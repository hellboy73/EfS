#!/usr/bin/env python3
"""vgm_main_theme_gen.py — generate assets/vgm/main_theme.vgm, the full
gameplay track, as a direct continuation of title_intro.vgm (tools/
vgm_intro_gen.py): same tempo, same nine-channel instrument palette, same
key (D natural minor / F major), same devices (evolving ostinato, sparse
theremin accents, echo+PSG-beep fills, structural gong hits). Longer, with
more instrumental variety and embellishment than the source material itself
carries — Holst's "Saturn" is the inspiration for the mood (a tolling,
spacious old-age march), not a transcription; nothing here quotes it note
for note.

Form (an arc, not a straight loop of one phrase): Intro (one-shot) | A
exposition | B development | C first climax | D SECOND KEY AREA, F major,
melody handed to Trumpet instead of Organ | E reprise of A (fuller texture
under the same tune) | F final climax/coda, thinning into the loop wrap.

Channel map (identical to title_intro.vgm):
  ch0 Flute    - echo/fill trail behind the melody
  ch1 Acoustic Bass - pedal, retriggered periodically (a decaying ROM
                  envelope held via a single key-on can go silent long
                  before the next section -- learned the hard way on the
                  title-theme-sketch rearrangement, 2026-09-14)
  ch2 Harpsichord - ostinato, pattern evolves per section
  ch3 Vibraphone  - gong, one hit per section boundary
  ch4 Organ       - melody (A/B/C/E/F)
  ch5 Oboe        - harmony
  ch6 Clarinet    - theremin-style glide accents, sparse, never continuous
  ch7 Synthesizer - sparkle arpeggio, climax sections only
  ch8 Trumpet     - fanfare stabs at section pivots, AND the lead melody
                  voice for all of section D (the one section it isn't
                  doing fanfare stabs)
PSG: noise channel = the same periodic (not white) clock tick as
title_intro.vgm throughout; tone channel 1 = quiet retro "beep" fills in
melody rests, same device as title_intro.vgm v3.
"""
import struct
import os

SN_CLOCK = 3579545
OPLL_CLOCK = 3579545
SAMPLE_RATE = 44100
BEAT = 1.5

INS_VIOLIN, INS_GUITAR, INS_PIANO, INS_FLUTE, INS_CLARINET = 1, 2, 3, 4, 5
INS_OBOE, INS_TRUMPET, INS_ORGAN, INS_HORN, INS_SYNTH = 6, 7, 8, 9, 10
INS_HARPSICHORD, INS_VIBRAPHONE, INS_SYNTH_BASS, INS_ACOUSTIC_BASS = 11, 12, 13, 14

_PITCH_CLASS = {
    'C': -9, 'C#': -8, 'Db': -8, 'D': -7, 'D#': -6, 'Eb': -6, 'E': -5,
    'F': -4, 'F#': -3, 'Gb': -3, 'G': -2, 'G#': -1, 'Ab': -1, 'A': 0,
    'A#': 1, 'Bb': 1, 'B': 2,
}


def note_hz(name):
    pc, octstr = (name[:2], name[2:]) if len(name) >= 2 and name[1] in '#b' else (name[:1], name[1:])
    semitone = _PITCH_CLASS[pc] + (int(octstr) - 4) * 12
    return 440.0 * (2.0 ** (semitone / 12.0))


def t(beats):
    return round(beats * BEAT * SAMPLE_RATE)


def la(beat):
    return t(1 + beat)  # loop-relative: beat 0 == the loop anchor, absolute beat 1


def opll_fnum_block(freq, clock=OPLL_CLOCK):
    for block in range(8):
        fnum = round(freq * (2 ** (19 - block)) * 72 / clock)
        if 0 <= fnum <= 511:
            return fnum, block
    return 511, 7


def sn_divisor(freq, clock=SN_CLOCK):
    return max(1, min(1023, round(clock / (32.0 * freq))))


