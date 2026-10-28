; aihand.asm -- the computer with the cue in hand: its place in the D chosen and
; walked to (hand_ai, called by ai_run in aiv.asm).  Cold code in the RAM under
; BASIC (out of the AI's window, which it calls into: pscan, opening.same).

; hand_ai: the cue in hand, before fire is pressed (ai_run, every frame) -> A =
; STRIG0.  aist 0: the place chosen (hpick) -- THINKING this frame; then aist
; $80: the stick walks the cue there as a player would (hand_place, 3 mm a
; frame), close or after HK_TMAX frames: put exactly on it, aist 0, fire pressed.
; [2026-10-23 6502-idioms/SKILL.md: a flag in a register (Y: the stick's bits), flags
;  tracked (the borrow's sign, no cmp #0), the count down to zero, jsr / rts -> jmp]
HK_NP    = 16                ; the D's places tried
HK_TMAX    = 220               ; frames to walk at most (a ball in the way)
HK_CLOSE    = 48                ; close: within 3 mm (Q4) on an axis
.proc hand_ai
    lda aist
    bne walk
    jsr hpick
    lda #$80
    sta aist
    lda #HK_TMAX
    sta hk_fr
    bne up                  ; (always: fire not pressed)
walk:
    ldy #$0F                ; the stick: a bit cleared, a way (bit 0 +x, 1 -x, 2 -y, 3 +y)
    dec hk_fr
    beq put
    sec                     ; dx = the place - the cue (Q4)
    lda hk_t
    sbc X1
    tax
    lda hk_t+1
    sbc X2
    bmi xn
    bne xp
    cpx #HK_CLOSE
    bcc xd
xp: ldy #%1110
    bne xd                  ; (always)
xn: cmp #$FF                ; dx <= -HK_CLOSE: -x
    bne xm
    cpx #$100-HK_CLOSE+1
    bcs xd
xm: ldy #%1101
xd: sec                     ; dy likewise
    lda hk_t+2
    sbc Y1
    tax
    lda hk_t+3
    sbc Y2
    bmi yn
    bne yp
    cpx #HK_CLOSE
    bcc yd
yp: tya
    and #%0111
    tay
    bne yd                  ; (always: bit 0 or 1 stays)
yn: cmp #$FF
    bne ym
    cpx #$100-HK_CLOSE+1
    bcs yd
ym: tya
    and #%1011
    tay
yd: sty STICK0
    cpy #$0F                ; there on both axes: down
    beq put
up: lda #1
    rts
put:                        ; (STICK0 $0F: ai_run's, or the walk's when there)
    lda #0
    sta aist
    sta rbx
    sta rby
    lda hk_t
    sta rbx+1
    lda hk_t+1
    sta rbx+2
    lda hk_t+2
    sta rby+1
    lda hk_t+3
    sta rby+2
    ldx #0                  ; the cue exactly on the place (re-projected), fire pressed
    jsr place
    lda #0
    rts
.endp

; hpick: the place in the D -> hk_t (the cue's X1, X2, Y1, Y2).  The break-off
; (no points yet, r11 in the pack): one of bo_*'s places at random (bo_i: opening
; plays its shot).  Else where its easiest pot is easiest (pscan from each free
; place); a pot from none: a free place at random.  pscan reads the cue's X1, X2,
; Y1, Y2 only (put back).
.proc hpick
    lda X1                  ; where it is: the place when nothing better is found
    sta hk_t
    lda X2
    sta hk_t+1
    lda Y1
    sta hk_t+2
    lda Y2
    sta hk_t+3
    lda #0                  ; (free: the cue itself skipped)
    sta rid
    lda sclo                ; the break-off?
    ora sclo+1
    ora schi
    ora schi+1
    bne np
    ldx #11
    ldy #11*7
    jsr opening.same
    bne np
    lda RANDOM              ; one of the break-offs at random: its place
    and #7
    tax
    stx bo_i                ; (opening plays its shot)
    lda bo_x1,x
    sta hk_t
    lda bo_x2,x
    sta hk_t+1
    lda bo_y1,x
    sta hk_t+2
    lda bo_y2,x
    sta hk_t+3
    rts
rn: lda RANDOM              ; a place at random, the next one while taken
    and #HK_NP-1
    tax
br: stx hk_i
    jsr hkld
    jsr free
    bcc bf
    ldx hk_i
    inx
    txa
    and #HK_NP-1
    tax
    bpl br                  ; (always: < HK_NP)
    ert HK_NP<>16
bf: ldy #0                  ; there
    jmp hkst
np:
    lda #$FF                ; the best: none; no break-off
    sta hk_be
    sta hk_be+1
    sta bo_i
    ldx #HK_NP-1
lp:
    stx hk_i
    jsr hkld
    jsr free                ; a ball there: not this place
    bcs nx
    lda rbx+1               ; the cue there
    sta X1
    lda rbx+2
    sta X2
    lda rby+1
    sta Y1
    lda rby+2
    sta Y2
    jsr pscan
    lda kel                 ; its easiest easier than the best place's? (ties: the first)
    cmp hk_be
    lda keh
    sbc hk_be+1
    bcs nx
    lda kel
    sta hk_be
    lda keh
    sta hk_be+1
    ldy #hk_b-hk_t          ; the best so far
    jsr hkst
nx:
    ldx hk_i
    dex
    bpl lp
    lda hk_t                ; the cue back where it is
    sta X1
    lda hk_t+1
    sta X2
    lda hk_t+2
    sta Y1
    lda hk_t+3
    sta Y2
    lda hk_be               ; a pot from a place: that place; from none: one at random
    and hk_be+1
    cmp #$FF
    jeq rn
    ldx #3
b:  lda hk_b,x
    sta hk_t,x
    dex
    bpl b
    rts
.endp

; hkst: rbx / rby (Q4 bytes 1, 2) -> hk_t + Y (0: the place, 4: the best so far)
; [2026-10-23 6502-idioms/SKILL.md: code size is RAM -- one copy for both]
.proc hkst
    lda rbx+1
    sta hk_t,y
    lda rbx+2
    sta hk_t+1,y
    lda rby+1
    sta hk_t+2,y
    lda rby+2
    sta hk_t+3,y
    rts
.endp
    ert hk_b<>hk_t+4

; hkld: X = a place of the D -> (rbx, rby), Q12
.proc hkld
    lda #0
    sta rbx
    sta rby
    lda hk_x1,x
    sta rbx+1
    lda hk_x2,x
    sta rbx+2
    lda hk_y1,x
    sta rby+1
    lda hk_y2,x
    sta rby+2
    rts
.endp

; the D's 16 places (mm), none straight behind the brown, Q4:
; (737,794) (670,822) (660,830) (670,956) (737,984) (737,699) (603,755) (560,950)
; (603,1023) (737,1079) (737,609) (539,691) (480,820) (539,1087) (737,1169) (640,760)
hk_x1   dta $10, $E0, $40, $E0, $10, $10, $B0, $00, $B0, $10, $10, $B0, $00, $B0, $10, $00
hk_x2   dta $2E, $29, $29, $29, $2E, $2E, $25, $23, $25, $2E, $2E, $21, $1E, $21, $2E, $28
hk_y1   dta $A0, $60, $E0, $C0, $80, $B0, $30, $60, $F0, $70, $10, $30, $40, $F0, $10, $80
hk_y2   dta $31, $33, $33, $3B, $3D, $2B, $2F, $3B, $3F, $43, $26, $2B, $33, $43, $49, $2F
hk_t    dta 0, 0, 0, 0      ; the place chosen: X1, X2, Y1, Y2 (Q4)
hk_b    dta 0, 0, 0, 0      ; the best place so far, its ease, the place tried, frames left
hk_be   dta 0, 0
hk_i    dta 0
hk_fr    dta 0

; the break-offs: the learnt one (597, 709: aim 107, side 2, thin on r11) moved
; along its own line and mirrored onto r15 -- every aim the computer adds (-4..+3)
; legal from each, the cue back in baulk (tools/_dbg_breakplaces.py):
; (537,708) (537,1070) (597,709) (597,1069) (657,710) (657,1068) (697,710) (697,1068)
bo_x1   dta $90, $90, $50, $50, $10, $10, $90, $90      ; the place, Q4
bo_x2   dta $21, $21, $25, $25, $29, $29, $2B, $2B
bo_y1   dta $40, $E0, $50, $D0, $60, $C0, $60, $C0
bo_y2   dta $2C, $42, $2C, $42, $2C, $42, $2C, $42
bo_al   dta $67, $91, $67, $91, $67, $91, $67, $91      ; the aim - 4 (1/64 units)
bo_ah   dta $00, $FF, $00, $FF, $00, $FF, $00, $FF
bo_sd   dta 2, 6, 2, 6, 2, 6, 2, 6                      ; the side, the red, its init_balls record
bo_bt   dta 11, 15, 11, 15, 11, 15, 11, 15
bo_b7   dta 77, 105, 77, 105, 77, 105, 77, 105
bo_i    dta $FF             ; the break-off hpick chose ($FF: none)
