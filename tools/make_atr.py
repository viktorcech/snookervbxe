"""make_atr.py -- build/snookerVBXE.atr, the bootable disk (src/atr.inc), and build/snooker.xex
cut down to the game's code [2026-10-27, after doom-rapidus-vbxe make_atr_doom.py]:

  boot sectors   the loader (build/atrboot.bin, src/atrboot.asm)
  then ONE byte stream from ATR_TITLE_SEC, every part ZX02 (zx02.exe; src/zx02.inc
  unpacks it on the Atari):
    the title's 15 banks (V:$030000 on), the photos' 16 (V:$060000 on) -- a 4 KB
      stream each, unpacked through the MEMAC window (hud.asm esc_quit reads them again)
    the XEX as records: a segment = its address + its stream (unpacked where it
      loads); INI / RUN = $02E2 / $02E0 + the address
    the other VRAM banks: their count, their numbers, a stream each

The XEX's VRAM streams are the 4 KB at $2000 that an INI on vram_next / sounds_0 /
sounds_1 copies into a bank: the load is played through (every segment into a 64 KB
image, vbank followed) and each stream INI leaves its bank's 4 KB; those INIs, the
$2000 segments only they read and the vbank segments go.  The menu's block (the last
$2000 segment: it runs from there) stays.  Every packed stream is unpacked here again
(unzx02: zx02.inc step for step) before it ships; packed streams are kept by their
input's md5 in tools/out/zx02.cache.  In place, after xex_osrom.py.

The one build script (build.ps1 merged in, 2026-10-28): mads, xex_osrom.py, the loader, the disk.

  python tools/make_atr.py              # the build -> build/snookerVBXE.atr, build/snooker.xex
  python tools/make_atr.py --assets     # the VBXE assets regenerated first
"""
import hashlib
import os
import pickle
import re
import subprocess
import sys
sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B = lambda *p: os.path.join(ROOT, 'build', *p)
OUT = os.path.join(ROOT, 'tools', 'out')
ZX02 = os.path.join(ROOT, 'docs', 'mads-src', 'compression', 'zx2', 'pc', 'zx02.exe')
CACHE = os.path.join(OUT, 'zx02.cache')


def layout():
    """atr.inc's constants (NAME = a number, or a sum of the names before it)"""
    v = {}
    for ln in open(os.path.join(ROOT, 'src', 'atr.inc')):
        m = re.match(r'\s*(\w+)\s*=\s*([^;]+)', ln)
        if m:
            v[m.group(1)] = eval(m.group(2).replace('$', '0x'), {}, dict(v))
    return v


def labels():
    lab = {}
    for ln in open(B('snooker.lab'), encoding='latin-1'):
        p = ln.strip().split('\t')
        if len(p) == 3 and p[0] == '00':
            lab[p[2]] = int(p[1], 16)
    return lab


def segments(x):
    out, i = [], 0
    while i < len(x):
        a = x[i] | x[i + 1] << 8
        if a == 0xFFFF:
            i += 2
            continue
        e = x[i + 2] | x[i + 3] << 8
        out.append((a, x[i + 4:i + 5 + e - a]))
        i += 5 + e - a
    return out


def split(x, lab):
    """the XEX -> (its segments without the VRAM streams, {bank: 4 KB} in load order)"""
    seg = segments(x)
    vbank = lab['VBANK']
    streams = {lab['VRAM_NEXT']: None, lab['SOUNDS_0']: 0x08, lab['SOUNDS_1']: 0x44}
    last2000 = max(k for k, (a, d) in enumerate(seg) if a == 0x2000)
    mem, vb, banks, keep, pend = bytearray(65536), 0, {}, [], []
    for k, (a, d) in enumerate(seg):
        mem[a:a + len(d)] = d
        if a == vbank:
            vb = d[0]
            continue                            # (the loader's bank: gone)
        if a == 0x2E2 and len(d) == 2:
            ini = d[0] | d[1] << 8
            if ini in streams:
                vb = streams[ini] if streams[ini] is not None else (vb + 1) & 255
                banks[vb] = bytes(mem[0x2000:0x3000])
                pend = []                       # (its staging: gone)
                continue
            keep += pend + [k]
            pend = []
            continue
        if 0x2000 <= a and a + len(d) <= 0x3000 and k != last2000:
            pend.append(k)                      # (kept if a non-stream INI reads it)
        else:
            keep.append(k)
    keep += pend
    return [seg[k] for k in sorted(keep)], banks


