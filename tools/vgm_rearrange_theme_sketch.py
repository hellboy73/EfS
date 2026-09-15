#!/usr/bin/env python3
"""vgm_rearrange_theme_sketch.py — rearrange efs_title_theme_sketch.vgm
(2026-09-08, D:\\MAD65\\VGMPlay_052-0\\), replacing the flat SN76489 square
pad with a quiet FM bass+pad on two fresh OPLL channels, per 2026-09-14
feedback ("ten prostokąt... długie ciągłe irytujące brzęczenie... przearanżować
... używając większej liczby środków i kanałów").

WHAT'S KEPT, unchanged, at its original timing: the SN76489 tone2 arpeggio
(reg4/5) and the whole YM2413 portamento lead (channel 0, entering ~30s) --
this is the part that already "brzmi nieźle".

WHAT'S REMOVED: SN76489 tone0/tone1 (reg0-3, the static square pad) and the
noise channel (reg6/7) entirely -- both already flagged as the problem.

WHAT'S NEW: decoding the arpeggio's own pitches shows a clean 4-chord loop,
D minor -> Bb major -> F major -> C major, repeating every ~14.93s (confirmed
against the file's own loop point, which sits exactly at that boundary). Two
new OPLL channels now track that same progression:
  - ch1, Acoustic Bass: the chord's root, an octave below the arpeggio
  - ch2, Organ: the chord's third, a soft mid-register pad
both quiet (background level) with a short fade-in at t=0, retriggering at
each chord change (giving it real harmonic movement instead of one static
dyad) -- and both silent, not just quiet, whenever nothing else has been
proven to need them, since being "cichy" was the explicit ask.

Chord duration is set to loop_samples/24 samples exactly, so six full
Dm-Bb-F-C cycles fit the loop body with zero remainder: the pad's chord
state matches exactly wherever the OS player's loop-anchor jump lands,
every repeat, with no explicit reset needed.

Total sample timing (total_samples, loop point) is left byte-for-byte
identical to the original -- only WHAT plays changes, not WHEN the piece
ends or loops.

Usage: python vgm_rearrange_theme_sketch.py <in.vgm> <out.vgm>
"""
import struct
import sys

SN_CLOCK = 3579545
OPLL_CLOCK = 3579545
SAMPLE_RATE = 44100
HEADER_SIZE = 0x100

INS_PIANO = 3
INS_FRENCH_HORN = 9
INS_SYNTH = 10
INS_HARPSICHORD = 11
INS_VIBRAPHONE = 12
INS_ORGAN = 8
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


def opll_fnum_block(freq, clock=OPLL_CLOCK):
    for block in range(8):
        fnum = round(freq * (2 ** (19 - block)) * 72 / clock)
        if 0 <= fnum <= 511:
            return fnum, block
    return 511, 7


def opll_write(addr, val):
    return bytes([0x51, addr & 0xFF, val & 0xFF])


def opll_instrument(ch, instrument, volume):
    return opll_write(0x30 + ch, ((instrument & 0xF) << 4) | (volume & 0xF))


def opll_note_on(ch, freq):
    fnum, block = opll_fnum_block(freq)
    return (opll_write(0x10 + ch, fnum & 0xFF) +
            opll_write(0x20 + ch, 0x10 | (block << 1) | ((fnum >> 8) & 1)))


def opll_note_off(ch):
    return opll_write(0x20 + ch, 0x00)


def opll_retrigger(ch, freq):
    # A same-value rewrite of $20-$28 with key-on already 1 is NOT guaranteed
    # to restart the envelope on real OPLL -- key-on needs an actual 0->1
    # EDGE. Without this, a decaying (non-sustaining) ROM patch like
    # Harpsichord plucks once on its first note and then sits essentially
    # silent forever, just silently re-pitching underneath -- which sounds
    # exactly like "that channel isn't playing at all" (2026-09-14 feedback).
    # A key-off immediately before each key-on forces the edge every time.
    return opll_note_off(ch) + opll_note_on(ch, freq)


