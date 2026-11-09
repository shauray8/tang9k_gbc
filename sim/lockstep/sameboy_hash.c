// SameBoy reference run producing the same per-frame hash stream as sim/tb.cpp's GB_FRAME_HASH.
// usage: sameboy_hash [--our-init] [--dump N:out.ppm]... <cgb_boot.bin> <rom.gbc> <frames> <out.hash>
//   Runs the CGB boot ROM (CGB-E), then counts from the handoff to 0x0100: <frames> * 70224 dots.
//   GB_PRESS="from:to:mask,..." as in tb.cpp, keyed to LCD-on LY 153->0 transitions (our vsync).
//   Hash lines "event vsyncs ticks kind fnv1a64": N rendered frame, F first frame after LCD on (SameBoy
//   shows white), R repeat (CGB keeps the previous frame), O LCD-off white frame, A artificial.
//   --our-init: at the handoff overwrite CPU registers, internal DIV, IE/IF, WRAM/HRAM/VRAM/OAM with
//   the FPGA core's reset state and restart the PPU at LY 0 by toggling LCDC.7.
#define GB_INTERNAL
#include <Core/gb.h>
#include <Core/random.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t screen[160 * 144];
static FILE *hash_out;
static int events, vsyncs;
// Our core starts at LY 0 so its first vsync follows its first vblank; SameBoy hands off at an
// arbitrary LY. Vsyncs seen before SameBoy's first vblank are discounted so GB_PRESS frame numbers
// mean the same game frame on both sides.
static int vsync_bias = -1;
static long long ticks8; // 8 MHz ticks since handoff (2 per dot)
static bool started;
static struct { int event; const char *path; } dumps[16];
static int ndumps;

static uint32_t encode(GB_gameboy_t *gb, uint8_t r, uint8_t g, uint8_t b)
{
    (void)gb; // channels arrive as (c << 3) | (c >> 2) with colour correction off
    return (r >> 3) | (g >> 3) << 5 | (uint32_t)(b >> 3) << 10;
}

static void write_ppm(const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return; }
    fprintf(f, "P6 160 144 255\n");
    for (unsigned i = 0; i < 160 * 144; i++)
        for (unsigned shift = 0; shift <= 10; shift += 5) {
            unsigned c = (screen[i] >> shift) & 31;
            fputc((c << 3) | (c >> 2), f);
        }
    fclose(f);
}

static void vblank(GB_gameboy_t *gb, GB_vblank_type_t type)
{
    if (!started) return;
    char kind = type == GB_VBLANK_TYPE_NORMAL_FRAME ? 'N' : type == GB_VBLANK_TYPE_LCD_OFF ? 'O' :
                type == GB_VBLANK_TYPE_REPEAT ? 'R' : 'A';
    // GB_display_vblank already whitened the screen for the skipped first frame after LCD on
    if (kind == 'N' && gb->frame_skip_state == GB_FRAMESKIP_LCD_TURNED_ON) kind = 'F';
    uint64_t h = 0xcbf29ce484222325ULL;
    for (unsigned i = 0; i < 160 * 144; i++) {
        h = (h ^ (screen[i] & 0xFF)) * 0x100000001b3ULL;
        h = (h ^ (screen[i] >> 8)) * 0x100000001b3ULL;
    }
    if (vsync_bias < 0) vsync_bias = vsyncs;
    fprintf(hash_out, "%d %d %lld %c %016llx\n", ++events, vsyncs - vsync_bias, (ticks8 + gb->cycles_since_run) / 2, kind,
            (unsigned long long)h);
    for (int i = 0; i < ndumps; i++)
        if (dumps[i].event == events) write_ppm(dumps[i].path);
}

static unsigned press_mask(int frame)
{
    unsigned m = 0;
    const char *p = getenv("GB_PRESS");
    if (!p) return 0;
    int a, b, k, n;
    while (sscanf(p, "%d:%d:%i%n", &a, &b, &k, &n) == 3) {
        if (frame >= a && frame < b) m |= k;
        p += n; if (*p == ',') p++; else break;
    }
    return m;
}

static void print_state(GB_gameboy_t *gb, const char *tag)
{
    printf("%s: AF=%04x BC=%04x DE=%04x HL=%04x SP=%04x PC=%04x IME=%d\n", tag,
           gb->af, gb->bc, gb->de, gb->hl, gb->sp, gb->pc, gb->ime);
    printf("%s: LY(FF44)=%d current_line=%d STAT=%02x mode=%d LCDC=%02x cycles_into_line=%d\n", tag,
           gb->io_registers[GB_IO_LY], gb->current_line, gb->io_registers[GB_IO_STAT],
           gb->io_registers[GB_IO_STAT] & 3, gb->io_registers[GB_IO_LCDC], gb->cycles_for_line);
    printf("%s: DIV(FF04)=%02x div_counter=%04x TIMA=%02x TMA=%02x TAC=%02x IE=%02x IF=%02x KEY1=%02x double_speed=%d\n", tag,
           gb->div_counter >> 8, gb->div_counter, gb->io_registers[GB_IO_TIMA], gb->io_registers[GB_IO_TMA],
           gb->io_registers[GB_IO_TAC], gb->interrupt_enable, gb->io_registers[GB_IO_IF],
           gb->io_registers[GB_IO_KEY1], gb->cgb_double_speed);
}

