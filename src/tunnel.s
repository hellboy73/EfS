; =============================================================================
; tunnel.s - the tunnel between sectors: an invisible tube, flown in 3D
; =============================================================================
; design_technical.md 11.45 and open_questions.md H6 say what it is; this file is
; the third tenant of DEMO_RAM (overlay.s: FIELD, SCREEN, TUNNEL), TUNCODE in ROM
; bank 10, run in TUNRAM ($C000). It is entered from gate.s (gate_arrive sets
; SC_TUNNEL when the ship flies into the exit), loaded by frame_body on the next
; frame, and left through set_state_field - the next sector - like
; sector_frame is.
;
; MEMORY RULES (open_questions.md H1, the tunnel memory audit): this code may
; write only its own segments, KEEP from $DF8D, the stack, and the zero page it
; saves and restores. In $6000-$97FF, the state a sector carries (SCORE, LIVES,
; CURLEV, SATN, LSRHAVE, EMPHAVE...), it writes ONLY what it gives back on purpose
; (tunnel_hud.s): SHIPHP (the hull grows), LIVES (a pod caught), SCORE, SATN (once,
; at the end) - and the sector HUD's own buffers and caches, through hud_game.s's
; code, which it calls. Its variables
; are TUNBSS (below), absolute - it borrows no zero page at all so far.
;
; STATE so far - the stars and the HUD. SCR_PH is the step:
;   0 dark: the background cleared, the screen blinded, the stars born
;   1 settle: the clear's replay lands
;   2 the cockpit's rectangle is armed
;   3 its bands go out, a batch every other frame (art_step, screens.s's macro)
;   4 their replay lands, and the blinder comes off on a finished cockpit
;   5 flying
; SC_PTRL/SC_PTRH count the frames flown (the marquee's pointer, unused outside
; the title).
;
; THE COCKPIT is tunnel_hud.png, 300 x 300, on the BACKGROUND layer at portrait
; (0,50) - centred on the 300 x 400 screen (the Makefile's tunnel_art.s rule). It
; is thin white lines, so the flight, drawn on the layer above it, simply overdraws
; where they cross: nothing here "covers" the flight yet.
;
; The picture its bands write is the WHOLE 300 x 400 screen, not just the window
; (the Makefile composes it: a blank canvas, the cockpit, and the ship's picture where
; the sector's radar stands). That is on purpose: CLEAR_BG has to reach BOTH background
; buffers, and when one pass is starved the sector bleeds through - the radar corner and
; the message bar's top band were what showed. Bands that rewrite every byte leave
; nothing of the sector whatever CLEAR_BG managed, and the ship, being background,
; costs no frame a cycle (the user, 2026-10-14: too big to draw every frame; effects
; round it will be small sprites).
; =============================================================================

TUN_FRAMES  = 3600              ; a minute of flying (design_technical 11.45), the last TUN_RUSH of
                                ;   it the rush, then the next sector

; --- THE STARS (design: the user, 2026-10-12/13) ------------------------------
; A point (x, y, z), projected as o = rel * F / z about the window's centre, where
; rel = x - cam is a SIGNED BYTE: the field is the whole 256 x 256 torus round the
; ship, so the 8-bit wrap does the work and the stars are EVERYWHERE, however far
; the camera has leaned - there is no tube edge to see past (the first version had
; one, and the space outside it was empty). z falls by TUN_SPEED a frame, so a star
; streams outward and leaves through the window's edge (or gets to ZMIN) and is
; born again far away, at a random place IN VIEW: with F = 150 a rel of +-127 at
; ZMAX = 255 lands on the window's edge, so every depth fills the whole window.
; Each is ONE PIXEL whatever its depth - the field's rule (37) - drawn by one
; DOT_PIXELS. A square hole of TUN_HOLE (in rel) is kept empty at birth: nothing
; is born on the line of flight, which is what makes it a tunnel and not a pin.
; WITH THE ROLL the torus is gone: a star's place is signed 16
; (SX/SXH, SY/SYH), born in a DISC of radius TUN_DUSTR round the view's centre, turned
; into the world (R(-TH)) - wider than the tube (the user, 2026-10-13: dust outside it
; too, the same count, the density may fall). At ZMAX the window's edge is a rel of 255
; (z is in units of 2), so the disc is not the whole window there: the dust spreads out
; to it as it comes in. A star whose |rel| is past its depth is outside the window.
TUN_STARS   = 24                ; TBM: the GPU is the tight side (11.49). 24 since the roll (the user,
                                ;   2026-10-13: 32 cost too much CPU once turned); it was 32, half
                                ;   of the first 64 (the user, 2026-10-13: not more, rather fewer)
TUN_F       = 150               ; the focal length: o = rel * F / z
TUN_ZMIN    = 6                 ; a star nearer than this is gone
TUN_ZMAX    = 255                   ; A STAR'S DEPTH IS IN UNITS OF 2 (a rock's is true z): so
                                ;   it is born 510 away, twice as far as it was, and
                                ;   its offset is rel * F / (2 z) - tun_projwin halves it
TUN_SPEED   = 2                 ; a star's z a frame (units of 2), and one more on every odd
                                ;   frame: 2.5 on average = 5 true z, which is a rock's speed
                                ;   (SPD2). 2x the 2.5 it was (the user, 2026-10-13)
TUN_HOLE    = 24                ; the empty square round the axis, at birth
TUN_DUSTR   = 190               ; the disc a star is born in (rel): 1.5 x the 127 it was

; --- THE HIT (design: the user, 2026-10-13) --------------------------------------
; A rock that reaches the ship (TUN_HITR) KNOCKS it: the lean's velocity gets a kick
; away from the rock (TUN_KICK units a frame, the spring then brings it back), the view
; SHAKES (SHK frames, the jitter fading as it counts down), the pad rumbles, and the
; sound is the sector's own ram (SE_KLANG and SE_KLANG_N, sfx.s). The ROCK stops
; coming - its depth is frozen where it hit - and is thrown sideways, away from the
; ship, at TUN_DEFL world units a frame, spinning faster, until it leaves the window.
TUN_KICK    = 3                 ; the lean velocity added, units a frame (8.8 high byte)
TUN_DEFL    = 3                 ; the rock's sideways speed, world units a frame
TUN_SHAKE   = 24                ; frames of shake: the jitter is SHK / 4 units, so 6..0
TUN_RUMBLE  = 20                ; frames of pad rumble

; --- THE SATURNIUM CLOUDS (design: the user, 2026-10-13) --------------------------------
; Something to catch. A cloud is a thing like a rock - a place in the tube, a depth, the
; same perspective, the same size (its radius is a rock's, 48 half-res px at 1:1) - but it
; is drawn as DOT_PIXELS: TUN_CLOUDMIN pixels when far, growing to TUN_CLOUDMAX when it is
; at the camera, scattered through a disc by a fixed pattern (CLDP) that drifts along
; so it shimmers. It hides nothing, and a rock in front of it hides its pixels. Reaching
; the ship within TUN_CATCHR CATCHES it: the sector's own Saturnium sound (SE_SATN), the
; cloud gone, TUN_SATCLD (tunnel_hud.s) added to the hold the tunnel keeps (TSATN), which is
; written back to SATN when the scene ends; TSAT counts the catches. One spawn in TUN_CLOUDP
; is a cloud.
TUN_CLOUDMIN = 8                ; pixels at the farthest
TUN_CLOUDMAX = 32               ; ...and at the camera (scale 128: the formula is 8 + 3/16 s)
TUN_CATCHR  = 36                ; a catch: |rel x| and |rel y| both under this (a rock's is 15;
                                ;   it was 22, made easier - the user, 2026-10-13: a pod's is 36
                                ;   too, and more would reach a cloud from the next lane, 81 off)
TUN_CLOUDP  = 7                 ; a spawn is a cloud when (random AND this) = 0: 1 in 8

; --- THE ENGINE (design: the user, 2026-10-13) --------------------------------------
; A low RUMBLE on the effects chip's NOISE voice: white noise at its slowest rate (mode 6),
; loud enough to hear over the flight (the boost's hiss, which is the game's own quiet
; noise bed, peaks at 6; this one starts at TUN_HUMV = 3 and swells to 5). A four-step program of four
; frames, RE-FIRED every TUN_HUMP frames from RAM that is always mapped (the OS reads it
; from the frame IRQ), its steps computed ahead from the rush's clock. In the rush the
; noise rate steps up (modes 6, 5, 4) and it swells. It is never re-fired over a ram's
; crunch (sfx.s's claim on the noise voice, VLEN+3), which, fired through sfx_fire,
; simply replaces it.
; NOT YET SMOOTH: the three rates are an octave apart. An earlier try took the rate from
; a silent tone on voice 6 (noise mode 7) and could not be heard at all.
TUN_HUMM    = 6                 ; the noise mode: white, slowest (4 = fastest white)
TUN_HUMV    = 3                 ; volume 0-15 (15 = loudest); 5 was too loud (the user, 2026-10-13)
TUN_HUMP    = 8                 ; frames between re-fires (the program lasts 16)
; The noise tops out at its fastest rate (mode 4), and the user wanted the end of the rush
; to climb far higher - an escape into hyperspace. So from RUSHR = TUN_WHINES (the start) a WHINE joins
; it: a tone on the chip's voice 0 (the gun's, which nothing fires here) that fades in and
; climbs from TUN_WHINEN to the top of the note table (MIDI 108, 4 kHz) by the last frame,
; r * 68 / 256 semitones, a note per ~7 frames, re-fired with the noise, with a VIBRATO of
; its own (7.5 Hz, +-1 to 3 semitones) and a tremolo, so that it does not sound a plain
; sine sliding up.
TUN_WHINES  = 1                 ; the rush clock (units of 2 frames) at which it begins: at
                                ;   once, quiet and low, rising with the speed (it was 80,
                                ;   half way, and came in too late - the user, 2026-10-13)
TUN_WHINEN  = 60                ; its first note (MIDI 60 = middle C)

; --- THE END OF THE RUN (design_technical 11.45; the user, 2026-10-13) ---------------
; The scene ends in a RUSH: no more rocks (the last is born TUN_CLEAR frames before
; it, enough for the farthest to pass), then for TUN_RUSHF frames the ship accelerates -
; the speed grows (up to 16 more z a frame, easing in) - and the dust stretches, from single
; pixels, into short lines pointing at the centre, longer the farther out, while the
; engine rises. Then the scene ends.
; RUSHR is the rush's own clock in units of 2 frames, 0 before it and 1..TUN_RUSH in it.
; The speed-up eases in (RSPT, quadratic) and is added with a fraction so that it never
; steps, and the streaks GROW from a single pixel (FRAC, quadratic): the tail is the
; head's offset times FRAC/256, at most half of it.
TUN_RUSHF   = 360               ; frames of rush (6 s: it was 180 and too short, 2026-10-13)
TUN_RUSH    = TUN_RUSHF / 2     ; ...in the units of RUSHR, which counts every second frame
TUN_CLEAR   = 200

; --- THE FAR STARS (design: the user, 2026-10-13) ---------------------------
; What the "stars" above are is DUST: the near field streaming past. The real stars
; are TUN_FAR single pixels at random places in the window, at infinity: no depth,
; no perspective, no zoom. All they do is slide a little against the lean (the
; camera divided by 2^TUN_FSH, the other way), wrapping round the window like the
; torus the dust lives on. A rock hides them, like it hides dust.
TUN_FAR     = 24                ; 32 until the roll (the user, 2026-10-13)
TUN_FSH     = 3                 ; they move CAM >> 3: at full lean (81) 10 px of 150

; --- THE ROCKS (design: the user, 2026-10-13) ---------------------------------
; The field's biggest rocks (class 192, the four SHP192 outlines), spinning in 2D
; as in the sector and growing with the perspective. A rock is a point in the tube
; (RXW, RYW: world x and y, where the ship's lean is +-TUN_AMP) and a depth, RZ,
; falling like a star's; it is drawn by one POLYGON16 - the GPU rotates and scales
; the authored outline, which it can only SHRINK (Q0.7, 128 = 1:1) - so a rock is
; 1:1 at the depth TUN_ZFULL and no bigger after it. Its occlusion disc (the
; field's SHAPE_OCC, 39 of the 48-px radius) hides the stars behind it, which is
; what makes the hollow outline read as a solid body.
TUN_ROCKS   = 16                ; at once (4 at first, doubled twice to test, 2026-10-13: the
                                ;   difficulty is meant to be in dodging them, and they are rare) TBM: a solid polygon is ~1.2k GPU cycles
                                ;   a SEGMENT, 13 of them a rock (11.49)
TUN_NDISC   = TUN_ROCKS + 2     ; the occlusion discs: the rocks', and a lifepod's middle
                                ;   and back lid (tunnel_pod.s), in the two slots after them
TUN_RZMAX   = 1020              ; a rock is born this far: four times a star's ZMAX (the
                                ;   user, 2026-10-13: they came in too late and too big),
                                ;   so its depth is 16 bit, indexed by z >> RTIER (below)
TUN_ZLOD    = 220               ; beyond this a rock is drawn from its REDUCED outline...
TUN_ZDOT    = 500               ; ...and beyond this only as a DOTTED polygon, which the user
                                ;   found it held too long (2026-10-13): from here in, solid
TUN_ZFULL   = 40                ; the depth at which a rock is drawn 1:1
TUN_ZHIT    = 36                ; ...and where it is tested against the ship, once
TUN_RZMIN   = 14                ; a rock this near has gone past
TUN_HITR    = 15                ; a hit: |rel x| and |rel y| both under this (world
                                ;   units): the rock's 10 (SHAPE_OCC at 1:1) + the ship's 5
TUN_SPAWN   = 25                ; frames between rocks, plus 0..15 (a spawn mask below)
TUN_RSPIN   = 7                 ; spin: -4..+3 brad a frame (AND mask)

; --- THE LEAN (design: the user, 2026-10-12) ----------------------------------
; The stick leans the ship in the eight directions inside the tube, and the ship
; still flies straight ahead: nine places to be (the centre and eight), and the
; way between them is a SPRING, so it starts and stops softly and never
; overshoots. Per axis, in 8.8: a = (T - P) >> K1 - V >> K2; V += a; P += V.
; K1 = 6 and K2 = 2 are (about) critical damping (k2 = 2 sqrt(k1)) with a time
; constant of 8 frames: 90% of the way in 31 frames, 98% in 47, from one place to
; the next, and it never goes past it. Slower (K1 = 7: 66 and 106 frames, K2 = 2)
; and faster are one constant each. All TBM. The camera is the position rounded:
; CAMX/CAMY.
TUN_AMP     = 81                ; how far it leans, in x/y units: 3 x the first 27
                                ;   (2026-10-12). Nothing limits it but the 8-bit
                                ;   position (+-127): the star field wraps
TUN_K1      = 6
TUN_K2      = 2

; --- THE ROLL (design: the user, 2026-10-13; the eight-way lean it replaced is git tag ----
; tunnel-lean-8way, and how to go back is open_questions.md H6) ----------------------------
; LEFT and RIGHT no longer lean: they TURN THE WORLD round the tube's axis. UP and DOWN
; still lean (the spring above, the y axis only, and inverted: UP leans down, like a
; pilot's stick), so the ship is at LY, its distance from
; the axis along the screen's up-down, and the roll TH says which way "up" is: the camera
; is at R(-TH) (0, LY) in the world, and every point is seen at R(TH) (w - cam) - the
; nine places are a ring of them now, the same reach. TH is 8.8 brad, its rate W 8.8 brad
; a frame, and W eases to its target (+-TUN_ROLLW held, 0 let go) by W += (T - W) >> K:
; a short smooth start and stop (time constant 2^K frames, 90% in ~18 at K = 3). RIGHT
; turns the world ANTICLOCKWISE (so at the top of the tube the ship goes right).
; R(a): x' = x C - y S, y' = x S + y C (portrait: x right, y down), the same as the GPU's
; polygon rotation in fb space (the TATE turn is a rotation, so the two agree), so a rock's
; angle on the screen is its own plus TH. The reach is a RING of radius AMP now, not the
; square +-AMP a side, so a thing born in a CORNER lane (+-AMP on both axes, 1.41 AMP out)
; is pulled in to the ring (tun_ring: both times 181/256), where the ship can get to it.
; A Saturnium cloud's centre turns with the world
; but its pattern does NOT (the user: it may set it apart from the stars).
TUN_ROLLW   = $0200             ; the roll's top rate, 8.8 brad a frame: a turn in 128 frames (TBM)
TUN_ROLLK   = 3                 ; the ease (TBM)
TUN_RKICK   = $0180             ; a hit's knock on the roll, 8.8 brad a frame (TBM)
TUN_HALF    = 75                ; the window's half-extent, HALF-res px
TUN_CX      = 100               ; the window's centre in half-res framebuffer
TUN_CY      = 75                ;   coordinates: fb x = 100 + (portrait down),
                                ;   fb y = 75 - (portrait right) - the TATE turn
        .assert TUN_F = 2 * TUN_HALF, error, "tunnel.s: tun_projs culls |rel| >= z, which is the window's edge only when F = 2 * HALF"
        .assert TUN_F * 128 / TUN_ZMIN / 128 + 128 <= 255, error, "tunnel.s: |rel| (<= 128) + R's high byte must fit umul's table index"
        .assert TUN_AMP <= 127, error, "tunnel.s: the lean is a signed byte"
        .assert TUN_ZMIN > TUN_SPEED + 1, error, "tunnel.s: z would borrow"
        .assert TUN_ROCKS <= 32, error, "tunnel.s: the near list is indexed by a byte and the arrays are 32 apart in cost"

        .pushseg
        .segment "TUNBSS"
SX:     .res    TUN_STARS               ; the star's place in the world, signed 16: low...
SY:     .res    TUN_STARS
SXH:    .res    TUN_STARS               ; ...and high (the roll's field is wider than a byte)
SYH:    .res    TUN_STARS
SZ:     .res    TUN_STARS               ; ZMIN..ZMAX
DOTB:   .res    1 + 2 * (TUN_STARS + TUN_FAR)   ; the DOT_PIXELS payload: N, x, y, ...
RVX:    .res    TUN_ROCKS               ; a thrown rock's world velocity, signed, units a frame
RVY:    .res    TUN_ROCKS
RDF:    .res    TUN_ROCKS               ; 1 = it has been thrown: depth frozen, flying sideways
SHK:    .res    1                       ; frames of shake left
HUMT:   .res    1                       ; frames to the next re-fire of the drone
HUMP:   .res    14                      ; the noise program: type, 4 x (frames, mode, volume), end
HUMQ:   .res    14                      ; the whine: a tone program on voice 0, the same shape
RUSHR:  .res    1                       ; the rush's clock (units of 2 frames): 0 = not yet, else 1..TUN_RUSH
SHV:    .res    1                       ; a streak's length fraction (FRAC), 0..127
ACCF:   .res    1                       ; the rush's speed-up, the fraction not yet added (1/16)
TMV:    .res    1
KSX:    .res    1                       ; the side the knock is from, per axis ($80 = left/above)
KSY:    .res    1
FARR:   .res    TUN_FAR                 ; a far star's place round the window's centre: radius
FARA:   .res    TUN_FAR                 ;   (0..105, half-res px) and angle (brad)
FSY:    .res    1                       ; the lean >> TUN_FSH, signed
CAMX:   .res    1                       ; the camera in the world (signed): R(-TH) (0, LY)
CAMY:   .res    1
CXH:    .res    1                       ; ...sign-extended, for the rocks' 9-bit rel
CYH:    .res    1
LY:     .res    1                       ; the lean (signed): the spring's y, rounded
WLO:    .res    1                       ; the roll's rate, 8.8 brad a frame, signed
WHI:    .res    1
THL:    .res    1                       ; ...and the roll, 8.8 brad
THH:    .res    1
ACM:    .res    1                       ; |cos TH| and |sin TH| (Q0.7)...
ACS:    .res    1
SGC:    .res    1                       ; ...and their signs (bit 7)
SGS:    .res    1
RXL:    .res    1                       ; tun_rot's input, two signed 16 (|v| <= 255)...
RXH:    .res    1
RYL:    .res    1
RYH:    .res    1
RQXL:    .res    1                       ; ...and its output
RQXH:    .res    1
RQYL:    .res    1
RQYH:    .res    1
MXR:    .res    1                       ; its magnitudes and signs
MYR:    .res    1
SXR:    .res    1
SYR:    .res    1
ACL:    .res    1                       ; ...and its sum
ACH:    .res    1
RHV:    .res    1                       ; 1 = both halved, the result doubled
SG1:    .res    1                       ; the four products' signs
SG2:    .res    1
SG3:    .res    1
SG4:    .res    1
RMT:    .res    1
TI:     .res    1                       ; the star being worked on (the multiply
                                        ;   clobbers X and Y, so it lives here)
TZ:     .res    1
TS:     .res    1                       ; the sign of what is being projected
TA:     .res    1                       ; umul's two operands...
TB:     .res    1
PL:     .res    1                       ; ...and its product
PH:     .res    1
OL:     .res    1                       ; the offset, 16 bit while it is summed
OH:     .res    1
OXS:    .res    1                       ; this star's offsets, signed
OYS:    .res    1
DN:     .res    1                       ; stars drawn this frame...
DI:     .res    1                       ; ...and the payload's write index
SVX:    .res    1                       ; a birth's candidate x and y
SVY:    .res    1
TMP:    .res    1
TMP2:   .res    1
DOTM:   .res    1                       ; 1 = the rock is far: drawn as a DOTTED polygon
CLB:    .res    1 + 2 * TUN_CLOUDMAX    ; a cloud's DOT_PIXELS payload
CLDP:   .res    64                      ; the pattern: 32 pairs (dx, dy), a signed disc of radius 127
CIDX:   .res    1                       ; the pattern place being drawn...
CK:     .res    1                       ; ...and how many are left
CDN:    .res    1                       ; pixels kept (in the window, not hidden)
CHXL:   .res    1                       ; the cloud's centre, half-res fb, signed 16
CHXH:   .res    1
CHYL:   .res    1
CHYH:   .res    1
CPXL:    .res    1                       ; a pixel
CPXH:    .res    1
CPYL:    .res    1
CPYH:    .res    1
TSAT:   .res    1                       ; clouds caught this passage
SPD:    .res    1                       ; z a frame this frame (a star's units): TUN_SPEED, +1 on odd frames
SPD2:   .res    1                       ; ...and in true z, a rock's: twice that
T3L:    .res    1                       ; a star's true depth, 9 bit, for the occluder test
T3H:    .res    1
RDOT:   .res    TUN_ROCKS               ; 1 = a rock so far it is drawn DOTTED
RTIER:   .res    1                       ; a rock's depth tier: z >> RTIER indexes its tables
SCL:    .res    1                       ; its scale, this frame
RSEL:   .res    TUN_ROCKS               ; which outline it is drawn from: 0-3 full, 4-7 reduced
RBL:    .res    TUN_ROCKS               ; the window's limits against it, relative to its
RBH:    .res    TUN_ROCKS               ;   centre, full-res fb x, signed bytes
RBT:    .res    TUN_ROCKS               ; ...and the screen's top and bottom (fb y 0..299),
RBB:    .res    TUN_ROCKS               ;   which a LINE16 does not clip - it CLAMPS
RWC:    .res    TUN_ROCKS               ; 1 = it crosses an x limit: drawn edge by edge, cut
VXF:    .res    13                      ; its vertices, full-res relative to its centre
VYF:    .res    13
EX0:    .res    1                       ; an edge being cut to the window
EY0:    .res    1
EX1:    .res    1
EY1:    .res    1
C0:     .res    1
C1:     .res    1
BLL:    .res    1                       ; the limits being cut to...
BHH:    .res    1
BNB:    .res    1                       ; ...and the one an end is cut back to
CXE:    .res    1                       ; the end being cut, and the end it is cut towards
CYE:    .res    1
CXO:    .res    1
CYO:    .res    1
ADV:    .res    1
YSG:    .res    1
MA8:    .res    1
MB8:    .res    1
MPL:    .res    1
MPH:    .res    1
NUML:   .res    1
NUMH:   .res    1
DEN:    .res    1
QUO:    .res    1
TMPV:   .res    1
EI:     .res    1
RZL:    .res    TUN_NDISC               ; depth (16 bit, true z up to TUN_RZMAX), 0 = no rock
RZH:    .res    TUN_NDISC
RVIS:   .res    TUN_ROCKS               ; 1 = in the window this frame, to be drawn
RCXL:   .res    TUN_ROCKS               ; its centre, full-res fb, signed 16
RCXH:   .res    TUN_ROCKS
RCYL:   .res    TUN_ROCKS
RCYH:   .res    TUN_ROCKS
RSCA:   .res    TUN_ROCKS               ; its SCALE (Q0.7) and its radius on the window,
RSCR:   .res    TUN_ROCKS               ;   half-res px, this frame
NBX:    .res    TUN_NDISC               ; for a rock being drawn: where a NEARER rock's
NBY:    .res    TUN_NDISC               ;   disc is relative to it, fb half-res, biased 128
NCNT:   .res    1                       ; ...and how many there are...
NLIST:  .res    TUN_NDISC               ; ...and which (rock indices)
HV:     .res    13                      ; per vertex of the rock being drawn: hidden?
HM:     .res    13                      ; ...per edge: its midpoint hidden?
EV:     .res    13                      ; ...per edge: visible (nothing hides it)?
VXB:    .res    13                      ; its vertices on the window, fb half-res,
VYB:    .res    13                      ;   relative to its centre, biased by 128
CCV:    .res    1                       ; cos and sin of its angle (signed Q0.7)...
SSV:    .res    1
CSV:    .res    1                       ; ...times its scale (the GPU's C and S)
SNV:    .res    1
VDX:    .res    1                       ; one outline vertex
VDY:    .res    1
SMA:    .res    1                       ; tun_sm's operands and sign
SMB:    .res    1
SMG:    .res    1
PXB:    .res    1                       ; the point being tested against the discs
PYB:    .res    1
RT2:     .res    1
NV:     .res    1                       ; the outline's vertex count
RUNS:   .res    1                       ; the visible run being collected: first vertex...
RUNE:   .res    1                       ; ...and last
EVS:    .res    1                       ; an invisible edge to start the walk from
EVC:    .res    1                       ; visible edges
RXW:    .res    TUN_ROCKS               ; world x and y, signed (the lean is +-AMP)
RYW:    .res    TUN_ROCKS
RAN:    .res    TUN_ROCKS               ; its angle, brad
RSP:    .res    TUN_ROCKS               ; ...and its spin, signed brad a frame
RKIND:  .res    TUN_ROCKS               ; 0 = a rock, 1 = a Saturnium cloud, 2 = a lifepod
RTY:    .res    TUN_ROCKS               ; which of the four outlines
RHI:    .res    TUN_ROCKS               ; 1 once it has been tested against the ship
ROC:    .res    TUN_NDISC               ; its occlusion radius on the window this frame,
                                        ;   half-res px, 0 = it hides nothing
RBX:    .res    TUN_NDISC               ; ...and where, as an offset from the window's
RBY:    .res    TUN_NDISC               ;   centre BIASED by 128 (unsigned)
TSHP:   .res    4 * 26 + 4 * 16         ; the outlines, copied out of SHAPES and
TSHN:   .res    8                       ;   doubled to full-res; their vertex counts
RBUF:   .res    7 + 26                  ; the POLYGON16 argument block
SPT:    .res    1                       ; frames to the next rock
HITS:   .res    1                       ; rocks that have struck the ship (a count
                                        ;   for the bench until the event is built)
TRK:    .res    1                       ; the rock being worked on
MG:     .res    1                       ; |rel|, 0..255, kept past the multiply
HXM:    .res    1                       ; the rock's |rel x| and |rel y|, for the hit
HYM:    .res    1
SXS:    .res    1                       ; the signs of its two offsets ($80 = negative)
SYS:    .res    1
XML:    .res    1                       ; ...and their magnitudes, 16 bit
XMH:    .res    1
YML:    .res    1
YMH:    .res    1
RSC:    .res    1                       ; its radius on the window, half-res px
VOFF:   .res    1                       ; the outline's offset in TSHP...
VCNT:   .res    1                       ; ...and its byte count, 2N
SXB:    .res    1                       ; a star's offsets, biased, for the occluder test
SYB:    .res    1
DXM:    .res    1
DYM:    .res    1
PLO:    .res    2                       ; the lean's position (8.8) per axis,
PHI:    .res    2                       ;   x then y
VLO:    .res    2                       ; ...and its velocity
VHI:    .res    2
EL:     .res    1                       ; the spring's working 16 bit pair
EH:     .res    1
AL:     .res    1                       ; ...and the acceleration
AH:     .res    1
TX:     .res    1                       ; the axis being stepped
TG:     .res    1                       ; ...and its target
TT:     .res    1                       ; tun_lean_frame's target
TJ:     .res    1                       ; the stick, as held this frame
        .include "tunnel_art.s"         ; GENERATED: TUN_ART_HUD, its blobs in
                                        ;   TUNART, its tables in TUNCODE
        .segment "TUNCODE"

        ART_RUNTIME tun_art_arm, tun_art_step, TUN_ART_GEO, TUN_ART_TAB

; R(z) = 128 * F / z, as a high byte (R / 128) and a 7-bit low byte, so that
; |v| * R >> 7 is two exact 7-bit multiplies: |v| * RH + (|v| * RL >> 7).
RHT:    .repeat 256, I
        .byte   ((128 * TUN_F) / .max(I, 1)) / 128
        .endrepeat
RLT:    .repeat 256, I
        .byte   ((128 * TUN_F) / .max(I, 1)) & 127
        .endrepeat

; THE TUNNEL'S CODE IS IN TWO AREAS (open_questions.md H1, the memory plan): TUNCODE runs in
; TUNRAM (DEMO_RAM, $C000) and TUNCODE2 - the rocks - in the RUN AREA ($1000, TUNRUN), which
; the tunnel overwrites for as long as it flies and which overlay.s reloads from ROM when it
; ends. The variables (TUNBSS) are in the run area too.
        .segment "TUNCODE2"
; The rocks' scale, by depth: Q0.7, 128 (1:1) at TUN_ZFULL and nearer. A rock's depth
; is 16 bit; the table is indexed by TZ = z >> RTIER, RTIER 0 for z < 256 (z = TZ), 1 for
; z < 512 (z = 2 TZ), 2 above (z = 4 TZ). The projection reuses the stars' RHT/RLT at
; TZ and shifts the result right by RTIER; the radii are 3/8 and 5/16 of the scale.
RST0:   .repeat 256, I
        .byte   .min(128, (128 * TUN_ZFULL) / .max(I, 1))
        .endrepeat
RST1:   .repeat 128, J                  ; (tiers 1 and 2 are indexed 128..255 only: the tables
        .byte   .min(128, (64 * TUN_ZFULL) / (J + 128))     ;   start at 128, and are read as RST1 - 128, y)
        .endrepeat
RST2:   .repeat 128, J
        .byte   .min(128, (32 * TUN_ZFULL) / (J + 128))
        .endrepeat
TSHO:   .byte   0, 26, 52, 78, 104, 120, 136, 152   ; each outline's offset in TSHP
LANE:   .byte   <(-TUN_AMP), 0, TUN_AMP, 0
        .segment "TUNCODE"
; The rush's two ease-ins, by RUSHR (0..TUN_RUSH): the extra speed in 1/16 of a z unit a
; frame (quadratic, 0 to 255 = 16 units: it was 1/32 and 8, and the streaks looked too slow
; for their length - the user, 2026-10-13) and a streak's length as a fraction of its head's
; offset, in 1/256 (quadratic, 0 to 127 = a half): both start at ZERO and grow smoothly.
RSPT:   .repeat TUN_RUSH + 1, I
        .byte   .min(255, (255 * I * I) / (TUN_RUSH * TUN_RUSH))
        .endrepeat
FRAC:   .repeat TUN_RUSH + 1, I
        .byte   .min(127, (127 * I * I) / (TUN_RUSH * TUN_RUSH))
        .endrepeat

; -----------------------------------------------------------------------------
; umul - TA * TB -> PH:PL, exact. Both <= 127, so TA + TB is a table index.
; a*b = f(a+b) - f(|a-b|), f(x) = x*x/4 (QSL/QSH, math.s init_qs). Clobbers A X Y.
; -----------------------------------------------------------------------------
umul:
        clc
        lda     TA
        adc     TB
        tax
        sec
        lda     TA
        sbc     TB
        bcs     :+
        eor     #$FF                    ; carry is clear: this +1 negates
        adc     #$01
:       tay
        sec
        lda     QSL,x
        sbc     QSL,y
        sta     PL
        lda     QSH,x
        sbc     QSH,y
        sta     PH
        rts

; -----------------------------------------------------------------------------
; tun_pcore - TA = |rel|, 0..255 (TA + R's high byte must stay <= 255), TS = its
; sign ($80 = negative), TZ = the depth. -> OH:OL = |rel| * F / z, 16 bit. The
; low byte of R is a 7-bit multiply, so a |rel| over 127 is halved first
; (2 * (|rel| >> 1) * RL, plus RL again if it was odd). Clobbers A X Y TA TB.
; -----------------------------------------------------------------------------
tun_pcore:
        lda     TA
        sta     MG                      ; (the caller may want it: the hit test)
        ldy     TZ
        lda     RHT,y
        sta     TB
        jsr     umul                    ; |rel| * RH
        lda     PL
        sta     OL
        lda     PH
        sta     OH
        ldy     TZ
        lda     RLT,y
        sta     TB
        lda     TA
        bmi     @big
        jsr     umul                    ; |rel| * RL
        bra     @sum
@big:   lsr     a                       ; 2 * (|rel| >> 1) * RL ...
        sta     TA
        jsr     umul
        asl     PL
        rol     PH
        lda     MG
        lsr     a                       ; ...+ RL if |rel| was odd
        bcc     @sum
        lda     PL
        clc
        adc     TB
        sta     PL
        bcc     @sum
        inc     PH
@sum:   lda     PL                      ; (P + 64) >> 7, rounded
        clc
        adc     #64
        sta     PL
        lda     PH
        adc     #0
        asl     PL                      ; bit 7 of the low byte into carry...
        rol     a                       ; ...and in at the bottom
        clc
        adc     OL
        sta     OL
        bcc     :+
        inc     OH
:       rts

; -----------------------------------------------------------------------------
; tun_projwin - after tun_pcore on a star (TS its sign): C CLEAR: A = its offset on
; the window, signed, |A| < TUN_HALF. C SET: it is outside the window, and the star
; is done.
; -----------------------------------------------------------------------------
tun_projwin:
        lsr     OH                      ; (a star's z is in units of 2: half the offset)
        ror     OL
        lda     OH
        bne     @out
        lda     OL
        cmp     #TUN_HALF
        bcs     @out
        ldx     TS
        bpl     @pos
        lda     #$00
        sec
        sbc     OL
        clc
        rts
@pos:   lda     OL
        clc
        rts
@out:   sec
        rts

; -----------------------------------------------------------------------------
; tun_projw - A = the low byte, X = the high byte of a signed 16 rel (turned: tun_rot's
; output). -> TS, MG = |rel|, OH:OL = |offset| (16 bit, not windowed). |rel| is held to 240,
; which keeps TA + R's high byte a table index (a rock's TZ >= 14: RH <= 10) and is far
; outside the window for anything that near (only a thrown rock gets so far off).
; tun_projs - the same for a star, windowed: C and A as tun_projwin.
; -----------------------------------------------------------------------------
tun_projs:
        jsr     tun_pmag
        cpx     #0                      ; |rel| >= z: its offset |rel| F / 2z is past
        bne     @out                    ;   the window's half (F = 2 * TUN_HALF) - and
        cmp     TZ                      ;   TA + R's high byte stays a table index
        bcs     @out
        sta     TA
        jsr     tun_pcore
        jmp     tun_projwin             ; tail
@out:   sec
        rts
tun_projw:
        jsr     tun_pmag
        cpx     #0
        bne     @cl
        cmp     #241
        bcc     @ok
@cl:    lda     #240
@ok:    sta     TA
        jmp     tun_pcore               ; tail

; tun_pmag - A = low, X = high of a signed 16 -> TS its sign ($80 = negative), A low
; and X high of its magnitude.
tun_pmag:
        stz     TS
        cpx     #$80
        bcc     @p
        pha
        lda     #$80
        sta     TS
        pla
        eor     #$FF
        clc
        adc     #$01
        pha
        txa
        eor     #$FF
        adc     #$00
        tax
        pla
@p:     rts

; -----------------------------------------------------------------------------
; tun_trig - ACM/SGC and ACS/SGS: |cos TH|, |sin TH| and their signs, for tun_rot.
; -----------------------------------------------------------------------------
tun_trig:
        lda     THH
        jsr     API_COS
        sta     SGC
        jsr     tun_abs
        sta     ACM
        lda     THH
        jsr     API_SIN
        sta     SGS
        jsr     tun_abs
        sta     ACS
        rts

; -----------------------------------------------------------------------------
; tun_rot - QX, QY = R(TH) (RX, RY): x' = x C - y S, y' = x S + y C, signed 16 in
; and out. FAST (it runs ~45 times a frame - the first version, through umul and a
; 24-bit sum, cost ~870 cycles a call and put a dump at 100% of a frame): each side's
; magnitude is held to 255 (only a thrown rock or a star far off to the side is ever
; past it, and it is outside the window), and when either is 128 or more BOTH are
; halved and the result doubled - such a point is so far off that it is seen only
; when far, where a unit is under a pixel. Then every product is |a| * |c| with both
; <= 127, straight from the quarter squares (QSL/QSH), and each sum fits 16 bits.
; tun_roti - the same by R(-TH) (S negated). Clobbers A X Y.
; -----------------------------------------------------------------------------
; QPROD m, c - PL = low, A = high of m * c (both <= 127): f(m + c) - f(|m - c|).
.macro QPROD m, c
        clc
        lda     m
        adc     c
        tax
        sec
        lda     m
        sbc     c
        bcs     :+
        eor     #$FF                    ; (carry clear: + 1 negates)
        adc     #$01
:       tay
        sec
        lda     QSL,x
        sbc     QSL,y
        sta     PL
        lda     QSH,x
        sbc     QSH,y
.endmacro
; QSIGN sg - ACH:ACL = +-(A:PL), negative when bit 7 of sg (memory) is set.
.macro QFIRST sg
        sta     ACH
        lda     PL
        sta     ACL
        bit     sg
        bpl     :+
        sec
        lda     #0
        sbc     ACL
        sta     ACL
        lda     #0
        sbc     ACH
        sta     ACH
:
.endmacro
; QNEXT sg - ACH:ACL += (A:PL), or -= when bit 7 of sg is set.
.macro QNEXT sg
        sta     PH
        bit     sg
        bmi     :+
        clc
        lda     ACL
        adc     PL
        sta     ACL
        lda     ACH
        adc     PH
        sta     ACH
        bra     :++
:       sec
        lda     ACL
        sbc     PL
        sta     ACL
        lda     ACH
        sbc     PH
        sta     ACH
:
.endmacro
; QROUND - A (low), X (high) = (ACH:ACL + 64) >> 7, doubled when RHV.
.macro QROUND
        clc
        lda     ACL
        adc     #64
        sta     ACL
        lda     ACH
        adc     #0
        asl     ACL                     ; bit 7 of the low byte into the bottom...
        rol     a                       ; ...and the sign out into carry
        ldx     #0
        bcc     :+
        dex
:       ldy     RHV
        beq     :+
        asl     a                       ; (doubled, 16 bit)
        tay
        txa
        rol     a
        tax
        tya
:
.endmacro

tun_roti:
        lda     SGS
        eor     #$80
        sta     SGS
        jsr     tun_rot
        lda     SGS
        eor     #$80
        sta     SGS
        rts
tun_rot:
        lda     RXH                     ; |x|, held to 255, and its sign
        sta     SXR
        bpl     @xp
        sec
        lda     #0
        sbc     RXL
        tax
        lda     #0
        sbc     RXH
        bne     @xc
        txa
        bra     @xs
@xp:    bne     @xc                     ; (the Z of the LDA RXH)
        lda     RXL
        bra     @xs
@xc:    lda     #255
@xs:    sta     MXR
        lda     RYH                     ; |y|, the same
        sta     SYR
        bpl     @yp
        sec
        lda     #0
        sbc     RYL
        tax
        lda     #0
        sbc     RYH
        bne     @yc
        txa
        bra     @ys
@yp:    bne     @yc
        lda     RYL
        bra     @ys
@yc:    lda     #255
@ys:    sta     MYR
        stz     RHV                     ; either past 127: both halved
        ora     MXR
        bpl     :+
        lsr     MXR
        lsr     MYR
        inc     RHV
:       lda     SXR                     ; the four products' signs
        eor     SGC
        sta     SG1                     ; x C
        lda     SYR
        eor     SGS
        eor     #$80
        sta     SG2                     ; - y S
        lda     SXR
        eor     SGS
        sta     SG3                     ; x S
        lda     SYR
        eor     SGC
        sta     SG4                     ; y C
        QPROD   MXR, ACM                ; x' = x C - y S
        QFIRST  SG1
        QPROD   MYR, ACS
        QNEXT   SG2
        QROUND
        sta     RQXL
        stx     RQXH
        QPROD   MXR, ACS                ; y' = x S + y C
        QFIRST  SG3
        QPROD   MYR, ACM
        QNEXT   SG4
        QROUND
        sta     RQYL
        stx     RQYH
        rts

; tun_sx - A = a signed byte -> A = its high byte, sign-extended ($00 or $FF).
tun_sx:
        cmp     #$80
        lda     #$00
        bcc     :+
        lda     #$FF
:       rts

; tun_abs - A = |A| (128 for -128).
tun_abs:
        cmp     #$80                    ; (the sign from A itself, not the flags: a caller
        bcc     :+                      ;   may come straight from a STA)
        eor     #$FF
        adc     #$00                    ; (carry set: + 1)
:       rts

; -----------------------------------------------------------------------------
; tun_born - star TI is (re)born: a random place IN VIEW at ZMAX, outside the
; hole. rel is picked and x = rel + cam stored, so the torus does the rest.
; -----------------------------------------------------------------------------
tun_born:
@try:   jsr     prng                    ; |x|, |y| < TUN_DUSTR...
        cmp     #TUN_DUSTR
        bcs     @try
        sta     SVX
@ty:    jsr     prng
        cmp     #TUN_DUSTR
        bcs     @ty
        sta     SVY
        cmp     #TUN_HOLE               ; ...not both inside the hole...
        bcs     @ok
        lda     SVX
        cmp     #TUN_HOLE
        bcc     @try
@ok:    lda     SVY                     ; ...and inside the disc (the octagon
        cmp     SVX                     ;   max + min/2 < DUSTR)
        bcs     :+
        lda     SVX
        ldx     SVY
        bra     :++
:       ldx     SVX
:       stx     TMP
        lsr     TMP
        clc
        adc     TMP
        bcs     @try
        cmp     #TUN_DUSTR
        bcs     @try
        jsr     prng                    ; the signs: bit 0 x, bit 1 y
        sta     TMP2
        lda     SVX
        stz     RXH
        lsr     TMP2
        bcc     :+
        eor     #$FF                    ; (negated, 16 bit)
        clc
        adc     #$01
        dec     RXH
:       sta     RXL
        lda     SVY
        stz     RYH
        lsr     TMP2
        bcc     :+
        eor     #$FF
        clc
        adc     #$01
        dec     RYH
:       sta     RYL
        ldx     RXL                     ; (a negation of 0 is 0: no borrow into the high byte)
        bne     :+
        stz     RXH
:       ldx     RYL
        bne     :+
        stz     RYH
:       jsr     tun_roti                ; rel = R(-TH) (the place in view), x = rel + cam
        ldx     TI
        clc
        lda     RQXL
        adc     CAMX
        sta     SX,x
        lda     RQXH
        adc     CXH
        sta     SXH,x
        clc
        lda     RQYL
        adc     CAMY
        sta     SY,x
        lda     RQYH
        adc     CYH
        sta     SYH,x
        jsr     prng                    ; ZMAX less a little, so a reborn star
        and     #$07                    ;   does not come in with all the others
        sta     TMP
        lda     #TUN_ZMAX
        sec
        sbc     TMP
        ldx     TI
        sta     SZ,x
        rts

; -----------------------------------------------------------------------------
; tun_asr - EH:EL >>= Y, arithmetic. Clobbers A, Y.
; -----------------------------------------------------------------------------
tun_asr:
@lp:    lda     EH
        cmp     #$80                    ; the sign into carry for the ROR
        ror     EH
        ror     EL
        dey
        bne     @lp
        rts

; -----------------------------------------------------------------------------
; tun_lean - X = the axis (0 x, 1 y), A = its target (signed): ONE step of the
; spring. a = (T*256 - P) >> K1 - V >> K2.
; -----------------------------------------------------------------------------
tun_lean:
        stx     TX
        sta     TG
        lda     PLO,x                   ; P >> K1 first, and T << (8 - K1) as its
        sta     EL                      ;   twin: (T*256 - P) >> K1 as ONE 16-bit
        lda     PHI,x                   ;   subtraction would overflow at the
        sta     EH                      ;   larger amplitudes (2 * 81 * 256 > 32767)
        ldy     #TUN_K1
        jsr     tun_asr
        lda     TG
        sta     AL
        stz     AH                      ; T sign-extended to 16 bits...
        lda     TG
        bpl     :+
        dec     AH
:       ldx     #8 - TUN_K1             ; ...and shifted left (8 - K1) times
@sh:    beq     @shd
        asl     AL
        rol     AH
        dex
        bra     @sh
@shd:   sec
        lda     AL
        sbc     EL
        sta     AL
        lda     AH
        sbc     EH
        sta     AH
        ldx     TX
        lda     VLO,x
        sta     EL
        lda     VHI,x
        sta     EH
        ldy     #TUN_K2
        jsr     tun_asr
        sec
        lda     AL
        sbc     EL
        sta     AL
        lda     AH
        sbc     EH
        sta     AH
        ldx     TX
        clc
        lda     VLO,x                   ; V += a
        adc     AL
        sta     VLO,x
        lda     VHI,x
        adc     AH
        sta     VHI,x
        clc
        lda     PLO,x                   ; P += V
        adc     VLO,x
        sta     PLO,x
        lda     PHI,x
        adc     VHI,x
        sta     PHI,x
        rts

; -----------------------------------------------------------------------------
; tun_lean_frame - LEFT/RIGHT: the roll's rate eased to its target, the roll turned
; by it, and its cos and sin (tun_trig). UP/DOWN: the lean's spring, the y axis only
; (LY = its position rounded). The camera = R(-TH) (0, LY) in the world, shaken.
; -----------------------------------------------------------------------------
tun_lean_frame:
        ldx     JOYPORT
        lda     JOY1,x
        sta     TJ
        stz     AL                      ; the roll's target rate, 8.8: RIGHT turns the
        stz     AH                      ;   world anticlockwise (TH falling)
        lda     TJ
        and     #JOY_RIGHT
        beq     :+
        lda     #<(-TUN_ROLLW)
        sta     AL
        lda     #>(-TUN_ROLLW)
        sta     AH
:       lda     TJ
        and     #JOY_LEFT
        beq     :+
        lda     #<TUN_ROLLW
        sta     AL
        lda     #>TUN_ROLLW
        sta     AH
:       sec                             ; E = (T - W) >> K
        lda     AL
        sbc     WLO
        sta     EL
        lda     AH
        sbc     WHI
        sta     EH
        ldy     #TUN_ROLLK
        jsr     tun_asr
        lda     EL
        ora     EH
        bne     @acc
        lda     AL                      ; less than a step from it: there (or a
        sta     WLO                     ;   rate of a few 1/256 would creep on)
        lda     AH
        sta     WHI
        bra     @turn
@acc:   clc
        lda     WLO
        adc     EL
        sta     WLO
        lda     WHI
        adc     EH
        sta     WHI
@turn:  clc                             ; TH += W
        lda     THL
        adc     WLO
        sta     THL
        lda     THH
        adc     WHI
        sta     THH
        jsr     tun_trig
        stz     TT                      ; y: UP leans DOWN (portrait), DOWN up - a pilot's
        lda     TJ                      ;   stick (the user, 2026-10-13, with the roll)
        and     #JOY_UP
        beq     :+
        lda     #TUN_AMP
        sta     TT
:       lda     TJ
        and     #JOY_DOWN
        beq     :+
        lda     #<(-TUN_AMP)
        sta     TT
:       lda     TT
        ldx     #1
        jsr     tun_lean
        lda     PLO+1                   ; round: add 1 when the fraction is >= 1/2
        cmp     #$80
        lda     PHI+1
        adc     #0
        sta     LY
        stz     RXL                     ; the camera: R(-TH) (0, LY)
        stz     RXH
        sta     RYL
        jsr     tun_sx
        sta     RYH
        jsr     tun_roti
        lda     RQXL
        sta     CAMX
        lda     RQYL
        sta     CAMY
        lda     SHK                     ; the shake: a jitter on the camera, fading
        beq     @ns
        dec     SHK
        lsr     a
        lsr     a                       ; (SHK / 4 units)
        beq     @ns
        sta     TMP
        jsr     tun_jit
        clc
        adc     CAMX
        sta     CAMX
        lda     TMP
        jsr     tun_jit
        clc
        adc     CAMY
        sta     CAMY
@ns:    lda     CAMX                    ; ...sign-extended, for the rocks
        jsr     tun_sx
        sta     CXH
        lda     CAMY
        jsr     tun_sx
        sta     CYH
        rts

; -----------------------------------------------------------------------------
; tun_occ - C SET when the star at offsets OXS/OYS (depth TZ) is behind a rock's
; occlusion disc. The disc is tested in the window's own offset space (biased by
; 128 so a distance is an unsigned difference), as an octagon: max + min/2 < r.
; -----------------------------------------------------------------------------
tun_occ:
        lda     TZ                      ; the star's true depth, 9 bit
        asl     a
        sta     T3L
        lda     #0
        rol     a
        sta     T3H
tun_occ0:                               ; (a far star enters here with T3 = infinity)
        lda     OXS
        eor     #$80
        sta     SXB
        lda     OYS
        eor     #$80
        sta     SYB
        ldx     #TUN_NDISC - 1
@k:     lda     ROC,x
        beq     @nx
        lda     RZL,x                   ; a rock hides only what is farther than it: its
        cmp     T3L                     ;   true z against the star's (2 * TZ, 9 bit)
        lda     RZH,x
        sbc     T3H
        bcs     @nx
        lda     SXB
        sec
        sbc     RBX,x
        bcs     :+
        eor     #$FF
        adc     #$01
:       cmp     ROC,x
        bcs     @nx
        sta     DXM
        lda     SYB
        sec
        sbc     RBY,x
        bcs     :+
        eor     #$FF
        adc     #$01
:       cmp     ROC,x
        bcs     @nx
        sta     DYM
        cmp     DXM                     ; the larger of the two, and half the other
        bcs     @ymax
        lda     DYM
        lsr     a
        clc
        adc     DXM
        bra     @cmp
@ymax:  lda     DXM
        lsr     a
        clc
        adc     DYM
@cmp:   cmp     ROC,x
        bcc     @hid
@nx:    dex
        bpl     @k
        clc
        rts
@hid:   sec
        rts

        .segment "TUNCODE2"
; -----------------------------------------------------------------------------
; tun_rocks_init - the four 192 outlines AND their reduced ones (the authored LOD
; outlines of the sector, for the rocks that are far) out of SHAPES (the RAM under
; the window, readable only with the window off) into TSHP, doubled to full-res
; (the field's SHAPE_16X). A full outline is 26 bytes (13 vertices is the most any
; has), a reduced one 16 (8); a shorter one just carries the next one's bytes
; after its own N. TSHP: the four full ones, then the four reduced.
; -----------------------------------------------------------------------------
        .macro  CPSHP idx, lab, lablod
        ldx     #25
:       lda     lab,x
        asl     a
        sta     TSHP + idx * 26,x
        dex
        bpl     :-
        lda     SHAPE_N + idx
        sta     TSHN + idx
        ldx     #15
:       lda     lablod,x
        asl     a
        sta     TSHP + 104 + idx * 16,x
        dex
        bpl     :-
        lda     SHAPE_LODN + idx
        sta     TSHN + 4 + idx
        .endmacro

tun_cloud_init:                         ; CLDP: 32 random points in a disc, by rejection
        ldx     #0
@pt:    stx     TI
@try:   jsr     prng
        cmp     #$80                    ; (-128 would not do as a tun_sm operand)
        beq     @try
        sta     CHXL                    ; (scratch: the cloud's centre is not in use yet)
        jsr     prng
        cmp     #$80
        beq     @try
        sta     CHYL
        sta     SMB
        lda     CHYL
        jsr     tun_sm                  ; dy * dy >> 7
        sta     TMP
        lda     CHXL
        sta     SMB
        lda     CHXL
        jsr     tun_sm                  ; dx * dx >> 7
        clc
        adc     TMP
        cmp     #127                    ; inside the disc: dx2 + dy2 <= 127 (of 128)
        bcs     @try
        lda     TI
        asl     a
        tax
        lda     CHXL
        sta     CLDP,x
        lda     CHYL
        sta     CLDP+1,x
        ldx     TI
        inx
        cpx     #32
        bne     @pt
        rts

tun_rocks_init:
        jsr     tun_cloud_init
        stz     TSAT
        jsr     win_off
        CPSHP   0, SHP192_A, SHP192_A_LOD
        CPSHP   1, SHP192_B, SHP192_B_LOD
        CPSHP   2, SHP192_C, SHP192_C_LOD
        CPSHP   3, SHP192_D, SHP192_D_LOD
        jsr     win_on
        ldx     #TUN_ROCKS - 1
:       stz     RZL,x
        stz     RZH,x
        stz     ROC,x
        stz     RVIS,x
        stz     RKIND,x
        dex
        bpl     :-
        stz     HITS
        jsr     tun_pod_init
        lda     #30                     ; the first rock after half a second
        sta     SPT
        rts

; -----------------------------------------------------------------------------
; tun_spawn - a rock in a free slot, far away (TUN_RZMAX): on one of the nine lanes
; of the lean (-AMP, 0, +AMP on each axis) give or take 16, with its own outline,
; angle and spin. None free: nothing.
; -----------------------------------------------------------------------------
tun_spawn:
        ldx     #TUN_ROCKS - 1
:       lda     RZL,x
        ora     RZH,x
        beq     @free
        dex
        bpl     :-
        rts
@free:  stx     TRK
        lda     #<TUN_RZMAX
        sta     RZL,x
        lda     #>TUN_RZMAX
        sta     RZH,x
        stz     RHI,x
        stz     RDF,x
        stz     ROC,x
        jsr     prng
        and     #3
        tay
        sty     LIX
        lda     LANE,y
        sta     TMP
        jsr     prng
        and     #31
        sec
        sbc     #16
        clc
        adc     TMP
        ldx     TRK
        sta     RXW,x
        jsr     prng
        and     #3
        tay
        sty     LIY
        lda     LANE,y
        sta     TMP
        jsr     prng
        and     #31
        sec
        sbc     #16
        clc
        adc     TMP
        ldx     TRK
        sta     RYW,x
        jsr     tun_pod_guard           ; not in the lane of a pod about to come
        ldx     TRK
        jsr     tun_ring                ; a corner lane pulled in to the ring
        jsr     prng
        ldx     TRK
        sta     RAN,x
        jsr     prng
        and     #TUN_RSPIN
        sec
        sbc     #4
        ldx     TRK
        sta     RSP,x
        jsr     prng
        and     #3
        ldx     TRK
        sta     RTY,x
        stz     RKIND,x
        jsr     prng
        and     #TUN_CLOUDP
        bne     @rk
        ldx     TRK                     ; a Saturnium cloud: no spin to speak of, its
        lda     #1                      ;   pattern drifts a place every 4 frames
        sta     RKIND,x
        sta     RSP,x
@rk:    rts

; tun_shr - OH:OL >>= RTIER (a rock's offset was projected with z >> RTIER).
tun_shr:
        ldy     RTIER
        beq     @d
@l:     lsr     OH
        ror     OL
        dey
        bne     @l
@d:     rts

; -----------------------------------------------------------------------------
; tun_rocks_frame - spawn on the timer; pass 1: every rock falls, spins, is
; projected, is tested against the ship once (at TUN_ZHIT) and, if any of it is in
; the window, leaves its centre, scale, radius, occlusion disc and the limits of
; the window against it; pass 2 draws each one that is - clipped against the NEARER
; rocks' discs, so that no part of a far rock shows through a near one, and
; against the window's edge (the HUD's frame), which the GPU does not know about.
;
; A rock's depth is 16 bit (z up to TUN_RZMAX = 1020) and its tables are indexed by
; TZ = z >> RTIER, RTIER = 0 for z < 256, 1 for z < 512, 2 above: a byte index with
; a resolution that gets coarser as the rock gets small.
; -----------------------------------------------------------------------------
tun_rocks_frame:
        jsr     tun_pod_sched           ; the lifepods' times, and their ghost discs cleared
        jsr     tun_deco                ; now and then a rock outside the tube (tunnel_pod.s)
        dec     SPT
        bne     @loop0
        lda     SC_PTRL                 ; no new rock in the last TUN_RUSHF + TUN_CLEAR frames:
        cmp     #<(TUN_FRAMES - TUN_RUSHF - TUN_CLEAR)
        lda     SC_PTRH                 ;   the last has time to pass before the rush
        sbc     #>(TUN_FRAMES - TUN_RUSHF - TUN_CLEAR)
        bcs     @loop0
        jsr     tun_spawn
        jsr     prng
        and     #15
        clc
        adc     #TUN_SPAWN
        sta     SPT
@loop0: stz     TRK
@rock:  ldx     TRK
        stz     ROC,x
        stz     RVIS,x
        lda     RZL,x
        ora     RZH,x
        bne     :+
        jmp     @next
:       lda     RDF,x
        beq     @fall
        lda     RXW,x                   ; thrown: its depth is frozen, it flies sideways
        clc
        adc     RVX,x
        sta     RXW,x
        lda     RYW,x
        clc
        adc     RVY,x
        sta     RYW,x
        jmp     @alive
@fall:  sec                             ; z -= SPD, 16 bit
        lda     RZL,x
        sbc     SPD2
        sta     RZL,x
        lda     RZH,x
        sbc     #0
        sta     RZH,x
        bne     @alive
        lda     RZL,x
        cmp     #TUN_RZMIN
        bcs     @alive
        stz     RZL,x                   ; gone past
        stz     RZH,x
        lda     RKIND,x
        cmp     #2
        bne     :+
        inc     TPLOST                  ; a lifepod not caught: the bar says so
        lda     #IM_PILOT_LOST          ;   (tunnel_hud.s)
        jsr     indicate_msg
:       jmp     @next
@alive: ldx     TRK
        lda     RZH,x                   ; TIER, and TZ = z >> TIER
        bne     @t1
        lda     RZL,x
        sta     TZ
        stz     RTIER
        bra     @tz
@t1:    cmp     #2
        bcs     @t2
        lda     RZL,x
        lsr     a
        ora     #$80
        sta     TZ
        lda     #1
        sta     RTIER
        bra     @tz
@t2:    lda     RZH,x                   ; 2..3: (RZH << 6) | (RZL >> 2)
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        sta     TMP
        lda     RZL,x
        lsr     a
        lsr     a
        ora     TMP
        sta     TZ
        lda     #2
        sta     RTIER
@tz:    ldx     TRK
        lda     RAN,x
        clc
        adc     RSP,x
        sta     RAN,x
        lda     RXW,x                   ; rel = w - cam, 16 bit (|rel| reaches 177 a
        jsr     tun_sx                  ;   side: +-97 less the lean +-81)...
        tay
        lda     RXW,x
        sec
        sbc     CAMX
        sta     RXL
        tya
        sbc     CXH
        sta     RXH
        lda     RYW,x
        jsr     tun_sx
        tay
        lda     RYW,x
        sec
        sbc     CAMY
        sta     RYL
        tya
        sbc     CYH
        sta     RYH
        jsr     tun_rot                 ; ...turned with the world
        lda     RQXL
        ldx     RQXH
        jsr     tun_projw
        jsr     tun_shr                 ; (it was projected with z >> RTIER)
        lda     MG
        sta     HXM
        lda     TS
        sta     SXS
        lda     OL
        sta     XML
        lda     OH
        sta     XMH
        lda     RQYL
        ldx     RQYH
        jsr     tun_projw
        jsr     tun_shr
        lda     MG
        sta     HYM
        lda     TS
        sta     SYS
        lda     OL
        sta     YML
        lda     OH
        sta     YMH
        ; --- the hit, once, as the rock reaches TUN_ZHIT --------------------
        ldx     TRK
        lda     RZH,x
        bne     @nohit
        lda     RZL,x
        cmp     #TUN_ZHIT + 1
        bcs     @nohit
        lda     RHI,x
        bne     @nohit
        lda     #1
        sta     RHI,x
        lda     #TUN_HITR               ; how near is a hit (a rock) or a catch (a cloud, a pod)
        ldy     RKIND,x
        beq     :+
        lda     #TUN_CATCHR
        cpy     #2
        bne     :+
        lda     #TUN_PODR
:       sta     TMV
        lda     HXM
        cmp     TMV
        bcs     @nohit
        lda     HYM
        cmp     TMV
        bcs     @nohit
        ldy     RKIND,x
        bne     @catch
        jsr     tun_hit                 ; the knock, the shake, the sound; the rock is thrown
        ldx     TRK
        bra     @nohit
@catch: cpy     #2
        beq     :+
        jsr     tun_catch               ; the Saturnium: a sound and a tally; the cloud is gone
        jmp     @next
:       jsr     tun_pod_catch           ; a pilot: the pod is gone
        jmp     @next
@nohit: ldy     TZ                      ; its SCALE by depth (Q0.7, 128 = 1:1)
        lda     RTIER
        beq     @s0
        cmp     #1
        beq     @s1
        lda     RST2 - 128,y
        bra     @sd
@s1:    lda     RST1 - 128,y
        bra     @sd
@s0:    lda     RST0,y
@sd:    sta     SCL
        lda     RKIND,x                 ; a lifepod: its own projection (tunnel_pod.s)
        cmp     #2
        bne     :+
        jsr     tun_pod_p1
        jmp     @next
:       lda     SCL
        lsr     a                       ; its radius on the window, half-res px:
        lsr     a                       ;   3/8 of the scale (48 of 128)
        sta     RSC
        lda     SCL
        lsr     a
        lsr     a
        lsr     a
        clc
        adc     RSC
        sta     RSC
        clc
        adc     #TUN_HALF
        sta     TMP                     ; the offset past which it is gone
        lda     XMH
        bne     @gone
        lda     XML
        cmp     TMP
        bcs     @gone
        lda     YMH
        bne     @gone
        lda     YML
        cmp     TMP
        bcc     @vis
@gone:  ldx     TRK                     ; (out of the window: nothing to draw - and a
        lda     RDF,x                   ;   thrown rock is gone for good: it is not
        beq     :+                      ;   coming back, and its world x would wrap)
        stz     RZL,x
        stz     RZH,x
        stz     RDF,x
:       jmp     @next
@vis:   ldx     TRK                     ; its disc, for the stars: offsets from the
        lda     SXS                     ;   centre, biased by 128 (ox right = +-XML)
        bmi     :+
        lda     #$80
        clc
        adc     XML
        bra     :++
:       lda     #$80
        sec
        sbc     XML
:       sta     RBX,x
        lda     SYS
        bmi     :+
        lda     #$80
        clc
        adc     YML
        bra     :++
:       lda     #$80
        sec
        sbc     YML
:       sta     RBY,x
        lda     RKIND,x                 ; a cloud hides nothing (ROC = 0 keeps it out of every
        beq     @ocr                    ;   rock's list of nearer discs and every star's test)
        stz     ROC,x
        bra     @ocd
@ocr:   lda     SCL                     ; the occlusion radius: 5/16 of the scale
        lsr     a                       ;   (39 of 128)
        lsr     a
        sta     TMP
        lda     SCL
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        clc
        adc     TMP
        sta     ROC,x
@ocd:   lda     SCL
        sta     RSCA,x
        lda     RSC
        sta     RSCR,x
        lda     #1
        sta     RVIS,x
        lda     RTY,x                   ; which outline: the reduced one when far
        ldy     RZH,x
        bne     @lod
        ldy     RZL,x
        cpy     #TUN_ZLOD + 1
        bcc     @sel
@lod:   clc
        adc     #4
@sel:   sta     RSEL,x
        lda     RZL,x                   ; dotted beyond TUN_ZDOT: z - (ZDOT + 1) >= 0
        cmp     #<(TUN_ZDOT + 1)
        lda     RZH,x
        sbc     #>(TUN_ZDOT + 1)
        lda     #0
        rol     a                       ; the carry: 1 = z > ZDOT
        sta     RDOT,x
        ; --- the centre (full-res fb: x = 200 + 2 oy, y = 150 - 2 ox) --------
        lda     YML                     ; 2 |oy|: |oy| <= 123, so it fits a byte
        asl     a
        sta     TMP
        lda     SYS
        bmi     @cxn
        lda     #200
        clc
        adc     TMP
        sta     RCXL,x
        lda     #0
        adc     #0
        sta     RCXH,x
        bra     @cy
@cxn:   lda     #200
        sec
        sbc     TMP
        sta     RCXL,x
        lda     #0
        sbc     #0
        sta     RCXH,x
@cy:    lda     XML
        asl     a
        sta     TMP2
        lda     SXS
        bmi     @cyp
        lda     #150                    ; ox positive (portrait right): fb y is LESS
        sec
        sbc     TMP2
        sta     RCYL,x
        lda     #0
        sbc     #0
        sta     RCYH,x
        bra     @win
@cyp:   lda     #150
        clc
        adc     TMP2
        sta     RCYL,x
        lda     #0
        adc     #0
        sta     RCYH,x
        ; --- the window's x limits (full-res fb 50..349) relative to its centre:
        ; BL = 50 - cx = -150 - 2 oy, BH = 349 - cx = 149 - 2 oy, clamped to a byte
        ; (a clamped one is a limit nothing reaches). TMP = 2 |oy|.
@win:   lda     SXS                     ; the screen's y limits (fb y 0..299) against it:
        bmi     @oxn                    ;   ox >= 0: fb y = 150 - 2|ox|, the top moves in
        lda     #127
        sta     RBB,x
        lda     TMP2
        cmp     #23
        bcc     @bt127
        sec
        sbc     #150
        bra     @btd
@bt127: lda     #$81
@btd:   sta     RBT,x
        bra     @xl
@oxn:   lda     #$81                    ; ox < 0: fb y = 150 + 2|ox|, the bottom moves in
        sta     RBT,x
        lda     TMP2
        cmp     #22
        bcc     @bb127
        lda     #149
        sec
        sbc     TMP2
        bra     @bbd
@bb127: lda     #127
@bbd:   sta     RBB,x
@xl:    lda     SYS
        bmi     @oyn
        lda     #$81                    ; oy >= 0: nothing is cut on the left...
        sta     RBL,x
        lda     TMP
        cmp     #22
        bcc     @bh127
        lda     #149
        sec
        sbc     TMP
        bra     @bhd
@bh127: lda     #127
@bhd:   sta     RBH,x
        bra     @wc
@oyn:   lda     #127                    ; oy < 0: ...and on the right
        sta     RBH,x
        lda     TMP
        cmp     #23
        bcc     @bl127
        sec
        sbc     #150
        bra     @bld
@bl127: lda     #$81
@bld:   sta     RBL,x
@wc:    stz     RWC,x                   ; does the rock cross a limit? R2 = 2 * radius
        lda     RSC
        asl     a
        sta     TMP
        lda     RBH,x                   ; BH < R2 ?
        sec
        sbc     TMP
        bvc     :+
        eor     #$80
:       bmi     @cross
        lda     RBL,x                   ; BL > -R2 ? A BL of 0 or more is (and must not
        bpl     @cross                  ;   be added to R2: 48 + 81 overflows a signed
        clc                             ;   byte, which once let a whole rock past the
        adc     TMP                     ;   HUD's frame); a negative one: BL + R2 > 0
        bmi     @next
        beq     @next
@cross: lda     #1
        sta     RWC,x
@next:  inc     TRK
        lda     TRK
        cmp     #TUN_ROCKS
        beq     @p2
        jmp     @rock
@p2:    stz     TRK                     ; pass 2: draw
@d:     ldx     TRK
        lda     RVIS,x
        beq     :+
        jsr     tun_draw_rock
:       inc     TRK
        lda     TRK
        cmp     #TUN_ROCKS
        bne     @d
        rts

; -----------------------------------------------------------------------------
; tun_hdr - the POLYGON16 block's first six bytes for rock TRK: centre, angle,
; scale. X = TRK on return.
; -----------------------------------------------------------------------------
tun_hdr:
        ldx     TRK
        stz     DOTM
        lda     RDOT,x
        beq     @solid
        inc     DOTM                    ; a far rock: DOTPOLYGON, which takes HALF-res
        lda     RCXH,x                  ;   centre and vertices (and costs the GPU less
        cmp     #$80                    ;   a segment than the solid one): the centre
        ror     a                       ;   halved, arithmetic...
        sta     RBUF+1
        lda     RCXL,x
        ror     a
        sta     RBUF+0
        lda     RCYH,x
        cmp     #$80
        ror     a
        sta     RBUF+3
        lda     RCYL,x
        ror     a
        sta     RBUF+2
        bra     @rest
@solid: lda     RCXL,x
        sta     RBUF+0
        lda     RCXH,x
        sta     RBUF+1
        lda     RCYL,x
        sta     RBUF+2
        lda     RCYH,x
        sta     RBUF+3
@rest:  lda     RAN,x                   ; its angle on the screen: its own and the roll's
        clc
        adc     THH
        sta     RBUF+4
        lda     RSCA,x
        sta     RBUF+5
        rts

; tun_vb - A = an outline byte (full-res, doubled): halved when the rock is dotted
; (its vertices are half-res, as authored).
tun_vb:
        pha                             ; (X and Y are the copy loops': keep them)
        lda     DOTM
        beq     :+
        pla
        cmp     #$80
        ror     a
        rts
:       pla
        rts

; tun_go - hand RBUF to the GPU.
tun_go:
        lda     #<RBUF
        sta     OS_ARG+0
        lda     #>RBUF
        sta     OS_ARG+1
        lda     DOTM
        bne     :+
        jmp     API_GPU_POLYGON16       ; tail
:       jmp     API_GPU_DOTPOLYGON      ; tail

; -----------------------------------------------------------------------------
; tun_sm - A = a (signed), SMB = b (signed, |b| <= 127) -> A = a * b >> 7, signed.
; Through the quarter-square qmul, which takes magnitudes (math.s). Clobbers X Y.
; -----------------------------------------------------------------------------
tun_sm:
        sta     SMA
        eor     SMB
        sta     SMG                     ; the product's sign: bit 7
        lda     SMA
        bpl     :+
        eor     #$FF
        clc
        adc     #$01
:       sta     MQA
        lda     SMB
        bpl     :+
        eor     #$FF
        clc
        adc     #$01
:       sta     MQB
        jsr     qmul
        ldx     SMG
        bpl     :+
        eor     #$FF
        clc
        adc     #$01
:       rts

; -----------------------------------------------------------------------------
; tun_hid - C SET when the point PXB/PYB (fb half-res, relative to the rock being
; drawn, biased 128) is inside the disc of any rock in NLIST. The same octagon as
; the stars'.
; -----------------------------------------------------------------------------
tun_hid:
        ldy     NCNT
@k:     dey
        bmi     @none
        ldx     NLIST,y                 ; the rock
        lda     PXB
        sec
        sbc     NBX,x
        bcs     :+
        eor     #$FF
        adc     #$01
:       cmp     ROC,x
        bcs     @k
        sta     DXM
        lda     PYB
        sec
        sbc     NBY,x
        bcs     :+
        eor     #$FF
        adc     #$01
:       cmp     ROC,x
        bcs     @k
        sta     DYM
        cmp     DXM
        bcs     @ymax
        lda     DYM
        lsr     a
        clc
        adc     DXM
        bra     @cmp
@ymax:  lda     DXM
        lsr     a
        clc
        adc     DYM
@cmp:   cmp     ROC,x
        bcs     @k
        bra     @hid
@none:  clc
        rts
@hid:   sec
        rts

; -----------------------------------------------------------------------------
; tun_ad - A = the result of an SBC of two signed bytes, flags as it left them: the
; difference reaches +-254, which a signed byte cannot hold, so the sign is N xor V
; and the magnitude the byte as unsigned, or its negation. -> A = |a - b|, SMG =
; $80 if it is negative.
; -----------------------------------------------------------------------------
tun_ad:
        sta     ADV
        bvs     @ov
        bmi     @neg
@pos:   stz     SMG
        lda     ADV
        rts
@ov:    bmi     @pos
@neg:   lda     #$80
        sta     SMG
        lda     #$00
        sec
        sbc     ADV
        rts

; tun_mul8 - MA8 * MB8 -> MPH:MPL, unsigned.
tun_mul8:
        lda     MA8
        sta     MPL
        lda     #0
        ldx     #8
        lsr     MPL
@l:     bcc     @s
        clc
        adc     MB8
@s:     ror     a
        ror     MPL
        dex
        bne     @l
        sta     MPH
        rts

; tun_div - NUMH:NUML / DEN -> NUML (the quotient, assumed < 256). DEN > 0.
tun_div:
        lda     #0
        ldx     #16
@l:     asl     NUML
        rol     NUMH
        rol     a
        bcs     @sub
        cmp     DEN
        bcc     @n
@sub:   sbc     DEN
        inc     NUML
@n:     dex
        bne     @l
        rts

; -----------------------------------------------------------------------------
; tun_cx - A = a signed x: 1 left of the window (< BLL), 2 right of it (> BHH), 0 in.
; -----------------------------------------------------------------------------
tun_cx:
        sta     TMPV
        sec
        sbc     BLL
        bvc     :+
        eor     #$80
:       bmi     @lo
        lda     BHH
        sec
        sbc     TMPV
        bvc     :+
        eor     #$80
:       bmi     @hi
        lda     #0
        rts
@lo:    lda     #1
        rts
@hi:    lda     #2
        rts

; -----------------------------------------------------------------------------
; tun_cut - cut the edge's end E = (CXE, CYE), which is outside, back to the limit
; BNB along the edge towards O = (CXO, CYO): CYE moves by (BNB - CXE) * (CYO - CYE)
; / (CXO - CXE), the signs of the first and last agreeing, so by the magnitudes and
; the sign of CYO - CYE. CXE becomes BNB.
; -----------------------------------------------------------------------------
tun_cut:
        lda     CXO
        sec
        sbc     CXE
        jsr     tun_ad
        sta     DEN                     ; |CXO - CXE|
        beq     @end                    ; (a vertical edge: nothing to cut)
        lda     BNB
        sec
        sbc     CXE
        jsr     tun_ad
        sta     MA8                     ; |BNB - CXE|
        lda     CYO
        sec
        sbc     CYE
        jsr     tun_ad
        sta     MB8                     ; |CYO - CYE|...
        lda     SMG
        sta     YSG                     ; ...and its sign
        jsr     tun_mul8
        lda     MPL
        sta     NUML
        lda     MPH
        sta     NUMH
        jsr     tun_div
        lda     YSG
        bmi     @dn
        lda     CYE
        clc
        adc     NUML
        bra     @st
@dn:    lda     CYE
        sec
        sbc     NUML
@st:    sta     CYE
@end:   lda     BNB
        sta     CXE
        rts

; -----------------------------------------------------------------------------
; tun_xclip - the edge (EX0,EY0)-(EX1,EY1) of the rock, relative to its centre, cut
; to the window's limits BLL..BHH. C SET: none of it is inside. Else the ends are
; moved onto the limits where they were outside.
; -----------------------------------------------------------------------------
tun_xclip:
        lda     EX0
        jsr     tun_cx
        sta     C0
        lda     EX1
        jsr     tun_cx
        sta     C1
        and     C0
        bne     @out                    ; both beyond the same limit
        lda     C0
        ora     C1
        beq     @in                     ; both inside
        lda     C0
        beq     @p1
        lda     EX0                     ; P0 is outside: cut it back towards P1
        sta     CXE
        lda     EY0
        sta     CYE
        lda     EX1
        sta     CXO
        lda     EY1
        sta     CYO
        lda     C0
        jsr     tun_bnd
        jsr     tun_cut
        lda     CXE
        sta     EX0
        lda     CYE
        sta     EY0
@p1:    lda     C1
        beq     @in
        lda     EX1
        sta     CXE
        lda     EY1
        sta     CYE
        lda     EX0
        sta     CXO
        lda     EY0
        sta     CYO
        lda     C1
        jsr     tun_bnd
        jsr     tun_cut
        lda     CXE
        sta     EX1
        lda     CYE
        sta     EY1
@in:    clc
        rts
@out:   sec
        rts

; -----------------------------------------------------------------------------
; tun_yclip - the same cut on y: swap x and y in the edge, cut it to the rock's RBT/RBB
; with tun_xclip, and swap back. C SET: none of it is on the screen.
; -----------------------------------------------------------------------------
tun_yclip:
        ldx     TRK
        lda     RBT,x
        sta     BLL
        lda     RBB,x
        sta     BHH
        jsr     tun_swp
        jsr     tun_xclip
        php
        jsr     tun_swp
        plp
        rts

tun_swp:
        lda     EX0
        ldx     EY0
        sta     EY0
        stx     EX0
        lda     EX1
        ldx     EY1
        sta     EY1
        stx     EX1
        rts

; tun_bnd - A = 1 or 2: BNB = the limit it names (BLL or BHH).
tun_bnd:
        cmp     #1
        bne     :+
        lda     BLL
        bra     :++
:       lda     BHH
:       sta     BNB
        rts

; tun_wx / tun_wy - OS_ARG[X..X+1] = the rock's centre x / y (rock Y) + the signed
; byte in A, as a signed 16 bit.
tun_wx:
        sta     TMPV
        clc
        adc     RCXL,y
        sta     OS_ARG,x
        lda     #0
        bit     TMPV
        bpl     :+
        lda     #$FF
:       adc     RCXH,y
        sta     OS_ARG+1,x
        rts
tun_wy:
        sta     TMPV
        clc
        adc     RCYL,y
        sta     OS_ARG,x
        lda     #0
        bit     TMPV
        bpl     :+
        lda     #$FF
:       adc     RCYH,y
        sta     OS_ARG+1,x
        rts

; tun_line - a solid LINE16 of the edge EX0,EY0 - EX1,EY1 of rock TRK.
tun_line:
        ldy     TRK
        lda     EX0
        ldx     #0
        jsr     tun_wx
        lda     EY0
        ldx     #2
        jsr     tun_wy
        lda     EX1
        ldx     #4
        jsr     tun_wx
        lda     EY1
        ldx     #6
        jsr     tun_wy
        jmp     API_GPU_LINE16          ; tail

; -----------------------------------------------------------------------------
; tun_verts - rock TRK's outline on the window: every vertex as the GPU will place
; it (x = dx*C - dy*S, y = dx*S + dy*C, C and S being cos and sin of its angle times
; the scale), full-res relative to its centre in VXF/VYF and half-res biased in
; VXB/VYB. If NCNT is not 0, each vertex and each edge's midpoint is tested against
; those rocks' discs and EV[i] = 1 says edge i (vertex i to i + 1) shows; else every
; edge does. Sets VOFF and NV.
; -----------------------------------------------------------------------------
tun_verts:
        ldx     TRK
        lda     RSEL,x
        tay
        lda     TSHO,y
        sta     VOFF
        lda     TSHN,y
        sta     NV
        lda     RAN,x                   ; C and S: cos and sin of the angle (its own and
        clc                             ;   the roll's) times the scale (128 read as 127:
        adc     THH                     ;   a byte of Q0.7)
        jsr     API_COS
        sta     CCV
        ldx     TRK
        lda     RAN,x
        clc
        adc     THH
        jsr     API_SIN
        sta     SSV
        ldx     TRK
        lda     RSCA,x
        cmp     #128
        bcc     :+
        lda     #127
:       sta     SMB
        lda     CCV
        jsr     tun_sm
        sta     CSV
        lda     SSV
        jsr     tun_sm
        sta     SNV
        ldx     #0                      ; every vertex, on the window
        ldy     VOFF
@v:     lda     TSHP,y
        sta     VDX
        lda     TSHP+1,y
        sta     VDY
        sty     VCNT                    ; (X and Y are clobbered by tun_sm: the
        stx     EVC                     ;   vertex's place in TSHP and its index
                                        ;   live here for the length of this loop)
        lda     VDX                     ; qx = dx*C - dy*S
        ldy     CSV
        sty     SMB
        jsr     tun_sm
        pha
        lda     VDY
        ldy     SNV
        sty     SMB
        jsr     tun_sm
        sta     RT2
        pla
        sec
        sbc     RT2
        ldy     EVC
        sta     VXF,y
        cmp     #$80                    ; full-res -> half-res, arithmetic
        ror     a
        eor     #$80                    ; biased
        sta     VXB,y
        lda     VDX                     ; qy = dx*S + dy*C
        ldy     SNV
        sty     SMB
        jsr     tun_sm
        pha
        lda     VDY
        ldy     CSV
        sty     SMB
        jsr     tun_sm
        sta     RT2
        pla
        clc
        adc     RT2
        ldy     EVC
        sta     VYF,y
        cmp     #$80
        ror     a
        eor     #$80
        sta     VYB,y
        ldy     VCNT
        iny
        iny
        ldx     EVC
        inx
        cpx     NV
        beq     :+
        jmp     @v
:       lda     NCNT
        bne     @occ
        ldx     NV                      ; nothing in front: every edge shows
        dex
        lda     #1
:       sta     EV,x
        dex
        bpl     :-
        rts
@occ:   ldx     #0                      ; the vertices against the discs
:       stx     EVC
        lda     VXB,x
        sta     PXB
        lda     VYB,x
        sta     PYB
        jsr     tun_hid
        lda     #0
        rol     a                       ; C -> 0/1
        ldx     EVC
        sta     HV,x
        inx
        cpx     NV
        bne     :-
        ldx     #0                      ; the midpoints, and the edges
@m:     stx     EVC
        inx
        cpx     NV
        bcc     :+
        ldx     #0
:       lda     VXB,x                   ; the next vertex, wrapping
        ldy     EVC
        clc
        adc     VXB,y
        ror     a                       ; (carry in: the 9-bit sum halved)
        sta     PXB
        lda     VYB,x
        clc
        adc     VYB,y
        ror     a
        sta     PYB
        stx     TMP                     ; the next vertex's index
        jsr     tun_hid
        lda     #0
        rol     a
        ldx     EVC
        sta     HM,x
        ldy     TMP                     ; visible: this vertex, the next, and the middle
        lda     HV,x
        ora     HV,y
        ora     HM,x
        eor     #1
        and     #1
        sta     EV,x
        inx
        cpx     NV
        bne     @m
        rts

; -----------------------------------------------------------------------------
; tun_draw_rock - rock TRK. Which NEARER rocks overlap it (NLIST)? Does it cross the
; window's limits (RWC)? Neither: one closed POLYGON16. Only the first: its edges
; that nothing hides are drawn as runs - OPEN polygons from the same raw vertices.
; The second (with or without the first): each edge that shows is drawn as its own
; LINE16, cut to the window. Nothing visible: nothing drawn.
; -----------------------------------------------------------------------------
tun_draw_rock:
        ldx     TRK
        lda     RKIND,x
        beq     :++
        cmp     #2
        bne     :+
        jmp     tun_draw_pod            ; a lifepod (tunnel_pod.s)
:       jmp     tun_draw_cloud          ; a Saturnium cloud: pixels
:       stz     NCNT
        ldy     #TUN_NDISC - 1
@n:     cpy     TRK
        bne     :+
        jmp     @nn
:       ldx     TRK
        lda     ROC,y
        beq     @nn
        lda     RZL,y                   ; nearer: z_n < z_f, 16 bit
        cmp     RZL,x
        lda     RZH,y
        sbc     RZH,x
        bcs     @nn
        lda     RBY,y                   ; the fb x distance between the two centres
        sec
        sbc     RBY,x
        bcs     :+
        eor     #$FF
        adc     #$01
:       sta     DXM
        lda     RBX,y
        sec
        sbc     RBX,x
        bcs     :+
        eor     #$FF
        adc     #$01
:       sta     DYM
        cmp     DXM
        bcs     @ymax
        lda     DYM
        lsr     a
        clc
        adc     DXM
        bra     @cmp
@ymax:  lda     DXM
        lsr     a
        clc
        adc     DYM
@cmp:   sta     TMP
        lda     ROC,y
        clc
        adc     RSCR,x                  ; the two radii
        cmp     TMP
        bcc     @nn                     ; apart
        beq     @nn
        lda     RBY,y                   ; where its disc is, fb half-res, biased
        sec
        sbc     RBY,x
        clc
        adc     #$80
        sta     NBX,y
        lda     RBX,x                   ; (fb y is the OPPOSITE of portrait x)
        sec
        sbc     RBX,y
        clc
        adc     #$80
        sta     NBY,y
        ldx     NCNT                    ; one more nearer rock overlapping it
        tya
        sta     NLIST,x
        inc     NCNT
@nn:    dey
        bmi     :+
        jmp     @n
:       ldx     TRK
        lda     RWC,x
        bne     @xclip
        lda     NCNT
        bne     @occ
        jmp     tun_closed              ; nothing in front, nothing cut: the whole outline
@occ:   jsr     tun_verts
        jmp     tun_runs
@xclip: jsr     tun_verts
        stz     EI
@e:     ldx     TRK                     ; (the limits are loaded again for every edge:
        lda     RBL,x                   ;   the y cut below borrows BLL and BHH)
        sta     BLL
        lda     RBH,x
        sta     BHH
        ldx     EI
        lda     EV,x
        beq     @skip                   ; hidden by a nearer rock
        lda     VXF,x
        sta     EX0
        lda     VYF,x
        sta     EY0
        inx
        cpx     NV
        bcc     :+
        ldx     #0
:       lda     VXF,x
        sta     EX1
        lda     VYF,x
        sta     EY1
        jsr     tun_xclip
        bcs     @skip
        jsr     tun_yclip               ; ...and to the screen's top and bottom
        bcs     @skip
        jsr     tun_line
@skip:  inc     EI
        lda     EI
        cmp     NV
        bne     @e
        rts

; -----------------------------------------------------------------------------
; tun_runs - draw the runs of visible edges EV[] of rock TRK as OPEN polygons.
; -----------------------------------------------------------------------------
tun_runs:
        ldx     #$FF                    ; an invisible edge to start from...
        stx     EVS
        stz     EVC                     ; ...and how many show
        ldx     #0
@cnt:   lda     EV,x
        beq     :+
        inc     EVC
        bra     :++
:       stx     EVS                     ; (the last invisible one will do)
:       inx
        cpx     NV
        bne     @cnt
        lda     EVC
        beq     @done                   ; nothing shows
        lda     EVS
        bmi     @whole                  ; nothing hides: the closed outline
        lda     #$FF
        sta     RUNS
        ldx     EVS
        ldy     NV                      ; examine NV edges: EVS+1 .. EVS (wrapping)
@w:     inx
        cpx     NV
        bcc     :+
        ldx     #0
:       lda     EV,x
        beq     @inv
        lda     RUNS
        bpl     :+
        stx     RUNS                    ; a run begins at this edge's first vertex
:       stx     RUNE
        inc     RUNE                    ; ...and ends at its second
        lda     RUNE
        cmp     NV
        bcc     @nx2
        stz     RUNE
        bra     @nx2
@inv:   lda     RUNS
        bmi     @nx2
        phx
        phy
        jsr     tun_run                 ; a run is over: draw it
        ply
        plx
        lda     #$FF
        sta     RUNS
@nx2:   dey
        bne     @w
@done:  rts
@whole: jmp     tun_closed              ; nearer rocks, but they hide none of it

; -----------------------------------------------------------------------------
; tun_closed - rock TRK as one CLOSED POLYGON16: the whole authored outline.
; -----------------------------------------------------------------------------
tun_closed:
        jsr     tun_hdr
        lda     RSEL,x
        tay
        lda     TSHO,y
        sta     VOFF
        lda     TSHN,y
        sta     RBUF+6
        asl     a
        sta     VCNT
        ldx     #0
        ldy     VOFF
:       lda     TSHP,y
        jsr     tun_vb
        sta     RBUF+7,x
        iny
        inx
        cpx     VCNT
        bne     :-
        jmp     tun_go

; -----------------------------------------------------------------------------
; tun_run - an OPEN POLYGON16 of the vertices RUNS .. RUNE (wrapping) of rock TRK.
; -----------------------------------------------------------------------------
tun_run:
        jsr     tun_hdr
        lda     RUNE
        sec
        sbc     RUNS
        bcs     :+
        adc     NV                      ; wrapped
:       clc
        adc     #1                      ; K vertices
        sta     VCNT
        ora     #$80                    ; OPEN: K vertices, K - 1 segments
        sta     RBUF+6
        lda     RUNS
        asl     a
        clc
        adc     VOFF
        tay                             ; the first vertex's bytes in TSHP
        ldx     #0
        lda     RUNS
        sta     TMP                     ; its index, to know when to wrap
@c:     lda     TSHP,y
        jsr     tun_vb
        sta     RBUF+7,x
        lda     TSHP+1,y
        jsr     tun_vb
        sta     RBUF+8,x
        inx
        inx
        iny
        iny
        inc     TMP
        lda     TMP
        cmp     NV
        bcc     :+
        stz     TMP                     ; past the last vertex: back to the first
        ldy     VOFF
:       dec     VCNT
        bne     @c
        jmp     tun_go

        .include "tunnel_pod.s"         ; the lifepods: TUNCODE3 (bank 11, run behind the rocks) and TUNBSS
        .segment "TUNCODE3"
        .include "tunnel_hud.s"         ; the instruments and what the tunnel gives back: TUNCODE3

        .segment "TUNCODE"
; -----------------------------------------------------------------------------
; tun_catch - cloud TRK has been caught: the sector's own Saturnium sound, the tally up,
; the cloud gone.
; -----------------------------------------------------------------------------
tun_catch:
        lda     #SE_SATN
        jsr     sfx_fire
        inc     TSAT                    ; (a count, for the bench)
        jsr     tun_hud_cloud           ; the hold and the score (tunnel_hud.s)
        ldx     TRK
        stz     RZL,x
        stz     RZH,x
        rts

; -----------------------------------------------------------------------------
; tun_draw_cloud - cloud TRK as one DOT_PIXELS: 8 + 3/16 of its scale pixels (8 far, 32 at
; the camera), each a place from the pattern (CLDP) times its radius (a rock's, RSCR),
; round its centre; those outside the window or behind a rock are dropped.
; -----------------------------------------------------------------------------
tun_draw_cloud:
        ldx     TRK
        lda     RSCA,x
        lsr     a
        lsr     a
        lsr     a
        sta     TMP
        lda     RSCA,x
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        clc
        adc     TMP
        clc
        adc     #TUN_CLOUDMIN
        sta     CK                      ; how many pixels
        lda     RSCR,x
        sta     SMB                     ; its radius, half-res px
        lda     RCXH,x                  ; the centre, half-res: the full-res one halved
        cmp     #$80
        ror     a
        sta     CHXH
        lda     RCXL,x
        ror     a
        sta     CHXL
        lda     RCYH,x
        cmp     #$80
        ror     a
        sta     CHYH
        lda     RCYL,x
        ror     a
        sta     CHYL
        lda     RZL,x                   ; its depth, for the rocks that may hide it
        sta     T3L
        lda     RZH,x
        sta     T3H
        lda     RAN,x                   ; where in the pattern it starts: it drifts
        lsr     a
        lsr     a
        and     #31
        sta     CIDX
        stz     CDN
@p:     lda     CIDX
        asl     a
        tax
        lda     CLDP,x                  ; dx: its offset in fb x
        jsr     tun_sm                  ; * the radius >> 7
        sta     TMV
        clc
        adc     CHXL
        sta     CPXL
        lda     #0
        bit     TMV
        bpl     :+
        lda     #$FF
:       adc     CHXH
        sta     CPXH
        lda     CIDX
        asl     a
        tax
        lda     CLDP+1,x                ; dy
        jsr     tun_sm
        sta     TMV
        clc
        adc     CHYL
        sta     CPYL
        lda     #0
        bit     TMV
        bpl     :+
        lda     #$FF
:       adc     CHYH
        sta     CPYH
        lda     CPXH                     ; in the window? fb x 25..174, y 0..149
        ora     CPYH
        bne     @skip
        lda     CPXL
        cmp     #25
        bcc     @skip
        cmp     #175
        bcs     @skip
        lda     CPYL
        cmp     #150
        bcs     @skip
        lda     #75                     ; behind a rock? the offsets from the window's centre
        sec
        sbc     CPYL
        sta     OXS
        lda     CPXL
        sec
        sbc     #100
        sta     OYS
        jsr     tun_occ0
        bcs     @skip
        lda     CDN
        asl     a
        tax
        lda     CPXL
        sta     CLB+1,x
        lda     CPYL
        sta     CLB+2,x
        inc     CDN
@skip:  inc     CIDX
        lda     CIDX
        and     #31
        sta     CIDX
        dec     CK
        beq     :+
        jmp     @p
:       lda     CDN
        beq     @done
        sta     CLB
        lda     #<CLB
        sta     OS_ARG+0
        lda     #>CLB
        sta     OS_ARG+1
        jmp     API_GPU_DOTPIXELS       ; tail
@done:  rts

; -----------------------------------------------------------------------------
; tun_hit - rock TRK has struck the ship. HXM/HYM, SXS/SYS: how far, and on which side
; (SXS/SYS $80 = the rock is left of / above the ship).
; -----------------------------------------------------------------------------
tun_hit:
        inc     HITS
        jsr     tun_hud_hit             ; a hit costs Saturnium (tunnel_hud.s)
        lda     #SE_KLANG               ; the sector's own ram: metal on stone, both halves
        jsr     sfx_fire
        lda     #SE_KLANG_N
        jsr     sfx_fire
        lda     #TUN_RUMBLE
        jsr     rumble_pulse
        lda     #TUN_SHAKE
        sta     SHK
        lda     SXS                     ; the side each axis is on; dead ahead on one: at random
        sta     KSX
        lda     HXM
        cmp     #2
        bcs     :+
        jsr     prng
        and     #$80
        sta     KSX
:       lda     SYS
        sta     KSY
        lda     HYM
        cmp     #2
        bcs     :+
        jsr     prng
        and     #$80
        sta     KSY
:       ldx     TRK
        lda     #1
        sta     RDF,x
        lda     #TUN_DEFL               ; the rock goes AWAY from the ship: the side it is
        ldy     KSX                     ;   on, in view, turned into the world (R(-TH))
        bpl     :+
        lda     #<(-TUN_DEFL)
:       sta     RXL
        asl     a                       ; spinning faster the way it was thrown
        sta     RSP,x
        lda     RXL
        jsr     tun_sx
        sta     RXH
        lda     #TUN_DEFL
        ldy     KSY
        bpl     :+
        lda     #<(-TUN_DEFL)
:       sta     RYL
        jsr     tun_sx
        sta     RYH
        jsr     tun_roti
        ldx     TRK
        lda     RQXL
        sta     RVX,x
        lda     RQYL
        sta     RVY,x
        lda     KSX                     ; the ship is knocked the OPPOSITE way: across, by
        eor     LY                      ;   the roll. A turn dTH moves a thing near the ship
        bmi     @kl                     ;   by -LY dTH in view x, so a rock on the right
        sec                             ;   (KSX clear) with LY >= 0 goes away when TH
        lda     WLO                     ;   falls - the rate is knocked down - and each of
        sbc     #<TUN_RKICK             ;   the two signs flips it
        sta     WLO
        lda     WHI
        sbc     #>TUN_RKICK
        sta     WHI
        bra     @ky
@kl:    clc
        lda     WLO
        adc     #<TUN_RKICK
        sta     WLO
        lda     WHI
        adc     #>TUN_RKICK
        sta     WHI
@ky:    lda     KSY                     ; ...and along, by the lean's spring
        bmi     @kd
        lda     VHI+1
        sec
        sbc     #TUN_KICK
        sta     VHI+1
        rts
@kd:    lda     VHI+1
        clc
        adc     #TUN_KICK
        sta     VHI+1
        rts

; -----------------------------------------------------------------------------
; tun_pay - the hold the tunnel kept (TSATN: the sector's, plus the clouds, less the hits)
; back into SATN (satn.s, under the window). The window is borrowed for the one write.
; -----------------------------------------------------------------------------
tun_pay:
        jsr     win_off
        lda     TSATN
        sta     SATN
        jmp     win_on                  ; tail

; -----------------------------------------------------------------------------
; tun_jit - A = amplitude (0-6) -> A = a random signed jitter within +-amplitude.
; -----------------------------------------------------------------------------
tun_jit:
        sta     TMV
        jsr     prng
        and     #15
        sec
        sbc     #8                      ; -8..7
        sta     RT2
        lda     #0
        ldx     TMV
        beq     @d
@l:     clc
        adc     RT2
        dex
        bne     @l
@d:     cmp     #$80                    ; >> 3, arithmetic
        ror     a
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        rts

; -----------------------------------------------------------------------------
; tun_hum_init - the program's fixed bytes: noise (type 1), four steps of four frames.
; -----------------------------------------------------------------------------
tun_hum_init:
        ldy     #1                      ; Y = 1 + 3 * step: where a step begins
        ldx     #4
@i:     lda     #4
        sta     HUMP,y                  ; frames
        lda     #TUN_HUMM
        sta     HUMP+1,y                ; the noise mode
        lda     #TUN_HUMV
        sta     HUMP+2,y                ; the volume
        iny
        iny
        iny
        dex
        bne     @i
        ldy     #1
        ldx     #4
@q:     lda     #2
        sta     HUMQ,y                  ; the whine: four steps of two frames (the last three), silent
        lda     #0
        sta     HUMQ+2,y
        iny
        iny
        iny
        dex
        bne     @q
        lda     #3
        sta     HUMQ+10                 ; (the last step overlaps the re-fire by a frame: no gap)
        lda     #$FF
        sta     HUMP+13
        sta     HUMQ+13
        lda     #1
        sta     HUMP+0
        stz     HUMQ+0
        rts

; -----------------------------------------------------------------------------
; tun_hum - the engine: on the timer, write the next 16 frames of the program (4 steps
; of 4 frames, each from the rush's clock plus 2 per step: RUSHR counts every second
; frame) and fire it - unless a ram holds the noise voice.
; -----------------------------------------------------------------------------
tun_hum:
        dec     HUMT
        beq     @go
        rts
@go:    lda     VLEN+3                  ; sfx.s's claim on the noise voice
        beq     @free
        lda     #1
        sta     HUMT                    ; a ram is sounding: try again next frame
        rts
@free:  lda     #TUN_HUMP
        sta     HUMT
        stz     TMV                     ; the step
        ldy     #1
@k:     lda     RUSHR
        beq     @r1                     ; before the rush: no rise at all (A = 0)
        sta     RT2
        lda     TMV
        asl     a
        clc
        adc     RT2                     ; r = RUSHR + 2 * step
@r1:    sta     RT2
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a                       ; 0..2 over the rush: a faster noise every 64
        sta     TMP
        lda     #TUN_HUMM
        sec
        sbc     TMP
        sta     HUMP+1,y                ; the mode
        lda     RT2
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a                       ; 0..2: a step louder every 64
        clc
        adc     #TUN_HUMV
        sta     HUMP+2,y                ; the volume
        lda     RT2                     ; the whine: silent until TUN_WHINES, then fading in
        sec
        sbc     #TUN_WHINES
        bcs     @w
        lda     #0
        sta     HUMQ+2,y
        sta     HUMQ+1,y
        bra     @wd
@w:     lsr     a
        lsr     a
        lsr     a
        lsr     a                       ; a step of volume every 16 clock units...
        clc
        adc     #1
        cmp     #5
        bcc     :+
        lda     #5                      ; ...up to 5 (it was 8: too loud)
:       pha                             ; TREMOLO: every other step one quieter
        lda     TMV
        and     #1
        beq     @t0
        pla
        sec
        sbc     #1
        bra     @t1
@t0:    pla
@t1:    sta     HUMQ+2,y
        lda     RT2
        lsr     a
        sta     TA                      ; r / 2, times 68, over 128: r * 68 / 256 semitones
        lda     #68
        sta     TB
        phy
        jsr     umul
        ply
        lda     PL
        asl     a
        lda     PH
        rol     a
        clc
        adc     #TUN_WHINEN
        sta     TMP2                    ; the base note
        lda     TMV                     ; VIBRATO: steps 0, 2 on the note, 1 above it and 3
        and     #1                      ;   below by d semitones - the 8-frame pattern repeats
        beq     @vz                     ;   with every re-fire, 7.5 Hz, and d widens with the
        lda     RUSHR                   ;   rush: 1, 2 then 3
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        clc
        adc     #1
        ldx     TMV
        cpx     #3
        bne     @vp
        eor     #$FF
        clc
        adc     #1
@vp:    clc
        adc     TMP2
        bra     @vs
@vz:    lda     TMP2
@vs:    sta     HUMQ+1,y                ; its note
@wd:    iny
        iny
        iny
        inc     TMV
        lda     TMV
        cmp     #4
        beq     :+
        jmp     @k
:       lda     RUSHR
        cmp     #TUN_WHINES
        bcc     @nw
        lda     #<HUMQ                  ; the whine first, on tone voice 0...
        ldx     #>HUMQ
        ldy     #0
        jsr     API_SFX_PLAY_PTR
@nw:    lda     #<HUMP                  ; ...and the noise
        ldx     #>HUMP
        ldy     #$FF                    ; the effects chip's noise voice
        jmp     API_SFX_PLAY_PTR        ; tail

; tun_hum_off - silence it: the noise program cut to one frame at volume 0.
tun_hum_off:
        stz     HUMQ+3                  ; the whine: one frame, silent
        lda     #1
        sta     HUMQ+1
        lda     #$FF
        sta     HUMQ+4
        lda     #<HUMQ
        ldx     #>HUMQ
        ldy     #0
        jsr     API_SFX_PLAY_PTR
        lda     #1
        sta     HUMP+1
        stz     HUMP+3
        lda     #$FF
        sta     HUMP+4
        lda     #<HUMP
        ldx     #>HUMP
        ldy     #$FF
        jmp     API_SFX_PLAY_PTR

; -----------------------------------------------------------------------------
; tun_streak - the dust star at offsets OXS/OYS as a LINE from its tail to its head,
; the tail being nearer the centre by |o| * FRAC / 256 on each axis: a single pixel at
; the start of the rush (FRAC = 0), growing to half the distance to the centre.
; -----------------------------------------------------------------------------
tun_streak:
        ldx     RUSHR
        lda     FRAC,x
        sta     SHV
        lda     OXS                     ; x: |ox| * FRAC / 256, rounded
        bpl     :+
        eor     #$FF
        clc
        adc     #$01
:       sta     TA
        lda     SHV
        sta     TB
        jsr     umul
        lda     PL
        cmp     #$80                    ; the rounding bit into carry
        lda     PH
        adc     #0
        sta     TMP                     ; the tail's pull toward the centre
        lda     OXS
        bmi     @xn
        sec
        sbc     TMP
        bra     @xd
@xn:    clc
        adc     TMP
@xd:    sta     TMP2                    ; the tail's ox
        lda     OYS                     ; y, the same
        bpl     :+
        eor     #$FF
        clc
        adc     #$01
:       sta     TA
        lda     SHV
        sta     TB
        jsr     umul
        lda     PL
        cmp     #$80
        lda     PH
        adc     #0
        sta     TMP
        lda     OYS
        bmi     @yn
        sec
        sbc     TMP
        bra     @yd
@yn:    clc
        adc     TMP
@yd:    clc
        adc     #TUN_CX                 ; the tail: fb x = 100 + oy, fb y = 75 - ox
        sta     OS_ARG+0
        lda     #TUN_CY
        sec
        sbc     TMP2
        sta     OS_ARG+1
        lda     OYS                     ; the head
        clc
        adc     #TUN_CX
        sta     OS_ARG+2
        lda     #TUN_CY
        sec
        sbc     OXS
        sta     OS_ARG+3
        jmp     API_GPU_LINE            ; tail

; -----------------------------------------------------------------------------
; tun_far_init - TUN_FAR random places in the disc round the window's centre that
; covers it (radius 105, half-res px), so that the roll turning them leaves no corner
; empty: an angle at random, and a radius max(u, v) * 105 - the larger of two uniform
; picks has twice the density at twice the radius, which is what a disc wants. About
; half of them are in the window at a time (the square is half the disc's... less: 64%).
; -----------------------------------------------------------------------------
tun_far_init:
        ldx     #TUN_FAR - 1
@i:     stx     TI
        jsr     prng
        ldx     TI
        sta     FARA,x
        jsr     prng
        sta     TMP
        jsr     prng
        cmp     TMP
        bcs     :+
        lda     TMP
:       lsr     a                       ; (0..127) * 106 >> 7
        sta     TA
        lda     #106
        sta     TB
        jsr     umul
        lda     PL
        asl     a
        lda     PH
        rol     a
        ldx     TI
        sta     FARR,x
        dex
        bpl     @i
        rts

; tun_fmul - A = a signed Q0.7, X = TI: FARR * A >> 7, rounded, signed.
tun_fmul:
        sta     TMV
        jsr     tun_abs
        sta     TB
        lda     FARR,x
        sta     TA
        jsr     umul
        lda     PL
        clc
        adc     #64
        sta     PL
        lda     PH
        adc     #0
        asl     PL                      ; (P + 64) >> 7: bit 7 of the sum's low byte...
        rol     a                       ; ...in at the bottom
        ldx     TMV
        bpl     :+
        eor     #$FF
        clc
        adc     #$01
:       rts

; -----------------------------------------------------------------------------
; tun_far_frame - the far stars into the DOT_PIXELS payload (DI, DN): turned with the
; roll (at infinity a turn is all that moves them, and the lean a little: LY >> FSH),
; the ones in the window kept, and hidden by any rock in front.
; -----------------------------------------------------------------------------
tun_far_frame:
        lda     LY
        ldy     #TUN_FSH
@sh:    cmp     #$80
        ror     a
        dey
        bne     @sh
        sta     FSY
        lda     #$FF                    ; at infinity: behind every rock
        sta     T3L
        sta     T3H
        stz     TI
@f:     ldx     TI
        lda     FARA,x                  ; ox = r cos(a + TH), oy = r sin(a + TH) - FSY
        clc
        adc     THH
        sta     TMP2
        jsr     API_COS
        ldx     TI
        jsr     tun_fmul
        sta     OXS
        jsr     tun_abs
        cmp     #TUN_HALF
        bcs     @n
        lda     TMP2
        jsr     API_SIN
        ldx     TI
        jsr     tun_fmul
        sec
        sbc     FSY                     ; (moving the camera down moves them up)
        sta     OYS
        jsr     tun_abs
        cmp     #TUN_HALF
        bcs     @n
        jsr     tun_occ0
        bcs     @n
        ldy     DI
        lda     #TUN_CX                 ; fb x = centre + (portrait down)
        clc
        adc     OYS
        sta     DOTB,y
        iny
        lda     #TUN_CY                 ; fb y = centre - (portrait right)
        sec
        sbc     OXS
        sta     DOTB,y
        iny
        sty     DI
        inc     DN
@n:     inc     TI
        lda     TI
        cmp     #TUN_FAR
        bne     @f
        rts

; -----------------------------------------------------------------------------
; tun_stars_init - every star born, and then given a depth of its own so the
; first frame is already a field, not a wall of stars arriving together.
; -----------------------------------------------------------------------------
tun_stars_init:
        stz     CAMX
        stz     CAMY
        stz     CXH
        stz     CYH
        stz     LY
        stz     WLO                     ; the roll at rest, upright
        stz     WHI
        stz     THL
        stz     THH
        jsr     tun_trig
        ldx     #1                      ; the lean at rest, in the middle
@z:     stz     PLO,x
        stz     PHI,x
        stz     VLO,x
        stz     VHI,x
        dex
        bpl     @z
        jsr     tun_rocks_init
        jsr     tun_far_init
        ldx     #TUN_STARS - 1
@lp:    stx     TI
        jsr     tun_born
        jsr     prng
        cmp     #TUN_ZMIN + 1
        bcs     :+
        lda     #TUN_ZMIN + 1
:       ldx     TI
        sta     SZ,x
        dex
        bpl     @lp
        rts

; -----------------------------------------------------------------------------
; tun_stars_frame - move every star, project it, and draw the ones in the window
; with one DOT_PIXELS. A star that is out, or too near, is born again at once.
; -----------------------------------------------------------------------------
tun_stars_frame:
        stz     DN
        lda     #1
        sta     DI
        stz     TI
@star:  ldx     TI
        lda     SZ,x
        sec
        sbc     SPD
        sta     SZ,x
        bcc     @dead                   ; (past the camera: the rush's speed outruns ZMIN)
        cmp     #TUN_ZMIN
        bcc     @dead
        sta     TZ
        lda     SX,x                    ; rel = x - cam, 16 bit...
        sec
        sbc     CAMX
        sta     RXL
        lda     SXH,x
        sbc     CXH
        sta     RXH
        lda     SY,x
        sec
        sbc     CAMY
        sta     RYL
        lda     SYH,x
        sbc     CYH
        sta     RYH
        jsr     tun_rot                 ; ...turned with the world
        lda     RQXL
        ldx     RQXH
        jsr     tun_projs
        bcs     @dead
        sta     OXS
        lda     RQYL
        ldx     RQYH
        jsr     tun_projs
        bcs     @dead
        sta     OYS
        jsr     tun_occ                 ; behind a rock: not drawn, still alive
        bcs     @next
        lda     RUSHR                   ; in the rush: a streak, not a pixel
        beq     @pix
        jsr     tun_streak
        bra     @next
@pix:   ldy     DI
        lda     #TUN_CX                 ; fb x = centre + (portrait down)
        clc
        adc     OYS
        sta     DOTB,y
        iny
        lda     #TUN_CY                 ; fb y = centre - (portrait right)
        sec
        sbc     OXS
        sta     DOTB,y
        iny
        sty     DI
        inc     DN
        bra     @next
@dead:  jsr     tun_born
@next:  inc     TI
        lda     TI
        cmp     #TUN_STARS
        beq     :+
        jmp     @star
:       jsr     tun_far_frame           ; the far stars join the same DOT_PIXELS
        lda     DN
        beq     @ret
        sta     DOTB
        lda     #<DOTB
        sta     OS_ARG+0
        lda     #>DOTB
        sta     OS_ARG+1
        jmp     API_GPU_DOTPIXELS       ; tail
@ret:   rts

; -----------------------------------------------------------------------------
; tunnel_frame - the whole frame while SCR_STATE is SC_TUNNEL.
; -----------------------------------------------------------------------------
tunnel_frame:
        jsr     frame_services          ; the pad's rumble and the sound layer's clock (the
                                        ;   claims on its voices age here: frame_body gives
                                        ;   a state that is not the field none of it)
        lda     SCR_PH
        bne     @p1
        lda     #VR_BLIND_ON            ; step 0: dark, and the field, the radar
        jsr     API_GPU_VREG            ;   ring and the HUD off the background
        jsr     API_GPU_CLEARBG
        jsr     API_VGM_STOP            ; no music in the tunnel (the title theme plays from
                                        ;   power-on until something stops it)
        jsr     tun_hud_init            ; (before the stars: the pods count the ships lost)
        jsr     tun_stars_init
        stz     SHK
        stz     ACCF
        lda     #1
        sta     HUMT
        jsr     tun_hum_init
        stz     SC_PTRL
        stz     SC_PTRH
        jmp     @next
@p1:    cmp     #1                      ; step 1: the clear's replay lands
        bne     @p2
        jsr     @tick
        bcs     :+
        rts
:
        ldx     #TUN_ART_HUD            ; (step 2, on the same frame it lands:
        jsr     tun_art_arm             ;   the rectangle is armed, nothing sent)
        lda     #3
        sta     SCR_PH
        stz     SCR_T                   ; art_step's replay flag starts clear
        rts
@p2:    cmp     #3                      ; step 3: the cockpit's bands
        bne     @p4
        jsr     tun_art_step
        bcc     :+
        rts
:       jmp     @next
@p4:    cmp     #4                      ; step 4: their replay lands - then the
        beq     :+                      ;   blinder comes off on a finished
        jmp     @fly                    ;   cockpit
:       jsr     @tick
        bcs     :+
        rts
:       lda     #VR_BLIND_OFF
        jsr     API_GPU_VREG
        jsr     tun_hud_start           ; the rows under the window paint from now on
        jmp     @next

@fly:   stz     RUSHR                   ; step 5: the rush's clock, in units of 2 frames:
        lda     SC_PTRL                 ;   (f - (TUN_FRAMES - TUN_RUSHF)) >> 1, plus 1
        sec
        sbc     #<(TUN_FRAMES - TUN_RUSHF)
        tax
        lda     SC_PTRH
        sbc     #>(TUN_FRAMES - TUN_RUSHF)
        bcc     :+                      ; not yet
        lsr     a
        txa
        ror     a
        clc
        adc     #1                      ; (1..TUN_RUSH: it is 0 only before the rush)
        sta     RUSHR
:       jsr     tun_hum                 ; the engine, then this frame's speed (2, 3, 2...)
        lda     SC_PTRL                 ;   plus the rush's eased extra
        and     #1
        clc
        adc     #TUN_SPEED
        sta     SPD
        ldx     RUSHR
        lda     RSPT,x                  ; extra speed in 1/16: the fraction is carried
        clc
        adc     ACCF
        pha
        and     #15
        sta     ACCF
        pla
        ror     a                       ; (the sum's ninth bit in: 255 + 15 overflows)
        lsr     a
        lsr     a
        lsr     a                       ; ...and the whole units added
        clc
        adc     SPD
        sta     SPD
        asl     a
        sta     SPD2
        jsr     tun_lean_frame          ;   the lean, the rocks, then the stars
        jsr     tun_rocks_frame         ;   (the rocks first: their discs hide stars)
        jsr     tun_stars_frame         ;   it moves...
        jsr     tun_pod_arrows          ;   (a lifepod's arrows: last, over everything)
        jsr     tun_hud_frame           ; the rows under the window, the hull, the sparks
.if TUNTEST
        ldx     JOYPORT                 ; ...and FIRE skips to the rush - in make run-tunnel
        lda     JOY1_PRESS,x            ;   only: in the game no button does anything here
        and     #JOY_FIRE               ;   (the user, 2026-10-15)
        beq     @nof
        lda     JOY1_PRESS,x
        and     #<~JOY_FIRE
        sta     JOY1_PRESS,x
        lda     SC_PTRL                 ; (forward only: in the rush already, it does nothing)
        cmp     #<(TUN_FRAMES - TUN_RUSHF - 60)
        lda     SC_PTRH
        sbc     #>(TUN_FRAMES - TUN_RUSHF - 60)
        bcs     @nof
        lda     #<(TUN_FRAMES - TUN_RUSHF - 60)
        sta     SC_PTRL
        lda     #>(TUN_FRAMES - TUN_RUSHF - 60)
        sta     SC_PTRH
@nof:
.endif
        inc     SC_PTRL
        bne     :+
        inc     SC_PTRH
:       lda     SC_PTRL
        cmp     #<TUN_FRAMES
        bne     @ret
        lda     SC_PTRH
        cmp     #>TUN_FRAMES
        bne     @ret
@leave: jsr     tun_pay
        jsr     tun_hum_off
        ldx     JOYPORT
        lda     JOY1_PRESS,x            ; consume the edge, or the press that
        and     #<~JOY_FIRE             ;   ends this also fires the gun on the
        sta     JOY1_PRESS,x            ;   next sector's first frame
.if TUNTEST
        stz     SCR_PH                  ; make run-tunnel has no sector to go to:
        stz     SCR_T                   ;   fly it again from the dark
        rts
.endif
        ldx     CURLEV                  ; the next sector, as sector_frame does
        inx
        cpx     #NLEVELS
        bcc     :+
        ldx     #$00
:       stx     CURLEV
        ldx     #FE_NEXTSECTOR          ; a tail JMP, never a jsr: this code is
        jmp     set_state_field         ;   about to be overwritten (overlay.s)
@ret:   rts

@next:  inc     SCR_PH
        stz     SCR_T
        rts

; SETTLE frames for a background write's replay to land. C SET when they have.
@tick:  inc     SCR_T
        lda     SCR_T
        cmp     #SETTLE
        rts

; The tunnel's run-area tenants (TUNCODE2, TUNBSS) must end below the kernel (CODE8): the
; kernel stays resident across the overlay, and CODE8 moves whenever the engine grows.
        .import __TUNBSS_RUN__, __TUNBSS_SIZE__, __CODE8_RUN__, __HUDCODE_RUN__
        .assert __TUNBSS_RUN__ + __TUNBSS_SIZE__ <= __HUDCODE_RUN__, lderror, "tunnel.s: TUNCODE2/3 + TUNBSS run into the HUD (HUDCODE), which the tunnel calls - cart.cfg"
        .assert __TUNBSS_RUN__ + __TUNBSS_SIZE__ <= __CODE8_RUN__, lderror, "tunnel.s: TUNCODE2 + TUNBSS run into the kernel (CODE8) - cart.cfg's TUNRUN"

        .popseg
