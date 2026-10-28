"""trick_sim.py -- the trick shots (the menu's TRICK SHOTS): each a set of balls and
the cue ball's place on the snooker table, the balls that must drop, and a shot
that makes it (aim, power, tip) found in the game's own physics (asm_bench's
Game: the balls placed, FIRE_CUE, TICK_ALL to rest).  Sources: docs/
trick_shot_top_10.pdf (Dr Dave, billiards.colostate.edu: pool, scaled to the
snooker table: the table by its size, a cluster by ball diameters) and Jimmy
White's Snooker Masterclass (chapters 5, 6).

  python tools/trick_sim.py search NAME   the best shot for one trick (a short grid, parallel)
  python tools/trick_sim.py                build/assets/tricks.inc (the layouts, the shots found)
"""
import math
import os
import sys
import time
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import asm_bench as A          # noqa: E402

XEX = os.path.join(os.path.dirname(HERE), 'build', 'snooker.xex')
L, W, R = 3569.0, 1778.0, 26.25
D = 2 * R
B = {n: i for i, n in enumerate(A.BALLS)}       # cue, r1..r15, yel grn brn blu pnk blk
POCKETS = {'bl': (0, 0), 'bm': (L / 2, 0), 'br': (L, 0), 'tl': (0, W), 'tm': (L / 2, W), 'tr': (L, W)}
_G = {}


def game():
    if 'g' not in _G:
        g = A.Game(XEX); g.vx.beam = False; g.init()
        _G['g'] = (g, g.snapshot())
    return _G['g']


def setup(g, cue, balls):
    """every ball off but these: cue (x, y) mm, balls {id: (x, y)}"""
    m, L_ = g.cpu.mem, g.L
    for b in range(22):
        m[L_['BON'] + b] = 0
        for k in ('X0', 'X1', 'X2', 'Y0', 'Y1', 'Y2'):
            m[L_[k] + b] = 0xFF
    for b, (x, y) in [(0, cue)] + list(balls.items()):
        for k, v in enumerate((int(round(x * 4096)), int(round(y * 4096)))):
            for j in range(3):
                m[L_[('X%d', 'Y%d')[k] % j] + b] = (v >> 8 * j) & 255
        m[L_['BON'] + b] = 1
    m[L_['INHAND']] = 0


def play(task):
    """(cue (x, y), balls ((id, x, y), ...), aim 1/64 units, power, spin, side) ->
    (balls potted, the cue potted, the first ball hit)"""
    cue, balls, t, pw, spin, side = task[:6]
    need = task[6] if len(task) > 6 else ()
    g, snap = game()
    m, L_ = g.cpu.mem, g.L
    g.restore(snap)
    setup(g, cue, {b: (x, y) for b, x, y in balls})
    m[L_['AIMANG']], m[L_['AIMANG'] + 1], m[L_['AIMFRAC']] = (t >> 6) & 255, (t >> 14) & 3, (t << 2) & 255
    m[L_['TURN']] = 0
    m[0x0278], m[0x0284] = 15, 1
    g.cpu.wr(0xD65E, 0x38)
    g.cpu.wr(0xD65F, 0x80)
    g.call('AIM_UPDATE')
    m[L_['PWR']:L_['PWR'] + 3] = bytes([pw & 255, (pw >> 8) & 255, pw >> 16])
    m[L_['SPIN']], m[L_['SIDE']] = spin, side
    g.call('FIRE_CUE')
    first = None
    nb = [b for b in need if b != 'cue']               # the needed balls: their place each frame
    last = {}                                           #   (the pocket a potted one fell in)
    for _ in range(9000):
        g.call('TICK_ALL')
        if first is None:
            first = next((b for b in range(1, 22) if m[L_['AWK'] + b]), None)
        for b in nb:
            if m[L_['BON'] + b]:
                last[b] = A._bpos(m, L_, b)
        if not any(m[L_['AWK'] + i] for i in range(22)):
            break
    down = [b for b, x, y in balls if not m[L_['BON'] + b]]
    ends = {b: (A._bpos(m, L_, b) if m[L_['BON'] + b] else None) for b, x, y in balls}
    return down, not m[L_['BON']], first, ends, last, {b: (x, y) for b, x, y in balls}


def made(tr, r):
    """the trick done: every ball it needs down and nothing else; the cue ball down only
    when it is one; the trick's own check (the pocket, the balls that must move) too"""
    down, cue_down, first = r[:3]
    need = [n for n in tr['need'] if n != 'cue']
    ok = all(b in down for b in need) if tr.get('extra_ok') else sorted(down) == sorted(need)   # (extra_ok: others may drop too)
    ok = ok and (cue_down == ('cue' in tr['need']))
    return ok and ('check' not in tr or tr['check'](r))


def pocket_of(pos):
    """the pocket nearest a ball's last place on the table"""
    return min(POCKETS, key=lambda n: math.hypot(POCKETS[n][0] - pos[0], POCKETS[n][1] - pos[1]))


def all_moved(r, ids, d=40.0):
    """every ball of ids left its place (potted counts) by at least d mm"""
    return all(r[3][b] is None or math.hypot(r[3][b][0] - r[5][b][0], r[3][b][1] - r[5][b][1]) >= d for b in ids)


def aim_at(src, dst):
    return int(round(math.atan2(dst[1] - src[1], dst[0] - src[0]) / (2 * math.pi) * 65536)) & 0xFFFF


def cnt(lay, idx, ang):
    """the PDF's aim: the white's centre at its contact with ball idx of lay({}), ang degrees
    round that ball (0 right, 90 up) -- where the drawing's white line ends"""
    b = lay({})[1][idx]
    return b[1] + D * math.cos(math.radians(ang)), b[2] + D * math.sin(math.radians(ang))


def crease(lay, i, j, dlt=0.0):
    """the white's centre at the crease of balls i (above), j of lay({}), from the left -- at
    its contact with j, dlt below the crease (0: touching both at once)"""
    bs = lay({})[1]
    b = math.asin(((bs[i][2] - bs[j][2]) / 2 - dlt) / D)
    return bs[j][1] - D * math.cos(b), bs[j][2] + D * math.sin(b)


# --- the tricks: a builder (its parameters -> the cue ball, the balls), the balls
# that must drop ('cue': an in-off), the aim's first guess (from the cue ball)
def sep(balls, gap=0.25):
    """balls read off a picture closer than a ball's width: pushed apart, each pair
    to D + gap (touching, never overlapping)"""
    bl = [list(b) for b in balls]
    for _ in range(20):
        moved = False
        for i in range(len(bl)):
            for j in range(i + 1, len(bl)):
                dx, dy = bl[j][1] - bl[i][1], bl[j][2] - bl[i][2]
                d = math.hypot(dx, dy)
                if d < D + gap - 1e-6:
                    k = (D + gap - d) / 2 / d
                    bl[i][1] -= dx * k; bl[i][2] -= dy * k
                    bl[j][1] += dx * k; bl[j][2] += dy * k
                    moved = True
        if not moved:
            break
    return [tuple(b) for b in bl]


def l_inoff(p):          # Jimmy White fig. 32A: the white at the green end of the D, half-ball on the pink
    return (737, 1141), [(B['pnk'], 2677, 889)]


def l_plant(p):          # JW fig. 38B: the blue on its spot, a red touching it up the table, from the D
    return (650, 889), [(B['blu'], 1784.5, 889), (B['r1'], 1784.5 + D, 889)]


def l_cannon(p):         # JW ch. 5: green and brown on their spots, the white on the yellow's: brown off green
    return (737, 597), [(B['grn'], 737, 1181), (B['brn'], 737, 889)]


def l_double(p):         # a double: the blue off the top side cushion back into the bottom middle pocket
    bx, by = 1784.5 + p.get('bx', 220), p.get('by', 450)
    return (bx + 40, by - 300), [(B['blu'], bx, by)]


