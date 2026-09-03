; =============================================================================
; objects.s - the field: what is out there, and what it costs to keep it there
; =============================================================================
; Fixed decision 6: every object keeps persistent parameters across the WHOLE
; world - nothing is spawned on approach and nothing is forgotten when it goes
; off camera. What is conditional is the work, not the existence: an object
; outside the cull window is frozen, not simulated.
;
; That makes the first gate the most expensive line in the program, because
; every object pays it whether or not it is anywhere near. do_objects is
; written around that fact, and design_technical 4.5b is the argument.
;
; The broad phase is a sector grid indexed by masked high bits of position
; (fixed decision 7): init_cells buckets the field once at load, and after that
; a cell change is a relink, deferred to cell_flush so the walk cannot trip
; over an object it has already moved.
; =============================================================================
; -----------------------------------------------------------------------------
; rock_kin — the part of a rock a level does not get to choose. Y = the object
; slot and OBJSHP,y already set; A and X are clobbered, Y is not.
; -----------------------------------------------------------------------------
; A level says WHICH rock and WHERE. How that rock moves is a property of its
; size class, so it is read here out of AST_VEL / AST_PHASE rather than stored
; per rock: one of four drift vectors per class by (slot & 3), one of eight
; starting spin phases by (slot & 7). Both hardcoded, so the field is identical
; on every run and any oddity in it can be reproduced — and two rocks of the
; same class in the same level still differ from each other.
; -----------------------------------------------------------------------------
rock_kin:
        lda     #$00                    ; (stz has no abs,y mode)
        sta     OBJXF,y
        sta     OBJYF,y
        sta     OBJANGF,y

        lda     OBJSHP,y                ; velocity: AST_VEL[class][slot & 3],
        asl     a
        asl     a                       ;   four bytes per vector, four vectors
        asl     a                       ;   per class -> class * 16
        asl     a
        sta     LVTMP
        tya
        and     #$03
        asl     a
        asl     a
        clc
        adc     LVTMP
        tax
        lda     AST_VEL+0,x
        sta     OBJVXL,y
        lda     AST_VEL+1,x
        sta     OBJVXH,y
        lda     AST_VEL+2,x
        sta     OBJVYL,y
        lda     AST_VEL+3,x
        sta     OBJVYH,y

        tya                             ; a spread of starting spin phases, also
        and     #$07                    ;   from a table rather than the LFSR
        tax
        lda     AST_PHASE,x
        sta     OBJANG,y
        rts

; -----------------------------------------------------------------------------
; load_level — build one level's opening state. X = the level (0..NLEVELS-1).
; -----------------------------------------------------------------------------
; Everything a level SAYS about its own start is in levels.s; this is the code
; that acts on it. Two passes over the object slots, in the order that file
; documents: the per-class SCATTER first, then the HAND-PLACED rocks appended
; after it. NROCK is what the two came to, and init_cells buckets exactly that
; many — the slots past it are never linked into the grid, so nothing in the
; frame ever looks at them and none of them has to be cleared.
;
; The scatter covers the WHOLE torus, not the area around the ship: a 16-bit
; world position is uniform by construction, so two random bytes per axis is the
; whole job — no boundary to keep away from and no rejection loop. What is NOT
; random any more is the SIZE. It used to be an eight-ticket draw through
; SHAPE_PICK, which gave the mix only in expectation; it is the pour below now,
; so a level that asks for four 192s gets four.
;
; Velocity and spin stay out of the level data entirely — see rock_kin.
load_level:
        stx     LVLIX

        lda     LVL_SHXL,x              ; the ship first: init_cells is about to
        sta     SHXL                    ;   bucket the field, and the very first
        lda     LVL_SHXH,x              ;   frame culls against the ship's own
        sta     SHXH                    ;   cell, so it has to already be where
        lda     LVL_SHYL,x              ;   the level put it
        sta     SHYL
        lda     LVL_SHYH,x
        sta     SHYH
        stz     SHXF
        stz     SHYF
        lda     LVL_SHHD,x
        sta     HEAD

        lda     LVL_SEEDL,x             ; the scatter is random in shape but not
        sta     PRNGL                   ;   in outcome: same level, same field,
        lda     LVL_SEEDH,x             ;   every run — so an arrangement can be
        sta     PRNGH                   ;   complained about and then rerolled

        lda     LVL_N192,x              ; the five counts, out of their per-level
        sta     SCATN+0                 ;   tables and into five CONSECUTIVE RAM
        lda     LVL_N128,x              ;   bytes, so the pour below can index
        sta     SCATN+1                 ;   them by class with no multiply
        lda     LVL_N64,x
        sta     SCATN+2
        lda     LVL_N32,x
        sta     SCATN+3
        lda     LVL_N16,x
        sta     SCATN+4

        stz     SLOT
        stz     SCATC                   ; pour class 0 (the 192s) first, one
                                        ;   class at a time. That makes the field
                                        ;   size-ordered by slot, which is what
                                        ;   AST_VEL's (slot & 3) wants: its four
                                        ;   vectors then spread across each
                                        ;   class instead of across the mix
