; =============================================================================
; physics.s - rock against rock: who is touching whom, and what that does to
; their velocities. Split out of main.s for the same reason shapes.s and
; levels.s were: this is the file that is going to be re-tuned twenty times,
; and it should be possible to argue with it without reading the flight code.
;
; What is here:
;   do_collide   one object's whole collision job, called from do_objects
;   col_begin    the per-frame reset, called from do_objects' prologue
;
; What is NOT here yet, on purpose:
;   - SPIN TRANSFER (physics.md 4.3). A glancing hit should set a rock
;     tumbling, and it cannot: spin is AST_SPIN[class] today, a property of the
;     size class, not of the rock. That needs two OBJSPN pages and a two-line
;     change in do_objects' integrator, and it is a separate piece of work.
;   - BREAK-UP (physics.md 5). The threshold it wants is the relative normal
;     speed, which this file already computes and leaves in COL_VNL/COL_VNH -
;     but the fragments it wants come out of the shot-split routine, which does
;     not exist.
;   - THE SHIP'S HALF OF A SHIP-ROCK HIT. The ship is DETECTED here and nothing
;     more: no impulse, no knockback, it flies straight through. What a hit
;     does to the ship is not decided (it may simply be death), and the ship's
;     velocity is recomputed from the throttle every frame in do_ship anyway,
;     so an impulse written into VELX/VELY would be gone by the next frame.
;     SHIPHIT / SHIPHITN / SHIPHITC are the hooks whatever decides that will
;     read.
; =============================================================================
; THE SHAPE OF THE THING
;
; Four ideas do all the work, and three of them are about not multiplying.
;
; 1. THE COLLISION UNIT is 32 world units - one half-res pixel. That is the
;    unit SHAPE_OCC is already authored in, and design_technical 5.4 settles
;    that the collision circle and the star-occlusion disc must be the SAME
;    circle, so BODY_R below is SHAPE_OCC and not a second opinion about how
;    big a rock is. In these units every radius, every delta and every sum of
;    two radii is a signed byte, which is the whole reason the test below fits
;    in table lookups.
;
; 2. THE NARROW PHASE HAS NO MULTIPLY IN IT AT ALL. The quarter-square table is
;    f(x) = floor(x*x/4), and f(2a) = a*a EXACTLY for any a <= 127. So
;
;        |d|^2 = QS[2*|dx|] + QS[2*|dy|]        vs      QS[2*rsum]
;
;    is three 16-bit table reads, one add and one compare - about 40 cycles,
;    and qmul is never called. This matters because the narrow phase is what
;    every candidate pair pays, every frame, forever; the response is paid only
;    by the handful of pairs that are actually touching.
;
; 3. THE NORMAL IS d / rsum, NOT d / |d|. A true unit normal wants a square
;    root and a divide. But a collision is DETECTED at the moment of contact,
;    and at the moment of contact |d| is within a percent or two of rsum: a
;    rock moves at most ~13 world units a frame, which is 0.4 collision units
;    against radii of 3 to 39. rsum is a constant of the pair, so dividing by
;    it is one shift and one 64-byte table read.
;
;    The error this makes is not merely small, it is SAFE: deeper overlap makes
;    |n| shorter, which makes the impulse WEAKER. The cheat cannot ring, and it
;    cannot explode. What resolves a deep overlap is the positional separation
;    in step 4, not the impulse.
;
; 4. EVERY MASS IS A POWER OF TWO. m = 2^e, so
;
;        F_i = m_j/(m_i+m_j) = 1/(2^k + 1),   k = e_i - e_j
;
;    depends on NOTHING but the difference of the exponents. Nine values, one
;    table, read forwards for F_i and backwards for F_j - and the pairs sum to
;    exactly 128, so linear momentum is conserved to the bit and the field
;    cannot acquire a drift over a long game. It also means the positional
;    separation is mass-weighted by a SHIFT: displacement goes as 1/m = 2^-e.
;
;    This is the one thing this file asks of anything new that wants to
;    collide - enemies, debris, the ship: give it a power-of-two mass and a
;    radius in BODY_R, and every line below works on it unchanged.
; =============================================================================
; WHICH PAIRS GET TESTED
;
; The sector grid main.s already keeps, walked the way a grid is meant to be
; walked. For the object do_objects has just integrated, in cell c:
;
;   - the REST OF ITS OWN CELL'S LIST - the OBJNXT chain onwards, which costs
;     nothing because do_objects is standing on that pointer already;
;   - the whole of four cells: E, S, SE, SW.
;
; Four of the eight neighbours, not eight, and only the successors in the own
; cell: that is what makes every pair come up EXACTLY ONCE without a
; "seen this frame" flag anywhere. If j is east of i then i is west of j, and
; west is not in anybody's list.
;
; It is legal only because the biggest possible rsum (78) is smaller than a
; cell (128 collision units) - asserted below. Two objects further apart than
; one cell cannot touch, so a 3x3 neighbourhood is complete.
;
; And it runs for exactly the objects that pass do_objects' COARSE WINDOW,
; which is the "near the player" set: design_technical 11.6 freezes everything
; outside it, and a frozen rock is not simulated, so it does not collide
; either. An active rock at the edge of the window CAN reach a frozen one and
; kick it; that is correct, not a leak - momentum still balances and the frozen
; rock simply carries its new velocity until the player flies near enough for
; it to start integrating again.
; =============================================================================