def l_twosides(p):       # the PDF's 1a: a pair split by the cue ball into the middle pockets, a pair
    g, xa, xb = p.get('g', 19), p.get('xa', 1297), p.get('xb', 2075)   # touching to the corners
    return (785, W / 2 + p.get('dy', 0)), [(B['r1'], xa, W / 2 + R + g), (B['r2'], xa, W / 2 - R - g),
                          (B['r3'], xb, W / 2 + R), (B['r4'], xb, W / 2 - R)]


def l_jailed(p):         # the PDF's 4: the black in a ring of six, shot along the diagonal to a corner
    cx, cy = L / 2, W / 2
    ph = math.atan2(-cy, -cx) + p.get('rot', 0.0)            # the ring ball towards the bottom-left corner
    ring = [B['r%d' % (k + 1)] for k in range(6)]
    balls = [(B['blk'], cx, cy)] + [(ring[k], cx + D * math.cos(ph + k * math.pi / 3),
                                     cy + D * math.sin(ph + k * math.pi / 3)) for k in range(6)]
    dcue = p.get('dcue', 400)
    return (cx + (D + dcue) * math.cos(ph), cy + (D + dcue) * math.sin(ph)), balls


def l_blueinoff(p):      # JW fig. 32B: the white at the yellow end of the D, half-ball on the blue
    return (737, 889 - 292 + 40), [(B['blu'], 1784.5, 889)]


def l_cannonpot(p):      # JW fig. 33A: a loose red by the black, cannoned off it into the top corner
    bx, by = 3245, 889
    rx, ry = bx - 70 + p.get('rx', 0), by - 60 + p.get('ry', 0)
    return (2300, 700 + p.get('cy', 0)), [(B['blk'], bx, by), (B['r1'], rx, ry)]


def l_railpot(p):        # a ball tight on the top side cushion, run along it into the top corner
    x = p.get('x', 2900)
    return (x - p.get('back', 400), W - 200), [(B['yel'], x, W - R - 1)]


def l_plant3(p):         # three reds touching in a line to the top-right corner, the cue ball in line
    ux, uy = (L - 2900) / math.hypot(L - 2900, W - 1300), (W - 1300) / math.hypot(L - 2900, W - 1300)
    balls = [(B['r%d' % (k + 1)], 2900 - (2 - k) * D * ux, 1300 - (2 - k) * D * uy) for k in range(3)]
    d = p.get('d', 500)
    return (balls[0][1] - d * ux, balls[0][2] - d * uy), balls


def l_mgun(p):           # the PDF's 10: a row of reds a ball's width off the bottom cushion, the
    n, sp, x0 = int(p.get('n', 5)), p.get('sp', 1.3), p.get('x0', 2500)   # cue ball runs the alley
    gy = p.get('gy', 1.0)                   # between them and the cushion, ticking each, and pots
    balls = [(B['r%d' % (k + 1)], x0 + k * sp * D, R + D + gy) for k in range(n)]   # the black
    balls.append((B['blk'], L - p.get('bk', 160), R + 0.5))                         # by the corner
    return (x0 - p.get('back', 250), R + 0.5), balls


def l_mgunf(p):          # the machine gun, follow (the user's notes): a row of reds tight on the
    n, sp = int(p.get('n', 5)), p.get('sp', 1.5)        # bottom cushion up to the bottom-right
    xl = L - p.get('bk', 160)                           # corner, the cue ball behind them on it,
    balls = [(B['r%d' % (k + 1)], xl - (n - 1 - k) * sp * D, R + 0.5) for k in range(n)]   # top spin
    return (balls[0][1] - p.get('back', 250), R + 0.5), balls


def l_twosides2(p):      # the PDF's 1a, for contacts one at a time: the near pair staggered
    g, xa, xb, st = p.get('g', 19), p.get('xa', 1297), p.get('xb', 2075), p.get('st', 0)
    return (785, W / 2 + p.get('dy', 0)), [(B['r1'], xa, W / 2 + R + g), (B['r2'], xa + st, W / 2 - R - g),
                                           (B['r3'], xb, W / 2 + R), (B['r4'], xb, W / 2 - R)]



# --- the PDF's diagrams (tools/out/trick_pdf/sheet*.png, each panel 480 x 288, the
# cloth's pockets at 24..455 x 44..263): a cluster's place by the table's scale, its
# balls apart by ball diameters (a pool ball 9.67 px)
def pdf(x, y):
    return (x - 24) / 431 * L, (263 - y) / 219 * W


def pdfc(anchor, pts):
    ax, ay = anchor
    X, Y = pdf(ax, ay)
    k = D / 9.67
    return [(B[n], X + (x - ax) * k, Y - (y - ay) * k) for n, x, y in pts]


def rail(balls, top=True):
    """balls on the top (bottom) cushion: y tight on it"""
    return [(b, x, (W - R - 0.5) if top else R + 0.5) for b, x, y in balls]


def l_easy8(p):          # 1b: a pair by the white to the middles, pairs at both middles, a pair to the
    # corners.  Exact for the physics: the white frozen behind the gap of blu / yel (h, a as
    # 1a) so each leaves for its middle pocket, where a pair sits frozen at the mouth's edge
    # -- r3 / r2 at the jaw (d5 off the pocket's centre, tight on the rail), grn / r1 under
    # it -- the arriving ball knocks the under ball out along the rail to the far corner and
    # the jaw ball drops; ahead the corners' pair as 1a (r4 at the pink spot, blk at 45 deg)
    # The pair leaves at asin(h / D) (65 deg; struck at once, each takes 0.62 of the
    # white's speed -- physics.asm narrow.two -- enough for grn and r1's 1.8 m along the
    # rail; the white keeps 0.47, a touch of top spin carries it on to the far pair).  blu hits grn nearly full, its line of centres psi deg
    # below level: r3 above grn takes grn's upward part (r3 is in the mouth and drops), grn
    # runs level along the rail to the corner; blu keeps the rest, up into the pocket.
    # 3.5 m/s (70 %), spin 5.
    s = D + 0.25
    h = p.get('h', 47.6)
    a = math.sqrt(s * s - h * h)
    d5 = p.get('d5', -45.0)
    psi = math.radians(p.get('psi', 25.0))
    u, ph = p.get('u', W / 2), math.radians(p.get('a4', 45.0))   # the corners' pair as 1a (l_twosides3: a4, u)
    jx = L / 2 - d5
    inn = p.get('inn', 0.0)                        # r3 in from the rail line, over the pocket
    gy = W - R - 0.5 - inn - s                     # grn (and r1 below: W - gy)
    tx, ty = jx - D * math.cos(psi), gy - D * math.sin(psi)   # blu's centre at its contact with grn
    ac = math.sqrt(D * D - h * h)                  # (the white's contact is at D, not at the rest gap s)
    xr = tx - (ty - W / 2 - h) * ac / h            # blu's line of centres from the white meets it
    return (xr - a, W / 2), [(B['blu'], xr, W / 2 + h), (B['yel'], xr, W / 2 - h),
                             (B['r3'], jx, W - R - 0.5 - inn), (B['grn'], jx, gy),
                             (B['r2'], jx, R + 0.5 + inn), (B['r1'], jx, W - gy),
                             (B['r4'], L - u, W / 2), (B['blk'], L - u + s * math.cos(ph), W / 2 - s * math.sin(ph))]


