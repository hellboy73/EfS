; =============================================================================
; pulsar.s - the PULSAR: a spinning bar that fires a laser out of both ends
; =============================================================================
; FLIGHT is the UFO's patrol and nothing more: the course and speed its level
; record gave it (or, at speed 0, a post it springs back to), foe_steer and
; foe_avoid exactly as a UFO flies them - but it never pursues: foe_seek is
; never called for it, so it never raises the alarm either. It does SEE the
; ship (pls_watch), and only so the camera frames it like the others.
;
; IT SPINS AND TURNS WITH THE WORLD. The UFO is the one stylistic exception
; that stays level on the screen; a pulsar is drawn at FOEANG - HEAD like a
; mounted spider, and FOEANG turns PLS_SPIN brad a frame (8.8), clockwise on an
; even slot and anticlockwise on an odd one, so a pair does not turn in step.
;
; THE LASER. The shape's part 0 is the bar through its middle, and the beam is
; that bar carried on outward: from each end of it, in opposite directions,
; always both at once. Each is ONE OPEN two-vertex DOT_POLYGON ($4C) at the bar's
; own ANGLE, (end, 0) -> (127, 0) half-res, and the second is the same block at
; ANGLE + 128 - so the GPU turns it exactly as it turns the bar, and CPU1 does
; no rotation at all. 127 half-res is 254 full-res px of beam a side at any zoom.
; It fires only from its animation's FRAME 0 - the longest bar - and burns
; PLS_FRAMES game frames with the animation FROZEN on that frame. Whether it
; fires is decided on the FIRST game frame of frame 0's hold, and it needs both:
;
;   - the pulsar on the screen (FOEON), and
;   - the ship DETECTED (FS_PURSUE, pls_watch: within FOE_SEE), and
;   - the ship ALMOST on the beam: its circle, widened by PLS_AIM, crosses the
;     beam's line within the beam's reach. It spins, so a shot lit on a near
;     miss sweeps on toward the ship over the frames it burns.
;
; Once lit, it stays lit PLS_FRAMES whatever the spin does, and is put out if
; the pulsar leaves the screen. Its beam is the ship's laser in
; everything but its shape: LSR_DMG a frame to every rock and every enemy it
; crosses (a mounted spider excepted - the beam is on its rock, as a bullet
; is), and to the ship. It pays nobody: FOEKILL is set around every hit, so a
; rock it breaks scores nothing and throws no Saturnium, and an enemy it kills
; scores nothing.
;
; THE TEST IS ON THE SCREEN, like the ship's laser (laser.s): the targets are
; the visible list, FOEFX/FY and the ship's drawn centre, all with the shake in.
; A target hits when its circle, widened by PLS_HW, reaches the beam's LINE
; (perpendicular distance) - and only that is tested (pls_hit). It is worked in
; HALF-res px - the beam's own units, so an offset past 127 is past its end -
; and the products are EXACT (f(a+b) - f(|a-b|), no >>7): the distance is
; compared x127 rather than divided. Offsets are rounded to the half px and the
; circle UP, so the test errs toward a hit by a px.
;
; TELEPORT. A pulsar that takes a BULLET and survives it jumps - a hit of
; SHOT_DMG or more. A beam's frame (the ship's laser, another pulsar's) is less
; and only burns it: jumping out of the beam on its first frame made the laser
; useless against it. The jump is its offset from the ship turned a
; QUARTER TURN, either way at random, at the same distance. A quarter turn is a
; swap and a negate, so there is no trig and no multiply in it. foe_take_hit
; calls pls_teleport.
;
; WHERE IT LIVES. CODE6, stored in bank 6 behind the screens' code and run in
; CART_HIRAM after it (cart.cfg): bank 4, where CODE5 is, had 200 bytes left.
; Its hooks are in foes.s - the spin and the think in foe_think_all/foe_think,
; the beams in do_foes, the teleport in foe_take_hit.
; =============================================================================

; --- tunables - physics.md 11 --------------------------------------------------
PLS_HP      = 5*HIT_HP          ; five bullets - and it jumps away from each
PLS_SPIN    = $0080             ; brad a frame, 8.8: half a brad, a turn in
                                ;   ~8.5 s
