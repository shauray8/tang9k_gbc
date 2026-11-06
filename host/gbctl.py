#!/usr/bin/python3
"""Control the FPGA Game Boy over the Tang Nano 9K's on-board USB-UART (BL702, channel B).

The macOS serial driver for this bridge rejects configuration and can wedge the device, so this
talks to the bridge's UART endpoints directly over libusb (bundled with the toolchain).

  gbctl.py load game.gb    upload a .gb image to PSRAM (up to 3.875 MiB; lost on reset),
                           checksum-verified; ~11 s per 128 KB at 115200 baud
  gbctl.py status          print core/loader state (PSRAM ready, load progress, LCD, lock)
  gbctl.py diagnose        print boot-memory address, expected/actual bytes, and controller state
  gbctl.py scanout         read the completed HDMI game-window fingerprint and frame counter
  gbctl.py play            open a window; keyboard = joypad (window must have focus)
                           arrows = D-pad, Z = A, X = B, Enter = Start, Backspace/Shift = Select
  gbctl.py screenshot out.ppm
                           read the live LCD back over the UART (no HDMI needed) into a 160x144
                           PPM of 2-bit DMG shades; one line per frame, so the image is rolling
                           (~3-6 s), not atomic
  gbctl.py screenshot-color out.ppm
                           same, but the PPU's native RGB555 colors (Game Boy Color), expanded to
                           8 bits per channel; rolling, ~8-12 s
"""
import ctypes, os, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = os.environ.get("OSS_CAD_SUITE", os.path.join(ROOT, "tools", "oss-cad-suite"))
LIBUSB = os.path.join(SUITE, "lib", "libusb-1.0.0.dylib")
VID, PID, IFACE, EP_OUT, EP_IN, CH = 0x0403, 0x6010, 1, 0x04, 0x83, 2   # FT2232 channel B

BTN = {"right": 0, "left": 1, "up": 2, "down": 3, "a": 4, "b": 5, "select": 6, "start": 7}
KEYS = {"Right": "right", "Left": "left", "Up": "up", "Down": "down", "z": "a", "Z": "a",
        "x": "b", "X": "b", "Return": "start", "BackSpace": "select", "Shift_L": "select",
        "Shift_R": "select"}
SHADES = (b"\xe0\xf8\xd0", b"\x88\xc0\x70", b"\x34\x68\x56", b"\x08\x18\x20")   # rtl/top.v DMG shades
CAP_ERR = {1: "core held in reset (no game loaded, or still loading)",
           2: "LCD is off (or was switched off during the capture)",
           3: "line not drawn within 2^21 clocks, ~80 ms (core stalled?)", 4: "line out of range"}
EXPAND5 = bytes((c << 3) | (c >> 2) for c in range(32))   # RGB555 channel -> 8 bits


class Link:
    def __init__(self):
        L = self.L = ctypes.CDLL(LIBUSB)
        V, I = ctypes.c_void_p, ctypes.c_int
        L.libusb_open_device_with_vid_pid.restype = V
        L.libusb_open_device_with_vid_pid.argtypes = [V, ctypes.c_uint16, ctypes.c_uint16]
        L.libusb_claim_interface.argtypes = [V, I]
        L.libusb_release_interface.argtypes = [V, I]
        L.libusb_close.argtypes = [V]
        L.libusb_exit.argtypes = [V]
        L.libusb_control_transfer.argtypes = [V, ctypes.c_uint8, ctypes.c_uint8, ctypes.c_uint16,
                                              ctypes.c_uint16, V, ctypes.c_uint16, ctypes.c_uint]
        L.libusb_bulk_transfer.argtypes = [V, ctypes.c_ubyte, V, I, ctypes.POINTER(I), ctypes.c_uint]
        L.libusb_error_name.restype = ctypes.c_char_p
        self.ctx = V()
        L.libusb_init(ctypes.byref(self.ctx))
        self.h = L.libusb_open_device_with_vid_pid(self.ctx, VID, PID)
        if not self.h:
            L.libusb_exit(self.ctx)
            sys.exit("Tang Nano 9K not found on USB (check cable / re-plug)")
        r = L.libusb_claim_interface(self.h, IFACE)
        if r:
            L.libusb_close(self.h)
            L.libusb_exit(self.ctx)
            sys.exit(f"cannot claim UART interface: {L.libusb_error_name(r).decode()}")
        # Initialize the UART explicitly after USB reconnect: 115200 baud,
        # 8N1, no flow control. These are FTDI vendor requests, not termios.
        for request, value in ((3, 0x001a), (4, 8), (2, 0)):
            r = L.libusb_control_transfer(self.h, 0x40, request, value, CH, None, 0, 1000)
            if r < 0:
                self.close()
                sys.exit(f"UART setup failed: {L.libusb_error_name(r).decode()}")
        # Send a harmless released-buttons packet to warm up the bridge.
        self.write(b"J\x00J\x00")
        self.read(0.1)

    def write(self, data):
        n = ctypes.c_int()
        for i in range(0, len(data), 4096):
            chunk = data[i:i + 4096]
            r = self.L.libusb_bulk_transfer(self.h, EP_OUT, ctypes.create_string_buffer(chunk, len(chunk)),
                                            len(chunk), ctypes.byref(n), 5000)
            if r:
                sys.exit(f"USB write failed: {self.L.libusb_error_name(r).decode()}")

    def read(self, seconds, done=None):
        """Collect UART bytes for `seconds`, or until done(bytes_so_far) is true. Replies may span
        several USB transfers; each 64-byte packet starts with 2 status bytes."""
        out, n, buf = b"", ctypes.c_int(), ctypes.create_string_buffer(512)
        end = time.time() + seconds
        while time.time() < end and not (done and done(out)):
            self.L.libusb_bulk_transfer(self.h, EP_IN, buf, 512, ctypes.byref(n), 50)
            d = buf.raw[:n.value]
            for i in range(0, len(d), 64):
                out += d[i + 2:i + 64]
        return out

    def close(self):
        self.L.libusb_release_interface(self.h, IFACE)
        self.L.libusb_close(self.h)
        self.L.libusb_exit(self.ctx)


