; =============================================================================
; EfS proto 01 — flight model bench
; =============================================================================
; PURPOSE: measure what is playable, nothing else. There is no gameplay here,
; no collision, no zoom and no asteroid — just the camera, the speed tiers and
; the starfield, so we can look at the screen and decide what the ship should
; feel like. Every number this thing shows is meant to be argued with.
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
;   * the ship: sprite 0, fixed dead centre, always nose-up.
;   * 7 drifting objects: also sprite 0, with real world positions and velocities.
;   * a HUD reading out speed, turn rate and the visible star count.
;
; TWO THINGS THIS BENCH DELIBERATELY GETS "WRONG", SO WE CAN JUDGE THEM
;   1. Heading is a full 8-bit brad angle (256 steps), not the 32 directions the
;      design assumes. Since the ship is always drawn nose-up, the only place 32
;      vs 256 can show up is the smoothness of the world's rotation — so run it
;      at 256 first and see whether 32 would have been visibly steppy.
;   2. Stars are suppressed inside the sprite boxes of the ship and the objects.
;      Sprite 0 has no overlay plane, so without that the stars shine straight
;      through it. This is the deliberately naive version of the occlusion
;      problem real asteroids will have for a much better reason (a dot-line
;      outline is hollow) — it is here to be MEASURED, not to be kept.
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
NOBJ        = 250               ; drifting reference objects, scattered over the
                                ;   whole torus. The world is about 140 screens,
                                ;   so this is ~1.8 on screen at any moment - with
                                ;   a handful you fly away once and never find
                                ;   them again. 250 is the ceiling for a byte index.
SPR_W2      = 8                 ; sprite 0 is 32x26 full-res -> 16x13 half-res,
SPR_H2      = 7                 ;   so half of that, for the occluder boxes

FBCX        = 200               ; full-res framebuffer centre
FBCY        = 149
HCX         = 100               ; half-res framebuffer centre
HCY         = 74

SHIP_SX     = FBCX - 16         ; sprite 0 top-left, so its centre is the screen's
SHIP_SY     = FBCY - 13

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

; --- cartridge RAM ($0400-$77FF is free game RAM) ----------------------------
ROTC_I      = $0400             ; the rotation tables, 8.8: ROT[i] = signed(i) *
ROTC_F      = $0500             ;   coef / 128, integer byte and fraction byte.
ROTS_I      = $0600             ;   Keeping the fraction is what stops a rebase
ROTS_F      = $0700             ;   truncating twice - see star_rebase.
STARBX      = $0800             ; STAR_N bytes: star layer X (the layer IS 0-255)
STARBY      = $0880             ; STAR_N bytes: star layer Y
DOTBUF      = $0900             ; 1 + 2*STAR_N: the DOT_PIXELS payload we build
OCCX0       = $0A00             ; occluder boxes, half-res framebuffer, max 16
OCCX1       = $0A20
OCCY0       = $0A40
OCCY1       = $0A60
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
OBJSXL      = $1A00             ; object screen position for this frame
OBJSXH      = $1B00
OBJSYL      = $1C00
OBJSYH      = $1D00
OBJVIS      = $1E00             ; nonzero when the object survived the cull
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

        stz     SHXL                    ; the middle of the torus, which means
        stz     SHYL                    ;   nothing on a torus but keeps a
        stz     SHXF                    ;   debugger session readable
        stz     SHYF
        lda     #$80
        sta     SHXH
        sta     SHYH

        stz     TRAVL
        stz     TRAVH
        lda     #$80                    ; != HEAD (0), so frame 1 rebases
        sta     BASEHEAD

        lda     #$A5                    ; any nonzero seed; see prng
        sta     PRNGL
        lda     #$3C
        sta     PRNGH

        jsr     init_stars
        jsr     init_motes
        jsr     init_objects
        jmp     init_strings

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
; init_objects — place the reference objects relative to the ship.
; -----------------------------------------------------------------------------
; Scattered over the WHOLE torus, not around the ship: a 16-bit world position
; is uniform by construction, so two random bytes per axis is the whole job.
; Velocities are a gentle drift, at most one world unit a frame.
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
        jsr     prng
        sta     OBJVXL,y
        jsr     prng
        and     #$01                    ; one bit of sign: -1 .. +1 unit/frame
        beq     :+
        lda     #$FF
