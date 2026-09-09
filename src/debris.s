; =============================================================================
; debris.s - the ship comes apart
; =============================================================================
; The last life is gone. The puff a rock's death throws off goes on the ship's
; own position (ship.s ship_die), the outline stops being drawn, and in its
; place FOUR pieces of it drift out of where it was and tumble as they go.
; After DEBRIS_FRAMES they are simply not drawn any more.
;
; THE PIECES ARE THE SHIP, TORN IN FOUR PLACES, and that is the whole design.
; An earlier cut spawned six generic radiating strokes and it did not read - it
; looked like a starburst placed where a ship had been, because that is what it
; was. SHIP_SHAPE (shapes.s) is a closed ring of fourteen vertices, and the
; table below cuts that ring into four RUNS, each drawn as an open polyline:
;
;   0..5    the port nozzle pod, whole
;   5,6,7   the nose, from the pod's aft corner over the point and down
;   7..12   the starboard nozzle pod, whole
;   12,13,0 the tail spike
;
; Consecutive runs SHARE their end vertex, so the four together are the same
; fourteen segments the intact hull draws - not one edge more or fewer. A pod
; comes off as a pod, which is the thing to see: a recognisable part of the
; ship you were flying, spinning away, rather than an anonymous stick.
;
; Nothing is authored here beyond the four cut points: change the ship in the
; shape editor and the wreck changes with it, in step, for free.
;
; This is also why there is no animation table and no animation editor. The
; whole of the motion is four constants below and one add per piece per frame;
; a keyframed version would be kilobytes of data per ship, would need a tool to
; author it, and would still have to interpolate - which is the multiply this
; does not do.
;
; ONE COMMAND PER PIECE, and CPU1 does no per-vertex transform. $4E POLYGON16
; with N's top bit set is an OPEN polyline (gpu_os.s "POLYGON FAMILY"), so a run
; of K vertices is K-1 segments and no closing edge - the same flag shots.s
; already sets for a bullet, there with K = 2. The GPU is handed the piece's
; pivot, its own tumble ANGLE, the frame's SCALE and the run's offsets, and does
; the rotate and the scale itself. Four commands, at most 19 bytes each.
;
; SCREEN-ANCHORED, NOT WORLD-ANCHORED. The offsets below are full-res SCREEN
; pixels from where the ship's centre is drawn, not world units, so no piece
; ever goes through view_xform or zoom_fb. It is free, and it is also right:
; the throttle walks itself back to rest from the moment the ship dies (input.s
; throttle_rest), so the world slides to a halt underneath a wreck that stays
; put, which is what the death of an Asteroids ship looks like.
;
; The one thing that follows from that anchor and is NOT corrected: the SPREAD
; is not scaled by the zoom, only each piece's own shape is (the GPU's SCALE).
; smul16q7 cannot take 128 - its magnitude is seven bits, main.s's own note on
; TPQ says so - so scaling the offsets would need the reciprocal-table
; treatment for a correction that is shrinking to nothing anyway: ZEASH is
; easing back to 1:1 over exactly these frames. Revisit if the death ever has
; to happen at a held zoom.
; =============================================================================

DEBRIS_N      = 4               ; pieces - the four runs in DBRUN_* below

; THE FOUR NUMBERS BELOW ARE ONE SETTING, NOT FOUR. The wreck went from 45
; frames to 60 to 120 while it was being flown, and each time the other three
; had to move with the duration or the break-up changed shape rather than
; pacing. The rule:
;
;   radius reached = |c| * (1 + DEBRIS_FRAMES * DEBRIS_K / 256)
;   tumble         = DEBRIS_FRAMES * DEBRIS_SPIN, in brad (256 = one turn)
;
; So HALVING K and SPIN while DOUBLING FRAMES is the same break-up in slow
; motion - same distance, same amount of tumble, twice the time to read it.
; Raising K without touching FRAMES is what makes the pieces FLY further.
DEBRIS_FRAMES = 120             ; how long the wreck is drawn, ~2.0 s. TUNE
                                ;   HERE - the game-over banner waits on it
