#!/usr/bin/env python3
"""vgm_patch_theme_sketch.py — targeted fix for efs_title_theme_sketch.vgm
(the 2026-09-08 sketch at D:\\MAD65\\VGMPlay_052-0\\), per 2026-09-14 feedback:
the opening noise and square pad need fixing, the rest ("the arpeggio", the
YM2413 portamento lead entering at ~30s) is fine and untouched.

Diagnosis (from decoding the command stream — the source title_theme.py
wasn't found locally, so this patches the compiled .vgm directly):

  reg6 (noise control) is set ONCE at t=0 to white-noise / fastest rate
  (0x4 = FB=1, rate=0) — the harshest possible PSG noise mode.
  reg7 (noise attenuation) fades in from silent(15) to ~13-14 by t=9s and
  STAYS there — audible, hissing, fast white noise — for the entire 104s
  piece. That's "ten szum" and it never actually goes away.

  reg1/reg3 (tone0=D3 / tone1=A4 attenuation) fade in from t=1.1s to
  t=11.2s and then hold STATIC at 8/10 (fairly loud, 0=loudest/15=silent)
  for the whole piece — two unmoving square tones, "za głośno i mało
  ciekawe". reg5 (tone2), which drives the actual arpeggio, is untouched
  here — that's the part that sounds good.

Fix (both are value-only substitutions at their EXACT original byte
offsets — nothing is inserted or removed, so total length, GD3 offset and
the VGM loop offset all stay valid with no recomputation needed):
  - every reg7 write is forced to 15 (silent) -- removes the noise entirely,
    as suggested ("szum chyba niepotrzebny").
  - every reg1 write is floored at 11, every reg3 write at 12 -- the pad
    still fades in with the same shape, it just settles at a background
    level instead of a foreground one.

Usage: python vgm_patch_theme_sketch.py <in.vgm> <out.vgm>
"""
import struct
import sys


def patch(data):
    out = bytearray(data)
    i = 0x100
    n_noise, n_tone0, n_tone1 = 0, 0, 0
    while i < len(out):
        op = out[i]
        if op == 0x50:
            val = out[i + 1]
            if val & 0x80:
                reg = (val >> 4) & 0x7
                lo = val & 0xF
                if reg == 7 and lo != 15:
                    out[i + 1] = 0xF0 | 15
                    n_noise += 1
                elif reg == 1 and lo < 11:
                    out[i + 1] = 0x80 | (1 << 4) | 11
                    n_tone0 += 1
                elif reg == 3 and lo < 12:
                    out[i + 1] = 0x80 | (3 << 4) | 12
                    n_tone1 += 1
            i += 2
        elif op == 0x51:
            i += 3
        elif op == 0x61:
            i += 3
        elif op in (0x62, 0x63):
            i += 1
        elif 0x70 <= op <= 0x7F:
            i += 1
        elif op == 0x66:
            break
        else:
            sys.exit(f"unexpected opcode 0x{op:02X} at 0x{i:X} -- stopping, nothing written")
    return out, n_noise, n_tone0, n_tone1


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <in.vgm> <out.vgm>")
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    out, n_noise, n_tone0, n_tone1 = patch(data)
    with open(sys.argv[2], "wb") as f:
        f.write(out)
    print(f"{sys.argv[2]}: {len(out)} bytes (unchanged length)")
    print(f"  silenced {n_noise} noise (reg7) writes")
    print(f"  floored {n_tone0} tone0 (reg1) writes to atten 11")
    print(f"  floored {n_tone1} tone1 (reg3) writes to atten 12")


if __name__ == "__main__":
    main()
