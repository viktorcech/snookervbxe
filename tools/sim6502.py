"""sim6502.py -- minimal NMOS 6502 core with cycle counting, MADS XEX + .lab
loading and a per-proc profiler.  Used by asm_bench.py to (a) prove two builds
of the game are bit-identical (ball table + every VRAM window write) and (b)
price each proc in cycles/frame before and after a rewrite.

No decimal mode (the game never uses SED).  Undocumented opcodes raise.
"""
import bisect
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ (the user's rule); numba's cache -> tools/out
os.environ.setdefault('NUMBA_CACHE_DIR', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out', 'numba'))

try:                           # the JIT core (numba): the same instructions, cycles and
    import numpy as np          # flags as the Python one, run natively; any access to a
    from numba import njit      # hooked address (I/O, MEMAC windows) goes to the Python one
except ImportError:
    np = None

FLAG_C, FLAG_Z, FLAG_I, FLAG_D, FLAG_B, FLAG_U, FLAG_V, FLAG_N = 1, 2, 4, 8, 16, 32, 64, 128


def load_xex(path, mem, on_init=None):
    """Load a MADS/DOS XEX.  An INITAD segment ($2E2) runs on_init(addr) right
    away, like the real loader (the game streams its view data through such
    hooks)."""
    data = open(path, 'rb').read()
    i = 0
    n = len(data)
    run = None
    while i < n:
        lo, hi = data[i], data[i + 1]
        if lo == 0xFF and hi == 0xFF:
            i += 2
            continue
        start = lo | (hi << 8)
        end = data[i + 2] | (data[i + 3] << 8)
        i += 4
        ln = end - start + 1
        mem[start:start + ln] = data[i:i + ln]
        if start == 0x02E0:
            run = mem[0x2E0] | (mem[0x2E1] << 8)
        if start == 0x02E2 and on_init is not None:
            on_init(mem[0x2E2] | (mem[0x2E3] << 8))
        i += ln
    return run


def load_labels(path):
    labs = {}
    for line in open(path, encoding='latin-1'):
        parts = line.strip().split('\t')
        if len(parts) == 3 and parts[0] == '00':
            try:
                labs[parts[2]] = int(parts[1], 16)
            except ValueError:
                pass
    return labs


# ---- the JIT core -------------------------------------------------------------
# kind: 1 LDA 2 LDX 3 LDY 4 AND 5 ORA 6 EOR 7 ADC 8 SBC 9 CMP 10 CPX 11 CPY 12 BIT,
# 20 STA 21 STX 22 STY, 30 ASL 31 ROL 32 LSR 33 ROR 34 INC 35 DEC, 40 branch,
# 50.. flags, 60.. implied; 0 = the Python core (BRK, illegal).
# mode: 0 implied 1 imm 2 zp 3 zpx 4 zpy 5 abs 6 absx 7 absy 8 indx 9 indy 10 acc
def _tables():
    kind = [0] * 256
    mode = [0] * 256

    def put(op, k, m):
        kind[op] = k
        mode[op] = m
    for k, base in ((4, 0x21), (5, 0x01), (6, 0x41), (7, 0x61), (8, 0xE1), (9, 0xC1)):
        for off, m in ((0x08, 1), (0x04, 2), (0x14, 3), (0x0C, 5), (0x1C, 6), (0x18, 7), (0x00, 8), (0x10, 9)):
            put(base + off, k, m)
    for op, m in ((0xA9, 1), (0xA5, 2), (0xB5, 3), (0xAD, 5), (0xBD, 6), (0xB9, 7), (0xA1, 8), (0xB1, 9)):
        put(op, 1, m)
    for op, m in ((0xA2, 1), (0xA6, 2), (0xB6, 4), (0xAE, 5), (0xBE, 7)):
        put(op, 2, m)
    for op, m in ((0xA0, 1), (0xA4, 2), (0xB4, 3), (0xAC, 5), (0xBC, 6)):
        put(op, 3, m)
    for op, m in ((0xE0, 1), (0xE4, 2), (0xEC, 5)):
        put(op, 10, m)
    for op, m in ((0xC0, 1), (0xC4, 2), (0xCC, 5)):
        put(op, 11, m)
    put(0x24, 12, 2)
    put(0x2C, 12, 5)
    for op, m in ((0x85, 2), (0x95, 3), (0x8D, 5), (0x9D, 6), (0x99, 7), (0x81, 8), (0x91, 9)):
        put(op, 20, m)
    for op, m in ((0x86, 2), (0x96, 4), (0x8E, 5)):
        put(op, 21, m)
    for op, m in ((0x84, 2), (0x94, 3), (0x8C, 5)):
        put(op, 22, m)
    for k, base in ((30, 0x06), (31, 0x26), (32, 0x46), (33, 0x66)):
        put(base, k, 2)
        put(base + 0x10, k, 3)
        put(base + 0x08, k, 5)
        put(base + 0x18, k, 6)
        put(base + 0x04, k, 10)
    for k, base in ((34, 0xE6), (35, 0xC6)):
        put(base, k, 2)
        put(base + 0x10, k, 3)
        put(base + 0x08, k, 5)
        put(base + 0x18, k, 6)
    for op in (0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0):
        put(op, 40, 0)
    for op, k in ((0x18, 50), (0x38, 51), (0x58, 52), (0x78, 53), (0xB8, 54), (0xD8, 55), (0xF8, 56),
                  (0xEA, 60), (0xAA, 61), (0xA8, 62), (0x8A, 63), (0x98, 64), (0xBA, 65), (0x9A, 66),
                  (0xE8, 67), (0xC8, 68), (0xCA, 69), (0x88, 70), (0x48, 71), (0x08, 72), (0x68, 73),
                  (0x28, 74), (0x4C, 75), (0x6C, 76), (0x20, 77), (0x60, 78), (0x40, 79)):
        put(op, k, 0)
    return kind, mode


if np is not None:
    _K, _M = _tables()
    _KIND = np.array(_K, dtype=np.uint8)
    _MODE = np.array(_M, dtype=np.uint8)
    _RD = np.array([0, 2, 3, 4, 4, 4, 4, 4, 6, 5, 2], dtype=np.int64)    # cycles per mode: read,
    _WR = np.array([0, 0, 3, 4, 4, 4, 5, 5, 6, 6, 0], dtype=np.int64)    # write,
    _RMW = np.array([0, 0, 5, 6, 0, 6, 7, 0, 0, 0, 2], dtype=np.int64)   # read-modify-write
    _BRF = np.array([128, 128, 64, 64, 1, 1, 2, 2], dtype=np.int64)       # branch: flag, value
    _BRV = np.array([0, 1, 0, 1, 0, 1, 0, 1], dtype=np.int64)

    @njit(inline='always')
    def rb(mem, i):
        return np.int64(mem[i])

    @njit(cache=True)
    def _fast(mem, slow, kind, mode, rdc, wrc, rmwc, brf, brv, regs, cycles, stop_pc, limit, irqp):
        """from regs (a x y s p pc) until pc = stop_pc (0), cycles >= limit (1) or an
        instruction the Python core must run (2, not executed).  regs[6] = the I
        flag before the last instruction run.  Returns (status, cycles)."""
        a = regs[0]
        x = regs[1]
        y = regs[2]
        s = regs[3]
        p = regs[4]
        pc = regs[5]
        i0 = regs[6]
        status = 0
        while pc != stop_pc:
            if cycles >= limit or (irqp and not (p & 4)):     # (an IRQ due: the Python core)
                status = 1
                break
            op = rb(mem, pc)
            k = np.int64(kind[op])
            if k == 0:
                status = 2
                break
            md = np.int64(mode[op])
            ea = 0
            pg = 0
            n = pc + 1
            if md == 1:
                ea = n & 0xFFFF
                n = n + 1
            elif md == 2:
                ea = rb(mem, n & 0xFFFF)
                n = n + 1
            elif md == 3:
                ea = (rb(mem, n & 0xFFFF) + x) & 0xFF
                n = n + 1
            elif md == 4:
                ea = (rb(mem, n & 0xFFFF) + y) & 0xFF
                n = n + 1
            elif md == 5:
                ea = rb(mem, n & 0xFFFF) | (rb(mem, (n + 1) & 0xFFFF) << 8)
                n = n + 2
            elif md == 6 or md == 7:
                b = rb(mem, n & 0xFFFF) | (rb(mem, (n + 1) & 0xFFFF) << 8)
                if md == 6:
                    ea = (b + x) & 0xFFFF
                else:
                    ea = (b + y) & 0xFFFF
                if (b & 0xFF00) != (ea & 0xFF00):
                    pg = 1
                n = n + 2
            elif md == 8:
                z = (rb(mem, n & 0xFFFF) + x) & 0xFF
                ea = rb(mem, z) | (rb(mem, (z + 1) & 0xFF) << 8)
                n = n + 1
            elif md == 9:
                z = rb(mem, n & 0xFFFF)
                b = rb(mem, z) | (rb(mem, (z + 1) & 0xFF) << 8)
                ea = (b + y) & 0xFFFF
                if (b & 0xFF00) != (ea & 0xFF00):
                    pg = 1
                n = n + 1
            n = n & 0xFFFF
            if k < 20:                          # hooked accesses: the Python core
                if md != 1 and (slow[ea] & 1):
                    status = 2
                    break
            elif k < 30:
                if slow[ea] & 2:
                    status = 2
                    break
            elif k < 40:
                if md != 10 and (slow[ea] & 3):
                    status = 2
                    break
            if (k == 7 or k == 8) and (p & 8):
                status = 2
                break
            i0 = p & 4
            if k < 20:
                v = rb(mem, ea)
                cycles += rdc[md] + pg
                r = 0
                if k == 1:
                    a = v
                    r = v
                elif k == 2:
                    x = v
                    r = v
                elif k == 3:
                    y = v
                    r = v
                elif k == 4:
                    a = a & v
                    r = a
                elif k == 5:
                    a = a | v
                    r = a
                elif k == 6:
                    a = a ^ v
                    r = a
                elif k == 7:
                    t = a + v + (p & 1)
                    p = p & ~(1 | 64)
                    if t > 0xFF:
                        p |= 1
                    if (~(a ^ v) & (a ^ t)) & 0x80:
                        p |= 64
                    a = t & 0xFF
                    r = a
                elif k == 8:
                    t = a - v - (1 - (p & 1))
                    p = p & ~(1 | 64)
                    if t >= 0:
                        p |= 1
                    if ((a ^ v) & (a ^ t)) & 0x80:
                        p |= 64
                    a = t & 0xFF
                    r = a
                elif k == 12:
                    p = p & ~(128 | 64 | 2)
                    p |= v & (128 | 64)
                    if (a & v) == 0:
                        p |= 2
                    pc = n
                    continue
                else:
                    if k == 9:
                        t = a - v
                    elif k == 10:
                        t = x - v
                    else:
                        t = y - v
                    p = p & ~1
                    if t >= 0:
                        p |= 1
                    r = t & 0xFF
                p = (p & ~(128 | 2)) | (r & 0x80)
                if r == 0:
                    p |= 2
                pc = n
            elif k < 30:
                if k == 20:
                    mem[ea] = a
                elif k == 21:
                    mem[ea] = x
                else:
                    mem[ea] = y
                cycles += wrc[md]
                pc = n
            elif k < 40:
                if md == 10:
                    v = a
                else:
                    v = rb(mem, ea)
                if k == 30:
                    p = (p & ~1) | (v >> 7)
                    r = (v << 1) & 0xFF
                elif k == 31:
                    c = p & 1
                    p = (p & ~1) | (v >> 7)
                    r = ((v << 1) | c) & 0xFF
                elif k == 32:
                    p = (p & ~1) | (v & 1)
                    r = v >> 1
                elif k == 33:
                    c = p & 1
                    p = (p & ~1) | (v & 1)
                    r = (v >> 1) | (c << 7)
                elif k == 34:
                    r = (v + 1) & 0xFF
                else:
                    r = (v - 1) & 0xFF
                p = (p & ~(128 | 2)) | (r & 0x80)
                if r == 0:
                    p |= 2
                if md == 10:
                    a = r
                else:
                    mem[ea] = r
                cycles += rmwc[md]
                pc = n
            elif k == 40:
                off = rb(mem, n)
                n = (n + 1) & 0xFFFF
                bi = op >> 5
                if ((p & brf[bi]) != 0) == (brv[bi] == 1):
                    if off & 0x80:
                        off -= 256
                    t = (n + off) & 0xFFFF
                    cycles += 3
                    if (n & 0xFF00) != (t & 0xFF00):
                        cycles += 1
                    pc = t
                else:
                    cycles += 2
                    pc = n
            elif k < 60:
                if k == 50:
                    p &= ~1
                elif k == 51:
                    p |= 1
                elif k == 52:
                    p &= ~4
                elif k == 53:
                    p |= 4
                elif k == 54:
                    p &= ~64
                elif k == 55:
                    p &= ~8
                else:
                    p |= 8
                cycles += 2
                pc = n
            else:
                r = -1
                if k == 60:
                    cycles += 2
                elif k == 61:
                    x = a
                    r = x
                    cycles += 2
                elif k == 62:
                    y = a
                    r = y
                    cycles += 2
                elif k == 63:
                    a = x
                    r = a
                    cycles += 2
                elif k == 64:
                    a = y
                    r = a
                    cycles += 2
                elif k == 65:
                    x = s
                    r = x
                    cycles += 2
                elif k == 66:
                    s = x
                    cycles += 2
                elif k == 67:
                    x = (x + 1) & 0xFF
                    r = x
                    cycles += 2
                elif k == 68:
                    y = (y + 1) & 0xFF
                    r = y
                    cycles += 2
                elif k == 69:
                    x = (x - 1) & 0xFF
                    r = x
                    cycles += 2
                elif k == 70:
                    y = (y - 1) & 0xFF
                    r = y
                    cycles += 2
                elif k == 71:
                    mem[0x100 + s] = a
                    s = (s - 1) & 0xFF
                    cycles += 3
                elif k == 72:
                    mem[0x100 + s] = p | 16 | 32
                    s = (s - 1) & 0xFF
                    cycles += 3
                elif k == 73:
                    s = (s + 1) & 0xFF
                    a = rb(mem, 0x100 + s)
                    r = a
                    cycles += 4
                elif k == 74:
                    s = (s + 1) & 0xFF
                    p = (rb(mem, 0x100 + s) | 32) & ~16
                    cycles += 4
                elif k == 75:
                    n = rb(mem, n) | (rb(mem, (n + 1) & 0xFFFF) << 8)
                    cycles += 3
                elif k == 76:
                    t = rb(mem, n) | (rb(mem, (n + 1) & 0xFFFF) << 8)
                    n = rb(mem, t) | (rb(mem, (t & 0xFF00) | ((t + 1) & 0xFF)) << 8)
                    cycles += 5
                elif k == 77:
                    t = rb(mem, n) | (rb(mem, (n + 1) & 0xFFFF) << 8)
                    ret = (n + 1) & 0xFFFF
                    mem[0x100 + s] = ret >> 8
                    s = (s - 1) & 0xFF
                    mem[0x100 + s] = ret & 0xFF
                    s = (s - 1) & 0xFF
                    n = t
                    cycles += 6
                elif k == 78:
                    s = (s + 1) & 0xFF
                    lo = rb(mem, 0x100 + s)
                    s = (s + 1) & 0xFF
                    hi = rb(mem, 0x100 + s)
                    n = ((lo | (hi << 8)) + 1) & 0xFFFF
                    cycles += 6
                else:
                    s = (s + 1) & 0xFF
                    p = (rb(mem, 0x100 + s) | 32) & ~16
                    s = (s + 1) & 0xFF
                    lo = rb(mem, 0x100 + s)
                    s = (s + 1) & 0xFF
                    hi = rb(mem, 0x100 + s)
                    n = lo | (hi << 8)
                    cycles += 6
                if r >= 0:
                    p = (p & ~(128 | 2)) | (r & 0x80)
                    if r == 0:
                        p |= 2
                pc = n
        regs[0] = a
        regs[1] = x
        regs[2] = y
        regs[3] = s
        regs[4] = p
        regs[5] = pc
        regs[6] = i0
        return status, cycles


class CPU:
    def __init__(self):
        self.mem = bytearray(65536)
        self.a = self.x = self.y = 0
        self.s = 0xFF
        self.p = FLAG_U | FLAG_I
        self.pc = 0
        self.cycles = 0
        self.irq_line = False  # the IRQ input (POKEY), level: taken while I = 0
        self.irq_vector = 0
        self.rd_hooks = {}     # addr -> fn() -> value
        self.wr_hooks = {}     # addr -> fn(value)
        self.wr_range = None   # (lo, hi, fn(addr, value))
        self.rd_range = None   # (lo, hi, fn(addr) -> value)
        self.next_event = None  # cycle count at which on_event() runs (the VBI's NMI)
        self.on_event = None
        self.profile = None    # list of counters, indexed by proc idx
        self.xcount = None     # {pc: page-cross penalties} (the Python core, with the profile on)
        self.xpen = 0
        self.cstack = None     # [(site, target, s, cycles)]: open calls (the call-time profile)
        self.istack = None     # [cycles at entry]: open interrupts (with the profile on)
        self.icycles = 0       # the cycles spent in interrupts, entry to rti
        self.tcount = None     # {pc: taken branches} (with the profile on)
        self.cstats = {}       # {(site, target): [calls, cycles, min]}: the time inside each call
        self.proc_starts = []  # sorted addrs
        self.proc_names = []
        self._build()

    # ---- memory ---------------------------------------------------------
    def rd(self, a):
        h = self.rd_hooks.get(a)
        if h is not None:
            return h()
        r = self.rd_range
        if r is not None and r[0] <= a <= r[1]:
            return r[2](a)
        return self.mem[a]

    def wr(self, a, v):
        r = self.wr_range
        if r is not None and r[0] <= a <= r[1]:
            r[2](a, v)          # a MEMAC window: the write is VRAM's, the RAM under it kept
        else:
            self.mem[a] = v
        h = self.wr_hooks.get(a)
        if h is not None:
            h(v)

    # ---- profiling ------------------------------------------------------
    def set_procs(self, labels):
        # procs = labels without a dot (proc-local labels contain '.'), ALL the code from
        # $0500 up: a pc is charged to the last label at or below it, so the old window
        # ($4000-$87FF) charged everything above $87D0 -- the RAM under BASIC and the OS
        # ROM (fmulu, the physics) -- to cu_unit, its last proc [2026-10-28]
        items = sorted((a, n) for n, a in labels.items()
                       if '.' not in n and a >= 0x0500)
        self.proc_starts = [a for a, n in items]
        self.proc_names = [n for a, n in items]
        self.profile = [0] * len(items)
        self.calls = [0] * len(items)

    def proc_index(self, pc):
        return bisect.bisect_right(self.proc_starts, pc) - 1

    # ---- flags ----------------------------------------------------------
    def setnz(self, v):
        self.p = (self.p & ~(FLAG_N | FLAG_Z)) | (v & 0x80) | (FLAG_Z if v == 0 else 0)
        return v

    def push(self, v):
        self.mem[0x100 + self.s] = v
        self.s = (self.s - 1) & 0xFF

    def pull(self):
        self.s = (self.s + 1) & 0xFF
        return self.mem[0x100 + self.s]

    # ---- run ------------------------------------------------------------
    def step(self):
        pc = self.pc
        op = self.mem[pc]
        self.pc = (pc + 1) & 0xFFFF
        fn = self.ops[op]
        if fn is None:
            raise RuntimeError('illegal opcode %02X at %04X' % (op, pc))
        self.xpen = 0
        cyc = fn()
        self.cycles += cyc
        if self.profile is not None:
            self.profile[bisect.bisect_right(self.proc_starts, pc) - 1] += cyc
            if self.xpen and self.xcount is not None:
                self.xcount[pc] = self.xcount.get(pc, 0) + 1
        return cyc

    def _slowmap(self):
        """the addresses the JIT core leaves to this one: bit 0 read, bit 1 write
        (hooks, MEMAC ranges); rebuilt when they change"""
        rr, wr = self.rd_range, self.wr_range
        sig = (len(self.rd_hooks), len(self.wr_hooks), sum(self.rd_hooks), sum(self.wr_hooks),
               rr and rr[:2], wr and wr[:2])
        if sig != getattr(self, '_sig', None):
            m = np.zeros(65536, dtype=np.uint8)
            for k in self.rd_hooks:
                m[k] |= 1
            for k in self.wr_hooks:
                m[k] |= 2
            if rr is not None:
                m[rr[0]:rr[1] + 1] |= 1
            if wr is not None:
                m[wr[0]:wr[1] + 1] |= 2
            self._sig, self._slow = sig, m
        return self._slow

    def _one(self, max_cycles):
        """one instruction in the Python core, then the event, the IRQ, the budget"""
        i0 = self.p & FLAG_I
        self.step()
        if self.next_event is not None and self.cycles >= self.next_event:
            self.on_event()
        if self.irq_line and not i0 and not self.p & FLAG_I:
            self.irq()
        if max_cycles is not None and self.cycles > max_cycles:
            raise RuntimeError('cycle budget exceeded at %04X' % self.pc)

    def _run_fast(self, stop_pc, max_cycles):
        if getattr(self, '_np', None) is None:
            self._np = np.frombuffer(self.mem, dtype=np.uint8)
            self._regs = np.zeros(7, dtype=np.int64)
        mem, regs = self._np, self._regs
        big = 1 << 62
        while self.pc != stop_pc:
            if self.irq_line and not self.p & FLAG_I:
                self._one(max_cycles)
                continue
            lim = self.next_event if self.next_event is not None else big
            if max_cycles is not None and max_cycles + 1 < lim:
                lim = max_cycles + 1
            regs[0] = self.a
            regs[1] = self.x
            regs[2] = self.y
            regs[3] = self.s
            regs[4] = self.p
            regs[5] = self.pc
            regs[6] = self.p & FLAG_I
            st, cyc = _fast(mem, self._slowmap(), _KIND, _MODE, _RD, _WR, _RMW, _BRF, _BRV,
                            regs, self.cycles, stop_pc, lim, self.irq_line)
            self.a, self.x, self.y, self.s = int(regs[0]), int(regs[1]), int(regs[2]), int(regs[3])
            self.p, self.pc, self.cycles = int(regs[4]), int(regs[5]), int(cyc)
            if st == 2:
                self._one(max_cycles)
                continue
            if self.next_event is not None and self.cycles >= self.next_event:
                self.on_event()
            if self.irq_line and not regs[6] and not self.p & FLAG_I:
                self.irq()
            if max_cycles is not None and self.cycles > max_cycles:
                raise RuntimeError('cycle budget exceeded at %04X' % self.pc)

    def run_until(self, stop_pc, max_cycles=None):
        if np is not None and self.profile is None and not getattr(self, 'slow_only', False):
            return self._run_fast(stop_pc, max_cycles)
        while self.pc != stop_pc:
            i0 = self.p & FLAG_I        # the IRQ is polled with the I flag of before
            self.step()                 # the instruction (CLI / SEI / PLP latency)
            if self.next_event is not None and self.cycles >= self.next_event:
                self.on_event()
            if self.irq_line and not i0 and not self.p & FLAG_I:
                self.irq()
            if max_cycles is not None and self.cycles > max_cycles:
                raise RuntimeError('cycle budget exceeded at %04X' % self.pc)

    def irq(self):
        """the IRQ sequence: PC and P pushed (B clear), I set, PC = ($FFFE) (7 cycles)."""
        self.push(self.pc >> 8)
        self.push(self.pc & 0xFF)
        self.push((self.p | FLAG_U) & ~FLAG_B)
        self.p |= FLAG_I
        self.pc = self.irq_vector
        if self.istack is not None:
            self.istack.append(self.cycles)
        self.cycles += 7

    def nmi(self, vector):
        """the NMI sequence: PC and P pushed, I set, PC = vector (7 cycles)."""
        self.push(self.pc >> 8)
        self.push(self.pc & 0xFF)
        self.push((self.p | FLAG_U) & ~FLAG_B)
        self.p |= FLAG_I
        self.pc = vector
        if self.istack is not None:
            self.istack.append(self.cycles)
        self.cycles += 7

    def call(self, addr, max_cycles=50_000_000):
        """JSR addr and run until it returns (stack-balanced)."""
        ret = 0xFFFC
        self.push((ret - 1) >> 8)
        self.push((ret - 1) & 0xFF)
        self.pc = addr
        self.cycles += 6
        start = self.cycles
        self.run_until(ret, start + max_cycles)
        return self.cycles - start

    # ---- opcode table ---------------------------------------------------
    def _build(self):
        self.ops = [None] * 256
        cpu = self
        mem = self.mem

        def fetch():
            v = mem[cpu.pc]
            cpu.pc = (cpu.pc + 1) & 0xFFFF
            return v

        def fetch16():
            lo = mem[cpu.pc]
            hi = mem[(cpu.pc + 1) & 0xFFFF]
            cpu.pc = (cpu.pc + 2) & 0xFFFF
            return lo | (hi << 8)

        # addressing: returns (addr, extra_cycles_on_page_cross)
        def am_imm():
            a = cpu.pc
            cpu.pc = (cpu.pc + 1) & 0xFFFF
            return a, 0

        def am_zp():
            return fetch(), 0

        def am_zpx():
            return (fetch() + cpu.x) & 0xFF, 0

        def am_zpy():
            return (fetch() + cpu.y) & 0xFF, 0

        def am_abs():
            return fetch16(), 0

        def am_absx():
            b = fetch16()
            a = (b + cpu.x) & 0xFFFF
            return a, 1 if (b & 0xFF00) != (a & 0xFF00) else 0

        def am_absy():
            b = fetch16()
            a = (b + cpu.y) & 0xFFFF
            return a, 1 if (b & 0xFF00) != (a & 0xFF00) else 0

        def am_indx():
            z = (fetch() + cpu.x) & 0xFF
            return mem[z] | (mem[(z + 1) & 0xFF] << 8), 0

        def am_indy():
            z = fetch()
            b = mem[z] | (mem[(z + 1) & 0xFF] << 8)
            a = (b + cpu.y) & 0xFFFF
            return a, 1 if (b & 0xFF00) != (a & 0xFF00) else 0

        # modes: (fn, base read cycles, write cycles, rmw cycles)
        MODES = {
            'imm': (am_imm, 2, None, None),
            'zp': (am_zp, 3, 3, 5),
            'zpx': (am_zpx, 4, 4, 6),
            'zpy': (am_zpy, 4, 4, None),
            'abs': (am_abs, 4, 4, 6),
            'absx': (am_absx, 4, 5, 7),
            'absy': (am_absy, 4, 5, None),
            'indx': (am_indx, 6, 6, None),
            'indy': (am_indy, 5, 6, None),
        }

        def rd(a):
            h = cpu.rd_hooks.get(a)
            if h is not None:
                return h()
            r = cpu.rd_range
            if r is not None and r[0] <= a <= r[1]:
                return r[2](a)
            return mem[a]

        wr = cpu.wr

        # ---- ALU ops (read) ----
        def op_lda(v): cpu.a = cpu.setnz(v)
        def op_ldx(v): cpu.x = cpu.setnz(v)
        def op_ldy(v): cpu.y = cpu.setnz(v)
        def op_and(v): cpu.a = cpu.setnz(cpu.a & v)
        def op_ora(v): cpu.a = cpu.setnz(cpu.a | v)
        def op_eor(v): cpu.a = cpu.setnz(cpu.a ^ v)

        def op_adc(v):
            if cpu.p & FLAG_D:
                raise RuntimeError('decimal mode unsupported')
            r = cpu.a + v + (cpu.p & FLAG_C)
            p = cpu.p & ~(FLAG_C | FLAG_V)
            if r > 0xFF:
                p |= FLAG_C
            if (~(cpu.a ^ v) & (cpu.a ^ r)) & 0x80:
                p |= FLAG_V
            cpu.p = p
            cpu.a = cpu.setnz(r & 0xFF)

        def op_sbc(v):
            if cpu.p & FLAG_D:
                raise RuntimeError('decimal mode unsupported')
            r = cpu.a - v - (1 - (cpu.p & FLAG_C))
            p = cpu.p & ~(FLAG_C | FLAG_V)
            if r >= 0:
                p |= FLAG_C
            if ((cpu.a ^ v) & (cpu.a ^ r)) & 0x80:
                p |= FLAG_V
            cpu.p = p
            cpu.a = cpu.setnz(r & 0xFF)

        def cmp_(reg, v):
            r = reg - v
            p = cpu.p & ~FLAG_C
            if r >= 0:
                p |= FLAG_C
            cpu.p = p
            cpu.setnz(r & 0xFF)

        def op_cmp(v): cmp_(cpu.a, v)
        def op_cpx(v): cmp_(cpu.x, v)
        def op_cpy(v): cmp_(cpu.y, v)

        def op_bit(v):
            p = cpu.p & ~(FLAG_N | FLAG_V | FLAG_Z)
            p |= v & (FLAG_N | FLAG_V)
            if (cpu.a & v) == 0:
                p |= FLAG_Z
            cpu.p = p

        # ---- RMW ops ----
        def op_asl(v):
            cpu.p = (cpu.p & ~FLAG_C) | (v >> 7)
            return cpu.setnz((v << 1) & 0xFF)

        def op_lsr(v):
            cpu.p = (cpu.p & ~FLAG_C) | (v & 1)
            return cpu.setnz(v >> 1)

        def op_rol(v):
            c = cpu.p & FLAG_C
            cpu.p = (cpu.p & ~FLAG_C) | (v >> 7)
            return cpu.setnz(((v << 1) | c) & 0xFF)

        def op_ror(v):
            c = cpu.p & FLAG_C
            cpu.p = (cpu.p & ~FLAG_C) | (v & 1)
            return cpu.setnz((v >> 1) | (c << 7))

        def op_inc(v): return cpu.setnz((v + 1) & 0xFF)
        def op_dec(v): return cpu.setnz((v - 1) & 0xFF)

        def mk_read(fn, mode):
            amf, base, _, _ = MODES[mode]

            def f():
                a, x = amf()
                fn(rd(a))
                if x:
                    cpu.xpen = 1
                return base + x
            return f

        def mk_write(getv, mode):
            amf, _, base, _ = MODES[mode]

            def f():
                a, _ = amf()
                wr(a, getv())
                return base
            return f

        def mk_rmw(fn, mode):
            amf, _, _, base = MODES[mode]

            def f():
                a, _ = amf()
                wr(a, fn(rd(a)))
                return base
            return f

        def mk_acc(fn):
            def f():
                cpu.a = fn(cpu.a)
                return 2
            return f

        def mk_branch(flag, val):
            def f():
                off = fetch()
                if ((cpu.p & flag) != 0) == val:
                    if off & 0x80:
                        off -= 256
                    old = cpu.pc
                    cpu.pc = (old + off) & 0xFFFF
                    if cpu.tcount is not None:
                        cpu.tcount[old - 2] = cpu.tcount.get(old - 2, 0) + 1
                    if (old & 0xFF00) != (cpu.pc & 0xFF00):
                        cpu.xpen = 1
                        return 4
                    return 3
                return 2
            return f

        def setflag(flag, on):
            def f():
                if on:
                    cpu.p |= flag
                else:
                    cpu.p &= ~flag
                return 2
            return f

        T = self.ops
        # LDA
        for opc, m in ((0xA9, 'imm'), (0xA5, 'zp'), (0xB5, 'zpx'), (0xAD, 'abs'), (0xBD, 'absx'),
                       (0xB9, 'absy'), (0xA1, 'indx'), (0xB1, 'indy')):
            T[opc] = mk_read(op_lda, m)
        for opc, m in ((0xA2, 'imm'), (0xA6, 'zp'), (0xB6, 'zpy'), (0xAE, 'abs'), (0xBE, 'absy')):
            T[opc] = mk_read(op_ldx, m)
        for opc, m in ((0xA0, 'imm'), (0xA4, 'zp'), (0xB4, 'zpx'), (0xAC, 'abs'), (0xBC, 'absx')):
            T[opc] = mk_read(op_ldy, m)
        for fn, base in ((op_and, 0x21), (op_ora, 0x01), (op_eor, 0x41), (op_adc, 0x61),
                         (op_sbc, 0xE1), (op_cmp, 0xC1)):
            T[base + 0x08] = mk_read(fn, 'imm')
            T[base + 0x04] = mk_read(fn, 'zp')
            T[base + 0x14] = mk_read(fn, 'zpx')
            T[base + 0x0C] = mk_read(fn, 'abs')
            T[base + 0x1C] = mk_read(fn, 'absx')
            T[base + 0x18] = mk_read(fn, 'absy')
            T[base + 0x00] = mk_read(fn, 'indx')
            T[base + 0x10] = mk_read(fn, 'indy')
        for opc, m in ((0xE0, 'imm'), (0xE4, 'zp'), (0xEC, 'abs')):
            T[opc] = mk_read(op_cpx, m)
        for opc, m in ((0xC0, 'imm'), (0xC4, 'zp'), (0xCC, 'abs')):
            T[opc] = mk_read(op_cpy, m)
        T[0x24] = mk_read(op_bit, 'zp')
        T[0x2C] = mk_read(op_bit, 'abs')
        # STA/STX/STY
        ga = lambda: cpu.a
        gx = lambda: cpu.x
        gy = lambda: cpu.y
        for opc, m in ((0x85, 'zp'), (0x95, 'zpx'), (0x8D, 'abs'), (0x9D, 'absx'), (0x99, 'absy'),
                       (0x81, 'indx'), (0x91, 'indy')):
            T[opc] = mk_write(ga, m)
        for opc, m in ((0x86, 'zp'), (0x96, 'zpy'), (0x8E, 'abs')):
            T[opc] = mk_write(gx, m)
        for opc, m in ((0x84, 'zp'), (0x94, 'zpx'), (0x8C, 'abs')):
            T[opc] = mk_write(gy, m)
        # RMW
        for fn, base in ((op_asl, 0x06), (op_rol, 0x26), (op_lsr, 0x46), (op_ror, 0x66)):
            T[base] = mk_rmw(fn, 'zp')
            T[base + 0x10] = mk_rmw(fn, 'zpx')
            T[base + 0x08] = mk_rmw(fn, 'abs')
            T[base + 0x18] = mk_rmw(fn, 'absx')
            T[base + 0x04] = mk_acc(fn)
        for fn, base in ((op_inc, 0xE6), (op_dec, 0xC6)):
            T[base] = mk_rmw(fn, 'zp')
            T[base + 0x10] = mk_rmw(fn, 'zpx')
            T[base + 0x08] = mk_rmw(fn, 'abs')
            T[base + 0x18] = mk_rmw(fn, 'absx')
        # branches
        T[0x10] = mk_branch(FLAG_N, False)
        T[0x30] = mk_branch(FLAG_N, True)
        T[0x50] = mk_branch(FLAG_V, False)
        T[0x70] = mk_branch(FLAG_V, True)
        T[0x90] = mk_branch(FLAG_C, False)
        T[0xB0] = mk_branch(FLAG_C, True)
        T[0xD0] = mk_branch(FLAG_Z, False)
        T[0xF0] = mk_branch(FLAG_Z, True)
        # flags
        T[0x18] = setflag(FLAG_C, False)
        T[0x38] = setflag(FLAG_C, True)
        T[0x58] = setflag(FLAG_I, False)
        T[0x78] = setflag(FLAG_I, True)
        T[0xB8] = setflag(FLAG_V, False)
        T[0xD8] = setflag(FLAG_D, False)
        T[0xF8] = setflag(FLAG_D, True)

        # implied
        def nop(): return 2

        def tax():
            cpu.x = cpu.setnz(cpu.a); return 2

        def tay():
            cpu.y = cpu.setnz(cpu.a); return 2

        def txa():
            cpu.a = cpu.setnz(cpu.x); return 2

        def tya():
            cpu.a = cpu.setnz(cpu.y); return 2

        def tsx():
            cpu.x = cpu.setnz(cpu.s); return 2

        def txs():
            cpu.s = cpu.x; return 2

        def inx():
            cpu.x = cpu.setnz((cpu.x + 1) & 0xFF); return 2

        def iny():
            cpu.y = cpu.setnz((cpu.y + 1) & 0xFF); return 2

        def dex():
            cpu.x = cpu.setnz((cpu.x - 1) & 0xFF); return 2

        def dey():
            cpu.y = cpu.setnz((cpu.y - 1) & 0xFF); return 2

        def pha():
            cpu.push(cpu.a); return 3

        def php():
            cpu.push(cpu.p | FLAG_B | FLAG_U); return 3

        def pla():
            cpu.a = cpu.setnz(cpu.pull()); return 4

        def plp():
            cpu.p = (cpu.pull() | FLAG_U) & ~FLAG_B; return 4

        def jmp():
            cpu.pc = fetch16(); return 3

        def jmpi():
            a = fetch16()
            lo = mem[a]
            hi = mem[(a & 0xFF00) | ((a + 1) & 0xFF)]
            cpu.pc = lo | (hi << 8)
            return 5

        def jsr():
            a = fetch16()
            ret = (cpu.pc - 1) & 0xFFFF
            cpu.push(ret >> 8)
            cpu.push(ret & 0xFF)
            cpu.pc = a
            if cpu.profile is not None:
                cpu.calls[bisect.bisect_right(cpu.proc_starts, a) - 1] += 1
                if cpu.cstack is not None:     # the call's own time, jsr to rts (both excluded)
                    cpu.cstack.append(((ret - 2) & 0xFFFF, a, (cpu.s + 2) & 0xFF, cpu.cycles))
            return 6

        def rts():
            lo = cpu.pull()
            hi = cpu.pull()
            cpu.pc = ((lo | (hi << 8)) + 1) & 0xFFFF
            if cpu.cstack:
                while cpu.cstack and cpu.cstack[-1][2] != cpu.s:
                    cpu.cstack.pop()            # (a call left by a jmp or a stack trick)
                if cpu.cstack:
                    site, tgt, _, c0 = cpu.cstack.pop()
                    st = cpu.cstats.setdefault((site, tgt), [0, 0, 1 << 30])
                    d = cpu.cycles - c0 - 6     # (cycles still holds the jsr's 6)
                    st[0] += 1
                    st[1] += d
                    if d < st[2]:
                        st[2] = d
            return 6

        def rti():
            cpu.p = (cpu.pull() | FLAG_U) & ~FLAG_B
            lo = cpu.pull()
            hi = cpu.pull()
            cpu.pc = lo | (hi << 8)
            if cpu.istack:
                c0 = cpu.istack.pop()
                if not cpu.istack:          # the outermost one: its whole time, nested ones in it
                    cpu.icycles += cpu.cycles + 6 - c0
            return 6

        def brk():
            raise RuntimeError('BRK at %04X' % (cpu.pc - 1))

        T[0xEA] = nop
        T[0xAA] = tax
        T[0xA8] = tay
        T[0x8A] = txa
        T[0x98] = tya
        T[0xBA] = tsx
        T[0x9A] = txs
        T[0xE8] = inx
        T[0xC8] = iny
        T[0xCA] = dex
        T[0x88] = dey
        T[0x48] = pha
        T[0x08] = php
        T[0x68] = pla
        T[0x28] = plp
        T[0x4C] = jmp
        T[0x6C] = jmpi
        T[0x20] = jsr
        T[0x60] = rts
        T[0x40] = rti
        T[0x00] = brk
