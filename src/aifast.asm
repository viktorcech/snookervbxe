; aifast.asm -- the AI's hot helpers in RAM (the main block, above $6000: the AI's
; window never covers it, tools/check_layout.py), called from its banks.
; [2026-10-22 6502-idioms/SKILL.md: code size is RAM -- the RAM the OS gave back (osrom.asm)
;  spent where the thinking spends its cycles; 6502-loops-tables-smc/SKILL.md: unrolled
;  runs entered by a patched jmp (no loop count), the top byte in A, stored once]

; csh: Y = i (0..13) -> ctx = cx >> i, cty = cy >> i (24-bit, arithmetic: cordic's
; t and u).  i >= 8: a byte down first.  The bits left, s: 1..4 right in place;
; 5..7 as 8 - s left of (v, its sign byte) and the upper 3 bytes -- the same floor.
.proc csh
    cpy #8
    bcs by
    lda cx                  ; the copies
    sta ctx
    lda cx+1
    sta ctx+1
    lda cx+2
    sta ctx+2
    lda cy
    sta cty
    lda cy+1
    sta cty+1
    lda cy+2
    sta cty+2
    jmp sh
by:
    lda cx+2                ; a byte down, the sign byte in
    sta ctx+1
    asl @
    lda #0
    adc #$FF
    eor #$FF
    sta ctx+2
    lda cx+1
    sta ctx
    lda cy+2
    sta cty+1
    asl @
    lda #0
    adc #$FF
    eor #$FF
    sta cty+2
    lda cy+1
    sta cty
    tya
    sec                     ; (the sign bytes' adc left C at y's sign)
    sbc #8
    tay
sh:
    lda xl,y                ; the run for s bits
    sta jx+1
    lda xh,y
    sta jx+2
    lda ctx+2
jx:
    jmp $FFFF
; x: s bits right (enter at 4 - s), then y the same way
xr4:
    cmp #$80
    ror @
    ror ctx+1
    ror ctx
xr3:
    cmp #$80
    ror @
    ror ctx+1
    ror ctx
xr2:
    cmp #$80
    ror @
    ror ctx+1
    ror ctx
xr1:
    cmp #$80
    ror @
    ror ctx+1
    ror ctx
xr0:
    sta ctx+2
    lda yl,y
    sta jy+1
    lda yh,y
    sta jy+2
    lda cty+2
jy:
    jmp $FFFF
yr4:
    cmp #$80
    ror @
    ror cty+1
    ror cty
yr3:
    cmp #$80
    ror @
    ror cty+1
    ror cty
yr2:
    cmp #$80
    ror @
    ror cty+1
    ror cty
yr1:
    cmp #$80
    ror @
    ror cty+1
    ror cty
yr0:
    sta cty+2
    rts
; s = 5..7: (v0 v1 v2 E) 8 - s bits left; the result v1 v2 E (A: the top byte now)
xl3:
    asl @                   ; E = the sign byte (A = v2 here)
    lda #0
    adc #$FF
    eor #$FF
    asl ctx
    rol ctx+1
    rol ctx+2
    rol @
xl2:
    asl ctx
    rol ctx+1
    rol ctx+2
    rol @
xl1:
    asl ctx
    rol ctx+1
    rol ctx+2
    rol @
    ldx ctx+1
    stx ctx
    ldx ctx+2
    stx ctx+1
    jmp xr0
xl2e:
    asl @
    lda #0
    adc #$FF
    eor #$FF
    jmp xl2
xl1e:
    asl @
    lda #0
    adc #$FF
    eor #$FF
    jmp xl1
yl3:
    asl @
    lda #0
    adc #$FF
    eor #$FF
    asl cty
    rol cty+1
    rol cty+2
    rol @
yl2:
    asl cty
    rol cty+1
    rol cty+2
    rol @
yl1:
    asl cty
    rol cty+1
    rol cty+2
    rol @
    ldx cty+1
    stx cty
    ldx cty+2
    stx cty+1
    jmp yr0
yl2e:
    asl @
    lda #0
    adc #$FF
    eor #$FF
    jmp yl2
yl1e:
    asl @
    lda #0
    adc #$FF
    eor #$FF
    jmp yl1
xl  dta <xr0, <xr1, <xr2, <xr3, <xr4, <xl3, <xl2e, <xl1e
xh  dta >xr0, >xr1, >xr2, >xr3, >xr4, >xl3, >xl2e, >xl1e
yl  dta <yr0, <yr1, <yr2, <yr3, <yr4, <yl3, <yl2e, <yl1e
yh  dta >yr0, >yr1, >yr2, >yr3, >yr4, >yl3, >yl2e, >yl1e
.endp
