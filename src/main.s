; =============================================================================
; Escape from Saturn — the frame
; =============================================================================
; THE GAME LIVES HERE. This file holds the two entry points the console calls —
; cart_init once at boot and cart_frame once a frame — and the state they run
; on: every tunable, every zero-page location and the whole RAM map. Everything
; those two call lives in the modules included at the bottom, and the manifest
; there says what each one is for.
;
; The code came from proto/03_radar, promoted whole once the benches had
; answered what they were built to answer. proto/ is frozen and nothing in the
; build reads it; if you are changing behaviour, you are changing src/.
;
; TATE: turn the monitor 90 deg CLOCKWISE (madsim: --tate, or F12).
;
; WHAT IS ON SCREEN
;   * a starfield: 110 stars in their own 256x256 wrapping layer, drawn as
;     half-res DOT_PIXELS. They are NOT world objects, have no world coordinates
;     and do not scale with the zoom. They move at 1/8 of the ship's speed and
;     they ROTATE with the camera — parallax applies to translation only, so a
;     layer that slid but did not turn would tear away from the world on every
;     turn. A nearer layer of MOTE_N specks runs at twice ship speed.
;   * the ship: an authored 14-vertex outline, always nose-up, riding up and
;     down the screen with the throttle. The 32x32 sprite it used to be is still
;     in the build behind SHIP_SPRITE, and design_technical 11.14 says why the
;     outline won.
;   * NOBJ asteroids with real world positions, velocities and spins, drawn as
;     SOLID FULL-RES outlines ($4E POLYGON16) at one of five sizes: 192, 128,
;     64, 32 and 16 full-res pixels across. They collide with each other; see
;     physics.s.
;   * the RADAR, hard into the bottom-left corner of the portrait screen: every
;     enemy within 25,600 world units, and every rock of the two largest size
;     classes that still exist, one point each, on a scale that does not move
;     with the zoom. Enemies blink. Its ring and ship icon are a BACKGROUND
;     BITMAP uploaded at start-up (the background takes whole bytes only, never
;     lines), and the starfield is suppressed inside its disc so a contact does
;     not read as one more star. See radar.s.
;
; WHAT IS STILL A KNOB RATHER THAN A DECISION
;   * HUD_ON — the text readout. OFF, and it assembles to nothing while it is;
;     turn it on to read the counters. See the note on it below.
;   * ROCK_FAMILY — which opcode draws a rock. A measurement control.
;   * the speed table and the camera's lag constants: open_questions B1 and B3
;     are open and are settled by flying them, not by argument.
;   * the reduced outlines left unused in shapes.s (design_technical 11.9).
;   * heading is a full 8-bit brad angle with a fraction, not the 32 directions
;     the design assumes (open_questions B5). With the ship always drawn
;     nose-up, the only place the difference can show is the smoothness of the
;     world's rotation.
;
; CONTROLS
;   joystick 1  LEFT / RIGHT   turn (held)
;               UP / DOWN      throttle (held) — a continuous position over the
;                              speed table, not a step between tiers
;   joystick 2  UP             boost, from the top tier only
;               DOWN           teleport along the heading
;
; COORDINATE SYSTEMS — the one thing worth reading before editing
;   world        16-bit per axis, unit = 1/16 full-res pixel. Wraps by 16-bit
;                overflow: there is no wrap code anywhere in this program, and a
;                16-bit subtract read as signed IS the shortest distance across
;                the seam. Do not "fix" that by adding a boundary test.
;   view         the player's portrait screen, +x right, +y down, origin centre.
;   framebuffer  what the hardware draws. TATE clockwise means
;                  fb_x = portrait_y   and   fb_y = 299 - portrait_x
;                so the full-res centre is fb (200, 149) and the half-res centre
;                is fb (100, 74).
;
;   asteroid     a vertex list in half-res pixels, signed bytes, origin-centred.
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
STAR_N      = 66                ; stars in the layer; ~46% are on screen at once.
                                ;   Was 88, thinned by a quarter: the field is
                                ;   backdrop, and the radar now owns a corner of
                                ;   the screen that used to be sky
MOTE_N      = 10                ; motes: a second layer much CLOSER than the
                                ;   action, so they streak past at twice the
                                ;   ship's speed. ~5 on screen at a time - they
                                ;   are there to sell speed when nothing else is
                                ;   in view, not to be looked at.
