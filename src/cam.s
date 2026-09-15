; =============================================================================
; cam.s - the camera frames the nearest enemy, and points at it when it cannot
; =============================================================================
; open_questions C6. Without a target the camera is exactly what do_ship always
; made it: ZOOM_RZ, SHIP_OFF and the turn lean, per tier. With one - the nearest
; enemy that has SEEN the ship (FS_PURSUE, which an adrift spider's FS_SEEN is
; too) - those are only the starting point, and the rules are:
;
;   ZOOM FIRST. The zoom that fits the enemy, plus CAM_M, with the ship where
;   the tier puts it - per axis, the widest wins, and never TIGHTER than the
;   tier's own zoom: an enemy already in frame changes nothing. Floored at ZCAP.
;
;   THEN SLIDE. Only what the zoom could not buy: the ship moves away from the
;   enemy by the remainder, inside its bounds - along, S_LIM down and, up, only
;   as far as still leaves CAM_F world pixels visible ahead (which is why the
;   zoom goes first: zooming out is what makes that room); across, the lean's
;   own reach, shared with the lean and clamped as one.
;
;   THEN POINT. Whenever this target is OFF the screen, cam_arrow blinks ONE
;   arrow on the edge where it is - not only once the plan gives up (CAMOUT):
;   the camera eases, and an enemy the plan can frame is still off the screen
;   for the second it takes to get there. Only for this target.
;
; The results are TARGETS: do_ship's eases, the zoom rung quantiser, the cull
; and the star sample point all run on them unchanged. Everything here reads
; FOEST, which lives under the window, and so runs inside cart_frame's bracket -
; do_ship and do_flames both do.
;
; The code is CODE5 and runs from CART_HIRAM, $C000 (cart.cfg): the first thing
; there. Its STATE is not - it is in the $6Fxx page below, which the OS clears.
; =============================================================================

CAM_M       = 24                ; enemy centre to screen edge, px: its radius
                                ;   (18 for a UFO) and a little air
CAM_F       = 250               ; world px, at 1:1, always visible AHEAD of a
                                ;   ship that slid up (the resting screen shows
                                ;   270)
CAM_MHYS    = 16               ; ...and this much MORE margin before it zooms
                                ;   back in: out at CAM_M, in at CAM_M + this.
                                ;   A band in screen px, so an enemy hovering on
                                ;   the edge does not pump the zoom
ZCAP_DEF    = 64                ; the widest zoom, while ZCAP is 0. ZQ_LADDER,
                                ;   ZQ_SNAP and ZOOM_CULLR all end at 64
CAM_SLIM    = 126               ; the ship's along offset either way - SHIP_OFF's
                                ;   top row, which is what CULL_R admits
CAM_XLIM    = 80                ; ...and across: the turn lean's full reach,
                                ;   (CAMX_CLAMP * 32 * 107/128) >> 8
CAM_XMAX    = 2*FBCX - 1        ; the last full-res row and column
CAM_YMAX    = 2*FBCY + 1

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
ARW_BLINK   = $08               ; FRAME bit: 8 frames lit, 8 dark, the respawn
                                ;   blink's rate (gameover.s ship_hidden)

        .assert CAM_F * ZCAP_DEF / 128 - FBCX >= -CAM_SLIM, error, "cam.s: CAM_F at the widest zoom must leave the up bound inside CAM_SLIM"
        .assert CAM_F * 127 / 128 - FBCX < 128, error, "cam.s: the up bound must fit a signed byte"
        .assert FBCY - CAM_M - CAM_MHYS > 0 && CAM_XMAX - FBCX - CAM_SLIM - CAM_M - CAM_MHYS > 0, error, "cam.s: the room beside the ship must stay positive for cam_fit"