def l_line4(p):          # 2: four in a column under the top middle pocket, each to its own pocket.
    # The white (dc left, off below the crease of blu / r1 -- the PDF's 2 / 3, struck low as
    # its tip shows) splits the pair: blu's upward part goes to yel (1, in the mouth: up into
    # the pocket), blu keeps the rest along the top rail to the right corner; r1's downward
    # part goes to r2 (4: the line r1 -> r2 points at the bottom middle pocket), r1 keeps the
    # rest to the right end cushion and back across the table into the left corner.  yel
    # leans dl degrees left of blu, r2 dl right of r1, so blu and r1 leave rising dl: level,
    # 80 mm off the rail, they would miss the corners' mouth (64 mm from the rail: physics.asm).
    s = D + 0.25
    dx, off, dc = p.get('dx', 20.0), p.get('off', 26.4), p.get('dc', 253.0)
    dl = math.radians(p.get('dl', 2.0))            # (dl_b, dl_r: blu's / r1's own rise)
    db, dr = math.radians(p.get('dl_b', p.get('dl', 2.0))), math.radians(p.get('dl_r', p.get('dl', 2.0)))
    x = L / 2 - dx
    y1 = W - R - 0.5
    y2 = y1 - s * math.cos(db)
    col = [(B['yel'], x - s * math.sin(db), y1), (B['blu'], x, y2), (B['r1'], x, y2 - s),
           (B['r2'], x + s * math.sin(dr), y2 - s - s * math.cos(dr))]
    return (x - dc, y2 - s / 2 - off), col


def l_redsea(p):         # 3 as drawn: the 9 (r9) on the middle line, 1 (yel) and 2 (blu) frozen to it
    # at its lower / upper left (a triangle, 1 under 2); three frozen pairs across the line
    # above it, the left ball lower (tilted t deg): the white full into r9, r9 wedges each pair
    # apart and runs on into the top middle pocket, 1 goes left, 2 up-left, the white right
    s = D + 0.25
    xm = L / 2
    y9 = p.get('y9', 560.0)
    g = p.get('g', 160.0)                          # the pairs' spacing up the line
    t = p.get('t', 0.0)                            # the pairs' tilt (deg), the left ball lower (drawn ~16: the
                                                   #   physics parts level pairs; tilted ones throw r9 off)
    ts = (p.get('t1', t), p.get('t2', t), p.get('t3', t))
    dx = p.get('dx', 0.0)                          # the pairs' middle right of the line
    c, h = math.sqrt(3) / 2 * s, s / 2              # the triangle: 1 / 2 a ball apart, both at s from r9
    bg, yg = p.get('bg', 10.0), p.get('yg', 0.0)   # 2 (blu) / 1 (yel) off r9 by a gap (0: frozen): 2 frozen turns
                                                   #   r9 30 deg right as it leaves; 10 mm (under a pixel) clears it
    out = [(B['r9'], xm, y9), (B['yel'], xm - c - yg * c / s, y9 - h - yg * h / s), (B['blu'], xm - c - bg * c / s, y9 + h + bg * h / s)]
    rows = [(B['r3'], B['r4']), (B['r5'], B['grn']), (B['r7'], B['blk'])]
    hp = p.get('sp', 106.0) / 2                    # the pair's centres apart (s: frozen -- stops r9; 106: r9 clips
                                                   #   both thinly, the widest aim run, _dbg_tgrid.py)
    for k, ((l, r), t) in enumerate(zip(rows, ts)):
        y = y9 + g * (k + 1.2)
        tr = math.radians(t)
        out += [(l, xm + dx - hp * math.cos(tr), y - hp * math.sin(tr)), (r, xm + dx + hp * math.cos(tr), y + hp * math.sin(tr))]
    return (xm + p.get('cx', -3.0), y9 - p.get('dc', 196.0)), out  # the white 3 mm left of r9's line (1 first), 3.7 balls under it


def l_backkick(p):       # 5: off the cushion's point by the top middle pocket, into a row on the rail
    cx, cy = pdf(346, 151)                        # (cx, cy: the white moved, mm)
    rx = p.get('rx', 0.0)                         # (rx: the row moved along the rail, mm)
    return (cx + p.get('cx', 0.0), cy + p.get('cy', 0.0)), (pdfc((215, 65), [('r3', 215, 56), ('r4', 215, 74)]) +
                           rail([(b, x + rx, y) for b, x, y in pdfc((267, 51), [('yel', 257, 51), ('blu', 267, 51), ('r9', 278, 51)])]))


def toward(p, q, s):
    """the point s from p towards q"""
    dx, dy = q[0] - p[0], q[1] - p[1]
    d = math.hypot(dx, dy)
    return (p[0] + dx / d * s, p[1] + dy / d * s)


def l_butterfly(p):      # 6: two arcs of three, the white between them: six balls, six pockets.
    # Exact for the physics (a frozen ball leaves along the line of centres): the arcs'
    # middles (r5, blu) on the middle pockets' line, h above and below the white's line
    # and frozen to the white (a behind); each wing on the line from its middle to its
    # corner.  The white stops between them (its two contacts at 45 deg take everything).
    # [2026-10-27: in the physics the near wings (6, 3: behind the middles' push) get their push
    #  only after the middle ball has moved off (its contacts resolved in turn), so they leave
    #  along the line of centres AS IT IS THEN -- wn deg off the corner's line in the layout
    #  compensates; sx moves the whole figure along the table, g gaps the near wings]
    s = D + 0.25
    h = p.get('h', 37.3)
    a = math.sqrt(s * s - h * h)
    xm = L / 2 + p.get('sx', 0.0)
    wn, g = math.radians(p.get('wn', 0.0)), p.get('g', 0.0)
    m5, m2 = (xm, W / 2 + h), (xm, W / 2 - h)

    dn = p.get('dn', 0.0)              # the near wing set dn mm along the middle ball's way after its
                                       #   far-wing push (square to the far corner's line): the middle
                                       #   meets it there, the line of centres then the corner's

    def wing(src, dst, far, turn, sg):   # s + g from src towards dst, turned by `turn`, + dn along the remainder
        t = math.atan2(dst[1] - src[1], dst[0] - src[0]) + turn
        r = math.atan2(far[1] - src[1], far[0] - src[0]) + sg * math.pi / 2
        return (src[0] + (s + g) * math.cos(t) + dn * math.cos(r), src[1] + (s + g) * math.sin(t) + dn * math.sin(r))
    wf = math.radians(p.get('wf', 0.0))   # the far wings turned wf deg off their corner's line (the throw)
    return (xm - a, W / 2), [(B['r5'],) + m5, (B['grn'],) + wing(m5, (0, W), (L, W), -wn, 1), (B['r4'],) + rot(m5, (L, W), s, wf),
                             (B['blu'],) + m2, (B['r3'],) + wing(m2, (0, 0), (L, 0), wn, -1), (B['yel'],) + rot(m2, (L, 0), s, -wf)]


def rot(src, dst, s, turn):
    """s from src towards dst, turned by `turn` (radians, counter-clockwise)"""
    t = math.atan2(dst[1] - src[1], dst[0] - src[0]) + turn
    return (src[0] + s * math.cos(t), src[1] + s * math.sin(t))


