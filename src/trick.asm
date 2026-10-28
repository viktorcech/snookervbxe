; trick.asm -- the trick shots (the menu's TRICK SHOTS, gmode 3): each a table
; (tools/trick_sim.py: the balls, the cue ball, a shot found in the game's own
; physics -> tricks.inc).  tstate: 0 its description shown, the demo after
; TK_WAIT frames; 1 the computer plays the demo; 2 the player's turn (the table
; set again); 3 judged -- WELL DONE / TRY AGAIN; fire: from the start again, the
; description and the demo too (WELL DONE: the next trick).  DEMO blinks in the
; bar's right field (the VBI's THINKING blink, thk $80).  No rules, no score.  Cold code
; in the RAM under BASIC.
; [2026-10-23 6502-idioms/SKILL.md: code size is RAM -- the tables struct of arrays,
;  the count down to zero, jsr / rts -> jmp, flags tracked]

TK_WAIT = 150               ; frames the description shows before the demo (3 s)
TK_VERD = 75                ; frames the verdict shows before its prompt (1.5 s)
TK_STEPS = 64               ; frames the computer walks the cue ball to its place
TK_BANK = $0C               ; V:$0C000: the tricks' records (tricks_v.inc), MEMAC-A at $3000

    icl '../build/assets/tricks.inc'

; the trick's record (TKREC bytes, tricks_v.inc), copied by tk_load
tkb_n  = tkb                ; its number and name ($FF ends it)
tkb_d  = tkb+23             ; its description
tkb_c  = tkb+50             ; the cue ball: x0 x1 x2 y0 y1 y2 (Q12, as rbx, rby)
tkb_bn = tkb+56             ; its balls
tkb_nc = tkb+57             ; 1: the cue ball must drop (an in-off)
tkb_al = tkb+58             ; the demo: the aim (1/64 units, 2),
tkb_p1 = tkb+60             ;   the power's bytes 1, 2,
tkb_sp = tkb+62             ;   the tip
tkb_b  = tkb+63             ; the balls, 8 bytes each: id, needed, x0 x1 x2, y0 y1 y2

; tk_load: A = a trick -> its record in tkb (the menu's name too)
.proc tk_load
    tax
    lda tk_rl,x
    sta src
    lda tk_rh,x
    sta src+1
    ldy #MA_BSEL
    lda #$80|TK_BANK
    sta (VB),y
    ldy #TKREC
c:  dey
    lda (src),y
    sta tkb,y
    tya
    bne c
    jmp hud_end             ; (bank 0 back)
.endp

; trick_start: main's start -- the trick mode: its table, the description up
.proc trick_start
    lda gmode
    cmp #3
    beq t
    rts
t:  lda gtrick
    jsr tk_load
    jsr tk_place
    lda #0
    sta tstate
    lda #TK_WAIT
    sta ttim
    sec                     ; the aim 11 deg off the demo's: the computer turns it in
    lda aimang
    sbc #32
    sta aimang
    lda aimang+1
    sbc #0
    and #$03
    sta aimang+1
    lda #CAM_TOP            ; the view from above: the whole trick (C: another camera)
    sta cmode
    jsr cam_set
    ert *<>tk_walk0         ; (the cue ball to the D: the computer walks it back)
.endp

; tk_walk0: the cue ball from its place to the D's middle (twp) -> tws = the walk's
; step back to its place, TK_STEPS of them (a 24-bit difference >> 6, signed)
.proc tk_walk0
    ldx #5
c:  lda tkd,x
    sta rbx,x
    sta twp,x
    dex
    bpl c
    ldx #3                  ; y, then x
a:  sec
    lda tkb_c,x
    sbc twp,x
    sta tws,x
    lda tkb_c+1,x
    sbc twp+1,x
    sta tws+1,x
    lda tkb_c+2,x
    sbc twp+2,x
    sta tws+2,x
    lda #0                  ; the sign from the borrow: a Q12 x over 2048 mm has bit 23 set,
    sbc #0                  ;   the difference needs 25 bits (the walk went left and wrapped)
    ldy #6
s:  cmp #$80                ; (A: $FF / $00, then the high byte) >> 1, signed
    ror tws+2,x
    ror tws+1,x
    ror tws,x
    lda tws+2,x
    dey
    bne s
    dex
    dex
    dex
    bpl a
    lda #TK_STEPS
    sta twn
    ldx #0
    jsr place
    jmp hud_draw            ; (main's start: the HUD drawn before the trick was read)
tkd dta 0, <[597*16], >[597*16], 0, <[889*16], >[889*16]   ; the D's middle (Q12)
.endp

; tk_place: every ball off the table, the trick's and the cue ball placed (at
; rest, re-projected), the aim the demo's (the camera along it)
.proc tk_place
    ldx #NB-1
off:
    lda #0
    sta BON,x
    lda #$FF                ; (off the table: as a potted ball)
    sta X0,x
    sta X1,x
    sta X2,x
    sta Y0,x
    sta Y1,x
    sta Y2,x
    dex
    bpl off
    ldx #5                  ; the cue ball
c:  lda tkb_c,x
    sta rbx,x
    dex
    bpl c
    ldx #0
    jsr place
    lda tkb_bn              ; its balls
    sta tkn
    ldy #7
b:  ldx #5                  ; (Y: the ball's last byte)
p:  lda tkb_b,y
    sta rbx,x
    dey
    dex
    bpl p
    sty tkj
    ldx tkb_b-1,y           ; its id
    jsr place
    lda tkj
    clc
    adc #14                 ; the next ball's last byte
    tay
    dec tkn
    bne b
    lda #0
    sta inhand
    sta hwait
    ert *<>tk_aim           ; falls into the aim
.endp

; tk_aim: the demo's aim (1/64 units) -> aimang (>> 6), aimfrac (<< 2)
.proc tk_aim
    lda tkb_al
    asl @
    asl @
    sta aimfrac
    lda tkb_al
    sta tkt
    lda tkb_al+1
    ldy #6
s:  lsr @
    ror tkt
    dey
    bne s
    sta aimang+1
    lda tkt
    sta aimang
    rts
.endp

; trick_tick: every frame (shot_clock, in the trick mode) -- the description's
; time out at rest: the demo, played as the computer plays (ai_run from its turn:
; the aim turns to tgt, a breath, the power charges to tpw, fired), the tip shown
.proc trick_tick
    lda tstate
    beq d
    cmp #3
    beq v
    cmp #1
    bne o
    lda twn                 ; 1: the cue ball walked to its place, then the aim
    beq o
    ldx #0                  ; twp += tws, both axes
    jsr w
    ldx #3
    jsr w
    dec twn
    bne p
    ldx #5                  ; there: exactly its place
c:  lda tkb_c,x
    sta twp,x
    dex
    bpl c
p:  ldx #5
c2: lda twp,x
    sta rbx,x
    dex
    bpl c2
    ldx #0
    jsr place
    lda twn
    bne o
    lda #2                  ; the aim turns (ai_run's 2); the view stays (one shot: from
    sta aist                ;   above, C another -- no pocket camera here, pcam_frame)
    rts
