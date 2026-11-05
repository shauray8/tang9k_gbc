// Pin-level behavioral model of one W955D8MBYA-class HyperRAM die (32 Mbit, x8 HyperBus), as embedded
// in the Tang Nano 9K GW1NR-9. Sim only. Driven exclusively by the external pins, so it works with any
// controller/PHY (Gowin ODDR/IDDR or plain fabric registers).
//
// Datasheet behaviour modelled (Winbond W955D8MBYA rev A01-001):
//  * CA: 48 bits on the first 6 CK edges (rising = CA[47:40], ...). CA47 R/W# (1 = read), CA46 address
//    space (1 = register), CA45 burst type (1 = linear, 0 = wrapped per CR0[2:0]); word address
//    A20..A3 = CA[33:16], A2..A0 = CA[2:0]. Reserved bits CA[44:34], CA[15:3] are checked to be zero.
//  * Clock index k counts CK rising edges from 0 (CA occupies k = 0..2). Initial latency counts from
//    k = 2: memory read/write and register read data starts at k = 2 + L (1x) or k = 2 + 2L (2x), with
//    L from CR0[7:4] (0000=5, 0001=6, 1110=3, 1111=4). Register writes have zero latency: data at k = 3.
//  * RWDS during CA (valid tDSV after CS# falls) = 1 for 2x latency. CR0[3]=1 (fixed latency, POR
//    default) always signals 2x; CR0[3]=0 signals 2x only on a refresh collision (+rf_pct / +rf_tx).
//    For writes the device releases RWDS at the end of CA; for reads it keeps driving it (low) and
//    then toggles it edge-aligned with data: byte A (word[15:8]) after CK rising, byte B (word[7:0])
//    after CK falling, both tCKD after the edge.
//  * Write data is centre-aligned: byte A captured on CK rising, byte B on CK falling, RWDS = 1 masks
//    the byte. Register data is never masked. Bursts continue while CK toggles (word address
//    increments, linear or wrapped).
//  * POR CR0 = 8F1F (latency 6, fixed 2x, 32-byte wrap). RESET# low returns to POR state.
//  * Checks: tCSS, tRWR, tCSM, tVCS (150 us after RESET#), input setup/hold (tIS/tIH) on CA and write
//    data/mask, CS# rising with CK high, X/Z on sampled inputs, FPGA/device bus contention.
//
// Board/IO delays: +pin_out_ps (controller pins -> die, applied to CK/CS#/DQ/RWDS alike),
// +pin_ck_ps (extra CK-only delay at the die), +pin_in_ps (die outputs -> controller pins).
// Device timing: +tckd_ps (CK edge -> DQ/RWDS, 1000..5500), +tdsv_ps (CS# fall -> RWDS valid, <= 8000).
// Unwritten bytes read back as +fill=<hex> (default EE). +dev_verbose=0 silences the transaction log.
`timescale 1ps/1ps
module hyperram_model (
    input        ck,
    input        ck_n,          // unused: single-ended model (CK# assumed complementary)
    input        cs_n,
    input        reset_n,
    inout  [7:0] dq,
    inout        rwds
);
    integer t_ckd = 3000, t_dsv = 5000, t_oz = 4000, t_is = 900, t_ih = 900, t_css = 2000;
    integer t_rwr = 36000, t_csm = 4000000, t_vcs = 150000000;
    integer pin_out = 1000, pin_in = 1000, pin_ck = 0;
    integer rf_pct = 0, rf_tx = -1, verbose = 1, seed = 1;
    reg [7:0] fill = 8'hEE;
    initial begin
        if ($value$plusargs("tckd_ps=%d", t_ckd)) ;
        if ($value$plusargs("tdsv_ps=%d", t_dsv)) ;
        if ($value$plusargs("toz_ps=%d", t_oz)) ;
        if ($value$plusargs("pin_out_ps=%d", pin_out)) ;
        if ($value$plusargs("pin_in_ps=%d", pin_in)) ;
        if ($value$plusargs("pin_ck_ps=%d", pin_ck)) ;
        if ($value$plusargs("rf_pct=%d", rf_pct)) ;
        if ($value$plusargs("rf_tx=%d", rf_tx)) ;
        if ($value$plusargs("dev_verbose=%d", verbose)) ;
        if ($value$plusargs("seed=%d", seed)) ;
        if ($value$plusargs("fill=%h", fill)) ;
    end

    // ---------------- board delays ----------------
    reg       ck_d = 0, cs_d = 1, rst_d = 0;
    reg [7:0] dq_d;
    reg       rwds_d;
    always @(ck)      ck_d   <= #(pin_out + pin_ck) ck;
    always @(cs_n)    cs_d   <= #(pin_out) cs_n;
    always @(reset_n) rst_d  <= #(pin_out) reset_n;
    always @(dq)      dq_d   <= #(pin_out) dq;
    always @(rwds)    rwds_d <= #(pin_out) rwds;

    reg [7:0] dq_o = 0;  reg dq_oe = 0;     // at the die
    reg rwds_o = 0;      reg rwds_oe = 0;
    reg [7:0] dq_p = 0;  reg dq_pe = 0;     // at the controller pins
    reg rwds_p = 0;      reg rwds_pe = 0;
    always @(dq_o)    dq_p    <= #(pin_in) dq_o;
    always @(dq_oe)   dq_pe   <= #(pin_in) dq_oe;
    always @(rwds_o)  rwds_p  <= #(pin_in) rwds_o;
    always @(rwds_oe) rwds_pe <= #(pin_in) rwds_oe;
    assign dq   = dq_pe   ? dq_p   : 8'bz;
    assign rwds = rwds_pe ? rwds_p : 1'bz;

    // ---------------- output scheduling (transport delay, cancelled by a new transaction) ----------
    integer gen = 0;                       // transaction generation
    reg [32+1+8-1:0] dq_ev;                // {gen, oe, data}
    reg [32+1+1-1:0] rw_ev;                // {gen, oe, value}
    reg out_released = 1;
    always @(dq_ev) if (dq_ev[40:9] == gen && !out_released) begin dq_oe = dq_ev[8]; dq_o = dq_ev[7:0]; end
    always @(rw_ev) if (rw_ev[33:2] == gen && !out_released) begin rwds_oe = rw_ev[1]; rwds_o = rw_ev[0]; end
    task sched_dq(input integer dly, input oe, input [7:0] v);
        dq_ev <= #(dly) {gen[31:0], oe, v};
    endtask
    task sched_rw(input integer dly, input oe, input v);
        rw_ev <= #(dly) {gen[31:0], oe, v};
    endtask

    // ---------------- state ----------------
    reg [15:0] mem [0:(1<<21)-1];
    reg [15:0] cr0, cr1;
    integer tx = -1;                       // transaction counter (0 = first CS# after reset)
    reg active = 0;
    integer edge_n, clk_idx, data_clk, nwords, lat;
    reg [47:0] ca;
    reg rf, is_read, is_reg, linear;
    reg [20:0] wa, wa0;
    reg [15:0] cur;
    reg [7:0] byte_a; reg mask_a;
    reg [8*64-1:0] dlog;                   // data log for the transaction summary
    integer nlog;
    time t_cs_fall = 0, t_cs_rise = 0, t_rst_rise = 0, t_dq_chg = 0, t_rw_chg = 0, t_sample = 0;
    reg sample_dq = 0, sample_rw = 0;
    integer n_setup = 0, n_hold = 0, n_xin = 0, n_proto = 0, n_contend = 0;

    function integer cr_lat(input [3:0] c);
        case (c) 4'b0000: cr_lat = 5; 4'b0001: cr_lat = 6; 4'b1110: cr_lat = 3; 4'b1111: cr_lat = 4;
            default: cr_lat = 6; endcase
    endfunction
    function [7:0] rd_byte(input [7:0] b);
        rd_byte = (^b === 1'bx) ? fill : b;
    endfunction
    function [20:0] next_wa(input [20:0] a);
        integer g;
        begin
            case (cr0[1:0]) 2'b00: g = 64; 2'b01: g = 32; 2'b10: g = 8; default: g = 16; endcase
            next_wa = linear ? a + 1 : ((a & ~(g - 1)) | ((a + 1) & (g - 1)));
        end
    endfunction

    task por;
        begin cr0 = 16'h8F1F; cr1 = 16'hFFC1; active = 0; gen = gen + 1; out_released = 1;
            dq_oe = 0; rwds_oe = 0; end
    endtask
    initial por;
    always @(rst_d) if (rst_d === 1'b0) por; else if (rst_d === 1'b1) t_rst_rise = $time;

    // input change tracking (hold checks)
    always @(dq_d) begin
        if (sample_dq && $time - t_sample < t_ih) begin
            n_hold = n_hold + 1;
            if (n_hold <= 8) $display("[hram %0t] HOLD violation DQ changed %0d ps after sampling edge (tx %0d)", $time, $time - t_sample, tx);
        end
        t_dq_chg = $time;
    end
    always @(rwds_d) begin
        if (sample_rw && $time - t_sample < t_ih) begin
            n_hold = n_hold + 1;
            if (n_hold <= 8) $display("[hram %0t] HOLD violation RWDS changed %0d ps after sampling edge (tx %0d)", $time, $time - t_sample, tx);
        end
        t_rw_chg = $time;
    end
    // contention: both ends driving the pins
    always @(dq or rwds) if ((dq_pe && (^dq === 1'bx)) || (rwds_pe && rwds === 1'bx)) begin
        n_contend = n_contend + 1;
        if (n_contend <= 4) $display("[hram %0t] CONTENTION/X on pins while die drives (dq=%b rwds=%b, tx %0d)", $time, dq, rwds, tx);
    end

    task check_setup(input chk_rw);
        begin
            if ($time - t_dq_chg < t_is || (chk_rw && $time - t_rw_chg < t_is)) begin
                n_setup = n_setup + 1;
                if (n_setup <= 8) $display("[hram %0t] SETUP violation (dq %0d ps, rwds %0d ps before edge; tx %0d edge %0d)",
                    $time, $time - t_dq_chg, $time - t_rw_chg, tx, edge_n);
            end
            if (^dq_d === 1'bx || (chk_rw && rwds_d !== 1'b0 && rwds_d !== 1'b1)) begin
                n_xin = n_xin + 1;
                if (n_xin <= 8) $display("[hram %0t] X/Z sampled dq=%b rwds=%b (tx %0d edge %0d)", $time, dq_d, rwds_d, tx, edge_n);
            end
            t_sample = $time; sample_dq = 1; sample_rw = chk_rw;
        end
    endtask

    // ---------------- CS# ----------------
    always @(cs_d) if (rst_d === 1'b1) begin
        if (cs_d === 1'b0) begin
            tx = tx + 1; gen = gen + 1; out_released = 0;
            active = 1; edge_n = 0; clk_idx = -1; ca = 0; nwords = 0; nlog = 0; dlog = 0;
            sample_dq = 0; sample_rw = 0;
            if ($time - t_cs_rise < t_rwr && tx > 0) begin
                n_proto = n_proto + 1;
                $display("[hram %0t] tRWR violation: CS# high only %0d ps", $time, $time - t_cs_rise);
            end
            if ($time - t_rst_rise < t_vcs) begin
                n_proto = n_proto + 1;
                $display("[hram %0t] tVCS violation: access %0d ns after RESET# release", $time, ($time - t_rst_rise) / 1000);
            end
            t_cs_fall = $time;
            rf = cr0[3] ? 1'b1 : (tx == rf_tx) || (rf_pct > 0 && ({$random(seed)} % 100) < rf_pct);
            sched_rw(t_dsv, 1'b1, rf);
        end else if (cs_d === 1'b1 && active) begin
            active = 0; t_cs_rise = $time; sample_dq = 0; sample_rw = 0;
            if (ck_d !== 1'b0) begin
                n_proto = n_proto + 1;
                $display("[hram %0t] CS# rose with CK=%b", $time, ck_d);
            end
            if ($time - t_cs_fall > t_csm) begin
                n_proto = n_proto + 1;
                $display("[hram %0t] tCSM violation: CS# low %0d ns", $time, ($time - t_cs_fall) / 1000);
            end
            sched_dq(t_oz, 1'b0, 8'h00); sched_rw(t_oz, 1'b0, 1'b0);
            out_release_after(t_oz);
            if (verbose) summary;
        end
    end
    task out_release_after(input integer dly);
        fork : rel
            begin : r
                integer g; g = gen;
                #(dly);
                if (g == gen) begin out_released = 1; dq_oe = 0; rwds_oe = 0; end
            end
        join_none
    endtask

    task summary;
        integer i;
        begin
            if (edge_n < 6)
                $display("[hram %0t] tx %0d: aborted after %0d CA edges (CA so far %h)", $time, tx, edge_n, ca);
            else begin
                $write("[hram %0t] tx %0d: %s %s wa=%06h (byte %06h) CA=%012h lat=%0dx%0d data@clk%0d clocks=%0d words=%0d",
                    $time, tx, is_read ? "RD" : "WR", is_reg ? "REG" : "MEM", wa0, {wa0, 1'b0}, ca, lat, rf ? 2 : 1,
                    data_clk, clk_idx + 1, nwords);
                for (i = 0; i < nlog && i < 8; i = i + 1) $write(" %h", dlog[i*64 +: 24]);
                $write("\n");
            end
        end
    endtask
    // dlog entry: {mask_a, mask_b, ..., A, B} packed as 24 bits: [23:16]=flags [15:0]=word

    // ---------------- CK ----------------
    always @(ck_d) if (active && rst_d === 1'b1 && cs_d === 1'b0 && (ck_d === 1'b0 || ck_d === 1'b1)) on_edge(ck_d);

    task on_edge(input rising);
        begin
            if (rising) begin
                clk_idx = clk_idx + 1;
                if (clk_idx == 0 && $time - t_cs_fall < t_css) begin
                    n_proto = n_proto + 1;
                    $display("[hram %0t] tCSS violation: first CK rise %0d ps after CS#", $time, $time - t_cs_fall);
                end
            end
            if (clk_idx < 0) begin
                // falling edge before the first rising edge: ignored
            end else if (edge_n < 6) begin
                check_setup(1'b0);
                ca = {ca[39:0], dq_d};
                edge_n = edge_n + 1;
                if (edge_n == 6) decode;
            end else if (clk_idx >= data_clk) begin
                if (is_read) read_edge(rising);
                else write_edge(rising);
            end else begin
                sample_dq = 0; sample_rw = 0;      // latency clocks: inputs are don't-care
            end
        end
    endtask

    task decode;
        begin
            is_read = ca[47]; is_reg = ca[46]; linear = ca[45];
            wa = {ca[33:16], ca[2:0]}; wa0 = wa;
            lat = cr_lat(cr0[7:4]);
            if (ca[44:34] != 0 || ca[15:3] != 0) begin
                n_proto = n_proto + 1;
                $display("[hram %0t] tx %0d: reserved CA bits set (CA=%012h)", $time, tx, ca);
            end
            if (is_reg && !is_read) data_clk = 3;
            else data_clk = 2 + lat * (rf ? 2 : 1);
            if (is_read) sched_rw(t_ckd, 1'b1, 1'b0);   // keep driving RWDS, low during latency
            else         sched_rw(t_ckd, 1'b0, 1'b0);   // release RWDS at the end of CA
        end
    endtask

    task read_edge(input rising);
        begin
            sample_dq = 0; sample_rw = 0;
            if (rising) begin
                if (is_reg) cur = ca[0] ? cr1 : (ca[24] ? cr0 : 16'h0C81);   // CR0/CR1 or ID0
                else cur = {rd_byte(mem[wa][15:8]), rd_byte(mem[wa][7:0])};
                sched_dq(t_ckd, 1'b1, cur[15:8]);
                sched_rw(t_ckd, 1'b1, 1'b1);
            end else begin
                sched_dq(t_ckd, 1'b1, cur[7:0]);
                sched_rw(t_ckd, 1'b1, 1'b0);
                if (nlog < 8) dlog[nlog*64 +: 24] = {8'h00, cur};
                nlog = nlog + 1; nwords = nwords + 1;
                wa = next_wa(wa);
            end
        end
    endtask

    task write_edge(input rising);
        reg mask_b;
        begin
            check_setup(!is_reg);
            if (rising) begin
                byte_a = dq_d; mask_a = is_reg ? 1'b0 : rwds_d;
            end else begin
                mask_b = is_reg ? 1'b0 : rwds_d;
                if (is_reg) begin
                    if (nwords == 0) begin
                        if (ca[0]) cr1 = {byte_a, dq_d};
                        else if (ca[24]) cr0 = {byte_a, dq_d};
                        if (verbose) $display("[hram %0t] %s <= %h (latency %0d, %s latency)", $time,
                            ca[0] ? "CR1" : "CR0", {byte_a, dq_d}, cr_lat(cr0[7:4]), cr0[3] ? "fixed 2x" : "variable");
                    end
                end else begin
                    // undefined mask (RWDS floating/X) is treated as "written": worst case
                    if (mask_a !== 1'b1) mem[wa][15:8] = byte_a;
                    if (mask_b !== 1'b1) mem[wa][7:0] = dq_d;
                    wa = next_wa(wa);
                end
                if (nlog < 8) dlog[nlog*64 +: 24] = {2'b0, mask_a === 1'bx, mask_a === 1'b1, 2'b0, mask_b === 1'bx, mask_b === 1'b1, byte_a, dq_d};
                nlog = nlog + 1; nwords = nwords + 1;
            end
        end
    endtask

    // ---------------- helpers for benches ----------------
    function [15:0] peek(input [20:0] a);
        peek = mem[a];
    endfunction
endmodule