; --- state: $6FE2-$6FFE, the tail of the page laser.s and thrust.s share -----
CAMT        = $6FE2             ; the target: its slot + 1, 0 = none
CAMRZ       = $6FE3             ; zoom target (Q0.7 reciprocal) do_ship eases to
CAMSOF      = $6FE4             ; SHOFF target, signed px
CAMLK       = $6FE5             ; lean bound: 0 none, 1 a floor, 2 a ceiling
CAMLB       = $6FE6             ; ...at this many px, signed
CAMOUT      = $6FE7             ; 1 = the plan cannot frame it: the arrow's cue
ZCAP        = $6FE8             ; the widest zoom allowed, 0 = ZCAP_DEF. The hook
                                ;   a performance safety net will write
CAMVXL      = $6FE9             ; the target in view coords, world units
CAMVXH      = $6FEA
CAMVYL      = $6FEB
CAMVYH      = $6FEC
CAMBL       = $6FED             ; scratch from here: the nearest distance...
CAMBH       = $6FEE
CAMCL       = $6FEF             ; ...the current target's, $FFFF = not a candidate
CAMCH       = $6FF0
CAMI        = $6FF1             ; ...and the nearest's slot + 1
CAMDL       = $6FF2             ; |view coord| / 16, px at 1:1
CAMDH       = $6FF3
CAMAL       = $6FF4             ; px of room / a signed 16 on its way to a byte
CAMAH       = $6FF5
CAMQ        = $6FF6             ; cam_fit's quotient
CAMS0       = $6FF7             ; SHIP_OFF[ETIER]
CAMZ        = $6FF8             ; the zoom being worked out, then its product form
CAMRT       = $6FF9             ; ZOOM_RZ[ETIER]
CAMWL       = $6FFA             ; signed byte scratch
CAMWH       = $6FFB
CAMDIR      = $6FFC             ; the arrow being placed
CAMZI       = $6FFD             ; the zoom that fits with the WIDER margin
CAMRL       = $6FFE             ; px of room from the ship's place to the edge,
CAMRH       = $6FFF             ;   before any margin
        .assert CAMT > LSRHN && CAMRH < FLWDIR, error, "cam.s: the camera's block no longer fits between laser.s's and thrust.s's"
CAMTF       = $73A9             ; FRAME when CAMT last changed hands, so the
                                ;   arrow's blink starts LIT on ENEMY DETECTED.
                                ;   Past shots.s's RKDMG; $73AA-$73BF still free

        .pushseg
        .segment "CODE5"

; -----------------------------------------------------------------------------
; cam_foe - this frame's camera targets: CAMSOF, CAMRZ, CAMLK/CAMLB, CAMOUT.
; -----------------------------------------------------------------------------
; do_ship calls it before the along ease. Clobbers everything, T0/T1 included.
; -----------------------------------------------------------------------------
cam_foe:
        ldx     ETIER
        lda     SHIP_OFF,x
        sta     CAMS0
        sta     CAMSOF
        lda     ZOOM_RZ,x
        sta     CAMRT
        sta     CAMZ
        sta     CAMZI
        stz     CAMLK
        stz     CAMOUT
        jsr     cam_pick
        ldx     CAMT
        bne     cf_have
        lda     CAMRT                   ; no target: the tier's camera, and the
        sta     CAMRZ                   ;   hysteresis starts from it next time
        rts

cf_have:
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
        lda     VXL
        sta     CAMVXL
        lda     VXH
        sta     CAMVXH
        lda     VYL
        sta     CAMVYL
        lda     VYH
        sta     CAMVYH

        ; ---- 1. ZOOM: what fits it with the ship where the tier puts it ----
        ; ALONG. VY < 0 is ahead (up the screen, toward fb-x 0), and the room
        ; there is FBCX + SHOFF; behind it is what is left of the 400 rows.
        lda     CAMVYL
        sta     MAL
        lda     CAMVYH
        sta     MAH
        jsr     cam_absd
        lda     CAMS0
        jsr     cam_sextw
        bit     CAMVYH
        bpl     cf_behind
        clc
        lda     #<FBCX
        adc     CAMWL
        sta     CAMRL
        lda     #>FBCX
        adc     CAMWH
        sta     CAMRH
        bra     cf_along