NOBJ        = 120               ; asteroid SLOTS. How many rocks a level puts
                                ;   in them is the level's own business (see
                                ;   levels.s); this is the ceiling the arrays
                                ;   are cut to, and a budget number rather than
                                ;   a world one. The world is about 140 screens,
                                ;   so 120 is a bit over one rock per screen by
                                ;   centre - and because they are up to 192 px
                                ;   across, that comes out as 3 to 6 actually on
                                ;   camera. It was 250 while these were dots;
                                ;   every one of them costs the position
                                ;   integrate and the coarse reject whether or
                                ;   not it is anywhere near, which is the single
                                ;   largest item in the frame - see the budget
                                ;   note in README.md.
START_LEVEL = 0                 ; which of levels.s's levels cart_init loads.
                                ;   One level exists; the campaign is five
                                ;   (design_technical 9), and picking between
                                ;   them is the menu's job, not a constant's.
; The HUD is SEVEN VTEXT commands and ~9,900 CPU cycles a frame (finding 18) on
; the IMAGE layer, which is not where the real game will put it - text is
; destructive, so it belongs on the background where the hardware re-copies it
; for nothing (5.5).
;
; It is OFF, and nothing on screen needs it: the radar suppresses the starfield
; inside its own disc (add_radar_occluder), so it reads as a dark hole with
; contacts in it rather than as a patch of sky that happens to have extra
; stars. Turn it on to read the counters while flying a tuning question - the
; STARS line carries the contact count in its R field - and expect to pay for
; it: 83.9% of CPU1's worst frame against 78.5%, and a derived outline budget
; of 78 vertices against 104. With it off, hud.s assembles to nothing at all.
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
; The ship is a VECTOR OUTLINE, not the sprite. Set SHIP_SPRITE = 1 to put
; ship32.png back: the asset, the converter and the whole upload path are
; still here, just assembled out. The outline is here to be measured against a
; sprite once zoom exists - it scales for nothing, where a sprite would need a
; pre-scaled frame per zoom step, and the ship is the one object in the game
; that never rotates so the usual argument for sprites does not apply to it.
; Settled that it never will (design_technical.md 11.9): sprites are for
; thruster flames and shots, not for the ship or for rocks.
SHIP_SPRITE = 0

; The outline itself - SHIP_SHAPE, up to 13 signed byte (dx,dy) vertices, and
; SHIP_VN, how many of them are used - lives in shapes.s next to the rock
; outlines, so the shape editor has one file for every drawable shape. It was
; a fixed triangle (SHIP_NOSE/TAIL/HALFW), then an authored N-gon still drawn
; as CPU1-transformed LINE16 segments (one sscale per axis per vertex). Now
; that it is 14 vertices rather than 3, that transform was the one outline
; left costing CPU1 instead of the GPU (design_technical.md 11.14), so
; emit_ship builds the same argument block a rock does and lets the GPU
; rotate (by 0 - the ship never spins), scale and draw it instead.

SPR_SHIP    = 1                 ; the slot the ship art is installed into. Slot 0
                                ;   is left as the ROM test sprite so that a
                                ;   forgotten id draws something recognisable
SHIP_PAGE   = $10               ; ...and the GPU RAM page its 256 bytes land on
; LOD_R and the per-rock switch to an authored reduced outline (SHAPE_LODN,
; shapes.s) are retired (design_technical.md 11.9): rocks draw at full
; authored detail at every on-screen size now. The GPU is the resource that
; vertex count was ever a budget against (AST_BUDGET/AST_VCOST below), and
; every bench that measured it found headroom there while CPU1 was the tighter
; side. The authored reduced shapes are left in shapes.s, unused rather than
; deleted, in case that balance moves back the other way.
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
; and the failure was invisible on screen: see proto 01 finding 49. The opcodes
; rasterise different amounts, the HUD is ~48,700 GPU cycles when it is on, and a
; constant tuned for one combination silently drops rocks in another. Writing the
; arithmetic out means changing ROCK_FAMILY or HUD_ON re-derives both valves.
;
;   AST_VCOST    GPU cycles a vertex, measured over a 200-frame flight, worst
;   AST_NONROCK  what the GPU's worst frame costs WITHOUT any rocks in it
;   209,000      of the 237,404 available - the same 88% discipline the original
;                budget kept on CPU1, leaving margin for a frame busier than
;                any that has been flown
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
PRNGL       = $BF               ; the cartridge's own LFSR state
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
LVLIX       = $0CB7             ; load_level's own state, nearly all of it dead
NROCK       = $0CB8             ;   once the field is built: the level that was
SCATN       = $0CB9             ;   loaded, how many rocks it came to, the five
SCATC       = $0CBE             ;   per-class scatter countdowns, the class (and
SLOT        = $0CBF             ;   then the placed-record) counter, the object
LVREC       = $0CC0             ;   slot being filled, one staged six-byte
LVTMP       = $0CC6             ;   record, and a scratch byte. NROCK is the one
                                ;   that outlives init - see init_cells.
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
; $6800-$6FFF belongs to radar.s - six DOT_PIXELS pages, its own scalars and
; the enemy table - and $F0/$F1 to its one zero-page pointer. Declared there,
; beside the code that reads them, exactly as physics.s declares its own. It
; sits that high because RAM from $2000 up is where cart.cfg RUNS the program.
OBJANG      = $6000             ; NOBJ bytes: its spin angle, brad (integer part)
OBJANGF     = $6100             ; ...and the fraction, so a spin can be far slower
                                ;   than one brad a frame
