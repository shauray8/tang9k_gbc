#!/usr/bin/python3
"""FPGA game library backed by a Mac directory (physical SD is not required).

  /usr/bin/python3 host/launcher.py /path/to/roms [--covers /path/to/covers]
  /usr/bin/python3 host/launcher.py /path/to/roms --build-only

The launcher is itself a GBC game (host/arcade): a wall of game cards, seven per page, after
GTA 2's character select. Left/right cycle through cards and pages, up/down change rows, A or
Start plays; the Mac window searches. Card art: save an image beside the ROM with the same name
(e.g. "Tetris (World).png"), or in an "art" folder beside the ROMs named with words from the
title (e.g. "mario.jpeg"); see host/menu.py. F1 / Home, or holding Select + Start for two
seconds in a game, saves the current game and returns to the library. In a game, the board's
S2 button or Esc opens the FPGA's overlay menu (rtl/overlay.v): resume, save, library, reset,
boot logo and the boot ROM colour palette for original Game Boy games; this launcher carries out
save, library and the boot logo choice. Battery saves live beside each ROM as <ROM stem>.sav (cartridge RAM plus the
standard 48-byte MBC3 clock footer). They are restored at launch and stored on Home,
on switching games, on exit, and shortly after the game writes save RAM (at most once
a minute; each save briefly pauses play). Games without a save start with blank RAM.
ROMs remain outside Git. Unsupported images appear disabled. A save-capable FPGA image
is required. This does not emulate the SD wire protocol. Transfers run on one
background worker with visible progress and exclusive USB ownership.
"""
import argparse
import importlib
from pathlib import Path
import threading
import time
import gbctl
import saves
import menu


