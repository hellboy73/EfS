; =============================================================================
; Escape from Saturn — Model B bootstrap
; =============================================================================
; Everything except this stub is STORED in the cartridge window and RUN from
; RAM. That is not a style choice: the cartridge is banked and cannot be
; shadowed, so the hardware charges 3 wait states on every read in the
; $8000-$9FFF window — instruction fetches included. Measured in proto 01,
; running in place costs 2.5x, which is the difference between a frame at 30%
; of budget and one at 77%. `make preview` prints both numbers.
;
; So: boot_init copies the image out of the window into RAM once, then hands
; over. Everything after that runs at full speed.
;
; This stub itself stays in the window (it runs once, and the frame trampoline
; is three cycles a frame), which is why it is its own segment.
; =============================================================================
; TWO BANKS, AND WHY THAT COSTS NOTHING
;
; physics.s pushed RODATA past the end of an 8 KB bank, so CODE now lives in
; bank 0 and RODATA in bank 1 (see cart.cfg). That is not a compromise: this
; cartridge reads the window exactly twice in its life, both times below, and
; never again. A second bank is therefore free — it is one more copy in a copy
; that was already happening, and not one cycle of the frame.
;
; The copy is the OS `cart_load` ($FF06) rather than the hand-rolled byte loop
; this file used to hold. cart_load RUNS FROM ROM, so it is the only code that
; may re-bank the window safely: the rule is that you never switch the bank of
; the code you are executing, and this stub IS executing from the window. It
; also saves and restores CART_SHADOW, so the rts lands back in bank 0 and the
; second call can be written exactly like the first.
;
; Two calls and not one, even though cart_load crosses bank boundaries by
; itself: bank 0 is padded to $9FFF with $FF, and a single copy would faithfully
; carry that padding into RAM between CODE and RODATA. The segments RUN
; contiguously; only their LOAD addresses are apart.
; =============================================================================
; ONE ROW PER SEGMENT, AND ONE LOOP FOR ALL OF THEM
;
; It was two calls, then five, each written out as seven loads and stores and a
; jsr - 31 bytes of bank 0 a segment. Bank 0 holds this stub AND CODE, and when
; the laser (laser.s) needed a sixth segment it had 15 bytes left. So the copies
; are a TABLE now: seven bytes a segment, laid out exactly as cart_load's OS_ARG
; block wants them - bank, LOAD, RUN, SIZE - and one loop that moves a row
; across and makes the call. Six segments cost 70 bytes where five cost 158, and
; the next one costs seven.
;
; Every address in the table is the LINKER'S. Nothing here is added up: when
; RODATA moved out of the $2000 run to $A000, not one line of this file changed,
; and that is the whole argument for __X_RUN__ over arithmetic. Only the bank
; numbers are typed, and they have to match cart.cfg's MEMORY order.
; =============================================================================

.setcpu "65SC02"                 ; (zp) indirect and bra are 65C02-only

        .import __CODE_LOAD__, __CODE_RUN__, __CODE_SIZE__
        .import __CODE2_LOAD__, __CODE2_RUN__, __CODE2_SIZE__
        .import __RODATA_LOAD__, __RODATA_RUN__, __RODATA_SIZE__
        .import __HIDATA_LOAD__, __HIDATA_RUN__, __HIDATA_SIZE__
        .import __CODE3_LOAD__, __CODE3_RUN__, __CODE3_SIZE__
        .import __CODE4_LOAD__, __CODE4_RUN__, __CODE4_SIZE__
        .import cart_init, cart_frame

        .export boot_init
        .export boot_frame

; The OS interface this stub needs. Not from mad65.inc: that file is the
; CARTRIDGE's view of the OS and this is a separate assembly unit that runs
; before the cartridge exists in RAM.
OS_ARG        = $20             ; $20-$2F, the API argument block
API_CART_LOAD = $FF06           ; OS_ARG: bank8, src16, dst16, len16

