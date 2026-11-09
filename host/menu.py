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
    if len(games) > 2032:
        raise ValueError('The launcher image holds at most 2032 game cards (2 MiB)')
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


ART_W, ART_H = 40, 48
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
    """Centre-crop to 5:6 and scale to 40x48 with sips; returns 48 rows of (r, g, b)."""
    info = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(path)],
                          capture_output=True, text=True, check=True).stdout
    w = int(re.search(r'pixelWidth: (\d+)', info).group(1))
    h = int(re.search(r'pixelHeight: (\d+)', info).group(1))
    cw, ch = (h*ART_W // ART_H, h) if w*ART_H > h*ART_W else (w, w*ART_H // ART_W)
    with tempfile.TemporaryDirectory() as tmp:
        crop, out = Path(tmp) / 'crop.png', Path(tmp) / 'art.bmp'
        subprocess.run(['sips', '-s', 'format', 'png', '-c', str(ch), str(cw), str(path),
                        '--out', str(crop)], capture_output=True, check=True)
        subprocess.run(['sips', '-s', 'format', 'bmp', '-z', str(ART_H), str(ART_W), str(crop),
                        '--out', str(out)], capture_output=True, check=True)
        rows = _read_bmp(out.read_bytes())
    if len(rows) != ART_H or len(rows[0]) != ART_W:
        raise ValueError(f'{path}: sips produced {len(rows[0])}x{len(rows)}')
    return rows


def _luma(c):
    return c[0]*3 + c[1]*6 + c[2]


def _quantize(rows):
    """Four representative colours (k-means), darkest first, and per-pixel indices."""
    pixels = [p for row in rows for p in row]
    ordered = sorted(pixels, key=_luma)
    centres = [ordered[len(ordered)*(2*i+1)//8] for i in range(4)]
    for _ in range(16):
        sums = [[0, 0, 0, 0] for _ in range(4)]
        for p in pixels:
            k = min(range(4), key=lambda i: sum((a-b)**2 for a, b in zip(p, centres[i])))
            s = sums[k]
            s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; s[3] += 1
        moved = [(s[0]//s[3], s[1]//s[3], s[2]//s[3]) if s[3] else centres[i]
                 for i, s in enumerate(sums)]
        if moved == centres:
            break
        centres = moved
    centres.sort(key=_luma)
    index = [[min(range(4), key=lambda i: sum((a-b)**2 for a, b in zip(p, centres[i])))
              for p in row] for row in rows]
    return ['#%02X%02X%02X' % c for c in centres], index


def image_art(path):
    st = path.stat()
    key = hashlib.sha1(f'{path.resolve()}|{st.st_mtime_ns}|{st.st_size}|v1'.encode()).hexdigest()
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
            if y > 30 - abs(x-11)//2:
                pixels[y][x] = 1
            if y > 38 - abs(x-31)//2:
                pixels[y][x] = 2
            if (x-30)**2 + (y-10)**2 < 16:
                pixels[y][x] = 3
            if y >= 44 and (x//4 + y//2) % 2:
                pixels[y][x] = 3
    for i in range(9):
        pixels[seed[i+10] % 20 + 2][seed[i+1] % 38 + 1] = 2
    initials = ''.join(word[0] for word in game.title.split() if word[0].isalnum())[:3]
    left = (ART_W - 7*len(initials) + 2) // 2
    for n, ch in enumerate(initials):
        for y, row in enumerate(bytes.fromhex(FONT.get(ch, FONT['?']))):
            for x in range(5):
                if row & (16 >> x):
                    pixels[23+y][left+n*7+x] = 3
    return palette, pixels


def cover(game, folder=None):
    """(480 bytes of 40x48 tiles, 8-byte RGB555 palette) for one game card."""
    path = art_source(game, folder)
    if path is None:
        palette, pixels = procedural_art(game)
    elif path.suffix == '.json':
        data = json.loads(path.read_text())
        palette, rows = data['palette'], data['pixels']
        if len(palette) != 4 or len(rows) != ART_H or any(
                len(row) != ART_W or set(row)-set('0123') for row in rows):
            raise ValueError(f'{path}: card art requires four colours and 40x48 pixels using 0..3')
        pixels = [[int(c) for c in row] for row in rows]
    else:
        palette, pixels = image_art(path)
    return tile_bytes(pixels), palettes(palette)


def text(value, width=20):
    return bytes(ord(c)-32 if c in FONT or c == ' ' else ord('?')-32
                 for c in value.upper()[:width].ljust(width))

# ---------------- card wall (host/arcade/engine.asm) ----------------
ENGINE = ROOT / 'host/arcade/engine.bin'
FONT_TILES, SPRITE_TILES, BG_MAP, BG_ATTR = 0x2000, 0x2800, 0x2900, 0x2B40
BG_PALS, OBJ_PALS, IDLE_TEXT, LOAD_TEXT = 0x2D80, 0x2DC0, 0x2E00, 0x2E40
BLANK_RECORD, GAME_COUNT, LAST_PAGE = 0x3000, 0x3FF0, 0x3FF2
RECORD, PER_BANK, PAGE = 1024, 16, 6
WORLD = 96                                                  # first wall tile, after the font
CARDS = [(8, 16), (56, 16), (104, 16), (16, 72), (64, 72), (112, 72)]   # engine's CardPos

WALL = ['#4A4844', '#F8D830', '#2C2A28', '#605D58']    # concrete, heading text, shadow, speck
BANNER = ['#C8381E', '#1A0E0A', '#F8D040', '#8A2010']  # red, text, stripe, hatch
FRAME = ['#000000', '#F8F8F8', '#B8B8B8', '#202020']   # colour 0 transparent


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


def _noise(seed):
    rnd = random.Random(seed)
    tile = [[0]*8 for _ in range(8)]
    for y in range(8):
        for x in range(8):
            r = rnd.random()
            tile[y][x] = 3 if r < 0.08 else 2 if r < 0.15 else 0
    if seed % 4 == 3:                                    # a short crack
        x = rnd.randrange(8)
        for y in range(8):
            tile[y][x] = 2
            x = max(0, min(7, x + rnd.choice((-1, 0, 1))))
    return tile


def wall_tiles():
    """Concrete noise, card drop shadows (2 px, offset 2 px) and the banner stripe."""
    tiles = {f'noise{i}': _noise(i) for i in range(8)}
    def shadow(cols, rows):
        t = [row[:] for row in tiles['noise0']]
        for y in rows:
            for x in cols:
                t[y][x] = 2
        return t
    tiles['sh_r_top'] = shadow((0, 1), range(2, 8))
    tiles['sh_r'] = shadow((0, 1), range(8))
    tiles['sh_b_left'] = shadow(range(2, 8), (0, 1))
    tiles['sh_b'] = shadow(range(8), (0, 1))
    tiles['sh_c'] = shadow((0, 1), (0, 1))
    tiles['band'] = [[2]*8] + [[3 if (x+y) % 8 in (0, 1) else 0 for x in range(8)]
                               for y in range(1, 8)]
    return tiles


def frame_tiles():
    """8x16 sprite pairs: top edge, bottom edge, left edge, right edge of the 2 px frame."""
    def t(rows):
        return tile_bytes([[int(c) for c in row] for row in rows])
    empty = ['00000000']*8
    return (t(empty) + t(['00000000']*6 + ['11111111']*2)
            + t(['11111111']*2 + ['00000000']*6) + t(empty)
            + t(['00000011']*8)*2 + t(['11000000']*8)*2)


def banner_text(game):
    """Two banner rows: the title, then its second line or the size/type (or why it can't run)."""
    lines = textwrap.wrap(game.title.upper(), 19) or ['']
    second = lines[1] if game.playable and len(lines) > 1 else game.info
    return text(' ' + lines[0]) + text(' ' + second)


def record(game, covers):
    tiles, pal = cover(game, covers)
    dim = shade(pal, 8, 3)
    if not game.playable:
        pal = shade(pal, 11, 4)
    return tiles + pal + dim + banner_text(game) + bytes((int(game.playable),))


def blank_record():
    """Empty card slot: concrete in the wall's colours, so it disappears into the wall."""
    noise = [_noise(i) for i in range(8)]
    pixels = [[noise[(x//8 + y//8*3) % 8][y % 8][x % 8] for x in range(ART_W)] for y in range(ART_H)]
    wall = palettes(WALL[:1] + WALL[:1] + WALL[2:])
    return tile_bytes(pixels) + wall + wall + text('')*2 + bytes((0,))


def wall_maps(heading, pages, tile):
    bg, attr = bytearray(32*18), bytearray(32*18)
    rnd = random.Random(1)
    def put(row, col, value, pal=0):
        bg[row*32+col], attr[row*32+col] = value, pal
    for row in range(15):
        for col in range(32):
            put(row, col, tile[f'noise{rnd.randrange(8) if rnd.random() < 0.6 else 0}'])
    bg[0:20] = text(heading.center(20))
    for k, (x, y) in enumerate(CARDS):
        c0, r0 = x // 8, y // 8
        for r in range(6):
            for c in range(5):
                put(r0+r, c0+c, k*30 + r*5 + c, 0x08 | (1+k))   # VRAM bank 1, palette 1+k
        put(r0, c0+5, tile['sh_r_top'])
        for r in range(1, 6):
            put(r0+r, c0+5, tile['sh_r'])
        if r0 + 6 < 15:
            put(r0+6, c0, tile['sh_b_left'])
            for c in range(1, 5):
                put(r0+6, c0+c, tile['sh_b'])
            put(r0+6, c0+5, tile['sh_c'])
    if pages > 1:
        put(8, 0, text('<', 1)[0])
        put(8, 19, text('>', 1)[0])
    for col in range(32):
        put(15, col, tile['band'], 7)
        put(16, col, 0, 7)
        put(17, col, 0, 7)
    return bg, attr


def build(games, covers=None, query="", total=None):
    """Card-wall launcher ROM: the engine plus graphics and one 1 KiB record per game."""
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
    font = []
    for ch in range(32, 128):
        rows = bytes.fromhex(FONT.get(chr(ch), '00000000000000'))
        font.extend(b for row in (*rows, 0) for b in (row << 1, 0))
    tiles = wall_tiles()
    tile = {name: WORLD + i for i, name in enumerate(tiles)}
    world = b''.join(tile_bytes(t) for t in tiles.values())
    image[FONT_TILES:FONT_TILES+0x800] = (bytes(font) + world).ljust(0x800, b'\0')
    image[SPRITE_TILES:SPRITE_TILES+128] = frame_tiles()
    pages = max(1, math.ceil(count / PAGE))
    heading = f'FIND:{query} {count}/{total}' if query else 'SELECT GAME'
    bg, attr = wall_maps(heading[:20], pages, tile)
    image[BG_MAP:BG_MAP+len(bg)], image[BG_ATTR:BG_ATTR+len(attr)] = bg, attr
    image[BG_PALS:BG_PALS+64] = palettes(WALL, *[WALL]*6, BANNER)
    image[OBJ_PALS:OBJ_PALS+8] = palettes(FRAME)
    image[IDLE_TEXT:IDLE_TEXT+40] = (text(' NO MATCHES' if query else ' NO GAMES YET')
                                     + text(' TRY ANOTHER SEARCH' if query else ' ADD .GB/.GBC FILES'))
    image[LOAD_TEXT:LOAD_TEXT+20] = text(' LOADING...')
    blank = blank_record()
    image[BLANK_RECORD:BLANK_RECORD+len(blank)] = blank
    image[GAME_COUNT:GAME_COUNT+2] = count.to_bytes(2, 'little')
    image[LAST_PAGE:LAST_PAGE+2] = ((pages-1)*PAGE).to_bytes(2, 'little')
    for i, game in enumerate(games):
        data = record(game, covers)
        offset = 0x4000*(1 + i//PER_BANK) + (i % PER_BANK)*RECORD
        image[offset:offset+len(data)] = data
    image[0x14D] = -sum(image[0x134:0x14D])-25 & 255
    checksum = (sum(image) - image[0x14E] - image[0x14F]) & 65535
    image[0x14E:0x150] = checksum.to_bytes(2, 'big')
    return bytes(image)
