; =============================================================================
; shield.s - the shield: a dotted circle round the hull, a quarter of every hit
; =============================================================================
; open_questions F6. No pickup yet: shield_on is the door the pickup will use,
; and for now only the TRAINER opens it (trainer.s, the second pad's DOWN).
;
; WHAT IT DOES. For SHLD_FRAMES (30 s) every cost to the hull is divided by 4,
; ON TOP of what the Saturnium armour already took off (satn.s satn_armour):
; physics.s ship_hurt calls shield_armour straight after it. The quarter is
; worked with its remainder carried to the next hit (SHARM), the armour's own
; trick, so the pulsar's beam at 1 a frame costs 1 frame in 4 rather than 0. It
; changes what the hull PAYS, nothing else - a ram still bounces and klangs.
;
; WHAT IT LOOKS LIKE. One DOT_CIRCLE ($FF27) about the hull's pivot, FLCX/FLCY
; halved. (Centring it on the middle of SHIP_SHAPE's -22..+10 instead was tried
; and judged worse in flight: the pivot is where the hull's mass reads.) What is
; left is the half-res lattice: DOT_CIRCLE's centre is a half-res pixel, so on a
; frame the pivot lands on an odd full-res one the circle is a pixel off it,
; sideways or along - inherent to the opcode, and it moves with the ship and
; the shake. SHLD_R half-res px at 1:1 and SCALED WITH THE ZOOM like
; the hull itself - qmul by ZOOMH, the laser's way of putting a radius on the
; screen - so it shrinks smoothly as the camera pulls out, as finely as a
; half-res radius can: 15 at 1:1 down to 8 at the 2x zoom-out. Steady, and for
; its last SHLD_WARN frames (4 s) it blinks, SHLD_BLINK frames on and off.
;
; WHAT IT SAYS. SHIELD ENABLED when it goes up, SHIELD WEARS OFF when the blink
; starts - both queued on the message bar like any report (hud_game.s).
;
; A SHIP LOST TAKES IT WITH IT: while SHIPGONE or SHIPINV (the respawn blink) the
; shield is simply dropped - so shield_on during a respawn blink does nothing.
;
; WHERE IT LIVES. CODE2 (bank 1, run from the run area): CART_HIRAM is kept for
; the next enemies' code and UPPER is full. Its state is under the window behind
; the EMP's, so it is only touched inside cart_frame's bracket - do_shield,
; ship_hurt and the trainer all are.
; =============================================================================

; --- tunables - open_questions F6 --------------------------------------------
SHLD_FRAMES = 1810              ; 30 s at 60.317 Hz
SHLD_WARN   = 241               ; ...the last 4 s of it blink
SHLD_BLINK  = 8                 ; frames on, then off, while it blinks
SHLD_R      = 15                ; half-res px at 1:1 (30 full-res; the nose
                                ;   is 22 out)
                                ;   - times ZOOMH/128 on the screen

        .assert SHLD_R <= 127, error, "shield.s: qmul takes magnitudes up to 127"
        .assert SHLD_WARN < 256 && SHLD_FRAMES > SHLD_WARN, error, "shield.s: do_shield tests the warning on the low byte alone"

; --- state: under the window, behind emp.s -------------------------------------
SHLDL       = EMP_END           ; frames of shield left, 0 = down
SHLDH       = EMP_END + 1
SHARM       = EMP_END + 2       ; the quarters of a hit point carried
SHLD_END    = EMP_END + 3
        .assert SHLD_END <= $A000, error, "shield.s: past the RAM under the window"

        .pushseg
        .segment "CODE2"

; -----------------------------------------------------------------------------
; shield_on - raise it, for the whole SHLD_FRAMES again if it is already up.
; The pickup's door; for now the trainer's. Clobbers A and X.
; -----------------------------------------------------------------------------
shield_on:
        lda     #<SHLD_FRAMES
        sta     SHLDL
        lda     #>SHLD_FRAMES
        sta     SHLDH
        stz     SHARM
        lda     #IM_SHIELD_ON
        jmp     indicate_msg            ; tail

; -----------------------------------------------------------------------------
; shield_reset - game_start (through laser.s lsr_reset): no shield.
; -----------------------------------------------------------------------------
shield_reset:
        stz     SHLDL
        stz     SHLDH
        rts

; -----------------------------------------------------------------------------
; shield_armour - physics.s ship_hurt, after satn_armour: A = a hit's cost ->
; what the hull pays with the shield up, (cost + carried) / 4. Unchanged with it
; down. Preserves X and Y.
; -----------------------------------------------------------------------------
shield_armour:
        pha
        lda     SHLDL
        ora     SHLDH
        beq     @down
        pla
        clc                             ; cost <= 31 and SHARM <= 3: a byte
        adc     SHARM
        pha
        and     #$03                    ; what does not make a whole point is
        sta     SHARM                   ;   carried
        pla
        lsr     a
        lsr     a
        rts
@down:  pla
        rts

; -----------------------------------------------------------------------------
; do_shield - once a frame, after do_emp (FLCX/FLCY are this frame's), inside
; the bracket: count it down, say when it starts to go, and draw it.
; -----------------------------------------------------------------------------
do_shield:
        lda     SHLDL
        ora     SHLDH
        beq     @done
        lda     SHIPGONE                ; no ship, or one just lost: no shield
        ora     SHIPINV
        beq     :+
        jmp     shield_reset            ; tail
:       lda     SHLDL                   ; one frame less
        bne     :+
        dec     SHLDH
:       dec     SHLDL
        lda     SHLDH
        bne     @draw                   ; 256 or more left: steady
        lda     SHLDL
        beq     @done                   ; ...none: it is down
        cmp     #SHLD_WARN
        beq     @warn
        bcs     @draw                   ; above the warning: steady
        lda     FRAME                   ; ...in it: blinking
        and     #SHLD_BLINK
        bne     @done
        bra     @draw
@warn:  lda     #IM_SHIELD_OFF
        jsr     indicate_msg
@draw:  jsr     ship_hidden             ; no hull drawn, no circle round it
        bcs     @done
        lda     FLCXH                   ; the drawn centre, half-res: on the
        lsr     a                       ;   screen, so a byte each
        lda     FLCXL
        ror     a
        sta     OS_ARG+0
        lda     FLCYH
        lsr     a
        lda     FLCYL
        ror     a
        sta     OS_ARG+1
        lda     #SHLD_R                 ; ...scaled with the zoom, as the hull is
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul
        sta     OS_ARG+2
        jmp     API_GPU_DOTCIRCLE       ; tail
@done:  rts

IM_SHIELD_ON_S:  .byte  "SHIELD ENABLED", 0
IM_SHIELD_OFF_S: .byte  "SHIELD WEARS OFF", 0

        .popseg
