; =============================================================================
; shots.s - the gun: six line bullets, and what one does when it reaches a rock
; =============================================================================
; A bullet is a LINE, not a dot and not a sprite: one $4E POLYGON16 with the
; OPEN flag set, two vertices, ten full-res pixels long against the ship's
; thirty-two. That is the whole draw. The GPU rotates it, scales it by the zoom
; and clips it, exactly as it does a rock's outline - the only difference is
; N's top bit, which says "these K vertices are K-1 segments, not a closed
; figure". Two vertices closed would be the same segment drawn twice.
;
; THE BULLET LIVES IN THE WORLD, AND DIES ON THE SCREEN. Those are two separate
; decisions and it is worth being clear which is which:
;
;   * its POSITION is a world position, 16.8 per axis like a rock's, and it is
;     transformed to the screen every frame through view_xform and zoom_fb. It
;     has to be. The camera turns about the ship, so a bullet held in screen
;     coordinates would swing round with the turn instead of carrying straight
;     on - and carrying straight on, while the world rotates around it, is the
;     entire thing this prototype exists to look at.
;   * its LIFETIME is the screen. There is no timer and no world wrap: when the
;     transform puts it past the edge, the slot is freed. Six slots, so six in
;     flight, and at eight pixels a frame plus the ship's speed a bullet crosses
;     the screen in twenty to forty frames.
;
; This is NOT what design_technical 8 assumed - "shots are objects in the same
; pool with a lifetime, so they wrap and collide like everything else" - nor
; what open_questions D2 assumed, which had shots as pre-scaled sprites. A
; vector line scales for nothing where a sprite needs a frame per zoom step, and
; a shot that cannot leave the screen needs neither the wrap nor the pool. Both
; of those are prototype decisions and both are the user's; if the line reads
; badly in flight, the sprite is still on the table.
;
; THE MUZZLE is vertex 13 of SHIP_SHAPE, (-22, 0) - the nose spike. A negative
; dx is forward (see shapes.s), so the gun sits 22 full-res pixels ahead of the
; ship's centre, which is 352 world units. The bullet is anchored at its own
; TIP and spawned SHOT_MUZZ ahead of that, so the whole ten-pixel line clears
; the nose instead of being drawn back through it.
;
; SPEED is the ship's velocity at the moment of the shot plus SHOT_SPD along the
; heading. Both are needed - inheriting the ship's velocity is what stops a
; bullet fired at top speed being overtaken by the ship that fired it - and it
; is why the velocity is 16.8 and not the 8.8 a rock's is: 12 px/frame is 192
; world units on its own, the boost is another 186, and signed 8.8 stops at 128.
;
; HITTING is done on the SCREEN, against the visible list do_objects has already
; built, and that is the cheap way round precisely because the bullet's life is
; the screen: a rock the player cannot see is not a rock this file can hit. The
; test is physics.s's narrow phase with the sign work taken out - one box reject
; and then |d|^2 against r^2 out of the quarter-square table, no multiply.
;
; WHAT IT COSTS, AND WHAT IS STILL UNMEASURED. On CPU1, over the harness's
; 200-frame flight with the gun firing throughout: 74.1% of the frame against
; 69.2% for the same flight with no gun, so the whole feature is about 11,600
; cycles of a 237,404-cycle frame. PPRAM goes from 262 steady bytes to 334,
; which is exactly the six 12-byte commands.
;
; The GPU side is NOT measured. Six one-segment POLYGON16 commands cost it
; something, and AST_NONROCK (main.s) - the rock-free frame the outline budget
; is derived from - has not been raised to cover them. That number is madsim's
; F3 meter to take, not this harness's: preview.py renders the list but does not
; model the GPU's clock. Until it is taken, the outline budget is optimistic by
; whatever the shots cost, and the low-water mark it actually reached on that
; flight was 72 of 104 - so there is room for the correction, but it is a
; correction that is owed.
; =============================================================================

; --- tunables ----------------------------------------------------------------
SHOT_N      = 6                 ; bullets in flight at once. The ceiling on the
                                ;   arrays below and, with one shot per press,
                                ;   the ceiling on the rate too
SHOT_LEN    = 10                ; full-res pixels, tip to tail, at 1:1. The GPU
                                ;   scales it with the zoom like everything else
SHOT_SPD    = 192               ; world units a frame, ADDED to the ship's own
                                ;   velocity. A world unit is 1/16 of a full-res
                                ;   pixel, so this is 12 px a frame - flown and
                                ;   chosen, up from the 8 the first cut had.
                                ;   Worst case is this plus the boost's 186,
                                ;   which is why the velocity is 16.8
SHOT_MUZZ   = 512               ; ...and where it starts: 32 full-res px ahead of
                                ;   the ship's centre, which is the 22 px to the
                                ;   nose plus the bullet's own 10, so the line
                                ;   begins just clear of the gun
SHOT_MARG   = 24                ; how far past the screen edge the TIP may go
                                ;   before the slot is freed. More than the
                                ;   bullet's own length, so it leaves cleanly
                                ;   rather than being cut off mid-flight
SHT_SWEEP   = 36                ; how far BEHIND its tip a bullet still counts
                                ;   as having been, in full-res screen pixels at
                                ;   1:1 - its own drawn length of 10 plus the 24
                                ;   it can travel in a frame with the boost on.
                                ;   See the note on tunnelling below

HIT_M       = 80                ; the hit pass's screen window, full-res px. The
                                ;   largest a rock's collision circle can be on
                                ;   screen is class 192 at 1:1 - BODY_R 39,
                                ;   half-res, doubled = 78 - so a rock further
                                ;   than this outside the field cannot be
                                ;   touching a bullet, which by definition is
                                ;   inside it. See shot_hits.

; --- what a hit does to the rock ---------------------------------------------
; A shot twists the rock it lands on. Which way, and how hard, is one number:
; the CROSS PRODUCT of where the hit landed against the way the bullet was
; going. That is not a fancier way of saying "left or right of centre" - it IS
; left or right of centre, measured against the shot's own direction instead of
; against the screen, which is the only frame of reference that means anything
; when both the rock and the camera are turning.
;
;     twist  =  r x v   =  dx*sin(A) - dy*cos(A)
;
; where (dx, dy) is the rock's centre minus the hit point on the screen and A is
; the bullet's screen heading - the same byte shot_draw hands the GPU. Its SIGN
; is which side of the centre the shot went past, and its MAGNITUDE is the
; perpendicular distance from the centre to the shot's line: the lever arm. Both
; fall out of the same two products, so the arm costs nothing extra - and it is
; worth having, because without it a shot straight through the middle of a rock
; would spin it exactly as hard as one that grazed the rim, which is the one
; case anybody would notice being wrong.
;
; The world -> framebuffer map is a pure rotation (main.s), so the sign of a
; cross product survives it: the twist computed in screen coordinates is the
; twist in the world.
;
; DIVIDED BY THE ZOOM, because the arm is measured in SCREEN pixels and the same
; hit has to mean the same thing whether the camera is pulled back or not.
; 128/RZ in Q0.7 is 128 + TPQ[RZ-64] - the table the teleport already builds its
; distance out of - and the 128 is just "the arm itself", which is what keeps
; the multiplier inside a signed byte.
;
; AND BY THE MASS, per size class, which is what SPIN_G below is: bigger rocks
; are harder to spin. It halves per class - the same power-of-two mass ladder
; physics.s's impulse runs on (BODY_ME) - so a rim hit moves the smallest rock's
; spin by 3.0 brad a frame and a 192's by 0.1875. Against AST_SPIN's own rates
; (1.50 for the smallest, 0.09 for the 192) both are plainly visible, which is
; the point: "less susceptible" has to stay short of "immune".
;
; A true rigid body would fall as 1/(m*r), i.e. a QUARTER per class, and that
; was tried: it makes the two big classes not move at all. This is the honest
; number to argue with, and it is one table.
SPIN_MAX    = $0400             ; the ceiling on |spin|, 8.8 brad per frame - 4.0
                                ;   is a revolution in 64 frames. Without it a
                                ;   rock worked over at close range keeps taking
                                ;   kicks until it is a blur

; --- the mini explosion ------------------------------------------------------
; A hit throws a small cloud of DOT_PIXELS off the point it landed on: eight
; single pixels, thrown outwards, slowing as they go, thinning out and gone in a
; tenth of a second. NOT scaled and NOT rotated - the offsets are half-res
; pixels and they are added to the hit point exactly as authored.
;
; THE WHOLE ANIMATION IS A TABLE. EXPL_OFF holds, for each of EXPL_SETS clouds
; and each of EXPL_AGES frames, the eight (dx, dy) offsets from the centre -
; so a frame of a puff is eight table reads and eight adds, with no multiply, no
; per-dot state and no integration. That is also what buys the SHAPE of it: the
; radii ease OUT (fast, then slowing) because they were authored that way, not
; because anything is decelerating at run time, and each cloud is irregular in
; both angle and radius because a ring of eight evenly spaced pixels reads as a
; machined part, exactly as a regular polygon does for a rock.
;
; It is anchored in the WORLD, like a bullet and for the same reason: over six
; frames a hard turn sweeps 34 degrees, and a puff pinned to the screen would
; visibly slide off the rock it came from. One view_xform each, and there are at
; most EXPL_N of them.
;
; IT SCALES WITH THE ZOOM, AND IT COSTS NOTHING TO. The puff used to be a fixed
; number of screen pixels across at every zoom, which meant it was twice the
; size RELATIVE TO THE ROCKS when the camera was pulled all the way back - and
; that is the version that looked right. Keeping that proportion at every zoom
; means the cloud has to grow as the camera pushes in, and the obvious way to do
; that - multiply each offset by ZEASH - is 16 multiplies per puff per frame,
; which is the one thing this file was built to avoid.
;
; So the SIZE IS PART OF THE TABLE, not applied to it. EXPL_OFF is authored at
; EXPL_SIZES scales, the size is chosen ONCE when the puff is spawned, and it is
; folded into the same block index the cloud number already goes through. The
; per-frame code is byte-for-byte what it was: one table read for the base, one
; add for the age. Zero cycles, EXPL_SIZES x 1,536 bytes of a bank that has the
; room.
;
; Choosing at SPAWN rather than per frame is not a shortcut either, it is the
; better behaviour: a puff keeps the size it was born at for its whole life, so
; it can never step between two authored sizes while the player watches it -
; which is exactly the defect the rocks' own SCALE had when it read the snapped
; zoom rung instead of the eased one (objects.s).
;
; Two sizes split the zoom's octave in half, so the cloud is within about 20% of
; a true continuous scale anywhere in the range. A third size would halve that
; again for another 1,536 bytes, and the numbers to change are EXPL_SIZES, the
; scale list in the generator note below, and EXPL_ZBIG.
;
; This is a PROTOTYPE of the effect, not a decision - the design's own answer
; (design_technical 11.9, open_questions D2) is that sprites are for art that is
; not an outline, and a scaled sprite may well win here. Pixels are what is
; cheap to try.
EXPL_N      = 6                 ; puffs at once. Six bullets can land in one
                                ;   frame, so six covers the worst honest case
EXPL_SETS   = 4                 ; authored clouds, picked in turn - see EXPL_OFF
EXPL_SIZES  = 2                 ; ...and how many SIZES each is authored at, for
                                ;   the zoom. See the note on scaling below
EXPL_ZBIG   = 96                ; the reciprocal at or above which a new puff
                                ;   takes the big cloud. ZEASH runs 64..128, so
                                ;   this splits the zoom's one octave in half
EXPL_AGES   = 24                ; frames one lasts: 0.40 s at 60.317 Hz. It was
                                ;   6, and the whole thing went by too fast to
                                ;   read; four times as many AUTHORED frames is
                                ;   how it slows down, not a divider holding
                                ;   each one for four - that would step instead
                                ;   of moving. The table is 4x bigger and every
                                ;   frame of it still costs eight adds
EXPL_DOTS_N = 8                 ; pixels in a cloud, at its fullest

; --- state, in free game RAM above thrust.s's block --------------------------
; Six-entry arrays on an eight-byte stride: the slot is the index, so every
; access is one abs,x and the spare two bytes buy room to raise SHOT_N to 8
; without moving anything.
SHTLIVE     = $7100             ; 0 = the slot is free
SHTXF       = $7108             ; world position, 16.8 - fraction, low, high, the
SHTXL       = $7110             ;   same layout a rock's OBJX has
SHTXH       = $7118
SHTYF       = $7120
SHTYL       = $7128
SHTYH       = $7130
SHTVXL      = $7138             ; world velocity, signed 16.8 - fraction, low,
SHTVXH      = $7140             ;   TOP. Three bytes because the ship's own is
SHTVXT      = $7148             ;   three (see the header)
SHTVYL      = $7150
SHTVYH      = $7158
SHTVYT      = $7160
SHTANG      = $7168             ; the heading it was fired on. The bullet does
                                ;   not turn, so this never changes; what changes
                                ;   is HEAD, and the drawn angle is the difference
SHTFXL      = $7170             ; ...and this frame's full-res screen point,
SHTFXH      = $7178             ;   signed 16, computed once and then read by the
SHTFYL      = $7180             ;   hit pass and the draw pass
SHTFYH      = $7188

SHTI        = $7190             ; the slot each pass is standing on
SHTJ        = $7191             ; ...and the inner one, over the bullets, while
                                ;   the outer walks the visible rocks
SHTVI       = $7192             ; the hit pass's cursor into the visible list -
                                ;   its own, because VISI belongs to
                                ;   emit_asteroids and that has already run
SHTOBJ      = $7193             ; the rock the hit pass is standing on
SHTR        = $7194             ; ...and its collision radius, FULL-res px
SHTADX      = $7195             ; |d| per axis, screen px, once the box reject
SHTADY      = $7196             ;   has proved it fits in a byte
SHTRW       = $7197             ; ...and the WIDE radius the reject uses: the
                                ;   rock's own plus the bullet's sweep
SHTR128     = $7198             ; R * 128 and SWEEP * 128, because the swept test
SHTR129     = $7199             ;   below compares RAW products and never shifts
SHTL128     = $719A             ;   them down
SHTL129     = $719B
SHTALO      = $719C             ; along the bullet's axis, and across it - both
SHTALO1     = $719D             ;   raw, i.e. 128x the pixel value
SHTPRP      = $719E
SHTPRP1     = $719F
SHTSWP      = $73A3             ; the sweep length at THIS zoom, screen px
SPL_TYA     = $73A4             ; the two halves' authored variants, drawn once
SPL_TYB     = $73A5             ;   and DIFFERENT - see rock_split
SHTC        = $7020             ; per bullet: the cosine and sine of its screen
SHTS        = $7028             ;   heading, worked out once a frame in shot_move
                                ;   and read by every rock the hit pass walks

SHTDX       = $71F9             ; the rock's centre from the bullet's TIP,
SHTDY       = $71FA             ;   signed screen px - what shot_swept turns into
                                ;   an along/across pair

EXTXL       = $71FB             ; where the next puff goes, when it is not a
EXTXH       = $71FC             ;   bullet asking - see expl_at
EXTYL       = $71FD
EXTYH       = $71FE

SPDX        = $71F0             ; rock_spin's scratch: the hit point relative to
SPDY        = $71F1             ;   the rock's centre, signed screen px
SPANG       = $71F2             ; the bullet's screen heading...
SPS         = $71F3             ; ...and its sine and cosine, signed Q0.7
SPC         = $71F4
SPP         = $71F5             ; the first product of the cross, RAW and signed
SPP1        = $71F6             ;   16-bit - see rock_spin
SPT0        = $71F7             ; ...and the second, which doubles as a 16-bit
SPT1        = $71F8             ;   hold across the multiplies

