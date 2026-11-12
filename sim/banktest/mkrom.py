#!/usr/bin/env python3
"""Synthetic SM83 ROMs for banking, GBC speed switching, STOP, VRAM DMA and MBC3 RTC.

usage: mkrom.py <outdir> -> bank_dmg.gb, bank_cgb.gb, bank_cgb_fast.gb, speed_cgb.gb,
                           vram_dma_cgb.gb, vram_dma_cgb_fast.gb, mbc3_rtc.gb,
                           mbc3_no_rtc.gb, mbc3_timer_only.gb and numbered .lst files.

Each ROM checks the memory map from a real CPU program, reports over serial ("Passed", or the failing
check number as one raw byte followed by "Failed"), then draws a solid screen with LCDC=91, BGP=E4 and
loops: shade 1 = pass, shade 3 = fail (BG map cleared to tile 0; tile 0 low bytes FF, high 00/FF).

VRAM DMA cases cover alignment, bank selection, 2048-byte ROM transfers, CPU stalls with
DIV running, destination overflow, visible-HBlank scheduling, cancellation/resume and HALT.
MBC3 cases cover RTC/RAM isolation, missing timer/RAM hardware, enable gating, latch sequences,
and real-time second progression across both CPU speeds. tb_rtc.v covers counter rollover,
sticky day carry and halt/resume with an accelerated oscillator, not altered register logic.
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'host'))
from sm83asm import Asm as RomAsm

DMA_ROUTINE = [0xE0, 0x46,   # LDH (46),A    start OAM DMA from A<<8
               0x3E, 0x30,   # LD A,48       48 x 4 M-cycles > 160
               0x3D,         # DEC A
               0x20, 0xFD,   # JR NZ,-3
               0xC9]         # RET


class Asm(RomAsm):
    def __init__(self, org):
        super().__init__(org)
        self.checks = []

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
    a.chk(0xFF90, 0x11, 'CGB hardware post-boot A is 11 in DMG compatibility mode too')
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
    a.wr(0xFF4D, 1)
    a.chk(0xFF4D, 0xFF, 'DMG: KEY1 writes are ignored and reads stay FF')
    a.chk(0xFF70, 0xFF, 'DMG: SVBK reads FF')
    a.chk(0xFF4F, 0xFE, 'CGB hardware exposes VBK while rendering a DMG cartridge')
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
    a.wr(0xFF4F, 0x00)
    a.wr(0x8000, 0xA0)
    a.wr(0x9FFF, 0xA9)
    a.wr(0xFF4F, 0x01)
    a.chk(0xFF4F, 0xFF, 'CGB hardware stores VBK while DMG VRAM remains single-bank')
    a.wr(0x8000, 0xB1)
    a.wr(0xFF4F, 0x00)
    a.chk(0x8000, 0xB1, 'DMG: VRAM single bank')
    a.chk(0x9FFF, 0xA9, 'DMG: VRAM 9FFF kept')
    a.wr(0x8001, 0x42)
    mode3(a)
    a.chk(0x8001, 0x42, 'DMG: VRAM write during mode 3 dropped')
    a.wr(0xFF40, 0x00)
    finish(a)


def cgb_program(a, fast=False):
    start(a, cgb=True)
    if fast:
        a.wr(0xFF00, 0x30)
        a.wr(0xFF4D, 1)
        a.emit(0x10, 0x00)
        a.chk(0xFF4D, 0xFE, 'CGB: run memory/DMA/rendering checks in double speed')
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


def speed_program(a):
    start(a, cgb=True)
    a.chk(0xFF4D, 0x7E, 'KEY1 starts normal and unarmed')
    a.wr(0xFF4D, 0xFE)
    a.chk(0xFF4D, 0x7E, 'KEY1 speed is read-only')
    a.wr(0xFF4D, 0xFF)
    a.chk(0xFF4D, 0x7F, 'KEY1 only stores the arm bit')
    a.wr(0xFF4D, 0x00)
    a.chk(0xFF4D, 0x7E, 'KEY1 arm can be cancelled')
    a.wr(0xFFFF, 0)
    a.wr(0xFF00, 0x30)
    for fast in (True, False):
        a.wr(0xFF01, ord('I' if fast else 'K'))
        a.wr(0xFF02, 0x81)
        a.wr(0xFF4D, 1)
        a.emit(0x10, 0x00)           # STOP and its padding byte
        a.wr(0xFF01, ord('J' if fast else 'L'))
        a.wr(0xFF02, 0x81)
        a.chk(0xFF4D, 0xFE if fast else 0x7E, 'STOP switches speed and clears the arm bit')
        a.chk(0xFF04, 0, 'STOP resets DIV and freezes it during switching')
        a.wr(0xFF40, 0x91)
        for line in (1, 3):
            l = a.label()
            a.emit(0xF0, 0x44, 0xFE, line)
            a.jr(0x20, l)
            if line == 1:
                a.wr(0xFF04, 0)
        a.emit(0x1C)                # next check: DIV over two PPU scanlines
        a.ldm(0xFF04)
        a.emit(0xFE, 6 if fast else 3)
        a.jp(0xDA, 'fail')           # JP C
        a.emit(0xFE, 9 if fast else 5)
        a.jp(0xD2, 'fail')           # JP NC
        a.checks.append('DIV runs twice as fast while PPU scanlines retain their dot rate'
                        if fast else 'Normal CPU/DIV rate is restored without doubling the PPU')
        a.wr(0xFF40, 0)
    a.wr(0xFF00, 0x10)              # select A/B/Start/Select for STOP wake
    a.wr(0xFF01, ord('S'))
    a.wr(0xFF02, 0x81)              # bench schedules a later button press
    a.emit(0x10, 0x00)              # unarmed STOP must wait for that press
    a.wr(0xFF01, ord('A'))
    a.wr(0xFF02, 0x81)              # bench rejects this marker before the press
    a.chk(0xFF4D, 0x7E, 'Unarmed STOP does not change CPU speed')
    a.chk(0xFF04, 0, 'Unarmed STOP keeps DIV stopped until joypad wake')
    finish(a)


def vdma_start(a, source, destination, control):
    for register, value in zip(range(0xFF51, 0xFF56),
                               (source >> 8, source & 255, destination >> 8,
                                destination & 255, control)):
        a.wr(register, value)


def wait_ly(a, line):
    l = a.label()
    a.emit(0xF0, 0x44, 0xFE, line)
    a.jr(0x20, l)


def vdma_wait(a):
    l = a.label()
    a.emit(0xF0, 0x55, 0xFE, 0xFF)
    a.jr(0x20, l)


def vram_dma_program(a, fast=False):
    start(a, cgb=True)
    if fast:
        a.wr(0xFF00, 0x30)
        a.wr(0xFF4D, 1)
        a.emit(0x10, 0)
        a.chk(0xFF4D, 0xFE)
    for register in range(0xFF51, 0xFF55):
        a.wr(register, 0xA5)
        a.chk(register, 0xFF, 'DMA address registers are write-only')
    a.wr(0xFF4F, 0)
    a.wr(0x8000, 0xC3)
    a.wr(0x9FEF, 0xA5)
    for i in range(48):
        a.wr(0xC200+i, (i*7+3) & 255)
    vdma_start(a, 0xC20B, 0xFFFF, 0)
    a.chk(0xFF55, 0xFF, 'GDMA completes before CPU resumes')
    for i in range(16):
        a.chk(0x9FF0+i, (i*7+3) & 255, 'GDMA address masking and data')
    a.chk(0x9FEF, 0xA5, 'GDMA lower guard')
    a.chk(0x8000, 0xC3, 'GDMA upper guard')
    for bank in (3, 7):
        a.wr(0xFF70, bank)
        for i in range(32):
            a.wr(0xD200+i, (bank*17+i*3) & 255)
    a.wr(0xFF4F, 1)
    vdma_start(a, 0xD200, 0x8100, 1)
    for i in range(32):
        a.chk(0x8100+i, (7*17+i*3) & 255, 'GDMA selected SVBK and VBK')
    a.wr(0xFF4F, 0)
    a.wr(0xFF04, 0)
    vdma_start(a, 0x7000, 0x9000, 0x7F)
    a.emit(0x1C)
    a.ldm(0xFF04)
    a.emit(0xFE, 32 if fast else 16)
    a.jp(0xDA, 'fail')
    a.emit(0xFE, 35 if fast else 18)
    a.jp(0xD2, 'fail')
    a.checks.append('Maximum GDMA fixed dot duration; DIV continues')
    a.emit(0x1C, 0xD5)              # preserve check number while DE is source pointer
    a.w16(0x21, 0x9000)
    a.w16(0x11, 0x7000)
    a.w16(0x01, 0x0800)
    l = a.label()
    a.emit(0x1A, 0xBE)
    a.jp(0xC2, 'vdma_mismatch')
    a.emit(0x13, 0x23, 0x0B, 0x78, 0xB1)
    a.jr(0x20, l)
    a.emit(0xD1)
    a.jp(0xC3, 'vdma_compared')
    a.label('vdma_mismatch')
    a.emit(0xD1)
    a.jp(0xC3, 'fail')
    a.label('vdma_compared')
    a.checks.append('All 2048 ROM-source DMA bytes match')
    vdma_start(a, 0x7000, 0x9FF0, 1)
    a.emit(0x1C)
    a.ldm(0xFF55)
    a.emit(0xE6, 0x80)
    a._check(0x80, 'Destination overflow stops DMA')
    a.chk(0x8000, 0xC3, 'Overflow never wraps into 8000')
    a.fill(0x8800, 64, 0xA5)
    a.wr(0xFF40, 0x91)
    wait_ly(a, 144)
    vdma_start(a, 0xC200, 0x8800, 0x82)
    wait_ly(a, 153)
    a.chk(0xFF55, 2, 'No HBlank DMA during VBlank')
    a.chk(0x8800, 0xA5, 'VBlank leaves destination untouched')
    wait_ly(a, 0)
    l = a.label()
    a.emit(0xF0, 0x55, 0xFE, 2)
    a.jr(0x28, l)
    a.wr(0xFF55, 0)
    a.chk(0xFF55, 0x81, 'Cancelled with two blocks remaining')
    wait_ly(a, 2)
    a.wr(0xFF40, 0)
    for i in range(48):
        a.chk(0x8800+i, (i*7+3) & 255 if i < 16 else 0xA5,
              'Exactly one block before cancellation')
    a.wr(0xFF40, 0x91)
    wait_ly(a, 0)
    a.wr(0xFF55, 0x81)
    vdma_wait(a)
    a.wr(0xFF40, 0)
    for i in range(48):
        a.chk(0x8800+i, (i*7+3) & 255, 'Resume retains source and destination')
    a.chk(0x8830, 0xA5, 'HBlank DMA length guard')
    a.fill(0x8A00, 32, 0xA5)
    a.wr(0xFFFF, 1)
    a.wr(0xFF0F, 0)
    a.wr(0xFF40, 0x91)
    wait_ly(a, 0)
    vdma_start(a, 0xC200, 0x8A00, 0x81)
    a.emit(0x76)
    a.chk(0xFF55, 1, 'HALT suspends HDMA until VBlank interrupt wakes CPU')
    a.wr(0xFFFF, 0)
    a.wr(0xFF0F, 0)
    vdma_wait(a)
    a.wr(0xFF40, 0)
    for i in range(32):
        a.chk(0x8A00+i, (i*7+3) & 255, 'HDMA resumes after HALT')
    finish(a)


def mbc3_program(a, clock=True, ram=True):
    start(a, cgb=True)
    a.wr(0x0000, 0x0A)
    a.wr(0x4000, 0)
    a.wr(0xA000, 0x5A)
    a.chk(0xA000, 0x5A if ram else 0xFF, 'RAM presence follows the cartridge header')
    if ram:
        a.wr(0x4000, 3)
        a.wr(0xA000, 0xA7)
    a.wr(0x4000, 0x0C)
    a.wr(0xA000, 0xC1)              # halt before setting the live clock
    for register, value in ((8, 42), (9, 17), (10, 23), (11, 0xFF)):
        a.wr(0x4000, register)
        a.wr(0xA000, value)
    a.wr(0x6000, 0)
    a.wr(0x6000, 1)
    for register, value in ((8, 42), (9, 17), (10, 23), (11, 0xFF), (12, 0xC1)):
        a.wr(0x4000, register)
        a.chk(0xB123, value if clock else 0xFF, 'RTC selected register maps the whole A000-BFFF window')
    a.wr(0x4000, 8)
    a.wr(0xA000, 21)
    a.chk(0xA000, 42 if clock else 0xFF, 'Live RTC writes do not change the latched snapshot')
    a.wr(0x6000, 1)
    a.chk(0xA000, 42 if clock else 0xFF, 'Latch requires a preceding zero')
    for value in (0, 2, 1):
        a.wr(0x6000, value)
    a.chk(0xA000, 42 if clock else 0xFF, 'An intervening value cancels latch arming')
    a.wr(0x6000, 0)
    a.wr(0x6000, 1)
    a.chk(0xA000, 21 if clock else 0xFF, 'Zero-to-one latch captures the new live value')
    a.wr(0x0000, 0)
    a.chk(0xA000, 0xFF, 'Disabled RTC reads are open bus')
    a.wr(0xA000, 55)
    a.wr(0x0000, 0x0A)
    for invalid in (0x0D, 0x18, 0x80):
        a.wr(0x4000, invalid)
        a.wr(0xA000, 33)
        a.chk(0xA000, 0xFF, 'Invalid MBC3 selectors do not alias RAM or RTC')
    a.wr(0x4000, 8)
    a.wr(0x6000, 0)
    a.wr(0x6000, 1)
    a.chk(0xA000, 21 if clock else 0xFF, 'Disabled/invalid writes leave the live clock intact')
    a.wr(0x4000, 0)
    a.chk(0xA000, 0x5A if ram else 0xFF, 'RTC writes never overwrite RAM bank 0')
    if ram:
        a.wr(0x4000, 3)
        a.chk(0xA000, 0xA7, 'RTC/invalid writes never overwrite RAM bank 3')
    if clock and ram:
        a.wr(0x4000, 12)
        a.wr(0xA000, 0x40)
        a.wr(0x4000, 8)
        a.wr(0xA000, 0)
        a.wr(0x4000, 12)
        a.wr(0xA000, 0)
        a.wr(0xFF40, 0x91)
        for elapsed in (1, 2):
            if elapsed == 2:
                a.wr(0xFF00, 0x30)
                a.wr(0xFF4D, 1)
                a.emit(0x10, 0)
            a.emit(0x16, 62)         # LD D,62; wait 62 complete video frames
            l = a.label()
            wait_ly(a, 144)
            wait_ly(a, 0)
            a.emit(0x15)
            a.jr(0x20, l)
            a.wr(0x6000, 0)
            a.wr(0x6000, 1)
            a.wr(0x4000, 8)
            a.chk(0xA000, elapsed, 'RTC runs at wall-clock rate in normal and double speed')
    finish(a)


def rom(program, cgb, mapper=0, ram_size=0):
    a = Asm(0x150)
    program(a)
    code = a.link()
    img = bytearray([0xFF] * 0x8000)
    img[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])   # NOP; JP 0150
    img[0x104:0x134] = bytes(0x30)                       # no logo (core has no boot ROM)
    img[0x134:0x143] = b'BANKTEST'.ljust(15, b'\0')
    img[0x143] = 0x80 if cgb else 0x00
    img[0x144:0x14D] = bytes(9)                          # default header: 32 KiB, mapper/RAM below
    img[0x147] = mapper
    img[0x149] = ram_size
    img[0x14A] = 0x01
    x = 0
    for i in range(0x134, 0x14D):
        x = (x - img[i] - 1) & 0xFF
    img[0x14D] = x
    assert 0x150 + len(code) <= 0x7000, 'program overlaps DMA ROM payload'
    img[0x7000:0x7800] = bytes((i*29+0x37) & 255 for i in range(2048))
    img[0x150:0x150 + len(code)] = code
    s = (sum(img) - img[0x14E] - img[0x14F]) & 0xFFFF
    img[0x14E], img[0x14F] = s >> 8, s & 0xFF
    return bytes(img), a.checks


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    os.makedirs(out, exist_ok=True)
    for name, prog, cgb, mapper, ram_size in (
            ('bank_dmg', dmg_program, False, 0, 0),
            ('bank_cgb', cgb_program, True, 0, 0),
            ('bank_cgb_fast', lambda a: cgb_program(a, fast=True), True, 0, 0),
            ('speed_cgb', speed_program, True, 0, 0),
            ('vram_dma_cgb', vram_dma_program, True, 0, 0),
            ('vram_dma_cgb_fast', lambda a: vram_dma_program(a, True), True, 0, 0),
            ('mbc3_rtc', mbc3_program, True, 0x10, 3),
            ('mbc3_no_rtc', lambda a: mbc3_program(a, clock=False), True, 0x13, 3),
            ('mbc3_timer_only', lambda a: mbc3_program(a, ram=False), True, 0x0F, 0)):
        img, checks = rom(prog, cgb, mapper, ram_size)
        with open(os.path.join(out, name + '.gb'), 'wb') as f:
            f.write(img)
        with open(os.path.join(out, name + '.lst'), 'w') as f:
            for i, d in enumerate(checks, 1):
                f.write(f'{i:3d} 0x{i:02X} {d}\n')


if __name__ == '__main__':
    main()
