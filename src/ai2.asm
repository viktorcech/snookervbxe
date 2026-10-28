; ai2.asm -- the computer player's second code bank: what judges a position
; besides the next pot's ease (Davis, Successful Snooker: Planning; EBSA), the
; break-off.  A 4 KB image in V:AI2_BANK000, the last 4 KB of the AI's 16 KB
; window (win_ai): aiv.asm calls it, it calls aiv.asm, as one program.
    org vbank               ; assembled for $5000 (the 4th 4 KB of the AI's 16 KB window),
    dta AI2_BANK-1          ;   staged at $2000, copied to V:AI2_BANK000 by vram_next
    org $5000,$2000



; erb: the cushion's rebound off the mirror (endpt, aiv.asm): beta - alpha in angle
; units (65536 a turn) by alpha's 512-unit step from the normal, a rolling ball --
; measured in the game's cushion.asm (Mathavan, Jackson, Parkin 2010: the rebound
; angle depends on the incident one only; tools/_dbg_rebound.py)
erbl    dta <65469, <65336, <65240, <65158, <65086, <65011, <64919, <64843, <64791, <64803, <64854, <64982, <65126, <65290, <65457, <95, <269, <443, <588, <721, <844, <957, <1018, <1060, <1070, <1030, <959, <844, <720, <566, <384, <128, <0
erbh    dta >65469, >65336, >65240, >65158, >65086, >65011, >64919, >64843, >64791, >64803, >64854, >64982, >65126, >65290, >65457, >95, >269, >443, >588, >721, >844, >957, >1018, >1060, >1070, >1030, >959, >844, >720, >566, >384, >128, >0
sfx     dta 0, 0            ; sfgeo: 0.875 of the half angle

; sfscan: safeties tried in the physics, not judged by the model (its multi-cushion
; runs are guesswork) -- as choganhq/chogan's snooker AI.  First the two balls on
; at the ends of the cluster as seen from the cue ball (their outer edges are
; free): thin on that edge, 0.875 of the half angle asin(2R / d), at ai_spl 6
; and 7 -- the cue ball off the top and side cushions back to baulk, the pros'
; reply to the break (tools/_dbg_safegrid2.py, _dbg_safevar.py: from baulk in
; baulk at every aim within +-6, $E000..$F000); then the SF_N balls on nearest the cue ball at four
; aims, +-0.8 (firm) and +-0.4 (soft, ai_spl 1).  Each played in sim_shot until
; the cue ball and it stop, measured as s3pick does (leave, psnk) into the list
; (s3ins: one a ball; spi bit 7: psi holds the aim itself)
SF_N    = 2
.proc sfscan
    lda #1
    sta squick
    ldx #NB-1               ; none chosen yet
    lda #0
c0:
    sta sfu,x
    dex
    bpl c0
    lda #$FF                ; the ends: the largest / smallest angle from the first
    sta sfmx                ;   ball on's (signed), sfmx $FF: none yet
    ldx #NB-1
el:
    lda BON,x
    jeq en
    jsr ison
    jcc en
    stx sfb
    jsr tload
    jsr ctot                ; C -> it: cz
    ldx sfb
    sec                     ; v = its angle - the first one's
    lda cz
    sbc sfr
    sta sft
    lda cz+1
    sbc sfr+1
    sta sft+1
    lda sfmx
    bpl e1
    lda cz                  ; the first: the reference, both ends (v 0)
    sta sfr
    lda cz+1
    sta sfr+1
    lda #0
    sta sfvx
    sta sfvx+1
    sta sfvn
    sta sfvn+1
    stx sfmx
    stx sfmn
    beq en                  ; (always)
e1:
    lda sfvx                ; v > the max (signed)?
    cmp sft
    lda sfvx+1
    sbc sft+1
    bvc *+4
    eor #$80
    bpl e2
    lda sft
    sta sfvx
    lda sft+1
    sta sfvx+1
    stx sfmx
e2:
    lda sft                 ; v < the min?
    cmp sfvn
    lda sft+1
    sbc sfvn+1
    bvc *+4
    eor #$80
    bpl en
    lda sft
    sta sfvn
    lda sft+1
    sta sfvn+1
    stx sfmn
en:
    dex
    jne el
    ldx sfmx
    bmi nr                  ; (no ball on)
    lda #0                  ; the counter-clockwise end: its outer edge, the aim +
    jsr sfend
    ldx sfmn
    cpx sfmx
    beq nr                  ; (one ball on)
    lda #$80                ; the clockwise end: the aim -
    jsr sfend
nr:
    lda #SF_N-1
    sta sfn
nbx:
    lda #$FF                ; the nearest ball on not chosen: |dx| + |dy| (32 mm)
    sta sfk
    ldx #NB-1
kl:
    lda BON,x
    beq kn
    lda sfu,x
    bne kn
    jsr ison
    bcc kn
    lda X2,x                ; (C = 1: the bcc not taken -- 2026-10-28 6502-idioms: no sec)
    sbc X2
    bcs k1
    eor #$FF
    adc #1                  ; (C = 0)
k1:
    lsr @
    sta sfa
    sec
    lda Y2,x
    sbc Y2
    bcs k2
    eor #$FF
    adc #1
k2:
    lsr @
    clc
    adc sfa
    cmp sfk
    bcs kn
    sta sfk
    stx sfb
kn:
    dex
    bne kl
    lda sfk                 ; none left
    cmp #$FF
    beq dn
    ldx sfb
    jsr sfgeo
    lda #3                  ; the four aims: 3 +0.8 h, 2 +0.4 h, 1 -0.4 h, 0 -0.8 h
    sta sfs
