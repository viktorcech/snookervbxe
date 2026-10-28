; tournament.asm -- the menu's TOURNAMENT (gmode 1): the draw of 8 (tdraw), the
; matches, and the draw's window with every result.  [2026-10-27: was modes.asm --
; the draw showed the 8 names only: who went through, who went out and by what score
; the player never saw]
;   The rounds: the last 8 best of 3, the semi best of 5, the final best of 7.  P1
;   plays his; the others are decided by the players' strength and RANDOM (tbeat2),
;   their scores drawn (the loser 0 .. the length - 1).  After each of P1's matches the
;   round's other matches are played out (all the rest when P1 is out) and the title
;   comes back with the draw (tour_done -> hud.asm esc_quit): each round a column, the
;   name and the frames it won, the winner white, the loser dim, the champion under
;   them; the bar: NEXT: P1 VS .. / CHAMPION! / KNOCKED OUT.
;   The window is menu.asm's (TB_*: its picture saved, its gradient, its frame); the
;   text in the small font (tools/menu_gfx.py: V:$05E000, menugfx2.inc), a glyph a
;   blit (mtx2).  Cold code.
; [2026-10-26 6502-idioms/SKILL.md: code size is RAM -- tables for the round's length
;  and the odds, fall-throughs guarded with ert]

; (the small font's tables, menugfx2.inc: main.asm puts them behind rdisc -- this block
;  is full)
TBAR = $0400                ; (24) tour_bar's NEXT: P1 VS .. (the cassette buffer: the
                            ;   game's cells there are set anew by the next game)

