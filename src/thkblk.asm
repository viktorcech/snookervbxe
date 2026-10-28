; thkblk.asm -- THINKING blinks: the VBI turns its colour, palette 0's index
; TH_IDX (the HUD's HA_THK foreground: title.asm), black and the bar's yellow by
; turns, 16 frames each.  No blit, no window: the
; AI's code holds the window while it plans.
; [2026-10-22 6502-cycles-layout/SKILL.md: the rare case out of line -- vbi tests
;  thk itself (5 cycles a frame), this runs only while the computer plans]

TH_IDX  = HA_THK&$7F

; pcam_frame: while the balls run (main, after the ticks): the pocket camera once a
; shot (pc_chk in the cushion model's bank decides; cam_rest clears pcam) -- not in
; the trick mode: its view stays
.proc pcam_frame
    lda gmode
    cmp #3
    beq r
    lda pcam
    bne r
    jsr win_cu
    jsr pc_chk
    jsr win_bcb             ; (keeps C)
    bcc r
    lda #ZOOM_EYE
    jsr zoom_set
    jsr pivot_at
    lda #0
    sta fidle
    jmp set_angle
r:
    rts
.endp

.proc thkblk
    ldy #PSEL
    lda #0
    sta (VB),y
    ldy #CSEL
    lda #TH_IDX
    sta (VB),y
    lda RTCLOK+2            ; frames 16..31 of 32: yellow (hidden)
    and #$10
    beq b0
    lda #3
b0:
    tax
    ldy #CR
l:
    lda thrgb,x             ; (CB increments CSEL: once a colour)
    sta (VB),y
    inx
    iny
    cpy #CB+1
    bne l
    jmp thkclk              ; [2026-10-27] its thinking's seconds (hud.asm)
thrgb dta $16, $16, $16, $E2, $C6, $2A  ; palette 1's black (15), yellow (10)
.endp

