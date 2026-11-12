`timescale 1ns/1ps

module tb_timer;
    reg clk = 0, rst = 1, ce = 0, boot = 0, div_reset = 0;
    reg [7:0] addr_lo = 0, din = 0;
    reg sel = 0, wr = 0;
    wire [7:0] dout;
    wire irq;

    gb_timer dut (
        .clk(clk), .rst(rst), .ce(ce), .boot(boot), .div_reset(div_reset),
        .addr_lo(addr_lo), .sel(sel), .wr(wr), .din(din), .dout(dout), .irq(irq)
    );

    always #5 clk = ~clk;

    task cycle;
        input active;
        begin
            ce = active;
            @(posedge clk); #1;
            ce = 0;
        end
    endtask

    task write_reg;
        input [7:0] addr;
        input [7:0] value;
        begin
            addr_lo = addr; din = value; sel = 1; wr = 1;
            cycle(1);
            sel = 0; wr = 0;
        end
    endtask

    integer i;
    initial begin
        repeat (2) @(posedge clk);
        rst = 0;

        // TAC becomes visible before the final divider tick of its write M-cycle.
        // Enabling at 07fc must therefore observe bit 9 falling at 0800.
        write_reg(8'h05, 8'hf0);
        write_reg(8'h04, 0);
        for (i = 0; i < 511; i = i + 1) cycle(1);
        if (dut.div !== 16'h07fc) $fatal(1, "setup DIV=%04x", dut.div);
        write_reg(8'h07, 8'h04);
        if (dut.tima !== 8'hf1) $fatal(1, "final-tick TAC enable lost: TIMA=%02x", dut.tima);

        // Preserve the established DIV-write falling-edge behavior.
        write_reg(8'h05, 8'h04);
        write_reg(8'h04, 0);
        write_reg(8'h07, 8'h04);
        for (i = 0; i < 127; i = i + 1) cycle(1);
        if (!dut.div[9]) $fatal(1, "DIV bit 9 never rose: DIV=%04x", dut.div);
        write_reg(8'h04, 0);
        if (dut.tima !== 8'h05) $fatal(1, "DIV reset edge lost: TIMA=%02x", dut.tima);

        $display("TIMER PASS: final-tick TAC enable and DIV-reset falling edges");
        $finish;
    end
endmodule
