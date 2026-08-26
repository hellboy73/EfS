; =============================================================================
; EfS proto 01 — flight model bench
; =============================================================================
; PURPOSE: measure what is playable, nothing else. There is no gameplay here,
; no collision and no zoom — just the camera, the speed tiers, the starfield and
; the rocks, so we can look at the screen and decide what the ship should feel
; like. Every number this thing shows is meant to be argued with.
;
; TATE: turn the monitor 90 deg CLOCKWISE (madsim: --tate, or F12).
;
; WHAT IS ON SCREEN
;   * a starfield: 110 stars living in their own 256x256 wrapping layer, drawn
;     as half-res DOT_PIXELS. They are NOT world objects, have no world
;     coordinates and are not affected by zoom (there is no zoom yet). They move
;     at 1/8 of the ship's speed, and they ROTATE with the camera — parallax
;     applies to translation only, so a layer that slid but did not turn would
;     tear away from the world on every turn.
;   * the ship: a 32x32 sprite installed into slot 1 at boot, always nose-up,
;     riding up and down the screen with the speed tier.
;   * 250 drifting asteroids with real world positions, velocities and spins,
;     drawn as dotted outlines at one of five sizes: 192, 128, 64, 32 and 16
;     full-res pixels across. Nothing collides with anything.
;   * a HUD reading out speed, turn rate, the visible star count and how many
;     rocks were drawn.
;
; TWO THINGS THIS BENCH DELIBERATELY GETS "WRONG", SO WE CAN JUDGE THEM
;   1. Heading is a full 8-bit brad angle (256 steps), not the 32 directions the
;      design assumes. Since the ship is always drawn nose-up, the only place 32
;      vs 256 can show up is the smoothness of the world's rotation — so run it
;      at 256 first and see whether 32 would have been visibly steppy.
;   2. Stars are suppressed inside the SHIP's sprite box only. The ship's art
;      has an overlay plane and would hide them anyway, but the box is what the
;      real game needs for opaque objects, so it stays here to be measured. The
;      asteroids get no box on purpose: a dotted outline is HOLLOW, and stars
;      showing through one is the correct picture, not a bug.
;
; CONTROLS (joystick 1)
;   LEFT / RIGHT   turn (held)
;   UP / DOWN      one speed tier up / down (on press, not held)
;   FIRE           cycle the turn rate — the knob we are here to judge
;
; COORDINATE SYSTEMS — the one thing worth reading before editing
;   world        16-bit per axis, unit = 1/16 full-res pixel. Wraps by 16-bit
;                overflow: there is no wrap code anywhere in this file, and a
;                16-bit subtract read as signed IS the shortest distance across
;                the seam. Do not "fix" that by adding a boundary test.
;   view         the player's portrait screen, +x right, +y down, origin centre.
;   framebuffer  what the hardware draws. TATE clockwise means
;                  fb_x = portrait_y   and   fb_y = 299 - portrait_x
;                so the full-res centre is fb (200, 149) and the half-res centre
;                is fb (100, 74).
;
;   asteroid    a vertex list in half-res pixels, signed bytes, origin-centred.
;                It is rotated by (spin - heading) and added to the rock's
;                half-res screen centre: one rotation, not two, because the
;                camera's rotation and the object's spin compose into one angle.
;
;   ship forward in world = (sin H, -cos H)
;   view of a world delta d:   vx =  dx*cos + dy*sin
;                              vy = -dx*sin + dy*cos
;   framebuffer:               fb_x = CX + vy       fb_y = CY - vx
; =============================================================================

.setcpu "65SC02"

        .include "mad65.inc"

        .export cart_init
        .export cart_frame

; --- tunables ----------------------------------------------------------------
STAR_N      = 88                ; stars in the layer; ~46% are on screen at once
MOTE_N      = 10                ; motes: a second layer much CLOSER than the
                                ;   action, so they streak past at twice the
                                ;   ship's speed. ~5 on screen at a time - they
                                ;   are there to sell speed when nothing else is
                                ;   in view, not to be looked at.
NOBJ        = 200               ; asteroids, scattered over the whole torus. The
                                ;   world is about 140 screens, so a bit over one
                                ;   rock per screen by centre - and because they
                                ;   are up to 192 px across, that comes out as 3
                                ;   to 6 actually on camera. It was 250 while
                                ;   these were dots; every one of them costs the
                                ;   position integrate and the coarse reject
                                ;   whether or not it is anywhere near, which is
                                ;   the single largest item in the frame - see
                                ;   the budget note in README.md.
SPR_W2      = 8                 ; the ship is 32x32 full-res -> 16x16 half-res,
SPR_H2      = 8                 ;   so half of that, for the occluder box
SPR_SHIP    = 1                 ; the slot the ship art is installed into. Slot 0
                                ;   is left as the ROM test sprite so that a
                                ;   forgotten id draws something recognisable
SHIP_PAGE   = $10               ; ...and the GPU RAM page its 256 bytes land on
AST_MAX     = 12                ; asteroids transformed and drawn per frame. The
                                ;   world holds NOBJ of them and about two are on
                                ;   camera at a time; this is the ceiling that
                                ;   stops a chance cluster eating the frame.

FBCX        = 200               ; full-res framebuffer centre
FBCY        = 149
HCX         = 100               ; half-res framebuffer centre
HCY         = 74

SHIP_SX     = FBCX - 16         ; ship top-left, so its centre is the screen's
SHIP_SY     = FBCY - 16

; --- cartridge zero page ($80-$FF belongs to the game) -----------------------
FRAME       = $80               ; $80-$81 16-bit frame counter
BGDONE      = $82
HEAD        = $83               ; heading, brad 0-255 (the integer part)
TIER        = $84               ; speed tier, index into TIER_SPD
TURNIX      = $85               ; index into TURN_RATE
TURNR       = $86               ; the selected rate itself, brad per frame
COSV        = $87               ; cos(HEAD), signed Q0.7
SINV        = $88               ; sin(HEAD), signed Q0.7
SGNC        = $89               ; $FF when COSV < 0, else $00
SGNS        = $8A
SHXL        = $8B               ; ship world X, 16.8
SHXH        = $8C
SHXF        = $8D
SHYL        = $8E
SHYH        = $8F
SHYF        = $90
VELXL       = $91               ; ship velocity, signed 8.8 world units/frame
VELXH       = $92
VELYL       = $93
VELYH       = $94
SGVX        = $95               ; sign extensions of VELXH / VELYH
SGVY        = $96
ACCL        = $97               ; running sum while building ROTC / ROTS
ACCH        = $98
CDXI        = $99               ; rebase scratch: the eight table reads, 8.8
CDXF        = $9A
SDXI        = $9B
SDXF        = $9C
FBX         = $9D               ; per-star half-res framebuffer position
FBY         = $9E
DIDX        = $9F               ; write index into DOTBUF
STARN       = $A0               ; stars that survived clip + occlusion
OCCN        = $A1               ; live occluder boxes
SAMPX       = $A2               ; star-layer sample point
SAMPY       = $A3
MAL         = $A4               ; smul: multiplicand, signed 16
MAH         = $A5
MB          = $A6               ; smul: multiplier, signed byte
MR0         = $A7               ; smul: 24-bit magnitude product
MR1         = $A8
MR2         = $A9
MSGN        = $AA               ; smul: 1 = negate the result
PXL         = $AB               ; object offset, full-res pixels
PXH         = $AC
PYL         = $AD
PYH         = $AE
VXL         = $AF               ; object view coords
VXH         = $B0
VYL         = $B1
VYH         = $B2
FXL         = $B3               ; object full-res framebuffer position
FXH         = $B4
FYL         = $B5
FYH         = $B6
T0          = $B7
T1          = $B8
DEC0        = $B9               ; 3-digit decimal / 2-digit hex scratch
DEC1        = $BA
DEC2        = $BB
OBJI        = $BC
SPDL        = $BD               ; this frame's speed, signed 8.8 world units
SPDH        = $BE               ;   per frame. 8.8 so the tiers can be round
                                ;   numbers of pixels per second instead of
                                ;   whatever a whole world unit lands on
