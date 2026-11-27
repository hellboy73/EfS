; =============================================================================
; ghosts.s - things in camouflage: dormant enemies, and rocks nobody can see
; =============================================================================
; open_questions.md, F10's GHOSTS. The wall slots' THIRD tenant (slots.s): the
; far zone - a sector has the base, the force field or the ghosts, never two.
;
; ENEMY GHOSTS. An enemy record whose KIND has bit 7 set (levels.s) is DORMANT:
; load_foes puts it on this file's own small list, not in an enemy slot, so
; nothing that reads FOEST sees it - no radar, no hits, no collision, it does not
; hold up a mission. It is only a picture: its kind's WHOLE shape, frame 0,
; dotted (gate.s gb_draw, GBSH 1), STROBED IRREGULARLY while the ship is within
; GH_R - the cloak shimmering as the ship passes - and dying away once it has
; gone: for GH_FLASH frames, the last half of them half as often. EVERY ghost
; strobe is the irregular one, gh_irr (the user, 2026-11-26) - not the field's
; regular flash. At most ONE ghost is drawn a frame: the GPU's bound.
; Waking (gh_wake) turns every ghost into its enemy through foe_spawn - from
; then on it is an ordinary enemy, on the radar and all. What wakes them will be
; F10's A_WAKE; until that exists it is the TRAINER's FIRE2 (the other pad).
;
; ROCK GHOSTS. An ordinary rock in the pool - it moves, collides, is hit, splits
; and scores like any other - with OBJTYPE bit 7 set (GH_ROCK, a level's
; hand-placed record carries it into OBJTYPE as it is). one_asteroid builds its
; command as for any rock, skips its star disc, and hands it to WS_GROCK
; (gh_rock) instead of the GPU:
;
;   unrevealed  drawn only while the ship is within GH_R, and not at all once
;               the ship has gone
;   revealed    drawn wherever it is, until it breaks
;
; ...both IRREGULARLY (gh_irr, by frame and slot, so two do not blink in step).
;
; Revealed = hit (OBJHP under its class's ROCK_HP - every hit goes through
; rock_take_hit, nothing to hook) or bumped (GH_SEEN, set by gh_reveal from the
; two collision answers in physics.s, which take no hit points). rock_split
; draws its children fresh variants, so they come out ordinary, solid rocks. The
; radar takes rocks by CLASS (the mission's RADCL), never reads OBJTYPE: a
; ghost is on it exactly when its class is.
;
;   GHWALL   slot A (upper RAM): gh_rock, gh_lit, gh_near, gh_irr, gh_hit, gh_foe
;
; A GHOST ROCK'S PASSENGER (the user, 2026-11-27): a spider riding a ghost rock
; is in the rock's camouflage and WORKS as ever - mounted, turning with it,
; digging. It is drawn exactly when its rock is (gh_lit), dotted, and is not on
; the radar (radar.s); it is never hit anyway while mounted (foes.s). When the
; rock breaks it falls off like any spider (foe_adrift) - an ordinary, awake,
; drifting spider. A GHOST SPIDER record is therefore never dormant: gh_add has
; it loaded awake to mount the rock beside it (an ordinary spider on a ghost
; rock is cloaked the same way - the cloak is the rock's, not the spider's).
;
; A GHOST ROCK IS RICH (the user, 2026-11-26): every whole hit's worth of damage
; it takes - a bullet, a UFO's shot, two and a half frames of laser - pays out
; the Saturnium a destroyed 16 does (satn.s satn_kill: SATN_ADD and its motes),
; the hit that breaks it included. The hint that the Saturnium in it is what
; hides it. (A ghost 16 pays twice on its last hit: once here, once as a 16.)
;   GHFRAME  slot B (DEMO_RAM): after slots.s's vector table, the enemy ghosts
; State: GHN in the run area (the loader counts on it), the list under the
; window behind ffield.s's (written by load_foes, the loader).
;
; ONLY THE OUTER ZONE HAS GHOSTS (levels.s ZONE 2): anywhere else the loader
; loads a dormant enemy awake (gh_add) and a ghost rock as an ordinary one
; (load_level), since no other tenant can draw them.
; =============================================================================

GH_MAX      = 4                 ; enemy ghosts a sector (the list's length)
GH_R        = 9                 ; "near": both high-byte deltas within this many
                                ;   pages, a square - +-2,304 units, 144 px at 1:1
                                ;   (the user: 150 px, or the fastest close to it)
GH_FLASH    = FF_FLASH          ; the strobe's timer, held here while near
GH_SHAKE    = 0                 ; 1: a drawn ghost's PICTURE jumps a px each
                                ;   frame (gh_jit) - tried and turned off (the
                                ;   user, 2026-11-26)
GH_ROCK     = $80               ; OBJTYPE: a ghost...
GH_SEEN     = $40               ; ...revealed by a collision
GH_VARM     = AST_TYPES - 1     ; ...and what is left is the variant
        .assert (AST_TYPES & GH_VARM) = 0 && AST_TYPES <= GH_SEEN, error, "ghosts.s: the variant must be a power-of-two mask under the ghost bits"
        .assert 2 * GH_R + 1 < 128, error, "ghosts.s: gh_near's biased compare"

; --- state: under the window, behind ffield.s's -------------------------------
GHB         = FF_END
GHXH        = GHB                   ; position, high bytes (the low are $80: a
GHYH        = GHB + GH_MAX          ;   page's middle, 16 px at most off)
GHK         = GHB + 2 * GH_MAX      ; the enemy KIND, bit 7 off
GHHD        = GHB + 3 * GH_MAX      ; its patrol heading...
GHSP        = GHB + 4 * GH_MAX      ; ...and speed, for when it wakes
GHT         = GHB + 5 * GH_MAX      ; the strobe's timer, 0 = dark
GHI         = GHB + 6 * GH_MAX      ; the last one drawn (one a frame, in turn)
GH_END      = GHB + 6 * GH_MAX + 1
        .assert GH_END <= SHAPES_AT, error, "ghosts.s: past the RAM under the window"

        .pushseg
        .segment "CODE8"                ; the run area, readable by the loader
GHN:    .byte   0                       ; enemy ghosts on the list

; -----------------------------------------------------------------------------
; gh_reveal2 / gh_reveal_i / gh_reveal - mark a rock as found out by a bump:
; COL_J and COL_I (a rock-rock answer), COL_I (the ship's), or X. Any rock, ghost
; or not - the bit means nothing without GH_ROCK. Resident: physics.s calls it.
; -----------------------------------------------------------------------------
        .segment "CODE"
gh_reveal2:
        ldx     COL_J
        jsr     gh_reveal
gh_reveal_i:
        ldx     COL_I
gh_reveal:
        lda     OBJTYPE,x
        ora     #GH_SEEN
        sta     OBJTYPE,x
        rts

; =============================================================================
; GHWALL - slot A
; =============================================================================
        .segment "GHWALL"

; -----------------------------------------------------------------------------
; gh_near - A / Y = a position's high bytes. Carry CLEAR: the ship is within
; GH_R pages of it on both axes. X kept.
; -----------------------------------------------------------------------------
gh_near:
        sec
        sbc     SHXH
        jsr     @a
        bcs     @r
        tya
        sec
        sbc     SHYH
@a:     clc                             ; d + R read unsigned, under 2R + 1:
        adc     #GH_R                   ;   no sign test (the wrap is free)
        cmp     #2 * GH_R + 1
@r:     rts

; -----------------------------------------------------------------------------
; gh_irr - A = a seed (the slot, the ghost) -> carry SET: lit this frame. The
; strobe every ghost uses: a FLUORESCENT TUBE's flicker (the user) - a short
; burst, a blip, a burst, then a long dark - 11 lit of GH_IRR's 32, about a
; third (the user: between 22 % and 44 %). Read at
; FRAME + 5 x seed: an ADD, so the bursts keep their shape (an XOR shuffled
; them), and 5 x so neighbours are five frames apart and never blink in step
; (5 is odd: all 32 phases). Clobbers Y and T0.
; -----------------------------------------------------------------------------
gh_irr:
        sta     T0
        asl     a
        asl     a
        clc
        adc     T0
        clc
        adc     FRAME
        and     #GH_IRRN - 1
        tay
        lda     GH_IRR,y
        cmp     #$01
        rts

; -----------------------------------------------------------------------------
; gh_hit - WS_GHIT: X = a rock about to take RKDMG hit points; a GHOST pays a 16's
; Saturnium if that crosses a whole hit (HIT_HP) - or ends it. X kept; A, Y and
; LVTMP (the loader's scratch, free in flight) clobbered.
; -----------------------------------------------------------------------------
gh_hit:
        bit     OBJTYPE,x               ; (every rock hit comes here: bank 1 had
        bpl     @r                      ;   no room for the test)
        lda     OBJHP,x
        jsr     @q
        sty     LVTMP                   ; whole hits it stood on...
        lda     OBJHP,x
        sec
        sbc     RKDMG
        beq     @pay                    ; (this one ends it: a hit all the same)
        bcc     @pay
        jsr     @q                      ; ...and after this one
        cpy     LVTMP
        beq     @r                      ; no whole hit's worth yet (the beam)
@pay:   stx     SPL_P
        jmp     satn_kill               ; tail - it hands X = SPL_P back
@q:     ldy     #$00                    ; A = HP >= 1 -> Y = (HP - 1) / HIT_HP
        sec
        sbc     #$01
@ql:    cmp     #HIT_HP
        bcc     @r
        sbc     #HIT_HP                 ; (carry set by the compare)
        iny
        bra     @ql
@r:     rts

GH_IRR: .byte   1, 1, 0, 1, 1, 0, 0, 0,  0, 0, 1, 0, 0, 0, 0, 0
        .byte   1, 0, 1, 1, 1, 0, 1, 0,  0, 1, 0, 0, 0, 0, 0, 0
GH_IRRN     = * - GH_IRR
        .assert (GH_IRRN & (GH_IRRN - 1)) = 0, error, "ghosts.s: GH_IRR's length must be a power of two"

.if GH_SHAKE
; -----------------------------------------------------------------------------
; gh_jit - A = a seed, X = a zero-page centre (x lo, x hi, y lo, y hi): moved by
; GH_JX/GH_JY[(FRAME + seed) & 7], one px in a direction that changes every
; frame. The PICTURE only: what is moved is the screen centre about to be drawn,
; never the position. Clobbers A, X, Y.
; -----------------------------------------------------------------------------
gh_jit:
        clc
        adc     FRAME
        and     #$07
        tay
        lda     GH_JX,y
        jsr     @add
        inx
        inx
        lda     GH_JY,y
@add:   pha                             ; A, signed, onto the 16-bit at 0,x
        clc
        adc     0,x
        sta     0,x
        pla
        and     #$80                    ; (carry untouched from here on)
        beq     :+
        lda     #$FF
:       adc     1,x
        sta     1,x
        rts

GH_JX:  .byte   1, <-1,  0,  1, <-1,  0, <-1,  1   ; the eight neighbours, one
GH_JY:  .byte   1, <-1,  1,  0,   1, <-1,  0, <-1   ;   step: 2 full-res px (the
                                                    ;   user: half of the first 4)
.endif

; -----------------------------------------------------------------------------
; gh_rock - WS_GROCK: one_asteroid's ghost, PBUF its POLYGON16 block and OS_ARG
; on it. Draw it dotted - half-res: the centre CX2/CY2, the scale halved for the
; doubled offsets - or not at all.
; -----------------------------------------------------------------------------
gh_rock:
        ldx     OBJI
        jsr     gh_lit
        bcc     @r
.if GH_SHAKE
        lda     OBJI                    ; the picture shakes, half-res px; the
        ldx     #CX2L                   ;   rock stays where it is
        jsr     gh_jit
.endif
        lda     CX2L
        sta     PBUF+0
        lda     CX2H
        sta     PBUF+1
        lda     CY2L
        sta     PBUF+2
        lda     CY2H
        sta     PBUF+3
        lsr     PBUF+5
        jmp     API_GPU_DOTPOLYGON      ; tail
@r:     rts

; -----------------------------------------------------------------------------
; gh_lit - X = a ghost rock: carry SET = it is drawn this frame. Found out
; (bumped, or hit: under its class's hit points) - anywhere; not yet - only
; near; both irregularly. X kept; Y and T0 clobbered.
; -----------------------------------------------------------------------------
gh_lit:
        lda     OBJTYPE,x               ; bumped...
        and     #GH_SEEN
        bne     @rev
        ldy     OBJSHP,x                ; ...or hit
        lda     OBJHP,x
        cmp     ROCK_HP,y
        bcc     @rev
        lda     OBJXH,x                 ; NOT YET: only near
        ldy     OBJYH,x
        jsr     gh_near
        bcc     @rev
        clc
        rts
@rev:   txa
        jmp     gh_irr                  ; tail

; -----------------------------------------------------------------------------
; gh_foe - WS_GFOE: X = FEI, an enemy about to be drawn. Carry SET: a passenger
; on a ghost rock - drawn here, its rock's strobe and dotted (gb_draw, its own
; frame and its rock's angle), or not at all. CLEAR: draw it as ever.
; -----------------------------------------------------------------------------
gh_foe:
        lda     FOEST,x
        cmp     #FS_MOUNTED
        bne     @no
        ldy     FOEROCK,x
        lda     OBJTYPE,y
        bpl     @no
        tya
        tax
        jsr     gh_lit
        bcc     @yes                    ; dark with its rock
        ldx     FEI
        lda     FOEFXL,x
        sta     FXL
        lda     FOEFXH,x
        sta     FXH
        lda     FOEFYL,x
        sta     FYL
        lda     FOEFYH,x
        sta     FYH
        lda     FOEAPP,x
        sta     GBAP
        lda     FOEAST,x
        sta     GBST
        lda     FOEANG,x
        sta     GBAN
        lda     #$FF
        sta     GBMK
        lda     #$01
        sta     GBSH
        jsr     gb_draw
@yes:   sec
        rts
@no:    clc
        rts

; =============================================================================
; GHFRAME - slot B: the frame (slots.s's vector table is first)
; =============================================================================
        .segment "GHFRAME"

; -----------------------------------------------------------------------------
; gh_frame - WS_FRAME: the enemy ghosts' timers, and one of them drawn.
; -----------------------------------------------------------------------------
gh_frame:
.if TRAINER
        lda     #JOY2-JOY1              ; TEMPORARY - the trainer's FIRE2 on the
        sec                             ;   other pad wakes them, until F10's
        sbc     JOYPORT                 ;   A_WAKE exists (trainer.s's pad)
        tax
        lda     JOY1_PRESS,x
        and     #JOY_FIRE2
        beq     :+
        jsr     gh_wake
:
.endif
        ldx     GHN
        beq     @r
@t:     dex                             ; near: held fresh; away: dying
        lda     GHXH,x
        ldy     GHYH,x
        jsr     gh_near
        lda     #GH_FLASH
        bcc     @set
        lda     GHT,x
        beq     @nx
        dec     a
@set:   sta     GHT,x
@nx:    txa
        bne     @t
        ldy     GHN                     ; ONE drawn: the next in turn that is
@d:     ldx     GHI                     ;   lit this frame
        inx
        cpx     GHN
        bcc     :+
        ldx     #$00
:       stx     GHI
        lda     GHT,x
        beq     @dn
        cmp     #GH_FLASH / 2           ; dying: half as often
        bcs     :+
        lda     FRAME
        and     #$02
        bne     @dn
:       phy
        txa
        jsr     gh_irr                  ; ...and irregularly
        ply
        bcs     gh_draw
@dn:    dey
        bne     @d
@r:     rts

; gh_draw - ghost X: its kind's whole shape, frame 0, dotted, at its place.
gh_draw:
        ldy     GHK,x
        lda     FOE_KAPP,y
        sta     GBAP
        sec                             ; P = it - the ship (the wrap is free)
        lda     #$80
        sbc     SHXL
        sta     PXL
        lda     GHXH,x
        sbc     SHXH
        sta     PXH
        sec
        lda     #$80
        sbc     SHYL
        sta     PYL
        lda     GHYH,x
        sbc     SHYH
        sta     PYH
        lda     PXL                     ; the rocks' own cull: off the screen
        ldy     PXH                     ;   and out of what view_xform can turn
        ldx     #$00
        jsr     in_range
        bcs     @r
        lda     PYL
        ldy     PYH
        ldx     #$01
        jsr     in_range
        bcs     @r
        jsr     view_xform
        jsr     zoom_fb
.if GH_SHAKE
        lda     GHI                     ; the picture shakes - twice the step, FX
        ldx     #FXL                    ;   being full-res - and the ghost stays
        jsr     gh_jit                  ;   where it is
        lda     GHI
        ldx     #FXL
        jsr     gh_jit
.endif
        stz     GBST                    ; frame 0
        lda     #$FF                    ; every part, at its world angle 0...
        ldy     #$00
        ldx     GBAP
        cpx     #EA_UFO
        bne     :+
        ldy     HEAD                    ; ...but the UFO: LEVEL ON THE SCREEN, as
        lda     #(1 << EN_UFO_PW) - 1   ;   the live one (foe_body) - and only its
:       sty     GBAN                    ;   hull and dome, not the stripes that
        sta     GBMK                    ;   animate its spin (the user)
        lda     #$01
        sta     GBSH
        jmp     gb_draw                 ; tail
@r:     rts

; -----------------------------------------------------------------------------
; gh_wake - every ghost becomes its enemy: its record back into FEREC and
; foe_spawn, as load_foes would have. The list empties. Clobbers A, X, Y.
; -----------------------------------------------------------------------------
gh_wake:
@lp:    ldx     GHN
        beq     @r
        dex
        stx     GHN
        ldy     NFOE                    ; no slot left: it stays asleep for good
        cpy     #FOE_MAX
        bcs     @lp
        lda     #$80
        sta     FEREC+0
        sta     FEREC+2
        lda     GHXH,x
        sta     FEREC+1
        lda     GHYH,x
        sta     FEREC+3
        lda     GHK,x
        sta     FEREC+4
        lda     GHHD,x
        sta     FEREC+5
        lda     GHSP,x
        sta     FEREC+6
        jsr     foe_spawn
        bra     @lp
@r:     rts

; =============================================================================
; The loader (loader.s): run in the window, bank 8 - writes under it, never reads
; =============================================================================
        .segment "LDCODE"

; gh_add - load_foes: a DORMANT record, (T0) on it in ROM, onto the list. A kind
; nothing flies, or a full list, is dropped. Carry SET: the sector is not the
; outer zone, which alone has ghosts - load it AWAKE. Clobbers A, X, Y.
gh_add:
        ldy     #4                      ; a SPIDER is a ghost rock's passenger:
        lda     (T0),y                  ;   loaded awake, to mount and work in
        and     #$7F                    ;   its rock's camouflage (gh_foe)
        cmp     #FK_SPIDER
        beq     @aw
        ldx     CURLEV
        lda     LVL_ZONE,x
        cmp     #ZN_OUTER
        beq     :+
@aw:    sec
        rts
:       ldx     GHN
        cpx     #GH_MAX
        bcs     @r
        ldy     #4
        lda     (T0),y
        and     #$7F
        cmp     #FK_N
        bcs     @r
        sta     GHK,x
        ldy     #1
        lda     (T0),y
        sta     GHXH,x
        ldy     #3
        lda     (T0),y
        sta     GHYH,x
        ldy     #5
        lda     (T0),y
        sta     GHHD,x
        iny
        lda     (T0),y
        sta     GHSP,x
        stz     GHT,x
        inc     GHN
@r:     clc
        rts

        .popseg
