; =============================================================================
; math.s - the arithmetic every other module is built out of
; =============================================================================
; Nothing here knows what a rock, a star or a camera is: it is the multiply,
; the pseudo-random generator, and the shifts that move a value between the
; program's fixed-point formats.
;
; THE MULTIPLY IS A QUARTER-SQUARE TABLE, not mul16 - design_technical 4.4 and
; fixed decision 5. a*b = f(a+b) - f(a-b) with f(x) = x*x/4, which is two table
; reads and a subtract for a product, at the price of 512 bytes of RAM that
; init_qs builds at boot. Every product in the frame goes through qmul or
; smul_core; if you find yourself wanting a general 16x16, you want a different
; algorithm instead.
; =============================================================================
; -----------------------------------------------------------------------------
; init_qs — the quarter-square multiply table, f(x) = x*x/4 for x = 0..255.
; -----------------------------------------------------------------------------
; a*b = f(a+b) - f(a-b), EXACTLY: (a+b) and (a-b) always have the same parity,
; so the two floors cancel. Both operands here are MAGNITUDES of at most 127 —
; the callers strip the signs — so a+b never leaves a byte and a 256-entry table
; covers every index the rotation can ask for. The design's 2 x 512 bytes is what
; a full signed 8x8 would need.
;
; The second copy is the same table plus 64. A >>7 has to round, and rounding is
; "add 64 before the shift"; taking the MINUEND from the +64 table and the
; subtrahend from the plain one does that add for nothing. It is 512 bytes of RAM
; for ~15 cycles on every one of the four multiplies a vertex costs.
;
; Built by running sum, not by multiplying: f(x+1) - f(x) = floor((x+1)/2), so
; the whole page costs one add per entry.
; -----------------------------------------------------------------------------
init_qs:
        stz     T0
        stz     T1
        ldx     #$00
@lp:    lda     T0
        sta     QSL,x
        clc
        adc     #$40
        sta     QRL,x
        lda     T1
        sta     QSH,x
        adc     #$00
        sta     QRH,x
        inx
        beq     @done                   ; wrapped past 255: the page is written
        txa                             ; delta for the entry just past x is
        lsr     a                       ;   floor((x+1)/2), and X is already x+1
        clc
        adc     T0
        sta     T0
        bcc     @lp
        inc     T1
        bra     @lp
@done:  rts

; -----------------------------------------------------------------------------
; qmul — MQA * MQB, both MAGNITUDES 0..127, rounded >>7 -> A. Clobbers X, Y.
; -----------------------------------------------------------------------------
; No signs anywhere: the caller strips them once per rock (the trig) and once per
; vertex (the coordinate) instead of four times per vertex inside here, and puts
; the sign back on the product with a compare. That is the difference between a
; ~130-cycle multiply and a ~60-cycle one, which on a 12-vertex rock — 48 of
; these — is most of what the outline costs.
;
; MQA + MQB has to stay inside a byte for the table index, which is why both are
; capped at 127. The largest authored vertex is 48 and |cos| tops out at 127.
; -----------------------------------------------------------------------------
qmul:
        clc
        lda     MQA
        adc     MQB
        tax                             ; a + b, at most 254
        sec
        lda     MQA
        sbc     MQB
        bcs     :+
        eor     #$FF                    ; carry is clear here, so this +1 is the
        adc     #$01                    ;   two's complement negate
:       tay                             ; |a - b|
        sec                             ; f(a+b) + 64 - f(|a-b|): the product with
        lda     QRL,x                   ;   its rounding term already in it
        sbc     QSL,y
        sta     MQR
        lda     QRH,x
        sbc     QSH,y
        asl     MQR                     ; >>7 is <<1 read as the high byte, and
        rol     a                       ;   the byte is already in A
        rts

; -----------------------------------------------------------------------------
; prng — 16-bit LFSR, eight steps per call so the whole low byte is fresh.
; -----------------------------------------------------------------------------
; Clobbers X. Y is left alone, which is what lets init_stars index with it.
; -----------------------------------------------------------------------------
prng:
        ldx     #8
@step:  lsr     PRNGH                   ; state >>= 1, high byte first, so bit 0
        ror     PRNGL                   ;   of the word falls into the carry
        bcc     @noxor
        lda     PRNGH
        eor     #$B4                    ; tap mask $B400 - the low byte is $00,
        sta     PRNGH                   ;   so only the high byte is touched
@noxor: dex
        bne     @step
        lda     PRNGL
        rts

