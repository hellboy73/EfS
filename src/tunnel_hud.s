; =============================================================================
; tunnel_hud.s - the tunnel's instruments and what it gives back (included by tunnel.s)
; =============================================================================
; The user, 2026-10-13. The bottom 50 px band under the cockpit window carries the
; SECTOR's SHIPS + hull row (line 46), built and emitted by hud_game.s - which is why
; that code now runs ABOVE the tunnel's footprint (HUDCODE, cart.cfg) - and under it,
; where the sector has LEVEL + SCORE, the tunnel's own row (the user: no LEVEL/SCORE
; line in the tunnel; the score still counts, it is only not shown here):
;
;   line 46   SHIPS: 3  |xxxxxxxxxxxx|      (hud_game.s hud_row1)
;   line 48   SATURNIUM |xxxxxxxxxxxx|      the hold, proportional, full at SATN_FULL
;
; The SATURNIUM bar is as wide as the hull bar and in the same cells. No radar: where
; it stands in the sector there is a PICTURE OF THE SHIP (assets/png/ship_rest_h44_1x.png,
; the user's, 2026-10-14), part of the cockpit's background art (tunnel.s, the Makefile's
; tunnel_art.s rule) - only the band's right side, cells 24+ of lines 44..49, is free for
; it in the tunnel, the window being above.
;
; THE REPAIR round it (tun_repair): the user's 44 frames (assets/png/ship/ship_anim*.png),
; each cut by tools/repairgen.py down to what it ADDS to the ship already on the
; background - one byte-wide no-overlay sprite a frame, OR-ed over the picture. A new one
; every TUN_RPD frames, looping, the whole time the tunnel flies (the user, 2026-10-14: to see how it
; looks; at full hull it is to stop).
;
; THE PACING IS THE SECTOR'S (the user: never more often than every 2 frames, one line
; at a time): both rows go through hud_game.s's bgtext_claim, on hud_game.s's 8-frame
; cycle (HUD_PHASE) - SHIPS on row 1's phase, SATURNIUM on row 2's, the message bar on
; its own. The tunnel steps the cycle itself rather than calling hud_tick, so neither
; LEVEL + SCORE nor the game-over banner is ever sent here.
;
; WHAT THE TUNNEL GIVES BACK:
;   * the HULL grows by one point every TUN_HPP frames, from whatever the sector left,
;     so it is full (HP_MAX) before the rush whatever it started at;
;   * the SATURNIUM is the sector's (SATN, under the window, read once at the start into
;     TSATN and written back at the end, tun_pay): a cloud adds TUN_SATCLD, a rock hit
;     takes TUN_SATHIT (to 0); at SATN_FULL and over SPARKS flash round the window, as
;     on the hull in the sector (TUN_SPK*);
;   * a SHIP for each lifepod caught (LIVES, never past TUN_LIVMAX), and as many pods
;     fly as ships were lost in the sector (LVSTART - LIVES, tunnel_pod.s); the bar
;     says PILOT RESCUED, or PILOT LOST IN SPACE for one gone past - on the sector's
;     message bar (line 2, the band above the window: the user, 2026-10-13, to see
;     whether it can stay there), spoken;
;   * SCORE: TUN_PODPTS hundred a pod, TUN_CLDPTS hundred a cloud (score_add).
; =============================================================================

TUN_HUDROW0 = HUD_ROW2          ; the SATURNIUM row: line 48, the sector's LEVEL + SCORE
TUN_HPP     = 60                ; frames a hull point (TBM): 1 s, so HP_MAX - 1 = 49 points
                                ;   are back in 49 s, before the rush starts
TUN_SATCLD  = 50                ; Saturnium a cloud adds (the user, 2026-10-13)
TUN_SATHIT  = 20                ; ...and a rock hit takes
TUN_PODPTS  = 3                 ; score, in hundreds: a lifepod...
TUN_CLDPTS  = 1                 ; ...and a cloud
TUN_LIVMAX  = 5                 ; ships in hand never go past this (design_technical 11.45)
TUN_RPD     = 3                 ; frames each frame of the repair effect stays (the user,
                                ;   2026-10-14): 44 of them, a lap in ~2.2 s
