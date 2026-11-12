#!/bin/bash
# usage: sim/run.sh <rom.gb> [max_frames] [out.ppm]
set -e
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/.."
source "$root/env.sh"
rom="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; frames="${2:-600}"; out="${3:-$root/build/frame.ppm}"
mkdir -p "$root/build"
if [ ! -x "$root/build/obj/Vgb" ] || [ -n "$(find "$root/rtl" "$here/tb.cpp" -newer "$root/build/obj/Vgb")" ]; then
  verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE \
    --top-module gb -Mdir "$root/build/obj" \
    "$root"/rtl/sm83.v "$root"/rtl/timer.v "$root"/rtl/apu.v "$root"/rtl/ppu.v "$root"/rtl/mbc3_rtc.v "$root"/rtl/gb.v "$here/tb.cpp" >/dev/null
fi
"$root/build/obj/Vgb" "$rom" "$frames" "$out"
