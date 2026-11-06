#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source "$PWD/env.sh"
mkdir -p build/sim_video
verilator --binary --timing --top-module tb -Wno-fatal -Wno-WIDTH \
    --Mdir "$PWD/build/sim_video" rtl/video_buffer.v sim/video/tb_video.v
for phase in 0 9000 18000; do
    build/sim_video/Vtb +phase="$phase"
done
