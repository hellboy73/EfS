; =============================================================================
; slots.s - the WALL SLOTS: the base's code, the force field's or the ghosts'
; =============================================================================
; design_technical.md 11.52. A sector has the human base (with its freighters)
; OR the force field (11.51) OR the ghosts (ghosts.s), never two (the user,
; 2026-11-23; the ghosts 2026-11-26), so their code does not have to be
; resident side by side. The three are the game's three ZONES: the near
; neighbourhood (the base), the farther reaches (things in camouflage) and the
; sectors the aliens hold for good (the field). They share two SLOTS, and the
; sector loader decides which TENANT fills them:
;
;   slot A  $B960-$BEFF, the tail of upper RAM (cart.cfg SLOTA_*): the walls'
;           own code - base.s's bs_* (BSWALL), the field's (FFWALL) or the
;           ghosts' rock drawing (GHWALL). Upper
;           RAM is never overlaid, so it is copied only when the tenant changes.
;   slot B  $DA60-$DEFF, the tail of DEMO_RAM (cart.cfg SLOTB_*): the frame's
;           code - do_base, the freighters (BSFRAME), the field's drawing
;           (FFFRAME) or the ghosts' (GHFRAME) - and FIRST in it, the VECTOR TABLE. DEMO_RAM is the
;           overlay's (overlay.s): the screens and the tunnel write over it, so
;           its row (overlay.s ovl_slotb_row) is the CURRENT tenant's, patched here, and
;           ovl_load_field brings back whichever tenant the sector has.
;
; EVERY CALLER GOES THROUGH THE VECTORS (WS_*), never a tenant's routine by
; name: the movers (objects.s, foes.s, ship.s, shots.s) and frame_body cannot
; know which tenant is in. Each tenant's table is the same nine entries at the
; same address (asserted), with the base's contracts:
;
;   WS_FRAME  once a frame, inside the bracket, before do_stars: its discs
;             must be in the list before the stars are walked
;   WS_ROCK   do_objects, a rock that has moved; X = its slot, kept
;   WS_FOE    foe_integrate's last word; X = the enemy's slot, kept
;   WS_BRAKE  do_ship, before the ship moves
;   WS_SHOTP  a player's bullet, X = its slot: carry SET = it ended on a wall
;   WS_SHOTF  an enemy's bullet, the same
;   WS_EMP    do_emp, EMK this frame's reach (the field's tower; the base: rts)
;   WS_GROCK  one_asteroid, a GHOST rock (OBJTYPE bit 7) with its command block
;             built in PBUF: draw it, or not (ghosts.s). Only the ghost tenant's
;             sectors have ghost rocks, so the other two never see the call
;   WS_GHIT   rock_take_hit, a GHOST rock about to take RKDMG; X = it, kept
;             (ghosts.s: its Saturnium). The same: only the ghost tenant's
;
; WHO CHOOSES: the sector's ZONE (levels.s, the user 2026-11-26) - 1 inner:
; the base, 2 outer: the ghosts, 3 void: the field. The loader's ws_zone, the
; step of level_begin after ff_load, writes WSKIND (WK_*) out of it -
; and ld_enter (loader.s) calls ws_sync once the
; loader is out of the window, which copies the tenant in if it is not the one
; resident (WSCUR). The base is the tenant at power-on: bootstrap.s copies it.
; =============================================================================

        .import __BSWALL_LOAD__,  __BSWALL_RUN__,  __BSWALL_SIZE__
        .import __BSFRAME_LOAD__, __BSFRAME_RUN__, __BSFRAME_SIZE__
        .import __FFWALL_LOAD__,  __FFWALL_RUN__,  __FFWALL_SIZE__
        .import __FFFRAME_LOAD__, __FFFRAME_RUN__, __FFFRAME_SIZE__
        .import __GHWALL_LOAD__,  __GHWALL_RUN__,  __GHWALL_SIZE__
        .import __GHFRAME_LOAD__, __GHFRAME_RUN__, __GHFRAME_SIZE__

WK_BASE     = 0                 ; WSKIND: the human base and its freighters
WK_FIELD    = 1                 ; ...the force field (ffield.s)
WK_GHOST    = 2                 ; ...the ghosts (ghosts.s)

ZN_INNER    = 1                 ; levels.s ZONE: the near neighbourhood - the base
ZN_OUTER    = 2                 ;   and freighters; the farther reaches - things in
ZN_VOID     = 3                 ;   camouflage; the aliens' own sectors - the field

BSWALL_BANK  = 7                ; must match cart.cfg's MEMORY order (ROMn = bank n)
BSFRAME_BANK = 2
FFWALL_BANK  = 2
FFFRAME_BANK = 2
GHWALL_BANK  = 7
GHFRAME_BANK = 7

; STROBE_LIT - A = a strobe's timer, nonzero (frames left, out of FF_FLASH) ->
; Z SET: lit this frame. Every other frame while fresh, one in four as it dies
; away, in step with FRAME. The field's flash (ffield.s). It was to be shared
; with the ghosts, hence a macro; since 2026-11-26 the ghosts strobe
; irregularly instead (ghosts.s gh_irr, the user) and only the field uses it.
; Branchless, so it has no label of its own: a label there would end the
; caller's @-local scope.
.macro  STROBE_LIT
        cmp     #FF_FLASH / 2           ; carry: fresh
        lda     #$00
        rol     a                       ; 1 fresh, 0 dying...
        asl     a
        eor     #$03                    ; ...-> the mask, 1 or 3
        and     FRAME