cf_behind:
        sec
        lda     #<(CAM_XMAX - FBCX)
        sbc     CAMWL
        sta     CAMRL
        lda     #>(CAM_XMAX - FBCX)
        sbc     CAMWH
        sta     CAMRH
cf_along:
        jsr     cam_fit2

        ; ACROSS. VX > 0 lands toward fb-y 0 (zoom_fb), and the ship itself sits
        ; at FBCY + SHOFX - so the room that way is FBCY + lean.
        lda     CAMVXL
        sta     MAL
        lda     CAMVXH
        sta     MAH
        jsr     cam_absd
        lda     #<FBCY                  ; the room from the screen's centre line,
        sta     CAMRL                   ;   NOT from where the lean has the ship:
        stz     CAMRH                   ;   the lean is moved by this very answer
        bit     CAMVXH                  ;   (cam_lean), and a zoom that reads its
        bpl     cf_across               ;   own output hunts
        lda     #<(CAM_YMAX - FBCY)
        sta     CAMRL
cf_across:
        jsr     cam_fit2

        lda     ZCAP                    ; no wider than the cap, either answer
        bne     :+
        lda     #ZCAP_DEF
:       cmp     CAMZ
        bcc     :+
        sta     CAMZ
:       cmp     CAMZI
        bcc     :+
        sta     CAMZI
:       lda     CAMZ                    ; OUT the moment the tight margin needs
        cmp     CAMRZ                   ;   it, back IN only as far as the loose
        bcc     cf_zset                 ;   one allows - between the two, hold
        lda     CAMZI
        cmp     CAMRZ
        bcc     cf_zkeep
        beq     cf_zkeep
cf_zset:
        sta     CAMRZ
cf_zkeep:
        lda     CAMRZ                   ; ...and never tighter than the tier
        cmp     CAMRT
        bcc     :+
        lda     CAMRT
        sta     CAMRZ
:
        ; ---- 2. SLIDE: what that zoom could not buy ------------------------
        ; e = the enemy's distance on the screen at the target zoom. The Q0.7
        ; multiply takes 127 for 1:1, a pixel short at most.
        lda     CAMRZ
        bpl     :+
        lda     #127
:       sta     CAMZ
        lda     CAMVYL
        sta     MAL
        lda     CAMVYH
        sta     MAH
        jsr     cam_absd
        jsr     cam_e
        bit     CAMVYH
        bmi     sl_ahead

        ; behind: the ship may rise to hi = room - e, but no higher than leaves
        ; CAM_F ahead at this zoom, and never lower than the tier had it
        sec
        lda     #<(CAM_XMAX - FBCX - CAM_M)
        sbc     MAL
        sta     CAMAL
        lda     #>(CAM_XMAX - FBCX - CAM_M)
        sbc     MAH
        sta     CAMAH
        jsr     cam_sat8
        sta     CAMWL
        sec
        sbc     CAMS0
        bvc     :+
        eor     #$80
:       bpl     sl_across               ; hi >= s0: it fits as it is
        lda     #<CAM_F
        sta     MAL
        lda     #>CAM_F
        sta     MAH
        lda     CAMZ
        sta     MB
        jsr     smul16q7
        lda     MAL                     ; the up bound, F*z/128 - FBCX. It fits a
        sec                             ;   signed byte (asserted), so the low
        sbc     #<FBCX                  ;   byte of the 16-bit answer is exact
        sta     CAMWH
        lda     CAMS0                   ; a ship the tier already put higher
        sec                             ;   than the bound stays where it is
        sbc     CAMWH
        bvc     :+
        eor     #$80
:       bpl     :+
        lda     CAMS0
        sta     CAMWH
:       lda     CAMWL
        sec
        sbc     CAMWH
        bvc     :+
        eor     #$80
