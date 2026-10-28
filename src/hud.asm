; [2026-10-22 vbxe-blitter/SKILL.md (VBXE 1.27 manual ch. 8, text mode): the bar is
;  VBXE's 80-column text mode -- writing a character is one byte, no blit, no BCB;
;  6502-idioms/SKILL.md: code size is RAM (no glyph builder, no templates), fall through]
; hud.asm -- the score bar: 3 text lines at V:HUD_VRAM (char, attribute), the OS
; ROM's font (hud.inc), after a TV snooker scoreboard:
;   yellow 0-21: P1 <  | white 22-26: frame points | blue 27-52: frames won
;   (best of N), a break while one is on, FOUL n after a foul, END |
;   white 53-57: points | yellow 58-75: > P2 | 76-79: the tip on the cue ball.
; Line 1 holds the text; lines 0 and 2 the field colours above and below it.
; Redrawn whole after every shot, at a new frame and at the start.  Cold code.

HA_YEL  = $A0               ; attributes: bit 7 = the background is palette 0's
HA_WHT  = $A1               ;   foreground + 128 (title.asm): black on yellow, on
HA_BLU  = $A2               ;   white, white on blue, THINKING (the VBI blinks
HA_THK  = $A3               ;   $23) on yellow, white on black
HA_TIP  = $A4
HL0     = WINDOW+[HUD_VRAM&$FFF]    ; the 3 lines in the window (hud_begin)
HL1     = HL0+160
HL2     = HL0+320
CH_0    = $10               ; internal codes
CH_LP   = $08
CH_RP   = $09
CH_LT   = $1C
CH_GT   = $1E
CH_CO   = $1A               ; ':'
TIPS    = WINDOW+[HUD_FONT&$FFF]+$40*8  ; the tip's 12 chars, the clean ball's at + $80

.proc hud_draw
    lda gmode               ; the trick mode: its own bar (trick.asm)
    cmp #3
    jeq tk_hud
    jsr hud_begin
    lda #HA_YEL             ; the bar: yellow | white | blue | white | yellow
    ldx #0
    ldy #22
    jsr hfill               ; (X: the column after)
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
    ldy pty                 ; P1's name (pty 0: P1, else the computer's: ai.asm)
    lda ai_nl,y
    ldx ai_nh,y
    cpy #0
    bne h1
    lda #<msp1
    ldx #>msp1
h1:
    stx src+1
    ldx #1
    jsr text.a              ; X = the column after it
    lda turn                ; P1 to play: < after the name
    bne p2
    inx
    lda #CH_LT
    jsr glyphc
p2:
    ldy opp                 ; P2's name (opp 0: P2), right-aligned to column 74
    lda #75
    sec
    sbc ai_nn,y
    tax
    lda turn                ; P2 to play: > before it
    beq n2
    dex
    dex
    lda #CH_GT
    jsr glyphc
    inx
    inx
n2:
    ldy opp
    lda ai_nh,y
    sta src+1
    lda ai_nl,y
    jsr text.a
    ldx #24                 ; the frame points, centred in the white fields
    lda sclo
    ldy schi
    jsr numc
    ldx #55
    lda sclo+1
    ldy schi+1
    jsr numc
    lda fover               ; the middle: the frame's end, a foul, a break, the frames
    jne fend
    lda inhand              ; [2026-10-27] the cue in hand (a person or the computer puts it in
    jne hand                ;   the D): BALL IN HAND, after FOUL n when a foul gave it
    lda msgc
    cmp #M_FOUL
    jeq foul
    cmp #M_MISS
    jeq miss
    cmp #M_FREE
    jeq free
    bit rem                 ; now and then the points left on the table (shot_clock)
    bmi rems
    lda brk
    bne brkon
    ldx #35                 ; frames: P1 (best of) P2
    lda fw
    ora #CH_0
    jsr glyphc
    ldx #43
    lda fw+1
    ora #CH_0
    jsr glyphc
    ldx #38
    lda #<msbo
    ldy #>msbo
    jmp ttip
brkon:
    ldx #35                 ; BREAK nnn
    lda #<msbrk
    ldy #>msbrk
    jsr text
    ldx #41
    lda brk
    ldy #0
    jsr numl
    jmp tip_draw
rems:
    lda redsl               ; POINTS REMAINING: 8 a red, 7 the colour after one, the
    asl @                   ;   colours on the table (<= 154)
    asl @
    asl @                   ; (C = 0: <= 120)
    ldy expcol
    beq rc0
    adc #7
