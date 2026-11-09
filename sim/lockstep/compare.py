#!/usr/bin/env python3
"""Lockstep frame comparison of our core (Verilator) against SameBoy.

Both sides write one line per vblank: "event vsyncs ticks kind fnv1a64" (see sim/tb.cpp
GB_FRAME_HASH and sim/lockstep/sameboy_hash.c). Kinds: N rendered, F first frame after LCD on,
R CGB repeat frame, O LCD-off white frame, A artificial. F/R frames are not compared by content:
SameBoy blanks (or repeats) the first frame after LCD on like hardware, our core renders it.
A frames (SameBoy pushes one when the LCD is switched on, to pace its frontend) are dropped.

  compare.py run <rom> <schedule> <frames> <outdir>   run both emulators, then compare
  compare.py diff <ours.hash> <sameboy.hash> [--rom R --schedule S --outdir D [--our-init]]

`run` builds nothing: call sim/lockstep/build.sh first. It writes ours.hash, sb.hash (boot ROM
handoff) and sb-ourinit.hash (SameBoy forced to our reset state) and compares both pairs.
"""
import os
import struct
import subprocess
import sys
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
VGB = os.path.join(ROOT, 'build', 'lockstep-obj', 'Vgb')
SAMEBOY = os.path.join(ROOT, 'build', 'lockstep', 'sameboy_hash')
BOOT = os.environ.get('SAMEBOY_BOOT', os.path.join(ROOT, '..', 'tools-ref', 'SameBoy', 'build', 'bin',
                                                    'BootROMs', 'cgb_boot.bin'))

RIGHT, LEFT, UP, DOWN, A, B, SELECT, START = 1, 2, 4, 8, 16, 32, 64, 128


def _gameplay():
    # mash Start through intros/menus, then walk right while tapping A (jump/confirm)
    sched = [(f, f + 6, START) for f in range(300, 1500, 60)]
    sched += [(f, f + 6, A) for f in range(1500, 2400, 30)]
    sched += [(2400, 18000, RIGHT)]
    sched += [(f, f + 20, A) for f in range(2400, 18000, 90)]
    sched += [(f, f + 4, START) for f in range(6000, 18000, 3000)]  # unpause / skip dialogs
    return ','.join(f'{a}:{b}:{m}' for a, b, m in sched)


SCHEDULES = {'none': '', 'play': _gameplay()}

COMPARABLE = {'N', 'O'}
DRIFT_DOTS = 8


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            if not line.strip() or line.startswith('#'):
                continue
            ev, vs, ticks, kind, h = line.split()
            if kind != 'A':
                rows.append((int(ev), int(vs), int(ticks), kind, h))
    return rows


def best_offset(ours, sb, window=3, span=300):
    best = None
    for d in range(-window, window + 1):
        score = sum(1 for i in range(min(span, len(ours)))
                    if 0 <= i + d < len(sb) and ours[i][4] == sb[i + d][4])
        key = (score, -abs(d))
        if best is None or key > best[0]:
            best = (key, d)
    return best[1], best[0][0]