PRNGL       = $BF               ; the bench's own LFSR state
PRNGH       = $D2
TRAVL       = $C0               ; distance flown since the last star rebase,
TRAVH       = $C1               ;   signed 8.8, in half-res screen pixels
TRAVI       = $C2               ;   ...its integer part, the frame's scroll offset
BASEHEAD    = $C3               ; the heading the star bases were built for
BASEOFF     = $DA               ; ...and the ship offset they were built for
T2          = $DB               ; the camera point, while a rebase computes it
T3          = $DC
PSHOFFL     = $DD               ; last frame's ship offset, so the ease between
PSHOFFH     = $DE               ;   speed tiers can be fed to the scroll
TURNVL      = $DF               ; angular velocity, signed 8.8 brad per frame
TURNVH      = $E0
RAMPIX      = $E1               ; how sharply it reaches the held turn rate
MSAMPX      = $E2               ; the mote layer's sample point
MSAMPY      = $E3
MOTEN       = $E4               ; motes that survived the clip
MDIDX       = $E5
MFRACX      = $E6               ; the sub-unit part of the mote sample
MFRACY      = $E7
VYT         = $C4               ; per-star scrolled view-y
HEADF       = $C5               ; heading fraction - turning is sub-brad, so the
                                ;   rate table can have steps finer than 1/256 turn
                                ;   per frame without the heading itself getting one
FRACX       = $C6               ; the sub-unit part of the star sample, 0.8
FRACY       = $C7
UXL         = $C8               ; -R * frac, the sub-unit registration of a rebase
UXH         = $C9
UYL         = $CA
UYH         = $CB
TSCALE      = $CC               ; 1 = turn rate rises with flight speed
RATEL       = $CD               ; this frame's effective turn rate, 8.8 brad
RATEH       = $CE
SHOFFL      = $CF               ; how far down the screen the ship is drawn,
SHOFFH      = $D0               ;   signed 8.8 full-res pixels, eased toward
                                ;   the speed tier's target - see do_ship
REFI        = $D1               ; the scroll offset at the last star refresh
RBMODE      = $D3               ; 0 = rebuild every star, 1 = only parked ones
CDYI        = $D4
CDYF        = $D5
SDYI        = $D6
SDYF        = $D7
CF          = $D8               ; carry out of a fractional sum, -1..2
PKX         = $D9               ; nonzero if this star must be parked
; --- the asteroids ($E8-$EF and $F5-$FF; $F0-$F4 belong to the bootstrap, which
;     is dead by the first frame but not worth reusing for eight bytes) --------
MQA         = $E8               ; quarter-square multiply: the two MAGNITUDES in,
MQB         = $E9               ;   0..127 each
MQR         = $EA               ; ...and its scratch, $EA-$EB
SPRSTEP     = $EC               ; which page of the sprite upload is next, 0-5
ACOSV       = $ED               ; |cos| and |sin| of THIS rock's screen angle,
ASINV       = $EE               ;   which is (its spin - the heading)
ARAD        = $EF               ; its bounding radius, half-res pixels
SHPL        = $F5               ; pointer to the shape's vertex list
SHPH        = $F6
AVN         = $F7               ; vertices in that list
AVI         = $F8               ; the vertex loop's own index
CX2L        = $F9               ; the rock's centre in HALF-res framebuffer
CX2H        = $FA               ;   coordinates, signed 16
CY2L        = $FB
CY2H        = $FC
ACLIP       = $FD               ; 0 = wholly on screen, so the cheap path
ADRAWN      = $FE               ; rocks drawn so far this frame
SGMY        = $FF               ; sign of the vertex's y, $FF when negative
; The bootstrap's own scratch, $F0-$F4, is dead the moment the copy finishes and
; cart_init is entered, so the vertex loop - the hottest code in the file - gets
; the last of the zero page rather than paying a cycle a byte for absolute RAM.
SGC         = $F0               ; sign of cos / sin for this rock
SGS         = $F1
AMXM        = $F2               ; |mx| and |my| for the vertex being transformed
AMYM        = $F3
SGMX        = $F4

; --- cartridge RAM ($0400-$77FF is free game RAM) ----------------------------
ROTC_I      = $0400             ; the rotation tables, 8.8: ROT[i] = signed(i) *
ROTC_F      = $0500             ;   coef / 128, integer byte and fraction byte.
ROTS_I      = $0600             ;   Keeping the fraction is what stops a rebase
ROTS_F      = $0700             ;   truncating twice - see star_rebase.
STARBX      = $0800             ; STAR_N bytes: star layer X (the layer IS 0-255)
STARBY      = $0880             ; STAR_N bytes: star layer Y
DOTBUF      = $0900             ; 1 + 2*STAR_N: the DOT_PIXELS payload we build
OCCX0       = $0A00             ; occluders: the clamped BOX, half-res, max 16
OCCX1       = $0A20             ;   - the cheap per-star reject
OCCY0       = $0A40
OCCY1       = $0A60
OCCCX       = $0A80             ; ...and the DISC inside it: centre (low byte
OCCCY       = $0AA0             ;   only - see disc_hit) and the radius squared.
OCCR2L      = $0AC0             ;   r2 = $FFFF makes the entry a plain box, which
OCCR2H      = $0AE0             ;   is what the ship's is
DSQL        = $62D1             ; disc_hit's own 16-bit scratch
DSQH        = $62D2
AOCR        = $62D3             ; this rock's star-suppression radius
OBJXL       = $1000             ; object world positions, 16.8, structure-of-arrays
OBJXH       = $1100
OBJXF       = $1200
OBJYL       = $1300
OBJYH       = $1400
OBJYF       = $1500
OBJVXL      = $1600             ; object velocities, signed 8.8
OBJVXH      = $1700
OBJVYL      = $1800
OBJVYH      = $1900
; The VISIBLE LIST: what came through do_objects' cull this frame, packed.
; This used to be five whole pages indexed by object id — a screen position and
; a flag for all NOBJ, of which a dozen were ever set. Packed, it is 320 bytes
; instead of 1280, and emit_asteroids walks the dozen instead of scanning two
; hundred flags. The reason it matters beyond that is the zoom: pulling the
; camera back multiplies the number of rocks in view, AST_MAX starts to bite,
; and a packed list can be SORTED so the ones that get dropped are the furthest
; away. A sparse flag array can only ever drop by object id, which is random.
VIS_MAX     = 64                ; entries; anything past this is simply not drawn
VISIDX      = $1A00             ; which object each entry is
VSXL        = $1A40             ; ...and its full-res screen centre, signed 16
VSXH        = $1A80
VSYL        = $1AC0
VSYH        = $1B00
BASEX       = $0B00             ; STAR_N bytes: each star's VIEW-space position at
BASEY       = $0B80             ;   the last rebase - see do_stars
PARKED      = $0D00             ; STAR_N bytes: 1 = out of byte range, do not draw
MOTEBX      = $0D80             ; MOTE_N bytes: the mote layer
MOTEBY      = $0D90
MOTEBUF     = $0DA0             ; 1 + 2*MOTE_N: the motes' DOT_PIXELS payload
MOTESX      = $0DC0             ; per-mote screen position, kept by index so the
MOTESY      = $0DD0             ;   harness can measure a single mote's motion
MOTEVIS     = $0DE0
STR_SPD     = $0C00             ; HUD strings, patched in place every frame
STR_TRN     = $0C20
STR_HDG     = $0C40
STR_STA     = $0C60
STR_SCL     = $0C80
QSL         = $0E00             ; the quarter-square multiply table, f(x) = x*x/4
QSH         = $0F00             ;   for x = 0..255, low byte and high byte
QRL         = $6400             ; ...and the same table plus 64. Subtracting the
QRH         = $6500             ;   plain one from THIS one is the rounding: the
                                ;   +64 that a >>7 needs, for no cycles at all
OBJSHP      = $1F00             ; NOBJ bytes: which of the five sizes each rock is
OBJANG      = $6000             ; NOBJ bytes: its spin angle, brad (integer part)
OBJANGF     = $6100             ; ...and the fraction, so a spin can be far slower
                                ;   than one brad a frame
AVXL        = $6200             ; the transformed outline, signed 16 half-res, one
AVXH        = $6220             ;   entry per vertex
AVYL        = $6240
AVYH        = $6260
AOC         = $62A0             ; ...and its Cohen-Sutherland outcode, built only
                                ;   when the rock straddles an edge
DLBUF       = $6280             ; the DOT_LINES payload: 1 + 2*(AVN+1) bytes
DEFPG       = $6300             ; one page of the GPU sprite definition table,
                                ;   staged here and shipped with LOAD
APX         = $62C2             ; the vertex being transformed, rotated
APY         = $62C3
ATMP        = $62C4
ASHY        = $62C5             ; the shape cursor, parked over the multiplies
AFAR        = $62CD             ; the far end of the segment being emitted
ROTHEAD     = $62CE             ; the heading the ROT tables were built for
VISN        = $62CF             ; entries in the visible list this frame
VISI        = $62D0             ; ...and the draw loop's cursor into it
SPL         = $62C6             ; span_test's own scratch
SPH         = $62C7
SPLIM       = $62C8
SPLOL       = $62C9
SPLOH       = $62CA
SPHIL       = $62CB
SPHIH       = $62CC

