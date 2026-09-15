#!/usr/bin/env python3
"""vgm_intro_gen.py — generate assets/vgm/title_intro.vgm, a title-screen cue
inspired by the slow, tolling character of Holst's "Saturn" (not a
transcription of it — an original cue built on the same idea: a low pedal, a
gong strike marking structure, a hypnotic-but-evolving ostinato, and sparse
pitch-glide "UFO" accents rather than a continuous theremin).

v2 (2026-09-14 feedback): the repeating ostinato was on raw SN76489 square —
sounded thin/harsh. Moved it to an OPLL voice (Harpsichord — a plucked FM
timbre actually suits a "clockwork" ostinato). SN76489 is now used only for a
soft noise-channel "tick" texture, not melodic content. Also: more channels
(8 of OPLL's 9), a four-section form (A/B/C/D) so the piece develops instead
of looping one 12-note phrase, and a substantially longer loop body.

Targets exactly what the OS's stripped-stream VGM player understands
(tools/vgmstrip.py's SUPPORTED_* sets): SN76489 write (0x50), YM2413 write
(0x51), and sample waits (0x61/0x66). Chip clocks (3,579,545 Hz for both)
match assets/vgm/song.vgm and design_technical.md's "2x SN76489 + YM2413".

The gong (first strike) and the bass pedal's key-on happen ONCE, before the
loop anchor, so neither re-triggers on repeat.

Run directly: writes assets/vgm/title_intro.vgm.
"""
import struct
import os

SN_CLOCK = 3579545
OPLL_CLOCK = 3579545
SAMPLE_RATE = 44100
BEAT = 1.5  # seconds — slow, Adagio

# YM2413 ROM instrument numbers (1-15; 0 is the user-programmable custom slot,
# left unused so nothing needs hand-tuned operator registers).
INS_TRUMPET = 7
INS_ORGAN = 8
INS_SYNTH = 10
INS_HARPSICHORD = 11
INS_VIBRAPHONE = 12
INS_ACOUSTIC_BASS = 14

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


def la(beat):  # loop-relative time: beat 0 == the loop anchor (absolute beat 1)
    return t(1 + beat)


def opll_fnum_block(freq, clock=OPLL_CLOCK):
    # Fnum = Freq * 2^(19-Block) * 72 / Clock ; pick the smallest Block that
    # keeps Fnum within the 9-bit register (0-511) -- maximises precision.
    for block in range(8):
        fnum = round(freq * (2 ** (19 - block)) * 72 / clock)
        if 0 <= fnum <= 511:
            return fnum, block
    return 511, 7


def sn_divisor(freq, clock=SN_CLOCK):
    n = round(clock / (32.0 * freq))
    return max(1, min(1023, n))


def opll_write(addr, val):
    return bytes([0x51, addr & 0xFF, val & 0xFF])


def sn_atten_write(channel, atten):  # channel 0-2 = tone, 3 = noise
    reg = channel * 2 + 1
    b1 = 0x80 | (reg << 4) | (atten & 0xF)
    return bytes([0x50, b1])


def sn_tone_write(channel, freq):  # channel 0-2 only
    n = sn_divisor(freq)
    reg = channel * 2
    b1 = 0x80 | (reg << 4) | (n & 0xF)
    b2 = (n >> 4) & 0x3F
    return bytes([0x50, b1, 0x50, b2])


def sn_noise_control(fb, shift_rate):
    val = ((1 if fb else 0) << 2) | (shift_rate & 0x3)
    b1 = 0x80 | (6 << 4) | (val & 0xF)
    return bytes([0x50, b1])


def opll_instrument(ch, instrument, volume):
    return opll_write(0x30 + ch, ((instrument & 0xF) << 4) | (volume & 0xF))


def opll_note_on(ch, freq):
    fnum, block = opll_fnum_block(freq)
    return (opll_write(0x10 + ch, fnum & 0xFF) +
            opll_write(0x20 + ch, 0x10 | (block << 1) | ((fnum >> 8) & 1)))


