; =============================================================================
; EfS proto 01 — cartridge header (segment HEADER, loaded at $8000 in bank 0)
; =============================================================================
; Hard contract read by the MAD-65 boot ROM before any code moves. This block
; MUST be the first thing in the bank: boot enables bank 0 and compares the five
; signature bytes at $8000 before it will hand over.
;
; The two vectors point at the BOOTSTRAP stubs, not at the game routines: the
; game itself is copied into RAM before its first instruction runs. See
; bootstrap.s.
; =============================================================================

        .import boot_init
        .import boot_frame

        .segment "HEADER"

        .byte   "MAD65"
        .addr   boot_init
        .addr   boot_frame
