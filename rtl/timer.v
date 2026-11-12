// DIV/TIMA/TMA/TAC timer. Advances once per M-cycle (ce). A CPU read in an M-cycle sees
// the state after that cycle's tick (Mooneye timer tests), so reads come from the next state.
module gb_timer (
    input            clk,
    input            rst,
    input            ce,
    input            boot,      // power-on through the boot ROM (internal counter starts at 8)
    input            div_reset, // STOP resets DIV even when its M-cycle enable is paused
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

    reg [15:0] ndiv;
    reg [2:0] ntac;
    reg [8:0] t9;
    reg nirq, novf;
    reg [15:0] tdiv;              // counter after this M-cycle's four ticks, before any write
    // next state if this M-cycle completes (writes included; reads have no write)
    always @(*) begin
        tdiv = div_reset ? 16'd0 : div + 16'd4;
        ndiv = tdiv;
        ntac = tac;
        if (sel && wr && addr_lo[1:0] == 2'd0) ndiv = 0;
        if (sel && wr && addr_lo[1:0] == 2'd3) ntac = din[2:0];
        t9 = {1'b0, tima};
        nirq = 0;
        if (ovf) begin t9 = {1'b0, tma}; nirq = 1; end
        novf = 0;
        // A TIMA write wins over a same-cycle increment, is ignored in the reload cycle
        // (TMA wins there) and cancels a pending reload when it lands on the overflow.
        if (sel && wr && addr_lo[1:0] == 2'd1 && !ovf) t9 = {1'b0, din};
        if (sel && wr && addr_lo[1:0] == 2'd2 && ovf) t9 = {1'b0, din};
        // A falling edge of the selected bit increments TIMA. DIV/TAC writes can drop the
        // timer input at the write edge. TAC itself becomes visible before the last of this
        // M-cycle's four divider ticks: an enable therefore also sees a natural fall only
        // when tdiv lands exactly on the selected divider boundary.
        // OR the causes: coincident clock/write edges are one physical falling edge.
        if (((tbit(div, tac) && !tbit(tdiv, tac)) ||
            (sel && wr && addr_lo[1:0] == 2'd3 && !tac[2] && ntac[2] &&
             tbit(div, ntac) && !tbit(tdiv, ntac) &&
             ((ntac[1:0] == 2'd0 && tdiv[9:0] == 0) ||
              (ntac[1:0] == 2'd1 && tdiv[3:0] == 0) ||
              (ntac[1:0] == 2'd2 && tdiv[5:0] == 0) ||
              (ntac[1:0] == 2'd3 && tdiv[7:0] == 0))) ||
            (tbit(tdiv, tac) && !tbit(ndiv, ntac))) &&
            !(sel && wr && addr_lo[1:0] == 2'd1 && !ovf)) begin
            t9 = t9 + 1'b1;
            novf = t9[8];
        end
    end

    always @(*) case (addr_lo[1:0])
        2'd0: dout = ndiv[15:8];
        2'd1: dout = t9[7:0];
        2'd2: dout = tma;
        default: dout = {5'b11111, tac};
    endcase

    always @(posedge clk) begin
        irq <= 0;
        if (rst) begin
            // CGB ABCDE post-boot value and sub-M-cycle phase. A mapped boot ROM starts at 0008.
            div <= boot ? 16'h0008 : 16'h2677; tima <= 0; tma <= 0; tac <= 0; ovf <= 0;
        end else if (ce || div_reset) begin
            if (ce && sel && wr && addr_lo[1:0] == 2'd2) tma <= din;
            irq <= nirq;
            ovf <= novf;
            tima <= t9[7:0];
            div <= ndiv;
            tac <= ntac;
        end
    end
endmodule
