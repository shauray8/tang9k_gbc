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


def build(games, covers=None):
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
    a.emit(0x06, 40)
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
        a.emit(0xF0, 0x96, 0xCB, 0x47)  # BIT 0,A: right
        a.jp(0xCA, 'check_left')
        load_selected()
        a.emit(0x23)
        a.w16(0x11, count)
        a.emit(0x7C, 0xBA)
        a.jr(0x20, 'store_cursor')
        a.emit(0x7D, 0xBB)
        a.jr(0x20, 'store_cursor')
        a.w16(0x21, 0)
        a.jp(0xC3, 'store_cursor')
        a.label('check_left')
        a.emit(0xF0, 0x96, 0xCB, 0x4F)
        a.jp(0xCA, 'check_play')
        load_selected()
        a.emit(0x7C, 0xB5)
        a.jr(0x20, 'cursor_nonzero')
        a.w16(0x21, count)
        a.label('cursor_nonzero')
        a.emit(0x2B)
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
    a.label('text20')
    for _ in range(20):
        a.emit(0x2A, 0x12, 0x13)     # pre-encoded font tiles; no per-character conversion
    a.emit(0xC9)
    a.label('render')
    for slot, destination in enumerate((0x8600, 0x8780, 0x8900)):
        load_selected()
        if slot:
            a.w16(0x11, slot); a.emit(0x19)
        call('record')
        a.emit(0x7C, 0xE0, 0x51, 0x7D, 0xE0, 0x52)
        a.wr(0xFF53, destination >> 8)
        a.wr(0xFF54, destination & 255)
        a.wr(0xFF55, 23)
        a.w16(0x01, 0x180); a.emit(0x09)
        a.wr(0xFF68, 0x80 | (slot+1)*8)
        a.emit(0x06, 8)
        l = a.label()
        a.emit(0x2A, 0xE0, 0x69, 0x05)
        a.jr(0x20, l)
        if slot == 0:
            for destination in (0x9960, 0x99A0, 0x9A00):
                a.w16(0x11, destination); call('text20')
            a.emit(0x7E, 0xE0, 0x94)
    a.emit(0xC9)
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
    tilemap[32:52] = text(f'MAC / {count} GAMES')
    for slot, x in enumerate((1, 8, 15)):
        for y in range(6):
            for dx in range(4):
                pos = (y+3)*32+x+dx
                tilemap[pos] = 96+slot*24+y*4+dx
                attrs[pos] = slot+1
    for x in range(6):
        tilemap[2*32+x] = 170 if x == 0 else 171 if x == 5 else 168
        tilemap[9*32+x] = 172 if x == 0 else 173 if x == 5 else 169
        attrs[2*32+x] = attrs[9*32+x] = 4
    for y in range(3, 9):
        # Vertical edges share the left/right corner's vertical stroke.
        tilemap[y*32] = 174
        tilemap[y*32+5] = 175
        attrs[y*32] = attrs[y*32+5] = 4
    # Two extra border tiles are loaded with the same initial GDMA burst.
    vertical = tile_bytes([[2 if x == 0 else 0 for x in range(8)] for _ in range(8)])
    vertical += tile_bytes([[2 if x == 7 else 0 for x in range(8)] for _ in range(8)])
    image[0x2660:0x2680] = vertical
    image[0x2700:0x2B00] = tilemap
    image[0x2B00:0x2F00] = attrs
    palette = ['#101827', '#F2F5E9', '#62D9D0', '#7191AE']*5
    image[0x2F00:0x2F28] = b''.join(rgb555(c).to_bytes(2, 'little') for c in palette)
    blank = bytes(384) + bytes(8) + text('NO GAMES FOUND') + text('MAC LIBRARY') + text('ADD .GB / .GBC FILES') + bytes(1)
    image[0x2F40:0x2F40+len(blank)] = blank
    for i, game in enumerate(games):
        record = cover(game, covers) + text(game.title) + text(game.info)
        record += text('A PLAY   <> BROWSE' if game.playable else 'NOT SUPPORTED YET')
        record += bytes((int(game.playable),))
        offset = 0x4000+i*512
        image[offset:offset+len(record)] = record
    image[0x14D] = -sum(image[0x134:0x14D])-25 & 255
    checksum = sum(image) & 65535
    image[0x14E:0x150] = checksum.to_bytes(2, 'big')
    return bytes(image)
