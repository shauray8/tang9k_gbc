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
from sm83asm import Asm

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
        elif header[0x147] not in (0, 1, 2, 3, 15, 16, 17, 18, 19, 25, 26, 27, 28, 29, 30):
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


def build(games, covers=None, query="", total=None):
    count = len(games)
    a = Asm(0x150)
    def call(label): a.call(label)
    def load_selected():
        a.emit(0xF0, 0x90, 0x6F, 0xF0, 0x91, 0x67)
    def dma(source, destination, blocks):
        for reg, value in ((0x51, source >> 8), (0x52, source & 255),
                           (0x53, destination >> 8), (0x54, destination & 255), (0x55, blocks-1)):
            a.wr(0xFF00+reg, value)
    a.emit(0xF3)
    a.w16(0x31, 0xFFFE)
    a.wr(0xFFFF, 0)
    a.wr(0xFF40, 0)
    a.wr(0xFF00, 0x30)
    a.wr(0xFF4D, 1)
    a.emit(0x10, 0)
    for reg, value in ((0x90, 0), (0x91, 0), (0x92, 15), (0x93, 15), (0x94, 0)):
        a.wr(0xFF00+reg, value)
    a.wr(0xFF4F, 0)
    dma(0x2000, 0x8000, 96)
    dma(0x2600, 0x8A80, 8)
    dma(0x2700, 0x9800, 64)
    a.wr(0xFF4F, 1)
    dma(0x2B00, 0x9800, 64)
    a.wr(0xFF4F, 0)
    a.w16(0x21, 0x2F00)
    a.wr(0xFF68, 0x80)
    a.emit(0x06, 56)
    l = a.label()
    a.emit(0x2A, 0xE0, 0x69, 0x05)
    a.jr(0x20, l)
    call('render')
    a.wr(0xFF40, 0x91)
    a.label('main')
    call('vblank')
    for select, previous, event in ((0x20, 0x92, 0x96), (0x10, 0x93, 0x95)):
        a.wr(0xFF00, select)
        a.emit(0xF0, 0x00, 0xE6, 15, 0x4F, 0x2F, 0x47, 0xF0, previous,
               0xA0, 0xE0, event, 0x79, 0xE0, previous)
    if count:
        a.emit(0xF0, 0x96, 0xCB, 0x5F)  # BIT 3,A: down selects next
        a.jp(0xCA, 'check_up')
        load_selected()
        a.emit(0x23)
        a.w16(0x11, count)
        a.emit(0x7C, 0xBA)
        a.jp(0xC2, 'store_cursor')
        a.emit(0x7D, 0xBB)
        a.jp(0xC2, 'store_cursor')
        a.w16(0x21, 0)
        a.jp(0xC3, 'store_cursor')
        a.label('check_up')
        a.emit(0xF0, 0x96, 0xCB, 0x57)
        a.jp(0xCA, 'check_pages')
        load_selected()
        a.emit(0x7C, 0xB5)
        a.jr(0x20, 'cursor_nonzero')
        a.w16(0x21, count)
        a.label('cursor_nonzero')
        a.emit(0x2B)
        a.jp(0xC3, 'store_cursor')
        a.label('check_pages')
        a.emit(0xF0, 0x96, 0xE6, 3)
        a.jp(0xCA, 'check_play')
        load_selected()
        call('record')
        a.w16(0x01, 0x1F6)
        a.emit(0x09, 0xF0, 0x96, 0xCB, 0x47)
        a.jr(0x28, 'page_pointer')
        a.emit(0x23, 0x23)
        a.label('page_pointer')
        a.emit(0x2A, 0x4F, 0x7E, 0x67, 0x69)
        a.jp(0xC3, 'store_cursor')
        a.label('store_cursor')
        a.emit(0x7D, 0xE0, 0x90, 0x7C, 0xE0, 0x91)
        call('render')
        a.label('check_play')
        a.emit(0xF0, 0x95, 0xE6, 9)
        a.jp(0xCA, 'frame_end')
        a.emit(0xF0, 0x94, 0xB7)
        a.jp(0xCA, 'frame_end')
        a.ld_a(0xA5); call('send')
        a.emit(0xF0, 0x90); call('send')
        a.emit(0xF0, 0x91); call('send')
        a.emit(0x47, 0xF0, 0x90, 0xA8, 0xEE, 0x5A); call('send')
        a.label('loading')
        a.emit(0x76)
        a.jr(0x18, 'loading')
    a.label('frame_end')
    l = a.label()
    a.emit(0xF0, 0x44, 0xB7)
    a.jr(0x20, l)
    a.jp(0xC3, 'main')
    a.label('vblank')
    a.emit(0xF0, 0x44, 0xFE, 144)
    a.jr(0x20, 'vblank')
    a.emit(0xC9)
    a.label('next_vblank')
    a.emit(0xF0, 0x40, 0xE6, 0x80, 0xC8)  # bootstrap renders with LCD off
    l = a.label()
    a.emit(0xF0, 0x44, 0xB7)
    a.jr(0x20, l)
    a.jp(0xC3, 'vblank')
    a.label('send')
    a.emit(0xF5, 0xE0, 1, 0x3E, 0x81, 0xE0, 2, 0xF1, 0xC9)
    a.label('record')
    a.w16(0x11, count)
    a.emit(0x7C, 0xBA)
    a.jr(0x38, 'record_valid')
    a.jr(0x20, 'record_blank')
    a.emit(0x7D, 0xBB)
    a.jr(0x38, 'record_valid')
    a.label('record_blank')
    a.w16(0x21, 0x2F40)
    a.emit(0xC9)
    a.label('record_valid')
    a.emit(0x7C, 0x07, 0x07, 0x07, 0x47, 0x7D, 0x07, 0x07, 0x07,
           0xE6, 7, 0xB0, 0x3C)
    a.st(0x2000)
    a.emit(0x7D, 0xE6, 31, 0x87, 0xF6, 0x40, 0x67, 0x2E, 0, 0xC9)
    for width in (13, 20):
        a.label(f'text{width}')
        for _ in range(width):
            a.emit(0x2A, 0x12, 0x13)
        a.emit(0xC9)
    a.label('render')
    load_selected()
    call('record')
    a.w16(0x01, 0x1D9)
    a.emit(0x09, 0x2A, 0xE0, 0x98, 0x2A, 0xE0, 0x99, 0x7E, 0xE0, 0x9C)
    # Redraw the list in one VBlank, then details in the next. This avoids
    # mode-3 VRAM writes and LCD-off flashing, even across a ROM bank/page.
    for row in range(5):
        a.emit(0xF0, 0x98, 0x6F, 0xF0, 0x99, 0x67)
        if row:
            a.w16(0x11, row); a.emit(0x19)
        call('record')
        a.w16(0x01, 0x1D8)
        a.emit(0x09, 0x2A, 0xE0, 0x9E, 0x23, 0x23, 0x23)
        for line in range(2):
            a.w16(0x11, 0x9801+(4+row*2+line)*32)
            call('text13')
        a.emit(0xF0, 0x9E, 0xB7)
        disabled = f'row{row}_disabled'
        palette_ready = f'row{row}_palette'
        a.jr(0x28, disabled)
        a.emit(0xAF)
        a.jr(0x18, palette_ready)
        a.label(disabled)
        a.ld_a(6)
        a.label(palette_ready)
        if count:
            a.emit(0x47, 0xF0, 0x9C, 0xFE, row, 0x78)
            unselected = f'row{row}_unselected'
            a.jr(0x20, unselected)
            a.ld_a(4)
            a.label(unselected)
        a.emit(0x4F)
        a.wr(0xFF4F, 1)
        a.emit(0x79)
        for line in range(2):
            a.w16(0x11, 0x9800+(4+row*2+line)*32)
            for _ in range(14):
                a.emit(0x12, 0x13)
        a.wr(0xFF4F, 0)
    call('next_vblank')
    load_selected()
    call('record')
    a.emit(0x7C, 0xE0, 0x51, 0x7D, 0xE0, 0x52)
    a.wr(0xFF53, 0x86)
    a.wr(0xFF54, 0)
    a.wr(0xFF55, 23)
    a.w16(0x01, 0x180); a.emit(0x09)
    a.wr(0xFF68, 0x88)
    a.emit(0x06, 8)
    l = a.label()
    a.emit(0x2A, 0xE0, 0x69, 0x05)
    a.jr(0x20, l)
    for destination in (0x99C0, 0x99E0, 0x9A00, 0x9A20):
        a.w16(0x11, destination); call('text20')
    a.emit(0x7E, 0xE0, 0x94, 0xC9)
    code = a.link()
    if 0x150 + len(code) > 0x2000:
        raise ValueError('Launcher code overlaps graphics')
    banks = 1 + math.ceil(count/32)
    size = max(0x8000, 1 << (banks*0x4000-1).bit_length())
    image = bytearray(size)
    image[0x100:0x104] = bytes((0, 0xC3, 0x50, 1))
    image[0x134:0x143] = b'TANG LIBRARY'.ljust(15, b'\0')
    image[0x143] = 0x80
    image[0x147] = 0x19              # MBC5, no RAM
    image[0x148] = size.bit_length()-16
    image[0x150:0x150+len(code)] = code
    font = []
    for ch in range(32, 128):
        rows = bytes.fromhex(FONT.get(chr(ch), '00000000000000'))
        font.extend(b for row in (*rows, 0) for b in (row << 1, 0))
    image[0x2000:0x2600] = bytes(font)
    border = []
    for kind in range(6):
        pixels = [[0]*8 for _ in range(8)]
        for y in range(8):
            for x in range(8):
                if (kind in (0, 2, 3) and y == 0 or kind in (1, 4, 5) and y == 7 or
                    kind in (2, 4) and x == 0 or kind in (3, 5) and x == 7):
                    pixels[y][x] = 2
        border.extend(tile_bytes(pixels))
    image[0x2600:0x2660] = bytes(border)
    tilemap, attrs = bytearray(1024), bytearray(1024)
    tilemap[0:20] = text('TANG / LIBRARY')
    tilemap[32:52] = text(f'{count}/{count if total is None else total} GAMES / MAC')
    tilemap[64:84] = text('FIND: '+query if query else 'UP/DOWN SELECT')
    for y in range(6):
        for x in range(4):
            tilemap[(y+4)*32+15+x] = 96+y*4+x
            attrs[(y+4)*32+15+x] = 1
    for x in range(6):
        tilemap[3*32+14+x] = 170 if x == 0 else 171 if x == 5 else 168
        tilemap[10*32+14+x] = 172 if x == 0 else 173 if x == 5 else 169
        attrs[3*32+14+x] = attrs[10*32+14+x] = 5
    for y in range(4, 10):
        tilemap[y*32+14] = 174
        tilemap[y*32+19] = 175
        attrs[y*32+14] = attrs[y*32+19] = 5
    # Two extra border tiles are loaded with the same initial GDMA burst.
    vertical = tile_bytes([[2 if x == 0 else 0 for x in range(8)] for _ in range(8)])
    vertical += tile_bytes([[2 if x == 7 else 0 for x in range(8)] for _ in range(8)])
    image[0x2660:0x2680] = vertical
    image[0x2700:0x2B00] = tilemap
    image[0x2B00:0x2F00] = attrs
    base = ['#101827', '#F2F5E9', '#62D9D0', '#7191AE']
    palette = base*4 + ['#62D9D0', '#101827', '#62D9D0', '#101827'] + base
    palette += ['#101827', '#64788A', '#62D9D0', '#64788A']
    image[0x2F00:0x2F38] = b''.join(rgb555(c).to_bytes(2, 'little') for c in palette)
    blank = bytes(392) + wrapped_text('NO MATCHES' if query else 'NO GAMES FOUND', 20, 2)
    blank += text('TRY ANOTHER SEARCH' if query else 'ADD GB OR GBC FILES') + text('SEARCH ON THE MAC')
    blank += bytes(4) + text('', 26) + bytes(4)
    image[0x2F40:0x2F40+len(blank)] = blank
    last_page = (max(count, 1)-1)//5*5
    for i, game in enumerate(games):
        page, row = i//5*5, i%5
        previous = page-5 if page else last_page
        following = page+5 if page+5 < count else 0
        record = cover(game, covers) + wrapped_text(game.title, 20, 2) + text(game.info)
        record += text('Z PLAY  <> PAGE' if game.playable else 'NOT SUPPORTED YET')
        record += bytes((int(game.playable),)) + page.to_bytes(2, 'little') + bytes((row,))
        record += wrapped_text(game.title, 13, 2)
        record += previous.to_bytes(2, 'little') + following.to_bytes(2, 'little')
        offset = 0x4000+i*512
        image[offset:offset+len(record)] = record
    image[0x14D] = -sum(image[0x134:0x14D])-25 & 255
    checksum = sum(image) & 65535
    image[0x14E:0x150] = checksum.to_bytes(2, 'big')
    return bytes(image)
