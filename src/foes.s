; =============================================================================
; foes.s - the enemies. One kind so far: the UFO.
; =============================================================================
; The UFO is the classic Asteroids saucer - the SHAPE is a homage (enemies.s),
; and it never turns: ANGLE 0, always drawn the way the editor shows it, while
; the zoom scales it like everything else. What it DOES is this game's own:
;
;   PATROL   the course and speed its level record gave it (levels.s), or, at
;            speed 0, holding its post - a spring back to an anchor point.
;   PURSUE   the moment it SEES the ship - within FOE_SEE, which is the height
;            of the resting screen, 400 px = 6,400 world units - it turns toward
;            it at FOE_SPD, half the ship's top speed, and holds FOE_STAND away
;            rather than ramming. The first one to see it sounds the ALARM
;            (three beeps, ENEMY DETECTED) - the first, because a pack that has
;            already found you does not need to say so again. It does NOT fire
;            yet: only once it has closed to FOE_SHOOT, and the first shot waits
;            FOE_FIRST after that. From then on it fires once a second while the
;            ship stays that close, aimed at where the ship IS: no lead, so a
;            ship that keeps moving is rarely hit.
;   LOSE     past FOE_LOSE, twice the sight, it gives up - and it is put
;            straight back on its patrol course and speed, from wherever the
;            chase left it. The gap between the two radii is the hysteresis:
;            with one radius a ship parked on it would flip the UFO every frame.
;
; ...and whatever it is doing it never flies into a rock, another UFO or the
; ship - foe_avoid. That runs on patrol too, because a UFO the player catches
; sitting inside a rock reads as a bug, not as a patrol.
;
; UNITS, and why the sight is a WORLD distance. The zoom changes how many world
; units a screen pixel is (16 at rest, 32 all the way out); it does not change
; the world. FOE_SEE is fixed in world units, so a UFO sees the same distance
; however the camera is set - at rest that reaches past the edges of the screen
; (the ship sits 70 px below centre: 270 px ahead, 130 behind, 150 each side),
; which is why a bullet can come from off screen and why fsh_all lets one live
; FSH_MIN frames before the screen may kill it. Fully zoomed out, a UFO can be
; on screen and not yet see you.
;
; A UFO's BULLET is the gun's bullet (shots.s): same line, same speed, same
; screen cull, drawn with the same command. It is killed the moment it leaves
; the screen once it has been ON it - there is nothing left for it to do out
; there - and one fired from off screen gets FSH_MIN frames to arrive first.
; It hits the ship (one hit point, ship_hurt, exactly as a rock), and it breaks
; rocks the way the gun does, for no score (FOEKILL). Bullets do not collide
; with bullets.
;
; THE PLAYER'S BULLETS hit a UFO on the screen, against the same swept test the
; rocks get (shots.s shot_dnarrow / shot_swept). FOE_HP hits, SCORE_FOE_HIT a
; hit and SCORE_FOE_KILL on top for the last one - the killing blow pays both,
; as a rock's does. A dead UFO comes apart the way the ship does (debris.s):
; each of its PARTS flies off as one piece and tumbles (fw_*).
;
; RAMMING. A ship that flies into a UFO pays one hit point (ship_hurt, with
; FOE_RAMCD frames before that UFO can charge it again) and the UFO is shoved
; out of the way; the UFO takes no damage from it - the rocks' rule, where the
; ship pays and the rock's own hit point is off by request (physics.s).
;
; WHERE THE TIME GOES. The enemies are simulated over the WHOLE field
; (design_technical 11.21), and thinking - seeing, steering, looking for rocks
; - is the expensive half: measured on the preview flight it was 11,700 of the
; 19,300 cycles do_foes first cost. So nothing thinks every frame. A UFO near
; the camera thinks every 2^FOE_SNEAR frames, and the obstacle zone's margin
; is already wider than anything can close in two (16 collision units against
; two frames of a split chip and a UFO, 11). One far outside the coarse window
; (FOE_FARPG pages past CULH) thinks every 2^FOE_SFAR, with FOE_LOOK added to
; its zone - sound because every rock out there is FROZEN (6.1), and a static
; obstacle cannot move into a UFO between two looks. Both are staggered by slot
; and scale the acceleration by the frames they skip. Integration is every
; frame for all of them. A UFO well off the screen also skips its screen
; transform for a few frames (FOESLP), the rocks' sleep in miniature.
; =============================================================================

; --- tunables - physics.md 9 is where these are argued; all of them are TBM --
FOE_REC     = 7                 ; bytes a level spends on one enemy (levels.s)
FK_UFO      = 0                 ; KIND 0 is the UFO, the only kind with a
                                ;   behaviour; load_foes skips any other
FS_DEAD     = 0                 ; FOEST: an empty or destroyed slot
FS_PATROL   = 1
FS_PURSUE   = 2

FOE_R       = 9                 ; the UFO's circle, collision units (32 world
                                ;   units = one half-res px): 18 full-res px,
                                ;   the hull's 20 across and the dome's 15 up
                                ;   meeting in the middle - the mean-vertex
                                ;   compromise the rocks and the ship make too.
                                ;   Rounded UP from 8.75: it was 7 with a shape
                                ;   0.8 of this one, too small next to the ship
                                ;   to hit; 1.5x that was too big, so 1.25x
FOE_HP      = 3
FOE_SEE     = 400*16            ; sees within this: the resting screen's
                                ;   height, in world units
FOE_LOSE    = 2*FOE_SEE         ; ...and gives up the chase past this
FOE_SHOOT   = 220*16            ; ...but only FIRES within this - it closes in
                                ;   first. It was FOE_SEE, and flown that read
                                ;   as being shot at the instant it saw you
FOE_STAND   = 160*16            ; the chase holds this far off. Closer than it,
                                ;   the UFO backs away (at most FOE_BACK)
FOE_SPD     = $2E6C             ; the chase, 8.8 world units a frame: 46.4 =
                                ;   175 px/s, half TIER_SPD's top row ($5CD8)
FOE_BACK    = FOE_SPD/2
FOE_ACC     = $00C0             ; how fast its velocity may change, per axis,
                                ;   8.8 a frame: rest to FOE_SPD in ~62 frames,
                                ;   so it turns in an arc, not a corner
FOE_VCAP    = $4000             ; ...and the most it may ever carry, per axis
FOE_MARGIN  = 16                ; the obstacle ZONE: an obstacle's radius plus
                                ;   the UFO's plus this, collision units - 32 px
                                ;   of clear space. FOE_R + this may not pass
                                ;   25, or a near UFO's reach grows past 8 pages
                                ;   (FOE_HIWN) and its cell walk past 2x2
FOE_LOOK    = 12                ; ...plus this for a far UFO: 2^FOE_SFAR frames
                                ;   of FOE_SPD, 368 world units, rounded up
FOE_VTMIN   = $1000             ; the least speed it slides ROUND an obstacle
                                ;   with, 8.8: 16 units a frame, 60 px/s - what
                                ;   stops a UFO heading dead at a rock stopping
                                ;   dead against it
FOE_FARPG   = 16                ; pages past the coarse cull window before a
                                ;   UFO counts as far (the window moves 6 pages
                                ;   in eight frames of boost)
FOE_SNEAR   = 1                 ; a near UFO thinks every 2^this frames...
FOE_SFAR    = 3                 ; ...and a far one every 2^this
FOE_SLPM    = 104               ; a UFO further off the screen than this, px,
                                ;   skips its transform for FOE_SLPN frames -
FOE_SLPN    = 2                 ;   +1 on odd slots. 64 px past the draw margin
                                ;   covers three frames of a boost, 43 px
FOE_FIRE    = 60                ; frames between shots: one a second
FOE_FIRST   = 60                ; ...and before the first, counted from the
                                ;   moment it gets within FOE_SHOOT, plus a
                                ;   stagger by slot
FOE_RAMCD   = 30                ; frames before the same UFO can hurt a ship
                                ;   that rammed it again
FOE_MUZZ    = 384               ; where its bullet starts: 24 px out along the
                                ;   aim, clear of its own circle
FOE_OCC     = 8                 ; the stars go out inside this, half-res px
FOE_SMARG   = 40                ; draw it this far past the screen edge
SCORE_FOE_HIT  = 50
SCORE_FOE_KILL = 100

FSH_N       = 8                 ; enemy bullets in flight at once
FSH_MIN     = 60                ; frames one fired from OFF screen lives before
                                ;   the screen may take it - so a pursuer can
                                ;   reach a ship it cannot yet draw

FW_N        = 4                 ; wreck pieces at once: two UFOs' worth
FW_FRAMES   = 90                ; how long a wreck is drawn
FW_K        = 28                ; launch: a piece's pivot offset from the shape's
                                ;   middle times this, 8.8 px a frame
FW_JIT      = 32                ; ...plus +/- this on each component
FW_SPIN     = 2                 ; ...and +/- this brad a frame of tumble

; --- derived ------------------------------------------------------------------
FOE_ZMAX    = COL_RMAX + FOE_R + FOE_MARGIN + FOE_LOOK
                                ; the widest zone there is, collision units
