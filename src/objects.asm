; objects.asm -- per-ball erase / draw plumbing on the SoA arrays (X = ball
; index everywhere), ball setup.


; erase_all / draw_all: one blit per ball, the BCB written STRAIGHT into the
; VBXE window (bank 0): erase uses the template at V:$000100, draw the one at
; V:$000120 (vb_init wrote the constants of both), so only the varying fields
; are written.  The offsets are computed while the previous blit runs; the
; BUSY wait sits right BEFORE the first BCB write -- the blitter must never
; see a half-rewritten BCB.  MA_BSEL and BL_ADR are set once per pass.
; A ball's record is its sprite rectangle cut to the screen (gstore): NEWS =
; x (2), stored row, w, h, source (2), pitch; OLDS = x (2), row, w, h.
EB    = WINDOW+$100     ; erase BCB template (window, bank 0)
DB    = WINDOW+$120     ; draw BCB template
SHB   = WINDOW+$1A0     ; shadow BCB template (MODE 3: the mask ORed in)

; [2026-10-09 6502-idioms/SKILL.md: no RAM cell for a value that only waits -- the offsets go straight
;  into the BCB (read at START, so the running blit is safe: as rfill) ; 6502-loops-tables-smc/SKILL.md:
;  BUSY / START by absolute address, page patched by set_angle]
.proc erase_all                 ; erase every shown ball at its OLDS rectangle
w0  lda $D653
    bne w0
    lda #$80                    ; window -> VRAM bank 0 (XDL + BCBs)
    ldy #MA_BSEL
    sta (VB),y
    lda #$00                    ; BCB -> V:$000100
    ldy #BL_ADR0
    sta (VB),y
    ldx #NTOT-1
lp:
    lda SHOWN,x                 ; only balls that were drawn last frame
    beq nx
    stx bi
    lda x8,x
    tax                         ; X = bi*8
    ldy OLDS+2,x               ; off = ymul[row] + x: src = clean ($06) + off, dst = visible ($03) + off
    clc
    lda ymlo,y
    adc OLDS,x
    sta EB+0
    sta EB+6
    lda ymmid,y
    adc OLDS+1,x
    sta EB+1
    sta EB+7
    lda ymhi,y
    adc #0                      ; off2 <= 1: C = 0 from here on
    tay
    adc #$06
    sta EB+2
    tya
    adc #$03
    sta EB+8
    lda OLDS+3,x                ; w - 1 (C = 0: sbc #0 is -1), then h - 1 (C = 1: w >= 1)
    sbc #0
    sta EB+12
    lda OLDS+4,x
    sbc #1
    sta EB+14
w1  lda $D653
    bne w1
    lda #$01
st  sta $D653                   ; start
    ldx bi
nx:
    dex
    bpl lp
    rts
.endp

.proc draw_all                  ; every ball's shadow, then every ball at its NEWS rectangle (+ NEWS -> OLDS)
w0  lda $D653
    bne w0
    lda #$80
    ldy #MA_BSEL
    sta (VB),y
; [2026-10-21 vbxe-blitter/SKILL.md: the shadows first, all of them (OR, MODE 3): onto the erased
;  table only, never onto a ball; the template's constants are vb_init's, per blit only the fields]
    lda #$A0                    ; BCB -> V:$0001A0 (the shadow template)
    ldy #BL_ADR0
    sta (VB),y
; [2026-10-28 6502-idioms/SKILL.md: sec / sbc #v with C known clear -> sbc #v-1 -- C = 0 at
;  both loops' tops: each blit's last add (ymhi + 3) never carries, the skips keep C, the
;  shadow-only exit clears it (nh)]
    clc
    ldx #NTOT-1
sl:
    lda BON,x
    beq sn
    ldy x8,x                    ; Y = bi*8
    lda NEWS+3,y                ; w = 0: nothing of it on the screen
    beq sn
    stx bi
    sbc #0                      ; (C = 0)
    sta SHB+12                   ; w - 1, h - 1 (C = 1: w >= 1)
    lda NEWS+4,y                ; (h - its lift - 1: the shadow on the cloth below a bounce)
    clc
    sbc NLIFT,x
    sta SHB+14
    lda NEWS+7,y                ; the mask: its pitch, its source (bank 0)
    sta SHB+3
    lda NSL,x
    sta SHB+0
    lda NSH,x
    sta SHB+1
    lda NEWS+2,y                ; dst = ymul[row + its lift] + x + the buffer
    clc
    adc NLIFT,x
    tax
    clc
    lda ymlo,x
    adc NEWS,y
    sta SHB+6
    lda ymmid,x
    adc NEWS+1,y
    sta SHB+7
    lda ymhi,x
    adc #$03                    ; the visible buffer's bank
    sta SHB+8
sw1 lda $D653
    bne sw1
    lda #$01
sst sta $D653                   ; start
    ldx bi
sn:
    dex
    bpl sl
    lda #$20                    ; BCB -> V:$000120 (read at START: the running shadow is safe)
    ldy #BL_ADR0
    sta (VB),y
    lda #256-NTOT               ; far to near: dorder (zsort keeps it sorted); dk counts up
    sta dk                      ;   to 0 [2026-10-28 6502-loops-tables-smc/SKILL.md: index
    bne lp0                     ;   counting up to zero, no cpy] (always)
done:
    rts
nh:                             ; only its shadow on the screen (C = 1 from w - 1)
    clc
    bcc nx                      ; (always)
off:
    sta SHOWN,x                 ; potted or off the screen -> not drawn (A = 0)
nx:
    inc dk
    beq done
lp0:
    ldy dk
    ldx dorder+NTOT-256,y
    lda BON,x
    beq off
    ldy x8,x                    ; Y = bi*8
    lda NEWS+3,y                ; w = 0: nothing of it on the screen
    beq off
    sbc #0                      ; (C = 0)
    sta DB+12                   ; w - 1 (C = 1: w >= 1)
    lda #1
    sta SHOWN,x                 ; drawn this frame -> erase it next frame
    lda nchg,x                  ; the rectangle (ball + shadow) -> OLDS (the same stride),
    beq ocp                     ;   when gstore wrote it anew (lda / sta keep C)
    lda #0
    sta nchg,x
    lda NEWS+3,y
    sta OLDS+3,y
    lda NEWS,y
    sta OLDS,y
    lda NEWS+1,y
    sta OLDS+1,y
    lda NEWS+2,y
    sta OLDS+2,y
    lda NEWS+4,y
    sta OLDS+4,y
ocp:
    lda NBH,x                   ; the ball's rows: 0 = only its shadow is on the screen
    beq nh
    sbc #1                      ; (C = 1: w - 1 above, w >= 1 -- 2026-10-28 6502-idioms: no sec)
    sta DB+14
    lda NEWS+7,y                ; source: the sprite's row within it, its pitch
    sta DB+3
    lda NEWS+5,y
    sta DB+0
    lda NEWS+6,y
    sta DB+1                    ; (DB+2 = 0: vb_init)
    ldx NEWS+2,y                ; dst = ymul[row] + x + the buffer
    clc
    lda ymlo,x
    adc NEWS,y
    sta DB+6
    lda ymmid,x
    adc NEWS+1,y
    sta DB+7
    lda ymhi,x
    adc #$03                    ; the visible buffer's bank
    sta DB+8
w1  lda $D653
    bne w1
    lda #$01
st  sta $D653                   ; start
    jmp nx
.endp

; x8: a ball's record offset, bi*8 [2026-10-28 6502-loops-tables-smc/SKILL.md: tables beat
;  arithmetic -- ldx/ldy x8,x for txa / asl x3 / tax]
x8  :NTOT dta #*8
    ert >x8<>>[x8+NTOT-1]       ; (one page: no read crosses)

