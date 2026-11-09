#!/usr/bin/python3
"""Control the FPGA Game Boy over the Tang Nano 9K's on-board USB-UART (BL702, channel B).

The macOS serial driver for this bridge rejects configuration and can wedge the device, so this
talks to the bridge's UART endpoints directly over libusb (bundled with the toolchain).

  gbctl.py load game.gb    upload a .gb image to PSRAM (up to 3.875 MiB; lost on reset),
                           checksum-verified; ~11 s per 128 KB at 115200 baud. The launcher
                           (host/launcher.py) also restores and stores battery saves.
  gbctl.py status          print core/loader state (PSRAM ready, load progress, LCD, lock)
  gbctl.py diagnose        print boot-memory address, expected/actual bytes, and controller state
  gbctl.py scanout         read the completed HDMI game-window fingerprint and frame counter
  gbctl.py play            open a window; keyboard = joypad (window must have focus)
                           arrows = D-pad, Z = A, X = B, Enter = Start, Backspace/Shift = Select
  gbctl.py scanout         fingerprint of the frame actually sent to HDMI (changes => running)
  gbctl.py load --boot game.gb   same as load, but start through the CGB boot ROM (logo, DMG
                           colourisation). Boot ROM choice: see BOOT_ROM below.
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
# UART rates: (27 MHz / baud divisor on the FPGA, FTDI divisor value, baud). Tried fastest first.
SLOW = (234, 0x001A, 115_200)
FAST = ((9, 0, 3_000_000), (18, 2, 1_500_000), (27, 3, 1_000_000), (54, 6, 500_000))
# Boot ROM: $GB_BOOT_ROM, else your own dump at ../bootroms/cgb_boot.bin (2304 bytes, from a
# Game Boy Color you own: Nintendo logo), else SameBoy's open-source boot ROM (SameBoy logo).
BOOT_ROM = next((p for p in (os.environ.get("GB_BOOT_ROM"),
                             os.path.join(ROOT, "..", "bootroms", "cgb_boot.bin"),
                             os.path.join(ROOT, "..", "tools-ref", "SameBoy", "build", "bin",
                                          "BootROMs", "cgb_boot.bin"))
                 if p and os.path.exists(p)), "")
BOOT_BASE = 0x3D0000   # boot ROM image in PSRAM; ROMs above this size run without it


class _Gone(Exception):
    """The bridge dropped off USB while it was being set up."""


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
        L.libusb_clear_halt.argtypes = [V, ctypes.c_ubyte]
        L.libusb_error_name.restype = ctypes.c_char_p
        self.ctx = V()
        L.libusb_init(ctypes.byref(self.ctx))
        self.h, self._opening = None, False
        error = self._open()
        if error:
            L.libusb_exit(self.ctx)
            sys.exit(error)

    def _open(self):
        """Open, claim and configure the bridge; returns an error message or None."""
        L = self.L
        self._opening = True
        try:
            self.h = L.libusb_open_device_with_vid_pid(self.ctx, VID, PID)
            if not self.h:
                return "Tang Nano 9K not found on USB (check cable / re-plug)"
            r = L.libusb_claim_interface(self.h, IFACE)
            if r:
                self._drop()
                return f"cannot claim UART interface: {L.libusb_error_name(r).decode()}"
            # Initialize the UART explicitly after USB reconnect: 115200 baud,
            # 8N1, no flow control. These are FTDI vendor requests, not termios.
            for request, value in ((3, SLOW[1]), (4, 8), (2, 0)):
                r = L.libusb_control_transfer(self.h, 0x40, request, value, CH, None, 0, 1000)
                if r < 0:
                    self._drop()
                    return f"UART setup failed: {L.libusb_error_name(r).decode()}"
            self.baud = SLOW[2]
            # Send a harmless released-buttons packet to warm up the bridge.
            self.write(b"J\x00J\x00")
            self.read(0.1)
            if os.environ.get("GB_BAUD") != "slow":
                self.negotiate()
            return None
        except _Gone:
            self._drop()
            return "USB connection dropped during setup"
        finally:
            self._opening = False

    def _drop(self):
        if self.h:
            self.L.libusb_release_interface(self.h, IFACE)
            self.L.libusb_close(self.h)
        self.h = None

    def reconnect(self, seconds=60):
        """The bridge left the bus (e.g. an HDMI cable was plugged in): wait for it to return."""
        if self._opening:
            raise _Gone
        print("USB connection lost, reconnecting...", flush=True)
        self._drop()
        end = time.time() + seconds
        while time.time() < end:
            time.sleep(1)
            if self._open() is None:
                print(f"reconnected at {self.baud} baud", flush=True)
                return
        sys.exit("the board did not come back on USB within a minute; re-plug it")

    def _set_host_rate(self, ftdi, baud):
        # The board's BL702 firmware applies a new rate only with the next 8N1 line-format
        # request, so both are sent.
        for request, value in ((3, ftdi), (4, 8)):
            r = self.L.libusb_control_transfer(self.h, 0x40, request, value, CH, None, 0, 1000)
            if r < 0:
                sys.exit(f"UART rate change failed: {self.L.libusb_error_name(r).decode()}")
        self.baud = baud
        time.sleep(0.02)
        self.read(0.05)                          # drop bytes framed at the old rate

    def _alive(self, tries=3):
        for _ in range(tries):
            self.read(0.02)
            self.write(b"S")
            reply = self.read(0.3, lambda d: len(d) >= 4)
            if len(reply) == 4 and reply[:1] == b"S":
                return True
        return False

    def negotiate(self):
        """Switch to the fastest UART rate both ends carry (rtl/top.v 'Q'). The board keeps a
        new rate only after an 'S' arrives at it, so a failed try falls back to 115200."""
        if not self._alive(1):
            for div, ftdi, baud in FAST:          # board still fast from an earlier session?
                self._set_host_rate(ftdi, baud)
                if self._alive(2):
                    return
            self._set_host_rate(SLOW[1], SLOW[2])
            return
        for div, ftdi, baud in FAST:
            self.write(bytes((ord("Q"), div)))
            time.sleep(0.02)
            self._set_host_rate(ftdi, baud)
            if self._alive(3):
                return
            self._set_host_rate(SLOW[1], SLOW[2])
            time.sleep(1.4)                        # board's probation timeout restores 115200
            if not self._alive():
                sys.exit("lost the board while trying a faster UART rate; re-plug it")

    def downgrade(self):
        """After a failed transfer at a fast rate, step down one rate (or to 115200)."""
        rates = [r for r in FAST if r[2] < self.baud] + [SLOW]
        if self.baud == SLOW[2]:
            return
        div, ftdi, baud = rates[0]
        self.read(0.1)
        self.write(bytes((ord("Q"), div)))
        time.sleep(0.05)
        self._set_host_rate(ftdi, baud)
        if not self._alive():
            self._set_host_rate(SLOW[1], SLOW[2])
            time.sleep(1.4)
            if not self._alive():
                sys.exit("lost the board while slowing the UART; re-plug it")
        print(f"UART now {self.baud} baud", flush=True)

    def write(self, data):
        n = ctypes.c_int()
        for i in range(0, len(data), 4096):
            chunk = data[i:i + 4096]
            for attempt in range(4):
                r = self.L.libusb_bulk_transfer(self.h, EP_OUT, ctypes.create_string_buffer(chunk, len(chunk)),
                                                len(chunk), ctypes.byref(n), 5000)
                if r == 0:
                    break
                if r == -9 and attempt < 2:
                    # The BL702 bridge occasionally stalls its endpoint (PIPE): clear it and
                    # resend the part it did not accept.
                    self.L.libusb_clear_halt(self.h, EP_OUT)
                    self.L.libusb_clear_halt(self.h, EP_IN)
                    chunk = chunk[n.value:]
                    time.sleep(0.05)
                else:
                    self.reconnect()               # gone or wedged: reopen, resend this chunk
            else:
                sys.exit(f"USB write failed: {self.L.libusb_error_name(r).decode()} (re-plug the board)")

    def read(self, seconds, done=None):
        """Collect UART bytes for `seconds`, or until done(bytes_so_far) is true. Replies may span
        several USB transfers; each 64-byte packet starts with 2 status bytes."""
        out, n, buf = b"", ctypes.c_int(), ctypes.create_string_buffer(512)
        end = time.time() + seconds
        while time.time() < end and not (done and done(out)):
            r = self.L.libusb_bulk_transfer(self.h, EP_IN, buf, 512, ctypes.byref(n), 50)
            if r == -9:                                   # LIBUSB_ERROR_PIPE: stalled endpoint
                self.L.libusb_clear_halt(self.h, EP_IN)
                continue
            if r in (-4, -1):                             # NO_DEVICE / IO: bridge left the bus
                self.reconnect()
                return out
            d = buf.raw[:n.value]
            for i in range(0, len(d), 64):
                out += d[i + 2:i + 64]
        return out

    def close(self):
        self._drop()
        self.L.libusb_exit(self.ctx)


class UploadCancelled(RuntimeError):
    pass


# Boot logo preference for the next game start; the in-game overlay can change it.
boot_preference = os.environ.get("GB_BOOT") != "off"


def set_boot(link, rom_size):
    """Map the CGB boot ROM for the next game start; returns whether it is enabled. The image is
    uploaded even when the logo is off, so the overlay can turn it on for a reset."""
    data = open(BOOT_ROM, "rb").read() if os.path.exists(BOOT_ROM) else b""
    usable = len(data) == 0x900 and rom_size <= BOOT_BASE
    on = usable and boot_preference
    frozen = core_pause(link, 2)[0]   # the launcher keeps the core frozen across a load
    core_pause(link, 1)
    try:
        if usable:
            write_memory(link, BOOT_BASE, data)
    finally:
        core_pause(link, 3 if on else 4)
        if not frozen:
            core_pause(link, 0)
    return on


def load(link, path, progress=None, cancelled=None, boot=False):
    with open(path, "rb") as source:
        rom = source.read()
    size = 32768 << rom[0x148] if len(rom) > 0x148 and rom[0x148] <= 7 else len(rom)
    if size > 0x3E0000:
        sys.exit(f"{size} bytes: larger than the 3.875 MB PSRAM ROM area")
    rom = rom[:size].ljust(size, b"\xff")
    if boot:
        set_boot(link, size)
    else:
        core_pause(link, 4)   # e.g. the launcher itself starts directly at 0100
    expected = b"K" + bytes([sum(rom) & 0xFF])

    def check_cancelled():
        if cancelled is not None and cancelled():
            raise UploadCancelled("Upload cancelled")

    for attempt in range(1, 4):
        check_cancelled()
        started = time.monotonic()
        if progress is not None:
            progress(0, size, attempt, "sending")
        link.write(b"L")
        for offset in range(0, size, 4096):
            check_cancelled()
            block = rom[offset:offset+4096]
            link.write(block)
            if progress is not None:
                progress(offset+len(block), size, attempt, "sending")
        if progress is not None:
            progress(size, size, attempt, "verifying")
        # USB completion means queued in the bridge, not drained over UART.
        # Its trailing bytes can take longer than the former 0.5 s ack window.
        reply = link.read(2.0, lambda data: expected in data)
        check_cancelled()
        if expected in reply:
            print(f"loaded {path} ({size // 1024} KB) in {time.monotonic()-started:.1f}s, "
                  f"checksum {expected[1]:02x} verified", flush=True)
            return
        print(f"attempt {attempt}: no valid ack (got {reply!r}), retrying", flush=True)
        link.downgrade()
    sys.exit("upload failed 3 times; is the Game Boy design on the board (make flash)?")

class TransferError(RuntimeError):
    pass


def core_flags(link, state=2):
    """'P' <state> -> the raw 'p' flags byte: {overlay event[2:0], overlay open, 0, boot logo,
    dirty cart RAM since the last freeze, frozen}. States: 0 resume, 1 freeze, 2 query,
    3/4 boot logo on/off, 5 acknowledge the overlay event."""
    for _ in range(3):
        link.read(0.02)
        link.write(bytes((ord("P"), state)))
        reply = link.read(0.5, lambda d: len(d) >= 2 and d[-2:-1] == b"p")
        k = reply.rfind(b"p")
        if k >= 0 and k + 1 < len(reply):
            return reply[k + 1]
    raise TransferError("no reply to freeze/resume; is the save-capable design loaded?")


def core_pause(link, state):
    """state 1 freezes, 0 resumes, 2 queries -> (frozen, dirty cart RAM since the last freeze)."""
    flags = core_flags(link, state)
    return bool(flags & 1), bool(flags & 2)


def _header(op, addr, n):
    return bytes((ord(op), addr >> 16 & 0x3F, addr >> 8 & 0xFF, addr & 0xFF, n >> 8 & 0xFF, n & 0xFF))


def read_memory(link, addr, size):
    """Read PSRAM bytes from a frozen core (64 KiB per command, 8-bit sum checked)."""
    out = bytearray()
    while len(out) < size:
        n = min(size - len(out), 0x10000)
        link.read(0.02)
        link.write(_header("A", addr + len(out), n))
        data = link.read(n / 9000 + 1.5, lambda d: len(d) >= n + 1)
        if len(data) != n + 1 or sum(data[:n]) & 0xFF != data[n]:
            raise TransferError(f"memory read failed at {addr + len(out):06x} ({len(data)}/{n + 1} bytes)")
        out += data[:n]
    return bytes(out)


def write_memory(link, addr, data):
    for offset in range(0, len(data), 0x10000):
        block = data[offset:offset + 0x10000]
        link.read(0.02)
        link.write(_header("B", addr + offset, len(block)) + block)
        expected = b"b" + bytes((sum(block) & 0xFF,))
        reply = link.read(len(block) / 9000 + 1.5, lambda d: expected in d)
        if expected not in reply:
            raise TransferError(f"memory write failed at {addr + offset:06x} (got {reply!r})")


def read_clock(link):
    link.read(0.02)
    link.write(b"T")
    reply = link.read(0.5, lambda d: len(d) >= 6)
    if len(reply) != 6 or reply[:1] != b"T":
        raise TransferError(f"clock read failed (got {reply!r})")
    return tuple(reply[1:])


def write_clock(link, clock):
    link.read(0.02)
    link.write(b"U" + bytes(clock))
    if link.read(0.5, lambda d: b"u" in d)[-1:] != b"u":
        raise TransferError("clock write failed")



def play(link, library=None):
    import tkinter as tk
    held, pending = set(), {}
    root = tk.Tk()
    root.title("FPGA Game Boy pad")
    lab = tk.Label(root, font=("Menlo", 14), justify="left", padx=16, pady=12)
    lab.pack()
    last = [-1]
    status_line = [""]
    poll_enabled = [True]
    home_button = None
    query_var = None
    search_controls = []

    def send(force=False):
        state = sum(1 << BTN[b] for b in held)
        uploading = library is not None and library.busy
        if (library is None or library.can_control) and (force or state != last[0]):
            link.write(bytes([ord("J"), state]))
            last[0] = state
        lab.config(text="arrows=D-pad  Z=A  X=B  Enter=Start  Backspace=Select  Esc=menu\n\nheld: "
                        + (" ".join(sorted(held)) or "-")
                        + ("\n\n" + status_line[0] if status_line[0] else ""))
        if home_button is not None:
            home_button.config(state="disabled" if uploading else "normal")
        for widget in search_controls:
            widget.config(state="normal" if library.active and library.can_control else "disabled")

    def down(e):
        if isinstance(e.widget, tk.Entry) or library is not None and library.busy:
            return
        if e.keysym == "Escape":                  # the FPGA's in-game overlay menu
            if library is None or library.can_control:
                link.write(b"O")
            return
        b = KEYS.get(e.keysym)
        if b:
            if b in pending:                      # auto-repeat: cancel the queued release
                root.after_cancel(pending.pop(b))
            held.add(b)
            send()

    def up(e):
        if isinstance(e.widget, tk.Entry):
            return
        b = KEYS.get(e.keysym)
        if b:                                     # defer: auto-repeat sends release+press pairs
            def rel():
                pending.pop(b, None); held.discard(b); send()
            pending[b] = root.after(30, rel)

    combo_since = [None]

    def keepalive():                              # resend state so a lost byte can't stick a key
        send(force=True)
        # Select + Start held for 2 s in a game: save it and return to the library (same as F1).
        if library is not None and library.title is not None and {"select", "start"} <= held:
            if combo_since[0] is None:
                combo_since[0] = time.monotonic()
            elif time.monotonic() - combo_since[0] >= 2:
                combo_since[0] = None
                go_home()
        else:
            combo_since[0] = None
        root.after(250, keepalive)

    def run_poll():
        if poll_enabled[0]:
            try:
                message = library.poll()
                if library.busy:
                    held.clear()
                if message is not None:
                    status_line[0] = message
                    send()
            except (OSError, RuntimeError, SystemExit) as error:
                poll_enabled[0] = False
                status_line[0] = f"Launcher error: {error}\nF1 / Home can reload the library."
                lab.config(text=status_line[0])
        root.after(50, run_poll)

    def go_home(event=None):
        if library.busy:
            return
        held.clear()
        send(force=True)
        status_line[0] = "Loading library..."
        send()
        root.update_idletasks()
        try:
            status_line[0] = library.home()
            query_var.set(library.query)
            poll_enabled[0] = True
            send()
        except (OSError, RuntimeError, SystemExit) as error:
            poll_enabled[0] = False
            status_line[0] = f"Launcher error: {error}\nF1 / Home can retry."
            lab.config(text=status_line[0])

    def apply_search(event=None, clear=False):
        if library.busy or not library.active:
            return "break"
        held.clear()
        send(force=True)
        if clear:
            query_var.set("")
        try:
            status_line[0] = library.search(query_var.get())
            query_var.set(library.query)
            poll_enabled[0] = True
            send()
        except (OSError, RuntimeError, ValueError, SystemExit) as error:
            status_line[0] = f"Search error: {error}"
            lab.config(text=status_line[0])
        root.focus_set()
        return "break"

    if library is not None:
        root.title("FPGA Game Boy library")
        query_var = tk.StringVar(value=library.query)
        row = tk.Frame(root)
        row.pack(before=lab, padx=12, pady=8, fill="x")
        tk.Label(row, text="Search library:").pack(side="left")
        entry = tk.Entry(row, textvariable=query_var, width=24, font=("Menlo", 12))
        entry.pack(side="left", padx=6)
        entry.bind("<Return>", apply_search)
        search_button = tk.Button(row, text="Search", command=apply_search)
        search_button.pack(side="left")
        clear_button = tk.Button(row, text="Clear", command=lambda: apply_search(clear=True))
        clear_button.pack(side="left")
        search_controls.extend((entry, search_button, clear_button))
        root.after(50, run_poll)
        home_button = tk.Button(root, text="Home (F1): save game, return to library", command=go_home)
        home_button.pack(pady=8)
        root.bind("<F1>", go_home)

    root.bind("<KeyPress>", down)
    root.bind("<KeyRelease>", up)
    root.bind("<FocusOut>", lambda e: (held.clear(), send()))
    keepalive()
    try:
        root.mainloop()
    finally:
        if library is not None:
            library.close()
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
    print(f"address={(ah << 16) | (am << 8) | al:#08x}  system_roundtrip_cycles={cycles}")
    if flags & 0x80 and not flags & 0x40:
        print(f"memory mismatch: expected={expected:02x} actual={actual:02x}")
    elif flags & 0x40:
        link.write(b"H")
        header = link.read(0.2)
        h = header.find(b"H")
        if h >= 0 and len(header) >= h + 3:
            a, b = header[h + 1:h + 3]
            print(f"ROM header readback: 0x104={a:02x} 0x105={b:02x} (expected ce ed)")


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
    cmds = {"load": 3, "play": 2, "status": 2, "diagnose": 2, "scanout": 2}
    boot = "--boot" in sys.argv
    if boot:
        sys.argv.remove("--boot")
    if len(sys.argv) < 2 or sys.argv[1] not in cmds or len(sys.argv) < cmds[sys.argv[1]]:
        sys.exit(__doc__)
    link = Link()
    try:
        if sys.argv[1] == "load":
            load(link, sys.argv[2], boot=boot)
        elif sys.argv[1] == "play":
            play(link)
        elif sys.argv[1] == "diagnose":
            diagnose(link)
        elif sys.argv[1] == "scanout":
            scanout(link)
        else:
            status(link)
    finally:
        link.close()
