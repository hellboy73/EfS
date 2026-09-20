# =============================================================================
# Escape from Saturn — the cartridge
# =============================================================================
# Build:    make              -> cart.bin (two 8 KB banks = 16384 bytes)
# Run:      make run          -> launches madsim with the monitor on its side
# Check:    make preview      -> the headless end-to-end run + preview.png
# =============================================================================
# The sources live in src/ and the build happens HERE, at the root, because the
# cartridge is one image and the paths it needs — roms/, assets/ — hang off the
# root too. proto/ is frozen; nothing in this build reads from it.

CART  = cart.bin

# What cl65 is HANDED. main.s pulls every module in with .include, so only
# these three are translation units.
UNITS = src/header.s src/bootstrap.s src/main.s

# What cl65 READS. Everything main.s includes, so touching any of it rebuilds.
MODULES = src/math.s src/input.s src/camera.s src/ship.s src/thrust.s \
          src/objects.s src/physics.s src/stars.s src/occlude.s src/hud.s \
          src/hud_game.s src/gameover.s src/debris.s src/radar.s \
          src/shots.s src/foes.s src/laser.s src/sfx.s src/window.s \
          src/music.s src/satn.s src/cam.s src/hiscore.s src/screens.s \
          src/pulsar.s src/emp.s src/shield.s src/trainer.s src/gate.s \
          src/pickup.s src/sprites.s src/base.s
DATA    = src/shapes.s src/enemies.s src/levels.s src/radar_bg.s \
          src/flames.s src/arrows.s src/screens_art.s src/scroller_text.s \
          src/pickups_art.s

# The song. vgmstrip.py removes the VGM header and the GD3 tag - vgm_play does
# no header parsing, it executes commands from the address it is given - and
# emits the loop anchor as an assembler constant in a sibling .inc. Both are
# build outputs and gitignored; src/music.s takes them back out at MUSIC_ON=0.
#
# TEMPORARY: the title-theme sketch stands in for music until there is some.
TITLE_VGM = assets/vgm/efs_title_theme_sketch_rearranged10.vgm
MUSIC   = assets/vgm/title_stream.bin assets/vgm/title_stream.inc
DEPS    = $(UNITS) $(MODULES) $(DATA) $(MUSIC) src/mad65.inc cart.cfg

all: $(CART)

# cart.lbl is the linker's LABEL file: every symbol at its RUN address. It is
# there for tools/preview.py, whose benches call real routines by name
# (rock_destroy, foe_kill) instead of poking the state those routines would
# have left behind - which is how a bench ends up agreeing with itself.
$(CART): $(DEPS)
	cl65 -g -t none -C cart.cfg -o $@ -Ln cart.lbl $(UNITS)

run: $(CART)
	./madsim.exe --tate --gpu roms/gpu_os.bin --cpu1 roms/cpu_os.bin --cart $(CART)

# Builds the cart itself first (preview.py runs make), so this is safe to call
# on a clean tree.
preview:
	python tools/preview.py

assets/vgm/%_stream.bin: assets/vgm/%.vgm tools/vgmstrip.py
	python tools/vgmstrip.py $< $@ $*

assets/vgm/title_stream.bin: $(TITLE_VGM) tools/vgmstrip.py
	python tools/vgmstrip.py $< $@ title

# The screens' pictures. The output is tracked, like radar_bg.s and arrows.s;
# this rule only keeps it in step with the PNGs.
# The placements (@X0,Y0 in portrait) and band heights (/rows) are the layout.
LOGO_PNG  = assets/png/bitmaps/MAD65_logo.png
TITLE_PNG = assets/png/bitmaps/efs_title_scr.png
src/screens_art.s: $(LOGO_PNG) $(TITLE_PNG) tools/artgen.py tools/bggen.py
	python tools/artgen.py $@ LOGO=$(LOGO_PNG)@22,160/128 TITLE=$(TITLE_PNG)@0,0/15

# The pickup's sprite, every animation frame (pickup.s). Tracked, like arrows.s.
# PICKUP_SET picks the set: assets/png/<set>1.png, <set>2.png, ... as far as they go.
PICKUP_SET = bonusbox
PICKUP_PNG = $(wildcard assets/png/$(PICKUP_SET)[0-9].png)
src/pickups_art.s: $(PICKUP_PNG) tools/pickupgen.py tools/sprgen.py Makefile
	python tools/pickupgen.py $(PICKUP_SET)

# ...and the .inc is a CO-PRODUCT of that same run, not a second one.
assets/vgm/%_stream.inc: assets/vgm/%_stream.bin ;

clean:
	rm -f $(CART) cart.lbl *.o src/*.o assets/vgm/*_stream.bin assets/vgm/*_stream.inc    # cl65 names its intermediates <src>.<pid>.<n>.o

.PHONY: all run preview clean
