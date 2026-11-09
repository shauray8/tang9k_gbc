#!/usr/bin/python3
"""Run the memory stress ROM on the connected FPGA and report its counters.

  /usr/bin/python3 sim/hwstress/run.py [seconds]      (default 120)

Builds build/hwstress/stress.gbc if needed, loads it without the boot ROM, then reads the
pass and mismatch counters from cartridge RAM every few seconds (a short freeze each time).
Exit status 0 only if passes keep increasing and no byte ever mismatched. A stalled pass
counter means the CPU crashed (a corrupted opcode fetch), which also fails the run.
"""
import os
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host'))
import gbctl  # noqa: E402
import saves  # noqa: E402

ROM = ROOT / 'build/hwstress/stress.gbc'


def counters(link):
    gbctl.core_pause(link, 1)
    try:
        d = gbctl.read_memory(link, saves.RAM_BASE, 16)
    finally:
        gbctl.core_pause(link, 0)
    passes, errors = struct.unpack('<II', d[:8])
    return d[13:15] == b'OK', passes, errors, d[8:13]


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 120
    subprocess.run(['bash', str(ROOT / 'sim/hwstress/build.sh')], check=True, stdout=subprocess.DEVNULL)
    os.environ['GB_BOOT'] = 'off'
    link = gbctl.Link()
    try:
        gbctl.load(link, str(ROM))
        time.sleep(3)
        started, last_passes, stalls = time.monotonic(), -1, 0
        ok = True
        while time.monotonic() - started < seconds:
            running, passes, errors, last = counters(link)
            print(f'{time.monotonic() - started:6.0f}s  passes {passes}  mismatches {errors}'
                  + (f'  last: bank {last[0]:02x} addr {last[2]:02x}{last[1]:02x} rom {last[3]:02x}'
                     f' vram {last[4]:02x}' if errors else ''), flush=True)
            if not running:
                print('stress ROM is not running (signature missing)'); ok = False; break
            stalls = stalls + 1 if passes == last_passes else 0
            if stalls >= 3:
                print('pass counter stalled: the CPU crashed'); ok = False; break
            if errors:
                ok = False
            last_passes = passes
            time.sleep(10)
        print('STRESS PASS' if ok else 'STRESS FAIL')
        return 0 if ok else 1
    finally:
        link.close()


if __name__ == '__main__':
    sys.exit(main())
