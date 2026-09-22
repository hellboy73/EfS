; =============================================================================
; empmine.s - the EMP MINE: a static trap that spins up and discharges
; =============================================================================
; A new KIND for foes.s (FK_EMPMINE); the shape and appearance are already in
; enemies.s (EA_EMP_MINE). It never moves - a level places it and it stays -
; and everything it does turns on FOEANG, which foe_body already applies to
; every foe's draw for nothing (foes.s FOEANG's own comment), so the spin
; costs no drawing code at all.
;
; IDLE it turns slowly (EMPM_SPIN a frame) and watches, on its own think
; cadence (foe_think's near/far phase, same as any foe), for the ship inside
; EMPM_RP - foe_dist's own approximate distance (foes.s), compared on the high
; byte alone against EMPM_RP PAGES (256 world units each, emp.s's own unit).
;
; CHARGING (FS_PURSUE, reused - foe_alarm and cam.s already treat it as "seen"
; for free, the same trick spider_watch plays) the spin RATE itself ramps up
; linearly from 0 to EMPM_SPIN_MAX (45 degrees/frame) over EMPM_CHARGE frames
; - an 8.8 fixed-point accumulator (EMACL/EMACH), pulsar.s's own FOEANGF
; trick, so it is exact ADDS, never a multiply. The cap at EMPM_SPIN_MAX
; matters on its own terms too: past it the three arms cross each other
; within one frame and the eye reads that as the spin STALLING, not going
; faster (the user, 2026-09-22) - EMPM_SPIN_MAX stays under half an arm's
; spacing (256/3) on purpose. It COMMITS once charging: nothing cancels it
; early, whatever the ship does.
;
; AT 0 it fires: the ship pays EMPM_DMG FLAT if it is within EMPM_RP -
; ship_hurt_raw (physics.s), which skips both the Saturnium armour and the
; shield on purpose (the user, 2026-09-22): this blast ignores both, unlike
; every other hit the ship takes. foe_dist is reused a second time for the
; test. Every OTHER enemy within EMPM_RP of the MINE dies outright -
; emp.s's do_emp own exact circle test (the quarter-square table), just
; re-centred on the mine instead of the ship.
;
; THEN IT SLOWS DOWN: back to FS_PATROL, but the SAME rate accumulator now
; eases back DOWN to EMPM_SPIN over the next EMPM_COOLDOWN frames - the
; mirror of the charge-up, not an instant snap to idle. Only once that is
; over can it detect the ship again: the whole cycle, charge plus cooldown,
; is EMPM_CHARGE + EMPM_COOLDOWN frames (the user, 2026-09-22: 90 + 90 =
; 180), and a mine that stays armed re-fires on a lingering ship rather than
; staying spent.
;
; THE RING (empm_ring) draws the SAME growing DOT_CIRCLE the ship's own EMP
; does (emp.s do_emp), just for fewer frames - "like my EMP, only limited
; range" (the user, 2026-09-22) - not the true blast radius, EMPM_RP, which
; a look at emp.s shows was never what the ship's own ring drew either.
;
; SHOT DOWN (EMPM_HP, ordinary hits) instead of going off, it drops the EMP
; pickup exactly as a pulsar drops the laser - see pickup.s.
;
; WHERE IT LIVES. CODE7, UPPER RAM: the tightest of the code homes had more
; room here than DEMO_RAM did. Its only new state is under the window,
; chained after base.s's (foes.s's own chain) - empm_fire's working scratch,
; borrowed once per detonation.
; =============================================================================

; --- tunables, TBM - the user's first guess, all in one place to retune ------
EMPM_HP       = 60              ; ordinary hits before it drops the pickup
                                 ;   instead of ever going off
EMPM_DMG      = 25              ; hull cost of a hit, FLAT - ship_hurt_raw
                                 ;   (physics.s) skips the Saturnium armour
                                 ;   and the shield on purpose (the user,
                                 ;   2026-09-22)
EMPM_RP       = 16              ; detection AND blast radius, in PAGES (256
                                 ;   world units each - emp.s's own EMK unit).
                                 ;   4,096 world units, under FOE_SEE's 6,400 -
                                 ;   shrunk from 50 (the user, 2026-09-22: it
                                 ;   was reaching most of the field)
EMPM_CHARGE   = 90              ; game frames from detection to firing - 1.5 s
                                 ;   at 60.317 Hz (the user, 2026-09-22; was
                                 ;   121, then 30)
EMPM_COOLDOWN = 90              ; frames the slowdown takes, then idle until
                                 ;   it can detect again - the whole cycle is
                                 ;   EMPM_CHARGE + EMPM_COOLDOWN, 180 frames
                                 ;   (the user, 2026-09-22)
EMPM_SPIN     = 2               ; FOEANG a frame, idle - and the floor the
                                 ;   cooldown's ease-down lands on
EMPM_SPIN_MAX = 32              ; ...and the charge's ceiling: 45 degrees a
                                 ;   frame (256 = 360 degrees) - past this the
                                 ;   three arms cross each other within one
                                 ;   frame and the spin reads as STALLED, not
                                 ;   fast (the user, 2026-09-22) - 256/3 is one
                                 ;   arm's spacing, and this sits well under
                                 ;   half of it
EMPM_RAMP_UP  = 91              ; the rate's own step while charging, 8.8
                                 ;   fixed (EMACL/EMACH below): 0 to
                                 ;   EMPM_SPIN_MAX linearly over EMPM_CHARGE
                                 ;   frames, exact ADDS only (pulsar.s's
                                 ;   FOEANGF trick), no multiply -
                                 ;   EMPM_SPIN_MAX*256/EMPM_CHARGE rounded
EMPM_RAMP_DN  = 85              ; ...and while cooling down, the mirror:
                                 ;   EMPM_SPIN_MAX easing back to EMPM_SPIN
                                 ;   over EMPM_COOLDOWN frames -
                                 ;   (EMPM_SPIN_MAX-EMPM_SPIN)*256/EMPM_COOLDOWN
                                 ;   rounded
EMPM_RING_FRAMES = 12            ; frames the ring grows for - emp.s's own
                                 ;   EMP_FRAMES (31) shortened: "like my EMP,
                                 ;   only limited range" (the user, 2026-09-22)
EMPM_RSH      = EMP_RSH         ; ...at the SAME rate emp.s's ring grows
                                 ;   (emp.s), so it reads as the same kind of
                                 ;   pulse, just cut shorter - max 96 half-res
                                 ;   px against the ship's 248

        .assert EMPM_RING_FRAMES << EMPM_RSH <= 255, error, "empmine.s: DOT_CIRCLE's R is one byte"
        .assert EMPM_RING_FRAMES <= EMPM_COOLDOWN, error, "empmine.s: the ring must fit inside the cooldown it rides on"
        .assert EMPM_RP < 128, error, "empmine.s: absa's result and 2*EMPM_RP must stay positive bytes"
        .assert FK_EMPMINE < FK_N, error, "empmine.s: foes.s's FK_N is behind this kind"

; --- state: under the window, chained after base.s's (foes.s's own chain) ---
EMI         = BASE_END          ; empm_fire: FEI saved/restored round the part
                                 ;   that borrows it for foe_kill - empm_fire
                                 ;   runs nested inside foe_think_all's own
                                 ;   FEI-driven sweep
EMCX        = BASE_END + 1      ; the firing mine's centre, high bytes
EMCY        = BASE_END + 2
EMJ         = BASE_END + 3      ; the kill-sweep's own loop index
EMH0        = BASE_END + 4      ; the quarter-square test's working sum
EMH1        = BASE_END + 5
EMDXT       = BASE_END + 6      ; ...|dx|, held across the |dy| test
EMACL       = BASE_END + 7      ; the spin RATE, 8.8 fixed - ramps up while
EMACH       = BASE_END + 8      ;   charging, down while cooling; EMACH,x is
                                 ;   this frame's FOEANG step either way
EMPM_END    = BASE_END + 9
        .assert EMPM_END <= SHAPES_AT, error, "empmine.s: past the RAM under the window"

        .pushseg
        .segment "CODE7"

; -----------------------------------------------------------------------------
; empm_think - foe_think's mine: X = FEI. Idle, it watches; charging, it does
; nothing here at all - empm_spin (every frame) owns the ramp and the fire.
; -----------------------------------------------------------------------------
empm_think:
        lda     FOEST,x
        cmp     #FS_PURSUE
        beq     @done
        lda     FOECD,x                 ; cooling down since its last shot
        bne     @done
        jsr     empm_near
        bcs     @done                   ; the ship is not close enough yet
        lda     #FS_PURSUE
        sta     FOEST,x
        lda     #EMPM_CHARGE
        sta     FOECD,x
        stz     EMACL,x                 ; the rate ramps from a dead stop
        stz     EMACH,x
        jsr     foe_alarm               ; ENEMY DETECTED, same as any foe
@done:  rts

; -----------------------------------------------------------------------------
; empm_spin - foe_think_all, every frame, every non-spider foe: X = FEI.
; Advances FOEANG by this frame's rate; at the end of a charge, fires.
; Preserves X.
; -----------------------------------------------------------------------------
empm_spin:
        lda     FOEKIND,x
        cmp     #FK_EMPMINE
        bne     @no
        lda     FOEST,x
        cmp     #FS_PURSUE
        beq     @charge
        lda     FOECD,x
        bne     @cool
        lda     #EMPM_SPIN              ; fully idle and armed: the resting
        bra     @add                    ;   turn - EMAC sits at its cooled-
                                        ;   down floor, unused till next time
@cool:  jsr     empm_ring               ; cooling down: the ring while its
        ldx     FEI                     ;   own window lasts, and the rate
        sec                             ;   eases back down toward EMPM_SPIN
        lda     EMACL,x
        sbc     #EMPM_RAMP_DN
        sta     EMACL,x
        lda     EMACH,x
        sbc     #$00
        cmp     #EMPM_SPIN
        bcs     :+
        lda     #EMPM_SPIN
:       sta     EMACH,x
        bra     @rate
@charge:clc                             ; charging: the rate ramps UP toward
        lda     EMACL,x                 ;   EMPM_SPIN_MAX, an 8.8 fixed step
        adc     #EMPM_RAMP_UP           ;   every frame (pulsar.s's FOEANGF
        sta     EMACL,x                 ;   trick) - exact adds, no multiply
        lda     EMACH,x
        adc     #$00
        cmp     #EMPM_SPIN_MAX+1
        bcc     :+
        lda     #EMPM_SPIN_MAX