def unzx02(src):
    """src/zx02.inc step for step: an 8-bit bit buffer refilled with a stop bit, 8-bit
    Elias values (a 0 count copies 256), a match's source at out - offset - 1, an
    Elias MSB of 0 ends it -> (the bytes, the stream's length used)"""
    out, st = bytearray(), {'i': 0, 'bitr': 0x80}

    def bit():
        c = st['bitr'] >> 7
        st['bitr'] = (st['bitr'] << 1) & 0xFF
        if st['bitr'] == 0:
            b = src[st['i']]
            st['i'] += 1
            c, st['bitr'] = b >> 7, ((b << 1) | 1) & 0xFF
        return c

    def elias(ctl=None):
        v = 1
        c = bit() if ctl is None else ctl
        while c:
            v = ((v << 1) | bit()) & 0xFF
            c = bit()
        return v

    def copy(n, off):
        p = len(out) - off - 1
        for k in range(n or 256):
            out.append(out[p + k])

    off, state = 0, 'lit'
    while True:
        if state == 'lit':
            n = elias() or 256
            out += src[st['i']:st['i'] + n]
            st['i'] += n
            if not bit():
                copy(elias(), off)
                if not bit():
                    continue
        v = elias()
        if v == 0:
            return bytes(out), st['i']
        b = src[st['i']]
        st['i'] += 1
        off = (((v - 1) >> 1) << 8) | (((v - 1) & 1) << 7) | (b >> 1)
        copy((elias(b & 1) + 1) & 0xFF, off)
        state = 'new' if bit() else 'lit'


_cache = None


def _load_cache():
    global _cache
    if _cache is None:
        try:
            _cache = pickle.load(open(CACHE, 'rb'))
        except (OSError, EOFError, pickle.UnpicklingError):
            _cache = {}


def _pack(data, n):
    """zx02.exe on data (its own file pair n: the packers run side by side) -> the stream,
    cut to what unzx02 reads (zx02.exe may leave a byte or two past the end code: never
    read, and in one stream they would shift the next part), checked"""
    src, dst = (os.path.join(OUT, '_zx02_%s_%d.bin' % (w, n)) for w in ('in', 'out'))
    open(src, 'wb').write(data)
    r = subprocess.run([ZX02, '-f', src, dst], capture_output=True, text=True)
    pak = open(dst, 'rb').read() if os.path.exists(dst) else None
    for f in (src, dst):
        if os.path.exists(f):
            os.remove(f)
    if r.returncode or pak is None:
        sys.exit('zx02 failed: %s%s' % (r.stdout, r.stderr))
    pak = pak[:unzx02(pak)[1]]
    if unzx02(pak) != (data, len(pak)):
        sys.exit('zx02: a stream does not unpack to its data')
    return pak


def zx02_all(blobs):
    """every stream not in the cache packed at once, one zx02.exe a CPU core (the first
    build after the cache is gone: the slowest stream's time, not the sum)"""
    from concurrent.futures import ThreadPoolExecutor
    _load_cache()
    todo = {}
    for d in blobs:
        k = hashlib.md5(d).digest()
        p = _cache.get(k)
        if p is None or unzx02(p) != (d, len(p)):
            todo[k] = d
    import time

    def timed(d, n):
        t = time.time()
        return _pack(d, n), time.time() - t, len(d)
    slow = []
    with ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        for k, (p, t, n) in zip(todo, ex.map(timed, todo.values(), range(len(todo)))):
            _cache[k] = p
            slow.append((t, n, len(p)))
    for t, n, m in sorted(slow, reverse=True)[:3]:
        print('make_atr: zx02 %.1f s for %d B -> %d B' % (t, n, m))