w:  clc
    lda twp,x
    adc tws,x
    sta twp,x
    lda twp+1,x
    adc tws+1,x
    sta twp+1,x
    lda twp+2,x
    adc tws+2,x
    sta twp+2,x
o:  rts
v:  lda ttim                ; 3: the verdict's time out -> the prompt (tk_hud; 0: it is up)
    beq o
    dec ttim
    bne o
    jmp hud_draw
d:  lda moving              ; 0: the description's time out at rest -> the demo
    bne o
    dec ttim
    bne o
    lda tkb_al              ; the computer's shot: tgt, tpw, the tip
    sta tgt
    lda tkb_al+1
    sta tgt+1
    lda #0
    sta tpw
    lda tkb_p1
    sta tpw+1
    lda tkb_p1+1
    sta tpw+2
    lda tkb_sp              ; the tip: spin in the low nibble, side in the high (trick_sim.py)
    and #$0F
    sta spin
    lda tkb_sp
    lsr @
    lsr @
    lsr @
    lsr @
    sta side
    jsr win_ai              ; ai_run's stage 1 while it walks (a look: no plan, the
    lda #255                ;   stick and fire its)
    sta aitm
    jsr win_bcb
    lda #1
    sta aist
    lda #$80                ; DEMO blinks (the VBI's thkblk; ai_input keeps $80)
    sta thk
    ldx turn                ; the computer at the table for it
    lda #5
    sta pty,x
    inc tstate              ; 1: the demo runs
    jmp hud_draw
.endp

; rest_judge: main's rest edge -- the rules, or in the trick mode: the demo done ->
; the table again, the player's turn; the player's shot done -> judged
.proc rest_judge
    lda gmode
    cmp #3
    jne rules_end
    lda tstate
    cmp #1
    bne jd
    lda #0                  ; the demo done: DEMO off, the player back, the table again
    sta thk
    ldx turn
    sta pty,x
    jsr tk_place
    lda #2
    sta tstate
    rts
jd: lda tkb_bn              ; every ball it needs down, the cue ball down only when needed
    sta tkn
    lda #1
    sta tkok
    ldy #0
    sty tkio
    sty tkl
jl: lda tkb_b+1,y
    beq jn
    ldx tkb_b,y
    lda BON,x
    beq jn
    inc tkl                 ; one it needed is still up
    lda #0
    sta tkok
jn: tya
    clc
    adc #8
    tay
    dec tkn
    bne jl
    lda cuein
    cmp tkb_nc
    beq j2
    sta tkio                ; (1: an in-off spoilt it -- the verdict says so)
    lda #0
    sta tkok
j2: lda #3                  ; judged: fire for another go (frame_next -> trick_again);
    sta tstate              ;   the verdict TK_VERD frames, then the prompt (trick_tick)
    lda #TK_VERD
    sta ttim
    lda #1
    sta fover
    lda #0
    sta fwait
    sta inhand
    rts
