// Actual boot test and byte bridge exercised against an external-pin HyperRAM model.
`timescale 1ps/1ps
module tb;
    reg mclk = 0, pclk = 0;
    always #6173 mclk = ~mclk;
    always #19841 pclk = ~pclk;
    reg [7:0] mpor = 0;
    always @(posedge mclk) if (!mpor[7]) mpor <= mpor + 1;
    wire mrst_n = mpor[7];
    reg rst = 1;
    initial begin repeat (20) @(posedge pclk); rst <= 0; end

    integer timeout_us = 1500;
    initial begin
        if ($value$plusargs("timeout_us=%d", timeout_us)) ;
    end
    wire [1:0] ck, ck_n, cs_n, rwds;
    wire [15:0] dq;
    wire t_req, t_we, b_busy, b_ready, b_hang, t_done, t_pass;
    wire [21:0] t_addr, f_addr;
    wire [7:0] t_wd, b_rd, b_lat, f_exp, f_act;
    wire [15:0] b_word;
    reg boot = 1, req = 0, we = 0;
    reg [21:0] addr = 0;
    reg [7:0] wd = 0;
    psram_bridge pb (
        .clk(pclk), .rst(rst), .req(boot ? t_req : req), .we(boot ? t_we : we),
        .addr(boot ? t_addr : addr), .wd(boot ? t_wd : wd), .rd(b_rd),
        .busy(b_busy), .ready(b_ready), .hang(b_hang), .dbg_lat(b_lat), .dbg_word(b_word),
        .mclk(mclk), .mrst_n(mrst_n), .O_psram_ck(ck), .O_psram_ck_n(ck_n),
        .IO_psram_rwds(rwds), .IO_psram_dq(dq), .O_psram_cs_n(cs_n)
    );
    psram_test mt (
        .clk(pclk), .rst(rst), .ready(b_ready), .busy(b_busy), .rd(b_rd),
        .req(t_req), .we(t_we), .addr(t_addr), .wd(t_wd),
        .done(t_done), .passed(t_pass), .fail_addr(f_addr), .expected(f_exp), .actual(f_act)
    );
    hyperram_model ram0 (
        .ck(ck[0]), .ck_n(ck_n[0]), .cs_n(cs_n[0]), .reset_n(mrst_n), .dq(dq[7:0]), .rwds(rwds[0])
    );
    always @(posedge pclk) if (mrst_n && cs_n[1] !== 1'b1) $fatal(1, "unused die selected");

    // Distinct bytes on both sides of cartridge bank boundaries and at every
    // address bit. Write all before reading any to expose address aliasing.
    function [21:0] probe(input integer n);
        case (n)
            22: probe = 22'h003fff;
            23: probe = 22'h004001;
            24: probe = 22'h007fff;
            25: probe = 22'h008001;
            26: probe = 22'h01ffff;
            27: probe = 22'h020001;
            28: probe = 22'h3dffff;
            29: probe = 22'h3e0000;
            30: probe = 22'h3ffffe;
            31: probe = 22'h3fffff;
            default: probe = 22'b1 << n;
        endcase
    endfunction
    function [7:0] value(input integer n);
        value = 8'h69 ^ (n * 7);
    endfunction
    task transfer(input wr, input [21:0] a, input [7:0] d);
        begin
            @(negedge pclk); we = wr; addr = a; wd = d; req = 1;
            @(negedge pclk); req = 0;
            if (!b_busy) $fatal(1, "request not accepted");
            wait (!b_busy);
            @(negedge pclk);
            if (!wr && b_rd !== d) $fatal(1, "read %h expected %h got %h", a, d, b_rd);
        end
    endtask

    // Data must arrive two pixel clocks before the shortest DMG M-cycle
    // (23 pixel clocks). Include the full request/acknowledge CDC round trip.
    time started = 0, max_roundtrip = 0;
    reg prev_busy = 0;
    always @(posedge pclk) begin
        prev_busy <= b_busy;
        if ((boot ? t_req : req) && !b_busy) started = $time;
        if (prev_busy && !b_busy) begin
            if ($time - started > max_roundtrip) max_roundtrip = $time - started;
            if ($time - started > 833333) $fatal(1, "DMG bus deadline exceeded: %0t ps", $time - started);
        end
    end
    integer i;
    initial begin
        wait (t_done);
        if (!t_pass) $fatal(1, "boot test failed at %h expected %h got %h", f_addr, f_exp, f_act);
        @(negedge pclk); boot = 0;
        for (i = 0; i < 32; i = i + 1) transfer(1, probe(i), value(i));
        for (i = 0; i < 32; i = i + 1) transfer(0, probe(i), value(i));
        repeat (4) @(posedge pclk);
        if (ram0.n_setup + ram0.n_hold + ram0.n_xin + ram0.n_proto + ram0.n_contend != 0 || b_hang)
            $fatal(1, "physical protocol error: setup=%0d hold=%0d xin=%0d protocol=%0d contention=%0d hang=%b",
                ram0.n_setup, ram0.n_hold, ram0.n_xin, ram0.n_proto, ram0.n_contend, b_hang);
        $display("RESULT PASS boot, byte masks, address bits, bank boundaries; max_roundtrip=%0t ps", max_roundtrip);
        $finish;
    end
    initial begin #(timeout_us * 1000000); $fatal(1, "PSRAM test timed out"); end
endmodule
