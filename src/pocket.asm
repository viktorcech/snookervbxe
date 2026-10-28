; pocket.asm -- the pocket (cu_mouth): a ball past the cushion line inside a mouth meets
; its back (past the slate edge), the fall (its reach less the pace), or the rounded nose
; (the cushion impact in the nose's normal's frame: cushion.asm cu_go, cuax 2).  The
; pockets after the WPBSA 2005/6 templates (docs: kapsa3.png, kaps.txt): the cushion runs
; straight to the nose's point (corners 108 mm from the corner, middles L/2 +- 75), the
; nose an arc r 76.2 / 79.4 (3", 3.125") back to the slate edge 47.6 behind the line, the
; fall r 44 at the corner / r 53.2 (2.094") centred 41 behind the line.  tick_all calls
; it with the cushion's bank mapped (win_cu); cold: a ball in a mouth.

; cu_mouth: ball X -> C = 1: it dropped.  The pocket's frame: al along the rail from the
; middle's centre line / from the corner, dp behind the line; cum_sg, +1 = $FF where al /
; dp mirror the table's x / y.  Keeps X.
.proc cu_mouth
    stx cub
    ldy #KF_HALF             ; al = x - L/2: the middle when |al| < 75 mm ($04B000)
    lda #0
    jsr cum_x
    lda cum_al+2
    bpl p
    cmp #$FB
    bcc corner
    bne mid
    lda cum_al+1
    cmp #$50
    bcc corner
    bcs mid                 ; (always)
p:
    cmp #$04
    bcc mid
    bne corner
    lda cum_al+1
    cmp #$B0
    bcs corner
mid:
    jsr cum_dpy
    ldy #FALL_M
    ldx #0
    jsr cum_fall
    bcs out
    ldy #NOSE_ML            ; the nearer nose: al < 0 the left one
    lda cum_al+2
    bmi n
    ldy #NOSE_MR
n:
    ldx #0
    jsr cum_nose
    clc
out:
    ldx cub                 ; (the ball back in X; C kept)
    rts
corner:
    ldy #KF_L               ; al = x - L (the right half: al >= 0 above) or -x (the left,
    lda cum_al+2            ;   mirrored)
    bmi cl
    lda #0
    beq r                   ; (always)
cl:
    ldy #KF_0
    lda #$FF
r:
    jsr cum_x
    ldx #0
    jsr cum_past            ; al past the slate edge: the back
    bcs out
    jsr cum_dpy
    ldy #FALL_C
    ldx #3
    jsr cum_fall
    bcs out
    ldy #NOSE_C1            ; the nose nearer: al < dp the x rail's, at (-165, 49)
    lda cum_al+2
    cmp cum_dp+2
    bmi c1
    ldy #NOSE_C2
c1:
    ldx #3
    jsr cum_nose
    bcs hit
    tya                     ; the other one
    eor #NOSE_C1^NOSE_C2
    tay
    ldx #3
    jsr cum_nose
hit:
    clc
    ldx cub
    rts
.endp

; cum_dpy: dp = y - W (the top, y >= 1024 mm) or -y (the bottom, mirrored; a wrap below
; 0 is the bottom), the back (dp past the slate edge) -> out of cu_mouth with C = 1
.proc cum_dpy
    ldy #KF_W
    ldx cub
    lda Y2,x
    cmp #$F0
    bcs b
    cmp #$40
    lda #0
    bcs t
b:
    ldy #KF_0
    lda #$FF
