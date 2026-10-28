; physmain.asm -- physics routines in the main RAM (the RAM under the OS ROM ran full)

; isqrtc: root = floor(sqrt(mP)) for mP = d2 < MIND2 (a contact: d < mind = 210 << 10) --
; isqrt48's root, bit for bit.  [2026-10-27 fable-skill-atari/SKILL.md 3: a case by what it
; needs] d sits just under mind: with D = MIND2 - d2, est = D / (2 mind) <= mind - sqrt(d2)
; (D = 2 mind e - e^2), so r = mind - est is never below the root; r drops while r^2 > d2
; ((r-1)^2 = r^2 - 2(r-1) - 1) -- a step or two.  est = (D >> 13) * 39 >> 11 (<= D / 430080)
; + its square's term; D >= 2^29 (a deep overlap: the cushion case) goes isqrt48's way.  Keeps mP.
.proc isqrtc
    sec                     ; D = MIND2 - mP: bytes 1..3 -> mQ..mQ+2, byte 4 tested
    lda MIND2
    sbc mP
    lda MIND2+1
    sbc mP+1
    sta mQ
    lda MIND2+2
    sbc mP+2
    sta mQ+1
    lda MIND2+3
    sbc mP+3
    sta mQ+2
    lda MIND2+4
    sbc mP+4
    bne wide
    lda mQ+2                ; (D < 2^29: est < 1250; deeper is isqrt48's)
    cmp #$20
    bcc nar
wide:
    jmp isqrt48
nar:                        ; h = D >> 13: (A = mQ+2 : mQ+1 : mQ) << 3, its top two bytes ->
    asl mQ                  ;   mrem+1 (hi), X (lo) -- mQ+2 < $20 loses nothing
    rol mQ+1
    rol @
    asl mQ
    rol mQ+1
    rol @
    asl mQ
    rol mQ+1
    rol @
    sta mrem+1
    ldx mQ+1                ; est = h * 39 >> 11 (<= D / 430080): hl * 39 (its high byte), hh * 39
    lda #39
    jsr fmulu
    lda fmph
    sta mrem+2
    ldx mrem+1
    lda #39
    jsr fmulu
    clc                     ; P1 = c0 + hh*39 lo, P2 = hh*39 hi + c (P < 2^22)
    lda mrem+2
    adc fmpl
    sta mrem+2
    lda fmph
    adc #0                  ; P2 (< 64)
    tax
    asl @                   ; est lo = P2 << 5 | P1 >> 3
    asl @
    asl @
    asl @
    asl @
    sta mrem
    lda mrem+2
    lsr @
    lsr @
    lsr @
    ora mrem
    sta mrem
    txa                     ; est hi = P2 >> 3 (<= 7)
    lsr @
    lsr @
    lsr @
    sta mrem+1
; the second term: e = est + e^2 / (2 mind) -- + (est >> 3)^2 * 39 >> 18 (<= est^2 / 430080)
    asl @                   ; t = est >> 3 (est < 2048: 8 bits)
    asl @
    asl @
    asl @
    asl @
    sta mrem+2
    lda mrem
    lsr @
    lsr @
    lsr @
    ora mrem+2
    tax
    jsr fmulu               ; t^2 (A = X = t)
    ldx fmph
    lda #39
    jsr fmulu
    lda fmph                ; c = (t^2 >> 8) * 39 >> 10
    lsr @
    lsr @
    clc
    adc mrem
    sta mrem
    bcc e2
    inc mrem+1
e2:
    sec                     ; root = mind - est ($034800)
    lda #$00
    sbc mrem
    sta root
    lda #$48
    sbc mrem+1
    sta root+1
    lda #$03
    sbc #0
    sta root+2
    SQ24M root, mA          ; mA(5) = r^2
dn:
    ldx #4                  ; r^2 <= d2: done
cp:
    lda mA,x
    cmp mP,x
    bcc ok
    bne big
    dex
    bpl cp
ok:
    rts
big:                        ; r -= 1, r^2 -= 2r + 1 (the new r)
    lda root
    bne d0
    lda root+1
    bne d1
    dec root+2
d1:
    dec root+1
d0:
    dec root
    lda root                ; mB = 2r
    asl @
    sta mB
    lda root+1
    rol @
    sta mB+1
    lda root+2
    rol @
    sta mB+2
    clc                     ; mA -= 2r + 1 (C = 0: the extra 1)
    lda mA
    sbc mB
    sta mA
    lda mA+1
    sbc mB+1
    sta mA+1
    lda mA+2
    sbc mB+2
    sta mA+2
    lda mA+3
    sbc #0
    sta mA+3
    lda mA+4
    sbc #0
    sta mA+4
    jmp dn
.endp
