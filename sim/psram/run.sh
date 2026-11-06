#!/usr/bin/env bash
# Run the actual PSRAM controller/bridge against the external-pin memory model.
# sim/psram/run.sh [sweep] [+model_plusarg ...]
set -euo pipefail
cd "$(dirname "$0")/../.."
source "$PWD/env.sh"
mkdir -p build/sim_psram
freq=${MEM_FREQ:-81000000}
stress=${STRESS:-0}
out=build/sim_psram/tb-$freq-$stress.vvp
iverilog -g2012 -Wall -Wno-timescale -s tb -Ptb.MEM_FREQ="$freq" -Ptb.STRESS="$stress" -o "$out" \
    rtl/psram_controller.v rtl/psram_bridge.v rtl/psram_test.v sim/psram/stress.v \
    sim/psram/hyperram_model.v sim/psram/tb_psram.v
if [[ ${1:-} == sweep ]]; then
    shift
    for tckd in 1000 3000 5500; do
        for pin in 0 1000 2000 3000 4000; do
            printf 'tCKD=%s ps, pin delay=%s ps each way: ' "$tckd" "$pin"
            vvp -n "$out" +dev_verbose=0 +tdsv_ps=8000 +tckd_ps="$tckd" \
                +pin_out_ps="$pin" +pin_in_ps="$pin" "$@" | grep '^RESULT'
        done
    done
else
    vvp -n "$out" +dev_verbose=0 "$@"
fi
