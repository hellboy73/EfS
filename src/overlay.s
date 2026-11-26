; =============================================================================
; overlay.s - the FIELD / SCREEN overlay over DEMO_RAM
; =============================================================================
; DEMO_RAM ($C000-$DEFF) holds one of two tenants, never both:
;   FIELD  - CODE5 + CODE6 + CODE9, the flight engine's DEMO_RAM code (cam.s's enemy
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
        .import __CODE9_LOAD__, __CODE9_RUN__, __CODE9_SIZE__
        .import __UICODE_LOAD__, __UICODE_RUN__, __UICODE_SIZE__
        .import __TUNCODE_LOAD__, __TUNCODE_RUN__, __TUNCODE_SIZE__
        .import __TUNCODE2_LOAD__, __TUNCODE2_RUN__, __TUNCODE2_SIZE__
        .import __TUNCODE3_LOAD__, __TUNCODE3_RUN__, __TUNCODE3_SIZE__
        .import __CODE_LOAD__, __CODE_RUN__, __CODE_SIZE__
        .import __CODE2_LOAD__, __CODE2_RUN__, __CODE2_SIZE__
        .import __CODE3_LOAD__, __CODE3_RUN__, __CODE3_SIZE__
        .import __CODE4_LOAD__, __CODE4_RUN__, __CODE4_SIZE__
                                        ; game_start/level_begin (gameover.s)
                                        ;   need no import - one translation
                                        ;   unit, same as every other cross-file
                                        ;   call in this cartridge

CODE5_BANK  = 4                 ; must match cart.cfg's MEMORY order and
CODE6_BANK  = 6                 ;   bootstrap.s's own copies of these - nothing
CODE9_BANK  = 2                 ;   (the EMP mine's hull, empmine.s)
TUNCODE_BANK = 10
TUNCODE3_BANK = 11              ; the lifepods (tunnel_pod.s)
ENG0_BANK   = 0                 ; the flight engine's four banks - bootstrap.s's CODE_BANK ..
ENG1_BANK   = 1                 ;   CODE4_BANK, which nothing links to this file but a number
ENG3_BANK   = 3
ENG4_BANK   = 4
UICODE_BANK = 6                 ;   links the two together but a bank number

OVL_FIELD  = 0                  ; matches boot: bootstrap.s's boot_segs copies
                                 ;   CODE5+CODE6 unconditionally, so DEMO_RAM
                                 ;   holds FIELD from power-on, before
                                 ;   overlay_cur below is even initialised
OVL_SCREEN = 1
OVL_TUNNEL = 2                  ; the third tenant: TUNCODE (tunnel.s)

FE_NEWGAME    = 1                ; title_frame's FIRE (screens.s): jsr game_start
FE_NEXTSECTOR = 2                ; sector_frame's FIRE (gate.s): jsr level_begin

        .segment "CODE8"

; THE SLOT ROWS, in RAM: ws_sync (slots.s) patches them with the tenant the
; sector wants. A row is bank(1) + load16 + run16 + size16 = 7 bytes, cart_load's
; own OS_ARG shape, and a list ends on a $FF bank. Every other row list is ROM
; (LDCODE, below): ld_pump selects bank 8 to read a row.
ovl_slotb_row:                          ; slot B, the wall slots' tenant in DEMO_RAM:
        .byte   BSFRAME_BANK            ;   FIELD's last row (ovl_load_field queues
        .word   __BSFRAME_LOAD__, __BSFRAME_RUN__, __BSFRAME_SIZE__ ;   it after
        .byte   $FF                     ;   FIELD's own) - the base at power-on
ovl_slota_row:                          ; ...and slot A's, filled in by ws_sync
        .res    7, 0
        .byte   $FF

overlay_cur: .byte OVL_FIELD    ; which tenant DEMO_RAM holds right now

; -----------------------------------------------------------------------------
; set_state_field - the ONLY place SCR_STATE is set to SC_PLAY. X = FE_NEWGAME
; or FE_NEXTSECTOR. QUEUES FIELD's copy, clears BGDONE UNCONDITIONALLY (a
; screen was showing no matter which of the callers got here) and queues the
; one-time action (ld_request); none of it runs here. From the next frame on,
; ld_pump runs the copy and then the loader's steps a piece a frame, and the
; field's first frame comes when they are done. Still a tail-JMP target, never
; a jsr target (the file header): harmless now that nothing is overwritten
; this frame, and the callers are UICODE that the copy WILL overwrite.
; -----------------------------------------------------------------------------
set_state_field:
        stz     SCR_STATE
        stz     BGDONE
        phx
        ldx     #LD_OVLF                ; ovl_load_field, in the loader's bank
        jsr     ld_enter
        plx
        ; fall through
