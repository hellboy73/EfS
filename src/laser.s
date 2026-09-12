; =============================================================================
; laser.s - the second weapon: one beam, from the nose to the top of the screen
; =============================================================================
; FIRE2's single click chooses between the gun (shots.s) and this, and FIRE
; fires whichever is chosen. One press lights the beam for LSR_FRAMES - CETAS's
; HERO_LASER_DUR, 20 frames, taken across - and it cannot be lit again while it
; burns. The ship is NOT locked while it burns, the way CETAS's whale is: the
; beam is laid from wherever the nose is on every frame, so turning SWEEPS it
; across the field, and that is the point of it.
;
; IT IS A SCREEN THING, THE WAY A BULLET'S LIFETIME IS. The ship always points
; up (design_technical 4.3) and TATE puts the player's up on the framebuffer's
; -X, so a beam from the nose to the top edge is always a HORIZONTAL framebuffer
; line - one gpu_hdotline, the byte-aligned dotted rule every CETAS laser is
; drawn with (X1, Y, X2 half-res; the OS aligns the run to whole VRAM bytes).
; One rule, not CETAS's two. It runs from byte 0 to the byte holding the nose,
; so it can reach up to 3 half-res px past the nose into the hull - under it,
; not over it: it is emitted from do_shots, before emit_ship draws the hull.
;
; IT PIERCES. Every rock and every UFO whose circle the beam crosses loses
; LSR_DMG hit points on every frame it is crossed - rock_take_hit and
; foe_take_hit, two fifths of what one bullet costs either - and is paid pro
; rata, so a rock is worth the same points to the beam as to the gun. Nothing
; stops the beam and nothing is spent: a rock broken in it puts both halves in
; it.
;
; THE TEST IS ON THE SCREEN, against the points the gun already uses - the
; visible list for the rocks, FOEFX/FY for the UFOs. Both have the screen shake
; folded in, so the beam is placed with the shake too and the two cancel. A
; target is hit when its circle - its collision radius at this zoom, plus
; LSR_HW - reaches the segment: level with it and within the radius across,
; or past one end and within the radius of that end.
;
; THE SWEEP IS TESTED, NOT SAMPLED. The world turns about the ship by whole
; brads, and at the top of the screen one brad carries a target ~8 px across
; the beam, where the smallest rock's whole circle zoomed out is 12 - so tested
; once a frame, a hard turn could step a speck clean over the line. On a frame
; the heading moved by d brads the test is widened, ON THE SIDE THE BEAM CAME
; FROM, by what the turn swept at the target's own distance: u * d * 2pi/256,
; u being how far up the screen from the ship it is. That is the wedge between
; last frame's beam and this one, near enough. One side only: widening both
; would hit a target a frame before the beam reached it and make a turning beam
; THICKER, not swept. A right turn (HEAD rising) carries everything ahead
; toward +Y - objects.s zoom_fb, fb_y = FBCY - vx*z/16 - so +Y is the swept
; side on a right turn and -Y on a left one.
;
; WHERE IT LIVES. The code is CODE4, stored behind COLD in bank 4 and run in
; the run area after CODE3 (cart.cfg): bank 0 had 15 bytes left and banks 1 and
; 3 a few hundred. Two three-byte hooks sit in CODE2 - do_shots and do_foes -
; and one in HIDATA, input.s's click. Its state is the free tail of the page
; gameover.s and main.s's death block share.
; =============================================================================

; --- tunables - physics.md 10 is where these are argued -----------------------
LSR_FRAMES  = 20                ; frames one press keeps the beam lit - CETAS's
                                ;   HERO_LASER_DUR, which is also its U-BOOT's
LSR_HW      = 2                 ; the beam's HALF-WIDTH for the hit test, full-
                                ;   res px - CETAS's HERO_LASER_HH, and the same
                                ;   bonus the gun's SHOT_HITR gives a bullet.
                                ;   Added to every target's own radius; it is
                                ;   not a second opinion about how big they are
LSR_DMG     = 4                 ; hit points a frame to everything the beam
                                ;   crosses - two fifths of a bullet's SHOT_DMG.
                                ;   Twenty frames of it are 80: a 192 (50) goes
                                ;   in thirteen, and the beam is still lit for
                                ;   the halves it just made
LSR_SCORE   = SCORE_HIT * LSR_DMG / SHOT_DMG
LSR_FOE_SCORE = SCORE_FOE_HIT * LSR_DMG / SHOT_DMG
                                ; ...and what a frame of it pays, pro rata to a
                                ;   bullet's: the same points per hit point
