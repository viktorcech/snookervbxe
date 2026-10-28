; physics.asm -- SoA physics engine: tick loop, cushions, pockets, renorm,
; ball-ball collisions.  Byte-exact spec: tools/phys_ref.py; gate:
; tools/phys_check.py (asm vs model, every array, every tick).
;
; Per awake ball and tick (X = ball index, every field is `ARR,x`):
;   sp <= STOP_V -> park          (tested BEFORE the decrement, as before)
;   fric += DEC_HI ; sp -= dec    (dec carries the 8 extra fractional bits)
;   v -= a                        (Q20, 32-bit, both axes: 88 cycles, no multiply)
;   x += v.q12 ; cushion_x        (carry of the add still live for the low wall)
;   y += v.q12 ; cushion_y
;   pocket_test
;   bounced -> renorm             (sp = |v|, a = DEC * v/|v|: 1 sqrt + 2 div)
; then collide.  Friction is a per-ball deceleration VECTOR a, rounded once
; per renorm, instead of two 24x24 multiplies (sp*u >> 16) per ball per tick.

; [2026-10-28 6502-cycles-layout/SKILL.md: a taken branch across a page is +1 -- the code
;  from here on 25 bytes later: tools/phys_check.py --shift=DA36:FF00 counted the hot
;  branches' crossings over a break, 12524 cycles at +0, 1686 at +25 (mv's bmi xneg)]
    :0 dta 0

; ==========================================================================
.proc tick_all
    inc tick16          ; (the physics' clock: cushion.asm's side spin decays by it)
    bne t0
    inc tick16+1
t0:
; [2026-10-22 fable-skill-atari/SKILL.md: work only on what can be reached -- the balls
;  that may be awake: the last tick's awklist and the balls collide woke (wkl), merged in
;  index order (cdl), not all 22 twice a tick; every ball after a new shot (scanall)]
    lda scanall
    beq mg
    lda #0
    sta scanall
    ldx #NB-1           ; every ball
f:
    txa
    sta cdl,x
    dex
    bpl f
    lda #NB
    sta cdn
    bne go              ; (always)
mg:
    ldx awkn            ; cdl = awklist (index order) ...
    stx cdn
    beq m1
c:
    lda awklist-1,x
    sta cdl-1,x
    dex
    bne c
m1:
    ldy wkn             ; ... + the woken, each into its place
    beq go
w:
    lda wkl-1,y
    sta wv
    ldx cdn
i1:
    txa
    beq pl
    lda cdl-1,x
    cmp wv
    bcc pl              ; (distinct: below it -- its place is X)
    sta cdl,x
    dex
    bne i1
pl:
    lda wv
    sta cdl,x
    inc cdn
    dey
    bne w
go:
    lda #0              ; awklist = balls still awake after their tick (index
    sta awkn            ; order): exactly the AWK snapshot collide starts from
    sta wkn
    sta tki
    beq lp              ; (always)
done:
    jsr collide
    ; deferred renorm: once per ball per tick, however many hits it took -- the
    ; balls this tick moved (cdl) and the ones collide woke (wkl): only they can have
    ; NEEDRN; each on its own, so the order does not matter.  The collide pass works
    ; on v, which is always current; sp and a are only read by the next tick.
    ldy cdn
    beq r1
r0:
    ldx cdl-1,y
    lda NEEDRN,x
    beq r0n
    lda #0
    sta NEEDRN,x
    sty tki
    jsr renorm
    ldy tki
r0n:
    dey
    bne r0
r1:
    ldy wkn
    beq rx
r2:
    ldx wkl-1,y
    lda NEEDRN,x
    beq r2n
    lda #0
    sta NEEDRN,x
    sty tki
    jsr renorm
    ldy tki
r2n:
    dey
    bne r2
rx:
    rts

air:                   ; no cloth: no slide, no friction -- the move, its cushions,
    lda #1              ;   pockets and contacts as ever (X = 0)
    sta DIRTY,x
    dec kk_hopt
    bne a1
    jsr hop_land        ; down: on the cloth again, slower, a chalk mark
a1:
    jmp mv
next:
    inc tki
lp:
    ldy tki
    cpy cdn
    bcs done
    ldx cdl,y
tl:
    lda AWK,x
    beq next
    bmi air             ; (the cue in the air: a bounce, chalk.asm)
    sta DIRTY,x         ; (A = 1) it will move (or park) -> reproject it
    lda SLP0,x          ; sliding: v -= a (the slip direction), |s| -= SLIP_DEC;
    ora SLP1,x          ; the slip is gone -> it rolls from here (u = v, renorm)
    ora SLP2,x
    bne sld             ; (rare: sliding, out of line)
roll:
    lda SP2,x           ; sp <= STOP_V ?  -> park
    ora SP1,x
    bne run
    lda SP0,x
    cmp #STOP_V+1
    bcs run
    jsr park
    jmp next
; [2026-10-28 6502-cycles-layout/SKILL.md: rare case out of line, the common path falls
;  through -- a ball rolls on ~93 % of its ticks (the break): no taken beq over this]
sld:                    ; sliding: v -= a (the slip direction), |s| -= SLIP_DEC
    sec
    lda SLP0,x
    sbc #<SLIP_DEC
    sta SLP0,x
    lda SLP1,x
    sbc #>SLIP_DEC
    sta SLP1,x
    lda SLP2,x
    sbc #0
    sta SLP2,x
    bcc send
    ora SLP1,x
    ora SLP0,x
    bne slok
send:
    lda #0
    sta SLP0,x
    sta SLP1,x
    sta SLP2,x
    jsr setu_v
    lda #1
    sta NEEDRN,x
slok:
    sec                 ; (spok: C = 1)
    jmp spok
; spok's top words, out of line: a's sign in N, the low word's carry in C
xan:                    ; a < 0: vx's top word + 1 unless the low word borrowed
    bcc ysub
    inc VX1,x
    bne ysub
    inc VX2,x
    bcs ysub            ; (always: inc keeps C = 1)
xdec:                   ; a >= 0, the low word borrowed: vx's top word - 1
    lda VX1,x
    bne xd1
    dec VX2,x
xd1:
    dec VX1,x
    jmp ysub
yan:
    bcc mv
    inc VY1,x
    bne mv
    inc VY2,x
    bcs mv              ; (always)
ydec:
    lda VY1,x
    bne yd1
    dec VY2,x
yd1:
    dec VY1,x
    jmp mv
run:
    clc                 ; fric += DEC_HI ; sp -= DEC_HI>>8 + carry
    lda FRIC,x
    adc #<DEC_HI
    sta FRIC,x
    lda SP0,x
    bcc c0
    sbc #>DEC_HI+1      ; C = 1: sp0 - hi - 1
    dta $2C             ; bit abs: skips the C = 0 subtract, keeps C
c0:
    sbc #>DEC_HI-1      ; C = 0: sp0 - (hi-1) - 1
    sta SP0,x
    bcs spok            ; no borrow: SP1/SP2 unchanged
    lda SP1,x
    sbc #0
    sta SP1,x
    lda SP2,x
    sbc #0
    sta SP2,x
spok:                   ; vx -= ax  (Q20, 32-bit).  C = 1 here: sp >= STOP_V+1 =
    lda VXF,x           ; 165 > the decrement (<= 68), so sp never borrowed out
    sbc AXF,x
    sta VXF,x
    lda VX0,x
    sbc AX0,x
    sta VX0,x
; [2026-10-28 6502-idioms/SKILL.md: compute only what changes] |a| <= DEC < 2^16 (avec,
;  park, objects): AX1 = AX2 = a's sign, so vx's top word moves only on the low word's carry
    lda AX1,x
    bmi xan
    bcc xdec
ysub:
    sec                 ; vy -= ay (the same)
    lda VYF,x
    sbc AYF,x
    sta VYF,x
    lda VY0,x
    sbc AY0,x
    sta VY0,x
    lda AY1,x
    bmi yan
    bcc ydec
    ; CUSHIONS (Q12).  Positions are UNSIGNED 24-bit 0..L: an under-0 result
    ; shows as a clear CARRY after adding a negative v.  Balls are clamped into
    ; [R, L-R] every tick, so the sign of v says which wall is reachable.
    ; R = $01A400  L-R = $DD6C00  W-R = $6D7C00.  A hit sets NEEDRN directly
    ; (a pot in the same tick parks the ball and clears it again).
mv:
    clc                 ; x += vx.q12, the move's v kept (MVX: rewind, narrow)
    lda VX0,x
    sta MVX0,x
    adc X0,x
    sta X0,x
    lda VX1,x
    sta MVX1,x
    adc X1,x
    sta X1,x
    lda VX2,x
    sta MVX2,x
    adc X2,x
    sta X2,x
    ldy VX2,x           ; sign of v (ldy keeps C and A = X2)
    bmi xneg
    cmp #$DD            ; v >= 0: high wall (x > L-R) only
    bcc xdone
    bne xhi
    lda X1,x
    cmp #$6C
    bcc xdone
    bne xhi
    lda X0,x
    cmp #$01
    bcs xhi
    bcc xdone           ; (always)
