"""Build the FPGA's GBC launcher ROM from a Mac-backed game library.

The launcher (host/arcade/engine.asm) is a GTA 2-style wall of game cards, six per page,
running on the existing SM83, colour PPU and GDMA. No second renderer.

Card art (40x48, four colours per card), first match wins:
  1. your image beside the ROM with the same name: "Pokemon Crystal (USA).png" (or .jpg ...)
  2. an image in the covers folder named after the ROM or the title slug ("pokemon-crystal.png")
  3. hand-drawn JSON pixel art there: four #RRGGBB colours and 48 rows of 40 indices 0..3
  4. original procedural art
Images are centre-cropped to 5:6, scaled with macOS `sips` and reduced to their four most
representative colours; results are cached in build/launcher/art-cache.
This is a file-library backend, not an SD SPI model.
"""
import hashlib
import json
import math
import random
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
import re
import textwrap

ROOT = Path(__file__).resolve().parents[1]

# Five-by-seven pixel font; each hex digit pair is one five-bit row.
FONT = {
    'A':'0E11111F111111','B':'1E11111E11111E','C':'0F10101010100F',
    'D':'1E11111111111E','E':'1F10101E10101F','F':'1F10101E101010',
    'G':'0F10101711110F','H':'1111111F111111','I':'0E04040404040E',
    'J':'0702020212120C','K':'11121418141211','L':'1010101010101F',
    'M':'111B1515111111','N':'11191513111111','O':'0E11111111110E',
    'P':'1E11111E101010','Q':'0E11111115120D','R':'1E11111E141211',
    'S':'0F10100E01011E','T':'1F040404040404','U':'1111111111110E',
    'V':'11111111110A04','W':'11111115151B11','X':'11110A040A1111',
    'Y':'11110A04040404','Z':'1F01020408101F','0':'0E11131519110E',
    '1':'040C040404040E','2':'0E11010204081F','3':'1E01010E01011E',
    '4':'02060A121F0202','5':'1F10101E01011E','6':'0E10101E11110E',
    '7':'1F010204080808','8':'0E11110E11110E','9':'0E11110F01010E',
    '/':'01010204081010','-':'0000001F000000','.':'00000000000C0C',
    ':':'000C0C000C0C00','<':'01020408040201','>':'10080402040810',
    '?':'0E110102040004','(':'02040808080402',')':'08040202020408',
    '!':'04040404040004',"'":'04040800000000','&':'0C12140C15120D',
    '+':'0004041F040400',',':'00000000000408','_':'0000000000001F',
    '[':'0E08080808080E',']':'0E02020202020E','#':'0A0A1F0A1F0A0A',
}

@dataclass(frozen=True)
class Game:
    path: Path
    title: str
    info: str
    playable: bool


def library(folder):
    games = []
    for path in sorted(Path(folder).iterdir(), key=lambda p: p.name.casefold()):
        if not path.is_file() or path.suffix.lower() not in ('.gb', '.gbc'):
            continue
        with path.open('rb') as f:
            header = f.read(0x150)
        size = path.stat().st_size
        reason = ''
        if len(header) < 0x150:
            reason = 'INVALID ROM HEADER'
        elif size > 0x3E0000:
            reason = 'EXCEEDS ROM LIMIT'
        elif header[0x148] > 7 or size != 0x8000 << header[0x148]:
            reason = 'INVALID ROM SIZE'
        elif header[0x147] not in (0, 1, 2, 3, 5, 6, 15, 16, 17, 18, 19, 25, 26, 27, 28, 29, 30):
            reason = 'MAPPER NOT SUPPORTED'
        title = re.sub(r'\([^)]*\)|\[[^]]*\]', '', path.stem).strip().upper()
        title = re.sub(r'\s+', ' ', title)
        kind = 'GBC' if len(header) > 0x143 and header[0x143] & 0x80 else 'GB'
        info = reason or f'{kind} / {size // 1024} KB'
        games.append(Game(path.resolve(), title or path.stem.upper(), info, not reason))
    if len(games) > 4064:
        raise ValueError('The launcher image holds at most 4064 game cards (2 MiB)')
    return games


