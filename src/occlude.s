; =============================================================================
; occlude.s - what the backdrop is NOT drawn behind
; =============================================================================
; The star layers go out LAST, so without this a star lands on top of the ship
; and inside every rock. design_technical 5.4 is the design; this is the list
; it works from.
;
; Two shapes, and the difference is deliberate. The ship gets a BOX, because it
; is opaque. A rock gets a DISC - one radius, SHAPE_OCC, which is the same
; circle physics.s collides with (fixed decision 12) - because a rock's outline
; is a closed figure and a star inside it would read as a hole in a solid.
;
; occ_bands exists because asking every star about every occluder is a product
; of two numbers that both grow with the zoom. Indexing the occluders by the
; screen rows they touch turns that product into a short list per row.
; =============================================================================
; -----------------------------------------------------------------------------
; add_ship_occluder — the star-suppression list, which is now one box.
; -----------------------------------------------------------------------------
; The backdrop is drawn LAST, so a star inside the ship's silhouette would land
; on top of it. One box stops that. The asteroids deliberately get no box: their
; outlines are hollow, and a star seen through one is the right picture — which
; is also why the general box list this file used to keep is gone. When rocks
; need to be opaque it will be the coarse disc mask of design_technical 5.4, not
; a bounding box.
; -----------------------------------------------------------------------------
add_ship_occluder:
        lda     #SPR_W2                 ; the box shrinks with the ship, or a
        sta     MQA                     ;   small ship would sit in a large hole
        lda     ZOOMH                   ;   in the starfield
        sta     MQB
        jsr     qmul
        sta     SOCCW
        lda     #SPR_H2
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul
        sta     SOCCH

        lda     SHOFFH                  ; the box rides down with the ship
        cmp     #$80
        ror     a                       ; offset / 2, arithmetic: half-res
        clc
        adc     #HCX
        sta     T0
        ldy     OCCN
        lda     T0
        sec
        sbc     SOCCW
        sta     OCCX0,y
        lda     T0
        clc
        adc     SOCCW
        sta     OCCX1,y
        sec
        lda     SHCY
        sbc     SOCCH
        sta     OCCY0,y
        clc
        lda     SHCY
        adc     SOCCH
        sta     OCCY1,y
        lda     T0                      ; the ship is opaque to its box corners,
        sta     OCCCX,y                 ;   so r2 = $FFFF: every star that gets
        lda     SHCY                    ;   inside the box is inside the "disc"
        sta     OCCCY,y
        lda     #$FF
        sta     OCCR2L,y
        sta     OCCR2H,y
        inc     OCCN
        rts

; -----------------------------------------------------------------------------
; add_disc — this rock's suppression disc. CX2/CY2 and AOCR are already set.
; -----------------------------------------------------------------------------
; A dotted outline is hollow, so without this a rock reads as a wire hoop with
; the starfield shining straight through it. A bounding BOX would be wrong for
; the same reason it is wrong for the cull: the corners of a 96-px box are a
; long way outside a 96-px rock, and stars would blink out in mid-space.
;
; The entry is therefore both: a clamped box for the cheap per-star reject, and
; the centre plus r^2 for the round test inside it. r^2 comes out of the
; quarter-square table for nothing - f(x) = x*x/4, so x*x = f(2x), and 2*48 is
; well inside a byte of index.
;
; Only the centre's LOW byte is kept, and that is exact: the round test only
; ever runs on a star already inside the clamped box, so its true offset from
; the centre is within +/-R, R is at most 48, and a value that small is read
; back correctly from a byte subtract no matter where the centre really is.
; That is what lets a rock hanging off the screen edge still suppress stars -
; the old box list gave up on those entirely.
; -----------------------------------------------------------------------------
add_disc:
        ldy     OCCN
        cpy     #16
        bcs     @full
        lda     CX2L
        sta     OCCCX,y
        lda     CY2L
        sta     OCCCY,y

        sec                             ; box x0 = cx - R, clamped at 0
        lda     CX2L
        sbc     AOCR
        tax
        lda     CX2H
        sbc     #$00
        bpl     @x0ok
        ldx     #$00
@x0ok:  txa
        sta     OCCX0,y
        clc                             ; box x1 = cx + R, clamped at 199
        lda     CX2L
        adc     AOCR
        tax
        lda     CX2H
        adc     #$00
        bne     @x1hi                   ; past 255, so past the right edge
        cpx     #200
        bcc     @x1ok
