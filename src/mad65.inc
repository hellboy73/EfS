; =============================================================================
; Escape from Saturn — MAD-65 OS interface equates (only what this cartridge uses)
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
API_GPU_DOTCIRCLE   = $FF27     ; OS_ARG+0 = CX (0-199), +1 = CY (0-149), +2 = R,
                                ;   half-res: a dotted circle outline ($48). An
                                ;   OFF-SCREEN CENTRE drops the whole command,
                                ;   as does R = 0; a radius past the edges is
                                ;   clipped (the slower path). The EMP (emp.s)
API_GPU_SPRITE      = $FF2A     ; OS_ARG+0 = SPR_ID, +1..2 = X16, +3..4 = Y16
API_GPU_LOAD        = $FF39     ; OS_ARG+0 = GPU page MSB, +1..2 = ptr -> 256 bytes
API_GPU_LOAD_CART_BEGIN = $FF9F ; OS_ARG+0 = cart bank, +1..2 = window address of
                                ;   the first page, +3 = destination START page,
                                ;   +4 = page count: ARM a multi-page job. Emits
                                ;   nothing, so it is legal outside a frame
                                ;   (cart_init) - sprites.s
API_GPU_LOAD_CART_N = $FFA2     ; no args: drain the armed job by the PPRAM this
                                ;   frame has left, ~7 pages. Call it LAST in
                                ;   the frame, between gpu_begin and gpu_end
LOAD_REM            = $0240     ; published: pages of the armed job still to
                                ;   load, 0 = done or idle
API_GPU_LOAD_CART   = $FF9C     ; OS_ARG+0 = cart bank, +1..2 = window address,
                                ;   +3 = GPU page: one LOAD page read straight
                                ;   out of the cartridge. Carry SET = no PPRAM
                                ;   left this frame (pickup.s)
API_GPU_CLEARBG     = $FF3C     ; (no args) clear the VRAM background
API_GPU_HDOTLINE    = $FFB1     ; OS_ARG+0..2 = X1,Y,X2, half-res bytes - a
                                ;   byte-aligned horizontal dotted rule ($49):
                                ;   the OS clamps, orders X1<=X2 and widens the
                                ;   run to whole VRAM bytes (4 half-res px).
                                ;   Image layer only. The laser's beam (laser.s)
API_GPU_DOTLINE_CLIP= $FF93     ; OS_ARG+0..7 = X1,Y1,X2,Y2, signed 16 half-res.
                                ;        Cohen-Sutherland: emits nothing when the
                                ;        segment misses the screen entirely
API_VGM_PLAY        = $FF66     ; OS_ARG+0 = cart bank, +1..2 = addr -> start a
                                ;   VGM stream. $FF = "flat", i.e. the stream is
                                ;   in RAM rather than in a bank
API_VGM_PLAY_LOOP   = $FFAE     ; ...and the same with a SEPARATE loop anchor in
                                ;   OS_ARG+3..5, so a one-shot intro is not
                                ;   replayed on the loop
API_VGM_STOP        = $FF69     ; (no args) silence SN76489 #1 + YM2413
API_VGM_TICK        = $FF6C     ; advance the song one frame. The OS's own IRQ
                                ;   calls this; it is exposed so a harness can
                                ;   stand in for that IRQ - see tools/preview.py
API_CART_BANK       = $FF03     ; A = CART_EN | bank -> select the $8000-$9FFF
                                ;   window's bank. THE ONLY legal way to do it:
                                ;   $BF60 is a WRITE-ONLY latch, and CART_BANK_MIR
                                ;   below is the system's only record of what is
                                ;   selected. Storing to the register directly
                                ;   desynchronises the shadow and breaks every
                                ;   OS call that borrows a bank and hands it
                                ;   back (cart_load, gpu_load_cart,
                                ;   rect_bg_cart, and the replay of the last).
API_GPU_VREG        = $FF3F     ; A = VIDEO_REG sub-op. Only two of the six are
                                ;   used here: 3 = BG_REG on, 2 = BG_REG off -
                                ;   the background pixel colour, black or dark
                                ;   grey, which is the explosion flash
                                ;   (sfx.s bgflash_tick). 1 PPRAM byte.
API_SFX_PLAY_PTR    = $FFAB     ; A = ptr lo, X = ptr hi, Y = voice hint (0-2 =
                                ;   that tone voice, $FF = auto) -> play a
                                ;   CALLER-SUPPLIED step program on the effects
                                ;   PSG. The engine dereferences the pointer
                                ;   live from the frame IRQ, so the program has
                                ;   to be in RAM that is always mapped - which
                                ;   is why src/sfx.s is a HIDATA file.
