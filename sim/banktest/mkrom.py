#!/usr/bin/env python3
"""Synthetic SM83 test ROMs for the banked WRAM/VRAM milestone (original code, no copyrighted data).

usage: mkrom.py <outdir>   -> bank_dmg.gb (header 0x143 = 0x00), bank_cgb.gb (0x143 = 0x80)
                              plus .lst files mapping check numbers to descriptions.

Each ROM checks the memory map from a real CPU program, reports over serial ("Passed", or the failing
check number as one raw byte followed by "Failed"), then draws a solid screen with LCDC=91, BGP=E4 and
loops: shade 1 = pass, shade 3 = fail (BG map cleared to tile 0; tile 0 low bytes FF, high 00/FF).
"""
import os
import sys

DMA_ROUTINE = [0xE0, 0x46,   # LDH (46),A    start OAM DMA from A<<8
               0x3E, 0x30,   # LD A,48       48 x 4 M-cycles > 160
               0x3D,         # DEC A
               0x20, 0xFD,   # JR NZ,-3
               0xC9]         # RET


class Asm:
    def __init__(self, org):
        self.org = org
        self.b = bytearray()
        self.labels = {}
        self.fix = []
        self.checks = []
        self.n = 0

    def pc(self):
        return self.org + len(self.b)

    def emit(self, *bs):
        self.b += bytes(bs)

    def label(self, name=None):
        if name is None:
            self.n += 1
            name = f'.L{self.n}'
        self.labels[name] = self.pc()
        return name

    def w16(self, op, v):
        self.emit(op, v & 0xFF, v >> 8)

    def jp(self, op, lab):           # JP/CALL family with absolute target
        self.emit(op, 0, 0)
        self.fix.append((len(self.b) - 2, lab, 'abs'))

    def jr(self, op, lab):           # JR family with relative target
        self.emit(op, 0)
        self.fix.append((len(self.b) - 1, lab, 'rel'))

    def link(self):
        for off, lab, kind in self.fix:
            t = self.labels[lab]
            if kind == 'abs':
                self.b[off], self.b[off + 1] = t & 0xFF, t >> 8
            else:
                r = t - (self.org + off + 1)
                assert -128 <= r < 128, lab
                self.b[off] = r & 0xFF
        return bytes(self.b)

    # ---- instructions / macros ----
    def ld_a(self, v):
        self.emit(0x3E, v)

    def st(self, addr):              # (addr) <- A
        if addr >= 0xFF00:
            self.emit(0xE0, addr & 0xFF)
        else:
            self.w16(0xEA, addr)

    def ldm(self, addr):             # A <- (addr)
        if addr >= 0xFF00:
            self.emit(0xF0, addr & 0xFF)
        else:
            self.w16(0xFA, addr)

    def wr(self, addr, v):
        self.ld_a(v)
        self.st(addr)

    def _check(self, v, desc):
        self.emit(0xFE, v)           # CP v
        self.jp(0xC2, 'fail')        # JP NZ,fail
        self.checks.append(desc)
        assert len(self.checks) < 256

    def chk(self, addr, v, desc=None):
        self.emit(0x1C)              # INC E  (E = number of the check in progress)
        self.ldm(addr)
        self._check(v, desc or f'({addr:04X}) == {v:02X}')

    def chk_c(self, v, desc):
        self.emit(0x1C, 0x79)        # INC E; LD A,C
        self._check(v, desc)

    def call(self, lab):
        self.jp(0xCD, lab)

    def fill(self, addr, n, v):
        self.w16(0x21, addr)         # LD HL,addr
        self.w16(0x01, n)            # LD BC,n
        l = self.label()
        self.emit(0x3E, v, 0x22, 0x0B, 0x78, 0xB1)  # LD A,v; LD (HL+),A; DEC BC; LD A,B; OR C
        self.jr(0x20, l)

    def dma(self, hi):
        self.ld_a(hi)
        self.w16(0xCD, 0xFF80)       # CALL FF80 (routine in HRAM)

    def poll_mode(self, m):
        l = self.label()
        self.emit(0xF0, 0x41, 0xE6, 0x03, 0xFE, m)  # LDH A,(41); AND 3; CP m
        self.jr(0x20, l)

    def send_str(self, s):
        for ch in s:
            self.ld_a(ord(ch))
            self.call('send')


