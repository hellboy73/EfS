; =============================================================================
; stars.s - the backdrop, which is sampled rather than simulated
; =============================================================================
; Fixed decision 8, and design_technical 5.3. Stars are not objects: they have
; no world coordinates, no slots and no physics. They live in their own 256x256
; wrapping layer, and a byte coordinate covers that layer exactly - so the
; layer's own wrap is free in the same way the world's is.
;
; Two layers. The far one scrolls at 1/8 of the ship's speed; the near motes
; run at twice it. Both ROTATE with the camera, because parallax applies to
; translation only and a layer that slid without turning would tear away from
; the world on every turn.
;
; The expensive half is not the drawing, it is knowing where a star IS after a
; turn: star_rebase rebuilds the layer's view-space positions, and do_stars is
; shaped entirely around not having to call it every frame.
; =============================================================================
; -----------------------------------------------------------------------------
; init_stars — scatter the layer with the OS RNG.
; -----------------------------------------------------------------------------
; The layer is 256 x 256 and a byte coordinate covers it exactly, so "scatter"
; really is two random bytes per star, and the layer's wrap is free.
;
; This uses the cartridge's own LFSR, not the OS `rng`, for two reasons: the OS
; seed is set up by CPU1 boot, which a py65 harness does not run (an unseeded
; LFSR is all zeroes and every star lands on the same spot), and a field that
; is measured should scatter the same way every time it is built.
; -----------------------------------------------------------------------------
init_stars:
        ldy     #$00
@lp:    jsr     prng
        sta     STARBX,y
        jsr     prng
        sta     STARBY,y
        iny
        cpy     #STAR_N
        bne     @lp
        rts

; The mote layer, scattered the same way and for the same reason.
init_motes:
        ldy     #$00
@lp:    jsr     prng
        sta     MOTEBX,y
        jsr     prng
        sta     MOTEBY,y
        iny
        cpy     #MOTE_N
        bne     @lp
        rts

; -----------------------------------------------------------------------------
; do_stars — scroll the field, rebuild it only when the heading moved, emit it.
; -----------------------------------------------------------------------------
; THE WHOLE POINT OF THIS ROUTINE'S SHAPE. A star's exact view position is
;
;       view_i = R(H) * (p_i - s)
;
; with p_i its position in the 256 x 256 layer and s the ship's (continuous)
; sample point. Split s into the value it had at the last rebase plus the
; distance flown since:  s = s_base + t * forward. R maps `forward` onto
; view-up by construction — that is what "the ship always points up" MEANS — so
;
;       R * (t * forward) = (0, -t)
;
; and the entire effect of flying is **one scalar added to view-y**. No rotation,
; no per-star work, and t can be carried at whatever precision we like.
;
; So: BASEX/BASEY hold R * (p_i - s_base) as plain bytes (the view-space torus:
; a star that scrolls off one edge is a byte overflow away from the other), and
; every frame adds the integer part of TRAV to view-y. The field translates
; RIGIDLY and exactly. Only a change of heading rebuilds the bases.
;
; The version this replaced folded the travel into the sample and rotated every
; frame, which threw the sub-unit part of s away in the table lookup. Measured
; at heading $14: the field stood still for 3 frames and then ~100 of 110 stars
; jumped at once, by different amounts, because each star's rounding flipped at
; its own moment. Near an axis (heading $FC) one table is almost the identity
; and the other almost zero, so the same lurch came out uniform and read as
; smooth — which is exactly why it looked fine at some angles and shook at
; others. Rigid stepping is what "smooth" looked like; this makes every heading
; behave the way the good one did.
;
; TRAV is in 8.8 half-res pixels, and its per-frame increment is *exactly* the
; speed byte: a world unit is 1/32 of a half-res pixel and the parallax is 1/8,
; so the step is SPD/256 pixels, which is SPD in 8.8. Nothing to compute.
; -----------------------------------------------------------------------------
do_stars:
        lda     SPDL                    ; flight: speed / 128. A world unit is
        sta     T0                      ;   1/32 of a half-res pixel and the
        lda     SPDH                    ;   parallax is 1/4, so the step is
        sta     T1                      ;   speed/128 pixels - with speed in 8.8
        ldx     #7                      ;   that is just a shift.
:       lda     T1
        cmp     #$80
        ror     T1
        ror     T0
        dex
        bne     :-
        ldx     ETIER                   ; ...times whatever vel_shl multiplied the
        lda     TIER_SHL,x              ;   ship by. The scroll is computed from
        beq     :++                     ;   SPD and the ship flies on VEL, so a
        tax                             ;   boosted tier would otherwise leave the
