; =============================================================================
; hud.s - the text readout, and it is OFF
; =============================================================================
; The whole file sits inside .if HUD_ON, so with the switch at 0 it costs
; nothing: no code, no templates, no RAM copy at boot. Turn it on to read the
; counters while flying a tuning question - the speed table, the camera lag -
; and turn it off again.
;
; It is not where the real game's HUD will live. Text opcodes are DESTRUCTIVE:
; they erase what is under them, which is why this readout sits in a band of
; its own rather than over the field. design_technical 5.5 says the shipping
; HUD belongs on the BACKGROUND layer, where the hardware re-copies it for
; nothing - that is how the radar's ring already works (radar_bg.s).
;
; The cost of switching it on: seven VTEXT commands, ~9,900 CPU1 cycles and
; ~48,700 GPU cycles a frame, which is why AST_BUDGET in main.s is derived from
; HUD_ON rather than typed.
; =============================================================================
.if HUD_ON
; -----------------------------------------------------------------------------
; init_strings — copy the HUD templates ROM -> RAM so digits can be patched.
; -----------------------------------------------------------------------------
init_strings:
        ldx     #$00
@lp:    lda     TPL_SPD,x
        sta     STR_SPD,x
        lda     TPL_TRN,x
        sta     STR_TRN,x
        lda     TPL_HDG,x
        sta     STR_HDG,x
        lda     TPL_STA,x
        sta     STR_STA,x
        lda     TPL_SCL,x
        sta     STR_SCL,x
        inx
        cpx     #24
        bne     @lp
        rts
; -----------------------------------------------------------------------------
; do_hud — patch the four RAM strings, then six VTEXT commands.
; -----------------------------------------------------------------------------
; VTEXT's grid is TEXT's transpose: X = character cell 0-36, Y = line 0-49, in
; the same order and directions as the horizontal opcode.
; -----------------------------------------------------------------------------
do_hud:
        lda     ETIER                   ; speed: a canned 4-character field per
        asl     a                       ;   tier, so there is no formatting to do
        asl     a
        tax
        ldy     #$00
:       lda     TIER_TXT,x
        sta     STR_SPD+4,y
        inx
        iny
        cpy     #4
        bne     :-

        lda     TURNIX                  ; turn rate, and the milliseconds per
        clc                             ;   full revolution — the number that is
        adc     #'0'                    ;   actually worth judging
        sta     STR_TRN+5
        lda     TURNIX
        asl     a
        asl     a
        tax
        ldy     #$00
:       lda     TURN_TXT,x
        sta     STR_TRN+7,y
        inx
        iny
        cpy     #4
        bne     :-
        lda     RAMPIX
        clc
        adc     #'0'
        sta     STR_TRN+20

        lda     TSCALE                  ; "TSCALE OFF" / "TSCALE 2 MAX x1.25"
        beq     @scoff
        ldx     #$00                    ; rebuild the line: it may be showing the
:       lda     TPL_SCL2,x              ;   OFF template from a previous frame
        sta     STR_SCL,x
        inx
        cpx     #24
        bne     :-
        lda     TSCALE
        clc
        adc     #'0'
        sta     STR_SCL+7
        lda     TSCALE                  ; (strength-1) * 5 into the max table
        dec     a
        asl     a
        asl     a
        clc
        adc     TSCALE
        sec
        sbc     #$01
        tax
        ldy     #$00
:       lda     TSCALE_TXT,x
        sta     STR_SCL+13,y
        inx
        iny
        cpy     #5
        bne     :-
        bra     @scdone
@scoff: ldx     #$00
:       lda     TPL_SCL,x
        sta     STR_SCL,x
        inx
        cpx     #24
        bne     :-
