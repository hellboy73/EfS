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
; always both at once, as two dotted lines (gpu_dotline_clip, half-res,
; clipped). It fires only from its animation's FRAME 0 - the longest bar - and
; burns PLS_FRAMES game frames with the animation FROZEN on that frame. Whether
; it fires at all is decided on the FIRST game frame of frame 0's hold, and it
; needs both:
;
;   - the pulsar on the screen (FOEON), and
;   - the bar pointing at the ship: the ship's circle crosses the beam's line.
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
; (perpendicular distance) beyond the bar's own ends. Both are worked in
; QUARTER-res px so every offset fits the quarter-square multiply's 127, and
; the products are EXACT (f(a+b) - f(|a-b|), no >>7): the distance is compared
; x127 rather than divided. A quarter px is 4 full-res; offsets are rounded to
; it, and the circle is rounded UP, so the test errs toward a hit by a px or two.
;
; TELEPORT. A pulsar that takes a hit and survives it - a bullet, the ship's
; laser, another pulsar's beam - jumps: its offset from the ship turned by
; PLS_TPANG + 0..PLS_TPJIT brad either way (about a quarter turn), at the SAME
; distance. foe_take_hit calls pls_teleport.
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
PLS_ARM     = 15                ; full-res px from its centre to each end of the
                                ;   bar in frame 0 (enemies.s EN_PULSAR_S0,
                                ;   +/-15): where the beam starts
PLS_HW      = LSR_HW            ; the beam's half-width for the hit test
PLS_DMG     = LSR_DMG           ; hit points a lit frame to what it crosses
PLS_SHIPDMG = 1                 ; ...and to the ship: 10 a shot, one ordinary
                                ;   hit
PLS_TPANG   = 48                ; a teleport turns it round the ship by this...
PLS_TPJIT   = $1F               ; ...plus a random 0..this (a mask), brad: 68
                                ;   to 111 degrees, either way

        .assert (PLS_TPJIT & (PLS_TPJIT+1)) = 0, error, "pulsar.s: PLS_TPJIT is an AND mask"
        .assert PLS_TPANG + PLS_TPJIT < 128, error, "pulsar.s: a teleport turn must stay under half a circle"
        .assert EN_PULSAR_FN >= 1, error, "pulsar.s: the pulsar fires on its frame 0"
        .assert FK_UFO = 0, error, "pulsar.s: foe_body leaves only KIND 0 level on the screen"

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
PLDX        = $958A             ; target - pulsar, quarter-res, signed byte
PLDY        = $958B
PLKL        = $958C             ; the target's radius x127, quarter-res
PLKH        = $958D
PLIKL       = $958E             ; the bar's half-length x127, quarter-res
PLIKH       = $958F
PLPL        = $9590             ; a distance being built, x127
PLPH        = $9591
PLML        = $9592             ; pls_mul's product
PLMH        = $9593
PLMA        = $9594             ; ...its operands
PLMB        = $9595
PLSG        = $9596             ; ...and the product's sign
PLT0        = $9597
PLHXL       = $9598             ; the centre in half-res, signed 16
PLHXH       = $9599
PLHYL       = $959A
PLHYH       = $959B
PLAH        = $959C             ; the bar's half-length, half-res
PLIXL       = $959D             ; the bar's end offset, half-res, signed 16 -
PLIXH       = $959E             ;   the beam's inner end...
PLIYL       = $959F
PLIYH       = $95A0
PLOXL       = $95A1             ; ...and its outer end, 256 half-res px out:
PLOXH       = $95A2             ;   past every corner of the screen from any
PLOYL       = $95A3             ;   point on it
PLOYH       = $95A4
PTI         = $95A5             ; pls_teleport: the foe
PTT0        = $95A6
PTANG       = $95A7
PTC         = $95A8
PTS         = $95A9
PTVXL       = $95AA             ; its offset from the ship, world 16-bit
PTVXH       = $95AB
PTVYL       = $95AC
PTVYH       = $95AD
PTXL        = $95AE             ; ...turned
PTXH        = $95AF
PTYL        = $95B0
PTYH        = $95B1
        .assert FOEANGF = FOEANG + FOE_MAX && FOELSR = FSDMG + FSH_N, error, "pulsar.s: FOEANGF/FOELSR no longer sit in the gaps they were put in"
        .assert FECAR < PLI && PTYH < $9600, error, "pulsar.s: the scratch runs into foes.s's or out of its page"

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
        bne     @burn                   ; mid-shot: the frame is frozen on 0
        ldy     FOEAST,x                ; on frame 0? (the playlist step's row
        lda     EN_ANIM+EN_PULSAR_ABASE,y ;   within the appearance is 0 only
        bne     @next                   ;   for frame 0)
        lda     FOEACD,x                ; ...its hold's FIRST frame decides
        cmp     #EN_PULSAR_AHOLD
        bne     @next
        lda     SHIPGONE
        bne     @next
        jsr     pls_setup
        jsr     pls_shipt
        jsr     pls_hit
        bcc     @next                   ; not pointing at the ship: dark
        ldx     PLI
        lda     #PLS_FRAMES
        sta     FOELSR,x
        lda     #SE_LASER
        jsr     sfx_fire
        bra     @fire
