// Behavioral test: rtl/line_capture.v -> rtl/uart_tx.v (real FIFO backpressure, plus a randomly
// withheld grant standing in for other replies) -> rtl/uart_rx.v decoder. A PPU model emits
// 160 sequential pixels per visible line with frame-dependent shades.
`timescale 1ns/1ns
module tb;
    localparam DIV = 16;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg req = 0;
    reg [7:0] line = 0;
    reg running = 1, lcd_on = 1, gen_on = 1, rand_grant = 0, glitch = 0;
    reg [7:0] glitch_y = 0, glitch_frame = 0;
    reg grant = 1;
    wire busy, cap_we, u_ready, tx, rx_v;
    wire [7:0] cap_d, rx_d;
    integer errors = 0;

    // ---- PPU model: 400 clk per line, 154 lines, pixel every 2 clk from dot 20 ----
    reg pix_we = 0;
    reg [1:0] pix = 0;
    reg [7:0] pix_x = 0, ly = 0, frame = 0;
    reg [8:0] dot = 0;
    wire [8:0] xd = (dot - 9'd20) >> 1;
    always @(posedge clk) begin
        pix_we <= 0;
        dot <= dot == 399 ? 9'd0 : dot + 1;
        if (dot == 399) begin
            ly <= ly == 153 ? 8'd0 : ly + 1;
            if (ly == 153) frame <= frame + 1;
            if (glitch && ly == glitch_y) glitch <= 0;
        end
        if (gen_on && ly < 144 && dot >= 20 && dot < 340 && !dot[0]
            && !(glitch && ly == glitch_y && xd == 77)) begin
            pix_we <= 1; pix_x <= xd[7:0]; pix <= xd[1:0] + ly[1:0] + frame[1:0];
            if (glitch && ly == glitch_y && xd == 0) glitch_frame <= frame;
        end
    end

    line_capture dut (
        .clk(clk), .rst(rst), .req(req), .line(line), .running(running), .lcd_on(lcd_on),
        .pix_we(pix_we), .pix(pix), .pix_x(pix_x), .pix_y(ly),
        .tx_ready(u_ready && grant), .tx_we(cap_we), .tx_d(cap_d), .busy(busy)
    );
    uart_tx #(.DIV(DIV)) utx (.clk(clk), .rst(rst), .we(cap_we), .wd(cap_d), .ready(u_ready), .tx(tx));
    uart_rx #(.DIV(DIV)) urx (.clk(clk), .rx(tx), .valid(rx_v), .data(rx_d));

    always @(posedge clk) begin
        if (rand_grant) grant <= $random;
        else grant <= 1;
        if (cap_we && !u_ready) begin
            $display("FAIL: byte pushed into a full FIFO"); errors = errors + 1;
        end
    end

    reg [7:0] rx_buf [0:63];
    integer rx_n = 0;
    always @(posedge clk) if (rx_v) begin
        if (rx_n < 64) rx_buf[rx_n] <= rx_d;
        rx_n <= rx_n + 1;
    end

    task request(input [7:0] y, input integer want, input integer max_clk);
        integer t;
        begin
            rx_n = 0;
            @(posedge clk) begin req <= 1; line <= y; end
            @(posedge clk) req <= 0;
            t = 0;
            while ((busy || rx_n < want) && t < max_clk) begin @(posedge clk); t = t + 1; end
            repeat (40 * DIV) @(posedge clk);      // any extra byte would arrive by now
            if (rx_n != want) begin
                $display("FAIL: line %0d: got %0d bytes, want %0d", y, rx_n, want); errors = errors + 1;
            end
        end
    endtask

    task expect_error(input [7:0] y, input [7:0] code, input integer max_clk);
        begin
            request(y, 2, max_clk);
            if (rx_buf[0] != "v" || rx_buf[1] != code) begin
                $display("FAIL: line %0d: reply %02x %02x, want 'v' %0d", y, rx_buf[0], rx_buf[1], code);
                errors = errors + 1;
            end
        end
    endtask

    // Returns the frame (mod 4) the line came from, or -1 if not one consistent frame.
    function integer check_line(input [7:0] y);
        integer i, f, ok, sum;
        reg [1:0] p;
        begin
            check_line = -1;
            sum = 0;
            for (i = 0; i < 40; i = i + 1) sum = sum + rx_buf[2 + i];
            if (rx_buf[0] == "V" && rx_buf[1] == y && rx_buf[42] == sum[7:0])
                for (f = 0; f < 4; f = f + 1) begin
                    ok = 1;
                    for (i = 0; i < 160; i = i + 1) begin
                        p = rx_buf[2 + i / 4] >> (6 - 2 * (i % 4));
                        if (p != ((i + y + f) & 3)) ok = 0;
                    end
                    if (ok) check_line = f;
                end
        end
    endfunction

    integer y, f;
    initial begin
        repeat (5) @(posedge clk);
        rst <= 0;

        // Data replies for edge and middle lines under FIFO + random grant backpressure.
        rand_grant = 1;
        for (y = 0; y < 144; y = y + 71) begin
            request(y, 43, 200000);
            if (check_line(y) < 0) begin $display("FAIL: line %0d data/sum/framing", y); errors = errors + 1; end
        end
        request(143, 43, 200000);
        if (check_line(143) < 0) begin $display("FAIL: line 143 data/sum/framing"); errors = errors + 1; end

        // A request while busy is ignored (exactly one 43-byte reply).
        rx_n = 0;
        @(posedge clk) begin req <= 1; line <= 10; end
        @(posedge clk) begin req <= 1; line <= 11; end
        @(posedge clk) req <= 0;
        while (busy) @(posedge clk);
        repeat (60 * 10 * DIV) @(posedge clk);
        if (rx_n != 43 || check_line(10) < 0) begin
            $display("FAIL: overlapping request: %0d bytes", rx_n); errors = errors + 1;
        end
        rand_grant = 0;

        // A broken line (missing pixel) is retried on the next frame, never sent half-filled.
        wait (ly == 60 && dot == 0);
        glitch_y = 100; glitch = 1;
        request(100, 43, 200000);
        f = check_line(100);
        if (f < 0 || f == glitch_frame[1:0]) begin
            $display("FAIL: glitched line not recaptured from a later frame (got %0d, glitch frame %0d)",
                     f, glitch_frame[1:0]);
            errors = errors + 1;
        end

        expect_error(144, 4, 1000);
        running = 0; expect_error(5, 1, 1000); running = 1;
        lcd_on = 0;  expect_error(5, 2, 1000); lcd_on = 1;
        // LCD switched off while waiting for the line.
        wait (ly == 10 && dot == 0);
        fork
            expect_error(120, 2, 100000);
            begin repeat (1000) @(posedge clk); lcd_on = 0; end
        join
        lcd_on = 1;
        // No pixels at all: bounded wait, then a timeout error.
        gen_on = 0; expect_error(20, 3, 2200000); gen_on = 1;

        if (errors == 0) $display("RESULT PASS");
        else $display("RESULT FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
