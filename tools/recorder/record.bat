@echo off
rem Serve the repo root and open the input recorder on the current cart.bin.
rem Build first (make) - the recorder plays whatever cart.bin is on disk.
cd /d "%~dp0..\.."
start "" http://localhost:8139/tools/recorder/recorder.html
python -m http.server 8139
