"""asm_bench.py -- run the game binary in sim6502, profile per proc and produce
a per-frame digest (ball table + every VRAM window write) so two builds can be
proven bit-identical.

  python tools/asm_bench.py tools/out/_fix.xex --scenario break --out tools/out/bench/fix_break.json
  python tools/asm_bench.py build/snooker.xex --scenario break --out tools/out/bench/new_break.json --procs --report tools/out/bench/bench_fps.txt
  python tools/asm_bench.py --compare tools/out/bench/fix_break.json tools/out/bench/new_break.json

The .json files are the per-frame digests (cycles, ball-table hash, VRAM
write hash) that --compare checks; keep them under tools/out/bench/.

  python tools/asm_bench.py build/_base.xex build/snooker.xex --micro
      random-vector bit-identity of the math primitives (fmulu, mul48, smul3,
      rsh16, rsh9, div24, divr, isqrt48, vrefl, project, cosptr, set_bp ...)

The .lab file is taken from the .xex path with the extension swapped.
"""
import argparse
import hashlib
import json
import os
import random
import sys
sys.dont_write_bytecode = True  # no __pycache__ (the user's rule)
import time

sys.path.insert(0, os.path.dirname(__file__))
from sim6502 import CPU, load_xex, load_labels  # noqa: E402


# ==========================================================================
# VBXE FX 1.27 as the game sees it (docs/new-vbxe: the 1.27 Programmers Manual):
# 512 KB VRAM, MEMAC-A (ch. 6), the XDL and the overlay in its pixel and text
# modes with the four palettes (ch. 7, 8), the blitter (ch. 12) beside the CPU
# on the manual's cycle counts.  The display is caught by a beam, a scan line
# at a time, so a screenshot is the frame a monitor showed.
# ==========================================================================
VW, VH = 320, 240
LINES = 312                 # PAL
LINE = 114                  # machine cycles a scan line
PCLK = 8                    # VRAM cycles a machine cycle (912 a line)
OV_FIRST = 8                # the first overlay scan line (the XDL starts there)
LEFT = {'g': 592, 't': 672, None: 912}   # blitter cycles left a line, NORMAL width (ch. 12)


