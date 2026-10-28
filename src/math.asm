; math.asm -- fixed-point math primitives.
; mul48 = quarter-square schoolbook (tables at $8000, see main.asm),
; div24 = 24-iteration divide, isqrt48 with leading-zero pre-skip.
; All bit-exact vs the references in sim/_ref_mathopt.py.

; ==========================================================================
; MATH
; ==========================================================================
; divr: mQ = round(mA / mB)  (round-to-nearest, ties up, mB > 0).  Wraps div24.
; divpr16: mQ = round(mP / mB) for a 16-bit divisor (mB+2 = 0) and a 24-bit quotient
; (mP < mB << 24: mP+5 = 0, mP+3..4 < mB) -- divr's result, bit for bit.  The remainder
; is 17 bits (its high byte in A, the 17th in C); the quotient bits shift into mP as the
; dividend leaves it.  Clobbers mP, mrem, X, Y.
; [2026-10-27 6502-idioms/SKILL.md: compute in A, the remainder's high byte lives in A;
;  no copy into mA (set_mA_mP) -- the reader reads the source]
.proc divpr16
    lda mP+3
    sta mrem
    lda mP+4
    ldx #24
    clc                 ; the bit below the first dividend bit
lp:
    rol mP
    rol mP+1
    rol mP+2
    rol mrem
    rol @
    bcs ge              ; bit 16 out -> rem >= 2^16 > mB
    cmp mB+1
    bcc lt
    bne ge
    ldy mrem
    cpy mB
    bcc lt
ge:                     ; every way in has C = 1
    tay
    lda mrem            ; rem -= mB
    sbc mB
    sta mrem
    tya
    sbc mB+1
    sec                 ; quotient bit 1 (a rem >= 2^16 path leaves a borrow)
lt:
    dex
    bne lp
    rol mP              ; the last quotient bit
    rol mP+1
    rol mP+2
    asl mrem            ; round: 2*rem >= mB -> +1  (rem < mB < 2^16)
    rol @
    bcs up
    cmp mB+1
    bcc done
    bne up
    lda mrem
    cmp mB
    bcc done
up:
    inc mP
    bne done
    inc mP+1
    bne done
    inc mP+2
done:
    lda mP
    sta mQ
    lda mP+1
    sta mQ+1
    lda mP+2
    sta mQ+2
    rts
.endp

.proc divr
    jsr div24           ; mQ = floor(mA/mB), mrem(4) = remainder (< mB < 2^24)
    asl mrem            ; 2*remainder (25 bits max)
    rol mrem+1
    rol mrem+2
    rol mrem+3
    lda mrem+3          ; bit 24 set -> 2*rem > any 24-bit mB -> round up
    bne up
    lda mrem+2
    cmp mB+2
    bcc no
    bne up
    lda mrem+1
    cmp mB+1
    bcc no
    bne up
    lda mrem
    cmp mB
    bcc no
up:
    inc mQ
    bne no
    inc mQ+1
    bne no
    inc mQ+2
no:
    rts
.endp

; SMUL_PRE: |sA| -> mA, |sB| -> mB, csgn = sign(sA) xor sign(sB).
; (macro: MADS makes every label inside local to the expansion)
.macro SMUL_PRE
    ldx #0
    lda sA+2
    bmi an
    lda sA
    sta mA
    lda sA+1
    sta mA+1
    lda sA+2
    sta mA+2
    bpl ad              ; (always: the bmi above not taken)
an
    inx
    sec
    lda #0
    sbc sA
    sta mA
    lda #0
    sbc sA+1
    sta mA+1
    lda #0
    sbc sA+2
    sta mA+2
ad
    lda sB+2
    bmi bn
    lda sB
    sta mB
    lda sB+1
    sta mB+1
    lda sB+2
    sta mB+2
    bpl bd              ; (always: the bmi above not taken)
bn
    txa
    eor #1
    tax
    sec
    lda #0
    sbc sB
    sta mB
    lda #0
    sbc sB+1
    sta mB+1
    lda #0
    sbc sB+2
    sta mB+2
bd
    stx csgn
.endm

; mul_dx / mul_dy: sP = round(sA * dirx / diry >> 16) (smul3r); clobbers X
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- the aim direction's sB set up once
;  here for its eight callers (each was 15 bytes, now a 3-byte jsr)]
; [2026-10-27 6502-idioms/SKILL.md: fall through instead of jumping -- mul_dx into smul3r,
;  smul3r into rsh16]
.proc mul_dy
    ldx #diry-dirx
    bne mul_dx.go           ; (always)
.endp
.proc mul_dx
    ldx #0
go:
    lda dirx,x
    sta sB
    lda dirx+1,x
    sta sB+1
    lda dirx+2,x
    sta sB+2
    ert *<>smul3r           ; falls into smul3r
.endp

; smul3r: sP[0..2] = round((sA * sB) >> 16), signed -- replaces every
; `jsr smul3 / jsr rsh16` pair.  A negative product is never negated as 6
; bytes: rsh16n folds the negation into the rounding add (same carries).
.proc smul3r
    SMUL_PRE
    jsr mul48
    lda csgn
    bne rsh16n
    ert *<>rsh16            ; falls into rsh16