def opll_write(addr, val):
    return bytes([0x51, addr & 0xFF, val & 0xFF])


def sn_atten_write(channel, atten):
    return bytes([0x50, 0x80 | ((channel * 2 + 1) << 4) | (atten & 0xF)])


def sn_tone_write(channel, freq):
    n = sn_divisor(freq)
    return bytes([0x50, 0x80 | ((channel * 2) << 4) | (n & 0xF), 0x50, (n >> 4) & 0x3F])


def sn_noise_control(fb, shift_rate):
    return bytes([0x50, 0x80 | (6 << 4) | (((1 if fb else 0) << 2) | (shift_rate & 0x3))])


def opll_instrument(ch, instrument, volume):
    return opll_write(0x30 + ch, ((instrument & 0xF) << 4) | (volume & 0xF))


def opll_note_on(ch, freq):
    fnum, block = opll_fnum_block(freq)
    return (opll_write(0x10 + ch, fnum & 0xFF) +
            opll_write(0x20 + ch, 0x10 | (block << 1) | ((fnum >> 8) & 1)))


def opll_note_off(ch, freq):
    fnum, block = opll_fnum_block(freq)
    return opll_write(0x20 + ch, (block << 1) | ((fnum >> 8) & 1))


def opll_retrigger(ch, freq):
    fnum, block = opll_fnum_block(freq)
    return opll_write(0x20 + ch, (block << 1) | ((fnum >> 8) & 1)) + opll_note_on(ch, freq)


events = []


def add(time_samples, data):
    events.append((time_samples, data))


def schedule_notes(ch, notes, instrument, volume):
    add(la(notes[0][0]), opll_instrument(ch, instrument, volume))
    for start, dur, name in notes:
        if name is not None:
            f = note_hz(name)
            add(la(start), opll_retrigger(ch, f))
            add(la(start + dur), opll_note_off(ch, f))


def echo_and_fills(echo_ch, beep_channel, notes, instrument_echo, vol_echo):
    add(la(notes[0][0]), opll_instrument(echo_ch, instrument_echo, vol_echo))
    for idx, (start, dur, name) in enumerate(notes):
        if name is not None:
            f = note_hz(name)
            echo_start = start + dur
            echo_dur = min(dur * 0.5, 1.0)
            add(la(echo_start), opll_retrigger(echo_ch, f))
            add(la(echo_start + echo_dur), opll_note_off(echo_ch, f))
        else:
            prev_name = next((n for s, d, n in reversed(notes[:idx]) if n is not None), None)
            if prev_name is None:
                continue
            f = note_hz(prev_name) * 2
            for frac in (0.25, 0.6):
                on_t = la(start + dur * frac)
                off_t = on_t + round(0.09 * SAMPLE_RATE)
                add(on_t, sn_tone_write(1, f))
                add(on_t, sn_atten_write(1, 12))
                add(off_t, sn_atten_write(1, 15))


def ostinato_section(ch, pattern, start_rel, end_rel, step, instrument, volume):
    add(la(start_rel), opll_instrument(ch, instrument, volume))
    beat, i = start_rel, 0
    while beat < end_rel:
        add(la(beat), opll_retrigger(ch, note_hz(pattern[i % len(pattern)])))
        i += 1
        beat += step


def bass_section(start_rel, end_rel, note_name, retrigger_every, instrument, volume):
    add(la(start_rel), opll_instrument(1, instrument, volume))
    f = note_hz(note_name)
    beat = start_rel
    while beat < end_rel:
        add(la(beat), opll_retrigger(1, f))
        beat += retrigger_every


def sparkle_section(ch, pattern, start_rel, end_rel, step, gate, instrument, volume):
    add(la(start_rel), opll_instrument(ch, instrument, volume))
    beat, i = start_rel, 0
    while beat < end_rel:
        f = note_hz(pattern[i % len(pattern)])
        add(la(beat), opll_retrigger(ch, f))
        add(la(beat + step * gate), opll_note_off(ch, f))
        i += 1
        beat += step


