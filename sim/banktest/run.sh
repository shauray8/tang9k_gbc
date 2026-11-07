#!/bin/bash
# usage: sim/banktest/run.sh
# Generates synthetic DMG/CGB banking ROMs into build/banktest and runs them on the gb core.
set -e
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."
source "$root/env.sh"
out="$root/build/banktest"
mkdir -p "$out"
iverilog -g2012 -s tb_rtc -o "$out/rtc.vvp" "$root/rtl/mbc3_rtc.v" "$here/tb_rtc.v"
vvp "$out/rtc.vvp"
python3 "$here/mkrom.py" "$out"
verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE \
  --top-module gb -Mdir "$out/obj" \
  "$root"/rtl/sm83.v "$root"/rtl/timer.v "$root"/rtl/ppu.v "$root"/rtl/mbc3_rtc.v "$root"/rtl/gb.v "$here/tb.cpp" >/dev/null
rc=0
for r in bank_dmg bank_cgb bank_cgb_fast vram_dma_cgb vram_dma_cgb_fast mbc3_rtc mbc3_no_rtc mbc3_timer_only; do "$out/obj/Vgb" "$out/$r.gb" || rc=1; done
"$out/obj/Vgb" "$out/speed_cgb.gb" --wake-stop || rc=1
exit $rc