xhi:                    ; clamp to L-R, reflect vx -- or, in a pocket mouth, the pocket
    jsr mouthy
    jcs xpot
    lda #$00
    sta X0,x
    lda #$6C
    sta X1,x
    lda #$DD
    sta X2,x
    jsr reflx
    jmp xdone
xlo:                    ; clamp to R, reflect vx (or the pocket)
    jsr mouthy
    jcs xpot
    lda #$00
    sta X0,x
    lda #$A4
    sta X1,x
    lda #$01
    sta X2,x
    jsr reflx
    jmp xdone
xm:                     ; still past L-R, moving away: a mouth's ball, the pocket
    jsr mouthy
    jcs xpot
    jmp xdone
xneg:
    bcc xlo             ; wrapped below 0
    cmp #$F0            ; still below 0, or still past L-R, moving away: a mouth's ball,
    bcs xlo             ;   the pocket has it (unclamped there)
    cmp #$DD
    bcs xm
    cmp #$01
    bcc xlo
    bne xdone
    lda X1,x
    cmp #$A4
    bcc xlo
xdone:
    clc                 ; y += vy.q12 (MVY as x)
    lda VY0,x
    sta MVY0,x
    adc Y0,x
    sta Y0,x
    lda VY1,x
    sta MVY1,x
    adc Y1,x
    sta Y1,x
    lda VY2,x
    sta MVY2,x
    adc Y2,x
    sta Y2,x
    ldy VY2,x
    bmi yneg
    cmp #$6D            ; v >= 0: high wall (y > W-R) only
    bcc ydone
    bne yhi
    lda Y1,x
    cmp #$7C
    bcc ydone
    bne yhi
    lda Y0,x
    cmp #$01
    bcs yhi
    bcc ydone           ; (always)
yneg:
    bcc ylo
    cmp #$F0            ; still below 0, or still past W-R, moving away: a mouth's ball
    bcs ylo
    cmp #$6D
    bcs ym
    cmp #$01
    bcc ylo
    bne ydone
    lda Y1,x
    cmp #$A4
    bcc ylo
ydone:
app:
    txa                 ; still awake -> collide candidate
    ldy awkn
    sta awklist,y
    inc awkn
    jmp next
yhi:
    jsr mouthx
    jcs ypot
    lda #$00
    sta Y0,x
    lda #$7C
    sta Y1,x
    lda #$6D
    sta Y2,x
    jsr refly
    jmp ydone
ylo:
    jsr mouthx
    jcs ypot
    lda #$00
    sta Y0,x
    lda #$A4
    sta Y1,x
    lda #$01
    sta Y2,x
    jsr refly
    jmp ydone
ym:                     ; still past W-R, moving away: a mouth's ball, the pocket
    jsr mouthx
    jcs ypot
    jmp ydone
