#!/bin/bash
# usage: sim/hwstress/qualify.sh [-t seconds] <image.fs>...
# Loads each image into FPGA SRAM (flash untouched), prints the power-on memory self-test and
# round-trip latency from `gbctl diagnose`, then runs the memory stress ROM. Afterwards the board
# gets the known-good image back (GOOD, default ../build/gb-working-bootrom.fs).
# Stop the game library first: it holds the USB link.
set -u
cd "$(dirname "$0")/../.."
source env.sh >/dev/null
SECONDS_EACH=120
[ "${1:-}" = -t ] && { SECONDS_EACH=$2; shift 2; }
GOOD=${GOOD:-../build/gb-working-bootrom.fs}
summary=()
for fs in "$@"; do
  echo "=== $fs"
  if ! openFPGALoader -b tangnano9k --freq 1000000 "$fs" >/dev/null 2>&1; then
    summary+=("$fs: program failed"); continue
  fi
  sleep 3
  /usr/bin/python3 host/gbctl.py diagnose 2>&1 | head -6
  if /usr/bin/python3 sim/hwstress/run.py "$SECONDS_EACH"; then
    summary+=("$fs: PASS")
  else
    summary+=("$fs: FAIL")
  fi
done
echo "=== restoring $GOOD"
openFPGALoader -b tangnano9k --freq 1000000 "$GOOD" >/dev/null 2>&1 || echo "restore failed"
printf '%s\n' "${summary[@]}"