; setup_balls: fill the arrays from init_balls (geom.inc): each init record =
; x(3) y(3) bank(1).  Everything else (v, a, sp, fric, awk, shown) = 0, on = 1.
.proc setup_balls
    lda #<init_balls
    sta src
    lda #>init_balls
    sta src+1
    ldx #0
sb:
    ldy #0
    lda (src),y
    sta X0,x
    iny
    lda (src),y
    sta X1,x
    iny
    lda (src),y
    sta X2,x
    iny
    lda (src),y
    sta Y0,x
    iny
    lda (src),y
    sta Y1,x
    iny
    lda (src),y
    sta Y2,x
    iny
    lda (src),y
    sta BANK,x
    lda #1
    sta BON,x
    sta DIRTY,x                 ; project everything once
    txa
    sta ord,x                   ; collide's x-sorted order starts as 0..NB-1
    sta dorder,x                ; and the draw order
    sta opos,x                  ; and its inverse (collide keeps it in step)
    lda #0
    sta SHOWN,x
    sta AWK,x
    sta NEEDRN,x
    sta FRIC,x
    sta SP0,x
    sta SP1,x
    sta SP2,x
    sta VXF,x
    sta VX0,x
    sta VX1,x
    sta VX2,x
    sta VYF,x
    sta VY0,x
    sta VY1,x
    sta VY2,x
    sta AXF,x
    sta AX0,x
    sta AX1,x
    sta AX2,x
    sta AYF,x
    sta AY0,x
    sta AY1,x
    sta AY2,x
    sta SLP0,x                  ; rolling (at rest)
    sta SLP1,x
    sta SLP2,x
    clc                         ; src += 7 -> next init record
    lda src
    adc #7
    sta src
    bcc sb2
    inc src+1
sb2:
    inx
    cpx #NB
    beq done
    jmp sb
done:
    rts
.endp
