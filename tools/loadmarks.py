"""Read the CPU load's high-water marks (src/fuse.s dbg_load) out of a madsim
F2 dump.

    python tools/loadmarks.py                 # the newest dumps/*_cpu1_ram.bin
    python tools/loadmarks.py dumps/00012345_cpu1_ram.bin

Built with DBG_LOAD (on whenever TRAINER is). The marks live at $70CB-$70D2
and game_start clears them, so a dump taken after a heavy fight - before a
new game - holds that fight's worst frames. Units are FRAME_POS steps: 1024
CPU cycles, 232 = a whole frame.
"""
import glob
import os
import sys

FRAME = 232
HWL, HWC, HWT, NLATE, HWF, NCKL = 0x70CB, 0x70CC, 0x70CD, 0x70CE, 0x70CF, 0x70D0
NCUT = 0x70D1  # 16-bit


def main():
    if len(sys.argv) > 1:
        path = sys.argv[1]
    else:
        dumps = glob.glob(os.path.join("dumps", "*_cpu1_ram.bin"))
        if not dumps:
            sys.exit("no dumps/*_cpu1_ram.bin - press F2 in madsim first")
        path = max(dumps, key=os.path.getmtime)
    ram = open(path, "rb").read()
    l, c, t, late = ram[HWL], ram[HWC], ram[HWT], ram[NLATE]
    front, ckl = ram[HWF], ram[NCKL]
    cuts = ram[NCUT] | ram[NCUT + 1] << 8

    def pct(v):
        return f"{v:3d} (${v:02X}) = {100 * v / FRAME:5.1f}% of a frame"

    def count(v):
        return f"{v}{'+' if v == 255 else ''}"

    print(path)
    print(f"heaviest on-time frame : {pct(l)}")
    print(f"  ...its checkpoint at : {pct(c)}")
    print(f"  ...its tail          : {pct(l - c)}")
    print(f"most expensive tail    : {pct(t)}")
    print(f"highest checkpoint     : {pct(front)}   (the worst front)")
    print(f"frames cut (degraded)  : {cuts}   (late-at-checkpoint ones included)")
    print(f"late frames            : {count(late)}")
    print(f"  ...late at checkpoint: {count(ckl)}   (no tail cut can save these)")
    try:
        cut = fuse_value("TAIL_MAX"), fuse_value("TAIL_MARGIN")
        if cut[0]:
            print(f"TAIL_CUT in the build  : {FRAME - cut[0] - cut[1]}"
                  f" (232 - TAIL_MAX {cut[0]} - TAIL_MARGIN {cut[1]})")
        else:
            print("TAIL_CUT in the build  : off (TAIL_MAX = 0)")
    except (OSError, ValueError):
        pass
    print(f"measured worst tail    : {t} -> TAIL_CUT {FRAME - t} minus a margin")


def fuse_value(name):
    """A constant out of src/fuse.s, as the source has it now."""
    for line in open(os.path.join("src", "fuse.s")):
        parts = line.split(";")[0].split("=")
        if len(parts) == 2 and parts[0].strip() == name:
            return int(parts[1].strip())
    raise ValueError(name)


if __name__ == "__main__":
    main()
