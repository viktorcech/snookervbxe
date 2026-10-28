; table3d.asm -- the table drawn in real time about the CUE BALL (the pivot)
; at any angle (rang 0..1023) and zoom.  Byte-exact copy of tools/rot_ref.py
; (Renderer.render); data from tools/rot_export.py (rot.inc, rotdata.inc and
; the VRAM streams).  The camera is fixed and the table turns about the
; pivot, so a point's row and x-scale depend on its rotated depth and height
; only: depth LUTs per z level, lerped; one LUT set per zoom (zoom_set).
; The table runs past the screen: polygons are clipped in table space
; (near / far plane: T = 0 / TF - 1) and in screen space (x = 0 / 320);
; sprites by rectangle.  Rows carry a bias of 8 (stored row = screen + 8):
; stored 0..7 and 248..255 are junk rows past the buffer (ymlo).
;
;   rot_draw: rang, piv, the zoom -> the table into the clean buffer (CLN_BK)
;
; Scratch: the physics / ball-projection cells (never live while drawing).

.macro SETBL            ; :1 = BL_ADR0 (a BCB template in page 1 of bank 0), written on a change only
    lda #:1
    cmp rcurbl
    beq done
    sta rcurbl
    ldy #BL_ADR0
    sta (VB),y
done
.endm

; ==========================================================================
; trig: c, s (Q14 = Q16 cos LUT (+2) >> 2) as magnitude + sign
; ==========================================================================
.proc rot_trig
    lda rang
    sta ang2
    lda rang+1
    sta ang2+1
    jsr cosptr
    jsr q14
    stx rcm
    sty rcm+1
    sta rcn
    sec                     ; sin(a) = cos(a - 256)
    lda rang
    sta ang2
    lda rang+1
    sbc #1
    and #3
    sta ang2+1
    jsr cosptr
    jsr q14
    stx rsm
    sty rsm+1
    sta rsn
    rts
.endp

; q14: (aptr) = Q16 signed 24-bit -> v = (v + 2) >> 2 (floor); out X:Y =
; |v|, A = $80 if v < 0 else 0.
.proc q14
    ldy #0
    clc
    lda (aptr),y
    adc #2
    sta rq0
    iny
    lda (aptr),y
    adc #0
    sta rq1
    iny
    lda (aptr),y
    adc #0
    cmp #$80                ; arithmetic >> 2 over the 3 bytes
    ror @
    ror rq1
    ror rq0
    cmp #$80
    ror @
    ror rq1
    ror rq0                 ; rq1:rq0 = v (16-bit signed, |v| <= 16384)
    ldx rq0
    ldy rq1
    bpl pos
    sec
    lda #0
    sbc rq0
    tax
    lda #0
    sbc rq1
    tay
    lda #$80
    rts
pos:
    lda #0
    rts
.endp

; r14: rpc = (mP + 8192) >> 14  (the product of a coordinate and c or s)
.proc r14
    lda mP+1
    clc
    adc #$20
    tax                     ; bits 14..15 of P + $2000 = its top 2 bits
    lda mP+2
    adc #0
    sta rpc
    lda mP+3
    adc #0
    sta rpc+1
    txa
    asl @
    rol rpc
    rol rpc+1
    asl @
    rol rpc
    rol rpc+1
    rts
.endp

; ==========================================================================
; view_setup: the pivot's offset B' = R(piv - C) (rot_rel) folded into the
; point loader -- ofb = OFF - B'x, nby = -B'y (24-bit) -- and the eye in
; table coordinates, halved: eu = (du - EXM c) >> 1, ev = (dv + EXM s) >> 1
; (the eye lies EXM behind the pivot in the rotated frame), as |.| + sign.
; ==========================================================================
.proc view_setup
    sec                     ; du = (pivx - CX) >> 9 (Q3, signed 16)
    lda pivx
    sbc #VCX_L
    lda pivx+1
    sbc #VCX_M
    sta rvu
    lda pivx+2
    sbc #VCX_H
    cmp #$80
    ror @
    ror rvu
    sta rvu+1
    sec                     ; dv = (pivy - CY) >> 9
    lda pivy
    sbc #VCY_L
    lda pivy+1
    sbc #VCY_M
    sta rvv
    lda pivy+2
    sbc #VCY_H
    cmp #$80
    ror @
    ror rvv
    sta rvv+1
    jsr rot_rel             ; rvx, rvy = B'
    sec                     ; ofb = OFF - B'x (B'x sign-extended to 24 bits)
zof0 lda #0                 ; (OFF lo: zoom_set)
    sbc rvx
    sta ofb
zof1 lda #0                 ; (OFF hi)
    sbc rvx+1
    sta ofb+1
    lda #0                  ; the top byte: -borrow, +1 when B'x < 0
    sbc #0
    ldx rvx+1
    cpx #$80
    adc #0
    sta ofb+2
    sec                     ; nby = -B'y
    lda #0
    sbc rvy
    sta nby
    lda #0
    sbc rvy+1
    sta nby+1
    lda #0
    sbc #0
    ldx rvy+1
    cpx #$80
    adc #0
    sta nby+2
    lda ofb                 ; ofb2 = 2 ofb, nby2 = 2 nby: rot_load's mirrored points
    asl @
    sta ofb2
    lda ofb+1
    rol @
    sta ofb2+1
    lda ofb+2
    rol @
    sta ofb2+2
    lda nby
    asl @
    sta nby2
    lda nby+1
    rol @
    sta nby2+1
    lda nby+2
    rol @
    sta nby2+2
exl lda #0                  ; rpc = (EXM |c| + 8192) >> 15: the term halved
    sta mA                  ; (EXM, the eye's distance: zoom_set patches it)
exh lda #0
    sta mA+1
    lda rcm
    sta mB
    lda rcm+1
    sta mB+1
    jsr mul16u
    jsr r14
    lsr rpc+1
    ror rpc
    lda rvu+1               ; eu = (du >> 1) - sign(c) rpc
    cmp #$80
    ror @
    sta eum+1
    lda rvu
    ror @
    sta eum
    lda rcn
    eor #$80
    jsr rvsgn
    clc
    adc eum
    sta eum
    tya
    adc eum+1
    sta eus
    sta eum+1
    bpl eup
    sec
    lda #0
    sbc eum
    sta eum
    lda #0
    sbc eum+1
    sta eum+1
eup:
    lda rsm                 ; (EXM |s| + 8192) >> 15
    sta mB
    lda rsm+1
    sta mB+1
    jsr mul16r
    jsr r14
    lsr rpc+1
    ror rpc
    lda rvv+1               ; ev = (dv >> 1) + sign(s) rpc
    cmp #$80
    ror @
    sta evm+1
    lda rvv
    ror @
    sta evm
    lda rsn
    jsr rvsgn
    clc
    adc evm
    sta evm
    tya
    adc evm+1
    sta evs
    sta evm+1
    bpl evp
    sec
    lda #0
    sbc evm
    sta evm
    lda #0
    sbc evm+1
    sta evm+1
evp:
    jmp cull_prep           ; the cull test's products for this eye
.endp

; ==========================================================================
; rot_load: the rotation points of the angle rang (even: the turn steps by 2)
; from VRAM slot rang/2 (rot_export: x lo, x hi, y lo, y hi per point, Q3
; about the table centre) -> rt = x + ofb (T, 24-bit), ry = y + nby (24-bit):
; the turn about the pivot and the LUT offset in one add.
; ==========================================================================
.proc rot_load
    lda rang                ; the slot's page in the window: $30 + (rang >> 1) & 15
    lsr @
    and #$0F
    ora #>WINDOW
    sta l0+2
    sta l1+2
    sta l2+2
    sta l3+2
    lda rang+1              ; its VRAM bank: ROT_PTS_BANK + rang >> 5
    asl @
    asl @
    asl @
    sta rq0
    lda rang
    lsr @
    lsr @
    lsr @
    lsr @
    lsr @
    ora rq0
    clc
    adc #$80|ROT_PTS_BANK
    ldy #MA_BSEL
    sta (VB),y
    ldy #ROT_NRS-1          ; the stored points (rot_export: the pairs' partners, the unpaired,
cp:                         ;   the D) -> entries ROT_NRA.. of rt / ry
    clc
l0  lda WINDOW,y            ; T = x + ofb
    adc ofb
    sta rt0+ROT_NRA,y
