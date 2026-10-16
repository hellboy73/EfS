@echo off
rem Build the v0.7 alpha demo (DEMO=1) and launch madsim with the monitor on its side.
rem -B because make does not track DEMO: switching between this and run.bat needs a full rebuild.
d:
cd D:\GitHub\EfS
make DEMO=1 -B
if errorlevel 1 (
    pause
    exit /b 1
)
madsim.exe --mix 0 --tate --gpu roms\gpu_os.bin --cpu1 roms\cpu_os.bin --cart cart.bin
