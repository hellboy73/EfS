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
; EVERY EFFECT GOES THROUGH ONE DOOR, and that door arbitrates. sfx_fire keeps
; a priority claim per voice and refuses anything quieter than what is already
; running there — see the PRI_ block below. A thruster puff must not cut the
; boost hiss (turning during a boost is the normal case), and a ram must not cut
; the loss tune (ramming while blinking through the respawn is too).
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
SE_DEATH     = 8        ; a ship is lost — the warbling fall, THE TOP LAYER of
SE_DEATH_LOW = 9        ; ...its slower, lower second voice under that...
SE_DEATH_N   = 10       ; ...and the blast the two of them ride on. All three
                        ;   fired together from ship.s ship_die - see se_death
SE_UFO_SHOT  = 11       ; a UFO fired (foes.s) - the gun's crack, a fifth up
SE_ALARM     = 12       ; a UFO has seen the ship - beep, beep, beep

; voice hint per effect: 0/1/2 = a forced tone voice, $FF = noise (auto, voice 7)
VOICE_GUN   = 0
VOICE_ROCK  = 1
VOICE_SHIP  = 2
VOICE_NOISE = $FF

VOICE_N     = 4         ; ...and how many claims there are to keep: three tone
                        ;   voices and the noise one. sfx_vi maps the hint above
                        ;   onto 0-3

; --- who wins a VOICE, and for how long --------------------------------------
; This was the noise voice's arbiter alone, because the noise voice was the only
; one three things wanted. THE SHIP'S DEATH MADE IT GENERAL. The loss tune sits
; on VOICE_SHIP with the klang and the teleport, and the ship goes on ramming
; rocks while it plays - during the respawn blink it is INVULNERABLE and grinding
; along one is the normal case - so every ram was shooting the tune out from
; under itself after four notes. Same failure the boost had with the thruster
; puffs, same fix, one voice further along.
;
; So the claim is now per voice (VPRI/VLEN, VOICE_N of each) and sfx_fire itself
; is the arbiter. Priorities are only ever compared WITHIN a voice, so one scale
; covers all four. Bigger wins; EQUAL ALSO WINS, which is the opposite of
; shake_arm's rule next door and is deliberate - two puffs in a row should be two
; puffs, and a second shot should be a second shot, not one and a swallowed one.
;
; The lengths are each program's own running time in frames, summed by hand from
; the steps, and they are what voice_tick ages. They exist because the OS does
; not publish "is this voice busy", and guessing from the outside is cheaper
; than asking the firmware for it. A claim can be one frame stale at the edges -
; a program that has just ended still reads as busy until the next tick - which
; costs nothing, because the only thing a stale "busy" can do is refuse a
; QUIETER effect one frame early.
PRI_FEEDBACK = 1        ; the ordinary per-event feedback: the gun, a rock hit,
                        ;   a ram's tone half, a teleport, a thruster puff. All
                        ;   of them yield to anything above, and to each other
                        ;   they are equal - so a shot never swallows a shot
PRI_BOOST  = 2          ; the boost hiss holds the noise voice against puffs...
PRI_KLANG  = 3          ; ...ramming a rock cuts even the hiss: you just took
                        ;   damage, and that outranks the drive...
