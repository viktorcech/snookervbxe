; [2026-10-21 6502-loops-tables-smc/SKILL.md: self-modifying code -- the sample pointer is the
;  operand of lda abs, its MEMB bank and the IRQEN acknowledge values lda # operands, MEMB's
;  address (VBXE at $D600 / $D700) patched once, the OS vector a jmp abs; a terminator ends
;  the scan (0: the lda's Z, no counter, no cmp); 6502-nmos-atari/SKILL.md: a handler saves
;  only what it uses (A, X) and stays short; the OS's IRQ entry does the cld;
;  6502-idioms/SKILL.md: the timer bit by lsr into C; X saved as stx / ldx # (not re-entrant:
;  vbi lets no IRQ into snd_irq) -- 6 cycles for txa / pha / pla / tax's 11;
;  6502-cycles-layout/SKILL.md: the rare cases (other, stop, hi) out of line, the common path
;  falls through every branch; 6502-idioms/SKILL.md (code size is RAM): the rare ones go to
;  the shared exit instead of repeating it, hi by bne (Z known); the acknowledge values once
;  in snd_init (POKMSK's other bits do not change in the game); vbxe-blitter/SKILL.md: code
;  running with a MEMAC window open not inside it (ert)]
; sound.asm -- samples on POKEY, all four channels volume-only as one output
; (~190 levels: tools/snd_prep.py); the timer 1 IRQ (10556 Hz) reads a sample
; and the four AUDCs for it from VRAM through MEMAC-B, 0 ends a sound.

AUDF1   = $D200
AUDC1   = $D201
AUDC2   = $D203
AUDC3   = $D205
AUDC4   = $D207
AUDCTL  = $D208
STIMER  = $D209
IRQEN   = $D20E             ; (write) the IRQ enables
IRQST   = $D20E             ; (read) the IRQ status, active low
POKMSK  = $10               ; the OS's IRQEN shadow
VIMIRQ  = $0216             ; the OS's immediate IRQ vector
MEMB    = $5D               ; MEMAC_B_CONTROL, from the VBXE base (VB)
SND_VRAM = $08000           ; the sounds' first bank (tools/snd_prep.py), the tables at its start
SND2_VRAM = $44000          ; the later sounds' bank (snd_prep.py SND2_VRAM), its own tables

; snd_init: the IRQ hooked in front of the OS's (any other IRQ goes on to it),
; the acknowledge values, the channels at the rest level
.proc snd_init
    lda VB+1                ; MEMB's page ($D6 / $D7)
    sta snd_irq.on+2
    sta snd_irq.off+2
    sta snd_irq.off0+2
    lda VIMIRQ              ; the OS's handler: snd_irq's way on (and kept: os_off
    sta snd_irq.os+1        ;   turns that way to kbirq, hud.asm esc_quit hands the
    sta os_irq              ;   OS its own back for SIO)
    lda VIMIRQ+1
    sta snd_irq.os+2
    sta os_irq+1
    lda POKMSK              ; the acknowledge: timer 1 off, then on again
    and #$FE
    sta snd_irq.ack0+1
    ora #1
    sta snd_irq.ack1+1
    lda #0
    sta AUDCTL              ; 64 kHz clock, no joined channels
    lda #SND_MID1           ; volume only: the middle level, where a sound starts
    sta AUDC1
    lda #SND_MID2
    sta AUDC2
    lda #SND_MID3
    sta AUDC3
    lda #SND_MID4
    sta AUDC4
    lda #SND_AUDF
    sta AUDF1
    php
    sei
    lda #<snd_irq
    sta VIMIRQ
    lda #>snd_irq
    sta VIMIRQ+1
    plp
    rts
.endp

os_irq  dta a(0)             ; the OS's VIMIRQ as snd_init found it

; snd_play: X = a sound (SND_*) -> playing from now (timer 1 restarted; a
; playing one is cut off)
.proc snd_play
    bit simon                   ; a shot only simulated (sim_shot): silent
    bpl go
    rts
go:
    php
    sei
    lda snd_b,x
    sta snd_irq.bank+1
    lda snd_lo,x
    sta snd_irq.smp+1
    lda snd_hi,x
    sta snd_irq.smp+2
    lda snd_irq.ack1+1      ; POKMSK with timer 1 on
    sta POKMSK
    sta IRQEN
    sta STIMER
    plp
    rts
.endp

; snd_irq: one sample a timer 1 IRQ (status bit 0 = 0); 0 ends the sound
.proc snd_irq
    pha
    lda IRQST
    lsr @                   ; C = bit 0: 1 = not timer 1
    bcs other
    stx xs+1                ; X kept (no stack: snd_irq is never re-entered)
ack0
    lda #0                  ; (POKMSK without bit 0: snd_init)
    sta IRQEN
ack1
    lda #0                  ; (POKMSK with it: snd_init)
    sta IRQEN
bank
    lda #0                  ; (the sound's MEMB: snd_play)
on
    sta $D600+MEMB          ; (the page: snd_init)
smp
    lda $FFFF               ; (the next sample: snd_play, then counted on)
    beq stop                ; 0: its end
    tax
    lda $4000,x             ; the four channels' volumes for that level
    sta AUDC1
    lda $4100,x
    sta AUDC2
    lda $4200,x
    sta AUDC3
    lda $4300,x
    sta AUDC4
    lda #0
off
    sta $D600+MEMB          ; the window closed
    inc smp+1
    beq hi
xs
    ldx #0                  ; (X: the stx above)
    pla
    rti
hi:
    inc smp+2               ; (a sound stays inside its 16 KB bank:
    bne xs                  ;   $40..$7F, never 0)
stop:
off0
    sta $D600+MEMB          ; (A = 0) the window closed; the channels hold the last level
    lda ack0+1              ; timer 1 off
    sta POKMSK
    sta IRQEN
    bcc xs                  ; (always: C = 0 since bcs other -- lda / sta / stx keep it)
other:
    pla
os
    jmp $FFFF               ; (the OS's VIMIRQ: snd_init)
.endp
    ert snd_irq<$8000 && snd_irq.os+3>$4000     ; (it reads with MEMAC-B on $4000-$7FFF)

; sounds_0 / sounds_1: the INI of each sound bank's first 4 KB (sounds.inc)
; -> V:$08000 / V:$44000 on
.proc sounds_1
    ldx #[SND2_VRAM>>12]
    bne sounds_0.go         ; (always)
.endp
.proc sounds_0
    ldx #[SND_VRAM>>12]
go:
    stx vbank
    jmp vram_chunk
.endp

    icl '../build/assets/sound_tab.inc'
