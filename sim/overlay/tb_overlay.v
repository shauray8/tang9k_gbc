// Overlay bench: controller contract checks, then a rendered panel written as a PPM.
//   sim/overlay/run.sh   (writes build/overlay.ppm, 160x144 GB pixels)
`timescale 1ns/1ps
module tb;
    reg clk = 0;
    always #5 clk = ~clk;

    // ---------------- controller ----------------
    reg rst = 1, enable = 1, open = 0, close_all = 0, cart_cgb = 0, boot_active = 0, boot_run = 1;
    reg boot_en = 1, ev_take = 0;
    reg [7:0] pad = 0;
    wire on, core_reset, boot_toggle, ev_valid;
    wire [2:0] sel; wire [4:0] pal; wire [7:0] core_pad, ev_code;
    overlay_ctl dut (
        .clk(clk), .rst(rst), .enable(enable), .open(open), .close_all(close_all), .pad(pad),
        .cart_cgb(cart_cgb), .boot_active(boot_active), .boot_run(boot_run), .boot_en(boot_en),
        .on(on), .sel(sel), .pal(pal), .core_reset(core_reset), .boot_toggle(boot_toggle),
        .core_pad(core_pad), .ev_valid(ev_valid), .ev_code(ev_code), .ev_take(ev_take)
    );
    localparam RIGHT = 8'h01, LEFT = 8'h02, UP = 8'h04, DOWN = 8'h08, A = 8'h10, B = 8'h20, START = 8'h80;
    task press(input [7:0] b);
        begin
            @(negedge clk) pad = b;
            @(negedge clk) pad = 0;
            @(negedge clk);
        end
    endtask
    task expect_event(input [7:0] code);
        begin
            if (!ev_valid || ev_code !== code) $fatal(1, "expected event %0d, got valid=%b code=%0d", code, ev_valid, ev_code);
            @(negedge clk) ev_take = 1;
            @(negedge clk) ev_take = 0;
            if (ev_valid) $fatal(1, "event not taken");
        end
    endtask
    task pulse_open;
        begin @(negedge clk) open = 1; @(negedge clk) open = 0; end
    endtask
    integer p, captured_reset;
    reg [7:0] want;
    always @(posedge clk) if (core_reset) captured_reset = captured_reset + 1;

    // ---------------- renderer ----------------
    reg [7:0] gx = 0, gy = 0;
    reg r_on = 1, r_boot = 0;
    reg [2:0] r_sel = 3'd2;
    reg [4:0] r_pal = 5'd12;
    wire [1:0] px;
    overlay_render draw (.clk(clk), .gx(gx), .gy(gy), .on(r_on), .sel(r_sel), .boot(r_boot),
                         .pal(r_pal), .px(px));
    integer f, x, y;

    initial begin
        captured_reset = 0;
        repeat (2) @(negedge clk);
        rst = 0;
        // Opens only while enabled; the game sees no buttons while it is open.
        enable = 0; pulse_open; if (on) $fatal(1, "opened without a running game");
        enable = 1; pulse_open; if (!on || sel != 0) $fatal(1, "did not open on RESUME");
        pad = UP; @(negedge clk); if (core_pad !== 0) $fatal(1, "buttons leak to the game"); pad = 0;
        repeat (2) @(negedge clk);
        // That press moved the selection up from RESUME: it wraps to COLOUR.
        if (!on || sel != 5) $fatal(1, "up from RESUME should wrap to COLOUR, on=%b sel=%0d", on, sel);
        press(DOWN); if (sel != 0) $fatal(1, "down from COLOUR should wrap to RESUME");
        // SAVE: event 1, overlay closes.
        press(DOWN); press(A); expect_event(8'd1); if (on) $fatal(1, "SAVE should close");
        // LIBRARY: event 2, closes (no waiting on the host).
        pulse_open; press(DOWN); press(DOWN); press(START); expect_event(8'd2);
        if (on) $fatal(1, "LIBRARY should close");
        // A (re)load closes an open overlay and drops an unanswered request.
        pulse_open; press(DOWN); press(A); if (!ev_valid) $fatal(1, "no SAVE request");
        pulse_open; close_all = 1; @(negedge clk) close_all = 0;
        if (on || ev_valid) $fatal(1, "reload must close it and clear the request: on=%b ev=%b", on, ev_valid);
        // RESET: one pulse, closes, event 3.
        pulse_open; press(UP); press(UP); press(UP); if (sel != 3) $fatal(1, "sel %0d, want RESET", sel);
        press(A); expect_event(8'd3);
        if (captured_reset != 1 || on) $fatal(1, "RESET: %0d pulses, on=%b", captured_reset, on);
        // BOOT LOGO: toggle event reports the new preference.
        pulse_open; press(UP); press(UP); if (sel != 4) $fatal(1, "sel %0d, want LOGO", sel);
        press(A); expect_event(8'd4);            // was on -> now off
        boot_en = 0; press(RIGHT); expect_event(8'd5);
        // B resumes.
        press(B); if (on) $fatal(1, "B should resume");
        // COLOUR: right/left cycle AUTO, 1..16; left from AUTO wraps to 16.
        pulse_open; press(UP); press(LEFT); if (pal != 16) $fatal(1, "left from AUTO: %0d", pal);
        press(RIGHT); if (pal != 0) $fatal(1, "right from 16: %0d", pal);
        press(B);
        // Key combination during the boot ROM: SameBoy index = direction + 4*A + 8*B.
        boot_active = 1;
        for (p = 1; p <= 16; p = p + 1) begin
            pulse_open; press(UP); while (pal != p) press(RIGHT); press(B);
            want = (8'd1 << ((p - 1) % 4)) | (((p - 1) & 4) ? A : 8'd0) | (((p - 1) & 8) ? B : 8'd0);
            #1 if (core_pad !== want) $fatal(1, "palette %0d: pad %b want %b", p, core_pad, want);
        end
        cart_cgb = 1; #1 if (core_pad !== 0) $fatal(1, "a CGB cart must never get a combination");
        cart_cgb = 0; boot_run = 0; #1 if (core_pad !== 0) $fatal(1, "no combination without the boot ROM");
        boot_run = 1; boot_active = 0; pad = RIGHT; #1 if (core_pad !== RIGHT) $fatal(1, "pad after boot");
        pad = 0;
        $display("overlay_ctl: PASS");

        // Render: one GB pixel per clock, px arrives four clocks later.
        f = $fopen("build/overlay.ppm", "w");
        $fwrite(f, "P6 160 144 255\n");
        for (y = 0; y < 144; y = y + 1)
            for (x = 0; x <= 163; x = x + 1) begin
                @(negedge clk);
                if (x > 3)
                    case (px)
                        2'd0: $fwrite(f, "%c%c%c", 8'h88, 8'hC0, 8'h70);
                        2'd1: $fwrite(f, "%c%c%c", 8'h18, 8'h28, 8'h48);
                        2'd2: $fwrite(f, "%c%c%c", 8'hF8, 8'hF8, 8'hF8);
                        default: $fwrite(f, "%c%c%c", 8'hF8, 8'hE0, 8'h30);
                    endcase
                gx = x; gy = y;
            end
        $fclose(f);
        $display("overlay_render: wrote build/overlay.ppm");
        $finish;
    end
endmodule
