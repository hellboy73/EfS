; =============================================================================
; EfS proto 02 — rocks & collisions bench
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
;                It is sent to the GPU EXACTLY AS AUTHORED, with the rock's
;                half-res screen centre, one angle and one scale beside it; the
;                GPU rotates, scales and clips it. One angle, not two, because
;                the camera's rotation and the object's spin compose - that part
;                is still the cartridge's, and it is now the only arithmetic the
;                cartridge does per rock.
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
NOBJ        = 120               ; asteroids, scattered over the whole torus. The
                                ;   world is about 140 screens, so a bit over one
                                ;   rock per screen by centre - and because they
                                ;   are up to 192 px across, that comes out as 3
                                ;   to 6 actually on camera. It was 250 while
                                ;   these were dots; every one of them costs the
                                ;   position integrate and the coarse reject
                                ;   whether or not it is anywhere near, which is
                                ;   the single largest item in the frame - see
                                ;   the budget note in README.md.
; The HUD is SEVEN VTEXT commands and ~9,900 cycles a frame (finding 18) on the
; IMAGE layer, which is not where the real game will put it - text is destructive,
; so it belongs on the background where the hardware re-copies it for nothing
; (5.5). Set to 0 to take it out and see the scene without it, and to measure
; what the rest of the frame costs on its own.
HUD_ON      = 0

; Which opcode draws a rock. All three are the SAME command - one closed figure
; per outline, with the centre, the angle, the scale and the RAW shape sent as
; data - and the GPU does the rotate, the scale and the clip. They differ only in
; what they rasterise, and in what resolution the centre and the offsets are read
; at:
;
;   0  $4C DOT_POLYGON  dotted, half-res. The cheapest, and what a rock has
;                       always looked like here.
;   1  $4D POLYGON      solid, half-res. About twice the pixels, because a dotted
;                       line skips every other row.
;   2  $4E POLYGON16    solid, FULL-res. Buys two things, and it is worth being
;                       precise about which:
;
;                       * THE CENTRE. This is the real one. At half-res a rock's
;                         screen position is the full-res one >> 1, so it steps
;                         TWO pixels at a time and a slow drift stutters - the
;                         same defect finding 39 found on the ship and fixed with
;                         LINE16. $4E reads the centre the view transform already
;                         computed, unshifted.
;                       * THE RASTER, drawn solid at full resolution.
;
;                       What it does NOT buy yet is a finer SHAPE, and that is a
;                       measurement, not an oversight: see the note on SHAPE_16X
;                       below. The offsets are the half-res tables doubled, which
;                       is an exact scale-up and lands every vertex on an even
;                       full-res pixel.
;
;                       And note what it TAKES AWAY: there is no dotted full-res
;                       figure. $4E is solid, and finding 24 chose dotted rocks on
;                       purpose - a dotted rim is what reads as rock, and it is
;                       why the asteroids get a suppression disc instead of an
;                       occluder box (a hollow outline lets the field shine
;                       through). Going full-res means going solid; that is an
;                       art decision riding on a resolution one, so look at it
;                       before adopting it.
ROCK_FAMILY = 2

.if ROCK_FAMILY = 2
ROCK_BUILDER = API_GPU_POLYGON16
SHAPE_16X    = 1                ; ...and the offsets are doubled on the way out
.elseif ROCK_FAMILY = 1
ROCK_BUILDER = API_GPU_POLYGON
SHAPE_16X    = 0
.else
ROCK_BUILDER = API_GPU_DOTPOLYGON
SHAPE_16X    = 0
.endif

; Doubling the shape rather than keeping a second, full-res table is deliberate,
; and the reason is that a full-res table CANNOT BE DERIVED - it has to be
; authored, and that is a design job, not a build step. The half-res integers
; carry no sub-half-res information: recovering (angle, radius) from a vertex and
; re-rounding it at twice the radius gives back exactly twice the vertex, every
; time, for every shape here. Measured, because it looked like it ought to work.
;
; So the choice is an honest doubling now, or new artwork. Doubling costs one ASL
; per byte in the copy below, keeps ONE table that cannot drift out of step with
; itself, and makes "these are not full-res shapes" a fact of the code rather
; than a comment on a duplicate. When the shapes ARE authored at full res -
; deeper bays, sharper points, radii that land between the half-res rungs, which
; matters most on SHP16 where one half-res pixel is a quarter of the whole rock -
; this becomes a second table and SHAPE_16X goes away.
;
; The doubling is safe for every shape: the largest authored coordinate is 44
; (SHP192), so the largest doubled one is 88, well inside the +/-127 the GPU's
; multiply needs. Author a half-res vertex past 63 and that stops being true.

SPR_W2      = 8                 ; the ship is 32x32 full-res -> 16x16 half-res,
SPR_H2      = 8                 ;   so half of that, for the occluder box

; The star-occlusion pass is indexed by SCREEN ROW BAND. The old shape was "for
; each star, for every occluder", which is O(stars x occluders) - 40 survivors
; times up to 16 boxes is 640 tests, and it grows with exactly the thing that
; overloads the frame. Inverted: an occluder is registered in the bands its box
; spans, and a star tests only the occluders in ITS band.
;
; 16 half-res rows a band (OCCB_SH = 4) keeps the list index in a byte -
; band*16 + slot is at most 9*16+15 = 159 - and it is why the base offset comes
; out as FBY & $F0 with no shifting at all. 16 slots a band is the OCCN maximum,
; so a band can never overflow and the build needs no capacity test.
OCCB_SH     = 4                 ; FBY >> this = band
OCCB_N      = 10                ; bands covering FBY 0..149

; The SECTOR GRID. do_objects used to walk all NOBJ every frame just to ask each
; rock whether it was near - 40 cycles a rock, paid on the 99% that are not, and
; the reason NOBJ is a budget parameter rather than a world parameter.
;
; A cell is the top nibble of each position high byte: 16 x 16 cells over the
; torus, 4096 world units (256 reference px) a side. The cell index is one byte,
; (YH & $F0) | (XH >> 4), and THE WRAP IS FREE - a cell column past 15 masks back
; to 0, which is the same overflow that makes the world a torus in the first
; place. Only cells overlapping the cull window are visited, so the cost becomes
; proportional to what is NEAR rather than to how many rocks exist.
;
; Rocks outside the window are frozen (finding 11), so they can never change
; cell: the lists only need maintaining for the handful being integrated, and a
; rock crosses a 4096-unit boundary about once in 300 frames.
PEND_MAX    = 16                ; deferred cell moves per frame; overflow is safe
                                ;   - it just relinks on a later frame instead
; The ship is a VECTOR OUTLINE for now, not the sprite. Set SHIP_SPRITE = 1 to
; put ship32.png back: the asset, the converter and the whole upload path are
; still here, just assembled out. The outline is here to be measured against a
; sprite once zoom exists - it scales for nothing, where a sprite would need a
; pre-scaled frame per zoom step, and the ship is the one object in the game
; that never rotates so the usual argument for sprites does not apply to it.
SHIP_SPRITE = 0

; The outline itself - SHIP_SHAPE, up to 13 signed byte (dx,dy) vertices, and
; SHIP_VN, how many of them are used - lives in shapes.s next to the rock
; outlines, so the shape editor has one file for every drawable shape. It was
; a fixed triangle (SHIP_NOSE/TAIL/HALFW) until it moved to an authored N-gon;
; emit_ship still draws it as solid FULL-res LINE16 segments for the same
; reason as before - see the note there. qmul indexes its table with
; |x| + |y|, so a vertex has the same +/-127 ceiling as a rock's does.

SPR_SHIP    = 1                 ; the slot the ship art is installed into. Slot 0
                                ;   is left as the ROM test sprite so that a
                                ;   forgotten id draws something recognisable
SHIP_PAGE   = $10               ; ...and the GPU RAM page its 256 bytes land on
LOD_R       = 16                ; below this ON-SCREEN radius (half-res) a rock
                                ;   switches to its AUTHORED reduced outline, if
                                ;   its shape id has one (shapes.s SHAPE_LODN). A
                                ;   rock that small cannot show its corners, and
                                ;   the zoom makes every rock small at speed -
                                ;   which is exactly when the frame is tightest.
                                ;
                                ; This used to be "every SECOND vertex of the
                                ; full outline", gated by a vertex-count floor
                                ; (LOD_MIN_N, was 8 then 10): every second vertex
                                ; of an octagon is a QUADRILATERAL, not a rock -
                                ; the shape census said so before the eye did, no
                                ; 8-gon or 12-gon ever reached the screen
                                ; unhalved, and 174 of 483 outlines drawn were
                                ; 4-gons, all of them reduced octagons. The
                                ; lesson was about the REDUCTION, not the
                                ; threshold - striding is not a level of detail,
                                ; it is a coincidence that happens to work on a
                                ; 12-gon and destroys an 8-gon - so reduced
                                ; shapes are now authored, same as the full ones,
                                ; and a shape with none (SHAPE_LODN = 0) simply
                                ; stays at full detail rather than being struck.
