// 1280x720p60 video path for the Game Boy image, frame-locked without a frame buffer.
//
// Clocks: clk_sys (27 MHz: GB core, pixel writes, frame lock) and clk_pix (74.25 MHz: CEA-861
// 1650x750 timing, 5x scaler). Both derive from the 27 MHz crystal, so one video frame is exactly
// 1237500 pixel clocks = 450000 system clocks (60.00 Hz).
//
// GB clock enable: `tick` gives exactly 70224 dots (one GB frame) per 450000 system clocks, 6-7
// clocks apart. The GB runs at 60.00 Hz instead of 59.73 Hz (0.46% fast).
//
// Control crossings use single-bit synchronizers; the fingerprint uses a held bundled-data snapshot:
//  - video -> sys: a toggle at every video frame start (2FF) re-anchors `spos`, a free-running
//    450000-clock counter that is 0 in the first system cycle after the video frame start.
//  - sys -> video: locked, lcd_on and cgb_mode (2FF each). They take effect at the video frame
//    start; loss of lock or LCD blanks the picture immediately.
//
// Frame lock: the GB frame starts (PPU released at LY 0, dot 0) at spos == TARGET, 3600 system =
// 9900 pixel clocks before the video frame. The core is held there while loading, after LCD enable
// (the PPU restarts at LY 0, dot 0) and after a vsync at the wrong phase; it keeps running while
// the LCD is off. `locked` means the last vsync arrived at the target phase with the LCD on. It is
// cleared while loading, while the LCD is off and when the video frame phase jumps.
//
// Ring: 6 GB lines x 160 pixels x 15 bits in one dual-clock BSRAM (960 x 15 = 14400 bits),
// slot = LY mod 6. CGB stores native RGB555 {B, G, R}; DMG stores the 2-bit shade. The reader
// derives the GB line from its own counters (video line / 5), so no pointer crosses domains.
// With pixel x of line n written at dot 80+x .. 296+x of its line (conservative mode-3 bounds),
// every write lands after the last read of the line 6 earlier and before the first read of its own
// line for GB frame phases of -13422.9 .. -6983.1 pixel clocks. At the chosen -9900 the worst
// cases leave about 2880 pixel clocks before the first read and 3550 after the last read;
// sim/video/run.sh checks ring lifetime at observable RGB outputs across independent clock phases.
//
// Picture: 800x720 GB image at x 240..1039, black outside. When not locked, the image area shows a
// blank LCD (white for CGB, the lightest DMG green otherwise).
module video_buffer (
    // system domain
    input             clk_sys,
    input             rst_sys,
    input             run,          // GB core out of reset
    input             lcd_on,
    input             gb_vsync,     // PPU: LY 153 -> 0 with the LCD on
    input             cgb_mode,
    input             pix_we,
    input      [7:0]  pix_x,
    input      [7:0]  pix_y,
    input      [1:0]  pix,          // DMG shade
    input      [14:0] pix_rgb,      // CGB RGB555: bits 4:0 R, 9:5 G, 14:10 B
    output reg        tick,         // GB clock enable
    output reg        locked,
    output reg        waitlock,     // GB held until the frame-phase target
    // video domain
    input             clk_pix,
    input             rst_pix,
    output reg [7:0]  r, g, b,
    output reg        de, hs, vs,   // sync active high (CEA-861 720p)
    output reg [15:0] scanout_sig,  // completed post-scaler RGB fingerprint, synchronized to clk_sys
    output reg [7:0]  scanout_frame
);
    localparam [18:0] SYS_FRAME = 19'd450000, GB_FRAME = 19'd70224;
    localparam [18:0] TARGET = 19'd446400;      // GB frame start, 3600 system clocks before spos 0
    localparam [18:0] SYNC_LAT = 19'd2;         // spos loaded when the synchronized toggle is seen
    // A locked core's vsync arrives at spos TARGET + 2.
    localparam [18:0] LOCK_LO = TARGET - 19'd8, LOCK_HI = TARGET + 19'd32;

    reg [14:0] ring [0:959];

    // ---------------- system domain: frame counter, GB clock enable, lock ----------------
    reg vft;                                    // video frame toggle (video domain)
    reg [15:0] video_sig, video_sig_hold;
    reg [2:0] vft_s;
    reg [18:0] spos, acc;
    reg sp_ok, lcd_d;
    wire vframe = vft_s[2] ^ vft_s[1];
    // In phase, spos is SYNC_LAT - 1 when the toggle is seen; one clock of synchronizer jitter is accepted.
    wire vjump = vframe && sp_ok && spos > SYNC_LAT;
    always @(posedge clk_sys) vft_s <= {vft_s[1:0], vft};
    always @(posedge clk_sys) begin
        tick <= 1'b0;
        lcd_d <= lcd_on;
        if (rst_sys) begin
            spos <= 0; sp_ok <= 0; acc <= 0; waitlock <= 1; locked <= 0;
            scanout_sig <= 0; scanout_frame <= 0;
        end else begin
            if (vframe) begin
                spos <= SYNC_LAT; sp_ok <= 1;
                // The snapshot is held for a video frame; the toggle synchronizer settles first.
                scanout_sig <= video_sig_hold; scanout_frame <= scanout_frame + 1'b1;
            end
            else spos <= spos == SYS_FRAME - 19'd1 ? 19'd0 : spos + 19'd1;

            if (waitlock) begin
                if (sp_ok && spos == TARGET) begin waitlock <= 0; acc <= 0; end
            end else if (acc >= SYS_FRAME - GB_FRAME) begin
                acc <= acc + GB_FRAME - SYS_FRAME; tick <= 1'b1;
            end else acc <= acc + GB_FRAME;

            if (gb_vsync) begin
                if (spos >= LOCK_LO && spos <= LOCK_HI) locked <= 1;
                else begin waitlock <= 1; locked <= 0; end
            end
            if (lcd_on && !lcd_d) waitlock <= 1;    // LCD enable restarts the PPU at LY 0, dot 0
            if (vjump || !lcd_on) locked <= 0;
            if (!lcd_on) waitlock <= 0;
            if (!run) begin waitlock <= 1; locked <= 0; tick <= 0; acc <= 0; end
        end
    end

    // ---------------- system domain: ring writes ----------------
    function [9:0] line_base(input [7:0] y);   // (y mod 6) * 160
        reg [3:0] s;
        reg [2:0] m;
        begin
            s = y[1:0] + y[3:2] + y[5:4] + y[7:6];  // 4 == 1 (mod 3), so s == y (mod 3); 0..12
            m = s >= 4'd12 ? 3'd0 : s >= 4'd9 ? s - 4'd9 : s >= 4'd6 ? s - 4'd6 : s >= 4'd3 ? s - 4'd3 : s;
            if (m[0] != y[0]) m = m + 3'd3;         // residue mod 6 with the parity of y
            line_base = {m, 7'd0} + {2'd0, m, 5'd0};
        end
    endfunction

    reg w_en;
    reg [9:0] w_addr;
    reg [14:0] w_data;
    always @(posedge clk_sys) begin
        w_en <= pix_we;
        w_addr <= line_base(pix_y) + {2'd0, pix_x};
        w_data <= cgb_mode ? pix_rgb : {13'd0, pix};
    end
    always @(posedge clk_sys) if (w_en) ring[w_addr] <= w_data;

    // ---------------- video domain: 1280x720p60 timing, ring read address ----------------
    localparam [10:0] H_ACT = 11'd1280, H_SYNC0 = 11'd1390, H_SYNC1 = 11'd1430, H_TOT = 11'd1650;
    localparam [9:0]  V_ACT = 10'd720, V_SYNC0 = 10'd725, V_SYNC1 = 10'd730, V_TOT = 10'd750;
    localparam [10:0] X0 = 11'd240, X1 = 11'd1040;   // 5 x 160 GB pixels, centred; full height

    reg [10:0] hc;
    reg [9:0] vc, rbase, rptr;
    reg [2:0] sx, sy;
    wire eol = hc == H_TOT - 11'd1;
    wire eof = eol && vc == V_TOT - 10'd1;
    always @(posedge clk_pix) begin
        if (rst_pix) begin
            hc <= 0; vc <= 0; vft <= 0; rbase <= 0; sy <= 0; rptr <= 0; sx <= 0;
        end else begin
            hc <= eol ? 11'd0 : hc + 11'd1;
            if (eol) vc <= eof ? 10'd0 : vc + 10'd1;
            if (eof) vft <= ~vft;
            // ring slot base of the next video line: GB line = video line / 5, slot = GB line mod 6
            if (eof) begin rbase <= 0; sy <= 0; end
            else if (eol && vc < V_ACT) begin
                if (sy == 3'd4) begin
                    sy <= 0; rbase <= rbase == 10'd800 ? 10'd0 : rbase + 10'd160;
                end else sy <= sy + 3'd1;
            end
            // ring address of the GB pixel at the next hc; each GB pixel spans 5 video pixels
            if (hc == X0 - 11'd1) begin rptr <= rbase; sx <= 0; end
            else if (hc >= X0 && hc < X1 - 11'd1) begin
                if (sx == 3'd4) begin sx <= 0; rptr <= rptr + 10'd1; end
                else sx <= sx + 3'd1;
            end
        end
    end

    // ---------------- video domain: synchronized flags ----------------
    reg [1:0] lock_s, lcd_s, cgb_s;
    reg show, cgb_v;
    always @(posedge clk_pix) begin
        lock_s <= {lock_s[0], locked};
        lcd_s <= {lcd_s[0], lcd_on};
        cgb_s <= {cgb_s[0], cgb_mode};
        if (rst_pix) begin show <= 0; cgb_v <= 0; end
        else if (eof) begin show <= lock_s[1] && lcd_s[1]; cgb_v <= cgb_s[1]; end
        else if (!lock_s[1] || !lcd_s[1]) show <= 0;
    end

    // ---------------- video domain: pipeline ----------------
    // S0: counters/rptr. S1: BRAM data + delayed flags. S2: registered RGB/DE/HS/VS outputs.
    wire de0 = hc < H_ACT && vc < V_ACT;
    wire win0 = hc >= X0 && hc < X1 && vc < V_ACT;
    wire hs0 = hc >= H_SYNC0 && hc < H_SYNC1;
    // VSYNC starts and ends with the HSYNC leading edge (CEA-861): 5 lines from line 724, pixel 1390.
    wire vs0 = vc == V_SYNC0 - 10'd1 ? hc >= H_SYNC0 :
               vc == V_SYNC1 - 10'd1 ? hc < H_SYNC0 :
               vc >= V_SYNC0 && vc < V_SYNC1 - 10'd1;

    reg [14:0] rq;
    reg de1, hs1, vs1, win1;
    reg win_out;
    always @(posedge clk_pix) rq <= ring[rptr];

    function [7:0] c5(input [4:0] c);           // 5 -> 8 bit: (c << 3) | (c >> 2)
        c5 = {c, c[4:2]};
    endfunction

    always @(posedge clk_pix) begin
        if (rst_pix) begin
            {de1, hs1, vs1, win1, win_out, de, hs, vs} <= 8'd0;
            {r, g, b} <= 24'd0;
        end else begin
            de1 <= de0; hs1 <= hs0; vs1 <= vs0; win1 <= win0;
            de <= de1; hs <= hs1; vs <= vs1;
            win_out <= win1;
            if (!win1) {r, g, b} <= 24'h000000;
            else if (!show) {r, g, b} <= cgb_v ? 24'hFFFFFF : 24'hE0F8D0;
            else if (cgb_v) {r, g, b} <= {c5(rq[4:0]), c5(rq[9:5]), c5(rq[14:10])};
            else case (rq[1:0])
                2'd0: {r, g, b} <= 24'hE0F8D0;
                2'd1: {r, g, b} <= 24'h88C070;
                2'd2: {r, g, b} <= 24'h346856;
                default: {r, g, b} <= 24'h081820;
            endcase
        end
    end

    // Fingerprint the actual registered RGB stream after RAM, scaling, blanking and palette expansion.
    // No framebuffer or pixel counter: this is a development readout, not a collision-free image proof.
    always @(posedge clk_pix) begin
        if (rst_pix) begin video_sig <= 0; video_sig_hold <= 0; end
        else if (eof) begin video_sig_hold <= video_sig; video_sig <= 0; end
        else if (win_out && de)
            video_sig <= {video_sig[14:0], video_sig[15]} ^ {1'b0, b[7:3], g[7:3], r[7:3]};
    end
endmodule