DEBRIS_K      = 11              ; outward speed: a piece's velocity is its own
                                ;   pivot offset times this, as an 8.8 fraction
                                ;   - so v = |c| * 11/256 px a frame, and the
                                ;   four pivots sit 8..11 px out, which is why
                                ;   they leave together but not in step. Over
                                ;   DEBRIS_FRAMES that carries them from ~11 px
                                ;   out to ~68 - about the 64 the wreck was
                                ;   asked to reach
DEBRIS_JIT    = 32              ; ...and +/-this (8.8) on each velocity
                                ;   COMPONENT, which is what stops the four
                                ;   reading as one hull being inflated: a pure
                                ;   radial scale-up of a shape is still that
                                ;   shape. It scales with K for a reason - at
                                ;   64 against this K it is larger than the
                                ;   smallest launch component (the pods' 22)
                                ;   and would throw a piece sideways faster
                                ;   than it was ever aimed
DEBRIS_SPIN   = 2               ; +/-this brad a frame of tumble, so a piece
                                ;   turns up to ~94% of a revolution before it
                                ;   goes - just under one, which is what keeps
                                ;   the tumble reading as a tumble rather than
                                ;   as a piece that came back to where it began

; --- state, in the free RAM above the radar's enemy table ($6F50 on; thrust.s
;     starts at $7000). Twelve arrays of stride 8 rather than four records, so
;     every access is an indexed load with the piece number in X and nothing
;     multiplies. ---------------------------------------------------------
DBCX        = $6F50             ; the piece's PIVOT, signed bytes: the centre of
DBCY        = $6F58             ;   its own bounding box in the hull's frame.
                                ;   The GPU rotates about it, and it is also the
                                ;   direction the piece was launched in
DBPXL       = $6F60             ; where the piece is now, signed 8.8 FULL-RES
DBPXH       = $6F68             ;   screen px from the ship's own drawn centre
DBPYL       = $6F70
DBPYH       = $6F78
DBVXL       = $6F80             ; ...and how far it moves a frame, same units
DBVXH       = $6F88
DBVYL       = $6F90
DBVYH       = $6F98
DBANG       = $6FA0             ; its tumble, brad - handed straight to the GPU
DBSPN       = $6FA8             ; ...and the signed brad a frame it turns by
DBN         = $6FB0             ; frames of wreck left, 0 = nothing to draw
DBI         = $6FB1             ; the piece walk's cursor (X is not free across
                                ;   prng, and the vertex walk wants its own)
DBV         = $6FB2             ; the vertex walk's cursor: a BYTE offset into
                                ;   SHIP_SHAPE, wrapped at 2*SHIP_VN
DBJ         = $6FB3             ; ...and vertices left in this run
DBW         = $6FB4             ; the write cursor into PBUF
DBMIN       = $6FB5             ; the bounding box being measured, EXCESS-128
DBMAX       = $6FB6             ;   (see debris_pivot)
DBC         = $6FB7             ; the pivot that came out of it
DBT0        = $6FB8             ; db_scale's shifting multiplicand...
DBT1        = $6FB9
DBR0        = $6FBA             ; ...and the product it and db_jitter leave
DBR1        = $6FBB
DBK         = $6FBC             ; ...and the shifting copy of DEBRIS_K
DBAX        = $6FBD             ; which axis debris_pivot is measuring, 0 or 1

; -----------------------------------------------------------------------------
; The routines below run at most ONCE a frame each, so they live in HIDATA at
; $A000 with ship.s's cull_window and input.s's do_boost, for the reason every
; one of those gives: CODE+CODE2+RODATA share one 16 KB window and this is not
; a hot per-object loop. See cart.cfg.
; -----------------------------------------------------------------------------
        .segment "HIDATA"

; --- where the hull tears -----------------------------------------------------
; A run is a START vertex and a COUNT, taken round the ring - the last run
; wraps past vertex 13 back to 0, which is what the &(2*SHIP_VN-1)-free wrap in
; the vertex walk is for. The assert is the sentence "the four pieces are the
; whole ship" in a form the assembler checks: a run of K vertices is K-1
; segments, and the four have to come to SHIP_VN of them.
DBRUN_ST:   .byte   0,  5,  7, 12       ; port pod, nose, starboard pod, tail
DBRUN_VN:   .byte   6,  3,  6,  3
        .assert (6-1)+(3-1)+(6-1)+(3-1) = SHIP_VN, error, "debris.s: the four runs no longer cover SHIP_SHAPE's ring exactly"

