// Tang Nano 9K top: Game Boy / Game Boy Color core -> 1280x720@60 HDMI.
// Clock domains: 27 MHz system (GB core, loader, UART; CLKOUTD/6 of the PSRAM PLL), 162 MHz memory
// fabric, 74.25 MHz video and 371.25 MHz TMDS serializer. PPU dots use a fractional clock enable of
// exactly 70224 dots per 450000 system clocks, frame-locked to the video timing, so a 6-line ring
// buffer (1 BSRAM, rtl/video_buffer.v) replaces a full frame buffer.
// Game: .gb image loaded into PSRAM from SPI flash @ 0x100000 on power-up / S1 (`make rom`), or over
// the USB-UART (host/gbctl.py load). MBC1/3/5 bank switching maps it for the core.
module top (
    input        clk27,
    input        btn1_n,         // S1: reset + reload ROM from flash
    input        btn2_n,         // S2: START
    output       flash_clk,
    output       flash_cs_n,
    output       flash_mosi,
    input        flash_miso,
    input  [7:0] joy_n,          // header buttons to GND: {start, select, b, a, down, up, left, right}
    input        uart_rx,        // BL702 USB-UART (FPGA_RX, pin 18)
    output       uart_tx,        // BL702 USB-UART (FPGA_TX, pin 17)
    output [5:0] led_n,
    output       tmds_clk_p, tmds_clk_n,
    output [2:0] tmds_d_p, tmds_d_n,
    // on-package PSRAM (pins placed automatically by the toolchain)
    output [1:0] O_psram_ck,
    inout  [1:0] IO_psram_rwds,
    inout  [15:0] IO_psram_dq,
    output [1:0] O_psram_cs_n,
    output [1:0] O_psram_reset_n,
    output [1:0] O_psram_ck_n
);

    // ---------------- clocks and resets ----------------
    // Clock net names are referenced by boards/tangnano9k/tangnano9k.sdc.
    wire mclk, clk_sys, mlock;      // 162 MHz memory fabric; 27 MHz system = mclk / 6
    pll_psram #(.FREQ(162_000_000)) pll_mem (.clock_in(clk27), .clock_out(mclk), .clock_sys(clk_sys), .locked(mlock));
    wire clk_ser, vlock, clk_pix;   // 371.25 MHz serializer; 74.25 MHz video = clk_ser / 5
    pll_video pll_vid (.clock_in(clk27), .clock_out(clk_ser), .locked(vlock));
    CLKDIV #(.DIV_MODE("5")) cdiv (.HCLKIN(clk_ser), .RESETN(vlock), .CALIB(1'b0), .CLKOUT(clk_pix));

    reg [7:0] por = 0;
    always @(posedge clk_sys) if (!mlock) por <= 0; else if (!por[7]) por <= por + 1;
    wire rst = !por[7];
    reg [7:0] vpor = 0;
    always @(posedge clk_pix) if (!vlock) vpor <= 0; else if (!vpor[7]) vpor <= vpor + 1;
    wire vrst = !vpor[7];

    // ---------------- PSRAM (162 MHz domain) ----------------
    reg [7:0] mpor = 0;
    always @(posedge mclk) if (!mlock) mpor <= 0; else if (!mpor[7]) mpor <= mpor + 1;
    assign O_psram_reset_n = {2{mpor[7]}};
    wire b_req, b_we, b_busy, p_ready, b_hang; wire [7:0] b_lat; wire [21:0] b_addr; wire [7:0] b_wd, b_rd;
    wire [7:0] b_state;
    psram_bridge #(.FREQ(162_000_000)) pb (
        .clk(clk_sys), .rst(rst), .req(b_req), .we(b_we), .addr(b_addr), .wd(b_wd), .rd(b_rd),
        .busy(b_busy), .ready(p_ready), .hang(b_hang), .dbg_lat(b_lat), .dbg_word(),
        .dbg_state(b_state),
        .mclk(mclk), .mrst_n(mpor[7]),
        .O_psram_ck(O_psram_ck), .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n)
    );

    // ---------------- game image loader: SPI flash @ 0x100000 (power-on, S1) or USB-UART ----------------
    reg [15:0] btn_sync;
    always @(posedge clk_sys) btn_sync <= {btn_sync[7:0], ~btn1_n, ~btn2_n, 6'b0};
    wire test_req, test_we, test_done, test_pass;
    wire [21:0] test_addr;            // holds the failing address once a test fails
    wire [7:0] test_wd, test_expected, test_actual;
    psram_test memtest (
        .clk(clk_sys), .rst(rst || btn_sync[15]), .ready(p_ready), .busy(b_busy), .rd(b_rd),
        .req(test_req), .we(test_we), .addr(test_addr), .wd(test_wd),
        .done(test_done), .passed(test_pass), .fail_addr(),
        .expected(test_expected), .actual(test_actual)
    );
    wire fl_rst = rst || !p_ready || !test_pass || btn_sync[15];
    reg fl_rst_d;
    always @(posedge clk_sys) fl_rst_d <= fl_rst;
    wire fl_start = fl_rst_d && !fl_rst;
    wire fl_v, fl_busy, ld_full, ld_done; wire [7:0] fl_d;
    spi_rom_loader #(.FLASH_ADDR(24'h100000)) flash_rd (
        .clk(clk_sys), .rst(fl_rst), .hold(ld_full), .stop(ld_done), .busy(fl_busy),
        .valid(fl_v), .data(fl_d),
        .sclk(flash_clk), .cs_n(flash_cs_n), .mosi(flash_mosi), .miso(flash_miso)
    );

    // External joypad: buttons to GND on header pins (internal pull-ups), sampled every ~1.2 ms
    // (debounce). Order matches the core: {start, select, b, a, down, up, left, right}.
    reg [14:0] jdiv;
    reg [7:0] jmeta, joy;
    always @(posedge clk_sys) begin
        jdiv <= jdiv + 1;
        jmeta <= ~joy_n;
        if (jdiv == 0) joy <= jmeta;
    end

    // ---------------- USB-UART (BL702, 115200 8N1) ----------------
    // 'J' <buttons>; 'L' <whole .gb image> -> 'K' <8-bit sum> (length taken from header 0x148);
    // 'V' <line> = shades; 'W' <line> = RGB555; 'F' = post-scaler fingerprint.
    // S/D/H/V/W/F replies are serialized so they never interleave with a captured line.
    wire u_v; wire [7:0] u_d;
    uart_rx #(.DIV(234)) urx (.clk(clk_sys), .rx(uart_rx), .valid(u_v), .data(u_d));
    localparam S_CMD = 2'd0, S_JOY = 2'd1, S_ROM = 2'd2, S_LINE = 2'd3;
    reg [1:0] us;
    reg [7:0] ubtn;
    reg [21:0] idle;
    reg cap_color;                // line request format: 0 = 'V' 2-bit shades
    // TX queue: 'L' done -> 'K' <sum>; 'S' -> 'S' <flags> <load addr[21:14]> <PC[15:8]>
    //   flags = {psram_ready, load_done, flash_busy, lcd_on, video_locked, waitlock, cart_type[1:0]}
    reg [3:0] tq;                 // bytes left to send
    reg [2:0] tq_s;               // 0 load, 1 status, 2 memory, 3 header, 4 scanout
    wire [15:0] scanout_sig; wire [7:0] scanout_frame;
    reg [23:0] scanout_reply;
    wire tx_rdy, cap_busy, cap_we; wire [7:0] cap_d;
    wire cap_req = u_v && us == S_LINE;
    wire [15:0] pc;
    wire lcd_on;
    wire locked_v, waitlock;
    wire ld_m_req; wire [21:0] ld_m_addr; wire [7:0] ld_m_wd;
    wire u_start = u_v && us == S_CMD && u_d == "L";
    wire [1:0] cart_type; wire [8:0] rom_mask; wire [3:0] ram_mask; wire [7:0] lsum;
    wire cgb_mode, cart_rtc, cart_ram;
    always @(posedge clk_sys) begin
        if (rst) begin us <= S_CMD; ubtn <= 0; idle <= 0; tq <= 0; cap_color <= 0; end
        else begin
            if (tq != 0 && tx_rdy) tq <= tq - 1;
            idle <= u_v ? 22'd0 : (idle[21] ? idle : idle + 1);
            if (idle[21] && us != S_CMD) us <= S_CMD;          // ~78 ms gap aborts 'J'/'L'/'V'
            if (us == S_ROM && ld_done) begin us <= S_CMD; tq <= 2; tq_s <= 0; end
            if (u_v) case (us)
                S_CMD: if (u_d == "J") us <= S_JOY;
                       else if (u_d == "L") us <= S_ROM;
                       else if (cap_busy) ;
                       else if (u_d == "S") begin tq <= 4; tq_s <= 1; end
                       else if (u_d == "D") begin tq <= 9; tq_s <= 2; end
                       else if (u_d == "H") begin tq <= 3; tq_s <= 3; end
                       else if (u_d == "V") begin us <= S_LINE; cap_color <= 0; end
                       else if (u_d == "W") begin us <= S_LINE; cap_color <= 1; end
                       else if (u_d == "F") begin
                           tq <= 4; tq_s <= 4; scanout_reply <= {scanout_frame, scanout_sig};
                       end
                S_JOY: begin ubtn <= u_d; us <= S_CMD; end
                S_LINE: us <= S_CMD;
                default: ;
            endcase
        end
    end
    reg [7:0] tx_d;
    always @(*) case ({tq_s, tq})
        7'b000_0010: tx_d = "K";
        7'b000_0001: tx_d = lsum;
        7'b001_0100: tx_d = "S";
        7'b001_0011: tx_d = {p_ready, ld_done, fl_busy, lcd_on, locked_v, waitlock, cart_type};
        7'b001_0010: tx_d = ld_m_addr[21:14];
        7'b010_1001: tx_d = "D";
        7'b010_1000: tx_d = {test_done, test_pass, test_we, b_busy, p_ready, b_hang, test_req, logo_ok};
        7'b010_0111: tx_d = b_state;
        7'b010_0110: tx_d = {2'b0, test_addr[21:16]};
        7'b010_0101: tx_d = test_addr[15:8];
        7'b010_0100: tx_d = test_addr[7:0];
        7'b010_0011: tx_d = test_expected;
        7'b010_0010: tx_d = test_actual;
        7'b010_0001: tx_d = b_lat;
        7'b011_0011: tx_d = "H";
        7'b011_0010: tx_d = rb0;
        7'b011_0001: tx_d = rb1;
        7'b100_0100: tx_d = "F";
        7'b100_0011: tx_d = scanout_reply[23:16];
        7'b100_0010: tx_d = scanout_reply[15:8];
        7'b100_0001: tx_d = scanout_reply[7:0];
        default: tx_d = pc[15:8];
    endcase
    uart_tx #(.DIV(234)) utx (.clk(clk_sys), .rst(rst), .tx(uart_tx), .ready(tx_rdy),
                              .we(tq != 0 || cap_we), .wd(tq != 0 ? tx_d : cap_d));

    cart_loader loader (
        .clk(clk_sys), .start(fl_start || u_start),
        .in_v(us == S_ROM ? u_v : fl_v), .in_d(us == S_ROM ? u_d : fl_d),
        .full(ld_full), .done(ld_done),
        .m_req(ld_m_req), .m_addr(ld_m_addr), .m_wd(ld_m_wd), .m_busy(b_busy),
        .cgb_mode(cgb_mode), .cart_type(cart_type), .cart_rtc(cart_rtc), .cart_ram(cart_ram),
        .rom_mask(rom_mask), .ram_mask(ram_mask), .sum(lsum)
    );

    // Post-load self-check: read back header bytes 0x104/0x105 (0xCE 0xED in every valid ROM)
    // before the core runs; reported by the D (logo_ok) and H (both bytes) UART commands.
    reg [2:0] vst;                // 0 wait load, 1/3 issue, 2/4 wait reply, 5 done
    reg logo_ok;
    reg [7:0] rb0, rb1;
    always @(posedge clk_sys) begin
        if (rst || !ld_done) begin vst <= 0; logo_ok <= 0; rb0 <= 0; rb1 <= 0; end
        else case (vst)
            3'd0: if (!b_busy) vst <= 3'd1;
            3'd1, 3'd3: vst <= vst + 1;
            3'd2: if (!b_busy) begin rb0 <= b_rd; logo_ok <= b_rd == 8'hCE; vst <= 3'd3; end
            3'd4: if (!b_busy) begin rb1 <= b_rd; vst <= 3'd5; end
            default: ;
        endcase
    end
    wire loading = !test_pass || vst != 3'd5;

    // ---------------- Game Boy ----------------
    wire pix_we; wire [1:0] pix; wire [14:0] pix_rgb; wire [7:0] px, py;
    wire gb_vsync, tick, tick_fast;
    wire [7:0] jb = joy | ubtn | {btn_sync[14], 7'b0};   // {start, select, b, a, down, up, left, right}
    wire gb_rst = rst || loading || btn_sync[15];
    wire g_req, g_we; wire [21:0] g_addr; wire [7:0] g_wd;
    gb core (
        .clk(clk_sys), .rst(gb_rst), .clk_en(tick), .clk_en_fast(tick_fast), .buttons(jb),
        .cgb_mode(cgb_mode),
        .pix_we(pix_we), .pix(pix), .pix_rgb(pix_rgb), .pix_x(px), .pix_y(py), .vsync(gb_vsync),
        .lcd_on(lcd_on),
        .cart_type(cart_type), .cart_rtc(cart_rtc), .cart_ram(cart_ram),
        .rom_mask(rom_mask), .ram_mask(ram_mask),
        .ext_addr(g_addr), .ext_req(g_req), .ext_we(g_we), .ext_wd(g_wd), .ext_rd(b_rd),
        .ser_valid(), .ser_data(), .pc_dbg(pc)
    );
    wire v_issue = vst == 3'd1 || vst == 3'd3;
    assign b_req  = !test_done ? test_req : !test_pass ? 1'b0 : !ld_done ? ld_m_req : v_issue ? 1'b1 : vst == 3'd5 ? g_req : 1'b0;
    assign b_we   = !test_done ? test_we : !ld_done ? 1'b1 : v_issue ? 1'b0 : g_we;
    assign b_addr = !test_done ? test_addr : !ld_done ? ld_m_addr : vst == 3'd1 ? 22'h104 : vst == 3'd3 ? 22'h105 : g_addr;
    assign b_wd   = !test_done ? test_wd : !ld_done ? ld_m_wd : g_wd;

    // ---------------- headless video readback ('V' <line>, see rtl/line_capture.v) ----------------
    line_capture lcap (
        .clk(clk_sys), .rst(rst), .req(cap_req), .line(u_d), .color_mode(cap_color),
        .running(!gb_rst), .lcd_on(lcd_on),
        .pix_we(pix_we), .pix(pix), .pix_rgb(pix_rgb), .pix_x(px), .pix_y(py),
        .tx_ready(tx_rdy && tq == 0), .tx_we(cap_we), .tx_d(cap_d), .busy(cap_busy)
    );

    // ---------------- 720p video: GB clock enable, frame lock, 6-line ring, 5x scaler ----------------
    wire [7:0] vr, vg, vb; wire vde, vhs, vvs;
    video_buffer vbuf (
        .clk_sys(clk_sys), .rst_sys(rst), .run(!gb_rst), .lcd_on(lcd_on), .gb_vsync(gb_vsync),
        .cgb_mode(cgb_mode),
        .pix_we(pix_we), .pix_x(px), .pix_y(py), .pix(pix), .pix_rgb(pix_rgb),
        .tick(tick), .tick_fast(tick_fast), .locked(locked_v), .waitlock(waitlock),
        .clk_pix(clk_pix), .rst_pix(vrst),
        .r(vr), .g(vg), .b(vb), .de(vde), .hs(vhs), .vs(vvs),
        .scanout_sig(scanout_sig), .scanout_frame(scanout_frame)
    );

    hdmi_out hdmi (
        .pclk(clk_pix), .fclk(clk_ser), .rst(vrst),
        .r(vr), .g(vg), .b(vb), .de(vde), .hs(vhs), .vs(vvs),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // Button test: LED0..5 = Up, Down, Left, Right, A, B; Select lights LED0-2, Start lights LED3-5.
    assign led_n = ~({jb[5], jb[4], jb[0], jb[1], jb[3], jb[2]} |
                     {jb[7], jb[7], jb[7], jb[6], jb[6], jb[6]});
endmodule
