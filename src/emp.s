; =============================================================================
; emp.s - the EMP: a ring off the ship that kills every enemy it reaches
; =============================================================================
; open_questions F8. Enemies only - it never touches a rock, which is the whole
; point of it next to the gun and the laser.
;
; THE TRIGGER. FIRE1 and FIRE2 held together, on the frame the second of them
; goes down (emp_input, from do_input, BEFORE do_fire2). It costs SATN_EMP_COST
; Saturnium, which is SATN_FULL: the hull's spark ring already flashes at that
; charge, so "the EMP is armed" has a readout without one byte of new drawing.
; Short of it the chord buys nothing, and says EMP NOT AVAILABLE on the message
; bar - nothing is taken off the hold.
;
; IT DOES NOT EXIST until EMPHAVE (pickup.s) is set - a killed EMP mine
; (empmine.s) drops it, the same door the laser is behind (LSRHAVE). Missing
; it reads exactly like short of Saturnium: EMP NOT AVAILABLE, one message for
; both, no new string.
;
; The chord eats both edges it was made of. FIRE2's is the easy one: a single
; FIRE2 click is only a weapon change once TPCLICK_FRAMES have passed without a
; second (input.s do_fire2), so a pending click (TPWIN) is simply cancelled and
; TPLOCK is armed as after a teleport. FIRE1's edge is cleared out of JOYINP
; before do_shots can read it - but only THIS frame's: a FIRE1 that went down a
; frame before FIRE2 has already fired its bullet, or lit the laser and paid for
; it, and nothing can take that back. So with the laser armed and the hold at
; 200-207, FIRE2 first.
;
; THE RING is a SCREEN circle and knows nothing about the world: one DOT_CIRCLE
; ($FF27, half-res centre and radius) about the ship's drawn centre, FLCX/FLCY
; halved, the radius the effect's own frame counter shifted:
;
;       n = EMPN = 1 .. EMP_FRAMES ;   R = n << EMP_RSH  half-res px
;
; 16 full-res px a frame, 248 half-res at the end. It has to be that big
; because the SHIP IS NOT IN THE MIDDLE OF THE SCREEN: at speed it sits up to
; 126 px below it (design_technical 11.33), the camera leans 80 px into a turn
; (11.34), and the far corner is then ~400 full-res px away. The first cut
; stopped at 128 half-res - the half-diagonal from the MIDDLE - and a madsim
; dump caught a pulsar on the screen, near its top edge, 33 pages from a fast
; ship: out of reach, and it lived. Nothing is scaled, projected or zoomed.
;
; THE KILL is every live enemy - a mounted spider included, hit points ignored,
; on the screen or not, awake or asleep - whose position is inside
; K = n << EMP_KSH in POSITION HIGH-BYTE units (256 world units) of the ship's.
; The radar's own round test (radar.s radar_plot): one SBC an axis on high
; bytes, so the wrap is free, the box first, then dx^2 + dy^2 <= K^2 from the
; quarter-square table. No multiply, no zoom. One unit is 4 half-res px at the
; 2x zoom-out, so there K and the ring are the SAME circle, frame for frame, out
; to 62 pages - 496 full-res px, past every corner. At 1:1 the kill runs twice
; the ring's pace, off the screen. A kill is foe_kill's, as
; from any weapon: SCORE_FOE_KILL, the boom and the screech, the flash, the
; shake, the wreck. It pays
; for the death only - there is no hit to pay for, and no skill in one.
;
; Distant enemies die on later frames, so a crowd's wrecks spawn over half a
; second rather than in one frame.
;
; WHERE IT LIVES. CODE6, behind the pulsar, in DEMO_RAM (cart.cfg). Its state
; is under the window behind satn.s's, so it is only touched inside cart_frame's
; bracket - do_input, do_emp and game_start all are.
; =============================================================================

; --- tunables - open_questions F8 --------------------------------------------
SATN_EMP_COST = 200             ; the price: SATN_FULL, a full hold
EMP_FRAMES  = 31                ; frames the ring grows: 0.51 s
EMP_RSH     = 3                 ; R = n << 3 half-res px - 16 full-res a frame
EMP_KSH     = 1                 ; K = n << 1 pages - the ring's own pace at the
                                ;   2x zoom-out, where a page is 4 half-res px

        .assert SATN_EMP_COST = SATN_FULL, error, "emp.s: the ring's flash at SATN_FULL is the EMP's readout - move them together"
        .assert EMP_FRAMES << EMP_RSH <= 255, error, "emp.s: DOT_CIRCLE's R is one byte"
        .assert EMP_FRAMES << EMP_KSH <= 63, error, "emp.s: the round test indexes QSL by 2K, and |d| must stay a positive byte"

; --- state: under the window, behind satn.s ------------------------------------
EMPN        = SATP_END          ; frames of ring so far, 0 = no EMP
EMT0        = SATP_END + 1      ; the round test's 16-bit sum
EMT1        = SATP_END + 2
EMDX        = SATP_END + 3      ; |dx| of the enemy being tested, high bytes
EMK         = SATP_END + 4      ; this frame's kill radius K, high bytes
EMP_END     = SATP_END + 5
        .assert EMP_END <= SHAPES_AT, error, "emp.s: past the RAM under the window"

        .pushseg
        .segment "CODE6"

