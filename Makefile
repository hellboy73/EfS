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
MODULES = src/math.s src/input.s src/camera.s src/ship.s src/objects.s \
          src/physics.s src/stars.s src/occlude.s src/hud.s src/radar.s
DATA    = src/shapes.s src/levels.s src/radar_bg.s src/ship32.s
DEPS    = $(UNITS) $(MODULES) $(DATA) src/mad65.inc cart.cfg

all: $(CART)

$(CART): $(DEPS)
	cl65 -t none -C cart.cfg -o $@ $(UNITS)

run: $(CART)
	./madsim.exe --tate --gpu roms/gpu_os.bin --cpu1 roms/cpu_os.bin --cart $(CART)

# Builds the cart itself first (preview.py runs make), so this is safe to call
# on a clean tree.
preview:
	python tools/preview.py

clean:
	rm -f $(CART) *.o src/*.o    # cl65 names its intermediates <src>.<pid>.<n>.o

.PHONY: all run preview clean