def l_clearance(p):      # 7 as drawn (2026-10-27, the picture measured): on the top rail the blue (2)
    # and the purple (4) apart, the yellow (1) frozen under 2 (a little left), the red (3) under 4;
    # then a gap and the black (8) heading a frozen row of six (14 .. 9) along the rail; near the
    # right corner the 7 over the 5 with the 6 frozen to both on their right; the 15 under the
    # rail by the top middle pocket.  The chain: the white into 1 from the left, 1 into 3, 3 into
    # the cluster, 7 up-left into 9, the row passes it to 8, 8 runs the rail and off the 15 into
    # the middle pocket; 2 and 4, knocked into the rail by 1 and 3, bounce clear of 8's way.
    s = D + 0.25
    yr = W - R - 0.5
    x2, x4, x8 = p.get('x2', 2207.0), p.get('x4', 2397.0), p.get('x8', 2601.0)
    y2 = yr - p.get('d2', 19.0)                    # the blue a little off the rail (the picture)
    # 1 under 2, 3 under 4 (the angle from 2 / 4 down to them): a little left of straight down,
    # so 1 and 3, struck from the left, keep a rightward way after shoving 2 / 4 into the rail
    # (a frozen ball keeps only the part square to the line of centres); 3 rises to the rail
    # and runs it into 9 -- the row passes it to 8, which runs the rail back to the 15
    a1, a3 = math.radians(p.get('a1', 262.0)), math.radians(p.get('a3', 260.0))
    row = [(B['blk'], x8, yr)] + [(B[n], x8 + k * s, yr) for k, n in enumerate(('r14', 'r13', 'r12', 'r11', 'r10', 'r9'), 1)]
    x7, y7 = p.get('x7', 3408.0), p.get('y7', 1574.0)
    c = math.sqrt(0.75) * s
    return (p.get('cx', 1543.0), p.get('cy', 1323.0)), (
        [(B['blu'], x2, y2), (B['yel'], x2 + s * math.cos(a1), y2 + s * math.sin(a1)),
         (B['r4'], x4, yr - p.get('d4', 0.0)), (B['r3'], x4 + s * math.cos(a3), yr - p.get('d4', 0.0) + s * math.sin(a3))] + row +
        [(B['r15'], p.get('x15', 1754.0), p.get('y15', yr - 0.7 * D)),   # 0.7 D under the rail line: 8 clips it
                                                                           #   where the middle pocket is
         (B['r7'], x7, y7)] + [(B[n], x7 + (s + gp) * math.cos(math.radians(a + p.get('rot', 0.0))), y7 + (s + gp) * math.sin(math.radians(a + p.get('rot', 0.0))))
                               for n, a, gp in (('r5', -90.0, p.get('g7', 0.0)), ('grn', -30.0, p.get('g6', 0.0)))])   # the 5 under the 7 (g7: a gap), the
                               #   6 on their right (g6: its gap); rot turns the pair about the 7


def l_combo(p):          # 8 as drawn (2026-10-27): by the top rail the 2 frozen over the 1, two and a half
    # balls right the 3 over the 4 with the 5 frozen below-right of the 4; the 6 in the far bottom
    # corner's jaws; the white far left by the rail.  The white into the 1 from the lower left: the
    # 1 shoves the 2 up (off the rail it runs down to the bottom middle pocket) and goes on into the
    # 4 from a little above -- the 4 sends the 5 down-right to the corner and, turning up-right,
    # the 3 up into the top middle pocket, then runs the rail to the top right corner; the 1 kisses
    # up-right into the top middle pocket; the white, top and left side, kicks four cushions round
    # the table into the 6
    s = D + 0.25
    x1, y1 = p.get('x1', 1655.0), p.get('y1', 1654.0)      # (the defaults are the tuned values: cnt() lays out with {})
    x4, y4 = p.get('x4', 1807.0), p.get('y4', 1640.0)
    a2, a3, a5 = (math.radians(p.get(k, v)) for k, v in (('a2', 84.0), ('a3', 72.5), ('a5', -43.0)))
    return (p.get('cx', 1126.0), p.get('cy', 1697.0)), [
        (B['blu'], x1 + s * math.cos(a2), y1 + s * math.sin(a2)), (B['yel'], x1, y1),
        (B['r3'], x4 + s * math.cos(a3), y4 + s * math.sin(a3)), (B['r4'], x4, y4),
        (B['r5'], x4 + s * math.cos(a5), y4 + s * math.sin(a5)), (B['grn'], p.get('x6', 99.0), p.get('y6', 97.0))]


def l_follow(p):         # 9 as drawn (2026-10-27, read off the page at the table's scale): the 1 by the
    # right rail at mid table, 38 mm off the cushion (a ball on the rail comes back off it into
    # the white; this one is past it by then), the 2 loose 125 mm above it, out of the way, the
    # 9 in the bottom right corner's jaws; the white up-left.  Half ball into the 1 from the
    # upper left, top and right side, hard: the 1 goes into the rail and off it down-left, three
    # rails round the table into the bottom right corner; the white curves down the rail into the 9
    # (tuned 2026-10-27: the pair 11 mm lower than read, the 9 14 mm up the jaw, the white 115 mm
    #  nearer the pair so it comes in at 51 deg, not 43 -- the physics' follow needs the steeper line
    #  to curve the white back on to the rail; cnt() lays out with {}, so these are the defaults)
    return (p.get('cx', 3113.0), p.get('cy', 1296.0)), [
        (B['blu'], p.get('x2', 3474.0), p.get('y2', 985.0)), (B['yel'], p.get('x1', 3479.0), p.get('y1', 860.0)),
        (B['r9'], p.get('x9', 3462.0), p.get('y9', 85.0))]


def l_twosides3(p):      # 1a as drawn, made exact for the physics (a ball leaves along the line of
    # centres at the contact): the white frozen in the gap of a pair, each of the pair on the
    # line from the white's centre to its middle pocket (75.2 deg); ahead, 3 on the centre line
    # 889 mm from the top cushion (the pink spot) with 4 frozen at 45 deg below-right: 4 leaves
    # along 3->4 into the bottom corner, 3 square to it into the top corner (the diagonal:
    # the only pair whose both ways end in the corners)
    s = D + 0.25                                   # frozen (sep's gap)
    h = p.get('h', 49.0)                           # the pair right above and below the white (the PDF: frozen, a little ahead:
                                                   #   19 mm here -- less and they leave too square to reach the middles)
    a = math.sqrt(s * s - h * h)                   # the white's centre that far behind the pair
    xr = L / 2 - (W / 2 - h) * a / h               # the pair's x: the line of centres meets the pocket
    st = p.get('st', 0.0)                          # (the second of the pair a little further on: tried
    # while the engine resolved the two contacts one after the other; the physics now takes
    # both from the velocity the white moved with, as one event -- physics.asm narrow,
    # rewind: MV)
    # [2026-10-27: the far pair a4 deg (45 as drawn) and u mm from the end rail (W/2 = the pink
    #  spot): 3 leaves 2.3 deg short of square to the pair in the physics (the two contacts), so
    #  at 45 it reaches the end rail 98 mm off the top rail -- outside the corners' 64 mm mouth
    #  (physics.asm mouthx); at a4 = 43.85, u = 905 both 3 (43.85 - 2.3 + ..) and 4 (along
    #  the pair) run into their corners]
    u, ph = p.get('u', W / 2), math.radians(p.get('a4', 45.0))
    return (xr - a, W / 2), [(B['r1'], xr, W / 2 + h), (B['r2'], xr + st, W / 2 - h),
                             (B['r3'], L - u, W / 2), (B['r4'], L - u + s * math.cos(ph), W / 2 - s * math.sin(ph))]


def l_jailed2(p):        # 4 as drawn: the black in a ring of six right of the middle, the white at A
    cx, cy = pdf(345, 151)
    ph = math.atan2(-cy, -cx)
    ring = [B['r%d' % (k + 1)] for k in range(6)]
    return pdf(292, 188), [(B['blk'], cx, cy)] + [(ring[k], cx + D * math.cos(ph + k * math.pi / 3),
                                                   cy + D * math.sin(ph + k * math.pi / 3)) for k in range(6)]


def l_ticky(p):          # 10 as drawn: a row of seven off the bottom rail, the white in the alley
    k = D / 9.67         #   between them and the rail, the black in the corner
    py = lambda y: R + 0.5 + (263 - 9.67 / 2 - y) * k
    ax = pdf(390, 0)[0]
    px_ = lambda x: ax + (x - 390) * k
    row = [(B['r%d' % (j + 1)], px_(x), py(239)) for j, x in enumerate((351, 362, 372, 382, 393, 403, 413))]
    return (px_(338), py(249)), row + [(B['blu'], px_(310), py(237)), (B['yel'], px_(318), py(242)),
                                       (B['blk'],) + (L - R - 30, R + 0.5)]


