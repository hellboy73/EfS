; =============================================================================
; gameover.s - the two states this game has, and the line between them
; =============================================================================
; Until now there was one: the frame ran, and it ran the same way for ever.
; Lives were a number in the corner that nothing ever decremented. This file is
; the smallest honest state machine that makes a life mean something:
;
;   GS_PLAY   the game. The ship flies, and losing a life costs one of LIVES.
;   GS_OVER   the last one is gone. The world still runs - the rocks still
;             drift and grind into each other - but the ship is not in it, the
;             stick is dead, and one line across the middle of the screen
;             alternates GAME OVER / PUSH FIRE until FIRE starts a new game.
;
; It is deliberately TWO and not five. CETAS has a title screen, a level
; summary, a continue countdown and a hall of fame, and every one of those is a
; real screen with its own art and its own song; none of them exists here yet
; and inventing them as a side effect of "the ship should explode" would be the
; wrong way round. What this gives is the SHAPE - one GSTATE byte, one restart
; entry point - so that when those screens arrive they have somewhere to attach
; instead of a frame loop with no seams in it.
;
; THE SEQUENCE, from the hit that empties the hull on the last life:
;
;   frame 0        ship_die: the puff on the ship's own position, SE_DEATH, and
;                  SHIPGONE. The outline and the flames stop being drawn, the
;                  stick is masked to zero (input.s JOYIN), and the throttle
;                  starts walking itself back to the resting tier - so the
;                  camera EASES out to 1:1 rather than snapping there
;   frames 0-119   the wreck: four pieces of the hull drifting and tumbling
;                  (debris.s). The world is untouched and keeps running
;   frame 120      GS_OVER. The banner goes up on the HUD's own next paint
;                  phase, opening on GAME OVER, and FIRE is armed - not before,
;                  so the reflexive shot a player fires as the ship dies cannot
;                  skip the wreck
;   FIRE           game_start: a whole new game, from level 1 with a fresh
;                  score and three ships
;
; THE BANNER IS BACKGROUND TEXT, like everything else this game prints. It goes
; through hud_game.s's bgtext_claim arbiter on a paint phase of its own, so it
; can never land inside another row's replay window (see that file's note on why
; that matters), and once painted it costs the GPU nothing per frame - it is in
; the VRAM background, which the hardware re-copies for free. That is also why
; it has to be UNPAINTED explicitly on restart: nothing clears the background
; but another write over the same cells. Each swap of the two words is one such
; write, which is the whole price of the alternation: one command every 64
; frames, and nothing at all in between.
; =============================================================================

GS_PLAY     = 0
GS_OVER     = 1

SHIP_INVULN = 180               ; frames a respawned ship cannot be hurt, 3 s at
                                ;   60.317 Hz - CETAS's HERO_INVULN, which is
                                ;   long enough to fly out of whatever killed
                                ;   you and short enough not to be a free pass

; --- THE BANNER IS ONE LINE, AND THE TWO WORDS TRADE PLACES ON IT ------------
; "GAME OVER" and "PUSH FIRE" are both NINE characters, which is not a
; coincidence any more - it is the constraint the second one was written
; against. They occupy the same nine cells on the same row and swap every
; GO_SWAP frames, so nothing on the screen moves: the line does not jump width,
; there is no second row of text competing with it, and the alternation itself
; is what draws the eye. Two static rows said the same thing and sat there.
GO_ROW      = 24                ; the screen's middle text row
GO_COL      = 14                ; ...and centred on it: (37 - 9) / 2
GO_SWAP     = 64                ; frames each word holds, ~1.06 s at 60.317 Hz
        .assert (GO_SWAP / HUD_PERIOD) * HUD_PERIOD = GO_SWAP, error, "gameover.s: GO_SWAP is not a whole number of paint periods, so the swap would land at a different offset every time and the cadence would limp"

GO_BLANK    = 0                 ; what OVWANT and OVC can be
GO_OVER     = 1
GO_FIRE     = 2