@burn:  jsr     pls_setup
@fire:  ldx     PLI
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
        bpl     @lp
        rts

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
        clc                             ; quarter-res, rounded, x127
        adc     #2
        lsr     a
        lsr     a
        jsr     pls_x127
        lda     PLKL
        sta     PLIKL
        lda     PLKH
        sta     PLIKH
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
; With d = target - centre and u = (PLC, PLS), all x127 in quarter-res px:
;   across = dy*c - dx*s     a hit needs |across| <= R
;   along  = dx*c + dy*s     ...and |along| + R >= the bar's half-length
; The far end is not tested: the beam runs 256 half-res px out, past every
; corner of the screen, and both points are on it.
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
        lda     PLR                     ; R, quarter-res, rounded UP, x127
        clc
        adc     #3
        lsr     a
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
        jsr     pls_abs
        sec                             ; R - |across|: a borrow is a miss
        lda     PLKL
        sbc     PLPL
        lda     PLKH
        sbc     PLPH
        bcc     @miss
        lda     PLDX                    ; along
        ldy     PLC
        jsr     pls_mul
        lda     PLML
        sta     PLPL
        lda     PLMH
        sta     PLPH
        lda     PLDY
        ldy     PLS
        jsr     pls_mul
        clc
        lda     PLPL
        adc     PLML
        sta     PLPL
        lda     PLPH
        adc     PLMH
        jsr     pls_abs
        clc                             ; |along| + R >= the half-length
        lda     PLPL
        adc     PLKL
        sta     PLPL
        lda     PLPH
        adc     PLKH
        sta     PLPH
        lda     PLPL
        cmp     PLIKL
        lda     PLPH
        sbc     PLIKH
        rts                             ; C SET: past the bar's end - a hit

; pls_abs - A = the high byte, PLPL the low of a signed 16 -> PLP = |it|.
pls_abs:
        sta     PLPH
        bpl     @done
        sec
        lda     #$00
        sbc     PLPL
        sta     PLPL
        lda     #$00
        sbc     PLPH
        sta     PLPH
@done:  rts

; pls_q - A:T0 = a signed 16 offset in full-res px -> A = it in quarter-res,
; rounded. C SET = outside -127..127, which is out of the beam's reach anyway.
pls_q:
        sta     T1
        clc
        lda     T0
        adc     #2
        sta     T0
        lda     T1
        adc     #$00
        sta     T1
        cmp     #$80                    ; >> 2, arithmetic
        ror     T1
        ror     T0
        lda     T1
        cmp     #$80
        ror     T1
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
; pls_draw - the two dotted beams, half-res, clipped: from each end of the bar
; out 256 half-res px, in opposite directions.
; -----------------------------------------------------------------------------
pls_draw:
        lda     PLCXH                   ; the centre, halved
        cmp     #$80
        ror     a
        sta     PLHXH
        lda     PLCXL
        ror     a
        sta     PLHXL
        lda     PLCYH
        cmp     #$80
        ror     a
        sta     PLHYH
        lda     PLCYL
        ror     a
        sta     PLHYL
        lda     PLARM                   ; the bar's end: half-length * (c, s)
        lsr     a
        sta     PLAH
        lda     PLC
        ldy     PLAH
        jsr     pls_smq
        ldx     #PLIXL - PLIXL
        jsr     pls_sext
        lda     PLS
        ldy     PLAH
        jsr     pls_smq
        ldx     #PLIYL - PLIXL
        jsr     pls_sext
        lda     PLC                     ; the far end: 256 * (c, s) / 128
        ldx     #PLOXL - PLIXL
        jsr     pls_sext
        asl     PLOXL
        rol     PLOXH
        lda     PLS
        ldx     #PLOYL - PLIXL
        jsr     pls_sext
        asl     PLOYL
        rol     PLOYH
        jsr     pls_line                ; one way...
        ldx     #6                      ; ...and, every offset negated, the other