:       sta     EMACH,x
        lda     FOECD,x
        bne     @rate
        jsr     empm_fire
        ldx     FEI                     ; empm_fire's own tail already put FEI
        lda     #FS_PATROL              ;   back on this mine; X just follows
        sta     FOEST,x
        lda     #EMPM_COOLDOWN
        sta     FOECD,x
        jsr     empm_ring               ; the ring's own first frame
        ldx     FEI
@rate:  lda     EMACH,x
@add:   clc
        adc     FOEANG,x
        sta     FOEANG,x
@no:    rts

; -----------------------------------------------------------------------------
; empm_near - FEI is a mine. C CLEAR = the ship is within EMPM_RP pages of it -
; foe_dist's own approximate distance (foes.s), high byte only. Clobbers A.
; -----------------------------------------------------------------------------
empm_near:
        jsr     foe_dist
        lda     FEDH
        cmp     #EMPM_RP
        rts

; -----------------------------------------------------------------------------
; empm_ring - X = FEI, a mine within EMPM_RING_FRAMES of its last shot: draw
; this frame's ring. The SAME growing DOT_CIRCLE the ship's own EMP draws
; (emp.s do_emp - nothing scaled, projected or zoomed, just bigger every
; frame), only shorter-lived and so smaller at the end - "like my EMP, only
; limited range" (the user, 2026-09-22). X preserved; clobbers A.
; -----------------------------------------------------------------------------
; n = EMPM_COOLDOWN+1 - FOECD: 1 on the firing frame (FOECD was just set to
; EMPM_COOLDOWN, in either caller - empm_spin's fire branch or its @idle),
; growing by 1 every frame after as FOECD counts down. Past EMPM_RING_FRAMES
; the ring is over and this is a no-op; FOECD keeps counting down to the
; cooldown regardless, and the caller is what stops calling in either case.
; -----------------------------------------------------------------------------
empm_ring:
        lda     #EMPM_COOLDOWN+1
        sec
        sbc     FOECD,x
        cmp     #EMPM_RING_FRAMES+1
        bcs     @done                   ; the ring's own life is over
        sta     EMH0
        lda     FOEON,x                 ; never drawn: no screen centre to use
        beq     @done
        lda     FOEFXH,x                ; the mine's screen centre, halved -
        lsr     a                       ;   do_emp's own conversion of a
        lda     FOEFXL,x                ;   full-res centre, this one the
        ror     a                       ;   mine's instead of the ship's
        sta     OS_ARG+0
        lda     FOEFYH,x
        lsr     a
        lda     FOEFYL,x
        ror     a
        sta     OS_ARG+1
        lda     EMH0
        .repeat EMPM_RSH
        asl     a
        .endrepeat
        sta     OS_ARG+2
        jsr     API_GPU_DOTCIRCLE
@done:  rts

; -----------------------------------------------------------------------------
; empm_fire - FEI is a charged mine, at 0: detonate. The ship first (foe_dist
; again, ship_hurt_raw - flat, no armour and no shield), then every OTHER
; enemy within EMPM_RP - do_emp's own exact circle (emp.s), re-centred here.
; The ring is empm_spin's, drawn once this returns and FOECD is set (its
; first frame needs FOECD already at EMPM_COOLDOWN). Nested inside
; foe_think_all's own FEI sweep, so FEI is saved and restored round the part
; that borrows it for foe_kill.
; -----------------------------------------------------------------------------
empm_fire:
        lda     FEI
        sta     EMI
        ldx     FEI
        lda     FOEXH,x
        sta     EMCX
        lda     FOEYH,x
        sta     EMCY
        lda     #SE_EMP
        jsr     sfx_fire
        jsr     empm_near
        bcs     @foes
        lda     #EMPM_DMG
        jsr     ship_hurt_raw           ; flat - no armour, no shield
