#!/usr/bin/env python3
"""Run Mooneye Test Suite ROMs on the RTL core (build/obj/Vgb) and summarise pass/fail.

usage: sim/mooneye.py <mts directory> [subdir ...]
Results use the suite's serial protocol (sim/tb.cpp). Suffixes name the hardware a test
targets; this core is a CGB, so -C / -cgb / unsuffixed tests apply and DMG/SGB/AGB-only
variants are reported separately as not applicable.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
VGB = ROOT / 'build/obj/Vgb'


def applies(name):
    """Mooneye model tags: upper-case groups (C = CGB, A = AGB, S = SGB, G = DMG...) or
    explicit revisions (dmg0, mgb, cgb0, cgbABCDE). This core is a CGB."""
    m = re.search(r'-([A-Za-z0-9]+)$', name)
    if not m:
        return True
    tag = m.group(1)
    return tag.lower().startswith('cgb') or (tag.isupper() and 'C' in tag)


def run(rom):
    try:
        r = subprocess.run([str(VGB), str(rom), '1200', os.devnull], capture_output=True,
                           text=True, errors='replace', timeout=600)
        out = r.stdout
    except subprocess.TimeoutExpired:
        return rom, 'TIMEOUT'
    if '\nPassed' in out or out.rstrip().endswith('Passed'):
        return rom, 'pass'
    if 'Failed' in out:
        return rom, 'FAIL'
    return rom, 'NO RESULT'


def main():
    base = Path(sys.argv[1])
    dirs = sys.argv[2:] or ['acceptance', 'emulator-only', 'misc']
    roms = sorted(p for d in dirs for p in (base / d).rglob('*.gb'))
    with ThreadPoolExecutor(os.cpu_count()) as pool:
        results = list(pool.map(run, roms))
    groups = {}
    for rom, status in results:
        rel = rom.relative_to(base)
        key = 'n/a' if not applies(rom.stem) else status
        groups.setdefault(key, []).append(str(rel))
    for key in ('pass', 'FAIL', 'NO RESULT', 'TIMEOUT', 'n/a'):
        items = groups.get(key, [])
        print(f'{key}: {len(items)}')
        if key != 'pass' and key != 'n/a':
            for item in items:
                print('   ', item)


if __name__ == '__main__':
    main()