def fanfare(ch, notes, start_rel, note_step, instrument, volume):
    add(la(start_rel), opll_instrument(ch, instrument, volume))
    for i, name in enumerate(notes):
        f = note_hz(name)
        s = start_rel + i * note_step
        add(la(s), opll_retrigger(ch, f))
        add(la(s + note_step * 0.8), opll_note_off(ch, f))


def glide(ch, f_start, f_end, t_start, t_end, steps):
    for k in range(steps + 1):
        frac = k / steps
        f = f_start * (f_end / f_start) ** frac
        tt = round(t_start + frac * (t_end - t_start))
        add(tt, opll_note_on(ch, f) if k == 0 else opll_retrigger(ch, f))


def gong_hit(time_abs, volume, ring_beats=0.9):
    add(time_abs, opll_instrument(3, INS_VIBRAPHONE, volume))
    add(time_abs, opll_note_on(3, note_hz('A2')))
    add(time_abs + round(ring_beats * BEAT * SAMPLE_RATE), opll_note_off(3, note_hz('A2')))


# ---------------------------------------------------------------------------
# Form. Loop-relative beat 0 == the loop anchor == absolute beat 1.
# ---------------------------------------------------------------------------
LOOP_END_BEAT = 180
END_TIME = la(LOOP_END_BEAT)
LOOP_ANCHOR_TIME = la(0)

# --- Intro: same gesture as title_intro.vgm -- gong + bass, one-shot ---
add(t(0), opll_write(0x0E, 0x00))
add(t(0), opll_instrument(1, INS_ACOUSTIC_BASS, 9))
add(t(0), opll_note_on(1, note_hz('D2')))
add(t(0), sn_noise_control(fb=0, shift_rate=1))
add(t(0), sn_atten_write(1, 15))
gong_hit(t(0), volume=4)

# --- clock tick, whole piece ---
for beat in range(0, LOOP_END_BEAT + 1):
    on_time = t(beat)
    off_time = on_time + round(0.12 * SAMPLE_RATE)
    atten = 9 if (56 <= beat - 1 < 80 or 140 <= beat - 1 < 176) else 11
    add(on_time, sn_atten_write(3, atten))
    add(off_time, sn_atten_write(3, 15))

# --- bass pedal: D through A/B, F under the D section (new key area), D again for E/F ---
bass_section(0, 80, 'D2', 8, INS_ACOUSTIC_BASS, 9)
bass_section(80, 116, 'F2', 8, INS_ACOUSTIC_BASS, 9)
bass_section(116, LOOP_END_BEAT, 'D2', 8, INS_ACOUSTIC_BASS, 9)

# --- ostinato: evolves per section, returns for the reprise ---
ostinato_section(2, ['D3', 'C#3'], 0, 24, 1, INS_HARPSICHORD, 8)
ostinato_section(2, ['E3', 'D3', 'F3', 'D3'], 24, 56, 1, INS_HARPSICHORD, 7)
ostinato_section(2, ['A3', 'G3', 'F3', 'G3'], 56, 80, 0.5, INS_HARPSICHORD, 5)
ostinato_section(2, ['F3', 'E3', 'G3', 'E3'], 80, 116, 0.5, INS_HARPSICHORD, 6)
ostinato_section(2, ['D3', 'C#3'], 116, 140, 1, INS_HARPSICHORD, 8)
ostinato_section(2, ['D4', 'A3', 'F3', 'A3'], 140, 176, 0.5, INS_HARPSICHORD, 4)
ostinato_section(2, ['D3', 'C#3'], 176, LOOP_END_BEAT, 1, INS_HARPSICHORD, 9)

# --- gong at every section pivot, escalating into the two climaxes ---
for beat_, vol_ in [(24, 6), (56, 3), (80, 5), (116, 5), (140, 3), (158, 2)]:
    gong_hit(la(beat_), volume=vol_)

