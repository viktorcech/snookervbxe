"""century_sim.py -- the "100" a century break shows (src/century.asm): the
model of the 6502 side and the generator of its tables.  The text is a list of
rectangles on a coarse grid (the digits drawn below); every frame each grid
edge is mapped ONCE to the screen (EX[i], EY[i]: a 24-bit accumulator stepped
by 2s, >> 9), so a rectangle is four table reads and one blitter fill --
shared edges stay shared at every scale, no cracks.  Layers, back to front:
shadow, outline, fill in three bands.  It grows from a dot (an exponential
zoom), overshoots, settles, holds, and is gone.

  python tools/century_sim.py          -> build/assets/century.inc (the asm's tables)
  python tools/century_sim.py --png    + tools/out/century.gif, century_sheet.png, century/NNN.png

Integer arithmetic only, exactly as the asm does it.
"""
import os
import sys
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
OUT = os.path.join(HERE, 'out')
INC = os.path.join(PROJ, 'build', 'assets', 'century.inc')

D1 = """
....######....
..########....
.#########....
.#########....
.####.####....
.##...####....
......####....
......####....
......####....
......####....
......####....
......####....
......####....
......####....
......####....
......####....
......####....
......####....
.############.
.############.
"""
D0 = """
....######....
..##########..
.############.
.####....####.
####......####
####......####
####......####
####......####
####......####
####......####
####......####
####......####
####......####
####......####
####......####
####......####
.####....####.
.############.
..##########..
....######....
"""
GAP = 2
BANDS = (7, 14)             # fill rows 0-6 light, 7-13 gold, 14- deep gold

CX, CY = 160, 128           # the centre of the table's area (buffer rows 16..239)
SMAX = 1100                 # 8.8: 46 grid columns -> ~198 pixels
OUTL = 3                    # the outline at SMAX, pixels (scaled with s)
SHAD = 4                    # the shadow's offset at SMAX
GROW, SETTLE, HOLD = 40, 8, 90
OVER = 1.10                 # the grow ends 10 % too big, settles back
OCT = 10                    # octaves: from SMAX / 2^OCT (a dot) up
WANT = {'shad': (8, 8, 8), 'outl': (60, 30, 0), 'fill0': (255, 245, 160),
        'fill1': (250, 205, 40), 'fill2': (215, 140, 10)}


def grid():
    a = D1.strip().split('\n')
    b = D0.strip().split('\n')
    return [x + '.' * GAP + y + '.' * GAP + y for x, y in zip(a, b)]


def rects(g):
    """row runs merged down while the run repeats (and the band is the same)
    -> (x0, y0, x1, y1, band), x1 / y1 exclusive"""
    h, w = len(g), len(g[0])
    band = lambda y: 0 if y < BANDS[0] else 1 if y < BANDS[1] else 2
    open_, out = {}, []
    for y in range(h + 1):
        runs = set()
        if y < h:
            x = 0
            while x < w:
                if g[y][x] == '#':
                    x0 = x
                    while x < w and g[y][x] == '#':
                        x += 1
                    runs.add((x0, x))
                else:
                    x += 1
        nxt = {}
        for r, y0 in open_.items():
            if r in runs and band(y0) == band(y):
                nxt[r] = y0
            else:
                out.append((r[0], y0, r[1], y, band(y0)))
        for r in sorted(runs):
            if r not in nxt:
                nxt[r] = y
        open_ = nxt
    return sorted(out, key=lambda r: (r[1], r[0]))


def s_table():
    """s for every drawn frame (8.8).  Exponential zoom: the same ratio every
    frame, so the text comes at a steady speed from a point; then it settles."""
    t = [SMAX * OVER * 2 ** (-OCT * (1 - (f + 1) / GROW)) for f in range(GROW)]
    for f in range(SETTLE):
        u = (f + 1) / SETTLE
        t.append(SMAX * (OVER + (1 - OVER) * (1 - (1 - u) ** 2)))
    return [max(1, int(v)) for v in t]