@clslp: ldx     SCATC
        lda     SCATN,x
        beq     @clsnxt
        dec     SCATN,x

        ldy     SLOT                    ; Y survives prng (it clobbers A and X
        jsr     prng                    ;   only), so it stays the slot for the
        sta     OBJXL,y                 ;   whole rock
        jsr     prng
        sta     OBJXH,y
        jsr     prng
        sta     OBJYL,y
        jsr     prng
        sta     OBJYH,y
        lda     SCATC                   ; the class is the loop counter itself
        sta     OBJSHP,y
        jsr     prng                    ; which authored variant of that class -
        and     #$07                    ;   eight tickets over AST_TYPES values,
        tax                             ;   still a draw, because which variant
        lda     TYPE_PICK,x             ;   a rock wears is not something a level
        sta     OBJTYPE,y               ;   has an opinion about
        jsr     rock_kin
        inc     SLOT
        bra     @clslp
@clsnxt:
        inc     SCATC
        lda     SCATC
        cmp     #$05
        bne     @clslp

        ldx     LVLIX                   ; the hand-placed set-pieces, appended
        lda     LVL_ROCKN,x             ;   after the scatter. SCATC is done
        sta     SCATC                   ;   being a class index; it is the record
        beq     @done                   ;   countdown now
        lda     LVL_ROCKLO,x
        sta     T0
        lda     LVL_ROCKHI,x
        sta     T1

@plp:   ldy     #$05                    ; stage the record first: Y has to be the
:       lda     (T0),y                  ;   record cursor here and the object
        sta     LVREC,y                 ;   slot below, and it cannot be both
        dey
        bpl     :-
        ldy     SLOT
        lda     LVREC+0
        sta     OBJXL,y
        lda     LVREC+1
        sta     OBJXH,y
        lda     LVREC+2
        sta     OBJYL,y
        lda     LVREC+3
        sta     OBJYH,y
        lda     LVREC+4
        sta     OBJSHP,y
        lda     LVREC+5
        sta     OBJTYPE,y
        jsr     rock_kin
        inc     SLOT
        clc                             ; ...and on to the next six bytes
        lda     T0
        adc     #$06
        sta     T0
        bcc     :+
        inc     T1
:       dec     SCATC
        bne     @plp

@done:  lda     SLOT                    ; what the two passes came to. Enemies
        sta     NROCK                   ;   are authored in levels.s but not read
                                        ;   here yet — see radar.s load_foes.
        ; fall through: the field is placed, so bucket it. NOTHING may be put
        ; between this and init_cells - rock_kin sits ABOVE load_level for
        ; exactly that reason.

; -----------------------------------------------------------------------------
; init_cells — bucket the whole field into the sector grid, once.
; -----------------------------------------------------------------------------
; This is the only full pass over the field in the program. Afterwards the grid
; is maintained incrementally by the handful of rocks that are actually moving.
;
; It walks NROCK, what load_level actually placed, not NOBJ, which is only how
; many slots exist. That is the whole reason a level can be smaller than the
; array: an unplaced slot is never linked into a cell, and the cell lists are
; the only way anything in the frame reaches an object.
; -----------------------------------------------------------------------------
init_cells:
        lda     #$FF                    ; every cell empty
        ldx     #$00
:       sta     CELLHD,x
        inx
        bne     :-
        stz     PENDN
        stz     GPENDMX

        ldx     NROCK                   ; count down from it rather than up to
        beq     @none                   ;   it: dex-then-body needs no compare
@lp:    dex                             ;   against a variable, and an empty
        jsr     cell_of                 ;   field still has to be legal
        sta     OBJCEL,x
        tay
        lda     CELLHD,y                ; push at the head
        sta     OBJNXT,x
        txa
        sta     CELLHD,y
        cpx     #$00                    ; (the count can exceed 128, so bne on
        bne     @lp                     ;  the compare, not bpl on the dex)
@none:  rts