def compare(ours, sb):
    d, score = best_offset(ours, sb)
    pairs = [(o, sb[i + d]) for i, o in enumerate(ours) if 0 <= i + d < len(sb)]
    res = {'offset': d, 'offset_score': score, 'pairs': len(pairs), 'match': 0, 'skipped': 0,
           'mismatch': 0, 'first': None, 'kind_mismatch': 0, 'shifts': []}
    # Per-frame tick delta between the two vblank events; it only moves when the PPU restarts (LCD
    # off/on) at a different CPU time, i.e. when the CPU-side timing differs.
    prev = res['tick_delta0'] = pairs[0][0][2] - pairs[0][1][2] if pairs else 0
    for o, s in pairs:
        if o[3] == s[3] == 'N':
            delta = o[2] - s[2]
            if abs(delta - prev) > DRIFT_DOTS:
                res['shifts'].append((o, s, delta, delta - prev))
            prev = delta
        if o[3] not in COMPARABLE or s[3] not in COMPARABLE:
            res['skipped'] += 1
            continue
        if o[3] == s[3] and o[4] == s[4]:
            res['match'] += 1
            continue
        res['mismatch'] += 1
        res['kind_mismatch'] += o[3] != s[3]
        if res['first'] is None:
            res['first'] = (o, s)
    # rendered frames only, in order: survives a different number of LCD-off frames in between
    on, sn = [r for r in ours if r[3] == 'N'], [r for r in sb if r[3] == 'N']
    rd, _ = best_offset(on, sn)
    rp = [(o, sn[i + rd]) for i, o in enumerate(on) if 0 <= i + rd < len(sn)]
    rfirst = next(((o, s) for o, s in rp if o[4] != s[4]), None)
    res['rendered'] = {'offset': rd, 'pairs': len(rp), 'match': sum(o[4] == s[4] for o, s in rp),
                       'first': rfirst}
    return res


def fmt_row(r):
    return f'event {r[0]} (vsync frame {r[1]}, tick {r[2]}, kind {r[3]})'


def report(name, res):
    out = [f'== {name}',
           f'offset {res["offset"]:+d} (sameboy event = ours + offset; {res["offset_score"]}/300 early hashes agree), '
           f'{res["pairs"]} frames compared: {res["match"]} match, {res["mismatch"]} mismatch '
           f'({res["kind_mismatch"]} kind mismatches), {res["skipped"]} first-after-LCD-on/repeat frames skipped']
    if res['first']:
        o, s = res['first']
        out.append(f'first mismatch: ours {fmt_row(o)} vs sameboy {fmt_row(s)}')
    else:
        out.append(f'identical for {res["match"]} compared frames')
    out.append(f'tick delta ours-sameboy at first pair: {res["tick_delta0"]} dots; '
               f'{len(res["shifts"])} later shifts >{DRIFT_DOTS} dots')
    for o, s, dl, ch in res['shifts'][:3]:
        out.append(f'  shift {ch:+d} -> {dl}: ours {fmt_row(o)} vs sameboy {fmt_row(s)}')
    r = res['rendered']
    out.append(f'rendered-only: offset {r["offset"]:+d}, {r["pairs"]} frames, {r["match"]} match'
               + (f', first mismatch ours {fmt_row(r["first"][0])} vs sameboy {fmt_row(r["first"][1])}'
                  if r['first'] else ', identical'))
    return '\n'.join(out)


def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    parts = data.split(maxsplit=4)
    assert parts[0] == b'P6'
    w, h = int(parts[1]), int(parts[2])
    pix = parts[4][:w * h * 3]
    return [tuple(pix[i:i + 3]) for i in range(0, len(pix), 3)]


def write_png(path, pixels, w=160, h=144):
    raw = b''.join(b'\0' + bytes(c for p in pixels[y * w:(y + 1) * w] for c in p) for y in range(h))

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


WHITE = [(255, 255, 255)] * (160 * 144)


