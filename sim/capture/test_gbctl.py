#!/usr/bin/env python3
"""Behavioral test of host/gbctl.py screenshot / screenshot-color against a fake USB-UART bridge.

The fake implements the board's 'V'/'W' line protocol independently and returns replies split at
random over several bulk transfers of 64-byte FTDI packets (2 status bytes each), so the real
Link.read() reassembly, reply validation, retries, error reporting and RGB555 expansion are all
exercised. Prints "HOST PASS".
"""
import ctypes, os, random, re, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "host"))
import gbctl  # noqa: E402


class FakeBridge:
    """Stands in for libusb: EP_OUT carries 2-byte line requests, EP_IN returns queued replies."""

    def __init__(self, rng, screen, shades, errors=None, garble=None):
        self.rng, self.screen, self.shades = rng, screen, shades
        self.errors = errors or {}          # y -> error code ('v' reply)
        self.garble = garble or {}          # y -> list of bad replies sent before the good one
        self.pending = bytearray()
        self.reqs = []

    def reply(self, cmd, y):
        if y in self.errors:
            return b"v" + bytes([self.errors[y]])
        if self.garble.get(y):
            return self.garble[y].pop(0)
        if cmd == ord("W"):
            return good_w(self.screen, y)
        if cmd == ord("V"):
            data = bytes(self.shades[y][x] << 6 | self.shades[y][x + 1] << 4 |
                         self.shades[y][x + 2] << 2 | self.shades[y][x + 3] for x in range(0, 160, 4))
            return b"V" + bytes([y]) + data + bytes([sum(data) & 0xFF])
        return b""

    def libusb_bulk_transfer(self, h, ep, buf, size, nref, timeout):
        if ep == gbctl.EP_OUT:
            data = buf.raw[:size]
            assert size % 2 == 0, f"odd-length request {data!r}"
            for i in range(0, size, 2):
                self.reqs.append((chr(data[i]), data[i + 1]))
                self.pending += self.reply(data[i], data[i + 1])
            nref._obj.value = size
            return 0
        out = b""
        for _ in range(self.rng.randint(0, 6)):              # full packets: 2 status + 62 data
            if len(self.pending) < 62:
                break
            out += b"\x31\x60" + bytes(self.pending[:62])
            del self.pending[:62]
        m = self.rng.randint(0, min(61, len(self.pending)))  # short packet ends the transfer
        out += b"\x31\x60" + bytes(self.pending[:m])
        del self.pending[:m]
        assert len(out) <= size
        ctypes.memmove(buf, out, len(out))
        nref._obj.value = len(out)
        return 0


def good_w(screen, y):
    data = b"".join(c.to_bytes(2, "little") for c in screen[y])
    return b"W" + bytes([y]) + data + bytes([sum(data) & 0xFF])


def make_link(bridge):
    link = gbctl.Link.__new__(gbctl.Link)     # skip USB open; Link.write/read stay real
    link.L, link.h = bridge, None
    return link


def expand(v):                                 # 5-bit channel -> 8-bit by bit replication
    return v * 8 + v // 4


def read_ppm(path):
    raw = open(path, "rb").read()
    header = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", raw)
    assert header and tuple(map(int, header.groups())) == (160, 144, 255)
    px = raw[header.end():]
    assert len(px) == 160 * 144 * 3, len(px)
    return px


def expect_exit(fn, output):
    try:
        fn()
    except SystemExit:
        assert not os.path.exists(output), "failed capture wrote a partial image"
        return
    raise AssertionError("expected SystemExit")


def main():
    rng = random.Random(1)
    screen = [[rng.randrange(0x8000) for _ in range(160)] for _ in range(144)]
    screen[0][0], screen[0][1] = 0x7FFF, 0x0000
    for x in range(32):                         # line 1: every level of R, then G, then B
        screen[1][x], screen[1][32 + x], screen[1][64 + x] = x, x << 5, x << 10
    shades = [[rng.randrange(4) for _ in range(160)] for _ in range(144)]
    temp = tempfile.TemporaryDirectory()
    tmp = temp.name

    # Color screenshot: exact decode of every pixel, with garbled replies retried.
    bad_sum = bytearray(good_w(screen, 5)); bad_sum[-1] ^= 1
    bit15 = bytearray(good_w(screen, 6)); bit15[3 + 2 * 17] |= 0x80; bit15[-1] = (bit15[-1] + 0x80) & 0xFF
    wrong_y = bytearray(good_w(screen, 7)); wrong_y[1] = 8
    wrong_cmd = bytearray(good_w(screen, 11)); wrong_cmd[0] = ord("V")
    garble = {5: [bytes(bad_sum)], 6: [bytes(bit15)], 7: [bytes(wrong_y)],
              8: [good_w(screen, 8)[:200]],                          # truncated reply
              9: [bytes(bad_sum), bytes(bad_sum)],                   # good on the 3rd attempt
              10: [b"\x00" + good_w(screen, 10)],                    # stale byte in front
              11: [bytes(wrong_cmd)]}
    br = FakeBridge(rng, screen, shades, garble=garble)
    out = os.path.join(tmp, "color.ppm")
    gbctl.screenshot_color(make_link(br), out)
    px = read_ppm(out)
    for y in range(144):
        for x in range(160):
            c = screen[y][x]
            want = bytes((expand(c & 31), expand(c >> 5 & 31), expand(c >> 10 & 31)))
            got = px[(y * 160 + x) * 3:(y * 160 + x) * 3 + 3]
            assert got == want, f"color pixel ({x},{y}) = {c:#06x}: got {got.hex()} want {want.hex()}"
    assert px[:6] == b"\xff\xff\xff\x00\x00\x00"

    # Legacy screenshot: unchanged 'V' protocol and DMG shade palette.
    br = FakeBridge(rng, screen, shades)
    out = os.path.join(tmp, "dmg.ppm")
    gbctl.screenshot(make_link(br), out)
    px = read_ppm(out)
    assert px == b"".join(gbctl.SHADES[shades[y][x]] for y in range(144) for x in range(160))

    # Errors: device error codes are reported with the line, persistent garbage gives up.
    for code in (1, 2, 3, 4, 9):
        br = FakeBridge(rng, screen, shades, errors={40: code})
        output = os.path.join(tmp, f"error-{code}.ppm")
        expect_exit(lambda: gbctl.screenshot_color(make_link(br), output), output)
    br = FakeBridge(rng, screen, shades, garble={3: [bytes(bad_sum)] * 3})
    output = os.path.join(tmp, "corrupt.ppm")
    expect_exit(lambda: gbctl.screenshot_color(make_link(br), output), output)
    br = FakeBridge(rng, screen, shades, errors={0: 2})
    output = os.path.join(tmp, "lcd-off.ppm")
    expect_exit(lambda: gbctl.screenshot(make_link(br), output), output)
    print("HOST PASS")


if __name__ == "__main__":
    main()
