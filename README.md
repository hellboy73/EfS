# Escape from Saturn (EfS)

A vector-graphics **Asteroids** descendant for the **MAD-65** console — a large
wrapping world, a rotating and zooming camera, a story campaign, and a simplified
physics model where rocks collide with each other, transfer spin, and break apart.

Played in **TATE (portrait) mode**: the monitor stands on its side, giving a
300 x 400 screen.

> **Status: design only.** No game code exists yet. The technical assumptions are
> written down in [`docs/design_technical.md`](docs/design_technical.md); the
> undecided parts are tracked in [`docs/open_questions.md`](docs/open_questions.md).

---

## The short version

- **World.** A torus many screens across, not a single screen. Positions are 16-bit
  per axis, so wrapping is 16-bit overflow — no wrap logic anywhere in the engine.
- **Camera.** The ship is drawn pointing up the screen; steering rotates the
  *world* around it, smoothly, at subpixel speeds. Faster flight pulls the camera
  back and slides the ship down the screen, so you see further ahead — and objects
  shrink, which is why the art is vector.
- **Objects.** Asteroids and enemies each carry position, velocity and spin, and
  are simulated across the whole world every frame, not spawned on approach.
- **Physics.** Rocks bounce off each other with mass-weighted, energy-losing
  collisions, trade spin on glancing blows, and fragment above an impact-speed
  threshold. Shooting one splits it into two smaller ones with conserved momentum.
- **Background.** Parallax star pixels drifting slower than the ship, sampled from
  a fixed layer rather than simulated.

---

## Layout

```
EfS/
  docs/
    design_technical.md   the technical design: world model, camera, transform,
                          rendering, object model, bank map, fixed decisions
    physics.md            the physics model and its (still placeholder) parameters
    open_questions.md     everything not decided yet, and how each will be settled
    story.md              story index + what the fiction commits the engine to
    EFS Wstęp do gry.md   the narrative itself (PL): opening text,
    EFS Skrócony ...md    the 5-level working script,
    EFS Pełna historia...  and the full back story with the reveal
  src/
    mad65.inc             OS jump table + RAM/ZP equates (the cart's interface
                          to the console firmware)
  assets/
    png/                  source art (sprites, bitmaps)
    vgm/                  source music
  tools/                  asset compilers (PNG -> sprite blobs, VGM -> streams)
  roms/
    cpu_os.bin            MAD-65 CPU1 firmware  ] bundled so the repo is
    gpu_os.bin            MAD-65 GPU firmware   ] self-contained
  madsim.exe              the MAD-65 simulator, bundled for the same reason
  dumps/                  simulator dumps (gitignored)
```

The **firmware and the simulator are built in the separate MAD-65 repo**
(`D:\GitHub\MAD-65`) and copied in here on purpose, so this repo builds and runs
with no external setup. After any firmware change: rebuild there and recopy
`cpu_os.bin` + `gpu_os.bin` into `roms/`.

---

## Cartridge

**256 KB = 32 banks of 8 KB**, window `$8000-$9FFF`, **Model B** (game code is
copied into RAM at boot and runs from there). The draft bank map is in
[`docs/design_technical.md`](docs/design_technical.md) section 10 — it will be
redone once assets have real sizes. The bank register reaches 1 MB, so growing to
512 KB later is a bigger EPROM part and nothing else.

---

## Building

Nothing to build yet. When there is:

```bash
make
```

will regenerate assets and assemble `cart.bin` with `cl65 -t none --cpu 65C02`, and

```bash
make run
```

will launch it in `madsim.exe`. Press `F12` in madsim to stand the monitor on its
side.

Build outputs (`cart.bin`, generated `assets/*.bin`) are **not** tracked — they are
regenerated from tracked sources. `madsim.exe` and `roms/*.bin` *are* tracked, on
purpose, per the note above.

---

## Related

- **MAD-65** — the console: hardware, firmware, simulator, and the
  [Software Developer's Guide](../MAD-65/docs/MAD65_Software_Developers_Guide.md).
- **CETAS** — the first MAD-65 game; the structural template this project follows.