PLS_FRAMES  = 10                ; game frames one shot burns, its animation
                                ;   frozen on frame 0 all the while
PLS_AIM     = 24                ; full-res px added to the ship's circle when
                                ;   it decides to fire - "almost on target"
PLS_ARM     = 15                ; full-res px from its centre to each end of the
                                ;   bar in frame 0 (enemies.s EN_PULSAR_S0,
                                ;   +/-15): where the beam starts
PLS_HW      = LSR_HW            ; the beam's half-width for the hit test
PLS_DMG     = LSR_DMG           ; hit points a lit frame to what it crosses
PLS_SHIPDMG = 1                 ; ...and to the ship: 10 a shot, one ordinary
                                ;   hit

        .assert EN_PULSAR_FN >= 1, error, "pulsar.s: the pulsar fires on its frame 0"
        .assert FK_UFO = 0, error, "pulsar.s: foe_body leaves only KIND 0 level on the screen"
        .assert LSR_DMG < SHOT_DMG && PLS_DMG < SHOT_DMG, error, "pulsar.s: foe_take_hit tells a beam from a bullet by SHOT_DMG - a beam frame that big would make it jump"

; --- state ---------------------------------------------------------------------
; Per foe, under the window beside foes.s's arrays (so only ever read inside
; cart_frame's bracket, as they are).
FOEANGF     = $92F0             ; FOEANG's fraction - the spin is 8.8
FOELSR      = $93A0             ; frames of beam left, 0 = dark. Nonzero also
                                ;   FREEZES the animation (foe_think_all)

; scratch, after foes.s's
PLI         = $957B             ; the pulsar firing
PLJ         = $957C             ; the target being tested
PLC         = $957D             ; the beam's direction on the screen, Q0.7:
PLS         = $957E             ;   cos and sin of FOEANG - HEAD
PLANG       = $957F
PLARM       = $9580             ; the bar's half-length at this zoom, full-res
PLR         = $9581             ; the target's radius + PLS_HW, full-res
PLCXL       = $9582             ; the pulsar's screen centre, full-res, signed 16
PLCXH       = $9583
PLCYL       = $9584
PLCYH       = $9585
PLTXL       = $9586             ; the target's
PLTXH       = $9587
PLTYL       = $9588
PLTYH       = $9589
PLDX        = $958A             ; target - pulsar, half-res, signed byte
PLDY        = $958B
PLKL        = $958C             ; the target's radius x127, half-res
PLKH        = $958D
PLPL        = $9590             ; a distance being built, x127
PLPH        = $9591
PLML        = $9592             ; pls_mul's product
PLMH        = $9593
PLMA        = $9594             ; ...its operands
PLMB        = $9595
PLSG        = $9596             ; ...and the product's sign
PLT0        = $9597
PTI         = $9598             ; pls_teleport: the foe
PTVXL       = $9599             ; its offset from the ship, world 16-bit
PTVXH       = $959A
PTVYL       = $959B
PTVYH       = $959C
        .assert FOEANGF = FOEANG + FOE_MAX && FOELSR = FSDMG + FSH_N, error, "pulsar.s: FOEANGF/FOELSR no longer sit in the gaps they were put in"
        .assert FECAR < PLI && PTVYH < $9600, error, "pulsar.s: the scratch runs into foes.s's or out of its page"

        .pushseg
        .segment "CODE6"

; -----------------------------------------------------------------------------
; pls_spin - X = a foe, every frame (foe_think_all). A pulsar turns; anything
; else is left alone. Preserves X.
; -----------------------------------------------------------------------------
pls_spin:
        lda     FOEKIND,x
        cmp     #FK_PULSAR
        bne     @no
        txa
        lsr     a
        bcs     @neg
        clc
        lda     FOEANGF,x
        adc     #<PLS_SPIN
        sta     FOEANGF,x
        lda     FOEANG,x
        adc     #>PLS_SPIN
        sta     FOEANG,x
        rts
@neg:   sec
        lda     FOEANGF,x
        sbc     #<PLS_SPIN
        sta     FOEANGF,x
        lda     FOEANG,x
        sbc     #>PLS_SPIN
        sta     FOEANG,x
@no:    rts