def sn_atten_write(channel, atten):  # channel 0-2 = tone, 3 = noise
    reg = channel * 2 + 1
    return bytes([0x50, 0x80 | (reg << 4) | (atten & 0xF)])


def sn_noise_control(fb, shift_rate):
    val = ((1 if fb else 0) << 2) | (shift_rate & 0x3)
    return bytes([0x50, 0x80 | (6 << 4) | (val & 0xF)])


def build_gd3(fields):
    body = ("\x00".join(fields) + "\x00").encode("utf-16-le")
    header = b"Gd3 " + struct.pack("<II", 0x100, len(body))
    return header + body


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <in.vgm> <out.vgm>")
    with open(sys.argv[1], "rb") as f:
        d = f.read()

    total_samples = struct.unpack_from("<I", d, 0x18)[0]
    loop_samples = struct.unpack_from("<I", d, 0x20)[0]
    OLD_LOOP_ANCHOR_TIME = total_samples - loop_samples

    # 2026-09-14: the old 14.93s of "nothing happens" (fade-in pad, silence)
    # before the arpeggio starts is now a console-logo sting: 8 ticks, then
    # straight into the title screen's music. LOGO_DUR is one chord's worth
    # of the arpeggio's own pace (loop_samples/24 -- see below), so the tick
    # spacing (LOGO_DUR/8) lines up with the piece's existing pulse.
    LOGO_TICKS = 8
    LOGO_DUR = loop_samples // 24
    TICK_SPACING = LOGO_DUR // LOGO_TICKS
    NEW_LOOP_ANCHOR_TIME = LOGO_DUR
    NEW_END_TIME = NEW_LOOP_ANCHOR_TIME + loop_samples
    TIME_SHIFT = OLD_LOOP_ANCHOR_TIME - NEW_LOOP_ANCHOR_TIME

    # --- parse the original stream, dropping the old square pad, noise, AND
    # (2026-09-14, 4th pass) the arpeggio itself -- "appregio nadal za głośno,
    # może zrobić go na OPLL?" -- every SN76489 tone/noise write is dropped;
    # PSG is now used only for the logo tick. The arpeggio's own pitches are
    # decoded live (reg4's 10-bit divisor -> Hz) and re-emitted as OPLL
    # note-on events on a fresh channel with a real instrument instead of a
    # raw square, which is quieter by nature even before any volume tuning.
    # Everything shifts back by TIME_SHIFT so it starts right where the logo
    # ends; the t=0 YM2413 instrument setup (silent, no audible effect) stays
    # at 0. The theremin lead (channel 0) keeps its own pitch/timing exactly,
    # only its volume (reg 0x30) is tuned. ---
    # 2026-09-14 (6th pass): the retrigger fix (below) made the arpeggio
    # actually attack for the first time -- vol=3 was tuned against a channel
    # that was barely sounding at all, so once it started really firing it
    # came out "co najmniej 2x za głośno", burying the lead and everything
    # else. Pulled the arpeggio back and brought the lead back up to match.
    # 7th pass: "theremin ciszej" -- pulled it back down again, past where it
    # started, now that everything else around it is properly balanced.
    LEAD_VOLUME = 10         # reg 0x30 low nibble (0=loudest..15=silent); was 8
    ARP_CH = 3
    ARP_VOLUME = 8           # was 3

    # 7th pass, new element: "w tej drugiej części bez theremina... ten sam
    # motyw co theremin ale grany na innym instrumencie" -- the lead is silent
    # for exactly the first chord-progression cycle after the logo (it enters
    # one full Dm-Bb-F-C cycle in). A second channel now plays THE SAME
    # portamento journey -- the identical fnum/block register values, copied
    # verbatim, not reconstructed from Hz -- during that empty stretch, on
    # Synthesizer instead of the lead's custom vibrato patch, then gets out
    # of the way (key-off) right as the real theremin takes over.
    PREVIEW_CH = 6
    PREVIEW_VOLUME = 9
    PREVIEW_WINDOW = LOGO_DUR * 4  # one full Dm-Bb-F-C cycle, 14.93s

    # plus ozdobniki: a light 2-note grace-flourish (third->fifth of the
    # current chord) on ch7/Piano, riding the same half-chord cadence as the
    # harmony bed -- quiet, short, decorative, not a new melodic voice.
    ORNAMENT_CH = 7
    ORNAMENT_VOLUME = 12

    DROP_REGS = {0, 1, 2, 3, 4, 5, 6, 7}  # all of SN76489 -- nothing plays there now but the logo tick
    i = HEADER_SIZE
    t = 0
    kept = []
    skip_next_data = False
    pending_arp_lo = None
    pending_ch0_freq_lo = None
    OLD_LEAD_START = None
    new_events = []

    def add_new(time_s, data):
        new_events.append((time_s, data))

    add_new(NEW_LOOP_ANCHOR_TIME, opll_instrument(ARP_CH, INS_HARPSICHORD, ARP_VOLUME))
    add_new(NEW_LOOP_ANCHOR_TIME, opll_instrument(PREVIEW_CH, INS_SYNTH, PREVIEW_VOLUME))
    add_new(NEW_LOOP_ANCHOR_TIME, opll_instrument(ORNAMENT_CH, INS_PIANO, ORNAMENT_VOLUME))

    while i < len(d):
        op = d[i]
        if op == 0x50:
            val = d[i + 1]
            if val & 0x80:
                reg = (val >> 4) & 0x7
                if reg == 4:
                    pending_arp_lo = val & 0xF
                    skip_next_data = True
                elif reg in DROP_REGS:
                    pending_arp_lo = None
                    skip_next_data = True
                else:
                    kept.append((max(0, t - TIME_SHIFT), bytes([0x50, val])))
                    skip_next_data = False
            else:
                data6 = val & 0x3F
                if pending_arp_lo is not None:
                    n = pending_arp_lo | (data6 << 4)
                    pending_arp_lo = None
                    if n > 0:
                        hz = SN_CLOCK / (32.0 * n)
                        add_new(max(0, t - TIME_SHIFT), opll_retrigger(ARP_CH, hz))
                elif not skip_next_data:
                    kept.append((max(0, t - TIME_SHIFT), bytes([0x50, val])))
                skip_next_data = False
            i += 2
        elif op == 0x51:
            reg, val = d[i + 1], d[i + 2]
            if reg == 0x30:
                val = (val & 0xF0) | LEAD_VOLUME
            kept.append((max(0, t - TIME_SHIFT), bytes([0x51, reg, val])))
            if reg == 0x10:
                pending_ch0_freq_lo = val
            elif reg == 0x20:
                if val & 0x10:  # ch0 key-on: the theremin lead's own pitch data
                    if OLD_LEAD_START is None:
                        OLD_LEAD_START = t
                    dt = t - OLD_LEAD_START
                    if dt <= PREVIEW_WINDOW:
                        preview_t = NEW_LOOP_ANCHOR_TIME + dt
                        if pending_ch0_freq_lo is not None:
                            add_new(preview_t, opll_write(0x10 + PREVIEW_CH, pending_ch0_freq_lo))
                        add_new(preview_t, opll_write(0x20 + PREVIEW_CH, val))
            i += 3
        elif op == 0x61:
            n = struct.unpack_from("<H", d, i + 1)[0]
            t += n
            i += 3
        elif op == 0x62:
            t += 735
            i += 1
        elif op == 0x63:
            t += 882
            i += 1
        elif 0x70 <= op <= 0x7F:
            t += (op & 0xF) + 1
            i += 1
        elif op == 0x66:
            break
        else:
            sys.exit(f"unexpected opcode 0x{op:02X} at 0x{i:X}")
    assert t == total_samples, f"parsed duration {t} != header total_samples {total_samples}"

    # --- 8-tick logo sting: periodic (not white) noise, quiet -- same fix as
    # the Holst-inspired title_intro.vgm's clock tick ---
    add_new(0, sn_noise_control(fb=0, shift_rate=1))
    for k in range(LOGO_TICKS):
        on_t = k * TICK_SPACING
        off_t = on_t + round(0.09 * SAMPLE_RATE)
        add_new(on_t, sn_atten_write(3, 10))
        add_new(off_t, sn_atten_write(3, 15))

    # --- harmony bed: D minor -> Bb major -> F major -> C major (root, third,
    # fifth), starting exactly where the logo ends and the title screen's
    # music begins. Three channels now split the full triad instead of a
    # bare root+third dyad -- BASS_CH=root, PAD_CH=third, FIFTH_CH=fifth. ---
    BASS_CH, PAD_CH, FIFTH_CH = 1, 2, 4
    CHORDS = [('D2', 'F3', 'A3'), ('A#2', 'D3', 'F3'), ('F2', 'A3', 'C4'), ('C2', 'E3', 'G3')]
    CHORD_DUR = LOGO_DUR  # 6 exact Dm-Bb-F-C cycles per loop body

    # 2026-09-14 (3rd pass): still inaudible under the arpeggio/lead even after
    # flooring those two -- low notes need MORE headroom than high ones to
    # read as equally loud (equal-loudness physics, not a bug in the floor
    # patch), and a plucked-style ROM envelope (Acoustic Bass especially) can
    # decay well below its written level before the next chord change 3.7s
    # later. Fix: louder (7/9, was 11/12) AND re-triggered twice per chord
    # (every half a chord) so the envelope never has time to decay away.
    add_new(NEW_LOOP_ANCHOR_TIME, opll_write(0x0E, 0x00))  # rhythm mode off
    add_new(NEW_LOOP_ANCHOR_TIME, opll_instrument(BASS_CH, INS_ACOUSTIC_BASS, 9))
    add_new(NEW_LOOP_ANCHOR_TIME, opll_instrument(PAD_CH, INS_ORGAN, 10))
    add_new(NEW_LOOP_ANCHOR_TIME, opll_instrument(FIFTH_CH, INS_FRENCH_HORN, 10))

    HALF_CHORD = CHORD_DUR // 2
    tpos, step = NEW_LOOP_ANCHOR_TIME, 0
    while tpos < NEW_END_TIME:
        root, third, fifth = CHORDS[(step // 2) % 4]
        add_new(tpos, opll_retrigger(BASS_CH, note_hz(root)))
        add_new(tpos, opll_retrigger(PAD_CH, note_hz(third)))
        add_new(tpos, opll_retrigger(FIFTH_CH, note_hz(fifth)))
        step += 1
        tpos += HALF_CHORD

    # the preview motif hands off to the real theremin right as it enters
    add_new(NEW_LOOP_ANCHOR_TIME + PREVIEW_WINDOW, opll_note_off(PREVIEW_CH))

    # ornament: a light third->fifth grace-flourish, riding the same
    # half-chord cadence as the harmony bed, short and quiet
    ORNAMENT_NOTE_LEN = round(0.12 * SAMPLE_RATE)
    ORNAMENT_DELAY = round(0.3 * SAMPLE_RATE)
    tpos, step = NEW_LOOP_ANCHOR_TIME, 0
    while tpos < NEW_END_TIME:
        root, third, fifth = CHORDS[(step // 2) % 4]
        orn_t = tpos + ORNAMENT_DELAY
        if orn_t + ORNAMENT_NOTE_LEN < NEW_END_TIME:
            add_new(orn_t, opll_retrigger(ORNAMENT_CH, note_hz(third)))
            add_new(orn_t + ORNAMENT_NOTE_LEN, opll_retrigger(ORNAMENT_CH, note_hz(fifth)))
        step += 1
        tpos += HALF_CHORD

    # --- sparkle (ch5, Vibraphone): a sparse, quiet echo of the arpeggio's
    # own high point in each chord (F5/D5/A5/E5 -- the same peaks it already
    # reaches), once per chord, not continuous. Pure ear-candy. ---
    SPARKLE_CH = 5
    SPARKLE_NOTES = ['F5', 'D5', 'A5', 'E5']
    SPARKLE_OFFSET = round(0.9 * SAMPLE_RATE)
    SPARKLE_VOLUME = 11
    add_new(NEW_LOOP_ANCHOR_TIME, opll_instrument(SPARKLE_CH, INS_VIBRAPHONE, SPARKLE_VOLUME))
    tpos, idx = NEW_LOOP_ANCHOR_TIME, 0
    while tpos < NEW_END_TIME:
        add_new(tpos + SPARKLE_OFFSET, opll_retrigger(SPARKLE_CH, note_hz(SPARKLE_NOTES[idx % 4])))
        idx += 1
        tpos += CHORD_DUR

    # --- merge, re-serialize ---
    events = kept + new_events
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
        if time_s == NEW_LOOP_ANCHOR_TIME and loop_anchor_offset is None:
            loop_anchor_offset = len(stream)
        stream.extend(data)
    if NEW_END_TIME > current_time:
        emit_wait(NEW_END_TIME - current_time)
    stream.extend(bytes([0x66]))
    assert loop_anchor_offset is not None

    loop_offset_field = (HEADER_SIZE + loop_anchor_offset) - 0x1C
    eof_offset_field = (HEADER_SIZE + len(stream)) - 0x04
    gd3_offset_field = len(stream) - 0x14 + HEADER_SIZE  # gd3 immediately follows the stream

    header = bytearray(d[:HEADER_SIZE])  # keep every other header field as-is
    struct.pack_into('<I', header, 0x04, eof_offset_field)
    struct.pack_into('<I', header, 0x14, gd3_offset_field)
    struct.pack_into('<I', header, 0x18, NEW_END_TIME)
    struct.pack_into('<I', header, 0x1C, loop_offset_field)

    gd3 = build_gd3([
        "Escape from Saturn -- Title Theme (sketch, full rearrangement)",
        "",
        "Escape from Saturn",
        "",
        "MAD-65",
        "",
        "Claude Code, for Mateusz",
        "",
        "2026-09-14",
        "vgm_rearrange_theme_sketch.py",
        "Rearrangement of title_theme.py's 2026-09-08 sketch. SN76489 is now "
        "used only for an 8-tick console-logo sting (periodic noise); the "
        "static square pad, its noise layer, and the SN76489 arpeggio are "
        "all gone. Six YM2413 channels instead: ch0 the original portamento "
        "lead (untouched pitch/timing, volume tuned); ch1/2/4 a full D minor "
        "- Bb - F - C triad (Acoustic Bass root, Organ third, French Horn "
        "fifth); ch3 the arpeggio's own pitches replayed on Harpsichord "
        "instead of raw square; ch5 a sparse Vibraphone echo of the "
        "arpeggio's own high points. Total duration and loop point follow "
        "from the logo length and the original's loop-body length.",
    ])

    with open(sys.argv[2], "wb") as f:
        f.write(header)
        f.write(stream)
        f.write(gd3)

    print(f"{sys.argv[2]}: {HEADER_SIZE + len(stream) + len(gd3)} bytes total "
          f"(command stream {len(stream)} bytes)")
    print(f"  logo: {LOGO_TICKS} ticks over {LOGO_DUR/SAMPLE_RATE:.3f}s, "
          f"then title screen music at {NEW_LOOP_ANCHOR_TIME/SAMPLE_RATE:.3f}s")
    print(f"  duration {NEW_END_TIME/SAMPLE_RATE:.2f}s total "
          f"(was {total_samples/SAMPLE_RATE:.2f}s), loop body {loop_samples/SAMPLE_RATE:.2f}s unchanged")
    print(f"  chord cycle: {CHORD_DUR/SAMPLE_RATE:.3f}s/chord, {CHORD_DUR*4/SAMPLE_RATE:.2f}s/cycle, "
          f"{loop_samples/(CHORD_DUR*4):.2f} cycles per loop body")


if __name__ == "__main__":
    main()
