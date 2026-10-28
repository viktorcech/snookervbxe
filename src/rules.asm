; [2026-10-21 6502-idioms/SKILL.md: count down to zero, tables beat arithmetic (bval), fall
;  through (ert); 6502-loops-tables-smc/SKILL.md: dispatch by rts (hud)]
; rules.asm -- the rules of snooker (WPBSA; biliard.sk): the ball on, scoring,
; fouls and their penalties, colour re-spots, ball in hand, the end of the
; frame.  shot_begin runs as the cue is struck (fire_cue), rules_end at the
; rest edge (main).  Cold code: once a shot.
;
; Ball ids: 0 cue, 1-15 reds, 16 yellow .. 21 black.  The colour after a red
; is nominated by the first colour the cue hits (the game's nomination).

M_NONE  = 0                 ; msgc: what the last shot did
M_PTS   = 1                 ;   msgv points scored
M_FOUL  = 2                 ;   msgv penalty to the opponent
M_END   = 3                 ;   the frame is over
M_MISS  = 4                 ;   a foul and a miss: msgv the penalty, mcnt the misses
M_FREE  = 5                 ;   a foul, the next player snookered: a free ball

bval:                       ; ball values
    dta 0
    :15 dta 1
    dta 2,3,4,5,6,7

; in hand: the cue's places in the D, tried in order (Q12 x, y): the D's middle
; (597, 889: behind the brown) first, then setup_balls' (597, 709)
handx0  dta $00,$00,$00,$00,$00
handx1  dta $50,$50,$D0,$D0,$50
handx2  dta $25,$25,$27,$22,$2A
handy0  dta $00,$00,$00,$00,$00
handy1  dta $90,$50,$90,$10,$10
handy2  dta $37,$2C,$37,$3F,$30

; rules_init: a new match -- no frames won, player 1 breaks off
.proc rules_init
    lda #0
    sta fw
    sta fw+1
    sta brkr
    ert *<>frame_init
.endp

; frame_init: a new frame's rules -- no points, 15 reds, the breaker to play
; with the cue in hand (in the D: setup_balls' place is the D's first)
.proc frame_init
    lda #0
    ldx #rstate_len-1
cl:
    sta rstate,x
    dex
    bpl cl
    sta hwait
    sta fwait
    sta fball
    sta mcnt
    sta rpl
    sta missf
    sta kk_chn              ; no chalk marks (chalk.asm): the table brushed
    sta kk_chi
    sta tsub                ; the shot clock (hud.asm shot_clock)
    sta tsu
    sta tst
    sta tmin
    lda PAL                 ; its VBLANKs a second: PAL 50, NTSC 60
    and #$0E
    beq fi0
    lda #60
    sta sc_add.hz+1
fi0:
    lda #1
    sta inhand
    lda #15
    sta redsl
    lda brkr
    sta turn
    rts
.endp

; frame_next: the frame is over (fover): fire pressed and released -> the next
; frame (re-racked, the other player breaks; after the match a new one)
; [2026-10-21 6502-idioms/SKILL.md: no cmp #0 -- tax sets Z from STRIG0 (X dies)]
.proc frame_next
    lda $0284               ; STRIG0: 0 = pressed
    ldx fwait
    bne rel
    tax                     ; (Z from STRIG0)
    bne out
    inc fwait               ; pressed: now wait for the release
out:
    rts
rel:
    tax                     ; (Z from STRIG0)
    beq out
    lda gmode               ; the trick mode: another go (trick.asm)
    cmp #3
    jeq trick_again
    lda fw                  ; the match won (bestw frames, the menu's): a new match
    cmp bestw
    bcs nm
    lda fw+1
    cmp bestw
    bcc nf
nm:
    lda gmode               ; the tournament: the draw on the title with every result,
    cmp #1                  ;   then the next round, or a new one (tournament.asm) --
    jeq tour_done           ;   never back here
nm0:
    jsr rules_init
    jmp rack
nf:
    lda brkr                ; the other player breaks off
    eor #1
    sta brkr
    jsr frame_init
rack:
    jsr setup_balls
    jsr in_hand             ; the break-off from hand: the D's middle first
    lda #0                  ; aim and view up the table again, as at the start
    sta aimang
    sta aimang+1
    sta aimfrac
    sta rang
    sta rang+1
    jsr set_pivot
    jsr set_angle
    jmp hud_draw
.endp

; ball_on -> onk (0 red, 1 a colour, 2 the sequence colour), onv its value
; (a colour: 0 until the first colour hit names it)
.proc ball_on
    lda expcol
    bne col
    lda redsl
    beq seq
    lda #0
    sta onk
    lda #1
    sta onv
    rts
col:
    lda #1
    sta onk
    lda #0
    sta onv
    rts
seq:
    lda #2
    sta onk
    ldx #16                 ; the lowest colour on the table
s1:
    lda BON,x
    bne fnd
    inx
    cpx #22
    bne s1
    lda #0                  ; (none: the frame is over)
    sta onv
    rts
fnd:
    lda bval,x
    sta onv
    rts
.endp

; shot_begin: the cue is struck -- the ball on now, an empty shot record, the
; position kept (a miss may put it back), a free ball taken over
; [2026-10-21 6502-idioms/SKILL.md: one load, many stores (lda #0)]
.proc shot_begin
    lda fball               ; the free ball awarded: this shot's
    sta fbs
    lda rpl                 ; misses count on only over replaced balls
    bne kp
    sta mcnt                ; (A = 0)
kp:
    lda #0                  ; a shot accepts the position (no request any more)
    sta fball
    sta rpl
    sta missf
    sta fchoice
    jsr snap
    jsr ball_on
    lda #$FF
    sta fcon
    lda #0
    sta potn
    sta cuein
    rts
.endp

; rules_end: the balls stopped -- judge the shot
.proc rules_end
    lda #0
    sta foul
    sta msgc
    lda #4                  ; the least penalty
    sta pen
    lda #$FF
    sta fbid
    ldx fcon
    bpl hit
    inc foul                ; no ball hit
    bne cue                 ; (always)
hit:
    lda fbs                 ; a free ball: the first ball hit, not on, is the one
    beq nofb                ; nominated -- it acts as the ball on
    jsr ison
    bcs nofb
    stx fbid
    bcc cue                 ; (always: C = 0)
nofb:
    lda onk
    beq onred
    cmp #1
    beq oncol
    lda bval,x              ; the sequence: the ball on first
    cmp onv
    beq cue
    bne bad                 ; (always)
onred:
    cpx #16
    bcc cue
bad:
    inc foul                ; a ball not on first: its value counts
    lda bval,x
    jsr fmax
    jmp cue
oncol:
    cpx #16                 ; a red first: no colour named
    bcc bad
    lda bval,x              ; the first colour hit is the one named
    sta onv
cue:
    lda cuein               ; the cue potted (in-off)
    beq pots
    inc foul
pots:
    ldy potn                ; every potted ball: on, or a foul at its value
pl:
    dey
    bmi pdone
    ldx potl,y
    cpx fbid                ; the free ball: as the ball on
    beq pl
    lda onk
    beq pr
    cmp #1
    beq pc
    lda bval,x              ; the sequence: only that colour
    cmp onv
    beq pl
    bne pbad                ; (always)
pr:
    cpx #16                 ; on a red: reds only
    bcc pl
    bcs pbad                ; (always)
pc:
    cpx fcon                ; on a colour: the one named only
    beq pl
pbad:
    inc foul
    lda bval,x
    jsr fmax
    jmp pl
pdone:
    lda foul
    beq clean
    lda onv                 ; the ball on's value counts too (max 4, on, involved)
    jsr fmax
    lda turn                ; the penalty to the opponent
    eor #1
    tax
    lda pen
    jsr addsc
    jsr potreds             ; reds stay down, colours go back
    jsr respots
    lda cuein
    beq ef
    jsr in_hand
ef:
    lda #1                  ; the next player may ask the offender to play again
    sta fchoice
    lda #M_FOUL
    sta msgc
    lda pen
    sta msgv
    jsr missq               ; a foul and a miss? (the third: the frame is over)
    lda fover
    jne out
    jsr end_turn
    jsr freeq               ; the next player snookered: a free ball
    jmp fend
clean:
    lda potn
    bne score
    jsr end_turn            ; nothing potted: the turn passes
    jmp fend
score:
    lda onv                 ; the free ball scores as the ball on -- nothing when
    ldx onk                 ; the sequence colour went down with it (2 pots)
    cpx #2
    bne fv
    ldx potn
    dex
    beq fv
    lda #0
fv:
    sta fbval
    lda #0                  ; the points of every potted ball
    ldy potn
s1:
    dey
    bmi s2
    ldx potl,y
    cpx fbid
    beq fb
    clc
    adc bval,x
    bcc s1                  ; (no carry: at most 15 + 7)
fb:
    clc
    adc fbval
    bcc s1                  ; (always)
s2:
    sta msgv
    ldx turn
    jsr addsc
    lda msgv                ; the break
    clc
    adc brk
    cmp #100                ; 100 reached from below: the century's "100" (century.asm)
    bcc s2c
    ldy brk
    cpy #100
    bcs s2c
    sty cent                ; (Y = the break before: not 0, no shot scores 100)
s2c:
    sta brk
    cmp hbrk
    bcc s3
    sta hbrk
s3:
    lda #M_PTS
    sta msgc
    jsr potreds
    lda onk                 ; a colour while reds remain (or the one after the
    cmp #1                  ; last red) goes back; the sequence's stays down
    bne s3f
    jsr respots
s3f:
    ldx fbid                ; the free ball potted: back on the table
    bmi s4
    jsr ispot
    bcc s4
    ldx fbid
    jsr respot
s4:
    lda #0                  ; after a red: a colour; after a colour: a red
    ldx onk
    bne s5
    lda #1
s5:
    sta expcol
fend:
    lda redsl               ; the end: no reds, not on a colour, the black down
    ora expcol
    bne out
    lda BON+21
    bne out
    lda sclo                ; a tie: the black back on its spot, the next
    cmp sclo+1              ; player from hand
    bne over
    lda schi
    cmp schi+1
    bne over
    ldx #21
    jsr respot
    jmp in_hand
over:
    lda #1
    sta fover
    lda #M_END
    sta msgc
    ldx #0                  ; the frame to the higher score
    lda sclo
    cmp sclo+1
    lda schi
    sbc schi+1
    bcs w0
    inx
w0:
    inc fw,x
out:
    rts
.endp

; fmax: A = a value involved -> pen = max(pen, A)
.proc fmax
    cmp pen
    bcc out
    sta pen
out:
    rts
.endp

; addsc: X = player, A = points -> his score (16 bits)
.proc addsc
    clc
    adc sclo,x
    sta sclo,x
    bcc out
    inc schi,x
out:
    rts
.endp

; century: the "100" (century.asm, its VRAM bank as an 8 KB window at $2000),
; then the table repainted -- the box under it was saved into the clean buffer
.proc century
    lda #0
    sta cent
    ldy #MA_CTL
    lda #$29                ; 8 KB at $2000
    sta (VB),y
    ldy #MA_BSEL
    lda #$80|CE_BANK
    sta (VB),y
    jsr cen_run
    jsr win_bcb
    jmp set_angle
.endp

.proc end_turn
    lda turn
    eor #1
    sta turn
    lda #0
    sta brk
    sta expcol
    rts
.endp

; potreds: every red potted this shot leaves the table for good
.proc potreds
    ldy potn
lp:
    dey
    bmi out
    lda potl,y
    cmp #16
    bcs lp
    dec redsl
    bpl lp                  ; (always: 15 reds at most)
out:
    rts
.endp

; respots: every colour potted this shot back on the table, the highest
; value first (it gets the first choice of the spots)
.proc respots
    ldx #21
cl:
    ldy potn
fd:
    dey
    bmi nx
    txa
    cmp potl,y
    bne fd
    stx rid
    jsr respot
    ldx rid
nx:
    dex
    cpx #16
    bcs cl
    rts
.endp

; respot: X = a colour -> its own spot; taken: the highest-value free spot;
; all taken: as near its spot toward the top cushion (pink, black: below it
; when there is no room above).
.proc respot
    stx rid
    jsr spotxy              ; its own spot
    jsr free
    bcc put
    ldx #21                 ; the highest free spot
hs:
    stx rj
    jsr spotxy
    jsr free
    bcc put
    ldx rj
    dex
    cpx #16
    bcs hs
    ldx rid                 ; up from its own spot, a ball radius a step
    jsr spotxy
up:
    clc
    lda rbx+1
    adc #<[BRQ>>8]
    sta rbx+1
    lda rbx+2
    adc #>[BRQ>>8]
    sta rbx+2
    cmp #>[LMRQ>>8]          ; past L - R: no room above
    bcs dn0
    jsr free
    bcs up
    bcc put                 ; (always)
dn0:
    ldx rid                 ; down from its own spot
    jsr spotxy
dn:
    sec
    lda rbx+1
    sbc #<[BRQ>>8]
    sta rbx+1
    lda rbx+2
    sbc #>[BRQ>>8]
    sta rbx+2
    jsr free
    bcs dn
put:
    ldx rid
    ert *<>place            ; falls into the placing
.endp

; place: ball X onto (rbx, rby), at rest, re-projected
.proc place
    lda rbx
    sta X0,x
    lda rbx+1
    sta X1,x
    lda rbx+2
    sta X2,x
    lda rby
    sta Y0,x
    lda rby+1
    sta Y1,x
    lda rby+2
    sta Y2,x
    lda #1
    sta BON,x
    lda DIRTY,x
    ora #1
    sta DIRTY,x
    lda #0
    sta projvalid
    jmp park
.endp

; spotxy: X = a ball -> (rbx, rby) = its rack position (a colour: its spot)
.proc spotxy
    txa                     ; init_balls: 7 bytes a ball
    asl @
    asl @
    asl @
    stx r7
    sec
    sbc r7                  ; 8 X - X (< 256)
    tay
    ldx #0
cp:
    lda init_balls,y
    sta rbx,x
    iny
    inx
    cpx #6
    bne cp
    rts
.endp

; free: is (rbx, rby) clear of every ball on the table but rid?  C = 1: no
; (a centre nearer than 2R).  Its ball index in rk: respot's and in_hand's loops keep theirs in rj
.proc free
    ldx #21
    bne lp                  ; (always)
nx1:
    ldx rk
nx:
    dex
    jmi none
lp:
    cpx rid
    jeq nx
    lda BON,x
    jeq nx
    sec                     ; adx = |x - rbx|
    lda X0,x
    sbc rbx
    sta adx
    lda X1,x
    sbc rbx+1
    sta adx+1
    lda X2,x
    sbc rbx+2
    bcs xp
    sta adx+2                ; negative: negate the three bytes
    sec
    lda #0
    sbc adx
    sta adx
    lda #0
    sbc adx+1
    sta adx+1
    lda #0
    sbc adx+2
xp:
    sta adx+2
    cmp #>[MINDQ>>8]+1      ; |dx| >= 2R + : clear
    jcs nx
    sec                     ; ady = |y - rby|
    lda Y0,x
    sbc rby
    sta ady
    lda Y1,x
    sbc rby+1
    sta ady+1
    lda Y2,x
    sbc rby+2
    bcs yp
    sta ady+2                ; negative: negate the three bytes
    sec
    lda #0
    sbc ady
    sta ady
    lda #0
    sbc ady+1
    sta ady+1
    lda #0
    sbc ady+2
yp:
    sta ady+2
    cmp #>[MINDQ>>8]+1
    jcs nx
    stx rk
    jsr calc_d2             ; mP = d2 (clobbers X, Y)
    ldx #5                  ; d2 < (2R)^2: taken
cm:
    lda mP,x
    cmp MIND2,x
    bcc taken
    jne nx1
    dex
    bpl cm
    jmi nx1                 ; (equal: just touching, clear)
none:
    clc
    rts
taken:
    sec
    rts
.endp

BRQ   = $01A400             ; R (26.25 mm), Q12
LMRQ  = $DD6C00             ; L - R, Q12
MINDQ = $034800             ; 2R, Q12

; in_hand: the cue potted -> on the table in the D, at the first free place;
; the player to play moves it there (hand_place) before he aims
.proc in_hand
    lda #1
    sta inhand
    lda #0                  ; aim (and so the view) up the table: the D in sight
    sta aimang
    sta aimang+1
    sta aimfrac
    lda #0
    sta rid                 ; (the cue itself is skipped)
    ldx #0
hl:
    stx rj
    lda handx0,x
    sta rbx
    lda handx1,x
    sta rbx+1
    lda handx2,x
    sta rbx+2
    lda handy0,x
    sta rby
    lda handy1,x
    sta rby+1
    lda handy2,x
    sta rby+2
    jsr free
    bcc ok
    ldx rj
    inx
    cpx #5
    bne hl
ok:
    ldx #0
    jmp place
.endp

; hand_place: the cue in hand, at rest (aim_update) -- the stick moves it a
; step in the D (only onto a free place), fire pressed and released puts it
; down: then the camera goes to it and the aiming starts.  No aim line meanwhile.
HSTEP = $30                 ; 3 mm a frame (Q12 byte 1)
.proc hand_place
    lda #0
    sta aiming
    lda $0284               ; STRIG0: 0 = pressed
    ldx hwait
    bne rel
    tax
    bne mv
    inc hwait               ; pressed: wait for the release (no move meanwhile)
    rts
rel:
    tax
    bne down
    rts                     ; (still held)
down:
    lda #0                  ; released: down for good
    sta hwait
    sta inhand
    jmp cam_rest
mv:
    lda $0278               ; the stick: bit 0 up, 1 down, 2 left, 3 right (0 = on)
    and #$0F
    cmp #$0F
    jeq out
    sta dtmp
    lda X0                  ; the cue's place (X0 / X1 / X2: the byte arrays)
    sta rbx
    lda X1
    sta rbx+1
    lda X2
    sta rbx+2
    lda Y0
    sta rby
    lda Y1
    sta rby+1
    lda Y2
    sta rby+2
    lsr dtmp                ; up: up the table (+x)
    bcs n1
    lda rbx+1
    adc #HSTEP
    sta rbx+1
    bcc n1
    inc rbx+2
n1:
    lsr dtmp                ; down: -x
    bcs n2
    sec
    lda rbx+1
    sbc #HSTEP
    sta rbx+1
    bcs n2
    dec rbx+2
n2:
    lsr dtmp                ; left: -y (+y is to the right, looking up the table)
    bcs n3
    sec
    lda rby+1
    sbc #HSTEP
    sta rby+1
    bcs n3
    dec rby+2
n3:
    lsr dtmp                ; right: +y
    bcs n4
    lda rby+1
    adc #HSTEP
    sta rby+1
    bcc n4
    inc rby+2
n4:
    jsr d_test
    bcs out
    lda #0
    sta rid                 ; (the cue itself does not block)
    jsr free
    bcs out
    ldx #0
    jmp place
out:
    rts
.endp

; d_test: is (rbx, rby) in the D (behind the baulk line, within 292 mm of
; its centre)?  C = 1: no.  In 2 mm units (Q4 >> 5), squares from sqlo/sqhi.
DCX = 737*16                ; the D's centre, Q4 mm
DCY = 889*16
.proc d_test
    sec                     ; dx = DCX - x (>= 0: behind the baulk line)
    lda #<DCX
    sbc rbx+1
    tay
    lda #>DCX
    sbc rbx+2
    bcc no
    jsr to2mm
    bcs no
    sta dtmp
    sec                     ; dy = |y - DCY|
    lda rby+1
    sbc #<DCY
    tay
    lda rby+2
    sbc #>DCY
    bcs yp
    eor #$FF                ; negative: negate A:Y
    pha
    tya
    eor #$FF
    adc #1                  ; (C = 0 from the borrow)
    tay
    pla
    adc #0
yp:
    jsr to2mm
    bcs no
    tay                     ; dx^2 + dy^2 <= 146^2 (21316)
    ldx dtmp
    lda sqlo,x
    adc sqlo,y
    lda sqhi,x
    adc sqhi,y
    cmp #>21316+1
    rts                     ; (C = 1: outside; the low byte is ignored: 1 mm)
no:
    sec
    rts
.endp

; to2mm: A:Y = a distance, Q4 (16 bits) -> A = it in 2 mm units, C = 1 when
; over 146 (outside the D)
.proc to2mm
    cmp #>[147*32]
    bcs out                 ; (C = 1)
    sty dtmp+1
    asl @                   ; hi << 3 | lo >> 5  (hi < $13: no overflow)
    asl @
    asl @
    sta dtmp+2
    lda dtmp+1
    lsr @
    lsr @
    lsr @
    lsr @
    lsr @
    ora dtmp+2
    cmp #147
out:
    rts
.endp

; rules_shift: SHIFT held (view_input) -- after a foul, SHIFT + down makes the
; offender play again from the position the foul left; after a miss SHIFT + up
; puts the balls back as at the stroke and he plays again (WPBSA: the request
; cannot be withdrawn); the turn and the arrow go back to him
; [2026-10-21 6502-idioms/SKILL.md: the stick bits shifted into C (no and/cmp), jsr X / rts -> jmp X]
.proc rules_shift
    lda fchoice
    beq out
    lda $0278               ; the stick: bit 0 = 0 up, bit 1 = 0 down
    lsr @
    bcc up
    lsr @
    bcs out
    jsr choose
    jmp hud_draw
up:
    lda missf
    beq out
    jsr choose
    jsr replace
    inc rpl                 ; (the misses count on)
    jsr hud_draw
    jmp cam_rest
out:
    rts
.endp

; [2026-10-21 6502-idioms/SKILL.md: count down to zero (the ball loop, the halving step);
;  carry tracked (the not-taken bcc / bcs of the subtractions); 6502-loops-tables-smc/SKILL.md:
;  tables beat arithmetic -- cos / sin from coslut (cone), no atan2]
; aim_play: the balls at rest after a shot -- the aim (and the camera with it,
; cam_rest) from the cue toward the nearest ball on, the bed's centre when no
; ball is on: never left facing a cushion.  The angle: the quadrant from the
; signs of v = target - cue, then 8 halvings on the sign of cos(m) vy - sin(m) vx.
TCX = 28552                 ; the bed's centre, Q4 mm (1784.5, 889)
TCY = 14224
.proc aim_play
    lda #<TCX
    sta apx
    lda #>TCX
    sta apx+1
    lda #<TCY
    sta apy
    lda #>TCY
    sta apy+1
    lda #$FF                ; the nearest so far: none
    sta abd
    sta abd+1
    jsr ball_on
    ldx #NB-1
lp:
    lda BON,x
    jeq nx
    jsr ison
    jcc nx
    sec                     ; |dx| + |dy|, Q4 (the arrays' mid / high bytes)
    lda X1,x
    sbc X1
    sta apvx
    lda X2,x
    sbc X2
    sta apvx+1
    bcs x0
    sec                     ; negative: negate
    lda #0
    sbc apvx
    sta apvx
    lda #0
    sbc apvx+1
    sta apvx+1
x0:
    sec
    lda Y1,x
    sbc Y1
    sta apvy
    lda Y2,x
    sbc Y2
    sta apvy+1
    bcs y0
    sec
    lda #0
    sbc apvy
    sta apvy
    lda #0
    sbc apvy+1
    sta apvy+1
y0:
    clc                     ; (|dx| + |dy|) / 2: 17 bits brought to 16
    lda apvx
    adc apvy
    tay
    lda apvx+1
    adc apvy+1
    ror @
    sta apvx+2              ; (a spare cell here)
    tya
    ror @
    tay
    lda apvx+2
    pha
    cpy abd                 ; nearer than the nearest so far?
    sbc abd+1
    pla                     ; (pla keeps C)
    bcs nx
    sta abd+1
    sty abd
    lda X1,x                ; the target: this ball
    sta apx
    lda X2,x
    sta apx+1
    lda Y1,x
    sta apy
    lda Y2,x
    sta apy+1
nx:
    dex
    jne lp                  ; (cold: a jmp per ball is nothing)
    sec                     ; v = target - cue, 24 bits signed
    lda apx
    sbc X1
    sta apvx
    lda apx+1
    sbc X2
    sta apvx+1
    lda #0
    sbc #0
    sta apvx+2
    sec
    lda apy
    sbc Y1
    sta apvy
    lda apy+1
    sbc Y2
    sta apvy+1
    lda #0
    sbc #0
    sta apvy+2
    ldy #0                  ; the quadrant: + + 0, - + 1, - - 2, + - 3 (vx, vy)
    lda apvy+2
    bpl qp
    ldy #3
    lda apvx+2
    bpl qd
    dey
    bne qd                  ; (always: 2)
qp:
    lda apvx+2
    bpl qd
    iny
qd:
    sty alo+1               ; lo = the quadrant * 256
    lda #0
    sta alo
    lda #128
    sta astp
hv:
    clc                     ; m = lo + step: v counterclockwise of m -> lo = m
    lda alo
    adc astp
    sta ang2
    lda alo+1
    sta ang2+1              ; (lo + step < the quadrant's end: no carry)
    jsr across
    bmi h1
    lda ang2
    sta alo
h1:
    lsr astp
    bne hv
    lda alo
    sta aimang
    lda alo+1
    sta aimang+1
    lda #0
    sta aimfrac
    rts
.endp

; across: ang2 = m -> N = the sign of cos(m) vy - sin(m) vx (aim_play's v):
; N = 0 when v lies counterclockwise of m (or on it)
.proc across
    ldx #0                  ; cos(m)
    lda ang2
    ldy ang2+1
    jsr cone
    jsr cmulb               ; x vy
    lda sP
    sta acr
    lda sP+1
    sta acr+1
    lda sP+2
    sta acr+2
    clc                     ; sin(m) = cos(m + 768)
    lda ang2
    adc #<768
    pha
    lda ang2+1
    adc #>768
    and #3
    tay
    pla
    ldx #0
    jsr cone
    lda apvx                 ; x vx
    sta sB
    lda apvx+1
    sta sB+1
    lda apvx+2
    sta sB+2
    jsr cmula
    sec
    lda acr
    sbc sP
    lda acr+1
    sbc sP+1
    lda acr+2
    sbc sP+2                ; (N: the sign; |each| < 2^23, no overflow)
    rts
.endp

; cmulb / cmula: sP = cbuf x apvy (cmulb) or x sB (cmula), >> 16
.proc cmulb
    lda apvy
    sta sB
    lda apvy+1
    sta sB+1
    lda apvy+2
    sta sB+2
    ert *<>cmula
.endp
.proc cmula
    lda cbuf
    sta sA
    lda cbuf+1
    sta sA+1
    lda cbuf+2
    sta sA+2
    jmp smul3r
.endp