rc0:
    ldy #21
rcl:
    ldx BON,y
    beq rcn
    clc
    adc bval,y
rcn:
    dey
    cpy #16
    bcs rcl
    pha
    ldx #29
    lda #<msrem
    ldy #>msrem
    jsr text
    inx
    pla
    ldy #0
    jsr numl
    jmp tip_draw
foul:
    ldx #37                 ; FOUL n
    lda #<msfoul
    ldy #>msfoul
    jsr text
    inx
    lda msgv
    ora #CH_0
    jsr glyphc
    jmp tip_draw
miss:
    ldx #43                 ; MISS n (k): the penalty, the misses in a row
    lda mcnt
    ora #CH_0
    jsr glyphc
    ldx #40
    lda msgv
    ora #CH_0
    jsr glyphc
    ldx #35
    lda #<msmiss
    ldy #>msmiss
    jsr text
    ldx #42
    lda #CH_LP
    jsr glyphc
    ldx #44
    lda #CH_RP
    jsr glyphc
    jmp tip_draw
free:
    ldx #35                 ; FREE BALL
    lda #<msfree
    ldy #>msfree
    bne ttip                ; (always: the strings are not in page 0)
hand:
    ldx #34                 ; BALL IN HAND, centred in the blue field
    lda msgc
    cmp #M_FOUL
    bne hb
    ldx #29                 ; FOUL n first, then two blanks
    lda #<msfoul
    ldy #>msfoul
    jsr text
    inx
    lda msgv
    ora #CH_0
    jsr glyphc
    ldx #37
hb:
    lda #<mshand
    ldy #>mshand
    jmp ttip
fend:
    lda gmode               ; the tournament: the match's end (tournament.asm)
    cmp #1
    jeq tour_end
    ldx #38                 ; END
    lda #<msend
    ldy #>msend