def rail_r(balls):
    return [(b, L - R - 0.5, y) for b, x, y in balls]

# --- Steve Davis's trick shot show (docs/tricks/*.png, top views, baulk on the left):
# the pixels read off the pictures, the cloth 175..1665 x 185..935 -> the table's mm
def px(x, y):
    return (x - 175) / 1490 * L, (935 - y) / 750 * W


def davis(cue, reds, extra):
    out = [(B['r%d' % (k + 1)],) + px(*r) for k, r in enumerate(reds)]
    out += [(B[n],) + px(*c) for n, c in extra]
    return px(*cue), out


def l_d1(p):             # trick1 (its set-up as played: trick1a.png, its camera's view mapped onto
    # trick1's by the balls both show): into the two reds together (r6, r7), r7 off the jaw of
    # the bottom-right pocket into the four by the black, the white on to the lone red r5 (out of
    # the black's way), the black up the rail into the top-right pocket (docs/tricks 1.png..5.png).
    # r7 turned r7t deg about r6 (1.8 mm, within the picture's reading): where it leaves the pair --
    # as read it met the cushion 160 mm from the corner, +6 dropped; +2 the jaw (_dbg_d1png.py)
    cue, balls = davis((1327, 558.6), [(1626, 203), (1536, 504.1), (1533.5, 543.6), (1502.6, 527.5), (1648, 603),
                                       (1490, 692.1), (1499, 711), (1598.2, 687.4), (1575.1, 681.7), (1582.3, 703.6),
                                       (1653, 752.1), (1654, 774), (1654, 796), (1648, 816.9)], [('blk', (1652.1, 729.1))])
    (b6, x6, y6), (b7, x7, y7) = balls[5], balls[6]
    a = math.atan2(y7 - y6, x7 - x6) + math.radians(p.get('r7t', 2.0))
    balls[6] = (b7, x6 + D * math.cos(a), y6 + D * math.sin(a))
    return cue, balls


def l_d2(p):             # trick2 (docs/tricks/trick2.txt: a hard shot into the row on the bottom cushion,
    # the black in it goes to the middle pocket)
    return davis((1285, 920), [(1050, 920), (1095, 920), (1117, 920), (1139, 920), (1161, 920), (1028, 903),
                               (932, 901.4)], [('blk', (1072, 920))])   # (the red by the pocket 8 mm lower than read: the black kisses it audibly on its way in)


def l_d4(p):             # trik4 (audience participation; docs/tricks/trik4.png, 1.jpg..5.jpg): the black in a
    # flower of six reds as the video has them (r1 on the black, r2 / r3 / r6 a few mm off it,
    # r4 / r5 some 15 mm: a gap r2-r4, r3-r5), a lone red by the bottom middle pocket; the white
    # lower right, full into r5.  r5 kicks r6 (frozen) off to the left, r6 kicks r4, the black is
    # pressed into the wedge of r1 / r2 and squeezed out of it towards the bottom middle pocket --
    # the wedge sets its line: r2 turned r2t deg about the black (5 mm, within the video's
    # reading) puts it on the pocket.  Only the black may drop.  (sep: r1 read overlapping)
    cue, balls = davis((1409.5, 642.8), [(1295.5, 538.8), (1273.8, 545.5), (1315, 546.3), (1273.8, 577), (1316.3, 576.3),
                                         (1296.3, 583), (886, 910)], [('blk', (1294.5, 560.5))])
    bx, by = balls[7][1], balls[7][2]
    dx, dy = balls[1][1] - bx, balls[1][2] - by
    a = math.atan2(dy, dx) + math.radians(p.get('r2t', -7.0))
    balls[1] = (balls[1][0], bx + math.hypot(dx, dy) * math.cos(a), by + math.hypot(dx, dy) * math.sin(a))
    return cue, sep(balls)


def l_d5(p):             # trik5: the pink to the middle pocket after kisses across the reds
    return davis((407, 295.5), [(1205, 202), (1202, 222), (1278, 202), (1275, 223), (1352, 203), (1346, 222),
                                (1484, 203), (1506, 203), (1528, 203), (1548, 208), (1531, 263), (1551, 258),
                                (950, 221)], [('pnk', (1463, 203))])   # (r13 by the top middle pocket: 10 px right of its reading -- it looked in the mouth in the game)


