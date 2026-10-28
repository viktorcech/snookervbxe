; aimline.asm -- the vector aim line (DDA, CPU pixel-plotted).

; ==========================================================================
; AIM LINE (vector, pixel-plotted into the visible buffer)
; ==========================================================================
; calc_linelen: the aim line reaches as far as the table needs: linelen =
; 2047 mm and line_calc takes it up to 2.0 times (to the first ball or the
; cushion); the power shows IN it: lpf = the charged fraction 0..255 (0 when
; not charging) -> line_dda paints that share of the line, from the cue, blue.
.proc calc_linelen
    lda #$00                    ; linelen = $7FF000 (2047 mm, the largest signed step)
    sta linelen
    lda #$F0
    sta linelen+1
    lda #$7F
    sta linelen+2
    lda charging
    beq none
    sec                         ; x = (pwr - PWR_MIN) >> 8 (hi 0 / 1 : lo in X), lpf =
    lda pwr+1                   ;   min(255, 11/16 x): the range $1799A is 377 of them;
    sbc #>PWR_MIN               ;   11/16 x = x - x/4 - x/16
    tax
    lda pwr+2
    sbc #PWR_MIN>>16
    sta lpf                     ; hi, for the moment
    lsr @                       ; C = hi, A = 0
    txa
    ror @
    lsr @                       ; x/4 (<= 94)
    sta nt
    lsr @
    lsr @                       ; x/16
    clc
    adc nt
    sta nt                      ; t = x/4 + x/16
    txa                         ; lo - t: hi = 1 without a borrow is 256 up -> 255; with one
    sec                         ;   the byte IS 256 + lo - t; hi = 0 never borrows
    sbc nt
    ldy lpf
    beq none
    bcc none
    lda #255
none:
    sta lpf
    rts
.endp

; lct: the axis X (0: x, 3: y -- lsx / lsy, ltx / lty are 3 apart; Y = 0 / $60:
; X0.. / Y0.. are $60 apart) -> lt(X) = t (3, Q16 of the step) to the rail the
; step ls(X) heads for, capped at 2.0 ($020000) -- also for a zero step.
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- one routine for both axes (was the
;  LCT macro twice, 354 bytes); the step's sign by bpl (no jmp)]
.proc lct
    lda lsx+2,x
    bmi neg
    ora lsx+1,x
    ora lsx,x
    jeq cap
    sec                         ; diff = rail - pos
    lda lct_r,x
    sbc X0,y
    sta mA+2
    lda lct_r+1,x
    sbc X1,y
    sta mA+3
    lda lct_r+2,x
    sbc X2,y
    sta mA+4
    lda lsx,x
    sta mB
    lda lsx+1,x
    sta mB+1
    lda lsx+2,x
    sta mB+2
    bpl dv                      ; (always: the step is positive here)
neg:
    sec                         ; diff = pos - R
    lda X0,y
    sbc #$00
    sta mA+2
    lda X1,y
    sbc #$A4
    sta mA+3
    lda X2,y
    sbc #$01
    sta mA+4
    sec                         ; mB = |step|
    lda #0
    sbc lsx,x
    sta mB
    lda #0
    sbc lsx+1,x
    sta mB+1
    lda #0
    sbc lsx+2,x
    sta mB+2
dv:
    lda mB                      ; diff >= 2 |step| -> t >= 2.0: capped
    asl @
    sta mtmp
    lda mB+1
    rol @
    sta mtmp+1
    lda mB+2
    rol @                       ; (2 |step| <= $FFE000: no carry out)
    cmp mA+4
    bcc cap
    bne div
    lda mtmp+1
    cmp mA+3
    bcc cap
    bne div
    lda mtmp
    cmp mA+2
    bcc cap
    beq cap
div:
    lda #0                      ; t = floor(diff << 16 / |step|) < 2.0
    sta mA
    sta mA+1
    sta mA+5
    stx lctx                    ; (div24 clobbers X)
    jsr div24
    ldx lctx
    lda mQ
    sta ltx,x
    lda mQ+1
    sta ltx+1,x
    lda mQ+2
    sta ltx+2,x
    rts
cap:
    lda #0
    sta ltx,x
    sta ltx+1,x
    lda #2
    sta ltx+2,x
    rts
.endp
lct_r                           ; the high rails, Q12: L - R, W - R
    dta <$DD6C00, >$DD6C00, ^$DD6C00, <$6D7C00, >$6D7C00, ^$6D7C00

; GSTEP: :1 = dir (Q16), :2-:4 = ball 0's position bytes -> :5 = cue + the
; step along :1 for gbest (Q8 mm): ((gbest * dir) >> 16) << 4 (Q12)
.macro GSTEP
    lda gbest
    sta sA
    lda gbest+1
    sta sA+1
    lda gbest+2
    sta sA+2
    lda :1
    sta sB
    lda :1+1
    sta sB+1
    lda :1+2
    sta sB+2
    jsr smul3r
    ldx #4
sh
    asl sP
    rol sP+1
    rol sP+2
    dex
    bne sh
    clc
    lda :2
    adc sP
    sta :5
    lda :3
    adc sP+1
    sta :5+1
    lda :4
    adc sP+2
    sta :5+2
