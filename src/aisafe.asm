; aisafe.asm -- the computer player's safety (in aiv.asm: V:AI_BANK).
; A safety (snooker.online): the cue ball left where the opponent has nothing --
; far from the balls he will be on, best on a cushion -- and the object ball no
; invitation (not by a pocket).  For every ball on that can be hit first (only
; balls on in the way: a legal shot), the object ball sent 15..75 deg either side
; of the straight line (cuts up to his ai_tth, 60..80 deg: thinner is a miss for
; his aim), at 6 powers: the cue ball deflects by ai_sdl from its
; line (the 30-degree rule, measured in the game physics) and runs ai_sg of what
; is left after the contact, the object ball ai_sh (cos^2); both folded off the
; cushions.  The best leave is chosen; none: the nearest ball on, firm.
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- in VRAM with the rest of the AI;
;  fall through (ert), one routine for the two vectors (ctot / gtoc)]

.proc ai_safe
    ldx #NB-1               ; the balls where they are (16 mm): smoved sees what a sim
pc:                         ;   disturbed (aipos.asm)
    lda X2,x
    sta ppx,x
    lda Y2,x
    sta ppy,x
    dex
    bpl pc
    inx
    stx smv                 ; (0)
    lda #0
    jsr nx_build            ; the opponent's pots, for the leaves
    lda #2                  ; first strict: the cue ball meets only T on its way (sapr
    sta sapr                ;   2); none: again with another ball on first allowed (1)
ps:
    jsr s3clr               ; the 3 best of this pass
    lda #0
    sta sbest
    sta sbest+1
    lda #$FF
    sta bt
    lda #1                  ; (blocked: balls on in the way are legal)
    sta blg
    ldx #NB-1
tl:
    stx at
    lda BON,x
    jeq tn
    jsr ison
    jcc tn
    lda X1,x                ; T
    sta tx
    lda X2,x
    sta tx+1
    lda Y1,x
    sta ty
    lda Y2,x
    sta ty+1
    jsr ctot                ; C -> T: cz, cd
    lda cz
    sta sa0
    sta bang
    lda cz+1
    sta sa0+1
    sta bang+1
    lda X1
    sta absx
    lda X2
    sta absx+1
    lda Y1
    sta absy
    lda Y2
    sta absy+1
    lda cd
    ldx cd+1
    jsr blocked
    jcs tn                  ; the first ball hit would not be on
    lda #9
    sta sk
kl:
    ldx sk                  ; psi = a0 +- (1..5) 15 deg
    clc
    lda sa0
    adc ai_skl,x
    sta psi
    sta cz
    lda sa0+1
    adc ai_skh,x
    sta psi+1
    sta cz+1
    jsr trig                ; G = T - 2R (cos, sin) psi
    lda #<AI_2R
    ldx #>AI_2R
    ldy #0
    jsr tmul
    sec
    lda tx
    sbc sP
    sta gx
    lda tx+1
    sbc sP+1
    sta gx+1
    lda #<AI_2R
    ldx #>AI_2R
    ldy #3
    jsr tmul
    sec
    lda ty
    sbc sP
    sta gy
    lda ty+1
    sbc sP+1
    sta gy+1
    jsr gtoc                ; C -> G: cz = the aim, cd
    lda cz
    sta aim
    lda cz+1
    sta aim+1
    sec                     ; theta = psi - aim
    lda psi
    sbc aim
    sta at0
    lda psi+1
    sbc aim+1
    sta ssg                 ; (bit 7: the side)
    bpl th
    sta at0+1
    sec
    lda #0
    sbc at0
    sta at0
    lda #0
    sbc at0+1