:       asl     T0                      ;   whole starfield behind.
        rol     T1
        dex
        bne     :-
:

        ; ...plus however far the CAMERA moved on its own. The camera point sits
        ; ahead of the ship by the ship's screen offset, and that offset EASES
        ; between speed tiers - so for a few frames after every tier change the
        ; camera is travelling as well as the ship. That motion is along the
        ; heading, which in view space is the scroll axis, so it belongs in this
        ; same accumulator.
        ;
        ; It used to force a full rebuild instead, and a rebuild rounds every
        ; star independently: while the offset was moving, stars twitched a pixel
        ; or two ACROSS the screen even though the scroll itself was smooth.
        sec
        lda     SHOFFL
        sbc     PSHOFFL
        sta     T2
        lda     SHOFFH
        sbc     PSHOFFH
        sta     T3
        lda     T3                      ; /2: full-res screen px -> half-res
        cmp     #$80
        ror     T3
        ror     T2
        clc
        lda     T0
        adc     T2
        sta     T0
        lda     T1
        adc     T3
        sta     T1
        lda     SHOFFL
        sta     PSHOFFL
        lda     SHOFFH
        sta     PSHOFFH

        clc
        lda     TRAVL
        adc     T0
        sta     TRAVL
        lda     TRAVH
        adc     T1
        sta     TRAVH
        lda     TRAVH                   ; the integer part IS the scroll offset.
        sta     TRAVI                   ;   It is never reset - a base is stored
                                        ;   as (true - TRAVI), so base + TRAVI is
                                        ;   the true position whenever it is set.
        lda     HEAD                    ; only the HEADING forces a rebuild - the
        cmp     BASEHEAD                ;   camera's own drift is in the scroll
        beq     @maybe
        jsr     star_rebase_full
        bra     @draw
@maybe:
        sec                             ; refresh once the field has scrolled far
        lda     TRAVI                   ;   enough that a parked star could have
        sbc     REFI                    ;   reached the screen - see star_rebase
        bpl     :+
        eor     #$FF
        inc     a
:       cmp     #STAR_REFRESH
        bcc     @draw
        jsr     star_rebase_refresh
@draw:
        jsr     occ_bands               ; emit_asteroids has finished, so the
                                        ;   occluder list is complete and can be
                                        ;   indexed by band before a star reads it
        stz     DIDX
        stz     STARN
        ldx     #$00
@lp:
        lda     PARKED,x
        beq     :+
        jmp     @next
:       clc                             ; scrolled view-y; the byte wrap is the
        lda     BASEY,x                 ;   view torus, so a star leaving the
        adc     TRAVI                   ;   bottom re-enters at the top for free
        sta     VYT

        ldy     #$00                    ; fb_x = HCX + view_y, as a 9-bit value
        lda     #HCX
        clc
        adc     VYT
        bcc     :+
        iny
:       bit     VYT
        bpl     :+
        dey
:       cpy     #$00
        beq     :+
        jmp     @next
:       cmp     #200
        bcc     :+
        jmp     @next
:       sta     FBX

        ldy     #$00                    ; fb_y = SHCY - view_x. SHCY, not HCY:
        lda     SHCY                    ;   the field must turn about the SHIP,
        sec                             ;   and the lean has moved the ship off
        sbc     BASEX,x                 ;   the cross-axis centre. See do_stars'
                                        ;   header.
        bcs     :+
        dey
:       bit     BASEX,x
        bpl     :+
        iny
:       cpy     #$00
        beq     :+
        jmp     @next
:       cmp     #150
        bcc     :+
        jmp     @next
:       sta     FBY

        lda     FBY                     ; drop the star if any box covers it -
        lsr     a                       ;   but only the boxes registered in this
        lsr     a                       ;   star's row band can, so that is the
        lsr     a                       ;   whole list it has to walk
        lsr     a
        tay
        lda     OCCBN,y
        beq     @emit                   ; empty band: nothing parked, nothing walked
        sta     OCCBW
        stx     SIDX                    ; X becomes the walk cursor; the star
        lda     FBY                     ;   index parks until the walk is over
        and     #$F0                    ; band*16 IS the list offset
        tax