TRICKS = {
    'TWOSIDES3': {'title': 'TWO SIDES 2 CORNERS', 'src': 'PDF 1a', 'lay': l_twosides3,
                  'need': [B['r1'], B['r2'], B['r3'], B['r4']], 'aim0': lambda c: 0},
    'JAILED2': {'title': 'JAILED 8-BALL', 'src': 'PDF 4', 'lay': l_jailed2, 'need': [B['blk']], 'first': 0},   # (not in the game: it needs cues laid along the rails)
    'TICKY': {'title': 'MACHINE GUN TICKY', 'src': 'PDF 10', 'lay': l_ticky, 'need': [B['blk']], 'spin': 2, 'side': 6,
              'aim0': lambda c: aim_at(c, cnt(l_ticky, 8, -22))},            # the yellow (1), its lower right
    'EASY8': {'title': 'EASY EIGHT', 'src': 'PDF 1b', 'lay': l_easy8,
              'need': [B[n] for n in ('blu', 'yel', 'r3', 'grn', 'r2', 'r1', 'r4', 'blk')], 'aim0': lambda c: 0, 'spin': 5},
    # (aim0: the drawing's white line -- its first segment's end is the white's centre at
    #  the contact; measured on the PDF's pictures, see cnt / crease)
    'LINE4': {'title': 'LINE OF FOUR BALLS', 'src': 'PDF 2', 'lay': l_line4, 'spin': 1,
              'need': [B[n] for n in ('yel', 'blu', 'r1', 'r2')],
              'aim0': lambda c: aim_at(c, crease(l_line4, 1, 2, 12.0))},    # the crease of 2 / 3, 12 mm low:
              # mostly into 3 ("do cervenej pod miernym uhlom"): 3 gets 0.66 of the white's speed for its
              # 5.3 m (the end cushion keeps 0.6 of it), 4 its downward part, 2 and 1 the rest; 4.8 m/s
    'REDSEA': {'title': 'PARTING THE RED SEA', 'src': 'PDF 3', 'lay': l_redsea, 'need': [B['r9']],
               'aim0': lambda c: 16384, 'extra_ok': True,                   # straight up the table
               'check': lambda r: pocket_of(r[4][B['r9']]) == 'tm' and all_moved(r, [B[n] for n in ('r3', 'r4', 'r5', 'grn', 'r7', 'blk')])},
    'BACKKICK': {'title': 'BACK KICK OFF POINT', 'src': 'PDF 5', 'lay': l_backkick, 'need': [B['r9']], 'extra_ok': True,
                 'aim0': lambda c: aim_at(c, (L / 2 - 75.0, W)) - 300,     # 1.6 deg right of the top middle pocket's left point (pocket.asm)
                 'check': lambda r: r[2] == B['yel'] and pocket_of(r[4][B['r9']]) == 'tr'},   # off the point into the row, r9 to the corner
    'BUTTERFLY': {'title': 'SIX-BALL BUTTERFLY', 'src': 'PDF 6', 'lay': l_butterfly,
                  'need': [B[n] for n in ('grn', 'r5', 'r4', 'blu', 'r3', 'yel')], 'aim0': lambda c: 0},
    'CLEARANCE': {'title': 'CLEARANCE AND CHAIN', 'src': 'PDF 7', 'lay': l_clearance, 'spin': 2,
                  'need': [B['blk']],                          # the 8 alone goes down
                  'aim0': lambda c: aim_at(c, cnt(l_clearance, 1, 195.0))},  # the yellow (1) from the lower left: it
                  # shoves 2 into the rail and keeps its way right, on to the 3
    'COMBO': {'title': 'COMBO-KISS-KICK', 'src': 'PDF 8', 'lay': l_combo, 'spin': 6, 'side': 6,
              'need': [B[n] for n in ('blu', 'yel', 'r3', 'r4', 'r5', 'grn')],   # all six
              'aim0': lambda c: aim_at(c, cnt(l_combo, 1, 202.0))},          # the yellow (1) from below-left, 22 deg
              # under full: it shoves 2 up (84 deg: off the rail 1.75 m down into the bottom middle) and goes on
              # at 3 deg to the 4, a little above centre -- the 4 sends 5 (-43 deg) to the bottom right corner,
              # kisses 3 (72.5 deg: it goes 100 deg up into the top middle) and runs the rail at 4 deg to the top
              # right corner; the 1 climbs off the 4 into the top middle; the white (top 6, side 6) curves off
              # the 1 to the bottom rail, the right and the top rail, then crosses the table into the green
    'FOLLOW': {'title': 'FOLLOW THE RAIL', 'src': 'PDF 9', 'lay': l_follow, 'need': [B['yel'], B['r9']], 'spin': 8, 'side': 2,
               'aim0': lambda c: aim_at(c, cnt(l_follow, 1, 140.0))},        # the yellow (1) from the upper left, 40 deg
               # off full: it goes 40 deg into the rail and off it at 28 (the physics flattens a sliding ball's
               # bounce), the bottom rail right of the middle pocket, the left and the top rail, into the bottom
               # right corner -- the PDF's diamond; the white, max top, curves back on to the rail and runs it
               # down into the 9 (side 2 there; 4 does as well)
    'IN-OFF': {'title': 'HALF-BALL IN-OFF', 'src': 'JW fig 32A', 'lay': l_inoff, 'need': ['cue']},
    'PLANT': {'title': 'RIGHT-ANGLE PLANT', 'src': 'JW fig 38B', 'lay': l_plant, 'need': [B['blu']]},
    'CANNON': {'title': 'CANNON PACE', 'src': 'JW ch 5', 'lay': l_cannon, 'need': [B['brn']]},
    'DOUBLE': {'title': 'DOUBLE', 'src': 'JW fig 11', 'lay': l_double, 'need': [B['blu']]},
    'TWOSIDES': {'title': 'TWO SIDES, 2 CORNERS', 'src': 'PDF 1a', 'lay': l_twosides,
                 'need': [B['r1'], B['r2'], B['r3'], B['r4']], 'aim0': lambda c: 0},
    'BLUEINOFF': {'title': 'BLUE IN-OFF', 'src': 'JW fig 32B', 'lay': l_blueinoff, 'need': ['cue']},
    'CANNONPOT': {'title': 'CANNON POT', 'src': 'JW fig 33A', 'lay': l_cannonpot, 'need': [B['r1']], 'aim0': lambda c: aim_at(c, (3245 - 70, 889 - 60))},
    'RAILPOT': {'title': 'RAIL POT', 'src': 'PDF 9', 'lay': l_railpot, 'need': [B['yel']]},
    'PLANT3': {'title': 'THREE-BALL PLANT', 'src': 'JW fig 37A', 'lay': l_plant3, 'need': [B['r3']]},
    'MGUN': {'title': 'MACHINE GUN', 'src': 'PDF 10', 'lay': l_mgun, 'need': [B['blk']],
             'aim0': lambda c: aim_at(c, (L, R))},
    'D1': {'title': 'OFF THE JAW', 'src': 'Davis trick1', 'lay': l_d1, 'need': [B['blk']], 'first': 5},
    'D2': {'title': 'BLACK FROM THE ROW', 'src': 'Davis trick2', 'lay': l_d2, 'need': [B['blk']], 'first': 4, 'spin': 8},
    'D4': {'title': 'BLACK IN THE FLOWER', 'src': 'Davis trik4', 'lay': l_d4, 'need': [B['blk']], 'first': 4, 'spin': 0},   # full into r5, screw: the white back
    'D5': {'title': 'DOUBLE KISSES', 'src': 'Davis trik5', 'lay': l_d5, 'need': [B['pnk']], 'first': 0,
           'aim0': lambda c: aim_at(px(407, 295.5), px(637, 275.5))},   # (the white: the blur's line, from the tip)
    'MGUNF': {'title': 'MACHINE GUN', 'src': 'PDF 10', 'lay': l_mgunf, 'need': [B['r%d' % (k + 1)] for k in range(5)],
              'aim0': lambda c: aim_at(c, (L, R + 0.5)), 'spin': 8},
    'TWOSIDES2': {'title': 'TWO SIDES TWO CORNERS', 'src': 'PDF 1a', 'lay': l_twosides2,
                  'need': [B['r1'], B['r2'], B['r3'], B['r4']], 'aim0': lambda c: 0},
    'JAILED': {'title': 'JAILED BLACK', 'src': 'PDF 4', 'lay': l_jailed, 'need': [B['blk']],
               'aim0': lambda c: aim_at(c, (L / 2, W / 2))},
}


