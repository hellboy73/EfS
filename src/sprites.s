; =============================================================================
; sprites.s - every sprite in the game, and how they reach the GPU
; =============================================================================
; The GPU's sprite memory, as this cartridge lays it out:
;
;   page $03-$06   the definition table - four pages, one FIELD each (TYPE,
;                  PTR_LSB, PTR_MSB, HEIGHT), one byte per slot
;   page $11       the thruster flames, 27 sprites in one blob    (thrust.s)
;   page $12       the enemy arrows, four sprites in one page     (cam.s)
;   page $13(-$14) the pickup, PK_FRAMES frames                    (pickup.s)
;
;   slot 0         the GPU ROM's test sprite - left alone, so a stray id draws
;                  something recognisable. (The definition pages here hold a
;                  zero in it, as they always have: nothing draws slot 0.)
;   slot 1         free - it was the ship's, when the ship was a sprite
;   slot 2-28      the flames     (FLAME_SLOT0, FLAME_N)
;   slot 29-32     the arrows     (ARW_SLOT0)
;   slot 33 on     the pickup     (PK_SLOT0, PK_FRAMES of them)
;
; NONE OF IT LIVES IN CPU RAM. The art (the three GENERATED files, included
; where their code is, into SPRART) and the four definition pages below are ROM
; in bank SPR_BANK, page aligned, in the order they land in GPU RAM - so the OS
; can stream them straight from the cartridge into LOAD commands
; (gpu_load_cart_begin / gpu_load_cart_n, MAD65_CPU_OS.md), with no cart -> RAM
; -> PPRAM double copy and no staging page. Two jobs, because the GPU wants the
; art and the definitions in two places: the art's pages ($11-$14), then the
; definitions' ($03-$06).
;
; spr_arm arms the first from cart_init, which may not touch the GPU (init runs
; outside gpu_begin/gpu_end) - and arming emits nothing. spr_pump drains it,
; LAST in every frame (cart_frame), because the drain takes whatever PPRAM the
; frame left over and never drops the game's own commands. Eight pages at ~7 a
; frame is the first two or three frames of the intro; the flames, arrows and
; pickups are drawn only in play. SPRJOB is the state: 0 done, 1 art draining,
; 2 definitions draining.
; =============================================================================

spr_art     = flames_data       ; the art's first page - SPRART opens with it
SPR_BANK    = 7                 ; cart.cfg: SPRART's bank (MSGDATA shares it)
SPR_ART_PAGES = PK_PAGE + PK_PAGES - FLAME_PAGE ; $11 flames, $12 arrows,
                                        ;   $13 on the pickup's frames
SPR_DEF_PAGES = 4               ; $03-$06

        .assert FLAME_PAGE = $11 && ARW_PAGE = FLAME_PAGE + 1 && PK_PAGE = ARW_PAGE + 1, error, "sprites.s: the art pages are not contiguous"
        .assert ARW_SLOT0 = FLAME_SLOT0 + FLAME_N && PK_SLOT0 = ARW_SLOT0 + 4, error, "sprites.s: the slot ranges are not adjacent"
        .assert PK_SLOT0 + PK_FRAMES <= 256, error, "sprites.s: slots past 255"
        .assert SPR_BANK = MSG_BANK, error, "sprites.s: SPRART and MSGDATA are one bank"

        .pushseg
        .segment "CODE"                 ; bank 0: the flight engine's neighbour -
                                        ;   CODE2 is full, and this runs once a
                                        ;   frame at most
; -----------------------------------------------------------------------------
; spr_arm - once, from cart_init: arm the art's job.
; -----------------------------------------------------------------------------
spr_arm:
        lda     #SPR_BANK
        sta     OS_ARG+0
        lda     #<spr_art
        sta     OS_ARG+1
        lda     #>spr_art
        sta     OS_ARG+2
        lda     #FLAME_PAGE
        sta     OS_ARG+3
        lda     #SPR_ART_PAGES
        sta     OS_ARG+4
        jsr     API_GPU_LOAD_CART_BEGIN
        lda     #1
        sta     SPRJOB
        rts