; --- state, straight after debris.s's block ($6FBE on) -----------------------
GSTATE      = $6FBE             ; GS_PLAY / GS_OVER
OVWANT      = $6FBF             ; which of the three the row should be showing
OVC         = $6FC0             ; ...and which it actually IS, so it is never
                                ;   repainted for nothing
OVSUB       = $6FC1             ; frames left before the two words trade places

        .segment "HIDATA"

; -----------------------------------------------------------------------------
; state_tick - once a frame, first thing inside the win_off bracket.
; -----------------------------------------------------------------------------
; Early, and inside the bracket, for one reason each: the invulnerability
; counter has to age before anything reads its blink phase, and game_start
; walks the object pool, which lives under the cartridge window (window.s).
; -----------------------------------------------------------------------------
state_tick:
        lda     SHIPINV                 ; the respawn blink ages on every frame,
        beq     @nodeb                  ;   whatever else is happening
        dec     SHIPINV

@nodeb: lda     DBN                     ; the wreck, while there is one
        beq     @arm
        jsr     debris_tick             ; drift, tumble, and count down - and
        bra     @over                   ;   the frame the count reaches 0 is
                                        ;   still a frame the pieces are DRAWN
                                        ;   on, because do_debris runs later in
                                        ;   it. So the banner waits for the NEXT
                                        ;   frame; arming it here would eat the
                                        ;   wreck's last frame, which is exactly
                                        ;   what the first cut did (59 drawn for
                                        ;   a DEBRIS_FRAMES of 60)

@arm:   lda     SHIPGONE                ; no wreck, no ship and still in play:
        beq     @over                   ;   THIS is the frame the game is over on
        lda     GSTATE
        bne     @over
        lda     #GS_OVER                ; the banner, and FIRE is live from here
        sta     GSTATE
        lda     #GO_OVER                ; ...opening on the word that says what
        sta     OVWANT                  ;   happened, not the one that asks for
        lda     #GO_SWAP                ;   something back
        sta     OVSUB
        lda     #HUD_PH_OVER - 1        ; ...and the paint schedule is wound so
        sta     HUD_PHASE               ;   the word lands on the NEXT frame
                                        ;   rather than up to a whole period
                                        ;   later. The gap between the wreck
                                        ;   vanishing and the banner appearing
                                        ;   should be a chosen beat, not
                                        ;   whatever the stagger happened to be
                                        ;   on the frame the ship died

@over:  lda     GSTATE
        beq     @done                   ; GS_PLAY - nothing to wait for

        dec     OVSUB                   ; ...and the two words trade places. The
        bne     @fire                   ;   counter runs on the FRAME and not on
        lda     #GO_SWAP                ;   the paint phase, which is exact
        sta     OVSUB                   ;   rather than approximate only because
        lda     OVWANT                  ;   GO_SWAP is a whole number of periods
        eor     #(GO_OVER ^ GO_FIRE)    ;   - the flip then always lands the same
        sta     OVWANT                  ;   distance before the row's own phase
@fire:
        lda     JOY1_PRESS
        and     #JOY_FIRE
        beq     @done
        lda     JOY1_PRESS              ; consume the edge, so the press that
        and     #<~JOY_FIRE             ;   restarts does not ALSO come out of
        sta     JOY1_PRESS              ;   the new game's first gun frame
        jsr     game_start
@done:  rts

; -----------------------------------------------------------------------------
; ship_hidden - C SET = the ship is not drawn this frame.
; -----------------------------------------------------------------------------
; The one place that answers this, read by emit_ship (ship.s) and flame_draw
; (thrust.s) so the hull and its nozzles can never disagree about whether there
; is a ship there. CETAS learned that the hard way with a boost sticker left
; floating over a whale that was not being drawn (its hero_boost_draw note).
;
; Bit 3 of the counter is the blink phase, so it is EIGHT frames shown and
; eight hidden - ~3.75 Hz. That is the same test CETAS blinks its respawned
; whale with (`and #8` on hero_invuln) and therefore the same rate, whatever
; that file's own comment says about it; measured here rather than copied, and
; it reads as a deliberate pulse rather than a flicker, which is what a three-
; second grace period wants.
; -----------------------------------------------------------------------------
ship_hidden:
        lda     SHIPGONE
        bne     @hide
        lda     SHIPINV
        beq     @show
        and     #8
        bne     @hide
