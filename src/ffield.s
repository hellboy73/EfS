; =============================================================================
; ffield.s - the FORCE FIELD: a fixed circle nothing crosses but a teleport
; =============================================================================
; design_technical.md 11.51 (what it is and how it works) and 11.52 (where it
; lives). The aliens' shield round an area: one circle a sector, its centre
; placed by the level, its radius FF_R for the whole game. Nothing crosses the
; edge, from either side - the ship, rocks, enemies and bullets all stay on the
; side they are on - except by the teleport, which is a jump of position and
; never meets the test. It is the WALL SLOTS' second tenant (slots.s): a sector
; has the human base or the field, never both.
;
; ONE FUNCTION DECIDES THE SIDE, FOR EVERYTHING (ff_f). The edge is the 256-gon
; whose vertex k is VTX[k] = FF_R (sin k, -cos k) - k a brad, the ship's own
; convention, so foe_atan's bearing IS the vertex - and it misses the true
; circle by about one world unit. For a point, D = point - centre (signed: the
; wrap is free, 3.1), k = atan(D), E = D - VTX[k], and
;
;       f = E.x nx + E.y ny,   n = (sin k, -cos k), Q0.7
;
; is the signed distance from the edge, > 0 OUTSIDE. Two properties make every
; test safe: it is CONSISTENT (every test uses this f, so "f < 0" and "f >= 0"
; split the world with no gap - a step whose two ends differ in sign crossed it,
; at any speed) and a brad off in k moves f by about one unit (the angle's
; error is second order in the distance).
;
; THE SIDE IS THE CENTRE'S, BEFORE THE STEP. A mover of radius r is outside if
; f(its old centre) >= 0, and touches the edge when, after the step, its centre
; is closer than r on that side. The answer always leaves the centre a full
; radius off the edge, so no rounding and no push from another collision can
; carry it across, and the side needs no bit of state. A mover ALREADY across
; the line (a teleport, a spawn, a rock's fragment) is put out on the side its
; centre is on.
;
;   the SHIP    put back on its side - by moving it BEFORE its step, so the
;               step ends on the edge - and, closing, kicked off it as off the
;               EMP mine (ship_kick: the knockback and the throttle) and hurt
;               as by a rock (RAM_DMG), at most once in FF_HURTCD frames
;   a ROCK      put back, and the velocity into the edge reflected: a wall of
;               infinite mass
;   an ENEMY    put back, and the velocity into the edge taken away: it slides
;   a BULLET    either's: its step crossed the edge -> a puff where it is, and
;               it is spent. The laser and the EMP ring are not tested at all
;
; THE COST is kept off almost every mover by a band on the position HIGH BYTES:
; d^2 in pages^2, two quarter-square reads, against (R +- FF_PM)^2. Only a mover
; within FF_PM pages of the edge pays for the atan and the two products.
;
; DRAWING. VISIBLE (FFVIS 1): OPEN DOT_POLYGONs, one TEMPLATE - five vertices
; along the arc, FF_ARCB brads either side of an anchor - whose anchor is a
; vertex VTX[kk] and whose ANGLE is kk - HEAD: a piece of this circle is the
; same shape wherever it is, only turned, so the GPU does the turning (gb_draw's
; way, the base's angle). FF_NI pieces either side of the one nearest the ship,
; each culled on its anchor as the base is. INVISIBLE (FFVIS 0): nothing, but a
; three-vertex piece FLASHED for FF_FLASH frames where a ship, a rock or a bullet
; hit it. Never on the radar (the user, for now). A visible field is drawn only
; for a ship INSIDE it: seen from outside it is the invisible one, flash and all.
;
; THE TOWER (open_questions E13) stands in the centre and holds the field up:
; EA_ALIEN_TOWER, turning a brad every TW_SPIN frames, a WALL - ff_f's other
; circle, below - that only the EMP harms (WS_EMP, ff_emp). Reached by the ring,
; it counts the rocks inside the field, once: one or more, and it and the field
; are DOWN for TW_DOWN frames (dotted, the whole shape); none, and they are down
; for good (dotted, without its last part, sparking where that part was).
;
;   TWST    0 up (solid; the field is there), 1..TW_DOWN down and counting, $FF dead
;
; ONE f FOR BOTH CIRCLES. Near the middle (both high bytes within TW_PM pages)
; ff_f measures the tower instead: f = D.n - TW_R, the same products with VTX[k]
; left out, so ff_mover, ff_pen and ff_shot serve it unchanged. Its side is
; always OUTSIDE (FFAM): a mover that lands inside it - a teleport, a spawn - is
; put out, never kept in. The ship slides on it as on the base's wall - no kick,
; no hurt - and nothing that strikes it flashes or zaps the field.
;
;   FFWALL   slot A (upper RAM, $B960): the side function and the movers
;   FFFRAME  slot B (DEMO_RAM, $DA60): after slots.s's vector table, the frame
; State: under the window, behind freight.s's (written by ff_load, the loader).
; =============================================================================

FF_R        = 16384             ; the radius, world units: a diameter of half the
                                ;   world, 19.6% of its area. FIXED - FF_SIN is it
FF_RP       = FF_R / 256        ; ...in pages: 64
FF_PM       = 9                 ; the band, pages either side of the edge: the
                                ;   largest radius (a 192's 1,248 units, 4.9 pages)
                                ;   + a step (a page) + the high bytes' error (1.5)
FF_PMAX     = FF_RP + FF_PM     ; a high byte this far off is outside the band
FF_BLO      = (FF_RP - FF_PM) * (FF_RP - FF_PM)  ; the band, pages^2
FF_BHI      = (FF_RP + FF_PM) * (FF_RP + FF_PM)
FF_DM       = 40                ; drawing: the ship this many pages off the edge
FF_DMAX     = FF_RP + FF_DM     ;   or nearer, or nothing is drawn
FF_DLO      = (FF_RP - FF_DM) * (FF_RP - FF_DM)
FF_DHI      = (FF_RP + FF_DM) * (FF_RP + FF_DM)
FF_SHIPR    = SHOT_MUZZ + 32    ; the ship's radius at the edge, world units: past
FF_FOER     = FOE_MUZZ + 32     ;   its own MUZZLE, and an enemy's past its - a gun
                                ;   held nearer would put its bullet out on the far
                                ;   side, where no step of it crosses (a UFO on the
                                ;   edge shot through it, the user's madsim run)
        .assert FF_SHIPR > SHIP_RAD * 32 && FF_FOER > FOE_R * 32, error, "ffield.s: a radius under the body's own circle"
FF_SNAP     = 2                 ; units past the radius a mover is put out to: the
                                ;   products' floors all fall inward
FF_HURTCD   = 20                ; frames after a hurt before the edge hurts again
                                ;   (TBM: pressing on it must not be a drain)
FF_FLASH    = 36                ; frames an invisible field's flash lasts: a strobe,
                                ;   every other frame, then one in four as it dies
FF_ARCB     = 10                ; the template's half-span, brad (+-124 half-res px)
FF_NI       = 2                 ; pieces drawn either side of the nearest one when
FF_NIZ      = 96                ;   zoomed out past this ZEASH; one when in
FF_RIN      = 36                ; ff_far: high bytes both under this are deep inside
        .assert (FF_RIN + 1) * 141 / 100 < FF_RP - FF_PM - 2, error, "ffield.s: FF_RIN's square reaches the band"
FF_STEP     = 2 * FF_ARCB       ; ...end to end
FF_REACH    = 17                ; pages past the cull window a piece reaches: its
                                ;   anchor to its end, FF_R sin 10 brad, 16 pages
        .assert FF_PMAX < 128 && FF_DMAX < 128, error, "ffield.s: the high bytes' squares index QS by 2a"
        .assert FF_R = 16384, error, "ffield.s: FF_SIN is FF_R sin - regenerate it with the radius"

TW_R        = EN_ALIEN_TOWER_R * 32 ; the tower's circle, world units: the editor's
TW_PM       = 12                ; ff_f: a mover within this many pages of the
                                ;   centre on both axes is the tower's - its radius
                                ;   (4.1 pages) + a 192's (4.9) + a step + the
                                ;   high bytes' error, as FF_PM
        .assert TW_PM < FF_RIN, error, "ffield.s: the tower's box reaches the edge's band"
TW_SPIN     = 4                 ; frames a brad: a turn in 17 s
TW_DOWN     = 180               ; frames the EMP takes it down with rocks inside: 3 s
TW_SPK0     = 15                ; frames between sparks, dead: TW_SPK0 + 0..31,
TW_SPKJ     = 31                ;   about half a second, irregular
TW_MASK     = (1 << (EN_ALIEN_TOWER_PN - 1)) - 1 ; dead: every part but the last
TW_GAP      = 160               ; where the last part's middle is: a bearing at
TW_SR       = 849               ;   spin 0, brad, and world units out - S1, (0,75)
                                ;   to (75,0) full-res px: its middle (37.5,37.5)
                                ;   is fb, = world (-37.5, 37.5), 53 px out
TW_DISC     = 38                ; its star-occlusion disc, half-res px at 1:1: to
                                ;   its corners, 75 full-res px
        .assert EN_ALIEN_TOWER_PN = 2, error, "ffield.s: TW_GAP/TW_SR are the middle of the tower's second part - re-measure them"

; --- state: under the window, behind freight.s's --------------------------------
FFB         = FR_END
FFON        = FFB + 0           ; 0 no field in this sector, 1 one
FFCXL       = FFB + 1           ; the centre, world 16-bit, fixed
FFCXH       = FFB + 2
FFCYL       = FFB + 3
FFCYH       = FFB + 4
FFVIS       = FFB + 5           ; 1 drawn, 0 invisible (flashed where it is hit)
FFLK        = FFB + 6           ; the flash: the vertex it is on...
FFLT        = FFB + 7           ; ...and the frames it has left
FFHC        = FFB + 8           ; frames before the edge may hurt the ship again
FFDXL       = FFB + 9           ; ff_f's input: D = a point - the centre, signed
FFDXH       = FFB + 10
FFDYL       = FFB + 11
FFDYH       = FFB + 12
FFK         = FFB + 13          ; ...its outputs: the vertex (a bearing, brad)
FFFL        = FFB + 14          ;   f, signed world units, > 0 outside
FFFH        = FFB + 15
FFNX        = FFB + 16          ;   the outward normal, Q0.7
FFNY        = FFB + 17
FFTB        = FFB + 18          ; ff_xfer: the mover's row of FF_ROCKA
FFT0        = FFB + 22          ; ff_atan's working
FFT1        = FFB + 23
FFT2        = FFB + 24
FFT3        = FFB + 25
FFMN        = FFB + 26          ; ff_ratio's / ff_rsin's
FFS         = FFB + 27
FFSD        = FFB + 28          ; the mover's side: bit 7 = inside
FFI         = FFB + 29          ; the mover's slot
FFRL        = FFB + 30          ; ...its radius, world units
FFRH        = FFB + 31
FFPEN       = FFB + 32          ; how far it is in, world units (2)
FFPXL       = FFB + 34          ; ...its position, world 16-bit (4)
FFPXH       = FFB + 35
FFPYL       = FFB + 36
FFPYH       = FFB + 37
FFWXL       = FFB + 38          ; ...its velocity, signed 8.8 (4)
FFWXH       = FFB + 39
FFWYL       = FFB + 40
FFWYH       = FFB + 41
FFVNL       = FFB + 42          ; ...along the normal, toward its own side
FFVNH       = FFB + 43
FFMD        = FFB + 44          ; ff_mover: 1 bounce, 0 slide; out: 1 closing
FFSX        = FFB + 45          ; the normal turned to the mover's side, Q0.7
FFSY        = FFB + 46
FFJ         = FFB + 47          ; ff_frame: pieces left (ff_xfer: in or out)
FFKK        = FFB + 48          ; ...the piece's vertex (ff_xfer, ff_shot: scratch)
FFAM        = FFB + 49          ; ff_f's circle: $FF the edge, 0 the tower
TWST        = FFB + 50          ; the tower: 0 up, 1..TW_DOWN down, $FF dead
TWAN        = FFB + 51          ; ...its spin, brad
TWSP        = FFB + 52          ; ...frames to its next spark, dead
FF_END      = FFB + 53
        .assert FF_END <= SHAPES_AT, error, "ffield.s: past the RAM under the window"

; =============================================================================
; FFFRAME - slot B: the frame (slots.s's vector table is first), and the side
; function, which both slots call.
; =============================================================================
        .pushseg
        .segment "FFFRAME"

; -----------------------------------------------------------------------------
; ff_frame - WS_FRAME: the clocks, and the drawing.
; -----------------------------------------------------------------------------
ff_frame:
        lda     FFON
        bne     :+
        rts
:       lda     FFHC
        beq     :+
        dec     FFHC
:       jsr     ff_dship                ; D = ship - centre (FFP = the ship)
        jsr     tw_frame                ; the tower: its clocks and its drawing
        lda     TWST                    ; the field is down while the tower is
        bne     @r
        lda     FFVIS
        beq     @nod
        ldx     #FF_BT_D                ; near enough to the edge to see it?
        jsr     ff_band
        bcc     @nod
        lda     FFT1                    ; ...and inside: from outside it is the
        cmp     #>(FF_RP * FF_RP)       ;   invisible one (d^2 >= R^2, pages^2)
        bcs     @nod
        jsr     ff_atan                 ; FFK: the vertex nearest the ship
        lda     FFK                     ; three pieces, or five zoomed out
        sec
        sbc     #FF_STEP
        ldx     #3
        ldy     ZEASH
        cpy     #FF_NIZ
        bcs     :+
        sbc     #FF_STEP - 1            ; (carry clear from the compare)
        ldx     #2 * FF_NI + 1
:       sta     FFKK
        stx     FFJ
@piece: ldx     #$00                    ; the whole template
        ldy     #5
        lda     FFKK
        jsr     ff_arc
        lda     FFKK
        clc
        adc     #FF_STEP
        sta     FFKK
        dec     FFJ
        bne     @piece
        sec                             ; drawn: the flash only runs down
        bra     @fl
@nod:   clc
@fl:    lda     FFLT
        beq     @r
        dec     FFLT
        bcs     @r
        lda     FFLT                    ; the strobe: on every other frame while
        ldx     #$01                    ;   fresh, one in four as it dies away
        cmp     #FF_FLASH / 2
        bcs     :+
        ldx     #$03
:       txa
        and     FFLT
        bne     @r
        lda     FFLT                    ; ...and it crawls, a brad on and back
        and     #$04
        lsr     a
        lsr     a
        clc
        adc     FFLK
        ldx     #$02                    ; the template's middle three vertices
        ldy     #3
        jmp     ff_arc
@r:     rts

; -----------------------------------------------------------------------------
; ff_arc - one piece: A = its vertex, X = the byte in FF_TPL its first vertex
; starts at, Y = how many vertices; FFP = the ship. Culled on its anchor, the
; base's way.
; -----------------------------------------------------------------------------
ff_arc:
        stx     FFSY                    ; (FFSX/FFSY are the movers'; free here)
        sty     FFSX
        sta     FFK
        jsr     ff_p0                   ; P = centre - ship...
        ldx     #$00                    ; ...+ VTX[k], x then y
@ax:    lda     FFK
        cpx     #$00
        beq     :+
        sec
        sbc     #64                     ; FF_R sin(k - 64) = -FF_R cos k
:       phx
        jsr     ff_rsin
        stx     FFT1
        plx
        clc
        adc     PXL,x
        sta     PXL,x
        lda     FFT1
        adc     PXH,x
        sta     PXH,x
        inx
        inx
        cpx     #$04
        bne     @ax
        jsr     ff_view
        bcc     :+
        rts
:       ldx     #$02                    ; the anchor, halved: DOT_POLYGON is half-res
@h:     lda     FXH,x
        cmp     #$80
        ror     a
        sta     PBUF+1,x
        lda     FXL,x
        ror     a
        sta     PBUF+0,x
        dex
        dex
        bpl     @h
        lda     FFK                     ; ANGLE: the piece's own, and the camera's
        sec
        sbc     HEAD
        sta     PBUF+4
        lda     ZEASH                   ; SCALE: half-res units at 1:1, as the base
        sta     PBUF+5
        lda     FFSX
        ora     #$80                    ; OPEN
        sta     PBUF+6
        lda     FFSX
        asl     a
        sta     FFT0                    ; 2K offset bytes
        ldx     FFSY
        ldy     #$00
@cp:    lda     FF_TPL,x
        sta     PBUF+7,y
        inx
        iny
        cpy     FFT0
        bne     @cp
        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jmp     API_GPU_DOTPOLYGON      ; tail

; The template: half-res px at 1:1, in the framebuffer's axes for an anchor at
; vertex 0 with HEAD 0 - fb = (world y, -world x) - five vertices at -10, -5, 0,
; 5 and 10 brads along the circle from the anchor: (R (1 - cos a), -R sin a) / 32.
; Each edge is 5 brads, 2,011 units, and stands 31 units (one half-res px) off
; the arc at its middle. The flash is the middle three.
FF_TPL:     .byte   15, 124,   4, 63,   0, 0,   4, <-63,   15, <-124

; SE_ZAP - something hit the field: two bursts of buzz, the periodic noise (0,
; 1) against white crackle (4) a frame at a time, the second weaker. On the
; noise voice at PRI_KLANG (sfx.s). Here, in slot B, because nothing but the
; field fires it; the IRQ reads it from DEMO_RAM, as emp.s's programs.
se_zap:
        .byte   $01                     ; noise
        .byte   1, 0, 13
        .byte   1, 4, 12
        .byte   1, 0, 13
        .byte   1, 4, 11
        .byte   1, 1, 12
        .byte   1, 4, 10
        .byte   3, 0, 0                 ; ...bzz - bzz
        .byte   1, 0, 11
        .byte   1, 4, 10
        .byte   1, 0, 10
        .byte   1, 4, 8
        .byte   1, 1, 7
        .byte   2, 0, 5
        .byte   3, 4, 2
        .byte   $FF                     ; 18 frames = LEN_ZAP

; ff_dship - FFP = the ship's position, and on into ff_dp.
ff_dship:
        lda     SHXL
        sta     FFPXL
        lda     SHXH
        sta     FFPXH
        lda     SHYL
        sta     FFPYL
        lda     SHYH
        sta     FFPYH
; ff_dp - D = FFP - the centre, both axes (signed: the wrap is free).
ff_dp:
        ldx     #$02
@l:     sec
        lda     FFPXL,x
        sbc     FFCXL,x
        sta     FFDXL,x
        lda     FFPXH,x
        sbc     FFCXH,x
        sta     FFDXH,x
        dex
        dex
        bpl     @l
        rts

; ff_p0 - P = the centre - FFP, both axes: the field's middle seen from the ship.
ff_p0:
        ldx     #$02
@l:     sec
        lda     FFCXL,x
        sbc     FFPXL,x
        sta     PXL,x
        lda     FFCXH,x
        sbc     FFPXH,x
        sta     PXH,x
        dex
        dex
        bpl     @l
        rts

; ff_view - P, world units from the ship: carry SET = off the rocks' coarse
; window grown by FF_REACH (which also keeps view_xform's input inside what it
; can rotate); CLEAR = FX/FY, its framebuffer point.
ff_view:
        ldy     #$01
@cull:  tya
        asl     a
        tax
        lda     CULH,y
        clc
        adc     #FF_REACH
        sta     T0
        asl     a
        adc     #$01
        sta     T1
        lda     PXH,x
        clc
        adc     T0
        cmp     T1
        bcs     @r
        dey
        bpl     @cull
        jsr     view_xform
        jsr     zoom_fb
        clc
@r:     rts

; -----------------------------------------------------------------------------
; ff_band -D's high bytes against a band round the edge, d^2 in pages^2 by two
; quarter-square reads: X = FF_BT_F the movers' (FF_PM pages), FF_BT_D the
; drawing's (FF_DM). Carry SET = in it.
; -----------------------------------------------------------------------------
ff_band:
        lda     FFDXH
        jsr     ff_absh
        cmp     FF_BT,x
        bcs     @far
        asl     a
        sta     FFT2
        lda     FFDYH
        jsr     ff_absh
        cmp     FF_BT,x
        bcs     @far
        asl     a
        tay
        phx
        ldx     FFT2
        clc                             ; f(2a) = a*a
        lda     QSL,x
        adc     QSL,y
        sta     FFT0
        lda     QSH,x
        adc     QSH,y
        sta     FFT1
        plx
        lda     FFT0                    ; d^2 >= lo...
        cmp     FF_BT+1,x
        lda     FFT1
        sbc     FF_BT+2,x
        bcc     @far
        lda     FF_BT+3,x               ; ...and hi >= d^2
        cmp     FFT0
        lda     FF_BT+4,x
        sbc     FFT1
        rts
@far:   clc
        rts

FF_BT:      .byte   FF_PMAX, <FF_BLO, >FF_BLO, <FF_BHI, >FF_BHI
            .byte   FF_DMAX, <FF_DLO, >FF_DLO, <FF_DHI, >FF_DHI
            .byte   FF_RP, 0, 0, <(FF_RP * FF_RP - 1), >(FF_RP * FF_RP - 1)
FF_BT_F     = 0
FF_BT_D     = 5
FF_BT_I     = 10                ; ...and the whole inside: ff_emp's count

; -----------------------------------------------------------------------------
; ff_f - D in FFDX/FFDY. Carry CLEAR = far from the edge (nothing else is
; computed); SET = in the band, and FFK the vertex, FFNX/FFNY its normal, FFF
; f. Near the middle it is the TOWER's circle instead (FFAM 0; the header).
; Clobbers A, X, Y, MA/MB/MR, MQ*, FFT*, FFMN, FFS.
; -----------------------------------------------------------------------------
ff_f:
        stz     FFFL
        stz     FFFH
        ldx     #$02                    ; both high bytes near the middle: the
@box:   lda     FFDXH,x                 ;   tower, f = D.n - TW_R
        jsr     ff_absh
        cmp     #TW_PM
        bcs     @edge
        dex
        dex
        bpl     @box
        lda     #<(-TW_R)
        sta     FFFL
        lda     #>(-TW_R)
        sta     FFFH
        lda     #$00
        bra     @go
@edge:  lda     TWST                    ; the edge, while the tower holds it up
        bne     @no
        ldx     #FF_BT_F
        jsr     ff_band
        bcc     @r
        lda     #$FF
@go:    sta     FFAM
        jsr     ff_atan                 ; FFK
        ldx     #$00                    ; f = (D - VTX[k]).n, x then y
@ax:    lda     FFK
        cpx     #$00
        beq     :+
        sec
        sbc     #64                     ; FF_R sin(k - 64) = -FF_R cos k
:       phx
        jsr     ff_rsin                 ; X:A = this axis of VTX[k]
        sta     FFT0
        stx     FFT1
        jsr     ff_n                    ; ...and of n
        bit     FFAM                    ; the tower: D.n, no vertex
        bmi     :+
        stz     FFT0
        stz     FFT1
:       ply                             ; Y = the axis, x2
        pha
        tya
        lsr     a
        tax
        pla
        sta     FFNX,x
        sta     MB
        sec
        lda     FFDXL,y
        sbc     FFT0
        sta     MAL
        lda     FFDXH,y
        sbc     FFT1
        sta     MAH
        phy
        jsr     smul16q7
        clc
        lda     MAL
        adc     FFFL
        sta     FFFL
        lda     MAH
        adc     FFFH
        sta     FFFH
        plx
        inx
        inx
        cpx     #$04
        bne     @ax
        sec
        rts
@no:    clc
@r:     rts

; -----------------------------------------------------------------------------
; ff_atan - FFK = the bearing of D: foe_atan's, on its own scratch (foes.s's FE*
; are an enemy's, and WS_FOE runs in the middle of one).
; -----------------------------------------------------------------------------
ff_atan:
        lda     FFDXL                   ; |D|, both axes
        ldx     FFDXH
        jsr     ff_abs16
        sta     FFT0
        stx     FFT1
        lda     FFDYL
        ldx     FFDYH
        jsr     ff_abs16
        sta     FFT2
        stx     FFT3
@dn:    lda     FFT1                    ; down together until both fit 7 bits
        ora     FFT3
        bne     @sh
        lda     FFT0
        ora     FFT2
        bpl     @small
@sh:    lsr     FFT1
        ror     FFT0
        lsr     FFT3
        ror     FFT2
        bra     @dn
@small: lda     FFT0
        cmp     FFT2
        bcs     @xbig
        ldx     FFT0                    ; |dy| the larger: theta = atan(|dx|/|dy|)
        lda     FFT2
        jsr     ff_ratio
        tay
        lda     ATAN_T,y
        bra     @quad
@xbig:  lda     FFT0                    ; |dx| the larger: 64 - atan(|dy|/|dx|)
        beq     @quad
        ldx     FFT2
        jsr     ff_ratio
        tay
        lda     ATAN_T,y
        eor     #$FF
        sec
        adc     #64
@quad:  sta     FFT1
        lda     FFDXH
        bmi     @left
        lda     FFDYH
        bmi     @q0
        lda     #128
        sec
        sbc     FFT1
        bra     @done
@q0:    lda     FFT1
        bra     @done
@left:  lda     FFDYH
        bmi     @q3
        lda     #128
        clc
        adc     FFT1
        bra     @done
@q3:    lda     #$00
        sec
        sbc     FFT1
@done:  sta     FFK
        rts

; ff_ratio - foes.s f_ratio on FFMN/FFS: A = the larger 1..127, X = the smaller
; -> A = 128 * smaller / larger.
ff_ratio:
        stx     FFMN
        ldy     #$00
@up:    cmp     #65
        bcs     @ok
        asl     a
        iny
        bra     @up
@ok:    sty     FFS
        sec
        sbc     #65
        tax
        lda     RECIP64,x
        sta     MQB
        lda     FFMN
        ldy     FFS
        beq     @go
@l:     asl     a
        dey
        bne     @l
@go:    sta     MQA
        jsr     pmul6
        cmp     #129
        bcc     :+
        lda     #128
:       rts

; ff_rsin - A = k -> X:A = FF_R sin k, from the quarter in FF_SIN.
ff_rsin:
        sta     FFS
        and     #$7F
        cmp     #65
        bcc     :+
        eor     #$7F                    ; 65..127 -> 128 - x
        inc     a
:       asl     a
        tay
        ldx     FF_SIN+1,y
        lda     FF_SIN,y
        bit     FFS
        bmi     ff_neg16                ; the half turn: negated
        rts
; ff_abs16 / ff_neg16 - X:A, |it| / negated.
ff_abs16:
        cpx     #$80
        bcc     ff_r16
ff_neg16:
        eor     #$FF
        clc
        adc     #$01
        pha
        txa
        eor     #$FF
        adc     #$00
        tax
        pla
ff_r16: rts

; ff_absh - A = |A| for a signed high byte, with -128 read as 127: past any band.
ff_absh:
        bpl     @r
        eor     #$FF
        inc     a
        bpl     @r
        lda     #$7F
@r:     rts

; ff_n - X:A = a 16-bit FF_R sin -> A = it as Q0.7, >> 7, +-128 held at +-127
; (smul16q7 cannot take -128).
ff_n:
        asl     a
        txa
        rol     a
        cmp     #$80
        bne     @r
        cpx     #$00
        bmi     @neg
        lda     #$7F
        rts
@neg:   lda     #$81
@r:     rts

; FF_R sin(j), j = 0..64 brad: the quarter every vertex is read from.
FF_SIN:
        .word   0, 402, 804, 1205, 1606, 2006, 2404, 2801
        .word   3196, 3590, 3981, 4370, 4756, 5139, 5520, 5897
        .word   6270, 6639, 7005, 7366, 7723, 8076, 8423, 8765
        .word   9102, 9434, 9760, 10080, 10394, 10702, 11003, 11297
        .word   11585, 11866, 12140, 12406, 12665, 12916, 13160, 13395
        .word   13623, 13842, 14053, 14256, 14449, 14635, 14811, 14978
        .word   15137, 15286, 15426, 15557, 15679, 15791, 15893, 15986
        .word   16069, 16143, 16207, 16261, 16305, 16340, 16364, 16379
        .word   16384

; =============================================================================
; FFWALL - slot A: the movers.
; =============================================================================
        .segment "FFWALL"

; -----------------------------------------------------------------------------
; ff_rock - WS_ROCK, X = the rock's slot (kept): bounced off the edge.
; ff_foe  - WS_FOE, X = the enemy's slot (kept): slid along it.
; Nearly every one ends at ff_far, on its high bytes.
; -----------------------------------------------------------------------------
ff_rock:
        lda     FFON
        beq     ff_rts
        lda     OBJXH,x
        ldy     OBJYH,x
        jsr     ff_far
        bcs     ff_rts
        stx     FFI
        ldy     OBJSHP,x                ; its circle: BODY_R collision units, x32
        lda     BODY_R,y
        stz     FFRH
        ldy     #5
:       asl     a
        rol     FFRH
        dey
        bne     :-
        sta     FFRL
        lda     #$01                    ; bounce, the rock's arrays (row 0)
        ldy     #$00
        bra     ff_obj
ff_foe:
        lda     FFON
        beq     ff_rts
        lda     FOEXH,x
        ldy     FOEYH,x
        jsr     ff_far
        bcs     ff_rts
        stx     FFI
        lda     #<FF_FOER
        sta     FFRL
        lda     #>FF_FOER
        sta     FFRH
        lda     #$00                    ; slide, the enemy's arrays
        ldy     #FF_FOEA - FF_ROCKA
ff_obj: sty     FFTB
        pha
        lda     #$00
        jsr     ff_xfer                 ; in
        pla
        jsr     ff_mover
        bcc     ff_rtx
        lda     #$01
        jsr     ff_xfer                 ; ...and out
        lda     FFTB                    ; a ROCK that struck it lights it
        bne     ff_rtx
        lda     FFMD
        beq     ff_rtx
        jsr     ff_lit
ff_rtx: ldx     FFI
ff_rts: rts

; ff_far - A, Y = a mover's x and y high bytes: carry SET = it is nowhere near
; the edge or the tower - outside the band's box, or deep inside its inner
; square but outside the tower's. On the larger of |dx|, |dy|. X kept.
ff_far:
        sec
        sbc     FFCXH
        jsr     ff_absh
        sta     FFT0
        tya
        sec
        sbc     FFCYH
        jsr     ff_absh
        cmp     FFT0
        bcs     :+
        lda     FFT0
:       cmp     #FF_PMAX
        bcs     @r                      ; past the box
        cmp     #FF_RIN
        bcs     @no                     ; the band's
        cmp     #TW_PM                  ; deep inside: far, unless the tower's
        rts
@no:    clc
@r:     rts

; ff_xfer - A = 0: the mover's eight bytes (FF_ROCKA row FFTB, slot FFI) into
; FFP..FFW; 1: back out.
ff_xfer:
        sta     FFJ
        ldx     FFTB
        stz     FFKK
@l:     lda     FF_ROCKA,x
        sta     T2
        lda     FF_ROCKA+1,x
        sta     T3
        ldy     FFKK
        lda     FFJ
        bne     @w
        ldy     FFI
        lda     (T2),y
        ldy     FFKK
        sta     FFPXL,y
        bra     @n
@w:     lda     FFPXL,y
        ldy     FFI
        sta     (T2),y
@n:     inx
        inx
        inc     FFKK
        lda     FFKK
        cmp     #8
        bne     @l
        rts

; Each mover's arrays, in FFP..FFW's order: position x y, then velocity x y (a
; bullet's: the whole units of its 16.8 step).
FF_ROCKA:   .word   OBJXL, OBJXH, OBJYL, OBJYH, OBJVXL, OBJVXH, OBJVYL, OBJVYH
FF_FOEA:    .word   FOEXL, FOEXH, FOEYL, FOEYH, FOEVXL, FOEVXH, FOEVYL, FOEVYH
FF_SHTA:    .word   SHTXL, SHTXH, SHTYL, SHTYH, SHTVXH, SHTVXT, SHTVYH, SHTVYT
FF_FSA:     .word   FSXL, FSXH, FSYL, FSYH, FSVXH, FSVXT, FSVYH, FSVYT

; -----------------------------------------------------------------------------
; ff_mover - a rock or an enemy, AFTER its step: FFP its position, FFW its
; velocity (8.8), FFR its radius, A = 1 bounce / 0 slide. Carry SET = it was put
; back (FFP, FFW changed), and then FFMD = 1 if it was closing on the edge.
; -----------------------------------------------------------------------------
ff_mover:
        sta     FFMD
        jsr     ff_dp                   ; D = the new centre - the centre...
        ldx     #$02                    ; ...minus the step's whole units: the OLD
@old:   ldy     #$00                    ;   centre, whose side it is
        lda     FFWXH,x
        bpl     :+
        dey
:       sta     FFT0
        sty     FFT1
        sec
        lda     FFDXL,x
        sbc     FFT0
        sta     FFDXL,x
        lda     FFDXH,x
        sbc     FFT1
        sta     FFDXH,x
        dex
        dex
        bpl     @old
        jsr     ff_f
        bcs     :+
        rts                             ; far from the edge: nothing to touch
:       lda     FFFH
        and     FFAM                    ; (the tower's side is always outside)
        sta     FFSD                    ; the side, from the old centre
        jsr     ff_dp                   ; the new centre
        jsr     ff_f
        bcc     @no
        jsr     ff_pen                  ; in by FFPEN? FFS* the normal to its side
        bcc     @no
        jsr     ff_push2                ; put back
        stz     FFVNL                   ; vn = W . ns, 8.8
        stz     FFVNH
        ldx     #$02
@vn:    lda     FFWXL,x
        sta     MAL
        lda     FFWXH,x
        sta     MAH
        jsr     ff_mbs
        clc
        lda     MAL
        adc     FFVNL
        sta     FFVNL
        lda     MAH
        adc     FFVNH
        sta     FFVNH
        dex
        dex
        bpl     @vn
        lda     FFVNH
        bmi     @close
        stz     FFMD                    ; parting already: just put back
        sec
        rts
@close: lda     FFMD                    ; bounce: take vn off twice
        beq     :+
        asl     FFVNL
        rol     FFVNH
:       ldx     #$02                    ; W -= vn ns
@w:     lda     FFVNL
        sta     MAL
        lda     FFVNH
        sta     MAH
        jsr     ff_mbs
        sec
        lda     FFWXL,x
        sbc     MAL
        sta     FFWXL,x
        lda     FFWXH,x
        sbc     MAH
        sta     FFWXH,x
        dex
        dex
        bpl     @w
        lda     #$01
        sta     FFMD
        sec
        rts
@no:    clc
        rts

; ff_mbs - MA *= this axis of ns (X = the axis, x2; kept).
ff_mbs:
        txa
        lsr     a
        tay
        lda     FFSX,y
        sta     MB
        phx
        jsr     smul16q7
        plx
        rts

; ff_push2 - FFP += (FFPEN + FF_SNAP) ns, both axes.
ff_push2:
        ldx     #$02
@l:     clc
        lda     FFPEN
        adc     #FF_SNAP
        sta     MAL
        lda     FFPEN+1
        adc     #$00
        sta     MAH
        jsr     ff_mbs
        clc
        lda     FFPXL,x
        adc     MAL
        sta     FFPXL,x
        lda     FFPXH,x
        adc     MAH
        sta     FFPXH,x
        dex
        dex
        bpl     @l
        rts

; ff_pen - after ff_f on the new centre, FFSD the side: carry SET = it is closer
; to the edge than its radius FFR on its own side, by FFPEN; FFSX/FFSY = the
; normal pointing to its side (n outside, -n inside).
ff_pen:
        ldx     #$01
@n:     lda     FFNX,x
        bit     FFSD
        bpl     :+
        eor     #$FF
        inc     a
:       sta     FFSX,x
        dex
        bpl     @n
        lda     FFFL                    ; g = f outside, -f inside
        ldx     FFFH
        bit     FFSD
        bpl     :+
        jsr     ff_neg16
:       sta     FFT0
        stx     FFT1
        sec                             ; pen = r - g
        lda     FFRL
        sbc     FFT0
        sta     FFPEN
        lda     FFRH
        sbc     FFT1
        sta     FFPEN+1
        bmi     @no                     ; (pen is small: its sign is bit 15)
        ora     FFPEN
        beq     @no
        sec
        rts
@no:    clc
        rts

; ff_lit - the flash, on the vertex ff_f last found (FFK), and the zap - unless
; the last one is still sounding. Nothing for the tower (FFAM 0).
ff_lit:
        bit     FFAM
        bpl     ff_lt_r
        lda     FFLT
        cmp     #FF_FLASH - LEN_ZAP + 1
        bcs     :+
        lda     #SE_ZAP
        jsr     sfx_fire
:       lda     FFK
        sta     FFLK
        lda     #FF_FLASH
        sta     FFLT
ff_lt_r:
        rts

; -----------------------------------------------------------------------------
; ff_brake - WS_BRAKE: do_ship, BEFORE the step. Kept on its side by moving it
; first, so that the step ends on the edge; closing, kicked off and hurt.
; -----------------------------------------------------------------------------
ff_brake:
        lda     FFON
        beq     @r
        lda     SHIPGONE
        bne     @r
        jsr     ff_dship                ; the side, now
        jsr     ff_f
        bcc     @r
        lda     FFFH
        and     FFAM
        sta     FFSD
        clc                             ; ...and where the step would put it: the
        lda     SHXF                    ;   true 24-bit sum, base_brake's way
        adc     VELXL
        lda     SHXL
        adc     VELXH
        sta     FFPXL
        lda     SHXH
        adc     VELXT
        sta     FFPXH
        clc
        lda     SHYF
        adc     VELYL
        lda     SHYL
        adc     VELYH
        sta     FFPYL
        lda     SHYH
        adc     VELYT
        sta     FFPYH
        jsr     ff_dp
        jsr     ff_f
        bcc     @r
        lda     #<FF_SHIPR
        sta     FFRL
        lda     #>FF_SHIPR
        sta     FFRH
        jsr     ff_pen
        bcs     ff_ship_hit
@r:     rts

; The ship is in by FFPEN on its side. Toward the edge is -ns: the EMP mine's
; normal "ship -> obstacle", so its impulse maths is taken as it stands.
ff_ship_hit:
        jsr     ff_dship                ; the snap: moved out by pen BEFORE its
        jsr     ff_push2                ;   step, so the step ends on the edge
        lda     FFPXL
        sta     SHXL
        lda     FFPXH
        sta     SHXH
        lda     FFPYL
        sta     SHYL
        lda     FFPYH
        sta     SHYH
        bit     FFAM                    ; the tower: a wall the ship slides on,
        bpl     ff_lt_r                 ;   as the base's - no kick, no hurt
        ldx     #$01                    ; COL_N = -ns, toward the edge
@n:     lda     FFSX,x
        eor     #$FF
        inc     a
        sta     COL_NX,x
        dex
        bpl     @n
        stz     COL_VNL                 ; vn = (0 - V).n, empm_bump's own: the
        stz     COL_VNH                 ;   16.8 velocity saturated (vel_sat)
        ldx     #$01
@vn:    phx
        txa
        asl     a
        tay
        sec
        lda     #$00
        sbc     VELXL,y
        sta     COL_T0
        lda     #$00
        sbc     VELXH,y
        sta     COL_T1
        lda     #$00
        sbc     VELXT,x
        jsr     vel_sat
        lda     COL_T0
        sta     MAL
        lda     COL_T1
        sta     MAH
        plx
        phx
        lda     COL_NX,x
        sta     MB
        jsr     smul16q7
        clc
        lda     MAL
        adc     COL_VNL
        sta     COL_VNL
        lda     MAH
        adc     COL_VNH
        sta     COL_VNH
        plx
        dex
        bpl     @vn
        lda     COL_VNH
        bmi     :+
        rts                             ; parting, or still: put out, no more
:       lda     COL_VNL                 ; peg the closing speed, ship_respond's
        cmp     #<(65536-COL_VNMAX)     ;   own bound
        lda     COL_VNH
        sbc     #>(65536-COL_VNMAX)
        bcs     :+
        lda     #<(65536-COL_VNMAX)
        sta     COL_VNL
        lda     #>(65536-COL_VNMAX)
        sta     COL_VNH
:       lda     COL_VNL                 ; P = vn + vn/2 + vn/4
        sta     COL_T0
        lda     COL_VNH
        sta     COL_T1
        jsr     asr_t
        clc
        lda     COL_VNL
        adc     COL_T0
        sta     COL_PL
        lda     COL_VNH
        adc     COL_T1
        sta     COL_PH
        jsr     asr_t
        clc
        lda     COL_PL
        adc     COL_T0
        sta     COL_PL
        lda     COL_PH
        adc     COL_T1
        sta     COL_PH
        ldx     #$01                    ; I = P n
@i:     lda     COL_PL
        sta     MAL
        lda     COL_PH
        sta     MAH
        lda     COL_NX,x
        sta     MB
        phx
        jsr     smul16q7
        pla
        pha
        asl     a
        tax
        lda     MAL
        sta     COL_IXL,x
        lda     MAH
        sta     COL_IXH,x
        plx
        dex
        bpl     @i
        lda     #EMPM_FI                ; an immovable wall: the mine's share
        sta     COL_FI
        jsr     ship_kick               ; the knockback and the throttle
        lda     FFHC                    ; ...and a ram's worth, as for a rock,
        bne     @lit                    ;   unless it hurt a moment ago
        lda     #FF_HURTCD
        sta     FFHC
        lda     #RAM_DMG
        jsr     ship_hurt
@lit:   jmp     ff_lit                  ; (after the klang: the zap takes the
                                        ;   noise voice from its crunch)

; -----------------------------------------------------------------------------
; ff_shot_p / ff_shot_f - WS_SHOTP / WS_SHOTF: X = the bullet's slot (kept),
; AFTER its step. Carry SET = its step crossed the edge: the puff, and it is
; spent (the player's slot freed here, the enemy's by the caller).
; -----------------------------------------------------------------------------
ff_shot_p:
        ldy     #FF_SHTA - FF_ROCKA
        jsr     ff_shot
        bcc     @r
        jsr     expl_spawn              ; the puff on its tip; spent, paying nothing
        ldx     FFI
        stz     SHTLIVE,x
        sec
@r:     rts

ff_shot_f:
        ldy     #FF_FSA - FF_ROCKA
        jsr     ff_shot
        bcc     @r
        jsr     fsh_bang                ; the puff (it reads FSI)
        ldx     FFI
        sec
@r:     rts

; ff_shot - X = the slot, Y = its row of FF_ROCKA: carry SET = its step crossed
; the edge (the flash lit). X = the slot either way.
ff_shot:
        lda     FFON
        beq     @off
        stx     FFI
        sty     FFTB
        lda     #$00
        jsr     ff_xfer                 ; FFP its end, FFW the step's whole units
        jsr     ff_dp                   ; the new end
        jsr     ff_f
        bcc     @no
        lda     FFFH
        sta     FFSD
        lda     FFK
        sta     FFKK                    ; its vertex, for the flash
        ldx     #$02                    ; FFP -= the step: the old end
@o:     sec
        lda     FFPXL,x
        sbc     FFWXL,x
        sta     FFPXL,x
        lda     FFPXH,x
        sbc     FFWXH,x
        sta     FFPXH,x
        dex
        dex
        bpl     @o
        jsr     ff_dp
        jsr     ff_f
        lda     FFKK
        sta     FFK
        bcc     @no
        lda     FFFH                    ; the two ends' sides differ?
        eor     FFSD
        asl     a
        bcc     @no
        jsr     ff_lit
        ldx     FFI
        sec
        rts
@no:    ldx     FFI
@off:   clc
        rts

; -----------------------------------------------------------------------------
; tw_frame - ff_frame, FFP = the ship: the tower's spin and clocks, its sparks
; when dead, and its drawing - gate.s's gb_draw, as the base's.
; -----------------------------------------------------------------------------
tw_frame:
        lda     FRAME                   ; a brad every TW_SPIN frames
        and     #TW_SPIN - 1
        bne     :+
        inc     TWAN
:       ldx     TWST
        beq     @draw                   ; up
        inx
        beq     @dead
        dec     TWST                    ; down: up again when it runs out,
        bne     @draw                   ;   and says so
        lda     #SE_TWUP
        jsr     sfx_fire
        bra     @draw
@dead:  dec     TWSP                    ; dead: a spark now and then
        bne     @draw
        jsr     prng
        and     #TW_SPKJ
        adc     #TW_SPK0
        sta     TWSP
        ldx     #$02                    ; ...where the last part was: the centre +
@sp:    lda     TWAN                    ;   TW_SR (sin, -cos) of its bearing, y
        clc                             ;   then x
        adc     #TW_GAP
        cpx     #$00
        beq     :+
        sec
        sbc     #64
:       phx
        jsr     ff_rsin
        jsr     ff_n                    ; Q0.7
        sta     MB
        lda     #<TW_SR
        sta     MAL
        lda     #>TW_SR
        sta     MAH
        jsr     smul16q7
        plx
        clc
        lda     MAL
        adc     FFCXL,x
        sta     EXTXL,x
        lda     MAH
        adc     FFCXH,x
        sta     EXTXH,x
        dex
        dex
        bpl     @sp
        jsr     expl_at                 ; a blaster's puff
@draw:  jsr     ff_p0
        jsr     ff_view
        bcs     @r
        lda     #TW_DISC                ; the stars kept out of it (occlude.s, a
        sta     MQA                     ;   rock's way): the radius with the zoom,
        lda     ZOOMH                   ;   the centre halved
        sta     MQB
        jsr     qmul
        sta     AOCR
        ldx     #$02
:       lda     FXH,x
        cmp     #$80
        ror     a
        sta     CX2H,x
        lda     FXL,x
        ror     a
        sta     CX2L,x
        dex
        dex
        bpl     :-
        jsr     add_disc
        lda     #EA_ALIEN_TOWER
        sta     GBAP
        stz     GBST
        lda     TWAN
        sta     GBAN
        ldx     #$FF                    ; up: every part, solid (POLYGON16)
        ldy     #$02
        lda     TWST
        beq     @go
        dey                             ; down or dead: dotted (DOT_POLYGON)...
        inc     a
        bne     @go
        ldx     #TW_MASK                ; ...and dead: without its last part
@go:    stx     GBMK
        sty     GBSH
        jsr     gb_draw
@r:
; ...and its radar mark: the freighter's 2x2, blinking with the enemies while it
; stands, steady once it is dead - no threat, still in the way.
        lda     TWST
        inc     a                       ; dead ($FF): steady
        beq     :+
        lda     RBLINK
        cmp     #RAD_BLINK_ON
        bcs     @nr
:       lda     FFCXH
        ldy     FFCYH
        jsr     gr_pos
        bcs     @nr
        lda     #GSQ_N
        ldx     #GSQ_X
        jmp     gr_mark                 ; tail
@nr:    rts

; -----------------------------------------------------------------------------
; ff_emp - WS_EMP: do_emp, EMK this frame's reach. A tower that is up and inside
; it goes down: for TW_DOWN frames if any rock is inside the field, for good if
; none is - counted here, once, on the rocks' high bytes (ff_band's inside row).
; -----------------------------------------------------------------------------
ff_emp:
        lda     FFON
        beq     @r
        lda     TWST
        bne     @r                      ; down or dead already
        lda     FFCXH
        ldy     FFCYH
        jsr     emp_rt
        bcc     @r
        lda     #TW_DOWN
        sta     TWST
        ldx     #NOBJ - 1
@lp:    lda     OBJSHP,x                ; every rock but the 16s (class 4,
        cmp     #4                      ;   the user) - and SHP_DEAD is past it
        bcs     @nx
        sec
        lda     OBJXH,x
        sbc     FFCXH
        sta     FFDXH
        sec
        lda     OBJYH,x
        sbc     FFCYH
        sta     FFDYH
        phx
        ldx     #FF_BT_I
        jsr     ff_band
        plx
        bcs     @zap                    ; one is enough
@nx:    dex
        cpx     #$FF
        bne     @lp
        lda     #$FF                    ; none: down for good - the fall, and a
        sta     TWST                    ;   blast where it ends, with the first
        lda     #LEN_TWSWEEP + 1        ;   spark
        sta     TWSP
        lda     #SE_TWDIE_N
        jsr     sfx_fire
@zap:   lda     #SE_TWDOWN
        jmp     sfx_fire                ; tail
@r:     rts

        .popseg

; -----------------------------------------------------------------------------
; ff_load - level_begin, after base_load: this sector's field, or none. LOADER
; CODE (loader.s): it writes the RAM under the window, never reads it.
; -----------------------------------------------------------------------------
        .pushseg
        .segment "LDCODE"
ff_load:
        ldx     CURLEV
        lda     LVL_FF_ON,x
        sta     FFON
        beq     :+
        lda     #WK_FIELD               ; the wall slots' tenant: the field
        sta     WSKIND                  ;   (base_load said the base)
:       lda     LVL_FF_XL,x
        sta     FFCXL
        lda     LVL_FF_XH,x
        sta     FFCXH
        lda     LVL_FF_YL,x
        sta     FFCYL
        lda     LVL_FF_YH,x
        sta     FFCYH
        lda     LVL_FF_VIS,x
        sta     FFVIS
        stz     FFLT
        stz     FFHC
        stz     TWST                    ; the tower stands
        rts
        .popseg
