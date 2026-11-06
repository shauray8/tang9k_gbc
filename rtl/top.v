// Tang Nano 9K top: DMG core -> 640x480@60 HDMI.
// 25.2 MHz GB/video, 81 MHz memory fabric, and 126 MHz serializer domains. GB uses a fractional clock
// enable of exactly 70224 dots per 420000 pixel clocks, frame-locked to HDMI, so a 32-line ring
// buffer (1 BSRAM) replaces a full frame buffer.
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

    // ---------------- clocks ----------------
    wire fclk, lock, pclk;
    pll_126 pll (.clock_in(clk27), .clock_out(fclk), .locked(lock));
    CLKDIV #(.DIV_MODE("5")) cdiv (.HCLKIN(fclk), .RESETN(lock), .CALIB(1'b0), .CLKOUT(pclk));

    reg [7:0] por = 0;
    always @(posedge pclk) if (!lock) por <= 0; else if (!por[7]) por <= por + 1;
    wire rst = !por[7];

    // ---------------- video timing 640x480@60 (800x525) ----------------
    reg [9:0] hc, vc;
    reg [18:0] pos;              // vc*800+hc
    always @(posedge pclk) begin
        if (rst) begin hc <= 0; vc <= 0; pos <= 0; end
        else begin
            hc <= hc == 799 ? 10'd0 : hc + 1;
            if (hc == 799) vc <= vc == 524 ? 10'd0 : vc + 1;
            pos <= (hc == 799 && vc == 524) ? 19'd0 : pos + 1;
        end
    end

    // ---------------- GB clock enable, frame lock ----------------
    localparam [18:0] TARGET = 19'd380000;   // GB frame start = HDMI line 475 (see docs/design.md)
    reg [18:0] acc;
    reg waitlock, locked_v, tick;
    wire gb_vsync;
    always @(posedge pclk) begin
        tick <= 0;
        if (rst) begin acc <= 0; waitlock <= 0; locked_v <= 0; end
        else begin
            if (waitlock) begin
                if (pos == TARGET) begin waitlock <= 0; acc <= 0; end
            end else if (acc >= 19'd420000 - 19'd70224) begin
                acc <= acc + 19'd70224 - 19'd420000; tick <= 1;
            end else acc <= acc + 19'd70224;
            if (gb_vsync) begin
                if (pos < TARGET - 8 || pos > TARGET + 32) begin waitlock <= 1; locked_v <= 0; end
                else locked_v <= 1;
            end
        end
    end

    // ---------------- PSRAM (81 MHz domain) ----------------
    wire mclk, mlock;
    pll_psram pll2 (.clock_in(clk27), .clock_out(mclk), .locked(mlock));
    reg [7:0] mpor = 0;
    always @(posedge mclk) if (!mlock) mpor <= 0; else if (!mpor[7]) mpor <= mpor + 1;
    assign O_psram_reset_n = {2{mpor[7]}};
    wire b_req, b_we, b_busy, p_ready, b_hang; wire [7:0] b_lat; wire [15:0] b_word; wire [21:0] b_addr; wire [7:0] b_wd, b_rd;
    wire [7:0] b_state;
    psram_bridge pb (
        .clk(pclk), .rst(rst), .req(b_req), .we(b_we), .addr(b_addr), .wd(b_wd), .rd(b_rd),
        .busy(b_busy), .ready(p_ready), .hang(b_hang), .dbg_lat(b_lat), .dbg_word(b_word),
        .dbg_state(b_state),
        .mclk(mclk), .mrst_n(mpor[7]),
        .O_psram_ck(O_psram_ck), .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n)
    );

    // ---------------- game image loader: SPI flash @ 0x100000 (power-on, S1) or USB-UART ----------------
    reg [15:0] btn_sync;
    always @(posedge pclk) btn_sync <= {btn_sync[7:0], ~btn1_n, ~btn2_n, 6'b0};
    wire test_req, test_we, test_done, test_pass;
    wire [21:0] test_addr, test_fail_addr;
    wire [7:0] test_wd, test_expected, test_actual;
    psram_test memtest (
        .clk(pclk), .rst(rst || btn_sync[15]), .ready(p_ready), .busy(b_busy), .rd(b_rd),
        .req(test_req), .we(test_we), .addr(test_addr), .wd(test_wd),
        .done(test_done), .passed(test_pass), .fail_addr(test_fail_addr),
        .expected(test_expected), .actual(test_actual)
    );
    wire fl_rst = rst || !p_ready || !test_pass || btn_sync[15];
    reg fl_rst_d;
    always @(posedge pclk) fl_rst_d <= fl_rst;
    wire fl_start = fl_rst_d && !fl_rst;
    wire fl_v, fl_busy, ld_full, ld_done; wire [7:0] fl_d;
    spi_rom_loader #(.FLASH_ADDR(24'h100000)) flash_rd (
        .clk(pclk), .rst(fl_rst), .hold(ld_full), .stop(ld_done), .busy(fl_busy),
        .valid(fl_v), .data(fl_d),
        .sclk(flash_clk), .cs_n(flash_cs_n), .mosi(flash_mosi), .miso(flash_miso)
    );

    // External joypad: buttons to GND on header pins (internal pull-ups), sampled every ~1.3 ms
    // (debounce). Order matches the core: {start, select, b, a, down, up, left, right}.
    reg [14:0] jdiv;
    reg [7:0] jmeta, joy;
    always @(posedge pclk) begin
        jdiv <= jdiv + 1;
        jmeta <= ~joy_n;
        if (jdiv == 0) joy <= jmeta;
    end

    // ---------------- USB-UART (BL702, 115200 8N1) ----------------
    // 'J' <buttons>; 'L' <whole .gb image> -> 'K' <8-bit sum> (length taken from header 0x148);
    // 'V' <line> -> one captured LCD line (rtl/line_capture.v). S/D/H/V are ignored while a line
    // capture is in progress so replies never interleave.
    wire u_v; wire [7:0] u_d;
    uart_rx #(.DIV(219)) urx (.clk(pclk), .rx(uart_rx), .valid(u_v), .data(u_d));
    localparam S_CMD = 2'd0, S_JOY = 2'd1, S_ROM = 2'd2, S_LINE = 2'd3;
    reg [1:0] us;
    reg [7:0] ubtn;
    reg [21:0] idle;
    // TX queue: 'L' done -> 'K' <sum>; 'S' -> 'S' <flags> <load addr[21:14]> <PC[15:8]>
    //   flags = {psram_ready, load_done, flash_busy, lcd_on, video_locked, waitlock, cart_type[1:0]}
    reg [3:0] tq;                 // bytes left to send
    reg [1:0] tq_s;               // 0 = load ack, 1 = status, 2 = memory diagnostic, 3 = header
    wire tx_rdy, cap_busy, cap_we; wire [7:0] cap_d;
    wire cap_req = u_v && us == S_LINE;
    wire [15:0] pc;
    wire lcd_on;
    wire ld_m_req; wire [21:0] ld_m_addr; wire [7:0] ld_m_wd;
    wire u_start = u_v && us == S_CMD && u_d == "L";
    wire [1:0] cart_type; wire [8:0] rom_mask; wire [3:0] ram_mask; wire [7:0] lsum;
    wire cgb_mode;
    always @(posedge pclk) begin
        if (rst) begin us <= S_CMD; ubtn <= 0; idle <= 0; tq <= 0; end
        else begin
            if (tq != 0 && tx_rdy) tq <= tq - 1;
            idle <= u_v ? 22'd0 : (idle[21] ? idle : idle + 1);
            if (idle[21] && us != S_CMD) us <= S_CMD;          // ~80 ms gap aborts 'J'/'L'/'V'
            if (us == S_ROM && ld_done) begin us <= S_CMD; tq <= 2; tq_s <= 0; end
            if (u_v) case (us)
                S_CMD: if (u_d == "J") us <= S_JOY;
                       else if (u_d == "L") us <= S_ROM;
                       else if (cap_busy) ;
                       else if (u_d == "S") begin tq <= 4; tq_s <= 1; end
                       else if (u_d == "D") begin tq <= 9; tq_s <= 2; end
                       else if (u_d == "H") begin tq <= 3; tq_s <= 3; end
                       else if (u_d == "V") us <= S_LINE;
                S_JOY: begin ubtn <= u_d; us <= S_CMD; end
                S_LINE: us <= S_CMD;
                default: ;
            endcase
        end
    end
    reg [7:0] tx_d;
    always @(*) case ({tq_s, tq})
        6'b00_0010: tx_d = "K";
        6'b00_0001: tx_d = lsum;
        6'b01_0100: tx_d = "S";
        6'b01_0011: tx_d = {p_ready, ld_done, fl_busy, lcd_on, locked_v, waitlock, cart_type};
        6'b01_0010: tx_d = ld_m_addr[21:14];
        6'b10_1001: tx_d = "D";
        6'b10_1000: tx_d = {test_done, test_pass, test_we, b_busy, p_ready, b_hang, test_req, logo_ok};
        6'b10_0111: tx_d = b_state;
        6'b10_0110: tx_d = {2'b0, test_addr[21:16]};
        6'b10_0101: tx_d = test_addr[15:8];
        6'b10_0100: tx_d = test_addr[7:0];
        6'b10_0011: tx_d = test_expected;
        6'b10_0010: tx_d = test_actual;
        6'b10_0001: tx_d = b_lat;
        6'b11_0011: tx_d = "H";
        6'b11_0010: tx_d = rb0;
        6'b11_0001: tx_d = rb1;
        default:  tx_d = pc[15:8];
    endcase
    uart_tx #(.DIV(219)) utx (.clk(pclk), .rst(rst), .tx(uart_tx), .ready(tx_rdy),
                              .we(tq != 0 || cap_we), .wd(tq != 0 ? tx_d : cap_d));

    cart_loader loader (
        .clk(pclk), .start(fl_start || u_start),
        .in_v(us == S_ROM ? u_v : fl_v), .in_d(us == S_ROM ? u_d : fl_d),
        .full(ld_full), .done(ld_done),
        .m_req(ld_m_req), .m_addr(ld_m_addr), .m_wd(ld_m_wd), .m_busy(b_busy),
        .cgb_mode(cgb_mode), .cart_type(cart_type), .rom_mask(rom_mask), .ram_mask(ram_mask), .sum(lsum)
    );

    // Post-load self-check: read back header bytes 0x104/0x105 (0xCE 0xED in every valid ROM)
    // before the core runs; shown on screen as diagnostics.
    reg [2:0] vst;                // 0 wait load, 1/3 issue, 2/4 wait reply, 5 done
    reg logo_ok;
    reg [7:0] rb0, rb1;
    always @(posedge pclk) begin
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
    wire pix_we; wire [1:0] pix; wire [7:0] px, py;
    wire gb_rst = rst || loading || btn_sync[15];
    wire g_req, g_we; wire [21:0] g_addr; wire [7:0] g_wd;
    gb core (
        .clk(pclk), .rst(gb_rst), .clk_en(tick), .buttons(joy | ubtn | {btn_sync[14], 7'b0}),
        .cgb_mode(cgb_mode),
        .pix_we(pix_we), .pix(pix), .pix_x(px), .pix_y(py), .vsync(gb_vsync), .lcd_on(lcd_on),
        .cart_type(cart_type), .rom_mask(rom_mask), .ram_mask(ram_mask),
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
        .clk(pclk), .rst(rst), .req(cap_req), .line(u_d), .running(!gb_rst), .lcd_on(lcd_on),
        .pix_we(pix_we), .pix(pix), .pix_x(px), .pix_y(py),
        .tx_ready(tx_rdy && tq == 0), .tx_we(cap_we), .tx_d(cap_d), .busy(cap_busy)
    );

    // ---------------- 32-line ring buffer ----------------
    reg [1:0] ring [0:8191];
    reg [1:0] rq;
    reg [12:0] ra;
    always @(posedge pclk) begin
        if (pix_we) ring[{py[4:0], px}] <= pix;
        rq <= ring[ra];
    end

    // GB pixel at 3x scale, centred: x 80..559, y 24..455
    reg [7:0] gx, gy; reg [1:0] sx, sy;
    wire hin = hc >= 80 && hc < 560, vin = vc >= 24 && vc < 456;
    always @(posedge pclk) begin
        if (hc == 799) begin
            gx <= 0; sx <= 0;
            if (vc == 23 || vc == 524) begin gy <= 0; sy <= 0; end
            else if (vin) begin
                if (sy == 2) begin sy <= 0; gy <= gy + 1; end else sy <= sy + 1;
            end
        end else if (hin) begin
            if (sx == 2) begin sx <= 0; gx <= gx + 1; end else sx <= sx + 1;
        end
        ra <= {gy[4:0], gx};
    end

    // On-screen joypad tester in the side borders: D-pad left, B/A and Select/Start right.
    // Grey = released, white = pressed.
    wire [7:0] jb = joy | ubtn | {btn_sync[14], 7'b0};   // {start, select, b, a, down, up, left, right}
    function box(input [9:0] x, y, x0, y0, w, h);
        box = x >= x0 && x < x0 + w && y >= y0 && y < y0 + h;
    endfunction
    wire [7:0] ovh = {box(hc, vc, 600, 284, 20, 12),   // start
                      box(hc, vc, 568, 284, 20, 12),   // select
                      box(hc, vc, 572, 212, 18, 18),   // B
                      box(hc, vc, 600, 196, 18, 18),   // A
                      box(hc, vc,  31, 222, 18, 18),   // down
                      box(hc, vc,  31, 186, 18, 18),   // up
                      box(hc, vc,  13, 204, 18, 18),   // left
                      box(hc, vc,  49, 204, 18, 18)};  // right
    reg [1:0] ov_s0, ov_d;           // {in box, pressed}; aligned with rq (2 clk)

    // Diagnostics (left border, under the D-pad): 7 lights, green = OK / red = not, left to right:
    //   PSRAM ready, load done, PSRAM readback 0x104 == 0xCE, no stuck PSRAM request, LCD on,
    //   video locked, MBC detected. Yellow bar below = load progress (address bits 17:12).
    //   Rows of 8 below (green = 1, red = 0, MSB left): byte read at 0x104, byte read at 0x105,
    //   PSRAM-clock cycles of the last request, raw read word [15:8], raw read word [7:0].
    wire [9:0] dgx = hc - 10'd4;
    wire [6:0] dg_val = {cart_type != 2'd0, locked_v, lcd_on, !b_hang, logo_ok, ld_done, p_ready};
    wire dg_lit = hc >= 4 && dgx[2:0] < 6;                         // 6 px lights, 8 px pitch
    wire dg_row  = vc >= 300 && vc < 310 && dg_lit && dgx < 56;    // status lights
    wire [9:0] dgy = vc - 10'd330;
    wire dg_byte = vc >= 330 && dgy < 80 && dgy[3:0] < 10 && dg_lit && dgx < 64;
    wire [2:0] dg_k = dgy[6:4];
    wire [7:0] dg_b = !test_done ?
                      (dg_k == 0 ? b_state : dg_k == 1 ? {test_we, b_busy, test_addr[21:16]} :
                       dg_k == 2 ? test_addr[15:8] : dg_k == 3 ? test_addr[7:0] : b_lat) :
                      !test_pass ?
                      (dg_k == 0 ? test_expected : dg_k == 1 ? test_actual :
                       dg_k == 2 ? {test_done, test_pass, test_fail_addr[21:16]} :
                       dg_k == 3 ? test_fail_addr[15:8] : test_fail_addr[7:0]) :
                      (dg_k == 3'd0 ? rb0 : dg_k == 3'd1 ? rb1 : dg_k == 3'd2 ? b_lat :
                       dg_k == 3'd3 ? b_word[15:8] : b_word[7:0]);
    wire [2:0] dg_i = dgx[5:3];
    wire dg_bar = vc >= 316 && vc < 322 && hc >= 4 && hc < 4 + ld_m_addr[17:12];
    reg [2:0] dg_s0, dg_d;           // {is diag pixel, is light, light value}
    always @(posedge pclk) begin
        ov_s0 <= {|ovh, |(ovh & jb)};
        ov_d <= ov_s0;
        dg_s0 <= {dg_row || dg_byte || dg_bar, dg_row || dg_byte,
                  dg_row ? dg_val[dg_i] : dg_b[3'd7 - dg_i]};
        dg_d <= dg_s0;
    end

    // 3-stage alignment: counters -> ra -> rq
    reg [2:0] de_d, hs_d, vs_d, in_d;
    always @(posedge pclk) begin
        de_d <= {de_d[1:0], hc < 640 && vc < 480};
        hs_d <= {hs_d[1:0], !(hc >= 656 && hc < 752)};
        vs_d <= {vs_d[1:0], !(vc >= 490 && vc < 492)};
        in_d <= {in_d[1:0], hin && vin};
    end
    reg [23:0] rgb;
    always @(*) begin
        if (!in_d[1]) rgb = dg_d[2] ? (dg_d[1] ? (dg_d[0] ? 24'h30E030 : 24'hE03030) : 24'hE0C020) :
                            ov_d[1] ? (ov_d[0] ? 24'hF8F8F8 : 24'h3A4A3A) : 24'h101810;
        else if (!lcd_on || !locked_v) rgb = 24'hE0F8D0;
        else case (rq)
            2'd0: rgb = 24'hE0F8D0;
            2'd1: rgb = 24'h88C070;
            2'd2: rgb = 24'h346856;
            default: rgb = 24'h081820;
        endcase
    end

    hdmi_out hdmi (
        .pclk(pclk), .fclk(fclk), .rst(rst),
        .r(rgb[23:16]), .g(rgb[15:8]), .b(rgb[7:0]), .de(de_d[1]), .hs(hs_d[1]), .vs(vs_d[1]),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // Button test: LED0..5 = Up, Down, Left, Right, A, B; Select lights LED0-2, Start lights LED3-5.
    assign led_n = ~({jb[5], jb[4], jb[0], jb[1], jb[3], jb[2]} |
                     {jb[7], jb[7], jb[7], jb[6], jb[6], jb[6]});
endmodule
