#!/usr/bin/env python3
"""ai-snooker - shared core: table geometry, two physics engines, rules.

Two engines run the SAME shot in lockstep so the GUI can show, side by side:
  * FloatEngine  -- "PC truth": full float math, the reference behaviour.
  * FixedEngine  -- "Atari": integer fixed-point math the 6502 + VBXE will
                    actually run (Q8 = 1/256 mm positions/velocities, BAM
                    angles via a 256-entry sin/cos LUT, integer isqrt for
                    distances, integer mul/div for the collision normal).

The point is to MEASURE how far the Atari approximation drifts from the PC
truth under a realistic per-frame substep budget, so we know what the 6502
port needs before writing a line of assembly.

Run this file directly for a headless self-test (no display needed):
    python snooker_core.py
"""

import math

# --------------------------------------------------------------------------
# Table geometry  (all lengths in millimetres; standard 12-ft snooker table)
# --------------------------------------------------------------------------
TABLE_L = 3569.0          # playing-area length  (x: 0 = baulk end, L = top end)
TABLE_W = 1778.0          # playing-area width   (y)
BALL_D  = 52.5            # ball diameter
BALL_R  = BALL_D / 2.0    # 26.25

BAULK_X = 737.0           # baulk line, 29" from baulk cushion
D_R     = 292.0           # radius of the "D", 11.5"

# Colour ball home spots (mm).  green/brown/yellow on the baulk line.
SPOTS = {
    'green':  (BAULK_X,        TABLE_W / 2 - D_R),
    'brown':  (BAULK_X,        TABLE_W / 2),
    'yellow': (BAULK_X,        TABLE_W / 2 + D_R),
    'blue':   (TABLE_L / 2,    TABLE_W / 2),
    'pink':   (TABLE_L * 0.75, TABLE_W / 2),     # midway centre->top cushion
    'black':  (TABLE_L - 324.0, TABLE_W / 2),    # 12.75" from top cushion
}

VALUE = {'red': 1, 'yellow': 2, 'green': 3, 'brown': 4,
         'blue': 5, 'pink': 6, 'black': 7, 'cue': 0}

# Colours cleared in ascending value order once the reds are gone.
COLOUR_ORDER = ['yellow', 'green', 'brown', 'blue', 'pink', 'black']

# Pockets: (x, y, capture_radius_mm).  Corners gobble more than the middles.
POCKETS = [
    (0.0,        0.0,        72.0),
    (TABLE_L,    0.0,        72.0),
    (0.0,        TABLE_W,    72.0),
    (TABLE_L,    TABLE_W,    72.0),
    (TABLE_L/2,  0.0,        58.0),
    (TABLE_L/2,  TABLE_W,    58.0),
]

# Cue ball break position (inside the D).
CUE_START = (BAULK_X - 140.0, TABLE_W / 2 - 180.0)

APEX_GAP = 1.5            # mm, the apex red to the pink: as near as possible without touching
RACK_EPS = 1.0 / 4096     # mm, one physics unit between racked reds: d2 >= MIND2 after rounding

# --------------------------------------------------------------------------
# Physics tunables (shared targets; FixedEngine quantises these)
# --------------------------------------------------------------------------
DECEL_MM_S2   = 650.0     # rolling deceleration (constant), mm/s^2
REST_CUSHION  = 0.85      # cushion restitution
REST_BALL     = 0.95      # ball-ball restitution
STOP_SPEED    = 8.0       # below this (mm/s) a ball is parked
MAX_SHOT      = 5500.0    # mm/s at full power

# VBXE-ish palette (RGB).  Used by the GUI for both panels.
PAL = {
    'baize':   (26, 116, 58),
    'cushion': (20, 96, 50),
    'cushtop': (40, 140, 74),     # lit cushion nose
    'rail':    (110, 68, 32),     # wood rail top
    'railside':(72, 42, 18),      # wood rail outer face (shadowed)
    'raillite':(120, 76, 40),     # rail bevel highlight
    'backdrop':(22, 19, 16),      # dark room behind the table (2.5D)
    'leather': (196, 150, 100),   # the pocket leather: a light tan U round the drop (cus.jpg)
    'fall':    (12, 62, 32),      # the cloth falling into the pocket throat: the baize in shadow
    'pocket':  (5, 5, 6),
    'net':     (232, 232, 226),   # the pocket net's cord: white
    'line':    (205, 205, 170),
    'spot':    (200, 200, 170),
    'red':     (198, 32, 26),
    'yellow':  (226, 198, 42),
    'green':   (28, 132, 56),
    'brown':   (132, 76, 34),
    'blue':    (36, 72, 192),
    'pink':    (236, 122, 150),
    'black':   (22, 22, 22),
    'cue':     (244, 240, 224),
}


# --------------------------------------------------------------------------
# Ball
# --------------------------------------------------------------------------
class Ball:
    __slots__ = ('kind', 'color', 'value', 'x', 'y', 'vx', 'vy', 'on', 'spot',
                 'fric')

    def __init__(self, kind, color, x, y, spot=None):
        self.kind = kind          # 'cue' | 'object'
        self.color = color
        self.value = VALUE.get(color, 0)
        self.x = x
        self.y = y
        self.vx = 0.0
        self.vy = 0.0
        self.on = True            # still on the table
        self.spot = spot          # home spot (mm) for colour respots
        self.fric = 0             # FixedEngine: friction-remainder accumulator


