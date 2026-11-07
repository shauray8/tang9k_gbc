`timescale 1ns/1ps
module tb_bridge;
    reg clk=0;
    always #5 clk=!clk;
    reg rst=1, arm=0, disarm=0, valid=0, take=0;
    reg [7:0] data=0;
    wire pending;
    wire [15:0] index;
    menu_bridge dut (.clk(clk), .rst(rst), .arm(arm), .disarm(disarm),
        .ser_valid(valid), .ser_data(data), .take(take), .pending(pending), .index(index));
    task send(input [7:0] value);
        begin
            @(negedge clk); data=value; valid=1;
            @(negedge clk); valid=0;
        end
    endtask
    task request(input [15:0] n);
        begin send(8'hA5); send(n[7:0]); send(n[15:8]); send(n[7:0]^n[15:8]^8'h5A); end
    endtask
    initial begin
        @(negedge clk); rst=0;
        request(16'h0103);
        if(pending) $fatal(1,"game serial output triggered an unarmed launcher");
        arm=1; @(negedge clk); arm=0;
        send(8'hA5); send(3); send(1); send(0);
        if(pending) $fatal(1,"invalid checksum accepted");
        request(16'h0103);
        if(!pending || index!=16'h0103) $fatal(1,"valid bank-crossing selection lost");
        request(16'h0204);
        if(!pending || index!=16'h0103) $fatal(1,"pending request changed under UART backpressure");
        take=1; @(negedge clk); take=0;
        if(pending) $fatal(1,"consumed request repeated");
        send(8'hA5); send(8'h99);
        disarm=1; @(negedge clk); disarm=0;
        send(0); send(8'hC3); request(16'h1234);
        if(pending) $fatal(1,"partial request survived game load/disarm");
        arm=1; @(negedge clk); arm=0;
        request(16'hFFFF);
        if(!pending || index!=16'hFFFF) $fatal(1,"16-bit index truncated");
        rst=1; @(negedge clk); rst=0;
        if(pending) $fatal(1,"reset left pending request");
        $display("MENU BRIDGE PASS: arming, checksum, backpressure, disarm and index width");
        $finish;
    end
endmodule
