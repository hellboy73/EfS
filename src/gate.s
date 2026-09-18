; =============================================================================
; gate.s - the exit gate, the mission that opens it, and SECTOR COMPLETED
; =============================================================================
; design_technical.md 3.3 always said a level is left through something that
; OPENS, not by switching the wrap off: the world keeps wrapping, and flying
; into the gate is what ends the sector. This is that something.
;
;   CLOSED     nothing of it exists on the screen, the radar or the edge. Once
;              a frame the mission is checked (gate_check): what it asks is
;              levels.s's LVL_MISN / LVL_MPAR, one of the MS_* below.
;   OPEN       the mission is done: EXIT GATE OPEN on the message bar, and from
;              that frame the gate is drawn where levels.s put it, an X marks
;              it on the radar, and while it is off the screen the enemy
;              arrow's own sprite points at it from the edge.
;   ARRIVED    the ship's centre reaches the middle of the X: SC_SECTOR, a
;              whole-frame screen like the intro's (screens.s). It is a
;              PLACEHOLDER - SECTOR COMPLETED on black - for the tunnel flight
;              that will stand between two sectors (open_questions A5, H1). FIRE
;              loads the next sector: the score, the ships and the Saturnium in
;              the hold carry over, everything else is level_begin's
;              (gameover.s).
;
; THE GATE IS AN ENEMY'S SHAPE, NOT AN ENEMY. Its outline is the appearance
; EA_GATE in enemies.s, so it is drawn, edited and ANIMATED with
; tools/enemy_editor.py exactly like a UFO - parts, frames, a playlist, a hold
; - and gate_body below is foe_body's loop without the foe. It never moves: its
; ANGLE is its own spin (GATE_SPIN, 0 = none) minus the camera's heading, which
; is what keeps a thing that is fixed in the world fixed on a turning screen,
; the same composition a spider riding a rock uses.
;
; GATE_DOT picks the primitive, which is still open: 1 = $4C DOT_POLYGON,
; dotted and half-res; 0 = $4E POLYGON16, solid and full-res, like the rocks
; (fixed decision 39). The SIZE does not change with it - the dotted builder
; takes its centre and scale halved - so the X is what the editor shows either
; way, at most +/-127 full-res px from its centre.
;
; FAR AND NEAR. The gate may be anywhere on the torus, and view_xform is only
; safe on a delta whose rotation still fits 16 bits. So a delta past +/-$3FFF
; on either axis is halved first (it keeps its direction, which is all the
; arrow wants of a gate that far away) and then doubled back up after the
; rotation until it is certain to land off the screen at the widest zoom: at
; >= $3C00 units on one axis it is >= 480 px out at 2x, and no edge is that far
; from the ship. A near gate goes through the plain road a UFO takes.
;
; WHERE IT LIVES. The code is CODE6 (CART_HIRAM). Its state is under the
; window behind shield.s's, so everything here but sector_frame runs inside
; cart_frame's win_off bracket - do_gate is called from it, gate_load from
; level_begin, which runs inside it too.
; =============================================================================

MS_ROCKS    = 0                 ; LVL_MISN: every rock of classes 0..LVL_MPAR
                                ;   gone (0 = the 192s) - rocks_left's RKLIVE
MS_FOES     = 1                 ; ...every enemy the level placed is dead
MS_OPEN     = 2                 ; ...nothing: the gate stands open from the start

GATE_DOT    = 1                 ; 1 = DOT_POLYGON, 0 = POLYGON16 - see the header
GATE_SPIN   = 0                 ; its own turn, 1/256 brad a frame (0 = none;
                                ;   256 is a full turn in 256 frames, ~4.2 s)
GATE_IN     = 48 * 16           ; the ship is IN when its centre is within this
                                ;   many world units of the gate's on both axes:
                                ;   48 px at 1:1, the middle of the X
GATE_GR     = 192               ; draw cull margin, full-res px round the screen:
                                ;   the X's reach, 127 * sqrt(2) at any angle
