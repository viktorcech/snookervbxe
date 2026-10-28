"""rot_ref.py -- the INTEGER spec of the real-time table (6502 + VBXE): the
table drawn about the CUE BALL (the pivot) at any angle and zoom.

Byte-exact model of what table3d.asm does, the way tools/phys_ref.py is for
the physics: the asm image must equal render(angle, pivot, zoom) pixel for
pixel (tools/_dbg_rotchk.py).

Camera fixed: EYE_D behind the pivot, PITCH down, the pivot (the cue ball)
at screen (160, PIVOT_ROW).  The table turns about the pivot, so it runs past
the screen and a point's row and x-scale depend only on its rotated depth
x'' and height z: per z level (bed 0, cushion top H, ball centre R) two
depth LUTs at 32 mm steps (row Q4, x-scale), linearly interpolated, one set
per zoom level (the zoom is a lens about the pivot's screen point).

Per frame (asm order):
  1. c, s (Q14) from the 1024-step cos LUT; the pivot's offset
     B' = R(piv - C) (Q3, rot_rel: mul16u + r14); the eye in table coords
     E = (piv - C) + R(-a)(EX, 0), halved term by term (Q2).
  2. rotation points about the table centre (precomputed per even angle in
     VRAM, Q3) -> x'' = x'_C - B'x, y'' = y'_C - B'y (24-bit); T = x'' + OFF.
  3. projection points: T in [0, TF[level]) -> stored row (screen row + 8,
     8 bits), sx (Q4 signed 16), depth index; else invalid.
  4. the draw list in painter order: vertical faces culled by a dot product
     with the eye; polygons clipped in TABLE space against the near plane
     (T = 0: the cushion top at row 240.5, everything nearer is below the
     screen) and the far plane of their level (that level at row -0.5), then
     in SCREEN space against x = 0 and x = 320 (exact: edges are straight on
     screen); filled as row spans (stored rows 0..7 and 248..255 are junk
     rows beyond the buffer).  Discs and balls are rectangle-clipped; the
     baulk line is clipped as a segment.

  python tools/rot_ref.py                  stats, every zoom
  python tools/rot_ref.py --png            tools/out/rotref_*.png (the model)
  python tools/rot_ref.py --cmp            tools/out/_pockets_cmp.png (the pockets from above beside the PDF's)
"""
import math
import os
import sys
sys.dont_write_bytecode = True  # no __pycache__ (the user's rule)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import snooker_core as C          # noqa: E402
import vbxe_export as V           # noqa: E402

ANG = 1024
H = 42.0
STEP = 32.0                        # mm per depth-LUT entry
CX, CY = C.TABLE_L / 2.0, C.TABLE_W / 2.0
CXQ, CYQ = int(round(CX * 4096)), int(round(CY * 4096))     # Q12 table centre
EYE_D = 3334.5                     # the eye: this far behind the pivot ...
PITCH = math.radians(42.0)         # ... looking down at it this steeply
PIVOT_ROW = 152.0                  # the pivot's screen row
K1 = 0.070                         # lateral scale at the pivot, px/mm, zoom 1
# a level: a zoom factor, or (zoom, pitch deg, eye distance mm, pivot row);
# the cameras (key C): behind the cue, low over the cue, the player's eye
# down the cue (250 mm behind the white, 250 mm over the bed), from above
LOW = (2.0, 20.0, 2600.0, 190.0)
EYE = (8.0, 45.0, 250.0, 220.0)
TOP = (1.08, 88.0, 150.0, 124.0)
ZOOMS = (1.0, LOW, EYE, TOP)
ZOOM_DEFAULT = 0
ZOOM_LOW = 1
ZOOM_EYE = 2
ZOOM_TOP = 3
EX = int(round(-EYE_D * 8))        # the eye in the rotated frame, Q3
SXC = 160 * 16                     # the pivot's screen x, Q4
ROW_BIAS = 8                       # stored row = screen row + 8
SCR_W, SCR_H = 320, 240
REACH = 4246.0                     # the farthest table point from any cue position (rails incl.)
BALL_SIZES = (2, 3, 4, 5, 6, 7, 8, 10, 12, 15)   # the ball sprites' radii (px; VRAM)
DISC_MAX = 28                      # a disc sprite's largest radius (px)
COL = V.IDX


# ---------------------------------------------------------------------------
# camera + LUTs
# ---------------------------------------------------------------------------
def camera(zoom=1.0, pitch=PITCH, eye_d=EYE_D, pivot_row=PIVOT_ROW):
    """the pinhole: eye at (CX - eye_d, CY, eye_d tan pitch) looking at the
    pivot (CX, CY, 0); proj(x, y, z) -> (sx, sy, depth) with the pivot at
    (160, pivot_row) and K1 * zoom px/mm across at the pivot's depth."""
    th = pitch
    eye = (CX - eye_d, CY, eye_d * math.tan(th))
    f = (math.cos(th), 0.0, -math.sin(th))
    u = (math.sin(th), 0.0, math.cos(th))
    r = (0.0, 1.0, 0.0)
    cz_piv = eye_d / math.cos(th)
    s = K1 * zoom * cz_piv

    def proj(x, y, z):
        dx, dy, dz = x - eye[0], y - eye[1], z - eye[2]
        cx = dx * r[0] + dy * r[1] + dz * r[2]
        cy = dx * u[0] + dy * u[1] + dz * u[2]
        cz = dx * f[0] + dy * f[1] + dz * f[2]
        cz = max(cz, 1.0)
        return (160.0 + s * (cx / cz), pivot_row - s * (cy / cz), cz)
    proj.scale = s
    proj.H = H
    proj.eye = eye
    return proj


class Zoom:
    """one zoom level: the depth LUTs (rows carry the +8 bias in Q4), the
    near plane (LUT entry 0) and the far planes."""

    def __init__(self, level):
        if isinstance(level, tuple):
            zoom, pitch, eye_d, pivot_row = level
            proj = camera(zoom, math.radians(pitch), eye_d, pivot_row)
        else:
            zoom, eye_d = level, EYE_D
            proj = camera(zoom)
        self.zoom = zoom
        self.EX = int(round(-eye_d * 8))        # the eye in the rotated frame, Q3
        # a sloped face (SLANT out over H up from its foot) faces the eye iff
        # n.(E - P) + SLANT / H * Ez > 0: in the cull's units (a Q6, the eye Q2) + KS
        self.KS = int(round(256 * SLANT / H * proj.eye[2]))
        self.proj = proj

        def solve(z, target, lo=-6000.0, hi=20000.0):
            # row decreases with x: find x with row(x, z) = target
            for _ in range(80):
                mid = (lo + hi) / 2
                if proj(mid, CY, z)[1] > target:
                    lo = mid
                else:
                    hi = mid
            return (lo + hi) / 2
        xn = min(solve(H, SCR_H + 0.5), solve(0.0, SCR_H + 0.5))   # both planes at row >= 240.5
        if proj(xn, CY, 0.0)[1] >= SCR_H + ROW_BIAS - 0.5:
            # a camera close over the bed: there the bed falls past the stored
            # byte; the near plane where the bed leaves row 247 (the cushion
            # tops end a few rows above the screen's foot)
            xn = solve(0.0, SCR_H + ROW_BIAS - 0.6)
        self.XMIN = xn
        self.OFF = int(round((CX - xn) * 8))    # T = x''(Q3) + OFF
        reach_t = int((REACH + (CX - xn)) * 8)  # T of the farthest table point
        assert reach_t < 65536, reach_t
        tf = []
        for z in (0.0, H):
            t = int((solve(z, -0.5) - xn) * 8)
            tf.append(min(t, reach_t))
        self.TF0, self.TFH = tf
        self.NLUT = (max(tf) >> 8) + 2
        assert self.NLUT <= 256, self.NLUT
        L = {}
        for zl, z in ((0, 0.0), (1, H), (2, C.BALL_R)):
            row, k = [], []
            for i in range(self.NLUT):
                x = xn + STEP * i
                sx0, sy, _ = proj(x, CY, z)
                sx1, _, _ = proj(x, CY + 256.0, z)
                row.append(int(round(sy * 16)) + ROW_BIAS * 16)
                k.append(int(round((sx1 - sx0) / 256.0 * 2 * 32768)))
            dr = [row[i] - row[i + 1] for i in range(self.NLUT - 1)] + [0]
            dk = [k[i] - k[i + 1] for i in range(self.NLUT - 1)] + [0]
            assert all(0 <= d < 256 for d in dr), ('DR', zoom, zl, min(dr), max(dr))
            assert all(0 <= d < 65536 for d in dk), ('DK', zoom, zl, min(dk), max(dk))
            assert max(k) < 65536 and min(row) >= 0 and max(row) < 4096, (zoom, zl, max(k), min(row), max(row))
            L[zl] = (row, dr, k, dk)
        self.L = L
        # NH: the entries whose DK passes 8 bits (its high byte at $C0 + i of
        # the DK page: NLUT stays below $C0) -- only near a close camera
        self.NH = max([i + 1 for zl in L for i, d in enumerate(L[zl][3]) if d > 255] + [0])
        assert self.NH <= 64 and self.NLUT <= 0xC0, (self.NH, self.NLUT)
        # BS: the ball sprite's radius per depth entry -- the ball's true
        # radius there (BALL_R at the ball-centre level's x-scale), the
        # nearest of BALL_SIZES (a tie: the larger)
        self.BS = [min(BALL_SIZES, key=lambda s: (abs(s - C.BALL_R * kv / 65536.0), -s))
                   for kv in L[2][2]]
        # the cast's keyrows: stored row CAST_KR k (its centre) on the bed's
        # plane -> T (= x'' Q3 + OFF) and G (y'' per pixel, Q3 x 128 = Q10)
        self.KT, self.KG = [], []
        for k in range(CAST_NK):
            target = CAST_KR * k - ROW_BIAS + 0.5
            x = solve(0.0, target, -20000.0, 60000.0)
            sx0, _, _ = proj(x, CY, 0.0)
            sx1, _, _ = proj(x, CY + 256.0, 0.0)
            mm_px = 256.0 / max(sx1 - sx0, 1e-6)
            self.KT.append(min(65535, max(0, int(round((x - xn) * 8)))))
            self.KG.append(min(65535, int(round(mm_px * 1024))))
        for zl in (0, 1):                       # the planes' rows fit the stored byte
            r0 = L[zl][0][0] >> 4
            assert (240 + ROW_BIAS <= r0 or zl == 1 and self.NH) and r0 <= 255, ('near row', zoom, zl, r0)

    def project(self, T, y, zl):
        """(T, y'' Q3 signed, level) -> (sx Q4 signed, stored row, depth index)."""
        i, f = T >> 8, T & 255
        row, dr, k, dk = self.L[zl]
        rowq = row[i] - ((dr[i] * f) >> 8)
        kv = k[i] - ((dk[i] * f) >> 8)
        ay = abs(y)
        assert ay < 65536
        m = mulh(ay, kv) >> 15                  # < 2^17: sx is 24-bit (rpxx)
        sx = SXC + (m if y >= 0 else -m)
        assert 0 <= rowq < 4096, (sx, rowq)
        return sx, rowq >> 4, i

    def valid(self, T, zl):
        return 0 <= T < (self.TF0 if zl == 0 else self.TFH)


