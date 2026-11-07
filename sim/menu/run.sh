#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source "$PWD/env.sh"
mkdir -p build/menu-tests
iverilog -g2012 -s tb_bridge -o build/menu-tests/bridge.vvp rtl/menu_bridge.v sim/menu/tb_bridge.v
vvp build/menu-tests/bridge.vvp
python3 sim/menu/test_menu.py