# --- fanfare (ch8): pivots outside section D, where ch8 carries the melody instead ---
for beat_ in (24, 56, 116, 140):
    fanfare(8, ['D4', 'F4', 'A4'], beat_, 0.25, INS_TRUMPET, 6)

# --- A: exposition ---
melody_a = [
    (1, 2, 'A3'), (3, 1, None), (4, 2, 'G3'), (6, 1, 'F3'), (7, 2, 'E3'),
    (9, 1, None), (10, 3, 'D4'), (13, 1, None), (14, 2, 'A3'),
    (17, 2, 'F3'), (19, 1, None), (20, 3, 'D3'),
]
schedule_notes(4, melody_a, INS_ORGAN, 6)
echo_and_fills(0, 1, melody_a, INS_FLUTE, 10)

# --- B: development 1, harmony enters ---
melody_b = [
    (24, 2, 'F4'), (26, 2, 'E4'), (28, 1, None), (29, 2, 'D4'), (31, 2, 'C4'),
    (33, 1, 'B3'), (34, 2, 'A3'), (36, 1, None), (37, 3, 'F4'), (40, 1, None),
    (41, 2, 'D4'), (43, 2, 'A3'), (45, 2, 'F3'), (48, 2, 'G3'), (50, 2, 'A3'),
    (52, 1, None), (53, 3, 'Bb3'),
]
schedule_notes(4, melody_b, INS_ORGAN, 6)
echo_and_fills(0, 1, melody_b, INS_FLUTE, 10)
harmony_b = [(24, 4, 'D4'), (29, 4, 'A3'), (34, 3, 'F3'), (37, 4, 'A3'), (41, 4, 'F3'), (48, 5, 'D4')]
schedule_notes(5, harmony_b, INS_OBOE, 6)

# --- C: first climax ---
melody_c = [
    (56, 2, 'A4'), (58, 2, 'G4'), (60, 1, 'F4'), (61, 2, 'E4'), (63, 1, None),
    (64, 3, 'D5'), (67, 1, None), (68, 2, 'A4'), (70, 2, 'F4'), (72, 1, 'D4'),
    (74, 2, 'E4'), (76, 2, 'C5'), (78, 2, 'A4'),
]
schedule_notes(4, melody_c, INS_ORGAN, 4)
echo_and_fills(0, 1, melody_c, INS_FLUTE, 9)
harmony_c = [(56, 4, 'D4'), (61, 3, 'A3'), (64, 4, 'F4'), (68, 4, 'D4'), (74, 4, 'A3')]
schedule_notes(5, harmony_c, INS_OBOE, 5)
sparkle_section(7, ['D5', 'A4', 'F4', 'A4'], 56, 80, 0.5, 0.8, INS_SYNTH, 8)

# --- D: second key area, F major -- melody handed to Trumpet ---
melody_d = [
    (80, 2, 'F4'), (82, 2, 'A4'), (84, 1, 'C5'), (85, 2, 'Bb4'), (87, 1, None),
    (88, 3, 'A4'), (91, 1, None), (92, 2, 'F4'), (94, 2, 'D4'), (96, 2, 'C4'),
    (98, 2, 'Bb3'), (100, 2, 'D4'), (102, 1, 'F4'), (103, 2, 'A4'), (105, 1, None),
    (106, 3, 'G4'), (109, 1, None), (110, 2, 'F4'), (112, 2, 'D4'), (114, 2, 'C4'),
]
schedule_notes(8, melody_d, INS_TRUMPET, 6)
echo_and_fills(0, 1, melody_d, INS_FLUTE, 10)
harmony_d = [(80, 5, 'A3'), (85, 4, 'F3'), (92, 4, 'C4'), (98, 4, 'A3'), (106, 6, 'F3')]
schedule_notes(5, harmony_d, INS_OBOE, 7)