opll_note_update = opll_note_on  # same registers; keeps key-on bit set (glide)


def opll_note_off(ch, freq):
    fnum, block = opll_fnum_block(freq)
    return opll_write(0x20 + ch, (block << 1) | ((fnum >> 8) & 1))


events = []


def add(time_samples, data):
    events.append((time_samples, data))


def schedule_notes(ch, notes, instrument, volume):
    """notes: list of (start_beat, duration_beats, note_name_or_None), loop-relative."""
    add(la(notes[0][0]), opll_instrument(ch, instrument, volume))
    for start, dur, name in notes:
        if name is not None:
            f = note_hz(name)
            add(la(start), opll_note_on(ch, f))
            add(la(start + dur), opll_note_off(ch, f))


def echo_and_fills(echo_ch, beep_channel, notes, instrument_echo, vol_echo):
    """Fills the gaps a bare note-list leaves: a soft trailing echo of every
    played note (on `echo_ch`, an OPLL voice) and, in the actual rests, two
    quiet retro PSG blips (on `beep_channel`, an octave above the note that
    just ended) instead of dead air."""
    add(la(notes[0][0]), opll_instrument(echo_ch, instrument_echo, vol_echo))
    for idx, (start, dur, name) in enumerate(notes):
        if name is not None:
            f = note_hz(name)
            echo_start = start + dur
            echo_dur = min(dur * 0.5, 1.0)
            add(la(echo_start), opll_note_on(echo_ch, f))
            add(la(echo_start + echo_dur), opll_note_off(echo_ch, f))
        else:
            prev_name = next((n for s, d, n in reversed(notes[:idx]) if n is not None), None)
            if prev_name is None:
                continue
            f = note_hz(prev_name) * 2  # an octave up — a "retro beep" register
            for frac in (0.25, 0.6):
                bt = start + dur * frac
                on_t = la(bt)
                off_t = on_t + round(0.09 * SAMPLE_RATE)
                add(on_t, sn_tone_write(1, f))
                add(on_t, sn_atten_write(1, 12))  # heavily quieted, per spec
                add(off_t, sn_atten_write(1, 15))


def ostinato_section(ch, pattern, start_rel, end_rel, step, instrument, volume):
    add(la(start_rel), opll_instrument(ch, instrument, volume))
    beat, i = start_rel, 0
    while beat < end_rel:
        add(la(beat), opll_note_on(ch, note_hz(pattern[i % len(pattern)])))
        i += 1
        beat += step


def sparkle_section(ch, pattern, start_rel, end_rel, step, gate, instrument, volume):
    add(la(start_rel), opll_instrument(ch, instrument, volume))
    beat, i = start_rel, 0
    while beat < end_rel:
        f = note_hz(pattern[i % len(pattern)])
        add(la(beat), opll_note_on(ch, f))
        add(la(beat + step * gate), opll_note_off(ch, f))
        i += 1
        beat += step


def fanfare(ch, notes, start_rel, note_step, instrument, volume):
    add(la(start_rel), opll_instrument(ch, instrument, volume))
    for i, name in enumerate(notes):
        f = note_hz(name)
        s = start_rel + i * note_step
        add(la(s), opll_note_on(ch, f))
        add(la(s + note_step * 0.8), opll_note_off(ch, f))


def glide(ch, f_start, f_end, t_start, t_end, steps):
    for k in range(steps + 1):
        frac = k / steps
        f = f_start * (f_end / f_start) ** frac
        tt = round(t_start + frac * (t_end - t_start))
        add(tt, (opll_note_on if k == 0 else opll_note_update)(ch, f))


def gong_hit(time_abs, volume, ring_beats=0.9):
    add(time_abs, opll_instrument(3, INS_VIBRAPHONE, volume))
    add(time_abs, opll_note_on(3, note_hz('A2')))
    add(time_abs + round(ring_beats * BEAT * SAMPLE_RATE), opll_note_off(3, note_hz('A2')))


