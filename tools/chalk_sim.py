"""chalk_sim.py -- chalk marks on the cloth: a model before the asm.  A screw or
a hard shot (and a miscue) leaves a short streak on the bed just ahead of the
cue ball, along the shot (the tip dragged over the cloth); the marks are kept
in table coordinates (up to CH_N, the oldest replaced) and drawn onto the clean
table after each repaint (set_angle) as lines of a faint white, both ends
projected -- the balls then pass over them.  Gone at the
frame's end (the table brushed).

  python tools/chalk_sim.py          -> build/assets/chalk.inc (the colours, src/chalk.asm)
  python tools/chalk_sim.py --png    + tools/out/chalk_*.png

The table is rot_ref's (the asm's own renderer, ROUND_JAWS off as in the game).
"""
import math
import os
import random
import sys
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rot_ref as R            # noqa: E402

R.ROUND_JAWS = False
CH_N = 32
CHALK = (96, 164, 118)       # a faint white on the cloth (the nearest palette entry is used)


def bed_point(r, a, piv, zi, pos):
    """a point on the bed at pos (Q12) -> (screen x, buffer row) or None: as
    Renderer.ball, at level 0 (the cloth)"""
    Z = r.Z[zi]
    c, s = r.trig(a)
    du, dv = (pos[0] - piv[0]) >> 9, (pos[1] - piv[1]) >> 9
    xr, yr = R.ball_rot(c, s, du, dv) if a % R.ANG else (du, dv)
    T = xr + Z.OFF
    if not Z.valid(T, 0):
        return None
    sx, row, i = Z.project(T, yr, 0)
    return (sx + 8) >> 4, row - 8, Z.BS[min(i, len(Z.BS) - 1)]


def marks_of(shots, rnd):
    """the shots (cue x, y mm, aim deg, kind) -> the marks: short streaks along
    the shot where the tip dragged over the cloth (x0, y0, x1, y1 mm, width): a
    screw 40-70 mm ahead of the ball, 20-45 mm long; a hard shot 20-40 mm ahead,
    10-25 long; a miscue at the ball, skewed off the line"""
    out = []
    for x, y, aim, kind in shots:
        d, ln, skew = {'screw': (rnd.uniform(40, 70), rnd.uniform(20, 45), 3),
                       'hard': (rnd.uniform(20, 40), rnd.uniform(10, 25), 3),
                       'miscue': (rnd.uniform(0, 15), rnd.uniform(15, 30), 35)}[kind]
        a = math.radians(aim + rnd.uniform(-skew, skew))
        x0, y0 = x + d * math.cos(a), y + d * math.sin(a)
        out.append((x0, y0, x0 + ln * math.cos(a), y0 + ln * math.sin(a), 2 if kind == 'screw' else 1))
    return out[-CH_N:]


FADE = ((96, 164, 118), (64, 146, 92), (44, 132, 74))   # the head, then fading into the cloth


def streak(setpx, p, q, w, cols):
    """a chalk streak from p to q (screen, with the ball radius there), w thick:
    the first 40 % cols[0], the next 30 % cols[1], the rest cols[2] -- into nothing"""
    n = max(abs(q[0] - p[0]), abs(q[1] - p[1]), 1)
    for k in range(n + 1):
        c = cols[0] if k * 10 < n * 4 else cols[1] if k * 10 < n * 7 else cols[2]
        px = p[0] + (q[0] - p[0]) * k // n
        py = p[1] + (q[1] - p[1]) * k // n
        for dx in range(w if k * 10 < n * 7 else 1):          # (the tail thinner)
            setpx(px + dx - w // 2, py, c)


def nearest(pal, rgb):
    return min(range(1, 256), key=lambda i: sum((p - q) ** 2 for p, q in zip(pal[i], rgb)))


def main():
    rnd = random.Random(7)
    # a frame's worth of shots: the break-off and the replies from baulk, the reds
    # off the pack round the black and the pink, the colours from around the blue
    shots = [(597, 709, 2, 'hard'), (650, 690, 1, 'hard'), (220, 950, 0, 'hard'), (300, 820, 1, 'hard')]
    for _ in range(10):
        shots.append((rnd.uniform(2900, 3300), rnd.uniform(600, 1200), rnd.uniform(-60, 60), 'screw'))
    for _ in range(8):
        shots.append((rnd.uniform(1600, 2100), rnd.uniform(650, 1150), rnd.uniform(-40, 40), rnd.choice(('screw', 'hard'))))
    shots.append((2400, 1300, 170, 'miscue'))
    for _ in range(4):
        shots.append((rnd.uniform(500, 800), rnd.uniform(700, 1100), rnd.uniform(-20, 20), 'screw'))
    marks = marks_of(shots, rnd)
    pb = open(os.path.join(R.os.path.dirname(HERE), 'build', 'assets', 'palette.bin'), 'rb').read()
    pal = [tuple(pb[i * 3:i * 3 + 3]) for i in range(256)]
    cks = [nearest(pal, c) for c in FADE]
    print('%d marks, colours %s' % (len(marks), [(c, pal[c]) for c in cks]))
    inc = os.path.join(os.path.dirname(HERE), 'build', 'assets', 'chalk.inc')
    with open(inc, 'w') as f:
        f.write('; chalk.inc -- tools/chalk_sim.py (do not edit): the streak, faint white into the cloth' + chr(10))
        for k, c in enumerate(cks):
            f.write('CH_C%d = %d' % (k, c) + chr(10))
    print('->', os.path.relpath(inc, os.path.dirname(HERE)))
    if '--png' not in sys.argv:
        return
    r = R.Renderer(R.scene_real())
    os.makedirs(os.path.join(HERE, 'out'), exist_ok=True)
    for name, piv, deg, zi in (('d', R.PIVOTS['d'], 0, R.ZOOM_DEFAULT), ('centre', R.PIVOTS['centre'], 0, 0),
                               ('far', (3100 << 12, 900 << 12), 180, R.ZOOM_EYE)):
        a = int(round(deg / 360 * R.ANG)) % R.ANG
        buf = bytearray(r.render(a, piv, zi)[0])
        for x0, y0, x1, y1, wd in marks:
            p = bed_point(r, a, piv, zi, (int(x0 * 4096), int(y0 * 4096)))
            q = bed_point(r, a, piv, zi, (int(x1 * 4096), int(y1 * 4096)))
            if p is None or q is None:
                continue
            w = max(1, (p[2] * wd + 8) // 16)           # its width: a 16th of the ball's radius a mm-ish, >= 1

            def setpx(x, y, c):
                if 0 <= x < R.SCR_W and 0 <= y < R.SCR_H and buf[y * R.SCR_W + x] in (1, 33, 65, 97):
                    buf[y * R.SCR_W + x] = c            # (on the cloth only: baize and its shades)
            streak(setpx, p, q, w, cks)
        R.save(os.path.join(HERE, 'out', 'chalk_%s.png' % name), buf)


if __name__ == '__main__':
    main()