@occ:   ldy     OCCBL,x
        lda     FBX
        cmp     OCCX0,y
        bcc     @occn
        lda     OCCX1,y
        cmp     FBX
        bcc     @occn
        lda     FBY                     ; the band narrows y to 16 rows, it does
        cmp     OCCY0,y                 ;   not decide it - a box covers part of
        bcc     @occn                   ;   its first and last band, not all
        lda     OCCY1,y
        cmp     FBY
        bcc     @occn
        jsr     disc_hit                ; inside the box - inside the disc?
        bcs     @killed
@occn:  inx
        dec     OCCBW
        bne     @occ
        ldx     SIDX

@emit:
        ldy     DIDX
        lda     FBX
        sta     DOTBUF+1,y
        iny
        lda     FBY
        sta     DOTBUF+1,y
        iny
        sty     DIDX
        inc     STARN
        bra     @next
@killed:
        ldx     SIDX
@next:
        inx
        cpx     #STAR_N
        beq     :+
        jmp     @lp
:
        lda     STARN
        sta     DOTBUF
        rts

; -----------------------------------------------------------------------------
; emit_stars / emit_motes — the two decorative layers, appended last.
; -----------------------------------------------------------------------------
emit_stars:
        lda     STARN
        beq     @none
        lda     #<DOTBUF
        sta     OS_ARG+0
        lda     #>DOTBUF
        sta     OS_ARG+1
        jmp     API_GPU_DOTPIXELS
@none:  rts

emit_motes:
        lda     MOTEN
        beq     @none
        lda     #<MOTEBUF
        sta     OS_ARG+0
        lda     #>MOTEBUF
        sta     OS_ARG+1
        jmp     API_GPU_DOTPIXELS
@none:  rts

; -----------------------------------------------------------------------------
; do_motes — the near layer: MOTE_N specks at TWICE the ship's speed.
; -----------------------------------------------------------------------------
; Everything the starfield needs machinery for, this does not. There are 16 of
; them, so they are simply transformed from scratch every frame: no stored bases,
; no travel accumulator, no parking, no refresh. At roughly six pixels a frame
; the per-mote rounding that made the STARS boil is far below the motion itself.
;
; They are also drawn in FRONT of everything, so they need no occlusion pass -
; which is most of what made them cheap. The rotation tables are whatever the
; last star rebuild left, and those are always current for the camera's heading,
; so this borrows them for free.
;
; The sample is the same camera point the stars use, but at parallax 2 instead of
; 1/4: sample = camera >> 4, so one layer unit is 16 world units where a half-res
; screen pixel is 32 - hence 2x. The camera offset is pre-multiplied by 8 rather
; than 64 for the same reason it is pre-multiplied at all: to come out as the
; ship's screen offset in layer units after the shift.
;
; 4x was tried and is too fast: at the top tier it moves them ~12 half-res pixels
; a frame, and specks that quick stop reading as depth and start reading as
; noise. 2x is ~6 a frame, which is the layer doing its job - saying "fast" when
; there is nothing else in view - without taking the eye off the rocks.
; -----------------------------------------------------------------------------
do_motes:
        lda     SHOFFH                  ; camera = ship + offset * forward
        jsr     sext_ma
        lda     SINV
        sta     MB
        jsr     smul16q7
        jsr     shl3_ma
        clc
        lda     SHXL
        adc     MAL
        sta     T0
        lda     SHXH
        adc     MAH
        sta     T1

        lda     SHOFFH
        jsr     sext_ma
        lda     COSV
        sta     MB
        jsr     smul16q7
        jsr     shl3_ma
        sec
        lda     SHYL
        sbc     MAL
        sta     T2
        lda     SHYH
        sbc     MAH
        sta     T3

        lda     T1                      ; sample = camera >> 4: bits 4..11, and
        asl     a                       ;   the four bits below it are the
        asl     a                       ;   sub-unit fraction
        asl     a
        asl     a
        sta     MSAMPX
        lda     T0
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        ora     MSAMPX
        sta     MSAMPX
        lda     T0
        asl     a
        asl     a
        asl     a
        asl     a
        sta     MFRACX
        lda     T3
        asl     a
        asl     a
        asl     a
        asl     a
        sta     MSAMPY
        lda     T2
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        ora     MSAMPY
        sta     MSAMPY
        lda     T2
        asl     a
        asl     a
        asl     a
        asl     a
        sta     MFRACY

        ; U = -R * frac, exactly as a star rebuild does it. The first version of
        ; this routine skipped it and used only the integer tables, on the theory
        ; that at six pixels a frame nobody would see the rounding. They did: the
        ; sample is quantised to a whole layer unit, so between steps a mote does
        ; not move at all and then jumps, and summing two separately-floored
        ; lookups scatters that jump by up to two pixels PER MOTE - which reads as
        ; specks twitching back and forth. Sub-unit registration plus a single
        ; floor makes each mote's position a monotone function of the sample, so
        ; it cannot step backwards.
        lda     MFRACX                  ; UX = -(fx*cos + fy*sin)
        sta     MAL
        stz     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     UXL
        lda     MAH
        sta     UXH
        lda     MFRACY
        sta     MAL
        stz     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        clc
        lda     UXL
        adc     MAL
        sta     UXL
        lda     UXH
        adc     MAH
        sta     UXH
        sec
        lda     #$00
        sbc     UXL
        sta     UXL
        lda     #$00
        sbc     UXH
        sta     UXH

        lda     MFRACX                  ; UY = fx*sin - fy*cos
        sta     MAL
        stz     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     UYL
        lda     MAH
        sta     UYH
        lda     MFRACY
        sta     MAL
        stz     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        sec
        lda     UYL
        sbc     MAL
        sta     UYL
        lda     UYH
        sbc     MAH
        sta     UYH

        stz     MDIDX
        stz     MOTEN
        ldx     #$00