; -----------------------------------------------------------------------------
; pls_think - foe_think's pulsar: the UFO's patrol, steer and avoid - and no
; seek, so no chase and no alarm. It does have the UFO's SIGHT (pls_watch), and
; only so the camera frames it (cam.s takes FS_PURSUE) as it frames the others.
; -----------------------------------------------------------------------------
pls_think:
        jsr     pls_watch
        jsr     foe_patrol
        jsr     foe_steer
        jmp     foe_avoid

; pls_watch - FS_PURSUE within FOE_SEE, back to FS_PATROL past FOE_LOSE: the
; spider's eyes (foes.s spider_watch) with no gun behind them. The state steers
; nothing - pls_think never reads it - but it is what cam.s and foe_alarm's
; "is anybody already on it" walk look for.
pls_watch:
        lda     SHIPGONE
        bne     @lose
        jsr     foe_dist                ; (X = FEI in, FEI's distance out)
        ldx     FEI
        lda     FOEST,x
        cmp     #FS_PURSUE
        beq     @seen
        lda     FEDL
        cmp     #<FOE_SEE
        lda     FEDH
        sbc     #>FOE_SEE
        bcs     @done
        lda     #FS_PURSUE
        sta     FOEST,x
        rts
@seen:  lda     FEDL
        cmp     #<(FOE_LOSE+1)
        lda     FEDH
        sbc     #>(FOE_LOSE+1)
        bcc     @done
@lose:  ldx     FEI
        lda     #FS_PATROL
        sta     FOEST,x
@done:  rts

; -----------------------------------------------------------------------------
; pls_beams - do_foes, after the hit passes: every pulsar's laser.
; -----------------------------------------------------------------------------
pls_beams:
        lda     NFOE
        bne     :+
        rts
:       dec     a
        sta     PLI
@lp:    ldx     PLI
        lda     FOEKIND,x
        cmp     #FK_PULSAR
        bne     @next
        lda     FOEST,x
        beq     @off
        lda     FOEON,x                 ; off the screen: dark, and the
        beq     @off                    ;   animation runs again
        lda     FOELSR,x
        bne     @fire                   ; mid-shot: the frame is frozen on 0
        ldy     FOEAST,x                ; on frame 0? (the playlist step's row
        lda     EN_ANIM+EN_PULSAR_ABASE,y ;   within the appearance is 0 only
        bne     @next                   ;   for frame 0)
        lda     FOEACD,x                ; ...its hold's FIRST frame decides
        cmp     #EN_PULSAR_AHOLD
        bne     @next
        lda     FOEST,x                 ; ...if it has the ship in sight
        cmp     #FS_PURSUE              ;   (pls_watch)...
        bne     @next
        lda     SHIPGONE
        bne     @next
        jsr     pls_setup               ; ...and ALMOST on the beam: the ship's
        jsr     pls_shipt               ;   circle widened by PLS_AIM, within
        lda     PLR                     ;   the beam's reach. It spins, so a
        clc                             ;   near miss on this frame can still
        adc     #PLS_AIM                ;   cross it on a later one
        sta     PLR
        jsr     pls_hit
        bcc     @next                   ; not near enough: dark
        ldx     PLI
        lda     #PLS_FRAMES
        sta     FOELSR,x
        lda     #SE_LASER
        jsr     sfx_fire
@fire:  jsr     pls_setup
        ldx     PLI
        dec     FOELSR,x                ; this frame spent: at 0 the animation
                                        ;   takes up from where it froze
        jsr     pls_draw
        jsr     pls_rocks
        jsr     pls_foes
        lda     SHIPGONE                ; the ship last: a hit may end it
        bne     @next
        jsr     pls_shipt
        jsr     pls_hit
        bcc     @next
        lda     #PLS_SHIPDMG
        jsr     ship_hurt
        bra     @next
@off:   stz     FOELSR,x
@next:  dec     PLI
        bmi     :+
        jmp     @lp
:       rts

; -----------------------------------------------------------------------------
; pls_setup - PLI's beam: direction, centre, the bar's half-length.
; -----------------------------------------------------------------------------
pls_setup:
        ldx     PLI
        lda     FOEANG,x                ; the angle it is DRAWN at (foe_body)
        sec
        sbc     HEAD
        sta     PLANG
        jsr     API_COS
        sta     PLC
        lda     PLANG
        jsr     API_SIN
        sta     PLS
        ldx     PLI
        lda     FOEFXL,x
        sta     PLCXL
        lda     FOEFXH,x
        sta     PLCXH
        lda     FOEFYL,x
        sta     PLCYL
        lda     FOEFYH,x
        sta     PLCYH
        lda     #PLS_ARM                ; scaled as the GPU scales the bar
        sta     MQA
        lda     ZEASH
        sta     MQB
        jsr     qmul
        sta     PLARM
        rts

; -----------------------------------------------------------------------------
; pls_shipt - the ship as the target: its drawn centre (laser.s lsr_where's
; arithmetic) and its circle.
; -----------------------------------------------------------------------------
pls_shipt:
        ldy     #$00
        bit     SHOFFH
        bpl     :+
        dey
:       clc
        lda     SHOFFH
        adc     #<FBCX
        sta     PLTXL
        tya
        adc     #>FBCX
        sta     PLTXH
        ldy     #$00
        lda     SHAKEX
        bpl     :+
        dey
:       clc
        adc     PLTXL
        sta     PLTXL
        tya
        adc     PLTXH
        sta     PLTXH
        ldy     #$00
        bit     SHOFXH
        bpl     :+
        dey
:       clc
        lda     SHOFXH
        adc     #<FBCY
        sta     PLTYL
        tya
        adc     #>FBCY
        sta     PLTYH
        ldy     #$00
        lda     SHAKEY
        bpl     :+
        dey
:       clc
        adc     PLTYL
        sta     PLTYL
        tya
        adc     PLTYH
        sta     PLTYH
        lda     #SHIP_RAD
        ; fall through

; pls_rad - A = a radius in collision units (half-res px at 1:1) -> PLR, that
; circle on the screen in full-res px plus the beam's half-width.
pls_rad:
        sta     MQA
        lda     ZOOMH
        sta     MQB
        jsr     qmul
        asl     a
        clc
        adc     #PLS_HW
        sta     PLR
        rts

; -----------------------------------------------------------------------------
; pls_rocks - the visible list against PLI's beam (laser.s lsr_rocks' walk).
; -----------------------------------------------------------------------------
pls_rocks:
        lda     VISN
        beq     @done
        stz     PLJ
