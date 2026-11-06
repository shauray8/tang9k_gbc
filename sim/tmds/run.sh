#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source "$PWD/env.sh"
mkdir -p build/tmds
iverilog -g2012 -s tb -o build/tmds/tb.vvp rtl/hdmi.v sim/tmds/tb_tmds.v
vvp -n build/tmds/tb.vvp
