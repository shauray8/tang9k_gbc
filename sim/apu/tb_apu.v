`timescale 1ns/1ps
module tb_apu;
    reg clk = 0, rst = 1, ce = 0, wr = 0, sel = 1;
    reg [7:0] addr = 0, din = 0;
    wire [7:0] dout;
    wire [9:0] sample;
    integer changes = 0;
    reg [9:0] previous;

    apu dut(.clk(clk), .rst(rst), .ce(ce), .wr(wr), .sel(sel),
            .addr_lo(addr), .din(din), .dout(dout), .sample(sample));
    always #5 clk = !clk;

    task put;
        input [7:0] a;
        input [7:0] d;
        begin
            @(negedge clk); addr = a; din = d; wr = 1;
            @(negedge clk); wr = 0;
        end
    endtask

    task check_reg;
        input [7:0] a;
        input [7:0] value;
        begin
            addr = a; #1;
            if (dout !== value) begin
                $display("APU FAIL: FF%02x read %02x expected %02x", a, dout, value);
                $fatal;
            end
        end
    endtask

    task check_voice;
        input integer channel_index;
        begin
            changes = 0;
            previous = sample;
            repeat (64) begin
                @(negedge clk);
                if (sample != previous) changes = changes + 1;
                previous = sample;
            end
            addr = 8'h26; #1;
            if (changes < 1 || !dout[0]) begin
                $display("APU FAIL: trigger group %0d did not drive voice changes=%0d NR52=%02x",
                         channel_index + 1, changes, dout);
                $fatal;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 0; ce = 1;
        check_reg(8'h10, 8'h80);
        check_reg(8'h11, 8'hBF);
        check_reg(8'h12, 8'hF3);
        check_reg(8'h24, 8'h77);
        check_reg(8'h25, 8'hF3);
        check_reg(8'h26, 8'hF1);

        put(8'h30, 8'hA5);
        check_reg(8'h30, 8'hFF);

        // Every hardware trigger group must drive the fit-safe shared voice.
        put(8'h12, 8'hF0); put(8'h13, 8'hFF); put(8'h14, 8'h87); check_voice(0);
        put(8'h17, 8'hF0); put(8'h18, 8'hFF); put(8'h19, 8'h87); check_voice(1);
        put(8'h1D, 8'hFF); put(8'h1E, 8'h87); check_voice(2);
        put(8'h21, 8'hF0); put(8'h23, 8'h80); check_voice(3);

        put(8'h26, 8'h00);
        check_reg(8'h26, 8'h70);
        if (sample !== 10'd0) begin
            $display("APU FAIL: powered-off sample %0d", sample);
            $fatal;
        end
        $display("APU PASS: CGB masks, shared square output and power control");
        $finish;
    end
endmodule
