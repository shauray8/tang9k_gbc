// DIV/TIMA/TMA/TAC timer. Advances once per M-cycle (ce).
module gb_timer (
    input            clk,
    input            rst,
    input            ce,
    input      [7:0] addr_lo,   // low byte, valid when sel
    input            sel,       // addr in FF04-FF07
    input            wr,
    input      [7:0] din,
    output reg [7:0] dout,
    output reg       irq
);
    reg [15:0] div;
    reg [7:0] tima, tma;
    reg [2:0] tac;
    reg ovf;   // TIMA overflowed last cycle, reload pending

    function tbit(input [15:0] dv, input [2:0] t);
        case (t[1:0])
            2'd0: tbit = t[2] & dv[9];
            2'd1: tbit = t[2] & dv[3];
            2'd2: tbit = t[2] & dv[5];
            default: tbit = t[2] & dv[7];
        endcase
    endfunction

    always @(*) case (addr_lo[1:0])
        2'd0: dout = div[15:8];
        2'd1: dout = tima;
        2'd2: dout = tma;
        default: dout = {5'b11111, tac};
    endcase

    reg [15:0] ndiv;
    reg [2:0] ntac;
    reg [8:0] t9;
    always @(posedge clk) begin
        irq <= 0;
        if (rst) begin
            div <= 16'hABCC; tima <= 0; tma <= 0; tac <= 0; ovf <= 0;
        end else if (ce) begin
            ndiv = div + 16'd4;
            ntac = tac;
            if (sel && wr && addr_lo[1:0] == 2'd0) ndiv = 0;
            if (sel && wr && addr_lo[1:0] == 2'd3) ntac = din[2:0];
            t9 = {1'b0, tima};
            if (ovf) begin t9 = {1'b0, tma}; irq <= 1; end
            ovf <= 0;
            if (sel && wr && addr_lo[1:0] == 2'd1) t9 = {1'b0, din};
            if (sel && wr && addr_lo[1:0] == 2'd2) begin tma <= din; if (ovf) t9 = {1'b0, din}; end
            // falling edge of the selected bit increments TIMA
            if (tbit(div, tac) && !tbit(ndiv, ntac)) begin
                t9 = t9 + 1;
                if (t9[8]) ovf <= 1;
            end
            tima <= t9[7:0];
            div <= ndiv;
            tac <= ntac;
        end
    end
endmodule
