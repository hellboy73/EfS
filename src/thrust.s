; =============================================================================
; thrust.s - the five thruster flames (A/B/C/D/E), animated sprites riding a
; vector ship
; =============================================================================
; The ship itself is a polygon (ship.s), but a flame is exactly the kind of
; small, non-outline art design_technical 11.9 reserves sprites for. Five
; nozzles were authored (docs/story - the pilot's own words): A/B fore, C/D
; aft, E the main drive at the tail. Four triggers:
;
;     turn LEFT     -> A (fore-left,  UP/nose-ward)  + D (aft-right, DOWN/tail-ward)
;     turn RIGHT    -> B (fore-right, UP/nose-ward)  + C (aft-left,  DOWN/tail-ward)
;     turn, either way, ONLY past TIER 6 (speed > 100 forward - not slower,
;                     not reverse) -> also E
;     accelerating  -> E, ALWAYS - it keeps showing once THRTL_MAX is reached
;                     and holding UP stops changing anything, because the
;                     player is still commanding thrust
;     braking       -> A + B together (both fore nozzles, straight back)
;
; The turn pair's grow/shrink ramp (FLPHASE, "zwiekszaj plomienie stopniowo" -
; the first two frames of a smaller bracket before settling into the own one,
; and the mirror on release) applies to E (FLEPHASE) and the brake pair
; (FLBPHASE) too, each independently - E can be ramping in from a straight-
; line accelerate with no turn involved at all, and braking has nothing to do
; with either.
;
; A/B sit on the hull's fore shoulder (SHIP_SHAPE vertices 2/3, 0-indexed - the
; shape editor's own numbering), C/D on the aft shoulder (vertices 3/4), E at
; the tail apex (vertex 6). Left and right on the player's SCREEN are dy>0 and
; dy<0 respectively - empirically confirmed against the ship outline, not
; derived from the TATE rotation, so if that convention ever changes this
; file's FL_ANCHOR/E_DX_TBL tables are where to fix it.
;
; The art comes in three pre-scaled sizes for A-D (flames.s, GENERATED from
; assets/png/flame_{large,med,small}_{up,dn}{N}.png by tools/sprgen.py --batch)
; because a raster sprite cannot ride the polygon's continuous SCALE the way a
; vertex can - design_technical 11.9 / open_questions D2. Which size is picked
; is a stepped function of the current zoom (FLAME_RZ_MED/SMALL below); the
; ANCHOR position is a separate small table per bracket rather than one table
; scaled at runtime, for the same reason: three raster steps beside one
; continuous outline is already an accepted seam (D2's own words), and
; snapping the anchor to it avoids a signed Q0.7 multiply on ZOOMH, which
; cannot represent 128 (1.0) in smul16q7's 7-bit magnitude anyway - see the
; TPQ table in main.s for how the rest of the code works around that.
;
; E is the odd one out: it was only authored at one size (assets/png/
; flame_xl_*.png, "xl" - the main drive dwarfs a side nozzle), so at the two
; SMALLER ship brackets it borrows A-D's own art one size up (ship bracket
; medium draws E with the side set's LARGE dn frames; ship bracket small draws
; it with the side set's MEDIUM dn frames) - the mirror image of the grow/
; shrink ramp's "borrow one size down". See E_BASE_TBL.
;
; NO ROTATION is applied to the source PNGs by sprgen.py here (unlike
; ship32.png's --tate): they were authored directly in the stored orientation
; - width = the flame's length (the axis the hardware blits DOWN the player's
; screen), height = its thinness (the axis it blits LEFT). See sprgen.py's
; docstring.
; =============================================================================

FLAME_PAGE      = $11           ; GPU RAM page for the flames blob (SHIP_PAGE
                                ;   is $10; nothing else claims a data page)
FLAME_N         = 27            ; sprite slots A-D, E's own art and A-D's xs
                                ;   grow/shrink tier install, 2..28
FLAME_SLOT0     = 2             ; slot 0 = ROM test sprite, 1 = SPR_SHIP

FLAME_ANIM_RATE = 4             ; frames per animation step - TUNE HERE. The
                                ;   frame cycles 1-2-3 (large/medium, 3 frames)
                                ;   or 1-2-3-4 (small, 4 frames) at this rate.

FLAME_RZ_MED    = 110           ; ZOOMH >= this -> large art; down to this,
FLAME_RZ_SMALL  = 80            ;   medium; below this, small. ZOOMH's own
                                ;   range is 64..128 (main.s's ZOOM_RZ).

; --- flame animation state, free game RAM (radar.s's own block ends at
;     $6F50; nothing else reaches $7000) --------------------------------------
FLWDIR      = $7000             ; wanted direction this frame: 0 none, 1 left, 2 right
FLDIR       = $7001             ; the direction actually ramping/held
FLTARGET    = $7002             ; FLPHASE's target for this frame's tick: 0 or 3
FLPHASE     = $7003             ; 0 off, 1/2 growing or shrinking (borrowed
                                ;   art), 3 running (own bracket)
FLSUB       = $7004             ; frame divider, 0..FLAME_ANIM_RATE-1
FLIDX       = $7005             ; free-running own-bracket frame index
FLBRACKET   = $7006             ; this frame's size class: 0 large,1 med,2 small
FLARTBR     = $7007             ; the bracket the ART actually comes from
                                ;   (== FLBRACKET, except mid-ramp on large/med)
FLFRAME     = $7008             ; frame index within that art set
FLKIND      = $7009             ; 0 = up (fore), 1 = dn (aft), for the nozzle
                                ;   flame_draw is about to place
FLNOZ_OFF   = $700A             ; that nozzle's offset into FL_ANCHOR, 0/2/4/6
FLW         = $700B             ; the chosen art's stored width/height
FLH         = $700C
FLSLOT      = $700D             ; the GPU sprite slot flame_draw is placing
FLTMPA      = $700E             ; origin dx/dy, signed, once flame_draw has
FLTMPB      = $700F             ;   applied the attach-edge offset
FLTMP2      = $7010
FLCXL       = $7011             ; the ship's screen centre, computed once a
FLCXH       = $7012             ;   frame exactly as emit_ship computes it
FLCYL       = $7013
FLCYH       = $7014
FLSTEP      = $7015             ; the flame upload, one LOAD page per frame - 0-4
FLEFRAME    = $7016             ; E's own frame index, 0-2 (FLIDX clamped - its
                                ;   own art sets are all 3 frames, but FLIDX
                                ;   free-runs 0-3 while the ship is at the
                                ;   small bracket)
FLEW        = $7017             ; E wanted this frame: accelerating, or
                                ;   turning fast enough (see do_flames)
FLETARGET   = $7018             ; E's own ramp target, 0 or 3 - ticks on the
                                ;   same FLAME_ANIM_RATE boundary as FLPHASE
FLEPHASE    = $7019             ; E's own ramp: 0 off, 1/2 growing/shrinking
                                ;   through a smaller tier, 3 running its own
FLEART      = $701A             ; which of E_ART_*'s four size tiers this
                                ;   draw uses (E_ART_BASE_TBL's 4th tier, the
                                ;   side set's small dn, exists only so E
                                ;   always has something smaller to grow
                                ;   through, even from the ship's own smallest
                                ;   bracket)
FLEFR       = $701B             ; frame within that tier
FLBW        = $701C             ; brake wanted this frame: JOY_DOWN held
FLBTARGET   = $701D             ; the brake pair's ramp target, 0 or 3
FLBPHASE    = $701E             ; the brake pair's own ramp - same shape as
                                ;   FLPHASE (small bracket snaps, no smaller
                                ;   tier to borrow), driven by FLBW instead

; -----------------------------------------------------------------------------
; upload_flames_step - installs the FLAME_N-sprite blob and patches slots
; 2..FLAME_N+1 into the shared GPU sprite definition table, one LOAD page a
; frame.
; -----------------------------------------------------------------------------
; Same shape as ship.s's upload_step (that file's own comment calls it out as
; the worked example this would need) but patching FLAME_N slots from a table
; instead of two slots inline, since a byte-by-byte special case stops making
; sense past a handful. Unconditional - unlike the ship's sprite path, this one
; is not behind SHIP_SPRITE; the ship stays a vector outline, but its flames
; are not.
; -----------------------------------------------------------------------------
upload_flames_step:
        ldx     FLSTEP
        inc     FLSTEP
        txa
        bne     @def
        lda     #FLAME_PAGE             ; step 0: the art itself, one LOAD
        sta     OS_ARG+0
        lda     #<flames_data
        sta     OS_ARG+1
        lda     #>flames_data
        sta     OS_ARG+2
        jmp     API_GPU_LOAD