API_SPK_SAY         = $FFEA     ; OS_ARG+0 = chip (0 = SN76489 #1, non-zero =
                                ;   #2), +1 = tempo, +3 = scale (both signed
                                ;   -2..+2, clamped), +2 = volume (0 = full,
                                ;   1..6 quieter in 2 dB steps), +4..5 = ptr ->
                                ;   a phoneme string -> START SPEAKING. The
                                ;   string is COPIED into the OS's own buffer
                                ;   here, so the pointer only has to be
                                ;   readable AT THE CALL - a cartridge window
                                ;   open on the message bank satisfies it, and
                                ;   the engine never touches a bank itself.
                                ;   Three tone voices and the noise voice of the
                                ;   chip asked for, for as long as it speaks.
                                ;   Calling it again REPLACES the utterance;
                                ;   there is no priority arbitration. Clobbers
                                ;   A/Y (and see SPK_BUSY below).
API_SPK_STOP        = $FFED     ; (no args) stop speaking and SILENCE those four
                                ;   voices. src/speech.s does not call it: a
                                ;   warning cut off mid-word is not a warning.
API_RNG             = $FF78     ; next pseudo-random byte -> A
API_SIN             = $FF7B     ; sin(A brad) -> A, signed Q0.7 (-127..127)
API_COS             = $FF7E     ; cos(A brad) -> A, signed Q0.7
API_GPU_VTEXT       = $FFB4     ; OS_ARG+0 = cell 0-36, +1 = line 0-49,
                                ;        +2 = scroll 0-7, +3..4 = ptr -> string
API_GPU_VTEXT_BG    = $FFB7     ; the same arguments, onto the VRAM BACKGROUND -
                                ;   which the hardware re-copies under the image
                                ;   for free, so a line drawn here costs the GPU
                                ;   NOTHING per frame afterwards. This is what
                                ;   the shipping HUD uses (hud_game.s).
                                ;
                                ;   REPLAY CONTRACT: the OS re-issues the command
                                ;   into the other double-buffer on the NEXT
                                ;   frame, and it stores the POINTER, not the
                                ;   bytes - so the string must not be touched
                                ;   until that has happened, and a second bg
                                ;   command inside the window stomps the replay
                                ;   and makes the line blink. hud_game.s's
                                ;   bgtext_claim is the arbiter for both rules.
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
                                ;   the raw shape, exactly as authored.
                                ;   N's BIT 7 IS THE OPEN FLAG: clear = CLOSED,
                                ;   K vertices = K segments and the figure joins
                                ;   its own ends; set = OPEN, K vertices = K-1
                                ;   segments and no closing edge - a rotated,
                                ;   scaled polyline. Bits 0-6 are the count,
                                ;   0-127. shots.s draws a bullet as $82 (one
                                ;   segment) and debris.s the wreck's four runs
                                ;   the same way; objects.s appends a crack to a
                                ;   damaged rock with it.
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

; --- the transport block: a rectangle on the background, streamed compressed
;     straight from the cartridge. XB/WB/GAP/H are armed once as job state and
;     then fed one band at a time; radar.s uses one band for the whole ring.
API_GPU_RECT_BG_BEGIN = $FFDE   ; OS_ARG+0..3 = XB, WB, GAP, H - arm the job,
                                ;   emits nothing. XB/WB are BYTE columns.
API_GPU_RECT_BG_CART  = $FFE1   ; OS_ARG+0 = source bank, +1..2 = window
                                ;   address of the band's length-prefixed blob
                                ;   (roms/rle.py format), +3..4 = destination
                                ;   row Y (signed 16). Carry SET on return =
                                ;   PPRAM was full this frame, nothing emitted
                                ;   or recorded - just call again next frame.

; --- published OS RAM ---------------------------------------------------------
OS_ARG            = $20         ; $20-$2F - builder argument block
CART_BANK_MIR     = $09         ; the OS's software copy of the write-only bank
                                ;   latch. READ it to find out which bank is
                                ;   selected; never write it - go through
                                ;   API_CART_BANK, which writes both.
CART_SHADOW       = CART_BANK_MIR ; the name this byte carried until 2026-09-21,
                                ;   kept so sources not yet renamed still build.
