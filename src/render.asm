; render.asm -- depth-row LUT projection, VBXE blitter (21-byte BCB),
; static rack drawing (init-time CPU blit).

; ==========================================================================
; PROJECTION
; ==========================================================================
; ==========================================================================
; project: the ball centre (rvx, rvy: rotated, Q3 about the table centre --
; rot_view) -> sx, syv = its sprite's top-left, dsz = 2*size+1, spadr.
; The table renderer's depth LUT at the ball-centre level (rot_ref.ball_proj):
;   row = ROW[i] - hi(DR[i]*f) ; k = K[i] - hi(DK[i]*f) ; x = SXC +- |y'| k >> 15
; centre rounded to the pixel; size by depth index.
; ==========================================================================
.proc project
    clc                     ; T = x + OFF (17 bits: x < 0 without a carry = behind)
    lda rvx
pof0 adc #0                 ; (OFF lo: zoom_set)
    tax                     ; X = f (fmulu keeps X and Y)
    lda rvx+1
pof1 adc #0
    tay                     ; Y = i
    bcc nc
; [2026-10-28 6502-mads/SKILL.md: an out-of-range jmi / jpl makes the common path a taken
;  branch -- an out (ot) in range; 6502-idioms/SKILL.md: compute in A, store once -- |y| from
;  rvy straight (yn), the >> 4s by the shr4 / x16 tables (6502-loops-tables-smc), no clc / sec
;  where the carry is known]
    bit rvx+1               ; a carry with x >= 0: T is past 64K, far beyond TFH
    bpl ot
    bmi ok0                 ; (always)
kf:                         ; (the DK rare case, out of line: i < NH)
    sta dkp
    lda #2
    jsr kfar                ; mB = K[i] - (DK[i] f >> 8)
    jmp kd
ot:
    sec
    rts
nc:
    bit rvx+1               ; no carry with x < 0: behind
    bmi ot
ok0:
pfh1 cpy #0                 ; T < TFH ?  (zoom_set)
    bcc ok1
    jne out
pfh0 cpx #0
    jcs out
ok1:
; [2026-10-09 6502-cycles-layout/SKILL.md: price each site -- fmulu inlined, only its high byte, kept in A]
    lda rd2,y               ; DR[i] * f, quarter squares
    sta ra1+1
    sta ra2+1
    eor #$FF
    sta rb1+1
    sta rb2+1
    sec
ra1 lda sqr1lo,x            ; (the low byte only for its borrow)
rb1 sbc sqr2lo,x
ra2 lda sqr1hi,x
rb2 sbc sqr2hi,x            ; A = hi(DR[i]*f), C = 1 (a product: no borrow)
    eor #$FF                ; row = ROW[i] + ~A + 1
    adc rl2_lo,y
    sta mA                  ; (scratch until the multiply)
    lda rl2_hi,y
    adc #$FF
    sta mA+1
    lda rdk2,y              ; DK[i] * f
    sta ka1+1
    sta ka2+1
    eor #$FF
    sta kb1+1
    sta kb2+1
    sec
ka1 lda sqr1lo,x
kb1 sbc sqr2lo,x
ka2 lda sqr1hi,x
kb2 sbc sqr2hi,x            ; A = hi(DK lo[i]*f)
    cpy znh                 ; i < NH: DK past 8 bits (a close camera): kf
    bcc kf
    eor #$FF                ; (C = 1)                ; k = K[i] + ~A + 1
    adc rk2_lo,y
    sta mB
    lda rk2_hi,y
    adc #$FF
    sta mB+1
kd:
    lda bsize,y
    sta sizev
    clc                     ; syv = ((row + 8) >> 4) - size, 16-bit signed
    lda mA
    adc #8
    tay
    lda mA+1
    adc #0
    tax                     ; the high byte (0..16): its bit 4 is bit 8 of the row
    lda shr4,x
    sta syvh
    txa
    and #$0F
    tax
    lda shr4,y
    ora x16,x
    sec
    sbc sizev
    sta syv
    lda syvh
    sbc #0
    sta syvh
    lda rvy+1               ; m = |y'| * k >> 15
    bmi yn
    sta mA+1
    lda rvy
    sta mA
yp:
    jsr mul16h
    lda mP+1
    asl @
    rol mP+2
    rol mP+3
    jcs out                 ; m >= 2^15: 2048 px off, never on the screen
    jmi out
    lda rvy+1               ; x (Q4) = SXC +- m, + 8 for the rounding (C = 0: the jcs)
    bmi xn
    lda #<[ROT_SXC+8]
    adc mP+2
    tay
    lda #>[ROT_SXC+8]
    adc mP+3
    jmp xs
yn:                         ; y' < 0: |y'| -> mA (out of line, in reach)
    sec
    lda #0
    sbc rvy
    sta mA
    lda #0
    sbc rvy+1
    sta mA+1
    jmp yp
xn:
    lda #<[ROT_SXC+8+1]     ; (C = 0: L + 1 - m - 1, 16 bits)
    sbc mP+2
    tay
    lda #>[ROT_SXC+8+1]
    sbc mP+3
xs:                         ; sx = (x >> 4) - size, arithmetic: x can be left of the screen
    tax                     ; x hi -> sx+1 = its >> 4, signed
    lda shr4,x
    cpx #$80
    bcc xp
    ora #$F0
xp:
    sta sx+1
    txa                     ; sx = shr4[lo] | x16[hi & $0F], less the size
    and #$0F
    tax
    lda shr4,y
    ora x16,x
    sec
    sbc sizev
    sta sx
    bcs s1
    dec sx+1
s1:
    lda sizev               ; dsz = 2 size + 1 ; the sprite of that size
    asl @                   ; (C = 0: a small size -- adc sprbank's)
    ora #1
    sta dsz
    ldy sizev
    lda sizeoff_lo,y
    sta spadr
    lda sizeoff_hi,y
    adc sprbank             ; the ball colour's sheet page (vbxe_export BALL_BANK)
    sta spadr+1             ; (spadr+2 = 0: the draw template's DB+2, vb_init)
    clc
    rts
out:
    sec
    rts
.endp







; (static-rack CPU blit removed: all 22 balls are dynamic now, so the clean
; buffer holds the table only; draw_rack/draw_one/put_vram + sprites.bin/rack.bin
; are no longer used.)

