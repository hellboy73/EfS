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

API_GPU_DOTPOLYGON  = $FFD2     ; OS_ARG+0..1 = ptr -> one argument block:
                                ;     CX.16, CY.16, ANGLE, SCALE, N,
                                ;     dx0,dy0, ... , dxN-1,dyN-1
                                ;   A CLOSED FIGURE round a signed-16 centre that
                                ;   MAY BE OFF SCREEN, rotated by ANGLE (brad, the
                                ;   same sense as API_SIN/API_COS) and scaled by
                                ;   SCALE (Q0.7, 128 = 1:1, SHRINK ONLY) - all of
                                ;   it ON THE GPU - and ALWAYS CLIPPED, properly
                                ;   cut rather than clamped. Offsets are signed
                                ;   bytes from the centre, unrotated and unscaled:
                                ;   the raw shape, exactly as authored. N vertices
                                ;   = N segments; the figure closes itself.
                                ;   2N + 8 PPRAM bytes. This builder is a COPY -
                                ;   CPU1 does no per-vertex work at all.
API_GPU_POLYGON     = $FFD5     ; the same block, SOLID half-res ($4D)
API_GPU_POLYGON16   = $FFD8     ; the same block, SOLID FULL-res ($4E) - the only
                                ;   way to get a full-res figure: a vertex CPU1
                                ;   transforms cannot carry better than half-res
                                ;   precision. Max 254 full-res px across.
API_GPU_CIRCLE16    = $FFDB     ; OS_ARG+0..1 = CX, +2..3 = CY (signed 16, FULL-res,
                                ;   MAY BE OFF SCREEN), +4 = R (full-res px, 0-255).
                                ;   A SOLID circle outline, ALWAYS CLIPPED - the circle
                                ;   member of the anchored family the polygons opened,
                                ;   so an object that is "a circle plus a polygon on one
                                ;   anchor" is one struct and two commands.
                                ;   No ANGLE and no SCALE: a rotation does nothing to a
                                ;   circle, and with none to ride inside, a scale would
                                ;   cost a multiply and a stream byte to save one you
                                ;   already do per object. Scale R yourself.
                                ;   NOT a replacement for $FF27 gpu_dotcircle, which is
                                ;   dotted, half-res, on-screen-only - and about HALF the
                                ;   cycles. Budget: R=10 ~6,400 cycles, R=25 ~14,000,
                                ;   R=50 ~27,500, R=100 ~54,000 (a quarter of a frame).
                                ;   Off screen: 200 cycles flat.

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