; ld_request - X = FE_*: the loader's steps from that action's first one -
; game_start's head (FE_NEWGAME) or level_begin's first step (FE_NEXTSECTOR),
; ld_all's entries 0 and 1 (gameover.s). Also gameover.s's FIRE on GAME OVER,
; which stays in the field and so needs no copy.
ld_request:
        dex                             ; FE_NEWGAME = 1, FE_NEXTSECTOR = 2
        txa
        asl     a
        sta     lj_step
        inc     lj_act
        rts

; =============================================================================
; THE STAGED LOAD (open_questions.md E12's rule for the loader, the user,
; 2026-11-26): no long code runs without a frame to show for it. A frame that
; has loading to do is the LOADER'S, whole: ld_pump runs first in frame_body,
; copies and runs steps for as long as FRAME_POS allows, and frame_body then
; returns, so the frame still closes its (empty) list - the background holds
; whatever picture it had, the image layer is blank. Two kinds of work:
;
;   COPIES  ovl_walk only QUEUES a table of rows; ld_pump copies them in
;           256-byte pages with cart_load, each started only while
;           FRAME_POS is under LD_POS_MAX. Every overlay swap, the wall slots'
;           tenant included, goes through here, so the next sector or tunnel
;           transition needs nothing new. Resident by necessity: cart_load
;           takes the window, so this cannot run from it.
;   STEPS   lj_act set: the loader's step table (gameover.s ld_steps_run, in
;           the window, bank 8), each step started only near the top of a
;           frame. Run after the queue is empty, since a step may need the
;           code a copy brings.
;
; ovl_flush runs the queue to the end, untimed: cart_init's, which has no frame
; to protect yet, and frame_body's safety net for py65 (preview.py).
; =============================================================================
LD_POS_MAX  = 200               ; no page starts past this (232 = the frame):
                                ;   a page is ~15 (cart_load, ~59 cycles a
                                ;   byte), so 215 at the latest
LJ_QMAX     = 2                 ; lists queued at once: FIELD's (ROM) and then
                                ;   slot B's row (RAM); slot A's and then slot
                                ;   B's (ws_sync)

lj_qn:      .byte   0           ; tables queued; the head is entry 0
lj_qlo:     .res    LJ_QMAX, 0     ; ...each a pointer to its next row
lj_qhi:     .res    LJ_QMAX, 0
lj_row:     .res    7, 0        ; the row being copied: bank, src, dst, len -
                                ;   len 0 = none, take the next one
lj_act:     .byte   0           ; nonzero: loader steps to run
lj_step:    .byte   0           ; ...and the next one, x2 (gameover.s ld_all)
lj_sync:    .byte   0           ; nonzero: ovl_flush, no clock
lj_bnk:     .byte   0           ; the window's bank when ld_pump started

; ovl_walk - A/X = a table of rows, $FF-ended: queue it.
ovl_walk:
        ldy     lj_qn
        sta     lj_qlo,y
        txa
        sta     lj_qhi,y
        inc     lj_qn
        rts

; -----------------------------------------------------------------------------
; ld_pump - frame_body's first word. C CLEAR: nothing to load, the frame is the
; game's (four loads and a branch). C SET: the frame was the loader's.
; -----------------------------------------------------------------------------
ld_pump:
        lda     lj_qn
        ora     lj_row+5
        ora     lj_row+6
        ora     lj_act
        bne     :+
        clc
        rts
:       lda     CART_BANK_MIR           ; the window as the frame had it - put
        sta     lj_bnk                  ;   back on the way out (@busy)