t:
    jsr cum_y
    ldx #3
    jsr cum_past
    bcc ok
    pla                     ; the back: cu_mouth returns C = 1 (its caller's X back)
    pla
    ldx cub
ok:
    rts
.endp

; cum_x / cum_y: cum_al / cum_dp = the ball's x / y less cum_k,y (24-bit), negated when
; A <> 0 (the frame's mirror: A -> cum_sg / +1)
.proc cum_x
    sta cum_sg
    ldx cub
    sec
    lda X0,x
    sbc cum_k,y
    sta cum_al
    lda X1,x
    sbc cum_k+1,y
    sta cum_al+1
    lda X2,x
    sbc cum_k+2,y
    sta cum_al+2
    ldx #0
    ldy #0
    bpl cum_mir             ; (always: cum_al, cum_sg)
.endp
.proc cum_y
    sta cum_sg+1
    ldx cub
    sec
    lda Y0,x
    sbc cum_k,y
    sta cum_dp
    lda Y1,x
    sbc cum_k+1,y
    sta cum_dp+1
    lda Y2,x
    sbc cum_k+2,y
    sta cum_dp+2
    ldx #3
    ldy #1
    ert *<>cum_mir          ; falls in: cum_dp, cum_sg+1
.endp

; cum_mir: cum_al,x (X = 0 / 3) negated when cum_sg,y (Y = 0 / 1)
.proc cum_mir
    lda cum_sg,y
    beq ok
    sec
    lda #0
    sbc cum_al,x
    sta cum_al,x
    lda #0
    sbc cum_al+1,x
    sta cum_al+1,x
    lda #0
    sbc cum_al+2,x
    sta cum_al+2,x
ok:
    rts
.endp

; cum_past: C = cum_al,x (X = 0) / cum_dp (3) > the slate edge, 47.6 mm ($02F99A)
.proc cum_past
    lda cum_al+2,x
    bmi no
    cmp #$02
    bcc no
    bne yes
    lda cum_al+1,x
    cmp #$F9
    bcc no
    bne yes
    lda cum_al,x
    cmp #$9B
    rts
no:
    clc
    rts
yes:
    sec
    rts
.endp

; cum_dist: the point cum_pts,y (ox, oy: 3 + 3, the pocket's frame) less (al, dp) ->
; cum_dx, cum_dy (signed), adx, ady = |.|, mP = d2.  Keeps Y.
.proc cum_dist
    ldx #0
l:
    sec
    lda cum_pts,y
    sbc cum_al,x
    sta cum_dx,x
    sta adx,x
    lda cum_pts+1,y
    sbc cum_al+1,x
    sta cum_dx+1,x
    sta adx+1,x
    lda cum_pts+2,y
    sbc cum_al+2,x
    sta cum_dx+2,x
    bpl p
    sec                     ; |.|
    lda #0
    sbc adx,x
    sta adx,x
    lda #0
    sbc adx+1,x
    sta adx+1,x
    lda #0
    sbc cum_dx+2,x
p:
    sta adx+2,x
    iny
    iny
    iny
    inx
    inx
    inx
    cpx #6
    bne l
    tya
    sbc #6                  ; (C = 1: cpx's equality) Y back to the point
    sta cum_n
    jsr calc_d2             ; (clobbers X, Y)
    ldy cum_n
    rts
.endp

; cum_fall: the fall cum_pts,y, radius cum_fr,x less the pace -> C = 1: the ball's centre
; is over it (d <= r - 2 sp)
.proc cum_fall
    stx cum_t
    jsr cum_dist
    jsr isqrt48             ; root = d
    ldx cub
    lda SP0,x               ; 2 sp
    asl @
    sta cum_dx
    lda SP1,x
    rol @
    sta cum_dx+1
    lda SP2,x
    rol @
    sta cum_dx+2
    ldx cum_t
    sec                     ; r - 2 sp (a borrow: the pace beats the fall)
    lda cum_fr,x
    sbc cum_dx
    sta cum_dx
    lda cum_fr+1,x
    sbc cum_dx+1
    sta cum_dx+1
    lda cum_fr+2,x
    sbc cum_dx+2
    bcc no
    sta cum_dx+2
    lda cum_dx              ; C = (r - 2 sp >= d)
    cmp root
    lda cum_dx+1
    sbc root+1
    lda cum_dx+2
    sbc root+2
no:
    rts
.endp

; cum_nose: the nose cum_pts,y (X = 0 the middle's, 3 a corner's): the ball into it (d2 <=
; (r + R)^2) -> the impact and the ball on it (cu_nose), C = 1; else C = 0.  Keeps Y.
.proc cum_nose
    stx cum_t
    jsr cum_dist
    sty cum_n
    lda cum_t
    asl @
    adc #5                  ; (C = 0: the asl of 0 / 3)
    tax                     ; the 6-byte (r + R)^2, high byte down
    ldy #5
c:
    lda mP,y
    cmp cum_rc2,x
    bcc in
    bne out
    dex
    dey
    bpl c
in:
    ldx #5                  ; K_RX, K_RY = the nose less the ball: (ox - al, oy - dp),
m:                          ;   each negated where the frame mirrors the table
    lda cum_dx,x
    sta cu_kv+K_RX,x
    dex
    bpl m
    ldy #1
    ldx #3
    jsr neg
    ldy #0
    ldx #0
    jsr neg
    jsr cu_nose
    ldy cum_n
    sec
    rts
out:
    ldy cum_n
    clc
    rts
neg:
    lda cum_sg,y
    beq ok
    sec
    lda #0
    sbc cu_kv+K_RX,x
    sta cu_kv+K_RX,x
    lda #0
    sbc cu_kv+K_RX+1,x
    sta cu_kv+K_RX+1,x
    lda #0
    sbc cu_kv+K_RX+2,x
    sta cu_kv+K_RX+2,x
ok:
    rts
.endp

; cu_nose: ball cub at a nose: K_RX, K_RY = its centre less the ball (Q12), cum_rc,cum_t
; its radius + R.  Moving into it: the impact in the frame of its normal (cu_go, cuax 2),
; then the ball put onto the nose, p += d - n (r + R); moving away: nothing
.proc cu_nose
    ldx cub                 ; moving away from it (v . d <= 0): no impact
    lda VX0,x
    sta sA
    lda VX1,x
    sta sA+1
    lda VX2,x
    sta sA+2
    lda cu_kv+K_RX
    sta sB
    lda cu_kv+K_RX+1
    sta sB+1
    lda cu_kv+K_RX+2
    sta sB+2
    jsr smul3r
    lda sP
    sta cum_dx
    lda sP+1
    sta cum_dx+1
    lda sP+2
    sta cum_dx+2
    ldx cub
    lda VY0,x
    sta sA
    lda VY1,x
    sta sA+1
    lda VY2,x
    sta sA+2
    lda cu_kv+K_RY
    sta sB
    lda cu_kv+K_RY+1
    sta sB+1
    lda cu_kv+K_RY+2
    sta sB+2
    jsr smul3r
    clc
    lda sP
    adc cum_dx
    sta cum_dx
    lda sP+1
    adc cum_dx+1
    sta cum_dx+1
    lda sP+2
    adc cum_dx+2
    bmi away
    ora cum_dx+1
    ora cum_dx
    beq away
    lda #K_RC
    sta cud
    lda #K_RY
    sta cuyy
    ldx #K_RX
    ldy #K_RY
    jsr cu_unit             ; K_RC, K_RS = (c, s), the unit vector into the nose
    lda #2
    ldx cub
    jsr cu_go
    ldx cum_t
    lda cum_rc,x
    sta sB
    lda cum_rc+1,x
    sta sB+1
    lda cum_rc+2,x
    sta sB+2
    ldx #K_RC               ; x: d - c (r + R) onto X; y: d - s (r + R) onto Y
    jsr axis
    ldx cub
    clc
    lda X0,x
    adc cum_dx
    sta X0,x
    lda X1,x
    adc cum_dx+1
    sta X1,x
    lda X2,x
    adc cum_dx+2
    sta X2,x
    ldx #K_RS
    jsr axis
    ldx cub
    clc
    lda Y0,x
    adc cum_dx
    sta Y0,x
    lda Y1,x
    adc cum_dx+1
    sta Y1,x
    lda Y2,x
    adc cum_dx+2
    sta Y2,x
away:
    rts
axis:
    lda cu_kv,x
    sta sA
    lda cu_kv+1,x
    sta sA+1
    lda cu_kv+2,x
    sta sA+2
    stx cum_t
    jsr smul3r              ; sP = n (r + R)
    ldx cum_t
    sec
    lda cu_kv+K_RX-K_RC,x
    sbc sP
    sta cum_dx
    lda cu_kv+K_RX-K_RC+1,x
    sbc sP+1
    sta cum_dx+1
    lda cu_kv+K_RX-K_RC+2,x
    sbc sP+2
    sta cum_dx+2
    rts
.endp

; the frames' origins (Q12): L/2, L, W, 0
KF_HALF  = 0
KF_L     = 3
KF_W     = 6
KF_0     = 9
cum_k   dta $00, $88, $6F,  $00, $10, $DF,  $00, $20, $6F,  $00, $00, $00
; the pockets' points (the pocket's frame, Q12): the fall's centre, the noses' centres
FALL_M  = 0
NOSE_ML = 6
NOSE_MR = 12
FALL_C  = 18
NOSE_C1 = 24
NOSE_C2 = 30
cum_pts dta $00, $00, $00,  $00, $90, $02       ; the middle's fall: (0, 41)
        dta $00, $08, $F8,  $33, $AB, $03       ; its noses: (-127.5, 58.7), (127.5, 58.7)
        dta $00, $F8, $07,  $33, $AB, $03
        dta $00, $00, $00,  $00, $00, $00       ; a corner's fall: (0, 0)
        dta $00, $A8, $F5,  $00, $10, $03       ; its noses: (-165.5, 49), (49, -165.5)
        dta $00, $10, $03,  $00, $A8, $F5
cum_fr  dta $33, $53, $03,  $00, $C0, $02       ; the falls' radii: 53.2 (2.094"), 44
cum_rc  dta $66, $9A, $06,  $33, $67, $06       ; the noses' r + R: 105.65, 102.45
cum_rc2 dta $A4, $E0, $E6, $99, $2B, $00        ; and squared
        dta $29, $14, $FE, $FF, $28, $00
cum_al  dta 0, 0, 0                             ; the ball in the pocket's frame
cum_dp  dta 0, 0, 0
cum_sg  dta 0, 0                                ; al / dp mirrored
cum_dx  dta 0, 0, 0                             ; a point less the ball; 2 sp, r - 2 sp
cum_dy  dta 0, 0, 0
cum_t   dta 0                                   ; (temps)
cum_n   dta 0
cuw     :NB*4 dta 0                             ; cushion.asm: per ball w (Q9), the tick it was set at
