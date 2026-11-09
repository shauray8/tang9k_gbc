#!/usr/bin/env python3
"""Launcher save behaviour against a protocol-level model of the FPGA's UART commands."""
from pathlib import Path
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host'))
import launcher
import menu
import saves


class FakeFPGA:
    """Byte-stream model of rtl/top.v + rtl/host_mem.v commands used by the launcher."""

    def __init__(self):
        self.mem = bytearray(1 << 22)
        self.inbox = bytearray()
        self.out = bytearray()
        self.frozen = False
        self.dirty = False
        self.overlay_event = 0         # pending in-game overlay request (rtl/overlay.v)
        self.clock = (0, 0, 0, 0, 0)
        self.rom_left = None
        self.rom_sum = 0
        self.rom_at = 0
        self.load_gate = None          # Event: block 'L' completion until set
        self.loads = []
        self.lock = threading.Lock()

    def ram(self, n):
        return bytes(self.mem[saves.RAM_BASE:saves.RAM_BASE + n])

    def game_writes(self, value, n):
        assert not self.frozen
        self.mem[saves.RAM_BASE:saves.RAM_BASE + n] = bytes((value,)) * n
        self.dirty = True

    def write(self, data):
        with self.lock:
            self.inbox += data
            self._process()

    def read(self, seconds, done=None):
        if self.load_gate is not None and self.rom_left == 0:
            self.load_gate.wait(5)
        with self.lock:
            if self.rom_left == 0:
                self.out += b'K' + bytes((self.rom_sum & 0xFF,))
                self.rom_left = None
                self.clock = (0, 0, 0, 0, 0)      # core reset clears the cartridge clock
            data, self.out = bytes(self.out), bytearray()
        return data

    def _process(self):
        while self.inbox:
            if self.rom_left is not None and self.rom_left > 0:
                if self.rom_at == 0 and len(self.inbox) < 0x149:
                    return
                if self.rom_at == 0:
                    self.rom_left = 0x8000 << self.inbox[0x148]
                take = self.inbox[:self.rom_left]
                self.mem[self.rom_at:self.rom_at + len(take)] = take
                self.rom_sum += sum(take)
                self.rom_at += len(take)
                self.rom_left -= len(take)
                del self.inbox[:len(take)]
                continue
            if self.rom_left == 0:
                return                         # load reply not yet collected
            op = self.inbox[0]
            need = {ord('J'): 2, ord('P'): 2, ord('A'): 6, ord('B'): 6, ord('U'): 6}.get(op, 1)
            if len(self.inbox) < need:
                return
            if op == ord('B'):
                n = (self.inbox[4] << 8 | self.inbox[5]) or 0x10000
                if len(self.inbox) < 6 + n:
                    return
            cmd = bytes(self.inbox[:need])
            if op == ord('L'):
                del self.inbox[:1]
                self.rom_left, self.rom_sum, self.rom_at = 1, 0, 0
                self.loads.append(None)
                continue
            if op == ord('P'):
                if cmd[1] == 1 and not self.frozen:
                    self.frozen, self.dirty = True, False
                elif cmd[1] == 0:
                    self.frozen = False
                elif cmd[1] == 5:
                    self.overlay_event = 0
                self.out += b'p' + bytes((self.overlay_event << 5 | self.dirty << 1 | self.frozen,))
            elif op in b'AB' and self.frozen:
                addr = cmd[1] << 16 | cmd[2] << 8 | cmd[3]
                n = (cmd[4] << 8 | cmd[5]) or 0x10000
                if op == ord('A'):
                    block = bytes(self.mem[addr:addr + n])
                    self.out += block + bytes((sum(block) & 0xFF,))
                else:
                    block = bytes(self.inbox[6:6 + n])
                    self.mem[addr:addr + n] = block
                    self.out += b'b' + bytes((sum(block) & 0xFF,))
                    del self.inbox[:n]
            elif op == ord('T') and self.frozen:
                self.out += b'T' + bytes(self.clock)
            elif op == ord('U') and self.frozen:
                self.clock = tuple(cmd[1:])
                self.out += b'u'
            elif op == ord('M'):
                self.out += b'M\x01'
            del self.inbox[:need]

    def select(self, index):
        self.out += b'G' + bytes((index & 255, index >> 8, (index & 255) ^ (index >> 8) ^ 0x5A))


