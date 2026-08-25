; =============================================================================
; EfS proto 01 — MAD-65 OS interface equates (only what this cartridge uses)
; =============================================================================
; A cartridge talks to the system ROM through the frozen $FF00 jump table and
; the published OS RAM locations, and through nothing else.
; =============================================================================

; --- OS jump table ($FF00, ABI v1) -------------------------------------------
API_GPU_DOTPIXELS   = $FF24     ; OS_ARG+0..1 = ptr -> { N, x0,y0, ... }  half-res
API_GPU_SPRITE      = $FF2A     ; OS_ARG+0 = SPR_ID, +1..2 = X16, +3..4 = Y16
API_GPU_CLEARBG     = $FF3C     ; (no args) clear the VRAM background
API_RNG             = $FF78     ; next pseudo-random byte -> A
API_SIN             = $FF7B     ; sin(A brad) -> A, signed Q0.7 (-127..127)
API_COS             = $FF7E     ; cos(A brad) -> A, signed Q0.7
API_GPU_VTEXT       = $FFB4     ; OS_ARG+0 = cell 0-36, +1 = line 0-49,
                                ;        +2 = scroll 0-7, +3..4 = ptr -> string
; NOTE: $FF6F joy_read is deliberately NOT listed. The kernel's frame ISR calls
; it once per frame, before cart_frame runs, so a cartridge just reads the
; shadows below. Calling it again zeroes every edge byte.

; --- published OS RAM ---------------------------------------------------------
OS_ARG            = $20         ; $20-$2F - builder argument block
JOY1              = $0A         ; port 1 held state, 1 = pressed
JOY1_PRESS        = $0C         ; port 1 edges: bits newly pressed this frame
JOY2              = $0D         ; port 2 held state
JOY2_PRESS        = $0F         ; port 2 edges

JOY_UP            = %00000001
JOY_DOWN          = %00000010
JOY_LEFT          = %00000100
JOY_RIGHT         = %00001000
JOY_FIRE          = %00010000

; --- cartridge header contract ------------------------------------------------
;   $8000  "MAD65"          5-byte signature the boot ROM looks for
;   $8005  .addr cart_init  one-time init  (boot does jsr (init) before IRQs)
;   $8007  .addr cart_frame per-frame entry (OS wraps it in gpu_begin/gpu_end)