.endp

; trick_again: frame_next in the trick mode (fire after the verdict) -- from the
; start again, the description and the demo: the same trick, or after WELL DONE
; the next one
.proc trick_again
    lda tkok
    beq s
    inc gtrick
    lda gtrick
    cmp #TK_N
    bcc s
    lda #0
    sta gtrick
s:  lda #0
    sta fover
    sta fwait
    jmp trick_start         ; (the view, the table repainted, the HUD)
.endp

; tk_hud: hud_draw in the trick mode -- the trick's name (yellow), its state in the
; blue field: the description, DEMO, YOUR TURN, WELL DONE / TRY AGAIN
.proc tk_hud
    jsr hud_begin
    lda #HA_YEL             ; the bar: yellow | white | blue | white | yellow
    ldx #0
    ldy #22
    jsr hfill
    lda #HA_WHT
    ldy #5
    jsr hfill
    lda #HA_BLU
    ldy #26
    jsr hfill
    lda #HA_WHT
    ldy #5
    jsr hfill
    lda #HA_YEL
    ldy #18
    jsr hfill
    lda #<tkb_n             ; the name, centred in the yellow field (0-21)
    sta src
    lda #>tkb_n
    sta src+1
    lda #0
    ldy #22
    jsr tk_ctr
    ldy tstate              ; the state's text, centred in the blue field (27-52)
    cpy #2
    bcs s1
    lda #<tkb_d             ; 0, 1: the description
    sta src
    lda #>tkb_d
    sta src+1
    lda #27
    ldy #26
    jsr tk_ctr
    lda tstate              ; 1: DEMO, blinking (HA_THK: the VBI's thkblk), right
    beq d0
    lda #HA_THK
    ldx #58
    ldy #18
    jsr hfill
    lda #<msdemo
    sta src
    lda #>msdemo
    sta src+1
    lda #58
    ldy #18
    jsr tk_ctr
d0: jmp tip_draw
s1: cpy #3
    bne s2
    lda ttim                ; 3: the verdict's time up -> its prompt (5 / 6)
    bne t4
    iny
    iny
t4: lda tkok
    beq t5
    iny                     ; done: WELL DONE (4) / NEXT TRICK? (6)
    bne s2                  ; (always)
t5: lda ttim                ; not done: TRY AGAIN (3) / ONCE MORE? (5); while the verdict
    beq s2                  ;   shows, why: an in-off (7) or how many are left (8)
    lda tkio
    beq t6
    ldy #7
    bne s2                  ; (always)
t6: lda tkl
    beq s2
    ora #16                 ; (its digit, screen code: tkl <= 15)
    sta msleft
    ldy #8
s2: lda tsl-2,y             ; 2 YOUR TURN, 3 TRY AGAIN, 4 WELL DONE, 5 / 6 the prompts, 7 / 8 why
    sta src
    lda tsh-2,y
    sta src+1
    lda #27
    ldy #26
    jsr tk_ctr
    jmp tip_draw
tsl dta <msturn, <mstry, <mswell, <msonce, <msnext, <msinoff, <msleft
tsh dta >msturn, >mstry, >mswell, >msonce, >msnext, >msinoff, >msleft
.endp

; tk_ctr: src = a text ($FF ends it), A = a field's first column, Y = its width ->
; the text centred in it (line 1)
.proc tk_ctr
    sta tkt
    sty tkj
    ldy #0
l:  lda (src),y
    bmi e
    iny
    bne l
e:  tya                     ; (width - length) / 2 + the first column
    eor #$FF
    sec
    adc tkj
    lsr @
    clc
    adc tkt
    tax
    lda src
    jmp text.a
.endp

msdemo  dta d'DEMO', $FF
msturn  dta d'YOUR TURN', $FF
mstry   dta d'TRY AGAIN', $FF
mswell  dta d'WELL DONE', $FF
msonce  dta d'ONCE MORE? FIRE', $FF
msnext  dta d'NEXT TRICK? FIRE', $FF
msinoff dta d'IN-OFF, TRY AGAIN', $FF
msleft  dta d'1 LEFT, TRY AGAIN', $FF    ; (the digit patched: tk_hud)
gmode   dta 0               ; 0 a match, 3 the trick shots (the menu's)
gtrick  dta 0               ; the trick
tstate  dta 0               ; its stage (above)
ttim    dta 0               ; frames to the demo
tkj     dta 0
tkn     dta 0
tkt     dta 0
tkok    dta 0               ; 1: the player's shot made it
tkio    dta 0               ; 1: it failed by an in-off (the cue ball down, not wanted)
tkl     dta 0               ; the balls it needed still up after the player's shot
tkb     :TKREC dta 0        ; the trick's record (tk_load)
twp     :6 dta 0            ; the walk: the cue ball's place now (x, y Q12), its step
tws     :6 dta 0
twn     dta 0               ; steps left
