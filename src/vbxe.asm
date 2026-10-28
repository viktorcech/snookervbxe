; vbxe.asm -- VBXE detection, palette/sprite loading, RLE table unpack,
; VBL wait, XDL.

; ==========================================================================
; VBXE bring-up helpers
; ==========================================================================
.proc detect_vbxe
    lda #$00
    sta VB
    lda #$D6
    sta VB+1
    jsr probe
    beq done
    lda #$D7
    sta VB+1
    jsr probe
    beq done
    lda #0
    sta VB+1
done:
    rts
; [2026-10-21 VBXE 1.27 manual ch. 2: reads only while probing; CORE_TYPE $10 (FX: the overlay
;  and the blitter) and CORE_REVISION & $7F in $26..$2F -- no core older than 1.26]
probe:
    ldy #$40
    lda (VB),y
    cmp #$10
    bne bad
    ldy #$41
    lda (VB),y
    and #$7F                ; (bit 7: the RAMBO "r" core flag)
    cmp #$26
    bcc bad
    cmp #$30
    bcs bad
    lda #0                  ; Z = 1: found
    rts
bad:
    lda #$ff
    rts
.endp



; (load_sprites removed: the 8 depth-sprite sheets are streamed straight into
; VRAM at $001000 by the INI hooks in vram_load.inc, like the view data.)

; (unpack_to / table.rle removed: the table views are painted by set_view.)

.proc vblwait
    lda $14
w:
    cmp $14
    beq w
    rts
.endp

; --------------------------------------------------------------------------
; the HUD's 16 lines: black | 14 lines of its text (hud.asm: 3 lines, 80 columns,
; the OS font, overlay palette 0) | black; then the table buffer's rows 16..239
; [2026-10-22 vbxe-blitter/SKILL.md: overlay off on lines that show nothing; every
;  field the frame needs in the XDL -- OVATT again for the table (palette 1)]
XDL:
    dta %00000100              ; OVOFF
    dta %00000000
    dta %11100001              ; TMON | RPTL | OVADR | OVSCRL
    dta %00001001              ; CHBASE | OVATT
    dta 13
    dta <HUD_VRAM, >HUD_VRAM, ^HUD_VRAM
    dta 160, 0                 ; 80 characters a line
    dta 0, 8-HUD_TOP           ; line 0 from its font row 8 - HUD_TOP
    dta HUD_FONT>>11
    dta %00000001              ; normal width, overlay palette 0
    dta $FF                    ; overlay over everything
    dta %00000100              ; OVOFF
    dta %00000000
    dta %01100010              ; GMON | RPTL | OVADR
    dta %10001000              ; OVATT | END
    dta 223
    dta $00,$15,$03            ; OVADR = V:$031500: the visible buffer's row 16 (SCR_OFF + 16 * 320)
    dta $40,$01
    dta %00010001              ; normal width, overlay palette 1
    dta $FF
XDL_LEN = *-XDL
