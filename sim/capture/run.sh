#!/usr/bin/env bash
# Behavioral test of the headless line capture + UART TX backpressure. Prints "RESULT PASS".
set -euo pipefail
cd "$(dirname "$0")/../.."
source "$PWD/env.sh"
mkdir -p build/sim_capture
out=build/sim_capture/tb.vvp
iverilog -g2012 -Wall -Wno-timescale -s tb -o "$out" \
    rtl/line_capture.v rtl/uart_tx.v rtl/uart_rx.v sim/capture/tb_line_capture.v
vvp -n "$out"
