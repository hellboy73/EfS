#!/usr/bin/env python3
"""vgm_title_theme_dynamic_gen.py — generate a title-theme candidate,
assets/vgm/tmp/efs_title_theme_dynamic_sketch.vgm.

2026-09-23 feedback, pass 1: a first try (straight D major, walking oom-pah
bass, fast bright harpsichord comping, Organ melody, cheerful Trumpet
fanfare) came back "brzmi jakoś tak prosto i dziecinnie... przypomina muzykę
cyrkową" (sounds simple and childish, reminds me of circus music) — also
"dobór instrumentów też wymaga uzupełnienia o ciekawsze brzmienia" (the
instrument choice needs more interesting timbres) — and "spróbuj jeszcze raz
zupełnie od nowa" (try again, completely from scratch). This is that rewrite,
not a patch of pass 1's material.

What actually caused "circus": a symmetric oom-pah bass, fast bright-major
arpeggiated comping, and a plain major-triad tune are literally the carousel/
polka toolkit. Fixed by changing the DEVICE, not just the notes:
  - harmony returns to the sad theme's own D-minor-family progression (Dm -
    Bb - F - C, root/third/fifth) -- same tonal "brzmienie" as the reference
    track, as asked, instead of a plain D major that has none of its colour.
  - the bass is no longer a walking line: it's an asymmetric 5-beat ostinato
    cell (long-long-short-short-long-long), the same DEVICE Holst used in
    "Mars" for driving-but-ominous, on Synth Bass -- a new, more electronic
    timbre than the Acoustic Bass every other cue here already uses. Nothing
    is quoted from Mars; only the idea (an odd, insistent rhythmic cell
    instead of a symmetric march bass) is borrowed, same as this project's
    existing Holst-inspired cues already do.
  - the melody (Horn, another unused timbre -- moodier and rounder than
    Organ/Trumpet) is syncopated and leaves rests to breathe, in D natural
    minor with one chromatic raised-7th (C#) tension note, not a straight
    major run.
  - comping moves from bright plucked Harpsichord to Electric Guitar --
    another unused YM2413 timbre -- landing deliberately OFF the ostinato's
    own accents, so the two rhythms cross instead of locking into one
    predictable oom-pah pulse.
  - Trumpet no longer plays a cheerful fanfare arpeggio; it lands two-note
    unison punches (root+fifth) at the chord pivots only -- weight, not
    cheer.
  - a new Violin voice (also unused so far) holds a very quiet, sparse high
    sustained tone through the middle of the loop -- a thin, cold backdrop,
    not a melodic voice.
  - the clock tick moves off a steady eighth pulse (that pulse IS the polka
    feel) onto only the ostinato cell's four "long" hits -- an irregular,
    tense count instead of a metronome.
  - the theremin (Clarinet glide) is now three short (~1s) swoops spread
    across the loop at the harmony's own chord changes, instead of one long
    swoop boxed into a single quarantined "mystery bar" -- so the unease
    threads through the whole piece rather than visiting once.

Same two chips as every other cue (SN76489 + YM2413), same D tonal centre as
efs_title_theme_sketch_rearranged10.vgm.

Form: 40-beat loop (8 ostinato cells), one chord per 2 cells --
Dm(0-9) - Bb(10-19) - F(20-29) - C(30-39) -- then back to Dm at the loop seam.

Channel map:
  ch0 Violin        - sparse, very quiet sustained high pad, middle of loop
  ch1 Synth Bass    - the 5-beat asymmetric ostinato, root of the current chord
  ch2 Electric Guitar - off-ostinato syncopated stabs, chord's fifth
  ch3 Vibraphone    - one soft low accent per chord change, distant not bright
  ch4 Horn          - the melody: syncopated, minor-mode, rests to breathe
  ch5 Oboe          - sustained harmony (chord's third), retriggered at
                      mid-chord so the ROM envelope doesn't decay to nothing
  ch6 Clarinet      - the theremin: three short glides, at the chord changes
  ch7 Synthesizer   - sparse isolated high "alien" blips, not a running arp
  ch8 Trumpet       - two-note unison punches (root+fifth) at chord pivots
PSG: noise channel ticks only on the ostinato's 4 long hits per cell (an
irregular count, not a steady pulse); no PSG tone-channel fills this pass --
that device read as a toy-ish blip and isn't needed here.

Usage: python vgm_title_theme_dynamic_gen.py
"""
import struct
import os

SN_CLOCK = 3579545
OPLL_CLOCK = 3579545
SAMPLE_RATE = 44100
BEAT = 0.38  # seconds per beat unit

INS_VIOLIN, INS_OBOE, INS_TRUMPET, INS_HORN = 1, 6, 7, 9
INS_SYNTH, INS_VIBRAPHONE, INS_SYNTH_BASS, INS_ELECTRIC_GUITAR = 10, 12, 13, 15
INS_CLARINET = 5

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


def opll_write(addr, val):
    return bytes([0x51, addr & 0xFF, val & 0xFF])


