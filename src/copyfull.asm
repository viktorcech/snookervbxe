; copyfull.asm -- copy_full at $9C00 (the free pages under the draw list)
; [2026-10-21 vbxe-blitter/SKILL.md: template the constant fields once -- the copy's BCB is
;  constant: written into its own slot V:$0001C0 at start (boot.asm vb_init), a copy is BL_ADR + START (no 21
;  bytes built and sent per copy, no erase slot to rebuild after); fire early, wait late]
; copy_full: clean V:$060100 -> visible V:$030100, the whole 320x240 screen
.proc copy_full
    lda #$C0                ; the copy's slot (BL_ADR1 / 2 = $01 / 0: vb_init)
    sta rcurbl              ; (SETBL: the slot now in BL_ADR0)
    ldy #BL_ADR0
    sta (VB),y
    ldy #BLITTER_START
w:  lda (VB),y              ; a free blitter (a START while busy is ignored)
    bne w
    lda #1
    sta (VB),y
    rts
.endp
