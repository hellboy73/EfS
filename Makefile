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
#
# The command line is deliberately the one proto 03 used, unchanged: the same
# sources through the same cart.cfg have to produce the same image, and that
# byte-identity is what says the move to src/ moved nothing else.

CART  = cart.bin

# What cl65 is HANDED. main.s pulls the rest in with .include, so only these
# three are translation units.
UNITS = src/header.s src/bootstrap.s src/main.s

# What cl65 READS. Everything main.s includes, so touching any of it rebuilds.
DEPS  = $(UNITS) src/shapes.s src/levels.s src/physics.s src/radar.s \
        src/radar_bg.s src/landmark.s src/ship32.s src/mad65.inc cart.cfg

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