; -----------------------------------------------------------------------------
; BUILD_ROT — fill a 256-byte table with signed(i) * coef / 128.
; -----------------------------------------------------------------------------
; The positive half is a running 16-bit sum: add the coefficient, store the top
; nine bits. That is exact — no rounding drift accumulates over 128 entries —
; and the negative half is just the mirror. This is what buys the star loop its
; multiply-free inner body: four table lookups and two adds per star.
; -----------------------------------------------------------------------------
.macro  BUILD_ROT tblI, tblF, coef, sgn
        .local  pos, neg
        stz     ACCL
        stz     ACCH
        ldx     #$00
pos:    lda     ACCL                    ; the entry is acc/128, i.e. acc<<1 read
        asl     a                       ;   as 8.8 - so the fraction is free, it
        sta     tblF,x                  ;   is the byte we used to throw away
        lda     ACCH
        rol     a
        sta     tblI,x
        clc
        lda     ACCL
        adc     coef
        sta     ACCL
        lda     ACCH
        adc     sgn
        sta     ACCH
        inx
        cpx     #128
        bne     pos
        stz     tblF+128                ; index 128 IS -128, so this entry is
        sec                             ;   exactly -coef, with no fraction
        lda     #$00
        sbc     coef
        sta     tblI+128
        ldx     #127                    ; mirror: tbl[256-k] = -tbl[k], negated
        ldy     #129                    ;   as the 16-bit value it now is
neg:    sec
        lda     #$00
        sbc     tblF,x
        sta     tblF,y
        lda     #$00
        sbc     tblI,x
        sta     tblI,y
        iny
        dex
        bne     neg
.endmacro

; -----------------------------------------------------------------------------
; RPROD — one product of the view transform, straight out of the ROT tables.
; -----------------------------------------------------------------------------
;     (srcL, srcH) signed 16 world units  x  coef/128  ->  T0/T1, signed 16
;
; The tables the starfield already builds are `ROT[i] = signed(i)*coef/128`, in
; 8.8 and EXACT. They are linear, so they work on a 16-bit operand too:
;
;     delta = hi*256 + lo    ->    delta*coef/128 = 256*ROT[hi] + ROT[lo]
;
; and `256 * ROT[hi]` needs no shifting at all — multiplying an 8.8 by 256 moves
; the fraction byte into the integer, so the two table bytes ARE the 16-bit
; value, fraction byte low. The only care needed is that the table reads its
; index as SIGNED while `lo` is the unsigned low byte of the delta: for lo >= 128
; the table returns (lo-256)*coef/128, so the missing 256 is borrowed from the
; high index instead. `hi+1` cannot overflow because this only ever runs on a
; delta that has already passed in_range.
;
; ~65 cycles against smul_core's ~300, and more accurate: nothing is truncated
; on the way through, and the low entry's fraction byte rounds the result.
; Clobbers A, X, Y.
; -----------------------------------------------------------------------------
.macro  RPROD tblI, tblF, srcL, srcH
        .local  nohi, pos, norm, done
        ldx     srcL
        ldy     srcH
        cpx     #$80                    ; lo >= 128: the table will read it as
        bcc     nohi                    ;   negative, so borrow the 256 back
        iny
nohi:   lda     tblF,y                  ; 256 * ROT[hi], as one 16-bit value
        sta     T0
        lda     tblI,y
        sta     T1
        lda     tblI,x                  ; + ROT[lo], sign-extended
        bpl     pos
        dec     T1
pos:    clc
        adc     T0
        sta     T0
        bcc     norm
        inc     T1
norm:   lda     tblF,x                  ; ...and rounded by its own fraction
        cmp     #$80
        bcc     done
        inc     T0
        bne     done
        inc     T1
done:
.endmacro

        .segment "CODE"

; =============================================================================
; cart_init — called ONCE by the boot ROM, before interrupts are enabled.
; =============================================================================
; No GPU calls here: init runs outside the gpu_begin/gpu_end pair, so anything
; drawn would land in no frame at all.
; =============================================================================
cart_init:
        stz     FRAME
        stz     FRAME+1
        stz     BGDONE
        stz     HEAD
        lda     #TIER_ZERO              ; standing still
        sta     TIER
        stz     SHOFFL
        stz     SHOFFH
        lda     #5                      ; 2.00 brad/frame, ~2.1 s per revolution
        sta     TURNIX
        stz     TURNVL
        stz     TURNVH
        lda     #2                      ; a middling wind-up by default
        sta     RAMPIX
        stz     PSHOFFL
        stz     PSHOFFH
        stz     HEADF
        stz     TSCALE
        stz     SPRSTEP

        stz     SHXL                    ; the middle of the torus, which means
        stz     SHYL                    ;   nothing on a torus but keeps a
        stz     SHXF                    ;   debugger session readable
        stz     SHYF
        lda     #$80
        sta     SHXH
        sta     SHYH

        stz     TRAVL
        stz     TRAVH
        lda     #$80                    ; != HEAD (0), so frame 1 builds the
        sta     BASEHEAD                ;   tables and rebases the star bases
        sta     ROTHEAD

        lda     #$A5                    ; any nonzero seed; see prng
        sta     PRNGL
        lda     #$3C
        sta     PRNGH

        jsr     init_qs
        jsr     init_stars
        jsr     init_motes
        jsr     init_objects
        jmp     init_strings

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
; init_stars — scatter the layer with the OS RNG.
; -----------------------------------------------------------------------------
; The layer is 256 x 256 and a byte coordinate covers it exactly, so "scatter"
; really is two random bytes per star, and the layer's wrap is free.
;
; This uses the cartridge's own LFSR, not the OS `rng`, for two reasons: the OS
; seed is set up by CPU1 boot, which a py65 harness does not run (an unseeded
; LFSR is all zeroes and every star lands on the same spot), and a bench that
; measures things should scatter the same way every time it is run.
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

; -----------------------------------------------------------------------------
; init_objects — scatter the asteroid field.
; -----------------------------------------------------------------------------
; Scattered over the WHOLE torus, not around the ship: a 16-bit world position
; is uniform by construction, so two random bytes per axis is the whole job. The
; SIZE is drawn the same way, through SHAPE_PICK, which is where the size mix is
; tuned.
;
; Velocity and spin are NOT random. Each is read out of a hand-written table:
; one of four drift vectors per size class (index & 3) and one spin rate per
; size class, so the field is completely reproducible and every number in it can
; be argued with by editing AST_VEL / AST_SPIN rather than by reseeding. Big
; rocks drift slowly and turn slowly; the small ones are quick and busy, which
; is the Asteroids convention and the thing worth checking on screen.
init_objects:
        ldy     #$00
@lp:    jsr     prng
        sta     OBJXL,y
        jsr     prng
        sta     OBJXH,y
        lda     #$00                    ; (stz has no abs,y mode)
        sta     OBJXF,y
        jsr     prng
        sta     OBJYL,y
        jsr     prng
        sta     OBJYH,y
        lda     #$00
        sta     OBJYF,y

        jsr     prng                    ; the size class
        and     #$07
        tax
        lda     SHAPE_PICK,x
        sta     OBJSHP,y

        asl     a                       ; velocity: AST_VEL[class][index & 3],
        asl     a                       ;   four bytes per variant, four variants
        asl     a                       ;   per class -> class * 16
        asl     a
        sta     T0
        tya
        and     #$03
        asl     a
        asl     a
        clc
        adc     T0
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
        lda     #$00
        sta     OBJANGF,y

        iny
        cpy     #NOBJ
        bne     @lp
        rts

; -----------------------------------------------------------------------------
; init_strings — copy the HUD templates ROM -> RAM so digits can be patched.
; -----------------------------------------------------------------------------
init_strings:
        ldx     #$00
@lp:    lda     TPL_SPD,x
        sta     STR_SPD,x
        lda     TPL_TRN,x
        sta     STR_TRN,x
        lda     TPL_HDG,x
        sta     STR_HDG,x
        lda     TPL_STA,x
        sta     STR_STA,x
        lda     TPL_SCL,x
        sta     STR_SCL,x
        inx
        cpx     #24
        bne     @lp
        rts

; =============================================================================
; cart_frame — called once per frame, between gpu_begin and gpu_end.
; =============================================================================
cart_frame:
        inc     FRAME
        bne     :+
        inc     FRAME+1
:
        lda     SPRSTEP                 ; the sprite upload, one LOAD page per
        cmp     #$05                    ;   frame, and FIRST in the frame it
        bcs     :+                      ;   happens on - see upload_step
        jsr     upload_step
