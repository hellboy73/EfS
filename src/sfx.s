; =============================================================================
; Escape from Saturn — sound effects
; =============================================================================
; The effects are hand-written bytecode, edited here and rebuilt with `make` —
; no tool, no asset pipeline. The OS SFX sequencer runs them; this file only
; supplies the programs and the one call that triggers them. The shape is
; CETAS's src/sfx.s, and four of the five programs below ARE its programs,
; taken across unchanged (the shot crack, the mine explosion, the soft hit and
; the metal "kling"); this is a different game but it is the same chip, and
; those already sound right.
;
; Each effect is a step program for the SFX sequencer on SN76489 #2 — the
; DEDICATED effects PSG, so an effect never steals a music voice:
;       effect := type, step, step, …, $FF
;       type   := $00 tone  |  $01 noise
;       step   := frames(@60Hz), note|mode, volume(0-15, 15 = loudest)
; Tone notes are MIDI 45 (A2) … 108 (C8); noise modes 0-7 (6 = low white noise).
;
; The program POINTER goes to the OS through API_SFX_PLAY_PTR, and the engine
; dereferences it LIVE from the frame IRQ — so the data has to stay put and
; stay mapped for the whole length of the effect. That is the real reason this
; whole file is in HIDATA: $A000-$BEFF is MAD-65's upper RAM, real SRAM
; regardless of CART_EN and never bank-switched, so a pointer into it is valid
; from the IRQ no matter which cartridge bank the frame left selected. (It also
; keeps the tight $2000-$5FFF window free — see cart.cfg's note on bank 3.)
;
; VOICE ROUTING — the effects PSG has 3 tone voices + 1 noise voice, all
; shared, so each effect is PINNED to one (the firmware's voice hint) and the
; categories cannot cut each other:
;       voice 0 — the gun
;       voice 1 — rocks being hit
;       voice 2 — the ship being hit
;       voice 7 — noise: the explosion, the thruster puffs and the boost hiss
; The gun fires far more often than anything else; pinning it away from the
; hits is what stops a burst of fire swallowing the feedback for landing one.
;
; THERE IS ONLY ONE NOISE VOICE, and three things now want it — so the noise
; effects do NOT go through sfx_fire directly. They go through noise_fire,
; which is an arbiter: see its own header. A thruster puff must not be able to
; cut the boost hiss, because turning during a boost is the normal case.
;
; TUNING: every number below is data. Edit and `make` — no firmware rebuild.
; =============================================================================

        .segment "HIDATA"

; --- effect ids (index into sfx_lo/sfx_hi/sfx_voice) -------------------------
SE_SHOT      = 0        ; the gun — a short dry crack
SE_ROCK_BOOM = 1        ; a rock came apart — low white-noise thud
SE_ROCK_HIT  = 2        ; a rock took a bullet and SURVIVED it — a dull tap
SE_KLANG     = 3        ; the ship rammed a rock, TONE half — the strike and
                        ;   the ring down after it
SE_PSST      = 4        ; a thruster nozzle fired — a quiet high puff of gas
SE_BOOST     = 5        ; the boost, all 90 frames of it — a low hiss that
                        ;   swells in and dies away
SE_TELEPORT  = 6        ; the ship jumped — a fast rising shimmer
SE_KLANG_N   = 7        ; ...and its NOISE half — the crunch of the contact.
                        ;   Fired together with SE_KLANG; see se_klang

; voice hint per effect: 0/1/2 = a forced tone voice, $FF = noise (auto, voice 7)
VOICE_GUN   = 0
VOICE_ROCK  = 1
VOICE_SHIP  = 2
VOICE_NOISE = $FF

; --- who wins the single noise voice, and for how long ------------------------
; Priorities are compared in noise_fire. Bigger wins; EQUAL ALSO WINS, which is
; the opposite of shake_arm's rule next door and is deliberate - two puffs in a
; row should be two puffs, not one puff and a swallowed one. The lengths are
; each program's own running time in frames, and they are what noise_tick ages;
; they exist because the OS does not publish "is the noise voice busy", and
; guessing from the outside is cheaper than asking the firmware for it.
NPRI_PSST  = 1          ; a puff yields to everything
NPRI_BOOST = 2          ; ...the boost hiss holds the channel against puffs...
NPRI_KLANG = 3          ; ...ramming a rock cuts even the hiss: you just took
                        ;   damage, and that outranks the drive...
NPRI_BOOM  = 4          ; ...and a rock coming apart outranks all of it. It
                        ;   ducks the hiss for its 30 frames and does not give
                        ;   it back - the loudest thing on screen should be the
                        ;   loudest thing in the speaker, and a boost with an
                        ;   explosion in the middle of it is that.
                        ;
                        ; The klang sitting UNDER the boom is safe in a way it
                        ; would not be the other way round: the klang is two
                        ; voices and only its noise half is ever refused, so a
                        ; ram is always heard. Put it on top instead and a rock
                        ; rammed to death would lose its explosion outright,
                        ; because that is one voice and one shot.

NLEN_PSST  = 13         ; se_psst's steps, summed
NLEN_KLANG = 9          ; se_klang_n's
NLEN_BOOM  = 30         ; se_rock_boom's
NLEN_BOOST = BOOST_FRAMES       ; se_boost is authored to the whole boost

; -----------------------------------------------------------------------------
; sfx_fire — A = SE_* id. Play that effect on its assigned voice.
; -----------------------------------------------------------------------------
; PRESERVES X AND Y, which is the whole reason it is written this way rather
; than as three loads and a call: every caller in this game is inside a loop
; holding a slot index in X (shot_hits' bullet/rock walk, rock_destroy, the
; collision response), and none of them can afford to reload it.
; -----------------------------------------------------------------------------
sfx_fire:
        phx
        phy
        tax                             ; id -> table index
        lda     sfx_hi,x
        pha                             ; stash the program pointer's high byte
        ldy     sfx_voice,x             ; Y = the voice this effect is pinned to
        lda     sfx_lo,x                ; A = the low byte
        plx                             ; X = the high byte
        jsr     API_SFX_PLAY_PTR        ; A=lo, X=hi, Y=voice hint
        ply                             ; ...and the caller's index back
        plx
        rts

; -----------------------------------------------------------------------------
; noise_fire — A = SE_* id of a NOISE effect. Play it only if it outranks (or
; matches) whatever already owns the single noise voice. Preserves X and Y.
; -----------------------------------------------------------------------------
; The firmware's own rule for the noise voice is "a new noise effect simply
; replaces a running one" (cpu_os.s), which is fine when explosions are the
; only thing using it and wrong the moment the thrusters are: a boost lasts a
; second and a half, the player turns during it, and every turn would shoot the
; hiss out from under itself. So the game arbitrates before it asks.
;
; The bookkeeping is a priority and a countdown, aged by noise_tick once a
; frame. It can be one frame stale at the edges - a program that has just ended
; still reads as busy until the next tick - which costs nothing here, because
; the only thing a stale "busy" can do is refuse a QUIETER effect one frame
; early.
; -----------------------------------------------------------------------------
noise_fire:
        phx
        tax                             ; id -> table index
        lda     NOISELEFT
        beq     @take                   ; the voice is idle: anything may have it
        lda     sfx_npri,x
        cmp     NOISEPRI
        bcc     @deny                   ; strictly quieter than what is running
@take:  lda     sfx_npri,x
        sta     NOISEPRI
        lda     sfx_nlen,x
        sta     NOISELEFT
        txa                             ; the id again...
        plx                             ; ...and the caller's index back
        jmp     sfx_fire                ; tail - it preserves X and Y too
@deny:  plx
        rts

; -----------------------------------------------------------------------------
; noise_tick — age the noise voice's claim by one frame. Called once from
; sfx_tick, at the top of the frame.
; -----------------------------------------------------------------------------
noise_tick:
        lda     NOISELEFT
        beq     @ret
        dec     NOISELEFT
        bne     @ret
        stz     NOISEPRI                ; the claim lapsed: the voice is free
@ret:   rts

; --- program pointer + voice tables, indexed by SE_* -------------------------
sfx_lo: .byte   <se_shot, <se_rock_boom, <se_rock_hit, <se_klang
        .byte   <se_psst, <se_boost, <se_teleport, <se_klang_n
sfx_hi: .byte   >se_shot, >se_rock_boom, >se_rock_hit, >se_klang
        .byte   >se_psst, >se_boost, >se_teleport, >se_klang_n
sfx_voice:
        .byte   VOICE_GUN, VOICE_NOISE, VOICE_ROCK, VOICE_SHIP
        .byte   VOICE_NOISE, VOICE_NOISE, VOICE_SHIP, VOICE_NOISE

; ...and the arbiter's own two, in the same order. The tone effects have rows
; here only so the tables can share one index; nothing ever reads them, because
; a tone effect never contends for the noise voice and so never goes through
; noise_fire at all.
sfx_npri:
        .byte   0, NPRI_BOOM, 0, 0, NPRI_PSST, NPRI_BOOST, 0, NPRI_KLANG
sfx_nlen:
        .byte   0, NLEN_BOOM, 0, 0, NLEN_PSST, NLEN_BOOST, 0, NLEN_KLANG

; --- the effect programs -----------------------------------------------------

; SE_SHOT — the gun. CETAS's se_shot_orca: a sharp one-frame attack, a fuller
; body under it, gone in five frames. The gun is edge-triggered (shots.s
; shot_fire reads JOY1_PRESS, not JOY1), so one press is one crack.
;
; CETAS'S NOTES, restored — 84/64/52 is its pitch exactly. It was lifted +2 and
; then +4 semitones while this was being tuned and both were wrong; the
; original interval shape is the one that reads as a gun. The ONLY thing kept
; from that pass is the level: every step is FOUR down from CETAS's 13/12/8.
; The volume field is the SN76489's attenuation upside down, 2 dB a step, so
; four steps is -8 dB - a little under half the amplitude. That is the axis to
; nudge if it wants to move; the notes are settled.
se_shot:
        .byte   $00                     ; tone
        .byte   1, 84, 9
        .byte   2, 64, 8
        .byte   2, 52, 4
        .byte   $FF

; SE_ROCK_BOOM — a rock came apart. CETAS's se_boom verbatim, the mina
; explosion: low white noise (mode 6) over a 30-frame loudness decay. The
; longest effect here by a distance, which is what a rock breaking should be
; against the taps around it, and it owns the noise voice alone, so nothing it
; overlaps can cut it short.
se_rock_boom:
        .byte   $01                     ; noise
        .byte   3, 6, 14
        .byte   5, 6, 12
        .byte   6, 6, 9
        .byte   7, 6, 6
        .byte   9, 6, 3
        .byte   $FF

; SE_ROCK_HIT — a bullet landed on a rock and the rock is still standing. The
; WEAK one: a short low tap, five frames, no explosion under it and well below
; the boom, so a big rock's four or five hits read as chipping away at it
; rather than as five little deaths. CETAS's se_hit_soft dropped a couple of
; semitones — a stone, not a creature.
se_rock_hit:
        .byte   $00                     ; tone
        .byte   2, 55, 9
        .byte   3, 50, 6
        .byte   $FF

; SE_KLANG / SE_KLANG_N — the ship rammed a rock. TWO VOICES, fired together
; from ship_hurt (physics.s): a tone half and a noise half.
; -----------------------------------------------------------------------------
; This started as CETAS's se_hit_hard - two tone steps, the second UP from the
; first - and on a bullet hitting a mine that works. Here it read as a plain
; BEEP, and the reason is structural, not a matter of picking better notes: two
; steps of one square wave IS a beep, and no amount of retuning makes a beep
; into a collision. What an impact is made of is a NOISE TRANSIENT with a PITCH
; DROP under it, and one voice cannot be both.
;
; So this is the two-voice shape CETAS reserves for its heaviest hit
; (se_bosshit + se_bosshit_n, "fire both for a 2-voice impact"), which is the
; right weight class: the ship hitting a rock is the biggest thing that happens
; TO the player.
;
;   THE TONE HALF is a strike and a ring-down. One frame bright and loud at the
;   top, one frame already falling off it, and then a body that DROPS - 93, 74,
;   57, 52, 48, 45 - lengthening and quietening the whole way to the engine's
;   lowest note. Falling is the whole point: rising two notes is a doorbell,
;   falling four is something heavy being struck. It ends on 45 because that is
;   the floor, and the floor is the heaviest thing available.
;
;   THE NOISE HALF is the contact itself - the crunch, mode 6 (the lowest of
;   the white-noise rates, the same one the explosion uses), 9 frames, peak 10
;   against the explosion's 14 so it never reads AS an explosion. It goes
;   through noise_fire like every other noise effect, which means it can be
;   refused (see NPRI_KLANG). That is the point of splitting it: the tone half
;   is on the ship's own voice and ALWAYS plays, so a refused crunch costs the
;   impact its edge and never its existence.
;
; LEVEL: both halves are ONE step down from the first draft, which asked for
; "25% quieter". A step is 2 dB, so it is 21% - and it is as close as the part
; gets, because 2 dB IS the SN76489's resolution. Two steps would have been
; 37%. Both halves moved together, or the balance between the strike and the
; crunch would have changed along with the level.
se_klang:
        .byte   $00                     ; tone
        .byte   1, 93, 12               ; the strike - bright, one frame only
        .byte   1, 74, 12               ; ...and off it immediately
        .byte   2, 57, 11               ; ...into the body, which only falls
        .byte   3, 52, 9
        .byte   4, 48, 6
        .byte   6, 45, 3                ; ...ringing down to the engine's floor
        .byte   $FF

se_klang_n:
        .byte   $01                     ; noise
        .byte   2, 6, 10
        .byte   3, 6, 6
        .byte   4, 6, 2
        .byte   $FF                     ; 9 frames - keep NLEN_KLANG in step

; SE_TELEPORT — the ship jumped. The cartoon/sci-fi one: a FAST RISING sweep
; that shimmers as it climbs and cuts off high. Everything about it is the
; opposite of CETAS's se_laser, which falls — falling is a thing being fired,
; rising is a thing LEAVING, and that one bit of direction is most of why this
; reads as a teleport rather than as a weapon.
;
; The shimmer is the zigzag: each step climbs a fourth and the next drops back a
; third, so the line nets upward while wobbling the whole way. That warble is
; what a single square wave has instead of the layered chorus a film would use,
; and it is the trick every 8-bit transporter used for the same reason.
;
; One frame per step through the climb (fast — 13 frames to cross four octaves),
; then three longer steps at the top fading out: the ship is already gone, and
; what is left is the ring. 19 frames all told, which is as long as "short" gets
; before it stops being a jump. On VOICE_SHIP, with the klang: the ship's own
; two events, and they have no reason to happen together.
se_teleport:
        .byte   $00                     ; tone
        .byte   1, 55, 7                ; the climb, shimmering
        .byte   1, 67, 10
        .byte   1, 62, 9
        .byte   1, 74, 11
        .byte   1, 69, 10
        .byte   1, 81, 12
        .byte   1, 76, 11
        .byte   1, 88, 12
        .byte   1, 83, 11
        .byte   1, 95, 12
        .byte   1, 90, 11
        .byte   1, 100, 11
        .byte   1, 96, 10
        .byte   2, 105, 9               ; ...and the ring it leaves behind
        .byte   2, 108, 6
        .byte   2, 108, 3
        .byte   $FF

; SE_PSST — a thruster nozzle firing: a short, quiet puff of gas. NOISE MODE 4,
; the highest of the SN76489's three white-noise rates (4 = N/512, 5 = N/1024,
; 6 = N/2048), so it is thin and hissy where the explosion at mode 6 is a low
; rumble - the same generator, three octaves apart, which is the whole reason
; the three noise sounds in this game can be told apart at all.
;
; Peak 4 out of 15. It fires on turns, on the throttle and on the brake, so it
; is the most frequent sound in the game after the gun, and anything louder
; would be exhausting inside a minute. It DIES AWAY rather than stopping: the
; four steps are a decay, which is what makes it read as escaping gas and not
; as a click.
se_psst:
        .byte   $01                     ; noise
        .byte   2, 4, 4
        .byte   3, 4, 3
        .byte   4, 4, 2
        .byte   4, 4, 1
        .byte   $FF                     ; 13 frames - keep NLEN_PSST in step

; SE_BOOST — the boost, for the whole of it: a low hiss that swells in and dies
; away. NOISE MODE 5, deliberately BETWEEN the puff (4) and the explosion (6) -
; the same family as a nozzle puff, an octave down, which is what "the same
; thrusters, but everything at once" should sound like.
;
; THE ENVELOPE IS THE PROGRAM. Its steps sum to exactly BOOST_FRAMES, so the
; sound and the boost end together with nothing watching either: five short
; steps swelling 1->5 over a quarter of a second, a long hold at 6, then six
; lengthening steps back down to silence. Fading OUT takes twice as long as
; fading in, which is what makes it feel like a drive spinning down rather than
; a switch. The hold is ONE step, so the noise register is written 12 times in
; 90 frames and not 90 - a rewrite restarts the SN76489's shift register, and
; at 60 Hz that periodicity is audible as a buzz sitting on top of the hiss.
;
; Peak 6 against the explosion's 14: eight steps down, -16 dB. Present under
; everything, never over it.
        .assert BOOST_FRAMES = 90, error, "sfx.s: se_boost's envelope is authored to BOOST_FRAMES = 90 - retune its steps to sum to the new value and move this assert"
se_boost:
        .byte   $01                     ; noise
        .byte    3, 5, 1                ; the swell: 15 frames
        .byte    3, 5, 2
        .byte    3, 5, 3
        .byte    3, 5, 4
        .byte    3, 5, 5
        .byte   35, 5, 6                ; ...the hold, one step, no rewrites
        .byte    5, 5, 5                ; ...and the spin-down: 40 frames
        .byte    5, 5, 4
        .byte    6, 5, 3
        .byte    7, 5, 2
        .byte    8, 5, 1
        .byte    9, 5, 0                ; volume 0 IS silence (attenuation 15)
        .byte   $FF                     ; 15 + 35 + 40 = 90 = BOOST_FRAMES

; =============================================================================
; THE THRUSTERS
; =============================================================================
; A puff per nozzle event, and the boost hiss under the whole boost. thrust.s
; already decides, every frame, which nozzles are firing and why (its do_flames
; header lists the five and their four triggers); this reads THOSE flags rather
; than the stick, so a nozzle and its sound can never disagree about whether it
; fired.
;
; EDGE-TRIGGERED, not held. A puff is a puff: one per input, not a hiss for as
; long as the key is down. That is also the contrast the boost is built on -
; it is the one thruster sound that lasts, because it is the one thing the ship
; does that lasts. Releasing a key is silent; so is a puff that arrives while
; the boost hiss owns the noise voice (noise_fire refuses it), which is exactly
; the intent - turning during a boost must not chop the boost up.
;
; Switching turn direction mid-turn DOES puff again - the other pair of nozzles
; genuinely fires - which is why the turn edge compares the whole of FLWDIR and
; not just "is it nonzero".
; =============================================================================

; thrust_sfx — called once a frame from the end of do_flames, after all three
; wants are computed.
thrust_sfx:
        lda     FLWDIR                  ; ---- the turn pair (A+D or B+C)
        cmp     PSST_WT
        beq     @accel                  ; nothing changed
        sta     PSST_WT
        cmp     #$00
        beq     @accel                  ; ...changed to nothing: a release
        jsr     psst

@accel: lda     JOY1                    ; ---- E, the main drive. The RAW stick
        and     #JOY_UP                 ;   and not FLEW, which is also set by
        cmp     PSST_WA                 ;   a fast turn and by the boost - this
        beq     @brake                  ;   one is "the player asked for thrust"
        sta     PSST_WA
        cmp     #$00
        beq     @brake
        jsr     psst

@brake: lda     FLBW                    ; ---- the brake pair (A+B together)
        cmp     PSST_WB
        beq     @ret
        sta     PSST_WB
        cmp     #$00
        beq     @ret
        bra     psst                    ; tail
@ret:   rts

; psst — one puff. The tail of thrust_sfx's brake edge and the helper its other
; two jsr into.
psst:
        lda     #SE_PSST
        jmp     noise_fire

; =============================================================================
; THE EXPLOSION FLASH
; =============================================================================
; One frame of the whole picture lifting out of black, on the same event as
; SE_ROCK_BOOM — CETAS does exactly this on a mina explosion (its effects.s
; bg_flash_tick), and it is the cheapest possible "that one was big": no puff,
; no extra draw, no per-pixel work anywhere. BG_REG is the hardware's
; background-pixel colour, black or dark grey (MAD-65 architecture.md), so
; setting it for one frame raises every unlit pixel on the screen a notch and
; drops it again.
;
; It is a two-frame state machine and not a single write because the ON and the
; OFF are two separate GPU commands, and each has to be emitted from its own
; frame's command list:
;       BGFLASH: 0 idle | 1 turn it ON (-> 2) | 2 turn it OFF (-> 0)
; While rocks keep dying every frame the arm re-writes 1, so the flash simply
; stays lit until they stop and then clears on the frame after.
;
; bgflash_tick is called FIRST in cart_frame, before any drawing, so the
; VIDEO_REG op lands high on the PPRAM command list and cannot be the one thing
; a full list drops — the same placement, and the same reason, as ring_frame.
; =============================================================================

; bgflash_arm — light the flash on the next frame. Preserves A, X and Y, so it
; sits anywhere in a kill path without disturbing it.
bgflash_arm:
        pha
        lda     #$01
        sta     BGFLASH
        pla
        rts

; -----------------------------------------------------------------------------
; sfx_tick — the sound layer's own frame. FIRST in cart_frame: the flash's
; VIDEO_REG op has to land high on the PPRAM command list, for the same reason
; ring_frame goes early, and the noise voice's claim has to age before anything
; this frame asks for it.
; -----------------------------------------------------------------------------
sfx_tick:
        jsr     noise_tick
        ; fall through into the flash

; bgflash_tick — run the two-frame pulse. API_GPU_VREG sub-op 3 = BG_REG on,
; 2 = BG_REG off.
bgflash_tick:
        lda     BGFLASH
        beq     @ret
        cmp     #$01
        bne     @off
        lda     #3                      ; BG_REG ON — the picture lifts
        jsr     API_GPU_VREG
        lda     #$02
        sta     BGFLASH                 ; ...and next frame it goes back down
        rts
@off:
        lda     #2                      ; BG_REG OFF — back to black
        jsr     API_GPU_VREG
        stz     BGFLASH
@ret:
        rts

        .segment "CODE"                 ; back to bank 0 for whatever follows
