; input.asm -- joystick aiming, trigger handling, firing the cue.

; ==========================================================================
; AIM (joystick)
; ==========================================================================
; [2026-10-09 6502-idioms/SKILL.md: no RAM cell for a value that only waits -- gmb + gmul inlined,
;  the signed product straight into the pass's table ; 6502-cycles-layout/SKILL.md: rare case out of line (first)]
; GMULX: mB:A = the coordinate (A = its high byte, N = its sign), X = gj ->
; :1, :2, :3 (,X) = bytes 1..3 of |coord| * mA signed by sign(coord) ^ gsg
; (floor / 256).  The pass's first ball (X = 0) patches mA in.
.macro GMULX
    sta mB+1
    bpl pos
    eor gsg
    sta gt
    sec
    lda #0
    sbc mB
    sta mB
    lda #0
    sbc mB+1
    sta mB+1
    bpl mul                 ; (always: |coord| < 32768)
pos
    eor gsg
    sta gt
mul
    cpx #0
    beq first
    jsr mul16hr
s
    ldx gj
    bit gt
    bmi neg
    lda mP+1
    sta :1,x
    lda mP+2
    sta :2,x
    lda mP+3
    sta :3,x
    jmp nx
first
    jsr mul16h
    jmp s
neg
    sec                     ; -P (its low byte is 0): bytes 1..3, no borrow in
    lda #0
    sbc mP+1
    sta :1,x
    lda #0
    sbc mP+2
    sta :2,x
    lda #0
    sbc mP+3
    sta :3,x
nx
.endm

; ==========================================================================
; project_balls: every moved ball -> NEWS (its sprite rectangle on the
; screen), then the depth order.  The turn about the pivot is
; rot_ref.ball_rot: four products a ball (P1 = c du, P2 = s dv, P3 = s du,
; P4 = c dv), BATCHED -- each pass patches its trig value into the
; multiplier once (mul16h on the first ball) and every ball's coordinate runs
; through mB (mul16hr).  Products kept as bytes 1..3 of the signed value:
; x' = (P1-P2+32) >> 6, y' = (P3+P4+32) >> 6.
; ==========================================================================
.proc project_balls
    ldy #0                  ; --- the moved balls: plist, du, dv (Q3) ---
    ldx #NB-1               ; (6502-idioms/SKILL.md: count DOWN -- plist's order is irrelevant)
; [2026-10-12 fable-skill-atari/SKILL.md 4: a cache behind a stamp -- du, dv per ball, recomputed only
;  when it moved (DIRTY bit 0); a new angle alone (bit 1) takes them from BDU / BDV]
pl:
    lda BON,x
    beq pn
    lda DIRTY,x
    beq pn
    lsr @               ; C = bit 0: it moved -> du, dv anew
    lda #0
    sta DIRTY,x
    txa
    sta plist,y
    bcc cached
                            ; du = (X - pivx) >> 9 (the pivot: set_pivot patches it in)
    lda X0,x
pvx0 sbc #0
    lda X1,x
pvx1 sbc #0
    sta rq0
    lda X2,x
pvx2 sbc #0
    ror @                   ; a 25-bit difference (up to 4 m): its sign is the
ex  eor #$80                ; borrow, not bit 23 ($00: a pivot below 0, pivot_at)
    ror rq0
    sta gduh,y
    sta BDUH,x
    lda rq0
    sta gdul,y
    sta BDUL,x
    sec                     ; dv = (Y - pivy) >> 9
    lda Y0,x
pvy0 sbc #0
    lda Y1,x
pvy1 sbc #0
    sta rq0
    lda Y2,x
pvy2 sbc #0
    ror @
ey  eor #$80
    ror rq0
    sta gdvh,y
    sta BDVH,x
    lda rq0
    sta gdvl,y
    sta BDVL,x
    iny
    bne pn                  ; (always: Y <= 22)
cached:
    lda BDUL,x
    sta gdul,y
    lda BDUH,x
    sta gduh,y
    lda BDVL,x
    sta gdvl,y
    lda BDVH,x
    sta gdvh,y
    iny
pn:
    dex
    bpl pl
    sty pcount
    tya
    jeq zsort               ; nothing moved
    lda rang
    ora rang+1
    jeq ident
    ; --- four products a ball (|du|, |dv| < 2^15 about the cue; a sum of
    ; them could not be): P1 = c du, P2 = s dv, P3 = s du, P4 = c dv ---
    lda rcm                 ; pass 1: |c| is the multiplier, its sign gsg
    sta mA
    lda rcm+1
    sta mA+1
    lda rcn
    sta gsg
    ldx #0
p1:
    stx gj
    lda gdul,x
    sta mB
    lda gduh,x
    GMULX g1a, g1b, g1c
    inx
    cpx pcount
    bne p1
    lda rsm                 ; pass 2: s dv
    sta mA
    lda rsm+1
    sta mA+1
    lda rsn
    sta gsg
    ldx #0
p2:
    stx gj
    lda gdvl,x
    sta mB
    lda gdvh,x
    GMULX g2a, g2b, g2c
    inx
    cpx pcount
    bne p2
    ldx #0                  ; pass 3: s du (the multiplier stays)
p3:
    stx gj
    lda gdul,x
    sta mB
    lda gduh,x
    GMULX g3a, g3b, g3c
    inx
    cpx pcount
    bne p3
    lda rcm                 ; pass 4: c dv
    sta mA
    lda rcm+1
    sta mA+1
    lda rcn
    sta gsg
    ldx #0
p4:
    stx gj
    lda gdvl,x
    sta mB
    lda gdvh,x
    GMULX g4a, g4b, g4c
    inx
    cpx pcount
    bne p4
    ; --- x' = (P1 - P2 + 32) >> 6 ; y' = (P3 + P4 + 32) >> 6, then project ---
; [2026-10-09 6502-idioms/SKILL.md: compute in A, store once -- the rounded >> 6 shifted
;  straight in rvx / rvy (g6 and its rq0 / rq1 parks gone)]
    ldx #0
fl:
    stx gj
    sec                     ; x': bytes 1..2 of (sum + 32) << 2
    lda g1a,x
    sbc g2a,x
    tay
    lda g1b,x
    sbc g2b,x
    sta rvx
    lda g1c,x
    sbc g2c,x
    sta rvx+1
    tya
    clc
    adc #32
    bcc fx1
    inc rvx
    bne fx1
    inc rvx+1
fx1:
    asl @
    rol rvx
    rol rvx+1
    asl @
    rol rvx
    rol rvx+1
    clc                     ; y'
    lda g3a,x
    adc g4a,x
    tay
    lda g3b,x
    adc g4b,x
    sta rvy
    lda g3c,x
    adc g4c,x
    sta rvy+1
    tya
    clc
    adc #32
    bcc fy1
    inc rvy
    bne fy1
    inc rvy+1
fy1:
    asl @
    rol rvy
    rol rvy+1
    asl @
    rol rvy
    rol rvy+1
    jsr gstore
    ldx gj
    inx
    cpx pcount
    bne fl
    jmp zsort
ident:                      ; angle 0: x' = du, y' = dv
    ldx #0
il:
    stx gj
    lda gdul,x
    sta rvx
    lda gduh,x
    sta rvx+1
    lda gdvl,x
    sta rvy
    lda gdvh,x
    sta rvy+1
    jsr gstore
    ldx gj
    inx
    cpx pcount
    bne il
    jmp zsort
.endp

; gstore: the ball plist[gj] at (rvx, rvy) -> project -> its sprite rectangle
; cut to the screen -> NEWS (w = 0: not drawn), BKEY = its row
.proc gstore
    ldy gj
    ldx plist,y
    stx bi
    lda BANK,x
    sta sprbank
    jsr project
    ldx bi
    jcs hidden              ; (C from project: out of the LUT range)
; [2026-10-28 6502-idioms/SKILL.md: one load, many stores; 6502-loops-tables-smc/SKILL.md:
;  tables beat arithmetic -- bi*8 from x8 (objects.asm), no asl x3 / tax]
    lda syv                 ; depth key: the sprite row (far = small)
    sta BKEY,x
    sta bsy
    lda sx
    sta bsx
    lda sx+1
    sta bsx+1
    lda syvh
    sta bsy+1
; [2026-10-21 vbxe-blitter/SKILL.md: one rectangle for the ball and its shadow -- clipped once,
;  erased once; the ball's source is the mask's cut moved to its sprite (same pitch)]
    lda dsz
    sta bsw
    sta bpit
    ldy sizev               ; the ball and its shadow below it: the zoom's mask for
    lda bsize+$E0,y         ;   this radius, its rows (zoom block, rot_export.patch_shadows)
    sta bsh
    lda bsize+$C0,y         ; clipped as the shadow mask (pitch dsz, as the sprite)
    sta bsrc
    sta shm
    lda bsize+$D0,y
    sta bsrc+1
    sta shm+1
    jsr occw                ; behind a cushion: its foot cut (cushion.asm's occl)
    jsr clip_blit
    ldx bi
    jcs hidden
    lda bsrc                ; the mask's source -> NSL / NSH
    sta NSL,x
    lda bsrc+1
    sta NSH,x
    sec                     ; ky = the rows cut off the top
    lda bsy
    sbc syv
    cmp dsz
    bcs nob                 ; (the ball itself cut away: its shadow only)
    sta mB
    adc bsh                 ; (C = 0) min(ky + h, dsz) - ky: the ball's rows
    cmp dsz
    bcc hk
    lda dsz
hk:
    sec
    sbc mB
    dta $2C                 ; (bit abs: skips the lda #0)
nob:
    lda #0
    sta NBH,x
    txa
    bne nl              ; the cue: its bounce's lift (chalk.asm: A = 0, X = 0 back)
    jsr hop_lift
nl:
    ldy x8,x                ; Y = bi*8 (X = bi; the cue's hop_lift leaves X = 0)
    lda #1                  ; NEWS anew: draw_all copies it to OLDS (objects.asm nchg)
    sta nchg,x
    lda bsx
    sta NEWS,y
    lda bsx+1
    sta NEWS+1,y
    lda bsy
    sta NEWS+2,y
    lda bsw
    sta NEWS+3,y
    lda bsh
    sta NEWS+4,y
    lda dsz
    sta NEWS+7,y
    sec                     ; the ball's source = its sprite + the mask's cut
    lda bsrc
    sbc shm
    tax
    lda bsrc+1
    sbc shm+1
    sta mB
    clc
    txa
    adc spadr
    sta NEWS+5,y
    lda mB
    adc spadr+1
    sta NEWS+6,y
    rts
hidden:
    ldy x8,x
    lda #0
    sta NEWS+3,y
    rts
.endp

; zsort: dorder by BKEY ascending (far first), stable insertion from the last
; order -- nearly sorted, a pass of compares.
; [2026-10-28 6502-loops-tables-smc/SKILL.md: a variable as the operand of cmp # -- the sorted
;  prefix's largest key (the predecessor's, unchanged by an insertion: as collide_full's cso)]
.proc zsort
    ldy dorder
    lda BKEY,y
    sta pk+1
    ldx #1
so:
    ldy dorder,x
    lda BKEY,y
pk  cmp #0                      ; (patched: the predecessor's key)
    bcc ins
    sta pk+1
sn:
    inx
    cpx #NB
    bne so
    rts
ins:                            ; A = key, slide the larger ones right
    sta zkey
    lda dorder,x
    sta zcur
    stx zsi
    txa
    tay
inner:
    dey
    bmi place
    ldx dorder,y
    lda BKEY,x
    cmp zkey
    bcc place
    beq place
    txa
    sta dorder+1,y
    bcs inner                   ; (always)
place:
    iny                         ; (Y = -1 at the front: abs,y does not wrap)
    lda zcur
    sta dorder,y
    ldx zsi
    jmp sn
.endp

; aim_update: at rest, read stick + trigger and set aim dir (dirx,diry = cos,sin
; Q16).  While balls move, dir = 0 so the aim line collapses onto the cue (hidden).
.proc aim_update
    lda moving                  ; no tick ran this frame -> still at rest (the
    beq atrest                  ; frame's own any_moving is exact); after ticks
    jsr any_moving              ; the state may have changed: rescan
    beq atrest
off:                            ; (a trick's walk too: no line, no stick, dir 0)
    lda #0
    sta aiming
    sta dirx
    sta dirx+1
    sta dirx+2
    sta diry
    sta diry+1
    sta diry+2
    rts
atrest:
    jsr ai_input                ; the computer's turn: it writes STICK0 / STRIG0 (ai.asm)
noai:                           ; (main's start: no plan before the screen is on)
    lda inhand                 ; the cue in hand: the stick places it (rules.asm)
    jne hand_place
    lda twn                    ; a trick's white on its walk to its place (trick.asm)
    bne off
    lda #1
    sta aiming
    jsr tip_input               ; SPACE held: the stick sets the tip, no aim, no power
    bcs tip
    jsr read_stick
    jsr handle_trigger
tip:
    jsr calc_linelen            ; aim-line length grows with charged power
dir:                            ; (sim_shot: the direction alone)
    lda aimang                  ; dirx = cos(aim)
    sta ang2
    lda aimang+1
    sta ang2+1
    jsr cosptr
    ldx #0
    jsr clerp
    clc                         ; diry = sin(aim) = cos(aim+768)
    lda aimang
    adc #<768
    sta ang2
    lda aimang+1
    adc #>768
    and #$03
    sta ang2+1
    jsr cosptr
    ldx #diry-dirx
.endp
    ert *<>clerp                ; falls into the interpolation

; clerp: X = 0 (dirx) / 3 (diry): c = coslut[a] + (coslut[a+1] - coslut[a])
; * aimfrac >> 8 (Q16; the table has entry 1024 = entry 0).  |c1 - c0| < 512.
.proc clerp
    ldy #0
    lda (aptr),y
    sta dirx,x
    iny
    lda (aptr),y
    sta dirx+1,x
    iny
    lda (aptr),y
    sta dirx+2,x
    ldy #3                      ; d = c1 - c0
    sec
    lda (aptr),y
    sbc dirx,x
    sta rq0
    iny
    lda (aptr),y
    sbc dirx+1,x
    sta rq1
    bpl pos
    sec                         ; |d|
    lda #0
    sbc rq0
    sta rq0
    lda #0
    sbc rq1
pos:
    stx rti                     ; t = |d| * frac >> 8  (|d| < 512: hi 0/1)
    tay
    lda rq0
    ldx aimfrac
    jsr fmulu
    lda fmph
    dey                         ; |d| hi was 0 -> t = fmph, t hi 0
    bmi t0
    clc                         ; hi 1: t = fmph + frac (C -> t hi)
    adc aimfrac
    ldy #0
    bcc t1
    iny
    bne t1                      ; (always)
t0:
    ldy #0
t1:
    sta rq0                     ; t = Y:rq0
    ldx rti
    lda rq1                     ; c0 +- t
    bmi sub
    clc
    lda dirx,x
    adc rq0
    sta dirx,x
    tya
    adc dirx+1,x
    sta dirx+1,x
    lda dirx+2,x
    adc #0
    sta dirx+2,x
    rts
sub:
    sec
    lda dirx,x
    sbc rq0
    sta dirx,x
    lda dirx+1,x
    sty rq0
    sbc rq0
    sta dirx+1,x
    lda dirx+2,x
    sbc #0
    sta dirx+2,x
    rts
.endp


; read_stick: STICK0 left/right rotates aimang (wrapped to 0..1023)
.proc read_stick
    lda $0278                   ; left / right (bits 2 / 3, 0 = pressed): the
    and #$0C                    ; speed ramps up while held, from ASTART to AMAX
    cmp #$0C
    beq still
    clc
    lda aspd
    adc #ARAMP
    sta aspd
    lda aspd+1
    adc #0
    cmp #>AMAX
    bcc s1
    lda #>AMAX                  ; (AMAX is whole units)
    ldy #0
    sty aspd
s1:
    sta aspd+1
    lda $0278
    and #$04
    bne right
    sec                         ; left: a -= aspd
    lda aimfrac
    sbc aspd
    sta aimfrac
    lda aimang
    sbc aspd+1
    sta aimang
    lda aimang+1
    sbc #0
    jmp fine
right:
    clc
    lda aimfrac
    adc aspd
    sta aimfrac
    lda aimang
    adc aspd+1
    sta aimang
    lda aimang+1
    adc #0
    jmp fine
still:
    lda #<ASTART                ; released: the next press starts slow again
    sta aspd
    lda #>ASTART
    sta aspd+1
    lda aimang+1
fine:
    and #$03
    sta aimang+1
    lda $0278                   ; up / down (bits 0 / 1): the finest step
    lsr @
    bcs nu
    sec
    lda aimfrac
    sbc #AFINE
    sta aimfrac
    lda aimang
    sbc #0
    sta aimang
    lda aimang+1
    sbc #0
    and #$03
    sta aimang+1
    rts
nu:
    lsr @
    bcs nd
    lda aimfrac
    adc #AFINE
    sta aimfrac
    lda aimang
    adc #0
    sta aimang
    lda aimang+1
    adc #0
    and #$03
    sta aimang+1
nd:
    rts
.endp

; any_moving: A != 0 if any ball is awake (the OR of every AWK: the callers test Z only).
; Keeps X and Y.
; [2026-10-28 6502-cycles-layout/SKILL.md: unroll a loop whose body is smaller than its
;  dex / bne -- 4 cycles a ball, not 11]
.proc any_moving
    lda AWK
    .rept NB-1
    ora AWK+#+1
    .endr
    rts
.endp

; handle_trigger: HOLD FIRE to charge power (pwr ramps PWR_MIN..PWR_MAX),
; RELEASE to shoot the cue at the charged power.  A quick tap = PWR_MIN.
.proc handle_trigger
    lda $0284                   ; STRIG0 (0 = pressed)
    bne released
    ; --- pressed: charge ---
    lda charging
    bne more
    lda #<PWR_MIN               ; first frame held: start at PWR_MIN
    sta pwr
    lda #>PWR_MIN
    sta pwr+1
    lda #0
    sta pwr+2
    lda #1
    sta charging
    rts
more:
    clc                         ; pwr += PWR_DELTA
    lda pwr
    adc #<PWR_DELTA
    sta pwr
    lda pwr+1
    adc #>PWR_DELTA
    sta pwr+1
    lda pwr+2
    adc #0
    sta pwr+2                   ; clamp to PWR_MAX
    cmp #PWR_MAX>>16
    bcc done
    bne setmax
    lda pwr+1
    cmp #>PWR_MAX
    bcc done
    bne setmax
    lda pwr
    cmp #<PWR_MAX
    bcc done
setmax:
    lda #<PWR_MAX
    sta pwr
    lda #>PWR_MAX
    sta pwr+1
    lda #PWR_MAX>>16
    sta pwr+2
done:
    rts
released:
    lda charging
    beq nofire                  ; was not charging -> nothing to do
    lda #0
    sta charging
    jsr fire_cue                ; shoot at the charged pwr
    jsr hop_go                  ; a bounce: the cue in the air (chalk.asm)
    lda #0                      ; reset power
    sta pwr
    sta pwr+1
    sta pwr+2
nofire:
    rts
.endp

; fire_cue: cue (ball 0) v = pwr * (cos, sin)(aim) in Q12 (fraction 0), then
; renorm derives sp = |v| and the deceleration vector.
.proc fire_cue
    lda #0                      ; struck: the computer's input ends (ai.asm)
    sta aiact
    sta aist
    jsr shot_begin              ; the rules: the ball on, an empty shot record
    jsr chalk_add               ; a screw or a hard one: a chalk mark (chalk.asm)
    ldx #SND_CUE                ; the cue's sound
    jsr snd_play
v:                              ; (sim_shot: the strike alone -- no rules, no sound)
    lda #1                      ; the balls may have been placed since (respots, in hand,
    sta srtall                  ;   sim_shot's restore): collide's first sort in full, the
    sta scanall                 ;   first tick looks at every ball.  Set, not inc: both are
                                ;   OS zero page ($3B, $3E) the disk's SIO leaves at $FF
    lda pwr                     ; sA = pwr
    sta sA
    lda pwr+1
    sta sA+1
    lda pwr+2
    sta sA+2
; the direction the aim line was drawn with (aim_update: cos / sin interpolated
; by aimfrac, the last frame's) -- not the LUT entry of aimang alone, which is
; up to 1/1024 turn off and misses a ball the line shows grazed
    jsr mul_dx                 ; vx = (pwr * cos) >> 16
    lda sP
    sta VX0
    lda sP+1
    sta VX1
    lda sP+2
    sta VX2
    lda #0
    sta VXF
    lda pwr                     ; (smul3r's prologue copies sA: reload it)
    sta sA
    lda pwr+1
    sta sA+1
    lda pwr+2
    sta sA+2
    jsr mul_dy                 ; sB = sin(aim)
    lda sP
    sta VY0
    lda sP+1
    sta VY1
    lda sP+2
    sta VY2
    lda #0
    sta VYF
    ldx spin                    ; u = k v: the tip (spin - 4) R/8 above the
    lda #0                      ;   centre gives wR = 5/2 h/R v, k = (spin - 4) 5/16
    sta sB                      ;   (Q16): top > 0, screw < 0, centre 0 (it SLIDES)
    lda spkm,x
    sta sB+1
    lda spkh,x
    sta sB+2
    lda VX0
    sta sA
    lda VX1
    sta sA+1
    lda VX2
    sta sA+2
    jsr smul3r                  ; (sA, sB preserved)
    lda sP
    sta UX0
    lda sP+1
    sta UX1
    lda sP+2
    sta UX2
    lda VY0
    sta sA
    lda VY1
    sta sA+1
    lda VY2
    sta sA+2
    jsr smul3r
    lda sP
    sta UY0
    lda sP+1
    sta UY1
    lda sP+2
    sta UY2
    lda #8                      ; w = R wz = -k v: the tip (side - 4) R/8 right of the
    sec                         ;   centre (k as spin's, the table's x, y mirror
    sbc side                    ;   Mathavan's frame: the sign flips): to cushion.asm, Q9
    tax
    lda #0
    sta sB
    lda spkm,x
    sta sB+1
    lda spkh,x
    sta sB+2
    lda pwr
    sta sA
    lda pwr+1
    sta sA+1
    lda pwr+2
    sta sA+2
    jsr smul3r                  ; Q12 -> >> 3
    lda sP+2
    ldx #3
ws:
    cmp #$80
    ror @
    ror sP+1
    ror sP
    dex
    bne ws
    lda sP
    sta wcue
    lda sP+1
    sta wcue+1
    lda #1
    sta wnew
    lda #4                      ; the next shot: the centre again
    sta spin
    sta side
    ldx #0
    jmp renorm                  ; SLP, a, awake
.endp

; tip_input: SPACE held (SKSTAT bit 2 = 0, KBCODE = SPACE) at the human's aim, not
; charging: the stick moves the tip on the cue ball -- up top, down screw, left /
; right side, one R/8 step on a press, repeated while held; never past R/2 from
; the centre (a miscue).  The square in the HUD's corner shows it (tip_draw), until
; the shot redraws the bar.  C = 1: SPACE held (the stick is not the aim's).
.proc tip_input
    lda aiact                   ; the computer's turn, the power charging: no
    ora charging
    bne no
    lda $D20F
    and #$04
    bne no
    lda $D209
    and #$3F
    cmp #$21                    ; SPACE
    bne no
    lda #$FF                    ; (the OS's key buffer: not a key press)
    sta CH
    lda tipm
    bne on
    inc tipm
    jsr tip_draw
on:
    lda STICK0
    cmp tipl
    beq hold
    sta tipl
    ldx #12                     ; a new press: a step now, the repeat after 12 frames
    bne step                    ; (always)
hold:
    cmp #$0F
    beq yes
    dec tipt
    bne yes
    ldx #5
step:
    stx tipt
    ldx spin
    ldy side
    lsr @                       ; bit 0 up, 1 down, 2 left, 3 right (0 = pressed)
    bcs u0
    inx
u0:
    lsr @
    bcs d0
    dex
d0:
    lsr @
    bcs l0
    dey
l0:
    lsr @
    bcs r0
    iny
r0:
    cpx #9                      ; inside 0..8 and the circle: (s-4)^2 + (d-4)^2 <= 16
    bcs yes
    cpy #9
    bcs yes
    lda tsq,x
    adc tsq,y                   ; (C = 0)
    cmp #17
    bcs yes
    stx spin
    sty side
    jsr tip_draw
yes:
    sec
    rts
no:
    lda #0
    sta tipm
    clc
    rts
tsq dta 16, 9, 4, 1, 0, 1, 4, 9, 16
.endp

; (tip_draw: hud.asm)

; the cue tip on the cue ball: spin 0..8 (4 = the centre, 8 = R/2 above),
; k = (spin - 4) * 5/16 as Q16 bytes 1..2 (byte 0 is 0)
spkm    dta <-320, <-240, <-160, <-80, 0, <80, <160, <240, <320
spkh    dta >-320, >-240, >-160, >-80, 0, >80, >160, >240, >320
