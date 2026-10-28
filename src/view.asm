; view.asm -- the view: the table about the cue ball (the pivot) at rang
; (any of 1024 steps, table3d.asm) and a zoom level.  set_angle draws it
; into the clean buffer; rot_view turns a ball's (x, y) about the pivot the
; same way; set_pivot moves the pivot to the cue; zoom_set loads a zoom's
; LUTs; view_input steps the camera (C) and passes SHIFT to the rules.

; --------------------------------------------------------------------------
; vram_chunk: X = VRAM bank -> copy the 4 KB staged at $2000 into that bank.
; Runs from the INI hooks while the XEX loads, before `start`: the first call
; brings the VBXE window up itself.
; --------------------------------------------------------------------------
.proc vram_chunk
    lda vearly
    bne ready
    inc vearly
    jsr detect_vbxe
    lda VB+1
    beq skip                ; no VBXE -> `start` halts anyway
    ldy #MA_CTL
    lda #$38
    sta (VB),y
ready:
    txa
    ora #$80
    ldy #MA_BSEL
    sta (VB),y
    lda #$20                ; src = $2000 (staged), dst = the window
    sta src+1
    lda #$30
    sta wptr+1
    lda #0
    sta src
    sta wptr
    ldx #16                 ; 16 pages = 4 KB
page:
    ldy #0
cp:
    lda (src),y
    sta (wptr),y
    iny
    bne cp
    inc src+1
    inc wptr+1
    dex
    bne page
skip:
    rts
.endp
vearly:
    dta 0

; vram_next: the next 4 KB chunk of the same stream -> the bank after
.proc vram_next
    inc vbank
    ldx vbank
    jmp vram_chunk
.endp

; --------------------------------------------------------------------------
; set_angle: the table at rang about the pivot -> clean buffer -> visible;
; every ball redrawn.
; --------------------------------------------------------------------------
.proc set_angle
; (the VBXE page in the polls, the BCB templates: boot.asm vb_init, once)
    lda #$FF
    sta rcurbl
    jsr rot_draw
    jsr chalk_draw          ; the chalk marks onto the clean table (chalk.asm)
    jsr copy_full           ; clean -> visible
    lda #1                  ; the next draw need not wait for the VBL (the HUD has its own
    sta novbl               ; XDL lines: nothing of it went with the table)
    ldx #NB-1               ; nothing is on the new screen: redraw everything
    lda #0
vs:
    sta SHOWN,x
    dex
    bpl vs
    ldx #NB-1               ; every ball at the new view (bit 1: its du, dv still hold)
vd:
    lda DIRTY,x
    ora #2
    sta DIRTY,x
    dex
    bpl vd
    lda #0
    sta lshown
    sta projvalid
    rts
.endp

; --------------------------------------------------------------------------
; set_pivot: the cue ball's position -> the pivot; the ball projection's
; subtrahends patched; every ball's du, dv (about the pivot) is stale.
; --------------------------------------------------------------------------
.proc set_pivot
    jsr cam_d
    ert *<>pivot_at         ; falls into the general case
.endp

