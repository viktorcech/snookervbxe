; vbi.asm -- the game's own immediate VBI (after the hot code: it moves nothing).

; vbi: the immediate VBI, instead of the OS's two stages -- only what the game
; reads: RTCLOK, STICK0 / STRIG0, the keyboard debounce (CH comes from the
; keyboard IRQ); A only (the OS NMI saved A, X, Y; XITVBV restores them).
; [2026-10-09 6502-nmos-atari/SKILL.md: interrupt handlers save only what they use and stay short]
; [2026-10-21 6502-nmos-atari/SKILL.md: interrupt handlers stay short -- the sound's timer
;  IRQ (sound.asm) may come in at once: I cleared, unless the NMI came with I set (inside
;  snd_irq or a sei: no IRQ may nest there)]
.proc vbi
    tsx                         ; the P the NMI pushed: under the OS's A, X, Y
    lda $0104,x
    and #$04
    bne i1                      ; I was set: it stays set
    cli                         ; the timer IRQ may come in (it saves its own A, X)
i1:
    inc RTCLOK+2
    bne c
    inc RTCLOK+1
    bne c
    inc RTCLOK
c:
    lda thk                     ; the computer plans: THINKING blinks (thkblk.asm)
    beq t0
    jsr thkblk
t0:
    lda aiact                   ; the computer plays: it writes them (ai.asm)
    bne k0
    lda PORTA                   ; stick 0 = the low nibble
    and #$0F
    sta STICK0
    lda TRIG0
    sta STRIG0
k0:
    lda KEYDEL
    beq k
    dec KEYDEL
k:
    jmp xitvbv              ; (osrom.asm: the OS's XITVBV, the ROM out)
.endp