TUN_SPKP    = 6                 ; SPARKS (at SATN_FULL and over): a burst every this many
TUN_SPKR0   = 60                ;   frames, 2 or 3 dashes, each one frame, from this radius
TUN_SPKR1   = 70                ;   to this (half-res px, about the window's centre: the
                                ;   window's half is TUN_HALF = 75, so none leaves it),
                                ;   pointing at the centre, at random angles

        .assert HUD_ROW1 * 8 >= 350, error, "tunnel_hud.s: the SHIPS row would be under the window"
        .assert (HP_MAX - 1) * TUN_HPP <= TUN_FRAMES - TUN_RUSHF, error, "tunnel_hud.s: the hull would not be full before the rush"
        .assert TUN_SPKR1 < TUN_HALF, error, "tunnel_hud.s: a spark would leave the window"
        .assert TUN_SPKR1 <= 127, error, "tunnel_hud.s: tun_sm takes a radius of at most 127"

        .pushseg
        .segment "TUNBSS"
TSATN:  .res    1                       ; the Saturnium, 0..255, while the tunnel flies
HCSAT:  .res    1                       ; ...as the SATURNIUM row last showed it ($FF: stale)
HPT:    .res    1                       ; frames to the next hull point
SPKT:   .res    1                       ; frames to the next burst of sparks
TL0:    .res    HUD_L1_LEN + 1          ; the SATURNIUM row's own buffer (the OS replays
                                        ;   the pointer, so it is never shared)
SPKN:   .res    1                       ; dashes left in this burst
RPF:    .res    1                       ; the repair effect's frame, 0..RP_FRAMES-1
RPT:    .res    1                       ; ...and frames left before the next one

        .segment "MSGDATA"
STR_SATN:   .byte   "SATURNIUM "        ; (10: the label and its space, cells 0..9)
IM_PILOT_OK_S:   .byte   "PILOT RESCUED", 0        ; the message bar's lines (hud_game.s
IM_PILOT_LOST_S: .byte   "PILOT LOST IN SPACE", 0  ;   IND_LO), spoken (mkspeech.py)
        .assert C_HPBAR = 10, error, "tunnel_hud.s: STR_SATN fills the cells before the bar"
        .popseg

; -----------------------------------------------------------------------------
; tun_hud_init - at the tunnel's start (step 0): the Saturnium read out of the hold,
; the clocks. TUNTEST (make run-tunnel) has no sector behind it, so it starts damaged
; and three-quarters full, to show the hull growing and the sparks coming.
; -----------------------------------------------------------------------------
tun_hud_init:
.if TUNTEST
        lda     #HIT_HP
        sta     SHIPHP
        lda     #150
        sta     TSATN
.else
        jsr     win_off                 ; (SATN is under the window)
        lda     SATN
        sta     TSATN
        jsr     win_on
.endif
        lda     #TUN_HPP
        sta     HPT
        lda     #1
        sta     SPKT
        stz     SPKN
        lda     #$FF
        sta     HCSAT
        stz     RPF
        lda     #TUN_RPD
        sta     RPT
        rts

; -----------------------------------------------------------------------------
; tun_hud_start - the frame the blinder comes off: the background holds the cockpit
; and nothing else (step 0 cleared it), so every row repaints.
; -----------------------------------------------------------------------------
tun_hud_start:
        jsr     indicate_reset          ; (nothing the sector left queued: it is gone)
        jsr     hud_reset
        lda     #$FF
        sta     HCSAT
        rts

; -----------------------------------------------------------------------------
; tun_hud_frame - once a frame while flying: the rows (paced), the hull, the sparks.
; -----------------------------------------------------------------------------
tun_hud_frame:
        jsr     tun_repair              ; the repair round the ship's picture
        jsr     bgtext_tick             ; the shared window ages first, as in the sector
        jsr     ind_timer_tick          ; ...and the message bar's hold, every frame
        inc     HUD_PHASE               ; ...and hud_game.s's cycle steps, as hud_tick
        lda     HUD_PHASE               ;   does it
        cmp     #HUD_PERIOD
        bcc     :+
        stz     HUD_PHASE
        lda     #0