; -----------------------------------------------------------------------------
; debris_spawn - cut SHIP_SHAPE into the four runs and launch them.
; -----------------------------------------------------------------------------
; Called once, from ship_die, on the frame the last life goes.
; -----------------------------------------------------------------------------
debris_spawn:
        lda     #DEBRIS_FRAMES
        sta     DBN
        stz     DBI
@lp:    ldx     DBI

        ldy     #$00                    ; the fb_x axis: the pivot, then the
        jsr     debris_pivot            ;   launch velocity along it
        ldx     DBI
        lda     DBC
        sta     DBCX,x
        sta     DBPXH,x                 ; the piece starts exactly where it is
        stz     DBPXL,x
        lda     DBC
        jsr     db_scale
        ldx     DBI
        lda     DBR0
        sta     DBVXL,x
        lda     DBR1
        sta     DBVXH,x
        jsr     db_jitter
        ldx     DBI
        clc
        lda     DBVXL,x
        adc     DBR0
        sta     DBVXL,x
        lda     DBVXH,x
        adc     DBR1
        sta     DBVXH,x

        ldy     #$01                    ; ...and the fb_y axis, the same three
        jsr     debris_pivot            ;   steps
        ldx     DBI
        lda     DBC
        sta     DBCY,x
        sta     DBPYH,x
        stz     DBPYL,x
        lda     DBC
        jsr     db_scale
        ldx     DBI
        lda     DBR0
        sta     DBVYL,x
        lda     DBR1
        sta     DBVYH,x
        jsr     db_jitter
        ldx     DBI
        clc
        lda     DBVYL,x
        adc     DBR0
        sta     DBVYL,x
        lda     DBVYH,x
        adc     DBR1
        sta     DBVYH,x

        stz     DBANG,x                 ; a piece starts in the hull's own
        jsr     prng                    ;   attitude and tumbles from there
        and     #(2*DEBRIS_SPIN-1)      ; 0 .. 2*SPIN-1
        sec
        sbc     #DEBRIS_SPIN            ; ...centred: -SPIN .. SPIN-1
        bmi     :+                      ; ...and NEVER ZERO. The plain centred
        inc     a                       ;   range includes 0, and at SPIN = 2