def sn_atten_write(channel, atten):
    return bytes([0x50, 0x80 | ((channel * 2 + 1) << 4) | (atten & 0xF)])


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


def glide(ch, f_start, f_end, t_start, t_end, steps):
    for k in range(steps + 1):
        frac = k / steps
        f = f_start * (f_end / f_start) ** frac
        tt = round(t_start + frac * (t_end - t_start))
        add(tt, opll_note_on(ch, f) if k == 0 else opll_retrigger(ch, f))


# ---------------------------------------------------------------------------
# Harmony: the sad theme's own D-minor-family progression, root/third/fifth.
# ---------------------------------------------------------------------------
CHORDS = [('D2', 'F3', 'A3'), ('A#2', 'D3', 'F3'), ('F2', 'A3', 'C4'), ('C2', 'E3', 'G3')]
CHORD_BEATS = 10  # 2 ostinato cells per chord
LOOP_END_BEAT = 40
END_TIME = la(LOOP_END_BEAT)
LOOP_ANCHOR_TIME = la(0)

# --- an asymmetric 5-beat ostinato cell: long-long-short-short-long-long ---
CELL_HITS = [0, 1, 2, 2.5, 3, 4]   # offsets within a 5-beat cell
CELL_LONG_HITS = [0, 2, 3, 4]      # the four "long" onsets -- where the tick lands

# --- straight in, no tolling intro -- energy from the first ostinato hit ---
add(t(0), opll_write(0x0E, 0x00))
add(t(0), sn_noise_control(fb=0, shift_rate=1))
add(t(0), sn_atten_write(3, 15))