CART_EN           = $80         ; bit 7 of the bank byte: 1 = cartridge enabled
OVERRUN_FLAG      = $03         ; the OS sets this when a VSYNC fired before
                                ;   gpu_end - i.e. the GPU drew nothing that
                                ;   frame. STICKY: the OS never clears it.
SPK_BUSY          = $024D       ; the speech engine: 0 = idle, non-zero = still
                                ;   speaking. PUBLISHED, and it is the whole
                                ;   mechanism - hud_game.s's message bar holds
                                ;   its line while this is set, so a sentence is
                                ;   never read out after its text has gone.
SPK_CUR           = $0252       ; index of the NEXT phoneme, 0 up. For a caption
                                ;   that arrives WITH the voice, word by word;
                                ;   this game shows the whole line at once and
                                ;   does not read it. Kept because it is ABI.
JOY1              = $0A         ; port 1 held state, 1 = pressed
JOY1_PREV         = $0B         ; port 1 state on the PREVIOUS frame - for
                                ;   detecting a release, not just a press
JOY1_PRESS        = $0C         ; port 1 edges: bits newly pressed this frame
JOY2              = $0D         ; port 2 held state
JOY2_PREV         = $0E         ; port 2 state on the previous frame
JOY2_PRESS        = $0F         ; port 2 edges

JOY_UP            = %00000001
JOY_DOWN          = %00000010
JOY_LEFT          = %00000100
JOY_RIGHT         = %00001000
JOY_FIRE          = %00010000
JOY_FIRE2         = %00100000

; --- the speech engine's phoneme indices (ABI) --------------------------------
; One byte per phoneme, %SSPPPPPP: the index in the low six bits, the length and
; stress in the top two. A low six bits of zero ENDS the string. tools/mkspeech.py
; writes these bytes; the names are here because they are the OS's, not ours -
; the table they index lives in cpu_os.bin.
;
; EVERY STOP CONSONANT IS A CLOSURE AND THEN A BURST: CLS before P/T/K, CLZ
; before B/D/G. Leave the silence out and /t/ is a click, not a T.
SPK_PH_I          = 1           ; /i/   bEAt
SPK_PH_IH         = 2           ; /I/   bIt
SPK_PH_EH         = 3           ; /E/   bEt
SPK_PH_AE         = 4           ; /ae/  bAt
SPK_PH_AA         = 5           ; /a/   fAther
SPK_PH_AO         = 6           ; /O/   bOught
SPK_PH_UH         = 7           ; /U/   bOOk
SPK_PH_UW         = 8           ; /u/   bOOt
SPK_PH_AH         = 9           ; /V/   bUt
SPK_PH_AX         = 10          ; /@/   schwa
SPK_PH_ER         = 11          ; /R/   bIRd
SPK_PH_M          = 12          ; /m/   nasal
SPK_PH_N          = 13          ; /n/   nasal
SPK_PH_NG         = 14          ; /ng/  nasal
SPK_PH_L          = 15          ; /l/
SPK_PH_R          = 16          ; /r/
SPK_PH_W          = 17          ; /w/
SPK_PH_Y          = 18          ; /j/   Yes
SPK_PH_CLS        = 19          ; voiceless stop closure, before /p/ /t/ /k/
SPK_PH_CLZ        = 20          ; voiced stop closure, before /b/ /d/ /g/
SPK_PH_PAU        = 21          ; word gap
SPK_PH_P          = 22          ; /p/ burst
SPK_PH_B          = 23          ; /b/ burst
SPK_PH_T          = 24          ; /t/ burst
SPK_PH_D          = 25          ; /d/ burst
SPK_PH_K          = 26          ; /k/ burst
SPK_PH_G          = 27          ; /g/ burst
SPK_PH_HH         = 28          ; /h/ aspiration
SPK_PH_S          = 29          ; /s/
SPK_PH_Z          = 30          ; /z/
SPK_PH_SH         = 31          ; /sh/
SPK_PH_F          = 32          ; /f/
SPK_PH_V          = 33          ; /v/
SPK_PH_TH         = 34          ; /th/

SPK_SHORT         = $00         ; half the table's duration
SPK_NORM          = $40         ; the table's own duration
SPK_LONG          = $80         ; half as long again
SPK_STRESS        = $C0         ; ...and 2 dB louder with it

; --- cartridge header contract ------------------------------------------------
;   $8000  "MAD65"          5-byte signature the boot ROM looks for
;   $8005  .addr cart_init  one-time init  (boot does jsr (init) before IRQs)
;   $8007  .addr cart_frame per-frame entry (OS wraps it in gpu_begin/gpu_end)