:
        lda     BGDONE                  ; one-shot: wipe the boot screen off the
        bne     :+                      ;   background. The OS replays background
        jsr     API_GPU_CLEARBG         ;   commands on the next frame for us, so
        lda     #$01                    ;   issuing this once is the whole job.
        sta     BGDONE
:
        jsr     do_input
        jsr     do_camera               ; cos/sin, then the two rotation tables
        jsr     do_ship                 ; velocity from tier + heading, integrate
        jsr     do_objects              ; move and spin the rocks, transform them
        jsr     emit_asteroids          ; ...which also registers their occluder
        jsr     do_stars                ;   discs, which do_stars needs: it is the
        jsr     do_motes                ;   one pass that has to run after them
        jsr     emit_ship
        jsr     do_hud
        ; The two decorative layers are appended LAST, and in this order: if the
        ; GPU ever runs out of frame to finish the list, what it drops should be
        ; the backdrop, not the ship or the HUD. Stars second to last, motes
        ; last, because motes are the cheapest thing on screen to lose.
        jsr     emit_stars
        jmp     emit_motes

; -----------------------------------------------------------------------------
; upload_step — install the ship sprite, ONE LOAD page per frame for five frames.
; -----------------------------------------------------------------------------
; LOAD is the only way CPU1 can write GPU RAM, and it writes a whole 256-byte
; page at a time — including the sprite definition table, which is four pages of
; one parameter each ($03 type, $04 ptr lo, $05 ptr hi, $06 height). So each of
; the four is staged blank in DEFPG, patched with the two slots this cartridge
; uses, and shipped. Slot 0 keeps the ROM test sprite's own numbers, which costs
; nothing and means an id typo still draws something.
;
; ONE PAGE A FRAME because five is too many at once: a LOAD is 258 bytes of the
; 2047-byte list and about 10,000 cycles of copying, and all five on the first
; frame put that frame at 98% of budget for no reason. Spread out it is 5% a
; frame, and the ship appears on frame 5 — 83 ms, which nobody sees. It still
; goes FIRST in whichever frame it lands on: a def page dropped for want of
; PPRAM would leave the slot empty for the rest of the session.
; -----------------------------------------------------------------------------
upload_step:
        ldx     SPRSTEP
        inc     SPRSTEP
        txa                             ; the OLD step, not the incremented one
        bne     @def
        lda     #SHIP_PAGE              ; step 0: the art itself
        sta     OS_ARG+0
        lda     #<ship32_data
        sta     OS_ARG+1
        lda     #>ship32_data
        sta     OS_ARG+2
        jmp     API_GPU_LOAD
@def:   dex                             ; steps 1-4: definition page X-1
        lda     #$00                    ; a blank page...
        ldy     #$00
:       sta     DEFPG,y
        iny
        bne     :-
        txa                             ; ...with the two live slots patched in
        asl     a
        tay
        lda     SPRDEF,y
        sta     DEFPG+0
        lda     SPRDEF+1,y
        sta     DEFPG+SPR_SHIP
        txa
        clc
        adc     #$03                    ; GPU pages $03 / $04 / $05 / $06
        sta     OS_ARG+0
        lda     #<DEFPG
        sta     OS_ARG+1
        lda     #>DEFPG
        sta     OS_ARG+2
        jmp     API_GPU_LOAD

; -----------------------------------------------------------------------------
; do_input — joystick 1.
; -----------------------------------------------------------------------------
; Turning is on the HELD bits; the speed tier and the turn rate are on the EDGE
; bits, because a held direction would rip through ten tiers in a sixth of a
; second and nothing could be judged.
; -----------------------------------------------------------------------------
do_input:
        ldx     TURNIX                  ; this frame's rate, 8.8 brad per frame
        txa
        asl     a
        tax
        lda     TURN_RATE,x
        sta     RATEL
        lda     TURN_RATE+1,x
        sta     RATEH
        lda     TSCALE                  ; ...optionally scaled by flight speed:
        beq     @rate_ok                ;   rate * (1 + xtra/128). Turn radius is
        ldy     TIER                    ;   v/omega, so a constant omega lets the
        lda     TURN_XTRA,y             ;   radius grow in proportion to speed;
        beq     @rate_ok                ;   this pulls that back. The first cut
        sta     T0                      ;   doubled the rate at top speed and rose
        ldx     TSCALE                  ;   far too fast, so the dial now goes
        cpx     #3                      ;   OFF / x1.12 / x1.25 / x1.50 at the top
        beq     @xok                    ;   tier - three shifts of one table.
        lsr     T0
        cpx     #2
        beq     @xok
        lsr     T0
@xok:   lda     T0
        beq     @rate_ok
        sta     MB
        lda     RATEL
        sta     MAL
        lda     RATEH
        sta     MAH
        jsr     smul16q7
        clc
        lda     RATEL
        adc     MAL
        sta     RATEL
        lda     RATEH
        adc     MAH
        sta     RATEH
@rate_ok:
        ; ---- the turn has momentum ------------------------------------------
        ; The stick sets a TARGET angular velocity and the real one eases toward
        ; it, so a turn winds up and unwinds instead of switching on and off.
        ; RAMP 0 is an instant ease, i.e. the old on/off behaviour, kept so the
        ; two can be compared back to back.
        stz     T0                      ; T0/T1 = the target
        stz     T1
        lda     JOY1
        and     #JOY_LEFT
        beq     :+
        sec
        lda     #$00
        sbc     RATEL
        sta     T0
        lda     #$00
        sbc     RATEH
        sta     T1
:       lda     JOY1
        and     #JOY_RIGHT
        beq     :+
        lda     RATEL
        sta     T0
        lda     RATEH
        sta     T1
:       ldx     RAMPIX
        beq     @snap
        sec                             ; delta = target - current, into MA so the
        lda     T0                      ;   target stays in T0/T1
        sbc     TURNVL
        sta     MAL
        lda     T1
        sbc     TURNVH
        sta     MAH
        ldy     RAMPIX                  ; (ldx has no abs,x mode)
        lda     RAMP_SHIFT,y
        tax
@rsh:   lda     MAH
        cmp     #$80
        ror     MAH
        ror     MAL
        dex
        bne     @rsh
        lda     MAL                     ; An exponential ease never lands on its
        ora     MAH                     ;   target in integers: shifting a small
        bne     @rapply                 ;   delta right gives 0 one way and -1 the
@snap:  lda     T0                      ;   other, so the angular velocity sticks
        sta     TURNVL                  ;   at some tiny nonzero value and the
        lda     T1                      ;   heading creeps FOREVER - which fires a
        sta     TURNVH                  ;   full star rebuild every few dozen
        bra     @spin                   ;   frames and twitches the whole field.
@rapply:                                ;   When the step underflows, snap.
        clc
        lda     TURNVL
        adc     MAL
        sta     TURNVL
        lda     TURNVH
        adc     MAH
        sta     TURNVH
@spin:
        clc                             ; the heading carries a FRACTION, so the
        lda     HEADF                   ;   rate ladder can step finer than one
        adc     TURNVL                  ;   brad per frame. Only the integer part
        sta     HEADF                   ;   is used for cos/sin, and only a change
        lda     HEAD                    ;   in THAT rebuilds the starfield, so a
        adc     TURNVH                  ;   slow turn also rebuilds less often.
        sta     HEAD

        lda     JOY1_PRESS
        and     #JOY_UP
        beq     :+
        lda     TIER
        cmp     #TIER_N-1
        bcs     :+
        inc     TIER
:       lda     JOY1_PRESS
        and     #JOY_DOWN
        beq     :+
        lda     TIER
        beq     :+
        dec     TIER
:       lda     JOY1_PRESS
        and     #JOY_FIRE
        beq     :+
        lda     TURNIX
        inc     a
        cmp     #TURN_N
        bcc     @tok
        lda     #$00
@tok:   sta     TURNIX
:       lda     JOY2_PRESS              ; joystick 2 left/right: how sharply the
        and     #JOY_RIGHT              ;   turn winds up
        beq     :+
        lda     RAMPIX
        inc     a
        cmp     #RAMP_N
        bcc     @rok
        lda     #$00
@rok:   sta     RAMPIX
:       lda     JOY2_PRESS
        and     #JOY_LEFT
        beq     :+
        lda     RAMPIX
        bne     @rdn
        lda     #RAMP_N
@rdn:   dec     a
        sta     RAMPIX
