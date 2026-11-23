; =============================================================================
; loader.s - the sector loader: code that RUNS IN THE CARTRIDGE WINDOW
; =============================================================================
; Everything that builds a sector's opening state - game_start, level_begin and
; what they call that nothing else does (load_level, load_foes, gate_load,
; base_load, the small resets), and the power-on tables - runs once a sector or
; once a session. It used to sit in RAM for the whole flight beside the code
; that runs every frame, ~1.1 KB of the run area, FIELDRAM and UPPER that the
; flight never touched. Now it is segment LDCODE, stored in ROM BANK 8 beside
; the level tables (LEVELS) and EXECUTED IN PLACE through the $8000-$9FFF
; window, the way bootstrap.s's boot_frame already runs every frame out of
; bank 0. Nothing is copied, so it costs no RAM at all. (2026-11-22, the
; freighter audit: the room it frees is the freighters' and the UFOs' raids.)
;
; IT IS IN THE LEVELS' OWN BANK ON PURPOSE: the loader reads LVL_* straight,
; with no lv_open / lv_close - those, and LVSAVE, are gone.
;
; THE ONE RULE - the window is showing ROM while this code runs, so:
;
;   * the loader may WRITE the RAM under the window (the object pool, the
;     enemies' arrays, SHAPES' neighbours) - a write reaches the RAM whatever
;     CART_EN says - but it must NEVER READ it: a read returns this bank's ROM,
;     silently. `inc X`, `dec X`, `lda X` on anything at $8000-$9FFF is a bug.
;     levels.s's old rule 2 ("between lv_open and lv_close, write but never
;     read") is now the rule for the whole loader.
;   * a RESIDENT routine that reads that RAM - rock_kin, init_cells, foe_spawn,
;     radar_census, satn_reset, indicate_msg - is called through WCALL, which
;     borrows the window back to RAM around it (win_off/win_on). A resident
;     routine that touches no window RAM (prng, hud_reset, shield_reset...) is
;     a plain jsr.
;   * the loader never calls win_off/win_on itself, and never cart_load: either
;     would take the window - this code - away from under the PC. A resident
;     routine that borrows the window and RESTORES the byte it found (msg_open,
;     the song's IRQ) is safe: what it restores is this bank.
;
; WHO MAY TELL WHETHER IT WORKED: scratch tracer of 2026-11-22 (memory note
; efs-free-space-2026-11) - every read of $8000-$9FFF with CART_EN clear,
; with its PC. After this move, no such read may come from an $8xxx PC.
;
; ENTRIES. The callers did not change: game_start and level_begin are still
; those names, now three-line stubs here (HIDATA - UPPER, resident in every
; overlay) that pick an entry and go through ld_enter; cart_init calls
; power_on the same way. All three are called INSIDE a win_off bracket
; (set_state_field, over_wait via state_tick, cart_init), so ld_enter saves
; both halves of that bracket - CART_BANK_MIR and WINSAVE - since every
; WCALL inside reuses WINSAVE, and puts both back on the way out.
;
; ONE FRAME OR SEVERAL. level_begin is a TABLE OF STEPS (gameover.s,
; ld_steps), run back to back. It takes ~230 k cycles at level 0 today - a
; whole frame (prng's scatter alone is ~100 k) - and it is run in the same
; frame as the trigger, synchronously, because the FIELD/SCREEN overlay taught
; that a transition deferred to a later frame breaks the background in
; madsim while preview.py still passes (memory: efs-field-screen-overlay).
; If a sector ever has to load across frames, the step table is where it is
; cut: a LOADING state that runs some steps a frame with the cursor kept in
; RAM, drawing a held screen meanwhile. Not built - nothing needs it yet.
; =============================================================================
LDR_BANK    = 8                 ; cart.cfg: LDCODE is in ROM8, with LEVELS
LDCNT       = $73B6             ; load_foes' record countdown. NOT under the
                                ;   window - the loader can't read that back.
                                ;   It is the byte levels.s's LVSAVE had
        .assert EMPHAVE < LDCNT && LDCNT < CAPN, error, "loader.s: LDCNT has landed inside pickup.s's or capsule.s's block"

LD_GAME     = 0                 ; ld_tab's entries, x2
LD_LEVEL    = 2
LD_POWER    = 4

; WCALL target - from the loader, call a resident routine that reads the RAM
; under the window. A goes in and comes back out; X and Y go in, and come back
; as the routine left them; the flags do not survive.
.macro  WCALL   target
        jsr     wcall
        .addr   target
.endmacro

        .pushseg
        .segment "HIDATA"

; -----------------------------------------------------------------------------
; game_start / level_begin / power_on - the resident names, into the loader.
; -----------------------------------------------------------------------------
power_on:
        ldx     #LD_POWER
        bra     ld_enter
game_start:
        ldx     #LD_GAME
        bra     ld_enter
level_begin:
        ldx     #LD_LEVEL
ld_enter:
        lda     WINSAVE                 ; the caller's bracket, both halves
        pha
        lda     CART_BANK_MIR
        pha
        lda     #LDR_BANK | CART_EN     ; (cart_bank keeps X and Y)
        jsr     API_CART_BANK
        jsr     ld_disp                 ; ...in the window from here
        jsr     ws_sync                 ; ...then the wall slots' tenant the
                                        ;   sector asked for (slots.s), out of it
        pla
        jsr     API_CART_BANK           ; the caller's window, CART_EN as it was
        pla
        sta     WINSAVE
        rts

; -----------------------------------------------------------------------------
; wcall - WCALL's body. The word after the caller's JSR is the target; it is
; read while the window still shows the loader, and the return skips it. Self-
; modifying (UPPER is RAM), so it needs no byte of RAM of its own.
; -----------------------------------------------------------------------------
wcall:
        sta     @ain+1                  ; A in
        pla                             ; the JSR's last byte - 1 below the word
        sta     @rd+1
        clc
        adc     #2
        sta     @rlo+1
        pla
        sta     @rd+2
        adc     #0
        pha                             ; return past the word: hi...
@rlo:   lda     #$00
        pha                             ; ...lo
        phy
        ldy     #2
@rd:    lda     $FFFF,y                 ; the word, out of the loader's bank
        sta     @go,y
        dey
        bne     @rd
        ply
        jsr     win_off                 ; A only
@ain:   lda     #$00
@go:    jsr     $FFFF
        sta     @aout+1
        jsr     win_on                  ; A only
@aout:  lda     #$00
        rts

        .segment "LDCODE"

; ld_disp - X = LD_*: into that entry. Its rts is ld_enter's.
ld_disp:
        jmp     (ld_tab,x)
ld_tab: .addr   ld_game_start, ld_level_begin, ld_power_on

        .popseg
