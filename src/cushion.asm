; cushion.asm -- a ball against a cushion: Mathavan, Jackson, Parkin, 'A theoretical
; analysis of billiard ball dynamics under cushion impacts' (Proc. IMechE C 224, 2010,
; docs/), the snooker values: the cushion touches the ball at h = 7R/5 (sin = 2/5),
; ee = 0.98, mu_w = 0.14 (cushion), mu_s = 0.212 (cloth).  The impulse in 4 Euler
; steps until the ball stops into the cushion, the rebound until the work is ee^2
; of that: asm_bench.py --cushion's fx_solve, bit for bit.  Its own VRAM bank,
; V:CU_BANK000, a 4 KB window at $2000 while reflx / refly (physics.asm) need it.  The side spin w = R wz (Q9)
; lives here per ball with the physics tick it was set at (tick16): the cloth
; takes 10.9 rad/s^2 off it (pooltool: 5 u_sp g / 2R, u_sp = 0.444 R).
; [2026-10-22 6502-idioms/SKILL.md: code size is RAM -- the model runs from VRAM;
;  math.asm's smul3r / divr / mul16u / fmulu, physics' spin_u; the derivative is a
;  table of operations for one small loop, not twenty inline multiplies]

    org vbank               ; assembled for the 4 KB window at $2000, staged there,
    dta CU_BANK-1           ;   copied to V:CU_BANK000 by vram_next
    org $2000

; the cells (3 bytes each, cu_kv + K_*): velocities Q9, the rest Q16
K_VX    = 0                 ; the state: vx, vy (into the cushion > 0), ux, uy, w
K_VY    = 3
K_UX    = 6
K_UY    = 9
K_W     = 12
K_N     = 15                ; the next state (5)
K_D     = 30                ; its derivative (5)
K_CT    = 45                ; constants
K_ST    = 48
K_MUW   = 51
K_MUS   = 54
K_K25   = 57
K_ZERO  = 60
K_T1    = 63
K_T2    = 66
K_XI    = 69                ; the slip at the cushion, then its cu_unit vector
K_YI    = 72
K_CI    = 75
K_SI    = 78
K_XC    = 81                ; at the cloth
K_YC    = 84
K_CC    = 87
K_SC    = 90
K_A     = 93
K_B     = 96
K_K     = 99
K_M1    = 102
K_M2    = 105
K_H     = 108               ; this step's impulse
K_DP    = 111               ; the whole step
K_RC    = 114               ; a nose (pocket.asm cu_nose): the unit vector into it (Q16),
K_RS    = 117               ;   the nose's centre less the ball (Q12)
K_RX    = 120
K_RY    = 123

CU_DW   = 937               ; w lost a tick (1/200 s), Q9 << 8

OP_MUL  = 0                 ; d = x * y (smul3r)
OP_ADD  = 1                 ; d = x + y
OP_SUB  = 2                 ; d = x - y
OP_UNIT = 3                 ; d, d + 3 = the cu_unit vector of (x, y)

; cu_go: A = 0 x / 1 y cushion, X = the ball -> its v, u, w after the bounce,
; NEEDRN (renorm: the slide).  Keeps X.
.proc cu_go
    sta cuax
    stx cub
    jsr spin_u              ; U = the spin as it is (sliding: v - SLP s^)
    lda wnew                ; a new shot: nothing spins sideways but the cue as struck
    beq wn
    lda #0
    sta wnew
    ldy #NB*4-1
wc:
    sta cuw,y
    dey
    bpl wc
    lda wcue
    sta cuw
    lda wcue+1
    sta cuw+1
    lda tick16
    sta cuw+2
    lda tick16+1
    sta cuw+3
wn:
    lda cub                 ; w, the cloth's toll since it was set taken off
    asl @
    asl @
    sta cuy
    tay
    sec
    lda tick16
    sbc cuw+2,y
    sta mA
    lda tick16+1
    sbc cuw+3,y
    sta mA+1
    lda #<CU_DW
    sta mB
    lda #>CU_DW
    sta mB+1
    jsr mul16u              ; (ticks * CU_DW) >> 8
    ldy cuy
    ldx #K_W
    lda cuw,y
    sta cu_kv,x
    lda cuw+1,y
    sta cu_kv+1,x
    asl @
    lda #0
    sbc #0
    eor #$FF                ; (the sign byte: C = bit 15)
    sta cu_kv+2,x
    php
    bpl wp
    jsr cu_negx                ; |w|
wp:
    lda mP+3
    bne w0
    sec
    lda cu_kv,x
    sbc mP+1
    sta cu_kv,x
    lda cu_kv+1,x
    sbc mP+2
    sta cu_kv+1,x
    bcs ws
w0:
    lda #0
    sta cu_kv,x
    sta cu_kv+1,x
ws:
    plp
    bpl wd
    jsr cu_negx
wd:
    ldx cub                 ; v, u: Q12 -> Q9, the table's cu_frame (cu_ct)
    ldy #0
    lda VX0,x
    sta cuc
    lda VX1,x
    sta cuc+1
    lda VX2,x
    jsr cu_q9
    lda VY0,x
    sta cuc
    lda VY1,x
    sta cuc+1
    lda VY2,x
    jsr cu_q9
    lda UX0,x
    sta cuc
    lda UX1,x
    sta cuc+1
    lda UX2,x
    jsr cu_q9
    lda UY0,x
    sta cuc
    lda UY1,x
    sta cuc+1
    lda UY2,x
    jsr cu_q9
    jsr cu_frame               ; -> cu_kv: the cushion along x, into it along +y
    lda cu_kv+K_VY+2           ; not into it: a mirror only
    bmi mir
    ora cu_kv+K_VY+1
    ora cu_kv+K_VY
    beq mir
    jsr cu_fx
    jmp back