# ---------------------------------------------------------------------------
# Form: Intro (one-shot) | A (0-17) | B (17-41) | C climax (41-59) | D tail (59-71)
# Loop-relative beat 0 == absolute beat 1 == the loop anchor.
# ---------------------------------------------------------------------------
LOOP_END_BEAT = 71
END_TIME = la(LOOP_END_BEAT)
LOOP_ANCHOR_TIME = la(0)

# --- Intro: gong + bass pedal, one-shot, before the loop anchor ---
add(t(0), opll_write(0x0E, 0x00))  # rhythm mode off
add(t(0), opll_instrument(1, INS_ACOUSTIC_BASS, 5))
add(t(0), opll_note_on(1, note_hz('D2')))  # held forever, no keyoff
add(t(0), sn_noise_control(fb=0, shift_rate=1))  # periodic, not white -- a soft
                                                  # tonal "tock" instead of a hiss
add(t(0), sn_atten_write(1, 15))  # beep channel: silent until the first fill
gong_hit(t(0), volume=4)

# --- The clock: a soft noise-channel tick, once a beat, whole piece ---
for beat in range(0, LOOP_END_BEAT + 1):
    on_time = t(beat)
    off_time = on_time + round(0.12 * SAMPLE_RATE)
    atten = 9 if 41 <= beat - 1 < 59 else 11  # a touch louder through the climax
    add(on_time, sn_atten_write(3, atten))
    add(off_time, sn_atten_write(3, 15))

# --- Ostinato (ch2, Harpsichord) — evolves per section instead of repeating ---
ostinato_section(2, ['D3', 'C#3'], 0, 17, 1, INS_HARPSICHORD, 8)
ostinato_section(2, ['E3', 'D3', 'F3', 'D3'], 17, 41, 1, INS_HARPSICHORD, 7)
ostinato_section(2, ['A3', 'G3', 'F3', 'G3'], 41, 59, 0.5, INS_HARPSICHORD, 5)
ostinato_section(2, ['D3', 'C#3'], 59, LOOP_END_BEAT, 1, INS_HARPSICHORD, 8)

# --- Gong hits at the two section pivots ---
gong_hit(la(17), volume=3)
gong_hit(la(41), volume=2)

# --- Fanfare (ch8, Trumpet) — a brief herald at the same two pivots ---
fanfare(8, ['D4', 'F4', 'A4'], 17, 0.25, INS_TRUMPET, 6)
fanfare(8, ['D4', 'F4', 'A4'], 41, 0.25, INS_TRUMPET, 6)

# --- Melody (ch4, Organ) — four distinct phrases, one per section, each
#     trailed by a soft echo (ch0, Flute) and PSG "beep" fills in its rests ---
melody_a = [
    (1, 2, 'A3'), (3, 1, None), (4, 2, 'G3'), (6, 1, 'F3'), (7, 2, 'E3'),
    (9, 1, None), (10, 3, 'D4'), (13, 1, None), (14, 2, 'A3'),
]
melody_b = [
    (17, 2, 'F4'), (19, 2, 'E4'), (21, 1, None), (22, 2, 'D4'), (24, 2, 'C4'),
    (26, 1, 'B3'), (27, 2, 'A3'), (29, 1, None), (30, 3, 'F4'), (33, 1, None),
    (34, 2, 'D4'), (36, 2, 'A3'), (38, 2, 'F3'),
]
melody_c = [
    (41, 2, 'A4'), (43, 2, 'G4'), (45, 1, 'F4'), (46, 2, 'E4'), (48, 1, None),
    (49, 3, 'D5'), (52, 1, None), (53, 2, 'A4'), (55, 2, 'F4'), (57, 1, 'D4'),
]
melody_d = [
    (59, 3, 'A3'), (62, 1, None), (63, 3, 'F3'), (66, 1, None), (67, 3, 'D3'),
]