@def:   dex                             ; steps 1-4: def page X, 0=TYPE,
        lda     #$00                    ;   1=PTR_LSB, 2=PTR_MSB, 3=HEIGHT
        ldy     #$00
:       sta     DEFPG,y
        iny
        bne     :-

        cpx     #$00
        bne     :+
        ldy     #$00
@tlp:   lda     FLAME_TYPE_TBL,y
        sta     DEFPG+FLAME_SLOT0,y
        iny
        cpy     #FLAME_N
        bne     @tlp
        bra     @ship
:       cpx     #$01
        bne     :+
        ldy     #$00
@llp:   lda     FLAME_OFF_TBL,y
        sta     DEFPG+FLAME_SLOT0,y
        iny
        cpy     #FLAME_N
        bne     @llp
        bra     @ship
:       cpx     #$02
        bne     @height
        lda     #FLAME_PAGE             ; every slot's PTR_MSB is the same
        ldy     #$00                    ;   page - they all share one blob
@mlp:   sta     DEFPG+FLAME_SLOT0,y
        iny
        cpy     #FLAME_N
        bne     @mlp
        bra     @ship
@height:
        ldy     #$00
@hlp:   lda     FLAME_HEIGHT_TBL,y
        sta     DEFPG+FLAME_SLOT0,y
        iny
        cpy     #FLAME_N
        bne     @hlp