def start(a, cgb=False):
    a.st(0xFF90)                    # preserve boot A before the test changes it
    a.emit(0xF3)                     # DI
    a.w16(0x31, 0xFFFE)              # LD SP,FFFE
    a.emit(0x1E, 0x00)               # LD E,0
    a.chk(0xFF90, 0x11 if cgb else 0x01, 'Boot A identifies the selected CPU model')
    a.wr(0xFF40, 0x00)               # LCD off: VRAM/OAM freely accessible
    for i, v in enumerate(DMA_ROUTINE):
        a.wr(0xFF80 + i, v)


def mode3(a):
    """Caller has written (8001) and selected the bank. A mode-3 write must be dropped and a mode-3 read
    must return FF; afterwards (vblank) the original byte is checked by the caller."""
    a.wr(0xFF40, 0x91)
    a.w16(0x21, 0x8001)              # LD HL,8001
    a.emit(0x06, 0x77)               # LD B,77
    a.poll_mode(3)
    a.emit(0x70, 0x7E, 0x4F)         # LD (HL),B; LD A,(HL); LD C,A  (all inside mode 3)
    a.poll_mode(1)                   # vblank: VRAM accessible again
    a.chk_c(0xFF, 'VRAM read during mode 3 returns FF')


def finish(a):
    # junk in "bank 1" (CGB) / bank 0 (DMG, VBK ignored) that would spoil the image if the PPU used it
    a.wr(0xFF4F, 0x01)
    a.fill(0x9800, 0x400, 0x01)
    a.fill(0x8000, 0x20, 0x00)
    a.jp(0xC3, 'pass')

    a.label('send')                  # serial byte A, wait for completion
    a.emit(0xE0, 0x01, 0x3E, 0x81, 0xE0, 0x02)
    l = a.label()
    a.emit(0xF0, 0x02, 0xE6, 0x80)
    a.jr(0x20, l)
    a.emit(0xC9)

    a.label('fail')
    a.emit(0x7B)                     # LD A,E
    a.call('send')
    a.send_str('Failed')
    a.emit(0x16, 0xFF)               # LD D,FF -> tile colour 3
    a.jp(0xC3, 'draw')

    a.label('pass')
    a.send_str('Passed')
    a.emit(0x16, 0x00)               # LD D,00 -> tile colour 1

    a.label('draw')
    a.wr(0xFF40, 0x00)
    a.wr(0xFF4F, 0x00)
    a.fill(0x9800, 0x400, 0x00)      # BG map 9800 -> tile 0
    a.w16(0x21, 0x8000)              # tile 0: rows FF,D
    a.emit(0x06, 0x08)               # LD B,8
    l = a.label()
    a.emit(0x3E, 0xFF, 0x22, 0x7A, 0x22, 0x05)  # LD A,FF; LD (HL+),A; LD A,D; LD (HL+),A; DEC B
    a.jr(0x20, l)
    a.fill(0x8010, 0x10, 0x00)       # tile 1 blank
    a.wr(0xFF47, 0xE4)
    a.wr(0xFF42, 0x00)
    a.wr(0xFF43, 0x00)
    a.wr(0xFF4F, 0x01)               # CPU selects bank 1 while rendering: the PPU must still read bank 0
    a.wr(0xFF40, 0x91)
    l = a.label()
    a.jr(0x18, l)                    # loop forever


