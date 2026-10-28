; ldpal.asm -- load_palette, in the rules' RAM (cold: once at start)
.proc load_palette
    ldy #PSEL
    lda #1
    sta (VB),y
    lda #<palette
    sta src
    lda #>palette
    sta src+1
; [2026-10-12 vbxe-blitter/SKILL.md: CSEL once, then R/G/B per colour -- CB auto-increments CSEL]
    ldy #CSEL
    lda #0
    sta (VB),y
    ldx #0
loop:
    ldy #0
    lda (src),y
    ldy #CR
    sta (VB),y
    ldy #1
    lda (src),y
    ldy #CG
    sta (VB),y
    ldy #2
    lda (src),y
    ldy #CB
    sta (VB),y
    clc
    lda src
    adc #3
    sta src
    bcc nc
    inc src+1
nc:
    inx
    bne loop
    rts
.endp
