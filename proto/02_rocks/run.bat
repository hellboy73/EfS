@echo off
rem Build the bench and launch madsim with the monitor already on its side.
d:
cd D:\GitHub\EfS\proto\02_rocks
make
cd D:\GitHub\EfS
madsim.exe --tate --gpu roms\gpu_os.bin --cpu1 roms\cpu_os.bin --cart proto\02_rocks\proto02.bin
