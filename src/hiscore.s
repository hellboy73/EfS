; =============================================================================
; hiscore.s - the hall of fame's TABLE, and the page of RAM it keeps for life
; =============================================================================
; No screen yet: this is the data the title's attract panel and the sign-up
; after a game will read and write (open_questions.md H1). What is settled here
; is WHERE it lives and WHEN it is filled, because both decide whether it
; survives:
;
;   WHERE  the top page of DEMO_RAM, $DF00-$DFFF - "KEEP". cart.cfg's DEMO_RAM
;          area stops at $DEFF, so no segment the linker places there can ever
;          grow over it, and the screens' code overlays planned for $C000
;          (H1) will be sized against the same $1F00. It is always mapped, so
;          no win_off bracket to read it and a pointer into it may be handed to
;          the OS; and it is not in the $0200-$77FF the OS clears.
;
;   WHEN   once, from cart_init - NEVER from game_start. That split is the
;          whole of "survives between games": game_start is what FIRE on a
;          game over runs, and everything it touches is a new game's. A RESET
;          copies the CPU EPROM back over $C000-$DFFF, demo and all, so the
;          table lasts exactly one power-on, as CETAS's does. MAD-65 has no
;          save API to do better with.
;
; A RECORD is HOF_REC bytes: the score, then three initials, then the level.
; The score is in the HUD's own format - SCORE_DIGITS ASCII digits, MSD first,
; ZERO-padded (hud_game.s SCORE) - so "does this score qualify" is a plain byte
; compare from the left, and a sign-up copies SCORE across without formatting
; anything. The table is kept sorted, best first.
; =============================================================================

DEMO_KEEP   = $DF00             ; must match where cart.cfg's DEMO_RAM area ends
DEMO_TOP    = $E000             ; ...and never at or past this: the running OS

NUM_HOF     = 8                 ; entries on the board
HOF_SCORE   = 0                 ; offsets inside a record
HOF_INIT    = SCORE_DIGITS
HOF_LEVEL   = SCORE_DIGITS + 3  ; 1-based, as the HUD shows it
HOF_REC     = SCORE_DIGITS + 4

HOF         = DEMO_KEEP        ; NUM_HOF * HOF_REC bytes
HOF_END     = HOF + NUM_HOF * HOF_REC
        .assert HOF_END <= DEMO_TOP, error, "hiscore.s: the table runs past KEEP into the OS"
        .assert NUM_HOF * HOF_REC <= 128, error, "hiscore.s: hof_seed counts the table down with bpl"
; KEEP from HOF_END to $DFFF is free for whatever else must outlive an overlay
; swap (which overlay is resident, whether the intro has played).

        .pushseg
        .segment "CODE5"

; -----------------------------------------------------------------------------
; hof_seed - the default board into KEEP. cart_init only; clobbers A and X.
; -----------------------------------------------------------------------------
; KEEP holds the demo's bytes on entry, so this runs before anything reads it.
; -----------------------------------------------------------------------------
hof_seed:
        ldx     #NUM_HOF * HOF_REC - 1
@lp:    lda     hof_def,x
        sta     HOF,x
        dex
        bpl     @lp
        rts

; The default board - PLACEHOLDER names and scores, best first. The initials
; are the five Titan ships' hull numbers (story_levels.md) and three more.
hof_def:
        .byte   "0050000", "T01", 5
        .byte   "0040000", "T02", 5
        .byte   "0030000", "T03", 4
        .byte   "0020000", "T04", 4
        .byte   "0010000", "T05", 3
        .byte   "0005000", "EFS", 2
        .byte   "0002500", "M65", 2
        .byte   "0001000", "TTN", 1
hof_def_end:
        .assert hof_def_end - hof_def = NUM_HOF * HOF_REC, error, "hiscore.s: hof_def does not hold NUM_HOF records of HOF_REC bytes"

        .popseg
