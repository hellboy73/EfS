; =============================================================================
; rumble.s - the pad shakes when the ship is hurt (madsim: LED7 / LED6)
; =============================================================================
; Nothing here is hardware. On the MAD-65 the CPU OS exposes 8 diagnostic LEDs
; at LED_CPU_REG ($BFC0, write only; LED_CPU_MIR $0278 is the readable copy),
; and the madsim SIMULATOR shakes the USB pad on joystick port 1 while LED7 is
; lit and the pad on port 2 while LED6 is (MAD65_Software_Developers_Guide.md,
; "Simulator only: LED7 and LED6 as rumble"). On the real machine the same two
; bits just light two LEDs, so using them costs a game nothing. LED0-LED3 are the
; POST pattern and are never touched here (the mask below keeps them).
;
; The pad shaken is the PLAYING one (JOYPORT, screens.s).
;
; THE LENGTHS ARE THE POINT. A pad's motor spins up slowly and madsim hands the
; change to a force-feedback thread that ticks every 50 ms: pulses of 6 and 16
; frames were not felt on a real pad, 12 and 24 were. So ~10 frames is the floor,
; 10-15 reads as a tap and 20-30 as a heavy hit. RUM_TAP / RUM_HEAVY / RUM_DEATH
; below are those, and are the numbers to tune.
;
; NO HOOKS IN THE GAME'S CODE. rumble_tick, once a frame from frame_body
; (main.s), WATCHES what the game already keeps: SHIPHP falling is a hit, LIVES
; falling is a lost ship, SHK_TIMER rising is the screen shaking (objects.s
; shake_arm - a rock breaking or cracking). That is deliberate - the damage paths live in upper RAM
; with no bytes to spare, and one observer catches the ram, the bullet, the
; EMP mine and anything added later. A pulse only ever EXTENDS the one running.
; It runs on the screens too, so a pulse still in flight when the sector ends
; dies out there instead of leaving the pad buzzing through SECTOR CLEARED.
; =============================================================================

LED_CPU_REG = $BFC0
LED_CPU_MIR = $0278

RUM_SMALL   = 12                ; a light shake (a rock cracking): a tap - CETAS's
                                ;   RUMBLE_SMALL
RUM_BIG     = 24                ; a full shake - a rock breaking, a hit taken: a
                                ;   solid thud, CETAS's RUMBLE_BIG
RUM_DEATH   = 40                ; a ship lost

RUMBLE      = $73C1             ; frames of shaking left, 0 = still
RUMHP       = $73C2             ; SHIPHP as of last frame...
RUMLV       = $73C3             ; ...and LIVES
RUMSH       = $73C4             ; ...and SHK_TIMER
        .assert RUMBLE > WINSAVE && RUMSH < $7400, error, "rumble.s: its bytes are not in the free stretch after window.s's WINSAVE"

        .segment "CODE8"

; frame_services - frame_body's one call (main.s): the pad, then the sound layer.
frame_services:
        jsr     rumble_tick
        jmp     sfx_tick                ; tail

; rumble_reset - a new game starts from rest. From game_start (gameover.s), which
; cart_init also calls, so nothing here is ever read before it has been written.
rumble_reset:
        stz     RUMBLE
        stz     RUMHP
        stz     RUMLV
        stz     RUMSH
        rts

; rumble_pulse - A = frames. Extends the running pulse, never shortens it.
rumble_pulse:
        cmp     RUMBLE
        bcc     @ret
        sta     RUMBLE
@ret:   rts

; rumble_tick - once a frame. Clobbers A, X.
rumble_tick:
        lda     LIVES                   ; a ship lost: LIVES fell
        cmp     RUMLV
        sta     RUMLV
        bcs     @hp
        lda     SHIPHP                  ; (SHIPHP jumps back to full on the same
        sta     RUMHP                   ;   frame - that is not a second event)
        lda     #RUM_DEATH
        jsr     rumble_pulse
        bra     @shake
@hp:    lda     RUMHP                   ; the hull lost something since last frame
        ldx     SHIPHP
        stx     RUMHP
        cmp     SHIPHP
        bcc     @shake                  ; RUMHP < SHIPHP: it GREW - a respawn or
        beq     @shake                  ;   a new game - no hit
        lda     #RUM_BIG
        jsr     rumble_pulse
@shake: lda     SHK_TIMER               ; the screen shake was (re)armed: its
        cmp     RUMSH                   ;   timer ROSE, which only shake_arm does
        sta     RUMSH
        bcc     @led
        beq     @led
        lda     SHK_SHIFT               ; smaller = louder, as in objects.s: a
        cmp     #2                      ;   break (1) is the full thud, a crack
        lda     #RUM_BIG                ;   (2) the light tap
        bcc     :+
        lda     #RUM_SMALL
:       jsr     rumble_pulse
@led:   lda     LED_CPU_MIR             ; the pad's bit on while a pulse runs
        and     #$3F                    ;   (LED0-LED5 are left as they are)
        ldx     RUMBLE
        beq     @w
        dec     RUMBLE
        ldx     JOYPORT
        bne     @p2
        ora     #$80                    ; port 1: LED7
        bra     @w
@p2:    ora     #$40                    ; port 2: LED6
@w:     sta     LED_CPU_MIR
        sta     LED_CPU_REG
        rts
