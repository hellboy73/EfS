@echo off
rem Build the cartridge and launch madsim with the monitor already on its side.
d:
cd D:\GitHub\EfS
make
madsim.exe --tate --gpu roms\gpu_os.bin --cpu1 roms\cpu_os.bin --cart cart.bin
