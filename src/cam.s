; =============================================================================
; cam.s - the camera frames the nearest enemy, and points at it when it cannot
; =============================================================================
; open_questions C6. Without a target the camera is exactly what do_ship always
; made it: ZOOM_RZ, SHIP_OFF and the turn lean, per tier. With one - the nearest
; enemy that has SEEN the ship (FS_PURSUE, which an adrift spider's FS_SEEN is
; too) - those are only the starting point, and the rules are:
;
;   ZOOM FIRST, AS A SERVO. No division: every frame the enemy's distance on
;   the screen at the TARGET zoom is held against the room to that edge, per
;   axis, with the ship where the tier puts it. Past the tight margin (CAM_M)
;   on either axis the target steps one ZQ_LADDER rung wider; inside the loose
;   one (CAM_M + CAM_MHYS) on both it steps one rung back in, every
;   CAM_INMASK+1 frames; between the two it holds. Out quick, in calm, and never
;   tighter than the tier or wider than ZCAP. Measured at the target and not at
;   ZOOMH, or the servo would wind up while the ease caught up.
;
;   THEN SLIDE - only once the zoom is at ZCAP. The ship moves away from the
;   enemy inside its bounds: along, CAM_SLIM down and, up, only as far as still
;   leaves CAM_F world px visible ahead; across, as a bound on the turn lean.
;   The along target is SLEWED, CAM_SSTEP px a frame, so taking, swapping or
;   losing a target never throws the ship; the tier's own moves pass straight
;   through.
;
;   THEN POINT. Whenever this target is off the screen, cam_arrow blinks ONE
;   arrow on the edge where it is, lit first on the frame it was taken.
;
; The results are TARGETS: do_ship's eases, the zoom rung quantiser, the cull
; and the star sample point all run on them unchanged. Everything here reads
; FOEST, which lives under the window, and so runs inside cart_frame's bracket -
; do_ship and do_flames both do.
;
; The code is CODE5 and runs from CART_HIRAM, $C000 (cart.cfg): the first thing
; there. Its STATE is not - it is in RAM the OS clears.
; =============================================================================

CAM_M       = 24                ; enemy centre to screen edge, px: its radius
                                ;   (18 for a UFO) and a little air
CAM_MHYS    = 16                ; ...and this much MORE margin before it zooms
                                ;   back in: a band in screen px, so an enemy
                                ;   hovering on the edge does not pump the zoom.
                                ;   Wider than one rung's step (2.2% of <400 px)
CAM_INMASK  = 3                 ; FRAME mask: a rung back in every 4 frames,
                                ;   where out is every frame
CAM_F       = 250               ; world px, at 1:1, always visible AHEAD of a
                                ;   ship that slid up (the resting screen shows
                                ;   270)
CAM_SLIM    = 126               ; the ship's along offset either way - SHIP_OFF's
                                ;   top row, which is what CULL_R admits
CAM_XLIM    = 80                ; ...and across: the turn lean's full reach,
                                ;   (CAMX_CLAMP * 32 * 107/128) >> 8
CAM_SSTEP   = 4                 ; px a frame the camera's slide may move
CAM_XMAX    = 2*FBCX - 1        ; the last full-res row and column
CAM_YMAX    = 299               ; ...and row: the screen's edge, not FBCY's

ARW_SLOT0   = FLAME_SLOT0 + FLAME_N ; the four arrows, after the flames
ARW_PAGE    = $12               ; GPU RAM page (ship $10, flames $11)
ARW_RIGHT   = 0                 ; slot order, arrows.s's order
ARW_LEFT    = 1
ARW_UP      = 2
ARW_DOWN    = 3
ARW_EDGE    = 1                 ; the tip sits this far inside the edge
ARW_CM      = 10                ; ...and this far from a corner, along it.
                                ;   Over the HUD and the radar too: the
                                ;   overlay is what makes it read on any ground
