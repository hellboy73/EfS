; =============================================================================
; pickup.s - the laser and the shield, dropped by a kill and absorbed on arrival
; =============================================================================
; design_technical.md 11.47. A killed PULSAR drops the laser while the player
; has not TAKEN one (LSRHAVE: a laser still in flight does not count, so two
; pulsars killed by one EMP drop two); every killed SPIDER drops the shield.
; A pulsar's beam killing one pays nobody (FOEKILL) and drops nothing either.
;
; A PICKUP IS A SATURNIUM MOTE WITH ANOTHER TAG. It lives in satn.s's pool, is
; steered by the same pull from the frame it drops, at any distance, and is
; taken on arrival - so nothing here moves anything. Only two things differ: it
; is drawn as a sprite and not a dot (pk_draw, from do_satn's walk), and its
; arrival does something (pk_arrive, from satp_arrive). The tag's bits 7-6 are
; SPT_LASER or SPT_SHIELD; bit 7 set is "a pickup", and bit 6 is the kind.
;
; TWO AT ONCE, in pool slots 0 and 1. satn_kill takes free slots from the top
; down, so these are the last a cloud of motes reaches; a pickup takes one that
; is free or holds a mote (feedback only), and with both holding pickups it
; replaces the OLDER, by the slot's age.
;
; THE SPRITE: ONE for every pickup, whatever it holds - its size is the art's
; (PK_W x PK_HEIGHT, tools/pickupgen.py), overlay, never scaled (the same size
; at every zoom), two frames flipped every PK_HOLD frames. The art is PK_PAGES
; GPU pages read straight out of the MSGDATA bank (gpu_load_cart), so it costs
; no CPU RAM: the art upload's steps after the arrows' (cam.s
; upload_art_step), and pk_defs puts its two slots into the definition pages
; behind the arrows'.
; =============================================================================

PK_SLOT0    = ARW_SLOT0 + 4     ; the two frames, after the arrows
PK_PAGE     = $13               ; GPU RAM page (arrows $12), and PK_PAGES on
PK_HOLD     = 10                ; frames each animation frame is shown
PK_ART_STEP = 6                 ; FLSTEP of its first page: after the arrows'

; --- state: $73AF-$73B3, behind hud_game.s's MSGSAVE. Always mapped: laser.s
;     reads LSRHAVE outside any bracket ------------------------------------------
LSRHAVE     = $73AF             ; nonzero once a laser has been TAKEN. A new
                                ;   game (continue included) clears it; a lost
                                ;   ship and a sector keep it
PKANI       = $73B0             ; frames left on this animation frame
PKPH        = $73B1             ; the frame, 0 or 1
PKT         = $73B2             ; pk_spawn's tag
PKAGE       = $73B3             ; ...and slot 0's age, to compare
        .assert MSGSAVE = LSRHAVE - 1 && PKAGE < WINSAVE, error, "pickup.s: the block no longer fits between MSGSAVE and WINSAVE"
        .assert SPT_LASER & $80 && SPT_SHIELD & $80 && (SPT_SATN & $80) = 0, error, "pickup.s: bit 7 of the tag is 'a pickup'"

        .pushseg
        .segment "CODE6"

; -----------------------------------------------------------------------------
; pk_drop - foes.s foe_kill, FEI dying, EXTX/EXTY its position (expl_at's).
; -----------------------------------------------------------------------------
pk_drop:
        lda     FOEKILL                 ; another pulsar's beam: nobody's kill
        bne     @no
        ldx     FEI
        lda     FOEKIND,x
        cmp     #FK_SPIDER
        beq     @shield
        cmp     #FK_PULSAR
        bne     @no
        lda     LSRHAVE                 ; the laser, while it is not in hand
        bne     @no
        lda     #SPT_LASER
        bra     pk_spawn
@no:    rts
@shield:lda     #SPT_SHIELD
        ; fall through
; pk_spawn - A = the tag: a pickup at EXTX/EXTY, at rest relative to the ship.
pk_spawn:
        sta     PKT
        ldy     #$00                    ; slot 0 or 1, whichever is not a pickup
        lda     SATPT
        bpl     @take
        iny
        lda     SATPT+1
        bpl     @take
        lda     SATPT                   ; both are: the older goes
        and     #SATP_AGE
        sta     PKAGE
        lda     SATPT+1
        and     #SATP_AGE
        cmp     PKAGE
        bcs     @take                   ; slot 1 is as old or older
        dey
@take:  lda     PKT
        sta     SATPT,y
        lda     #$00
        sta     SATPVX,y
        sta     SATPVY,y
        lda     EXTXL
        sta     SATPXL,y
        lda     EXTXH
        sta     SATPXH,y
        lda     EXTYL
        sta     SATPYL,y
        lda     EXTYH
        sta     SATPYH,y
        rts

; -----------------------------------------------------------------------------
; pk_arrive - satn.s satp_arrive: A = the tag, SPT_LASER or SPT_SHIELD. Heard
; as a mote's landing, with the ring's breath, and then what it is.
; -----------------------------------------------------------------------------
pk_arrive:
        pha
        lda     #$01
        sta     SATHMP
        lda     #SE_SATN
        jsr     sfx_fire
        pla
        cmp     #SPT_SHIELD
        bne     :+
        jmp     shield_on               ; tail: SHIELD ENABLED
:       lda     #$01
        sta     LSRHAVE
        lda     #IM_LASER_GOT
        jmp     indicate_msg            ; tail

; -----------------------------------------------------------------------------
; pk_draw - satn.s do_satn: X = a pickup's slot, FX/FY its full-res screen
; centre. The sprite, centred there; the GPU clips it. Clobbers A.
; -----------------------------------------------------------------------------
pk_draw:
        lda     PKPH                    ; the frame
        clc
        adc     #PK_SLOT0
        sta     OS_ARG+0
        sec
        lda     FXL
        sbc     #PK_W / 2
        sta     OS_ARG+1
        lda     FXH
        sbc     #$00
        sta     OS_ARG+2
        sec
        lda     FYL
        sbc     #PK_HEIGHT / 2
        sta     OS_ARG+3
        lda     FYH
        sbc     #$00
        sta     OS_ARG+4
        jmp     API_GPU_SPRITE          ; tail

; -----------------------------------------------------------------------------
; pk_tick - satn.s do_satn, once a frame: the animation's clock.
; -----------------------------------------------------------------------------
pk_tick:
        dec     PKANI
        bpl     :+
        lda     #PK_HOLD-1
        sta     PKANI
        lda     PKPH
        eor     #$01
        sta     PKPH
:       rts

; -----------------------------------------------------------------------------
; pk_upload - cam.s upload_art_step, FLSTEP just counted past PK_ART_STEP + n:
; the art's page n, straight out of the MSGDATA bank. A frame with no PPRAM
; left for it tries again on the next.
; -----------------------------------------------------------------------------
pk_upload:
        lda     FLSTEP
        sec
        sbc     #PK_ART_STEP + 1        ; n
        tax
        clc
        adc     #>pickups_data
        sta     OS_ARG+2
        lda     #<pickups_data
        sta     OS_ARG+1
        txa
        clc
        adc     #PK_PAGE
        sta     OS_ARG+3
        lda     #MSG_BANK
        sta     OS_ARG+0
        jsr     API_GPU_LOAD_CART
        bcc     :+
        dec     FLSTEP
:       rts

; pk_defs - cam.s arrow_defs, X = the definition page being staged (0 TYPE,
; 1 PTR_LSB, 2 PTR_MSB, 3 HEIGHT): the pickup's two slots into DEFPG. Keeps X.
pk_defs:
        phx
        txa
        asl     a
        tax
        lda     PK_DEF,x
        sta     DEFPG+PK_SLOT0
        lda     PK_DEF+1,x
        sta     DEFPG+PK_SLOT0+1
        plx
        rts

PK_DEF:     .byte   PK_TYPE, PK_TYPE    ; by field, then frame
            .byte   <PK_OFF0, <PK_OFF1
            .byte   PK_PAGE + >PK_OFF0, PK_PAGE + >PK_OFF1
            .byte   PK_HEIGHT, PK_HEIGHT
        .assert PK_PAGE + PK_PAGES <= $14 + 1, error, "pickup.s: the art runs past GPU page $14"

        .segment "MSGDATA"
        .include "pickups_art.s"        ; the art - GENERATED, tools/pickupgen.py
IM_LASER_GOT_S: .byte "LASER ACQUIRED", 0

        .popseg