; THE FRAME CANNOT BE ALLOWED TO OVERRUN, and the reason is far worse than a
; dropped frame. The ping-pong SRAMs swap owner at EVERY VSYNC, unconditionally,
; in hardware. If CPU1 is still building when that happens, the rest of its list
; lands in the OTHER chip - on top of the list from two frames ago - and then
; gpu_end stamps CPU_READY on that splice. The GPU has no way to tell, walks into
; the seam mid-command, and starts executing whatever follows as opcodes. What
; follows is the HUD, and HUD text is full of live opcodes: ' ' is CLEAR_BG, '0'
; is LOAD (258 bytes into an arbitrary GPU page), 'D' is DOT_LINE with letters
; for coordinates. That is how a late frame writes to the background layer and
; how it eventually latches BLINDER and kills the screen for good. Reproduced,
; decoded out of an F2 dump, and written up in README finding 30.
;
; The GPU has its OWN version of this, and moving work there is what makes it
; ours to worry about. Its policy is "the new frame wins": the ping-pong swap is
; unconditional hardware, so a GPU still dispatching when VSYNC arrives has had
; the list it was reading swapped away underneath it, and resuming would splice
; one frame into another. It abandons the rest instead - the picture loses
; whatever the list had not reached yet, which is why the decorative layers are
; appended LAST - and counts it in OVERRUN_CNT. That counter lives in GPU RAM and
; CPU1 cannot read it; madsim's F3 meter is where you see it.
;
; So the outlines get a hard budget rather than a count: a rock costs what it
; actually costs, and the unit is one VERTEX, because the cost is linear in
; vertices on either side of the machine.
;
; WHAT CHANGED WITH THE POLYGON FAMILY: the budget still counts vertices, but it
; is no longer CPU1's frame it is protecting. A vertex used to be ~530 cycles of
; CPU1 transform; it is now ~30 of copying, and 1,500-1,900 GPU cycles of
; transform, clip and raster. Same valve, same lever - fewer vertices - but the
; GPU's frame on the other end of it. AST_CLIP is gone: a rock that straddles an
; edge used to cost ~3,000 CPU cycles a crossing segment through
; gpu_dotline_clip, and it is now one command like any other.
;
; SO THE BUDGET IS DERIVED, NOT TYPED. Hand-picking it went wrong once already
; and the failure was invisible in the bench: see finding 49. The three opcodes
; rasterise different amounts, the HUD is ~48,700 GPU cycles when it is on, and a
; constant tuned for one combination silently drops rocks in another. Writing the
; arithmetic out means changing ROCK_FAMILY or HUD_ON re-derives both valves.
;
;   AST_VCOST    GPU cycles a vertex, measured over the bench flight, worst frame
;   AST_NONROCK  what the GPU's worst frame costs WITHOUT any rocks in it
;   209,000      of the 237,404 available - the same 88% discipline the original
;                budget kept on CPU1, leaving margin for a frame busier than any
;                the bench has flown
.if ROCK_FAMILY = 2
AST_VCOST   = 1873              ; $4E POLYGON16
.elseif ROCK_FAMILY = 1
AST_VCOST   = 1749              ; $4D POLYGON
.else
AST_VCOST   = 1564              ; $4C DOT_POLYGON
.endif
.if HUD_ON
AST_NONROCK = 62700             ; ...of which ~48,700 is seven VTEXT commands
.else
AST_NONROCK = 14000
.endif
AST_BUDGET  = (209000 - AST_NONROCK) / AST_VCOST

; The count cap exists to bound PPRAM and the per-rock fixed costs the vertex
; budget does not model, NOT to limit rocks - so it must never bind before the
; budget does. The smallest shape is 5 vertices and has no authored reduced
; outline (shapes.s SHAPE_LODN), so five is the fewest units a drawn rock can
; cost, and a ceiling of
; BUDGET/5 cannot be reached until the budget is spent.
;
; This is exactly what went wrong at 10: it fired with budget still unspent and
; abandoned every REMAINING entry in the visible list - wherever those rocks
; happened to be on screen. A count cap is not a cost cap and must not act like
; one. Finding 49.
AST_MAX     = (AST_BUDGET + 4) / 5

FBCX        = 200               ; full-res framebuffer centre
FBCY        = 149
HCX         = 100               ; half-res framebuffer centre
HCY         = 74

SHIP_SX     = FBCX - 16         ; sprite top-left, so its centre is the screen's
SHIP_SY     = FBCY - 16

; --- cartridge zero page ($80-$FF belongs to the game) -----------------------
FRAME       = $80               ; $80-$81 16-bit frame counter
BGDONE      = $82
HEAD        = $83               ; heading, brad 0-255 (the integer part)
TIER        = $84               ; DERIVED each frame from THRTLL/THRTLH, 0..
                                ;   TIER_N-1 - see do_input. (ETIER/BOOSTN are
                                ;   NOT here - $9B/$9C are star_rebase's SDXI/
                                ;   SDXF, and do_stars runs after do_ship, so it
                                ;   would eat them)

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
VELXL       = $91               ; ship velocity, signed 16.8 world units/frame
VELXH       = $92
VELYL       = $93
VELYH       = $94
VELXT       = $95               ; ...their top bytes, so the ship's velocity is
VELYT       = $96               ;   16.8 like its position and a boost can exceed
                                ;   what 8.8 holds - see vel_shl
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
MAT         = $0CAE             ; ...and a third byte the multiply never touches:
                                ;   vel_shl widens its result into it
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
THRTLL      = $ED               ; throttle position, 0..THRTL_MAX - see do_input.
THRTLH      = $EE               ;   Two of the three bytes this used to be FREE;
                                ;   they held the rock transform's split trig
                                ;   before that loop moved to the GPU with $4C.
ARAD        = $EF               ; its bounding radius, half-res pixels
SHPL        = $F5               ; pointer to the shape's vertex list
SHPH        = $F6
AVN         = $F7               ; vertices in that list
AVN2        = $F8               ; ...and 2N, the copy loop's stop
CX2L        = $F9               ; the rock's centre in HALF-res framebuffer
CX2H        = $FA               ;   coordinates, signed 16
CY2L        = $FB
CY2H        = $FC
THFRAC      = $FD               ; ...and THRTL's low 7 bits, a ready-made Q0.7
                                ;   fraction for do_ship's lerp
ADRAWN      = $FE               ; rocks drawn so far this frame
; The bootstrap's own scratch at $F0-$F4 is still free and dead by the first
; frame - not worth reusing for five bytes.

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
OCCBN       = $1B40             ; OCCB_N bytes: occluders registered in each band
OCCBL       = $1B50             ; OCCB_N * 16: their ids, band b at offset b*16
PEND        = $1BF0             ; PEND_MAX ids whose cell changed this frame
                                ;   (OCCBL ends at $1BEF and CELLHD starts at
                                ;   $1C00, so this slot is exactly 16 bytes)
CELLHD      = $1C00             ; 256 cells: the first object in each, $FF = empty
OBJNXT      = $1D00             ; NOBJ bytes: the next object in the same cell
OBJCEL      = $1E00             ; NOBJ bytes: which cell each one is LINKED into
DSQL        = $62D1             ; disc_hit's own 16-bit scratch
DSQH        = $62D2
AOCR        = $62D3             ; this rock's star-suppression radius
ZEASL       = $62D4             ; the EASED zoom reciprocal, 8.8 Q0.7-per-1,
ZEASH       = $62D5             ;   read by nothing but the quantiser
ZOOMH       = $62F8             ; ...and the snapped one, which is what the whole
                                ;   rest of the frame means by "the zoom"
ZSHEAD      = $62D6             ; the reciprocal the ZS tables were built for
CULRL       = $62D7             ; this frame's cull radius, from ZOOM_CULLR
CULRH       = $62D8
CUL2L       = $62D9             ; ...and 2*CULR + 1, which in_range compares to
CUL2H       = $62DA
CULHI       = $62DB             ; the high-byte window, from ZOOM_CULLH
CULHI2      = $62E1             ; ...doubled plus one, the compare it feeds
ASHP        = $62E2             ; this rock's size class, kept because qmul
                                ;   clobbers both index registers
AVSTEP      = $62E3             ; bytes to the next vertex: 2, or 4 at half LOD
OVRCNT      = $62E4             ; frames the OS reported as overrun
ABUDGET     = $62E5             ; outline work left this frame, in vertex-units
SIDX        = $62E6             ; the star loop's index, parked over the band walk
OCCBW       = $62E7             ; ...and how many of that band's occluders are left
OCCBMAX     = $62E8             ; deepest band ever walked, for the harness
GX0         = $62E9             ; the sector walk: first cell column and row...
GY0         = $62EA
GN          = $62EB             ; ...how many of each, 2R+1
GDY         = $62ED             ; ...and the cursor over the rows
GROW        = $62EE             ; this row's cell index, already shifted
GNEXT       = $62EF             ; the successor in the cell list, read BEFORE the
                                ;   body runs so a relink cannot lose the walk
GTMP        = $62F0
GOBJ        = $62F1             ; the object cell_flush is moving
PENDN       = $62F2             ; deferred cell moves waiting
GCELLS      = $62F3             ; cells visited this frame, for the harness
GPENDMX     = $62F4             ; deepest PEND ever reached, likewise
GRUN        = $62F5             ; cells left in the contiguous run being walked
GRUN2       = $62F6             ; ...and in the one that wrapped past column 15
GCELL       = $62F7             ; the run cursor, parked while a rock is drawn
ETIER       = $62F9             ; the tier the frame actually uses: TIER, except
                                ;   while boosting, when it is TIER_BOOST
BOOSTN      = $62FA             ; frames of boost left, 0 = not boosting
SHIP_TMP    = $62DC             ; emit_ship's own scratch: one scaled vertex
SHIP_EXT    = $62DD             ;   axis, and its sign-extension byte for the
                                ;   16-bit add into the centre
SOCCW       = $62DF             ; the ship's occluder box, half-extents
SOCCH       = $62E0
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
SHOFXL      = $0CA0             ; the CROSS-axis camera offset, signed 8.8
SHOFXH      = $0CA1             ;   full-res px. Nothing but the world, the ship
                                ;   and the ship's occluder box reads it.
SHCY        = $0CA2             ; ...and HCY + half of it, the HALF-res cross
                                ;   centre the ship's occluder box is built about
SHOFXQ      = $0CAC             ; the lean >> 4, ready for the object loop
TPGO        = $0CAF             ; a teleport was asked for this frame
TPDST       = $0CB0             ; ...the SHOFF it will land on, signed
TPML        = $0CB1             ; ...and how far it moves, full-res screen px
TPMH        = $0CB2
TPCNT       = $0CB3             ; teleports so far, for the HUD and the harness
SHOFT       = $0CB4             ; the SHOFF ease's 24-bit gap: target top byte...
SHOFC       = $0CB5             ;   ...and the current offset's
TPSGN       = $0CB6             ; the landing point's sign extension
STR_SCL     = $0C80
QSL         = $0E00             ; the quarter-square multiply table, f(x) = x*x/4
QSH         = $0F00             ;   for x = 0..255, low byte and high byte
QRL         = $6400             ; ...and the same table plus 64. Subtracting the
QRH         = $6500             ;   plain one from THIS one is the rounding: the
                                ;   +64 that a >>7 needs, for no cycles at all