.endp

; rsh16: sP[0..2] = round(sP(6) >> 16) = bytes 2..4 of (P + $8000).
; Byte 5 of that sum is read by nobody, so its carry-add is gone, and the
; three result bytes go straight to their slots (no sP+1..+5 write-backs).
.proc rsh16
    clc
    lda sP+1
    adc #$80
    lda sP+2
    adc #0
    sta sP
    lda sP+3
    adc #0
    sta sP+1
    lda sP+4
    adc #0
    sta sP+2
    rts
.endp

; rsh16n: sP[0..2] = round((-P) >> 16) for the 48-bit P in sP.
; -P + $8000 = ~P + $8001 summed byte-wise: carry out of byte 0 is (P0 == 0),
; then ~P1 + $80 + c, ~P2 + c, ~P3 + c, ~P4 + c -- exactly the carries the
; old 6-byte negate followed by rsh16 produced (asm_bench --micro: friction,
; smul3r sites).
.proc rsh16n
    sec
    lda #0
    sbc sP              ; C = 1 iff P0 == 0
    lda sP+1
    eor #$FF
    adc #$80
    lda sP+2
    eor #$FF
    adc #0
    sta sP
    lda sP+3
    eor #$FF
    adc #0
    sta sP+1
    lda sP+4
    eor #$FF
    adc #0
    sta sP+2
    rts
.endp


; rsh9: mA(3) = round(sP >> 9): bits 9..32 of sP + $100 (both callers multiply it next:
; the result goes where they read it).  Byte 5 never reaches these bits.  Keeps sP.
; [2026-10-27 6502-idioms/SKILL.md: shift in A, store once -- no 6-byte shift in memory;
;  the reader reads the source -- no sP -> mA copy]
.proc rsh9
    sec                 ; Q = sP + $100 over bytes 1..4: Q1 in X, Q2 in Y, Q3 in mA+2, Q4 in A
    lda sP+1
    adc #0
    tax
    lda sP+2
    adc #0
    tay
    lda sP+3
    adc #0
    sta mA+2
    lda sP+4
    adc #0
    lsr @               ; C = Q4 bit 0
    lda mA+2            ; mA+2 = Q4:Q3 >> 1
    ror @
    sta mA+2
    tya                 ; mA+1 = Q3:Q2 >> 1
    ror @
    sta mA+1
    txa                 ; mA = Q2:Q1 >> 1
    ror @
    sta mA
    rts
.endp

; --------------------------------------------------------------------------


