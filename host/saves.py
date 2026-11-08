"""Battery-backed cartridge saves: `<ROM stem>.sav` beside each ROM.

The file is the raw cartridge RAM, optionally followed by the common 48-byte MBC3
clock footer (BGB/VBA-M layout): live s/m/h/day-low/day-high and the latched copy as
ten little-endian 32-bit words, then a 64-bit Unix timestamp. Other emulators read the
same files. On load the clock advances by the wall time elapsed since the timestamp,
unless the saved clock was halted.
"""
from dataclasses import dataclass
import os
from pathlib import Path
import struct
import time

RAM_BASE = 0x3E0000
RAM_BYTES = {0: 0, 1: 0x800, 2: 0x2000, 3: 0x8000, 4: 0x20000, 5: 0x10000}
BATTERY = {0x03, 0x0F, 0x10, 0x13, 0x1B, 0x1E}
CLOCK = {0x0F, 0x10}
FRESH_RAM = 0xFF


@dataclass(frozen=True)
class Cartridge:
    rom: Path
    ram_bytes: int
    battery: bool
    clock: bool

    @property
    def save_path(self):
        return self.rom.with_suffix('.sav')

    @property
    def persistent(self):
        return self.battery and (self.ram_bytes or self.clock)


def cartridge(rom):
    rom = Path(rom)
    with rom.open('rb') as f:
        header = f.read(0x150)
    kind, size = header[0x147], header[0x149]
    ram = RAM_BYTES.get(size, 0)
    return Cartridge(rom, ram, kind in BATTERY, kind in CLOCK)


def advance(clock, seconds):
    """clock = (sec, min, hour, day_low, day_high); returns the clock after `seconds`."""
    sec, minute, hour, low, high = clock
    if high & 0x40 or seconds <= 0:
        return clock
    days = (high & 1) << 8 | low
    total = ((days*24 + hour)*60 + minute)*60 + sec + int(seconds)
    sec, total = total % 60, total // 60
    minute, total = total % 60, total // 60
    hour, days = total % 24, total // 24
    carry = 0x80 if days > 511 or high & 0x80 else 0
    days &= 511
    return sec, minute, hour, days & 255, carry | (high & 0x40) | days >> 8


def encode(ram, clock=None, now=None):
    data = bytes(ram)
    if clock is not None:
        words = list(clock) * 2
        data += struct.pack('<10I', *words) + struct.pack('<Q', int(time.time() if now is None else now))
    return data


def decode(cart, data, now=None):
    """Returns (ram, clock); missing or short data is padded with fresh RAM."""
    ram = data[:cart.ram_bytes].ljust(cart.ram_bytes, bytes((FRESH_RAM,)))
    clock = None
    if cart.clock:
        footer = data[cart.ram_bytes:]
        clock = (0, 0, 0, 0, 0)
        if len(footer) >= 44:
            words = struct.unpack('<10I', footer[:40])
            stamp = struct.unpack('<Q', footer[40:48])[0] if len(footer) >= 48 else \
                struct.unpack('<I', footer[40:44])[0]
            clock = tuple(w & 0xFF for w in words[:5])
            clock = (clock[0] % 60, clock[1] % 60, clock[2] % 24, clock[3], clock[4] & 0xC1)
            clock = advance(clock, (time.time() if now is None else now) - stamp)
    return ram, clock


def read(cart, now=None):
    try:
        data = cart.save_path.read_bytes()
    except FileNotFoundError:
        data = b''
    return decode(cart, data, now)


def write(cart, ram, clock=None):
    """Atomic replace, so an interrupted save never truncates the previous file."""
    path = cart.save_path
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('wb') as f:
        f.write(encode(ram, clock))
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)