al:
    ldx sfs                 ; the offset: 0.8 h (firm) or 0.4 h (soft)
    lda sfh
    ldy sfh+1
    cpx #3
    beq o8
    cpx #0
    beq o8
    lda sfq
    ldy sfq+1
o8:
    sta sfo
    sty sfo+1
    ldy #6                  ; the power: thin firm (6), thicker medium (3: 2026-10-27, was
    cpx #3                  ;   1 -- 2160 mm died mid-table; a safety goes back to baulk)
    beq p2
    cpx #0
    beq p2
    ldy #3
p2:
    cpx #2                  ; 3, 2: the way + it (bit 7 0); 1, 0: - it
    ror @
    eor #$80
    sta sfsg
    jsr sfaim
    dec sfs
    bpl al
    dec sfn
    jpl nbx
dn:
    lda #0
    sta squick
    rts
.endp

; sfend: X = an end ball, A = its outer side (bit 7: the aim -): thin on that
; edge, 0.8 h then 0.94 h, firm
; [2026-10-27 the safety to the back cushion (behind the yellow, brown, green): in 10 games
;  of two O'Sullivans none of 37 safeties left the cue ball on it -- $E000 / $F000 stopped it
;  300-650 mm short (measured in the game's physics: the same aim, the power swept); the
;  stronger $10800 / $12000 (ai_spl 8, 9; their third byte ai_spx) reach it, so sfend tries
;  them too and s3pick, five times with his aim error, chooses]
.proc sfend
    sta sfsg
    jsr sfgeo
    lda sfx                 ; 0.875 h (0.906 fouls at some aims between: _dbg_safevar.py)
    ldy sfx+1
    sta sfo
    sty sfo+1
    ldy #6                  ; $E000, $F000, $10800, $12000 (sfaim falls into sftry: Y the
    jsr sfaim               ;   power) -- the stronger two bring the cue ball to the back
    ldy #7                  ;   cushion, the weaker stop it 300-650 mm short (measured)
    jsr sfaim
    ldy #8
    jsr sfaim
    ldy #9
    jmp sfaim
.endp

; sfgeo: X = the ball -> chosen, sfb, at, sfd = the way to it, sfw = 0.94 h,
; sfh = 0.8 h, sfq = 0.4 h (h its half angle = 547600 / d, 65536 a turn: 2R / d
; rad = 34225 / (d / 16))
.proc sfgeo
    stx sfb
    stx at
    inc sfu,x
    jsr tload
    jsr ctot
    lda cz
    sta sfd
    lda cz+1
    sta sfd+1
; [2026-10-28 6502-idioms/SKILL.md: shift in A, not in memory; 6502-loops-tables-smc/SKILL.md:
;  tables beat arithmetic -- d >> 4 = x16[hi] | shr4[lo] when hi < 16]
    lda #$FF                ; (d >= 4 m: 255)
    ldx cd+1
    cpx #16
    bcs d0
    ldy cd
    lda shr4,y
    ora x16,x
d0:
    cmp #7                  ; (d < 112 mm: 7)
    bcs d1
    lda #7
d1:
    sta sfa                 ; 34225 / A, 16 / 8 bits -> sfh
    lda #<34225
    sta sfh
    lda #>34225
    sta sfh+1
    lda #0
    ldx #16
dv:
    asl sfh
    rol sfh+1
    rol @
    bcs ds
    cmp sfa
    bcc dz
ds:
    sbc sfa                 ; (C = 1)
    inc sfh
dz:
    dex
    bne dv
    ldy sfh+1               ; h - h / 16 -> sfw (h <= 34225 / 7: its hi <= $13)
    lda shr4,y
    sta sfa
    tya
    and #$0F
    tax
    ldy sfh
    lda shr4,y
    ora x16,x
    sta sfo
    sec
    lda sfh
    sta sfq                 ; (h -> sfq for m13)
    sbc sfo
    sta sfw
    lda sfh+1
    sta sfq+1
    sbc sfa
    sta sfw+1
    sec                     ; (sfa:sfo is h / 16) h - h / 8 -> sfx (0.875)
    lda sfw
    sbc sfo
    sta sfx
    lda sfw+1
    sbc sfa
    sta sfx+1
    lda sfa                 ; h - 3 h / 32 -> sfw (0.906): h / 32's high byte in A
    lsr @
    ror sfo
    sta sfa
    sec
    lda sfw
    sbc sfo
    sta sfw
    lda sfw+1
    sbc sfa
    sta sfw+1
    jsr m13                 ; 0.8 h ~ h 13 / 16 -> sfh, 0.4 h -> sfq
    lda sfq
    sta sfh
    lda sfq+1
    sta sfh+1
    lsr sfq+1
    ror sfq
    rts
.endp

; sfaim: stgt = sfd + sfo (sfsg bit 7 clear) or - sfo, played at power Y (sftry)
.proc sfaim
    bit sfsg
    bmi mi
    clc
    lda sfd
    adc sfo
    sta stgt
    lda sfd+1
    adc sfo+1
    jmp sa
mi:
    sec
    lda sfd
    sbc sfo
    sta stgt
    lda sfd+1
    sbc sfo+1
sa:
    sta stgt+1
.endp
    ert *<>sftry

; sftry: the ball sfb at stgt, power ai_spl Y, the tip centred: sim_shot, its
; leave (a foul: nothing) into the list
.proc sftry
    sty spi
    lda ai_spl,y
    sta stpw
    lda ai_sph,y
    sta stpw+1
    lda ai_spx,y
    sta stpw+2
    lda #4
    sta sspin
    sta sside
    lda sfb
    sta sat
    jsr sim_shot
    lda scon                ; a foul: nothing
    beq sn
    ldx sfc                 ; the first ball: one on
    bmi sn
    jsr ison
    bcc sn
    ldx #3                  ; (the ball played down as well: its leave as any, lsafe's + 500 mm)