@x1hi:  ldx     #199
@x1ok:  txa
        sta     OCCX1,y

        sec                             ; the same for y, against 149
        lda     CY2L
        sbc     AOCR
        tax
        lda     CY2H
        sbc     #$00
        bpl     @y0ok
        ldx     #$00
@y0ok:  txa
        sta     OCCY0,y
        clc
        lda     CY2L
        adc     AOCR
        tax
        lda     CY2H
        adc     #$00
        bne     @y1hi
        cpx     #150
        bcc     @y1ok
@y1hi:  ldx     #149
@y1ok:  txa
        sta     OCCY1,y

        lda     AOCR                    ; r^2 = f(2R)
        asl     a
        tax
        lda     QSL,x
        sta     OCCR2L,y
        lda     QSH,x
        sta     OCCR2H,y
        inc     OCCN
@full:  rts

; -----------------------------------------------------------------------------
; disc_hit — is (FBX, FBY) inside occluder Y's disc? Carry SET = yes.
; -----------------------------------------------------------------------------
; Called only for a star already inside that occluder's box. Two table reads,
; an add and a 16-bit compare. Preserves X (the star loop's index) and Y.
; -----------------------------------------------------------------------------
disc_hit:
        phx
        sec
        lda     FBX
        sbc     OCCCX,y
        bpl     :+
        eor     #$FF
        inc     a
:       asl     a                       ; index 2*|dx|, at most 96
        tax
        lda     QSL,x
        sta     DSQL
        lda     QSH,x
        sta     DSQH
        sec
        lda     FBY
        sbc     OCCCY,y
        bpl     :+
        eor     #$FF
        inc     a
:       asl     a
        tax
        clc
        lda     QSL,x
        adc     DSQL
        sta     DSQL
        lda     QSH,x
        adc     DSQH
        plx                             ; (pull does not touch the carry, and
        cmp     OCCR2H,y                ;  the compare below sets it anyway)
        bcc     @in
        bne     @out
        lda     DSQL
        cmp     OCCR2L,y
        bcc     @in
        beq     @in
@out:   clc
        rts
@in:    sec
        rts

; -----------------------------------------------------------------------------
; occ_bands — index the occluder list by the screen row bands each box spans.
; -----------------------------------------------------------------------------
; The star loop used to ask every star about every occluder. That product is
; O(stars x rocks), and both factors grow together: pulling the camera back puts
; more rocks on screen without removing a single star, so the pass gets more
; expensive on exactly the frames that are already the worst ones. The frame
; budget did not model it at all, because it was measured once, at two rocks,
; and written down as a constant.
;
; Inverting it costs one pass over the occluders - at most 16 of them, each
; touching a handful of bands - and turns the per-star walk from OCCN into
; "however many occluders are in these 16 rows". At full zoom-out the suppression
; radii are 19, 13, 6, 3 and 1 half-res pixels, so most rocks land in one or two
; bands and a star sees two or three occluders instead of ten.
;
; Nothing here knows the outline is dotted: it works on the occluder boxes, which
; are the same whether the rock is drawn with DOT_LINES or with solid LINES.
; -----------------------------------------------------------------------------
occ_bands:
        ldx     #OCCB_N-1
:       stz     OCCBN,x
        dex
        bpl     :-

        ldx     OCCN
        beq     @done
@occ:   dex                             ; occluder ids, OCCN-1 down to 0
        stx     T3                      ; ...parked: X becomes the band, because
        lda     OCCY0,x                 ;   INC abs,y does not exist
        lsr     a                       ; the bands its clamped box spans. Both
        lsr     a                       ;   ends are already 0..149, so both
        lsr     a                       ;   bands are already 0..OCCB_N-1 and
        lsr     a                       ;   neither needs a range test.
        sta     T0
        lda     OCCY1,x
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     T1
@band:  ldx     T0
        lda     OCCBN,x                 ; append at band*16 + count. The count
        inc     OCCBN,x                 ;   cannot reach 16: OCCN is capped at 16
        sta     T2                      ;   and an occluder is appended once per
        txa                             ;   band, so no capacity test is needed.
        asl     a
        asl     a
        asl     a
        asl     a
        clc
        adc     T2
        tay
        lda     T3
        sta     OCCBL,y
        inc     T0
        lda     T0
        cmp     T1
        beq     @band
        bcc     @band
        ldx     T3
        bne     @occ

@done:  ldx     #OCCB_N-1               ; deepest band, for the harness to report
        lda     #$00
:       cmp     OCCBN,x
        bcs     :+
        lda     OCCBN,x
:       dex
        bpl     :--
        sta     OCCBMAX
        rts