.endmacro

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
        rts                             ; WS_EMP: nothing of the base's
        .res    2
        rts                             ; WS_GROCK: no ghost rocks here
        .res    2
        rts                             ; WS_GHIT: ...nor here
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
        jmp     ff_emp
        rts                             ; WS_GROCK: no ghost rocks here
        .res    2
        rts                             ; WS_GHIT

        .segment "GHFRAME"
ws_tab_gh:
        jmp     gh_frame                ; WS_FRAME
        rts                             ; WS_ROCK: nothing to bump into
        .res    2
        rts                             ; WS_FOE
        .res    2
        rts                             ; WS_BRAKE
        .res    2
        clc                             ; WS_SHOTP: carry CLEAR, no wall
        rts
        .res    1
        clc                             ; WS_SHOTF
        rts
        .res    1
        rts                             ; WS_EMP
        .res    2
        jmp     gh_rock                 ; WS_GROCK
        jmp     gh_hit                  ; WS_GHIT

        .assert ws_tab_ff = ws_tab_bs, lderror, "slots.s: the two tenants' vector tables are not at one address"
        .assert ws_tab_gh = ws_tab_bs, lderror, "slots.s: the ghosts' vector table is not at the others' address"
        .assert ws_tab_gh = __GHFRAME_RUN__, lderror, "slots.s: the ghosts' vector table is not first in slot B"
        .assert ws_tab_bs = __BSFRAME_RUN__, lderror, "slots.s: the base's vector table is not first in slot B"
        .assert ws_tab_ff = __FFFRAME_RUN__, lderror, "slots.s: the field's vector table is not first in slot B"
        .popseg

WS_FRAME    = ws_tab_bs + 0
WS_ROCK     = ws_tab_bs + 3
WS_FOE      = ws_tab_bs + 6
WS_BRAKE    = ws_tab_bs + 9
WS_SHOTP    = ws_tab_bs + 12
WS_SHOTF    = ws_tab_bs + 15
WS_EMP      = ws_tab_bs + 18
WS_GROCK    = ws_tab_bs + 21
WS_GHIT     = ws_tab_bs + 24

; --- the swap ----------------------------------------------------------------
        .pushseg
        .segment "CODE8"                ; the run area, beside overlay.s: never
                                        ;   in a slot, never overlaid

WSKIND:     .byte   WK_BASE             ; the tenant this sector wants (the loader)
WSCUR:      .byte   WK_BASE             ; ...and the one in the slots (bootstrap.s)

        .segment "LDCODE"               ; the LOADER (loader.s): only ld_enter
                                        ;   calls it, with the window on bank 8

; ws_zone - level_begin, after ff_load: the sector's ZONE -> the tenant it wants.
ws_zone:
        ldx     CURLEV
        ldy     LVL_ZONE,x
        lda     ZONE_WK - ZN_INNER,y
        sta     WSKIND
        rts
ZONE_WK:    .byte   WK_BASE, WK_GHOST, WK_FIELD     ; inner, outer, void
        .assert ZN_OUTER = ZN_INNER + 1 && ZN_VOID = ZN_INNER + 2, error, "slots.s: ZONE_WK is in zone order"
; -----------------------------------------------------------------------------
; ws_sync - ld_enter, after the loader: bring WSKIND's tenant into the slots if
; it is not there. Both rows are copied into RAM (overlay.s) - ld_pump reads
; rows from there, later, when this bank is long out of the window - and slot A
; is queued; slot B's row is FIELD's last, so it is queued only while DEMO_RAM
; holds FIELD - under any other tenant ovl_load_field will bring it, from the
; patched row. QUEUED, not copied: ld_pump does it on the next frames, before
; the field runs again. Clobbers A, X, Y.
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
        tax
        ldy     #$00
@cp:    lda     ws_rows,x               ; its slot-A row, and its slot-B row
        sta     ovl_slota_row,y         ;   into the FIELD list
        lda     ws_rows+8,x
        sta     ovl_slotb_row,y
        inx
        iny
        cpy     #7
        bne     @cp
        lda     #<ovl_slota_row         ; slot A, always
        ldx     #>ovl_slota_row
        jsr     ovl_walk
        lda     overlay_cur
        cmp     #OVL_FIELD
        bne     @ret
        lda     #<ovl_slotb_row         ; slot B: the FIELD list's last row and
        ldx     #>ovl_slotb_row         ;   its terminator
        jmp     ovl_walk
@ret:   rts

; Each tenant: its slot-A row, $FF, its slot-B row, $FF (bank, load, run,
; size) - ws_sync copies the two rows into overlay.s's RAM rows. ROM, bank 8.
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
        .byte   GHWALL_BANK
        .word   __GHWALL_LOAD__, __GHWALL_RUN__, __GHWALL_SIZE__
        .byte   $FF
        .byte   GHFRAME_BANK
        .word   __GHFRAME_LOAD__, __GHFRAME_RUN__, __GHFRAME_SIZE__
        .byte   $FF
        .assert * - ws_rows = 48, error, "slots.s: ws_sync indexes 16 bytes a tenant"

        .popseg