.endm

; DQ8: :1-:3 = position byte arrays -> :4 = (ball X - ball 0) >> 4 (Q8, signed 3).  Keeps X.
; [2026-10-28 6502-idioms/SKILL.md: compute in A, store once -- no 4 x ror of 3 bytes in
;  memory; 6502-loops-tables-smc/SKILL.md: tables beat arithmetic -- each byte of d >> 4 is
;  shr4[its byte] | x16[the next byte & $0F]; the top takes the 25th bit (0 / $F0)]
.macro DQ8
    sec
    lda :1,x
    sbc :1
    tay                         ; d0
    lda shr4,y
    sta :4
    lda :2,x
    sbc :2
    tay                         ; d1
    lda shr4,y
    sta :4+1
    tya
    and #$0F
    tay
    lda x16,y
    ora :4
    sta :4
    lda :3,x
    sbc :3
    tay                         ; d2
    lda #0                      ; the 25th bit: the borrow -> 0 / $F0
    sbc #0
    and #$F0
    ora shr4,y
    sta :4+2
    tya
    and #$0F
    tay
    lda x16,y
    ora :4+1
    sta :4+1
.endm

; line_calc: project the cue (start) and a point LINELEN = 600mm ahead along
; the aim direction (end) into screen coords lx0,ly0 / nlx1,nly1.
; The far point is kept ON the playfield by shortening it ALONG THE RAY:
; if an axis crosses its rail, t_axis = (rail-cue)<<16 / |step| (Q16), then
; far = cue + step*min(tx,ty,1.0) recomputed on BOTH axes -- the line never
; bends, it just stops at the cushion.  (The old per-axis clamp + 1300mm far
; point pointed the line the WRONG WAY once the cue parked deep in the table:
; x wrapped 24 bits past 4096mm / the xrow index wrapped past 223 -- the
; 'second shot goes backwards' bug.)  Validated in sim/_ref_aimline2.py.
.proc line_calc
    lda aiming
    bne lc1
    rts
lc1:
    jsr cam_d                   ; the cue -> bx, by
    lda #$10
    sta sprbank
    jsr pcen                    ; the line starts at the ball's centre
    lda #0
    rol @
    sta lcut                    ; (off the screen: cut at the edge below)
    lda lcx
    sta lx0
    lda lcx+1
    sta lx0+1
    lda lcy
    sta ly0
    ; step x = (LINELEN * dirx) >> 16 -> lsx   (LINELEN = $258000 = 600mm)
    lda linelen
    sta sA
    lda linelen+1
    sta sA+1
    lda linelen+2
    sta sA+2
    jsr mul_dx
    lda sP
    sta lsx
    lda sP+1
    sta lsx+1
    lda sP+2
    sta lsx+2
    ; step y = (LINELEN * diry) >> 16 -> lsy
    lda linelen
    sta sA
    lda linelen+1
    sta sA+1
    lda linelen+2
    sta sA+2
    jsr mul_dy
    lda sP
    sta lsy
    lda sP+1
    sta lsy+1
    lda sP+2
    sta lsy+2
    ; t per axis = (the distance to the rail the step heads for) / |step|,
    ; capped at 2.0 (2 x 2047 mm: every rail is in reach); t = min(tx, ty)
    ldx #0                      ; x
    ldy #0
    jsr lct
    ldx #lsy-lsx                ; y
    ldy #Y0-X0
    jsr lct
    lda lty+2
    cmp ltx+2
    bcc takey
    bne tdone
    lda lty+1
    cmp ltx+1
    bcc takey
    bne tdone
    lda lty
    cmp ltx
    bcs tdone
takey:
    lda lty
    sta ltx
    lda lty+1
    sta ltx+1
    lda lty+2
    sta ltx+2
tdone:
    ; far = cue + (step * t) >> 16 on BOTH axes (keeps the true direction)
    lda lsx
    sta sA
    lda lsx+1
    sta sA+1
    lda lsx+2
    sta sA+2
    lda ltx
    sta sB
    lda ltx+1
    sta sB+1
    lda ltx+2
    sta sB+2
    jsr smul3r
    clc
    lda X0
    adc sP
    sta bx
    lda X1
    adc sP+1
    sta bx+1
    lda X2
    adc sP+2
    sta bx+2
    lda lsy
    sta sA
    lda lsy+1
    sta sA+1
    lda lsy+2
    sta sA+2
    lda ltx
    sta sB
    lda ltx+1
    sta sB+1
    lda ltx+2
    sta sB+2
    jsr smul3r
    clc
    lda Y0
    adc sP
    sta by
    lda Y1
    adc sP+1
    sta by+1
    lda Y2
    adc sP+2
    sta by+2
    jsr segbox                  ; the box a ball must touch to be in the way
    jsr ghost                   ; the first ball on the way -> lgh, gbest (Q8 along), ghj
    lda lgh
    jeq shortdone
hit:
    ; far = G, the cue's centre at the contact: cue + ((gbest * dir) >> 16) << 4
    GSTEP dirx, X0, X1, X2, bx
    GSTEP diry, Y0, Y1, Y2, by