def build_rack():
    """Return a fresh list of balls (cue first), in mm float coordinates."""
    balls = [Ball('cue', 'cue', CUE_START[0], CUE_START[1])]

    # 15 reds: the triangle behind the pink, apex toward baulk, the balls
    # TOUCHING (WPBSA: racked tight, d = 52.5 mm; zac.txt), the apex as near
    # the pink as possible without touching it: APEX_GAP.  RACK_EPS keeps
    # every pair's Q12 distance at or over 2R after rounding (zac2.txt 3:
    # exact 52.5 lands the diagonal pairs 38300 Q12^2 UNDER MIND2).
    d = BALL_D + RACK_EPS
    px, py = SPOTS['pink']
    apex_x = px + BALL_R + APEX_GAP + BALL_R
    step_x = d * math.cos(math.radians(30))      # row pitch along x
    for row in range(5):
        rx = apex_x + row * step_x
        for k in range(row + 1):
            ry = py + (k - row / 2.0) * d
            balls.append(Ball('object', 'red', rx, ry))

    # 6 colours on their spots.
    for color in COLOUR_ORDER:
        sx, sy = SPOTS[color]
        balls.append(Ball('object', color, sx, sy, spot=(sx, sy)))
    return balls


# --------------------------------------------------------------------------
# FloatEngine -- the "PC truth"
# --------------------------------------------------------------------------
class FloatEngine:
    name = 'PC (float)'

    def __init__(self, balls):
        self.balls = balls
        self.reset_shot()

    def reset_shot(self):
        self.first_contact = None     # first object ball the cue touched
        self.potted = []              # object balls potted this shot (in order)
        self.cue_potted = False

    @property
    def cue(self):
        return self.balls[0]

    def shoot(self, angle, power):
        self.reset_shot()
        sp = power * MAX_SHOT
        self.cue.vx = math.cos(angle) * sp
        self.cue.vy = math.sin(angle) * sp

    def moving(self):
        for b in self.balls:
            if b.on and (b.vx * b.vx + b.vy * b.vy) > 0.0:
                return True
        return False

    def step(self, dt):
        # substep so the fastest ball never moves more than ~half a radius
        maxv = 0.0
        for b in self.balls:
            if b.on:
                maxv = max(maxv, math.hypot(b.vx, b.vy))
        n = 1
        if maxv > 0:
            n = max(1, min(16, int(math.ceil(maxv * dt / (BALL_R * 0.5)))))
        sub = dt / n
        for _ in range(n):
            self._substep(sub)

    def _substep(self, dt):
        for b in self.balls:
            if not b.on:
                continue
            sp = math.hypot(b.vx, b.vy)
            if sp > 0:
                if sp <= STOP_SPEED:
                    b.vx = b.vy = 0.0
                else:
                    ns = sp - DECEL_MM_S2 * dt
                    if ns < 0:
                        ns = 0.0
                    f = ns / sp
                    b.vx *= f
                    b.vy *= f
            b.x += b.vx * dt
            b.y += b.vy * dt
        self._pockets()
        self._cushions()
        self._collisions()

    def _cushions(self):
        for b in self.balls:
            if not b.on:
                continue
            if b.x < BALL_R:
                b.x = BALL_R; b.vx = -b.vx * REST_CUSHION
            elif b.x > TABLE_L - BALL_R:
                b.x = TABLE_L - BALL_R; b.vx = -b.vx * REST_CUSHION
            if b.y < BALL_R:
                b.y = BALL_R; b.vy = -b.vy * REST_CUSHION
            elif b.y > TABLE_W - BALL_R:
                b.y = TABLE_W - BALL_R; b.vy = -b.vy * REST_CUSHION

    def _collisions(self):
        bs = self.balls
        n = len(bs)
        for i in range(n):
            a = bs[i]
            if not a.on:
                continue
            for j in range(i + 1, n):
                b = bs[j]
                if not b.on:
                    continue
                dx = b.x - a.x
                dy = b.y - a.y
                d2 = dx * dx + dy * dy
                mind = 2 * BALL_R
                if d2 >= mind * mind or d2 == 0:
                    continue
                d = math.sqrt(d2)
                nx = dx / d
                ny = dy / d
                # separate the overlap
                ov = (mind - d) * 0.5
                a.x -= nx * ov; a.y -= ny * ov
                b.x += nx * ov; b.y += ny * ov
                # normal relative velocity (a approaching b is positive)
                rvn = (a.vx - b.vx) * nx + (a.vy - b.vy) * ny
                if rvn > 0:
                    imp = (1 + REST_BALL) * rvn * 0.5
                    a.vx -= imp * nx; a.vy -= imp * ny
                    b.vx += imp * nx; b.vy += imp * ny
                self._record_contact(a, b)

    def _record_contact(self, a, b):
        if self.first_contact is None:
            if a.kind == 'cue' and b.kind == 'object':
                self.first_contact = b
            elif b.kind == 'cue' and a.kind == 'object':
                self.first_contact = a

    def _pockets(self):
        for b in self.balls:
            if not b.on:
                continue
            for (px, py, pr) in POCKETS:
                if (b.x - px) ** 2 + (b.y - py) ** 2 <= pr * pr:
                    b.on = False
                    b.vx = b.vy = 0.0
                    if b.kind == 'cue':
                        self.cue_potted = True
                    else:
                        self.potted.append(b)
                    break

    # ---- positions in mm (for the GUI / divergence metric / rules) ----
    def pos_mm(self, b):
        return (b.x, b.y)

    def set_pos_mm(self, b, x, y):
        b.x = x
        b.y = y


