// Verilator testbench: runs the gb core with an ideal external cartridge memory (stands in for
// PSRAM), echoes serial output, dumps the last frame as PPM.
// usage: Vgb <rom.gb> <max_frames> <out.ppm>
// GB_PRESS="from:to:mask,..." holds joypad mask (bit0=right..bit7=start) during frames [from,to)
// GB_FRAME_HASH=path writes "event vsyncs ticks kind fnv1a64" per frame, taken when line 143's last
// pixel lands (vblank entry): kind N rendered, F first frame after LCD on, O LCD off (all white,
// one per 70224 dots since the previous event). Hash covers the 160x144 framebuffer as 16-bit LE words.
// GB_FRAME_DUMP=N:path additionally writes hash event N's frame as PPM and stops the run there.
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
    g->cart_rtc = type == 0x0F || type == 0x10;
    g->cart_ram = rb != 0;
    g->cgb_mode = (ext[0x143] & 0x80) != 0;
    static unsigned short fb[144][160];
    memset(fb, 0, sizeof fb);
    std::string ser;
    g->clk_en = 1; g->clk_en_fast = 1; g->buttons = 0; g->rst = 1; g->ext_rd = 0xFF;
    for (int i = 0; i < 8; i++) { g->clk = 0; g->eval(); g->clk = 1; g->eval(); }
    g->rst = 0;
    int frames = 0;
    long long ticks = 0, max_ticks = (long long)max_frames * 70224;
    long acc = 0;
    // GB_MEM_LATENCY: system clocks from request to read data (hardware PSRAM ~10).
    const int latency = getenv("GB_MEM_LATENCY") ? atoi(getenv("GB_MEM_LATENCY")) : 0;
    int read_due = 0; unsigned read_data = 0xFF;
    auto write_ppm = [&](const char *path) {
        FILE *f = fopen(path, "wb");
        if (!f) { perror(path); return false; }
        fprintf(f, "P6 160 144 255\n");
        static const unsigned char shade[4] = {0xE0, 0xA8, 0x58, 0x10};
        for (int y = 0; y < 144; y++) for (int x = 0; x < 160; x++) {
            if (g->cgb_mode) {
                unsigned v = fb[y][x];
                for (int shift : {0, 5, 10}) {
                    unsigned c = (v >> shift) & 31;
                    fputc((c << 3) | (c >> 2), f);
                }
            } else {
                unsigned char s = shade[fb[y][x] & 3];
                fputc(s, f); fputc(s, f); fputc(s, f);
            }
        }
        fclose(f);
        return true;
    };
    FILE *fh = getenv("GB_FRAME_HASH") ? fopen(getenv("GB_FRAME_HASH"), "w") : nullptr;
    int dump_event = 0; const char *dump_path = nullptr;
    if (const char *d = getenv("GB_FRAME_DUMP")) { dump_event = atoi(d); dump_path = strchr(d, ':'); if (dump_path) dump_path++; }
    int hash_events = 0; long long last_event = 0; bool lcd_was_off = false;
    auto frame_hash = [&](char kind) {
        unsigned long long h = 0xcbf29ce484222325ULL;
        for (int y = 0; y < 144; y++) for (int x = 0; x < 160; x++) {
            unsigned v = kind == 'O' ? (g->cgb_mode ? 0x7FFF : 0) : fb[y][x];
            h = (h ^ (v & 0xFF)) * 0x100000001b3ULL;
            h = (h ^ (v >> 8)) * 0x100000001b3ULL;
        }
        if (fh) fprintf(fh, "%d %d %lld %c %016llx\n", ++hash_events, frames, ticks, kind, h);
        else ++hash_events;
        last_event = ticks;
        if (dump_path && hash_events == dump_event) { write_ppm(dump_path); max_ticks = ticks; }
    };
    while (ticks < max_ticks) {
        // Same fractional enable as the 27 MHz system domain.
        g->clk_en_fast = acc >= 154776 && acc < 225000;
        acc += 70224; g->clk_en = acc >= 450000;
        g->clk_en_fast |= g->clk_en;
        if (g->clk_en) { acc -= 450000; ticks++; }
        g->clk = 0; g->eval();
        bool req = g->ext_req, we = g->ext_we; unsigned addr = g->ext_addr, wd = g->ext_wd;
        g->clk = 1; g->eval();
        if (read_due > 0 && --read_due == 0) g->ext_rd = read_data;
        if (req) {
            if (we) ext[addr] = wd;
            else if (latency) { read_data = ext[addr]; read_due = latency; }
            else g->ext_rd = ext[addr];
        }
        if (g->pix_we && g->pix_y < 144 && g->pix_x < 160)
            fb[g->pix_y][g->pix_x] = g->cgb_mode ? g->pix_rgb : g->pix;
        if (fh || dump_path) {
            if (!g->lcd_on) {
                lcd_was_off = true;
                if (ticks - last_event >= 70224) frame_hash('O');
            } else if (g->pix_we && g->pix_y == 143 && g->pix_x == 159) {
                frame_hash(lcd_was_off ? 'F' : 'N');
                lcd_was_off = false;
            }
        }
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
            // Mooneye protocol: Fibonacci bytes 3 5 8 13 21 34 = pass, six 0x42 = fail.
            static const std::string fib("\x03\x05\x08\x0D\x15\x22", 6), bad(6, '\x42');
            if (ser.size() >= 6 && ser.compare(ser.size() - 6, 6, fib) == 0) { printf("\nPassed\n"); break; }
            if (ser.size() >= 6 && ser.compare(ser.size() - 6, 6, bad) == 0) { printf("\nFailed\n"); break; }
            if (ser.find("Passed") != std::string::npos || ser.find("Failed") != std::string::npos) break;
        }
    }
    if (fh) fclose(fh);
    if (!write_ppm(out)) return 2;
    printf("\n[tb] ticks=%lld frames=%d pc=%04x\n", ticks, frames, g->pc_dbg);
    delete g;
    return ser.find("Failed") != std::string::npos ? 1 : 0;
}
