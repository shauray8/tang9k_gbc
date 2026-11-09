"""Build the FPGA's GBC launcher ROM from a Mac-backed game library.

The launcher uses the existing SM83, colour PPU and GDMA. No second renderer.
Optional covers: <ROM stem>.json or <lowercase-title-slug>.json, with four
#RRGGBB palette entries and 48 rows of 32 pixel indices using 0..3.
Artwork is original procedural pixel art when no cover is supplied.
This is a file-library backend, not an SD SPI model.
"""
import hashlib
import json
import math
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
        raise ValueError('The current ROM address space supports at most 4064 menu records')
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


def cover(game, folder=None):
    path = Path(folder) / (game.path.stem + '.json') if folder else None
    if path and not path.exists():
        slug = re.sub(r'[^a-z0-9]+', '-', game.title.lower()).strip('-')
        path = Path(folder) / (slug + '.json')
    if path and path.exists():
        data = json.loads(path.read_text())
        palette, rows = data['palette'], data['pixels']
        if len(palette) != 4 or len(rows) != 48 or any(len(row) != 32 or set(row)-set('0123') for row in rows):
            raise ValueError(f'{path}: cover requires four colours and 32x48 pixels using 0..3')
        pixels = [[int(c) for c in row] for row in rows]
    else:
        seed = hashlib.sha256(game.path.name.encode()).digest()
        palettes = (
            ['#101827', '#20546B', '#42B7A0', '#F5E7AD'],
            ['#171C38', '#534178', '#D66791', '#FFE4AF'],
            ['#101B2C', '#34518A', '#61BAD1', '#F2E9CE'],
        )
        palette = palettes[seed[0] % len(palettes)]
        pixels = [[0 for _ in range(32)] for _ in range(48)]
        for y in range(48):
            for x in range(32):
                if y > 30 - abs(x-9)//2:
                    pixels[y][x] = 1
                if y > 38 - abs(x-25)//2:
                    pixels[y][x] = 2
                if (x-24)**2 + (y-10)**2 < 16:
                    pixels[y][x] = 3
                if y >= 44 and (x//4+y//2) % 2:
                    pixels[y][x] = 3
        for i in range(9):
            x, y = seed[i+1] % 30 + 1, seed[i+10] % 20 + 2
            pixels[y][x] = 2
        initials = ''.join(word[0] for word in game.title.split() if word[0].isalnum())[:3]
        for n, ch in enumerate(initials):
            rows = bytes.fromhex(FONT.get(ch, FONT['?']))
            for y, row in enumerate(rows):
                for x in range(5):
                    if row & (16 >> x):
                        pixels[23+y][6+n*7+x] = 3
    colors = b''.join(rgb555(c).to_bytes(2, 'little') for c in palette)
    return tile_bytes(pixels) + colors


def text(value, width=20):
    return bytes(ord(c)-32 if c in FONT or c == ' ' else ord('?')-32
                 for c in value.upper()[:width].ljust(width))

def wrapped_text(value, width, lines):
    parts = textwrap.wrap(value.upper(), width=width)[:lines]
    return b''.join(text(part, width) for part in parts + ['']*(lines-len(parts)))


# ---------------- arcade hall (host/arcade/engine.asm) ----------------
ENGINE = ROOT / 'host/arcade/engine.bin'
FONT_TILES, SPRITE_TILES, BG_MAP, BG_ATTR = 0x2000, 0x2A00, 0x2C00, 0x2E00
WIN_MAP, WIN_ATTR, BG_PALS, OBJ_PALS = 0x3000, 0x3080, 0x3100, 0x3140
MARQUEE_PALS, IDLE_TEXT, LOAD_TEXT, BLANK_RECORD = 0x3180, 0x31A0, 0x3200, 0x3400
GAME_COUNT, LAST_ROOM = 0x3FF0, 0x3FF2
WORLD, COVER_TILE = 96, 160

HALL = ['#120F24', '#2D2357', '#6C5BB8', '#F7D774']      # bg, wall, cabinet, lights
TEXT = ['#120F24', '#F2F5E9', '#62D9D0', '#7191AE']
MARQUEE_DIM = ['#3A2E6B', '#B9A9F0', '#3A2E6B', '#3A2E6B']
MARQUEE_LIT = ['#F7D774', '#2A1B4F', '#F7D774', '#F7D774']
PLAYER = ['#000000', '#F7C59F', '#3FA7D6', '#1A1A2E']    # colour 0 transparent
COIN = ['#000000', '#F7D774', '#C08A2E', '#FFFFFF']

# 8x8 world tiles, '0'-'3' = palette colours of HALL
WORLD_TILES = {
    'blank': ['00000000'] * 8,
    'wall': ['11111111', '11111111', '11101111', '11111111',
             '11111111', '11111111', '11111110', '11111111'],
    'light': ['11111111', '00010000', '00010000', '00333000',
              '03333300', '00333000', '00000000', '00000000'],
    'floor_a': ['22222221', '22222211', '22222111', '22221111',
                '22211111', '22111111', '21111111', '11111111'],
    'floor_b': ['11111112', '11111122', '11111222', '11112222',
                '11122222', '11222222', '12222222', '22222222'],
    'cab_tl': ['00333333', '03222222', '32222222', '32200000',
               '32200000', '32200000', '32200000', '32222222'],
    'cab_tr': ['33333300', '22222230', '22222223', '00000223',
               '00000223', '00000223', '00000223', '22222223'],
    'cab_l': ['32222222', '32222222', '32200000', '32200000',
              '32200000', '32200000', '32222222', '32222222'],
    'cab_r': ['22222223', '22222223', '00000223', '00000223',
              '00000223', '00000223', '22222223', '22222223'],
    'panel_l': ['32222222', '32333333', '32322222', '32322222',
                '32322222', '32322222', '32333333', '32222222'],
    'stick': ['22222222', '33333333', '22233222', '22333322',
              '22233222', '22213222', '33333333', '22222222'],
    'buttons': ['22222222', '33333333', '22222222', '23322332',
                '23322332', '22222222', '33333333', '22222222'],
    'panel': ['22222222', '33333333', '22222222', '22222222',
              '22222222', '22222222', '33333333', '22222222'],
    'panel_r': ['22222223', '33333323', '22222323', '22222323',
                '22222323', '22222323', '33333323', '22222223'],
    'base_l': ['32222222', '32222222', '32222222', '32222222',
               '32222222', '32222222', '32222222', '11111111'],
    'base': ['22222222', '22222222', '22222222', '22222222',
             '22222222', '22222222', '22222222', '11111111'],
    'slot': ['22222222', '22000022', '22033022', '22000022',
             '22222222', '22222222', '22222222', '11111111'],
    'base_r': ['22222223', '22222223', '22222223', '22222223',
               '22222223', '22222223', '22222223', '11111111'],
    'edge': ['00000000', '00000000', '11111111', '11111111',
             '11111111', '11111111', '11111111', '11111111'],
}
TILE = {name: WORLD + i for i, name in enumerate(WORLD_TILES)}

# 16x16 player frames: stand, walk 1, walk 2, jump ('.' transparent, s skin, b shirt, d dark)
PLAYER_FRAMES = [
    ['.....dddddd.....', '....dbbbbbbd....', '...dbbbbbbbbd...', '...ddddddddd....',
     '...dssdssdss....', '...dsssssss.....', '....dsssss......', '.....ddddd......',
     '....dbbbbbd.....', '...dbbbbbbbd....', '...sdbbbbbds....', '...sdbbbbbds....',
     '....ddddddd.....', '....dd...dd.....', '....dd...dd.....', '...ddd...ddd....'],
    ['.....dddddd.....', '....dbbbbbbd....', '...dbbbbbbbbd...', '...ddddddddd....',
     '...dssdssdss....', '...dsssssss.....', '....dsssss......', '.....ddddd......',
     '....dbbbbbd.....', '...dbbbbbbbds...', '..sdbbbbbbd.....', '....dbbbbbd.....',
     '....ddddddd.....', '...dd....dd.....', '..dd......dd....', '..dd.......dd...'],
    ['.....dddddd.....', '....dbbbbbbd....', '...dbbbbbbbbd...', '...ddddddddd....',
     '...dssdssdss....', '...dsssssss.....', '....dsssss......', '.....ddddd......',
     '....dbbbbbd.....', '..sdbbbbbbbd....', '....dbbbbbbds...', '....dbbbbbd.....',
     '....ddddddd.....', '.....dd.dd......', '.....dd.dd......', '....ddd.ddd.....'],
    ['.....dddddd.....', '....dbbbbbbd....', '...dbbbbbbbbd...', '...ddddddddd....',
     '...dssdssdss....', '..sdsssssss.s...', '..s.dsssss..s...', '.....ddddd......',
     '....dbbbbbd.....', '...dbbbbbbbd....', '...dbbbbbbbd....', '....ddddddd.....',
     '...dd.....dd....', '..dd.......dd...', '................', '................'],
]
COIN_FRAMES = [
    ['..1111..', '.122221.', '12233221', '12232221', '12232221', '12233221', '.122221.', '..1111..'],
    ['...11...', '...12...', '...12...', '...13...', '...13...', '...12...', '...12...', '...11...'],
]


def _pixels(rows, legend):
    return [[legend[c] for c in row] for row in rows]


def sprite_tiles():
    """8x16 OBJ mode: each 16x16 frame is a left and right column of two tiles."""
    out = bytearray()
    legend = {'.': 0, 's': 1, 'b': 2, 'd': 3}
    for frame in PLAYER_FRAMES:
        px = _pixels(frame, legend)
        for half in (0, 8):
            out += tile_bytes([row[half:half+8] for row in px])
    for frame in COIN_FRAMES:
        out += tile_bytes(_pixels(frame, {'.': 0, '1': 1, '2': 2, '3': 3}))
        out += bytes(16)
    return bytes(out).ljust(24*16, b'\0')


def palettes(*sets):
    return b''.join(rgb555(c).to_bytes(2, 'little') for p in sets for c in p)


def marquee(title):
    words = [w for w in re.split(r'[^A-Z0-9]+', title.upper()) if w]
    letters = ''.join(w[0] for w in words) if len(words) > 1 else (words[0] if words else '?')
    return text(letters[:4].center(4), 4)


def grey(record_palette):
    out = bytearray()
    for i in range(0, 8, 2):
        c = int.from_bytes(record_palette[i:i+2], 'little')
        y = ((c & 31)*3 + (c >> 5 & 31)*6 + (c >> 10 & 31)) // 10 // 2 + 4
        out += (y | y << 5 | y << 10).to_bytes(2, 'little')
    return bytes(out)


def record(game, covers):
    art = cover(game, covers)
    tiles, pal = art[:384], art[384:392]
    hint = 'A: INSERT COIN' if game.playable else 'OUT OF ORDER'
    return (tiles + (pal if game.playable else grey(pal)) + wrapped_text(game.title, 20, 2)
            + text(game.info) + text(hint) + bytes((int(game.playable),)) + marquee(game.title))


def blank_record():
    pixels = [[0]*32 for _ in range(48)]
    for y in range(48):
        for x in range(32):
            if (x + y) % 6 == 0:
                pixels[y][x] = 1
    for y, row in enumerate(bytes.fromhex(FONT['?'])):
        for x in range(5):
            if row & (16 >> x):
                for dy in range(2):
                    for dx in range(2):
                        pixels[17+2*y+dy][11+2*x+dx] = 3
    return (tile_bytes(pixels) + palettes(['#0B0A16', '#1E1A33', '#2D2357', '#4B3F7A'])
            + wrapped_text('EMPTY CABINET', 20, 2) + text('') + text('ADD MORE GAMES')
            + bytes((0,)) + text('----', 4))


def hall_maps():
    bg, attr = bytearray(32*14), bytearray(32*14)
    def put(row, col, tile, pal=0):
        bg[row*32+col], attr[row*32+col] = tile, pal
    for col in range(32):
        put(1, col, TILE['light'] if col % 3 == 1 else TILE['blank'])
        for row in range(2, 11):
            put(row, col, TILE['wall'])
        put(11, col, TILE['edge'])
        put(12, col, TILE['floor_a' if col % 2 else 'floor_b'])
        put(13, col, TILE['floor_b' if col % 2 else 'floor_a'])
    for k in range(3):
        c = 7*k
        put(2, c, TILE['cab_tl'])
        put(2, c+5, TILE['cab_tr'])
        for i in range(4):
            put(2, c+1+i, 0, 5+k)                   # marquee text, filled per room
        for r in range(6):
            put(3+r, c, TILE['cab_l'])
            put(3+r, c+5, TILE['cab_r'])
            for i in range(4):
                put(3+r, c+1+i, COVER_TILE + 24*k + r*4 + i, 1+k)
        for i, name in enumerate(('panel_l', 'stick', 'buttons', 'panel', 'panel', 'panel_r')):
            put(9, c+i, TILE[name])
        for i, name in enumerate(('base_l', 'base', 'slot', 'base', 'base', 'base_r')):
            put(10, c+i, TILE[name])
    return bg, attr


def banner(lines):
    return b''.join(text(line) for line in (lines + ['']*4)[:4])


def build(games, covers=None, query="", total=None):
    """Arcade-hall launcher ROM: the engine plus graphics and one record per game."""
    count = len(games)
    total = count if total is None else total
    banks = 1 + math.ceil(count/32)
    size = max(0x8000, 1 << (banks*0x4000-1).bit_length())
    image = bytearray(size)
    image[:0x2000] = ENGINE.read_bytes()[:0x2000]
    image[0x134:0x143] = b'TANG ARCADE'.ljust(15, b'\0')
    image[0x143] = 0x80
    image[0x147] = 0x19                                  # MBC5, no RAM
    image[0x148] = size.bit_length()-16
    font = []
    for ch in range(32, 128):
        rows = bytes.fromhex(FONT.get(chr(ch), '00000000000000'))
        font.extend(b for row in (*rows, 0) for b in (row << 1, 0))
    world = b''.join(tile_bytes(_pixels(t, {c: int(c) for c in '0123'})) for t in WORLD_TILES.values())
    image[FONT_TILES:FONT_TILES+0xA00] = (bytes(font) + world).ljust(0xA00, b'\0')
    image[SPRITE_TILES:SPRITE_TILES+24*16] = sprite_tiles()
    bg, attr = hall_maps()
    heading = f'FIND:{query} {count}/{total}' if query else f'TANG ARCADE {count} GAMES'
    bg[0:20], attr[0:20] = text(heading), bytes((4,))*20
    image[BG_MAP:BG_MAP+len(bg)], image[BG_ATTR:BG_ATTR+len(attr)] = bg, attr
    image[WIN_MAP:WIN_MAP+128], image[WIN_ATTR:WIN_ATTR+128] = bytes(128), bytes((4,))*128
    image[BG_PALS:BG_PALS+64] = palettes(HALL, HALL, HALL, HALL, TEXT,
                                         MARQUEE_DIM, MARQUEE_DIM, MARQUEE_DIM)
    image[OBJ_PALS:OBJ_PALS+16] = palettes(PLAYER, COIN)
    image[MARQUEE_PALS:MARQUEE_PALS+16] = palettes(MARQUEE_DIM, MARQUEE_LIT)
    image[IDLE_TEXT:IDLE_TEXT+80] = banner(
        ['NO MATCHES' if query and not count else 'WALK TO A CABINET',
         '<> WALK  B RUN', 'UP JUMP', 'A OR START: PLAY'])
    image[LOAD_TEXT:LOAD_TEXT+80] = banner(['COIN INSERTED!', 'LOADING GAME...', '', 'HANG TIGHT'])
    blank = blank_record()
    image[BLANK_RECORD:BLANK_RECORD+len(blank)] = blank
    image[GAME_COUNT:GAME_COUNT+2] = count.to_bytes(2, 'little')
    image[LAST_ROOM:LAST_ROOM+2] = ((max(count, 1)-1)//3*3).to_bytes(2, 'little')
    for i, game in enumerate(games):
        data = record(game, covers)
        offset = 0x4000*(1 + i//32) + (i % 32)*512
        image[offset:offset+len(data)] = data
    image[0x14D] = -sum(image[0x134:0x14D])-25 & 255
    checksum = (sum(image) - image[0x14E] - image[0x14F]) & 65535
    image[0x14E:0x150] = checksum.to_bytes(2, 'big')
    return bytes(image)
