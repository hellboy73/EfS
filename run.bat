@echo off
rem Build the full cartridge (DEMO=0: MINING ZONE, trainer on) and launch madsim with the monitor on its side.
rem -B because make does not track DEMO: without it a cart.bin left by run_alfa.bat is reused as is.
d:
cd D:\GitHub\EfS
make DEMO=0 -B
if errorlevel 1 (
    pause
    exit /b 1
)
madsim.exe --mix 0 --tate --gpu roms\gpu_os.bin --cpu1 roms\cpu_os.bin --cart cart.bin