# --- E: reprise of A, fuller texture underneath the same tune ---
melody_e = [(s + 116, d, n) for s, d, n in melody_a]
schedule_notes(4, melody_e, INS_ORGAN, 5)
echo_and_fills(0, 1, melody_e, INS_FLUTE, 9)
harmony_e = [(116, 6, 'F3'), (124, 6, 'A3'), (132, 6, 'D4')]
schedule_notes(5, harmony_e, INS_OBOE, 8)
sparkle_section(7, ['A4', 'F4', 'D4', 'F4'], 116, 140, 1, 0.6, INS_SYNTH, 11)

# --- F: final climax / coda, biggest, then thin to nothing before the loop ---
melody_f = [
    (140, 2, 'D5'), (142, 2, 'C5'), (144, 1, 'Bb4'), (145, 2, 'A4'), (147, 1, None),
    (148, 4, 'D5'), (152, 1, None), (153, 2, 'A4'), (155, 2, 'F4'), (157, 1, 'D4'),
    (158, 3, 'A3'), (161, 1, None), (162, 3, 'F3'), (165, 1, None), (166, 4, 'D3'),
]
schedule_notes(4, melody_f, INS_ORGAN, 3)
echo_and_fills(0, 1, melody_f, INS_FLUTE, 8)
harmony_f = [(140, 4, 'F4'), (145, 3, 'D4'), (148, 5, 'A4'), (155, 3, 'D4'), (158, 3, 'F3')]
schedule_notes(5, harmony_f, INS_OBOE, 4)
sparkle_section(7, ['D5', 'A4', 'F4', 'C5'], 140, 158, 0.5, 0.8, INS_SYNTH, 6)

# --- an original motif, not from Holst: a rising, determined 4-beat cell
# (D4-F4-A4-G4-F4 -- an ascending tonic triad instead of Holst's even, level
# tread) standing for the player/the escape itself, cutting through the
# Saturn material rather than being derived from it. Same key, same tempo,
# but a different rhythmic character on purpose. It appears three times,
# growing: a quiet, tentative hint (Synthesizer, idle mid-B), a fuller
# restatement reaching further (Clarinet, idle before the D section), and
# the full, loud statement (Trumpet) right as the final climax begins --
# alongside, not instead of, the Organ's own climactic line: the two ideas
# meet at the peak. Borrows ch6/7/8 in their otherwise-idle windows rather
# than inventing a tenth OPLL channel that doesn't exist.
def motif_cell(start):
    return [(start, 1, 'D4'), (start + 1, 0.5, 'F4'), (start + 1.5, 0.5, 'A4'),
            (start + 2, 1, 'G4'), (start + 3, 1, 'F4')]


motif_seed = motif_cell(40)
schedule_notes(7, motif_seed, INS_SYNTH, 11)

motif_bridge = motif_cell(78) + [(82, 1, 'A4'), (83, 1, 'Bb4'), (84, 2, 'A4')]
schedule_notes(6, motif_bridge, INS_CLARINET, 9)

motif_climax = motif_cell(141) + [
    (145, 1, 'A4'), (146, 1, 'Bb4'), (147, 1, 'A4'), (148, 1, 'G4'), (149, 3, 'F4'),
]
schedule_notes(8, motif_climax, INS_TRUMPET, 3)

# --- theremin (ch6): sparse accents across the whole arc, never continuous ---
add(la(0), opll_instrument(6, INS_CLARINET, 5))
glide(6, note_hz('F3'), note_hz('A4'), la(29.5), la(30.7), 16)
glide(6, note_hz('A4'), note_hz('C#4'), la(30.7), la(31.5), 8)
add(la(31.5), opll_note_off(6, note_hz('C#4')))

glide(6, note_hz('A3'), note_hz('D5'), la(68), la(69.5), 16)
glide(6, note_hz('D5'), note_hz('A4'), la(69.5), la(70.5), 8)
add(la(70.5), opll_note_off(6, note_hz('A4')))