PRI_BOOM   = 4          ; ...and a rock coming apart outranks all of it. It
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
PRI_ALARM  = 3          ; the UFO alarm holds VOICE_ROCK for its three beeps:
                        ;   a rock tap or a UFO shot must not cut a warning
                        ;   in half. (Priorities only compare within a voice,
                        ;   so sharing PRI_KLANG's number is no clash.)
PRI_DEATH  = 6          ; ...and above everything, on every voice it uses, a
                        ; ship being lost. It is the rarest event in the game and
                        ; the only one that ends something, so for the ~1.5 s it
                        ; runs it simply owns the chip. The one exception is
                        ; deliberate and is se_death_low's own note.

LEN_SHOT   = 5          ; each program's steps, summed
LEN_ROCKHIT= 5
LEN_KLANG  = 17         ; se_klang's tone half...
LEN_KLANG_N= 9          ; ...and its noise half
LEN_TELE   = 19
LEN_PSST   = 13
LEN_BOOM   = 30
LEN_BOOST  = BOOST_FRAMES       ; se_boost is authored to the whole boost
LEN_DEATH  = 91         ; ...and all THREE layers of the death are authored to
                        ;   the same length, so they end together
LEN_ALARM  = 36

; -----------------------------------------------------------------------------
; sfx_fire — A = SE_* id. Play that effect on its assigned voice.
; -----------------------------------------------------------------------------
; PRESERVES X AND Y, which is the whole reason it is written this way rather
; than as three loads and a call: every caller in this game is inside a loop
; holding a slot index in X (shot_hits' bullet/rock walk, rock_destroy, the
; collision response), and none of them can afford to reload it.
; -----------------------------------------------------------------------------
; The firmware's own rule is "a new effect simply replaces whatever is on the
; voice" (cpu_os.s), which is right for a chip driver and wrong for a game: the
; thing that has been playing for four frames is usually more important than the
; thing that wants to start. So the game arbitrates before it asks, and this is
; where it does it - ONE door, so there is no way to reach the chip past it.
; -----------------------------------------------------------------------------
sfx_fire:
        phx
        phy
        tax                             ; id -> table index

        ldy     sfx_vi,x                ; Y = which claim this effect competes in
        lda     VLEN,y
        beq     @take                   ; the voice is idle: anything may have it
        lda     sfx_pri,x
        cmp     VPRI,y
        bcc     @deny                   ; strictly quieter than what is running
@take:  lda     sfx_pri,x
        sta     VPRI,y
        lda     sfx_len,x
        sta     VLEN,y

        lda     sfx_hi,x
        pha                             ; stash the program pointer's high byte
        ldy     sfx_voice,x             ; Y = the voice this effect is pinned to
        lda     sfx_lo,x                ; A = the low byte
        plx                             ; X = the high byte
        jsr     API_SFX_PLAY_PTR        ; A=lo, X=hi, Y=voice hint
@deny:  ply                             ; ...and the caller's index back
        plx
        rts

; -----------------------------------------------------------------------------
; voice_tick — age all four claims by one frame. Called once from sfx_tick, at
; the top of the frame.
; -----------------------------------------------------------------------------
voice_tick:
        ldx     #VOICE_N-1
@lp:    lda     VLEN,x
        beq     @next
        dec     VLEN,x
        bne     @next
        stz     VPRI,x                  ; the claim lapsed: the voice is free
@next:  dex
        bpl     @lp
        rts

; -----------------------------------------------------------------------------
; voice_reset — every voice unclaimed. cart_init and game_start, so the first
; sound of a game is never refused by a claim left over from the last one.
; -----------------------------------------------------------------------------
voice_reset:
        ldx     #VOICE_N-1
@lp:    stz     VPRI,x
        stz     VLEN,x
        dex
        bpl     @lp
        rts

; --- program pointer + voice tables, indexed by SE_* -------------------------
sfx_lo: .byte   <se_shot, <se_rock_boom, <se_rock_hit, <se_klang
        .byte   <se_psst, <se_boost, <se_teleport, <se_klang_n
        .byte   <se_death, <se_death_low, <se_death_n, <se_ufo_shot
        .byte   <se_alarm
sfx_hi: .byte   >se_shot, >se_rock_boom, >se_rock_hit, >se_klang
        .byte   >se_psst, >se_boost, >se_teleport, >se_klang_n
        .byte   >se_death, >se_death_low, >se_death_n, >se_ufo_shot
        .byte   >se_alarm
sfx_voice:
        .byte   VOICE_GUN, VOICE_NOISE, VOICE_ROCK, VOICE_SHIP
        .byte   VOICE_NOISE, VOICE_NOISE, VOICE_SHIP, VOICE_NOISE
        .byte   VOICE_SHIP, VOICE_GUN, VOICE_NOISE, VOICE_ROCK
        .byte   VOICE_ROCK

; ...the same voice again as a 0-3 CLAIM INDEX, because sfx_voice's $FF is a
; firmware hint ("noise, allocate it yourself") and not a table row. Derived by
; hand rather than at run time: it is one byte an effect against a load, a
; branch and a constant on the one path every sound in the game goes through.
sfx_vi: .byte   VOICE_GUN, 3, VOICE_ROCK, VOICE_SHIP
        .byte   3, 3, VOICE_SHIP, 3
        .byte   VOICE_SHIP, VOICE_GUN, 3, VOICE_ROCK
        .byte   VOICE_ROCK
        .assert VOICE_N = 4, error, "sfx.s: sfx_vi's noise rows say 3; VOICE_N moved"

; ...and the arbiter's own two, in the same order. Every effect has a real row
; now - they used to be zero for anything that was not a noise effect, because
; only the noise voice was arbitrated.
sfx_pri:
        .byte   PRI_FEEDBACK, PRI_BOOM, PRI_FEEDBACK, PRI_FEEDBACK
        .byte   PRI_FEEDBACK, PRI_BOOST, PRI_FEEDBACK, PRI_KLANG
        .byte   PRI_DEATH, PRI_FEEDBACK, PRI_DEATH, PRI_FEEDBACK
        .byte   PRI_ALARM
sfx_len:
        .byte   LEN_SHOT, LEN_BOOM, LEN_ROCKHIT, LEN_KLANG
        .byte   LEN_PSST, LEN_BOOST, LEN_TELE, LEN_KLANG_N
        .byte   LEN_DEATH, LEN_DEATH, LEN_DEATH, LEN_SHOT
        .byte   LEN_ALARM

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

; SE_UFO_SHOT - a UFO fired. The gun's own crack, every note seven semitones up
; - the same interval shape, so it reads as the same weapon, and a fifth higher,
; so the player hears at once that it is not theirs. Same length (LEN_SHOT) and
; level. On VOICE_ROCK, not VOICE_GUN: the two guns firing together must not cut
; each other off, and a UFO shot swallowing a rock's tap is the cheaper loss.
se_ufo_shot:
        .byte   $00                     ; tone
        .byte   1, 91, 9
        .byte   2, 71, 8
        .byte   2, 59, 4
        .byte   $FF

; SE_ALARM - a UFO has seen the ship (foes.s foe_alarm). Beep, beep, beep: three
; flat tones on one pitch with silence between (volume 0 IS silence), because an
; alarm is the one sound that should be nothing but a signal - no sweep, no
; decay, nothing that could be mistaken for a weapon or an impact. D6, well
; above everything the ship and the rocks make, so it reads over a busy screen.
; Eight frames on and six off is ~7 beeps a second: urgent without being a
; buzz. 36 frames all told = LEN_ALARM.
se_alarm:
        .byte   $00                     ; tone
        .byte   8, 86, 10               ; beep
        .byte   6, 86, 0
        .byte   8, 86, 10               ; beep
        .byte   6, 86, 0
        .byte   8, 86, 10               ; beep
        .byte   $FF                     ; 36 frames - keep LEN_ALARM in step

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
;   through sfx_fire's arbiter like everything else, which means it can be
;   refused (see PRI_KLANG). That is the point of splitting it: the tone half
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
        .byte   $FF                     ; 9 frames - keep LEN_KLANG_N in step

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
        .byte   $FF                     ; 13 frames - keep LEN_PSST in step

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

; SE_DEATH / SE_DEATH_LOW / SE_DEATH_N — a ship is lost. THREE VOICES, fired
; together from ship.s ship_die, all three authored to exactly LEN_DEATH frames
; so they end on the same one.
; -----------------------------------------------------------------------------
; This was CETAS's se_death, taken across whole: five steps falling 72 -> 55 on
; one voice. Against that game it works, and here it read as what it literally
; is - a few square notes. The reason is the same structural one se_klang's own
; note works out at length: one square wave playing five pitches is a TUNE, and
; the loss of the ship is not a tune, it is a thing coming apart. What that is
; made of is three simultaneous layers, and the chip has exactly three voices
; free at the moment it happens.
;
;   THE SCREAM (se_death, VOICE_SHIP) is a WARBLE that falls. Six one-frame
;   steps alternating high and low is not heard as six notes - it is heard as
;   one unstable tone, because the ear cannot resolve pitches that fast - and
;   that instability IS the sound of something tearing. Then the alternation
;   widens and slows as the pitch sags, so the warble decays into a plain fall,
;   and the fall lands on 45, the engine's lowest note, and sits there dying.
;   The whole shape is "a machine losing power", and none of it is a melody.
;
;   THE BODY (se_death_low, VOICE_GUN) is the same fall an octave down and half
;   the speed, so it beats against the scream instead of harmonising with it.
;   Two square waves a fraction apart is the only chorus a PSG has.
;
;   THE BLAST (se_death_n, noise) is mode 6 - the lowest white-noise rate, the
;   same one the rock explosion uses - peaking at 14 and taking the full 91
;   frames to decay. It is the loudest thing in the game and it should be: it
;   happens three times a session at most.
;
; VOICE_SHIP for the scream is correct rather than merely convenient: the ram
; that killed the ship fires SE_KLANG on this voice one instruction earlier
; (physics.s ship_hurt), so the loss cuts the strike. The strike has been heard
; by then - it is the frame's first sound - and the thing that follows it should
; own the speaker. PRI_DEATH is what makes that hold for the whole 91 frames
; rather than until the next rock the blinking, invulnerable ship grinds into.
se_death:
        .byte   $00                     ; tone
        .byte    1, 96, 13              ; the tear: too fast to hear as notes
        .byte    1, 84, 13
        .byte    1, 99, 12
        .byte    1, 80, 13
        .byte    1, 93, 12
        .byte    1, 76, 13              ; 6
        .byte    2, 79, 12              ; ...the warble widens and slows as the
        .byte    2, 70, 12              ;    pitch starts to go
        .byte    2, 74, 11
        .byte    2, 65, 12
        .byte    2, 69, 11
        .byte    2, 60, 11              ; 18
        .byte    3, 64, 11
        .byte    3, 55, 10
        .byte    3, 59, 10
        .byte    3, 51, 10              ; 30
        .byte    4, 54,  9              ; ...and stops warbling: now it just
        .byte    4, 49,  9              ;    falls
        .byte    5, 50,  8
        .byte    5, 47,  7              ; 48
        .byte    6, 48,  6
        .byte    7, 46,  5
        .byte    8, 45,  4              ; ...onto the floor, and dying there
        .byte   10, 45,  2
        .byte   12, 45,  1              ; 91
        .byte   $FF                     ; = LEN_DEATH

; THE ONE DELIBERATE EXCEPTION TO PRI_DEATH. This layer is PRI_FEEDBACK, not
; PRI_DEATH, because it sits on the GUN's voice: while SHIPGONE nothing can
; fire (input.s masks the stick), but a life lost that is NOT the last one puts
; the player back in the ship immediately, and a shot they take in the next
; second and a half has to be heard. So the gun cuts the body layer and leaves
; the scream and the blast standing. Losing the bass of a chord to the player's
; own trigger is the right trade; losing the whole death to it is not.
se_death_low:
        .byte   $00                     ; tone
        .byte    4, 64, 10
        .byte    4, 62, 10
        .byte    5, 60,  9
        .byte    5, 58,  9
        .byte    6, 57,  8
        .byte    7, 55,  8
        .byte    8, 53,  7
        .byte    9, 51,  6
        .byte   10, 49,  5
        .byte   11, 47,  4
        .byte   10, 45,  3
        .byte   12, 45,  1
        .byte   $FF                     ; 91 = LEN_DEATH

se_death_n:
        .byte   $01                     ; noise
        .byte    2,  6, 14              ; the bang...
        .byte    4,  6, 13
        .byte    5,  6, 12
        .byte    6,  6, 11
        .byte    7,  6,  9
        .byte    8,  6,  8
        .byte    9,  6,  6              ; ...and a decay three times the length
        .byte   10,  6,  5              ;    of a rock's, because it is three
        .byte   11,  6,  3              ;    times the event
        .byte   12,  6,  2
        .byte   17,  6,  1
        .byte   $FF                     ; 91 = LEN_DEATH

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
; the boost hiss owns the noise voice (sfx_fire refuses it), which is exactly
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
        jmp     sfx_fire

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
; ring_frame goes early, and the four voice claims have to age before anything
; this frame asks for one.
; -----------------------------------------------------------------------------
sfx_tick:
        jsr     voice_tick
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