:       lda     JOY2_PRESS              ; joystick 2's button steps the speed
        and     #JOY_FIRE               ;   coupling, so the settings can be
        beq     :+                      ;   compared back to back, no rebuild
        lda     TSCALE
        inc     a
        and     #$03
        sta     TSCALE
:       rts

; -----------------------------------------------------------------------------
; do_camera — cos/sin of the heading, then the two rotation tables.
; -----------------------------------------------------------------------------
do_camera:
        lda     HEAD
        jsr     API_COS
        sta     COSV
        ldx     #$00
        bit     COSV
        bpl     :+
        ldx     #$FF
:       stx     SGNC

        lda     HEAD
        jsr     API_SIN
        sta     SINV
        ldx     #$00
        bit     SINV
        bpl     :+
        ldx     #$FF
:       stx     SGNS

        ; The rotation tables are built HERE, and only on a frame where the
        ; heading actually moved — they are ~15k cycles and nothing else can
        ; change them. They used to be built inside star_rebase, which runs
        ; after do_objects: on a turning frame the objects would then transform
        ; against last frame's heading and lag the camera by a frame. Three
        ; things read them now — the starfield, the object centres, and (soon)
        ; the radar — so they belong to the camera, not to the stars.
        lda     HEAD
        cmp     ROTHEAD
        bne     :+                      ; (branching the other way is out of
        rts                             ;  range - two BUILD_ROTs is 147 bytes)
:       sta     ROTHEAD
        BUILD_ROT ROTC_I, ROTC_F, COSV, SGNC
        BUILD_ROT ROTS_I, ROTS_F, SINV, SGNS
        rts

; -----------------------------------------------------------------------------
; do_ship — velocity from the speed tier and the heading, then integrate.
; -----------------------------------------------------------------------------
; forward = (sin H, -cos H), so vel = speed * that. Velocity is signed 8.8 world
; units per frame and the position carries a fraction byte; that is what makes
; the slowest tier a smooth drift rather than a stutter — the finest motion this
; can express is 1/4096 of a pixel per frame.
; -----------------------------------------------------------------------------
do_ship:
        lda     TIER
        asl     a
        tax
        lda     TIER_SPD,x
        sta     SPDL
        lda     TIER_SPD+1,x
        sta     SPDH

        lda     SPDL                    ; VELX = speed * sin. Speed is already
        sta     MAL                     ;   8.8, so the Q0.7 multiply lands in
        lda     SPDH                    ;   8.8 too and the old byte-wide
        sta     MAH                     ;   smul_vel is gone.
        lda     SINV
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     VELXL
        lda     MAH
        sta     VELXH

        lda     SPDL                    ; VELY = -(speed * cos)
        sta     MAL
        lda     SPDH
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        sec
        lda     #$00
        sbc     MAL
        sta     VELYL
        lda     #$00
        sbc     MAH
        sta     VELYH

        ; The ship slides down the screen as it speeds up, and above centre in
        ; reverse, so the player is always looking at where they are going. It
        ; EASES toward the tier's target instead of snapping: a jump on every
        ; tier change would be unreadable, and this shift is the camera-lag
        ; constant the design still has to settle (open question B3).
        ldx     TIER
        stz     T0
        lda     SHIP_OFF,x
        sta     T1
        sec
        lda     T0
        sbc     SHOFFL
        sta     T0
        lda     T1
        sbc     SHOFFH
        sta     T1
        ldx     #SHOFF_LAG
:       lda     T1
        cmp     #$80
        ror     T1
        ror     T0
        dex
        bne     :-
        clc
        lda     SHOFFL
        adc     T0
        sta     SHOFFL
        lda     SHOFFH
        adc     T1
        sta     SHOFFH

        ldx     #$00                    ; sign extensions for the 24-bit add
        bit     VELXH
        bpl     :+
        ldx     #$FF
:       stx     SGVX
        ldx     #$00
        bit     VELYH
        bpl     :+
        ldx     #$FF
:       stx     SGVY

        clc                             ; position += velocity, 16.8 + 8.8
        lda     SHXF
        adc     VELXL
        sta     SHXF
        lda     SHXL
        adc     VELXH
        sta     SHXL
        lda     SHXH
        adc     SGVX
        sta     SHXH
        clc
        lda     SHYF
        adc     VELYL
        sta     SHYF
        lda     SHYL
        adc     VELYH
        sta     SHYL
        lda     SHYH
        adc     SGVY
        sta     SHYH
        rts

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
        stz     OCCN
        stz     VISN
        jsr     add_ship_occluder
        stz     OBJI
@lp:
        ldx     OBJI
        ; The coarse reject comes FIRST, before the rock has even moved. Any
        ; object whose high byte is more than CULL_HI from the ship's cannot
        ; survive the precise cull below, and an object that is not drawn does
        ; not need to have moved: on a torus with no off-camera collisions,
        ; nothing in the machine can observe where a distant rock has drifted
        ; to. So a far rock costs this test and nothing else - about 40 cycles
        ; instead of 160 - and starts moving again the moment you fly near it.
        ;
        ; Reading the position one frame stale is what makes this safe to do in
        ; this order: a rock moves at most ~13 world units a frame and the gap
        ; between this window (CULL_HI * 256) and the precise cull (CULL_R) is
        ; 128 units, so nothing can cross both tests inside one frame.
        lda     OBJXH,x
        sec
        sbc     SHXH
        clc
        adc     #CULL_HI
        cmp     #CULL_HI * 2 + 1
        bcc     :+
        jmp     @cull
:       lda     OBJYH,x
        sec
        sbc     SHYH
        clc
        adc     #CULL_HI
        cmp     #CULL_HI * 2 + 1
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

        lda     VYL                     ; fb_x = FBCX + round(vy / 16)
        sta     MAL
        lda     VYH
        sta     MAH
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
        lda     VXL                     ; fb_y = FBCY - round(vx / 16)
        sta     MAL
        lda     VXH
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
        inc     OBJI
        lda     OBJI
        cmp     #NOBJ
        beq     :+
        jmp     @lp
:       rts

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
; which is precisely the size this bench exists to look at.
; -----------------------------------------------------------------------------
CULL_R      = 7808              ; 488 full-res px, in world units (16 per px)
CULL_HI     = 31                ; ...and CULL_R / 256, rounded up, for the cheap
                                ;   high-byte reject above

in_range:
        clc
        adc     #<CULL_R
        sta     T0
        tya
        adc     #>CULL_R
        tay
        bmi     @out
        cpy     #>(CULL_R * 2 + 1)
        bcc     @in
        bne     @out
        lda     T0
        cmp     #<(CULL_R * 2 + 1)
        bcc     @in
@out:   sec
        rts
@in:    clc
        rts

; -----------------------------------------------------------------------------
; view_xform — rotate a WORLD-unit offset (PX, PY) into view coords.
; -----------------------------------------------------------------------------
;   vx =  px*cos + py*sin        vy = -px*sin + py*cos
;
; Four products, and they used to be four smul_core multiplies at ~300 cycles
; each because a world delta is 16-bit and neither the quarter-square table
; (8-bit operands) nor the ROT tables (a byte index) appeared to fit it. The ROT
; tables DO fit it — see RPROD — so this is now four table pairs and some adds,
; at the full 1/16-pixel resolution of a world coordinate. The caller rounds to
; a whole pixel afterwards, never before: rounding first is what used to make
; objects swim, and RPROD's own rounding is monotone so it cannot bring that
; back.
;
; The stars have always taken this shortcut. The only reason the objects did not
; was that nobody had noticed a 16-bit operand splits into two byte lookups.
; -----------------------------------------------------------------------------
view_xform:
        RPROD   ROTC_I, ROTC_F, PXL, PXH        ; vx = px*cos ...
        lda     T0
        sta     VXL
        lda     T1
        sta     VXH
        RPROD   ROTS_I, ROTS_F, PYL, PYH        ;      ... + py*sin
        clc
        lda     VXL
        adc     T0
        sta     VXL
        lda     VXH
        adc     T1
        sta     VXH

        RPROD   ROTC_I, ROTC_F, PYL, PYH        ; vy = py*cos ...
        lda     T0
        sta     VYL
        lda     T1
        sta     VYH
        RPROD   ROTS_I, ROTS_F, PXL, PXH        ;      ... - px*sin
        sec
        lda     VYL
        sbc     T0
        sta     VYL
        lda     VYH
        sbc     T1
        sta     VYH
        rts

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
        lda     SHOFFH                  ; the box rides down with the ship
        cmp     #$80
        ror     a                       ; offset / 2, arithmetic: half-res
        clc
        adc     #HCX
        sta     T0
        ldy     OCCN
        lda     T0
        sec
        sbc     #SPR_W2
        sta     OCCX0,y
        lda     T0
        clc
        adc     #SPR_W2
        sta     OCCX1,y
        lda     #HCY - SPR_H2
        sta     OCCY0,y
        lda     #HCY + SPR_H2
        sta     OCCY1,y
        lda     T0                      ; the ship is opaque to its box corners,
        sta     OCCCX,y                 ;   so r2 = $FFFF: every star that gets
        lda     #HCY                    ;   inside the box is inside the "disc"
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

        ldy     #$00                    ; fb_y = HCY - view_x
        lda     #HCY
        sec
        sbc     BASEX,x
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

        ldy     OCCN                    ; drop the star if any box covers it
        beq     @emit