EXLIVE      = $71A0             ; the puffs, on the same eight-byte stride
EXXL        = $71A8             ; where it happened, in the WORLD. 16 bits and no
EXXH        = $71B0             ;   fraction: a puff does not move, and a
EXYL        = $71B8             ;   sixteenth of a pixel is not visible on one
EXYH        = $71C0
EXSET       = $71C8             ; which BLOCK GROUP of EXPL_OFF this puff reads:
                                ;   size * EXPL_SETS + cloud, combined once at
                                ;   spawn so the per-frame lookup stays one
                                ;   table read - see the scaling note above
EXAGE       = $71D0             ; ...and how many frames it has been going

EXSEQ       = $71D8             ; the cloud picker, free-running
EXI         = $71D9             ; the draw loop's slot
EXDI        = $71DA             ; write cursor into EXPLBUF
EXN         = $71DB             ; dots that survived the clip, all puffs together
EXCXL       = $71DC             ; this puff's HALF-res centre, signed 16
EXCXH       = $71DD
EXCYL       = $71DE
EXCYH       = $71DF
EXDX        = $71E0             ; the offset pair being placed
EXDY        = $71E1
EXPX        = $71E2             ; ...and where it landed, once it is on screen
EXPY        = $71E3
EXSTOP      = $71E4             ; bytes of the block this age still draws
EXY         = $71E5             ; the block cursor, parked over the clip
EXPLBUF     = $7300             ; 1 + 2*EXPL_N*EXPL_DOTS_N: the DOT_PIXELS
                                ;   payload every live puff writes into, so all
                                ;   of them go out as ONE command
EXPTR       = $F2               ; the zero-page pointer into EXPL_OFF. $F2-$F4 is
                                ;   the bootstrap's old scratch, dead by the
                                ;   first frame; radar.s took $F0/$F1 of it

; -----------------------------------------------------------------------------
; do_shots — the whole of the gun, in three passes.
; -----------------------------------------------------------------------------
; Three loops rather than one, and the order is what makes each one simple:
;
;   move   integrate, transform, free the slots that left the screen
;   hits   walk the VISIBLE ROCKS, and test the live bullets against each
;   draw   whatever is still alive
;
; The hit pass is the reason for the split. It is rock-outer and bullet-inner
; because the rock is what costs something to set up - one qmul for its screen
; radius - and the bullet side of the test is a subtract and a compare. Six
; bullets against a dozen rocks is ~70 of those, which is why they are cheaper
; walked this way round, and the bullets' screen points have to exist before it
; starts. Drawing last means a bullet that hit this frame is never drawn: what
; the player sees at the impact point is the hit, not the shot that made it.
; -----------------------------------------------------------------------------
do_shots:
        jsr     rock_sweep              ; the debris the split leaves behind, put
                                        ;   back on the free stack before
                                        ;   anything asks for a slot
        jsr     shot_fire
        jsr     shot_move
        jsr     shot_hits
        ; fall through into shot_draw

