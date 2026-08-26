# =============================================================================
# EfS proto 01 — flight model bench
# =============================================================================
# Build:  make            -> proto01.bin (exactly 8192 bytes)
# Run:    make run        -> launches madsim with the monitor already on its side
# =============================================================================

ROOT = ../..

all: proto01.bin

proto01.bin: header.s bootstrap.s main.s ship32.s mad65.inc cart.cfg
	cl65 -t none -C cart.cfg -o $@ header.s bootstrap.s main.s

run: proto01.bin
	cd $(ROOT) && ./madsim.exe --tate --gpu roms/gpu_os.bin --cpu1 roms/cpu_os.bin \
	    --cart proto/01_flight/proto01.bin

clean:
	rm -f proto01.bin *.o          # cl65 names its intermediates <src>.<pid>.<n>.o

.PHONY: all run clean