@scdone:
        lda     HEAD
        jsr     put_hex2
        lda     DEC0
        sta     STR_HDG+5
        lda     DEC1
        sta     STR_HDG+6
        lda     ZOOMH                   ; the zoom, as its raw reciprocal: 128 is
        jsr     put_dec3                ;   1:1 and 64 is twice as far out. The
        lda     DEC0                    ;   number to watch while re-tuning
        sta     STR_HDG+11              ;   ZOOM_RZ, so it is the number shown
        lda     DEC1
        sta     STR_HDG+12
        lda     DEC2
        sta     STR_HDG+13
        lda     OVRCNT                  ; ...and OVR: frames the OS said we did
        jsr     put_dec3                ;   not deliver. It must stay at 000. Any
        lda     DEC0                    ;   other number means the GPU blinked and
        sta     STR_HDG+18              ;   the scene needs thinning
        lda     DEC1
        sta     STR_HDG+19
        lda     DEC2
        sta     STR_HDG+20

        lda     STARN
        jsr     put_dec3
        lda     DEC0
        sta     STR_STA+3
        lda     DEC1
        sta     STR_STA+4
        lda     DEC2
        sta     STR_STA+5
        lda     MOTEN
        jsr     put_dec3
        lda     DEC1
        sta     STR_STA+12
        lda     DEC2
        sta     STR_STA+13
        lda     ADRAWN
        jsr     put_dec3
        lda     DEC1
        sta     STR_STA+16
        lda     DEC2
        sta     STR_STA+17
        lda     RADRAWN                 ; R: contacts actually drawn on the radar.
        jsr     put_dec3                ;   "STARS" lost three letters to make
        lda     DEC1                    ;   room - the line is 24 bytes and every
        sta     STR_STA+20              ;   one of them was spoken for
        lda     DEC2
        sta     STR_STA+21

        lda     #<STR_SPD
        ldx     #>STR_SPD
        ldy     #2
        jsr     vtext_at
        lda     #<STR_TRN
        ldx     #>STR_TRN
        ldy     #4
        jsr     vtext_at
        lda     #<STR_SCL
        ldx     #>STR_SCL
        ldy     #6
        jsr     vtext_at
        lda     #<STR_HDG
        ldx     #>STR_HDG
        ldy     #8
        jsr     vtext_at
        lda     #<STR_STA
        ldx     #>STR_STA
        ldy     #10
        jsr     vtext_at
        lda     #<TXT_H1
        ldx     #>TXT_H1
        ldy     #45
        jsr     vtext_at
        lda     #<TXT_H2
        ldx     #>TXT_H2
        ldy     #47
        ; fall through

; A/X = string pointer, Y = line. Cell 2 keeps clear of the left margin.
vtext_at:
        sta     OS_ARG+3
        stx     OS_ARG+4
        sty     OS_ARG+1
        lda     #$02
        sta     OS_ARG+0
        stz     OS_ARG+2
        jmp     API_GPU_VTEXT

; A -> three ASCII digits in DEC0..DEC2.
put_dec3:
        ldx     #'0'-1
@h:     inx
        sec
        sbc     #100
        bcs     @h
        adc     #100
        stx     DEC0
        ldx     #'0'-1
@t:     inx
        sec
        sbc     #10
        bcs     @t
        adc     #10
        stx     DEC1
        ora     #'0'
        sta     DEC2
        rts

; A -> two ASCII hex digits in DEC0..DEC1.
put_hex2:
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     @nib
        sta     DEC0
        pla
        and     #$0F
        jsr     @nib
        sta     DEC1
        rts
@nib:   cmp     #10
        bcc     :+
        adc     #'A'-10-1               ; carry is set on this path, hence the -1
        rts
:       ora     #'0'
        rts

; =============================================================================
; The strings
; =============================================================================
; Every one of them is only ever read by the routines above, so they sit
; inside the same .if and cost nothing while the HUD is off. The three _TXT
; tables are canned fields indexed by a tier, a rung or a dial position -
; there is no formatting code in this program, only substitution.
; =============================================================================
        .segment "RODATA"
;               -150   -100    -50      0    +50   +100
;               +150   +200   +250   +300   +350        px/s
TIER_TXT:
        .byte   "-150", "-100", "-050", "+000", "+050", "+100"
        .byte   "+150", "+200", "+250", "+300", "+350"
        .byte   "BOST"                  ; TIER_BOOST reads ETIER, so the HUD says
                                        ;   so while it runs

TURN_TXT:
        .byte   "5659", "4244", "3396", "2830", "2425", "2122", "1698", "1415"

TSCALE_TXT: .byte   "x1.12", "x1.25", "x1.50"

; HUD templates. Each is exactly 24 bytes, which is what init_strings copies.
TPL_SPD:    .byte   "SPD +000 PX/S", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_TRN:    .byte   "TURN 2 2122 MS/REV R0", 0, 0, 0
TPL_HDG:    .byte   "HDG $00 RZ 000 OVR000", 0, 0, 0
TPL_STA:    .byte   "ST 000/066 M00 A00 R00", 0, 0
TPL_SCL:    .byte   "TSCALE OFF", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
TPL_SCL2:   .byte   "TSCALE 0 MAX x1.00", 0, 0, 0, 0, 0, 0

; The two help lines, which say what the sticks do.
TXT_H1:     .byte   "J1 TURN/THROTTLE", 0
TXT_H2:     .byte   "J2 UP BOOST  DN TELEPORT", 0

        .segment "CODE"

.endif
