; [2026-10-21 6502-idioms/SKILL.md: count down to zero, carry tracked (C after cmp / bcc,
;  the clear carry is the -1 in needs), jsr X / rts -> jmp X; 6502-nmos-atari/SKILL.md: NMOS
;  opcodes only; 6502-loops-tables-smc/SKILL.md: index counting down to zero (tab-1,x)]
; [2026-10-21 fable-skill-atari/SKILL.md: the cheap rejection first -- corr's box decides most
;  balls with compares only, edges' maths only for the rest; in corr the box before ison; 6502-idioms/SKILL.md: d's shift
;  in A (not ror in memory), needs' colour loop counts to zero (no cpx); use what was
;  already produced: the four products of an edge pair once for both sides (4 mul48 of 8),
;  eset / eadd gone (ecomb); 6502-cycles-layout/SKILL.md: zero page is the register file --
;  ediv's cells are the math cells (enum mA, erem mrem, eq mQ, the divisor mtmp)]
; snooker.asm -- the snooker test (WPBSA: both extreme edges of a ball on, in a
; straight line, free of balls not on), the free ball and the foul and a miss
; (the balls replaced, three misses lose the frame).  Cold code: once a shot.

; snap: the position as the cue is struck (shot_begin): the six position
; arrays, BON, the reds left and the ball on
.proc snap
    ldx #$C0
lp:
    lda X0-1,x
    sta SPOS-1,x
    dex
    bne lp
    ldx #NB
b:
    lda BON-1,x
    sta SBON-1,x
    dex
    bne b
    lda redsl
    sta sred
    lda expcol
    sta sexp
    ldx #3                  ; the scores at the stroke
sc:
    lda sclo,x
    sta ssc,x
    dex
    bpl sc
    rts
.endp

; swap: the position now <-> the one kept (the snooker test at the stroke)
.proc swap
    ldx #$C0
lp:
    ldy X0-1,x
    lda SPOS-1,x
    sta X0-1,x
    tya
    sta SPOS-1,x
    dex
    bne lp
    ldx #NB
b:
    ldy BON-1,x
    lda SBON-1,x
    sta BON-1,x
    tya
    sta SBON-1,x
    dex
    bne b
    rts
.endp

; replace: the balls back where they were at the stroke (at rest, re-projected),
; the reds left and the ball on as then; the cue out of hand
.proc replace
    ldx #$C0
lp:
    lda SPOS-1,x
    sta X0-1,x
    dex
    bne lp
    ldx #NB-1
b:
    lda SBON,x
    sta BON,x
    lda DIRTY,x
    ora #1
    sta DIRTY,x
    jsr park                ; (keeps X)
    dex
    bpl b
    lda #0
    sta projvalid
    sta inhand
    sta hwait
    lda sred
    sta redsl
    lda sexp
    sta expcol
    rts
.endp

; choose: a request after a foul made -- the offender to play, no free ball
; (void then), no message
.proc choose
    lda #0
    sta fchoice
    sta fball
    sta msgc                ; (the bar: no FOUL any more)
    lda turn
    eor #1
    sta turn
    rts
.endp

; missq: a foul -- WPBSA Rules 2024-25, Section 3 Rule 14: a FOUL AND A MISS
; when the ball on was not hit first while a straight line to some part of a
; ball on was free at the stroke (c), unless any player required penalty points
; before or after it (a)(i) -- not inside a full-ball miss sequence (d)(i) -- or
; it was a free ball shot.  Only a miss with a full ball in sight counts toward
; the third, which gives the opponent the frame (d).
.proc missq
    lda #0
    sta missf
    lda fbs                 ; (a free ball shot: no miss)
    jne out
    ldx fcon
    bmi chk                 ; nothing hit
    jsr ison
    jcs out                 ; the ball on first: another foul
chk:
    lda mcnt                ; in a full-ball sequence: regardless of the scores
    beq n1
    jsr swap
    jmp sight
n1:
    ldx #3                  ; after the stroke: either player needs snookers?
a1:
    lda sclo,x
    sta wsc,x
    dex
    bpl a1
    lda redsl
    jsr needs
    bcs out
    ldx #3                  ; before it: the scores, the balls and the reds then
b1:
    lda ssc,x
    sta wsc,x
    dex
    bpl b1
    jsr swap
    lda sred
    jsr needs
    bcs sw                  ; (C = 1: back, no miss)
sight:
    lda #1                  ; the sight at the stroke: a full ball (C), a part (spart)
    sta ewant
    jsr snooker
    lda #0
    sta ewant
    rol @                   ; A = 1: no full ball in sight
    eor #1                  ; A = 1: a full ball
    sta wsc                 ; (wsc is spent: the full flag)
    lda spart
    eor #1
    lsr @                   ; C = 1: no part in sight -- no miss
sw:
    php
    jsr swap
    plp
    bcs out
    inc missf
    lda #M_MISS
    sta msgc
    lda wsc                 ; a full ball in sight: the misses in a row count
    beq out
    inc mcnt
    lda mcnt
    cmp #3
    bcc out
    lda #1                  ; the third: the frame to the opponent
    sta fover
    lda #M_END
    sta msgc
    lda #0
    sta fchoice
    sta missf
    lda turn
    eor #1
    tax
    inc fw,x
out:
    rts
.endp

; needs: A = the reds left, BON, wsc = the scores -> C = 1 when either player
; needs snookers: his score plus all the points left (8 a red, the colours on
; the table) is below the other's
.proc needs
    asl @
    asl @
    asl @                   ; (8 x 15 at most)
    ldx #5                  ; the six colours
lp:
    ldy BON+16,x
    beq nx
    clc
    adc bval+16,x           ; (<= 147)
nx:
    dex
    bpl lp
    sta nrem
    ldx #1                  ; each player: the other - (his + left) - 1 >= 0 ?
pl:
    clc
    lda wsc,x
    adc nrem
    sta dtmp
    lda wsc+2,x
    adc #0
    sta dtmp+1
    txa
    eor #1
    tay
    clc                     ; (the clear carry is the -1)
    lda wsc,y
    sbc dtmp
    lda wsc+2,y
    sbc dtmp+1
    bcs out                 ; C = 1: he needs snookers
    dex
    bpl pl                  ; (falls out with C = 0)
out:
    rts
.endp

; freeq: after a foul -- the next player (not in hand) snookered (3.12: he
; cannot hit both extreme edges of a ball on): a free ball
.proc freeq
    lda cuein
    bne out
    jsr ball_on
    jsr snooker
    bcc out
    lda #1
    sta fball
    lda msgc
    cmp #M_FOUL
    bne out
    lda #M_FREE
    sta msgc
out:
    rts
.endp

; ispot: X = a ball -> C = 1 when it went down this shot
.proc ispot
    txa
    ldy potn
lp:
    dey
    bmi no
    cmp potl,y
    bne lp
    rts                     ; (C = 1 from the equal cmp)
no:
    clc
    rts
.endp

; ison: X = a ball -> C = 1 when it is a ball on (onk / onv).  Keeps X.
.proc ison
    lda onk
    bne col
    cpx #16                 ; a red
    bcs no
    sec
    rts
col:
    cpx #16
    bcc out                 ; (C = 0)
    cmp #1
    beq out                 ; any colour (C = 1)
    lda bval,x
    cmp onv
    beq out                 ; the sequence colour (C = 1)
no:
    clc
out:
    rts
.endp

; snooker: C = 1 when the cue is snookered -- no ball on whose both extreme
; edges it can hit
.proc snooker
    lda #0                  ; (edges sets it)
    sta spart
    ldx #NB-1
lp:
    stx esn
    lda BON,x
    beq nx
    jsr ison
    bcc nx
    jsr corr                ; nothing in the way at all
    bcc full
    ldx esn
    jsr edges
    bcc out                 ; both edges free: not snookered
nx:
    ldx esn
    dex
    bne lp
    sec
    rts
full:
    lda #1                  ; (a full ball is in part sight too)
    sta spart
    clc
out:
    rts
.endp

; CBOX lo, hi, X1 / Y1: the cue -> ball (ebal) span on one axis, Q4 mm (the
; arrays' mid / high bytes), widened by 4R = 1680: lo (floored at 0), hi
.macro CBOX
    ldx #0                  ; X = the lower end, Y = the higher
    ldy ebal
    lda :3
    cmp :3,y
    lda :3+$20
    sbc :3+$20,y
    bcc o
    ldx ebal
    ldy #0
o
    sec
    lda :3,x
    sbc #<1680
    sta :1
    lda :3+$20,x
    sbc #>1680
    sta :1+1
    bcs l
    lda #0
    sta :1
    sta :1+1
l
    clc
    lda :3,y
    adc #<1680
    sta :2
    lda :3+$20,y
    adc #>1680
    sta :2+1
.endm

; corr: X = a ball on -> C = 0 when no ball not on lies in the box of the
; cue -> ball line widened by 4R: the cue's path to an edge is within 2R of
; that line and a ball obstructs it within 2R -- both edges free, no maths
.proc corr
    stx ebal
    CBOX cx0, cx1, X1
    CBOX cy0, cy1, Y1
    ldx #NB-1
lp:
    cpx ebal
    beq nx
    lda BON,x
    beq nx
    lda X1,x                ; outside the box (the cheap test first)
    cmp cx0
    lda X2,x
    sbc cx0+1
    bcc nx
    lda cx1
    cmp X1,x
    lda cx1+1
    sbc X2,x
    bcc nx
    lda Y1,x
    cmp cy0
    lda Y2,x
    sbc cy0+1
    bcc nx
    lda cy1
    cmp Y1,x
    lda cy1+1
    sbc Y2,x
    bcc nx
    jsr ison                ; inside: a ball not on -> the full test (C = 1)
    bcc in
nx:
    dex
    bne lp                  ; (ball 0, the cue, is not tested)
    clc
    rts
in:
    sec
    rts
.endp

; edges: X = a ball -> C = 0 when the cue can hit both its edges.  An edge
; line: d = ball - cue turned by +-asin(r / L), r = 2R - 0.5 mm (the cue
; passes 0.5 mm inside the contact): dir = (d c -+ d' r) / L^2 with
; c = sqrt(L^2 - r^2), in Q2 mm.  The first ball on it (ghost) must be on.
ER = 208                    ; 2R - 0.5 mm, Q2 (2R = 210); ER^2 = $A900
.proc edges
    stx ebal
    sec                     ; d = (ball - cue) >> 10 (Q12 -> Q2), 16 bits (from 25)
    lda X0,x
    sbc X0
    lda X1,x
    sbc X1
    sta edx
    lda X2,x
    sbc X2
    tay
    lda #0                  ; the 25th bit (the borrow): $FF negative
    sbc #0
    cmp #$80                ; C = the sign
    tya
    ror @
    ror edx
    cmp #$80                ; (bit 7 is the sign again)
    ror @
    ror edx
    sta edx+1
    sec
    lda Y0,x
    sbc Y0
    lda Y1,x
    sbc Y1
    sta edy
    lda Y2,x
    sbc Y2
    tay
    lda #0                  ; the 25th bit (the borrow): $FF negative
    sbc #0
    cmp #$80                ; C = the sign
    tya
    ror @
    ror edy
    cmp #$80                ; (bit 7 is the sign again)
    ror @
    ror edy
    sta edy+1
    ldx #0                  ; L^2 = dx^2 + dy^2
    jsr esq
    ldx #3
cp:
    lda mP,x
    sta el2,x
    dex
    bpl cp
    ldx #2
    jsr esq
    clc                     ; L^2, and mP = L^2 - r^2 (the radicand)
    lda el2
    adc mP
    sta el2
    sta mP
    lda el2+1
    adc mP+1
    sta el2+1
    tay
    lda el2+2
    adc mP+2
    sta el2+2
    tax
    lda el2+3
    adc mP+3
    sta el2+3
    sta mP+3
    tya                     ; (ER^2's low byte is 0)
    sec
    sbc #>[ER*ER]
    sta mP+1
    txa
    sbc #0
    sta mP+2
    lda mP+3
    sbc #0
    sta mP+3
    lda #0
    sta mP+4
    sta mP+5
    jsr isqrt48
    lda root
    sta ec
    lda root+1
    sta ec+1
    lda ec                  ; the four products, both sides': dx c, dy r, dy c, dx r
    ldy ec+1
    ldx #0
    jsr emul
    ldx #0
    jsr ekeep
    lda #ER
    ldy #0
    ldx #2
    jsr emul
    ldx #4
    jsr ekeep
    lda ec
    ldy ec+1
    ldx #2
    jsr emul
    ldx #8
    jsr ekeep
    lda #ER
    ldy #0
    ldx #0
    jsr emul
    ldx #12
    jsr ekeep
    lda #0
    sta es
    sta eclr
side:
    ldx #0                  ; x: dx c -+ dy r
    ldy #4
    lda es
    jsr ecomb
    ldx #dirx-dirx
    jsr ediv
    ldx #8                  ; y: dy c +- dx r
    ldy #12
    lda es
    eor #1
    jsr ecomb
    ldx #diry-dirx
    jsr ediv
    jsr eline
    bcs sb                  ; this side blocked
    lda es                  ; free: its bit in eclr
    adc #1
    ora eclr
    sta eclr
    bne nx                  ; (always)
sb:
    lda ewant               ; blocked: only the both-edges answer wanted -> done
    beq blk
nx:
    lda es
    bne end
    inc es
    jmp side
end:
    lda eclr                ; both free: C = 0
    cmp #3
    beq both
    ora spart               ; one free: a part in sight
    bne part
    jsr ecent               ; none: the centre line?
    bcs blk
part:
    lda #1
    sta spart
blk:
    sec
    rts
both:
    lda #1                  ; (a full ball is in part sight too)
    sta spart
    clc
    rts
.endp

; eline: dirx / diry -> C = 0 when the first ball on the cue's line to ball
; ebal is a ball on
.proc eline
    ldx ebal                ; the line to the ball: its box, the reach 2 x 2047 mm
    jsr ball_b              ; (keeps X)
    lda #0
    sta ltx
    sta ltx+1
    lda #2
    sta ltx+2
    jsr segbox
    jsr ghost
    lda lgh
    beq no
    ldx ghj
    jsr ison                ; C = 1: a ball on
    bcc no
    clc
    rts
no:
    sec
    rts
.endp

; ecent: both edges blocked -- the centre line (d / L) -> C = 0 when free
; (a gap between two balls not on)
.proc ecent
    lda el2                 ; L = sqrt(L^2)
    sta mP
    lda el2+1
    sta mP+1
    lda el2+2
    sta mP+2
    lda el2+3
    sta mP+3
    lda #0
    sta mP+4
    sta mP+5
    jsr isqrt48
    lda root                ; the divisor L
    sta ediv_d
    lda root+1
    sta ediv_d+1
    lda #0
    sta ediv_d+2
    sta ediv_d+3
    ldx #0                  ; dirx = dx / L
    jsr ecen1
    ldx #2                  ; diry = dy / L
    jsr ecen1
    jmp eline
.endp

; ecen1: X = 0 / 2 (edx / edy) -> enum = it sign-extended, dirx,(X*3/2) = enum / L
.proc ecen1
    lda edx,x
    sta enum
    lda edx+1,x
    sta enum+1
    and #$80                ; the sign into bytes 2, 3
    beq p
    lda #$FF
p:
    sta enum+2
    sta enum+3
    txa                     ; 0 -> dirx, 2 -> diry (dirx + 3)
    beq x0
    ldx #diry-dirx
x0:
    jmp edivd
.endp

; esq: X = 0 / 2 (edx / edy) -> mP = its square
.proc esq
    jsr eabs
    lda mA
    sta mB
    lda mA+1
    sta mB+1
    lda #0
    sta mB+2
    jmp mul48
.endp

; eabs: X = 0 / 2 -> mA = |edx / edy| (3 bytes), N = its sign
.proc eabs
    lda #0
    sta mA+2
    lda edx+1,x
    bpl p
    sec
    lda #0
    sbc edx,x
    sta mA
    lda #0
    sbc edx+1,x
    sta mA+1
    lda #$80                ; (N = 1: negative)
    rts
p:
    sta mA+1
    lda edx,x
    sta mA
    lda #0
    rts
.endp

; emul: A:Y = an unsigned 16-bit factor, X = 0 / 2 -> mP(4) = edx / edy x it, signed
.proc emul
    sta mB
    sty mB+1
    lda #0
    sta mB+2
    jsr eabs
    php
    jsr mul48
    plp
    bpl out
    ldx #0                  ; negative: negate the four bytes
    ldy #4
    sec
ng:
    lda #0
    sbc mP,x
    sta mP,x
    inx
    dey
    bne ng
out:
    rts
.endp

; ekeep: X = 0 / 4 / 8 / 12 -> epr,X = mP(4)
.proc ekeep
    lda mP
    sta epr,x
    lda mP+1
    sta epr+1,x
    lda mP+2
    sta epr+2,x
    lda mP+3
    sta epr+3,x
    rts
.endp

; ecomb: X, Y = two products (epr offsets), A = 0: enum = X - Y, 1: X + Y
.proc ecomb
    lsr @
    bcs ad
    sec                     ; (C = 0 from the lsr)
    lda epr,x
    sbc epr,y
    sta enum
    lda epr+1,x
    sbc epr+1,y
    sta enum+1
    lda epr+2,x
    sbc epr+2,y
    sta enum+2
    lda epr+3,x
    sbc epr+3,y
    sta enum+3
    rts
ad:
    clc
    lda epr,x
    adc epr,y
    sta enum
    lda epr+1,x
    adc epr+1,y
    sta enum+1
    lda epr+2,x
    adc epr+2,y
    sta enum+2
    lda epr+3,x
    adc epr+3,y
    sta enum+3
    rts
.endp

; ediv: dirx,X (3 bytes, Q16 signed) = enum * 65536 / el2 (|enum| <= el2):
; 17 quotient bits by shift and subtract; edivd: the divisor already in ediv_d
.proc ediv
    lda el2                 ; the divisor into zero page
    sta ediv_d
    lda el2+1
    sta ediv_d+1
    lda el2+2
    sta ediv_d+2
    lda el2+3
    sta ediv_d+3
    ert *<>edivd
.endp
.proc edivd
    lda enum+3
    php
    bpl p
    sec                     ; |enum|
    lda #0
    sbc enum
    sta enum
    lda #0
    sbc enum+1
    sta enum+1
    lda #0
    sbc enum+2
    sta enum+2
    lda #0
    sbc enum+3
    sta enum+3
p:
    lda #0
    sta eq
    sta eq+1
    sta eq+2
    ldy #17
lp:
    asl eq
    rol eq+1
    rol eq+2
    sec                     ; enum >= L^2: subtract, a 1 bit
    lda enum
    sbc ediv_d
    sta erem
    lda enum+1
    sbc ediv_d+1
    sta erem+1
    lda enum+2
    sbc ediv_d+2
    sta erem+2
    lda enum+3
    sbc ediv_d+3
    bcc sh
    sta enum+3
    lda erem
    sta enum
    lda erem+1
    sta enum+1
    lda erem+2
    sta enum+2
    inc eq                  ; (bit 0 is 0 after the shift)
sh:
    asl enum
    rol enum+1
    rol enum+2
    rol enum+3
    dey
    bne lp
    plp
    bpl st
    sec                     ; the sign back
    lda #0
    sbc eq
    sta eq
    lda #0
    sbc eq+1
    sta eq+1
    lda #0
    sbc eq+2
    sta eq+2
st:
    lda eq
    sta dirx,x
    lda eq+1
    sta dirx+1,x
    lda eq+2
    sta dirx+2,x
    rts
.endp