:                                       ;   that is one piece in four left not
        ldx     DBI                     ;   tumbling at all - which reads as a
        sta     DBSPN,x                 ;   piece that got stuck, not as one
                                        ;   that happened to draw a low number.
                                        ;   Folding 0..SPIN-1 up to 1..SPIN
                                        ;   makes the range symmetric AND
                                        ;   punctured, for two bytes

        inc     DBI
        lda     DBI
        cmp     #DEBRIS_N
        beq     :+                      ; (a JMP: the body above is well past a
        jmp     @lp                     ;  relative branch's reach)
:       rts

; -----------------------------------------------------------------------------
; debris_pivot - DBC = the centre of run DBI's bounding box on axis Y (0 = the
; fb_x component of each vertex, 1 = fb_y).
; -----------------------------------------------------------------------------
; The BOUNDING BOX CENTRE and not the centroid, and that is worth a line: a
; centroid is a sum divided by the vertex count, and the counts here are 3, 4,
; 5 and 6 - three of them not powers of two. The box centre needs no division
; at all, lands within a pixel of the centroid on every one of these four runs,
; and is arguably the better pivot anyway: it is the middle of what the piece
; actually occupies rather than of where its corners happen to be dense.
;
; EXCESS-128. min/max are tracked with $80 added, so an UNSIGNED compare is the
; signed one - shapes.s allows a vertex anywhere in +/-127, so a plain CMP on
; the raw bytes would need the overflow dance and a difference of 254 makes
; that dance necessary. The bias survives the midpoint untouched, because
; ((a+128) + (b+128)) / 2 = (a+b)/2 + 128, so one SBC at the end undoes it -
; and the halving is a NINE-bit shift (the add's own carry rotated in), because
; two biased bytes sum past 255.
;
; Clobbers A, X, Y. Leaves the answer in DBC.
; -----------------------------------------------------------------------------
debris_pivot:
        sty     DBAX
        ldx     DBI
        lda     DBRUN_ST,x
        asl     a                       ; the run's first vertex, as a byte
        clc                             ;   offset, plus the axis
        adc     DBAX
        sta     DBV
        lda     DBRUN_VN,x
        sta     DBJ
        ldy     DBV
        lda     SHIP_SHAPE,y            ; open the box on the first vertex
        eor     #$80
        sta     DBMIN
        sta     DBMAX
@vlp:   ldy     DBV
        lda     SHIP_SHAPE,y
        eor     #$80
        cmp     DBMIN
        bcs     :+
        sta     DBMIN
:       cmp     DBMAX
        bcc     :+
        sta     DBMAX
:       lda     DBV                     ; on to the next vertex, wrapping the
        clc                             ;   ring - the tail run is 12, 13, 0
        adc     #2
        cmp     #2*SHIP_VN
        bcc     :+
        sec
        sbc     #2*SHIP_VN
:       sta     DBV
        dec     DBJ
        bne     @vlp
        clc
        lda     DBMIN
        adc     DBMAX
        ror     a                       ; the add's carry IS bit 8 - a nine-bit
                                        ;   unsigned halving, exact
        sec
        sbc     #$80                    ; ...and out of excess-128
        sta     DBC
        rts

; -----------------------------------------------------------------------------
; db_scale - A = a signed byte, out DBR0/DBR1 = A * DEBRIS_K, signed 16.
; -----------------------------------------------------------------------------
; Shift-and-add over the bits of DEBRIS_K rather than a qmul, for two reasons:
; the quarter-square table's >>7 would throw away exactly the bits that matter
; here (the product is small, and it IS the 8.8 fraction), and this way
; DEBRIS_K stays a plain tunable byte instead of being baked into a shift
; expression. It runs eight times in the life of a game. Clobbers A and X.
; -----------------------------------------------------------------------------
db_scale:
        sta     DBT0
        ldx     #$00                    ; sign-extend the multiplicand
        cmp     #$80
        bcc     :+
        ldx     #$FF
:       stx     DBT1
        stz     DBR0
        stz     DBR1
        lda     #DEBRIS_K
        sta     DBK
@lp:    lsr     DBK
        bcc     @noadd
        clc
        lda     DBR0
        adc     DBT0
        sta     DBR0
        lda     DBR1
        adc     DBT1
        sta     DBR1
@noadd: asl     DBT0
        rol     DBT1
        lda     DBK
        bne     @lp
        rts

; -----------------------------------------------------------------------------
; db_jitter - DBR0/DBR1 = a signed nudge in -DEBRIS_JIT .. DEBRIS_JIT-1.
; -----------------------------------------------------------------------------
db_jitter:
        jsr     prng
        and     #(2*DEBRIS_JIT-1)
        sec
        sbc     #DEBRIS_JIT
        sta     DBR0
        ldx     #$00
        cmp     #$80
        bcc     :+
        ldx     #$FF
:       stx     DBR1
        rts

; -----------------------------------------------------------------------------
; debris_tick - one frame of drift and tumble, and the countdown.
; -----------------------------------------------------------------------------
; Called from state_tick (gameover.s) only while DBN is nonzero, so there is no
; guard here. Two 16-bit adds and one byte add per piece: nine adds a frame,
; for 45 frames, once a game.
; -----------------------------------------------------------------------------
debris_tick:
        stz     DBI
@lp:    ldx     DBI
        clc
        lda     DBPXL,x
        adc     DBVXL,x
        sta     DBPXL,x
        lda     DBPXH,x
        adc     DBVXH,x
        sta     DBPXH,x
        clc
        lda     DBPYL,x
        adc     DBVYL,x
        sta     DBPYL,x
        lda     DBPYH,x
        adc     DBVYH,x
        sta     DBPYH,x
        clc                             ; the tumble wraps by the byte, which is
        lda     DBANG,x                 ;   what brad means
        adc     DBSPN,x
        sta     DBANG,x
        inc     DBI
        lda     DBI
        cmp     #DEBRIS_N
        bne     @lp
        dec     DBN
        rts

; -----------------------------------------------------------------------------
; do_debris - one OPEN POLYGON16 per piece.
; -----------------------------------------------------------------------------
; Called from the frame right after do_flames, and it READS WHAT DO_FLAMES
; LEFT: FLCXL/H and FLCYL/H are the ship's drawn screen centre, computed once a
; frame by thrust.s with the screen shake already folded in, and do_flames goes
; on computing them after the ship stops being drawn precisely so this can have
; them. Moving this call above do_flames would anchor the wreck to last frame's
; centre.
;
; The argument block is PBUF, the same one a rock, the ship and a bullet each
; fill in turn - see main.s's note on it. Nothing holds it across a call.
;
; The run's offsets are rebuilt from SHIP_SHAPE every frame rather than copied
; at spawn: it is one SBC per coordinate, 28 of them a frame, against 48 bytes
; of RAM to hold what the shape table already says.
; -----------------------------------------------------------------------------
do_debris:
        lda     SHIPGONE                ; THERE IS A WRECK exactly while the ship
        beq     @none                   ;   is gone and the game has not ended
        lda     GSTATE                  ;   yet - not "while DBN is nonzero".
        beq     :+                      ;   state_tick has already counted this
@none:  rts                             ;   frame down by the time this runs, so
:       stz     DBI                     ;   testing DBN would drop the wreck's
                                        ;   last frame. See state_tick's @arm
@lp:    ldx     DBI
        ldy     #$00                    ; CX = the ship's centre + this piece's
        lda     DBPXH,x                 ;   whole-pixel offset, sign-extended
        bpl     :+                      ;   into the 16-bit add
        dey
:       clc
        adc     FLCXL
        sta     PBUF+0
        tya
        adc     FLCXH
        sta     PBUF+1

        ldx     DBI
        ldy     #$00
        lda     DBPYH,x
        bpl     :+
        dey
:       clc
        adc     FLCYL
        sta     PBUF+2
        tya
        adc     FLCYH
        sta     PBUF+3

        ldx     DBI
        lda     DBANG,x                 ; ANGLE: its own tumble. Not HEAD-
        sta     PBUF+4                  ;   relative like a bullet's - the wreck
                                        ;   keeps the SCREEN attitude the ship
                                        ;   had, because the ship never spun on
                                        ;   screen either (11.14)
        lda     ZEASH                   ; SCALE: the same eased zoom everything
        sta     PBUF+5                  ;   else this frame is drawn at
        lda     DBRUN_VN,x
        ora     #$80                    ; OPEN: K vertices, K-1 segments, and no
        sta     PBUF+6                  ;   closing edge back to the start

        lda     DBRUN_ST,x              ; the run's vertices, each moved onto
        asl     a                       ;   the pivot the GPU will rotate about
        sta     DBV
        lda     DBRUN_VN,x
        sta     DBJ
        lda     #7                      ; ...written straight after the header
        sta     DBW
@vlp:   ldy     DBV
        ldx     DBI
        sec
        lda     SHIP_SHAPE+0,y
        sbc     DBCX,x
        ldy     DBW
        sta     PBUF,y
        ldy     DBV
        ldx     DBI
        sec
        lda     SHIP_SHAPE+1,y
        sbc     DBCY,x
        ldy     DBW
        sta     PBUF+1,y
        inc     DBW
        inc     DBW
        lda     DBV                     ; ...wrapping the ring, as the pivot
        clc                             ;   walk does
        adc     #2
        cmp     #2*SHIP_VN
        bcc     :+
        sec
        sbc     #2*SHIP_VN
:       sta     DBV
        dec     DBJ
        bne     @vlp

        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jsr     API_GPU_POLYGON16

        inc     DBI
        lda     DBI
        cmp     #DEBRIS_N
        beq     :+
        jmp     @lp                     ; (as above: too far for a branch)
:       rts

        .segment "CODE2"                ; back to the segment main.s included
                                        ;   this file inside
