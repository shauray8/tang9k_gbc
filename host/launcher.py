#!/usr/bin/python3
"""FPGA game library backed by a Mac directory (physical SD is not required).

  /usr/bin/python3 host/launcher.py /path/to/roms [--covers /path/to/covers]
  /usr/bin/python3 host/launcher.py /path/to/roms --build-only

The generated GBC menu runs on the FPGA. Left/right browse, Z or Enter launches.
F1 / Home resets the current game and reloads/rescans the library. Saves are not
persistent yet. ROMs remain outside Git. Unsupported images appear as disabled cards.
A menu-capable FPGA image is required. This does not emulate the SD wire protocol.
Uploads run on one background worker with visible progress and exclusive USB ownership.
"""
import argparse
from pathlib import Path
import threading
import time
import gbctl
import menu


class Requests:
    """Incremental decoder for G <index-low> <index-high> <low^high^5A>."""
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer.extend(data)
        requests = []
        while self.buffer:
            if self.buffer[0] != ord('G'):
                del self.buffer[0]
                continue
            if len(self.buffer) < 4:
                break
            _, lo, hi, check = self.buffer[:4]
            if check != lo ^ hi ^ 0x5A:
                del self.buffer[0]
                continue
            requests.append(lo | hi << 8)
            del self.buffer[:4]
        return requests


class Library:
    def __init__(self, link, folder, covers=None):
        self.link, self.folder, self.covers = link, Path(folder), covers
        self.games = []
        self.query = ""
        self.total = 0
        self.active = False
        self.decoder = Requests()
        self.image = menu.ROOT / 'build/launcher/library.gbc'
        self._worker = None
        self._done = threading.Event()
        self._cancel = threading.Event()
        self._error = None
        self._target = None
        self.progress = ""

    @property
    def busy(self):
        return self._worker is not None

    @property
    def can_control(self):
        return not self.busy and self._error is None

    def prepare(self):
        catalog = menu.library(self.folder)
        games = menu.filter_games(catalog, self.query)
        image = menu.build(games, self.covers, query=self.query, total=len(catalog))
        self.total = len(catalog)
        self.image.parent.mkdir(parents=True, exist_ok=True)
        self.image.write_bytes(image)
        self.games = games
        for index, game in enumerate(games):
            print(f'{index:4d} {game.title} / {game.info}', flush=True)
        return self.image

    def home(self):
        if self.busy:
            return self.progress
        return self._start(self.prepare(), None)

    def search(self, query):
        if self.busy or not self.active:
            return "Open the library with F1 / Home before searching."
        self.query = ' '.join(query.split())
        return self.home()

    def _start(self, path, game):
        # One worker owns USB during a transfer. Tk only reads progress and
        # never sends joypad bytes into the ROM stream or touches Tk here.
        self.active = False
        self._target = game
        self._error = None
        self._cancel.clear()
        self._done.clear()
        display = game.title if game is not None else "library"
        self.progress = f"Loading {display}..."
        started = time.monotonic()

        def progress(sent, total, attempt, phase):
            self.progress = (f"Loading {display}: {sent*100//total}%\n"
                             f"{sent//1024}/{total//1024} KB sent | attempt {attempt} | "
                             f"{time.monotonic()-started:.0f}s | {phase}")

        def transfer():
            try:
                self.link.write(b'J\x00')
                gbctl.load(self.link, str(path), progress=progress, cancelled=self._cancel.is_set)
                if self._cancel.is_set():
                    raise gbctl.UploadCancelled("Upload cancelled")
                if game is None:
                    self.link.read(.1)
                    self.link.write(b'M')
                    reply = self.link.read(.5, lambda data: b'M\x01' in data)
                    if b'M\x01' not in reply:
                        raise RuntimeError("FPGA did not acknowledge launcher protocol; load the menu-capable bitstream")
                self.link.write(b'J\x00')
            except BaseException as error:
                self._error = error
                print(f"Upload stopped: {error}", flush=True)
            finally:
                self._done.set()

        self._worker = threading.Thread(target=transfer, daemon=True)
        self._worker.start()
        return self.progress

    def poll(self):
        if self.busy:
            if not self._done.is_set():
                return self.progress
            self._worker.join()
            self._worker = None
            if self._error is not None:
                return f"Upload stopped: {self._error}\nF1 / Home can reload the library."
            if self._target is None:
                self.decoder = Requests()
                self.active = True
                message = f"Library: {len(self.games)} games | F1 refresh / Home"
            else:
                message = f"Playing: {self._target.title} | F1 / Home returns to library"
            print(message, flush=True)
            return message
        if self._error is not None or not self.active:
            return None
        events = self.decoder.feed(self.link.read(.005))
        if not events:
            return None
        index = events[0]
        if index >= len(self.games):
            return 'Invalid library selection; F1 to reload the menu'
        game = self.games[index]
        if not game.playable:
            return f'{game.info}; F1 to reload the menu'
        print(f'Launching {game.path.name}', flush=True)
        return self._start(game.path, game)

    def close(self):
        if self._worker is not None:
            self._cancel.set()
            self._worker.join()
            self._worker = None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--covers', type=Path, default=menu.ROOT / 'assets/covers')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    if not args.folder.is_dir():
        parser.error(f'Not a ROM directory: {args.folder}')
    if args.build_only:
        service = Library(None, args.folder, args.covers)
        print(f'Built {service.prepare()}')
        return
    link = gbctl.Link()
    try:
        service = Library(link, args.folder, args.covers)
        print(service.home(), flush=True)
        gbctl.play(link, library=service)
    finally:
        service.close()
        link.close()


if __name__ == '__main__':
    main()