l1  lda WINDOW+ROT_NRS,y
    tax
    adc ofb+1
    sta rt1+ROT_NRA,y
    lda ofb+2
    adc #0
    cpx #$80                ; x < 0: its sign extension ($FF + C = C - 1)
    bcc xp
    sbc #1
xp:
    sta rt2+ROT_NRA,y
    clc
l2  lda WINDOW+2*ROT_NRS,y  ; y + nby
    adc nby
    sta ry0+ROT_NRA,y
l3  lda WINDOW+3*ROT_NRS,y
    tax
    adc nby+1
    sta ry1+ROT_NRA,y
    lda nby+2
    adc #0
    cpx #$80
    bcc yp
    sbc #1
yp:
    sta ry2+ROT_NRA,y
    dey
    bpl cp
    lda #$80                ; the window back on bank 0 (the BCBs)
    ldy #MA_BSEL
    sta (VB),y
; the first ROT_NRA points are the negations of the next ROT_NRA (the table's centre
; symmetry, rot_export mirror_first): T = (-x) + ofb = 2 ofb - (x + ofb), from RAM --
; no window read; the tables sit in page halves, no read crosses
    ldy #ROT_NRA-1
mr:
    sec
    lda ofb2
    sbc rt0+ROT_NRA,y
    sta rt0,y
    lda ofb2+1
    sbc rt1+ROT_NRA,y
    sta rt1,y
    lda ofb2+2
    sbc rt2+ROT_NRA,y
    sta rt2,y
    sec
    lda nby2
    sbc ry0+ROT_NRA,y
    sta ry0,y
    lda nby2+1
    sbc ry1+ROT_NRA,y
    sta ry1,y
    lda nby2+2
    sbc ry2+ROT_NRA,y
    sta ry2,y
    dey
    bpl mr
    rts
.endp

; ==========================================================================
; projection: i = T hi, f = T lo ; row = ROW[i] - (DR[i]*f >> 8) ;
;   k = K[i] - (DK[i]*f >> 8) ; sx = SXC +- (|y| k >> 15)   (Q4 signed)
; ==========================================================================
.macro PROJ_PT          ; :1 LUT level.  X = the projection point; rq0 = f, rpi = i
    stx rti                 ; -> rpyl,x = the stored row, rpidx,x = i, mB = k
    lda rpi
    sta rpidx,x
    tay
    lda rd:1,y              ; DR[i] * f, quarter squares (the high byte only)
    sta ra1+1
    sta ra2+1
    eor #$FF
    sta rb1+1
    sta rb2+1
    ldx rq0
    sec
ra1 lda sqr1lo,x            ; (the low byte only for its borrow)
rb1 sbc sqr2lo,x
ra2 lda sqr1hi,x
rb2 sbc sqr2hi,x            ; A = hi(DR[i]*f), C = 1 (a product: no borrow)
    ldx rti
    eor #$FF                ; row = (ROW[i] - A) >> 4: ROW + ~A + 1 (12 bits) ->
    adc rl:1_lo,y           ;   x16[hi] | shr4[lo]
    sta rrt
    lda rl:1_hi,y
    adc #$FF
    tay
    lda x16,y
    ldy rrt
    ora shr4,y
    ldy rpi                 ; (Y = i again)
    sta rpyl,x
    lda rdk:1,y             ; k = K[i] - hi(DK[i]*f)
    sta ka1+1
    sta ka2+1
    eor #$FF
    sta kb1+1
    sta kb2+1
    ldx rq0
    sec
ka1 lda sqr1lo,x
kb1 sbc sqr2lo,x
ka2 lda sqr1hi,x
kb2 sbc sqr2hi,x            ; A = hi(DK lo[i]*f)
    cpy znh                 ; i < NH: DK past 8 bits (a close camera) --
    bcc kf:1                ;   rot_project.kf0 / kf1, back after the macro
    eor #$FF                ; K + ~A + 1 (C = 1)
    adc rk:1_lo,y
    sta mB
    lda rk:1_hi,y
    adc #$FF
    sta mB+1
.endm

; after the multiply: m = P >> 15 (17 bits) -> X = lo, rpm = mid, rph = hi,
; negated over 24 bits when y < 0 (rq1)
.macro SX_M
    lda mP+1                ; m = P3:P2 << 1 | bit 7 of P1, bit 7 of P3 on top
    asl @
    lda mP+2
    rol @
    tax
    lda mP+3
    rol @
    sta rpm
    lda #0
    rol @
    sta rph
    bit rq1
    bpl pos
    sec                     ; y < 0: m = ~m + 1
    txa
    eor #$FF
    adc #0
    tax
    lda rpm
    eor #$FF
    adc #0
    sta rpm
    lda rph
    eor #$FF
    adc #0
    sta rph
pos
.endm

.macro PROJ_TAIL        ; rti = the projection point, rq1 = sign of y -> rpxl/rpxh/rpxx
    SX_M
    ldy rti
    clc
    txa
    adc #<ROT_SXC
    sta rpxl,y
    lda rpm
    adc #>ROT_SXC
    sta rpxh,y
    lda rph
    adc #0
    sta rpxx,y
.endm

; kfar: a depth step past 8 bits (i < znh: a close camera) -> mB = K[i] -
; (DK[i] f >> 8) = K[i] - (DKhi[i] f + dkp), dkp = hi(DKlo[i] f) (rot_ref:
; the same exact product).  DKhi sits at $C0 + i of the level's DK page.
; A = the level (0, 1, 2: its pages patched in), X = f, Y = i; keeps Y; out
; with C = 1 (K >= the sum: k is never negative).
.proc kfar
    stx dkf
    tax
    lda kf_dk,x
    sta kh+2
    lda kf_lo,x
    sta kl+2
    lda kf_hi,x
    sta kk+2
    ldx dkf
kh  lda rdk0+$C0,y          ; DKhi * f, quarter squares (16 bits)
    sta q1+1
    sta q2+1
    eor #$FF
    sta q3+1
    sta q4+1
    sec
q1  lda sqr1lo,x
q3  sbc sqr2lo,x
    sta dkl
q2  lda sqr1hi,x
q4  sbc sqr2hi,x
    sta dkl+1
    clc                     ; + dkp
    lda dkl
    adc dkp
    sta dkl
    bcc nc
    inc dkl+1
nc:
    sec                     ; mB = K - the sum
kl  lda rk0_lo,y
    sbc dkl
    sta mB
kk  lda rk0_hi,y
    sbc dkl+1
    sta mB+1
    rts
.endp
kf_dk dta >rdk0, >rdk1, >rdk2
kf_lo dta >rk0_lo, >rk1_lo, >rk2_lo
kf_hi dta >rk0_hi, >rk1_hi, >rk2_hi