@occ:   dey
        lda     FBX
        cmp     OCCX0,y
        bcc     @occn
        lda     OCCX1,y
        cmp     FBX
        bcc     @occn
        lda     FBY
        cmp     OCCY0,y
        bcc     @occn
        lda     OCCY1,y
        cmp     FBY
        bcc     @occn
        jsr     disc_hit                ; inside the box - inside the disc?
        bcs     @next
@occn:  cpy     #$00
        bne     @occ

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
; do_motes — the near layer: 16 specks at TWICE the ship's speed.
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
; 1/4: sample = camera >> 4. The camera offset is pre-multiplied by 8 rather than
; 64 for the same reason it is pre-multiplied at all - to come out as the ship's
; screen offset in layer units after the shift.
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

        ; fb_y = HCY - (ROTC[dx] + ROTS[dy] + UX)
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
        lda     #HCY
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

; -----------------------------------------------------------------------------
; emit_objects / emit_ship — one SPRITE command each.
; -----------------------------------------------------------------------------
; Coordinates go out unclamped on purpose: the GPU's blitter clips all four
; edges itself and rejects a fully off-screen sprite, so an object hanging over
; an edge is the hardware's problem, not ours.
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; emit_asteroids - draw the outline of every rock that is actually on camera.
; -----------------------------------------------------------------------------
; do_objects has already put a full-res screen centre in OBJSX/OBJSY for every
; rock inside the coarse cull, which is a band 400 px wide around the ship - far
; more than the screen. This is the precise pass: it halves the centre into the
; line ops' half-res space, tests the rock's bounding square against the field,
; and only then pays for the rotation.
;
; Two draw paths, and the difference matters:
;   * wholly on screen -> ONE DOT_LINES chain. Byte coordinates, one dispatch,
;     interior vertices shared. This is the cheap case and the common one.
;   * crossing an edge -> one gpu_dotline_clip per segment. That builder carries
;     true signed-16 coordinates and runs Cohen-Sutherland against the field, so
;     the EDGE is trimmed rather than the coordinate clamped. DOT_LINES cannot be
;     used here at any price: its coordinates are bytes, and clamping a vertex
;     bends every edge that touches it - a 192-px rock half off the top would
;     come apart into a fan.
; -----------------------------------------------------------------------------
emit_asteroids:
        stz     ADRAWN
        stz     VISI
@lp:    lda     VISI
        cmp     VISN
        beq     @done
        lda     ADRAWN
        cmp     #AST_MAX
        bcs     @done
        jsr     one_asteroid
        inc     VISI
        bra     @lp
@done:  rts

one_asteroid:
        ldy     VISI                    ; the list entry names its object
        lda     VISIDX,y
        sta     OBJI
        tax
        ldy     OBJSHP,x
        lda     SHAPE_R,y
        sta     ARAD
        lda     SHAPE_OCC,y
        sta     AOCR
        lda     SHAPE_N,y
        sta     AVN
        lda     SHAPE_LO,y
        sta     SHPL
        lda     SHAPE_HI,y
        sta     SHPH

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

        lda     CX2L                    ; the precise cull, one axis at a time
        ldy     CX2H
        ldx     #199
        jsr     span_test
        cmp     #$02
        bne     :+
        rts                             ; wholly off this axis: nothing to draw
:       sta     ACLIP
        lda     CY2L
        ldy     CY2H
        ldx     #149
        jsr     span_test
        cmp     #$02
        bne     :+
        rts
:       ora     ACLIP
        sta     ACLIP

        jsr     add_disc                ; the stars go out under this rock

        ldx     OBJI                    ; ONE angle: the spin and the camera's
        sec                             ;   rotation compose, so a spinning rock
        lda     OBJANG,x                ;   still costs one pair of trig calls
        sbc     HEAD                    ;   and not two transforms
        pha
        jsr     API_COS                 ; ...split into magnitude and sign HERE,
        ldx     #$00                    ;   once per rock, because qmul wants
        cmp     #$00                    ;   magnitudes and the sign of a product
        bpl     :+                      ;   is just "do the two operands agree"
        eor     #$FF
        inc     a
        ldx     #$FF
:       sta     ACOSV
        stx     SGC
        pla
        jsr     API_SIN
        ldx     #$00
        cmp     #$00
        bpl     :+
        eor     #$FF
        inc     a
        ldx     #$FF
:       sta     ASINV
        stx     SGS

        stz     AVI
        ldy     #$00                    ; Y walks the shape, 2 bytes a vertex
@vlp:   lda     (SHPL),y                ; mx, split the same way - once per
        ldx     #$00                    ;   vertex, not once per multiply
        cmp     #$00
        bpl     :+
        eor     #$FF
        inc     a
        ldx     #$FF
:       sta     AMXM
        stx     SGMX
        iny
        lda     (SHPL),y                ; my
        ldx     #$00
        cmp     #$00
        bpl     :+
        eor     #$FF
        inc     a
        ldx     #$FF
:       sta     AMYM
        stx     SGMY
        iny
        sty     ASHY

        lda     AMXM                    ; px = mx*cos - my*sin
        sta     MQA
        lda     ACOSV
        sta     MQB
        jsr     qmul
        ldy     SGMX                    ; negative exactly when the two operands
        cpy     SGC                     ;   disagreed about their sign
        beq     :+
        eor     #$FF
        inc     a
:       sta     APX
        lda     AMYM
        sta     MQA
        lda     ASINV
        sta     MQB
        jsr     qmul
        ldy     SGMY
        cpy     SGS
        beq     :+
        eor     #$FF
        inc     a
:       sta     ATMP
        sec
        lda     APX
        sbc     ATMP
        sta     APX

        lda     AMXM                    ; py = mx*sin + my*cos
        sta     MQA
        lda     ASINV
        sta     MQB
        jsr     qmul
        ldy     SGMX
        cpy     SGS
        beq     :+
        eor     #$FF
        inc     a
:       sta     APY
        lda     AMYM
        sta     MQA
        lda     ACOSV
        sta     MQB
        jsr     qmul
        ldy     SGMY
        cpy     SGC
        beq     :+
        eor     #$FF
        inc     a
:       clc
        adc     APY
        sta     APY

        ldx     AVI                     ; screen = centre + the rotated offset,
        ldy     #$00                    ;   sign-extended into 16 bits
        bit     APX
        bpl     :+
        ldy     #$FF
:       clc
        lda     CX2L
        adc     APX
        sta     AVXL,x
        tya
        adc     CX2H
        sta     AVXH,x
        ldy     #$00
        bit     APY
        bpl     :+
        ldy     #$FF
:       clc
        lda     CY2L
        adc     APY
        sta     AVYL,x
        tya
        adc     CY2H
        sta     AVYH,x

        inc     AVI
        ldy     ASHY
        lda     AVI
        cmp     AVN
        beq     :+
        jmp     @vlp                    ; (out of branch range - 12 vertices of
:                                       ;  transform is a long loop body)

        inc     ADRAWN
        lda     ACLIP
        bne     @clipped

        lda     AVN                     ; the cheap path: one closed chain, so
        sta     DLBUF                   ;   AVN segments over AVN+1 points
        ldx     #$00
        ldy     #$01
@bl:    lda     AVXL,x
        sta     DLBUF,y
        iny
        lda     AVYL,x
        sta     DLBUF,y
        iny
        inx
        cpx     AVN
        bne     @bl
        lda     AVXL                    ; ...closing back onto vertex 0
        sta     DLBUF,y
        iny
        lda     AVYL
        sta     DLBUF,y
        lda     #<DLBUF
        sta     OS_ARG+0
        lda     #>DLBUF
        sta     OS_ARG+1
        jmp     API_GPU_DOTLINES

