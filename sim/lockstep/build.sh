#!/bin/bash
# Builds both sides of the lockstep frame comparison:
#   build/lockstep-obj/Vgb      our core, verilated from a snapshot of rtl/ (build/lockstep-rtl)
#   build/lockstep/sameboy_hash SameBoy reference harness
# SameBoy lives outside the repo: SAMEBOY_DIR (default ../tools-ref/SameBoy, tag v1.0.5); this
# script runs its "make lib bootroms" (needs rgbds) when the library or boot ROM is missing.
# usage: sim/lockstep/build.sh [--no-snapshot]   (--no-snapshot reuses build/lockstep-rtl as is)
set -e
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
sb="${SAMEBOY_DIR:-$root/../tools-ref/SameBoy}"
source "$root/env.sh"
mkdir -p "$root/build/lockstep"

if [ ! -f "$sb/build/lib/libsameboy.a" ] || [ ! -f "$sb/build/bin/BootROMs/cgb_boot.bin" ]; then
  make -C "$sb" -j8 lib bootroms CONF=release >/dev/null
fi
cc -O2 -std=gnu11 -D_GNU_SOURCE -I"$sb" -o "$root/build/lockstep/sameboy_hash" \
  "$here/sameboy_hash.c" "$sb/build/lib/libsameboy.a" -lm

if [ "$1" != "--no-snapshot" ] || [ ! -d "$root/build/lockstep-rtl" ]; then
  rm -rf "$root/build/lockstep-rtl"; cp -R "$root/rtl" "$root/build/lockstep-rtl"
  cp "$root/sim/tb.cpp" "$root/build/lockstep-rtl/tb.cpp"
  { git -C "$root" rev-parse --short HEAD; git -C "$root" diff --stat -- rtl sim/tb.cpp
    echo "worktree diff sha1 $(git -C "$root" diff -- rtl sim/tb.cpp | shasum | cut -c1-12)"; } \
    > "$root/build/lockstep-rtl/SNAPSHOT"
  git -C "$root" diff -- rtl sim/tb.cpp > "$root/build/lockstep-rtl/worktree.diff"
fi
cat "$root/build/lockstep-rtl/SNAPSHOT"
src="$root/build/lockstep-rtl"
verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE \
  --top-module gb -Mdir "$root/build/lockstep-obj" \
  "$src/sm83.v" "$src/timer.v" "$src/ppu.v" "$src/mbc3_rtc.v" "$src/gb.v" "$src/tb.cpp" >/dev/null
echo "built $root/build/lockstep-obj/Vgb and $root/build/lockstep/sameboy_hash"