c:
    lda scx,x
    sta ex,x
    lda sox,x
    sta oex,x
    dex
    bpl c
    lda sfb
    sta at
    jsr leavep
    jsr psnk
    jsr lsafe               ; (aipos.asm)
ins:
    lda sfb
    sta at
    lda stgt                ; psi: the aim itself (spi bit 7)
    sta psi
    lda stgt+1
    sta psi+1
    lda spi
    ora #$80
    sta spi
    lda #9                  ; (cd+1: the error's distance part, ~2.3 m)
    sta cd+1
    jmp s3ins
sn:
    rts
.endp
    ert scy<>scx+2 || soy<>sox+2 || ey<>ex+2 || oey<>oex+2

; m13: sfq = sfq * 13 / 16 = q / 2 + q / 4 + q / 16
.proc m13
    lda sfq+1
    sta sfk
    lda sfq
    sta sfa                 ; sfk:sfa = q
    lsr sfk
    ror sfa
    lda sfa                 ; q / 2
    sta sfq
    lda sfk
    sta sfq+1
    lsr sfk
    ror sfa
    clc                     ; + q / 4
    lda sfq
    adc sfa
    sta sfq
    lda sfq+1
    adc sfk
    sta sfq+1
    lsr sfk
    ror sfa
    lsr sfk
    ror sfa
    clc                     ; + q / 16
    lda sfq
    adc sfa
    sta sfq
    lda sfq+1
    adc sfk
    sta sfq+1
    rts
.endp

sfb     dta 0               ; the ball
sfn     dta 0               ; balls left to try
sfs     dta 0               ; the aim: 3 .. 0
sfk     dta 0               ; the nearest's key
sfa     dta 0
sfd     dta 0, 0            ; the way to it
sfh     dta 0, 0            ; 0.8 of its half angle
sfq     dta 0, 0            ; 0.4 of it
sfo     dta 0, 0            ; this aim's offset
sfu     :NB dta 0           ; chosen
sfw     dta 0, 0            ; 0.94 of its half angle
sfsg    dta 0               ; the aim's side (bit 7: -)
sfmx    dta 0               ; the ends: the ball, its angle from the first's
sfmn    dta 0
sfvx    dta 0, 0
sfvn    dta 0, 0
sfr     dta 0, 0            ; the first ball's angle
sft     dta 0, 0

; s3aim: Y = a place in s3r -> sat, at, cz = its aim (psi -> pgeo2, or the aim
; itself when its spi has bit 7: sfscan's), stpw = its power, the tip centred
.proc s3aim
    sty s3a
    lda s3r+2,y
    sta sat
    sta at
    lda s3r+5,y
    pha
    and #$7F
    tax
    lda ai_spl,x
    sta stpw
    lda ai_sph,x
    sta stpw+1
    lda ai_spx,x
    sta stpw+2
    lda #4
    sta sspin
    sta sside
    pla
    bmi dr
    ldx at
    jsr tload
    ldy s3a
    lda s3r+3,y
    sta phi
    lda s3r+4,y
    sta phi+1
    lda #14
    sta cit
    jmp pgeo2
dr:
    ldy s3a
    lda s3r+3,y
    sta cz
    lda s3r+4,y
    sta cz+1
    rts
.endp
s3a     dta 0

; nx_eval's 16 / cos^2 (aiv.asm's: its first 4 KB is full; the window shows both)
nxi_c   dta 227, 202, 182, 164, 149, 135, 124, 114, 105, 97, 90, 84, 78, 73, 68, 64, 60, 57, 53, 51, 48, 45, 43, 41, 39, 37, 35, 34, 32, 31, 30, 28, 27, 26, 25, 24, 23, 22, 22, 21, 20, 19, 19, 18, 18, 17, 18, 20    ; 16 / cos^2 by cos 64ths 17..64 (the last two: dead straight is no position -- a pro leaves an angle)

; opening: the frame's first shot -- the cue ball on the break-off place hpick
; chose (bo_i, aihand.asm), its end red of the pack in its place: the break-off
; found in the game's physics (asm_bench --break): thin on that red with side,
; the cue ball off the top and side cushions back to the baulk cushion (aims
; 101..111 of 65536 end there from (597, 709); thinner than 99 misses the pack).
; C = 1: set.
OPEN_PWR = $00C800
.proc opening
    ldx bo_i                ; the place chosen, the cue exactly on it (hand_ai)
    bmi no
    lda X1
    cmp bo_x1,x
    bne no
    lda X2
    cmp bo_x2,x
    bne no
    lda Y1
    cmp bo_y1,x
    bne no
    lda Y2
    cmp bo_y2,x
    bne no
    ldy bo_b7,x             ; its red in the pack
    lda bo_bt,x
    tax
    jsr same
    bne no
    ldx bo_i
    lda RANDOM              ; the aim: bo_a + 0 .. 7 -- a learnt shot, every player
    and #7                  ;   hits it (the player's error would miss the pack)
    clc
    adc bo_al,x
    sta tgt
    lda bo_ah,x
    adc #0
    sta tgt+1
    lda #<OPEN_PWR
    sta tpw
    lda #>OPEN_PWR
    sta tpw+1
    lda #OPEN_PWR>>16
    sta tpw+2
    lda #4
    sta spin
    lda bo_sd,x             ; the tip's side (r11: left of centre), the red
    sta side
    lda bo_bt,x
    sta bt
    lda #9                  ; 2.3 m to the ghost (/256: the error's distance part)
    sta edc
    lda #$FF                ; (no pot: best none)
    sta best
    sta best+1
    sec
    rts
no:
    clc
    rts
