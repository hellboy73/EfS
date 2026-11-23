; =============================================================================
; slots.s - the WALL SLOTS: the base's code or the force field's, never both
; =============================================================================
; design_technical.md 11.52. A sector has the human base (with its freighters)
; OR the force field (11.51), never both (the user, 2026-11-23), so their code
; does not have to be resident side by side. It shares two SLOTS, and the
; sector loader decides which TENANT fills them:
;
;   slot A  $B960-$BEFF, the tail of upper RAM (cart.cfg SLOTA_*): the walls'
;           own code - base.s's bs_* (BSWALL) or the field's (FFWALL). Upper
;           RAM is never overlaid, so it is copied only when the tenant changes.
;   slot B  $DA60-$DEFF, the tail of DEMO_RAM (cart.cfg SLOTB_*): the frame's
;           code - do_base, the freighters (BSFRAME) or the field's drawing
;           (FFFRAME) - and FIRST in it, the VECTOR TABLE. DEMO_RAM is the
;           overlay's (overlay.s): the screens and the tunnel write over it, so
;           its row in ovl_field_segs is the CURRENT tenant's, patched here, and
;           ovl_load_field brings back whichever tenant the sector has.
;
; EVERY CALLER GOES THROUGH THE VECTORS (WS_*), never a tenant's routine by
; name: the movers (objects.s, foes.s, ship.s, shots.s) and frame_body cannot
; know which tenant is in. Each tenant's table is the same six JMPs at the same
; address (asserted), with the base's contracts:
;
;   WS_FRAME  once a frame, inside the bracket, before do_stars: its discs
;             must be in the list before the stars are walked
;   WS_ROCK   do_objects, a rock that has moved; X = its slot, kept
;   WS_FOE    foe_integrate's last word; X = the enemy's slot, kept
;   WS_BRAKE  do_ship, before the ship moves
;   WS_SHOTP  a player's bullet, X = its slot: carry SET = it ended on a wall
;   WS_SHOTF  an enemy's bullet, the same
;
; WHO CHOOSES: the sector loader writes WSKIND (WK_*) - base.s's base_load the
; base, then ffield.s's ff_load the field if the level has one (LVL_FF_ON) -
; and ld_enter (loader.s) calls ws_sync once the
; loader is out of the window, which copies the tenant in if it is not the one
; resident (WSCUR). The base is the tenant at power-on: bootstrap.s copies it.
; =============================================================================

        .import __BSWALL_LOAD__,  __BSWALL_RUN__,  __BSWALL_SIZE__
        .import __BSFRAME_LOAD__, __BSFRAME_RUN__, __BSFRAME_SIZE__
        .import __FFWALL_LOAD__,  __FFWALL_RUN__,  __FFWALL_SIZE__
        .import __FFFRAME_LOAD__, __FFFRAME_RUN__, __FFFRAME_SIZE__

WK_BASE     = 0                 ; WSKIND: the human base and its freighters
WK_FIELD    = 1                 ; ...the force field (ffield.s)

BSWALL_BANK  = 7                ; must match cart.cfg's MEMORY order (ROMn = bank n)
BSFRAME_BANK = 2
FFWALL_BANK  = 2
FFFRAME_BANK = 2

; --- the vector tables: FIRST in each tenant's slot B -------------------------
        .pushseg
        .segment "BSFRAME"
ws_tab_bs:
        jmp     ws_frame_bs
        jmp     base_rock
        jmp     base_foe
        jmp     base_brake
        jmp     base_shot_p
        jmp     base_shot_f
ws_frame_bs:                            ; the freighters, then the base - the
        jsr     do_freight              ;   order frame_body always had
        jmp     do_base

        .segment "FFFRAME"
ws_tab_ff:
        jmp     ff_frame
        jmp     ff_rock
        jmp     ff_foe
        jmp     ff_brake
        jmp     ff_shot_p
        jmp     ff_shot_f

        .assert ws_tab_ff = ws_tab_bs, lderror, "slots.s: the two tenants' vector tables are not at one address"
        .assert ws_tab_bs = __BSFRAME_RUN__, lderror, "slots.s: the base's vector table is not first in slot B"
        .assert ws_tab_ff = __FFFRAME_RUN__, lderror, "slots.s: the field's vector table is not first in slot B"
        .popseg

WS_FRAME    = ws_tab_bs + 0
WS_ROCK     = ws_tab_bs + 3
WS_FOE      = ws_tab_bs + 6
WS_BRAKE    = ws_tab_bs + 9
WS_SHOTP    = ws_tab_bs + 12
WS_SHOTF    = ws_tab_bs + 15

; --- the swap ----------------------------------------------------------------
        .pushseg
        .segment "CODE8"                ; the run area, beside overlay.s: never
                                        ;   in a slot, never overlaid

WSKIND:     .byte   WK_BASE             ; the tenant this sector wants (the loader)
WSCUR:      .byte   WK_BASE             ; ...and the one in the slots (bootstrap.s)

; -----------------------------------------------------------------------------
; ws_sync - ld_enter, after the loader: bring WSKIND's tenant into the slots if
; it is not there. Slot A always; slot B's row in ovl_field_segs is patched,
; and slot B itself copied only while DEMO_RAM holds FIELD - under any other
; tenant ovl_load_field will bring it, from the patched row. Clobbers A, X, Y
; and the window's bank (API_CART_LOAD hands bank 0 back; ld_enter restores).
; -----------------------------------------------------------------------------
ws_sync:
        lda     WSKIND
        cmp     WSCUR
        beq     @ret
        sta     WSCUR
        asl     a                       ; 16 bytes of rows a tenant
        asl     a
        asl     a
        asl     a
        pha
        tax
        ldy     #$00
@cp:    lda     ws_rows+8,x             ; its slot-B row into the FIELD list
        sta     ovl_slotb_row,y
        inx
        iny
        cpy     #7
        bne     @cp
        pla
        clc
        adc     #<ws_rows
        pha
        lda     #>ws_rows
        adc     #$00
        tax
        pla
        jsr     ovl_walk                ; slot A: its row and a terminator
        lda     overlay_cur
        cmp     #OVL_FIELD
        bne     @ret
        lda     #<ovl_slotb_row         ; slot B: the FIELD list's last row and
        ldx     #>ovl_slotb_row         ;   its terminator
        jmp     ovl_walk
@ret:   rts

; Each tenant: its slot-A row, $FF, its slot-B row, $FF - ovl_walk's rows
; (bank, load, run, size), each list ended by a $FF bank.
ws_rows:
        .byte   BSWALL_BANK
        .word   __BSWALL_LOAD__, __BSWALL_RUN__, __BSWALL_SIZE__
        .byte   $FF
        .byte   BSFRAME_BANK
        .word   __BSFRAME_LOAD__, __BSFRAME_RUN__, __BSFRAME_SIZE__
        .byte   $FF
        .byte   FFWALL_BANK
        .word   __FFWALL_LOAD__, __FFWALL_RUN__, __FFWALL_SIZE__
        .byte   $FF
        .byte   FFFRAME_BANK
        .word   __FFFRAME_LOAD__, __FFFRAME_RUN__, __FFFRAME_SIZE__
        .byte   $FF
        .assert * - ws_rows = 32, error, "slots.s: ws_sync indexes 16 bytes a tenant"

        .popseg
