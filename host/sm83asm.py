"""Small byte-code assembler shared by launcher firmware and CPU regression ROMs."""


class Asm:
    def __init__(self, org):
        self.org = org
        self.b = bytearray()
        self.labels = {}
        self.fix = []
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

    def jp(self, op, lab):
        self.emit(op, 0, 0)
        self.fix.append((len(self.b)-2, lab, 'abs'))

    def jr(self, op, lab):
        self.emit(op, 0)
        self.fix.append((len(self.b)-1, lab, 'rel'))

    def link(self):
        for off, lab, kind in self.fix:
            target = self.labels[lab]
            if kind == 'abs':
                self.b[off], self.b[off+1] = target & 0xFF, target >> 8
            else:
                displacement = target - (self.org+off+1)
                assert -128 <= displacement < 128, lab
                self.b[off] = displacement & 0xFF
        return bytes(self.b)

    def ld_a(self, value):
        self.emit(0x3E, value)

    def st(self, addr):
        if addr >= 0xFF00:
            self.emit(0xE0, addr & 0xFF)
        else:
            self.w16(0xEA, addr)

    def ldm(self, addr):
        if addr >= 0xFF00:
            self.emit(0xF0, addr & 0xFF)
        else:
            self.w16(0xFA, addr)

    def wr(self, addr, value):
        self.ld_a(value)
        self.st(addr)

    def call(self, label):
        self.jp(0xCD, label)