:       cmp     #HUD_PH_ROW1            ; SHIPS + hull on row 1's phase...
        bne     :+
        jsr     hud_row1
        bra     @hp
:       cmp     #HUD_PH_ROW2            ; ...SATURNIUM on row 2's...
        bne     :+
        jsr     tun_sat_row
        bra     @hp
:       cmp     #HUD_PH_IND             ; ...and the message bar on its own
        bne     @hp
        jsr     indicate_tick
@hp:    dec     HPT                     ; the hull, a point every TUN_HPP frames
        bne     @spk
        lda     #TUN_HPP
        sta     HPT
        lda     SHIPHP
        cmp     #HP_MAX
        bcs     @spk
        inc     SHIPHP
@spk:   lda     TSATN                   ; sparks only at SATN_FULL and over
        cmp     #SATN_FULL
        bcc     @r
        lda     SPKN                    ; a burst in progress: one dash a frame?
        bne     @dash
        dec     SPKT
        bne     @r
        lda     #TUN_SPKP
        sta     SPKT
        jsr     prng                    ; 2 or 3
        and     #1
        clc
        adc     #2
        sta     SPKN
@dash:  jsr     tun_spark               ; (all of a burst on its first frame:
        dec     SPKN                    ;   each dash lives one frame)
        bne     @dash
@r:     rts

; tun_repair - one SPRITE: frame RPF of the repair effect at its own place (repair_art.s:
; RP_XL/RP_YL, high bytes RP_XH/RP_YH), drawn every frame; the next one every TUN_RPD.
; TUNCODE3, with its tables: bank 10 (TUNCODE, TUNCODE2) had no 24 bytes left for them.
        .pushseg
        .segment "TUNCODE3"
tun_repair:
        ldx     RPF
        txa
        clc
        adc     #RP_SLOT0
        sta     OS_ARG+0
        lda     RP_XL,x
        sta     OS_ARG+1
        lda     #RP_XH
        sta     OS_ARG+2
        lda     RP_YL,x
        sta     OS_ARG+3
        lda     #RP_YH
        sta     OS_ARG+4
        dec     RPT                     ; this one held long enough?
        bne     @draw
        lda     #TUN_RPD
        sta     RPT
        inx
        cpx     #RP_FRAMES
        bcc     :+
        ldx     #0
:       stx     RPF
@draw:  jmp     API_GPU_SPRITE          ; tail
        .popseg

