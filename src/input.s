; =============================================================================
; input.s - the joystick, and the only file that reads one
; =============================================================================
; One stick. Joystick 1 steers and throttles on HELD bits, teleports on
; FIRE2's edge, and boosts on a gesture read off its own throttle HELD bit -
; not a button at all. Nothing else in the program looks at JOY1/JOY2:
; everything downstream reads the state this leaves behind - the heading, the
; throttle position, the boost timer.
;
; The turn rate, its wind-up and how hard it follows speed are settled
; (design_technical 11.15-11.17) and are no longer bound to a control. The
; speed table itself is not settled - open_questions B1 - so the throttle is
; still the thing to fly.
; =============================================================================
; -----------------------------------------------------------------------------
; do_input — joystick 1 turns, throttles, boosts and teleports.
; -----------------------------------------------------------------------------
; Turning and the throttle are both HELD bits now - the turn-rate/ramp/speed-
; coupling knobs that used to live on edge bits here were debug controls for
; comparing settings back to back, and are gone now that the values are fixed.
; -----------------------------------------------------------------------------
do_input:
        ; ---- the stick, or nothing at all -----------------------------------
        ; While SHIPGONE there is no pilot: the three joystick bytes are
        ; republished as zero and EVERY reader in the program - the turn and
        ; throttle below, the boost gesture, the teleport, thrust.s's five
        ; nozzles and their puffs, shots.s's gun - reads the republished copy.
        ; One test here instead of a guard in each of them, and the one control
        ; that must still work with no ship (FIRE, to start a new game) is read
        ; by gameover.s straight off the hardware byte.
        lda     SHIPGONE
        bne     @dead
        lda     JOY1
        sta     JOYIN
        lda     JOY1_PRESS
        sta     JOYINP
        lda     JOY1_PREV
        sta     JOYINV
        bra     @stick
@dead:  stz     JOYIN
        stz     JOYINP
        stz     JOYINV
@stick:
        ldx     TURNIX                  ; this frame's rate, 8.8 brad per frame
        txa
        asl     a
        tax
        lda     TURN_RATE,x
        sta     RATEL
        lda     TURN_RATE+1,x
        sta     RATEH
        lda     TSCALE                  ; ...optionally scaled by flight speed:
        beq     @rate_ok                ;   rate * (1 + xtra/128). Turn radius is
        ldy     TIER                    ;   v/omega, so a constant omega lets the
        lda     TURN_XTRA,y             ;   radius grow in proportion to speed;
        beq     @rate_ok                ;   this pulls that back. The first cut
        sta     T0                      ;   doubled the rate at top speed and rose
        ldx     TSCALE                  ;   far too fast, so the dial now goes
        cpx     #3                      ;   OFF / x1.12 / x1.25 / x1.50 at the top
        beq     @xok                    ;   tier - three shifts of one table.
        lsr     T0
        cpx     #2
        beq     @xok
        lsr     T0
@xok:   lda     T0
        beq     @rate_ok
        sta     MB
        lda     RATEL
        sta     MAL
        lda     RATEH
        sta     MAH
        jsr     smul16q7
        clc
        lda     RATEL
        adc     MAL
        sta     RATEL
        lda     RATEH
        adc     MAH
        sta     RATEH
@rate_ok:
        ; ---- the turn has momentum ------------------------------------------
        ; The stick sets a TARGET angular velocity and the real one eases toward
        ; it, so a turn winds up and unwinds instead of switching on and off.
        ; RAMP 0 is an instant ease, i.e. the old on/off behaviour, kept so the
        ; two can be compared back to back.
        stz     T0                      ; T0/T1 = the target
        stz     T1
        lda     JOYIN
        and     #JOY_LEFT
        beq     :+
        sec
        lda     #$00
        sbc     RATEL
        sta     T0
        lda     #$00
        sbc     RATEH
        sta     T1
:       lda     JOYIN
        and     #JOY_RIGHT
        beq     :+
        lda     RATEL
        sta     T0
        lda     RATEH
        sta     T1
:       ldx     RAMPIX
        beq     @snap
        sec                             ; delta = target - current, into MA so the
        lda     T0                      ;   target stays in T0/T1
        sbc     TURNVL
        sta     MAL
        lda     T1
        sbc     TURNVH
        sta     MAH
        ldy     RAMPIX                  ; (ldx has no abs,x mode)
        lda     RAMP_SHIFT,y
        tax