; same: X a ball, Y its init_balls record -> Z = 1 when it is at its place there (Q4)
same:
    lda X1,x
    cmp init_balls+1,y
    bne r
    lda X2,x
    cmp init_balls+2,y
    bne r
    lda Y1,x
    cmp init_balls+4,y
    bne r
    lda Y2,x
    cmp init_balls+5,y
r:
    rts
.endp

; pmov: C = 1 when the shot moved or potted a ball besides the cue and bt (its
; position, Q4 high bytes, against ppx / ppy; the balls on against pbn)
.proc pmov
    lda #0
    sta pcnt
    ldx #NB-1
l:
    cpx bt
    beq n
    lda BON,x
    beq n
    inc pcnt
    lda X2,x
    cmp ppx,x
    bne y
    lda Y2,x
    cmp ppy,x
    bne y
n:
    dex
    bne l
    lda pcnt                ; one down too: C = 1
    cmp pbn
    bne y
    clc
    rts
y:
    sec
    rts
.endp

; pclose: no pot left for the cue ball: sev = $E000 + 16 x (the nearest ball on,
; |dx| + |dy| in 32 mm) -- after a baulk colour, back up to the reds
.proc pclose
    lda #$FF
    sta ppm
    ldx #NB-1
nl:
    jsr nexton
    bcc nn
    lda X2,x                ; (C = 1: the bcc not taken -- 2026-10-28 6502-idioms: no sec)
    sbc scx+1
    bcs a1
    eor #$FF
    adc #1                  ; (C = 0)
a1:
    lsr @
    sta a2t
    sec
    lda Y2,x
    sbc scy+1
    bcs a2
    eor #$FF
    adc #1
a2:
    lsr @
    clc
    adc a2t
    cmp ppm
    bcs nn
    sta ppm
nn:
    dex
    bne nl
    lda ppm
    sta sev
    lda #0
    ldx #4
s4:
    asl sev
    rol @
    dex
    bne s4
    ora #$E0
    sta sev+1
    rts
.endp


