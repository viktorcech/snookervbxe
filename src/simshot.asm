; simshot.asm -- the computer tries a shot in the game's own physics before it
; plays it (as Franky100-pig/Billiards-solo's bot: the geometry picks the few
; best, the physics shows where the balls really stop).  The table is saved to
; VRAM (V:SIM_BANK000: $1000-$1FFF, the balls and the rules; +$1000: pages 4-7)
; and put back after; the shot runs in tick_all alone -- no rules, no sound, no
; drawing.  In RAM: it maps banks under the AI's window and maps that back last.
; [2026-10-22 6502-idioms/SKILL.md: code size is RAM -- one copy loop for both
;  ways and both blocks, the AI's cells for its inputs]

SIM_BANK = $4C              ; V:$04C000 (+ $04D000), free (the simulator's survey)
SIM_TICKS = 4000            ; 20 s of play at most

; sim_shot: stgt (the aim, 1/64 units), stpw (the power), sspin, sside (the tip:
; the shot runs until every ball stops; sevon: ppev judges that table first;
; fire_cue's spin, side), sat (the ball looked at) -> scx, scy (the cue ball's end, Q4; scon 0: potted), sfc (the first ball
; it touched, $FF none), sox, soy, soon (the ball looked at).  Back to the AI's
; window (it is called from there).
.proc sim_shot
; [2026-10-22 6502-idioms/SKILL.md: code size is RAM -- delete what nothing needs: the aim
;  cells (aimang, dirx, diry: zero page; aimfrac: page 4) come back with scopy's copy]
    clc                     ; save: RAM -> VRAM
    jsr scopy
    lda stgt                ; aimang = tgt >> 6 (10 bits), aimfrac = tgt << 2
    asl @
    asl @
    sta aimfrac
    lda stgt
    sta sw
    lda stgt+1
    ldx #6
sh:
    lsr @
    ror sw
    dex
    bne sh
    sta aimang+1
    lda sw
    sta aimang
    jsr aim_update.dir      ; dirx, diry
    lda stpw
    sta pwr
    lda stpw+1
    sta pwr+1
    lda stpw+2
    sta pwr+2
    lda sspin               ; the tip
    sta spin
    lda sside
    sta side
    lda #$FF
    sta fcon
    lda #$80
    sta simon
    jsr fire_cue.v
    lda #<SIM_TICKS
    sta sw
    lda #>SIM_TICKS
    sta sw+1
tk:
    jsr tick_all
    lda sevon               ; a pot tried for position: lost as soon as the cue ball
    beq nm                  ;   goes down or the ball looked at stops on the table
    lda BON
    beq st
    lda fcon                ;   (after the cue ball hit something: before it the ball
    bmi nm                  ;   looked at rests)
    ldx sat
    lda BON,x
    beq nm
    lda AWK,x
    beq st
nm:
    lda squick              ; a safety scanned (sfscan): the cue ball and the ball
    beq na                  ;   looked at both still is enough
    ldx sat
    lda AWK
    ora AWK,x
    beq st
na:
    lda awkn                ; a ball awake after its own tick: still moving (collide only
    bne mv                  ;   wakes; renorm's stop costs at most one idle tick, tick16
    jsr any_moving          ;   put back by scopy) -- else every ball still: done
    beq st
mv:
    lda sw
    bne t1
    dec sw+1
    bmi st
t1:
    dec sw
    jmp tk
st:
    lda #0
    sta simon
    lda X1                  ; the outcome
    sta scx
    lda X2
    sta scx+1
    lda Y1
    sta scy
    lda Y2
    sta scy+1
    lda BON
    sta scon
    lda fcon
    sta sfc
    ldx sat
    lda X1,x
    sta sox
    lda X2,x
    sta sox+1
    lda Y1,x
    sta soy
    lda Y2,x
    sta soy+1
    lda BON,x
    sta soon
    jsr win_ai              ; the AI's eye on the table as it stopped: a pot's leave
    lda sevon               ;   (ppev), a safety's balls disturbed (smoved, aipos.asm)
    beq sf
    jsr ppev
    jmp rs
sf:
    jsr smoved
rs:
    sec                     ; the table back: VRAM -> RAM
    jsr scopy
    jmp win_ai
.endp

; scopy: C = 0 save, 1 restore -- only the RAM pages a sim writes (the physics'
; balls $10-$13, $17, the rules' $1F at V:SIM_BANK000 + their offset; $04, $06,
; $07 and the zero page $80-$FF at V:(SIM_BANK+1)000); the renderer's pages ($05,
; $14-$16, $18-$1E) nothing in a sim writes (fire_cue.v: no rules, no drawing).
; Through a 4 KB window at $2000; leaves the BCB window.
; [2026-10-22 6502-loops-tables-smc/SKILL.md: patched absolute operands instead of
;  (zp),y, 2 bytes a pass; fable-skill-atari/SKILL.md: do only the work a reader needs]
.proc scopy
    ror sdir                ; (bit 7: the way)
    ldy #MA_CTL
    lda #$28
    sta (VB),y
    iny                     ; (MA_BSEL = MA_CTL + 1)
    lda #$80|[SIM_BANK+1]
    sta (VB),y
    ldx #$7F                ; the zero page $80-$FF at +$400 (the renderer keeps its
    bit sdir                ;   own there between frames; this loop's cells are none)
    bmi zl                  ; [2026-10-28 6502-cycles-layout/SKILL.md: the way is a mode,
zs:                         ;  not a rare case -- tested once, a loop each way]
    lda $80,x
    sta $2400,x
    dex
    bpl zs
    bmi zn                  ; (always)
zl:
    lda $2400,x
    sta $80,x
    dex
    bpl zl
zn:
    ldx #SP_N-1             ; the pages, (SIM_BANK+1)'s first
pl:
    cpx #SP_B-1             ; SIM_BANK's from here
    bne pg
    ldy #MA_BSEL
    lda #$80|SIM_BANK
    sta (VB),y
pg:
    lda sp_r,x              ; RAM page, window page: patched in as source / target
    ldy sp_w,x
    bit sdir
    bmi ld
    sta s0+2
    sta s1+2
    sty d0+2
    sty d1+2
    bpl cp                  ; (always: N from bit sdir)
ld:
    sty s0+2
    sty s1+2
    sta d0+2
    sta d1+2
cp:
    ldy #0
c:
s0  lda $FF00,y
d0  sta $FF00,y
    iny
s1  lda $FF00,y
d1  sta $FF00,y
    iny
    bne c
    dex
    bpl pl
    jmp win_bcb
.endp
sp_r    dta $10, $11, $12, $13, $17, $1F, $04, $06, $07   ; the RAM pages a sim writes
sp_w    dta $20, $21, $22, $23, $27, $2F, $20, $22, $23   ;   and their place in the window
SP_N    = 9
SP_B    = 6                 ; (the first SP_B: V:SIM_BANK000, the rest V:(SIM_BANK+1)000)
    ert SIM_BANK&1<>0       ; (blk tells the blocks by the bank's bit 0)

; its cells (the AI writes stgt, stpw, sat; reads the rest)
stgt    dta 0, 0
stpw    dta 0, 0, 0
sat     dta 0
sspin   dta 4
sside   dta 4
scx     dta 0, 0
scy     dta 0, 0
scon    dta 0
sfc     dta 0
sox     dta 0, 0
soy     dta 0, 0
soon    dta 0
sw      dta 0, 0
sdir    = $03F5             ; (1) scopy's way (page 3, set before read)
sevon   = $03F4             ; (1) <> 0: ppev at the end (posplay; ai_plan clears it)

; occw: gstore -> cushion.asm's occl (a ball behind a cushion), its bank mapped over
; ROT_LUT (the ball projection reads ROT_BLUT, not it) and the BCB window back
occw:
    jsr win_cu
    jsr occl
    jmp win_bcb

; the cells both AI banks use (RAM, after nxe in the OS's page 3: either bank may be
; in the window; never loaded -- set before read)
bt      = $03F0             ; (1) the ball played
nxbi    = $03F1             ; (1) nx_eval's easiest: its nxe offset
sev     = $03F2             ; (2) ppev's number for a variant's end (pscore, aipos.asm)
squick  = $061C             ; (1) <> 0: sim_shot stops when the cue ball and sat stop (page 5;
                            ;   ai_plan clears it)
pbn     = $03F6             ; (1) the balls on before the shot (but the cue and bt): posplay
pcnt    = $03F7             ; (1) pmov's count of them
    ert $0300+40*6>bt       ; (nxe, NX_MAX 40, ends below)
