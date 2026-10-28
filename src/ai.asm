; ai.asm -- the computer player's stub in RAM: on its turn the VRAM bank AI_BANK
; pair is mapped as an 8 KB MEMAC-A window at $2000 and ai_run (aiv.asm,
; executed there) plays.
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- the 2.6 KB AI runs from VRAM
;  (VBXE 1.27 manual ch. 6: a CPU access through MEMAC costs what RAM does); only this
;  stub and its 2 cells stay in RAM]

; ai_input: aim_update at rest, before the stick and the trigger are read
.proc ai_input
    ldx turn                ; the player at the table: a computer (its profile -> aip)?
    lda pty,x
    sta aip
    bne cpu
hum:
    lda #0
    sta aiact
    sta aist
    rts
cpu:
    lda moving              ; the balls stopped during this frame's ticks: the rules
    bne out                 ;   (rules_end) judge them next frame -- plan after that
    lda #1                  ; the VBI leaves STICK0 / STRIG0 to ai_run
    sta aiact
    lda aist                ; it plans this frame (seconds): THINKING in its name's place --
    bne pl                  ;   the shot, or in hand its place in the D (hand_ai's first
    lda inhand              ;   frame), not the frame it releases fire
    and hwait
    bne pl
    jsr erase_all           ; the balls up first, at NEWS (main projects before aim_update):
    jsr draw_all            ;   the old places off (in_hand moved the cue; after cam_rest's
    jsr think_on            ;   new table nothing is shown)
pl:
    jsr win_ai
    jsr ai_run
    jsr win_bcb
    lda thk                 ; planned: the name back, the tip it chose shown (hud_draw);
    cmp #1                  ;   $80 (a trick's DEMO) kept
    bne out
    dec thk
    jmp hud_draw            ; (it shows the tip it chose)
out:
    rts
.endp

; win_ai: MEMAC-A 16 KB at $2000-$5FFF (over ROT_LUT and the RAM below $6000, which
; nothing the AI calls lives in): banks AI_BANK .. +3 -- its code (2), cushion.asm,
; ai2.asm; win_bcb: back to 4 KB at $3000, bank 0
; (the BCBs).  Keep X.
.proc win_ai
    lda snd_irq.ack0+1      ; the sound's timer off: its IRQ reads samples and volume
    sta POKMSK              ;   tables through MEMAC-B at $4000, which this window
    sta IRQEN               ;   covers (MEMAC-A first): noise till a 0 came by
    ldy #MA_CTL
    lda #$2A                ; 16 KB at $2000
    sta (VB),y
    ldy #MA_BSEL
    lda #$80|AI_BANK
    sta (VB),y
    rts
.endp
; win_cu: MEMAC-A 4 KB at $2000, the cushion model's bank (reflx / refly).  Keeps X.
.proc win_cu
    ldy #MA_CTL
    lda #$28
    sta (VB),y
    ldy #MA_BSEL
    lda #$80|CU_BANK
    sta (VB),y
    rts
.endp
.proc win_bcb
    ldy #MA_CTL
    lda #$38
    sta (VB),y
    ldy #MA_BSEL
    lda #$80
    sta (VB),y
    rts
.endp

; the opponents' names (hud.asm, menu.asm): opp 0 = P2, 1..5 the computer
; players, weakest first; their lengths
ai_nl   dta <msp2, <nm1, <nm2, <nm3, <nm4, <nm5, <nm6
ai_nh   dta >msp2, >nm1, >nm2, >nm3, >nm4, >nm5, >nm6
ai_nn   dta 2, nm2-nm1-1, nm3-nm2-1, nm4-nm3-1, nm5-nm4-1, nm6-nm5-1, nme-nm6-1
nm1     dta d'SELBY', $FF
nm2     dta d'HIGGINS', $FF
nm3     dta d'ROBERTSON', $FF
nm4     dta d'TRUMP', $FF
nm5     dta d"O'SULLIVAN", $FF
nm6     dta d'QUALIFIER', $FF   ; (the tournament's: profile 6)
nme
