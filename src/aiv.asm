; aiv.asm -- the computer player (opp 1..5, menu.asm).  On its turn, at rest
; and after the rules judged the last shot, it plans once (ai_plan), then plays
; through the human input path: STICK0 / STRIG0 written here (the VBI leaves
; them, aiact) -- the aim turns, the view follows, the power charges, it fires.
; Pot (as noble1911/cue-club, faisukhan01/snooker): every ball on x pocket, the
; ghost ball 2R behind the object ball, cut <= 75 deg, middle pockets within 45
; deg of square, both paths clear; ease = dcg dtp / cos^2.  Power: a ball rolls
; 2.16 v^2 m, D = dcg + 2.83 dtp / cos^2 (measured in the game physics).
; Not sure of the pot (ease > his nerve) or none: a safety (aisafe.asm);
; snookered: a one-cushion escape.  The first ball hit is always a ball on.
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- one CORDIC gives the angle and the
;  distance (no atan / sqrt tables), the multiplies are math.asm's; cold code, cells here.
;  vbxe-blitter/SKILL.md: code in the window never switches it -- ai_run calls only RAM
;  routines that leave MA_BSEL alone]
; Assembled for the 8 KB window at $2000, staged at $2000 in two 4 KB halves and
; copied to V:AI_BANK000 / +$1000 by vram_next (vbank seeded below).
    org vbank
    dta AI_BANK-1
    org $2000               ; (the first 4 KB: staged where they run)

AI_CUT  = 13653             ; 75 deg (1/64 aim units: 65536 a turn)
AI_2R   = 840               ; 2R = 52.5 mm, Q4
AI_SDA0 = 120               ; a safety: at least this many mm of run left at the contact
RANDOM  = $D20A             ; POKEY