xpot:                   ; past the cushion line inside a mouth: the pocket (cu_mouth,
    jsr mouth           ;   in the cushion's bank) -- dropped, or on it goes: the x walls'
    jcc xdone           ;   on to the y move, the y walls' on to the next ball
    bcs drop            ; (always)
ypot:
    jsr mouth
    jcc ydone
drop:
    stx tix             ; it dropped (it left the table: collide's full sort)
    inc srtall
    jsr pocket_test.hit
    jmp next
mouth:
    jsr win_cu
    jsr cu_mouth
    jmp win_bcb         ; (keeps C)
.endp

; park: ball X stops: sp = v = a = fric = 0, asleep.  Preserves X.
.proc park
    lda #0
    sta SP0,x
    sta SP1,x
    sta SP2,x
    sta MVX0,x          ; (it moves no more this tick: narrow, rewind read MV of the awake)
    sta MVX1,x
    sta MVX2,x
    sta MVY0,x
    sta MVY1,x
    sta MVY2,x
    sta VXF,x
    sta VX0,x
    sta VX1,x
    sta VX2,x
    sta VYF,x
    sta VY0,x
    sta VY1,x
    sta VY2,x
    sta AXF,x
    sta AX0,x
    sta AX1,x
    sta AX2,x
    sta AYF,x
    sta AY0,x
    sta AY1,x
    sta AY2,x
    sta FRIC,x
    sta AWK,x
    sta NEEDRN,x
    sta SLP0,x
    sta SLP1,x
    sta SLP2,x
    rts
.endp

; The cushions run straight to the noses' points: the corners' as DRAWN (rot_ref.py
; CN: the jaw's tip 90 mm from the corner along the rail, so a ball's centre within
; 90 - R = 64 mm is in the mouth; beyond, the ball overlaps the drawn cushion and
; meets it as a cushion), the middles' L/2 +- 75 mm (the drawn jaws, open 15 deg,
; reach +-74 at the line).  A ball past the cushion line inside a mouth meets the
; pocket (cu_mouth: the fall, the rounded nose).  C = 1: in a mouth.
; [2026-10-27: the corners were the WPBSA 108 mm (cu_mouth's nose): a ball 85 mm
;  off the rail dropped where the picture shows it hitting the cushion (3.png)]
; mouthy: the end rails (x walls) -- y in a corner mouth.  Preserves X.
.proc mouthy
    lda Y2,x            ; y < 64 mm ($040000) ?
    cmp #$04
    bcc yes
    cmp #$6B            ; y >= W - 64 = 1714 mm ($6B2000) ?
    bcc no
    bne yes
    lda Y1,x
    cmp #$20
    rts                 ; C = (y >= $6B20xx)
no:
    rts                 ; (C = 0)
yes:
    sec
    rts
.endp

; mouthx: the side rails (y walls) -- x in a corner or the middle mouth.
.proc mouthx
    lda X2,x            ; x < 64 mm ($040000) ?
    cmp #$04
    bcc yes
    cmp #$DB            ; x >= L - 64 = 3505 mm ($DB1000) ?
    bcc mid
    bne yes
    lda X1,x
    cmp #$10
    bcs yes
mid:
    lda X2,x            ; L/2 - 75 = 1709.5 ($6AD800) <= x < L/2 + 75 = 1859.5 ($743800) ?
    cmp #$6A
    bcc no
    bne m1
    lda X1,x
    cmp #$D8
    bcc no
m1:
    lda X2,x
    cmp #$74
    bcc yes
    bne no
    lda X1,x
    cmp #$38
    bcc yes
no:
    clc
    rts
yes:
    sec
    rts
.endp

; setu_v: ball X rolls from here: u = v.q12.  Preserves X.
.proc setu_v
    lda VX0,x
    sta UX0,x
    lda VX1,x
    sta UX1,x
    lda VX2,x
    sta UX2,x
    lda VY0,x
    sta UY0,x
    lda VY1,x
    sta UY1,x
    lda VY2,x
    sta UY2,x
    rts
.endp

; reflx / refly: ball X against an x / y cushion (clamped to its rail): the impact
; model (cushion.asm: Mathavan 2010, spin and side) runs in the AI's bank.  Keeps X.
.proc reflx
    lda #0
    dta $2C                 ; (bit abs: skips refly's lda)
.endp
.proc refly
    lda #1
    pha
    jsr win_cu
    pla
    jsr cu_go
    jmp win_bcb
.endp
    ert refly-reflx<>3

; pocket_test.hit -- ball tix dropped (cu_mouth): v = a = sp = fric = 0, asleep;
; object balls go off the table (BON = 0, position $FFFFFF so the collide
; prefilter never sees them), the cue respots at the break spot.  Preserves X.
.proc pocket_test
hit:
    ldx #SND_POCKET     ; the ball falls in: its sound
    jsr snd_play
    ldx tix
    jsr park            ; sp = v = a = fric = 0, asleep
    txa                 ; the shot record: potted (the cue too: in hand after
    bne potball         ; the shot, rules_end)
    lda #1
    sta cuein
    bne off             ; (always)
potball:
    ldy potn
    sta potl,y
    inc potn
off:
    lda #0
    sta BON,x
    lda #$FF            ; off the table: never near a rail, never a collide candidate
    sta X0,x
    sta X1,x
    sta X2,x
    sta Y0,x
    sta Y1,x
    sta Y2,x
    rts
.endp



; calc_d2: mP(6) = adx(3)^2 + ady(3)^2 (exact; adx, ady < 2^18).  The sum
; lands in mP, where isqrt48 wants it.  Clobbers X, Y, d2b.
.macro CALCD2           ; :1, :2 = the two 3-byte magnitudes
    SQ24M :1, mP
    SQ24M :2, d2b
    clc                 ; mP += d2b  (both < 2^36: byte 5 stays 0)
    lda mP
    adc d2b
    sta mP
    lda mP+1
    adc d2b+1
    sta mP+1
    lda mP+2
    adc d2b+2
    sta mP+2
    lda mP+3
    adc d2b+3
    sta mP+3
    lda mP+4
    adc d2b+4
    sta mP+4
    lda #0
    sta mP+5
.endm

.proc calc_d2
    CALCD2 adx, ady
    rts
.endp

; renorm: ball X's velocity (or spin) changed.  s = v - u over the Q12 parts:
;  |s| >= SLIP_DEC -> SLIDING: SLP = |s|, a = DEC_S * s/|s| (the slip direction:
;    it stays fixed while the ball slides, so a is too) -- sp is not used;
;  else ROLLING: SLP = 0, sp = |v|, a = DEC_HI * v/|v|; sp == 0 -> a = 0, asleep.
; a per axis = sign * divr(DEC * |c|, |vec|) (Q20).  fric = 0.  Preserves X.
.proc renorm
    stx ri
    sec                 ; sv = s = v - u
    lda VX0,x
    sbc UX0,x
    sta sv
    lda VX1,x
    sbc UX1,x
    sta sv+1
    lda VX2,x
    sbc UX2,x
    sta sv+2
    sec
    lda VY0,x
    sbc UY0,x
    sta sv+3
    lda VY1,x
    sbc UY1,x
    sta sv+4
    lda VY2,x
    sbc UY2,x
    sta sv+5
    jsr vlen            ; root = |s|, avx / avy / sgnx / sgny
    ldx ri
    lda #0
    sta FRIC,x
    lda root+2          ; |s| < SLIP_DEC -> rolling
    bne slide
    lda root+1
    cmp #>SLIP_DEC
    bcc roll
    bne slide
    lda root
    cmp #<SLIP_DEC
    bcc roll
slide:
    lda root            ; SLP = |s|
    sta SLP0,x
    lda root+1
    sta SLP1,x
    lda root+2
    sta SLP2,x
    lda #<DEC_S
    ldy #>DEC_S
    jmp avec
roll:
    lda #0
    sta SLP0,x
    sta SLP1,x
    sta SLP2,x
    lda VX0,x           ; sv = v
    sta sv
    lda VX1,x
    sta sv+1
    lda VX2,x
    sta sv+2
    lda VY0,x
    sta sv+3
    lda VY1,x
    sta sv+4
    lda VY2,x
    sta sv+5
    jsr vlen            ; root = |v|
    ldx ri
    lda root            ; sp = root
    sta SP0,x
    lda root+1
    sta SP1,x
    lda root+2
    sta SP2,x
    lda root
    ora root+1
    ora root+2
    bne nz
    sta AXF,x           ; sp == 0 -> a = 0, asleep  (A = 0)
    sta AX0,x
    sta AX1,x
    sta AX2,x
    sta AYF,x
    sta AY0,x
    sta AY1,x
    sta AY2,x
    sta AWK,x
    rts
nz:
    lda #<DEC_HI
    ldy #>DEC_HI
    ert *<>avec         ; falls into the deceleration vector
.endp

; avec: A:Y = DEC (Q20) -> ball ri's a = sign * divr(DEC * |c|, root) per axis
; (avx / avy / sgnx / sgny / root from vlen), awake.  DEC < 2^16, |c| <= root.
.proc avec
    sta dx0+1           ; the mode's constant into both multiplies
    sta dy0+1
    sty dx1+1
    sty dy1+1
    lda avx
    sta mA
    lda avx+1
    sta mA+1
    lda avx+2
    sta mA+2
dx0 lda #0
    sta mB
dx1 lda #0
    sta mB+1
    lda #0
    sta mB+2
    jsr mul48           ; mP = DEC * |cx| (< 2^32)
    jsr set_mA_mP
    jsr set_mB_root
    jsr div16r          ; mQ = round(DEC * |cx| / root) <= DEC
    ldx ri
    lda sgnx
    bne axn
    lda mQ
    sta AXF,x
    lda mQ+1
    sta AX0,x
    lda mQ+2
    sta AX1,x
    lda #0
    sta AX2,x
    beq doy             ; always
axn:
    sec
    lda #0
    sbc mQ
    sta AXF,x
    lda #0
    sbc mQ+1
    sta AX0,x
    lda #0
    sbc mQ+2
    sta AX1,x
    lda #0
    sbc #0
    sta AX2,x
doy:
    lda avy
    sta mA
    lda avy+1
    sta mA+1
    lda avy+2
    sta mA+2
dy0 lda #0
    sta mB
dy1 lda #0
    sta mB+1
    lda #0
    sta mB+2
    jsr mul48
    jsr set_mA_mP
    jsr set_mB_root
    jsr div16r
    ldx ri
    lda sgny
    bne ayn
    lda mQ
    sta AYF,x
    lda mQ+1
    sta AY0,x
    lda mQ+2
    sta AY1,x
    lda #0
    sta AY2,x
    beq awake           ; always
ayn:
    sec
    lda #0
    sbc mQ
    sta AYF,x
    lda #0
    sbc mQ+1
    sta AY0,x
    lda #0
    sbc mQ+2
    sta AY1,x
    lda #0
    sbc #0
    sta AY2,x
awake:
    lda #1
    sta AWK,x
    rts
.endp

; vlen: sv (2 x 3 bytes, signed Q12) -> avx / avy = |.|, sgnx / sgny (1 = neg),
; root = sqrt(avx^2 + avy^2).
.proc vlen
    lda sv+2
    bmi xn
    lda #0
    sta sgnx
    lda sv
    sta avx
    lda sv+1
    sta avx+1
    lda sv+2
    sta avx+2
    bpl ya              ; (always: the bmi above not taken)
xn:
    lda #1
    sta sgnx
    sec
    lda #0
    sbc sv
    sta avx
    lda #0
    sbc sv+1
    sta avx+1
    lda #0
    sbc sv+2
    sta avx+2
ya:
    lda sv+5
    bmi yn
    lda #0
    sta sgny
    lda sv+3
    sta avy
    lda sv+4
    sta avy+1
    lda sv+5
    sta avy+2
    bpl sq              ; (always: the bmi above not taken)
yn:
    lda #1
    sta sgny
    sec
    lda #0
    sbc sv+3
    sta avy
    lda #0
    sbc sv+4
    sta avy+1
    lda #0
    sbc sv+5
    sta avy+2
sq:
    CALCD2 avx, avy     ; mP = avx^2 + avy^2
    jmp isqrt48         ; root = the length
.endp

; spin_u: ball X is about to be hit and has no renorm pending this tick -> U =
; its spin velocity u, which the (frictionless) collision keeps: rolling u = v,
; sliding u = v - SLP * s^ with s^ = a / DEC_S.  Preserves X.
.proc spin_u
    lda NEEDRN,x
    bne out
    lda SLP0,x
    ora SLP1,x
    ora SLP2,x
    bne sl
    jmp setu_v
out:
    rts
sl:
    stx tix
    lda AX2,x           ; x: |a| (Q20, < 2^16: AXF, AX0), its sign
    sta sgu
    bpl axp
    sec
    lda #0
    sbc AXF,x
    sta mB
    lda #0
    sbc AX0,x
    sta mB+1
    jmp axm
axp:
    lda AXF,x
    sta mB
    lda AX0,x
    sta mB+1
axm:
    jsr slpa            ; mQ = round(SLP * |ax| / DEC_S)
    ldx tix
    lda sgu             ; ux = vx - sign * mQ
    bmi uxn
    sec
    lda VX0,x
    sbc mQ
    sta UX0,x
    lda VX1,x
    sbc mQ+1
    sta UX1,x
    lda VX2,x
    sbc mQ+2
    sta UX2,x
    jmp doy
uxn:
    clc
    lda VX0,x
    adc mQ
    sta UX0,x
    lda VX1,x
    adc mQ+1
    sta UX1,x
    lda VX2,x
    adc mQ+2
    sta UX2,x
doy:
    lda AY2,x
    sta sgu
    bpl ayp
    sec
    lda #0
    sbc AYF,x
    sta mB
    lda #0
    sbc AY0,x
    sta mB+1
    jmp aym
ayp:
    lda AYF,x
    sta mB
    lda AY0,x
    sta mB+1
aym:
    jsr slpa
    ldx tix
    lda sgu
    bmi uyn
    sec
    lda VY0,x
    sbc mQ
    sta UY0,x
    lda VY1,x
    sbc mQ+1
    sta UY1,x
    lda VY2,x
    sbc mQ+2
    sta UY2,x
    rts
uyn:
    clc
    lda VY0,x
    adc mQ
    sta UY0,x
    lda VY1,x
    adc mQ+1
    sta UY1,x
    lda VY2,x
    adc mQ+2
    sta UY2,x
    rts
.endp

; slpa: mB(2) = |a_axis| -> mQ = round(SLP(tix) * mB / DEC_S)  (< SLP < 2^24)
.proc slpa
    ldx tix
    lda #0
    sta mB+2
    lda SLP0,x
    sta mA
    lda SLP1,x
    sta mA+1
    lda SLP2,x
    sta mA+2
    jsr mul48           ; mP = SLP * |a| (mB+2 = 0 stays: DEC_S is 16-bit)
    lda #<DEC_S
    sta mB
    lda #>DEC_S
    sta mB+1
    jmp divpr16         ; (mQ < SLP < 2^24: divpr16's domain)
.endp

.proc set_mA_mP         ; mA(6) = mP(6)  (48-bit dividend for div24)
    lda mP
    sta mA
    lda mP+1
    sta mA+1
    lda mP+2
    sta mA+2
    lda mP+3
    sta mA+3
    lda mP+4
    sta mA+4
    lda mP+5
    sta mA+5
    rts
.endp




; ==========================================================================
; ball-ball collisions -- SWEEP over the balls sorted by x high byte.
; ord[] is kept STABLY sorted by X2 with an insertion sort from the previous
; tick's order (nearly sorted: ~60 cycles a ball); opos[] is its inverse.
; For every awake ball ci (index order) the neighbours in ord are scanned
; downward, then upward, until a ball 5 or more x-high-byte units away ON THE
; SCANNING SIDE is met (|dx| >= $040001 > mind then; a ball that a hit moved
; to the wrong side does not stop the scan -- the order is not re-sorted
; inside the pass).  Each candidate passes the same tests the full scan
; applied: each unordered pair once ((ci, j) iff j > ci or j asleep), x AND y
; high bytes within 4, both on the table; potted balls sit at $FFFFFF.
; Same algorithm in tools/phys_ref.py; tools/phys_check.py proves equality.
; ==========================================================================
.proc set_mB_root       ; mB(3) = root (divisor)
    lda root
    sta mB
    lda root+1
    sta mB+1
    lda root+2
    sta mB+2
    rts
.endp


; collide_full: the full sort, out of line before collide (rare: positions changed besides
; the ticks -- a pot, a contact, a new shot); collide's common path is the cheap check.
collide_full:
    lda #0
    sta srtall
    ldy ord             ; --- stable insertion sort of ord[] by X2 ---
    lda X2,y            ; A = key of the predecessor (max of the sorted prefix)
    ldx #1
cso:
    ldy ord,x
    cmp X2,y
    beq csn             ; equal: in place, A is already its key
    jcs collide_ins     ; smaller than its predecessor: full insertion (rare, past collide)
    lda X2,y
csn:
    inx
    cpx #NB
    bne cso
    jmp cokf            ; (every key as sorted: past collide, its loops' page)

.proc collide
    lda srtall          ; positions changed besides the ticks: the full sort (rare)
    bne collide_full
chk:                    ; only awklist's balls moved: no strict inversion next to one of
    ldx awkn            ;   them means the sort would change nothing
    beq sorted
ck:                     ; [2026-10-22 fable-skill-atari/SKILL.md: the cheap pass first --
    ldy awklist-1,x     ;  2 neighbour checks a moving ball, not 21 for the whole table]
    lda X2,y            ; [2026-10-28 fable-skill-atari/SKILL.md 4: a cache behind a stamp]
    cmp okey,y          ;  key as last in order: unchanged -> no inversion can start at it
    beq nr              ;  (one needs a changed key: the others moved only with srtall)
    sta okey,y
    sta skey
    lda opos,y
    tay                 ; Y = its slot
    beq nl
    sty sslot
    lda ord-1,y
    tay
    lda X2,y            ; the left one's key > its own: unsorted
    cmp skey
    beq lok
    bcs collide_full
lok:
    ldy sslot
nl:
    cpy #NB-1
    bcs nr
    lda ord+1,y
    tay
    lda skey            ; its own > the right one's: unsorted
    cmp X2,y
    beq nr
    bcs collide_full
nr:
    dex
    bne ck
sorted:
    ldx #0              ; awklist[] (awkn) was built by tick_all
    cpx awkn
    bcc ohave
    rts
ohave:                  ; X = awki
    stx awki
    lda awklist,x
    sta ci              ; [2026-10-28 measured: cxh / cyl / ci as SMC operands cost more here --
    tax                 ;  ohave runs once a ball a tick for ~4 candidates; zero page stays]
    lda #$FF            ; no contact of this sweep yet (narrow: two at once)
    sta fcj
    lda X2,x
    sta cxh
    lda Y2,x
    sbc #3              ; (C = 0: both ways in are a taken bcc) Y2 - 4
    sta cyl             ; cyh - 4: |dy hi| <= 4 <=> (Y2 - cyl) mod 256 <= 8
    lda opos,x
    sta kup
    tax                 ; X = downward cursor
; Each candidate j: pair once ((ci, j) iff j > ci or j asleep; j != ci as ord
; is a permutation), x AND y high bytes within 4, then narrow.  A y "pass"
; that only the mod-256 form lets through is a potted ball ($FF): narrow's
; BON test rejects it.
dn:                     ; --- downward in ord ---
    dex
    bmi up0
    ldy ord,x           ; Y = j
    lda cxh
    sec
    sbc X2,y
    bcc dnx             ; x_j > cxh (moved by a hit): no stop, x test
    cmp #5
    bcs up0             ; x_j <= cxh - 5 -> done downward
dnt:                    ; |dx hi| <= 4
    cpy ci
    bcs dc              ; j > ci (C = 1 for dc's subtract)
    lda AWK,y           ; j < ci: only if ball j is asleep
    bne dn
    sec                 ; [2026-10-12 6502-idioms/SKILL.md: sec after a not-taken bcc is dead -- only this path needs it]
dc:
    lda Y2,y
    sbc cyl
    cmp #9
    bcs dn
    stx kdn
    sty cj
    jsr narrow
    ldx kdn
    bpl dn              ; (always: a slot < NB)
dnx:
    cmp #256-4          ; x_j - cxh >= 5 -> too far
    bcc dn
    bcs dnt             ; (always)
cnext:
    ldx awki            ; next awake ball
    inx
    cpx awkn
    bcc ohave
    rts
up0:
    ldx kup
up:                     ; --- upward in ord ---
    inx
    cpx #NB
    bcs cnext
    ldy ord,x
    lda X2,y
    sbc cxh             ; (C = 0: the bcs not taken) x_j - cxh - 1
    bcc upx             ; x_j <= cxh: no stop, x test
    cmp #4
    bcs cnext           ; x_j >= cxh + 5 -> done
upt:
    cpy ci
    bcs uc              ; (C = 1 for uc's subtract)
    lda AWK,y
    bne up
    sec
uc:
    lda Y2,y
    sbc cyl
    cmp #9
    bcs up
    stx kup
    sty cj
    jsr narrow
    ldx kup
    bpl up              ; (always: a slot < NB)
upx:
    cmp #256-5          ; cxh - x_j >= 5 -> too far (A = x_j - cxh - 1)
    bcc up
    bcs upt             ; (always)
.endp

; [6502-cycles-layout: keep a hot stretch in one page] the full sort's loop, and collide's
; ck .. up loops (every tick), each in one page: a taken branch across one costs a cycle more
    ert >cso <> >[csn+4]
    ert >collide.ck <> >[collide.upx+5]

; okey: each ball's X2 when collide last found it in order (collide.ck skips a ball whose key
; is unchanged; cokf sets them all after the full sort) -- read abs,y every tick: in one page
cokf:
    ldy #NB-1
cok lda X2,y
    sta okey,y
    dey
    bpl cok
    jmp collide.sorted
okey    :NB dta 0
    ert >okey <> >[okey+NB-1]
; rewind's cells (past collide since 2026-10-28: draw_all grew, collide's loops keep their page)
rdx     dta 0, 0, 0         ; d, w
rdy     dta 0, 0, 0
rwx     dta 0, 0, 0
rwy     dta 0, 0, 0
rft     dta 0               ; rewind: the contact's time back from the tick's end, 1/64 tick
rfb     dta 0

; collide_ins: the rare full insertion of collide's sort, out of line; opos[]
; (inverse of ord) follows every move.
collide_ins:
    lda X2,y
    sta key
    sty cur
    stx si
    txa
    tay                 ; Y = hole
cinner:
    dey
    bmi cplace
    ldx ord,y
    lda X2,x
    cmp key
    bcc cplace          ; X2 < key -> insert after it
    beq cplace          ; equal -> after it too (stable)
    inc opos,x          ; ball X moves one slot right (C = 1 kept)
    txa
    sta ord+1,y         ; shift right, hole moves left
    bcs cinner          ; (always)
cplace:
    iny
    ldx cur
    txa
    sta ord,y
    tya
    sta opos,x
    ldx si
    ldy ord,x
    lda X2,y            ; the predecessor of the next element
    jmp csn

; rewind: the pair (ci, cj) overlaps -> d = j - i moved back in time to the
; contact: d(t) = d - t (wj - wi), w the velocity each MOVED with this tick (MV; rvj:
; j's, 0 when it lay still), t in 0..1 tick by 6 halvings (t to 1/64: the normal
; within ~0.3 deg at 17 mm a tick).  -> adx, ady, sgnx, sgny, mP = d2 of that d.
; A ball off a cushion this tick (NEEDRN 2) bent its path at the rail: the
; overlap's own normal then (mP as it is).
; ovl: rewind's test of the tried d (rtx, rty): C = 1 overlapping (d2 < mind2), C = 0 not.
; [2026-10-27 fable-skill-atari/SKILL.md 3: the cheap reject first; 6502-loops-tables-smc:
;  tables beat arithmetic] a = |dx| >> 10, b = |dy| >> 10 give d2 >= (a^2 + b^2) << 20 and
;  d2 < ((a+1)^2 + (b+1)^2) << 20; MIND2 = 44100 << 20 exactly (mind = 210 << 10): a sum on
;  the right side decides as the full d2 would -- the rest (near the contact) go full (rabs)
.proc ovl
    lda rtx+2           ; |dx|'s top bytes -> X = a, or no overlap (|dx| >= 4 << 16 > mind)
    bpl fxp
    sec
    lda #0
    sbc rtx
    lda #0
    sbc rtx+1
    sta nt
    lda #0
    sbc rtx+2           ; (C = 0: 0 - a negative high byte borrows)
    bcc fxs
fxp:
    ldx rtx+1
    stx nt
fxs:
    cmp #4
    bcs no
    tax
    lda nt
    lsr @
    lsr @
    ora sh6,x
    tax
    lda rty+2           ; the same for |dy| -> Y = b
    bpl fyp
    sec
    lda #0
    sbc rty
    lda #0
    sbc rty+1
    sta nt
    lda #0
    sbc rty+2
    bcc fys
fyp:
    ldy rty+1
    sty nt
fys:
    cmp #4
    bcs no
    tay
    lda nt
    lsr @
    lsr @
    ora sh6,y
    tay
    clc                 ; a^2 + b^2 >= 44100: d2 >= mind2 (a > 210 lands here too)
    lda sqlo,x
    adc sqlo,y
    sta nt
    lda sqhi,x
    adc sqhi,y
    bcs no
    cmp #>44100
    bcc up
    bne no
    lda nt
    cmp #<44100
    bcs no
up:
    clc                 ; (a+1)^2 + (b+1)^2 <= 44100: d2 < mind2 (a, b <= 210 here)
    lda sqlo+1,x
    adc sqlo+1,y
    sta nt
    lda sqhi+1,x
    adc sqhi+1,y
    bcs ful
    cmp #>44100
    bcc yes
    bne ful
    lda nt
    cmp #<44100+1
    bcc yes
ful:
    jsr rabs            ; the full d2 against mind2, from the high byte down
    ldx #5
cm:
    lda mP,x
    cmp MIND2,x
    bcc yes
    bne no
    dex
    bpl cm
no:                     ; (equal: touching -- no overlap)
    clc
    rts
yes:
    sec
    rts
.endp

.proc rewind
    lda #0
    sta rft             ; (none: the cushion case keeps 0)
    ldx ci
    ldy cj
    lda NEEDRN,x
    ora NEEDRN,y
    and #2
    beq go
    jmp calc_d2         ; (narrow's adx, ady: its d2 -- narrow may have skipped it)
go:
    sec                 ; d = j - i, w = vj - vi (Q12, signed)
    lda X0,y
    sbc X0,x
    sta rdx
    lda X1,y
    sbc X1,x
    sta rdx+1
    lda X2,y
    sbc X2,x
    sta rdx+2
    sec
    lda Y0,y
    sbc Y0,x
    sta rdy
    lda Y1,y
    sbc Y1,x
    sta rdy+1
    lda Y2,y
    sbc Y2,x
    sta rdy+2
    sec
    lda rvj
    sbc MVX0,x
    sta rwx
    lda rvj+1
    sbc MVX1,x
    sta rwx+1
    lda rvj+2
    sbc MVX2,x
    sta rwx+2
    sec
    lda rvj+3
    sbc MVY0,x
    sta rwy
    lda rvj+4
    sbc MVY1,x
    sta rwy+1
    lda rvj+5
    sbc MVY2,x
    sta rwy+2
    lda #32             ; this halving's share of the tick, 1/64: 32 .. 1, six halvings
    sta rfb             ;   (rfb shifted out to 0 ends them -- no counter)
hl:
    lda rwx+2           ; w >>= 1 (arithmetic)
    cmp #$80
    ror rwx+2
    ror rwx+1
    ror rwx
    lda rwy+2
    cmp #$80
    ror rwy+2
    ror rwy+1
    ror rwy
    sec                 ; try d - w: still overlapping -> keep it
    lda rdx
    sbc rwx
    sta rtx
    lda rdx+1
    sbc rwx+1
    sta rtx+1
    lda rdx+2
    sbc rwx+2
    sta rtx+2
    sec
    lda rdy
    sbc rwy
    sta rty
    lda rdy+1
    sbc rwy+1
    sta rty+1
    lda rdy+2
    sbc rwy+2
    sta rty+2
    jsr ovl             ; C = 1: still overlapping
    bcc nk
    lda rft             ; still overlapping: this halving's d stands, its share of the tick counts
    ora rfb
    sta rft
    lda rtx
    sta rdx
    lda rtx+1
    sta rdx+1
    lda rtx+2
    sta rdx+2
    lda rty
    sta rdy
    lda rty+1
    sta rdy+1
    lda rty+2
    sta rdy+2
nk:
    lsr rfb
    bne hl
    ldx #2              ; the kept d -> adx, ady, sgnx, sgny, mP
dc:
    lda rdx,x
    sta rtx,x
    lda rdy,x
    sta rty,x
    dex
    bpl dc
    ert *<>rabs         ; falls into rabs
.endp

; rabs: (rtx, rty) signed -> adx, ady = |.|, sgnx, sgny = the high bytes,
; mP = adx^2 + ady^2
.proc rabs
    lda rtx+2
    sta sgnx
    bpl xp
    sec
    lda #0
    sbc rtx
    sta adx
    lda #0
    sbc rtx+1
    sta adx+1
    lda #0
    sbc rtx+2
    bcc xs                ; (always: 0 - a negative high byte borrows)
xp:
    ldx rtx
    stx adx
    ldx rtx+1
    stx adx+1
xs:
    sta adx+2
    lda rty+2
    sta sgny
    bpl yp
    sec
    lda #0
    sbc rty
    sta ady
    lda #0
    sbc rty+1
    sta ady+1
    lda #0
    sbc rty+2
    bcc ys                ; (always: 0 - a negative high byte borrows)
yp:
    ldx rty
    stx ady
    ldx rty+1
    stx ady+1
ys:
    sta ady+2
    CALCD2 adx, ady
    rts
.endp

.macro CUMB                ; mB = |cu_kv,y| (cumul)
    lda cu_kv+2,y
    bmi yn
    lda cu_kv,y
    sta mB
    lda cu_kv+1,y
    sta mB+1
    lda cu_kv+2,y
    sta mB+2
    bpl yd              ; (always: the bmi above not taken)
yn
    sec
    lda #0
    sbc cu_kv,y
    sta mB
    lda #0
    sbc cu_kv+1,y
    sta mB+1
    lda #0
    sbc cu_kv+2,y
    sta mB+2
yd
.endm

; cumul: sP[0..2] = round(cu_kv,x * cu_kv,y >> 16) signed -- smul3r's result, bit for bit,
; for the cushion model's programs (cuprog.asm).  Keeps cud.
; [2026-10-27 6502-idioms/SKILL.md: the reader reads the source -- no sA / sB copies]
.proc cumul
    cpx #$80                ; x | $80: mA = |x| as the last cumul left it (cuprog.asm marks those)
    bcs re
    lda cu_kv+2,x           ; the product's sign: bit 7 of the two signs' xor
    eor cu_kv+2,y
    sta csgn
    lda cu_kv+2,x           ; mA = |x|
    bmi xn
    lda cu_kv,x
    sta mA
    lda cu_kv+1,x
    sta mA+1
    lda cu_kv+2,x
    sta mA+2
    bpl xd              ; (always: the bmi above not taken)
xn:
    sec
    lda #0
    sbc cu_kv,x
    sta mA
    lda #0
    sbc cu_kv+1,x
    sta mA+1
    lda #0
    sbc cu_kv+2,x
    sta mA+2
xd:
    CUMB
    jsr mul48
    bit csgn
    bmi n
    jmp rsh16
n:
    jmp rsh16n
; [2026-10-27 6502-loops-tables-smc/SKILL.md: SMC stores of a target that rarely changes]
; the same x cell, unchanged since: no |x| into mA, mul48r keeps its patches
re:
    txa
    and #$7F
    tax
    lda cu_kv+2,x
    eor cu_kv+2,y
    sta csgn
    CUMB
    jsr mul48r
    bit csgn
    bmi n
    jmp rsh16
.endp

sh6     dta $00, $40, $80, $C0  ; rewind: |d|'s top byte (0..3) << 6
rvj     dta 0, 0, 0, 0, 0, 0    ; narrow: j's move this tick (MVX, MVY; 0 when it lay still)
    ert MVX1-MVX0<>NB || MVX2-MVX1<>NB || MVY0-MVX2<>NB || MVY1-MVY0<>NB || MVY2-MVY1<>NB
SIMUL = 4                   ; contacts within 1/16 tick: struck at once (narrow.two)

; (isqrtc: physmain.asm, the main RAM)

; narrow: the exact contact test and resolution for the pair (ci, cj).
; The normal is kept as MAGNITUDE + sign: cnx = |nx| = round(|dx|<<16 / d),
; sign = bit 7 of sgnx (dx's high byte); every product with it is the
; unsigned mul48 of the magnitudes, then rsh16 / rsh16n by the combined
; sign -- smul3/smul3r's own steps without re-deriving |n| from a signed
; copy.  A zero magnitude gives 0 either way.
; MSIGN s: rsh16 or rsh16n by bit 7 of s -> sP[0..2] = round(+-P >> 16).
.macro MSIGN
    bit :1
    bmi n
    jsr rsh16
    jmp d
n
    jsr rsh16n
d
.endm

.proc narrow
    ldx ci              ; X = i, Y = j
    ldy cj
    lda BON,x           ; both balls on the table?
    beq nc0
    lda BON,y
    bne on
nc0:
    rts
on:
    sec                 ; adx = |j.x - i.x| ; sgnx = its high byte (sign)
    lda X0,y
    sbc X0,x
    sta adx
    lda X1,y
    sbc X1,x
    sta adx+1
    lda X2,y
    sbc X2,x
    sta sgnx
    bpl xp
    sec
    lda #0
    sbc adx
    sta adx
    lda #0
    sbc adx+1
    sta adx+1
    lda #0
    sbc sgnx
xp:
    sta adx+2
    cmp #$03            ; broad phase: |dx| >= mind ($034800) -> no contact
    bcc xok
    bne nc0             ; (nc0's rts: in this branch's page, nocol's is not)
    lda adx+1
    cmp #$48
    bcs nc0
xok:
    sec                 ; ady = |j.y - i.y| ; sgny
    lda Y0,y
    sbc Y0,x
    sta ady
    lda Y1,y
    sbc Y1,x
    sta ady+1
    lda Y2,y
    sbc Y2,x
    sta sgny
    bpl yp
    sec
    lda #0
    sbc ady
    sta ady
    lda #0
    sbc ady+1
    sta ady+1
    lda #0
    sbc sgny
yp:
    sta ady+2
    cmp #$03
    bcc yok
    bne nocol
    lda ady+1
    cmp #$48
    bcc yok
nocol:                  ; no-contact exits land here
    rts
yok:
    ; lower bound first: with a = |dx|>>10, b = |dy|>>10 (<= 210, mind = 210<<10)
    ; (a^2 + b^2)<<20 <= d2, so a^2 + b^2 >= 44100 already means d2 >= mind2:
    ; no contact (most rack neighbours sit just outside, cheaply rejected here)
    lda adx+2
    lsr @
    sta nt
    lda adx+1
    ror @
    lsr nt
    ror @
    tax
    lda ady+2
    lsr @
    sta nt
    lda ady+1
    ror @
    lsr nt
    ror @
    tay
    clc
    lda sqlo,x
    adc sqlo,y
    sta nt
    lda sqhi,x
    adc sqhi,y
    bcs nocol           ; >= 65536
    cmp #>44100
    bcc full
    bne nocol
    lda nt
    cmp #<44100
    bcs nocol
full:
; [2026-10-27 fable-skill-atari/SKILL.md 3: a rejection by what it needs] the upper bound:
;  (a+1)^2 + (b+1)^2 <= 44100 -> d2 < mind2, a contact for sure (a, b <= 209 here): no d2 now
;  -- rewind makes its own (rabs), its cushion case calc_d2; d2 = 0 is |dx| = |dy| = 0
    clc
    lda sqlo+1,x
    adc sqlo+1,y
    sta nt
    lda sqhi+1,x
    adc sqhi+1,y
    bcs exact
    cmp #>44100
    bcc sure
    bne exact
    lda nt
    cmp #<44100+1
    bcs exact
sure:
    lda adx
    ora adx+1
    ora adx+2
    ora ady
    ora ady+1
    ora ady+2
    jne lt
    rts
exact:
    CALCD2 adx, ady     ; mP = d2 = adx^2 + ady^2  (mP+5 = 0)
    lda mP              ; d2 == 0 ?
    ora mP+1
    ora mP+2
    ora mP+3
    ora mP+4
    beq nc1
    ldx #5              ; d2 >= mind2 ?  (compare from the high byte down)
cmp2:
    lda mP,x
    cmp MIND2,x
    bcc lt
    bne nc1             ; d2 > mind2 -> too far
    dex
    bpl cmp2
nc1:
    rts                 ; equal -> just touching, skip
lt:
    lda fcon            ; the shot record: the first ball the cue touches
    bpl fc0
    lda ci
    bne fc1
    lda cj              ; (the cue is ball 0)
    sta fcon
    bpl fc0             ; (always)
fc1:
    lda cj
    bne fc0
    lda ci
    sta fcon
fc0:
    ldy cj              ; j's move this tick -> rvj: MV while it is awake (a ball woken
    lda AWK,y           ;   this tick had its MV cleared), none when it lay still
    beq rj0
    lda MVX0,y          ; [2026-10-27 6502-cycles-layout/SKILL.md: unroll a loop whose body
    sta rvj             ;  is smaller than its counting]
    lda MVX1,y
    sta rvj+1
    lda MVX2,y
    sta rvj+2
    lda MVY0,y
    sta rvj+3
    lda MVY1,y
    sta rvj+4
    lda MVY2,y
    sta rvj+5
    jmp rjd
rj0:
    sta rvj             ; (A = 0)
    sta rvj+1
    sta rvj+2
    sta rvj+3
    sta rvj+4
    sta rvj+5
rjd:
    jsr rewind          ; the normal at the contact, not deep in the overlap
    jsr isqrtc          ; d = isqrt(d2)
    lda root
    sta mB              ; mB = d: the divisor of both normals
    ora root+1
    ora root+2
    beq nc1
    lda root+1
    sta mB+1
    lda root+2
    sta mB+2
    lda #0              ; cnx = round((|dx|<<16) / d)
    sta mA
    sta mA+1
    sta mA+5
    lda adx
    sta mA+2
    lda adx+1
    sta mA+3
    lda adx+2
    sta mA+4
    jsr div16r
    lda mQ
    sta cnx
    lda mQ+1
    sta cnx+1
    lda mQ+2
    sta cnx+2
    lda #0              ; cny = round((|dy|<<16) / d)  (mA+5 still 0)
    sta mA
    sta mA+1
    lda ady
    sta mA+2
    lda ady+1
    sta mA+3
    lda ady+2
    sta mA+4
    jsr div16r
    lda mQ
    sta cny
    lda mQ+1
    sta cny+1
    lda mQ+2
    sta cny+2
    sec                 ; mA = ov = (mind - d + 1) >> 1   (half overlap)
    lda #$00
    sbc root
    tax
    lda #$48
    sbc root+1
    tay
    lda #$03
    sbc root+2          ; (the top byte stays in A)
    inx                 ; + 1
    bne ov1
    iny
    bne ov1
    adc #0              ; (C = 1: mind - d borrowed nothing) + 1
ov1:
    lsr @               ; (mA = ov, the normals in mB: the second product reuses mA, mul48r)
    sta mA+2
    tya
    ror @
    sta mA+1
    txa
    ror @
    sta mA
    ; --- positional separation: i -= n*ov , j += n*ov ---
    lda cnx
    sta mB
    lda cnx+1
    sta mB+1
    lda cnx+2
    sta mB+2
    jsr mul48
    MSIGN sgnx          ; sP[0..2] = round(nx*ov >> 16)
    ldx ci
    ldy cj
    sec
    lda X0,x
    sbc sP
    sta X0,x
    lda X1,x
    sbc sP+1
    sta X1,x
    lda X2,x
    sbc sP+2
    sta X2,x
    clc
    lda X0,y
    adc sP
    sta X0,y
    lda X1,y
    adc sP+1
    sta X1,y
    lda X2,y
    adc sP+2
    sta X2,y
    inc srtall          ; (both moved apart: the next tick's full sort)
    lda cny             ; (mA = ov still: mul48 reads its operands only)
    sta mB
    lda cny+1
    sta mB+1
    lda cny+2
    sta mB+2
    jsr mul48r
    MSIGN sgny
    ldx ci
    ldy cj
    sec
    lda Y0,x
    sbc sP
    sta Y0,x
    lda Y1,x
    sbc sP+1
    sta Y1,x
    lda Y2,x
    sbc sP+2
    sta Y2,x
    clc
    lda Y0,y
    adc sP
    sta Y0,y
    lda Y1,y
    adc sP+1
    sta Y1,y
    lda Y2,y
    adc sP+2
    sta Y2,y
    ; --- rvn from the velocities each MOVED with this tick (MV; j's in rvj): the
    ;     impulse of a contact an earlier one of the tick does not change -- struck
    ;     at once, they leave at once (two: the contacts apart in time go in turn)
    ldx ci              ; wiv = i's MV
    lda MVX0,x
    sta wiv
    lda MVX1,x
    sta wiv+1
    lda MVX2,x
    sta wiv+2
    lda MVY0,x
    sta wiv+3
    lda MVY1,x
    sta wiv+4
    lda MVY2,x
    sta wiv+5
    jsr dotv
    lda sP+2            ; rvn <= 0 -> no impulse
    bmi nimp
    ora sP+1
    ora sP
    bne imp
nimp:
    rts
tw: jmp two             ; (the second contact: out of line, past aw)
imp:
; [2026-10-21 6502-cycles-layout/SKILL.md: the rare case (a hit hard enough to hear) costs only
;  the impulse path; 6502-idioms/SKILL.md: rvn's bytes tested in place, no copy]
    lda sP+2            ; a click from 0.5 mm a tick (rvn >= $000800, Q12) up
    bne snd
    lda sP+1
    cmp #$08
    bcc nos
snd:
    ldx #SND_BALL       ; the balls' sound (keeps sP)
    jsr snd_play
nos:
    lda sP              ; the spins survive the (frictionless) impact: U of
    pha                 ; both balls from their state before it (spin_u
    lda sP+1            ; uses the math cells: rvn rides the stack)
    pha
    lda sP+2
    pha
    ldx ci
    jsr spin_u
    ldx cj
    jsr spin_u
    pla                 ; mA = rvn (> 0: unsigned): off the stack straight into the
    sta mA+2            ; multiplicand (6502-idioms: no RAM cell for a value that
    pla                 ; only waits)
    sta mA+1
    pla
    sta mA
    lda fcj             ; the sweep's first contact is remembered (its normal, rvn):
    cmp #$FE            ;   a second one in the tick solves both at once (two); $FE:
    beq app             ;   the two solved, later ones alone; $FF (the usual): the
    bcc tw              ;   first -- remember it
    ldx cj
    stx fcj
    stx fj1             ; (the ball itself, kept while fcj turns into a state)
    lda rft
    sta fft
    ldx #2
r1: lda cnx,x
    sta fnx,x
    lda cny,x
    sta fny,x
    lda mA,x
    sta fa,x
    dex
    bpl r1
    lda sgnx
    sta fsx
    lda sgny
    sta fsy
app:
    lda #$F3            ; imp = (499 * rvn) >> 9 ; 256+rest_b = 499 = $01F3
    sta mB
    lda #$01
    sta mB+1
    lda #$00
    sta mB+2
    jsr mul48
    jsr rsh9            ; mA = imp
    lda cnx             ; dvx = (imp * nx) >> 16 ; i.vx -= dvx ; j.vx += dvx (imp >= 0: nx's sign)
    sta mB
    lda cnx+1
    sta mB+1
    lda cnx+2
    sta mB+2
    jsr mul48
    MSIGN sgnx
    ldx ci
    ldy cj
    sec
    lda VX0,x
    sbc sP
    sta VX0,x
    lda VX1,x
    sbc sP+1
    sta VX1,x
    lda VX2,x
    sbc sP+2
    sta VX2,x
    clc
    lda VX0,y
    adc sP
    sta VX0,y
    lda VX1,y
    adc sP+1
    sta VX1,y
    lda VX2,y
    adc sP+2
    sta VX2,y
    lda cny             ; dvy = (imp * ny) >> 16  (mA = imp still)
    sta mB
    lda cny+1
    sta mB+1
    lda cny+2
    sta mB+2
    jsr mul48r
    MSIGN sgny
    ldx ci
    ldy cj
    sec
    lda VY0,x
    sbc sP
    sta VY0,x
    lda VY1,x
    sbc sP+1
    sta VY1,x
    lda VY2,x
    sbc sP+2
    sta VY2,x
    clc
    lda VY0,y
    adc sP
    sta VY0,y
    lda VY1,y
    adc sP+1
    sta VY1,y
    lda VY2,y
    adc sP+2
    sta VY2,y
    lda AWK,y           ; cj was asleep: woken -- next tick's tick_all takes it (wkl);
    bne aw              ;   it moved not this tick: MV 0 (another contact of the tick)
    sta MVX0,y
    sta MVX1,y
    sta MVX2,y
    sta MVY0,y
    sta MVY1,y
    sta MVY2,y
    tya
    ldx wkn
    sta wkl,x
    inc wkn
    ldx ci
aw:
    lda #1              ; velocities changed: both awake now, renorm deferred
    sta AWK,x           ; (X = ci, Y = cj still)
    sta AWK,y
    sta NEEDRN,x
    sta NEEDRN,y
    lda X2,x            ; ci moved: refresh its cached high bytes
    sta cxh
    lda Y2,x
    sec
    sbc #4
    sta cyl
    lda fcj             ; ($FD: the first contact, undone, goes again now)
    cmp #$FD
    beq redo
    rts
redo:                   ; the first contact again: its ball and normal back in cj / cn, from the
    ldy fj1             ;   velocities as they are now (seq)
    sty cj
    ldx #2
rd: lda fnx,x
    sta cnx,x
    lda fny,x
    sta cny,x
    dex
    bpl rd
    lda fsx
    sta sgnx
    lda fsy
    sta sgny
    jmp seq

; two: ball i's second contact of the sweep (j2 = cj; the first j1 = fcj, its normal
; n1 and closing speed a1 kept): struck at once, the impulses solve (e = 1)
;   2 J1 + c J2 = 2 a1,  c J1 + 2 J2 = 2 a2,  c = n1 . n2
; J1 = (4 a1 - 2 c a2) / (4 - c^2), J2 = (4 a2 - 2 c a1) / (4 - c^2); one below 0 is
; not struck at all (J = 0, the other gets its a).  The first was applied as a1:
; its correction J1 - a1 goes along n1 here, then J2 along n2 as any contact (app).
two:
    sec                 ; the two contacts' times in the tick (rewind: 1/64 back from
    lda fft             ;   its end) within SIMUL of each other: struck at once -> the
    sbc rft             ;   joint solve (jt); else in turn: this one's closing speed
    bcs tp              ;   from the velocities as they are now, after the first
    eor #$FF
    adc #1
tp: cmp #SIMUL
    jcs ord             ; (apart in time: in turn -- out of line, past the joint solve)
jt: lda #$FE            ; (the two solved: later contacts of the sweep alone)
    sta fcj
    ldx #2              ; a2 -> cacc (mA is mul48's)
t0: lda mA,x
    sta cacc,x
    dex
    bpl t0
    ldx #2              ; cc = s |n1x| |n2x| + s |n1y| |n2y|  (Q16 Q16 >> 16 = Q16)
t1: lda fnx,x
    sta mA,x
    lda cnx,x
    sta mB,x
    dex
    bpl t1
    jsr mul48
    lda fsx
    eor sgnx
    sta csgn
    MSIGN csgn
    ldx #2
t2: lda sP,x
    sta cc,x
    lda fny,x
    sta mA,x
    lda cny,x
    sta mB,x
    dex
    bpl t2
    jsr mul48
    lda fsy
    eor sgny
    sta csgn
    MSIGN csgn
    clc
    lda cc
    adc sP
    sta cc
    lda cc+1
    adc sP+1
    sta cc+1
    lda cc+2
    adc sP+2
    sta cc+2
    jsr cabs            ; cden = 4 - c^2 (Q16; c^2 = |c| |c| >> 16 <= 1)
    ldx #2
t3: lda mA,x
    sta mB,x
    dex
    bpl t3
    jsr mul48
    jsr rsh16
    sec
    lda #0
    sbc sP
    sta cden
    lda #0
    sbc sP+1
    sta cden+1
    lda #4
    sbc sP+2
    sta cden+2
    jsr cabs            ; J1 = (4 a1 - 2 (c a2 >> 16)) / cden
    ldx #2
t4: lda cacc,x
    sta mB,x
    dex
    bpl t4
    jsr mul48
    MSIGN csgn          ; sP = c a2 (Q12, signed)
    ldx #2
t5: lda fa,x
    sta mA,x
    dex
    bpl t5
    jsr numj
    sec                 ; cj1 = J1 - a1
    lda mQ
    sbc fa
    sta cj1
    lda mQ+1
    sbc fa+1
    sta cj1+1
    lda mQ+2
    sbc fa+2
    sta cj1+2
    jsr cabs            ; J2 = (4 a2 - 2 (c a1 >> 16)) / cden
    ldx #2
t6: lda fa,x
    sta mB,x
    dex
    bpl t6
    jsr mul48
    MSIGN csgn
    ldx #2
t7: lda cacc,x
    sta mA,x
    dex
    bpl t7
    jsr numj            ; (J2 waits in mQ: nothing below touches it)
cor:
    ldx #2              ; the first's correction: mA = |cj1|, nt = its sign
t8: lda cj1,x
    sta mA,x
    dex
    bpl t8
    lda cj1+2
    sta nt
    bpl c1p
    sec
    lda #0
    sbc cj1
    sta mA
    lda #0
    sbc cj1+1
    sta mA+1
    lda #0
    sbc cj1+2
    sta mA+2
c1p:
    lda #$F3            ; imp1 = (499 |cj1|) >> 9, along n1 (its signs eor cj1's)
    sta mB
    lda #$01
    sta mB+1
    lda #$00
    sta mB+2
    jsr mul48
    jsr rsh9            ; mA = the correction
    lda fnx
    sta mB
    lda fnx+1
    sta mB+1
    lda fnx+2
    sta mB+2
    jsr mul48
    lda fsx
    eor nt
    sta csgn
    MSIGN csgn
    ldx ci
    ldy fj1
    sec
    lda VX0,x
    sbc sP
    sta VX0,x
    lda VX1,x
    sbc sP+1
    sta VX1,x
    lda VX2,x
    sbc sP+2
    sta VX2,x
    clc
    lda VX0,y
    adc sP
    sta VX0,y
    lda VX1,y
    adc sP+1
    sta VX1,y
    lda VX2,y
    adc sP+2
    sta VX2,y
    ldx #2              ; (mA = imp1 still)
ta: lda fny,x
    sta mB,x
    dex
    bpl ta
    jsr mul48
    lda fsy
    eor nt
    sta csgn
    MSIGN csgn
    ldx ci
    ldy fj1
    sec
    lda VY0,x
    sbc sP
    sta VY0,x
    lda VY1,x
    sbc sP+1
    sta VY1,x
    lda VY2,x
    sbc sP+2
    sta VY2,x
    clc
    lda VY0,y
    adc sP
    sta VY0,y
    lda VY1,y
    adc sP+1
    sta VY1,y
    lda VY2,y
    adc sP+2
    sta VY2,y
    ldx #2              ; the second as any contact: mA = J2 (or a2)
tb: lda mQ,x
    sta mA,x
    dex
    bpl tb
    jmp app
ord:
    lda fft             ; which came first?  the first (fft >= rft): this one goes
    cmp rft             ;   second, from the velocities as they are now (seq)
    bcs seq
    ldx #2              ; this one did: the first undone (-a1 along n1: cor), this one from
u1: lda mA,x            ;   the MVs (app), then the first again (redo, fcj $FD) -- a2 waits in mQ
    sta mQ,x
    dex
    bpl u1
    sec
    lda #0
    sbc fa
    sta cj1
    lda #0
    sbc fa+1
    sta cj1+1
    lda #0
    sbc fa+2
    sta cj1+2
    lda #$FD
    sta fcj
    jmp cor
seq:
    ldx ci
    ldy cj
    lda VX0,x
    sta wiv
    lda VX1,x
    sta wiv+1
    lda VX2,x
    sta wiv+2
    lda VY0,x
    sta wiv+3
    lda VY1,x
    sta wiv+4
    lda VY2,x
    sta wiv+5
    lda VX0,y
    sta rvj
    lda VX1,y
    sta rvj+1
    lda VX2,y
    sta rvj+2
    lda VY0,y
    sta rvj+3
    lda VY1,y
    sta rvj+4
    lda VY2,y
    sta rvj+5
    jsr dotv
    lda sP+2            ; parting already: nothing (the separation stands)
    bmi sq0
    ora sP+1
    ora sP
    beq sq0
    ldx #2
ts: lda sP,x
    sta mA,x
    dex
    bpl ts
    lda #$FE
    sta fcj
    jmp app
sq0:
    rts

; dotv: sP[0..2] = rvn = ((wiv.x - rvj.x) nx + (wiv.y - rvj.y) ny) >> 16 (Q12): the
; closing speed along the normal, from the two velocities in wiv (i's) and rvj (j's)
dotv:
    sec                 ; mA = |i.wx - j.wx| ; csgn bit 7 = sign of the product
    lda wiv
    sbc rvj
    sta mA
    lda wiv+1
    sbc rvj+1
    sta mA+1
    lda wiv+2
    sbc rvj+2
    sta mA+2
    eor sgnx
    sta csgn
    lda mA+2
    bpl vxp
    sec
    lda #0
    sbc mA
    sta mA
    lda #0
    sbc mA+1
    sta mA+1
    lda #0
    sbc mA+2
    sta mA+2
vxp:
    lda cnx
    sta mB
    lda cnx+1
    sta mB+1
    lda cnx+2
    sta mB+2
    jsr mul48
; [2026-10-27 drac030-review/SKILL.md carry chains; 6502-idioms/SKILL.md negate with a known
;  carry] S = s1 P1 + s2 P2 by the signs: P1 kept as it is (no 6-byte negate), the sum or the
;  difference in 5 bytes (rsh16 / rsh16n read bytes 0..4; P < 2^36), -(P1 + P2) by rsh16n
    lda csgn            ; s1 -> cacc+5, P1 -> cacc (5 bytes)
    sta cacc+5
    lda mP
    sta cacc
    lda mP+1
    sta cacc+1
    lda mP+2
    sta cacc+2
    lda mP+3
    sta cacc+3
    lda mP+4
    sta cacc+4
cdone:                  ; (the y term)
    sec                 ; mA = |i.wy - j.wy|
    lda wiv+3
    sbc rvj+3
    sta mA
    lda wiv+4
    sbc rvj+4
    sta mA+1
    lda wiv+5
    sbc rvj+5
    sta mA+2
    eor sgny
    sta csgn
    lda mA+2
    bpl vyp
    sec
    lda #0
    sbc mA
    sta mA
    lda #0
    sbc mA+1
    sta mA+1
    lda #0
    sbc mA+2
    sta mA+2
vyp:
    lda cny
    sta mB
    lda cny+1
    sta mB+1
    lda cny+2
    sta mB+2
    jsr mul48           ; sP = P2
    lda cacc+5
    eor csgn
    bmi dif
    clc                 ; the same signs: sP = P1 + P2, then +- by s2
    lda cacc
    adc sP
    sta sP
    lda cacc+1
    adc sP+1
    sta sP+1
    lda cacc+2
    adc sP+2
    sta sP+2
    lda cacc+3
    adc sP+3
    sta sP+3
    lda cacc+4
    adc sP+4
    sta sP+4
    bit csgn
    bmi nsum
    jmp rsh16           ; sP[0..2] = rvn
nsum:
    jmp rsh16n          ; -(P1 + P2)
dif:
    bit csgn
    bmi p1m             ; s2 < 0 (s1 > 0): P1 - P2
    sec                 ; s1 < 0: P2 - P1
    lda sP
    sbc cacc
    sta sP
    lda sP+1
    sbc cacc+1
    sta sP+1
    lda sP+2
    sbc cacc+2
    sta sP+2
    lda sP+3
    sbc cacc+3
    sta sP+3
    lda sP+4
    sbc cacc+4
    sta sP+4
    jmp rsh16
p1m:
    sec
    lda cacc
    sbc sP
    sta sP
    lda cacc+1
    sbc sP+1
    sta sP+1
    lda cacc+2
    sbc sP+2
    sta sP+2
    lda cacc+3
    sbc sP+3
    sta sP+3
    lda cacc+4
    sbc sP+4
    sta sP+4
    jmp rsh16

; cabs: mA = |cc|, csgn = cc's sign (bit 7)
cabs:
    lda cc+2
    sta csgn
    bpl cp
    sec
    lda #0
    sbc cc
    sta mA
    lda #0
    sbc cc+1
    sta mA+1
    lda #0
    sbc cc+2
    sta mA+2
    rts
cp: lda cc
    sta mA
    lda cc+1
    sta mA+1
    lda cc+2
    sta mA+2
    rts

; numj: mQ = J = (4 mA - 2 sP) / cden, 0 when that is below 0 (mA = a > 0, sP = c a'
; signed, |sP| <= a': 4 a - 2 sP < 2^20).  div16r takes a dividend whose top 32 bits
; are <= the divisor: (num >> 2) << 16 / cden (num / 4 < 2^18 <= cden), then << 2.
numj:
    asl mA
    rol mA+1
    rol mA+2
    asl mA
    rol mA+1
    rol mA+2
    asl sP
    rol sP+1
    rol sP+2
    sec
    lda mA
    sbc sP
    sta mA
    lda mA+1
    sbc sP+1
    sta mA+1
    lda mA+2
    sbc sP+2
    bmi nz
    lsr @               ; mA+2..4 = num >> 2, mA..mA+1 = 0 (mA+5 is 0: rem's top)
    ror mA+1
    ror mA
    lsr @
    ror mA+1
    ror mA
    sta mA+4
    lda mA+1
    sta mA+3
    lda mA
    sta mA+2
    lda #0
    sta mA
    sta mA+1
    sta mA+5
    ldx #2
nd: lda cden,x
    sta mB,x
    dex
    bpl nd
    jsr div16r
    asl mQ
    rol mQ+1
    rol mQ+2
    asl mQ
    rol mQ+1
    rol mQ+2
    rts
nz: lda #0
    sta mQ
    sta mQ+1
    sta mQ+2
    rts
.endp

; (cdl, wkl: math.asm, before div16r's page -- read cdl-1,x / wkl-1,y in one page)
