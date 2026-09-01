; =============================================================================
; EfS proto 01 — MAD-65 OS interface equates (only what this cartridge uses)
; =============================================================================
; A cartridge talks to the system ROM through the frozen $FF00 jump table and
; the published OS RAM locations, and through nothing else.
; =============================================================================

; --- OS jump table ($FF00, ABI v1) -------------------------------------------
API_GPU_LINE        = $FF15     ; OS_ARG+0..3 = X1,Y1,X2,Y2, half-res bytes.
API_GPU_LINE16      = $FFC0     ; OS_ARG+0..7 = X1,Y1,X2,Y2, signed 16 FULL-res.
                                ;   Same clamping as $FF15, same renderer - only
                                ;   the ENDPOINTS stop being doubled, which is
                                ;   what stops a slowly moving line stepping 2 px
                                ;   at a time. 8 PPRAM bytes instead of 4.
                                ;        Solid, unlike the DOT_ family.
API_GPU_LINES       = $FFC6     ; OS_ARG+0..1 = ptr -> { N, x0,y0, ... } half-res
                                ;   - the SOLID twin of DOTLINES ($4A)
API_GPU_LINE_CLIP   = $FFC3     ; OS_ARG+0..7 = X1,Y1,X2,Y2 signed 16 half-res,
                                ;   clipped, emitting LINE ($42)
API_GPU_DOTLINE     = $FF1B     ; OS_ARG+0..3 = X1,Y1,X2,Y2, half-res bytes
API_GPU_DOTLINES    = $FF1E     ; OS_ARG+0..1 = ptr -> { N, x0,y0, ... }  half-res
                                ;        a chain of N connected dotted segments
API_GPU_DOTPIXELS   = $FF24     ; OS_ARG+0..1 = ptr -> { N, x0,y0, ... }  half-res
API_GPU_SPRITE      = $FF2A     ; OS_ARG+0 = SPR_ID, +1..2 = X16, +3..4 = Y16
API_GPU_LOAD        = $FF39     ; OS_ARG+0 = GPU page MSB, +1..2 = ptr -> 256 bytes
API_GPU_CLEARBG     = $FF3C     ; (no args) clear the VRAM background
API_GPU_DOTLINE_CLIP= $FF93     ; OS_ARG+0..7 = X1,Y1,X2,Y2, signed 16 half-res.
                                ;        Cohen-Sutherland: emits nothing when the
                                ;        segment misses the screen entirely
API_RNG             = $FF78     ; next pseudo-random byte -> A
API_SIN             = $FF7B     ; sin(A brad) -> A, signed Q0.7 (-127..127)
API_COS             = $FF7E     ; cos(A brad) -> A, signed Q0.7
API_GPU_VTEXT       = $FFB4     ; OS_ARG+0 = cell 0-36, +1 = line 0-49,
                                ;        +2 = scroll 0-7, +3..4 = ptr -> string
; NOTE: $FF6F joy_read is deliberately NOT listed. The kernel's frame ISR calls
; it once per frame, before cart_frame runs, so a cartridge just reads the
; shadows below. Calling it again zeroes every edge byte.

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
OS_ARG            = $20         ; $20-$2F - builder argument block
OVERRUN_FLAG      = $03         ; the OS sets this when a VSYNC fired before
                                ;   gpu_end - i.e. the GPU drew nothing that
                                ;   frame. STICKY: the OS never clears it.
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
