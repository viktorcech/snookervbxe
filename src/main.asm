; ai-snooker -- THE GAME (single evolving binary -> build/snooker.xex)
; Coding of the game began on 2026-05-26.
; 2.5D table + full static rack (21 object balls) + the cue ball moving under
; real fixed-point physics (Q12), flicker-free via double buffering.
;
;   clean  buffer V:$013000 = table + static rack (built once at init)
;   visible buffer V:$030000 = what the XDL shows; the cue ball is blitted here
;   each frame: run physics (heavy) FIRST so the ball stays drawn, then at VBL
;   erase-old + draw-new back-to-back (two fast blits) -> no blink.
;
; Build: mads.exe src/main.asm -o:build/snooker.xex   (Altirra + VBXE)
; Physics = FixedEngine (ratio friction) from sim/snooker_core.py, validated.
; (cushions / ball-ball collisions / joystick / rules still to come, in place.)
;
; Modules (icl'd below): defs.inc objects.asm input.asm aimline.asm
;   physics.asm math.asm render.asm vbxe.asm -- main.asm keeps the
;   init sequence, the frame loop, and the data/tables tail.
;
; Speed work, round 1 (math/render/aimline; the slower originals deleted):
; quarter-square mul_slope, mul48 fast path, ZP math scratch,
; div16r/div9, direct BCB writes, aim-line replay erase, projection cache.
; Round 2 (48Balls-style): the ball state is struct-of-arrays (defs.inc, every
; field `ARR,x`), friction is a per-ball deceleration VECTOR subtracted each
; tick (no per-tick multiply; a is rebuilt by renorm on every velocity change),
; collisions sweep the balls sorted by x, only moved balls are reprojected.
; Spec + gate: tools/phys_ref.py (byte-exact model) and tools/phys_check.py;
; cycle reports: tools/out/bench/bench_fps*.txt; divergence from the previous Q12
; engine (src/old_q12/): asm_bench.py --compare-pos (0.08 mm soft, 1.85 mm
; medium; the hard break is chaotic in every engine).

    icl 'defs.inc'
    icl 'atr.inc'

    org $4000

; the multiply / row tables load above $A000: BASIC off (XL/XE PORTB bit 1)
; is the first thing the loader runs, before any segment lands there;
; BASICF keeps it off across RESET.
; [2026-10-21 VBXE 1.27 manual ch. 6 + history 1.08: $FF to PORTB before any MEMAC-B use --
;  a RAM expansion's bank (bits 4, 5) would win over the VRAM at $4000-$7FFF (sound.asm);
;  $FF also keeps the OS ROM on (bit 0), BASIC (1) and the self-test (7) off]
basic_off:
    lda #$FF
    sta PORTB
    lda #1
    sta BASICF
    rts
    ini basic_off

start:
    cld                         ; [2026-10-12 6502-nmos-atari/SKILL.md: D is not cleared on reset -- cld at start-up]
    jsr detect_vbxe
    lda VB+1
    bne ok
    jmp halt
ok:
    jsr load_palette            ; palette 1: the menu bar's colours (the HUD's)
    jsr vb_init                 ; the VBXE page into the blitter polls, the BCB templates (once)
    jsr snd_init                ; the sounds (the menu's click too)
    jsr menu                    ; the title's menu (menu.asm): the opponent -> opp
    jsr os_off                  ; the OS ROM out for good: its RAM is the game's (osrom.asm)
newgame:                        ; (hud.asm esc_quit: QUIT TO MENU's menu, then here again)
; [2026-10-21 VBXE 1.27 manual ch. 5: FEATURE_CONTROL to a known state -- a previous program's
;  PXGF keeps its CLIP / XCOLOR / GTIA_PALETTE through RESET; written after VIDEO_CONTROL
;  (whose write clears XCOLOR[0])]
    ldy #VIDEO_CONTROL
    lda #0
    sta (VB),y
    ldy #FEATURE_CONTROL
    sta (VB),y
    ldy #MA_CTL
    lda #$38
    sta (VB),y
    ldy #MA_BSEL
    lda #$80
    sta (VB),y
    ldx #0
cpxdl:
    lda XDL,x
    sta WINDOW,x
    inx
    cpx #XDL_LEN
    bne cpxdl
    lda #0
    ldy #XDL_ADR0
    sta (VB),y
    ldy #XDL_ADR1
    sta (VB),y
    ldy #XDL_ADR2
    sta (VB),y

    jsr mk_tables               ; ymlo / ymmid / ymhi, shr4 -> pages $08-$0B
    jsr setup_balls             ; init all 22 balls from init_balls (geom.inc)
    jsr rules_init
    jsr in_hand                 ; the break-off from hand (rules.asm)
    lda #0
    sta rang
    sta rang+1
    sta wasmov
    sta fidle
    sta novbl
    lda #CAM_CUE
    sta cmode
    jsr set_pivot               ; the view: about the cue, the default zoom
    lda #ZOOM_DEF
    jsr zoom_set
    jsr set_angle               ; the table at angle 0 -> clean + visible, BCB constants
    jsr hud_draw                ; the HUD (its own XDL lines)

    lda #0              ; aim angle 0 = pointing +x (into the screen)
    sta aimang
    sta aimang+1
    sta aimfrac
    lda #<ASTART
    sta aspd
    lda #>ASTART
    sta aspd+1
    lda #0              ; power: not charging yet
    sta charging
    sta pwr
    sta pwr+1
    sta pwr+2
    jsr trick_start             ; (the trick mode: its table, its aim, the view, trick.asm)

    ; initial draw of balls + seed their OLDS slots
    lda #0
    sta lshown                  ; no aim line drawn yet
    sta bdirty                  ; (the initial draw_all below draws every ball)
    sta moving                  ; all balls at rest (aim_update reads this)
    jsr project_balls
    lda #1
    sta projvalid               ; NEWS valid until the first physics tick
    jsr aim_update.noai         ; (the computer plans in the loop: the table is up by then)
    jsr draw_all                ; (also seeds OLDS)
    jsr line_calc               ; compute + draw the initial aim line
    lda aiming
    beq nl0
    jsr draw_line
nl0:

    ldy #VIDEO_CONTROL
    lda #$05
    sta (VB),y
; [2026-10-09 6502-nmos-atari/SKILL.md: ANTIC steals cycles on displayed lines -- its playfield off,
;  VBXE drives the display (as doom/bsp_main.asm)]
    lda PAL                     ; GTIA: bits 1-3 = 0 on PAL -> 50 Hz, else 60 Hz
    and #$0E
    beq hz_pal
    lda #10                     ; NTSC: 10/3 ticks a VBLANK
    sta ph_tpv+1
hz_pal:
    lda $14
    sta fd_last
    lda #0
    sta tacc
    sta SDMCTL                  ; the OS VBI copies it into DMACTL every frame
    sta DMACTL

frame:
    lda CH                      ; [2026-10-27] ESC: the menu over the stopped game (hud.asm esc_menu)
    cmp #KEY_ESC
    bne fesc
    jsr esc_menu
fesc:
    lda $14                     ; this frame's VBLANKs: the physics' real-time step
    tax
    sec
    sbc fd_last
    stx fd_last
    sta fd_dt
    jsr any_moving              ; all at rest -> skip physics entirely (the
    sta moving                  ; collide scan is a no-op when nothing moves)
    beq frest
; 200 ticks a second of REAL time: the ticks follow the VBLANKs the last frame
; took (fd_dt), in thirds of a tick (PAL 12 = 4 a VBLANK, NTSC 10 = 3 1/3).
; At most 2 VBLANKs a frame: a slower frame is slow motion, never a spiral.
    lda fd_dt
    beq ph_tk                      ; (never: every frame waits for a VBLANK)
    cmp #3
    bcc ph_dt
    lda #2
ph_dt:
    tax
ph_acc:
    clc
    lda tacc
ph_tpv adc #12                     ; (NTSC: 10, start)
    sta tacc
    dex
    bne ph_acc
ph_tk:
    lda tacc
    cmp #3
    bcc ph_tkd
    sbc #3                      ; (C = 1)
    sta tacc
    jsr tick_all
    jmp ph_tk
ph_tkd:
    jsr pcam_frame              ; a long pot: the camera by the pocket (thkblk.asm)
    lda #0
    sta projvalid               ; positions changed -> NEWS must be recomputed
frest:
    lda moving                  ; the balls came to rest: the view follows the cue
    cmp wasmov
    beq fr1
    sta wasmov
    tax                         ; (sta sets no flag: Z from the new value)
    bne fr1
    jsr rest_judge              ; the shot is over: the rules (scores, re-spots, in hand), or the trick's
; [2026-10-21 6502-idioms/SKILL.md: one ora tests both flags (no second lda / bne)]
    lda inhand                  ; the aim into the game (not at a cushion); in hand
    ora fover                   ;   the D's placing aims, at the end nothing does
    bne fr0
    jsr aim_play
fr0:
    jsr hud_draw
    jsr cam_rest                ; (the cue moved: the camera follows)
    lda cent                    ; a century: the "100" now (rules.asm) -- at the rest edge,
    beq fr1                     ;   before aim_update, where the computer plans for 20-50 s
    jsr century                 ;   (2026-10-27: it was at the frame's start, after the plan)
fr1:
    jsr shot_clock              ; a human thinking 30 s: SHOT TIME (hud.asm)
    jsr view_input              ; at rest: C the camera, SHIFT + up / down the request after a foul
    lda fover                   ; the frame is over: fire for the next one
    beq play
    lda lshown                  ; (the aim line of the rest frame, drawn before the rest
    beq fn                      ;   edge judged the shot: off -- a potted white's is bogus)
    jsr erase_line
fn: jsr frame_next
    jsr vblwait                 ; (a frame a VBL: the trigger is sampled by the VBI)
    jmp frame
play:
    jsr aim_follow              ; at rest: the view turns after the aim
    lda projvalid               ; no tick since the last projection -> NEWS is
    bne pskip                   ; still exact (only ticks move balls / pot them)
    jsr project_balls           ; NB balls -> NEWS
    lda #1
    sta projvalid
    sta bdirty                  ; projections changed -> balls must be redrawn
pskip:
    jsr aim_update              ; stick/trigger; dirx,diry (0 while balls move)
    jsr line_calc               ; aim-line endpoints + `aiming`
    ; idle-frame check: while aiming (all balls asleep) with the line already
    ; drawn at the SAME endpoints, nothing on screen changes -- skip the whole
    ; erase/draw pass (the per-pixel CPU line redraw alone is worth ~a frame).
    lda #0
    sta lsame
    lda aiming
    beq ckdone
    lda lshown
    beq ckdone
    lda nlx1
    cmp olx1
    bne ckdone
    lda nlx1+1
    cmp olx1+1
    bne ckdone
    lda nly1
    cmp oly1
    bne ckdone
    lda lpf                     ; the power share changed (charging) -> redraw
    cmp opf
    bne ckdone
    lda lob                     ; the hit ball's line: shown / gone, or moved -- it swings
    cmp dlob                    ; far more than the cue line's end on a small turn
    bne ckdone
    tax                         ; (Z: no line on either side -> nothing to compare)
    beq ob0
    lda ox1
    cmp dox1
    bne ckdone
    lda ox1+1
    cmp dox1+1
    bne ckdone
    lda oy1
    cmp doy1
    bne ckdone
ob0:
    lda #1
    sta lsame
ckdone:
    lda novbl                   ; set_angle just rewrote the screen (the copy):
    beq vw                      ; nothing to keep tear-free, draw at once
    lda #0
    sta novbl
    beq vd                      ; (always)
vw:
    jsr vblwait                 ; sync, then erase-all + draw-all together
vd:
    lda lsame                   ; nothing changed -> next frame
    beq redraw
    jmp frame
redraw:
    lda lshown                  ; erase the OLD aim line first (restore clean bg)
    beq noeraseln
    jsr erase_line
noeraseln:
    lda bdirty                  ; no projection changed (aiming): the balls
    beq nodrawb                 ; are intact -- the line erase restored them
    jsr erase_all               ; erase every object's OLD pos
    jsr draw_all                ; draw every object's NEW pos
    lda #0
    sta bdirty
nodrawb:
    lda aiming                  ; draw the NEW aim line on top (only while aiming)
    beq nodrawln
    jsr draw_line
nodrawln:
    jmp frame
halt:
    jmp halt




; $4000-$5FFF: only what the AI window's code never reads or calls -- the 16 KB
; window covers it while the computer plans (tools/check_layout.py checks it)
    icl 'aimline.asm'
    icl 'table3d.asm'
    icl 'input.asm'
    icl 'ldpal.asm'                 ; (out of the RAM under BASIC: it ran full; after input.asm since
                                    ;   2026-10-28 -- 6502-cycles-layout: project_balls' loop in one page)
    icl 'vbxe.asm'
    icl 'view.asm'
    icl 'ai.asm'
    icl 'aifast.asm'                ; the AI's hot helpers (RAM above $6000)
    icl 'rdisc_y.asm'
    icl 'mktables.asm'              ; (cold, once: out of the draw list's block, which the D filled)
    icl '../build/assets/vram_stubs.inc'   ; (empty now: vram_load.inc seeds vbank for each stream)

    icl '../build/assets/geom.inc'      ; init_balls + pockets + MIND2

    icl '../build/assets/persp.inc'     ; ball sprite sizeoff tables
    icl '../build/assets/rot.inc'       ; the rotating table: geometry + draw list
    ert ct2+3*ROT_NCU>rt0 || rpidx+ROT_NPP>ct0      ; (cull_prep's tables after rpidx, below rt0)

coslut                          ; cos 0..255 only (cosptr folds the quadrants)
    ins '../build/assets/coslut.bin',0,768
; cold code, out of the RAM under BASIC (it ran full); above the AI's 16 KB window
; ($2000-$5FFF) and below rt0 ($9200)
    icl 'trick.asm'                 ; the trick shots (the menu's TRICK SHOTS)
    icl 'pocket.asm'                ; the pockets' falls and rounded noses (tick_all's mouths)
    icl 'tournament.asm'            ; the tournament: its matches, its draw (the menu's)
    icl 'physmain.asm'              ; physics routines out of the full RAM under the OS ROM
    icl 'cuprog.asm'                ; the cushion model's programs, straight code (its bank is full)
    icl 'cuunit.asm'                ; the cushion model's unit vector (its VRAM bank is full)
    icl 'simshot.asm'               ; the AI's shots tried in the physics (RAM: it maps banks; out of the
                                    ;   draw list's block since 2026-10-27: the round pockets' tables filled it)
    icl '../build/assets/trickhelp.inc'   ; the tricks' descriptions (menu.asm mhelpd: the menu's own block is full)
; [2026-10-22 6502-cycles-layout/SKILL.md: page-align hot tables -- rot_project / kgather read
;  rpidx,x for 74 points: at $16DE it crossed from x = 34 on; now its own page, $7500]
cold_end
    ert *>rpidx                 ; (the main block's code below rpidx / ct* / rt* / ry*: $9100-$94FF)
    ert *>$9500             ; code+data must stay below the rcp table (the QS tables sit above BASIC: $A000)
; --- quarter-square multiply tables (page-aligned; generated at assembly time) ---
;   sqr1[i] = floor(i^2/4)        for i = 0..510   (i = a+b)
;   sqr2[j] = floor((j-255)^2/4)  for j = 0..510   (j = 255-a+b)
    org $A000
sqr1lo
    :511 dta <[[#]*[#]/4]
    org $A200
sqr1hi
    :511 dta >[[#]*[#]/4]
    org $A400
sqr2lo
    :511 dta <[[[#]-255]*[[#]-255]/4]
    org $A600
sqr2hi
    :511 dta >[[[#]-255]*[[#]-255]/4]

; --- OPT lookup tables ($9000: free RAM below the cartridge area) ----------
    org $A800
; [2026-10-21 6502-loops-tables-smc/SKILL.md: tables beat arithmetic -- rowhi holds $30+hi and
;  rowbank the MA_BSEL value itself, so line_dda adds no ora #$30 and reads no visel]
; [2026-10-22 6502-cycles-layout/SKILL.md: page-align hot tables -- each on its own page,
;  line_dda's lda rowhi,y / rowbank,y never cross (they did from row 16 on)]
rowlo                       ; row*320+SCR_OFF = bank*4096 + offset (12 bits): its low byte,
    :240 dta <[[#]*320+SCR_OFF]
    org $A900
rowhi                       ; $30 + its high nibble (the window page),
    :240 dta $30+[[[#]*320+SCR_OFF]/256]&15
    org $AA00
rowbank                     ; the visible buffer's MA_BSEL for the bank: $80|($30+bank)
    :240 dta $B0+[[#]*320+SCR_OFF]/4096
    org $AB00
sqlo                        ; r^2 for r = 0..255 (isqrt48's binary search)
    :256 dta <[[#]*[#]]
sqhi
    :256 dta >[[#]*[#]]

    org $AD00                   ; cold code in the RAM under BASIC (the rules: osrom.asm)
; [2026-10-12 6502-loops-tables-smc/SKILL.md: tables beat arithmetic -- x16 / >>4 for rot_project's rows;
;  2026-10-21 6502-idioms/SKILL.md: code size is RAM -- here, where the main block had no room]
x16                             ; hi << 4 (hi = 0..15): first, at a page's start
    :16 dta [#]<<4
    ert >x16<>>[x16+15]         ; (one page: rot_project's reads never cross)
    icl 'hud.asm'
    icl 'sound.asm'
    icl 'aihand.asm'                ; the computer in hand (calls into the AI's window)
    icl 'chalk.asm'                 ; chalk marks on the cloth
    ert *>$BFF0                 ; (the OS reads $BFFA-$BFFF as a cartridge at RESET)

    icl 'title.asm'                       ; the title picture first: up while the rest loads
    icl 'aiv.asm'                         ; the computer player's code -> V:$048000
    icl 'cushion.asm'                     ; the cushion impact model -> V:$00D000
    icl 'century.asm'                     ; the century's "100" -> V:$04E000
    icl 'ai2.asm'                         ; the computer player's second bank -> V:$04B000
    icl 'aipos.asm'                       ; the computer player's position play -> V:$04A000
    icl '../build/assets/tricks_v.inc'    ; the trick shots' records -> V:$0C000 (trick.asm)
    icl '../build/assets/menufont_v.inc'  ; the menu windows' font -> V:$071000 (menu.asm)
    icl '../build/assets/menufont2_v.inc' ; the small font -> V:$05E000 (tournament.asm)
    icl '../build/assets/vram_load.inc'   ; the VRAM streams, 4 KB per INI
    icl 'osrom.asm'                       ; the RAM under the OS ROM: staged, copied by INI
    icl '../build/assets/sounds.inc'      ; the sounds (tools/snd_prep.py), V:$08000 on
    icl '../build/assets/rotdata.inc'     ; RAM tables (after the loader's $2000 staging)
    org rot_tab_end                       ; the draw list's tail
    icl 'rdisc.asm'
    icl '../build/assets/menugfx2.inc'    ; the small font's tables (tournament.asm: the main
                                          ;   block is full)
    ert *>$A000
    org $9C00                   ; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- the
    icl 'copyfull.asm'          ;  pages between the LUT block and ROT_TAB hold cold code]
    icl 'thkblk.asm'
    ert *>ROT_TAB
    org $0E42                   ; free RAM after g4c (as the palette below): rfill's merged rows
    icl 'mrun.asm'
    org lbuf_lo                 ; the palette: read once by load_palette at start,
palette                         ; then the aim line's pixel buffers reuse the RAM
    ins '../build/assets/palette.bin'
    ert *<>lbuf_px                ; vb_init right after it, in the save-under buffer
    icl 'boot.asm'
    ert *>vbuf
; [2026-10-27] the menu font again -> V:ESC_FONT000 for the ESC menu (the game's clean
; buffer goes over V:$071000); staged at $2000, so before the menu's block
ESC_FONT = $5B              ; V:$05B000-$05DFFF
    org vbank
    dta ESC_FONT-1
    org $2000
    ins '../build/assets/menufont.bin',0,4096
    ini vram_next
    org $2000
    ins '../build/assets/menufont.bin',4096,4096
    ini vram_next
    org $2000
    ins '../build/assets/menufont.bin',8192,4096
    ini vram_next
    icl 'menu.asm'                        ; last: its $2000 is ROT_LUT (zoom_set fills it after)
; [2026-10-27] the ESC menu's (hud.asm esc_menu): this block as loaded -> V:ESC_BANK000
    org vbank
    dta ESC_BANK-1
    ini vram_next

    run start
