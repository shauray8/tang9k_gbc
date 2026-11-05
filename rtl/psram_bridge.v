// Byte-wide request bridge from the 25.2 MHz system domain to the 81 MHz PsramController.
// Toggle handshake: address/data are held stable in the system domain from `req` until the
// acknowledge returns, so only the toggle bits cross clock domains.
// The memory clock is mclk/4; fixed-latency transactions complete before the next
// DMG M-cycle. The pin-level simulation checks the complete CDC round-trip budget.
module psram_bridge (
    // system domain
    input             clk,
    input             rst,
    input             req,          // 1-clk pulse; ignored while busy
    input             we,
    input      [21:0] addr,
    input      [7:0]  wd,
    output reg [7:0]  rd,           // last read byte (held)
    output            busy,
    output            ready,        // PSRAM initialised
    output reg        hang,         // sticky: a request never completed (diagnostics)
    output reg [7:0]  dbg_lat,      // PSRAM-clock cycles taken by the last request (diagnostics)
    output reg [15:0] dbg_word,     // raw word of the last read (diagnostics)
    output [7:0]      dbg_state,
    // PSRAM domain
    input             mclk,
    input             mrst_n,
    output [1:0]      O_psram_ck,
    output [1:0]      O_psram_ck_n,
    inout  [1:0]      IO_psram_rwds,
    inout  [15:0]     IO_psram_dq,
    output [1:0]      O_psram_cs_n
);
    // ---------------- system domain ----------------
    reg rq_t, pend;
    reg [21:0] a_h; reg [7:0] d_h; reg we_h;
    reg [2:0] ak_s;
    reg [1:0] rdy_s;
    wire [7:0] m_data;
    wire [15:0] c_dout;
    reg ak_t;
    reg m_ready;
    assign busy = pend;
    assign ready = rdy_s[1];
    reg [11:0] pend_cnt;          // diagnostics: a request outstanding > 4096 clk (~160 us) never completes
    always @(posedge clk) begin
        ak_s <= {ak_s[1:0], ak_t};
        rdy_s <= {rdy_s[0], m_ready};
        if (rst) begin
            rq_t <= 0; pend <= 0; hang <= 0; pend_cnt <= 0;
            rd <= 0; dbg_word <= 0; ak_s <= 0; rdy_s <= 0;
        end
        else begin
            pend_cnt <= pend ? pend_cnt + (pend_cnt != 12'hFFF) : 12'd0;
            if (pend_cnt == 12'hFFF) hang <= 1;
            if (pend && ak_s[2] != ak_s[1]) begin
                pend <= 0; rd <= m_data;
                // The controller holds this word until the next read. The
                // synchronized acknowledgement makes it stable here, like m_data.
                if (!we_h) dbg_word <= c_dout;
            end
            if (req && !pend) begin
                a_h <= addr; d_h <= wd; we_h <= we; rq_t <= ~rq_t; pend <= 1;
            end
        end
    end

    // ---------------- PSRAM domain ----------------
    reg [2:0] rq_s;
    reg [1:0] st;
    reg c_rd, c_wr;
    reg [7:0] m_q;
    assign m_data = m_q;
    wire c_busy;
    always @(posedge mclk) begin
        rq_s <= {rq_s[1:0], rq_t};
        c_rd <= 0; c_wr <= 0;
        if (!mrst_n) begin st <= 0; ak_t <= 0; m_ready <= 0; rq_s <= 0; end
        else begin
            if (!c_busy) m_ready <= 1;
            if (st != 2'd0 && dbg_lat != 8'hFF) dbg_lat <= dbg_lat + 1;
            case (st)
                2'd0: if (m_ready && rq_s[2] != rq_s[1] && !c_busy) begin
                          c_rd <= !we_h; c_wr <= we_h; st <= 2'd1; dbg_lat <= 0;
                      end
                2'd1: st <= 2'd2;                       // controller registers the command
                2'd2: if (!c_busy) st <= 2'd3;
                2'd3: begin
                    m_q <= a_h[0] ? c_dout[15:8] : c_dout[7:0];
                    ak_t <= ~ak_t; st <= 2'd0;
                end
            endcase
        end
    end

    PsramController #(.FREQ(81_000_000), .LATENCY(3)) ctl (
        .clk(mclk), .resetn(mrst_n),
        .read(c_rd), .write(c_wr), .addr(a_h), .din({d_h, d_h}), .byte_write(1'b1),
        .dout(c_dout), .busy(c_busy),
        .debug(dbg_state),
        .O_psram_ck(O_psram_ck), .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n)
    );
endmodule
