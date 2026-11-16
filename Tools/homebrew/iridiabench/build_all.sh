#!/bin/bash
# gc-emu: build every IridiaBench variant the Mac A/Bs use (scripts/mac_bench.sh).
set -e
export DEVKITPRO=${DEVKITPRO:-/opt/devkitpro}
export DEVKITPPC=${DEVKITPPC:-$DEVKITPRO/devkitPPC}
export PATH="$DEVKITPPC/bin:$DEVKITPRO/tools/bin:$PATH"
cd "$(dirname "$0")"
for scale in 1 4 16 32; do
  make -s -B SCALE=$scale
  make -s -B PLATFORM=wii SCALE=$scale
done
make -s -B PLATFORM=wii MEM2=1 SCALE=16
make -s -B PLATFORM=wii WPAD=1 SCALE=16
make -s -B FREERUN=1 SCALE=16
make -s -B PLATFORM=wii FREERUN=1 SCALE=16
make -s -B PLATFORM=wii FREERUN=1 MEM2=0 SCALE=4
make -s -B FREERUN=1 SCALE=4
ls -1 iridiabench-*.dol
