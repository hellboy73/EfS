@echo off
rem Build the TUNNEL-ONLY image and launch madsim on it: it powers on straight into
rem the tunnel (no intro, no title, no sector) and flies it again and again - FIRE
rem restarts it. The real cart.bin is not touched.
d:
cd D:\GitHub\EfS
make tunnel.bin
madsim.exe --mix 0 --tate --gpu roms\gpu_os.bin --cpu1 roms\cpu_os.bin --cart tunnel.bin