LSR_NOSE    = 22                ; full-res px from the ship's centre to the nose
                                ;   at 1:1 - SHIP_SHAPE's vertex 13, (-22, 0),
                                ;   the gun's muzzle too (shots.s)
LSR_SWK     = 13                ; the sweep: 128 * 4 * 2pi/256 = 12.57 per brad,
                                ;   rounded UP - see lsr_sweep - so a swept
                                ;   target is found 3% generously, never missed
LSR_DMAX    = 7                 ; brads a frame the sweep believes at most. The
                                ;   fastest turn is under 2; this only bounds
                                ;   the product for qmul

        .assert 2 * (2*39 + LSR_HW) <= 255, error, "laser.s: 2R must stay a quarter-square index (BODY_R's 39 at 1:1)"
        .assert 127 + LSR_DMAX*LSR_SWK <= 254, error, "laser.s: lsr_sweep's qmul index"
        .assert 2*39 + LSR_HW + (127*LSR_DMAX*LSR_SWK + 64)/128 <= 255, error, "laser.s: R + the sweep must stay a byte"
        .assert LSR_NOSE + 128 <= 254, error, "laser.s: the nose's qmul index"
        .assert LSR_SCORE * SHOT_DMG = SCORE_HIT * LSR_DMG && LSR_FOE_SCORE * SHOT_DMG = SCORE_FOE_HIT * LSR_DMG, error, "laser.s: the beam's pay is no longer an exact share of a bullet's"

; --- state: $6FC9 on, the page's free tail -------------------------------------
WEAPON      = $6FC9             ; 0 = the gun, 1 = the laser - input.s's single
                                ;   FIRE2 click flips it (wpn_toggle)
LSRN        = $6FCA             ; frames of beam left, 0 = dark
LSRON       = $6FCB             ; 1 on a frame the beam is lit: lsr_frame sets
                                ;   it for lsr_foes, which runs later, in do_foes
LSRHD       = $6FCC             ; HEAD as it was last frame, for the sweep
LSRD        = $6FCD             ; this frame's |turn| * LSR_SWK, 0 = no turn
LSRSGN      = $6FCE             ; ...and which side it swept: 0 = +Y, $FF = -Y
LSRXL       = $6FCF             ; the nose: full-res framebuffer X, signed 16,
LSRXH       = $6FD0             ;   the shake folded in
LSRYL       = $6FD1             ; the beam's row, full-res, likewise
LSRYH       = $6FD2
LSRCXL      = $6FD3             ; the ship's centre, full-res X - the pivot the
LSRCXH      = $6FD4             ;   world turns about, which the sweep measures from
LSRI        = $6FD5             ; the walk's cursor
LSRR        = $6FD6             ; the target's radius on the screen + LSR_HW
LSROV       = $6FD7             ; how far past either end of the beam it is, 0 =
                                ;   level with the span
LSRTXL      = $6FD8             ; the target's full-res screen centre, signed 16
LSRTXH      = $6FD9
LSRTYL      = $6FDA
LSRTYH      = $6FDB
LSRRT       = $6FDC             ; 5 bytes: LSRR per rock class, once a frame
LSRHN       = $6FE1             ; hits this frame, rocks and UFOs together - for
                                ;   the harness, which cannot see a hit any other
                                ;   way once the rock has split
        .assert WEAPON > TPLOCK && LSRHN < FLWDIR, error, "laser.s: the laser's block no longer fits between main.s's death block and thrust.s's"

        .pushseg
        .segment "CODE4"

; -----------------------------------------------------------------------------
; wpn_trigger - do_shots' FIRE: to the laser if FIRE2 chose it, else the gun.
; -----------------------------------------------------------------------------
; A dispatch in place of do_shots' `jsr shot_fire`, so the choice costs CODE2
; nothing - it had 85 bytes to spare.
; -----------------------------------------------------------------------------
wpn_trigger:
        lda     WEAPON
        bne     lsr_fire
        jmp     shot_fire               ; tail

; lsr_fire - FIRE's edge lights the beam, unless it is already lit. The heading
; it is lit on is where its first frame's sweep starts, so that frame sweeps
; nothing: the beam did not exist the frame before.
lsr_fire:
        lda     JOYINP
        and     #JOY_FIRE
        beq     @no
        lda     LSRN
        bne     @no                     ; burning: one beam at a time, as CETAS
        lda     #LSR_FRAMES
        sta     LSRN
        lda     HEAD
        sta     LSRHD
        lda     #SE_LASER
        jmp     sfx_fire                ; tail
@no:    rts

