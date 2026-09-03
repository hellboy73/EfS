; =============================================================================
; ship.s - the player's own motion, and the outline that draws it
; =============================================================================
; The ship is the one object that is not in the field: it has no slot, no
; sector-grid cell and no collision pass of its own (physics.s tests rocks
; against it separately). What it has is a velocity taken from the throttle and
; the heading, an integration into the world, and the two things that ride the
; throttle with it - the slide down the screen and the zoom out - both eased
; toward their target rather than snapped to it.
;
; It is drawn as an authored 14-vertex outline through the same GPU polygon
; call a rock uses, at angle 0 because it never spins: design_technical 11.14.
; The 32x32 sprite it used to be is still here behind SHIP_SPRITE, along with
; the LOAD-page upload that installs it, because that path is also how any
; future sprite gets into GPU RAM.
; =============================================================================
.if SHIP_SPRITE
; -----------------------------------------------------------------------------
; upload_step — install the ship sprite, ONE LOAD page per frame for five frames.
; -----------------------------------------------------------------------------
; LOAD is the only way CPU1 can write GPU RAM, and it writes a whole 256-byte
; page at a time — including the sprite definition table, which is four pages of
; one parameter each ($03 type, $04 ptr lo, $05 ptr hi, $06 height). So each of
; the four is staged blank in DEFPG, patched with the two slots this cartridge
; uses, and shipped. Slot 0 keeps the ROM test sprite's own numbers, which costs
; nothing and means an id typo still draws something.
;
; ONE PAGE A FRAME because five is too many at once: a LOAD is 258 bytes of the
; 2047-byte list and about 10,000 cycles of copying, and all five on the first
; frame put that frame at 98% of budget for no reason. Spread out it is 5% a
; frame, and the ship appears on frame 5 — 83 ms, which nobody sees. It still
; goes FIRST in whichever frame it lands on: a def page dropped for want of
; PPRAM would leave the slot empty for the rest of the session.
; -----------------------------------------------------------------------------
upload_step:
        ldx     SPRSTEP
        inc     SPRSTEP
        txa                             ; the OLD step, not the incremented one
        bne     @def
        lda     #SHIP_PAGE              ; step 0: the art itself
        sta     OS_ARG+0
        lda     #<ship32_data
        sta     OS_ARG+1
        lda     #>ship32_data
        sta     OS_ARG+2
        jmp     API_GPU_LOAD
@def:   dex                             ; steps 1-4: definition page X-1
        lda     #$00                    ; a blank page...
        ldy     #$00
:       sta     DEFPG,y
        iny
        bne     :-
        txa                             ; ...with the two live slots patched in
        asl     a
        tay
        lda     SPRDEF,y
        sta     DEFPG+0
        lda     SPRDEF+1,y
        sta     DEFPG+SPR_SHIP
        txa
        clc
        adc     #$03                    ; GPU pages $03 / $04 / $05 / $06
        sta     OS_ARG+0
        lda     #<DEFPG
        sta     OS_ARG+1
        lda     #>DEFPG
        sta     OS_ARG+2
        jmp     API_GPU_LOAD

.endif

; -----------------------------------------------------------------------------
; do_ship — velocity from the speed tier and the heading, then integrate.
; -----------------------------------------------------------------------------
; forward = (sin H, -cos H), so vel = speed * that. Velocity is signed 8.8 world
; units per frame and the position carries a fraction byte; that is what makes
; the slowest tier a smooth drift rather than a stutter — the finest motion this
; can express is 1/4096 of a pixel per frame.
; -----------------------------------------------------------------------------
do_ship:
        ; The boost is a TIER the player cannot select. It runs out on its own,
        ; and while it does, every table this frame reads is indexed by ETIER
        ; instead of TIER - which is how it changes the speed without changing
        ; the zoom or the ship's place on screen: those two rows of ZOOM_RZ and
        ; SHIP_OFF are copies of the top tier's.
        lda     TIER
        ldx     BOOSTN
        beq     :+
        dec     BOOSTN
        lda     #TIER_BOOST
