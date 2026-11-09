#!/usr/bin/env bash
# Builds build/hwstress/stress.gbc: the stress program in bank 0, random data in banks 1-63
# (1 MiB, MBC5 + RAM + battery, 8 KiB RAM for the counters).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=build/hwstress
mkdir -p "$out"
rgbasm -o "$out/stress.o" sim/hwstress/stress.asm
rgblink -p 0xFF -o "$out/code.gb" "$out/stress.o"
python3 - "$out/code.gb" "$out/stress.gbc" <<'EOF'
import random, sys
code = open(sys.argv[1], 'rb').read()
image = bytearray(code[:0x4000].ljust(0x4000, b'\xff'))
rnd = random.Random(20261109)
image += bytes(rnd.randrange(256) for _ in range(63 * 0x4000))
open(sys.argv[2], 'wb').write(image)
EOF
rgbfix -C -v -m 0x1B -r 2 -t STRESS -p 0xFF "$out/stress.gbc" >/dev/null
echo "$out/stress.gbc"