:       sec
        lda     #$00
        sbc     PLIXL,x
        sta     PLIXL,x
        lda     #$00
        sbc     PLIXH,x
        sta     PLIXH,x
        dex
        dex
        bpl     :-
        ; fall through

; pls_line - centre + the inner offset to centre + the outer one.
pls_line:
        clc
        lda     PLHXL
        adc     PLIXL
        sta     OS_ARG+0
        lda     PLHXH
        adc     PLIXH
        sta     OS_ARG+1
        clc
        lda     PLHYL
        adc     PLIYL
        sta     OS_ARG+2
        lda     PLHYH
        adc     PLIYH
        sta     OS_ARG+3
        clc
        lda     PLHXL
        adc     PLOXL
        sta     OS_ARG+4
        lda     PLHXH
        adc     PLOXH
        sta     OS_ARG+5
        clc
        lda     PLHYL
        adc     PLOYL
        sta     OS_ARG+6
        lda     PLHYH
        adc     PLOYH
        sta     OS_ARG+7
        jmp     API_GPU_DOTLINE_CLIP    ; tail

; pls_sext - A = a signed byte -> PLIXL+X / PLIXH+X, sign-extended.
pls_sext:
        sta     PLIXL,x
        lda     #$00
        bit     PLIXL,x
        bpl     :+
        lda     #$FF
:       sta     PLIXH,x
        rts

; pls_smq - A = a signed byte, Y = a magnitude 0..127 -> A = A * Y / 128,
; rounded, signed.
pls_smq:
        sty     MQB
        sta     PLT0
        tax
        bpl     :+
        eor     #$FF
        inc     a
:       sta     MQA
        jsr     qmul
        bit     PLT0
        bpl     :+
        eor     #$FF
        inc     a
:       rts

; -----------------------------------------------------------------------------
; pls_teleport - X = a pulsar that took a hit and is still standing (foe_take_hit).
; It jumps round the ship, keeping its distance. Preserves X.
; -----------------------------------------------------------------------------
; Its offset from the ship turned by a quarter turn, give or take, either way:
;   x' = x cos - y sin,  y' = x sin + y cos
; smul16q7 four times - once a hit, not once a frame. The Q0.7 trig's 127/128
; shaves the distance by under 1% a jump.
; -----------------------------------------------------------------------------
pls_teleport:
        stx     PTI
        lda     SHIPGONE                ; no ship to keep a distance from
        beq     :+
        rts
:       sec
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
        jsr     prng                    ; how far round, and which way
        sta     PTT0
        and     #PLS_TPJIT
        clc
        adc     #PLS_TPANG
        bit     PTT0
        bpl     :+
        eor     #$FF
        inc     a
:       sta     PTANG
        jsr     API_COS
        sta     PTC
        lda     PTANG
        jsr     API_SIN
        sta     PTS

        lda     PTC                     ; x' = x cos...
        ldx     #PTVXL - PTVXL
        jsr     pt_mul
        lda     MAL
        sta     PTXL
        lda     MAH
        sta     PTXH
        lda     PTS                     ; ...- y sin
        ldx     #PTVYL - PTVXL
        jsr     pt_mul
        sec
        lda     PTXL
        sbc     MAL
        sta     PTXL
        lda     PTXH
        sbc     MAH
        sta     PTXH
        lda     PTS                     ; y' = x sin...
        ldx     #PTVXL - PTVXL
        jsr     pt_mul
        lda     MAL
        sta     PTYL
        lda     MAH
        sta     PTYH
        lda     PTC                     ; ...+ y cos
        ldx     #PTVYL - PTVXL
        jsr     pt_mul
        clc
        lda     PTYL
        adc     MAL
        sta     PTYL
        lda     PTYH
        adc     MAH
        sta     PTYH

        ldx     PTI                     ; the ship + the turned offset, and the
        clc                             ;   post it holds is the new place too
        lda     SHXL
        adc     PTXL
        sta     FOEXL,x
        sta     FOEAXL,x
        lda     SHXH
        adc     PTXH
        sta     FOEXH,x
        sta     FOEAXH,x
        clc
        lda     SHYL
        adc     PTYL
        sta     FOEYL,x
        sta     FOEAYL,x
        lda     SHYH
        adc     PTYH
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

; pt_mul - A = Q0.7, X = PTVXL/PTVYL's offset from PTVXL -> MA = that * A.
pt_mul:
        sta     MB
        lda     PTVXL,x
        sta     MAL
        lda     PTVXH,x
        sta     MAH
        jmp     smul16q7                ; tail

        .popseg