def filter_games(games, query):
    needle = ' '.join(query.casefold().split())
    return [game for game in games if needle in ' '.join(
        (game.title, game.path.stem, game.info)).casefold()]


def rgb555(color):
    if not re.fullmatch(r'#[0-9a-fA-F]{6}', color):
        raise ValueError(f'Invalid cover colour: {color!r}')
    r, g, b = (int(color[i:i+2], 16) >> 3 for i in (1, 3, 5))
    return r | g << 5 | b << 10


def tile_bytes(pixels):
    height, width = len(pixels), len(pixels[0])
    out = bytearray()
    for ty in range(0, height, 8):
        for tx in range(0, width, 8):
            for y in range(ty, ty+8):
                lo = hi = 0
                for x in range(tx, tx+8):
                    c = pixels[y][x]
                    lo = lo << 1 | (c & 1)
                    hi = hi << 1 | (c >> 1)
                out.extend((lo, hi))
    return bytes(out)


ART_W, ART_H = 32, 40                         # card slot (4x5 tiles)
GAP = 2                                       # concrete border per side: 4 px between cards
PIC_W, PIC_H = ART_W - 2*GAP, ART_H - 2*GAP   # the picture inside it, in 3 colours
IMAGE_SUFFIXES = ('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.tif', '.tiff')
ART_CACHE = ROOT / 'build/launcher/art-cache'


def art_source(game, folder=None):
    slug = re.sub(r'[^a-z0-9]+', '-', game.title.lower()).strip('-')
    bases = [game.path.parent / game.path.stem]
    if folder:
        bases += [Path(folder) / game.path.stem, Path(folder) / slug]
    for base in bases:
        for suffix in IMAGE_SUFFIXES + tuple(s.upper() for s in IMAGE_SUFFIXES) + ('.json',):
            path = Path(str(base) + suffix)
            if path.is_file():
                return path
    return None


def _read_bmp(data):
    offset, width, height = (int.from_bytes(data[10:14], 'little'),
                             int.from_bytes(data[18:22], 'little', signed=True),
                             int.from_bytes(data[22:26], 'little', signed=True))
    bpp, compression = int.from_bytes(data[28:30], 'little'), int.from_bytes(data[30:34], 'little')
    if bpp not in (24, 32):
        raise ValueError(f'unexpected {bpp}-bit BMP from sips')
    masks = (0xFF0000, 0xFF00, 0xFF)
    if compression == 3:
        masks = tuple(int.from_bytes(data[54+4*i:58+4*i], 'little') for i in range(3))
    shifts = [(m & -m).bit_length() - 1 for m in masks]
    stride, step = (bpp*width + 31) // 32 * 4, bpp // 8
    rows = []
    for y in range(abs(height)):
        row = offset + stride * (abs(height) - 1 - y if height > 0 else y)
        line = []
        for x in range(width):
            v = int.from_bytes(data[row+x*step:row+x*step+step], 'little')
            line.append(tuple((v & m) >> s for m, s in zip(masks, shifts)))
        rows.append(line)
    return rows