int main(int argc, char **argv)
{
    bool our_init = false;
    int argi = 1;
    for (; argi < argc && argv[argi][0] == '-' && argv[argi][1] == '-'; argi++) {
        if (!strcmp(argv[argi], "--our-init")) our_init = true;
        else if (!strcmp(argv[argi], "--dump") && argi + 1 < argc && ndumps < 16) {
            char *colon = strchr(argv[++argi], ':');
            if (!colon) { fprintf(stderr, "--dump N:path\n"); return 2; }
            dumps[ndumps].event = atoi(argv[argi]);
            dumps[ndumps++].path = colon + 1;
        }
        else { fprintf(stderr, "unknown option %s\n", argv[argi]); return 2; }
    }
    if (argc - argi != 4) {
        fprintf(stderr, "usage: sameboy_hash [--our-init] [--dump N:out.ppm]... boot.bin rom.gbc frames out.hash\n");
        return 2;
    }
    const char *boot = argv[argi], *rom = argv[argi + 1], *out = argv[argi + 3];
    long long max_ticks = atoll(argv[argi + 2]) * 70224LL;

    GB_random_seed(0); // deterministic power-on RAM contents
    GB_gameboy_t *gb = GB_init(GB_alloc(), GB_MODEL_CGB_E);
    if (GB_load_boot_rom(gb, boot) || GB_load_rom(gb, rom)) { fprintf(stderr, "load failed\n"); return 2; }
    GB_set_pixels_output(gb, screen);
    GB_set_border_mode(gb, GB_BORDER_NEVER);
    GB_set_rgb_encode_callback(gb, encode);
    GB_set_color_correction_mode(gb, GB_COLOR_CORRECTION_DISABLED);
    GB_set_light_temperature(gb, 0);
    GB_set_vblank_callback(gb, vblank);
    GB_set_turbo_mode(gb, true, true);
    GB_set_turbo_cap(gb, 0);
    GB_set_rtc_mode(gb, GB_RTC_MODE_ACCURATE);
    GB_set_emulate_joypad_bouncing(gb, false);
    hash_out = fopen(out, "w");
    if (!hash_out) { perror(out); return 2; }

    long long boot_ticks = 0;
    while (!(gb->boot_rom_finished && gb->pc == 0x0100)) {
        boot_ticks += GB_run(gb);
        if (boot_ticks > 8LL * 1000 * 1000 * 60) { fprintf(stderr, "boot ROM never reached 0x0100\n"); return 1; }
    }
    printf("handoff after %lld dots of boot ROM\n", boot_ticks / 2);
    print_state(gb, "sameboy handoff");
    if (our_init) {
        // FPGA core reset: sm83.v registers, timer.v div=ABCC, IE=IF=0, zeroed RAMs, PPU at LY 0 dot 0
        gb->af = 0x1180; gb->bc = 0x0000; gb->de = 0xFF56; gb->hl = 0x000D; gb->sp = 0xFFFE;
        gb->ime = false;
        gb->div_counter = 0xABCC;
        gb->interrupt_enable = 0;
        gb->io_registers[GB_IO_IF] = 0;
        memset(gb->ram, 0, gb->ram_size);
        memset(gb->hram, 0, sizeof gb->hram);
        memset(gb->vram, 0, gb->vram_size);
        memset(gb->oam, 0, sizeof gb->oam);
        uint8_t lcdc = gb->io_registers[GB_IO_LCDC];
        GB_write_memory(gb, 0xFF40, lcdc & 0x7F);
        GB_write_memory(gb, 0xFF40, lcdc | 0x80);
        print_state(gb, "sameboy our-init");
    }
    fflush(stdout);

    started = true;
    unsigned prev_line = gb->current_line;
    while (ticks8 < 2 * max_ticks) {
        ticks8 += GB_run(gb);
        unsigned line = gb->current_line;
        if (prev_line == 153 && line == 0 && (gb->io_registers[GB_IO_LCDC] & 0x80)) {
            vsyncs++;
            if (vsync_bias >= 0) GB_set_key_mask(gb, (GB_key_mask_t)press_mask(vsyncs - vsync_bias));
        }
        prev_line = line;
    }
    fclose(hash_out);
    printf("ticks=%lld events=%d vsyncs=%d (bias %d) pc=%04x\n", ticks8 / 2, events, vsyncs - vsync_bias, vsync_bias, gb->pc);
    return 0;
}
