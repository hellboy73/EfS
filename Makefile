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
          src/shots.s src/sfx.s src/window.s src/music.s
DATA    = src/shapes.s src/levels.s src/radar_bg.s src/ship32.s src/flames.s

# The song. vgmstrip.py removes the VGM header and the GD3 tag - vgm_play does
# no header parsing, it executes commands from the address it is given - and
# emits the loop anchor as an assembler constant in a sibling .inc. Both are
# build outputs and gitignored; src/music.s takes them back out at MUSIC_ON=0.
MUSIC   = assets/vgm/song_stream.bin assets/vgm/song_stream.inc
DEPS    = $(UNITS) $(MODULES) $(DATA) $(MUSIC) src/mad65.inc cart.cfg

all: $(CART)

$(CART): $(DEPS)
	cl65 -t none -C cart.cfg -o $@ $(UNITS)

run: $(CART)
	./madsim.exe --tate --gpu roms/gpu_os.bin --cpu1 roms/cpu_os.bin --cart $(CART)

# Builds the cart itself first (preview.py runs make), so this is safe to call
# on a clean tree.
preview:
	python tools/preview.py

assets/vgm/%_stream.bin: assets/vgm/%.vgm tools/vgmstrip.py
	python tools/vgmstrip.py $< $@ $*

# ...and the .inc is a CO-PRODUCT of that same run, not a second one.
assets/vgm/%_stream.inc: assets/vgm/%_stream.bin ;

clean:
	rm -f $(CART) *.o src/*.o assets/vgm/*_stream.bin assets/vgm/*_stream.inc    # cl65 names its intermediates <src>.<pid>.<n>.o

.PHONY: all run preview clean