; MA >>= 4, arithmetic, ROUNDED. CMP #$80 puts the sign bit into carry for ROR.
; -----------------------------------------------------------------------------
; This is the LAST step of an object's transform, not the first. Truncating the
; world delta to whole pixels BEFORE the rotation - which is what the code used
; to do - threw away four bits of position, and the rotation turned that into one
; to two pixels of wander on screen: objects visibly swam at low speed. Rotating
; at full 1/16-pixel resolution and rounding once at the end leaves them still.
; MA <<= 6: a full-res screen pixel is 16 world units, and then x4 to cancel the
; star layer's 1/4 parallax. Parallax belongs to TRANSLATION only - a rotation
; moves near and far alike - and the camera's swing around the ship is part of
; turning, not of travelling. Leave the x4 out and the star field pivots a
; quarter of the way from the screen centre to the ship, which still strafes.
shl6_ma:
        ldx     #6
        bra     shl_ma
shl3_ma:
        ldx     #3
shl_ma:
@lp:    asl     MAL
        rol     MAH
        dex
        bne     @lp
        rts

; -----------------------------------------------------------------------------
; zoom_ma — MA (world units) *= the zoom reciprocal, in place.
; -----------------------------------------------------------------------------
; A subroutine and not the macro inline, for a reason worth knowing: RPROD ends
; with .local symbols, and a .local closes the enclosing cheap-local (@) scope.
; Expanded inside do_objects it silently orphaned that routine's own @cull and
; @lp. Macros that declare locals do not belong in a routine that uses @labels.
; -----------------------------------------------------------------------------
zoom_ma:
        RPROD   ZSI, ZSF, MAL, MAH
        lda     T0
        sta     MAL
        lda     T1
        sta     MAH
        rts

asr4r:
        clc
        lda     MAL
        adc     #8                      ; +0.5 px, so this rounds instead of
        sta     MAL                     ;   flooring - the magnitude multiply
        lda     MAH                     ;   truncates toward zero, and a floor
        adc     #$00                    ;   here would disagree with it across
        sta     MAH                     ;   the origin: a 1 px hitch
        ldx     #4
@lp:    lda     MAH
        cmp     #$80
        ror     MAH
        ror     MAL
        dex
        bne     @lp
        rts
; -----------------------------------------------------------------------------
; sext_ma — A (signed byte) -> MAL/MAH, sign-extended.
; -----------------------------------------------------------------------------
sext_ma:
        sta     MAL
        and     #$80
        beq     :+
        lda     #$FF
:       sta     MAH
        rts

; -----------------------------------------------------------------------------
; smul_core — |MA| * |MB| -> MR0..MR2, MSGN = 1 if the result must be negated.
; -----------------------------------------------------------------------------
; Shift-and-add over the seven magnitude bits of MB, MOST significant first: the
; 24-bit accumulator is what gets shifted, so the multiplicand never moves and
; there is no ceiling on it. The earlier LSB-first version shifted MA left six
; times, which capped it near 1024 and is why object positions had to be
; pre-truncated to whole pixels before the rotation - the thing that made them
; swim. MA is destroyed (sign only). The wrappers below shape the 24-bit
; magnitude into whatever the caller wanted.
; -----------------------------------------------------------------------------
smul_core:
        stz     MSGN
        lda     MB
        bpl     @bpos
        eor     #$FF
        clc
        adc     #$01
        sta     MB
        lda     #$01
        sta     MSGN
@bpos:
        lda     MAH
        bpl     @apos
        lda     MSGN
        eor     #$01
        sta     MSGN
        sec
        lda     #$00
        sbc     MAL
        sta     MAL
        lda     #$00
        sbc     MAH
        sta     MAH
@apos:
        stz     MR0
        stz     MR1
        stz     MR2
        asl     MB                      ; the seven magnitude bits move up to
        ldx     #7                      ;   bits 7..1, so the loop can take them
@lp:    asl     MR0                     ;   off the top one at a time
        rol     MR1
        rol     MR2
        asl     MB
        bcc     @noadd
        clc
        lda     MR0
        adc     MAL
        sta     MR0
        lda     MR1
        adc     MAH
        sta     MR1
        lda     MR2
        adc     #$00
        sta     MR2
@noadd: dex
        bne     @lp
        rts

; (signed 16) x (signed Q0.7), >> 7 -> MAL/MAH.
smul16q7:
        jsr     smul_core
        asl     MR0                     ; >>7 is <<1 and then the top two bytes
        rol     MR1
        rol     MR2
        lda     MR1
        sta     MAL
        lda     MR2
        sta     MAH
        lda     MSGN
        beq     @done
        sec
        lda     #$00
        sbc     MAL
        sta     MAL
        lda     #$00
        sbc     MAH
        sta     MAH
@done:  rts