; rot_project: every projection point in the LUT range (0 <= T < TF of its
; level) -> sx, row, i; else rpidx = $FF.  Per ROTATION point: T, |y| and
; the multiplier patch serve both its levels.
; dtest: the D skipped this frame (its chords and the points only they use, the
; last ROT_ND) when all its points lie behind the near plane: T < 0, so each chord
; would be clipped away whole -- the same picture.  Pass 1, on the rotation points.
; [2026-10-22 fable-skill-atari/SKILL.md 1, 3: cheap rejects in pass 1, by what they need;
;  6502-loops-tables-smc/SKILL.md: rot_project's count an immediate operand]
.proc dtest
    lda rt2+ROT_DE0         ; bit 7 of every T's top byte: all negative?
    and rt2+ROT_DE1
    ldx #ROT_ND-1
l:
    and rt2+ROT_NRP-ROT_ND,x
    dex
    bpl l
    sta dskip
    asl @                   ; C = 1: skipped
    lda #ROT_NRP-1
    bcc n
    lda #ROT_NRP-ROT_ND-1
n:
    sta rot_project+1
    ert *<>rot_project
.endp

.proc rot_project
    ldy #ROT_NRP-1          ; (dtest: less the D's own points, the last ones, while it is skipped)
; [2026-10-28 6502-mads/SKILL.md: an out-of-range jne makes the common path a taken branch --
;  off ahead of rp, its bne in range; 6502-idioms/SKILL.md: compute in A, store once -- a
;  negative |y| from ry0 / ry1 straight (no mA store and reload), out of line]
    bpl rp                  ; (always: Y > 0)
off:                        ; behind the near plane or past 65535: both of its points
    ldx rot_rpp0,y
    bmi o1
    lda #$FF
    sta rpidx,x
o1:
    ldx rot_rpp1,y
    bmi onx
    lda #$FF
    sta rpidx,x
onx:
    jmp nx
yn:                         ; y < 0: |y| -> mA
    sec
    lda #0
    sbc ry0,y
    sta mA
    lda #0
    sbc ry1,y
    sta mA+1
    jmp yd
rp:
    sty rpy
    lda rt2,y               ; T in 0..65535: its top byte 0
    bne off
    lda rt0,y
    sta rq0
    lda rt1,y
    sta rpi
    lda ry2,y               ; the sign of y -> rq1, |y| -> mA (both levels' multiplicand)
    sta rq1
    bmi yn
    lda ry0,y
    sta mA
    lda ry1,y
    sta mA+1
yd:
    ldx rot_rpp0,y          ; the level-0 point: in range iff T < TF0
    jmi no0
    lda rpi
tf0h cmp #0                 ; (zoom_set)
    bcc ok0
    bne out0
    lda rq0
tf0l cmp #0
    bcc ok0
out0:
    lda #$FF
    sta rpidx,x
    jmp no0                 ; (N = 1: a jmi out of range is a bpl over this)
; [2026-10-21 6502-cycles-layout/SKILL.md: rare case out of line -- i < NH (a close camera)
;  jumps away, the common k falls through (C = 1: bcc not taken)]
ok0:
    PROJ_PT 0
pk0 jsr mul16h              ; patches |y| in for level 1 too
    PROJ_TAIL
    lda #<mul16hr
    ldx #>mul16hr
    bne l1s                 ; (always)
kf0:                        ; (PROJ_PT 0's rare case)
    sta dkp
    lda #0
    jsr kfar                ; mB = K[i] - (DK[i] f >> 8)
    jmp pk0
no0:
    lda #<mul16h            ; no level-0 point: level 1 patches
    ldx #>mul16h
l1s:
    sta l1m+1
    stx l1m+2
    ldy rpy
    ldx rot_rpp1,y          ; the level-1 point: in range iff T < TFH
    jmi nx
    lda rpi
tfhh cmp #0
    bcc ok1
    bne out1
    lda rq0
tfhl cmp #0
    bcc ok1
out1:
    lda #$FF
    sta rpidx,x
    jmp nx                  ; (N = 1, as out0)
ok1:
    PROJ_PT 1
l1m jsr mul16h
    PROJ_TAIL
nx:
    ldy rpy
    dey
    jpl rp
    rts
kf1:                        ; (PROJ_PT 1's rare case)
    sta dkp
    lda #1
    jsr kfar
    jmp l1m
.endp

; ==========================================================================
; pvtx: vertex X of set A (c = T, v = y, z = level) -> c = sx (sign-extended),
; v = the stored row (0, 0): the same projection on one clipped vertex.  The
; level patches the six table operands (compared first: only a vertical
; face alternates).  cxo = 1 when sx is off the screen's x range.
; ==========================================================================
.proc pvtx
    stx rti
    lda az,x
lev cmp #$FF
    beq same
    sta lev+1
    tay
    lda lvpg,y              ; the level's first page: rl_lo, rl_hi, rd, rk_lo, rk_hi, rdk
    sta t2+2
    clc
    adc #1
    sta t3+2
    adc #1
    sta t1+2
    adc #1
    sta t5+2
    adc #1
    sta t6+2
    adc #1
    sta t4+2
same:
    lda av0,x               ; |y| -> mA, its sign -> rq1
    sta mA
    lda av1,x
    sta mA+1
    lda av2,x
    sta rq1
    bpl yd
    sec
    lda #0
    sbc mA
    sta mA
    lda #0
    sbc mA+1
    sta mA+1
yd:
    lda ac1,x               ; i
    sta rpi
    tay
t1  lda rd0,y               ; row = ROW[i] - hi(DR[i] f)
    sta ra1+1
    sta ra2+1
    eor #$FF
    sta rb1+1
    sta rb2+1
    lda ac0,x               ; f
    tax
    sec
ra1 lda sqr1lo,x
rb1 sbc sqr2lo,x
ra2 lda sqr1hi,x
rb2 sbc sqr2hi,x            ; (C = 1: a product, no borrow)
    ldx rti
    eor #$FF
t2  adc rl0_lo,y
    sta rrt
t3  lda rl0_hi,y
    adc #$FF
    tay
    lda x16,y
    ldy rrt
    ora shr4,y
    sta av0,x
    lda #0
    sta av1,x
    sta av2,x
    ldy rpi
t4  lda rdk0,y              ; k = K[i] - hi(DK[i] f)
    sta ka1+1
    sta ka2+1
    eor #$FF
    sta kb1+1
    sta kb2+1
    lda ac0,x
    tax
    sec
ka1 lda sqr1lo,x
kb1 sbc sqr2lo,x
ka2 lda sqr1hi,x
kb2 sbc sqr2hi,x
    cpy znh                 ; i < NH: DK past 8 bits (a close camera): kf
    bcc kf
    eor #$FF                ; (C = 1)
t5  adc rk0_lo,y
    sta mB
t6  lda rk0_hi,y
    adc #$FF
    sta mB+1
kd:
    jsr mul16h
    SX_M
    ldy rti
    clc
    txa
    adc #<ROT_SXC
    sta ac0,y
    lda rpm
    adc #>ROT_SXC
    sta ac1,y
    tax                     ; (the high byte, for the compare)
    lda rph
    adc #0
    sta ac2,y
    bmi neg                 ; sx < 0: off the screen
    bne out                 ; sx >= 2^16
    cpx #>[320*16]
    bcc in
    bne out
    lda ac0,y
    beq in
out:
    inc cxo
in:
    ldx rti
    rts
neg:
    inc cxo
    ldx rti
    rts
kf:                         ; (the rare case, out of line)
    sta dkp
    lda lev+1               ; (the level)
    jsr kfar
    jmp kd
.endp
lvpg
    dta >rl0_lo, >rl1_lo

; ==========================================================================
; the clipper: set A (cvn vertices: c, v 24-bit signed, z) against the plane
; c = cp -- ckp = 0 keeps c >= cp, ckp = $80 keeps c <= cp.  A crossing lands
; on the plane with v by the lerp q = |d_a| / |c_b - c_a| (div16r, Q16),
; v = v_a +- (|v_b - v_a| q >> 16) (rot_ref lerp_q16).
; ==========================================================================
; clip_in: pass 1: d = c - cp -> cvd, in -> cvin (1 = on the kept side; d = 0
; is kept by both sides).
; Out: Z = 1 when every vertex is kept (Y = the vertices out).
.proc clip_in
    ldy #0
    ldx cvn
    dex
d1:
    sec
    lda ac0,x
    sbc cp
    sta cvd0,x
    lda ac1,x
    sbc cp+1
    sta cvd1,x
    lda ac2,x
    sbc cp+2
    sta cvd2,x
    eor ckp                 ; the kept sign: in
    bpl in
    lda cvd2,x              ; the other sign: in only if d = 0
    ora cvd1,x
    ora cvd0,x
    beq in
    iny                     ; one more out
    lda #0
    beq st                  ; (always)
in:
    lda #1
st:
    sta cvin,x
    dex
    bpl d1
    tya
    rts
.endp

; cross: the crossing of the edge a (cva) -> b (cvb) with the plane -> set
; B[cvo], cvo += 1.
.proc cross
    ldx cva
    lda cvd0,x              ; num = |d_a| (24 bits)
    sta mA+2
    lda cvd1,x
    sta mA+3
    lda cvd2,x
    sta mA+4
    bpl np
    sec
    lda #0
    sbc mA+2
    sta mA+2
    lda #0
    sbc mA+3
    sta mA+3
    lda #0
    sbc mA+4
    sta mA+4
np:
    ldy cvb                 ; den = |c_b - c_a| (24 bits; num <= den)
    sec
    lda ac0,y
    sbc ac0,x
    sta mB
    lda ac1,y
    sbc ac1,x
    sta mB+1
    lda ac2,y
    sbc ac2,x
    sta mB+2
    bpl dp
    sec
    lda #0
    sbc mB
    sta mB
    lda #0
    sbc mB+1
    sta mB+1
    lda #0
    sbc mB+2
    sta mB+2
dp:                         ; (A = mB+2, Z from its sbc: no reload)
    beq dv                  ; den past 16 bits (a screen edge, sx 24-bit):
                            ; both >> 1 until it fits (rot_ref _cross)
sh:
    lsr mB+2
    ror mB+1
    ror mB
    lsr mA+4
    ror mA+3
    ror mA+2
    lda mB+2
    bne sh
dv:
    jsr div16s              ; mQ = q (2^16 when b lies on the plane)
    ldx cva
    ldy cvb
    lda mQ+2
    jne onb
    sec                     ; dv = v_b - v_a: its magnitude (< 2^16) -> mA, sign -> cds
    lda av0,y
    sbc av0,x
    sta mA
    lda av1,y
    sbc av1,x
    sta mA+1
    lda av2,y
    sbc av2,x
    sta cds
    bpl vp
    sec
    lda #0
    sbc mA
    sta mA
    lda #0
    sbc mA+1
    sta mA+1
vp:
    lda mQ
    sta mB
    lda mQ+1
    sta mB+1
    jsr mul16u              ; pa = +-(|dv| q >> 16) as 24 bits
    lda mP+2
    sta pa
    lda mP+3
    sta pa+1
    lda #0
    sta pa+2
    bit cds
    bpl padd
    sec
    lda #0
    sbc pa
    sta pa
    lda #0
    sbc pa+1
    sta pa+1
    lda #0
    sbc pa+2
    sta pa+2
padd:
    ldx cva
    ldy cvo
    clc                     ; v = v_a + pa
    lda av0,x
    adc pa
    sta bv0,y
    lda av1,x
    adc pa+1
    sta bv1,y
    lda av2,x
    adc pa+2
    sta bv2,y
fin:
    lda cp                  ; c = the plane, z = z_a
    sta bc0,y
    lda cp+1
    sta bc1,y
    lda cp+2
    sta bc2,y
    lda az,x
    sta bz,y
    inc cvo
    rts
onb:                        ; q = 1: v = v_b
    lda av0,y
    sta pa
    lda av1,y
    sta pa+1
    lda av2,y
    sta pa+2
    ldy cvo
    lda pa
    sta bv0,y
    lda pa+1
    sta bv1,y
    lda pa+2
    sta bv2,y
    jmp fin
.endp

; emit_a: set A[X] -> set B[cvo], cvo += 1 (X kept)
.proc emit_a
    ldy cvo
    inc cvo
    lda ac0,x
    sta bc0,y
    lda ac1,x
    sta bc1,y
    lda ac2,x
    sta bc2,y
    lda av0,x
    sta bv0,y
    lda av1,x
    sta bv1,y
    lda av2,x
    sta bv2,y
    lda az,x
    sta bz,y
    rts
.endp

; clip_poly: Sutherland-Hodgman on set A -> set A, cvn = the new count.
; [2026-10-21 fable-skill-atari/SKILL.md 3: a rejection by what it needs -- a plane that cuts
;  nothing leaves set A as it is (no emit, no copy back)]
.proc clip_poly
    jsr clip_in
    beq done                ; every vertex kept
    lda #0
    sta cvo
    sta cva
e1:
    ldx cva                 ; b = a + 1 (mod n)
    inx
    cpx cvn
    bne e2
    ldx #0
e2:
    stx cvb
    ldx cva
    lda cvin,x
    beq noa
    jsr emit_a
    lda cvin,x
noa:
    ldy cvb                 ; a and b on different sides: the crossing too
    cmp cvin,y
    beq nocross
    jsr cross
nocross:
    inc cva
    lda cva
    cmp cvn
    bne e1
    ldx cvo                 ; set B -> set A
    stx cvn
    dex
    bmi done
cb:
    lda bc0,x
    sta ac0,x
    lda bc1,x
    sta ac1,x
    lda bc2,x
    sta ac2,x
    lda bv0,x
    sta av0,x
    lda bv1,x
    sta av1,x
    lda bv2,x
    sta av2,x
    lda bz,x
    sta az,x
    dex
    bpl cb
done:
    rts
.endp

; clip_seg: set A = a segment (2 vertices): an endpoint outside is replaced
; by the crossing (computed 0 -> 1); both outside -> C = 1 (gone).
.proc clip_seg
    lda #2
    sta cvn
    jsr clip_in
    lda cvin
    ora cvin+1
    beq gone
    lda cvin
    cmp cvin+1
    beq keep
    ldx #0
    stx cva
    stx cvo
    inx
    stx cvb
    jsr cross               ; -> set B[0]
    ldx #1                  ; a in: [a, I] ; b in: [I, b]
    lda cvin
    bne put
    dex
put:
    lda bc0
    sta ac0,x
    lda bc1
    sta ac1,x
    lda bc2
    sta ac2,x
    lda bv0
    sta av0,x
    lda bv1
    sta av1,x
    lda bv2
    sta av2,x
keep:
    clc
    rts
gone:
    sec
    rts
.endp

; aset_pv: set A (screen space) -> the fill's vertices: x Q7, the stored row
.proc aset_pv
    ldx cvn
    stx rn
    dex
l:
    lda ac1,x
    sta rq1
    lda ac0,x               ; x << 3 (x in 0..5120: 16 bits)
    asl @
    rol rq1
    asl @
    rol rq1
    asl @
    rol rq1
    sta pvxl,x
    lda rq1
    sta pvxh,x
    lda av0,x
    sta pvyl,x
    dex
    bpl l
    rts
.endp

; [2026-10-22 6502-cycles-layout/SKILL.md: keep a hot stretch in one page with a pad, placed only
;  after an unconditional exit (the rts above) -- kgather's vertex loop kg .. kout]
KG_KG = $0E                 ; kgather.kg - kgather, kgather.tab - kgather (asserted after it)
KG_END = $48
    .if [[*+KG_KG]&$FF]+KG_END-KG_KG > $100
    :[$100-[[*+KG_KG]&$FF]] dta 0
    .endif
; ==========================================================================
; kgather: the item's vertices (n at (src),2, points at 3..n+2) -> set A.
; Every point in the LUT range: screen space (sx sign-extended, the row),
; cxo = 1 if one is off the x range, C = 0.  Else table space (T, y, level)
; from the rotation points, C = 1: the caller clips and projects.
; ==========================================================================
.proc kgather
    ldy #2
    lda (src),y
    sta cvn
    clc
    adc #2
    tay                     ; Y = n + 2: the last vertex
    lda #0
    sta cxo
; [2026-10-21 fable-skill-atari/SKILL.md 1: only what every vertex needs -- c lo / hi and the
;  row; the third bytes (ac2, av1, av2) only the screen clip reads: kfix, when cxo is set]
; [2026-10-28 fable-skill-atari/SKILL.md 1 + 6502-idioms/SKILL.md: use what is loaded -- the
;  "every point projected?" test rides in the gather pass (no second walk, no second Y); a
;  point that is not sends it to tab, which writes every vertex again (and cxo = 0)]
kg:                         ; vertex Y - 3 <- its projection
    lda (src),y
    tax
    lda rpidx,x
    cmp #$FF
    beq tab
    lda rpyl,x
    sta av0-3,y
    lda rpxl,x
    sta ac0-3,y
    lda rpxh,x
    sta ac1-3,y
    cmp #>[320*16]          ; sx's middle byte: 0..$13 in (if rpxx = 0)
    bcs kc
    lda rpxx,x
    bne kout                ; sx < 0 or past 2^16
kin:
    dey
    cpy #2
    bne kg
    clc
    rts
kc:
    bne kout                ; $14 + 1.. (and every negative middle byte)
    lda rpxl,x              ; $14xx: in only at x = 320 * 16 exactly
    ora rpxx,x
    beq kin
kout:
    inc cxo
    bne kin                 ; (always: one per vertex, cxo < 256)
tab:
    lda #0                  ; (kg may have counted some: table space starts clean)
    sta cxo
    lda cvn
    clc
    adc #2
    tay
kt:                        ; vertex Y - 3 <- its rotation point, its level
    lda (src),y
    tax
    cpx #ROT_NPP0           ; level 1 from NPP0 on
    lda #0
    rol @
    sta az-3,y
    lda rot_pprp,x
    tax
    lda rt0,x
    sta ac0-3,y
    lda rt1,x
    sta ac1-3,y
    lda rt2,x
    sta ac2-3,y
    lda ry0,x
    sta av0-3,y
    lda ry1,x
    sta av1-3,y
    lda ry2,x
    sta av2-3,y
    dey
    cpy #2
    bne kt
    sec
    rts
.endp
    ert >kgather.kg <> >[kgather.tab-1]
    ert kgather.kg-kgather <> KG_KG || kgather.tab-kgather <> KG_END

; kfix: set A from kgather's screen points (cxo set: the screen clip next) ->
; their third bytes: c's (rpxx), v's (0)
.proc kfix
    lda cvn
    clc
    adc #2
    tay                     ; Y = n + 2: the last vertex
lp:
    lda (src),y
    tax
    lda rpxx,x
    sta ac2-3,y
    lda #0
    sta av1-3,y
    sta av2-3,y
    dey
    cpy #2
    bne lp
    rts                     ; (C = 1: Y = 2)
.endp

; set_near / set_far: the plane cells for the table-space clips (the far
; plane of the item's class: rkind bit 6 = level H)
.proc set_near
    lda #0
    sta cp
    sta cp+1
    sta cp+2
    sta ckp
    rts
.endp
.proc set_far
    ldx tfp0
    ldy tfp0+1
    bit rkind
    bvc f0
    ldx tfph
    ldy tfph+1
f0:
    stx cp
    sty cp+1
    lda #0
    sta cp+2
    lda #$80
    sta ckp
    rts
.endp

; clip_x: set A (screen space) against x = 0 and x = 320 (polygon)
.proc clip_x
    jsr set_near            ; x >= 0
    jsr clip_poly
    lda cvn
    cmp #3
    bcc out
    jsr set_right
    jmp clip_poly
out:
    rts
.endp
.proc set_right
    lda #<[320*16]
    sta cp
    lda #>[320*16]
    sta cp+1
    lda #0
    sta cp+2
    lda #$80
    sta ckp
    rts
.endp

; ==========================================================================
; cull_face: the item's a, b (Q6 signed) and d' (3 bytes signed) at (src),1..5
; -> C = 1 visible: a eu + b ev > d'.  8 x 16 products by quarter squares.
; ==========================================================================

.proc cull_face
    ldy #1                  ; acc = -d' + the u term (cull_prep's entry)
    lda (src),y
    tax
    ldy #3
    clc
    lda (src),y
    adc ct0,x
    sta cacc
    iny
    lda (src),y
    adc ct1,x
    sta cacc+1
    iny
    lda (src),y
    adc ct2,x
    sta cacc+2
    ldy #2                  ; + the v term
    lda (src),y
    tax
    clc
    lda cacc
    adc ct0,x
    sta cacc
    lda cacc+1
    adc ct1,x
    sta cacc+1
    lda cacc+2
    adc ct2,x
    bmi hid                 ; visible iff acc > 0
    ora cacc+1
    ora cacc
    beq hid
    sec
    rts
hid:
    clc
    rts
.endp

; cull_prep: the cull test's products once a frame (view_setup, after the eye):
; per normal magnitude m_j (rot_export cm_mag) ct[j] = m_j eu, ct[M + j] = -m_j eu
; (signed 24-bit), the v ones from NCU on, ct[0] = ct[NCU] = 0.  cull_face adds two
; of them to -d': the same sums as a*eu + b*ev - d', the same faces.
; [2026-10-22 6502-loops-tables-smc/SKILL.md: tables beat arithmetic -- 22 faces, 5
;  magnitudes; fable-skill-atari/SKILL.md 4: shared work once a frame]
.proc cull_prep
    lda #0                  ; the zero factor's entries
    sta ct0
    sta ct1
    sta ct2
    sta ct0+ROT_NCU
    sta ct1+ROT_NCU
    sta ct2+ROT_NCU
    ldx #2
cu:
    lda eum,x               ; |eu|, its sign
    sta cacc+3,x
    dex
    bpl cu
    ldy #ROT_NCM
    jsr cpr
    ldx #2
cv:
    lda evm,x
    sta cacc+3,x
    dex
    bpl cv
    ldy #ROT_NCU+ROT_NCM
    jsr cpr
    ldx #ROT_NCU-1          ; the sloped faces' v entries: + this zoom's KS (the
k:                          ;   eye's height: rot_ref Zoom.KS; zoom_set patches it)
    clc
    lda ct0+ROT_NCU,x
k0  adc #0
    sta ct0+2*ROT_NCU,x
    lda ct1+ROT_NCU,x
k1  adc #0
    sta ct1+2*ROT_NCU,x
    lda ct2+ROT_NCU,x
k2  adc #0
    sta ct2+2*ROT_NCU,x
    dex
    bpl k
    rts
.endp

; cpr: Y = the last + entry -> its ROT_NCM products with e (cacc+3..5: |e|, sign)
.proc cpr
    lda #ROT_NCM
    sta cds
l:
    lda cm_mag,y
    ldx cacc+3
    jsr fmulu               ; m |e| lo (fmulu keeps X and Y)
    lda fmpl
    sta pa
    lda fmph
    sta pa+1
    lda cm_mag,y
    ldx cacc+4
    jsr fmulu               ; m |e| hi, a byte up
    clc
    lda pa+1
    adc fmpl
    sta pa+1
    lda fmph
    adc #0
    sta pa+2
    bit cacc+5              ; e < 0: the + entry is -P
    bpl p
    jsr neg
p:
    lda pa
    sta ct0,y
    lda pa+1
    sta ct1,y
    lda pa+2
    sta ct2,y
    jsr neg
    lda pa
    sta ct0+ROT_NCM,y
    lda pa+1
    sta ct1+ROT_NCM,y
    lda pa+2
    sta ct2+ROT_NCM,y
    dey
    dec cds
    bne l
    rts
neg:
    sec
    lda #0
    sbc pa
    sta pa
    lda #0
    sbc pa+1
    sta pa+1
    lda #0
    sbc pa+2
    sta pa+2
    rts
.endp

; ==========================================================================
; rot_draw: the whole table into the clean buffer (CLN_BK) -- backdrop clear, then
; the draw list.  The blitter is idle when this returns.
; ==========================================================================
.proc rot_draw
    lda #$80                ; window -> bank 0 (the BCBs)
    ldy #MA_BSEL
    sta (VB),y
    jsr bwait
    SETBL $40               ; the fill template, V:$000140
    ; --- clear: 40x30 at zoom 8x8 = 320x240, backdrop ---
    lda #0
    sta FB+6
    sta FB+16
    lda #>SCR_OFF           ; (the buffer starts at bank + 0: the mid byte is the offset's)
    sta FB+7
    lda #CLN_BK
    sta FB+8
    lda #39
    sta FB+12
    lda #29
    sta FB+14
    lda #$77
    sta FB+18
    jsr bstart              ; the clear runs while the points are worked out
    jsr rot_trig
    jsr view_setup
    jsr rot_load
    jsr dtest               ; (falls into rot_project)
    jsr bwait
    lda #0
    sta FB+14
    sta FB+18
    lda #<rot_dl
    sta src
    lda #>rot_dl
    sta src+1
    bne item                ; (always)
cull:
    cmp #$FF
    bne c1
    lda #0                  ; the draw template's source bank: 0 again (rdisc: the balls')
    sta DB+2
    jmp bwait               ; end: let the last blit finish
c1:
    cmp #$FE                ; the D's header: its items skipped (dtest) or entered
    beq dgrp
    sta rkind
    jsr cull_face
    bcc hid
    lda src                 ; visible: skip the 5-byte header to its last byte (C = 1)
    adc #4
    sta src
    bcc c2
    inc src+1
c2:
    lda rkind
    and #$7F
    bpl vis                 ; (always)
hid:                        ; culled: skip header + item
    lda rkind
    and #3
    bne h1
    ldy #7                  ; poly: 1 + 5 + 2 + n (n at 7)
    lda (src),y
    clc
    adc #8
    bne nxa                 ; (always)
h1:
    cmp #2
    beq h2
    lda #8                  ; disc, spot: 1 + 5 + 2
    bne nxa                 ; (always)
h2:
    lda #10                 ; line: 1 + 5 + 4
    bne nxa                 ; (always)
dgrp:
    lda #2                  ; the header alone
    bit dskip
    bpl nxa
    ldy #1                  ; + the D's items: 2 + their bytes (its second byte)
    lda (src),y
    bne nxa                 ; (always)
; next item: src += A (the item's size); the fields are read as (src),y
nxp:                        ; poly / line: A = n -> 3 + n
    sec
    adc #2
    bne nxa                 ; (always)
nx3:
    lda #3
nxa:
    clc
    adc src
    sta src
    bcc item
    inc src+1
item:
    ldy #0
    lda (src),y
    bmi cull                ; angle-culled kind, or the end ($FF)
vis:                        ; A = kind: 0 poly, 1 disc, 2 line, 3 spot (bit 6: level H)
    sta rkind
    and #3
    beq kpoly
    cmp #2
    bcc kdisc
    beq kline
kspot:
    ldy #1                  ; colour, pp
    lda (src),y
    sta FB+16
    iny
    lda (src),y
    tax
    jsr rspot
    jmp nx3
kpoly:
    jsr kgather
    bcc kscr0
    jsr set_near            ; table space: the near plane, the far plane
    jsr clip_poly
    lda cvn
    cmp #3
    bcc knext
    jsr set_far
    jsr clip_poly
    lda cvn
    cmp #3
    bcc knext
    ldx cvn                 ; -> screen space
    dex
kp:
    jsr pvtx
    dex
    bpl kp
kscr:
    lda cxo
    beq kpv
kcl:
    jsr clip_x
    lda cvn
    cmp #3
    bcc knext
kpv:
    jsr aset_pv
    ldy #1
    lda (src),y
    sta FB+16
    jsr rfill
knext:
    ldy #2
    lda (src),y
    jmp nxp
; from kgather's screen points (never the pvtx path's: theirs are set): the
; clip's third bytes first
kscr0:
    lda cxo
    beq kpv
    jsr kfix
    bcs kcl                 ; (always: kfix ends with C = 1)
lscr0:
    lda cxo
    beq lpv
    jsr kfix
    bcs lcl                 ; (always: kfix ends with C = 1)
kdisc:
    ldy #1
    lda (src),y
    sta rn                  ; class
    iny
    lda (src),y
    tax                     ; pp
    jsr rdisc
    jmp nx3
kline:
    jsr kgather
    bcc lscr0
    jsr set_near
    jsr clip_seg
    bcs knext
    jsr set_far
    jsr clip_seg
    bcs knext
    ldx #1
    jsr pvtx
    dex
    jsr pvtx
lscr:
    lda cxo
    beq lpv
lcl:
    jsr set_near
    jsr clip_seg
    bcs knext
    jsr set_right
    jsr clip_seg
    bcs knext
lpv:
    jsr aset_pv
    ldy #1
    lda (src),y
    sta FB+16
    jsr rline
    jmp knext
.endp


; ==========================================================================
; blitter helpers (the window is on bank 0)
; ==========================================================================
FB    = WINDOW+$140     ; the fill template (AND 0, mode 0, one row)

; [2026-10-09 6502-loops-tables-smc/SKILL.md: patch an absolute operand instead of (zp),y -- page = VB+1, set_angle]
.proc bwait                 ; keeps X, Y
w:
    lda $D653
    bne w
    rts
.endp

.proc bstart                ; keeps X, Y
    lda #1
st  sta $D653
    rts
.endp


; ==========================================================================
; redga / redgb: the edge pv[Y] -> pv[X] (x Q7, y = the vertex rows,
; y[Y] <= y[X]) straight into chain A's / B's cells.  Out: C = 1 empty, else
; rows, first row, x (3, Q8 + 0.5 + 255 px: never below 0, so the width's
; subtraction never borrows across; ymmid1 takes the 255 back) and m (3, Q8
; per row): 0 for one row, dx for two, else dx * RCP7[rows] >> 16 (the high
; word: no shifting); rfill's carry step patched for the sign of m.
; ==========================================================================
.macro REDGE           ; :1 rows, :2 first row (if :7), :3 x, :4+2 m's sign byte, :5 / :6 rfill's step patches,
                        ; :8 / :9 = m's low / mid byte: rfill's adc # operands
    sec
    lda pvyl,x
    sbc pvyl,y
    bne ok
    rts                     ; (C = 1: no borrow)
ok
    sta :1
  .if :7
    lda pvyl,y
    sta :2
  .endif
; x = (x0 << 1) + 128 + $FF00: the chains hold x + 255.  x0 runs to 40960
; (320 px): x0 << 1 is 17 bits.
; [2026-10-21 6502-idioms/SKILL.md: compute in A, store once -- no reload of :3 / :3+1;
;  a value that only parks goes on the stack (pha / pla)]
    lda pvxl,y
    asl @                   ; C = bit 7 of x0
    lda pvxh,y
    rol @                   ; the mid byte of x0 << 1, C = bit 16
    pha
    lda #0
    rol @                   ; bit 16 (C = 0)
    sta :3+2
    pla
    adc #$FF                ; + $FF00
    sta :3+1
    bcc xc
    inc :3+2
xc
    lda pvxl,y              ; the low byte + 128: bit 7 flips, a carry when it was set
    asl @
    eor #$80
    sta :3
    bmi b1
    inc :3+1
    bne b1
    inc :3+2
b1
    sec                     ; dx = x1 - x0: 17 bits (x < 40960), the sign is
    lda pvxl,x              ; the borrow
    sbc pvxl,y
    sta mA
    lda pvxh,x
    sbc pvxh,y
    sta mA+1
    ror edsn                ; bit 7 = C: 1 = no borrow = dx >= 0
    ldy :1
    cpy #3
    bcs mul
    cpy #2
    bne m0
    sta :9                ; two rows: m = dx (sign-extended)
    lda mA
    sta :8
    lda #0
    bit edsn
    bmi e2
    lda #$FF
    sta :4+2
    bmi mneg                  ; (always)
e2
    sta :4+2
    beq mpos                  ; (always)
m0
    lda #0                  ; one row: never steps
    sta :8
    sta :9
    sta :4+2
    beq mpos                  ; (always)
mul
    lda rcp_lo,y
    sta mB
    lda rcp_hi,y
    sta mB+1
    bit edsn                ; |dx|
    bmi dxp
    lda #0                  ; (C = 1: bcs mul taken -- 2026-10-28 6502-idioms: no sec)
    sbc mA
    sta mA
    lda #0
    sbc mA+1
    sta mA+1
dxp
    jsr mul16u
    bit edsn
    bpl neg
    lda mP+2
    sta :8
    lda mP+3
    sta :9
    lda #0
    sta :4+2
    beq mpos                  ; (always)
neg
    sec                     ; m = -(P >> 16)
    lda #0
    sbc mP+2
    sta :8
    lda #0
    sbc mP+3
    sta :9
    lda #0                  ; (the borrow: -0 stays 0)
    sbc #0
    sta :4+2
    bmi mneg
mpos                          ; m >= 0: bcs + inc
    lda #$B0
    sta :5
    lda #$E6
    sta :6
    clc
    rts
mneg                          ; m < 0: bcc + dec
    lda #$90
    sta :5
    lda #$C6
    sta :6
    clc
    rts
.endm

; [2026-10-09 6502-mads/SKILL.md: labels are case-insensitive -- macro labels mpos/mneg, never mp (= mP)]
.proc redga                 ; chain A (and rline)
    REDGE rna, era0, rxa, rma, rfill.ba, rfill.ia, 1, rfill.ma0+1, rfill.ma1+1
.endp
.proc redgb                 ; chain B
    REDGE rnb, 0, rxb, rmb, rfill.bb, rfill.ib, 0, rfill.mb0+1, rfill.mb1+1
.endp



; [2026-10-09 6502-cycles-layout/SKILL.md: keep a hot stretch in one page with a pad, placed only
;  after an unconditional exit (redgb ends in rts) -- the row loop of rfill]
RF_ROW = $AD                ; rfill.row - rfill   (asserted after rfill)
RF_LEN = $4C                ; rfill.rowend - rfill.row
RF_END = $160               ; the end of rare (after hia / hib) - rfill: the row loop and the
                            ;   blocks its taken branches reach share one page
    .if [[*+RF_ROW]&$FF]+RF_END-RF_ROW > $100
    :[$100-[[*+RF_ROW]&$FF]] dta 0
    .endif
; ==========================================================================
; rfill: convex polygon pv[0..rn-1] (Q7, stored rows) as row spans.  Chains
; from the top vertex: A forward, B backward; per row the span between them.
; A run never crosses a bank step: stored rows 0..7 and 212.. sit in the
; buffer's next bank (the junk rows and the rows past 204).
; ==========================================================================
.proc rfill
; [2026-10-09 fable-skill-atari/SKILL.md 6: registers over memory for what a loop carries -- the top in Y]
    ldy #0                  ; top = min (y, index): Y = the top so far (n >= 3)
    ldx #1
tl:
    lda pvyl,x
    cmp pvyl,y
    bcs tnx
    txa
    tay
tnx:
    inx
    cpx rn
    bne tl
    sty rtop
    sty ria
    sty rib
    lda #0
    sta raend
    sta rbend
    jsr nexta
    jcs out
    jsr nextb
    jcs out
    ldx era0                ; X = row (rows start where chain A does)
    SETBL $40               ; the fill template for the whole polygon
run:                        ; rows until the next chain event: min(rna, rnb)
    lda rna
    cmp rnb
    bcc rmin
    lda rnb
; [2026-10-09 6502-idioms/SKILL.md: no RAM cell for a value that only waits -- the row count in Y (dey/bne)]
rmin:
    cpx #212                ; the rows from 212 up: the next bank
    bcs lo
    cpx #8
    bcc top
    sta rrun                ; 8..211: the buffer's bank, up to row 212 (C = 1)
    txa
    eor #$FF
    adc #212                ; ~X + 212 + 1 = 212 - X
    cmp rrun
    bcs up
    sta rrun
up:
    lda #CLN_BK             ; the buffer's bank
    sta FB+8
    ldy rrun                ; Y = rows left in this run
; [2026-10-21 vbxe-blitter/SKILL.md: fewer, larger blits -- both chains under 1 px a row
;  (m1 = 0, or $FF with m0 <> 0) and 4+ rows: mrun joins equal rows into one blit]
    cpy #4
    bcc row
    jmp mtest               ; (mrun.asm: the slopes' test out of this block's RAM)
; [2026-10-21 6502-cycles-layout/SKILL.md: rare case out of line -- row 212 (the first row
;  of its run: runs split there) gets the row's fields here and drops the carry]
r212:
    clc
    lda rxb+1
    sbc rxa+1
    sta FB+12
    lda rxb+2
    sbc rxa+2
    jmi rare
    sta FB+13
    lda ymlo,x              ; C = 1
    adc rxa+1
    sta FB+6
    lda ymmid1,x
    adc rxa+2
    sta FB+7
    clc                     ; (dst = bank+1:$0000.. : the add carried out)
    jmp go
top:                        ; 0..7: the junk rows, up to row 8 (C = 0)
    sta rrun
    txa
    eor #$FF
    adc #9                  ; ~X + 9 = 8 - X
    cmp rrun
    bcs lo1
    sta rrun
lo1:
    lda rrun
lo:
    sta rrun
    tay
    lda #CLN_BK+1           ; the bank + 1 (SCR_OFF, junk rows)
    sta FB+8
    cpx #212                ; row 212 starts on the 64K line: its dst add carries (r212)
    beq r212
; per row: fields first (the running blit already holds its BCB), then wait
; for it and start this one.  Buffers are 64K-aligned: dst hi = row hi + bank.
; Both chains hold x + 255 (REDGE): the width is unchanged, the carry the
; width leaves is the +1 and ymmid1 (= ymmid - 1) takes the 256 back.
; [2026-10-09 6502-idioms/SKILL.md: flags are values you track -- the width's C = 1 is the +1 of dst (no clc)]
row:
    clc                     ; d = xb - xa - 1 (= width - 1 when >= 0)
    lda rxb+1
    sbc rxa+1
    sta FB+12
    lda rxb+2
    sbc rxa+2
    bmi rare                ; width <= 0 or the chains crossed (tips only)
    sta FB+13
                            ; C = 1: d >= 0 (both chains >= 255: no borrow across)
    lda ymlo,x              ; dst = row * 320 - 256 + (x + 255) + 1 + buffer
    adc rxa+1
    sta FB+6
    lda ymmid1,x
    adc rxa+2
    sta FB+7                ; (no carry: a row never crosses 64K)
go:
wt  lda $D653               ; BUSY (page patched by rot_draw)
    bne wt
    lda #1
st  sta $D653               ; START
; [2026-10-09 6502-cycles-layout/SKILL.md: rare case out of line, not-taken branch on the hot path (hia/hib)]
step:                       ; x += m (C = 0: the dst add never carries, SCR_OFF).
; [2026-10-09 6502-loops-tables-smc/SKILL.md: a variable as the operand of adc # -- the slopes, patched by REDGE]
    lda rxa                 ; |m| < 256 px/row whenever a next row uses it, so
ma0 adc #0                  ; the integer high byte only moves by the carry --
                            ; rarely: bcs (m >= 0) / bcc (m < 0) to the inc/dec
    sta rxa                 ; out of line, patched per edge (cop)
    lda rxa+1
ma1 adc #0
    sta rxa+1
ba  bcs hia
sa:
    clc
    lda rxb
mb0 adc #0
    sta rxb
    lda rxb+1
mb1 adc #0
    sta rxb+1
bb  bcs hib
sb:
    inx
    dey
    bne row
rowend:
    sec                     ; the run is over: both chains advanced rrun rows
    lda rna
    sbc rrun
    sta rna
    bne aok                 ; (C = 1: rrun <= rna)
    stx rrw
    jsr nexta
    ldx rrw
    bcs out
    sec
; [2026-10-09 6502-idioms/SKILL.md: sec after a not-taken bcc is dead -- only the nexta path sets C]
aok:
    lda rnb
    sbc rrun
    sta rnb
    jne run
    stx rrw
    jsr nextb
    ldx rrw
    jcc run
out:
    rts
hia:                        ; the chains' high-byte steps (x crossed a 256 boundary)
ia  inc rxa+2               ; (inc / dec, patched)
    jmp sa
hib:
ib  inc rxb+2
    jmp sb
; [2026-10-22 6502-cycles-layout/SKILL.md: a taken branch to another page costs +1 -- rare
;  (taken at the polygons' tips, ~160 times a frame) after hia / hib, all on the row loop's page]
rare:                       ; d = -1: nothing ; else swap: x = xb, w-1 = xa-xb-1
    cmp #$FF
    bne swp
    lda FB+12
    cmp #$FF
    bne swp
    clc
    bcc step                ; (always)
swp:
    clc
    lda rxa+1
    sbc rxb+1
    sta FB+12
    lda rxa+2
    sbc rxb+2
    sta FB+13
    sec                     ; (x + 255) + 1 - 256
    lda ymlo,x
    adc rxb+1
    sta FB+6
    lda ymmid1,x
    adc rxb+2
    sta FB+7
    clc                     ; (row 212's add carries: step wants C = 0)
    jmp go
rend:
.endp
; [2026-10-09 6502-cycles-layout/SKILL.md: keep a hot stretch in one page -- the row loop (~800 rows a frame)]
    ert >rfill.row <> >[rfill.rend-1]
    ert rfill.row-rfill <> RF_ROW
    ert rfill.rowend-rfill.row <> RF_LEN
    ert rfill.rend-rfill <> RF_END

; span: one fill row: row = rrw, x = rsx (16), width = rsw (16, > 0).
.proc span
    SETBL $40
    ldx rrw
    clc                     ; dst = row * 320 + x + the buffer's bank (its mid byte is 0)
    lda ymlo,x
    adc rsx
    sta FB+6
    lda ymmid,x
    adc rsx+1
    sta FB+7
    lda ymhi,x
    adc #CLN_BK
    sta FB+8
    lda rsw                 ; width - 1 (C = 0: ymhi <= 1 + the bank 6 never carries --
    sbc #0                  ;   2026-10-28 6502-idioms: sbc #v-1 for the sec)
    sta FB+12
    lda rsw+1
    sbc #0
    sta FB+13
w   lda $D653               ; (page: set_angle) -- 6502-cycles-layout: inlined, smaller than a call
    bne w
    lda #1
st  sta $D653
    rts
.endp


; nexta / nextb: the next non-empty edge of chain A (forward from the top
; vertex) / B (backward).  A chain ends where y decreases or at the top again
; (that last edge still counts).  C = 1: no more edges.
.proc nexta
lp:
    lda raend
    bne endc
    ldx ria                 ; j = i + 1 (mod n)
    inx
    cpx rn
    bne n1
    ldx #0
n1:
    ldy ria
    lda pvyl,x              ; y[j] < y[i] -> the chain is over
    cmp pvyl,y
    bcc endc
fwd:
    stx ria
    cpx rtop
    bne n2
    inc raend
n2:
    jsr redga               ; edge i (Y) -> j (X)
    bcs lp
    rts
endc:
    sec
    rts
.endp

.proc nextb
lp:
    lda rbend
    bne endc
    ldx rib                 ; j = i - 1 (mod n)
    dex
    bpl n1
    ldx rn
    dex
n1:
    ldy rib
    lda pvyl,x
    cmp pvyl,y
    bcc endc
fwd:
    stx rib
    cpx rtop
    bne n2
    inc rbend
n2:
    jsr redgb
    bcs lp
    rts
endc:
    sec
    rts
.endp

; ==========================================================================
; clip_blit: the sprite rectangle (bsx, bsy: 16-bit signed top-left, bsw x
; bsh, source bsrc with pitch bpit) cut to the screen: x in [0, 320), stored
; rows in [8, 248).  C = 1: nothing left.  bsy's low byte is the row then.
; ==========================================================================
.proc clip_blit
    lda bsx+1
    bpl xr
    cmp #$FF                ; x < -255: off (a sprite is < 256 wide)
    bne gone
    sec                     ; n = -x: source += n, width -= n
    lda #0
    sbc bsx
    tax
    clc
    adc bsrc
    sta bsrc
    bcc s1
    inc bsrc+1
s1:
    txa
    eor #$FF
    sec
    adc bsw                 ; width - n
    bcc gone
    beq gone
    sta bsw
    lda #0
    sta bsx
    sta bsx+1
xr:                         ; x + width <= 320 ?
    clc
    lda bsx
    adc bsw
    tax
    lda bsx+1
    adc #0
    cmp #>320
    bcc yc
    bne over
    cpx #<320+1
    bcc yc
over:
    sec                     ; width = 320 - x
    lda #<320
    sbc bsx
    sta bsw
    lda #>320
    sbc bsx+1
    bcc gone                ; x > 320
    lda bsw
    bne yc                  ; (x = 320: nothing)
gone:
    sec
    rts
yc:
    lda bsy+1
    beq yr
    bpl gone                ; y >= 256: below
    cmp #$FF
    bne gone                ; y < -256
    sec                     ; -255 <= y < 0: n = 8 - y (> 255 for y < -247: off)
    lda #8
    sbc bsy
    bcs gone
    bcc ycut                ; (always)
yr:
    lda bsy
    cmp #8
    bcs ybot
    eor #$FF                ; 0 <= y < 8: n = 8 - y = ~y + 9 (C = 0)
    adc #9
ycut:                       ; A = n: source += n * pitch, height -= n, y = 8
    tax
sl:
    clc
    lda bsrc
    adc bpit
    sta bsrc
    bcc s2
    inc bsrc+1
s2:
    dex
    bne sl
    sec
    lda #8
    sbc bsy                 ; (n again: A was spent on the source)
    eor #$FF
    sec
    adc bsh                 ; height - n
    bcc gone
    beq gone
    sta bsh
    lda #8
    sta bsy
    lda #0
    sta bsy+1
ybot:                       ; y + height <= 248 ?
    clc
    lda bsy
    adc bsh
    bcs cut
    cmp #249
    bcc ok
cut:
    sec                     ; height = 248 - y
    lda #248
    sbc bsy
    bcc gone
    beq gone
    sta bsh
ok:
    clc
    rts
.endp

; (rdisc: in rdisc.asm, after the draw list -- main.asm)


; ==========================================================================
; rline: the baulk line pv[0] -> pv[1] (aset_pv) -- per row the run between
; this row's and the next row's x, at least 1 pixel.
; ==========================================================================
.proc rline
    lda pvyl+1              ; pv[0] above pv[1] (strictly: y0 > y1 swaps)
    cmp pvyl
    bcs ok
    ldx pvxl
    lda pvxl+1
    sta pvxl
    stx pvxl+1
    ldx pvxh
    lda pvxh+1
    sta pvxh
    stx pvxh+1
    ldx pvyl
    lda pvyl+1
    sta pvyl
    stx pvyl+1
ok:
    ldy #0
    ldx #1
    jsr redga
    jcs flat
    lda rna                 ; one row: its run end to end, as a flat line (a 1-row
    cmp #1                  ;   edge never steps: the D's chords lost all but a pixel)
    jeq flat
    lda era0
    sta rrw
    sec                     ; chain A holds x + 255: x itself here
    lda rxa+1
    sbc #$FF
    sta rxa+1
    lda rxa+2
    sbc #0
    sta rxa+2
row:
    lda rxa+1               ; the run starts at int(x) ...
    sta rsx
    clc                     ; ... x += m in place (span leaves rxa alone)
    lda rxa
    adc rfill.ma0+1         ; (chain A's slope lives in rfill's operands)
    sta rxa
    lda rsx
    adc rfill.ma1+1
    sta rxa+1
    lda rxa+2
    sta rsx+1
    adc rma+2
    sta rxa+2
    sec                     ; w = int(x + m) - int(x)
    lda rxa+1
    sbc rsx
    sta rsw
    lda rxa+2
    sbc rsx+1
    sta rsw+1
    bpl wp                  ; (N: the sbc's)
    lda rxa+1               ; next < x: start at next, w = -w
    sta rsx
    lda rxa+2
    sta rsx+1
    lda #1                  ; (C = 0: x hi 0..1 both, N = 1 is the borrow -- 2026-10-28
    sbc rsw                 ;   6502-idioms: 1 - w - 1 for the sec)
    sta rsw
    lda #0
    sbc rsw+1
    sta rsw+1
wp:
    lda rsw
    ora rsw+1
    bne w1
    lda rsx+1               ; at least one pixel -- none at x = 320 (rot_ref
    beq w0                  ;   line: min(w, hi); a run never ends past 320
    lda rsx                 ;   otherwise: its ends are clipped to 0..320)
    cmp #<320
    bcs w2
w0:
    inc rsw
w1:
    jsr span
w2:
    inc rrw
    dec rna
    jne row
out:
    rts
flat:                       ; both ends on one row: one run, end inclusive
    lda pvxl                ; ex0 / ex1 = the ends, ordered
    sta ex0
    lda pvxh
    sta ex0+1
    lda pvxl+1
    sta ex1
    lda pvxh+1
    sta ex1+1
    lda ex0
    cmp ex1
    lda ex0+1
    sbc ex1+1
    bcc ord
    lda ex0
    ldy ex1
    sta ex1
    sty ex0
    lda ex0+1
    ldy ex1+1
    sta ex1+1
    sty ex0+1
ord:
    lda pvyl
    sta rrw
    ldx #7                  ; (cold) x >> 7 for both ends
sh:
    lsr ex0+1
    ror ex0
    lsr ex1+1
    ror ex1
    dex
    bne sh
    lda ex0
    sta rsx
    lda ex0+1
    sta rsx+1
    sec                     ; w = hi - lo + 1
    lda ex1
    sbc ex0
    sta rsw
    lda ex1+1
    sbc ex0+1
    sta rsw+1
    inc rsw
    bne fc
    inc rsw+1
fc:
    lda ex1+1               ; hi = 320 (clipped there): the run ends at 319
    beq sp                  ;   (rot_ref line: min(w, hi))
    lda ex1
    cmp #<320
    bcc sp
    lda rsw                 ; w - 1: 0 when lo = 320 too -- nothing
    bne nb
    dec rsw+1
nb:
    dec rsw
    lda rsw
    ora rsw+1
    beq none
sp:
    jmp span
none:
    rts
.endp

; rspot: X = projection point -> a 2x2 square at (sx >> 4, its row), when
; both columns and both rows are on the screen
.proc rspot
    lda rpidx,x
    cmp #$FF
    beq out
    lda rpyl,x              ; rows 8..246 (stored)
    cmp #8
    bcc out
    cmp #247
    bcs out
    sta rrw
    lda rpxx,x              ; sx past 16 bits: off
    bne out
    lda rpxh,x              ; x = sx >> 4: 0..318 (the range check below)
    lsr @
    lsr @
    lsr @
    lsr @
    sta rsx+1
    lda rpxh,x
    and #15
    tay
    lda x16,y
    sta rq0
    ldy rpxl,x
    lda shr4,y
    ora rq0
    sta rsx
    ldy rsx+1               ; [2026-10-21 6502-idioms/SKILL.md: x >= 512 was let through]
    beq ok
    dey
    bne out
    cmp #319-256
    bcs out
ok:
    lda #2
    sta rsw
    lda #0
    sta rsw+1
    jsr span
    inc rrw
    jmp span
out:
    rts
.endp