GATE_RX     = RAD_RH - 8        ; the radar X's reach, position-high-byte units:
                                ;   92 -> 23 cells, and the X's +/-2 keeps it
                                ;   inside the 25 the box holds
GTR_N       = 9                 ; dots in the radar X

        .assert (2 * GATE_IN) .MOD 256 = 0, error, "gate.s: the arrival test compares the high byte of P + GATE_IN only"
        .assert (GATE_RX >> RAD_SH) + 2 <= RAD_SCR, error, "gate.s: the radar X would reach outside the radar's box"
        .assert 2 * GATE_RX <= 254, error, "gate.s: d*d = f(2d) needs 2d to index QS"

; --- SECTOR COMPLETED, the placeholder ------------------------------------------
SEC_LINE    = 24                ; the screen's middle text row
SEC_COL     = (37 - (sec_s1_end - sec_s1 - 1)) / 2
SEC_PFLINE  = 27                ; PUSH FIRE, a blank row below it
SEC_PFCOL   = (37 - (sec_s2_end - sec_s2 - 1)) / 2
SEC_ARM     = 90                ; frames before FIRE counts, ~1.5 s: the shot a
                                ;   player was firing as they flew in cannot
                                ;   skip the screen

; --- state: under the window, behind shield.s ----------------------------------
GTON        = SHLD_END + 1      ; 0 closed, 1 open
GTXL        = SHLD_END + 2      ; where it stands, world 16-bit
GTXH        = SHLD_END + 3
GTYL        = SHLD_END + 4
GTYH        = SHLD_END + 5
GTAST       = SHLD_END + 6      ; its playlist step, like FOEAST...
GTACD       = SHLD_END + 7      ; ...and the frames left on it, like FOEACD
GTANL       = SHLD_END + 8      ; its own angle, 8.8 brad
GTANH       = SHLD_END + 9
GTFAR       = SHLD_END + 10     ; nonzero: the delta was halved (see the header)
GTPIN       = SHLD_END + 11     ; nonzero: the radar X is pinned to the rim
GTDX        = SHLD_END + 12     ; the radar's delta, high bytes, signed
GTDY        = SHLD_END + 13
GTJ         = SHLD_END + 14     ; gate_body: the part...
GTROW       = SHLD_END + 15     ; ...and the frame's first row in EN_PLO/EN_PHI
GTRX        = SHLD_END + 16     ; the radar X's centre, half-res
GTRY        = SHLD_END + 17
GTRB        = SHLD_END + 18     ; ONE DOT_PIXELS: the count, then GTR_N pairs
GATE_END    = GTRB + 1 + 2 * GTR_N
        .assert GATE_END <= SHAPES_AT, error, "gate.s: past the RAM under the window"

        .pushseg
        .segment "CODE6"

; -----------------------------------------------------------------------------
; gate_load - level_begin, after load_foes: the gate closed, where CURLEV says.
; -----------------------------------------------------------------------------
gate_load:
        ldx     CURLEV
        lda     LVL_GTXL,x
        sta     GTXL
        lda     LVL_GTXH,x
        sta     GTXH
        lda     LVL_GTYL,x
        sta     GTYL
        lda     LVL_GTYH,x
        sta     GTYH
        stz     GTON
        stz     GTAST
        stz     GTANL
        stz     GTANH
        ldy     #EA_GATE
        lda     EN_AHOLD,y
        sta     GTACD
        lda     LVL_MISN,x              ; MS_OPEN: open from the first frame,
        cmp     #MS_OPEN                ;   quietly - the level's own line is
        bne     :+                      ;   on the bar
        inc     GTON
:       rts

; -----------------------------------------------------------------------------
; gate_open - the mission is done. Also the trainer's door (trainer.s).
; -----------------------------------------------------------------------------
gate_open:
        lda     GTON
        bne     :+
        inc     GTON
        lda     #IM_GATE
        jmp     indicate_msg            ; tail