@rsh:   lda     MAH
        cmp     #$80
        ror     MAH
        ror     MAL
        dex
        bne     @rsh
        lda     MAL                     ; An exponential ease never lands on its
        ora     MAH                     ;   target in integers: shifting a small
        bne     @rapply                 ;   delta right gives 0 one way and -1 the
@snap:  lda     T0                      ;   other, so the angular velocity sticks
        sta     TURNVL                  ;   at some tiny nonzero value and the
        lda     T1                      ;   heading creeps FOREVER - which fires a
        sta     TURNVH                  ;   full star rebuild every few dozen
        bra     @spin                   ;   frames and twitches the whole field.
@rapply:                                ;   When the step underflows, snap.
        clc
        lda     TURNVL
        adc     MAL
        sta     TURNVL
        lda     TURNVH
        adc     MAH
        sta     TURNVH
@spin:
        clc                             ; the heading carries a FRACTION, so the
        lda     HEADF                   ;   rate ladder can step finer than one
        adc     TURNVL                  ;   brad per frame. Only the integer part
        sta     HEADF                   ;   is used for cos/sin, and only a change
        lda     HEAD                    ;   in THAT rebuilds the starfield, so a
        adc     TURNVH                  ;   slow turn also rebuilds less often.
        sta     HEAD

        ; ---- throttle: continuous, not stepped -------------------------------
        ; JOY1 UP/DOWN are now HELD bits, not edge bits: holding UP accelerates
        ; smoothly from a standstill to the top tier and releasing holds
        ; whatever speed that reached, so getting to +350 no longer means
        ; clicking UP ten times. THRTLL/THRTLH is the position, 0..THRTL_MAX,
        ; and because THRTL_MAX is (TIER_N-1)*128 the old per-tier machinery
        ; falls out of it for free: TIER = position >> 7 (128 divides a byte
        ; evenly, so that is a shift, not a divide) and THFRAC, the low 7 bits,
        ; is a ready-made Q0.7 fraction for do_ship to lerp TIER_SPD with -
        ; the same smul16q7 the speed-coupled turn rate above already uses.
        ; THRTL_ACCEL is a first cut (TBM): full range in THRTL_MAX/THRTL_ACCEL
        ; frames, about 1.3 s at 60.317 Hz - the number to retune by flying it.
        lda     JOYIN
        and     #JOY_UP
        beq     :+
        clc
        lda     THRTLL
        adc     #THRTL_ACCEL
        sta     THRTLL
        lda     THRTLH
        adc     #$00
        sta     THRTLH
        cmp     #>THRTL_MAX
        bcc     @thok
        bne     @thclip
        lda     THRTLL
        cmp     #<THRTL_MAX
        beq     @thok
@thclip:
        lda     #<THRTL_MAX
        sta     THRTLL
        lda     #>THRTL_MAX
        sta     THRTLH
@thok:
:       lda     JOYIN
        and     #JOY_DOWN
        beq     :+
        sec
        lda     THRTLL
        sbc     #THRTL_ACCEL
        sta     THRTLL
        lda     THRTLH
        sbc     #$00
        sta     THRTLH
        bcs     :+
        stz     THRTLL
        stz     THRTLH
:       lda     SHIPGONE                ; ...and with nobody holding it, the
        beq     :+                      ;   throttle walks itself back to the
        jsr     throttle_rest           ;   resting tier - see that routine
:       lda     THRTLL                  ; TIER = THRTL >> 7: the top bit of the
        asl     a                       ;   low byte joins the high byte's *2.
        lda     THRTLH
        rol     a
        sta     TIER
        lda     THRTLL
        and     #$7F
        sta     THFRAC

        lda     JOYINP              ; FIRE2: TELEPORT
        and     #JOY_FIRE2
        beq     :+
        inc     TPGO
:       jmp     do_boost                ; tail call: the reselect-forward
                                        ;   gesture, in HIDATA below - its own
                                        ;   rts returns for do_input's own
                                        ;   caller

; -----------------------------------------------------------------------------
; What follows runs in HIDATA (cart.cfg): do_input's own once-a-frame, non-
; hot-per-object tenant, same reasoning as ship.s's cull_window/knb_tick -
; CODE+CODE2+RODATA share one 16 KB window that is full, while $A000 is barely
; touched.
; -----------------------------------------------------------------------------
        .segment "HIDATA"