def search(name, params=({},), aims=40, step=8, powers=(0x6000, 0x8000, 0xA000, 0xC000, 0xE000), first=None):
    """every layout of params x a grid of aims around the line to the first ball x powers"""
    tr = TRICKS[name]
    tasks, keys = [], []
    for p in params:
        cue, balls = tr['lay'](p)
        balls = sep(balls)
        fb = tr.get('first', first or 0)
        tgt = (balls[fb][1], balls[fb][2])
        t0 = tr['aim0'](cue) if 'aim0' in tr else aim_at(cue, tgt)
        for k in range(-aims, aims + 1):
            for pw in powers:
                tasks.append((cue, tuple(balls), (t0 + k * step) & 0xFFFF, pw, tr.get('spin', 4), tr.get('side', 4), tuple(tr['need'])))
                keys.append((tuple(sorted(p.items())), pw))
    ts = time.time()
    res = [play(t) for t in tasks]      # (a shot is 0.05 s here: a pool only costs its start)
    runs = {}
    for task, key, r in zip(tasks, keys, res):
        if made(tr, r):
            runs.setdefault(key, []).append(task[2])
    print('%s: %d of %d shots make it (%.0f s)' % (name, sum(len(v) for v in runs.values()), len(tasks), time.time() - ts))
    top = None
    for key, aims_ in runs.items():
        aims_.sort()
        cur = [aims_[0]]
        for x in aims_[1:] + [None]:
            if x is not None and (x - cur[-1]) & 0xFFFF <= step:
                cur.append(x)
                continue
            if top is None or len(cur) > len(top[1]):
                top = (key, cur)
            if x is not None:
                cur = [x]
    if top:
        (p, pw), a_ = top
        print('   best: %s power $%05X, aims %d..%d (%d wide) -> aim %d' % (dict(p), pw, a_[0], a_[-1], len(a_), a_[len(a_) // 2]))
    return top


def guess(name):
    """the trick's aim: as the PDF draws it (aim0) -- else, a trick not tuned yet (Davis's), the
    line to its first ball (search's centre)"""
    tr = TRICKS[name]
    cue, balls = tr['lay']({})
    fb = tr.get('first', 0)
    return tr['aim0'](cue) if 'aim0' in tr else aim_at(cue, (balls[fb][1], balls[fb][2]))


# --- the game's tricks (the menu's TRICK SHOTS, src/trick.asm): the layout, a line
# of description (<= 26: the HUD's blue field), the demo shot the computer plays
# (found by search / grid above: aim 1/64 units, power), the balls that must drop
GAME = [('PLANT3', {}, 'POT THE LAST RED', 6471, 0x6000),
        ('MGUNF', {'sp': 1.1, 'bk': 60, 'back': 100}, 'TOP SPIN, FIVE IN A CORNER', 8, 0xE000),
        ('D2', {}, 'BLACK INTO THE MIDDLE', 32792, 0x13000),    # (a touch harder than the $12000 window's middle: the user's call)
        ('D4', {}, 'BLACK INTO A MIDDLE POCKET', guess('D4'), 0x14000),  # 4 m/s: clean over aims +-1 deg, 3.6-4.4 m/s
        ('D1', {}, 'OFF THE JAW, BLACK IN', guess('D1') - 425, 0x16000),   # the crease of r6 / r7, 2.3 deg thin: the white on to r5; the black
        # drops at -2.5..-2.2 deg, $16000 (_dbg_d1aim.py; the line to r6: the white into the triple r8-r10 instead)
        ('D5', {}, 'KISSES, PINK IN THE MIDDLE', guess('D5') + 40, 0x19000),   # full power: the white under r13 into the pairs'
        # lower balls (kisses), on to the pair under the row, the row; the pink runs the rail to the top middle
        # pocket -- drops at +35..+45 only, $18000 stops 300 mm short (_dbg_d1aim.py .. D5)
        ('TWOSIDES3', {'a4': 43.85, 'u': 905.0}, 'SPLIT THEM, FOUR POCKETS', 0, 0xF800),   # 2026-10-27: the far pair turned and
        # moved so 3 reaches the top corner too (l_twosides3: a4, u; all four drop at aims +-16, $F000..$10000)
        ('EASY8', {'a4': 43.85, 'u': 905.0}, 'EIGHT BALLS, SIX POCKETS', 0, 0x11800),   # (the corners' pair as 1a: 7 was 177 mm short)
        ('LINE4', {'dl_b': 1.5, 'dl_r': 2.5, 'off': 18.0, 'dc': 240.0}, 'FOUR BALLS, FOUR POCKETS', 439, 0x18600),   # 2026-10-27: the
        # corners take a ball within 64 mm of the rail only (physics.asm mouthx): 3 leans 2.5 deg, 2 only 1.5 with the white 8 mm
        # higher and 13 mm nearer; the aim this layout's crease 10 mm low (aim_at / crease(.., 10): 439 -- 12 mm low sent 3 back
        # 65 mm off the rail, it bounced at the left corner) and $18600: 2 reaches the right corner 45 mm off the rail, 3 the left
        # one 40..43 (3 returns along the rail 2 is still rolling on: higher returns of 3 clip 2 -- the chaos at $18000).  All
        # four drop at aims 435..443 and $18400..$18600 (grid, mirrored as the game plays it)
        ('REDSEA', {}, 'THE RED THROUGH THE PAIRS', 16379, 0x12800),  # (straight up 16384: the white 3 mm left of r9's
        # line hits 1 and 9 together; r9 to the top middle pocket, every pair parted, at 16368..16390)
        ('BACKKICK', {}, 'OFF THE JAW, RED TO CORNER', guess('BACKKICK') + 56, 0xF000),   # off the left point into the row (pocket.asm): 24832..24840 at $F000
        # (BUTTERFLY, PDF 6, left out 2026-10-27: in the physics a middle ball that has passed its share to the far
        #  wing can only move square to their line, so it misses the middle pocket, and the near wings get at most
        #  ~12 % of the cue ball's speed -- on this table's cloth 0.8 m of run, the near corners 1.6-2 m away; the real
        #  shot works on a 9 ft pool table with fast cloth.  The layout and its parameters stay in l_butterfly)
        ('CLEARANCE', {'a3': 262.0, 'd4': 15.0, 'y7': 1643.75, 'g7': 10.0, 'g6': 40.0, 'x15': 1766.0, 'y15': 1722.0},
         'A CHAIN ALONG THE RAIL', guess('CLEARANCE'), 0x19000),   # 2026-10-27, laid out as the PDF and tuned in the
        # physics: full power; 4 is 15 mm off the rail (on it, the rail threw it back onto 3 and 3 dived); 3 under 4
        # at 262 deg runs 1 m to the 5 at y 1581 (a gap of 10 under the 7, the 6 40 mm clear) and sends it up-right
        # 2..5 deg: off the end rail it climbs back into the 9 from below-right, the row passes it to the 8, which
        # runs the rail 790 mm and, off the 15 (29 mm under the rail line, just right of the pocket's x), drops
        ('COMBO', {'a2': 84.0, 'a3': 72.5, 'a5': -43.0, 'y1': 1654.0}, 'COMBO, KISS AND KICK', guess('COMBO'), 0x17E00),
        # 2026-10-27, as the PDF: all six drop at contacts 201.5..202.5 deg and $17C00..$18800 in both orientations
        # (the 1 is the tight one: higher it cuts the 4 too thin for the 4's run, lower it stays short of the pocket);
        # $17C00..$18000 the white stays up after the green (at $18200 it toppled in after it, 0.9 m/s nearly full)
        ('FOLLOW', {}, 'YELLOW ROUND THE TABLE', guess('FOLLOW') + 3, 0x18D00),   # 2026-10-27: both drop at $18A00..$19000
        # in both orientations at aims +2..+4 of the drawn line (139.5 / 140.5 deg already miss: the 9 is the tight one,
        # the white wobbles down the rail)
        # (TICKY, PDF 10, left out 2026-10-27: it is played with the cue raised, jumping the white off the
        #  rail-side yellow along the row -- the game has no elevated stroke.  l_ticky stays)
        ]
# (D1 .. MGUN: no shot found yet in the game's physics -- the demo's a first guess, the
#  line to its first ball, till they are tuned)
# (a trick has three balls or more: the one- and two-ball ones -- IN-OFF, DOUBLE, RAILPOT,
#  PLANT, CANNON, CANNONPOT -- left out)


TKREC, TKMAXB = 192, 16   # a trick's record (src/trick.asm's tkb), its balls at most
TH_W = 220                # the help window's text width in pixels (menu.asm: TL_W - 20)


# the menu's description of each trick (the TRICK SHOTS window: what to do), lines of
# <= 22 characters in the menu font's charset (A-Z 0-9 !',-.:), up to 12 lines
HELP = {
    'PLANT3': ['THREE REDS IN A LINE', 'TO THE TOP CORNER.', 'HIT THE FIRST FULL:', 'THE LAST ONE DROPS.', 'PLAIN BALL, MEDIUM.'],
    'MGUNF': ['FIVE REDS ON THE RAIL', 'BY THE CORNER.', 'TOP SPIN, HARD: THE', 'WHITE RUNS THE ROW', 'AND ALL FIVE DROP.'],
    'D2': ['REDS AND THE BLACK', 'IN A ROW ON THE RAIL.', 'HIT THE ROW HARD,', 'MAX TOP: THE BLACK', 'GOES TO THE MIDDLE,', 'THE REDS STAY UP.'],
    'D4': ['THE BLACK IN A FLOWER', 'OF SIX REDS.', 'FULL INTO THE LOWER', 'RIGHT RED, HARD,', 'SCREW: THE BLACK', 'ESCAPES TO THE MIDDLE.'],
    'D1': ['INTO THE TWO REDS:', 'ONE COMES OFF THE', 'JAW INTO THE FOUR', 'BY THE BLACK AND', 'THE BLACK DROPS.'],
    'D5': ['THE PINK TO THE MIDDLE', 'AFTER KISSES ACROSS', 'THE REDS: EVERY BALL', 'MUST MOVE FIRST.'],
    'TWOSIDES3': ['THE WHITE BETWEEN A', 'PAIR: STRAIGHT, FIRM.', 'THE PAIR TO THE SIDE', 'POCKETS, THE FAR PAIR', 'TO THE CORNERS.'],
    'EASY8': ['STRAIGHT BETWEEN THE', 'PAIR, FULL POWER, A', 'TOUCH OF TOP. EIGHT', 'BALLS, SIX POCKETS.'],
    'LINE4': ['FOUR IN A COLUMN AT', 'THE SIDE POCKET. HIT', 'THE CREASE OF 2 AND 3', 'LOW, HARD: FOUR', 'POCKETS, FOUR BALLS.'],
    'REDSEA': ['STRAIGHT UP THE TABLE', 'INTO THE RED: IT RUNS', 'THROUGH THE PAIRS', 'INTO THE FAR MIDDLE.'],
    'BACKKICK': ["OFF THE JAW'S POINT", 'BY THE SIDE POCKET', 'INTO THE ROW ON THE', 'RAIL: THE LAST RED', 'TO THE CORNER.'],
    'BUTTERFLY': ['STRAIGHT BETWEEN THE', 'TWO WINGS: SIX BALLS', 'TO SIX POCKETS.'],
    'CLEARANCE': ['FULL INTO THE YELLOW, LOW, HARD.', 'THE CHAIN RUNS: 3 TO 5, OFF THE', 'END RAIL INTO THE ROW, THE 8', 'ALONG THE RAIL AND OFF THE 15', 'INTO THE MIDDLE POCKET.'],
    'COMBO': ['THE YELLOW FROM BELOW LEFT, TOP', 'AND LEFT SIDE, HARD: A COMBO, A', 'KISS, THE 4 ALONG THE RAIL, AND', 'THE WHITE KICKS THREE RAILS INTO', 'THE FAR GREEN.'],
    'FOLLOW': ['HALF BALL INTO THE YELLOW FROM', 'THE UPPER LEFT, TOP AND RIGHT', 'SIDE, HARD: IT GOES THREE RAILS', 'ROUND INTO THE CORNER, THE WHITE', 'FOLLOWS THE RAIL INTO THE 9.'],
    'TICKY': ['OFF THE YELLOW BY THE', 'RAIL, LOW AND RIGHT:', 'THE WHITE RATTLES', 'ALONG THE ROW TO', 'THE BLACK.'],
}


def emit(path=os.path.join(os.path.dirname(HERE), 'build', 'assets', 'tricks.inc')):
    """tricks.inc (RAM: the count, the records' window addresses) and tricks_v.inc (the records, a VRAM stream to V:TK_BANK000, read at
    $3000 through MEMAC-A): name, description, the cue ball, the balls, the demo"""
    q = lambda v: int(round(v * 4096)) & 0xFFFFFF
    b3 = lambda v: [v & 255, (v >> 8) & 255, v >> 16]
    recs = []
    nb = 0
    for name, p, desc, aim, pw in GAME:
        tr = TRICKS[name]
        title = '%d %s' % (len(recs) + 1, tr['title'])          # numbered: 1, 2, 3 ..
        cue, bl = tr['lay'](p)
        bl = sep(bl)
        cue, bl = (cue[0], W - cue[1]), [(b, x, W - y) for b, x, y in bl]   # the game's y: 0 at the
        aim = -aim & 0xFFFF                                                  #   screen's top -- mirrored
        assert len(desc) <= 26 and len(title) <= 22, (desc, title)
        assert 3 <= len(bl) <= TKMAXB, name        # (no trick with fewer than three balls)
        txt = lambda t, n: [(ord(c) - 32) & 63 for c in t] + [0xFF] * (n - len(t))
        r = txt(title, 23) + txt(desc, 27) + b3(q(cue[0])) + b3(q(cue[1]))
        r += [len(bl), 1 if 'cue' in tr['need'] else 0, aim & 255, (aim >> 8) & 255,
              (pw >> 8) & 255, pw >> 16, tr.get('spin', 4) | (8 - tr.get('side', 4)) << 4]   # the tip: spin + 16 side
        #   (trick.asm); the side mirrored with y (2026-10-27: it was not -- COMBO's kick went the other way in the game)
        for b, x, y in bl:
            r += [b, 1 if b in tr['need'] else 0] + b3(q(x)) + b3(q(y))
        assert len(r) <= TKREC
        recs.append(r + [0] * (TKREC - len(r)))
        nb += len(bl)
    n = len(recs)
    assert n * TKREC <= 4096
    L_ = ['; tricks.inc -- tools/trick_sim.py (do not edit): the trick shots (src/trick.asm)',
          'TK_N = %d' % n, 'TKREC = %d' % TKREC,
          'tk_rl dta ' + ', '.join('<$%04X' % (0x3000 + k * TKREC) for k in range(n)),
          'tk_rh dta ' + ', '.join('>$%04X' % (0x3000 + k * TKREC) for k in range(n))]
    open(path, 'w').write(chr(10).join(L_) + chr(10))
    V = ['; tricks_v.inc -- tools/trick_sim.py (do not edit): the trick records -> V:TK_BANK000',
         '    org vbank', '    dta TK_BANK-1', '    org $3000,$2000']
    for k, r in enumerate(recs):
        V.append('; %d %s' % (k, GAME[k][0]))
        for j in range(0, TKREC, 24):
            V.append('    dta ' + ', '.join('$%02X' % v for v in r[j:j + 24]))
    V += ['    ert *>$4000', '    ini vram_next']
    open(os.path.join(os.path.dirname(path), 'tricks_v.inc'), 'w').write(chr(10).join(V) + chr(10))
    # the texts re-wrapped to the window's width by the font's advances (menugfx.inc
    # mf_a, a glyph's pixels: menu_gfx.py): TH_W = menu.asm's TL_W - 20
    import re
    adv = [int(v) for v in re.search(r'mf_a\s+dta\s+([^\n]+)',
                                     open(os.path.join(os.path.dirname(path), 'menugfx.inc')).read()).group(1).split(',')]
    width = lambda t: sum(adv[ord(c) - 32] for c in t)

    def wrap(lines):
        out, cur = [], ''
        for w in ' '.join(lines).split():
            t = (cur + ' ' + w) if cur else w
            if width(t) <= TH_W:
                cur = t
            else:
                out.append(cur)
                cur = w
        return out + [cur]
    WR = {name: wrap(HELP[name]) for name, par, desc, aim, pw in GAME}
    H = ["; trickhelp.inc -- tools/trick_sim.py (do not edit): the TRICK SHOTS window's texts (menu.asm mhelpd)",
         'th_lo dta ' + ', '.join('<th%d' % k for k in range(len(GAME))),
         'th_hi dta ' + ', '.join('>th%d' % k for k in range(len(GAME))),
         'th_n  dta ' + ', '.join('%d' % len(WR[name]) for name, par, desc, aim, pw in GAME)]
    for k, (name, par, desc, aim, pw) in enumerate(GAME):
        lines = WR[name]
        assert 1 <= len(lines) <= 12 and all(width(t) <= TH_W and set(t) <= set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!',-.: ") for t in lines), name
        H.append('th%d' % k)
        H += ['    dta d%s, $FF' % ('"%s"' % t if "'" in t else "'%s'" % t) for t in lines]
    open(os.path.join(os.path.dirname(path), 'trickhelp.inc'), 'w').write(chr(10).join(H) + chr(10))
    print('->', os.path.relpath(path, os.path.dirname(HERE)), '+ tricks_v.inc (%d tricks, %d balls)' % (n, nb))


if __name__ == '__main__' and len(sys.argv) == 1:
    emit()


if __name__ == '__main__':
    if len(sys.argv) > 2 and sys.argv[1] == 'search':
        search(sys.argv[2])
    elif len(sys.argv) > 2 and sys.argv[1] == 'grid':
        import itertools, json
        spec = json.loads(sys.argv[3])                 # {"param": [values]} -> every combination
        ks = list(spec)
        search(sys.argv[2], [dict(zip(ks, v)) for v in itertools.product(*[spec[k] for k in ks])],
               aims=int(sys.argv[4]) if len(sys.argv) > 4 else 12, step=int(sys.argv[5]) if len(sys.argv) > 5 else 4)
