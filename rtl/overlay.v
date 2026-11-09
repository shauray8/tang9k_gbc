// In-game overlay menu, drawn over the HDMI picture (no frame buffer, no BSRAM).
//
// overlay_ctl (system domain): S2 or the host's 'O' command opens it while a game runs. The
// core is held (CPU, timer, DMA; the PPU keeps the picture) and sees no buttons. Up/Down pick an
// item, A/Start activates, B resumes:
//   0 RESUME   1 SAVE (host saves, overlay closes)   2 LIBRARY (overlay closes; the host freezes,
//     saves and loads the menu, so nothing waits on a host that is absent or busy)
//   3 RESET (core reset; cart RAM and the loaded ROM stay)   4 BOOT LOGO on/off (next reset/load)
//   5 COLOUR: AUTO or SameBoy boot ROM palette 1-16 for original-GB carts. The boot ROM reads
//     its key combination while the logo runs, so the chosen combination is held on the core's
//     joypad during the boot ROM. CGB carts are never given one: a combination would force them
//     into DMG mode.
// Host events go out as 'O' <code>: 1 save, 2 library, 3 reset, 4 boot logo off, 5 boot logo on.
//
// overlay_render (video domain): 6 items in a panel at GB pixels x 28-131, y 16-127, drawn
// with a 3x5 font at 2x (each GB pixel is 5x5 HDMI pixels). Output per pixel: 0 picture,
// 1 panel, 2 text, 3 selected.
module overlay_ctl (
    input             clk,
    input             rst,
    input             enable,       // a game (not the launcher menu) is loaded and running
    input             open,         // 1-clk pulse
    input             close_all,    // game (re)load
    input      [7:0]  pad,          // active high {start,select,b,a,down,up,left,right}
    input             cart_cgb,
    input             boot_active,  // core still executes the boot ROM
    input             boot_run,     // the running game was started through the boot ROM
    input             boot_en,      // boot logo preference (applies from the next reset)
    output reg        on,
    output reg [2:0]  sel,
    output reg [4:0]  pal,          // 0 AUTO, 1-16 boot ROM key combination
    output reg        core_reset,   // 1-clk pulse
    output reg        boot_toggle,  // 1-clk pulse
    output     [7:0]  core_pad,
    output reg        ev_valid,
    output reg [7:0]  ev_code,
    input             ev_take
);
    reg [7:0] prev;
    wire [7:0] press = pad & ~prev;
    wire up = press[2], down = press[3], left = press[1], right = press[0];
    wire act = press[4] || press[7], back = press[5];

    wire [3:0] p1 = pal[3:0] - 4'd1;
    wire [7:0] combo = {2'b00, p1[3], p1[2], 4'b0001 << p1[1:0]};
    assign core_pad = on ? 8'h00 :
                      boot_active && boot_run && !cart_cgb && pal != 0 ? combo : pad;

    task event_out(input [7:0] code);
        begin ev_valid <= 1; ev_code <= code; end
    endtask

    always @(posedge clk) begin
        prev <= pad;
        core_reset <= 0;
        boot_toggle <= 0;
        if (ev_take) ev_valid <= 0;
        if (rst || close_all) begin
            on <= 0; sel <= 0; ev_valid <= 0;     // a request never outlives its game
            if (rst) pal <= 0;
        end else if (!on) begin
            if (open && enable) begin on <= 1; sel <= 0; end
        end else begin
            if (up) sel <= sel == 0 ? 3'd5 : sel - 3'd1;
            if (down) sel <= sel == 5 ? 3'd0 : sel + 3'd1;
            if (back) on <= 0;
            if ((sel == 4 && (left || right)) || (sel == 4 && act)) begin
                boot_toggle <= 1;
                event_out(boot_en ? 8'd4 : 8'd5);
            end
            if (sel == 5 && (right || act)) pal <= pal == 16 ? 5'd0 : pal + 5'd1;
            if (sel == 5 && left) pal <= pal == 0 ? 5'd16 : pal - 5'd1;
            if (act) case (sel)
                3'd0: on <= 0;
                3'd1: begin on <= 0; event_out(8'd1); end
                3'd2: begin on <= 0; event_out(8'd2); end
                3'd3: begin on <= 0; core_reset <= 1; event_out(8'd3); end
                default: ;
            endcase
        end
    end