; tour_start: the menu's START -- a tournament over (P1 out, or the champion): a new
; one; else the match P1 is on, its length
.proc tour_start
    lda tover
    jne tour_reset
    lda tnext               ; (opp is pty+1: the menu's window set it to 0)
    jmp tour_set
.endp

; tour_reset: a new tournament -- nothing played, P1 against the draw's slot 1
; (the menu's start: a tournament left through the mode bar is gone)
.proc tour_reset
    lda #$FF
    ldx #6
c:  sta tw,x
    dex
    bpl c
    lda #0
    sta tround
    sta tover
    lda tdraw+1
    ert *<>tour_set
.endp

; tour_set: A = the opponent -> the match: opp, its length (the round's)
.proc tour_set
    sta opp
    sta tnext
    ldx tround
    lda tbw,x
    sta bestw
    lda tbo,x
    sta msbo+1
    rts
.endp
tbw dta 2, 3, 4             ; frames to win: the last 8, the semi, the final
tbo dta CH_0+3, CH_0+5, CH_0+7

; tour_done: frame_next, P1's match over -- its result, the round's other matches,
; all the rest when P1 is out; the next opponent; then the title with the draw
; (the menu's block in, its font back, esc_quit: the picture and the photos off the
; disk, menu_back: the tournament's window)
.proc tour_done
    ldx tround
    lda tp1,x               ; P1's match in this round
    sta tm
    asl @
    tay
    lda fw                  ; his frames, the opponent's
    sta tf,y
    lda fw+1
    sta tf+1,y
    lda fw                  ; won: P1 (0) goes through, else the opponent
    cmp bestw
    lda #0
    bcs w
    lda opp
w:  ldx tm
    sta tw,x
    ldx tround
    jsr tsimr               ; the round's other matches
    ldx tm
    lda tw,x
    bne out
    ldx tround
    cpx #2
    bcs fin                 ; the final won: the champion
    inx
    stx tround
    ldy topp-1,x            ; the next opponent: the winner beside P1's
    lda tw,y
    jsr tour_set
    jmp show
out:
    ldx tround              ; P1 out: every round to the end
o1: inx
    cpx #3
    bcs fin
    stx tr2
    jsr tsimr
    ldx tr2
    bne o1                  ; (always: X >= 1)
fin:
    lda #1
    sta tover
show:
    jsr eswap               ; the menu's block in (esc_quit runs the menu from it)
    jsr efont               ; the title's font back (the game's clean buffer had it)
    jmp esc_quit
tp1  dta 0, 4, 6            ; P1's match in the round
topp dta 1, 5               ; the winner P1 meets next (tw: round 1, the final)
.endp

; tsimr: X = a round -> its matches not played yet played out (tbeat2), a score each
.proc tsimr
    lda trm0,x
    sta tm2
    lda trm1,x
    sta tme
    lda tbw,x
    sta tlen
l:  ldx tm2
    lda tw,x
    cmp #$FF
    bne n
    jsr tplay               ; its two players
    jsr tbeat2              ; -> A the winner (ta, tb: the two)
    ldx tm2
    sta tw,x
    eor ta                  ; the winner's side: 0 the first, 1 the second
    beq f
    lda #1
f:  sta tt
    txa                     ; his cell: 2 match + side -- the length
    asl @
    ora tt
    tax
    lda tlen
    sta tf,x
    txa                     ; the loser's: 0 .. the length - 1
    eor #1
    tax
r:  lda RANDOM
    and #3
    cmp tlen
    bcs r
    sta tf,x
n:  inc tm2
    lda tm2
    cmp tme
    bcc l
    rts
trm0 dta 0, 4, 6            ; a round's first match, the one past its last
trm1 dta 4, 6, 7
.endp

; tplay: X = a match -> A, Y its two players (the draw's pair, or the winners of the
; two matches before it)
.proc tplay
    cpx #4
    bcs w
    txa
    asl @
    tax
    lda tdraw,x
    ldy tdraw+1,x
    rts
w:  txa
    sec
    sbc #4
    asl @
    tax
    lda tw,x
    ldy tw+1,x
    rts
.endp

; tbeat2: A, Y = two players -> A = the winner: the stronger by the odds of tbp
.proc tbeat2
    sta ta
    sty tb
    lda tstr,y
    sta tt
    ldx ta
    lda tstr,x
    sec
    sbc tt                  ; their strengths' difference, -5..5
    clc
    adc #5
    tax
    lda RANDOM
    cmp tbp,x               ; RANDOM < its odds: the first
    lda ta
    bcc w
    lda tb
w:  rts
tbp dta 28, 48, 68, 88, 108, 128, 148, 168, 188, 208, 228
.endp

; tour_bar: the tournament bar's text -> A:X (menu.asm mbarx): NEXT: P1 VS the
; opponent, CHAMPION! or KNOCKED OUT
.proc tour_bar
    lda tover
    beq nx
    lda tw+6                ; over: P1 the champion (0) or out
    bne o
    lda #<mschamp
    ldx #>mschamp
    rts
o:  lda #<msout
    ldx #>msout
    rts
nx: ldx #0                  ; NEXT: P1 VS, then the name
c1: lda tnx,x
    bmi n1
    sta TBAR,x
    inx
    bne c1                  ; (always)
n1: ldy tnext
    lda ai_nl,y
    sta src
    lda ai_nh,y
    sta src+1
    ldy #0
c2: lda (src),y
    sta TBAR,x
    inx
    iny
    cmp #$FF
    bne c2
    lda #<TBAR
    ldx #>TBAR
    rts
.endp

; tour_end: hud_draw's frame end in the tournament -- the match over: through,
; the champion or out (centred in the blue field), else END
.proc tour_end
    lda fw+1
    cmp bestw
    bcs out
    lda fw
    cmp bestw
    bcs won
    ldx #38
    lda #<msend
    ldy #>msend
    jmp hud_draw.ttip
won:
    ldy tround
    lda tml,y
    ldx tmh,y
    bne t                   ; (always: the strings are not in page 0)
out:
    lda #<msout
    ldx #>msout
t:  sta src
    stx src+1
    lda #27
    ldy #26
    jsr tk_ctr
    jmp tip_draw
tml dta <mssemi, <msfin, <mschamp
tmh dta >mssemi, >msfin, >mschamp
.endp

; --- the draw's window (menu.asm mopen, the tournament's state 3: the window drawn,
; its picture saved) ---------------------------------------------------------------
; tdrawb: the headers, each round's column (name, frames, the lines to the next round),
; the champion under them.  A column's entries: the last 8 the draw's 8, then the
; winners of the matches before; entry e of column c at row TB_Y + 20 + tyo + e * tst
TC_X  = 4                   ; the columns' x in the window: 4, 83, 162 (a name 64 px at most:
TC_W  = 79                  ;   O'SULLIVAN), the frames at + 66, the lines from + 72
.proc tdrawb
    ldx #2                  ; the headers, gold
h:  stx ti
    lda thx,x
    jsr twx
    lda #TB_Y+6
    sta my
    lda #0
    sta mcolr
    lda thl,x
    sta src
    lda thh,x
    sta src+1
    jsr mtx2
    ldx ti
    dex
    bpl h
    lda #0
    sta tc
col:
    lda #0
    sta te
ent:
    ldx tc                  ; this entry's player: the draw's, or a winner before
    bne c1
    ldy te
    lda tdraw,y
    jmp got
c1: lda tcb,x
    clc
    adc te
    tay
    lda tw,y
got:
    sta tp
    lda tyo,x               ; its row
    ldy te
    beq y1
y0: clc
    adc tst,x
    dey
    bne y0
y1: clc
    adc #TB_Y+20
    sta tyr
    lda te                  ; its match, and its frames' cell: 2 match + (e & 1)
    lsr @
    clc
    adc tmb,x
    sta tm
    asl @
    sta tfi
    lda te
    and #1
    ora tfi
    sta tfi
    lda tp
    cmp #$FF
    beq ln                  ; not known yet: the lines alone
    ldy tm                  ; the colour: played -- the winner white, the loser dim;
    lda tw,y                ;   to come -- white
    ldx #1
    cmp #$FF
    beq cw
    cmp tp
    beq cw
    inx
cw: stx mcolr
    ldx tc
    lda tcx,x
    jsr twx
    lda tyr
    sta my
    lda tp
    jsr tname
    jsr mtx2
    ldy tm                  ; its frames, when played
    lda tw,y
    cmp #$FF
    beq ln
    ldx tfi
    lda tf,x
    ora #CH_0
    sta tsc
    lda #<tsc
    sta src
    lda #>tsc
    sta src+1
    ldx tc
    lda tcx,x
    clc
    adc #66
    jsr twx
    lda tyr
    sta my
    jsr mtx2
ln: lda te                  ; the pair's lines at its second entry
    lsr @
    bcs pr
    lda tyr
    sta tyr0                 ; (the first's row)
    jmp nx
pr: lda tc                  ; (the final: no lines -- the champion is under the draw)
    cmp #2
    bcs nx
    jsr tlines
nx: inc te
    ldx tc
    lda te
    cmp tcn,x
    jcc ent
    inc tc
    lda tc
    cmp #3
    jcc col
    lda tw+6                ; the champion, under the draw
    cmp #$FF
    beq o
    pha
    lda #0                  ; CHAMPION: (gold), the name (white)
    sta mcolr
    lda #TC_X
    jsr twx
    lda #TB_Y+TB_H-17
    sta my
    lda #<msch2
    sta src
    lda #>msch2
    sta src+1
    jsr mtx2
    inc mcolr
    lda #TC_X+62
    jsr twx
    pla
    jsr tname
    jmp mtx2
o:  rts
; the columns: x, entries, the first winner (tw), the first match, row offset, step
tcx dta TC_X, TC_X+TC_W, TC_X+2*TC_W
tcn dta 8, 4, 2
tcb dta 0, 0, 4
tmb dta 0, 4, 6
tyo dta 0, 7, 21
tst dta 14, 28, 56
thx dta TC_X, TC_X+TC_W, TC_X+2*TC_W
thl dta <tsh0, <tsh1, <tsh2
thh dta >tsh0, >tsh1, >tsh2
.endp

; tlines: a pair's lines (tyr0 the first's row, tyr the second's, column tc 0 / 1): from
; each to the join, the join, and on to the next column
.proc tlines
    lda #0                  ; (every rect here under 256 wide)
    sta mw+1
    ldx tc
    lda tdrawb.tcx,x
    clc
    adc #72
    sta tlx                 ; the stubs' x (window units)
    ldy tyr0
    jsr stub
    ldy tyr
    jsr stub
    lda tlx                 ; the join: from the first's row to the second's
    clc
    adc #3
    jsr twx
    lda tyr0
    clc
    adc #3
    sta my
    lda tyr
    sec
    sbc tyr0
    clc
    adc #1
    sta mh
    lda #1
    sta mw
    lda #MG_LINE
    jsr mfill
    lda tlx                 ; on: 3 px, 2 short of the next column
    clc
    adc #3
    jsr twx
    lda tyr0
    clc
    adc tyr
    ror @
    clc
    adc #3
    sta my
    lda #3
    sta mw
    lda #1
    sta mh
    lda #MG_LINE
    jmp mfill
stub:                       ; Y = a row: 3 px into the join, at the row's middle
    lda tlx
    jsr twx
    tya
    clc
    adc #3
    sta my
    lda #3
    sta mw
    lda #1
    sta mh
    lda #MG_LINE
    jmp mfill
.endp

; twx: A = an x in the window -> mx = TB_X + A (16 bits: the window reaches past 255)
.proc twx
    clc
    adc #TB_X
    sta mx
    lda #0
    adc #0
    sta mx+1
    rts
.endp

; tname: A = a player -> src = his name (0: P1)
.proc tname
    tay
    bne c
    lda #<msp1
    sta src
    lda #>msp1
    sta src+1
    rts
c:  lda ai_nl,y
    sta src
    lda ai_nh,y
    sta src+1
    rts
.endp

; mtx2: src = a text ($FF ends it) -> drawn at mx, my in the small font, mcolr 0 gold,
; 1 white, 2 dim: a glyph a blit (mode 1: its 0s transparent), waited for (as menu.asm
; mtx's own path without a list)
.proc mtx2
    lda #0
    sta mi
    jsr mdst                ; mva = the line's start: the glyphs step it on
c:  ldy mi
    lda (src),y
    bmi e
    tax
    lda mf2_w,x
    beq a                   ; (a space: no glyph)
    sta mw
    sta mbc+3               ; (its rows: w apart)
    lda #0
    sta mw+1
    sta mbc+4
    sta mbc+16
    lda #MF2_H
    sta mh
    ldy mcolr
    lda mf2_ol,x            ; the glyph: V:$05E000 + its offset, + its colour's plane
    clc
    adc tpl,y
    sta mbc
    lda mf2_oh,x
    adc tph,y
    sta mbc+1
    lda #^$05E000
    sta mbc+2
    lda #1                  ; mode 1, AND $FF, XOR 0
    sta mbc+20
    lda #$FF
    jsr mblit
    lda #0
    sta mbc+20
a:  ldy mi
    lda (src),y
    tax
    lda mf2_a,x             ; on by its advance
    clc
    adc mva
    sta mva
    bcc n
    inc mva+1
n:  inc mi
    bne c                   ; (always)
e:  rts
tpl dta 0, <MF2_C1, <MF2_C2
tph dta 0, >MF2_C1, >MF2_C2
.endp

mssemi  dta d'THROUGH TO THE SEMI-FINAL', $FF
msfin   dta d'THROUGH TO THE FINAL', $FF
mschamp dta d'CHAMPION!', $FF
msout   dta d'KNOCKED OUT', $FF
msch2   dta d'CHAMPION:', $FF
tsh0    dta d'LAST 8 (3)', $FF
tsh1    dta d'SEMI (5)', $FF
tsh2    dta d'FINAL (7)', $FF
tnx     dta d'NEXT: P1 VS ', $FF
; the draw (the menu's): P1, the qualifier (6), Selby, Robertson, Higgins, the
; qualifier, Trump, O'Sullivan; their strengths (the qualifier the weakest)
tdraw   dta 0, 6, 1, 3, 2, 6, 4, 5
tstr    dta 3, 1, 2, 3, 4, 5, 0
tw      :7 dta $FF          ; each match's winner ($FF: not played): the last 8 0-3,
                            ;   the semis 4-5, the final 6
tf      :14 dta 0           ; its frames: the first player's, the second's
tround  dta 0               ; 0 the last 8, 1 the semi, 2 the final
tover   dta 0               ; 1: the tournament over (P1 out, or the champion)
tsc     dta 0, $FF          ; a score, a glyph
tnext   dta 0               ; the opponent P1 meets next
; [2026-10-27 6502-idioms/SKILL.md: code size is RAM -- no RAM cell for a value that only
;  waits: the scratch in the zero page, the game's multiply / divide cells (mA .. mQ,
;  $EE-$FD): nothing of the game runs while the menu draws or a match has ended]
ta      = $EE               ; tbeat2: the two players, a strength
tb      = $EF
tt      = $F0
tm      = $F1               ; a match
tm2     = $F2               ; tsimr: the match, the one past the round's last, the length
tme     = $F3
tlen    = $F4
tr2     = $F5               ; tour_done: a round
ti      = $F6               ; tdrawb: a header, the column, the entry, its player, its row,
tc      = $F7               ;   the pair's first row, its frames' cell, the lines' x
te      = $F8
tp      = $F9
tyr     = $FA
tyr0    = $FB
tfi     = $FC
tlx     = $FD
