; =============================================================================
; base.s - the human base: an animated shape like the gate's, and a wall round it
; =============================================================================
; design_technical.md 11.46 (mining stations) and 11.48 (this file). A base is
; scenery and an obstacle: it never moves, it is not in the object pool, and
; nothing can enter it - not the ship, not a rock, not an enemy. It is placed
; per level (BASE_* below).
;
; THE SHAPE IS AN ENEMY APPEARANCE, EA_BASE in enemies.s, authored and animated
; in tools/enemy_editor.py exactly like EA_GATE - and DRAWN BY THE GATE'S OWN
; ROUTINE. Six equilateral triangles, each the gate's largest, laid out as a
; hexagon with their apexes towards the middle and 16 px between them; frame f
; draws triangle f smaller, and the playlist walks the six frames, 60 game frames
; each. That is all this file has to say about the shape: its vertices are data
; in the RAM under the cartridge window (SHAPES) with every other outline, and
; nothing here draws a line. gate.s's gb_draw is the drawing (one DOT_POLYGON a
; part, at the object's centre, turned by -HEAD because the base is fixed in a
; world the camera turns) and gate.s's gr_pos is the radar's cell; the numbers
; are authored in HALF-RES UNITS, so that a vertex offset - a signed byte - can
; reach the 154 px the hexagon does, and GBSH = 0 tells gb_draw not to halve the
; scale the way the gate's full-res numbers want.
;
; WHAT THIS FILE IS, then: the base's place in the world (BASE_*, per level), its
; playlist step (the gate's own, done again over its own two bytes), a disc and a
; wall for each triangle, and the radar mark.
;
; A CIRCLE PER TRIANGLE, on its vertices. Each of the six triangles is a SEGMENT
; with a circle - its centre at the triangle's, its edge through the triangle's
; three corners (41 half-res px, 41 collision units: EA_BASE's circumradius, 40.3,
; worked out of its vertices and rounded up to hold them). It is the WALL (bs_keep) always, and the star-occlusion disc
; (occlude.s add_disc, a rock's way) only when a triangle is missing: while all six
; stand the stars get ONE disc, on the anchor, round the whole hexagon (77 half-res
; px, its farthest corner), because the hexagon is nearly a circle and six discs
; cost the star loop six bounding boxes that cover most of the screen. A circle
; through the corners covers the whole triangle, so no star shows through one; it
; reaches 20 half-res px past the middle of each edge, a halo of about 40 px that
; the hexagon's own edges never fill. A segment has a bit in BSLIVE, and a segment
; that is not live has no disc, no wall and no drawing (gb_draw's mask, GBMK):
; nothing clears a bit yet, but the base will be shot at and lose its triangles one
; by one, and that is all it will take.
;
; THE RADAR MARK is six dots, the hexagon's own shape,
;
;         . .
;        .   .          in the player's screen axes, never turned,
;         . .           and pinned to the rim, blinking, when out of reach
;
; through gate.s's gr_pos, which is what puts the gate's mark there.
;
; NOTHING CAN ENTER A LIVE SEGMENT. Every mover meets the same circles, each grown by
; the mover's own radius, so its EDGE and not its centre stops at the line. One
; routine, bs_keep, and three movers that differ only in what they do with their
; velocity:
;
;   a ROCK   is put back on the circle and its velocity into it reversed: a wall
;            of infinite mass (11.46)
;   an ENEMY is put back and its velocity into the circle taken away. It keeps
;            steering, so it slides along it; going round is the open part
;            (open_questions E11)
;   the SHIP is stopped BEFORE it moves, not after: bs_keep runs on where the
;            step would put it, and the velocity is corrected by however far it
;            was put back, so the ship ends on the circle and slides along it.
;            The star layers scroll off the throttle (SPD), not off the
;            velocity, so the braking is also taken off their travel (TRAV,
;            base_brake) or they would flow past a ship that is held
;
; HOW A CIRCLE PUSHES, WITHOUT A SQUARE ROOT. Distances are in collision units (32
; world units, a half-res px) so that two table lookups and an add are d^2 - the
; quarter-square table physics.s uses - compared with (41 + the mover's radius)^2.
; A mover that is inside is moved along the axis it is FARTHER from the centre on,
; to the first whole unit at which it is outside: a short search up the table. Both
; roundings are toward "inside" (a magnitude is floored), so a mover is never left
; in a circle, at the price of standing off it by up to a unit and a half (three
; px), and the velocity that is reversed or dropped is that axis's, not the true
; normal's. Circles overlap, so a push out of one can land in the next: the six are
; walked, up to six times. The middle of the hexagon is where they do not resolve:
; the circles leave one small pocket free there and a mover pushed out of one circle
; comes to rest in it with no way out (a rock the scatter dropped in the base did,
; and sat there jittering in a dump). A mover still being pushed after six passes is
; therefore PUT OUT of the base (bs_eject), past the farthest reach of any circle.
; A ship that is ALREADY inside - a teleport landed there, or the sector began
; there - is let out and not held: braked, it would be trapped. A BULLET, the
; player's or an enemy's, is stopped by the triangle itself (bs_shot) and not by
; its circle, and ends in a puff on its tip; the base has no hit points yet, so it
; is not hurt. The laser's beam (laser.s) still goes through.
;
; WHERE IT LIVES. The place, the discs and the mark are CODE6 (CART_HIRAM); the
; wall is CODE7, stored in bank 6 and run in upper RAM. State is under the
; window behind gate.s's, so all of it runs inside cart_frame's win_off bracket:
; do_base from frame_body just before do_stars (the disc must be in the list
; before the stars are walked), base_brake from do_ship, base_rock from
; do_objects, base_foe from foe_integrate, base_load from level_begin.
; =============================================================================

BS_N        = 6                 ; segments: EA_BASE's parts
BS_HR       = 77                ; the disc round the whole hexagon, half-res px: its
                                ;   farthest corner, 76.5 units out
BS_CR       = 41                ; a segment's circle, half-res px = collision units:
                                ;   the circumradius of EA_BASE's triangles, out of
                                ;   their vertices (40.3), rounded up to hold them
BS_REACH    = 12                ; pages past the cull radius the base can still
                                ;   reach the screen from: a circle's centre is 48
                                ;   units out and its edge 41 past that, 89 units
                                ;   of 32 world units, 11.1 pages
BS_ER       = 48 + BS_CR        ; where a mover that is stuck is put out to: the farthest a
                                ;   circle reaches from the anchor, a centre 48 units out
                                ;   and its 41 - 89 (bs_eject)
BS_SHIPR    = 12                ; the ship's radius for the wall, collision units:
                                ;   its own 16 px (8) and eight more (4), so it
                                ;   stops short of the line
BS_WIN      = 18                ; pages: a rock or an enemy this far from the
                                ;   anchor on either axis cannot touch a circle.
                                ;   The largest reach is a centre 48 units out, the
                                ;   41 of its circle and a rock's 39
BS_FOE_R    = 9                 ; an enemy's circle, collision units: the UFO's,
                                ;   and the spider's and the pulsar's 8 are under it
BS_TI       = 20 + 2            ; a triangle's INRADIUS - its edges are 20 units from its
                                ;   centroid - and two more, a bullet's own reach (SHOT_HITR)
BR_N        = 6                 ; dots in the radar mark

        .assert GATE_DOT = 1, error, "base.s: EA_BASE is authored in half-res units for gb_draw's DOT_POLYGON"
        .assert EN_BASE_PN = BS_N && BS_N <= 8, error, "base.s: a segment is a part of EA_BASE, and BSLIVE is a byte"
        .assert (48 + BS_CR + 39) * 32 < BS_WIN * 256 - 256, error, "base.s: BS_WIN no longer covers the widest reach"
        .assert (BS_CR + 39) * 2 < 256, error, "base.s: rsum indexes the quarter-squares by 2*rsum"
        .assert 13 * 8 > BS_CR + 39, error, "base.s: bs_circle's 13-page reject must be past rsum"
        .assert BS_HR <= 127 && BS_CR <= 127, error, "base.s: disc_hit indexes the quarter-squares by 2R"
        .assert EN_BASE_PN * EN_BASE_FN <= 255, error, "base.s: EA_BASE's rows index a byte"

; --- state: under the window, behind gate.s's -----------------------------------
BSB         = GATE_END
BSON        = BSB + 0           ; 0 no base in this sector, 1 one
BSXL        = BSB + 1           ; the anchor - the middle of the hexagon -
BSXH        = BSB + 2           ;   world 16-bit, fixed
BSYL        = BSB + 3
BSYH        = BSB + 4
BSAST       = BSB + 5           ; its playlist step, like GTAST...
BSACD       = BSB + 6           ; ...and the frames left on it, like GTACD
                                ; BSB + 7 is spare
BSLIVE      = BSB + 8           ; the live segments, bit j = triangle j
BP          = BSB + 9           ; do_base: anchor - ship, kept: xl xh yl yh
; the wall's workspace. BW_D..BW_V is one run of eight bytes, in the order
; BS_ARR names the arrays that hold them
BW_D        = BSB + 13          ; the mover's centre minus the anchor: xl xh yl yh
BW_V        = BSB + 17          ; its velocity, signed 16 an axis: xl xh yl yh
BW_D0       = BSB + 21          ; ...and where it started, for the ship's correction
BW_R        = BSB + 25          ; its radius, collision units
BW_M        = BSB + 26          ; what to do with its velocity: 0 zero, 1 reflect,
                                ;   2 leave
BW_I        = BSB + 27          ; the mover's slot...
BW_TB       = BSB + 28          ; ...and its table in BS_ARR
BW_W        = BSB + 29          ; 0 read the mover in, 1 write it out
BW_K        = BSB + 30          ; bs_xfer's byte
BW_DX       = BSB + 31          ; bs_circle: d = the mover - the centre, 16-bit an
                                ;   axis, then its magnitude
BW_MG       = BSB + 35          ; ...that magnitude in units (x at +0, y at +2)
BW_SN       = BSB + 39          ; ...and its signs, bit 7 (x at +0, y at +2)
BW_Q        = BSB + 43          ; (41 + the mover's radius)^2, 16-bit
BW_AX       = BSB + 45          ; the axis a push is along, 0 x / 2 y...
BW_OT       = BSB + 46          ; ...the other one...
BW_AC       = BSB + 47          ; ...the unit the search has reached...
BW_T        = BSB + 48          ; ...and 16-bit scratch
BW_L        = BSB + 50          ; the live bits, being walked
BW_S        = BSB + 51          ; the segment
BW_PS       = BSB + 52          ; a push happened this pass, and ever
BW_ANY      = BSB + 53
BW_PASS     = BSB + 54          ; passes left
BASE_END    = BSB + 55
        .assert BW_V = BW_D + 4 && BW_D0 = BW_V + 4, error, "base.s: the workspace's runs"
        .assert BASE_END <= SHAPES_AT, error, "base.s: past the RAM under the window"

        .pushseg
        .segment "CODE6"

; -----------------------------------------------------------------------------
; base_load - level_begin, after gate_load: this sector's base, or none.
; -----------------------------------------------------------------------------
base_load:
        ldx     CURLEV
        lda     BASE_ON,x
        sta     BSON
        lda     BASE_XL,x
        sta     BSXL
        lda     BASE_XH,x
        sta     BSXH
        lda     BASE_YL,x
        sta     BSYL
        lda     BASE_YH,x
        sta     BSYH
        lda     #(1 << BS_N) - 1        ; every segment standing
        sta     BSLIVE
        stz     BSAST
        ldy     #EA_BASE
        lda     EN_AHOLD,y
        sta     BSACD
        rts

; -----------------------------------------------------------------------------
; do_base - once a frame, inside the bracket, before do_stars: the playlist, the
; radar mark, and - if the base is anywhere near the screen - a disc for each live
; segment and the drawing.
; -----------------------------------------------------------------------------
do_base:
        lda     BSON
        bne     :+
        rts
:       dec     BSACD                   ; the playlist, as do_gate steps its own
        bne     @radar
        ldy     #EA_BASE
        lda     EN_AHOLD,y
        sta     BSACD
        inc     BSAST
        lda     BSAST
        cmp     EN_AN,y
        bcc     @radar
        stz     BSAST

@radar: lda     BSXH                    ; the mark, wherever the base is
        ldy     BSYH
        jsr     gr_pos
        bcs     @near
        ldx     #$00
        ldy     #$01
@pt:    lda     GTRX
        clc
        adc     BR_DX,x
        sta     GTRB,y
        iny
        lda     GTRY
        clc
        adc     BR_DY,x
        sta     GTRB,y
        iny
        inx
        cpx     #BR_N
        bne     @pt
        lda     #BR_N
        sta     GTRB
        lda     #<GTRB
        sta     OS_ARG+0
        lda     #>GTRB
        sta     OS_ARG+1
        jsr     API_GPU_DOTPIXELS

@near:  sec                             ; P = anchor - ship, and the wrap is free
        lda     BSXL
        sbc     SHXL
        sta     PXL
        lda     BSXH
        sbc     SHXH
        sta     PXH
        sec
        lda     BSYL
        sbc     SHYL
        sta     PYL
        lda     BSYH
        sbc     SHYH
        sta     PYH
        ldy     #$01                    ; is any of it near? The rocks' own coarse
@axis:  tya                             ;   window, per world axis, grown by what
        asl     a                       ;   the base reaches past its anchor. It
        tax                             ;   also keeps view_xform's input inside
        lda     CULH,y                  ;   what it can rotate without overflow
        clc
        adc     #BS_REACH
        sta     T0
        asl     a
        adc     #$01                    ; (the shift left the carry clear)
        sta     T1
        lda     PXH,x
        clc
        adc     T0
        cmp     T1
        bcc     :+
        rts                             ; too far off to reach the screen
:       dey
        bpl     @axis

        ldx     #$03                    ; P is kept: each disc is P + its centre
:       lda     PXL,x
        sta     BP,x
        dex
        bpl     :-
        lda     BSLIVE
        cmp     #(1 << BS_N) - 1
        bne     @segs
        jsr     view_xform              ; ALL STANDING: one disc, on the anchor, round
        jsr     zoom_fb                 ;   the whole hexagon - it is nearly a circle,
        lda     #BS_HR                  ;   and one disc is a sixth of the star loop's
        jsr     bs_disc                 ;   work
        bra     @draw                   ; (FX/FY are the anchor's already)

@segs:  lda     BSLIVE                  ; A TRIANGLE GONE: a disc for each that stands
        sta     BW_L
        stz     BW_S
@seg:   lsr     BW_L
        bcc     @nseg
        lda     BW_S                    ; the segment's centre, world units
        asl     a
        asl     a
        tax
        clc
        lda     BP
        adc     BS_OFF,x
        sta     PXL
        lda     BP+1
        adc     BS_OFF+1,x
        sta     PXH
        clc
        lda     BP+2
        adc     BS_OFF+2,x
        sta     PYL
        lda     BP+3
        adc     BS_OFF+3,x
        sta     PYH
        jsr     view_xform
        jsr     zoom_fb
        lda     #BS_CR                  ; ...its circle, through the corners
        jsr     bs_disc
@nseg:  inc     BW_S
        lda     BW_S
        cmp     #BS_N
        bcc     @seg

        ldx     #$03                    ; the drawing is the gate's, round the anchor
:       lda     BP,x
        sta     PXL,x
        dex
        bpl     :-
        jsr     view_xform
        jsr     zoom_fb
@draw:  lda     #EA_BASE                ; this appearance, this step, no spin of its
        sta     GBAP                    ;   own, the scale as it stands (half-res
        lda     BSAST                   ;   units), and the segments that are live
        sta     GBST
        stz     GBAN
        stz     GBSH
        lda     BSLIVE
        sta     GBMK
        jmp     gb_draw                 ; tail

; A = a disc's radius at 1:1, half-res px; FX/FY = its centre. The star layers are
; kept out of it: shrinking with the zoom, and half-res like the stars are.
bs_disc:
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul
        sta     AOCR
        lda     FXH
        cmp     #$80
        ror     a
        sta     CX2H
        lda     FXL
        ror     a
        sta     CX2L
        lda     FYH
        cmp     #$80
        ror     a
        sta     CY2H
        lda     FYL
        ror     a
        sta     CY2L
        jmp     add_disc                ; tail

; --- tables -------------------------------------------------------------------
; The radar mark, in framebuffer axes (fb x runs down the player's screen, fb y
; to the left of it): the six dots of a flat-topped hexagon, two above, one to
; each side, two below.
BR_DX:  .byte   <-1, <-1, 0, 0, 1, 1
BR_DY:  .byte   0, <-1, 1, <-2, 0, <-1

; Where each level's base stands (its anchor, world 16-bit), or 0 in BASE_ON for
; none. It is here and not in levels.s because the level editor rewrites that
; block whole; it moves there when the editor learns to place one.
; Level 0: 640 px dead ahead of where the ship starts.
BASE_ON:    .byte   1
BASE_XL:    .byte   <$8000
BASE_XH:    .byte   >$8000
BASE_YL:    .byte   <$5800
BASE_YH:    .byte   >$5800
        .assert BASE_XL - BASE_ON = NLEVELS && * - BASE_YH = NLEVELS, error, "base.s: a row per level in BASE_*"
        .assert BR_DY - BR_DX = BR_N && GTR_N >= BR_N, error, "base.s: the mark's dots go through gate.s's GTRB, which holds GTR_N"

        .popseg

; =============================================================================
; The wall. CODE7: stored in bank 6, run in upper RAM (cart.cfg).
; =============================================================================
        .pushseg
        .segment "CODE7"

; -----------------------------------------------------------------------------
; bs_keep - put a mover back on the circles of the live segments, if it is in one.
;   in   BW_D  its centre minus the anchor, BW_V its velocity, BW_R its radius
;        (collision units); A = what to do to a velocity that points INTO the
;        circle: 0 zero it, 1 reflect it, 2 leave it
;   out  carry SET: it was inside one, and BW_D is now outside them all (BW_D0 is
;        where it started, for the ship's correction); BW_V is changed as asked.
;        carry CLEAR: it was not, and nothing was touched
; Clobbers A, X, Y and the workspace.
; -----------------------------------------------------------------------------
bs_keep:
        sta     BW_M
        ldx     #$03
@sv:    lda     BW_D,x                  ; where it started
        sta     BW_D0,x
        dex
        bpl     @sv
        ldx     #$02                    ; the coarse reject: nothing within the
@fr:    lda     BW_D+1,x                ;   window of pages, on either axis, can
        clc                             ;   touch a circle
        adc     #BS_WIN
        cmp     #2 * BS_WIN
        bcs     @none
        dex
        dex
        bpl     @fr
        lda     BW_R                    ; rsum = a circle's radius and the mover's,
        clc                             ;   and rsum^2 off the quarter-squares
        adc     #BS_CR
        asl     a
        tax
        lda     QSL,x
        sta     BW_Q
        lda     QSH,x
        sta     BW_Q+1
        stz     BW_ANY
        lda     #$06
        sta     BW_PASS
@pass:  stz     BW_PS
        lda     BSLIVE
        sta     BW_L
        stz     BW_S
@seg:   lsr     BW_L
        bcc     @next
        jsr     bs_circle
        bcc     @next
        lda     #$01
        sta     BW_PS
        sta     BW_ANY
@next:  inc     BW_S
        lda     BW_S
        cmp     #BS_N
        bcc     @seg
        lda     BW_PS                   ; a push may have landed it in the next
        beq     @done                   ;   circle along: walk them again
        dec     BW_PASS
        bne     @pass
        jsr     bs_eject                ; still being pushed after six passes: it is
                                        ;   in the middle, where nothing has room
@done:  lda     BW_ANY
        lsr     a                       ; carry = it was put back
        rts
@none:  clc
        rts

; -----------------------------------------------------------------------------
; bs_eject - a mover the circles will not let go of is put OUT of the base: a circle
; on the anchor, as far out as any of them reaches, and it is pushed out of that the
; way it is pushed out of a segment's. The six overlap, so a rock that was born in
; the hexagon (the scatter does) or came to rest in the pocket at its middle - the
; one place the circles leave free - has no way out of it by their walls.
; -----------------------------------------------------------------------------
bs_eject:
        lda     BW_R
        clc
        adc     #BS_ER
        cmp     #128                    ; rsum^2 is looked up by 2*rsum, a byte: a
        bcc     :+                      ;   mover of the biggest class is a unit
        lda     #127                    ;   short, and the next frame finishes it
:       asl     a
        tax
        lda     QSL,x
        sta     BW_Q
        lda     QSH,x
        sta     BW_Q+1
        lda     #BS_N                   ; the row after the segments' in BS_OFF: 0, 0
        sta     BW_S
        jmp     bs_circle               ; tail

; -----------------------------------------------------------------------------
; bs_circle - segment BW_S's circle against BW_D. Carry SET: it was in, and it has
; been put out along the axis it is farther from the centre on.
; -----------------------------------------------------------------------------
bs_circle:
        lda     BW_S
        asl     a
        asl     a
        tay                             ; this segment's row of BS_OFF
        ldx     #$00                    ; x, then y: d = D - centre, as a magnitude
@ax:    sec                             ;   and a sign, and the magnitude in units
        lda     BW_D,x
        sbc     BS_OFF,y
        sta     BW_DX,x
        lda     BW_D+1,x
        sbc     BS_OFF+1,y
        sta     BW_DX+1,x
        sta     BW_SN,x
        bpl     :+
        sec
        lda     #$00
        sbc     BW_DX,x
        sta     BW_DX,x
        lda     #$00
        sbc     BW_DX+1,x
        sta     BW_DX+1,x
:       lda     BW_DX+1,x
        cmp     #$0D                    ; 13 pages is 104 units, past rsum's 80
        bcs     @far
        lda     BW_DX,x                 ; units = (high << 3) | (low >> 5): floored,
        lsr     a                       ;   so a magnitude is never overstated
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     BW_T
        lda     BW_DX+1,x
        asl     a
        asl     a
        asl     a
        ora     BW_T
        sta     BW_MG,x
        iny
        iny
        inx
        inx
        cpx     #$04
        bne     @ax
        bra     @d2
@far:   clc                             ; (out here so that both tests reach it)
        rts

@d2:    lda     BW_MG                   ; d^2 = mx^2 + my^2, in table reads
        asl     a
        tax
        lda     QSL,x
        sta     BW_T
        lda     QSH,x
        sta     BW_T+1
        lda     BW_MG+2
        asl     a
        tax
        clc
        lda     QSL,x
        adc     BW_T
        sta     BW_T
        lda     QSH,x
        adc     BW_T+1
        sta     BW_T+1
        cmp     BW_Q+1                  ; ...against rsum^2
        bcc     @in
        bne     @far
        lda     BW_T
        cmp     BW_Q
        bcs     @far
@in:    ldx     #$00                    ; the axis it is farther out on
        lda     BW_MG
        cmp     BW_MG+2
        bcs     :+
        ldx     #$02
:       stx     BW_AX
        txa
        eor     #$02
        sta     BW_OT
        tax
        lda     BW_MG,x                 ; the other axis's square is spoken for:
        asl     a                       ;   what this one must make up is
        tax                             ;   rsum^2 - b^2
        sec
        lda     BW_Q
        sbc     QSL,x
        sta     BW_T
        lda     BW_Q+1
        sbc     QSH,x
        sta     BW_T+1
        ldx     BW_AX
        lda     BW_MG,x
        sta     BW_AC
@up:    inc     BW_AC                   ; the first unit at which a^2 gets there
        lda     BW_AC
        asl     a
        tax
        lda     QSH,x
        cmp     BW_T+1
        bcc     @up
        bne     @ok
        lda     QSL,x
        cmp     BW_T
        bcc     @up
@ok:    lda     BW_AC                   ; ...in world units: * 32
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        sta     BW_T
        lda     BW_AC
        lsr     a
        lsr     a
        lsr     a
        sta     BW_T+1
        ldx     BW_AX
        sec                             ; ...and how far that is from where it is
        lda     BW_T
        sbc     BW_DX,x
        sta     BW_T
        lda     BW_T+1
        sbc     BW_DX+1,x
        sta     BW_T+1
        lda     BW_SN,x                 ; outward is the way d already points
        bpl     :+
        sec
        lda     #$00
        sbc     BW_T
        sta     BW_T
        lda     #$00
        sbc     BW_T+1
        sta     BW_T+1
:       clc
        lda     BW_D,x
        adc     BW_T
        sta     BW_D,x
        lda     BW_D+1,x
        adc     BW_T+1
        sta     BW_D+1,x

        lda     BW_M
        cmp     #$02
        beq     @pushed                 ; the ship's velocity is not this one's
        lda     BW_V+1,x                ; opposite signs: it is coming in
        eor     BW_SN,x
        bpl     @pushed
        lda     BW_M
        bne     @refl
        stz     BW_V,x                  ; ...and an enemy stops coming in
        stz     BW_V+1,x
        bra     @pushed
@refl:  sec                             ; ...and a rock goes back out
        lda     #$00
        sbc     BW_V,x
        sta     BW_V,x
        lda     #$00
        sbc     BW_V+1,x
        sta     BW_V+1,x
@pushed:
        sec
        rts

; The segments' centres, world units, x then y a row: EA_BASE's triangles' centroids
; (48 units out, 60 degrees apart, in framebuffer axes), turned into world axes
; (world x is -fb y, world y is fb x) at 32 world units a unit
BS_OFF: .word   0, 1536
        .word   $10000 - 1323, 768
        .word   $10000 - 1323, $10000 - 768
        .word   0, $10000 - 1536
        .word   1323, $10000 - 768
        .word   1323, 768
        .word   0, 0                    ; ...and the anchor itself, for bs_eject
        .assert * - BS_OFF = (BS_N + 1) * 4, error, "base.s: a row of BS_OFF a segment, and the anchor's"

; -----------------------------------------------------------------------------
; base_shot_p / base_shot_f - a bullet against the base: X = the player's bullet's
; slot / an enemy bullet's (kept). Carry SET = it hit a live segment and was spent
; (the puff on its tip; the player's slot is freed here, the enemy's by the caller).
; -----------------------------------------------------------------------------
base_shot_p:
        lda     BSON
        beq     bs_none
        phx
        lda     SHTXL,x
        sta     BW_D
        lda     SHTXH,x
        sta     BW_D+1
        lda     SHTYL,x
        sta     BW_D+2
        lda     SHTYH,x
        sta     BW_D+3
        jsr     bs_shot
        plx
        bcc     bs_none
        jsr     expl_spawn              ; the puff on the tip; a bullet that has hit
        stz     SHTLIVE,x               ;   a wall is over, and pays nothing
        sec
        rts

base_shot_f:
        lda     BSON
        beq     bs_none
        phx
        lda     FSXL,x
        sta     BW_D
        lda     FSXH,x
        sta     BW_D+1
        lda     FSYL,x
        sta     BW_D+2
        lda     FSYH,x
        sta     BW_D+3
        jsr     bs_shot
        plx
        bcc     bs_none
        jsr     fsh_bang                ; the puff
        sec
        rts
bs_none:
        clc
        rts

; -----------------------------------------------------------------------------
; bs_shot - the point in BW_D against the live triangles: carry SET = inside one,
; BW_S its number (the hook for hit points: the segment that was hit).
; -----------------------------------------------------------------------------
; The bullet is a point and the triangle is the TRIANGLE, not its circle - a circle
; stands 20 units off the middle of an edge, and a shot that dies in empty space
; there reads as a shield. The three edges of a segment's equilateral triangle are
; 20 units (BS_TI) from its centroid and their normals are 120 degrees apart, and
; every one of the six points its apex at the anchor, so in world axes the normals
; are one of two sets - (0,1) and (+-7/8, -1/2) for the even segments, the same
; turned half a turn for the odd - and a point q from the centroid is inside when
;
;       qy < TI   and   |7/8 qx| - qy/2 < TI        (odd: with q negated)
;
; 7/8 for the cosine of 30 degrees (0.866) is a 1% error, on a shift and a subtract.
; Whole units, floored; a segment whose centroid is 6 pages away is skipped.
; -----------------------------------------------------------------------------
bs_shot:
        sec                             ; D = the bullet - the anchor
        lda     BW_D
        sbc     BSXL
        sta     BW_D
        lda     BW_D+1
        sbc     BSXH
        sta     BW_D+1
        clc
        adc     #BS_WIN                 ; the coarse reject: a bullet far from the
        cmp     #2 * BS_WIN             ;   base dies on its high bytes
        bcs     @miss
        sec
        lda     BW_D+2
        sbc     BSYL
        sta     BW_D+2
        lda     BW_D+3
        sbc     BSYH
        sta     BW_D+3
        clc
        adc     #BS_WIN
        cmp     #2 * BS_WIN
        bcs     @miss
        lda     BSLIVE
        sta     BW_L
        stz     BW_S
@seg:   lsr     BW_L
        bcc     @next
        jsr     bs_tri
        bcs     @hit
@next:  inc     BW_S
        lda     BW_L
        bne     @seg
@miss:  clc
        rts
@hit:   sec
        rts

; bs_tri - BW_D against segment BW_S's triangle. Carry SET = inside.
bs_tri:
        lda     BW_S
        asl     a
        asl     a
        tay                             ; this segment's row of BS_OFF
        ldx     #$00                    ; q = D - centre, in whole units, x then y
@ax:    sec
        lda     BW_D,x
        sbc     BS_OFF,y
        sta     BW_DX,x
        lda     BW_D+1,x
        sbc     BS_OFF+1,y
        sta     BW_DX+1,x
        clc
        adc     #6                      ; a triangle is 40 units, 5 pages, across:
        cmp     #12                     ;   the page must be -6..5 or it is out
        bcs     @out
        lda     BW_DX,x                 ; units = (high << 3) | (low >> 5), signed,
        lsr     a                       ;   floored - a byte, at 48 units at most
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     BW_T
        lda     BW_DX+1,x
        asl     a
        asl     a
        asl     a
        ora     BW_T
        sta     BW_MG,x
        iny
        iny
        inx
        inx
        cpx     #$04
        bne     @ax
        lda     BW_S
        lsr     a
        bcc     @even                   ; the odd ones are the even ones turned round
        sec
        lda     #$00
        sbc     BW_MG
        sta     BW_MG
        sec
        lda     #$00
        sbc     BW_MG+2
        sta     BW_MG+2
@even:  lda     BW_MG+2                 ; qy < TI
        sec
        sbc     #BS_TI
        bpl     @out
        lda     BW_MG                   ; |7/8 qx| = |qx| - |qx| / 8
        bpl     :+
        eor     #$FF
        inc     a
:       sta     BW_T
        lsr     a
        lsr     a
        lsr     a
        sta     BW_T+1
        lda     BW_T
        sec
        sbc     BW_T+1
        sta     BW_T
        lda     BW_MG+2                 ; ...minus qy / 2, arithmetic
        cmp     #$80
        ror     a
        sta     BW_T+1
        lda     BW_T
        sec
        sbc     BW_T+1
        sec
        sbc     #BS_TI + 1              ; (+1: the floors, and the 7/8, all fall stricter)
        bmi     @in                     ; both inside: it is in this triangle
@out:   clc
        rts
@in:    sec
        rts

; -----------------------------------------------------------------------------
; base_rock - do_objects, after a rock has moved and BEFORE its cell is looked
; up, X = its slot (kept). A rock inside a circle is put back on it and turned.
; -----------------------------------------------------------------------------
base_rock:
        lda     BSON
        beq     @r
        lda     OBJXH,x                 ; the coarse reject: nearly every rock
        sec                             ;   dies here, on the high bytes
        sbc     BSXH
        clc
        adc     #BS_WIN
        cmp     #2 * BS_WIN
        bcs     @r
        lda     OBJYH,x
        sec
        sbc     BSYH
        clc
        adc     #BS_WIN
        cmp     #2 * BS_WIN
        bcs     @r
        stx     BW_I
        lda     OBJSHP,x                ; its circle: BODY_R, collision units
        tay
        lda     BODY_R,y
        sta     BW_R
        stz     BW_TB
        lda     #$01
        jmp     bs_mover
@r:     rts

; -----------------------------------------------------------------------------
; base_foe - foe_integrate's last word, X = the enemy's slot (kept).
; -----------------------------------------------------------------------------
base_foe:
        lda     BSON
        beq     @r
        lda     FOEXH,x
        sec
        sbc     BSXH
        clc
        adc     #BS_WIN
        cmp     #2 * BS_WIN
        bcs     @r
        lda     FOEYH,x
        sec
        sbc     BSYH
        clc
        adc     #BS_WIN
        cmp     #2 * BS_WIN
        bcs     @r
        stx     BW_I
        lda     #BS_FOE_R
        sta     BW_R
        lda     #BS_FOE - BS_ARR
        sta     BW_TB
        lda     #$00
        jmp     bs_mover
@r:     rts

; A = the velocity mode. BW_I = the slot, BW_TB = its table, BW_R its radius.
; Reads the mover in, keeps it out, and writes it back if it had to.
bs_mover:
        pha
        stz     BW_W
        ldx     BW_TB
        ldy     BW_I
        jsr     bs_xfer
        ldx     #$00                    ; D = position - anchor, both axes
@sub:   sec
        lda     BW_D,x
        sbc     BSXL,x
        sta     BW_D,x
        inx
        lda     BW_D,x
        sbc     BSXL,x
        sta     BW_D,x
        inx
        cpx     #$04
        bne     @sub
        pla
        jsr     bs_keep
        bcc     @r
        ldx     #$00                    ; ...and back to a position
@add:   clc
        lda     BW_D,x
        adc     BSXL,x
        sta     BW_D,x
        inx
        lda     BW_D,x
        adc     BSXL,x
        sta     BW_D,x
        inx
        cpx     #$04
        bne     @add
        lda     #$01
        sta     BW_W
        ldx     BW_TB
        ldy     BW_I
        jsr     bs_xfer
@r:     ldx     BW_I
        rts

; X = the table in BS_ARR, Y = the slot. BW_W 0: eight bytes from the mover's
; arrays into BW_D..BW_V; 1: the same eight back. The arrays are named by a
; 16-bit address each and the slot is the index, which is how one loop reaches a
; rock's, whose arrays are a page apart, and an enemy's, sixteen.
bs_xfer:
        stz     BW_K
@l:     lda     BS_ARR,x
        sta     T2
        lda     BS_ARR+1,x
        sta     T3
        phx
        ldx     BW_K
        lda     BW_W
        bne     @w
        lda     (T2),y
        sta     BW_D,x
        bra     @n
@w:     lda     BW_D,x
        sta     (T2),y
@n:     inc     BW_K
        plx
        inx
        inx
        lda     BW_K
        cmp     #$08
        bne     @l
        rts

; a rock's arrays (main.s), then an enemy's (radar.s, foes.s): position x y,
; velocity x y, low bytes then high
BS_ARR: .word   OBJXL, OBJXH, OBJYL, OBJYH, OBJVXL, OBJVXH, OBJVYL, OBJVYH
BS_FOE: .word   FOEXL, FOEXH, FOEYL, FOEYH, FOEVXL, FOEVXH, FOEVYL, FOEVYH

; -----------------------------------------------------------------------------
; base_brake - do_ship, after the throttle and the knockback have made this
; frame's velocity and BEFORE it is added to the position. The ship cannot
; enter a live segment: see the header for why by velocity and not by position.
; The stars are scrolled by the throttle (SPD), which the wall does not touch, so
; the part of what it took off that lay along the heading is also taken off TRAV,
; the stars' travel: without it the ship stands at the base and the stars flow on.
; -----------------------------------------------------------------------------
base_brake:
        lda     BSON
        bne     :+
        rts
:       sec                             ; D = ship - anchor
        lda     SHXL
        sbc     BSXL
        sta     BW_D
        lda     SHXH
        sbc     BSXH
        sta     BW_D+1
        sec
        lda     SHYL
        sbc     BSYL
        sta     BW_D+2
        lda     SHYH
        sbc     BSYH
        sta     BW_D+3
        lda     #BS_SHIPR
        sta     BW_R
        lda     #$02
        jsr     bs_keep
        bcs     @out                    ; inside already: free to go

        clc                             ; where the step would put it: the true
        lda     SHXF                    ;   24-bit sum, so a fraction that carries
        adc     VELXL                   ;   is not a unit missed
        lda     BW_D
        adc     VELXH
        sta     BW_D
        lda     BW_D+1
        adc     VELXT
        sta     BW_D+1
        clc
        lda     SHYF
        adc     VELYL
        lda     BW_D+2
        adc     VELYH
        sta     BW_D+2
        lda     BW_D+3
        adc     VELYT
        sta     BW_D+3
        lda     #$02
        jsr     bs_keep
        bcs     @cut
@out:   rts
@cut:   sec                             ; it would go in: the step is cut by however
        lda     BW_D                    ;   far it was put back, on both axes
        sbc     BW_D0
        sta     T0
        lda     BW_D+1
        sbc     BW_D0+1
        sta     T1
        clc
        lda     VELXH
        adc     T0
        sta     VELXH
        lda     VELXT
        adc     T1
        sta     VELXT
        lda     T0                      ; the stars scroll off the throttle, not off
        sta     MAL                     ;   the velocity (stars.s), so what the wall
        lda     T1                      ;   took off the way forward is taken off
        sta     MAH                     ;   their travel too: forward is (sin, -cos)
        lda     SINV                    ;   and this is the x part of the correction
        sta     MB                      ;   along it
        jsr     smul16q7
        lda     MAL
        sta     BW_Q
        lda     MAH
        sta     BW_Q+1
        sec
        lda     BW_D+2
        sbc     BW_D0+2
        sta     T0
        lda     BW_D+3
        sbc     BW_D0+3
        sta     T1
        clc
        lda     VELYH
        adc     T0
        sta     VELYH
        lda     VELYT
        adc     T1
        sta     VELYT
        lda     T0                      ; ...and the y part
        sta     MAL
        lda     T1
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        sec                             ; travelled less by BW_Q - MAL world units
        lda     BW_Q                    ;   along the heading: a unit is two of TRAV's
        sbc     MAL                     ;   256ths of a pixel (stars.s: a 128th of a
        sta     T0                      ;   px, in 8.8), so twice that is added to it
        lda     BW_Q+1
        sbc     MAH
        asl     T0
        rol     a
        tax
        clc
        lda     TRAVL
        adc     T0
        sta     TRAVL
        txa
        adc     TRAVH
        sta     TRAVH
        rts

        .popseg
