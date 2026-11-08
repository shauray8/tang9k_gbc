#!/usr/bin/env python3
"""Original menu ROMs executed by the real SM83/PPU, plus library/protocol edges."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host'))
import menu
from launcher import Requests


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
            r = subprocess.run([str(ROOT / 'build/obj/Vgb'), str(rom), '200',
                                str(Path(temporary) / 'screen.ppm')], env=env,
                               capture_output=True, timeout=120, check=True)
            packets = re.findall(rb'\xA5(.)(.)(.)', r.stdout, re.S)
            selections = []
            for lo, hi, check in packets:
                self.assertEqual(check[0], lo[0] ^ hi[0] ^ 0x5A)
                selections.append(lo[0] | hi[0] << 8)
            self.assertEqual(selections, expected)

    # GB_PRESS masks: 1 right, 2 left, 4 up, 16 A, 32 B, 128 start. The player starts in
    # front of the middle cabinet; walking off an edge enters the next/previous room.
    def test_launch_cabinet_in_front_of_player(self):
        self.run_menu(3, '30:33:16', [1])

    def test_walk_to_another_cabinet(self):
        self.run_menu(3, '30:90:1,100:103:16', [2])

    def test_run_into_next_room(self):
        self.run_menu(6, '30:80:33,100:103:128', [3])

    def test_wrap_to_last_room_above_255_and_banks(self):
        self.run_menu(261, '30:100:2,110:113:16', [260])
        self.run_menu(36, '30:100:2,110:113:16', [35])

    def test_disabled_and_empty_cabinets_do_not_launch(self):
        self.run_menu(2, '30:33:16,50:100:2,110:113:16', [0], disabled=(1,))
        self.run_menu(1, '30:33:16,50:100:2,110:113:16', [0])

    def test_empty_library_cannot_launch(self):
        self.run_menu(0, '30:33:16,40:90:2,100:103:128', [])

    def test_case_insensitive_search_and_no_results(self):
        games = [menu.Game(Path('Mario Deluxe.gbc'), 'MARIO DELUXE', 'GBC', True),
                 menu.Game(Path('Tetris.gb'), 'TETRIS', 'GB', True),
                 menu.Game(Path('Densha.gbc'), 'DENSHA', 'EXCEEDS ROM LIMIT', False)]
        self.assertEqual(menu.filter_games(games, 'mArIo'), [games[0]])
        self.assertEqual(menu.filter_games(games, 'DELUXE'), [games[0]])
        self.assertEqual(menu.filter_games(games, '  '), games)
        self.assertEqual(menu.filter_games(games, 'ZELDA'), [])

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


if __name__ == '__main__':
    unittest.main(verbosity=2)