; -----------------------------------------------------------------------------
; shot_draw — one OPEN POLYGON16 per live bullet.
; -----------------------------------------------------------------------------
; The argument block is PBUF, the same seven-byte header a rock's is - the three
; of them are never live at once (see main.s's note on PBUF). N is $82: bit 7
; says OPEN, and the low bits say two vertices, so the GPU draws exactly one
; segment and does not join the ends.
;
; ANGLE is (the heading it was fired on) - (the heading now), which is how a
; rock's spin composes with the camera and means the same thing here: fire and
; then turn, and the bullet visibly keeps its own heading while the world swings
; round it. At the instant of the shot the two are equal, the angle is 0, and
; the line draws straight up the screen out of the nose.
; -----------------------------------------------------------------------------
shot_draw:
        lda     #SHOT_N-1
        sta     SHTI
@lp:    ldx     SHTI
        lda     SHTLIVE,x
        beq     @next
        lda     SHTFXL,x
        sta     PBUF+0
        lda     SHTFXH,x
        sta     PBUF+1
        lda     SHTFYL,x
        sta     PBUF+2
        lda     SHTFYH,x
        sta     PBUF+3
        sec
        lda     SHTANG,x
        sbc     HEAD
        sta     PBUF+4
        lda     ZEASH                   ; the same eased zoom reciprocal the ship
        sta     PBUF+5                  ;   and the rocks are scaled by
        lda     #$80 | 2                ; OPEN, two vertices - one segment
        sta     PBUF+6
        stz     PBUF+7                  ; the TIP, on the anchor itself...
        stz     PBUF+8
        lda     #SHOT_LEN               ; ...and the tail astern of it, +dx being
        sta     PBUF+9                  ;   backwards (shapes.s: the nose is -dx)
        stz     PBUF+10
        lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jsr     API_GPU_POLYGON16
@next:  dec     SHTI
        bpl     @lp
        rts

; -----------------------------------------------------------------------------
; shot_fire — joystick 1 FIRE, on the edge: one bullet per press.
; -----------------------------------------------------------------------------
; JOY1_PRESS and not JOY1, so holding the button does nothing after the first
; frame. With no cadence timer the six slots are the only rate limit there is.
;
; It runs inside do_shots rather than in input.s, which reads every other
; control, for one reason: the muzzle needs SINV/COSV and the ship's integrated
; position, and neither exists yet when do_input runs. input.s stays the file
; that turns a stick into intent; this is the file that acts on this one.
; -----------------------------------------------------------------------------
shot_fire:
        lda     JOY1_PRESS
        and     #JOY_FIRE
        beq     @none
        ldx     #SHOT_N-1               ; the first free slot, if there is one
@find:  lda     SHTLIVE,x
        beq     @got
        dex
        bpl     @find
@none:  rts
@got:   stx     SHTI

        ; ---- where: the muzzle, SHOT_MUZZ world units along the heading ------
        ; Forward in the world is (sin H, -cos H) - see main.s's coordinate note
        ; - so the offset is one smul16q7 an axis. smul16q7 clobbers X, which is
        ; why the slot is parked in SHTI and re-read after every call.
        lda     #<SHOT_MUZZ
        sta     MAL
        lda     #>SHOT_MUZZ
        sta     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        ldx     SHTI
        lda     SHXF                    ; the ship's own fraction: the offset is
        sta     SHTXF,x                 ;   whole world units, so it adds nothing
        clc                             ;   below the point
        lda     SHXL
        adc     MAL
        sta     SHTXL,x
        lda     SHXH
        adc     MAH
        sta     SHTXH,x

        lda     #<SHOT_MUZZ
        sta     MAL
        lda     #>SHOT_MUZZ
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        ldx     SHTI
        lda     SHYF
        sta     SHTYF,x
        sec                             ; ...and MINUS the cosine term on y
        lda     SHYL
        sbc     MAL
        sta     SHTYL,x
        lda     SHYH
        sbc     MAH
        sta     SHTYH,x

        ; ---- how fast: the ship's velocity, plus SHOT_SPD along the heading --
        ; The ship's velocity is already the 16.8 this wants, and do_ship rebuilt
        ; it from the throttle this frame, so "the ship's speed at the moment of
        ; the shot" is literally the bytes at VELX/VELY.
        lda     #<SHOT_SPD
        sta     MAL
        lda     #>SHOT_SPD
        sta     MAH
        lda     SINV
        sta     MB
        jsr     smul16q7
        ldx     SHTI
        lda     VELXL                   ; the fraction is the ship's alone - the
        sta     SHTVXL,x                ;   muzzle term is a whole number of
        clc                             ;   world units per frame
        lda     VELXH
        adc     MAL
        sta     SHTVXH,x
        lda     VELXT
        adc     MAH
        sta     SHTVXT,x

        lda     #<SHOT_SPD
        sta     MAL
        lda     #>SHOT_SPD
        sta     MAH
        lda     COSV
        sta     MB
        jsr     smul16q7
        ldx     SHTI
        lda     VELYL
        sta     SHTVYL,x
        sec
        lda     VELYH
        sbc     MAL
        sta     SHTVYH,x
        lda     VELYT
        sbc     MAH
        sta     SHTVYT,x

        lda     HEAD                    ; the heading it will keep for its whole
        sta     SHTANG,x                ;   flight, whatever the ship does next
        lda     #$01
        sta     SHTLIVE,x
        rts

; -----------------------------------------------------------------------------
; shot_move — integrate every live bullet, put it on the screen, or free it.
; -----------------------------------------------------------------------------
; The integrate is a rock's, one byte wider: a 16.8 position and a 16.8 velocity
; make a three-byte add with no sign extension anywhere, because the velocity's
; top byte IS its sign extension. The wrap is free, as it is everywhere else -
; 16-bit overflow is the world's edge and there is nothing here that tests for
; one.
; -----------------------------------------------------------------------------
shot_move:
        lda     #SHOT_N-1
        sta     SHTI
@lp:    ldx     SHTI
        lda     SHTLIVE,x
        bne     :+
        jmp     @next                   ; (the body below is past a branch's

:                                       ;  reach, here and at @lp)
        clc                             ; position += velocity, 16.8 + 16.8
        lda     SHTXF,x
        adc     SHTVXL,x
        sta     SHTXF,x
        lda     SHTXL,x
        adc     SHTVXH,x
        sta     SHTXL,x
        lda     SHTXH,x
        adc     SHTVXT,x
        sta     SHTXH,x
        clc
        lda     SHTYF,x
        adc     SHTVYL,x
        sta     SHTYF,x
        lda     SHTYL,x
        adc     SHTVYH,x
        sta     SHTYL,x
        lda     SHTYH,x
        adc     SHTVYT,x
        sta     SHTYH,x

        sec                             ; world delta from the ship - wrap-correct
        lda     SHTXL,x                 ;   for free, a signed 16-bit subtract IS
        sbc     SHXL                    ;   the short way round the torus
        sta     PXL
        lda     SHTXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     SHTYL,x
        sbc     SHYL
        sta     PYL
        lda     SHTYH,x
        sbc     SHYH
        sta     PYH
        jsr     view_xform              ; the same two routines a rock's centre
        jsr     zoom_fb                 ;   goes through - see objects.s
        ldx     SHTI
        lda     FXL
        sta     SHTFXL,x
        lda     FXH
        sta     SHTFXH,x
        lda     FYL
        sta     SHTFYL,x
        lda     FYH
        sta     SHTFYH,x

        sec                             ; ...and the axis it lies along on the
        lda     SHTANG,x                ;   screen, which the hit test needs for
        sbc     HEAD                    ;   every rock it walks. Once a bullet,
        sta     T0                      ;   not once a pair: it is two OS trig
        jsr     API_SIN                 ;   calls and there are at most six
        ldx     SHTI
        sta     SHTS,x
        lda     T0
        jsr     API_COS
        ldx     SHTI
        sta     SHTC,x

        ; ---- off the screen? then the bullet is over --------------------------
        ; (fb + MARG) read UNSIGNED is below the span exactly when fb is inside
        ; [-MARG, limit+MARG): a negative fb wraps the sum into the high half,
        ; which the same compare rejects. The trick in_range uses, on a smaller
        ; window.
        clc
        lda     FXL
        adc     #<SHOT_MARG
        sta     T0
        lda     FXH
        adc     #>SHOT_MARG
        tay
        lda     T0
        cpy     #>(400 + 2*SHOT_MARG)
        bcc     @yaxis
        bne     @kill
        cmp     #<(400 + 2*SHOT_MARG)
        bcs     @kill
@yaxis:
        clc
        lda     FYL
        adc     #<SHOT_MARG
        sta     T0
        lda     FYH
        adc     #>SHOT_MARG
        tay
        lda     T0
        cpy     #>(300 + 2*SHOT_MARG)
        bcc     @next
        bne     @kill
        cmp     #<(300 + 2*SHOT_MARG)
        bcc     @next
@kill:  ldx     SHTI
        stz     SHTLIVE,x
@next:  dec     SHTI
        bmi     :+
        jmp     @lp
:       rts

; -----------------------------------------------------------------------------
; shot_hits — every visible rock, against every live bullet.
; -----------------------------------------------------------------------------
; ON THE SCREEN, not in the world, and the two are the same test here because a
; bullet only exists while it is on the screen. What that buys is the visible
; list: do_objects has already reduced a hundred and twenty rocks to the dozen
; on camera AND put a full-res screen point beside each one, so this pass costs
; nothing to set up. A rock the player cannot see cannot be shot, which is the
; rule anyway.
;
; The narrow phase is physics.s's, with the sign work removed. |d|^2 comes out
; of the quarter-square table - f(2a) = a*a exactly - so a hit test is three
; table reads, an add and a compare, and qmul is called once per ROCK for its
; screen radius rather than once per pair.
;
; BODY_R and not SHAPE_OCC: they are the same numbers (design_technical 5.4 has
; the collision circle and the star-suppression disc as one circle) but BODY_R
; is indexed by size class, which is what OBJSHP holds, and SHAPE_OCC by shape
; id, which would need CLASS_BASE first.
; -----------------------------------------------------------------------------
shot_hits:
        lda     #SHT_SWEEP              ; the sweep is a distance ON SCREEN, so it
        sta     MQA                     ;   shrinks with the zoom exactly as the
        lda     ZOOMH                   ;   bullet's own travel does
        sta     MQB
        jsr     qmul
        sta     SHTSWP

        ldx     #SHOT_N-1               ; nothing in flight - and most frames have
@any:   lda     SHTLIVE,x               ;   nothing in flight - is the whole pass
        bne     @go                     ;   skipped for five loads
        dex
        bpl     @any
        rts
@go:    lda     VISN
        bne     :+
        rts
:       stz     SHTVI
        bra     @rlp
@rskip: jmp     @rnext                  ; (the end of the rock loop is past a
                                        ;  branch's reach from the window test)
@rlp:   ldy     SHTVI

        ; ---- is this rock anywhere near the SCREEN? --------------------------
        ; The visible list is the COARSE cull's survivors, a band 400 px wider
        ; than the screen in every direction, and about two thirds of it is
        ; nowhere the player can see. A bullet only exists on the screen, so
        ; those two thirds cannot be hit by anything - and throwing them out
        ; here, for two 16-bit window tests, is what stops each of them costing
        ; a qmul and a six-bullet inner loop. Measured over the harness's
        ; 200-frame flight with the gun firing throughout: CPU1's worst frame is
        ; 78.0% of budget without this test and 74.1% with it, against 69.2% for
        ; the same flight with no gun at all.
        ;
        ; It is the same (v + M) read UNSIGNED trick the shot's own screen cull
        ; and in_range both use. M is the largest screen radius any rock can
        ; have - class 192 at 1:1, 39 half-res doubled - so no rock that could
        ; be touching a bullet is ever thrown out.
        clc
        lda     VSXL,y
        adc     #<HIT_M
        sta     T0
        lda     VSXH,y
        adc     #>HIT_M
        tax
        cpx     #>(400 + 2*HIT_M)
        bcc     @xok
        bne     @rskip
        lda     T0
        cmp     #<(400 + 2*HIT_M)
        bcs     @rskip
@xok:   clc
        lda     VSYL,y
        adc     #<HIT_M
        sta     T0
        lda     VSYH,y
        adc     #>HIT_M
        tax
        cpx     #>(300 + 2*HIT_M)
        bcc     @yok
        bne     @rskip
        lda     T0
        cmp     #<(300 + 2*HIT_M)
        bcs     @rskip
@yok:
        lda     VISIDX,y
        sta     SHTOBJ
        tax
        ldy     OBJSHP,x
        lda     BODY_R,y                ; the rock's collision circle, half-res...
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul                    ; ...shrunk by the zoom...
        asl     a                       ; ...and doubled into the FULL-res units
        sta     SHTR                    ;   the screen points are in. 39*2 = 78
                                        ;   at 1:1, so 2*R stays a byte index
        clc                             ; the reject is widened by the sweep, so
        adc     SHTSWP                  ;   a rock the bullet jumped OVER this
        sta     SHTRW                   ;   frame still reaches the test below.
                                        ;   78 + 36 = 114, still a byte, and
                                        ;   |dx| + |cos| still inside the
                                        ;   quarter-square index
        lda     SHTR                    ; R * 128 and SWEEP * 128: the swept test
        lsr     a                       ;   compares RAW quarter-square products,
        sta     SHTR129                 ;   which are 128x the pixel value, so its
        lda     #$00                    ;   bounds have to be too - and then
        ror     a                       ;   nothing is ever shifted back down
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
@bskip: jmp     @bnext                  ; (the end of the loop is past a branch's
:                                       ;  reach from the test below, so every
                                        ;  reject goes through here)
        sec                             ; d = rock - bullet, full-res screen px
        ldy     SHTVI
        lda     VSXL,y
        sbc     SHTFXL,x
        sta     T0
        lda     VSXH,y
        sbc     SHTFXH,x
        sta     T1
        jsr     shot_dnarrow
        bcs     @bskip
        sta     SHTADX
        lda     T0                      ; ...and the SIGNED byte too: the swept
        sta     SHTDX                   ;   test below needs a direction, not
        ldx     SHTJ                    ;   just a distance
        sec
        ldy     SHTVI
        lda     VSYL,y
        sbc     SHTFYL,x
        sta     T0
        lda     VSYH,y
        sbc     SHTFYH,x
        sta     T1
        jsr     shot_dnarrow
        bcs     @bskip
        sta     SHTADY
        lda     T0
        sta     SHTDY

        lda     SHTADX                  ; |d|^2 = QS[2|dx|] + QS[2|dy|], exactly
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
        lda     SHTR                    ; ...against QS[2R], which is R*R
        asl     a
        tax
        lda     T0
        cmp     QSL,x
        lda     T1
        sbc     QSH,x
        bcc     @hit                    ; inside the circle round the TIP
        jsr     shot_swept              ; ...or anywhere along the path it swept
        bcc     @hit                    ;   getting here
        jmp     @bnext

@hit:   ldx     SHTJ                    ; A HIT.
        jsr     expl_spawn              ; the puff goes on the bullet's own tip,
        jsr     rock_spin               ;   which is where the anchor is; and the
                                        ;   rock takes the twist for it
        ldx     SHTJ
        stz     SHTLIVE,x               ; ...and the bullet is spent, whatever it
                                        ;   did to the rock
        ldx     SHTOBJ
        jsr     rock_take_hit           ; dec HP; destroy, or the crack shake
        bcs     @rnext                  ;   if this landed it on 1 - see the
                                        ;   routine. Destroyed: this slot is
                                        ;   not the rock the inner loop was
                                        ;   testing against any more, so the
                                        ;   bullets move on.
@bnext: dec     SHTJ
        bmi     @rnext
        jmp     @blp
@rnext: inc     SHTVI
        lda     SHTVI
        cmp     VISN
        beq     @done
        jmp     @rlp
@done:  rts

; -----------------------------------------------------------------------------
; shot_dnarrow — T0/T1, a signed 16, to |T0| in A. Carry SET = it is not a hit.
; -----------------------------------------------------------------------------
; The box reject and the byte narrowing in one: a delta that does not sign-
; extend from its own low byte is at least 128 px away and cannot be touching
; anything, and one that does still has to be inside SHTRW - the rock's radius
; PLUS the bullet's sweep, because a rock the bullet jumped clean over is still
; a rock it hit. What comes back is a magnitude of at most 114, so 2*|d| is a
; legal quarter-square index by construction and the caller never has to check
; it.
; -----------------------------------------------------------------------------
shot_dnarrow:
        lda     T0
        bmi     @neg
        lda     T1                      ; positive: the high byte must be 0
        bne     @out
        lda     T0
        bra     @test
@neg:   ldy     T1                      ; negative: it must be $FF
        iny
        bne     @out
        sec
        lda     #$00
        sbc     T0
@test:  cmp     SHTRW                   ; ...and inside the rock's radius WIDENED
        beq     @in                     ;   by the bullet's sweep. The equal case
        bcs     @out                    ;   is in, which is what makes an R of 0
@in:    clc                             ;   impossible to hit rather than always
        rts                             ;   hit
@out:   sec
        rts

; -----------------------------------------------------------------------------
; shot_swept — did the bullet PASS THROUGH the rock on its way here?
; -----------------------------------------------------------------------------
; Carry CLEAR = yes. SHTDX/SHTDY are the rock's centre from the bullet's tip.
;
; TUNNELLING, and it was found by playing rather than by reasoning. A bullet
; moves 12 screen pixels a frame plus whatever the ship was doing - up to 24
; with the boost - and the smallest rock is 12 pixels ACROSS. So the tip could
; be short of it on one frame and past it on the next, and a shot that visibly
; went through a speck did nothing at all.
;
; The fix is to stop testing a POINT and start testing the SEGMENT the bullet
; swept. In the bullet's own frame that is two numbers:
;
;     along = d . (cos, sin)      how far back down the path the rock is
;     perp  = d x (cos, sin)      and how far off it
;
; - the bullet's screen forward is (-cos, -sin), so BACKWARD, which is where it
; has been, is (cos, sin). A hit is `0 <= along <= sweep` and `|perp| <= R`. The
; round end at the tip is the caller's circle test, which has already run; this
; is the rectangle behind it, and the far end being square is invisible because
; it is behind the bullet.
;
; NOTHING IS SHIFTED. The quarter-square products come out 128x the pixel value
; (sp_prod), so the bounds are held 128x as well and the comparison is made
; there. The one place it matters is `along`, where the two products are ADDED
; and the +64 each carries adds up instead of cancelling - so 128 comes off the
; sum. In `perp` they are subtracted and cancel by themselves.
;
; The lever arm rock_spin wants is this same `perp`, and it does not have to be
; recomputed at the contact point: the perpendicular distance to a LINE is the
; same measured from anywhere on it, so rock_spin measuring from the tip is
; already right for a swept hit.
; -----------------------------------------------------------------------------
shot_swept:
        ldx     SHTJ
        lda     SHTC,x
        sta     SPC
        lda     SHTS,x
        sta     SPS

        lda     SHTDX                   ; along = dx*cos ...
        jsr     sp_abs
        sta     MQA
        lda     SPC
        jsr     sp_abs
        sta     MQB
        jsr     sp_prod
        lda     SHTDX
        eor     SPC
        bpl     :+
        jsr     sp_negt
:       lda     SPT0
        sta     SPP
        lda     SPT1
        sta     SPP1
        lda     SHTDY                   ; ... + dy*sin
        jsr     sp_abs
        sta     MQA
        lda     SPS
        jsr     sp_abs
        sta     MQB
        jsr     sp_prod
        lda     SHTDY
        eor     SPS
        bpl     :+
        jsr     sp_negt
:       clc
        lda     SPP
        adc     SPT0
        sta     SHTALO
        lda     SPP1
        adc     SPT1
        sta     SHTALO1
        sec                             ; ...less the rounding term both products
        lda     SHTALO                  ;   carry, which cancels in a subtraction
        sbc     #128                    ;   but doubles in this one
        sta     SHTALO
        lda     SHTALO1
        sbc     #$00
        sta     SHTALO1

        bmi     @nope                   ; ahead of the tip: the circle had it
        cmp     SHTL129                 ; ...or past the far end of the sweep
        bcc     @perp
        bne     @nope
        lda     SHTALO
        cmp     SHTL128
        bcc     @perp
@nope:  sec                             ; (the far end of the routine is out of
        rts                             ;  a branch's reach from here)

@perp:  lda     SHTDX                   ; perp = dx*sin - dy*cos
        jsr     sp_abs
        sta     MQA
        lda     SPS
        jsr     sp_abs
        sta     MQB
        jsr     sp_prod
        lda     SHTDX
        eor     SPS
        bpl     :+
        jsr     sp_negt
:       lda     SPT0
        sta     SPP
        lda     SPT1
        sta     SPP1
        lda     SHTDY
        jsr     sp_abs
        sta     MQA
        lda     SPC
        jsr     sp_abs
        sta     MQB
        jsr     sp_prod
        lda     SHTDY
        eor     SPC
        bpl     :+
        jsr     sp_negt
:       sec
        lda     SPP
        sbc     SPT0
        sta     SHTPRP
        lda     SPP1
        sbc     SPT1
        sta     SHTPRP1

        bpl     @mag                    ; |perp| <= R?
        sec
        lda     #$00
        sbc     SHTPRP
        sta     SHTPRP
        lda     #$00
        sbc     SHTPRP1
@mag:   cmp     SHTR129
        bcc     @hit
        bne     @miss
        lda     SHTPRP
        cmp     SHTR128
        bcs     @miss
@hit:   clc
        rts
@miss:  sec
        rts

; -----------------------------------------------------------------------------
; rock_spin - the twist. SHTOBJ is the rock, SHTJ the bullet, SHTVI its entry.
; -----------------------------------------------------------------------------
; Runs ONLY on a hit, which is why it is allowed two OS trig calls and two
; 16-bit multiplies: a busy second has a dozen of these in it, against sixty
; frames of everything else. See the note at the top of the file for what it
; computes and why.
; -----------------------------------------------------------------------------
rock_spin:
        ldy     SHTVI                   ; d = rock centre - hit point. Only the
        ldx     SHTJ                    ;   LOW bytes: the hit test has already
        sec                             ;   proved |d| is inside the rock's
        lda     VSXL,y                  ;   screen radius, which is 78 px at the
        sbc     SHTFXL,x                ;   very largest, so each one is its own
        sta     SPDX                    ;   signed byte
        sec
        lda     VSYL,y
        sbc     SHTFYL,x
        sta     SPDY

        sec                             ; the bullet's SCREEN heading - the same
        lda     SHTANG,x                ;   byte shot_draw hands the GPU as
        sbc     HEAD                    ;   ANGLE, so the two can never disagree
        sta     SPANG
        jsr     API_SIN
        sta     SPS
        lda     SPANG
        jsr     API_COS
        sta     SPC

        lda     SPDX                    ; p = dx * sin, magnitudes through the
        jsr     sp_abs                  ;   quarter-square and the sign put back
        sta     MQA                     ;   by comparing - the house pattern
        lda     SPS                     ;   (math.s) - but RAW, see sp_prod
        jsr     sp_abs
        sta     MQB
        jsr     sp_prod
        lda     SPDX
        eor     SPS
        bpl     :+
        jsr     sp_negt
:       lda     SPT0
        sta     SPP
        lda     SPT1
        sta     SPP1

        lda     SPDY                    ; q = dy * cos
        jsr     sp_abs
        sta     MQA
        lda     SPC
        jsr     sp_abs
        sta     MQB
        jsr     sp_prod
        lda     SPDY
        eor     SPC
        bpl     :+
        jsr     sp_negt
:
        sec                             ; arm = p - q, and it is EXACT: each raw
        lda     SPP                     ;   product carries the same +64 and they
        sbc     SPT0                    ;   cancel here
        sta     MAL
        lda     SPP1
        sbc     SPT1
        sta     MAH

        clc                             ; ...and only NOW is it rounded to a whole
        lda     MAL                     ;   screen pixel, once. Rounding the two
        adc     #64                     ;   products first and subtracting after
        sta     MAL                     ;   costs a whole pixel of arm, which on
        lda     MAH                     ;   the smallest rock's six-pixel rim is
        adc     #$00                    ;   17% of the answer and can flip its
        sta     MAH                     ;   sign outright near the centre.
        ldx     #7
:       lda     MAH
        cmp     #$80
        ror     MAH
        ror     MAL
        dex
        bne     :-

        ldx     ZOOMH                   ; ...divided by the zoom, so the same hit
        lda     TPQ-64,x                ;   is the same twist however far back
        beq     @scaled                 ;   the camera is. 1:1 needs no work
        sta     MB
        lda     MAL
        sta     SPT0
        lda     MAH
        sta     SPT1
        jsr     smul16q7                ; arm * (128/RZ - 1)...
        clc
        lda     MAL
        adc     SPT0                    ; ...+ arm, which is the 128 part
        sta     MAL
        lda     MAH
        adc     SPT1
        sta     MAH
@scaled:
        lda     MAL                     ; the arm is the MULTIPLIER now, and it
        sta     MB                      ;   is a signed byte: it cannot exceed
        ldx     SHTOBJ                  ;   the rock's own un-zoomed radius, 78
        ldy     OBJSHP,x
        tya
        asl     a
        tay
        lda     SPIN_G,y                ; ...against the class's gain, which is
        sta     MAL                     ;   where the MASS is
        lda     SPIN_G+1,y
        sta     MAH
        jsr     smul16q7                ; MA = the change, signed 8.8 brad/frame

        ldx     SHTOBJ                  ; ...onto the rock's own rate
        clc
        lda     OBJSPNL,x
        adc     MAL
        sta     SPT0
        lda     OBJSPNH,x
        adc     MAH
        sta     SPT1

        lda     SPT1                    ; ...clamped, both ways
        bmi     @neg
        cmp     #>SPIN_MAX
        bcc     @store
        bne     @hi
        lda     SPT0
        cmp     #<SPIN_MAX
        bcc     @store
@hi:    lda     #<SPIN_MAX
        sta     SPT0
        lda     #>SPIN_MAX
        sta     SPT1
        bra     @store
@neg:   sec                             ; negative: clamp the MAGNITUDE, so the
        lda     #$00                    ;   ceiling is symmetric
        sbc     SPT0
        tay
        lda     #$00
        sbc     SPT1
        cmp     #>SPIN_MAX
        bcc     @store
        bne     @lo
        cpy     #<SPIN_MAX
        bcc     @store
@lo:    sec
        lda     #$00
        sbc     #<SPIN_MAX
        sta     SPT0
        lda     #$00
        sbc     #>SPIN_MAX
        sta     SPT1
@store: ldx     SHTOBJ
        lda     SPT0
        sta     OBJSPNL,x
        lda     SPT1
        sta     OBJSPNH,x
        rts

; A -> |A|, for the two magnitudes the quarter-square wants. The sign is put
; back by the caller, out of an EOR of the two operands - four cycles against
; carrying it through.
sp_abs:
        bpl     :+
        eor     #$FF
        inc     a
:       rts

; MQA * MQB + 64 -> SPT0/SPT1, both magnitudes 0..127. qmul without its last
; two instructions: the >>7 is what throws the low bits away, and here there are
; two of these products going into a SUBTRACTION, so the shift has to wait until
; after it. The +64 the QR table carries is left in on purpose - both products
; carry the same one and it cancels in the subtract, leaving the difference
; exact and one rounding to do at the end instead of two before it.
sp_prod:
        clc
        lda     MQA
        adc     MQB
        tax
        sec
        lda     MQA
        sbc     MQB
        bcs     :+
        eor     #$FF
        adc     #$01
:       tay
        sec
        lda     QRL,x
        sbc     QSL,y
        sta     SPT0
        lda     QRH,x
        sbc     QSH,y
        sta     SPT1
        rts

; ...and negate it, for when the two operands had opposite signs.
sp_negt:
        sec
        lda     #$00
        sbc     SPT0
        sta     SPT0
        lda     #$00
        sbc     SPT1
        sta     SPT1
        rts

; -----------------------------------------------------------------------------
; expl_spawn - X = the bullet that just landed. Start a puff where its tip is.
; -----------------------------------------------------------------------------
; No free slot means no puff, silently: six can be going at once and a seventh
; hit inside a tenth of a second is not a case worth a queue for.
; -----------------------------------------------------------------------------
expl_spawn:
        lda     SHTXL,x                 ; the hit point IS the bullet's anchor -
        sta     EXTXL                   ;   the tip, not the middle of the line
        lda     SHTXH,x
        sta     EXTXH
        lda     SHTYL,x
        sta     EXTYL
        lda     SHTYH,x
        sta     EXTYH
        ; fall through

; ...and the same thing from a world point rather than a bullet: rock_split puts
; one exactly between the two halves it has just made.
expl_at:
        ldy     #EXPL_N-1
@find:  lda     EXLIVE,y
        beq     @got
        dey
        bpl     @find
        rts
@got:   lda     EXTXL
        sta     EXXL,y
        lda     EXTXH
        sta     EXXH,y
        lda     EXTYL
        sta     EXYL,y
        lda     EXTYH
        sta     EXYH,y
        lda     EXSEQ                   ; the four clouds in turn, so consecutive
        inc     EXSEQ                   ;   hits do not stamp out the same shape
        and     #EXPL_SETS-1
        sta     EXDX
        lda     ZOOMH                   ; ...and the SIZE, once and for the whole
        cmp     #EXPL_ZBIG              ;   life of this puff, so it grows with
        lda     #EXPL_SETS              ;   the world instead of staying a fixed
        bcs     :+                      ;   number of screen pixels. The snapped
        lda     #$00                    ;   rung and not the eased value: a puff
:       clc                             ;   is born on one frame and this is
        adc     EXDX                    ;   read once, so there is nothing for a
        sta     EXSET,y                 ;   smooth value to make smoother
        lda     #$00
        sta     EXAGE,y
        lda     #$01
        sta     EXLIVE,y
        rts

; -----------------------------------------------------------------------------
; do_explosions - age every live puff and put its pixels in ONE DOT_PIXELS.
; -----------------------------------------------------------------------------
; All of them share EXPLBUF and go out as a single command, the way the stars
; and the motes do: DOT_PIXELS costs two bytes a pixel and one dispatch for the
; lot, where a command per puff would be six dispatches for the same pixels.
; -----------------------------------------------------------------------------
do_explosions:
        stz     EXN
        stz     EXDI
        lda     #EXPL_N-1
        sta     EXI
@lp:    ldx     EXI
        lda     EXLIVE,x
        beq     @next
        jsr     expl_one
@next:  dec     EXI
        bpl     @lp
        lda     EXN
        beq     @none
        sta     EXPLBUF
        lda     #<EXPLBUF
        sta     OS_ARG+0
        lda     #>EXPLBUF
        sta     OS_ARG+1
        jmp     API_GPU_DOTPIXELS
@none:  rts

; -----------------------------------------------------------------------------
; expl_one - one puff: place its pixels, then age it.
; -----------------------------------------------------------------------------
expl_one:
        sec                             ; the anchor, world -> screen, by exactly
        lda     EXXL,x                  ;   the road a bullet and a rock take
        sbc     SHXL
        sta     PXL
        lda     EXXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     EXYL,x
        sbc     SHYL
        sta     PYL
        lda     EXYH,x
        sbc     SHYH
        sta     PYH
        jsr     view_xform
        jsr     zoom_fb
        lda     FXH                     ; DOT_PIXELS is HALF-res, so the full-res
        cmp     #$80                    ;   point it left is halved - arithmetic,
        ror     a                       ;   cmp #$80 putting the sign into carry
        sta     EXCXH
        lda     FXL
        ror     a
        sta     EXCXL
        lda     FYH
        cmp     #$80
        ror     a
        sta     EXCYH
        lda     FYL
        ror     a
        sta     EXCYL

        ; ---- the block for this cloud, this size and this frame of it --------
        ; EXPL_OFF is EXPL_SIZES x EXPL_SETS x EXPL_AGES blocks of 16 bytes, so
        ; this block starts (group*EXPL_AGES + age)*16 from the base - up to
        ; 3,056, which is why it is reached through a pointer and not an index.
        ; The block NUMBER still fits a byte (191 at the most), which is what
        ; lets the shift below start from a single one.
        ;
        ; THE ZOOM IS IN HERE and costs nothing: EXSET is already the group,
        ; size and cloud combined at spawn, so scaling the puff added no
        ; instruction to this at all. See the scaling note at the top.
        ldx     EXI
        ldy     EXSET,x
        lda     EXPL_BASE,y             ; group * EXPL_AGES, out of a table - the
        clc                             ;   CLASS_BASE trick from shapes.s, so
        adc     EXAGE,x                 ;   this needs no multiply either
        stz     EXDY
        asl     a
        rol     EXDY
        asl     a
        rol     EXDY
        asl     a
        rol     EXDY
        asl     a
        rol     EXDY                    ; ...* 16, 16-bit
        clc
        adc     #<EXPL_OFF
        sta     EXPTR
        lda     EXDY
        adc     #>EXPL_OFF
        sta     EXPTR+1

        ldy     EXAGE,x                 ; the cloud THINS as it goes - fewer
        lda     EXPL_DOTS,y             ;   pixels every frame near the end, which
        asl     a                       ;   is what reads as fading out. The
        sta     EXSTOP                  ;   offsets are ordered so that any prefix
                                        ;   of them is still spread round the ring

        ldy     #$00
@dot:   lda     (EXPTR),y
        sta     EXDX
        iny
        lda     (EXPTR),y
        sta     EXDY
        iny
        sty     EXY                     ; the cursor is safe over the clip below

        lda     EXDX                    ; sx = centre + dx, sign-extended, 16-bit
        ldx     #$00                    ;   - the centre may be off screen, and a
        cmp     #$80                    ;   byte add would wrap it back on
        bcc     :+
        dex
:       clc
        adc     EXCXL
        sta     EXPX
        txa
        adc     EXCXH
        bne     @dnext                  ; not in 0..255, so not on the screen
        lda     EXPX
        cmp     #200
        bcs     @dnext

        lda     EXDY
        ldx     #$00
        cmp     #$80
        bcc     :+
        dex
:       clc
        adc     EXCYL
        sta     EXPY
        txa
        adc     EXCYH
        bne     @dnext
        lda     EXPY
        cmp     #150
        bcs     @dnext

        ldx     EXDI                    ; it is on screen: into the payload
        lda     EXPX
        sta     EXPLBUF+1,x
        lda     EXPY
        sta     EXPLBUF+2,x
        inx
        inx
        stx     EXDI
        inc     EXN
@dnext: ldy     EXY
        cpy     EXSTOP
        bne     @dot

        ldx     EXI                     ; ...and one frame older
        inc     EXAGE,x
        lda     EXAGE,x
        cmp     #EXPL_AGES
        bcc     :+
        stz     EXLIVE,x
:       rts

; -----------------------------------------------------------------------------
; shots_init - called once from cart_init. Every slot free.
; -----------------------------------------------------------------------------
; RAM is not cleared for us: the boot ROM does not zero the cartridge's pages,
; so without this a slot whose byte happened to come up nonzero would draw a
; bullet from nowhere on the first frame - and, worse, integrate a world
; position out of whatever else was left in those bytes.
; -----------------------------------------------------------------------------
shots_init:
        lda     #$00
        ldx     #SHOT_N-1
:       sta     SHTLIVE,x
        dex
        bpl     :-
        ldx     #EXPL_N-1
:       sta     EXLIVE,x
        dex
        bpl     :-
        stz     EXSEQ
        rts

; -----------------------------------------------------------------------------
; rock_kill — X = the object. It is out of hit points; take it out of the game.
; -----------------------------------------------------------------------------
; Three lines, and each one closes a different door:
;
;   the SECTOR GRID is the only way the frame reaches an object - do_objects,
;   do_collide and cell_flush all walk cell lists and nothing else walks by
;   slot - so unlinking it is the whole of "it stops existing". Its arrays are
;   left exactly as they were; nothing will ever read them again.
;
;   the RADAR'S CENSUS is the one thing that has to be TOLD. RKLIVE is the
;   population per size class, counted once at load, and radar_sens tunes the
;   instrument to the largest class that still has a rock in it - so this is
;   what makes the radar step down to the small stuff as the field is cleared.
;   radar.s has always said "the moment anything starts destroying rocks it
;   decrements that"; this is that moment.
;
;   the RADAR'S SCAN is flat, by slot, not through the grid (see do_radar's note
;   on why), so a dead rock would keep showing as a contact. Stamping OBJSHP
;   with SHP_DEAD is what stops it, and it costs nothing: the class window
;   do_radar already applies rejects $FF on the compare it was making anyway.
;
; This is safe to do IMMEDIATELY - no deferral like cell_flush's - because
; do_objects' walk finished before do_shots ran, and cell_flush emptied PEND on
; its way out. Nothing is standing on a cell list at this point in the frame.
;
; The rock is still in THIS frame's visible list, and that is fine: emit_asteroids
; ran before do_shots, so it has already been drawn one last time, and nothing
; reads the list again afterwards.
; -----------------------------------------------------------------------------
rock_kill:
        stx     GOBJ
        jsr     cell_unlink             ; (objects.s - X and GOBJ are the object)
        ldx     GOBJ
        ldy     OBJSHP,x                ; its class, before the stamp overwrites
        lda     #SHP_DEAD               ;   it
        sta     OBJSHP,x
        tya
        tax                             ; dec has no abs,y - only abs,x
        lda     RKLIVE,x
        beq     :+                      ; (cannot happen; a census that has run
        dec     RKLIVE,x                ;  short must not wrap to 255 anyway)
:       rts

; =============================================================================
; The split
; =============================================================================
; A rock out of hit points becomes TWO of the next size class down, thrown apart
; PERPENDICULAR to the shot that killed it, with a little of the shot's own
; momentum added to both so the pair visibly recoils away from the player. That
; is physics.md section 6, built; the four parameters it lists as (TBM) are the
; tables at the bottom of this file.
;
;   child.pos  = parent.pos  +/- SPLIT_OFF * perp
;   child.vel  = parent.vel  +/- SPLIT_V   * perp  +  SHOT_PUSH * along
;   child.spin = parent.spin +/- SPLIT_SPIN
;
; The two children take OPPOSITE signs on the separation, so linear momentum is
; conserved by construction and a field taken apart over a long game does not
; acquire a drift - the same discipline physics.s's impulse keeps. The push is
; the one term that is added to both, and it is the one term that is meant to
; move the total: it comes from the bullet.
;
; THE PARENT'S SLOT IS ONE OF THE CHILDREN. That is not a saving, it is the
; difference between needing one free slot per split and needing two, and the
; whole question of whether the array can survive a level being taken apart
; turns on it - see main.s's note on NOBJ. The parent is unlinked from the
; sector grid first, because both children are somewhere it was not.
;
; THE SMALLEST CLASS DOES NOT SPLIT (physics.md 5). It is destroyed, and its
; slot goes back on the free stack - which is what feeds every other split.
; =============================================================================
SPLIT_LAST  = 4                 ; the class that does not break up: there is
                                ;   nothing smaller for it to become
SPLIT_SPIN  = $00C0             ; the spin kick, 8.8 brad/frame, one child up and
                                ;   the other down. Also opposite by construction
SPLIT_VMAX  = $4000             ; the per-axis speed cap, signed 8.8 world units
                                ;   a frame - 64, where the fastest authored
                                ;   drift is 13 and the arithmetic wraps at 128.
                                ;   physics.md 7 asks for exactly this and says
                                ;   why it was not needed until now: the split is
                                ;   the first thing in the game that ADDS
                                ;   momentum, so it is the first thing that can
                                ;   make a speed grow without bound
RECYC_FAR   = 96                ; how far from the ship a speck has to be before
                                ;   the sweep drops it, in position HIGH bytes -
                                ;   24,576 world units, which is 1,536 reference
                                ;   pixels. The furthest corner of the screen is
                                ;   about 250 pixels from the ship even with the
                                ;   camera all the way back, so this is six times
                                ;   the distance at which it could still be seen.
                                ;   It is also well outside the widest cull
                                ;   window (CULL_HI tops out at 68), so a swept
                                ;   rock is never one the frame was looking at
RECYC_STEP  = 32                ; slots the sweep examines per frame, so the whole
                                ;   255-slot field comes round every 8 frames -
                                ;   an eighth of a second, in which the fastest
                                ;   speck moves 7 pixels. "As soon as it is far
                                ;   enough away" does not need to mean "in the
                                ;   same frame", and a flat scan of the whole
                                ;   field every frame would cost 3,000 cycles to
                                ;   find nothing 999 times out of 1,000
SWEEPN      = $73A2             ; ...the sweep's own countdown

; --- state, in free game RAM -------------------------------------------------
SPL_P       = $7380             ; the parent's slot, which becomes child A
SPL_S       = $7381             ; ...and the one the free stack gave us for B
SPL_C       = $7382             ; the child class
SPL_XL      = $7383             ; everything about the parent, read out before
SPL_XH      = $7384             ;   either child overwrites it
SPL_XF      = $7385
SPL_YL      = $7386
SPL_YH      = $7387
SPL_YF      = $7388
SPL_VXL     = $7389
SPL_VXH     = $738A
SPL_VYL     = $738B
SPL_VYH     = $738C
SPL_SPL     = $738D
SPL_SPH     = $738E
SPL_ANG     = $738F
SPL_SIN     = $7390             ; the SHOT's WORLD heading, not its screen one:
SPL_COS     = $7391             ;   these move world velocities
SPL_OXL     = $7392             ; the separation OFFSET, world units, signed 16
SPL_OXH     = $7393
SPL_OYL     = $7394
SPL_OYH     = $7395
SPL_DVXL    = $7396             ; ...the separation VELOCITY, 8.8
SPL_DVXH    = $7397
SPL_DVYL    = $7398
SPL_DVYH    = $7399
SPL_PXL     = $739A             ; ...and the push along the shot, added to both
SPL_PXH     = $739B
SPL_PYL     = $739C
SPL_PYH     = $739D
SPL_I       = $739E             ; which child is being built, 0 = +, 1 = -
SPL_T       = $739F             ; ...and its slot
RECYCI      = $73A0             ; rock_recycle's rotating cursor over the field
NBLOCK      = $73A1             ; splits refused for want of a slot. It should be
                                ;   zero forever; it is here so that "should be"
                                ;   is a number somebody can look at

; -----------------------------------------------------------------------------
; rock_destroy — X = the rock whose last hit point has just gone.
; -----------------------------------------------------------------------------
; Three outcomes, and the third one is the interesting one:
;
;   the smallest class      destroyed, slot back on the free stack
;   anything else           split in two, taking one slot off the stack
;   ...and nothing there    rock_recycle finds a slot; if it cannot, THE HIT
;                           DOES NOT LAND. The rock keeps its last hit point and
;                           the player has to clear a speck somewhere before
;                           this one will come apart.
;
; That last case is the only place in the game where a shot can fail to do what
; it looks like it did, and it is deliberate: the alternative is destroying a
; rock and quietly losing half of what it should have become, which is worse and
; invisible. It needs the field to be at 255 rocks AND to have nothing small and
; far away left to recycle, which takes some doing.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; rock_take_hit - X = the rock. Spend one hit point, exactly the same way
; regardless of what caused it - a bullet (shot_hits, above) or a ship
; collision (physics.s ship_respond) both just want "this rock took a hit".
; Out: carry SET if that was its last point (rock_destroy has already run -
; the slot may be gone); carry CLEAR if it is still standing, having fired
; the crack shake if this was the hit that landed it on 1.
; -----------------------------------------------------------------------------
rock_take_hit:
        dec     OBJHP,x
        bne     @alive
        jsr     rock_destroy
        sec
        rts
@alive: lda     OBJHP,x                 ; CRACK: just reached its last hit point
        cmp     #1                      ;   by damage - the same "1" one_asteroid's
        bne     @done                   ;   ACRACK tests. A class that SPAWNS at 1
        lda     #SHK_SHIFT_CRACK        ;   (16px) can never land here: its only
        jsr     shake_arm               ;   hit takes it straight to 0, above.
@done:  clc
        rts

rock_destroy:
        stx     SPL_P
        lda     OBJSHP,x
        cmp     #SPLIT_LAST
        bcs     @gone
        jsr     rock_alloc              ; room for the second fragment?
        bcc     @got
        jsr     rock_recycle            ; no - so make some
        bcs     @blocked
        jsr     rock_alloc
        bcs     @blocked
@got:   sta     SPL_S
        jmp     rock_split
@gone:  ldx     SPL_P                   ; the smallest class just goes, and its
        jsr     rock_kill               ;   slot is what every other split is
        lda     SPL_P                   ;   drawing on
        jmp     rock_free
@blocked:
        inc     NBLOCK
        ldx     SPL_P                   ; nothing to break into: the hit lands,
        inc     OBJHP,x                 ;   the rock survives it
        rts

; -----------------------------------------------------------------------------
; rock_split — SPL_P is the parent and SPL_S the slot for its second half.
; -----------------------------------------------------------------------------
rock_split:
        lda     #SHK_SHIFT_BREAK        ; shake now, since a real break is
        jsr     shake_arm               ;   committed (a blocked hit never
                                        ;   reaches rock_split; rock_destroy's
                                        ;   @gone routes SPLIT_LAST straight
                                        ;   to rock_kill, never here - so
                                        ;   every rock that lands in THIS
                                        ;   routine gets the same shake)
        ldx     SPL_P                   ; out of the grid first: both children
        stx     GOBJ                    ;   are somewhere the parent was not
        jsr     cell_unlink

        ldx     SPL_P                   ; ...then everything about it, before
        lda     OBJXL,x                 ;   child A writes over the slot
        sta     SPL_XL
        lda     OBJXH,x
        sta     SPL_XH
        lda     OBJXF,x
        sta     SPL_XF
        lda     OBJYL,x
        sta     SPL_YL
        lda     OBJYH,x
        sta     SPL_YH
        lda     OBJYF,x
        sta     SPL_YF
        lda     OBJVXL,x
        sta     SPL_VXL
        lda     OBJVXH,x
        sta     SPL_VXH
        lda     OBJVYL,x
        sta     SPL_VYL
        lda     OBJVYH,x
        sta     SPL_VYH
        lda     OBJSPNL,x
        sta     SPL_SPL
        lda     OBJSPNH,x
        sta     SPL_SPH
        lda     OBJANG,x
        sta     SPL_ANG

        lda     OBJSHP,x                ; the census: one of the parent's class
        tax                             ;   goes, two of the next one down arrive
        dec     RKLIVE,x
        inx
        stx     SPL_C
        lda     RKLIVE,x
        clc
        adc     #$02
        sta     RKLIVE,x

        ldx     SHTJ                    ; the SHOT'S WORLD heading. rock_spin
        lda     SHTANG,x                ;   wanted the screen one because it was
        sta     SPL_T                   ;   measuring a screen lever arm; this is
        jsr     API_SIN                 ;   moving world velocities, so it is the
        sta     SPL_SIN                 ;   raw heading and no camera in it
        lda     SPL_T
        jsr     API_COS
        sta     SPL_COS

        ; ---- the three vectors ----------------------------------------------
        ; Forward along the shot is (sin, -cos) - main.s's coordinate note - so
        ; PERPENDICULAR to it is (cos, sin), and that is the axis the two halves
        ; are thrown along.
        ldx     SPL_C
        jsr     spl_tblx
        lda     SPLIT_OFF,x
        sta     MAL
        lda     SPLIT_OFF+1,x
        sta     MAH
        lda     SPL_COS
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     SPL_OXL
        lda     MAH
        sta     SPL_OXH

        ldx     SPL_C
        jsr     spl_tblx
        lda     SPLIT_OFF,x
        sta     MAL
        lda     SPLIT_OFF+1,x
        sta     MAH
        lda     SPL_SIN
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     SPL_OYL
        lda     MAH
        sta     SPL_OYH

        ldx     SPL_C
        jsr     spl_tblx
        lda     SPLIT_V,x
        sta     MAL
        lda     SPLIT_V+1,x
        sta     MAH
        lda     SPL_COS
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     SPL_DVXL
        lda     MAH
        sta     SPL_DVXH

        ldx     SPL_C
        jsr     spl_tblx
        lda     SPLIT_V,x
        sta     MAL
        lda     SPLIT_V+1,x
        sta     MAH
        lda     SPL_SIN
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     SPL_DVYL
        lda     MAH
        sta     SPL_DVYH

        ldx     SPL_C                   ; ...and the push, ALONG the shot
        jsr     spl_tblx
        lda     SHOT_PUSH,x
        sta     MAL
        lda     SHOT_PUSH+1,x
        sta     MAH
        lda     SPL_SIN
        sta     MB
        jsr     smul16q7
        lda     MAL
        sta     SPL_PXL
        lda     MAH
        sta     SPL_PXH

        ldx     SPL_C
        jsr     spl_tblx
        lda     SHOT_PUSH,x
        sta     MAL
        lda     SHOT_PUSH+1,x
        sta     MAH
        lda     SPL_COS
        sta     MB
        jsr     smul16q7
        sec                             ; forward's y term is MINUS the cosine
        lda     #$00
        sbc     MAL
        sta     SPL_PYL
        lda     #$00
        sbc     MAH
        sta     SPL_PYH

        ; ---- which two shapes they wear -------------------------------------
        ; Drawn here rather than in spl_one, because the two have to differ:
        ; twins coming out of one rock read as a copy-paste, not as a break.
        ; The second is the first plus a step of 1..AST_TYPES-1 round the ring,
        ; which cannot land back on it.
        jsr     prng
        and     #$07
        tay
        lda     TYPE_PICK,y
        sta     SPL_TYA
        jsr     prng
        and     #$07
        tay
        clc
        lda     TYPE_STEP,y
        adc     SPL_TYA
        cmp     #AST_TYPES
        bcc     :+
        sec
        sbc     #AST_TYPES
:       sta     SPL_TYB

        ; ---- and then the two of them ---------------------------------------
        stz     SPL_I
        lda     SPL_P
        sta     SPL_T
        jsr     spl_one
        inc     SPL_I
        lda     SPL_S
        sta     SPL_T
        jsr     spl_one

        ; ---- one more puff, exactly between them ----------------------------
        ; The parent's own centre, which is where neither child is any more.
        lda     SPL_XL
        sta     EXTXL
        lda     SPL_XH
        sta     EXTXH
        lda     SPL_YL
        sta     EXTYL
        lda     SPL_YH
        sta     EXTYH
        jmp     expl_at

; X = a class, and this turns it into the byte offset of a .word table entry.
spl_tblx:
        txa
        asl     a
        tax
        rts

; -----------------------------------------------------------------------------
; spl_one — build one child. SPL_T is its slot, SPL_I is 0 for + and 1 for -.
; -----------------------------------------------------------------------------
spl_one:
        ldx     SPL_T
        lda     SPL_XF                  ; the sub-unit part rides along untouched:
        sta     OBJXF,x                 ;   the offset is whole world units
        lda     SPL_YF
        sta     OBJYF,x

        lda     SPL_I
        bne     @minus

        clc                             ; ---- the + child ----
        lda     SPL_XL
        adc     SPL_OXL
        sta     OBJXL,x
        lda     SPL_XH
        adc     SPL_OXH
        sta     OBJXH,x
        clc
        lda     SPL_YL
        adc     SPL_OYL
        sta     OBJYL,x
        lda     SPL_YH
        adc     SPL_OYH
        sta     OBJYH,x
        clc
        lda     SPL_VXL
        adc     SPL_DVXL
        sta     OBJVXL,x
        lda     SPL_VXH
        adc     SPL_DVXH
        sta     OBJVXH,x
        clc
        lda     SPL_VYL
        adc     SPL_DVYL
        sta     OBJVYL,x
        lda     SPL_VYH
        adc     SPL_DVYH
        sta     OBJVYH,x
        clc
        lda     SPL_SPL
        adc     #<SPLIT_SPIN
        sta     OBJSPNL,x
        lda     SPL_SPH
        adc     #>SPLIT_SPIN
        sta     OBJSPNH,x
        lda     SPL_ANG
        sta     OBJANG,x
        bra     @push

@minus:                                 ; ---- the - child ----
        sec
        lda     SPL_XL
        sbc     SPL_OXL
        sta     OBJXL,x
        lda     SPL_XH
        sbc     SPL_OXH
        sta     OBJXH,x
        sec
        lda     SPL_YL
        sbc     SPL_OYL
        sta     OBJYL,x
        lda     SPL_YH
        sbc     SPL_OYH
        sta     OBJYH,x
        sec
        lda     SPL_VXL
        sbc     SPL_DVXL
        sta     OBJVXL,x
        lda     SPL_VXH
        sbc     SPL_DVXH
        sta     OBJVXH,x
        sec
        lda     SPL_VYL
        sbc     SPL_DVYL
        sta     OBJVYL,x
        lda     SPL_VYH
        sbc     SPL_DVYH
        sta     OBJVYH,x
        sec
        lda     SPL_SPL
        sbc     #<SPLIT_SPIN
        sta     OBJSPNL,x
        lda     SPL_SPH
        sbc     #>SPLIT_SPIN
        sta     OBJSPNH,x
        clc                             ; ...and a quarter turn out of step, so
        lda     SPL_ANG                 ;   the pair does not read as one shape
        adc     #64                     ;   cut down the middle
        sta     OBJANG,x

@push:  ldx     SPL_T                   ; the shot's own momentum goes on BOTH -
        clc                             ;   the one term that is meant to move
        lda     OBJVXL,x                ;   the total, because it comes from
        adc     SPL_PXL                 ;   outside the field
        sta     OBJVXL,x
        lda     OBJVXH,x
        adc     SPL_PXH
        sta     OBJVXH,x
        clc
        lda     OBJVYL,x
        adc     SPL_PYL
        sta     OBJVYL,x
        lda     OBJVYH,x
        adc     SPL_PYH
        sta     OBJVYH,x

        lda     OBJVXL,x                ; ...and the cap, per axis
        sta     MAL
        lda     OBJVXH,x
        sta     MAH
        jsr     spl_clamp
        ldx     SPL_T
        lda     MAL
        sta     OBJVXL,x
        lda     MAH
        sta     OBJVXH,x
        lda     OBJVYL,x
        sta     MAL
        lda     OBJVYH,x
        sta     MAH
        jsr     spl_clamp
        ldx     SPL_T
        lda     MAL
        sta     OBJVYL,x
        lda     MAH
        sta     OBJVYH,x

        lda     #$00                    ; a fresh angle fraction, its class, and
        sta     OBJANGF,x               ;   the hit points that class is worth
        lda     SPL_C
        sta     OBJSHP,x
        tay
        lda     ROCK_HP,y
        sta     OBJHP,x
        lda     SPL_I                   ; ...and its authored variant, which
        beq     @tya                    ;   rock_split drew for the pair so that
        lda     SPL_TYB                 ;   the two of them could be made to
        bra     @tyw                    ;   differ
@tya:   lda     SPL_TYA
@tyw:   sta     OBJTYPE,x

        jmp     cell_link               ; ...and into the grid where it now is

; MA, signed 8.8, clamped to +/- SPLIT_VMAX. The same shape as rock_spin's spin
; clamp, and there for the same reason: something is adding momentum now.
spl_clamp:
        lda     MAH
        bmi     @neg
        cmp     #>SPLIT_VMAX
        bcc     @done
        bne     @hi
        lda     MAL
        cmp     #<SPLIT_VMAX
        bcc     @done
@hi:    lda     #<SPLIT_VMAX
        sta     MAL
        lda     #>SPLIT_VMAX
        sta     MAH
@done:  rts
@neg:   sec
        lda     #$00
        sbc     MAL
        tay
        lda     #$00
        sbc     MAH
        cmp     #>SPLIT_VMAX
        bcc     @done
        bne     @lo
        cpy     #<SPLIT_VMAX
        bcc     @done
@lo:    sec
        lda     #$00
        sbc     #<SPLIT_VMAX
        sta     MAL
        lda     #$00
        sbc     #>SPLIT_VMAX
        sta     MAH
        rts

; -----------------------------------------------------------------------------
; rock_sweep / rock_recycle — the smallest class is DEBRIS, and debris is swept.
; -----------------------------------------------------------------------------
; THE 16s DO NOT COUNT. They exist so that a 32 has something to come apart
; into, and so that a hit has something to scatter; they are a special effect
; with collision, not part of the field the player is clearing. So the moment
; one has drifted RECYC_FAR from the ship it is dropped, without ceremony and
; without ever being seen to go - and `rocks_left` does not count them in the
; first place.
;
; That is what makes the split affordable. A destroyed rock becomes two of the
; next class down, so the field multiplies, and the leaf of that cascade is
; exactly the class this sweep is taking back: the slots the split spends are
; the slots the sweep returns. Without it, 120 rocks taken all the way apart is
; 570 against 255 slots; with it, the 16s never accumulate at all.
;
; It amends fixed decision 6 for this one class - see design_technical.md 11.6 -
; and the amendment is bounded by RECYC_FAR, which is six times the distance at
; which anything can still be on screen.
;
; rock_sweep runs every frame and examines RECYC_STEP slots. rock_recycle is the
; same test used as an emergency: it walks the WHOLE field looking for one, and
; is only called when a split has nowhere to put its second half. With the sweep
; running it should never find work, and NBLOCK counts the times it did not.
; -----------------------------------------------------------------------------
rock_sweep:
        lda     #RECYC_STEP
        sta     SWEEPN
@lp:    jsr     recyc_next
        jsr     recyc_ok
        bcc     @next
        jsr     recyc_drop
@next:  dec     SWEEPN
        bne     @lp
        rts

rock_recycle:
        ldy     #$00
@lp:    jsr     recyc_next
        jsr     recyc_ok
        bcs     @take
        iny
        cpy     NROCK
        bne     @lp
        sec                             ; nothing safe to take
        rts
@take:  jsr     recyc_drop
        clc
        rts

; The cursor: X = the next slot to look at, wrapping at the high-water mark.
recyc_next:
        ldx     RECYCI
        inx
        cpx     NROCK
        bcc     :+
        ldx     #$00
:       stx     RECYCI
        rts

; X = a slot. Carry SET if it is a speck that may be dropped. Three conditions,
; and each one closes a different door: the smallest class only, so nothing the
; player was aiming at can vanish (SHP_DEAD fails this too); far enough away
; that it cannot be seen going and cannot be about to come into view; and the
; wrap is free, because a high-byte subtract read as signed is already the short
; way round the torus.
recyc_ok:
        lda     OBJSHP,x
        cmp     #SPLIT_LAST
        bne     @no
        sec
        lda     OBJXH,x
        sbc     SHXH
        jsr     spl_far                 ; far on EITHER axis is enough to be off
        bcs     @yes                    ;   the screen
        ldx     RECYCI
        sec
        lda     OBJYH,x
        sbc     SHYH
        jsr     spl_far
        bcs     @yes
@no:    clc
        rts
@yes:   sec
        rts

; X is not needed - the cursor is. Take it out of the grid, off the census and
; back onto the free stack.
recyc_drop:
        ldx     RECYCI
        jsr     rock_kill
        lda     RECYCI
        jsr     rock_free
        inc     NRECYC
        rts

; -----------------------------------------------------------------------------
; rocks_left — A = how many rocks the player still has to break.
; -----------------------------------------------------------------------------
; Classes 0 to 3, and NOT the smallest: the 16s are debris (see rock_sweep) and
; counting them would make a level's remaining work jump upwards every time
; something was destroyed. RKLIVE is maintained by rock_kill, rock_split and
; recyc_drop between them, so this is a sum and never a walk of the field.
;
; Nothing reads it yet - the mission types are open (open_questions.md F1) - and
; it is here because "how many are left" is the one number all three of them
; need and it must mean the same thing to all three.
rocks_left:
        lda     RKLIVE+0
        clc
        adc     RKLIVE+1
        clc
        adc     RKLIVE+2
        clc
        adc     RKLIVE+3
        rts

; A, a signed byte of position HIGH bytes. Carry SET if it is at least RECYC_FAR
; away - and the wrap is free, because a high-byte subtract read as signed is
; already the short way round the torus.
spl_far:
        bpl     :+
        eor     #$FF
        inc     a
:       cmp     #RECYC_FAR
        rts

; =============================================================================
; The clouds
; =============================================================================
        .segment "RODATA"

; How many of the eight pixels are still drawn at each age. The cloud does not
; fade - a pixel is on or it is not - so it THINS instead, and because EXPL_OFF
; stores its eight offsets in bit-reversed order (0, 4, 2, 6, 1, 5, 3, 7 round
; the ring) the first six and the first four are still spread rather than being
; an arc with a hole in it.
EXPL_DOTS:  .byte   8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
            .byte   8, 8, 8, 8, 6, 6, 6, 6, 4, 4, 4, 4

; THE SPLIT'S FOUR NUMBERS, the ones physics.md section 6 lists as (TBM). All
; three tables are indexed by the CHILD's class, so entry 0 is never read - a
; 192 is nobody's child.
;
; SPLIT_OFF is where each half starts, in world units from the parent's centre.
; The multiplicands are BODY_R (physics.s), the collision radii in half-res
; pixels, and 32 world units is one of those.
;
; IT WAS 48 - one and a half radii, so the halves were born clear of each other
; and never overlapped. Flown, that read as TWO ROCKS TELEPORTING IN rather than
; as one coming apart: a 128 put its halves 156 full-res pixels apart on the
; frame it died, which is further than either of them then travelled in the next
; second. 10 is a THIRD of a radius, so they start deeply overlapped and visibly
; separate over the following frames, which is the thing that reads as a split.
;
; The overlap is not free and it is not a bug: physics.s sees two bodies inside
; each other and pushes them apart, on top of the SPLIT_V they already have. It
; can do that - col_separate is mass-weighted and resolves over frames rather
; than teleporting anything - and its push is along the same axis SPLIT_V is, so
; the two agree rather than fight.
;                        192      128       64       32       16
SPLIT_OFF:  .word     10*39,   10*26,   10*13,    10*7,    10*3

; SPLIT_V is how fast they leave, signed 8.8 world units a frame, each half
; getting it in the opposite direction. 8.0 is 30 px/s, so a pair of 128s parts
; at 60 px/s and a pair of 16s at 150 - smaller debris scatters harder, which is
; both what it looks like and what keeps the small stuff from piling up where it
; was made. The authored drift for comparison is 8 to 50 px/s (AST_VEL).
SPLIT_V:    .word     $0800,   $0800,   $0C00,   $1000,   $1400

; SHOT_PUSH is the bullet's own momentum, along the shot and added to BOTH
; halves, so the pair visibly recoils away from the player instead of just
; opening up in place. It is the one term in the whole file that is meant to
; change the field's total momentum - everything else is equal and opposite.
SHOT_PUSH:  .word     $0200,   $0200,   $0300,   $0400,   $0500

; The twist a hit puts on a rock, per size class: the change in spin, 8.8 brad
; per frame, for one full-res pixel of lever arm, times 128. See rock_spin.
;
; Derived rather than typed, and it is worth writing the derivation down because
; the numbers look arbitrary otherwise. A hit right on the RIM has an arm of
; 2*BODY_R (BODY_R is half-res, the arm is full-res), and that hit is meant to
; move the spin by RIM_D below - which HALVES per class, because the mass does.
; So the entry is 128 * RIM_D / (2*BODY_R), and the class's radius drops out:
; a rim hit is a rim hit whatever size the rock is.
;
;                    192     128      64      32      16
;   BODY_R            39      26      13       7       3
;   arm at the rim    78      52      26      14       6
;
; SPIN_RIM is the authored half - what a rim hit is worth, halving per class -
; and SPIN_G is worked out from it by the ASSEMBLER, so the two can never drift
; apart and there is nothing here to mistype. The same reason physics.s writes
; RECIP64 as an expression instead of sixty-four numbers.
SPIN_RIM:   .word    48,     96,    192,    384,    768
SPIN_G:     .word   128*48/78, 128*96/52, 128*192/26, 128*384/14, 128*768/6

; block group -> its first block in EXPL_OFF, so expl_one needs no multiply to
; find one. The same shape as shapes.s's CLASS_BASE, and for the same reason.
; The group is size * EXPL_SETS + cloud, which is why there are eight of them
; and not four: the zoom's size step rides in the same index.
EXPL_BASE:  .byte   0*EXPL_AGES, 1*EXPL_AGES, 2*EXPL_AGES, 3*EXPL_AGES
            .byte   4*EXPL_AGES, 5*EXPL_AGES, 6*EXPL_AGES, 7*EXPL_AGES

; EXPL_OFF - the whole animation, as EXPL_SIZES x EXPL_SETS x EXPL_AGES blocks
; of eight (dx, dy) offsets in HALF-res pixels from the hit point. Size-major,
; then cloud, then age. 3,072 bytes, and it is what makes a frame of a puff
; eight table reads and eight adds with no arithmetic of any kind behind it -
; the zoom included.
;
; The radii EASE OUT - r = size * (2 + 8*(1 - (1-t)^2)) over EXPL_AGES frames,
; so the pixels leap away and then slow down - which is the shape of a real puff
; and is far cheaper authored than integrated. At size 1.0 the cloud reaches 10
; half-res pixels, i.e. 40 full-res across: about the size of a 32 px rock, and
; that is the one the camera pulled all the way back gets. At 1.6 it is the one
; drawn at 1:1, where the rocks are twice the size. Those two numbers, the frame
; count and the eight pixels are the knobs here.
;
; Angles and radii are jittered per pixel and per cloud - an even ring of eight
; reads as machined, the same way a regular polygon does for a rock (see
; shapes.s). Generated once from a seeded draw and then AUTHORED here: there is
; no tool that regenerates it, and it does not need one. Neither slowing the
; animation down nor adding the second size redrew the clouds - both resampled
; the same four, so they are the shapes they always were.
EXPL_OFF:
; --- size 0 (x1.0), cloud 0 ---
              .byte     2,     0,   <-2,     0,     0,     2,     0,   <-2    ; age  0, r 2.0
              .byte     1,     1,   <-1,   <-1,   <-2,     1,     1,   <-1
              .byte     2,     0,   <-2,   <-1,     0,     3,     0,   <-3    ; age  1, r 2.7
              .byte     1,     2,   <-1,   <-2,   <-2,     2,     1,   <-2
              .byte     3,     0,   <-3,   <-1,     0,     3,     0,   <-3    ; age  2, r 3.3
              .byte     1,     2,   <-2,   <-2,   <-3,     2,     1,   <-2
              .byte     3,     0,   <-4,   <-1,     0,     4,     0,   <-4    ; age  3, r 4.0
              .byte     1,     2,   <-2,   <-2,   <-3,     3,     1,   <-2
              .byte     4,     0,   <-4,   <-1,     0,     5,   <-1,   <-5    ; age  4, r 4.5
              .byte     2,     3,   <-2,   <-3,   <-4,     3,     1,   <-3
              .byte     4,     0,   <-5,   <-1,     0,     5,   <-1,   <-5    ; age  5, r 5.1
              .byte     2,     3,   <-3,   <-3,   <-4,     3,     2,   <-3
              .byte     5,     0,   <-5,   <-1,     0,     6,   <-1,   <-6    ; age  6, r 5.6
              .byte     2,     3,   <-3,   <-3,   <-5,     4,     2,   <-3
              .byte     5,     0,   <-6,   <-1,     0,     6,   <-1,   <-6    ; age  7, r 6.1
              .byte     2,     4,   <-3,   <-4,   <-5,     4,     2,   <-4
              .byte     5,     0,   <-6,   <-1,     0,     7,   <-1,   <-7    ; age  8, r 6.6
              .byte     2,     4,   <-4,   <-4,   <-5,     4,     2,   <-4
              .byte     6,     0,   <-6,   <-1,     0,     7,   <-1,   <-7    ; age  9, r 7.0
              .byte     2,     4,   <-4,   <-4,   <-6,     5,     2,   <-4
              .byte     6,     0,   <-7,   <-2,     0,     7,   <-1,   <-8    ; age 10, r 7.4
              .byte     2,     4,   <-4,   <-4,   <-6,     5,     2,   <-5
              .byte     6,     0,   <-7,   <-2,     0,     8,   <-1,   <-8    ; age 11, r 7.8
              .byte     3,     5,   <-4,   <-5,   <-6,     5,     3,   <-5
              .byte     7,     0,   <-7,   <-2,     0,     8,   <-1,   <-9    ; age 12, r 8.2
              .byte     3,     5,   <-4,   <-5,   <-7,     5,     3,   <-5
              .byte     7,     0,   <-8,   <-2,     0,     8,   <-1,   <-9    ; age 13, r 8.5
              .byte     3,     5,   <-5,   <-5,   <-7,     6,     3,   <-5
              .byte     7,     0,   <-8,   <-2,     0,     9,   <-1,   <-9    ; age 14, r 8.8
              .byte     3,     5,   <-5,   <-5,   <-7,     6,     3,   <-5
              .byte     7,     0,   <-8,   <-2,     0,     9,   <-1,   <-9    ; age 15, r 9.0
              .byte     3,     5,   <-5,   <-5,   <-7,     6,     3,   <-6
              .byte     8,     0,   <-8,   <-2,     0,     9,   <-1,  <-10    ; age 16, r 9.3
              .byte     3,     5,   <-5,   <-5,   <-7,     6,     3,   <-6
              .byte     8,     0,   <-8,   <-2,     0,     9,   <-1,  <-10    ; age 17, r 9.5
              .byte     3,     5,   <-5,   <-6,   <-8,     6,     3,   <-6
              .byte     8,     0,   <-9,   <-2,     0,    10,   <-1,  <-10    ; age 18, r 9.6
              .byte     3,     6,   <-5,   <-6,   <-8,     6,     3,   <-6
              .byte     8,     0,   <-9,   <-2,     0,    10,   <-1,  <-10    ; age 19, r 9.8
              .byte     3,     6,   <-5,   <-6,   <-8,     6,     3,   <-6
              .byte     8,     0,   <-9,   <-2,     0,    10,   <-1,  <-10    ; age 20, r 9.9
              .byte     3,     6,   <-5,   <-6,   <-8,     6,     3,   <-6
              .byte     8,     0,   <-9,   <-2,     0,    10,   <-1,  <-10    ; age 21, r 9.9
              .byte     3,     6,   <-5,   <-6,   <-8,     7,     3,   <-6
              .byte     8,     0,   <-9,   <-2,     0,    10,   <-1,  <-10    ; age 22, r 10.0
              .byte     3,     6,   <-5,   <-6,   <-8,     7,     3,   <-6
              .byte     8,     0,   <-9,   <-2,     0,    10,   <-1,  <-10    ; age 23, r 10.0
              .byte     3,     6,   <-5,   <-6,   <-8,     7,     3,   <-6
; --- size 0 (x1.0), cloud 1 ---
              .byte     2,     0,   <-2,     0,     0,     2,     0,   <-2    ; age  0, r 2.0
              .byte     2,     1,   <-1,   <-1,   <-2,     2,     2,   <-1
              .byte     3,     0,   <-3,   <-1,     1,     2,     0,   <-2    ; age  1, r 2.7
              .byte     3,     2,   <-2,   <-2,   <-2,     2,     3,   <-2
              .byte     4,     0,   <-4,   <-1,     1,     3,     0,   <-3    ; age  2, r 3.3
              .byte     3,     2,   <-2,   <-2,   <-3,     3,     3,   <-2
              .byte     5,     0,   <-5,   <-1,     1,     3,     0,   <-3    ; age  3, r 4.0
              .byte     4,     3,   <-2,   <-3,   <-3,     3,     4,   <-3
              .byte     5,     0,   <-5,   <-1,     1,     4,     0,   <-4    ; age  4, r 4.5
              .byte     5,     3,   <-3,   <-3,   <-3,     4,     4,   <-3
              .byte     6,     0,   <-6,   <-1,     1,     4,     0,   <-4    ; age  5, r 5.1
              .byte     5,     4,   <-3,   <-3,   <-4,     4,     5,   <-3
              .byte     7,     0,   <-7,   <-1,     1,     5,     0,   <-5    ; age  6, r 5.6
              .byte     6,     4,   <-3,   <-4,   <-4,     4,     5,   <-4
              .byte     7,     0,   <-7,   <-1,     1,     5,     0,   <-5    ; age  7, r 6.1
              .byte     6,     4,   <-4,   <-4,   <-5,     5,     6,   <-4
              .byte     8,     0,   <-8,   <-2,     1,     6,     0,   <-6    ; age  8, r 6.6
              .byte     7,     5,   <-4,   <-5,   <-5,     5,     6,   <-4
              .byte     8,     0,   <-8,   <-2,     1,     6,     0,   <-6    ; age  9, r 7.0
              .byte     7,     5,   <-4,   <-5,   <-5,     6,     7,   <-5
              .byte     9,     0,   <-9,   <-2,     2,     6,     0,   <-6    ; age 10, r 7.4
              .byte     8,     5,   <-4,   <-5,   <-6,     6,     7,   <-5
              .byte     9,     0,   <-9,   <-2,     2,     7,     0,   <-7    ; age 11, r 7.8
              .byte     8,     6,   <-4,   <-5,   <-6,     6,     7,   <-5
              .byte    10,     0,   <-9,   <-2,     2,     7,     0,   <-7    ; age 12, r 8.2
              .byte     8,     6,   <-5,   <-6,   <-6,     6,     8,   <-5
              .byte    10,     0,  <-10,   <-2,     2,     7,     0,   <-7    ; age 13, r 8.5
              .byte     9,     6,   <-5,   <-6,   <-6,     7,     8,   <-6
              .byte    11,     0,  <-10,   <-2,     2,     7,     0,   <-8    ; age 14, r 8.8
              .byte     9,     6,   <-5,   <-6,   <-7,     7,     8,   <-6
              .byte    11,     0,  <-10,   <-2,     2,     8,     0,   <-8    ; age 15, r 9.0
              .byte     9,     6,   <-5,   <-6,   <-7,     7,     8,   <-6
              .byte    11,     0,  <-11,   <-2,     2,     8,     0,   <-8    ; age 16, r 9.3
              .byte     9,     7,   <-5,   <-6,   <-7,     7,     9,   <-6
              .byte    11,     0,  <-11,   <-2,     2,     8,     0,   <-8    ; age 17, r 9.5
              .byte    10,     7,   <-5,   <-6,   <-7,     7,     9,   <-6
              .byte    12,     0,  <-11,   <-2,     2,     8,     0,   <-8    ; age 18, r 9.6
              .byte    10,     7,   <-5,   <-7,   <-7,     8,     9,   <-6
              .byte    12,     0,  <-11,   <-2,     2,     8,     0,   <-8    ; age 19, r 9.8
              .byte    10,     7,   <-6,   <-7,   <-7,     8,     9,   <-6
              .byte    12,     0,  <-11,   <-2,     2,     8,     0,   <-9    ; age 20, r 9.9
              .byte    10,     7,   <-6,   <-7,   <-8,     8,     9,   <-7
              .byte    12,     0,  <-12,   <-2,     2,     8,     0,   <-9    ; age 21, r 9.9
              .byte    10,     7,   <-6,   <-7,   <-8,     8,     9,   <-7
              .byte    12,     0,  <-12,   <-2,     2,     8,     0,   <-9    ; age 22, r 10.0
              .byte    10,     7,   <-6,   <-7,   <-8,     8,     9,   <-7
              .byte    12,     0,  <-12,   <-2,     2,     8,     0,   <-9    ; age 23, r 10.0
              .byte    10,     7,   <-6,   <-7,   <-8,     8,     9,   <-7
; --- size 0 (x1.0), cloud 2 ---
              .byte     3,     0,   <-2,     0,     0,     2,     0,   <-2    ; age  0, r 2.0
              .byte     2,     1,   <-2,   <-1,   <-1,     1,     2,   <-1
              .byte     3,     0,   <-2,     0,     1,     2,   <-1,   <-3    ; age  1, r 2.7
              .byte     3,     1,   <-3,   <-2,   <-1,     1,     2,   <-1
              .byte     4,     0,   <-3,     0,     1,     3,   <-1,   <-4    ; age  2, r 3.3
              .byte     4,     2,   <-3,   <-2,   <-2,     2,     3,   <-1
              .byte     5,   <-1,   <-3,   <-1,     1,     4,   <-1,   <-5    ; age  3, r 4.0
              .byte     4,     2,   <-4,   <-2,   <-2,     2,     3,   <-2
              .byte     6,   <-1,   <-4,   <-1,     1,     4,   <-1,   <-5    ; age  4, r 4.5
              .byte     5,     2,   <-5,   <-3,   <-2,     2,     4,   <-2
              .byte     6,   <-1,   <-4,   <-1,     1,     5,   <-1,   <-6    ; age  5, r 5.1
              .byte     5,     3,   <-5,   <-3,   <-2,     3,     4,   <-2
              .byte     7,   <-1,   <-4,   <-1,     1,     5,   <-1,   <-7    ; age  6, r 5.6
              .byte     6,     3,   <-6,   <-4,   <-3,     3,     5,   <-2
              .byte     8,   <-1,   <-5,   <-1,     1,     5,   <-1,   <-7    ; age  7, r 6.1
              .byte     6,     3,   <-6,   <-4,   <-3,     3,     5,   <-2
              .byte     8,   <-1,   <-5,   <-1,     1,     6,   <-1,   <-8    ; age  8, r 6.6
              .byte     7,     3,   <-7,   <-4,   <-3,     3,     5,   <-3
              .byte     9,   <-1,   <-6,   <-1,     1,     6,   <-1,   <-8    ; age  9, r 7.0
              .byte     7,     4,   <-7,   <-4,   <-3,     4,     6,   <-3
              .byte     9,   <-1,   <-6,   <-1,     1,     7,   <-1,   <-9    ; age 10, r 7.4
              .byte     8,     4,   <-7,   <-5,   <-4,     4,     6,   <-3
              .byte    10,   <-1,   <-6,   <-1,     2,     7,   <-1,   <-9    ; age 11, r 7.8
              .byte     8,     4,   <-8,   <-5,   <-4,     4,     6,   <-3
              .byte    10,   <-1,   <-6,   <-1,     2,     7,   <-2,  <-10    ; age 12, r 8.2
              .byte     9,     4,   <-8,   <-5,   <-4,     4,     7,   <-3
              .byte    11,   <-1,   <-7,   <-1,     2,     8,   <-2,  <-10    ; age 13, r 8.5
              .byte     9,     4,   <-8,   <-5,   <-4,     4,     7,   <-3
              .byte    11,   <-1,   <-7,   <-1,     2,     8,   <-2,  <-11    ; age 14, r 8.8
              .byte     9,     5,   <-9,   <-5,   <-4,     5,     7,   <-4
              .byte    11,   <-1,   <-7,   <-1,     2,     8,   <-2,  <-11    ; age 15, r 9.0
              .byte    10,     5,   <-9,   <-6,   <-4,     5,     7,   <-4
              .byte    12,   <-1,   <-7,   <-1,     2,     8,   <-2,  <-11    ; age 16, r 9.3
              .byte    10,     5,   <-9,   <-6,   <-4,     5,     7,   <-4
              .byte    12,   <-1,   <-7,   <-1,     2,     8,   <-2,  <-11    ; age 17, r 9.5
              .byte    10,     5,   <-9,   <-6,   <-5,     5,     8,   <-4
              .byte    12,   <-1,   <-8,   <-1,     2,     9,   <-2,  <-12    ; age 18, r 9.6
              .byte    10,     5,  <-10,   <-6,   <-5,     5,     8,   <-4
              .byte    12,   <-1,   <-8,   <-1,     2,     9,   <-2,  <-12    ; age 19, r 9.8
              .byte    10,     5,  <-10,   <-6,   <-5,     5,     8,   <-4
              .byte    13,   <-1,   <-8,   <-1,     2,     9,   <-2,  <-12    ; age 20, r 9.9
              .byte    10,     5,  <-10,   <-6,   <-5,     5,     8,   <-4
              .byte    13,   <-1,   <-8,   <-1,     2,     9,   <-2,  <-12    ; age 21, r 9.9
              .byte    10,     5,  <-10,   <-6,   <-5,     5,     8,   <-4
              .byte    13,   <-1,   <-8,   <-1,     2,     9,   <-2,  <-12    ; age 22, r 10.0
              .byte    11,     5,  <-10,   <-6,   <-5,     5,     8,   <-4
              .byte    13,   <-1,   <-8,   <-1,     2,     9,   <-2,  <-12    ; age 23, r 10.0
              .byte    11,     5,  <-10,   <-6,   <-5,     5,     8,   <-4
; --- size 0 (x1.0), cloud 3 ---
              .byte     2,     1,   <-2,     0,     0,     2,     0,   <-2    ; age  0, r 2.0
              .byte     2,     1,   <-1,   <-1,   <-2,     1,     1,   <-1
              .byte     2,     1,   <-3,     0,     1,     3,     0,   <-3    ; age  1, r 2.7
              .byte     3,     1,   <-2,   <-1,   <-3,     2,     1,   <-2
              .byte     3,     1,   <-3,     1,     1,     3,     0,   <-3    ; age  2, r 3.3
              .byte     3,     2,   <-2,   <-2,   <-3,     2,     1,   <-2
              .byte     3,     1,   <-4,     1,     1,     4,     1,   <-4    ; age  3, r 4.0
              .byte     4,     2,   <-3,   <-2,   <-4,     2,     1,   <-2
              .byte     4,     1,   <-4,     1,     1,     5,     1,   <-5    ; age  4, r 4.5
              .byte     4,     2,   <-3,   <-2,   <-5,     3,     2,   <-3
              .byte     4,     1,   <-5,     1,     1,     5,     1,   <-5    ; age  5, r 5.1
              .byte     5,     2,   <-4,   <-3,   <-5,     3,     2,   <-3
              .byte     4,     1,   <-6,     1,     1,     6,     1,   <-6    ; age  6, r 5.6
              .byte     5,     3,   <-4,   <-3,   <-6,     4,     2,   <-3
              .byte     5,     2,   <-6,     1,     1,     6,     1,   <-6    ; age  7, r 6.1
              .byte     6,     3,   <-5,   <-3,   <-6,     4,     2,   <-4
              .byte     5,     2,   <-6,     1,     1,     7,     1,   <-7    ; age  8, r 6.6
              .byte     6,     3,   <-5,   <-4,   <-7,     4,     2,   <-4
              .byte     6,     2,   <-7,     1,     1,     7,     1,   <-7    ; age  9, r 7.0
              .byte     7,     3,   <-5,   <-4,   <-7,     4,     2,   <-4
              .byte     6,     2,   <-7,     1,     2,     7,     1,   <-8    ; age 10, r 7.4
              .byte     7,     4,   <-6,   <-4,   <-8,     5,     3,   <-4
              .byte     6,     2,   <-8,     1,     2,     8,     1,   <-8    ; age 11, r 7.8
              .byte     8,     4,   <-6,   <-4,   <-8,     5,     3,   <-5
              .byte     7,     2,   <-8,     1,     2,     8,     1,   <-9    ; age 12, r 8.2
              .byte     8,     4,   <-6,   <-4,   <-8,     5,     3,   <-5
              .byte     7,     2,   <-8,     1,     2,     8,     1,   <-9    ; age 13, r 8.5
              .byte     8,     4,   <-6,   <-5,   <-9,     5,     3,   <-5
              .byte     7,     2,   <-9,     2,     2,     9,     1,   <-9    ; age 14, r 8.8
              .byte     8,     4,   <-7,   <-5,   <-9,     6,     3,   <-5
              .byte     7,     2,   <-9,     2,     2,     9,     1,   <-9    ; age 15, r 9.0
              .byte     9,     4,   <-7,   <-5,   <-9,     6,     3,   <-5
              .byte     7,     2,   <-9,     2,     2,     9,     1,  <-10    ; age 16, r 9.3
              .byte     9,     4,   <-7,   <-5,  <-10,     6,     3,   <-5
              .byte     8,     2,   <-9,     2,     2,     9,     1,  <-10    ; age 17, r 9.5
              .byte     9,     5,   <-7,   <-5,  <-10,     6,     3,   <-6
              .byte     8,     3,   <-9,     2,     2,    10,     1,  <-10    ; age 18, r 9.6
              .byte     9,     5,   <-7,   <-5,  <-10,     6,     3,   <-6
              .byte     8,     3,  <-10,     2,     2,    10,     1,  <-10    ; age 19, r 9.8
              .byte     9,     5,   <-7,   <-5,  <-10,     6,     3,   <-6
              .byte     8,     3,  <-10,     2,     2,    10,     1,  <-10    ; age 20, r 9.9
              .byte     9,     5,   <-7,   <-5,  <-10,     6,     3,   <-6
              .byte     8,     3,  <-10,     2,     2,    10,     1,  <-10    ; age 21, r 9.9
              .byte    10,     5,   <-7,   <-5,  <-10,     6,     4,   <-6
              .byte     8,     3,  <-10,     2,     2,    10,     1,  <-10    ; age 22, r 10.0
              .byte    10,     5,   <-7,   <-5,  <-10,     6,     4,   <-6
              .byte     8,     3,  <-10,     2,     2,    10,     1,  <-10    ; age 23, r 10.0
              .byte    10,     5,   <-7,   <-5,  <-10,     6,     4,   <-6
; --- size 1 (x1.6), cloud 0 ---
              .byte     3,     0,   <-3,   <-1,     0,     3,     0,   <-3    ; age  0, r 3.2
              .byte     1,     2,   <-2,   <-2,   <-3,     2,     1,   <-2
              .byte     3,     0,   <-4,   <-1,     0,     4,     0,   <-4    ; age  1, r 4.3
              .byte     1,     2,   <-2,   <-3,   <-3,     3,     1,   <-3
              .byte     4,     0,   <-5,   <-1,     0,     5,   <-1,   <-6    ; age  2, r 5.3
              .byte     2,     3,   <-3,   <-3,   <-4,     4,     2,   <-3
              .byte     5,     0,   <-6,   <-1,     0,     6,   <-1,   <-7    ; age  3, r 6.3
              .byte     2,     4,   <-3,   <-4,   <-5,     4,     2,   <-4
              .byte     6,     0,   <-7,   <-2,     0,     7,   <-1,   <-8    ; age  4, r 7.3
              .byte     2,     4,   <-4,   <-4,   <-6,     5,     2,   <-4
              .byte     7,     0,   <-7,   <-2,     0,     8,   <-1,   <-9    ; age  5, r 8.2
              .byte     3,     5,   <-4,   <-5,   <-7,     5,     3,   <-5
              .byte     7,     0,   <-8,   <-2,     0,     9,   <-1,   <-9    ; age  6, r 9.0
              .byte     3,     5,   <-5,   <-5,   <-7,     6,     3,   <-6
              .byte     8,     0,   <-9,   <-2,     0,    10,   <-1,  <-10    ; age  7, r 9.8
              .byte     3,     6,   <-5,   <-6,   <-8,     6,     3,   <-6
              .byte     9,     0,   <-9,   <-2,     0,    10,   <-1,  <-11    ; age  8, r 10.6
              .byte     4,     6,   <-6,   <-6,   <-9,     7,     3,   <-7
              .byte     9,   <-1,  <-10,   <-2,     0,    11,   <-1,  <-12    ; age  9, r 11.3
              .byte     4,     7,   <-6,   <-7,   <-9,     7,     4,   <-7
              .byte    10,   <-1,  <-11,   <-2,     0,    12,   <-1,  <-12    ; age 10, r 11.9
              .byte     4,     7,   <-6,   <-7,  <-10,     8,     4,   <-7
              .byte    10,   <-1,  <-11,   <-3,     0,    12,   <-1,  <-13    ; age 11, r 12.5
              .byte     4,     7,   <-7,   <-7,  <-10,     8,     4,   <-8
              .byte    11,   <-1,  <-12,   <-3,     0,    13,   <-1,  <-14    ; age 12, r 13.1
              .byte     4,     8,   <-7,   <-8,  <-11,     9,     4,   <-8
              .byte    11,   <-1,  <-12,   <-3,     0,    14,   <-2,  <-14    ; age 13, r 13.6
              .byte     5,     8,   <-7,   <-8,  <-11,     9,     4,   <-8
              .byte    11,   <-1,  <-13,   <-3,     0,    14,   <-2,  <-15    ; age 14, r 14.0
              .byte     5,     8,   <-8,   <-8,  <-11,     9,     5,   <-9
              .byte    12,   <-1,  <-13,   <-3,     0,    14,   <-2,  <-15    ; age 15, r 14.5
              .byte     5,     8,   <-8,   <-8,  <-12,    10,     5,   <-9
              .byte    12,   <-1,  <-13,   <-3,     0,    15,   <-2,  <-16    ; age 16, r 14.8
              .byte     5,     9,   <-8,   <-9,  <-12,    10,     5,   <-9
              .byte    12,   <-1,  <-14,   <-3,     0,    15,   <-2,  <-16    ; age 17, r 15.1
              .byte     5,     9,   <-8,   <-9,  <-12,    10,     5,   <-9
              .byte    13,   <-1,  <-14,   <-3,     0,    15,   <-2,  <-16    ; age 18, r 15.4
              .byte     5,     9,   <-8,   <-9,  <-12,    10,     5,   <-9
              .byte    13,   <-1,  <-14,   <-3,     0,    16,   <-2,  <-16    ; age 19, r 15.6
              .byte     5,     9,   <-8,   <-9,  <-13,    10,     5,  <-10
              .byte    13,   <-1,  <-14,   <-3,     0,    16,   <-2,  <-17    ; age 20, r 15.8
              .byte     5,     9,   <-9,   <-9,  <-13,    10,     5,  <-10
              .byte    13,   <-1,  <-14,   <-3,     0,    16,   <-2,  <-17    ; age 21, r 15.9
              .byte     5,     9,   <-9,   <-9,  <-13,    10,     5,  <-10
              .byte    13,   <-1,  <-14,   <-3,     0,    16,   <-2,  <-17    ; age 22, r 16.0
              .byte     5,     9,   <-9,   <-9,  <-13,    11,     5,  <-10
              .byte    13,   <-1,  <-14,   <-3,     0,    16,   <-2,  <-17    ; age 23, r 16.0
              .byte     5,     9,   <-9,   <-9,  <-13,    11,     5,  <-10
; --- size 1 (x1.6), cloud 1 ---
              .byte     4,     0,   <-4,   <-1,     1,     3,     0,   <-3    ; age  0, r 3.2
              .byte     3,     2,   <-2,   <-2,   <-2,     3,     3,   <-2
              .byte     5,     0,   <-5,   <-1,     1,     4,     0,   <-4    ; age  1, r 4.3
              .byte     4,     3,   <-2,   <-3,   <-3,     3,     4,   <-3
              .byte     6,     0,   <-6,   <-1,     1,     4,     0,   <-5    ; age  2, r 5.3
              .byte     5,     4,   <-3,   <-4,   <-4,     4,     5,   <-4
              .byte     8,     0,   <-7,   <-1,     1,     5,     0,   <-5    ; age  3, r 6.3
              .byte     6,     5,   <-4,   <-4,   <-5,     5,     6,   <-4
              .byte     9,     0,   <-8,   <-2,     1,     6,     0,   <-6    ; age  4, r 7.3
              .byte     7,     5,   <-4,   <-5,   <-6,     6,     7,   <-5
              .byte    10,     0,   <-9,   <-2,     2,     7,     0,   <-7    ; age  5, r 8.2
              .byte     8,     6,   <-5,   <-6,   <-6,     6,     8,   <-5
              .byte    11,     0,  <-10,   <-2,     2,     8,     0,   <-8    ; age  6, r 9.0
              .byte     9,     6,   <-5,   <-6,   <-7,     7,     8,   <-6
              .byte    12,     0,  <-11,   <-2,     2,     8,     0,   <-9    ; age  7, r 9.8
              .byte    10,     7,   <-6,   <-7,   <-7,     8,     9,   <-7
              .byte    13,     0,  <-12,   <-2,     2,     9,     0,   <-9    ; age  8, r 10.6
              .byte    11,     8,   <-6,   <-7,   <-8,     8,    10,   <-7
              .byte    14,     0,  <-13,   <-3,     2,     9,     0,  <-10    ; age  9, r 11.3
              .byte    12,     8,   <-6,   <-8,   <-9,     9,    11,   <-7
              .byte    14,     0,  <-14,   <-3,     2,    10,     1,  <-10    ; age 10, r 11.9
              .byte    12,     8,   <-7,   <-8,   <-9,     9,    11,   <-8
              .byte    15,     0,  <-14,   <-3,     3,    10,     1,  <-11    ; age 11, r 12.5
              .byte    13,     9,   <-7,   <-9,  <-10,    10,    12,   <-8
              .byte    16,     0,  <-15,   <-3,     3,    11,     1,  <-11    ; age 12, r 13.1
              .byte    13,     9,   <-7,   <-9,  <-10,    10,    12,   <-9
              .byte    16,     0,  <-16,   <-3,     3,    11,     1,  <-12    ; age 13, r 13.6
              .byte    14,    10,   <-8,   <-9,  <-10,    11,    13,   <-9
              .byte    17,     0,  <-16,   <-3,     3,    12,     1,  <-12    ; age 14, r 14.0
              .byte    14,    10,   <-8,  <-10,  <-11,    11,    13,   <-9
              .byte    17,     0,  <-17,   <-3,     3,    12,     1,  <-13    ; age 15, r 14.5
              .byte    15,    10,   <-8,  <-10,  <-11,    11,    14,  <-10
              .byte    18,     0,  <-17,   <-3,     3,    12,     1,  <-13    ; age 16, r 14.8
              .byte    15,    11,   <-8,  <-10,  <-11,    12,    14,  <-10
              .byte    18,     0,  <-18,   <-3,     3,    13,     1,  <-13    ; age 17, r 15.1
              .byte    15,    11,   <-9,  <-10,  <-12,    12,    14,  <-10
              .byte    19,     0,  <-18,   <-4,     3,    13,     1,  <-13    ; age 18, r 15.4
              .byte    16,    11,   <-9,  <-11,  <-12,    12,    14,  <-10
              .byte    19,     0,  <-18,   <-4,     3,    13,     1,  <-14    ; age 19, r 15.6
              .byte    16,    11,   <-9,  <-11,  <-12,    12,    15,  <-10
              .byte    19,     0,  <-18,   <-4,     3,    13,     1,  <-14    ; age 20, r 15.8
              .byte    16,    11,   <-9,  <-11,  <-12,    12,    15,  <-10
              .byte    19,     0,  <-18,   <-4,     3,    13,     1,  <-14    ; age 21, r 15.9
              .byte    16,    11,   <-9,  <-11,  <-12,    13,    15,  <-11
              .byte    19,     0,  <-18,   <-4,     3,    13,     1,  <-14    ; age 22, r 16.0
              .byte    16,    11,   <-9,  <-11,  <-12,    13,    15,  <-11
              .byte    19,     0,  <-19,   <-4,     3,    13,     1,  <-14    ; age 23, r 16.0
              .byte    16,    11,   <-9,  <-11,  <-12,    13,    15,  <-11
; --- size 1 (x1.6), cloud 2 ---
              .byte     4,     0,   <-3,     0,     1,     3,   <-1,   <-4    ; age  0, r 3.2
              .byte     3,     2,   <-3,   <-2,   <-2,     2,     3,   <-1
              .byte     5,   <-1,   <-3,   <-1,     1,     4,   <-1,   <-5    ; age  1, r 4.3
              .byte     5,     2,   <-4,   <-3,   <-2,     2,     3,   <-2
              .byte     7,   <-1,   <-4,   <-1,     1,     5,   <-1,   <-6    ; age  2, r 5.3
              .byte     6,     3,   <-5,   <-3,   <-3,     3,     4,   <-2
              .byte     8,   <-1,   <-5,   <-1,     1,     6,   <-1,   <-8    ; age  3, r 6.3
              .byte     7,     3,   <-6,   <-4,   <-3,     3,     5,   <-3
              .byte     9,   <-1,   <-6,   <-1,     1,     6,   <-1,   <-9    ; age  4, r 7.3
              .byte     8,     4,   <-7,   <-5,   <-3,     4,     6,   <-3
              .byte    10,   <-1,   <-6,   <-1,     2,     7,   <-2,  <-10    ; age  5, r 8.2
              .byte     9,     4,   <-8,   <-5,   <-4,     4,     7,   <-3
              .byte    11,   <-1,   <-7,   <-1,     2,     8,   <-2,  <-11    ; age  6, r 9.0
              .byte     9,     5,   <-9,   <-6,   <-4,     5,     7,   <-4
              .byte    12,   <-1,   <-8,   <-1,     2,     9,   <-2,  <-12    ; age  7, r 9.8
              .byte    10,     5,  <-10,   <-6,   <-5,     5,     8,   <-4
              .byte    13,   <-1,   <-8,   <-1,     2,     9,   <-2,  <-13    ; age  8, r 10.6
              .byte    11,     6,  <-10,   <-7,   <-5,     6,     9,   <-4
              .byte    14,   <-2,   <-9,   <-2,     2,    10,   <-2,  <-14    ; age  9, r 11.3
              .byte    12,     6,  <-11,   <-7,   <-5,     6,     9,   <-5
              .byte    15,   <-2,   <-9,   <-2,     2,    11,   <-2,  <-14    ; age 10, r 11.9
              .byte    13,     6,  <-12,   <-7,   <-6,     6,    10,   <-5
              .byte    16,   <-2,  <-10,   <-2,     2,    11,   <-2,  <-15    ; age 11, r 12.5
              .byte    13,     7,  <-12,   <-8,   <-6,     7,    10,   <-5
              .byte    17,   <-2,  <-10,   <-2,     3,    12,   <-3,  <-16    ; age 12, r 13.1
              .byte    14,     7,  <-13,   <-8,   <-6,     7,    11,   <-5
              .byte    17,   <-2,  <-11,   <-2,     3,    12,   <-3,  <-16    ; age 13, r 13.6
              .byte    14,     7,  <-13,   <-8,   <-7,     7,    11,   <-6
              .byte    18,   <-2,  <-11,   <-2,     3,    13,   <-3,  <-17    ; age 14, r 14.0
              .byte    15,     7,  <-14,   <-9,   <-7,     7,    11,   <-6
              .byte    18,   <-2,  <-11,   <-2,     3,    13,   <-3,  <-17    ; age 15, r 14.5
              .byte    15,     8,  <-14,   <-9,   <-7,     8,    12,   <-6
              .byte    19,   <-2,  <-12,   <-2,     3,    13,   <-3,  <-18    ; age 16, r 14.8
              .byte    16,     8,  <-15,   <-9,   <-7,     8,    12,   <-6
              .byte    19,   <-2,  <-12,   <-2,     3,    13,   <-3,  <-18    ; age 17, r 15.1
              .byte    16,     8,  <-15,   <-9,   <-7,     8,    12,   <-6
              .byte    20,   <-2,  <-12,   <-2,     3,    14,   <-3,  <-18    ; age 18, r 15.4
              .byte    16,     8,  <-15,  <-10,   <-7,     8,    12,   <-6
              .byte    20,   <-2,  <-12,   <-2,     3,    14,   <-3,  <-19    ; age 19, r 15.6
              .byte    16,     8,  <-15,  <-10,   <-7,     8,    13,   <-6
              .byte    20,   <-2,  <-12,   <-2,     3,    14,   <-3,  <-19    ; age 20, r 15.8
              .byte    17,     8,  <-16,  <-10,   <-8,     8,    13,   <-6
              .byte    20,   <-2,  <-13,   <-2,     3,    14,   <-3,  <-19    ; age 21, r 15.9
              .byte    17,     8,  <-16,  <-10,   <-8,     8,    13,   <-6
              .byte    20,   <-2,  <-13,   <-2,     3,    14,   <-3,  <-19    ; age 22, r 16.0
              .byte    17,     8,  <-16,  <-10,   <-8,     8,    13,   <-6
              .byte    20,   <-2,  <-13,   <-2,     3,    14,   <-3,  <-19    ; age 23, r 16.0
              .byte    17,     8,  <-16,  <-10,   <-8,     8,    13,   <-6
; --- size 1 (x1.6), cloud 3 ---
              .byte     3,     1,   <-3,     1,     1,     3,     0,   <-3    ; age  0, r 3.2
              .byte     3,     2,   <-2,   <-2,   <-3,     2,     1,   <-2
              .byte     3,     1,   <-4,     1,     1,     4,     1,   <-4    ; age  1, r 4.3
              .byte     4,     2,   <-3,   <-2,   <-4,     3,     2,   <-3
              .byte     4,     1,   <-5,     1,     1,     5,     1,   <-6    ; age  2, r 5.3
              .byte     5,     3,   <-4,   <-3,   <-5,     3,     2,   <-3
              .byte     5,     2,   <-6,     1,     1,     6,     1,   <-7    ; age  3, r 6.3
              .byte     6,     3,   <-5,   <-3,   <-7,     4,     2,   <-4
              .byte     6,     2,   <-7,     1,     1,     7,     1,   <-8    ; age  4, r 7.3
              .byte     7,     3,   <-5,   <-4,   <-7,     5,     3,   <-4
              .byte     7,     2,   <-8,     1,     2,     8,     1,   <-9    ; age  5, r 8.2
              .byte     8,     4,   <-6,   <-4,   <-8,     5,     3,   <-5
              .byte     7,     2,   <-9,     2,     2,     9,     1,   <-9    ; age  6, r 9.0
              .byte     9,     4,   <-7,   <-5,   <-9,     6,     3,   <-5
              .byte     8,     3,  <-10,     2,     2,    10,     1,  <-10    ; age  7, r 9.8
              .byte     9,     5,   <-7,   <-5,  <-10,     6,     3,   <-6
              .byte     8,     3,  <-10,     2,     2,    10,     2,  <-11    ; age  8, r 10.6
              .byte    10,     5,   <-8,   <-6,  <-11,     7,     4,   <-6
              .byte     9,     3,  <-11,     2,     2,    11,     2,  <-12    ; age  9, r 11.3
              .byte    11,     5,   <-8,   <-6,  <-12,     7,     4,   <-7
              .byte    10,     3,  <-12,     2,     2,    12,     2,  <-12    ; age 10, r 11.9
              .byte    11,     6,   <-9,   <-7,  <-12,     8,     4,   <-7
              .byte    10,     3,  <-12,     2,     3,    12,     2,  <-13    ; age 11, r 12.5
              .byte    12,     6,   <-9,   <-7,  <-13,     8,     4,   <-7
              .byte    10,     3,  <-13,     2,     3,    13,     2,  <-14    ; age 12, r 13.1
              .byte    13,     6,  <-10,   <-7,  <-13,     8,     5,   <-8
              .byte    11,     4,  <-13,     2,     3,    13,     2,  <-14    ; age 13, r 13.6
              .byte    13,     6,  <-10,   <-7,  <-14,     9,     5,   <-8
              .byte    11,     4,  <-14,     2,     3,    14,     2,  <-15    ; age 14, r 14.0
              .byte    14,     7,  <-11,   <-8,  <-14,     9,     5,   <-8
              .byte    12,     4,  <-14,     2,     3,    14,     2,  <-15    ; age 15, r 14.5
              .byte    14,     7,  <-11,   <-8,  <-15,     9,     5,   <-8
              .byte    12,     4,  <-15,     3,     3,    15,     2,  <-15    ; age 16, r 14.8
              .byte    14,     7,  <-11,   <-8,  <-15,     9,     5,   <-9
              .byte    12,     4,  <-15,     3,     3,    15,     2,  <-16    ; age 17, r 15.1
              .byte    15,     7,  <-11,   <-8,  <-16,    10,     5,   <-9
              .byte    12,     4,  <-15,     3,     3,    15,     2,  <-16    ; age 18, r 15.4
              .byte    15,     7,  <-12,   <-8,  <-16,    10,     5,   <-9
              .byte    12,     4,  <-15,     3,     3,    15,     2,  <-16    ; age 19, r 15.6
              .byte    15,     7,  <-12,   <-9,  <-16,    10,     6,   <-9
              .byte    13,     4,  <-16,     3,     3,    16,     2,  <-17    ; age 20, r 15.8
              .byte    15,     8,  <-12,   <-9,  <-16,    10,     6,   <-9
              .byte    13,     4,  <-16,     3,     3,    16,     2,  <-17    ; age 21, r 15.9
              .byte    15,     8,  <-12,   <-9,  <-16,    10,     6,   <-9
              .byte    13,     4,  <-16,     3,     3,    16,     2,  <-17    ; age 22, r 16.0
              .byte    15,     8,  <-12,   <-9,  <-16,    10,     6,   <-9
              .byte    13,     4,  <-16,     3,     3,    16,     2,  <-17    ; age 23, r 16.0
              .byte    15,     8,  <-12,   <-9,  <-17,    10,     6,   <-9

        .segment "CODE2"