def dump_frames(o, s, rom, schedule, outdir, our_init):
    """Re-runs both emulators up to the mismatching event and writes PNGs plus a diff summary."""
    env = dict(os.environ, GB_PRESS=SCHEDULES[schedule])
    tag = 'ourinit-' if our_init else ''
    op, sp = os.path.join(outdir, f'{tag}first-ours.ppm'), os.path.join(outdir, f'{tag}first-sameboy.ppm')
    if s[3] == 'O':
        sim = WHITE
    else:
        frames = s[2] // 70224 + 2
        subprocess.run([SAMEBOY] + (['--our-init'] if our_init else []) + ['--dump', f'{s[0]}:{sp}', BOOT, rom,
                       str(frames), os.devnull], env=env, check=True, stdout=subprocess.DEVNULL)
        sim = read_ppm(sp)
    if o[3] == 'O':
        ours = WHITE
    else:
        if not os.path.exists(op):  # identical for both pairings; the rerun is slow
            frames = o[2] // 70224 + 2
            subprocess.run([VGB, rom, str(frames), os.path.join(outdir, 'last-ours.ppm')],
                           env=dict(env, GB_FRAME_DUMP=f'{o[0]}:{op}'), check=True, stdout=subprocess.DEVNULL)
        ours = read_ppm(op)
    write_png(os.path.join(outdir, f'{tag}first-ours.png'), ours)
    write_png(os.path.join(outdir, f'{tag}first-sameboy.png'), sim)
    diff = [i for i in range(160 * 144) if ours[i] != sim[i]]
    write_png(os.path.join(outdir, f'{tag}first-diff.png'),
              [(255, 0, 0) if ours[i] != sim[i] else tuple(c // 3 for c in ours[i]) for i in range(160 * 144)])
    if not diff:
        return 'frame images identical (hash difference outside the image?)'
    xs, ys = [i % 160 for i in diff], [i // 160 for i in diff]
    rows = sorted(set(ys))
    sample = [(i % 160, i // 160, ours[i], sim[i]) for i in diff[:4]]
    return (f'{len(diff)} pixels differ, bbox x {min(xs)}..{max(xs)} y {min(ys)}..{max(ys)}, '
            f'{len(rows)} rows affected; samples (x,y,ours,sameboy): {sample}')


def run(rom, schedule, frames, outdir):
    os.makedirs(outdir, exist_ok=True)
    env = dict(os.environ, GB_PRESS=SCHEDULES[schedule])
    paths = {k: os.path.join(outdir, k + '.hash') for k in ('ours', 'sb', 'sb-ourinit')}
    for key, extra in (('sb', []), ('sb-ourinit', ['--our-init'])):
        with open(os.path.join(outdir, key + '.log'), 'w') as log:
            subprocess.run([SAMEBOY] + extra + [BOOT, rom, str(frames), paths[key]], env=env, check=True, stdout=log)
    if not os.path.exists(paths['ours']) or os.environ.get('LOCKSTEP_RERUN'):
        with open(os.path.join(outdir, 'ours.log'), 'w') as log:
            subprocess.run([VGB, rom, str(frames), os.path.join(outdir, 'last-ours.ppm')],
                           env=dict(env, GB_FRAME_HASH=paths['ours']), check=True, stdout=log, stderr=log)
    diff_cmd(paths['ours'], paths['sb'], rom, schedule, outdir, False)
    diff_cmd(paths['ours'], paths['sb-ourinit'], rom, schedule, outdir, True)


def diff_cmd(ours_path, sb_path, rom=None, schedule='none', outdir=None, our_init=False):
    res = compare(load(ours_path), load(sb_path))
    text = report(f'{os.path.basename(rom or ours_path)} schedule={schedule} '
                  f'{"sameboy forced to our reset state" if our_init else "sameboy boot ROM handoff"}', res)
    if res['first'] and rom and outdir:
        text += '\nfirst mismatch frames: ' + dump_frames(*res['first'], rom, schedule, outdir, our_init)
    print(text, flush=True)
    if outdir:
        with open(os.path.join(outdir, 'report-ourinit.txt' if our_init else 'report.txt'), 'w') as f:
            f.write(text + '\n')


def main(argv):
    if len(argv) >= 5 and argv[0] == 'run':
        run(os.path.abspath(argv[1]), argv[2], int(argv[3]), os.path.abspath(argv[4]))
    elif len(argv) >= 3 and argv[0] == 'diff':
        rest = [a for a in argv[3:] if a != '--our-init']
        opts = dict(zip(rest[::2], rest[1::2]))
        diff_cmd(argv[1], argv[2], opts.get('--rom'), opts.get('--schedule', 'none'), opts.get('--outdir'),
                 '--our-init' in argv[3:])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
