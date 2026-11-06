// Banked-memory behavioural test: runs a synthetic ROM from sim/banktest/mkrom.py on the gb core with
// an ideal external memory. cgb_mode comes from header 0x143 bit 7 (as the loader does).
// Pass = serial "Passed", then one complete frame where every pixel is shade 1.
// usage: Vgb <rom.gb>
#include "Vgb.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: Vgb rom.gb\n"); return 2; }
    std::vector<unsigned char> ext(1 << 22, 0xFF);
    FILE *rf = fopen(argv[1], "rb");
    if (!rf) { perror(argv[1]); return 2; }
    fread(ext.data(), 1, 0x8000, rf);
    fclose(rf);
    const bool cgb = ext[0x143] & 0x80;

    Vgb *g = new Vgb;
    g->cart_type = 0; g->rom_mask = 1; g->ram_mask = 0; g->cgb_mode = cgb;
    g->clk_en = 1; g->buttons = 0; g->ext_rd = 0xFF; g->rst = 1;
    for (int i = 0; i < 8; i++) { g->clk = 0; g->eval(); g->clk = 1; g->eval(); }
    g->rst = 0;

    static unsigned char seen[144][160];
    std::string ser;
    bool passed = false;
    int vs = 0, bad = 0, rc = 1;
    const long long max_ticks = 60LL * 70224;
    long long t = 0;
    long acc = 0;
    while (t < max_ticks) {
        // Match the real 25.2 MHz domain and its 5–6-clock spacing between GB dots.
        acc += 70224;
        g->clk_en = acc >= 420000;
        if (g->clk_en) { acc -= 420000; t++; }
        g->clk = 0; g->eval();
        bool req = g->ext_req, we = g->ext_we; unsigned addr = g->ext_addr, wd = g->ext_wd;
        g->clk = 1; g->eval();
        if (req) { if (we) ext[addr] = wd; else g->ext_rd = ext[addr]; }
        if (g->ser_valid && !passed) {
            unsigned char c = g->ser_data; ser += (char)c;
            if (c >= 0x20 && c < 0x7F) putchar(c); else printf("\\x%02X", c);
            if (ser.size() >= 6 && ser.compare(ser.size() - 6, 6, "Failed") == 0) {
                int n = ser.size() >= 7 ? (unsigned char)ser[ser.size() - 7] : -1;
                printf("\n[banktest] %s: FAIL at check %d (see .lst)\n", argv[1], n);
                break;
            }
            if (ser.size() >= 6 && ser.compare(ser.size() - 6, 6, "Passed") == 0) passed = true;
        }
        if (passed && g->vsync && ++vs == 3) memset(seen, 0, sizeof seen);
        if (passed && vs == 3 && g->pix_we && g->pix_y < 144 && g->pix_x < 160) {
            seen[g->pix_y][g->pix_x] = 1;
            if (g->pix != 1) bad++;
        }
        if (passed && vs == 4) {
            int missing = 0;
            for (int y = 0; y < 144; y++) for (int x = 0; x < 160; x++) missing += !seen[y][x];
            if (missing || bad) printf("\n[banktest] %s: FAIL image (%d pixels not shade 1, %d missing)\n", argv[1], bad, missing);
            else { printf("\n[banktest] %s: PASS (cgb_mode=%d)\n", argv[1], cgb); rc = 0; }
            break;
        }
    }
    if (t == max_ticks) printf("\n[banktest] %s: FAIL timeout (pc=%04x, passed=%d)\n", argv[1], g->pc_dbg, passed);
    delete g;
    return rc;
}
