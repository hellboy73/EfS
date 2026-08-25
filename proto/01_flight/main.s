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
STAR_N      = 110               ; stars in the layer; ~46% are on screen at once
NOBJ        = 7                 ; drifting reference objects
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
HEAD        = $83               ; heading, brad 0-255
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
CDX         = $99               ; per-star ROTC[dx], ROTS[dx], ROTC[dy], ROTS[dy]
SDX         = $9A               ;   (rebase only)
CDY         = $9B
SDY         = $9C
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
SPD         = $BD               ; this frame's speed, signed
PRNGL       = $BE               ; the bench's own LFSR state
PRNGH       = $BF
TRAVL       = $C0               ; distance flown since the last star rebase,
TRAVH       = $C1               ;   signed 8.8, in half-res screen pixels
TRAVI       = $C2               ;   ...its integer part, the frame's scroll offset
BASEHEAD    = $C3               ; the heading the star bases were built for
VYT         = $C4               ; per-star scrolled view-y

; --- cartridge RAM ($0400-$77FF is free game RAM) ----------------------------
ROTC        = $0400             ; 256 B: ROTC[i] = signed(i) * cos / 128
ROTS        = $0500             ; 256 B: ROTS[i] = signed(i) * sin / 128
STARBX      = $0600             ; STAR_N bytes: star layer X (the layer IS 0-255)
STARBY      = $0680             ; STAR_N bytes: star layer Y
DOTBUF      = $0700             ; 1 + 2*STAR_N: the DOT_PIXELS payload we build
OCCX0       = $0800             ; occluder boxes, half-res framebuffer, max 8
OCCX1       = $0808
OCCY0       = $0810
OCCY1       = $0818
OBJXL       = $0820             ; object world positions, 16.8, structure-of-arrays
OBJXH       = $0828
OBJXF       = $0830
OBJYL       = $0838
OBJYH       = $0840
OBJYF       = $0848
OBJVXL      = $0850             ; object velocities, signed 8.8
OBJVXH      = $0858
OBJVYL      = $0860
OBJVYH      = $0868
OBJSXL      = $0870             ; object screen position for this frame
OBJSXH      = $0878
OBJSYL      = $0880
OBJSYH      = $0888
OBJVIS      = $0890             ; nonzero when the object survived the cull
STR_SPD     = $0900             ; HUD strings, patched in place every frame
STR_TRN     = $0920
STR_HDG     = $0940
STR_STA     = $0960
BASEX       = $0A00             ; STAR_N bytes: each star's VIEW-space position at
BASEY       = $0A80             ;   the last rebase - see do_stars

; -----------------------------------------------------------------------------
; BUILD_ROT — fill a 256-byte table with signed(i) * coef / 128.
; -----------------------------------------------------------------------------
; The positive half is a running 16-bit sum: add the coefficient, store the top
; nine bits. That is exact — no rounding drift accumulates over 128 entries —
; and the negative half is just the mirror. This is what buys the star loop its
; multiply-free inner body: four table lookups and two adds per star.
; -----------------------------------------------------------------------------
.macro  BUILD_ROT tbl, coef, sgn
        .local  pos, neg
        stz     ACCL
        stz     ACCH
        ldx     #$00
pos:    lda     ACCL                    ; store acc >> 7, arithmetic
        asl     a                       ;   carry = bit 7 of the low byte
        lda     ACCH
        rol     a                       ;   A = (ACCH << 1) | that bit
        sta     tbl,x
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
        sec                             ; index 128 IS -128, so this entry is
        lda     #$00                    ;   exactly -coef
        sbc     coef
        sta     tbl+128
        ldx     #127                    ; mirror: tbl[256-k] = -tbl[k]
        ldy     #129
neg:    lda     tbl,x
        eor     #$FF
        clc
        adc     #$01
        sta     tbl,y
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
        lda     #2                      ; tier 2 = standing still
        sta     TIER
        lda     #1                      ; turn rate 2 brad/frame, ~2.1 s per rev
        sta     TURNIX
        lda     #2
        sta     TURNR

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
init_objects:
        ldx     #$00
@lp:    txa
        asl     a                       ; Y = X*8: this object's row in OBJ_SEED
        asl     a
        asl     a
        tay
        clc
        lda     SHXL
        adc     OBJ_SEED+0,y
        sta     OBJXL,x
        lda     SHXH
        adc     OBJ_SEED+1,y
        sta     OBJXH,x
        stz     OBJXF,x
        clc
        lda     SHYL
        adc     OBJ_SEED+2,y
        sta     OBJYL,x
        lda     SHYH
        adc     OBJ_SEED+3,y
        sta     OBJYH,x
        stz     OBJYF,x
        lda     OBJ_SEED+4,y
        sta     OBJVXL,x
        lda     OBJ_SEED+5,y
        sta     OBJVXH,x
        lda     OBJ_SEED+6,y
        sta     OBJVYL,x
        lda     OBJ_SEED+7,y
        sta     OBJVYH,x
        inx
        cpx     #NOBJ
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
        jsr     do_stars                ; build and emit the starfield
        jsr     emit_objects
        jsr     emit_ship
        jmp     do_hud

