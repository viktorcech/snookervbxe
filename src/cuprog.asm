; cuprog.asm -- the cushion model's programs (cushion.asm cu_dprg, cu_sprg, cu_rot) as straight
; code: the same operations in the same order as the op table was, so the same numbers.
; [2026-10-27 6502-cycles-layout/SKILL.md: unroll a loop whose body is smaller than its
;  counting -- cu_run's dispatch cost more than an add; the cells by absolute address]
; In the main RAM (the bank is full); runs while the cushion bank is mapped at $2000.

.macro KMUL              ; :1 = :2 * :3 (cumul: :2 | $80 reuses mA)
    ldx #:2
    ldy #:3
    jsr cumul
    lda sP
    sta cu_kv+:1
    lda sP+1
    sta cu_kv+:1+1
    lda sP+2
    sta cu_kv+:1+2
.endm
.macro KADD              ; :1 = :2 + :3 (byte by byte: :1 may be :2 or :3)
    clc
    lda cu_kv+:2
    adc cu_kv+:3
    sta cu_kv+:1
    lda cu_kv+:2+1
    adc cu_kv+:3+1
    sta cu_kv+:1+1
    lda cu_kv+:2+2
    adc cu_kv+:3+2
    sta cu_kv+:1+2
.endm
.macro KSUB              ; :1 = :2 - :3
    sec
    lda cu_kv+:2
    sbc cu_kv+:3
    sta cu_kv+:1
    lda cu_kv+:2+1
    sbc cu_kv+:3+1
    sta cu_kv+:1+1
    lda cu_kv+:2+2
    sbc cu_kv+:3+2
    sta cu_kv+:1+2
.endm
.macro KUNIT             ; :1, :1+3 = the unit vector of (:2, :3)
    lda #:1
    sta cud
    lda #:3
    sta cuyy
    tay
    ldx #:2
    jsr cu_unit
.endm
.macro KMULP             ; sP = :1 * :2 (the product only waits for the next op: no cell)
    ldx #:1
    ldy #:2
    jsr cumul
.endm
.macro KADDP             ; :1 = :2 + sP
    clc
    lda cu_kv+:2
    adc sP
    sta cu_kv+:1
    lda cu_kv+:2+1
    adc sP+1
    sta cu_kv+:1+1
    lda cu_kv+:2+2
    adc sP+2
    sta cu_kv+:1+2
.endm
.macro KSUBP             ; :1 = :2 - sP
    sec
    lda cu_kv+:2
    sbc sP
    sta cu_kv+:1
    lda cu_kv+:2+1
    sbc sP+1
    sta cu_kv+:1+1
    lda cu_kv+:2+2
    sbc sP+2
    sta cu_kv+:1+2
.endm
.macro KPSUB             ; :1 = sP - :2
    sec
    lda sP
    sbc cu_kv+:2
    sta cu_kv+:1
    lda sP+1
    sbc cu_kv+:2+1
    sta cu_kv+:1+1
    lda sP+2
    sbc cu_kv+:2+2
    sta cu_kv+:1+2
.endm
.macro KNEGP             ; :1 = 0 - sP
    sec
    lda #0
    sbc sP
    sta cu_kv+:1
    lda #0
    sbc sP+1
    sta cu_kv+:1+1
    lda #0
    sbc sP+2
    sta cu_kv+:1+2
.endm
.macro KNEG              ; :1 = 0 - :2 (a literal 0, not the K_ZERO cell)
    sec
    lda #0
    sbc cu_kv+:2
    sta cu_kv+:1
    lda #0
    sbc cu_kv+:2+1
    sta cu_kv+:1+1
    lda #0
    sbc cu_kv+:2+2
    sta cu_kv+:1+2
.endm

.proc cu_dprg
; [2026-10-27 6502-loops-tables-smc/SKILL.md: SMC stores of a target that rarely changes] the
;  table's operations, reordered where independent and each product's factors swapped (exact:
;  the same numbers) so one constant multiplies in a row -- | $80: mA kept (cumul, mul48r)
; [2026-10-27 6502-idioms/SKILL.md: no RAM cell for a value that only waits; a literal 0]
    KMULP K_ST, K_UX                    ; x = vx + ux st - w ct
    KADDP K_XI, K_VX
    KMULP K_ST|$80, K_VY                ; y' = -vy st - uy
    KNEGP K_YI
    KSUB K_YI, K_YI, K_UY
    KMULP K_CT, K_W
    KSUBP K_XI, K_XI
    KUNIT K_CI, K_XI, K_YI
    KSUB K_XC, K_VX, K_UX               ; at the cloth: v - u
    KSUB K_YC, K_VY, K_UY
    KUNIT K_CC, K_XC, K_YC
    KMUL K_A, K_MUW, K_CI               ; a = mu_w cI, b = mu_w sI
    KMUL K_B, K_MUW|$80, K_SI
    KMULP K_CT, K_B                     ; k = st + b ct
    KADDP K_K, K_ST
    KMUL K_T1, K_MUS, K_CC              ; m1 = mu_s cC k, m2 = mu_s sC k
    KMUL K_T2, K_MUS|$80, K_SC
    KMUL K_M1, K_K, K_T1
    KMUL K_M2, K_K|$80, K_T2
    KADD K_T1, K_A, K_M1                ; dvx = -(a + m1)
    KNEG K_D, K_T1
    KMULP K_ST, K_B                     ; dvy = st b - ct - m2
    KPSUB K_T1, K_CT
    KSUB K_D+3, K_T1, K_M2
    KMULP K_ST|$80, K_A                 ; dux = -5/2 (a st - m1)
    KPSUB K_T1, K_M1
    KMUL K_T2, K_CT, K_A                ;   (a ct for dw, ahead: the 5/2 three in a row)
    KMULP K_K25, K_T1
    KNEGP K_D+6
    KADD K_T1, K_B, K_M2                ; duy = 5/2 (b + m2)
    KMUL K_D+9, K_K25|$80, K_T1
    KMUL K_D+12, K_K25|$80, K_T2        ; dw = 5/2 a ct
    rts
.endp

.proc cu_sprg
    KMULP K_H, K_D
    KADDP K_N, K_VX
    KMULP K_H|$80, K_D+3
    KADDP K_N+3, K_VY
    KMULP K_H|$80, K_D+6
    KADDP K_N+6, K_UX
    KMULP K_H|$80, K_D+9
    KADDP K_N+9, K_UY
    KMULP K_H|$80, K_D+12
    KADDP K_N+12, K_W
    rts
.endp

.proc cu_rot                            ; v' = (vx s - vy c, vx c + vy s), u' the same
    KMUL K_T1, K_VX, K_RS
    KMUL K_XI, K_VX|$80, K_RC
    KMULP K_VY, K_RC
    KSUBP K_VX, K_T1
    KMULP K_VY|$80, K_RS
    KADDP K_VY, K_XI
    KMUL K_T1, K_UX, K_RS
    KMUL K_XI, K_UX|$80, K_RC
    KMULP K_UY, K_RC
    KSUBP K_UX, K_T1
    KMULP K_UY|$80, K_RS
    KADDP K_UY, K_XI
    rts
.endp