@lp:    stz     MOTEVIS,x
        lda     MOTEBX,x
        sec
        sbc     MSAMPX
        tay
        lda     ROTC_I,y
        sta     CDXI
        lda     ROTC_F,y
        sta     CDXF
        lda     ROTS_I,y
        sta     SDXI
        lda     ROTS_F,y
        sta     SDXF
        lda     MOTEBY,x
        sec
        sbc     MSAMPY
        tay
        lda     ROTC_I,y
        sta     CDYI
        lda     ROTC_F,y
        sta     CDYF
        lda     ROTS_I,y
        sta     SDYI
        lda     ROTS_F,y
        sta     SDYF

        ; fb_x = HCX + (ROTC[dy] - ROTS[dx] + UY), summed in 8.8, floored once
        stz     CF
        sec
        lda     CDYF
        sbc     SDXF
        bcs     :+
        dec     CF
:       clc
        adc     UYL
        bcc     :+
        inc     CF
:       ldy     #$00
        lda     #HCX
        clc
        adc     CDYI
        bcc     :+
        iny
:       bit     CDYI
        bpl     :+
        dey
:       sec
        sbc     SDXI
        bcs     :+
        dey
:       bit     SDXI
        bpl     :+
        iny
:       clc
        adc     UYH
        bcc     :+
        iny
:       bit     UYH
        bpl     :+
        dey
:       clc
        adc     CF
        bcc     :+
        iny
:       bit     CF
        bpl     :+
        dey
:       cpy     #$00
        bne     @next
        cmp     #200
        bcs     @next
        sta     FBX

        ; fb_y = SHCY - (ROTC[dx] + ROTS[dy] + UX) - SHCY for the same reason
        ; the stars use it: the cross-axis lean moves the pivot.
        stz     CF
        clc
        lda     CDXF
        adc     SDYF
        bcc     :+
        inc     CF
:       clc
        adc     UXL
        bcc     :+
        inc     CF
:       ldy     #$00
        lda     SHCY
        sec
        sbc     CDXI
        bcs     :+
        dey
:       bit     CDXI
        bpl     :+
        iny
:       sec
        sbc     SDYI
        bcs     :+
        dey
:       bit     SDYI
        bpl     :+
        iny
:       sec
        sbc     UXH
        bcs     :+
        dey
:       bit     UXH
        bpl     :+
        iny
:       sec
        sbc     CF
        bcs     :+
        dey
:       cpy     #$00
        bne     @next
        cmp     #150
        bcs     @next
        sta     FBY

        ldy     MDIDX
        lda     FBX
        sta     MOTEBUF+1,y
        sta     MOTESX,x
        lda     FBY
        sta     MOTEBUF+2,y
        sta     MOTESY,x
        iny
        iny
        sty     MDIDX
        inc     MOTEN
        lda     #$01
        sta     MOTEVIS,x
@next:
        inx
        cpx     #MOTE_N
        beq     :+
        jmp     @lp
:       lda     MOTEN
        sta     MOTEBUF
        rts

