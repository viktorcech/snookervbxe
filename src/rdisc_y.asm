; rdisc_y.asm -- rdisc's second half (rdisc.asm, after the draw list, has no room
; for it): the rows' clip, the source / destination, the blit.
.proc rdisc_y
    lda dy0+1
    bpl y1
    cmp #$FF                ; y0 < -256: off
    bne out
    lda #0                  ; y0 < 0: -y0 rows cut (C = 1: the cmp's equality -- 2026-10-28
                            ;   6502-idioms: no sec where the carry is known)
    sbc dy0
    cmp dh
    bcs out
    sta dky
    lda #0
    sta dy0
    beq y2                  ; (always)
out:
    rts
y1:
    bne out                 ; (>= 256: below the screen)
    lda dy0
    cmp #240
    bcs out
y2:
    sec                     ; h' = min(h - cut, 240 - y0)
    lda dh
    sbc dky
    sta dhh
    lda #240
    sbc dy0
    cmp dhh
    bcs y3
    sta dhh
y3:
    lda dky                 ; src = the sprite + cut rows x w + cut columns
    ldx dw
    jsr fmulu
    ldy dsp
    clc
    lda fmpl
    adc dkx
    tax
    lda fmph
    adc #0
    sta DB+1
    clc
    txa
    adc rot_spa0,y
    sta DB+0
    lda DB+1
    adc rot_spa1,y
    sta DB+1
    lda #ROT_DISC_BANK      ; their bank (rot_draw puts 0 back for the balls)
    sta DB+2
    lda dw                  ; the pitch
    sta DB+3
    ldx dy0                 ; dst = the buffer + ymul[y0 + 8] + x0
    lda dx0
    clc
    adc ymlo+8,x
    sta DB+6
    lda dx0+1
    adc ymmid+8,x
    sta DB+7
    lda ymhi+8,x
    adc #CLN_BK
    sta DB+8
    ldx dww
    dex
    stx DB+12
    ldx dhh
    dex
    stx DB+14
    SETBL $20               ; the draw template
    jsr bwait
    jmp bstart
.endp