shortdone:
    lda bx                      ; (the far end G, kept for the object line)
    sta ggx
    lda bx+1
    sta ggx+1
    lda bx+2
    sta ggx+2
    lda by
    sta ggy
    lda by+1
    sta ggy+1
    lda by+2
    sta ggy+2
    jsr pcen
    bcc farin
    lda lcut                    ; both ends off the screen: no line
    bne nol
    jsr farcut                  ; past the screen (zoomed in): the line runs to its edge
farin:
    lda lcx
    sta nlx1
    lda lcx+1
    sta nlx1+1
    lda lcy
    sta nly1
    lda lcut
    beq stin
    jsr cuecut                  ; the cue off the screen: the line starts at its edge
    lda lcx
    sta lx0
    lda lcx+1
    sta lx0+1
    lda lcy
    sta ly0
stin:
    lda #0
    sta lob
    lda lgh
    beq nob
    jmp objline                 ; where the hit ball goes
nol:
    lda #0                      ; no point of the line on the screen: none this frame
    sta aiming
nob:
    rts
.endp

; farcut / cuecut: one end of the segment cue..far is off the screen ->
; the point nearest it that is on, by bisection on the end points: A (ltx,
; lty) on the screen, B (lsx, lsy) off; 8 times M = (A + B) / 2 replaces A or
; B.  Ends with pcen of A (C = 0, lcx / lcy).  farcut: A = the cue, B = the
; far end (bx, by); the hit ball is past the screen, so no ghost and no object
; line (lgh = 0).  cuecut: A = the far end (bx, by), B = the cue.
.macro MID24            ; (:1 + :2) >> 1 -> :3, the 25th bit rotated in
    clc
    lda :1
    adc :2
    sta :3
    lda :1+1
    adc :2+1
    sta :3+1
    lda :1+2
    adc :2+2
    ror @
    sta :3+2
    ror :3+1
    ror :3
.endm
.macro COPY24           ; :1 -> :2 (:1 given as three cells :1, :3, :4)
    lda :1
    sta :2
    lda :3
    sta :2+1
    lda :4
    sta :2+2
.endm

.proc farcut
    lda #0
    sta lgh
    COPY24 X0, ltx, X1, X2
    COPY24 Y0, lty, Y1, Y2
    COPY24 bx, lsx, bx+1, bx+2
    COPY24 by, lsy, by+1, by+2
    jmp bisect
.endp

.proc cuecut
    COPY24 bx, ltx, bx+1, bx+2
    COPY24 by, lty, by+1, by+2
    COPY24 X0, lsx, X1, X2
    COPY24 Y0, lsy, Y1, Y2
    ert *<>bisect           ; falls into the bisection
.endp

.proc bisect
    lda #8
    sta gtry
bis:
    MID24 ltx, lsx, bx
    MID24 lty, lsy, by
    jsr pcen
    bcs no
    COPY24 bx, ltx, bx+1, bx+2  ; M on the screen: A = M
    COPY24 by, lty, by+1, by+2
    jmp nx
no:
    COPY24 bx, lsx, bx+1, bx+2  ; off it: B = M
    COPY24 by, lsy, by+1, by+2
nx:
    dec gtry
    jne bis
    COPY24 ltx, bx, ltx+1, ltx+2
    COPY24 lty, by, lty+1, lty+2
    ert *<>pcen             ; A: on the screen (C = 0)
.endp

; pcen: the table point (bx, by) -> its centre on the screen lcx (16), lcy:
; the projected sprite's corner + dsz / 2.  C = 1: out of the view's range or
; off the 320 x 240 screen (line_dda draws only on it).
.proc pcen
    jsr rot_view
    jsr project
    bcs out
    lda dsz
    lsr @
    sta od
    clc                     ; (dsz is odd: the lsr left C = 1)
    adc sx
    sta lcx
    tax
    lda sx+1
    adc #0
    sta lcx+1
    bmi off                 ; x < 0
    beq xok
    cmp #1                  ; 256..319
    bne off
    cpx #320-256
    bcs off
xok:
    clc                     ; row = syvh:syv + od - ROW_BIAS, 0..239
    lda syv
    adc od
    tax
    lda syvh
    adc #0
    bne off
    txa
    sec
    sbc #ROW_BIAS
    bcc off
    cmp #240
    bcs off
    sta lcy
    rts                     ; (C = 0)
off:
    sec
out:
    rts
.endp

; gbox: the cue's segment (cue .. far, Q4 mm = the X2:X1 / Y2:Y1 bytes)
; widened by 2R (840) on every side -> gx0..gx1, gy0..gy1: a ball centre
; outside cannot touch the segment.
; [2026-10-12 fable-skill-atari/SKILL.md 3: place each rejection by what it needs -- four
;  16-bit compares per ball before its four multiplies]
; segbox: the box a ball must touch to be on the cue's segment, Q4 mm (the
; mid / high bytes): per axis lo = min(cue, far) - 840 (floored at 0), hi =
; max(cue, far) + 840 -> gx0 / gx1, gy0 / gy1.  Clobbers X, Y.
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- one body for both axes (was the
;  GBOX macro twice); the far point's two bytes copied into gfr so that X (gx / gy: 4
;  apart) and Y (X1 / Y1: $60 apart) carry the rest]
.proc segbox
    lda by+1                ; y
    sta gfr
    lda by+2
    sta gfr+1
    ldx #gy0-gx0
    ldy #Y1-X1
    jsr gbox
    lda bx+1                ; x
    sta gfr
    lda bx+2
    sta gfr+1
    ldx #0
    ldy #0
    ert *<>gbox             ; falls into the axis