ZSI         = $6600             ; the ZOOM table: ZS[i] = signed(i)*RZ/128, 8.8,
ZSF         = $6700             ;   the same shape as ROT and read the same way -
                                ;   see RPROD. Rebuilt when the reciprocal moves
OBJSHP      = $1F00             ; NOBJ bytes: which of the five sizes each rock is
OBJTYPE     = $1F80             ; NOBJ bytes: which authored variant of that size
                                ;   (0..AST_TYPES-1) - see shapes.s and TYPE_PICK
OBJANG      = $6000             ; NOBJ bytes: its spin angle, brad (integer part)
OBJANGF     = $6100             ; ...and the fraction, so a spin can be far slower
                                ;   than one brad a frame
SHIP_PVX    = $6200             ; emit_ship's own scratch, FULL-res signed 16 -
SHIP_PVY    = $6202             ;   the PREVIOUS vertex placed this frame, the
SHIP_FVX    = $6204             ;   FIRST one (so the last edge can close the
SHIP_FVY    = $6206             ;   loop back to it) and the one just computed.
SHIP_CURX   = $6208             ;   Fixed size regardless of SHIP_VN (shapes.s)
SHIP_CURY   = $620A             ;   - the outline is walked and drawn a vertex
                                ;   at a time, nothing needs to hold all of it
                                ;   at once, so there is no per-vertex array to
                                ;   size and no cap tied to one - see emit_ship.
SHIP_VI     = $620C             ; the vertex counter - zero page, not X: see
                                ;   emit_ship for why nothing here trusts a
                                ;   register to survive a JSR
SHIP_SIGN   = $620D             ; sscale's own scratch: the original signed
                                ;   value, re-tested after qmul clobbers A
PBUF        = $6280             ; the POLYGON argument block: 7 header bytes and
                                ;   then 2*AVN of shape, 31 at the largest rock.
                                ;   $6200-$627F and $62A0-$62BF used to hold the
                                ;   transformed outline and its outcodes; the GPU
                                ;   owns both now, so 160 bytes came back.
DEFPG       = $6300             ; one page of the GPU sprite definition table,
                                ;   staged here and shipped with LOAD
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
        lda     #<(TIER_ZERO*128)       ; THRTL starts at TIER_ZERO exactly, so
        sta     THRTLL                  ;   TIER derives to TIER_ZERO and THFRAC
        lda     #>(TIER_ZERO*128)       ;   to 0 on the very first frame - see
        sta     THRTLH                  ;   do_input for the shift that recovers
        lda     #TIER_ZERO              ;   both from this
        sta     TIER
        sta     ETIER
        stz     BOOSTN
        stz     SHOFFL
        stz     SHOFFH
        lda     #3                      ; 2.83 s per revolution - the settled-on
        sta     TURNIX                  ;   default; see open_questions.md B2
        stz     TURNVL
        stz     TURNVH
        lda     #2                      ; the settled-on wind-up; ramp/tscale no
        sta     RAMPIX                  ;   longer change at runtime - see do_input
        stz     PSHOFFL
        stz     PSHOFFH
        stz     HEADF
        lda     #2                      ; the settled-on speed-coupled turn rate,
        sta     TSCALE                  ;   x1.25 at the top tier
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
        lda     #128                    ; 1:1, and ZSHEAD != it so frame 1 builds
        sta     ZOOMH                   ;   the scale table too
        sta     ZEASH
        stz     ZEASL
        stz     ZSHEAD

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
; sscale — A = a SIGNED byte, scaled by ZEASH through qmul, -> signed A.
; Clobbers X, same as qmul (which does the actual multiply) - deliberately: a
; caller that needs a register to survive this should not be trusting a JSR to
; carry it, it should be keeping its own loop state in zero page. emit_ship
; used to lean on PHX/PHY/PLX/PLY here to protect a vertex counter and a shape
; pointer across this call and API_GPU_LINE16 both - measured wrong in
; madsim (not in the py65 harness, which is exactly the kind of gap a
; register-preservation trick can hide): the counter is in SHIP_VI now,
; and the shape pointer walks itself forward instead of riding Y, so nothing
; here needs a register to still be what it was after a call returns.
; -----------------------------------------------------------------------------
; qmul only takes magnitudes, so this strips the sign, scales, and puts it
; back - the one-vertex-at-a-time version of what a rock's trig does once per
; rock.
; -----------------------------------------------------------------------------
sscale:
        sta     SHIP_SIGN               ; remember the ORIGINAL value - not just
        bpl     @scale                  ;   its sign, the whole byte, so it can
        eor     #$FF                    ;   be re-tested after qmul clobbers A
        sec                             ;   two's-complement negate - magnitude,
        adc     #$00                    ;   not assuming anything about the
                                        ;   incoming carry
@scale: sta     MQA
        lda     ZEASH
        sta     MQB
        jsr     qmul                    ; A = magnitude * scale, rounded
        ldx     SHIP_SIGN               ; test the ORIGINAL sign, not anything
        bpl     @done                   ;   qmul or this routine touched
        eor     #$FF
        sec
        adc     #$00
@done:  rts

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

        jsr     prng                    ; which authored variant of that class -
        and     #$07                    ;   same eight-ticket trick, orthogonal
        tax                             ;   to the size pick above
        lda     TYPE_PICK,x
        sta     OBJTYPE,y

        lda     OBJSHP,y                ; velocity: AST_VEL[class][index & 3],
        asl     a
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
        ; fall through: the field is placed, so bucket it

; -----------------------------------------------------------------------------
; init_cells — bucket the whole field into the sector grid, once.
; -----------------------------------------------------------------------------
; This is the only full pass over NOBJ in the program. Afterwards the grid is
; maintained incrementally by the handful of rocks that are actually moving.
; -----------------------------------------------------------------------------
init_cells:
        lda     #$FF                    ; every cell empty
        ldx     #$00
:       sta     CELLHD,x
        inx
        bne     :-
        stz     PENDN
        stz     GPENDMX

        ldx     #NOBJ-1
@lp:    jsr     cell_of                 ; A = this rock's cell
        sta     OBJCEL,x
        tay
        lda     CELLHD,y                ; push at the head
        sta     OBJNXT,x
        txa
        sta     CELLHD,y
        dex
        bpl     @lp
        cpx     #$FF                    ; (NOBJ may exceed 128, so bpl alone
        bne     @lp                     ;  is not the whole loop)
        rts

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
.if SHIP_SPRITE
        lda     SPRSTEP                 ; the sprite upload, one LOAD page per
        cmp     #$05                    ;   frame, and FIRST in the frame it
        bcs     :+                      ;   happens on - see upload_step
        jsr     upload_step
:
.endif
        lda     BGDONE                  ; one-shot: wipe the boot screen off the
        bne     :+                      ;   background. The OS replays background
        jsr     API_GPU_CLEARBG         ;   commands on the next frame for us, so
        lda     #$01                    ;   issuing this once is the whole job.
        sta     BGDONE
:
        ; ---- repair after a frame we failed to deliver ----------------------
        ; OVERRUN_FLAG is set by the OS when a VSYNC fired before gpu_end. It is
        ; sticky and the OS never clears it, so a cartridge that reads and clears
        ; it gets per-frame detection - and this one needs it, because a late
        ; frame here does not merely blink. See the note on AST_BUDGET: the list
        ; gets spliced across both ping-pong chips and stamped CPU_READY, the GPU
        ; executes HUD text as opcodes, and ' ' (CLEAR_BG) and '0' (LOAD) are
        ; among them. Re-issuing CLEAR_BG cannot undo a LOAD, but it does repair
        ; the background layer, which is the damage that persists and accumulates.
        ;
        ; This is a mitigation, not a fix. The fix is four bytes in the OS: do not
        ; stamp CPU_READY when VSYNC_FLAG is already set. os_run computes exactly
        ; that condition one instruction too late.
        lda     OVERRUN_FLAG
        beq     :+
        stz     OVERRUN_FLAG
        inc     OVRCNT
        jsr     API_GPU_CLEARBG
:
        jsr     do_input
        jsr     do_camera               ; cos/sin, then the two rotation tables
        jsr     do_ship                 ; velocity from tier + heading, integrate
        jsr     do_objects              ; move and spin the rocks, transform them
        jsr     emit_asteroids          ; ...which also registers their occluder
        jsr     do_stars                ;   discs, which do_stars needs: it is the
        jsr     do_motes                ;   one pass that has to run after them
        jsr     emit_ship
.if HUD_ON
        jsr     do_hud
.endif
        ; The two decorative layers are appended LAST, and in this order: if the
        ; GPU ever runs out of frame to finish the list, what it drops should be
        ; the backdrop, not the ship or the HUD. Stars second to last, motes
        ; last, because motes are the cheapest thing on screen to lose.
        jsr     emit_stars
        jmp     emit_motes

.if SHIP_SPRITE
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

.endif

; -----------------------------------------------------------------------------
; do_input — joystick 1 turns and throttles; joystick 2 boosts and teleports.
; -----------------------------------------------------------------------------
; Turning and the throttle are both HELD bits now - the turn-rate/ramp/speed-
; coupling knobs that used to live on edge bits here were debug controls for
; comparing settings back to back, and are gone now that the values are fixed.
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

        ; ---- throttle: continuous, not stepped -------------------------------
        ; JOY1 UP/DOWN are now HELD bits, not edge bits: holding UP accelerates
        ; smoothly from a standstill to the top tier and releasing holds
        ; whatever speed that reached, so getting to +350 no longer means
        ; clicking UP ten times. THRTLL/THRTLH is the position, 0..THRTL_MAX,
        ; and because THRTL_MAX is (TIER_N-1)*128 the old per-tier machinery
        ; falls out of it for free: TIER = position >> 7 (128 divides a byte
        ; evenly, so that is a shift, not a divide) and THFRAC, the low 7 bits,
        ; is a ready-made Q0.7 fraction for do_ship to lerp TIER_SPD with -
        ; the same smul16q7 the speed-coupled turn rate above already uses.
        ; THRTL_ACCEL is a first cut (TBM): full range in THRTL_MAX/THRTL_ACCEL
        ; frames, about 1.3 s at 60.317 Hz - the number to retune by flying it.
        lda     JOY1
        and     #JOY_UP
        beq     :+
        clc
        lda     THRTLL
        adc     #THRTL_ACCEL
        sta     THRTLL
        lda     THRTLH
        adc     #$00
        sta     THRTLH
        cmp     #>THRTL_MAX
        bcc     @thok
        bne     @thclip
        lda     THRTLL
        cmp     #<THRTL_MAX
        beq     @thok