@ship:  txa
        clc
        adc     #$03                    ; GPU def pages $03/$04/$05/$06
        sta     OS_ARG+0
        lda     #<DEFPG
        sta     OS_ARG+1
        lda     #>DEFPG
        sta     OS_ARG+2
        jmp     API_GPU_LOAD

; -----------------------------------------------------------------------------
; do_flames - trigger, ramp and draw all five nozzles. Called once a frame,
; after emit_ship. Only the turning pair (A+D/B+C) ramps through FLPHASE; E
; and the braking pair (A+B) are plain on/off against their own trigger and
; never borrow a smaller bracket's art (E's own borrowing, one size UP, is a
; fixed per-bracket table instead - see E_BASE_TBL).
; -----------------------------------------------------------------------------
do_flames:
        ; ---- WDIR: which way the player is actually holding, off the RAW
        ; stick (input.s's JOY1/JOY_LEFT/JOY_RIGHT) - not TURNV's sign, which
        ; is eased and made the flames visibly lag the key. The FLPHASE ramp
        ; below is the only intentional lag left, and it is a growth effect,
        ; not an input delay.
        lda     JOY1
        and     #JOY_LEFT
        bne     @wdir_left
        lda     JOY1
        and     #JOY_RIGHT
        bne     @wdir_right
        lda     #0
        bra     @wdir_done
@wdir_left:
        lda     #1
        bra     @wdir_done
@wdir_right:
        lda     #2
@wdir_done:
        sta     FLWDIR

        ; ---- bracket, from the snapped zoom every other system already uses
        lda     ZOOMH
        cmp     #FLAME_RZ_MED
        bcs     @br_large
        cmp     #FLAME_RZ_SMALL
        bcs     @br_med
        lda     #2
        bra     @br_done
@br_large:
        lda     #0
        bra     @br_done
@br_med:
        lda     #1
@br_done:
        sta     FLBRACKET

        ; ---- target: 3 (fully in) if held and the direction matches, 0
        ; otherwise. Switching direction mid-ramp is treated as "ramp the OLD
        ; one down" until it lands on 0, then the new direction is adopted.
        lda     FLWDIR
        bne     @want
        lda     #0                      ; not turning: always ramp down
        bra     @have_target
@want:  lda     FLDIR
        bne     @have_dir
        lda     FLWDIR                  ; idle -> adopt the wanted direction
        sta     FLDIR
@have_dir:
        lda     FLDIR
        cmp     FLWDIR
        beq     @target3
        lda     #0                      ; switched direction: ramp the OLD
        bra     @have_target            ;   one down first
@target3:
        lda     #3
@have_target:
        sta     FLTARGET

        ; ---- E wanted: accelerating - unconditionally, it shows even once
        ; THRTL_MAX is reached and holding UP no longer changes anything - or
        ; turning while faster than 100 forward (TIER>=6 excludes both slower
        ; forward flight and reverse in one compare: TIER_SPD's rows are
        ; -150,-100,-50,0,+50,+100,+150,... so tier 6 is the first one past
        ; +100). ----
        lda     JOY1
        and     #JOY_UP
        bne     @ew_yes
        lda     FLWDIR
        beq     @ew_no
        lda     TIER
        cmp     #6
        bcc     @ew_no
@ew_yes:
        lda     #1
        bra     @ew_done
@ew_no: lda     #0
@ew_done:
        sta     FLEW
        beq     @etarget0
        lda     #3
        bra     @ehave_target
@etarget0:
        lda     #0
@ehave_target:
        sta     FLETARGET

        ; ---- brake wanted / target: plain JOY_DOWN, ramped the same shape as
        ; the turn pair (FLBRACKET's small-bracket snap applies here too - it
        ; is the same A/B art, just both firing together). ----
        lda     JOY1
        and     #JOY_DOWN
        beq     @bw_no
        lda     #1
        bra     @bw_done
@bw_no: lda     #0
@bw_done:
        sta     FLBW
        beq     @btarget0
        lda     #3
        bra     @bhave_target
@btarget0:
        lda     #0
@bhave_target:
        sta     FLBTARGET

        ; ---- one tick every FLAME_ANIM_RATE frames: steps FLPHASE, FLEPHASE
        ; and FLBPHASE toward their targets by 1, AND the own-bracket running
        ; frame index FLIDX - UNCONDITIONALLY, so small's animation does not
        ; stall just because it never ramps. This was the bug: FLIDX used to
        ; live inside the large/medium-only ramp branch, so the small bracket
        ; never advanced it. All three phases always STEP now, never snap:
        ; the small bracket used to have no smaller tier to grow through and
        ; jumped straight in/out, but WIDTH_TBL/HEIGHT_TBL/BASE_TBL's "xs"
        ; entry (see above) gives it one, the same way large borrows medium
        ; and medium borrows small.
        inc     FLSUB
        lda     FLSUB
        cmp     #FLAME_ANIM_RATE
        bcc     @notick
        stz     FLSUB
        lda     FLPHASE
        cmp     FLTARGET
        beq     @afterphase
        bcc     @phase_up
        dec     FLPHASE
        bra     @afterphase
@phase_up:
        inc     FLPHASE
@afterphase:
        lda     FLEPHASE
        cmp     FLETARGET
        beq     @eafterphase
        bcc     @ephase_up
        dec     FLEPHASE
        bra     @eafterphase
@ephase_up:
        inc     FLEPHASE
@eafterphase:
        lda     FLBPHASE
        cmp     FLBTARGET
        beq     @bafterphase
        bcc     @bphase_up
        dec     FLBPHASE
        bra     @bafterphase
@bphase_up:
        inc     FLBPHASE
@bafterphase:
        inc     FLIDX
        ldx     FLBRACKET
        lda     FLIDX
        cmp     NFRAMES_BY_BRACKET,x
        bcc     @notick
        stz     FLIDX
@notick:
        lda     FLPHASE
        bne     @tick_done
        stz     FLDIR                   ; fully wound down: idle again
@tick_done:

        ; ---- ship's screen centre, exactly as emit_ship's vector branch.
        ; UNCONDITIONAL: E and the brake pair can fire without a turn, so this
        ; can no longer live behind the turn-pair's early exit. ----
        ldy     #$00
        bit     SHOFFH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFFH
        adc     #<FBCX
        sta     FLCXL
        tya
        adc     #>FBCX
        sta     FLCXH
        ldy     #$00
        bit     SHOFXH
        bpl     :+
        ldy     #$FF
:       clc
        lda     SHOFXH
        adc     #<FBCY
        sta     FLCYL
        tya
        adc     #>FBCY
        sta     FLCYH

        lda     FLIDX                   ; E's own frame: FLIDX clamped to 0-2
        cmp     #3                      ;   (its art is always 3 frames; FLIDX
        bcc     :+                      ;   itself free-runs 0-3 at the small
        lda     #0                      ;   bracket)
:       sta     FLEFRAME

        lda     FLDIR                   ; ---- the turning pair, if the ramp
        beq     @turn_none              ; has anything to show ----
        lda     FLPHASE
        bne     :+
        jmp     @turn_none
:
        ; ---- which art set: own bracket if fully ramped in, else one bracket
        ; smaller, showing its frame 0 or 1 as the grow/shrink step ----
        lda     FLPHASE
        cmp     #3
        beq     @use_own
        lda     FLBRACKET
        inc     a                       ; 65C02: INC A is a real addressing mode
        sta     FLARTBR
        lda     FLPHASE
        sec
        sbc     #1
        sta     FLFRAME
        bra     @have_art
@use_own:
        lda     FLBRACKET
        sta     FLARTBR
        lda     FLIDX
        sta     FLFRAME
@have_art:

        lda     FLDIR
        cmp     #1
        beq     @left
        ; right: B (fore-right, up) + C (aft-left, dn)
        stz     FLKIND
        lda     #1*2                    ; nozzle B
        sta     FLNOZ_OFF
        jsr     flame_draw
        lda     #1
        sta     FLKIND
        lda     #2*2                    ; nozzle C
        sta     FLNOZ_OFF
        jsr     flame_draw
        bra     @turn_none
@left:  ; left: A (fore-left, up) + D (aft-right, dn)
        stz     FLKIND
        lda     #0*2                    ; nozzle A
        sta     FLNOZ_OFF
        jsr     flame_draw
        lda     #1
        sta     FLKIND
        lda     #3*2                    ; nozzle D
        sta     FLNOZ_OFF
        jsr     flame_draw
@turn_none:

        ; ---- E: which art tier - own (FLBRACKET) if fully ramped in, else
        ; one tier smaller, showing its frame 0 or 1 as the grow/shrink step -
        ; same shape as the turn pair's, just never a bracket-based snap,
        ; since E_ART_* always has a smaller tier on hand (see FLEART's
        ; comment above). ----
        lda     FLEPHASE
        beq     @e_none
        cmp     #3
        beq     @euse_own
        lda     FLBRACKET
        inc     a                       ; 65C02: INC A is a real addressing mode
        sta     FLEART
        lda     FLEPHASE
        sec
        sbc     #1
        sta     FLEFR
        bra     @ehave_art
@euse_own:
        lda     FLBRACKET
        sta     FLEART
        lda     FLEFRAME
        sta     FLEFR
@ehave_art:
        jsr     flame_draw_e
@e_none:

        ; ---- brake: both fore nozzles together, straight back - ramped the
        ; same shape as the turn pair (FLBPHASE/FLBTARGET above). ----
        lda     FLBPHASE
        beq     @done
        cmp     #3
        beq     @buse_own
        lda     FLBRACKET
        inc     a                       ; 65C02: INC A is a real addressing mode
        sta     FLARTBR
        lda     FLBPHASE
        sec
        sbc     #1
        sta     FLFRAME
        bra     @bhave_art
@buse_own:
        lda     FLBRACKET
        sta     FLARTBR
        lda     FLIDX
        sta     FLFRAME
@bhave_art:
        stz     FLKIND
        lda     #0*2                    ; nozzle A
        sta     FLNOZ_OFF
        jsr     flame_draw
        lda     #1*2                    ; nozzle B
        sta     FLNOZ_OFF
        jsr     flame_draw
@done:  rts

; -----------------------------------------------------------------------------
; flame_draw - place one nozzle's flame sprite. In: FLARTBR, FLFRAME, FLKIND,
; FLNOZ_OFF, FLBRACKET, FLCXL/H, FLCYL/H. Clobbers A/X/Y.
; -----------------------------------------------------------------------------
flame_draw:
        lda     FLARTBR                 ; slot = 2 + BASE[artbr*2+kind] + frame
        asl     a
        clc
        adc     FLKIND
        tax
        lda     BASE_TBL,x
        clc
        adc     FLFRAME
        adc     #FLAME_SLOT0
        sta     FLSLOT

        ldx     FLARTBR                 ; the chosen art's own stored size
        lda     WIDTH_TBL,x
        sta     FLW
        lda     HEIGHT_TBL,x
        sta     FLH

        lda     FLBRACKET               ; anchor from the CURRENT bracket -
        asl     a                       ;   position tracks the real ship,
        asl     a                       ;   only the art size is borrowed
        asl     a
        clc
        adc     FLNOZ_OFF
        tax
        lda     FL_ANCHOR,x
        sta     FLTMPA                  ; anchor dx
        lda     FL_ANCHOR+1,x
        sta     FLTMPB                  ; anchor dy

        lda     FLKIND
        bne     @dn
        lda     FLW                     ; up: attach edge is the HIGH end of
        sec                             ;   the sprite's stored width - origin
        sbc     #1                      ;   is (W-1) short of the anchor
        sta     FLTMP2
        lda     FLTMPA
        sec
        sbc     FLTMP2
        sta     FLTMPA
@dn:                                    ; dn: attach edge IS the origin already
        lda     FLH
        lsr     a
        sta     FLTMP2
        lda     FLTMPB
        sec
        sbc     FLTMP2
        sta     FLTMPB

        lda     FLSLOT
        ; fall through into flame_place

; -----------------------------------------------------------------------------
; flame_place - A = sprite slot, FLTMPA/FLTMPB = signed offset from the ship's
; screen centre (FLCXL/H, FLCYL/H). Issues one SPRITE draw.
; -----------------------------------------------------------------------------
flame_place:
        sta     OS_ARG+0
        ldy     #$00
        lda     FLTMPA
        bpl     :+
        ldy     #$FF
:       clc
        lda     FLCXL
        adc     FLTMPA
        sta     OS_ARG+1
        tya
        adc     FLCXH
        sta     OS_ARG+2
        ldy     #$00
        lda     FLTMPB
        bpl     :+
        ldy     #$FF
:       clc
        lda     FLCYL
        adc     FLTMPB
        sta     OS_ARG+3
        tya
        adc     FLCYH
        sta     OS_ARG+4
        jmp     API_GPU_SPRITE

; -----------------------------------------------------------------------------
; flame_draw_e - place the main-drive flame. In: FLEART (which of E_ART_*'s
; four size tiers), FLEFR (frame within it), FLBRACKET (the ship's REAL
; bracket - position tracks that even while the art is a smaller borrowed
; tier), FLCXL/H, FLCYL/H. Always centred (dy=0) and always "dn"-style (the
; attach edge - the visible content's leading edge - IS the origin;
; E_ART_PAD_TBL corrects for the XL sprite's padding up to a valid stored
; width, which the plain A-D sprites never needed because 16 and 8 are already
; valid buckets).
; -----------------------------------------------------------------------------
flame_draw_e:
        ldx     FLEART
        lda     E_ART_BASE_TBL,x
        clc
        adc     FLEFR
        sta     FLSLOT
        lda     E_ART_HEIGHT_TBL,x
        sta     FLH
        lda     E_ART_PAD_TBL,x
        sta     FLTMP2                  ; stash the pad - X is about to change

        ldx     FLBRACKET               ; position uses the REAL bracket
        sec
        lda     E_DX_TBL,x
        sbc     FLTMP2
        sta     FLTMPA
        lda     FLH                     ; origin dy = -(H/2), centred
        lsr     a
        sta     FLTMP2
        sec
        lda     #$00
        sbc     FLTMP2
        sta     FLTMPB

        lda     FLSLOT
        jmp     flame_place

; =============================================================================
; Tables
; =============================================================================
        .segment "RODATA"

; anchor point per bracket (0 large/1 medium/2 small) x nozzle (A/B/C/D),
; already nudged 2px past the hull edge along the fore/aft axis (fore nozzles
; further nose-ward, aft nozzles further tail-ward). Computed by scaling the
; SHIP_SHAPE edge midpoints (A = mid of shape vertices 10/11, B = mid of 1/2,
; C = mid of 8/9, D = mid of 3/4 - the shape editor's 0-based numbering) by
; each bracket's representative RZ/128 (119, 95, 72 - the midpoints of the
; FLAME_RZ_MED/SMALL bands above) and rounding to the nearest pixel. Tuned
; against madsim, not measured precisely - nudge further here if a flame
; still sits visibly on the hull.
FL_ANCHOR:
        .byte   <-6, 12, <-6, <-11, 11, 12, 11, <-11   ; large:  A  B  C  D
        .byte   <-5, 10, <-5,  <-9,  8, 10,  8,  <-9   ; medium: A  B  C  D
        .byte   <-4,  7, <-4,  <-6,  7,  7,  7,  <-6   ; small:  A  B  C  D

; WIDTH_TBL/HEIGHT_TBL/BASE_TBL have a FOURTH entry, "xs" - not a ship bracket
; (FLBRACKET only ever reaches 2), but the tier the small bracket's own ramp
; borrows from, the same way large borrows medium and medium borrows small.
; Without it, small had nothing smaller to grow through and snapped straight
; in/out - see the tick logic below, which no longer special-cases FLBRACKET
; 2 for exactly this reason.
WIDTH_TBL:      .byte   16, 16, 8,  8    ; stored sprite width per tier
HEIGHT_TBL:     .byte   4,  3,  2,  2    ; ...and height
NFRAMES_BY_BRACKET:
                .byte   3,  3,  4        ; large/medium cycle 1-2-3, small
                                        ; 1-2-3-4 - OWN-bracket cycling only,
                                        ; so no xs entry (xs is never "own")

; slot base per (bracket*2 + kind), kind 0=up(fore) 1=dn(aft) - must match
; flames.s's generation order (large up/dn, medium up/dn, small up/dn, ...,
; xs up/dn last)
BASE_TBL:       .byte   0, 3, 6, 9, 12, 16, 23, 25

