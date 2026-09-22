; =============================================================================
; pickup.s - the laser and the shield, dropped by a kill and absorbed on arrival
; =============================================================================
; design_technical.md 11.47. A killed PULSAR drops the laser while the player
; has not TAKEN one (LSRHAVE: a laser still in flight does not count, so two
; pulsars killed by one EMP drop two); every killed SPIDER drops the shield;
; every killed EMP MINE (empmine.s) drops the EMP itself, the same way and
; gated the same way (EMPHAVE) - the weapon does not exist for the player
; until one is found, exactly like the laser (emp.s emp_input checks it).
; A pulsar's beam killing one pays nobody (FOEKILL) and drops nothing either.
;
; A PICKUP IS A SATURNIUM MOTE WITH ANOTHER TAG. It lives in satn.s's pool, is
; steered by the same pull from the frame it drops, at any distance, and is
; taken on arrival - so nothing here moves anything. Only two things differ: it
; is drawn as a sprite and not a dot (pk_draw, from do_satn's walk), and its
; arrival does something (pk_arrive, from satp_arrive). The tag's top three
; bits (SPT_MASK, satn.s) are SPT_LASER, SPT_SHIELD or SPT_EMP; bit 7 set is
; "a pickup", bits 6-5 the kind - widened from one bit to two when the EMP
; mine needed a third kind, at the cost of one bit of SATP_AGE (satn.s).
;
; TWO AT ONCE, in pool slots 0 and 1. satn_kill takes free slots from the top
; down, so these are the last a cloud of motes reaches; a pickup takes one that
; is free or holds a mote (feedback only), and with both holding pickups it
; replaces the OLDER, by the slot's age.
;
; THE SPRITE: ONE for every pickup, whatever it holds - its size and its
; animation are the art's (PK_W x PK_HEIGHT, PK_FRAMES, tools/pickupgen.py),
; overlay, never scaled (the same size at every zoom), a frame every PK_HOLD
; game frames. The art is PK_PAGES GPU pages, kept in the sprite bank (SPRART),
; so it costs no CPU RAM: it goes to the GPU with the other sprites' at
; power-on, and its PK_FRAMES slots sit in the definition pages behind the
; arrows' (sprites.s).
; =============================================================================

PK_SLOT0    = ARW_SLOT0 + 4     ; the frames' slots, after the arrows
PK_PAGE     = $13               ; GPU RAM page (arrows $12), and PK_PAGES on
PK_HOLD     = 6                 ; game frames each animation frame is shown
PK_SLOW     = 1                 ; FRAME mask: it takes its step one frame in
                                ;   PK_SLOW+1 and drifts with the ship on the
                                ;   others, so it closes at 1/(PK_SLOW+1) of a
                                ;   mote's speed - see satn.s do_satn

; --- state: $73AF-$73B4, behind hud_game.s's MSGSAVE. Always mapped: laser.s
;     reads LSRHAVE outside any bracket, and emp.s reads EMPHAVE the same way.
;     $73B5 is the next free byte; levels.s's LVSAVE follows at $73B6 and the
;     assert below is what keeps this block from walking into it again ---
LSRHAVE     = $73AF             ; nonzero once a laser has been TAKEN. A new
                                ;   game (continue included) clears it; a lost
                                ;   ship and a sector keep it
PKANI       = $73B0             ; frames left on this animation frame
PKPH        = $73B1             ; the animation's frame, 0 .. PK_FRAMES-1
PKT         = $73B2             ; pk_spawn's tag
PKAGE       = $73B3             ; ...and slot 0's age, to compare
EMPHAVE     = $73B4             ; nonzero once the EMP has been TAKEN - the
                                ;   same door LSRHAVE is for the laser
        .assert MSGSAVE = LSRHAVE - 1 && EMPHAVE < LVSAVE, error, "pickup.s: the block no longer fits between MSGSAVE and levels.s's LVSAVE"
        .assert SPT_LASER & $80 && SPT_SHIELD & $80 && SPT_EMP & $80 && (SPT_SATN & $80) = 0, error, "pickup.s: bit 7 of the tag is 'a pickup'"

        .pushseg
        .segment "CODE4"                ; the run area, not DEMO_RAM: DEMO_RAM
                                        ;   was down to 8 bytes when the
                                        ;   pickup's half-rate step (satn.s)
                                        ;   needed room, and this file asks
                                        ;   nothing of DEMO_RAM

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
        beq     @laser
        cmp     #FK_EMPMINE
        bne     @no
        lda     EMPHAVE                 ; the EMP, while it is not in hand
        bne     @no
        lda     #SPT_EMP
        bra     pk_spawn
@laser: lda     LSRHAVE                 ; the laser, while it is not in hand
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
; pk_arrive - satn.s satp_arrive: A = the tag, SPT_LASER, SPT_SHIELD or
; SPT_EMP. Heard as a mote's landing, with the ring's breath, and then what
; it is.
; -----------------------------------------------------------------------------
pk_arrive:
        pha
        lda     #$01
        sta     SATHMP
        lda     #SE_SATN
        jsr     sfx_fire
        pla
        cmp     #SPT_SHIELD
        beq     @shield
        cmp     #SPT_EMP
        beq     @emp
        lda     #$01                    ; else: the laser
        sta     LSRHAVE
        lda     #IM_LASER_GOT
        jmp     indicate_msg            ; tail
@shield:jmp     shield_on               ; tail: SHIELD ENABLED
@emp:   lda     #$01
        sta     EMPHAVE
        sta     EMPRDY                  ; ...and the hold's own line is SAID: this
                                        ;   path fills the hold itself, one line
                                        ;   below, so emp_ready (emp.s) would
                                        ;   otherwise queue EMP AVAILABLE straight
                                        ;   behind EMP ACQUIRED - the same fact,
                                        ;   twice, two seconds apart
        lda     #SATN_FULL              ; charged and ready: the hold too
        sta     SATN
        lda     #IM_EMP_GOT
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
        lda     PKPH                    ; ...and the next frame: 0, 1, ... and
        inc     a                       ;   round to 0 again
        cmp     #PK_FRAMES
        bcc     @set
        lda     #$00
@set:   sta     PKPH
:       rts

        .assert PK_PAGE + PK_PAGES <= $14 + 1, error, "pickup.s: the art runs past GPU page $14"
        .assert PK_FRAMES >= 1 && PK_FRAMES * PK_BYTES <= PK_PAGES * 256, error, "pickup.s: the frames do not fit the pages they claim"

        .segment "SPRART"               ; the art - GENERATED, tools/pickupgen.py -
        .align  256                     ;   is not RAM's: it sits in a ROM bank and
        .include "pickups_art.s"        ;   goes to the GPU in bulk at power-on
        .align  256                     ;   (sprites.s). PK_PAGES pages.

        .segment "MSGDATA"
IM_LASER_GOT_S: .byte "LASER ACQUIRED", 0
IM_EMP_GOT_S:   .byte "EMP ACQUIRED", 0

        .popseg