def rom(path, kind, ram_size):
    image = bytearray(0x8000)
    image[0x143], image[0x147], image[0x149] = 0x80, kind, ram_size
    path.write_bytes(image)


class SaveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name)
        rom(self.folder / 'Alpha.gbc', 0x1B, 2)       # MBC5 + RAM + battery, 8 KiB
        rom(self.folder / 'Beta.gbc', 0x1B, 2)
        rom(self.folder / 'Clock.gbc', 0x10, 3)       # MBC3 + timer + RAM + battery, 32 KiB
        rom(self.folder / 'Plain.gbc', 0x1A, 2)       # RAM without battery
        self.fpga = FakeFPGA()
        self.service = launcher.Library(self.fpga, self.folder)
        self.finish(self.service.home())

    def tearDown(self):
        self.service.close()
        self.temporary.cleanup()

    def finish(self, _=None):
        while self.service.busy:
            self.assertTrue(self.service._done.wait(10))
            self.service.poll()
        self.assertIsNone(self.service._error)

    def launch(self, name):
        if not self.service.active:
            self.finish(self.service.home())
        index = [g.path.name for g in self.service.games].index(name)
        self.fpga.select(index)
        self.service.poll()
        self.finish()
        self.assertFalse(self.fpga.frozen, 'game left frozen after launch')

    def test_saves_are_isolated_restored_and_stored_on_switch(self):
        self.launch('Alpha.gbc')
        self.assertEqual(self.fpga.ram(0x2000), b'\xff' * 0x2000)
        self.fpga.game_writes(0x11, 0x2000)
        self.launch('Beta.gbc')
        self.assertEqual((self.folder / 'Alpha.sav').read_bytes(), b'\x11' * 0x2000)
        self.assertEqual(self.fpga.ram(0x2000), b'\xff' * 0x2000, 'Alpha save leaked into Beta')
        self.fpga.game_writes(0x22, 0x2000)
        self.finish(self.service.home())
        self.assertEqual((self.folder / 'Beta.sav').read_bytes(), b'\x22' * 0x2000)
        self.launch('Alpha.gbc')
        self.assertEqual(self.fpga.ram(0x2000), b'\x11' * 0x2000)

    def test_ram_without_battery_is_cleared_and_never_saved(self):
        self.launch('Alpha.gbc')
        self.fpga.game_writes(0x33, 0x2000)
        self.launch('Plain.gbc')
        self.assertEqual(self.fpga.ram(0x2000), b'\xff' * 0x2000)
        self.fpga.game_writes(0x44, 0x2000)
        self.finish(self.service.home())
        self.assertFalse((self.folder / 'Plain.sav').exists())

    def test_clock_saved_and_advanced_by_elapsed_time(self):
        self.launch('Clock.gbc')
        self.fpga.clock = (50, 59, 23, 255, 0x01)          # day 511, 23:59:50
        with patch('saves.time.time', return_value=1_000_000):
            self.finish(self.service.home())
        data = (self.folder / 'Clock.sav').read_bytes()
        self.assertEqual(len(data), 0x8000 + 48)
        self.assertEqual(struct.unpack('<Q', data[-8:])[0], 1_000_000)
        with patch('saves.time.time', return_value=1_000_015):
            self.launch('Clock.gbc')
        self.assertEqual(self.fpga.clock, (5, 0, 0, 0, 0x80))   # wrapped day counter sets carry

    def test_failed_store_aborts_switch_and_resumes_old_game(self):
        self.launch('Alpha.gbc')
        self.fpga.game_writes(0x55, 0x2000)
        with patch('saves.write', side_effect=OSError('disk full')):
            self.service.home()
            self.assertTrue(self.service._done.wait(10))
            message = self.service.poll()
        self.assertIn('disk full', message)
        self.assertFalse(self.fpga.frozen)
        self.assertEqual(self.service.current.rom.name, 'Alpha.gbc')
        self.assertEqual(self.fpga.ram(0x2000), b'\x55' * 0x2000, 'old game state was replaced')
        self.assertFalse((self.folder / 'Alpha.sav').exists())

    def test_autosave_after_save_ram_writes(self):
        self.launch('Alpha.gbc')
        self.service.AUTOSAVE_QUIET = 0
        self.service.AUTOSAVE_INTERVAL = 0
        self.service.GAME_POLL = 0
        self.assertIsNone(self.service.poll())                 # clean: no save
        self.fpga.game_writes(0x66, 0x2000)
        self.service.poll()
        self.finish()
        self.assertEqual((self.folder / 'Alpha.sav').read_bytes(), b'\x66' * 0x2000)
        self.assertFalse(self.fpga.frozen)
        self.assertFalse(self.service.active)

    def test_overlay_save_then_library(self):
        self.launch('Alpha.gbc')
        self.service.GAME_POLL = 0
        self.fpga.game_writes(0x77, 0x2000)
        self.fpga.overlay_event = 1                            # SAVE
        self.service.poll()
        self.finish()
        self.assertEqual((self.folder / 'Alpha.sav').read_bytes(), b'\x77' * 0x2000)
        self.assertEqual(self.fpga.overlay_event, 0, 'request not acknowledged')
        self.assertFalse(self.fpga.frozen)
        self.assertFalse(self.service.active)                  # still playing
        self.fpga.game_writes(0x78, 0x2000)
        self.fpga.overlay_event = 2                            # LIBRARY: save, then the menu
        self.service.poll()
        self.finish()
        self.assertTrue(self.service.active)
        self.assertEqual((self.folder / 'Alpha.sav').read_bytes(), b'\x78' * 0x2000)

    def test_overlay_boot_logo_sets_next_start(self):
        self.launch('Alpha.gbc')
        self.service.GAME_POLL = 0
        before = launcher.gbctl.boot_preference
        try:
            self.fpga.overlay_event = 4
            self.service.poll()
            self.assertFalse(launcher.gbctl.boot_preference)
            self.fpga.overlay_event = 5
            self.service.poll()
            self.assertTrue(launcher.gbctl.boot_preference)
            self.assertEqual(self.fpga.overlay_event, 0)
        finally:
            launcher.gbctl.boot_preference = before

    def test_controls_blocked_until_upload_completion_consumed(self):
        self.fpga.load_gate = threading.Event()
        index = [g.path.name for g in self.service.games].index('Alpha.gbc')
        self.fpga.select(index)
        try:
            self.service.poll()
            self.assertTrue(self.service.busy)
            self.assertFalse(self.service.can_control)
            self.service.poll()                                # returns while blocked
            self.assertTrue(self.service.busy)
        finally:
            self.fpga.load_gate.set()
        self.assertTrue(self.service._done.wait(10))
        self.assertFalse(self.service.can_control)             # completion not yet consumed
        self.service.poll()
        self.assertTrue(self.service.can_control)
        self.fpga.load_gate = None

    def test_exit_stores_running_game(self):
        self.launch('Alpha.gbc')
        self.fpga.game_writes(0x77, 0x2000)
        self.service.close()
        self.assertEqual((self.folder / 'Alpha.sav').read_bytes(), b'\x77' * 0x2000)
        self.assertFalse(self.fpga.frozen)


class ClockTests(unittest.TestCase):
    def test_halted_clock_does_not_advance(self):
        self.assertEqual(saves.advance((1, 2, 3, 4, 0x40), 86400), (1, 2, 3, 4, 0x40))

    def test_carry_is_sticky_and_day_bit_8_propagates(self):
        self.assertEqual(saves.advance((0, 0, 0, 255, 0x80), 86400), (0, 0, 0, 0, 0x81))

    def test_short_footer_and_missing_save(self):
        cart = saves.Cartridge(Path('x.gbc'), 4, True, True)
        footer = struct.pack('<10I', 10, 0, 0, 0, 0, 10, 0, 0, 0, 0) + struct.pack('<I', 100)
        self.assertEqual(saves.decode(cart, b'\1\2' + footer[:0], now=200), (b'\1\2\xff\xff', (0, 0, 0, 0, 0)))
        self.assertEqual(saves.decode(cart, b'\0' * 4 + footer, now=130)[1], (40, 0, 0, 0, 0))


if __name__ == '__main__':
    unittest.main(verbosity=2)