; -----------------------------------------------------------------------------
; spr_pump - last in every frame: drain the armed job, and when it is done arm
; the next. Preserves nothing; the frame is over.
; -----------------------------------------------------------------------------
spr_pump:
        lda     SPRJOB
        beq     @ret                    ; 0: nothing armed - the steady state
        jsr     API_GPU_LOAD_CART_N
        lda     LOAD_REM
        bne     @ret                    ; still draining: again next frame
        lda     SPRJOB
        cmp     #2
        bcs     @done                   ; the definitions were the last job
        lda     #SPR_BANK               ; the art is in - the definitions next
        sta     OS_ARG+0
        lda     #<spr_defs
        sta     OS_ARG+1
        lda     #>spr_defs
        sta     OS_ARG+2
        lda     #$03                    ; GPU pages $03-$06
        sta     OS_ARG+3
        lda     #SPR_DEF_PAGES
        sta     OS_ARG+4
        jsr     API_GPU_LOAD_CART_BEGIN
        lda     #2
        sta     SPRJOB
        rts
@done:  stz     SPRJOB
@ret:   rts
        .popseg

; -----------------------------------------------------------------------------
; The definition pages - ROM, in SPRART, straight behind the art.
; -----------------------------------------------------------------------------
; One byte per slot in each field: slots 0-1 zero, the flames', the arrows',
; the pickup's, then zero to the end of the page - exactly what the staging
; code they replace wrote. The flames' three tables are the generated
; constants of flames.s, in the order of its sprites (large up1-3/dn1-3, medium
; up1-3/dn1-3, small up1-4/dn1-4, xl dn1-3 - E's own art, slots 22-24 - then xs
; up1-2/dn1-2, the small bracket's own grow/shrink tier, slots 25-28).
; -----------------------------------------------------------------------------
        .pushseg
        .segment "SPRART"
        .align  256

spr_defs:

; --- page $03, SPR_TYPE ------------------------------------------------------
        .res    FLAME_SLOT0, 0
        .byte   FLAME_L_UP1_TYPE, FLAME_L_UP2_TYPE, FLAME_L_UP3_TYPE
        .byte   FLAME_L_DN1_TYPE, FLAME_L_DN2_TYPE, FLAME_L_DN3_TYPE
        .byte   FLAME_M_UP1_TYPE, FLAME_M_UP2_TYPE, FLAME_M_UP3_TYPE
        .byte   FLAME_M_DN1_TYPE, FLAME_M_DN2_TYPE, FLAME_M_DN3_TYPE
        .byte   FLAME_S_UP1_TYPE, FLAME_S_UP2_TYPE, FLAME_S_UP3_TYPE, FLAME_S_UP4_TYPE
        .byte   FLAME_S_DN1_TYPE, FLAME_S_DN2_TYPE, FLAME_S_DN3_TYPE, FLAME_S_DN4_TYPE
        .byte   FLAME_XL_DN1_TYPE, FLAME_XL_DN2_TYPE, FLAME_XL_DN3_TYPE
        .byte   FLAME_XS_UP1_TYPE, FLAME_XS_UP2_TYPE
        .byte   FLAME_XS_DN1_TYPE, FLAME_XS_DN2_TYPE
        .byte   ARW_RIGHT_TYPE, ARW_LEFT_TYPE, ARW_UP_TYPE, ARW_DOWN_TYPE
        .repeat PK_FRAMES
        .byte   PK_TYPE
        .endrepeat
        .res    256 - PK_SLOT0 - PK_FRAMES, 0
        .assert * - spr_defs = 256, error, "sprites.s: the TYPE page is not 256 bytes"

; --- page $04, SPR_PTR_LSB (each sprite's byte offset within its page) --------
        .res    FLAME_SLOT0, 0
        .byte   FLAME_L_UP1_OFFSET, FLAME_L_UP2_OFFSET, FLAME_L_UP3_OFFSET
        .byte   FLAME_L_DN1_OFFSET, FLAME_L_DN2_OFFSET, FLAME_L_DN3_OFFSET
        .byte   FLAME_M_UP1_OFFSET, FLAME_M_UP2_OFFSET, FLAME_M_UP3_OFFSET
        .byte   FLAME_M_DN1_OFFSET, FLAME_M_DN2_OFFSET, FLAME_M_DN3_OFFSET
        .byte   FLAME_S_UP1_OFFSET, FLAME_S_UP2_OFFSET, FLAME_S_UP3_OFFSET, FLAME_S_UP4_OFFSET
        .byte   FLAME_S_DN1_OFFSET, FLAME_S_DN2_OFFSET, FLAME_S_DN3_OFFSET, FLAME_S_DN4_OFFSET
        .byte   FLAME_XL_DN1_OFFSET, FLAME_XL_DN2_OFFSET, FLAME_XL_DN3_OFFSET
        .byte   FLAME_XS_UP1_OFFSET, FLAME_XS_UP2_OFFSET
        .byte   FLAME_XS_DN1_OFFSET, FLAME_XS_DN2_OFFSET
        .byte   ARW_RIGHT_OFFSET, ARW_LEFT_OFFSET, ARW_UP_OFFSET, ARW_DOWN_OFFSET
        .repeat PK_FRAMES, I
        .byte   <(I * PK_BYTES)
        .endrepeat
        .res    256 - PK_SLOT0 - PK_FRAMES, 0
        .assert * - spr_defs = 512, error, "sprites.s: the PTR_LSB page is not 256 bytes"

; --- page $05, SPR_PTR_MSB (the GPU page - the flames share one blob) --------
        .res    FLAME_SLOT0, 0
        .repeat FLAME_N
        .byte   FLAME_PAGE
        .endrepeat
        .byte   ARW_PAGE, ARW_PAGE, ARW_PAGE, ARW_PAGE
        .repeat PK_FRAMES, I
        .byte   PK_PAGE + >(I * PK_BYTES)
        .endrepeat
        .res    256 - PK_SLOT0 - PK_FRAMES, 0
        .assert * - spr_defs = 768, error, "sprites.s: the PTR_MSB page is not 256 bytes"

; --- page $06, SPR_HEIGHT ----------------------------------------------------
        .res    FLAME_SLOT0, 0
        .byte   FLAME_L_UP1_HEIGHT, FLAME_L_UP2_HEIGHT, FLAME_L_UP3_HEIGHT
        .byte   FLAME_L_DN1_HEIGHT, FLAME_L_DN2_HEIGHT, FLAME_L_DN3_HEIGHT
        .byte   FLAME_M_UP1_HEIGHT, FLAME_M_UP2_HEIGHT, FLAME_M_UP3_HEIGHT
        .byte   FLAME_M_DN1_HEIGHT, FLAME_M_DN2_HEIGHT, FLAME_M_DN3_HEIGHT
        .byte   FLAME_S_UP1_HEIGHT, FLAME_S_UP2_HEIGHT, FLAME_S_UP3_HEIGHT, FLAME_S_UP4_HEIGHT
        .byte   FLAME_S_DN1_HEIGHT, FLAME_S_DN2_HEIGHT, FLAME_S_DN3_HEIGHT, FLAME_S_DN4_HEIGHT
        .byte   FLAME_XL_DN1_HEIGHT, FLAME_XL_DN2_HEIGHT, FLAME_XL_DN3_HEIGHT
        .byte   FLAME_XS_UP1_HEIGHT, FLAME_XS_UP2_HEIGHT
        .byte   FLAME_XS_DN1_HEIGHT, FLAME_XS_DN2_HEIGHT
        .byte   ARW_RIGHT_HEIGHT, ARW_LEFT_HEIGHT, ARW_UP_HEIGHT, ARW_DOWN_HEIGHT
        .repeat PK_FRAMES
        .byte   PK_HEIGHT
        .endrepeat
        .res    256 - PK_SLOT0 - PK_FRAMES, 0
        .assert * - spr_defs = 1024, error, "sprites.s: the HEIGHT page is not 256 bytes"
        .popseg

; The art is three files' worth, included where their code is - flames in
; thrust.s, arrows in cam.s, pickups in pickup.s - and lands in SPRART in that
; order, each page aligned. This is the sentence that says so.
        .assert arrows_data = flames_data + $100 && pickups_data = flames_data + $200, error, "sprites.s: the art is not in page order at the start of SPRART"
        .assert spr_defs = spr_art + SPR_ART_PAGES * $100, error, "sprites.s: the definition pages do not follow the art"