# ---------------------------------------------------------------------------
# asm arithmetic
# ---------------------------------------------------------------------------
def mulh(a, b):
    """mul16h: a * b (16-bit magnitudes) without the low partial aL*bL."""
    ah, al, bh, bl = a >> 8, a & 255, b >> 8, b & 255
    return (ah * bh << 16) + ((ah * bl + al * bh) << 8)


def smulh(a, b):
    """signed: the product of the magnitudes, then the sign."""
    p = mulh(abs(a), abs(b))
    return -p if (a < 0) != (b < 0) else p


def mulr14h(a, b):
    """round(a*b / 2^14) sign-magnitude on the 3-partial product."""
    p = (mulh(abs(a), abs(b)) + 8192) >> 14
    return -p if (a < 0) != (b < 0) else p


def mulr14(a, b):
    """round(a*b / 2^14) sign-magnitude on the exact product (mul16u + r14)."""
    p = (abs(a) * abs(b) + 8192) >> 14
    return -p if (a < 0) != (b < 0) else p


def div16r(num, den):
    """div16r: round(num * 65536 / den), ties up; 0 <= num <= den < 65536."""
    assert 0 <= num <= den and 0 < den < 65536, (num, den)
    return (2 * (num << 16) + den) // (2 * den)


def lerp_q16(a, b, q):
    """a + (b - a) * q >> 16 as the asm: |b - a| * q (mul16u, exact), the
    high word, then the sign.  q = 65536 (b on the plane) gives b."""
    d = b - a
    assert abs(d) < 65536
    p = (abs(d) * q) >> 16
    return a + (p if d >= 0 else -p)


def ball_rot(c, s, du, dv):
    """a ball centre (du, dv: Q3 about the pivot, |.| < 2^15) turned by (c, s)
    Q14, four products (a sum of coordinates could pass 2^15 about the cue):
    P1 = c du, P2 = s dv, P3 = s du, P4 = c dv, each kept as floor(P / 256)
    (the asm stores bytes 1..3 of the signed product);
    x' = (P1 - P2 + 32) >> 6, y' = (P3 + P4 + 32) >> 6."""
    p1 = smulh(c, du) >> 8
    p2 = smulh(s, dv) >> 8
    p3 = smulh(s, du) >> 8
    p4 = smulh(c, dv) >> 8
    return (p1 - p2 + 32) >> 6, (p3 + p4 + 32) >> 6