; pivot_at: the table point (bx, by) -> the pivot (cam_set: the table's centre from above)
.proc pivot_at
    lda bx
    sta pivx
    sta project_balls.pvx0+1
    lda bx+1
    sta pivx+1
    sta project_balls.pvx1+1
    lda bx+2
    sta pivx+2
    sta project_balls.pvx2+1
    lda by
    sta pivy
    sta project_balls.pvy0+1
    lda by+1
    sta pivy+1
    sta project_balls.pvy1+1
    lda by+2
    sta pivy+2
    sta project_balls.pvy2+1
    ldx #NB-1
dl:
    lda DIRTY,x
    ora #1
    sta DIRTY,x
    dex
    bpl dl
    rts
.endp

; --------------------------------------------------------------------------
; zoom_set: A = the zoom level -> its planes patched (OFF: view_setup,
; project; TF0 / TFH: rot_project, project; the clipper's TF - 1) and its
; LUT pages copied from VRAM: 16 to ROT_LUT, 5 to ROT_BLUT, 2 to ROT_BLUT2.
; --------------------------------------------------------------------------
.proc zoom_set
    tax
    lda zoom_nh,x           ; DK past 8 bits below this entry (kfar)
    sta znh
    lda zoom_ks0,x          ; a sloped face's eye-height term (cull_prep)
    sta cull_prep.k0+1
    lda zoom_ks1,x
    sta cull_prep.k1+1
    lda zoom_ks2,x
    sta cull_prep.k2+1
    lda zoom_exm_lo,x       ; the eye's distance (the faces' culling)
    sta view_setup.exl+1
    lda zoom_exm_hi,x
    sta view_setup.exh+1
    lda zoom_off_lo,x
    sta view_setup.zof0+1
    sta project.pof0+1
    lda zoom_off_hi,x
    sta view_setup.zof1+1
    sta project.pof1+1
    lda zoom_tf0_hi,x
    sta rot_project.tf0h+1
    sta tfp0+1
    lda zoom_tf0_lo,x
    sta rot_project.tf0l+1
    sec
    sbc #1
    sta tfp0
    bcs t0
    dec tfp0+1
t0:
    lda zoom_tfh_hi,x
    sta rot_project.tfhh+1
    sta project.pfh1+1
    sta tfph+1
    lda zoom_tfh_lo,x
    sta rot_project.tfhl+1
    sta project.pfh0+1
    sec
    sbc #1
    sta tfph
    bcs t1
    dec tfph+1
t1:
    txa                     ; the block: 8 KB a level -> bank ZLUT_BANK + 2 level, page 0
    asl @
    adc #ZLUT_BANK          ; (C = 0: a small level)
    sta vbk
    lda #0
    sta vpg
    lda #>ROT_LUT
    sta wptr+1
    ldx #16
    jsr vcopy
    lda #>ROT_BLUT
    sta wptr+1
    ldx #5
    jsr vcopy
    lda #>ROT_BLUT2
    sta wptr+1
    ldx #2
    ert *<>vcopy            ; falls into the last copy
.endp

; vcopy: X pages of VRAM (bank vbk, from page vpg) -> wptr (page-aligned);
; on to the next bank at the end of one.
.proc vcopy
pg:
    lda vbk
    ora #$80
    ldy #MA_BSEL
    sta (VB),y
    lda vpg
    ora #>WINDOW
    sta src+1
    lda #0
    sta src
    sta wptr
    tay
cp:
    lda (src),y
    sta (wptr),y
    iny
    bne cp
    inc wptr+1
    inc vpg
    lda vpg
    cmp #16
    bne n1
    lda #0
    sta vpg
    inc vbk
n1:
    dex
    bne pg
    lda #$80                ; the window back on bank 0 (the BCBs)
    ldy #MA_BSEL
    sta (VB),y
    rts
.endp

; --------------------------------------------------------------------------
; rot_view: (bx, by) Q12 -> the turned point (rvx, rvy), Q3 mm about the
; pivot, on the table renderer's c, s (rot_trig ran for this rang):
; d = (p - piv) >> 9, x' = du c - dv s, y' = du s + dv c (each product rounded
; like the table points).  At angle 0, x' = du, y' = dv.
; --------------------------------------------------------------------------
.proc rot_view
    sec                     ; du = (bx - pivx) >> 9 (Q3, signed 16)
    lda bx
    sbc pivx
    lda bx+1
    sbc pivx+1
    sta rvu
    lda bx+2
    sbc pivx+2
    ror @                   ; a 25-bit difference (up to 4 m): its sign is the
    eor #$80                ; borrow, not bit 23
    ror rvu
    sta rvu+1
    sec                     ; dv = (by - pivy) >> 9
    lda by
    sbc pivy
    lda by+1
    sbc pivy+1
    sta rvv
    lda by+2
    sbc pivy+2
    ror @
    eor #$80
    ror rvv
    sta rvv+1
    ert *<>rot_rel          ; falls into the turn
.endp

; rot_rel: (rvu, rvv) -> (rvx, rvy) turned by rang
.proc rot_rel
    lda rang
    ora rang+1
    bne go
    lda rvu                 ; angle 0: the identity
    sta rvx
    lda rvu+1
    sta rvx+1
    lda rvv
    sta rvy
    lda rvv+1
    sta rvy+1
    rts
go:
    ldx #rvu                ; |du| * c, then |du| * s (the same mA)
    jsr rvmag
    lda rcm
    sta mB
    lda rcm+1
    sta mB+1
    jsr mul16u
    jsr r14
    lda rvu+1
    eor rcn
    jsr rvsgn
    sta rvx                 ; x' = du c ...
    sty rvx+1
    lda rsm
    sta mB
    lda rsm+1
    sta mB+1
    jsr mul16r
    jsr r14
    lda rvu+1
    eor rsn
    jsr rvsgn
    sta rvy                 ; y' = du s ...
    sty rvy+1
    ldx #rvv                ; |dv| * s, then |dv| * c
    jsr rvmag
    lda rsm
    sta mB
    lda rsm+1
    sta mB+1
    jsr mul16u
    jsr r14
    lda rvv+1
    eor rsn
    jsr rvsgn
    sta rq0
    sty rq1
    sec                     ; x' -= dv s
    lda rvx
    sbc rq0
    sta rvx
    lda rvx+1
    sbc rq1
    sta rvx+1
    lda rcm
    sta mB
    lda rcm+1
    sta mB+1
    jsr mul16r
    jsr r14
    lda rvv+1
    eor rcn
    jsr rvsgn
    clc                     ; y' += dv c
    adc rvy
    sta rvy
    tya
    adc rvy+1
    sta rvy+1
    rts
.endp

; rvmag: X = zp cell of a signed 16 -> mA = its magnitude
; [2026-10-28 6502-idioms/SKILL.md: compute in A, store once -- a negative one negated from
;  its cell straight (no mA store and reload); no RAM cell / stack for a value that only
;  waits: rvsgn's low byte in X (its callers keep nothing in X)]
.proc rvmag
    lda 1,x
    bmi n
    sta mA+1
    lda 0,x
    sta mA
    rts
n:
    sec
    lda #0
    sbc 0,x
    sta mA
    lda #0
    sbc 1,x
    sta mA+1
    rts
.endp

; rvsgn: A bit 7 = negate rpc -> A:Y = +-rpc (lo:hi).  Clobbers X.
.proc rvsgn
    asl @
    lda rpc
    ldy rpc+1
    bcc ok
    eor #$FF                ; C = 1: the +1 of the two's complement
    adc #0
    tax
    tya
    eor #$FF
    adc #0
    tay
    txa
ok:
    rts
.endp

; --------------------------------------------------------------------------
; view_input: key C steps the camera (cam_set), also while the balls run; at
; rest SHIFT + stick up / down goes to the rules (the request after a foul / a miss).
; --------------------------------------------------------------------------
KEY_C = $12

.proc view_input
    lda $D20F               ; SKSTAT bit 3 = 0: SHIFT held
    and #$08
    bne c
    lda moving
    jeq rules_shift
    rts
c:
    lda CH                  ; C: the next camera
    cmp #KEY_C
    bne ret
    lda #$FF
    sta CH
    ldx cmode
    inx
    cpx #CAM_N
    bcc cn
    ldx #0
cn:
    stx cmode
    jmp cam_rest.cpx
ret:
    rts
.endp

; --------------------------------------------------------------------------
; the cameras (cmode, key C): CAM_CUE behind the cue ball, CAM_LOW low over
; the cue, CAM_EYE the player's view down the cue (close behind the white,
; zoomed in) -- all three turned after
; the aim (aim_follow); CAM_TOP from above, the whole table, still.  cam_set redraws the table for cmode;
; cam_rest after a shot (the cue moved).
; --------------------------------------------------------------------------
CAM_CUE = 0
CAM_LOW = 1
CAM_EYE = 2
CAM_TOP = 3
CAM_N   = 4
TOP_ANG = 256               ; from above: the table across the screen, baulk left

cam_zoom:
    dta ZOOM_DEF, ZOOM_LOW, ZOOM_EYE, ZOOM_TOP

.proc cam_rest
    lda pcam                ; the pocket camera was on: back to the camera, whichever
    beq np                  ;   (and the next shot may show it again)
    ldx #0
    stx pcam
cpx:                        ; (view_input's C too) a pivot on the table again: its
    lda #$80                ;   differences' sign is the borrow (pc_chk's may be below 0)
    sta project_balls.ex+1
    sta project_balls.ey+1
    bne cam_set             ; (always)
np:
    lda cmode
    cmp #CAM_TOP
    bne cam_set
    rts                     ; from above nothing moves
.endp

.proc cam_set
    ldx cmode
    lda cam_zoom,x
    jsr zoom_set
    lda cmode
    cmp #CAM_TOP
    beq top
    jsr cam_d               ; behind the cue / at the target: along the aim
    sec                     ; rang = -aimang
    lda #0
    sbc aimang
    sta rang
    lda #0
    sbc aimang+1
    and #3
    sta rang+1
    jmp piv
top:
    lda #<ROT_CXQ           ; the table centre
    sta bx
    lda #>ROT_CXQ
    sta bx+1
    lda #^ROT_CXQ
    sta bx+2
    lda #<ROT_CYQ
    sta by
    lda #>ROT_CYQ
    sta by+1
    lda #^ROT_CYQ
    sta by+2
    lda #<TOP_ANG
    sta rang
    lda #>TOP_ANG
    sta rang+1
piv:
    jsr pivot_at
    lda #0
    sta fidle
    jmp set_angle
.endp

; cam_d: the pivot the cameras turn about -> bx, by: the cue ball (CAM_EYE
; looks from close behind it: rot_ref EYE)
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- fall through into the shared copy]
.proc cam_d
    ldx #0
    ert *<>ball_b           ; falls into ball_b
.endp

; ball_b: ball X's position -> bx, by (Q12, 24-bit); keeps X
.proc ball_b
    lda X0,x
    sta bx
    lda X1,x
    sta bx+1
    lda X2,x
    sta bx+2
    lda Y0,x
    sta by
    lda Y1,x
    sta by+1
    lda Y2,x
    sta by+2
    rts
.endp

; aim_follow: at rest the view looks along the aim (rang = -aimang, the aim
; line straight up the screen) about the cue (cam_d).  The table is redrawn (pivot_at + set_angle) only when the line has
; swung FOLLOW_STEP off, or when the stick has rested FOLLOW_WAIT frames with
; any swing or a pivot off the cue left; between those only the line and the balls
; move.  Not while the power is being charged.
FOLLOW_STEP = 8             ; ~2.8 degrees
FOLLOW_WAIT = 10            ; frames

.macro PNEAR            ; :1 (the cue) vs :2 (the pivot), Q4 = bytes 1-2: |cue - pivot| > 2..3 x 16 mm -> :3
    sec
    lda :1+1
    sbc :2+1
    lda :1+2
    sbc :2+2
    bcs pos             ; (the borrow is the sign of the 17-bit difference)
    cmp #$FD
    bcc :3
    bcs ok              ; (always)
pos
    cmp #3
    bcs :3
ok
.endm

.proc aim_follow
    lda moving
    ora charging
    jne ret
    lda cmode               ; from above the view stays
    cmp #CAM_TOP
    jeq ret
    jsr cam_d               ; the cue -> bx, by
    PNEAR bx, pivx, poff
    PNEAR by, pivy, poff
    lda #0
    beq pset                ; (always)
poff:
    lda #1
pset:
    sta pfar
    clc                     ; s = (aimang + rang) mod 1024: the swing is -s
    lda aimang
    adc rang
    tay
    lda aimang+1
    adc rang+1
    and #3
    tax
    bne hi
    tya
    bne lo
    lda pfar                ; on the aim: only a pivot off the cue is left
    beq still
    bne near                ; (always)
lo:
    cmp #FOLLOW_STEP
    bcs turn
    bcc near                ; (always)
hi:
    cpx #3                  ; s in 993..1023: a swing of 1..31 the other way
    bne turn
    cpy #256-FOLLOW_STEP+1  ; (s - 768 >= 993 - 768)
    bcc turn
near:
    lda $0278               ; the stick moved (any direction): not yet
    and #$0F
    cmp #$0F
    bne still
    inc fidle
    lda fidle
    cmp #FOLLOW_WAIT
    bcc ret
turn:
    sec                     ; rang = -aimang
    lda #0
    sbc aimang
    sta rang
    lda #0
    sbc aimang+1
    and #3
    sta rang+1
    jsr pivot_at            ; about the cue
    jsr set_angle
still:
    lda #0
    sta fidle
ret:
    rts
.endp

; ---- the aim's cos (input.asm's, here above $6000: the computer's 16 KB window
;      ($2000-$5FFF) hides that RAM while it plans, and its trig calls cosptr) ----
; cosptr: ang2 (0..1023) -> aptr = cbuf: cos(ang2), cos(ang2 + 1), Q16 signed
; 24-bit (6 bytes, as the old full table's two neighbours).  Keeps ang2.
; [2026-10-09 6502-idioms/SKILL.md: code size is RAM, on a cold path bytes win -- the table is one quarter
;  wave (cos 0..255, exactly symmetric: cos(-a) = cos(a), cos(512-a) = -cos(a)); 2304 bytes freed]
.proc cosptr
    ldx #0
    lda ang2
    ldy ang2+1
    jsr cone
    ldx #3                  ; a + 1 (1023 + 1 wraps to 0)
    ldy ang2+1
    lda ang2
    clc
    adc #1
    bcc nq
    iny
nq:
    pha
    tya
    and #3
    tay
    pla
    jsr cone
    lda #<cbuf
    sta aptr
    lda #>cbuf
    sta aptr+1
    rts
.endp

; cone: A = the angle's low byte r, Y = its quadrant (0..3), X = the cbuf
; offset -> cbuf+X..+2 = cos.  Odd quadrants run the table backwards (256 - r),
; quadrants 1 and 2 are negative.
.proc cone
    sty amul+1
    cpy #1                  ; an odd quadrant (1, 3)?  [2026-10-28 6502-idioms/SKILL.md: A
    beq od                  ;  stays r -- no pha / tya / lsr / pla to test bit 0]
    cpy #3
    bne ev
