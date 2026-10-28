; defs.inc -- constants, VBXE register offsets, zero-page and page-6/7
; memory map shared by all modules (icl'd first from main.asm).

VIDEO_CONTROL = $40
FEATURE_CONTROL = $4B
XDL_ADR0 = $41
XDL_ADR1 = $42
XDL_ADR2 = $43
CSEL = $44
PSEL = $45
CR = $46
CG = $47
CB = $48
BL_ADR0 = $50
BL_ADR1 = $51
BL_ADR2 = $52
BLITTER_START = $53
MA_CTL = $5E
MA_BSEL = $5F
WINDOW = $3000
CH    = $02FC         ; OS: last key pressed ($FF = none)
SDMCTL = $022F        ; OS shadow of DMACTL
RTCLOK = $12          ; (3) OS frame counter, $14 = low byte
STICK0 = $0278        ; OS shadows the game reads (vbi fills them)
STRIG0 = $0284
KEYDEL = $02F1        ; OS keyboard debounce (the keyboard IRQ sets it)
PORTA = $D300
PORTB = $D301         ; XL/XE memory control: bit 1 = 1 -> BASIC ROM off
BASICF = $03F8        ; OS: 1 = BASIC stays off after RESET
TRIG0 = $D010
DMACTL = $D400        ; ANTIC DMA control (0 = no playfield / P-M fetch)
IDX_POW = 13          ; the power share of the aim line: the blue ball's colour (vbxe_export IDX)
HUD_VRAM = $074400    ; the HUD's 3 text lines x 160 (vbxe.asm, hud.asm), after the menu sound's AUDC tables; its font: hud.inc
    icl '../build/assets/hud.inc'
IDX_LINE = 7          ; palette index of the table markings (vbxe_export IDX):
                      ; the aim line is drawn in it, so it is always the same
                      ; white as the baulk line whatever the ball shades do

; Ball-cloth friction, measured on a snooker table (Mathavan, Jackson, Parkin,
; Am. J. Phys. 77, 788 (2009)): ROLLING 0.124-0.126 m/s^2, SLIDING 1.75-2.40
; m/s^2 (mu_s 0.212 avg, also Proc. IMechE C 224 (2010)).  A struck ball slides
; (v and the spin velocity u = R w differ) until u = v, then rolls.
; Q20 per tick: X_MM_S2 * 4096 * 256 / 200^2.
DEC_HI = 3277         ; rolling: 125 mm/s^2
DEC_S = 54522         ; sliding: 0.212 * 9.81 = 2080 mm/s^2
SLIP_DEC = 745        ; |s| = |v - u| shrinks by 3.5 * DEC_S a tick (Q12: /256)
STOP_V = 164          ; STOP_SPEED*ONE/ftps  (Q12/tick)

; --- zero page ---
VB    = $80
src   = $82
wptr  = $84
bx    = $86           ; (3) cue table x, Q12 mm
by    = $89           ; (3) cue table y
sx    = $93           ; (2) projected screen x
syv   = $95
dsz   = $96
spadr = $97           ; (3)
osx   = $9A           ; (2) previous drawn screen x
osy   = $9C
od    = $9D
off0  = $9E
off1  = $9F
off2  = $A0
rtx   = $A1           ; (3) rewind / ovl: the d tried (zero page: read every halving)
p0    = $A4
p1    = $A5
p2    = $A6
dyneg = $A7
sizev = $A8
sgn   = $A9
; rack drawing (init only)
va    = $AB           ; (3)
rb    = $AE           ; (3)
spr   = $B1           ; (2)
rackp = $B3           ; (2)
rtmp  = $B5
rtmp2 = $B6
rrow  = $B7
ballcnt = $B8
; new-position save (this frame's projection, used after erase)
nsx   = $BA           ; (2)
nsyv  = $BC
nd    = $BD
nspadr = $BE          ; (3)
bp    = $C4           ; (2) pointer to the current ball's record
bi    = $C6           ; (1) current ball index
sptmp = $C7           ; (3) friction speed scratch
fmpl  = $CB           ; (1) fmulu 8x8 product low
fmph  = $CC           ; (1) fmulu 8x8 product high
aimang = $CD          ; (2) aim angle 0..1023 (joystick)
aptr  = $CF           ; (2) pointer into coslut
amul  = $D1           ; (2) angle*3 scratch
ang2  = $D3           ; (2) angle arg for cosptr
sprbank = $D5         ; (1) VRAM bank high byte of the current object's sprite set
dirx  = $D7           ; (3) aim direction x (cos, Q16 signed; 0 while balls move)
diry  = $DA           ; (3) aim direction y (sin, Q16 signed)
; --- OPT additions (zero page $DD-$FF was free) ------------------------------
laccx = $DD           ; (3) aim-line DDA x accumulator, Q8 (page 6 copy unused)
laccy = $E0           ; (2) DDA y accumulator, Q8 (rows 0..239 fit 16 bits)
lstepx = $E2          ; (3 signed) DDA x step, Q8
lstepy = $E5          ; (2 signed) DDA y step, Q8 (low 16 bits of the 3-byte value)
                      ; ($E7: free -- line_dda's end index is its cpx # operands)
lidx  = $E8           ; (1) index into the drawn-pixel buffers (lbuf_*)
                      ; ($E9: free -- the last MA_BSEL is the cmp # operand in line_dda / erase_line)
moving = $EA          ; (1) any_moving result for this frame (aim_update reads it)
cxh   = $EB           ; (1) collide: x high byte of ball ci
cyl   = $EC           ; (1) collide: y high byte of ball ci, minus 4
syvh  = $ED           ; (1) project: syv's high byte (the sprite row is 16-bit signed)

; --- math scratch (page 6) ---
; OPT: the math scratch lives in ZERO PAGE (every RMW shift 5 instead of 6
; cycles, every load/store 3 instead of 4 -- mul48/div24/isqrt48 are shift and
; add ladders).  $AB-$B9 held the removed rack-drawing scratch, $EE-$FF was free.
mP    = $AB           ; (6) product / sP
mtmp  = $B1           ; (4) div/sqrt scratch (isqrt48: u = 4*root)
root  = $B5           ; (3) isqrt48 result
bits  = $B8           ; (1) isqrt48: input byte being consumed
mA    = $EE           ; (6) multiplicand / 48-bit dividend
mB    = $F4           ; (3) multiplier / divisor
mrem  = $F7           ; (4) remainder
mQ    = $FB           ; (3) quotient
spv   = $0644
nsv   = $0647
fv    = $064D

; --- ball arrays: struct-of-arrays, 22 entries each at stride 32 -----------
; Every field is its own page-aligned array indexed by the ball number in X
; (48Balls' layout): each access is one `lda ARR,x`, 4 cycles, never a page
; cross, no (ptr),y and no per-ball pointer maths.  $1000-$13BF.
; Physics model: tools/phys_ref.py (byte-exact spec, tools/phys_check.py gate).
NB    = 22            ; number of physics balls (cue + 15 reds + 6 colours)
NTOT  = NB            ; blitter-drawn objects (balls only; the aim line is pixel-plotted)
ASTART = $0040        ; aim speed when left/right is pressed: 1/4 unit a frame
ARAMP = $10           ; ... + 1/16 unit a frame per frame held
AMAX  = $0400         ; ... up to 4 units a frame (1024 units = 360 deg)
AFINE = $10           ; up/down: 1/16 unit a frame (0.02 deg)
X0    = $1000         ; position x, Q12 mm, 24-bit unsigned (lo, mid, hi)
X1    = $1020
X2    = $1040
Y0    = $1060         ; position y
Y1    = $1080
Y2    = $10A0
VXF   = $10C0         ; velocity x, Q20 signed 32-bit: fraction byte, then the
VX0   = $10E0         ;   Q12 part (VX0..VX2 = the 24-bit signed Q12 velocity)
VX1   = $1100
VX2   = $1120
VYF   = $1140         ; velocity y
VY0   = $1160
VY1   = $1180
VY2   = $11A0
AXF   = $11C0         ; deceleration x, Q20 signed 32-bit = DEC * v/|v| (v -= a per tick)
AX0   = $11E0
AX1   = $1200
AX2   = $1220
AYF   = $1240         ; deceleration y
AY0   = $1260
AY1   = $1280
AY2   = $12A0
SP0   = $12C0         ; speed scalar |v|, Q12 24-bit (stop test; -= dec per tick)
SP1   = $12E0
SP2   = $1300
FRIC  = $1320         ; (1) 8 extra fractional bits of the sp decrement
BON   = $1340         ; (1) 1 = on the table, 0 = potted (skip physics + draw)
SHOWN = $1360         ; (1) 1 = drawn last frame (erase it exactly once)
BANK  = $1380         ; (1) sprite VRAM bank high byte ($10 cue .. $80 black)
AWK   = $13A0         ; (1) 1 = awake (sp != 0): the only balls the tick touches
DIRTY = $13E0         ; (1) 1 = moved since its last projection (tick/pot/respot):
                      ;     project_balls skips the others (NEWS still exact)
NEEDRN = $13C0        ; (1) 1 = velocity changed this tick (cushion/collision):
                      ;     renorm runs ONCE per ball at the end of the tick
NEWS  = $1400         ; stride 8, 22 recs -> $1400-$14AF: this frame's sprite rectangle,
                      ;   clipped to the screen: x (2), stored row, w (0 = not drawn), h,
                      ;   source (2), pitch -- the rectangle holds the ball AND its shadow (h)
; [2026-10-21 6502-idioms/SKILL.md: SoA by ball index -- the shadow's fields]
NBH   = $14B0         ; (22) the ball's own rows in the NEWS rectangle (0: only its shadow)
NSL   = $14C6         ; (22) the shadow mask's source (clipped), lo
NSH   = $14DC         ; (22)   hi (VRAM bank 0)
shm   = $14F2         ; (2) gstore: the ball's shadow mask ($14B0-$14F3)
UX0   = $1750         ; spin velocity u = R w (Q12, 24-bit signed, per axis):
UX1   = $1766         ;   valid at a renorm only -- set by a cushion / the end
UX2   = $177C         ;   of a slide (u = v), a collision (spin kept), the cue
UY0   = $1792         ;   (u = 0); renorm slides while |v - u| > 0
UY1   = $17A8
UY2   = $17BE         ; ($1750-$17D3)
SLP0  = $1F78         ; |slip| Q12, 0 = rolling; counts down by SLIP_DEC a tick
SLP1  = $1F8E
SLP2  = $1FA4         ; ($1F78-$1FB9)
; the shot record (physics) and the rules' state (rules.asm), $1FBA-$1FE7
fcon  = $1FBA         ; (1) the first ball the cue hit this shot ($FF: none)
potn  = $1FBB         ; (1) balls potted this shot
potl  = $1FBC         ; (22) their ids, in pot order
cuein = $1FD2         ; (1) the cue went down this shot
rstate = $1FD3        ; ---- rules_init clears from here
sclo  = $1FD3         ; (2) the players' scores, lo
schi  = $1FD5         ; (2)   hi
turn  = $1FD7         ; (1) the player to play (0 / 1)
brk   = $1FD8         ; (1) the current break
hbrk  = $1FD9         ; (1) the highest break
redsl = $1FDA         ; (1) reds left on the table
expcol = $1FDB        ; (1) 1 = on a colour (a red was potted)
fover = $1FDC         ; (1) 1 = the frame is over
msgc  = $1FDD         ; (1) what the last shot did (M_*), msgv its value
msgv  = $1FDE
rstate_len = $1FDF-rstate
onk   = $1FDF         ; (1) the ball on at the shot: 0 red, 1 colour, 2 sequence
onv   = $1FE0         ; (1)   its value (a colour: named by the first colour hit)
foul  = $1FE1         ; (1) fouls counted in rules_end
pen   = $1FE2         ; (1) the penalty
rid   = $1FE3         ; (1) respot / free: the ball placed
rj    = $1FE4         ; (1) a loop index across calls
r7    = $1FE5         ; (1) spotxy: 7 x
rbx   = $1FE6         ; (3) a place being tried, Q12 (rbx, rby adjacent: spotxy)
rby   = $1FE9         ; (3)
n3u   = $1FEC         ; (1) hud num3: the units, the tens
n3t   = $1FED
n3c   = $1FEE         ;   the column
hcolr = $1FEF         ; (1) hud: hfill's attribute
fw    = $1FF0         ; (2) frames won (the match)
fwait = $1FF2         ; (1) the frame is over: 0 wait for fire, 1 for its release
brkr  = $1FF3         ; (1) who breaks off this frame
inhand = $1FF4        ; (1) the cue is in hand: the stick moves it in the D, fire puts it down
hwait = $1FF5         ; (1)   fire pressed, waiting for its release
dtmp  = $1FF6         ; (3)   d_test / to2mm scratch
fchoice = $1FF9       ; (1) a foul: the next player may make the offender play again
cent  = $1FFA         ; (1) not 0: this shot made the break a century -- the "100" next frame (century.asm)  
rk    = $1FFB         ; (1) free's ball index (rules.asm; rj is its callers')
; [2026-10-28 the shot clock and fd_last moved to $1E36-$1E3A (the renderer's page): page $1F and
;  $06 are what simshot.asm scopy saves and puts back around every sim -- the computer's
;  thinking clock (hud.asm thkclk, the VBI) went back with them and never reached 30 s]
tsub  = $1E36         ; (1) the shot clock (hud.asm shot_clock): VBLANKs into the second,
tsu   = $1E37         ; (1)   the seconds' units, tens,
tst   = $1E38         ; (1)
tmin  = $1E39         ; (1)   minutes of a human's thinking (> 0 or tst >= 3: SHOT TIME shown)  ($1FBA-$1FFB)
; the snooker test, free ball, foul and a miss (rules.asm), in the RAM under BASIC
SPOS  = $0500         ; ($C0) X0..Y2 as the cue is struck (the six arrays $1000-$10BF)
SBON  = $05C0         ; (22)  BON then (page 5: free RAM, no game cell in it)
RV    = $043B         ; (87, to $0491: the free gap between vpg $043A and rcm $04B0)
sred  = RV            ; (1) redsl then
sexp  = RV+1          ; (1) expcol then
fball = RV+2          ; (1) 1 = a free ball for the next shot
fbs   = RV+3          ; (1) this shot is a free ball
fbid  = RV+4          ; (1) the free ball (the first ball hit, not on); $FF none
mcnt  = RV+5          ; (1) misses in a row, the balls replaced between them
rpl   = RV+6          ; (1) 1 = the balls were replaced: the offender plays again
missf = RV+7          ; (1) 1 = the last foul was a miss (SHIFT + up replaces)
edx   = RV+8          ; (2) edges: ball - cue, Q2 mm signed (edy right after: X = 0 / 2)
edy   = RV+10         ; (2)
el2   = RV+12         ; (4) L^2
ec    = RV+16         ; (2) sqrt(L^2 - r^2)
enum  = mA            ; (4) a direction's numerator, signed (the math cells: zero page
erem  = mrem          ; (3) ediv: the trial remainder              with OPT; no mul48 /
eq    = mQ            ; (3) ediv: the quotient                     div24 in between)
ediv_d = mtmp         ; (4) ediv: L^2 (isqrt48 clobbers mtmp between the sides)
ebal  = RV+29         ; (1) the ball tested
es    = RV+30         ; (1) its side (0 / 1)
esn   = RV+31         ; (1) snooker: the ball index
fbval = RV+32         ; (1) the free ball's points
cx0   = RV+33         ; (2) corr: the line's box widened by 4R, Q4 mm (X2:X1)
cx1   = RV+35         ; (2)
cy0   = RV+37         ; (2)
cy1   = RV+39         ; (2)
epr   = RV+41         ; (16) edges: dx c, dy r, dy c, dx r (4 bytes each, signed)
apx   = RV+57         ; (2) aim_play: the target, Q4 mm (X2:X1)
apy   = RV+59         ; (2)
abd   = RV+61         ; (2)   the nearest ball on's (|dx| + |dy|) / 2 so far
apvx  = RV+63         ; (3)   target - cue, Q4 signed
apvy  = RV+66         ; (3)
alo   = RV+69         ; (2)   the angle search's lower end
astp  = RV+71         ; (1)   its step
acr   = RV+72         ; (3)   cross: cos(m) vy
ewant = RV+75         ; (1) snooker: 1 = also find a ball on in part sight (spart)
eclr  = RV+76         ; (1) edges: bit 0 / 1 = side 0 / 1 free
spart = RV+77         ; (1) snooker: 1 = some part of a ball on is in sight
ssc   = RV+78         ; (4) the scores at the stroke (sclo, sclo+1, schi, schi+1)
wsc   = RV+82         ; (4) needs: the scores it judges
nrem  = RV+86         ; (1) needs: the points left
OLDS  = $0D00         ; stride 8, 22 recs -> $0D00-$0DAF: the drawn rectangle (x, row, w, h)

; --- collision scratch (page 6, after fv) --------------------------------
adx   = $6B           ; (3) |dx|  (zero page: collide's hottest cells, $6B-$73 untouched by any code)
ady   = $6E           ; (3) |dy|
sgnx  = $71           ; (1) sign of dx (0/1)
sgny  = $72           ; (1)
rty   = $58           ; (3) rewind / ovl: the d tried, y ($58-$5A untouched by any code)
cnx   = $0661         ; (3 signed) unit normal x, Q16
cny   = $0664         ; (3 signed)
sA    = $0670         ; (3 signed) smul3 input A
sB    = $0673         ; (3 signed) smul3 input B
sP    = mP            ; (6 signed) smul3 result IS the mul48 product: no copy.
                      ; Every consumer reads sP right after smul3/rsh16, before
                      ; the next mul48/isqrt48 -- verified (see smul3 comment).
csgn  = $0682         ; (1) smul3 combined sign
cacc  = $0683         ; (6) dot-product accumulator
; --- all-pairs collide + pocket loop scratch (page 6, after cacc) ---------
pky   = $068A         ; (1) pocket_test: offset of the current pocket record
; narrow: the first contact of a ball's sweep (collide), for a second one in the
; same tick -- both struck at once, their impulses solved together (narrow.two)
fcj   = $73           ; (1) its j: $FF none yet, $FE the two solved (later ones alone)
fnx   = $0493         ; (3) its |nx|, |ny| (Q16), their signs, its closing speed a1 (Q12)
fny   = $0496         ; (3)
fsx   = $0499         ; (1)
fsy   = $049A         ; (1)
fa    = $049B         ; (3)
cc    = $049E         ; (3 signed) n1 . n2 (Q16)
cden  = $04A1         ; (3) 4 - cc^2 (Q16)
cj1   = $04A4         ; (3 signed) J1 - a1: the first contact's correction (Q12)
fft   = $04A7         ; (1) the first contact's time back in the tick (rewind's rft)
wiv   = $04A8         ; (6) narrow: i's velocity for dotv (MV, or the current one)
fj1   = $04AE         ; (1) the first contact's ball (fcj holds it too till it turns into $FE / $FD)
ci    = $90           ; (1) collide: current awake ball index i
d2b   = $BE           ; (5) calc_d2: the second square ($BE-$C2: nspadr + vv, not live then)
nt    = $B9           ; (1) narrow: lower-bound scratch
sqx   = $BD           ; (1) isqrt48: next byte index after the top 16 bits
bdirty = $92          ; (1) NEWS changed since the last ball redraw (main)
cj    = $91           ; (1) collide: inner ball index j
; collide ball pointers reuse zero page bp ($C4)=ball i, src ($82)=ball j
; (both free during the collide pass; math primitives never touch them).
; pocket_test reuses src ($82) as the pocket-table walk pointer.
; --- collide awake-list scratch (page 6, after the aim-line block) --------
awklist = $06C3       ; (22) indices of awake balls (sp != 0), rebuilt per call
awkn  = $8C           ; (1) number of awake balls in awklist
awki  = $8D           ; (1) outer cursor into awklist
tmpidx = $06DB        ; (1) ball index while building awklist
pacopy = $06DC        ; (2) saved record addr of the current awake ball (ci)
; --- shot power (charge while FIRE held) ---------------------------------
pwr      = $06DE      ; (3) charged shot speed, Q12 (sp to apply); 0 when idle
charging = $06E1      ; (1) 1 = FIRE held, power charging
linelen  = $06E2      ; (3) current aim-line length, Q12 mm = LINELEN + power
; shot speeds: "0.28-3.5 m/s, the typical range of ball velocities in the game"
; (Mathavan et al. 2009); Q12 mm per tick = m/s * 5 * 4096
PWR_MIN  = $001666    ; 0.28 m/s (1.4 mm/tick) -- a quick tap
PWR_MAX  = $019000    ; 5.0 m/s (25 mm/tick): two balls head-on at it close 50 mm a tick,
                      ;   under a ball's width -- none passes through another (narrow)
PWR_DELTA = $0809     ; MIN -> MAX in 47 frames (~1 s held)
; (base aim-line length 600mm = $258000 is inlined in calc_linelen)

; --- aim line (vector, pixel-plotted) scratch (page 6) -------------------
lx0   = $0690         ; (2) line start screen x (cue)
ly0   = $0692         ; (1) line start screen y
lex   = $0693         ; (2) current end x (set per draw/erase)
ley   = $0695         ; (1) current end y
nlx1  = $0696         ; (2) new far-end x
nly1  = $0698         ; (1) new far-end y
olx1  = $0699         ; (2) old far-end x (to erase)
oly1  = $069B         ; (1) old far-end y
lshown = $069C        ; (1) line was drawn last frame
pmode = $069D         ; (1) plot_px mode: 0 = white, 1 = restore clean bg
lsteps = $069E        ; (1) DDA step count
ldxv  = $06AC         ; (2) |dx|
ldyv  = $06AE         ; (2) |dy|
lsgnx = $06B0         ; (1) sign of dx
lsgny = $06B1         ; (1) sign of dy
aiming = $06B2        ; (1) 1 = balls at rest, aim line active
bcx   = $06B3         ; (2) current plot pixel x
bcy   = $06B5         ; (1) current plot pixel y
lsame = $06B6         ; (1) idle frame: nothing on screen changed -> skip redraw
lsx   = $06B7         ; (3 signed) aim-line step x = (LINELEN*dirx)>>16, Q12
lsy   = $06BA         ; (3 signed) aim-line step y
ltx   = $06BD         ; (3) ray param to the x rail, Q16 ($010000 = full length)
lty   = $06C0         ; (3) ray param to the y rail

; --- OPT: aim-line erase replay + projection cache flags (page 6 tail) -------
projvalid = $06E5     ; (1) NEWS is up to date: no tick ran since project_balls
osteps = $06E6        ; (1) drawn line's pixel count-1 (lsteps) for the erase replay
si    = $06E7         ; (1) collide sort cursor
key   = $06E8         ; (1) collide sort: X2 of the ball being inserted
cur   = $06E9         ; (1) collide sort: the ball being inserted
; --- the frame's VBLANKs (main), fdiv (hud.asm), page 6 tail ($06EC-$06EE, $06F2-$06F6 free) ---
dskip = $06EA         ; (1) bit 7: the D is behind the camera this frame (dtest)
fd_last = $1E3A       ; (1) RTCLOK at the last frame (out of scopy's pages: thkclk sets it)
fd_dv = $06EF         ; (1) fdiv divisor
fd_q  = $06F0         ; (2) fdiv dividend / quotient
cbuf  = $06F7         ; (6) cosptr: cos(a), cos(a + 1)
sv    = $04F8         ; (6) renorm: the vector it normalises (s = v - u, or v)
sgu   = $04FE         ; (1) spin_u: sign of the a component
fd_dt = $06FD         ; (1) VBLANKs the last frame took (main)
tacc  = $06FE         ; (1) physics ticks owed, in thirds of a tick (main)
PAL   = $D014         ; GTIA: PAL flags (bits 1-3 = 0 on PAL)
kdn   = $8E           ; (1) collide sweep cursor (downward)
kup   = $8F           ; (1) collide sweep cursor (upward)
ord   = $0701         ; (22) ball indices sorted by X2 (persistent; $0701: chk's ord-1,y stays in page 7)
opos  = $0717         ; (22) inverse of ord
; --- view (view.asm), page 7 ---------------------------------------------
lpf   = $00         ; (1) the charged power, 0..255 (calc_linelen; 0 when not charging)
opf   = $01         ; (1) the power share the drawn aim line shows
                    ; ($02: free -- line_dda's blue share is its cpx # operand)
lpfd  = $03         ; (1) line_dda: the power share of THIS line (draw_line)
lgh   = $04         ; (1) line_calc: the cue's line ends at a ball (ghost ball)
lob   = $05         ; (1) the hit ball's line is shown
ghj   = $06         ; (1) the ball hit
gjx   = $77         ; (1) ghost: the ball looked at
gtry  = $07         ; (1) objline: halvings left
ox0   = $07A8         ; (2) the hit ball's line on screen: start x, y, end x, y
oy0   = $07AA
ox1   = $07AB         ; (2)
oy1   = $07AD
gbest = $07AE         ; (3) ghost: the nearest contact so far, Q8 mm along the aim
gdx   = $22         ; (3) ghost: (ball - cue) >> 4, Q8 signed
gdy   = $25         ; (3)
gpp   = $28         ; (3) ghost: |perp|
gal   = $2B         ; (3) ghost: along, then tc
ggx   = $74         ; (3) the cue line's far end G (Q12)
ggy   = $07C0         ; (3)
gvx   = $07C3         ; (3) objline: the hit ball's step (Q12 signed)
gvy   = $07C6         ; (3)
dlob  = $07D1         ; (1) the hit ball's line as drawn: shown, end x (2), end y
dox1  = $07D2
doy1  = $07D4
aiact = $07D6         ; (1) 1: the computer plays -- the VBI leaves STICK0 / STRIG0 to ai.asm
aist  = $07D7         ; (1) the computer's shot stage (aiv.asm ai_run)
CU_BANK = $07         ; V:$007000: the cushion impact model (cushion.asm), 4 KB through MEMAC-A -- between the ball sheets ($01-$06) and the sounds ($08); NOT $0D-$0F, $3F-$43, $4C-$4D: the menu saves the picture under its windows there (menu.asm msave)
AI2_BANK = $4B        ; V:$04B000: the computer player's second code bank (ai2.asm), at $5000 in its 16 KB window
AI_BANK = $48         ; V:$048000: the computer player's code (aiv.asm), run through MEMAC-A
AI3_BANK = $4A        ; V:$04A000: the computer player position play (aipos.asm: the leave score, the cannon), at $4000 in its 16 KB window
wcue  = $07D8         ; (2) the cue ball's side spin as struck, R wz Q9 (cushion.asm)
wnew  = $07DA         ; (1) 1: a new shot -- cu_go clears the side spins, the cue's = wcue
tipm  = $07DB         ; (1) 1: SPACE held -- the stick moves the tip on the cue ball (tip_input)
tipl  = $07DC         ; (1) the stick as it was (a move on a change, then repeated)
tipt  = $07DD         ; (1) frames to the repeat
simon = $07E3         ; (1) $80: sim_shot runs a shot in the physics alone (no sound)
tick16 = $07E4        ; (2) physics ticks so far (tick_all): the side spin's clock
thk   = $07E6         ; (1) 1: THINKING is in the HUD (ai_input puts the name back)
pty   = $07E7         ; (2) the players (menu.asm): P1, P2 -- 0 a human, 1..5 a computer player
opp   = pty+1         ; (1) P2's (0 = a human: P2), weakest first
aip   = $07E9         ; (1) the computer at the table (ai_input): its profile, 1..5
pcam  = $07EA         ; (1) 1: the pocket camera shown this shot (pcam_frame; cam_rest clears it)
gx0   = $07C9         ; (2) gbox: the segment's box, Q4 mm (X2:X1)
gx1   = $07CB         ; (2)
gy0   = $07CD         ; (2)
gy1   = $07CF         ; (2)  ($07A8-$07D0)
BDUL  = $0750         ; (22 each) project_balls' cache: du, dv (Q3) of each ball, valid while
BDUH  = $0766         ;   it has not moved since (DIRTY bit 0 clear)
BDVL  = $077C
BDVH  = $0792         ; ($0750-$07A7)
pivx  = $0739         ; (3) the pivot: the cue ball's position when the view was set, Q12
pivy  = $073C         ; (3)
wasmov = $073F        ; (1) `moving` of the previous frame (the rest edge recentres)
vbank = $0740         ; (1) the VRAM loader's bank (vram_chunk / vram_next, while the XEX loads)
fidle = $0741         ; (1) aim_follow: frames the stick has rested with the view off the aim
lcx   = $0742         ; (2) pcen: a point's centre on the screen, x
lcy   = $0744         ; (1)   and row (0..239)
lcut  = $0745         ; (1) line_calc: the cue is off the screen (the line starts at the edge)
cmode = $0747         ; (1) the camera (key C): 0 behind the cue, 1 low over it, 2 at the target, 3 from above
novbl = $0749         ; (1) set_angle redrew the screen: the next frame draws without the VBL wait
pfar  = $0746       ; (1) aim_follow: the pivot is off D (the cue, or zoomed in, the line's end)
VCX_L = $00           ; table centre x, Q12: $6F8800 = 1784.5 mm
VCX_M = $88
VCX_H = $6F
VCY_L = $00           ; table centre y, Q12: $379000 = 889 mm (rot_ref CYQ)
VCY_M = $90
VCY_H = $37
vbuf      = $1C00     ; (the loader stages $2000-$2FFF while the XEX loads)
; --- drawn aim-line pixel buffers ($1800-$1BFF free CPU RAM) -----------------
lbuf_lo = $1800       ; (256) window address lo of each drawn pixel
lbuf_hi = $1900       ; (256) window address hi ($30-$3F)
lbuf_sel = $1A00      ; (256) MA_BSEL of the VISIBLE bank of each pixel ($B0+bank)
lbuf_px = $1B00       ; (256) pixel under each line pixel (save-under for the erase)
; --- SoA physics scratch -----------------------------------------------------
ri    = $C4           ; (1) renorm: saved ball index (mul48/div/isqrt clobber X)
tix   = $C5           ; (1) pocket_test: saved ball index
avx   = $C7           ; (3) renorm: |vx| Q12
avy   = $BA           ; (3) renorm: |vy| Q12  (nsx/nsyv, unused)


; --- the table renderer (table3d.asm) -------------------------------------
rang  = $FE           ; (2) table angle 0..1023
; render-only scratch: physics / ball-projection cells, never live meanwhile
rq0   = $BA
rq1   = $BB
rti   = $BC
rxa   = $BD           ; (3) chain A x, Q8 (+0.5)
rma   = $C0           ; (3) chain A step per row
rxb   = $C3           ; (3)
rmb   = $C6           ; (3)
rptr  = $C9           ; (2)
rpm   = $CB           ; (1) rot_project: m's high byte (fmpl: idle then)
; the clipper (before rfill: the chain cells are free)
cva   = $BD           ; (1) vertex a
cvb   = $BE           ; (1) vertex b
cvn   = $BF           ; (1) vertices in set A
cvo   = $C0           ; (1) vertices written to set B
ckp   = $C1           ; (1) 0: keep c >= cp ; $80: keep c <= cp
cp    = $C2           ; (3) the plane
cds   = $C5           ; (1) the sign of the lerp's difference / a cull factor
pa    = $C6           ; (3) the lerp's signed addend
cxo   = $C9           ; (1) 1 = a vertex is off the screen's x range
SCR_OFF = $100        ; the screen buffers start at $xx0100 (main: mk_tables)
CLN_BK = $06          ; the clean buffer's VRAM bank: V:$060000 (rot_draw draws there)
ROW_BIAS = 8          ; stored row = screen row + 8 (rows 0..7, 248..255 = junk rows)
ymlo  = $0800         ; stored row -> VRAM offset (row - 8) * 320 + SCR_OFF, lo / mid / hi
ymmid = $0900         ;   (the junk rows 0..7, 248..255 map past the buffer's end, bank + 1)
ymhi  = $0A00
ymmid1 = $0F00        ; ymmid - 1: rfill's chains hold x + 255 (never below 0), the +1 is the width's carry
shr4  = $0B00         ; i >> 4
ROT_LUT = $2000       ; 16 pages: the depth LUTs of levels 0, 1 + the 4 disc class tables (zoom_set)
rl0_lo = ROT_LUT      ; per level: ROW lo / hi (Q4, +128 bias), DR, K lo / hi, DK
rl0_hi = ROT_LUT+$100
rd0    = ROT_LUT+$200
rk0_lo = ROT_LUT+$300
rk0_hi = ROT_LUT+$400
rdk0   = ROT_LUT+$500
rl1_lo = ROT_LUT+$600
rl1_hi = ROT_LUT+$700
rd1    = ROT_LUT+$800
rk1_lo = ROT_LUT+$900
rk1_hi = ROT_LUT+$A00
rdk1   = ROT_LUT+$B00
ROT_RCP = $9500       ; reciprocal table by row count, lo / hi pages
ROT_BLUT = $9700      ; ball-centre depth LUT, 5 pages (zoom_set)
rl2_lo = ROT_BLUT
rl2_hi = ROT_BLUT+$100
rd2    = ROT_BLUT+$200
rk2_lo = ROT_BLUT+$300
rk2_hi = ROT_BLUT+$400
ROT_BLUT2 = $1C00     ; ... rdk2 + bsize, 2 pages
rdk2   = ROT_BLUT2
bsize  = ROT_BLUT2+$100   ; the ball's radius per depth; + $C0 / $D0 / $E0 + radius: its shadow mask lo / hi, rows
; page 4: the view's per-frame constants (view_setup), the zoom's planes
ofb   = $0400         ; (3) OFF - B'x: a rotation point's x + ofb = its T
nby   = $0403         ; (3) -B'y
ofb2  = $0430         ; (3) 2 ofb: a mirrored point's T = ofb2 - its partner's T (rot_load)
nby2  = $0433         ; (3) 2 nby (to $0435; bpit $0438)
eum   = $0406         ; (2) |eu|: the halved eye u in table coordinates, Q2
eus   = $0408         ; (1) its sign (bit 7)
evm   = $0409         ; (2) |ev|
evs   = $040B         ; (1)
tfp0  = $040C         ; (2) TF0 - 1: the far plane of a level-0 item (zoom_set)
tfph  = $040E         ; (2) TFH - 1: ... of a level-H item
cvd0  = $0410         ; (8 each) clip_poly: d = c - cp per vertex, 24-bit
cvd1  = $0418
cvd2  = $0420
cvin  = $0428         ; (8) 1 = the vertex is on the kept side
bsx   = $78         ; (2) clip_blit: the sprite's top-left x (signed)
bsy   = $7A         ; (2) ... stored row (signed)
bsw   = $7C         ; (1) width
bsh   = $7D         ; (1) height
bsrc  = $7E         ; (2) source VRAM address (bank 0)
bpit  = $0438         ; (1) source pitch
vbk   = $0439         ; (1) vcopy: VRAM bank
vpg   = $043A         ; (1) vcopy: page in the bank
; page $0C: the clipper's vertex sets (c = T or sx, v = y or row, z = level)
ac0   = $0C00         ; (8 each) set A
ac1   = $0C08
ac2   = $0C10
av0   = $0C18
av1   = $0C20
av2   = $0C28
az    = $0C30
bc0   = $0C38         ; set B
bc1   = $0C40
bc2   = $0C48
bv0   = $0C50
bv1   = $0C58
bv2   = $0C60
bz    = $0C68
pvxl  = $0C70         ; (8 each) the polygon being filled, x Q7, the stored row
pvxh  = $0C78
pvyl  = $0C80
BKEY  = $1E00         ; (22) ball depth key (sprite row)
dorder = $1E20        ; (22) balls far to near (draw order)
dk    = $1E         ; draw_all cursor into dorder
aimfrac = $04ED       ; aim angle fraction (1/256 unit)
aspd  = $04EE         ; (2) left/right aim speed, 8.8 units a frame
zkey  = $1F
gsg   = $0A         ; sign of the pass's trig operand (bit 7)
gt    = $0B         ; sign of the product (bit 7)
gj    = $0C         ; ball cursor into plist
pcount = $0D        ; moved balls this call
gdul  = $1E40         ; (22 each) du, dv (Q3) of the moved balls,
gduh  = $1E56         ;   P1, P2, P3 >> 8 (3 bytes each)
gdvl  = $1E6C
gdvh  = $1E82
g1a   = $1E98
g1b   = $1EAE
g1c   = $1EC4
; the physics: the velocity each ball MOVED with this tick (tick_all mv) -- the contacts of
; a tick take their normals (rewind) and their impulses (narrow) from it, not from a v an
; earlier contact of the tick changed: two balls struck at once leave as one event, as a
; frozen pair does.  gdul .. g1b reused: dead during the ticks (project_balls rebuilds them)
MVX0  = gdul
MVX1  = gduh
MVX2  = gdvl
MVY0  = gdvh
MVY1  = g1a
MVY2  = g1b
g2a   = $1EDA
g2b   = $1EF0
g2c   = $1F06
g3a   = $1F1C
g3b   = $1F32
g3c   = $1F48
g4a   = $0E00         ; (22 each) the fourth product
g4b   = $0E16
g4c   = $0E2C
plist = $1F60         ; (22) the moved balls (ball indices)
zcur  = $20
zsi   = $21
ROT_TAB = $9C90       ; rotation/projection indices + the draw list (to $9FFF)
rcm   = $45         ; (2) |cos| Q14
rcn   = $47         ; sign of cos (bit 7)
rsm   = $48         ; (2) |sin|
rsn   = $4A
rpc   = $4B         ; (2) |coord| * |cos|
rps   = $4D         ; (2) |coord| * |sin|
rkind = $4F
rn    = $51         ; vertex count / disc class
rtop  = $53
ria   = $54
rib   = $55
raend = $56
rbend = $57
rna   = $86           ; rows left in chain A's edge (render: bx/by cells)
rnb   = $87
rrw   = $88           ; row (saved round the chain calls)
rrun  = $8A           ; the run's length
rsx   = $5B         ; (2) span x
rsw   = $5D         ; (2) span width
era0  = $5F
ex0   = $62         ; (2) edge endpoints, Q4
ey0   = $64         ; (1) edge rows
ex1   = $66
ey1   = $68
edsn  = $6A
rcurbl = $04DF        ; BL_ADR0 last written
rvx   = $1A         ; (2) rot_view: x', y' (Q3)
rvy   = $1C
rvu   = $BD           ; (2) rot_view: du, dv (zp: rvmag indexes them; the
rvv   = $C0           ;   renderer's rxa / rma cells, idle while balls are projected)
rpi   = rxa           ; rot_project: depth index i of the rotation point (rfill's cells, idle then)
rpy   = rxa+1         ; rot_project: the rotation point
rrt   = rxb           ; (2) rot_project: row scratch
rt0   = $9200         ; (128 each, a page half: ROT_NRP <= 128, rot_export asserts) the rotation points
rt1   = rt0+128       ;   about the pivot: T = x'' + OFF (24-bit) -- the first ROT_NRA made by rot_load
rt2   = rt1+128       ;   as the negations of the next ROT_NRA (the table's centre symmetry, 2026-10-27)
ry0   = rt2+128       ; y'' (24-bit signed)
ry1   = ry0+128
ry2   = ry1+128       ; (to $94FF)
; [2026-10-12 6502-cycles-layout/SKILL.md: page-align hot tables -- kgather / rdisc / rspot read these
;  by point index (0..73): all four in page $16, no read crosses]
rpxl  = $1600         ; (128 each, a page half: ROT_NPP <= 128) projected points: sx (Q4 signed), the stored row
rpxh  = rpxl+128
rpyl  = $1500
rpxx  = $1580         ; sx's third byte (24-bit: a close camera puts points 2048 px off)
rpidx = $9100         ; (ROT_NPP) the points' depth index: its own page, the top of the main block
                      ;   (main.asm: ert) -- the reads rpidx,x never cross a page
ct0   = $9180         ; (3 ROT_NCU each) cull_prep's products m_j * eu, -m_j * eu, the v ones, the v ones + KS (24-bit)
ct1   = ct0+3*ROT_NCU
ct2   = ct1+3*ROT_NCU
; [2026-10-21 6502-cycles-layout/SKILL.md: zero page is the register file -- the hot cells
;  in the OS's SIO zero page $30-$3F: the game does no SIO after start, and the OS code it
;  still runs (the keyboard IRQ, SETVBV, XITVBV; mads-src/A800-OS-XL-Rev2-main) touches only
;  POKMSK $10, BRKKEY $11 and ATRACT $4D there]
rph   = $30           ; (1) SX_M: m's third byte
znh   = $31           ; (1) zoom_set: depth entries i < znh have DK past 8 bits (kfar)
dkp   = $32           ; (1) kfar: hi(DK lo * f)
dkf   = $33           ; (1) kfar: f
dkl   = $34           ; (2) kfar: DK hi * f + dkp
myst  = $36           ; (1) mrun: Y at the pending blit's first row
lctx  = $38           ; (1) lct: the axis across div24
gfr   = $39           ; (2) segbox: the far point's mid, hi bytes
srtall = $3B          ; (1) <> 0: collide sorts ord[] in full (a pot, a contact, a new shot)
skey  = $3C           ; (1) collide's check: a moved ball's key, its slot
sslot = $3D
scanall = $3E         ; (1) <> 0: tick_all looks at every ball (a new shot) -- else cdl
tki   = $3F           ; (1) tick_all: the place in cdl, its length, the woken (wkl) count,
cdn   = $40           ;   a woken ball being placed (the OS's zero page: the ROM is out)
wkn   = $41
wv    = $42