@lp:    ldy     PLJ
        ldx     VISIDX,y
        lda     OBJSHP,x
        cmp     #BODY_SPIDER            ; the five rock classes only: SHP_DEAD
        bcs     @next                   ;   (a rock broken earlier this frame)
        tax                             ;   and a carrier fail the same compare
        lda     BODY_R,x
        jsr     pls_rad
        ldy     PLJ
        lda     VSXL,y
        sta     PLTXL
        lda     VSXH,y
        sta     PLTXH
        lda     VSYL,y
        sta     PLTYL
        lda     VSYH,y
        sta     PLTYH
        jsr     pls_hit
        bcc     @next
        ldx     PLI                     ; the halves go across the bar
        lda     FOEANG,x
        sta     SPL_HD
        lda     #$01                    ; ...and nobody is paid for it
        sta     FOEKILL
        ldy     PLJ
        ldx     VISIDX,y
        lda     #PLS_DMG
        jsr     rock_take_hit
        stz     FOEKILL
@next:  inc     PLJ
        lda     PLJ
        cmp     VISN
        bne     @lp
@done:  rts

; -----------------------------------------------------------------------------
; pls_foes - every other enemy on the screen against PLI's beam.
; -----------------------------------------------------------------------------
pls_foes:
        lda     #FOE_R
        jsr     pls_rad
        lda     NFOE
        dec     a
        sta     PLJ
@lp:    ldx     PLJ
        cpx     PLI
        beq     @next                   ; not itself
        lda     FOEST,x
        beq     @next
        cmp     #FS_MOUNTED             ; on its rock: the beam is on the rock
        beq     @next
        lda     FOEON,x
        beq     @next
        lda     FOEFXL,x
        sta     PLTXL
        lda     FOEFXH,x
        sta     PLTXH
        lda     FOEFYL,x
        sta     PLTYL
        lda     FOEFYH,x
        sta     PLTYH
        jsr     pls_hit
        bcc     @next
        lda     PLJ
        sta     FEI                     ; foe_take_hit and foe_kill read FEI
        tax
        lda     #$01
        sta     FOEKILL
        lda     #PLS_DMG
        jsr     foe_take_hit
        stz     FOEKILL