.endp
.proc gbox                  ; X = 0 / 4 (the outputs), Y = 0 / $60 (the cue's bytes), gfr = the far's
    lda X1+$20,y            ; (X2 / Y2)
    cmp gfr+1
    bcc gcue
    bne gfar
    lda X1,y
    cmp gfr
    bcc gcue
gfar:
    lda gfr                 ; far <= cue: lo = far, hi = cue
    sta gx0,x
    lda gfr+1
    sta gx0+1,x
    lda X1,y
    sta gx1,x
    lda X1+$20,y
    sta gx1+1,x
    jmp wd
gcue:
    lda X1,y                ; cue < far: lo = cue, hi = far
    sta gx0,x
    lda X1+$20,y
    sta gx0+1,x
    lda gfr
    sta gx1,x
    lda gfr+1
    sta gx1+1,x
wd:
    sec                     ; lo -= 840 (floored at 0) ; hi += 840
    lda gx0,x
    sbc #<840
    sta gx0,x
    lda gx0+1,x
    sbc #>840
    sta gx0+1,x
    bcs lok
    lda #0
    sta gx0,x
    sta gx0+1,x
lok:
    clc
    lda gx1,x
    adc #<840
    sta gx1,x
    lda gx1+1,x
    adc #>840
    sta gx1+1,x
    rts
.endp

; ghost: the first object ball the cue would hit on its way (along the aim,
; within the reach to the cushion): per ball on the table, in Q8 mm --
;   d = (ball - cue) >> 4 ; perp = d x dir ; along = d . dir
;   |perp| < 2R and along > 0 -> contact at tc = along - sqrt(4R^2 - perp^2)
; the smallest tc is taken -> lgh = 1, gbest = tc, ghj = the ball.  2R = 13440 (Q8).
.proc ghost
    lda #0
    sta lgh
    sta sA                      ; the reach = (2047 mm Q8 * t) >> 16
    lda #$FF
    sta sA+1
    lda #$07
    sta sA+2
    lda ltx
    sta sB
    lda ltx+1
    sta sB+1
    lda ltx+2
    sta sB+2
    jsr smul3r
    lda sP
    sta gbest
    lda sP+1
    sta gbest+1
    lda sP+2
    sta gbest+2
; [2026-10-28 6502-idioms/SKILL.md: no RAM cell for a value that only waits -- the ball stays
;  in X through the cheap rejects (gjx only for one that passes the box); 6502-mads/SKILL.md:
;  an out-of-range jcc pays a taken branch -- the rejects' target is in range]
    ldx #1
    bne bl                      ; (always)
nx:
    ldx gjx
nxr:
    inx
    cpx #NB
    bcc bl
    rts
bl:
    lda BON,x
    beq nxr
    lda X1,x                    ; outside the box -> cannot be in the way
    cmp gx0
    lda X2,x
    sbc gx0+1
    bcc nxr
    lda gx1
    cmp X1,x
    lda gx1+1
    sbc X2,x
    bcc nxr
    lda Y1,x
    cmp gy0
    lda Y2,x
    sbc gy0+1
    bcc nxr
    lda gy1
    cmp Y1,x
    lda gy1+1
    sbc Y2,x
    bcc nxr
    stx gjx
    DQ8 X0, X1, X2, gdx         ; d = (ball - cue) >> 4, Q8 signed
    DQ8 Y0, Y1, Y2, gdy
    lda gdy                     ; perp = dy*cx - dx*cy
    sta sA
    lda gdy+1
    sta sA+1
    lda gdy+2
    sta sA+2
    jsr mul_dx
    lda sP
    sta gpp
    lda sP+1
    sta gpp+1
    lda sP+2
    sta gpp+2
    lda gdx
    sta sA
    lda gdx+1
    sta sA+1
    lda gdx+2
    sta sA+2
    jsr mul_dy
    sec
    lda gpp
    sbc sP
    sta gpp
    lda gpp+1
    sbc sP+1
    sta gpp+1
    lda gpp+2
    sbc sP+2
    bpl pp                      ; |perp|
    sta gpp+2
    sec
    lda #0
    sbc gpp
    sta gpp
    lda #0
    sbc gpp+1
    sta gpp+1
    lda #0
    sbc gpp+2
pp:
    sta gpp+2
    jne nx                      ; |perp| >= 2R ($003480) -> misses
    lda gpp+1
    cmp #$34
    bcc near
    jne nx
    lda gpp
    cmp #$80
    jcs nx
near:                           ; along = dx*cx + dy*cy
; [2026-10-28 6502-idioms/SKILL.md: use what a routine already produced -- sA still holds dx
;  from perp's mul_dy (smul3r only reads sA)]
    jsr mul_dx
    lda sP
    sta gal
    lda sP+1
    sta gal+1
    lda sP+2
    sta gal+2
    lda gdy
    sta sA
    lda gdy+1
    sta sA+1
    lda gdy+2
    sta sA+2
    jsr mul_dy
    clc
    lda gal
    adc sP
    sta gal
    lda gal+1
    adc sP+1
    sta gal+1
    lda gal+2
    adc sP+2
    sta gal+2
    jmi nx                      ; behind the cue
    ora gal+1
    ora gal
    jeq nx
    lda gpp                     ; back = sqrt(4R^2 - perp^2): perp^2 -> mP
    sta mA
    sta mB
    lda gpp+1
    sta mA+1
    sta mB+1
    lda #0
    sta mA+2
    sta mB+2
    jsr mul48
    sec                         ; mP = $0AC44000 - perp^2 (13440^2)
    lda #$00
    sbc mP
    sta mP
    lda #$40
    sbc mP+1
    sta mP+1
    lda #$C4
    sbc mP+2
    sta mP+2
    lda #$0A
    sbc mP+3
    sta mP+3
    lda #0
    sta mP+4
    sta mP+5
    jsr isqrt48                 ; root = back
    sec                         ; tc = along - back (>= 0)
    lda gal
    sbc root
    sta gal
    lda gal+1
    sbc root+1
    sta gal+1
    lda gal+2
    sbc root+2
    sta gal+2
    bcs tcp
    lda #0
    sta gal
    sta gal+1
    sta gal+2
tcp:                            ; (A = gal+2 from either way in)
    cmp gbest+2                 ; tc < gbest -> the nearest so far
    bcc best
    bne gnx
    lda gal+1
    cmp gbest+1
    bcc best
    bne gnx
    lda gal
    cmp gbest
    bcs gnx
best:
    lda gal
    sta gbest
    lda gal+1
    sta gbest+1
    lda gal+2
    sta gbest+2
    lda gjx
    sta ghj
    lda #1
    sta lgh
gnx jmp nx
.endp

; objline: the hit ball's way: from its centre O along O - G (the line of
; centres at the contact, 2R long) times 8 (420 mm), halved until the end
; stays on the bed -> screen ox0, oy0 / ox1, oy1, lob = 1 (0: none).
.proc objline
    ldx ghj
    sec                         ; v = O - G (Q12)
    lda X0,x
    sbc ggx
    sta gvx
    lda X1,x
    sbc ggx+1
    sta gvx+1
    lda X2,x
    sbc ggx+2
    sta gvx+2
    sec
    lda Y0,x
    sbc ggy
    sta gvy
    lda Y1,x
    sbc ggy+1
    sta gvy+1
    lda Y2,x
    sbc ggy+2
    sta gvy+2
    ldy #3                      ; v * 8
sh:
    asl gvx
    rol gvx+1
    rol gvx+2
    asl gvy
    rol gvy+1
    rol gvy+2
    dey
    bne sh
    lda #4                      ; tries: 8, 4, 2, 1 times 2R
    sta gtry
try:
    ldx ghj
    clc                         ; E = O + v: on the bed? (no 24-bit wrap, R..L-R)
    lda X0,x
    adc gvx
    sta bx
    lda X1,x
    adc gvx+1
    sta bx+1
    lda X2,x
    adc gvx+2
    sta bx+2
    lda gvx+2
    bmi xn
    bcs half
    bcc xhi                     ; (always)
xn:
    bcc half
xhi:
    lda bx+2                    ; R <= x <= L-R
    cmp #$01
    bcc half
    bne xr1
    lda bx+1
    cmp #$A4
    bcc half
xr1:
    lda bx+2
    cmp #$DD
    bcc yy
    bne half
    lda bx+1
    cmp #$6C
    bcs half
yy:
    clc
    lda Y0,x
    adc gvy
    sta by
    lda Y1,x
    adc gvy+1
    sta by+1
    lda Y2,x
    adc gvy+2
    sta by+2
    lda gvy+2
    bmi yn
    bcs half
    bcc yhi                     ; (always)
yn:
    bcc half
yhi:
    lda by+2
    cmp #$01
    bcc half
    bne yr1
    lda by+1
    cmp #$A4
    bcc half
yr1:
    lda by+2
    cmp #$6D
    bcc okp
    bne half
    lda by+1
    cmp #$7C
    bcc okp
half:
    lda gvx+2                   ; v /= 2 (arithmetic), try again
    cmp #$80
    ror gvx+2
    ror gvx+1
    ror gvx
    lda gvy+2
    cmp #$80
    ror gvy+2
    ror gvy+1
    ror gvy
    dec gtry
    jne try
    rts                         ; the ball sits on a cushion: no line (lob = 0)
okp:
    jsr pcen                    ; E -> ox1, oy1
    bcs out                     ; (off the screen: no line, lob = 0)
    lda lcx
    sta ox1
    lda lcx+1
    sta ox1+1
    lda lcy
    sta oy1
    ldx ghj                      ; O -> ox0, oy0
    jsr ball_b
    jsr pcen
    bcs out
    lda lcx
    sta ox0
    lda lcx+1
    sta ox0+1
    lda lcy
    sta oy0
    lda #1
    sta lob
out:
    rts
.endp


; OPT aim line.  draw_line runs the DDA once and RECORDS every pixel's window
; address + visible-bank selector in lbuf_lo/hi/sel and the pixel it covered
; in lbuf_px (save-under); erase_line writes those pixels back in reverse
; order -- no second DDA, no clean-buffer read, and the balls under the line
; come back too, so a moving aim line never forces a ball redraw.  Valid
; because nothing else draws between a line's draw and its erase while
; aiming (balls asleep); when balls move the line is erased before they are.
.proc draw_line
    ldx #1                      ; one pixel record for both lines, indices 1..255
    stx lidx                    ; (0 = the record is full; erase_line stops at 1)
    lda lpf                     ; the cue's line: the power share blue
    sta lpfd
    lda nlx1
    sta lex
    lda nlx1+1
    sta lex+1
    lda nly1
    sta ley
    jsr line_dda
    lda lob                     ; the hit ball's way (white)
    beq one
    lda lidx
    beq one                     ; (the record is full)
    lda #0
    sta lpfd
    lda ox0
    sta lx0
    lda ox0+1
    sta lx0+1
    lda oy0
    sta ly0
    lda ox1
    sta lex
    lda ox1+1
    sta lex+1
    lda oy1
    sta ley
    jsr line_dda
one:
    lda nlx1
    sta olx1
    lda nlx1+1
    sta olx1+1
    lda nly1
    sta oly1
    lda lpf                     ; the power share drawn
    sta opf
    lda lob                     ; the hit ball's line drawn (main compares it)
    sta dlob
    lda ox1
    sta dox1
    lda ox1+1
    sta dox1+1
    lda oy1
    sta doy1
    lda #1
    sta lshown
    rts
.endp

.proc erase_line
    lda #0                      ; no valid selector is 0 -> first pixel selects
    sta el+1
    ldx osteps                  ; saved pixels osteps..1 -> visible buffer, last drawn first
; [2026-10-21 6502-loops-tables-smc/SKILL.md: patch an absolute operand instead of (zp),y --
;  the pixel's window address; 6502-cycles-layout/SKILL.md: the rare case (a new bank) out of line]
pb:
    lda lbuf_sel,x
el  cmp #0                      ; (patched: the last MA_BSEL written)
    bne ns
pb1:
    lda lbuf_lo,x
    sta pw+1
    lda lbuf_hi,x
    sta pw+2
    lda lbuf_px,x
pw  sta WINDOW              ; (patched: the pixel's window address)
    dex
    bne pb                      ; (index 0 is never a pixel: osteps >= 1)
    stx lshown                  ; X = 0
    rts
ns:
    sta el+1
    ldy #MA_BSEL
    sta (VB),y
    bne pb1                     ; (always: Y = MA_BSEL)
.endp

; div9: mQ(2) = round((n << 8) / lsteps), n = A:X (16-bit).  Requires
; n <= 319, n < 2*lsteps, lsteps >= 1 (true: lsteps = max(|dx|,|dy|) or 255
; with |dx| <= 319) -- then the quotient is < 512 and the remainder n>>1 (< B)
; can be PRELOADED: 9 restoring steps over an 8-bit remainder instead of
; div24's 24 steps over 32 bits.  A 1 shifted out of the remainder means
; rem >= 256 > B: subtract without comparing.  Rounding = divr's (ties up).
; Bit-identical to divr(n<<8, lsteps): asm_bench --micro line_dda.
.proc div9
    lsr                     ; C = n bit 8 (hi >> 1 is 0: n <= 319)
    txa
    ror                     ; A = n >> 1 = remainder preload, C = n bit 0
    rol                     ; rem = rem*2 + bit ; C = rem bit 8
    bcs s1
    cmp lsteps
    bcc n1
s1:
    sbc lsteps              ; C = 1 on both paths in
    ldx #1                  ; quotient bit 8
    bne l8                  ; always
n1:
    ldx #0
l8:
    stx mQ+1
    ldx #8
lp:
    asl                     ; rem*2 (the 8 low bits of n<<8 are 0) ; C = bit 8
    bcs sub
    cmp lsteps
    bcc nsub                ; C = 0 -> quotient bit 0
sub:
    sbc lsteps              ; rem - B < B <= 255 fits ; the bit-8 path may clear C
    sec                     ; quotient bit 1
nsub:
    rol mQ
    dex
    bne lp
    asl                     ; 2*rem >= B -> round up  (C = bit 8 of 2*rem)
    bcs up
    cmp lsteps
    bcc done
up:
    inc mQ
    bne done
    inc mQ+1
done:
    rts
.endp

; line_dda: plot a WHITE line from (lx0,ly0) to (lex,ley) into the visible
; buffer and record the pixels for erase_line.  Zero-page DDA state; the y
; accumulator is 16-bit (rows 0..239 never leave 0..$EFFF, so the low 16 bits
; of the old 24-bit add are the same); the pixel address comes from the
; rowlo/rowhi/rowbank tables (row*320 split into bank + 12-bit offset) with
; a single compare for the x carry into the next bank.
.proc line_dda
    sec                         ; dx = lex - lx0 ; |dx| -> ldxv, sign lsgnx
    lda lex
    sbc lx0
    sta ldxv
    lda lex+1
    sbc lx0+1
    sta ldxv+1
; [2026-10-28 6502-idioms/SKILL.md: sec / sbc with C known clear -> the -1 in the literal
;  (the bpl not taken: dx borrowed, C = 0: 1 - x - 1 = 0 - x, the same carry); jmp with a flag
;  known -> the branch (|dx| <= 320: N = 0; |dy|, step hi likewise)]
    bpl xp
    lda #1
    sta lsgnx
    sbc ldxv                    ; (A = 1, C = 0)
    sta ldxv
    lda #0
    sbc ldxv+1
    sta ldxv+1
    bpl xd                      ; (always)
xp:
    lda #0
    sta lsgnx
xd:
    sec                         ; dy = ley - ly0 (both 0..239) -> ldyv, sign lsgny
    lda ley
    sbc ly0
    sta ldyv
    lda #0
    sbc #0
    sta ldyv+1
    bpl yp
    lda #1
    sta lsgny
    sbc ldyv                    ; (A = 1, C = 0)
    sta ldyv
    lda #0
    sbc ldyv+1
    sta ldyv+1
    bpl yd                      ; (always)
yp:
    lda #0
    sta lsgny
yd:
    lda ldxv+1                  ; steps = max(|dx|,|dy|), clamp 255
    ora ldyv+1
    beq sm
    lda #255
    bne havs                    ; always
sm:
    lda ldxv
    cmp ldyv
    bcs havs                    ; A = |dx| >= |dy|
    lda ldyv
havs:
    sta lsteps
    cmp #0                      ; (Z may still be the cmp ldyv result: dx == dy)
    bne sok
    lda #0                      ; zero length -> one pixel at (lx0,ly0): zero steps
    sta lstepx
    sta lstepx+1
    sta lstepx+2
    sta lstepy
    sta lstepy+1
    beq acc                     ; always
sok:
    lda ldxv+1                  ; stepx = round((|dx|<<8)/steps), signed (3-byte)
    ldx ldxv
    jsr div9
    lda lsgnx
    bne sxn
    lda mQ
    sta lstepx
    lda mQ+1
    sta lstepx+1
    lda #0
    sta lstepx+2
    beq sxdn                    ; always
sxn:
    sec
    lda #0
    sbc mQ
    sta lstepx
    lda #0
    sbc mQ+1
    sta lstepx+1
    lda #$FF
    sta lstepx+2
sxdn:
    lda ldyv+1                  ; stepy (16-bit: low bytes of the old 3-byte step)
    ldx ldyv
    jsr div9
    lda lsgny
    bne syn
    lda mQ
    sta lstepy
    lda mQ+1
    sta lstepy+1
    bpl acc                     ; (always: mQ < 512)
syn:
    sec
    lda #0
    sbc mQ
    sta lstepy
    lda #0
    sbc mQ+1
    sta lstepy+1
acc:
    ; the pixels of this line are the record indices lidx .. lidx + lsteps;
    ; the first ((lsteps + 1) * lpfd >> 8) of them are blue: index < the lb operand
    ; (the cue's line starts the record at 1; all of it at 255)
    lda lpfd
    cmp #255
    bne part
    lda lsteps
    clc
    adc #2
    bcc pnb                     ; (lsteps >= 254: a 255th pixel stays white)
    lda #255
    bne pnb
part:
    tax
    lda lsteps
    jsr fmulu                   ; lsteps * lpf
    clc
    lda fmpl
    adc lpfd                    ; + lpfd = (lsteps + 1) * lpfd
    lda fmph
    adc #1                      ; + 1: the record is 1-based (no wrap: < 255)
pnb:
    sta lb+1
    ldy #BLITTER_START          ; the balls under the line must be finished
wbl:                            ; before their pixels are saved
    lda (VB),y
    bne wbl
    lda #0                      ; acc = (lx0,ly0) << 8 ; lidx goes on (draw_line)
    sta laccx
    sta laccy
    sta ls+1                    ; force the first selector write
    lda lx0
    sta laccx+1
    lda lx0+1
    sta laccx+2
    lda ly0
    sta laccy+1
    lda lidx                    ; the end = lidx + lsteps + 1: the index after the
    sec                         ; last pixel; 0 when the record ends first
    adc lsteps                  ; (X wraps to 0 there: the line is cut)
    bcc le
    lda #0
le:
    sta ge+1                    ; [2026-10-28 6502-loops-tables-smc/SKILL.md: a variable as the
    sta xe+1                    ;  operand of cmp # / adc # (2 cycles) -- the end, the blue
    sta ye+1                    ;  share, the selector and the steps patched once a line]
    lda lstepx
    sta gx0+1
    sta yx0+1
    lda lstepx+1
    sta gx1+1
    sta yx1+1
    lda lstepx+2
    sta gx2+1
    sta yx2+1
    lda lstepy
    sta gy0+1
    sta xy0+1
    lda lstepy+1
    sta gy1+1
    sta xy1+1
; the major axis steps exactly one pixel when its |d| is the step count (<= 255:
; div9 made the step $100): its accumulator moves by an inc / dec or +-1 alone.
; [2026-10-21 6502-loops-tables-smc/SKILL.md: patch an opcode / operand to switch behaviour --
;  the pass's tail (jmp), inc / dec, the +-1 operands]
    ldy #<tgen                  ; the pass's tail: generic, x major or y major
    ldx #>tgen
    lda lsteps
    beq tsel                    ; (one pixel: no step)
    cmp ldyv
    bne nym
    lda #$E6                    ; y major: inc laccy+1 / dec laccy+1
    ldx lsgny
    beq yinc
    lda #$C6
yinc:
    sta yo
    ldy #<tym
    ldx #>tym
    bne tsel                    ; (always)
nym:
    cmp ldxv
    bne tsel
    lda ldxv+1                  ; (|dx| > 255: the step was clamped)
    bne tsel
    lda #0                      ; x major: x += 1 / -1 (16 bits): hi 0 / $FF
    ldx lsgnx
    beq xinc
    lda #$FF
xinc:
    sta xh+1
    ora #1                      ; lo 1 / $FF
    sta xi+1
    ldy #<txm
    ldx #>txm
tsel:
    sty tail+1
    stx tail+2
; [2026-10-21 6502-idioms/SKILL.md: no RAM cell for a value that only waits -- the record index
;  stays in X (no ldx / stx lidx a pixel); compute in A, store once -- each address byte goes to
;  wptr and the record together; rowhi / rowbank carry $30 / $B0 (no ora, no visel)]
    ldx lidx                    ; X = the record index for the whole line
; [2026-10-28 6502-mads/SKILL.md: an out-of-range jne pays a taken branch -- the tails txm /
;  tym ahead of ploop, their bne back in range (a pixel 2 cycles less); 6502-idioms: jmp with
;  a flag known -> the branch (wrap, nsel)]
    bne ploop                   ; (always: draw_line's lidx >= 1)
ldone:
    stx lidx
    dex                         ; erase_line replays the pixels osteps .. 1
    stx osteps
    rts
txm:                            ; x major: x (16) += +-1, the fraction stays; y as tgen
    clc
    lda laccx+1
xi  adc #1
    sta laccx+1
    lda laccx+2
xh  adc #0
    sta laccx+2
    clc
    lda laccy
xy0 adc #0
    sta laccy
    lda laccy+1
xy1 adc #0
    sta laccy+1
xe  cpx #0
    bne ploop
    beq ldone                   ; (always)
tym:                            ; y major: x as tgen, the row +-1, the fraction stays
    clc
    lda laccx
yx0 adc #0
    sta laccx
    lda laccx+1
yx1 adc #0
    sta laccx+1
    lda laccx+2
yx2 adc #0
    sta laccx+2
yo  inc laccy+1                 ; (inc / dec, patched)
ye  cpx #0
    bne ploop
    beq ldone                   ; (always)
ploop:
    ldy laccy+1                 ; Y = the row
    clc                         ; row -> window address + x
    lda rowlo,y
    adc laccx+1
    sta wptr
    sta lbuf_lo,x
    lda rowhi,y                 ; $30 + the row's offset hi (0..$0F)
    adc laccx+2                 ; + 0..1 (+ carry)
    cmp #$40
    bcs wrap                    ; (rare: the pixel is in the next 4 KB bank)
    sta wptr+1
    sta lbuf_hi,x
    lda rowbank,y               ; MA_BSEL of the row's bank, $B0 + bank
sel:
    sta lbuf_sel,x
ls  cmp #0                      ; (patched: the last MA_BSEL written)
    bne nsel                    ; (rare: the first pixel, a bank edge)
same:
    ldy #0
    lda (wptr),y                ; save-under
    sta lbuf_px,x
    lda #IDX_LINE               ; the power share of the line (from the cue) is blue
lb  cpx #0                      ; (patched: the first white pixel's index)
    bcs wh
    lda #IDX_POW
wh:
    sta (wptr),y
    inx
tail:
    jmp tgen                    ; (patched: tgen / txm / tym)
tgen:
    clc                         ; acc += step (the operands patched)
    lda laccx
gx0 adc #0
    sta laccx
    lda laccx+1
gx1 adc #0
    sta laccx+1
    lda laccx+2
gx2 adc #0
    sta laccx+2
    clc
    lda laccy
gy0 adc #0
    sta laccy
    lda laccy+1
gy1 adc #0
    sta laccy+1
ge  cpx #0                      ; (patched: the index after the last pixel)
    bne ploop
    jmp ldone
wrap:
    sbc #$10                    ; C = 1: exact -$10
    sta wptr+1
    sta lbuf_hi,x
    lda rowbank,y               ; the next bank: + 1 (C = 1: $40+ - $10 borrows nothing)
    adc #0
    bne sel                     ; (always: $B1+)
nsel:
    sta ls+1
    ldy #MA_BSEL
    sta (VB),y
    bne same                    ; (always: Y = MA_BSEL)
.endp
    ert >line_dda.txm <> >[line_dda.ge+1]  ; the pixel loop and its tails in one page

