#!/usr/bin/env bash
# Behavioral test of the headless line capture ('V' 2-bit and 'W' RGB555 replies) + UART TX
# backpressure, then of the host screenshot decoders against a fake USB bridge.
# Prints "RESULT PASS" (RTL) and "HOST PASS" (host/gbctl.py).
set -euo pipefail
cd "$(dirname "$0")/../.."
source "$PWD/env.sh"
mkdir -p build/sim_capture
out=build/sim_capture/tb.vvp
iverilog -g2012 -Wall -Wno-timescale -s tb -o "$out" \
    rtl/line_capture.v rtl/uart_tx.v rtl/uart_rx.v sim/capture/tb_line_capture.v
vvp -n "$out"
python3 sim/capture/test_gbctl.py