@thclip:
        lda     #<THRTL_MAX
        sta     THRTLL
        lda     #>THRTL_MAX
        sta     THRTLH
@thok:
:       lda     JOY1
        and     #JOY_DOWN
        beq     :+
        sec
        lda     THRTLL
        sbc     #THRTL_ACCEL
        sta     THRTLL
        lda     THRTLH
        sbc     #$00
        sta     THRTLH
        bcs     :+
        stz     THRTLL
        stz     THRTLH
:       lda     THRTLL                  ; TIER = THRTL >> 7: the top bit of the
        asl     a                       ;   low byte joins the high byte's *2.
        lda     THRTLH
        rol     a
        sta     TIER
        lda     THRTLL
        and     #$7F
        sta     THFRAC

        lda     JOY2_PRESS              ; joystick 2 UP: BOOST. Only from the top
        and     #JOY_UP                 ;   tier, and not while one is running -
        beq     :+                      ;   so it cannot be stacked or held
        lda     BOOSTN
        bne     :+
        lda     TIER
        cmp     #TIER_N-1
        bne     :+
        lda     #BOOST_FRAMES
        sta     BOOSTN
:       lda     JOY2_PRESS              ; joystick 2 DOWN: TELEPORT
        and     #JOY_DOWN
        beq     :+
        inc     TPGO
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
        ; The boost is a TIER the player cannot select. It runs out on its own,
        ; and while it does, every table this frame reads is indexed by ETIER
        ; instead of TIER - which is how it changes the speed without changing
        ; the zoom or the ship's place on screen: those two rows of ZOOM_RZ and
        ; SHIP_OFF are copies of the top tier's.
        lda     TIER
        ldx     BOOSTN
        beq     :+
        dec     BOOSTN
        lda     #TIER_BOOST