ttip:
    jsr text
    jmp tip_draw            ; (the tip square in the bar's corner)
.endp

; shot_clock: every frame -- a human at the table thinks: from 30 s on the
; blue field shows SHOT TIME: m:ss, redrawn each second; a shot running: the
; clock at 0, the bar back if it showed (tmin > 0 or tst >= 3).  The seconds kept as digits.
; [2026-10-23 6502-idioms/SKILL.md: code size is RAM -- the digits are the state (no
;  divide), a flag that only waits in Y, one lda #0 for many stores, jsr / rts -> jmp]
.proc shot_clock
    lda gmode               ; the trick mode: no clock, its demo's countdown (trick.asm)
    cmp #3
    jeq trick_tick
    lda inhand              ; [2026-10-27] the cue taken in hand or put down: the bar again
    cmp inhs                ;   (BALL IN HAND on / off)
    beq ih
    sta inhs
    jsr hud_draw
ih:
    lda moving
    bne run
    lda rem                 ; at rest: the next shot rolls again (bit 6 off); the points
    and #$80                ;   left shown (bit 7) for REM_T frames, then the bar back
    sta rem
    bpl ck
    lda remt
    sec
    sbc fd_dt
    sta remt
    bcs ck
    lda #0
    sta rem
    jsr hud_draw
ck:
    lda fover               ; the frame over: none.  [2026-10-27] the computer's too: its
    bne out                 ;   plan's seconds come from the VBI (thkclk)
    ldx fd_dt               ; this frame's VBLANKs
    jsr sc_add
    tya
    bpl out                 ; no new second
shw:
    lda tmin
    bne dr                  ; 30 s or more: shown
    lda tst
    cmp #3
    bcs dr
out:
    rts
run:
    bit rem                 ; a shot: once, at random (1 in 12), the points left at its rest
    bvs r1
    lda RANDOM
    cmp #REM_P
    lda #$40
    bcs r0
    lda #$C0
r0: sta rem
    lda #REM_T
    sta remt
r1:
    ldx tmin                ; it showed: a minute or more (X), or 30 s (C)
    lda tst
    cmp #3
    lda #0                  ; (lda / sta keep C)
    sta tsub
    sta tsu
    sta tst
    sta tmin
    bcs bk
    txa
    beq out
bk: jmp hud_draw
dr:
    jsr hud_begin
    lda #HA_BLU             ; the blue field cleared
    ldx #27
    ldy #26
    jsr hfill
    ldx #32
    lda #<mstime
    ldy #>mstime
    jsr text                ; (X = the column after)
    inx
    lda tmin
    ldy #0
    jsr numl                ; (X = its last digit)
    inx
    lda #CH_CO
    jsr glyphc
    inx
    lda tst
    ora #CH_0
    jsr glyphc
    inx
    lda tsu
    ora #CH_0
    jsr glyphc
    jmp hud_end
.endp

; sc_add: X = VBLANKs -> onto the clock's digits; Y bit 7: a second passed
.proc sc_add
    ldy #0
    txa
    beq o
t:  inc tsub
    lda tsub
hz  cmp #50                 ; VBLANKs a second (frame_init: 60 on NTSC)
    bcc n
    ldy #$80
    lda #0
    sta tsub
    inc tsu
    lda tsu
    cmp #10
    bcc n
    lda #0
    sta tsu
    inc tst
    lda tst
    cmp #6
    bcc n
    lda #0
    sta tst
    inc tmin
n:  dex
    bne t
o:  rts
.endp

; thkclk: [2026-10-27] the VBI while the computer plans (thkblk): its plan is one frame
; of seconds and the frame loop's shot_clock stands -- a VBLANK at a time on the clock,
; from 30 s SHOT TIME redrawn each second through the window, which the plan's code
; and its sims have as they like: MEMAC-A's registers read back and put back (manual
; 1.27 ch. 6: readable), src (text's) kept.  fd_last on: the frame after the plan does
; not count it again
; [2026-10-28 fix: the computer thought 45 s and SHOT TIME never showed -- tsub..tmin
;  ($1FFC-$1FFF) and fd_last ($06EB) sat in pages simshot.asm scopy saves and puts back
;  around every sim, so each sim took the clock back (a 67 s plan counted 2.7 s); moved
;  to $1E36-$1E3A (defs.inc), a page no sim writes or restores]
.proc thkclk
    lda thk                 ; (a trick's demo: $80 -- its own clock)
    cmp #1
    bne o
    lda $14
    sta fd_last
    ldx #1
    jsr sc_add
    tya
    bpl o                   ; no new second
    lda tmin
    bne d
    lda tst
    cmp #3
    bcc o
d:  ldy #MA_CTL             ; the plan's window kept
    lda (VB),y
    pha
    iny
    lda (VB),y
    pha
    lda src
    pha
    lda src+1
    pha
    lda #$38                ; 4 KB at $3000 (the HUD's offsets)
    ldy #MA_CTL
    sta (VB),y
    jsr shot_clock.dr
    pla
    sta src+1
    pla
    sta src
    pla
    tax
    pla
    ldy #MA_CTL
    sta (VB),y
    txa
    iny
    sta (VB),y
o:  rts
.endp

; esc_menu: [2026-10-27, after doom-rapidus-vbxe's ESC panel (menu.asm mn_key / mn_open /
; mn_ingame)] ESC at the frame's start -- the game stops under a menu window (menu.asm
; esc_panel: CONTINUE / QUIT TO MENU).  The menu's block ($2000-$2FFF, ROT_LUT in the
; game) was parked at load in V:ESC_BANK000: swapped in, run, swapped back -- ROT_LUT
; comes back with it.  CONTINUE: the BCB window, the table repainted (set_angle: the
; window and its font went over both buffers), the frame's clock from now.
KEY_ESC  = $1C
ESC_BANK = $59              ; V:$059000: the menu's block (main.asm), free in the game
.proc esc_menu
    lda #$FF
    sta CH
    jsr bwait               ; (the table's last blits)
    jsr eswap
    jsr esc_panel           ; (QUIT TO MENU never returns)
    jsr eswap
    jsr win_bcb
    lda $14
    sta fd_last
    jsr set_angle           ; the table over the window (the pause XDL shows it till then:
    jsr bwait               ;   the game's would show the window in the table's palette)
    lda #0
    tax
    tay
    jmp exdla
.endp

; esc_quit: QUIT TO MENU [2026-10-27, after doom-rapidus-vbxe menu.asm rd_pages: the
; pages read back off the ATR, no reboot] -- the game left the title picture and the
; photos to the table's buffers: their raw sectors (atr.inc) back into V:$030000 /
; V:$060000 through SIOV, the machine as the title had it (the OS ROM in, its VBI, the
; sound's IRQ in front of the OS's), the title's XDL, the menu (this block still in
; RAM), then os_off and a new game from newgame (main.asm).  The menu's block goes back
; to V:ESC_BANK000 first (esave): the new game's zoom_set fills ROT_LUT over it.
SIOV    = $E459
SYSVBV  = $E45F
DCB     = $0300
DAUX1   = DCB+10
QBUF    = $1800             ; a sector (lbuf_lo: the aim line's, a new game's again)
.proc esc_quit
    jsr bwait
    lda #0                  ; black while the sectors come
    ldy #VIDEO_CONTROL
    sta (VB),y
    sei
    sta NMIEN
    lda os_irq              ; the OS's IRQ (SIO's), its VBI (SIO's timeouts)
    sta VIMIRQ
    lda os_irq+1
    sta VIMIRQ+1
    lda #<SYSVBV
    sta VVBLKI
    lda #>SYSVBV
    sta VVBLKI+1
    lda POKMSK              ; the sound's timer off (snd_init below)
    and #$FE
    sta POKMSK
    sta IRQEN
    lda PORTB               ; the OS ROM in
    ora #1
    sta PORTB
    lda #$40
    sta NMIEN
    cli
    ldx #11
d:  lda qdcb,x
    sta DCB,x
    dex
    bpl d
    lda #0                  ; (no sector read yet)
    sta qpos
    lda #[$030000>>12]      ; the title, then the photos: a stream each (zx02v.inc)
    jsr zxv
    lda #[$060000>>12]
    jsr zxv
    jsr snd_init            ; the sound's IRQ in front of the OS's again, as at the title
    jsr hud_end
    lda #<TITLE_XDL         ; the title's XDL (in the sectors read), shown
    ldx #>TITLE_XDL
    ldy #^TITLE_XDL
    jsr exdla
    lda #$05
    ldy #VIDEO_CONTROL
    sta (VB),y
    ldx #$FF                ; a fresh stack: the game is left
    txs
    lda #0                  ; the gradient column: the window's built again
    sta mgh
    jsr menu_back
    jsr os_off
    jsr esave
    jmp newgame
qdcb dta $31, 1, $52, $40, a(QBUF), $0F, 0, a(128), a(ATR_TITLE_SEC)
.endp

; menu_back: QUIT TO MENU's menu (esc_quit; menu.asm's block in RAM then) [2026-10-27] -- where the game came
; from (gmode): the match bar with its players and length, the tricks at the trick
; played, the tournament's draw
.proc menu_back
    ldx gmode               ; 0 the match, 1 the tournament, 3 the tricks
    lda mbs,x
    sta mstate
    lda mbm,x
    sta mmode
    lda gtrick
    sta mtrk
    lda bestw               ; best of 2 bestw - 1
    asl @
    sbc #0                  ; (C = 0: the asl of a small count)
    sta mbo
    lda #0
    sta simon
    jsr mltpl
    lda mstate
    cmp #1
    bne w
    jsr mbar1
    jmp menu.shw
