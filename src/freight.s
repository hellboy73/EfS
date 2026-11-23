; =============================================================================
; freight.s - the FREIGHTER: a neutral human transport, scenery that moves
; =============================================================================
; Decided 2026-11-22 (the user). Not an enemy: it is a second kind of HUMAN
; BASE, one that drifts. So it is not in the enemy slots at all - nothing that
; hunts, frames, counts or kills enemies (cam.s, the radar, the EMP, the mine,
; the laser, the pulsar's beams, foe_alarm, gate_check's MS_FOES) ever sees
; one, and none of them needed a line. What it shares with the base is the
; WALL (base.s): a rock that meets it bounces off, an enemy slides along it,
; the ship is braked by its field rather than hurt, and every bullet ends on it
; in a puff. It cannot be destroyed - not yet; a scenario may want that later.
;
; TWO WAYS TO BE, both read from an enemy record in levels.s with KIND
; FK_FREIGHT (load_foes diverts it here; it takes no enemy slot):
;
;   ADRIFT   SPEED > 0: it flies along the world's Y axis only - HEADING 0
;            north (-Y), 128 south - at SPEED px/s (120 is the setting: a
;            third of the ship's unboosted top speed), forever, wrapping round
;            the torus like everything else. A level must keep the base off
;            its line. It moves whether it is seen or not. Its nozzles leave a
;            trail of the bullet-hit puffs (shots.s expl_at) behind the stern.
;   DOCKED   SPEED 0: it stands where the level put it. There is no docking
;            manoeuvre - placing it is the whole of it: stern to the base's
;            bottom edge, the base's own triangle gap away (levels.s).
;
; Y ONLY, on purpose: the hull lies along the world's Y axis, so its bullet
; test is a rectangle on the world axes (fr_rect) and its wall is two circles
; on that axis (BS_OFF's last two rows), with no rotation anywhere. Any other
; HEADING is read as north.
;
; THE WALL IS base.s's, unchanged in kind: its routines read a BODY - BSON, the
; anchor, BSLIVE, the circles' radius and first row in BS_OFF, the body's y
; velocity (BSB+0..9) - and for each freighter near a mover, fr_each SWAPS the
; freighter's body into those ten bytes, runs the base's routine, and swaps
; the base back. So base_rock, base_foe, base_brake, base_shot_p and base_shot_f
; - the names the movers call - are here now: the base's own (bs_rock1...),
; then each freighter's. The ship is braked against where the freighter WILL
; be this frame (BSVY), because do_freight moves it after do_ship.
;
; It is DRAWN through gate.s's gb_draw like the base, but in SOLID lines -
; POLYGON16 at full-res, as the rocks and the UFOs are (GBSH = 2; the user,
; 2026-11-22), not the base's and the gate's dotted ones - at its own angle 0
; or 128 minus the camera's, with one star-occlusion disc.
; ON THE RADAR as four dots in a square - the middle of the base's 4x4 ring
; (the user, 2026-11-23) - while it is in the radar's reach, as the base is.
; No hit points, no wreck - EA_TRANSPORTER_DAMAGED
; is drawn for nothing yet.
;
; WHERE IT LIVES: state under the window behind empmine.s's (read only inside
; cart_frame's bracket, written by the loader); code in CODE9 (FIELDRAM, ROM
; bank 2 - bank 6 behind CODE6 had no room), frt_add in LDCODE (loader.s).
; =============================================================================
FK_FREIGHT  = 4                 ; the KIND a levels.s enemy record carries for
                                ;   one. Not one of foes.s's FK_* - nothing flies
                                ;   it as an enemy - and past FK_N on purpose
        .assert FK_FREIGHT >= FK_N, error, "freight.s: FK_FREIGHT is a kind foes.s now flies as an enemy"
FR_MAX      = 4                 ; freighters a sector can hold
FR_CR       = 15                ; the wall: two circles of this radius, collision
FR_COFF     = 8 * 32            ;   units, their centres this far (world units, 8
                                ;   collision units) fore and aft of the anchor
                                ;   - a stadium 30 units wide and 46 long, the
                                ;   hull's 60 x 90 full-res px
FR_RB       = BS_N + 1          ; ...the first of those two rows in BS_OFF
FR_HW       = 15 * 32           ; the bullet test: the hull's half width and half
FR_HL       = 22 * 32 + 16      ;   length, world units (30 and 45 full-res px)
FR_WIN      = 9                 ; pages: a mover farther than this from the anchor
                                ;   on either axis cannot touch the wall - its
                                ;   reach is 8 + 15 units and a rock's 39, 62
                                ;   units of 32, 7.75 pages
FR_REACH    = 4                 ; pages past the cull window it can still reach
                                ;   the screen from: 54 px of corner, 864 units
FR_DISC     = 27                ; its star-occlusion disc, half-res px at 1:1:
                                ;   the corners
FR_STERN    = 53 * 16           ; where a puff is born: 8 full-res px behind the
                                ;   stern (45 px aft of the anchor), world units
FR_PUFFM    = 7                 ; a puff every 8 frames while it moves
        .assert EN_TRANSPORTER_FN = 1 && EN_TRANSPORTER_AN = 1, error, "freight.s: do_freight draws step 0 only - an animated EA_TRANSPORTER needs a playlist here"

; --- state: under the window, behind empmine.s's --------------------------------
FRTN        = EMPM_END          ; freighters in this sector
FRXL        = FRTN + 1          ; position, world 16-bit; x never changes...
FRXH        = FRXL + FR_MAX
FRYF        = FRXH + FR_MAX     ; ...y is 16.8
FRYL        = FRYF + FR_MAX
FRYH        = FRYL + FR_MAX
FRVYL       = FRYH + FR_MAX     ; its y velocity, signed 8.8 world units a frame
FRVYH       = FRVYL + FR_MAX
FRAN        = FRVYH + FR_MAX    ; 0 north, 128 south: the angle it is drawn at
FIMG        = FRAN + FR_MAX     ; 10 bytes: a body, swapped with BSB+0..9
FRMX        = FIMG + 10         ; fr_each: the mover's high bytes...
FRMY        = FRMX + 1
FRMI        = FRMX + 2          ; ...its slot (X, kept)...
FRI         = FRMX + 3          ; ...and the freighter being looked at
FR_END      = FRMX + 4
        .assert FR_END <= SHAPES_AT, error, "freight.s: past the RAM under the window"
        .assert BSVYH = BSB + 9 && BSON = BSB, error, "freight.s: base.s's BODY is not BSB+0..9"
LDFRT       = $73BE             ; the loader's count while it fills the list - NOT
                                ;   under the window, which it cannot read back
        .assert CAPYH < LDFRT && LDFRT < WINSAVE, error, "freight.s: LDFRT is not the free byte between capsule.s's block and WINSAVE"

        .pushseg
        .segment "CODE9"

; -----------------------------------------------------------------------------
; do_freight - once a frame, inside the bracket, after do_base and before
; do_stars (its disc must be in the list before the stars are walked): each
; freighter moves, puffs, and is drawn if it is near the screen.
; -----------------------------------------------------------------------------
do_freight:
        ldx     FRTN
@lp:    dex
        bpl     :+
        rts
:       stx     FRI
        ldy     #$00                    ; y += vy: 16.8 plus signed 8.8, and the
        lda     FRVYH,x                 ;   wrap is free
        bpl     :+
        dey
:       clc
        lda     FRYF,x
        adc     FRVYL,x
        sta     FRYF,x
        lda     FRYL,x
        adc     FRVYH,x
        sta     FRYL,x
        tya
        adc     FRYH,x
        sta     FRYH,x

        lda     FRXH,x                  ; THE RADAR MARK: four dots in a square,
        ldy     FRYH,x                  ;   the middle of the base's 4x4 ring,
        jsr     gr_pos                  ;   while it is in reach (gate.s gr_pos,
        bcs     @near                   ;   as the base's and the gate's)
        ldx     #FR_MN - 1
        ldy     #$01
@pt:    lda     GTRX
        clc
        adc     FR_MDX,x
        sta     GTRB,y
        iny
        lda     GTRY
        clc
        adc     FR_MDY,x
        sta     GTRB,y
        iny
        dex
        bpl     @pt
        lda     #FR_MN
        sta     GTRB
        lda     #<GTRB
        sta     OS_ARG+0
        lda     #>GTRB
        sta     OS_ARG+1
        jsr     API_GPU_DOTPIXELS

@near:  ldx     FRI
        sec                             ; P = freighter - ship
        lda     FRXL,x
        sbc     SHXL
        sta     PXL
        lda     FRXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     FRYL,x
        sbc     SHYL
        sta     PYL
        lda     FRYH,x
        sbc     SHYH
        sta     PYH
        ldy     #$01                    ; near? do_base's test, per world axis
@axis:  tya
        asl     a
        tax
        lda     CULH,y
        clc
        adc     #FR_REACH
        sta     T0
        asl     a
        adc     #$01
        sta     T1
        lda     PXH,x
        clc
        adc     T0
        cmp     T1
        bcs     @next                   ; too far off to reach the screen
        dey
        bpl     @axis

        ldx     FRI                     ; THE NOZZLES: a puff behind the stern every
        lda     FRVYL,x                 ;   8 frames while it moves, staggered by
        ora     FRVYH,x                 ;   freighter
        beq     @draw
        txa
        clc
        adc     FRAME
        and     #FR_PUFFM
        bne     @draw
        lda     FRXL,x
        sta     EXTXL
        lda     FRXH,x
        sta     EXTXH
        lda     FRVYH,x
        bmi     @north
        sec                             ; going south: the stern is to the north
        lda     FRYL,x
        sbc     #<FR_STERN
        sta     EXTYL
        lda     FRYH,x
        sbc     #>FR_STERN
        bra     @puff
@north: clc
        lda     FRYL,x
        adc     #<FR_STERN
        sta     EXTYL
        lda     FRYH,x
        adc     #>FR_STERN
@puff:  sta     EXTYH
        jsr     expl_at                 ; (shots.s; no free slot is no puff)

@draw:  jsr     view_xform
        jsr     zoom_fb
        lda     #FR_DISC                ; the stars are kept out of the hull
        jsr     bs_disc
        lda     #EA_TRANSPORTER         ; gate.s draws it: its own angle, every
        sta     GBAP                    ;   part, step 0
        stz     GBST
        ldx     FRI
        lda     FRAN,x
        sta     GBAN
        lda     #$02                    ; SOLID lines, as the rocks: POLYGON16,
        sta     GBSH                    ;   full-res (the user, 2026-11-22)
        lda     #$FF
        sta     GBMK
        jsr     gb_draw
@next:  ldx     FRI
        jmp     @lp

; -----------------------------------------------------------------------------
; The walls: the human base's (base.s bs_*1), then every freighter near the
; mover. Same contracts as base.s's - X is the mover's slot, kept; the bullets'
; carry SET = it ended on a wall.
; -----------------------------------------------------------------------------
base_rock:
        jsr     bs_rock1
        lda     FRTN
        beq     fr_rts
        lda     #<bs_rock1
        ldy     #>bs_rock1
        jsr     fr_vec
        lda     OBJXH,x
        ldy     OBJYH,x
        jmp     fr_each

base_foe:
        jsr     bs_foe1
        lda     FRTN
        beq     fr_rts
        lda     #<bs_foe1
        ldy     #>bs_foe1
        jsr     fr_vec
        lda     FOEXH,x
        ldy     FOEYH,x
        jmp     fr_each

base_brake:
        jsr     bs_brake1
        lda     FRTN
        beq     fr_rts
        lda     #<bs_brake1
        ldy     #>bs_brake1
        jsr     fr_vec
        lda     SHXH
        ldy     SHYH
        jmp     fr_each

base_shot_p:
        jsr     bs_shotp1
        bcs     fr_rts
        lda     FRTN                    ; (carry still clear)
        beq     fr_rts
        lda     #<bs_shotp1
        ldy     #>bs_shotp1
        jsr     fr_vec
        lda     SHTXH,x
        ldy     SHTYH,x
        jmp     fr_each

base_shot_f:
        jsr     bs_shotf1
        bcs     fr_rts
        lda     FRTN
        beq     fr_rts
        lda     #<bs_shotf1
        ldy     #>bs_shotf1
        jsr     fr_vec
        lda     FSXH,x
        ldy     FSYH,x
        jmp     fr_each

fr_vec: sta     fr_call+1              ; the routine fr_each runs (self-modifying:
        sty     fr_call+2               ;   FIELDRAM is RAM)
fr_rts: rts

; the radar mark, framebuffer axes as base.s's BR_DX/BR_DY: the 2x2 inside its
; ring
FR_MN       = 4
FR_MDX: .byte   <-1, <-1, 0, 0
FR_MDY: .byte   <-1, 0, <-1, 0
        .assert FR_MDY - FR_MDX = FR_MN && GTR_N >= FR_MN, error, "freight.s: the mark's dots go through gate.s's GTRB"

; -----------------------------------------------------------------------------
; fr_each - A = the mover's x high byte, Y = its y high byte, X = its slot. For
; each freighter within FR_WIN pages, swap its body in, run fr_call's routine,
; swap the base back. Carry SET out = a routine returned carry set (a bullet
; ended), and the walk stopped there. X is the slot again on the way out.
; -----------------------------------------------------------------------------
fr_each:
        sta     FRMX
        sty     FRMY
        stx     FRMI
        ldy     FRTN
fre_lp: dey
        bmi     fre_no
        lda     FRMX                    ; the coarse reject, on the high bytes
        sec
        sbc     FRXH,y
        clc
        adc     #FR_WIN
        cmp     #2 * FR_WIN
        bcs     fre_lp
        lda     FRMY
        sec
        sbc     FRYH,y
        clc
        adc     #FR_WIN
        cmp     #2 * FR_WIN
        bcs     fre_lp
        sty     FRI
        jsr     fr_in                   ; its body in
        ldx     FRMI
fr_call:
        jsr     $FFFF                   ; (fr_vec's)
        php
        jsr     fr_swap                 ; the base back
        plp
        ldy     FRI
        bcc     fre_lp
        ldx     FRMI                    ; ended on this one
        rts
fre_no: ldx     FRMI
        clc
        rts

; fr_in - freighter Y's body into FIMG, then swapped in for the base's: on,
; the anchor, both circles, their radius and rows, and the y step it takes
; this frame in whole world units.
fr_in:
        lda     #$01
        sta     FIMG+0
        lda     FRXL,y
        sta     FIMG+1
        lda     FRXH,y
        sta     FIMG+2
        lda     FRYL,y
        sta     FIMG+3
        lda     FRYH,y
        sta     FIMG+4
        lda     #%11
        sta     FIMG+5
        lda     #FR_CR
        sta     FIMG+6
        lda     #FR_RB
        sta     FIMG+7
        ldx     #$00                    ; the EXACT whole-unit step do_freight
        lda     FRVYH,y                 ;   will take: vy's whole part plus the
        bpl     :+                      ;   carry out of its fraction. vy's whole
        dex                             ;   part alone is a unit short now and
:       stx     FIMG+9                  ;   then - north, 31.875 is -32 - and a
        lda     FRYF,y                  ;   ship braked at the stern against it
        clc                             ;   ended a unit INSIDE, where bs_brake1
        adc     FRVYL,y                 ;   lets it go: it flew through
        lda     FRVYH,y
        adc     #$00
        sta     FIMG+8
        bcc     :+
        inc     FIMG+9
:                                       ; (on into fr_swap)
; fr_swap - BSB+0..9 <-> FIMG. Clobbers A, X, Y.
fr_swap:
        ldx     #9
@l:     lda     BSB,x
        ldy     FIMG,x
        sta     FIMG,x
        tya
        sta     BSB,x
        dex
        bpl     @l
        rts

; -----------------------------------------------------------------------------
; fr_rect - base.s bs_shot's test for a freighter: BW_D (the bullet - the
; anchor) inside the hull's rectangle, on the world axes. Carry SET = inside.
; -----------------------------------------------------------------------------
fr_rect:
        ldx     #$02                    ; y, then x
@ax:    lda     BW_D+1,x                ; |d|
        bpl     @p
        sec
        lda     #$00
        sbc     BW_D,x
        sta     BW_T
        lda     #$00
        sbc     BW_D+1,x
        bra     @c
@p:     lda     BW_D,x
        sta     BW_T
        lda     BW_D+1,x
@c:     sta     BW_T+1
        lda     BW_T                    ; ...against the half side
        cmp     FR_LIM,x
        lda     BW_T+1
        sbc     FR_LIM+1,x
        bcs     @out
        dex
        dex
        bpl     @ax
        sec
        rts
@out:   clc
        rts
FR_LIM: .word   FR_HW, FR_HL            ; x, y

; -----------------------------------------------------------------------------
; frt_add - load_foes, LOADER CODE (loader.s): the record at (T0) is a
; freighter's. Into the list, if there is room. Writes under the window only.
; -----------------------------------------------------------------------------
        .segment "LDCODE"
frt_add:
        ldx     LDFRT
        cpx     #FR_MAX
        bcs     @r
        ldy     #$00
        lda     (T0),y
        sta     FRXL,x
        iny
        lda     (T0),y
        sta     FRXH,x
        iny
        lda     (T0),y
        sta     FRYL,x
        iny
        lda     (T0),y
        sta     FRYH,x
        stz     FRYF,x
        ldy     #$06                    ; SPEED px/s -> 8.8 world units a frame:
        lda     (T0),y                  ;   x68 (16/60.317*256, load_foes' own
        sta     T2                      ;   factor) = x64 + x4
        asl     a
        asl     a
        sta     T3                      ; (v << 2) & $FF
        asl     a
        asl     a
        asl     a
        asl     a                       ; (v << 6) & $FF
        clc
        adc     T3
        sta     T3                      ; the low byte
        php
        lda     T2
        lsr     a
        lsr     a
        sta     T2                      ; v >> 2
        lsr     a
        lsr     a
        lsr     a
        lsr     a                       ; v >> 6
        plp
        adc     T2                      ; the high byte
        sta     T2
        ldy     #$05                    ; HEADING: 128 south, anything else north
        lda     (T0),y
        cmp     #128
        beq     @s
        stz     FRAN,x
        sec                             ; north is -y
        lda     #$00
        sbc     T3
        sta     T3
        lda     #$00
        sbc     T2
        sta     T2
        bra     @v
@s:     sta     FRAN,x
@v:     lda     T3
        sta     FRVYL,x
        lda     T2
        sta     FRVYH,x
        inx
        stx     LDFRT
        stx     FRTN                    ; (written, never read here)
@r:     rts

        .popseg