ARW_BLINK   = $08               ; blink bit: 8 frames lit, 8 dark, the respawn
                                ;   blink's rate (gameover.s ship_hidden)

        .assert CAM_F * 64 / 128 - FBCX >= -CAM_SLIM, error, "cam.s: CAM_F at the widest zoom must leave the up bound inside CAM_SLIM"
        .assert CAM_F * 127 / 128 - FBCX < 128, error, "cam.s: the up bound must fit a signed byte"
        .assert CAM_SLIM + CAM_SSTEP < 256, error, "cam.s: the slew's step must not wrap past a byte"

; --- state: $6FE2-$6FFF (the tail of the page laser.s and thrust.s share) and
;     $73A9-$73AB (behind shots.s's RKDMG) ------------------------------------
CAMT        = $6FE2             ; the target: its slot + 1, 0 = none
CAMRZ       = $6FE3             ; zoom target (Q0.7 reciprocal) do_ship eases to
CAMSOF      = $6FE4             ; SHOFF target, signed px, slewed
CAMLK       = $6FE5             ; lean bound: 0 none, 1 a floor, 2 a ceiling
CAMLB       = $6FE6             ; ...at this many px, signed
CAMK        = $6FE7             ; the servo's rung, ZQ_LADDER index: 0 = 2x out,
                                ;   32 = 1:1. $FF = no target, start afresh
ZCAP        = $6FE8             ; the widest RUNG allowed, 0 = 2x. The hook a
                                ;   performance safety net will write
CAMVL       = $6FE9             ; the target in view coords, world units, by
CAMVH       = $6FEB             ;   axis: +0 along (VY), +1 across (VX)
CAMBL       = $6FED             ; scratch from here: the nearest distance...
CAMBH       = $6FEE
CAMCL       = $6FEF             ; ...the current target's, $FFFF = not a candidate
CAMCH       = $6FF0
CAMI        = $6FF1             ; ...and the nearest's slot + 1
CAMDL       = $6FF2             ; |view coord| / 16, px at 1:1 - and 16 bits of
CAMDH       = $6FF3             ;   scratch for cam_pick and cam_arrow
CAMNL       = $6FF4             ; need = e + CAM_M - base, by axis: how far past
CAMNH       = $6FF6             ;   the room at the ship's centre the enemy is
CAMG        = $6FF8             ; bit 7: toward the fb 0 edge, by axis
CAMS0       = $6FFA             ; SHIP_OFF[ETIER]
CAMS0P      = $6FFB             ; ...last frame's, for the pass-through
CAMRT       = $6FFC             ; ZOOM_RZ[ETIER], then its rung
CAMWL       = $6FFD             ; scratch
CAMWH       = $6FFE
CAMDIR      = $6FFF             ; the axis being measured / the arrow placed
        .assert CAMT > LSRHN && CAMDIR < FLWDIR, error, "cam.s: the camera's block no longer fits between laser.s's and thrust.s's"
CAMTF       = $73A9             ; FRAME when CAMT last changed hands, so the
                                ;   arrow's blink starts LIT on ENEMY DETECTED
CAMFL       = $73AA             ; the servo's verdict: bit 0 past the tight
                                ;   margin, bit 1 not inside the loose one
CAMSD       = $73AB             ; the SHOFF the slide wants, before the slew
CAMZ        = $73AC             ; the rung's reciprocal as a Q0.7 multiplier
CAMZLAG     = $73AD             ; the shift do_ship's zoom ease uses: ZOOM_LAG,
                                ;   or ZOOM_LAG+1 on the way home from a target
                                ;   that is gone - half the pace, so an enemy
                                ;   killed on the edge is seen coming apart

        .pushseg
        .segment "CODE5"

; -----------------------------------------------------------------------------
; cam_foe - this frame's camera targets: CAMSOF, CAMRZ, CAMLK/CAMLB.
; -----------------------------------------------------------------------------
; do_ship calls it before the along ease. Clobbers everything, T0/T1 included.
; -----------------------------------------------------------------------------
cam_foe:
        ldx     ETIER
        lda     ZOOM_RZ,x
        sta     CAMRT
        lda     SHIP_OFF,x              ; (0..126: SHIP_OFF is never negative)
        sta     CAMS0
        sta     CAMSD
        sec                             ; the tier's own move goes straight into
        sbc     CAMS0P                  ;   CAMSOF: only what the camera adds on
        sta     CAMWL                   ;   top of it is slewed
        clc
        adc     CAMSOF
        bvc     :+
        lda     #CAM_SLIM
        bit     CAMWL
        bpl     :+
        lda     #<-CAM_SLIM
:       sta     CAMSOF
        lda     CAMS0
        sta     CAMS0P
        stz     CAMLK
        jsr     cam_pick
        ldx     CAMT
        bne     cf_have
        ldx     CAMK                    ; no target. Lost one this frame: the
        bmi     :+                      ;   way home runs at half the ease's
        lda     #$FF                    ;   pace, and the next target starts
        sta     CAMK                    ;   from wherever the camera is then
        lda     #ZOOM_LAG+1
        sta     CAMZLAG
:       lda     ZEASH                   ; ...until the zoom is home (or the tier
        cmp     CAMRT                   ;   has gone wider than it)
        bcc     :+
        lda     #ZOOM_LAG
        sta     CAMZLAG
:       lda     CAMRT                   ; the tier's zoom
        sta     CAMRZ
        jmp     cf_slew

cf_have:
        lda     #ZOOM_LAG
        sta     CAMZLAG
        dex
        sec                             ; the wrap is free: a 16-bit subtract is
        lda     FOEXL,x                 ;   the short way round
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
        jsr     view_xform
        lda     VYL
        sta     CAMVL
        lda     VYH
        sta     CAMVH
        lda     VXL
        sta     CAMVL+1
        lda     VXH
        sta     CAMVH+1

        lda     CAMRT                   ; from here CAMRT is the tier's RUNG
        jsr     cam_rung
        sta     CAMRT
        lda     CAMK
        bpl     :+
        lda     CAMRZ                   ; a new target: start from the zoom the
        jsr     cam_rung                ;   camera is already aiming at
:       cmp     CAMRT                   ; never tighter than the tier...
        bcc     :+
        lda     CAMRT
:       cmp     ZCAP                    ; ...nor wider than the cap
        bcs     :+
        lda     ZCAP
:       sta     CAMK

        ; ---- 1. ZOOM: the servo's verdict, per axis --------------------------
        ; e = the enemy's distance on the screen at the target rung; need = e +
        ; CAM_M - base, base the room from the ship's centre to that edge
        ; (CAM_BASE); and T = need - s', s' the ship's own place toward that edge,
        ; along only - the TIER's place, not the slid one, or the slide would
        ; talk the zoom back in. T > 0 is past the tight margin; T >= -CAM_MHYS
        ; is not yet inside the loose one.
        tax
        lda     ZQ_LADDER,x             ; the Q0.7 multiply takes 127 for 1:1,
        bpl     :+                      ;   a pixel short at most
        lda     #127
:       sta     CAMZ
        stz     CAMFL
        ldx     #$01
cm_lp:  stx     CAMDIR
        lda     CAMVL,x
        sta     MAL
        lda     CAMVH,x
        sta     MAH
        jsr     cam_absd
        jsr     cam_e
        ldx     CAMDIR
        lda     CAMVH,x                 ; toward fb 0: ahead is VY < 0, and VX > 0
        eor     CAM_FLIP,x              ;   lands toward fb-y 0 (zoom_fb)
        and     #$80
        sta     CAMG,x
        txa
        asl     a
        ldy     CAMG,x
        bmi     :+
        ora     #$01
:       tay
        sec
        lda     MAL
        sbc     CAM_BASE,y
        sta     MAL
        lda     MAH
        sbc     #$00
        sta     MAH
        clc
        lda     MAL
        adc     #CAM_M
        sta     CAMNL,x
        lda     MAH
        adc     #$00
        sta     CAMNH,x
        lda     #$00                    ; s'
        cpx     #$00
        bne     :+
        lda     CAMS0
        ldy     CAMG
        bmi     :+
        eor     #$FF
        inc     a
:       sta     CAMWL
        ldy     #$00
        ora     #$00
        bpl     :+
        dey
:       sty     CAMWH
        sec
        lda     CAMNL,x
        sbc     CAMWL
        sta     CAMWL
        lda     CAMNH,x
        sbc     CAMWH
        sta     CAMWH
        bmi     cm_tight                ; T <= 0: inside the tight margin
        ora     CAMWL
        beq     cm_tight
        lda     #$01
        tsb     CAMFL
cm_tight:
        clc
        lda     CAMWL
        adc     #CAM_MHYS
        lda     CAMWH
        adc     #$00
        bmi     cm_next                 ; T + CAM_MHYS < 0: inside the loose one
        lda     #$02
        tsb     CAMFL
cm_next:
        dex
        bmi     :+
        jmp     cm_lp
:

        lda     CAMFL                   ; OUT a rung a frame...
        lsr     a
        bcc     cz_in
        lda     CAMK
        cmp     ZCAP
        beq     cz_set
        dec     CAMK
        bra     cz_set
cz_in:  lsr     a                       ; ...IN a rung every CAM_INMASK+1, and
        bcs     cz_set                  ;   only once both axes sit inside the
        lda     FRAME                   ;   loose margin
        and     #CAM_INMASK
        bne     cz_set
        lda     CAMK
        cmp     CAMRT
        bcs     cz_set
        inc     CAMK
cz_set: ldx     CAMK
        lda     ZQ_LADDER,x
        sta     CAMRZ

        ; ---- 2. SLIDE: only at the cap, only what the zoom could not buy -----
        lda     CAMK
        cmp     ZCAP
        beq     :+
        jmp     cf_slew
:       ldx     #$00                    ; ALONG
        jsr     cam_need8
        bit     CAMG
        bpl     sl_behind
        ldx     #CAM_SLIM               ; ahead: sink by need, no lower than the
        stx     CAMWL                   ;   bound, and never above the tier's own
        jsr     cam_smin                ;   place
        ldx     CAMS0
        stx     CAMWL
        jsr     cam_smax
        sta     CAMSD
        bra     sl_across
sl_behind:
        eor     #$FF                    ; behind: rise to -need...
        inc     a
        sta     CAMDIR
        ldx     CAMK                    ; ...no higher than leaves CAM_F ahead
        lda     ZQ_LADDER,x             ;   at this zoom, F*z/128 - FBCX (a
        bpl     :+                      ;   signed byte, asserted)...
        lda     #127
:       sta     MB
        lda     #<CAM_F
        sta     MAL
        lda     #>CAM_F
        sta     MAH
        jsr     smul16q7
        lda     MAL
        sec
        sbc     #<FBCX
        ldx     CAMS0                   ; ...a ship the tier already put higher
        stx     CAMWL                   ;   than that stays where it is...
        jsr     cam_smin
        sta     CAMWL
        lda     CAMDIR
        jsr     cam_smax
        ldx     CAMS0                   ; ...and never below the tier's place
        stx     CAMWL
        jsr     cam_smin
        sta     CAMSD
sl_across:
        ldx     #$01                    ; ACROSS: a bound on the lean - a floor
        jsr     cam_need8               ;   toward fb-y 0, a ceiling the other
        sta     CAMDIR                  ;   way, at need either side
        sec
        sbc     #<-CAM_XLIM
        bvc     :+
        eor     #$80
:       bmi     cf_slew                 ; need < -XLIM: no bound at all
        lda     #CAM_XLIM
        sta     CAMWL
        lda     CAMDIR
        jsr     cam_smin
        ldx     #$01
        bit     CAMG+1
        bmi     :+
        eor     #$FF
        inc     a
        inx
:       stx     CAMLK
        sta     CAMLB

cf_slew:                                ; CAMSOF toward CAMSD, CAM_SSTEP a frame
        lda     CAMSD
        sta     CAMWL
        sec
        sbc     CAMSOF
        bvc     :+
        eor     #$80
:       bmi     sw_down
        lda     CAMSOF
        clc
        adc     #CAM_SSTEP
        bvc     :+
        lda     #$7F
:       jsr     cam_smin
        sta     CAMSOF
        rts
sw_down:
        lda     CAMSOF
        sec
        sbc     #CAM_SSTEP
        bvc     :+
        lda     #$80
:       jsr     cam_smax
        sta     CAMSOF
        rts

CAM_FLIP:   .byte   $00, $80        ; along: V < 0 is toward fb 0; across, V >= 0
CAM_BASE:   .byte   FBCX, CAM_XMAX - FBCX, FBCY, CAM_YMAX - FBCY
                                    ; [axis*2 + away]: centre to that edge

; -----------------------------------------------------------------------------
; cam_pick - CAMT = the nearest enemy that has seen the ship, slot + 1, or 0.
; -----------------------------------------------------------------------------
; The target only changes hands when the new one is nearer by a quarter: two
; enemies at much the same range would otherwise swap it every frame and the
; camera with it. foe_dist is the enemies' own distance, ~7%, no square root.
; -----------------------------------------------------------------------------
cp_none:
        stz     CAMT
        rts
cam_pick:
        lda     SHIPGONE
        bne     cp_none
        lda     #$FF
        sta     CAMBL
        sta     CAMBH
        sta     CAMCL
        sta     CAMCH
        stz     CAMI
        lda     NFOE
        beq     cp_none
        dec     a
        sta     FEI
cp_lp:  ldx     FEI
        lda     FOEST,x
        cmp     #FS_PURSUE
        bne     cp_nx
        jsr     foe_dist
        ldx     FEI
        inx
        cpx     CAMT
        bne     :+
        lda     FEDL
        sta     CAMCL
        lda     FEDH
        sta     CAMCH
:       lda     FEDL
        cmp     CAMBL
        lda     FEDH
        sbc     CAMBH
        bcs     cp_nx
        lda     FEDL
        sta     CAMBL
        lda     FEDH
        sta     CAMBH
        stx     CAMI
cp_nx:  dec     FEI
        bpl     cp_lp
        lda     CAMI
        beq     cp_none
        lda     CAMCL                   ; the current one is not a candidate
        and     CAMCH                   ;   any more: take the nearest
        cmp     #$FF
        beq     cp_take
        lda     CAMBH                   ; W = nearest + nearest/4
        lsr     a
        sta     CAMDH
        lda     CAMBL
        ror     a
        lsr     CAMDH
        ror     a
        clc
        adc     CAMBL
        sta     CAMDL
        lda     CAMDH
        adc     CAMBH
        sta     CAMDH
        lda     CAMDL                   ; current <= W: keep it
        cmp     CAMCL
        lda     CAMDH
        sbc     CAMCH
        bcs     cp_keep
cp_take:
        lda     CAMI
        cmp     CAMT
        beq     cp_keep
        sta     CAMT
        lda     FRAME
        sta     CAMTF
cp_keep:
        rts

; cam_rung - A = a zoom reciprocal -> A = the widest ZQ_LADDER rung not
; tighter than it. From the 1:1 end, where the camera spends most of its time.
cam_rung:
        ldx     #32
:       cmp     ZQ_LADDER,x
        bcs     :+
        dex
        bne     :-
:       txa
        rts

; cam_absd - CAMD = |MA| / 16: world units to px at 1:1. Clobbers MA.
cam_absd:
        lda     MAH
        bpl     :+
        sec
        lda     #$00
        sbc     MAL
        sta     MAL
        lda     #$00
        sbc     MAH
        sta     MAH
:       ldx     #4
:       lsr     MAH
        ror     MAL
        dex
        bne     :-
        lda     MAL
        sta     CAMDL
        lda     MAH
        sta     CAMDH
        rts

; cam_e - MA = CAMD * CAMZ / 128.
cam_e:
        lda     CAMDL
        sta     MAL
        lda     CAMDH
        sta     MAH
        lda     CAMZ
        sta     MB
        jmp     smul16q7

; cam_need8 - X = axis -> A = its need, saturated to -127..127 (so it negates).
cam_need8:
        lda     CAMNH,x
        beq     n8_pos
        cmp     #$FF
        beq     n8_neg
        asl     a
        lda     #$7F
        bcc     :+
        lda     #$81
:       rts
n8_pos: lda     CAMNL,x
        bpl     :+
        lda     #$7F
:       rts
n8_neg: lda     CAMNL,x
        cmp     #$81
        bcs     :+
        lda     #$81
:       rts

; cam_smin / cam_smax - A = the signed min / max of A and CAMWL. Uses CAMWH.
cam_smin:
        sta     CAMWH
        sec
        sbc     CAMWL
        bvc     :+
        eor     #$80
:       bmi     :+
        lda     CAMWL
        rts
:       lda     CAMWH
        rts
cam_smax:
        sta     CAMWH
        sec
        sbc     CAMWL
        bvc     :+
        eor     #$80
:       bpl     :+
        lda     CAMWL
        rts
:       lda     CAMWH
        rts

; -----------------------------------------------------------------------------
; cam_lean - MAL/MAH = do_ship's lean target, 8.8 px: held to CAMLK's bound.
; -----------------------------------------------------------------------------
; A bound and not a replacement: a turn that already leans the way the enemy
; needs keeps its lean, and one that leans the other way gives it up.
; -----------------------------------------------------------------------------
cam_lean:
        lda     CAMLK
        beq     cl_done
        lsr     a                       ; 1 -> C set, a floor; 2 -> a ceiling
        lda     MAH
        bcc     cl_ceil
        sec
        sbc     CAMLB
        bvc     :+
        eor     #$80
:       bpl     cl_done                 ; already at or over the floor
        bmi     cl_set
cl_ceil:
        sec
        sbc     CAMLB
        bvc     :+
        eor     #$80
:       bmi     cl_done                 ; already under the ceiling
cl_set: lda     CAMLB
        sta     MAH
        stz     MAL
cl_done:
        rts

; -----------------------------------------------------------------------------
; cam_arrow - the blinking arrow on the edge, while the target is off the screen.
; -----------------------------------------------------------------------------
; Where the enemy IS on the screen - zoom_fb, with this frame's eased zoom,
; slide, lean and shake - clamped onto the screen: the clamp is the whole test
; (nothing clamped, nothing to point at), the edge it clamped to picks the arrow
; (top or bottom wins a corner), and the tip goes to that edge, level with the
; enemy along it and a corner's worth clear of the ends, so the arrow is always
; whole. After do_flames, so the ship's own place is final.
; -----------------------------------------------------------------------------
ar_skip:
        rts
cam_arrow:
        lda     CAMT
        beq     ar_skip
        lda     FRAME                   ; the blink counts from the frame the
        sec                             ;   target was taken, lit first - it
        sbc     CAMTF                   ;   is ENEMY DETECTED's arrow
        and     #ARW_BLINK
        bne     ar_skip
        jsr     ship_hidden             ; no ship drawn, nothing to point from
        bcs     ar_skip
        lda     CAMVL+1
        sta     VXL
        lda     CAMVH+1
        sta     VXH
        lda     CAMVL
        sta     VYL
        lda     CAMVH
        sta     VYH
        jsr     zoom_fb
        ldx     #FYL - FXL              ; across: 0 on, 1 past fb-y 0 (RIGHT),
        jsr     arw_clamp               ;   2 past fb-y 299 (LEFT)
        sta     CAMG+1
        ldx     #$00                    ; along: 1 past the top (UP), 2 the
        jsr     arw_clamp               ;   bottom (DOWN) - and it wins a
        beq     :+                      ;   corner, whole on the screen
        inc     a
        bra     ar_put
:       lda     CAMG+1
        bne     :+
        rts                             ; on the screen: no arrow
:       dec     a
ar_put: tax                             ; both coordinates are on the screen now,
        sec                             ;   the edge one at ARW_CM in from it:
        lda     FXL                     ;   top-left = there - the tip, which
        sbc     ARW_TX,x                ;   ARW_TX/TY already carry that inset
        sta     OS_ARG+1
        lda     FXH
        sbc     #$00
        sta     OS_ARG+2
        sec
        lda     FYL
        sbc     ARW_TY,x
        sta     OS_ARG+3
        lda     FYH
        sbc     #$00
        sta     OS_ARG+4
        txa
        clc
        adc     #ARW_SLOT0
        sta     OS_ARG+0
        jmp     API_GPU_SPRITE

; arw_clamp - X = 0 (FX) or 2 (FY): the coordinate into ARW_CM..max-ARW_CM, and
; A = 0 if it was on the screen, 1 past its low edge, 2 past its high one.
arw_clamp:
        ldy     #$01
        lda     FXH,x
        bmi     ac_lo                   ; past the low edge
        dey
        lda     FXL,x
        cmp     #ARW_CM
        lda     FXH,x
        sbc     #$00
        bcc     ac_lo                   ; on it, inside the corner margin
        ldy     #$02
        lda     ARW_MAX,x
        cmp     FXL,x
        lda     ARW_MAX+1,x
        sbc     FXH,x
        bcc     ac_hi                   ; past the high edge
        ldy     #$00
        lda     ARW_HI,x
        cmp     FXL,x
        lda     ARW_HI+1,x
        sbc     FXH,x
        bcs     ac_done                 ; on it, clear of the margin
ac_hi:  lda     ARW_HI,x
        sta     FXL,x
        lda     ARW_HI+1,x
        bra     ac_set
ac_lo:  lda     #ARW_CM
        sta     FXL,x
        lda     #$00
ac_set: sta     FXH,x
ac_done:
        tya
        rts

; -----------------------------------------------------------------------------
; upload_art_step - the flames' five LOAD pages, then the arrows' one.
; -----------------------------------------------------------------------------
upload_art_step:
        lda     FLSTEP
        cmp     #$05
        bcs     :+
        jmp     upload_flames_step
:       inc     FLSTEP
        lda     #ARW_PAGE
        sta     OS_ARG+0
        lda     #<arrows_data
        sta     OS_ARG+1
        lda     #>arrows_data
        sta     OS_ARG+2
        jmp     API_GPU_LOAD

; arrow_defs - X = the definition page upload_flames_step is staging (0 TYPE,
; 1 PTR_LSB, 2 PTR_MSB, 3 HEIGHT): the arrows' four slots into DEFPG. Keeps X.
arrow_defs:
        phx
        txa
        asl     a
        asl     a
        tax
        ldy     #$00
:       lda     ARW_DEF,x
        sta     DEFPG+ARW_SLOT0,y
        inx
        iny
        cpy     #$04
        bne     :-
        plx
        rts

ARW_DEF:
        .byte   ARW_RIGHT_TYPE, ARW_LEFT_TYPE, ARW_UP_TYPE, ARW_DOWN_TYPE
        .byte   ARW_RIGHT_OFFSET, ARW_LEFT_OFFSET, ARW_UP_OFFSET, ARW_DOWN_OFFSET
        .byte   ARW_PAGE, ARW_PAGE, ARW_PAGE, ARW_PAGE
        .byte   ARW_RIGHT_HEIGHT, ARW_LEFT_HEIGHT, ARW_UP_HEIGHT, ARW_DOWN_HEIGHT
; The tip inside each sprite, and on the axis the arrow points along, the
; distance from ARW_CM (where arw_clamp leaves that coordinate) to ARW_EDGE
; folded in - so one subtraction puts the tip ARW_EDGE in from the edge.
ARW_TX: .byte   ARW_RIGHT_TX, ARW_LEFT_TX
        .byte   ARW_UP_TX + ARW_CM - ARW_EDGE, ARW_DOWN_TX - ARW_CM + ARW_EDGE
ARW_TY: .byte   ARW_RIGHT_TY + ARW_CM - ARW_EDGE, ARW_LEFT_TY - ARW_CM + ARW_EDGE
        .byte   ARW_UP_TY, ARW_DOWN_TY
ARW_MAX:.word   CAM_XMAX, CAM_YMAX      ; by arw_clamp's X: 0 along, 2 across
ARW_HI: .word   CAM_XMAX - ARW_CM, CAM_YMAX - ARW_CM
        .assert ARW_DOWN_TX + ARW_EDGE >= ARW_CM && ARW_LEFT_TY + ARW_EDGE >= ARW_CM, error, "cam.s: an arrow's tip sits closer to its edge than ARW_CM - ARW_EDGE"
        .assert FXH = FXL + 1 && FYL = FXL + 2 && FYH = FXL + 3, error, "cam.s: arw_clamp indexes FX/FY as one block"

        .include "arrows.s"             ; the art - GENERATED, tools/arrowgen.py

        .popseg