FOE_HIW     = (FOE_ZMAX*32 + 255) / 256
                                ; ...and in position-high-byte pages, for the
                                ;   coarse reject (physics.s COL_HIW's rule)
FOE_HIWN    = ((COL_RMAX + FOE_R + FOE_MARGIN)*32 + 255) / 256
                                ; ...and a NEAR UFO's, which has no FOE_LOOK:
                                ;   8 pages, so its cell walk is always 2x2
FOE_SEEH    = FOE_SEE/256 + 1   ; a high-byte gap this big cannot be in sight
FSH_HIW     = (COL_RMAX*32 + 255) / 256 + 1
                                ; the bullet's own: a rock's radius, plus a page
                                ;   for the half-frame it looks back along
FOE_PUSHN   = (FOE_SPD + 767) / 768
                                ; penetration at which the outward push reaches
                                ;   FOE_SPD (the push is 3 units a frame a cu)

        .assert 2*FOE_ZMAX <= 255, error, "foes.s: 2 * the widest zone must index QS"
        .assert FOE_ZMAX < 128, error, "foes.s: a zone must fit a signed byte of collision units"
        .assert FOE_SNEAR <= FOE_SFAR && FOE_SFAR <= 3, error, "foes.s: FE_PMASK and FE_ACCL have four rows"
        .assert (FOE_ACC << FOE_SFAR) < $8000, error, "foes.s: the far acceleration must stay a positive signed 16"
        .assert FOE_HIW < 16 && FSH_HIW < 16, error, "foes.s: fe_cells reaches one cell each way at most"
        .assert FOE_HIWN <= 8, error, "foes.s: a near UFO's cell walk must stay 2x2 - trim FOE_MARGIN"
        .assert 2*FOE_SLPM < 256, error, "foes.s: f_onscr doubles its margin in a byte"
        .assert (FW_JIT & (FW_JIT-1)) = 0, error, "foes.s: FW_JIT must be a power of two - the jitter is an AND"
        .assert FSH_N <= 8 && FW_N <= 8, error, "foes.s: the bullet and wreck arrays are eight apart"
        .assert FOE_MAX <= 16, error, "foes.s: the FOE arrays are sixteen apart"
        .assert 3*FOE_PUSHN < 128, error, "foes.s: the push's high byte must stay a positive signed byte"
        .assert SHIP_RAD*SHIP_RAD*2 < 256, error, "foes.s: fsh_in sums two squares in one byte"

; --- state, UNDER THE CARTRIDGE WINDOW ($9100-$95FF) ---------------------------
; The RAM under $8000-$9FFF reads back only while CART_EN is clear (window.s),
; so every reader of what follows runs inside cart_frame's win_off bracket:
; do_foes, radar_foes and load_foes (game_start), and nothing here is touched
; by the IRQ or by code running from the window - window.s's two rules. The
; 4 KB beside the object pool was free; OBJSLP ends at $90FE. The position,
; KIND and count stay where radar.s put them ($6F00, NFOE).
FOEXF       = $9100             ; position fractions - FOEXL..FOEYH are radar.s's
FOEYF       = $9110
FOEVXL      = $9120             ; velocity, signed 8.8 world units a frame
FOEVXH      = $9130
FOEVYL      = $9140
FOEVYH      = $9150
FOEPVXL     = $9160             ; ...the patrol velocity it is put back on
FOEPVXH     = $9170
FOEPVYL     = $9180
FOEPVYH     = $9190
FOEAXL      = $91A0             ; the post a speed-0 UFO holds, world 16-bit
FOEAXH      = $91B0
FOEAYL      = $91C0
FOEAYH      = $91D0
FOEST       = $91E0             ; FS_*
FOEHP       = $91F0
FOECD       = $9200             ; frames until it may fire again
FOERAM      = $9210             ; frames until a ram can hurt the ship again
FOEFXL      = $9220             ; this frame's full-res screen centre...
FOEFXH      = $9230
FOEFYL      = $9240
FOEFYH      = $9250
FOEON       = $9260             ; ...valid while this is 1
FOEPSPD     = $9270             ; the patrol speed, px/s - 0 holds a post
FOESLP      = $9280             ; frames left before its screen transform
                                ;   runs again, 0 = every frame
FOENEW      = $9290             ; 1 until its first think, which then runs on
                                ;   the very next frame whatever its phase: a
                                ;   level can put a UFO on top of a scattered
                                ;   rock, and a far one would otherwise sit in
                                ;   it for up to 2^FOE_SFAR frames

FSLIVE      = $9300             ; the enemy bullets, eight apart. 0 = free
FSXF        = $9308             ; world position, 16.8, the gun's layout
FSXL        = $9310
FSXH        = $9318
FSYF        = $9320
FSYL        = $9328
FSYH        = $9330
FSVXL       = $9338             ; world velocity, 16.8: fraction, low, top
FSVXH       = $9340
FSVXT       = $9348
FSVYL       = $9350
FSVYH       = $9358
FSVYT       = $9360
FSANG       = $9368             ; the world heading it was fired along
FSAGE       = $9370             ; frames alive, saturating at 255
FSSEEN      = $9378             ; 1 once it has been on the screen
FSPDX       = $9380             ; last frame's offset from the ship, collision
FSPDY       = $9388             ;   units, for the swept test against the ship
FSPOK       = $9390             ; ...valid while this is 1

FWN         = $9400             ; the wreck pieces, eight apart. Frames left
FWPART      = $9408             ; which part of the shape it is
FWAXL       = $9410             ; the world point it is anchored to
FWAXH       = $9418
FWAYL       = $9420
FWAYH       = $9428
FWPXL       = $9430             ; its SCREEN offset from there, 8.8 full-res px
FWPXH       = $9438             ;   - screen, like the ship's wreck, because
FWPYL       = $9440             ;   the UFO lives in screen orientation
FWPYH       = $9448
FWVXL       = $9450             ; ...and how far that moves a frame
FWVXH       = $9458
FWVYL       = $9460
FWVYH       = $9468
FWANG       = $9470             ; tumble, brad
FWSPN       = $9478
FWCX        = $9480             ; the part's pivot, signed full-res px
FWCY        = $9488

; scratch, $9500 on
FEI         = $9500             ; the UFO being thought about
FEJ         = $9501             ; an inner index (another UFO, or a rock)
FEFAR       = $9502             ; 1 = this UFO thinks at the far rate
FEDXL       = $9503             ; ship - UFO, world 16-bit, signed...
FEDXH       = $9504
FEDYL       = $9505
FEDYH       = $9506
FEAXL       = $9507             ; ...and its magnitudes
FEAXH       = $9508
FEAYL       = $9509
FEAYH       = $950A
FEDL        = $950B             ; the distance, max + 3/8 min, world units
FEDH        = $950C
FEANG       = $950D             ; the bearing to the ship, brad
FESIN       = $950E             ; ...its sine and cosine
FECOS       = $950F
FEVXL       = $9510             ; the velocity it WANTS, 8.8
FEVXH       = $9511
FEVYL       = $9512
FEVYH       = $9513
FEACCL      = $9514             ; this think's acceleration limit
FEACCH      = $9515
FET0        = $9516             ; general scratch
FET1        = $9517
FET2        = $9518
FET3        = $9519
FETL        = $951A             ; foe_cu's input
FETH        = $951B
FETX        = $951C             ; an offset in collision units, signed
FETY        = $951D
FEADX       = $951E             ; ...and its magnitudes
FEADY       = $951F
FERS        = $9520             ; the candidate's radius sum
FEZE        = $9521             ; what the zone adds to it: FOE_MARGIN(+LOOK)
FEZ         = $9522             ; the candidate's zone
FEOVL       = $9523             ; 1 = the candidate is touching
FEE2        = $9524             ; 2|d|, estimated
FEP         = $9525             ; how deep into its zone the UFO is
FEBP        = $9526             ; THE WORST SO FAR: its depth (0 = none)...
FEBTX       = $9527             ; ...its offset...
FEBTY       = $9528
FEBRS       = $9529             ; ...radius sum, 2|d|, touching...
FEBE2       = $952A
FEBOV       = $952B
FEOBXL      = $952C             ; the candidate's world position
FEOBXH      = $952D
FEOBYL      = $952E
FEOBYH      = $952F
FEBOXL      = $9530             ; ...and the worst one's
FEBOXH      = $9531
FEBOYL      = $9532
FEBOYH      = $9533
FES         = $9534             ; the normal's shift and reciprocal
FEQ         = $9535
FENX        = $9536             ; the unit normal, obstacle -> UFO, Q0.7
FENY        = $9537
FEVNL       = $9538             ; velocity along it...
FEVNH       = $9539
FEVTL       = $953A             ; ...and across it
FEVTH       = $953B
FEMN        = $953C             ; f_ratio's smaller operand
FEUXH       = $953D             ; the high bytes the cell walk centres on
FEUYH       = $953E
FECX        = $953F             ; fe_cells' cursor
FEROW       = $9540
FECOL       = $9541
FENEXT      = $9542
FERN        = $9543
FECN        = $9544
FSI         = $9545             ; the bullet being moved
FESHX       = $9546             ; half its frame's travel, collision units
FESHY       = $9547
FESQL       = $9548             ; a sum of squares
FESQH       = $9549
FEK         = $954A             ; a small count
FELN        = $954B             ; load_foes' record countdown
FEVEC       = $954C             ; fe_cells' callback, 2 bytes
FEREC       = $9550             ; a level record, staged: FOE_REC bytes
FEWI        = $9557             ; the wreck: which piece...
FEWP        = $9558             ; ...which part
FEWV        = $9559             ; the vertex cursor
FEWJ        = $955A             ; the part's vertex count
FEWW        = $955B             ; ...counted down
FEWMN       = $955C             ; the box being measured, EXCESS-128
FEWMX       = $955D
FEWOX       = $955E             ; the whole shape's middle
FEWOY       = $955F
FEWK        = $9560             ; fw_scale's shifting FW_K
FEWT0       = $9561
FEWT1       = $9562
FEWR0       = $9563             ; ...and its product
FEWR1       = $9564
FEWA        = $9565             ; fw_centre's axis
FEPER       = $9566             ; this UFO's think period, as a shift
FEPOS       = $9567             ; fe_cells: where in its cell, in pages
FECN0       = $9568             ; ...how many columns
FEHIW       = $9569             ; ...and the reach it is walking for, pages
FEOBK       = $956A             ; the candidate's kind: 0 ship, 1 UFO, 2 rock...
FEOBI       = $956B             ; ...and which one
FEBK        = $956C             ; ...and the worst one's
FEBI        = $956D
FEOVXL      = $956E             ; the worst one's velocity, 8.8
FEOVXH      = $956F
FEOVYL      = $9570
FEOVYH      = $9571
FEVOL       = $9572             ; ...along or across the normal
FEVOH       = $9573
        .assert FEREC + FOE_REC <= FEWI, error, "foes.s: FEREC ran into the wreck scratch"

; =============================================================================
; do_foes - the whole of the enemies, once a frame.
; =============================================================================
; AFTER do_shots, and the order matters: the player's bullets have already been
; moved and put on the screen (so foe_hits can test them), the rocks have
; already been moved and relinked (so the obstacle walk sees this frame's
; field), and nothing is standing on a cell list, so a bullet of ours that
; breaks a rock may relink the grid. BEFORE do_stars, which reads the star
; suppression discs foe_draw_all registers.
;
;   think      see, decide, steer, avoid - and integrate, every UFO
;   screen     where each one is on the screen, if it is
;   hits       the player's bullets against the ones that are
;   draw       what survived, and its hole in the starfield
;   bullets    the UFOs' own: fly, hit, draw
;   wreck      what is left of the ones that did not survive
; =============================================================================
        .segment "CODE2"

do_foes:
        jsr     foe_think_all
        jsr     foe_screen_all
        jsr     foe_hits
        jsr     foe_draw_all
        jsr     fsh_all
        jmp     fw_all

; -----------------------------------------------------------------------------
; foe_think_all - every live UFO: age its timers, think, integrate.
; -----------------------------------------------------------------------------
foe_think_all:
        lda     NFOE
        bne     :+
        rts
:       dec     a
        sta     FEI
@lp:    ldx     FEI
        lda     FOEST,x
        beq     @next
        lda     FOECD,x                 ; the timers age every frame, thinking
        beq     :+                      ;   or not
        dec     FOECD,x
:       lda     FOERAM,x
        beq     :+
        dec     FOERAM,x
:       jsr     foe_think
        ldx     FEI
        jsr     foe_integrate
@next:  dec     FEI
        bpl     @lp
        rts

; -----------------------------------------------------------------------------
; foe_think - X = FEI. Near the camera: every 2^FOE_SNEAR frames. Far: every
; 2^FOE_SFAR. Either way on its own phase.
; -----------------------------------------------------------------------------
foe_think:
        stz     FEFAR
        lda     #FOE_SNEAR
        sta     FEPER
        lda     FOEYH,x
        sta     FEUYH
        lda     FOEXH,x
        sta     FEUXH
        sec
        sbc     SHXH
        jsr     absa
        sec
        sbc     CULH+0                  ; how far past the coarse window, x
        bcc     @xin
        cmp     #FOE_FARPG
        bcs     @far
@xin:   lda     FEUYH
        sec
        sbc     SHYH
        jsr     absa
        sec
        sbc     CULH+1                  ; ...and y
        bcc     @phase
        cmp     #FOE_FARPG
        bcc     @phase
@far:   inc     FEFAR
        lda     #FOE_SFAR
        sta     FEPER
@phase: lda     FOENEW,x                ; just loaded: think NOW
        beq     :+
        stz     FOENEW,x
        bra     @go
:       ldy     FEPER                   ; its own phase, so they do not all
        lda     FEI                     ;   think on the same frame
        clc
        adc     FRAME
        and     FE_PMASK,y
        beq     @go
        rts
@go:    jsr     foe_seek
        jsr     foe_steer
        jmp     foe_avoid

; -----------------------------------------------------------------------------
; foe_dist - FEDX/FEDY = ship - UFO, FEAX/FEAY their magnitudes, FED the
; distance. X = FEI.
; -----------------------------------------------------------------------------
; max + min/4 + min/8 - "alpha max plus beta min", good to about 7% and never a
; square root. The wrap is free: the subtract read as signed is the short way
; round the torus, and the magnitudes are at most 32768 so the sum cannot
; leave an unsigned 16-bit.
; -----------------------------------------------------------------------------
foe_dist:
        ldx     FEI
        sec
        lda     SHXL
        sbc     FOEXL,x
        sta     FEDXL
        sta     FEAXL
        lda     SHXH
        sbc     FOEXH,x
        sta     FEDXH
        sta     FEAXH
        bpl     :+
        sec
        lda     #$00
        sbc     FEAXL
        sta     FEAXL
        lda     #$00
        sbc     FEAXH
        sta     FEAXH
:       sec
        lda     SHYL
        sbc     FOEYL,x
        sta     FEDYL
        sta     FEAYL
        lda     SHYH
        sbc     FOEYH,x
        sta     FEDYH
        sta     FEAYH
        bpl     :+
        sec
        lda     #$00
        sbc     FEAYL
        sta     FEAYL
        lda     #$00
        sbc     FEAYH
        sta     FEAYH
:       lda     FEAXL                   ; which is the larger
        cmp     FEAYL
        lda     FEAXH
        sbc     FEAYH
        bcc     @ymax
        lda     FEAXL
        sta     FEDL
        lda     FEAXH
        sta     FEDH
        lda     FEAYL
        sta     FET0
        lda     FEAYH
        sta     FET1
        bra     @sum
@ymax:  lda     FEAYL
        sta     FEDL
        lda     FEAYH
        sta     FEDH
        lda     FEAXL
        sta     FET0
        lda     FEAXH
        sta     FET1
@sum:   lsr     FET1                    ; + min/4
        ror     FET0
        lsr     FET1
        ror     FET0
        clc
        lda     FEDL
        adc     FET0
        sta     FEDL
        lda     FEDH
        adc     FET1
        sta     FEDH
        lsr     FET1                    ; + min/8
        ror     FET0
        clc
        lda     FEDL
        adc     FET0
        sta     FEDL
        lda     FEDH
        adc     FET1
        sta     FEDH
        rts

; -----------------------------------------------------------------------------
; foe_seek - see, lose, and decide what velocity it wants (FEV).
; -----------------------------------------------------------------------------
foe_seek:
        ldx     FEI
        lda     SHIPGONE                ; no ship: nothing to see
        bne     @lose
        lda     FOEST,x
        cmp     #FS_PURSUE
        beq     @look
        lda     FEUXH                   ; on patrol and out of sight on the
        sec                             ;   high bytes alone: it sees nothing,
        sbc     SHXH                    ;   and the distance is not worth
        jsr     absa                    ;   working out
        cmp     #FOE_SEEH
        bcs     @patrol
        lda     FEUYH
        sec
        sbc     SHYH
        jsr     absa
        cmp     #FOE_SEEH
        bcs     @patrol
@look:  jsr     foe_dist
        ldx     FEI
        lda     FOEST,x
        cmp     #FS_PURSUE
        beq     @chase
        lda     FEDL                    ; on patrol: is the ship in sight?
        cmp     #<FOE_SEE
        lda     FEDH
        sbc     #>FOE_SEE
        bcs     @patrol
        lda     #FS_PURSUE              ; SEEN. It turns now and shoots later:
        sta     FOEST,x                 ;   the first shot waits FOE_FIRST, plus
        txa                             ;   a stagger by slot, so a pack that
        asl     a                       ;   spots the ship on the same frame
        asl     a                       ;   does not fire on the same frame
        asl     a
        and     #$1F
        clc
        adc     #FOE_FIRST
        sta     FOECD,x
        jsr     foe_alarm               ; ...and says so, if nobody has yet
        jmp     foe_chase
@chase: lda     FEDL                    ; in pursuit: still close enough to hold
        cmp     #<(FOE_LOSE+1)          ;   on to it?
        lda     FEDH
        sbc     #>(FOE_LOSE+1)
        bcs     @lose
        jmp     foe_chase
@lose:  lda     FOEST,x
        cmp     #FS_PURSUE
        bne     @patrol
        jsr     foe_reset               ; lost it: back on its own course
@patrol:
        jmp     foe_patrol

; foe_reset - the chase is over. Velocity back to the patrol's, AT ONCE - "reset
; its speed and heading" - and the post it holds is wherever it now is.
foe_reset:
        ldx     FEI
        lda     #FS_PATROL
        sta     FOEST,x
        lda     FOEPVXL,x
        sta     FOEVXL,x
        lda     FOEPVXH,x
        sta     FOEVXH,x
        lda     FOEPVYL,x
        sta     FOEVYL,x
        lda     FOEPVYH,x
        sta     FOEVYH,x
        lda     FOEXL,x
        sta     FOEAXL,x
        lda     FOEXH,x
        sta     FOEAXH,x
        lda     FOEYL,x
        sta     FOEAYL,x
        lda     FOEYH,x
        sta     FOEAYH,x
        rts

; foe_patrol - the course it was given, or, at speed 0, a spring back to its
; post: (post - here) / 32 a frame, capped at FOE_SPD. The spring is what brings
; it home after a rock has pushed it aside.
foe_patrol:
        ldx     FEI
        lda     FOEPSPD,x
        beq     @hold
        lda     FOEPVXL,x
        sta     FEVXL
        lda     FOEPVXH,x
        sta     FEVXH
        lda     FOEPVYL,x
        sta     FEVYL
        lda     FOEPVYH,x
        sta     FEVYH
        rts
@hold:  sec
        lda     FOEAXL,x
        sbc     FOEXL,x
        sta     FET0
        lda     FOEAXH,x
        sbc     FOEXH,x
        sta     FET1
        jsr     foe_spring
        lda     FET0
        sta     FEVXL
        lda     FET1
        sta     FEVXH
        ldx     FEI
        sec
        lda     FOEAYL,x
        sbc     FOEYL,x
        sta     FET0
        lda     FOEAYH,x
        sbc     FOEYH,x
        sta     FET1
        jsr     foe_spring
        lda     FET0
        sta     FEVYL
        lda     FET1
        sta     FEVYH
        rts

; foe_spring - FET0/FET1, a signed world offset, -> x8 as 8.8 (i.e. /32 a
; frame), clamped to +/-FOE_SPD.
foe_spring:
        lda     FET1
        bmi     @neg
        lda     FET0
        cmp     #<(FOE_SPD/8)
        lda     FET1
        sbc     #>(FOE_SPD/8)
        bcs     @max
        bra     @x8
@neg:   lda     FET0                    ; two negatives compare correctly as
        cmp     #<(-(FOE_SPD/8))        ;   unsigned
        lda     FET1
        sbc     #>(-(FOE_SPD/8))
        bcc     @min
@x8:    asl     FET0
        rol     FET1
        asl     FET0
        rol     FET1
        asl     FET0
        rol     FET1
        rts
@max:   lda     #<FOE_SPD
        sta     FET0
        lda     #>FOE_SPD
        sta     FET1
        rts
@min:   lda     #<(-FOE_SPD)
        sta     FET0
        lda     #>(-FOE_SPD)
        sta     FET1
        rts

; -----------------------------------------------------------------------------
; foe_chase - toward the ship, at the speed foe_speed picks, and the gun.
; -----------------------------------------------------------------------------
foe_chase:
        jsr     foe_atan                ; FEANG: the bearing to the ship
        lda     FEANG
        jsr     API_SIN
        sta     FESIN
        lda     FEANG
        jsr     API_COS
        sta     FECOS
        jsr     foe_speed               ; FET2/FET3: how fast, signed
        lda     FET2                    ; forward is (sin, -cos), main.s's
        sta     MAL                     ;   convention for the ship too
        lda     FET3
        sta     MAH
        lda     FESIN
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     FEVXL
        lda     MAH
        sta     FEVXH
        lda     FET2
        sta     MAL
        lda     FET3
        sta     MAH
        lda     FECOS
        sta     MB
        jsr     smul16q7
        sec
        lda     #$00
        sbc     MAL
        sta     FEVYL
        lda     #$00
        sbc     MAH
        sta     FEVYH

        ldx     FEI                     ; ...and the gun, once it is CLOSE
        lda     FEDL
        cmp     #<FOE_SHOOT
        lda     FEDH
        sbc     #>FOE_SHOOT
        bcc     @close
        txa                             ; not yet: the wind-up is held full, so
        asl     a                       ;   the first shot comes FOE_FIRST after
        asl     a                       ;   it closes in, not after it saw you -
        asl     a                       ;   staggered by slot as at the sighting
        and     #$1F
        clc
        adc     #FOE_FIRST
        sta     FOECD,x
        rts
@close: lda     FOECD,x                 ; close: once a second
        bne     @done
        jsr     fsh_fire
        bcs     @done                   ; no free bullet: try again next frame
        ldx     FEI
        lda     #FOE_FIRE
        sta     FOECD,x
@done:  rts

; foe_speed - FET2/FET3 = the speed the chase wants, signed 8.8, out of FED:
; FOE_SPD from FOE_SPD/8 units past the stand-off out, ramping down to 0 on it,
; and backing away (to -FOE_BACK) inside it. The ramp is x8, so the whole
; approach decelerates over ~93 px rather than stopping on a line.
foe_speed:
        sec
        lda     FEDL
        sbc     #<FOE_STAND
        sta     FET2
        lda     FEDH
        sbc     #>FOE_STAND
        sta     FET3
        bcc     @close                  ; closer than the stand-off
        lda     FET2
        cmp     #<(FOE_SPD/8)
        lda     FET3
        sbc     #>(FOE_SPD/8)
        bcs     @full
        bra     @x8
@close: lda     FET2                    ; negative here, and so is the bound
        cmp     #<(-(FOE_BACK/8))
        lda     FET3
        sbc     #>(-(FOE_BACK/8))
        bcc     @back
@x8:    asl     FET2
        rol     FET3
        asl     FET2
        rol     FET3
        asl     FET2
        rol     FET3
        rts
@full:  lda     #<FOE_SPD
        sta     FET2
        lda     #>FOE_SPD
        sta     FET3
        rts
@back:  lda     #<(-FOE_BACK)
        sta     FET2
        lda     #>(-FOE_BACK)
        sta     FET3
        rts

; -----------------------------------------------------------------------------
; foe_atan - FEANG = the bearing of (FEDX, FEDY), in the ship's convention: the
; heading whose forward (sin, -cos) points along it. From the magnitudes FEAX,
; FEAY and the two signs.
; -----------------------------------------------------------------------------
; No divide and no big table. Both magnitudes are shifted down together until
; they fit seven bits; the ratio of the smaller to the larger is then one
; RECIP64 read and one quarter-square product (f_ratio - col_respond's own
; normalisation, physics.s); and the angle inside the octant is ATAN_T, 129
; bytes. The octant and the quadrant come back off the comparison and the
; signs. Good to a brad (1.4 degrees), which is far finer than the aim needs.
; -----------------------------------------------------------------------------
foe_atan:
        lda     FEAXL
        sta     FET0
        lda     FEAXH
        sta     FET1
        lda     FEAYL
        sta     FET2
        lda     FEAYH
        sta     FET3
@dn:    lda     FET1
        ora     FET3
        bne     @sh
        lda     FET0
        ora     FET2
        bpl     @small
@sh:    lsr     FET1
        ror     FET0
        lsr     FET3
        ror     FET2
        bra     @dn
@small: lda     FET0
        cmp     FET2
        bcs     @xbig
        ldx     FET0                    ; |dy| the larger: theta = atan(|dx|/|dy|)
        lda     FET2
        jsr     f_ratio
        tay
        lda     ATAN_T,y
        bra     @quad
@xbig:  lda     FET0                    ; |dx| the larger: 64 - atan(|dy|/|dx|)
        beq     @quad                   ;   (both 0: any bearing will do)
        ldx     FET2
        jsr     f_ratio
        tay
        lda     ATAN_T,y
        eor     #$FF                    ; 64 - t is ~t + 65
        sec
        adc     #64
@quad:  sta     FET1                    ; theta, measured from the y axis
        lda     FEDXH
        bmi     @left
        lda     FEDYH
        bmi     @q0
        lda     #128                    ; +x, +y: 128 - theta
        sec
        sbc     FET1
        bra     @done
@q0:    lda     FET1                    ; +x, -y: theta
        bra     @done
@left:  lda     FEDYH
        bmi     @q3
        lda     #128                    ; -x, +y: 128 + theta
        clc
        adc     FET1
        bra     @done
@q3:    lda     #$00                    ; -x, -y: -theta
        sec
        sbc     FET1
@done:  sta     FEANG
        rts

; f_ratio - A = the larger magnitude, 1..127, X = the smaller -> A = 128 *
; smaller / larger, 0..128. Clobbers X, Y.
f_ratio:
        stx     FEMN
        ldy     #$00
@up:    cmp     #65                     ; the larger into [65, 128]...
        bcs     @ok
        asl     a
        iny
        bra     @up
@ok:    sty     FES
        sec
        sbc     #65
        tax
        lda     RECIP64,x               ; ...8192 / it...
        sta     MQB
        lda     FEMN                    ; ...and the smaller shifted the same
        ldy     FES
        beq     @go
@l:     asl     a
        dey
        bne     @l
@go:    sta     MQA
        jsr     pmul6                   ; smaller * 8192 / larger / 64
        cmp     #129
        bcc     :+
        lda     #128
:       rts

; -----------------------------------------------------------------------------
; foe_steer - move the velocity toward the wanted one, FEACC per axis at most.
; -----------------------------------------------------------------------------
foe_steer:
        ldx     FEI                     ; already flying the velocity it wants
        lda     FEVXL                   ;   - a patrol, nearly always: nothing
        cmp     FOEVXL,x                ;   to do
        bne     @go
        lda     FEVXH
        cmp     FOEVXH,x
        bne     @go
        lda     FEVYL
        cmp     FOEVYL,x
        bne     @go
        lda     FEVYH
        cmp     FOEVYH,x
        bne     @go
        rts
@go:    ldy     FEPER                   ; a think every 2^FEPER frames carries
        lda     FE_ACCL,y               ;   that many frames' acceleration
        sta     FEACCL
        lda     FE_ACCH,y
        sta     FEACCH
        sec
        lda     FEVXL
        sbc     FOEVXL,x
        sta     FET0
        lda     FEVXH
        sbc     FOEVXH,x
        sta     FET1
        jsr     foe_clampacc
        ldx     FEI
        clc
        lda     FOEVXL,x
        adc     FET0
        sta     FOEVXL,x
        lda     FOEVXH,x
        adc     FET1
        sta     FOEVXH,x
        sec
        lda     FEVYL
        sbc     FOEVYL,x
        sta     FET0
        lda     FEVYH
        sbc     FOEVYH,x
        sta     FET1
        jsr     foe_clampacc
        ldx     FEI
        clc
        lda     FOEVYL,x
        adc     FET0
        sta     FOEVYL,x
        lda     FOEVYH,x
        adc     FET1
        sta     FOEVYH,x
        rts

; foe_clampacc - FET0/FET1, signed, clamped to +/-FEACC.
foe_clampacc:
        lda     FET1
        bmi     @neg
        lda     FET0
        cmp     FEACCL
        lda     FET1
        sbc     FEACCH
        bcc     @ok
        lda     FEACCL
        sta     FET0
        lda     FEACCH
        sta     FET1
@ok:    rts
@neg:   clc                             ; below -ACC exactly when adding ACC
        lda     FET0                    ;   still leaves it negative
        adc     FEACCL
        lda     FET1
        adc     FEACCH
        bpl     @ok
        sec
        lda     #$00
        sbc     FEACCL
        sta     FET0
        lda     #$00
        sbc     FEACCH
        sta     FET1
        rts

; foe_integrate - X = the UFO. 16.8 += signed 8.8, a rock's integrate.
foe_integrate:
        ldy     #$00
        bit     FOEVXH,x
        bpl     :+
        dey
:       clc
        lda     FOEXF,x
        adc     FOEVXL,x
        sta     FOEXF,x
        lda     FOEXL,x
        adc     FOEVXH,x
        sta     FOEXL,x
        tya
        adc     FOEXH,x
        sta     FOEXH,x
        ldy     #$00
        bit     FOEVYH,x
        bpl     :+
        dey
:       clc
        lda     FOEYF,x
        adc     FOEVYL,x
        sta     FOEYF,x
        lda     FOEYL,x
        adc     FOEVYH,x
        sta     FOEYL,x
        tya
        adc     FOEYH,x
        sta     FOEYH,x
        rts

; =============================================================================
; Avoidance
; =============================================================================
; Every obstacle - a rock, another UFO, the ship - has a ZONE round it: its own
; radius, the UFO's, and FOE_MARGIN of clear space. Of all the zones the UFO is
; inside, the DEEPEST decides (foe_respond), and three things happen:
;
;   1. if it is actually TOUCHING, it is put back on the circle just outside -
;      the hard guarantee, the same snap physics.s gives the ship. Whatever the
;      steering does, a frame never ends with a UFO inside what it avoids.
;   2. whatever velocity it has INTO the obstacle is taken away, and replaced
;      by an outward push that grows with how deep it is, up to FOE_SPD at the
;      obstacle's surface. That is what makes a UFO holding its post get out of
;      the way of a rock drifting at it.
;   3. if it is not sliding round the obstacle at FOE_VTMIN at least, it is
;      made to - so a UFO flying straight at a rock goes round it instead of
;      stopping at the edge, and carries on along its course once it is past.
;      Not for a UFO holding a post: that one only backs off, or it would orbit.
;
; Only the velocity along and across the one normal changes - nothing is
; rescaled - so sliding along a rock for many frames cannot pump the speed up.
; =============================================================================
foe_avoid:
        stz     FEBP
        lda     #FOE_MARGIN
        ldy     FEFAR
        beq     :+
        lda     #FOE_MARGIN+FOE_LOOK
:       sta     FEZE

        lda     SHIPGONE                ; --- the ship
        bne     @noship
        lda     SHXL
        sta     FEOBXL
        lda     SHXH
        sta     FEOBXH
        lda     SHYL
        sta     FEOBYL
        lda     SHYH
        sta     FEOBYH
        stz     FEOBK
        lda     #SHIP_RAD+FOE_R
        sta     FERS
        jsr     foe_cand
        bcc     @noship                 ; not touching it
        ldx     FEI
        lda     FOERAM,x
        bne     @noship
        lda     #FOE_RAMCD              ; RAMMED: the ship pays a hit point,
        sta     FOERAM,x                ;   the same as for a rock
        jsr     ship_hurt
@noship:
        lda     NFOE                    ; --- the other UFOs
        sta     FEJ
@olp:   dec     FEJ
        bmi     @rocks
        ldy     FEJ
        cpy     FEI
        beq     @olp
        lda     FOEST,y
        beq     @olp
        lda     FOEXH,y
        sec
        sbc     FEUXH
        clc
        adc     #FOE_HIW
        cmp     #2*FOE_HIW+1
        bcs     @olp
        lda     FOEYH,y
        sec
        sbc     FEUYH
        clc
        adc     #FOE_HIW
        cmp     #2*FOE_HIW+1
        bcs     @olp
        lda     FOEXL,y
        sta     FEOBXL
        lda     FOEXH,y
        sta     FEOBXH
        lda     FOEYL,y
        sta     FEOBYL
        lda     FOEYH,y
        sta     FEOBYH
        sty     FEOBI
        lda     #1
        sta     FEOBK
        lda     #2*FOE_R
        sta     FERS
        jsr     foe_cand
        bra     @olp
@rocks: lda     #<foe_rock1             ; --- the rocks, out of the sector grid
        sta     FEVEC
        lda     #>foe_rock1
        sta     FEVEC+1
        lda     #FOE_HIWN               ; the reach the walk has to cover
        ldy     FEFAR
        beq     :+
        lda     #FOE_HIW
:       sta     FEHIW
        jsr     fe_cells
        lda     FEBP
        beq     @done
        jmp     foe_respond
@done:  rts

; foe_rock1 - fe_cells' callback while a UFO looks for rocks. X = the rock.
foe_rock1:
        lda     OBJXH,x                 ; the coarse reject on the high bytes
        sec                             ;   first, as everywhere
        sbc     FEUXH
        clc
        adc     #FOE_HIW
        cmp     #2*FOE_HIW+1
        bcs     @no
        lda     OBJYH,x
        sec
        sbc     FEUYH
        clc
        adc     #FOE_HIW
        cmp     #2*FOE_HIW+1
        bcs     @no
        lda     OBJXL,x
        sta     FEOBXL
        lda     OBJXH,x
        sta     FEOBXH
        lda     OBJYL,x
        sta     FEOBYL
        lda     OBJYH,x
        sta     FEOBYH
        stx     FEOBI
        lda     #2
        sta     FEOBK
        ldy     OBJSHP,x                ; a linked rock is never SHP_DEAD
        lda     BODY_R,y
        clc
        adc     #FOE_R
        sta     FERS
        jsr     foe_cand
@no:    clc                             ; ...and never stop the walk
        rts

; -----------------------------------------------------------------------------
; fe_cells - the sector cells within FEHIW pages of the high bytes FEUXH/FEUYH;
; every rock in them goes to (FEVEC) with X = the rock. The callback returns
; carry SET to stop the walk - then this returns carry SET too.
; -----------------------------------------------------------------------------
; Not the four cells physics.s walks: that walk is PAIRS, and each pair comes
; up from one side. This is one body asking about everything round it, so a
; neighbour is needed on whichever side the reach crosses the cell's edge. A
; cell is 16 pages: a reach of 8 or less always needs exactly one neighbour a
; side, so a near UFO walks 2x2; a far one's 10 needs both on the middle third
; of a cell. The wrap is the mask, as everywhere. The successor is read BEFORE
; the callback, which may break the rock it was handed - and then must stop,
; because the lists have moved (fsh_rock1).
; -----------------------------------------------------------------------------
fe_cells:
        lda     FEUXH                   ; --- the columns
        and     #$0F
        sta     FEPOS
        lda     FEUXH
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     FECX
        lda     #1
        sta     FECN0
        lda     FEPOS
        cmp     FEHIW
        bcs     :+                      ; far enough from the left edge
        dec     FECX
        inc     FECN0
:       lda     #16
        sec
        sbc     FEHIW
        cmp     FEPOS
        beq     @xr
        bcs     :+                      ; ...and from the right one
@xr:    inc     FECN0
:       lda     FECX
        and     #$0F
        sta     FECX
        lda     FEUYH                   ; --- the rows, the same test
        and     #$0F
        sta     FEPOS
        lda     FEUYH
        and     #$F0
        sta     FEROW
        lda     #1
        sta     FERN
        lda     FEPOS
        cmp     FEHIW
        bcs     :+
        lda     FEROW                   ; the row above - the byte wraps, and
        sec                             ;   that is the torus
        sbc     #$10
        sta     FEROW
        inc     FERN
:       lda     #16
        sec
        sbc     FEHIW
        cmp     FEPOS
        beq     @yr
        bcs     @row
@yr:    inc     FERN
@row:   lda     FECX
        sta     FECOL
        lda     FECN0
        sta     FECN
@cell:  lda     FEROW
        ora     FECOL
        tax
        lda     CELLHD,x
@lp:    cmp     #$FF
        beq     @cnext
        tax
        lda     OBJNXT,x
        sta     FENEXT
        jsr     fe_visit
        bcs     @stop
        lda     FENEXT
        bra     @lp
@cnext: lda     FECOL
        inc     a
        and     #$0F
        sta     FECOL
        dec     FECN
        bne     @cell
        lda     FEROW
        clc
        adc     #$10
        sta     FEROW
        dec     FERN
        bne     @row
        clc
@stop:  rts

fe_visit:
        jmp     (FEVEC)

; -----------------------------------------------------------------------------
; foe_cand - is the obstacle at FEOB* (radius sum FERS) inside this UFO's zone?
; If it is the deepest so far it becomes FEB*. Carry SET = actually touching.
; -----------------------------------------------------------------------------
; The narrow phase is physics.s's: offsets in collision units, a box reject,
; then |d|^2 against the zone's square out of the quarter-square table. Only a
; candidate inside its zone pays for |d| - two shifts and an add, the ship's
; own estimate carried at 2x rather than 4x because a zone reaches 74 units.
; -----------------------------------------------------------------------------
foe_cand:
        lda     FERS
        clc
        adc     FEZE
        sta     FEZ
        bra     @x
@out:   clc                             ; (the box rejects' exit, kept in their
        rts                             ;  branch range)
@x:     ldx     FEI
        sec
        lda     FOEXL,x
        sbc     FEOBXL
        sta     FETL
        lda     FOEXH,x
        sbc     FEOBXH
        jsr     foe_cu
        bcs     @out
        sta     FETX
        jsr     absa
        cmp     FEZ
        beq     :+
        bcs     @out
:       sta     FEADX
        ldx     FEI
        sec
        lda     FOEYL,x
        sbc     FEOBYL
        sta     FETL
        lda     FOEYH,x
        sbc     FEOBYH
        jsr     foe_cu
        bcs     @out
        sta     FETY
        jsr     absa
        cmp     FEZ
        beq     :+
        bcs     @out
:       sta     FEADY
        asl     a                       ; |d|^2 = f(2|dx|) + f(2|dy|)
        tax
        lda     QSL,x
        sta     FET0
        lda     QSH,x
        sta     FET1
        lda     FEADX
        asl     a
        tax
        clc
        lda     QSL,x
        adc     FET0
        sta     FET0
        lda     QSH,x
        adc     FET1
        sta     FET1
        lda     FEZ                     ; ...against the zone's square
        asl     a
        tax
        lda     FET0
        cmp     QSL,x
        lda     FET1
        sbc     QSH,x
        bcc     :+
        jmp     @no                     ; outside the zone
:       lda     FERS                    ; ...and the obstacle's own
        asl     a
        tax
        lda     FET0
        cmp     QSL,x
        lda     FET1
        sbc     QSH,x
        lda     #$00
        rol     a                       ; carry CLEAR = inside it = touching
        eor     #$01
        sta     FEOVL
        jsr     foe_e2
        sta     FEE2
        clc                             ; |d| ~ (2|d| + 1) / 2
        adc     #$01
        lsr     a
        sta     FET2
        lda     FEZ                     ; depth = zone - |d|, at least 1
        sec
        sbc     FET2
        beq     @p1
        bcs     @pok
@p1:    lda     #$01
@pok:   sta     FEP
        cmp     FEBP
        beq     @keep
        bcc     @keep                   ; not deeper than the one held
        sta     FEBP
        lda     FETX
        sta     FEBTX
        lda     FETY
        sta     FEBTY
        lda     FERS
        sta     FEBRS
        lda     FEE2
        sta     FEBE2
        lda     FEOVL
        sta     FEBOV
        lda     FEOBXL
        sta     FEBOXL
        lda     FEOBXH
        sta     FEBOXH
        lda     FEOBYL
        sta     FEBOYL
        lda     FEOBYH
        sta     FEBOYH
        lda     FEOBK
        sta     FEBK
        lda     FEOBI
        sta     FEBI
@keep:  lda     FEOVL
        lsr     a                       ; carry = touching
        rts
@no:    clc
        rts

; foe_cu - A = high, FETL = low of a signed 16-bit world offset -> A = it >> 5,
; collision units; carry SET if that is not a signed byte. physics.s's to_cu
; on this file's scratch.
foe_cu:
        sta     FETH
        clc
        adc     #$10
        cmp     #$20
        bcs     @out
        asl     FETL
        rol     FETH
        asl     FETL
        rol     FETH
        asl     FETL
        lda     FETH
        rol     a
        clc
        rts
@out:   sec
        rts

; foe_e2 - A = 2|d| from FEADX/FEADY: 2M + max(0, m - (M+2)/4), M the larger.
; physics.s ship_respond's max(M, 0.875M + 0.5m) at 2x, the quarter rounded UP
; so the estimate errs SHORT - a long normal only overshoots the snap.
foe_e2:
        lda     FEADX
        ldx     FEADY
        cmp     FEADY
        bcs     :+
        ldx     FEADX
        lda     FEADY
:       sta     FET2                    ; M
        clc
        adc     #$02
        lsr     a
        lsr     a
        sta     FET3                    ; (M+2)/4
        txa
        sec
        sbc     FET3
        bcs     :+
        lda     #$00
:       sta     FET3
        lda     FET2
        asl     a
        clc
        adc     FET3
        rts

; =============================================================================
; On the screen
; =============================================================================
; foe_screen_all - FOEON and FOEFX/FY for every live UFO near enough to draw.
; The same road a rock takes: the cull window first (it is also what keeps the
; delta small enough for view_xform's tables), then the transform.
foe_screen_all:
        lda     NFOE
        bne     :+
        rts
:       dec     a
        sta     FEI
@lp:    ldx     FEI
        stz     FOEON,x
        lda     FOEST,x
        beq     @next
        lda     FOESLP,x                ; asleep: it was well off the screen a
        beq     :+                      ;   frame or two ago, and nothing can
        dec     FOESLP,x                ;   have brought it on since
        bra     @next
:       sec
        lda     FOEXL,x
        sbc     SHXL
        sta     PXL
        lda     FOEXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     FOEYL,x
        sbc     SHYL
        sta     PYL
        lda     FOEYH,x
        sbc     SHYH
        sta     PYH
        lda     PXL
        ldy     PXH
        ldx     #$00
        jsr     in_range
        bcs     @sleep
        lda     PYL
        ldy     PYH
        ldx     #$01
        jsr     in_range
        bcs     @sleep
        jsr     view_xform
        jsr     zoom_fb
        lda     #FOE_SMARG
        jsr     f_onscr
        bcs     @off
        ldx     FEI
        lda     FXL
        sta     FOEFXL,x
        lda     FXH
        sta     FOEFXH,x
        lda     FYL
        sta     FOEFYL,x
        lda     FYH
        sta     FOEFYH,x
        lda     #$01
        sta     FOEON,x
@next:  dec     FEI
        bpl     @lp
        rts
@off:   lda     #FOE_SLPM               ; off the screen - but near enough to
        jsr     f_onscr                 ;   the edge to be looked at again next
        bcc     @next                   ;   frame?
@sleep: lda     FEI
        and     #$01
        clc
        adc     #FOE_SLPN
        ldx     FEI
        sta     FOESLP,x
        bra     @next

; f_onscr - carry CLEAR when FX/FY lies inside the full-res field grown by A
; pixels on every side. (v + M) read UNSIGNED against extent + 2M - the trick
; shots.s's own cull and in_range use.
f_onscr:
        sta     FET2
        asl     a
        sta     FET3
        clc
        lda     FXL
        adc     FET2
        sta     FET0
        lda     FXH
        adc     #$00
        sta     FET1
        clc
        lda     #<400
        adc     FET3
        tax
        lda     #>400
        adc     #$00
        cmp     FET1
        bcc     @out
        bne     @yok
        cpx     FET0
        beq     @out
        bcc     @out
@yok:   clc
        lda     FYL
        adc     FET2
        sta     FET0
        lda     FYH
        adc     #$00
        sta     FET1
        clc
        lda     #<300
        adc     FET3
        tax
        lda     #>300
        adc     #$00
        cmp     FET1
        bcc     @out
        bne     @in
        cpx     FET0
        beq     @out
        bcc     @out
@in:    clc
        rts
@out:   sec
        rts

; foe_draw_all - every UFO that is on screen and still alive.
foe_draw_all:
        lda     NFOE
        bne     :+
        rts
:       dec     a
        sta     FEI
@lp:    ldx     FEI
        lda     FOEON,x
        beq     @next
        lda     FOEST,x
        beq     @next
        jsr     foe_disc
        jsr     foe_body
@next:  dec     FEI
        bpl     @lp
        rts

; foe_disc - its hole in the starfield: occlude.s's disc, like a rock's.
foe_disc:
        ldx     FEI
        lda     FOEFXH,x
        cmp     #$80
        ror     a
        sta     CX2H
        lda     FOEFXL,x
        ror     a
        sta     CX2L
        lda     FOEFYH,x
        cmp     #$80
        ror     a
        sta     CY2H
        lda     FOEFYL,x
        ror     a
        sta     CY2L
        lda     #FOE_OCC
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul
        sta     AOCR
        jmp     add_disc

; foe_body - one POLYGON16 per part of the shape, at ANGLE 0: the UFO never
; turns, so the parts go out exactly as enemies.s authors them and the GPU only
; scales them. SHPL/SHPH is one_asteroid's pointer, free by now.
foe_body:
        stz     FEJ
@part:  ldy     FEJ
        lda     EN_UFO_PLO,y
        sta     SHPL
        lda     EN_UFO_PHI,y
        sta     SHPH
        ldx     FEI
        lda     FOEFXL,x
        sta     PBUF+0
        lda     FOEFXH,x
        sta     PBUF+1
        lda     FOEFYL,x
        sta     PBUF+2
        lda     FOEFYH,x
        sta     PBUF+3
        stz     PBUF+4                  ; ANGLE 0
        lda     ZEASH                   ; SCALE: the eased zoom, as a rock
        sta     PBUF+5
        ldy     #$00
        lda     (SHPL),y                ; N, OPEN bit and all
        sta     PBUF+6
        and     #$7F
        asl     a
        tax                             ; 2K bytes of offsets follow it
        ldy     #$01
@cp:    lda     (SHPL),y
        sta     PBUF+6,y
        iny
        dex
        bne     @cp
        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jsr     API_GPU_POLYGON16
        inc     FEJ
        lda     FEJ
        cmp     #EN_UFO_PN
        bcc     @part
        rts

; =============================================================================
; From here to the wreck: CODE3, bank 3 stored and run in RAM after CODE2 -
; bank 1 has no more room (cart.cfg). It is ordinary run-area code; the split
; is where the bank filled, not a difference in kind.
; =============================================================================
        .segment "CODE3"

; -----------------------------------------------------------------------------
; foe_hits - the player's bullets against every UFO on the screen.
; -----------------------------------------------------------------------------
; shot_hits' own test, UFO-outer: the circle round the bullet's tip, and the
; rectangle it swept getting there (shots.s shot_dnarrow / shot_swept, which
; take their operands in shots.s's scratch - set here exactly as there).
; -----------------------------------------------------------------------------
foe_hits:
        ldx     #SHOT_N-1
@any:   lda     SHTLIVE,x
        bne     @go
        dex
        bpl     @any
        rts
@go:    lda     NFOE
        bne     :+
        rts
:       dec     a
        sta     FEI
@flp:   ldx     FEI
        lda     FOEST,x
        beq     @fnx
        lda     FOEON,x
        bne     :+
@fnx:   jmp     @fnext
:       lda     #FOE_R                  ; its circle on the screen, full-res px
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul
        asl     a
        clc                             ; SHOT_HITR (shots.s) - same bullet-radius
        adc     #SHOT_HITR              ;   hit-test bonus shot_hits gives a rock
        sta     SHTR
        clc
        adc     SHTSWP
        sta     SHTRW
        lda     SHTR                    ; R * 128 and SWEEP * 128, shot_swept's
        lsr     a                       ;   raw bounds
        sta     SHTR129
        lda     #$00
        ror     a
        sta     SHTR128
        lda     SHTSWP
        lsr     a
        sta     SHTL129
        lda     #$00
        ror     a
        sta     SHTL128
        lda     #SHOT_N-1
        sta     SHTJ
@blp:   ldx     SHTJ
        lda     SHTLIVE,x
        bne     :+
@bsk:   jmp     @bnext
:       ldy     FEI
        sec
        lda     FOEFXL,y
        sbc     SHTFXL,x
        sta     T0
        lda     FOEFXH,y
        sbc     SHTFXH,x
        sta     T1
        jsr     shot_dnarrow
        bcs     @bsk
        sta     SHTADX
        lda     T0
        sta     SHTDX
        ldx     SHTJ
        ldy     FEI
        sec
        lda     FOEFYL,y
        sbc     SHTFYL,x
        sta     T0
        lda     FOEFYH,y
        sbc     SHTFYH,x
        sta     T1
        jsr     shot_dnarrow
        bcs     @bsk
        sta     SHTADY
        lda     T0
        sta     SHTDY
        lda     SHTADX
        asl     a
        tax
        lda     QSL,x
        sta     T0
        lda     QSH,x
        sta     T1
        lda     SHTADY
        asl     a
        tax
        clc
        lda     QSL,x
        adc     T0
        sta     T0
        lda     QSH,x
        adc     T1
        sta     T1
        lda     SHTR
        asl     a
        tax
        lda     T0
        cmp     QSL,x
        lda     T1
        sbc     QSH,x
        bcc     @hit
        jsr     shot_swept
        bcc     @hit
        jmp     @bnext
@hit:   ldx     SHTJ                    ; A HIT: the puff on the bullet's tip,
        jsr     expl_spawn              ;   the bullet spent, the points paid
        ldx     SHTJ
        stz     SHTLIVE,x
        lda     #SCORE_FOE_HIT
        jsr     score_add
        ldx     FEI
        dec     FOEHP,x
        bne     @alive
        jsr     foe_kill                ; ...and that was the last one
        jmp     @fnext
@alive: lda     #SE_ROCK_HIT
        jsr     sfx_fire
@bnext: dec     SHTJ
        bmi     @fnext
        jmp     @blp
@fnext: dec     FEI
        bmi     :+
        jmp     @flp
:       rts

; =============================================================================
; The UFOs' bullets
; =============================================================================
fsh_all:
        lda     #FSH_N-1
        sta     FSI
@lp:    ldx     FSI
        lda     FSLIVE,x
        bne     :+
        jmp     @next
:       clc                             ; position += velocity, 16.8 + 16.8
        lda     FSXF,x
        adc     FSVXL,x
        sta     FSXF,x
        lda     FSXL,x
        adc     FSVXH,x
        sta     FSXL,x
        lda     FSXH,x
        adc     FSVXT,x
        sta     FSXH,x
        clc
        lda     FSYF,x
        adc     FSVYL,x
        sta     FSYF,x
        lda     FSYL,x
        adc     FSVYH,x
        sta     FSYL,x
        lda     FSYH,x
        adc     FSVYT,x
        sta     FSYH,x
        lda     FSAGE,x
        cmp     #$FF
        beq     :+
        inc     FSAGE,x
:       jsr     fsh_ship                ; the ship first: it is what they are for
        bcs     @kill
        jsr     fsh_rocks
        bcs     @kill
        ldx     FSI                     ; ...then the screen
        sec
        lda     FSXL,x
        sbc     SHXL
        sta     PXL
        lda     FSXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     FSYL,x
        sbc     SHYL
        sta     PYL
        lda     FSYH,x
        sbc     SHYH
        sta     PYH
        lda     PXL
        ldy     PXH
        ldx     #$00
        jsr     in_range
        bcs     @off
        lda     PYL
        ldy     PYH
        ldx     #$01
        jsr     in_range
        bcs     @off
        jsr     view_xform
        jsr     zoom_fb
        lda     #SHOT_MARG              ; the gun's own screen margin
        jsr     f_onscr
        bcs     @off
        ldx     FSI
        lda     #$01
        sta     FSSEEN,x
        jsr     fsh_draw
        bra     @next
@off:   ldx     FSI                     ; off the screen: over, once it has been
        lda     FSSEEN,x                ;   on it - or once it has had FSH_MIN
        bne     @kill                   ;   frames to get there
        lda     FSAGE,x
        cmp     #FSH_MIN
        bcc     @next
@kill:  ldx     FSI
        stz     FSLIVE,x
@next:  dec     FSI
        bmi     :+
        jmp     @lp
:       rts

; fsh_draw - the gun's own command: an OPEN two-vertex POLYGON16, tip on the
; anchor, turned by (the heading it flies) - (the camera's).
fsh_draw:
        lda     FXL
        sta     PBUF+0
        lda     FXH
        sta     PBUF+1
        lda     FYL
        sta     PBUF+2
        lda     FYH
        sta     PBUF+3
        ldx     FSI
        sec
        lda     FSANG,x
        sbc     HEAD
        sta     PBUF+4
        lda     ZEASH
        sta     PBUF+5
        lda     #$80 | 2
        sta     PBUF+6
        stz     PBUF+7
        stz     PBUF+8
        lda     #SHOT_LEN
        sta     PBUF+9
        stz     PBUF+10
        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jmp     API_GPU_POLYGON16

; -----------------------------------------------------------------------------
; fsh_ship - FSI against the ship. Carry SET = it hit (and has been paid for).
; -----------------------------------------------------------------------------
; In the WORLD, against the ship's circle, and SWEPT: a bullet closes on a ship
; flying at it by up to 13 collision units a frame against a circle 16 across,
; so a point test would let it through. The swept path is the step since last
; frame RELATIVE TO THE SHIP (FSPD), cut in quarters - four points 3 units
; apart at the worst. A step longer than 32 is not a flight, it is a teleport,
; and gets no sweep.
; -----------------------------------------------------------------------------
fsh_ship:
        lda     SHIPGONE
        beq     @go
@miss:  clc
        rts
@far:   ldx     FSI                     ; out of collision-unit range: nothing
        stz     FSPOK,x                 ;   to sweep from next frame either
        clc
        rts
@hit:   jsr     fsh_bang
        jsr     ship_hurt               ; one hit point, the same as a rock
        sec
        rts
@go:    ldx     FSI
        sec
        lda     FSXL,x
        sbc     SHXL
        sta     FETL
        lda     FSXH,x
        sbc     SHXH
        jsr     foe_cu
        bcs     @far
        sta     FETX
        ldx     FSI
        sec
        lda     FSYL,x
        sbc     SHYL
        sta     FETL
        lda     FSYH,x
        sbc     SHYH
        jsr     foe_cu
        bcs     @far
        sta     FETY
        ldy     FETY                    ; where it is now...
        lda     FETX
        jsr     fsh_in
        bcc     @hit
        ldx     FSI                     ; ...and back along the way it came
        lda     FSPOK,x
        beq     @save
        sec
        lda     FETX
        sbc     FSPDX,x
        sta     FET0
        jsr     absa
        cmp     #33
        bcs     @save
        sec
        lda     FETY
        sbc     FSPDY,x
        sta     FET1
        jsr     absa
        cmp     #33
        bcs     @save
        lda     FET0                    ; a quarter of the step
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        sta     FET0
        lda     FET1
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        sta     FET1
        lda     FETX
        sta     FET2
        lda     FETY
        sta     FET3
        lda     #3
        sta     FEK
@back:  sec
        lda     FET2
        sbc     FET0
        sta     FET2
        sec
        lda     FET3
        sbc     FET1
        sta     FET3
        tay
        lda     FET2
        jsr     fsh_in
        bcs     :+
        jmp     @hit
:       dec     FEK
        bne     @back
@save:  ldx     FSI
        lda     FETX
        sta     FSPDX,x
        lda     FETY
        sta     FSPDY,x
        lda     #$01
        sta     FSPOK,x
        clc
        rts

; fsh_in - A = dx, Y = dy, collision units -> carry CLEAR inside SHIP_RAD.
fsh_in:
        jsr     absa
        cmp     #SHIP_RAD
        bcs     @out
        asl     a
        tax
        lda     QSL,x
        sta     FESQL
        tya
        jsr     absa
        cmp     #SHIP_RAD
        bcs     @out
        asl     a
        tax
        lda     QSL,x
        clc
        adc     FESQL
        cmp     #SHIP_RAD*SHIP_RAD
        rts
@out:   sec
        rts

; fsh_bang - the puff, on the bullet's tip.
fsh_bang:
        ldx     FSI
        lda     FSXL,x
        sta     EXTXL
        lda     FSXH,x
        sta     EXTXH
        lda     FSYL,x
        sta     EXTYL
        lda     FSYH,x
        sta     EXTYH
        jmp     expl_at

; -----------------------------------------------------------------------------
; fsh_rocks - FSI against the rocks round it. Carry SET = it broke one.
; -----------------------------------------------------------------------------
; Out of the sector grid, so it works off the screen too - a UFO shooting from
; out there hits what is in the way. Two points, now and half a frame back: the
; bullet moves 6 collision units a frame and the smallest rock is 6 across.
; -----------------------------------------------------------------------------
fsh_rocks:
        ldx     FSI
        lda     FSVXH,x                 ; half its frame's travel: the 16.8
        sta     FET0                    ;   velocity's integer part >> 6
        lda     FSVXT,x
        sta     FET1
        jsr     fe_asr6
        sta     FESHX
        ldx     FSI
        lda     FSVYH,x
        sta     FET0
        lda     FSVYT,x
        sta     FET1
        jsr     fe_asr6
        sta     FESHY
        ldx     FSI
        lda     FSXH,x
        sta     FEUXH
        lda     FSYH,x
        sta     FEUYH
        lda     #FSH_HIW
        sta     FEHIW
        lda     #<fsh_rock1
        sta     FEVEC
        lda     #>fsh_rock1
        sta     FEVEC+1
        jmp     fe_cells

; fe_asr6 - FET1:FET0 >>= 6, arithmetic -> A = the low byte.
fe_asr6:
        ldy     #6
:       lda     FET1
        cmp     #$80
        ror     FET1
        ror     FET0
        dey
        bne     :-
        lda     FET0
        rts

; fsh_rock1 - fe_cells' callback for a bullet. X = the rock.
fsh_rock1:
        lda     OBJXH,x
        sec
        sbc     FEUXH
        clc
        adc     #FSH_HIW
        cmp     #2*FSH_HIW+1
        bcs     @no
        lda     OBJYH,x
        sec
        sbc     FEUYH
        clc
        adc     #FSH_HIW
        cmp     #2*FSH_HIW+1
        bcs     @no
        stx     FEJ
        ldy     OBJSHP,x
        lda     BODY_R,y
        sta     FERS
        ldy     FSI
        sec
        lda     FSXL,y
        sbc     OBJXL,x
        sta     FETL
        lda     FSXH,y
        sbc     OBJXH,x
        jsr     foe_cu
        bcs     @no
        sta     FETX
        ldx     FEJ
        ldy     FSI
        sec
        lda     FSYL,y
        sbc     OBJYL,x
        sta     FETL
        lda     FSYH,y
        sbc     OBJYH,x
        jsr     foe_cu
        bcs     @no
        sta     FETY
        ldy     FETY                    ; now...
        lda     FETX
        jsr     frk_in
        bcc     @hit
        lda     FETY                    ; ...and half a frame back
        sec
        sbc     FESHY
        tay
        lda     FETX
        sec
        sbc     FESHX
        jsr     frk_in
        bcc     @hit
@no:    clc
        rts
@hit:   jsr     fsh_bang
        ldx     FSI                     ; the halves go across ITS heading
        lda     FSANG,x
        sta     SPL_HD
        lda     #$01                    ; ...and nobody is paid for it
        sta     FOEKILL
        ldx     FEJ
        jsr     rock_take_hit
        stz     FOEKILL
        sec                             ; stop: the lists may have moved
        rts

; frk_in - A = dx, Y = dy, collision units -> carry CLEAR inside FERS.
frk_in:
        jsr     absa
        cmp     FERS
        beq     :+
        bcs     @out
:       asl     a
        tax
        lda     QSL,x
        sta     FESQL
        lda     QSH,x
        sta     FESQH
        tya
        jsr     absa
        cmp     FERS
        beq     :+
        bcs     @out
:       asl     a
        tax
        clc
        lda     QSL,x
        adc     FESQL
        sta     FESQL
        lda     QSH,x
        adc     FESQH
        sta     FESQH
        lda     FERS
        asl     a
        tax
        lda     FESQL
        cmp     QSL,x
        lda     FESQH
        sbc     QSH,x
        rts
@out:   sec
        rts

; =============================================================================
; The wreck
; =============================================================================
; fw_all - one frame of drift and tumble for every piece, and its command.
fw_all:
        lda     #FW_N-1
        sta     FEWI
@lp:    ldx     FEWI
        lda     FWN,x
        bne     :+
        jmp     @next
:       dec     FWN,x
        clc
        lda     FWPXL,x
        adc     FWVXL,x
        sta     FWPXL,x
        lda     FWPXH,x
        adc     FWVXH,x
        sta     FWPXH,x
        clc
        lda     FWPYL,x
        adc     FWVYL,x
        sta     FWPYL,x
        lda     FWPYH,x
        adc     FWVYH,x
        sta     FWPYH,x
        clc
        lda     FWANG,x
        adc     FWSPN,x
        sta     FWANG,x
        sec                             ; the anchor, onto the screen
        lda     FWAXL,x
        sbc     SHXL
        sta     PXL
        lda     FWAXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     FWAYL,x
        sbc     SHYL
        sta     PYL
        lda     FWAYH,x
        sbc     SHYH
        sta     PYH
        lda     PXL
        ldy     PXH
        ldx     #$00
        jsr     in_range
        bcs     @next
        lda     PYL
        ldy     PYH
        ldx     #$01
        jsr     in_range
        bcs     @next
        jsr     view_xform
        jsr     zoom_fb
        ldx     FEWI                    ; ...plus the piece's own offset
        ldy     #$00
        lda     FWPXH,x
        bpl     :+
        dey
:       clc
        adc     FXL
        sta     FXL
        tya
        adc     FXH
        sta     FXH
        ldy     #$00
        lda     FWPYH,x
        bpl     :+
        dey
:       clc
        adc     FYL
        sta     FYL
        tya
        adc     FYH
        sta     FYH
        lda     #FOE_SMARG
        jsr     f_onscr
        bcs     @next
        jsr     fw_draw
@next:  dec     FEWI
        bmi     :+
        jmp     @lp
:       rts

; fw_draw - the piece's part, its vertices moved onto its own pivot so the GPU
; tumbles it about its own middle, not about the UFO's.
fw_draw:
        ldx     FEWI
        ldy     FWPART,x
        lda     EN_UFO_PLO,y
        sta     SHPL
        lda     EN_UFO_PHI,y
        sta     SHPH
        lda     FXL
        sta     PBUF+0
        lda     FXH
        sta     PBUF+1
        lda     FYL
        sta     PBUF+2
        lda     FYH
        sta     PBUF+3
        lda     FWANG,x
        sta     PBUF+4
        lda     ZEASH
        sta     PBUF+5
        ldy     #$00
        lda     (SHPL),y
        sta     PBUF+6
        and     #$7F
        sta     FEWJ
        ldy     #$01
@cp:    ldx     FEWI
        lda     (SHPL),y
        sec
        sbc     FWCX,x
        sta     PBUF+6,y
        iny
        lda     (SHPL),y
        sec
        sbc     FWCY,x
        sta     PBUF+6,y
        iny
        dec     FEWJ
        bne     @cp
        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jmp     API_GPU_POLYGON16

; =============================================================================
; The avoidance response - CODE3 with the rest of the per-UFO code. It only runs
; on a think that finds the UFO inside a zone.
; =============================================================================
        .segment "CODE3"

; -----------------------------------------------------------------------------
; foe_respond - the deepest zone the UFO is in (FEB*). See the note above
; foe_avoid for the three things it does.
; -----------------------------------------------------------------------------
foe_respond:
        lda     FEBE2                   ; --- the unit normal, obstacle -> UFO
        bne     @norm
        lda     #127                    ; dead on top of it: any way out will do
        sta     FENX
        stz     FENY
        bra     @snap
@norm:  ldy     #$01                    ; 2|d| into (64, 128], the shift counted
@dn:    cmp     #129                    ;   from 1 because the divisor it builds
        bcc     @up                     ;   is 2|d| and foe_nrm wants the one
        lsr     a                       ;   that goes with |d| - ship_respond's
        dey                             ;   normalisation, at 2x
        bra     @dn
@up:    cmp     #65
        bcs     @nd
        asl     a
        iny
        bra     @up
@nd:    sty     FES
        sec
        sbc     #65
        tax
        lda     RECIP64,x
        sta     FEQ
        lda     FEBTX
        jsr     absa
        jsr     foe_nrm
        ldy     FEBTX
        bpl     :+
        eor     #$FF
        inc     a
:       sta     FENX
        lda     FEBTY
        jsr     absa
        jsr     foe_nrm
        ldy     FEBTY
        bpl     :+
        eor     #$FF
        inc     a
:       sta     FENY
        ora     FENX
        bne     @snap
        lda     #127
        sta     FENX

@snap:  lda     FEBOV                   ; --- 1. touching: onto the circle
        beq     @vel                    ;   just outside, obstacle + n (rsum+1)
        lda     FEBRS
        inc     a
        sta     FET0
        stz     FET1
        ldy     #5                      ; collision units -> world units
:       asl     FET0
        rol     FET1
        dey
        bne     :-
        lda     FET0
        sta     MAL
        lda     FET1
        sta     MAH
        lda     FENX
        sta     MB
        jsr     smul16q7
        ldx     FEI
        clc
        lda     FEBOXL
        adc     MAL
        sta     FOEXL,x
        lda     FEBOXH
        adc     MAH
        sta     FOEXH,x
        lda     FET0
        sta     MAL
        lda     FET1
        sta     MAH
        lda     FENY
        sta     MB
        jsr     smul16q7
        ldx     FEI
        clc
        lda     FEBOYL
        adc     MAL
        sta     FOEYL,x
        lda     FEBOYH
        adc     MAH
        sta     FOEYH,x

@vel:   jsr     foe_vn                  ; --- 2. no velocity in; a push out
        lda     FEBP                    ; the push: 3 units a frame per unit of
        cmp     #FOE_PUSHN              ;   depth, up to FOE_SPD
        bcc     @pk
        lda     #<FOE_SPD
        sta     FET0
        lda     #>FOE_SPD
        sta     FET1
        bra     @pd
@pk:    sta     FET1                    ; depth * 768 is (3 * depth) * 256
        asl     a
        clc
        adc     FET1
        sta     FET1
        stz     FET0
@pd:    sec                             ; vn < push? (signed)
        lda     FEVNL
        sbc     FET0
        lda     FEVNH
        sbc     FET1
        bvc     :+
        eor     #$80
:       bpl     @tan
        sec
        lda     FET0
        sbc     FEVNL
        sta     FET0
        lda     FET1
        sbc     FEVNH
        sta     FET1
        jsr     foe_addn                ; v += (push - vn) n

@tan:   ldx     FEI                     ; --- 3. round it - or, holding a post,
        lda     FOEST,x                 ;   out of the way of it
        cmp     #FS_PATROL
        bne     :+
        lda     FOEPSPD,x
        beq     @post
:       jsr     foe_slide_own
        jmp     foe_vcap
@post:  jsr     foe_slide_post
        jmp     foe_vcap

; foe_slide_own - a UFO going somewhere: at least FOE_VTMIN round the obstacle,
; the way it is already going round it (+ if it is dead on).
foe_slide_own:
        jsr     foe_vt
        lda     FEVTH
        bmi     @vneg
        lda     FEVTL                   ; 0 <= vt < VTMIN: up to +VTMIN
        cmp     #<FOE_VTMIN
        lda     FEVTH
        sbc     #>FOE_VTMIN
        bcs     @done
        bra     foe_to_plus
@vneg:  clc                             ; -VTMIN < vt < 0: down to -VTMIN
        lda     FEVTL
        adc     #<FOE_VTMIN
        lda     FEVTH
        adc     #>FOE_VTMIN
        bpl     foe_to_minus
@done:  rts

; foe_to_plus / foe_to_minus - vt := +/-FOE_VTMIN (FEVT = vt already).
foe_to_plus:
        sec
        lda     #<FOE_VTMIN
        sbc     FEVTL
        sta     FET0
        lda     #>FOE_VTMIN
        sbc     FEVTH
        sta     FET1
        jmp     foe_addt                ; v += (target - vt) t
foe_to_minus:
        sec
        lda     #<(-FOE_VTMIN)
        sbc     FEVTL
        sta     FET0
        lda     #>(-FOE_VTMIN)
        sbc     FEVTH
        sta     FET1
        jmp     foe_addt

; foe_slide_post - a UFO holding a post only dodges what is coming AT it: an
; obstacle whose own velocity has a component toward the UFO. Then it slides at
; FOE_VTMIN off that obstacle's path - against the obstacle's own drift across
; the normal - instead of being shoved ahead of it, which is all the push alone
; does to a rock arriving dead on. A rock it merely sits beside, it leaves be:
; slide there and the spring back to the post would make it orbit.
foe_slide_post:
        jsr     foe_obsv
        lda     FENX                    ; vobs . n
        ldx     FENY
        jsr     foe_ovdot
        lda     FEVOH
        bmi     @done                   ; moving away from it
        ora     FEVOL
        beq     @done                   ; not moving at all
        jsr     foe_vt
        lda     FENY                    ; vobs . t, t = (-ny, nx): the dot with
        eor     #$FF                    ;   (nx, ny) turned a quarter
        inc     a
        tax
        lda     FENX
        jsr     foe_ovdot_yx
        lda     FEVOH
        bmi     foe_to_plus             ; drifting -t: step off along +t
        ora     FEVOL
        beq     foe_to_plus             ; dead on: either side will do
        jmp     foe_to_minus
@done:  rts

; foe_obsv - FEOV = the worst obstacle's velocity, 8.8. The ship counts as
; standing still - a UFO does not dodge the player, it is shoved by the ram.
foe_obsv:
        stz     FEOVXL
        stz     FEOVXH
        stz     FEOVYL
        stz     FEOVYH
        ldx     FEBI
        lda     FEBK
        beq     @done
        cmp     #1
        bne     @rock
        lda     FOEVXL,x
        sta     FEOVXL
        lda     FOEVXH,x
        sta     FEOVXH
        lda     FOEVYL,x
        sta     FEOVYL
        lda     FOEVYH,x
        sta     FEOVYH
        rts
@rock:  lda     OBJVXL,x
        sta     FEOVXL
        lda     OBJVXH,x
        sta     FEOVXH
        lda     OBJVYL,x
        sta     FEOVYL
        lda     OBJVYH,x
        sta     FEOVYH
@done:  rts

; foe_ovdot - FEVO = FEOVX * A + FEOVY * X (both Q0.7). foe_ovdot_yx is the
; same with the roles swapped: FEOVY * A + FEOVX * X.
foe_ovdot:
        stx     FET2
        ldx     FEOVXL
        stx     MAL
        ldx     FEOVXH
        stx     MAH
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     FEVOL
        lda     MAH
        sta     FEVOH
        lda     FEOVYL
        sta     MAL
        lda     FEOVYH
        sta     MAH
        bra     foe_ovadd
foe_ovdot_yx:
        stx     FET2
        ldx     FEOVYL
        stx     MAL
        ldx     FEOVYH
        stx     MAH
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     FEVOL
        lda     MAH
        sta     FEVOH
        lda     FEOVXL
        sta     MAL
        lda     FEOVXH
        sta     MAH
foe_ovadd:
        lda     FET2
        sta     MB
        jsr     smul16q7
        clc
        lda     MAL
        adc     FEVOL
        sta     FEVOL
        lda     MAH
        adc     FEVOH
        sta     FEVOH
        rts

; foe_nrm - A = a magnitude <= |d| -> A * 128 / |d|, from FES/FEQ. physics.s's
; nrm on this file's scratch.
foe_nrm:
        ldy     FES
        beq     @go
@lp:    asl     a
        dey
        bne     @lp
@go:    sta     MQA
        lda     FEQ
        sta     MQB
        jsr     pmul6
        cmp     #$80
        bcc     :+
        lda     #$7F
:       rts

; foe_vn - FEVN = v . n.
foe_vn:
        ldx     FEI
        lda     FOEVXL,x
        sta     MAL
        lda     FOEVXH,x
        sta     MAH
        lda     FENX
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     FEVNL
        lda     MAH
        sta     FEVNH
        ldx     FEI
        lda     FOEVYL,x
        sta     MAL
        lda     FOEVYH,x
        sta     MAH
        lda     FENY
        sta     MB
        jsr     smul16q7
        clc
        lda     MAL
        adc     FEVNL
        sta     FEVNL
        lda     MAH
        adc     FEVNH
        sta     FEVNH
        rts

; foe_vt - FEVT = v . t, t = (-ny, nx): vy*nx - vx*ny.
foe_vt:
        ldx     FEI
        lda     FOEVYL,x
        sta     MAL
        lda     FOEVYH,x
        sta     MAH
        lda     FENX
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     FEVTL
        lda     MAH
        sta     FEVTH
        ldx     FEI
        lda     FOEVXL,x
        sta     MAL
        lda     FOEVXH,x
        sta     MAH
        lda     FENY
        sta     MB
        jsr     smul16q7
        sec
        lda     FEVTL
        sbc     MAL
        sta     FEVTL
        lda     FEVTH
        sbc     MAH
        sta     FEVTH
        rts

; foe_addn - v += FET * n.
foe_addn:
        lda     FET0
        sta     MAL
        lda     FET1
        sta     MAH
        lda     FENX
        sta     MB
        jsr     smul16q7
        ldx     FEI
        clc
        lda     FOEVXL,x
        adc     MAL
        sta     FOEVXL,x
        lda     FOEVXH,x
        adc     MAH
        sta     FOEVXH,x
        lda     FET0
        sta     MAL
        lda     FET1
        sta     MAH
        lda     FENY
        sta     MB
        jsr     smul16q7
        ldx     FEI
        clc
        lda     FOEVYL,x
        adc     MAL
        sta     FOEVYL,x
        lda     FOEVYH,x
        adc     MAH
        sta     FOEVYH,x
        rts

; foe_addt - v += FET * t, t = (-ny, nx).
foe_addt:
        lda     FET0
        sta     MAL
        lda     FET1
        sta     MAH
        lda     FENY
        sta     MB
        jsr     smul16q7
        ldx     FEI
        sec
        lda     FOEVXL,x
        sbc     MAL
        sta     FOEVXL,x
        lda     FOEVXH,x
        sbc     MAH
        sta     FOEVXH,x
        lda     FET0
        sta     MAL
        lda     FET1
        sta     MAH
        lda     FENX
        sta     MB
        jsr     smul16q7
        ldx     FEI
        clc
        lda     FOEVYL,x
        adc     MAL
        sta     FOEVYL,x
        lda     FOEVYH,x
        adc     MAH
        sta     FOEVYH,x
        rts

; foe_vcap - each axis of the velocity clamped to +/-FOE_VCAP.
foe_vcap:
        ldx     FEI
        lda     FOEVXH,x
        bmi     @xn
        cmp     #>FOE_VCAP
        bcc     @y
        lda     #<FOE_VCAP
        sta     FOEVXL,x
        lda     #>FOE_VCAP
        sta     FOEVXH,x
        bra     @y
@xn:    cmp     #>(-FOE_VCAP)
        bcs     @y
        lda     #<(-FOE_VCAP)
        sta     FOEVXL,x
        lda     #>(-FOE_VCAP)
        sta     FOEVXH,x
@y:     lda     FOEVYH,x
        bmi     @yn
        cmp     #>FOE_VCAP
        bcc     @done
        lda     #<FOE_VCAP
        sta     FOEVYL,x
        lda     #>FOE_VCAP
        sta     FOEVYH,x
        rts
@yn:    cmp     #>(-FOE_VCAP)
        bcs     @done
        lda     #<(-FOE_VCAP)
        sta     FOEVYL,x
        lda     #>(-FOE_VCAP)
        sta     FOEVYH,x
@done:  rts

; =============================================================================
; What runs at most once a frame, or once a level - HIDATA, at $A000 (cart.cfg's
; note on bank 3): the shot, the kill, the wreck's launch and the level load.
; =============================================================================
        .segment "HIDATA"

; -----------------------------------------------------------------------------
; fsh_fire - FEI fires along FEANG (FESIN/FECOS). Carry SET = no free bullet.
; -----------------------------------------------------------------------------
; The gun's bullet, but NOT the gun's velocity rule: the ship's bullet inherits
; the ship's speed, and this one does not inherit the UFO's. It is aimed, and a
; bullet carrying the shooter's sideways drift would not fly where it was aimed.
; -----------------------------------------------------------------------------
fsh_fire:
        ldy     #FSH_N-1
@find:  lda     FSLIVE,y
        beq     @got
        dey
        bpl     @find
        sec
        rts
@got:   sty     FSI
        lda     #<FOE_MUZZ              ; the muzzle: FOE_MUZZ along the aim
        sta     MAL
        lda     #>FOE_MUZZ
        sta     MAH
        lda     FESIN
        sta     MB
        jsr     smul16q7
        ldx     FEI
        ldy     FSI
        lda     FOEXF,x
        sta     FSXF,y
        clc
        lda     FOEXL,x
        adc     MAL
        sta     FSXL,y
        lda     FOEXH,x
        adc     MAH
        sta     FSXH,y
        lda     #<FOE_MUZZ
        sta     MAL
        lda     #>FOE_MUZZ
        sta     MAH
        lda     FECOS
        sta     MB
        jsr     smul16q7
        ldx     FEI
        ldy     FSI
        lda     FOEYF,x
        sta     FSYF,y
        sec                             ; ...minus the cosine term on y
        lda     FOEYL,x
        sbc     MAL
        sta     FSYL,y
        lda     FOEYH,x
        sbc     MAH
        sta     FSYH,y
        lda     #<SHOT_SPD              ; SHOT_SPD along the aim, 16.8 with no
        sta     MAL                     ;   fraction
        lda     #>SHOT_SPD
        sta     MAH
        lda     FESIN
        sta     MB
        jsr     smul16q7
        ldy     FSI
        lda     #$00
        sta     FSVXL,y
        lda     MAL
        sta     FSVXH,y
        lda     MAH
        sta     FSVXT,y
        lda     #<SHOT_SPD
        sta     MAL
        lda     #>SHOT_SPD
        sta     MAH
        lda     FECOS
        sta     MB
        jsr     smul16q7
        ldy     FSI
        lda     #$00
        sta     FSVYL,y
        sec
        lda     #$00
        sbc     MAL
        sta     FSVYH,y
        lda     #$00
        sbc     MAH
        sta     FSVYT,y
        lda     FEANG
        sta     FSANG,y
        lda     #$00
        sta     FSAGE,y
        sta     FSSEEN,y
        sta     FSPOK,y
        lda     #$01
        sta     FSLIVE,y
        lda     #SE_UFO_SHOT
        jsr     sfx_fire
        clc
        rts

; -----------------------------------------------------------------------------
; foe_alarm - FEI has just seen the ship. If no other UFO is already chasing it,
; the ALARM: three beeps (SE_ALARM) and ENEMY DETECTED on the message bar.
; -----------------------------------------------------------------------------
; Only the FIRST: the warning is "you are being hunted", and a second UFO
; joining a chase already under way is not news - it would restart the beeps
; over the top of themselves. A UFO that loses the ship and finds it again
; sounds it again, if it is the only one on it by then. The bar de-duplicates
; against what it is already showing, so it cannot stack either.
; -----------------------------------------------------------------------------
foe_alarm:
        ldy     NFOE
@lp:    dey
        bmi     @sound
        cpy     FEI
        beq     @lp
        lda     FOEST,y
        cmp     #FS_PURSUE
        bne     @lp
        rts                             ; somebody is already on it
@sound: lda     #SE_ALARM
        jsr     sfx_fire
        lda     #IM_ENEMY
        jmp     indicate_msg            ; tail (clobbers A and X)

; -----------------------------------------------------------------------------
; foe_kill - FEI is out of hit points.
; -----------------------------------------------------------------------------
; A rock's death in every way the player can hear and see - the boom and the
; flash (rock_boom), the break shake, the puff - and then the wreck. The slot
; is simply marked dead: nothing walks the enemies by anything but FOEST.
; -----------------------------------------------------------------------------
foe_kill:
        ldx     FEI
        stz     FOEST,x
        stz     FOEON,x
        lda     #SCORE_FOE_KILL
        jsr     score_add
        jsr     rock_boom
        lda     #SHK_SHIFT_BREAK
        jsr     shake_arm
        ldx     FEI
        lda     FOEXL,x
        sta     EXTXL
        lda     FOEXH,x
        sta     EXTXH
        lda     FOEYL,x
        sta     EXTYL
        lda     FOEYH,x
        sta     EXTYH
        jsr     expl_at
        ; fall through into the wreck

; -----------------------------------------------------------------------------
; fw_spawn - FEI's parts, launched as pieces.
; -----------------------------------------------------------------------------
; debris.s's recipe, with parts where the ship has runs: each part's pivot is
; the middle of its own bounding box, and it is thrown out along the line from
; the WHOLE shape's middle to that pivot, times FW_K, with some jitter. For the
; UFO that sends the dome up and off and the hull down, tumbling apart.
; -----------------------------------------------------------------------------
fw_spawn:
        jsr     fw_centre
        stz     FEWP
@part:  ldy     #FW_N-1
@find:  lda     FWN,y
        beq     @got
        dey
        bpl     @find
        rts                             ; no piece free: the rest is not drawn
@got:   sty     FEWI
        ldy     FEWP
        lda     EN_UFO_PLO,y
        sta     SHPL
        lda     EN_UFO_PHI,y
        sta     SHPH
        ldy     #$00
        lda     (SHPL),y
        and     #$7F
        sta     FEWJ
        lda     #$00                    ; fb_x: the pivot, then the launch
        jsr     fw_pivot
        ldx     FEWI
        sta     FWCX,x
        sta     FWPXH,x
        stz     FWPXL,x
        sec
        sbc     FEWOX
        jsr     fw_scale
        jsr     fw_jitter
        ldx     FEWI
        lda     FEWR0
        sta     FWVXL,x
        lda     FEWR1
        sta     FWVXH,x
        lda     #$01                    ; ...and fb_y, the same three steps
        jsr     fw_pivot
        ldx     FEWI
        sta     FWCY,x
        sta     FWPYH,x
        stz     FWPYL,x
        sec
        sbc     FEWOY
        jsr     fw_scale
        jsr     fw_jitter
        ldx     FEWI
        lda     FEWR0
        sta     FWVYL,x
        lda     FEWR1
        sta     FWVYH,x
        ldy     FEI                     ; anchored where the UFO was
        lda     FOEXL,y
        sta     FWAXL,x
        lda     FOEXH,y
        sta     FWAXH,x
        lda     FOEYL,y
        sta     FWAYL,x
        lda     FOEYH,y
        sta     FWAYH,x
        lda     FEWP
        sta     FWPART,x
        stz     FWANG,x
        jsr     prng                    ; a tumble that is never zero - see
        and     #(2*FW_SPIN-1)          ;   debris.s's note on why
        sec
        sbc     #FW_SPIN
        bmi     :+
        inc     a
:       ldx     FEWI
        sta     FWSPN,x
        lda     #FW_FRAMES
        sta     FWN,x
        inc     FEWP
        lda     FEWP
        cmp     #EN_UFO_PN
        bcs     :+
        jmp     @part
:       rts

; fw_pivot - A = axis (0 fb_x, 1 fb_y) -> A = the middle of SHPL's part's box on
; that axis. FEWJ = its vertex count. EXCESS-128, as debris.s's debris_pivot.
fw_pivot:
        clc
        adc     #$01
        sta     FEWV
        tay
        lda     (SHPL),y
        eor     #$80
        sta     FEWMN
        sta     FEWMX
        lda     FEWJ
        sta     FEWW
@lp:    ldy     FEWV
        lda     (SHPL),y
        eor     #$80
        cmp     FEWMN
        bcs     :+
        sta     FEWMN
:       cmp     FEWMX
        bcc     :+
        sta     FEWMX
:       inc     FEWV
        inc     FEWV
        dec     FEWW
        bne     @lp
        clc
        lda     FEWMN
        adc     FEWMX
        ror     a
        sec
        sbc     #$80
        rts

; fw_centre - FEWOX/FEWOY = the middle of the box round ALL the parts.
fw_centre:
        lda     #$00
        jsr     @axis
        sta     FEWOX
        lda     #$01
        jsr     @axis
        sta     FEWOY
        rts
@axis:  sta     FEWA
        lda     #$FF
        sta     FEWMN
        stz     FEWMX
        stz     FEWP
@part:  ldy     FEWP
        lda     EN_UFO_PLO,y
        sta     SHPL
        lda     EN_UFO_PHI,y
        sta     SHPH
        ldy     #$00
        lda     (SHPL),y
        and     #$7F
        sta     FEWW
        lda     FEWA
        clc
        adc     #$01
        sta     FEWV
@lp:    ldy     FEWV
        lda     (SHPL),y
        eor     #$80
        cmp     FEWMN
        bcs     :+
        sta     FEWMN
:       cmp     FEWMX
        bcc     :+
        sta     FEWMX
:       inc     FEWV
        inc     FEWV
        dec     FEWW
        bne     @lp
        inc     FEWP
        lda     FEWP
        cmp     #EN_UFO_PN
        bcc     @part
        clc
        lda     FEWMN
        adc     FEWMX
        ror     a
        sec
        sbc     #$80
        rts

; fw_scale - A = a signed byte -> FEWR0/FEWR1 = A * FW_K, signed 16. debris.s's
; db_scale with its own constant.
fw_scale:
        sta     FEWT0
        ldx     #$00
        cmp     #$80
        bcc     :+
        ldx     #$FF
:       stx     FEWT1
        stz     FEWR0
        stz     FEWR1
        lda     #FW_K
        sta     FEWK
@lp:    lsr     FEWK
        bcc     @no
        clc
        lda     FEWR0
        adc     FEWT0
        sta     FEWR0
        lda     FEWR1
        adc     FEWT1
        sta     FEWR1
@no:    asl     FEWT0
        rol     FEWT1
        lda     FEWK
        bne     @lp
        rts

; fw_jitter - FEWR += a signed nudge in -FW_JIT .. FW_JIT-1.
fw_jitter:
        jsr     prng
        and     #(2*FW_JIT-1)
        sec
        sbc     #FW_JIT
        ldx     #$00
        cmp     #$80
        bcc     :+
        ldx     #$FF
:       clc
        adc     FEWR0
        sta     FEWR0
        txa
        adc     FEWR1
        sta     FEWR1
        rts

; -----------------------------------------------------------------------------
; load_foes - the level's enemies out of levels.s, once, from game_start.
; -----------------------------------------------------------------------------
; After load_level, which has left LVLIX on the level. Everything a game in
; progress could have left behind is cleared first - the slots, the bullets,
; the wreck - because nothing zeroes cartridge RAM for us and game_start runs
; again on every restart. A record whose KIND nothing knows how to fly is
; skipped rather than loaded as a UFO in disguise.
; -----------------------------------------------------------------------------
load_foes:
        stz     NFOE
        stz     FOEKILL
        ldx     #FOE_MAX-1
:       stz     FOEST,x
        stz     FOEON,x
        stz     FOESLP,x
        dex
        bpl     :-
        ldx     #FSH_N-1
:       stz     FSLIVE,x
        dex
        bpl     :-
        ldx     #FW_N-1
:       stz     FWN,x
        dex
        bpl     :-
        ldx     LVLIX
        lda     LVL_FOEN,x
        bne     :+
        rts
:       sta     FELN
        lda     LVL_FOELO,x
        sta     T0
        lda     LVL_FOEHI,x
        sta     T1
@lp:    ldy     #FOE_REC-1              ; stage the record
:       lda     (T0),y
        sta     FEREC,y
        dey
        bpl     :-
        lda     NFOE                    ; a level that authors more than there
        cmp     #FOE_MAX                ;   are slots loses the tail, quietly
        bcs     @skip
        lda     FEREC+4
        cmp     #FK_UFO
        bne     @skip
        jsr     foe_spawn
@skip:  clc
        lda     T0
        adc     #FOE_REC
        sta     T0
        bcc     :+
        inc     T1
:       dec     FELN
        bne     @lp
        rts

; foe_spawn - FEREC into slot NFOE, on patrol, full of hit points.
foe_spawn:
        ldx     NFOE
        lda     FEREC+0
        sta     FOEXL,x
        sta     FOEAXL,x
        lda     FEREC+1
        sta     FOEXH,x
        sta     FOEAXH,x
        lda     FEREC+2
        sta     FOEYL,x
        sta     FOEAYL,x
        lda     FEREC+3
        sta     FOEYH,x
        sta     FOEAYH,x
        lda     FEREC+4
        sta     FOEKIND,x
        stz     FOEXF,x
        stz     FOEYF,x
        stz     FOECD,x
        stz     FOERAM,x
        stz     FOEON,x
        lda     #$01
        sta     FOENEW,x
        lda     #FS_PATROL
        sta     FOEST,x
        lda     #FOE_HP
        sta     FOEHP,x
        lda     FEREC+6
        sta     FOEPSPD,x

        sta     FET0                    ; px/s -> 8.8 world units a frame: x68,
        stz     FET1                    ;   which is 16 units a pixel over 60.317
        asl     FET0                    ;   frames, times 256, to 0.2% - as x64
        rol     FET1                    ;   plus x4
        asl     FET0
        rol     FET1
        lda     FET0
        sta     FET2
        lda     FET1
        sta     FET3
        ldy     #4
:       asl     FET0
        rol     FET1
        dey
        bne     :-
        clc
        lda     FET0
        adc     FET2
        sta     FET0
        lda     FET1
        adc     FET3
        sta     FET1

        lda     FEREC+5                 ; ...along the heading: (sin, -cos)
        jsr     API_SIN
        sta     MB
        lda     FET0
        sta     MAL
        lda     FET1
        sta     MAH
        jsr     smul16q7
        ldx     NFOE
        lda     MAL
        sta     FOEPVXL,x
        sta     FOEVXL,x
        lda     MAH
        sta     FOEPVXH,x
        sta     FOEVXH,x
        lda     FEREC+5
        jsr     API_COS
        sta     MB
        lda     FET0
        sta     MAL
        lda     FET1
        sta     MAH
        jsr     smul16q7
        ldx     NFOE
        sec
        lda     #$00
        sbc     MAL
        sta     FOEPVYL,x
        sta     FOEVYL,x
        lda     #$00
        sbc     MAH
        sta     FOEPVYH,x
        sta     FOEVYH,x
        inc     NFOE
        rts

; =============================================================================
; Tables
; =============================================================================
        .segment "RODATA"

; A think period, as a shift, -> the phase mask and the acceleration it carries.
FE_PMASK:   .byte   0, 1, 3, 7
FE_ACCL:    .byte   <FOE_ACC, <(FOE_ACC*2), <(FOE_ACC*4), <(FOE_ACC*8)
FE_ACCH:    .byte   >FOE_ACC, >(FOE_ACC*2), >(FOE_ACC*4), >(FOE_ACC*8)

; atan(t/128) in brad, t = 0..128 - the angle inside one octant, for foe_atan.
; round(atan(t/128) * 128/pi); the last entry is 45 degrees, 32 brad.
ATAN_T:
        .byte    0,  0,  1,  1,  1,  2,  2,  2,  3,  3,  3,  3,  4,  4,  4,  5
        .byte    5,  5,  6,  6,  6,  7,  7,  7,  8,  8,  8,  8,  9,  9,  9, 10
        .byte   10, 10, 11, 11, 11, 11, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14
        .byte   15, 15, 15, 15, 16, 16, 16, 17, 17, 17, 17, 18, 18, 18, 18, 19
        .byte   19, 19, 19, 20, 20, 20, 20, 21, 21, 21, 21, 22, 22, 22, 22, 23
        .byte   23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 25, 26, 26, 26
        .byte   26, 26, 27, 27, 27, 27, 27, 28, 28, 28, 28, 28, 29, 29, 29, 29
        .byte   29, 29, 30, 30, 30, 30, 30, 31, 31, 31, 31, 31, 31, 32, 32, 32
        .byte   32

        .segment "CODE2"                ; back to the segment main.s included
                                        ;   this file inside