; -----------------------------------------------------------------------------
; star_rebase — rebuild the stars' view-space positions from the layer.
; -----------------------------------------------------------------------------
; Two entry points. FULL runs when the heading moved: it rebuilds the rotation
; tables and every star. REFRESH runs during straight flight and rewrites only
; the PARKED stars, so nothing that is currently on screen ever moves - a
; rebuild rounds each star independently and would put a scattered one-pixel
; twitch into an otherwise perfectly rigid scroll.
;
; PARKING is what this is really for. A star's view position is R*d over the
; whole 256x256 layer square, so it reaches 128*(|cos|+|sin|) - up to 181 at 45
; degrees - while a base is one byte and folds at 128. A star whose true view_y
; is 128..156 folds to -128..-100 and is drawn at the TOP of the screen, at a
; radius of about 150, so it sweeps faster than everything else and the wrong
; way. That is the streak along the top and bottom edges during a turn, and it
; is worst off-axis: at heading 0 the maximum is exactly 128 and nothing folds,
; which is why it looked clean flying north.
;
; So a star whose true position does not fit in a byte is parked instead of
; folded. Every parked star is off screen by construction - the visible band is
; |view_x| <= 75 and |view_y| <= 100, well inside +/-127 - so nothing is lost.
; What IS lost is the margin: the kept band clears the screen by only 27 pixels
; in y, and the field scrolls in y. STAR_REFRESH forces a refresh before that
; margin runs out, which is what un-parks stars as they come round.
;
; The cross-axis lean eats into the OTHER margin. The field is drawn about SHCY,
; not HCY, so the band it has to cover is (L-75)..(74+L) where L is the lean in
; half-res pixels - at the design ceiling of 80 full-res that is |view_x| <= 115
; and the 53-pixel margin in x becomes 13. There is no refresh for that axis and
; none is needed: the lean only GROWS while the heading is turning, and a turning
; heading rebases every frame anyway. Once the stick is centred the lean decays,
; and a decaying lean only ever shrinks the band. The one frame in four that the
; slowest turn rate leaves the heading byte alone can move the lean by at most
; 1.25 half-res px, against 13 of margin.
;
; The bases carry no travel: a base is stored as (true - TRAVI), so base + TRAVI
; is the true position at any later frame. TRAVI is therefore never reset.
; -----------------------------------------------------------------------------
STAR_REFRESH = 24               ; refresh after this much scroll; the margin is 27

star_rebase_full:
        lda     HEAD                    ; (the ROT tables this uses were built by
        sta     BASEHEAD                ;   do_camera on the same frame, for the
        stz     RBMODE                  ;   same reason: the heading moved)
        bra     srb_core
star_rebase_refresh:
        lda     #$01
        sta     RBMODE
srb_core:
        lda     TRAVI
        sta     REFI

        ; ---- where the CAMERA is, which is not where the ship is ------------
        ; The world has to turn about the SHIP: it is the ship that rotates, so
        ; anything else slides past it and the turn reads as a strafe. But the
        ; ship is drawn below centre at speed, and the star layer only reaches
        ; 128 units - measured from wherever the layer is centred. Centre it on
        ; the ship and the top of the screen is 160 units away, past the end of
        ; the layer, and the field would need four times the stars to fill it.
        ;
        ; Both at once: sample the layer at the point the SCREEN CENTRE looks at,
        ; which is the ship plus its screen offset along the heading. Then the
        ; layer sits where it is needed - centred on the screen - and the pivot
        ; still lands on the ship, because that sample point swings around the
        ; ship as the heading changes. The offset cancels out of the drawing
        ; entirely; it only moves the sample.
        ;
        ; That is the ALONG axis. The cross axis cannot be done here - the lean
        ; decays while the heading is still, and a still heading does not rebase
        ; - so it is applied at draw time instead, as SHCY. Same effect, one
        ; pixel of granularity: see do_stars and the CAMX notes.
        lda     SHOFFH                  ; camera = ship + offset * forward,
        jsr     sext_ma                 ;   forward = (sin, -cos)
        lda     SINV
        sta     MB
        jsr     smul16q7
        jsr     shl6_ma                 ; screen pixels -> layer offset
        clc
        lda     SHXL
        adc     MAL
        sta     T0
        lda     SHXH
        adc     MAH
        sta     T1

        lda     SHOFFH
        jsr     sext_ma
        lda     COSV
        sta     MB
        jsr     smul16q7
        jsr     shl6_ma
        sec
        lda     SHYL
        sbc     MAL
        sta     T2
        lda     SHYH
        sbc     MAH
        sta     T3

        lda     T0                      ; sample = camera >> 7 at parallax 1/4,
        asl     a                       ;   and the bit below it is the sub-unit
        sta     FRACX                   ;   fraction. Both fall out of one shift.
        lda     T1
        rol     a
        sta     SAMPX
        lda     T2
        asl     a
        sta     FRACY
        lda     T3
        rol     a
        sta     SAMPY

        ; U = -R * frac. Without it a rebase re-registers the field against the
        ; INTEGER sample and the whole field pops by up to a pixel.
        lda     FRACX                   ; UX = -(fx*cos + fy*sin)
        sta     MAL
        stz     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     UXL
        lda     MAH
        sta     UXH
        lda     FRACY
        sta     MAL
        stz     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        clc
        lda     UXL
        adc     MAL
        sta     UXL
        lda     UXH
        adc     MAH
        sta     UXH
        sec
        lda     #$00
        sbc     UXL
        sta     UXL
        lda     #$00
        sbc     UXH
        sta     UXH

        lda     FRACX                   ; UY = fx*sin - fy*cos
        sta     MAL
        stz     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     UYL
        lda     MAH
        sta     UYH
        lda     FRACY
        sta     MAL
        stz     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        sec
        lda     UYL
        sbc     MAL
        sta     UYL
        lda     UYH
        sbc     MAH
        sta     UYH

        ldx     #$00
