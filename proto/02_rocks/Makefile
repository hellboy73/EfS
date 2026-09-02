# =============================================================================
# EfS proto 02 — rocks & collisions bench
# =============================================================================
# Build:  make            -> proto02.bin (exactly 8192 bytes)
# Run:    make run        -> launches madsim with the monitor already on its side
# =============================================================================

ROOT = ../..

all: proto02.bin

proto02.bin: header.s bootstrap.s main.s ship32.s mad65.inc cart.cfg
	cl65 -t none -C cart.cfg -o $@ header.s bootstrap.s main.s

run: proto02.bin
	cd $(ROOT) && ./madsim.exe --tate --gpu roms/gpu_os.bin --cpu1 roms/cpu_os.bin \
	    --cart proto/02_rocks/proto02.bin

clean:
	rm -f proto02.bin *.o          # cl65 names its intermediates <src>.<pid>.<n>.o

.PHONY: all run clean