mir:
    ldx #K_VY
    jsr cu_negx
    ldx #K_UY
    jsr cu_negx
back:
    jsr cu_unframe             ; cu_kv -> cu_ct
    ldx cub                 ; Q9 -> Q12: v (fraction 0), u, renorm (2: off a cushion --
    lda #2                  ;   physics.asm rewind keeps the overlap's own normal then)
    sta NEEDRN,x
    lda #0
    sta VXF,x
    sta VYF,x
    ldy #0
    jsr cu_q12
    sta VX2,x
    lda cuc
    sta VX0,x
    lda cuc+1
    sta VX1,x
    jsr cu_q12
    sta VY2,x
    lda cuc
    sta VY0,x
    lda cuc+1
    sta VY1,x
    jsr cu_q12
    sta UX2,x
    lda cuc
    sta UX0,x
    lda cuc+1
    sta UX1,x
    jsr cu_q12
    sta UY2,x
    lda cuc
    sta UY0,x
    lda cuc+1
    sta UY1,x
    ldy cuy                 ; w, set now
    lda cu_kv+K_W
    sta cuw,y
    lda cu_kv+K_W+1
    sta cuw+1,y
    lda tick16
    sta cuw+2,y
    lda tick16+1
    sta cuw+3,y
    rts
.endp

; cu_q9: cuc, cuc+1, A = a Q12 24-bit value -> cu_ct,y (Q9, 16-bit: >> 3); Y += 2
.proc cu_q9
    lsr @                   ; (the top byte shifted in A)
    ror cuc+1
    ror cuc
    lsr @
    ror cuc+1
    ror cuc
    lsr @
    ror cuc+1
    ror cuc
    lda cuc
    sta cu_ct,y
    lda cuc+1
    sta cu_ct+1,y
    iny
    iny
    rts
.endp

; cu_q12: cu_ct,y (Q9) -> cuc, cuc+1, A = the Q12 24-bit value (<< 3, signed); Y += 2
.proc cu_q12
    lda cu_ct,y
    sta cuc
    lda cu_ct+1,y
    sta cuc+1
    asl @                   ; the sign byte, shifted in A
    lda #0
    sbc #0
    eor #$FF
    asl cuc
    rol cuc+1
    rol @
    asl cuc
    rol cuc+1
    rol @
    asl cuc
    rol cuc+1
    rol @
    iny
    iny
    rts
.endp

; cu_frame: cu_ct (vx, vy, ux, uy: 16-bit) -> cu_kv (24-bit), the cushion along x, the
; ball into it along +y.  A y cushion (cuax 1), sign s of vy: (s vx, s vy); an x
; one, s of vx: (-s vy, s vx) -- the same for u.  cuns = s (bit 7: negative)
.proc cu_frame
    lda cuax
    bne fy
    lda cu_ct+1                ; x: from (vy, vx, uy, ux)
    sta cuns
    ldx #K_UY               ; cu_kv (vx, vy, ux, uy) <- cu_ct (2, 0, 6, 4)
    ldy #4
    jsr cu_wide
    ldx #K_UX
    ldy #6
    jsr cu_wide
    ldx #K_VY
    ldy #0
    jsr cu_wide
    ldx #K_VX
    ldy #2
    jsr cu_wide
    bit cuns
    bmi n2
    ldx #K_VX               ; s > 0: the tangential ones flip
    jsr cu_negx
    ldx #K_UX
    jmp cu_negx
n2:
    ldx #K_VY               ; s < 0: the normal ones flip
    jsr cu_negx
    ldx #K_UY
    jmp cu_negx
fy:
    ldx #K_UY               ; y: as they are, all flipped when s < 0; a nose (2):
    ldy #6                  ;   as they are, then turned to its normal (cu_rot_in)
fl:
    jsr cu_wide
    dex
    dex
    dex
    dey
    dey
    bpl fl
    lda cuax
    lsr @
    bne rot
    lda cu_ct+3
    sta cuns
    bpl ok
    ldx #K_UY
fn:
    jsr cu_negx
    dex
    dex
    dex
    bpl fn
ok:
    rts
rot:
    jmp cu_rot              ; (cuprog.asm)
.endp

; cu_wide: cu_kv,x (24-bit) = cu_ct,y (16-bit, signed).  Keeps X, Y.
.proc cu_wide
    lda cu_ct,y
    sta cu_kv,x
    lda cu_ct+1,y
    sta cu_kv+1,x
    asl @
    lda #0
    sbc #0
    eor #$FF
    sta cu_kv+2,x
    rts
.endp

; cu_unframe: cu_kv -> cu_ct (16-bit), cu_frame undone
.proc cu_unframe
    lda cuax
    bne uy
    bit cuns                ; x: s > 0 (vx, vy) = (fy, -fx); s < 0 (-fy, fx)
    bmi m2
    ldx #K_VX
    jsr cu_negx
    ldx #K_UX
    jsr cu_negx
    jmp ux
m2:
    ldx #K_VY
    jsr cu_negx
    ldx #K_UY
    jsr cu_negx
ux:
    ldx #K_VY               ; cu_ct (vx, vy, ux, uy) <- cu_kv (vy, vx, uy, ux)
    ldy #0
    jsr cu_nar
    ldx #K_VX
    ldy #2
    jsr cu_nar
    ldx #K_UY
    ldy #4
    jsr cu_nar
    ldx #K_UX
    ldy #6
    jmp cu_nar
uy:
    lda cuax
    lsr @
    beq u1
    ldx #K_RC               ; a nose: turned back (cu_rot with -c), c as it was after
    jsr cu_negx
    jsr cu_rot
    ldx #K_RC
    jsr cu_negx
    jmp as
u1:
    bit cuns
    bpl as
    ldx #K_UY
un:
    jsr cu_negx
    dex
    dex
    dex
    bpl un
as:
    ldx #K_UY
    ldy #6
al:
    jsr cu_nar
    dex
    dex
    dex
    dey
    dey
    bpl al
    rts
.endp

; cu_nar: cu_ct,y = cu_kv,x (the low 16 bits).  Keeps X, Y.
.proc cu_nar
    lda cu_kv,x
    sta cu_ct,y
    lda cu_kv+1,x
    sta cu_ct+1,y
    rts
.endp

; cu_negx: cu_kv,x = -cu_kv,x (24-bit).  Keeps X, Y.
.proc cu_negx
    sec
    lda #0
    sbc cu_kv,x
    sta cu_kv,x
    lda #0
    sbc cu_kv+1,x
    sta cu_kv+1,x
    lda #0
    sbc cu_kv+2,x
    sta cu_kv+2,x
    rts
.endp

; (cu_run, the op-table interpreter: gone 2026-10-27 -- the programs are straight code, cuprog.asm)

; (cu_unit: src/cuunit.asm, in the main RAM since 2026-10-27 -- this bank ran full)

; cu_fx: cu_kv (Q9: vx, vy > 0 into the cushion, ux, uy, w) -> after the impact
.proc cu_fx
    ldx #K_VY               ; dp = vy / (cu_ct 4), at least 1
    lda cu_kv,x
    sta sA
    lda cu_kv+1,x
    sta sA+1
    lda cu_kv+2,x
    sta sA+2
    lda #<17876
    sta sB
    lda #>17876
    sta sB+1
    lda #0
    sta sB+2
    jsr smul3r
    lda sP
    ora sP+1
    bne d1
    inc sP
d1:
    lda sP
    sta cu_kv+K_DP
    lda sP+1
    sta cu_kv+K_DP+1
    lda #0
    sta cu_kv+K_DP+2
    jsr cu_wclr
    lda #16
    sta cun
cl:                         ; compression
    jsr cu_fstep               ; deriv, n = s + d dp
    lda cu_kv+K_N+K_VY+2       ; n vy <= 0: this step crosses it
    bmi cut0
    ora cu_kv+K_N+K_VY+1
    ora cu_kv+K_N+K_VY
    beq cut0
    clc                     ; work += dp (vy + vy') >> 2
    lda cu_kv+K_VY
    adc cu_kv+K_N+K_VY
    tay
    lda cu_kv+K_VY+1
    adc cu_kv+K_N+K_VY+1
    tax
    tya
    jsr cu_wdp
    jsr cu_wacc
    jsr cu_take
    dec cun
    bne cl
    beq rs              ; (always)
cut0:
    lda cu_kv+K_VY             ; h = dp * cu_frac(vy, vy - vy')
    sta cu_dn
    lda cu_kv+K_VY+1
    sta cu_dn+1
    sec
    lda cu_kv+K_VY
    sbc cu_kv+K_N+K_VY
    sta mB
    lda cu_kv+K_VY+1
    sbc cu_kv+K_N+K_VY+1
    sta mB+1
    lda #0
    sta cu_dn+2
    sta cu_dn+3
    sta mB+2
    jsr cu_frac
    lda cu_kv+K_VY             ; work += h vy >> 2
    ldx cu_kv+K_VY+1
    jsr cu_wh
    jsr cu_wacc
    jsr cu_sprg                ; n = s + d h (cuprog.asm)
    jsr cu_take
    lda #0
    sta cu_kv+K_VY
    sta cu_kv+K_VY+1
    sta cu_kv+K_VY+2
rs:
    ldx #3                  ; the rebound's work: ee^2 of it = w - w/32 - w/128
cr:
    lda cu_cwk,x
    sta cu_ctg,x
    sta cu_dn,x
    dex
    bpl cr
    ldy #5
    jsr cu_tsub
    ldy #2
    jsr cu_tsub
    jsr cu_wclr
    lda #24
    sta cun
rl:                         ; restitution
    jsr cu_fstep
    sec                     ; dw = dp (-vy - vy') >> 2
    lda #0
    sbc cu_kv+K_VY
    sta cut
    lda #0
    sbc cu_kv+K_VY+1
    sta cut+1
    sec
    lda cut
    sbc cu_kv+K_N+K_VY
    tay
    lda cut+1
    sbc cu_kv+K_N+K_VY+1
    tax
    tya
    jsr cu_wdp
    clc                     ; work + dw >= target: the last step, partial
    ldx #0
    ldy #4
ad:
    lda cu_cwk,x
    adc cu_cdw,x
    sta cu_dn,x
    inx
    dey
    bne ad
    ldx #3
c2:
    lda cu_dn,x
    cmp cu_ctg,x
    bcc more
    bne last
    dex
    bpl c2
last:
    sec                     ; h = dp * cu_frac(target - work, dw)
    ldx #0
    ldy #4
sbk:
    lda cu_ctg,x
    sbc cu_cwk,x
    sta cu_dn,x
    inx
    dey
    bne sbk
    lda cu_cdw
    sta mB
    lda cu_cdw+1
    sta mB+1
    lda cu_cdw+2
    sta mB+2
    jsr cu_frac
    jsr cu_sprg                ; n = s + d h (cuprog.asm)
    jmp cu_take
more:
    jsr cu_wacc
    jsr cu_take
    dec cun
    bne rl
    rts
.endp

; cu_fstep: the derivative at the state, n = s + d dp (n = s + d h: cu_sprg itself)
.proc cu_fstep
    jsr cu_dprg                ; (cuprog.asm)
    ldx #2
c:
    lda cu_kv+K_DP,x
    sta cu_kv+K_H,x
    dex
    bpl c
    jmp cu_sprg                ; n = s + d h (cuprog.asm)
.endp

; cu_take: s = n
.proc cu_take
    ldx #14
l:
    lda cu_kv+K_N,x
    sta cu_kv,x
    dex
    bpl l
    rts
.endp

; cu_frac: h = dp * round(cu_dn 256 / mB) >> 8 (cu_dn, 4 bytes; mB 3), the fraction at
; most 255 (cu_dn >= mB: 255) -- divr's
.proc cu_frac
    lda cu_dn+3             ; cu_dn >= mB: 255 (mB's 4th byte is 0)
    bne mx
    ldx #2
cm:
    lda cu_dn,x
    cmp mB,x
    bcc go
    bne mx
    dex
    bpl cm
mx:
    lda #255
    bne hs                  ; (always)
go:
    lda #0                  ; mA = cu_dn << 8 (48-bit)
    sta mA
    sta mA+5
    ldx #3
c:
    lda cu_dn,x
    sta mA+1,x
    dex
    bpl c
    jsr divr
    lda mQ+1                ; 256: 255
    beq ok
    lda #255
    bne hs
ok:
    lda mQ
hs:
    sta mB                  ; h = (dp * f) >> 8
    lda #0
    sta mB+1
    lda cu_kv+K_DP
    sta mA
    lda cu_kv+K_DP+1
    sta mA+1
    jsr mul16u
    lda mP+1
    sta cu_kv+K_H
    lda mP+2
    sta cu_kv+K_H+1
    lda #0
    sta cu_kv+K_H+2
    rts
.endp

; cu_wdp / cu_wh: A, X = a 16-bit factor -> cu_cdw = (dp / h * it) >> 2
.proc cu_wdp
    ldy #K_DP
    dta $2C                 ; (bit abs: skips the ldy)
.endp
.proc cu_wh
    ldy #K_H
    sta mB
    stx mB+1
    lda cu_kv,y
    sta mA
    lda cu_kv+1,y
    sta mA+1
    jsr mul16u
    lda mP+3                ; cu_cdw = mP >> 2: shifted in zero page, the top byte in A
    lsr @
    ror mP+2
    ror mP+1
    ror mP
    lsr @
    ror mP+2
    ror mP+1
    ror mP
    sta cu_cdw+3
    lda mP+2
    sta cu_cdw+2
    lda mP+1
    sta cu_cdw+1
    lda mP
    sta cu_cdw
    rts
.endp
    ert cu_wh-cu_wdp<>3

; cu_wacc: cu_cwk += cu_cdw; cu_wclr: cu_cwk = 0
.proc cu_wacc
    clc
    ldx #0
    ldy #4
l:
    lda cu_cwk,x
    adc cu_cdw,x
    sta cu_cwk,x
    inx
    dey
    bne l
    rts
.endp
.proc cu_wclr
    lda #0
    ldx #3
l:
    sta cu_cwk,x
    dex
    bpl l
    rts
.endp

; cu_tsub: cu_dn >>= Y, cu_ctg -= cu_dn (32-bit)
.proc cu_tsub
s:
    lsr cu_dn+3
    ror cu_dn+2
    ror cu_dn+1
    ror cu_dn
    dey
    bne s
    sec
    ldx #0
    ldy #4
l:
    lda cu_ctg,x
    sbc cu_dn,x
    sta cu_ctg,x
    inx
    dey
    bne l
    rts
.endp

; the derivative: Mathavan's eqs 12-14 per cu_unit of normal impulse
; (the programs cu_dprg, cu_sprg, cu_rot: cuprog.asm, the main RAM)

; 1 / sqrt(q) for q = ax^2 + ay^2 (ax, ay < 128, max >= 64), by q >> 6 = 64..504:
; round(2^13 / sqrt((i + 0.5) 64)), at most 255 (asm_bench.py FX_TINV)
cu_tinv
    dta 128, 127, 126, 125, 124, 123, 122, 121, 120, 119, 119, 118, 117, 116, 116, 115
    dta 114, 113, 113, 112, 111, 111, 110, 109, 109, 108, 108, 107, 106, 106, 105, 105
    dta 104, 104, 103, 103, 102, 102, 101, 101, 100, 100, 99, 99, 98, 98, 97, 97
    dta 97, 96, 96, 95, 95, 94, 94, 94, 93, 93, 93, 92, 92, 91, 91, 91
    dta 90, 90, 90, 89, 89, 89, 88, 88, 88, 87, 87, 87, 86, 86, 86, 85
    dta 85, 85, 85, 84, 84, 84, 83, 83, 83, 83, 82, 82, 82, 82, 81, 81
    dta 81, 81, 80, 80, 80, 80, 79, 79, 79, 79, 78, 78, 78, 78, 78, 77
    dta 77, 77, 77, 76, 76, 76, 76, 76, 75, 75, 75, 75, 75, 74, 74, 74
    dta 74, 74, 73, 73, 73, 73, 73, 72, 72, 72, 72, 72, 72, 71, 71, 71
    dta 71, 71, 71, 70, 70, 70, 70, 70, 70, 69, 69, 69, 69, 69, 69, 68
    dta 68, 68, 68, 68, 68, 68, 67, 67, 67, 67, 67, 67, 67, 66, 66, 66
    dta 66, 66, 66, 66, 65, 65, 65, 65, 65, 65, 65, 65, 64, 64, 64, 64
    dta 64, 64, 64, 64, 63, 63, 63, 63, 63, 63, 63, 63, 62, 62, 62, 62
    dta 62, 62, 62, 62, 62, 61, 61, 61, 61, 61, 61, 61, 61, 61, 60, 60
    dta 60, 60, 60, 60, 60, 60, 60, 60, 59, 59, 59, 59, 59, 59, 59, 59
    dta 59, 59, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 57, 57, 57
    dta 57, 57, 57, 57, 57, 57, 57, 57, 56, 56, 56, 56, 56, 56, 56, 56
    dta 56, 56, 56, 56, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55
    dta 55, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 53, 53
    dta 53, 53, 53, 53, 53, 53, 53, 53, 53, 53, 53, 53, 52, 52, 52, 52
    dta 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 51, 51, 51, 51, 51
    dta 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 50, 50, 50, 50, 50
    dta 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 49, 49, 49, 49
    dta 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 48, 48
    dta 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48
    dta 48, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47
    dta 47, 47, 47, 47, 47, 46, 46, 46, 46, 46, 46, 46, 46, 46, 46, 46
    dta 46, 46, 46, 46, 46, 46, 46, 46, 46

; its cells -- [2026-10-27 6502-cycles-layout/SKILL.md: page-align hot tables] at a page's
; start: every lda cu_kv,x / cu_kv,y (cu_run, cumul, cu_unit) was +1 past $2A00 (from K_T1 on)
    :[[$100-[*&$FF]]&$FF] dta 0
cu_kv      dta a(0), 0, a(0), 0, a(0), 0, a(0), 0, a(0), 0       ; the state
        dta a(0), 0, a(0), 0, a(0), 0, a(0), 0, a(0), 0       ; n
        dta a(0), 0, a(0), 0, a(0), 0, a(0), 0, a(0), 0       ; d
        dta a(60065), 0, a(26214), 0, a(9175), 0, a(13894), 0 ; cu_ct, st, mu_w, mu_s (Q16)
        dta a(163840&$FFFF), 163840>>16, a(0), 0              ; 5/2, 0
        :K_RY+3-K_T1 dta 0                                     ; t1 .. dp, the nose's
    ert >cu_kv <> >[cu_kv+K_RY+2]     ; (one page)
    ert *-cu_kv<>K_RY+3
cuax    dta 0
cub     dta 0
cuy     dta 0
cuns    dta 0
cud     dta 0
cuyy    dta 0
cut     dta 0, 0
cutx    dta 0
cun     dta 0
cuc     dta 0, 0
cu_ct      dta a(0), a(0), a(0), a(0)          ; the table's cu_frame: vx, vy, ux, uy (Q9)
cu_ua      dta 0, 0, 0, 0, 0, 0
cu_usg     dta 0, 0
cu_cwk     dta 0, 0, 0, 0                      ; the work so far, the rebound's target
cu_ctg     dta 0, 0, 0, 0
cu_cdw     dta 0, 0, 0, 0
cu_dn      dta 0, 0, 0, 0

; pc_chk: the pocket camera (TV's) for a hard attempt: the ball the cue ball hit
; first (fcon) heads at a pocket (its line within 64 mm of the centre), more than
; 1.5 m off, or more than 0.4 m off on a cut of 40 deg or more (its way against
; the aim; past 86 deg it came back off a cushion: no pot) -> C = 1, the camera
; set: the pivot PC_BACK behind the pocket (bx, by) on its axis, looking back
; along it into the table (rang), the pocket in front; pcam = 1.
; Else C = 0.
.proc pc_chk
    ldx fcon
    jmi no
    lda AWK,x
    jeq no
    lda BON,x
    jeq no
    stx pcb
    ldy #5*12
pk:
    sty pcy
    ldx pcb                 ; d = P - B (Q3, 16-bit signed: the Q4 difference is 17-bit,
    sec                     ;   its sign = no carry -- the table's 3569 mm pass 2048 mm Q4)
    lda pockets+1,y
    sbc X1,x
    sta pcd
    lda pockets+2,y
    sbc X2,x
    ror @
    eor #$80
    sta pcd+1
    ror pcd
    sec
    lda pockets+4,y
    sbc Y1,x
    sta pcd+2
    lda pockets+5,y
    sbc Y2,x
    ror @
    eor #$80
    sta pcd+3
    ror pcd+2
    ldy #0                  ; dot (pcp), |cross| (pcq) of d with v
    jsr pdc
    lda pcp+1               ; dot > 0: towards it
    jmi nx
    ora pcp
    jeq nx
    ldx pcb                 ; |cross| < |v| >> 7: the line within 64 mm of the centre
    lda SP1,x               ;   (|cross| = |d| |v| sin / 2 in mm, mm/tick)
    asl @
    sta pct
    lda SP2,x
    rol @
    sta pct+1
    lda pcq
    cmp pct
    lda pcq+1
    sbc pct+1
    jcs nx
    jsr pangle              ; pcq = t, the way's angle
    sec                     ; cut = t - aimang (mod 1024) -> pct
    lda pcq
    sbc aimang
    sta pct
    lda pcq+1
    sbc aimang+1
    and #3
    sta pct+1
    cmp #2                  ; 512..1023: the other side, 1024 - cut = (cut ^ $3FF) + 1
    bcc c2
    lda pct
    eor #$FF
    adc #0                  ; (C = 1: the + 1)
    sta pct
    lda pct+1
    eor #3
    adc #0
    sta pct+1
c2:
    lda pct                 ; > 86 deg off the aim: back off a cushion, no pot
    cmp #245
    lda pct+1
    sbc #0
    jcs nx
    ldx #0                  ; |dx| + |dy| (Q3) -> pcq
    jsr pabs
    sta pcq
    stx pcq+1
    ldx #2
    jsr pabs
    clc
    adc pcq
    sta pcq
    txa
    adc pcq+1
    sta pcq+1
    bcs far
    lda pcq                 ; > 1.5 m: a long pot
    cmp #<[1500*8]
    lda pcq+1
    sbc #>[1500*8]
    bcs far
    lda pcq                 ; < 0.4 m: no room for the camera
    cmp #<[400*8]
    lda pcq+1
    sbc #>[400*8]
    bcc nx
    lda pct                 ; >= 114 (40 deg): a hard cut
    cmp #114
    lda pct+1
    sbc #0
    bcs far
nx:
    lda pcy                 ; the next pocket
    sec
    sbc #12
    tay
    jcs pk
no:
    clc
    rts
far:
    lda #1
    sta pcam
    lda pcy                 ; t = the pocket's axis (a TV pocket camera: the jaws either
    lsr @                   ;   side, the drop between them), 16 x pcax[pocket]
    lsr @
    tax
    lda pcax,x
    sta pcq
    lda #0
    ldx #4
t4:
    asl pcq
    rol @
    dex
    bne t4
    sta pcq+1
    clc                     ; i = (t + 8) >> 4 & 63: the way in 64 steps
    lda pcq
    adc #8
    sta pct
    lda pcq+1
    adc #0
    ldx #4
sh:
    lsr @
    ror pct
    dex
    bne sh
    lda pct
    and #63
    asl @
    tax                     ; X = 2 i
    ldy pcy                 ; the pivot: P + PC_BACK (cos, sin) -- behind the pocket,
    clc                     ;   the pocket in front of it (Q4 -> Q12: bx+1, bx+2)
    lda pockets+1,y
    adc pcbk,x
    sta bx+1
    lda pockets+2,y
    adc pcbk+1,x
    sta bx+2
    lda pcbk+1,x            ; below 0 (behind a pocket at x 0: a negative step, no
    and #$80                ;   carry) -> $00, else $80: project_balls' sign is not
    bcc n1                  ;   the borrow then (cam_rest sets $80 back)
    lda #0
n1:
    eor #$80
    sta project_balls.ex+1
    txa                     ; sin = cos(i - 16)
    sec
    sbc #32
    and #127
    tax
    clc
    lda pockets+4,y
    adc pcbk,x
    sta by+1
    lda pockets+5,y
    adc pcbk+1,x
    sta by+2
    lda pcbk+1,x            ; (as x)
    and #$80
    bcc n2
    lda #0
n2:
    eor #$80
    sta project_balls.ey+1
    lda #0
    sta bx
    sta by
    sec                     ; rang = 512 - t: from behind the pocket back at the ball
    lda #0
    sbc pcq
    sta rang
    lda #2
    sbc pcq+1
    and #3
    sta rang+1
    sec
    rts
.endp

; pdc: Y = 0 (d) -> pcp = dot (x vx + y vy), pcq = |cross| (x vy - y vx), >> 16
.proc pdc
    sty pco
    ldx #0
    jsr pmul                ; x vx
    sta pcp
    stx pcp+1
    ldy pco
    iny
    iny
    ldx #$80
    jsr pmul                ; y vy
    clc
    adc pcp
    sta pcp
    txa
    adc pcp+1
    sta pcp+1
    ldy pco
    ldx #$80
    jsr pmul                ; x vy
    sta pcq
    stx pcq+1
    ldy pco
    iny
    iny
    ldx #0
    jsr pmul                ; y vx
    sec                     ; cross = x vy - y vx: (x vy) + ~(y vx) + 1
    eor #$FF
    adc pcq
    sta pcq
    txa
    eor #$FF
    adc pcq+1
    sta pcq+1
    bpl r
    sec
    lda #0
    sbc pcq
    sta pcq
    lda #0
    sbc pcq+1
    sta pcq+1
r:
    rts
.endp

; pmul: Y = 0 dx / 2 dy, X = 0 vx / $80 vy (VY0 = VX0 + $80) of ball pcb ->
; A:X = (d * v) >> 16 (signed)
.proc pmul
    lda pcd,y
    sta sA
    lda pcd+1,y
    sta sA+1
    asl @
    lda #0
    sbc #0
    eor #$FF
    sta sA+2
    txa
    clc
    adc pcb
    tax
    lda VX0,x
    sta sB
    lda VX1,x
    sta sB+1
    lda VX2,x
    sta sB+2
    jsr smul3r
    lda sP
    ldx sP+1
    rts
.endp
    ert VY0<>VX0+$80 || VY1<>VX1+$80 || VY2<>VX2+$80

; pabs: X = 0 dx / 2 dy -> A:X = |d|
.proc pabs
    lda pcd+1,x
    bpl p
    sec
    lda #0
    sbc pcd,x
    pha
    lda #0
    sbc pcd+1,x
    tax
    pla
    rts
p:
    lda pcd,x
    pha
    lda pcd+1,x
    tax
    pla
    rts
.endp

; pangle: pcq = t = atan2(dy, dx) in 1024 a turn: the octant, then atan(min / max)
; from a 33-entry table
.proc pangle
    ldx #0
    jsr pabs
    sta pax
    stx pax+1
    ldx #2
    jsr pabs
    sta pay
    stx pay+1
sh:
    lda pax+1               ; both < 2048 (min * 128 stays 16-bit)
    ora pay+1
    cmp #2
    bcc dv
    lsr pax+1
    ror pax
    lsr pay+1
    ror pay
    jmp sh
dv:
    lda pax                 ; |dy| > |dx|?
    cmp pay
    lda pax+1
    sbc pay+1
    lda #0
    rol @
    eor #1
    sta pcs                 ; 1: |dy| larger
    beq m0
    lda pax                 ; min = |dx|, max = |dy|
    sta pcq
    lda pax+1
    sta pcq+1
    lda pay
    sta pct
    lda pay+1
    sta pct+1
    jmp d6
m0:
    lda pay
    sta pcq
    lda pay+1
    sta pcq+1
    lda pax
    sta pct
    lda pax+1
    sta pct+1
d6:
    lda pct                 ; (max 0: the way along x)
    ora pct+1
    beq z
    lda #2                  ; r = min 128 / max: 7 bits (the 1 shifts out after them)
    sta pcr
l:
    asl pcq
    rol pcq+1
    sec
    lda pcq
    sbc pct
    tax
    lda pcq+1
    sbc pct+1
    bcc b0
    sta pcq+1
    stx pcq
b0:
    rol pcr
    bcc l
    lda pcr                 ; / 4: 0..32
    lsr @
    lsr @
    tax
    lda patan,x             ; 0..128 (45 deg)
    jmp o1
z:
    lda #0
o1:
    sta pcq                 ; t (octant 0)
    lda #0
    sta pcq+1
    lda pcs                 ; |dy| > |dx|: 256 - t
    beq o2
    sec
    lda #0
    sbc pcq
    sta pcq
    lda #1
    sbc #0
    sta pcq+1
o2:
    lda pcd+1               ; dx < 0: 512 - t
    bpl o3
    sec
    lda #0
    sbc pcq
    sta pcq
    lda #2
    sbc pcq+1
    sta pcq+1
o3:
    lda pcd+3               ; dy < 0: 1024 - t
    bpl o4
    sec
    lda #0
    sbc pcq
    sta pcq
    lda #4
    sbc pcq+1
    sta pcq+1
o4:
    rts
patan dta 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 49, 54, 58, 63, 67, 71, 76, 80, 84, 87, 91, 95, 98, 102, 105, 108, 111, 114, 117, 120, 123, 125, 128
.endp

; pcbk: PC_BACK = 150 mm along the way, Q4 16-bit, 64 steps a turn: 150 * 16 cos(2 pi i / 64)
; (tools: python, the numbers below)
pcbk
    dta a(2400), a(2388), a(2354), a(2297), a(2217), a(2117), a(1996), a(1855)
    dta a(1697), a(1523), a(1333), a(1131), a(918), a(697), a(468), a(235)
    dta a(0), a(-235), a(-468), a(-697), a(-918), a(-1131), a(-1333), a(-1523)
    dta a(-1697), a(-1855), a(-1996), a(-2117), a(-2217), a(-2297), a(-2354), a(-2388)
    dta a(-2400), a(-2388), a(-2354), a(-2297), a(-2217), a(-2117), a(-1996), a(-1855)
    dta a(-1697), a(-1523), a(-1333), a(-1131), a(-918), a(-697), a(-468), a(-235)
    dta a(0), a(235), a(468), a(697), a(918), a(1131), a(1333), a(1523)
    dta a(1697), a(1855), a(1996), a(2117), a(2217), a(2297), a(2354), a(2388)

; pcax: per pocket (pockets' order, by pcy / 4) its axis out of the table, t >> 4:
; (0, 0) 225 deg, (L, 0) 315, (0, W) 135, (L, W) 45, (L/2, 0) 270, (L/2, W) 90
pcax    dta 40, 0, 0, 56, 0, 0, 24, 0, 0, 8, 0, 0, 48, 0, 0, 16

pcb     dta 0               ; pc_chk's cells
pcy     dta 0
pcd     dta 0, 0, 0, 0      ; d = P - B: dx, dy (Q3)
pco     dta 0               ; pdc's vector
pcp     dta 0, 0
pcq     dta 0, 0
pcr     dta 0, 0
pct     dta 0, 0
pcs     dta 0
pax     dta 0, 0
pay     dta 0, 0
; occl: X = a ball (gstore, before clip_blit; occw maps this bank) -- the balls
; are drawn after the table, so a cushion nearer the eye hid nothing.  The eye
; past a cushion's nose line by D, H above the bed, the ball's centre dc < 48 mm
; in front of it: the sight line over the nose (h) meets the ball's plane at
; L = h - (H - h) dc / D; the rows below L hidden (the rectangle kept to
; 2s - s L / R, s the sprite's radius).  A high eye hides nothing.  Keeps X.
.proc occl
    stx ocb
    ldy #0                  ; u: the cushions x 0 / x L
    jsr oax
    ldy #3                  ; v: y 0 / y W
    jsr oax
    ldx ocb
    rts
; oax: Y = 0 (u: X1 / X2, L) / 3 (v: Y1 / Y2, W)
oax:
    lda eum,y               ; |the eye| past the half length / width (x 4: Q2)?
    cmp oal,y
    lda eum+1,y
    sbc oah,y
    jcc r
    lda ocb                  ; the ball's cells: x, or y ($60 on)
    cpy #0
    beq a0
    adc #$60-1              ; (C = 1: cpy)
a0:
    tax
    sec
    lda eum+2,y             ; past the 0 cushion: d = the coordinate; past the far
    bpl fr                  ;   one: d = the length - it (Q4)
    lda X1,x
    sta ocd
    lda X2,x
    jmp dd
fr:
    lda olq,y
    sbc X1,x
    sta ocd
    lda olq+1,y
    sbc X2,x
dd:
    cmp #3                  ; dc < 48 mm (Q4 hi 3): near
    jcs r
    ldx #4                  ; -> mm (dc / 16: 0..47)
sh:
    lsr @
    ror ocd
    dex
    bne sh
    sec                     ; D = the eye past the nose line (Q2, >= 0: oax's test)
    lda eum,y
    sbc oal,y
    sta ocp
    lda eum+1,y
    sbc oah,y
    sta ocp+1
    lda view_setup.exh+1    ; the zoom by its eye's distance -> H - h (mm)
    ldy #NZOOM-1
zl:
    cmp zoom_exm_hi,y
    beq zf
    dey
    bne zl
zf:
    lda ochl,y              ; n = (H - h) dc 4 (Q2 as D)
    ldx ocd
    jsr fmulu
    lda fmpl
    sta ocn
    lda fmph
    sta ocn+1
    lda ochh,y
    jsr fmulu
    clc
    lda fmpl
    adc ocn+1
    sta ocn+1
    lda fmph
    adc #0
    asl ocn
    rol ocn+1
    rol @
    asl ocn
    rol ocn+1
    rol @
    sta ocn+2
    ldx #OCH                ; the sight line over the nose (height h) at the ball:
ql:                         ;   L = h - n / D mm above the bed, X counts it down
    sec
    lda ocn
    sbc ocp
    sta ocn
    lda ocn+1
    sbc ocp+1
    sta ocn+1
    lda ocn+2
    sbc #0
    sta ocn+2
    bcc qd
    dex
    bne ql
    rts                     ; L <= 0: the nose hides nothing of it
qd:
    txa                     ; keep = 2 s - s L / R rows (R 26: L 5 s >> 7), s the
    asl @                   ;   sprite's radius
    asl @
    stx oct
    adc oct                 ; (C = 0: L <= 36)
    ldx dsz
    jsr fmulu               ; L 5 2s
    lda fmph                ; >> 8: s L / 25.6
    sta oct
    sec
    lda dsz
    sbc oct
    bcs k0
    lda #0
k0:
    cmp bsh
    bcs r
    sta bsh
r:
    rts
.endp
    ert Y1<>X1+$60 || Y2<>X2+$60 || evm<>eum+3 || eus<>eum+2 || evs<>evm+2
oal     dta <7138, 0, 0, <3556          ; (u, v at 0, 3) half the length / width, x 4
oah     dta >7138, 0, 0, >3556
olq     dta <[3569*16], >[3569*16], 0, <[1778*16], >[1778*16]   ; the length / width, Q4
; H - h per zoom (rot_ref.py: H = the eye's distance tan(pitch): 3002, 946, 250,
; 4295 mm; h = 36 mm, the nose over the bed)
OCH     = 36
ochl    dta <2966, <910, <214, <4259
ochh    dta >2966, >910, >214, >4259
ocb      dta 0
ocd      dta 0
oct      dta 0
ocp      dta 0, 0            ; D (Q2)
ocn      dta 0, 0, 0         ; n

    ert *>$3000
    ini vram_next