schedule_notes(4, melody_a, INS_ORGAN, 6)
schedule_notes(4, melody_b, INS_ORGAN, 6)
schedule_notes(4, melody_c, INS_ORGAN, 4)  # climax: louder
schedule_notes(4, melody_d, INS_ORGAN, 8)  # tail: fading

for section in (melody_a, melody_b, melody_c, melody_d):
    echo_and_fills(0, 1, section, 4, 10)  # ch0 Flute, quiet, one octave of "air"

# --- Harmony (ch5, Oboe) — enters for the development and climax only ---
schedule_notes(5, [
    (17, 4, 'D4'), (22, 4, 'A3'), (27, 3, 'F3'), (30, 4, 'A3'), (34, 4, 'F3'),
], 6, 6)  # Oboe = 6
schedule_notes(5, [
    (41, 4, 'D4'), (46, 3, 'A3'), (49, 4, 'F4'), (53, 4, 'D4'),
], 6, 5)  # louder at the climax

# --- Sparkle (ch7, Synthesizer) — a soft high arpeggio, climax only ---
sparkle_section(7, ['D5', 'A4', 'F4', 'A4'], 41, 59, 0.5, 0.8, INS_SYNTH, 8)

# --- Theremin-style glides (ch6, Clarinet) — three brief accents, never continuous ---
add(la(0), opll_instrument(6, 5, 5))  # Clarinet, set once, silent until first glide
glide(6, note_hz('F3'), note_hz('A4'), la(20.5), la(21.7), 16)
glide(6, note_hz('A4'), note_hz('C#4'), la(21.7), la(22.5), 8)
add(la(22.5), opll_note_off(6, note_hz('C#4')))

glide(6, note_hz('A3'), note_hz('D5'), la(52), la(53.5), 16)
glide(6, note_hz('D5'), note_hz('A4'), la(53.5), la(54.5), 8)
add(la(54.5), opll_note_off(6, note_hz('A4')))

add(la(65), opll_instrument(6, 5, 7))  # softer: a receding accent for the tail
glide(6, note_hz('D4'), note_hz('A3'), la(65), la(66.2), 12)
glide(6, note_hz('A3'), note_hz('F3'), la(66.2), la(67), 6)
add(la(67), opll_note_off(6, note_hz('F3')))

# ---------------------------------------------------------------------------
# Emit: merge events in time order into wait/command stream.
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

# ---------------------------------------------------------------------------
# VGM v1.51 header, 256 bytes, matching assets/vgm/song.vgm's layout.
# ---------------------------------------------------------------------------
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
struct.pack_into('<I', header, 0x14, 0)  # no GD3 tag
struct.pack_into('<I', header, 0x18, total_samples)
struct.pack_into('<I', header, 0x1C, loop_offset_field)
struct.pack_into('<I', header, 0x20, loop_samples)
struct.pack_into('<I', header, 0x24, 60)
struct.pack_into('<H', header, 0x28, 0x0009)  # SN76489 feedback
header[0x2A] = 15  # shift register width
header[0x2B] = 0
struct.pack_into('<I', header, 0x34, HEADER_SIZE - 0x34)  # VGM data offset

out_path = os.path.join(os.path.dirname(__file__), '..', 'assets', 'vgm', 'title_intro.vgm')
with open(out_path, 'wb') as f:
    f.write(header)
    f.write(stream)

print(f"wrote {out_path}")
print(f"  command stream: {len(stream)} bytes")
print(f"  total duration: {total_samples/SAMPLE_RATE:.2f}s, loop body: {loop_samples/SAMPLE_RATE:.2f}s")
print(f"  loop anchor: file offset 0x{HEADER_SIZE+loop_anchor_offset:X} "
      f"(stream offset 0x{loop_anchor_offset:X})")