; -----------------------------------------------------------------------------
; wpn_toggle - input.s do_fire2's confirmed single click: the other weapon, said
; on the message bar and heard as a click. A beam already burning is left to
; burn out - it was fired, the way a bullet in flight is not recalled.
; -----------------------------------------------------------------------------
wpn_toggle:
        lda     WEAPON
        eor     #$01
        sta     WEAPON
        clc                             ; IM_GUN / IM_LASER, WEAPON the offset
        adc     #IM_GUN
        jsr     indicate_urgent         ; ...and it JUMPS THE QUEUE (hud_game.s):
                                        ;   what is armed is the state the player
                                        ;   is flying in, not a report of
                                        ;   something that happened, so it must
                                        ;   not wait behind a HULL BREACH
        lda     #SE_WSWITCH
        jmp     sfx_fire                ; tail
        .assert IM_LASER = IM_GUN + 1, error, "laser.s: wpn_toggle indexes the two messages by WEAPON"

; lsr_reset - game_start: the gun is chosen and the beam is dark. Nothing zeroes
; cartridge RAM for us.
lsr_reset:
        stz     WEAPON
        stz     LSRN
        stz     LSRON
        rts

; -----------------------------------------------------------------------------
; lsr_frame - one frame of the beam, from do_shots after the gun's hit pass.
; -----------------------------------------------------------------------------
; Where it is, then draw it, then what it crosses among the rocks; the UFOs get
; theirs from lsr_foes, inside do_foes, once their screen points exist. Nothing
; is standing on a cell list here - shots.s rock_kill's own condition - so a
; rock it breaks may relink the grid.
; -----------------------------------------------------------------------------
lsr_frame:
        stz     LSRON
        stz     LSRHN
        lda     LSRN
        beq     @dark
        lda     SHIPGONE                ; no ship, no beam - one lit when the last
        beq     :+                      ;   life went does not outlive it
        stz     LSRN
@dark:  rts
:       dec     LSRN
        inc     LSRON
        jsr     lsr_where
        jsr     lsr_draw
        ; fall through into lsr_rocks

; -----------------------------------------------------------------------------
; lsr_rocks - every rock in the visible list, against the beam.
; -----------------------------------------------------------------------------
; The radii first, once a frame per CLASS rather than once per rock: five qmuls
; instead of a qmul for every entry, most of which the test throws out on one
; subtract. A rock something else broke earlier this frame - a bullet, a ram -
; is still in the list, stamped SHP_DEAD; its slot may already be a free one,
; and hitting it would spend a hit point nobody has.
; -----------------------------------------------------------------------------
lsr_rocks:
        lda     VISN
        beq     @done
        lda     #4                      ; five classes, BODY_R's five rows
        sta     LSRI
@rr:    ldx     LSRI
        lda     BODY_R,x                ; half-res, shrunk by the zoom and doubled
        sta     MQA                     ;   into full-res - shot_hits' own radius
        lda     ZOOMH
        sta     MQB
        jsr     qmul                    ; (clobbers X and Y)
        asl     a
        clc
        adc     #LSR_HW
        ldx     LSRI
        sta     LSRRT,x
        dec     LSRI
        bpl     @rr
        stz     LSRI
@lp:    ldy     LSRI
        ldx     VISIDX,y
        lda     OBJSHP,x
        cmp     #SHP_DEAD
        beq     @next
        tax
        lda     LSRRT,x
        sta     LSRR
        lda     VSXL,y
        sta     LSRTXL
        lda     VSXH,y
        sta     LSRTXH
        lda     VSYL,y
        sta     LSRTYL
        lda     VSYH,y
        sta     LSRTYH
        jsr     lsr_hit
        bcc     @next
        inc     LSRHN                   ; A HIT: paid pro rata to a bullet, and
        lda     #LSR_SCORE              ;   the halves - if this is the last of
        jsr     score_add               ;   it - thrown across the beam, which
        lda     HEAD                    ;   lies along the heading
        sta     SPL_HD
        ldy     LSRI
        ldx     VISIDX,y
        lda     #LSR_DMG
        jsr     rock_take_hit           ; LSR_DMG: the crack, or the split
@next:  inc     LSRI
        lda     LSRI
        cmp     VISN
        bne     @lp
@done:  rts