:       sta     ETIER

        ; SPD used to be a plain TIER_SPD[ETIER] lookup - one of eleven round
        ; numbers, snapped to on the frame a tier changed. The throttle is
        ; continuous now (do_input's THRTLL), so SPD lerps between TIER_SPD[TIER]
        ; and TIER_SPD[TIER+1] by THFRAC instead, and only boosting still forces
        ; the flat lookup: TIER_BOOST's row duplicates the top tier's, which is
        ; how it changes vel_shl's multiplier without moving SPD, ZOOM or SHOFF -
        ; and THFRAC is always 0 at TIER 10 anyway, so the two paths agree there.
        lda     ETIER
        cmp     #TIER_BOOST
        bne     @spd_interp
        asl     a
        tax
        lda     TIER_SPD,x
        sta     SPDL
        lda     TIER_SPD+1,x
        sta     SPDH
        bra     @spd_done
@spd_interp:
        lda     TIER
        asl     a
        tax
        sec
        lda     TIER_SPD+2,x
        sbc     TIER_SPD,x
        sta     MAL
        lda     TIER_SPD+3,x
        sbc     TIER_SPD+1,x
        sta     MAH
        lda     THFRAC
        sta     MB
        jsr     smul16q7                ; clobbers X, so TIER (a plain zero-page
        lda     TIER                    ;   byte) is re-read below rather than
        asl     a                       ;   stashed across the call
        tax
        clc
        lda     MAL
        adc     TIER_SPD,x
        sta     SPDL
        lda     MAH
        adc     TIER_SPD+1,x
        sta     SPDH
@spd_done:
        lda     SPDL                    ; VELX = speed * sin. Speed is already
        sta     MAL                     ;   8.8, so the Q0.7 multiply lands in
        lda     SPDH                    ;   8.8 too and the old byte-wide
        sta     MAH                     ;   smul_vel is gone.
        lda     SINV
        sta     MB
        jsr     smul16q7
        jsr     vel_shl                 ; ...then the tier's speed multiplier
        lda     MAL
        sta     VELXL
        lda     MAH
        sta     VELXH
        lda     MAT
        sta     VELXT

        lda     SPDL                    ; VELY = -(speed * cos)
        sta     MAL
        lda     SPDH
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        jsr     vel_shl
        sec
        lda     #$00
        sbc     MAL
        sta     VELYL
        lda     #$00
        sbc     MAH
        sta     VELYH
        lda     #$00
        sbc     MAT
        sta     VELYT

        ; The ship slides down the screen as it speeds up, and above centre in
        ; reverse, so the player is always looking at where they are going. It
        ; EASES toward the tier's target instead of snapping: a jump on every
        ; tier change would be unreadable, and this shift is the camera-lag
        ; constant the design still has to settle (open question B3).
        ; The GAP is 24-bit, and it has to be. Target and offset are each a
        ; signed byte of pixels, so their difference reaches 255 px - which in
        ; 8.8 is 65280 and is not a positive signed 16. Between adjacent tiers
        ; the gap never exceeded 127 px and this never showed; the teleport opens
        ; a 246 px gap in one frame, the subtract wrapped, and the ease walked
        ; the ship AWAY from its target. SHOFF itself stays 8.8 - only the gap
        ; needed the third byte.
        ldx     ETIER
        stz     T0
        lda     SHIP_OFF,x
        sta     T1
        ldy     #$00
        bpl     :+
:       bit     T1
        bpl     :+
        ldy     #$FF
:       sty     SHOFT
        ldy     #$00
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       sty     SHOFC
        sec
        lda     T0
        sbc     SHOFFL
        sta     T0
        lda     T1
        sbc     SHOFFH
        sta     T1
        lda     SHOFT
        sbc     SHOFC
        sta     SHOFT
        ldx     #SHOFF_LAG
:       lda     SHOFT
        cmp     #$80
        ror     SHOFT
        ror     T1
        ror     T0
        dex
        bne     :-
        clc                             ; the sum converges into range, so the
        lda     SHOFFL                  ;   top byte is not carried back
        adc     T0
        sta     SHOFFL
        lda     SHOFFH
        adc     T1
        sta     SHOFFH

        ; ---- and the zoom, on the same curve, because it is the same gesture --
        ; ...and the cross-axis lean, on the same shape of ease. TURNV is signed
        ; 8.8, so shifting it up 3 and taking a Q0.7 product lands the target in
        ; 8.8 full-res pixels directly.
        lda     TURNVL                  ; CLAMP FIRST. The shift below is 5, and
        sta     MAL                     ;   the speed coupling can push the turn
        lda     TURNVH                  ;   rate to 4.5 brad a frame - 1152 in
        sta     MAH                     ;   8.8, which shifted 5 is 36864 and no
        bpl     @cxpos                  ;   longer a positive signed 16. The lean
        lda     MAH                     ;   saturates at CAMX_CLAMP instead, which
        cmp     #>-CAMX_CLAMP           ;   is the right behaviour anyway: past
        bne     :+                      ;   three brad a frame it is already as
        lda     MAL                     ;   far over as it is ever going to lean.
        cmp     #<-CAMX_CLAMP
:       bcs     @cxok
        lda     #<-CAMX_CLAMP
        sta     MAL
        lda     #>-CAMX_CLAMP
        sta     MAH
        bra     @cxok
@cxpos: lda     MAH
        cmp     #>CAMX_CLAMP
        bne     :+
        lda     MAL
        cmp     #<CAMX_CLAMP
:       bcc     @cxok
        lda     #<CAMX_CLAMP
        sta     MAL
        lda     #>CAMX_CLAMP
        sta     MAH
@cxok:  asl     MAL
        rol     MAH
        asl     MAL
        rol     MAH
        asl     MAL
        rol     MAH
        asl     MAL
        rol     MAH
        asl     MAL
        rol     MAH
        ldx     ETIER                   ; the gain is per TIER, not a constant:
        lda     CAMX_TIER,x             ;   the effect is meant to read as the
        sta     MB                      ;   camera failing to keep up with a ship
        jsr     smul16q7                ;   that is MOVING, and at a standstill
                                        ;   a camera that swings on a pivot the
                                        ;   ship is sitting still on has nothing
                                        ;   to fail to keep up with. Zero there.
        sec
        lda     MAL
        sbc     SHOFXL
        sta     T0
        lda     MAH
        sbc     SHOFXH
        sta     T1
        ldx     #CAMX_LAG
:       lda     T1
        cmp     #$80
        ror     T1
        ror     T0
        dex
        bne     :-
        clc
        lda     SHOFXL
        adc     T0
        sta     SHOFXL
        lda     SHOFXH
        adc     T1
        sta     SHOFXH
        lda     SHOFXH                  ; the half-res cross centre the ship and
        cmp     #$80                    ;   its occluder box are drawn about
        ror     a
        clc
        adc     #HCY
        sta     SHCY
        lda     SHOFXH                  ; ...and the lean in ZOOM_MA's own scale,
        sta     T1                      ;   which is pixels * 16. SHOFX is 8.8
        lda     SHOFXL                  ;   px, so that is simply >> 4 - and it
        sta     T0                      ;   is folded into the value BEFORE
        ldx     #4                      ;   asr4r rounds, not added as a whole
:       lda     T1                      ;   pixel after it. Adding it after made
        cmp     #$80                    ;   the entire world step 1 px at a time
        ror     T1                      ;   as the lean decayed, and preview.py
        ror     T0                      ;   counted that as objects swimming.
        dex                             ;   Finding 15's rule, on a third axis:
        bne     :-                      ;   register sub-unit, floor once.
        lda     T0
        sta     SHOFXQ
        lda     T1
        sta     SHOFXQ+1

        ; The camera pulls back as the ship slides down: both exist so the player
        ; is looking at where they are going, so they must move together or the
        ; two halves of it read as two events.
        ldx     ETIER
        lda     ZOOM_RZ,x
        sta     T1
        stz     T0
        sec
        lda     T0
        sbc     ZEASL
        sta     T0
        lda     T1
        sbc     ZEASH
        sta     T1
        ldx     #SHOFF_LAG
:       lda     T1
        cmp     #$80
        ror     T1
        ror     T0
        dex
        bne     :-
        lda     T0                      ; finding 13's trap, and it bites harder
        ora     T1                      ;   here: an ease that never lands would
        bne     @zstep                  ;   leave the reciprocal creeping, and
        ldx     ETIER                   ;   every creep rebuilds a 512-byte table
        lda     ZOOM_RZ,x
        sta     ZEASH
        stz     ZEASL
        bra     @zdone
@zstep: clc
        lda     ZEASL
        adc     T0
        sta     ZEASL
        lda     ZEASH
        adc     T1
        sta     ZEASH
@zdone:
        ; QUANTISE. The ease is continuous, but everything downstream reads the
        ; SNAPPED reciprocal: nothing outside this line ever sees ZEASH.
        ldx     ZEASH
        lda     ZQ_SNAP-64,x
        sta     ZOOMH
        ; The cull window follows the zoom: pulling back widens the visible
        ; world, so a rock that was out of range comes into it.
        lda     ZOOMH
        lsr     a
        lsr     a
        lsr     a
        sec
        sbc     #$08                    ; RZ 64..128 -> 0..8
        tax
        lda     ZOOM_CULLH,x
        sta     CULHI
        txa
        asl     a
        tax
        lda     ZOOM_CULLR,x
        sta     CULRL
        asl     a
        sta     CUL2L
        lda     ZOOM_CULLR+1,x
        sta     CULRH
        rol     a
        sta     CUL2H
        inc     CUL2L                   ; 2*CULR + 1, the exclusive upper bound
        bne     :+
        inc     CUL2H
:
        ; The scale table, rebuilt only when the reciprocal's integer part moved.
        ; ~10k cycles, so it must not run on a frame where nothing changed - and
        ; must run BEFORE do_objects, which is the next thing the frame does.
        lda     ZOOMH
        cmp     ZSHEAD
        beq     :+                      ; (an anonymous label, not a cheap one:
        sta     ZSHEAD                  ;  BUILD_ROT's .local symbols end the
        BUILD_ROT ZSI, ZSF, ZOOMH, #$00 ;  @-scope this sits in)
:

        clc                             ; position += velocity, 16.8 + 16.8.
        lda     SHXF                    ;   The velocity carries its own top byte
        adc     VELXL                   ;   now, so the two sign extensions this
        sta     SHXF                    ;   used to build are gone and the add is
        lda     SHXL                    ;   a plain 24-bit one.
        adc     VELXH
        sta     SHXL
        lda     SHXH
        adc     VELXT
        sta     SHXH
        clc
        lda     SHYF
        adc     VELYL
        sta     SHYF
        lda     SHYL
        adc     VELYH
        sta     SHYL
        lda     SHYH
        adc     VELYT
        sta     SHYH

        lda     TPGO                    ; ...and only then, the teleport: it must
        beq     :+                      ;   land on THIS frame's position
        stz     TPGO
        jsr     do_teleport
:       rts

; -----------------------------------------------------------------------------
; do_teleport — jump a fixed screen distance and leave the camera behind.
; -----------------------------------------------------------------------------
; Move the ship in the world, drop SHOFF by the same screen distance, and the
; camera point does not move: the ship simply appears further up the screen and
; SHOFF_LAG walks the camera back, fast at first and slower as it closes.
;
; PSHOFF is dragged with it because do_stars folds (SHOFF - PSHOFF) into the
; scroll - that term exists so the field does not twitch while the offset eases
; between tiers - and a 246 px step there would sweep the whole field sideways.
;
; The rebase is NOT belt and braces. The star camera point is SHOFF scaled into
; LAYER units (shl6) and the motes' into their own (shl3), not world units, so
; the ship's world displacement and the SHOFF drop do not cancel analytically the
; way they do for the world objects. star_rebase_full recomputes every base from
; whatever the camera point now is, so the question never has to be answered -
; and if the field does jump one frame, you did just teleport.
; -----------------------------------------------------------------------------
do_teleport:
        inc     TPCNT
        lda     #<-TP_OFF               ; forward: land near the LEADING edge
        ldx     TIER
        cpx     #TIER_ZERO
        bcs     :+
        lda     #TP_OFF                 ; reversing: mirror it, and the jump
:       sta     TPDST                   ;   below comes out negative by itself

        ; M = SHOFF - landing, full-res px, positive meaning "forward along the
        ; heading". BOTH operands are sign-extended first, because the difference
        ; reaches 246 px and does not fit the byte either of them lives in. The
        ; first cut wrote `sbc TPDST / ldy #$00 / bpl` - and LDY sets the flags,
        ; so the branch tested the zero it had just loaded rather than the
        ; subtraction. The top byte came out $00 every time, which is right by
        ; luck going forward and turns the backward jump into a forward one.
        ldy     #$00
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       sty     TPMH
        ldy     #$00
        bit     TPDST
        bpl     :+
        ldy     #$FF
:       sty     TPSGN
        sec
        lda     SHOFFH
        sbc     TPDST
        sta     TPML
        lda     TPMH
        sbc     TPSGN
        sta     TPMH

        asl     TPML                    ; screen px -> world units at 1:1 is x16
        rol     TPMH
        asl     TPML
        rol     TPMH
        asl     TPML
        rol     TPMH
        asl     TPML
        rol     TPMH

        lda     TPML                    ; ...and x(128/RZ) on top, because the
        sta     MAL                     ;   distance is authored on the SCREEN:
        lda     TPMH                    ;   at 2x out the same screen span is
        sta     MAH                     ;   twice as much world. TPQ holds
        ldx     ZOOMH                   ;   128/RZ - 1 in Q0.7, so this is one
        lda     TPQ-64,x                ;   product and one add.
        sta     MB
        jsr     smul16q7
        clc
        lda     TPML
        adc     MAL
        sta     TPML
        lda     TPMH
        adc     MAH
        sta     TPMH

        lda     TPML                    ; SHX += M * sin
        sta     MAL
        lda     TPMH
        sta     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        ldy     #$00
        bit     MAH
        bpl     :+
        dey
:       clc
        lda     SHXL
        adc     MAL
        sta     SHXL
        lda     SHXH
        adc     MAH
        sta     SHXH

        lda     TPML                    ; SHY -= M * cos
        sta     MAL
        lda     TPMH
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        sec
        lda     SHYL
        sbc     MAL
        sta     SHYL
        lda     SHYH
        sbc     MAH
        sta     SHYH

        lda     TPDST                   ; the camera stays where it was...
        sta     SHOFFH
        stz     SHOFFL
        sta     PSHOFFH                 ; ...and the scroll must not see the step
        stz     PSHOFFL
        lda     HEAD                    ; force a full rebase of the star bases
        eor     #$80
        sta     BASEHEAD
        rts

; -----------------------------------------------------------------------------
; vel_shl — MA (signed 16) -> MA/MAT (signed 24), shifted by this tier's TIER_SHL.
; -----------------------------------------------------------------------------
; The ship's speed is authored in TIER_SPD as signed 8.8 world units a frame, and
; that type stops at 127.996 units - 482.5 px/s. A boost that only reaches 482
; against a normal top of 350 is a 37% difference and does not read as a boost at
; all, which is what flying it said.
;
; Rather than widen SPD - which would mean a 24-bit operand for smul16q7, twice a
; frame, and a three-byte TIER_SPD - the multiplier lives here, AFTER the
; direction product. TIER_SHL says how many times to double this tier's velocity,
; so an authored 350 with a shift of 1 flies at 700 px/s and the arithmetic that
; produced it never left 16 bits. The ceiling is 964 px/s at shift 1; the cull
; allows 1157 (the gap at RZ 64 is 320 units and a rock adds 13).
; -----------------------------------------------------------------------------
vel_shl:
        ldy     #$00                    ; sign-extend the product into 24 bits
        bit     MAH
        bpl     :+
        ldy     #$FF
:       sty     MAT
        ldx     ETIER
        lda     TIER_SHL,x
        beq     @done
        tax
:       asl     MAL
        rol     MAH
        rol     MAT
        dex
        bne     :-
@done:  rts

; -----------------------------------------------------------------------------
; emit_ship — an authored N-vertex outline, nose up, riding the speed tier up
; and down.
; -----------------------------------------------------------------------------
; SOLID, N full-res LINE16 segments. The rocks are dot-lines because a dotted
; rim is what reads as rock and there are a dozen of them; the ship is one
; object and wants to be the solid thing in the frame, which is also what it
; looked like as a sprite.
;
; FULL RESOLUTION, and the reason is motion, not sharpness. $42 takes half-res
; endpoints and doubles them, so a line that drifts or turns slowly lands on
; the same two even pixels for several frames and then jumps 2 px - which on
; the one object the player watches the whole time reads as the ship stepping
; rather than moving. $43 takes the endpoints on the 400x300 grid and draws
; them with the same renderer: identical still picture, four times the
; distinct positions in motion.
;
; No clipping is needed and none is available: the coordinates are computed
; from the centre, and nothing validates them. The ship is safe because it
; never leaves the middle of the screen and shapes.s's vertices are small.
;
; TATE: "up" on the player's screen is DECREASING fb_x. That is the same
; rotation sprgen bakes into the artwork with --tate; here it is just how the
; shape is authored - shapes.s's header says which axis is which.
; -----------------------------------------------------------------------------
emit_ship:
.if SHIP_SPRITE
        lda     #SPR_SHIP
        sta     OS_ARG+0
        ldy     #$00                    ; fb_x = FBCX + offset - 16
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFFH
        adc     #<SHIP_SX
        sta     OS_ARG+1
        tya
        adc     #>SHIP_SX
        sta     OS_ARG+2
        lda     #<SHIP_SY
        sta     OS_ARG+3
        lda     #>SHIP_SY
        sta     OS_ARG+4
        jmp     API_GPU_SPRITE
.else
        ; The centre is 16-bit because it has to be: FBCX plus a SHOFF of 126
        ; plus a vertex is past 255 on its own. Built straight into PBUF now -
        ; the same argument block one_asteroid fills, reused here because the
        ; two never draw at once.
        ldy     #$00                    ; cx = FBCX + SHOFF, signed 16
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFFH
        adc     #<FBCX
        sta     PBUF+0
        tya
        adc     #>FBCX
        sta     PBUF+1

        ldy     #$00                    ; cy = FBCY + SHOFX, the cross lean
        bit     SHOFXH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFXH
        adc     #<FBCY
        sta     PBUF+2
        tya
        adc     #>FBCY
        sta     PBUF+3

        stz     PBUF+4                  ; ANGLE: nose fixed up (4.3) - no spin
                                        ;   to fold in, unlike a rock's
        lda     ZEASH                   ; SCALE: the same eased zoom reciprocal
        sta     PBUF+5                  ;   a rock's SCALE reads (4.4) - the GPU
                                        ;   now does the multiply sscale used to
                                        ;   do here, one vertex at a time
        lda     #SHIP_VN
        sta     PBUF+6

        ldx     #$00                    ; the shape is authored at the scale
@vlp:   lda     SHIP_SHAPE,x            ;   POLYGON16 wants - unrotated and
        sta     PBUF+7,x                ;   unscaled, exactly as authored - so
        inx                             ;   this is a copy, the same as a
        cpx     #SHIP_VN*2              ;   rock's, not a per-vertex transform
        bne     @vlp

        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jmp     API_GPU_POLYGON16       ; tail call: its own rts returns for us
.endif

; =============================================================================
; The sprite the ship used to be
; =============================================================================
; Assembles to nothing while SHIP_SPRITE = 0, which it is: the outline won
; (design_technical 11.14). It is kept whole - the art, the definition pages
; and upload_step above - because it is also the worked example of getting any
; sprite into GPU RAM, which the thruster flames and the shots will need.
; =============================================================================
        .segment "RODATA"
.if SHIP_SPRITE
; --- the ship -----------------------------------------------------------------
; Generated from assets/png/ship32.png:
;     python tools/sprgen.py assets/png/ship32.png src/ship32.s \
;            ship32 --tate
; --tate pre-rotates the art a quarter turn, because the monitor is on its side
; and a sprite's width axis runs DOWN the player's screen. Nothing rotates it at
; runtime; the asset is simply stored turned. It is 32x32 with an overlay plane,
; which is 256 bytes - exactly one LOAD page, which is why it is 32 and not 30.
        .include "ship32.s"

; The two sprite slots this cartridge defines, as the four GPU definition pages
; want them: [slot 0, slot SPR_SHIP] per page. Slot 0 keeps the ROM test sprite
; ($F400, 32x26, no overlay) so that a wrong id draws something recognisable
; instead of nothing at all.
SPRDEF:
        .byte   $14, SHIP32_TYPE        ; $0300 SPR_TYPE
        .byte   $00, $00                ; $0400 SPR_PTR_LSB
        .byte   $F4, SHIP_PAGE          ; $0500 SPR_PTR_MSB
        .byte   26,  SHIP32_HEIGHT      ; $0600 SPR_HEIGHT
.endif

        .segment "CODE"
