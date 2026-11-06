// Volatile memory diagnostic. No CPU/video; the flashed game image is unchanged.
// FAST: 81 MHz memory fabric instead of 27 MHz. BRIDGE: actual 27-to-81 MHz bridge.
// UART remains at clk27. 'R' physically resets/retests memory; 'D' reports stable test results.
module psram_probe #(parameter FAST = 0, BRIDGE = 0, SYNC = 0, MEM_MHZ = 81, STRESS = 0) (
    input clk27, uart_rx,
    output uart_tx,
    output [1:0] O_psram_ck, O_psram_ck_n, O_psram_cs_n, O_psram_reset_n,
    inout [15:0] IO_psram_dq,
    inout [1:0] IO_psram_rwds
);
    localparam FREQ = (FAST || BRIDGE) ? MEM_MHZ * 1_000_000 : 27_000_000;
    wire mclk, mlock, tclk, tlock, sys27;
    generate if (FAST || BRIDGE) begin: fast_clock
        pll_psram #(.FREQ(FREQ)) pll (.clock_in(clk27), .clock_out(mclk), .clock_sys(sys27), .locked(mlock));
    end else begin: direct_clock
        assign mclk = clk27; assign mlock = 1'b1; assign sys27 = clk27;
    end endgenerate
    generate if (BRIDGE) begin: system_clock
        assign tclk = sys27; assign tlock = mlock;
    end else begin: memory_test_clock
        assign tclk = mclk; assign tlock = 1'b1;
    end endgenerate
    wire u_v; wire [7:0] u_d;
    reg [7:0] por = 0;
    always @(posedge clk27) begin
        if (!mlock || !tlock || (u_v && u_d == "R")) por <= 0;
        else if (!por[7]) por <= por + 1'b1;
    end
    wire rst = !por[7];
    assign O_psram_reset_n = {2{!rst}};
    wire req, we, busy, done, passed, ready, hang;
    wire [21:0] addr, fail_addr;
    wire [7:0] wd, rd, expected, actual, state, cycles;
    wire [15:0] debug_word;
    wire client_clk = SYNC ? mclk : tclk;
    generate if (BRIDGE) begin: with_bridge
        psram_bridge #(.FREQ(FREQ)) pb (
            .clk(client_clk), .rst(rst), .req(req), .we(we), .addr(addr), .wd(wd), .rd(rd),
            .busy(busy), .ready(ready), .hang(hang), .dbg_lat(cycles), .dbg_word(debug_word), .dbg_state(state),
            .mclk(mclk), .mrst_n(!rst), .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
            .O_psram_cs_n(O_psram_cs_n), .IO_psram_dq(IO_psram_dq), .IO_psram_rwds(IO_psram_rwds)
        );
    end else begin: without_bridge
        wire [15:0] word;
        reg initialized = 0;
        reg [7:0] elapsed;
        assign ready = initialized;
        assign hang = state[7];
        assign cycles = elapsed;
        assign rd = addr[0] ? word[15:8] : word[7:0];
        assign debug_word = word;
        always @(posedge mclk) begin
            if (rst) initialized <= 0; else if (!busy) initialized <= 1;
            if (rst || req) elapsed <= 0;
            else if (busy && ready && elapsed != 255) elapsed <= elapsed + 1'b1;
        end
        PsramController #(.FREQ(FREQ)) ctl (
            .clk(mclk), .resetn(!rst), .req(req), .we(we),
            .addr(addr), .din({wd, wd}), .byte_write(1'b1), .dout(word), .busy(busy), .debug(state),
            .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
            .O_psram_cs_n(O_psram_cs_n), .IO_psram_dq(IO_psram_dq), .IO_psram_rwds(IO_psram_rwds)
        );
    end endgenerate
    generate if (STRESS) begin: stress_test
        psram_stress mt (
            .clk(client_clk), .rst(rst), .ready(ready), .busy(busy), .rd(rd),
            .req(req), .we(we), .addr(addr), .wd(wd), .done(done), .passed(passed),
            .fail_addr(fail_addr), .expected(expected), .actual(actual)
        );
    end else begin: boot_test
        psram_test mt (
            .clk(client_clk), .rst(rst), .ready(ready), .busy(busy), .rd(rd),
            .req(req), .we(we), .addr(addr), .wd(wd), .done(done), .passed(passed),
            .fail_addr(fail_addr), .expected(expected), .actual(actual)
        );
    end endgenerate
    // Clock measurement against the 27 MHz crystal: count /128 toggle edges
    // over 32768 input cycles. Frequency in MHz = edge_count * 27 / 256.
    reg [7:0] mdiv = 0, tdiv = 0;
    always @(posedge mclk) mdiv <= mdiv + 1'b1;
    always @(posedge tclk) tdiv <= tdiv + 1'b1;
    reg [2:0] ms = 0, ts = 0;
    reg [15:0] window = 0;
    reg window_prev = 0;
    reg [12:0] mc = 0, tc = 0, measured_m = 0, measured_t = 0;
    always @(posedge clk27) begin
        ms <= {ms[1:0], mdiv[7]}; ts <= {ts[1:0], tdiv[7]};
        window <= window + 1'b1;
        window_prev <= window[15];
        if (window[15] != window_prev) begin
            measured_m <= mc; measured_t <= tc; mc <= 0; tc <= 0;
        end else begin
            if (ms[2] != ms[1]) mc <= mc + 1'b1;
            if (ts[2] != ts[1]) tc <= tc + 1'b1;
        end
    end
    uart_rx #(.DIV(234)) rx (.clk(clk27), .rx(uart_rx), .valid(u_v), .data(u_d));
    reg [3:0] left;
    reg word_reply;
    always @(posedge clk27) begin
        if (rst) begin left <= 0; word_reply <= 0; end
        else if (u_v && u_d == "D") begin left <= 9; word_reply <= 0; end
        else if (u_v && u_d == "W") begin left <= 7; word_reply <= 1; end
        else if (left != 0) left <= left - 1'b1;
    end
    reg [7:0] tx_d;
    always @(*) if (word_reply) case (left)
        7: tx_d = "W";
        6: tx_d = debug_word[15:8];
        5: tx_d = debug_word[7:0];
        4: tx_d = {3'b0, measured_m[12:8]};
        3: tx_d = measured_m[7:0];
        2: tx_d = {3'b0, measured_t[12:8]};
        default: tx_d = measured_t[7:0];
    endcase else case (left)
        9: tx_d = "D";
        8: tx_d = {done, passed, we, busy, ready, hang, req, 1'b0};
        7: tx_d = state;
        6: tx_d = {2'b0, addr[21:16]};
        5: tx_d = addr[15:8];
        4: tx_d = addr[7:0];
        3: tx_d = expected;
        2: tx_d = actual;
        default: tx_d = cycles;
    endcase
    uart_tx #(.DIV(234)) tx (.clk(clk27), .rst(rst), .we(left != 0), .wd(tx_d), .tx(uart_tx));
endmodule
