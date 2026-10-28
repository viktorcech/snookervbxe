; menu.asm -- the title's menu bar, as the HUD's score bar (hud.asm's text lines)
; (tools/menu_mock.py): the mode  MATCH | TOURNAMENT | TRICK SHOTS  (a click
; chooses; the tournament's draw, the tricks' list in a window over the picture), the match
; < P1 > | VS | < P2 > | < BEST OF n > | PLAY | BACK,  driven by an ST mouse in port 2 (PORTA
; bits 4-5 x, 6-7 y, quadrature; the button = TRIG1).  Each player: a human (P1,
; P2) or one of 5 computer players, weakest first -> pty, pty+1 (0 / 1..5): two
; computers play each other too.  A field's left half: the previous one, its
; right half: the next.  The pointer is player 0 over the overlay (the title
; XDL's priority $FE).
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- loaded last at $2000 (ROT_LUT:
;  zoom_set fills it after the menu), the pointer in lbuf_sel: no game RAM.
;  VBXE 1.27 manual ch. 9: priority bit 0 = 0 -> PM0 covers the overlay;
;  alt-src antic.cpp: player DMA runs without the display list; inputcontroller.cpp:
;  the ST mouse's phases x 0,2,3,1 (bits 0-1), y the same on bits 2-3]
P0MEM  = $1A00              ; double-line player 0 (PMBASE $18): lbuf_sel, free until the aim line
HPOSP0 = $D000
GRAFP0 = $D00D
GRACTL = $D01D
PMBASE = $D407
PCOLR0 = $02C0
GPRIOR = $026F
MBAR   = [TITLE_BARY+1]/2   ; the bar's first pointer row (rows are 2 lines)

    org $2000
.proc menu
    jsr tour_reset          ; (a tournament left for the title: a new one -- before the
                            ;   zeros below: it leaves A its own)
    lda #0                  ; P1, P2: humans; the sounds not silenced (sim_shot's flag);
    sta pty                 ;   the mode bar first, MATCH chosen
    sta pty+1
    sta simon
    sta mstate
    sta mmode
    sta gmode               ; (MATCH: the mode bar's PLAY sets none)
    tax                     ; (A = 0) the photos: the picture (humans)
    jsr mopp.ph
    ldx #1
    jsr mopp.ph
    jsr mbar0
    jsr mltpl               ; the text lists' slots: a glyph BCB's constant bytes
shw:
    ldy #VIDEO_CONTROL      ; [2026-10-27] the display on: the picture and the bar at once
    lda #$05                ;   (XDL on, no transparent colour; title.asm left it off)
    sta (VB),y
    ldy #MA_BSEL            ; drawn: the bar shown (its priority 0 -> $FE)
    lda #$80|[TITLE_BARPRI>>12]
    sta (VB),y
    lda #$FE
    sta WINDOW+[TITLE_BARPRI&$FFF]
    lda #$28                ; the photos' attribute map on (its data loaded by now)
    sta WINDOW+[TITLE_MAPON&$FFF]
    lda #0                  ; the pointer: player 0, white, the others off screen
    tax
cl:
    sta P0MEM,x
    inx
    bpl cl
    sta HPOSP0+1
    sta HPOSP0+2
    sta HPOSP0+3
    lda #$18                ; PMBASE: player 0 at +$200 = P0MEM
    sta PMBASE
    lda #$0E
    sta PCOLR0
    lda #1
    sta GPRIOR
    lda #2
    sta GRACTL
    lda #$08                ; player DMA only, 2 lines a byte (the OS VBI copies it)
    sta SDMCTL
poll:
    jsr mstep
    lda $14                 ; a new frame: the pointer moved there
    cmp mlf
    beq bt
    sta mlf
    jsr ptr
bt:
    lda TRIG0+1             ; the button (TRIG1, port 2): act on its press
    cmp mlb
    beq poll
    sta mlb
    lsr @
    bcs poll                ; (released)
    lda mpy                  ; on the bar?
    sec
    sbc #MBAR
    cmp #8
    jcs poll                ; (above it: the window -- nothing to click)
onb:
    lda mpx                 ; its column / 2: 2 colour clocks a pointer step, 2 a column
    lsr @
    lsr @
    sta mk
    ldx mstate
    ldy mft0,x              ; the state's field ends -> X = the field
    ldx #$FF
f0: inx
    cmp mend,y
    iny
    bcs f0
    lda mstate
    bne s1
    stx mmode               ; the mode bar: a click chooses -- its bar (and window)
    lda mst0,x
    sta mstate
    cmp #1
    bne om
    jsr mbar1
    jmp clk
om: jsr mopen
    jmp clk
s1: cmp #1
    jeq s1m
    cpx #2                  ; BACK: the window off, the mode bar
    bne t1
    jsr mclose
    lda #0
    sta mstate
    jsr mbar0
    jmp clk
t1: cpx #1
    bne t2
    ldx mstate              ; START: the mode -- the tricks 3, the tournament 1
    lda mgm-2,x
    sta gmode
    lda mtrk
    sta gtrick
    jmp play
t2: lda mstate              ; < the trick >: its left half the previous, the right the next
    cmp #3
    jeq poll                ; (the tournament's: the first match only)
    lda mk
    cmp #10
    lda mtrk
    bcs tn
    sbc #0                  ; (C = 0: - 1)
    bpl tw
    lda #TK_N-1
    bpl tw                  ; (always)
tn: adc #0                  ; (C = 1: + 1)
    cmp #TK_N
    bcc tw
    lda #0
tw: sta mtrk                ; the trick: the bar's field, its description in the window
    jsr mwin
    jsr mhelpd
tb: jsr mbarx
    jmp clk
s1m:
    cpx #5                  ; the match bar: BACK
    bne s2
    dec mstate
    jsr mbar0
    jmp clk
s2: cpx #4
    bne s3
    lda #0                  ; PLAY: a match (QUIT TO MENU's menu_back keeps the gmode
    sta gmode               ;   it came from: a trick's 3 would rack the trick again)
    jmp play
s3: cpx #1
    jeq poll                ; (VS)
    lda mk                  ; its left half: the previous one (-1), the right: the next (+1)
    cmp mhalf,x
    lda #$FF
    bcc dr
    lda #1
dr: sta mdir
    cpx #3
    bne pl
    asl @                   ; BEST OF n: n +- 2, 1..9 wrapping
    clc
    adc mbo
    bpl b0
    lda #9
b0: cmp #10
    bcc b1
    lda #1
b1: sta mbo
    jsr mbest
    jmp clk
pl: txa                     ; a player: P1 (field 0) or P2 (2) -> X = 0 / 1
    lsr @
    tax
    eor #1                  ; the other side's player -> mo
    tay
    lda pty,y
    sta mo
    lda pty,x
st:
    clc                     ; 0..5, wrapping
    adc mdir
    bpl ps0
    lda #5
ps0:
    cmp #6
    bcc ps1
    lda #0
ps1:
    tay                     ; (Z: a human -- both sides may be)
    beq set
    cmp mo                  ; the other side's computer: not twice, one more step
    beq st
set:
    sta pty,x
    jsr mopp
clk:
    ldx #SND_CLICK          ; two balls clacking
    jsr snd_play
    jmp poll
play:
    lda mbo                 ; the match's length: the HUD's (n), the rules' n / 2 + 1
    ora #CH_0
    sta msbo+1
    lda mbo
    lsr @
    adc #0                  ; (n odd: C = 1 -> + 1)
    sta bestw
    lda gmode               ; the tournament: its match (tournament.asm)
    cmp #1
    bne pz
    jsr tour_start
pz: lda #0                  ; the pointer off (GTIA keeps no player data)
    sta GRACTL
    sta GRAFP0
    sta HPOSP0
    sta SDMCTL
    rts
.endp

; mstep: the mouse in port 2 (PORTA's high nibble): mpx, mpy by their phase steps (qd)
; -- polled as often as the loop runs (the title's menu, the ESC menu)
.proc mstep
    lda PORTA
    lsr @
    lsr @
    lsr @
    lsr @
    sta mpa
    and #3
    tax
    ora mox
    tay
    lda qd,y
    clc
    adc mpx
    cmp #160                ; (0 - 1 = $FF and 159 + 1 = 160: both kept out)
    bcs nx
    sta mpx
nx:
    txa
    asl @
    asl @
    sta mox
    lda mpa
    lsr @
    lsr @
    and #3
    tax
    ora moy
    tay
    lda qd,y
    clc
    adc mpy
    cmp #117                ; (the pointer's 8 bytes stay inside player 0)
    bcs ny
    sta mpy
ny:
    txa
    asl @
    asl @
    sta moy
    rts
.endp

; ptr: player 0's arrow from row mpy + 4 (overlay line 2 mpy = scan line 2 mpy + 8),
; at colour clock 48 + mpx; the old rows cleared first
.proc ptr
    ldx mpr
    ldy #7
    lda #0
c0:
    sta P0MEM,x
    inx
    dey
    bpl c0
    lda mpy
    clc
    adc #4
    sta mpr
    tax
    ldy #0
c1:
    lda arrow,y
    sta P0MEM,x
    inx
    iny
    cpy #8
    bne c1
    lda mpx
    clc
    adc #48
    sta HPOSP0
    rts
.endp

; mopp: X = 0 P1 / 1 P2 -> its field: < name > on yellow, columns 0-19 / 26-45,
; the name centred (a human: P1 / P2; a computer: ai.asm's names); mopp.ph: X = the
; side -> its photo alone
.proc mopp
    stx mside
    lda mbase,x
    sta mcol
    jsr hud_begin
    lda #HA_YEL
    ldx mcol
    ldy #20
    jsr hfill               ; (X: the column after the field)
    dex
    dex
    lda #CH_GT
    jsr glyphc
    ldx mcol
    inx
    lda #CH_LT
    jsr glyphc
    ldx mside
    ldy pty,x               ; its player: the name from mcol + 14 - length / 2
    lda ai_nn,y
    lsr @
    eor #$FF                ; (- length / 2 - 1, C = 1 below: + 1)
    sec
    adc mcol
    clc
    adc #10
    pha
    lda ai_nh,y
    sta src+1
    lda ai_nl,y
    cpy #0
    bne nm
    lda mhh,x               ; a human: P1 / P2
    sta src+1
    lda mhl,x
nm:
    sta src
    pla
    tax
    lda src
    jsr text.a
    ldx mside
ph:                         ; (X = the side) its photo above it: the BCB pair vbxe_export.py built
    lda pty,x               ;   (PHOTO_BCB, side * 6 + its player: 0 a human = the
    clc                     ;   picture back)
    adc mpo,x
    tax
    jsr bwait               ; (the other side's photo done)
    ldy #BL_ADR0
    lda mpbl,x
    sta (VB),y
    iny
    lda mpbm,x
    sta (VB),y
    iny
    lda #^PHOTO_BCB
    sta (VB),y
    jsr bstart              ; (keeps Y)
    lda #$01                ; BL_ADR1 / 2 back to the renderer's $01 / 0 (it sets
    dey                     ;   BL_ADR0 only; BL_ADR is buffered: the list started
    sta (VB),y              ;   is not disturbed)
    lda #0
    iny
    sta (VB),y
    lda #$FF                ; BL_ADR0 is not the renderer's any more
    sta rcurbl
    jmp hud_end
mbase dta 0, 26
mpo   dta 0, 6
mpbl  :12 dta <[PHOTO_BCB+#*42]
mpbm  :12 dta >[PHOTO_BCB+#*42]
mhl   dta <msp1, <msp2
mhh   dta >msp1, >msp2
.endp

    ert ^PHOTO_BCB<>^[PHOTO_BCB+11*42] || TITLE_MAPON>>12<>TITLE_BARPRI>>12

; mbar0: the mode bar -- MATCH | TOURNAMENT | TRICK SHOTS, yellow, white, yellow:
; a click on one chooses it
.proc mbar0
    jsr hud_begin
    ldx #2
f:  stx mk
    lda #HA_YEL             ; its attribute: yellow, white by turns
    cpx #1
    bne a1
    lda #HA_WHT
a1: ldy m0w,x               ; its columns
    pha
    lda m0c,x
    tax
    pla
    jsr hfill
    ldx mk                  ; its text
    lda m0sl,x
    ldy m0sh,x
    pha
    lda m0t,x
    tax
    pla
    jsr text
    ldx mk
    dex
    bpl f
    jmp hud_end
.endp

; mbar1: the match bar -- < P1 > | VS | < P2 > | < BEST OF n > | PLAY | BACK
.proc mbar1
    jsr hud_begin
    lda #HA_WHT             ; VS (20-25)
    ldx #20
    ldy #6
    jsr hfill
    ldx #22
    lda #<mvs
    ldy #>mvs
    jsr text
    lda #HA_BLU             ; PLAY (62-71)
    ldx #62
    ldy #10
    jsr hfill
    ldx #65
    lda #<mplay
    ldy #>mplay
    jsr text
    lda #HA_TIP             ; BACK (72-79): white on black
    ldx #72
    ldy #8
    jsr hfill
    ldx #74
    lda #<mback
    ldy #>mback
    jsr text
    jsr hud_end
    ldx #0                  ; the players' fields, their photos
    jsr mopp
    ldx #1
    jsr mopp
    ert *<>mbest            ; falls into the length's field
.endp

; mbest: < BEST OF n > (46-61) on white
.proc mbest
    jsr hud_begin
    lda #HA_WHT
    ldx #46
    ldy #16
    jsr hfill
    ldx #47
    lda #CH_LT
    jsr glyphc
    ldx #60
    lda #CH_GT
    jsr glyphc
    ldx #49
    lda #<mbtx
    ldy #>mbtx
    jsr text                ; (X = 56)
    inx
    lda mbo
    ora #CH_0
    jsr glyphc
    jmp hud_end
.endp

; mbarx: the bar of the tricks (2), the tournament (3) -- < its field > (0-39) |
; START | BACK; the tournament's field without the arrows
.proc mbarx
    lda mstate
    cmp #3
    beq m3
    lda mtrk                ; the trick: its name (its record: tk_load)
    jsr tk_load
    lda #<tkb_n
    ldx #>tkb_n
    bne m5                  ; (always)
m3: jsr tour_bar            ; (tournament.asm: NEXT / CHAMPION! / KNOCKED OUT)
m5: sta src
    stx src+1
    jsr hud_begin
    lda #HA_YEL
    ldx #0
    ldy #40
    jsr hfill
    lda mstate
    cmp #3
    beq na
    ldx #1
    lda #CH_LT
    jsr glyphc
    ldx #38
    lda #CH_GT
    jsr glyphc
na: ldy #0                  ; its text, centred on column 20
ln: lda (src),y
    bmi le
    iny
    bne ln
le: tya
    lsr @
    eor #$FF
    sec
    adc #20                 ; 20 - length / 2
    tax
    lda src
    jsr text.a
    lda #HA_BLU             ; START (40-59)
    ldx #40
    ldy #20
    jsr hfill
    ldx #47
    lda #<mstart
    ldy #>mstart
    jsr text
    lda #HA_TIP             ; BACK (60-79)
    ldx #60
    ldy #20
    jsr hfill
    ldx #68
    lda #<mback
    ldy #>mback
    jsr text
    jmp hud_end
.endp


; --- the windows over the title picture (V:$030000, 320 a line): the tricks' help
; (2), the tournament's draw (3) -- a green gradient in a gold frame, the text in
; tools/menu_gfx.py's font (V:$071000: gold, then white glyphs, 0 transparent: one
; mode-1 blit a letter).  The picture under a window saved in bands to the VRAM
; free till the game (V:$03F000 20 KB, $00D000 12 KB, $04C000 8 KB, $058300 3 KB;
; $044000 on holds the sounds).  The blits of a window and of a text line go as
; one BCB list (mlbeg / mlend: the text lines' two lists from V:$070100 by turns,
; the CPU building one while the other blits, their constant bytes filled once
; (mltpl); the window's at V:$070700); msave's bands alone one BCB at V:$070000,
; waited for.
; [2026-10-26 vbxe-blitter/SKILL.md: a constant fill is AND 0, XOR colour; mode 1
;  skips the source's 0s -- a glyph costs what it draws.  2026-10-27: fewer, larger
;  blits, fire early, wait late -- a window was 180 one-row fills and every letter a
;  blit, each waited for (~0.4 s a trick); the window is 240 wide now (was 200)]
    icl '../build/assets/menugfx.inc'
PIC_T = 29                  ; the picture's first overlay line: (240 - 181) / 2 (vbxe_export.py)
    ert TITLE_BARY<>PIC_T+181+7
TL_X = 40                   ; the tricks' list: x, width, top, height, its first strip
TL_W = 240                  ;   (tools/trick_sim.py wraps the texts to TL_W - 20 px)
TL_Y = 0
TL_H = 180
TL_T = TL_Y+5
TB_X = 40                   ; the draw
TB_W = 240
TB_Y = 6
TB_H = 150
    ert 12*13+TL_T+8>TL_Y+TL_H || TL_Y+TL_H>181     ; (mhelpd: up to 12 lines)
    ert TL_W*85>$5000 || TL_W*51>$3000 || TL_W*34>$2000 || TL_W*10>$1000 || 85+51+34+10<>TL_H
    ert TB_W*85>$5000 || TB_W*51>$3000 || TB_W*14>$2000 || 85+51+14<>TB_H

; mopen: the bar and the window of state 2, 3 (mstate): both players humans first
; (the photos: the picture back under them)
.proc mopen
    lda #0
    sta pty
    sta pty+1
    tax
    jsr mopp.ph
    ldx #1
    jsr mopp.ph
    clc
    jsr msave               ; the picture under the window saved
    jsr mwin
    lda mstate
    cmp #3
    beq t
    jsr mhelpd              ; the tricks: the chosen one's description
    jmp mbarx
t:  jsr tdrawb              ; (tournament.asm: the draw with its results)
    jmp mbarx
.endp

; mhelpd: the chosen trick's description in the window (trickhelp.inc: th_lo / th_hi
; its first line, th_n its lines), 13 lines apart from TL_T+8; < > redraw it (mwin
; first).  A line is one blit list, built while the line before blits.
.proc mhelpd
    ldx mtrk
    lda th_lo,x
    sta src
    lda th_hi,x
    sta src+1
    lda th_n,x
    sta mi2
    lda #TL_T+8
    sta mi3
h:  ldx mlbf                ; the text buffers by turns
    jsr mlbeg
    lda #TL_X+10
    ldx mi3
    ldy #0
    jsr mpos
    jsr mtx
    jsr mlend
    ldy mi                  ; (mi: its $FF's index -- the next line follows)
    iny
    tya
    clc
    adc src
    sta src
    bcc p
    inc src+1
    clc
p:  lda mi3
    adc #13
    sta mi3
    dec mi2
    bne h
    rts
.endp

; mclose: the window's picture back
.proc mclose
    sec
    ert *<>msave
.endp

; msave: C = 0: the window's picture -> its bands; C = 1: the bands -> the picture
.proc msave
    lda #0
    rol @
    sta msd
    ldx mstate              ; its bands (mbr ..): from mbb
    lda mbb-2,x
    sta mi2
b:  jsr mrect
    ldx mi2
    lda mbr,x
    jeq o
    sta mh
    lda mby,x               ; (its first row)
    clc
    adc my
    sta my
    jsr mdst                ; mbc+6..8: the picture's
    ldx mi2
    lda msd
    bne bk
    ldy #2                  ; save: the picture -> the band (mw a line)
c:  lda mbc+6,y
    sta mbc,y
    dey
    bpl c
    lda #<320
    sta mbc+3
    lda #>320
    sta mbc+4
    lda #0
    sta mbc+6
    lda mbm,x
    sta mbc+7
    lda mbh,x
    sta mbc+8
    lda mw
    sta mbc+9
    lda mw+1
    sta mbc+10
    jmp go
bk: lda #0                  ; back: the band -> the picture
    sta mbc
    lda mbm,x
    sta mbc+1
    lda mbh,x
    sta mbc+2
    lda mw
    sta mbc+3
    lda mw+1
    sta mbc+4
    lda #<320
    sta mbc+9
    lda #>320
    sta mbc+10
go: lda #0                  ; a copy: AND $FF, XOR 0
    sta mbc+16
    lda #$FF
    jsr mblit
    inc mi2
    jmp b
o:  lda #<320               ; the destination step back to the picture's (mfill, mtx,
    sta mbc+9               ;   mwin rely on it: set here and by mltpl alone)
    lda #>320
    sta mbc+10
    rts
; the bands: rows, their first row, the save's address (bits 8-19); 0 ends a window's
mbb dta 0, 5
mbr dta 85, 51, 34, 10, 0, 85, 51, 14, 0
mby dta 0, 85, 136, 170, 0, 0, 85, 136, 0
mbm dta $F0, $D0, $C0, $83, 0, $F0, $D0, $C0, 0
mbh dta $03, $00, $04, $05, 0, $03, $00, $04, 0   ; (the tricks' last band: V:$058300, [2026-10-27] the
                            ;   discs' bank's free tail -- $05E000 on is the small font)
.endp
    ert 170+8<>TL_H-2 || 136+12<>TB_H-2     ; (mwin's corners: the last band's row H - 2)

; mrect: mstate 2 / 3 -> mx, my, mw, mh = its window, mwh its height
.proc mrect
    ldx mstate
    lda mrxl-2,x
    sta mx
    lda #0
    sta mx+1
    lda mrwl-2,x
    sta mw
    lda mrwh-2,x
    sta mw+1
    lda mry-2,x
    sta my
    lda mrh-2,x
    sta mh
    sta mwh
    rts
mrxl dta TL_X, TB_X
mrwl dta <TL_W, <TB_W
mrwh dta >TL_W, >TB_W
mry  dta TL_Y, TB_Y
mrh  dta TL_H, TB_H
.endp

; mwin: the window (mrect) as one blit list: its rows a gradient -- one pattern-mode
; copy (pattern width 1: a row repeats its byte of the column at V:$070800, mgr's
; colours, built once a height), the picture back in the 4 cut corners (2 x 2 off
; the saved bands: the top band's first row, the last band's row H - 2), then the
; gold frame and a dark one inside it (mfr*)
.proc mwin
    ldx #2                  ; its own list (the window on bank $70: the column, the list)
    jsr mlbeg
    jsr mrect
    lda mwh                 ; the gradient column for this height, once
    cmp mgh
    beq gd
    sta mgh
    sta mi2
g:  dec mi2
    lda mi2
    jsr mgr
    ldx mi2
    sta WINDOW+$900,x
    txa
    bne g
gd: lda #0                  ; the gradient: a pattern copy, the column its source
    sta mbc
    sta mbc+4
    sta mbc+16
    sta mbc+20
    lda #9
    sta mbc+1
    lda #7
    sta mbc+2
    lda #1                  ; the source: a row down a byte
    sta mbc+3
    lda #$80                ; the pattern: a row repeats its first byte
    sta mbc+19
    jsr mdst
    lda #$FF
    jsr mblit
    lda #0
    sta mbc+19
    ldx #3                  ; the 4 corners: the picture back, 2 x 2 off the saved bands
k:  stx mi2
    jsr mrect
    lda mw                  ; the band's pitch: the window's width
    sta mbc+3
    lda mw+1
    sta mbc+4
    lda mstate              ; the entry: (mstate - 2) * 4 + the corner
    asl @
    asl @
    adc mi2                 ; (C = 0: the asl of 2 / 3)
    tax
    lda mcsl-8,x
    sta mbc
    lda mcsm-8,x
    sta mbc+1
    lda mcsh-8,x
    sta mbc+2
    lda mcxl-8,x
    sta mx
    lda mcxh-8,x
    sta mx+1
    lda mcy-8,x
    sta my
    lda #2
    sta mw
    sta mh
    lda #0
    sta mw+1
    jsr mdst
    lda #$FF
    jsr mblit
    ldx mi2
    dex
    bpl k
    ldx #11                 ; the frames: the window's 12 rects
    lda mstate
    cmp #3
    bne f0
    ldx #23
f0: lda #12
    sta mi3
f:  stx mi2
    lda mfrl,x
    sta mx
    lda mfrh,x
    sta mx+1
    lda mfry,x
    sta my
    lda mfrw,x
    sta mw
    lda #0
    sta mw+1
    lda mfrt,x
    sta mh
    lda mfrc,x
    jsr mfill
    ldx mi2
    dex
    dec mi3
    bne f
    jmp mlend
; the corners' picture: the saved bands' bytes (the top band's row 0, the last band's
; row H - 2: msave's tables), the corner's x, y -- the tricks' window, the draw's
mcsl dta <$03F000, <[$03F000+TL_W-2], <[$058300+8*TL_W], <[$058300+9*TL_W-2]
     dta <$03F000, <[$03F000+TB_W-2], <[$04C000+12*TB_W], <[$04C000+13*TB_W-2]
mcsm dta >$03F000, >[$03F000+TL_W-2], >[$058300+8*TL_W], >[$058300+9*TL_W-2]
     dta >$03F000, >[$03F000+TB_W-2], >[$04C000+12*TB_W], >[$04C000+13*TB_W-2]
mcsh dta ^$03F000, ^[$03F000+TL_W-2], ^[$058300+8*TL_W], ^[$058300+9*TL_W-2]
     dta ^$03F000, ^[$03F000+TB_W-2], ^[$04C000+12*TB_W], ^[$04C000+13*TB_W-2]
mcxl dta <TL_X, <[TL_X+TL_W-2], <TL_X, <[TL_X+TL_W-2], <TB_X, <[TB_X+TB_W-2], <TB_X, <[TB_X+TB_W-2]
mcxh dta >TL_X, >[TL_X+TL_W-2], >TL_X, >[TL_X+TL_W-2], >TB_X, >[TB_X+TB_W-2], >TB_X, >[TB_X+TB_W-2]
mcy  dta TL_Y, TL_Y, TL_Y+TL_H-2, TL_Y+TL_H-2, TB_Y, TB_Y, TB_Y+TB_H-2, TB_Y+TB_H-2
; the frames' rects: top, bottom, left, right, the 4 corner pixels (gold); inside
; at inset 3 top, bottom, left, right (dark) -- the tricks' window, the draw's
mfrl dta <[TL_X+2], <[TL_X+2], <TL_X, <[TL_X+TL_W-1], <[TL_X+1], <[TL_X+TL_W-2], <[TL_X+1], <[TL_X+TL_W-2]
     dta <[TL_X+3], <[TL_X+3], <[TL_X+3], <[TL_X+TL_W-4]
     dta <[TB_X+2], <[TB_X+2], <TB_X, <[TB_X+TB_W-1], <[TB_X+1], <[TB_X+TB_W-2], <[TB_X+1], <[TB_X+TB_W-2]
     dta <[TB_X+3], <[TB_X+3], <[TB_X+3], <[TB_X+TB_W-4]
mfrh dta >[TL_X+2], >[TL_X+2], >TL_X, >[TL_X+TL_W-1], >[TL_X+1], >[TL_X+TL_W-2], >[TL_X+1], >[TL_X+TL_W-2]
     dta >[TL_X+3], >[TL_X+3], >[TL_X+3], >[TL_X+TL_W-4]
     dta >[TB_X+2], >[TB_X+2], >TB_X, >[TB_X+TB_W-1], >[TB_X+1], >[TB_X+TB_W-2], >[TB_X+1], >[TB_X+TB_W-2]
     dta >[TB_X+3], >[TB_X+3], >[TB_X+3], >[TB_X+TB_W-4]
mfry dta TL_Y, TL_Y+TL_H-1, TL_Y+2, TL_Y+2, TL_Y+1, TL_Y+1, TL_Y+TL_H-2, TL_Y+TL_H-2
     dta TL_Y+3, TL_Y+TL_H-4, TL_Y+3, TL_Y+3
     dta TB_Y, TB_Y+TB_H-1, TB_Y+2, TB_Y+2, TB_Y+1, TB_Y+1, TB_Y+TB_H-2, TB_Y+TB_H-2
     dta TB_Y+3, TB_Y+TB_H-4, TB_Y+3, TB_Y+3
mfrw dta TL_W-4, TL_W-4, 1, 1, 1, 1, 1, 1, TL_W-6, TL_W-6, 1, 1
     dta TB_W-4, TB_W-4, 1, 1, 1, 1, 1, 1, TB_W-6, TB_W-6, 1, 1
mfrt dta 1, 1, TL_H-4, TL_H-4, 1, 1, 1, 1, 1, 1, TL_H-6, TL_H-6
     dta 1, 1, TB_H-4, TB_H-4, 1, 1, 1, 1, 1, 1, TB_H-6, TB_H-6
mfrc :8 dta MG_FRAME
     :4 dta MG_FRIN
     :8 dta MG_FRAME
     :4 dta MG_FRIN
.endp

; mgr: A = a row of the window (mwh high) -> A = its gradient colour, mg_g[16 A / mwh]
.proc mgr
    ldx #0
    stx mt
    asl @
    rol mt
    asl @
    rol mt
    asl @
    rol mt
    asl @
    rol mt
    ldx #$FF
d:  inx
    sec
    sbc mwh
    tay
    lda mt
    sbc #0
    sta mt
    tya
    bcs d
    lda mg_g,x
    rts
.endp


; mpos: A = x, X = y, Y = the colour (0 gold, 1 white) -> mx, my, mcolr
.proc mpos
    sta mx
    stx my
    sty mcolr
    lda #0
    sta mx+1
    rts
.endp

; mtx: src = a text ($FF ends it) -> drawn at mx, my in mcolr (0 gold, 1 white):
; each letter one blit of its glyph (mode 1: its 0s transparent), mx on by its advance
.proc mtx
    lda #0
    sta mi
    jsr mdst                ; mva = the line's start: the glyphs step it on
c:  ldy mi
    lda (src),y
    bmi e
    tax
    lda mf_w,x
    beq a                   ; (a space: no glyph)
    ldy mlon
    beq sl
    ldy #3                  ; a text list (mhelpd): the slot's 8 variable bytes, the
    sta (wptr),y            ;   rest mltpl's -- the source's rows w apart,
    sec
    sbc #1
    ldy #12                 ;   the width - 1,
    sta (wptr),y
    lda mf_ol,x             ;   the glyph: V:$070000 + its offset (+ MF_C1: white),
    ldy mcolr
    beq g0
    clc
    adc #<MF_C1
g0: ldy #0
    sta (wptr),y
    lda mf_oh,x
    ldy mcolr
    beq g1
    adc #>MF_C1             ; (C: the low byte's)
g1: ldy #1
    sta (wptr),y
    ldy #6                  ;   the destination (its bank 3: the template's),
    lda mva
    sta (wptr),y
    iny
    lda mva+1
    sta (wptr),y
    ldy #20                 ;   mode 1 and the next flag (mlend turns the last one's off)
    lda #1|8
    sta (wptr),y
    lda wptr                ; the slot after
    clc
    adc #21
    sta wptr
    bcc n
    inc wptr+1
n:  inc mlq
a:  ldy mi
    lda (src),y
    tax
    lda mf_a,x              ; on by its advance (320 my + mx < $10000: byte 2 holds)
    clc
    adc mva
    sta mva
    bcc n2
    inc mva+1
n2: inc mi
    bne c                   ; (always)
e:  rts
sl: sta mw                  ; no list (mdraw): one blit, waited for -- out of line,
    sta mbc+3               ;   the list's path falls through to `a` (its rows: w apart)
    lda #0
    sta mw+1
    sta mbc+4
    sta mbc+16
    lda #MF_H
    sta mh
    lda mf_ol,x             ; the glyph: V:$070000 + its offset (+ MF_C1: white)
    ldy mf_oh,x
    ldx mcolr
    beq g
    clc
    adc #<MF_C1
    pha
    tya
    adc #>MF_C1
    tay
    pla
g:  sta mbc
    sty mbc+1
    lda #7
    sta mbc+2
    lda #1                  ; mode 1, AND $FF, XOR 0 (the destination: mva, stepped)
    sta mbc+20
    lda #$FF
    jsr mblit
    lda #0
    sta mbc+20
    beq a                   ; (always)
.endp

; mdst: mx, my -> mva = mbc+6..8: the picture's V:$030000 + 320 my + mx
.proc mdst
    lda my
    sta mva
    lda #0
    sta mva+1
    ldx #6                  ; 64 my
s:  asl mva
    rol mva+1
    dex
    bne s
    clc
    lda mva
    adc mx
    sta mva
    lda mva+1
    adc mx+1
    adc my                  ; + 256 my (no carry: 320 my + mx < $10000)
    sta mva+1
    lda #3
    sta mva+2
    rts
.endp

; mfill: A = a colour -> the picture's rect mx, my, mw, mh filled
.proc mfill
    sta mbc+16              ; XOR: the colour, AND 0: a fill
    jsr mdst
    lda #0
    ert *<>mblit
.endp

; mblit: A = AND -> mbc (its width, height from mw, mh): a list open (mlbeg), the
; BCB appended to it; else run from V:$070000, waited for, BL_ADR back to the
; renderer's $01 / 0
.proc mblit
    sta mbc+15
    sec
    lda mw
    sbc #1
    sta mbc+12
    lda mw+1
    sbc #0
    sta mbc+13
    ldx mh
    dex
    stx mbc+14
    lda #1
    sta mbc+5
    sta mbc+11
    lda mlon
    beq im
    ldy #20                 ; appended: the next flag on (mlend turns the last one's off)
    lda mbc+20
    ora #$08
    sta (wptr),y
    dey
c:  lda mbc,y
    sta (wptr),y
    dey
    bpl c
    lda wptr                ; the slot after
    clc
    adc #21
    sta wptr
    bcc n
    inc wptr+1
n:  inc mlq
    rts
im: jsr bwait
    ldy #MA_BSEL
    lda #$80|$70
    sta (VB),y
    ldx #20
cp: lda mbc,x
    sta WINDOW,x
    dex
    bpl cp
    jsr hud_end
    ldy #BL_ADR0
    lda #0
    sta (VB),y
    iny
    sta (VB),y
    iny
    lda #7
    sta (VB),y
    jsr bstart
    jsr bwait
    ldy #BL_ADR1
    lda #$01
    sta (VB),y
    iny
    lda #0
    sta (VB),y
    lda #$FF                ; BL_ADR0: not the renderer's any more
    sta rcurbl
    rts
.endp

; mlbeg / mlend: a blit list in bank $70 -- X = the buffer: 0, 1 the text lines'
; (36 slots each from V:$070100, by turns: the CPU builds one while the other
; blits; their constant bytes mltpl's), 2 the window's (V:$070700).  mlbeg opens
; one (mblit appends to it from then on; the window on bank $70), mlend closes it
; (the last BCB's next flag off), waits for the list before (a START while busy
; is ignored) and starts it.
.proc mlbeg
    stx mlcur
    lda #1
    sta mlon
    ldy #0
    sty mlq
    lda mlbl,x              ; the buffer in the window
    sta wptr
    lda mlbh,x
    sta wptr+1
    lda #$80|$70
    ldy #MA_BSEL
    sta (VB),y
    rts
mlbl dta <[WINDOW+$100], <[WINDOW+$100+36*21], <[WINDOW+$700]
mlbh dta >[WINDOW+$100], >[WINDOW+$100+36*21], >[WINDOW+$700]
.endp
    ert $100+72*21>$700 || $700+17*21>$870 || $870+21>$900     ; (the lists, mltpl's template, mwin's column)

.proc mlend
    lda #0
    sta mlon
    lda mlq
    beq x
    lda wptr                ; the last slot's byte 20 (wptr - 1): the next flag off
    bne d
    dec wptr+1
d:  dec wptr
    ldy #0
    lda (wptr),y
    and #$F7
    sta (wptr),y
    jsr bwait
    ldx mlcur
    lda mlbeg.mlbl,x        ; BL_ADR = V:$07xxxx: the buffer
    ldy #BL_ADR0
    sta (VB),y
    lda mlbm,x
    iny
    sta (VB),y
    lda #7
    iny
    sta (VB),y
    lda mlbf                ; the text buffers by turns
    eor #1
    sta mlbf
    jsr bstart
    ldy #BL_ADR1            ; BL_ADR back to the renderer's $01 / 0 (read at START only)
    lda #$01
    sta (VB),y
    iny
    lda #0
    sta (VB),y
    lda #$FF
    sta rcurbl
x:  jmp hud_end             ; (bank 0 back)
mlbm dta >[$100], >[$100+36*21], >[$700]
.endp

; mltpl (the menu's start): the text lists' 72 slots filled with a glyph BCB's
; constant bytes -- the template written once, a pattern copy 21 wide spreads it
; (504 = 24 slots a row, 3 rows); mtx then writes a glyph's 8 variable bytes only
; [2026-10-27 vbxe-blitter/SKILL.md: template the constant fields once, write only
;  what changes]
.proc mltpl
    ldy #MA_BSEL
    lda #$80|$70
    sta (VB),y
    ldx #20
c:  lda mtpl,x
    sta WINDOW+$870,x
    dex
    bpl c
    lda #<$0870             ; the source: the template, every row the same
    sta mbc
    lda #>$0870
    sta mbc+1
    lda #7
    sta mbc+2
    sta mbc+8               ; the destination: V:$070100, rows 504 apart
    lda #0
    sta mbc+3
    sta mbc+4
    sta mbc+6
    sta mbc+16
    sta mbc+20
    lda #1
    sta mbc+7
    lda #<504
    sta mbc+9
    sta mw
    lda #>504
    sta mbc+10
    sta mw+1
    lda #3
    sta mh
    lda #$80|20             ; the pattern: 21 bytes repeated
    sta mbc+19
    lda #$FF
    jsr mblit
    lda #0
    sta mbc+19
    lda #<320               ; the destination step back to the picture's
    sta mbc+9
    lda #>320
    sta mbc+10
    rts
; a glyph's BCB: the source (0-1, 3 a glyph's), its bank 7, rows w apart, a byte
; on; the destination (6-7 a glyph's) in bank 3, rows 320 apart, a byte on; the
; width (12 a glyph's), MF_H rows; AND $FF, XOR 0; mode 1 and the next flag
mtpl dta 0, 0, 7, 0, 0, 1, 0, 0, 3, <320, >320, 1, 0, 0, MF_H-1, $FF, 0, 0, 0, 0, 1|8
.endp
mva = mbc+6
mbc     :21 dta 0           ; the BCB (17-19: collision, zoom, pattern 0; 20 the mode)
mx      dta 0, 0
my      dta 0
mw      dta 0, 0
mh      dta 0
mwh     dta 0               ; the window's height (the gradient's)
mgh     dta 0               ; the height the gradient column at V:$070800 was built for
mlon    dta 0               ; 1: a blit list open (mlbeg .. mlend: mblit appends)
mlq     dta 0               ;   its BCBs so far
mlbf    dta 0               ;   the text buffer next: 0 / 1 (mlbl)
mlcur   dta 0               ;   the open list's buffer (mlbeg's X)
msd     dta 0               ; msave: 0 save, 1 back
mcolr   dta 0
mt      dta 0
mi      dta 0
mi2     dta 0
mi3     dta 0
mst0    dta 1, 3, 2         ; the mode bar's field -> the state
mgm     dta 3, 1            ; the states 2, 3 -> gmode

; --- the ESC menu [2026-10-27, after doom-rapidus-vbxe menu.asm mn_ingame / mn_run]: run
; from here by hud.asm esc_menu, this block swapped in over ROT_LUT.  A window as the
; title's (the gradient, the gold frame, this font) over the stopped table: CONTINUE /
; QUIT TO MENU, the chosen one white on its strip.  Its colours are palette 2's (the
; title's, still loaded): the attribute map gives the window's 8 x 8 cells palette 2,
; the rest of its lines palette 1 -- a pause XDL in ESC_MAP's bank, the game's own back
; at CONTINUE.  The stick up / down (or - =) chooses, fire or RETURN takes it, ESC
; continues; a control counts after all were let go (mn_run's rest).
EW_X = 88                   ; the window: 8-aligned (its cells), the table's middle
EW_W = 144
EW_Y = 100
EW_H = 56
ESC_MAP = $05A000           ; the map (7 rows x 160), the pause XDL at + $800
KEY_RET = $0C
VCOUNT  = $D40B
SKSTAT  = $D20F
COLPM0  = $D012
    ert EW_X&7 || EW_W&7 || EW_H<>7*8 || EW_X+EW_W>256

; efont: the menu font back where the glyph BCBs read it: V:ESC_FONT000 -> V:$071000
; (12 KB, 48 rows of 256; the game's clean buffer goes over it -- the table is
; repainted after; tournament.asm tour_done too)
.proc efont
    lda #0
    sta mbc
    sta mbc+3
    sta mbc+6
    sta mbc+9
    sta mbc+16              ; (mbc+19, +20: 0 -- mltpl, edraw leave them so)
    sta mw
    lda #1
    sta mbc+4
    sta mbc+10
    sta mw+1
    lda #>[ESC_FONT*$1000]
    sta mbc+1
    lda #ESC_FONT>>4
    sta mbc+2
    lda #$10
    sta mbc+7
    lda #7
    sta mbc+8
    lda #48
    sta mh
    lda #$FF
    jmp mblit
.endp


.proc esc_panel
    lda #0
    sta escs
    jsr efont
    jsr mltpl               ; the text lists' templates (bank $70 is the clean buffer's too)
    ert *<>ep               ; (falls into the panel)
.endp

.proc ep
    ldy #MA_BSEL            ; the map: a row's cells palette 1, the window's palette 2
    lda #$80|[ESC_MAP>>12]
    sta (VB),y
    ldx #160
mp: txa
    and #3
    bne z                   ; (bytes 0-2: the playfield's colours, no ANTIC)
    lda #$10
    cpx #4*[EW_X/8]+4
    bcc st
    cpx #4*[[EW_X+EW_W]/8]+1
    bcs st
    lda #$20
    bne st                  ; (always)
z:  lda #0
st: :7 sta WINDOW-1+#*160,x
    dex
    bne mp
    ldx #16                 ; the pause XDL: the game's HUD records, then the table's lines
c0: lda XDL,x               ;   split round the window's
    sta WINDOW+$800,x
    dex
    bpl c0
    ldx #exe-exdl-1
c1: lda exdl,x
    sta WINDOW+$811,x
    dex
    bpl c1
    jsr hud_end
    jsr edraw
    jsr bwait               ; drawn: the pause XDL shows it
    lda #<[ESC_MAP+$800]
    ldx #>[ESC_MAP+$800]
    ldy #^[ESC_MAP+$800]
    jsr exdla
    ldx #SND_CLICK
    jsr snd_play
    lda #[EW_X+EW_W/2]/2    ; the pointer on CONTINUE, the button as it is now
    sta mpx
    lda #[EW_Y+18]/2
    sta mpy
    lda TRIG0+1
    sta mlb
    lda #0                  ; the pointer: player 0 over the overlay (the pause XDL's
    sta earm                ;   priority $FE), white; the game's VBI copies no shadow
    tax
p0: sta P0MEM,x
    inx
    bpl p0
    sta HPOSP0+1
    sta HPOSP0+2
    sta HPOSP0+3
    lda #$18
    sta PMBASE
    lda #$0E
    sta COLPM0
    lda #2
    sta GRACTL
    lda #$08                ; player DMA only, 2 lines a byte
    sta DMACTL
lp: jsr mstep               ; (as the title's menu: polled, a frame's work on a new frame)
    lda TRIG0+1             ; the button (TRIG1): on its press, a row under the pointer
    cmp mlb
    beq fr
    sta mlb
    lsr @
    bcs fr                  ; (released)
    jsr erow
    bcs fr
    sta escs                ; (the row clicked, drawn or not yet)
    bcc sel                 ; (always: C = 0)
fr: lda $14
    cmp mlf
    beq lp
    sta mlf
    jsr ptr
    jsr erow                ; the row under the pointer chosen
    bcs ky
    cmp escs
    beq ky
    sta escs
    jsr edraw
ky: lda SKSTAT              ; a key: on its press (doom menu.asm mn_key's arm)
    and #4
    bne up
    lda earm
    beq lp
    lda #0
    sta earm
    lda KBCODE
    and #$3F
    cmp #KEY_ESC
    beq cont
    cmp #KEY_RET
    beq sel
    bne lp                  ; (always)
up: lda #1
    sta earm
    bne lp                  ; (always)
sel:
    ldx #SND_CLICK
    jsr snd_play
    lda escs
    jne esc_quit            ; (hud.asm: the title and the photos back, the menu)
cont:
    ldx #$FF                ; (the ESC typed here: not the frame loop's)
    stx CH
    lda #0                  ; the pointer off (the game's XDL: esc_menu, after the table)
    sta GRACTL
    sta GRAFP0
    sta HPOSP0
    sta DMACTL
    rts
.endp


; edraw: the window -- the gradient (a pattern copy), the frames and
; the chosen row's strip as one list, then the two rows' texts
.proc edraw
    ldx #2
    jsr mlbeg
    lda #EW_H               ; the gradient's column (V:$070900, the clean buffer's: each time)
    sta mwh
    sta mi2
g:  dec mi2
    lda mi2
    jsr mgr
    ldx mi2
    sta WINDOW+$900,x
    txa
    bne g
    lda #9
    sta mbc+1
    lda #7
    sta mbc+2
    lda #1
    sta mbc+3
    lda #0
    sta mbc+4
    sta mbc+16
    sta mbc+20
    sta mbc                 ; (its first row: the column's byte 0)
    sta mi3
    lda #$80
    sta mbc+19
    lda #EW_X               ; the whole rect (no corners cut: the table under them is
    sta mx                  ;   palette 2 there)
    lda #EW_Y
    sta my
    lda #EW_W
    sta mw
    lda #EW_H
    sta mh
    jsr mbox
    jsr mdst
    lda #$FF
    jsr mblit
    lda #0
    sta mbc+19
    ldx #12                 ; the frames (12) and the strip
f:  stx mi3
    lda efx,x
    sta mx
    lda efy,x
    sta my
    lda efw,x
    sta mw
    lda efh,x
    sta mh
    jsr mbox
    ldx mi3
    lda efc,x
    jsr mfill
    ldx mi3
    dex
    bpl f
    jsr mlend
    ldx #1                  ; the texts: the chosen one white
t:  stx mi3
    ldx mlbf
    jsr mlbeg
    ldx mi3
    lda etl,x
    sta src
    lda eth,x
    sta src+1
    ldy #0
    cpx escs
    bne t0
    iny
t0: lda ety,x
    tax
    lda #EW_X+20
    jsr mpos
    inc mx+1                ; (the game's buffer: + 256)
    jsr mtx
    jsr mlend
    ldx mi3
    dex
    bpl t
    rts
; the frames (as mwin's: gold, the dark one inside), the strip (13th: escs's row)
efx dta EW_X+2, EW_X+2, EW_X, EW_X+EW_W-1, EW_X+1, EW_X+EW_W-2, EW_X+1, EW_X+EW_W-2
    dta EW_X+3, EW_X+3, EW_X+3, EW_X+EW_W-4, EW_X+8
efy dta EW_Y, EW_Y+EW_H-1, EW_Y+2, EW_Y+2, EW_Y+1, EW_Y+1, EW_Y+EW_H-2, EW_Y+EW_H-2
    dta EW_Y+3, EW_Y+EW_H-4, EW_Y+3, EW_Y+3, 0
efw dta EW_W-4, EW_W-4, 1, 1, 1, 1, 1, 1, EW_W-6, EW_W-6, 1, 1, EW_W-16
efh dta 1, 1, EW_H-4, EW_H-4, 1, 1, 1, 1, 1, 1, EW_H-6, EW_H-6, 16
efc :8 dta MG_FRAME
    :4 dta MG_FRIN
    dta MG_SEL
ety dta EW_Y+14, EW_Y+34
etl dta <mscont, <msquit
eth dta >mscont, >msquit
.endp

; mbox: the ESC window's rect -> the game's buffer (V:$030100: x + 256); the strip's row
.proc mbox
    lda #1
    sta mx+1
    lda #0
    sta mw+1
    lda mi3                 ; (the frames' loop: 12 = the strip, at escs's row)
    cmp #12
    bne o
    ldx escs
    lda edraw.ety,x
    sec
    sbc #3
    sta my
o:  rts
.endp

; the pause XDL's table lines (after the game's 17 bytes of the HUD): above the window
; palette 1, the window's lines the map on, below it off
exdl
    dta %01100010, %00001000, EW_Y-16-1         ; GMON | RPTL | OVADR, OVATT
    dta $00, $15, $03, $40, $01                 ; V:$031500: the visible buffer's row 16, 320 a row
    dta %00010001, $FE                          ; palette 1, player 0 (the pointer) over it
    dta %00101000, %00000110, EW_H-1            ; MAP_ON | RPTL, MAP_ADR | MAP_PAR
    dta <ESC_MAP, >ESC_MAP, ^ESC_MAP, 160, 0    ; 40 cells a row
    dta 0, 0, 7, 7                              ; 8 x 8 cells
    dta %00110000, %10000000, 239-EW_Y-EW_H     ; MAP_OFF | RPTL, END
exe
escs    dta 0               ; the chosen row: 0 CONTINUE, 1 QUIT TO MENU
earm    dta 0               ; 1: no key held since the last one counted
mscont  dta d'CONTINUE', $FF
msquit  dta d'QUIT TO MENU', $FF


; os_off: the OS ROM out for good (PORTB bit 0) -- its RAM holds the game's own
; NMI / IRQ entries and code (osrom.asm); the VBI straight to vbi (no SETVBV now),
; any IRQ but the sound's on to kbirq (snd_irq stays in front of it).  Here:
; it runs once, before zoom_set fills this RAM (ROT_LUT).
.proc os_off
    sei
    lda #0
    sta NMIEN
    lda PORTB
    and #$FE
    sta PORTB
    lda VB+1                    ; the VBXE page into the polls under the ROM: only now
    sta erase_all.w0+2          ;   the writes reach that RAM (vb_init's ran with the ROM in)
    sta erase_all.w1+2
    sta erase_all.st+2
    sta draw_all.w0+2
    sta draw_all.w1+2
    sta draw_all.st+2
    sta draw_all.sw1+2
    sta draw_all.sst+2
    lda #<vbi
    sta VVBLKI
    lda #>vbi
    sta VVBLKI+1
    lda #<kbirq                 ; (VIMIRQ = snd_irq: snd_init before the menu)
    sta snd_irq.os+1
    lda #>kbirq
    sta snd_irq.os+2
    lda #$40
    sta NMIEN
    cli
    rts
.endp

mpx      dta 80              ; the pointer: colour clock - 48, row (2 lines)
mpy      dta 60
mox     dta 0               ; the last phases x 4
moy     dta 0
mpa      dta 0
mlf   dta 0
mlb   dta 1
mpr    dta 4
mside dta 0                 ; mopp: the side, its first column
mdir  dta 0                 ; the step: -1 / +1
mo    dta 0                 ; the other side's player
mcol  dta 0
mstate dta 0                ; 0 the mode bar, 1 the match bar, 2 the tricks, 3 the tournament
mmode dta 0                 ; 0 MATCH, 1 TOURNAMENT, 2 TRICK SHOTS
mbo   dta 3                 ; the match: best of 1, 3 .. 9
mk    dta 0
; the fields' ends (a column / 2), by state: the mode bar, the match bar
mft0  dta 0, 3, 9, 9        ; (the tricks, the tournament: one bar)
mend  dta 13, 27, 40
      dta 10, 13, 23, 31, 36, 40
      dta 20, 30, 40        ; the trick bar
mtrk  dta 0                 ; the trick chosen
mhalf dta 5, 0, 18, 27      ; the match bar's fields: where their right half starts
; the mode bar: each field's first column, width, its text's column, the text
m0c   dta 0, 26, 54
m0w   dta 26, 28, 26
m0t   dta 10, 35, 61
m0sl  dta <mmatch, <mtour, <mtrick
m0sh  dta >mmatch, >mtour, >mtrick
qd                          ; old * 4 + new -> the step (PORTA: the phases inverted, 3 1 0 2 forward)
    dta 0, $FF, 1, 0
    dta 1, 0, 0, $FF
    dta $FF, 0, 0, 1
    dta 0, 1, $FF, 0
arrow
    dta %10000000, %11000000, %11100000, %11110000, %11111000, %11100000, %10110000, %00011000
mvs     dta d'VS', $FF
mplay   dta d'PLAY', $FF
mback   dta d'BACK', $FF
mbtx    dta d'BEST OF', $FF
mmatch  dta d'MATCH', $FF
mtour   dta d'TOURNAMENT', $FF
mtrick  dta d'TRICK SHOTS', $FF
mstart  dta d'START', $FF
    ert *>WINDOW