od:
    eor #$FF                ; 256 - r = ~r + 1 (C = 1: cpy's equality)
    adc #0
    bcs zero                ; r = 0: entry 256 = cos 90 = 0
ev:
    sta amul                ; aptr = coslut + 3 idx (idx < 256)
    lda #0
    sta aptr+1
    lda amul
    asl @
    rol aptr+1              ; (C = 0: aptr+1 was 0)
    adc amul
    bcc c1
    inc aptr+1
    clc
c1:
    adc #<coslut
    sta aptr
    lda aptr+1
    adc #>coslut
    sta aptr+1              ; (C = 0)
    lda amul+1
    adc #1
    and #2                  ; quadrants 1, 2
    beq pos
    ldy #0
    sec
    lda #0
    sbc (aptr),y
    sta cbuf,x
    iny
    lda #0
    sbc (aptr),y
    sta cbuf+1,x
    iny
    lda #0
    sbc (aptr),y
    sta cbuf+2,x
    rts
pos:
    ldy #0
    lda (aptr),y
    sta cbuf,x
    iny
    lda (aptr),y
    sta cbuf+1,x
    iny
    lda (aptr),y
    sta cbuf+2,x
    rts
zero:
    lda #0
    sta cbuf,x
    sta cbuf+1,x
    sta cbuf+2,x
    rts
.endp

spin    dta 4                   ; the cue tip on the cue ball: 0..8, 4 = the centre (input.asm; here above $6000 for the AI)
side    dta 4                   ; the tip left / right: 0..8, 4 = the centre (cushion.asm's w)