def load(link, path):
    rom = open(path, "rb").read()
    size = 32768 << rom[0x148] if len(rom) > 0x148 and rom[0x148] <= 7 else len(rom)
    if size > 0x3E0000:
        sys.exit(f"{size} bytes: larger than the 3.875 MB PSRAM ROM area")
    rom = rom[:size].ljust(size, b"\xff")             # FPGA stops after the header-declared size
    want = sum(rom) & 0xFF
    for attempt in range(1, 4):
        t = time.time()
        link.write(b"L" + rom)
        reply = link.read(0.5)            # also lets the FPGA's 80 ms idle timeout abort a partial load
        k = reply.find(b"K")
        if k >= 0 and k + 1 < len(reply) and reply[k + 1] == want:
            print(f"loaded {path} ({size // 1024} KB) in {time.time() - t:.1f}s, checksum {want:02x} verified")
            return
        print(f"attempt {attempt}: no valid ack (got {reply!r}), retrying")
    sys.exit("upload failed 3 times; is the Game Boy design on the board (make flash)?")


def play(link):
    import tkinter as tk
    held, pending = set(), {}
    root = tk.Tk()
    root.title("FPGA Game Boy pad")
    lab = tk.Label(root, font=("Menlo", 14), justify="left", padx=16, pady=12)
    lab.pack()
    last = [-1]

    def send(force=False):
        state = sum(1 << BTN[b] for b in held)
        if force or state != last[0]:
            link.write(bytes([ord("J"), state]))
            last[0] = state
        lab.config(text="arrows=D-pad  Z=A  X=B  Enter=Start  Backspace=Select\n\nheld: "
                        + (" ".join(sorted(held)) or "-"))

    def down(e):
        b = KEYS.get(e.keysym)
        if b:
            if b in pending:                      # auto-repeat: cancel the queued release
                root.after_cancel(pending.pop(b))
            held.add(b)
            send()

    def up(e):
        b = KEYS.get(e.keysym)
        if b:                                     # defer: auto-repeat sends release+press pairs
            def rel():
                pending.pop(b, None); held.discard(b); send()
            pending[b] = root.after(30, rel)

    def keepalive():                              # resend state so a lost byte can't stick a key
        send(force=True)
        root.after(250, keepalive)

    root.bind("<KeyPress>", down)
    root.bind("<KeyRelease>", up)
    root.bind("<FocusOut>", lambda e: (held.clear(), send()))
    keepalive()
    try:
        root.mainloop()
    finally:
        link.write(b"J\x00")


def status(link):
    for _ in range(3):
        link.write(b"S")
        r = link.read(0.3)
        k = r.find(b"S")
        if k >= 0 and len(r) >= k + 4:
            f, la, pc = r[k + 1], r[k + 2], r[k + 3]
            names = ["psram_ready", "load_done", "flash_busy", "lcd_on", "video_locked", "waitlock"]
            print("  ".join(f"{n}={(f >> (7 - i)) & 1}" for i, n in enumerate(names)),
                  f"mapper={f & 3}  load_addr={la << 14:#08x}  pc_hi={pc:02x}")
            return
    sys.exit(f"no status reply (got {r!r})")