@foes:  stz     FOEKILL                 ; every kill below is paid (do_emp's
                                        ;   own convention) - the mine pays
                                        ;   nobody for ITS OWN death, but the
                                        ;   ones it catches score normally
        lda     NFOE
        beq     @done
        dec     a
        sta     EMJ
@lp:    ldy     EMJ
        cpy     EMI
        beq     @next                   ; not itself
        lda     FOEST,y
        beq     @next                   ; FS_DEAD
        lda     FOEXH,y
        sec
        sbc     EMCX
        jsr     absa
        cmp     #EMPM_RP
        beq     :+
        bcs     @next
:       sta     EMDXT
        lda     FOEYH,y
        sec
        sbc     EMCY
        jsr     absa
        cmp     #EMPM_RP
        beq     :+
        bcs     @next
:       asl     a                       ; the exact circle: f(2a) = a*a, the
        tax                             ;   quarter-square trick do_emp uses
        lda     EMDXT
        asl     a
        tay
        clc
        lda     QSL,y
        adc     QSL,x
        sta     EMH0
        lda     QSH,y
        adc     QSH,x
        sta     EMH1
        ldx     #EMPM_RP*2
        lda     QSL,x                   ; RP*RP - the rim is inside
        cmp     EMH0
        lda     QSH,x
        sbc     EMH1
        bcc     @next
        lda     EMJ
        sta     FEI
        ldx     FEI
        jsr     foe_kill
@next:  dec     EMJ
        bpl     @lp
@done:  lda     EMI
        sta     FEI
        rts

        .popseg