:       rts

; -----------------------------------------------------------------------------
; gate_check - C SET when this sector's mission is done.
; -----------------------------------------------------------------------------
gate_check:
        ldx     CURLEV
        lda     LVL_MISN,x
        beq     @rocks                  ; MS_ROCKS
        cmp     #MS_FOES
        beq     @foes
        sec                             ; MS_OPEN, or a type nothing knows:
        rts                             ;   open rather than a sector with no exit
@rocks: ldy     LVL_MPAR,x              ; classes MPAR down to 0, all empty
:       lda     RKLIVE,y
        bne     @no
        dey
        bpl     :-
        sec
        rts
@foes:  ldx     NFOE                    ; FOEST 0 is dead or never filled
        beq     @yes
:       dex
        lda     FOEST,x
        bne     @no
        txa
        bne     :-
@yes:   sec
        rts
@no:    clc
        rts

; -----------------------------------------------------------------------------
; do_gate - once a frame, inside the bracket, after cam_arrow.
; -----------------------------------------------------------------------------
do_gate:
        lda     GTON
        bne     @open
        jsr     gate_check
        bcs     :+
        rts                             ; closed, and it stays closed
:       jsr     gate_open

@open:  dec     GTACD                   ; the playlist, as foe_think_all ages a
        bne     @spin                   ;   foe's: a step holds EN_AHOLD frames
        ldy     #EA_GATE
        lda     EN_AHOLD,y
        sta     GTACD
        inc     GTAST
        lda     GTAST
        cmp     EN_AN,y
        bcc     @spin
        stz     GTAST
@spin:  clc
        lda     GTANL
        adc     #<GATE_SPIN
        sta     GTANL
        lda     GTANH
        adc     #>GATE_SPIN
        sta     GTANH

        sec                             ; P = gate - ship, and the wrap is free
        lda     GTXL
        sbc     SHXL
        sta     PXL
        lda     GTXH
        sbc     SHXH
        sta     PXH
        sec
        lda     GTYL
        sbc     SHYL
        sta     PYL
        lda     GTYH
        sbc     SHYH
        sta     PYH

        jsr     gate_arrive
        bcc     :+
        rts                             ; flown in: the screen takes over
:       jsr     gate_radar              ; the radar X, off the high bytes

        stz     GTFAR                   ; |P| past $3FFF on either axis: halve
        lda     PXH                     ;   (see FAR AND NEAR). A high byte in
        clc                             ;   $C0..$3F plus $40 stays positive
        adc     #$40
        bmi     @far
        lda     PYH
        clc
        adc     #$40
        bpl     @xf
@far:   inc     GTFAR
        lda     PXH
        cmp     #$80
        ror     PXH
        ror     PXL
        lda     PYH
        cmp     #$80
        ror     PYH
        ror     PYL
@xf:    jsr     view_xform
        lda     GTFAR
        bne     @norm
        jsr     zoom_fb
        jsr     gate_body               ; near: draw it, if it is on the screen
        bra     @arrow

@norm:  lda     VXH                     ; far: doubled until one axis is past
        bpl     :+                      ;   $3C00 - off every edge at any zoom,
        eor     #$FF                    ;   and still clear of zoom_fb's
:       cmp     #$3C                    ;   rounding add at $7FF8
        bcs     @big
        lda     VYH
        bpl     :+
        eor     #$FF
:       cmp     #$3C
        bcs     @big
        asl     VXL
        rol     VXH
        asl     VYL
        rol     VYH
        bra     @norm
@big:   jsr     zoom_fb

@arrow: jsr     ship_hidden             ; no ship drawn, nothing to point from
        bcs     @ret
        lda     CAMT                    ; an enemy arrow may be up: the two
        beq     :+                      ;   blink in turn, the gate's dark on
        lda     FRAME                   ;   the enemy's lit phase (cam_arrow)
        sec
        sbc     CAMTF
        and     #ARW_BLINK
        beq     @ret