def rcp7(rows):
    """131072 / rows, rounded (rows >= 3: fits 16 bits); m = dx_q7 * rcp7 >> 16
    is the Q8 step per row."""
    return (131072 + rows // 2) // rows


def edge(a, b):
    """(x0,r0)->(x1,r1): x Q7, the vertices on their rows; rows [r0, r1),
    x Q8 starting at x0 (+0.5 bias), step m Q8 = dx * RCP[rows] >> 16
    (a 1-row edge never steps: m = 0)."""
    (x0, r0), (x1, r1) = a, b
    if r1 <= r0:
        return None
    rows = r1 - r0
    dx = x1 - x0
    m = 0 if rows == 1 else abs(dx) if rows == 2 else (abs(dx) * rcp7(rows)) >> 16
    if dx < 0:
        m = -m
    return r0, r1, (x0 << 1) + 128, m


def disc_size(L, zl, i, r):
    """(rx, ry) in pixels of a horizontal circle of radius r mm at LUT depth
    i: rx from the x-scale (K = px/mm * 2^16), ry from the row slope (DR =
    rows Q4 per 32 mm)."""
    row, dr, kk, dk = L[zl]
    rx = r * kk[i] / 65536.0
    ry = r * dr[i] / 16.0 / STEP
    big = max(rx, ry)
    if big > DISC_MAX:                  # a close camera: capped, the shape kept (VRAM)
        rx, ry = rx * DISC_MAX / big, ry * DISC_MAX / big
    return max(1, int(round(rx))), max(1, int(round(ry)))


POCKET_NET = True     # the white net hanging in the hole (disc_color)


def disc_color(col, rx, ry, dx, dy):
    """the colour of a disc sprite's pixel (dx, dy) from its centre.  A pocket
    opening big enough (rx >= 4) shows its white net hanging in the hole: a
    diagonal mesh over the black in the LOWER half only -- the upper half is
    the dark far wall of the pocket, seen from above -- inside the dark rim."""
    if col != COL['pocket'] or rx < 4 or dy < 0 or not POCKET_NET:
        return col
    e = (dx / (rx + 0.5)) ** 2 + (dy / (ry + 0.5)) ** 2
    if e < 0.10 or e > 0.62:
        return col
    return COL['net'] if (dx + dy) % 3 == 0 or (dx - dy) % 3 == 0 else col


def disc_mask(rx, ry):
    """rows of the ellipse sprite: (dy, half-width), dy = -ry..ry."""
    out = []
    for yy in range(-ry, ry + 1):
        t = 1 - (yy / (ry + 0.5)) ** 2
        if t > 0:
            out.append((yy, int(rx * math.sqrt(t) + 0.5)))
    return out


def disc_sprite(L, zl, i, r, col):
    """the sprite of a disc at depth index i: (img, rx, ry), colour 0 clear."""
    rx, ry = disc_size(L, zl, i, r)
    w, h = 2 * rx + 1, 2 * ry + 1
    img = bytearray(w * h)
    for (yy, ww) in disc_mask(rx, ry):
        for x in range(rx - ww, rx + ww + 1):
            img[(yy + ry) * w + x] = disc_color(col, rx, ry, x - rx, yy)
    return img, rx, ry


# ---------------------------------------------------------------------------
# scene
# ---------------------------------------------------------------------------
class Scene:
    """rotation points (Q3 about the centre), projection points (rp, zl),
    polygons [(pp list, colour, cull)], discs, marks, layer order."""

    def __init__(self):
        self.rp = []            # (u, v) Q3
        self.rpi = {}
        self.pp = []            # (rp index, zl)
        self.ppi = {}
        self.items = []         # dicts, in layer order

    def P(self, x, y, zl):
        u, v = int(round((x - CX) * 8)), int(round((y - CY) * 8))
        if (u, v) not in self.rpi:
            self.rpi[(u, v)] = len(self.rp)
            self.rp.append((u, v))
        k = (self.rpi[(u, v)], zl)
        if k not in self.ppi:
            self.ppi[k] = len(self.pp)
            self.pp.append(k)
        return self.ppi[k]

    def poly(self, pts, col, cull=None, outl=None):
        """pts: [(x, y, zl)] mm; cull: (a, b, d) -- the face is visible iff
        a*Eu + b*Ev > d (eye in the table frame, Q3; a, b the normal, Q6).
        outl: the top view's outlined edges (indices; None: all) -- the PDF's black lines"""
        self.items.append({'kind': 'poly', 'pp': [self.P(*p) for p in pts], 'col': COL[col],
                           'cull': cull, 'outl': outl})

    def disc(self, x, y, zl, r, col):
        self.items.append({'kind': 'disc', 'pp': [self.P(x, y, zl)], 'r': r, 'col': COL[col],
                           'zl': zl})

    def line(self, a, b, col):
        self.items.append({'kind': 'line', 'pp': [self.P(*a), self.P(*b)], 'col': COL[col]})

    def spot(self, x, y, col):
        self.items.append({'kind': 'spot', 'pp': [self.P(x, y, 0)], 'col': COL[col]})

    def group_last(self, grp):
        """the rotation points only grp's items use -> the last ones (rot_project
        leaves them out while the group is skipped); returns their count"""
        mine = {self.pp[k][0] for it in self.items if it.get('grp') == grp for k in it['pp']}
        other = {self.pp[k][0] for it in self.items if it.get('grp') != grp for k in it['pp']}
        own = sorted(mine - other)
        order = [k for k in range(len(self.rp)) if k not in own] + own
        new = {old: n for n, old in enumerate(order)}
        self.rp = [self.rp[k] for k in order]
        self.rpi = {uv: n for n, uv in enumerate(self.rp)}
        self.pp = [(new[k], zl) for (k, zl) in self.pp]
        self.ppi = {(k, zl): n for n, (k, zl) in enumerate(self.pp)}
        return len(own)

    def mirror_first(self, nd):
        '''the points symmetric about the table's centre, (u, v) <-> (-u, -v), the last nd
        (the D's) kept last: one of each pair FIRST, the partners right after in the same
        order, then the unpaired.  rot_load stores only the partners, the unpaired and the
        D in VRAM and makes the first ones by negation (2026-10-27); returns the pairs' count'''
        n = len(self.rp) - nd
        m, a, seen = [], [], set()
        for k in range(n):
            if k in seen:
                continue
            u, v = self.rp[k]
            j = self.rpi.get((-u, -v))
            if j is not None and j != k and j < n and j not in seen:
                m.append(k); a.append(j); seen.add(k); seen.add(j)
        rest = [k for k in range(n) if k not in seen]
        order = m + a + rest + list(range(n, len(self.rp)))
        new = {old: i for i, old in enumerate(order)}
        self.rp = [self.rp[k] for k in order]
        self.rpi = {uv: i for i, uv in enumerate(self.rp)}
        self.pp = [(new[k], zl) for (k, zl) in self.pp]
        self.ppi = {(k, zl): i for i, (k, zl) in enumerate(self.pp)}
        return len(m)


SLANT = 68.0     # mm: the cushion's wedge, nose on the cloth to its back at the rail (POCKET_D):
                 # (docs: the nose 7R/5 high, the contact above the ball's equator; the anatomy pictures)


def _vface(a, b, zl_lo, zl_hi, col, scene, ref, toward=True, top=None, tri=False):
    """vertical face over the segment a-b (mm), z from level zl_lo to zl_hi;
    its normal points toward (or away from) the point ref.  Culling: the eye
    must be on the normal side -- a*Eu + b*Ev > d with the normal (a, b) in
    Q6 and d = a*u + b*v of a point of the plane (all exact integers)."""
    (ax, ay), (bx, by) = a, b
    nx, ny = by - ay, -(bx - ax)
    if (nx * (ref[0] - ax) + ny * (ref[1] - ay) > 0) != toward:
        nx, ny = -nx, -ny
    ln = math.hypot(nx, ny)
    na, nb = int(round(nx / ln * 64)), int(round(ny / ln * 64))
    u0, v0 = int(round((ax - CX) * 8)), int(round((ay - CY) * 8))
    (atx, aty), (btx, bty) = top if top else (a, b)       # (a sloped face: its top edge elsewhere)
    pts = [(ax, ay, zl_lo), (bx, by, zl_lo), (btx, bty, zl_hi), (atx, aty, zl_hi)]
    scene.poly(pts[:3] if tri else pts, col, cull=(na, nb, na * u0 + nb * v0))   # (tri: a wedge's end)



# snooker pocket geometry (mm).  Cushion depth D; the corner jaws are cut at
# 45 degrees (the two jaw faces run parallel to the diagonal: a throat of
# CM/sqrt2*2 = 89 mm mouth, 63 mm across); the middle jaws open outward by
# MID_ANG.  The black opening sits in the rail right behind the throat, the
# leather pocket top round it.
POCKET_D, RAIL_W = 68.0, 150.0
# corner jaws after the WPBSA 2005/6 layout (as drawn by flashsnooker.com, aa.png): the
# straight nose ends 6.15" from the slate edge = 108 mm from the corner of the bed, then the
# jaw curves back (r 3") to meet the slate edge 90 mm from the corner -- cut here as a line
# from the nose to the cushion base (82.5 mm at the full depth D); the drop is 84 mm wide
# (2026-10-22, cus.jpg: a corner pocket under its template) the jaws close to a throat of
# parallel walls, TW = 89 mm across, running out along the diagonal; the tips 127 mm apart
# (CN = 127 / sqrt 2); a jaw face runs from its tip to the wall at the cushion's back
TW = 89.0
CN = 90.0
CB = CBD = TW / 2 / math.sqrt(2)  # the jaw's base: on the drop's rim (the wall's touch), not the cushion's back
CM, MH = 90.0, 56.0          # where the jaws meet the slate (physics); middle L/2 +- 56 mm
KN = 8.0                     # middle: the rounded nose, its tip cut back along the rail
MID_ANG = math.radians(15.0)
HOLE_C, HOLE_CR, LEATH_C = 0.0, 44.0, 18.0         # corner: the drop + net in the throat (its walls 44.5 off), the leather U round it (cus.jpg)
HOLE_M, HOLE_MR, LEATH_M = 20.0, 50.0, 16.0        # middle: the drop + net, centre (L/2, -20)
# the middle pocket after bw5.jpg (cushion 68 mm wide = 160 px there): the rail cut
# square, a gap 2 XW wide; the cushions rounded r RM from the nose down to the gap's
# wall; the hole (net) in the gap at the rail line, the leather U round its far side
XW, RM = 54.0, 60.0
# the corner the same way: the throat's walls along the diagonal TW apart (x - y = TWH from the
# corner), the noses rounded r RC into them (so they end SC from the corner, as the physics'
# jaws), the rail cut between the walls, the leather U LC further out along the diagonal
TWH = 89.0 / 2 * math.sqrt(2)
RC = 60.0
SC = TWH + RC * (math.sqrt(2) - 1)
LC = 52.0
LEATH_MY = 114.0                 # the U's centre behind the nose (bw5: its bottom 167 mm out, r XW)
LEATH_MW = 18.0                  # its leather's width
if True:
    HOLE_M, HOLE_MR, LEATH_M = 62.0, 46.0, 8.0
    HOLE_C = 20.0                # the corner's hole back from the bed's corner: behind the mouth
# 2026-10-27, the pockets as the trick-shot PDF draws them (tools/out/_pdf_p5_1.jpg, --cmp): the rail
# is whole wood (no cut through it), the hole a big round opening right behind the mouth with a
# thin liner, the noses rounded into short jaws, the middle jaws opening outward, a darker cap
# of wood round each corner's hole
if True:                         # the pockets as _pdf_p4_1.jpg draws them, by its ball (r 16.5 px there = our
    # 26.25 mm; tools/rot_ref.py --cmp lays the model over it, half see-through): the cushions' tops 37 wide;
    # at a corner each ends in a 45-degree cut from its tip CN from the bed's corner to its back CN - 37 at the
    # rail; the cloth runs on past the nose lines into the throat, up to the cap; the opening, r 60 centred
    # (-19, -19) from the bed's corner, is drawn over everything and bites the cap's inner corner; the cap a
    # darker square of rail CAPL along each rail, its outer corner rounded r CAPR.  A middle: the cuts lean in
    # (MT at the cloth, MB at the rail), the opening r 57 centred 57 behind the nose line touches it.  Black
    # outlines OUTL wide round every piece (the top view)
    HOLE_C, HOLE_CR, LEATH_C = 24.0, 52.0, 0.0     # (the corner's opening: the round hole r 52 centred (-24, -24)
    HOLE_M, HOLE_MR, LEATH_M = 52.0, 58.0, 0.0     #   AND the triangle between the chord and the cap's inner
    CUSH_D = 37.0                                  #   corner, all black, under the throat's cloth that ends at
    RAILW_PDF = 114.0                              #   the chord -- the PDF's shape, circles fitted by least squares
    CN = 84.0                                      #   on its pixels (sd 0.7 px); the middle's a whole circle, 6 mm
    CB = 41.0                                      #   over the nose line); the rail 114 wide past the cushion; the
                                                   #   corner cut from the tip CN to the back CB at the rail
    MT, MB = 65.0, 59.0
    CAPL, CAPR = 116.0, 160.0
    OUTL = 6.0


def cushions():
    """the 6 cushion segments with their jaw cuts: (nose a, nose b, base b,
    base a, jaw ref a, jaw ref b) -- ref = the point the jaw face looks at.
    The nose tips are cut back KN along the rail (the rounded knuckle of a
    real jaw); the bases stay, so the throat keeps its width."""
    L, W, D = C.TABLE_L, C.TABLE_W, (CUSH_D if ROUND_JAWS else POCKET_D)
    t = D * math.tan(MID_ANG)
    m = MH + KN
    out = []
    for (y, o) in ((0.0, -1.0), (W, 1.0)):            # long sides, two segments
        mb = MB if ROUND_JAWS else MH + t            # the middle end's back (the jaw opens outward to it)
        ca, cd = (CB, D) if ROUND_JAWS else (CB, CBD)   # the corner end's back
        mt = MT if ROUND_JAWS else m
        out.append(((CN, y), (L / 2 - mt, y), (L / 2 - mb, y + o * D), (ca, y + o * cd),
                    (0.0, y), (L / 2, y)))
        out.append(((L / 2 + mt, y), (L - CN, y), (L - ca, y + o * cd), (L / 2 + mb, y + o * D),
                    (L / 2, y), (L, y)))
    for (x, o) in ((0.0, -1.0), (L, 1.0)):            # short sides
        ca, cd = (CB, D) if ROUND_JAWS else (CB, CBD)
        out.append(((x, CN), (x, W - CN), (x + o * cd, W - ca), (x + o * cd, ca),
                    (x, 0.0), (x, W)))
    return out


D_SEG = 10                       # the D's chords (18 degrees: at most 3.6 mm off the arc)


def scene_real():
    """the table with REAL snooker pockets, fixed layer order: rail sides,
    rail top, the leather pocket tops, bed + markings, the cloth fall in each
    pocket throat, the black openings, the visible cushion noses and jaw
    faces, the cushion tops (trapezoids) over everything."""
    s = Scene()
    L, W = C.TABLE_L, C.TABLE_W
    D, O = (CUSH_D, CUSH_D + RAILW_PDF) if ROUND_JAWS else (POCKET_D, POCKET_D + RAIL_W)
    for (a, b) in (((-O, -O), (L + O, -O)), ((L + O, W + O), (-O, W + O)),
                   ((-O, W + O), (-O, -O)), ((L + O, -O), (L + O, W + O))):
        _vface(a, b, 0, 1, 'railside', s, (CX, CY), toward=False)
    s.poly([(-O, -O, 1), (L + O, -O, 1), (L + O, W + O, 1), (-O, W + O, 1)], 'rail')
    # the cloth runs over the bed AND the cushions to the rail: green under them, to
    # their backs -- no edge's rounding can show the rail's wood any more
    s.poly([(-D, -D, 1), (L + D, -D, 1), (L + D, W + D, 1), (-D, W + D, 1)], 'cushion')
    if ROUND_JAWS:                       # the corner caps: a darker L of wood round the hole, outside the cushions
        for (cx, cy, sx, sy) in ((0, 0, -1, -1), (L, 0, 1, -1), (0, W, -1, 1), (L, W, 1, 1)):
            g = lambda x, y, z: (cx - sx * x, cy - sy * y, z)
            s.poly([g(-O, -O, 1), g(CAPL, -O, 1), g(CAPL, -D, 1), g(-O, -D, 1)], 'railside', outl=[1])   # (one piece:
            s.poly([g(-O, -D, 1), g(-D, -D, 1), g(-D, CAPL, 1), g(-O, CAPL, 1)], 'railside', outl=[2])   #  lines at its ends only)
            arc = [(-O + CAPR * (1 - math.cos(math.radians(a))), -O + CAPR * (1 - math.sin(math.radians(a))))
                   for a in range(0, 91, 15)]                      # the rail's outer corner rounded: cut away
            for k in (0, 2, 4):                                    #   in 6 chords (1 mm off the arc), 3 fans
                s.poly([g(-O, -O, 1)] + [g(x, y, 1) for x, y in arc[k:k + 3]], 'backdrop')
    for (x, y, r, rim) in POCKETS:       # the liners round the holes
        if rim:
            s.disc(x, y, 1, r + rim, 'leather')
    for (cx, cy, sx, sy) in ((0, 0, -1, -1), (L, 0, 1, -1), (0, W, -1, 1), (L, W, 1, 1)):
        # the throat between the jaws: the cloth falling into the hole (the fall),
        # from the jaw tips on the bed to the cushions' backs at the rail (the wedges'
        # own top points), the hole in the rail at its end: one opening in the table
        # (the bed drawn next keeps the slate green up to its own corner)
        if ROUND_JAWS:
            g = lambda x, y, z: (cx - sx * x, cy - sy * y, z)       # the corner's frame: the bed in +x, +y
            s.poly([g(CB, -D, 1), g(-D, -D, 1), g(-D, CB, 1)], 'pocket', outl=[])   # the opening: the throat's
            hx, hy, _ = g(-HOLE_C, -HOLE_C, 1)                                  #   square part to the cap's corner
            s.disc(hx, hy, 1, HOLE_CR, 'pocket')                               #   and the round hole, under the cloth
            continue                                                           #   (the throat's cloth: after the bed's)
        s.poly([(cx - sx * CN, cy, 0), (cx, cy - sy * CN, 0), (cx + sx * CBD, cy - sy * CB, 1),
                (cx - sx * CB, cy + sy * CBD, 1)], 'fall')
    if ROUND_JAWS:                       # the cloth's corners cut along the chords (x + y = CB - D from each
        c = CB - D                       #   corner), where the throats' cloth takes over: nothing pokes into the D
        s.poly([(c, 0, 0), (L - c, 0, 0), (L - c, W, 0), (c, W, 0)], 'baize', outl=[])
        s.poly([(0, c, 0), (c, 0, 0), (c, W, 0), (0, W - c, 0)], 'baize', outl=[])
        s.poly([(L - c, 0, 0), (L, c, 0), (L, W - c, 0), (L - c, W, 0)], 'baize', outl=[])
        for (cx, cy, sx, sy) in ((0, 0, -1, -1), (L, 0, 1, -1), (0, W, -1, 1), (L, W, 1, 1)):
            g = lambda x, y, z: (cx - sx * x, cy - sy * y, z)       # the throats: the cloth past the nose lines to
            s.poly([g(CN, 0, 0), g(CB, -D, 1), g(-D, CB, 1), g(0, CN, 0)], 'baize', outl=[1])   # the chord between
    else:                                #   the cuts' ends (it cuts the opening to a D; its outline last, whole)
        s.poly([(0, 0, 0), (L, 0, 0), (L, W, 0), (0, W, 0)], 'baize', outl=[])   # (the nose lines: the cushions' edges)
    s.line((C.BAULK_X, 0, 0), (C.BAULK_X, W, 0), 'line')
    d = [(C.BAULK_X - C.D_R * math.sin(math.pi * i / D_SEG), W / 2 - C.D_R * math.cos(math.pi * i / D_SEG), 0)
         for i in range(D_SEG + 1)] if D_SEG else []
    for i in range(D_SEG):               # the D: D_SEG chords, its ends the green and yellow spots
        s.line(d[i], d[i + 1], 'line')
        s.items[-1]['grp'] = 'D'
    for (x, y) in C.SPOTS.values():
        s.spot(x, y, 'spot')
    cu = cushions()
    t = D * math.tan(MID_ANG)
    for (cy, sy) in ((0, -1), (W, 1)):
        if ROUND_JAWS:                   # the middle: the throat from the tips down to the backs
            s.poly([(L / 2 - MT, cy, 0), (L / 2 + MT, cy, 0), (L / 2 + MB, cy + sy * D, 1),
                    (L / 2 - MB, cy + sy * D, 1)], 'baize', outl=[2])   # (the throat: the cloth to the rail)
            continue
        s.poly([(L / 2 - MH - KN, cy, 0), (L / 2 + MH + KN, cy, 0), (L / 2 + MH + t, cy + sy * D, 1),
                (L / 2 - MH - t, cy + sy * D, 1)], 'fall')       # (the middle's throat, the same way)
    for (x, y, r, rim) in POCKETS:       # the holes in the rail, inside the leather: the throats run into them
        if not ROUND_JAWS:
            s.disc(x, y, 1, r, 'pocket')
    for (na, nb, bb, ba, ra, rb) in cu:  # the cushion: a wedge, its nose on the cloth, its back at the rail
        if not ROUND_JAWS:
            _vface(na, nb, 0, 1, 'cushion', s, (CX, CY), top=(ba, bb))
            s.items[-1]['slant'] = True          # (its cull: the eye's height too, Zoom.KS)
            _vface(na, ba, 0, 1, 'cushion', s, ra, tri=True)    # its ends along the jaws: triangles
            _vface(nb, bb, 0, 1, 'cushion', s, rb, tri=True)
            continue
        arcs = [_jaw_arc(na, nb, ra), _jaw_arc(nb, na, rb)]
        _vface(arcs[0][0], arcs[1][0], 0, 1, 'cushion', s, (CX, CY), top=(ba, bb))
        s.items[-1]['slant'] = True
        for arc, base, ref in ((arcs[0], ba, ra), (arcs[1], bb, rb)):   # each end: a fan from the back's end point
            if arc.centre is None:                        # a middle end: the straight jaw alone
                _vface(arc[0], base, 0, 1, 'cushion', s, ref, tri=True)
                continue
            for p0, p1 in zip(arc, arc[1:]):              #   down the rounded nose into the jaw
                _vface(p0, p1, 0, 1, 'cushion', s, arc.centre, toward=False, top=(base, base), tri=True)
                s.items[-1]['slant'] = True
            _vface(arc[-1], base, 0, 1, 'cushion', s, arc.centre, toward=False, tri=True)
    if ROUND_JAWS:                       # the middles' openings over everything (the corners' are under the cloth)
        for (x, y, r, rim) in POCKETS[4:]:
            s.disc(x, y, 1, r, 'pocket')
    return s


class _Arc(list):
    centre = None


ROUND_JAWS = True
JAW_C = None                     # corner: a straight jaw at 45 degrees; the opening drawn over it rounds its end
JAW_M = None                     # middle: a straight jaw from the tip to the back (the PDF's side pocket)
JAW_SEG = 2                      # chords an arc (2026-10-27: 3 -> 2, the points' budget)


def _jaw_arc(tip, other, ref):
    """the rounded end of a cushion at its nose tip `tip` (the other end `other`,
    the pocket's reference `ref`): the arc's points from where the straight nose
    ends to where it meets the jaw's wall, on the bed (mm)."""
    L = C.TABLE_L
    ux, uy = other[0] - tip[0], other[1] - tip[1]
    ln = math.hypot(ux, uy)
    dx, dy = ux / ln, uy / ln                         # along the nose, away from the pocket
    bx, by = -dy, dx                                  # across it, toward the cushion's back
    if bx * (CX - tip[0]) + by * (CY - tip[1]) > 0:
        bx, by = -bx, -by
    middle = abs(ref[0] - L / 2) < 1
    if (JAW_M if middle else JAW_C) is None:          # a straight jaw: no arc, the tip alone
        out = _Arc([tip])
        return out
    start, r, sweep = JAW_M if middle else JAW_C
    tipd = (MH + KN) if middle else CN                # the tip's distance from the pocket now
    sx, sy = tip[0] + dx * (start - tipd), tip[1] + dy * (start - tipd)
    cx, cy = sx + bx * r, sy + by * r
    out = _Arc()
    for k in range(JAW_SEG + 1):
        th = math.radians(sweep) * k / JAW_SEG
        out.append((cx - bx * r * math.cos(th) - dx * r * math.sin(th),
                    cy - by * r * math.cos(th) - dy * r * math.sin(th)))
    out.centre = (cx, cy)
    return out


def _pockets():
    """(x, y, opening radius, leather width) per pocket, mm."""
    L, W = C.TABLE_L, C.TABLE_W
    c, m = HOLE_C, HOLE_M
    return [(-c, -c, HOLE_CR, LEATH_C), (L + c, -c, HOLE_CR, LEATH_C),
            (-c, W + c, HOLE_CR, LEATH_C), (L + c, W + c, HOLE_CR, LEATH_C),
            (L / 2, -m, HOLE_MR, LEATH_M), (L / 2, W + m, HOLE_MR, LEATH_M)]


POCKETS = _pockets()


# ---------------------------------------------------------------------------
# the cast table (VBXE 1.27 raycasting container, as doom's FX127 walls): the
# flat surfaces as ONE top-down texture, each screen row of the rails' outer
# rectangle ONE blit -- the row's texture start and step (7.8) from per-row
# values interpolated between keyrows (every CAST_KR stored rows), which are
# worked out exactly once a frame.  Integer spec of table3d.asm rcast.
# ---------------------------------------------------------------------------
CAST_O = POCKET_D + RAIL_W                  # the rails' outer edge past the bed, mm
CAST_X0, CAST_Y0 = -CAST_O, -CAST_O         # the texture's corner, mm
CAST_TW = CAST_TH = 128                     # texels (the raycaster's 128 x 128)
CAST_SU = (C.TABLE_L + 2 * CAST_O) / CAST_TW            # mm a texel along / across
CAST_SV = (C.TABLE_W + 2 * CAST_O) / CAST_TH
CAST_KR = 8                                 # stored rows between keyrows
CAST_NK = 256 // CAST_KR + 1                # keyrows 0..32 (row 255 needs k + 1)
KU15 = int(round(32 / CAST_SU * 32768))     # texels Q8 per x'' Q3, Q15
KV15 = int(round(32 / CAST_SV * 32768))
MU16 = int(round(16 / CAST_SU * 65536))     # texels Q8 per mm Q4, Q16
MV16 = int(round(16 / CAST_SV * 65536))
X0Q4 = int(round(CAST_X0 * 16))
Y0Q4 = int(round(CAST_Y0 * 16))
assert max(KU15, KV15, MU16, MV16) < 65536


def mulsh(a, b, sh):
    """sign(a b) * ((|a| |b|) >> sh): the asm's unsigned multiply of the magnitudes"""
    m = (abs(a) * abs(b)) >> sh
    return -m if (a < 0) != (b < 0) else m


def cast_texture():
    """the flat items top-down, in layer order: rails, leather, falls, bed,
    pockets, cushion tops -- the vertical faces, the line and the spots stay
    polygons / marks (scene_cast)."""
    s = scene_real()
    items = [it for it in s.items if it['kind'] in ('poly', 'disc')
             and not (it['kind'] == 'poly' and it['cull'] is not None)]
    rp = [((u / 8.0) + CX, (v / 8.0) + CY) for (u, v) in s.rp]

    def pts(it):
        return [rp[s.pp[k][0]] for k in it['pp']]
    tex = bytearray([COL['rail']] * (CAST_TW * CAST_TH))
    for ty in range(CAST_TH):
        for tx in range(CAST_TW):
            x, y = CAST_X0 + (tx + 0.5) * CAST_SU, CAST_Y0 + (ty + 0.5) * CAST_SV
            col = None
            for it in items:
                if it['kind'] == 'poly':
                    p = pts(it)
                    ins, j = False, len(p) - 1
                    for i in range(len(p)):
                        (xi, yi), (xj, yj) = p[i], p[j]
                        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                            ins = not ins
                        j = i
                    if ins:
                        col = it['col']
                else:
                    (cx, cy), = pts(it)
                    if (x - cx) ** 2 + (y - cy) ** 2 <= it['r'] ** 2:
                        col = it['col']
            if col is not None:
                tex[ty * CAST_TW + tx] = col
    return bytes(tex)


def scene_cast():
    """the table as the cast renderer draws it: the rails' outer rectangle
    (kind 'poly' with 'cast': its rows come from the texture), then what stays
    geometry -- the vertical faces, the baulk line, the spots -- in their
    original order."""
    full = scene_real()
    s = Scene()
    L, W = C.TABLE_L, C.TABLE_W
    O = CAST_O
    s.poly([(-O, -O, 0), (L + O, -O, 0), (L + O, W + O, 0), (-O, W + O, 0)], 'rail')
    s.items[-1]['cast'] = True
    rp = [((u / 8.0) + CX, (v / 8.0) + CY) for (u, v) in full.rp]
    for it in full.items:
        keep = (it['kind'] == 'poly' and it['cull'] is not None) or it['kind'] in ('line', 'spot')
        if not keep:
            continue
        pts = [(rp[full.pp[k][0]][0], rp[full.pp[k][0]][1], full.pp[k][1]) for k in it['pp']]
        if it['kind'] == 'poly':
            s.items.append({'kind': 'poly', 'pp': [s.P(*q) for q in pts], 'col': it['col'],
                            'cull': it['cull']})
        elif it['kind'] == 'line':
            s.items.append({'kind': 'line', 'pp': [s.P(*q) for q in pts], 'col': it['col']})
        else:
            s.items.append({'kind': 'spot', 'pp': [s.P(*q) for q in pts], 'col': it['col']})
    return s


# ---------------------------------------------------------------------------
# the integer pipeline
# ---------------------------------------------------------------------------
class Renderer:
    def __init__(self, scene, zooms=ZOOMS):
        self.s = scene
        self.cast_tex = cast_texture() if any(it.get('cast') for it in scene.items) else None
        self.Z = [Zoom(z) for z in zooms]
        self.U = sorted(set(abs(u) for u, v in scene.rp))
        self.Vv = sorted(set(abs(v) for u, v in scene.rp))
        self.cos16 = [int(round(65536 * math.cos(a * 2 * math.pi / ANG))) for a in range(ANG)]
        # the culled faces: (a, b, d') with d' = (a u0 + b v0) >> 1 -- the
        # test runs on the halved eye
        self.cull = {}
        for n, it in enumerate(scene.items):
            if it.get('cull') is not None:
                a_, b_, d_ = it['cull']
                self.cull[n] = (a_, b_, d_ >> 1)
        # the far plane class of every item: 1 = level-H only (the rail top,
        # cushion tops), 0 = touches level 0 (bed, falls, vertical faces)
        self.farcls = []
        for it in scene.items:
            zls = set(scene.pp[p][1] for p in it['pp'])
            self.farcls.append(1 if zls == {1} else 0)
        self.classes = sorted(set((it['r'], it['col']) for it in scene.items if it['kind'] == 'disc'))
        while len(self.classes) < 4:          # (the asm's zoom block holds 4 class pages: unused ones repeat)
            self.classes.append(self.classes[-1])

    # --- the frame's shared work ---
    def trig(self, a):
        c = (self.cos16[a % ANG] + 2) >> 2                 # Q14
        s = (self.cos16[(a - ANG // 4) % ANG] + 2) >> 2     # sin(a) = cos(a - 256)
        return c, s

    def rot_points(self, a):
        """the rotation points about the table centre (Q3): the PRECOMP data.  Only the
        first quarter (a < ANG/4) is computed; a quarter turn more is the same points
        as (-y, x) [2026-10-27: atrboot.asm makes the other three quarters from it]."""
        q, a = (a % ANG) // (ANG // 4), a % (ANG // 4)
        pts = self._rot_q0(a)
        for _ in range(q):
            pts = [(-y, x) for (x, y) in pts]
        return pts

    def _rot_q0(self, a):
        c, s = self.trig(a)
        uc = {u: mulr14h(u, c) for u in self.U}
        us = {u: mulr14h(u, s) for u in self.U}
        vc = {v: mulr14h(v, c) for v in self.Vv}
        vs = {v: mulr14h(v, s) for v in self.Vv}

        def sg(tab, x):
            return tab[x] if x >= 0 else -tab[-x]
        return [(sg(uc, u) - sg(vs, v), sg(us, u) + sg(vc, v)) for (u, v) in self.s.rp]

    @staticmethod
    def pivot_q3(piv):
        """(px, py) Q12 -> (piv - C) >> 9, Q3 signed."""
        return (piv[0] - CXQ) >> 9, (piv[1] - CYQ) >> 9

    def frame(self, a, piv, zi):
        """a: angle, piv: the cue (Q12), zi: zoom index -> rotation points
        (x'', y'' about the pivot), projection points, the halved eye."""
        Z = self.Z[zi]
        c, s = self.trig(a)
        du, dv = self.pivot_q3(piv)
        bx = mulr14(du, c) - mulr14(dv, s)          # rot_rel
        by = mulr14(du, s) + mulr14(dv, c)
        rot = [(x - bx, y - by) for (x, y) in self.rot_points(a)]
        prj = []
        for (k, zl) in self.s.pp:
            xr, yr = rot[k]
            T = xr + Z.OFF
            prj.append(Z.project(T, yr, zl) if Z.valid(T, zl) else None)
        # the eye, halved term by term (the sum could pass 2^15): the
        # products' magnitudes halved, then signed (EX < 0: -sign(c), +sign(s))
        tc = ((-Z.EX) * abs(c) + 8192) >> 15
        ts = ((-Z.EX) * abs(s) + 8192) >> 15
        eu = (du >> 1) + (-tc if c >= 0 else tc)
        ev = (dv >> 1) + (ts if s >= 0 else -ts)
        return rot, prj, (eu, ev)

    # --- clipping ---
    @staticmethod
    def _cross(a, b, plane):
        num, den = abs(plane - a[0]), abs(b[0] - a[0])
        while den >= 65536:                     # a screen edge past 16 bits (sx 24-bit)
            num >>= 1
            den >>= 1
        q = div16r(num, den)
        return (plane, lerp_q16(a[1], b[1], q)) + tuple(a[2:])

    def clip_poly(self, verts, planes):
        """Sutherland-Hodgman against each (plane, keep_ge) on coordinate 0."""
        for plane, keep_ge in planes:
            out = []
            n = len(verts)
            for i in range(n):
                a, b = verts[i], verts[(i + 1) % n]
                ina = (a[0] >= plane) if keep_ge else (a[0] <= plane)
                inb = (b[0] >= plane) if keep_ge else (b[0] <= plane)
                if ina:
                    out.append(a)
                if ina != inb:
                    out.append(self._cross(a, b, plane))
            verts = out
            if not verts:
                break
        return verts

    def clip_seg(self, verts, planes):
        """a segment: an endpoint outside is replaced by the crossing (always
        computed from verts[0] toward verts[1]); both outside -> None."""
        for plane, keep_ge in planes:
            a, b = verts
            ina = (a[0] >= plane) if keep_ge else (a[0] <= plane)
            inb = (b[0] >= plane) if keep_ge else (b[0] <= plane)
            if not ina and not inb:
                return None
            if ina != inb:
                cross = self._cross(a, b, plane)
                verts = [a, cross] if ina else [cross, b]
        return verts

    def table_verts(self, pp, rot, Z):
        out = []
        for p in pp:
            k, zl = self.s.pp[p]
            xr, yr = rot[k]
            out.append((xr + Z.OFF, yr, zl))
        return out

    def poly_pts(self, it, n, rot, prj, Z, st):
        """the polygon's screen vertices (x Q7, stored row) after both clips,
        or None."""
        pp = it['pp']
        if all(prj[p] is not None for p in pp):
            pts = [prj[p][:2] for p in pp]
            zls = [self.s.pp[p][1] for p in pp]
        else:
            st['clipped'] += 1
            tmax = Z.TFH if self.farcls[n] else Z.TF0
            verts = self.clip_poly(self.table_verts(pp, rot, Z), ((0, True), (tmax - 1, False)))
            if len(verts) < 3:
                return None
            pts = [Z.project(T, y, zl)[:2] for (T, y, zl) in verts]
            zls = [zl for (T, y, zl) in verts]
        if any(not 0 <= x <= SCR_W * 16 for x, r in pts):
            st['xclipped'] += 1
            pts = self.clip_poly(pts, ((0, True), (SCR_W * 16, False)))
            if len(pts) < 3:
                return None
        return [(x << 3, r) for (x, r) in pts]

    def line_pts(self, it, rot, prj, Z):
        pp = it['pp']
        if all(prj[p] is not None for p in pp):
            pts = [prj[p][:2] for p in pp]
        else:
            verts = self.clip_seg(self.table_verts(pp, rot, Z), ((0, True), (Z.TF0 - 1, False)))
            if verts is None:
                return None
            pts = [Z.project(T, y, zl)[:2] for (T, y, zl) in verts]
        pts = self.clip_seg(pts, ((0, True), (SCR_W * 16, False)))
        if pts is None:
            return None
        return [(x << 3, r) for (x, r) in pts]

    # --- rasterisation ---
    def fill(self, buf, pts, col, st):
        for r, (xl, xr) in self.spans(pts, st):
            y = r - ROW_BIAS
            if xr <= xl or not 0 <= y < SCR_H:
                continue
            st['spans'] += 1
            st['px'] += xr - xl
            buf[y * SCR_W + xl:y * SCR_W + xr] = bytes([col]) * (xr - xl)

    def spans(self, pts, st):
        """the polygon's rows: [(stored row, (xl, xr))] from its two chains"""
        n = len(pts)
        top = min(range(n), key=lambda i: (pts[i][1], i))
        # chains from the top vertex: forward = A, backward = B

        def chain(dirn):
            e = []
            i = top
            while True:
                j = (i + dirn) % n
                if pts[j][1] < pts[i][1]:
                    break
                e.append((pts[i], pts[j]))
                i = j
                if i == top:
                    break
            return e
        A, B = chain(1), chain(-1)
        st['polys'] += 1

        def rows(ch):
            out = {}
            for (p, q) in ch:
                if q[1] == p[1]:
                    continue
                st['edges'] += 1
                e = edge(p, q)
                if e is None:
                    continue
                r0, r1, x, m = e
                for r in range(r0, r1):
                    out[r] = x >> 8
                    x += m
            return out
        ra, rb = rows(A), rows(B)
        out = []
        for r in sorted(set(ra) & set(rb)):
            xl, xr = ra[r], rb[r]
            if xl > xr:
                xl, xr = xr, xl
            assert 0 <= xl and xr <= SCR_W, (xl, xr)
            out.append((r, (xl, xr)))
        return out

    def blit(self, buf, img, w, h, x0, y0, st):
        """a sprite (colour 0 clear), top-left (x0, stored row y0),
        rectangle-clipped to the screen."""
        y0 -= ROW_BIAS
        cx0, cy0 = max(0, x0), max(0, y0)
        cx1, cy1 = min(SCR_W, x0 + w), min(SCR_H, y0 + h)
        if cx1 <= cx0 or cy1 <= cy0:
            return
        st['discs'] += 1
        for y in range(cy0, cy1):
            for x in range(cx0, cx1):
                v = img[(y - y0) * w + (x - x0)]
                if v:
                    buf[y * SCR_W + x] = v

    def line(self, buf, a, b, col, st):
        """the baulk line: per row the run between this row's and the next
        row's x (>= 1 px), in the row window."""
        if a[1] > b[1]:
            a, b = b, a
        e = edge(a, b)
        w = SCR_W
        if e is None or e[1] - e[0] == 1:   # flat or one row (its edge never steps): one run, end inclusive
            lo, hi = min(a[0], b[0]) >> 7, (max(a[0], b[0]) >> 7) + 1
            y = a[1] - ROW_BIAS
            if 0 <= y < SCR_H:
                buf[y * w + lo:y * w + min(w, hi)] = bytes([col]) * (min(w, hi) - lo)
                st['spans'] += 1
            return
        r0, r1, x, m = e
        for r in range(r0, r1):
            xa, xb = x >> 8, (x + m) >> 8
            lo, hi = min(xa, xb), max(xa, xb)
            if hi == lo:
                hi = lo + 1
            y = r - ROW_BIAS
            if 0 <= y < SCR_H:
                lo2, hi2 = max(0, lo), min(w, hi)
                if hi2 > lo2:
                    buf[y * w + lo2:y * w + hi2] = bytes([col]) * (hi2 - lo2)
                    st['spans'] += 1
            x += m

    def cast_keys(self, a, piv, zi):
        """the frame's keyrows: per keyrow the texture point of the screen's
        centre pixel 160 (Q8) and the step per pixel (Q16), u and v -- cast.asm"""
        Z = self.Z[zi]
        c, s = self.trig(a)
        cu, su = mulsh(c, KU15, 15), mulsh(s, KU15, 15)
        cv, sv = mulsh(c, KV15, 15), mulsh(s, KV15, 15)
        bu = (((piv[0] >> 8) - X0Q4) * MU16) >> 16
        bv = (((piv[1] >> 8) - Y0Q4) * MV16) >> 16
        cuo, svo = mulsh(cu, Z.OFF, 14), mulsh(sv, Z.OFF, 14)
        keys = []
        for k in range(CAST_NK):
            T, G = Z.KT[k], Z.KG[k]
            du = mulsh(su, G, 13)
            dv = mulsh(cv, G, 13)
            u0 = bu + mulsh(cu, T, 14) - cuo + (du >> 9)      # (pixel 160: y'' = half a pixel)
            v0 = bv - mulsh(sv, T, 14) + svo + (dv >> 9)
            keys.append((u0, du, v0, dv))
        return keys

    def cast_fill(self, buf, pts, keys, st):
        """the rails' rectangle row by row: its span from the polygon's chains
        (as fill), the texture walked as the raycasting container does it"""
        tex = self.cast_tex
        for r, (xl, xr) in self.spans(pts, st):
            y = r - ROW_BIAS
            if xr <= xl or not 0 <= y < SCR_H:
                continue
            k, f = r >> 3, r & 7
            vals = []
            for q in range(4):
                a0, a1 = keys[k][q], keys[k + 1][q]
                vals.append(a0 + ((a1 - a0) >> 3) * f)
            u0, du, v0, dv = vals
            us = u0 + mulsh(du, xl - 160, 8)
            vs = v0 + mulsh(dv, xl - 160, 8)
            xa, ya = us & 0x7FFF, vs & 0x7FFF
            sx, sy = (du >> 8) & 0x7FFF, (dv >> 8) & 0x7FFF
            st['spans'] += 1
            st['casts'] = st.get('casts', 0) + 1
            for x in range(xl, xr):
                buf[y * SCR_W + x] = tex[((ya >> 8) & 127) * CAST_TW + ((xa >> 8) & 127)]
                xa = (xa + sx) & 0x7FFF
                ya = (ya + sy) & 0x7FFF

    def render(self, a, piv, zi, st=None):
        if st is None:
            st = {}
        for k in ('polys', 'edges', 'spans', 'px', 'discs', 'culled', 'clipped', 'xclipped'):
            st.setdefault(k, 0)
        Z = self.Z[zi]
        rot, prj, (eu, ev) = self.frame(a, piv, zi)
        buf = bytearray([COL['backdrop']] * (SCR_W * SCR_H))
        keys = None
        for n, it in enumerate(self.s.items):
            if n in self.cull:
                a_, b_, d_ = self.cull[n]
                if not a_ * eu + b_ * ev + (Z.KS if it.get('slant') else 0) > d_:
                    st['culled'] += 1
                    continue
            if it['kind'] == 'poly':
                pts = self.poly_pts(it, n, rot, prj, Z, st)
                if pts is not None:
                    if it.get('cast'):
                        if keys is None:
                            keys = self.cast_keys(a, piv, zi)
                        self.cast_fill(buf, pts, keys, st)
                    else:
                        self.fill(buf, pts, it['col'], st)
            elif it['kind'] == 'disc':
                p = prj[it['pp'][0]]
                if p is None:
                    continue
                sx, row, i = p
                img, rx, ry = disc_sprite(Z.L, 1, i, it['r'], it['col'])   # (sized as rot_export: level H)
                self.blit(buf, img, 2 * rx + 1, 2 * ry + 1, (sx >> 4) - rx, row - ry, st)
            elif it['kind'] == 'line':
                pts = self.line_pts(it, rot, prj, Z)
                if pts is not None:
                    self.line(buf, pts[0], pts[1], it['col'], st)
            elif it['kind'] == 'spot':
                p = prj[it['pp'][0]]
                if p is None:
                    continue
                x, y = p[0] >> 4, p[1] - ROW_BIAS
                if 0 <= x < SCR_W - 1 and 0 <= y < SCR_H - 1:
                    for yy in (y, y + 1):
                        buf[yy * SCR_W + x:yy * SCR_W + x + 2] = bytes([it['col']]) * 2
                    st['spans'] += 1
        return buf, st

    # --- balls (render.asm project) ---
    def ball(self, a, piv, zi, pos):
        """a ball at pos (Q12) -> (x, stored row, size) of its sprite corner,
        or None (behind the near plane / past the far one)."""
        Z = self.Z[zi]
        c, s = self.trig(a)
        du, dv = (pos[0] - piv[0]) >> 9, (pos[1] - piv[1]) >> 9
        xr, yr = ball_rot(c, s, du, dv) if a % ANG else (du, dv)
        T = xr + Z.OFF
        if not 0 <= T < Z.TFH:
            return None
        i, f = T >> 8, T & 255
        row, dr, kk, dk = Z.L[2]
        sy = row[i] - ((dr[i] * f) >> 8)
        kv = kk[i] - ((dk[i] * f) >> 8)
        m = mulh(abs(yr), kv) >> 15
        if m >= 32768:                          # 2048 px off the axis: never on the screen
            return None
        sx = SXC + (m if yr >= 0 else -m)
        size = Z.BS[i]
        return ((sx + 8) >> 4) - size, ((sy + 8) >> 4) - size, size


def save(path, buf):
    from vbxe_export import write_png
    pal = open(os.path.join(os.path.dirname(HERE), 'build', 'assets', 'palette.bin'), 'rb').read()
    rgb = bytearray()
    for v in buf:
        rgb += pal[v * 3:v * 3 + 3]
    write_png(path, SCR_W, SCR_H, bytes(rgb))
    print('->', path)


PIVOTS = {'centre': (CXQ, CYQ), 'd': (597 << 12, 709 << 12), 'far': (3300 << 12, 1700 << 12),
          'side': (1784 << 12, 60 << 12)}


def top_view(sc, x0, y0, x1, y1, S=1.0, outlines=True):
    """the scene from straight above: the region x0..x1, y0..y1 (mm) at S px/mm, the items
    in layer order (polygons filled, discs, lines, spots), the palette's colours -> a PIL image"""
    from PIL import Image, ImageDraw
    pal = open(os.path.join(os.path.dirname(HERE), 'build', 'assets', 'palette.bin'), 'rb').read()
    rgb = lambda c: tuple(pal[c * 3:c * 3 + 3])
    im = Image.new('RGB', (int((x1 - x0) * S), int((y1 - y0) * S)), (20, 20, 20))
    d = ImageDraw.Draw(im)
    P = lambda i: ((CX + sc.rp[sc.pp[i][0]][0] / 8 - x0) * S, (y1 - CY - sc.rp[sc.pp[i][0]][1] / 8) * S)
    ow = int(round(OUTL * S)) if ROUND_JAWS and outlines else 0   # the PDF's black outlines
    for it in sc.items:
        pts = [P(i) for i in it['pp']]
        if it['kind'] == 'poly':
            d.polygon(pts, fill=rgb(it['col']))
            if ow and it['col'] != COL['backdrop']:
                edges = it.get('outl')
                for k in (range(len(pts)) if edges is None else edges):
                    d.line([pts[k], pts[(k + 1) % len(pts)]], fill=(45, 45, 45), width=ow)
        elif it['kind'] == 'disc':
            (x, y), r = pts[0], it['r'] * S
            d.ellipse([x - r, y - r, x + r, y + r], fill=rgb(it['col']))   # (no line round an opening: the PDF has none)
        elif it['kind'] == 'line':
            d.line(pts, fill=rgb(it['col']), width=max(1, int(S)))
        elif it['kind'] == 'spot':
            (x, y), r = pts[0], 3 * S
            d.ellipse([x - r, y - r, x + r, y + r], fill=rgb(it['col']))
    return im


def compare_png(path):
    """tools/out/_pockets_cmp.png: the PDF's pool pockets (trick_shot_top_10, page 4 bottom: the bottom
    right corner, the bottom middle; its ball r 16.5 px = our 26.25 mm) beside the model's from above
    at the same mm scale, the model half see-through on the PDF, and the edges (the PDF's black lines
    red, the model's colour boundaries blue, both white) -- also tools/out/_edges_<pocket>.png at 3x"""
    from PIL import Image, ImageDraw
    L, W = C.TABLE_L, C.TABLE_W
    MMPX = C.BALL_R / 16.5                              # the PDF by its ball: r 16.5 px there -> our 26.25 mm
    S = 1.2
    k = MMPX * S                                        # page px -> panel px
    pdf = Image.open(os.path.join(HERE, 'out', '_pdf_p4_1.jpg')).convert('RGB')
    panels = []
    for (name, box, px_ref, rx, ry) in (('corner', (1430, 700, 1651, 919), (1556, 824), L, 0),
                                        ('middle', (690, 700, 960, 919), (825, 824), L / 2, 0)):
        crop = pdf.crop(box).resize((int((box[2] - box[0]) * k), int((box[3] - box[1]) * k)), Image.LANCZOS)
        # the model over exactly the crop's region: the nose lines' crossing px_ref is the table's (rx, ry)
        mx0, mx1 = rx - (px_ref[0] - box[0]) * MMPX, rx + (box[2] - px_ref[0]) * MMPX
        my1, my0 = ry + (px_ref[1] - box[1]) * MMPX, ry - (box[3] - px_ref[1]) * MMPX
        mine = top_view(scene_real(), mx0, my0, mx1, my1, S).resize(crop.size)
        over = Image.blend(crop, mine, 0.5)
        bare = top_view(scene_real(), mx0, my0, mx1, my1, S, outlines=False).resize(crop.size)   # (edges: single lines)
        ed = Image.new('RGB', crop.size, (0, 0, 0))
        cp, mp, ep = crop.load(), bare.load(), ed.load()
        isk = lambda c: c[0] < 90 and c[1] < 90 and c[2] < 90
        for yy in range(2, crop.height - 2):
            for xx in range(2, crop.width - 2):
                pk = isk(cp[xx, yy]) and any(not isk(cp[xx + dx, yy + dy]) for dx, dy in ((2, 0), (-2, 0), (0, 2), (0, -2)))
                c0 = mp[xx, yy]
                mk = any(mp[xx + dx, yy + dy] != c0 for dx, dy in ((1, 0), (0, 1)))
                if pk or mk:
                    ep[xx, yy] = (255, 255, 255) if pk and mk else (220, 40, 40) if pk else (60, 120, 255)
        ed.resize((ed.width * 3, ed.height * 3), Image.NEAREST).save(os.path.join(HERE, 'out', '_edges_%s.png' % name))
        h = crop.height
        row = Image.new('RGB', (4 * crop.width + 90, h + 24), (40, 40, 40))
        for n, im in enumerate((crop, mine, over, ed)):
            row.paste(im, (n * (crop.width + 30), 24))
        dr = ImageDraw.Draw(row)
        for n, t in enumerate(('PDF (pool, 9 ft) -- ' + name, 'model (snooker), from above', 'model over the PDF, half see-through',
                               'edges: PDF red, model blue, both white')):
            dr.text((n * (crop.width + 30) + 4, 4), t, fill=(255, 255, 255))
        panels.append(row)
    out = Image.new('RGB', (max(p_.width for p_ in panels), sum(p_.height for p_ in panels) + 10), (40, 40, 40))
    y = 0
    for p_ in panels:
        out.paste(p_, (0, y)); y += p_.height + 10
    out.save(path)
    print('->', path)


def main():
    if '--cmp' in sys.argv:
        compare_png(os.path.join(HERE, 'out', '_pockets_cmp.png'))
        return
    r = Renderer(scene_real())
    for Z in r.Z:
        print('zoom %.1f: OFF %d (near plane %.0f mm from the pivot), far planes T %d / %d, NLUT %d, ball size %d'
              % (Z.zoom, Z.OFF, Z.XMIN - CX, Z.TF0, Z.TFH, Z.NLUT, max(Z.BS)))
    if '--png' in sys.argv:
        out = os.path.join(HERE, 'out')
        for name, piv in PIVOTS.items():
            for deg in (0, 60, 180):
                for zi in range(len(ZOOMS)):
                    a = int(round(deg / 360 * ANG)) % ANG
                    save(os.path.join(out, 'rotref_%s_%d_z%d.png' % (name, deg, zi)), r.render(a, piv, zi)[0])
        return
    for zi in range(len(ZOOMS)):
        tot, n = {}, 0
        for name, piv in PIVOTS.items():
            for a in range(0, ANG, 64):
                buf, st = r.render(a, piv, zi)
                for k, v in st.items():
                    tot[k] = tot.get(k, 0) + v
                n += 1
        print('zoom %d: avg per frame %s' % (zi, {k: round(v / n, 1) for k, v in tot.items()}))


if __name__ == '__main__':
    main()