; The rock straddles an edge, so every segment has to be classified. This is
; worth the trouble: gpu_dotline_clip measures at ~3,000 cycles a call - it is a
; full Cohen-Sutherland with a divide per crossing - and on a rock that is only
; half off screen most segments never touch an edge at all. So build an outcode
; per vertex first (which edges it is outside of), and then per segment:
;   both codes zero        -> plain gpu_dotline, byte coordinates, ~200 cycles
;   codes share a bit      -> both ends beyond the SAME edge, so the whole
;                             segment is: emit nothing, and pay nothing
;   anything else          -> the real clip, which is now a handful of segments
;                             a frame instead of every segment of every rock
@clipped:
        ldx     #$00
@oc:    stz     ATMP
        lda     AVXH,x
        bmi     @oxlo
        beq     @oxin
@oxhi:  lda     #$02                    ; x > 199
        sta     ATMP
        bra     @ocy
@oxlo:  lda     #$01                    ; x < 0
        sta     ATMP
        bra     @ocy
@oxin:  lda     AVXL,x
        cmp     #200
        bcs     @oxhi
@ocy:   lda     AVYH,x
        bmi     @oylo
        beq     @oyin
@oyhi:  lda     ATMP                    ; y > 149
        ora     #$08
        sta     ATMP
        bra     @ocst
@oylo:  lda     ATMP                    ; y < 0
        ora     #$04
        sta     ATMP
        bra     @ocst
@oyin:  lda     AVYL,x
        cmp     #150
        bcs     @oyhi
@ocst:  lda     ATMP
        sta     AOC,x
        inx
        cpx     AVN
        bne     @oc

        stz     AVI
@cl:    ldx     AVI
        lda     AOC,x
        sta     ATMP
        inx                             ; ...and the far end, wrapping round
        cpx     AVN
        bne     :+
        ldx     #$00
:       stx     AFAR
        lda     AOC,x
        bit     ATMP
        bne     @clnext                 ; the two share an edge they are outside
        ora     ATMP
        bne     @clip1
        ldx     AVI                     ; both ends on screen: the cheap builder
        lda     AVXL,x
        sta     OS_ARG+0
        lda     AVYL,x
        sta     OS_ARG+1
        ldx     AFAR
        lda     AVXL,x
        sta     OS_ARG+2
        lda     AVYL,x
        sta     OS_ARG+3
        jsr     API_GPU_DOTLINE
        bra     @clnext
@clip1: ldx     AVI
        lda     AVXL,x
        sta     OS_ARG+0
        lda     AVXH,x
        sta     OS_ARG+1
        lda     AVYL,x
        sta     OS_ARG+2
        lda     AVYH,x
        sta     OS_ARG+3
        ldx     AFAR
        lda     AVXL,x
        sta     OS_ARG+4
        lda     AVXH,x
        sta     OS_ARG+5
        lda     AVYL,x
        sta     OS_ARG+6
        lda     AVYH,x
        sta     OS_ARG+7
        jsr     API_GPU_DOTLINE_CLIP
@clnext:
        inc     AVI
        lda     AVI
        cmp     AVN
        bne     @cl
        rts

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

emit_ship:
        lda     #SPR_SHIP
        sta     OS_ARG+0
        ldy     #$00                    ; fb_x = FBCX + offset - 16
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFFH
        adc     #<SHIP_SX
        sta     OS_ARG+1
        tya
        adc     #>SHIP_SX
        sta     OS_ARG+2
        lda     #<SHIP_SY
        sta     OS_ARG+3
        lda     #>SHIP_SY
        sta     OS_ARG+4
        jmp     API_GPU_SPRITE

; -----------------------------------------------------------------------------
; do_hud — patch the four RAM strings, then six VTEXT commands.
; -----------------------------------------------------------------------------
; VTEXT's grid is TEXT's transpose: X = character cell 0-36, Y = line 0-49, in
; the same order and directions as the horizontal opcode.
; -----------------------------------------------------------------------------
do_hud:
        lda     TIER                    ; speed: a canned 4-character field per
        asl     a                       ;   tier, so there is no formatting to do
        asl     a
        tax
        ldy     #$00
:       lda     TIER_TXT,x
        sta     STR_SPD+4,y
        inx
        iny
        cpy     #4
        bne     :-

        lda     TURNIX                  ; turn rate, and the milliseconds per
        clc                             ;   full revolution — the number that is
        adc     #'0'                    ;   actually worth judging
        sta     STR_TRN+5
        lda     TURNIX
        asl     a
        asl     a
        tax
        ldy     #$00
:       lda     TURN_TXT,x
        sta     STR_TRN+7,y
        inx
        iny
        cpy     #4
        bne     :-
        lda     RAMPIX
        clc
        adc     #'0'
        sta     STR_TRN+20

        lda     TSCALE                  ; "TSCALE OFF" / "TSCALE 2 MAX x1.25"
        beq     @scoff
        ldx     #$00                    ; rebuild the line: it may be showing the
:       lda     TPL_SCL2,x              ;   OFF template from a previous frame
        sta     STR_SCL,x
        inx
        cpx     #24
        bne     :-
        lda     TSCALE
        clc
        adc     #'0'
        sta     STR_SCL+7
        lda     TSCALE                  ; (strength-1) * 5 into the max table
        dec     a
        asl     a
        asl     a
        clc
        adc     TSCALE
        sec
        sbc     #$01
        tax
        ldy     #$00
:       lda     TSCALE_TXT,x
        sta     STR_SCL+13,y
        inx
        iny
        cpy     #5
        bne     :-
        bra     @scdone
@scoff: ldx     #$00
:       lda     TPL_SCL,x
        sta     STR_SCL,x
        inx
        cpx     #24
        bne     :-
@scdone:
        lda     HEAD
        jsr     put_hex2
        lda     DEC0
        sta     STR_HDG+5
        lda     DEC1
        sta     STR_HDG+6

        lda     STARN
        jsr     put_dec3
        lda     DEC0
        sta     STR_STA+6
        lda     DEC1
        sta     STR_STA+7
        lda     DEC2
        sta     STR_STA+8
        lda     MOTEN
        jsr     put_dec3
        lda     DEC1
        sta     STR_STA+15
        lda     DEC2
        sta     STR_STA+16
        lda     ADRAWN
        jsr     put_dec3
        lda     DEC1
        sta     STR_STA+19
        lda     DEC2
        sta     STR_STA+20

        lda     #<STR_SPD
        ldx     #>STR_SPD
        ldy     #2
        jsr     vtext_at
        lda     #<STR_TRN
        ldx     #>STR_TRN
        ldy     #4
        jsr     vtext_at
        lda     #<STR_SCL
        ldx     #>STR_SCL
        ldy     #6
        jsr     vtext_at
        lda     #<STR_HDG
        ldx     #>STR_HDG
        ldy     #8
        jsr     vtext_at
        lda     #<STR_STA
        ldx     #>STR_STA
        ldy     #10
        jsr     vtext_at
        lda     #<TXT_H1
        ldx     #>TXT_H1
        ldy     #45
        jsr     vtext_at
        lda     #<TXT_H2
        ldx     #>TXT_H2
        ldy     #47
        ; fall through

; A/X = string pointer, Y = line. Cell 2 keeps clear of the left margin.
vtext_at:
        sta     OS_ARG+3
        stx     OS_ARG+4
        sty     OS_ARG+1
        lda     #$02
        sta     OS_ARG+0
        stz     OS_ARG+2
        jmp     API_GPU_VTEXT

; A -> three ASCII digits in DEC0..DEC2.
put_dec3:
        ldx     #'0'-1
@h:     inx
        sec
        sbc     #100
        bcs     @h
        adc     #100
        stx     DEC0
        ldx     #'0'-1
@t:     inx
        sec
        sbc     #10
        bcs     @t
        adc     #10
        stx     DEC1
        ora     #'0'
        sta     DEC2
        rts

; A -> two ASCII hex digits in DEC0..DEC1.
put_hex2:
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     @nib
        sta     DEC0
        pla
        and     #$0F
        jsr     @nib
        sta     DEC1
        rts
@nib:   cmp     #10
        bcc     :+
        adc     #'A'-10-1               ; carry is set on this path, hence the -1
        rts
:       ora     #'0'
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

; =============================================================================
; Data
; =============================================================================
        .segment "RODATA"

; --- the ship -----------------------------------------------------------------
; Generated from assets/png/ship32.png:
;     python tools/sprgen.py assets/png/ship32.png proto/01_flight/ship32.s \
;            ship32 --tate
; --tate pre-rotates the art a quarter turn, because the monitor is on its side
; and a sprite's width axis runs DOWN the player's screen. Nothing rotates it at
; runtime; the asset is simply stored turned. It is 32x32 with an overlay plane,
; which is 256 bytes - exactly one LOAD page, which is why it is 32 and not 30.
        .include "ship32.s"