th:
    ldx aip                 ; |theta| over his limit: too thin for his aim (a miss
    cmp ai_tth-1,x          ;   is a foul)
    jcs kn
    clc                     ; i = round(|theta| / 15 deg): (hi + 5) * 3 / 32
    adc #5
    sta at0+1
    asl @
    adc at0+1
    lsr @
    lsr @
    lsr @
    lsr @
    lsr @
    sta ssi
    tax                     ; the cue ball: aim -+ delta (away from the object side)
    lda ssg
    bmi ng
    sec
    lda aim
    sbc ai_sdl,x
    sta cang
    lda aim+1
    sbc ai_sdh,x
    jmp cg
ng:
    clc
    lda aim
    adc ai_sdl,x
    sta cang
    lda aim+1
    adc ai_sdh,x
cg:
    sta cang+1
    lda #5
    sta spi
pl:
    ldx spi                 ; Da = D - dcg: what is left at the contact
    sec
    lda ai_sdd,x
    sbc cd
    sta sda
    lda ai_sddh,x
    sbc cd+1
    sta sda+1
    jcc pn                  ; (it never gets there)
    bne da0                 ; Da < AI_SDA0: it may stop short (the physics
    lda sda                 ;   rolls ~2 % less than 2.16 v^2) -- a miss, a foul
    cmp #AI_SDA0
    jcc pn
da0:
    ldx ssi                 ; the object ball: Da * h, from T along psi
    lda ai_sh,x
    jsr dmulb
    lda at0
    sta sdo
    lda at0+1
    sta sdo+1
    lda tx
    sta absx
    lda tx+1
    sta absx+1
    lda ty
    sta absy
    lda ty+1
    sta absy+1
    lda psi
    sta cz
    lda psi+1
    sta cz+1
    lda at0
    ldx at0+1
    jsr endpt
    lda ex
    sta oex
    lda ex+1
    sta oex+1
    lda ey
    sta oey
    lda ey+1
    sta oey+1
    ldx ssi                 ; the cue ball: Da * g, from G along cang
    lda ai_sg,x
    jsr dmulb
    lda gx
    sta absx
    lda gx+1
    sta absx+1
    lda gy
    sta absy
    lda gy+1
    sta absy+1
    lda cang
    sta cz
    lda cang+1
    sta cz+1
    lda at0
    ldx at0+1
    jsr endpt
    jsr leave               ; -> at0 (0: never)
    lsr at0+1               ; the model's guess at half: the ones sfscan played in the
    ror at0                 ;   physics come before it in the list (one a ball)
    lda s3r+16              ; better than the 3rd best so far?
    cmp at0
    lda s3r+17
    sbc at0+1
    jcs pn
    lda sapr                ; the third pass: no path checks (sim_shot shows them)
    beq si
    lda at0                 ; (blocked uses at0)
    pha
    lda at0+1
    pha
    jsr spath               ; the cue ball's two paths clear?
    pla
    sta at0+1
    pla
    sta at0
    jcs pn
si:
    jsr s3ins               ; among the 3 best: tried in the physics after
pn:
    dec spi
    jpl pl
kn:
    dec sk
    jpl kl
tn:
    ldx at
    dex
    jne tl
    lda #0
    sta blg
    jsr sfscan              ; + the thin safeties tried in the physics (ai2.asm)
    jsr s3pick              ; the best played in the physics: the real best
    ldx bt                  ; a safety found: its aim to 14 turns
    bpl fd
    lda sapr                ; none yet: the second pass (1), the third (0: the model's
    beq none                ;   leave alone, the physics judges them), then a roll-up
    lsr @
    sta sapr
    jmp ps
fd:
    ldy sbpsi               ; the one played: its aim (s3aim)
    jsr s3aim
    lda cz
    sta tgt
    lda cz+1
    sta tgt+1
    rts
none:
    lda #$FF                ; none: a roll-up onto the nearest ball on (D = d + 150 mm)
    sta best
    sta best+1
    ldx #NB-1
