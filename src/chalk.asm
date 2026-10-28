; chalk.asm -- chalk marks on the cloth (tools/chalk_sim.py models them): a screw
; or a hard shot leaves a streak along the shot just ahead of the cue ball (the
; tip dragged over the cloth); up to CH_N kept in table coordinates (Q4 mm, the
; oldest replaced), drawn onto the clean buffer after every repaint (set_angle,
; before its copy to the visible one): both ends projected (pcen: the ball
; centre, + its radius in pixels: the cloth under it), a line fading from a
; faint white into the cloth (CH_C0 .. CH_C2, chalk.inc), on cloth pixels only.
; The frame's end clears them (frame_init: the table brushed).  Cold code, in the
; RAM under BASIC; CH_C0 .. CH_C2 from tools/chalk_sim.py (build/assets/chalk.inc).

    icl '../build/assets/chalk.inc'
; [2026-10-23 6502-loops-tables-smc/SKILL.md: patch an absolute operand instead of (zp),y --
;  the pixel's window address (as erase_line); the marks struct-of-arrays, the ring
;  index counted; 6502-idioms/SKILL.md: code size is RAM, jsr / rts -> jmp, flags tracked]

CH_N    = 32                ; marks kept (a power of 2: the ring's mask)
CH_PW   = $E0               ; a very hard shot: pwr from $00E000 (pwr+1)
CH_PS   = 96                ; its chance /256: a deep screw
CH_PH   = 64                ;   a very hard one
CH_NEAR = 8                 ; a ball radius in pixels from which the streak is 2 wide
HOP_PW  = $C0               ; a bounce: pwr from $00C000 (pwr+1), the tip at the top or
HOP_P   = 128               ;   the ball on the cushion behind it, 1 in 2 (/256)
HOP_XL  = 3                 ; tight on a cushion: the centre within 48 mm of it (X2 / Y2, mm / 16)
HOP_XH  = 220               ;   (3569 - 48) / 16
HOP_YH  = 108               ;   (1778 - 48) / 16
HOP_T   = 32                ; ticks in the air (0.16 s)

; chalk_add: the shot as struck (fire_cue: spin, pwr, dirx / diry, the cue's X1..Y2)
; -> now and then a mark (the tip only sometimes catches the cloth): a deep screw
; (spin 0, 1) 3 in 8, 32 mm long from 64 mm ahead; a very hard one ($E000 on) 1
; in 4, 16 mm from 32 mm; any other shot none
.proc chalk_add
    jsr hop_test            ; a miscue: the hop, and its mark for sure (a screw's)
    ldy #2                  ; the length in (diry, dirx) >> 8 units: a screw 2
    bcs go
    lda spin
    cmp #2
    bcs hd
    lda RANDOM              ; (POKEY)
    cmp #CH_PS
    bcc go
    rts
hd:
    dey
    lda pwr+2               ; very hard: >= $00E000
    bne h1
    lda pwr+1
    cmp #CH_PW
    bcc o
h1:
    lda RANDOM
    cmp #CH_PH
    bcc go
o:  rts
go:
    sty kk_chw                 ; (its width class too)
    lda dirx+1              ; L = dir >> 8 (Q8: 256 = 16 mm in Q4), x Y times
    sta kk_chlx
    lda dirx+2
    sta kk_chlx+1
    lda diry+1
    sta kk_chly
    lda diry+2
    sta kk_chly+1
    dey
    beq l1
    asl kk_chlx
    rol kk_chlx+1
    asl kk_chly
    rol kk_chly+1
l1:
    ldx kk_chi                 ; the ring's next slot
    lda kk_chw
    sta kk_chwd,x
    lda kk_chlx                ; the start: the cue + 2 L (the landing's: the cue), the end: + L
    asl @
    sta kk_cht
    lda kk_chlx+1
    rol @
    tay
    bit kk_s0
    bpl x0
    lda #0
    sta kk_cht
    tay
x0:
    clc
    lda X1
    adc kk_cht
    sta kk_chx0l,x
    tya
    adc X2
    sta kk_chx0h,x
    clc
    lda kk_chx0l,x
    adc kk_chlx
    sta kk_chx1l,x
    lda kk_chx0h,x
    adc kk_chlx+1
    sta kk_chx1h,x
    lda kk_chly
    asl @
    sta kk_cht
    lda kk_chly+1
    rol @
    tay
    bit kk_s0
    bpl y0
    lda #0
    sta kk_cht
    tay
y0:
    clc
    lda Y1
    adc kk_cht
    sta kk_chy0l,x
    tya
    adc Y2
    sta kk_chy0h,x
    clc
    lda kk_chy0l,x
    adc kk_chly
    sta kk_chy1l,x
    lda kk_chy0h,x
    adc kk_chly+1
    sta kk_chy1h,x
    lda #0
    sta kk_s0
    inx                     ; the ring on, the count to CH_N at most
    txa
    and #CH_N-1
    sta kk_chi
    lda kk_chn
    cmp #CH_N
    bcs f
    inc kk_chn
f:  rts
.endp

; chalk_land: the hop's end (tick_all): a short mark from where the cue ball is
.proc chalk_land
    lda #$80
    sta kk_s0
    ldy #1
    jmp chalk_add.go
.endp

; hop_test: a bounce (docs: Jimmy White's bounce screw and jump, Davis's swerve and
; miscue -- hitting DOWN on the cue ball): hard ($C000 on) with the tip at its top
; (spin 8), or the ball tight on the cushion behind it (the cue raised over the
; rail), 1 in 2 -> C = 1, kk_hopr set (hop_go starts the hop after fire_cue)
.proc hop_test
    lda gmode               ; the trick shots: the demo and the player's go as struck
    cmp #3
    beq no
    lda pwr+2
    bne p1
    lda pwr+1
    cmp #HOP_PW
    bcc no
p1:
    lda spin
    cmp #8
    beq ed
    lda dirx+2              ; the cushion behind it, by the aim's signs
    bmi xn
    lda X2
    cmp #HOP_XL
    bcc ed
    bcs yy                  ; (always)
xn: lda X2
    cmp #HOP_XH
    bcs ed
yy: lda diry+2
    bmi yn
    lda Y2
    cmp #HOP_XL
    bcc ed
    bcs no                  ; (always)
yn: lda Y2
    cmp #HOP_YH
    bcc no
ed:
    lda RANDOM
    cmp #HOP_P
    bcs no
    lda #1
    sta kk_hopr
    sec
    rts
no: clc
    rts
.endp

; hop_land: tick_all, the hop's end (X = 0) -- the ball on the cloth again, a quarter
; of its speed lost to the bounce (EBSA: a kick costs the cue ball its energy), a
; chalk mark where it landed.  Keeps X = 0.
.proc hop_land
    lda #1
    sta AWK
    sta NEEDRN              ; (renorm: its a, sp from the new v)
    ldy #0                  ; v -= v / 4 (32 bits signed, Q20), x then y ($80 on)
ax:
    lda VX2,y               ; v / 2 in A and the cells ...
    cmp #$80
    ror @
    sta kk_v+3
    lda VX1,y
    ror @
    sta kk_v+2
    lda VX0,y
    ror @
    sta kk_v+1
    lda VXF,y
    ror @
    sta kk_v
    lda kk_v+3              ; ... / 4
    cmp #$80
    ror @
    sta kk_v+3
    ror kk_v+2
    ror kk_v+1
    ror kk_v
    sec
    lda VXF,y
    sbc kk_v
    sta VXF,y
    lda VX0,y
    sbc kk_v+1
    sta VX0,y
    lda VX1,y
    sbc kk_v+2
    sta VX1,y
    lda VX2,y
    sbc kk_v+3
    sta VX2,y
    tya
    bne d
    ldy #VYF-VXF
    bne ax                  ; (always)
d:  jsr chalk_land
    ldx #0
    rts
.endp
    ert VY0-VX0<>VYF-VXF || VY1-VX1<>VYF-VXF || VY2-VX2<>VYF-VXF

; hop_go: after fire_cue -- a miscue's hop: the cue ball in the air for HOP_T ticks
; (AWK $80: tick_all's air path, no cloth)
.proc hop_go
    lda kk_hopr
    beq o
    lda #0
    sta kk_hopr
    lda #$80
    sta AWK
    lda #HOP_T
    sta kk_hopt
o:  rts
.endp

; hop_lift: gstore, the cue (X = 0, A = 0) -> its sprite kk_par of its size up
; (a parabola over the hop's ticks), the rectangle that much taller (the shadow
; stays: NLIFT, draw_all); none when its top is clipped or near the screen's.
; Returns A = 0, X = 0.
.proc hop_lift
    sta NLIFT
    bit AWK
    bpl o
    lda bsy                 ; its top not cut
    cmp syv
    bne o
    ldy kk_hopt
    lda kk_par,y
    ldx dsz
    jsr fmulu               ; k = dsz par / 256
    ldx #0
    lda fmph
    beq o
    sta NLIFT
    clc
    adc #24                 ; room above it (the stored row >= 8 + 16 + k)
    cmp bsy
    bcs n0
    lda bsy
    sbc NLIFT               ; (C = 0 from the bcs: - k - 1 ... C known clear: add it back)
    clc
    adc #1
    sta bsy
    clc
    lda bsh
    adc NLIFT
    sta bsh
    lda #0
    rts
n0: lda #0
    sta NLIFT
o:  lda #0
    rts
.endp

; chalk_draw: every mark onto the clean buffer (set_angle, after rot_draw)
.proc chalk_draw
    ldx kk_chn
    beq out
lp:
    dex
    stx kk_chj
    lda kk_chx0l,x             ; its start on the screen
    ldy kk_chx0h,x
    pha
    lda kk_chy0h,x
    sta by+2
    lda kk_chy0l,x
    sta by+1
    pla
    jsr chpt
    bcs nx
    stx kk_cx0                 ; (chpt: X:Y = x, A = the row)
    sty kk_cx0+1
    sta kk_cy0
    lda od
    sta kk_cod
    ldx kk_chj
    lda kk_chy1h,x             ; its end
    sta by+2
    lda kk_chy1l,x
    sta by+1
    ldy kk_chx1h,x
    lda kk_chx1l,x
    jsr chpt
    bcs nx
    stx kk_cx1
    sty kk_cx1+1
    sta kk_cy1
    jsr chline
nx:
    ldx kk_chj
    bne lp
    lda #$80                ; the window back on bank 0 (the BCBs, as the renderer has it)
    ldy #MA_BSEL
    sta (VB),y
out:
    rts
.endp

; chpt: A:Y = a mark's x (Q4), by+1 / by+2 its y -> X:Y = its screen x, A = the
; row of the cloth under a ball there (pcen's centre + its radius).  C = 1: off.
.proc chpt
    sta bx+1
    sty bx+2
    lda #0
    sta bx
    sta by
    jsr pcen
    bcs o
    lda lcy                 ; (C = 0: the bcs not taken -- 2026-10-28 6502-idioms: no clc)
    adc od
    ldx lcx
    ldy lcx+1
o:  rts
.endp

; chline: (kk_cx0, kk_cy0) -> (kk_cx1, kk_cy1), the steps 8.8: the first 3/8 CH_C0, to 11/16
; CH_C1, the rest CH_C2 one wide (the head 2 wide when the ball there is near)
.proc chline
    sec                     ; dx, |dx|
    lda kk_cx1
    sbc kk_cx0
    sta kk_cdx
    lda kk_cx1+1
    sbc kk_cx0+1
    sta kk_cdx+1
    bpl x1
    sec
    lda #0
    sbc kk_cdx
    sta kk_cax
    lda #0
    sbc kk_cdx+1
    jne d0                  ; (|dx| > 255: no streak is that long)
    beq x2                  ; (always)
x1: jne d0
    lda kk_cdx
    sta kk_cax
x2: sec                     ; dy, |dy|
    lda kk_cy1
    sbc kk_cy0
    sta kk_cdy
    bcs y1
    eor #$FF
    adc #1                  ; (C = 0)
y1: sta kk_cay
    cmp kk_cax                 ; n = max(|dx|, |dy|), >= 1
    bcs n1
    lda kk_cax
n1: tax                     ; (Z from n, not from the cmp)
    bne n2
    lda #1
n2: sta kk_cn
    lsr @                   ; t1 = n/4 + n/8, t2 = n/2 + n/8 + n/16
    lsr @
    sta kk_ct1
    lsr @
    sta kk_ct2                 ; (n/8 for now)
    sec                     ; (+ 1: the first point the head, however short)
    adc kk_ct1
    sta kk_ct1
    lda kk_cn
    lsr @
    clc
    adc kk_ct2
    sta kk_ct2
    lda kk_cn
    lsr @
    lsr @
    lsr @
    lsr @
    clc
    adc kk_ct2
    sta kk_ct2
    lda kk_cax                 ; the steps: |d| 256 / n, the sign back
    jsr cstep
    ldx kk_cdx+1
    jsr csign
    sta kk_cix
    sty kk_cix+1
    stx kk_cixh                ; (x's third byte: its sign)
    lda kk_cay
    jsr cstep
    ldx kk_cdy
    jsr csign
    sta kk_ciy
    sty kk_ciy+1
    lda #$80                ; the sums at the start (+ 1/2: rounded)
    sta kk_cfx
    sta kk_cfy
    lda kk_cx0
    sta kk_cpx
    lda kk_cx0+1
    sta kk_cpx+1
    lda kk_cy0
    sta kk_cpy
    lda #0
    sta kk_ck
pl:
    lda #CH_C0              ; its colour by the step, its width
    ldx #1
    ldy kk_ck
    cpy kk_ct1
    bcc c0
    lda #CH_C1
    cpy kk_ct2
    bcc c0
    lda #CH_C2
    dex                     ; (the tail one wide)
c0: sta kk_chc
    lda kk_cod
    cmp #CH_NEAR
    bcs c1
    ldx #0
c1: stx kk_cwd
    jsr chpx
    lda kk_cwd
    beq c2
    inc kk_cpx                 ; the second pixel to its right
    bne c3
    inc kk_cpx+1
c3: jsr chpx
    lda kk_cpx
    bne c4
    dec kk_cpx+1
c4: dec kk_cpx
c2:
    clc                     ; the next point
    lda kk_cfx
    adc kk_cix
    sta kk_cfx
    lda kk_cpx
    adc kk_cix+1
    sta kk_cpx
    lda kk_cpx+1
    adc kk_cixh
    sta kk_cpx+1
    clc
    lda kk_cfy
    adc kk_ciy
    sta kk_cfy
    lda kk_cpy
    adc kk_ciy+1
    sta kk_cpy
    inc kk_ck
    lda kk_ck
    cmp kk_cn
    bcc pl
    beq pl                  ; (k = 0 .. n)
d0: rts
.endp

; cstep: A = |d| -> A:Y = d 256 / kk_cn (the 8.8 step's fraction, whole), <= 1.0
.proc cstep
    cmp kk_cn                  ; |d| = n: exactly 1
    bcc f
    lda #0
    ldy #1
    rts
f:  sta fd_q+1              ; |d| 256 / n < 256: the fraction
    lda #0
    sta fd_q
    lda kk_cn
    sta fd_dv
    jsr fdiv
    lda fd_q
    ldy #0
    rts
.endp

; csign: A:Y = |step|, X's bit 7 = d's sign -> A:Y = the step, X = its sign byte
.proc csign
    stx kk_csg
    ldx #0
    bit kk_csg
    bpl p
    eor #$FF                ; -(Y:A), 16 bits
    clc
    adc #1
    pha
    tya
    eor #$FF
    adc #0
    tay
    pla
    ldx #$FF
p:  rts
.endp

; chpx: the pixel (kk_cpx, kk_cpy) in the clean buffer -> kk_chc, when it is on the screen
; and cloth (the baize, its shadows' shades: 1, 33, 65, 97)
.proc chpx
    lda kk_cpx+1               ; x 0..319, the row 0..239
    beq x
    cmp #1
    bne o
    lda kk_cpx
    cmp #320-256
    bcs o
x:  ldy kk_cpy
    cpy #240
    bcs o
    lda rowlo,y             ; row * 320 + SCR_OFF + x: the window address, its bank
    adc kk_cpx              ; (C = 0: the bcs not taken -- 2026-10-28 6502-idioms: no clc)
    sta pr+1
    sta pw+1
    lda rowhi,y
    adc kk_cpx+1
    ldx rowbank,y
    cmp #$40                ; past the window's 4 KB: the next bank
    bcc b
    sbc #$10                ; (C = 1)
    inx
b:  sta pr+2
    sta pw+2
    txa
    clc
    adc #$30                ; the clean buffer: 3 x 64 KB above the visible one
    ldy #MA_BSEL
    sta (VB),y
pr  lda WINDOW              ; (patched)
    and #$9F                ; cloth: 1 with any shadow bits
    cmp #1
    bne o
    lda kk_chc
pw  sta WINDOW              ; (patched)
o:  rts
.endp

; the marks (struct of arrays), the ring, the line's cells
kk_chx0l   :CH_N dta 0
kk_chx0h   :CH_N dta 0
kk_chy0l   :CH_N dta 0
kk_chy0h   :CH_N dta 0
kk_chx1l   :CH_N dta 0
kk_chx1h   :CH_N dta 0
kk_chy1l   :CH_N dta 0
kk_chy1h   :CH_N dta 0
kk_chwd    :CH_N dta 0
kk_chi     dta 0               ; the next slot
kk_chn     dta 0               ; marks kept
kk_chj     dta 0
kk_chw     dta 0
kk_chlx    dta 0, 0
kk_chly    dta 0, 0
kk_cht     dta 0
kk_cx0     dta 0, 0
kk_cy0     dta 0
kk_cx1     dta 0, 0
kk_cy1     dta 0
kk_cod     dta 0
kk_cdx     dta 0, 0
kk_cdy     dta 0
kk_cax     dta 0
kk_cay     dta 0
kk_cn      dta 0
kk_ct1     dta 0
kk_ct2     dta 0
kk_cix     dta 0, 0
kk_cixh    dta 0
kk_ciy     dta 0, 0
kk_cfx     dta 0
kk_cfy     dta 0
kk_cpx     dta 0, 0
kk_cpy     dta 0
kk_ck      dta 0
kk_chc     dta 0
kk_cwd     dta 0
kk_csg     dta 0
kk_s0   dta 0               ; $80: the next mark starts at the cue (chalk_land)
kk_hopr dta 0               ; 1: the shot just fired hops (hop_go)
kk_hopt dta 0               ; its ticks left in the air
kk_v    dta 0, 0, 0, 0      ; hop_land: v / 4
NLIFT   :22 dta 0           ; a ball's sprite rows above its shadow (the cue's: hop_lift)
kk_par  dta 0, 25, 48, 70, 90, 108, 125, 140, 154, 166, 176, 185, 192, 198, 202, 204, 205, 204, 202, 198, 192, 185, 176, 166, 154, 140, 125, 108, 90, 70, 48, 25, 0
    ert *-kk_par<>HOP_T+1   ; (0.8 of the ball's size at the top: seen at the table's distance)