srb_lp:
        lda     RBMODE                  ; a refresh leaves live stars alone
        beq     srb_do
        lda     PARKED,x
        bne     srb_do
        jmp     srb_next
srb_do:
        stz     PKX
        lda     STARBX,x
        sec
        sbc     SAMPX
        tay
        lda     ROTC_I,y
        sta     CDXI
        lda     ROTC_F,y
        sta     CDXF
        lda     ROTS_I,y
        sta     SDXI
        lda     ROTS_F,y
        sta     SDXF
        lda     STARBY,x
        sec
        sbc     SAMPY
        tay
        lda     ROTC_I,y
        sta     CDYI
        lda     ROTC_F,y
        sta     CDYF
        lda     ROTS_I,y
        sta     SDYI
        lda     ROTS_F,y
        sta     SDYF

        ; ---- view x = ROTC[dx] + ROTS[dy] + UX, kept to 9 bits so the fold
        ;      can be SEEN rather than silently happening
        stz     CF
        clc
        lda     CDXF
        adc     SDYF
        bcc     :+
        inc     CF
:       clc
        adc     UXL
        bcc     :+
        inc     CF
:       ldy     #$00
        lda     CDXI
        bpl     :+
        dey
:       clc
        adc     SDYI
        bcc     :+
        iny
:       bit     SDYI
        bpl     :+
        dey
:       clc
        adc     UXH
        bcc     :+
        iny
:       bit     UXH
        bpl     :+
        dey
:       clc
        adc     CF
        bcc     :+
        iny
:       sta     T0                      ; T0 = the byte, Y = its ninth bit
        cpy     #$00
        bne     :+
        cmp     #$80
        bcc     srb_x_ok
        bra     srb_x_bad
:       cpy     #$FF
        bne     srb_x_bad
        cmp     #$80
        bcs     srb_x_ok
srb_x_bad:
        inc     PKX
srb_x_ok:

        ; ---- view y = ROTC[dy] - ROTS[dx] + UY
        stz     CF
        sec
        lda     CDYF
        sbc     SDXF
        bcs     :+
        dec     CF
:       clc
        adc     UYL
        bcc     :+
        inc     CF
:       ldy     #$00
        lda     CDYI
        bpl     :+
        dey
:       sec
        sbc     SDXI
        bcs     :+
        dey
:       bit     SDXI
        bpl     :+
        iny
:       clc
        adc     UYH
        bcc     :+
        iny
:       bit     UYH
        bpl     :+
        dey
:       clc
        adc     CF
        bcc     :+
        iny
:       bit     CF
        bpl     :+
        dey
:       sta     T1
        cpy     #$00
        bne     :+
        cmp     #$80
        bcc     srb_y_ok
        bra     srb_y_bad
:       cpy     #$FF
        bne     srb_y_bad
        cmp     #$80
        bcs     srb_y_ok
srb_y_bad:
        inc     PKX
srb_y_ok:
        lda     PKX
        beq     :+
        lda     #$01                    ; out of byte range: park it rather than
        sta     PARKED,x                ;   let it fold onto the screen edge
        bra     srb_next
:       stz     PARKED,x
        lda     T0
        sta     BASEX,x
        sec                             ; the scroll is in y only, so only y
        lda     T1                      ;   carries the travel back out
        sbc     TRAVI
        sta     BASEY,x
srb_next:
        inx
        cpx     #STAR_N
        beq     :+
        jmp     srb_lp
:       rts