def _image_rgb(path):
    """Centre-crop to 4:5 and scale to the picture size with sips; returns rows of (r, g, b)."""
    info = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(path)],
                          capture_output=True, text=True, check=True).stdout
    w = int(re.search(r'pixelWidth: (\d+)', info).group(1))
    h = int(re.search(r'pixelHeight: (\d+)', info).group(1))
    cw, ch = (h*PIC_W // PIC_H, h) if w*PIC_H > h*PIC_W else (w, w*PIC_H // PIC_W)
    with tempfile.TemporaryDirectory() as tmp:
        crop, out = Path(tmp) / 'crop.png', Path(tmp) / 'art.bmp'
        subprocess.run(['sips', '-s', 'format', 'png', '-c', str(ch), str(cw), str(path),
                        '--out', str(crop)], capture_output=True, check=True)
        subprocess.run(['sips', '-s', 'format', 'bmp', '-z', str(PIC_H), str(PIC_W), str(crop),
                        '--out', str(out)], capture_output=True, check=True)
        rows = _read_bmp(out.read_bytes())
    if len(rows) != PIC_H or len(rows[0]) != PIC_W:
        raise ValueError(f'{path}: sips produced {len(rows[0])}x{len(rows)}')
    return rows


def _luma(c):
    return c[0]*3 + c[1]*6 + c[2]


def _quantize(rows, k=3):
    """k representative colours (k-means), darkest first, and per-pixel indices."""
    pixels = [p for row in rows for p in row]
    ordered = sorted(pixels, key=_luma)
    centres = [ordered[len(ordered)*(2*i+1)//(2*k)] for i in range(k)]
    for _ in range(16):
        sums = [[0, 0, 0, 0] for _ in range(k)]
        for p in pixels:
            n = min(range(k), key=lambda i: sum((a-b)**2 for a, b in zip(p, centres[i])))
            s = sums[n]
            s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; s[3] += 1
        moved = [(s[0]//s[3], s[1]//s[3], s[2]//s[3]) if s[3] else centres[i]
                 for i, s in enumerate(sums)]
        if moved == centres:
            break
        centres = moved
    centres.sort(key=_luma)
    index = [[min(range(k), key=lambda i: sum((a-b)**2 for a, b in zip(p, centres[i])))
              for p in row] for row in rows]
    return ['#%02X%02X%02X' % c for c in centres], index


def image_art(path):
    st = path.stat()
    key = hashlib.sha1(f'{path.resolve()}|{st.st_mtime_ns}|{st.st_size}|{PIC_W}x{PIC_H}x3'.encode()).hexdigest()
    cached = ART_CACHE / f'{key}.json'
    if cached.exists():
        data = json.loads(cached.read_text())
        return data['palette'], data['pixels']
    palette, pixels = _quantize(_image_rgb(path))
    ART_CACHE.mkdir(parents=True, exist_ok=True)
    cached.write_text(json.dumps({'palette': palette, 'pixels': pixels}))
    return palette, pixels


def procedural_art(game):
    seed = hashlib.sha256(game.path.name.encode()).digest()
    palette = (['#101827', '#20546B', '#42B7A0', '#F5E7AD'],
               ['#171C38', '#534178', '#D66791', '#FFE4AF'],
               ['#101B2C', '#34518A', '#61BAD1', '#F2E9CE'])[seed[0] % 3]
    pixels = [[0]*ART_W for _ in range(ART_H)]
    for y in range(ART_H):
        for x in range(ART_W):
            if y > 26 - abs(x-9)//2:
                pixels[y][x] = 1
            if y > 32 - abs(x-25)//2:
                pixels[y][x] = 2
            if (x-23)**2 + (y-10)**2 < 12:
                pixels[y][x] = 3
            if y >= 36 and (x//4 + y//2) % 2:
                pixels[y][x] = 3
    for i in range(9):
        pixels[seed[i+10] % 16 + 4][seed[i+1] % 28 + 2] = 2
    initials = ''.join(word[0] for word in game.title.split() if word[0].isalnum())[:3]
    left = (ART_W - 7*len(initials) + 2) // 2
    for n, ch in enumerate(initials):
        for y, row in enumerate(bytes.fromhex(FONT.get(ch, FONT['?']))):
            for x in range(5):
                if row & (16 >> x):
                    pixels[18+y][left+n*7+x] = 3
    return palette, pixels


def _rgb(color):
    return tuple(int(color[i:i+2], 16) for i in (1, 3, 5))


def three_colours(palette, pixels):
    """Four-colour 32x40 art (procedural or .json) as a three-colour picture: nearest-neighbour
    resample, then merge the two closest colours (weighted by how many pixels use them)."""
    pixels = [[pixels[y*ART_H//PIC_H][x*ART_W//PIC_W] for x in range(PIC_W)] for y in range(PIC_H)]
    counts = [sum(row.count(i) for row in pixels) for i in range(4)]
    rgb = [_rgb(c) for c in palette]
    a, b = min(((i, j) for i in range(4) for j in range(i+1, 4)),
               key=lambda p: sum((u-v)**2 for u, v in zip(rgb[p[0]], rgb[p[1]])))
    total = max(counts[a] + counts[b], 1)
    merged = '#%02X%02X%02X' % tuple((u*counts[a] + v*counts[b]) // total
                                       for u, v in zip(rgb[a], rgb[b]))
    keep = [i for i in range(4) if i not in (a, b)]
    colours = [merged] + [palette[i] for i in keep]
    remap = {a: 0, b: 0, keep[0]: 1, keep[1]: 2}
    return colours, [[remap[c] for c in row] for row in pixels]


def _by_luma(palette, pixels):
    """Order the colours darkest first, so every card dims with the one shared grey palette."""
    order = sorted(range(len(palette)), key=lambda i: _luma(_rgb(palette[i])))
    remap = {old: new for new, old in enumerate(order)}
    return [palette[i] for i in order], [[remap[c] for c in row] for row in pixels]


def bordered(pixels):
    """The card: a 2 px concrete border (colour 0) around the picture (colours 1-3), which has
    GTA 2's photo look: a 1 px edge in its lightest colour and a dark pin at the top."""
    out = [[0]*ART_W for _ in range(ART_H)]
    for y in range(PIC_H):
        for x in range(PIC_W):
            edge = x in (0, PIC_W-1) or y in (0, PIC_H-1)
            out[GAP+y][GAP+x] = 3 if edge else pixels[y][x] + 1
    for y, x in ((1, 13), (1, 14), (2, 13), (2, 14)):
        out[GAP+y][GAP+x] = 1
    return out


def cover(game, folder=None):
    """(320 bytes of 32x40 tiles, 8-byte RGB555 palette) for one game card."""
    path = art_source(game, folder)
    if path is None:
        palette, pixels = three_colours(*procedural_art(game))
    elif path.suffix == '.json':
        data = json.loads(path.read_text())
        palette, rows = data['palette'], data['pixels']
        if len(palette) != 4 or len(rows) != ART_H or any(
                len(row) != ART_W or set(row)-set('0123') for row in rows):
            raise ValueError(f'{path}: card art requires four colours and 32x40 pixels using 0..3')
        palette, pixels = three_colours(palette, [[int(c) for c in row] for row in rows])
    else:
        palette, pixels = image_art(path)
    palette, pixels = _by_luma(palette, pixels)
    return tile_bytes(bordered(pixels)), palettes([WALL[0]] + palette)


def text(value, width=20):
    return bytes(ord(c)-32 if c in FONT or c == ' ' else ord('?')-32
                 for c in value.upper()[:width].ljust(width))


# ---------------- card wall (host/arcade/engine.asm), after GTA 2's character select ----------
ENGINE = ROOT / 'host/arcade/engine.bin'
FONT_TILES, BANK1_TILES, BG_MAP, BG_ATTR = 0x2000, 0x3000, 0x3740, 0x3980
BG_PALS, OBJ_PALS, IDLE_TEXT, LOAD_TEXT = 0x3BC0, 0x3C00, 0x3C10, 0x3C40
BLANK_RECORD, GAME_COUNT, LAST_PAGE = 0x3C80, 0x3FF0, 0x3FF2
RECORD, PER_BANK, PAGE, CARD_TILES = 512, 32, 7, 20
WALL_FIRST, WALL_LAST, FRAME_TILE = 96, 251, 252   # bank 0 tile numbers
BANK1_FIRST = PAGE * CARD_TILES                    # bank 1 tiles after the card art: 140-255
# engine's CardPos: three up, four down at uneven heights like GTA 2; the slots touch and each
# card's own concrete border makes the gaps
CARDS = [(48, 16), (80, 24), (112, 16), (16, 80), (48, 72), (80, 80), (112, 72)]
NAME_COLS, NAME_MAX = 17, 64                       # banner columns 1-17; longer names scroll

WALL = ['#313131', '#212121', '#424242', '#000000']    # concrete, dark, light, black stains
DIM = ['#313131', '#080808', '#4A4A4A', '#7B7B7B']     # every unselected card: border, picture darkest first
TITLE = ['#313131', '#F7E731', '#636363', '#000000']   # yellow heading on concrete
BANNER = ['#D64221', '#630010', '#F7F700', '#000000']  # red, dark red, yellow line, text
FRAME = ['#000000', '#F7F7F7', '#B5B5B5', '#212121']   # colour 0 transparent


def palettes(*sets):
    return b''.join(rgb555(c).to_bytes(2, 'little') for p in sets for c in p)


def shade(palette, scale, offset):
    """Grey version of an RGB555 palette: luma * scale/16 + offset (5-bit)."""
    out = bytearray()
    for i in range(0, 8, 2):
        c = int.from_bytes(palette[i:i+2], 'little')
        y = min(31, ((c & 31)*3 + (c >> 5 & 31)*6 + (c >> 10 & 31)) // 10 * scale // 16 + offset)
        out += (y | y << 5 | y << 10).to_bytes(2, 'little')
    return bytes(out)


def _noise_tile(seed):
    rnd = random.Random(seed)
    return [[1 if r < 0.16 else 2 if r < 0.30 else 0 for r in (rnd.random() for _ in range(8))]
            for _ in range(8)]


def wall_image():
    """160x128 concrete: speckle noise, faint block joints, black stains and a crack."""
    noise = [_noise_tile(i) for i in range(12)]
    rnd = random.Random(3)
    pick = [[rnd.randrange(12) for _ in range(20)] for _ in range(16)]
    img = [[noise[pick[y//8][x//8]][y % 8][x % 8] for x in range(160)] for y in range(128)]
    for y, x0, x1 in ((39, 0, 160), (87, 0, 160)):            # block joints: dark line, light below
        for x in range(x0, x1):
            img[y][x], img[y+1][x] = 1, 2
    for x, y0, y1 in ((27, 0, 39), (123, 0, 39), (70, 40, 87), (150, 40, 87), (40, 88, 128)):
        for y in range(y0, y1):
            img[y][x] = 1
    for cx, cy, r in ((130, 66, 4), (19, 50, 2), (155, 58, 2), (6, 104, 3)):   # stains
        for y in range(cy-r-2, cy+r+3):
            for x in range(cx-r-2, cx+r+3):
                d = (x-cx)**2 + (y-cy)**2
                if 0 <= x < 168 and 0 <= y < 128:
                    if d <= r*r:
                        img[y][x] = 3
                    elif d <= (r+1)**2 and rnd.random() < 0.5:
                        img[y][x] = 1
    x = 152                                                    # crack down the right side
    for y in range(96, 126):
        img[y][x] = 3
        x = max(144, min(158, x + rnd.choice((-1, 0, 0, 1))))
    return img


def frame_tiles():
    """8x16 sprite pairs: two lines across (top/bottom edge), two columns down (sides)."""
    def t(rows):
        return tile_bytes([[int(c) for c in row] for row in rows])
    return t(['11111111']*2 + ['00000000']*6) + t(['00000000']*8) + t(['11000000']*8)*2


# Banner, rows 16-17: yellow top line, angled start, tall name, a divider, hatching, angled end.
BANNER_PIECES = ('start', 'plain', 'div', 'hatch', 'end', 'void')
TALL = ' ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?\'-&:/()+'


def _banner_piece(kind):
    """16x8 pixel column (top, bottom tile) in BANNER colours."""
    px = [[0]*8 for _ in range(16)]
    for x in range(8):
        px[0][x] = 2
    def slash(x0, width):
        for y in range(1, 16):
            for w in range(width):
                x = x0 + (15 - y) // 2 + w
                if 0 <= x < 8:
                    px[y][x] = 1
    if kind == 'start':
        slash(-4, 3)
    elif kind == 'div':
        slash(-4, 3)
    elif kind == 'hatch':
        slash(-3, 1)
    elif kind == 'end':
        for y in range(16):
            for x in range(8):
                if x > 7 - (15 - y) // 2 - 1:
                    px[y][x] = 3
        slash(-5, 2)
    elif kind == 'void':
        px = [[3]*8 for _ in range(16)]
    return px


def bank1_tiles():
    """Tile data and numbers: tall banner font (2 tiles per character) then banner pieces."""
    data, codes = bytearray(), {}
    def add(px):
        n = BANK1_FIRST + len(data) // 16
        data.extend(tile_bytes(px[:8]) + tile_bytes(px[8:]))
        return n
    for ch in TALL:
        rows = bytes.fromhex(FONT.get(ch, FONT['?'])) if ch != ' ' else bytes(7)
        px = [[0]*8 for _ in range(16)]
        for y, row in enumerate(rows):
            for x in range(5):
                if row & (16 >> x):
                    px[1+2*y][1+x] = px[2+2*y][1+x] = 3
        for x in range(8):
            px[0][x] = 2
        codes[ch] = add(px)
    for kind in BANNER_PIECES:
        codes[kind] = add(_banner_piece(kind))
    if len(data) > (256 - BANK1_FIRST) * 16:
        raise ValueError('banner tiles overflow VRAM bank 1')
    return bytes(data), codes


def banner_name(title):
    return ''.join(c if c in TALL else ' ' for c in title.upper())[:NAME_MAX].strip()


def banner_rows(name, codes):
    """Two 20-byte map rows. A short name gets GTA 2's divider and hatching after it; a long
    one fills columns 1-17 (the engine scrolls the rest through)."""
    name = banner_name(name)
    if len(name) <= 14:
        cols = ['start'] + list(name) + ['div']
        while len(cols) < 18:
            cols.append('hatch' if len(cols) % 2 == 0 else 'plain')
    else:
        cols = ['start'] + list(name[:NAME_COLS])
    cols += ['end', 'void']
    top = bytes(codes[c] for c in cols)
    return top + bytes(c + 1 for c in top)


def name_field(name, codes):
    """Length and tall-font top tiles of the whole name, for the engine's scrolling."""
    name = banner_name(name)
    return bytes((len(name),)) + bytes(codes[c] for c in name)


def record(game, covers, codes):
    tiles, pal = cover(game, covers)
    if not game.playable:
        pal = pal[:2] + shade(pal, 11, 4)[2:]     # greyed picture, same concrete border
    return (tiles + pal + banner_rows(game.title, codes) + bytes((int(game.playable),))
            + name_field(game.title, codes))


def blank_record(codes):
    """Empty card slot: concrete in the wall palette, so it disappears into the wall."""
    noise = [_noise_tile(i) for i in range(12)]
    pixels = [[noise[(x//8 + y//8*3) % 12][y % 8][x % 8] for x in range(ART_W)] for y in range(ART_H)]
    return tile_bytes(pixels) + palettes(WALL) + banner_rows('', codes) + bytes((0, 0))


def wall_maps(heading, pages, codes):
    """Map and attributes, plus the deduplicated wall tiles they use."""
    img = wall_image()
    tiles, index = [], {}
    bg, attr = bytearray(32*18), bytearray(32*18)
    for row in range(16):
        for col in range(20):
            key = tuple(tuple(img[row*8+y][col*8:col*8+8]) for y in range(8))
            if key not in index:
                index[key] = WALL_FIRST + len(tiles)
                tiles.append([list(r) for r in key])
            bg[row*32+col] = index[key]
    if WALL_FIRST + len(tiles) > WALL_LAST + 1:
        raise ValueError(f'wall texture needs {len(tiles)} tiles')
    heading = heading.center(20)
    for col, ch in enumerate(text(heading)):
        if heading[col] != ' ':
            bg[32+col], attr[32+col] = ch, 3
    for k, (x, y) in enumerate(CARDS):
        for r in range(5):
            for c in range(4):
                i = (y//8 + r)*32 + x//8 + c
                bg[i], attr[i] = k*CARD_TILES + r*4 + c, 0x08 | 5     # bank 1, hidden until loaded
    if pages > 1:
        bg[8*32], attr[8*32] = text('<', 1)[0], 3
        bg[8*32+19], attr[8*32+19] = text('>', 1)[0], 3
    rows = banner_rows('', codes)
    for col in range(32):
        bg[16*32+col] = rows[min(col, 19)]
        bg[17*32+col] = rows[20+min(col, 19)]
        attr[16*32+col] = attr[17*32+col] = 0x08 | 4
    return bg, attr, tiles


def build(games, covers=None, query="", total=None):
    """Card-wall launcher ROM: the engine plus graphics and one 512-byte record per game."""
    count = len(games)
    total = count if total is None else total
    banks = 1 + math.ceil(count / PER_BANK)
    size = max(0x8000, 1 << (banks*0x4000-1).bit_length())
    image = bytearray(size)
    engine = ENGINE.read_bytes()
    if any(engine[0x2000:0x4000]):
        raise ValueError('engine.bin overlaps the launcher data area')
    image[:0x2000] = engine[:0x2000]
    image[0x134:0x143] = b'TANG LAUNCHER'.ljust(15, b'\0')
    image[0x143] = 0x80
    image[0x147] = 0x19                                  # MBC5, no RAM
    image[0x148] = size.bit_length()-16
    font = bytearray()
    for ch in range(32, 128):                            # bold heading font, colour 1 on 0
        rows = (*bytes.fromhex(FONT.get(chr(ch), '00000000000000')), 0)
        font.extend(b for row in rows for b in ((row << 1 | row) & 0xFF, 0))
    tiles1, codes = bank1_tiles()
    pages = max(1, math.ceil(count / PAGE))
    heading = f'FIND:{query} {count}/{total}' if query else 'SELECT GAME'
    bg, attr, wall = wall_maps(heading[:20], pages, codes)
    bank0 = bytes(font) + b''.join(tile_bytes(t) for t in wall)
    image[FONT_TILES:FONT_TILES+0x1000] = bank0.ljust(FRAME_TILE*16, b'\0') + frame_tiles()
    image[BANK1_TILES:BANK1_TILES+len(tiles1)] = tiles1
    image[BG_MAP:BG_MAP+len(bg)], image[BG_ATTR:BG_ATTR+len(attr)] = bg, attr
    hidden = [WALL[0]]*4
    image[BG_PALS:BG_PALS+64] = palettes(WALL, DIM, DIM, TITLE, BANNER, hidden, WALL, WALL)
    image[OBJ_PALS:OBJ_PALS+8] = palettes(FRAME)
    image[IDLE_TEXT:IDLE_TEXT+40] = banner_rows('NO MATCHES' if query else 'NO GAMES YET', codes)
    image[LOAD_TEXT:LOAD_TEXT+40] = banner_rows('LOADING...', codes)
    blank = blank_record(codes)
    image[BLANK_RECORD:BLANK_RECORD+len(blank)] = blank
    image[GAME_COUNT:GAME_COUNT+2] = count.to_bytes(2, 'little')
    image[LAST_PAGE:LAST_PAGE+2] = ((pages-1)*PAGE).to_bytes(2, 'little')
    for i, game in enumerate(games):
        data = record(game, covers, codes)
        offset = 0x4000*(1 + i//PER_BANK) + (i % PER_BANK)*RECORD
        image[offset:offset+len(data)] = data
    image[0x14D] = -sum(image[0x134:0x14D])-25 & 255
    checksum = (sum(image) - image[0x14E] - image[0x14F]) & 65535
    image[0x14E:0x150] = checksum.to_bytes(2, 'big')
    return bytes(image)
