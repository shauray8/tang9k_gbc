#!/usr/bin/env bash
# Overlay controller checks and a rendered panel (build/overlay.ppm).
set -euo pipefail
cd "$(dirname "$0")/../.."
source "$PWD/env.sh" >/dev/null
mkdir -p build
iverilog -g2012 -Wall -Irtl -s tb -o build/tb_overlay.vvp sim/overlay/tb_overlay.v rtl/overlay.v
vvp -n build/tb_overlay.vvp