# --- bass ostinato + irregular tick, root of whichever chord is current ---
add(la(0), opll_instrument(1, INS_SYNTH_BASS, 8))
beat = 0.0
chord_i = 0
while beat < LOOP_END_BEAT:
    chord_i = int(beat // CHORD_BEATS) % len(CHORDS)
    root = CHORDS[chord_i][0]
    for h in CELL_HITS:
        pos = beat + h
        if pos >= LOOP_END_BEAT:
            break
        add(la(pos), opll_retrigger(1, note_hz(root)))
        if h in CELL_LONG_HITS:
            on_t = la(pos)
            off_t = on_t + round(0.08 * SAMPLE_RATE)
            add(on_t, sn_atten_write(3, 11))
            add(off_t, sn_atten_write(3, 15))
    beat += 5

# --- electric guitar: syncopated stabs deliberately OFF the ostinato's own
# accents (offsets 1.5 / 3.5 within the cell), chord's fifth ---
add(la(1.5), opll_instrument(2, INS_ELECTRIC_GUITAR, 9))
beat = 0.0
while beat < LOOP_END_BEAT:
    chord_i = int(beat // CHORD_BEATS) % len(CHORDS)
    fifth = CHORDS[chord_i][2]
    for off in (1.5, 3.5):
        pos = beat + off
        if pos < LOOP_END_BEAT:
            add(la(pos), opll_retrigger(2, note_hz(fifth)))
    beat += 5

# --- vibraphone: one soft, low, distant accent per chord change ---
add(la(0), opll_instrument(3, INS_VIBRAPHONE, 6))
for cb in range(0, LOOP_END_BEAT, CHORD_BEATS):
    chord_i = (cb // CHORD_BEATS) % len(CHORDS)
    add(la(cb), opll_retrigger(3, note_hz(CHORDS[chord_i][0].replace('2', '3'))))
    add(la(cb + 3), opll_note_off(3, note_hz(CHORDS[chord_i][0].replace('2', '3'))))

# --- melody (Horn): syncopated, D natural minor with one raised-7th (C#)
# tension note, rests to breathe -- deliberately not a symmetric major tune ---
melody = [
    (5, 1.5, 'D4'), (7, 1, 'F4'), (8.5, 1.5, 'G4'), (10.5, 1, None),
    (12, 1.5, 'A4'), (14, 1, 'G4'), (15, 2, 'F4'), (17.5, 1, None),
    (19, 1.5, 'C5'), (21, 1, 'Bb4'), (22.5, 1.5, 'A4'), (24.5, 1, None),
    (26, 1.5, 'F4'), (28, 1, 'E4'), (29, 2, 'D4'), (31.5, 1, None),
    (33, 1.5, 'A4'), (35, 1, 'C#5'), (36.5, 1.5, 'D5'), (38.5, 1.5, 'C5'),
]
schedule_notes(4, melody, INS_HORN, 7)

# --- oboe: sustained harmony (chord's third), retriggered mid-chord ---
add(la(0), opll_instrument(5, INS_OBOE, 6))
for cb in range(0, LOOP_END_BEAT, CHORD_BEATS):
    chord_i = (cb // CHORD_BEATS) % len(CHORDS)
    third = CHORDS[chord_i][1]
    add(la(cb), opll_retrigger(5, note_hz(third)))
    add(la(cb + CHORD_BEATS / 2), opll_retrigger(5, note_hz(third)))
    add(la(cb + CHORD_BEATS - 0.5), opll_note_off(5, note_hz(third)))

# --- trumpet: two-note unison punches (root+fifth) at chord pivots, weight
# rather than a cheerful fanfare run ---
add(la(0), opll_instrument(8, INS_TRUMPET, 8))
for cb in (10, 20, 30):
    chord_i = (cb // CHORD_BEATS) % len(CHORDS)
    root, _, fifth = CHORDS[chord_i]
    add(la(cb), opll_retrigger(8, note_hz(root.replace('2', '3'))))
    add(la(cb + 0.8), opll_note_off(8, note_hz(root.replace('2', '3'))))
    add(la(cb + 1), opll_retrigger(8, note_hz(fifth)))
    add(la(cb + 1.8), opll_note_off(8, note_hz(fifth)))

# --- synthesizer: sparse, isolated "alien" blips, not a running arpeggio ---
add(la(0), opll_instrument(7, INS_SYNTH, 3))
for pos, name in [(15.5, 'D6'), (25.5, 'C6'), (37, 'A5')]:
    add(la(pos), opll_retrigger(7, note_hz(name)))
    add(la(pos + 0.4), opll_note_off(7, note_hz(name)))

# --- violin: a very quiet, thin sustained pad through the middle of the
# loop -- a cold backdrop, not a melodic voice ---
add(la(18), opll_instrument(0, INS_VIOLIN, 2))
add(la(18), opll_note_on(0, note_hz('A5')))
for pos in (22, 26):
    add(la(pos), opll_retrigger(0, note_hz('A5')))
add(la(30), opll_note_off(0, note_hz('A5')))

# --- theremin (Clarinet): three short (~1s) swoops at the chord changes,
# threaded through the piece instead of boxed into one bar ---
add(la(0), opll_instrument(6, INS_CLARINET, 9))
glide(6, note_hz('D3'), note_hz('A4'), la(9.5), la(10), 8)
add(la(10.3), opll_note_off(6, note_hz('A4')))

glide(6, note_hz('F3'), note_hz('C#5'), la(19.5), la(20.2), 10)
add(la(20.5), opll_note_off(6, note_hz('C#5')))

glide(6, note_hz('A3'), note_hz('E5'), la(38.7), la(39.5), 10)
add(la(39.5), opll_note_off(6, note_hz('E5')))

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


def build_gd3(fields):
    body = ("\x00".join(fields) + "\x00").encode("utf-16-le")
    header = b"Gd3 " + struct.pack("<II", 0x100, len(body))
    return header + body


gd3 = build_gd3([
    "Escape from Saturn -- Title Theme (mystery/dynamic candidate, pass 2)",
    "",
    "Escape from Saturn",
    "",
    "MAD-65",
    "",
    "Claude Code, for Mateusz",
    "",
    "2026-09-23",
    "vgm_title_theme_dynamic_gen.py",
    "Complete rewrite of pass 1, which read as childish/circus music. Returns "
    "to the sad theme's own D-minor-family harmony (Dm-Bb-F-C); replaces the "
    "symmetric oom-pah bass with a Holst-'Mars'-style asymmetric 5-beat "
    "ostinato on Synth Bass; melody moves to Horn, syncopated, minor-mode; "
    "comping moves to Electric Guitar, deliberately off the ostinato's own "
    "accents; adds a sparse Violin pad; three short theremin swoops threaded "
    "through the chord changes instead of boxed into one section.",
])

header = bytearray(HEADER_SIZE)
header[0x00:0x04] = b'Vgm '
struct.pack_into('<I', header, 0x04, eof_offset_field)
struct.pack_into('<I', header, 0x08, 0x151)
struct.pack_into('<I', header, 0x0C, SN_CLOCK)
struct.pack_into('<I', header, 0x10, OPLL_CLOCK)
gd3_offset_field = len(stream) - 0x14 + HEADER_SIZE
struct.pack_into('<I', header, 0x14, gd3_offset_field)
struct.pack_into('<I', header, 0x18, total_samples)
struct.pack_into('<I', header, 0x1C, loop_offset_field)
struct.pack_into('<I', header, 0x20, loop_samples)
struct.pack_into('<I', header, 0x24, 60)
struct.pack_into('<H', header, 0x28, 0x0009)
header[0x2A] = 15
header[0x2B] = 0
struct.pack_into('<I', header, 0x34, HEADER_SIZE - 0x34)

out_dir = os.path.join(os.path.dirname(__file__), '..', 'assets', 'vgm', 'tmp')
os.makedirs(out_dir, exist_ok=True)
out_path = os.path.join(out_dir, 'efs_title_theme_dynamic_sketch.vgm')
with open(out_path, 'wb') as f:
    f.write(header)
    f.write(stream)
    f.write(gd3)

print(f"wrote {out_path}")
print(f"  command stream: {len(stream)} bytes")
print(f"  total duration: {total_samples/SAMPLE_RATE:.2f}s, loop body: {loop_samples/SAMPLE_RATE:.2f}s")
print(f"  loop anchor: stream offset 0x{loop_anchor_offset:X}")