:       sta     OBJVXH,y
        jsr     prng
        sta     OBJVYL,y
        jsr     prng
        and     #$01
        beq     :+
        lda     #$FF
:       sta     OBJVYH,y
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
        lda     BGDONE                  ; one-shot: wipe the boot screen off the
        bne     :+                      ;   background. The OS replays background
        jsr     API_GPU_CLEARBG         ;   commands on the next frame for us, so
        lda     #$01                    ;   issuing this once is the whole job.
        sta     BGDONE
:
        jsr     do_input
        jsr     do_camera               ; cos/sin, then the two rotation tables
        jsr     do_ship                 ; velocity from tier + heading, integrate
        jsr     do_objects              ; move, transform, collect occluder boxes
        jsr     do_stars                ; BUILD the starfield - see below
        jsr     do_motes                ; BUILD the mote layer
        jsr     emit_objects
        jsr     emit_ship
        jsr     do_hud
        ; The two decorative layers are appended LAST, and in this order: if the
        ; GPU ever runs out of frame to finish the list, what it drops should be
        ; the backdrop, not the ship or the HUD. Stars second to last, motes
        ; last, because motes are the cheapest thing on screen to lose.
        jsr     emit_stars
        jmp     emit_motes

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
        rts                             ; the ROT tables are built by star_rebase,
                                        ;   which only runs when the heading moved

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
; do_objects — integrate, transform to the screen, collect occluder boxes.
; -----------------------------------------------------------------------------
do_objects:
        stz     OCCN
        jsr     add_ship_occluder
        stz     OBJI
@lp:
        ldx     OBJI
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

        ; A cheap reject first: the cull below passes only |d| <= 6400 = $1900,
        ; so a high byte more than 26 away cannot possibly survive it. With most
        ; of a 140-screen world off camera this is what nearly every object hits,
        ; and it costs a fraction of the precise test.
        lda     OBJXH,x
        sec
        sbc     SHXH
        clc
        adc     #26
        cmp     #53
        bcc     :+
        jmp     @cull
:       lda     OBJYH,x
        sec
        sbc     SHYH
        clc
        adc     #26
        cmp     #53
        bcc     :+
        jmp     @cull
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

        ldx     OBJI
        lda     FXL
        sta     OBJSXL,x
        lda     FXH
        sta     OBJSXH,x
        lda     FYL
        sta     OBJSYL,x
        lda     FYH
        sta     OBJSYH,x
        lda     #$01
        sta     OBJVIS,x
        jsr     add_occluder
        bra     @next
@cull:
        ldx     OBJI
        stz     OBJVIS,x
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

; A/Y = signed 16 world units. Carry CLEAR inside +/-6400 (= 400 px), SET outside.
in_range:
        clc
        adc     #<6400
        sta     T0
        tya
        adc     #>6400
        tay
        bmi     @out
        cpy     #>12801
        bcc     @in
        bne     @out
        lda     T0
        cmp     #<12801
        bcc     @in
@out:   sec
        rts
@in:    clc
        rts

; -----------------------------------------------------------------------------
; view_xform — rotate a WORLD-unit offset (PX, PY) into view coords.
; -----------------------------------------------------------------------------
;   vx =  px*cos + py*sin        vy = -px*sin + py*cos
; Four 16x8 multiplies, at the full 1/16-pixel resolution of a world coordinate -
; the caller rounds to a pixel afterwards, not before. Objects are few, so this
; is the honest path; the stars take the table shortcut instead, because there
; are a hundred of them and they do not need it.
; -----------------------------------------------------------------------------
view_xform:
        lda     PXL                     ; px * cos
        sta     MAL
        lda     PXH
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     VXL
        lda     MAH
        sta     VXH

        lda     PYL                     ; + py * sin
        sta     MAL
        lda     PYH
        sta     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        clc
        lda     VXL
        adc     MAL
        sta     VXL
        lda     VXH
        adc     MAH
        sta     VXH

        lda     PYL                     ; py * cos
        sta     MAL
        lda     PYH
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     VYL
        lda     MAH
        sta     VYH

        lda     PXL                     ; - px * sin
        sta     MAL
        lda     PXH
        sta     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        sec
        lda     VYL
        sbc     MAL
        sta     VYL
        lda     VYH
        sbc     MAH
        sta     VYH
        rts