@show:  clc
        rts
@hide:  sec
        rts

; -----------------------------------------------------------------------------
; gameover_row - the banner's one line, on its own paint phase (HUD_PH_OVER).
; -----------------------------------------------------------------------------
; It compares what is wanted against what it last put there, exactly as hud_row1
; and hud_row2 compare their caches - so a paint that could not claim the layer
; leaves OVC stale and tries again on the next phase, and a word that is already
; up costs one compare a phase and nothing else. state_tick does the swapping;
; this only ever answers "is the screen showing what it should".
; -----------------------------------------------------------------------------
gameover_row:
        lda     OVWANT
        cmp     OVC
        beq     @ret
        jsr     bgtext_claim
        bcc     @ret
        lda     OVWANT
        sta     OVC
        beq     @blank                  ; GO_BLANK
        cmp     #GO_OVER
        beq     @over
        lda     #<GO_S2                 ; GO_FIRE
        ldx     #>GO_S2
        bra     @go
@over:  lda     #<GO_S1
        ldx     #>GO_S1
        bra     @go
@blank: lda     #<GO_B
        ldx     #>GO_B
@go:    ldy     #GO_ROW
        sta     OS_ARG+3
        stx     OS_ARG+4
        lda     #GO_COL
        jmp     go_emit
@ret:   rts

; A = the cell, Y = the line, OS_ARG+3/4 already the string.
go_emit:
        sta     OS_ARG+0
        sty     OS_ARG+1
        stz     OS_ARG+2                ; no sub-cell scroll
        jmp     API_GPU_VTEXT_BG

