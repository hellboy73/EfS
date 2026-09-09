#!/usr/bin/env python3
"""vgmstrip.py — strip a VGM file down to the raw command stream CETAS embeds.

The OS VGM player (vgm_play $FF66) does no header parsing: it starts executing
commands at the address it's given and loops on the stream's own 0x66. So the
cart must store ONLY the command stream, not the 40+ byte VGM header or the
trailing GD3 tag. Previously this offset/length pair was hand-computed per song
and pasted into an `.incbin` in main.s (see the VGM spec: data offset @ file
$34, add $34; GD3 offset @ file $14, add $14) — easy to get wrong when swapping
songs. This tool computes both automatically and also validates the stream
against what the firmware player actually supports, so an incompatible export
fails the build instead of silently playing nothing in-game.

The OS player can also loop back to a point PAST a one-shot intro (vgm_play_loop
$FFAE) instead of restarting the whole stream. This tool reads the VGM loop
offset (header field @ $1C) and emits it as an assembler constant in a sibling
`.inc` (MUSIC_HAS_LOOP / MUSIC_LOOP_OFF = byte offset into the stripped stream),
which main.s bakes into the loop-anchor address. No loop field ⇒ MUSIC_HAS_LOOP
= 0 and the game uses the plain whole-stream loop.

Usage: python vgmstrip.py <in.vgm> <out.bin> [prefix]
       (also writes <out>.inc next to <out.bin>)

The optional <prefix> namespaces the emitted constants as <PREFIX>_MUSIC_HAS_LOOP
/ <PREFIX>_MUSIC_LOOP_OFF (uppercased) so several songs can be .include'd into
one translation unit without symbol collisions. Omit it for the legacy bare
MUSIC_HAS_LOOP / MUSIC_LOOP_OFF names.
"""
import os
import struct
import sys

SUPPORTED_1BYTE = {0x66}                       # loop-to-start (ends the stream)
SUPPORTED_2BYTE = {0x50, 0x30}                 # SN76489 #1 write / SN76489 #2 write
                                               #   0x30 = second PSG: the player IGNORES it
                                               #   (SN76489 #2 is reserved for SFX), but it's
                                               #   kept in the stream so byte offsets — and the
                                               #   loop anchor — stay exact.
SUPPORTED_3BYTE = {0x51, 0x61}                 # YM2413 write / wait nnnn samples
SUPPORTED_WAITS = {0x62, 0x63}                 # wait 735 / 882 samples
UNSUPPORTED_FM_CLOCKS = {0x2C: "YM2612 (Genesis export)", 0x30: "YM2151"}


def u32(d, off):
    return struct.unpack_from("<I", d, off)[0]


def strip(data):
    if data[:2] == b"\x1f\x8b":
        import gzip
        data = gzip.decompress(data)
    if data[:4] != b"Vgm ":
        sys.exit("not a VGM file (bad magic)")

    for clock_off, name in UNSUPPORTED_FM_CLOCKS.items():
        if len(data) > clock_off + 4 and u32(data, clock_off):
            sys.exit(f"song uses {name} — the OS player only supports SN76489 "
                      f"+ YM2413; re-export as DefleMask 'Sega Master System (+FM)'")

    version = u32(data, 0x08)
    if version >= 0x150:
        rel = u32(data, 0x34)
        data_off = 0x34 + rel if rel else 0x40
    else:
        data_off = 0x40

    gd3_rel = u32(data, 0x14)
    end = (0x14 + gd3_rel) if gd3_rel else (0x04 + u32(data, 0x04))

    loop_rel = u32(data, 0x1C)               # VGM loop offset (0 ⇒ no loop point)
    loop_abs = (0x1C + loop_rel) if loop_rel else None

    starts = set()                           # every valid command-start file offset
    i = data_off
    while i < end:
        starts.add(i)
        op = data[i]
        if op in SUPPORTED_2BYTE:
            i += 2
        elif op in SUPPORTED_3BYTE:
            i += 3
        elif op in SUPPORTED_WAITS:
            i += 1
        elif 0x70 <= op <= 0x7F:
            i += 1
        elif op in SUPPORTED_1BYTE:
            i += 1
            stream = data[data_off:i]        # stream ends on the single 0x66
            # Resolve the loop anchor to a byte offset INTO the stripped stream.
            loop_off = None
            if loop_abs is not None:
                if loop_abs not in starts or loop_abs >= i:
                    sys.exit(f"VGM loop offset 0x{loop_abs:X} is not a command "
                              f"boundary inside the stream — refusing to bake a "
                              f"loop anchor that would desync the player")
                loop_off = loop_abs - data_off
            return stream, loop_off
        else:
            sys.exit(f"unsupported VGM opcode 0x{op:02X} at offset 0x{i:X} — "
                      f"the OS player hard-stops on unknown opcodes")

    sys.exit("stream never hit a 0x66 loop command before GD3/EOF — "
             "the OS player needs one to loop the song")


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(f"usage: {sys.argv[0]} <in.vgm> <out.bin> [prefix]")
    src, dst = sys.argv[1], sys.argv[2]
    # <PREFIX>_ namespaces the constants so several songs coexist in one TU.
    pfx = (sys.argv[3].upper() + "_") if len(sys.argv) == 4 else ""
    with open(src, "rb") as f:
        raw = f.read()
    stream, loop_off = strip(raw)
    with open(dst, "wb") as f:
        f.write(stream)

    inc = os.path.splitext(dst)[0] + ".inc"
    with open(inc, "w") as f:
        f.write("; auto-generated by tools/vgmstrip.py -- do not edit\n")
        if loop_off is not None:
            f.write(f"{pfx}MUSIC_HAS_LOOP = 1\n")
            f.write(f"{pfx}MUSIC_LOOP_OFF = ${loop_off:04X}\n")
        else:
            f.write(f"{pfx}MUSIC_HAS_LOOP = 0\n")
            f.write(f"{pfx}MUSIC_LOOP_OFF = 0\n")

    loopmsg = f"loop @ +0x{loop_off:X}" if loop_off is not None else "no loop point (whole-stream loop)"
    print(f"{src}: {len(stream)} bytes of command stream -> {dst}  ({loopmsg})")


if __name__ == "__main__":
    main()