# --------------------------------------------------------------------------
# FixedEngine -- the "Atari": integer fixed-point, BAM angles, LUT sin/cos
# --------------------------------------------------------------------------
FX = 12                     # fractional bits: Q12, 1/4096 mm (6502: 3-byte pos)
ONE = 1 << FX               # 4096

# Shot-direction LUT: ANG_STEPS angles over a full turn, values Q15.  256 steps
# (1.4 deg) proved too coarse for aiming; 1024 steps (~0.35 deg, a 2 KB sin/cos
# table on the 6502) tracks the float aim well.  Collision normals do NOT use
# this table -- they divide by the integer distance, so they stay fine-grained.
ANG_STEPS = 1024
_SIN = [int(round(math.sin(a * 2 * math.pi / ANG_STEPS) * 32767))
        for a in range(ANG_STEPS)]
_COS = [int(round(math.cos(a * 2 * math.pi / ANG_STEPS) * 32767))
        for a in range(ANG_STEPS)]


def to_fx(mm):
    return int(round(mm * ONE))


def to_mm(fx):
    return fx / ONE


def _rsh(v, s):
    """Round-to-nearest right shift (v >> s).  On the 6502 this is 'add half
    the rounding unit, then shift' -- one extra ADC -- and halves the
    truncation bias vs a plain >>."""
    return (v + (1 << (s - 1))) >> s