:       sta     ETIER

        ; SPD used to be a plain TIER_SPD[ETIER] lookup - one of eleven round
        ; numbers, snapped to on the frame a tier changed. The throttle is
        ; continuous now (do_input's THRTLL), so SPD lerps between TIER_SPD[TIER]
        ; and TIER_SPD[TIER+1] by THFRAC instead, and only boosting still forces
        ; the flat lookup: TIER_BOOST's row duplicates the top tier's, which is
        ; how it changes vel_shl's multiplier without moving SPD, ZOOM or SHOFF -
        ; and THFRAC is always 0 at TIER 10 anyway, so the two paths agree there.
        lda     ETIER
        cmp     #TIER_BOOST
        bne     @spd_interp
        asl     a
        tax
        lda     TIER_SPD,x
        sta     SPDL
        lda     TIER_SPD+1,x
        sta     SPDH
        bra     @spd_done
@spd_interp:
        lda     TIER
        asl     a
        tax
        sec
        lda     TIER_SPD+2,x
        sbc     TIER_SPD,x
        sta     MAL
        lda     TIER_SPD+3,x
        sbc     TIER_SPD+1,x
        sta     MAH
        lda     THFRAC
        sta     MB
        jsr     smul16q7                ; clobbers X, so TIER (a plain zero-page
        lda     TIER                    ;   byte) is re-read below rather than
        asl     a                       ;   stashed across the call
        tax
        clc
        lda     MAL
        adc     TIER_SPD,x
        sta     SPDL
        lda     MAH
        adc     TIER_SPD+1,x
        sta     SPDH
@spd_done:
        lda     SPDL                    ; VELX = speed * sin. Speed is already
        sta     MAL                     ;   8.8, so the Q0.7 multiply lands in
        lda     SPDH                    ;   8.8 too and the old byte-wide
        sta     MAH                     ;   smul_vel is gone.
        lda     SINV
        sta     MB
        jsr     smul16q7
        jsr     vel_shl                 ; ...then the tier's speed multiplier
        lda     MAL
        sta     VELXL
        lda     MAH
        sta     VELXH
        lda     MAT
        sta     VELXT

        lda     SPDL                    ; VELY = -(speed * cos)
        sta     MAL
        lda     SPDH
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        jsr     vel_shl
        sec
        lda     #$00
        sbc     MAL
        sta     VELYL
        lda     #$00
        sbc     MAH
        sta     VELYH
        lda     #$00
        sbc     MAT
        sta     VELYT

        ; The ship slides down the screen as it speeds up, and above centre in
        ; reverse, so the player is always looking at where they are going. It
        ; EASES toward the tier's target instead of snapping: a jump on every
        ; tier change would be unreadable, and this shift is the camera-lag
        ; constant the design still has to settle (open question B3).
        ; The GAP is 24-bit, and it has to be. Target and offset are each a
        ; signed byte of pixels, so their difference reaches 255 px - which in
        ; 8.8 is 65280 and is not a positive signed 16. Between adjacent tiers
        ; the gap never exceeded 127 px and this never showed; the teleport opens
        ; a 246 px gap in one frame, the subtract wrapped, and the ease walked
        ; the ship AWAY from its target. SHOFF itself stays 8.8 - only the gap
        ; needed the third byte.
        ldx     ETIER
        stz     T0
        lda     SHIP_OFF,x
        sta     T1
        ldy     #$00
        bpl     :+
:       bit     T1
        bpl     :+
        ldy     #$FF
:       sty     SHOFT
        ldy     #$00
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       sty     SHOFC
        sec
        lda     T0
        sbc     SHOFFL
        sta     T0
        lda     T1
        sbc     SHOFFH
        sta     T1
        lda     SHOFT
        sbc     SHOFC
        sta     SHOFT
        ldx     #SHOFF_LAG
:       lda     SHOFT
        cmp     #$80
        ror     SHOFT
        ror     T1
        ror     T0
        dex
        bne     :-
        clc                             ; the sum converges into range, so the
        lda     SHOFFL                  ;   top byte is not carried back
        adc     T0
        sta     SHOFFL
        lda     SHOFFH
        adc     T1
        sta     SHOFFH

        ; ---- and the zoom, on the same curve, because it is the same gesture --
        ; ...and the cross-axis lean, on the same shape of ease. TURNV is signed
        ; 8.8, so shifting it up 3 and taking a Q0.7 product lands the target in
        ; 8.8 full-res pixels directly.
        lda     TURNVL                  ; CLAMP FIRST. The shift below is 5, and
        sta     MAL                     ;   the speed coupling can push the turn
        lda     TURNVH                  ;   rate to 4.5 brad a frame - 1152 in
        sta     MAH                     ;   8.8, which shifted 5 is 36864 and no
        bpl     @cxpos                  ;   longer a positive signed 16. The lean
        lda     MAH                     ;   saturates at CAMX_CLAMP instead, which
        cmp     #>-CAMX_CLAMP           ;   is the right behaviour anyway: past
        bne     :+                      ;   three brad a frame it is already as
        lda     MAL                     ;   far over as it is ever going to lean.
        cmp     #<-CAMX_CLAMP
:       bcs     @cxok
        lda     #<-CAMX_CLAMP
        sta     MAL
        lda     #>-CAMX_CLAMP
        sta     MAH
        bra     @cxok
@cxpos: lda     MAH
        cmp     #>CAMX_CLAMP
        bne     :+
        lda     MAL
        cmp     #<CAMX_CLAMP
:       bcc     @cxok
        lda     #<CAMX_CLAMP
        sta     MAL
        lda     #>CAMX_CLAMP
        sta     MAH
@cxok:  asl     MAL
        rol     MAH
        asl     MAL
        rol     MAH
        asl     MAL
        rol     MAH
        asl     MAL
        rol     MAH
        asl     MAL
        rol     MAH
        ldx     ETIER                   ; the gain is per TIER, not a constant:
        lda     CAMX_TIER,x             ;   the effect is meant to read as the
        sta     MB                      ;   camera failing to keep up with a ship
        jsr     smul16q7                ;   that is MOVING, and at a standstill
                                        ;   a camera that swings on a pivot the
                                        ;   ship is sitting still on has nothing
                                        ;   to fail to keep up with. Zero there.
        sec
        lda     MAL
        sbc     SHOFXL
        sta     T0
        lda     MAH
        sbc     SHOFXH
        sta     T1
        ldx     #CAMX_LAG
:       lda     T1
        cmp     #$80
        ror     T1
        ror     T0
        dex
        bne     :-
        clc
        lda     SHOFXL
        adc     T0
        sta     SHOFXL
        lda     SHOFXH
        adc     T1
        sta     SHOFXH
        lda     SHOFXH                  ; the half-res cross centre the ship and
        cmp     #$80                    ;   its occluder box are drawn about
        ror     a
        clc
        adc     #HCY
        sta     SHCY
        lda     SHOFXH                  ; ...and the lean in ZOOM_MA's own scale,
        sta     T1                      ;   which is pixels * 16. SHOFX is 8.8
        lda     SHOFXL                  ;   px, so that is simply >> 4 - and it
        sta     T0                      ;   is folded into the value BEFORE
        ldx     #4                      ;   asr4r rounds, not added as a whole
:       lda     T1                      ;   pixel after it. Adding it after made
        cmp     #$80                    ;   the entire world step 1 px at a time
        ror     T1                      ;   as the lean decayed, and preview.py
        ror     T0                      ;   counted that as objects swimming.
        dex                             ;   Finding 15's rule, on a third axis:
        bne     :-                      ;   register sub-unit, floor once.
        lda     T0
        sta     SHOFXQ
        lda     T1
        sta     SHOFXQ+1

        ; The camera pulls back as the ship slides down: both exist so the player
        ; is looking at where they are going, so they must move together or the
        ; two halves of it read as two events.
        ldx     ETIER
        lda     ZOOM_RZ,x
        sta     T1
        stz     T0
        sec
        lda     T0
        sbc     ZEASL
        sta     T0
        lda     T1
        sbc     ZEASH
        sta     T1
        ldx     #SHOFF_LAG
:       lda     T1
        cmp     #$80
        ror     T1
        ror     T0
        dex
        bne     :-
        lda     T0                      ; finding 13's trap, and it bites harder
        ora     T1                      ;   here: an ease that never lands would
        bne     @zstep                  ;   leave the reciprocal creeping, and
        ldx     ETIER                   ;   every creep rebuilds a 512-byte table
        lda     ZOOM_RZ,x
        sta     ZEASH
        stz     ZEASL
        bra     @zdone
@zstep: clc
        lda     ZEASL
        adc     T0
        sta     ZEASL
        lda     ZEASH
        adc     T1
        sta     ZEASH
@zdone:
        ; QUANTISE. The ease is continuous, but everything downstream reads the
        ; SNAPPED reciprocal: nothing outside this line ever sees ZEASH.
        ldx     ZEASH
        lda     ZQ_SNAP-64,x
        sta     ZOOMH
        ; The cull window follows the zoom: pulling back widens the visible
        ; world, so a rock that was out of range comes into it.
        lda     ZOOMH
        lsr     a
        lsr     a
        lsr     a
        sec
        sbc     #$08                    ; RZ 64..128 -> 0..8
        tax
        lda     ZOOM_CULLH,x
        sta     CULHI
        txa
        asl     a
        tax
        lda     ZOOM_CULLR,x
        sta     CULRL
        asl     a
        sta     CUL2L
        lda     ZOOM_CULLR+1,x
        sta     CULRH
        rol     a
        sta     CUL2H
        inc     CUL2L                   ; 2*CULR + 1, the exclusive upper bound
        bne     :+
        inc     CUL2H
:
        ; The scale table, rebuilt only when the reciprocal's integer part moved.
        ; ~10k cycles, so it must not run on a frame where nothing changed - and
        ; must run BEFORE do_objects, which is the next thing the frame does.
        lda     ZOOMH
        cmp     ZSHEAD
        beq     :+                      ; (an anonymous label, not a cheap one:
        sta     ZSHEAD                  ;  BUILD_ROT's .local symbols end the
        BUILD_ROT ZSI, ZSF, ZOOMH, #$00 ;  @-scope this sits in)
:

        clc                             ; position += velocity, 16.8 + 16.8.
        lda     SHXF                    ;   The velocity carries its own top byte
        adc     VELXL                   ;   now, so the two sign extensions this
        sta     SHXF                    ;   used to build are gone and the add is
        lda     SHXL                    ;   a plain 24-bit one.
        adc     VELXH
        sta     SHXL
        lda     SHXH
        adc     VELXT
        sta     SHXH
        clc
        lda     SHYF
        adc     VELYL
        sta     SHYF
        lda     SHYL
        adc     VELYH
        sta     SHYL
        lda     SHYH
        adc     VELYT
        sta     SHYH

        lda     TPGO                    ; ...and only then, the teleport: it must
        beq     :+                      ;   land on THIS frame's position
        stz     TPGO
        jsr     do_teleport
:       rts

; -----------------------------------------------------------------------------
; do_teleport — jump a fixed screen distance and leave the camera behind.
; -----------------------------------------------------------------------------
; Move the ship in the world, drop SHOFF by the same screen distance, and the
; camera point does not move: the ship simply appears further up the screen and
; SHOFF_LAG walks the camera back, fast at first and slower as it closes.
;
; PSHOFF is dragged with it because do_stars folds (SHOFF - PSHOFF) into the
; scroll - that term exists so the field does not twitch while the offset eases
; between tiers - and a 246 px step there would sweep the whole field sideways.
;
; The rebase is NOT belt and braces. The star camera point is SHOFF scaled into
; LAYER units (shl6) and the motes' into their own (shl3), not world units, so
; the ship's world displacement and the SHOFF drop do not cancel analytically the
; way they do for the world objects. star_rebase_full recomputes every base from
; whatever the camera point now is, so the question never has to be answered -
; and if the field does jump one frame, you did just teleport.
; -----------------------------------------------------------------------------
do_teleport:
        inc     TPCNT
        lda     #<-TP_OFF               ; forward: land near the LEADING edge
        ldx     TIER
        cpx     #TIER_ZERO
        bcs     :+
        lda     #TP_OFF                 ; reversing: mirror it, and the jump
:       sta     TPDST                   ;   below comes out negative by itself

        ; M = SHOFF - landing, full-res px, positive meaning "forward along the
        ; heading". BOTH operands are sign-extended first, because the difference
        ; reaches 246 px and does not fit the byte either of them lives in. The
        ; first cut wrote `sbc TPDST / ldy #$00 / bpl` - and LDY sets the flags,
        ; so the branch tested the zero it had just loaded rather than the
        ; subtraction. The top byte came out $00 every time, which is right by
        ; luck going forward and turns the backward jump into a forward one.
        ldy     #$00
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       sty     TPMH
        ldy     #$00
        bit     TPDST
        bpl     :+
        ldy     #$FF
:       sty     TPSGN
        sec
        lda     SHOFFH
        sbc     TPDST
        sta     TPML
        lda     TPMH
        sbc     TPSGN
        sta     TPMH

        asl     TPML                    ; screen px -> world units at 1:1 is x16
        rol     TPMH
        asl     TPML
        rol     TPMH
        asl     TPML
        rol     TPMH
        asl     TPML
        rol     TPMH

        lda     TPML                    ; ...and x(128/RZ) on top, because the
        sta     MAL                     ;   distance is authored on the SCREEN:
        lda     TPMH                    ;   at 2x out the same screen span is
        sta     MAH                     ;   twice as much world. TPQ holds
        ldx     ZOOMH                   ;   128/RZ - 1 in Q0.7, so this is one
        lda     TPQ-64,x                ;   product and one add.
        sta     MB
        jsr     smul16q7
        clc
        lda     TPML
        adc     MAL
        sta     TPML
        lda     TPMH
        adc     MAH
        sta     TPMH

        lda     TPML                    ; SHX += M * sin
        sta     MAL
        lda     TPMH
        sta     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        ldy     #$00
        bit     MAH
        bpl     :+
        dey
:       clc
        lda     SHXL
        adc     MAL
        sta     SHXL
        lda     SHXH
        adc     MAH
        sta     SHXH

        lda     TPML                    ; SHY -= M * cos
        sta     MAL
        lda     TPMH
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        sec
        lda     SHYL
        sbc     MAL
        sta     SHYL
        lda     SHYH
        sbc     MAH
        sta     SHYH

        lda     TPDST                   ; the camera stays where it was...
        sta     SHOFFH
        stz     SHOFFL
        sta     PSHOFFH                 ; ...and the scroll must not see the step
        stz     PSHOFFL
        lda     HEAD                    ; force a full rebase of the star bases
        eor     #$80
        sta     BASEHEAD
        rts

; -----------------------------------------------------------------------------
; vel_shl — MA (signed 16) -> MA/MAT (signed 24), shifted by this tier's TIER_SHL.
; -----------------------------------------------------------------------------
; The ship's speed is authored in TIER_SPD as signed 8.8 world units a frame, and
; that type stops at 127.996 units - 482.5 px/s. A boost that only reaches 482
; against a normal top of 350 is a 37% difference and does not read as a boost at
; all, which is what flying it said.
;
; Rather than widen SPD - which would mean a 24-bit operand for smul16q7, twice a
; frame, and a three-byte TIER_SPD - the multiplier lives here, AFTER the
; direction product. TIER_SHL says how many times to double this tier's velocity,
; so an authored 350 with a shift of 1 flies at 700 px/s and the arithmetic that
; produced it never left 16 bits. The ceiling is 964 px/s at shift 1; the cull
; allows 1157 (the gap at RZ 64 is 320 units and a rock adds 13).
; -----------------------------------------------------------------------------
vel_shl:
        ldy     #$00                    ; sign-extend the product into 24 bits
        bit     MAH
        bpl     :+
        ldy     #$FF
:       sty     MAT
        ldx     ETIER
        lda     TIER_SHL,x
        beq     @done
        tax
:       asl     MAL
        rol     MAH
        rol     MAT
        dex
        bne     :-
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
        jsr     add_ship_occluder

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

; -----------------------------------------------------------------------------
; zoom_ma — MA (world units) *= the zoom reciprocal, in place.
; -----------------------------------------------------------------------------
; A subroutine and not the macro inline, for a reason worth knowing: RPROD ends
; with .local symbols, and a .local closes the enclosing cheap-local (@) scope.
; Expanded inside do_objects it silently orphaned that routine's own @cull and
; @lp. Macros that declare locals do not belong in a routine that uses @labels.
; -----------------------------------------------------------------------------
zoom_ma:
        RPROD   ZSI, ZSF, MAL, MAH
        lda     T0
        sta     MAL
        lda     T1
        sta     MAH
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
        ldx     ETIER                   ; ...times whatever vel_shl multiplied the
        lda     TIER_SHL,x              ;   ship by. The scroll is computed from
        beq     :++                     ;   SPD and the ship flies on VEL, so a
        tax                             ;   boosted tier would otherwise leave the
:       asl     T0                      ;   whole starfield behind.
        rol     T1
        dex
        bne     :-
:

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
        jsr     occ_bands               ; emit_asteroids has finished, so the
                                        ;   occluder list is complete and can be
                                        ;   indexed by band before a star reads it
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

        ldy     #$00                    ; fb_y = SHCY - view_x. SHCY, not HCY:
        lda     SHCY                    ;   the field must turn about the SHIP,
        sec                             ;   and the lean has moved the ship off
        sbc     BASEX,x                 ;   the cross-axis centre. See do_stars'
                                        ;   header.
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

        lda     FBY                     ; drop the star if any box covers it -
        lsr     a                       ;   but only the boxes registered in this
        lsr     a                       ;   star's row band can, so that is the
        lsr     a                       ;   whole list it has to walk
        lsr     a
        tay
        lda     OCCBN,y
        beq     @emit                   ; empty band: nothing parked, nothing walked
        sta     OCCBW
        stx     SIDX                    ; X becomes the walk cursor; the star
        lda     FBY                     ;   index parks until the walk is over
        and     #$F0                    ; band*16 IS the list offset
        tax
@occ:   ldy     OCCBL,x
        lda     FBX
        cmp     OCCX0,y
        bcc     @occn
        lda     OCCX1,y
        cmp     FBX
        bcc     @occn
        lda     FBY                     ; the band narrows y to 16 rows, it does
        cmp     OCCY0,y                 ;   not decide it - a box covers part of
        bcc     @occn                   ;   its first and last band, not all
        lda     OCCY1,y
        cmp     FBY
        bcc     @occn
        jsr     disc_hit                ; inside the box - inside the disc?
        bcs     @killed
@occn:  inx
        dec     OCCBW
        bne     @occ
        ldx     SIDX

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
        bra     @next
@killed:
        ldx     SIDX
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
; do_motes — the near layer: MOTE_N specks at TWICE the ship's speed.
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
; 1/4: sample = camera >> 4, so one layer unit is 16 world units where a half-res
; screen pixel is 32 - hence 2x. The camera offset is pre-multiplied by 8 rather
; than 64 for the same reason it is pre-multiplied at all: to come out as the
; ship's screen offset in layer units after the shift.
;
; 4x was tried and is too fast: at the top tier it moves them ~12 half-res pixels
; a frame, and specks that quick stop reading as depth and start reading as
; noise. 2x is ~6 a frame, which is the layer doing its job - saying "fast" when
; there is nothing else in view - without taking the eye off the rocks.
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

        ; fb_y = SHCY - (ROTC[dx] + ROTS[dy] + UX) - SHCY for the same reason
        ; the stars use it: the cross-axis lean moves the pivot.
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
        lda     SHCY
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
; The cross-axis lean eats into the OTHER margin. The field is drawn about SHCY,
; not HCY, so the band it has to cover is (L-75)..(74+L) where L is the lean in
; half-res pixels - at the design ceiling of 80 full-res that is |view_x| <= 115
; and the 53-pixel margin in x becomes 13. There is no refresh for that axis and
; none is needed: the lean only GROWS while the heading is turning, and a turning
; heading rebases every frame anyway. Once the stick is centred the lean decays,
; and a decaying lean only ever shrinks the band. The one frame in four that the
; slowest turn rate leaves the heading byte alone can move the lean by at most
; 1.25 half-res px, against 13 of margin.
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
        ;
        ; That is the ALONG axis. The cross axis cannot be done here - the lean
        ; decays while the heading is still, and a still heading does not rebase
        ; - so it is applied at draw time instead, as SHCY. Same effect, one
        ; pixel of granularity: see do_stars and the CAMX notes.
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

        ; LOD: below LOD_R this shape id may have an AUTHORED reduced outline -
        ; SHAPE_LODN nonzero - and if so the shape pointer swaps to it outright,
        ; rather than striding through the full outline (shapes.s explains why:
        ; an authored reduced shape reads as a rock at any vertex count, where
        ; every-second-vertex only ever worked on the two biggest classes).
        lda     ARAD
        cmp     #LOD_R
        bcs     :+
        ldy     ASHP
        lda     SHAPE_LODN,y
        beq     :+
        sta     AVN
        lda     SHAPE_LODLO,y
        sta     SHPL
        lda     SHAPE_LODHI,y
        sta     SHPH
:       lda     #$02                    ; AVSTEP: how far apart the vertices we
        sta     AVSTEP                  ;   use sit in the shape, in bytes - always
                                        ;   2 now, the shape itself is already the
                                        ;   right size

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

; -----------------------------------------------------------------------------
; emit_ship — an authored N-vertex outline, nose up, riding the speed tier up
; and down.
; -----------------------------------------------------------------------------
; SOLID, N full-res LINE16 segments. The rocks are dot-lines because a dotted
; rim is what reads as rock and there are a dozen of them; the ship is one
; object and wants to be the solid thing in the frame, which is also what it
; looked like as a sprite.
;
; FULL RESOLUTION, and the reason is motion, not sharpness. $42 takes half-res
; endpoints and doubles them, so a line that drifts or turns slowly lands on
; the same two even pixels for several frames and then jumps 2 px - which on
; the one object the player watches the whole time reads as the ship stepping
; rather than moving. $43 takes the endpoints on the 400x300 grid and draws
; them with the same renderer: identical still picture, four times the
; distinct positions in motion.
;
; No clipping is needed and none is available: the coordinates are computed
; from the centre, and nothing validates them. The ship is safe because it
; never leaves the middle of the screen and shapes.s's vertices are small.
;
; TATE: "up" on the player's screen is DECREASING fb_x. That is the same
; rotation sprgen bakes into the artwork with --tate; here it is just how the
; shape is authored - shapes.s's header says which axis is which.
; -----------------------------------------------------------------------------
emit_ship:
.if SHIP_SPRITE
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
.else
        ; The centre is 16-bit because it has to be: FBCX plus a SHOFF of 126
        ; plus a vertex is past 255 on its own.
        ldy     #$00                    ; cx = FBCX + SHOFF, signed 16
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFFH
        adc     #<FBCX
        sta     T0
        tya
        adc     #>FBCX
        sta     T1

        ldy     #$00                    ; cy = FBCY + SHOFX, the cross lean
        bit     SHOFXH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFXH
        adc     #<FBCY
        sta     T2
        tya
        adc     #>FBCY
        sta     T3

        ; Scale every authored vertex by ZEASH (not ZOOMH, same reason as a
        ; rock's SCALE: qmul is a plain product, nothing here gates a table
        ; rebuild, so the smooth ease costs nothing and the ship shrinks
        ; continuously instead of by rungs), place it relative to the centre
        ; just computed, and draw it - one vertex at a time, no array: SHIP_VN
        ; has no ceiling tied to a buffer size, the same as a rock's vertex
        ; count has none. Only SHIP_CURX/Y (the vertex just placed),
        ; SHIP_PVX/Y (the previous one, so its edge can be drawn) and
        ; SHIP_FVX/Y (the first one, so the LAST edge can close the loop back
        ; to it) are ever live - three vertices' worth of state regardless of
        ; how many are authored.
        ;
        ; ALL of that state lives in ZERO PAGE, on purpose, including the
        ; vertex counter (SHIP_VI) and the shape pointer, which advances
        ; itself two bytes a vertex instead of riding an index register. This
        ; used to trust X and Y to survive jsr sscale and jsr API_GPU_LINE16,
        ; via PHX/PHY/PLX/PLY - measured wrong in real madsim (not in the py65
        ; harness, which never caught it): every vertex came out with its sign
        ; discarded, exactly as if the register save had silently failed.
        ; Nothing here relies on that any more - a JSR's only contract is what
        ; it returns in A, never what it leaves in X or Y.
        lda     #<SHIP_SHAPE
        sta     SHPL
        lda     #>SHIP_SHAPE
        sta     SHPH
        stz     SHIP_VI                 ; vertices placed so far
@vlp:   ldy     #$00
        lda     (SHPL),y                ; dx
        jsr     sscale
        sta     SHIP_TMP
        lda     SHIP_TMP
        bmi     @xneg
        lda     #$00
        bra     @xext
@xneg:  lda     #$FF
@xext:  sta     SHIP_EXT
        clc
        lda     T0
        adc     SHIP_TMP
        sta     SHIP_CURX
        lda     T1
        adc     SHIP_EXT
        sta     SHIP_CURX+1

        ldy     #$01
        lda     (SHPL),y                ; dy
        jsr     sscale
        sta     SHIP_TMP
        lda     SHIP_TMP
        bmi     @yneg
        lda     #$00
        bra     @yext
@yneg:  lda     #$FF
@yext:  sta     SHIP_EXT
        clc
        lda     T2
        adc     SHIP_TMP
        sta     SHIP_CURY
        lda     T3
        adc     SHIP_EXT
        sta     SHIP_CURY+1

        lda     SHIP_VI
        bne     @drawedge
        ; the FIRST vertex: nothing to draw yet, just remember it twice - as
        ; the loop's start (FIRST, for the closing edge) and as the running
        ; PREVIOUS (for the next edge)
        lda     SHIP_CURX
        sta     SHIP_FVX
        sta     SHIP_PVX
        lda     SHIP_CURX+1
        sta     SHIP_FVX+1
        sta     SHIP_PVX+1
        lda     SHIP_CURY
        sta     SHIP_FVY
        sta     SHIP_PVY
        lda     SHIP_CURY+1
        sta     SHIP_FVY+1
        sta     SHIP_PVY+1
        bra     @next
@drawedge:
        lda     SHIP_PVX
        sta     OS_ARG+0
        lda     SHIP_PVX+1
        sta     OS_ARG+1
        lda     SHIP_PVY
        sta     OS_ARG+2
        lda     SHIP_PVY+1
        sta     OS_ARG+3
        lda     SHIP_CURX
        sta     OS_ARG+4
        lda     SHIP_CURX+1
        sta     OS_ARG+5
        lda     SHIP_CURY
        sta     OS_ARG+6
        lda     SHIP_CURY+1
        sta     OS_ARG+7
        jsr     API_GPU_LINE16
        lda     SHIP_CURX               ; PREVIOUS = this vertex, for the edge
        sta     SHIP_PVX                ;   that follows it
        lda     SHIP_CURX+1
        sta     SHIP_PVX+1
        lda     SHIP_CURY
        sta     SHIP_PVY
        lda     SHIP_CURY+1
        sta     SHIP_PVY+1
@next:  clc                             ; the shape pointer advances itself,
        lda     SHPL                    ;   two bytes to the next vertex
        adc     #$02
        sta     SHPL
        bcc     :+
        inc     SHPH
:       inc     SHIP_VI
        lda     SHIP_VI
        cmp     #SHIP_VN
        beq     @closeedge              ; the loop body is too long for a plain
        jmp     @vlp                    ;   branch to reach backward over
@closeedge:
        ; ...and the closing edge, the last vertex placed back to the first.
        lda     SHIP_PVX
        sta     OS_ARG+0
        lda     SHIP_PVX+1
        sta     OS_ARG+1
        lda     SHIP_PVY
        sta     OS_ARG+2
        lda     SHIP_PVY+1
        sta     OS_ARG+3
        lda     SHIP_FVX
        sta     OS_ARG+4
        lda     SHIP_FVX+1
        sta     OS_ARG+5
        lda     SHIP_FVY
        sta     OS_ARG+6
        lda     SHIP_FVY+1
        sta     OS_ARG+7
        jmp     API_GPU_LINE16          ; tail call: its own rts returns for us
.endif

; -----------------------------------------------------------------------------
; do_hud — patch the four RAM strings, then six VTEXT commands.
; -----------------------------------------------------------------------------
; VTEXT's grid is TEXT's transpose: X = character cell 0-36, Y = line 0-49, in
; the same order and directions as the horizontal opcode.
; -----------------------------------------------------------------------------
.if HUD_ON
do_hud:
        lda     ETIER                   ; speed: a canned 4-character field per
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
        lda     ZOOMH                   ; the zoom, as its raw reciprocal: 128 is
        jsr     put_dec3                ;   1:1 and 64 is twice as far out. The
        lda     DEC0                    ;   number to watch while re-tuning
        sta     STR_HDG+11              ;   ZOOM_RZ, so it is the number shown
        lda     DEC1
        sta     STR_HDG+12
        lda     DEC2
        sta     STR_HDG+13
        lda     OVRCNT                  ; ...and OVR: frames the OS said we did
        jsr     put_dec3                ;   not deliver. It must stay at 000. Any
        lda     DEC0                    ;   other number means the GPU blinked and
        sta     STR_HDG+18              ;   the scene needs thinning
        lda     DEC1
        sta     STR_HDG+19
        lda     DEC2
        sta     STR_HDG+20

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

.endif
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

.if SHIP_SPRITE
; --- the ship -----------------------------------------------------------------
; Generated from assets/png/ship32.png:
;     python tools/sprgen.py assets/png/ship32.png proto/02_rocks/ship32.s \
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
.endif

        .include "shapes.s"             ; every vertex table - rocks, ship. See
                                         ; that file's header and tools/shape_editor.py

; =============================================================================
; Asteroids
; =============================================================================
; FIVE SIZES at 192, 128, 64, 32 and 16 full-res pixels across, each with
; AST_TYPES hand-authored outline variants so a field of same-size rocks does
; not read as stamped from one mould. The outlines themselves, the per-shape
; radii and the authored reduced (LOD) outlines all live in shapes.s now - see
; its header - so the shape editor (tools/shape_editor.py) has one file to
; read and write. Only the two RANDOM PICKS that choose a rock's size and
; variant stay here, next to the rest of a rock's behaviour (AST_VEL/AST_SPIN
; below): they are population mix, not geometry.
;
; The vertex COUNT falls with the size - 12, 10, 8, 6, 5 - because a rock 16 px
; across cannot show more than about five corners anyway, and the small classes
; are the ones that multiply when rocks start breaking. Five is the floor: four
; reads as a diamond, which the eye recognises as a shape rather than as a rock.
; At ~530 cycles a vertex this is also the cheapest LOD knob in the file.

; The size mix, drawn with three bits of the LFSR: eight tickets over five
; classes, weighted away from the two biggest. Edit this to change how the field
; feels without touching any code.
SHAPE_PICK: .byte  0, 1, 2, 3, 4, 2, 3, 4

; Which authored variant of whatever size was just picked - independent of the
; above, same eight-ticket trick, evenly over AST_TYPES (shapes.s). Must have
; exactly AST_TYPES distinct values across its eight entries or a variant goes
; unused.
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

; Speed tiers, in world units per frame. 16 units = 1 full-res pixel and the
; frame is 60.317 Hz, so 16 units/frame = 60 px/s. The top tier crosses the
; 400-pixel screen height in about a second, which is the fastest that still
; leaves the player anywhere to look.
; Speed tiers, signed 8.8 world units per frame. A world unit is 1/16 of a
; full-res pixel and the frame is 60.317 Hz, so one unit per frame is 3.77 px/s
; and the tiers below come out as exact round numbers of pixels per second -
; which is the whole reason the speed is 8.8 and not a byte.
TIER_N      = 11                ; rows in TIER_SPD/SHOFF/ZOOM_RZ/CAMX_TIER the
                                ;   throttle can reach, 0..10 - it used to be
                                ;   the count the player picked from directly;
                                ;   now it is just how finely those tables are
                                ;   authored, and the throttle sweeps them
TIER_ZERO   = 3
TIER_BOOST  = 11                ; ...and the one only the boost can reach
BOOST_FRAMES = 90               ; 1.5 s at 60.317 Hz

; THRTL is a position in the same units as TIER*128 - see do_input - so
; THRTL_MAX has to land exactly on TIER_N-1's row or the top tier could never
; be reached exactly (THFRAC would never settle at 0). THRTL_ACCEL is a first
; cut (TBM): full range in THRTL_MAX/THRTL_ACCEL frames, ~1.3 s at 60.317 Hz -
; the number to retune once this is actually being flown.
THRTL_MAX   = (TIER_N-1)*128
THRTL_ACCEL = 16

; THE TELEPORT lands the ship on a FIXED screen point, and that one decision is
; what makes it cheap. The ship sits at FBCX + SHOFF, so a fixed landing point
; means a fixed SHOFF afterwards - and since SHOFF is a signed byte, the landing
; point only has to satisfy L >= 72 for the whole thing to fit the representation
; the cartridge already has. No 16-bit camera offset, and - because the ship
; never leaves the screen - no clipping of a ship whose LINE16 coordinates the
; GPU would not have validated.
;
; TP_OFF 120 lands it 80 px from the leading edge: 8 units of margin in the byte
; and 66 px of clearance for the nose at 1:1.
;
; The jump length falls out of the geometry rather than being authored: it is
; (SHOFF - landing), so +350 jumps 246 px and a standstill jumps 160. Faster
; means further, which is what you want from an escape move, and no code decides
; it. Reverse mirrors: the ship rides ABOVE centre backing up, so it lands low
; and the jump goes backwards along the heading.
TP_OFF      = 120               ; |SHOFF| the ship lands on, sign by direction
TIER_SPD:
        .word   $D836, $E579, $F2BD, $0000, $0D43, $1A87
        .word   $27CA, $350E, $4251, $4F94, $5CD8
        .word   $5CD8                   ; TIER_BOOST: 350 authored, doubled by
                                        ;   TIER_SHL to 700 px/s
;
; 480 and not 500, and the 4% is not a rounding preference. SPD is signed 8.8
; world units per frame; a unit is 1/16 px at 60.317 Hz, so one unit a frame is
; 3.7698 px/s and $7FFF - the largest value the type holds - is 482.5 px/s.
; 500 px/s is 132.6 units a frame, which is $8499: a NEGATIVE number in signed
; 8.8. Typing 500 into this table does not give a slower boost, it fires the ship
; backwards at ~490 px/s. Above 482.5 the speed has to become 16.8, which widens
; smul16q7 by one partial product - twice a frame, not once per object - and
; makes the position add cheaper, because a 16.8 velocity needs no sign extension
; into the 24-bit accumulator.
;
; The cull does not constrain this. The boost only starts from the top tier and
; does not touch the zoom, so RZ stays 64, where the gap between the coarse
; window and the precise cull is 256 units. Ship 127 + rock 13 = 140. 1.8x.
;               -150   -100    -50      0    +50   +100
;               +150   +200   +250   +300   +350        px/s
TIER_TXT:
        .byte   "-150", "-100", "-050", "+000", "+050", "+100"
        .byte   "+150", "+200", "+250", "+300", "+350"
        .byte   "BOST"                  ; TIER_BOOST reads ETIER, so the HUD says
                                        ;   so while it runs

; How far down the screen the ship sits at each tier, in full-res pixels.
; Forward pushes it down so the player sees further ahead; reverse lifts it for
; the same reason. SHOFF_LAG is the ease: the offset closes 1/(2^LAG) of the
; remaining gap each frame.
;
; At REST it is 40 px below centre, not on it - 20% of the screen's half-height.
; Dead centre gives the same amount of screen ahead and behind, and the thing
; ahead is the thing you are flying into.
;
; The forward end is squashed to fit, and the ceiling is not aesthetic: SHOFFH is
; the high byte of a SIGNED 8.8 offset and is read as a signed byte everywhere,
; so 127 is the wall. The first cut of this table ran to 140 and the offset wrapped
; to -127 mid-flight - the ship shot to the top of the screen and took the star
; camera point with it. Squashing costs little now that the ZOOM provides most of
; the look-ahead the slide used to.
SHOFF_LAG   = 4

; The camera leans INTO a turn, which slides the ship across the screen. Target
; cross-offset = turn velocity * CAMX_GAIN, eased with CAMX_LAG the same way the
; along-axis offset is eased. The turn velocity is 8.8 brad per frame and tops
; out near 3.0 - and is clamped to exactly that before the shift, so the speed
; coupling cannot push it past what the arithmetic holds. Shift 5 and the per-tier
; Q0.7 gain in CAMX_TIER put the target at +/-80 full-res px at full lean and top
; speed. The first cut was a quarter of that and read as almost nothing; the
; second was half; and all three leaned just as hard standing still, which is
; where it looked wrong - see CAMX_TIER. Flip the SIGN of CAMX_GAIN if it leans the
; wrong way - that is the only thing about it that is a guess.
;
; The pivot of the world rotation is the SHIP, not the screen centre (4.2), so
; moving the ship across the screen moves the pivot with it. CULL_R has always
; carried that term for the along axis - "200 half-height + 126 ship offset + 96
; rock radius" - and this adds the same term to the cross axis: 150 + 80 + 96 =
; 326 instead of 246, so the worst-case reach goes from 483 to 534 px. Both cull
; tables are regenerated from that number, and this is the real price of leaning
; harder: a 4.7% bigger CULL_R is 9.6% more area through the precise cull.
;
; The star and mote layers get it too, and the first cut of the lean did not -
; which was wrong and looked it. Those layers are drawn about a screen centre,
; and the ALONG axis is compensated by moving the sample point (the camera sits
; SHOFF ahead of the ship, so the ship's screen offset cancels and the pivot
; lands on the ship). Nothing did that for the cross axis, so the backdrop kept
; turning about the centre of the screen while the ship slid 80 px off it: the
; stars swept sideways past a ship that was supposed to be the still point, and
; the turn read as a strafe. Both layers now draw about SHCY, the ship's own
; half-res cross position, exactly as the ship's occluder box already did.
;
; It is a whole-pixel shift of the whole field, not a sub-unit-registered one -
; and that is consistent, not a shortcut: TRAVI moves the field in whole pixels
; along the other axis for the same reason. Only the OBJECTS need the sub-unit
; treatment (SHOFXQ, folded in before asr4r rounds), because they are drawn at
; full-res and each rounds independently. See findings 6, 12 and 15.
CAMX_CLAMP  = 768               ; ...and the turn velocity it saturates at, 8.8
                                ;   brad per frame, i.e. 3.0
CAMX_LAG    = 5                 ; the ease closes 1/(2^LAG) of the gap a frame
; How many times each tier's velocity is doubled after the direction product.
; Everything the player can select is authored at face value; only the boost is
; multiplied. See vel_shl for why the multiplier is here and not in TIER_SPD.
TIER_SHL:
        .byte   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        .byte   1                       ; TIER_BOOST: 350 -> 700 px/s

; How hard the camera leans into a turn, Q0.7, per tier. The lean exists to say
; "the camera is not keeping up with this ship", and that sentence has no meaning
; at a standstill: a pivot the ship is sitting still on has nothing to lag behind.
; So the gain tracks |speed|, zero at TIER_ZERO and 107 at either end of the
; range. Reverse leans too - the camera lags whichever way you are going.
;
; The boost is held at 107 rather than scaled to its 2x speed on purpose: the
; lean is what sets CULL_R's cross-axis term, and a harder one there would mean
; regenerating both cull tables for a case that lasts 90 frames.
;              -150 -100  -50    0  +50 +100 +150 +200 +250 +300 +350
CAMX_TIER:
        .byte    46,  31,  15,   0,  15,  31,  46,  61,  76,  92, 107
        .byte   107                     ; TIER_BOOST

SHIP_OFF:
        .byte   <-40, <-18, 12, 40, 56, 71, 85, 97, 108, 118, 126
        .byte   126                     ; TIER_BOOST: the top tier's, unchanged -
                                        ;   the boost must not move the ship. It
                                        ;   also COULD not: 127 is the ceiling on
                                        ;   a signed byte and 126 is where the top
                                        ;   tier already sits. See finding 28.

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

; =============================================================================
; Zoom
; =============================================================================
; The camera pulls BACK as the ship speeds up, and never pushes in past 1:1, so
; the scale is always <= 1. It is carried as its RECIPROCAL in Q0.7 - "how many
; screen pixels per reference pixel, times 128" - because that turns every use
; of it into a multiply and never a divide:
;
;   128 = 1:1, 64 = twice as far out, 43 would be three times
;
; Per tier, and eased toward it on the same curve as the ship's screen offset,
; because they are one gesture: the camera pulls back AND the ship slides down,
; both so the player is looking at where they are going (design_technical 4.4).
;
; Reverse and rest stay at 1:1 - going backwards you want to see what you are
; backing into, not a wider view of it. This is the whole zoom curve and it is
; meant to be flown and re-tuned; making the ramp start later, or making it a
; step, is an edit to this one line.
;              -150  -100   -50     0   +50  +100  +150  +200  +250  +300  +350
ZOOM_RZ:
        .byte   128,  128,  128,  128,  128,  123,  112,   99,   87,   76,   64
        .byte    64                     ; TIER_BOOST: the top tier's, unchanged
;              1:1                            ...                        2x out
;   rung k:      0     0     0     0     0     1     3     6     9    12    16
;
; Every value is a RUNG of ZQ_LADDER, and the shape is "start later, end harder".
; +50 stays at 1:1 - at fifty pixels a second a wider view buys nothing and costs
; a table rebuild. From +100 the steps grow 1, 2, 3, 3, 3, 4 rungs, so the world
; opens up fastest exactly where the look-ahead is worth most. The old curve was
; a first cut: it started widening at +50 and its steps were 6, 8, 9, 9, 10, 11
; reciprocal counts, which is nearly linear and put the biggest proportional
; change at the bottom of the range where it reads least.
;
; The whole ramp crosses 16 rungs, so a full acceleration rebuilds the ZS table
; at most 16 times. Un-quantised the same ramp crosses all 64 integer values of
; the reciprocal, at ~10,000 cycles each.

; -----------------------------------------------------------------------------
; ZQ_LADDER / ZQ_SNAP — the zoom is quantised, and the rungs are GEOMETRIC.
; -----------------------------------------------------------------------------
; Two reasons, and they are independent.
;
; CYCLES. The ZS scale table is rebuilt whenever the reciprocal's integer part
; moves - ~10,000 cycles - and the ease walks the reciprocal one count at a time,
; so the un-quantised ramp pays that on nearly every frame it is accelerating.
; Which is the same stretch of frames on which the zoom is multiplying the number
; of rocks in view. Snapping the eased value to 16 rungs an octave cuts that by
; 4x for a 4.4% step in scale, which is below what the eye picks up on a rock.
;
; SPRITES, and this is why the rungs are geometric rather than evenly spaced.
; On-screen radius is R_class * RZ/128. With the rungs at 128*2^(-k/16) and the
; size classes an octave apart, that becomes
;
;       r = R0 * 2^(-(c*S + k)/S)
;
; so the on-screen size depends on ONE integer, c*S + k. A rock at the bottom
; rung of its octave is pixel-identical to the next class down at the top rung:
; k=16 of class c IS k=0 of class c+1. A sprite atlas is therefore indexed by an
; ADDITION, not a table, and one sprite serves every (class, zoom) pair that
; lands on its index. The S=4 sub-ladder the sprites will actually use is every
; fourth rung - 128, 108, 91, 76, 64 - and it is exact, not approximate, because
; it is a subset of these same rungs.
;
; SHAPE_R's 48 breaks the octave spacing (48, 32, 16, 8, 4 - the first step is
; 1.5x). It does not matter: the 192 class is far too big to ever be a sprite,
; and 32/16/8/4 are octaves.
ZQ_LADDER:                              ; 128 * 2^(-k/16), k = 0..16
        .byte    64,  67,  70,  73,  76,  79,  83,  87,  91
        .byte    95,  99, 103, 108, 112, 117, 123, 128