; tun_spark - one dash at a random angle, TUN_SPKR0..TUN_SPKR1 from the centre, along
; the radius: fb x = TUN_CX + (portrait down), fb y = TUN_CY - (portrait right).
tun_spark:
        jsr     prng
        sta     TMP2                    ; the angle
        jsr     API_COS
        sta     CCV                     ; (cos and sin: the rocks' scratch, free here)
        lda     TMP2
        jsr     API_SIN
        sta     SSV
        lda     #TUN_SPKR0
        sta     SMB
        lda     SSV
        jsr     tun_sm
        clc
        adc     #TUN_CX
        sta     OS_ARG+0
        lda     CCV
        jsr     tun_sm
        sta     TMP
        lda     #TUN_CY
        sec
        sbc     TMP
        sta     OS_ARG+1
        lda     #TUN_SPKR1
        sta     SMB
        lda     SSV
        jsr     tun_sm
        clc
        adc     #TUN_CX
        sta     OS_ARG+2
        lda     CCV
        jsr     tun_sm
        sta     TMP
        lda     #TUN_CY
        sec
        sbc     TMP
        sta     OS_ARG+3
        jmp     API_GPU_LINE            ; tail

; -----------------------------------------------------------------------------
; tun_sat_row - the SATURNIUM row, when TSATN has moved and the layer can be claimed
; (a failed claim leaves HCSAT stale, so it tries again next cycle).
; -----------------------------------------------------------------------------
tun_sat_row:
        lda     TSATN
        cmp     HCSAT
        beq     @r
        jsr     bgtext_claim
        bcc     @r
        lda     TSATN
        sta     HCSAT
        ldx     #HUD_L1_LEN - 1         ; blank, NUL-terminated
        lda     #' '
:       sta     TL0,x
        dex
        bpl     :-
        stz     TL0 + HUD_L1_LEN
        jsr     msg_open                ; the label (MSGDATA, under the window)
        ldx     #C_HPBAR - 1
:       lda     STR_SATN,x
        sta     TL0,x
        dex
        bpl     :-
        jsr     msg_close
        lda     #'|'
        sta     TL0 + C_HPBAR
        sta     TL0 + C_HPEND
        jsr     tun_sat_fill            ; X cells of fill
        beq     @emit
        ldy     #C_HPFILL
        lda     #'x'
:       sta     TL0,y
        iny
        dex
        bne     :-
@emit:  stz     OS_ARG+0
        lda     #TUN_HUDROW0
        sta     OS_ARG+1
        stz     OS_ARG+2
        lda     #<TL0
        sta     OS_ARG+3
        lda     #>TL0
        sta     OS_ARG+4
        jmp     API_GPU_VTEXT_BG        ; tail
@r:     rts

; tun_sat_fill - X = (TSATN * HP_CELLS + SATN_FULL / 2) / SATN_FULL, held to HP_CELLS and
; never 0 while there is any; Z set when it is 0. Proportional like the hull bar: full
; at SATN_FULL, what the EMP costs (the bar stays full above it).
tun_sat_fill:
        ldx     #0
        lda     TSATN
        beq     @r
        ldx     #HP_CELLS               ; TSATN * HP_CELLS, 16 bit (tun_rmul: TSATN
        jsr     tun_rmul                ;   reaches 255, past umul's table)
        ldx     #0
        lda     PL                      ; + SATN_FULL / 2
        clc
        adc     #SATN_FULL / 2
        sta     PL
        bcc     @d
        inc     PH
@d:     lda     PL                      ; / SATN_FULL, by subtraction (<= 16 times)
        sec
        sbc     #SATN_FULL
        tay
        lda     PH
        sbc     #0
        bcc     @q
        sta     PH
        sty     PL
        inx
        bra     @d
@q:     cpx     #HP_CELLS + 1
        bcc     :+
        ldx     #HP_CELLS
:       cpx     #0
        bne     @r
        inx                             ; some, but under half a cell: one
@r:     cpx     #0
        rts
        .assert HP_CELLS <= 127, error, "tunnel_hud.s: tun_rmul takes a multiplier of at most 127"

; -----------------------------------------------------------------------------
; tun_hud_cloud - a Saturnium cloud caught: TUN_SATCLD more (to 255), the score.
; tun_hud_hit - a rock hit: TUN_SATHIT less (to 0).
; tun_hud_pod - a lifepod caught: a ship back (to TUN_LIVMAX), the score.
; -----------------------------------------------------------------------------
tun_hud_cloud:
        lda     TSATN
        clc
        adc     #TUN_SATCLD
        bcc     :+
        lda     #$FF
:       sta     TSATN
        ldx     #TUN_CLDPTS
        bra     tun_hud_score
tun_hud_hit:
        lda     TSATN
        sec
        sbc     #TUN_SATHIT
        bcs     :+
        lda     #0
:       sta     TSATN
        rts
tun_hud_pod:
        lda     #IM_PILOT_OK
        jsr     indicate_msg
        lda     LIVES
        cmp     #TUN_LIVMAX
        bcs     :+
        inc     LIVES
:       ldx     #TUN_PODPTS
        ; fall through
; tun_hud_score - X hundreds onto the score (score_add, hud_game.s: decimal digits).
tun_hud_score:
@l:     lda     #100
        jsr     score_add               ; (keeps X and Y)
        dex
        bne     @l
        rts