; The banner is a STATIC string and is handed to the OS by pointer, unlike the
; HUD's rows, which are built into RAM buffers because their contents change.
; That is safe for the same reason those buffers have to be left alone for a
; frame: the OS replays the POINTER into the other background buffer on the
; following frame, and what these point at never moves. The blanks are separate
; strings of exactly the same length - a background text write is destructive
; per CELL, so unpainting means writing spaces over the same span and nothing
; wider (hud_game.s's note on why the rows have fixed widths).
GO_S1:  .byte   "GAME OVER", 0
GO_S2:  .byte   "PUSH FIRE", 0
GO_B:   .byte   "         ", 0
GO_END:
        .assert GO_S2 - GO_S1 = GO_B - GO_S2, error, "gameover.s: the two words are no longer the same width - they would not swap in place, and the shorter one would leave a tail of the longer"
        .assert GO_END - GO_B = GO_B - GO_S2, error, "gameover.s: the blank no longer covers exactly what the words write"
        .assert GO_COL + (GO_B - GO_S2) <= HUD_COLS + 1, error, "gameover.s: the banner runs off the VTEXT grid"

; -----------------------------------------------------------------------------
; game_start - everything a NEW GAME resets, and nothing a session does once.
; -----------------------------------------------------------------------------
; Called twice: from cart_init, where it is the second half of booting, and
; from state_tick when FIRE ends a game over. The split is exactly the question
; "would doing this twice be wrong?" - the quarter-square tables, the star and
; mote fields, the PRNG seed, the sprite uploads and the song are all built or
; started once and stay built, so they are NOT here; everything that describes
; the state of a game in progress is.
;
; It runs inside the win_off bracket in both callers, because load_level does
; not merely fill the object pool - init_cells walks it back to build the
; sector grid and free_init rebuilds the free stack, and the pool lives under
; the cartridge window.
; -----------------------------------------------------------------------------
game_start:
        stz     GSTATE                  ; ...the game is a game again
        stz     SHIPGONE
        stz     SHIPINV
        stz     DBN                     ; ...no wreck left over
        stz     OVWANT                  ; ...and the banner comes off the screen
                                        ;   on the next two paint phases

        stz     HEAD                    ; (load_level overwrites this with the
                                        ;  level's own heading - it is zeroed
                                        ;  first so BASEHEAD below is reliably
                                        ;  different from it)
        lda     #<(TIER_ZERO*128)       ; THRTL starts at TIER_ZERO exactly, so
        sta     THRTLL                  ;   TIER derives to TIER_ZERO and THFRAC
        lda     #>(TIER_ZERO*128)       ;   to 0 on the very first frame - see
        sta     THRTLH                  ;   do_input for the shift that recovers
        lda     #TIER_ZERO              ;   both from this
        sta     TIER
        sta     ETIER
        stz     BOOSTN
        stz     BOOSTARM
        stz     TPWIN                   ; ...and no FIRE2 click carries over
        stz     TPLOCK                  ;   from the life that just ended
        lda     #1                      ; unlimited for now - see BOOST_AVAIL
        sta     BOOST_AVAIL
        stz     SHOFFL
        stz     SHOFFH
        stz     TURNVL
        stz     TURNVH
        stz     PSHOFFL
        stz     PSHOFFH
        stz     HEADF
        stz     TRAVL
        stz     TRAVH
        lda     #$80                    ; != HEAD, so the next frame builds the
        sta     BASEHEAD                ;   tables and rebases the star bases
        sta     ROTHEAD
        lda     #128                    ; 1:1, and ZSHEAD != it so the next
        sta     ZOOMH                   ;   frame builds the scale table too
        sta     ZEASH
        stz     ZEASL
        stz     ZSHEAD

        lda     #HP_MAX                 ; the ship's hit points - see SHIPHP,
        sta     SHIPHP                  ;   and HP_MAX for why the number is
        stz     KNBXL                   ;   not here
        stz     KNBXH
        stz     KNBYL
        stz     KNBYH
        lda     #$FF
        sta     SHIPKILL_PEND
        stz     BGFLASH                 ; idle - nothing zeroes cartridge RAM
                                        ;   for us, and a stray 1 here would
                                        ;   open the game on a lit screen
        jsr     voice_reset             ; ...and no voice is claimed, or the
                                        ;   first sound of the new game is
                                        ;   refused by the last one's death
        stz     PSST_WT                 ; ...and no nozzle was firing last
        stz     PSST_WA                 ;   frame, or the game opens on a puff
        stz     PSST_WB

        jsr     shots_init              ; every gun and puff slot free - nothing
                                        ;   zeroes cartridge RAM for us
        jsr     lsr_reset               ; ...the gun chosen, the beam dark
        ldx     #START_LEVEL            ; ...and the field, the ship's place in
        jsr     load_level              ;   it and the sector grid, all out of
        jsr     radar_census            ;   levels.s. The radar's per-class rock
                                        ;   count is taken here, once, off the
                                        ;   field load_level just built - see
                                        ;   radar_sens
        jsr     load_foes               ; ...and then the enemies - AFTER
                                        ;   load_level, because it falls through
                                        ;   into init_cells and nothing may come
                                        ;   between the two (see load_level)
        jsr     hud_init                ; the score, the lives, the level number
        lda     #START_LEVEL            ;   and the caches behind the two rows -
        sta     CURLEV                  ;   none of it is zeroed for us. The
                                        ;   level is taken here rather than
                                        ;   inside load_level so that routine
                                        ;   stays a pure field builder with no
                                        ;   HUD in it
        lda     #HUD_PH_OVER - 1       ; ...and the paint schedule is wound to
        sta     HUD_PHASE               ;   just before the BANNER's two phases,
                                        ;   not to just before row 1 as hud_reset
                                        ;   leaves it. Otherwise the banner is
                                        ;   six frames behind the ship coming
                                        ;   back and the new game opens with GAME
                                        ;   OVER still written across it - a
                                        ;   tenth of a second, and visible. The
                                        ;   two readouts it delays instead are
                                        ;   not urgent on the frame a game starts
        lda     #IM_LEVEL               ; ...and the bar opens with a word
        jmp     indicate_msg            ; tail

        .segment "CODE2"                ; back to the segment main.s included
                                        ;   this file inside