nl:
    stx at
    lda BON,x
    jeq nn
    jsr ison
    bcc nn
    lda X1,x
    sta tx
    lda X2,x
    sta tx+1
    lda Y1,x
    sta ty
    lda Y2,x
    sta ty+1
    jsr ctot
    lda cz                  ; key = d, + $8000 when the first ball hit would not be on
    sta bang
    lda cz+1
    sta bang+1
    lda X1
    sta absx
    lda X2
    sta absx+1
    lda Y1
    sta absy
    lda Y2
    sta absy+1
    lda #1
    sta blg
    lda cd
    ldx cd+1
    jsr blocked
    lda #0
    sta blg
    ror @
    ora cd+1
    tax
    lda cd
    cmp best
    txa
    sbc best+1
    bcs nn
    lda cd
    sta best
    stx best+1
    lda cd+1
    sta edc
    lda bang
    sta tgt
    lda bang+1
    sta tgt+1
nn:
    ldx at
    dex
    jne nl
    lda best+1              ; a ball on in sight: a roll-up onto it (snooker.online:
    bpl roll                ;   the cue ball left tight behind it; legal in snooker)
    jsr kick                ; snookered: off a cushion, if one gets there
    bcs hit
    lda best+1              ; (none: the nearest ball on all the same)
    and #$7F
    sta best+1
hit:
    lda #<700               ; firm: D = d + 700 mm
    ldy #>700
    bne ad                  ; (always)
roll:
    lda #150                ; the roll-up: D = d + 150 mm
    ldy #0
ad:
    clc
    adc best
    sta at0
    tya
    adc best+1
    tax
    lda at0
    jsr power
    lda ar
    jsr pset
    jmp kver                ; played in the physics first (ai2.asm)
.endp

; kick: snookered -- the shortest one-cushion escape onto a ball on (the WPBSA
; rules: the first ball hit must be on; a cushion first is legal): aimed at the
; ball mirrored in the cushion line, both legs clear of balls not on.  C = 1:
; found (tgt, best = twice the unfolded distance)
.proc kick
    lda #$FF
    sta kbest
    sta kbest+1
    lda #1
    sta blg
    ldx #NB-1
tl:
    stx at
    lda BON,x
    jeq tn
    jsr ison
    jcc tn
    jsr tload
    lda #3
    sta kk
kl:
    ldx kk                  ; the image: 2 lo - T, in x (0, 1) or y (2, 3)
    lda tx
    sta kix
    lda tx+1
    sta kix+1
    lda #0
    sta kix+2
    lda ty
    sta kiy
    lda ty+1
    sta kiy+1
    lda #0
    sta kiy+2
    ldy ai_kax,x            ; (0: x, 3: y)
    sec
    lda ai_kl,x
    sbc kix,y
    sta kix,y
    lda ai_km,x
    sbc kix+1,y
    sta kix+1,y
    lda ai_kh,x
    sbc kix+2,y
    sta kix+2,y
    sec                     ; v = image - C
    lda kix
    sbc X1
    sta cx
    lda kix+1
    sbc X2
    sta cx+1
    lda kix+2
    sbc #0
    sta cx+2
    sec
    lda kiy
    sbc Y1
    sta cy
    lda kiy+1
    sbc Y2
    sta cy+1
    lda kiy+2
    sbc #0
    sta cy+2
    jsr cordic
    lda cd                  ; shorter than the best so far?
    cmp kbest
    lda cd+1
    sbc kbest+1
    jcs kn
    lda cz
    sta kaim
    sta bang
    lda cz+1
    sta kaim+1
    sta bang+1
    lda X1                  ; leg 1: from the cue ball (the part past the cushion
    sta absx                ;   meets no ball)
    lda X2
    sta absx+1
    lda Y1
    sta absy
    lda Y2
    sta absy+1
    lda cd
    ldx cd+1
    jsr blocked
    jcs kn
    ldx kk                  ; leg 2: back from T, the aim mirrored and turned
    sec                     ;   (x cushion: - aim, y cushion: 180 deg - aim)
    lda #0
    sbc kaim
    sta bang
    lda ai_kt,x
    sbc kaim+1
    sta bang+1
    lda tx
    sta absx
    lda tx+1
    sta absx+1
    lda ty
    sta absy
    lda ty+1
    sta absy+1
    lda cd
    ldx cd+1
    jsr blocked
    jcs kn
    lda cd
    sta kbest
    lda cd+1
    sta kbest+1
    lda kaim
    sta tgt
    lda kaim+1
    sta tgt+1
    lda cd+1
    sta edc