endmodule

module overlay_render (
    input             clk,
    input      [7:0]  gx,           // GB pixel of the ring read issued this clock
    input      [7:0]  gy,
    input             on,
    input      [2:0]  sel,
    input             boot,
    input      [4:0]  pal,
    output reg [1:0]  px            // four clocks later
);
    // Four register stages (position, character, glyph row, pixel) keep each step within a
    // 74.25 MHz clock. They trail the ring data by three HDMI pixels: a uniform shift of the
    // whole panel (each GB pixel is 5 HDMI pixels wide).
    // Text: 12 columns x 6 rows of 8x16 GB-pixel cells from x 32, y 24; 3x5 glyphs at 2x.
    localparam [7:0] TX = 8'd32, TY = 8'd24;
    wire [7:0] dx = gx - TX, dy = gy - TY;
    reg [3:0] col; reg [2:0] cx, row; reg [3:0] cy; reg text_a, in_a;
    always @(posedge clk) begin
        col <= dx[6:3]; cx <= dx[2:0]; row <= dy[6:4]; cy <= dy[3:0];
        text_a <= gx >= TX && gx < TX + 8'd96 && gy >= TY && gy < TY + 8'd96;
        in_a <= on && gx >= TX - 8'd4 && gx < TX + 8'd100 && gy >= TY - 8'd8 && gy < TY + 8'd104;
    end

    `include "overlay_rom.vh"
    wire [3:0] pal_ones = pal >= 5'd10 ? pal[3:0] - 4'd10 : pal[3:0];
    wire hl = row == sel;
    reg [4:0] ch;
    always @(*) begin
        ch = text_code(row, col);
        if (row == 3'd4 && col == 4'd7) ch = boot ? CH_N : CH_F;               // ON / OFF
        if (row == 3'd4 && col == 4'd8) ch = boot ? CH_SPACE : CH_F;
        if (row == 3'd5 && pal == 0) case (col)                                // AUTO
            4'd8: ch = CH_A; 4'd9: ch = CH_U; 4'd10: ch = CH_T; 4'd11: ch = CH_O;
            default: ;
        endcase
        if (row == 3'd5 && pal != 0 && col == 4'd10) ch = pal >= 5'd10 ? 5'd1 : CH_SPACE;
        if (row == 3'd5 && pal != 0 && col == 4'd11) ch = {1'b0, pal_ones};    // digits are codes 0-9
        if (col == 4'd0 && hl) ch = CH_GT;
        if (!text_a) ch = CH_SPACE;
    end

    // Glyph pixel (fx, fy) covers cell pixels 1+2fx..2+2fx and 3+2fy..4+2fy.
    reg [4:0] ch_b; reg [1:0] fx; reg [2:0] fy; reg lit_ok, in_b, hl_b;
    wire [2:0] cxm = cx - 3'd1;
    wire [3:0] cym = cy - 4'd3;
    always @(posedge clk) begin
        ch_b <= ch; fx <= cxm[2:1]; fy <= cym[3:1];
        lit_ok <= cx >= 3'd1 && cx <= 3'd6 && cy >= 4'd3 && cy <= 4'd12;
        in_b <= in_a; hl_b <= hl && text_a;
    end
    // Glyph row, then the pixel: the font ROM gets a clock of its own.
    reg [2:0] line; reg [1:0] fx_c; reg lit_c, in_c, hl_c;
    always @(posedge clk) begin
        line <= glyph_row(ch_b, fy); fx_c <= fx; lit_c <= lit_ok; in_c <= in_b; hl_c <= hl_b;
    end
    wire bit_on = lit_c && line[3'd2 - {1'b0, fx_c}];
    always @(posedge clk) px <= !in_c ? 2'd0 : !bit_on ? 2'd1 : hl_c ? 2'd3 : 2'd2;
endmodule
