// DMG system: CPU + memory map + timer + serial + joypad + PPU.
// clk runs at 4x the M-cycle rate; one T-cycle per clk (ce_t), one M-cycle per 4 clk (ce).
module gb (
    input             clk,
    input             rst,
    input             clk_en,           // global clock enable (T-cycle rate)
    input      [7:0]  buttons,          // active high: {start,select,b,a,down,up,left,right}
    // video out (one pixel per pix_we)
    output            pix_we,
    output     [1:0]  pix,
    output     [7:0]  pix_x,
    output     [7:0]  pix_y,
    output            vsync,
    output            lcd_on,
    // cartridge (from header, set by the loader): type 0 none, 1 MBC1, 2 MBC3, 3 MBC5
    input      [1:0]  cart_type,
    input      [8:0]  rom_mask,         // ROM bank mask (banks - 1)
    input      [3:0]  ram_mask,         // RAM bank mask
    // external cartridge memory (PSRAM via bridge)
    output     [21:0] ext_addr,
    output            ext_req,          // 1-clk pulse at M-cycle start
    output            ext_we,
    output     [7:0]  ext_wd,
    input      [7:0]  ext_rd,
    // serial debug
    output reg        ser_valid,
    output reg [7:0]  ser_data,
    output     [15:0] pc_dbg
);
    reg [1:0] tdiv;
    always @(posedge clk) if (rst) tdiv <= 0; else if (clk_en) tdiv <= tdiv + 1;
    wire ce = clk_en && tdiv == 2'd3;

    wire [15:0] a;
    wire [7:0] cpu_dout;
    wire cpu_wr, cpu_rd;
    reg [7:0] cpu_din;
    wire [4:0] irq;

    sm83 cpu (
        .clk(clk), .rst(rst), .ce(ce), .addr(a), .dout(cpu_dout), .wr(cpu_wr), .rd(cpu_rd),
        .din(cpu_din), .irq(irq), .halted(), .pc_dbg(pc_dbg)
    );

    wire wr_now = ce && cpu_wr;

    // ---------------- memories ----------------
    // OAM DMA (FF46): 160 M-cycles. Like hardware, DMA owns the external bus
    // (ROM/WRAM) while active; the CPU only sees HRAM/IO. This keeps every
    // memory single-ported (one BSRAM port each).
    reg dma_act;
    reg [7:0] dma_hi, dma_idx;
    wire [15:0] dma_src = {dma_hi, dma_idx};
    wire [15:0] ma = dma_act ? dma_src : a;   // external-bus address
    wire cpu_blk = dma_act && a[15:8] != 8'hFF; // CPU locked out of everything but HRAM/IO

    // ---------------- cartridge: MBC1/3/5 mapping onto external memory (PSRAM) ----------------
    // ROM at ext {bank, a[13:0]}; cartridge RAM at ext 0x3E0000 + {ram_bank, a[12:0]}.
    // The CPU/DMA address is stable for the whole M-cycle; one request is issued at cycle start
    // and ext_rd must be valid >=2 clk before the next ce (see psram_bridge).
    reg ram_en, mbc1_mode;
    reg [8:0] rom_bank;
    reg [3:0] ram_bank;
    always @(posedge clk) begin
        if (rst) begin ram_en <= 0; mbc1_mode <= 0; rom_bank <= 9'd1; ram_bank <= 0; end
        else if (wr_now && a[15] == 1'b0) case (cart_type)
            2'd1: case (a[14:13])                                   // MBC1
                2'd0: ram_en <= cpu_dout[3:0] == 4'hA;
                2'd1: rom_bank[4:0] <= cpu_dout[4:0] == 0 ? 5'd1 : cpu_dout[4:0];
                2'd2: ram_bank[1:0] <= cpu_dout[1:0];               // also ROM bank bits 5-6
                default: mbc1_mode <= cpu_dout[0];
            endcase
            2'd2: case (a[14:13])                                   // MBC3 (no RTC)
                2'd0: ram_en <= cpu_dout[3:0] == 4'hA;
                2'd1: rom_bank[6:0] <= cpu_dout[6:0] == 0 ? 7'd1 : cpu_dout[6:0];
                2'd2: ram_bank <= {2'b00, cpu_dout[1:0]};
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
    wire cram_sel = ma[15:13] == 3'b101 && ram_en && cart_type != 2'd0;
    assign ext_addr = rom_sel ? {bank[7:0], ma[13:0]} : {5'b11111, rbank, ma[12:0]};
    reg cyc_start;                // also set right after reset: the first opcode fetch (0100) needs a request
    always @(posedge clk) cyc_start <= ce || rst;
    assign ext_req = cyc_start && !rst && (rom_sel || cram_sel) &&
                     !(cpu_wr && !dma_act && rom_sel);                 // ROM writes are MBC registers
    assign ext_we = cpu_wr && !dma_act && cram_sel;
    assign ext_wd = cpu_dout;

    reg [7:0] wram [0:8191];
    reg [7:0] wram_q;
    wire wram_sel = a[15:13] == 3'b110 || (a[15:13] == 3'b111 && a < 16'hFE00); // C000-FDFF (echo)
    always @(posedge clk) begin
        if (wr_now && wram_sel && !dma_act) wram[a[12:0]] <= cpu_dout;
        wram_q <= wram[ma[12:0]];
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
        .clk(clk), .rst(rst), .ce(ce), .addr_lo(a[7:0]), .sel(tim_sel), .wr(cpu_wr),
        .din(cpu_dout), .dout(tim_q), .irq(tim_irq)
    );

    // ---------------- PPU ----------------
    wire [7:0] ppu_q;
    wire vram_sel = a[15:13] == 3'b100;
    wire oam_sel  = a[15:8] == 8'hFE && a[7:0] < 8'hA0;
    wire preg_sel = a[15:4] == 12'hFF4 && a[3:0] <= 4'hB && a[3:0] != 4'h6;
    wire ppu_vblank, ppu_stat;
    wire [7:0] dma_data = (dma_src[15:14] == 2'b11) ? wram_q : ext_rd; // ROM/cart RAM/WRAM (VRAM source unsupported)

    ppu ppu (
        .clk(clk), .rst(rst), .ce_t(clk_en), .ce(ce),
        .cpu_addr(a), .cpu_wr(wr_now && !(dma_act && oam_sel)), .cpu_din(cpu_dout), .cpu_dout(ppu_q),
        .vram_sel(vram_sel), .oam_sel(oam_sel), .reg_sel(preg_sel),
        .dma_act(dma_act), .dma_we(dma_act && ce), .dma_idx(dma_idx), .dma_data(dma_data),
        .irq_vblank(ppu_vblank), .irq_stat(ppu_stat),
        .pix_we(pix_we), .pix(pix), .pix_x(pix_x), .pix_y(pix_y), .vsync(vsync), .lcd_on(lcd_on)
    );

    always @(posedge clk) begin
        if (rst) begin dma_act <= 0; dma_idx <= 0; dma_hi <= 0; end
        else begin
            if (ce && dma_act) begin
                dma_idx <= dma_idx + 1;
                if (dma_idx == 8'd159) dma_act <= 0;
            end
            if (wr_now && a == 16'hFF46) begin dma_act <= 1; dma_hi <= cpu_dout; dma_idx <= 0; end
        end
    end

    // ---------------- joypad ----------------
    reg [1:0] joy_sel;
    reg [3:0] joy_prev;
    reg [7:0] btn_r;              // sampled at M-cycle edges (keeps CPU input paths multicycle-safe)
    wire [3:0] joy_in = ~((joy_sel[0] ? 4'h0 : btn_r[3:0]) | (joy_sel[1] ? 4'h0 : btn_r[7:4]));
    always @(posedge clk) begin
        if (rst) joy_sel <= 2'b11;
        else if (wr_now && a == 16'hFF00) joy_sel <= cpu_dout[5:4];
        if (ce) begin joy_prev <= joy_in; btn_r <= buttons; end
    end
    wire joy_irq = ce && |(joy_prev & ~joy_in);

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
        else if (a[15:13] == 3'b101) cpu_din = cram_sel ? ext_rd : 8'hFF;
        else if (wram_sel)       cpu_din = wram_q;
        else if (oam_sel)        cpu_din = ppu_q;
        else if (hram_sel)       cpu_din = hram_q;
        else if (tim_sel)        cpu_din = tim_q;
        else if (preg_sel)       cpu_din = ppu_q;
        else if (a == 16'hFF00)  cpu_din = {2'b11, joy_sel, joy_in};
        else if (a == 16'hFF01)  cpu_din = sb;
        else if (a == 16'hFF02)  cpu_din = {sc[7], 6'b111111, sc[0]};
        else if (a == 16'hFF46)  cpu_din = dma_hi;
        else                     cpu_din = 8'hFF;
    end
endmodule
