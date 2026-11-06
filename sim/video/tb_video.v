`timescale 1ps/1ps
// Check observable raster pixels, timing and the synchronized scanout fingerprint under independent clocks.
module tb;
    reg clk_sys = 0, clk_pix = 0;
    always #6734 clk_pix = ~clk_pix;
    integer phase = 0;
    initial begin
        if ($value$plusargs("phase=%d", phase)) begin end
        #(phase);
        forever begin #18518 clk_sys = 1; #18519 clk_sys = 0; end
    end
    reg rst_sys = 1, rst_pix = 1, run = 0, lcd = 1, cgb = 1;
    reg pix_we = 0, gb_vsync = 0;
    reg [7:0] px = 0, py = 0;
    reg [1:0] shade = 0;
    reg [14:0] color = 0;
    wire tick, locked, waitlock, de, hs, vs;
    wire [7:0] r, g, b, scan_frame;
    wire [15:0] scan_sig;
    video_buffer dut (
        .clk_sys(clk_sys), .rst_sys(rst_sys), .run(run), .lcd_on(lcd), .gb_vsync(gb_vsync),
        .cgb_mode(cgb), .pix_we(pix_we), .pix_x(px), .pix_y(py), .pix(shade), .pix_rgb(color),
        .tick(tick), .locked(locked), .waitlock(waitlock), .clk_pix(clk_pix), .rst_pix(rst_pix),
        .r(r), .g(g), .b(b), .de(de), .hs(hs), .vs(vs), .scanout_sig(scan_sig), .scanout_frame(scan_frame)
    );
    function [14:0] pattern(input integer f, y, x);
        pattern = f * 3001 + y * 160 + x;
    endfunction
    function [23:0] rgb555(input [14:0] p);
        rgb555 = {p[4:0],p[4:2],p[9:5],p[9:7],p[14:10],p[14:12]};
    endfunction
    function [23:0] dmg(input [1:0] p);
        case (p)
            0: dmg = 24'he0f8d0; 1: dmg = 24'h88c070;
            2: dmg = 24'h346856; 3: dmg = 24'h081820;
        endcase
    endfunction

    // Independent PPU model: earliest, latest, and alternating legal line schedules.
    integer dot = 0, line_no = 0, next_x = 0, frame_id = 0, timing_mode = 0;
    integer start_dot, system_ticks = 0;
    reg was_running = 0, was_lcd = 1, skip_line_zero = 0;
    always @(posedge clk_sys) begin
        pix_we <= 0; gb_vsync <= 0;
        if (!run) begin
            dot = 0; line_no = 0; next_x = 0; was_running = 0; skip_line_zero = 0;
        end else begin
            if (!was_running) begin frame_id = frame_id + 1; was_running = 1; end
            if (!was_lcd && lcd) begin
                frame_id = frame_id + 1; dot = 0; line_no = 0; next_x = 0; skip_line_zero = 1;
            end
            if (tick) begin
                system_ticks = system_ticks + 1;
                if (!lcd) begin dot = 0; line_no = 0; next_x = 0; end
                else begin
                    start_dot = timing_mode == 0 ? 80 : timing_mode == 1 ? 296 : (line_no[0] ? 296 : 80);
                    if (line_no < 144 && !(skip_line_zero && line_no == 0) && next_x < 160 && dot == start_dot + next_x) begin
                        pix_we <= 1; px <= next_x; py <= line_no;
                        color <= pattern(frame_id, line_no, next_x);
                        shade <= frame_id + line_no + next_x;
                        next_x = next_x + 1;
                    end
                    if (dot == 455) begin
                        dot = 0; next_x = 0;
                        if (line_no == 153) begin
                            line_no = 0; frame_id = frame_id + 1; gb_vsync <= 1; skip_line_zero = 0;
                        end else line_no = line_no + 1;
                    end else dot = dot + 1;
                end
            end
        end
        was_lcd = lcd;
    end

    integer h = 0, v = 0, qh = 0, qv = 0, eh, ev;
    integer frames = 0, checked_frames = 0, frame_pixels = 0, expected_fid = 0;
    reg qvalid = 0, valid_now, check_pixels = 0, check_frame = 0, frame_cgb;
    reg [23:0] expected_rgb;
    reg [15:0] work_sig = 0, expected_sig = 0;
    always @(posedge clk_pix) begin
        if (rst_pix) begin
            h = 0; v = 0; qvalid = 0; work_sig = 0; check_frame = 0;
        end else begin
            eh = qh; ev = qv; valid_now = qvalid;
            qh = h; qv = v; qvalid = 1;
            if (h == 1649) begin h = 0; v = v == 749 ? 0 : v + 1; end else h = h + 1;
            #1;
            if (valid_now) begin
                if (eh == 0 && ev == 0) begin
                    expected_fid = frame_id; frame_cgb = cgb; frame_pixels = 0;
                    check_frame = check_pixels;
                    if (check_frame && locked !== 1'b1) $fatal(1, "lost frame lock before a checked frame");
                end
                if (de !== (eh < 1280 && ev < 720) || hs !== (eh >= 1390 && eh < 1430) ||
                    vs !== ((ev*1650+eh) >= 724*1650+1390 && (ev*1650+eh) < 729*1650+1390))
                    $fatal(1, "720p timing mismatch at %0d,%0d: de=%b hs=%b vs=%b", eh, ev, de, hs, vs);
                if (de && (eh < 240 || eh >= 1040) && {r,g,b} !== 24'd0)
                    $fatal(1, "non-black border at %0d,%0d", eh, ev);
                if (de && eh >= 240 && eh < 1040) begin
                    work_sig = {work_sig[14:0],work_sig[15]} ^ {1'b0,b[7:3],g[7:3],r[7:3]};
                    if (check_frame) begin
                        expected_rgb = frame_cgb ? rgb555(pattern(expected_fid, ev/5, (eh-240)/5)) : dmg((expected_fid+ev/5+(eh-240)/5) & 3);
                        if ({r,g,b} !== expected_rgb)
                            $fatal(1, "RGB/lifetime mismatch frame %0d pixel %0d,%0d: got %h expected %h", expected_fid, eh, ev, {r,g,b}, expected_rgb);
                        if (!locked) $fatal(1, "lost lock during a checked frame");
                        frame_pixels = frame_pixels + 1;
                    end
                end
                if (eh == 1649 && ev == 749) begin
                    expected_sig = work_sig; work_sig = 0; frames = frames + 1;
                    if (check_frame) begin
                        if (frame_pixels != 576000) $fatal(1, "incomplete checked frame: %0d", frame_pixels);
                        checked_frames = checked_frames + 1;
                    end
                end
            end
        end
    end
    reg [7:0] previous_scan_frame = 0;
    always @(negedge clk_sys) begin
        if (rst_sys) previous_scan_frame = 0;
        else if (scan_frame != previous_scan_frame) begin
            if (check_pixels && scan_sig !== expected_sig)
                $fatal(1, "scanout snapshot/CDC mismatch: %h expected %h", scan_sig, expected_sig);
            previous_scan_frame = scan_frame;
        end
    end
    task wait_frames(input integer count);
        integer goal;
        begin goal = frames + count; while (frames < goal) @(negedge clk_pix); end
    endtask
    task verify_scene(input integer schedule, input use_color);
        integer before_checked;
        begin
            check_pixels = 0;
            @(negedge clk_sys); run = 0; timing_mode = schedule; cgb = use_color;
            repeat (32) @(negedge clk_sys);
            run = 1;
            wait (locked === 1'b1);
            wait_frames(2);
            check_pixels = 1; before_checked = checked_frames;
            wait_frames(3);
            check_pixels = 0;
            if (checked_frames < before_checked + 2) $fatal(1, "scene did not produce checked frames");
            $display("video scene PASS: schedule=%0d CGB=%0d", schedule, use_color);
        end
    endtask
    integer ticks_before;
    initial begin
        repeat (32) @(negedge clk_sys);
        rst_sys = 0;
        @(negedge clk_pix); rst_pix = 0;
        verify_scene(0,1);
        verify_scene(1,1);
        verify_scene(2,1);
        @(negedge clk_sys); lcd = 0;
        repeat (10) @(negedge clk_sys);
        if (locked) $fatal(1, "LCD-off did not clear frame lock");
        ticks_before = system_ticks;
        repeat (45000) @(negedge clk_sys);
        if (system_ticks - ticks_before < 7021 || system_ticks - ticks_before > 7024)
            $fatal(1, "CPU clock stopped or changed rate while LCD was off");
        lcd = 1;
        wait (locked === 1'b1);
        wait_frames(2);
        check_pixels = 1; wait_frames(3); check_pixels = 0;
        $display("video LCD-only restart PASS");
        verify_scene(2,0);
        repeat (23177) @(negedge clk_pix);
        rst_pix = 1;
        repeat (16) @(negedge clk_pix);
        rst_pix = 0;
        wait_frames(3);
        wait (locked === 1'b1);
        check_pixels = 1; wait_frames(3); check_pixels = 0;
        $display("video-only restart PASS");
        verify_scene(1,1);
        if (checked_frames < 10) $fatal(1, "insufficient complete output frames");
        $display("VIDEO PASS: phase=%0d, %0d complete frames checked, RGB/raster/CDC valid", phase, checked_frames);
        $finish;
    end
    initial begin #1200000000000; $fatal(1, "video acquisition timeout"); end
endmodule