w:  jsr mopen
    jmp menu.shw
mbs dta 1, 3, 0, 2
mbm dta 0, 1, 0, 2
.endp

; exdla: A:X:Y = the XDL's address -> XDL_ADR (A parked on the stack, no cell)
.proc exdla
    pha
    tya
    ldy #XDL_ADR2
    sta (VB),y
    txa
    dey
    sta (VB),y
    pla
    dey
    sta (VB),y
    rts
.endp

; erow: the pointer (its tip: x 2 mpx, row 2 mpy) on a row's strip -> C = 0, A = the
; row; else C = 1
.proc erow
    lda mpx
    cmp #EW_X/2+4
    bcc no
    cmp #[EW_X+EW_W]/2-4
    bcs no
    ldx #1
r:  lda mpy
    cmp ery0,x
    bcc n
    cmp ery1,x
    bcc y
n:  dex
    bpl r
no: sec
    rts
y:  txa
    rts                     ; (C = 0)
ery0 dta [EW_Y+11]/2, [EW_Y+31]/2
ery1 dta [EW_Y+27]/2, [EW_Y+47]/2
.endp

; the ZX02 streams of QUIT TO MENU (zx02v.inc), read by zx_gb from the DCB's sector on
ZX_OFF = $E0                ; zx02v.inc's cells: the aim line's DDA cells (laccy .. lend),
ZX_DST = $E2                ;   set again for every line drawn -- QUIT TO MENU leaves the
ZX_BIT = $E4                ;   game, the new one draws its lines anew
ZX_PTR = $E5