:       bpl     :+
        lda     CAMWH                   ; the bound wins: it will not fit
        sta     CAMWL
        inc     CAMOUT
:       lda     CAMWL
        sta     CAMSOF
        bra     sl_across

sl_ahead:                               ; ahead: the ship sinks to lo = e + m - FBCX
        clc
        lda     MAL
        adc     #<(CAM_M - FBCX)
        sta     CAMAL
        lda     MAH
        adc     #>(CAM_M - FBCX)
        sta     CAMAH
        jsr     cam_sat8
        sta     CAMWL
        lda     CAMS0
        sec
        sbc     CAMWL
        bvc     :+
        eor     #$80
:       bpl     sl_across               ; s0 >= lo: it fits as it is
        lda     CAMWL                   ; lo > s0 >= 0, so unsigned will do
        cmp     #CAM_SLIM+1
        bcc     :+
        lda     #CAM_SLIM
        inc     CAMOUT
:       sta     CAMSOF

sl_across:
        lda     CAMVXL
        sta     MAL
        lda     CAMVXH
        sta     MAH
        jsr     cam_absd
        jsr     cam_e
        bit     CAMVXH
        bmi     sl_left
        clc                             ; toward fb-y 0: the lean may not go
        lda     MAL                     ;   under lo = e + m - FBCY
        adc     #<(CAM_M - FBCY)
        sta     CAMAL
        lda     MAH
        adc     #>(CAM_M - FBCY)
        sta     CAMAH
        jsr     cam_sat8
        sta     CAMWL
        sec
        sbc     #<-CAM_XLIM
        bvc     :+
        eor     #$80
:       bmi     sl_done                 ; lo < -XLIM: no bound at all
        lda     CAMWL
        sec
        sbc     #CAM_XLIM+1
        bvc     :+
        eor     #$80
:       bmi     :+
        lda     #CAM_XLIM
        sta     CAMWL
        inc     CAMOUT
:       lda     #1
        bra     sl_bound
sl_left:
        sec                             ; toward fb-y 299: nor over hi
        lda     #<(CAM_YMAX - FBCY - CAM_M)
        sbc     MAL
        sta     CAMAL
        lda     #>(CAM_YMAX - FBCY - CAM_M)
        sbc     MAH
        sta     CAMAH
        jsr     cam_sat8
        sta     CAMWL
        sec
        sbc     #CAM_XLIM+1
        bvc     :+
        eor     #$80
:       bpl     sl_done                 ; hi > XLIM: no bound at all
        lda     CAMWL
        sec
        sbc     #<-CAM_XLIM
        bvc     :+
        eor     #$80
:       bpl     :+
        lda     #<-CAM_XLIM
        sta     CAMWL
        inc     CAMOUT
:       lda     #2
sl_bound:
        sta     CAMLK
        lda     CAMWL
        sta     CAMLB
sl_done:
        rts

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
        sta     CAMAH
        lda     CAMBL
        ror     a
        lsr     CAMAH
        ror     a
        clc
        adc     CAMBL
        sta     CAMAL
        lda     CAMAH
        adc     CAMBH
        sta     CAMAH
        lda     CAMAL                   ; current <= W: keep it
        cmp     CAMCL
        lda     CAMAH
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

; cam_sextw - A (signed) -> CAMWL/CAMWH.
cam_sextw:
        sta     CAMWL
        ldy     #$00
        ora     #$00
        bpl     :+
        dey
:       sty     CAMWH
        rts

; cam_fit - CAMZ = min(CAMZ, 128 * CAMA / CAMD): the zoom at which CAMD px sit
; inside CAMA px of room. Nothing to do when it already fits at 1:1, and when it
; does not the quotient is under 128, so seven restoring steps are all of it.
cam_fit:
        lda     CAMAL
        cmp     CAMDL
        lda     CAMAH
        sbc     CAMDH
        bcs     cfit_done
        stz     CAMQ
        ldx     #7