; The two sprite slots this cartridge defines, as the four GPU definition pages
; want them: [slot 0, slot SPR_SHIP] per page. Slot 0 keeps the ROM test sprite
; ($F400, 32x26, no overlay) so that a wrong id draws something recognisable
; instead of nothing at all.
SPRDEF:
        .byte   $14, SHIP32_TYPE        ; $0300 SPR_TYPE
        .byte   $00, $00                ; $0400 SPR_PTR_LSB
        .byte   $F4, SHIP_PAGE          ; $0500 SPR_PTR_MSB
        .byte   26,  SHIP32_HEIGHT      ; $0600 SPR_HEIGHT

; =============================================================================
; Asteroids
; =============================================================================
; FIVE SIZES, one authored outline each, at 192, 128, 64, 32 and 16 full-res
; pixels across. The whole point of this pass is to see which of those sizes
; actually read on a 400x300 screen through a dotted line.
;
; Vertices are SIGNED BYTES in HALF-RES pixels, origin-centred, wound in order
; and closed by the drawing code - so the radius of the 192 rock is 48 here, not
; 96. That is the space the line ops work in, so the outline needs no scaling at
; draw time: the transform is one rotation and one add.
;
; The vertex COUNT falls with the size - 12, 10, 8, 6, 5 - because a rock 16 px
; across cannot show more than about five corners anyway, and the small classes
; are the ones that multiply when rocks start breaking. Five is the floor: four
; reads as a diamond, which the eye recognises as a shape rather than as a rock.
; At ~530 cycles a vertex this is also the cheapest LOD knob in the file.
;
; They are deliberately hand-editable: change a number, rebuild, look. The only
; rule is |vertex| <= 127, because qmul indexes its table with |mx| + |cos| and
; that has to stay inside a byte. At 48 there is room to spare.
;
; Shapes are near-circular but irregular - a regular polygon reads as a machined
; part, and the eye picks the repetition out immediately even while it tumbles.
SHAPE_N:    .byte   12, 10, 8, 6, 5         ; vertices in each
SHAPE_R:    .byte   48, 32, 16, 8, 4        ; and the radius that bounds it

; The radius the STARS go out under, which is NOT the bounding one. A rock is
; irregular, so its vertices sit anywhere between about 0.66 and 1.0 of the
; bound: suppress out to the bound and there is a starless halo in every bay of
; the outline; suppress to the smallest vertex and stars shine through every
; point of it. These are the MEAN vertex radius of each shape, ~0.82 of the
; bound, which splits the error - a little leak at the points, a little halo in
; the bays, neither of them large. Tune by eye; preview.py measures both errors
; against the real polygon on every run.
SHAPE_OCC:  .byte   39, 26, 13, 7, 3
SHAPE_LO:   .byte   <SHP192, <SHP128, <SHP64, <SHP32, <SHP16
SHAPE_HI:   .byte   >SHP192, >SHP128, >SHP64, >SHP32, >SHP16

; 192 x 192 full-res -> radius 48 half-res, 12 vertices
SHP192: .byte      44,     2,    35,    20,    25,    41,     2,    34
        .byte    <-16,    32,  <-30,    20,  <-37,     4,  <-37,  <-18
        .byte    <-19,  <-27,   <-4,  <-40,    21,  <-38,    35,  <-16

; 128 x 128 -> radius 32, 10 vertices
SHP128: .byte      29,   <-4,    19,    17,     6,    24,  <-13,    27
        .byte    <-27,    16,  <-27,     3,  <-23,  <-19,   <-8,  <-21
        .byte       8,  <-21,    18,  <-11

; 64 x 64 -> radius 16, 8 vertices
SHP64:  .byte      13,     0,    11,     8,     0,    13,  <-13,     9
        .byte    <-12,   <-2,  <-11,   <-7,   <-2,  <-14,     7,   <-9

; 32 x 32 -> radius 8, 6 vertices
SHP32:  .byte       6,   <-1,     2,     6,   <-3,     7,   <-6,     2
        .byte     <-3,   <-7,     2,   <-5

; 16 x 16 -> radius 4, 5 vertices. At this size a half-res pixel is a quarter of
; the whole rock, so the outline is a lumpy pentagon and its rotation is visibly
; quantised. That is the measurement, not a defect - and five points is the floor:
; four would read as a diamond, which the eye picks out as a shape rather than as
; a rock.
SHP16:  .byte       4,     0,     2,     3,   <-2,     2,   <-3,   <-1
        .byte       1,   <-3

; The size mix, drawn with three bits of the LFSR: eight tickets over five
; classes, weighted away from the two biggest. Edit this to change how the field
; feels without touching any code.
SHAPE_PICK: .byte  0, 1, 2, 3, 4, 2, 3, 4

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

; Speed tiers, in world units per frame. 16 units = 1 full-res pixel and the
; frame is 60.317 Hz, so 16 units/frame = 60 px/s. The top tier crosses the
; 400-pixel screen height in about a second, which is the fastest that still
; leaves the player anywhere to look.
; Speed tiers, signed 8.8 world units per frame. A world unit is 1/16 of a
; full-res pixel and the frame is 60.317 Hz, so one unit per frame is 3.77 px/s
; and the tiers below come out as exact round numbers of pixels per second -
; which is the whole reason the speed is 8.8 and not a byte.
TIER_N      = 11
TIER_ZERO   = 3
TIER_SPD:
        .word   $D836, $E579, $F2BD, $0000, $0D43, $1A87
        .word   $27CA, $350E, $4251, $4F94, $5CD8
;               -150   -100    -50      0    +50   +100
;               +150   +200   +250   +300   +350        px/s
TIER_TXT:
        .byte   "-150", "-100", "-050", "+000", "+050", "+100"
        .byte   "+150", "+200", "+250", "+300", "+350"

; How far down the screen the ship sits at each tier, in full-res pixels. At
; rest it is centred; forward pushes it down so the player sees further ahead,
; reverse lifts it above centre for the same reason. SHOFF_LAG is the ease: the
; offset closes 1/(2^LAG) of the remaining gap each frame.
SHOFF_LAG   = 4
SHIP_OFF:
        .byte   <-80, <-55, <-28, 0, 18, 35, 52, 69, 86, 103, 120

; Turn rates in brad per frame (256 brad = one revolution) and the resulting
; milliseconds per revolution. Rate 8 is the "1/32 of a turn per frame" idea:
; half a second for a full revolution, which is why it sits at the far end of
; the list rather than in the middle of it.
; Turn rates, 8.8 brad per frame, and the milliseconds per revolution each one
; gives. Flying the first version showed rates 1, 2 and 3 brad/frame were the
; usable band and that whole-brad steps inside it were far too coarse - hence the
; fractional heading and the quarter-brad ladder here.
TURN_N      = 8
TURN_RATE:  .word   $00C0, $0100, $0140, $0180, $01C0, $0200, $0280, $0300
;                    0.75   1.00   1.25   1.50   1.75   2.00   2.50   3.00
TURN_TXT:
        .byte   "5659", "4244", "3396", "2830", "2425", "2122", "1698", "1415"

; Optional speed coupling: rate = rate * (1 + xtra/128), indexed by speed tier.
; Standstill is unchanged, top speed is doubled.
; The speed coupling, at full strength: rate * (1 + xtra/128), so the top tier
; turns 1.5x faster than a standstill. TSCALE 2 and 1 shift this right once and
; twice, giving 1.25x and 1.12x.
; How sharply the turn reaches the stick's rate: the angular velocity closes
; 1/(2^shift) of the gap each frame. Index 0 is no ramp at all - the old on/off
; behaviour - so the two can be compared side by side.
RAMP_N      = 4
RAMP_SHIFT: .byte   0, 2, 3, 4

TURN_XTRA:  .byte    27,  18,   9,   0,   9,  18,  27,  37,  46,  55,  64
TSCALE_TXT: .byte   "x1.12", "x1.25", "x1.50"

; HUD templates. Each is exactly 24 bytes, which is what init_strings copies.
TPL_SPD:    .byte   "SPD +000 PX/S", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_TRN:    .byte   "TURN 2 2122 MS/REV R0", 0, 0, 0
TPL_HDG:    .byte   "HDG $00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_STA:    .byte   "STARS 000/088 M00 A00", 0, 0, 0
TPL_SCL:    .byte   "TSCALE OFF", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_SCL2:   .byte   "TSCALE 0 MAX x1.00", 0, 0, 0, 0, 0, 0

TXT_H1:     .byte   "JOY1 L/R TURN  UP/DN SPEED", 0
TXT_H2:     .byte   "FIRE RATE  J2 L/R RAMP", 0