CODE_BANK     = 0               ; must match cart.cfg's MEMORY order
CODE2_BANK    = 1
RODATA_BANK   = 2
HIDATA_BANK   = 3               ; HIDATA runs at $A000 (MAD-65's separate
                                 ;   upper RAM), not chained after RODATA - see
                                 ;   cart.cfg's note on why bank 3 exists
CODE3_BANK    = 3               ; ...and CODE3 is the rest of that bank, which
                                 ;   runs in the $1000 area after CODE2
CODE4_BANK    = 4               ; ...and CODE4 rides behind COLD in bank 4, and
                                 ;   runs after CODE3

        .segment "BOOT"

boot_init:
        ldx     #$00                    ; X walks the table, Y the row
@row:   ldy     #$00
@arg:   lda     boot_segs,x
        sta     OS_ARG,y
        inx
        iny
        cpy     #7
        bne     @arg
        phx                             ; cart_load's registers are its own
        jsr     API_CART_LOAD
        plx
        cpx     #boot_segs_end - boot_segs
        bne     @row
        jmp     cart_init               ; its rts returns to the boot ROM

; The rows, in the order they are copied. Read from THIS bank, which is safe
; between calls because cart_load hands bank 0 back every time (above).
;
;   CODE    bank 0 -> the run area at $1000
;   CODE2   bank 1 -> the run area, after CODE
;   RODATA  bank 2 -> upper RAM at $A000 - see cart.cfg's RODATA MOVE
;   HIDATA  bank 3 -> upper RAM, straight after RODATA. Both land outside the
;                     run area and the linker packs them into UPPER in SEGMENTS
;                     order, so this one's address is RODATA's end - and it
;                     gets it the only safe way, its own RUN symbol
;   CODE3   bank 3 -> the run area, after CODE2: the same bank as HIDATA, a
;                     different destination - stored behind HIDATA in the
;                     window, run behind CODE2 in RAM
;   CODE4   bank 4 -> the run area, after CODE3: stored behind COLD, which is
;                     read in the window and never copied
boot_segs:
        .byte   CODE_BANK
        .word   __CODE_LOAD__, __CODE_RUN__, __CODE_SIZE__
        .byte   CODE2_BANK
        .word   __CODE2_LOAD__, __CODE2_RUN__, __CODE2_SIZE__
        .byte   RODATA_BANK
        .word   __RODATA_LOAD__, __RODATA_RUN__, __RODATA_SIZE__
        .byte   HIDATA_BANK
        .word   __HIDATA_LOAD__, __HIDATA_RUN__, __HIDATA_SIZE__
        .byte   CODE3_BANK
        .word   __CODE3_LOAD__, __CODE3_RUN__, __CODE3_SIZE__
        .byte   CODE4_BANK
        .word   __CODE4_LOAD__, __CODE4_RUN__, __CODE4_SIZE__
boot_segs_end:

; -----------------------------------------------------------------------------
; boot_frame - the OS's per-frame entry, and A TRAMPOLINE THAT LIVES IN THE
; CARTRIDGE WINDOW.
; -----------------------------------------------------------------------------
; The header at $8007 hands the OS this address, the OS parks it in FRAME_VEC,
; and every frame it is jumped to - through the $8000-$9FFF window, out of BANK
; 0, because the BOOT segment is stored and run in place (it has to be: it is
; what copies CODE into RAM in the first place).
;
; SO THE WINDOW MUST BE SHOWING BANK 0 AT THE END OF EVERY FRAME. Anything that
; pages another bank in to read it - shots.s's do_explosions does, for EXPL_OFF
; in the COLD segment, and level scripts and message text will - must BORROW the
; window and hand it back before cart_frame returns. Leave a different bank
; selected and the next frame jumps into that bank's data and the machine is
; gone. Save CART_SHADOW, select, restore: see do_explosions for the pattern.
;
; (Pointing the header straight at cart_frame in RAM would remove the hazard,
; and is a reasonable thing to do later. It is not free to do casually - the
; boot ROM reads the vector before cart_init has run - so the constraint is
; written down here rather than quietly designed around.)
; -----------------------------------------------------------------------------
boot_frame:
        jmp     cart_frame
