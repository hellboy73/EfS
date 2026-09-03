; =============================================================================
; input.s - the joystick, and the only file that reads one
; =============================================================================
; Two sticks. Joystick 1 steers and throttles on HELD bits; joystick 2 boosts
; and teleports on EDGE bits, because both are one-shot. Nothing else in the
; program looks at JOY1/JOY2: everything downstream reads the state this leaves
; behind - the heading, the throttle position, the boost timer.
;
; The turn rate, its wind-up and how hard it follows speed are settled
; (design_technical 11.15-11.17) and are no longer bound to a control. The
; speed table itself is not settled - open_questions B1 - so the throttle is
; still the thing to fly.
; =============================================================================
; -----------------------------------------------------------------------------
; do_input — joystick 1 turns and throttles; joystick 2 boosts and teleports.
; -----------------------------------------------------------------------------
; Turning and the throttle are both HELD bits now - the turn-rate/ramp/speed-
; coupling knobs that used to live on edge bits here were debug controls for
; comparing settings back to back, and are gone now that the values are fixed.
; -----------------------------------------------------------------------------
do_input:
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
        lda     JOY1
        and     #JOY_LEFT
        beq     :+
        sec
        lda     #$00
        sbc     RATEL
        sta     T0
        lda     #$00
        sbc     RATEH
        sta     T1
:       lda     JOY1
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
        lda     JOY1
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
:       lda     JOY1
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
:       lda     THRTLL                  ; TIER = THRTL >> 7: the top bit of the
        asl     a                       ;   low byte joins the high byte's *2.
        lda     THRTLH
        rol     a
        sta     TIER
        lda     THRTLL
        and     #$7F
        sta     THFRAC

        lda     JOY2_PRESS              ; joystick 2 UP: BOOST. Only from the top
        and     #JOY_UP                 ;   tier, and not while one is running -
        beq     :+                      ;   so it cannot be stacked or held
        lda     BOOSTN
        bne     :+
        lda     TIER
        cmp     #TIER_N-1
        bne     :+
        lda     #BOOST_FRAMES
        sta     BOOSTN
:       lda     JOY2_PRESS              ; joystick 2 DOWN: TELEPORT
        and     #JOY_DOWN
        beq     :+
        inc     TPGO
:       rts