def _s(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


class VbxeSim:
    def __init__(self):
        self.vram = bytearray(512 * 1024)
        self.ma_ctl = 0
        self.bsel_raw = 0
        self.enabled = False
        self.video_control = 0
        self.xdl_adr = 0
        self.bl_adr = 0
        self.coll = 0               # BLT_COLLISION_CODE
        self.irqe = self.irqf = 0
        self.on_irq = lambda: None
        self.feature = self.colmask = self.coldetect = 0
        self.blit_count = self.blit_pixels = 0
        # the blitter: state (BLITTER_BUSY: 1 loading, 2 blitting, 0 idle), the list's
        # fetch pointer, the cycles owed / available
        self.state = 0
        self.ptr = 0
        self.phase = 0              # 0: load the next BCB, 1: its blit runs (owed cycles)
        self.owed = 0
        self.more = False           # the BCB being blitted has NEXT
        self.credit = 0.0
        # the beam
        self.mtime = 0.0
        self.ov_rows = [None] * VH  # per overlay line: its VRAM address
        self.ov_kind = [None] * VH  # ('g', palette) / ('t', palette, chbase, font row)
        self.xdl_cost = {}
        self.cur = bytearray(VW * VH)
        self.cur_rows = [None] * VH
        self.shown = None
        self.shown_rows = self.shown_pals = None
        self.frames = 0
        self.beam = True
        self.races = []
        self.pc = lambda: 0
        # the palettes: 0 the GTIA layer's colours after power on, 1-3 black (ch. 4)
        self.pals = [bytearray(768) for _ in range(4)]
        act = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           'docs', 'new-vbxe', 'palettes', 'PAL.act')
        if os.path.exists(act):
            self.pals[0][:] = open(act, 'rb').read()[:768]
        self.csel = self.psel = 0

    # ---- MEMAC-A (ch. 6): base bits 7-4, MCE bit 3, size 4 KB << bits 1-0; MGE + bank -
    def set_bsel(self, v):
        self.bsel_raw = v
        self.enabled = bool(v & 0x80) and bool(self.ma_ctl & 8)

    def set_mactl(self, v):
        self.ma_ctl = v
        self.enabled = bool(self.bsel_raw & 0x80) and bool(v & 8)

    def window(self):
        """(CPU base, size, VRAM address) of the enabled window, else None"""
        if not self.enabled:
            return None
        size = 0x1000 << (self.ma_ctl & 3)
        base = self.ma_ctl & 0xF0
        base <<= 8
        size = min(size, 0x10000 - base)            # (no wrap: cut at $FFFF)
        bank = self.bsel_raw & 0x7F & ~((0x1000 << (self.ma_ctl & 3)) // 0x1000 - 1)
        return (base, size, (bank << 12) & 0x7FFFF)

    def _win(self, a):
        w = self.window()
        if w is not None and w[0] <= a < w[0] + w[1]:
            return w[2] + a - w[0]
        return None

    def win_read(self, a, m, t):
        v = self._win(a)
        if v is None:
            return m[a]
        self.advance(t)
        self.credit -= 1                            # a MEMAC access: a VRAM cycle
        return self.vram[v]

    def win_write(self, a, val, m, t):
        v = self._win(a)
        if v is None:
            m[a] = val
            return
        self.advance(t)
        self.credit -= 1
        self.vram[v] = val

    def bcb(self, adr):
        return bytes(self.vram[adr:adr + 21])

    # ---- registers (ch. 5, 10, 12) ---------------------------------------
    def wr_video_control(self, v, t):
        self.advance(t)
        self.video_control = v
        self.feature = (self.feature & ~0x18) | (0x10 if v & 2 else 0)

    def wr_feature(self, v):
        self.feature = v & 0b10111011

    def wr_irq_control(self, v, t):
        self.advance(t)
        self.irqe = v & 1
        self.irqf = 0
        self.on_irq()

    def rd_irq_status(self, t):
        self.advance(t)
        return self.irqf

    def wr_csel(self, v):
        self.csel = v

    def wr_psel(self, v):
        self.psel = v & 3

    def wr_cr(self, v):
        self.pals[self.psel][self.csel * 3] = v & 0xFE

    def wr_cg(self, v):
        self.pals[self.psel][self.csel * 3 + 1] = v & 0xFE

    def wr_cb(self, v):                             # a write to CB steps CSEL
        self.pals[self.psel][self.csel * 3 + 2] = v & 0xFE
        self.csel = (self.csel + 1) & 255

    def busy(self, t):
        self.advance(t)
        return self.state

    def start(self, v, t):
        """BLITTER_START: 1 starts an idle blitter at BL_ADR (ignored while busy), 0 stops it"""
        self.advance(t)
        if v & 1:
            if self.state == 0:
                self.ptr = self.bl_adr & 0x7FFFF
                self.phase = 0
                self.state = 1
                self.credit = min(self.credit, 0.0)
                self._run()
        elif self.state:
            self.state = 0                          # stopped: no IRQ

    def flush(self):
        """the list run to its end now (tools that read VRAM straight after)"""
        while self.state:
            self.credit = 1e12
            self._run()
        self.credit = 0.0

    # ---- time -------------------------------------------------------------
    def advance(self, t):
        if self.state == 0 and not self.beam and t > self.mtime:
            l0, l1 = int(self.mtime // LINE), int(t // LINE)
            if l1 > l0:
                if l0 + (OV_FIRST - 1 - l0) % LINES < l1:
                    self._read_xdl()
                self.frames += (l1 - l0) // LINES
            self.mtime = t
            return
        while self.mtime < t:
            line = int(self.mtime // LINE)
            end = min(t, (line + 1) * LINE)
            y = line % LINES
            rate = PCLK
            if OV_FIRST <= y < OV_FIRST + VH and self.ov_rows[y - OV_FIRST] is not None:
                rate = LEFT[self.ov_kind[y - OV_FIRST][0]] / LINE
            if self.state:
                self.credit += rate * (end - self.mtime)
                self._run()
            self.mtime = end
            if end == (line + 1) * LINE:
                self._line_done(y)

    # ---- the blitter -----------------------------------------------------
    def _run(self):
        while self.state and self.credit > 0:
            if self.phase == 1:                     # the blit's cycles
                n = min(self.owed, self.credit)
                self.owed -= n
                self.credit -= n
                if self.owed > 0:
                    return
                if self.more:
                    self.phase = 0
                    self.state = 1
                    continue
                self.state = 0                      # the list's end
                self.credit = 0.0
                if self.irqe:
                    self.irqf = 1
                    self.on_irq()
                return
            r = self._load()                        # a BCB and its containers
            if r is None:                           # an invalid container: stop, no IRQ
                self.state = 0
                self.credit = 0.0
                return
            self.credit -= r[0]
            self.owed = self._blit(r[1], r[2])
            self.blit_count += 1
            self.phase = 1
            self.state = 2

    def _load(self):
        v = self.vram
        p = self.ptr
        b = bytes(v[(p + i) & 0x7FFFF] for i in range(21))
        p += 21
        cost = 21
        rc = None
        if b[20] & 0x80:                            # EXTENDED: containers
            while True:
                cc = v[p & 0x7FFFF]
                typ = (cc >> 5) & 3
                if typ == 0:                        # jump: absolute, or relative to its byte 4
                    j = v[(p + 1) & 0x7FFFF] | v[(p + 2) & 0x7FFFF] << 8
                    if cc & 1:
                        p = p + 3 + _s(j, 16)
                    else:
                        p = j | (v[(p + 3) & 0x7FFFF] & 7) << 16
                        p -= 4                      # (the + 4 below)
                    p += 4
                    cost += 4
                elif typ == 1:                      # raycasting: x, y accumulators, step x high
                    rc = bytes(v[(p + i) & 0x7FFFF] for i in range(1, 6))
                    p += 6
                    cost += 6
                else:
                    return None
                if not cc & 0x80:
                    break
        self.ptr = p & 0x7FFFF
        self.more = bool(b[20] & 8)
        return cost, b, rc

    def _blit(self, b, rc):
        """one BCB's operation (ch. 12 pseudo-code) -> its cycles"""
        v = self.vram
        src = b[0] | b[1] << 8 | (b[2] & 7) << 16
        sy = _s((b[3] | b[4] << 8) & (0x7FFF if rc else 0x1FFF), 15 if rc else 13)
        sx = _s(b[5], 8)
        dst = b[6] | b[7] << 8 | (b[8] & 7) << 16
        dy = _s((b[9] | b[10] << 8) & 0x1FFF, 13)
        dx = _s(b[11], 8)
        w = (b[12] | (b[13] & 1) << 8) + 1
        h = b[14] + 1
        andm, xorm, cm = b[15], b[16], b[17]
        zx, zy = (b[18] & 7) + 1, ((b[18] >> 4) & 7) + 1
        pat = b[19]
        ctl = b[20]
        mode, aux = ctl & 7, (ctl >> 4) & 7
        const = andm == 0
        self.coll = 0
        cyc = 0
        first = True
        if rc:
            xa = rc[0] | (rc[1] & 0x7F) << 8
            ya = rc[2] | (rc[3] & 0x7F) << 8
            sx = _s(b[5] | (rc[4] & 0x7F) << 8, 15)
            tw = [3, 4, 5, 6, 7, 7, 7, 7][pat & 7]
            th = [3, 4, 5, 6, 7, 7, 7, 7][(pat >> 3) & 7]
        tab = (aux << 16 | cm << 8) & 0x7FFFF
        srow = src
        for yy in range(h):
            for ry in range(zy):
                drow = dst
                sp = srow
                pw = 0
                for xx in range(w):
                    if rc:
                        ta = ((ya >> 8) & ((1 << th) - 1)) << tw | ((xa >> 8) & ((1 << tw) - 1))
                        sa = (src & 0x7C000) | ((src & 0x3FC0) | (ta & 0x3FC0)) | (ta & 0x3F)
                    else:
                        sa = sp
                    fetched = first or not const
                    s = (xorm if const else (v[sa & 0x7FFFF] & andm) ^ xorm)
                    for rx in range(zx):
                        da = drow & 0x7FFFF
                        rep = rx > 0 or not fetched
                        c = self._op(mode, aux, s, da, cm, tab)
                        cyc += self._cost(mode, aux, s, rep, cm)
                        first = False
                        drow += dx
                    if rc:
                        xa = (xa + sx) & 0x7FFF
                        ya = (ya + sy) & 0x7FFF
                    else:
                        sp += sx
                        pw += 1
                        if pat & 0x80 and pw == (pat & 0x3F) + 1:
                            sp = srow
                            pw = 0
                dst += dy
            if not rc:
                srow += sy
        self.blit_pixels += w * zx * h * zy
        return cyc

    def _op(self, mode, aux, s, da, cm, tab):
        v = self.vram
        if mode == 0:
            v[da] = s
            return
        if mode == 7:
            v[da] = v[tab | s]
            return
        if mode == 1:
            if s:
                if cm and not self.coll and self._csr(v[da], cm):
                    self.coll = v[da]
                v[da] = s
            return
        if mode == 2:
            if s or aux & 1:
                d = v[da]
                if cm and not self.coll and self._csr(d, cm):
                    self.coll = d
                t = d + s
                v[da] = (255 if t > 255 else 0) if aux & 1 else (min(t, 255) if aux & 2 else t & 255)
            return
        if mode == 4:
            if s:
                d = v[da]
                if cm and not self.coll and self._csr(d, cm):
                    self.coll = d
                v[da] = d & s
            else:
                v[da] = 0
            return
        if mode in (3, 5):
            if s:
                d = v[da]
                if cm and not self.coll and self._csr(d, cm):
                    self.coll = d
                v[da] = d | s if mode == 3 else d ^ s
            return
        if mode == 6 and s:                         # HR: nibbles apart
            d = v[da]
            nc = not self.coll
            r = d
            for sh in (0, 4):
                if (s >> sh) & 15:
                    dn = (d >> sh) & 15
                    if cm and nc and self._chr(dn, cm):
                        self.coll |= dn << sh
                    r = (r & ~(15 << sh)) | (s & (15 << sh))
            v[da] = r

    @staticmethod
    def _csr(d, cm):
        return d != 0 and cm >> (d >> 5) & 1

    @staticmethod
    def _chr(d, cm):
        return d != 0 and cm >> (d >> 1) & 1

    def _cost(self, mode, aux, s, rep, cm):
        """ch. 12 'Cycles needed by the Blitter': a fetched / repeated byte, source'' 0 or not"""
        if mode == 0:
            return 1 if rep else 2
        if mode == 1:
            ce = 1 if (cm and not self.coll) else 0
            if s:
                return (1 if rep else 2) + ce
            return 1
        if mode == 2:
            if s:
                return 2 if rep else 3
            return (2 if rep else 3) if aux & 1 else 1
        if mode in (3, 5, 6):
            return (2 if rep else 3) if s else 1
        if mode == 4:
            return (2 if rep else 3) if s else (1 if rep else 2)
        return 1 if rep else 3                      # mode 7

    # ---- the beam and the XDL (ch. 7, 8) ------------------------------------
    def _line_done(self, y):
        if y == OV_FIRST - 1:                       # the XDL is (re)read for line 8
            self._read_xdl()
        n = self.xdl_cost.get(y)
        if n and self.state:
            self.credit -= n
        if OV_FIRST <= y < OV_FIRST + VH:
            r = y - OV_FIRST
            a, k = self.ov_rows[r], self.ov_kind[r]
            if a is None:
                self.cur[r * VW:(r + 1) * VW] = bytes(VW)
                self.cur_rows[r] = None
            elif k[0] == 'g':
                self.cur[r * VW:(r + 1) * VW] = self.vram[a:a + VW]
                self.cur_rows[r] = ('g', k[1], bytes(self.vram[a:a + VW]), k[2])
            else:
                self.cur[r * VW:(r + 1) * VW] = bytes(VW)
                self.cur_rows[r] = self._text_row(a, k)
        if y == OV_FIRST + VH - 1:
            self.shown = bytes(self.cur)
            self.shown_rows = list(self.cur_rows)
            self.shown_pals = [bytes(q) for q in self.pals]
            self.frames += 1

    def _text_row(self, a, k):
        """a text mode scan line: 80 characters of 2 bytes (the character, its attribute),
        the font's row k[3] at k[2] * 2048, bit 7 the left pixel; a set bit is AT bits 6-0,
        a clear one AT bits 6-0 + 128 with AT bit 7, else transparent (ch. 8)"""
        v = self.vram
        font = k[2] * 2048 + k[3]
        pix, mask = bytearray(640), bytearray(640)
        for c in range(80):
            ch, at = v[a + 2 * c], v[a + 2 * c + 1]
            bits = v[font + ch * 8]
            fg = at & 0x7F
            for i in range(8):
                x = c * 8 + i
                if bits & (0x80 >> i):
                    pix[x], mask[x] = fg, 1
                elif at & 0x80:
                    pix[x], mask[x] = fg + 128, 1
        return ('t', k[1], bytes(pix), bytes(mask))

    def _read_xdl(self):
        """the XDL from XDL_ADR (ch. 7): per record the XDLC word, then its data in bit
        order (RPTL 1, OVADR 5, OVSCRL 2, CHBASE 1, MAPADR 5, MAPPAR 4, OVATT 2); RPTL
        lines repeat the settings; OV_STEP after every pixel line, after every 8th text
        line (the font rows from OV_VSCROLL); XDLC_END ends it"""
        rows, kinds, cost = [None] * VH, [None] * VH, {}
        if self.video_control & 1:
            v = self.vram
            p = self.xdl_adr
            y = 0
            on = None
            base, step = 0, VW
            chbase = frow = pal = 0
            mon, madr, mstep, mpar, mrow = False, 0, 0, (0, 0, 7, 7), 0
            while y < VH:
                start = p
                c = v[p] | v[p + 1] << 8
                p += 2
                rpt = 0
                if c & 0x20:
                    rpt = v[p]
                    p += 1
                if c & 0x40:
                    base = v[p] | v[p + 1] << 8 | (v[p + 2] & 7) << 16
                    step = (v[p + 3] | v[p + 4] << 8) & 0xFFF
                    p += 5
                if c & 0x80:
                    frow = v[p + 1] & 7
                    p += 2
                if c & 0x100:
                    chbase = v[p]
                    p += 1
                if c & 0x08:            # MAP_ON / MAP_OFF (ch. 7)
                    mon = True
                if c & 0x10:
                    mon = False
                if c & 0x200:           # MAPADR: its cells' rows, the step between them
                    madr = v[p] | v[p + 1] << 8 | (v[p + 2] & 7) << 16
                    mstep = (v[p + 3] | v[p + 4] << 8) & 0xFFF
                    p += 5
                    mrow = None
                if c & 0x400:           # MAPPAR: h / v scroll, a cell's width - 1, height - 1
                    mpar = (v[p], v[p + 1], v[p + 2], v[p + 3])
                    p += 4
                    mrow = None
                if c & 0x800:
                    pal = (v[p] >> 4) & 3
                    p += 2
                cost[OV_FIRST - 1 + y] = p - start
                ov = c & 7              # TM_ON 1, GM_ON 2, OFF 4; more than one bit: off
                on = 'g' if ov == 2 else 't' if ov == 1 else None if ov else on
                for _ in range(rpt + 1):
                    if y >= VH:
                        break
                    rows[y] = base if on else None
                    if on == 'g':
                        mp = None
                        if mon:                 # the attribute map: a cell's byte 3 bits 4-5 its palette
                            if mrow is None:
                                mrow, mline = madr, mpar[1] & 31
                            cw = mpar[2] + 1
                            mp = bytes((v[mrow + (x // cw) * 4 + 3] >> 4) & 3 for x in range(VW))
                            mline += 1
                            if mline > mpar[3]:
                                mline = 0
                                mrow += mstep
                        kinds[y] = ('g', pal, mp)
                        base += step
                    elif on == 't':
                        kinds[y] = ('t', pal, chbase, frow)
                        frow = (frow + 1) & 7
                        if frow == 0:
                            base += step
                    y += 1
                if c & 0x8000:
                    break
        self.ov_rows, self.ov_kind, self.xdl_cost = rows, kinds, cost

    # ---- pictures -----------------------------------------------------------
    def screenshot(self, path, palette_path=None, scale=1, frame=None):
        """the frame the beam showed, as the VBXE shows it: every line in its mode and
        palette, the text mode's 640 pixels (the HUD) -- 640 x 480 PNG.  `frame` (a
        tool's own 320 x 240 index buffer): drawn with palette 1."""
        if frame is not None:
            rows = [('g', 1, frame[r * VW:(r + 1) * VW]) for r in range(VH)]
            pals = [bytes(q) for q in self.pals]
        else:
            rows, pals = self.shown_rows, self.shown_pals
            if rows is None or not self.beam:       # (no frame shown / the beam off: the lines now)
                self._read_xdl()
                rows = []
                for r in range(VH):
                    a, k = self.ov_rows[r], self.ov_kind[r]
                    rows.append(None if a is None else ('g', k[1], bytes(self.vram[a:a + VW]), k[2])
                                if k[0] == 'g' else self._text_row(a, k))
                pals = [bytes(q) for q in self.pals]
        rgb = bytearray()
        for row in rows:
            line = bytearray(640 * 3)               # (no overlay / transparent: black)
            if row is not None and row[0] == 'g':
                pl = pals[row[1]]
                mp = row[3] if len(row) > 3 else None
                for x in range(VW):
                    if mp:
                        pl = pals[mp[x]]
                    i = row[2][x] * 3
                    line[x * 6:x * 6 + 3] = line[x * 6 + 3:x * 6 + 6] = pl[i:i + 3]
            elif row is not None:
                pl = pals[row[1]]
                for x in range(640):
                    if row[3][x]:
                        i = row[2][x] * 3
                        line[x * 3:x * 3 + 3] = pl[i:i + 3]
            rgb += line + line
        from vbxe_export import write_png
        write_png(path, 640, VH * 2, bytes(rgb))

PALETTE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       'build', 'assets', 'palette.bin')

STICK0, STRIG0, CH = 0x0278, 0x0284, 0x02FC
ST_CENTER, ST_LEFT, ST_RIGHT, ST_UP, ST_DOWN = 0x0F, 0x0B, 0x07, 0x0E, 0x0D
KEY_Z, KEY_X, KEY_NONE = 0x17, 0x16, 0xFF      # zoom out / in / no key
KEY_C = 0x12                                    # the camera
# ANTIC with DMACTL = 0 still refreshes memory: cycles 25, 29 .. 57 of every
# line (Altirra antic.cpp ATAnticSetRefreshCycles) -- the CPU runs on the other
# 105.  FREE[k] = the machine cycle of the line's k-th CPU cycle.
REFRESH = set(range(25, 61, 4))
FREE = [c for c in range(114) if c not in REFRESH]
FREE_BEFORE = [sum(1 for f in FREE if f < c) for c in range(115)]   # CPU cycles before machine cycle c
CPU_LINE = len(FREE)            # 105
VBI_LINE, VBI_CYCLE = 248, 8    # NMI asserted at cycle 8 of line 248 (antic.cpp), taken 2 cycles later at the earliest


def _poly17():
    """POKEY's 17-bit polynomial counter (AUDCTL bit 7 clear), one step a machine cycle:
    RANDOM reads its top 8 bits -- the value the game sees at that cycle"""
    t, p = bytearray(131071), 0x1FFFF
    for i in range(131071):
        t[i] = (p >> 9) & 0xFF
        p = (p >> 1) | (((p ^ (p >> 5)) & 1) << 16)
    return bytes(t)


POLY17 = _poly17()


def machine_time(cyc):
    """CPU cycles since power-on -> machine cycles (114 a line)."""
    line, k = divmod(cyc, CPU_LINE)
    return line * 114 + FREE[k]


def cpu_cycle_at(mt):
    """the first CPU cycle count at or after machine cycle mt."""
    line, c = divmod(mt, 114)
    return line * CPU_LINE + FREE_BEFORE[c]


class Game:
    def __init__(self, xex):
        lab = os.path.splitext(xex)[0] + '.lab'
        self.cpu = CPU()
        self.labels = load_labels(lab)
        self.L = self.labels
        m = self.cpu.mem
        m[0xD01F] = 0x07        # CONSOL: no console key pressed
        m[0xD20F] = 0xFF        # SKSTAT: no SHIFT, no key
        m[0x022F] = 0x22        # SDMCTL as the OS leaves it
        m[0xD301] = 0xFF        # PORTB as the OS leaves it: the OS ROM in, BASIC off
        self.bsel = 0
        self.vlog = []          # (bank, addr, value) for every $3000-$3FFF write
        self.logging = False
        self.vx = VbxeSim()     # VRAM + window + blitter + beam (VbxeSim above)
        if os.environ.get('SIM_RAMFILL'):   # RAM and VRAM as after power-on (not 0): what the
            import random                   #   game reads before it writes shows (seeded)
            rnd = random.Random(int(os.environ['SIM_RAMFILL']))
            m[0x80:0x100] = bytes(rnd.randrange(256) for _ in range(0x80))
            m[0x480:0xC000] = bytes(rnd.randrange(256) for _ in range(0xC000 - 0x480))
            m[0xC000:0xD000] = bytes(rnd.randrange(256) for _ in range(0x1000))   # the RAM under
            m[0xD800:0xFFFA] = bytes(rnd.randrange(256) for _ in range(0xFFFA - 0xD800))   #   the OS ROM
            self.vx.vram[:] = bytes(rnd.randrange(256) for _ in range(len(self.vx.vram)))
        self.stick = ST_CENTER  # what PORTA / TRIG0 read: the VBI copies them
        self.trig = 1
        cpu = self.cpu
        vx = self.vx
        vx.pc = lambda: cpu.pc
        self._os_stubs(m)
        self.vbl_n = 0          # VBIs so far
        self.vbl_next = self._vbl_cycle(0)
        self.tim_next = None    # POKEY timer 1: its next underflow (CPU cycles)
        cpu.next_event = self.vbl_next
        cpu.on_event = self._event

        def t():                # machine time (the refresh cycles counted in)
            return machine_time(cpu.cycles)

        code_banks = [self.labels[k] for k in ('AI_BANK', 'CU_BANK', 'AI2_BANK', 'AI3_BANK', 'CE_BANK') if k in self.labels]   # code run in the window
        wt_banks = [self.labels[k] for k in ('CE_BANK',) if k in self.labels]   # ... whose BCB lists the blitter reads: written through
        if 'SIM_BANK' in self.labels:   # sim_shot's table copies: no blit there either -- mirrored too
            code_banks += [self.labels['SIM_BANK'], self.labels['SIM_BANK'] + 1]
        self.mirror = None          # (base, RAM saved): code run from the window (aiv.asm)

        def remap():
            """MEMAC-A moved / resized / rebanked: the CPU's ranges; a code bank (the
            AI's, the cushion model's) also copied into mem (the CPU fetches opcodes from mem)"""
            if self.mirror is not None:
                b0, saved, v0, live = self.mirror
                if live:                    # (MEMAC-B on: the window's writes went to VRAM
                    vx.vram[v0:v0 + len(saved)] = m[b0:b0 + len(saved)]   #   itself, the copy is stale)
                m[b0:b0 + len(saved)] = saved
                self.mirror = None
            w = vx.window()
            lo, hi = (0x3000, 0x3FFF) if w is None else (w[0], w[0] + w[1] - 1)
            if self.memb & 0x80:
                cpu.rd_range = (min(lo, 0x4000), 0x7FFF, rd_ab)
                cpu.wr_range = (min(lo, 0x4000), 0x7FFF, wr_ab)
            else:
                cpu.rd_range = (lo, hi, rd_win)
                cpu.wr_range = (lo, hi, wr_win)
            self.win_lo, self.win_hi = lo, hi
            if w is not None and any(w[2] >> 12 == cb & ~((w[1] >> 12) - 1) for cb in code_banks):
                self.mirror = (w[0], bytes(m[w[0]:w[0] + w[1]]), w[2], not self.memb & 0x80)
                m[w[0]:w[0] + w[1]] = bytes(vx.vram[w[2]:w[2] + w[1]])
                if not self.memb & 0x80:    # the mirror IS the window (no blit touches the
                    cpu.rd_range = None     #   AI's banks): reads and writes in mem, the
                    cpu.wr_range = None     #   writes back to VRAM when it is unmapped
                    if any(w[2] >> 12 == cb & ~((w[1] >> 12) - 1) for cb in wt_banks):
                        cpu.wr_range = (lo, hi, wr_wt)   # (century.asm: its lists, read by the blitter)

        def wr_bsel(v):
            self.bsel = v
            vx.set_bsel(v)
            remap()
        self.remap = remap

        def wr_mactl(v):
            vx.set_mactl(v)
            remap()

        def wr_win(a, v):
            vx.win_write(a, v, m, t())
            # pixel writes only: the BCB templates (bank 0, $3100-$3134) are
            # captured as a whole when the blitter is started
            if self.logging and not (self.bsel == 0x80 and 0x3100 <= a <= 0x3134):
                self.vlog.append((self.bsel, a, v))

        def rd_win(a):
            return vx.win_read(a, m, t())

        def wr_wt(a, v):
            m[a] = v
            wr_win(a, v)

        def wr_blit(v):
            idle = vx.busy(t()) == 0
            if v & 1 and idle and self.logging:
                self.blits.append((len(self.vlog), vx.bcb(vx.bl_adr)))
            vx.start(v, t())

        def wr_vc(v):
            vx.wr_video_control(v, t())

        def wr_bladr(i):
            def f(v):
                vx.bl_adr = (vx.bl_adr & ~(0xFF << 8 * i)) | (v << 8 * i)
            return f

        def wr_xdladr(i):
            def f(v):
                vx.xdl_adr = (vx.xdl_adr & ~(0xFF << 8 * i)) | (v << 8 * i)
            return f

        cpu.rd_hooks[0xD20A] = lambda: POLY17[t() % 131071]  # POKEY RANDOM, as the chip: 1:1 with the game
        cpu.rd_hooks[0xD640] = lambda: 0x10                   # CORE_TYPE: FX
        cpu.rd_hooks[0xD641] = lambda: 0x27                   # CORE_REVISION 1.27
        cpu.rd_hooks[0xD653] = lambda: vx.busy(t())           # BLITTER_BUSY
        cpu.rd_hooks[0xD650] = lambda: (vx.advance(t()), vx.coll)[1]   # BLT_COLLISION_CODE
        cpu.wr_hooks[0xD640] = wr_vc
        cpu.wr_hooks[0xD653] = wr_blit
        cpu.wr_hooks[0xD65F] = wr_bsel
        cpu.wr_hooks[0xD65E] = wr_mactl
        cpu.rd_hooks[0xD65F] = lambda: vx.bsel_raw      # MEMAC-A reads back (manual 1.27 ch. 6:
        cpu.rd_hooks[0xD65E] = lambda: vx.ma_ctl        #   only MEMAC_B_CONTROL is write-only)
        for i in range(3):
            cpu.wr_hooks[0xD650 + i] = wr_bladr(i)
            cpu.wr_hooks[0xD641 + i] = wr_xdladr(i)
        cpu.rd_hooks[0xD300] = lambda: 0xF0 | self.stick      # PORTA: stick 0 low nibble
        cpu.rd_hooks[0xD010] = lambda: self.trig              # TRIG0
        def vcount():           # from cycle 111 the next line's (antic.cpp)
            line, x = divmod(t(), 114)
            y = line % 312
            if x >= 111:
                y += 1
                if x >= 112 and y >= 312:
                    y = 0
            return y >> 1
        cpu.rd_hooks[0xD40B] = vcount
        # POKEY timer 1 and its IRQ, volume-only AUDC1 logged (pokey.cpp): the
        # 64 kHz clock ticks every 28 machine cycles (free running); STIMER
        # loads AUDF1+1, the timer underflows on the (AUDF1+1)th tick after it
        # and reloads; 1.79 MHz (AUDCTL bit 6): AUDF1+4 cycles.  IRQST bits are
        # active low; IRQEN clears the status of every disabled source.
        self.audf1, self.audctl, self.irqen, self.irqst = 0, 0, 0xC0, 0xFF
        m[0x0010] = 0xC0        # POKMSK = IRQEN = $C0 as the XL OS boots (break key, keyboard)
        self.audc_log = []      # (machine cycle, channel 0..3, AUDC value)
        def tim_period():
            return self.audf1 + 4 if self.audctl & 0x40 else 28 * (self.audf1 + 1)
        def tim_sched(mt):
            self.tim_mt = mt
            self.tim_next = cpu_cycle_at(mt)
            cpu.next_event = min(self.vbl_next, self.tim_next)
        def wr_stimer(v):
            now = t()
            if self.audctl & 0x40:
                tim_sched(now + self.audf1 + 4)
            else:
                tim_sched((now // 28 + 1 + self.audf1) * 28)
        def irq_line():         # the CPU's IRQ input: POKEY's sources or the VBXE blitter's
            cpu.irq_line = bool(self.irqen & ~self.irqst & 0xFF) or bool(vx.irqf)
        self._irq_line = irq_line
        vx.on_irq = irq_line
        def wr_irqen(v):
            self.irqen = v
            self.irqst |= ~v & 0xF7
            irq_line()
        def wr_audf1(v):
            self.audf1 = v
        def wr_audctl(v):
            self.audctl = v
        def wr_audc(ch):
            def f(v):
                self.audc_log.append((t(), ch, v))
            return f
        self._tim_sched, self._tim_period = tim_sched, tim_period
        cpu.wr_hooks[0xD200] = wr_audf1
        for ch in range(4):
            cpu.wr_hooks[0xD201 + 2 * ch] = wr_audc(ch)
        cpu.wr_hooks[0xD208] = wr_audctl
        cpu.wr_hooks[0xD209] = wr_stimer
        cpu.wr_hooks[0xD20E] = wr_irqen
        cpu.rd_hooks[0xD20E] = lambda: self.irqst
        cpu.irq_vector = self.OS_IRQ
        # PORTB bit 0 (XL/XE): 1 the OS ROM at $C000-$CFFF / $D800-$FFFF, 0 the RAM
        # under it -- mem holds whichever is in, `under` the other (the I/O page is
        # never swapped); the ROM out: NMI and IRQ through the RAM's $FFFA / $FFFE
        self.os_on = True
        self.under = bytearray(0x4000)
        self.nmien = 0x40               # NMIEN as the OS leaves it: the VBI on
        def wr_portb(v):
            m[0xD301] = v
            on = bool(v & 1)
            if on != self.os_on:
                for lo, hi in ((0xC000, 0xD000), (0xD800, 0x10000)):
                    cur = bytes(m[lo:hi])
                    m[lo:hi] = self.under[lo - 0xC000:hi - 0xC000]
                    self.under[lo - 0xC000:hi - 0xC000] = cur
                self.os_on = on
            cpu.irq_vector = self.OS_IRQ if on else m[0xFFFE] | m[0xFFFF] << 8
        cpu.wr_hooks[0xD301] = wr_portb
        def wr_nmien(v):
            self.nmien = v
        cpu.wr_hooks[0xD40E] = wr_nmien
        # NMIST / NMIRES ($D40F, Altirra antic.cpp): a VBI sets bit 6 and clears bit 7,
        # NMIRES puts it back to $1F (the unused bits read 1)
        self.nmist = 0x1F
        cpu.rd_hooks[0xD40F] = lambda: self.nmist
        def wr_nmires(v):
            self.nmist = 0x1F
        cpu.wr_hooks[0xD40F] = wr_nmires
        cpu.wr_range = (0x3000, 0x3FFF, wr_win)
        cpu.rd_range = (0x3000, 0x3FFF, rd_win)
        # MEMAC-B (manual 1.27 ch. 6): $4000-$7FFF, 16 KB banks, MEMB write-only
        # (bit 7 CPU on, bits 0-4 the bank); a CPU access costs the blitter a cycle
        def rd_ab(a):
            if a < 0x4000:
                return rd_win(a) if self.win_lo <= a <= self.win_hi else m[a]
            vx.advance(t())
            vx.credit -= 1
            return vx.vram[(self.memb & 31) << 14 | a & 0x3FFF]
        def wr_ab(a, v):
            if a < 0x4000:
                return wr_win(a, v) if self.win_lo <= a <= self.win_hi else None
            vx.advance(t())
            vx.credit -= 1
            vx.vram[(self.memb & 31) << 14 | a & 0x3FFF] = v
        def wr_memb(v):
            self.memb = v
            remap()
        self.memb = 0
        self.win_lo, self.win_hi = 0x3000, 0x3FFF
        cpu.wr_hooks[0xD65D] = wr_memb
        # chapter 5 / 10 / 12 registers: IRQ_CONTROL / IRQ_STATUS, FEATURE_CONTROL,
        # COLMASK, COLCLR / COLDETECT
        cpu.wr_hooks[0xD654] = lambda v: vx.wr_irq_control(v, t())
        cpu.rd_hooks[0xD654] = lambda: vx.rd_irq_status(t())
        cpu.wr_hooks[0xD644] = vx.wr_csel     # the palettes: CSEL, PSEL, CR, CG, CB
        cpu.wr_hooks[0xD645] = vx.wr_psel
        cpu.wr_hooks[0xD646] = vx.wr_cr
        cpu.wr_hooks[0xD647] = vx.wr_cg
        cpu.wr_hooks[0xD648] = vx.wr_cb
        cpu.wr_hooks[0xD64B] = vx.wr_feature
        cpu.rd_hooks[0xD64B] = lambda: vx.feature
        cpu.wr_hooks[0xD649] = lambda v: setattr(vx, 'colmask', v)
        cpu.wr_hooks[0xD64A] = lambda v: setattr(vx, 'coldetect', 0)
        cpu.rd_hooks[0xD64A] = lambda: vx.coldetect
        # the registers are decoded without address bit 5: $D660-$D67F mirror $D640-$D65F
        for a in range(0xD640, 0xD660):
            if a in cpu.wr_hooks:
                cpu.wr_hooks[a + 0x20] = cpu.wr_hooks[a]
            if a in cpu.rd_hooks:
                cpu.rd_hooks[a + 0x20] = cpu.rd_hooks[a]
        if os.environ.get('VBXE_D7'):   # VBXE at $D740: $D6xx is then an empty bus ($FF)
            for a in range(0xD600, 0xD700):
                for hk in (cpu.wr_hooks, cpu.rd_hooks):
                    if a in hk:
                        hk[a + 0x100] = hk.pop(a)
                cpu.rd_hooks[a] = lambda: 0xFF
                cpu.wr_hooks[a] = lambda v: None
        self.blits = []
        self.t = t
        # the disk (build/snookerVBXE.atr, tools/make_atr.py): SIOV reads its sectors (_sio)
        atr = os.path.join(os.path.dirname(xex), 'snookerVBXE.atr')
        self.atr = open(atr, 'rb').read() if os.path.exists(atr) else None
        cpu.wr_hooks[0xD1F0] = lambda v: self._sio()
        # load last: the INI hooks stream views.bin into VRAM through the window
        self.run = self._load(xex, m)
        if 'SND_PLAY' in self.L and not os.environ.get('SIM_SOUND'):   # no sounds: their timer IRQ (SIM_SOUND=1: kept)
            m[self.L['SND_PLAY']] = 0x60  #   only slows the simulation (rts)

    def _load(self, xex, m):
        """load_xex with its INI hooks run in the CPU (seconds: every VRAM byte goes
        through the window) -- or, this very .xex loaded before, the machine as that
        load left it (tools/out/xexcache/, keyed by the .xex's bytes): the same state"""
        import pickle
        cpu, vx = self.cpu, self.vx
        here = os.path.dirname(os.path.abspath(__file__))   # (the simulator's own code in the key:
        key = hashlib.sha1(os.environ.get('SIM_RAMFILL', '').encode() + open(xex, 'rb').read() + (self.atr or b'') + open(os.path.join(here, 'asm_bench.py'), 'rb').read()
                           + open(os.path.join(here, 'sim6502.py'), 'rb').read()).hexdigest()[:20]   #   a changed one loads anew)
        d = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out', 'xexcache')
        path = os.path.join(d, key + '.pkl')
        objs = {'game': self, 'cpu': cpu, 'vx': vx}
        if os.path.exists(path):
            st = pickle.load(open(path, 'rb'))
            for name, fields in st['objs'].items():
                o = objs[name]
                for k, v in fields.items():
                    cur = o.__dict__.get(k)
                    if hasattr(cur, '__setitem__') and hasattr(cur, '__len__') and not isinstance(cur, (dict, list))                             and len(cur) == len(v):
                        cur[:] = v              # (in place: the hooks hold these arrays)
                    else:
                        setattr(o, k, v)
            self.remap()
            return st['run']
        # the disk (tools/make_atr.py: the XEX holds the code alone, the VRAM is on it):
        # booted as the OS boots it; else (no disk) the XEX's own load
        run = self._load_atr(m) if self.atr else load_xex(xex, m, on_init=lambda a: cpu.call(a))
        keep = {}
        for name, o in objs.items():
            f = {}
            for k, v in o.__dict__.items():
                if k in ('L', 'labels', 'cpu', 'vx') or callable(v) or (name == 'cpu' and k[0] == '_'):
                    continue            # (the CPU's _np is a view of mem, _sig / _slow / _regs caches)
                try:
                    pickle.dumps(v)
                except Exception:
                    continue
                f[k] = v
            keep[name] = f
        os.makedirs(d, exist_ok=True)
        with open(path + '.tmp', 'wb') as fh:
            pickle.dump({'run': run, 'objs': keep}, fh, protocol=pickle.HIGHEST_PROTOCOL)
        os.replace(path + '.tmp', path)
        return run

    def _load_atr(self, m):
        """the ATR booted as the OS boots it: its boot sectors to their load address,
        entered at + 6 (src/atrboot.asm reads the XEX through SIOV, runs its INIs); -> the
        RUN address, where the loader jumps"""
        a, cpu = self.atr, self.cpu
        n, ad = a[16 + 1], a[16 + 2] | a[16 + 3] << 8
        m[ad:ad + n * 128] = a[16:16 + n * 128]
        cpu.pc, cpu.s = ad + 6, 0xFD
        run = self.L['START']
        cpu.run_until(run, 4_000_000_000)
        return run

    def _sio(self):
        """SIOV on the disk (as Altirra's SIO patch: the transfer at once): the DCB's
        read of a 128-byte sector from the ATR -> DSTATS 1, else an error (NAK $8B)"""
        m = self.cpu.mem
        dev, unit, cmd = m[0x300], m[0x301], m[0x302]
        buf, n = m[0x304] | m[0x305] << 8, m[0x308] | m[0x309] << 8
        sec = m[0x30A] | m[0x30B] << 8
        off = 16 + (sec - 1) * 128
        if self.atr and dev == 0x31 and unit == 1 and cmd == 0x52 and n == 128 and 1 <= sec                 and off + 128 <= len(self.atr):
            m[buf:buf + 128] = self.atr[off:off + 128]
            m[0x303] = 1
            m[0x30] = 1                 # the OS's SIO zero page as it leaves it (STATUS, BUFRFL,
            m[0x38:0x3C] = bytes([0xFF]) * 4  #   RECVDN, XMTDON, CHKSNT $FF): the game's cells there
                                        #   (srtall $3B) start so, as on the machine
        else:
            m[0x303] = 0x8B

    # the OS as far as the game uses it: NMI -> (VVBLKI), SETVBV, SYSVBV, XITVBV
    OS_NMI, OS_SETVBV, OS_SYSVBV, OS_XITVBV = 0xE800, 0xE810, 0xE830, 0xE860
    OS_IRQ, OS_IIR = 0xE880, 0xE888     # IRQ: cld / jmp (VIMIRQ) (XL OS); IIR: the OS's own
    OS_SIO = 0xE890                     # SIOV: sta $D1F0 (_sio) / ldy DSTATS / rts

    def _os_stubs(self, m):
        def put(a, bs):
            m[a:a + len(bs)] = bytes(bs)
        put(0xE45C, [0x4C, self.OS_SETVBV & 255, self.OS_SETVBV >> 8,
                     0x4C, self.OS_SYSVBV & 255, self.OS_SYSVBV >> 8,
                     0x4C, self.OS_XITVBV & 255, self.OS_XITVBV >> 8])
        put(self.OS_NMI, [0x48, 0x8A, 0x48, 0x98, 0x48, 0x6C, 0x22, 0x02])   # pha txa pha tya pha jmp (VVBLKI)
        put(self.OS_SETVBV, [0xC9, 0x06, 0xD0, 0x07, 0x8C, 0x22, 0x02, 0x8E, 0x23, 0x02, 0x60,
                             0x8C, 0x24, 0x02, 0x8E, 0x25, 0x02, 0x60])       # A=6: VVBLKI, else VVBLKD
        put(self.OS_SYSVBV, [0xE6, 0x14, 0xD0, 0x06, 0xE6, 0x13, 0xD0, 0x02, 0xE6, 0x12,
                             0xAD, 0x00, 0xD3, 0x29, 0x0F, 0x8D, 0x78, 0x02,  # STICK0 = PORTA & $0F
                             0xAD, 0x10, 0xD0, 0x8D, 0x84, 0x02,              # STRIG0 = TRIG0
                             0x4C, 0x62, 0xE4])                               # RTCLOK, then XITVBV
        m[0x0278], m[0x0284] = 0x0F, 1                                        # as the OS boots them
        put(self.OS_XITVBV, [0x68, 0xA8, 0x68, 0xAA, 0x68, 0x40])             # pla tay pla tax pla rti
        m[0x0222], m[0x0223] = 0x5F, 0xE4                                     # VVBLKI = SYSVBV
        put(self.OS_IRQ, [0xD8, 0x6C, 0x16, 0x02])                            # cld / jmp (VIMIRQ)
        put(self.OS_IIR, [0x40])
        put(0xE459, [0x4C, self.OS_SIO & 255, self.OS_SIO >> 8])
        put(self.OS_SIO, [0x8D, 0xF0, 0xD1, 0xAC, 0x03, 0x03, 0x60])                                              # (no other IRQ source modelled)
        m[0x0216], m[0x0217] = self.OS_IIR & 255, self.OS_IIR >> 8

    def _vbl_cycle(self, n):
        """CPU cycle of the n-th VBI: scan line 248 of frame n."""
        return cpu_cycle_at((n * 312 + VBI_LINE) * 114 + VBI_CYCLE) + 2

    def _event(self):
        cpu = self.cpu
        if self.tim_next is not None and cpu.cycles >= self.tim_next:
            if self.irqen & 1:                  # timer 1 underflow: its IRQ
                self.irqst &= ~1
                self._irq_line()
            self._tim_sched(self.tim_mt + self._tim_period())
        if cpu.cycles >= self.vbl_next:
            self._vbl()
        cpu.next_event = self.vbl_next if self.tim_next is None else min(self.vbl_next, self.tim_next)

    def _vbl(self):
        cpu = self.cpu
        self.vx.advance(self.t())
        self.vbl_n += 1
        self.vbl_next = self._vbl_cycle(self.vbl_n)
        self.nmist = (self.nmist | 0x40) & ~0x80
        if self.nmien & 0x40:           # (NMIEN: the VBI on)
            cpu.nmi(self.OS_NMI if self.os_on else cpu.mem[0xFFFA] | cpu.mem[0xFFFB] << 8)

    def audio_out(self, rate=44100):
        """POKEY's output from the AUDC writes (volume-only channels: bit 4), as
        Altirra models it (ATAudio pokey.cpp UpdateMixTable): the volume bits
        weigh 0.12 / 0.26 / 0.56 / 1.12 (of 8.24) summed over the channels, x <
        0.14 linear, then 0.14 + (1 - e^(-2.85 (x - 0.14))) / 2.85, times 2.1;
        the AC coupling after it (tau 2.6 ms).  Every output sample is the
        level's mean over its time, to the machine cycle (the box filter Altirra
        renders with): a level held a few cycles between two AUDC writes counts
        for those cycles.  -> floats at `rate`, from the first write on."""
        import math
        bits = (0.12 / 8.24, 0.26 / 8.24, 0.56 / 8.24, 1.12 / 8.24)
        mt_rate = 1773447
        log = self.audc_log
        if not log:
            return []

        def level(vol):
            x = sum(((v >> b) & 1) * bits[b] for v in vol for b in range(4))
            return (x if x < 0.14 else 0.14 + (1 - math.exp(-2.85 * (x - 0.14))) / 2.85) * 2.1
        vol = [0, 0, 0, 0]
        t0, t1 = log[0][0], log[-1][0] + mt_rate // 50
        a = math.exp(-1 / (rate * 0.0025968510736001341))
        out, k, ref = [], 0, None
        cur, tc = level(vol), t0
        for i in range(int((t1 - t0) * rate / mt_rate)):
            te = t0 + (i + 1) * mt_rate / rate
            acc, ts = 0.0, t0 + i * mt_rate / rate
            while k < len(log) and log[k][0] <= te:
                tw, ch, v = log[k]
                acc += cur * (max(tw, ts) - ts)
                ts = max(tw, ts)
                vol[ch] = v & 15 if v & 0x10 else 0
                cur = level(vol)
                k += 1
            acc += cur * (te - ts)
            y = acc / (mt_rate / rate)
            if ref is None:
                ref = y
            out.append(y - ref)
            ref = y - (y - ref) * a
        return out

    def audio_wav(self, path, rate=44100):
        """audio_out -> a 16-bit WAV (normalised)"""
        import wave
        import struct
        y = self.audio_out(rate)
        if not y:
            return 0
        pk = max(abs(v) for v in y) or 1
        with wave.open(path, 'wb') as f:
            f.setnchannels(1); f.setsampwidth(2); f.setframerate(rate)
            f.writeframes(b''.join(struct.pack('<h', int(v / pk * 30000)) for v in y))
        return len(y)

    def screenshot(self, path):
        self.vx.screenshot(path, PALETTE)

    def where(self, pc):
        """pc -> 'label+off' (the nearest label at or below it)."""
        best = max(((a, n) for n, a in self.L.items() if a <= pc and 0x2000 <= a < 0xC000),
                   default=(0, '?'))
        return '%s+%d' % (best[1].lower(), pc - best[0])

    def race_report(self):
        """the blitter races seen so far, grouped: kind, place, count."""
        cnt = {}
        for kind, pc, det in self.vx.races:
            k = (kind, self.where(pc))
            cnt[k] = cnt.get(k, 0) + 1
        return sorted(cnt.items(), key=lambda kv: -kv[1])

    def snapshot(self):
        """the whole machine (RAM, VRAM, CPU, VBXE, timers): restore() puts it back --
        one init for many trials"""
        import copy
        cpu, vx = self.cpu, self.vx
        vd = {k: (bytearray(v) if isinstance(v, bytearray) else copy.copy(v))
              for k, v in vx.__dict__.items() if k != 'vram'}
        return (bytes(cpu.mem), bytes(vx.vram), (cpu.a, cpu.x, cpu.y, cpu.s, cpu.p, cpu.pc, cpu.cycles,
                cpu.next_event), vd, (self.vbl_n, self.vbl_next, self.tim_next, self.bsel, self.stick, self.trig, self.memb),
                (bytes(self.under), self.os_on, self.nmien, cpu.irq_vector, self.nmist))

    def restore(self, snap):
        import copy
        mem, vram, regs, vd, gs, osr = snap
        cpu, vx = self.cpu, self.vx
        cpu.mem[:] = mem
        vx.vram[:] = vram
        cpu.a, cpu.x, cpu.y, cpu.s, cpu.p, cpu.pc, cpu.cycles, cpu.next_event = regs
        for k, v in vd.items():
            setattr(vx, k, bytearray(v) if isinstance(v, bytearray) else copy.copy(v))
        self.vbl_n, self.vbl_next, self.tim_next, self.bsel, self.stick, self.trig, self.memb = gs
        u, self.os_on, self.nmien, cpu.irq_vector, self.nmist = osr
        self.under[:] = u
        self.mirror = None
        self.remap()

    def init(self):
        cpu = self.cpu
        cpu.pc = self.run
        cpu.s = 0xFF
        cpu.p &= ~0x04          # I = 0: DOS runs the program with IRQs on (the keyboard's)
        if 'MENU' in self.L and os.environ.get('MENU_PLAY'):   # the menu run: the pointer on PLAY, TRIG1 down
            cpu.run_until(self.L['MENU'], 100_000_000)
            m = cpu.mem
            m[self.L['MPX']], m[self.L['MPY']], m[self.L['MLB']] = 140, (self.L['TITLE_BARY'] + 1) // 2 + 2, 1
            cpu.rd_hooks[0xD011] = lambda: 0
        elif 'MENU' in self.L:            # the title's mouse menu: skipped (P1 vs P2)
            cpu.run_until(self.L['MENU'], 100_000_000)
            m = cpu.mem
            cpu.pc = (m[0x100 + ((cpu.s + 1) & 255)] | m[0x100 + ((cpu.s + 2) & 255)] << 8) + 1
            cpu.s = (cpu.s + 2) & 255
            m[self.L['OPP']] = 0
        cpu.run_until(self.L['FRAME'], 100_000_000)
        if 'INHAND' in self.L and not os.environ.get('BREAK_IN_HAND'):
            m = cpu.mem                     # the break-off from hand (in_hand: the D's middle) skipped:
            m[self.L['INHAND']] = 0         #   the cue back where setup_balls put it, the scenarios
            ib = self.L['INIT_BALLS']       #   aim at once from there
            m[self.L['RBX']:self.L['RBX'] + 3] = m[ib:ib + 3]
            m[self.L['RBY']:self.L['RBY'] + 3] = m[ib + 3:ib + 6]
            cpu.x = 0
            self.call('PLACE')
            if 'BO_I' in self.L:
                m[self.L['BO_I']] = 2       # (597, 709): the break-off place there (aihand.asm bo_*)
        return cpu.cycles

    def frame(self, stick=ST_CENTER, trig=1, key=0xFF):
        cpu = self.cpu
        m = cpu.mem
        self.stick = stick              # PORTA / TRIG0: the game's VBI copies them to STICK0 / STRIG0
        self.trig = trig
        if key != 0xFF:
            m[CH] = key                 # OS key code (the keyboard IRQ); Z/X zoom
        self.vlog = []
        self.blits = []
        self.logging = True
        c0 = cpu.cycles
        cpu.step()
        cpu.run_until(self.L['FRAME'], c0 + 400_000_000)   # (the AI plans within one frame: up to ~20 M)
        self.logging = False
        return cpu.cycles - c0

    def turn_frame(self, step=32):
        """one frame with the aim swung by step (>= FOLLOW_STEP): aim_follow
        redraws the table (set_angle) -- the cost of a view turn."""
        m, L = self.cpu.mem, self.L
        a = ((m[L['AIMANG']] | m[L['AIMANG'] + 1] << 8) + step) & 1023
        m[L['AIMANG']], m[L['AIMANG'] + 1] = a & 255, a >> 8
        return self.frame(ST_CENTER, 1)

    def view_at(self, ang):
        """aim so that the view turns to rang = ang, run frames until it has"""
        m, L = self.cpu.mem, self.L
        a = -ang & 1023
        m[L['AIMANG']], m[L['AIMANG'] + 1] = a & 255, a >> 8
        for _ in range(16):
            self.frame(ST_CENTER, 1)
            if m[L['RANG']] | m[L['RANG'] + 1] << 8 == ang & 1023:
                return
        raise RuntimeError('the view did not turn to %d' % ang)

    def vram_state(self):
        """Semantic view of one frame's VRAM traffic: the blits in order (each
        with the number of pixel writes that preceded it) and the FINAL value
        of every pixel written -- write order within a pass is irrelevant."""
        final = {}
        for b, a, v in self.vlog:
            final[(b, a)] = v
        return tuple(self.blits), tuple(sorted(final.items()))

    def digest(self):
        m = self.cpu.mem
        balls = bytes(m[0x1000:0x13C8])
        h = hashlib.sha1(balls)
        vh = hashlib.sha1()
        blits, final = self.vram_state()
        for n, bcb in blits:
            vh.update(bytes((n & 0xFF, n >> 8)) + bcb)
        vh.update(b'|')
        for (b, a), v in final:
            vh.update(bytes((b, a & 0xFF, a >> 8, v)))
        return h.hexdigest()[:12], vh.hexdigest()[:12], len(blits), len(final)

    def at_rest(self):
        return self.cpu.mem[self.L['AIMING']] == 1

    def positions(self):
        """[(x, y, on), ...] for the 22 balls in Q12 mm -- layout-independent:
        the AoS build (BALLS records) and the SoA build (X0/X1/X2 arrays)."""
        m, L = self.cpu.mem, self.L
        out = []
        if 'X0' in L:
            for i in range(22):
                x = m[L['X0'] + i] | (m[L['X1'] + i] << 8) | (m[L['X2'] + i] << 16)
                y = m[L['Y0'] + i] | (m[L['Y1'] + i] << 8) | (m[L['Y2'] + i] << 16)
                out.append((x, y, m[L['BON'] + i]))
        else:
            for i in range(22):
                b = 0x1000 + 32 * i
                x = m[b] | (m[b + 1] << 8) | (m[b + 2] << 16)
                y = m[b + 3] | (m[b + 4] << 8) | (m[b + 5] << 16)
                out.append((x, y, m[b + 23]))
        return out


SCENARIOS = {
    # (name): list of (frames, stick, trig) phases; 'rest' = run until balls stop.
    # cue (597,709) -> pack apex (2729,889): 2 frames right = 16/1024 turn = 5.6 deg
    'break': [(3, ST_CENTER, 1), (2, ST_RIGHT, 1), (47, ST_CENTER, 0), (1, ST_CENTER, 1),
              (140, ST_CENTER, 1)],
    'soft':  [(3, ST_CENTER, 1), (20, ST_RIGHT, 1), (6, ST_CENTER, 0), (1, ST_CENTER, 1),
              ('rest', ST_CENTER, 1)],
    'aim':   [(2, ST_CENTER, 1), (40, ST_LEFT, 1), (40, ST_RIGHT, 1), (10, ST_CENTER, 1)],
    'medium': [(3, ST_CENTER, 1), (1, ST_RIGHT, 1), (20, ST_CENTER, 0), (1, ST_CENTER, 1),
               ('rest', ST_CENTER, 1)],
    # turn the table two steps, zoom in (X), aim a bit, one soft shot
    'rotate': [(2, ST_CENTER, 1), (1, ST_UP, 1), (2, ST_CENTER, 1), (1, ST_UP, 1), (2, ST_CENTER, 1),
               (1, ST_CENTER, 1, KEY_X), (2, ST_CENTER, 1), (10, ST_RIGHT, 1), (4, ST_CENTER, 0),
               (1, ST_CENTER, 1), (60, ST_CENTER, 1)],
    'view45': [(2, ST_CENTER, 1), (1, ST_UP, 1), (2, ST_CENTER, 1), (1, ST_UP, 1), (3, ST_CENTER, 1)],
    'zoom':   [(2, ST_CENTER, 1), (1, ST_CENTER, 1, KEY_X), (3, ST_CENTER, 1)],
    # balls by the top cushion (y 1778 - 33 mm), the camera stepped by C (occl's cut)
    'occl':   [('place', {0: (500, 1745), 1: (200, 1750), 19: (1200, 1700)}), (2, ST_CENTER, 1),
               (1, ST_CENTER, 1, KEY_C), (3, ST_CENTER, 1)],
    'occl2':  [('place', {0: (60, 1735)}), ('aim', 63000), (2, ST_CENTER, 1),
               (1, ST_CENTER, 1, KEY_C), (2, ST_CENTER, 1), (1, ST_CENTER, 1, KEY_C), (3, ST_CENTER, 1)],
    'occl3':  [('place', {0: (500, 1745), 1: (200, 1750), 19: (1200, 1700)}), (2, ST_CENTER, 1),
               (6, ST_LEFT, 1), (3, ST_CENTER, 1)],
}


_AI = {}
_TRACE = None                           # a list: _ai_full logs the cue ball's run into it
BALLS = ['cue'] + ['r%d' % i for i in range(1, 16)] + ['yel', 'grn', 'brn', 'blu', 'pnk', 'blk']


def _bpos(m, L, b):
    return tuple(sum(m[L[n] + 0x20 * k + b] << 8 * k for k in range(3)) / 4096 for n in ('X0', 'Y0'))


def _ai_shot(task):
    """one computer shot (ai_bench's worker): the plan by ai_plan, then the ticks
    until the red is potted or stops -- the cue's roll after that changes nothing"""
    xex, opp, cue, red, noerr, seed = task
    if xex not in _AI:
        g = Game(xex)
        g.init()
        _AI[xex] = (g, g.snapshot())
    g, snap = _AI[xex]
    rnd = random.Random(seed)
    g.restore(snap)
    m, L, v = g.cpu.mem, g.L, g.vx.vram
    bank = L['AI_BANK']
    va = lambda name: (bank << 12) + L[name] - 0x2000
    full = red is None                  # the full rack, the cue ball at `cue`
    for b in range(22):
        if not full:
            m[L['BON'] + b] = 0
    for b, (x, y) in ((0, cue),) + (() if full else ((1, red),)):
        X, Y = int(x * 4096), int(y * 4096)
        m[L['BON'] + b] = 1
        for k in range(3):
            m[L['X0'] + 0x20 * k + b] = (X >> 8 * k) & 255
            m[L['Y0'] + 0x20 * k + b] = (Y >> 8 * k) & 255
    m[L['OPP']] = opp
    m[L['TURN']] = 1
    if noerr:
        for i in range(5):
            v[va('AI_ERR') + i] = 0
            v[va('AI_ERRL') + i] = 0
    g.cpu.wr(0xD65E, 0x2A)                  # the AI's 16 KB window (ai.asm)
    g.cpu.wr(0xD65F, 0x80 | bank)
    g.call('AI_PLAN')
    g.cpu.wr(0xD65E, 0x38)                  # the window back (the AI's cells to VRAM)
    g.cpu.wr(0xD65F, 0x80)
    if full:
        return _ai_full(g, m, L, v, va)
    pot = m[L['BT']] != 0xFF and m[L['BEST']] | m[L['BEST'] + 1] << 8 <=         v[va('AI_DML') + opp - 1] | v[va('AI_DMH') + opp - 1] << 8
    if not pot:
        return False, False
    t = m[L['TGT']] | m[L['TGT'] + 1] << 8
    m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
    m[L['TURN']] = 0                    # (aim_update's human path: dirx, diry only)
    m[0x0278], m[0x0284] = 15, 1
    g.cpu.wr(0xD65E, 0x38)
    g.cpu.wr(0xD65F, 0x80)
    g.call('AIM_UPDATE')
    m[L['PWR']:L['PWR'] + 3] = bytes(m[L['TPW']:L['TPW'] + 3])
    g.call('FIRE_CUE')
    hit = False
    for _ in range(8000):
        g.call('TICK_ALL')
        if not m[L['BON'] + 1]:
            return True, True
        if m[L['AWK'] + 1]:
            hit = True
        elif hit:
            break
        elif not m[L['AWK']]:
            break
    return True, False


def _ai_full(g, m, L, v, va):
    """the planned shot on the full table: (legal, potted) -- legal = the first ball
    hit is a red (the ball on) and the cue ball stays on the table"""
    t = m[L['TGT']] | m[L['TGT'] + 1] << 8
    m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
    m[L['TURN']] = 0
    m[0x0278], m[0x0284] = 15, 1
    g.cpu.wr(0xD65E, 0x38)
    g.cpu.wr(0xD65F, 0x80)
    g.call('AIM_UPDATE')
    m[L['PWR']:L['PWR'] + 3] = bytes(m[L['TPW']:L['TPW'] + 3])
    g.call('FIRE_CUE')
    first = None
    wall = False
    for _ in range(8000):
        if _TRACE is not None:
            asleep = [b for b in range(1, 22) if m[L['BON'] + b] and not m[L['AWK'] + b]]
        g.call('TICK_ALL')
        if first is None:
            for b in range(1, 22):
                if m[L['AWK'] + b]:
                    first = b
                    break
        if _TRACE is not None:              # the cue ball's cushions and the balls it hits
            x, y = _bpos(m, L, 0)
            w = x < 34 or x > 3535 or y < 34 or y > 1744
            if w and not wall:
                _TRACE.append('cushion (%d,%d)' % (x, y))
            wall = w
            for b in asleep:
                if m[L['AWK'] + b]:
                    bx, by = _bpos(m, L, b)
                    if (bx - x) ** 2 + (by - y) ** 2 < 60 ** 2:
                        _TRACE.append('%s (%d,%d)' % (BALLS[b], bx, by))
        if not any(m[L['AWK'] + i] for i in range(22)):
            break
    legal = first is not None and first < 16 and m[L['BON']] == 1
    if legal and v[va('SBEST')] | v[va('SBEST') + 1]:
        return True, ('safety',)        # (its end: sim_shot's, the real one -- bit-exact)
    if not legal:
        return False, (first, m[L['BON']] == 1, m[L['BT']], v[va('SBEST')] | v[va('SBEST') + 1] << 8)
    return True, any(m[L['BON'] + b] == 0 for b in range(1, 16))


def ai_calib(xex):
    """the safety model's tables from the game physics: a lone cue ball and one
    ball, 1 m apart, cut theta = 0..90 deg in 15s, at the 5 safety powers
    (aisafe.asm ai_spl) -- after the contact the cue ball's run (share g of what
    is left, D - 1 m, a ball rolls 2.16 v^2 m) and its turn from the aim (delta),
    the object ball's run (share h).  A run that reaches a cushion counts as the
    path to it + 2.16 v^2 of the speed it has there (endpt folds the rest).
    Prints them as aisafe.asm's ai_sg / ai_sh / ai_sdl / ai_sdh rows."""
    import math
    g = Game(xex)
    g.init()
    m, L = g.cpu.mem, g.L
    snap = g.snapshot()

    def pos(b):
        return (sum(m[L['X0'] + 0x20 * k + b] << 8 * k for k in range(3)) / 4096,
                sum(m[L['Y0'] + 0x20 * k + b] << 8 * k for k in range(3)) / 4096)

    def speed(b):                       # m/s from v.q12 (mm a tick, 200 ticks a second)
        s24 = lambda n: (lambda v: v - (1 << 24) if v & 0x800000 else v)(
            sum(m[L[n] + 0x20 * k + b] << 8 * k for k in range(3)))
        return math.hypot(s24('VX0'), s24('VY0')) / 4096 * 0.2

    def put(b, x, y):
        X, Y = int(x * 4096), int(y * 4096)
        m[L['BON'] + b] = 1
        for k in range(3):
            m[L['X0'] + 0x20 * k + b] = (X >> 8 * k) & 255
            m[L['Y0'] + 0x20 * k + b] = (Y >> 8 * k) & 255

    def wall(p):
        return p[0] < 34 or p[0] > 3535 or p[1] < 34 or p[1] > 1744   # (the bounce: R + 8 mm)
    t0 = time.time()
    rows = {'g': [], 'h': [], 'd': []}
    for p in (0x3800, 0x5000, 0x6800, 0x8100, 0x9A10):
        v0 = p / 20480
        D = 2160 * v0 * v0
        gs, hs, ds = [], [], []
        for th in range(0, 91, 15):
            g.restore(snap)
            for b in range(22):
                m[L['BON'] + b] = 0
            put(0, 300, 889)                    # the cue ball 1 m from the contact,
            sn = math.sin(math.radians(min(th, 88)))
            put(1, 300 + 1000 + 52.5 * math.cos(math.radians(th)), 889 + 52.5 * sn)
            m[L['AIMANG']] = m[L['AIMANG'] + 1] = m[L['AIMFRAC']] = 0   # aimed along +x
            m[L['TURN']] = 0
            m[0x0278], m[0x0284] = 15, 1
            g.call('AIM_UPDATE')
            m[L['PWR']], m[L['PWR'] + 1], m[L['PWR'] + 2] = p & 255, (p >> 8) & 255, p >> 16
            g.call('FIRE_CUE')
            c0 = None
            run = {0: [0.0, None, None], 1: [0.0, None, None]}   # path, end, speed left
            last = {0: pos(0), 1: pos(1)}
            for _ in range(8000):
                g.call('TICK_ALL')
                if c0 is None and m[L['AWK'] + 1]:
                    c0 = pos(0)
                    last[0] = c0
                for b in (0, 1):
                    if c0 is None or run[b][1] is not None:
                        continue
                    q = pos(b)
                    run[b][0] += math.hypot(q[0] - last[b][0], q[1] - last[b][1])
                    last[b] = q
                    if wall(q):
                        run[b][1], run[b][2] = q, speed(b)
                    elif not m[L['AWK'] + b]:
                        run[b][1], run[b][2] = q, 0.0
                if all(run[b][1] is not None for b in (0, 1)) or                         not any(m[L['AWK'] + i] for i in range(22)):
                    break
            da = max(D - 1000, 1)
            if c0 is None:
                gs.append(0); hs.append(0); ds.append(0)
                continue
            for b, o, out in ((0, c0, gs), (1, (300 + 1000 + 52.5 * math.cos(math.radians(th)),
                                                889 + 52.5 * sn), hs)):
                path, end, v1 = run[b]
                if end is None:
                    end, v1 = last[b], 0.0
                out.append(min(255, round(256 * (path + 2160 * v1 * v1) / da)))
            c1 = run[0][1] or last[0]
            ds.append(-math.atan2(c1[1] - c0[1], c1[0] - c0[0]) if c1 != c0 else 0.0)
        print('v %.2f m/s: g %s  h %s  delta (deg) %s' % (
            v0, gs, hs, [round(math.degrees(d)) for d in ds]))
        rows['g'].append(gs); rows['h'].append(hs)
        rows['d'].append([round(abs(d) * 32768 / math.pi) for d in ds])
    for name, key, f in (('ai_sg', 'g', '%d'), ('ai_sh', 'h', '%d')):
        for i, r in enumerate(rows[key]):
            print('%-7s dta %s' % (name if i == 0 else '', ', '.join(f % x for x in r)))
    for name, op in (('ai_sdl', '<'), ('ai_sdh', '>')):
        for i, r in enumerate(rows['d']):
            print('%-7s dta %s' % (name if i == 0 else '', ', '.join('%s%d' % (op, x) for x in r)))
    print('%.1f s' % (time.time() - t0))

def ai_bench(xex, n, seed=1):
    """the computer players (aiv.asm) over n random positions (the cue + one red):
    planned by ai_plan, played tick by tick in the game's own physics, all cores.
    Prints each player's pots with no aim error (the geometry and the power) and
    with his own."""
    import multiprocessing
    rnd = random.Random(seed)
    cases = []
    while len(cases) < n:
        c = (rnd.uniform(300, 3270), rnd.uniform(150, 1630))
        r = (rnd.uniform(300, 3270), rnd.uniform(150, 1630))
        if (c[0] - r[0]) ** 2 + (c[1] - r[1]) ** 2 > 250 ** 2:
            cases.append((c, r))
    names = ['Selby', 'Higgins', 'Robertson', 'Trump', "O'Sullivan"]
    runs = [(5, True)] + [(o, False) for o in (1, 2, 3, 4, 5)]
    tasks = [(xex, o, c, r, ne, k) for o, ne in runs for k, (c, r) in enumerate(cases)]
    fulls = []                                  # the full rack: the cue ball anywhere free
    while len(fulls) < n // 2:
        c = (rnd.uniform(300, 2400), rnd.uniform(100, 1680))
        if all((c[0] - x) ** 2 + (c[1] - y) ** 2 > 80 ** 2 for x, y in
               ((737, 889), (737, 597), (737, 1181), (1784, 889), (2676, 889), (3245, 889))):
            fulls.append(c)
    tasks += [(xex, o, c, None, False, k) for o in (1, 5) for k, c in enumerate(fulls)]
    t0 = time.time()
    with _pool() as pool:
        res = pool.map(_ai_shot, tasks, chunksize=4)
    nf = len(fulls)
    for j, o in enumerate((1, 5)):
        rr = res[len(runs) * n + j * nf:len(runs) * n + (j + 1) * nf]
        print('%-11s full rack: legal %2d of %d, a red potted %d' % (
            names[o - 1], sum(1 for a, _ in rr if a), nf,
            sum(1 for a, b in rr if a and b is True)))
        pe = sorted(b[1] for a, b in rr if a and isinstance(b, tuple))
        if pe:
            print('   safeties %d: the cue ball ends %d mm from the plan (median), %d (80 %%)'
                  % (len(pe), pe[len(pe) // 2], pe[len(pe) * 4 // 5]))
        for (a, b), c in zip(rr, fulls):
            if not a:
                print('   foul: cue at (%d, %d): first hit %s, cue on table %s, target %d, safety score %d'
                      % (c[0], c[1], b[0], b[1], b[2], b[3]))
    for j, (o, ne) in enumerate(runs):
        rr = res[j * n:(j + 1) * n]
        tried = sum(1 for a, _ in rr if a)
        potted = sum(1 for a, b in rr if b)
        print('%-11s %s: went for %2d of %d, potted %2d (%d %%)' % (
            names[o - 1], 'no error ' if ne else 'his error', tried, n, potted,
            100 * potted // max(tried, 1)))
    print('%.1f s' % (time.time() - t0))

def ai_safe(xex, n, opp=5, seed=3):
    """the safeties on the full rack: the cue ball at n places -> the plan (ball,
    power, the predicted cue ball end) vs where it really ends, and its run (the
    cushions, the balls it hits)"""
    global _TRACE
    rnd = random.Random(seed)
    for k in range(n):
        c = (rnd.uniform(300, 2400), rnd.uniform(100, 1680))
        _TRACE = []
        r = _ai_shot((xex, opp, c, None, False, k))
        g, _ = _AI[xex]
        m, L, v = g.cpu.mem, g.L, g.vx.vram
        va = lambda name: (L['AI_BANK'] << 12) + L[name] - 0x2000
        rd = lambda name, o=0: v[va(name) + o] | v[va(name) + o + 1] << 8
        e = _bpos(m, L, 0)
        print('cue (%4d,%4d) %-4s pwr %05X  end (%4d,%4d)  %s' % (
            c[0], c[1], BALLS[m[L['BT']]] if m[L['BT']] < 22 else '-',
            m[L['TPW']] | m[L['TPW'] + 1] << 8 | m[L['TPW'] + 2] << 16, e[0], e[1], 'legal' if r[0] else 'FOUL'))
        print('    ' + ', '.join(_TRACE))
    _TRACE = None


def ai_play_game(xex, opp, nshots, wait=0):
    """two computer players `opp` against each other, the game as it is -- the main
    loop, the VBI, the AI aiming with the stick and charging the power, the rules;
    nothing set but the players.  One line a shot, written when the next one is
    planned (the game's own record then: fcon the first ball hit, potl / potn what
    went down, cuein the cue ball down): who, the plan (POT / SAFE and its ball, '-'
    none found), the pack flags (aipos.asm cnset), what happened, where the cue ball
    is for the next shot."""
    g = Game(xex)
    g.init()
    m, L, v = g.cpu.mem, g.L, g.vx.vram
    va = lambda name: (L['AI_BANK'] << 12) + L[name] - 0x2000
    for _ in range(wait):                   # frames waited at the table before the players are set
        g.frame()                           #   (a person in the menu: RANDOM's phase moves on)
    m[L['OPP']] = opp
    m[L['PTY']] = m[L['PTY'] + 1] = opp
    nerve = v[va('AI_DML') + opp - 1] | v[va('AI_DMH') + opp - 1] << 8
    shots, f, t0, last, pl = 0, 0, time.time(), None, None

    def record():
        fc = m[L['FCON']]
        pots = [BALLS[m[L['POTL'] + i]] for i in range(m[L['POTN']])]
        return 'hit %-4s potted %-8s%s' % (BALLS[fc] if fc < 22 else '-', ' '.join(pots) or '-',
                                         ' cue down' if m[L['CUEIN']] else '')
    while shots < nshots and f < 200000:
        c0 = g.cpu.cycles
        st0 = m[L['AIST']]
        g.frame()
        f += 1
        if st0 == 0 and m[L['AIST']] == 1:     # a plan: the shot before it is over -- its line
            if last:
                shots += 1
                print('%2d %s | %s | next cue at (%4d,%4d)' % ((shots, last, record()) + _bpos(m, L, 0)))
            bt = m[L['BT']]
            last = 'P%d %-4s %-4s plan %4.1f s  pack cnst %d cnsp %d free %d' % (m[L['TURN']] + 1,
                'POT' if bt != 0xFF and (m[L['BEST']] | m[L['BEST'] + 1] << 8) <= nerve else 'SAFE',
                BALLS[bt] if bt < 22 else '-', (g.cpu.cycles - c0) / 1.77e6,
                v[va('CNST')], v[va('CNSP')], v[va('CNFR')])
    print('%d frames, %.0f s' % (f, time.time() - t0))


def ai_play(xex, opp, nshots, seed=1):
    """the computer plays its shots in the game (the main loop, the rules), both
    turns its own: per shot its plan (a pot or a safety), the ball on, what it hit
    first and what went down.  Fast: once planned the shot is fired as ai_run
    would (its aim, power and spin -- the stick's turning and the charge skipped),
    the balls run in the physics alone (no drawing), a frame then for the rules."""
    rnd = random.Random(seed)
    g = Game(xex)
    g.init()
    m, L, v = g.cpu.mem, g.L, g.vx.vram
    va = lambda name: (L['AI_BANK'] << 12) + L[name] - 0x2000
    rd = lambda name: v[va(name)] | v[va(name) + 1] << 8
    m[L['OPP']] = opp
    nerve = v[va('AI_DML') + opp - 1] | v[va('AI_DMH') + opp - 1] << 8
    shots, f, t0 = 0, 0, time.time()
    while shots < nshots and f < 4000:
        m[L['TURN']] = 1
        c0 = g.cpu.cycles
        g.frame()
        dc = g.cpu.cycles - c0                  # the frame's cycles: the plan's (1.77 MHz)
        f += 1
        if m[L['AIST']] != 1:                   # not planned this frame (in hand, the rules)
            continue
        bt = m[L['BT']]
        pot = bt != 0xFF and (m[L['BEST']] | m[L['BEST'] + 1] << 8) <= nerve
        before = [(m[L['BON'] + b], m[L['X2'] + b], m[L['Y2'] + b]) for b in range(22)]
        tpw = m[L['TPW']] | m[L['TPW'] + 1] << 8 | m[L['TPW'] + 2] << 16
        cut = ((m[L['TGT']] | m[L['TGT'] + 1] << 8) - rd('PHI') + 32768) % 65536 - 32768   # the pot's cut (65536 a turn)
        plan = '%-4s %-4s colour %d  cue (%4d,%4d) tip %d side %d pw %3d%% D %5d cut %3d %4.1f s' % (
            'POT' if pot else 'SAFE', BALLS[bt] if bt < 22 else '-', m[L['EXPCOL']], *_bpos(m, L, 0),
            m[L['SPIN']], m[L['SIDE']], tpw * 100 // 71680, rd('DD'), cut * 360 // 65536, dc / 1.77e6)   # (tip 0 screw .. 4 stun .. 8 follow)
        if not pot and bt != 0xFF:              # the safety list s3pick chose from
            s3 = va('S3R')
            print('   s3 sbest %d sbpsi %d: %s' % (rd('SBEST'), v[va('SBPSI')], '  '.join(
                '%s %d spi %02x' % (BALLS[v[s3 + 8 * i + 2]], v[s3 + 8 * i] | v[s3 + 8 * i + 1] << 8,
                                     v[s3 + 8 * i + 5]) for i in range(v[va('S3N')]))))
        t = m[L['TGT']] | m[L['TGT'] + 1] << 8                           # fired as ai_run would, at once
        m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
        m[L['TURN']] = 0                        # (aim_update's human path: dirx, diry only)
        m[0x0278], m[0x0284] = 15, 1
        g.cpu.wr(0xD65E, 0x38)
        g.cpu.wr(0xD65F, 0x80)
        g.call('AIM_UPDATE')
        m[L['TURN']] = 1
        m[L['PWR']:L['PWR'] + 3] = bytes(m[L['TPW']:L['TPW'] + 3])
        g.call('FIRE_CUE')
        shots += 1
        first = None
        for _ in range(20000):
            g.call('TICK_ALL')
            if first is None:
                first = next((b for b in range(1, 22) if m[L['AWK'] + b]), None)
            if not any(m[L['AWK'] + i] for i in range(22)):
                break
        m[L['WASMOV']] = 1                      # the next frame sees them stop: the rules
        pots = [BALLS[b] for b in range(22) if before[b][0] and not m[L['BON'] + b]]
        moved = sum(1 for b in range(1, 22) if b != bt and before[b][0] and m[L['BON'] + b]
                    and (m[L['X2'] + b], m[L['Y2'] + b]) != before[b][1:])   # others disturbed (16 mm)
        cx, cy = _bpos(m, L, 0)
        near = sum(1 for b in range(1, 22) if m[L['BON'] + b]                 # balls within 160 mm of the cue ball
                   and abs(_bpos(m, L, b)[0] - cx) + abs(_bpos(m, L, b)[1] - cy) < 160)
        print('%2d %s | hit %-4s potted %-8s moved %2d near %d  cue ends (%4d,%4d)' % (
            shots, plan, BALLS[first] if first else '-', ' '.join(pots) or '-', moved, near, cx, cy))
    print('%d frames, %.0f s' % (f, time.time() - t0))


def break_search(xex, coarse=True, at=None):
    """the opening shot from the D (the cue where the game puts it, or `at` = (x, y)
    mm: one of aihand.asm's bo_* places): thin on an end red of the pack's near
    side (the green side below the centre line, the yellow side above: mirrored),
    the cue ball off the top and side cushions back to the baulk cushion -- a grid
    of contacts, speeds and side, each played in the game's physics; prints the
    best (the cue ball nearest the baulk cushion, the fewest reds sent out, no
    foul) as ai2.asm's opening (aim 1/64 units, power), then the aims around the
    best one: bo_al is the first of 8 in a row that end on the cushion (opening
    adds RANDOM & 7)"""
    import math
    g = Game(xex)
    g.init()
    m, L = g.cpu.mem, g.L
    if at:
        for k in range(3):
            m[L['X0'] + 0x20 * k] = (int(at[0] * 4096) >> 8 * k) & 255
            m[L['Y0'] + 0x20 * k] = (int(at[1] * 4096) >> 8 * k) & 255
    snap = g.snapshot()
    cue = _bpos(m, L, 0)
    reds0 = {b: _bpos(m, L, b) for b in range(1, 16)}
    R = 26.25
    lo = cue[1] < 889                   # below the centre line: the green-side end reds, the
    ends = (11, 7, 4) if lo else (15, 10, 6)   # ghost on their low-y side; above: mirrored
    sgn = -1 if lo else 1

    def play(t, pw, side):
        g.restore(snap)
        m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
        m[L['TURN']] = 0
        m[0x0278], m[0x0284] = 15, 1
        g.cpu.wr(0xD65E, 0x38)
        g.cpu.wr(0xD65F, 0x80)
        g.call('AIM_UPDATE')
        m[L['PWR']:L['PWR'] + 3] = bytes([pw & 255, (pw >> 8) & 255, pw >> 16])
        m[L['SPIN']], m[L['SIDE']] = 4, side
        g.call('FIRE_CUE')
        first = None
        for _ in range(6000):
            g.call('TICK_ALL')
            if first is None:
                first = next((b for b in range(1, 22) if m[L['AWK'] + b]), None)
            if not any(m[L['AWK'] + i] for i in range(22)):
                break
        e = _bpos(m, L, 0)
        moved = sum(1 for b in range(1, 16) if not m[L['BON'] + b] or
                    math.hypot(_bpos(m, L, b)[0] - reds0[b][0], _bpos(m, L, b)[1] - reds0[b][1]) > 60)
        legal = first is not None and first < 16 and m[L['BON']] == 1
        cols = all(m[L['BON'] + b] for b in range(16, 22))
        return legal and cols, e, moved, first
    res = []
    t0 = time.time()
    for tb in (ends if coarse else ends[:1]):
        bx, by = reds0[tb]
        for f in ([0.80, 0.86, 0.92, 0.97] if coarse else [0.90 + 0.01 * i for i in range(10)]):
            # the ghost: off the red's centre by f 2R on its outer side, square to the line
            a0 = math.atan2(by - cue[1], bx - cue[0])
            d = math.hypot(bx - cue[0], by - cue[1])
            a = a0 + sgn * math.asin(min(0.999, f * 2 * R / d))
            t = round(a / (2 * math.pi) * 65536) & 0xFFFF
            for pw in ((0x9000, 0xB000, 0xD000, 0xF000) if coarse else range(0xC000, 0xE800, 0x800)):
                for side in ((4,) if coarse else (2, 3, 4, 5, 6)):
                    ok, e, moved, first = play(t, pw, side)
                    score = e[0] + 150 * moved + (0 if ok else 100000)
                    res.append((score, tb, round(f, 2), t, pw, side, e, moved, first))
    res.sort()
    print('cue at (%d, %d)' % (round(cue[0]), round(cue[1])))
    for r in res[:8]:
        print('score %6d  red %2d f %.2f  aim %5d  pwr %05X side %d  cue ends (%4d,%4d)  reds moved %d  first %s'
              % (r[0], r[1], r[2], r[3], r[4], r[5], r[6][0], r[6][1], r[7], BALLS[r[8]] if r[8] else '-'))
    best = res[0]
    print('aims about the best (pwr %05X side %d): aim -> cue x, y, reds moved; * = on the baulk cushion'
          % (best[4], best[5]))
    row = []
    for t in range(best[3] - 10, best[3] + 14):
        ok, e, moved, first = play(t & 0xFFFF, best[4], best[5])
        good = ok and e[0] < 90
        row.append('%d%s(%d,%d,%d)' % (t, '*' if good else ' ', e[0], e[1], moved))
    print('  '.join(row))
    print('%d shots, %.0f s' % (len(res) + 24, time.time() - t0))


def safe_search(xex, shot=2, seed=1):
    """a safety searched in the game's physics: the position before ai_play's shot
    `shot` (O'Sullivan both sides); every red, thin on either side (cuts 55..85
    deg), powers $A000..$F000, side 2 / 4 / 6 -- the best by where the cue ball
    stops (back on the baulk cushion, far from the reds, no foul)"""
    import math
    rnd = random.Random(seed)
    g = Game(xex)
    g.init()
    m, L, v = g.cpu.mem, g.L, g.vx.vram
    m[L['OPP']] = 5
    n = 0
    while True:
        m[L['TURN']] = 1
        snap = g.snapshot()
        g.frame()
        if m[L['AIST']] != 1:
            continue
        n += 1
        if n == shot:
            break
        t = m[L['TGT']] | m[L['TGT'] + 1] << 8
        m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
        m[L['TURN']] = 0
        m[0x0278], m[0x0284] = 15, 1
        g.cpu.wr(0xD65E, 0x38)
        g.cpu.wr(0xD65F, 0x80)
        g.call('AIM_UPDATE')
        m[L['TURN']] = 1
        m[L['PWR']:L['PWR'] + 3] = bytes(m[L['TPW']:L['TPW'] + 3])
        g.call('FIRE_CUE')
        for _ in range(20000):
            g.call('TICK_ALL')
            if not any(m[L['AWK'] + i] for i in range(22)):
                break
        m[L['WASMOV']] = 1
    g.restore(snap)
    base = g.snapshot()
    cue = _bpos(m, L, 0)
    reds = [b for b in range(1, 16) if m[L['BON'] + b]]
    print('cue (%d,%d)' % cue)

    def play(t, pw, side):
        g.restore(base)
        m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
        m[L['TURN']] = 0
        m[0x0278], m[0x0284] = 15, 1
        g.cpu.wr(0xD65E, 0x38)
        g.cpu.wr(0xD65F, 0x80)
        g.call('AIM_UPDATE')
        m[L['PWR']:L['PWR'] + 3] = bytes([pw & 255, (pw >> 8) & 255, pw >> 16])
        m[L['SPIN']], m[L['SIDE']] = 4, side
        g.call('FIRE_CUE')
        first = None
        for _ in range(8000):
            g.call('TICK_ALL')
            if first is None:
                first = next((b for b in range(1, 22) if m[L['AWK'] + b]), None)
            if not any(m[L['AWK'] + i] for i in range(22)):
                break
        e = _bpos(m, L, 0)
        ok = first is not None and first < 16 and m[L['BON']] == 1
        dr = min(abs(_bpos(m, L, b)[0] - e[0]) + abs(_bpos(m, L, b)[1] - e[1]) for b in range(1, 16) if m[L['BON'] + b])
        return ok, e, dr, first
    res = []
    t0 = time.time()
    for b in reds:
        bx, by = _bpos(m, L, b)
        a0 = math.atan2(by - cue[1], bx - cue[0])
        d = math.hypot(bx - cue[0], by - cue[1])
        for sg in (-1, 1):
            for f in (0.82, 0.90, 0.96):        # the cue's centre off the red's by f 2R
                a = a0 + sg * math.asin(f * 52.5 / d)
                t = round(a / (2 * math.pi) * 65536) & 0xFFFF
                for pw in (0xA000, 0xC000, 0xE000):
                    for side in (2, 4, 6):
                        ok, e, dr, first = play(t, pw, side)
                        if not ok:
                            continue
                        score = dr + (1500 if e[0] < 300 else 0) + (500 if min(e[1], 1778 - e[1]) < 60 or e[0] < 60 else 0)
                        res.append((score, b, sg, f, pw, side, e, dr, first))
    res.sort(reverse=True)
    for r in res[:10]:
        print('score %5d  %-4s side %+d f %.2f pwr %05X tip-side %d  cue ends (%4d,%4d)  nearest red %4d  first %s'
              % (r[0], BALLS[r[1]], r[2], r[3], r[4], r[5], r[6][0], r[6][1], r[7], BALLS[r[8]]))
    print('%d legal of %d tries, %.0f s' % (len(res), len(reds) * 54, time.time() - t0))


def phys_check_shots(xex):
    """the physics against the textbook: a 30-degree cut at a few gaps and speeds
    (the object ball leaves along the line of centres at the contact), and the
    cue ball's top / back spin on a straight shot (fire_cue's spin 0..8)"""
    import math
    g = Game(xex)
    g.init()
    m, L = g.cpu.mem, g.L
    snap = g.snapshot()

    def put(b, x, y):
        X, Y = int(x * 4096), int(y * 4096)
        m[L['BON'] + b] = 1
        for k in range(3):
            m[L['X0'] + 0x20 * k + b] = (X >> 8 * k) & 255
            m[L['Y0'] + 0x20 * k + b] = (Y >> 8 * k) & 255

    def shoot(c, o, p, spin=4):
        g.restore(snap)
        for b in range(22):
            m[L['BON'] + b] = 0
        put(0, *c)
        put(1, *o)
        m[L['AIMANG']] = m[L['AIMANG'] + 1] = m[L['AIMFRAC']] = 0     # along +x
        m[L['TURN']] = 0
        m[0x0278], m[0x0284] = 15, 1
        g.call('AIM_UPDATE')
        m[L['SPIN']] = spin
        m[L['PWR']], m[L['PWR'] + 1], m[L['PWR'] + 2] = p & 255, (p >> 8) & 255, p >> 16
        g.call('FIRE_CUE')
    cut = math.radians(30)
    o = (1800, 889)
    for dcg in (5, 50, 1000):
        row = []
        for p in (0x3000, 0x8000, 0x11000):
            shoot((o[0] - 52.5 * math.cos(cut) - dcg, o[1] - 52.5 * math.sin(cut)), o, p)
            for _ in range(4000):
                g.call('TICK_ALL')
                x, y = _bpos(m, L, 1)
                if (x - o[0]) ** 2 + (y - o[1]) ** 2 > 100 ** 2:
                    break
            row.append('%5.1f' % math.degrees(math.atan2(y - o[1], x - o[0])) if x != o[0] else '  -  ')
        print('cut 30 deg, the cue %4d mm short: the object ball at %s deg (0.6 / 1.6 / 3.4 m/s)'
              % (dcg, ' '.join(row)))
    for p in (0x6000, 0xA000):
        row = []
        for sp in range(9):
            shoot((700, 889), (1200, 889), p, sp)
            for _ in range(6000):
                g.call('TICK_ALL')
                x = _bpos(m, L, 0)[0]
                if not any(m[L['AWK'] + i] for i in range(22)) or x > 3400 or x < 100:
                    break
            row.append('%+5d' % (x - 1200))
        print('straight, %.1f m/s, spin 0..8: the cue ball ends %s mm from the object ball'
              % (p / 20480, ' '.join(row)))
    # the cushion: the cue ball rolling into the x cushion at alpha from its
    # line, side 0 / 4 / 8 -> the way it leaves once it rolls again (deg from the
    # cushion line), the game vs Mathavan's model (side as struck)
    slp = [L['SLP0'], L['SLP1'], L['SLP2']]
    for side in (4, 0, 8):
        row = []
        for ang in (20, 45, 70):
            a = math.radians(ang)
            g.restore(snap)
            for b in range(22):
                m[L['BON'] + b] = 0
            put(0, 3543 - 700 * math.sin(a), 889 - 500 * math.cos(a))
            t = round(math.atan2(math.cos(a), math.sin(a)) / (2 * math.pi) * 65536) & 0xFFFF
            m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
            m[L['TURN']] = 0
            m[0x0278], m[0x0284] = 15, 1
            g.call('AIM_UPDATE')
            m[L['SIDE']] = side
            p = 0x5000
            m[L['PWR']], m[L['PWR'] + 1], m[L['PWR'] + 2] = p & 255, (p >> 8) & 255, p >> 16
            g.call('FIRE_CUE')
            hit = None
            for _ in range(4000):
                q = _bpos(m, L, 0)
                g.call('TICK_ALL')
                e = _bpos(m, L, 0)
                if hit is None and e[0] < q[0]:
                    hit = q
                if hit is not None and not any(m[x] for x in slp) and math.hypot(e[0] - hit[0], e[1] - hit[1]) > 150:
                    break
            game = math.degrees(math.atan2(hit[0] - e[0], e[1] - hit[1])) if hit else float('nan')
            r = mathavan(*state(ang, 1, (side - 4) * 5 / 16))
            sv = settle(r[0], r[1], r[2], r[3])
            row.append('%5.1f/%5.1f' % (game, math.degrees(math.atan2(-sv[1], sv[0]))))
        print('cushion, side %d: off it at (game/model, deg from the cushion) for 20 / 45 / 70: %s'
              % (side, '  '.join(row)))
    # the run a cushion leaves: a rolling ball (centre, 0.6 m to the cushion) -> the
    # run after it / the run it had left at it (aisafe.asm endpt's share a bounce)
    row = []
    for ang in (15, 30, 45, 60, 75, 90):
        a = math.radians(ang)
        g.restore(snap)
        for b in range(22):
            m[L['BON'] + b] = 0
        d0 = 600
        put(0, 3543 - d0 * math.sin(a), 889 - d0 * math.cos(a))
        t = round(math.atan2(math.cos(a), math.sin(a)) / (2 * math.pi) * 65536) & 0xFFFF
        m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
        m[L['TURN']] = 0
        m[0x0278], m[0x0284] = 15, 1
        g.call('AIM_UPDATE')
        p = 0x6000
        m[L['PWR']], m[L['PWR'] + 1], m[L['PWR'] + 2] = p & 255, (p >> 8) & 255, p >> 16
        g.call('FIRE_CUE')
        hit, left, run = None, 0.0, 0.0
        q = _bpos(m, L, 0)
        for _ in range(8000):
            vx = sum(m[L['VX0'] + 0x20 * k] << 8 * k for k in range(3))
            vy = sum(m[L['VY0'] + 0x20 * k] << 8 * k for k in range(3))
            vx, vy = [(x - (1 << 24) if x & 0x800000 else x) / 4096 * 0.2 for x in (vx, vy)]
            g.call('TICK_ALL')
            e = _bpos(m, L, 0)
            if hit is None and e[0] < q[0]:
                hit, left = q, 4000 * (vx * vx + vy * vy)       # it rolls: 4 v^2 m to go
            elif hit is not None:
                run += math.hypot(e[0] - q[0], e[1] - q[1])
            q = e
            if not m[L['AWK']]:
                break
        row.append('%d: %.2f' % (ang, run / left if left else float('nan')))
    print('a cushion keeps of the run (rolling in, by the angle from the cushion): ' + '  '.join(row))


def ai_model_check(xex):
    """the cue ball after the contact, the game physics vs the textbook: at the
    contact it moves at v (along the aim) with spin u = f v; it leaves along the
    tangent at v sin(a), grips the cloth again at 5/7 of that + 2/7 of u:
    v_end / v = ((5 sin^2 a + 2 f) / 7, 5 sin a cos a / 7), then rolls 4 v^2 m.
    f = 1 follow (it rolls at the contact), 0 stun, -1.25 screw (the tip R/2 low,
    5 mm from the ball).  Prints the way (deg from the aim) and the run after the
    contact (mm, a cushion counted as 2.16 v^2 of the speed there): model / game."""
    g = Game(xex)
    g.init()
    m, L = g.cpu.mem, g.L
    snap = g.snapshot()

    def put(b, x, y):
        X, Y = int(x * 4096), int(y * 4096)
        m[L['BON'] + b] = 1
        for k in range(3):
            m[L['X0'] + 0x20 * k + b] = (X >> 8 * k) & 255
            m[L['Y0'] + 0x20 * k + b] = (Y >> 8 * k) & 255

    def vel(b):
        s24 = lambda n: (lambda v: v - (1 << 24) if v & 0x800000 else v)(
            sum(m[L[n] + 0x20 * k + b] << 8 * k for k in range(3)))
        return s24('VX0') / 4096 * 0.2, s24('VY0') / 4096 * 0.2      # m/s

    def wall(p):
        return p[0] < 34 or p[0] > 3535 or p[1] < 34 or p[1] > 1744
    for name, f, spin, dcg, p in (('follow', 1.0, 4, 1500, 0x8000), ('stun', 0.0, 4, 5, 0x6000),
                                  ('screw', -1.25, 0, 5, 0x6000)):
        print('%s (f %+.2f):' % (name, f))
        for th in range(0, 76, 15):
            a = math.radians(th)
            o = (300 + dcg + 52.5 * math.cos(a), 889 + 52.5 * math.sin(a))
            g.restore(snap)
            for b in range(22):
                m[L['BON'] + b] = 0
            put(0, 300, 889)
            put(1, *o)
            m[L['AIMANG']] = m[L['AIMANG'] + 1] = m[L['AIMFRAC']] = 0
            m[L['TURN']] = 0
            m[0x0278], m[0x0284] = 15, 1
            g.call('AIM_UPDATE')
            m[L['SPIN']] = spin
            m[L['PWR']], m[L['PWR'] + 1], m[L['PWR'] + 2] = p & 255, (p >> 8) & 255, p >> 16
            g.call('FIRE_CUE')
            vc = c0 = None
            for _ in range(8000):
                v0 = vel(0)
                g.call('TICK_ALL')
                if c0 is None and m[L['AWK'] + 1]:
                    c0, vc = _bpos(m, L, 0), math.hypot(*v0)
                q = _bpos(m, L, 0)
                if c0 is not None and (wall(q) or not m[L['AWK']]):
                    break
            ve = vel(0)
            run = math.hypot(q[0] - c0[0], q[1] - c0[1]) + 2160 * (ve[0] ** 2 + ve[1] ** 2)
            way = -math.degrees(math.atan2(q[1] - c0[1], q[0] - c0[0])) if run > 1 else 0
            x = (5 * math.sin(a) ** 2 + 2 * f) / 7
            y = 5 * math.sin(a) * math.cos(a) / 7
            print('  cut %2d: way %6.1f / %6.1f deg, run %5d / %5d mm   (v at the contact %.2f m/s)' % (
                th, math.degrees(math.atan2(y, x)), way, 4000 * vc * vc * (x * x + y * y), run, vc))


# ==========================================================================
# the snooker ball-cushion impact (--cushion): Mathavan, Jackson, Parkin, 'A
# theoretical analysis of billiard ball dynamics under cushion impacts', Proc.
# IMechE C 224 (2010) 1863-1873 (docs/): the numerical model of eqs 12-16 as
# ported in pooltool (physics/resolve/ball_cushion/mathavan_2010/model.py),
# with the paper's snooker values: h = 7R/5 (sin theta = 2/5), ee = 0.98,
# mu_w = 0.14, mu_s = 0.212, M = 0.1406 kg, R = 26.25 mm.  Frame: the cushion
# along x, the ball approaching along +y (vy > 0); w = (wx, wy, wz) rad/s.
# ==========================================================================
import math  # noqa: E402

M, R = 0.1406, 0.02625
H = 7 * R / 5
EE, MU_S, MU_W = 0.98, 0.212, 0.14


def _slip(st, ct, vx, vy, wx, wy, wz):
    a = math.atan2(-vy * st + wx * R, vx + wy * R * st - wz * R * ct)
    b = math.atan2(vy + wx * R, vx - wy * R)
    return a, b


def _dv(st, ct, a, b, dp):
    k = st + MU_W * math.sin(a) * ct
    return (-(MU_W * math.cos(a) + MU_S * math.cos(b) * k) * dp / M,
            -(ct - MU_W * st * math.sin(a) + MU_S * math.sin(b) * k) * dp / M)


def _dw(st, ct, a, b, dp):
    f = 5 / (2 * M * R)
    k = st + MU_W * math.sin(a) * ct
    return (-f * (MU_W * math.sin(a) + MU_S * math.sin(b) * k) * dp,
            -f * (MU_W * math.cos(a) * st - MU_S * math.cos(b) * k) * dp,
            f * MU_W * math.cos(a) * ct * dp)


def mathavan(vx, vy, wx, wy, wz, steps=5000):
    """the paper's model: compression until vy = 0, restitution until the work at
    the cushion is ee^2 of the compression's"""
    st = (H - R) / R
    ct = math.sqrt(1 - st * st)
    s = [vx, vy, wx, wy, wz]

    def step(dp):
        a, b = _slip(st, ct, *s)
        dx, dy = _dv(st, ct, a, b, dp)
        e = _dw(st, ct, a, b, dp)
        return [s[0] + dx, s[1] + dy, s[2] + e[0], s[3] + e[1], s[4] + e[2]]
    dp = M * vy / steps
    w = 0.0
    while s[1] > 0:
        n = step(dp)
        if n[1] <= 0:
            d = dp
            for _ in range(12):
                d /= 2
                t = step(d)
                if t[1] > 0:
                    s = t
                    w += d * abs(s[1]) * ct
            break
        s = n
        w += dp * abs(s[1]) * ct
    target = EE * EE * w
    w = 0.0
    while w < target:
        dw = dp * abs(s[1]) * ct
        if w + dw > target and abs(s[1]) > 0:
            s = step((target - w) / (abs(s[1]) * ct))
            break
        s = step(dp)
        w += dw
    return tuple(s)


def state(alpha, k_top, k_side, v0=1.0):
    """the paper's eq. 15: alpha from the cushion line, topspin k V0/R along the
    way, sidespin k V0/R"""
    a = math.radians(alpha)
    wt, ws = k_top * v0 / R, k_side * v0 / R
    return v0 * math.cos(a), v0 * math.sin(a), -wt * math.sin(a), wt * math.cos(a), ws


def settle(vx, vy, wx, wy):
    """the slide on the cloth after it: it rolls at 5/7 v + 2/7 of the spin's"""
    return (5 * vx + 2 * wy * R) / 7, (5 * vy - 2 * wx * R) / 7


# ---- the 6502's version (src/cushion.asm), bit for bit ------------------------
# 24-bit signed cells: velocities Q9 (mm a tick * 512: the engine's Q12 >> 3),
# the rest Q16.  Every product is math.asm's smul3r (|a b| >> 16 rounded half
# up, then the sign: a negative one as floor((-P + $8000) / 65536)); the unit
# vectors Q7 << 9 from a 1/sqrt table; 4 Euler steps of the normal impulse,
# the compression cut at vy = 0, the rebound at ee^2 of its work (w - w/32 -
# w/128); a step's fraction is divr's round(n 256 / d), at most 255.
FX_CT, FX_ST = 60065, 26214              # cos / sin theta (sin = 2/5), Q16
FX_MUW, FX_MUS = 9175, 13894             # 0.14, 0.212
FX_K25 = 163840                          # 5/2
FX_DP = 17876                            # 1 / (cos theta * 4): the impulse step
# 1 / sqrt(q) for q = ax^2 + ay^2, ax, ay < 128, max >= 64: q >> 6 = 64..504
FX_TINV = [min(255, round(2 ** 13 / math.sqrt((i + 0.5) * 64))) for i in range(64, 505)]


def _w(x):                               # a 24-bit signed cell
    x &= 0xFFFFFF
    return x - 0x1000000 if x & 0x800000 else x


def smul3r(a, b):
    p = abs(a) * abs(b)
    return _w(((p + 0x8000) >> 16) if (a < 0) == (b < 0) or p == 0 else (0x8000 - p) >> 16)


def fx_unit(x, y):
    """(x, y) -> (c, s) Q16: scaled to max 64..127, 1/sqrt from the table"""
    ax, ay = abs(x), abs(y)
    if ax == 0 and ay == 0:
        return 0, 0
    while max(ax, ay) >= 128:
        ax >>= 1
        ay >>= 1
    while max(ax, ay) < 64:
        ax <<= 1
        ay <<= 1
    t = FX_TINV[((ax * ax + ay * ay) >> 6) - 64]
    c, s = min(127, (ax * t) >> 6) << 9, min(127, (ay * t) >> 6) << 9
    return (-c if x < 0 else c), (-s if y < 0 else s)


def fx_deriv(vx, vy, ux, uy, w):
    """the change of (vx, vy, ux, uy, w) per unit of normal impulse (Q16): the
    program cu_dprg runs"""
    m = smul3r
    cI, sI = fx_unit(_w(_w(vx + m(ux, FX_ST)) - m(w, FX_CT)), _w(_w(-m(vy, FX_ST)) - uy))
    cC, sC = fx_unit(_w(vx - ux), _w(vy - uy))
    a, b = m(FX_MUW, cI), m(FX_MUW, sI)
    k = _w(FX_ST + m(b, FX_CT))
    m1, m2 = m(m(FX_MUS, cC), k), m(m(FX_MUS, sC), k)
    return (_w(-_w(a + m1)), _w(_w(m(FX_ST, b) - FX_CT) - m2),
            _w(-m(_w(m(a, FX_ST) - m1), FX_K25)), m(_w(b + m2), FX_K25), m(m(a, FX_CT), FX_K25))


def _frac(n, d):
    """divr's round(n 256 / d), at most 255 (n >= d: 255)"""
    return 255 if n >= d else min(255, (2 * n * 256 + d) // (2 * d))


def fx_solve(vx, vy, ux, uy, w):
    """Q9 in, Q9 out; vy > 0 (into the cushion)"""
    s = [vx, vy, ux, uy, w]
    dp = max(1, smul3r(vy, FX_DP))

    def step(s, d, h):
        return [_w(s[i] + smul3r(d[i], h)) for i in range(5)]
    work = 0
    for _ in range(16):                  # compression
        d = fx_deriv(*s)
        n = step(s, d, dp)
        if n[1] <= 0:
            h = (dp * _frac(s[1], s[1] - n[1])) >> 8
            work += (h * s[1]) >> 2
            s = step(s, d, h)
            s[1] = 0
            break
        work += (dp * (s[1] + n[1])) >> 2
        s = n
    target = work - (work >> 5) - (work >> 7)     # ee^2 = 0.9604 ~ 1 - 1/32 - 1/128
    work = 0
    for _ in range(24):                  # restitution
        d = fx_deriv(*s)
        n = step(s, d, dp)
        dw = (dp * (-s[1] - n[1])) >> 2
        if work + dw >= target:
            s = step(s, d, (dp * _frac(target - work, dw)) >> 8)
            break
        work += dw
        s = n
    return s


def fx_check():
    """--cushion: the 6502's fixed point against the model (the settled velocity after it)"""
    cases = [(al, kt, ks) for al in (10, 20, 30, 45, 60, 75, 85, 90)
             for kt in (-1, 0, 0.5, 1, 2) for ks in (-2, -1, -0.5, 0, 0.5, 1, 2)]
    wa = wv = 0.0
    for v0 in (0.3, 1.0, 2.5):
        for c in cases:
            r = mathavan(*state(*c, v0=v0))
            a = settle(r[0], r[1], r[2], r[3])
            vx, vy, wx, wy, wz = state(*c, v0=v0)
            q = 1 / 2560                         # Q9 mm a tick in m/s (5 mm a tick = 1 m/s)
            o = fx_solve(round(vx / q), round(vy / q), round(wy * R / q),
                         round(-wx * R / q), round(wz * R / q))
            o = [x * q for x in o]
            b = ((5 * o[0] + 2 * o[2]) / 7, (5 * o[1] + 2 * o[3]) / 7)
            da = abs(math.degrees(math.atan2(a[1], a[0]) - math.atan2(b[1], b[0])))
            wa = max(wa, min(da, 360 - da))
            wv = max(wv, abs(math.hypot(*a) - math.hypot(*b)) / v0)
    print('fixed point vs Mathavan: worst %.2f deg, worst %.1f %% of the speed' % (wa, 100 * wv))


def fx_asm(xex, n=400, seed=7):
    """--cushion: cushion.asm's cu_fx in the simulator against fx_solve, bit for
    bit, on n random states (0.1..3.5 m/s, any spin and side)"""
    rnd = random.Random(seed)
    g = Game(xex)
    g.init()
    L, v = g.L, g.vx.vram
    kv = (L['CU_BANK'] << 12) + L['CU_KV'] - 0x2000
    bad = 0
    t0 = time.time()
    for k in range(n):
        sp = rnd.uniform(0.1, 3.5) * 2560
        a = rnd.uniform(0.05, math.pi - 0.05)
        st = [round(sp * math.cos(a)), round(sp * math.sin(a))]
        st += [round(sp * rnd.uniform(-1.3, 1.3)) for _ in range(3)]
        for i, x in enumerate(st):
            x &= 0xFFFFFF
            v[kv + 3 * i:kv + 3 * i + 3] = bytes((x & 255, x >> 8 & 255, x >> 16))
        g.cpu.wr(0xD65E, 0x28)          # MEMAC-A: 4 KB at $2000, the model's bank
        g.cpu.wr(0xD65F, 0x80 | L['CU_BANK'])
        g.call('CU_FX')
        g.cpu.wr(0xD65E, 0x38)          # back (its cells to VRAM)
        g.cpu.wr(0xD65F, 0x80)
        got = [_w(v[kv + 3 * i] | v[kv + 3 * i + 1] << 8 | v[kv + 3 * i + 2] << 16) for i in range(5)]
        want = fx_solve(*st)
        if got != want:
            bad += 1
            if bad <= 5:
                print('  in %s: asm %s, model %s' % (st, got, want))
    print('cu_fx (6502) vs the model: %d of %d states differ (%.1f s)' % (bad, n, time.time() - t0))


def sim_check(xex):
    """--sim: simshot.asm's sim_shot against a real shot -- the table put back
    exactly (RAM pages 4-7, $1000-$1FFF, the aim's zero page), and its outcome
    (the cue ball's end, the first ball touched, the target's end) the same as
    the shot fired for real"""
    g = Game(xex)
    g.init()
    m, L = g.cpu.mem, g.L
    snap = g.snapshot()
    for cue, tgt, pw, ball in (((799, 959), 3900, 0xBCAC, 15), ((1614, 203), 2800, 0x9A10, 14),
                               ((600, 800), 1500, 0x5000, 1)):
        g.restore(snap)
        X, Y = int(cue[0] * 4096), int(cue[1] * 4096)
        for k in range(3):
            m[L['X0'] + 0x20 * k] = (X >> 8 * k) & 255
            m[L['Y0'] + 0x20 * k] = (Y >> 8 * k) & 255
        t = tgt * 16                            # 1/64 units of a 1024 turn
        m[L['STGT']], m[L['STGT'] + 1] = t & 255, t >> 8
        m[L['STPW']:L['STPW'] + 3] = bytes((pw & 255, pw >> 8 & 255, pw >> 16))
        m[L['SAT']] = ball
        before = bytes(m[0x400:0x800]) + bytes(m[0x1000:0x2000]) + bytes(m[0xCD:0xDD])
        g.cpu.wr(0xD65E, 0x2A)                  # called from the AI's window
        g.cpu.wr(0xD65F, 0x80 | L['AI_BANK'])
        c0 = g.cpu.cycles
        g.call('SIM_SHOT')
        cyc = g.cpu.cycles - c0
        after = bytes(m[0x400:0x800]) + bytes(m[0x1000:0x2000]) + bytes(m[0xCD:0xDD])
        diff = [i for i in range(len(before)) if before[i] != after[i]]
        rd = lambda n: m[L[n]] | m[L[n] + 1] << 8
        sim = (rd('SCX') / 16, rd('SCY') / 16, m[L['SFC']], rd('SOX') / 16, rd('SOY') / 16)
        g.cpu.wr(0xD65E, 0x38)                  # the same shot for real
        g.cpu.wr(0xD65F, 0x80)
        m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
        m[L['TURN']] = 0
        m[0x0278], m[0x0284] = 15, 1
        g.call('AIM_UPDATE')
        m[L['PWR']:L['PWR'] + 3] = bytes((pw & 255, pw >> 8 & 255, pw >> 16))
        g.call('FIRE_CUE')
        for _ in range(8000):
            g.call('TICK_ALL')
            if not any(m[L['AWK'] + i] for i in range(22)):
                break
        c, o = _bpos(m, L, 0), _bpos(m, L, ball)
        real = (int(c[0] * 16) / 16, int(c[1] * 16) / 16, m[L['FCON']], int(o[0] * 16) / 16, int(o[1] * 16) / 16)
        print('cue %s: sim %s | real %s | restored: %s | %.1f M cycles' % (
            cue, tuple(round(x) for x in sim), tuple(round(x) for x in real),
            'exact' if not diff else '%d bytes differ (first $%X)' % (len(diff), diff[0]), cyc / 1e6))


def run_scenario(xex, name, procs=False, verbose=True, window=None, shot=None):
    """window = (a, b): the per-proc profile (and the headline numbers) count
    only frames a..b-1 -- e.g. the impact frames of the break."""
    g = Game(xex)
    if procs:
        g.cpu.set_procs(g.labels)
    t0 = time.time()
    ic = g.init()
    if procs:
        g.cpu.profile = [0] * len(g.cpu.profile)   # drop init from the profile
        g.cpu.calls = [0] * len(g.cpu.calls)
    frames = []
    pos = []

    saved = [None]

    def one(stick, trig, key=KEY_NONE):
        if procs and window and len(frames) == window[0]:
            g.cpu.profile = [0] * len(g.cpu.calls)
            g.cpu.calls = [0] * len(g.cpu.calls)
        if procs and window and len(frames) == window[1]:
            saved[0] = g.cpu.profile        # stop counting after the window
            g.cpu.profile = None
        cyc = g.frame(stick, trig, key)
        frames.append((cyc,) + g.digest())
        pos.append(g.positions())

    for phase in SCENARIOS[name]:
        if phase[0] == 'place':             # balls put at (x, y) mm (Q12)
            m, L = g.cpu.mem, g.L
            for b, (x, y) in phase[1].items():
                for k, v in enumerate((x * 4096, y * 4096)):
                    for j in range(3):
                        m[L[('X%d', 'Y%d')[k] % j] + b] = (v >> 8 * j) & 255
            continue
        if phase[0] == 'aim':               # the aim (65536 a turn)
            m, L, t = g.cpu.mem, g.L, phase[1]
            m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
            continue
        n, stick, trig = phase[:3]
        key = phase[3] if len(phase) > 3 else KEY_NONE
        if n == 'rest':
            k = 0
            while True:
                one(stick, trig, key)
                k += 1
                if g.at_rest() and k > 2 or k > 1500:
                    break
        else:
            for _ in range(n):
                one(stick, trig, key)
    dt = time.time() - t0
    if shot:
        g.screenshot(shot)
        print('[shot] %s  (%d blits, %d pixels)' % (shot, g.vx.blit_count, g.vx.blit_pixels))
    allframes = frames
    if procs and window:
        if saved[0] is not None:
            g.cpu.profile = saved[0]
        frames = frames[window[0]:window[1]]     # headline + table = the window only
    total = sum(f[0] for f in frames)
    res = {'xex': xex, 'scenario': name, 'init_cycles': ic, 'frames': allframes,
           'total_cycles': total, 'nframes': len(frames), 'pos': pos,
           'window': list(window) if window else None}
    if verbose:
        cyc = sorted((f[0] for f in frames), reverse=True)
        print('%s  scenario=%s  frames=%d  total=%d cyc  avg=%d cyc/frame  top5=%s  (%.1fs)%s'
              % (xex, name, len(frames), total, total // len(frames), cyc[:5], dt,
                 '  [window %d:%d]' % tuple(window) if window else ''))
    if procs:
        rows = []
        for i, n_ in enumerate(g.cpu.proc_names):
            c = g.cpu.profile[i]
            if c:
                rows.append((c, g.cpu.calls[i], n_))
        rows.sort(reverse=True)
        res['procs'] = rows
        if verbose:
            nf = len(frames)
            print('  %-16s %8s %10s %9s %8s' % ('proc', '%', 'cyc/frame', 'calls/fr', 'cyc/call'))
            for c, k, n_ in rows[:32]:
                print('  %-16s %7.2f%% %10d %9.1f %8s' % (n_, 100.0 * c / total, c // nf, k / nf,
                                                        (c // k) if k else '-'))
    return res


PAL_CYCLES_PER_FRAME = 35469        # 1.7734 MHz / 50 Hz (DMA ignored)
SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'src')


def proc_files():
    """proc name (upper) -> source file, from the `.proc name` lines in src/."""
    out = {}
    if not os.path.isdir(SRC):
        return out
    for f in sorted(os.listdir(SRC)):
        if not f.endswith('.asm') or f == 'anim.asm':
            continue
        for line in open(os.path.join(SRC, f), encoding='latin-1'):
            s = line.strip().split(';', 1)[0].split()
            if len(s) >= 2 and s[0].lower() == '.proc':
                out[s[1].upper()] = f
    return out


def write_report(res, path):
    """bench_fps.txt-style report: the model fps line, the per-proc table and
    the per-file totals (same shape as doom-bsp-port/bench/bench_fps.txt)."""
    nf = res['nframes']
    cyc = res['total_cycles'] / nf
    ms = cyc / 1773.4
    fps = 50.0 / max(cyc / PAL_CYCLES_PER_FRAME, 1.0)
    files = proc_files()
    lines = ['FPS  model %.2f   frame %.1f ms   %d cyk   scenario %s   %s'
             % (fps, ms, cyc, res['scenario'], res['xex']),
             '     %s   %d frames   (50 Hz cap; a frame under %d cyk runs at full rate)'
             % (time.strftime('%Y-%m-%d %H:%M'), nf, PAL_CYCLES_PER_FRAME), '',
             '    %6s %6s %9s  %-20s %s' % ('ms/f', '%', 'cyk/f', 'proc', 'file')]
    per_file = {}
    for c, k, n in res.get('procs', []):
        f = files.get(n, '-')
        per_file[f] = per_file.get(f, 0) + c
        if c / nf >= 20:
            lines.append('    %6.2f %5.1f%% %9d  %-20s %s' % (c / nf / 1773.4, 100.0 * c / res['total_cycles'],
                                                            c / nf, n.lower(), f))
    lines += ['', '    %6s  subor' % 'ms/f']
    for f, c in sorted(per_file.items(), key=lambda kv: -kv[1]):
        lines.append('    %6.2f  %s' % (c / nf / 1773.4, f))
    open(path, 'w').write('\n'.join(lines) + '\n')
    print('[bench] report -> %s' % path)


def compare_pos(a, b):
    """Physics divergence in mm between two runs' per-frame ball positions:
    max over frames/balls, and the max at the final frame -- the gate for
    behaviour-changing rewrites (the README's PC-vs-Atari metric)."""
    A = json.load(open(a))
    B = json.load(open(b))
    pa, pb = A['pos'], B['pos']
    n = min(len(pa), len(pb))
    worst = (0.0, 0, 0)
    for f in range(n):
        for i in range(22):
            xa, ya, oa = pa[f][i]
            xb, yb, ob = pb[f][i]
            if oa != ob:
                d = 9999.0
            else:
                d = (((xa - xb) / 4096.0) ** 2 + ((ya - yb) / 4096.0) ** 2) ** 0.5
            if d > worst[0]:
                worst = (d, f, i)
    last = max((((pa[n - 1][i][0] - pb[n - 1][i][0]) / 4096.0) ** 2
                + ((pa[n - 1][i][1] - pb[n - 1][i][1]) / 4096.0) ** 2) ** 0.5 for i in range(22))
    print('%s vs %s: %d frames, max divergence %.2f mm (frame %d, ball %d), final-frame max %.2f mm'
          % (a, b, n, worst[0], worst[1], worst[2], last))
    if len(pa) != len(pb):
        print('  frame count differs: %d vs %d (settling time changed)' % (len(pa), len(pb)))
    return worst[0]


def compare(a, b):
    A = json.load(open(a))
    B = json.load(open(b))
    fa, fb = A['frames'], B['frames']
    n = min(len(fa), len(fb))
    bad = 0
    for i in range(n):
        if fa[i][1:] != fb[i][1:]:
            if bad < 10:
                print('frame %d differs: %s vs %s' % (i, fa[i][1:], fb[i][1:]))
            bad += 1
    if len(fa) != len(fb):
        print('frame count differs: %d vs %d' % (len(fa), len(fb)))
        bad += 1
    print('%s: %d frames, %d cycles  ->  %s: %d frames, %d cycles  (%.1f%%)'
          % (a, len(fa), A['total_cycles'], b, len(fb), B['total_cycles'],
             100.0 * B['total_cycles'] / A['total_cycles']))
    print('BIT-IDENTICAL' if bad == 0 else 'MISMATCH in %d frames' % bad)
    return bad == 0


# ---------------------------------------------------------------------------
# micro: random-vector bit-identity of the primitives between two builds
# ---------------------------------------------------------------------------
def rnd3():
    return random.getrandbits(24)


def rnds3():
    v = random.getrandbits(24)
    return v if random.random() < 0.5 else (-v) & 0xFFFFFF


def put(m, a, v, n):
    for i in range(n):
        m[a + i] = (v >> (8 * i)) & 0xFF


def get(m, a, n):
    return bytes(m[a:a + n])


def micro(xa, xb, ncases=3000):
    ga, gb = Game(xa), Game(xb)
    ga.init()
    gb.init()
    random.seed(7)
    # each test: name, setup(mem, labels, rnd) -> None, outputs: [(label, offset, len)]
    tests = []

    def T(name, setup, outs, proc=None):
        tests.append((name, setup, outs, proc or name.upper()))

    def s_fmulu(m, L, cpu):
        cpu.a = random.getrandbits(8)
        cpu.x = random.getrandbits(8)
    T('fmulu', s_fmulu, [('FMPL', 0, 1), ('FMPH', 0, 1)])

    def small3():
        # the mul48 fast-path domain: high byte 0 or 1 (sp, unit vectors, 217)
        r = random.random()
        if r < 0.15:
            return random.choice((0, 1, 0xFFFF, 0x10000, 0x1FFFF, 0x1B800, 217,
                                  0x3FFFF, 0x30000, 0x2FFFF, 0x34800))
        return random.getrandbits(18)

    def s_mul48(m, L, cpu):
        if random.random() < 0.6:
            put(m, L['MA'], small3(), 3)
            put(m, L['MB'], small3(), 3)
        else:
            put(m, L['MA'], rnd3(), 3)
            put(m, L['MB'], rnd3(), 3)
    T('mul48', s_mul48, [('MP', 0, 6)])

    def s_smul3(m, L, cpu):
        if random.random() < 0.6:
            put(m, L['SA'], small3() if random.random() < 0.5 else (-small3()) & 0xFFFFFF, 3)
            put(m, L['SB'], small3() if random.random() < 0.5 else (-small3()) & 0xFFFFFF, 3)
        else:
            put(m, L['SA'], rnds3(), 3)
            put(m, L['SB'], rnds3(), 3)
    T('smul3', s_smul3, [('SP', 0, 6)])
    T('smul3r', s_smul3, [('SP', 0, 3)], proc='SMUL3R')

    def s_rsh(m, L, cpu):
        put(m, L['SP'], random.getrandbits(48), 6)
    T('rsh16', s_rsh, [('SP', 0, 3)])
    T('rsh9', s_rsh, [('SP', 0, 3)])

    def s_div24(m, L, cpu):
        B = random.randint(1, (1 << 24) - 1)
        v = random.randint(1, B)
        put(m, L['MA'], v << 16, 6)
        put(m, L['MB'], B, 3)
    T('div24', s_div24, [('MQ', 0, 3), ('MREM', 0, 4)])
    T('divr', s_div24, [('MQ', 0, 3)])

    def s_div16(m, L, cpu):
        # the two real domains: adx<<16 / d (adx <= d) and DEC_HI*|v| / sp (|v| <= sp)
        if random.random() < 0.5:
            B = random.randint(1, 0x034800)
            v = random.randint(0, B) if random.random() < 0.9 else B
            put(m, L['MA'], v << 16, 6)
        else:
            B = random.randint(1, 0x1B800 * 2)
            v = random.randint(0, B)
            put(m, L['MA'], 17039 * v, 6)
        put(m, L['MB'], B, 3)
    T('div16r', s_div16, [('MQ', 0, 3)], proc='DIV16R')

    def s_sq24(m, L, cpu):
        # a < 2^18; the reference side squares with mul48 (mB = mA)
        a = random.choice((random.getrandbits(18), random.getrandbits(17), random.getrandbits(16),
                           0x3FFFF, 0x30000, 0x2FFFF, 0x1B800, 0x34800, 0, 1, 0xFFFF, 0x10000))
        put(m, L['MA'], a, 3)
        put(m, L['MB'], a, 3)
    T('sq24', s_sq24, [('MP', 0, 6)], proc='SQ24')

    def s_isqrt(m, L, cpu):
        bits = random.randint(0, 48) if random.random() < 0.4 else random.randint(0, 36)
        v = random.getrandbits(bits) if bits else 0
        if random.random() < 0.1:
            v = random.choice((0, 1, (1 << 36) - 1, 1 << 36, (1 << 35) + 5, 0x0AC43FFFFF, 0x0AC4400000))
        put(m, L['MP'], v, 6)
    T('isqrt48', s_isqrt, [('ROOT', 0, 3)])

    def s_vrefl(m, L, cpu):
        put(m, L['VV'], rnds3() & 0xFFFFFF, 3)
    T('vrefl', s_vrefl, [('VV', 0, 3)])

    def s_project(m, L, cpu):
        put(m, L['BX'], random.randint(0, 0xDF1000), 3)
        put(m, L['BY'], random.randint(0, 0x6F2000), 3)
        m[L['SPRBANK']] = random.choice((0x10, 0x20, 0x30, 0x80))
    T('project', s_project, [('SX', 0, 2), ('SYV', 0, 1), ('DSZ', 0, 1), ('SPADR', 0, 3),
                             ('SIZEV', 0, 1)])

    def s_cosptr(m, L, cpu):
        put(m, L['ANG2'], random.randint(0, 1023), 2)
        m[L['SA']] = 0
    # (aptr is compared as an offset from coslut: the table moves between builds)
    T('cosptr', s_cosptr, [('APTR', 0, 2)])

    def s_setbp(m, L, cpu):
        cpu.a = random.randint(0, 21)
    T('set_bp', s_setbp, [('BP', 0, 2)])

    def s_calcoff(m, L, cpu):
        m[L['SYV']] = random.randint(0, 239)
        put(m, L['SX'], random.randint(0, 319), 2)
    T('calc_off', s_calcoff, [('OFF0', 0, 3)])

    def s_cush(m, L, cpu):
        # position after the integrate step + its carry; velocity sign decides the wall
        v = rnds3()
        put(m, L['BVX'], v, 3)
        put(m, L['BVY'], v, 3)
        r = random.random()
        if r < 0.3:
            x = random.randint(0, 0x01A400 + 0x2000)
        elif r < 0.6:
            x = random.randint(0xDD6C00 - 0x2000, 0xDF1000)
        else:
            x = random.randint(0, 0xDF1000)
        put(m, L['BX'], x, 3)
        put(m, L['BY'], min(x, 0x6F2000), 3)
        cpu.p = (cpu.p & ~1) | (1 if random.random() < 0.8 else 0)
        m[L['CUBNC']] = 0
    T('cushion_x', s_cush, [('BX', 0, 3), ('BVX', 0, 3), ('CUBNC', 0, 1)])
    T('cushion_y', s_cush, [('BY', 0, 3), ('BVY', 0, 3), ('CUBNC', 0, 1)])

    def s_friction(m, L, cpu):
        bi = random.randint(0, 21)
        m[L['BI']] = bi
        bp = 0x1000 + bi * 32
        put(m, L['BP'], bp, 2)
        sp = random.choice((random.randint(0, 200), random.randint(0, 0x1B800)))
        put(m, bp + 13, sp, 3)
        put(m, bp + 16, rnds3() & 0x1FFFF if random.random() < 0.5 else (-(random.getrandbits(16))) & 0xFFFFFF, 3)
        put(m, bp + 19, random.getrandbits(16), 3)
        m[L['BFRIC']] = random.getrandbits(8)
    T('friction', s_friction, [('BVX', 0, 3), ('BVY', 0, 3), ('BFRIC', 0, 1), ('BALLS', 0, 0x2C0)])

    def s_renorm(m, L, cpu):
        bi = random.randint(0, 21)
        bp = 0x1000 + bi * 32
        put(m, L['BP'], bp, 2)
        put(m, bp + 6, rnds3() & 0xFFFFFF if random.random() < 0.9 else 0, 3)
        put(m, bp + 9, rnds3() & 0xFFFFFF if random.random() < 0.9 else 0, 3)
        # keep |v| < 2^23 so v^2 sums stay in 48 bits like the real game
        m[bp + 8] = (m[bp + 8] & 0x80) | (m[bp + 8] & 0x0F)
        m[bp + 11] = (m[bp + 11] & 0x80) | (m[bp + 11] & 0x0F)
    T('renorm', s_renorm, [('BALLS', 0, 0x2C0)])

    def s_linedda(m, L, cpu):
        put(m, L['LX0'], random.randint(0, 319), 2)
        m[L['LY0']] = random.randint(0, 239)
        put(m, L['LEX'], random.randint(0, 319), 2)
        m[L['LEY']] = random.randint(0, 239)
        if 'PMODE' in L:
            m[L['PMODE']] = 0       # draw (the OPT build has no erase mode in line_dda)
    T('line_dda', s_linedda, [])   # compared through the VRAM write log

    ok = True
    for name, setup, outs, proc in tests:
        if proc not in gb.L or (proc not in ga.L and name not in ('smul3r', 'div16r', 'sq24')):
            print('%-10s skipped (missing in a build)' % name)
            continue
        ca = cb = 0
        bad = 0
        for i in range(ncases if name not in ('line_dda', 'renorm', 'friction') else ncases // 6):
            seed = random.getrandbits(32)
            outa = outb = None
            for g in (ga, gb):
                random.seed(seed)
                m, L, cpu = g.cpu.mem, g.L, g.cpu
                # common scratch: randomise page 6/7 + zp so stale values can't hide bugs
                junk = random.getrandbits(8)
                for a in range(0x0620, 0x0700):
                    m[a] = junk ^ (a & 0xFF)
                for a in range(0x82, 0x100):
                    m[a] = junk ^ a
                m[0x80], m[0x81] = 0x00, 0xD6      # VB must stay valid: (VB),y writes
                for a in range(0x1000, 0x13C8):
                    m[a] = (junk + a) & 0xFF
                setup(m, L, cpu)
                g.vlog = []
                g.blits = []
                g.logging = True
                if proc == 'DIV16R' and g is ga:
                    cyc = g.call('DIVR')    # reference side: the generic divr
                elif proc == 'SQ24' and g is ga:
                    cyc = g.call('MUL48')   # reference side: the generic product
                elif proc in g.L:
                    cyc = g.call(proc)
                else:                       # base build: smul3r == smul3 + rsh16
                    cyc = g.call('SMUL3') + g.call('RSH16')
                g.logging = False
                o = tuple(get(m, L[lab] + off, n) for lab, off, n in outs) + (g.vram_state(),)
                if name == 'isqrt48' and g is ga:
                    # the reference side is the TRUTH: floor(sqrt(v)) from Python
                    import math
                    v = int.from_bytes(bytes(m[L['MP']:L['MP'] + 6]), 'little') if False else None
                    random.seed(seed)
                    junk = random.getrandbits(8)            # replay the setup's random stream
                    for a in range(0x0620, 0x0700):
                        pass
                if name == 'isqrt48' and g is gb:
                    import math
                    root = int.from_bytes(bytes(m[L['ROOT']:L['ROOT'] + 3]), 'little')
                    # the input was consumed: recompute it from the seed
                    random.seed(seed)
                    random.getrandbits(8)
                    bits = random.randint(0, 48) if random.random() < 0.4 else random.randint(0, 36)
                    v = random.getrandbits(bits) if bits else 0
                    if random.random() < 0.1:
                        v = random.choice((0, 1, (1 << 36) - 1, 1 << 36, (1 << 35) + 5, 0x0AC43FFFFF, 0x0AC4400000))
                    if root != math.isqrt(v):
                        print('  isqrt48 WRONG for %X: %X vs %X' % (v, root, math.isqrt(v)))
                        outb = None
                if name == 'cosptr':
                    ap = m[L['APTR']] | (m[L['APTR'] + 1] << 8)
                    o = (ap - L['COSLUT'],)
                if g is ga:
                    outa = o
                    ca += cyc
                else:
                    outb = o
                    cb += cyc
            if outa != outb:
                bad += 1
                if bad <= 3:
                    print('  %s mismatch (seed %d): %s vs %s' % (name, seed, outa, outb))
        n = ncases if name not in ('line_dda', 'renorm', 'friction') else ncases // 6
        print('%-10s %s  cyc/call %6d -> %6d (%.1f%%)' % (name, 'OK      ' if not bad else 'MISMATCH',
                                                          ca / n, cb / n, 100.0 * cb / max(ca, 1)))
        ok &= not bad
    return ok


def _call(self, proc):
    pc = self.cpu.pc            # (frame() goes on from here afterwards)
    c = self.cpu.call(self.L[proc])
    self.cpu.pc = pc
    self.vx.flush()             # (tools read VRAM straight after: the last blit done)
    return c


Game.call = _call


POCKETS = ((0, 0), (1784, 0), (3569, 0), (0, 1778), (1784, 1778), (3569, 1778))


def _lowprio():
    """a Pool worker at BELOW_NORMAL priority: the PC stays usable"""
    try:
        import ctypes
        k = ctypes.windll.kernel32
        k.SetPriorityClass(k.GetCurrentProcess(), 0x4000)
    except Exception:
        pass


def _pool():
    import multiprocessing
    return multiprocessing.Pool(max(1, (os.cpu_count() or 4) - 2), initializer=_lowprio)


def _cc_ease(balls, on, cue):
    """noble1911/cue-club src/sim/ai.ts potLines()[0].ease from the cue ball: every
    ball on x pocket, the ghost ball, middle pockets |uy| >= 0.45, cut >= 0.22, both
    paths clear; ease = cut^3 / ((1 + 0.6 d1)(1 + 1.2 d2)), metres; 0: no pot.
    balls: {i: (x, y)} mm"""
    R2 = 2 * 26.25

    def clear(ax, ay, bx, by, skip):
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        for i, (x, y) in balls.items():
            if i in skip:
                continue
            t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / l2)) if l2 else 0.0
            if (ax + t * dx - x) ** 2 + (ay + t * dy - y) ** 2 < R2 * R2:
                return False
        return True
    cx, cy = cue
    best = 0.0
    for b in on:
        bx, by = balls[b]
        for k, (px, py) in enumerate(POCKETS):
            ux, uy = px - bx, py - by
            d2 = (ux * ux + uy * uy) ** 0.5
            ux, uy = ux / d2, uy / d2
            if k in (1, 4) and abs(uy) < 0.45:
                continue
            gx, gy = bx - ux * R2, by - uy * R2
            wx, wy = gx - cx, gy - cy
            d1 = (wx * wx + wy * wy) ** 0.5
            if d1 < 1:
                continue
            wx, wy = wx / d1, wy / d1
            cut = wx * ux + wy * uy
            if cut < 0.22:
                continue
            if not clear(cx, cy, gx, gy, (0, b)) or not clear(bx, by, px, py, (0, b)):
                continue
            best = max(best, cut ** 3 / ((1 + 0.6 * d1 / 1000) * (1 + 1.2 * d2 / 1000)))
    return best


def _cc_on(m, L):
    """the balls on for the player to play: reds, any colour, or the lowest colour"""
    if m[L['EXPCOL']]:
        return [b for b in range(16, 22) if m[L['BON'] + b]]
    if m[L['REDSL']]:
        return [b for b in range(1, 16) if m[L['BON'] + b]]
    return [b for b in range(16, 22) if m[L['BON'] + b]][:1]


def _brk_layout(g, rnd, nred, pack=False):
    """a reds-phase table: nred reds (most round the pink and the black; pack: a
    loosened pack below the pink and the cue ball in baulk), the colours on their
    spots, the cue ball free; player 1 to play"""
    m, L = g.cpu.mem, g.L
    put = [_bpos(m, L, b) for b in range(16, 22)]

    def free(x, y, d=58):
        return (all((x - a) ** 2 + (y - b) ** 2 > d * d for a, b in put) and
                all((x - a) ** 2 + (y - b) ** 2 > 130 ** 2 for a, b in POCKETS))

    def place(b, x, y):
        X, Y = int(x * 4096), int(y * 4096)
        m[L['BON'] + b] = 1
        for k in range(3):
            m[L['X0'] + 0x20 * k + b] = (X >> 8 * k) & 255
            m[L['Y0'] + 0x20 * k + b] = (Y >> 8 * k) & 255
        put.append((x, y))
    for b in range(1, 16):
        m[L['BON'] + b] = 0
    for b in range(1, nred + 1):
        for _ in range(10000):
            if pack:
                x, y, d = rnd.gauss(2780, 90), rnd.gauss(889, 90), 54
            elif rnd.random() < 0.7:
                x, y, d = rnd.uniform(1900, 3400), rnd.uniform(300, 1478), 58
            else:
                x, y, d = rnd.uniform(60, 3509), rnd.uniform(60, 1718), 58
            if 40 < x < 3529 and 40 < y < 1738 and free(x, y, d):
                place(b, x, y)
                break
    for _ in range(10000):
        x, y = (rnd.uniform(60, 737), rnd.uniform(60, 1718)) if pack else \
               (rnd.uniform(60, 3509), rnd.uniform(60, 1718))
        if free(x, y, 80):
            place(0, x, y)
            break
    m[L['REDSL']] = sum(m[L['BON'] + b] for b in range(1, 16))
    for n in ('EXPCOL', 'ONK', 'INHAND', 'HWAIT', 'FOVER', 'BRK'):
        m[L[n]] = 0
    for n in ('SCLO', 'SCHI'):
        m[L[n]] = m[L[n] + 1] = 0
    m[L['TURN']] = 1


def _shot_task(task):
    """one table, one computer shot (his aim error) in the game's rules -> (kind,
    the ball played, potted, foul, the ease after it, plan s).  The ease after it
    (cue-club's, from where the cue ball stopped): a red potted -> the black's; a
    colour potted -> the easiest red's; a safety -> the opponent's easiest pot"""
    xex, opp, seed, nred, kind = task
    if xex not in _AI:
        g = Game(xex)
        g.vx.beam = False
        g.init()
        _AI[xex] = (g, g.snapshot())
    g, snap = _AI[xex]
    g.restore(snap)
    rnd = random.Random(seed)
    m, L, v = g.cpu.mem, g.L, g.vx.vram
    va = lambda name: (L['AI_BANK'] << 12) + L[name] - 0x2000
    m[L['OPP']] = opp
    m[L['PTY']] = 0
    _brk_layout(g, rnd, 0 if kind >= 3 else nred, kind == 1)
    if kind == 2:                           # a red just potted: on a colour
        m[L['EXPCOL']] = m[L['ONK']] = 1
    if kind >= 3:                           # the colours: 3 the last black, 4 all six, on the yellow
        for b in range(16, 21 if kind == 3 else 16):
            m[L['BON'] + b] = 0
        lo = next(b for b in range(16, 22) if m[L['BON'] + b])
        m[L['ONK']], m[L['ONV']] = 2, lo - 14
    nerve = v[va('AI_DML') + opp - 1] | v[va('AI_DMH') + opp - 1] << 8
    if os.environ.get('NOERR'):             # (no aim error: what the plan itself leaves)
        for i in range(5):
            v[va('AI_ERR') + i] = v[va('AI_ERRL') + i] = 0
    for f in range(8):
        c0 = g.cpu.cycles
        g.frame()
        if m[L['AIST']] == 1:
            break
    else:
        return None
    dc = g.cpu.cycles - c0
    bt = m[L['BT']]
    pot = bt != 0xFF and (m[L['BEST']] | m[L['BEST'] + 1] << 8) <= nerve
    before = [m[L['BON'] + b] for b in range(22)]
    sc = lambda p: m[L['SCLO'] + p] | m[L['SCHI'] + p] << 8
    o0 = sc(0)
    t = m[L['TGT']] | m[L['TGT'] + 1] << 8
    m[L['AIMANG']], m[L['AIMANG'] + 1], m[L['AIMFRAC']] = (t >> 6) & 255, t >> 14, (t << 2) & 255
    m[L['TURN']] = 0
    m[0x0278], m[0x0284] = 15, 1
    g.cpu.wr(0xD65E, 0x38)
    g.cpu.wr(0xD65F, 0x80)
    g.call('AIM_UPDATE')
    m[L['TURN']] = 1
    m[L['PWR']:L['PWR'] + 3] = bytes(m[L['TPW']:L['TPW'] + 3])
    g.call('FIRE_CUE')
    first = None
    on0 = _cc_on(m, L)
    for _ in range(20000):
        g.call('TICK_ALL')
        if first is None:
            first = next((b for b in range(1, 22) if m[L['AWK'] + b]), None)
        if not any(m[L['AWK'] + i] for i in range(22)):
            break
    m[L['WASMOV']] = 1
    potted = bt < 22 and before[bt] and not m[L['BON'] + bt]
    why = ('cue down' if not m[L['BON']] else 'no ball hit' if first is None else
           'first %s (not on)' % BALLS[first] if first not in on0 else
           'a ball not on potted' if any(before[b] and not m[L['BON'] + b] for b in range(1, 22) if b not in on0) else 'other')
    m[L['OPP']] = 0                         # (the rules' frame: no plan in it)
    g.frame()
    foul = sc(0) > o0
    e = None
    if m[L['BON']]:
        balls = {b: _bpos(m, L, b) for b in range(22) if m[L['BON'] + b]}
        if not pot:
            e = _cc_ease(balls, _cc_on(m, L), balls[0])
        elif bt < 16:
            e = _cc_ease(balls, [21], balls[0]) if 21 in balls else 0.0
        elif kind >= 3:                     # the next colour in the sequence
            nx = [b for b in range(bt + 1, 22) if b in balls][:1]
            e = _cc_ease(balls, nx, balls[0]) if nx else None
        else:
            e = _cc_ease(balls, [b for b in range(1, 16) if b in balls], balls[0])
    cue = _bpos(m, L, 0) if m[L['BON']] else None
    return ('POT' if pot else 'SAFE', bt, potted, foul, e, dc / 1.77e6, t, cue, why if foul else None)


def colour_bench(xex, n, opp=5, seed=31):
    """the colours: n tables with all six on their spots (on the yellow) -> the next
    colour on after the pot, the plan time; n with the black alone -> the plan time"""
    rnd = random.Random(seed)
    tasks = [(xex, opp, rnd.randrange(1 << 30), 0, 3 + (k & 1)) for k in range(n)]
    t0 = time.time()
    with _pool() as pool:
        res = pool.map(_shot_task, tasks, chunksize=2)
    for kind, name in ((4, 'six colours'), (3, 'the last black')):
        rr = [r for t, r in zip(tasks, res) if r and t[4] == kind]
        ok = [r for r in rr if r[0] == 'POT' and r[2] and not r[3] and r[4] is not None]
        pl = sorted(r[5] for r in rr)
        print('%-15s %3d tables: potted %3d, the next colour on %3d (ease %.3f); plan median %.1f s, max %.1f s' % (
            name, len(rr), sum(1 for r in rr if r[0] == 'POT' and r[2]), sum(1 for r in ok if r[4]),
            sum(r[4] for r in ok) / max(1, len(ok)), pl[len(pl) // 2] if pl else 0, pl[-1] if pl else 0))
    print('(%.1f s)' % (time.time() - t0))


def shot_bench(xex, n, opp=5, seed=21, out=None):
    """1. nahravanie: after a red potted, can the black be potted from where the cue
    ball stopped (and how easily); after a colour potted, a red.  2. istoty: after a
    safety, the opponent's easiest pot (0: none), fouls.  One shot a table, n tables
    (open reds / the pack with the cue ball in baulk / on a colour)"""
    rnd = random.Random(seed)
    tasks = [(xex, opp, rnd.randrange(1 << 30), rnd.randint(4, 15), k % 3) for k in range(n)]
    t0 = time.time()
    with _pool() as pool:
        res = [r for r in pool.map(_shot_task, tasks, chunksize=2) if r]

    def line(name, rr):
        ok = [r for r in rr if r[2] and not r[3] and r[4] is not None]
        es = [r[4] for r in ok]
        on = sum(1 for e in es if e)
        print('   %-18s potted %3d of %3d: next ball on %3d (%2d %%), ease mean %.3f' % (
            name, len(ok), len(rr), on, 100 * on // max(1, len(es)), sum(es) / max(1, len(es))))
    print('1. nahravanie')
    line('red -> the black', [r for r in res if r[0] == 'POT' and r[1] < 16])
    line('colour -> a red', [r for r in res if r[0] == 'POT' and r[1] >= 16])
    ps = [r for r in res if r[0] == 'SAFE']
    se = [r[4] for r in ps if not r[3] and r[4] is not None]
    fo = sum(1 for r in ps if r[3])
    op = sum(1 for e in se if e)
    print('2. istoty: %d, fouls %d (%d %%); the opponent has a pot %d of %d (%d %%), ease mean %.3f' % (
        len(ps), fo, 100 * fo // max(1, len(ps)), op, len(se), 100 * op // max(1, len(se)),
        sum(se) / max(1, len(se))))
    fw = {}
    for r in ps:
        if r[8]:
            fw[r[8]] = fw.get(r[8], 0) + 1
    if fw:
        print('   the fouls: ' + ', '.join('%s %d' % kv for kv in sorted(fw.items(), key=lambda kv: -kv[1])))
    pl = sorted(r[5] for r in res)
    print('plan on the Atari: median %.1f s, max %.1f s   (%.1f s)' % (pl[len(pl) // 2], pl[-1], time.time() - t0))
    if out:                                     # the choices, to prove a rewrite left them as they were
        json.dump([[r[0], r[1], r[6], r[7]] for r in res], open(out, 'w'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('xex', nargs='*')
    ap.add_argument('--scenario', default='break')
    ap.add_argument('--procs', action='store_true')
    ap.add_argument('--out')
    ap.add_argument('--compare', nargs=2)
    ap.add_argument('--compare-pos', nargs=2, help='physics divergence in mm between two runs')
    ap.add_argument('--micro', action='store_true')
    ap.add_argument('--cases', type=int, default=3000)
    ap.add_argument('--report', help='write a bench_fps.txt-style report (needs --procs)')
    ap.add_argument('--window', help='a:b -- profile only frames a..b-1 (e.g. the break impact)')
    ap.add_argument('--shot', help='write a PNG of the visible screen after the scenario')
    ap.add_argument('--ai', type=int, help='the computer players: pots over N random positions')
    ap.add_argument('--colours', type=int, help='the colours: the plan time, the next colour on (N tables)')
    ap.add_argument('--shots', type=int, help='1. nahravanie, 2. istoty: one computer shot on N tables')
    ap.add_argument('--ai-calib', action='store_true', help='the safety model tables from the physics')
    ap.add_argument('--ai-safe', type=int, help='the safeties on the full rack: plan vs real at N places')
    ap.add_argument('--ai-play', nargs='+', type=int, metavar='N',
                    help='OPP SHOTS [SEED]: the computer plays real frames, a line a shot')
    ap.add_argument('--sim', action='store_true', help="sim_shot: the AI's simulated shot vs a real one")
    ap.add_argument('--cushion', action='store_true', help='the cushion: the fixed point vs Mathavan 2010')
    ap.add_argument('--phys', action='store_true', help='cut angles and top / back spin vs the textbook')
    ap.add_argument('--ai-model', action='store_true', help="the cue ball after the contact: the AI's model vs the game")
    ap.add_argument('--break', dest='brk', type=int, help='the opening shot searched in the physics: 1 coarse, 2 fine')
    ap.add_argument('--at', help="X,Y (mm): the cue ball's place for --break (aihand.asm's bo_* places)")
    ap.add_argument('--safe-search', type=int, help="a safety searched in the physics before ai_play's shot N")
    a = ap.parse_args()
    if a.ai_calib:
        ai_calib(a.xex[0] if a.xex else 'build/snooker.xex')
        return
    xx = a.xex[0] if a.xex else 'build/snooker.xex'
    if a.colours:
        colour_bench(xx, a.colours)
        return
    if a.shots:
        shot_bench(xx, a.shots, out=a.out)
        return
    if a.ai_safe:
        ai_safe(xx, a.ai_safe)
        return
    if a.ai_play:
        if len(a.ai_play) > 3 and a.ai_play[3]:     # OPP SHOTS SEED 1: the game as it is
            ai_play_game(xx, a.ai_play[0], a.ai_play[1], a.ai_play[2])   # SEED: the frames waited first
        else:
            ai_play(xx, *a.ai_play[:3])
        return
    if a.sim:
        sim_check(xx)
        return
    if a.cushion:
        fx_check()
        fx_asm(xx)
        return
    if a.ai_model:
        ai_model_check(xx)
        return
    if a.brk:
        break_search(xx, a.brk == 1, tuple(float(v) for v in a.at.split(',')) if a.at else None)
        return
    if a.safe_search:
        safe_search(xx, a.safe_search)
        return
    if a.phys:
        phys_check_shots(xx)
        return
    if a.ai:
        ai_bench(a.xex[0] if a.xex else 'build/snooker.xex', a.ai)
        return
    window = tuple(int(v) for v in a.window.split(':')) if a.window else None
    if a.compare:
        sys.exit(0 if compare(*a.compare) else 1)
    if a.compare_pos:
        compare_pos(*a.compare_pos)
        return
    if a.micro:
        sys.exit(0 if micro(a.xex[0], a.xex[1], a.cases) else 1)
    for x in a.xex:
        res = run_scenario(x, a.scenario, a.procs, window=window, shot=a.shot)
        if a.out:
            json.dump(res, open(a.out, 'w'))
        if a.report and a.procs:
            write_report(res, a.report)


if __name__ == '__main__':
    main()