kn:
    dec kk
    jpl kl
tn:
    ldx at
    dex
    jne tl
    lda #0
    sta blg
    lda kbest+1             ; found: best = 2 d -- a cushion keeps 0.48..0.64 of the
    cmp #$FF                ;   run (Mathavan's, asm_bench.py --phys): the leg after it
    beq no                  ;   counts twice (d < 32768)
    lda kbest
    asl @
    sta best
    lda kbest+1
    rol @
    sta best+1
    sec
    rts
no:
    clc
    rts
.endp
; the cushion lines of the ball centre, doubled (2 lo, 24 bits), per cushion
; (x lo, x hi, y lo, y hi); the axis (0 x, 3 y); the turn of the mirrored aim
ai_kl   dta <[26*32], <[[3569-26]*32], <[26*32], <[[1778-26]*32]
ai_km   dta >[26*32], >[[3569-26]*32], >[26*32], >[[1778-26]*32]
ai_kh   dta 0, [[3569-26]*32]>>16, 0, [[1778-26]*32]>>16
ai_kax  dta 0, 0, 3, 3
ai_kt   dta 0, 0, $80, $80

; spath: C = 1 when the shot cannot be played as planned: on the way to G the cue
; ball meets a ball that is not on (a foul), or after the contact, along cang for
; the run planned, it meets any ball (the leave is then anyone's guess)
.proc spath
    lda X1
    sta absx
    lda X2
    sta absx+1
    lda Y1
    sta absy
    lda Y2
    sta absy+1
    lda aim
    sta bang
    lda aim+1
    sta bang+1
    lda sapr                ; (blocked, 2: only a ball it would touch before T -- a thin
    sta blg                 ;   contact on a red of the pack passes its neighbours)
    lda cd
    ldx cd+1
    jsr blocked
    jcs out
    lda #0
    sta blg
    lda gx
    sta absx
    lda gx+1
    sta absx+1
    lda gy
    sta absy
    lda gy+1
    sta absy+1
    lda cang
    sta bang
    lda cang+1
    sta bang+1
    lda sapr                ; (2: a real contact only, the pack's neighbours by its way
    sta blg                 ;   passed; 1, the second pass: reds kissed too -- sim_shot
                            ;   shows where it really goes)
    lda e1l                 ; (to the first cushion: endpt's first leg)
    ldx e1l+1
    jsr blocked
    jcs ob
    jsr leg2                ; off a cushion: the way back too (the black, the pack)
    bcs ob
    lda sdo+1               ; the object ball: a touch (< 300 mm) may nudge its
    cmp #>300               ;   neighbours, a longer run must meet no colour (a red
                            ;   into the pack stays there: leave weighs his pots)
    bcc o2
    bne o1
    lda sdo
    cmp #<300
    bcc o2
o1:
    lda tx
    sta absx
    lda tx+1
    sta absx+1
    lda ty
    sta absy
    lda ty+1
    sta absy+1
    lda psi
    sta bang
    lda psi+1
    sta bang+1
    lda #1                  ; (balls on: the pack)
    sta blg
    lda sdo
    ldx sdo+1
    jsr blocked
    lda #0
    sta blg
    bcs ob
o2:
    lda gx                  ; (the cue run again: btr, blen for nearp)
    sta absx
    lda gx+1
    sta absx+1
    lda gy
    sta absy
    lda gy+1
    sta absy+1
    lda cang
    sta bang
    lda cang+1
    sta bang+1
    lda sapr                ; (as the first check)
    sta blg
    lda e1l                 ; (the first leg only: past the cushion lies no pocket)
    ldx e1l+1
    jsr blocked
ob:
    lda #1
    sta blg
    bcs out
    ldy #5                  ; its run passes a pocket (100 mm): an in-off risk
pk:
    sty spk
    tya                     ; * 12
    asl @
    sta at0
    asl @
    adc at0
    asl @
    tax
    sec                     ; d = P - G (Q4)
    lda pockets+1,x
    sbc gx
    sta bdx
    lda pockets+2,x
    sbc gx+1
    sta bdx+1
    lda #0
    sbc #0
    sta bdx+2
    sec
    lda pockets+4,x
    sbc gy
    sta bdx+3
    lda pockets+5,x
    sbc gy+1
    sta bdx+4
    lda #0
    sbc #0
    sta bdx+5
    jsr nearp               ; (btr: the run's cos, sin -- blocked left them)
    bcs out
    ldy spk
    dey
    bpl pk
    clc
out:
    rts
.endp

; ctot / gtoc: the vector from the cue ball to T / to G -> cordic (cz, cd)
.proc gtoc
    ldx #gx-tx
    bne ctot.go             ; (always)
.endp
.proc ctot
    ldx #0
go:
    sec
    lda tx,x
    sbc X1
    sta cx
    lda tx+1,x
    sbc X2
    sta cx+1
    lda #0
    sbc #0
    sta cx+2
    sec
    lda ty,x
    sbc Y1
    sta cy
    lda ty+1,x
    sbc Y2
    sta cy+1
    lda #0
    sbc #0
    sta cy+2
    jmp cordic
.endp

; dmulb: A = a share / 256 -> at0 = sda * A / 256 (mm)
.proc dmulb
    sta mB
    lda #0
    sta mB+1
    lda sda
    sta mA
    lda sda+1
    sta mA+1
    jsr mul16u
    lda mP+1
    sta at0
    lda mP+2
    sta at0+1
    rts
.endp

; leave: the cue ball at (ex, ey), the object ball `at` at (oex, oey) -> at0 =
; how far (|dx| + |dy|, 1/8 mm) the cue ball is from the nearest ball the
; opponent will be on, + 500 mm on a cushion, + 1500 mm tight on the baulk
; cushion / + 500 mm in baulk (the pros' safety off the pack), + half his
; easiest pot from there (nx_eval, at most + 1000 mm); - 700 mm when the
; object ball ends by a pocket; 1 (never) when the cue ball does (an in-off)
.proc leave
    lda #$FF
    sta lmin
    sta lmin+1
    ldx #NB-1
lp:
    lda BON,x
    beq nx
    jsr oppon
    bcc nx
    cpx at
    bne bp
    lda oex                 ; the object ball: where it stops
    sta lbx
    lda oex+1
    sta lbx+1
    lda oey
    sta lby
    lda oey+1
    sta lby+1
    jmp dl
bp:
    lda X1,x
    sta lbx
    lda X2,x
    sta lbx+1
    lda Y1,x
    sta lby
    lda Y2,x
    sta lby+1
dl:
    jsr ldist
    lda at0
    cmp lmin
    lda at0+1
    sbc lmin+1
    bcs nx
    lda at0
    sta lmin
    lda at0+1
    sta lmin+1
nx:
    dex
    bne lp
    ldy #5                  ; the pockets
pk:
    tya                     ; * 12
    asl @
    sta at0
    asl @
    adc at0
    asl @
    tax
    lda pockets+1,x
    sta lbx
    lda pockets+2,x
    sta lbx+1
    lda pockets+4,x
    sta lby
    lda pockets+5,x
    sta lby+1
    jsr ldist               ; the cue ball by it: an in-off risk
    lda at0+1
    cmp #>[450*8]
    bcs p2
    lda #1
    sta at0
    lda #0
    sta at0+1
    rts
p2:
    jsr oswap               ; the object ball by it: - 700 mm
    jsr ldist
    jsr oswap
    lda at0+1
    cmp #>[150*8]
    bcs p3
    sec
    lda lmin
    sbc #<[700*8]
    sta lmin
    lda lmin+1
    sbc #>[700*8]
    sta lmin+1
    bcs p3
    lda #0
    sta lmin
    sta lmin+1
p3:
    dey
    bpl pk
    lda ex+1                ; on a cushion (60 mm): + 500 mm
    cmp #>[[26+60]*16]
    bcc cu
    cmp #>[[3569-26-60]*16]
    bcs cu
    lda ey+1
    cmp #>[[26+60]*16]
    bcc cu
    cmp #>[[1778-26-60]*16]
    bcc no
cu:
    clc
    lda lmin
    adc #<[500*8]
    sta lmin
    lda lmin+1
    adc #>[500*8]
    bcc cs
    lda #$FF
    sta lmin
cs:
    sta lmin+1
no:
; [2026-10-27 THE RULE: nothing to pot -> the safety goes to the BACK cushion, the one
;  behind the yellow, brown and green (x < 737 mm from it).  A leave that ends anywhere
;  else is divided by 64 (it was by 4, and a leave up the table by the black was still chosen:
;  istota.png, zlta2.png -- the cue ball left on the top cushion or stuck on the pack).
;  Why 64: the best leave elsewhere is then at most 64000 / 64 = 1000 units, and every
;  leave behind the line gets + 500 mm (4000 units) or + 1500 mm on top -- so ANY leave
;  at the back cushion is chosen before ANY leave elsewhere, while the order among the ones
;  elsewhere is kept (the shifts keep it) for when no shot reaches the back cushion.
;  The 3 best of this model are then played in the physics (s3pick), which measures the
;  real end place with this same routine (leavep): the rule holds there too.]
    lda ex+1                ; the cue ball's end x (Q4 high byte: 16 mm units)
    cmp #>[737*16]          ; behind the yellow, brown, green: to ib (+ 500 / + 1500 mm)
    bcc ib
    lda lmin+1              ; elsewhere: lmin / 64 -- 6 shifts of the 16-bit value
    ldx #6
q:  lsr @
    ror lmin
    dex
    bne q
    sta lmin+1
    beq nbk                 ; (always: Z from the dex; tight on the back cushion, x < 300
                            ;   mm: + 1500 mm below, else + 500 mm)
ib:
    cmp #>[300*16]
    bcs b1
    lda #<[1500*8]
    ldx #>[1500*8]
    bne bk                  ; (always)
b1:
    lda #<[500*8]
    ldx #>[500*8]
bk:
    jsr ladd
nbk:
    jsr lnx                 ; his easiest pot from there: + min(it, 16000) / 2
    cmp #<16000
    tay
    txa
    sbc #>16000
    bcc e1
    ldy #<16000
    ldx #>16000
e1:
    stx at0+1
    lsr at0+1
    tya
    ror @
    ldx at0+1
    jsr ladd
    lda lmin
    sta at0
    lda lmin+1
    sta at0+1
    ora at0                 ; (0 reads as never)
    bne ok
    inc at0
ok:
    rts
.endp

; oswap: (ex, ey) <-> (oex, oey).  Keeps X, Y.
.proc oswap
    ldx #3
lp:
    lda ex,x
    pha
    lda oex,x
    sta ex,x
    pla
    sta oex,x
    dex
    bpl lp
    rts
.endp

; ldist: at0 = (|ex - lbx| + |ey - lby|) / 2  (Q4 / 2 = 1/8 mm).  Keeps X, Y.
.proc ldist
    sec
    lda ex
    sbc lbx
    sta at0
    lda ex+1
    sbc lbx+1
    bcs x1
    eor #$FF                ; negative: - v = ~v + 1
    sta at0+1
    lda at0
    eor #$FF
    adc #1                  ; (C = 0 here)
    sta at0
    lda at0+1
    adc #0
x1:
    lsr @
    sta at0+1
    ror at0
    sec
    lda ey
    sbc lby
    sta lt
    lda ey+1
    sbc lby+1
    bcs y1
    eor #$FF
    sta lt+1
    lda lt
    eor #$FF
    adc #1
    sta lt
    lda lt+1
    adc #0
y1:
    lsr @
    sta lt+1
    ror lt
    clc
    lda at0
    adc lt
    sta at0
    lda at0+1
    adc lt+1
    sta at0+1
    rts
.endp

; oppon: X = a ball -> C = 1 when the opponent will be on it (the reds while
; any are left and we are not on the sequence colours; else the ball on).
; Keeps X.
.proc oppon
    lda onk
    cmp #2
    beq is
    lda redsl
    beq is
    cpx #16                 ; a red: C = 0 -> 1
    rol @
    eor #1
    lsr @
    rts
is:
    jmp ison
.endp

; the safety: the psi offsets (+-1..5 x 15 deg); per |theta| / 15 deg the cue
; ball deflection from its line, the shares of what is left after the contact
; (cue g, object h) -- asm_bench.py --ai-calib, 1.0 m/s: the same for every power
; whose cue ball rolls at the contact (it slides at most 0.45 m)
ai_skl  dta <2731, <5461, <8192, <10923, <-2731, <-5461, <-8192, <-10923, <13653, <-13653
ai_skh  dta >2731, >5461, >8192, >10923, >-2731, >-5461, >-8192, >-10923, >13653, >-13653
ai_sdl  dta <0, <4887, <5748, <4908, <3461, <1815, <351
ai_sdh  dta >0, >4887, >5748, >4908, >3461, >1815, >351
ai_sg   dta 27, 41, 85, 142, 197, 236, 249
ai_sh   dta 122, 117, 91, 59, 29, 8, 0
ai_sdd  dta <1058, <2160, <3650, <5600, <8000, <12000  ; D (mm) of 0.7 .. 2.4 m/s: the
ai_sddh dta >1058, >2160, >3650, >5600, >8000, >12000  ;   firm ones a thin hit off the pack
ai_spl  dta <$3800, <$5000, <$6800, <$8100, <$9A10, <$BCAC, <$E000, <$F000, <$10800, <$12000  ; their power (r * 441)
ai_sph  dta >$3800, >$5000, >$6800, >$8100, >$9A10, >$BCAC, >$E000, >$F000, >$10800, >$12000  ;   6 .. 9: sfscan's thin
ai_spx  dta 0, 0, 0, 0, 0, 0, 0, 0, 1, 1                                                       ;   ones off the pack
; [2026-10-27 8, 9 ($10800, $12000) and their third byte ai_spx added: the safety to the back
;  cushion -- $E000 / $F000 stopped the cue ball 300-650 mm short of it (ai2.asm sfend)]
; the rectangle of the ball centre (Q4): lo, span for x / y (endpt)
ai_flo  dta a(26*16), a(26*16)
ai_fsp  dta a([3569-52]*16), a([1778-52]*16)

; its cells
sapr    dta 2               ; spath's blocked mode for the way to G (ai_safe's passes)
blg     dta 0               ; blocked: 1 = balls on in the way are legal
sbest   dta 0, 0
sbpsi   dta 0, 0
sdo     dta 0, 0            ; the planned run of the object ball (mm)
spk     dta 0
kbest   dta 0, 0
kk      dta 0
kaim    dta 0, 0
kix     dta 0, 0, 0
kiy     dta 0, 0, 0
sa0     dta 0, 0
sk      dta 0
ssg     dta 0
ssi      dta 0
spi     dta 0
psi     dta 0, 0
cang    dta 0, 0
sda     dta 0, 0
ex      dta 0, 0            ; (ex, ey and oex, oey adjacent: endpt, oswap)
ey      dta 0, 0
oex     dta 0, 0
oey     dta 0, 0
lmin    dta 0, 0
lbx     dta 0, 0
lby     dta 0, 0
lt      dta 0, 0