cfit_lp:
        asl     CAMAL
        rol     CAMAH
        asl     CAMQ
        sec
        lda     CAMAL
        sbc     CAMDL
        tay
        lda     CAMAH
        sbc     CAMDH
        bcc     :+
        sta     CAMAH
        sty     CAMAL
        inc     CAMQ
:       dex
        bne     cfit_lp
        lda     CAMQ
        cmp     CAMZ
        bcs     cfit_done
        sta     CAMZ
cfit_done:
        rts

; cam_fit2 - the room CAMR less CAM_M into CAMZ, and less CAM_M + CAM_MHYS into
; CAMZI: the zoom-out threshold and the zoom-back-in one, for the same CAMD.
cam_fit2:
        sec
        lda     CAMRL
        sbc     #CAM_M
        sta     CAMAL
        lda     CAMRH
        sbc     #$00
        sta     CAMAH
        jsr     cam_fit
        jsr     cam_swapz
        sec
        lda     CAMRL
        sbc     #CAM_M + CAM_MHYS
        sta     CAMAL
        lda     CAMRH
        sbc     #$00
        sta     CAMAH
        jsr     cam_fit
cam_swapz:
        lda     CAMZ
        ldx     CAMZI
        sta     CAMZI
        stx     CAMZ
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

; cam_sat8 - A = CAMA saturated into a signed byte.
cam_sat8:
        lda     CAMAH
        beq     s8_pos
        cmp     #$FF
        beq     s8_neg
        asl     a
        lda     #$7F
        bcc     :+
        lda     #$80
:       rts
s8_pos: lda     CAMAL
        bpl     :+
        lda     #$7F
:       rts
s8_neg: lda     CAMAL
        bmi     :+
        lda     #$80
:       rts

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
; cam_arrow - the blinking arrow on the edge, for the target it could not frame.
; -----------------------------------------------------------------------------
; Where the enemy IS on the screen - zoom_fb, with this frame's eased zoom,
; slide, lean and shake - pushed onto the screen's edge: the edge it is further
; past picks the arrow, and the tip goes to that edge, level with the enemy
; along it. After do_flames, so the ship's own place is final.
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
        lda     CAMVXL
        sta     VXL
        lda     CAMVXH
        sta     VXH
        lda     CAMVYL
        sta     VYL
        lda     CAMVYH
        sta     VYH
        jsr     zoom_fb

        stz     CAMAL                   ; past the top or bottom: by CAMA,
        stz     CAMAH                   ;   the arrow CAMWL - 1
        stz     CAMWL
        lda     FXH
        bpl     ar_xhi
        sec
        lda     #$00
        sbc     FXL
        sta     CAMAL
        lda     #$00
        sbc     FXH
        sta     CAMAH
        lda     #ARW_UP+1
        sta     CAMWL
        bra     ar_y
ar_xhi: sec
        lda     FXL
        sbc     #<CAM_XMAX
        tay
        lda     FXH
        sbc     #>CAM_XMAX
        bcc     ar_y
        sty     CAMAL
        sta     CAMAH
        ora     CAMAL
        beq     ar_y
        lda     #ARW_DOWN+1
        sta     CAMWL
ar_y:   stz     CAMDL                   ; past a side: by CAMD, the arrow
        stz     CAMDH                   ;   CAMWH - 1
        stz     CAMWH
        lda     FYH
        bpl     ar_yhi
        sec
        lda     #$00
        sbc     FYL
        sta     CAMDL
        lda     #$00
        sbc     FYH
        sta     CAMDH
        lda     #ARW_RIGHT+1
        sta     CAMWH
        bra     ar_pick
ar_yhi: sec
        lda     FYL
        sbc     #<CAM_YMAX
        tay
        lda     FYH
        sbc     #>CAM_YMAX
        bcc     ar_pick
        sty     CAMDL
        sta     CAMDH
        ora     CAMDL
        beq     ar_pick
        lda     #ARW_LEFT+1
        sta     CAMWH