:       jmp     arrow_fb                ; tail - it draws only if FX/FY is off
@ret:   rts                             ;   the screen

; -----------------------------------------------------------------------------
; gate_arrive - C SET when the ship has flown into the gate, and the screen is
; SC_SECTOR from the next frame. |P| < GATE_IN on both axes: P + GATE_IN read
; unsigned is below 2 * GATE_IN, whose low byte is 0.
; -----------------------------------------------------------------------------
gate_arrive:
        lda     SHIPGONE                ; a wreck does not arrive
        ora     GSTATE
        bne     @no
        clc
        lda     PXL
        adc     #<GATE_IN
        lda     PXH
        adc     #>GATE_IN
        cmp     #>(2 * GATE_IN)
        bcs     @no
        clc
        lda     PYL
        adc     #<GATE_IN
        lda     PYH
        adc     #>GATE_IN
        cmp     #>(2 * GATE_IN)
        bcs     @no
        lda     #SE_TELEPORT            ; the ship's own jump, the one shimmer
        jsr     sfx_fire                ;   the game already has for "gone"
        lda     #SC_SECTOR
        sta     SCR_STATE
        stz     SCR_PH
        stz     SCR_T
        sec
        rts
@no:    clc
        rts

; -----------------------------------------------------------------------------
; gate_body - one polygon per part of EA_GATE, at FX/FY, if it is near enough
; the screen to show. foe_body's loop, with the gate's own step and angle.
; -----------------------------------------------------------------------------
gb_off: rts
gate_body:
        clc                             ; FX + GR read unsigned below
        lda     FXL                     ;   400 + 2GR: on the screen, or near
        adc     #<GATE_GR               ;   enough that an arm reaches onto it
        tax
        lda     FXH
        adc     #>GATE_GR
        cpx     #<(400 + 2 * GATE_GR)
        sbc     #>(400 + 2 * GATE_GR)
        bcs     gb_off
        clc
        lda     FYL
        adc     #<GATE_GR
        tax
        lda     FYH
        adc     #>GATE_GR
        cpx     #<(300 + 2 * GATE_GR)
        sbc     #>(300 + 2 * GATE_GR)
        bcs     gb_off

        ldy     #EA_GATE                ; the frame's first row, as foe_anim
        lda     EN_ABASE,y
        clc
        adc     GTAST
        tax
        lda     EN_ANIM,x
        clc
        adc     EN_RBASE,y
        sta     GTROW
        stz     GTJ
@part:  lda     GTROW
        clc
        adc     GTJ
        tay
        lda     EN_PLO,y
        sta     SHPL
        lda     EN_PHI,y
        sta     SHPH
.if GATE_DOT
        lda     FXH                     ; the centre and the scale halved:
        cmp     #$80                    ;   DOT_POLYGON is half-res, and its
        ror     a                       ;   offsets are half-res px
        sta     PBUF+1
        lda     FXL
        ror     a
        sta     PBUF+0
        lda     FYH
        cmp     #$80
        ror     a
        sta     PBUF+3
        lda     FYL
        ror     a
        sta     PBUF+2
        lda     ZEASH
        lsr     a
.else
        lda     FXL
        sta     PBUF+0
        lda     FXH
        sta     PBUF+1
        lda     FYL
        sta     PBUF+2
        lda     FYH
        sta     PBUF+3
        lda     ZEASH
.endif
        sta     PBUF+5                  ; SCALE
        lda     GTANH                   ; ANGLE: its own, and the camera's
        sec
        sbc     HEAD
        sta     PBUF+4
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
.if GATE_DOT
        jsr     API_GPU_DOTPOLYGON
.else
        jsr     API_GPU_POLYGON16
.endif
        inc     GTJ
        ldy     #EA_GATE
        lda     GTJ
        cmp     EN_PN,y
        bcc     @part
        rts