def dmg_program(a):
    start(a)
    a.chk(0xFF70, 0xFF, 'DMG: SVBK reads FF')
    a.chk(0xFF4F, 0xFF, 'DMG: VBK reads FF')
    for addr, v in ((0xC000, 0xC0), (0xCFFF, 0xCF), (0xD000, 0xD0), (0xDFFF, 0xDF), (0xDDFF, 0xDD)):
        a.wr(addr, v)
    a.wr(0xFF70, 0x03)
    a.chk(0xFF70, 0xFF, 'DMG: SVBK write ignored (reads FF)')
    a.chk(0xD000, 0xD0, 'DMG: SVBK write does not switch D000')
    a.wr(0xD000, 0xD3)
    a.wr(0xFF70, 0x00)
    a.chk(0xD000, 0xD3, 'DMG: D000 single bank')
    a.wr(0xFF70, 0x07)
    a.chk(0xDFFF, 0xDF, 'DMG: DFFF single bank')
    a.chk(0xC000, 0xC0, 'DMG: C000 kept')
    a.chk(0xE000, 0xC0, 'DMG: echo E000 -> C000')
    a.chk(0xEFFF, 0xCF, 'DMG: echo EFFF -> CFFF')
    a.chk(0xF000, 0xD3, 'DMG: echo F000 -> D000')
    a.chk(0xFDFF, 0xDD, 'DMG: echo FDFF -> DDFF')
    a.wr(0xF001, 0x5F)
    a.chk(0xD001, 0x5F, 'DMG: echo write F001 -> D001')
    a.wr(0xE002, 0x5E)
    a.chk(0xC002, 0x5E, 'DMG: echo write E002 -> C002')
    a.wr(0xD09F, 0x9F)
    a.wr(0xC09F, 0x9C)
    a.dma(0xC0)
    a.chk(0xFE00, 0xC0, 'DMG: DMA C0 first byte')
    a.chk(0xFE9F, 0x9C, 'DMG: DMA C0 last byte')
    a.dma(0xD0)
    a.chk(0xFE00, 0xD3, 'DMG: DMA D0 first byte')
    a.chk(0xFE9F, 0x9F, 'DMG: DMA D0 last byte')
    a.dma(0xE0)
    a.chk(0xFE00, 0xC0, 'DMG: DMA E0 echoes C000 (undocumented source; current echo behaviour)')
    a.wr(0xFF70, 0x02)
    a.dma(0xF0)
    a.chk(0xFE00, 0xD3, 'DMG: DMA F0 echoes D000, SVBK ignored (undocumented source; current echo behaviour)')
    a.chk(0xFE9F, 0x9F, 'DMG: DMA F0 last byte')
    a.wr(0xFF4F, 0x00)
    a.wr(0x8000, 0xA0)
    a.wr(0x9FFF, 0xA9)
    a.wr(0xFF4F, 0x01)
    a.chk(0xFF4F, 0xFF, 'DMG: VBK write ignored (reads FF)')
    a.wr(0x8000, 0xB1)
    a.wr(0xFF4F, 0x00)
    a.chk(0x8000, 0xB1, 'DMG: VRAM single bank')
    a.chk(0x9FFF, 0xA9, 'DMG: VRAM 9FFF kept')
    a.wr(0x8001, 0x42)
    mode3(a)
    a.chk(0x8001, 0x42, 'DMG: VRAM write during mode 3 dropped')
    a.wr(0xFF40, 0x00)
    finish(a)


