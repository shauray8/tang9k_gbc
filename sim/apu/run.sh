#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/env.sh"
mkdir -p "$root/build/apu"
iverilog -g2012 -o "$root/build/apu/tb" "$root/rtl/apu.v" "$root/sim/apu/tb_apu.v"
vvp "$root/build/apu/tb"
