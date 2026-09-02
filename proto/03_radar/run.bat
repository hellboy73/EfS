@echo off
rem Build the bench and launch madsim with the monitor already on its side.
d:
cd D:\GitHub\EfS\proto\03_radar
make
cd D:\GitHub\EfS
madsim.exe --tate --gpu roms\gpu_os.bin --cpu1 roms\cpu_os.bin --cart proto\03_radar\proto03.bin