; SQ24M src,dst: dst(5) = src(3)^2, EXACT, for src < 2^18 (src+2 <= 3: |v| <=
; $1B800, |dx| < mind, pocket |dx| < $040000).  a = h*2^16 + l:  a^2 = l^2 +
; (2hl)<<16 + h^2<<32.  l^2 = ll^2 + 2*ll*lh<<8 + lh^2<<16: the squares come
; straight from the r^2 table, the cross term is one quarter-square partial;
; the h terms are h adds of 2l (h <= 3) and h^2 <= 9 added to byte 4.  l^2 <
; 2^32 so no carry leaves byte 3; a^2 < 2^36 fits 5 bytes (byte 5 is the
; caller's).  Clobbers X, Y, A, fmpl, fmph, mtmp.  (labels macro-local)
.macro SQ24M
    ldx :1              ; ll^2 -> bytes 0,1
    lda sqlo,x
    sta :2
    lda sqhi,x
    sta :2+1
    txa                 ; 2*ll*lh (17 bits) added at byte 1
    sta l1+1
    sta h1+1
    eor #$FF
    sta l2+1
    sta h2+1
    ldx :1+1
    sec
l1  lda sqr1lo,x
l2  sbc sqr2lo,x
    sta fmpl
h1  lda sqr1hi,x
h2  sbc sqr2hi,x
    asl fmpl            ; C = bit 8
    rol @               ; t1 ; C = bit 16
    tay
    lda #0
    rol @
    sta :2+3            ; t2 (0/1), byte 3 so far (C = 0: A was 0)
    lda fmpl
    adc :2+1
    sta :2+1
    tya
    adc #0
    sta :2+2
    bcc s3
    inc :2+3
    clc
s3                      ; lh^2 -> bytes 2,3 (no carry out: l^2 < 2^32)
    lda :2+2
    adc sqlo,x
    sta :2+2
    lda :2+3
    adc sqhi,x
    sta :2+3
    lda #0
    sta :2+4
    ldx :1+2            ; h = 0 -> done
    beq done
    lda :1              ; mtmp = 2l (17 bits)
    asl @
    sta mtmp
    lda :1+1
    rol @
    sta mtmp+1
    lda #0
    rol @
    sta mtmp+2
hl                      ; bytes 2..4 += 2l, h times (C = 0: in from a rol of 0, round
    lda :2+2            ;   from byte 4's add -- the total < 2^36 carries out nothing)
    adc mtmp
    sta :2+2
    lda :2+3
    adc mtmp+1
    sta :2+3
    lda :2+4
    adc mtmp+2
    sta :2+4
    dex
    bne hl
    ldx :1+2            ; byte 4 += h^2 (sqlo: h <= 3; total < 2^36: no carry)
    lda :2+4            ; [2026-10-27 6502-loops-tables-smc/SKILL.md: tables beat arithmetic --
    adc sqlo,x          ;  was h adds of h] (C = 0 from the loop)
    sta :2+4
done
.endm


; mul48: mP(6) = mA(3) x mB(3) unsigned -- the EXACT product, so any exact
; method is bit-identical.  FAST PATH when both high bytes are <= 3 (every
; product the game forms: sp*u, v*217, v^2, dx^2 with |dx| < $034800, n*ov,
; rvn*499, imp*n with |rvn| <= 2*sp): the four 16x16 partials give
; A16*B16 < 2^32 (so P4 = P5 = 0 after them and no carry can leave P3), then
; B16<<16 is added a2 times, A16<<16 b2 times, and a2*b2 (<= 9) goes to P4 --
; no lookups for the high bytes.  The product is < 2^36, so P4 <= 15 and P5
; stays 0.  Otherwise the original 9-partial schoolbook runs (mul48_full,
; verbatim).  Validated: tools/asm_bench.py --micro.
; [2026-10-28 6502-loops-tables-smc/SKILL.md: tables beat arithmetic -- high bytes 4..15 (the
;  aim's ghost: Q8 distances x a unit direction) stay on this path: a2 B16 / b2 A16 as two
;  8x8 quarter-square products (fmulu) instead of 9 partials; P < 2^40: P4 < 256, P5 = 0]
.proc mul48
    lda mA+2
    cmp #16
    bcs full
    lda mA              ; four 8x8 quarter-square partials; the two of a0 (a1)
    sta l00+1           ; share one patch value, each high byte waits in Y
    sta h00+1
    sta l01+1
    sta h01+1
    eor #$FF
    sta m00+1
    sta g00+1
    sta m01+1
    sta g01+1
    lda mA+1
    sta l10+1
    sta h10+1
    sta l11+1
    sta h11+1
    eor #$FF
    sta m10+1
    sta g10+1
    sta m11+1
    sta g11+1
; mul48r: mA as the last mul48 left it (unchanged since): its patches stand when mA+2 <= 3
; (then that call patched them too); a wider mA goes the full way as mul48 does
; [2026-10-27 6502-loops-tables-smc/SKILL.md: SMC stores of a target that rarely changes]
r1: lda mB+2
    cmp #16
    bcc fast
full:
    jmp mul48_full
r:  lda mA+2            ; (mul48r's entry: out of mul48's way, no jmp on its path)
    cmp #16
    bcs full
    bcc r1              ; (always)
fast:
    ldx mB              ; (0,0) -> P0,P1
    sec
l00 lda sqr1lo,x
m00 sbc sqr2lo,x
    sta mP
h00 lda sqr1hi,x
g00 sbc sqr2hi,x
    sta mP+1
    ldx mB+1            ; (0,1) -> P1 += lo ; P2 = hi + c
l01 lda sqr1lo,x
m01 sbc sqr2lo,x
    sta fmpl
h01 lda sqr1hi,x
g01 sbc sqr2hi,x
    tay
    clc
    lda mP+1
    adc fmpl
    sta mP+1
    tya
    adc #0
    sta mP+2
    ldx mB              ; (1,0) -> P1 += lo ; P2 += hi + c ; P3 = c
    sec
l10 lda sqr1lo,x
m10 sbc sqr2lo,x
    sta fmpl
h10 lda sqr1hi,x
g10 sbc sqr2hi,x
    tay
    clc
    lda mP+1
    adc fmpl
    sta mP+1
    tya
    adc mP+2
    sta mP+2
    lda #0
    rol @
    sta mP+3
    ldx mB+1            ; (1,1) -> P2 += lo ; P3 += hi + c  (no carry out: < 2^32)
    sec
l11 lda sqr1lo,x
m11 sbc sqr2lo,x
    sta fmpl
h11 lda sqr1hi,x
g11 sbc sqr2hi,x
    tay
    clc
    lda mP+2
    adc fmpl
    sta mP+2
    tya
    adc mP+3
    sta mP+3
    lda #0
    sta mP+4
    sta mP+5
    ldx mA+2            ; + a2 * B16 << 16  (B16 added a2 times, a2 <= 3)
    beq noa2            ; (C = 0 here and round each loop: (1,1)'s add carries out nothing,
    cpx #4              ;   a carry out of P3 is cleared where it goes into P4)
    bcs a2m             ; (a2 4..15: two products, out of line)
la2:
    lda mP+2
    adc mB
    sta mP+2
    lda mP+3
    adc mB+1
    sta mP+3
    bcc na2
    inc mP+4
    clc
na2:
    dex
    bne la2
noa2:
    ldx mB+2            ; + b2 * A16 << 16  (A16 added b2 times)
    beq nob2
    cpx #4
    bcs b2m             ; (b2 4..15: two products, out of line; C = 0 on the loop's way)
lb2:
    lda mP+2
    adc mA
    sta mP+2
    lda mP+3
    adc mA+1
    sta mP+3
    bcc nb2
    inc mP+4
    clc
nb2:
    dex
    bne lb2
ab2:
    ldx mA+2            ; + a2 * b2 << 32  (P4 += b2, a2 times; P < 2^40: no carry)
    beq nob2
lab:
    lda mP+4
    adc mB+2
    sta mP+4
    dex
    bne lab
nob2:
    rts
a2m:                    ; a2 * B16 << 16 = a2 b0 << 16 + a2 b1 << 24 (fmulu keeps X = a2)
    lda mB
    jsr fmulu
    clc
    lda mP+2
    adc fmpl
    sta mP+2
    lda mP+3
    adc fmph
    sta mP+3
    bcc a2c
    inc mP+4
a2c:
    lda mB+1
    jsr fmulu
    clc
    lda mP+3
    adc fmpl
    sta mP+3
    lda mP+4
    adc fmph
    sta mP+4            ; (C = 0: P4 < 256)
    jmp noa2
b2m:                    ; b2 * A16 << 16, the same (X = b2)
    lda mA
    jsr fmulu
    clc
    lda mP+2
    adc fmpl
    sta mP+2
    lda mP+3
    adc fmph
    sta mP+3
    bcc b2c
    inc mP+4
b2c:
    lda mA+1
    jsr fmulu
    clc
    lda mP+3
    adc fmpl
    sta mP+3
    lda mP+4
    adc fmph
    sta mP+4            ; (C = 0: P4 < 256)
    jmp ab2
.endp
mul48r = mul48.r

; mul16h: mP+1..3 = mA * mB without the low partial aL*bL (3 quarter-square
; partials): for results that keep only bits >= 12 of the product
; (rot_ref.mulh).  mul16hr reuses the mA of the previous mul16h.  mP+0 is
; not written.  Clobbers A, X, Y.
.proc mul16h
    lda mA
    sta mul16hm.a2+1
    sta mul16hm.a3+1
    eor #$FF
    sta mul16hm.b2+1
    sta mul16hm.b3+1
    lda mA+1
    sta mul16hm.c0+1
    sta mul16hm.c1+1
    sta mul16hm.c2+1
    sta mul16hm.c3+1
    eor #$FF
    sta mul16hm.d0+1
    sta mul16hm.d1+1
    sta mul16hm.d2+1
    sta mul16hm.d3+1
    ert *<>mul16hm          ; falls into the multiply
.endp

.proc mul16hm
    ldx mB
    sec                     ; aH*bL -> P1, P2
c0  lda sqr1lo,x
d0  sbc sqr2lo,x
    sta mP+1
c1  lda sqr1hi,x
d1  sbc sqr2hi,x
    tay                     ; hl.h
    ldx mB+1
                            ; (C = 1: the product before borrowed nothing) aL*bH
a2  lda sqr1lo,x
b2  sbc sqr2lo,x
    sta mtmp
a3  lda sqr1hi,x
b3  sbc sqr2hi,x
    sta mtmp+1
                            ; (C = 1: the product before borrowed nothing) aH*bH -> P2, P3
c2  lda sqr1lo,x
d2  sbc sqr2lo,x
    sta fmpl
c3  lda sqr1hi,x
d3  sbc sqr2hi,x
; [2026-10-09 6502-idioms/SKILL.md: lda X / sta Y / lda Y (hl.h in Y) ; flags are values you track (carry into P3 by inx)]
    tax
    clc                     ; P1 += lh.l ; P2 = hl.h + lh.h + hh.l (+c) ; P3 = hh.h + c
    lda mP+1
    adc mtmp
    sta mP+1
    tya
    adc mtmp+1
    bcc nc                  ; a carry into P3: hh.h + c <= 255 (P < 2^32)
    inx
    clc
nc:
    adc fmpl
    sta mP+2
    txa
    adc #0
    sta mP+3
    rts
.endp
mul16hr = mul16hm

; mul16u: mP(4) = mA(16) * mB(16) unsigned -- four quarter-square partials
; (mads-src/math/fmul_16x16.asm on the game's sqr tables).  mul16r reuses
; the mA of the previous call (its 16 operand patches skipped).  Partial
; high bytes park in mtmp/fmpl.  Clobbers A, X.
.proc mul16u
    lda mA
    sta mul16m.a0+1
    sta mul16m.a1+1
    sta mul16m.a2+1
    sta mul16m.a3+1
    eor #$FF
    sta mul16m.b0+1
    sta mul16m.b1+1
    sta mul16m.b2+1
    sta mul16m.b3+1
    lda mA+1
    sta mul16m.c0+1
    sta mul16m.c1+1
    sta mul16m.c2+1
    sta mul16m.c3+1
    eor #$FF
    sta mul16m.d0+1
    sta mul16m.d1+1
    sta mul16m.d2+1
    sta mul16m.d3+1
    ert *<>mul16m           ; falls into the multiply
.endp

; mul16r: the multiply with the operands mul16u patched last (mB new).
.proc mul16m
    ldx mB
    sec                     ; aL*bL
a0  lda sqr1lo,x
b0  sbc sqr2lo,x
    sta mP
a1  lda sqr1hi,x
b1  sbc sqr2hi,x
    sta mP+1
                            ; (C = 1: the product before borrowed nothing) aH*bL
c0  lda sqr1lo,x
d0  sbc sqr2lo,x
    sta mtmp
c1  lda sqr1hi,x
d1  sbc sqr2hi,x
    sta mtmp+1
    ldx mB+1
                            ; (C = 1: the product before borrowed nothing) aL*bH
a2  lda sqr1lo,x
b2  sbc sqr2lo,x
    sta mtmp+2
a3  lda sqr1hi,x
b3  sbc sqr2hi,x
    sta mtmp+3
                            ; (C = 1: the product before borrowed nothing) aH*bH
c2  lda sqr1lo,x
d2  sbc sqr2lo,x
    sta fmpl
c3  lda sqr1hi,x
d3  sbc sqr2hi,x
    tax                     ; P3 so far
    clc                     ; P1 = ll.h + hl.l + lh.l ; P2 = hl.h + lh.h + hh.l (+c)
    lda mP+1
    adc mtmp
    sta mP+1
    lda mtmp+1
    adc mtmp+3
    sta mP+2
    txa
    adc #0
    sta mP+3
    clc
    lda mP+1
    adc mtmp+2
    sta mP+1
    lda mP+2
    adc fmpl
    sta mP+2
    bcc done
    inc mP+3
done:
    rts
.endp
mul16r = mul16m

; mul48_full: the original quarter-square schoolbook (9 fmulu partials), kept
; verbatim for operands with a high byte >= 2.
.proc mul48_full
    lda mA              ; (0,0) -> init mP0,mP1
    ldx mB
    jsr fmulu
    lda fmpl
    sta mP
    lda fmph
    sta mP+1
    lda mA              ; (0,1) -> mP1 += lo ; mP2 = hi+c (init)
    ldx mB+1
    jsr fmulu
    clc
    lda mP+1
    adc fmpl
    sta mP+1
    lda fmph
    adc #0
    sta mP+2
    lda mA+1            ; (1,0) -> mP1 += lo ; mP2 += hi ; mP3 = c (init)
    ldx mB
    jsr fmulu
    clc
    lda mP+1
    adc fmpl
    sta mP+1
    lda mP+2
    adc fmph
    sta mP+2
    lda #0
    adc #0
    sta mP+3
    lda mA              ; (0,2) -> mP2 += lo ; mP3 += hi ; mP4 = c (init)
    ldx mB+2
    jsr fmulu
    clc
    lda mP+2
    adc fmpl
    sta mP+2
    lda mP+3
    adc fmph
    sta mP+3
    lda #0
    adc #0
    sta mP+4
    lda mA+1            ; (1,1) -> mP2 += lo ; mP3 += hi ; mP4 += c
    ldx mB+1
    jsr fmulu
    clc
    lda mP+2
    adc fmpl
    sta mP+2
    lda mP+3
    adc fmph
    sta mP+3
    lda mP+4
    adc #0
    sta mP+4
    lda mA+2            ; (2,0) -> mP2 += lo ; mP3 += hi ; mP4 += c
    ldx mB
    jsr fmulu
    clc
    lda mP+2
    adc fmpl
    sta mP+2
    lda mP+3
    adc fmph
    sta mP+3
    lda mP+4
    adc #0
    sta mP+4
    lda mA+1            ; (1,2) -> mP3 += lo ; mP4 += hi ; mP5 = c (init)
    ldx mB+2
    jsr fmulu
    clc
    lda mP+3
    adc fmpl
    sta mP+3
    lda mP+4
    adc fmph
    sta mP+4
    lda #0
    adc #0
    sta mP+5
    lda mA+2            ; (2,1) -> mP3 += lo ; mP4 += hi ; mP5 += c
    ldx mB+1
    jsr fmulu
    clc
    lda mP+3
    adc fmpl
    sta mP+3
    lda mP+4
    adc fmph
    sta mP+4
    lda mP+5
    adc #0
    sta mP+5
    lda mA+2            ; (2,2) -> mP4 += lo ; mP5 += hi (no carry out: P < 2^48)
    ldx mB+2
    jsr fmulu
    clc
    lda mP+4
    adc fmpl
    sta mP+4
    lda mP+5
    adc fmph
    sta mP+5
    rts
.endp


; isqrt48: root(3) = floor(sqrt(mP)).  Consumes mP.  Same 2-bits-per-step
; restoring algorithm as the original (rem = 4*rem + 2 bits; if rem >= 4*root+1
; then rem -= that and root = 2*root+1 else root = 2*root), restructured:
;  - the input is consumed one BYTE at a time from a ZP cell (4 steps per byte)
;    instead of shifting all 6 bytes of mP twice per step;
;  - u = 4*root is kept incrementally (u' = 2u, +4 on a 1 digit: 2u is a
;    multiple of 8, so the +4 is an ORA) instead of rebuilt from root each step,
;    and "rem >= u+1" is tested as "u < rem" with the -1 folded into the
;    subtract's borrow (clc before sbc);
;  - leading ZERO BYTES are skipped outright (a zero digit pair on a zero
;    remainder yields a 0 root bit and leaves rem 0, so the root is unchanged --
;    the same argument as the old 16-bit pre-skip, at byte granularity).
; Bit-identical root: tools/asm_bench.py --micro isqrt48 (random 0..2^48).
;
; Inputs below 2^36 (every one the game forms: d2 < mind2, |v|^2 < 2^35)
; take the 3-BYTE path: the top 16 bits N (from the first non-zero byte) are
; solved at once -- r = isqrt(N) by an 8-step binary search in the r^2
; table, rem = N - r^2, u = 4r (isqrt(n >> 2k) = isqrt(n) >> k, so this is
; the state the 2-bit steps would have reached) -- then the 2-bit steps
; (unrolled, 3-byte remainder) run over the remaining bytes.  root is not
; built step by step: it is u >> 2 at the end.  Same root.
.macro SQSTEP           ; one 2-bit step, 3-byte remainder (labels macro-local)
    asl bits
    rol mrem
    rol mrem+1
    rol mrem+2
    asl bits
    rol mrem
    rol mrem+1
    rol mrem+2
    lda mtmp+2          ; u < rem ?
    cmp mrem+2
    bcc yes
    bne no
    lda mtmp+1
    cmp mrem+1
    bcc yes
    bne no
    lda mtmp
    cmp mrem
    bcs no
yes                     ; rem -= u + 1 (C = 0: both ways in are a taken bcc -- the 1)
    lda mrem
    sbc mtmp
    sta mrem
    lda mrem+1
    sbc mtmp+1
    sta mrem+1
    lda mrem+2
    sbc mtmp+2
    sta mrem+2
    lda mtmp            ; u = 2u + 4  (C = bit 7 into the next byte)
    asl @
    ora #4
    sta mtmp
    rol mtmp+1
    rol mtmp+2
    bcc nxt             ; (always: u < 2^20, mtmp+2's bit 7 is 0)
no
    asl mtmp            ; u = 2u
    rol mtmp+1
    rol mtmp+2
nxt
.endm

; QBIT b: binary-search step for r = isqrt(mrem+1:mrem): X = r so far.
.macro QBIT
    txa
    ora #:1
    tay
    lda mrem+1
    cmp sqhi,y
    bcc no
    bne yes
    lda mrem
    cmp sqlo,y
    bcc no
yes
    tya
    tax
no
.endm

.proc isqrt48
    lda mP+5
    beq ok1
wide:
    jmp isqrt48w        ; >= 2^36: the 4-byte remainder version below
ok1:
    lda mP+4
    cmp #$10
    bcs wide
    ldx #4
pre:
    lda mP,x            ; first non-zero byte from the top
    bne top
    dex
    bpl pre
    sta root            ; mP == 0 -> root = 0  (A = 0)
    sta root+1
    sta root+2
    rts
one:
    sta mrem
    lda #0
    sta mrem+1
    beq srch            ; (always; X = -1)
top:                    ; N = mP[x]:mP[x-1]  (0:mP[0] when x = 0)
    dex
    bmi one
    sta mrem+1
    lda mP,x
    sta mrem
    dex                 ; next byte (-1: none)
srch:
    stx sqx
    ldx #0
    QBIT $80
    QBIT $40
    QBIT $20
    QBIT $10
    QBIT $08
    QBIT $04
    QBIT $02
    QBIT $01
    sec                 ; rem = N - r^2  (<= 2r)
    lda mrem
    sbc sqlo,x
    sta mrem
    lda mrem+1
    sbc sqhi,x
    sta mrem+1
    lda #0
    sta mrem+2
    sta mtmp+2
    sta mtmp+1
    txa                 ; u = 4r
    asl @
    rol mtmp+1
    asl @
    rol mtmp+1
    sta mtmp
    ldx sqx
    jmi fin
byte:
    lda mP,x
    sta bits
    SQSTEP
    SQSTEP
    SQSTEP
    SQSTEP
    dex
    bmi fin
    jmp byte
fin:
    lda mtmp+2          ; root = u >> 2
    lsr @
    sta root+2
    lda mtmp+1
    ror @
    sta root+1
    lda mtmp
    ror @
    lsr root+2
    ror root+1
    ror @
    sta root
    rts
.endp

.proc isqrt48w
    lda #0
    sta root
    sta root+1
    sta root+2
    sta mrem
    sta mrem+1
    sta mrem+2
    sta mrem+3
    sta mtmp            ; u = 4*root = 0
    sta mtmp+1
    sta mtmp+2
    sta mtmp+3
    ldx #5
pre:
    lda mP,x            ; first non-zero byte from the top
    bne byte
    dex
    bpl pre
    rts                 ; mP == 0 -> root = 0
byte:
    lda mP,x
    sta bits
    ldy #4
b2:
    asl bits            ; rem = rem*4 + next 2 bits
    rol mrem
    rol mrem+1
    rol mrem+2
    rol mrem+3
    asl bits
    rol mrem
    rol mrem+1
    rol mrem+2
    rol mrem+3
    lda mtmp+3          ; u < rem ?  (<=> rem >= 4*root+1)
    cmp mrem+3
    bcc yes
    bne no
    lda mtmp+2
    cmp mrem+2
    bcc yes
    bne no
    lda mtmp+1
    cmp mrem+1
    bcc yes
    bne no
    lda mtmp
    cmp mrem
    bcs no              ; u >= rem -> digit 0
yes:                    ; rem -= u + 1 (C = 0: both ways in are a taken bcc -- the 1)
    lda mrem
    sbc mtmp
    sta mrem
    lda mrem+1
    sbc mtmp+1
    sta mrem+1
    lda mrem+2
    sbc mtmp+2
    sta mrem+2
    lda mrem+3
    sbc mtmp+3
    sta mrem+3
    asl root            ; root = 2*root + 1
    rol root+1
    rol root+2
    inc root
    asl mtmp            ; u = 2u + 4 = 4*(2*root_old + 1)
    rol mtmp+1
    rol mtmp+2
    rol mtmp+3
    lda mtmp
    ora #4
    sta mtmp
    bne nxt             ; (A != 0: always)
no:
    asl root            ; root = 2*root
    rol root+1
    rol root+2
    asl mtmp            ; u = 2u
    rol mtmp+1
    rol mtmp+2
    rol mtmp+3
nxt:
    dey
    bne b2
    dex
    bpl byte
    rts
.endp

; [2026-10-27 6502-cycles-layout/SKILL.md: measured (phys_check --shift) -- isqrt48 32 bytes
;  lower has its loops' branches in their pages: fmulu (no branches) moved here from before it]
; fmulu: A = a, X = b  ->  fmpl:fmph = a*b (8x8->16 unsigned), via 4 quarter-square
; tables and self-modified (page-aligned) base addresses.  Preserves X.
;   a*b = sqr1[a+b] - sqr2[(255-a)+b]   (validated for all 65536 pairs)
.proc fmulu
    sta m1+1
    sta m2+1
    eor #$FF
    sta m3+1
    sta m4+1
    sec
m1: lda sqr1lo,x
m3: sbc sqr2lo,x
    sta fmpl
m2: lda sqr1hi,x
m4: sbc sqr2hi,x
    sta fmph
    rts
.endp

; tick_all's lists (physics.asm), here in the slack before div16r's page: their reads
; (cdl-1,x, wkl-1,y every tick) never cross one
cdl     :NB dta 0           ; tick_all: the balls that may be awake, index order
wkl     :NB dta 0           ; the balls collide woke this tick
    ert >[cdl-1] <> >[wkl+NB-1]
; nchg: a ball's NEWS rewritten since objects.asm draw_all last copied it to OLDS (input.asm
; gstore sets it) [2026-10-28 fable-skill-atari/SKILL.md 4: a cache behind a stamp -- an
; unchanged NEWS is OLDS already, no copy]
nchg    :NTOT dta 0

; [2026-10-27 6502-cycles-layout/SKILL.md: a hot loop in one page] div16r starts a page: its
;  16-step loop sat across $FB00 -- each taken bne lp / bcc lt paid +1 (4 calls a contact);
;  aligned, div24's loop below fits its page too (the erts after both)
    :[[$100-[*&$FF]]&$FF] dta 0
; div16r: mQ(3) = round(mA(6) / mB(3)) for dividends whose top 32 bits (mA+2..5)
; are <= mB -- i.e. a quotient <= 2^16: the collision normal (adx<<16 / d,
; adx <= d) and the deceleration (DEC_HI * |v| / sp, DEC_HI < 2^16, |v| <= sp).
; The remainder is preloaded with mA+2..4 (mA+5 is 0 there) and only the low
; 16 bits shift in: 16 steps over a 3-byte remainder instead of div24's 24
; over 4 bytes.  Preload == mB (adx == d) is the exact quotient 2^16, rem 0.
; Rounding as divr (ties up).  Same result as divr on that domain
; (asm_bench --micro div16r).  Clobbers X, Y, mA, mA+1.
.proc div16r
    lda mA+2
    sta mrem
    lda mA+3
    sta mrem+1
    lda mA+4            ; A = remainder top byte for the whole loop
    cmp mB+2            ; preload == mB ?  (top-down compare)
    bne go
    ldy mrem+1
    cpy mB+1
    bne go
    ldy mrem
    cpy mB
    bne go
    lda #0              ; exact 2^16 (the low 16 bits are 0 on this domain)
    sta mQ
    sta mQ+1
    lda #1
    sta mQ+2
    rts
go:
    ldx #16
    clc                 ; the bit below the first dividend bit
lp:                     ; the quotient bits shift into mA as the dividend leaves it
    rol mA
    rol mA+1
    rol mrem
    rol mrem+1
    rol @
    bcs ge              ; bit 24 out -> rem >= 2^24 > mB
    cmp mB+2
    bcc lt
    bne ge
    ldy mrem+1
    cpy mB+1
    bcc lt
    bne ge
    ldy mrem
    cpy mB
    bcc lt
ge:                     ; every way in has C = 1
    tay
    lda mrem            ; rem -= mB
    sbc mB
    sta mrem
    lda mrem+1
    sbc mB+1
    sta mrem+1
    tya
    sbc mB+2
    sec                 ; quotient bit 1 (a rem >= 2^24 path leaves a borrow)
lt:
    dex
    bne lp
    rol mA              ; the last quotient bit
    rol mA+1
    ldy #0
    sty mQ+2            ; quotient < 2^16
    asl mrem            ; round: 2*rem >= mB -> +1  (rem < mB < 2^24)
    rol mrem+1
    rol @
    bcs up
    cmp mB+2
    bcc done
    bne up
    lda mrem+1
    cmp mB+1
    bcc done
    bne up
    lda mrem
    cmp mB
    bcc done
up:
    inc mA
    bne done
    inc mA+1
    bne done
    inc mQ+2
done:
    lda mA
    sta mQ
    lda mA+1
    sta mQ+1
    rts
.endp
    ert >div16r.lp <> >[div16r.lt+3]     ; (the loop and the page after its bne: one page)

; div16s: mQ(3) = round((n << 16) / d), n = mA+2..3 <= d = mB..mB+1 (16 bits):
; div16r on the clipper's domain (cross), its rounding, n = d -> 2^16.  The
; remainder is 17 bits (hi in A, the 17th in C); a sentinel 1 in mQ ends the
; loop as it leaves mQ+1 (no counter).  Clobbers Y.
; [2026-10-21 6502-idioms/SKILL.md: compute in A -- the remainder's high byte lives in A;
;  count to zero -- a sentinel bit ends the loop, no dex / counter; price each site: 635 vs
;  1013 cycles a call, 20 calls a redraw]
.proc div16s
    lda #0
    sta mQ+1
    sta mQ+2
    lda mA+2
    sta mrem
    lda mA+3                ; A = the remainder's high byte for the whole loop
    cmp mB+1
    bne go
    ldy mrem
    cpy mB
    bne go
    lda #0                  ; n = d: exactly 2^16
    sta mQ
    lda #1
    sta mQ+2
    rts
go:
    ldy #1
    sty mQ                  ; the sentinel
lp:
    asl mrem                ; rem *= 2: C = bit 16 -> rem >= 2^16 > d
    rol @
    bcs ge
    cmp mB+1
    bcc lt
    bne ge
    ldy mrem
    cpy mB
    bcc lt
ge:                         ; every way in has C = 1
    tay
    lda mrem
    sbc mB
    sta mrem
    tya
    sbc mB+1
    sec                     ; quotient bit 1 (the bit-16 path leaves a borrow)
lt:
    rol mQ
    rol mQ+1
    bcc lp                  ; (until the sentinel leaves)
    asl mrem                ; round: 2 rem >= d -> +1
    rol @
    bcs up
    cmp mB+1
    bcc done
    bne up
    lda mrem
    cmp mB
    bcc done
up:
    inc mQ
    bne done
    inc mQ+1
    bne done
    inc mQ+2
done:
    rts
.endp


; div24: mQ(3) = floor(mA(6) / mB(3)), mrem(4) = remainder.  mB preserved.
; Same preloaded-remainder restoring division as the original (see below);
; the trial subtraction into mtmp + copy-back is replaced by a top-down
; compare that decides early and subtracts IN PLACE only when rem >= mB.
; Bit-identical (quotient and remainder): asm_bench --micro div24/divr.
.proc div24
    lda mA+3
    sta mrem
    lda mA+4
    sta mrem+1
    lda mA+5
    sta mrem+2
    lda #0
    sta mrem+3
    ldx #24
lp:
    asl mA
    rol mA+1
    rol mA+2
    rol mrem
    rol mrem+1
    rol mrem+2
    rol mrem+3
    lda mrem+3
    bne ge              ; rem >= 2^24 > mB
    lda mrem+2
    cmp mB+2
    bcc lt
    bne ge
    lda mrem+1
    cmp mB+1
    bcc lt
    bne ge
    lda mrem
    cmp mB
    bcc lt
ge:
    sec                 ; rem -= mB ; leaves C = 1 = this quotient bit
    lda mrem
    sbc mB
    sta mrem
    lda mrem+1
    sbc mB+1
    sta mrem+1
    lda mrem+2
    sbc mB+2
    sta mrem+2
    lda mrem+3
    sbc #0
    sta mrem+3
lt:                     ; C = 0 straight from a bcc: quotient bit 0
    rol mQ
    rol mQ+1
    rol mQ+2
    dex
    bne lp
    rts
.endp
    ert >div24.lp <> >[div24.lt+9]       ; (lt: rol x3, dex, bne lp: one page)

