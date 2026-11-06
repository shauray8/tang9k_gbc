// Behavioral test: rtl/line_capture.v -> rtl/uart_tx.v (real FIFO backpressure, plus a randomly
// withheld grant standing in for other replies) -> rtl/uart_rx.v decoder. A PPU model emits
// 160 sequential pixels per visible line with frame-dependent 2-bit shades and RGB555 colors.
// Both reply formats are checked byte-exactly: legacy 'V' (2-bit packed) and 'W' (RGB555 LE).
`timescale 1ns/1ns
module tb;
    localparam DIV = 16;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg req = 0, color_mode = 0;
    reg [7:0] line = 0;
    reg running = 1, lcd_on = 1, gen_on = 1, rand_grant = 0, stall = 0, glitch = 0;
    reg [7:0] glitch_y = 0, glitch_frame = 0;
    reg grant = 1;
    wire busy, cap_we, u_ready, tx, rx_v;
    wire [7:0] cap_d, rx_d;
    integer errors = 0;

    // Pixel color of the model: pixel 1 is all ones and pixel 2 all zeros (every RGB bit is seen
    // both ways on every line); the others are distinct per x and per frame (mod 4), so swapped,
    // dropped, shifted or mixed-frame pixels and wrong byte order all mismatch.
    function [14:0] model_rgb(input [7:0] x, input [7:0] yy, input [1:0] f);
        reg [15:0] v;
        begin
            v = x * 16'd331 + yy * 16'd97 + f * 16'd5003;
            model_rgb = x == 8'd1 ? 15'h7fff : x == 8'd2 ? 15'h0000 : v[14:0];
        end
    endfunction

    // ---- PPU model: 400 clk per line, 154 lines, pixel every 2 clk from dot 20 ----
    reg pix_we = 0;
    reg [1:0] pix = 0;
    reg [14:0] pix_rgb = 0;
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
            pix_rgb <= model_rgb(xd[7:0], ly, frame[1:0]);
            if (glitch && ly == glitch_y && xd == 0) glitch_frame <= frame;
        end
    end

    line_capture dut (
        .clk(clk), .rst(rst), .req(req), .line(line), .color_mode(color_mode),
        .running(running), .lcd_on(lcd_on),
        .pix_we(pix_we), .pix(pix), .pix_rgb(pix_rgb), .pix_x(pix_x), .pix_y(ly),
        .tx_ready(u_ready && grant), .tx_we(cap_we), .tx_d(cap_d), .busy(busy)
    );
    uart_tx #(.DIV(DIV)) utx (.clk(clk), .rst(rst), .we(cap_we), .wd(cap_d), .ready(u_ready), .tx(tx));
    uart_rx #(.DIV(DIV)) urx (.clk(clk), .rx(tx), .valid(rx_v), .data(rx_d));

    always @(posedge clk) begin
        if (stall) grant <= 0;
        else if (rand_grant) grant <= $random;
        else grant <= 1;
        if (cap_we && !u_ready) begin
            $display("FAIL: byte pushed into a full FIFO"); errors = errors + 1;
        end
    end

    reg [7:0] rx_buf [0:511];
    integer rx_n = 0;
    always @(posedge clk) if (rx_v) begin
        if (rx_n < 512) rx_buf[rx_n] <= rx_d;
        rx_n <= rx_n + 1;
    end

    // mode 1 = 'W' request, 0 = 'V'. color_mode is flipped right after req to prove it is latched.
    task request(input mode, input [7:0] y, input integer want, input integer max_clk);
        integer t;
        begin
            rx_n = 0;
            @(posedge clk) begin req <= 1; line <= y; color_mode <= mode; end
            @(posedge clk) begin req <= 0; color_mode <= !mode; end
            t = 0;
            while ((busy || rx_n < want) && t < max_clk) begin @(posedge clk); t = t + 1; end
            repeat (40 * DIV) @(posedge clk);      // any extra byte would arrive by now
            if (busy) begin
                $display("FAIL: line %0d: still busy after %0d clk", y, max_clk); errors = errors + 1;
            end
            if (rx_n != want) begin
                $display("FAIL: %s line %0d: got %0d bytes, want %0d", mode ? "W" : "V", y, rx_n, want);
                errors = errors + 1;
            end
        end
    endtask

    task expect_error(input mode, input [7:0] y, input [7:0] code, input integer max_clk);
        begin
            request(mode, y, 2, max_clk);
            if (rx_buf[0] != "v" || rx_buf[1] != code) begin
                $display("FAIL: %s line %0d: reply %02x %02x, want 'v' %0d", mode ? "W" : "V", y,
                         rx_buf[0], rx_buf[1], code);
                errors = errors + 1;
            end
        end
    endtask

    // Legacy reply: returns the frame (mod 4) the line came from, or -1 if not one consistent frame.
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

    // Color reply: 'W' <y> <160 x 16-bit little-endian RGB555, bit 15 clear> <sum8 of 320 bytes>.
    // Returns the frame (mod 4) every pixel matches exactly, or -1.
    function integer check_color(input [7:0] y);
        integer i, f, ok, sum;
        reg [15:0] v;
        begin
            check_color = -1;
            sum = 0;
            for (i = 0; i < 320; i = i + 1) sum = sum + rx_buf[2 + i];
            if (rx_buf[0] == "W" && rx_buf[1] == y && rx_buf[322] == sum[7:0])
                for (f = 0; f < 4; f = f + 1) begin
                    ok = 1;
                    for (i = 0; i < 160; i = i + 1) begin
                        v = {rx_buf[3 + 2 * i], rx_buf[2 + 2 * i]};
                        if (v != {1'b0, model_rgb(i[7:0], y, f[1:0])}) ok = 0;
                    end
                    if (ok) check_color = f;
                end
        end
    endfunction

    task color_line(input [7:0] y, input integer max_clk);
        begin
            request(1, y, 323, max_clk);
            if (check_color(y) < 0) begin
                $display("FAIL: W line %0d data/sum/framing (%02x %02x ... sum %02x)", y,
                         rx_buf[0], rx_buf[1], rx_buf[322]);
                errors = errors + 1;
            end
        end
    endtask

    task legacy_line(input [7:0] y, input integer max_clk);
        begin
            request(0, y, 43, max_clk);
            if (check_line(y) < 0) begin $display("FAIL: V line %0d data/sum/framing", y); errors = errors + 1; end
        end
    endtask

    integer y, f, m;
    initial begin
        repeat (5) @(posedge clk);
        rst <= 0;

        // ---------------- legacy 'V' protocol (unchanged) ----------------
        // Data replies for edge and middle lines under FIFO + random grant backpressure.
        rand_grant = 1;
        for (y = 0; y < 144; y = y + 71) legacy_line(y, 200000);
        legacy_line(143, 200000);

        // A request while busy is ignored (exactly one 43-byte reply).
        rx_n = 0;
        @(posedge clk) begin req <= 1; line <= 10; color_mode <= 0; end
        @(posedge clk) begin req <= 1; line <= 11; color_mode <= 1; end
        @(posedge clk) req <= 0;
        while (busy) @(posedge clk);
        repeat (60 * 10 * DIV) @(posedge clk);
        if (rx_n != 43 || check_line(10) < 0) begin
            $display("FAIL: overlapping V request: %0d bytes", rx_n); errors = errors + 1;
        end

        // ---------------- color 'W' protocol ----------------
        // Edge and middle lines, every RGB bit, LE packing, sum8, under FIFO + random grant.
        color_line(0, 300000);
        color_line(1, 300000);
        color_line(37, 300000);
        color_line(71, 300000);
        color_line(142, 300000);
        color_line(143, 300000);

        // A request while busy is ignored (exactly one 323-byte reply for the first request).
        rx_n = 0;
        @(posedge clk) begin req <= 1; line <= 20; color_mode <= 1; end
        @(posedge clk) begin req <= 1; line <= 21; color_mode <= 0; end
        @(posedge clk) req <= 0;
        while (busy) @(posedge clk);
        repeat (60 * 10 * DIV) @(posedge clk);
        if (rx_n != 323 || check_color(20) < 0) begin
            $display("FAIL: overlapping W request: %0d bytes", rx_n); errors = errors + 1;
        end
        rand_grant = 0;

        // Sink stalled mid-reply for longer than the 2^21-clk capture timeout, while the PPU keeps
        // redrawing the line with other frames: the reply resumes intact (no timeout, no counter
        // wrap, no buffer overwrite, no dropped or repeated byte).
        fork
            color_line(50, 3000000);
            begin
                @(posedge clk);
                wait (rx_n == 150);
                stall = 1;
                repeat (2200000) @(posedge clk);
                stall = 0;
            end
        join

        // Back to legacy after color: format switches per request.
        legacy_line(77, 200000);

        // ---------------- retry of a broken line (both formats) ----------------
        // A broken line (missing pixel) is retried on the next frame, never sent half-filled.
        for (m = 0; m < 2; m = m + 1) begin
            wait (ly == 60 && dot == 0);
            glitch_y = 100; glitch = 1;
            request(m, 100, m ? 323 : 43, 300000);
            f = m ? check_color(100) : check_line(100);
            if (f < 0 || f == glitch_frame[1:0]) begin
                $display("FAIL: %s glitched line not recaptured from a later frame (got %0d, glitch frame %0d)",
                         m ? "W" : "V", f, glitch_frame[1:0]);
                errors = errors + 1;
            end
        end

        // ---------------- errors (both formats reply 'v' <code>) ----------------
        for (m = 0; m < 2; m = m + 1) begin
            expect_error(m, 144, 4, 1000);
            expect_error(m, 255, 4, 1000);
            running = 0; expect_error(m, 5, 1, 1000); running = 1;
            lcd_on = 0;  expect_error(m, 5, 2, 1000); lcd_on = 1;
            // LCD switched off while waiting for the line.
            wait (ly == 10 && dot == 0);
            fork
                expect_error(m, 120, 2, 100000);
                begin repeat (1000) @(posedge clk); lcd_on = 0; end
            join
            lcd_on = 1;
            // LCD switched off in the middle of capturing the requested line.
            wait (ly == 10 && dot == 0);
            fork
                expect_error(m, 120, 2, 100000);
                begin wait (ly == 120 && pix_we && pix_x == 80); lcd_on = 0; end
            join
            lcd_on = 1;
            // Core put in reset in the middle of capturing the requested line.
            wait (ly == 10 && dot == 0);
            fork
                expect_error(m, 121, 1, 100000);
                begin wait (ly == 121 && pix_we && pix_x == 100); running = 0; end
            join
            running = 1;
            // No pixels at all: bounded wait, then a timeout error.
            gen_on = 0; expect_error(m, 20, 3, 2200000); gen_on = 1;
            // Recovers to normal data replies after errors.
            if (m) color_line(30, 300000);
            else legacy_line(30, 200000);
        end

        if (errors == 0) $display("RESULT PASS");
        else $display("RESULT FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