def _idiv(num, den):
    """Round-to-nearest integer division (den > 0), symmetric for negatives."""
    if num >= 0:
        return (num + (den >> 1)) // den
    return -((-num + (den >> 1)) // den)


class FixedEngine:
    name = 'ATARI (fixed-point)'

    def __init__(self, balls, substeps=4, frame_hz=50):
        # mirror the float rack into integer Q8 coordinates
        self.balls = balls
        self.set_rate(substeps, frame_hz)
        # geometry pre-quantised to Q8
        self.R   = to_fx(BALL_R)
        self.L   = to_fx(TABLE_L)
        self.W   = to_fx(TABLE_W)
        self.pockets = [(to_fx(px), to_fx(py), to_fx(pr)) for px, py, pr in POCKETS]
        self.rest_c = int(REST_CUSHION * 256)   # Q8 restitution
        self.rest_b = int(REST_BALL * 256)
        self.reset_shot()

    def set_rate(self, substeps, frame_hz=50):
        """One 'tick' = 1/(frame_hz*substeps) s -- the honest Atari budget."""
        self.substeps = substeps
        self.ftps = frame_hz * substeps                     # fixed ticks / second
        # Constant friction = velocity loss per tick (Q12/tick).  Because the
        # per-tick loss is tiny (and shrinks with ftps^2), we keep it with 8
        # extra fractional bits and carry the remainder per ball (see _friction)
        # so the *average* deceleration is exact regardless of substep count.
        self.dec_hi = max(1, int(round(DECEL_MM_S2 * ONE * 256 / (self.ftps * self.ftps))))
        self.stop_v = max(1, int(round(STOP_SPEED * ONE / self.ftps)))   # Q12/tick

    def sync_from(self, fl):
        """Re-quantise this engine's balls to match a FloatEngine state, so we
        can measure the divergence of a SINGLE shot from a shared start rather
        than letting two chaotic games drift apart forever."""
        for nb, b in zip(self.balls, fl.balls):
            nb.x = to_fx(b.x)
            nb.y = to_fx(b.y)
            nb.vx = 0
            nb.vy = 0
            nb.fric = 0
            nb.on = b.on
        self.reset_shot()

    def reset_shot(self):
        self.first_contact = None
        self.potted = []
        self.cue_potted = False
        self._acc = 0.0          # leftover real-time to convert into ticks

    @property
    def cue(self):
        return self.balls[0]

    def shoot(self, angle_units, power):
        """angle_units: 0..ANG_STEPS-1 ; power: 0..1.  Velocity built from the
        LUT, in Q12 mm per tick (integer add to position each tick = 6502)."""
        self.reset_shot()
        # mm/s -> Q12 per tick
        sp = int(round(power * MAX_SHOT * ONE / self.ftps))
        a = angle_units & (ANG_STEPS - 1)
        self.cue.vx = _rsh(sp * _COS[a], 15)
        self.cue.vy = _rsh(sp * _SIN[a], 15)

    def moving(self):
        for b in self.balls:
            if b.on and (b.vx or b.vy):
                return True
        return False

    def step(self, dt):
        # advance the integer engine by whole ticks matching real elapsed time
        self._acc += dt * self.ftps
        ticks = int(self._acc)
        self._acc -= ticks
        if ticks > 60:           # clamp after a long stall
            ticks = 60
        for _ in range(ticks):
            self._tick()

    def _tick(self):
        for b in self.balls:
            if not b.on:
                continue
            self._friction(b)
            b.x += b.vx          # pure integer integration
            b.y += b.vy
        self._pockets()
        self._cushions()
        self._collisions()

    def _friction(self, b):
        sp = math.isqrt(b.vx * b.vx + b.vy * b.vy)    # Q12/tick (integer sqrt)
        if sp == 0:
            return
        if sp <= self.stop_v:
            b.vx = b.vy = 0
            b.fric = 0
            return
        b.fric += self.dec_hi                         # carry the 8 extra bits
        dec = b.fric >> 8
        b.fric &= 255
        ns = sp - dec
        if ns < 0:
            ns = 0
        # scale (vx,vy) by ns/sp using integer mul/div (round to nearest)
        b.vx = _idiv(b.vx * ns, sp)
        b.vy = _idiv(b.vy * ns, sp)

    def _cushions(self):
        for b in self.balls:
            if not b.on:
                continue
            if b.x < self.R:
                b.x = self.R; b.vx = -_rsh(b.vx * self.rest_c, 8)
            elif b.x > self.L - self.R:
                b.x = self.L - self.R; b.vx = -_rsh(b.vx * self.rest_c, 8)
            if b.y < self.R:
                b.y = self.R; b.vy = -_rsh(b.vy * self.rest_c, 8)
            elif b.y > self.W - self.R:
                b.y = self.W - self.R; b.vy = -_rsh(b.vy * self.rest_c, 8)

    def _collisions(self):
        bs = self.balls
        n = len(bs)
        mind = 2 * self.R
        mind2 = mind * mind
        for i in range(n):
            a = bs[i]
            if not a.on:
                continue
            for j in range(i + 1, n):
                b = bs[j]
                if not b.on:
                    continue
                dx = b.x - a.x
                dy = b.y - a.y
                d2 = dx * dx + dy * dy
                if d2 >= mind2 or d2 == 0:
                    continue
                d = math.isqrt(d2)
                if d == 0:
                    continue
                # unit normal in Q16 (round-to-nearest division)
                nx = _idiv(dx << 16, d)
                ny = _idiv(dy << 16, d)
                ov = _rsh(mind - d, 1)                # half overlap, Q12
                a.x -= _rsh(nx * ov, 16); a.y -= _rsh(ny * ov, 16)
                b.x += _rsh(nx * ov, 16); b.y += _rsh(ny * ov, 16)
                rvn = _rsh((a.vx - b.vx) * nx + (a.vy - b.vy) * ny, 16)  # Q12/tick
                if rvn > 0:
                    imp = _rsh((256 + self.rest_b) * rvn, 9)           # (1+e)/2
                    a.vx -= _rsh(imp * nx, 16); a.vy -= _rsh(imp * ny, 16)
                    b.vx += _rsh(imp * nx, 16); b.vy += _rsh(imp * ny, 16)
                self._record_contact(a, b)

    def _record_contact(self, a, b):
        if self.first_contact is None:
            if a.kind == 'cue' and b.kind == 'object':
                self.first_contact = b
            elif b.kind == 'cue' and a.kind == 'object':
                self.first_contact = a

    def _pockets(self):
        for b in self.balls:
            if not b.on:
                continue
            for (px, py, pr) in self.pockets:
                ddx = b.x - px
                ddy = b.y - py
                if ddx * ddx + ddy * ddy <= pr * pr:
                    b.on = False
                    b.vx = b.vy = 0
                    if b.kind == 'cue':
                        self.cue_potted = True
                    else:
                        self.potted.append(b)
                    break

    def pos_mm(self, b):
        return (to_mm(b.x), to_mm(b.y))

    def set_pos_mm(self, b, x, y):
        b.x = to_fx(x)
        b.y = to_fx(y)


def make_fixed_from(balls):
    """Build a FixedEngine whose balls are an independent Q8 copy of `balls`."""
    copy = []
    for b in balls:
        nb = Ball(b.kind, b.color, 0, 0, b.spot)
        nb.x = to_fx(b.x)
        nb.y = to_fx(b.y)
        nb.vx = 0            # integer velocities (Q8/tick) -- never float
        nb.vy = 0
        nb.on = b.on
        copy.append(nb)
    return FixedEngine(copy)


# --------------------------------------------------------------------------
# Snooker rules (run on the FloatEngine = authoritative game)
# --------------------------------------------------------------------------
class Rules:
    """Core snooker: ball-on, fouls, scoring, colour respots, frame end.

    Simplified (TODO for later): free ball, miss/play-again rule, exact
    'highest available spot' respot chain, nomination UI (here the nominated
    colour is inferred from first contact)."""

    def __init__(self):
        self.scores = [0, 0]
        self.turn = 0
        self.brk = 0                 # current visit break
        self.reds_left = 15
        self.expect_colour = False   # True when player is "on a colour" mid-reds
        self.frame_over = False
        self.message = 'Rozbitie - hrac 1'
        self.on_at_shot = None       # ('red'|'colour'|'seq', value)

    # --- which ball is legal to hit/pot right now ---
    def ball_on(self, engine):
        if self.reds_left > 0:
            return ('colour', None) if self.expect_colour else ('red', 1)
        for c in COLOUR_ORDER:
            if self._colour_on_table(engine, c):
                return ('seq', VALUE[c])
        return None

    def _colour_on_table(self, engine, color):
        for b in engine.balls:
            if b.color == color and b.on:
                return True
        return False

    def begin_shot(self, engine):
        self.on_at_shot = self.ball_on(engine)

    # --- evaluate the just-finished shot, mutate scores/state ---
    def resolve(self, engine):
        on = self.on_at_shot or self.ball_on(engine)
        fc = engine.first_contact
        potted = list(engine.potted)
        cue_potted = engine.cue_potted

        foul = False
        foul_val = 4
        msg = []

        # 1) first-contact legality
        if fc is None:
            foul = True; msg.append('ziadny kontakt')
        else:
            if on is None:
                pass
            elif on[0] == 'red':
                if fc.color != 'red':
                    foul = True; foul_val = max(foul_val, fc.value)
                    msg.append('najprv cervena')
            elif on[0] == 'colour':
                if fc.color == 'red':
                    foul = True; foul_val = max(foul_val, 4)
                    msg.append('najprv farba')
            elif on[0] == 'seq':
                if fc.value != on[1]:
                    foul = True; foul_val = max(foul_val, fc.value, on[1])
                    msg.append('zla farba')

        # 2) cue potted
        if cue_potted:
            foul = True; foul_val = max(foul_val, 4); msg.append('biela spadla')

        # 3) legality of potted object balls
        legal_pots = []
        for b in potted:
            ok = False
            if on is None:
                ok = False
            elif on[0] == 'red':
                ok = (b.color == 'red')
            elif on[0] == 'colour':
                ok = (b.color != 'red' and b is fc)   # nominated = first colour hit
            elif on[0] == 'seq':
                ok = (b.value == on[1])
            if ok:
                legal_pots.append(b)
            else:
                foul = True
                foul_val = max(foul_val, b.value, 4)
                msg.append(f'spadla {b.color}')

        if foul:
            self._apply_foul(engine, foul_val, potted, cue_potted)
            self.message = 'FAUL +%d sup.  (%s)' % (foul_val, ', '.join(msg))
        elif legal_pots:
            self._apply_pots(engine, on, legal_pots)
        else:
            self.message = 'bez pottu - vymena'
            self._end_turn()

        self._check_frame_over(engine)
        engine.reset_shot()

    def _apply_pots(self, engine, on, legal_pots):
        gained = 0
        for b in legal_pots:
            self.scores[self.turn] += b.value
            self.brk += b.value
            gained += b.value
            if b.color == 'red':
                b.on = False
                self.reds_left -= 1
            else:
                # colour: respot during the reds phase or the post-reds colour;
                # in the final sequence it stays down.
                if self.reds_left > 0 or on[0] == 'colour':
                    self._respot_colour(engine, b)
                else:
                    b.on = False
        if on[0] == 'red':
            self.expect_colour = True
        elif on[0] == 'colour':
            self.expect_colour = False
        self.message = '+%d  (break %d)' % (gained, self.brk)

    def _apply_foul(self, engine, foul_val, potted, cue_potted):
        self.scores[1 - self.turn] += foul_val
        # reds potted on a foul stay off; colours are respotted
        for b in potted:
            if b.color != 'red':
                self._respot_colour(engine, b)
            else:
                if b.on:
                    b.on = False
                    self.reds_left -= 1
        if cue_potted:
            self._respot_cue(engine)
        self._end_turn()

    def _end_turn(self):
        self.turn = 1 - self.turn
        self.brk = 0
        self.expect_colour = False

    # --- respotting ---
    def _free(self, engine, x, y, exclude):
        mind = (2 * BALL_R) ** 2
        for b in engine.balls:
            if b is exclude or not b.on:
                continue
            bx, by = engine.pos_mm(b)
            if (bx - x) ** 2 + (by - y) ** 2 < mind:
                return False
        return True

    def _respot_colour(self, engine, b):
        b.on = True
        b.vx = b.vy = 0
        b.fric = 0
        sx, sy = b.spot
        if self._free(engine, sx, sy, b):
            engine.set_pos_mm(b, sx, sy)
            return
        # own spot busy: try the other colour spots, highest value first
        for c in reversed(COLOUR_ORDER):
            cx, cy = SPOTS[c]
            if self._free(engine, cx, cy, b):
                engine.set_pos_mm(b, cx, cy)
                return
        # all busy: nudge toward the top cushion along its spot line
        x = sx
        while x < TABLE_L - BALL_R and not self._free(engine, x, sy, b):
            x += BALL_R
        engine.set_pos_mm(b, x, sy)

    def _respot_cue(self, engine):
        cue = engine.cue
        cue.on = True
        cue.vx = cue.vy = 0
        cue.fric = 0
        for cand in (CUE_START,
                     (BAULK_X - 100, TABLE_W / 2),
                     (BAULK_X - 180, TABLE_W / 2 + 120),
                     (BAULK_X - 60, TABLE_W / 2 - 120)):
            if self._free(engine, cand[0], cand[1], cue):
                engine.set_pos_mm(cue, cand[0], cand[1])
                return
        engine.set_pos_mm(cue, CUE_START[0], CUE_START[1])

    def _check_frame_over(self, engine):
        if self.reds_left == 0 and not self._colour_on_table(engine, 'black'):
            self.frame_over = True
            w = 0 if self.scores[0] > self.scores[1] else 1
            self.message = 'KONIEC - vyhral hrac %d (%d:%d)' % (
                w + 1, self.scores[0], self.scores[1])


# --------------------------------------------------------------------------
# Divergence metric: how far has the Atari math drifted from the PC truth?
# --------------------------------------------------------------------------
def table_furniture():
    """Faithful snooker table furniture in mm, shared by every renderer.

    Real openings (WPBSA): corner mouth 3.5" ~ 89 mm, middle mouth 4" ~ 102 mm
    (middles are WIDER).  The cushion ends are ROUNDED knuckles (jaws), not a
    straight bevel, and each pocket is a dark funnel cut into the corner / rail,
    not a leather ring.  Returns:
      cushions : 6 green rectangles (nose edge -> rail)
      knuckles : (x, y, r) green rounded cushion ends
      pockets  : dark opening polygons (the cut-out the ball drops through)
    """
    L, W = TABLE_L, TABLE_W
    CUSH_D = 68.0          # cushion depth (nose -> rail)
    CM = 90.0             # corner: the jaw meets the slate this far from the corner (WPBSA 2005/6)
    MH = 56.0             # middle: half-mouth (rot_ref: the hole circles cut the cushion ends)
    KR = CUSH_D * 0.5     # knuckle (rounded jaw) radius
    cush, knuck = [], []

    def seg(ax, ay, bx, by, ox, oy):
        cush.append([(ax, ay), (bx, by),
                     (bx + ox * CUSH_D, by + oy * CUSH_D),
                     (ax + ox * CUSH_D, ay + oy * CUSH_D)])
        knuck.append((ax + ox * KR, ay + oy * KR, KR))   # rounded ends
        knuck.append((bx + ox * KR, by + oy * KR, KR))

    seg(CM, 0, L / 2 - MH, 0, 0, -1)            # top rail (two segments)
    seg(L / 2 + MH, 0, L - CM, 0, 0, -1)
    seg(CM, W, L / 2 - MH, W, 0, 1)             # bottom rail
    seg(L / 2 + MH, W, L - CM, W, 0, 1)
    seg(0, CM, 0, W - CM, -1, 0)                # left short rail
    seg(L, CM, L, W - CM, 1, 0)                 # right short rail

    bk = 30.0             # how far the corner funnel reaches past the corner
    md = 40.0             # middle funnel depth into the rail
    pk = [
        [(CM, 0), (0, CM), (-bk, -bk)],                       # top-left
        [(L - CM, 0), (L, CM), (L + bk, -bk)],                # top-right
        [(CM, W), (0, W - CM), (-bk, W + bk)],                # bottom-left
        [(L - CM, W), (L, W - CM), (L + bk, W + bk)],         # bottom-right
        [(L/2 - MH, 0), (L/2 + MH, 0),
         (L/2 + MH*0.55, -md), (L/2 - MH*0.55, -md)],         # top middle
        [(L/2 - MH, W), (L/2 + MH, W),
         (L/2 + MH*0.55, W + md), (L/2 - MH*0.55, W + md)],   # bottom middle
    ]
    hc, hm = 36.0, 30.0      # rounded hole at the back of each pocket
    holes = [
        (-bk * 0.5, -bk * 0.5, hc), (L + bk * 0.5, -bk * 0.5, hc),
        (-bk * 0.5, W + bk * 0.5, hc), (L + bk * 0.5, W + bk * 0.5, hc),
        (L / 2, -md * 0.55, hm), (L / 2, W + md * 0.55, hm),
    ]
    return {'cushions': cush, 'knuckles': knuck, 'pockets': pk, 'holes': holes}


def table_faces_3d():
    """3D table geometry for the 2.5D view, built from the same furniture as
    the top-down so they always agree.  Returns layers:
      bed    : the cloth floor (one quad, z=0)
      darks  : pocket funnels + holes on the bed (z=0, drawn over the bed)
      raised : cushion walls/tops, wood rails, knuckles (z>0) -- painter-sorted
               together with the balls by the renderer.
    Each raised item is {'pts':[(x,y,z)...], 'color':key}."""
    fur = table_furniture()
    L, W = TABLE_L, TABLE_W
    H = 42.0          # cushion / rail top height
    RW = 150.0        # wood rail width beyond the cushion base
    bed = [(0, 0, 0), (L, 0, 0), (L, W, 0), (0, W, 0)]
    darks = [[(x, y, 0.0) for (x, y) in poly] for poly in fur['pockets']]
    for (hx, hy, hr) in fur['holes']:
        darks.append(circle_poly(hx, hy, hr, 0.0, 12))
    raised = []
    for seg in fur['cushions']:
        (nax, nay), (nbx, nby), (bbx, bby), (bax, bay) = seg
        ox, oy = bax - nax, bay - nay
        ol = math.hypot(ox, oy)
        ux, uy = ox / ol, oy / ol
        raised.append({'pts': [(nax, nay, 0), (nbx, nby, 0),
                               (nbx, nby, H), (nax, nay, H)], 'color': 'cushion'})
        raised.append({'pts': [(nax, nay, H), (nbx, nby, H),
                               (bbx, bby, H), (bax, bay, H)], 'color': 'cushtop'})
        rax, ray = bax + ux * RW, bay + uy * RW
        rbx, rby = bbx + ux * RW, bby + uy * RW
        raised.append({'pts': [(bax, bay, H), (bbx, bby, H),
                               (rbx, rby, H), (rax, ray, H)], 'color': 'rail'})
        raised.append({'pts': [(rax, ray, H), (rbx, rby, H),
                               (rbx, rby, 0), (rax, ray, 0)], 'color': 'railside'})
    for (kx, ky, kr) in fur['knuckles']:
        raised.append({'pts': circle_poly(kx, ky, kr, H, 10), 'color': 'cushtop'})
    return {'bed': bed, 'darks': darks, 'raised': raised, 'H': H}


def make_camera(w, h, margin=24):
    """A real 3D pinhole camera placed behind the baulk end and raised, looking
    up the table -- the proper way to do the 2.5D view (vs the flat trapezoid).
    Returns proj(x,y,z)->(sx,sy,depth); .scale and .H are attached.  Auto-fits
    the whole table (incl. rails) into the w*h panel so framing is robust."""
    H = 42.0                      # cushion / rail top height (mm)
    RW = 150.0                    # wood rail width beyond cushion
    eye = (-1550.0, TABLE_W / 2.0, 1780.0)
    tgt = (TABLE_L * 0.52, TABLE_W / 2.0, 0.0)
    fx, fy, fz = tgt[0] - eye[0], tgt[1] - eye[1], tgt[2] - eye[2]
    fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    f = (fx / fl, fy / fl, fz / fl)
    up = (0.0, 0.0, 1.0)
    rx = up[1]*f[2] - up[2]*f[1]   # r = up x f
    ry = up[2]*f[0] - up[0]*f[2]
    rz = up[0]*f[1] - up[1]*f[0]
    rl = math.sqrt(rx*rx + ry*ry + rz*rz)
    r = (rx/rl, ry/rl, rz/rl)
    u = (f[1]*r[2] - f[2]*r[1],    # u = f x r
         f[2]*r[0] - f[0]*r[2],
         f[0]*r[1] - f[1]*r[0])

    def cam(x, y, z):
        dx, dy, dz = x - eye[0], y - eye[1], z - eye[2]
        return (dx*r[0] + dy*r[1] + dz*r[2],
                dx*u[0] + dy*u[1] + dz*u[2],
                dx*f[0] + dy*f[1] + dz*f[2])

    ext = []
    for X in (-RW, TABLE_L + RW):
        for Y in (-RW, TABLE_W + RW):
            for Z in (0.0, H):
                cx, cy, cz = cam(X, Y, Z)
                cz = max(cz, 1.0)
                ext.append((cx / cz, cy / cz))
    nxs = [p[0] for p in ext]; nys = [p[1] for p in ext]
    s = min((w - 2*margin) / (max(nxs) - min(nxs)),
            (h - 2*margin) / (max(nys) - min(nys)))
    ox = (w - s * (max(nxs) + min(nxs))) / 2.0
    oy = (h + s * (max(nys) + min(nys))) / 2.0

    def proj(x, y, z):
        cx, cy, cz = cam(x, y, z)
        cz = max(cz, 1.0)
        return (ox + s * (cx / cz), oy - s * (cy / cz), cz)

    proj.scale = s
    proj.H = H
    proj.RW = RW
    return proj


def make_atari_persp(w, h, N=96):
    """The 2.5D ball projection AS THE 6502 WILL DO IT -- table-driven, no
    runtime float 3D.  Because the camera's forward/up have no y-component,
    the perspective is exactly a per-depth-row affine map: for a given depth x
    the screen row sy is constant and sx is LINEAR in y.  So we bake, per depth
    row i (x quantised into N bands): sy[i], centre cx[i], lateral slope[i]
    (px per mm, a fixed-point multiplier) and the discrete sprite size[i].

    Runtime per ball (all integer on 6502): i = x*N/L ; sx = cx[i] +
    slope[i]*(y - W/2) ; sy = sy[i] ; r = size[i].  The visible Atari artefacts
    are depth banding (N rows), integer screen pixels and a small set of sprite
    sizes -- exactly what the simulator should expose vs the PC float camera.
    Returns aproj(x,y)->(sx,sy,r); .proj is the float camera for the (baked,
    accurate) static table background."""
    proj = make_camera(w, h)
    rows = []
    for i in range(N):
        x = (i + 0.5) / N * TABLE_L
        cx, cy, cz = proj(x, TABLE_W / 2, BALL_R)
        px2, _, _ = proj(x, TABLE_W / 2 + 200.0, BALL_R)
        slope = (px2 - cx) / 200.0                  # px per mm of y (linear)
        size = max(2, int(round(proj.scale * BALL_R / cz)))
        rows.append((round(cx), round(cy), slope, size))

    def aproj(x, y):
        i = int(x / TABLE_L * N)
        i = 0 if i < 0 else (N - 1 if i >= N else i)
        cx, sy, slope, size = rows[i]
        sx = int(round(cx + slope * (y - TABLE_W / 2)))
        return sx, sy, size

    aproj.proj = proj
    aproj.rows = rows
    aproj.N = N
    return aproj


def circle_poly(cx, cy, r, z=0.0, n=12):
    return [(cx + r * math.cos(2*math.pi*i/n), cy + r * math.sin(2*math.pi*i/n), z)
            for i in range(n)]


def persp_project(x, y, w, h):
    """2.5D camera behind the baulk end looking up-table.  table mm -> (screen
    x, screen y, depth scale).  x is depth: 0 = baulk (near/big/bottom) ..
    TABLE_L = top cushion (far/small/top).  Shared by the GUI and the PNG
    renderer; on the 6502 this becomes a per-scanline scale LUT."""
    d = min(1.0, max(0.0, x / TABLE_L))
    sc = 1.0 / (1.0 + d)                  # 1.0 near .. 0.5 far
    f = 2.0 * d / (1.0 + d)               # vertical perspective compression
    top = h * 0.15
    bot = h * 0.93
    sy = bot - (bot - top) * f
    half = w * 0.46 * sc
    sx = w * 0.5 + (y / TABLE_W - 0.5) * 2.0 * half
    return sx, sy, sc


_BALL_NAMES = {0: 'cue', 16: 'yellow', 17: 'green', 18: 'brown',
               19: 'blue', 20: 'pink', 21: 'black'}


def ball_label(idx, color):
    return _BALL_NAMES.get(idx, color)


def coord_report_lines(fl, fx, mark_mm=20.0):
    """Per-ball PC vs ATARI coordinate table as a list of text lines.  Shared
    by the live GUI readout and the saved coords_N.txt so they never differ.
    A '<<' marks balls that drifted more than `mark_mm`."""
    lines = ['id  ball     PC x,y (mm)         ATARI x,y (mm)      diff',
             '-' * 60]
    for idx, (a, b) in enumerate(zip(fl.balls, fx.balls)):
        name = ball_label(idx, a.color)
        if a.on and b.on:
            ax, ay = fl.pos_mm(a)
            bx, by = fx.pos_mm(b)
            d = math.hypot(ax - bx, ay - by)
            mark = ' <<' if d > mark_mm else ''
            lines.append('%2d  %-7s (%7.1f,%7.1f)  (%7.1f,%7.1f) %6.1f%s'
                         % (idx, name, ax, ay, bx, by, d, mark))
        else:
            st = 'PC:%s ATARI:%s' % ('on' if a.on else 'POT',
                                     'on' if b.on else 'POT')
            lines.append('%2d  %-7s %s' % (idx, name, st))
    return lines


def divergence(fl, fx):
    """Max & mean centre distance (mm) over balls still on table in BOTH, plus
    a list of balls whose on/off state disagrees."""
    diffs = []
    mismatch = []
    for a, b in zip(fl.balls, fx.balls):
        if a.on and b.on:
            ax, ay = fl.pos_mm(a)
            bx, by = fx.pos_mm(b)
            diffs.append(math.hypot(ax - bx, ay - by))
        elif a.on != b.on:
            mismatch.append(a.color)
    mx = max(diffs) if diffs else 0.0
    mean = sum(diffs) / len(diffs) if diffs else 0.0
    return mx, mean, mismatch


# --------------------------------------------------------------------------
# Headless self-test
# --------------------------------------------------------------------------
def _selftest():
    print('=== ai-snooker core self-test ===')
    fl = FloatEngine(build_rack())
    fx = make_fixed_from(fl.balls)
    print(f'balls: {len(fl.balls)}  (1 cue + 15 reds + 6 colours)')
    print(f'fixed engine: {fx.substeps} substeps/frame -> {fx.ftps} ticks/s, '
          f'dec_hi={fx.dec_hi} (Q12<<8), stop={fx.stop_v} Q12, FX=Q{FX}, '
          f'angle steps={ANG_STEPS}')

    # aim cue at the red pack and fire a hard break
    cx, cy = fl.cue.x, fl.cue.y
    px, py = SPOTS['pink']
    ang = math.atan2(py - cy, px - cx)
    units = int(round(ang / (2 * math.pi) * ANG_STEPS)) & (ANG_STEPS - 1)
    fl.shoot(ang, 0.95)
    fx.shoot(units, 0.95)
    print(f'break shot: angle={math.degrees(ang):.1f} deg  (angle unit {units})')

    dt = 1.0 / 60.0
    frames = 0
    while (fl.moving() or fx.moving()) and frames < 4000:
        fl.step(dt)
        fx.step(dt)
        frames += 1
    mx, mean, mismatch = divergence(fl, fx)
    print(f'came to rest after {frames} frames ({frames/60:.1f}s sim time)')
    print(f'float potted: {[b.color for b in fl.potted]}  cue_potted={fl.cue_potted}')
    print(f'fixed potted: {[b.color for b in fx.potted]}  cue_potted={fx.cue_potted}')
    print(f'divergence vs PC truth: max={mx:.1f} mm  mean={mean:.1f} mm'
          f'  (1 ball = {BALL_D} mm)')
    if mismatch:
        print(f'  on/off disagreement on: {mismatch}')

    assert not fl.moving(), 'float engine never came to rest!'
    assert not fx.moving(), 'fixed engine never came to rest!'
    for b in fl.balls:
        if b.on:
            assert -1 <= b.x <= TABLE_L + 1 and -1 <= b.y <= TABLE_W + 1, \
                f'{b.color} escaped the table at ({b.x:.0f},{b.y:.0f})'
    print('OK: both engines stable, balls contained, came to rest.')

    # quick rules smoke test
    r = Rules()
    fl2 = FloatEngine(build_rack())
    r.begin_shot(fl2)
    print(f'ball-on at break: {r.ball_on(fl2)}')
    print('=== self-test passed ===')


if __name__ == '__main__':
    _selftest()