def zx02(data):
    """data -> its ZX02 stream (zx02.exe, optimal), checked by unzx02"""
    _load_cache()
    key = hashlib.md5(data).digest()
    pak = _cache.get(key)
    if pak is None or unzx02(pak) != (data, len(pak)):
        pak = _cache[key] = _pack(data, 0)
    return pak


def mydos(boot, first, data, name=b'SNOOKER DAT'):
    """the disk as MyDOS sees it (docs/alt-src ATIO diskfsdos2.cpp, atadim.exe): the boot
    sectors, then the stream as ONE file from sector first on -- 125 bytes a sector, the
    next sector's number in bytes 125 (hi) / 126 (lo) (the directory entry's flag $04:
    16-bit links), the bytes used in 127 -- around the VTOC (359-360: two sectors, code
    $03, from 944 sectors on) and the directory (361-368)"""
    secs, k, s = [], 0, first
    while k < len(data):
        if 359 <= s <= 368:
            s = 369
        secs.append(s)
        k += 125
        s += 1
    n = secs[-1]
    while (n * 8) & 0xFFFF in (0x3250, 0x3350):
        n += 1                                  # (the size's bytes 'P2' / 'P3': Altirra's
    assert 944 <= n <= 1967, n                  #   diskimage.cpp takes it for a .PRO image;
                                                #   code $03: two VTOC sectors)
    img = bytearray(n * 128)
    img[:len(boot)] = boot
    for i, s in enumerate(secs):
        d = data[i * 125:(i + 1) * 125]
        nx = secs[i + 1] if i + 1 < len(secs) else 0
        img[(s - 1) * 128:s * 128] = d + bytes(125 - len(d)) + bytes([nx >> 8, nx & 255, len(d)])
    vt = bytearray(256)                         # sector 360 = bytes 0-127, 359 = 128-255
    vt[0] = 3
    vt[1:3] = (n - 2 - 11).to_bytes(2, 'little')  # (the sectors a DOS may use; all used: 0 free)
    img[359 * 128:360 * 128] = vt[:128]
    img[358 * 128:359 * 128] = vt[128:]
    img[360 * 128:361 * 128] = bytes([0x66]) + len(secs).to_bytes(2, 'little')         + first.to_bytes(2, 'little') + name + bytes(112)   # in use, locked, DOS 2, 16-bit links
    return bytes(img)


