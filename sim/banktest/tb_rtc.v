`timescale 1ns/1ps
module tb_rtc;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1, latch_wr = 0, data_wr = 0;
    reg [3:0] select = 0;
    reg [7:0] din = 0;
    wire [7:0] dout;
    mbc3_rtc #(.CLOCK_HZ(64)) dut (
        .clk(clk), .rst(rst), .latch_wr(latch_wr), .data_wr(data_wr),
        .select(select), .din(din), .dout(dout)
    );
    task write_register(input [3:0] regno, input [7:0] value);
        begin
            @(negedge clk); select = regno; din = value; data_wr = 1;
            @(negedge clk); data_wr = 0;
        end
    endtask
    task latch_byte(input [7:0] value);
        begin
            @(negedge clk); din = value; latch_wr = 1;
            @(negedge clk); latch_wr = 0;
        end
    endtask
    task snapshot;
        begin latch_byte(0); latch_byte(1); end
    endtask
    task check(input [3:0] regno, input [7:0] expected);
        begin
            select = regno; #1;
            if (dout !== expected)
                $fatal(1, "RTC register %h: expected %h, got %h", regno, expected, dout);
        end
    endtask
    task cycles(input integer n);
        begin repeat (n) @(negedge clk); end
    endtask
    initial begin
        cycles(2); rst = 0;
        write_register(12, 8'h41); // halted, day bit 8 set
        write_register(8, 58);
        write_register(9, 59);
        write_register(10, 23);
        write_register(11, 255);
        snapshot;
        check(8, 58); check(9, 59); check(10, 23); check(11, 255); check(12, 8'h41);
        cycles(256);
        snapshot; check(8, 58); // halting freezes elapsed time
        write_register(12, 1);
        cycles(64);
        snapshot; check(8, 59); check(9, 59); check(10, 23); check(11, 255); check(12, 1);
        cycles(64);
        // The old snapshot must remain stable while live counters roll over.
        check(8, 59); check(12, 1);
        snapshot;
        check(8, 0); check(9, 0); check(10, 0); check(11, 0); check(12, 8'h80);
        cycles(128);
        snapshot; check(12, 8'h80); // day carry remains sticky
        write_register(12, 8'h40);
        write_register(8, 20);
        snapshot; check(8, 20); check(12, 8'h40); // software clears carry
        write_register(8, 21);
        check(8, 20);
        latch_byte(1); check(8, 20);
        latch_byte(0); latch_byte(2); latch_byte(1); check(8, 20);
        snapshot; check(8, 21);
        cycles(256); snapshot; check(8, 21);
        write_register(12, 0);
        cycles(64); snapshot; check(8, 22); // resumes after clearing halt
        $display("RTC PASS: seconds/minutes/hours/day rollover, sticky carry, halt/resume and snapshots");
        $finish;
    end
    initial begin #100000; $fatal(1, "RTC test timeout"); end
endmodule