; E's ART, in FOUR size tiers so its own grow/shrink ramp always has something
; smaller to borrow from, even starting at the ship's own smallest bracket:
; tier 0 = E's own XL art; tier 1 = the side set's LARGE dn (also what ship
; bracket "medium" draws E with at tier 3/"own"); tier 2 = side MEDIUM dn
; (also ship bracket "small"'s own E art); tier 3 = side SMALL dn, which E
; only ever borrows two frames of (0/1) while ramping - it is never anyone's
; "own" tier. FLEART picks the tier per frame; do_flames.
E_ART_BASE_TBL:   .byte   22, 5, 11, 18  ; xl / large dn / medium dn / small dn
E_ART_HEIGHT_TBL: .byte   5,  4,  3,  2
E_ART_PAD_TBL:    .byte   4,  0,  0,  0 ; only XL (24 -> padded to 32) needs one

; E's SCREEN position, one entry per ship bracket (0-2) - always the real
; bracket, never the borrowed art tier. Same dx as C/D at that bracket (E
; sits on the centreline at the same how-far-aft distance), nudged one more
; pixel further aft.
E_DX_TBL:         .byte   12, 9,  8

        .include "flames.s"             ; the sprite art itself - GENERATED,
                                        ; see that file's header

; the def-table patch source, one byte per slot 2..FLAME_N+1, in the same
; order as flames.s's sprites (large up1-3/dn1-3, medium up1-3/dn1-3, small
; up1-4/dn1-4, xl dn1-3 - E's own art, slots 22-24 - then xs up1-2/dn1-2 -
; the small bracket's own grow/shrink tier, slots 25-28)
FLAME_TYPE_TBL:
        .byte   FLAME_L_UP1_TYPE, FLAME_L_UP2_TYPE, FLAME_L_UP3_TYPE
        .byte   FLAME_L_DN1_TYPE, FLAME_L_DN2_TYPE, FLAME_L_DN3_TYPE
        .byte   FLAME_M_UP1_TYPE, FLAME_M_UP2_TYPE, FLAME_M_UP3_TYPE
        .byte   FLAME_M_DN1_TYPE, FLAME_M_DN2_TYPE, FLAME_M_DN3_TYPE
        .byte   FLAME_S_UP1_TYPE, FLAME_S_UP2_TYPE, FLAME_S_UP3_TYPE, FLAME_S_UP4_TYPE
        .byte   FLAME_S_DN1_TYPE, FLAME_S_DN2_TYPE, FLAME_S_DN3_TYPE, FLAME_S_DN4_TYPE
        .byte   FLAME_XL_DN1_TYPE, FLAME_XL_DN2_TYPE, FLAME_XL_DN3_TYPE
        .byte   FLAME_XS_UP1_TYPE, FLAME_XS_UP2_TYPE
        .byte   FLAME_XS_DN1_TYPE, FLAME_XS_DN2_TYPE

FLAME_OFF_TBL:
        .byte   FLAME_L_UP1_OFFSET, FLAME_L_UP2_OFFSET, FLAME_L_UP3_OFFSET
        .byte   FLAME_L_DN1_OFFSET, FLAME_L_DN2_OFFSET, FLAME_L_DN3_OFFSET
        .byte   FLAME_M_UP1_OFFSET, FLAME_M_UP2_OFFSET, FLAME_M_UP3_OFFSET
        .byte   FLAME_M_DN1_OFFSET, FLAME_M_DN2_OFFSET, FLAME_M_DN3_OFFSET
        .byte   FLAME_S_UP1_OFFSET, FLAME_S_UP2_OFFSET, FLAME_S_UP3_OFFSET, FLAME_S_UP4_OFFSET
        .byte   FLAME_S_DN1_OFFSET, FLAME_S_DN2_OFFSET, FLAME_S_DN3_OFFSET, FLAME_S_DN4_OFFSET
        .byte   FLAME_XL_DN1_OFFSET, FLAME_XL_DN2_OFFSET, FLAME_XL_DN3_OFFSET
        .byte   FLAME_XS_UP1_OFFSET, FLAME_XS_UP2_OFFSET
        .byte   FLAME_XS_DN1_OFFSET, FLAME_XS_DN2_OFFSET

FLAME_HEIGHT_TBL:
        .byte   FLAME_L_UP1_HEIGHT, FLAME_L_UP2_HEIGHT, FLAME_L_UP3_HEIGHT
        .byte   FLAME_L_DN1_HEIGHT, FLAME_L_DN2_HEIGHT, FLAME_L_DN3_HEIGHT
        .byte   FLAME_M_UP1_HEIGHT, FLAME_M_UP2_HEIGHT, FLAME_M_UP3_HEIGHT
        .byte   FLAME_M_DN1_HEIGHT, FLAME_M_DN2_HEIGHT, FLAME_M_DN3_HEIGHT
        .byte   FLAME_S_UP1_HEIGHT, FLAME_S_UP2_HEIGHT, FLAME_S_UP3_HEIGHT, FLAME_S_UP4_HEIGHT
        .byte   FLAME_S_DN1_HEIGHT, FLAME_S_DN2_HEIGHT, FLAME_S_DN3_HEIGHT, FLAME_S_DN4_HEIGHT
        .byte   FLAME_XL_DN1_HEIGHT, FLAME_XL_DN2_HEIGHT, FLAME_XL_DN3_HEIGHT
        .byte   FLAME_XS_UP1_HEIGHT, FLAME_XS_UP2_HEIGHT
        .byte   FLAME_XS_DN1_HEIGHT, FLAME_XS_DN2_HEIGHT

        .segment "CODE"
