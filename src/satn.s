; =============================================================================
; satn.s - Saturnium: the drifting pool, the counter, the hull's spark ring
; =============================================================================
; open_questions F7, stages 1 and 2.
;
; THE POOL (stage 1). SATP_N lightweight objects that home on the ship: a world
; position, a velocity and a tag. They are not rocks - not in NOBJ, not in the
; sector grid, no collision, no mass - so they cost one transform each and a
; free slot is simply a zero tag. Built on the near-mote layer's idea (stars.s
; do_motes: a fixed little table walked whole every frame into one DOT_PIXELS),
; with one difference: a mote drifts at a fixed rate, and these are steered.
;
; THE STEERING. Each object keeps its own velocity RELATIVE TO THE SHIP (one
; signed byte an axis, world units a frame), born at zero. Every frame it first
; takes the ship's own step (the integer part of VELX/VELY), then is pulled
; toward the ship and moves:
;
;     P += v_ship ;  d = ship - P ;  p = d >> SATP_ACC
;     v += p  (+ the SWIRL, (-p.y, p.x) or its mirror, for SATP_SWIRL frames)
;     v clamped to SATP_VMAX ;  P += v
;
; THE SWIRL is what makes the cloud swim instead of flying in on rails. For its
; first SATP_SWIRL frames a mote is also pushed ACROSS the line to the ship, by
; the same p turned a quarter - so it costs no shift and no multiply beyond the
; pull's own, just two adds. Even slots turn one way and odd slots the other, so
; a kill's cloud opens into two counter-rotating streams that curl in. Measured
; on the model: paths bow 12-38 px off the straight line, and land in 19-28
; frames.
;
; THEN IT MUST LAND. Once the swirl is over, an axis whose velocity would carry
; the mote AWAY from the ship is stopped dead. Without that the pull is an
; undamped spring - the short axis overshoots and swings for ever, the arrival
; box never catches both axes at once, and the mote orbits the ship (the first
; accelerating cut did exactly that in flight). With it every axis only ever
; closes. Seen from the ship all of this is exact whatever the ship is doing,
; since the ship's step is taken first; d is a 16-bit subtract read as signed,
; so the wrap is free, and a teleport is simply chased.
;
; ARRIVAL is a box, |dx| and |dy| both under SATP_ARR, tested before the step.
; What arrived is told by the TAG: bits 7-6 of the slot byte are what it is
; (SPT_SATN, a Saturnium mote; SPT_LASER / SPT_SHIELD, pickup.s's), bits 5-0
; its age, saturating. A zero byte is a free slot, which is why no tag is 00.
; A landing pulses the ring out past its outer radius for a frame; the FIRST landing of a cloud
; also sounds the whoosh (SE_SATN), and SATWC holds it off for the length of
; the sound so the rest of the cloud does not restart it every frame.
;
; OVERFLOW DROPS, silently, like VIS_MAX and PPRAM: a kill that finds the pool
; full spawns what fits and loses the rest. The Saturnium was already paid.
;
; THE COUNTER (stage 2). SATN, 0..SATN_MAX. A killing blow on the smallest class
; pays SATN_ADD once, clamped (satn_kill, from shots.s rock_destroy). It is
; spent through satn_spend, which refuses outright when there is too little: a
; teleport costs SATN_TP_COST (satn_teleport, from ship.s) and a laser beam
; SATN_LSR_COST (laser.s lsr_fire).
; A class-4 kill's puff becomes the motes: the puff the hit already threw is
; taken off, and EXPL_DOTS_N objects start on a ring round the rock instead.
; A mote's ARRIVAL pays nothing - it is the feedback.
;
; THE RING is the readout: sparks spread round the WHOLE circle about the
; ship's drawn centre, each one flying outward from SATR_R0 to SATR_R1 half-res
; px over SATR_LIFE frames AND sliding one direction round the circle a frame -
; even slots one way, odd slots the other - then reborn somewhere else. So each
; spark draws a short spiral, and the ones going opposite ways cross: no fixed
; radial streaks and no gaps between them. The charge sets how MANY are alive
; (SATR_CNT, by tier). The positions come out of a TABLE, and only a QUARTER
; of one: SATR_C holds r*cos for the 17 directions of the first quadrant at each
; of the 4 radius steps - 68 bytes - and satr_pos folds the other three
; quadrants out of it by swapping the axes and flipping signs. The full 4 x 64
; table for both axes was 512 bytes of CART_HIRAM, which is RAM the code wants.
; So a spark is two table reads, a swap and a negate or two: no multiply, no
; rotation (the ship is always nose-up, 11.27). When the camera is zoomed out
; past SATR_ZBIG the ring is taken to three quarters, one shift, so it stays
; round the smaller hull.
;
; FULL. At SATN_FULL and over, every SATR_FLASH frames the ring throws a flash
; for two frames: SATR_RAYS short LINE16 rays across it, at a heading that moves
; on each time. BRIMMING, at SATN_MAX itself, a lone extra ray flickers in the
; gaps as well, SATR_BRIM times as often, one frame each.
;
; THE LADDER, SATN -> the ring:
;       0           nothing
;       1 - 7       2 sparks                    (the laser needs 8)
;       8 - 49      4 sparks                    (laser)
;      50 - 99      8 sparks                    (+ teleport)
;     100 - 149     10 sparks
;     150 - 199     14 sparks
;     200 - 254     18 sparks + a 3-ray flash for 2 frames every 32
;     255           ...and a lone ray for 1 frame every 4 between them
;
; ARMOUR. The hold also soaks up damage: every cost to the hull (physics.s
; ship_hurt - rams, bullets, the pulsar's beam) is scaled by the charge, in
; steps rather than smoothly. The step is SATN >> 6, and the full hold is one
; more:
;       SATN   0 -  63     pays 8/8     (a hit of 10 costs 10)
;             64 - 127          7/8                         9 (8.75)
;            128 - 191          6/8                         8 (7.5)
;            192 - 254          5/8                         6 (6.25)
;            255                4/8 - half                  5
; It is worked in EIGHTHS with the remainder carried to the next hit
; (SATARM), so nothing is lost to rounding: the pulsar's beam costs 1 a frame,
; which a plain halving would round to 0 or leave at 1, and at 255 it costs
; exactly one frame in two. Nothing is spent: the armour is the charge being
; there. (The shield divides what is left by 4 on top of this - shield.s.)
;
; RAM: under the cartridge window, $9600 up, behind foes.s's block. Everything
; that touches it runs inside cart_frame's win_off bracket - do_shots/do_foes
; (the kill), do_ship (the teleport), game_start, and do_satn - and the dot
; buffer is read by DOT_PIXELS on the spot, not later.
; =============================================================================

; --- tunables -----------------------------------------------------------------
SATP_N      = 16                ; pool capacity: two class-4 kills' clouds in
                                ;   flight at once (EXPL_DOTS_N each). A cloud
                                ;   is home in ~0.4 s, so a third kill that fast
                                ;   is a laser sweep through debris - and what it
                                ;   loses is only feedback
SATP_ARR    = 192               ; arrival box, world units a side-half: 12
                                ;   full-res px at 1:1 - inside the hull
SATP_AGE    = $3F               ; the age field of the slot byte
SPT_SATN    = $40               ; tags. Never $00: that is a free slot
SPT_LASER   = $80               ;   ...and the pickups (pickup.s): bit 7 set,
SPT_SHIELD  = $C0               ;   drawn as a sprite by pk_draw
SPT_MASK    = $C0
SATP_ACC    = 7                 ; the pull is d >> this: 9 units/frame^2 from
                                ;   80 px away, and it fades as the mote closes
SATP_VMAX   = 63                ; the speed cap, world units a frame per axis -
                                ;   4 full-res px at 1:1
SATP_SWIRL  = 12                ; frames of sideways push before the mote
                                ;   commits to landing

SATN_MAX    = $FF               ; the counter's ceiling: the whole byte. An add
                                ;   that carries out of it is clamped here
SATN_ADD    = 8                 ; a class-4 killing blow, once per kill
SATN_TP_COST = 50               ; a teleport
SATN_LSR_COST = 8               ; a laser beam - one press, all LSR_FRAMES of it
SATN_FULL   = 200               ; ...and "full": the ring flashes

SATR_N      = 18                ; ring spark slots, at the most
SATR_DIRS   = 64                ; directions round the circle
SATR_LIFE   = 4                 ; frames a spark flies before it is reborn -
                                ;   one per radius step, SATR_R0 -> SATR_R1
SATR_R0     = 18                ; its radius at birth, half-res px (36 full-
SATR_R1     = 21                ;   res)... and at the end, 42 - SATR_C says
                                ;   so, and is what to regenerate
SATR_STEP   = 23                ; how far round a reborn spark jumps, plus up to
                                ;   15 more from the frame counter
SATR_ZBIG   = 96                ; ZEASH under this and the ring is 3/4 size
SATR_FLASH  = 32                ; FULL: a flash every this many frames...
SATR_RAYS   = 3                 ; ...of this many rays...
SATR_RAYGAP = 21                ; ...this many directions apart
SATR_BRIM   = 8                 ; at SATN_MAX, a lone ray this many times per
                                ;   SATR_FLASH, in the gaps between flashes

; --- state, UNDER THE CARTRIDGE WINDOW ($9600-$96E8) ---------------------------
SATPT       = $9600             ; SATP_N: tag | age, 0 = free
SATPXL      = $9610             ; SATP_N: world position, whole units
SATPXH      = $9620
SATPYL      = $9630
SATPYH      = $9640
SATPVX      = $9650             ; SATP_N: velocity relative to the ship,
SATPVY      = $9660             ;   signed, world units a frame
SATRS       = $9670             ; SATR_N: a spark - direction << 2 | age
SATN        = $9688             ; the Saturnium the ship holds, 0..SATN_MAX
SATHMP      = $9689             ; frames of arrival pulse left
SATI        = $968A             ; the walk's slot
SATDI       = $968B             ; write cursor into SATBUF, bytes
SATDXL      = $968C             ; ship - object, signed 16 - and, in satn_kill,
SATDXH      = $968D             ;   the dying rock's position
SATDYL      = $968E             ;   (satp_near and satp_accel index these
SATDYH      = $968F             ;   four as a block)
SATTXL      = $9690             ; the swirl's copy of the pull's x
SATTXH      = $9691
SATSW       = $9692             ; nonzero while this mote still swirls
SATSG       = $9693             ; a sign, or a high byte, over one call
SATHX       = $9694             ; the ship's half-res centre - or a clip scratch
SATHY       = $9695
SATCL       = $9696             ; 16-bit scratch, and a LINE16 end's centre
SATCH       = $9697
SATCNT      = $9698             ; sparks alive at this charge
SATOX       = $9699             ; this spark's offset, half-res
SATOY       = $969A
SATJ        = $969B             ; the ray being drawn
SATWC       = $969C             ; frames before the whoosh may sound again
SATRD       = $969D             ; the flash's first ray direction
SATHEX      = $969E             ; DBG_SATN: "SN hh", NUL - 6 bytes
SATBUF      = $96A4             ; 1 + 2*(SATP_N + SATR_N): ONE DOT_PIXELS
SATRN       = SATBUF + 1 + 2 * (SATP_N + SATR_N) ; rays in this flash
SATARM      = SATRN + 1         ; armour: the eighths of a hit point carried
SATAC       = SATRN + 2         ;   to the next hit, and this hit's cost
SATP_END    = SATRN + 3
        .assert SATPT > FECAR, error, "satn.s: the pool runs into foes.s's state"
        .assert SATN_MAX = $FF, error, "satn.s: satn_kill clamps on the carry out of the byte"
        .assert SATP_N <= 16, error, "satn.s: SATP_N outgrew its 16-byte arrays"
        .assert SATRS + SATR_N <= SATN, error, "satn.s: SATRS runs into SATN"
        .assert SATP_END <= $A000, error, "satn.s: past the RAM under the window"
        .assert SATP_VMAX * 3 <= SATP_ARR && SATP_VMAX < 128, error, "satn.s: SATP_VMAX could step over the arrival box"
        .assert SATR_LIFE = 4 && SATR_DIRS = 64, error, "satn.s: the ring tables are 4 radii x 64 directions, packed dir << 2 | age"

        .pushseg
        .segment "CODE5"

; -----------------------------------------------------------------------------
; do_satn - once a frame, after do_debris (FLCX/FLCY are this frame's) and
; inside the bracket. Steer, collect and place the pool; then the ring; then
; one DOT_PIXELS for both.
; -----------------------------------------------------------------------------
do_satn:
        jsr     pk_tick                 ; the pickups' animation clock
        stz     SATDI
        lda     SATWC
        beq     :+
        dec     SATWC
:       lda     SHIPGONE
        beq     @fly
        ldx     #SATP_N-1               ; nothing left to collect it: the pool
@clr:   stz     SATPT,x                 ;   empties
        dex
        bpl     @clr
        jmp     @emit

@fly:   ldx     #SATP_N-1
@lp:    lda     SATPT,x
        bne     @live
        jmp     @next
@live:  stx     SATI
        clc                             ; the ship's own step, first
        lda     SATPXL,x
        adc     VELXH
        sta     SATPXL,x
        lda     SATPXH,x
        adc     VELXT
        sta     SATPXH,x
        clc
        lda     SATPYL,x
        adc     VELYH
        sta     SATPYL,x
        lda     SATPYH,x
        adc     VELYT
        sta     SATPYH,x
        sec                             ; d = ship - object, signed: the wrap
        lda     SHXL                    ;   is free
        sbc     SATPXL,x
        sta     SATDXL
        lda     SHXH
        sbc     SATPXH,x
        sta     SATDXH
        sec
        lda     SHYL
        sbc     SATPYL,x
        sta     SATDYL
        lda     SHYH
        sbc     SATPYH,x
        sta     SATDYH

        ldy     #$00                    ; arrived?
        jsr     satp_near
        bcs     @step
        ldy     #$02
        jsr     satp_near
        bcs     @step
        lda     SATPT,x
        stz     SATPT,x
        jsr     satp_arrive
        jmp     @nextx

@step:  stz     SATSW
        lda     SATPT,x                 ; one frame older, saturating
        and     #SATP_AGE
        cmp     #SATP_SWIRL
        bcs     :+
        inc     SATSW                   ; young: it still swirls
:       cmp     #SATP_AGE
        beq     :+
        inc     SATPT,x
:       ldy     #SATP_ACC               ; the pull: d >> SATP_ACC, arithmetic
@sh:    lda     SATDXH
        cmp     #$80
        ror     SATDXH
        ror     SATDXL
        lda     SATDYH
        cmp     #$80
        ror     SATDYH
        ror     SATDYL
        dey
        bne     @sh

        lda     SATSW                   ; the swirl: the pull turned a quarter,
        beq     @pull                   ;   added - even slots one way, odd
        lda     SATDXL                  ;   slots the other
        sta     SATTXL
        lda     SATDXH
        sta     SATTXH
        txa
        lsr     a
        bcs     @odd
        sec                             ; px -= py ; py += px
        lda     SATDXL
        sbc     SATDYL
        sta     SATDXL
        lda     SATDXH
        sbc     SATDYH
        sta     SATDXH
        clc
        lda     SATDYL
        adc     SATTXL
        sta     SATDYL
        lda     SATDYH
        adc     SATTXH
        sta     SATDYH
        bra     @pull
@odd:   clc                             ; px += py ; py -= px
        lda     SATDXL
        adc     SATDYL
        sta     SATDXL
        lda     SATDXH
        adc     SATDYH
        sta     SATDXH
        sec
        lda     SATDYL
        sbc     SATTXL
        sta     SATDYL
        lda     SATDYH
        sbc     SATTXH
        sta     SATDYH

@pull:  ldy     #$00                    ; v += it, clamped
        jsr     satp_accel
        ldy     #$02
        jsr     satp_accel
        ldy     #$00                    ; P += v
        lda     SATPVX,x
        bpl     :+
        dey
:       clc
        adc     SATPXL,x
        sta     SATPXL,x
        tya
        adc     SATPXH,x
        sta     SATPXH,x
        ldy     #$00
        lda     SATPVY,x
        bpl     :+
        dey
:       clc
        adc     SATPYL,x
        sta     SATPYL,x
        tya
        adc     SATPYH,x
        sta     SATPYH,x

        sec                             ; ...and to the screen, by the road a
        lda     SATPXL,x                ;   puff's anchor takes (expl_one)
        sbc     SHXL
        sta     PXL
        lda     SATPXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     SATPYL,x
        sbc     SHYL
        sta     PYL
        lda     SATPYH,x
        sbc     SHYH
        sta     PYH
        jsr     view_xform
        jsr     zoom_fb
        ldx     SATI                    ; a pickup is a sprite (pickup.s)
        lda     SATPT,x
        bpl     :+
        jsr     pk_draw
        bra     @nextx
:       lda     FXH                     ; half-res, and on the screen or not
        cmp     #$80                    ;   drawn at all
        ror     a
        bne     @nextx
        lda     FXL
        ror     a
        cmp     #200
        bcs     @nextx
        sta     SATHX
        lda     FYH
        cmp     #$80
        ror     a
        bne     @nextx
        lda     FYL
        ror     a
        cmp     #150
        bcs     @nextx
        ldy     SATDI
        sta     SATBUF+2,y
        lda     SATHX
        sta     SATBUF+1,y
        iny
        iny
        sty     SATDI
@nextx: ldx     SATI
@next:  dex
        bmi     @ring
        jmp     @lp

        ; ---- the ring -------------------------------------------------------
@ring:  jsr     ship_hidden             ; no hull drawn, no ring round it
        bcc     :+
        jmp     @emit
:       lda     SATN
        bne     :+
        jmp     @emit
:       ldy     #$00                    ; the tier: how many thresholds it clears
@tl:    cmp     SATR_TIER,y
        bcc     @tier
        iny
        cpy     #SATR_TIER_N
        bne     @tl
@tier:  lda     SATR_CNT,y
        sta     SATCNT

        lda     FLCXH                   ; the drawn centre, half-res. Always on
        lsr     a                       ;   the screen, so a byte
        lda     FLCXL
        ror     a
        sta     SATHX
        lda     FLCYH
        lsr     a
        lda     FLCYL
        ror     a
        sta     SATHY

        ldx     #$00
@rs:    stx     SATI
        lda     SATRS,x                 ; age on, or reborn round the circle
        and     #SATR_LIFE-1
        cmp     #SATR_LIFE-1
        bcc     @older
        lda     SATRS,x                 ; direction + SATR_STEP + 0..15
        lsr     a
        lsr     a
        clc
        adc     #SATR_STEP
        sta     SATOX
        lda     FRAME
        and     #$0F
        clc
        adc     SATOX
        asl     a                       ; << 2 with age 0 - and the shift out
        asl     a                       ;   of the top is the mod 64
        sta     SATRS,x
        bra     @place
@older: txa                             ; one frame older AND one direction on
        lsr     a                       ;   round the circle: +1 age with +1
        lda     SATRS,x                 ;   direction (even slots) or -1 (odd),
        bcs     :+                      ;   in one add - the direction is the
        adc     #4+1                    ;   top six bits. Carry is clear on
        bra     @aged                   ;   both paths
:       clc
        adc     #<(-4+1)
@aged:  sta     SATRS,x
@place: lda     SATRS,x                 ; dir << 2 | age -> age << 6 | dir, the
        lsr     a                       ;   table index: rotate right twice
        bcc     :+
        ora     #$80
:       lsr     a
        bcc     :+
        ora     #$80
:       ldy     SATHMP                  ; a mote just landed: the whole ring
        beq     :+                      ;   at its outer radius, and past it
        ora     #(SATR_LIFE-1) << 6
:       jsr     satr_pos
        lda     SATOX
        jsr     satr_pulse
        jsr     satr_zoom
        sta     SATSG
        clc
        adc     SATHX
        jsr     satp_clip
        bcs     @rn
        cmp     #200
        bcs     @rn
        sta     SATCL
        lda     SATOY
        jsr     satr_pulse
        jsr     satr_zoom
        sta     SATSG
        clc
        adc     SATHY
        jsr     satp_clip
        bcs     @rn
        cmp     #150
        bcs     @rn
        ldy     SATDI
        sta     SATBUF+2,y
        lda     SATCL
        sta     SATBUF+1,y
        iny
        iny
        sty     SATDI
@rn:    ldx     SATI
        inx
        cpx     SATCNT
        beq     :+
        jmp     @rs
:
        lda     SATHMP
        beq     :+
        dec     SATHMP

        ; ---- FULL: a two-frame flash of rays --------------------------------
:       lda     SATN
        cmp     #SATN_FULL
        bcc     @emit
        lda     FRAME
        and     #SATR_FLASH-1
        cmp     #$02
        bcs     @brim
        lda     FRAME                   ; the heading moves on every flash
        lsr     a
        lsr     a
        and     #SATR_DIRS-1
        sta     SATRD
        lda     #SATR_RAYS
        bra     @rays

        ; ---- ...and brimming, at SATN_MAX: one more ray, SATR_BRIM times as
        ; often - a single frame half-way between every two of the above
@brim:  lda     SATN
        cmp     #SATN_MAX
        bne     @emit
        lda     FRAME
        and     #SATR_FLASH/SATR_BRIM-1
        cmp     #SATR_FLASH/SATR_BRIM/2
        bne     @emit
        lda     FRAME                   ; heading 5 * FRAME: never the same one
        asl     a                       ;   twice running
        asl     a
        adc     FRAME
        and     #SATR_DIRS-1
        sta     SATRD
        lda     #1
@rays:  sta     SATRN
        stz     SATJ
@ray:   lda     SATRD                   ; inner end on the ring's start radius,
        ldx     #0                      ;   outer end SATR_RAYOUT past its end
        ldy     #$00
        jsr     satr_end
        lda     SATRD
        ldx     #(SATR_LIFE-1) << 6
        ldy     #$04
        jsr     satr_end
        jsr     API_GPU_LINE16
        lda     SATRD
        clc
        adc     #SATR_RAYGAP
        and     #SATR_DIRS-1
        sta     SATRD
        inc     SATJ
        lda     SATJ
        cmp     SATRN
        bne     @ray

@emit:
.if DBG_SATN
        ; TEMPORARY - SATN in hex on the IMAGE text layer (not the background:
        ; see hud_game.s DBG_CLASSES for why), redrawn every frame. BEFORE the
        ; dots: the frame must end in one unbroken run of DOT_PIXELS (main.s).
        lda     #'S'
        sta     SATHEX
        lda     #'N'
        sta     SATHEX+1
        lda     #' '
        sta     SATHEX+2
        lda     SATN
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     satp_hex
        sta     SATHEX+3
        lda     SATN
        and     #$0F
        jsr     satp_hex
        sta     SATHEX+4
        stz     SATHEX+5
        lda     #DBG_SATN_CELL
        sta     OS_ARG+0
        lda     #DBG_SATN_ROW
        sta     OS_ARG+1
        stz     OS_ARG+2
        lda     #<SATHEX
        sta     OS_ARG+3
        lda     #>SATHEX
        sta     OS_ARG+4
        jsr     API_GPU_VTEXT
.endif
        lda     SATDI
        lsr     a
        beq     @none
        sta     SATBUF
        lda     #<SATBUF
        sta     OS_ARG+0
        lda     #>SATBUF
        sta     OS_ARG+1
        jmp     API_GPU_DOTPIXELS
@none:  rts

.if DBG_SATN
satp_hex:
        cmp     #$0A
        bcc     :+
        adc     #$06
:       adc     #'0'
        rts
.endif

; A = a ring offset, half-res. Zoomed out past SATR_ZBIG it becomes 3/4 of
; itself (v - v >> 2), so the ring shrinks with the hull. Preserves X and Y.
satr_zoom:
        pha
        lda     ZEASH
        cmp     #SATR_ZBIG
        pla
        bcs     @done
        sta     SATSG
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        eor     #$FF                    ; v + ~(v >> 2) + 1 = v - v >> 2
        sec
        adc     SATSG
@done:  rts

; A = a ring offset, half-res. On a pulse frame (SATHMP) it becomes v + v >> 3,
; a ninth past the outer radius. Preserves Y; clobbers X.
satr_pulse:
        ldx     SATHMP
        beq     @done
        sta     SATSG
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        clc
        adc     SATSG
@done:  rts

; A = radius step << 6 | direction (0-63) -> SATOX, SATOY: that point of the
; ring, half-res, signed. The quadrant is the direction's top two bits and k
; its low four; a = C[k] and b = C[16-k] are the first quadrant's cos and sin,
; and the other three are the same two numbers swapped and signed:
;     quadrant 0: ( a,  b)   1: (-b,  a)   2: (-a, -b)   3: ( b, -a)
; Clobbers A, X and Y.
satr_pos:
        pha
        rol     a                       ; the radius step, out of bits 7-6
        rol     a
        rol     a
        and     #SATR_LIFE-1
        tax
        lda     SATR_BASE,x
        sta     SATOY                   ; (the step's first row, for a moment)
        pla
        pha
        and     #$0F
        tax                             ; X = k
        clc
        adc     SATOY
        tay
        lda     SATR_C,y
        pha                             ; a = C[k]
        txa
        eor     #$FF                    ; 16 - k = ~k + 17
        sec
        adc     #16
        clc
        adc     SATOY
        tay
        lda     SATR_C,y
        sta     SATOY                   ; b = C[16-k]
        pla
        sta     SATOX
        pla
        lsr     a                       ; the quadrant
        lsr     a
        lsr     a
        lsr     a
        and     #$03
        beq     @done                   ; 0: (a, b) as it stands
        cmp     #$02
        beq     @q2
        tax                             ; 1 or 3: swap first
        lda     SATOX
        ldy     SATOY
        sta     SATOY
        sty     SATOX
        cpx     #$01
        bne     @negy                   ; 3: ( b, -a)
@negx:  lda     SATOX                   ; 1: (-b,  a)
        eor     #$FF
        inc     a
        sta     SATOX
        rts
@q2:    lda     SATOX                   ; 2: (-a, -b)
        eor     #$FF
        inc     a
        sta     SATOX
@negy:  lda     SATOY
        eor     #$FF
        inc     a
        sta     SATOY
@done:  rts

; One end of a FULL ray. A = direction, X = the radius step << 6, Y = its
; OS_ARG slot: 0 for the inner end, 4 for the outer, which reaches a quarter
; further than the offset (x2.5 instead of x2 into full-res). The end is the
; drawn centre, full-res, plus that.
satr_end:
        stx     SATCL
        ora     SATCL
        phy
        jsr     satr_pos
        ply
        lda     SATOX
        jsr     satr_zoom
        jsr     @full
        clc
        lda     SATCL
        adc     FLCXL
        sta     OS_ARG,y
        lda     SATCH
        adc     FLCXH
        sta     OS_ARG+1,y
        lda     SATOY
        jsr     satr_zoom
        jsr     @full
        clc
        lda     SATCL
        adc     FLCYL
        sta     OS_ARG+2,y
        lda     SATCH
        adc     FLCYH
        sta     OS_ARG+3,y
        rts
@full:  sta     SATSG                   ; A -> SATCL/SATCH, signed 16: x2, and
        stz     SATCH                   ;   x2.5 for the outer end
        asl     a
        bpl     :+
        dec     SATCH
:       sta     SATCL
        cpy     #$04
        bne     @done
        lda     SATSG
        cmp     #$80
        ror     a
        clc
        adc     SATCL
        sta     SATCL
        lda     SATSG                   ; (the carry survives the load)
        bpl     :+
        lda     SATCH
        adc     #$FF
        sta     SATCH
        rts
:       lda     SATCH
        adc     #$00
        sta     SATCH
@done:  rts

; X = the slot (SATI), Y = 0 (x) or 2 (y): that axis's velocity += the pull in
; SATDXL/H+Y, 16-bit, clamped back to +/-SATP_VMAX - and, once the swirl is
; over (SATSW = 0), zeroed if it points away from the ship. Returns X = SATI.
satp_accel:
        lda     SATDXL,y
        sta     SATCL
        lda     SATDXH,y
        sta     SATCH
        tya
        beq     :+
        txa                             ; y: SATPVY, the next 16 bytes
        clc
        adc     #SATPVY-SATPVX
        tax
:       ldy     #$00
        lda     SATPVX,x
        bpl     :+
        dey
:       clc
        adc     SATCL
        sta     SATCL
        tya
        adc     SATCH
        bmi     @neg
        bne     @hi
        lda     SATCL
        cmp     #SATP_VMAX+1
        bcc     @done
@hi:    lda     #SATP_VMAX
        bra     @done
@neg:   cmp     #$FF
        bne     @lo
        lda     SATCL
        cmp     #<(-SATP_VMAX)
        bcs     @done
@lo:    lda     #<(-SATP_VMAX)
@done:  sta     SATCL
        lda     SATSW                   ; still swirling: it may go any way
        bne     @keep
        lda     SATCL                   ; NEVER AWAY FROM THE SHIP: a velocity
        eor     SATCH                   ;   whose sign is not the pull's is
        bpl     @keep                   ;   zeroed - see the header
        stz     SATCL
@keep:  lda     SATCL
        sta     SATPVX,x
        ldx     SATI
        rts

; Y = 0 (x) or 2 (y). Carry CLEAR if |ship - object| < SATP_ARR on that axis.
satp_near:
        lda     SATDXH,y
        beq     @pos
        cmp     #$FF
        bne     @far
        lda     SATDXL,y
        cmp     #<(-SATP_ARR+1)         ; -SATP_ARR < d < 0
        bcc     @far
        clc
        rts
@pos:   lda     SATDXL,y
        cmp     #SATP_ARR
        rts
@far:   sec
        rts

; After `clc / adc centre` with SATSG the offset: carry SET if the add left
; 0..255 - a positive offset that carried, or a negative one that borrowed.
; Preserves A, X and Y.
satp_clip:
        bit     SATSG
        bmi     @neg
        rts                             ; carry already says it
@neg:   bcc     @off
        clc
        rts
@off:   sec
        rts

; A = the arrived slot's byte. A Saturnium mote was already paid for at the
; kill: this is the feedback, and nothing else; a pickup is pk_arrive's.
; Clobbers everything.
satp_arrive:
        and     #SPT_MASK
        cmp     #SPT_SATN
        beq     :+
        jmp     pk_arrive               ; a pickup: what it is (pickup.s)
:       lda     #$01                    ; the ring breathes out for a frame
        sta     SATHMP
        lda     SATWC                   ; ...and the cloud's first landing
        bne     @done                   ;   whooshes, once
        lda     #LEN_SATN
        sta     SATWC
        lda     #SE_SATN
        jmp     sfx_fire
@done:  rts

; -----------------------------------------------------------------------------
; satn_kill - shots.s rock_destroy, on the smallest class's SUCCESS path, with
; SPL_P the rock. Pays SATN_ADD once, takes this hit's puff off, and puts the
; kill's EXPL_DOTS_N motes on a ring where the rock was. Out: X = SPL_P.
; -----------------------------------------------------------------------------
; Paid exactly when rock_score pays - a UFO's bullet (FOEKILL) pays nobody.
; The puff is the one expl_spawn put on this bullet's tip this frame: live, age
; 0, and anchored on EXT, which that spawn wrote. A laser or ram kill threw no
; puff, finds none, and still gets its motes.
; -----------------------------------------------------------------------------
satn_kill:
        lda     FOEKILL
        beq     :+
        rts                             ; X is still SPL_P: nothing ran
:       lda     SATN                    ; pay, clamped - never wrapped
        clc
        adc     #SATN_ADD
        bcc     :+
        lda     #SATN_MAX               ; carried out of the byte: full
:       sta     SATN

        ldy     #EXPL_N-1               ; this hit's puff becomes the motes
@px:    lda     EXLIVE,y
        beq     @pn
        lda     EXAGE,y
        bne     @pn
        lda     EXXL,y
        cmp     EXTXL
        bne     @pn
        lda     EXXH,y
        cmp     EXTXH
        bne     @pn
        lda     EXYL,y
        cmp     EXTYL
        bne     @pn
        lda     EXYH,y
        cmp     EXTYH
        bne     @pn
        lda     #$00
        sta     EXLIVE,y
        bra     @spawn
@pn:    dey
        bpl     @px

@spawn: ldx     SPL_P
        lda     OBJXL,x
        sta     SATDXL
        lda     OBJXH,x
        sta     SATDXH
        lda     OBJYL,x
        sta     SATDYL
        lda     OBJYH,x
        sta     SATDYH
        ldy     #SATP_N-1               ; free slots, walking down
        ldx     #$00                    ; ...and the ring
@sl:    lda     SATPT,y
        beq     @free
        dey
        bpl     @sl
        bra     @out                    ; full: the rest are dropped
@free:  lda     #SPT_SATN
        sta     SATPT,y
        lda     #$00                    ; from rest, relative to the ship
        sta     SATPVX,y
        sta     SATPVY,y
        stz     SATSG
        lda     SATP_RING,x             ; x: world units / 4
        bpl     :+
        dec     SATSG
:       asl     a
        rol     SATSG
        asl     a
        rol     SATSG
        clc
        adc     SATDXL
        sta     SATPXL,y
        lda     SATSG
        adc     SATDXH
        sta     SATPXH,y
        inx
        stz     SATSG
        lda     SATP_RING,x             ; y
        bpl     :+
        dec     SATSG
:       asl     a
        rol     SATSG
        asl     a
        rol     SATSG
        clc
        adc     SATDYL
        sta     SATPYL,y
        lda     SATSG
        adc     SATDYH
        sta     SATPYH,y
        inx
        cpx     #EXPL_DOTS_N*2
        bcc     @sl
@out:   ldx     SPL_P
        rts

; -----------------------------------------------------------------------------
; satn_teleport - ship.s do_ship, in place of do_teleport. Spend SATN_TP_COST
; and jump; below it, the gesture does nothing at all.
; -----------------------------------------------------------------------------
satn_teleport:
        lda     #SATN_TP_COST
        jsr     satn_spend
        bcc     :+
        jmp     do_teleport
:       rts

; -----------------------------------------------------------------------------
; satn_spend - A = a price. Carry SET: paid, SATN is that much lower. Carry
; CLEAR: not enough, and nothing changed - never a partial spend. The teleport
; (above) and the laser (laser.s lsr_fire) both buy through here. Preserves X.
; -----------------------------------------------------------------------------
satn_spend:
        sta     SATSG
        lda     SATN
        cmp     SATSG
        bcc     @no                     ; short: carry clear, SATN untouched
        sbc     SATSG                   ; carry is set, and stays set: no borrow
        sta     SATN
@no:    rts

; -----------------------------------------------------------------------------
; satn_armour - physics.s ship_hurt: A = a hit's cost (at most 31) -> what the
; hull pays for it, (cost * (8 - step) + the carried eighths) / 8, where step is
; SATN >> 6, or 4 when the hold is full. See ARMOUR in the header. Preserves X
; and Y; the multiply is 4 to 8 adds.
; -----------------------------------------------------------------------------
satn_armour:
        phx
        sta     SATAC
        lda     SATN
        cmp     #SATN_MAX
        beq     @full
        lsr     a                       ; the step, 0-3
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        bra     @step
@full:  lda     #4                      ; ...and 4 brimming: half
@step:  eor     #$FF                    ; 8 - step = ~step + 1 + 8 (carry set
        sec                             ;   is the +1)
        adc     #8
        tax                             ; X = eighths paid, 4..8
        lda     SATARM
@mul:   clc
        adc     SATAC
        dex
        bne     @mul
        tax
        and     #$07                    ; what does not make a whole point is
        sta     SATARM                  ;   carried
        txa
        lsr     a
        lsr     a
        lsr     a
        plx
        rts
        .assert RAM_DMG * 8 + 7 < 256 && FSH_DMG * 8 + 7 < 256, error, "satn.s: satn_armour's product is one byte - a hit of at most 31"

; -----------------------------------------------------------------------------
; satn_reset - game_start: an empty hold, an empty pool, and the ring's sparks
; spread round the circle with their ages staggered, so it never starts in step.
; -----------------------------------------------------------------------------
satn_reset:
        stz     SATN
        stz     SATARM
        stz     EMPN                    ; ...and no EMP still growing (emp.s)
        stz     SATHMP
        stz     SATWC
        ldx     #SATP_N-1
:       stz     SATPT,x
        dex
        bpl     :-
        stz     SATCL                   ; direction 23i mod 64, age i mod 4
        ldx     #$00
:       lda     SATCL
        asl     a
        asl     a
        sta     SATCH
        txa
        and     #SATR_LIFE-1
        ora     SATCH
        sta     SATRS,x
        lda     SATCL
        clc
        adc     #23
        sta     SATCL
        inx
        cpx     #SATR_N
        bne     :-
        rts

; --- tables -------------------------------------------------------------------
SATR_TIER:  .byte   SATN_LSR_COST, 50, 100, 150, SATN_FULL ; tier = thresholds cleared
SATR_TIER_N = * - SATR_TIER
SATR_CNT:   .byte   2, 4, 8, 10, 14, SATR_N     ; ...and the sparks alive at it
        .assert * - SATR_CNT = SATR_TIER_N + 1, error, "satn.s: SATR_CNT needs a row per tier"

; the kill's ring, world units / 4 - EXPL_DOTS_N (dx, dy), uneven on purpose
SATP_RING:  .byte   80, 4,  54, 50,  <-4, 72,  <-58, 46
            .byte   <-78, <-6,  <-40, <-60,  6, <-84,  60, <-44
        .assert * - SATP_RING = EXPL_DOTS_N * 2, error, "satn.s: SATP_RING is not one puff's dots"

; The spark ring: r * cos over the first quadrant, 17 directions (0-16 of
; SATR_DIRS; 16 is the quadrant's end and reads as sin's start), at each of the
; four radius steps of a spark's flight, SATR_R0 to SATR_R1. Made by:
;   [round(r*cos(k*pi/32)) for r in (18, 19, 20, 21) for k in range(17)]
SATR_QN     = SATR_DIRS / 4 + 1
SATR_C:
        .byte   18, 18, 18, 17, 17, 16, 15, 14, 13, 11, 10, 8, 7, 5, 4, 2, 0   ; r = 18
        .byte   19, 19, 19, 18, 18, 17, 16, 15, 13, 12, 11, 9, 7, 6, 4, 2, 0   ; r = 19
        .byte   20, 20, 20, 19, 18, 18, 17, 15, 14, 13, 11, 9, 8, 6, 4, 2, 0   ; r = 20
        .byte   21, 21, 21, 20, 19, 19, 17, 16, 15, 13, 12, 10, 8, 6, 4, 2, 0   ; r = 21
        .assert * - SATR_C = SATR_LIFE * SATR_QN, error, "satn.s: SATR_C is not a quarter per radius step"
SATR_BASE:  .byte   0, SATR_QN, 2 * SATR_QN, 3 * SATR_QN

        .popseg