; -----------------------------------------------------------------------------
; do_input — joystick 1.
; -----------------------------------------------------------------------------
; Turning is on the HELD bits; the speed tier and the turn rate are on the EDGE
; bits, because a held direction would rip through ten tiers in a sixth of a
; second and nothing could be judged.
; -----------------------------------------------------------------------------
do_input:
        ldx     TURNIX
        lda     TURN_RATE,x
        sta     TURNR

        lda     JOY1
        and     #JOY_LEFT
        beq     :+
        lda     HEAD
        sec
        sbc     TURNR
        sta     HEAD
:       lda     JOY1
        and     #JOY_RIGHT
        beq     :+
        lda     HEAD
        clc
        adc     TURNR
        sta     HEAD
:
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
        bcc     @ok
        lda     #$00
@ok:    sta     TURNIX
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
        ldx     TIER
        lda     TIER_SPD,x
        sta     SPD

        lda     SPD                     ; VELX = speed * sin, in 8.8
        jsr     sext_ma
        lda     SINV
        sta     MB
        jsr     smul_vel
        lda     MR0
        sta     VELXL
        lda     MR1
        sta     VELXH

        lda     SPD                     ; VELY = -(speed * cos), in 8.8
        jsr     sext_ma
        lda     COSV
        sta     MB
        jsr     smul_vel
        sec
        lda     #$00
        sbc     MR0
        sta     VELYL
        lda     #$00
        sbc     MR1
        sta     VELYH

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

        jsr     asr4_p                  ; world units -> full-res pixels

        lda     PXL                     ; cull well outside the screen, so the
        ldy     PXH                     ;   transform only runs on what matters
        jsr     in_range_400
        bcc     :+
        jmp     @cull
:       lda     PYL
        ldy     PYH
        jsr     in_range_400
        bcc     :+
        jmp     @cull
:
        jsr     view_xform              ; -> VXL/VXH, VYL/VYH

        clc                             ; fb_x = FBCX + vy
        lda     VYL
        adc     #<FBCX
        sta     FXL
        lda     VYH
        adc     #>FBCX
        sta     FXH
        sec                             ; fb_y = FBCY - vx
        lda     #<FBCY
        sbc     VXL
        sta     FYL
        lda     #>FBCY
        sbc     VXH
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

; PX and PY >>= 4, arithmetic. CMP #$80 puts the sign bit into carry for ROR.
asr4_p:
        ldx     #4
@lp:    lda     PXH
        cmp     #$80
        ror     PXH
        ror     PXL
        lda     PYH
        cmp     #$80
        ror     PYH
        ror     PYL
        dex
        bne     @lp
        rts

; A/Y = signed 16. Carry CLEAR if inside -400..400, SET if outside.
in_range_400:
        clc
        adc     #<400
        sta     T0
        tya
        adc     #>400
        tay
        bmi     @out
        cpy     #>801
        bcc     @in
        bne     @out
        lda     T0
        cmp     #<801
        bcc     @in
@out:   sec
        rts
@in:    clc
        rts

; -----------------------------------------------------------------------------
; view_xform — rotate a full-res pixel offset (PX, PY) into view coords.
; -----------------------------------------------------------------------------
;   vx =  px*cos + py*sin        vy = -px*sin + py*cos
; Four 16x8 multiplies. Objects are few, so this is the honest path; the stars
; take the table shortcut instead, because there are a hundred of them.
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
        ldy     OCCN
        lda     #HCX - SPR_W2
        sta     OCCX0,y
        lda     #HCX + SPR_W2
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
        cpy     #8
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
        lda     HEAD
        cmp     BASEHEAD
        beq     @scroll
        jsr     star_rebase
        bra     @ready
@scroll:
        ldy     #$00                    ; travel += speed, sign-extended
        bit     SPD
        bpl     :+
        ldy     #$FF
:       sty     T0
        clc
        lda     TRAVL
        adc     SPD
        sta     TRAVL
        lda     TRAVH
        adc     T0
        sta     TRAVH
@ready:
        lda     TRAVH                   ; the integer part IS this frame's offset
        sta     TRAVI

        stz     DIDX
        stz     STARN
        ldx     #$00
@lp:
        clc                             ; scrolled view-y; the byte wrap is the
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
        beq     @done
        sta     DOTBUF
        lda     #<DOTBUF
        sta     OS_ARG+0
        lda     #>DOTBUF
        sta     OS_ARG+1
        jmp     API_GPU_DOTPIXELS
@done:  rts

