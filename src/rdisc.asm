; rdisc.asm -- after the draw list (ROT_TAB's tail; called ~12 times a frame).
; [2026-10-21 rewritten (the cast experiment had removed it): vbxe-blitter/SKILL.md -- the draw
;  template's constants stay (bank 0 source, steps, MODE 1), only what changes is written;
;  6502-idioms/SKILL.md: the shifts in A, the clip's rare exits short (out mid-procedure);
;  tables beat arithmetic (rot_spry8 = ry + 8: one subtraction for the screen row);
;  code size is RAM: w, h worked out from rx, ry + 8 (no tables of their own)]
; ==========================================================================
; rdisc: X = projection point, rn = class -> the depth-sized ellipse sprite
; (rot_ref Renderer.render 'disc' + blit): top-left (sx >> 4 - rx, row - ry),
; cut to the screen (x 0..319, screen rows 0..239), its 0 pixels clear.
; ==========================================================================
RD    = WINDOW+$300     ; rdisc's cells (VRAM bank 0: the window is on it in rot_draw)
dw    = RD              ; (1) the sprite's width, height
dh    = RD+1
dx0   = RD+2            ; (2) its top-left x, screen row (signed)
dy0   = RD+4            ; (2)
dkx   = RD+6            ; (1) columns / rows cut off the left / top
dky   = RD+7
dww   = RD+8            ; (1) the width / height drawn
dhh   = RD+9
dsp   = RD+10           ; (1) the sprite

.proc rdisc
    lda rpidx,x             ; out of the LUT range: no disc
    cmp #$FF
    jeq out
    tay                     ; the sprite: the class's table (page ROT_LUT + $C00 + class)
    lda rn
    clc
    adc #>[ROT_LUT+$C00]
    sta cl+2
cl  lda $FF00,y
    tay
    sty dsp
    lda rot_sprx,y          ; w = 2 rx + 1
    asl @
    ora #1
    sta dw
    lda rot_spry8,y         ; h = 2 ry + 1 = 2 (ry + 8) - 15
    asl @                   ; (C = 0: ry + 8 < 128)
    sbc #14
    sta dh
    sec                     ; y0 = row - (ry + 8), the screen row (signed 16)
    lda rpyl,x
    sbc rot_spry8,y
    sta dy0
    lda #0
    sbc #0
    sta dy0+1
    lda rpxh,x              ; sx past 16 bits (rpxx not its sign): off
    asl @
    lda rpxx,x
    adc #0
    jne out
; [2026-10-28 6502-loops-tables-smc/SKILL.md: tables beat arithmetic -- sx >> 4 (arithmetic) by
;  shr4 / x16, no 4 x ror of a window cell; 6502-idioms/SKILL.md: compute in A, store once, no
;  sec / clc where the carry is known]
    lda rpxl,x              ; x0 = (sx >> 4) - rx: >> 4 in A (arithmetic)
    sta dx0
    lda rpxh,x
    cmp #$80
    ror @
    ror dx0
    cmp #$80
    ror @
    ror dx0
    cmp #$80
    ror @
    ror dx0
    cmp #$80
    ror @
    ror dx0
    tax
    sec
    lda dx0
    sbc rot_sprx,y
    sta dx0
    txa
    sbc #0
    sta dx0+1
    lda #0                  ; the clip: columns / rows cut off the left / top
    sta dkx
    sta dky
    lda dx0+1
    bpl x1
    cmp #$FF                ; x0 < -256: off ([2026-10-21 6502-idioms/SKILL.md: the high byte checked whole])
    bne out
    lda #0                  ; x0 < 0: -x0 columns cut (C = 1: the cmp's equality)
    sbc dx0
    cmp dw
    bcs out                 ; (all of it)
    sta dkx
    lda #0
    sta dx0
    sta dx0+1
x1:
    lda dx0+1               ; x0 >= 320: nothing
    beq x2
    cmp #1                  ; (x0 >= 512 too)
    bne out
    lda dx0
    cmp #<320
    bcs out
x2:
    sec                     ; w' = min(w - cut, 320 - x0)
    lda dw
    sbc dkx
    sta dww
    lda #<320               ; (C = 1: dkx < dw, no borrow)
    sbc dx0
    tax
    lda #>320
    sbc dx0+1
    bne x3                  ; (>= 256 left: no cut)
    cpx dww
    bcs x3
    stx dww
x3:
    jmp rdisc_y             ; the rows' clip and the blit: in the code (rdisc_y.asm)
out:
    rts
.endp