; zx_gb: the stream's next byte -- keeps X and C, leaves Y = 0 (zx02v.inc); a sector
; through SIOV into QBUF when the last is used up (the DCB on the next one)
.proc zx_gb
    ldy qpos
    bne ok
    php
    stx qx
r:  lda #$40
    sta DCB+3
    jsr SIOV
    bmi r                   ; an error: again
    lda QBUF+125            ; the next sector: the MyDOS link (make_atr.py: SNOOKER.DAT,
    sta DAUX1+1             ;   16-bit links, 125 bytes a sector)
    lda QBUF+126
    sta DAUX1
    ldx qx
    plp
    ldy #256-125            ; (Y counts up to 0: C kept)
ok: lda QBUF-[256-125],y
    iny
    sty qpos
    ldy #0
    rts
qx  dta 0
.endp
qpos dta 0                  ; the place in QBUF, 131..255 (0: read the next sector)

    icl 'zx02v.inc'

; esave: this block ($2000-$2FFF) -> V:ESC_BANK000 alone, the RAM kept (eswap with its
; RAM store turned into a load)
.proc esave
    lda #$BD                ; lda abs,x
    sta eswap.a4
    jsr eswap
    lda #$9D                ; sta abs,x
    sta eswap.a4
    rts
.endp

; eswap: $2000-$2FFF <-> V:ESC_BANK000, through the 4 KB window at $3000
.proc eswap
    ldy #MA_BSEL
    lda #$80|ESC_BANK
    sta (VB),y
    ldx #0
l:
a1  lda $2000,x
a2  ldy WINDOW,x
a3  sta WINDOW,x
    tya
a4  sta $2000,x
    inx
    bne l
    inc a1+2
    inc a2+2
    inc a3+2
    inc a4+2
    lda a3+2
    cmp #>[WINDOW+$1000]
    bne l
    lda #>$2000             ; the operands back for the next swap
    sta a1+2
    sta a4+2
    lda #>WINDOW
    sta a2+2
    sta a3+2
    jmp hud_end
.endp

; glyphc: A = a character at column X of line 1.  Keeps X.
.proc glyphc
    pha
    txa
    asl @
    tay
    pla
    sta HL1,y
    rts
.endp

; numc: A:Y = a number < 1000 -> its digits centred on column X (two from X - 1)
.proc numc
    jsr split
    lda fd_q
    ora n3t
    beq numl.d              ; (one digit)
    dex
    bne numl.d              ; (always: X > 1)
.endp

; numl: A:Y = a number < 1000 -> its digits from column X, no blanks
.proc numl
    jsr split
d:
    lda fd_q
    beq t
    ora #CH_0
    jsr glyphc
    inx
    lda n3t
    bpl t1                  ; (always: 0..9) the tens under a hundred
t:
    lda n3t
    beq u
t1:
    ora #CH_0
    jsr glyphc
    inx
u:
    lda n3u
    ora #CH_0
    jmp glyphc
.endp

; split: A:Y -> n3u = the units, n3t = the tens, fd_q = the hundreds (X kept)
.proc split
    stx n3c                 ; (fdiv counts in X)
    sta fd_q
    sty fd_q+1
    lda #10
    sta fd_dv
    jsr fdiv
    sta n3u
    jsr fdiv
    sta n3t
    ldx n3c
    rts
.endp

; fdiv: fd_q (16) / fd_dv (8) -> fd_q, A = the remainder
.proc fdiv
    lda #0
    ldx #16
lp:
    asl fd_q
    rol fd_q+1
    rol @
    bcs sub                 ; a 9-bit remainder is above any divisor
    cmp fd_dv
    bcc nx
sub:
    sbc fd_dv               ; (C = 1)
    inc fd_q
nx:
    dex
    bne lp
    rts
.endp

; text: A:Y = characters up to $FF -> line 1 from column X; X = the column after
; them.  text.a: the high byte already in src+1.
.proc text
    sty src+1
a:
    sta src
    txa
    asl @
    tax
    ldy #0
lp:
    lda (src),y
    bmi out
    sta HL1,x
    inx
    inx
    iny
    bne lp                  ; (always: a string < 80)
out:
    txa
    lsr @
    tax
    rts
.endp

; hfill: A = an attribute, X = a column, Y = columns -> blanks in it on the 3
; lines; X = the column after them
.proc hfill
    sta hcolr
    txa
    asl @
    tax
