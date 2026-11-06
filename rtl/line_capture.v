// Headless video readback: captures one LCD line (160 px, 2-bit shades) as the PPU draws it and
// streams it out through a byte sink with backpressure. Purely passive on the pixel bus, so game
// timing is untouched; storage is one 40-byte distributed RAM (no BSRAM, no frame buffer).
// A full screen is assembled by requesting lines one at a time, so successive lines come from
// successive frames (rolling, not atomic).
//
// Reply to req(line):
//   'V' <line> <40 bytes: pixel 4k in bits 7:6 ... pixel 4k+3 in bits 1:0> <sum8 of the 40 bytes>
//   'v' <code>   1 = core held in reset, 2 = LCD off, 3 = line not drawn within 2^21 clk, 4 = line >= 144
module line_capture (
    input            clk,
    input            rst,
    input            req,          // 1-clk pulse, ignored while busy
    input      [7:0] line,
    input            running,      // core out of reset
    input            lcd_on,
    input            pix_we,
    input      [1:0] pix,
    input      [7:0] pix_x,
    input      [7:0] pix_y,
    input            tx_ready,     // sink accepts a byte this cycle
    output           tx_we,
    output     [7:0] tx_d,
    output           busy
);
    localparam IDLE = 2'd0, WAIT = 2'd1, CAP = 2'd2, SEND = 2'd3;
    reg [1:0] st;
    reg [7:0] y;
    reg [21:0] timer;
    reg [7:0] ex;                  // next expected pixel x
    reg [5:0] sh;                  // 3 pending pixels of the current byte
    reg [7:0] sum;
    reg [2:0] err;                 // 0 = data reply
    reg [5:0] k;                   // reply byte index
    (* ram_style = "distributed" *) reg [7:0] lb [0:39];

    wire [7:0] pb = {sh, pix};
    wire [5:0] ra = k - 6'd2;
    wire last = err != 0 ? k == 6'd1 : k == 6'd42;
    assign busy = st != IDLE;
    assign tx_we = st == SEND && tx_ready;
    assign tx_d = k == 0 ? (err != 0 ? "v" : "V") :
                  k == 1 ? (err != 0 ? {5'd0, err} : y) :
                  k == 42 ? sum : lb[ra];

    always @(posedge clk) begin
        if (st == CAP && pix_we && pix_x == ex && pix_x[1:0] == 2'd3) lb[pix_x[7:2]] <= pb;
    end

    always @(posedge clk) begin
        if (rst) st <= IDLE;
        else case (st)
            IDLE: if (req) begin
                y <= line; timer <= 0; k <= 0;
                err <= line >= 8'd144 ? 3'd4 : !running ? 3'd1 : !lcd_on ? 3'd2 : 3'd0;
                st <= line >= 8'd144 || !running || !lcd_on ? SEND : WAIT;
            end
            WAIT, CAP: begin
                timer <= timer + 1;
                if (!running) begin err <= 3'd1; st <= SEND; end
                else if (!lcd_on) begin err <= 3'd2; st <= SEND; end
                else if (timer[21]) begin err <= 3'd3; st <= SEND; end
                else if (pix_we) begin
                    if (pix_y == y && pix_x == (st == WAIT ? 8'd0 : ex)) begin
                        st <= pix_x == 8'd159 ? SEND : CAP;
                        ex <= pix_x + 1;
                        sh <= pb[5:0];
                        if (pix_x == 0) sum <= 0;
                        else if (pix_x[1:0] == 2'd3) sum <= sum + pb;
                    end else st <= WAIT;    // out of order / line ended early: retry next frame
                end
            end
            SEND: if (tx_ready) begin
                k <= k + 1;
                if (last) st <= IDLE;
            end
        endcase
    end
endmodule