@lp:    lda     lj_row+5
        ora     lj_row+6
        bne     @copy
        lda     lj_qn
        beq     @steps
        lda     #LDR_BANK | CART_EN     ; the lists are the loader's bank's
        jsr     API_CART_BANK           ;   (slot rows are RAM: any bank reads)
        lda     lj_qlo                  ; the head list's next row
        sta     @rd+1
        lda     lj_qhi
        sta     @rd+2
        ldy     #6
@rd:    lda     $FFFF,y
        sta     lj_row,y
        dey
        bpl     @rd
        lda     lj_row
        inc     a
        beq     @pop                    ; $FF: that table is done
        clc
        lda     lj_qlo                  ; past this row
        adc     #7
        sta     lj_qlo
        bcc     @lp
        inc     lj_qhi
        bra     @lp
@pop:   stz     lj_row+5                ; (the bytes after a $FF are not a len)
        stz     lj_row+6
        lda     lj_qlo+1                ; the second list moves up
        sta     lj_qlo
        lda     lj_qhi+1
        sta     lj_qhi
        dec     lj_qn
        bra     @lp

@copy:  jsr     ld_time
        bcs     @busy
        jsr     ld_piece
        bra     @lp

@steps: lda     lj_act
        beq     @busy                   ; (the copies were this frame's work)
        jsr     ld_time
        bcs     @busy
        lda     lj_step                 ; the loader runs what it can start
        pha
        jsr     win_off                 ;   (the object pool is under the
        ldx     #LD_STEPS               ;   window), in its own bank
        jsr     ld_enter
        jsr     win_on
        pla
        cmp     lj_step
        beq     @busy
        jmp     @lp                     ; it ran some: any copies it queued next
@busy:  lda     lj_bnk
        jsr     API_CART_BANK
        sec
        rts

; ld_piece - one cart_load of the current row: a PAGE (256 bytes), or the
; row's last part-page. A page moves only the high bytes - src (crossing into
; the next bank at $A000), dst, len - and a last part-page ends the row, which
; then needs no moving at all. Everything is moved BEFORE the call and nothing
; reads OS_ARG after it: cart_load does not leave its argument block as it
; found it.
ld_piece:
        ldx     #4                      ; bank, src, dst
:       lda     lj_row,x
        sta     OS_ARG,x
        dex
        bpl     :-
        lda     lj_row+6
        beq     @last
        stz     OS_ARG+5                ; a page
        lda     #$01
        sta     OS_ARG+6
        dec     lj_row+6
        inc     lj_row+4
        inc     lj_row+2
        lda     lj_row+2
        cmp     #$A0
        bne     @go
        lda     #$80
        sta     lj_row+2
        inc     lj_row
        bra     @go
@last:  lda     lj_row+5                ; the row's tail, and the row is done
        sta     OS_ARG+5
        stz     OS_ARG+6
        stz     lj_row+5
@go:    jmp     API_CART_LOAD           ; tail

; ld_time - C SET: too late in this frame to start a piece. ovl_flush: never.
ld_time:
        lda     lj_sync
        bne     @go
        lda     FRAME_POS               ; the hardware FIRST, then the flag
        ldx     VSYNC_FLAG              ;   (MAD65_CPU_OS.md)
        bne     @late
        cmp     #LD_POS_MAX
        rts
@late:  sec
        rts
@go:    clc
        rts

        .pushseg
        .segment "LDCODE"               ; THE LOADER'S BANK (loader.s): run in
                                        ;   the window through ld_enter (LD_OVLF,
                                        ;   LD_OVLS, LD_OVLT), and nothing here
                                        ;   copies - it only QUEUES (ovl_walk)
; -----------------------------------------------------------------------------
; ovl_load_field / ovl_load_screen / ovl_load_tunnel - queue the tenant's rows
; unless it is already resident, and say it is (overlay_cur): the copies land
; over the next frames (ld_pump), and frame_body runs no frame of the new
; tenant until they have. ovl_load_field is also frame_body's safety net, then
; flushed on the spot. Out of the TUNNEL the flight engine comes back first -
; the tunnel's second row is over the run area - so those lists start with the
; engine's four rows (bootstrap.s's boot_segs) and run on into the tenant's.
; -----------------------------------------------------------------------------
ovl_load_field:
        lda     overlay_cur
        cmp     #OVL_FIELD
        beq     @ret
        cmp     #OVL_TUNNEL
        beq     @eng
        lda     #<ovl_field_rows
        ldx     #>ovl_field_rows
        bra     @go
