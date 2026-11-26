; =============================================================================
; trainer.s - TEMPORARY cheats for testing, all behind main.s's TRAINER flag
; =============================================================================
; TRAINER = 0 in main.s takes every byte of this out of the image, the call in
; cart_frame included. It is meant to grow while the game is being tuned and to
; be switched off before it ships.
;
; THE SECOND PAD drives it - the one the game is NOT being played on (JOYPORT,
; screens.s), so a game started from port 1 has its trainer on port 2 and one
; started from port 2 on port 1, and the stick being flown never triggers it.
;
;   UP      the hold fills: SATN = SATN_MAX (satn.s) - held
;   DOWN    the shield goes up for its 30 s (shield.s shield_on) - on the press
;   RIGHT   the exit gate opens, mission or not (gate.s gate_open) - on the press
;   LEFT    the laser arrives, exactly as a pickup would (pk_arrive) - on the press
;   FIRE    the EMP arrives, exactly as a pickup would (pk_arrive) - on the press,
;           so EMP ACQUIRED is spoken and the hold comes full with it
;
; Runs from cart_frame after do_input, inside the bracket: SATN lives under the
; window.
; =============================================================================

.if TRAINER

        .pushseg
        .segment "CODE6"

trainer_tick:
        lda     #JOY2-JOY1              ; the other port's offset from JOY1
        sec
        sbc     JOYPORT
        tax
        lda     JOY1,x
        and     #JOY_UP
        beq     :+
        lda     #SATN_MAX               ; UP: a full hold
        sta     SATN
:       lda     JOY1_PRESS,x
        and     #JOY_RIGHT
        beq     :+
        phx
        jsr     gate_open               ; RIGHT: the exit gate
        plx
:       lda     JOY1_PRESS,x
        and     #JOY_LEFT
        beq     :+
        phx
        lda     #SPT_LASER              ; LEFT: the laser, through the REAL arrival
        jsr     pk_arrive               ;   too - so it is announced, and spoken,
        plx                             ;   exactly as a picked-up one is
:       lda     JOY1_PRESS,x
        and     #JOY_FIRE
        beq     :+
        phx
        lda     #SPT_EMP                ; FIRE: the EMP, through the REAL arrival -
        jsr     pk_arrive               ;   the whoosh, the flag, the full hold and
        plx                             ;   EMP ACQUIRED, none of it duplicated here
:       lda     JOY1_PRESS,x
        and     #JOY_DOWN
        beq     @done
        jmp     shield_on               ; DOWN: the shield (tail)
@done:  rts

        .popseg

.endif
