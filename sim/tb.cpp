// Verilator testbench: runs the gb core with an ideal external cartridge memory (stands in for
// PSRAM), echoes serial output, dumps the last frame as PPM.
// usage: Vgb <rom.gb> <max_frames> <out.ppm>
// GB_PRESS="from:to:mask,..." holds joypad mask (bit0=right..bit7=start) during frames [from,to)
#include "Vgb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: Vgb rom.gb [frames] [out.ppm]\n"); return 2; }
    int max_frames = argc > 2 ? atoi(argv[2]) : 600;
    const char *out = argc > 3 ? argv[3] : "frame.ppm";

    // external memory: 4 MB, ROM at 0, cartridge RAM at 0x3E0000
    std::vector<unsigned char> ext(1 << 22, 0xFF);
    FILE *rf = fopen(argv[1], "rb");
    if (!rf) { perror(argv[1]); return 2; }
    size_t rom_len = fread(ext.data(), 1, 0x3E0000, rf);
    fclose(rf);
    int type = ext[0x147];
    int cart = (type >= 1 && type <= 3) ? 1 : (type >= 0x0F && type <= 0x13) ? 2 : (type >= 0x19 && type <= 0x1E) ? 3 : 0;
    int banks = 2 << ext[0x148];
    static const int ram_banks[6] = {0, 1, 1, 4, 16, 8};
    int rb = ext[0x149] < 6 ? ram_banks[ext[0x149]] : 1;
    fprintf(stderr, "[tb] %zu bytes, type %02x -> mapper %d, %d banks, %d RAM banks\n", rom_len, type, cart, banks, rb);

    Vgb *g = new Vgb;
    g->cart_type = cart; g->rom_mask = banks - 1; g->ram_mask = rb ? rb - 1 : 0;
    static unsigned char fb[144][160];
    memset(fb, 0, sizeof fb);
    std::string ser;
    g->clk_en = 1; g->buttons = 0; g->rst = 1; g->ext_rd = 0xFF;
    for (int i = 0; i < 8; i++) { g->clk = 0; g->eval(); g->clk = 1; g->eval(); }
    g->rst = 0;
    int frames = 0;
    long long ticks = 0, max_ticks = (long long)max_frames * 70224;
    long acc = 0;
    while (ticks < max_ticks) {
        // same fractional enable as hardware: 70224 GB dots per 420000 pixel clocks
        acc += 70224; g->clk_en = acc >= 420000; if (g->clk_en) { acc -= 420000; ticks++; }
        g->clk = 0; g->eval();
        bool req = g->ext_req, we = g->ext_we; unsigned addr = g->ext_addr, wd = g->ext_wd;
        g->clk = 1; g->eval();
        if (req) { if (we) ext[addr] = wd; else g->ext_rd = ext[addr]; }
        if (g->pix_we && g->pix_y < 144 && g->pix_x < 160) fb[g->pix_y][g->pix_x] = g->pix;
        if (g->vsync) {
            frames++;
            int m = 0;
            if (const char *p = getenv("GB_PRESS")) {
                int a, b, k, n;
                while (sscanf(p, "%d:%d:%i%n", &a, &b, &k, &n) == 3) {
                    if (frames >= a && frames < b) m |= k;
                    p += n; if (*p == ',') p++; else break;
                }
            }
            g->buttons = m;
        }
        if (g->ser_valid) {
            char c = (char)g->ser_data; putchar(c); fflush(stdout); ser += c;
            if (ser.find("Passed") != std::string::npos || ser.find("Failed") != std::string::npos) break;
        }
    }
    FILE *f = fopen(out, "wb");
    if (!f) { perror(out); return 2; }
    fprintf(f, "P6 160 144 255\n");
    static const unsigned char shade[4] = {0xE0, 0xA8, 0x58, 0x10};
    for (int y = 0; y < 144; y++) for (int x = 0; x < 160; x++) {
        unsigned char s = shade[fb[y][x] & 3]; fputc(s, f); fputc(s, f); fputc(s, f);
    }
    fclose(f);
    printf("\n[tb] ticks=%lld frames=%d pc=%04x\n", ticks, frames, g->pc_dbg);
    delete g;
    return ser.find("Failed") != std::string::npos ? 1 : 0;
}