@eng:   lda     #<ovl_engf_rows
        ldx     #>ovl_engf_rows
@go:    jsr     ovl_walk
        lda     #OVL_FIELD
        sta     overlay_cur
        lda     #<ovl_slotb_row         ; ...and slot B, its last row (RAM)
        ldx     #>ovl_slotb_row
        jmp     ovl_walk
@ret:   rts

ovl_load_screen:
        lda     overlay_cur
        cmp     #OVL_SCREEN
        beq     @ret
        cmp     #OVL_TUNNEL             ; the demo ends in SECTOR COMPLETED straight
        beq     @eng                    ;   out of the tunnel
        lda     #<ovl_screen_rows
        ldx     #>ovl_screen_rows
        bra     @go
@eng:   lda     #<ovl_engs_rows
        ldx     #>ovl_engs_rows
@go:    jsr     ovl_walk
        lda     #OVL_SCREEN
        sta     overlay_cur
@ret:   rts

; ovl_field_now - frame_body's safety net (LD_OVLFN): FIELD, copied on the spot.
ovl_field_now:
        jsr     ovl_load_field
        ; fall through
; ovl_flush - run the queue to its end now, whatever the frame says: cart_init's
; (ld_power_on) and the safety net's. From this bank: ld_pump is resident, does
; the copying, and hands the window back as it found it - this bank.
ovl_flush:
        inc     lj_sync
:       jsr     ld_pump
        bcs     :-
        stz     lj_sync
        rts

; ovl_load_tunnel - the frame AFTER the field set SC_TUNNEL (frame_body), so the
; field's last frame has already returned out of CODE6.
ovl_load_tunnel:
        lda     overlay_cur
        cmp     #OVL_TUNNEL
        beq     @ret
        lda     #OVL_TUNNEL
        sta     overlay_cur
        lda     #<ovl_tunnel_rows
        ldx     #>ovl_tunnel_rows
        jmp     ovl_walk
@ret:   rts

; The row lists. ROM, so a list may be spelt out twice rather than chained.
.macro  ENGINE_ROWS
        .byte   ENG0_BANK
        .word   __CODE_LOAD__, __CODE_RUN__, __CODE_SIZE__
        .byte   ENG1_BANK
        .word   __CODE2_LOAD__, __CODE2_RUN__, __CODE2_SIZE__
        .byte   ENG3_BANK
        .word   __CODE3_LOAD__, __CODE3_RUN__, __CODE3_SIZE__
        .byte   ENG4_BANK
        .word   __CODE4_LOAD__, __CODE4_RUN__, __CODE4_SIZE__
.endmacro
ovl_engf_rows:
        ENGINE_ROWS                     ; out of the tunnel: the engine, then...
ovl_field_rows:
        .byte   CODE5_BANK
        .word   __CODE5_LOAD__, __CODE5_RUN__, __CODE5_SIZE__
        .byte   CODE6_BANK
        .word   __CODE6_LOAD__, __CODE6_RUN__, __CODE6_SIZE__
        .byte   CODE9_BANK
        .word   __CODE9_LOAD__, __CODE9_RUN__, __CODE9_SIZE__
        .byte   $FF
ovl_engs_rows:
        ENGINE_ROWS
ovl_screen_rows:
        .byte   UICODE_BANK
        .word   __UICODE_LOAD__, __UICODE_RUN__, __UICODE_SIZE__
        .byte   $FF
ovl_tunnel_rows:
        .byte   TUNCODE_BANK
        .word   __TUNCODE_LOAD__, __TUNCODE_RUN__, __TUNCODE_SIZE__
        .byte   TUNCODE_BANK            ; ...and the rocks, over the run area
        .word   __TUNCODE2_LOAD__, __TUNCODE2_RUN__, __TUNCODE2_SIZE__
        .byte   TUNCODE3_BANK           ; ...and the lifepods, behind them
        .word   __TUNCODE3_LOAD__, __TUNCODE3_RUN__, __TUNCODE3_SIZE__
        .byte   $FF
        .popseg
