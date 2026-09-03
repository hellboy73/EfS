# Escape from Saturn (EfS)

A vector-graphics **Asteroids** descendant for the **MAD-65** console — a large
wrapping world, a rotating and zooming camera, a story campaign, and a simplified
physics model where rocks collide with each other, transfer spin, and break apart.

Played in **TATE (portrait) mode**: the monitor stands on its side, giving a
300 x 400 screen.

> **Status: the game is code.** [`src/`](src/) flies, collides and draws a
> radar — it is [`proto/03_radar`](proto/03_radar/) promoted whole, and the
> benches under [`proto/`](proto/) are now frozen records rather than living
> code. `make` builds it. The technical assumptions are written down in
> [`docs/design_technical.md`](docs/design_technical.md); the undecided parts
> are tracked in [`docs/open_questions.md`](docs/open_questions.md).

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
  Makefile                `make` -> cart.bin, `make run` -> madsim,
  cart.cfg                `make preview` -> the headless check. THE build.
  src/                    THE GAME - the only living code in the repo
    main.s                cart_init and cart_frame, and the state they run on:
                          every tunable, the zero page and the whole RAM map
    math.s                the quarter-square multiply, the LFSR, the shifts
    input.s               the joystick, and the only file that reads one
    camera.s              the heading, the rotation tables, the transform
    ship.s                the player's motion, and the outline that draws it
    objects.s             the field: the level, the sector grid, the walk
    physics.s             rock against rock, over that same grid
    stars.s               the two parallax layers, sampled not simulated
    occlude.s             what the star layers are NOT drawn behind
    radar.s               the HUD radar walk
    hud.s                 the text readout - assembles to nothing, HUD_ON = 0
    shapes.s              every vertex table          ] authored by the
    levels.s              every level's opening state ] editors in tools/
    radar_bg.s            the radar's ring, as a background bitmap
    bootstrap.s           Model B: copy both banks to RAM, then never read
    header.s              the $8000 signature and the two vectors
    ship32.s              the ship sprite, kept for SHIP_SPRITE = 1
    mad65.inc             OS jump table + RAM/ZP equates (the cart's interface
                          to the console firmware)
  docs/
    design_technical.md   the technical design: world model, camera, transform,
                          rendering, object model, bank map, fixed decisions
    physics.md            the physics model and its (still placeholder) parameters
    open_questions.md     everything not decided yet, and how each will be settled
    story.md              story index + what the fiction commits the engine to
    story_intro.md        the narrative itself: the opening text,
    story_levels.md       the 5-level working script,
    story_full.md         and the full back story with the reveal
  tools/                  the tooling, all of it pointed at src/
    preview.py            the headless end-to-end check, and preview.png
    shape_editor.py       authors src/shapes.s
    level_editor.py       authors src/levels.s
    sprgen.py             PNG -> sprite blobs
    bggen.py              PNG -> background bitmaps
  assets/
    png/                  source art (sprites, bitmaps)
    vgm/                  source music
  proto/                  FROZEN benches - the record of what each question
    01_flight/            cost, and nothing the build reads. None of them is to
    02_rocks/             be edited or forked again; each README says so at the
    03_radar/             top. src/ began as a byte-for-byte copy of 03.
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

## The benches

Before the game there were three benches, and they are why the game starts as
something that already flies. Each forked from the last, answered one question
with measurements rather than opinion, and is now **frozen**:

| bench | its question | what it left behind |
|---|---|---|
| [`proto/01_flight`](proto/01_flight/) | what does flying this ship feel like? | the camera, the speed tiers, the starfield - and Model B, worth 2.5x on this workload |
| [`proto/02_rocks`](proto/02_rocks/) | what does a colliding asteroid field cost? | the sector grid, the mass/radius model, the two authoring tools |
| [`proto/03_radar`](proto/03_radar/) | what is near, on a scale that does not move? | the HUD radar - and the code that became `src/` |

They stay in the tree because `docs/` cites their findings and because a bench
is the smallest complete thing that ever answered its question. They are not to
be edited, and a new question gets answered in `src/` rather than in a
`proto/04` - see the banner at the top of each.

---

## Building

```bash
make
```

assembles `cart.bin` from `src/` with `cl65 -t none`, two 8 KB banks, and

```bash
make run
```

launches it in `madsim.exe` with the monitor already on its side (`F12`
toggles that, `F3` shows the CPU/GPU utilisation meter). Then

```bash
make preview
```

runs the whole cartridge headless in a 65C02 emulator - CPU1 and the GPU
against each other, no window - checks a few hundred assertions about what
reached the framebuffer, reports the frame's cycle budget and writes
`preview.png`. That is the test suite.

Build outputs (`cart.bin`, `preview.png`, generated `assets/*.bin`) are **not**
tracked - they are regenerated from tracked sources. `madsim.exe` and
`roms/*.bin` *are* tracked, on purpose, per the note above.

---

## Related

- **MAD-65** — the console: hardware, firmware, simulator, and the
  [Software Developer's Guide](../MAD-65/docs/MAD65_Software_Developers_Guide.md).
- **CETAS** — the first MAD-65 game; the structural template this project follows.