add(la(96), opll_instrument(6, INS_CLARINET, 6))
glide(6, note_hz('C4'), note_hz('G5'), la(96), la(97.5), 16)
glide(6, note_hz('G5'), note_hz('D5'), la(97.5), la(98.7), 8)
add(la(98.7), opll_note_off(6, note_hz('D5')))

glide(6, note_hz('F3'), note_hz('A4'), la(128), la(129.5), 16)
glide(6, note_hz('A4'), note_hz('D4'), la(129.5), la(130.5), 8)
add(la(130.5), opll_note_off(6, note_hz('D4')))

add(la(150), opll_instrument(6, INS_CLARINET, 3))
glide(6, note_hz('A3'), note_hz('D5'), la(150), la(152), 20)
glide(6, note_hz('D5'), note_hz('A5'), la(152), la(153.5), 10)
glide(6, note_hz('A5'), note_hz('F4'), la(153.5), la(155.5), 12)
add(la(155.5), opll_note_off(6, note_hz('F4')))

add(la(174), opll_instrument(6, INS_CLARINET, 8))
glide(6, note_hz('D4'), note_hz('A3'), la(174), la(175.5), 10)
glide(6, note_hz('A3'), note_hz('F3'), la(175.5), la(177), 8)
add(la(177), opll_note_off(6, note_hz('F3')))

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
events.sort(key=lambda e: e[0])
stream = bytearray()
current_time = 0
loop_anchor_offset = None


def emit_wait(delta):
    while delta > 0:
        chunk = min(delta, 65535)
        stream.extend(bytes([0x61]) + struct.pack('<H', chunk))
        delta -= chunk


for time_s, data in events:
    if time_s > current_time:
        emit_wait(time_s - current_time)
        current_time = time_s
    if time_s == LOOP_ANCHOR_TIME and loop_anchor_offset is None:
        loop_anchor_offset = len(stream)
    stream.extend(data)

if END_TIME > current_time:
    emit_wait(END_TIME - current_time)
stream.extend(bytes([0x66]))
assert loop_anchor_offset is not None

HEADER_SIZE = 0x100
total_samples = END_TIME
loop_samples = END_TIME - LOOP_ANCHOR_TIME
loop_offset_field = (HEADER_SIZE + loop_anchor_offset) - 0x1C
eof_offset_field = (HEADER_SIZE + len(stream)) - 0x04

header = bytearray(HEADER_SIZE)
header[0x00:0x04] = b'Vgm '
struct.pack_into('<I', header, 0x04, eof_offset_field)
struct.pack_into('<I', header, 0x08, 0x151)
struct.pack_into('<I', header, 0x0C, SN_CLOCK)
struct.pack_into('<I', header, 0x10, OPLL_CLOCK)
struct.pack_into('<I', header, 0x14, 0)
struct.pack_into('<I', header, 0x18, total_samples)
struct.pack_into('<I', header, 0x1C, loop_offset_field)
struct.pack_into('<I', header, 0x20, loop_samples)
struct.pack_into('<I', header, 0x24, 60)
struct.pack_into('<H', header, 0x28, 0x0009)
header[0x2A] = 15
header[0x2B] = 0
struct.pack_into('<I', header, 0x34, HEADER_SIZE - 0x34)

out_path = os.path.join(os.path.dirname(__file__), '..', 'assets', 'vgm', 'main_theme.vgm')
with open(out_path, 'wb') as f:
    f.write(header)
    f.write(stream)

print(f"wrote {out_path}")
print(f"  command stream: {len(stream)} bytes")
print(f"  total duration: {total_samples/SAMPLE_RATE:.2f}s, loop body: {loop_samples/SAMPLE_RATE:.2f}s")
print(f"  loop anchor: stream offset 0x{loop_anchor_offset:X}")