def frame_params(s, w, h):
    """what the asm's table holds for a frame: the accumulators' starts, the
    step, the outline and the shadow's offset"""
    o = max(1, (OUTL * s) // SMAX)
    d = (SHAD * s) // SMAX
    return CX * 512 - w * s, CY * 512 - h * s, 2 * s, o, d


def edges(start, step, n):
    """the asm's loop: e[i] = acc >> 9, acc += step"""
    out, acc = [], start
    for _ in range(n + 1):
        out.append(acc >> 9)
        acc += step
    return out


def frame_rects(rs, w, h, s):
    """-> [(x, y, w, h, layer)] in draw order (the list's slots)"""
    xs, ys, st, o, d = frame_params(s, w, h)
    ex, ey = edges(xs, st, w), edges(ys, st, h)
    assert ex == [CX + (((2 * i - w) * s) >> 9) for i in range(w + 1)]
    out = []
    for lay, g, f in (('shad', o, d), ('outl', o, 0), ('fill', 0, 0)):
        for x0, y0, x1, y1, b in rs:
            rw = max(1, ex[x1] - ex[x0] + 2 * g)          # never thinner than a pixel: tiny = a dot
            rh = max(1, ey[y1] - ey[y0] + 2 * g)
            out.append((ex[x0] - g + f, ey[y0] - g + f, rw, rh, lay if lay != 'fill' else 'fill%d' % b))
    for x, y, rw, rh, _ in out:
        assert 0 <= x and x + rw <= 320 and 16 <= y and y + rh <= 240, (x, y, rw, rh)
        assert rw <= 128 and rh <= 128        # the asm: W - 1, H - 1 in 7 bits (bpl clamps -1 to 0)
    return out


def bbox(fr):
    x0 = min(r[0] for r in fr)
    y0 = min(r[1] for r in fr)
    x1 = max(r[0] + r[2] for r in fr)
    y1 = max(r[1] + r[3] for r in fr)
    return x0, y0, x1 - x0, y1 - y0


def blit_cost(fr, prev):
    """blitter cycles (Altirra vbxe.cpp): a BCB 21 (+1 with AND 0), a fill 1 a
    byte, the restore copy 2"""
    return 21 + 2 * prev[2] * prev[3] + sum(22 + r[2] * r[3] for r in fr)


def nearest(pal, rgb):
    return min(range(1, 256), key=lambda i: sum((a - b) ** 2 for a, b in zip(pal[i], rgb)))


def build():
    pb = open(os.path.join(PROJ, 'build', 'assets', 'palette.bin'), 'rb').read()
    pal = [tuple(pb[i * 3:i * 3 + 3]) for i in range(256)]
    col = {k: nearest(pal, v) for k, v in WANT.items()}
    g = grid()
    w, h = len(g[0]), len(g)
    rs = rects(g)
    st = s_table()
    frames = [frame_rects(rs, w, h, s) for s in st]
    boxes = [bbox(fr) for fr in frames]
    return pal, col, w, h, rs, st, frames, boxes


def lohi(name, vals, n=2):
    out = []
    for k, suf in zip(range(n), ('l', 'm', 'h') if n == 3 else ('l', 'h')):
        out.append('%s%s dta %s' % (name, suf, ', '.join('$%02X' % ((v >> (8 * k)) & 255) for v in vals)))
    return out


def write_inc(col, w, h, rs, st, boxes):
    mb = (min(b[0] for b in boxes), min(b[1] for b in boxes))
    mb = mb + (max(b[0] + b[2] for b in boxes) - mb[0], max(b[1] + b[3] for b in boxes) - mb[1])
    pr = [frame_params(s, w, h) for s in st]
    prev = [boxes[0]] + boxes[:-1]          # a frame's list restores what the one before drew
    L = ['; century.inc -- tools/century_sim.py (do not edit): the "100" of src/century.asm',
         'CE_NR = %d              ; rectangles' % len(rs),
         'CE_NW = %d              ; grid columns, rows' % w,
         'CE_NH = %d' % h,
         'CE_NF = %d              ; drawn frames (grow + settle), then CE_HOLD frames held' % len(st),
         'CE_HOLD = %d' % HOLD,
         'CE_SHAD = %d            ; the colours (palette 1)' % col['shad'],
         'CE_OUTL = %d' % col['outl'],
         'CE_MBX = %d             ; the box every frame stays in (saved into the clean buffer)' % mb[0],
         'CE_MBY = %d' % mb[1],
         'CE_MBW = %d' % mb[2],
         'CE_MBH = %d' % mb[3],
         'ce_rx0 dta %s' % ', '.join(str(r[0]) for r in rs),
         'ce_rx1 dta %s' % ', '.join(str(r[2]) for r in rs),
         'ce_ry0 dta %s' % ', '.join(str(r[1]) for r in rs),
         'ce_ry1 dta %s' % ', '.join(str(r[3]) for r in rs),
         'ce_rc  dta %s' % ', '.join(str(col['fill%d' % r[4]]) for r in rs)]
    L += lohi('ce_xs', [p[0] for p in pr], 3)
    L += lohi('ce_ys', [p[1] for p in pr], 3)
    L += lohi('ce_st', [p[2] for p in pr])
    L += ['ce_o   dta %s' % ', '.join(str(p[3]) for p in pr),
          'ce_d   dta %s' % ', '.join(str(p[4]) for p in pr)]
    L += lohi('ce_bx', [b[0] for b in prev])
    L += ['ce_by  dta %s' % ', '.join(str(b[1]) for b in prev)]
    L += lohi('ce_bw', [b[2] - 1 for b in prev])
    L += ['ce_bh  dta %s' % ', '.join(str(b[3] - 1) for b in prev)]
    open(INC, 'w').write('\n'.join(L) + '\n')
    return mb


def main():
    pal, col, w, h, rs, st, frames, boxes = build()
    mb = write_inc(col, w, h, rs, st, boxes)
    prev = [boxes[0]] + boxes[:-1]
    cost = [blit_cost(fr, p) for fr, p in zip(frames, prev)]
    k = max(range(len(cost)), key=cost.__getitem__)
    print('grid %d x %d, %d rectangles -> %d fills a frame; %d frames drawn, %d held (%.2f s)'
          % (w, h, len(rs), 3 * len(rs), len(st), HOLD, (len(st) + HOLD) / 50))
    print('the box %s; the worst frame %d: %d blitter cycles, its top row %d' % (mb, k, cost[k], boxes[k][1]))
    print('-> %s' % os.path.relpath(INC, PROJ))
    if '--png' not in sys.argv:
        return
    from PIL import Image, ImageDraw
    bg = Image.open(os.path.join(PROJ, 'build', 'assets', 'shot_v00_z0.png')).convert('RGB')
    ims = []
    for fr in frames:
        im = bg.copy()
        px = im.load()
        for x0, y0, rw, rh, c in fr:
            rgb = pal[col[c]]
            for y in range(y0, y0 + rh):
                for x in range(x0, x0 + rw):
                    px[x, y] = rgb
        ims.append(im)
    ims += [ims[-1]] * HOLD
    os.makedirs(OUT, exist_ok=True)
    big = [im.resize((640, 480), Image.NEAREST) for im in ims]
    big[0].save(os.path.join(OUT, 'century.gif'), save_all=True,
                append_images=big[1:] + [bg.resize((640, 480))] * 10, duration=20, loop=0)
    n = len(ims)
    pick = list(range(0, GROW + SETTLE, 2)) + [80, 110] + list(range(n - 4, n))
    cols = 6
    sheet = Image.new('RGB', (320 * cols, 240 * ((len(pick) + cols - 1) // cols)))
    dr = ImageDraw.Draw(sheet)
    for k, i in enumerate(pick):
        x, y = (k % cols) * 320, (k // cols) * 240
        sheet.paste(ims[i], (x, y))
        dr.text((x + 4, y + 2), '%d  s=%d' % (i, st[min(i, len(st) - 1)]), fill=(255, 255, 255))
    sheet.save(os.path.join(OUT, 'century_sheet.png'))
    fd = os.path.join(OUT, 'century')
    os.makedirs(fd, exist_ok=True)
    for i, im in enumerate(ims):
        im.save(os.path.join(fd, '%03d.png' % i))
    print('-> tools/out/century.gif, tools/out/century_sheet.png, tools/out/century/NNN.png')


if __name__ == '__main__':
    main()