; -----------------------------------------------------------------------------
; star_rebase — rebuild every star's view-space base for the current heading.
; -----------------------------------------------------------------------------
; Runs only on a frame where the heading actually moved, so it is a turning-time
; cost, not a flying-time one: two 256-byte table builds plus one transform per
; star. Straight flight pays none of it.
;
; The bases come from the LAYER, not from the previous bases, so nothing
; accumulates. Rotating the stars in place each frame would have been cheaper
; still, but the table's matrix has a determinant of about 0.987 — the field
; would visibly implode, roughly 20% per quarter turn.
;
; Travel resets to zero here, which re-registers the field against the integer
; sample and can shift a star by up to one pixel. That happens only while
; turning, when the whole field is rotating anyway.
; -----------------------------------------------------------------------------
star_rebase:
        lda     HEAD
        sta     BASEHEAD
        stz     TRAVL
        stz     TRAVH
        BUILD_ROT ROTC, COSV, SGNC
        BUILD_ROT ROTS, SINV, SGNS
        lda     SHXH
        sta     SAMPX
        lda     SHYH
        sta     SAMPY
        ldx     #$00
@lp:    lda     STARBX,x
        sec
        sbc     SAMPX
        tay
        lda     ROTC,y
        sta     CDX
        lda     ROTS,y
        sta     SDX
        lda     STARBY,x
        sec
        sbc     SAMPY
        tay
        lda     ROTC,y
        sta     CDY
        lda     ROTS,y
        sta     SDY
        clc                             ; view x = ROTC[dx] + ROTS[dy]
        lda     CDX
        adc     SDY
        sta     BASEX,x
        sec                             ; view y = ROTC[dy] - ROTS[dx]
        lda     CDY
        sbc     SDX
        sta     BASEY,x
        inx
        cpx     #STAR_N
        bne     @lp
        rts

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
        lda     #<SHIP_SX
        sta     OS_ARG+1
        lda     #>SHIP_SX
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

        lda     #<STR_SPD
        ldx     #>STR_SPD
        ldy     #2
        jsr     vtext_at
        lda     #<STR_TRN
        ldx     #>STR_TRN
        ldy     #4
        jsr     vtext_at
        lda     #<STR_HDG
        ldx     #>STR_HDG
        ldy     #6
        jsr     vtext_at
        lda     #<STR_STA
        ldx     #>STR_STA
        ldy     #8
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
; Shift-and-add over the seven magnitude bits of MB. MA is destroyed. The two
; wrappers below turn the 24-bit magnitude into whatever the caller wanted.
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
        ldx     #7
@lp:    lsr     MB
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
@noadd: asl     MAL
        rol     MAH
        dex
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

; (signed byte) x (signed Q0.7) x 2 -> MR0/MR1: the product expressed in 8.8.
smul_vel:
        jsr     smul_core
        asl     MR0
        rol     MR1
        lda     MSGN
        beq     @done
        sec
        lda     #$00
        sbc     MR0
        sta     MR0
        lda     #$00
        sbc     MR1
        sta     MR1
@done:  rts

; =============================================================================
; Data
; =============================================================================
        .segment "RODATA"

; Speed tiers, in world units per frame. 16 units = 1 full-res pixel and the
; frame is 60.317 Hz, so 16 units/frame = 60 px/s. The top tier crosses the
; 400-pixel screen height in about a second, which is the fastest that still
; leaves the player anywhere to look.
TIER_N      = 10
TIER_SPD:   .byte   $F0, $F8, $00, $04, $08, $10, $20, $30, $48, $68
;                   -16   -8     0     4     8    16    32    48    72   104

; The same tiers as a canned readout in pixels per second.
TIER_TXT:
        .byte   "-060", "-030", "+000", "+015", "+030"
        .byte   "+060", "+121", "+181", "+271", "+392"

; Turn rates in brad per frame (256 brad = one revolution) and the resulting
; milliseconds per revolution. Rate 8 is the "1/32 of a turn per frame" idea:
; half a second for a full revolution, which is why it sits at the far end of
; the list rather than in the middle of it.
TURN_N      = 6
TURN_RATE:  .byte   1, 2, 3, 4, 6, 8
TURN_TXT:
        .byte   "4244", "2122", "1415", "1061", " 707", " 531"

; Seed offsets from the ship, and constant velocities, for the drifting
; reference objects: dx16, dy16, vx16, vy16 — velocity is signed 8.8.
; (ca65 wants .word operands unsigned, hence the mask on the negative offsets.)
.define NEG(v) ((-(v)) & $FFFF)
OBJ_SEED:
        .word   1600, NEG 2400,  $0060,  $0100
        .word   NEG 2000,  1000, $FF40,  $0040
        .word   3000,  2600,     $0140,  $FF60
        .word   NEG 3400, NEG 1200, $FF80, $FEC0
        .word    800,  3400,     $0200,  $0080
        .word   NEG 1400,  2800, $FF00,  $FFA0
        .word   2600, NEG 3200,  $00A0,  $0180

; HUD templates. Each is exactly 24 bytes, which is what init_strings copies.
TPL_SPD:    .byte   "SPD +000 PX/S", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_TRN:    .byte   "TURN 2 2122 MS/REV", 0, 0, 0, 0, 0, 0
TPL_HDG:    .byte   "HDG $00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_STA:    .byte   "STARS 000/110", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

TXT_H1:     .byte   "JOY1 L/R TURN  UP/DN SPEED", 0
TXT_H2:     .byte   "FIRE CYCLES TURN RATE", 0