; --- the bodies --------------------------------------------------------------
; Indexed by body class. 0..4 are the rock size classes, exactly as OBJSHP
; holds them; 5 upwards is where enemies go when there are enemies, at which
; point they join the grid, this loop and this response for free.
;
; BODY_R is SHAPE_OCC, the MEAN VERTEX radius - see design_technical 5.4 for
; why that and not the bounding radius. Keep the two in step by hand: the shape
; editor authors SHAPE_OCC per shape id, this table is per CLASS, and they
; agree today because all three variants of a class share one value.
COL_RMAX    = 39                ; the largest entry in BODY_R, for the asserts
CELL_CU     = 4096 / 32         ; a sector, in collision units

; The COARSE windows, in position-high-byte units - the cheap reject both
; tests open with. The widest pair of bodies that can touch is 2*COL_RMAX
; collision units apart, which is 2496 world units; the low bytes contribute
; at most 255 more, so anything further apart than this in the HIGH BYTE
; alone cannot be a hit and never has to have its 16-bit delta built. It is
; do_objects' own coarse reject, applied one level down, and it is what keeps
; a candidate pair that misses to about forty cycles instead of a hundred.
COL_HIW     = (2*COL_RMAX*32 + 255) / 256

        .assert 2*COL_RMAX <= 127, error, "physics.s: 2*rsum must index QS"
        .assert 2*COL_RMAX <= CELL_CU, error, "physics.s: rsum exceeds a sector, so 3x3 is not enough"

