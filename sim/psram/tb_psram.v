// Actual boot test and byte bridge exercised against an external-pin HyperRAM model.
`timescale 1ps/1ps
module tb #(parameter MEM_FREQ = 81_000_000, STRESS = 0);
    localparam time MEM_HALF_PS = (64'd500_000_000_000 + MEM_FREQ/2) / MEM_FREQ;
    reg mclk = 0, pclk = 0;
    always #(MEM_HALF_PS) mclk = ~mclk;
    always #18519 pclk = ~pclk; // 27 MHz system domain
    reg [7:0] mpor = 0;
    always @(posedge mclk) if (!mpor[7]) mpor <= mpor + 1;
    wire mrst_n = mpor[7];
    reg rst = 1;
    initial begin repeat (20) @(posedge pclk); rst <= 0; end

    integer timeout_us = 1500, deadline_ps = 851852;
    initial begin
        if ($value$plusargs("timeout_us=%d", timeout_us)) ;
        if ($value$plusargs("deadline_ps=%d", deadline_ps)) ;
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
    psram_bridge #(.FREQ(MEM_FREQ)) pb (
        .clk(pclk), .rst(rst), .req(boot ? t_req : req), .we(boot ? t_we : we),
        .addr(boot ? t_addr : addr), .wd(boot ? t_wd : wd), .rd(b_rd),
        .busy(b_busy), .ready(b_ready), .hang(b_hang), .dbg_lat(b_lat), .dbg_word(b_word),
        .mclk(mclk), .mrst_n(mrst_n), .O_psram_ck(ck), .O_psram_ck_n(ck_n),
        .IO_psram_rwds(rwds), .IO_psram_dq(dq), .O_psram_cs_n(cs_n)
    );
    generate if (STRESS) begin: stress_test
        psram_stress mt (
            .clk(pclk), .rst(rst), .ready(b_ready), .busy(b_busy), .rd(b_rd),
            .req(t_req), .we(t_we), .addr(t_addr), .wd(t_wd),
            .done(t_done), .passed(t_pass), .fail_addr(f_addr), .expected(f_exp), .actual(f_act)
        );
    end else begin: boot_test
        psram_test mt (
            .clk(pclk), .rst(rst), .ready(b_ready), .busy(b_busy), .rd(b_rd),
            .req(t_req), .we(t_we), .addr(t_addr), .wd(t_wd),
            .done(t_done), .passed(t_pass), .fail_addr(f_addr), .expected(f_exp), .actual(f_act)
        );
    end endgenerate
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
    // Model the CPU input register and consume it at the next minimum-length
    // double-speed M-cycle: request at cycle 0, din_r at 10, CPU at 11, next request at 12.
    reg [7:0] cpu_sample;
    always @(posedge pclk) cpu_sample <= b_rd;
    task double_speed_stream;
        integer n, idx;
        reg [7:0] expected_mem [0:31];
        begin
            for (n = 0; n < 32; n = n + 1) expected_mem[n] = value(n);
            @(negedge pclk);
            for (n = 0; n < 128; n = n + 1) begin
                if (b_busy) $fatal(1, "double-speed next request would be dropped at transaction %0d", n);
                idx = (n * 13) % 32;
                we = n % 3 == 0; addr = probe(idx); wd = value(idx) ^ n; req = 1;
                if (we) expected_mem[idx] = wd;
                @(posedge pclk);
                @(negedge pclk); req = 0;
                repeat (10) @(posedge pclk);
                if (!we && b_rd !== expected_mem[idx])
                    $fatal(1, "double-speed input-register deadline: address %h got %h expected %h", addr, b_rd, expected_mem[idx]);
                @(posedge pclk);
                if (!we && cpu_sample !== expected_mem[idx])
                    $fatal(1, "double-speed CPU consumed wrong byte at %h", addr);
                @(negedge pclk);
            end
            we = 0;
        end
    endtask

    // Preserve the normal-speed complete-acknowledgement budget. The fast stream
    // separately enforces the tighter CPU data deadline and request-reuse interval.
    time started = 0, max_roundtrip = 0;
    reg prev_busy = 0;
    integer sys_cycles = 0, accepted_cycle = 0;
    always @(posedge pclk) begin
        sys_cycles = sys_cycles + 1;
        prev_busy <= b_busy;
        if (prev_busy && !b_busy) begin
            if (b_lat != sys_cycles-accepted_cycle-1)
                $fatal(1, "reported system round trip does not match request/ack clocks");
            if ($time - started > max_roundtrip) max_roundtrip = $time - started;
            if ($time - started > deadline_ps) $fatal(1, "bus deadline %0d ps exceeded: %0t ps", deadline_ps, $time - started);
        end
        if ((boot ? t_req : req) && !b_busy) begin started = $time; accepted_cycle = sys_cycles; end
    end
    integer i;
    reg [7:0] last_read;
    initial begin
        wait (t_done);
        if (!t_pass) $fatal(1, "boot test failed at %h expected %h got %h", f_addr, f_exp, f_act);
        @(negedge pclk); boot = 0;
        for (i = 0; i < 32; i = i + 1) transfer(1, probe(i), value(i));
        for (i = 0; i < 32; i = i + 1) transfer(0, probe(i), value(i));
        if (MEM_FREQ == 162_000_000) double_speed_stream;
        repeat (4) @(posedge pclk);
        if (ram0.n_setup + ram0.n_hold + ram0.n_xin + ram0.n_proto + ram0.n_contend != 0 || b_hang)
            $fatal(1, "physical protocol error: setup=%0d hold=%0d xin=%0d protocol=%0d contention=%0d hang=%b",
                ram0.n_setup, ram0.n_hold, ram0.n_xin, ram0.n_proto, ram0.n_contend, b_hang);
        // Missing device strobes must release the pins before tCSM, not fabricate an acknowledgement.
        last_read = b_rd;
        force ram0.rwds_pe = 1'b1;
        force ram0.rwds_p = 1'b0;
        @(negedge pclk); we = 0; addr = probe(0); req = 1;
        @(negedge pclk); req = 0;
        #4000000;
        if (!b_busy || b_rd !== last_read || cs_n[0] !== 1'b1 || ck[0] !== 1'b0)
            $fatal(1, "missing-strobe read falsely completed or left memory selected");
        repeat (4100) @(posedge pclk);
        if (!b_hang || !b_busy || b_rd !== last_read)
            $fatal(1, "missing-strobe fault was not retained");
        release ram0.rwds_pe;
        release ram0.rwds_p;
        $display("RESULT PASS stress_bytes=%0d, fast_stream=%0d, byte masks/addressing, timeout release; max_roundtrip=%0t ps",
                 STRESS ? 512 : 8, MEM_FREQ == 162_000_000 ? 128 : 0, max_roundtrip);
        $finish;
    end
    initial begin #(timeout_us * 1000000); $fatal(1, "PSRAM test timed out"); end
endmodule