; -----------------------------------------------------------------------------
; lsr_foes - every UFO on the screen, against the beam. From do_foes, straight
; after foe_hits: the same screen points, and a UFO the gun has just killed is
; FS_DEAD by now and skipped.
; -----------------------------------------------------------------------------
lsr_foes:
        lda     LSRON
        beq     @done
        lda     NFOE
        beq     @done
        lda     #FOE_R                  ; one radius for all of them, full-res
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul
        asl     a
        clc
        adc     #LSR_HW
        sta     LSRR
        lda     NFOE
        dec     a
        sta     FEI                     ; FEI, because foe_kill reads it
@lp:    ldx     FEI
        lda     FOEST,x
        beq     @next
        cmp     #FS_MOUNTED             ; a spider on its rock: the beam is on
        beq     @next                   ;   the ROCK, as a bullet is (foe_hits)
        lda     FOEON,x
        beq     @next
        lda     FOEFXL,x
        sta     LSRTXL
        lda     FOEFXH,x
        sta     LSRTXH
        lda     FOEFYL,x
        sta     LSRTYL
        lda     FOEFYH,x
        sta     LSRTYH
        jsr     lsr_hit
        bcc     @next
        inc     LSRHN
        lda     #LSR_FOE_SCORE
        jsr     score_add
        ldx     FEI
        lda     #LSR_DMG
        jsr     foe_take_hit            ; the tap, or - the last of it - the kill
@next:  dec     FEI
        bpl     @lp
@done:  rts

; -----------------------------------------------------------------------------
; lsr_where - this frame's nose, row, pivot and sweep.
; -----------------------------------------------------------------------------
; The ship's centre exactly as emit_ship places it - FBCX + SHOFF across, FBCY +
; the cross lean down, and the shake on both - and the nose LSR_NOSE ahead of it
; scaled by ZEASH, the reciprocal the GPU scales the hull by.
; -----------------------------------------------------------------------------
lsr_where:
        ldy     #$00
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFFH
        adc     #<FBCX
        sta     LSRCXL
        tya
        adc     #>FBCX
        sta     LSRCXH
        ldy     #$00
        bit     SHAKEX
        bpl     :+
        ldy     #$FF
:       clc
        lda     LSRCXL
        adc     SHAKEX
        sta     LSRCXL
        tya
        adc     LSRCXH
        sta     LSRCXH

        lda     #LSR_NOSE
        sta     MQA
        lda     ZEASH
        sta     MQB
        jsr     qmul
        sta     T0
        sec
        lda     LSRCXL
        sbc     T0
        sta     LSRXL
        lda     LSRCXH
        sbc     #$00
        sta     LSRXH

        ldy     #$00
        bit     SHOFXH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFXH
        adc     #<FBCY
        sta     LSRYL
        tya
        adc     #>FBCY
        sta     LSRYH
        ldy     #$00
        bit     SHAKEY
        bpl     :+
        ldy     #$FF
:       clc
        lda     LSRYL
        adc     SHAKEY
        sta     LSRYL
        tya
        adc     LSRYH
        sta     LSRYH

        ; ---- the sweep: the whole brads the world turned since last frame ----
        sec
        lda     HEAD
        sbc     LSRHD
        ldx     HEAD
        stx     LSRHD
        stz     LSRSGN
        cmp     #$80
        bcc     :+
        dec     LSRSGN                  ; a left turn: the -Y side was swept
        eor     #$FF
        inc     a
:       cmp     #LSR_DMAX + 1
        bcc     :+
        lda     #LSR_DMAX
:       tax                             ; |d| * LSR_SWK, by adding - |d| is 0, 1
        lda     #$00                    ;   or 2 on every real frame
        cpx     #$00
        beq     @d
@m:     clc
        adc     #LSR_SWK
        dex
        bne     @m
@d:     sta     LSRD
        rts

; -----------------------------------------------------------------------------
; lsr_draw - the rule: framebuffer X 0 (the top edge) to the nose, on the ship's
; row. Both are positive and under 400 whatever SHOFF and the shake do - the
; ship never leaves the screen - so each halves into one byte.
; -----------------------------------------------------------------------------
lsr_draw:
        stz     OS_ARG+0                ; X1: the top of the screen
        lda     LSRYH
        lsr     a
        lda     LSRYL
        ror     a
        sta     OS_ARG+1                ; Y
        lda     LSRXH
        lsr     a
        lda     LSRXL
        ror     a
        sta     OS_ARG+2                ; X2: the nose
        jmp     API_GPU_HDOTLINE        ; tail

