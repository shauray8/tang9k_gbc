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

    # GB_PRESS masks: 1 right, 2 left, 4 up, 8 down, 16 A, 128 start. The cursor starts on
    # the first card; cards 0-2 are the top row, 3-5 the bottom row, six per page.
    def test_launch_selected_card(self):
        self.run_menu(3, '30:33:16', [0])
        self.run_menu(3, '30:33:1,40:43:128', [1])

    def test_rows(self):
        self.run_menu(6, '30:33:8,40:43:16', [3])
        self.run_menu(6, '30:33:8,40:43:4,50:53:16', [0])
        self.run_menu(5, '30:33:1,36:39:1,42:45:8,50:53:16', [4])   # short bottom row: last card
        self.run_menu(3, '30:33:8,40:43:16', [0])                   # no bottom row

    def test_right_past_the_page_loads_the_next(self):
        presses = ','.join(f'{30+6*i}:{32+6*i}:1' for i in range(6))
        self.run_menu(8, presses + ',80:83:16', [6])

    def test_wrap_to_last_page_above_255_and_banks(self):
        self.run_menu(261, '30:33:2,50:53:16', [260])
        self.run_menu(36, '30:33:2,50:53:16', [35])

    def test_disabled_and_single_page_wrap(self):
        self.run_menu(2, '30:33:1,40:43:16', [], disabled=(1,))
        self.run_menu(1, '30:33:1,40:43:16', [0])

    def test_empty_library_cannot_launch(self):
        self.run_menu(0, '30:33:16,40:90:2,100:103:128', [])

    def test_user_image_becomes_four_colour_card_art(self):
        # 100x96 BMP (wider than 5:6, so the sides are cropped): four colour quadrants.
        colours = {(0, 0): (255, 0, 0), (1, 0): (0, 255, 0), (0, 1): (0, 0, 255), (1, 1): (255, 255, 255)}
        w, h = 100, 96
        rows = b''.join(bytes(c for x in range(w) for c in colours[(x >= 50, y >= 48)][::-1])
                        for y in reversed(range(h)))                       # BGR, bottom-up
        header = (b'BM' + (54 + len(rows)).to_bytes(4, 'little') + bytes(4) + (54).to_bytes(4, 'little')
                  + (40).to_bytes(4, 'little') + w.to_bytes(4, 'little') + h.to_bytes(4, 'little')
                  + (1).to_bytes(2, 'little') + (24).to_bytes(2, 'little') + bytes(24))
        with tempfile.TemporaryDirectory(dir=self.out) as temporary:
            folder = Path(temporary)
            (folder / 'Game (USA).bmp').write_bytes(header + rows)
            game = menu.Game(folder / 'Game (USA).gbc', 'GAME', 'GBC', True)
            self.assertEqual(menu.art_source(game), folder / 'Game (USA).bmp')
            palette, pixels = menu._quantize(menu._image_rgb(folder / 'Game (USA).bmp'))
        self.assertEqual(len(pixels), 48)
        self.assertEqual(len(pixels[0]), 40)
        rgb = [tuple(int(c[i:i+2], 16) for i in (1, 3, 5)) for c in palette]
        def near(index, expected):
            return max(abs(a-b) for a, b in zip(rgb[index], expected)) < 24
        self.assertTrue(near(3, (255, 255, 255)))                          # lightest last
        self.assertTrue(near(pixels[2][2], (255, 0, 0)))                    # top left red
        self.assertTrue(near(pixels[2][37], (0, 255, 0)))                   # top right green
        self.assertTrue(near(pixels[45][2], (0, 0, 255)))                   # bottom left blue
        self.assertEqual(pixels[45][37], 3)

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
