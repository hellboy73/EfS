# SRV-T01 – model referencyjny statku

Wygenerowane przez `tools/ship_ref/build_ship_ref.py` (`python tools/ship_ref/build_ship_ref.py`).
Proporcje z wektorowego zarysu gry (`ship_png/ship_rest_150_x8.png`) i grafiki tytułowej.
Pliki: `srv_t01_sheet.png` (arkusz 8 widoków), pojedyncze widoki `srv_t01_*.png`, siatka `srv_t01.obj` (Blender itp.).

Kolory (biel/szary + pomarańczowe paski + cyjanowy żar dysz) to **założenie** – oryginał jest 1-bitowy.
Zmień `COL` w skrypcie i wyrenderuj ponownie, jeśli chcesz inną malaturę.

## Opis do wklejenia w ChatGPT (angielski, razem z obrazami)

> Reference: the attached turnaround sheet shows ONE specific spacecraft, "SRV-T01"
> (Survey Reconnaissance Vessel – Titan 01). Keep its design EXACTLY the same in every image:
> - the main hull is a long, low PYRAMID: a sharp pointed nose, standing on a THICK FLAT BASE SLAB (~3.6 tall, same outline as the pyramid, vertical sides, flat underside; its bottom is level with the bottom of the engine pods),
>   and a triangular cross-section (seen head-on it is an isosceles triangle, ~22 wide, ~13 tall);
>   two sloped faces meet at a ridge running from the nose back to the stern; the stern face is a flat triangle;
> - cockpit canopy: seen from above, the black glass windscreen is a TRIANGLE with the same proportions as the
>   hull (needle tip near the nose, widening back), covering both sloped faces and split by the ridge; just behind
>   the glass a thin dark SEAM runs across the hull - the upper canopy lifts open there to let the pilot in;
> - two identical cylindrical engine pods on the left and right of the REAR half, each carried on a short, thick,
>   flat OUTRIGGER WING (about a quarter of a pod-diameter long, at the height of the base slab's middle) that holds the pod clear of the hull; each pod is a plain rectangular cylinder (a simple rectangle in side view, axis at mid-height of the base slab) with a FLAT front face holding a CONCAVE conical intake that narrows INTO the pod (not a protruding nose cone), two orange bands, and a recessed dark
>   nozzle with a pale cyan glow;
> - a THIRD nozzle of the same kind in the centre of the stern face, in a short cylindrical housing
>   that sticks out behind the hull and slightly below its flat underside (3 engines in a row seen from behind);
> - NO tail fin, NO big wings (only the two short pod outriggers), NO antennae; one orange survey band across each aft slope;
> - off-white / light-grey painted metal, orange survey-fleet markings, hull number "SRV-T01"
>   in small stencil lettering on a sloped face;
> - a small, utilitarian corporate survey craft – not a fighter, no weapons, no extra greebles.
> Do not add, remove or move any part. Place this exact ship in the following scene: …

Wskazówka: wgraj `srv_t01_sheet.png` + 1–2 widoki 3/4 i w każdej nowej scenie powtarzaj ten opis.

---

# Baza wydobywcza (`srv_base_*.png`, `srv_base.obj`)

Generator: `python tools/ship_ref/build_base_ref.py`. Liczby z gry (`src/base.s`, design_technical 11.48):
6 trójkątów równobocznych po 140 px, wierzchołkami do środka, 16 px odstępu, środki 96 px od środka bazy.
Skala modelu: 1 jednostka = 1 jednostka statku (statek 48 = jego sprite 52 px), baza powiększona
`BASE_SCALE = 1.5` względem gry. Moduł: trójkątny graniastosłup o wysokości równej POŁOWIE boku (~97 j.),
wszystkie krawędzie sfazowane; tunele (r = 11) co sąsiednią parę na ~40% wysokości.

## Opis do wklejenia w ChatGPT

> Reference: the attached sheet shows ONE specific space mining station of a human survey/mining company.
> Keep it EXACTLY the same in every image:
> - SIX identical-sized solid MODULES, each a low triangular prism (equilateral triangle in plan view, its height
>   only HALF a triangle side), arranged in a hexagon ring with every module's apex pointing at the centre and a
>   narrow gap between neighbours; the middle of the ring is empty;
> - all edges chamfered/bevelled (vertical corners and the top/bottom rims), flat underside, off-white / light-grey
>   painted panels with orange survey-fleet stripes and dark-grey trim;
> - every pair of neighbouring modules is joined by ONE short, narrow cylindrical tunnel with flanges, at
>   about 40% of the height, across the gap;
> - walls are NOT all alike: one module has a wide panoramic cockpit-style window band, one a huge hazard-striped
>   hangar door, one a dense grid of habitat windows (about half lit warm amber), one big louvred vents and a docking
>   ring, one two cargo doors, one three large amber windows plus a docking ring; plain panel seams elsewhere;
> - roofs are working space-station roofs: machinery halls, exhaust stacks, pipe runs, radiator fins, a coolant tank,
>   cargo containers, small comm dishes - NO round pads, NO antenna masts, NO beacons; on three alternate modules the roof
>   instead holds a shallow TRIANGULAR recess (a landing bay) whose outline is the exact same equilateral triangle as the
>   module, concentric and ~66% size, with an orange border and a few amber lights on its dark floor; ONE survey ship
>   (SRV-T01, see the ship sheet) sits in one of these bays, nose pointing TOWARDS THE CENTRE of the station - it is about half the width of the bay;
> - the UNDERSIDE of every module carries similar horizontal installations (long pipe runs, manifolds, horizontal tanks,
>   a radiator plate, a round reactor drum with radial lines, cargo gantry beams with hung containers), different per module;
> No other structures, no spires, no solar panels, no extra modules.

---

# Pająk (obcy koparko-wydobywca) (`spider_*.png`, `spider.obj`)

Generator: `python tools/ship_ref/build_spider_ref.py`. Maszyna obcych, która kopie i wydobywa saturnium ze skał
(`docs/physics.md` 9.1). W grze ma ok. 44 px, czyli rozmiar zbliżony do statku (rozpiętość nóg modelu ~62 j.,
statek 48). Tylko szarości (bez pomarańczu - ten kolor to ludzie).

## Opis do wklejenia w ChatGPT

> Reference: the attached turnaround sheet shows ONE specific alien machine, a mining "spider". Keep it EXACTLY the same
> in every image; it is a machine, not an animal:
> - FOUR thin, long legs, arranged like a spider's: each leg rises from under the rim of the body OUTWARDS AND UP to a
>   spherical KNEE joint, then goes OUTWARDS AND DOWN to a small round foot pad - the knees are the highest points of
>   the legs; legs at the four diagonal directions, evenly spaced; each upper leg has a hydraulic ram and clamp rings,
>   the lower leg has two thin pipes along it;
> - the TOP of the body is a wide, flat saucer / disc-shaped dome with a small central turret bump, three thin antenna
>   whiskers, ten small round vents near the rim and panel rings;
> - the BODY below the saucer is a short drum that narrows DOWNWARDS into a bucket-like MAW, like an excavator scoop:
>   an elliptical funnel with a dark open throat at the bottom, ringed by a row of about 14 pointed teeth; ring bands and a
>   bundle of ten vertical pipes run down its outside;
> - MANY thin pipes and dark cables: cables run from the central turret over the saucer's surface down to the rim in
>   eight lines, and from the rim in sagging arcs over the knees and down to the feet; looping manifold pipes join the
>   neck ring to each shoulder;
> - the whole machine is greyscale only - light grey saucer, mid grey body and legs, dark grey cables and feet, bright
>   pale teeth and joints; no colour, no glow, no markings, no weapons.
> Do not add, remove or move any part. Place this exact machine in the following scene: …

---

# Pulsar (obcy) (`pulsar_idle_*.png`, `pulsar_fire_*.png`, `pulsar_compare.png`, `pulsar_*.obj`)

Generator: `python tools/ship_ref/build_pulsar_ref.py`. Z gry (`EN_PULSAR_S*`, `src/pulsar.s`): z boku dwa niskie, bardzo rozwarte
stożki podstawami do siebie (podstawa ~37 px, wysokość ~9 px), odstęp między podstawami od ~4 px (strzał) do ~18 px (spoczynek);
poziomy pręt (laser) przez szczelinę, wiązka z obu końców naraz tylko gdy stożki są najbliżej. W modelu: bryła obrotowa wokół osi Z
(kamera na wysokości 0 = widok z boku jak w grze). Wiązka na modelu ma 110 j. (w grze ~234 j. na stronę, ~4,5 długości statku).

## Opis do wklejenia w ChatGPT

> Reference: the attached sheets show ONE specific alien machine, the "pulsar", in two states. Keep it EXACTLY the same:
> - TWO very low, very obtuse (about 130 degree apex) stepped cones, LEVITATING one above the other along a vertical axis with
>   nothing connecting them (no axle, no drum, no cables, no pipes): bases facing each other, apexes pointing away (up and
>   down), each with a flat dark plate on its base side, a rim bead, three terrace steps, a ring of small round vents and a small
>   ball on the apex; greyscale only, mid-grey metal;
> - BETWEEN the cones, also levitating, hangs a small COIL: a spring-like winding of thin grey wire (about nine turns, a thinner
>   dark strand wound the opposite way) lying HORIZONTALLY, wound round the line of the laser beam; it has NO nozzles and
>   NO housing - the beam comes out of the coil itself;
> - IDLE state: the cones are far apart (gap about the cone's height), only the floating coil hangs between them, NO beam;
> - FIRING state: the cones have moved closer (gap less than half the idle gap), a hot white core glows inside the coil, and TWO
>   thin straight near-white laser beams leave the two ends of the coil in exactly opposite horizontal directions, along the coil's
>   axis, perpendicular to the cones' axis, with a small flare at each end of the coil and a few thin ring pulses along the beams;
> - no colour, no other parts. Place this exact machine, in the stated state, in the following scene: …

---

# UFO (obcy) (`ufo_*.png`, `ufo.obj`)

Generator: `python tools/ship_ref/build_ufo_ref.py`. Kształt wg obrazka od użytkownika (NIE wg symbolicznej grafiki z gry);
z gry tylko rząd wielkości (promień kolizji 18 px, spodek ~34 j. średnicy, statek 48). Szarości, światło prawie białe.

## Opis do wklejenia w ChatGPT

> Reference: the attached sheet shows ONE specific alien craft, a classic flying saucer, drawn flat and thin:
> - a wide, very thin disc (width about seven times its thickness) with a thin bevelled rim carrying a ring of tiny pale
>   port lights, and shallow concentric terraces and two thin dark concentric grooves on the top surface (no radial lines,
>   no wires, no antennas);
> - a LOW, smooth, glossy blister dome in the middle of the top, with a thin ring round its foot;
> - the underside is shallow: concentric terraces, a few small dark ports, and in the middle a dark round recess;
> - in the recess hangs ONE pure-white, strongly glowing rounded bulb (sphere-like, slightly pointed at the bottom). That
>   white glow is the only light: no beam, no rays, no light shaft;
> - greyscale metal, mid and light greys, no markings, no colour.
> Do not add, remove or move any part. Place this exact craft in the following scene: …

---

# Mina EMP (`mine_*.png`, `mine.obj`)

Generator: `python tools/ship_ref/build_mine_ref.py`. Proporcje z gry (`EN_EMP_MINE_S*`, `src/empmine.s`): z góry trzy trójkąty co 120°,
każdy o podstawie 10 px i wysokości 13 px (wierzchołek 16 px od środka), podstawami stykające się narożnikami wokół
małego trójkątnego otworu. Model: trzy ostrosłupy o podstawie kwadratu (10 x 10, wysokość 13), podstawy zwrócone do środka i
stykające się pionowymi krawędziami - w środku trójkątny szyb otwarty od góry i od dołu, a w nim biała świecąca kulka (jak pod UFO).
Szare ostrosłupy z pomarańczowymi czubkami (bez innych pomarańczowych elementów). ~30 j. średnicy (statek 48).

## Opis do wklejenia w ChatGPT

> Reference: the attached sheet shows ONE specific object, a small space mine of the human survey company. It consists ONLY of
> three identical square-based PYRAMIDS, tall and sharp (height about 1.3 times the width of the square base), and a glowing ball:
> - the three pyramids lie in one horizontal plane, 120 degrees apart, points outwards (seen from above the mine is a
>   three-pointed star); each pyramid's flat square base faces the middle, and neighbouring bases touch each other along their
>   vertical edges, so together the bases form a small triangular SHAFT that is open at the top and at the bottom;
> - inside the shaft, in the exact middle, floats a small pure-white, strongly glowing sphere (the only light; no beam);
> - pyramids mid-grey (faces alternately a bit lighter and darker), the square bases dark grey, and the last fifth of each pyramid's
>   point is orange - that is the ONLY colour accent;
> - nothing else: no cube, no necks, no cables, no frame rods, no lights. Place this exact mine in the following scene: ...

---

# Kapsuła ratunkowa LIFEPOD (`lifepod_*.png`, `lifepod.obj`)

Generator: `python tools/ship_ref/build_lifepod_ref.py`. Wg opisu użytkownika: walec z prostokątnym oknem na połowie obwodu, ~2x gondola
silnikowa statku (promień 10, długość 42; gondola ma 5 x 21), sfazowane krawędzie, kapsuła stoi pionowo, a na górnej pokrywie (dekiel) jest kwadratowy właz z napisem LIFEPOD (nic nie wystaje z boku).
Dodane od siebie: mała dysza na dole, dwa pomarańczowe pasy, zawiasy i zatrzask włazu.
Ludzki sprzęt: biało-szary z pomarańczowymi znakami.

## Opis do wklejenia w ChatGPT

> Reference: the attached sheet shows ONE specific object, a human rescue capsule named "LIFEPOD". Keep it EXACTLY the same:
> - the body is a plain horizontal CYLINDER (length about 2.1 times its diameter) with bevelled end edges, off-white / light grey
>   painted metal, with two thin orange bands round it near the ends;
> - ONE rectangular WINDOW covers a bit less than half of the cylinder's circumference (about 160 degrees) on one side and about a third of its length: a dark
>   glass band wrapping round the cylinder, in a thin grey frame, ONE single pane with NO dividing bars;
> - the capsule STANDS upright. In its flat round LID (the top end cap, with a bevelled rim) is set a SQUARE hatch (about 1.1 times
>   the cylinder's radius per side), a thin raised plate with an orange border and the word "LIFEPOD" in black block capitals in the
>   middle, two small hinges on one edge and an orange latch on the opposite edge; nothing sticks out of the cylinder's side;
> - the window band sits in the upper part of the side, below the lid;
> - the bottom end has a small dark thruster nozzle;
> - nothing else: no wings, no fins, no antennas, no markings except the word LIFEPOD. Place this exact capsule in the following scene: ...

## TRANSPORTER (Transporter, EA_TRANSPORTER)

Proportions from the game's shape (top view 90 x 60): two huge drive cylinders, 90 long x 15 across, side by side
with a 30 gap; between them a flat spine frame (80 long) carrying a box CONTAINER 40 long x 29 wide that is clearly
LOWER than the cylinders (top about 40% of the cylinders' height). Cylinders: light grey drums with reinforcing
rings and two orange bands near the ends, concave conical intake in front (cone narrowing into the drum, like the crew ship pods), dark engine bell with a cyan glow at the rear.
Container: tan/brown cargo box with vertical ribs, orange stripe, dark corner posts, small amber beacon on the lid.
Files: transporter_sheet.png, transporter_*.png, transporter.obj (tools/ship_ref/build_transporter_ref.py).

TRANSPORTER update (shape re-read from the current src/enemies.s): the game outline is now 93 x 60 -
two 15-wide drums side by side, ends stepped at the rear (drums reach x=-45, waist stops at -40), and the
FRONT narrows into a pointed BEAK (from the full 60 width to a tip 13 further on). In the model the beak is
a low wedge-shaped prow swallowing the drums' front ends, with the two forward nozzles (concave intakes,
orange rims) set into its two slanted faces. Rear: cyan-glow engine bells; container between the drums.
TRANSPORTER beak, final: a plain pointed wedge as tall as the drums, all edges chamfered (bevelled); no round intakes or nozzles on it.
TRANSPORTER beak, revised: as tall as the drums' full diameter and smoothly rounded - its flanks are the drums' own round
cross-section (stadium shape) running forward and narrowing to a vertical knife-edge tip; no ridges or hard corners around the drums.
TRANSPORTER beak tip: rounded nose (plan radius 7 units, tangent to the flanks) instead of a knife edge.
TRANSPORTER beak tip: slightly truncated - a small flat vertical front face (stadium-shaped, ~8 units wide) instead of a point.

## TRANSPORTER v2 (restart from the game outline; replaces the pontoon-like cylinder version above)

Game outline 93 x 60. Two SQUARE-section engine bodies (15 x 15, bevelled edges, light grey, orange collars at both ends,
grey ribs and small dark vent slots on the outer walls), running the full length. At the REAR each square body ends in a
ROUND engine nozzle (dark bell with a cyan glow). At the FRONT a flat-fronted bevelled wedge BEAK as tall as the engines
joins both bodies (outline narrows from the full 60 width to a flat ~8-wide nose). Between the engines: a closed hull deck with a
bulkhead at the stern (closed) and one at the bow. On the deck a tan/brown cargo CONTAINER (40 x 29, vertical ribs,
orange stripe, dark corner posts, amber beacon), taller than before (10.5 high) but still just below the engine tops.
TRANSPORTER v2: the underside is one flat closed belly plate (no grooves between engines and deck).

## ALIEN TOWER (EA_ALIEN_TOWER, ffield.s)

In the game data it is a diamond with both diagonals (75 px half-diagonal) - an "envelope" in 2D. In 3D: two extremely tall
SQUARE PRISMS standing upright, joined BASE TO BASE, so it is one column with a waist halfway where the two bevelled bases meet
(a thin light bevelled ring there). Each prism is 5 x as tall as its base side is wide (side 10, each prism 50 high, 100 in all);
the square is turned 45 degrees, so seen from above it is the game's diamond. Colour: dark blue-grey, matte, with lightly
bevelled (chamfered) edges, lighter bevels on the top, bottom and waist. Windows (tall pairs), vents (wide, with slits),
tall doors and rows of small square ports are shown ONLY as thin engraved outlines - flush panels a shade lighter/darker than
the wall, separated by thin contour lines, with a thin horizontal contour line between every 10-unit bay - so the whole surface
stays closed and solid, with no openings and no glow. Files: alien_tower_sheet.png, alien_tower_*.png, alien_tower.obj
(tools/ship_ref/build_alien_tower_ref.py).
ALIEN TOWER, revised: the two prisms are now two tall square PYRAMIDS joined base to base - the tower narrows towards the top and
towards the bottom into two slightly blunted tips (tiny flat square at each end), widest at the bevelled waist in the middle
(a long bipyramid, 100 high x 10 wide). Edges bevelled (lighter); windows, vents, doors and ports are engraved outlines that taper
with the walls, with the outermost segment at each tip left plain.

## Interactive viewer

`ship_ref/viewer.html` - one self-contained page (open it by double-click, no server, no internet). All models, with the same
lighting and contour lines as the sheets: drag to rotate, right-drag / Shift-drag to pan, wheel to zoom, buttons for the
preset views, sliders for azimuth / elevation / zoom, background (dark / white / black / transparent / custom). The yellow frame is
exactly what "Zrób snapshot (PNG)" saves, at the size you type (2x smoothed); "Kopiuj do schowka" puts it on the clipboard.
Regenerate after changing any model: `python tools/ship_ref/build_viewer.py` (needs numpy; the page itself needs a WebGL2 browser).
