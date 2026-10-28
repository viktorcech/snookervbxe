; century.asm -- the "100" of a century break: it grows from a dot in the
; table's middle, overshoots, settles, holds, and is gone (tools/century_sim.py
; models it pixel for pixel and writes its tables, century.inc).  41 rectangles
; on a 46 x 20 grid; a frame maps each grid edge once (EX, EY: a 24-bit sum
; stepped by 2s, >> 9) and writes 3 fills a rectangle (shadow, outline, fill)
; into a BCB list behind one restore copy -- fired at the VBL, done before the
; beam reaches the text.  Two lists: the CPU builds one while the other blits.
; Its own VRAM bank pair, V:CE_BANK000, an 8 KB MEMAC-A window at $2000 (the
; code staged at load, the lists built at run time).  century (rules.asm) maps
; it; the box under the text is saved into the clean buffer first, set_angle
; repaints both buffers after.
; [2026-10-23 vbxe-blitter/SKILL.md: template the constant fields once, write only what
;  changes; fire early, wait late; a fill is AND 0, XOR the colour -- 1 cycle a pixel.
;  6502-idioms/SKILL.md: code size is RAM -- the code and the lists live in VRAM]

CE_BANK = $4E               ; V:$04E000-$04FFFF (free: after SIM_BANK's two, before the discs)
CE_V    = CE_BANK*$1000-$2000   ; + a window address = its VRAM address
CE_L0   = $2A00             ; the two BCB lists in the window: the restore, then
CE_L1   = $3500             ;   3 x CE_NR fills (shadows, outlines, fills)
CE_SL   = 1+3*CE_NR         ; slots a list
ce_a    = p0                ; (3) the edge sum (zero page: nothing else runs)
ce_t    = off0              ; (3) a slot's destination

    org vbank
    dta CE_BANK-1           ;   copied to V:CE_BANK000 by vram_next
    org $2000

; cen_run: the whole animation (about 2.8 s), then the blitter idle, BL_ADR as
; vb_init left it.  Called by century with this window on.
.proc cen_run
    lda #<CE_L0             ; both lists: every slot's constant fields
    ldx #>CE_L0
    jsr tmpl
    lda #<CE_L1
    ldx #>CE_L1
    jsr tmpl
    lda #0                  ; each list's last slot ends it
    sta CE_L0+21*CE_SL-1
    sta CE_L1+21*CE_SL-1
    sta ce_f
    sta ce_l
    lda #<[CE_V+ce_sv]      ; the box: visible -> clean (the restores' source)
    ldx #>[CE_V+ce_sv]
    jsr fire
    jsr build               ; frame 0 into list 0 (while the save runs)
lp:
    jsr vblwait
    ldy ce_l                  ; the list just built: at the VBL, ahead of the beam
    ldx ce_lh,y
    lda #<[CE_V+CE_L0]
    jsr fire
    lda ce_l
    eor #1
    sta ce_l
    inc ce_f
    lda ce_f
    cmp #CE_NF
    beq hold
    jsr build
    jmp lp
hold:
    ldx #CE_HOLD            ; held: nothing changes on the screen
h:
    jsr vblwait             ; (A only)
    dex
    bne h
    jsr bidle
    ldy #BL_ADR1            ; BL_ADR back to V:$0001xx (copy_full, erase_all write BL_ADR0 only)
    lda #$01
    sta (VB),y
    ldy #BL_ADR2
    lda #0
    sta (VB),y
    rts
.endp
ce_lh   dta >[CE_V+CE_L0], >[CE_V+CE_L1]    ; the lists' VRAM address, bits 8-15
ce_lw   dta >CE_L0, >CE_L1                  ;   and in the window
    ert <CE_L0<>0 || <CE_L1<>0 || ^[CE_V+CE_L0]<>^[CE_V+CE_L1] || ^[CE_V+CE_L0]<>^[CE_V+ce_sv]

; fire: X:A = the list's VRAM address (bits 8-15 : 0-7, bits 16-18 = CE_BANK >> 4)
; -> started when the blitter is free
.proc fire
    pha
    jsr bidle
    pla
    ldy #BL_ADR0
    sta (VB),y
    txa
    iny
    sta (VB),y
    lda #^[CE_V+CE_L0]
    iny
    sta (VB),y
    lda #1
    ldy #BLITTER_START
    sta (VB),y
    rts
.endp

; bidle: wait for a free blitter (BUSY: bit 0 covers the gap between BCBs).  Y = BLITTER_START
.proc bidle
    ldy #BLITTER_START
w:  lda (VB),y
    bne w
    rts
.endp

; tmpl: X:A = a list -> the restore's template in slot 0, then the fills with
; their colours (the layer's; the band's for the fill)
.proc tmpl
    sta wptr
    stx wptr+1
    ldy #20
c:  lda tcopy,y
    sta (wptr),y
    dey
    bpl c
    ldx #0
f:  jsr next
    lda #CE_SHAD
    cpx #CE_NR
    bcc f1
    lda #CE_OUTL
    cpx #2*CE_NR
    bcc f1
    lda ce_rc-2*CE_NR,x
f1: sta tfill+16
    ldy #20
f2: lda tfill,y
    sta (wptr),y
    dey
    bpl f2
    inx
    cpx #3*CE_NR
    bne f
    rts
.endp

; next: wptr += 21 (the next slot)
.proc next
    lda wptr
    clc
    adc #21
    sta wptr
    bcc o
    inc wptr+1
o:  rts
.endp

; build: frame ce_f -> list ce_l
.proc build
    ldx ce_l
    lda #0
    sta wptr
    lda ce_lw,x
    sta wptr+1
    ldx ce_f
    lda ce_stl,x            ; the step 2s into both edge loops
    sta xs0+1
    sta ys0+1
    lda ce_sth,x
    sta xs1+1
    sta ys1+1
    lda ce_xsl,x            ; EX[i] = acc >> 9, i = 0 .. CE_NW
    sta ce_a
    lda ce_xsm,x
    sta ce_a+1
    lda ce_xsh,x
    sta ce_a+2
    ldy #$100-[CE_NW+1]
ex: lda ce_a+2
    lsr @
    sta exh+CE_NW+1-$100,y
    lda ce_a+1
    ror @
    sta exl+CE_NW+1-$100,y
    lda ce_a
    clc
xs0 adc #0
    sta ce_a
    lda ce_a+1
xs1 adc #0
    sta ce_a+1
    bcc ex1
    inc ce_a+2
ex1:
    iny
    bne ex
    lda ce_ysl,x            ; EY[i], i = 0 .. CE_NH (rows < 256: the low byte)
    sta ce_a
    lda ce_ysm,x
    sta ce_a+1
    lda ce_ysh,x
    sta ce_a+2
    ldy #$100-[CE_NH+1]
ey: lda ce_a+2
    lsr @
    lda ce_a+1
    ror @
    sta eyt+CE_NH+1-$100,y
    lda ce_a
    clc
ys0 adc #0
    sta ce_a
    lda ce_a+1
ys1 adc #0
    sta ce_a+1
    bcc ey1
    inc ce_a+2
ey1:
    iny
    bne ey
; slot 0: the box the list before drew, clean -> visible (the same offsets)
    ldy ce_by,x
    lda ymlo+8,y
    clc
    adc ce_bxl,x
    sta ce_t
    lda ymmid+8,y
    adc ce_bxh,x
    sta ce_t+1
    lda ymhi+8,y
    adc #0                  ; (<= 1: C = 0 after)
    sta ce_t+2
    ldy #0
    lda ce_t
    sta (wptr),y
    ldy #6
    sta (wptr),y
    lda ce_t+1
    ldy #1
    sta (wptr),y
    ldy #7
    sta (wptr),y
    lda ce_t+2
    adc #$06                ; the clean buffer
    ldy #2
    sta (wptr),y
    lda ce_t+2
    adc #$03                ; the visible buffer
    ldy #8
    sta (wptr),y
    lda ce_bwl,x
    ldy #12
    sta (wptr),y
    lda ce_bwh,x
    iny
    sta (wptr),y
    lda ce_bh,x
    iny
    sta (wptr),y
; the layers 2, 1, 0: shadow (grown by o, moved by d), outline (grown by o), fill
    lda ce_d,x
    sec
    sbc ce_o,x              ; d - o
    sta la+2
    lda ce_o,x
    asl @
    sbc #0                  ; 2o - 1 (C = 0 from the asl: o < 128)
    sta lw+2
    sta lw+1
    lda #0
    sec
    sbc ce_o,x              ; -o
    sta la+1
    ldx #2
ly: lda la,x                ; this layer's into the rectangle loop
    sta xa0+1
    sta ya0+1
    asl @                   ; its sign -> the x's high byte: C = 1 -> 0 + $FF + 1 = 0
    lda #0                  ;   -> $FF, C = 0 -> $FF -> 0
    adc #$FF
    eor #$FF
    sta xa1+1
    lda lw,x
    sta wa+1
    sta ha+1
    stx lx
    ldx #$100-CE_NR         ; the rectangles in order (the fills' colours are by slot)
rl: jsr next
    ldy ce_rx0+CE_NR-$100,x ; x = EX[x0] + a
    lda exl,y
    clc
xa0 adc #0
    sta ce_t
    lda exh,y
xa1 adc #0
    sta ce_t+1
    ldy ce_rx1+CE_NR-$100,x ; W - 1 = EX[x1] - EX[x0] + w (< 128, century_sim asserts:
    lda exl,y               ;   -1 -> 0, never thinner than a pixel)
    ldy ce_rx0+CE_NR-$100,x
    sec
    sbc exl,y
    clc
wa  adc #0
    bpl w1
    lda #0
w1: ldy #12
    sta (wptr),y
    ldy ce_ry1+CE_NR-$100,x ; H - 1 likewise
    lda eyt,y
    ldy ce_ry0+CE_NR-$100,x
    sec
    sbc eyt,y
    clc
ha  adc #0
    bpl h1
    lda #0
h1: ldy #14
    sta (wptr),y
    ldy ce_ry0+CE_NR-$100,x ; the row EY[y0] + a -> dst = the visible buffer + row * 320 + x
    lda eyt,y
    clc
ya0 adc #0
    tay
    lda ymlo+8,y
    clc
    adc ce_t
    sta ce_t+2
    lda ymmid+8,y
    adc ce_t+1
    sta ce_t+1
    lda ymhi+8,y
    adc #$03
    ldy #8
    sta (wptr),y
    lda ce_t+1
    dey
    sta (wptr),y
    lda ce_t+2
    dey
    sta (wptr),y
    inx
    bne rl
    ldx lx
    dex
    jpl ly
    rts
; the layers 0 fill, 1 outline, 2 shadow (built 2 first: the list's order): the shift a, the growth 2g - 1
la  dta 0, 0, 0
lw  dta $FF, 0, 0
lx  dta 0
.endp

ce_f      dta 0               ; the frame
ce_l      dta 0               ; the list being built (0 / 1)

; the templates: the restore copy (320-byte rows both sides), a fill (AND 0, XOR the colour)
tcopy   dta 0, 0, 0, $40, $01, $01, 0, 0, 0, $40, $01, $01, 0, 0, 0, $FF, 0, 0, 0, 0, $08
tfill   dta 0, 0, 0, 0, 0, 0, 0, 0, 0, $40, $01, $01, 0, 0, 0, 0, 0, 0, 0, 0, $08
CE_OFF  = CE_MBY*320+SCR_OFF+CE_MBX
ce_sv   dta <CE_OFF, >CE_OFF, $03+[CE_OFF>>16], $40, $01, $01
        dta <CE_OFF, >CE_OFF, $06+[CE_OFF>>16], $40, $01, $01
        dta <[CE_MBW-1], >[CE_MBW-1], CE_MBH-1, $FF, 0, 0, 0, 0, 0

    icl '../build/assets/century.inc'

exl     :CE_NW+1 dta 0      ; this frame's edges
exh     :CE_NW+1 dta 0
eyt     :CE_NH+1 dta 0

    ert *>CE_L0
    ini vram_next
