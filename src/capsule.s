; =============================================================================
; capsule.s - a lifeboat capsule ejects when the ship is lost
; =============================================================================
; PROTOTYPE HOOK, not a decided mechanic - nothing in design_technical.md or
; open_questions.md says what this is for yet. The art (tools/capsulegen.py,
; assets/png/capsule1-4.png) needed a way to be seen moving in madsim before
; anything is decided about what it MEANS, so today it is pure decoration: an
; ANTI-PICKUP. ship_die (ship.s) launches one on EVERY ship lost, not only the
; last - unlike the wreck (debris.s), which only comes apart when there is no
; ship left in hand - and it drifts off in a straight line and vanishes -
; nothing tracks it, nothing can reach it, nothing happens when it is gone.
;
; SCREEN-ANCHORED, exactly like the wreck: CAPXL/H, CAPYL/H are a signed 16-bit
; full-res offset from FLCXL/H, FLCYL/H (thrust.s emit_ship's drawn ship
; centre, shake folded in), not world units - so it costs no view_xform and
; needs no camera read. THE OFFSET STARTS AT -CAP_W/2, -CAP_HEIGHT/2, not
; zero: API_GPU_SPRITE places its top-left corner, and folding the sprite's own
; half-size into the position once, at spawn, means capsule_draw is a plain
; two-term 16-bit add - the same shape as thrust.s flame_place - rather than a
; third subtraction every frame.
;
; A CONSTANT VELOCITY, not eased or jittered: CAP_LIFE frames at CAP_VX/CAP_VY
; carries it well past the 400x300 screen (design_technical.md 2) before it
; expires, so nothing here has to test against the edge - the GPU sprite blit
; clips whatever coordinate it is handed, same as pickup.s's pk_draw.
;
; THE SPRITE HAS NO ANGLE. API_GPU_SPRITE is an axis-aligned blit, unlike the
; wreck's POLYGON16, so there is no tumble to give it; only the four drawn
; frames animate, CAP_HOLD game frames each. First cut held CAP_HOLD = 1 (one
; game frame a drawn frame, off the raw "1,2,3,4,1,2,3,4 over 8 frames" spec)
; and CAP_VX/CAP_VY = 3/-2 over CAP_LIFE = 100 - playtest read both as too
; fast; see the numbers below for where they landed instead.
; =============================================================================

CAP_SLOT0   = PK_SLOT0 + PK_FRAMES  ; the frames' slots, after the pickup's
CAP_PAGE    = $14                    ; GPU RAM page (pickup $13), and CAP_PAGES on
CAP_LIFE    = 220                    ; frames the capsule drifts before it
                                      ;   vanishes, ~3.6 s at 60.317 Hz. TUNE -
                                      ;   it only needs to outlast leaving the
                                      ;   screen, which CAP_VX/CAP_VY clear
                                      ;   with room to spare by ~t=200
CAP_VX      = 1                      ; constant drift, signed full-res screen
CAP_VY      = -1                     ;   px/frame (fb-x, fb-y). TUNE - slower
                                      ;   than the first cut's 3/-2 on request
CAP_HOLD    = 8                      ; game frames each animation frame is
                                      ;   held, a full 4-frame loop every 32
                                      ;   frames (~1.9 Hz). TUNE - the first
                                      ;   cut's CAP_HOLD = 1 read as a flicker,
                                      ;   6 (PK_HOLD's own pace) still too
                                      ;   quick

; --- state: $73B7-$73BD, behind levels.s's LVSAVE ($73B6) and ahead of
;     window.s's WINSAVE ($73C0) - hand-placed RAM, like pickup.s's block on
;     the same page; see that file's note on why and the collision it costs to
;     get wrong ---
CAPN        = $73B7             ; frames left in flight, 0 = no capsule in the
                                 ;   air - the one gate every routine below
                                 ;   tests
CAPANI      = $73B8             ; frames left on this animation frame
CAPPH       = $73B9             ; the animation's frame, 0 .. CAP_FRAMES-1
CAPXL       = $73BA             ; position: signed 16-bit full-res screen px,
CAPXH       = $73BB             ;   added straight onto FLCXL/H
CAPYL       = $73BC             ; ...and onto FLCYL/H
CAPYH       = $73BD
        .assert LVSAVE < CAPN && CAPYH < WINSAVE, error, "capsule.s: the block no longer fits between levels.s's LVSAVE and window.s's WINSAVE"

        .pushseg
        .segment "CODE6"                ; DEMO_RAM/FIELDRAM, beside emp.s and
                                         ;   base.s - the run area (CODE4,
                                         ;   pickup.s's own segment) is the
                                         ;   scarce one; this is a new
                                         ;   subsystem and DEMO_RAM is where
                                         ;   design_technical.md 11.19 says a
                                         ;   new one goes

; -----------------------------------------------------------------------------
; capsule_spawn - ship.s ship_die, every ship lost: launch one, right where
; the ship was.
; -----------------------------------------------------------------------------
capsule_spawn:
        lda     #CAP_LIFE
        sta     CAPN
        lda     #CAP_HOLD-1
        sta     CAPANI
        stz     CAPPH
        lda     #<(-(CAP_W/2))
        sta     CAPXL
        lda     #>(-(CAP_W/2))
        sta     CAPXH
        lda     #<(-(CAP_HEIGHT/2))
        sta     CAPYL
        lda     #>(-(CAP_HEIGHT/2))
        sta     CAPYH
        rts

; -----------------------------------------------------------------------------
; capsule_tick - gameover.s state_tick, once a frame: drift, animate, count
; down. Self-gated on CAPN, so it costs one compare a frame once the capsule
; is gone.
; -----------------------------------------------------------------------------
capsule_tick:
        lda     CAPN
        beq     @ret
        dec     CAPN

        clc
        lda     CAPXL
        adc     #<CAP_VX
        sta     CAPXL
        lda     CAPXH
        adc     #>CAP_VX
        sta     CAPXH

        clc
        lda     CAPYL
        adc     #<CAP_VY
        sta     CAPYL
        lda     CAPYH
        adc     #>CAP_VY
        sta     CAPYH

        dec     CAPANI
        bpl     @ret
        lda     #CAP_HOLD-1
        sta     CAPANI
        lda     CAPPH                    ; the next frame: 0, 1, ... and round
        inc     a                        ;   to 0 again
        cmp     #CAP_FRAMES
        bcc     @set
        lda     #$00
@set:   sta     CAPPH
@ret:   rts

; -----------------------------------------------------------------------------
; capsule_draw - main.s, after do_debris: one SPRITE command, while CAPN is
; nonzero. Clobbers A.
; -----------------------------------------------------------------------------
capsule_draw:
        lda     CAPN
        beq     @ret
        lda     CAPPH
        clc
        adc     #CAP_SLOT0
        sta     OS_ARG+0
        clc
        lda     FLCXL
        adc     CAPXL
        sta     OS_ARG+1
        lda     FLCXH
        adc     CAPXH
        sta     OS_ARG+2
        clc
        lda     FLCYL
        adc     CAPYL
        sta     OS_ARG+3
        lda     FLCYH
        adc     CAPYH
        sta     OS_ARG+4
        jmp     API_GPU_SPRITE          ; tail
@ret:   rts

        .segment "SPRART"               ; the art - GENERATED, tools/capsulegen.py -
        .align  256                     ;   is not RAM's: it sits in a ROM bank
        .include "capsule_art.s"        ;   and goes to the GPU in bulk at
        .align  256                     ;   power-on (sprites.s). CAP_PAGES pages.

        .popseg
