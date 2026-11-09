// Banked-memory behavioural test: runs a synthetic ROM from sim/banktest/mkrom.py on the gb core with
// an ideal external memory. cgb_mode comes from header 0x143 bit 7 (as the loader does).
// Pass = serial "Passed", then one complete frame where every pixel is shade 1.
// usage: Vgb <rom.gb> [--wake-stop]
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
    const unsigned type = ext[0x147];
    g->cart_mbc2 = type == 0x05 || type == 0x06;
    g->cart_type = (type >= 1 && type <= 3) || g->cart_mbc2 ? 1 :
                   type >= 0x0F && type <= 0x13 ? 2 :
                   type >= 0x19 && type <= 0x1E ? 3 : 0;
    g->cart_rtc = type == 0x0F || type == 0x10;
    g->rom_mask = (2 << ext[0x148]) - 1;
    static const unsigned ram_banks[] = {0, 1, 1, 4, 16, 8};
    const unsigned rb = ext[0x149] < 6 ? ram_banks[ext[0x149]] : 0;
    g->cart_ram = rb != 0 || g->cart_mbc2;
    g->ram_mask = rb ? rb - 1 : 0; g->cgb_mode = cgb;
    g->clk_en = 1; g->clk_en_fast = 1; g->buttons = 0; g->ext_rd = 0xFF; g->rst = 1;
    for (int i = 0; i < 8; i++) { g->clk = 0; g->eval(); g->clk = 1; g->eval(); }
    g->rst = 0;

    static unsigned char seen[144][160];
    std::string ser;
    bool passed = false;
    int vs = 0, bad = 0, rc = 1;
    const long long max_ticks = 240LL * 70224;
    long long t = 0;
    long acc = 0;
    const bool test_stop = argc > 2 && strcmp(argv[2], "--wake-stop") == 0;
    long long cycles = 0, wake_at = -1;
    bool stop_seen = false, stop_ack = false, woke = false;
    long long switch_start[2] = {-1, -1};
    bool switch_done[2] = {false, false};
    // GB_FREEZE_PERIOD: every N system clocks, freeze the core like the host save path:
    // clock enables off for 400 clocks while the bus data is scrambled, then a resume
    // reissue followed by 20 held clocks.
    const long long freeze_period = getenv("GB_FREEZE_PERIOD") ? atoll(getenv("GB_FREEZE_PERIOD")) : 0;
    long long freeze_phase = 0;
    while (t < max_ticks) {
        // Match the 27 MHz system domain and its fractional dot enable.
        cycles++;
        if (wake_at == cycles) { g->buttons = 0x10; woke = true; }
        g->clk_en_fast = acc >= 154776 && acc < 225000;
        acc += 70224;
        g->clk_en = acc >= 450000;
        g->clk_en_fast |= g->clk_en;
        // The video timebase keeps running during a freeze; only the core's enables stop.
        if (g->clk_en) { acc -= 450000; t++; }
        g->bus_resume = 0;
        if (freeze_period) {
            const long long p = freeze_phase++ % freeze_period;
            if (p < 420) { g->clk_en = 0; g->clk_en_fast = 0; }
            if (p < 400) g->ext_rd = 0x5A;
            if (p == 400) g->bus_resume = 1;
        }
        g->clk = 0; g->eval();
        bool req = g->ext_req, we = g->ext_we; unsigned addr = g->ext_addr, wd = g->ext_wd;
        g->clk = 1; g->eval();
        if (req) { if (we) ext[addr] = wd; else g->ext_rd = ext[addr]; }
        if (g->ser_valid && !passed) {
            unsigned char c = g->ser_data; ser += (char)c;
            if (test_stop && (c == 'I' || c == 'K')) switch_start[c == 'I' ? 0 : 1] = cycles;
            else if (test_stop && (c == 'J' || c == 'L')) {
                const int i = c == 'J' ? 0 : 1;
                const long long divisor = (i == 0 ? 2LL : 1LL) * 70224;
                const long long elapsed = cycles - switch_start[i];
                // Markers enclose the 2050-M-cycle pause plus a short fixed
                // instruction sequence; allow its old/new speed boundary.
                if (switch_start[i] < 0 || elapsed < 2050LL*4*450000/divisor ||
                    elapsed > 2082LL*4*450000/divisor) {
                    printf("\n[banktest] FAIL: speed-switch pause outside hardware interval (%lld clocks)\n", elapsed);
                    break;
                }
                switch_done[i] = true;
            }
            if (test_stop && c == 'S') { stop_seen = true; wake_at = cycles + 270000; }
            else if (test_stop && stop_seen && c == 'A') {
                if (!woke) { printf("\n[banktest] FAIL: unarmed STOP returned before button press\n"); break; }
                stop_ack = true;
            }
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
            if (test_stop && (!stop_ack || !switch_done[0] || !switch_done[1]))
                printf("\n[banktest] FAIL: missing speed-switch or STOP/wake sequence\n");
            else if (missing || bad) printf("\n[banktest] %s: FAIL image (%d pixels not shade 1, %d missing)\n", argv[1], bad, missing);
            else { printf("\n[banktest] %s: PASS (cgb_mode=%d)\n", argv[1], cgb); rc = 0; }
            break;
        }
    }
    if (t == max_ticks) printf("\n[banktest] %s: FAIL timeout (pc=%04x, passed=%d)\n", argv[1], g->pc_dbg, passed);
    delete g;
    return rc;
}
