; =============================================================================
; EfS proto 02 — Model B bootstrap
; =============================================================================
; Everything except this stub is STORED in the cartridge window and RUN from
; RAM. That is not a style choice: the cartridge is banked and cannot be
; shadowed, so the hardware charges 3 wait states on every read in the
; $8000-$9FFF window — instruction fetches included. Measured on this bench,
; running in place costs 2.5x, which is the difference between a frame at 30%
; of budget and one at 77%. `preview.py` prints both numbers.
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
        .import __RODATA_LOAD__, __RODATA_RUN__, __RODATA_SIZE__
        .import cart_init, cart_frame

        .export boot_init
        .export boot_frame

; The OS interface this stub needs. Not from mad65.inc: that file is the
; CARTRIDGE's view of the OS and this is a separate assembly unit that runs
; before the cartridge exists in RAM.
OS_ARG        = $20             ; $20-$2F, the API argument block
API_CART_LOAD = $FF06           ; OS_ARG: bank8, src16, dst16, len16

RODATA_BANK   = 1               ; must match cart.cfg's MEMORY order

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

        lda     #RODATA_BANK            ; --- RODATA: bank 1 -> RAM, right after
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

        jmp     cart_init               ; its rts returns to the boot ROM

boot_frame:
        jmp     cart_frame