def cgb_program(a):
    start(a, cgb=True)
    a.chk(0xFF70, 0xF8, 'CGB: SVBK resets to 0 (reads F8)')
    a.chk(0xFF4F, 0xFE, 'CGB: VBK resets to 0 (reads FE)')
    a.wr(0xC000, 0xC0)
    a.wr(0xCFFF, 0xCF)
    for b in range(1, 8):
        a.wr(0xFF70, b)
        a.wr(0xD000, 0x10 + b)
        a.wr(0xDFFF, 0x20 + b)
        a.wr(0xDDFF, 0x30 + b)
    a.wr(0xFF70, 0x00)
    a.chk(0xFF70, 0xF8, 'CGB: SVBK=0 reads back 0')
    a.chk(0xD000, 0x11, 'CGB: SVBK=0 aliases bank 1 (D000)')
    a.chk(0xDFFF, 0x21, 'CGB: SVBK=0 aliases bank 1 (DFFF)')
    for b in range(1, 8):
        a.wr(0xFF70, b)
        a.chk(0xFF70, 0xF8 | b, f'CGB: SVBK={b} readback')
        a.chk(0xD000, 0x10 + b, f'CGB: bank {b} D000 isolated')
        a.chk(0xDFFF, 0x20 + b, f'CGB: bank {b} DFFF isolated')
        a.chk(0xC000, 0xC0, f'CGB: C000 fixed with SVBK={b}')
        a.chk(0xCFFF, 0xCF, f'CGB: CFFF fixed with SVBK={b}')
    a.wr(0xFF70, 0x02)
    a.wr(0xD001, 0x77)
    a.wr(0xFF70, 0x00)
    a.wr(0xD001, 0x5A)
    a.wr(0xFF70, 0x01)
    a.chk(0xD001, 0x5A, 'CGB: write via SVBK=0 lands in bank 1')
    a.wr(0xFF70, 0x02)
    a.chk(0xD001, 0x77, 'CGB: write via SVBK=0 leaves bank 2')
    a.wr(0xFF70, 0xFB)
    a.chk(0xFF70, 0xFB, 'CGB: SVBK uses bits 2:0 only')
    a.chk(0xD000, 0x13, 'CGB: SVBK=FB selects bank 3')
    a.chk(0xE000, 0xC0, 'CGB: echo E000 -> C000')
    a.chk(0xEFFF, 0xCF, 'CGB: echo EFFF -> CFFF')
    a.chk(0xF000, 0x13, 'CGB: echo F000 -> bank 3 D000')
    a.chk(0xFDFF, 0x33, 'CGB: echo FDFF -> bank 3 DDFF')
    a.wr(0xFF70, 0x00)
    a.chk(0xF000, 0x11, 'CGB: echo F000 with SVBK=0 -> bank 1')
    a.chk(0xFDFF, 0x31, 'CGB: echo FDFF with SVBK=0 -> bank 1')
    a.wr(0xFF70, 0x05)
    a.wr(0xF000, 0x55)
    a.chk(0xD000, 0x55, 'CGB: echo write F000 -> bank 5 D000')
    a.wr(0xFF70, 0x04)
    a.chk(0xD000, 0x14, 'CGB: echo write left bank 4')
    a.chk(0xF000, 0x14, 'CGB: echo F000 -> bank 4')
    a.wr(0xE001, 0x99)
    a.chk(0xC001, 0x99, 'CGB: echo write E001 -> C001')
    a.wr(0xFF70, 0x06)
    a.chk(0xE001, 0x99, 'CGB: echo E001 bank independent')
    for b, v in ((6, 0x6F), (2, 0x2F), (1, 0x1F), (7, 0x7F)):
        a.wr(0xFF70, b)
        a.wr(0xD09F, v)
    a.wr(0xC09F, 0x0C)
    a.wr(0xFF70, 0x06)
    a.dma(0xD0)
    a.chk(0xFE00, 0x16, 'CGB: DMA D0 with SVBK=6 first byte')
    a.chk(0xFE9F, 0x6F, 'CGB: DMA D0 with SVBK=6 last byte')
    a.wr(0xFF70, 0x02)
    a.dma(0xF0)
    a.chk(0xFE00, 0x12, 'CGB: DMA F0 with SVBK=2 first byte (undocumented source; current echo behaviour)')
    a.chk(0xFE9F, 0x2F, 'CGB: DMA F0 with SVBK=2 last byte (undocumented source; current echo behaviour)')
    a.wr(0xFF70, 0x00)
    a.dma(0xD0)
    a.chk(0xFE00, 0x11, 'CGB: DMA D0 with SVBK=0 -> bank 1')
    a.chk(0xFE9F, 0x1F, 'CGB: DMA D0 with SVBK=0 last byte')
    a.wr(0xFF70, 0x07)
    a.dma(0xD0)
    a.chk(0xFE00, 0x17, 'CGB: DMA D0 with SVBK=7 first byte')
    a.chk(0xFE9F, 0x7F, 'CGB: DMA D0 with SVBK=7 last byte')
    a.dma(0xC0)
    a.chk(0xFE00, 0xC0, 'CGB: DMA C0 bank 0 first byte')
    a.chk(0xFE9F, 0x0C, 'CGB: DMA C0 bank 0 last byte')
    a.dma(0xD0)
    a.dma(0xE0)
    a.chk(0xFE00, 0xC0, 'CGB: DMA E0 echoes bank 0 (undocumented source; current echo behaviour)')
    a.wr(0xFF4F, 0x00)
    a.wr(0x8000, 0xA0)
    a.wr(0x9FFF, 0xA9)
    a.wr(0x8001, 0x24)
    a.wr(0xFF4F, 0x01)
    a.chk(0xFF4F, 0xFF, 'CGB: VBK=1 reads FF')
    a.wr(0x8000, 0xB1)
    a.wr(0x9FFF, 0xB9)
    a.chk(0x8000, 0xB1, 'CGB: VRAM bank 1 8000')
    a.chk(0x9FFF, 0xB9, 'CGB: VRAM bank 1 9FFF')
    a.wr(0xFF4F, 0x00)
    a.chk(0xFF4F, 0xFE, 'CGB: VBK=0 reads FE')
    a.chk(0x8000, 0xA0, 'CGB: VRAM bank 0 8000 isolated')
    a.chk(0x9FFF, 0xA9, 'CGB: VRAM bank 0 9FFF isolated')
    a.wr(0xFF4F, 0xFF)
    a.chk(0xFF4F, 0xFF, 'CGB: VBK=FF reads FF')
    a.chk(0x8000, 0xB1, 'CGB: VBK=FF selects bank 1')
    a.wr(0xFF4F, 0xFE)
    a.chk(0xFF4F, 0xFE, 'CGB: VBK=FE reads FE')
    a.chk(0x8000, 0xA0, 'CGB: VBK=FE selects bank 0')
    a.wr(0xFF4F, 0x01)
    a.wr(0x8001, 0x42)
    mode3(a)
    a.chk(0x8001, 0x42, 'CGB: bank 1 write during mode 3 dropped')
    a.wr(0xFF4F, 0x00)
    a.chk(0x8001, 0x24, 'CGB: bank 0 untouched by mode 3 write')
    a.wr(0xFF40, 0x00)
    finish(a)