; --- the players (opp - 1), weakest first.  One AI for them all: they differ in
;     their skill only -- the aim error (and its growth with the distance) and
;     the time they take.  What a pot is worth going for follows from it (his
;     nerve = 96000 / his aim error: a pot he misses more often is a safety).
;     Selby, Higgins, Robertson (the long potter: no extra error on long
;     shots), Trump, O'Sullivan (the most accurate, the fastest), the qualifier
;     (6: the tournament's, the weakest).
ai_err  dta 22, 18, 15, 12, 6, 26   ; aim error: +- this many 1/64 units (a triangle)
ai_errl dta 3, 2, 0, 1, 0, 3        ; + this per 256 mm from the cue to the ghost
ai_dml  dta <4364, <5333, <6400, <8000, <16000, <3692   ; his nerve: the hardest pot (ease) he
ai_dmh  dta >4364, >5333, >6400, >8000, >16000, >3692   ;   goes for, 96000 / ai_err
ai_pm   dta 130, 130, 130, 130, 130, 130 ; the power x / 128 on a pot (the same: the physics')
ai_thk  dta 60, 45, 35, 25, 10, 70  ; his tempo: frames he studies the table before aiming
ai_wv   dta 8, 8, 8, 6, 4, 3            ; a colour's ease * this / 8 (yellow .. black): the black for 3/8 of the ease -- worth a harder pot, but not a bad position (Davis)
ai_tth  dta >14563, >14563, >14563, >14563, >14563, >14563  ; the thinnest safety: 80 deg (his aim error decides)

.proc ai_run
    lda #$0F
    sta STICK0
    lda inhand
    beq aim
    lda hwait               ; in hand: its place walked to, fire pressed (hwait 0: hand_ai,
    bne hw                  ;   ai2.asm), then released (1)
    jsr hand_ai
hw:
    sta STRIG0
    rts
aim:
    lda #1
    sta STRIG0
    ldx aist
    bne s1
    jsr ai_plan             ; 0: the shot
    ldx aip
    lda ai_thk-1,x
    sta aitm
    inc aist
    rts
s1:
    dex
    bne s2
    dec aitm                ; 1: he looks at it
    bne r
    inc aist
r:
    rts
s2:
    dex
    bne s3
    jmp ai_turn             ; 2: the aim turns to it
s3:
    dex
    bne s4
    dec aitm                ; 3: aimed, a breath
    bne r
    inc aist
    rts
s4:
    lda charging            ; 4: the power held until it reaches tpw, then released
    beq pr
    lda pwr+2
    cmp tpw+2
    bne c1
    lda pwr+1
    cmp tpw+1
    bne c1
    lda pwr
    cmp tpw
c1:
    bcc pr
    lda tpw                 ; there: exactly tpw, released (handle_trigger fires)
    sta pwr
    lda tpw+1
    sta pwr+1
    lda tpw+2
    sta pwr+2
    rts
pr:
    lda #0
    sta STRIG0
    rts
.endp

; ai_turn: the aim towards tgt with the stick -- left / right while the gap is a
; whole step of read_stick's ramp, up / down (AFINE) below that, then exact
.proc ai_turn
    lda aimfrac             ; cur = aimang * 64 + aimfrac / 4
    lsr @
    lsr @
    sta at0
    lda aimang
    lsr @
    lsr @
    sta at0+1
    lda aimang+1
    asl @
    asl @
    asl @
    asl @
    asl @
    asl @
    ora at0+1
    sta at0+1
    lda aimang
    asl @
    asl @
    asl @
    asl @
    asl @
    asl @
    ora at0
    sta at0
    sec                     ; d = tgt - cur
    lda tgt
    sbc at0
    sta at0
    lda tgt+1
    sbc at0+1
    sta at0+1
    php                     ; (N: the direction)
    bpl ab
    sec
    lda #0
    sbc at0
    sta at0
    lda #0
    sbc at0+1
    sta at0+1
ab:
    lda at0+1               ; |d| * 4: 1/256 units ($FFFF when larger)
    cmp #$40
    bcc sm
    lda #$FF
    sta at0
    sta at0+1
    bne cs                  ; (always)
sm:
    asl at0
    rol at0+1
    asl at0
    rol at0+1
cs:
    clc                     ; read_stick's next step: aspd + ARAMP
    lda aspd
    adc #ARAMP
    tax
    lda aspd+1
    adc #0
    cpx at0                 ; step < |d|: a whole step
    sbc at0+1
    bcc big
    lda at0+1               ; |d| >= AFINE: a fine step
    bne fine
    lda at0
    cmp #AFINE
    bcs fine
    plp                     ; there: exact, then a breath
    lda tgt
    asl @
    asl @
    sta aimfrac
    lda tgt+1
    lsr @
    sta at0+1
    lda tgt
    ror @
    ldx #5
sh:
    lsr at0+1
    ror @
    dex
    bne sh
    sta aimang
    lda at0+1
    sta aimang+1
    lda #20
    sta aitm
    inc aist
    rts
big:
    plp
    bmi lf
    lda #$07                ; right: + aspd
    bne st
lf:
    lda #$0B                ; left
    bne st
fine:
    plp
    bmi up
    lda #$0D                ; down: + AFINE
    bne st
up:
    lda #$0E                ; up: - AFINE
st:
    sta STICK0
    rts
.endp

; ai_plan: the shot -> tgt (1/64 units, with the player's error), tpw
.proc ai_plan
    lda #0                  ; (sim_shot's ppev and quick stop off: RAM never loaded)
    sta sevon
    sta squick
    jsr opening             ; the frame's break-off: the pros' one (ai2.asm)
    bcc pl0
    rts
pl0:
    jsr pscan
    jsr kplay               ; the KP_N easiest played for position (ai2.asm); none in his nerve: C = 1
    bcc er
    jsr ai_safe
er:
    jmp ai_err_
.endp

; pscan: the cue where it is -> the KP_N easiest pots (kel / keh, kat, kap ...: kins),
; kel / keh[0] = the easiest's ease ($FFFF: none).  hand_pick tries the D with it.
.proc pscan
    jsr ball_on
    lda #9                  ; cordic: 9 turns while choosing
    sta cit
    jsr kclr                ; the KP_N easiest pots: none yet (best = the last one's ease)
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
    lda #5
    sta ap
pl:
    jsr pgeo1               ; phi, dtp
    ldx ap                  ; the ball runs into the pocket's mouth?
    sec
    lda cz
    sbc ai_plo,x
    lda cz+1
    sbc ai_phi,x
    cmp ai_prh,x
    jcs pn
    lda cz
    sta phi
    lda cz+1
    sta phi+1
    lda cd
    sta dtp
    lda cd+1
    sta dtp+1
    jsr pgeo2               ; aim, dcg
    lda cz
    sta aim
    lda cz+1
    sta aim+1
    sec                     ; |cut| = |aim - phi| <= 75 deg
    lda aim
    sbc phi
    sta at0
    lda aim+1
    sbc phi+1
    bpl cp
    sta at0+1
    sec
    lda #0
    sbc at0
    sta at0
    lda #0
    sbc at0+1
cp:
    sta at0+1
    cmp #>AI_CUT
    bcc ck
    jne pn
    lda at0
    cmp #<AI_CUT
    jcs pn
ck:
    lda at0+1               ; f = 32 / cos^2 (cut / 512)
    lsr @
    tax
    lda ai_fl,x
    sta cf
    lda ai_fh,x
    sta cf+1
    lda cd                  ; ease = ((dcg + 320) / 16) (dtp / 16) f / 32: the cue
    ldx cd+1                ;   ball right by the ball does not make a thin cut
    jsr d16                 ;   easy (the pocket's error grows with dtp / cos)
    clc
    adc #320/16
    bcc ez
    lda #$FF
ez:
    sta at0
    lda dtp
    ldx dtp+1
    jsr d16
    ldx at0
    jsr fmulu
    lda fmpl
    sta mA
    lda fmph
    sta mA+1
    lda cf
    sta mB
    lda cf+1
    sta mB+1
    jsr mul16u
    lda mP+3                ; >> 5 ($FFFF when larger)
    bne sat
    lda mP+2
    cmp #$20
    bcs sat
    ldx #5
sh:
    lsr mP+2
    ror mP+1
    ror mP
    dex
    bne sh
    lda mP
    ldx mP+1
    jmp es
sat:
    lda #$FF
    tax
es:
    sta ease
    stx ease+1
    ldy at                  ; a colour: its value counts -- ease * ai_wv / 8 (the black
    cpy #16                 ;   5/8: as hard, the black is the one to take)
    bcc ec
    lda ai_wv-16,y
    tay
    lda ease
    jsr wmul8
    sta ease
    stx ease+1
ec:
    cmp best                ; easier than the best so far?
    txa
    sbc best+1
    jcs pn
    lda X1                  ; the cue's path to G clear?
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
    lda cd
    ldx cd+1
    jsr blocked
    jcs pn
    lda tx                  ; the object ball's path to P clear?
    sta absx
    lda tx+1
    sta absx+1
    lda ty
    sta absy
    lda ty+1
    sta absy+1
    lda phi
    sta bang
    lda phi+1
    sta bang+1
    lda dtp
    ldx dtp+1
    jsr blocked
    jcs pn
    lda cd+1                ; one of the KP_N easiest (kins): its cue-to-ghost run, its D
    sta edc
    lda dtp                 ; D = dcg + 2.83 dtp / cos^2 = dcg + (dtp f >> 8) 181 >> 3
    sta mA                  ; (the cue rolls at 5/7 of its speed after the slide, the
    lda dtp+1               ;  object ball must roll on into the pocket: the game's
    sta mA+1                ;  physics measured, +30 % margin)
    lda cf
    sta mB
    lda cf+1
    sta mB+1
    jsr mul16u
    lda mP+3
    bne dsat
    lda mP+1
    sta mA
    lda mP+2
    sta mA+1
    lda #181
    sta mB
    lda #0
    sta mB+1
    jsr mul16u
    lda mP+3
    bne dsat
    ldx #3
sd:
    lsr mP+2
    ror mP+1
    ror mP
    dex
    bne sd
    lda mP+2
    bne dsat
    clc
    lda mP
    adc cd
    sta dd
    lda mP+1
    adc cd+1
    sta dd+1
    bcc ki
dsat:
    lda #$FF
    sta dd
    sta dd+1
ki:
    jsr kins
pn:
    dec ap
    jpl pl
tn:
    ldx at
    dex
    jne tl
    rts
.endp


; pgeo1: T (tx, ty), the pocket ap -> cordic of P - T: cz = phi, cd = dtp
.proc pgeo1
    lda ap                  ; P: the pocket's Q4 x, y (bytes 1, 2 and 4, 5 of 12)
    asl @
    adc ap
    asl @
    asl @
    tay
    sec                     ; v = P - T
    lda pockets+1,y
    sbc tx
    sta cx
    lda pockets+2,y
    sbc tx+1
    sta cx+1
    lda #0
    sbc #0
    sta cx+2
    sec
    lda pockets+4,y
    sbc ty
    sta cy
    lda pockets+5,y
    sbc ty+1
    sta cy+1
    lda #0
    sbc #0
    sta cy+2
    jmp cordic
.endp

; pgeo2: T, phi -> the ghost G = T - 2R (cos, sin) phi, cordic of G - C: cz = the
; aim, cd = dcg
.proc pgeo2
    lda phi
    sta cz
    lda phi+1
    sta cz+1
    jsr trig                ; G = T - 2R (cos, sin) phi
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
    jmp gtoc                ; w = G - C
.endp

; tload: X = a ball -> T (tx, ty)
.proc tload
    lda X1,x
    sta tx
    lda X2,x
    sta tx+1
    lda Y1,x
    sta ty
    lda Y2,x
    sta ty+1
    rts
.endp

; ai_err_: tgt += the player's error: s * e / 128, s = (r1 + r2) / 2 - 128 (a
; triangle), e = err + errl * dcg / 256
.proc ai_err_
    ldx aip
    lda ai_errl-1,x
    ldx edc
    jsr fmulu
    ldx aip
    lda fmph
    bne sat
    lda fmpl
    clc
    adc ai_err-1,x
    bcc e2
sat:
    lda #$FF
e2:
    sta at0                 ; e
    clc
    lda RANDOM
    adc RANDOM
    ror @                   ; (r1 + r2) / 2
    eor #$80                ; - 128
    php
    bpl ep
    eor #$FF
    clc
    adc #1
ep:
    ldx at0
    jsr fmulu               ; |s| e / 128
    lda fmpl
    asl @
    lda fmph
    rol @
    sta at0
    lda #0
    rol @
    sta at0+1
    plp
    bpl ad
    sec
    lda tgt
    sbc at0
    sta tgt
    lda tgt+1
    sbc at0+1
    sta tgt+1
    rts
ad:
    clc
    lda tgt
    adc at0
    sta tgt
    lda tgt+1
    adc at0+1
    sta tgt+1
    rts
.endp


; power: A:X = D (mm) -> ar = floor(sqrt(D)), D <= 26450 (the full power)
.proc power
    cpx #>26450
    bcc ok
    lda #<26450
    ldx #>26450
ok:
    sta mP
    stx mP+1
    lda #0
    sta mP+2
    sta mP+3
    sta mP+4
    sta mP+5
    jsr isqrt48
    lda root
    sta ar
    rts
.endp

; pset: A = r -> tpw = r * 441 (sqrt(D / 2160) m/s, Q12 mm a tick), PWR_MIN..PWR_MAX
.proc pset
    sta ar
    ldx #185
    jsr fmulu
    clc
    lda fmpl
    sta tpw
    lda fmph
    adc ar
    sta tpw+1
    lda #0
    adc #0
    sta tpw+2
    cmp #PWR_MAX>>16
    bcc lo
    bne hi
    lda tpw+1
    cmp #>PWR_MAX
    bcc lo
hi:
    lda #<PWR_MAX
    sta tpw
    lda #>PWR_MAX
    sta tpw+1
    lda #PWR_MAX>>16
    sta tpw+2
    rts
lo:
    lda tpw+2
    bne ok
    lda tpw+1
    cmp #>PWR_MIN
    bcs ok
    lda #<PWR_MIN
    sta tpw
    lda #>PWR_MIN
    sta tpw+1
ok:
    rts
.endp

; endpt: from (absx, absy) along cz for A:X mm -> (ex, ey) Q4: straight to the
; nearest cushion (R from it), there the way off it at Mathavan's rebound angle (erb) and only the rest of the
; run cut to what a cushion keeps: 164/256 at 45 deg from it or less, down to
; 123/256 square on (|the way's normal part| n: 164 - (n - 0.71) 143/256; the
; game's cushion.asm, Mathavan -- asm_bench.py --phys), up to 3 cushions.  The legs after a cushion -> elg (start
; x, y Q4, angle, run mm), enl of them, for leg2.
.proc endpt
    sta erun
    stx erun+1
    ldx #3
cp:
    lda absx,x              ; (absx, absy adjacent)
    sta epx,x
    dex
    bpl cp
    lda cz
    sta ean
    lda cz+1
    sta ean+1
    lda erun                ; the first leg: all of it, or to the first cushion
    sta e1l
    lda erun+1
    sta e1l+1
    lda #0
    sta enl
lg:
    lda ean
    sta cz
    lda ean+1
    sta cz+1
    jsr trig                ; btr: cos, sin (Q16)
    lda #$FF                ; ed = the run to the nearest cushion (mm), eax its axis
    sta ed
    sta ed+1
    ldx #0
    jsr wdist
    ldx #2
    jsr wdist
    lda enl                 ; 3 cushions: the rest ends where it is
    cmp #3
    jcs fin
    lda erun                ; the run ends before the cushion?
    cmp ed
    lda erun+1
    sbc ed+1
    jcc fin
    lda ed                  ; to the cushion
    ldx ed+1
    jsr emove
    lda #0
    ldx eax                 ; what the cushion keeps, by n (btr's hi byte, |.|)
    beq nx
    lda #3
nx:
    tay
    lda btr+1,y
    ldx btr+2,y
    bpl np
    eor #$FF                ; (|n|: the one's complement is near enough)
np:
    sec
    sbc #182                ; n < 0.71: 164
    bcc k0
    tax
    lda #143
    jsr fmulu
    sec
    lda #164
    sbc fmph
    jmp k1
k0:
    lda #164
k1:
    sta ekp
    sec                     ; the rest, ekp/256 of it
    lda erun
    sbc ed
    tay
    lda erun+1
    sbc ed+1
    tax
    tya
    jsr r150
    ldx eax                 ; the way mirrored: x: 32768 - a, y: -a
    sec
    lda #0
    sbc ean
    sta ean
    lda ebh,x
    sbc ean+1
    sta ean+1
    lda ebh,x               ; then turned to Mathavan's rebound (erb, ai2.asm): its
    lsr @                   ;   angle off the normal d (hi byte: x + $40, y + 0, mod
    clc                     ;   $80, - $40) -> d + sign(d) erb(|d|)
    adc ean+1
    and #$7F
    sec
    sbc #$40
    pha
    bpl ep
    eor #$FF                ; (|d|: the one's complement is near enough)
ep:
    lsr @
    tay
    pla
    bmi en
    clc
    lda ean
    adc erbl,y
    sta ean
    lda ean+1
    adc erbh,y
    sta ean+1
    jmp ee
en:
    sec
    lda ean
    sbc erbl,y
    sta ean
    lda ean+1
    sbc erbh,y
    sta ean+1
ee:
    lda enl                 ; (the first cushion: the first leg ends there)
    bne l1
    lda ed
    sta e1l
    lda ed+1
    sta e1l+1
    lda enl
l1:                         ; the leg: start, angle, run
    asl @
    asl @
    asl @
    tay
    ldx #0
rl:
    lda epx,x
    sta elg,y
    iny
    inx
    cpx #8
    bne rl
    inc enl
    jmp lg
fin:
    lda erun
    ldx erun+1
    jsr emove
    ldx #3
ce:
    lda epx,x
    sta ex,x                ; (ex, ey adjacent)
    dex
    bpl ce
    rts
ebh dta $80, 0, 0           ; x: 32768 - a, y: 0 - a (by eax 0 / 2)
.endp
    ert ean<>epx+4 || erun<>ean+2

; r150: A:X -> erun = A:X * ekp / 256
.proc r150
    stx ttmp
    ldx ekp
    jsr fmulu
    lda fmph
    sta erun
    lda ttmp
    ldx ekp
    jsr fmulu
    clc
    lda fmpl
    adc erun
    sta erun
    lda fmph
    adc #0
    sta erun+1
    rts
.endp

; emove: A:X = mm -> (epx, epy) += mm along btr (Q3 products, Q4 sums)
.proc emove
    stx ttmp
    asl @                   ; mm * 8 (Q3), at most 65535
    rol ttmp
    asl @
    rol ttmp
    asl @
    rol ttmp
    bcc ok
    lda #$FF
    sta ttmp
ok:
    sta at0
    lda ttmp
    sta at0+1
    ldy #0
    jsr mv
    ldy #3
mv:
    lda at0
    ldx at0+1
    sty ttmp
    jsr tmul                ; sP = Q3 signed
    asl sP                  ; Q4
    rol sP+1
    lda ttmp                ; Y 0 / 3 -> epx / epy
    beq x0
    ldx #2
    dta $2C
x0:
    ldx #0
    clc
    lda epx,x
    adc sP
    sta epx,x
    lda epx+1,x
    adc sP+1
    sta epx+1,x
    rts
.endp

; wdist: X = 0 x / 2 y -> the run (mm) to that axis' cushion along btr; the
; nearer than ed -> ed, eax = X.  A way within 1/256 of along the cushion: none.
.proc wdist
    stx eax0
    txa                     ; btr: x 0, y 3
    beq c0
    lda #3
c0:
    tay
    lda btr+2,y             ; |c| (Q16) -> mB, from the cushion it heads for
    bmi ng
    lda btr,y
    sta mB
    lda btr+1,y
    sta mB+1
    lda btr+2,y
    sta mB+2
    clc                     ; d = lo + span - p (Q4)
    lda ai_flo,x
    adc ai_fsp,x
    sta at0
    lda ai_flo+1,x
    adc ai_fsp+1,x
    sta at0+1
    sec
    lda at0
    sbc epx,x
    sta at0
    lda at0+1
    sbc epx+1,x
    sta at0+1
    jmp dv
ng:
    sec
    lda #0
    sbc btr,y
    sta mB
    lda #0
    sbc btr+1,y
    sta mB+1
    lda #0
    sbc btr+2,y
    sta mB+2
    sec                     ; d = p - lo
    lda epx,x
    sbc ai_flo,x
    sta at0
    lda epx+1,x
    sbc ai_flo+1,x
    sta at0+1
dv:
    bcs ps                  ; (behind it already: 0)
    lda #0
    sta at0
    sta at0+1
ps:
    lda erun+1              ; the run (Q4) short of the cushion even straight at it:
    cmp #$10                ;   no division (d >= run 16; run < 4096 mm)
    bcs dd
    sta ttmp
    lda erun
    asl @
    rol ttmp
    asl @
    rol ttmp
    asl @
    rol ttmp
    asl @
    rol ttmp
    cmp at0
    lda ttmp
    sbc at0+1
    bcc no                  ; run 16 < d
dd:
    lda mB+2                ; |c| < 256: along it
    ora mB+1
    beq no
    lda #0                  ; mQ = d 65536 / |c| (Q4) -> mm = >> 4
    sta mA
    sta mA+1
    sta mA+4
    sta mA+5
    lda at0
    sta mA+2
    lda at0+1
    sta mA+3
    jsr divr
    lda mQ+2                ; >> 4, at most 65535
    cmp #$10
    bcs no
    lda mQ+1
    sta at0+1
    lda mQ
    ldx #4
sh:
    lsr mQ+2
    ror at0+1
    ror @
    dex
    bne sh
    cmp ed                  ; nearer?
    tay
    lda at0+1
    sbc ed+1
    bcs no
    sty ed
    lda at0+1
    sta ed+1
    lda eax0
    sta eax
no:
    rts
.endp

; leg2: the cue ball's legs after a cushion (endpt's elg): C = 1 when a ball lies
; on one (the object ball too: a thin hit leaves it by its spot), or one starts
; off a cushion within 450 mm (|dx| + |dy|) of a pocket: an in-off for a little
; aim error (the model's legs are off by a few hundred mm)
.proc leg2
    lda at
    pha
    lda #$FF
    sta at
    lda #0
    sta eli
lp:
    lda eli
    cmp enl
    bcs out                 ; (C = 1 -> no: cleared below)
    asl @
    asl @
    asl @
    tay
    ldx #0
c:
    lda elg,y
    sta absx,x              ; absx, absy, bang adjacent
    iny
    inx
    cpx #6
    bne c
    lda elg,y
    sta erun                ; (the leg's run: endpt is done with it)
    lda elg+1,y
    sta erun+1
    inc eli
    ldx #3                  ; the cushion it comes off: by a pocket (450 mm)? an
cp:                         ;   in-off for his aim error (ex, ey: leave is done)
    lda absx,x
    sta ex,x
    dex
    bpl cp
    ldy #5
pk:
    tya
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
    jsr ldist               ; (keeps Y)
    lda at0+1
    cmp #>[450*8]
    bcc bad
    dey
    bpl pk
    lda erun
    ldx erun+1
    jsr blocked
    bcc lp
bad:
    pla                     ; a ball on it
    sta at
    sec
    rts
out:
    pla
    sta at
    clc
    rts
.endp
    ert absy<>absx+2 || bang<>absy+2

; endpt's cells
epx     dta 0, 0            ; the point (Q4)
epy     dta 0, 0
ean     dta 0, 0            ; the way
erun    dta 0, 0            ; the run left (mm)
ed      dta 0, 0            ; to the nearest cushion
eax     dta 0
eax0    dta 0
ekp     dta 0               ; what this cushion keeps of the run, /256
e1l     dta 0, 0            ; the first leg's run (mm): to the first cushion
enl     dta 0               ; the legs after a cushion
eli     dta 0
elg     :24 dta 0           ; 3 x (x, y, angle, run)

; nx_build: A = 0: the opponent's pots after a safety (snooker.online: a safety
; asks him a question he may not answer), 1: the computer's own after this pot
; (nexton: its position) -- every such ball x pocket, its way to the mouth clear
; -> nxe (x, y, the pocket's dx, dy, the run: 32 mm units; the weight: a colour's
; value, mode 1), nxn of them.  2: the reds but bt, one entry each: nxn = how many
; have a clear pocket (kset -> cnfr: cnset's pack-closed test).
.proc nx_build
    sta nxmd
    lda #0
    sta nxn
    sta blg
    ldx #NB-1
bl:
    stx at
    lda BON,x
    jeq bn
    lda nxmd
    beq m0
    lsr @                   ; 1: on after this pot; 2: a red but bt, one entry each
    beq nm                  ;   (nxn = the reds with a clear pocket: cnset)
    cpx #16
    jcs bn
    cpx bt
    jeq bn
    bne m1                  ; (always: X <> bt)
m0:
    jsr oppon
    jmp ck
nm:
    jsr nexton
ck:
    jcc bn
m1:
    jsr tload
    lda #5
    sta ap
pk:
    jsr pgeo1               ; cz = the way to the pocket, cd = the run
    ldx ap                  ; into the mouth?
    sec
    lda cz
    sbc ai_plo,x
    lda cz+1
    sbc ai_phi,x
    cmp ai_prh,x
    jcs pn
    lda cz
    sta bang
    lda cz+1
    sta bang+1
    lda cd
    sta nxd
    lda cd+1
    sta nxd+1
    ldx #3
c:
    lda tx,x                ; (tx, ty -> absx, absy)
    sta absx,x
    dex
    bpl c
    lda cd
    ldx cd+1
    jsr blocked             ; the way clear?
    jcs pn
    lda nxn
    cmp #NX_MAX
    jcs pn
    asl @                   ; * 6
    adc nxn                 ; (C = 0: nxn < 43)
    asl @
    tay
    lda tx+1                ; x, y: Q4 >> 9
    lsr @
    sta nxe,y
    lda ty+1
    lsr @
    sta nxe+1,y
    lda ap                  ; the pocket: * 12
    asl @
    adc ap
    asl @
    asl @
    tax
    lda pockets+2,x
    lsr @
    sec
    sbc nxe,y
    sta nxe+2,y
    lda pockets+5,x
    lsr @
    sec
    sbc nxe+1,y
    sta nxe+3,y
    ldx nxd                 ; the run / 32 (its low byte): hi << 3 | lo >> 5 [2026-10-28
    lda shr4,x              ;  6502-idioms/SKILL.md: no shift ladder in memory;
    lsr @                   ;  6502-loops-tables-smc/SKILL.md: tables beat arithmetic]
    sta ttmp
    lda nxd+1
    asl @
    asl @
    asl @
    ora ttmp
    sta nxe+4,y
    lda #8                  ; the weight /8: a colour in mode 1 by its value (ai_wv)
    ldx nxmd
    beq w
    ldx at
    cpx #16
    bcc w
    lda ai_wv-16,x
w:
    sta nxe+5,y
    inc nxn
    lda nxmd                ; (2) one entry a red: its other pockets skipped
    cmp #2
    beq bn
pn:
    dec ap
    jpl pk
bn:
    ldx at
    dex
    jne bl
    rts
.endp
    ert ty<>tx+2 || absy<>absx+2

; nx_eval: the cue ball at (ex, ey) -> A:X = the opponent's easiest pot of nxe
; ($FFFF: none): ease = (|a| + 320 mm) |b| / cos^2 as ai_plan's, a = the ball
; from the cue, b = the pocket from it (|a| ~ max + 3/8 min, cos = a.b / |a||b|
; to 1/64; a cut over 75 deg: none)
.proc nx_eval
    lda #$FF
    sta nxb
    sta nxb+1
    lda ex+1
    lsr @
    sta nxp
    lda ey+1
    lsr @
    sta nxp+1
    lda #0
    sta nxi
lp:
    lda nxi
    cmp nxn
    jcs out
    asl @                   ; * 6
    adc nxi
    asl @
    sta nxy
    tay
    lda nxe+5,y             ; weight 0: its way from the cue ball blocked (nxclr)
    jeq nx
    sec                     ; a = the ball - the cue
    lda nxe,y
    sbc nxp
    sta nxax
    lda nxe+1,y
    sbc nxp+1
    sta nxay
    lda nxax                ; dot = ax bdx + ay bdy
    ldx nxe+2,y
    jsr smul8
    sta nxdt
    stx nxdt+1
    ldy nxy
    lda nxay
    ldx nxe+3,y
    jsr smul8
    clc
    adc nxdt
    sta nxdt
    txa
    adc nxdt+1
    sta nxdt+1
    jmi nx                  ; behind the ball (a cut over 90 deg)
    ora nxdt
    jeq nx
    lda nxax                ; |a| ~ max + 3/8 min
    bpl a1
    eor #$FF
    adc #1                  ; (C = 0)
a1:
    sta nxa
    lda nxay
    bpl a2
    eor #$FF
    clc
    adc #1
a2:
    cmp nxa
    bcc a3
    ldx nxa                 ; swap: nxa = max, A = min
    sta nxa
    txa
a3:
    sta nxm                 ; min * 3 / 8
    asl @
    adc nxm
    lsr @
    lsr @
    lsr @
    clc
    adc nxa
    sta nxa
    ldy nxy                 ; den = |a| |b|
    ldx nxe+4,y
    jsr fmulu
    lda fmpl
    sta nxdn
    lda fmph
    sta nxdn+1
    lda nxdt                ; r = dot 64 / den (dot >= den: 64)
    cmp nxdn
    lda nxdt+1
    sbc nxdn+1
    bcc dv
    lda #64
    bne rr                  ; (always)
dv:
    lda #1                  ; 6 bits (the 1 shifts out to C after them)
    sta nxr
d6:
    asl nxdt
    rol nxdt+1
    sec
    lda nxdt
    sbc nxdn
    tax
    lda nxdt+1
    sbc nxdn+1
    bcc d0
    sta nxdt+1
    stx nxdt
d0:
    rol nxr
    lda nxr
    cmp #64
    bcc d6
    and #63
rr:
    cmp #17                 ; cos < 17/64: a cut over 75 deg
    jcc nx
    tax
    lda nxi_c-17,x
    cpx #45                 ; a cut over 45 deg: half as hard again, over 60: twice --
    bcs rk                  ;   no position (a pro leaves himself a half to three-quarter
    cpx #32                 ;   ball: Davis, Planning; White)
    bcc dbl
    sta nxr
    lsr @
    adc nxr                 ; (+ the half, rounded up by the bit out)
    bcc rk
    bcs sat8                ; (always)
dbl:
    asl @
    bcc rk
sat8:
    lda #255
rk:
    sta nxr
    lda nxa                 ; t = (|a| + 10) |b|
    clc
    adc #10
    bcc a4
    lda #$FF
a4:
    ldy nxy
    ldx nxe+4,y
    jsr fmulu
    lda fmph
    sta nxt+1
    lda fmpl                ; e = t * 16/cos^2 >> 2 (= ai_plan's ease): tL c ...
    ldx nxr
    jsr fmulu
    lda fmpl
    sta nxt
    lda fmph
    sta nxt+2
    lda nxt+1               ; ... + tH c << 8
    ldx nxr
    jsr fmulu
    clc
    lda fmpl
    adc nxt+2
    sta nxt+1
    lda fmph
    adc #0
    cmp #4                  ; >> 2 >= 65536: $FFFF
    bcs sat
    lsr @
    ror nxt+1
    ror nxt
    lsr @
    ror nxt+1
    ror nxt
    lda nxt
    ldx nxt+1
    jmp cb
sat:
    lda #$FF
    tax
cb:
    ldy nxy                 ; * the weight / 8 (a black 5/8: the one to play for)
    pha
    lda nxe+5,y
    tay
    pla
    cpy #8
    beq wc
    jsr wmul8
wc:
    cmp nxb                 ; easier?
    tay
    txa
    sbc nxb+1
    bcs nx
    sty nxb
    stx nxb+1
    lda nxy                 ; (which: pscore's next ball)
    sta nxbi
nx:
    inc nxi
    jmp lp
out:
    lda nxb
    ldx nxb+1
    rts
.endp

; smul8: A, X signed bytes -> A:X = their product (16-bit signed)
.proc smul8
    sta nxs
    stx nxs+1
    eor nxs+1               ; N: the product's sign
    php
    lda nxs
    bpl p1
    eor #$FF
    clc
    adc #1
p1:
    sta nxs
    lda nxs+1
    bpl p2
    eor #$FF
    clc
    adc #1
p2:
    tax
    lda nxs
    jsr fmulu
    plp
    bpl ps
    sec
    lda #0
    sbc fmpl
    tay
    lda #0
    sbc fmph
    tax
    tya
    rts
ps:
    lda fmpl
    ldx fmph
    rts
.endp

; ladd: A:X -> lmin += it (saturating)
.proc ladd
    clc
    adc lmin
    sta lmin
    txa
    adc lmin+1
    bcc ok
    lda #$FF
    sta lmin
ok:
    sta lmin+1
    rts
.endp

NX_MAX  = 40                ; (* 6 < 256; 240 bytes: page 3)
nxn     dta 0
nxi     = $060F             ; nx_eval's temporaries (page 5's free RAM, $060F-$061B)
nxy     = $0610
nxp     = $0611             ; (2)
nxax    = $0613
nxay    = $0614
nxa     = $0615
nxm     = $0616
nxr     = $0617
nxd     dta 0, 0
nxdt    = $0618             ; (2)
nxdn    = $061A             ; (2)
nxb     dta 0, 0
nxt     dta 0, 0
nxs     dta 0, 0
nxe     = $0300             ; (NX_MAX * 6) x, y, dx, dy, run (32 mm units), weight /8: the OS's
                            ;   page 3 (SIO / CIO blocks: no I/O once loaded; scratch, never loaded)
nxmd    dta 0               ; nx_build's mode: 0 the opponent's, 1 the computer's next

; s3clr / s3ins / s3pick: the 3 best safeties of the model, then tried in the
; physics (sim_shot) -- the one whose real leave is best is played (as
; Franky100-pig/Billiards-solo's bot: the geometry picks, the physics decides).
; s3r: 8 bytes a place: the leave (2), the ball, psi (2), the power, cd+1.
.proc s3clr
    lda #0
    sta s3n
    sta s3n8
    ldx #S3_N*8-1
c:
    sta s3r,x
    dex
    bpl c
    rts
.endp

; s3ins: the candidate (at0 its leave; at, psi, spi, cd+1) into s3r, best first,
; one a ball and kind (its best: the model's and sfscan's, spi bit 7, apart -- the
; model's guess for a ball must not push out the shot played in the physics)
.proc s3ins
    ldy #0                  ; its place: before the first it is ahead of
p:
    cpy s3n8
    bcs ip
    lda s3r,y
    cmp at0
    lda s3r+1,y
    sbc at0+1
    bcc ip
    lda s3r+2,y             ; a better one of this ball and kind there: not this one
    cmp at                  ;   (one a ball -- else the model's favourite fills the list)
    bne pn
    lda s3r+5,y
    eor spi
    bpl rj
pn:
    tya
    sec
    adc #8-1
    tay
    cpy #S3_N*8
    bcc p
rj:
    rts                     ; (not among the best S3_N)
ip:
    sty s3p
    ldy #S3_N*8-9           ; the ones from there one place down
sd:
    cpy s3p
    bcc sx
    lda s3r,y
    sta s3r+8,y
    dey
    bpl sd
sx:
    ldy s3p
    lda at0
    sta s3r,y
    lda at0+1
    sta s3r+1,y
    lda at
    sta s3r+2,y
    lda psi
    sta s3r+3,y
    lda psi+1
    sta s3r+4,y
    lda spi
    sta s3r+5,y
    lda cd+1
    sta s3r+6,y
    lda s3n8
    cmp #S3_N*8
    bcs ok
    adc #8                  ; (C = 0)
    sta s3n8
    inc s3n
ok:
    lda s3p                 ; a worse one of this ball after it: out
    clc
dl:
    adc #8
    tay
    cpy s3n8
    bcs rj
    lda s3r+2,y
    cmp at
    bne dn
    lda s3r+5,y
    eor spi
    bpl rm
dn:
    tya
    clc
    bcc dl                  ; (always)
rm:
    lda s3r+8,y             ; the rest one place up
    sta s3r,y
    iny
    cpy s3n8
    bcc rm
    lda s3n8
    sbc #8                  ; (C = 1)
    sta s3n8
    dec s3n
    rts
.endp

; s3pick: each of the list played in the physics five times -- as planned and
; with his aim error e and e / 2 either side -- each counted 1/8: a foul (no ball
; on first, the cue ball down) 0, the object ball down the best, else leave's
; leave of where they really stop (+ psnk's snooker) -> bt, sbpsi, tpw, edc,
; sbest (bt $FF: none).  (Three aims missed a thin safety's fouls between them.)
.proc s3pick
    lda #$FF
    sta bt
    lda #0
    sta sbest
    sta sbest+1
    sta s3i
    lda #1                  ; its sims end when the cue ball and the ball played stop:
    sta squick              ;   all it reads (leave: the others where they were)
lp:
    lda s3i
    cmp s3n
    bcc go
    lsr squick              ; (1 -> 0)
    rts
go:
    asl @
    asl @
    asl @
    sta s3y
    tay
    jsr s3aim               ; its aim -> cz, its power -> stpw (ai2.asm)
    ldx aip                 ; the aim: as planned + e, then - e / 2 a time (e: his aim error)
    lda ai_err-1,x
    lsr @
    sta s3e
    asl @                   ; (+ e, even)
    clc
    adc cz
    sta stgt
    lda cz+1
    adc #0
    sta stgt+1
    lda #0                  ; its five, 1/8 each -- Davis: percentage play, a safety that
    sta s3w                 ;   only works when struck perfectly is no safety for him
    sta s3w+1
    lda #4
    sta s3k
kl:
    jsr sim_shot
    lda #0                  ; a foul: the worst (0)
    sta at0
    sta at0+1
    lda scon                ; the cue ball down
    beq wm
    ldx sfc                 ; the first ball: one on
    bmi wm
    jsr ison
    bcc wm
    ldx #3                  ; where they stopped -> leave (the ball played down as well:
c:                          ;   its leave as any, lsafe's + 500 mm)
    lda scx,x
    sta ex,x
    lda sox,x
    sta oex,x
    dex
    bpl c
    ldy s3y
    lda s3r+2,y
    sta at
    jsr leavep              ; (ai2.asm: the leave, his ways from the cue ball checked)
    jsr psnk                ; snookered: the best safety there is
    jsr lsafe               ; (aipos.asm: the balls disturbed, the ball down)
wm:
    lda at0+1               ; / 8 (five: <= $9FFB): the high byte shifted in A
    lsr @
    ror at0
    lsr @
    ror at0
    lsr @
    ror at0
    sta at0+1
    clc
    lda s3w
    adc at0
    sta s3w
    lda s3w+1
    adc at0+1
    sta s3w+1
wn:
    sec                     ; the next aim: - e
    lda stgt
    sbc s3e
    sta stgt
    bcs w0
    dec stgt+1
w0:
    dec s3k
    jpl kl
    lda s3w
    sta at0
    lda s3w+1
    sta at0+1
sc:
    lda sbest               ; the best so far?
    cmp at0
    lda sbest+1
    sbc at0+1
    bcs nx
    lda at0
    sta sbest
    lda at0+1
    sta sbest+1
    ldy s3y                 ; (sbpsi: its place in the list -- ai_safe's s3aim)
    sty sbpsi
    lda s3r+2,y
    sta bt
    lda s3r+6,y
    sta edc
    ldx #2
tp:
    lda stpw,x
    sta tpw,x
    dex
    bpl tp
nx:
    inc s3i
    jmp lp
.endp
    ert scy<>scx+2 || soy<>sox+2 || ey<>ex+2 || oey<>oex+2

; wmul8: A:X * Y / 8 -> A:X (at most $FFFF)
.proc wmul8
    stx wmv+1
    sty wmw
    ldx wmw
    jsr fmulu               ; lo * w
    lda fmpl
    sta wmv
    lda fmph
    pha
    lda wmv+1
    ldx wmw
    jsr fmulu               ; hi * w << 8
    pla
    clc
    adc fmpl
    sta wmv+1
    lda fmph
    adc #0
    cmp #8                  ; >> 3 >= 65536
    bcs sat
    ldx #3
s:
    lsr @
    ror wmv+1
    ror wmv
    dex
    bne s
    lda wmv
    ldx wmv+1
    rts
sat:
    lda #$FF
    tax
    rts
.endp

s3n     dta 0
s3e     = $060A             ; (1) s3pick: his aim error (page 5's free RAM: sim_shot's
s3w     = $060B             ; (2)   scopy saves and puts it back) the worst leave of three
s3k     = $060D             ; (1)
s3n8    dta 0
s3i     dta 0
s3y     dta 0
s3p     dta 0
S3_N    = 3                 ; the safeties tried three times in the physics (s3pick)
s3r     :S3_N*8 dta 0
wmv     dta 0, 0
wmw     dta 0

; nexton: X = a ball -> C = 1 when it is on after this pot of bt: a red's: the
; colours; a colour's: the reds while any are left, else the yellow; in the
; sequence: the next colour on the table.  Keeps X.
.proc nexton
    cpx bt
    beq no
    lda BON,x
    beq no
    lda onk
    bne c1
    cpx #16                 ; a red on: the colours (C = X >= 16)
    rts
c1:
    cmp #1
    bne sq
    lda redsl
    beq yl
    cpx #16                 ; a colour on, reds left: a red
    bcs no
    sec
    rts
yl:
    cpx #16                 ; the last red's colour: the yellow next
    bne no
    sec
    rts
sq:
    stx ttmp                ; the sequence: the lowest colour on the table after bt
    ldy bt
s1:
    iny
    cpy #NB
    bcs no
    lda BON,y
    beq s1
    cpy ttmp
    bne no
    sec
    rts
no:
    clc
    rts
.endp

; ppev: sim_shot's end, the table as it stopped (its own RAM still): the
; computer's next pot from the cue ball -> sev (nx_eval of nexton's balls -- the
; list kset built once, built again only when the shot moved or potted a ball
; besides the cue and bt (pmov); none: pclose), then the leave's word (pscore,
; aipos.asm: the balls it moved, where the cue ball lies, the shot itself)
.proc ppev
    jsr pchk                ; (ai2.asm: the list stale?)
    bcc kp
    lda #1
    jsr nx_build
kp:
    ldx #3
c:
    lda scx,x
    sta ex,x
    dex
    bpl c
    jsr nxclr               ; (ai2.asm: nx_eval, the cue ball's way to it clear)
    sta sev
    stx sev+1
    and sev+1               ; no pot from there: the nearest ball on, at least
    cmp #$FF
    bne pd
    jsr pclose              ; (ai2.asm)
pd:
    jmp pscore              ; (aipos.asm)
.endp






; psnk: the cue ball at (ex, ey) after a safety: no ball the opponent is on can be
; hit straight (every way to one passes within 2R of another ball: blocked) ->
; a snooker, the best safety (Davis; White: Safety and Snookers): at0 += 2 m.
; The cue ball's RAM place is moved to (ex, ey) for ctot meanwhile (blocked
; skips the cue ball), put back after.
.proc psnk
    ldx #3
s:
    lda at0-2,x             ; (at0: blocked's; the cue ball's place) on the stack
    pha
    dex
    bpl s
    lda X1
    pha
    lda X2
    pha
    lda Y1
    pha
    lda Y2
    pha
    lda ex
    sta X1
    lda ex+1
    sta X2
    lda ey
    sta Y1
    lda ey+1
    sta Y2
    lda #0
    sta psc
    ldx #NB-1
l:
    stx at
    lda BON,x
    beq n
    jsr oppon
    bcc n
    inc psc
    jsr tload               ; T: the ball; ctot: cz, cd of T - the cue ball
    jsr ctot
    ldx #3
c:
    lda ex,x
    sta absx,x
    dex
    bpl c
    lda cz
    sta bang
    lda cz+1
    sta bang+1
    sec                     ; the way to the contact, not to its centre (the balls
    lda cd                  ;   touching it, the pack's, are not in the way); within
    sbc #120                ;   120 mm: it can be hit (no way to block)
    lda cd+1
    sbc #0
    bcc fr
    lda cd                  ; (C = 1: the bcc not taken -- 2026-10-28 6502-idioms: no sec)
    sbc #60
    pha
    lda cd+1
    sbc #0
    tax
    pla
    jsr blocked
    bcc fr                  ; a way to it: no snooker
n:
    ldx at
    dex
    bne l
    beq pr                  ; (always: psc <> 0 snookered; none on: 0, nothing to snooker)
fr:
    lda #0
    sta psc
pr:
    pla
    sta Y2
    pla
    sta Y1
    pla
    sta X2
    pla
    sta X1
    ldx #0
r:
    pla
    sta at0-2,x
    inx
    cpx #4
    bne r
    lda psc
    beq ns
    clc                     ; + 16000 (2 m in 1/8 mm), saturating
    lda at0
    adc #<16000
    sta at0
    lda at0+1
    adc #>16000
    bcc ok
    lda #$FF
    sta at0
ok:
    sta at0+1
ns:
    rts
.endp
    ert absy<>absx+2 || ey<>ex+2
psc     = $060E             ; (1) psnk: the balls on it looked at (RAM, as s3e)

    ert *>$3000             ; the first half: to V:AI_BANK000
    :$3000-* dta 0
    ini vram_next
    org $3000,$2000         ; the second half: staged at $2000 too

; cordic: (cx, cy) 24-bit signed Q4 -> cz = its angle (65536 a turn), cd = its
; length in mm.  Vectoring: 14 turns by atan 2^-i drive y to 0.
.proc cordic
    lda #0
    sta cz
    sta cz+1
    sta aci
    lda cx+2
    bpl it
    lda #$80                ; x < 0: half a turn first
    sta cz+1
    sec
    lda #0
    sbc cx
    sta cx
    lda #0
    sbc cx+1
    sta cx+1
    lda #0
    sbc cx+2
    sta cx+2
    sec
    lda #0
    sbc cy
    sta cy
    lda #0
    sbc cy+1
    sta cy+1
    lda #0
    sbc cy+2
    sta cy+2
it:
    ldy aci                 ; t = x >> i, u = y >> i (aifast.asm, in RAM)
    jsr csh
sh0:
    ldy aci
    lda cy+2
    bmi neg
    clc                     ; y >= 0: x += u, y -= t, z += atan
    lda cx
    adc cty
    sta cx
    lda cx+1
    adc cty+1
    sta cx+1
    lda cx+2
    adc cty+2
    sta cx+2
    sec
    lda cy
    sbc ctx
    sta cy
    lda cy+1
    sbc ctx+1
    sta cy+1
    lda cy+2
    sbc ctx+2
    sta cy+2
    clc
    lda cz
    adc ai_atl,y
    sta cz
    lda cz+1
    adc ai_ath,y
    sta cz+1
    jmp nx
neg:
    sec                     ; y < 0: x -= u, y += t, z -= atan
    lda cx
    sbc cty
    sta cx
    lda cx+1
    sbc cty+1
    sta cx+1
    lda cx+2
    sbc cty+2
    sta cx+2
    clc
    lda cy
    adc ctx
    sta cy
    lda cy+1
    adc ctx+1
    sta cy+1
    lda cy+2
    adc ctx+2
    sta cy+2
    sec
    lda cz
    sbc ai_atl,y
    sta cz
    lda cz+1
    sbc ai_ath,y
    sta cz+1
nx:
    inc aci
    lda aci
    cmp cit                 ; 9 turns (0.2 deg) while choosing, 14 for the shot played
    jne it
; [2026-10-28 6502-idioms/SKILL.md: no shift ladder in memory; 6502-loops-tables-smc/SKILL.md:
;  tables beat arithmetic -- each byte of x >> 4 is x16[the byte above & $0F] | shr4[its own]
;  (cx dies here: only csh and this read it)]
    lda cx+2                ; d = (x >> 4) * 155 / 256 (x = 1.6468 |v|, Q4)
    and #$0F
    tax
    ldy cx+1
    lda shr4,y
    ora x16,x
    sta ttmp                ; (x >> 4) hi
    tya
    and #$0F
    tax
    ldy cx
    lda shr4,y
    ora x16,x
    ldx #155                ; lo * 155 / 256
    jsr fmulu
    lda fmph
    sta cd
    lda ttmp
    ldx #155
    jsr fmulu
    clc
    lda fmpl
    adc cd
    sta cd
    lda fmph
    adc #0
    sta cd+1
    rts
.endp

; trig: cz >> 6 -> btr = cos, btr+3 = sin (Q16, 24-bit); cz consumed
.proc trig
    lda cz+1
    sta ang2
    lda #0
    asl cz
    rol ang2
    rol @
    asl cz
    rol ang2
    rol @
    sta ang2+1
    ldx #0
    jsr tc
    clc
    lda ang2
    adc #<768
    sta ang2
    lda ang2+1
    adc #>768
    and #3
    sta ang2+1
    ldx #3
tc:
    stx ttmp
    jsr cosptr
    ldx ttmp
    ldy #0                  ; [2026-10-28 6502-cycles-layout/SKILL.md: unrolled -- 3 bytes,
    lda (aptr),y            ;  no inx / cpy / bne a byte]
    sta btr,x
    iny
    lda (aptr),y
    sta btr+1,x
    iny
    lda (aptr),y
    sta btr+2,x
    rts
.endp

; tmul: A:X = a 16-bit factor, Y = 0 cos / 3 sin -> sP = factor * btr >> 16
.proc tmul
    sta sA
    stx sA+1
    lda #0
    sta sA+2
    lda btr,y
    sta sB
    lda btr+1,y
    sta sB+1
    lda btr+2,y
    sta sB+2
    jmp smul3r
.endp

; blocked: from (absx, absy) along bang for A:X mm -- C = 1 when a ball (not the
; cue, not ball `at`) lies within 2R of the path
.proc blocked
    tay                     ; mm -> Q4 (<< 4, 16 bits) by x16 / shr4 [2026-10-28
    txa                     ;   6502-idioms/SKILL.md: no shift ladder in memory;
    and #$0F                ;   6502-loops-tables-smc/SKILL.md: tables beat arithmetic]
    tax
    lda x16,x
    ora shr4,y
    sta blen+1
    tya
    and #$0F
    tay
    lda x16,y
    sta blen
    clc                     ; the far limit: length + 2R
    lda blen
    adc #<AI_2R
    sta blim
    lda blen+1
    adc #>AI_2R
    sta blim+1
    lda #0
    adc #0
    sta blim+2
    lda bang
    sta cz
    lda bang+1
    sta cz+1
    jsr trig
    ldx #0                  ; the path's box, once (ai2.asm; fable-skill-atari: the cheap
    jsr bbox                ;   rejection first -- outside it no ball is within 2R +
    ldx #3                  ;   8 mm of the path: what follows would pass it anyway)
    jsr bbox
    ldx #NB-1
lp:
    stx bbi
    cpx at
    jeq nx
    lda BON,x
    jeq nx
    lda blg                 ; 1: a ball on in the way is hit first legally (a safety);
    beq bc                  ;   2: every ball counts, but only a real first contact
    cmp #2
    beq bc
    jsr ison
    jcs nx
bc:
; [2026-10-28 fable-skill-atari/SKILL.md 3: the cheap rejection first, by what it needs --
;  the path's box reads only the ball's X / Y: ahead of the d it would throw away]
    lda X1,x                ; outside the path's box (x, then y)
    cmp bxl
    lda X2,x
    sbc bxl+1
    jcc nx
    lda bxh
    cmp X1,x
    lda bxh+1
    sbc X2,x
    jcc nx
    lda Y1,x
    cmp bxl+3
    lda Y2,x
    sbc bxl+4
    jcc nx
    lda bxh+3
    cmp Y1,x
    lda bxh+4
    sbc Y2,x
    jcc nx
    sec
    lda X1,x
    sbc absx
    sta bdx
    lda X2,x
    sbc absx+1
    sta bdx+1
    lda #0
    sbc #0
    sta bdx+2
    sec
    lda Y1,x
    sbc absy
    sta bdx+3
    lda Y2,x
    sbc absy+1
    sta bdx+4
    lda #0
    sbc #0
    sta bdx+5
    lda bdx+2               ; both products negative: behind the start
    eor btr+2
    bpl fw
    lda bdx+5
    eor btr+5
    jmi nx
fw:
    ldx #0                  ; |dx| or |dy| > the length + 2R: too far
    jsr absgt
    jcs nx
    ldx #3
    jsr absgt
    jcs nx
    ldx #0                  ; along = dx cos + dy sin
    ldy #0
    jsr dmul
    jsr keep
    ldx #3
    ldy #3
    jsr dmul
    clc
    lda sP
    adc bk
    sta bk
    lda sP+1
    adc bk+1
    sta bk+1
    lda sP+2
    adc bk+2
    bmi nx                  ; behind the start
    bne nx                  ; far past the end
    lda bk
    cmp blen
    lda bk+1
    sbc blen+1
    bcs nx                  ; past the end
    ldx #3                  ; perp = dy cos - dx sin
    ldy #0
    jsr dmul
    jsr keep
    ldx #0
    ldy #3
    jsr dmul
    sec
    lda bk
    sbc sP
    sta bk
    lda bk+1
    sbc sP+1
    sta bk+1
    lda bk+2
    sbc sP+2
    sta bk+2
    bpl pp
    sec
    lda #0
    sbc bk
    sta bk
    lda #0
    sbc bk+1
    sta bk+1
    lda #0
    sbc bk+2
pp:
    bne nx                  ; >= 2^16 away
    ldy blg
    cpy #2
    beq ex
    lda bk
    cmp #<[AI_2R+128]
    lda bk+1
    sbc #>[AI_2R+128]
    bcs nx
    sec                     ; within 2R + 8 mm (his aim error): blocked
    rts
ex:
    lda bk                  ; blg 2: within 2R -- it is touched before the target
    cmp #<AI_2R
    lda bk+1
    sbc #>AI_2R
    bcs nx
    sec
    rts
nx:
    ldx bbi
    dex
    jne lp
    clc
    rts
keep:
    lda sP
    sta bk
    lda sP+1
    sta bk+1
    lda sP+2
    sta bk+2
    rts
.endp

; nearp: d = bdx (dx, dy) -> C = 1 when it lies along the last blocked() path
; (btr, blen) within 100 mm of it
.proc nearp
    ldx #0                  ; along = dx cos + dy sin
    ldy #0
    jsr dmul
    jsr blocked.keep
    ldx #3
    ldy #3
    jsr dmul
    clc
    lda sP
    adc bk
    sta bk
    lda sP+1
    adc bk+1
    sta bk+1
    lda sP+2
    adc bk+2
    bmi no                  ; behind
    bne no
    lda bk
    cmp blen
    lda bk+1
    sbc blen+1
    bcs no                  ; past the end
    ldx #3                  ; perp = dy cos - dx sin
    ldy #0
    jsr dmul
    jsr blocked.keep
    ldx #0
    ldy #3
    jsr dmul
    sec
    lda bk
    sbc sP
    sta bk
    lda bk+1
    sbc sP+1
    sta bk+1
    lda bk+2
    sbc sP+2
    sta bk+2
    bpl pp
    sec
    lda #0
    sbc bk
    sta bk
    lda #0
    sbc bk+1
    sta bk+1
    lda #0
    sbc bk+2
pp:
    bne no
    lda bk
    cmp #<[100*16]
    lda bk+1
    sbc #>[100*16]
    bcs no
    sec                     ; within 100 mm
    rts
no:
    clc
    rts
.endp

; absgt: X = 0 dx / 3 dy -> C = 1 when |d| > blim (24 bits).  Keeps X.
.proc absgt
    lda bdx+2,x
    bpl ps
    clc                     ; d < 0: |d| > lim when d + lim < 0
    lda bdx,x
    adc blim
    lda bdx+1,x
    adc blim+1
    lda bdx+2,x
    adc blim+2
    asl @                   ; (C: the sign)
    rts
ps:
    sec                     ; d >= 0: |d| > lim when lim - d < 0
    lda blim
    sbc bdx,x
    lda blim+1
    sbc bdx+1,x
    lda blim+2
    sbc bdx+2,x
    asl @
    rts
.endp

; dmul: X = 0 dx / 3 dy, Y = 0 cos / 3 sin -> sP = d * trig >> 16
.proc dmul
    lda bdx,x
    sta sA
    lda bdx+1,x
    sta sA+1
    lda bdx+2,x
    sta sA+2
    lda btr,y
    sta sB
    lda btr+1,y
    sta sB+1
    lda btr+2,y
    sta sB+2
    jmp smul3r
.endp

ai_atl  dta <8192, <4836, <2555, <1297, <651, <326, <163, <81, <41, <20, <10, <5, <3, <1
ai_ath  dta >8192, >4836, >2555, >1297, >651, >326, >163, >81, >41, >20, >10, >5, >3, >1
; 32 / cos^2 of the cut, in 2.8 deg steps (the middle of each)
ai_fl   dta <32, <32, <32, <33, <34, <34, <35, <37, <38, <40, <42, <45, <48, <51, <56, <61, <67, <75, <85, <97, <112, <132, <158, <195, <247, <325, <450
ai_fh   dta >32, >32, >32, >33, >34, >34, >35, >37, >38, >40, >42, >45, >48, >51, >56, >61, >67, >75, >85, >97, >112, >132, >158, >195, >247, >325, >450
; the pockets' mouths (geom.inc order: corners (0,0) (L,0) (0,W) (L,W), the
; middles (L/2,0) (L/2,W)): the object ball's direction in [lo, lo + range)
; a corner takes a ball from 1 to 88 deg off either rail (along a rail the ball kisses
; it before the mouth and still drops: pocket_test's mouth; White ch. 1: rolling along
; the top cushion into the pocket is reliable); a middle within 45 deg of square
ai_plo  dta <32950, <49334, <16566, <182, <40960, <8192
ai_phi  dta >32950, >49334, >16566, >182, >40960, >8192
ai_prh  dta >16020, >16020, >16020, >16020, >16384, >16384

; the AI's cells (cold code: here, not in zero page)
aitm    dta 0
tgt     = $0602             ; (2) the aim, 1/64 units (page 5's free RAM: both AI banks
tpw     = $0604             ; (3)   reach them -- ai2.asm's opening sets them) the power
best    = $0607             ; (2)
ease    dta 0, 0
at      dta 0               ; the ball looked at
ap      dta 0               ; the pocket
at0     dta 0, 0
ttmp    dta 0
tx      dta 0, 0            ; T, G (Q4)
ty      dta 0, 0
gx      dta 0, 0
gy      dta 0, 0
phi     dta 0, 0
aim     dta 0, 0
dtp     dta 0, 0
cf      dta 0, 0
dd      dta 0, 0            ; the chosen shot's D (mm)
edc     = $0609             ; (1) its cue-to-ghost distance / 256 mm (RAM, as tgt)
ar      dta 0
cx      dta 0, 0, 0
cy      dta 0, 0, 0
cz      dta 0, 0
cd      dta 0, 0
aci      dta 0
ctx     dta 0, 0, 0
cty     dta 0, 0, 0
btr     dta 0, 0, 0, 0, 0, 0
bdx     dta 0, 0, 0, 0, 0, 0
bk      dta 0, 0, 0
absx     dta 0, 0
absy     dta 0, 0
bang    dta 0, 0
blen    dta 0, 0
bbi     dta 0
blim    dta 0, 0, 0
cit     dta 14              ; cordic turns
abp      dta 0               ; the best pot: its pocket
    icl "aisafe.asm"                    ; the safety (the second half: the first is full)


; ppw: A = the speed * 8 -> tpw (pset) at ppr * A / 8 (255 at most)
.proc ppw
    ldx ppr
    jsr fmulu
    lda fmph                ; >> 3
    cmp #8
    bcs sat
    sta ttmp
    lda fmpl
    lsr ttmp
    ror @
    lsr ttmp
    ror @
    lsr ttmp
    ror @
    dta $2C                 ; (bit abs: skips the lda #255)
sat:
    lda #255
    jmp pset
.endp

; ptry: A = the tip (spin 0..8), Y = the speed * 8, X = the side -> the pot played
; in the physics; potted cleanly and a better next pot (sev): pbt, pbk, pbs
.proc ptry
    sta sspin
    stx sside
    sty pck
    tya
    jsr ppw                 ; tpw: this one's speed
    ldx #2
c0:
    lda tpw,x
    sta stpw,x
    dex
    bpl c0
    lda tgt
    sta stgt
    lda tgt+1
    sta stgt+1
    lda bt
    sta sat
    jsr sim_shot
    lda scon                ; the cue ball down
    beq nx
    lda soon                ; not potted
    bne nx
    lda sfc                 ; another ball first
    cmp bt
    bne nx
    lda sev                 ; the leave (ppev, pscore): better than this pot's best?
    cmp ppb
    lda sev+1
    sbc ppb+1
    bcs nx
    lda sev
    sta ppb
    lda sev+1
    sta ppb+1
    lda sspin
    sta pbt
    lda sside
    sta pbs
    lda pck
    sta pbk
nx:
    rts
.endp

; d16: A:X = a distance (mm) -> A = min(255, d / 16)
.proc d16
    stx ttmp
    lsr ttmp
    ror @
    lsr ttmp
    ror @
    lsr ttmp
    ror @
    lsr ttmp
    ror @
    ldx ttmp
    beq ok
    lda #$FF
ok:
    rts
.endp

pvs     dta 4, 0, 8, 4, 0, 8, 4, 0, 8, 4, 0, 8   ; the tip: centre, full screw, full follow
pvk     dta 8, 8, 8, 12, 12, 12, 18, 18, 18, 26, 26, 26 ; the speed * 8 (26: the split's, cnsp)
pvn     dta 0               ; round 1's ways: PV_N, + 3 when the pack must be opened (cnset)
pdt     dta -2, 2, 0, 0, 0, 0           ; round 2: the tip, the speed, the side
pdk     dta 0, 0, -3, 4, 0, 0
pds     dta 4, 4, 4, 4, 2, 6
ppi     dta 0
pck     dta 0
pbt     dta 0               ; the best: its tip, speed * 8, side
pbk     dta 0
pbs     dta 0
pb0     dta 0, 0            ; round 1's best (tip, speed)
ppr     dta 0
ppb     dta 0, 0

ppx     = $05D6             ; (22) the balls before the shot, X2 (page 5's free RAM:
ppy     = $05EC             ;   sim_shot keeps it till ppev reads it); (22) Y2
    ert ty-tx<>gy-gx
    ert gx<tx
    ert *>$4000
    ini vram_next