PBUF        = $6280             ; the POLYGON argument block: 7 header bytes and
                                ;   then 2*AVN of shape - 31 at the largest
                                ;   rock, 35 for the ship's 14 vertices - and
                                ;   emit_ship's block too now, the two never
                                ;   being live at once. $6200-$627F and
                                ;   $62A0-$62BF used to hold the transformed
                                ;   outline and its outcodes, and then
                                ;   emit_ship's own per-vertex scratch; the GPU
                                ;   owns the whole ship outline now too, so
                                ;   those bytes came back as well.
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
        sta     TURNIX                  ;   default; see design_technical.md 11.15
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

                                        ; (the ship's world position and its
                                        ;  heading are not set here any more:
                                        ;  they are level data, and load_level
                                        ;  below writes them)
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
        ldx     #START_LEVEL            ; ...and the field, the ship's place in
        jsr     load_level              ;   it and the sector grid, all out of
        jsr     radar_census            ;   levels.s. The radar's per-class rock
                                        ;   count is taken here, once, off the
                                        ;   field load_level just built - see
                                        ;   radar_sens
        jsr     load_foes               ;   ...and then the enemies - AFTER
                                        ;   load_level, because it falls through
                                        ;   into init_cells and nothing may come
                                        ;   between the two (see load_level)
.if HUD_ON
        jmp     init_strings            ; ...and the HUD's RAM copies last, since
.else                                   ;   it is the only thing that patches a
        rts                             ;   string in place
.endif


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
        lda     FLSTEP                  ; same shape, for the flames - see
        cmp     #$05                    ;   upload_flames_step. Unconditional:
        bcs     :+                      ;   the ship is a vector outline, but
        jsr     upload_flames_step      ;   its flames are sprites regardless.
:
        lda     BGDONE                  ; one-shot: wipe the boot screen off the
        bne     :+                      ;   background. The OS replays background
        jsr     API_GPU_CLEARBG         ;   commands on the next frame for us, so
        lda     #$01                    ;   issuing this once is the whole job.
        sta     BGDONE
        jsr     ring_restart            ; ...and the radar's ring goes on top of
                                        ;   the cleared background, one
                                        ;   RECT_BG_RLE command - see radar.s
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
        jsr     ring_restart            ; the clear takes the radar's ring with
                                        ;   it, so paint it again rather than
                                        ;   leave a hole for the session
:
        jsr     ring_frame              ; the radar's furniture, one
                                        ;   RECT_BG_RLE command, retried until
                                        ;   it lands. FIRST in the frame for the
                                        ;   same reason upload_step is: dropped
                                        ;   for want of PPRAM leaves a permanent
                                        ;   hole, not a one-frame blink
        jsr     do_input
        jsr     do_camera               ; cos/sin, then the two rotation tables
        jsr     do_ship                 ; velocity from tier + heading, integrate
        jsr     do_objects              ; move and spin the rocks, transform them
        jsr     emit_asteroids          ; ...which also registers their occluder
                                        ;   discs, which do_stars needs: it is the
                                        ;   one pass that has to run after them
        jsr     do_stars
        jsr     do_motes
        jsr     emit_ship
        jsr     do_flames                ; the side thruster flames, riding the
                                        ; screen centre emit_ship just placed
        jsr     do_radar                ; the contact lists - built BEFORE the HUD
                                        ;   because the HUD reads the count, and
                                        ;   emitted AFTER it because the list
                                        ;   order is the priority order
.if HUD_ON
        jsr     do_hud
