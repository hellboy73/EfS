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

.setcpu "65SC02"                 ; (zp) indirect and bra are 65C02-only

        .import __CODE_LOAD__, __CODE_RUN__, __CODE_SIZE__
        .import __CODE2_LOAD__, __CODE2_RUN__, __CODE2_SIZE__
        .import __RODATA_LOAD__, __RODATA_RUN__, __RODATA_SIZE__
        .import __HIDATA_LOAD__, __HIDATA_RUN__, __HIDATA_SIZE__
        .import cart_init, cart_frame

        .export boot_init
        .export boot_frame

; The OS interface this stub needs. Not from mad65.inc: that file is the
; CARTRIDGE's view of the OS and this is a separate assembly unit that runs
; before the cartridge exists in RAM.
OS_ARG        = $20             ; $20-$2F, the API argument block
API_CART_LOAD = $FF06           ; OS_ARG: bank8, src16, dst16, len16

CODE2_BANK    = 1               ; must match cart.cfg's MEMORY order
RODATA_BANK   = 2
HIDATA_BANK   = 3               ; HIDATA runs at $A000 (MAD-65's separate
                                 ;   upper RAM), not chained after RODATA - see
                                 ;   cart.cfg's note on why bank 3 exists

        .segment "BOOT"

boot_init:
        lda     #$00                    ; --- CODE: bank 0 window -> RAM $2000
        sta     OS_ARG+0
        lda     #<__CODE_LOAD__
        sta     OS_ARG+1
        lda     #>__CODE_LOAD__
        sta     OS_ARG+2
        lda     #<__CODE_RUN__
        sta     OS_ARG+3
        lda     #>__CODE_RUN__
        sta     OS_ARG+4
        lda     #<__CODE_SIZE__
        sta     OS_ARG+5
        lda     #>__CODE_SIZE__
        sta     OS_ARG+6
        jsr     API_CART_LOAD

        ; --- bank 1: CODE2 ------------------------------------------------
        ; This used to be one copy covering CODE2 AND RODATA, because the two
        ; were contiguous in the window as well as in RAM. The split pushed them
        ; past 8 KB together and RODATA moved to a bank of its own (cart.cfg),
        ; and then out of the $2000 run altogether - it lands at $A000 now, with
        ; HIDATA. NOT ONE LINE OF THIS FILE CHANGED FOR THAT, which is the whole
        ; argument for taking the run addresses from the linker: every copy below
        ; says __X_RUN__ and none of them has an address this file could get
        ; wrong when the map moves under it.
        lda     #CODE2_BANK
        sta     OS_ARG+0
        lda     #<__CODE2_LOAD__
        sta     OS_ARG+1
        lda     #>__CODE2_LOAD__
        sta     OS_ARG+2
        lda     #<__CODE2_RUN__
        sta     OS_ARG+3
        lda     #>__CODE2_RUN__
        sta     OS_ARG+4
        lda     #<__CODE2_SIZE__
        sta     OS_ARG+5
        lda     #>__CODE2_SIZE__
        sta     OS_ARG+6
        jsr     API_CART_LOAD

        ; --- bank 2: RODATA, -> $A000 as well - see cart.cfg's RODATA MOVE --
        lda     #RODATA_BANK
        sta     OS_ARG+0
        lda     #<__RODATA_LOAD__
        sta     OS_ARG+1
        lda     #>__RODATA_LOAD__
        sta     OS_ARG+2
        lda     #<__RODATA_RUN__
        sta     OS_ARG+3
        lda     #>__RODATA_RUN__
        sta     OS_ARG+4
        lda     #<__RODATA_SIZE__
        sta     OS_ARG+5
        lda     #>__RODATA_SIZE__
        sta     OS_ARG+6
        jsr     API_CART_LOAD

        ; --- bank 3: HIDATA, -> upper RAM, straight after RODATA -----------
        ; Both of the last two land outside the $2000-$5FFF run, and the linker
        ; packs them into UPPER in SEGMENTS order - so this one's address is
        ; RODATA's end, and it gets it the only safe way: its own RUN symbol,
        ; never __RODATA_RUN__ + __RODATA_SIZE__ arithmetic done here.
        lda     #HIDATA_BANK
        sta     OS_ARG+0
        lda     #<__HIDATA_LOAD__
        sta     OS_ARG+1
        lda     #>__HIDATA_LOAD__
        sta     OS_ARG+2
        lda     #<__HIDATA_RUN__
        sta     OS_ARG+3
        lda     #>__HIDATA_RUN__
        sta     OS_ARG+4
        lda     #<__HIDATA_SIZE__
        sta     OS_ARG+5
        lda     #>__HIDATA_SIZE__
        sta     OS_ARG+6
        jsr     API_CART_LOAD

        jmp     cart_init               ; its rts returns to the boot ROM

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