; --- tunables (physics.md's placeholders, living here until they are measured)
SHIP_RAD    = 8                 ; the ship's collision radius, collision units.
                                ;   SHIP_SHAPE reaches 25 full-res px at the
                                ;   nose and 14 at the beam; 8 cu = 16 full-res
                                ;   px is the same mean-vertex compromise the
                                ;   rocks get. (TBM - nothing is riding on it
                                ;   yet, the ship does not react.)
PHYS_SEP_SH = 2                 ; the separation push is n >> this, so the
                                ;   LIGHTEST body of a pair moves up to 128>>2
                                ;   = 32 world units (one half-res pixel) a
                                ;   frame and every heavier one moves 2^-de of
                                ;   that. (TBM)
PHYS_SEP_DP = 2                 ; ...and this much less shift when the pair is
                                ;   deeply inside each other, which is the
                                ;   spawn case: |d|^2 < rsum^2/4, i.e. more
                                ;   than half sunk. Four times the push, so a
                                ;   field scattered on top of itself untangles
                                ;   in a second or so instead of ten.
SHIP_HIW    = ((SHIP_RAD + COL_RMAX)*32 + 255) / 256
                                ; ...and the ship's own coarse window, in
                                ;   position-high-byte units - see COL_HIW
COL_MAX     = 8                 ; collisions RESOLVED per frame. Past this the
                                ;   pair is still counted and still detected,
                                ;   it just waits: the overlap does not go
                                ;   away, so nothing is lost by deferring it,
                                ;   and one pathological frame cannot eat the
                                ;   budget. Same bargain as PEND_MAX.

; Restitution is spent as SHIFTS, not as a multiply - see the (1+e) block in
; col_respond. e = 0.75 is p = vn + vn>>1 + vn>>2. Changing it to 0.5 is
; deleting the third term and to 0.875 is adding a fourth; none of them costs a
; multiply, which is the point of doing it this way.

; --- scratch ($620E-$623F, out of the block emit_ship's outline gave back) ----
COL_I       = $620E             ; the subject - a copy of OBJI, because qmul
COL_J       = $620F             ;   and smul16q7 both clobber X
COL_CI      = $6210             ; their body classes...
COL_CJ      = $6211
COL_EI      = $6212             ; ...and their mass exponents
COL_EJ      = $6213
COL_RS      = $6214             ; rsum, collision units
COL_TL      = $6215             ; to_cu's 16-bit input
COL_TH      = $6216
COL_DXC     = $6217             ; d = p[j] - p[i], collision units, signed
COL_DYC     = $6218
COL_ADX     = $6219             ; ...and its magnitudes, which is what indexes
COL_ADY     = $621A             ;   the quarter-square table
COL_DSL     = $621B             ; |d|^2
COL_DSH     = $621C
COL_RQL     = $621D             ; rsum^2
COL_RQH     = $621E
COL_S       = $621F             ; the shift that normalises rsum into [65,128]
COL_Q       = $6220             ; ...and the reciprocal that lands on
COL_NX      = $6221             ; the normal, signed Q0.7, 127 = one unit
COL_NY      = $6222
COL_VNL     = $6223             ; relative speed ALONG the normal, signed 8.8.
COL_VNH     = $6224             ;   Negative = closing. This is the number
                                ;   break-up will threshold on (physics.md 5)
COL_PL      = $6225             ; (1+e) * vn
COL_PH      = $6226
COL_IXL     = $6227             ; P = (1+e) * vn * n, the shared impulse
COL_IXH     = $6228
COL_IYL     = $6229
COL_IYH     = $622A
COL_AXL     = $622B             ; A = F_i * P, the subject's half of it
COL_AXH     = $622C
COL_AYL     = $622D
COL_AYH     = $622E
COL_FI      = $622F             ; F_i, Q0.7
COL_BASE    = $6230             ; the separation shift both bodies start from
COL_SHI     = $6231             ; ...and the two they end up with
COL_SHJ     = $6232
COL_C0      = $6233             ; the subject's cell, and the row below it
COL_C1      = $6234
COL_T0      = $6235             ; general scratch
COL_T1      = $6236
COL_T2      = $6237
COL_W0      = $6240             ; the neighbour walk's own byte, held only
                                ;   across the six instructions that build
                                ;   a cell index - so it survives nothing,
                                ;   which is exactly why it is not COL_T0

; --- what the frame can be asked about afterwards ----------------------------
COL_N       = $6238             ; collisions RESOLVED this frame, 0..COL_MAX
COL_HITS    = $6239             ; ...and DETECTED, which can be more
COL_TOTL    = $623A             ; detected since boot, 16-bit - the number the
COL_TOTH    = $623B             ;   headless soak (physics.md 8) watches
SHIPHIT     = $623C             ; the first rock touching the ship this frame,
                                ;   $FF if none. NOTHING acts on it yet
SHIPHITN    = $623D             ; how many are touching it this frame
SHIPHITCL   = $623E             ; ...and how many FRAMES since boot had at
SHIPHITCH   = $623F             ;   least one, 16-bit

; -----------------------------------------------------------------------------
; col_begin - the per-frame reset. Called from do_objects, before the walk.
; -----------------------------------------------------------------------------
col_begin:
        stz     COL_N
        stz     COL_HITS
        stz     SHIPHITN
        lda     #$FF
        sta     SHIPHIT
        rts

; -----------------------------------------------------------------------------
; do_collide - one object's whole collision job. X and OBJI = the object,
; already integrated; PXL/PXH, PYL/PYH = its offset from the ship.
; -----------------------------------------------------------------------------
; Called from the middle of do_objects' cell walk, at the one point in the
; frame where all three things it needs are in hand at once: the object has
; moved, its cell cursor is parked in GCELL, and the ship delta has just been
; subtracted for the transform. The ship test below is free because of that
; last one - PXL..PYH is the delta it would otherwise have to compute.
;
; Clobbers A, X, Y and everything qmul and smul16q7 clobber. Preserves OBJI,
; GCELL, GNEXT and PXL..PYH, which is what do_objects needs back.
; -----------------------------------------------------------------------------
do_collide:
        lda     OBJI
        sta     COL_I
        tax
        lda     OBJSHP,x                ; the body class IS the size class,
        sta     COL_CI                  ;   until there are enemies

        jsr     ship_test

        ldx     COL_I                   ; its own cell's list, from the
        lda     OBJNXT,x                ;   SUCCESSOR on - the pair (a,b) is
        cmp     #$FF                    ;   tested by whichever of them the
        beq     @nself                  ;   list reaches first, and only then
        jsr     scan_list
@nself:
        ; ...then four of the eight neighbours. Y wraps by the byte, X by
        ; masking the low nibble: the torus again. Spelled out rather than run
        ; through a helper because the answer is USUALLY "empty" - 120 rocks
        ; over 256 cells - and a cell that costs a jsr, a helper and two rts to
        ; find empty costs more than the four indices are worth. Inline, an
        ; empty neighbour is one lda and one cmp.
        ldx     COL_I
        lda     OBJCEL,x
        sta     COL_C0
        clc
        adc     #$10
        sta     COL_C1                  ; the row below

        lda     COL_C0                  ; E
        inc     a
        and     #$0F
        sta     COL_W0
        lda     COL_C0
        and     #$F0
        ora     COL_W0
        tax
        lda     CELLHD,x
        cmp     #$FF
        beq     @noe
        jsr     scan_list
@noe:
        ldx     COL_C1                  ; S
        lda     CELLHD,x
        cmp     #$FF
        beq     @nos
        jsr     scan_list
@nos:
        lda     COL_C1                  ; SE
        inc     a
        and     #$0F
        sta     COL_W0
        lda     COL_C1
        and     #$F0
        ora     COL_W0
        tax
        lda     CELLHD,x
        cmp     #$FF
        beq     @nose
        jsr     scan_list
@nose:
        lda     COL_C1                  ; SW
        dec     a
        and     #$0F
        sta     COL_W0
        lda     COL_C1
        and     #$F0
        ora     COL_W0
        tax
        lda     CELLHD,x
        cmp     #$FF
        beq     @nosw
        jmp     scan_list
@nosw:  rts

; scan_list - A = the first object in a list, or $FF. Tests each against the
; subject. The successor is read from the object BEFORE pair_test runs, for the
; same reason do_objects reads it before the body: nothing in here relinks a
; cell, but nothing in here should have to promise that either.
scan_list:
@lp:    cmp     #$FF
        beq     @done
        sta     COL_J
        jsr     pair_test
        ldx     COL_J
        lda     OBJNXT,x
        bra     @lp
@done:  rts

; -----------------------------------------------------------------------------
; pair_test - COL_I against COL_J. Detect, and if it is a hit, respond.
; -----------------------------------------------------------------------------
pair_test:
        ldx     COL_I                   ; THE COARSE REJECT FIRST, off the
        ldy     COL_J                   ;   position high bytes alone: no 16-bit
        lda     OBJXH,y                 ;   delta, no radius lookup, no jsr. Most
        sec                             ;   of what the cell walk hands over dies
        sbc     OBJXH,x                 ;   here, and this is all it costs
        clc
        adc     #COL_HIW
        cmp     #2*COL_HIW+1
        bcc     :+
@nohi:  rts                             ; the reject's own exit - @no is a whole
:       lda     OBJYH,y                 ;   response away by now
        sec
        sbc     OBJYH,x
        clc
        adc     #COL_HIW
        cmp     #2*COL_HIW+1
        bcs     @nohi

        ldx     COL_J
        lda     OBJSHP,x
        sta     COL_CJ
        tax
        lda     BODY_R,x
        ldx     COL_CI
        clc
        adc     BODY_R,x
        sta     COL_RS

        ldx     COL_I                   ; dx = X[j] - X[i], 16-bit. On a torus
        ldy     COL_J                   ;   the wrap IS the subtract: a plain
        sec                             ;   16-bit sbc read as signed already
        lda     OBJXL,y                 ;   gives the SHORTEST way round, so
        sbc     OBJXL,x                 ;   there is no seam to test for
        sta     COL_TL
        lda     OBJXH,y
        sbc     OBJXH,x
        jsr     to_cu
        bcs     @no
        sta     COL_DXC
        jsr     absa
        cmp     COL_RS                  ; the box reject, which is what nearly
        beq     :+                      ;   every candidate dies on
        bcs     @no
:       sta     COL_ADX

        ldx     COL_I
        ldy     COL_J
        sec
        lda     OBJYL,y
        sbc     OBJYL,x
        sta     COL_TL
        lda     OBJYH,y
        sbc     OBJYH,x
        jsr     to_cu
        bcs     @no
        sta     COL_DYC
        jsr     absa
        cmp     COL_RS
        beq     :+
        bcs     @no
:       sta     COL_ADY

        jsr     dsq                     ; the circle, in table reads
        bcs     @no

        inc     COL_HITS                ; detected. Counted whether or not the
        inc     COL_TOTL                ;   budget lets it be answered - the
        bne     :+                      ;   soak test wants the honest number
        inc     COL_TOTH
:       lda     COL_N
        cmp     #COL_MAX
        bcs     @no                     ; over budget: it waits a frame
        inc     COL_N
        jmp     col_respond
@no:    rts

; -----------------------------------------------------------------------------
; dsq - |d|^2 from COL_ADX/COL_ADY, rsum^2 from COL_RS, compared.
; Carry CLEAR = overlapping. Leaves rsum^2 in COL_RQL/H for the deep test.
; -----------------------------------------------------------------------------
; f(x) = floor(x*x/4) and therefore f(2a) = a*a, exactly, for a <= 127. Three
; reads of a table that is in RAM for the rotation anyway, and not one multiply
; in the routine every candidate pair in the world runs through.
; -----------------------------------------------------------------------------
dsq:
        lda     COL_ADX
        asl     a
        tax
        lda     QSL,x
        sta     COL_DSL
        lda     QSH,x
        sta     COL_DSH
        lda     COL_ADY
        asl     a
        tax
        clc
        lda     QSL,x
        adc     COL_DSL
        sta     COL_DSL
        lda     QSH,x
        adc     COL_DSH
        sta     COL_DSH

        lda     COL_RS
        asl     a
        tax
        lda     QSL,x
        sta     COL_RQL
        lda     QSH,x
        sta     COL_RQH

        lda     COL_DSL                 ; carry clear = |d|^2 < rsum^2
        cmp     COL_RQL
        lda     COL_DSH
        sbc     COL_RQH
        rts

; -----------------------------------------------------------------------------
; to_cu - a signed 16-bit WORLD delta (A = high, COL_TL = low) into collision
; units. -> A = the delta >> 5, carry SET if it did not fit in a byte.
; -----------------------------------------------------------------------------
; The reject is the same shape as do_objects' coarse window and for the same
; reason: anything 4096 world units away cannot be touching anything (the
; largest rsum is 78 units = 2496), so the high byte alone settles it before
; the shifts are worth doing.
; -----------------------------------------------------------------------------
to_cu:
        sta     COL_TH
        clc
        adc     #$10
        cmp     #$20
        bcs     @out
        asl     COL_TL                  ; >>5 is <<3 read as the high byte
        rol     COL_TH
        asl     COL_TL
        rol     COL_TH
        asl     COL_TL
        lda     COL_TH
        rol     a
        clc
        rts
@out:   sec
        rts

; absa - A = |A|, for a signed byte.
absa:
        bpl     @done
        eor     #$FF
        inc     a
@done:  rts

; -----------------------------------------------------------------------------
; ship_test - is the subject touching the ship? Detection ONLY.
; -----------------------------------------------------------------------------
; PXL/PXH, PYL/PYH are already rock-minus-ship in world units, computed by
; do_objects for the view transform, so this costs the two shifts and the
; circle and nothing else. The ship is not in the object pool and does not need
; to be for this: it is one body against the list the walk is handing us
; anyway, so it needs no grid.
;
; Nothing is done with the answer. When something is - death, damage, a
; knockback - it reads SHIPHIT, and it will want the closing speed too, which
; is the block in col_respond down to COL_VNL/COL_VNH with the ship's
; VELXL/VELXH standing in for OBJVX.
; -----------------------------------------------------------------------------
ship_test:
        lda     PXH                     ; the coarse reject again, and the ship's
        clc                             ;   window is narrower than a rock pair's
        adc     #SHIP_HIW               ;   because the ship is small: nothing
        cmp     #2*SHIP_HIW+1           ;   further than SHIP_RAD + COL_RMAX away
        bcs     @no                     ;   can possibly be touching it
        lda     PYH
        clc
        adc     #SHIP_HIW
        cmp     #2*SHIP_HIW+1
        bcs     @no

        ldx     COL_CI
        lda     BODY_R,x
        clc
        adc     #SHIP_RAD
        sta     COL_RS

        lda     PXL
        sta     COL_TL
        lda     PXH
        jsr     to_cu
        bcs     @no
        jsr     absa
        cmp     COL_RS
        beq     :+
        bcs     @no
:       sta     COL_ADX

        lda     PYL
        sta     COL_TL
        lda     PYH
        jsr     to_cu
        bcs     @no
        jsr     absa
        cmp     COL_RS
        beq     :+
        bcs     @no
:       sta     COL_ADY

        jsr     dsq
        bcs     @no

        lda     SHIPHITN                ; the first one of the frame is what
        bne     :+                      ;   SHIPHIT names, and it is also what
        lda     COL_I                   ;   ticks the frame counter
        sta     SHIPHIT
        inc     SHIPHITCL
        bne     :+
        inc     SHIPHITCH
:       inc     SHIPHITN
@no:    rts

; -----------------------------------------------------------------------------
; col_respond - two bodies are overlapping. Bounce them, then push them apart.
; -----------------------------------------------------------------------------
; The order matters and so does the fact that BOTH halves always run. The
; impulse is skipped when the pair is already parting (vn >= 0) - without that
; test a pair that has just bounced gets hit again on the next frame while it
; is still overlapping, which is exactly how two rocks stick together. The
; SEPARATION is not skipped, ever: it is the only thing that can resolve a pair
; that was spawned inside another, where there is no approach to answer.
; -----------------------------------------------------------------------------
col_respond:
        ; --- the normal, n = d / rsum -----------------------------------------
        ; Normalise rsum into (64,128] first so the reciprocal is a 64-byte
        ; table instead of a divide, and shift |d| by the same amount so the
        ; ratio is unchanged. rsum >= 6 for any real pair and the loop
        ; terminates at 128 for anything down to 1, so it cannot run away.
        ldy     #$00
        lda     COL_RS
@norm:  cmp     #65
        bcs     @normd
        asl     a
        iny
        bra     @norm
@normd: sty     COL_S
        sec
        sbc     #65
        tax
        lda     RECIP64,x
        sta     COL_Q

        lda     COL_ADX
        jsr     nrm
        ldy     COL_DXC                 ; the sign comes back off the delta -
        bpl     :+                      ;   the magnitude went through the
        eor     #$FF                    ;   table, the sign never did
        inc     a
:       sta     COL_NX
        lda     COL_ADY
        jsr     nrm
        ldy     COL_DYC
        bpl     :+
        eor     #$FF
        inc     a
:       sta     COL_NY

        lda     COL_NX                  ; two bodies at EXACTLY the same place
        ora     COL_NY                  ;   have no normal. The scatter can do
        bne     :+                      ;   that, so pick a direction rather
        lda     #127                    ;   than divide by nothing and leave
        sta     COL_NX                  ;   them welded together forever
:
        ; --- relative velocity along it ---------------------------------------
        ldx     COL_I
        ldy     COL_J
        sec
        lda     OBJVXL,y
        sbc     OBJVXL,x
        sta     MAL
        lda     OBJVXH,y
        sbc     OBJVXH,x
        sta     MAH
        lda     COL_NX
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     COL_VNL
        lda     MAH
        sta     COL_VNH

        ldx     COL_I
        ldy     COL_J
        sec
        lda     OBJVYL,y
        sbc     OBJVYL,x
        sta     MAL
        lda     OBJVYH,y
        sbc     OBJVYH,x
        sta     MAH
        lda     COL_NY
        sta     MB
        jsr     smul16q7
        clc
        lda     MAL
        adc     COL_VNL
        sta     COL_VNL
        lda     MAH
        adc     COL_VNH
        sta     COL_VNH
        bmi     :+                      ; parting already: separate, do not hit
        jmp     col_separate
:

        ; --- P = (1+e) * vn * n -----------------------------------------------
        ; (1+e) as shifts, so restitution costs nothing and can be retuned by
        ; adding or deleting a term. 1.75 = 1 + 1/2 + 1/4.
        lda     COL_VNL
        sta     COL_T0
        lda     COL_VNH
        sta     COL_T1
        jsr     asr_t                   ; t = vn >> 1
        clc
        lda     COL_VNL
        adc     COL_T0
        sta     COL_PL
        lda     COL_VNH
        adc     COL_T1
        sta     COL_PH
        jsr     asr_t                   ; t = vn >> 2
        clc
        lda     COL_PL
        adc     COL_T0
        sta     COL_PL
        lda     COL_PH
        adc     COL_T1
        sta     COL_PH

        lda     COL_PL
        sta     MAL
        lda     COL_PH
        sta     MAH
        lda     COL_NX
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     COL_IXL
        lda     MAH
        sta     COL_IXH
        lda     COL_PL
        sta     MAL
        lda     COL_PH
        sta     MAH
        lda     COL_NY
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     COL_IYL
        lda     MAH
        sta     COL_IYH

        ; --- A = F_i * P ------------------------------------------------------
        ; F_j is never looked up: it is 1 - F_i, so the partner's share is
        ; A - P, which is a subtract instead of two more 16-bit multiplies.
        jsr     mass_fi
        lda     COL_IXL
        sta     MAL
        lda     COL_IXH
        sta     MAH
        lda     COL_FI
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     COL_AXL
        lda     MAH
        sta     COL_AXH
        lda     COL_IYL
        sta     MAL
        lda     COL_IYH
        sta     MAH
        lda     COL_FI
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     COL_AYL
        lda     MAH
        sta     COL_AYH

        ldx     COL_I                   ; v[i] += A
        clc
        lda     OBJVXL,x
        adc     COL_AXL
        sta     OBJVXL,x
        lda     OBJVXH,x
        adc     COL_AXH
        sta     OBJVXH,x
        clc
        lda     OBJVYL,x
        adc     COL_AYL
        sta     OBJVYL,x
        lda     OBJVYH,x
        adc     COL_AYH
        sta     OBJVYH,x

        sec                             ; v[j] += A - P
        lda     COL_AXL
        sbc     COL_IXL
        sta     COL_T0
        lda     COL_AXH
        sbc     COL_IXH
        sta     COL_T1
        ldx     COL_J
        clc
        lda     OBJVXL,x
        adc     COL_T0
        sta     OBJVXL,x
        lda     OBJVXH,x
        adc     COL_T1
        sta     OBJVXH,x
        sec
        lda     COL_AYL
        sbc     COL_IYL
        sta     COL_T0
        lda     COL_AYH
        sbc     COL_IYH
        sta     COL_T1
        ldx     COL_J
        clc
        lda     OBJVYL,x
        adc     COL_T0
        sta     OBJVYL,x
        lda     OBJVYH,x
        adc     COL_T1
        sta     OBJVYH,x
        ; fall through

; -----------------------------------------------------------------------------
; col_separate - push the pair apart along n, mass-weighted, with no multiply.
; -----------------------------------------------------------------------------
; Displacement goes as 1/m and every mass is a power of two, so the weighting
; is a SHIFT: the lightest body of the pair moves by n >> PHYS_SEP_SH and every
; heavier one by a further factor of two per exponent. A 16-pixel chip shoves a
; 192 sixteen times less than the 192 shoves it, which is what the eye expects
; and what the mass table already says.
;
; This runs on every overlapping frame, impulse or no impulse, and it is
; deliberately a small constant rather than the true overlap: it cannot
; overshoot, it cannot jitter (there is no gravity holding anything in
; contact - once the pair is apart it stops being found), and a pair spawned
; inside each other simply walks out over a second, off camera, before the
; player ever sees it.
;
; It moves positions after do_objects has already decided whether the object
; changed cell. One frame of stale membership, on a body 32 world units past a
; 4096-unit boundary - the same bargain cell_flush already takes.
; -----------------------------------------------------------------------------
col_separate:
        ldx     COL_CI
        lda     BODY_ME,x
        sta     COL_EI
        ldx     COL_CJ
        lda     BODY_ME,x
        sta     COL_EJ
        cmp     COL_EI                  ; T2 = min(e_i, e_j): the LIGHTEST body
        bcc     @emin                   ;   is the one that moves the full step
        lda     COL_EI
@emin:  sta     COL_T2

        lda     #PHYS_SEP_SH
        sta     COL_BASE
        lda     COL_RQH                 ; deeply sunk? |d|^2 < rsum^2 / 4
        lsr     a
        sta     COL_T1
        lda     COL_RQL
        ror     a
        sta     COL_T0
        lsr     COL_T1
        ror     COL_T0
        lda     COL_DSL
        cmp     COL_T0
        lda     COL_DSH
        sbc     COL_T1
        bcs     @shifts
        lda     #PHYS_SEP_SH - PHYS_SEP_DP
        bpl     :+
        lda     #$00
:       sta     COL_BASE

@shifts:
        sec
        lda     COL_EI
        sbc     COL_T2
        clc
        adc     COL_BASE
        sta     COL_SHI
        sec
        lda     COL_EJ
        sbc     COL_T2
        clc
        adc     COL_BASE
        sta     COL_SHJ

        lda     COL_NX                  ; i moves along -n...
        ldy     COL_SHI
        jsr     sep_shr
        eor     #$FF
        inc     a
        ldx     COL_I
        jsr     posx_add
        lda     COL_NY
        ldy     COL_SHI
        jsr     sep_shr
        eor     #$FF
        inc     a
        ldx     COL_I
        jsr     posy_add

        lda     COL_NX                  ; ...and j along +n
        ldy     COL_SHJ
        jsr     sep_shr
        ldx     COL_J
        jsr     posx_add
        lda     COL_NY
        ldy     COL_SHJ
        jsr     sep_shr
        ldx     COL_J
        jmp     posy_add

; -----------------------------------------------------------------------------
; the small change
; -----------------------------------------------------------------------------

; nrm - A = a magnitude 0..rsum -> A = that magnitude * 128 / rsum, 0..127.
; The shift and the reciprocal were both picked in col_respond; all that is
; left here is one quarter-square product and the clamp that keeps the result
; inside what smul16q7 will take as a Q0.7 multiplier.
nrm:
        ldy     COL_S
        beq     @go
@lp:    asl     a
        dey
        bne     @lp
@go:    sta     MQA
        lda     COL_Q
        sta     MQB
        jsr     pmul6
        cmp     #$80
        bcc     @done
        lda     #$7F
@done:  rts

; pmul6 - MQA * MQB, both magnitudes, sum <= 255, >> 6 -> A.
; qmul's shape with two differences: the RAW quarter-square table rather than
; the +64 one (the rounding term is for a >>7, and this is a >>6, so taking it
; would be a systematic overestimate of every normal), and one more shift.
pmul6:
        clc
        lda     MQA
        adc     MQB
        tax
        sec
        lda     MQA
        sbc     MQB
        bcs     :+
        eor     #$FF                    ; carry is clear here, so this is the
        adc     #$01                    ;   two's-complement negate
:       tay
        sec
        lda     QSL,x
        sbc     QSL,y
        sta     MQR
        lda     QSH,x
        sbc     QSH,y
        asl     MQR
        rol     a
        asl     MQR
        rol     a
        rts

; asr_t - COL_T0/T1 >>= 1, arithmetic. CMP #$80 puts the sign into carry.
asr_t:
        lda     COL_T1
        cmp     #$80
        ror     COL_T1
        ror     COL_T0
        rts

; sep_shr - A >>= Y, arithmetic, for a signed byte.
sep_shr:
        cpy     #$00
        beq     @done
@lp:    cmp     #$80
        ror     a
        dey
        bne     @lp
@done:  rts

; mass_fi - COL_FI = m_j / (m_i + m_j), Q0.7, from the two mass exponents.
; k is clamped rather than asserted: nothing today can produce |k| > 4, but the
; table is only nine wide and an enemy class added later should bend the ratio,
; not index off the end of it.
mass_fi:
        ldx     COL_CI
        lda     BODY_ME,x
        sta     COL_T0
        ldx     COL_CJ
        lda     COL_T0
        sec
        sbc     BODY_ME,x               ; k = e_i - e_j
        clc
        adc     #4
        bpl     :+
        lda     #$00
:       cmp     #9
        bcc     :+
        lda     #8
:       tax
        lda     MASSF,x
        sta     COL_FI
        rts

; posx_add / posy_add - X = object, A = a signed byte of WORLD units, added to
; the 16-bit integer part of its position. The fraction is left alone: a
; separation step is a correction, not motion, and it has no sub-unit part.
posx_add:
        sta     COL_T0
        ldy     #$00
        cmp     #$80
        bcc     :+
        ldy     #$FF
:       clc
        lda     OBJXL,x
        adc     COL_T0
        sta     OBJXL,x
        tya
        adc     OBJXH,x
        sta     OBJXH,x
        rts

posy_add:
        sta     COL_T0
        ldy     #$00
        cmp     #$80
        bcc     :+
        ldy     #$FF
:       clc
        lda     OBJYL,x
        adc     COL_T0
        sta     OBJYL,x
        tya
        adc     OBJYH,x
        sta     OBJYH,x
        rts

; =============================================================================
; Tables
; =============================================================================
        .segment "RODATA"

; The collision circle, per body class, in collision units. This is SHAPE_OCC -
; the same circle the star mask uses - so what looks solid and what actually
; hits you are one shape. See design_technical 5.4.
BODY_R:     .byte   39, 26, 13, 7, 3

; Mass, as an EXPONENT: m = 2^e. Each class is half the one above it, which is
; what makes MASSF nine bytes instead of a matrix. Anything added here must be
; a power of two as well - that is the whole contract.
;                       192 128  64  32  16
BODY_ME:    .byte         4,  3,  2,  1,  0

; F = 1/(2^k + 1) in Q0.7, indexed by k+4, k = e_i - e_j.
; Read forwards for the subject's share and BACKWARDS for the partner's, since
; F_j(k) = F_i(-k). Every mirrored pair sums to exactly 128 - 120+8, 114+14,
; 102+26, 85+43, 64+64 - so the impulse conserves linear momentum to the bit
; and a field left alone for an hour does not acquire a drift.
;                     -4   -3   -2   -1    0   +1   +2   +3   +4
MASSF:      .byte    120, 114, 102,  85,  64,  43,  26,  14,   8

; 8192 / r for r = 65..128 - the reciprocal that turns d/rsum into a shift and
; a lookup. The range is exactly one octave, which is why 64 entries cover
; every rsum there can ever be: col_respond shifts rsum into it first.
; Written as an expression, not as numbers, so there is nothing here to mistype.
RECIP64:
        .repeat 64, i
        .byte   8192 / (i + 65)
        .endrepeat

        .segment "CODE"
