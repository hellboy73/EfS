; =============================================================================
; window.s - borrowing $8000-$9FFF as RAM for the length of a pass
; =============================================================================
; MAD-65's upper RAM chip (a CY7C199) has /CE = A15, so it covers $8000-$FFFF
; whole; the cartridge only OVERLAYS it on READS. Two things follow, and both
; are measured, not assumed - src/probe.s establishes them in py65 AND in
; madsim, and tools/preview.py keeps checking them on every run:
;
;   * a write into $8000-$9FFF reaches that RAM whatever CART_EN says, and does
;     not disturb the ROM the window shows,
;   * clearing CART_EN makes the RAM read back, at FULL SPEED - the three wait
;     states belong to the cartridge, not to this chip - and setting it again
;     hands the ROM view back untouched.
;
; So the window is 8 KB of RAM that costs one cart_bank call to LOOK at. That
; is the whole point of this file: the toggle is per REGION OF CODE, not per
; access, so a pass brackets itself once and then reads its arrays at the same
; speed as any other RAM in the machine. Measured at ~60 cycles for an off/on
; pair - 0.025% of the 237,404-cycle frame.
;
; WHAT MAY NOT LIVE THERE. Two rules, and neither is negotiable:
;
;   1. Nothing read from the IRQ. audio_tick dereferences the SFX step program
;      live in the interrupt (which is why sfx.s is a HIDATA file end to end),
;      and at the normal CART_EN=1 it would read cartridge ROM instead.
;   2. Nothing read by code EXECUTING from the window. That code needs CART_EN
;      set; this RAM needs it clear. They cannot both be true, so data touched
;      by a window-resident routine belongs at $A000-$BEFF instead.
;
; WHY THIS COMPOSES WITH EVERYTHING THAT BORROWS THE WINDOW. Only two things in
; the whole game read the cartridge in flight - ring_frame (the radar's ring,
; out of bank 1, via the OS's gpu_rect_bg_cart) and do_explosions (EXPL_OFF, out
; of the COLD bank). Both save CART_SHADOW, select their own bank, and restore
; the WHOLE saved byte on every path out - CART_EN included, checked in
; cpu_os.s. So a borrow inside a bracket returns the bracket's state, not a
; guess at it, and the same is true of these two routines in the other
; direction. That is why win_off/win_on save through CART_SHADOW as well rather
; than writing a constant: $BF60 is a write-only latch and the shadow is the
; only record of what the window was showing.
;
; AND WHY THE BRACKET MUST ALWAYS CLOSE. boot_frame (bootstrap.s) is a
; trampoline that EXECUTES FROM THE WINDOW - the OS jumps to it through
; FRAME_VEC every frame. cart_frame reaching its end with CART_EN clear would
; leave the next frame's first instruction fetch reading RAM where the
; trampoline should be. There is no path out of a bracket that may skip win_on.
; =============================================================================

WINSAVE     = $73C0             ; the bank byte win_off borrowed the window
                                ;   from. $73A6-$73FF is free - shots.s's SPL_
                                ;   block ends at $73A5

        .segment "HIDATA"

win_off:
        lda     CART_SHADOW
        sta     WINSAVE
        lda     #$00                    ; CART_EN clear: the RAM shows through
        jmp     API_CART_BANK

win_on:
        lda     WINSAVE
        jmp     API_CART_BANK
