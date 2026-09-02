; =============================================================================
; landmark.s - A TEMPORARY DEBUG OBJECT. Delete this file when it has done its
; job; nothing in the game is allowed to depend on it.
; =============================================================================
; One square, 256 x 256 full-res pixels, nailed to a fixed world position. It
; exists to answer a question the rock field cannot: HOW BIG IS THE WORLD when
; you fly it? Every rock looks like every other rock and they all drift, so
; there is nothing on screen to measure travel against - you cannot tell forty
; seconds of flying from having gone round the torus twice.
;
; A square fixes that three ways at once:
;   - it does not move, so any motion of it on screen is YOUR motion;
;   - it is a square, so it is unmistakably not a rock and its rotation reads
;     as the CAMERA turning;
;   - it sits exactly ONE SECTOR from the ship's start (4096 world units, which
;     is 256 full-res pixels at 1:1 - about a screen), so the first thing it
;     tells you is what a cell of the collision grid feels like.
;
; It draws with $4D POLYGON, half-res, rather than the $4E full-res family the
; rocks use. That is not indifference: the shape's offsets are signed bytes, and
; the full-res path doubles them on the way out (main.s SHAPE_16X), which caps a
; figure at 254 px across. Half-res offsets of +/-64 give exactly 256, and no
; landmark needs sub-pixel precision.
;
; It is deliberately NOT an object:
;   - no slot in the pool, so it cannot be spun, moved, split or bounced;
;   - no entry in the sector grid, so physics.s never sees it - it is scenery,
;     and a solid wall is a different question from the one it was added to
;     answer;
;   - no occlusion disc, so stars show through it. Adding one is add_disc and
;     four lines, if it ever starts reading as a hole rather than a frame.
;
; Cost, MEASURED (preview.py, 200 frames, drawn on 185 of them): about 2,000
; cycles a frame, 0.8% of CPU1's budget - one transform, one 15-byte command,
; and only when it is on camera, because it takes the rocks' own cull first.
; =============================================================================

; Where it stands. The ship starts at $8000,$8000 (levels.s L0_SHX/L0_SHY), so
; this is one sector away along Y - just off the top edge at boot, whole a
; moment later. Move it by editing these two.
LM_X        = $8000
LM_Y        = $7000

; -----------------------------------------------------------------------------
; emit_landmark - called from cart_frame, after the rocks.
; -----------------------------------------------------------------------------
emit_landmark:
        sec                             ; the world delta, exactly as a rock's is
        lda     #<LM_X                  ;   built: 16-bit, and the wrap is the
        sbc     SHXL                    ;   subtract
        sta     PXL
        lda     #>LM_X
        sbc     SHXH
        sta     PXH
        sec
        lda     #<LM_Y
        sbc     SHYL
        sta     PYL
        lda     #>LM_Y
        sbc     SHYH
        sta     PYH

        lda     PXL                     ; the rocks' own cull. CULL_R already
        ldy     PXH                     ;   carries a 96 px rock radius of slack
        jsr     in_range                ;   and this square's half-diagonal is
        bcc     :+                      ;   181 px against 534 of margin, so it
@off:   rts                             ;   cannot pop at an edge
:       lda     PYL
        ldy     PYH
        jsr     in_range
        bcs     @off

        jsr     view_xform              ; -> VXL/VXH, VYL/VYH, still world units

        lda     VYL                     ; fb_x = FBCX + round(vy*z/16) + SHOFF
        sta     MAL
        lda     VYH
        sta     MAH
        jsr     zoom_ma
        jsr     asr4r
        clc
        lda     MAL
        adc     #<FBCX
        sta     FXL
        lda     MAH
        adc     #>FBCX
        sta     FXH
        ldy     #$00
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       clc
        lda     FXL
        adc     SHOFFH
        sta     FXL
        tya
        adc     FXH
        sta     FXH

        lda     VXL                     ; fb_y = FBCY - round((vx*z - lean)/16),
        sta     MAL                     ;   the cross-axis camera lean folded in
        lda     VXH                     ;   before the single rounding
        sta     MAH
        jsr     zoom_ma
        sec
        lda     MAL
        sbc     SHOFXQ
        sta     MAL
        lda     MAH
        sbc     SHOFXQ+1
        sta     MAH
        jsr     asr4r
        sec
        lda     #<FBCY
        sbc     MAL
        sta     FYL
        lda     #>FBCY
        sbc     MAH
        sta     FYH

        lda     FXH                     ; the half-res centre $4D wants: the
        cmp     #$80                    ;   full-res position >> 1, arithmetic
        ror     a
        sta     PBUF+1
        lda     FXL
        ror     a
        sta     PBUF+0
        lda     FYH
        cmp     #$80
        ror     a
        sta     PBUF+3
        lda     FYL
        ror     a
        sta     PBUF+2

        lda     #$00                    ; ANGLE. It has no spin of its own, but
        sec                             ;   the CAMERA rotates, so the square has
        sbc     HEAD                    ;   to turn with the world - and that is
        sta     PBUF+4                  ;   most of what makes it readable
        lda     ZEASH                   ; SCALE: the same eased zoom the rocks
        sta     PBUF+5                  ;   take, so it shrinks with everything
        lda     #LM_VN
        sta     PBUF+6

        ldx     #$00
:       lda     LM_SHAPE,x
        sta     PBUF+7,x
        inx
        cpx     #2*LM_VN
        bne     :-

        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jmp     API_GPU_POLYGON

        .segment "RODATA"

; Signed bytes in HALF-res pixels from the centre, wound in order and closed by
; the GPU - a rock's outline format exactly. +/-64 is 128 half-res across, which
; is the 256 full-res the name promises, and it is inside the +/-127 a signed
; byte allows with room to spare.
LM_VN       = 4
LM_SHAPE:   .byte   <-64, <-64,   64, <-64,   64,   64, <-64,   64

        .segment "CODE"
