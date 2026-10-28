; boot.asm -- vb_init: once at start, in lbuf_px (the aim line's save-under,
; after the palette: both read once before the first line is drawn).
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- cold start-up code out of the main
;  block, the BCB templates as data (21 bytes each) under one copy loop instead of ~60
;  lda / sta pairs; vbxe-blitter/SKILL.md: template the constant fields once -- at start,
;  not per redraw (set_angle no longer rebuilds them: nothing at run time spoils them)]
; ==========================================================================
; vb_init: the VBXE page into the blitter polls / starts (SMC), the BCB
; templates -> V:$0001xx, the blitter's BCB pointer -> V:$000100.
; ==========================================================================
tpl                         ; (one page: the copy loop's lda tpl,x keeps its high byte)
    dta $00, $00, $00, $40, $01, $01, $00, $00, $00, $40, $01, $01, $00, $00, $00, $FF, $00, $00, $00, $00, $00    ; V:$000100 erase: copy clean -> visible, the rect per ball
    dta $00, $00, $00, $00, $00, $01, $00, $00, $00, $40, $01, $01, $00, $00, $00, $FF, $00, $00, $00, $00, $01    ; V:$000120 draw: the sprite, MODE 1
    dta $00, $00, $00, $00, $00, $00, $00, $00, $00, $40, $01, $01, $00, $00, $00, $00, $00, $00, $00, $00, $00    ; V:$000140 fill: AND 0, XOR the colour, MODE 0
    dta $00, $00, $00, $00, $00, $01, $00, $00, $00, $40, $01, $01, $00, $00, $00, $FF, $00, $00, $00, $00, $03    ; V:$0001A0 shadow: the mask ORed in, MODE 3
    dta $00, $01, $06, $40, $01, $01, $00, $01, $03, $40, $01, $01, $3F, $01, $EF, $FF, $00, $00, $00, $00, $00    ; V:$0001C0 copy_full: clean -> visible, 320 x 240
.proc vb_init
    lda VB+1
    sta rfill.wt+2
    sta rfill.st+2
    sta bwait.w+2
    sta bstart.st+2
    sta span.w+2                ; (erase_all / draw_all: under the OS ROM -> os_off patches them)
    sta span.st+2
    sta mrun.wt+2
    sta mrun.st+2
    lda #$80                ; the window on bank 0
    ldy #MA_BSEL
    sta (VB),y
    ldy #4                  ; templates 4 .. 0
t:
    lda tdst,y
    sta st+1
    lda tsrc,y
    sta ld+1
    ldx #20
c:
ld  lda tpl,x
st  sta WINDOW+$100,x
    dex
    bpl c
    dey
    bpl t
    lda #$00                ; BL_ADR = V:$000100
    ldy #BL_ADR0
    sta (VB),y
    ldy #BL_ADR2
    sta (VB),y
    lda #$01
    ldy #BL_ADR1
    sta (VB),y
    rts
.endp
tdst
    dta $00, $20, $40, $A0, $C0
tsrc
    dta <tpl, <[tpl+21], <[tpl+42], <[tpl+63], <[tpl+84]
    ert >tpl <> >[tpl+104]

