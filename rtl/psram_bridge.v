// Byte request bridge from the 27 MHz system domain to the memory fabric.
// Request and acknowledgement toggles cross through synchronizers; payloads are held stable.
// Read data is sampled continuously, then sampled again by the CPU's din_r register.
// The fixed CPU deadline, rather than acknowledgement latency, determines when it may be used.
// Requests wait through controller recovery even when the previous response returned early.
module psram_bridge #(parameter FREQ = 81_000_000) (
    // system domain
    input             clk,
    input             rst,
    input             req,          // 1-clk pulse; ignored while busy
    input             we,
    input      [21:0] addr,
    input      [7:0]  wd,
    output reg [7:0]  rd,           // synchronized read data; stable by the verified bus deadline
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
        rd <= m_data;
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
                pend <= 0;
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
    reg [1:0] rq_s;
    reg rq_seen;
    reg [1:0] st;
    reg c_req;
    reg [7:0] m_q;
    assign m_data = m_q;
    wire c_busy, c_valid;
    reg can_launch;
    always @(posedge mclk)
        if (!mrst_n) can_launch <= 0;
        else can_launch <= st == 0 && m_ready && !c_busy;
    wire launch = can_launch && rq_s[1] != rq_seen;
    reg capture_read;
    always @(posedge mclk)
        if (!mrst_n) capture_read <= 0;
        else capture_read <= st == 2 && c_valid && !we_h;
    // Capture one fabric clock after response detection. The source keeps its
    // payload until the synchronized acknowledgement returns, so the byte select
    // and controller word remain stable across this short pipeline stage.
    always @(posedge mclk)
        if (capture_read) m_q <= a_h[0] ? c_dout[15:8] : c_dout[7:0];
    reg counting, lat_full, lat_carry;
    // Registered lookahead keeps saturation and inter-nibble carry off the feedback path.
    always @(posedge mclk) begin
        if (!mrst_n) begin
            dbg_lat <= 0; counting <= 0; lat_full <= 0; lat_carry <= 0;
        end else if (c_req) begin
            // Command is registered one edge after launch; start at one so the
            // completed diagnostic remains launch-relative without launch fanout.
            dbg_lat <= 1; counting <= 1; lat_full <= 0; lat_carry <= 0;
        end else begin
            if (counting && !lat_full) begin
                dbg_lat[3:0] <= dbg_lat[3:0] + 1'b1;
                if (lat_carry) dbg_lat[7:4] <= dbg_lat[7:4] + 1'b1;
                lat_carry <= dbg_lat[3:0] == 4'he;
                lat_full <= dbg_lat == 8'hfe;
            end
            if (st == 2 && c_valid) counting <= 0;
        end
    end
    // One command pulse; write-enable is held with the request payload.
    always @(posedge mclk) c_req <= mrst_n && launch;
    always @(posedge mclk) begin
        rq_s <= {rq_s[0], rq_t};
        if (!mrst_n) begin st <= 0; ak_t <= 0; m_ready <= 0; rq_s <= 0; rq_seen <= 0; end
        else begin
            if (!c_busy) m_ready <= 1;
            case (st)
                2'd0: if (launch) begin
                          st <= 2'd1;
                          rq_seen <= rq_s[1];
                      end
                2'd1: st <= 2'd2;                       // controller registers the command
                2'd2: if (c_valid) begin
                    ak_t <= ~ak_t; st <= 2'd0;
                end
            endcase
        end
    end

    PsramController #(.FREQ(FREQ), .LATENCY(3)) ctl (
        .clk(mclk), .resetn(mrst_n),
        .req(c_req), .we(we_h), .addr(a_h), .din({d_h, d_h}), .byte_write(1'b1),
        .dout(c_dout), .busy(c_busy), .response_valid(c_valid),
        .debug(dbg_state),
        .O_psram_ck(O_psram_ck), .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n)
    );
endmodule