; -----------------------------------------------------------------------------
; cell_of — X = object, A = its cell index. Y is clobbered.
; -----------------------------------------------------------------------------
cell_of:
        lda     OBJXH,x
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     GTMP
        lda     OBJYH,x
        and     #$F0
        ora     GTMP
        rts

; -----------------------------------------------------------------------------
; cell_flush — apply the cell moves do_objects deferred.
; -----------------------------------------------------------------------------
; Deferred, not immediate, and the reason is the walk: a rock relinked into a
; cell the walk has not reached yet would be integrated and DRAWN a second time
; in the same frame. Applying the moves after the walk cannot do that. The cost
; of the delay is one frame of stale cell membership, on a rock 13 units past a
; 4096-unit boundary.
; -----------------------------------------------------------------------------
cell_flush:
        lda     PENDN
        beq     @done
@lp:    dec     PENDN
        ldx     PENDN
        lda     PEND,x
        sta     GOBJ
        tax

        ldy     OBJCEL,x                ; unlink from the cell it is in now
        lda     CELLHD,y
        cmp     GOBJ
        bne     @scan
        lda     OBJNXT,x                ; it was the head of that list
        sta     CELLHD,y
        bra     @link
@scan:  tax                             ; walk to the predecessor - it is in
        lda     OBJNXT,x                ;   there, so this always terminates
        cmp     GOBJ
        bne     @scan
        ldy     GOBJ
        lda     OBJNXT,y
        sta     OBJNXT,x

@link:  ldx     GOBJ                    ; ...and push it onto the new one
        jsr     cell_of
        sta     OBJCEL,x
        tay
        lda     CELLHD,y
        sta     OBJNXT,x
        txa
        sta     CELLHD,y

        lda     PENDN
        bne     @lp
@done:  rts

