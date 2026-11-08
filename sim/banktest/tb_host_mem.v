`timescale 1ns/1ps
module tb_host_mem;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1, allow = 0, abort = 0, in_v = 0, tx_room = 1;
    reg [7:0] in_d = 0;
    wire busy, tx_we, m_req, m_we, rtc_load;
    wire [7:0] tx_d, m_wd;
    wire [21:0] m_addr;
    wire [39:0] rtc_d;
    reg [39:0] rtc_q = 40'h0A_1B_17_FE_C1;
    // Bridge model: busy for 9 clocks after each request; read data appears at the end.
    reg [7:0] mem [0:4194303];
    reg [3:0] busy_n = 0;
    reg [7:0] m_rd = 8'hEE;
    reg [21:0] pend_addr;
    wire m_busy = busy_n != 0;
    always @(posedge clk) begin
        if (m_req) begin
            if (m_busy) $fatal(1, "request while bridge busy");
            busy_n <= 9; pend_addr <= m_addr;
            if (m_we) mem[m_addr] <= m_wd;
            m_rd <= 8'hEE;                     // stale until the reply arrives
        end else if (busy_n != 0) begin
            busy_n <= busy_n - 1'b1;
            if (busy_n == 1) m_rd <= mem[pend_addr];
        end
    end
    host_mem dut (.clk(clk), .rst(rst), .allow(allow), .cmd_ok(1'b1), .abort(abort),
        .in_v(in_v), .in_d(in_d), .busy(busy), .tx_ok(tx_room), .tx_we(tx_we), .tx_d(tx_d),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wd(m_wd), .m_busy(m_busy), .m_rd(m_rd),
        .rtc_q(rtc_q), .rtc_load(rtc_load), .rtc_d(rtc_d));

    reg [7:0] out [0:1023];
    integer n_out = 0;
    always @(posedge clk) if (tx_we) begin
        if (!tx_room) $fatal(1, "transmit without room");
        out[n_out] = tx_d; n_out = n_out + 1;
    end
    always @(posedge clk) tx_room <= ($random & 3) != 0;   // UART backpressure

    task send(input [7:0] v);
        begin @(negedge clk); in_d = v; in_v = 1; @(negedge clk); in_v = 0; repeat (20) @(negedge clk); end
    endtask
    task wait_idle; begin while (busy) @(negedge clk); repeat (5) @(negedge clk); end endtask
    integer i; reg [7:0] s;
    reg [39:0] got_rtc;
    always @(posedge clk) if (rtc_load) got_rtc <= rtc_d;
    initial begin
        for (i = 0; i < 4194304; i = i + 1) mem[i] = 8'h00;
        repeat (3) @(negedge clk); rst = 0;
        send("B");
        if (busy) $fatal(1, "command accepted while core running");
        allow = 1;
        // write 300 bytes to cart RAM base + 0x10
        send("B"); send(8'h3E); send(8'h00); send(8'h10); send(8'h01); send(8'h2C);
        s = 0;
        for (i = 0; i < 300; i = i + 1) begin send(i * 7 + 3); s = s + (i * 7 + 3); end
        wait_idle;
        if (n_out != 2 || out[0] != "b" || out[1] != s) $fatal(1, "write reply %h %h", out[0], out[1]);
        for (i = 0; i < 300; i = i + 1)
            if (mem[22'h3E0010 + i] != ((i * 7 + 3) & 255)) $fatal(1, "write data %0d", i);
        if (mem[22'h3E000F] != 0 || mem[22'h3E013C] != 0) $fatal(1, "write overran bounds");
        // read them back under backpressure, with the UART idle timeout asserted throughout:
        // a read receives no host bytes, so the timeout must not cut it short
        n_out = 0;
        send("A"); send(8'h3E); send(8'h00); send(8'h10); send(8'h01); send(8'h2C);
        abort = 1;
        wait_idle;
        abort = 0;
        if (n_out != 301) $fatal(1, "read length %0d", n_out);
        for (i = 0; i < 300; i = i + 1) if (out[i] != ((i * 7 + 3) & 255)) $fatal(1, "read data %0d", i);
        if (out[300] != s) $fatal(1, "read checksum");
        // aborted header leaves the engine idle; next command still works
        n_out = 0;
        send("A"); send(8'h3E);
        abort = 1; @(negedge clk); abort = 0;
        if (busy) $fatal(1, "abort ignored");
        send("T"); wait_idle;
        if (n_out != 6 || out[0] != "T" || {out[1], out[2], out[3], out[4], out[5]} != rtc_q)
            $fatal(1, "clock read");
        n_out = 0;
        send("U"); send(8'd42); send(8'd17); send(8'd23); send(8'hFF); send(8'hC1); wait_idle;
        if (got_rtc != 40'h2A_11_17_FF_C1 || n_out != 1 || out[0] != "u") $fatal(1, "clock load");
        $display("HOST MEM PASS: gated, write/read checksum, bounds, backpressure, abort, clock read/load");
        $finish;
    end
    initial begin #50000000; $fatal(1, "timeout"); end
endmodule
