#!/usr/bin/env python3
"""Original menu ROMs executed by the real SM83/PPU, plus library/protocol edges."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from threading import Event
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host'))
import menu
from launcher import Library, Requests


class MenuTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.out = ROOT / 'build/menu-tests'
        cls.out.mkdir(parents=True, exist_ok=True)
        bootstrap = cls.out / 'bootstrap.gbc'
        bootstrap.write_bytes(menu.build([]))
        subprocess.run(['bash', str(ROOT / 'sim/run.sh'), str(bootstrap), '1',
                        str(cls.out / 'bootstrap.ppm')], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL)

    def run_menu(self, count, presses, expected, disabled=()):
        games = [menu.Game(Path(f'Game {i:04}.gbc'), f'GAME {i:04}', 'GBC', i not in disabled)
                 for i in range(count)]
        with tempfile.TemporaryDirectory(dir=self.out) as temporary:
            rom = Path(temporary) / 'menu.gbc'
            rom.write_bytes(menu.build(games))
            env = os.environ.copy()
            env['GB_PRESS'] = presses
            r = subprocess.run([str(ROOT / 'build/obj/Vgb'), str(rom), '65',
                                str(Path(temporary) / 'screen.ppm')], env=env,
                               capture_output=True, timeout=40, check=True)
            packets = re.findall(rb'\xA5(.)(.)(.)', r.stdout, re.S)
            selections = []
            for lo, hi, check in packets:
                self.assertEqual(check[0], lo[0] ^ hi[0] ^ 0x5A)
                selections.append(lo[0] | hi[0] << 8)
            self.assertEqual(selections, expected)

    def test_empty_library_cannot_launch(self):
        self.run_menu(0, '5:8:16,15:18:1,25:28:128', [])

    def test_single_game_wraps(self):
        self.run_menu(1, '5:8:2,20:23:16', [0])

    def test_bank_boundary_selection(self):
        self.run_menu(34, '5:8:2,20:23:16', [33])

    def test_index_above_255_and_wrap_back(self):
        self.run_menu(260, '5:8:2,20:23:16', [259])
        self.run_menu(260, '5:8:2,12:15:1,25:28:16', [0])

    def test_disabled_card_does_not_launch_but_navigation_continues(self):
        self.run_menu(2, '5:8:16,15:18:1,30:33:16', [1], disabled=(0,))

    def test_partial_and_corrupt_host_packets(self):
        decoder = Requests()
        self.assertEqual(decoder.feed(b'noiseG\x01'), [])
        self.assertEqual(decoder.feed(b'\x01\x00G\x03'), [])
        self.assertEqual(decoder.feed(b'\x01\x58'), [259])
        self.assertEqual(decoder.feed(b'G\x00\x00\x5aG\xff\x00\xa5'), [0, 255])

    def test_directory_filters_and_disables_unsupported_images(self):
        with tempfile.TemporaryDirectory(dir=self.out) as temporary:
            folder = Path(temporary)
            good = bytearray(0x8000)
            good[0x143] = 0x80
            (folder / 'Game (USA).GBC').write_bytes(good)
            (folder / 'broken.gb').write_bytes(b'not a ROM')
            (folder / 'ignored.txt').write_text('not a game')
            (folder / 'subdirectory.gb').mkdir()
            with (folder / 'large.gbc').open('wb') as f:
                f.write(good[:0x150]); f.seek(0x800000-1); f.write(b'\0')
            games = menu.library(folder)
            by_name = {game.path.name: game for game in games}
            self.assertEqual(set(by_name), {'Game (USA).GBC', 'broken.gb', 'large.gbc'})
            self.assertTrue(by_name['Game (USA).GBC'].playable)
            self.assertFalse(by_name['broken.gb'].playable)
            self.assertFalse(by_name['large.gbc'].playable)


class UploadStateTests(unittest.TestCase):
    def service(self):
        link = Mock()
        link.read.return_value = b'G\x00\x00\x5A'
        service = Library(link, ROOT)
        service.games = [menu.Game(Path('example.gb'), 'EXAMPLE', 'GB', True)]
        service.active = True
        return service

    def test_controls_stay_blocked_until_upload_completion_is_consumed(self):
        service = self.service()
        started, release = Event(), Event()

        def transfer(link, path, progress, cancelled):
            started.set()
            if not release.wait(3):
                raise RuntimeError('test transfer gate timed out')

        with patch('launcher.gbctl.load', side_effect=transfer):
            try:
                service.poll()
                self.assertTrue(started.wait(2))
                self.assertTrue(service.busy)
                self.assertFalse(service.can_control)
                service.poll()       # must return while the transfer is still blocked
                self.assertTrue(service.busy)
                release.set()
                self.assertTrue(service._done.wait(2))
                self.assertFalse(service.can_control)  # GUI has not consumed completion yet
                service.poll()
                self.assertFalse(service.busy)
                self.assertTrue(service.can_control)
                self.assertFalse(service.active)
            finally:
                release.set()
                service.close()

    def test_upload_error_pauses_controls_and_polling(self):
        service = self.service()
        with patch('launcher.gbctl.load', side_effect=RuntimeError('transport interrupted')):
            try:
                service.poll()
                self.assertTrue(service._done.wait(2))
                service.poll()
                self.assertFalse(service.busy)
                self.assertFalse(service.can_control)
                self.assertFalse(service.active)
                self.assertIsNone(service.poll())
            finally:
                service.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