; -----------------------------------------------------------------------------
; do_objects — reject, then move, then transform the centre to the screen.
; -----------------------------------------------------------------------------
; Three gates, and the whole cost of the field is decided by the first one:
;
;   all NOBJ           a high-byte reject against the ship. Nothing else.
;   ~14 that pass      integrate position and spin, precise cull, rotate the
;                      CENTRE into screen coordinates
;   3-6 on camera      rotate the OUTLINE - and that happens in emit_asteroids,
;                      not here
;
; The first gate used to run second, after every rock in the world had been
; integrated. That was the largest single item in the frame.
; -----------------------------------------------------------------------------
do_objects:
        lda     CULHI                   ; the coarse window, doubled once here
        asl     a                       ;   rather than per object
        clc
        adc     #$01
        sta     CULHI2
        stz     OCCN
        stz     VISN
        jsr     col_begin               ; physics.s: clear this frame's hit
        jsr     add_ship_occluder       ;   counters before anything can raise
                                        ;   one
        jsr     add_radar_occluder      ; ...and the radar's disc, which is as
                                        ;   permanent as the ship's and takes
                                        ;   its slot before any rock can - see
                                        ;   radar.s

        ; The sector walk. CULHI is the coarse window in position-high-byte
        ; units and a cell is 16 of those, so the window reaches (CULHI >> 4)
        ; cells each way; +1 rounds outward, which over-covers by up to a whole
        ; cell. That slack is what keeps finding 11's staleness argument true
        ; with room to spare: the camera moves at most 93 units a frame and the
        ; margin is thousands.
        lda     SHXH
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     GX0                     ; (the ship's cell column, for now)
        lda     SHYH
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     GY0
        lda     CULHI
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        inc     a
        sta     GTMP                    ; R
        asl     a
        inc     a
        sta     GN                      ; 2R+1 columns, and as many rows
        sec
        lda     GX0
        sbc     GTMP
        and     #$0F                    ; the mask IS the torus
        sta     GX0
        sec
        lda     GY0
        sbc     GTMP
        and     #$0F
        sta     GY0
        stz     GCELLS
        stz     GDY

        ; A row of the window is a contiguous run of cell indices, EXCEPT where
        ; it crosses column 15 into column 0. Splitting it into the two runs up
        ; front is what lets the cell cursor be a plain INX: masking per cell
        ; cost about as much as the object reject it was there to avoid, which
        ; is how the first version of this managed to be slower than no grid at
        ; all.
@rowlp: clc
        lda     GY0
        adc     GDY
        and     #$0F
        asl     a
        asl     a
        asl     a
        asl     a
        sta     GROW

        lda     #16                     ; how much of the run fits before the
        sec                             ;   column wrap...
        sbc     GX0
        cmp     GN
        bcc     :+
        lda     GN
:       sta     GRUN
        lda     GN                      ; ...and what is left over for column 0
        sec
        sbc     GRUN
        sta     GRUN2
        lda     GX0
        ora     GROW
        tax

@cellp: inc     GCELLS
        lda     CELLHD,x
@lp:    cmp     #$FF                    ; walk this cell's list
        bne     :+
        jmp     @cellnext
:       stx     GCELL                   ; the run cursor parks over the body
        sta     OBJI
        tax
        lda     OBJNXT,x                ; the successor, read BEFORE the body -
        sta     GNEXT                   ;   see cell_flush
        ldx     OBJI
        ; The coarse reject comes FIRST, before the rock has even moved. Any
        ; object whose high byte is more than CULHI from the ship's cannot
        ; survive the precise cull below, and an object that is not drawn does
        ; not need to have moved: on a torus with no off-camera collisions,
        ; nothing in the machine can observe where a distant rock has drifted
        ; to. So a far rock costs this test and nothing else - about 40 cycles
        ; instead of 160 - and starts moving again the moment you fly near it.
        ;
        ; Reading the position one frame stale is what makes this safe to do in
        ; this order: a rock moves at most ~13 world units a frame and the gap
        ; between this window (CULHI * 256) and the precise cull (CULRL/H) is
        ; at least 128 units at EVERY zoom step, so nothing can cross both
        ; tests inside one frame - see the rounding note on ZOOM_CULLH.
        lda     OBJXH,x
        sec
        sbc     SHXH
        clc
        adc     CULHI
        cmp     CULHI2
        bcc     :+
        jmp     @cull
:       lda     OBJYH,x
        sec
        sbc     SHYH
        clc
        adc     CULHI
        cmp     CULHI2
        bcc     :+
        jmp     @cull
:
        ; Past the coarse reject, so this rock is near enough to matter. Only
        ; now does it move: position, then spin.
        ldy     #$00                    ; integrate X: 16.8 += signed 8.8
        bit     OBJVXH,x
        bpl     :+
        ldy     #$FF
:       clc
        lda     OBJXF,x
        adc     OBJVXL,x
        sta     OBJXF,x
        lda     OBJXL,x
        adc     OBJVXH,x
        sta     OBJXL,x
        tya
        adc     OBJXH,x
        sta     OBJXH,x

        ldy     #$00                    ; integrate Y
        bit     OBJVYH,x
        bpl     :+
        ldy     #$FF
:       clc
        lda     OBJYF,x
        adc     OBJVYL,x
        sta     OBJYF,x
        lda     OBJYL,x
        adc     OBJVYH,x
        sta     OBJYL,x
        tya
        adc     OBJYH,x
        sta     OBJYH,x

        ldy     OBJSHP,x                ; angle += the class's rate, 8.8 brad per
        tya                             ;   frame. The integer part is a brad and
        asl     a                       ;   wraps by itself, which is the whole
        tay                             ;   of "mod one turn"
        clc
        lda     OBJANGF,x
        adc     AST_SPIN,y
        sta     OBJANGF,x
        lda     OBJANG,x
        adc     AST_SPIN+1,y
        sta     OBJANG,x

        jsr     cell_of                 ; it moved, so it may have left its cell
        cmp     OBJCEL,x
        beq     :+
        ldy     PENDN
        cpy     #PEND_MAX
        bcs     :+                      ; full: it queues again next frame, and
        txa                             ;   a cell is 4096 units wide, so being
        sta     PEND,y                  ;   one frame late is 13 units of wrong
        inc     PENDN
        lda     PENDN
        cmp     GPENDMX
        bcc     :+
        sta     GPENDMX
:
        sec                             ; world delta — wrap-correct for free
        lda     OBJXL,x
        sbc     SHXL
        sta     PXL
        lda     OBJXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     OBJYL,x
        sbc     SHYL
        sta     PYL
        lda     OBJYH,x
        sbc     SHYH
        sta     PYH

        ; COLLIDE, here and not a line later. This object has moved, its cell
        ; cursor is parked in GCELL, and the ship delta above is exactly what
        ; the ship test wants - the one point in the frame where all three are
        ; in hand at once. It runs for everything past the COARSE window, not
        ; just what survives the cull below: a rock must finish bouncing while
        ; it is still off screen, or it arrives already inside its neighbour.
        ; See physics.s - it clobbers X and leaves PXL..PYH and OBJI alone.
        jsr     do_collide

        lda     PXL                     ; cull well outside the screen, so the
        ldy     PXH                     ;   transform only runs on what matters
        jsr     in_range
        bcc     :+
        jmp     @cull
:       lda     PYL
        ldy     PYH
        jsr     in_range
        bcc     :+
        jmp     @cull
:
        jsr     view_xform              ; -> VXL/VXH, VYL/VYH, still world units

        ; ...and then the ZOOM, which is the same shape of product as the
        ; rotation and uses the same trick on it: one table pair built from the
        ; reciprocal, two lookups and an add per axis. Doing it HERE and not by
        ; folding the scale into the rotation tables is what lets the starfield
        ; and the radar keep those tables unscaled, which they must - neither of
        ; them zooms.
        lda     VYL                     ; fb_x = FBCX + round(vy * z / 16)
        sta     MAL
        lda     VYH
        sta     MAH
        jsr     zoom_ma
        jsr     asr4r
        clc                             ; fb_x = FBCX + offset + vy: an object at
        lda     MAL                     ;   the ship's own position must land ON
        adc     #<FBCX                  ;   the ship, or the world pivots about
        sta     FXL                     ;   the screen centre and turning strafes
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
        lda     VXL                     ; fb_y = FBCY - round(vx * z / 16)
        sta     MAL
        lda     VXH
        sta     MAH
        jsr     zoom_ma
        sec                             ; fb_y = FBCY - round((vx*z - lean)/16):
        lda     MAL                     ;   the cross-axis camera lean joins the
        sbc     SHOFXQ                  ;   value here, so the single rounding in
        sta     MAL                     ;   asr4r covers both terms
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

        ldy     VISN                    ; it survived: append it to the list
        cpy     #VIS_MAX
        bcs     @next                   ; ...unless the list is full
        lda     OBJI
        sta     VISIDX,y
        lda     FXL
        sta     VSXL,y
        lda     FXH
        sta     VSXH,y
        lda     FYL
        sta     VSYL,y
        lda     FYH
        sta     VSYH,y
        inc     VISN
@cull:                                  ; (culled needs no store at all now)
@next:
        ldx     GCELL
        lda     GNEXT
        jmp     @lp

@cellnext:
        inx
        dec     GRUN
        beq     :+
        jmp     @cellp
:       lda     GRUN2                   ; the part of the row past column 15
        beq     @rownext
        sta     GRUN
        stz     GRUN2
        lda     GROW
        tax
        jmp     @cellp

@rownext:
        inc     GDY
        lda     GDY
        cmp     GN
        bcs     :+
        jmp     @rowlp
:       jmp     cell_flush              ; ...and only now may the lists change

; -----------------------------------------------------------------------------
; in_range — A/Y = signed 16 world units. Carry CLEAR inside +/-CULL_R.
; -----------------------------------------------------------------------------
; CULL_R is not "a bit more than the screen": it is what the WORST CASE needs.
; A rock is on camera when its rotated offset lands inside the screen grown by
; its own radius, and the cull runs on the UNROTATED world delta, so it has to
; pass anything whose rotation could still get there. Screen half-height 200 px
; + the ship's 120 px of speed offset + a 96 px rock radius is 416; the other
; axis needs 150 + 96 = 246; the vector that has to survive is therefore up to
; sqrt(416^2 + 246^2) = 483 px long, and a single world axis can carry all of
; it. At the old 400 px the biggest rocks popped in and out at the screen edges,
; which is exactly the failure the cull radius exists to prevent.
; -----------------------------------------------------------------------------
; CULRL/CULRH is this frame's radius and CUL2 is 2*it + 1; both are set in
; do_ship from ZOOM_CULLR, because pulling the camera back widens the window.
; The test is the biased range compare: delta is in [-CULR, +CULR] exactly when
; (delta + CULR) read UNSIGNED is below 2*CULR + 1. That is complete on its own -
; a delta below -CULR wraps the sum up into the high half, which is above CUL2
; and rejected by the same compare - so there is no sign test here. There used to
; be a BMI, and at RZ 64 it was wrong: CUL2 is 34,177 there, so a legitimate
; delta of +15,680 or more makes a sum with bit 15 set and the BMI threw it away.
; Only at the widest zoom (every other rung has CUL2 below $8000) and only ~440 px
; out, so all it ever cost was a big rock popping at the very edge of the screen
; at top speed - but it was still a hole in the one test that decides what exists.
in_range:
        clc
        adc     CULRL
        sta     T0
        tya
        adc     CULRH
        tay
        cpy     CUL2H
        bcc     @in
        bne     @out
        lda     T0
        cmp     CUL2L
        bcc     @in
@out:   sec
        rts
@in:    clc
        rts

; -----------------------------------------------------------------------------
; emit_asteroids - draw the outline of every rock that is actually on camera.
; -----------------------------------------------------------------------------
; do_objects has already put a full-res screen centre in OBJSX/OBJSY for every
; rock inside the coarse cull, which is a band 400 px wide around the ship - far
; more than the screen. This is the precise pass: it halves the centre into the
; line ops' half-res space, tests the rock's bounding square against the field,
; and only then pays for the rotation.
;
; There is ONE draw path (design_technical 11.13). The rock goes out as a centre,
; an angle, a scale and the shape AS AUTHORED, and the GPU rotates, scales and
; clips it - so "crosses an edge" stopped being a case to handle. What the cull
; above still buys is not the drawing but the PPRAM: 2N+8 bytes of a 2047-byte
; frame, and a budget unit, spent on a rock nobody can see.
; -----------------------------------------------------------------------------
emit_asteroids:
        stz     ADRAWN
        stz     VISI
        lda     #AST_BUDGET
        sta     ABUDGET
@lp:    lda     VISI
        cmp     VISN
        beq     @done
        lda     ADRAWN
        cmp     #AST_MAX
        bcs     @done
        lda     ABUDGET                 ; out of frame? stop drawing rocks. The
        beq     @done                   ;   ones that go are the ones the visible
        jsr     one_asteroid            ;   list happened to reach last
        inc     VISI
        bra     @lp
@done:  rts

one_asteroid:
        ldy     VISI                    ; the list entry names its object
        lda     VISIDX,y
        sta     OBJI
        tax
        ldy     OBJSHP,x                ; the SIZE CLASS - CLASS_BASE (shapes.s)
        lda     CLASS_BASE,y            ;   turns it into the first shape id of
        clc                             ;   that class, so this needs no multiply
        adc     OBJTYPE,x               ; ...+ which authored variant, picked at
        tay                             ;   init - Y is now the SHAPE ID, and
        sty     ASHP                    ;   everything below reads it, qmul
        lda     SHAPE_N,y               ;   clobbers X and Y so it is read FIRST
        sta     AVN
        lda     SHAPE_LO,y
        sta     SHPL
        lda     SHAPE_HI,y
        sta     SHPH

        lda     SHAPE_R,y               ; both radii shrink with the zoom - the
        sta     MQA                     ;   bounding one because it decides what
        lda     ZOOMH                   ;   is on screen, the suppression one
        sta     MQB                     ;   because a rock that draws smaller has
        jsr     qmul                    ;   to hide stars over a smaller disc
        sta     ARAD
        ldy     ASHP
        lda     SHAPE_OCC,y
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul
        sta     AOCR

        lda     #$02                    ; AVSTEP: how far apart the vertices we
        sta     AVSTEP                  ;   use sit in the shape, in bytes -
                                        ;   always 2. Used to drop to an
                                        ;   authored reduced outline below
                                        ;   LOD_R; retired, rocks stay full
                                        ;   detail at every size now (11.9).

        ldy     VISI                    ; half-res centre = the full-res screen
        lda     VSXH,y                  ;   position >> 1, arithmetic (cmp #$80
        cmp     #$80                    ;   puts the sign bit into carry)
        ror     a
        sta     CX2H
        lda     VSXL,y
        ror     a
        sta     CX2L
        lda     VSYH,y
        cmp     #$80
        ror     a
        sta     CY2H
        lda     VSYL,y
        ror     a
        sta     CY2L

        ; The cull is still worth its ~200 cycles even though the GPU rejects a
        ; missed figure for ~480 of its own: what it really saves is the 2N+8
        ; PPRAM bytes, which are the scarcer resource (2047 for the whole frame),
        ; and a budget unit that a rock nobody can see would have spent. What it
        ; no longer decides is HOW to draw - there is one path now, and "crosses
        ; an edge" is not a case any more.
        lda     CX2L                    ; the precise cull, one axis at a time
        ldy     CX2H
        ldx     #199
        jsr     span_test
        cmp     #$02
        bne     :+
        rts                             ; wholly off this axis: nothing to draw
:       lda     CY2L
        ldy     CY2H
        ldx     #149
        jsr     span_test
        cmp     #$02
        bne     :+
        rts
:
        jsr     add_disc                ; the stars go out under this rock

        ; ---------------------------------------------------------------------
        ; The argument block. Seven bytes of header and then the shape's own
        ; signed bytes, copied. That is the whole of CPU1's per-vertex work now:
        ; two moves, no multiply, no sign, no 16-bit add, no outcode.
        ; ---------------------------------------------------------------------
.if ROCK_FAMILY = 2
        ldy     VISI                    ; the FULL-res centre, straight out of the
        lda     VSXL,y                  ;   view transform. CX2/CY2 are that >> 1
        sta     PBUF+0                  ;   and are still built above, because the
        lda     VSXH,y                  ;   cull and the star-suppression disc are
        sta     PBUF+1                  ;   half-res whatever the rock is drawn
        lda     VSYL,y                  ;   with - the screen is the same screen.
        sta     PBUF+2                  ;   Only the DRAWING gets the extra bit.
        lda     VSYH,y
        sta     PBUF+3
.else
        lda     CX2L
        sta     PBUF+0
        lda     CX2H
        sta     PBUF+1
        lda     CY2L
        sta     PBUF+2
        lda     CY2H
        sta     PBUF+3
.endif

        ldx     OBJI                    ; ONE angle: the spin and the camera's
        sec                             ;   rotation compose, so a spinning rock
        lda     OBJANG,x                ;   is one byte, not two transforms - and
        sbc     HEAD                    ;   the GPU's ANGLE has the same sense and
        sta     PBUF+4                  ;   direction as API_SIN / API_COS

        lda     ZEASH                   ; SCALE. The GPU folds this into the same
        sta     PBUF+5                  ;   rotate it already pays for per rock -
                                        ;   see the note below - so unlike the
                                        ;   ZS table there is no rebuild to gate
                                        ;   and nothing is bought by reading the
                                        ;   RUNG (ZOOMH) instead of the smooth
                                        ;   ease itself. Reading ZOOMH here was
                                        ;   the visible "scale pops, everything
                                        ;   else is smooth" defect: a rock's
                                        ;   SIZE has no per-frame motion of its
                                        ;   own to hide a step in, unlike its
                                        ;   position. Q0.7 with 128 = 1:1, and
                                        ;   the camera never pushes in, so it is
                                        ;   never above 128 and never hits the
                                        ;   GPU's clamp. Folding the zoom into
                                        ;   the trig by hand is gone: on that
                                        ;   side the scale is free, because
                                        ;   composing it with the rotation costs
                                        ;   the four products the rotation was
                                        ;   paying anyway.
        lda     AVN
        sta     PBUF+6
        asl     a                       ; ...and 2N is the copy's stop
        sta     AVN2

        ldx     #$00                    ; X walks the block, Y walks the shape -
        ldy     #$00                    ;   AVSTEP apart, which is how the level
@vlp:   lda     (SHPL),y                ;   of detail is expressed now: a smaller
.if SHAPE_16X                           ;   figure is simply a shorter command
        asl     a                       ; half-res shape -> full-res offsets
.endif
        sta     PBUF+7,x
        iny
        inx
        lda     (SHPL),y
.if SHAPE_16X
        asl     a
.endif
        sta     PBUF+7,x
        inx
        tya                             ; Y is on dy; the next pair starts one
        clc                             ;   back plus the LOD stride
        adc     AVSTEP
        tay
        dey
        cpx     AVN2
        bne     @vlp

        inc     ADRAWN
        sec                             ; charge the budget: the vertices, and
        lda     ABUDGET                 ;   nothing else. A rock that straddles an
        sbc     AVN                     ;   edge is one command like any other now,
        bcs     :+                      ;   so the old clipping surcharge is gone.
        lda     #$00
:       sta     ABUDGET

        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jmp     ROCK_BUILDER

; -----------------------------------------------------------------------------
; span_test - where does [C-R, C+R] sit against the field 0..LIM?
; -----------------------------------------------------------------------------
;   in:  A / Y = C (signed 16), ARAD = R, X = LIM
;   out: A = 0 wholly inside, 1 crosses an edge, 2 misses the field entirely
; -----------------------------------------------------------------------------
span_test:
        sta     SPL
        sty     SPH
        stx     SPLIM
        clc                             ; hi = C + R
        lda     SPL
        adc     ARAD
        sta     SPHIL
        lda     SPH
        adc     #$00
        sta     SPHIH
        bmi     @miss                   ; the whole span is off the low edge
        sec                             ; lo = C - R
        lda     SPL
        sbc     ARAD
        sta     SPLOL
        lda     SPH
        sbc     #$00
        sta     SPLOH
        bmi     @cross                  ; lo < 0 <= hi: it straddles that edge
        bne     @miss                   ; lo >= 256, and LIM is at most 199
        lda     SPLOL
        cmp     SPLIM
        beq     :+
        bcs     @miss                   ; lo > LIM: off the high edge
:       lda     SPHIH
        bne     @cross
        lda     SPHIL
        cmp     SPLIM
        beq     @inside
        bcs     @cross
@inside:
        lda     #$00
        rts
@cross: lda     #$01
        rts
@miss:  lda     #$02
        rts

        .segment "RODATA"
; =============================================================================
; Asteroids
; =============================================================================
; FIVE SIZES at 192, 128, 64, 32 and 16 full-res pixels across, each with
; AST_TYPES hand-authored outline variants so a field of same-size rocks does
; not read as stamped from one mould. The outlines themselves, the per-shape
; radii and the authored reduced (LOD) outlines all live in shapes.s now - see
; its header - so the shape editor (tools/shape_editor.py) has one file to
; read and write. How MANY of each size a field holds lives in levels.s, per
; level. What stays here is a rock's BEHAVIOUR - how it drifts and how it spins
; - which is a property of the size class and not of either file.
;
; The vertex COUNT falls with the size - 12, 10, 8, 6, 5 - because a rock 16 px
; across cannot show more than about five corners anyway, and the small classes
; are the ones that multiply when rocks start breaking. Five is the floor: four
; reads as a diamond, which the eye recognises as a shape rather than as a rock.
; At ~530 cycles a vertex this is also the cheapest LOD knob in the file.

; Which authored variant a scattered rock wears - eight tickets drawn with three
; bits of the LFSR, spread evenly over AST_TYPES (shapes.s). Must have exactly
; AST_TYPES distinct values across its eight entries or a variant goes unused;
; tools/shape_editor.py rewrites this line when a variant is added.
;
; The SIZE mix used to be a table just like it, SHAPE_PICK. It is gone: eight
; tickets only ever gave a mix in expectation, and a level wants to state a
; count. See LVL_N192..LVL_N16 in levels.s, and load_level, which pours them.
TYPE_PICK:  .byte  0, 1, 2, 0, 1, 2, 0, 1

; Drift velocities, signed 8.8 world units per frame. 16 units = 1 full-res pixel
; and the frame is 60.317 Hz, so 1.0 here is 3.77 px/s. FOUR hand-written vectors
; per size class, picked by (index & 3): hardcoded, not random, so the field is
; the same every run and any oddity in it can be reproduced. Big rocks are slow;
; the 16-px chips are the fastest thing in the world that is not the ship.
;                 vx        vy            class / px/s
AST_VEL:
        .word    $0220,  $0090           ; 192:  8.0 / 1.3
        .word   $FF20,   $01C0           ;      -3.4 / 6.6
        .word    $0100,  $FE60           ;       3.8 / -6.1
        .word   $FEB0,   $FF60           ;      -5.0 / -2.4
        .word    $03B0,  $FF40           ; 128: 14.0 / -2.8
        .word   $FD60,   $0180           ;     -10.0 / 5.7
        .word    $0140,  $0340           ;       4.7 / 12.3
        .word   $FE80,   $FD90           ;      -5.6 / -9.3
        .word    $0000,  $05D0           ;  64:  0.0 / 22.0
        .word   $FA80,   $0100           ;     -20.6 / 3.8
        .word    $0480,  $FBC0           ;      17.0 / -15.9
        .word    $0300,  $0500           ;      11.3 / 18.9
        .word    $0900,  $0180           ;  32: 34.0 / 5.7
        .word   $F800,   $FE00           ;     -30.2 / -7.5
        .word    $0200,  $F780           ;       7.5 / -32.1
        .word   $FC40,   $0740           ;     -14.2 / 27.4
        .word    $0D50,  $FE00           ;  16: 50.0 / -7.5
        .word   $F480,   $0400           ;     -43.4 / 15.1
        .word    $0500,  $0C00           ;      18.9 / 45.3
        .word   $FA00,   $F600           ;     -22.6 / -37.7

; Spin rates, signed 8.8 BRAD per frame, one per size class. A full turn is 256
; brad, so 1.00 here is 256 frames = 4.2 s per revolution. The sign is the
; direction, and it alternates on purpose so a screen with several sizes on it
; reads as a tumbling field rather than a carousel.
;                    brad/frame   seconds per revolution
AST_SPIN:
        .word   $0018           ;   0.09    45 s   - the 192 barely turns
        .word   $FFB0           ;  -0.31    13.6 s
        .word   $0090           ;   0.56     7.5 s
        .word   $FF00           ;  -1.00     4.2 s
        .word   $0180           ;   1.50     2.8 s - the chips are frantic

; Starting spin phases, spread over the circle by (index & 7). Hardcoded for the
; same reason the velocities are: a reproducible field.
AST_PHASE:  .byte   0, 32, 64, 96, 128, 160, 192, 224

        .segment "CODE"