def diagnose(link):
    link.write(b"D")
    reply = link.read(0.5)
    k = reply.find(b"D")
    if k < 0 or len(reply) < k + 9:
        sys.exit(f"no memory diagnostic reply (got {reply!r})")
    flags, state, ah, am, al, expected, actual, cycles = reply[k + 1:k + 9]
    names = ("test_done", "test_pass", "write", "busy", "ready", "hang", "request", "logo_ok")
    print("  ".join(f"{name}={(flags >> (7 - i)) & 1}" for i, name in enumerate(names)))
    names = ("timeout", "active", "writing", "configuring", "first_byte", "read_complete", "dq_drive", "rwds_drive")
    print("  ".join(f"{name}={(state >> (7 - i)) & 1}" for i, name in enumerate(names)))
    print(f"address={(ah << 16) | (am << 8) | al:#08x}  memory_fabric_cycles={cycles}")
    if flags & 0x80 and not flags & 0x40:
        print(f"memory mismatch: expected={expected:02x} actual={actual:02x}")
    elif flags & 0x40:
        link.write(b"H")
        header = link.read(0.2)
        h = header.find(b"H")
        if h >= 0 and len(header) >= h + 3:
            a, b = header[h + 1:h + 3]
            print(f"ROM header readback: 0x104={a:02x} 0x105={b:02x} (expected ce ed)")


def _capture(link, cmd, y, n, valid):
    """Send cmd <y>; accept cmd <y> <n data bytes> <sum8> if valid(data), or exit on 'v' <code>."""
    r = b""
    for _ in range(3):
        link.write(cmd + bytes([y]))
        r = link.read(0.5, lambda b: len(b) >= n + 3 or (b[:1] == b"v" and len(b) >= 2))
        if r[:1] == b"v" and len(r) == 2:
            sys.exit(f"screenshot failed at line {y}: {CAP_ERR.get(r[1], f'error code {r[1]}')}")
        if (len(r) == n + 3 and r[:1] == cmd and r[1] == y and sum(r[2:-1]) & 0xFF == r[-1]
                and valid(r[2:-1])):
            return r[2:-1]
        link.read(0.1)                    # discard the rest of a garbled reply before retrying
    sys.exit(f"screenshot failed at line {y}: no valid reply after 3 attempts (last {r!r}); "
             "is the current design flashed?")


def capture_line(link, y):
    """'V' <y> -> 'V' <y> <40 bytes, 4 px/byte, MSB first> <sum8>, or 'v' <error code>."""
    return _capture(link, b"V", y, 40, lambda d: True)


def capture_line_color(link, y):
    """'W' <y> -> 'W' <y> <160 RGB555 pixels, little-endian, bit 15 = 0> <sum8>, or 'v' <code>."""
    return _capture(link, b"W", y, 320, lambda d: all(h < 0x80 for h in d[1::2]))


def screenshot(link, path):
    t = time.time()
    link.read(0.05)                       # drop stale bytes so replies start frame-aligned
    rows = [b"".join(SHADES[(b >> s) & 3] for b in capture_line(link, y) for s in (6, 4, 2, 0))
            for y in range(144)]
    with open(path, "wb") as f:
        f.write(b"P6\n160 144\n255\n" + b"".join(rows))
    print(f"wrote {path}: 160x144 in {time.time() - t:.1f}s "
          "(rolling capture: each line from a later frame than the one above)")


def screenshot_color(link, path):
    t = time.time()
    link.read(0.05)                       # drop stale bytes so replies start frame-aligned
    rows = []
    for y in range(144):
        d = capture_line_color(link, y)
        for lo, hi in zip(d[0::2], d[1::2]):
            c = lo | hi << 8
            rows.append(bytes((EXPAND5[c & 31], EXPAND5[(c >> 5) & 31], EXPAND5[(c >> 10) & 31])))
    with open(path, "wb") as f:
        f.write(b"P6\n160 144\n255\n" + b"".join(rows))
    print(f"wrote {path}: 160x144 RGB555 in {time.time() - t:.1f}s "
          "(rolling capture: each line from a later frame than the one above)")

def scanout(link):
    """Fingerprint of the scaled RGB pixels, after the dual-clock video buffer (not HDMI capture)."""
    link.read(0.05)
    link.write(b"F")
    reply = link.read(0.3, lambda d: len(d) >= 4)
    if len(reply) != 4 or reply[0] != ord("F"):
        sys.exit(f"invalid scanout reply: {reply!r}")
    frame, signature = reply[1], int.from_bytes(reply[2:4], "big")
    print(f"scanout frame={frame} fingerprint={signature:04x} (16-bit, not collision-free)")
    return frame, signature



if __name__ == "__main__":
    cmds = {"load": 3, "play": 2, "status": 2, "diagnose": 2, "scanout": 2,
            "screenshot": 3, "screenshot-color": 3}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds or len(sys.argv) < cmds[sys.argv[1]]:
        sys.exit(__doc__)
    link = Link()
    try:
        if sys.argv[1] == "load":
            load(link, sys.argv[2])
        elif sys.argv[1] == "play":
            play(link)
        elif sys.argv[1] == "diagnose":
            diagnose(link)
        elif sys.argv[1] == "scanout":
            scanout(link)
        elif sys.argv[1] == "screenshot":
            screenshot(link, sys.argv[2])
        elif sys.argv[1] == "screenshot-color":
            screenshot_color(link, sys.argv[2])
        else:
            status(link)
    finally:
        link.close()