l:
    lda #0
    sta HL0,x
    sta HL1,x
    sta HL2,x
    lda hcolr
    sta HL0+1,x
    sta HL1+1,x
    sta HL2+1,x
    inx
    inx
    dey
    bne l
    txa
    lsr @
    tax
    rts
.endp

; tip_draw: the bar's corner (columns 76-79, white on black): the cue ball (the
; font's clean copy) and a dot of 3 lines x 6 HR pixels where the tip meets it
; (x 4 + 2 side, line 10 - spin: 1 SR pixel an R/8)
.proc tip_draw
    jsr hud_begin
    ldx #6                  ; the 12 chars: $40 + line * 4 + column
tc:
    txa
    lsr @
    ora #$40
    sta HL0+152,x
    ora #$04
    sta HL1+152,x
    eor #$0C
    sta HL2+152,x
    lda #HA_TIP
    sta HL0+153,x
    sta HL1+153,x
    sta HL2+153,x
    dex
    dex
    bpl tc
    ldx #95                 ; the clean ball
cp:
    lda TIPS+$80,x
    sta TIPS,x
    dex
    bpl cp
    lda side                ; the dot's first pixel 4 + 2 side: its column (s + 2) / 4,
    clc                     ;   its 6 pixels' masks over that byte and the next by (s + 2) & 3
    adc #2
    tax
    and #3
    tay
    lda dml,y
    sta n3t
    lda dmr,y
    sta hcolr
    txa
    and #$FC
    asl @                   ; (the column * 8: a char's bytes)
    sta n3c
    lda #3
    sta n3u
    lda #10
    sec
    sbc spin
    tax                     ; its first line (2..10 of 1..14)
r:
    lda rof-1,x
    clc
    adc n3c
    tay
    lda TIPS,y
    and n3t
    sta TIPS,y
    lda TIPS+8,y
    and hcolr
    sta TIPS+8,y
    inx
    dec n3u
    bne r
    jmp hud_end
dml dta $03, $C0, $F0, $FC  ; not ($FC00 >> 2k): the left byte, the right one
dmr dta $FF, $FF, $3F, $0F
rof TIP_ROF                 ; the bar's line 1..14 -> line * 32 + font row
.endp

; hud_begin: the window on the HUD's text and font; hud_end: back on bank 0 (the
; BCBs, as the renderer has it)
.proc hud_begin
    lda #$80|[HUD_VRAM>>12]
    dta $2C                 ; (bit abs: skips hud_end's lda)
    ert *<>hud_end
.endp

.proc hud_end
    lda #$80
    ldy #MA_BSEL
    sta (VB),y
    rts
.endp

; think_on: THINKING in place of the computer's name (its side of the bar) while
; it plans -- the HUD cannot change during that (its window holds the AI's code)
.proc think_on
    inc thk
    jsr hud_begin
    ldx turn                ; its side: P1's columns 0-21, P2's 58-75
    ldy thw,x
    lda thc,x
    tax
    lda #HA_THK             ; (its own colour: the VBI blinks it)
    jsr hfill
    ldx turn
    lda tht,x
    tax
    lda #<msthk
    ldy #>msthk
    jsr text
    jmp hud_end
thc dta 0, 58
thw dta 22, 18
tht dta 1, 67
.endp
msthk   dta d'THINKING', $FF

msp1    dta d'P1', $FF
msp2    dta d'P2', $FF
msfoul  dta d'FOUL', $FF
msend   dta d'END', $FF
msmiss  dta d'MISS', $FF
msfree  dta d'FREE BALL', $FF
mshand  dta d'BALL IN HAND', $FF
msbrk   dta d'BREAK', $FF
mstime  dta d'SHOT TIME:', $FF
msrem   dta d'POINTS REMAINING:', $FF
inhs    dta 0               ; inhand as the bar shows it (shot_clock)
rem     dta 0               ; the points left: bit 7 shown at the rest, bit 6 rolled this shot
remt    dta 0               ;   frames it stays
REM_P   = 21                ; its chance a shot: 21 / 256 (3-4 a frame)
REM_T   = 200               ;   4 s (PAL)
msbo    dta CH_LP, CH_0+3, CH_RP, $FF           ; (best of N: the menu writes N)
bestw   dta 2               ; frames to win the match: N / 2 + 1 (the menu's)
