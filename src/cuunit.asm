; cuunit.asm -- the cushion model's unit vector (cushion.asm's OP_UNIT), out of its full
; VRAM bank: runs while that bank is mapped at $2000 (its cells, cu_tinv, cu_negx there)

; cu_unit: cu_kv,x, cu_kv,y -> cu_kv,cud and cu_kv,cud+3: the cu_unit vector (Q16, Q7 << 9) --
; |x|, |y| scaled to max 64..127, 1/sqrt(ax^2 + ay^2) from cu_tinv by q >> 6
.proc cu_unit
    lda cu_kv+2,x              ; the signs, |x|, |y| -> cu_ua (3 + 3)
    sta cu_usg
    lda cu_kv+2,y
    sta cu_usg+1
    txa
    tay
    ldx #0
    jsr ab
    ldy cuyy
    ldx #3
    jsr ab
    lda cu_ua                  ; (0, 0): (0, 0)
    ora cu_ua+1
    ora cu_ua+2
    ora cu_ua+3
    ora cu_ua+4
    ora cu_ua+5
    bne nrm
    ldx cud
    ldy #6
z:
    sta cu_kv,x
    inx
    dey
    bne z
    rts
nrm:
nb:
    lda cu_ua+1                ; max >= 128: both >> 1
    ora cu_ua+2
    ora cu_ua+4
    ora cu_ua+5
    bne d1
    lda cu_ua
    ora cu_ua+3
    bpl up
d1:
    lsr cu_ua+2
    ror cu_ua+1
    ror cu_ua
    lsr cu_ua+5
    ror cu_ua+4
    ror cu_ua+3
    jmp nb
up:
    lda cu_ua                  ; max < 64: both << 1
    ora cu_ua+3
    cmp #64
    bcs sc
    asl cu_ua
    asl cu_ua+3
    jmp up
sc:
    lda cu_ua                  ; q = ax^2 + ay^2 (< 32768)
    tax
    jsr fmulu
    lda fmpl
    sta cut
    lda fmph
    sta cut+1
    lda cu_ua+3
    tax
    jsr fmulu
    clc
    lda fmpl
    adc cut
    sta cut
    lda fmph
    adc cut+1               ; A:cut = q: q >> 6 = its bits 6..14
    asl cut
    rol @
    asl cut
    rol @
    tay                     ; the low 8
    lda #0
    rol @                   ; the 9th (C = 0 after: A was 0)
    tax
    tya
    adc #<[cu_tinv-64]
    sta tp+1
    txa
    adc #>[cu_tinv-64]
    sta tp+2
tp:
    lda $FFFF               ; (patched: t)
    sta cut
    ldx cud                 ; c, s = min(127, a t >> 6) << 9, signed
    ldy #0
cs:
    sty cuyy                ; (0 x, 1 y)
    lda cu_uoff,y
    tay
    lda cu_ua,y
    stx cutx
    tax
    lda cut
    jsr fmulu
    ldx cutx
    lda fmph
    cmp #$20                ; a t >= 128 << 6: 127
    bcs mx
    asl fmpl                ; (fmph:fmpl) >> 6 = (fmph << 2) | (fmpl >> 6), A = fmph
    rol @
    asl fmpl
    rol @
    bpl sv                  ; (always: fmph < $20)
mx:
    lda #127
sv:
    asl @                   ; << 9: byte 1 = c << 1, bytes 0, 2 = 0
    sta cu_kv+1,x
    lda #0
    sta cu_kv,x
    sta cu_kv+2,x
    ldy cuyy
    lda cu_usg,y
    bpl pp
    jsr cu_negx
pp:
    inx
    inx
    inx
    iny
    cpy #2
    bne cs
    rts
cu_uoff
    dta 0, 3
; ab: cu_ua,x.. = |cu_kv,y..| (24-bit)
ab:
    lda cu_kv+2,y
    bpl ps
    sec
    lda #0
    sbc cu_kv,y
    sta cu_ua,x
    lda #0
    sbc cu_kv+1,y
    sta cu_ua+1,x
    lda #0
    sbc cu_kv+2,y
    sta cu_ua+2,x
    rts
ps:
    lda cu_kv,y
    sta cu_ua,x
    lda cu_kv+1,y
    sta cu_ua+1,x
    lda cu_kv+2,y
    sta cu_ua+2,x
    rts
.endp