; kver: the no-safety shot (ai_safe's roll-up or kick: tgt, tpw) played in the
; physics before it is played, as cue-club plays every candidate: the aim and
; +-64, +-160, +-320 units round it, at the power, x1.5, x2, until the cue ball's
; first ball is one on and it stays on the table -> tgt, tpw.  None legal: as planned
KV_A    = 7
.proc kver
    lda #0
    sta sevon
    sta kvk
    sta sat                 ; (the cue ball: a sim ends when it stops -- the first ball
    lda #1                  ;   hit and the cue ball are all it reads)
    sta squick
    lda #4
    sta sspin
    sta sside
    ldx #2
c0:
    lda tpw,x
    sta kvp,x
    sta kvq,x
    dex
    bpl c0
pw:
    ldx #0
al:
    stx kvi
    clc
    lda tgt
    adc kvl,x
    sta stgt
    lda tgt+1
    adc kvh,x
    sta stgt+1
    ldx #2
c1:
    lda kvq,x
    sta stpw,x
    dex
    bpl c1
    jsr sim_shot
    lda scon                ; the cue ball down
    beq bad
    ldx sfc                 ; no ball hit
    bmi bad
    jsr ison                ; not a ball on first
    bcc bad
    lda stgt                ; legal: this one
    sta tgt
    lda stgt+1
    sta tgt+1
    ldx #2
c2:
    lda kvq,x
    sta tpw,x
    dex
    bpl c2
    lsr squick              ; (1 -> 0)
    rts
bad:
    ldx kvi
    inx
    cpx #KV_A
    bcc al
    inc kvk                 ; the next power: x1.5, then x2 (PWR_MAX at most)
    lda kvk
    cmp #3
    bcs no
    cmp #2
    beq x2
    lda kvp+2               ; x1.5: p / 2 + p
    lsr @
    sta kvq+2
    lda kvp+1
    ror @
    sta kvq+1
    lda kvp
    ror @
    clc
    adc kvp
    sta kvq
    lda kvq+1
    adc kvp+1
    sta kvq+1
    lda kvq+2
    adc kvp+2
    sta kvq+2
    bcc mx                  ; (always: no carry out of 24 bits)
x2:
    lda kvp                 ; x2: p * 2
    asl @
    sta kvq
    lda kvp+1
    rol @
    sta kvq+1
    lda kvp+2
    rol @
    sta kvq+2
mx:
    lda kvq+2               ; PWR_MAX at most
    cmp #PWR_MAX>>16
    bcc pk
    bne cl
    lda kvq+1
    cmp #>PWR_MAX
    bcc pk
cl:
    lda #<PWR_MAX
    sta kvq
    lda #>PWR_MAX
    sta kvq+1
    lda #PWR_MAX>>16
    sta kvq+2
pk:
    jmp pw
no:
    lsr squick
    rts
.endp
kvl     dta <0, <64, <-64, <160, <-160, <320, <-320
kvh     dta >0, >64, >-64, >160, >-160, >320, >-320
kvi     dta 0
kvk     dta 0
kvp     dta 0, 0, 0         ; the power planned
kvq     dta 0, 0, 0         ; this try's

; bbox: X = 0 (x) / 3 (y) -> bxl,x .. bxh,x: blocked's path from (absx, absy) for
; blen (Q4) along btr's cos / sin, its two ends' min - M and max + M (M = 2R + 9 mm:
; the 8 mm of its test and 1 mm for the end's rounding); Q4, the low end >= 0
BB_M    = AI_2R+144
.proc bbox
    stx bbx
    lda blen                ; d = blen cos (or sin)
    sta sA
    lda blen+1
    sta sA+1
    lda #0
    sta sA+2
    lda btr,x
    sta sB
    lda btr+1,x
    sta sB+1
    lda btr+2,x
    sta sB+2
    jsr smul3r
    ldx bbx
    ldy #0                  ; the start: absx or absy (= absx + 2)
    cpx #3
    bcc s0
    ldy #2
s0:
    clc                     ; e = s + d, 0 .. $FFFF (a path may run off the table)
    lda absx,y
    adc sP
    sta bbe
    lda absx+1,y
    adc sP+1
    sta bbe+1
    lda sP+2                ; d < 0: no carry is below 0; d >= 0: a carry is past $FFFF
    bmi en
    bcc ok
    lda #$FF
    bne cl                  ; (always)
en:
    bcs ok
    lda #0
cl:
    sta bbe
    sta bbe+1
ok:
    lda absx,y              ; lo = min(s, e), hi = max
    cmp bbe
    lda absx+1,y
    sbc bbe+1
    bcs se
; [2026-10-28 6502-idioms/SKILL.md: compute in A, store once -- lo - M and hi + M straight
;  from s / e (no bxl / bxh store and reload); C = 0 here: sbc #M-1 is - M]
    lda absx,y              ; s < e: lo = s - M (0 at least)
    sbc #<[BB_M-1]
    sta bxl,x
    lda absx+1,y
    sbc #>[BB_M-1]
    bcs l0
    lda #0
    sta bxl,x
l0:
    sta bxl+1,x
    clc                     ; hi = e + M ($FFFF at most)
    lda bbe
    adc #<BB_M
    sta bxh,x
    lda bbe+1
    adc #>BB_M
    bcc h0
    lda #$FF
    sta bxh,x
h0:
    sta bxh+1,x
    rts
se:                         ; s >= e (C = 1): lo = e - M, hi = s + M
    lda bbe
    sbc #<BB_M
    sta bxl,x
    lda bbe+1
    sbc #>BB_M
    bcs l1
    lda #0
    sta bxl,x
l1:
    sta bxl+1,x
    clc
    lda absx,y
    adc #<BB_M
    sta bxh,x
    lda absx+1,y
    adc #>BB_M
    bcc h1
    lda #$FF
    sta bxh,x
h1:
    sta bxh+1,x
    rts
.endp
    ert absy<>absx+2
bxl     dta 0, 0, 0, 0, 0   ; x lo (0, 1), y lo (3, 4)
bxh     dta 0, 0, 0, 0, 0
bbe     dta 0, 0
bbx     dta 0

; kclr / kins: ai_plan's KP_N easiest pots, easiest first (ease, the ball, the pocket,
; D, edc); best = the last one's ease, the bar a pot must pass to be listed
; [2026-10-27: KP_N 3 -> 4 -- in mid-game the pot with the natural position was often
;  the 4th easiest and never looked at]
KP_N    = 4                 ; the pots tried (the list holds KP_N)
.proc kclr
    lda #$FF
    sta best
    sta best+1
    ldx #KP_N*2-1
c:
    sta kel,x               ; (kel, keh: KP_N * 2 bytes)
    dex
    bpl c
    rts
.endp
    ert keh<>kel+KP_N

.proc kins
    ldy #KP_N-1             ; its place: after the last it is not ahead of (ties keep
f:                          ;   the order found)
    dey
    bmi p
    lda ease
    cmp kel,y
    lda ease+1
    sbc keh,y
    bcc f
p:
    iny
    sty kpl
    ldx #KP_N-2             ; the entries from there one down (the last drops off)
s:
    cpx kpl
    bcc w
    lda kel,x
    sta kel+1,x
    lda keh,x
    sta keh+1,x
    lda kat,x
    sta kat+1,x
    lda kap,x
    sta kap+1,x
    lda kdl,x
    sta kdl+1,x
    lda kdh,x
    sta kdh+1,x
    lda kdc,x
    sta kdc+1,x
    dex
    bpl s
w:
    lda ease
    sta kel,y
    lda ease+1
    sta keh,y
    lda at
    sta kat,y
    lda ap
    sta kap,y
    lda dd
    sta kdl,y
    lda dd+1
    sta kdh,y
    lda edc
    sta kdc,y
    lda kel+KP_N-1
    sta best
    lda keh+KP_N-1
    sta best+1
    rts
.endp

; kplay: the listed pots within his nerve, easiest first, each played in the
; physics PV_N ways (ptry): the one whose ease + its best next pot (ppb) is least
; is chosen (Davis: position decides which ball, not only how) -- a pot whose ease
; alone reaches the best total is not tried.  Then 6 ways round the winner's best
; (round 2) -> bt, abp, edc, tgt, tpw, spin, side; best = its ease.  C = 1: none
; in his nerve (best = $FFFF: a safety)
PV_N    = 9                 ; round 1's ways (pvs, pvk)
SEV_OK  = $0200             ; a leave this good (sev < it, whole 256s) ends the search: after
SEV_OKC = $0400             ;   a red (the black's weight 1/8), after a colour (weights ~8/8)
; [2026-10-27: SEV_OKC $0800 -> $0400 -- after a colour any straight red within ~70 cm
;  ended the search at the first variant (stun), the best leave never sought; now only
;  a red really at hand (~40 cm, straight) does; the search otherwise runs through
;  every variant, round 2 and the other KP_N pots]
.proc kplay
    lda #$FF                ; (none is below $FFFF: the easiest, round 1 as planned)
    sta kbl
    sta kbh
    sta kpb
    sta kpb+1
    lda #4
    sta kst
    sta kst+2
    lda #8
    sta kst+1
    ldx #0
    stx kw
    stx kpl
    jsr knerve              ; the easiest in his nerve?
    bcc k1
    lda #$FF
    sta best
    sta best+1
    rts
k1:
    ldy #NB-1               ; the last ball on the table: no next shot to play for --
    lda #0                  ;   the easiest, the centre, the speed planned, no sims
c1:
    adc BON,y               ; (C = 0: <= 21)
    dey
    bne c1
    cmp #2
    bcs kl
    jsr kset                ; (X = 0)
    lda kel
    sta best
    lda keh
    sta best+1
    lda #0
    sta sevon
    lda #4
    sta spin
    sta side
    clc
    rts
kl:
    lda kel,x               ; bound: its ease alone >= the best total
    cmp kbl
    lda keh,x
    sbc kbh
    jcs kd
    jsr kset
    ldx #0                  ; round 1, the plainest first (stun, the speed planned) --
r1:                         ;   stopped by the first leave good enough (SEV_OK)
    stx ppi
    lda pvs,x
    ldy pvk,x
    ldx #4
    jsr ptry
    lda ppb+1
    cmp kok
    bcc r2
    ldx ppi
    inx
    cpx pvn                 ; (PV_N; + 3 harder ones for the split, cnset)
    bcc r1
r2:
    lda cnon                ; nothing to play after it (the leave beyond his nerve), a
    beq r2a                 ;   tied ball to free: the cannon into it as well (aipos.asm)
    ldy aip
    lda ppb
    cmp ai_dml-1,y
    lda ppb+1
    sbc ai_dmh-1,y
    bcc r2a
    jsr cannon
r2a:
    ldx kpl                 ; the total: ease + ppb (saturating)
    clc
    lda kel,x
    adc ppb
    sta ktl
    lda keh,x
    adc ppb+1
    bcc t0
    lda #$FF
    sta ktl
t0:
    sta kth
    cmp kbh
    bne t1
    lda ktl
    cmp kbl
t1:
    bcs kn
    lda ktl
    sta kbl
    lda kth
    sta kbh
    stx kw
    lda pbt
    sta kst
    lda pbk
    sta kst+1
    lda pbs
    sta kst+2
    lda cnf                 ; (its best the cannon: no round 2 -- aipos.asm)
    sta kcn
    lda ppb
    sta kpb
    lda ppb+1
    sta kpb+1
kn:
    lda kpb+1               ; the best so far good enough: the harder pots not tried
    cmp kok
    bcc kd
    inc kpl
    ldx kpl
    cpx #KP_N
    bcs kd
    jsr knerve
    jcc kl
kd:
    ldx kw                  ; the winner set up again (no sims), round 1's best
    lda kel,x
    sta best
    lda keh,x
    sta best+1
    jsr kset
    lda kst
    sta pbt
    sta pb0
    lda kst+1
    sta pbk
    sta pb0+1
    lda kst+2
    sta pbs
    lda kpb
    sta ppb
    lda kpb+1
    sta ppb+1
    cmp kok            ; good enough: no round 2
    bcc s5
    lda kcn                 ; the cannon chosen: played as the geometry gave it -- round 2's
    bne s5                  ;   hard shots would cost seconds (aipos.asm)
    ldx #5                  ; round 2: the tip 2 up / down, the speed 3/8 down / up,
s2:                         ;   side left / right
    stx ppi
    clc
    lda pb0
    adc pdt,x
    bpl s3
    lda #0
s3:
    cmp #9
    bcc s4
    lda #8
s4:
    pha
    clc
    lda pb0+1
    adc pdk,x
    tay
    lda pds,x
    tax
    pla
    jsr ptry
    ldx ppi
    dex
    bpl s2
s5:
    lda #0
    sta sevon
    lda pbt
    sta spin
    lda pbs
    sta side
    lda pbk
    jsr ppw
    clc
    rts
.endp

; knerve: X = a list place -> C = 0 when its pot is in his nerve (ai_dml). Keeps X.
.proc knerve
    ldy aip
    lda kel,x
    cmp ai_dml-1,y
    lda keh,x
    sbc ai_dmh-1,y
    rts
.endp

; kset: X = a list place -> its pot set up as the one played: bt, abp, edc, dd, kok, its
; aim to 14 turns (tgt), his power (ar, tpw); then the balls kept for ppev (ppx,
; ppy), the next pots from there (nx_build 1) and round 1's start
.proc kset
    lda kat,x
    sta bt
    lda kap,x
    sta ap
    sta abp
    lda kdc,x
    sta edc
    lda kdl,x
    sta dd
    lda kdh,x
    sta dd+1
    ldx bt
    lda #>SEV_OK            ; (good enough: by what comes next)
    cpx #16
    bcc ko
    lda #>SEV_OKC
ko:
    sta kok
    jsr tload
    lda #14
    sta cit
    jsr pgeo1
    lda cz
    sta phi
    lda cz+1
    sta phi+1
    jsr pgeo2
    lda cz
    sta tgt
    lda cz+1
    sta tgt+1
    lda dd                  ; the power, his
    ldx dd+1
    jsr power
    ldx aip
    lda ai_pm-1,x
    ldx ar
    jsr fmulu
    lda fmpl                ; r * pm / 128
    asl @
    lda fmph
    rol @
    bcc pw
    lda #$FF
pw:
    jsr pset
    ldx #NB-1               ; the balls where they are (Q4 high bytes: 16 mm): ppev
m0:                         ;   sees which the shot moved
    lda X2,x
    sta ppx,x
    lda Y2,x
    sta ppy,x
    dex
    bpl m0
    lda #9                  ; the list of the next pots, once (cordic: 9 turns do for a
    sta cit                 ;   judgement): bt off the table for it (it goes down)
    ldx bt
    lda BON,x
    pha
    lda #0
    sta BON,x
    lda #2                  ; the reds but bt with a clear pocket -> cnfr (cnset: the pack
    jsr nx_build            ;   closed?), then the list of the next pots
    lda nxn
    sta cnfr
    lda #1
    jsr nx_build
    ldx bt
    pla
    sta BON,x
    jsr pmov                ; (pcnt, the balls on but the cue and bt)
    lda pcnt
    sta pbn
    lda ar
    sta ppr
    lda #$FF
    sta ppb
    sta ppb+1
    sta sevon               ; sim_shot asks ppev at its end
    lda #4                  ; (none found: the centre, side 0, the speed planned)
    sta pbt
    sta pbs
    lda #8
    sta pbk
    jmp cnset               ; the balls on next that are tied: the cannon's target (aipos.asm)
.endp

; pchk: after a sim, C = 1 when the next pots' list (nxe) may be stale and must
; be built again: a ball besides the cue and bt went down (pmov's count), a ball
; on next moved, or another ball came to rest within 64 mm of the box of a listed
; ball's way to its pocket (it may block that way now).  A red the shot moved far
; from those ways changes nothing.
.proc pchk
    jsr pmov
    bcs c0
    rts                     ; nothing moved (C = 0)
c0:
    lda pcnt
    cmp pbn
    bne yes                 ; one went down
    lda nxn                 ; the list's end: nxn * 6
    asl @
    adc nxn                 ; (C = 0: nxn <= 40)
    asl @
    sta pqe+1               ; [2026-10-28 6502-loops-tables-smc/SKILL.md: the end as cpy #]
    ldx #NB-1
l:
    cpx bt
    beq n
    lda BON,x
    beq n
    lda X2,x
    cmp ppx,x
    bne mv
    lda Y2,x
    cmp ppy,x
    beq n
mv:
    jsr nexton              ; a ball on next moved
    bcs yes
    stx pqx
    lda X2,x                ; its place (32 mm units)
    lsr @
    sta pqu
    lda Y2,x
    lsr @
    sta pqv
    ldy #0
e:
pqe cpy #0
    bcs en
    lda pqu                 ; inside the entry's box?  x, then y
    sta pqp
    lda nxe,y
    ldx nxe+2,y
    jsr inb
    bcs nx
    lda pqv
    sta pqp
    lda nxe+1,y
    ldx nxe+3,y
    jsr inb
    bcs nx
    jsr qnear               ; and near its line?
    bcc yes
nx:
    ldx pqx
    tya
    adc #5                  ; (C = 1: + 6)
    tay
    bne e                   ; (always: < 240)
en:
    ldx pqx
n:
    dex
    bne l
no:
    clc
    rts
yes:
    sec
    rts
.endp

; qnear: Y = an nxe entry, (pqu, pqv) a ball's place -> C = 0 when it lies near
; the entry's way: |d x (p - a)| < 3 |d| (2R and the 32 mm rounding: under ~96 mm).
; Keeps Y.
.proc qnear
    sty pqy
    sec
    lda pqv
    sbc nxe+1,y
    ldx nxe+2,y
    jsr smul8               ; dx (v - ay)
    sta pqc
    stx pqc+1
    ldy pqy
    sec
    lda pqu
    sbc nxe,y
    ldx nxe+3,y
    jsr smul8               ; dy (u - ax)
    sta pqp                 ; (pqp, pql: its product)
    stx pql
    sec                     ; the cross product
    lda pqc
    sbc pqp
    sta pqc
    lda pqc+1
    sbc pql
    bpl a0
    tax                     ; |it|
    lda #0
    sec
    sbc pqc
    sta pqc
    txa
    eor #$FF
    adc #0
a0:
    sta pqc+1
    ldy pqy                 ; 3 |d| (the run, nxe+4)
    lda nxe+4,y
    asl @
    sta pqp
    lda #0
    rol @
    sta pql
    clc
    lda nxe+4,y
    adc pqp
    sta pqp
    lda pql
    adc #0
    sta pql
    lda pqc                 ; |cross| < 3 |d|: C = 0
    cmp pqp
    lda pqc+1
    sbc pql
    ldy pqy
    rts
.endp

; inb: A = a, X = d (signed: the pocket - the ball), pqp = a point (32 mm units)
; -> C = 0 when min(a, a + d) - 2 <= pqp <= max(a, a + d) + 2.  Keeps Y.
.proc inb
    sta pql
    sta pqh
    txa
    clc
    adc pql                 ; a + d (no wrap: both ends on the table, < 112)
; [2026-10-28 6502-idioms/SKILL.md: a known carry needs no clc -- it rides in the literal:
;  d >= 0 comes with C = 0 (adc #2), d < 0 with C = 1 (adc #1)]
    cpx #$80
    bcs ng
    sta pqh                 ; d >= 0: [a, a + d]
    lda pqp
    adc #2                  ; (C = 0: cpx < $80)
t:
    cmp pql                 ; p + 2 >= lo?
    bcc out
    lda pqh
    adc #1                  ; (C = 1: + 2)
    cmp pqp                 ; hi + 2 >= p?
    bcc out
    clc
    rts
ng:
    sta pql                 ; d < 0: [a + d, a]
    lda pqp
    adc #1                  ; (C = 1: the bcs taken -- + 2)
    bcc t                   ; (always: p + 2 < 256)
out:
    sec
    rts
.endp

pqx     dta 0               ; pchk: the ball, its place, the entry (the list's end: pchk.pqe)
pqu     dta 0
pqv     dta 0
pqy     dta 0
pqc     dta 0, 0            ;   the cross product
pqp     dta 0
pql     dta 0               ; inb: the box's low and high ends
pqh     dta 0

kel     :KP_N dta 0         ; the list: ease lo, hi (kclr: kel, keh adjacent)
keh     :KP_N dta 0
kat     :KP_N dta 0         ; the ball
kap     :KP_N dta 0         ; the pocket
kdl     :KP_N dta 0         ; D lo, hi
kdh     :KP_N dta 0
kdc     :KP_N dta 0         ; edc
kpl     dta 0               ; a place
kok     dta 0               ; SEV_OK's high byte for this pot
kw      dta 0               ; the winner's place
kbl     dta 0               ; the best total
kbh     dta 0
ktl     dta 0               ; a total
kth     dta 0
kst     dta 0, 0, 0         ; the winner's round-1 best: tip, speed * 8, side
kpb     dta 0, 0            ;   its ppb
; leavep: leave for a safety played in the physics: his pots from the cue ball
; checked for a clear way (nxclr); the model's many leaves use nx_eval alone
.proc leavep
    inc nqon
    jsr leave
    dec nqon
    rts
.endp
; lnx: leave's nx_eval -- nxclr when leavep asked
.proc lnx
    lda nqon
    jne nxclr
    jmp nx_eval
.endp
nqon    dta 0

; nxclr: nx_eval from (ex, ey), but the easiest whose ball the cue ball can reach
; (blocked: nothing within 2R of its run to 2R short of the ball) -> A:X as
; nx_eval's, nxbi.  The blocked ones get weight 0 (nx_eval skips them) until it
; ends, then theirs back.  The cue ball's RAM place is (ex, ey) meanwhile (ctot).
NQ_MAX  = 8
.proc nxclr
    lda X1                  ; (the cue ball's X1 X2 Y1 Y2 kept)
    sta nqc
    lda X2
    sta nqc+1
    lda Y1
    sta nqc+2
    lda Y2
    sta nqc+3
    lda ex
    sta X1
    lda ex+1
    sta X2
    lda ey
    sta Y1
    lda ey+1
    sta Y2
    lda at                  ; (blocked skips ball `at`: the one looked at, for now)
    sta nqat
    ldx #3
t0:
    lda tx,x                ; T and C -> T: the caller's (the safety model's loop)
    sta nqt,x
    lda cz,x
    sta nqz,x
    dex
    bpl t0
    lda #0
    sta nqn
    sta blg                 ; (any ball blocks)
lp:
    jsr nx_eval
    sta nqa
    stx nqa+1
    and nqa+1
    cmp #$FF
    beq dn                  ; none left
    jsr nqball              ; X = the ball of nxe[nxbi]
    stx at
    jsr tload               ; T
    jsr ctot                ; C -> T: cz, cd (mm)
    ldx #3
c1:
    lda ex,x                ; (ex, ey -> absx, absy)
    sta absx,x
    dex
    bpl c1
    lda cz
    sta bang
    lda cz+1
    sta bang+1
    sec
    lda cd
    sbc #53                 ; 2R short of it
    tay
    lda cd+1
    sbc #0
    bcc dn                  ; (touching: clear)
    tax
    tya
    jsr blocked
    bcc dn                  ; clear: this one
    ldx nqn                 ; blocked: off the list for now
    cpx #NQ_MAX
    bcs no
    ldy nxbi
    tya
    sta nqi,x
    lda nxe+5,y
    sta nqw,x
    lda #0
    sta nxe+5,y
    inc nqn
    bne lp                  ; (always)
no:
    lda #$FF
    sta nqa
    sta nqa+1
dn:
    ldx nqn                 ; the weights back
    beq w0
w:
    ldy nqi-1,x
    lda nqw-1,x
    sta nxe+5,y
    dex
    bne w
w0:
    lda nqc
    sta X1
    lda nqc+1
    sta X2
    lda nqc+2
    sta Y1
    lda nqc+3
    sta Y2
    lda nqat
    sta at
    ldx #3
t1:
    lda nqt,x
    sta tx,x
    lda nqz,x
    sta cz,x
    dex
    bpl t1
    lda nqa
    ldx nqa+1
    rts
.endp

; nqball: nxe[nxbi]'s ball -> X: the ball on the table nearest its x, y (32 mm)
; [2026-10-28 6502-loops-tables-smc/SKILL.md: a variable as the operand of sbc # / cmp # --
;  the target's x, y and the nearest so far, patched once (no ldy nxbi, no abs,y a ball)]
.proc nqball
    ldy nxbi
    lda nxe,y
    sta ex+1
    lda nxe+1,y
    sta ey+1
    lda #$FF
    sta cq+1
    ldx #NB-1
l:
    lda BON,x
    beq n
    lda X2,x
    lsr @
    sec
ex  sbc #0
    bcs a1
    eor #$FF
    adc #1                  ; (C = 0)
a1:
    sta a2t
    lda Y2,x
    lsr @
    sec
ey  sbc #0
    bcs a2
    eor #$FF
    adc #1
a2:
    clc
    adc a2t
    bcs n
cq  cmp #0
    bcs n
    sta cq+1
    stx nqb
n:
    dex
    bne l
    ldx nqb
    rts
.endp

nqc     dta 0, 0, 0, 0      ; the cue ball's RAM place (X1 X2 Y1 Y2)
nqn     dta 0               ; the entries blocked
nqi     :NQ_MAX dta 0       ; their nxe offsets
nqw     :NQ_MAX dta 0       ;   and weights
nqa     dta 0, 0            ; nx_eval's answer
nqat    dta 0               ; `at` kept
nqt     dta 0, 0, 0, 0      ; tx ty kept
nqz     dta 0, 0, 0, 0      ; cz cd kept
nqb     dta 0               ; nqball: the nearest ball (its distance: nqball.cq.s operand)
ppm     dta 0
a2t     dta 0               ; (this bank's own temp: aiv.asm's ttmp is out of the window)


    ert *>$6000
    ini vram_next