; -----------------------------------------------------------------------------
; gate_radar - an X on the radar where the gate is, or on its rim toward it.
; -----------------------------------------------------------------------------
; radar_plot's own mapping, on the same high bytes. Out of reach the delta is
; taken down by an eighth at a time until it is inside GATE_RX, so the X sits
; on the rim in the gate's direction - and blinks there, with the enemies, to
; say it is further than it looks. Its own DOT_PIXELS, ahead of the radar's
; lists in the command list, and nothing while the instrument is down.
; -----------------------------------------------------------------------------
gate_radar:
        lda     RADDOWN
        beq     :+
        rts
:       lda     GTXH
        sec
        sbc     SHXH
        jsr     @fix
        sta     GTDX
        lda     GTYH
        sec
        sbc     SHYH
        jsr     @fix
        sta     GTDY
        stz     GTPIN

@fit:   lda     GTDX                    ; dx^2 + dy^2 against GATE_RX^2, off
        jsr     @sq                     ;   the quarter-square table
        sta     GTRX                    ;   (GTRX/GTRY as the sum's scratch)
        sty     GTRY
        lda     GTDY
        jsr     @sq
        clc
        adc     GTRX
        sta     GTRX
        tya
        adc     GTRY
        cmp     #>(GATE_RX * GATE_RX)
        bcc     @in
        bne     @out
        lda     GTRX
        cmp     #<(GATE_RX * GATE_RX)
        bcc     @in
        beq     @in
@out:   lda     GTDX                    ; d -= d >> 3, both axes
        jsr     @shrink
        sta     GTDX
        lda     GTDY
        jsr     @shrink
        sta     GTDY
        lda     #$01
        sta     GTPIN
        bra     @fit

@in:    lda     GTPIN                   ; on the rim: dark on the enemies' dark
        beq     :+                      ;   half of RBLINK
        lda     RBLINK
        cmp     #RAD_BLINK_ON
        bcc     :+
        rts
:       ldx     GTDX                    ; the rotation - radar_plot's, line for
        ldy     GTDY                    ;   line
        clc
        lda     ROTC_F,x
        adc     ROTS_F,y
        lda     ROTC_I,x
        adc     ROTS_I,y
        clc
        adc     #RAD_ROUND
        .repeat RAD_SH
        cmp     #$80
        ror     a
        .endrepeat
        sta     GTRY
        sec
        lda     ROTC_F,y
        sbc     ROTS_F,x
        lda     ROTC_I,y
        sbc     ROTS_I,x
        clc
        adc     #RAD_ROUND
        .repeat RAD_SH
        cmp     #$80
        ror     a
        .endrepeat
        clc
        adc     #RADCX
        sta     GTRX
        sec
        lda     #RADCY
        sbc     GTRY
        sta     GTRY

        ldx     #$00                    ; the X: GTR_N dots round its centre
        ldy     #$01
@pt:    lda     GTRX
        clc
        adc     GX_DX,x
        sta     GTRB,y
        iny
        lda     GTRY
        clc
        adc     GX_DY,x
        sta     GTRB,y
        iny
        inx
        cpx     #GTR_N
        bne     @pt
        lda     #GTR_N
        sta     GTRB
        lda     #<GTRB
        sta     OS_ARG+0
        lda     #>GTRB
        sta     OS_ARG+1
        jmp     API_GPU_DOTPIXELS       ; tail

; A = a signed high-byte delta; -128 has no magnitude in a byte, so it is -127.
@fix:   cmp     #$80
        bne     :+
        inc     a
:       rts

; A = a signed byte d: A/Y = d*d, low/high, as f(2|d|).
@sq:    bpl     :+
        eor     #$FF
        inc     a
:       asl     a
        tax
        lda     QSL,x
        ldy     QSH,x
        rts

; A = d: d - (d >> 3), arithmetic, so -1 goes to 0 and the loop ends.
@shrink:
        sta     GTJ
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        eor     #$FF                    ; d + ~(d >> 3) + 1 = d - (d >> 3)
        sec
        adc     GTJ
        rts

; The X: its centre and two dots out along each diagonal, half-res.
GX_DX:  .byte   0,  1,  2, <-1, <-2,  1,  2, <-1, <-2
GX_DY:  .byte   0,  1,  2, <-1, <-2, <-1, <-2,  1,  2
        .assert GX_DY - GX_DX = GTR_N, error, "gate.s: GTR_N no longer counts the X's dots"

        .segment "MSGDATA"          ; was CODE6 - see hud_game.s's
                                    ;   msg_open/msg_close
IM_GATE_S:  .byte   "EXIT GATE OPEN", 0
        .segment "CODE6"

; -----------------------------------------------------------------------------
; sector_frame - the whole frame while SCR_STATE is SC_SECTOR (screens.s).
; -----------------------------------------------------------------------------
; The intro's opening, and then text on the IMAGE, reissued every frame: black,
; SECTOR COMPLETED, and after SEC_ARM frames a blinking PUSH FIRE that loads
; the next sector. THIS SCREEN IS THE SEAM THE TUNNEL GOES INTO: when the
; flight between sectors exists, it is this state's frame, and FIRE here
; becomes the tunnel's end.
; -----------------------------------------------------------------------------
sector_frame:
        lda     SCR_PH
        bne     @p1
        lda     #VR_BLIND_ON            ; step 0: dark, and the field, the radar
        jsr     API_GPU_VREG            ;   ring and the HUD off the background
        jsr     API_GPU_CLEARBG
        bra     @next
@p1:    cmp     #1                      ; step 1: the clear's replay lands
        bne     @p2
        inc     SCR_T
        lda     SCR_T
        cmp     #SETTLE
        bcc     @ret
        lda     #VR_BLIND_OFF
        jsr     API_GPU_VREG
        bra     @next

@p2:    lda     #SEC_COL                ; step 2: the words, every frame
        ldx     #SEC_LINE
        ldy     #$00
        jsr     @text
        lda     SCR_T
        cmp     #SEC_ARM
        bcs     @armed
        inc     SCR_T
        rts
@armed: lda     FRAME                   ; PUSH FIRE, 32 frames lit, 32 dark
        and     #$20
        bne     @fire
        lda     #SEC_PFCOL
        ldx     #SEC_PFLINE
        ldy     #$01
        jsr     @text
@fire:  ldx     JOYPORT
        lda     JOY1_PRESS,x
        and     #JOY_FIRE
        beq     @ret
        lda     JOY1_PRESS,x            ; consume the edge, or the press that
        and     #<~JOY_FIRE             ;   ends the screen also fires the gun
        sta     JOY1_PRESS,x            ;   on the next sector's first frame
        ldx     CURLEV                  ; the next sector - round to the first
        inx                             ;   after the last, while there is only
        cpx     #NLEVELS                ;   one
        bcc     :+
        ldx     #$00
:       stx     CURLEV
        jsr     win_off                 ; level_begin walks the object pool
        jsr     level_begin
        jsr     win_on
        stz     BGDONE                  ; ...and the flight's first frame puts
        stz     SCR_STATE               ;   the radar's ring and the HUD back
@ret:   rts                             ;   (cart_frame)

@next:  inc     SCR_PH
        stz     SCR_T
        rts

; A = cell, X = line, Y = which string.
@text:  sta     OS_ARG+0
        stx     OS_ARG+1
        stz     OS_ARG+2
        lda     sec_lo,y
        sta     OS_ARG+3
        lda     sec_hi,y
        sta     OS_ARG+4
        jmp     API_GPU_VTEXT

sec_lo:     .byte   <sec_s1, <sec_s2
sec_hi:     .byte   >sec_s1, >sec_s2

sec_s1:     .byte   "SECTOR COMPLETED", 0
sec_s1_end:
sec_s2:     .byte   "PUSH FIRE", 0
sec_s2_end:

        .popseg
