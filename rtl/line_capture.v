// Headless video readback: captures one LCD line (160 px) as the PPU draws it and streams it out
// through a byte sink with backpressure. Purely passive on the pixel bus, so game timing is
// untouched; storage is one synchronous 160 x 15-bit BSRAM, shared by both reply formats.
// A full screen is assembled by requesting lines one at a time, so successive
// lines come from successive frames (rolling, not atomic).
//
// Reply to req(line) with color_mode = 0 (legacy 'V' request, 2-bit shades):
//   'V' <line> <40 bytes: pixel 4k in bits 7:6 ... pixel 4k+3 in bits 1:0> <sum8 of the 40 bytes>
// Reply to req(line) with color_mode = 1 ('W' request, native RGB555 from pix_rgb):
//   'W' <line> <320 bytes: pixel i = byte 2i | byte 2i+1 << 8, bits 4:0 R, 9:5 G, 14:10 B, bit 15 0>
//   <sum8 of the 320 bytes>
// Errors (either mode):
//   'v' <code>   1 = core held in reset, 2 = LCD off, 3 = line not drawn within 2^21 clk, 4 = line >= 144
// color_mode is sampled with req; a line is only sent once all 160 pixels of it arrived in order
// within one frame, otherwise it is recaptured from a later frame.
module line_capture (
    input             clk,
    input             rst,
    input             req,          // 1-clk pulse, ignored while busy
    input       [7:0] line,
    input             color_mode,   // with req: 1 = 'W' RGB555 reply, 0 = 'V' 2-bit reply
    input             running,      // core out of reset
    input             lcd_on,
    input             pix_we,
    input       [1:0] pix,
    input      [14:0] pix_rgb,
    input       [7:0] pix_x,
    input       [7:0] pix_y,
    input             tx_ready,     // sink accepts a byte this cycle
    output            tx_we,
    output      [7:0] tx_d,
    output            busy
);
    localparam IDLE = 2'd0, WAIT = 2'd1, CAP = 2'd2, SEND = 2'd3;
    reg [1:0] st;
    reg cm;                        // latched color_mode
    reg [7:0] y;
    reg [21:0] timer;
    reg [7:0] ex;                  // next expected pixel x
    reg [5:0] sh;                  // 3 pending pixels of the current legacy byte
    reg [7:0] sum;
    reg [2:0] err;                 // 0 = data reply
    reg [8:0] k;                   // reply byte index (0..322)
    // Color: entry x = pixel x. Legacy: entry x/4 = packed byte of pixels x..x+3 (bits 14:8 zero).
    (* ram_style = "block" *) reg [14:0] lb [0:159];

    wire [7:0] pb = {sh, pix};
    wire [7:0] rgb_lo = pix_rgb[7:0];
    wire [7:0] rgb_hi = {1'b0, pix_rgb[14:8]};
    wire active = st == WAIT || st == CAP;
    // Next in-order pixel of the requested line (same priority as the abort checks below).
    wire take = active && running && lcd_on && !timer[21] && pix_we && pix_y == y
                && pix_x == (st == WAIT ? 8'd0 : ex);

    wire [8:0] d = k - 9'd2;       // data byte index
    // Prefetch the next reply byte on acceptance; this also supports a sink ready every cycle.
    // The two header bytes provide the initial RAM-read latency before pixel data is transmitted.
    wire [8:0] read_k = st == SEND && tx_ready ? k + 9'd1 : k;
    wire [8:0] read_d = read_k - 9'd2;
    reg [14:0] rd;
    always @(posedge clk) rd <= lb[cm ? read_d[8:1] : read_d[7:0]];
    wire [7:0] db = cm && d[0] ? {1'b0, rd[14:8]} : rd[7:0];
    wire last = err != 0 ? k == 9'd1 : k == (cm ? 9'd322 : 9'd42);
    assign busy = st != IDLE;
    assign tx_we = st == SEND && tx_ready;
    assign tx_d = k == 0 ? (err != 0 ? "v" : cm ? "W" : "V") :
                  k == 1 ? (err != 0 ? {5'd0, err} : y) :
                  last ? sum : db;

    // One write port: every color pixel, or every 4th legacy pixel (completing a packed byte).
    wire wen = take && (cm || pix_x[1:0] == 2'd3);
    wire [7:0] wa = cm ? pix_x : {2'd0, pix_x[7:2]};
    wire [14:0] wdat = cm ? pix_rgb : {7'd0, pb};
    always @(posedge clk) if (wen) lb[wa] <= wdat;

    always @(posedge clk) begin
        if (rst) st <= IDLE;
        else case (st)
            IDLE: if (req) begin
                y <= line; cm <= color_mode; timer <= 0; k <= 0;
                err <= line >= 8'd144 ? 3'd4 : !running ? 3'd1 : !lcd_on ? 3'd2 : 3'd0;
                st <= line >= 8'd144 || !running || !lcd_on ? SEND : WAIT;
            end
            WAIT, CAP: begin
                timer <= timer + 1;
                if (!running) begin err <= 3'd1; st <= SEND; end
                else if (!lcd_on) begin err <= 3'd2; st <= SEND; end
                else if (timer[21]) begin err <= 3'd3; st <= SEND; end
                else if (take) begin
                    st <= pix_x == 8'd159 ? SEND : CAP;
                    ex <= pix_x + 1;
                    sh <= pb[5:0];
                    if (cm) sum <= (pix_x == 0 ? 8'd0 : sum) + rgb_lo + rgb_hi;
                    else if (pix_x == 0) sum <= 0;
                    else if (pix_x[1:0] == 2'd3) sum <= sum + pb;
                end else if (pix_we) st <= WAIT;    // out of order / line ended early: retry next frame
            end
            SEND: if (tx_ready) begin
                k <= k + 1;
                if (last) st <= IDLE;
            end
        endcase
    end
endmodule
