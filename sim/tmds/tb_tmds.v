`timescale 1ns/1ps
// Decode the actual encoded words: data/control alignment, transition minimization and DC balance.
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg [7:0] d = 0;
    reg [1:0] c = 0;
    reg de = 0;
    wire [9:0] q;
    tmds_enc dut (.clk(clk), .d(d), .c(c), .de(de), .q(q));
    reg [7:0] expected_d [0:2];
    reg [1:0] expected_c [0:2];
    reg expected_de [0:2];
    reg valid [0:2];
    integer disparity = 0, checked = 0;
    function [9:0] control(input [1:0] value);
        case (value)
            0: control = 10'b1101010100;
            1: control = 10'b0010101011;
            2: control = 10'b0101010100;
            3: control = 10'b1010101011;
        endcase
    endfunction
    task step(input [7:0] data, input enabled, input [1:0] ctl);
        reg [7:0] minimized, decoded;
        integer i, ones, transitions;
        begin
            @(negedge clk);
            for (i = 2; i > 0; i = i - 1) begin
                expected_d[i] = expected_d[i-1]; expected_c[i] = expected_c[i-1];
                expected_de[i] = expected_de[i-1]; valid[i] = valid[i-1];
            end
            d = data; de = enabled; c = ctl;
            expected_d[0] = data; expected_de[0] = enabled; expected_c[0] = ctl; valid[0] = 1;
            @(posedge clk); #1;
            if (valid[2]) begin
                checked = checked + 1;
                if (!expected_de[2]) begin
                    if (q !== control(expected_c[2])) $fatal(1, "control token or latency mismatch: %b", q);
                    disparity = 0;
                end else begin
                    minimized = q[9] ? ~q[7:0] : q[7:0];
                    decoded[0] = minimized[0];
                    transitions = 0;
                    for (i = 1; i < 8; i = i + 1) begin
                        decoded[i] = minimized[i] ^ minimized[i-1] ^ !q[8];
                        transitions = transitions + (minimized[i] != minimized[i-1]);
                    end
                    if (decoded !== expected_d[2]) $fatal(1, "data or latency mismatch: got %h expected %h", decoded, expected_d[2]);
                    if (transitions > 4) $fatal(1, "transition minimizer emitted %0d transitions", transitions);
                    ones = 0;
                    for (i = 0; i < 10; i = i + 1) ones = ones + q[i];
                    disparity = disparity + 2*ones - 10;
                    if (disparity < -8 || disparity > 8) $fatal(1, "unbounded running disparity: %0d", disparity);
                end
            end
        end
    endtask
    integer i, j;
    reg [31:0] lfsr = 32'h1badb002;
    initial begin
        for (i = 0; i < 3; i = i + 1) valid[i] = 0;
        for (i = 0; i < 4; i = i + 1) step(0, 0, i);
        for (j = 0; j < 16; j = j + 1) begin
            for (i = 0; i < 256; i = i + 1) step(i, 1, 0);
            step(0, 0, j[1:0]);
        end
        for (i = 0; i < 1024; i = i + 1) step(i[0] ? 8'hff : 0, 1, 0);
        for (i = 0; i < 65536; i = i + 1) begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            step(lfsr[7:0], lfsr[11:8] != 0, lfsr[13:12]);
        end
        repeat (3) step(0, 0, 0);
        $display("TMDS PASS: %0d decoded words, aligned control/data and bounded disparity", checked);
        $finish;
    end
endmodule
