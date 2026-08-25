; =============================================================================
; comb_test — MAD-65 OS interface equates (only what this cartridge uses)
; =============================================================================
; A cartridge talks to the system ROM through the frozen $FF00 jump table and
; the published OS RAM locations, and through nothing else. Mirror of cpu_os.s.
; =============================================================================

; --- OS jump table ($FF00, ABI v1) -------------------------------------------
API_GPU_SPRITE      = $FF2A     ; OS_ARG: SPR_ID, X16, Y16
API_GPU_TEXT        = $FF2D     ; OS_ARG: col,row,scroll, ptr → string
API_GPU_TEXT_BG     = $FF30     ; …to the background (auto-replayed next frame)
API_GPU_LOAD        = $FF39     ; OS_ARG: dest page MSB, ptr → 256 bytes
API_GPU_CLEARBG     = $FF3C     ; (no args) clear the VRAM background
; NOTE: $FF6F joy_read is deliberately NOT listed. The kernel's frame ISR calls it
; once per frame, before cart_frame runs, so a cartridge just reads the shadows
; below. Calling it a second time recomputes JOY*_PREV from the current state and
; zeroes every edge byte — held directions still work, every press does not.
API_GPU_COMB_SPRITE = $FFBA     ; OS_ARG: SPR_ID, X16, Y16, GAP (0–15)

; --- published OS RAM ---------------------------------------------------------
OS_ARG            = $20         ; $20–$2F — builder argument block
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