def rom(program, cgb):
    a = Asm(0x150)
    program(a)
    code = a.link()
    img = bytearray([0xFF] * 0x8000)
    img[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])   # NOP; JP 0150
    img[0x104:0x134] = bytes(0x30)                       # no logo (core has no boot ROM)
    img[0x134:0x143] = b'BANKTEST'.ljust(15, b'\0')
    img[0x143] = 0x80 if cgb else 0x00
    img[0x144:0x14D] = bytes(9)                          # licensee, SGB, type 0, 32 KiB, no RAM
    img[0x14A] = 0x01
    x = 0
    for i in range(0x134, 0x14D):
        x = (x - img[i] - 1) & 0xFF
    img[0x14D] = x
    img[0x150:0x150 + len(code)] = code
    s = (sum(img) - img[0x14E] - img[0x14F]) & 0xFFFF
    img[0x14E], img[0x14F] = s >> 8, s & 0xFF
    return bytes(img), a.checks


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    os.makedirs(out, exist_ok=True)
    for name, prog, cgb in (('bank_dmg', dmg_program, False), ('bank_cgb', cgb_program, True)):
        img, checks = rom(prog, cgb)
        with open(os.path.join(out, name + '.gb'), 'wb') as f:
            f.write(img)
        with open(os.path.join(out, name + '.lst'), 'w') as f:
            for i, d in enumerate(checks, 1):
                f.write(f'{i:3d} 0x{i:02X} {d}\n')


if __name__ == '__main__':
    main()