; -----------------------------------------------------------------------------
; add_ship_occluder / add_occluder — the naive star-suppression list.
; -----------------------------------------------------------------------------
; Sprite 0 has no overlay plane, so anything drawn under it shows through its
; black pixels. Real asteroids will be dot-line OUTLINES and have the same
; problem for a much better reason — they are hollow. This box list is the
; deliberately naive version: cost is stars x boxes. Measure it, then decide
; whether the coarse disc mask in docs/design_technical.md 5.4 is worth building.
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
        inc     OCCN
        rts

; FX/FY hold a full-res framebuffer centre. Add its half-res box to the list.
add_occluder:
        ldy     OCCN
        cpy     #16
        bcs     @skip
        lda     FXH                     ; on screen? fb_x is 0..399, so the high
        cmp     #$02                    ;   byte is 0 or 1 — anything else, incl.
        bcs     @skip                   ;   $FF for negative, is off screen
        lsr     a                       ; hx = fb_x >> 1, carry = bit 0 of FXH
        lda     FXL
        ror     a
        cmp     #200
        bcs     @skip
        sta     T0
        lda     FYH
        cmp     #$02
        bcs     @skip
        lsr     a
        lda     FYL
        ror     a
        cmp     #150
        bcs     @skip
        sta     T1

        lda     T0
        sec
        sbc     #SPR_W2
        bcs     :+
        lda     #$00
:       sta     OCCX0,y
        lda     T0
        clc
        adc     #SPR_W2
        bcc     :+
        lda     #199
:       sta     OCCX1,y
        lda     T1
        sec
        sbc     #SPR_H2
        bcs     :+
        lda     #$00
:       sta     OCCY0,y
        lda     T1
        clc
        adc     #SPR_H2
        bcc     :+
        lda     #149
:       sta     OCCY1,y
        inc     OCCN
@skip:  rts

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
        bra     @next
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
        lda     HEAD
        sta     BASEHEAD
        stz     RBMODE
        BUILD_ROT ROTC_I, ROTC_F, COSV, SGNC
        BUILD_ROT ROTS_I, ROTS_F, SINV, SGNS
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
emit_objects:
        stz     OBJI
@lp:    ldx     OBJI
        lda     OBJVIS,x
        beq     @next
        stz     OS_ARG+0                ; sprite 0
        sec
        lda     OBJSXL,x
        sbc     #16
        sta     OS_ARG+1
        lda     OBJSXH,x
        sbc     #$00
        sta     OS_ARG+2
        sec
        lda     OBJSYL,x
        sbc     #13
        sta     OS_ARG+3
        lda     OBJSYH,x
        sbc     #$00
        sta     OS_ARG+4
        jsr     API_GPU_SPRITE
@next:  inc     OBJI
        lda     OBJI
        cmp     #NOBJ
        bne     @lp
        rts

emit_ship:
        stz     OS_ARG+0
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
TPL_STA:    .byte   "STARS 000/088 M00", 0, 0, 0, 0, 0, 0, 0
TPL_SCL:    .byte   "TSCALE OFF", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_SCL2:   .byte   "TSCALE 0 MAX x1.00", 0, 0, 0, 0, 0, 0

TXT_H1:     .byte   "JOY1 L/R TURN  UP/DN SPEED", 0
TXT_H2:     .byte   "FIRE RATE  J2 L/R RAMP", 0
