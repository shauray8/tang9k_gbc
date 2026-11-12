#!/bin/bash
set -e
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."
source "$root/env.sh"
mkdir -p "$root/build/timer"
iverilog -g2012 -o "$root/build/timer/tb_timer.vvp" "$root/rtl/timer.v" "$here/tb_timer.v"
vvp "$root/build/timer/tb_timer.vvp"