; ...and the nearest rung for every reciprocal the ease can produce, indexed by
; the eased value: ZQ_SNAP-64,x with x = ZEASH. One table read a frame.
; TPQ - (128/RZ) - 1 in Q0.7, indexed by the snapped reciprocal. The teleport
; distance is authored on the SCREEN, so it has to be divided by the zoom to get
; world units; this turns that divide into one multiply and one add.
TPQ:
        .byte   127, 124, 120, 117, 113, 109, 106, 103, 100,  96,  93,  90,  88
        .byte    85,  82,  79,  77,  74,  72,  69,  67,  65,  63,  60,  58,  56
        .byte    54,  52,  50,  48,  46,  44,  43,  41,  39,  37,  36,  34,  33
        .byte    31,  30,  28,  27,  25,  24,  22,  21,  20,  18,  17,  16,  14
        .byte    13,  12,  11,  10,   9,   7,   6,   5,   4,   3,   2,   1,   0

ZQ_SNAP:
        .byte    64,  64,  67,  67,  67,  70,  70,  70,  73,  73,  73,  76,  76
        .byte    76,  79,  79,  79,  79,  83,  83,  83,  83,  87,  87,  87,  87
        .byte    91,  91,  91,  91,  95,  95,  95,  95,  99,  99,  99,  99, 103
        .byte   103, 103, 103, 108, 108, 108, 108, 108, 112, 112, 112, 112, 117
        .byte   117, 117, 117, 117, 117, 123, 123, 123, 123, 123, 128, 128, 128