def current_menu():
    """menu.py and engine.bin change together: pick up a newer menu.py, or a long-running
    launcher pairs its old builder with the new engine and the card wall comes out garbled."""
    global menu
    stamp = Path(menu.__file__).stat().st_mtime_ns
    if getattr(menu, '_loaded_stamp', stamp) != stamp:
        menu = importlib.reload(menu)
    menu._loaded_stamp = stamp
    return menu


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
    AUTOSAVE_QUIET = 3        # seconds after the first observed cart-RAM write
    AUTOSAVE_INTERVAL = 60    # minimum seconds between in-game autosaves (each pauses play)
    GAME_POLL = 0.25          # in-game status query: overlay actions and cart-RAM writes

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
        self.current = None       # saves.Cartridge of the running game, None in the library
        self.title = None
        self.last_save = 0.0
        self.dirty_since = None
        self.next_poll = 0.0

    @property
    def busy(self):
        return self._worker is not None

    @property
    def can_control(self):
        return not self.busy and self._error is None

    def prepare(self):
        build = current_menu()
        catalog = build.library(self.folder)
        games = build.filter_games(catalog, self.query)
        image = build.build(games, self.covers, query=self.query, total=len(catalog))
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
        image = self.prepare()
        return self._run("library", lambda progress: self._switch(image, None, progress), None)

    def search(self, query):
        if self.busy or not self.active:
            return "Open the library with F1 / Home before searching."
        self.query = ' '.join(query.split())
        return self.home()

    # ---------------- saves ----------------
    def _store(self, resume):
        """Freeze, copy the running game's battery RAM/clock to its .sav, optionally resume."""
        cart = self.current
        gbctl.core_pause(self.link, 1)
        ram = gbctl.read_memory(self.link, saves.RAM_BASE, cart.ram_bytes) if cart.ram_bytes else b''
        clock = gbctl.read_clock(self.link) if cart.clock else None
        saves.write(cart, ram, clock)
        self.last_save = time.monotonic()
        self.dirty_since = None
        print(f"Saved {cart.save_path.name} ({len(ram)} bytes{', clock' if clock else ''})", flush=True)
        if resume:
            gbctl.core_pause(self.link, 0)

    def _switch(self, path, game, progress):
        # Freeze first: the old game must not write RAM between its export and the new load.
        gbctl.core_pause(self.link, 1)
        if self.current is not None and self.current.persistent:
            self._store(resume=False)   # failure aborts the switch; the old game resumes
        self.current, self.title = None, None
        self.link.write(b'J\x00')
        gbctl.load(self.link, str(path), progress=progress, cancelled=self._cancel.is_set,
                   boot=game is not None)
        if self._cancel.is_set():
            raise gbctl.UploadCancelled("Upload cancelled")
        cart = saves.cartridge(path) if game is not None else None
        if cart is not None:
            # Every launch replaces the shared PSRAM save area: no state leaks between games.
            ram, clock = saves.read(cart) if cart.battery else \
                (bytes((saves.FRESH_RAM,)) * cart.ram_bytes, None)
            if cart.ram_bytes:
                gbctl.write_memory(self.link, saves.RAM_BASE, ram)
            if cart.clock:
                gbctl.write_clock(self.link, clock)
        gbctl.core_pause(self.link, 0)
        if game is None:
            self.link.read(.1)
            self.link.write(b'M')
            reply = self.link.read(.5, lambda data: b'M\x01' in data)
            if b'M\x01' not in reply:
                raise RuntimeError("FPGA did not acknowledge launcher protocol; load the menu-capable bitstream")
        self.link.write(b'J\x00')
        self.current, self.title = cart, game.title if game is not None else None
        self.last_save = time.monotonic()
        self.dirty_since = None

    # ---------------- background jobs ----------------
    def _run(self, display, job, target):
        # One worker owns USB during a job. Tk only reads progress and never sends joypad
        # bytes into a transfer or touches Tk here.
        self.active = False
        self._target = target
        self._error = None
        self._cancel.clear()
        self._done.clear()
        verb = "Saving" if target == "save" else "Loading"
        self.progress = f"{verb} {display}..."
        started = time.monotonic()

        def progress(sent, total, attempt, phase):
            self.progress = (f"Loading {display}: {sent*100//total}%\n"
                             f"{sent//1024}/{total//1024} KB sent | attempt {attempt} | "
                             f"{time.monotonic()-started:.0f}s | {phase}")

        def worker():
            try:
                job(progress)
            except BaseException as error:
                self._error = error
                print(f"{verb} stopped: {error}", flush=True)
                try:
                    gbctl.core_pause(self.link, 0)    # never leave a game frozen
                except BaseException:
                    pass
            finally:
                self._done.set()

        self._worker = threading.Thread(target=worker, daemon=True)
        self._worker.start()
        return self.progress

    def poll(self):
        if self.busy:
            if not self._done.is_set():
                return self.progress
            self._worker.join()
            self._worker = None
            if self._error is not None:
                if self._target == "save":
                    message = f"Autosave failed: {self._error}\nPlaying continues; F1 / Home retries saving."
                    self._error = None
                    return message
                return f"Stopped: {self._error}\nF1 / Home can reload the library."
            if self._target == "save":
                message = f"Saved {self.title} | F1 / Home saves and returns to library"
            elif self._target is None:
                self.decoder = Requests()
                self.active = True
                message = f"Library: {len(self.games)} games | F1 refresh / Home"
            else:
                message = f"Playing: {self._target.title} | F1 / Home saves and returns to library"
            print(message, flush=True)
            return message
        if self._error is not None:
            return None
        if not self.active:
            return self._in_game()
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
        return self._run(game.title, lambda progress: self._switch(game.path, game, progress), game)

    def _in_game(self):
        """One status query per GAME_POLL: act on the FPGA overlay's request, and mark cart-RAM
        writes for the autosave (stored once writes settle, at most once a minute). Clock state
        needs no periodic saves: reopening advances it by the elapsed time."""
        if self.current is None or time.monotonic() < self.next_poll:
            return None
        now = time.monotonic()
        self.next_poll = now + self.GAME_POLL
        try:
            flags = gbctl.core_flags(self.link)
            event = flags >> 5
            if event:
                gbctl.core_flags(self.link, 5)
        except gbctl.TransferError:
            return None               # retried at the next poll; play is unaffected
        if event:
            return self._overlay(event)
        if not self.current.ram_bytes or not self.current.battery:
            return None
        if flags & 2:
            self.dirty_since = self.dirty_since or now
        if self.dirty_since is not None and now - self.dirty_since >= self.AUTOSAVE_QUIET \
                and now - self.last_save >= self.AUTOSAVE_INTERVAL:
            return self._run(self.title, lambda progress: self._store(resume=True), "save")
        return None

    def _overlay(self, event):
        """Overlay menu actions (rtl/overlay.v): 1 save, 2 library, 3 reset, 4/5 boot logo off/on."""
        if event == 1:
            if not self.current.persistent:
                return f"{self.title} has no battery save | F1 / Home returns to library"
            return self._run(self.title, lambda progress: self._store(resume=True), "save")
        if event == 2:
            return self.home()
        if event == 3:
            return f"Reset {self.title} | F1 / Home saves and returns to library"
        if event in (4, 5):
            gbctl.boot_preference = event == 5
            return f"Boot logo {'on' if event == 5 else 'off'} from the next start | F1 / Home returns to library"
        return None

    def close(self):
        if self._worker is not None:
            self._cancel.set()
            self._worker.join()
            self._worker = None
        if self.current is not None and self.current.persistent and self._error is None:
            try:
                self._store(resume=True)
            except BaseException as error:
                gbctl.core_pause(self.link, 0)
                print(f"Final save failed: {error}", flush=True)


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
