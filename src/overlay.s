; =============================================================================
; overlay.s - the FIELD / SCREEN overlay over DEMO_RAM
; =============================================================================
; DEMO_RAM ($C000-$DEFF) holds one of two tenants, never both:
;   FIELD  - CODE5 + CODE6, the flight engine's DEMO_RAM code (cam.s's enemy
;            framing, game_start/level_begin, gate.s, emp.s, trainer.s,
;            pulsar.s, base.s's field hooks) - needed whenever SCR_STATE is
;            SC_PLAY (0), i.e. the world is simulated.
;   SCREEN - UICODE (screens.s and what it includes) - needed whenever
;            SCR_STATE is anything else, i.e. only a screen is up.
; frame_body (main.s) already proves the two never share a frame - SC_PLAY
; falls straight into the field and scr_frame is not called; any other value
; hands the WHOLE frame to scr_frame and the field's per-frame code never
; runs. This file is what makes that boundary also a RAM boundary, following
; CETAS's states.s load_hicode/load_uicode. See open_questions.md H1 for the
; audit and design_technical.md 11.19 for the RAM map.
;
; ONE CHOKE POINT PER DIRECTION, AND CONTENT CODE NEVER DOES THE SWAP ITSELF.
; SCREEN -> FIELD goes through set_state_field below; FIELD -> SCREEN sets
; SCR_STATE and lets frame_body notice it next frame (screens are cheap to
; delay into - see frame_body). Content code that wants to enter the field
; (title_frame's FIRE, sector_frame's FIRE) does not set SCR_STATE, does not
; touch BGDONE, and does not call game_start/level_begin - it loads X with
; which one it wants and tail-JMPS to set_state_field. Never JSR: title_frame
; and sector_frame are UICODE, about to be overwritten by the very call they
; are making, and a JSR's return address would be inside that overwritten
; range the instant it lands - a JMP leaves nothing on the stack pointing
; there, so there is nothing to corrupt. set_state_field's own rts, at the
; end, pops the return address frame_body's original JSR (from cart_frame)
; left untouched three tail-jumps back (frame_body -> scr_frame ->
; title_frame/sector_frame -> here) and lands correctly in cart_frame.
; =============================================================================

        .import __CODE5_LOAD__, __CODE5_RUN__, __CODE5_SIZE__
        .import __CODE6_LOAD__, __CODE6_RUN__, __CODE6_SIZE__
        .import __UICODE_LOAD__, __UICODE_RUN__, __UICODE_SIZE__
                                        ; game_start/level_begin (gameover.s)
                                        ;   need no import - one translation
                                        ;   unit, same as every other cross-file
                                        ;   call in this cartridge

CODE5_BANK  = 4                 ; must match cart.cfg's MEMORY order and
CODE6_BANK  = 6                 ;   bootstrap.s's own copies of these - nothing
UICODE_BANK = 6                 ;   links the two together but a bank number

OVL_FIELD  = 0                  ; matches boot: bootstrap.s's boot_segs copies
                                 ;   CODE5+CODE6 unconditionally, so DEMO_RAM
                                 ;   holds FIELD from power-on, before
                                 ;   overlay_cur below is even initialised
OVL_SCREEN = 1

FE_NEWGAME    = 1                ; title_frame's FIRE (screens.s): jsr game_start
FE_NEXTSECTOR = 2                ; sector_frame's FIRE (gate.s): jsr level_begin

        .segment "CODE8"

; Row: bank(1) + load16 + run16 + size16 = 7 bytes, cart_load's own OS_ARG
; shape (bootstrap.s), $FF-terminated (a real bank never reads FF here - the
; image has at most a few dozen banks).
ovl_field_segs:
        .byte   CODE5_BANK
        .word   __CODE5_LOAD__, __CODE5_RUN__, __CODE5_SIZE__
        .byte   CODE6_BANK
        .word   __CODE6_LOAD__, __CODE6_RUN__, __CODE6_SIZE__
        .byte   $FF
ovl_screen_segs:
        .byte   UICODE_BANK
        .word   __UICODE_LOAD__, __UICODE_RUN__, __UICODE_SIZE__
        .byte   $FF

overlay_cur: .byte OVL_FIELD    ; which tenant DEMO_RAM holds right now

; -----------------------------------------------------------------------------
; set_state_field - the ONLY place SCR_STATE is set to SC_PLAY. X = FE_NEWGAME
; or FE_NEXTSECTOR. Loads CODE5/CODE6, clears BGDONE UNCONDITIONALLY (a screen
; was showing no matter which of the two callers got here), runs the one-time
; action inside a win_off/win_on bracket (the object pool lives under the
; window), and returns to cart_frame. See the file header for why this is a
; tail-JMP target, never a jsr target.
; -----------------------------------------------------------------------------
set_state_field:
        stz     SCR_STATE
        phx                             ; ovl_load_field clobbers X; FE_* is
        jsr     ovl_load_field          ;   still needed once it returns
        plx
        stz     BGDONE
        jsr     win_off
        cpx     #FE_NEWGAME
        bne     @sector
        jsr     game_start
        bra     @done
@sector:
        jsr     level_begin
@done:
        jmp     win_on                  ; tail: its rts is this call's own

; -----------------------------------------------------------------------------
; ovl_load_field / ovl_load_screen - cart_load the group's table unless it is
; already resident. ovl_load_field is also frame_body's safety net: normally
; set_state_field has already loaded FIELD by the time frame_body sees
; SCR_STATE = SC_PLAY, but a path that reaches SC_PLAY some OTHER way (a test
; harness poking SCR_STATE directly - tools/preview.py's boot_cart does) still
; gets FIELD loaded and BGDONE cleared, just without a queued action.
; -----------------------------------------------------------------------------
ovl_load_field:
        lda     overlay_cur
        cmp     #OVL_FIELD
        beq     @ret
        lda     #OVL_FIELD
        sta     overlay_cur
        lda     #<ovl_field_segs
        ldx     #>ovl_field_segs
        jsr     ovl_walk
@ret:   rts

ovl_load_screen:
        lda     overlay_cur
        cmp     #OVL_SCREEN
        beq     @ret
        lda     #OVL_SCREEN
        sta     overlay_cur
        lda     #<ovl_screen_segs
        ldx     #>ovl_screen_segs
        jsr     ovl_walk
@ret:   rts

; -----------------------------------------------------------------------------
; ovl_walk - A/X = table addr lo/hi. Reads 7-byte rows into OS_ARG (self-
; patched base + ,Y so no zero page is spent - ZP had as little as 2 B free
; the same day this was written), cart_load per row, stops at the $FF
; sentinel. bootstrap.s's boot_init loop, generalised to a runtime address.
; -----------------------------------------------------------------------------
ovl_walk:
        sta     @rd+1
        stx     @rd+2
        ldy     #0
@row:   ldx     #0
@arg:
@rd:    lda     $FFFF,y
        sta     OS_ARG,x
        iny
        inx
        cpx     #7
        bne     @arg
        lda     OS_ARG+0
        cmp     #$FF
        beq     @done
        jsr     API_CART_LOAD
        bra     @row
@done:  rts