; -----------------------------------------------------------------------------
; emp_input - do_input, before do_fire2. The chord, or nothing.
; -----------------------------------------------------------------------------
emp_input:
        lda     JOYIN
        and     #JOY_FIRE|JOY_FIRE2
        cmp     #JOY_FIRE|JOY_FIRE2
        bne     @no                     ; not both held
        lda     JOYINP
        bit     #JOY_FIRE|JOY_FIRE2
        beq     @no                     ; both held, but no new edge: done already
        and     #<~(JOY_FIRE|JOY_FIRE2) ; ...and neither edge is anything else:
        sta     JOYINP                  ;   no bullet, no beam, no click
        stz     TPWIN                   ; a FIRE2 still waiting to be a weapon
        lda     #TPLOCK_FRAMES          ;   change is not one
        sta     TPLOCK
        lda     EMPHAVE                 ; not found yet (pickup.s): same as
        beq     @short                  ;   short of Saturnium, below
        lda     EMPN
        bne     @no                     ; a ring is still growing: one at a time
        lda     #SATN_EMP_COST
        jsr     satn_spend
        bcc     @short
        lda     #1
        sta     EMPN
        lda     #SE_EMP
        jmp     sfx_fire                ; tail
@short: lda     #IM_EMP_NA              ; nothing spent - and it says so, now,
        jmp     indicate_urgent         ;   not behind a HULL BREACH (tail)
@no:    rts

; -----------------------------------------------------------------------------
; do_emp - once a frame, after do_satn (FLCX/FLCY are this frame's), inside the
; bracket: this frame's kills, then this frame's ring.
; -----------------------------------------------------------------------------
do_emp:
        lda     EMPN
        bne     :+
        rts
:       stz     FOEKILL                 ; the ship's kills: paid
        lda     EMPN                    ; K, this frame's reach in pages
        .repeat EMP_KSH
        asl     a
        .endrepeat
        sta     EMK
        lda     NFOE
        beq     @ring
        dec     a
        sta     FEI                     ; FEI, because foe_kill reads it
@lp:    ldx     FEI
        lda     FOEST,x
        beq     @next                   ; FS_DEAD - and FS_MOUNTED is NOT skipped
        lda     FOEXH,x                 ; the box, on high bytes
        sec
        sbc     SHXH
        jsr     absa
        cmp     EMK
        beq     :+
        bcs     @next
:       sta     EMDX
        lda     FOEYH,x
        sec
        sbc     SHYH
        jsr     absa
        cmp     EMK
        beq     :+
        bcs     @next
:       asl     a                       ; ...then the circle: f(2a) = a*a
        tay
        ldx     EMDX
        txa
        asl     a
        tax
        clc
        lda     QSL,x
        adc     QSL,y
        sta     EMT0
        lda     QSH,x
        adc     QSH,y
        sta     EMT1
        lda     EMK
        asl     a
        tax
        lda     QSL,x                   ; K*K - the rim is inside
        cmp     EMT0
        lda     QSH,x
        sbc     EMT1
        bcc     @next
        jsr     foe_kill                ; FEI's, whatever its hit points
@next:  dec     FEI
        bpl     @lp

@ring:  lda     FLCXH                   ; the drawn centre, half-res: on the
        lsr     a                       ;   screen, so a byte each
        lda     FLCXL
        ror     a
        sta     OS_ARG+0
        lda     FLCYH
        lsr     a
        lda     FLCYL
        ror     a
        sta     OS_ARG+1
        lda     EMPN
        .repeat EMP_RSH
        asl     a
        .endrepeat
        sta     OS_ARG+2
        jsr     API_GPU_DOTCIRCLE
        lda     EMPN
        inc     a
        cmp     #EMP_FRAMES+1
        bcc     :+
        lda     #$00                    ; grown out: the EMP is over
:       sta     EMPN
        rts

; --- the sound programs --------------------------------------------------------
; sfx.s's rows point here: UPPER, where the rest of the programs are, has no
; room left, and DEMO_RAM is as good a home for them - always mapped, full
; speed, so the IRQ that plays them reads the right bytes whatever the frame
; left in the window. The format and the voices are sfx.s's.

; SE_SCREECH - an enemy died (foes.s foe_kill, from any weapon), over the
; rock's boom it also gets. A creature, not only a rock: a shriek that warbles
; high - one-frame steps alternating too fast to hear as notes, the trick
; se_death tears with - and sags as it goes. On VOICE_ROCK at PRI_BOOM: it
; outranks the taps and the UFO alarm there, and two deaths in a row are two
; shrieks. 16 frames = LEN_SCREECH.
se_screech:
        .byte   $00                     ; tone
        .byte   1, 101, 11
        .byte   1, 94, 11
        .byte   1, 103, 10
        .byte   1, 95, 10
        .byte   1, 100, 10
        .byte   1, 91, 9
        .byte   2, 96, 8
        .byte   2, 87, 7
        .byte   2, 90, 5
        .byte   4, 81, 2
        .byte   $FF                     ; 16 frames - keep LEN_SCREECH in step

; SE_EMP - the EMP went off. A discharge: a drop from the top of the range to
; the floor, fast where the ring is small and slowing as it widens, dying on the
; engine's lowest note as the ring leaves the screen. Authored to EMP_FRAMES, so
; the sound and the ring end together. VOICE_SHIP at PRI_KLANG, so a ram in the
; middle of it does not cut it.
se_emp:
        .byte   $00                     ; tone
        .byte   1, 108, 13
        .byte   1, 96, 12
        .byte   1, 84, 12
        .byte   2, 72, 11
        .byte   2, 62, 10
        .byte   3, 54, 9
        .byte   4, 49, 7
        .byte   6, 46, 5
        .byte   8, 45, 3
        .byte   3, 45, 1
        .byte   $FF                     ; 31 frames = EMP_FRAMES
        .assert EMP_FRAMES = 31, error, "emp.s: se_emp is authored to EMP_FRAMES = 31"

        .segment "MSGDATA"          ; was CODE6 - see hud_game.s's
                                    ;   msg_open/msg_close
IM_EMP_NA_S: .byte  "EMP NOT AVAILABLE", 0

        .popseg
