// Behavioral test of rtl/ppu.v colour features, driven only through the CPU bus and checked on the
// pixel outputs:
//  1. CGB colour RAM registers: power-up white BG colours, FF68-FF6B index/auto-increment (wrap,
//     reads never increment, blocked mode-3 writes still increment, mode-3 reads FF), FF6C, and
//     DMG-mode gating (all of FF68-FF6C read FF, writes ignored).
//  2. Rendering: random scenes (both VRAM banks, BG/window attributes, OAM incl. >10 objects per
//     line, 8x8/8x16, random LCDC/scroll/window, random RGB555 colours with bit 15 set at random)
//     rendered in CGB and DMG mode, with a fractional GB tick (70224 dots per 450000 clk) and with a
//     dot on every clk. Every pixel of a full frame is compared against a straightforward per-pixel
//     reference model written from Pan Docs (OAM-order vs X object priority, BG attribute/OAM/LCDC.0
//     priority); every line must deliver exactly 160 pixels in x order on its own LY.
`timescale 1ns/1ns
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, cgb = 1, cont = 1;
    integer errors = 0;

    // ---- clock enables (same scheme as gb.v) ----
    reg ce_t = 0;
    reg [1:0] tdiv = 0;
    integer acc = 0;
    always @(posedge clk) begin
        if (cont) ce_t <= 1;
        else begin
            acc = acc + 70224;
            if (acc >= 450000) begin acc = acc - 450000; ce_t <= 1; end else ce_t <= 0;
        end
        if (rst) tdiv <= 0; else if (ce_t) tdiv <= tdiv + 1;
    end
    wire ce = ce_t && tdiv == 2'd3;

    // ---- CPU bus ----
    reg [15:0] addr = 16'h0000;
    reg [7:0] din = 0;
    reg wr_req = 0;
    wire cpu_wr = wr_req && ce;
    wire vram_sel = addr[15:13] == 3'b100;
    wire oam_sel = addr[15:8] == 8'hFE && addr[7:0] < 8'hA0;
    wire reg_sel = (addr[15:4] == 12'hFF4 && (addr[3:0] <= 4'hB && addr[3:0] != 4'h6 || addr[3:0] == 4'hF)) ||
                   (addr >= 16'hFF68 && addr <= 16'hFF6C);
    wire [7:0] dout;
    wire pix_we, vsync, lcd_on;
    wire [1:0] pix;
    wire [14:0] pix_rgb;
    wire [7:0] pix_x, pix_y;

    ppu dut (
        .clk(clk), .rst(rst), .ce_t(ce_t), .ce(ce), .cgb_mode(cgb), .cgb_hw(cgb),
        .cgb_post_boot(1'b0), .dmg_color(1'b0), .boot(1'b0),
        .cpu_addr(addr), .cpu_wr(cpu_wr), .cpu_din(din), .cpu_dout(dout),
        .vram_sel(vram_sel), .vram_dma(1'b0), .oam_dma_vram(1'b0), .oam_dma_addr(13'd0), .oam_dma_vq(),
        .oam_sel(oam_sel), .reg_sel(reg_sel),
        .dma_act(1'b0), .dma_we(1'b0), .dma_idx(8'd0), .dma_data(8'd0),
        .irq_vblank(), .irq_stat(), .pix_we(pix_we), .pix(pix), .pix_rgb(pix_rgb),
        .pix_x(pix_x), .pix_y(pix_y), .vsync(vsync), .lcd_on(lcd_on)
    );

    // ---- mirrors of what the CPU wrote (reference model input) ----
    reg [7:0] tvram [0:16383];
    reg [7:0] toam [0:159];
    reg [7:0] tbc [0:63], toc [0:63];
    reg [7:0] t_lcdc, t_scx, t_scy, t_wx, t_wy, t_bgp, t_obp0, t_obp1;

    task wr(input [15:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; din = d; wr_req = 1;
            while (!ce) @(negedge clk);
            @(negedge clk); wr_req = 0;
        end
    endtask
    task rd(input [15:0] a, output [7:0] d);
        begin
            @(negedge clk); addr = a; #1 d = dout;
        end
    endtask
    task expect_rd(input [15:0] a, input [7:0] e, input [8*40-1:0] what);
        reg [7:0] d;
        begin
            rd(a, d);
            if (d !== e) begin
                errors = errors + 1;
                $display("FAIL %0s: read %04h = %02h, expected %02h", what, a, d, e);
            end
        end
    endtask
    task wait_mode(input [1:0] m);      // via STAT
        reg [7:0] d;
        begin
            d = 0;
            rd(16'hFF41, d);
            while (d[1:0] != m) rd(16'hFF41, d);
        end
    endtask
    task do_reset(input c);
        begin
            @(negedge clk); rst = 1; cgb = c; wr_req = 0;
            repeat (8) @(negedge clk);
            rst = 0;
        end
    endtask

    // ================= 1. colour RAM registers =================
    integer i;
    reg [7:0] d;
    task test_registers;
        begin
            do_reset(1);
            cont = 1;
            wr(16'hFF40, 8'h00);                                   // LCD off: colour RAM accessible
            expect_rd(16'hFF68, 8'h40, "BCPS reset (bit6 reads 1)");
            expect_rd(16'hFF6A, 8'h40, "OCPS reset");
            expect_rd(16'hFF6C, 8'hFE, "OPRI reset");
            // power-up BG colours are white ($7FFF); reads do not increment
            wr(16'hFF68, 8'h80);
            expect_rd(16'hFF69, 8'hFF, "BG colour 0 low = FF");
            expect_rd(16'hFF69, 8'hFF, "BG colour 0 low again");
            expect_rd(16'hFF68, 8'hC0, "BCPS unchanged by reads");
            for (i = 0; i < 64; i = i + 1) begin
                wr(16'hFF68, i[5:0]);
                expect_rd(16'hFF69, i[0] ? 8'h7F : 8'hFF, "BG power-up white");
            end
            // auto-increment fill and wrap 63 -> 0
            wr(16'hFF68, 8'h80);
            for (i = 0; i < 64; i = i + 1) wr(16'hFF69, i * 37 + 5);
            expect_rd(16'hFF68, 8'hC0, "BCPS wrapped to 0");
            wr(16'hFF6A, 8'hBE);                                   // OBJ: start at 3E, bit6 of write ignored
            expect_rd(16'hFF6A, 8'hFE, "OCPS write");
            for (i = 0; i < 64; i = i + 1) wr(16'hFF6B, 8'hFF - i * 11);
            expect_rd(16'hFF6A, 8'hFE, "OCPS wrapped back to 3E");
            for (i = 0; i < 64; i = i + 1) begin
                wr(16'hFF68, i[5:0]);
                expect_rd(16'hFF69, i * 37 + 5, "BG colour RAM readback");
                wr(16'hFF6A, i[5:0]);
                expect_rd(16'hFF6B, 8'hFF - ((i + 2) % 64) * 11, "OBJ colour RAM readback");
            end
            // no auto-increment: writes stay on the same byte
            wr(16'hFF68, 8'h05);
            wr(16'hFF69, 8'h99); wr(16'hFF69, 8'h9A);
            expect_rd(16'hFF68, 8'h45, "BCPS without auto-increment");
            expect_rd(16'hFF69, 8'h9A, "BG byte 5 last write");
            wr(16'hFF68, 8'h04);
            expect_rd(16'hFF69, 4 * 37 + 5, "BG byte 4 untouched");
            wr(16'hFF68, 8'h06);
            expect_rd(16'hFF69, 6 * 37 + 5, "BG byte 6 untouched");
            // FF6C stores bit 0
            wr(16'hFF6C, 8'h01); expect_rd(16'hFF6C, 8'hFF, "OPRI=1");
            wr(16'hFF6C, 8'hFE); expect_rd(16'hFF6C, 8'hFE, "OPRI=0");
            // mode 3: data reads FF, writes blocked but still increment; index registers stay accessible
            wr(16'hFF40, 8'h91);
            wait_mode(2'd3);
            wr(16'hFF68, 8'h90);
            wr(16'hFF6A, 8'h91);
            wr(16'hFF69, 8'h00);
            wr(16'hFF6B, 8'h00);
            expect_rd(16'hFF69, 8'hFF, "BCPD read in mode 3");
            expect_rd(16'hFF6B, 8'hFF, "OCPD read in mode 3");
            expect_rd(16'hFF68, 8'hD1, "BCPS incremented by blocked write");
            expect_rd(16'hFF6A, 8'hD2, "OCPS incremented by blocked write");
            rd(16'hFF41, d);
            if (d[1:0] != 2'd3) begin errors = errors + 1; $display("FAIL: mode-3 window missed"); end
            wait_mode(2'd0);
            wr(16'hFF68, 8'h10);
            expect_rd(16'hFF69, 16 * 37 + 5, "BG byte 10 kept after blocked write");
            wr(16'hFF6A, 8'h11);
            expect_rd(16'hFF6B, 8'hFF - 19 * 11, "OBJ byte 11 kept after blocked write");
            wr(16'hFF69, 8'h5A);                                  // mode 0: accepted
            expect_rd(16'hFF69, 8'h5A, "BG write accepted in mode 0");
            wr(16'hFF69, (16 * 37 + 5) & 8'hFF);
            // DMG mode: FF68-FF6C absent
            do_reset(0);
            wr(16'hFF40, 8'h00);
            wr(16'hFF68, 8'h80); wr(16'hFF69, 8'h12); wr(16'hFF6A, 8'h80); wr(16'hFF6B, 8'h34); wr(16'hFF6C, 8'h01);
            expect_rd(16'hFF68, 8'hFF, "DMG FF68"); expect_rd(16'hFF69, 8'hFF, "DMG FF69");
            expect_rd(16'hFF6A, 8'hFF, "DMG FF6A"); expect_rd(16'hFF6B, 8'hFF, "DMG FF6B");
            expect_rd(16'hFF6C, 8'hFF, "DMG FF6C");
            do_reset(1);                                           // the DMG writes must not have landed
            wr(16'hFF40, 8'h00);
            expect_rd(16'hFF68, 8'h40, "BCPS after DMG writes");
            expect_rd(16'hFF6C, 8'hFE, "OPRI after DMG writes");
            expect_rd(16'hFF69, 8'h05, "BG byte 0 after DMG writes");
            wr(16'hFF6A, 8'h00);
            expect_rd(16'hFF6B, 8'hFF - 2 * 11, "OBJ byte 0 after DMG writes");
        end
    endtask

    // ================= 2. rendering vs reference =================
    function automatic [16:0] ref_px(input integer x, input integer y);   // {shade, rgb}
        integer win, mx, my, ma, tile, attr, row, col, ta, bgc, h, n, k, oy, ox, oa, sr, st, sc, sa, c;
        integer best, bestx, bc, ba, obj, pl, shade, idx, rgb, g;
        begin
            win = t_lcdc[5] && y >= t_wy && t_wx <= 166 && x + 7 >= t_wx;
            if (win) begin mx = x + 7 - t_wx; my = y - t_wy; ma = t_lcdc[6] ? 16'h1C00 : 16'h1800; end
            else begin mx = (x + t_scx) & 255; my = (y + t_scy) & 255; ma = t_lcdc[3] ? 16'h1C00 : 16'h1800; end
            ma = ma + (my >> 3) * 32 + (mx >> 3);
            tile = tvram[ma];
            attr = cgb ? tvram[16'h2000 + ma] : 0;
            row = my & 7; if (attr & 8'h40) row = 7 - row;
            col = mx & 7; if (attr & 8'h20) col = 7 - col;
            ta = t_lcdc[4] ? tile * 16 : (tile < 128 ? 16'h1000 + tile * 16 : 16'h0800 + (tile - 128) * 16);
            ta = ta + row * 2 + ((attr & 8) ? 16'h2000 : 0);
            bgc = ((tvram[ta + 1] >> (7 - col)) & 1) * 2 + ((tvram[ta] >> (7 - col)) & 1);
            if (!cgb && !t_lcdc[0]) bgc = 0;
            // objects: first 10 in OAM order overlapping LY; CGB: first opaque in OAM order wins,
            // DMG: opaque with the smallest X wins (OAM order breaks ties)
            h = t_lcdc[2] ? 16 : 8;
            n = 0; best = -1; bestx = 0; bc = 0; ba = 0;
            for (k = 0; k < 40; k = k + 1) begin
                oy = toam[k * 4];
                if (n < 10 && y + 16 >= oy && y + 16 < oy + h) begin
                    n = n + 1;
                    ox = toam[k * 4 + 1];
                    if (x + 8 >= ox && x < ox) begin
                        oa = toam[k * 4 + 3];
                        sr = y + 16 - oy; if (oa & 8'h40) sr = h - 1 - sr;
                        st = toam[k * 4 + 2]; if (h == 16) st = (st & 8'hFE) | (sr >> 3);
                        sr = sr & 7;
                        sc = x + 8 - ox; if (oa & 8'h20) sc = 7 - sc;
                        sa = ((cgb && (oa & 8)) ? 16'h2000 : 0) + st * 16 + sr * 2;
                        c = ((tvram[sa + 1] >> (7 - sc)) & 1) * 2 + ((tvram[sa] >> (7 - sc)) & 1);
                        if (c != 0 && (best < 0 || (!cgb && ox < bestx))) begin
                            best = k; bestx = ox; bc = c; ba = oa;
                        end
                    end
                end
            end
            obj = t_lcdc[1] && best >= 0 &&
                  (bgc == 0 || (cgb ? (!t_lcdc[0] || (!(attr & 8'h80) && !(ba & 8'h80))) : !(ba & 8'h80)));
            if (obj) begin pl = (ba & 8'h10) ? t_obp1 : t_obp0; shade = (pl >> (2 * bc)) & 3; end
            else shade = (t_bgp >> (2 * bgc)) & 3;
            if (cgb) begin
                if (obj) begin idx = (ba & 7) * 8 + bc * 2; rgb = toc[idx] | ((toc[idx + 1] & 8'h7F) << 8); end
                else begin idx = (attr & 7) * 8 + bgc * 2; rgb = tbc[idx] | ((tbc[idx + 1] & 8'h7F) << 8); end
            end else begin
                g = shade == 0 ? 31 : shade == 1 ? 21 : shade == 2 ? 10 : 0;
                rgb = g | (g << 5) | (g << 10);
            end
            ref_px = {shade[1:0], rgb[14:0]};
        end
    endfunction

    integer seed;
    integer cap = 0, vs = 0, line_dot_max = 0;
    integer cnt [0:143];
    reg [16:0] e;
    always @(posedge clk) begin
        if (vsync) vs = vs + 1;
        if (cap && pix_we && vs == 1) begin
            if (pix_y >= 144 || pix_x >= 160 || pix_x != cnt[pix_y]) begin
                errors = errors + 1;
                if (errors < 20) $display("FAIL order: pixel x=%0d y=%0d, expected x=%0d", pix_x, pix_y,
                                          pix_y < 144 ? cnt[pix_y] : -1);
            end else begin
                cnt[pix_y] = cnt[pix_y] + 1;
                e = ref_px(pix_x, pix_y);
                if (pix !== e[16:15] || pix_rgb !== e[14:0]) begin
                    errors = errors + 1;
                    if (errors < 20) $display("FAIL pixel (%0d,%0d): pix %0d rgb %04h, expected %0d %04h",
                                              pix_x, pix_y, pix, pix_rgb, e[16:15], e[14:0]);
                end
                if (pix_x == 159 && dut.dot > line_dot_max) line_dot_max = dut.dot;
            end
        end
    end

    function integer full_lines;      // reference: lines with 10 objects selected
        input dummy;
        integer y, k, n, h;
        begin
            full_lines = 0; h = t_lcdc[2] ? 16 : 8;
            for (y = 0; y < 144; y = y + 1) begin
                n = 0;
                for (k = 0; k < 40; k = k + 1)
                    if (y + 16 >= toam[k * 4] && y + 16 < toam[k * 4] + h) n = n + 1;
                if (n >= 10) full_lines = full_lines + 1;
            end
        end
    endfunction

    task render_test(input integer s, input c, input frac);
        integer a, b, v, missing;
        begin
            seed = s;
            do_reset(c);
            cont = 1;                                             // fast setup
            wr(16'hFF40, 8'h00);
            for (b = 0; b < 2; b = b + 1) begin
                wr(16'hFF4F, b);
                for (a = 0; a < 8192; a = a + 1) begin
                    v = $random(seed) & 255;
                    wr(16'h8000 + a, v);
                    if (b == 1 && c) tvram[16'h2000 + a] = v;
                    else if (b == 0 || !c) tvram[a] = v;          // DMG: VBK ignored, bank 0 only
                end
            end
            if (!c) for (a = 0; a < 8192; a = a + 1) tvram[16'h2000 + a] = 0;
            for (a = 0; a < 40; a = a + 1) begin
                // half the objects crowd a 24-line band (more than 10 per line), the rest anywhere
                v = a < 20 ? 60 + ($random(seed) & 15) : ($random(seed) & 255) % 170;
                toam[a * 4] = v;
                toam[a * 4 + 1] = ($random(seed) & 255) % 176;
                toam[a * 4 + 2] = $random(seed);
                toam[a * 4 + 3] = $random(seed);
                for (b = 0; b < 4; b = b + 1) wr(16'hFE00 + a * 4 + b, toam[a * 4 + b]);
            end
            wr(16'hFF68, 8'h80); wr(16'hFF6A, 8'h80);
            for (a = 0; a < 64; a = a + 1) begin
                tbc[a] = $random(seed); toc[a] = $random(seed);
                wr(16'hFF69, tbc[a]); wr(16'hFF6B, toc[a]);
            end
            t_scx = $random(seed); t_scy = $random(seed);
            t_wx = 7 + ($random(seed) & 255) % 160; t_wy = ($random(seed) & 255) % 150;
            t_bgp = $random(seed); t_obp0 = $random(seed); t_obp1 = $random(seed);
            // LCDC.0 alternates with the seed, window enable follows seed bit 1, the rest is random
            t_lcdc = 8'h82 | ($random(seed) & 8'h5C) | (s & 1) | ((s & 2) << 4);
            wr(16'hFF43, t_scx); wr(16'hFF42, t_scy); wr(16'hFF4B, t_wx); wr(16'hFF4A, t_wy);
            wr(16'hFF47, t_bgp); wr(16'hFF48, t_obp0); wr(16'hFF49, t_obp1);
            wr(16'hFF4F, 8'h00);
            for (a = 0; a < 144; a = a + 1) cnt[a] = 0;
            @(negedge clk); cont = !frac; addr = 16'h0000;
            vs = 0; cap = 1; line_dot_max = 0;
            wr(16'hFF40, t_lcdc);
            addr = 16'h0000;
            while (vs < 2) @(posedge clk);
            cap = 0;
            missing = 0;
            for (a = 0; a < 144; a = a + 1) if (cnt[a] != 160) missing = missing + 1;
            if (missing) begin errors = errors + 1; $display("FAIL: %0d lines without 160 pixels", missing); end
            $display("render seed %0d %0s %0s LCDC=%02h SCX=%0d SCY=%0d WX=%0d WY=%0d: %0d full-OAM lines, last pixel by dot %0d, errors so far %0d",
                     s, c ? "CGB" : "DMG", frac ? "fractional" : "1dot/clk", t_lcdc, t_scx, t_scy, t_wx, t_wy,
                     full_lines(0), line_dot_max, errors);
        end
    endtask

    initial begin
        test_registers;
        $display("register checks done, errors %0d", errors);
        render_test(1, 1, 1);
        render_test(2, 1, 1);
        render_test(3, 1, 0);
        render_test(4, 1, 1);
        render_test(5, 0, 1);
        render_test(6, 0, 0);
        render_test(7, 0, 1);
        render_test(11, 1, 1);
        if (errors != 0) $fatal(1, "PPU color regression failed (%0d errors)", errors);
        $display("RESULT PASS");
        $finish;
    end
endmodule
