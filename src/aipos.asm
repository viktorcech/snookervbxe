; aipos.asm -- the computer player's position play: what a leave is worth (pscore)
; and the cannon that frees a tied ball (cnset, cannon).  A 4 KB image in
; V:AI3_BANK000, the third 4 KB of the AI's 16 KB window (win_ai): aiv.asm's ppev
; and ai2.asm's kset / kplay call it, it calls aiv.asm, as one program.
;
; The leave (Davis, Successful Snooker: Planning; White, Snooker Masterclass ch. 2,
; 4, 5, 7; EBSA): kplay plays each pot PV_N ways in the game's physics (ptry);
; where the balls really stop, ppev finds the easiest next pot (nx_eval: the run,
; the cut -- a half to three-quarter ball is position, thinner is not) and pscore
; adds the rest:
;   another ball down: a foul (but a second red on a red) -- the shot is out;
;   a ball moved that the shot did not mean to: a colour off its spot +2048, a red
;     +512 (a clean leave, mildly: opening a pack on the way is no crime);
;   tight on a cushion (within 48 mm, as hop_test's): the cue raised, +2048;
;   under 96 mm from the next ball: no room to cue, +2048;
; [2026-10-27: the leave in mid-game was judged by the wrong things -- the cue ball
;  closer than 256 mm to the next ball and every ball within 160 mm added +2048 each,
;  a red moved +2048, as much as a metre-long pot: a close straight red measured like
;  a long one and the AI left itself long pots.  Now near IS position: only the
;  tight cases above count, a red moved adds 512, a colour 2048]
;   on the wrong side of the next ball (potting it sends the cue ball away from
;     the ball after it: after a red the reds' middle, after a colour the black):
;     +1024;
;   the shot itself: side +512, full screw / follow +256, the speed 12/8 of the
;     pot's +256, 18/8 and over +512 (plain ball at a gentle pace: the surest leave);
;   the cannon's own shot (cannon, when nothing else is on): a tied ball freed
;     (cnset's cntd) -2048 each -- White ch. 5, Davis: cannon the awkward balls
;     into play; any other shot counts the balls it disturbs as above.
; [2026-10-27 the pack (Davis: break it up early, off a colour, and pot the colour;
;  White ch. 5, 7): cnset finds the pack closed (cnsp / cnst: at most one red with a clear
;  pocket, two or more tied).  A colour then (cnsp): every variant counts the tied
;  reds it frees -2048 each, and round 1 tries 3 harder ways (pvk 26).  A red then
;  (cnst): the leave on a colour over ~1.2 m from the pack +1024, the wrong side of
;  it +2048 -- position on the black / pink from which the colour pot splits them.
;  Before: the AI potted the colour plain, had no red and played a soft safety into
;  the pack]
; [2026-10-26 6502-idioms/SKILL.md: code size is RAM -- the model runs from VRAM;
;  aiv.asm's cordic, trig, tmul, tload, nexton, smul8 do the arithmetic]
    org vbank               ; assembled for $4000 (the 3rd 4 KB of the AI's window),
    dta AI3_BANK-1          ;   staged at $2000, copied to V:AI3_BANK000 by vram_next
    org $4000,$2000

; pscore (ppev's end): the table as the sim stopped, sev = the next pot's ease from
; the cue ball (scx, scy: Q4; $E000 on: none) -> sev as above
.proc pscore
    ldx #NB-1               ; the balls besides bt: down, moved
    ldy #0                  ; (Y: the tied balls freed)
bl:
    cpx bt
    beq bn
    lda BON,x
    bne on
    lda ppx,x               ; off now: was it on?  (a ball off sits at X2 $FF)
    cmp #$FF
    beq bn
    cpx #16                 ; a colour down, or any ball on a colour: a foul
    bcs foul
    lda onk
    bne foul
    beq bn                  ; (always: a second red on a red)
on:
    lda X2,x                ; its 16 mm place as before the shot (ppx, ppy)?
    cmp ppx,x
    bne mv
    lda Y2,x
    cmp ppy,x
    beq bn
mv:
    lda cnplay              ; the cannon's own shot (cannon), or a colour with the pack
    ora cnsp                ;   closed (cnsp): a tied ball freed is counted; any other
    beq pr                  ;   shot counts it like every ball it disturbs
    lda cntd,x
    beq pr
    iny
    bne bn                  ; (always)
pr:
    lda #$08                ; a colour off its spot +2048, a red moved +512
    cpx #16
    bcs pa
    lda #$02
pa:
    jsr padd
bn:
    dex
    bne bl
    beq cr0                 ; (always: X = 0)
foul:
    lda #$FF                ; (out of line here: the loop's branches reach it)
    sta sev
    sta sev+1
    rts
cr0:
    sty cnn
    lda scx+1               ; tight on a cushion: the centre within 48 mm (Q4 high
    cmp #3                  ;   bytes, 16 mm; the bounds hop_test's)
    bcc cu
    cmp #220
    bcs cu
    lda scy+1
    cmp #3
    bcc cu
    cmp #108
    bcc nc
cu:
    lda #$08
    jsr padd
nc:
    ldy #0                  ; [2026-10-27] in the pack: two reds or more within 64 mm both
    ldx #15                 ;   ways of the cue ball (16 mm units) +4096 -- a split that
pk:                         ;   left the cue ball among the reds (rozbitie.png)
    lda BON,x
    beq pn
    lda X2,x
    sec
    sbc scx+1
    bcs p1
    eor #$FF
    adc #1                  ; (C = 0)
p1:
    cmp #5
    bcs pn
    lda Y2,x
    sec
    sbc scy+1
    bcs p2
    eor #$FF
    adc #1
p2:
    cmp #5
    bcs pn
    iny
pn:
    dex
    bne pk
    cpy #2
    bcc np
    lda #$10
    jsr padd
np:
    lda sev+1               ; no pot from there: pclose's (nothing to be the side of)
    cmp #$E0
    jcs own
    ldy nxbi                ; under 96 mm from the next ball: no room to cue (+2048) --
    lda scx+1               ;   |dx| + |dy| in 32 mm units < 3
    lsr @
    sec
    sbc nxe,y
    bcs a1
    eor #$FF
    adc #1                  ; (C = 0)
a1:
    sta pmx
    lda scy+1
    lsr @
    sec
    sbc nxe+1,y
    bcs a2
    eor #$FF
    adc #1
a2:
    clc
    adc pmx
    cmp #3
    bcs fa
    lda #$08
    jsr padd
fa:
    ldx bt                  ; F, the ball after the next: after a red the reds' box,
    cpx #16                 ;   its middle (32 mm units); after a colour the black
    bcs fb
    lda #$FF
    sta pfx
    sta pfy
    lda #0
    sta pmx
    sta pmy
    ldx #15
rl:
    lda BON,x
    beq rn
    lda X2,x
    cmp pfx
    bcs n1
    sta pfx
n1:
    cmp pmx
    bcc n2
    sta pmx
n2:
    lda Y2,x
    cmp pfy
    bcs n3
    sta pfy
n3:
    cmp pmy
    bcc rn
    sta pmy
rn:
    dex
    bne rl
    lda pmx                 ; no red left: nothing to go to
    cmp pfx
    jcc own
    clc
    lda pfx
    adc pmx
    ror @
    lsr @
    sta pfx
    clc
    lda pfy
    adc pmy
    ror @
    lsr @
    sta pfy
    jmp dt
fb:
    lda BON+21              ; a colour potted: the black, if there
    jeq own                 ; (dt grew: out of range)
    lda X2+21
    lsr @
    sta pfx
    lda Y2+21
    lsr @
    sta pfy
dt:
    ldx cnst                ; the pack to be opened from the next colour (cnst: bt a
    beq d0                  ;   red): one over ~1.2 m from it (|dx| + |dy|, 32 mm
    ldy nxbi                ;   units) +1024
    sec
    lda pfy
    sbc nxe+1,y
    bcs d1
    eor #$FF
    adc #1                  ; (C = 0)
d1:
    sta pst
    sec
    lda pfx
    sbc nxe,y
    bcs d2
    eor #$FF
    adc #1
d2:
    adc pst                 ; (C = 0 both ways: a negated difference is never 0)
    cmp #38
    bcc d0
    lda #$04
    jsr padd
d0:
    ldy nxbi                ; a = the next ball - the cue ball, b = F - the next ball:
    lda scx+1               ;   a . b < 0: the wrong side (+1024)
    lsr @
    sta pmx
    lda scy+1
    lsr @
    sta pmy
    sec
    lda pfx
    sbc nxe,y
    tax
    sec
    lda nxe,y
    sbc pmx
    jsr smul8               ; ax bx
    sta pmx
    stx pmy
    ldy nxbi
    sec
    lda pfy
    sbc nxe+1,y
    tax
    sec
    lda scy+1
    lsr @
    sta pst
    lda nxe+1,y
    sbc pst
    jsr smul8               ; ay by
    clc
    adc pmx
    txa
    adc pmy
    bpl own
    lda cnst                ; +1024; +2048 when the pack is to be opened from that
    asl @                   ;   colour (cnst 0 / 1 -> 0 / 4, C = 0)
    asl @
    adc #$04
    jsr padd
own:
    lda sside               ; the shot itself: side +512
    cmp #4
    beq s0
    lda #2
    jsr padd
s0:
    lda sspin               ; full screw / follow +256
    beq s1
    cmp #8
    bne s2
s1:
    lda #1
    jsr padd
s2:
    lda pck                 ; the speed: 12/8 +256, 18/8 and over +512
    cmp #9
    bcc s3
    lda #1
    ldx pck
    cpx #13
    bcc s4
    lda #2
s4:
    jsr padd
s3:
    lda cnn                 ; the tied balls freed: 2048 each off (0 at least)
    beq r
    asl @                   ; (at most 21 * 8)
    asl @
    asl @
    eor #$FF                ; sev+1 - it = sev+1 + ~it + 1
    sec
    adc sev+1
    bcs ok
    lda #0
    sta sev
ok:
    sta sev+1
r:
    rts
.endp

; smoved (sim_shot's end, a safety: the table as it stopped): smv = the balls besides
; the cue and the one played (sat) that moved (their 16 mm place against ppx / ppy,
; ai_safe's copy) -- a safety that opens the balls up hands the opponent chances
.proc smoved
    ldy #0
    ldx #NB-1
l:
    cpx sat
    beq n
    lda BON,x
    beq n
    lda X2,x
    cmp ppx,x
    bne mv
    lda Y2,x
    cmp ppy,x
    beq n
mv:
    iny
n:
    dex
    bne l
    sty smv
    rts
.endp

; lsafe (s3pick, sftry: a safety's leave at0 from leavep and psnk, 1/8 mm): the balls
; it disturbed take 256 mm each off (1 at least: 0 reads as never); the ball played down
; as well: + 500 mm (it is down, and our shot next -- not the $FFFF it was: the cue ball
; then ran anywhere)
.proc lsafe
    lda smv
    beq pt
    asl @                   ; (at most 20 * 8)
    asl @
    asl @
    eor #$FF                ; at0+1 - it = at0+1 + ~it + 1
    sec
    adc at0+1
    bcs ok
    lda #1                  ; below 0: 1
    sta at0
    lda #0
ok:
    sta at0+1
pt:
    lda soon
    bne r
    clc
    lda at0
    adc #<4000
    sta at0
    lda at0+1
    adc #>4000
    bcc o2
    lda #$FF
    sta at0
o2:
    sta at0+1
r:
    rts
.endp

; padd: sev += A * 256 (saturating).  Keeps X, Y.
.proc padd
    clc
    adc sev+1
    bcc ok
    lda #$FF
    sta sev
ok:
    sta sev+1
    rts
.endp

; cnset (kset's end: the pot bt set up, nxe built): the balls on next (nexton) that
; are TIED -- no clear way to any pocket (not in nxe) or on a cushion (within 64 mm
; of a rail: along it only) -> cntd; the nearest to bt is the cannon's target F
; (cfx, cfy: 16 mm units), cnon = 1; none tied: 0.  kplay: a pot whose best leave is
; then beyond his nerve is also tried as a cannon off bt into F (cannon).
.proc cnset
    ldy #0
    sty cnon
    sty cnf
    sty cnsp
    sty cnst
    ldx #15                 ; the pack closed: the reds left but bt, less the free ones
rl:                         ;   (cnfr: kset), >= 2 tied and at most one free.  bt a
    cpx bt                  ;   colour: the split is this shot's (cnsp); a red: the
    beq rn                  ;   leave sets it up (cnst)
    lda BON,x
    beq rn
    iny
rn:
    dex
    bne rl
    tya
    sec
    sbc cnfr
    cmp #2
    bcc nd
    lda cnfr
    cmp #2
    bcs nd
    ldx bt
    cpx #16
    bcs sc
    inc cnst
    bcc nd                  ; (always)
sc:
    inc cnsp
nd:
    lda cnsp                ; round 1's ways: PV_N, 3 harder ones more for the split
    asl @                   ;   (pvs, pvk; C = 0 after the asl of 0 / 1)
    adc cnsp
    adc #PV_N
    sta pvn
    lda #$FF
    sta cnd                 ; the nearest tied ball's |dx| + |dy| so far
    ldx bt
    lda X2,x
    sta cnsx
    lda Y2,x
    sta cnsy
    lda nxn                 ; the list's end: nxn * 6
    asl @
    adc nxn                 ; (C = 0: nxn <= 40)
    asl @
    sta cnln
    ldx #NB-1
l:
    lda #0
    sta cntd,x
    cpx bt
    beq n
    lda BON,x
    beq n
    jsr nexton              ; on after this pot?  (keeps X)
    bcc n
    jsr cntied              ; tied?
    bcc n
    inc cntd,x              ; (0 -> 1)
                            ; (C = 1: the bcc not taken) |dx| + |dy| from bt (16 mm units, saturating)
    lda X2,x
    sbc cnsx
    bcs a1
    eor #$FF
    adc #1                  ; (C = 0)
a1:
    sta cnu
    sec
    lda Y2,x
    sbc cnsy
    bcs a2
    eor #$FF
    adc #1
a2:
    clc
    adc cnu
    bcc a3
    lda #$FF
a3:
    cmp cnd                 ; the nearest so far: the target
    bcs n
    sta cnd
    lda X2,x
    sta cfx
    lda Y2,x
    sta cfy
    ldy #1
    sty cnon
n:
    dex
    bne l
    rts
.endp

; cntied: X = a ball -> C = 1 when it is tied: on a cushion (within 64 mm of a rail),
; or not in nxe (no clear way to any pocket).  Keeps X.
.proc cntied
    lda X2,x
    cmp #5
    bcc td
    cmp #219
    bcs td
    lda Y2,x
    cmp #5
    bcc td
    cmp #107
    bcs td
    lda X2,x                ; its 32 mm place, against the list's entries
    lsr @
    sta cnu
    lda Y2,x
    lsr @
    sta cnu+1
    ldy #0
e:
    cpy cnln
    bcs td                  ; not listed: tied
    lda nxe,y
    cmp cnu
    bne en
    lda nxe+1,y
    cmp cnu+1
    beq no                  ; listed: it can be potted
en:
    tya
    clc
    adc #6
    tay
    bne e                   ; (always: < 240)
td:
    sec
    rts
no:
    clc
    rts
.endp

; cndiv: A = cnsx (16 bits) / cnd (the dividend < 256 x the divisor: a byte)
.proc cndiv
    ldy #8
    lda cnsx+1              ; the remainder; the quotient's bits enter the low byte
d:
    asl cnsx
    rol @
    bcs s                   ; (a 9th bit: over the divisor for sure)
    cmp cnd
    bcc c
s:
    sbc cnd                 ; (C = 1 both ways)
    inc cnsx
c:
    dey
    bne d
    lda cnsx
    rts
.endp

; cannon (kplay: cnon, the leave beyond his nerve): the pot as set up (bt, phi, tgt,
; edc, ppr) with the tip that sends the cue ball into the tied ball F (cnset).
; Off the object ball the cue ball keeps v sin(cut) along the tangent t (phi +- 90
; deg, its side) and its spin u = k v along the aim a = cos(cut) p + sin(cut) t (p:
; the pot's way); the slide ends at (5 v_t + 2 u) / 7: the turn from t towards p is
; atan(2 u cos / ((5 v + 2 u) sin)).  u at the contact from the tip and the run (edc)
; at 80 % power, 14 mm a tick: the slip (1 - k) v loses 0.18 mm/tick a tick, v 0.05
; (renorm; measured in the game: within 3 deg).  The tip 0, 2 .. 8 whose turn is
; nearest the one F asks for, within CN_TOL: ptry at pck = 1040 / ppr (pset 130, 2.8
; m/s), cnf = 1 when that is this pot's best; none near: no cannon.
CN_TOL  = 11                ; the turn allowed off: < 11 * 256 units (15.5 deg)
.proc cannon
    ldx bt
    jsr tload               ; T
    sec                     ; F - T (Q4) -> cordic: e = the way to F - the pot's
    lda #0
    sbc tx
    sta cx
    lda cfx
    sbc tx+1
    sta cx+1
    lda #0
    sbc #0
    sta cx+2
    sec
    lda #0
    sbc ty
    sta cy
    lda cfy
    sbc ty+1
    sta cy+1
    lda #0
    sbc #0
    sta cy+2
    jsr cordic
    sec
    lda cz
    sbc phi
    sta cne
    lda cz+1
    sbc phi+1
    sta cne+1
    sec                     ; cut = tgt - phi -> |cut| in cz; cut < 0: t = phi - 90 and
    lda tgt                 ;   towards p is +, so e is negated for the one formula
    sbc phi
    sta cz
    lda tgt+1
    sbc phi+1
    sta cz+1
    bpl cp
    sec
    lda #0
    sbc cz
    sta cz
    lda #0
    sbc cz+1
    sta cz+1
    sec
    lda #0
    sbc cne
    sta cne
    lda #0
    sbc cne+1
    sta cne+1
cp:
    sec                     ; dw = 90 deg - e: the turn from t towards p F asks for
    lda #0
    sbc cne
    sta cndw
    lda #$40
    sbc cne+1
    sta cndw+1
    jsr trig                ; cos, sin of |cut| (btr, btr+3)
    lda edc                 ; T = 19 edc ticks to the contact (edc <= 13: a byte)
    asl @
    sta cnv
    asl @
    asl @
    asl @
    adc cnv                 ; (C = 0: 16 edc < 256)
    adc edc                 ; (C = 0: 18 edc < 256)
    sta cn3t
    lsr @                   ; v = 224 + T/8 - T (Q4 mm/tick: 8 .. 224)
    lsr @
    lsr @
    clc
    adc #224
    sec
    sbc cn3t
    sta cnv
    lda #0                  ; 3 T (16 bits)
    sta cn3t+1
    lda cn3t
    asl @
    rol cn3t+1              ; (C = 0: the byte was 0)
    adc cn3t
    sta cn3t
    bcc t3
    inc cn3t+1
t3:
    lda #$FF
    sta cnbe                ; the best tip's turn error: none yet
    ldx #4                  ; the tips 8, 6 .. 0 (cns0: their slip at the strike)
tl:
    stx cni
    sec                     ; s = s0 - 3 T, 0 at least: the slip at the contact
    lda cns0l,x
    sbc cn3t
    tay
    lda cns0h,x
    sbc cn3t+1
    bcs s1
    lda #0
    tay
s1:
    sta cnsc+1
    sty cnsc
    lda cnv                 ; 5 v -> cnwt
    ldy #0
    sty cnwt+1
    asl @
    rol cnwt+1
    asl @
    rol cnwt+1              ; (C = 0: the high byte was 0 or 1)
    adc cnv
    sta cnwt
    bcc w1
    inc cnwt+1
w1:
    sec                     ; 2 u = 2 (v - s), signed (cold: the shift in place is the
    lda cnv                 ;   smaller form)
    sbc cnsc
    sta cnu
    lda #0
    sbc cnsc+1
    asl cnu
    rol @
    sta cnu+1
    clc                     ; wt = 5 v + 2 u (> 0: 5 v > 2 s always) -> A:X
    lda cnwt
    adc cnu
    tay
    lda cnwt+1
    adc cnu+1
    tax
    tya
    ldy #3                  ; wt sin -> cx
    jsr tmul
    lda sP
    sta cx
    lda sP+1
    sta cx+1
    lda #0
    sta cx+2
    lda cnu                 ; |2 u| cos -> cy with u's sign
    ldx cnu+1
    bpl up
    sec
    lda #0
    sbc cnu
    tay
    lda #0
    sbc cnu+1
    tax
    tya
up:
    ldy #0
    jsr tmul
    bit cnu+1
    bmi ng
    lda sP
    sta cy
    lda sP+1
    sta cy+1
    lda #0
    beq cz2                 ; (always)
ng:
    sec
    lda #0
    sbc sP
    sta cy
    lda #0
    sbc sP+1
    sta cy+1
    lda #0
    sbc #0
cz2:
    sta cy+2
    jsr cordic              ; cz = this tip's turn from t towards p
    sec                     ; |cz - dw|'s high byte (the complement is near enough)
    lda cz
    sbc cndw
    lda cz+1
    sbc cndw+1
    bpl ab
    eor #$FF
ab:
    cmp cnbe                ; the nearest so far?
    bcs tn
    sta cnbe
    lda cni
    sta cnbt
tn:
    ldx cni
    dex
    jpl tl
    lda cnbe
    cmp #CN_TOL
    bcs out                 ; F out of the cue ball's reach: no cannon
    lda #<1040              ; the speed code: 1040 / ppr -> ppw's pset(130), 80 % power
    sta cnsx
    lda #>1040
    sta cnsx+1
    lda ppr
    sta cnd
    jsr cndiv
    tay
    lda cnbt                ; the tip: 2 x its index; the side: the centre
    asl @
    ldx #4
    inc cnplay              ; (pscore: this shot means to free the tied balls)
    jsr ptry
    dec cnplay
    lda pbk                 ; this pot's best now (its code and tip): cnf (kplay: no
    cmp pck                 ;   round 2 of hard shots round it when it is chosen)
    bne out
    lda pbt
    cmp sspin
    bne out
    inc cnf                 ; (0 -> 1)
out:
    rts
cns0l   dta <504, <364, <224, <84, <0  ; the slip at the strike by the tip (Q4 mm/tick at
cns0h   dta >504, >364, >224, >84, >0  ;   14 mm/tick = 224): (1 - k) 224, k = (tip - 4) 5/16
.endp                                  ;   (the follow's over-roll is gone by the contact)

; the cells
pfx     dta 0               ; pscore: F (the ball after the next), its box, temps
pfy     dta 0
pmx     dta 0
pmy     dta 0
pst     dta 0
cnn     dta 0               ;   the tied balls the shot freed
smv     dta 0               ; smoved: the balls a safety's sim disturbed
cnon    dta 0               ; 1: a tied ball to free (cnset)
cnfr    dta 0               ; the reds but bt with a clear pocket (kset: nx_build 2)
cnsp    dta 0               ; 1: the pack must be opened (<= 1 free red, >= 2 tied) by this
cnst    dta 0               ;   colour: freed tied reds are counted for it; 1: ... after this red:
                            ;   the leave on a colour near the pack (cnset)
cnplay  dta 0               ; 1: the shot in the physics is the cannon's (pscore counts the tied balls it frees)
cnf     dta 0               ; 1: the cannon is this pot's best variant
kcn     dta 0               ; 1: ... and that pot chosen (kplay: no round 2)
cfx     dta 0               ; F: the cannon's target, 16 mm units
cfy     dta 0
cntd    :NB dta 0           ; 1: tied (on next, no clear pocket or on a cushion)
cnsx    dta 0, 0            ; cnset: bt's place (16 mm); cannon: cndiv's dividend
cnsy    dta 0
cnd     dta 0               ; cnset: the nearest tied ball's distance; cndiv's divisor
cnln    dta 0               ; nxe's end (nxn * 6)
cne     dta 0, 0            ; cannon's cells: the way to F - the pot's
cndw    dta 0, 0            ;   the turn from the tangent F asks for
cnv     dta 0               ;   v at the contact (Q4 mm/tick)
cn3t    dta 0, 0            ;   3 T: the slip lost by then
cnsc    dta 0, 0            ;   this tip's slip at the contact
cnwt    dta 0, 0            ;   5 v
cnu     dta 0, 0            ;   2 u (cnset: a 32 mm place, a distance)
cnbe    dta 0               ;   the best tip's turn error (high byte), its index
cnbt    dta 0
cni     dta 0

    ert *>$5000
    ini vram_next