; -----------------------------------------------------------------------------
; lsr_hit - does the circle LSRTX/LSRTY, radius LSRR, reach the beam? C SET = it
; does. Clobbers A, X, Y, T0, T1.
; -----------------------------------------------------------------------------
; ALONG first: how far past either end the centre is (LSROV; 0 = level with the
; span). Past the nose means back down the hull, past X 0 means off the top of
; the screen, and either by more than the radius is a miss outright. ACROSS
; second, with the swept side folded onto +v: inside the radius is a hit when
; level with the span and the round-end test past an end; outside it, on the
; swept side and level with the span, the sweep gets its say.
; -----------------------------------------------------------------------------
lsr_hit:
        sec
        lda     LSRTXL
        sbc     LSRXL
        tax
        lda     LSRTXH
        sbc     LSRXH
        bmi     @fwd                    ; ahead of the nose
        bne     @out                    ; 256+ px back down the hull
        txa
        bra     @end
@fwd:   lda     LSRTXH                  ; ahead of it: off the top of the screen?
        bpl     @span                   ; no - level with the beam
        cmp     #$FF
        bne     @out
        lda     LSRTXL
        beq     @out                    ; exactly -256
        eor     #$FF
        inc     a
@end:   cmp     LSRR
        beq     :+
        bcs     @out
:       sta     LSROV
        bra     @across
@out:   clc                             ; (a miss - here, within a branch's
        rts                             ;  reach of the along test)
@span:  stz     LSROV
@across:
        sec                             ; v = the target's row - the beam's
        lda     LSRTYL
        sbc     LSRYL
        sta     T0
        lda     LSRTYH
        sbc     LSRYH
        sta     T1
        bit     LSRSGN                  ; a left turn swept -Y: fold it over, so
        bpl     :+                      ;   the swept side is +v either way
        sec
        lda     #$00
        sbc     T0
        sta     T0
        lda     #$00
        sbc     T1
        sta     T1
:       lda     T1
        beq     @swept                  ; 0..255 on the side the beam came from
        cmp     #$FF
        bne     @miss
        lda     T0
        beq     @miss                   ; exactly -256
        eor     #$FF
        inc     a                       ; |v| on the side it is heading into
        bra     @plain
@swept: lda     T0
        cmp     LSRR
        bcc     @plain
        beq     @plain
        ldx     LSROV                   ; beyond the radius: the sweep widens the
        bne     @miss                   ;   span only, never the ends...
        ldx     LSRD                    ; ...and only on a frame the world turned
        beq     @miss
        jsr     lsr_sweep               ; A = R + the swept width here
        cmp     T0                      ; C set iff R + swept >= v
        rts
@plain: cmp     LSRR                    ; A = |v|: inside the beam's own width?
        beq     :+
        bcs     @miss
:       ldx     LSROV
        bne     @round
        sec                             ; level with the span: a hit
        rts
@round: asl     a                       ; past an end: |d|^2 against R^2, both out
        tax                             ;   of the quarter-square table - QS[2a]
        lda     QSL,x                   ;   is a*a exactly (shots.s shot_hits)
        sta     T0
        lda     QSH,x
        sta     T1
        lda     LSROV
        asl     a
        tax
        clc
        lda     QSL,x
        adc     T0
        sta     T0
        lda     QSH,x
        adc     T1
        sta     T1
        lda     LSRR
        asl     a
        tax
        lda     QSL,x                   ; R^2 - |d|^2: C SET when it is not
        cmp     T0                      ;   negative
        lda     QSH,x
        sbc     T1
        rts
@miss:  clc
        rts

; -----------------------------------------------------------------------------
; lsr_sweep - A = LSRR + how far the turn carried a target at this distance, in
; full-res px. Preserves T0.
; -----------------------------------------------------------------------------
; u * |d| * 2pi/256 with u the target's distance up the screen from the ship's
; centre - the pivot. As a qmul: (u/4) * (|d| * 12.57) / 128, the quarter so a
; target off the top of a zoomed-out screen (u ~ 410) still fits qmul's 127.
; Behind the pivot it contributes nothing: those are the targets beside the
; hull, which the turn moves the least.
; -----------------------------------------------------------------------------
lsr_sweep:
        sec
        lda     LSRCXL
        sbc     LSRTXL
        tax
        lda     LSRCXH
        sbc     LSRTXH
        bmi     @none
        cmp     #$02
        bcs     @far                    ; 512+ px: pin the quarter at 127
        sta     T1                      ; u >> 2 out of T1:X
        txa
        lsr     T1
        ror     a
        lsr     T1
        ror     a
        bra     @mul
@far:   lda     #127
@mul:   sta     MQA
        lda     LSRD
        sta     MQB
        jsr     qmul
        clc
        adc     LSRR
        rts
@none:  lda     LSRR
        rts

        .popseg