; What the cull has to admit, per zoom step: CULL_R scales as 128/RZ, because
; pulling the camera back makes the visible window that much wider in world
; units. Indexed by (RZ >> 3) - 8, so RZ 64..128 is nine entries. Rounded UP, and
; the high-byte window with it: the freeze-far-rocks ordering in do_objects needs
; CULL_HI * 256 to stay at least 128 units clear of CULL_R, or a rock could cross
; both tests inside one frame.
;              RZ 64   72     80     88     96    104    112    120    128
ZOOM_CULLR:
        .word   17088, 15190, 13671, 12428, 11392, 10516,  9765,  9114,  8544
ZOOM_CULLH:
        .byte      68,    61,    55,    50,    46,    43,    40,    37,    35
;
; Regenerated when the camera gained its cross-axis lean. The pivot of the world
; rotation is the SHIP, so moving the ship across the screen moves the pivot: the
; cross-axis reach goes from 150 + 96 = 246 to 150 + 20 + 96 = 266, and the
; worst-case vector from sqrt(422^2 + 246^2) = 483 px to sqrt(422^2 + 266^2) =
; 499. At 483 the big rocks popped in and out at the edges - see finding 18 -
; and the cross axis would have started doing the same thing on hard turns.
;
; The high-byte windows are now +2 rather than the minimum +1, so the smallest
; clearance is 281 units instead of 128. That costs a coarse window 3% wider -
; about half a rock more through the cheap test at 1:1 - and buys two things:
; the freeze-far-rocks ordering keeps its margin at every zoom step, and the
; BOOST's 127 units a frame plus a rock's 13 stays well inside it everywhere,
; not just at the top tier where the boost happens to live today.

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
TPL_HDG:    .byte   "HDG $00 RZ 000 OVR000", 0, 0, 0
TPL_STA:    .byte   "STARS 000/088 M00 A00", 0, 0, 0
TPL_SCL:    .byte   "TSCALE OFF", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_SCL2:   .byte   "TSCALE 0 MAX x1.00", 0, 0, 0, 0, 0, 0

TXT_H1:     .byte   "J1 TURN/SPEED  J2UP BOOST", 0
TXT_H2:     .byte   "FIRE RATE  J2 L/R RAMP", 0
