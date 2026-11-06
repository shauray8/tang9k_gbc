#!/usr/bin/env bash
# Behavioral test of the PPU colour path (colour RAM registers + CGB/DMG pixel stream vs a reference
# model). Prints "RESULT PASS".
set -euo pipefail
cd "$(dirname "$0")/../.."
source "$PWD/env.sh"
mkdir -p build/sim_color
out=build/sim_color/tb.vvp
iverilog -g2012 -Wall -Wno-timescale -s tb -o "$out" rtl/ppu.v sim/color/tb_ppu_color.v
vvp -n "$out"
