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
; So: cart_init copies the CODE+RODATA span out of the window into RAM once,
; then hands over. Everything after that runs at full speed.
;
; This stub itself stays in the window (it runs once, and the frame trampoline
; is three cycles a frame), which is why it is its own segment.
; =============================================================================

.setcpu "65SC02"                 ; (zp) indirect and bra are 65C02-only

        .import __CODE_LOAD__, __CODE_RUN__
        .import __RODATA_LOAD__, __RODATA_SIZE__
        .import cart_init, cart_frame

        .export boot_init
        .export boot_frame

SRC     = $F0                   ; the bootstrap's own scratch, well clear of the
DST     = $F2                   ;   game's $80-$BF - and dead by the time the
CNT     = $F4                   ;   game's first frame runs

COPY_SIZE = __RODATA_LOAD__ + __RODATA_SIZE__ - __CODE_LOAD__

        .segment "BOOT"

boot_init:
        lda     #<__CODE_LOAD__
        sta     SRC
        lda     #>__CODE_LOAD__
        sta     SRC+1
        lda     #<__CODE_RUN__
        sta     DST
        lda     #>__CODE_RUN__
        sta     DST+1
        lda     #<COPY_SIZE
        sta     CNT
        lda     #>COPY_SIZE
        sta     CNT+1
@lp:    lda     CNT                     ; a 16-bit "is it zero yet" up front, so
        ora     CNT+1                   ;   a zero-length copy is not 64 KB
        beq     @done
        lda     (SRC)
        sta     (DST)
        inc     SRC
        bne     :+
        inc     SRC+1
:       inc     DST
        bne     :+
        inc     DST+1
:       lda     CNT
        bne     :+
        dec     CNT+1
:       dec     CNT
        bra     @lp
@done:
        jmp     cart_init               ; its rts returns to the boot ROM

boot_frame:
        jmp     cart_frame
