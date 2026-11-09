// DMG/CGB system: CPU, memory map, timer, serial, joypad and PPU.
// clk_en is the PPU dot rate; clk_en_fast adds the half-dot CPU T-cycle.
module gb (
    input             clk,
    input             rst,
    input             clk_en,           // PPU dots / normal CPU T-cycles
    input             clk_en_fast,      // double CPU T-cycles; includes clk_en
    input      [7:0]  buttons,          // active high: {start,select,b,a,down,up,left,right}
    // video out (one pixel per pix_we)
    output            pix_we,
    output     [1:0]  pix,
    output     [14:0] pix_rgb,          // native CGB RGB555: {blue, green, red}
    output     [7:0]  pix_x,
    output     [7:0]  pix_y,
    output            vsync,
    output            lcd_on,
    // cartridge (from header, set by the loader): type 0 none, 1 MBC1 (or MBC2), 2 MBC3, 3 MBC5
    input      [1:0]  cart_type,
    input             cart_rtc,         // header type 0F/10: MBC3 with timer
    input             cart_mbc2,        // header type 05/06: MBC2 (cart_type is 1)
    input             cart_ram,         // header declares cartridge RAM
    input      [8:0]  rom_mask,         // ROM bank mask (banks - 1)
    input      [3:0]  ram_mask,         // RAM bank mask
    input             cgb_mode,         // CGB-mode cartridge (header 0x143 bit 7): enables SVBK/VBK
    // external cartridge memory (PSRAM via bridge)
    output     [21:0] ext_addr,
    output            ext_req,          // 1-clk pulse at M-cycle start
    output            ext_we,
    output     [7:0]  ext_wd,
    input      [7:0]  ext_rd,
    input             bus_resume,       // host released a freeze: reissue the held bus access
    input             rtc_host_load,
    input      [39:0] rtc_host_d,
    output     [39:0] rtc_live,
    // serial debug
    output reg        ser_valid,
    output reg [7:0]  ser_data,
    output     [15:0] pc_dbg
);
    reg [1:0] tdiv, joy_sel;
    reg double_speed, key_prepare, stopped;
    reg [11:0] speed_wait;
    wire stop_req;
    wire [3:0] stop_joy_in = ~((joy_sel[0] ? 4'h0 : buttons[3:0]) |
                                (joy_sel[1] ? 4'h0 : buttons[7:4]));
    wire stop_enter = stop_req && stop_joy_in == 4'hF;
    wire stop_wake = stopped && stop_joy_in != 4'hF;
    wire cpu_tick = double_speed ? clk_en_fast : clk_en;
    wire cpu_mcycle = cpu_tick && tdiv == 2'd3;
    wire ce = cpu_mcycle && !stopped && speed_wait == 0;
    reg hdma_active, hdma_hblank, hdma_busy, hdma_pending, hdma_half, hdma_used, hdma_req;
    reg [15:0] hdma_src;
    reg [12:0] hdma_dst;
    reg [6:0] hdma_left;
    wire cpu_halted, ppu_hblank;
    wire hdma_start = hdma_pending && hdma_active && !dma_act && !cpu_halted &&
                      (!hdma_hblank || (ppu_hblank && !hdma_used));
    wire hdma_owns = hdma_busy || hdma_start;
    wire hdma_hold = hdma_busy || hdma_pending || (hdma_active && !hdma_hblank);
    wire cpu_ce = ce && !hdma_hold;
    wire hdma_put = hdma_busy && clk_en && hdma_half;
    wire hdma_block_end = hdma_src[3:0] == 4'hF;
    wire hdma_release = hdma_put && (hdma_dst == 13'h1FFF ||
                       (hdma_block_end && (hdma_left == 0 || hdma_hblank)));
    always @(posedge clk)
        if (rst || stop_enter || hdma_release) tdiv <= 0;
        else if (cpu_tick) tdiv <= tdiv + 1'b1;

    wire [15:0] a;
    wire [7:0] cpu_dout;
    wire cpu_wr, cpu_rd;
    reg [7:0] cpu_din;
    wire [4:0] irq;

    sm83 cpu (
        .clk(clk), .rst(rst), .ce(cpu_ce), .addr(a), .dout(cpu_dout), .wr(cpu_wr), .rd(cpu_rd),
        .din(cpu_din), .irq(irq), .cgb_mode(cgb_mode), .halted(cpu_halted), .stop_req(stop_req), .pc_dbg(pc_dbg)
    );

    wire wr_now = cpu_ce && cpu_wr;

    // STOP arms an oscillator pause, not a derived clock. PPU dots continue
    // during speed switching; normal STOP also stops them until joypad wake.
    always @(posedge clk) begin
        if (rst) begin
            double_speed <= 0; key_prepare <= 0; speed_wait <= 0; stopped <= 0;
        end else begin
            if (wr_now && a == 16'hFF4D && cgb_mode) key_prepare <= cpu_dout[0];
            if (cpu_mcycle && speed_wait != 0) speed_wait <= speed_wait - 1'b1;
            if (stop_wake) stopped <= 0;
            if (stop_enter) begin
                if (cgb_mode && key_prepare) begin
                    double_speed <= !double_speed;
                    key_prepare <= 0;
                    speed_wait <= 12'd2050;
                end else stopped <= 1;
            end
        end
    end

    // ---------------- memories ----------------
    // OAM DMA (FF46): written in M-cycle 0, idle in M1 (a running DMA keeps going), then
    // 160 transfer cycles M2..M161. The DMA owns only the bus it reads: a ROM/cart-RAM/WRAM
    // source holds the external bus (CPU locked out of 0000-7FFF and A000-FDFF), a VRAM
    // source holds VRAM. OAM is always locked; HRAM/IO stay free. This keeps every
    // memory single-ported (one BSRAM port each).
    reg dma_act, dma_pend;
    reg [7:0] dma_hi, dma_src_hi, dma_idx;   // dma_hi = FF46 as written
    wire [15:0] dma_src = {dma_src_hi, dma_idx};
    wire dma_vram = dma_act && dma_src[15:13] == 3'b100;
    wire dma_ext = dma_act && !dma_vram;
    wire [15:0] ma = hdma_owns ? hdma_src : dma_ext ? dma_src : a;
    wire a_vram = a[15:13] == 3'b100;
    wire cpu_blk = dma_act && a[15:8] != 8'hFF &&
                   (a[15:8] == 8'hFE || (dma_vram ? a_vram : !a_vram));

    // ---------------- cartridge: MBC1/2/3/5 mapping onto external memory (PSRAM) ----------------
    // ROM at ext {bank, a[13:0]}; cartridge RAM at ext 0x3E0000 + {ram_bank, a[12:0]}.
    // MBC2: address bit 8 picks RAM enable vs ROM bank anywhere in 0000-3FFF; its built-in
    // 512 x 4-bit RAM echoes through A000-BFFF and reads back with the upper nibble set.
    // The CPU/DMA address is stable for the whole M-cycle; one request is issued at cycle start
    // and ext_rd must be valid >=2 clk before the next ce (see psram_bridge).
    reg ram_en, mbc1_mode;
    reg [8:0] rom_bank;
    reg [3:0] ram_bank;
    reg mbc3_invalid;
    always @(posedge clk) begin
        if (rst) begin ram_en <= 0; mbc1_mode <= 0; rom_bank <= 9'd1; ram_bank <= 0; mbc3_invalid <= 0; end
        else if (wr_now && a[15] == 1'b0 && cart_mbc2) begin
            if (!a[14]) begin
                if (a[8]) rom_bank[3:0] <= cpu_dout[3:0] == 0 ? 4'd1 : cpu_dout[3:0];
                else ram_en <= cpu_dout[3:0] == 4'hA;
            end
        end
        else if (wr_now && a[15] == 1'b0) case (cart_type)
            2'd1: case (a[14:13])                                   // MBC1
                2'd0: ram_en <= cpu_dout[3:0] == 4'hA;
                2'd1: rom_bank[4:0] <= cpu_dout[4:0] == 0 ? 5'd1 : cpu_dout[4:0];
                2'd2: ram_bank[1:0] <= cpu_dout[1:0];               // also ROM bank bits 5-6
                default: mbc1_mode <= cpu_dout[0];
            endcase
            2'd2: case (a[14:13])                                   // MBC3 RAM/RTC selection
                2'd0: ram_en <= cpu_dout[3:0] == 4'hA;
                2'd1: rom_bank[6:0] <= cpu_dout[6:0] == 0 ? 7'd1 : cpu_dout[6:0];
                2'd2: begin ram_bank <= cpu_dout[3:0]; mbc3_invalid <= |cpu_dout[7:4]; end
                default: ;
            endcase
            2'd3: case (a[14:12])                                   // MBC5
                3'd0, 3'd1: ram_en <= cpu_dout[3:0] == 4'hA;
                3'd2: rom_bank[7:0] <= cpu_dout;
                3'd3: rom_bank[8] <= cpu_dout[0];
                3'd4, 3'd5: ram_bank <= cpu_dout[3:0];
                default: ;
            endcase
            default: ;
        endcase
    end
    wire mbc1 = cart_type == 2'd1;
    wire [8:0] bank_hi = mbc1 ? {2'b00, ram_bank[1:0], rom_bank[4:0]} : rom_bank;     // 4000-7FFF
    wire [8:0] bank_lo = mbc1 && mbc1_mode ? {2'b00, ram_bank[1:0], 5'd0} : 9'd0;     // 0000-3FFF
    wire [8:0] bank = (ma[14] ? bank_hi : bank_lo) & rom_mask;
    wire [3:0] rbank = (mbc1 && !mbc1_mode ? 4'd0 : ram_bank) & ram_mask;
    wire rom_sel = ma[15] == 1'b0;
    wire mbc3 = cart_type == 2'd2;
    wire cart_window = ma[15:13] == 3'b101 && ram_en;
    wire cram_sel = cart_window && cart_ram && cart_type != 2'd0 &&
                    (!mbc3 || (!mbc3_invalid && !ram_bank[3]));
    wire rtc_sel = cart_window && mbc3 && cart_rtc && !mbc3_invalid &&
                   ram_bank >= 4'h8 && ram_bank <= 4'hC;
    wire [7:0] rtc_q;
    wire [7:0] cart_q = rtc_sel ? rtc_q : cram_sel ? (cart_mbc2 ? {4'hF, ext_rd[3:0]} : ext_rd) : 8'hFF;
    mbc3_rtc rtc (
        .clk(clk), .rst(rst || !cart_rtc),
        .latch_wr(wr_now && mbc3 && cart_rtc && a[15:13] == 3'b011),
        .data_wr(wr_now && !cpu_blk && rtc_sel), .select(ram_bank),
        .din(cpu_dout), .dout(rtc_q),
        .host_load(rtc_host_load), .host_d(rtc_host_d), .live(rtc_live)
    );
    assign ext_addr = rom_sel ? {bank[7:0], ma[13:0]} :
                      {5'b11111, rbank, cart_mbc2 ? {4'd0, ma[8:0]} : ma[12:0]};
    reg cyc_start;                // also set right after reset: the first opcode fetch (0100) needs a request
    always @(posedge clk) cyc_start <= ce || rst || hdma_release;
    assign ext_req = !rst && (rom_sel || cram_sel) &&
                     (hdma_owns ? (hdma_start || hdma_req || bus_resume) :
                      (cyc_start || bus_resume) && !(cpu_wr && !dma_ext && rom_sel));
    assign ext_we = !hdma_owns && cpu_wr && !cpu_blk && cram_sel;
    assign ext_wd = cpu_dout;

    // WRAM: 8 x 4 KiB. C000-CFFF is bank 0; D000-DFFF is SVBK bank 1..7 (0 selects 1). E000-FDFF echoes
    // C000-DDFF with the same banking. DMG mode keeps SVBK at its reset state: the plain 8 KiB map.
    // Single port: CPU writes are blocked while DMA owns the bus, so the one address is always ma.
    reg [2:0] svbk;               // stored as written (reads back 0 after writing 0)
    always @(posedge clk)
        if (rst) svbk <= 0;
        else if (wr_now && a == 16'hFF70 && cgb_mode) svbk <= cpu_dout[2:0];
    wire [2:0] wbank = !ma[12] ? 3'd0 : (cgb_mode && svbk != 0) ? svbk : 3'd1;
    wire [14:0] wram_a = {wbank, ma[11:0]};
    reg [7:0] wram [0:32767];
    reg [7:0] wram_q;
    wire wram_sel = a[15:13] == 3'b110 || (a[15:13] == 3'b111 && a < 16'hFE00); // C000-FDFF (echo)
    always @(posedge clk) begin
        if (wr_now && wram_sel && !cpu_blk) wram[wram_a] <= cpu_dout;
        wram_q <= wram[wram_a];
    end

    reg [7:0] hram [0:127];
    reg [7:0] hram_q;
    wire hram_sel = a[15:7] == 9'h1FF && a != 16'hFFFF;
    always @(posedge clk) begin
        if (wr_now && hram_sel) hram[a[6:0]] <= cpu_dout;
        hram_q <= hram[a[6:0]];
    end

    // ---------------- timer ----------------
    wire [7:0] tim_q;
    wire tim_irq;
    wire tim_sel = a[15:2] == 14'h3FC1; // FF04-FF07
    gb_timer timer (
        .clk(clk), .rst(rst), .ce(ce), .div_reset(stop_enter), .addr_lo(a[7:0]), .sel(tim_sel), .wr(wr_now),
        .din(cpu_dout), .dout(tim_q), .irq(tim_irq)
    );

    // ---------------- PPU ----------------
    wire [7:0] ppu_q;
    wire vram_sel = a[15:13] == 3'b100;
    wire oam_sel  = a[15:8] == 8'hFE && a[7:0] < 8'hA0;
    wire preg_sel = (a[15:4] == 12'hFF4 && (a[3:0] <= 4'hB && a[3:0] != 4'h6 || a[3:0] == 4'hF)) ||
                    (a >= 16'hFF68 && a <= 16'hFF6C);
    wire ppu_vblank, ppu_stat;
    // ROM/cart RAM/WRAM come over the external bus (WRAM follows SVBK and the echo map via ma).
    // A VRAM source uses the PPU's CPU read path; the CPU is locked out of VRAM during DMA.
    wire [7:0] dma_vq;
    wire [7:0] dma_data = dma_src[15:14] == 2'b11 ? wram_q : dma_vram ? dma_vq : rom_sel ? ext_rd : cart_q;
    wire [7:0] hdma_data = hdma_src[15:13] == 3'b110 ? wram_q :
                           rom_sel ? ext_rd : cart_q;

    ppu ppu (
        .clk(clk), .rst(rst), .ce_t(clk_en && !stopped), .ce(cpu_ce || hdma_release), .cgb_mode(cgb_mode),
        .cpu_addr(hdma_busy ? {3'b100, hdma_dst} : a),
        .cpu_wr(hdma_busy ? hdma_put : wr_now && !cpu_blk),
        .cpu_din(hdma_busy ? hdma_data : cpu_dout), .cpu_dout(ppu_q),
        .vram_sel(hdma_busy || vram_sel), .vram_dma(hdma_busy),
        .oam_dma_vram(dma_vram), .oam_dma_addr(dma_src[12:0]), .oam_dma_vq(dma_vq),
        .oam_sel(!hdma_busy && oam_sel), .reg_sel(!hdma_busy && preg_sel),
        .dma_act(dma_act), .dma_we(dma_act && ce), .dma_idx(dma_idx), .dma_data(dma_data),
        .irq_vblank(ppu_vblank), .irq_stat(ppu_stat), .hblank(ppu_hblank),
        .pix_we(pix_we), .pix(pix), .pix_rgb(pix_rgb), .pix_x(pix_x), .pix_y(pix_y), .vsync(vsync), .lcd_on(lcd_on)
    );

    always @(posedge clk) begin
        if (rst) begin dma_act <= 0; dma_pend <= 0; dma_idx <= 0; dma_hi <= 0; dma_src_hi <= 0; end
        else begin
            if (ce && dma_act) begin
                dma_idx <= dma_idx + 1;
                if (dma_idx == 8'd159) dma_act <= 0;
            end
            if (ce && dma_pend) begin
                dma_pend <= 0; dma_act <= 1; dma_src_hi <= dma_hi; dma_idx <= 0;
            end
            if (wr_now && a == 16'hFF46) begin dma_pend <= 1; dma_hi <= cpu_dout; end
        end
    end

    // One byte per two PPU dots, at either CPU speed. The one-clock pending
    // grant observes HALT/OAM DMA entered on the preceding CPU edge.
    // Releasing the bus reissues the held CPU read and gives it a full M-cycle.
    always @(posedge clk) begin
        if (rst) begin
            hdma_active <= 0; hdma_hblank <= 0; hdma_busy <= 0;
            hdma_pending <= 0; hdma_half <= 0; hdma_used <= 0; hdma_req <= 0;
            hdma_src <= 0; hdma_dst <= 0; hdma_left <= 7'h7F;
        end else begin
            hdma_req <= 0;
            hdma_pending <= 0;
            if (!ppu_hblank) hdma_used <= 0;
            if (ce && hdma_active && !hdma_busy && !hdma_pending &&
                !dma_act && !cpu_halted &&
                (!hdma_hblank || (ppu_hblank && !hdma_used)))
                hdma_pending <= 1;
            if (hdma_start) begin
                hdma_busy <= 1;
                hdma_half <= 0;
                if (hdma_hblank) hdma_used <= 1;
            end
            if (hdma_busy && clk_en) begin
                hdma_half <= !hdma_half;
                if (hdma_half) begin
                    hdma_src <= hdma_src + 1'b1;
                    hdma_dst <= hdma_dst + 1'b1;
                    if (hdma_block_end) hdma_left <= hdma_left - 1'b1;
                    if (hdma_release) hdma_busy <= 0;
                    else hdma_req <= 1;
                    if (hdma_dst == 13'h1FFF || (hdma_block_end && hdma_left == 0)) begin
                        hdma_active <= 0;
                        hdma_left <= 7'h7F;
                    end
                end
            end
            if (wr_now && cgb_mode) case (a)
                16'hFF51: if (!hdma_active) hdma_src[15:8] <= cpu_dout;
                16'hFF52: if (!hdma_active) hdma_src[7:0] <= {cpu_dout[7:4], 4'b0};
                16'hFF53: if (!hdma_active) hdma_dst[12:8] <= cpu_dout[4:0];
                16'hFF54: if (!hdma_active) hdma_dst[7:0] <= {cpu_dout[7:4], 4'b0};
                16'hFF55: begin
                    if (hdma_active) begin
                        if (hdma_hblank && !cpu_dout[7]) begin
                            hdma_active <= 0;
                            hdma_pending <= 0;
                        end
                    end else begin
                        hdma_active <= 1;
                        hdma_hblank <= cpu_dout[7];
                        hdma_left <= cpu_dout[6:0];
                        if (!cpu_dout[7]) hdma_pending <= 1;
                    end
                end
                default: ;
            endcase
        end
    end

    // ---------------- joypad ----------------
    reg [3:0] joy_prev;
    reg [7:0] btn_r;              // sampled at M-cycle edges (keeps CPU input paths multicycle-safe)
    wire [3:0] joy_in = ~((joy_sel[0] ? 4'h0 : btn_r[3:0]) | (joy_sel[1] ? 4'h0 : btn_r[7:4]));
    always @(posedge clk) begin
        if (rst) joy_sel <= 2'b11;
        else if (wr_now && a == 16'hFF00) joy_sel <= cpu_dout[5:4];
        if (stopped) begin joy_prev <= stop_joy_in; btn_r <= buttons; end
        else if (ce) begin joy_prev <= joy_in; btn_r <= buttons; end
    end
    wire joy_irq = (ce && |(joy_prev & ~joy_in)) || stop_wake;

    // ---------------- serial (no link partner) ----------------
    // Internal clock (SC bit0=1): transfer takes 8 bits x 128 M-cycles, receives 0xFF, then IRQ.
    // External clock: never completes (no cable), exactly like a lone Game Boy.
    // ser_valid/ser_data expose transmitted bytes for debug (Blargg test output).
    reg [7:0] sb;
    reg [7:0] sc;
    reg ser_irq;
    reg [9:0] ser_cnt;
    always @(posedge clk) begin
        ser_valid <= 0; ser_irq <= 0;
        if (rst) begin sb <= 0; sc <= 0; ser_cnt <= 0; end
        else begin
            if (ce && ser_cnt != 0) begin
                ser_cnt <= ser_cnt - 1;
                if (ser_cnt == 10'd1) begin sb <= 8'hFF; sc[7] <= 0; ser_irq <= 1; end
            end
            if (wr_now && a == 16'hFF01) sb <= cpu_dout;
            else if (wr_now && a == 16'hFF02) begin
                sc <= cpu_dout;
                ser_cnt <= 0;
                if (cpu_dout[7] && cpu_dout[0]) begin
                    ser_valid <= 1; ser_data <= sb; ser_cnt <= 10'd1023;
                end
            end
        end
    end

    assign irq = {joy_irq, ser_irq, tim_irq, ppu_stat, ppu_vblank};

    // ---------------- read mux (address stable during the M-cycle) ----------------
    always @(*) begin
        if (cpu_blk)             cpu_din = 8'hFF;
        else if (a[15] == 1'b0)  cpu_din = ext_rd;
        else if (vram_sel)       cpu_din = ppu_q;
        else if (a[15:13] == 3'b101) cpu_din = cart_q;
        else if (wram_sel)       cpu_din = wram_q;
        else if (oam_sel)        cpu_din = ppu_q;
        else if (hram_sel)       cpu_din = hram_q;
        else if (tim_sel)        cpu_din = tim_q;
        else if (preg_sel)       cpu_din = ppu_q;
        else if (a == 16'hFF00)  cpu_din = {2'b11, joy_sel, joy_in};
        else if (a == 16'hFF01)  cpu_din = sb;
        else if (a == 16'hFF02)  cpu_din = {sc[7], 6'b111111, sc[0]};
        else if (a == 16'hFF46)  cpu_din = dma_hi;
        else if (a == 16'hFF4D)  cpu_din = cgb_mode ? {double_speed, 6'b111111, key_prepare} : 8'hFF;
        else if (a == 16'hFF55)  cpu_din = cgb_mode ? {!hdma_active, hdma_left} : 8'hFF;
        else if (a == 16'hFF70)  cpu_din = cgb_mode ? {5'b11111, svbk} : 8'hFF;
        else                     cpu_din = 8'hFF;
    end
endmodule