def main():
    L, lab = layout(), labels()
    x = open(B('snooker.xex'), 'rb').read()     # (build()'s whole XEX: written over below)
    segs, banks = split(x, lab)
    assert banks, 'build/snooker.xex has no VRAM streams: assembled anew? (make_atr.py builds it)'
    title, photos = open(B('assets', 'title.bin'), 'rb').read(), open(B('assets', 'photos.bin'), 'rb').read()
    tb, pb = L['ATR_TITLE_BANKS'], L['ATR_PHOTO_BANKS']
    assert len(title) <= tb * 4096 and len(photos) <= pb * 4096, 'atr.inc: too few banks'
    for b in list(banks):
        if 0x30 <= b < 0x30 + tb or 0x60 <= b < 0x60 + pb:
            del banks[b]                        # (the stream's first parts)
    lo, hi = 0x0400, 0x0500 + L['ATR_BOOT_NSEC'] * 128
    for a, d in segs:                           # the loader's RAM: no segment there
        assert a + len(d) <= lo or a >= hi, 'a segment at $%04X: the loader' % a
    rb = L['ATR_ROT_BANK']                      # the rotation points: the first quarter only
    assert rb == lab['ROT_PTS_BANK'] and lab['ROT_NRS'] == 64, 'atr.inc ATR_ROT_BANK / atrboot.asm rq'
    for b in range(rb + 8, rb + 32):
        del banks[b]                            # (atrboot.asm makes them: a quarter turn = (-y, x))
    runs = [(b, [b]) for b in sorted(banks)]    # a stream a bank: zx02.exe's time grows with
    assert len(runs) < 128                      #   the square of a stream (4 KB 0.1 s, 16 KB 2 s)
    pad = lambda d, n: d + bytes(n - len(d))
    zx02_all([pad(title, tb * 4096), pad(photos, pb * 4096)]
             + [d for a, d in segs if a not in (0x2E0, 0x2E2)]
             + [b''.join(banks[k] for k in run) for b, run in runs])
    stream, small = bytearray(), bytearray(b'\xFF\xFF')
    for blob, n in ((title, tb), (photos, pb)):
        stream += zx02(pad(blob, n * 4096))     # (one stream: zx02v.inc runs on across banks)
    for a, d in segs:
        small += bytes([a & 255, a >> 8, (a + len(d) - 1) & 255, (a + len(d) - 1) >> 8]) + d
        if a in (0x2E0, 0x2E2):
            stream += bytes([a & 255, a >> 8]) + d
        else:
            stream += bytes([a & 255, a >> 8]) + zx02(d)
    stream += bytes([len(runs)])
    for b, run in runs:
        stream += bytes([b]) + zx02(b''.join(banks[k] for k in run))
    pickle.dump(_cache, open(CACHE, 'wb'), protocol=pickle.HIGHEST_PROTOCOL)
    boot = open(B('atrboot.bin'), 'rb').read()
    assert len(boot) <= L['ATR_BOOT_NSEC'] * 128, 'atr.inc: the loader outgrew its sectors'
    img = mydos(pad(boot, L['ATR_BOOT_NSEC'] * 128), L['ATR_TITLE_SEC'], stream)
    par = len(img) // 16
    hdr = bytes([0x96, 0x02, par & 255, (par >> 8) & 255, 128, 0, par >> 16]) + bytes(9)
    open(B('snookerVBXE.atr'), 'wb').write(hdr + img)
    open(B('snooker.xex'), 'wb').write(bytes(small))
    plain = len(title) + len(photos) + sum(len(d) for a, d in segs) + 4096 * len(banks)
    print('make_atr: build/snookerVBXE.atr %d sectors (%d B ZX02 <- %d B), build/snooker.xex %d B, '
          '%d VRAM banks' % (len(img) // 128, len(stream), plain, len(small), len(banks)))


def build():
    """the whole build (tools/build.ps1 merged in, 2026-10-28): with --assets the VBXE assets
    first (vbxe_export.py fails on the ROUND_JAWS scene: off by default), then the game
    (mads), the RAM under the OS ROM (xex_osrom.py), the loader (mads atrboot.asm) and the
    disk (main).  A whole XEX (code + VRAM, ~489 KB) is never left behind."""
    run = lambda *a: subprocess.run(a, cwd=ROOT).returncode == 0
    py = lambda s, *a: run(sys.executable, os.path.join('tools', s), *a)
    mads = os.path.join(ROOT, 'mads.exe')
    try:
        if '--assets' in sys.argv:
            for s in ('vbxe_export.py', 'century_sim.py', 'chalk_sim.py', 'menu_gfx.py', 'trick_sim.py'):
                if not py(s):
                    sys.exit('make_atr: %s failed' % s)
        if not run(mads, 'src/main.asm', '-o:build/snooker.xex', '-t:build/snooker.lab'):
            sys.exit('make_atr: mads src/main.asm failed')
        if not py('xex_osrom.py', 'build/snooker.xex'):
            sys.exit('make_atr: xex_osrom.py failed')
        if not run(mads, 'src/atrboot.asm', '-o:build/atrboot.bin'):
            sys.exit('make_atr: mads src/atrboot.asm failed')
        main()
    finally:
        x = B('snooker.xex')
        if os.path.exists(x) and os.path.getsize(x) > 65536:
            os.remove(x)
            print('make_atr: build/snooker.xex removed -- the whole XEX (the disk was not made)')


if __name__ == '__main__':
    build()