@next:  dec     PLJ
        bpl     @lp
        rts

; -----------------------------------------------------------------------------
; pls_hit - does the circle PLTX/PLTY, radius PLR, reach PLI's beam? C SET = it
; does. Clobbers A, X, Y, T0, T1.
; -----------------------------------------------------------------------------
; With d = target - centre and u = (PLC, PLS), all x127 in half-res px:
;   across = dy*c - dx*s     a hit needs |across| <= R
; ACROSS ONLY. Where along the line the target is is not tested: the far end is
; where pls_q gives up (an offset past 127 half-res on either axis is past the
; beam's 127), and the near end - the bar's own - only matters to something
; overlapping the pulsar's body, which foe_avoid keeps rocks and enemies out of
; and the ship cannot be without ramming it.
; -----------------------------------------------------------------------------
pls_hit:
        sec
        lda     PLTXL
        sbc     PLCXL
        sta     T0
        lda     PLTXH
        sbc     PLCXH
        jsr     pls_q
        bcs     @miss
        sta     PLDX
        sec
        lda     PLTYL
        sbc     PLCYL
        sta     T0
        lda     PLTYH
        sbc     PLCYH
        jsr     pls_q
        bcc     :+
@miss:  clc                             ; (here: within reach of every branch)
        rts
:       sta     PLDY
        lda     PLR                     ; R, half-res, rounded UP, x127
        clc
        adc     #1
        lsr     a
        jsr     pls_x127
        lda     PLDY                    ; across
        ldy     PLC
        jsr     pls_mul
        lda     PLML
        sta     PLPL
        lda     PLMH
        sta     PLPH
        lda     PLDX
        ldy     PLS
        jsr     pls_mul
        sec
        lda     PLPL
        sbc     PLML
        sta     PLPL
        lda     PLPH
        sbc     PLMH
        sta     PLPH                    ; |across|
        bpl     :+
        sec
        lda     #$00
        sbc     PLPL
        sta     PLPL
        lda     #$00
        sbc     PLPH
        sta     PLPH
:       lda     PLKL                    ; R - |across|: C SET (no borrow) is a
        cmp     PLPL                    ;   hit
        lda     PLKH
        sbc     PLPH
        rts

; pls_q - A:T0 = a signed 16 offset in full-res px -> A = it in half-res,
; rounded. C SET = outside -127..127: past the beam's end.
pls_q:
        sta     T1
        clc
        lda     T0
        adc     #1
        sta     T0
        lda     T1
        adc     #$00
        cmp     #$80                    ; >> 1, arithmetic
        ror     a
        sta     T1
        ror     T0
        lda     T1
        beq     @pos
        cmp     #$FF
        bne     @out
        lda     T0
        cmp     #$81
        bcc     @out
        clc
        rts
@pos:   lda     T0
        cmp     #$80
        bcs     @out
        clc
        rts
@out:   sec
        rts

; pls_x127 - A = n, 0..127 -> PLK = n * 127, as n * 128 - n.
pls_x127:
        sta     PLT0
        lsr     a
        sta     PLKH
        lda     #$00
        ror     a
        sec
        sbc     PLT0
        sta     PLKL
        lda     PLKH
        sbc     #$00
        sta     PLKH
        rts

; pls_mul - A * Y, both signed bytes in -127..127 -> PLM, signed 16, EXACT:
; f(|a|+|b|) - f(||a|-|b||) out of the quarter-square table (math.s), with no
; >>7, so nothing is rounded.
pls_mul:
        sta     PLMA
        sty     PLMB
        eor     PLMB
        sta     PLSG                    ; bit 7: the signs differ
        lda     PLMA
        bpl     :+
        eor     #$FF
        inc     a
        sta     PLMA
:       lda     PLMB
        bpl     :+
        eor     #$FF
        inc     a
        sta     PLMB
:       clc
        adc     PLMA
        tax
        lda     PLMA
        sec
        sbc     PLMB
        bcs     :+
        eor     #$FF
        inc     a
:       tay
        sec
        lda     QSL,x
        sbc     QSL,y
        sta     PLML
        lda     QSH,x
        sbc     QSH,y
        sta     PLMH
        bit     PLSG
        bpl     @done
        sec
        lda     #$00
        sbc     PLML
        sta     PLML
        lda     #$00
        sbc     PLMH
        sta     PLMH
@done:  rts

; -----------------------------------------------------------------------------
; pls_draw - the two beams: one OPEN two-vertex DOT_POLYGON from the bar's end
; out to 127 half-res, at the bar's angle - and the same block again half a
; turn round. PBUF is foe_body's, free until it draws.
; -----------------------------------------------------------------------------
pls_draw:
        lda     PLCXH                   ; the centre, halved: DOT_POLYGON is
        cmp     #$80                    ;   half-res
        ror     a
        sta     PBUF+1
        lda     PLCXL
        ror     a
        sta     PBUF+0
        lda     PLCYH
        cmp     #$80
        ror     a
        sta     PBUF+3
        lda     PLCYL
        ror     a
        sta     PBUF+2
        lda     PLANG
        sta     PBUF+4
        lda     #128                    ; SCALE 1:1 - the end below is already
        sta     PBUF+5                  ;   zoomed
        lda     #$82                    ; OPEN, two vertices
        sta     PBUF+6
        lda     PLARM                   ; (the bar's end, 0)...
        lsr     a
        sta     PBUF+7
        stz     PBUF+8
        lda     #127                    ; ...to (127, 0)
        sta     PBUF+9
        stz     PBUF+10
        jsr     @one                    ; one way...
        lda     PBUF+4                  ; ...and half a turn round, the other
        eor     #$80
        sta     PBUF+4
@one:   lda     #<PBUF
        sta     OS_ARG+0
        lda     #>PBUF
        sta     OS_ARG+1
        jmp     API_GPU_DOTPOLYGON      ; tail

; -----------------------------------------------------------------------------
; pls_teleport - X = a pulsar that took a hit and is still standing (foe_take_hit).
; It jumps a quarter turn round the ship, keeping its distance. Preserves X.
; -----------------------------------------------------------------------------
; d = pulsar - ship, negated on a random bit, then (x, y) -> (-y, x): a quarter
; turn one way or, with d negated, the other.
; -----------------------------------------------------------------------------
pls_teleport:
        lda     SHIPGONE                ; no ship to keep a distance from
        beq     :+
        rts
:       stx     PTI
        sec
        lda     FOEXL,x
        sbc     SHXL
        sta     PTVXL
        lda     FOEXH,x
        sbc     SHXH
        sta     PTVXH
        sec
        lda     FOEYL,x
        sbc     SHYL
        sta     PTVYL
        lda     FOEYH,x
        sbc     SHYH
        sta     PTVYH
        jsr     prng                    ; which way round
        bpl     @turn
        ldx     #2                      ; the other: d negated
:       sec
        lda     #$00
        sbc     PTVXL,x
        sta     PTVXL,x
        lda     #$00
        sbc     PTVXH,x
        sta     PTVXH,x
        dex
        dex
        bpl     :-
@turn:  ldx     PTI
        sec                             ; x = ship - dy
        lda     SHXL
        sbc     PTVYL
        sta     FOEXL,x
        sta     FOEAXL,x                ; ...and the post it holds is the new
        lda     SHXH                    ;   place too
        sbc     PTVYH
        sta     FOEXH,x
        sta     FOEAXH,x
        clc                             ; y = ship + dx
        lda     SHYL
        adc     PTVXL
        sta     FOEYL,x
        sta     FOEAYL,x
        lda     SHYH
        adc     PTVXH
        sta     FOEYH,x
        sta     FOEAYH,x
        stz     FOEON,x                 ; not where this frame's screen point
        stz     FOESLP,x                ;   says: not hit or drawn there again,
        stz     FOELSR,x                ;   and transformed afresh next frame
        lda     #$01
        sta     FOENEW,x                ; ...and it thinks next frame: it may
                                        ;   have landed in a rock
        lda     #SE_TELEPORT
        jsr     sfx_fire
        ldx     PTI
        rts

        .popseg