; -----------------------------------------------------------------------------
; do_boost — BOOST is not a button, it is a RESELECT of forward. The player
; has to already be holding the top tier, let go, and choose forward again; a
; plain tap while cruising at max speed does nothing, because nothing armed
; it. BOOSTARM carries the "let go while on top" half of the gesture across
; frames; falling off the top tier (braking back down) disarms it, so the
; re-press has to land while still at full speed, not after coasting back up
; through the tiers to it.
; -----------------------------------------------------------------------------
do_boost:
        lda     JOYINV               ; forward held last frame...
        and     #JOY_UP
        beq     @boost_check            ;   ...wasn't - no release to arm on
        lda     JOYIN
        and     #JOY_UP
        bne     @boost_check            ;   ...and still is - not a release
        lda     TIER
        cmp     #TIER_N-1               ; only arms from the very top tier
        bne     @boost_check
        lda     #1
        sta     BOOSTARM
@boost_check:
        lda     TIER
        cmp     #TIER_N-1
        beq     @boost_fire
        stz     BOOSTARM                ; off the top tier: the gesture lapsed
@boost_fire:
        lda     JOYINP              ; forward, chosen again
        and     #JOY_UP
        beq     :+
        lda     BOOSTARM
        beq     :+
        stz     BOOSTARM
        lda     BOOSTN
        bne     :+                      ; already running - cannot stack
        lda     BOOST_AVAIL             ; unlimited for now (TBM: gate on a
        beq     :+                      ;   collected, limited charge count)
        lda     #BOOST_FRAMES
        sta     BOOSTN
        lda     #SE_BOOST               ; ...and the hiss under the whole of it.
        jsr     sfx_fire                ;   Here, on the one edge that starts a
                                        ;   boost, because se_boost's envelope
                                        ;   IS the boost's length - fire it once
                                        ;   and the two end together with
                                        ;   nothing watching either (sfx.s)
:       rts

; -----------------------------------------------------------------------------
; throttle_rest — the ship is gone: walk THRTL back to THRTL_REST, one
; THRTL_ACCEL a frame, and stop exactly on it.
; -----------------------------------------------------------------------------
; ONE STEP A FRAME AND NOT A SNAP, and that is the whole point of the routine.
; Everything the camera does hangs off this one number - the speed, the screen
; slide (SHOFF), the zoom rung - so setting it to rest on the frame the ship
; dies would stop the whole world dead in one frame, which reads as the game
; crashing rather than as the ship dying. Stepped at the same rate the player's
; own thumb would have moved it, the field coasts to a halt and the zoom eases
; out to 1:1 underneath the wreck, in about the time the wreck takes to go.
;
; The ease itself is not here and never was: ZEAS follows ZOOM and SHOFF
; follows its own target every frame (ship.s), whatever moved them. This only
; has to move the input they are all watching.
;
; The step cannot underflow: THRTL_REST is 384, so the only path that
; subtracts is one where THRTL is already above it by more than THRTL_ACCEL.
; -----------------------------------------------------------------------------
throttle_rest:
        jsr     thr_cmp_rest
        beq     @done                   ; already there
        bcs     @down
        clc                             ; below rest: come UP to it
        lda     THRTLL
        adc     #THRTL_ACCEL
        sta     THRTLL
        bcc     :+
        inc     THRTLH
:       jsr     thr_cmp_rest
        bcc     @done                   ; still short - next frame
        bra     @snap                   ; reached or overshot: land on it
@down:  sec                             ; above rest: come DOWN to it
        lda     THRTLL
        sbc     #THRTL_ACCEL
        sta     THRTLL
        bcs     :+
        dec     THRTLH
:       jsr     thr_cmp_rest
        bcs     @done                   ; still above - next frame
@snap:  lda     #<THRTL_REST
        sta     THRTLL
        lda     #>THRTL_REST
        sta     THRTLH
@done:  rts

; C SET = THRTL >= THRTL_REST, Z SET = exactly on it. An unsigned 16-bit
; compare, which is what THRTL is: 0..THRTL_MAX.
thr_cmp_rest:
        lda     THRTLH
        cmp     #>THRTL_REST
        bne     @ne
        lda     THRTLL
        cmp     #<THRTL_REST
@ne:    rts

        .segment "CODE"                 ; back to bank 0 for the rest of this file
