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
    (* BEL = "X46Y28/CLKDIV_HCLK1_SECT0" *)
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
    // 'F' = post-scaler fingerprint. Replies are serialized through one queue.
    // 'P' <0|1|2>: resume / freeze / query the core -> 'p' <{dirty cart RAM, frozen}>.
    // A/B/T/U (cartridge RAM and MBC3 clock transfer, frozen core only): see rtl/host_mem.v.
    // 'Q' <div>: switch both UART directions to 27 MHz / div once the reply queue drains.
    // A new rate stays on probation until an 'S' arrives at it; ~1.2 s without one falls
    // back to 115200 (div 234), so a rate the USB bridge cannot carry never strands the host.
    wire u_v; wire [7:0] u_d;
    reg [8:0] udiv;
    reg [7:0] udiv_next;
    reg baud_switch, probation;
    reg [24:0] probation_cnt;
    wire tx_idle;
    uart_rx urx (.clk(clk_sys), .div(udiv), .rx(uart_rx), .valid(u_v), .data(u_d));
    localparam S_CMD = 3'd0, S_JOY = 3'd1, S_ROM = 3'd2, S_BAUD = 3'd3, S_PAUSE = 3'd4;
    reg [2:0] us;
    reg [7:0] ubtn;
    reg [21:0] idle;
    // TX queue: 'L' done -> 'K' <sum>; 'S' -> 'S' <flags> <load addr[21:14]> <PC[15:8]>
    //   flags = {psram_ready, load_done, flash_busy, lcd_on, video_locked, waitlock, cart_type[1:0]}
    reg [3:0] tq;                 // bytes left to send
    reg [2:0] tq_s;               // 0 load, 1 status, 2 memory, 3 header, 4 scanout
    wire [15:0] scanout_sig; wire [7:0] scanout_frame;
    reg [23:0] scanout_reply;
    wire tx_rdy;
    wire [15:0] pc;
    wire lcd_on;
    wire locked_v, waitlock;
    wire ld_m_req; wire [21:0] ld_m_addr; wire [7:0] ld_m_wd;
    wire hm_busy;                 // host transfer owns the UART byte stream
    wire u_start = u_v && !hm_busy && us == S_CMD && u_d == "L";
    wire core_ser_valid, menu_pending;
    wire [7:0] core_ser_data;
    wire [15:0] menu_index;
    wire menu_arm = u_v && !hm_busy && us == S_CMD && u_d == "M" && tq == 0;
    menu_bridge menu_requests (
        .clk(clk_sys), .rst(rst || btn_sync[15]), .arm(menu_arm), .disarm(u_start || fl_start),
        .ser_valid(core_ser_valid), .ser_data(core_ser_data),
        .take(tq_s == 5 && tq == 1 && tx_rdy), .pending(menu_pending), .index(menu_index)
    );
    wire [1:0] cart_type; wire [8:0] rom_mask; wire [3:0] ram_mask; wire [7:0] lsum;
    wire cgb_mode, cart_rtc, cart_ram;
    // Freeze gates the core's clock enables. Resume first reissues the held bus access,
    // then waits until its reply is valid before the core advances again.
    reg freeze, dirty;
    reg [4:0] resume_cnt;
    wire core_hold = freeze || resume_cnt != 0;
    wire bus_resume = resume_cnt == 5'd20;
    wire hm_tx_we, hm_req, hm_we, rtc_load; wire [7:0] hm_tx_d, hm_wd;
    wire [21:0] hm_addr; wire [39:0] rtc_d, rtc_live;
    always @(posedge clk_sys) begin
        if (rst) begin us <= S_CMD; ubtn <= 0; idle <= 0; tq <= 0;
                       freeze <= 0; resume_cnt <= 0; dirty <= 0;
                       udiv <= 9'd234; baud_switch <= 0; probation <= 0; end
        else begin
            if (tq != 0 && tx_rdy) tq <= tq - 1;
            idle <= u_v ? 22'd0 : (idle[21] ? idle : idle + 1);
            if (idle[21] && us != S_CMD) us <= S_CMD;          // ~78 ms gap aborts 'J'/'L'/'V'
            if (us == S_ROM && ld_done) begin us <= S_CMD; tq <= 2; tq_s <= 0; end
            if (resume_cnt != 0) resume_cnt <= resume_cnt - 1'b1;
            if (g_req && g_we && vst == 3'd5) dirty <= 1;
            if (u_start) dirty <= 0;
            if (menu_pending && tq == 0 && !u_v) begin tq <= 4; tq_s <= 5; end
            if (baud_switch && tx_idle && tq == 0) begin
                udiv <= {1'b0, udiv_next}; baud_switch <= 0;
                probation <= udiv_next != 8'd234; probation_cnt <= 0;
            end
            if (probation) begin
                probation_cnt <= probation_cnt + 1'b1;
                if (&probation_cnt) begin udiv <= 9'd234; probation <= 0; end
            end
            if (u_v && !hm_busy) case (us)
                S_CMD: if (u_d == "J") us <= S_JOY;
                       else if (u_d == "L") us <= S_ROM;
                       else if (tq != 0) ;
                       else if (u_d == "P") us <= S_PAUSE;
                       else if (u_d == "Q") us <= S_BAUD;
                       else if (u_d == "M") begin tq <= 2; tq_s <= 6; end
                       else if (u_d == "S") begin tq <= 4; tq_s <= 1; probation <= 0; end
                       else if (u_d == "D") begin tq <= 9; tq_s <= 2; end
                       else if (u_d == "H") begin tq <= 3; tq_s <= 3; end
                       else if (u_d == "F") begin
                           tq <= 4; tq_s <= 4; scanout_reply <= {scanout_frame, scanout_sig};
                       end
                S_JOY: begin ubtn <= u_d; us <= S_CMD; end
                S_BAUD: begin
                    us <= S_CMD;
                    if (u_d >= 8'd8) begin udiv_next <= u_d; baud_switch <= 1; end
                end
                S_PAUSE: begin
                    us <= S_CMD; tq <= 2; tq_s <= 7;
                    if (u_d == 8'd1 && !freeze) begin freeze <= 1; dirty <= 0; end
                    else if (u_d == 8'd0 && freeze) begin freeze <= 0; resume_cnt <= 5'd20; end
                end
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
        7'b101_0100: tx_d = "G";
        7'b101_0011: tx_d = menu_index[7:0];
        7'b101_0010: tx_d = menu_index[15:8];
        7'b101_0001: tx_d = menu_index[7:0] ^ menu_index[15:8] ^ 8'h5A;
        7'b110_0010: tx_d = "M";
        7'b110_0001: tx_d = 8'h01; // launcher protocol version
        7'b111_0010: tx_d = "p";
        7'b111_0001: tx_d = {6'd0, dirty, freeze};
        default: tx_d = pc[15:8];
    endcase
    uart_tx utx (.clk(clk_sys), .rst(rst), .div(udiv), .tx(uart_tx), .ready(tx_rdy), .idle(tx_idle),
                 .we(tq != 0 || hm_tx_we), .wd(tq != 0 ? tx_d : hm_tx_d));

    host_mem host_port (
        .clk(clk_sys), .rst(rst), .allow(freeze && resume_cnt == 0 && vst == 3'd5),
        .cmd_ok(us == S_CMD && tq == 0), .abort(idle[21]),
        .in_v(u_v), .in_d(u_d), .busy(hm_busy),
        .tx_ok(tx_rdy && tq == 0), .tx_we(hm_tx_we), .tx_d(hm_tx_d),
        .m_req(hm_req), .m_we(hm_we), .m_addr(hm_addr), .m_wd(hm_wd), .m_busy(b_busy), .m_rd(b_rd),
        .rtc_q(rtc_live), .rtc_load(rtc_load), .rtc_d(rtc_d)
    );

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
        .clk(clk_sys), .rst(gb_rst), .clk_en(tick && !core_hold), .clk_en_fast(tick_fast && !core_hold),
        .buttons(jb),
        .cgb_mode(cgb_mode),
        .pix_we(pix_we), .pix(pix), .pix_rgb(pix_rgb), .pix_x(px), .pix_y(py), .vsync(gb_vsync),
        .lcd_on(lcd_on),
        .cart_type(cart_type), .cart_rtc(cart_rtc), .cart_ram(cart_ram),
        .rom_mask(rom_mask), .ram_mask(ram_mask),
        .ext_addr(g_addr), .ext_req(g_req), .ext_we(g_we), .ext_wd(g_wd), .ext_rd(b_rd),
        .bus_resume(bus_resume), .rtc_host_load(rtc_load), .rtc_host_d(rtc_d), .rtc_live(rtc_live),
        .ser_valid(core_ser_valid), .ser_data(core_ser_data), .pc_dbg(pc)
    );
    wire v_issue = vst == 3'd1 || vst == 3'd3;
    // Host transfers own the bus only while the core is frozen; no core access is in flight then.
    assign b_req  = !test_done ? test_req : !test_pass ? 1'b0 : !ld_done ? ld_m_req : v_issue ? 1'b1 :
                    hm_busy ? hm_req : vst == 3'd5 ? g_req : 1'b0;
    assign b_we   = !test_done ? test_we : !ld_done ? 1'b1 : v_issue ? 1'b0 : hm_busy ? hm_we : g_we;
    assign b_addr = !test_done ? test_addr : !ld_done ? ld_m_addr : vst == 3'd1 ? 22'h104 :
                    vst == 3'd3 ? 22'h105 : hm_busy ? hm_addr : g_addr;
    assign b_wd   = !test_done ? test_wd : !ld_done ? ld_m_wd : hm_busy ? hm_wd : g_wd;

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