ar_pick:
        lda     CAMWL
        ora     CAMWH
        bne     :+
ar_no:  rts                             ; it is on the screen after all
:       lda     CAMWL                   ; the edge it is further past
        beq     ar_side
        lda     CAMAL
        cmp     CAMDL
        lda     CAMAH
        sbc     CAMDH
        bcc     ar_side
        lda     CAMWL
        bra     ar_dir
ar_side:
        lda     CAMWH
ar_dir: dec     a
        sta     CAMDIR

        lda     FXH                     ; both coordinates onto the screen, a
        bmi     ar_fxlo                 ;   corner's worth in from each end
        lda     FXL
        cmp     #<ARW_CM
        lda     FXH
        sbc     #>ARW_CM
        bcc     ar_fxlo
        lda     #<(CAM_XMAX - ARW_CM)
        cmp     FXL
        lda     #>(CAM_XMAX - ARW_CM)
        sbc     FXH
        bcs     ar_fy
        lda     #<(CAM_XMAX - ARW_CM)
        sta     FXL
        lda     #>(CAM_XMAX - ARW_CM)
        sta     FXH
        bra     ar_fy
ar_fxlo:
        lda     #ARW_CM
        sta     FXL
        stz     FXH
ar_fy:  lda     FYH
        bmi     ar_fylo
        lda     FYL
        cmp     #<ARW_CM
        lda     FYH
        sbc     #>ARW_CM
        bcc     ar_fylo
        lda     #<(CAM_YMAX - ARW_CM)
        cmp     FYL
        lda     #>(CAM_YMAX - ARW_CM)
        sbc     FYH
        bcs     ar_put
        lda     #<(CAM_YMAX - ARW_CM)
        sta     FYL
        lda     #>(CAM_YMAX - ARW_CM)
        sta     FYH
        bra     ar_put
ar_fylo:
        lda     #ARW_CM
        sta     FYL
        stz     FYH

ar_put: ldx     CAMDIR                  ; top-left = the tip's place - the tip
        txa                             ;   inside the sprite
        asl     a
        tay
        cpx     #ARW_UP
        bcc     ar_ps
        sec                             ; top or bottom: fb-x is the edge
        lda     ARW_EDGEW,y
        sbc     ARW_TX,x
        sta     OS_ARG+1
        lda     ARW_EDGEW+1,y
        sbc     #$00
        sta     OS_ARG+2
        sec
        lda     FYL
        sbc     ARW_TY,x
        sta     OS_ARG+3
        lda     FYH
        sbc     #$00
        sta     OS_ARG+4
        bra     ar_emit
ar_ps:  sec                             ; a side: fb-y is the edge
        lda     ARW_EDGEW,y
        sbc     ARW_TY,x
        sta     OS_ARG+3
        lda     ARW_EDGEW+1,y
        sbc     #$00
        sta     OS_ARG+4
        sec
        lda     FXL
        sbc     ARW_TX,x
        sta     OS_ARG+1
        lda     FXH
        sbc     #$00
        sta     OS_ARG+2
ar_emit:
        txa
        clc
        adc     #ARW_SLOT0
        sta     OS_ARG+0
        jmp     API_GPU_SPRITE

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
ARW_TX: .byte   ARW_RIGHT_TX, ARW_LEFT_TX, ARW_UP_TX, ARW_DOWN_TX
ARW_TY: .byte   ARW_RIGHT_TY, ARW_LEFT_TY, ARW_UP_TY, ARW_DOWN_TY
ARW_EDGEW:                              ; the edge each tip goes to: fb-y for a
        .word   ARW_EDGE                ;   side, fb-x for the top and bottom
        .word   CAM_YMAX - ARW_EDGE
        .word   ARW_EDGE
        .word   CAM_XMAX - ARW_EDGE

        .include "arrows.s"             ; the art - GENERATED, tools/arrowgen.py

        .popseg