.endif
        ; The radar goes in ahead of the backdrop and behind everything else.
        ; It is information, not decoration: if the GPU runs out of frame, a
        ; missing contact is a worse loss than a missing star, and a better one
        ; than a missing rock. See open_questions G7 for the priority INSIDE it,
        ; which is CPU1's own business - the GPU can only drop whole commands.
        jsr     emit_radar

        ; The two decorative layers are appended LAST, and in this order: if the
        ; GPU ever runs out of frame to finish the list, what it drops should be
        ; the backdrop, not the ship or the HUD. Stars second to last, motes
        ; last, because motes are the cheapest thing on screen to lose.
        jsr     emit_stars
        jmp     emit_motes

; =============================================================================
; The rest of the frame
; =============================================================================
; Everything above is the two entry points and the state they run on; every
; routine they call lives in one of these. They are .include, not separate
; translation units, for the reason they always were: one assembly sees every
; equate above without an import list, and the linker never has to resolve a
; cross-module reference. Reading order, which is also roughly the order a
; frame uses them:

        .include "math.s"               ; the quarter-square multiply, the LFSR,
                                        ; and the shifts every transform is
                                        ; built out of. Nothing here knows what
                                        ; a rock or a star is.
        .include "input.s"              ; joystick -> heading, throttle, boost,
                                        ; teleport. The only file that reads a
                                        ; joystick.
        .include "camera.s"             ; the heading's cos/sin, the two rotation
                                        ; tables built from them, and the world
                                        ; -> view transform every object goes
                                        ; through.
        .include "ship.s"               ; the ship's own motion - velocity,
                                        ; integration, the screen slide and the
                                        ; zoom that ride the throttle - and the
                                        ; outline that draws it.
        .include "thrust.s"             ; the four side thruster flames -
                                        ; sprites riding the vector ship. See
                                        ; that file's header.
        .include "objects.s"            ; the field: the level's opening state,
                                        ; the sector grid, the per-frame walk
                                        ; that culls, moves and transforms it,
                                        ; and the outlines it emits.
        .include "physics.s"            ; rock against rock: the sector-grid pair
                                        ; walk, the circle test and the impulse.
                                        ; See that file's header.
        .include "stars.s"              ; the two parallax layers - the 256x256
                                        ; star field and the near motes - which
                                        ; are sampled, not simulated (5.3).
        .include "occlude.s"            ; what the star layers are NOT drawn
                                        ; behind: the ship's box and every
                                        ; rock's disc (5.4).
        .include "hud.s"                ; the text readout. Assembles to nothing
                                        ; while HUD_ON = 0 - see the note on it.

        ; ...and the radar lands in the SECOND bank's code segment, because
        ; with the HUD switched on it is what took bank 0 past 8 KB. Nothing
        ; about it is special - CODE and CODE2 run contiguously in RAM and
        ; every reference between them resolves after the copy - it is simply
        ; where the room is. See cart.cfg and bootstrap.s.
        .segment "CODE2"
        .include "radar.s"              ; the HUD radar: a second, wider walk of
                                        ; the same sector grid, on high bytes
                                        ; only. See that file's header.

; =============================================================================
; Data
; =============================================================================
; The authored files, and THE FLIGHT MODEL'S OWN TABLES - the speed tiers, the
; screen offset, the zoom ladder, the turn rates and the two ramps.
;
; A table generally belongs beside the code that reads it, and the ones that do
; have gone there: how a rock drifts and spins is in objects.s, the HUD's canned
; strings are in hud.s, the ship's sprite pages are in ship.s. These stayed on
; purpose. They are not five tables, they are ONE argument about how the ship
; flies - each is indexed by the same swept throttle position, and changing a
; row of one without looking at the others is how you get a camera that lurches
; or a boost that fires backwards. open_questions B1 and B3 are still open
; against exactly these numbers, so they are kept on one page to be read and
; retuned together.
; =============================================================================
        .segment "RODATA"

        .include "shapes.s"             ; every vertex table - rocks, ship. See
                                         ; that file's header and tools/shape_editor.py
        .include "levels.s"             ; ...and every level's opening state. See
                                         ; that file's header and tools/level_editor.py
        .include "radar_bg.s"           ; the radar's ring and ship icon as a
                                        ; background bitmap - GENERATED from
                                        ; assets/png/radar100.png by
                                        ; tools/bggen.py. See radar.s.

; The ceiling on the array itself. That every level FITS in it is asserted from
; levels.s, per level, off sums the assembler makes out of that file's own
; constants - so a count edited there by hand is checked too.
        .assert NOBJ <= 128, error, "OBJSHP and OBJTYPE are only 128 bytes apart"

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



