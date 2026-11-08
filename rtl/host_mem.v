// Host access to cartridge RAM and MBC3 clock state over the USB-UART.
// Only runs while the Game Boy is frozen (`allow`), so the core never observes
// host-modified bus data mid-access. Only the 128 KiB save area 3E0000-3FFFFF is reachable:
// address bits 21-17 of a request are ignored.
//   'A' a2 a1 a0 nh nl : read n bytes (0 = 65536) -> n data bytes, then 8-bit sum
//   'B' a2 a1 a0 nh nl <n bytes> : write -> 'b' <8-bit sum>
//   'T'                : -> 'T' sec min hour day-low day-high (live MBC3 clock)
//   'U' sec min hour day-low day-high : load the live MBC3 clock -> 'u'
// Commands arriving while not allowed are ignored; an idle UART gap aborts a partial command.
module host_mem (
    input             clk,
    input             rst,
    input             allow,
    input             cmd_ok,       // top-level parser idle: no reply or capture in flight
    input             abort,        // UART idle timeout
    input             in_v,
    input      [7:0]  in_d,
    output            busy,         // owns the UART input stream
    input             tx_ok,
    output            tx_we,
    output reg [7:0]  tx_d,
    output            m_req,
    output            m_we,
    output     [21:0] m_addr,
    output     [7:0]  m_wd,
    input             m_busy,
    input      [7:0]  m_rd,
    input      [39:0] rtc_q,
    output reg        rtc_load,
    output     [39:0] rtc_d
);
    localparam IDLE = 3'd0, HDR = 3'd1, RD_ISSUE = 3'd2, RD_WAIT = 3'd3, RD_SEND = 3'd4,
               WR = 3'd5, TAG = 3'd6, PAYLOAD = 3'd7;
    localparam K_READ = 2'd0, K_WRITE = 2'd1, K_LOAD = 2'd2, K_CLOCK = 2'd3;
    reg [2:0] st;
    reg [1:0] kind;
    reg [2:0] cnt;                // header bytes still expected / payload bytes still to send
    reg [39:0] hdr;               // shift-in only: header, then the clock value for 'U'
    reg [16:0] addr, left;
    reg [7:0] sum, data, tag;
    reg slot_v;
    assign busy = st != IDLE;
    assign m_req = (st == RD_ISSUE && !m_busy) || (st == WR && slot_v && !m_busy);
    assign m_we = st == WR;
    assign m_addr = {5'b11111, addr};
    assign m_wd = data;
    assign rtc_d = hdr;
    // Same-cycle handshake: a byte is offered only while the UART FIFO has room.
    assign tx_we = tx_ok && (st == RD_SEND || st == TAG || st == PAYLOAD);
    always @(*) begin
        if (st == RD_SEND) tx_d = data;
        else if (st == TAG) tx_d = tag;
        else if (kind != K_CLOCK) tx_d = sum;
        else case (cnt)
            3'd5: tx_d = rtc_q[39:32];
            3'd4: tx_d = rtc_q[31:24];
            3'd3: tx_d = rtc_q[23:16];
            3'd2: tx_d = rtc_q[15:8];
            default: tx_d = rtc_q[7:0];
        endcase
    end

    always @(posedge clk) begin
        rtc_load <= 0;
        if (rst || (abort && st != IDLE && st != TAG && st != PAYLOAD)) begin
            st <= IDLE; slot_v <= 0;
        end else case (st)
            IDLE: if (in_v && cmd_ok && allow) case (in_d)
                "A": begin st <= HDR; kind <= K_READ; cnt <= 5; end
                "B": begin st <= HDR; kind <= K_WRITE; cnt <= 5; end
                "U": begin st <= HDR; kind <= K_LOAD; cnt <= 5; end
                "T": begin st <= TAG; kind <= K_CLOCK; tag <= "T"; cnt <= 5; end
                default: ;
            endcase
            HDR: if (in_v) begin
                hdr <= {hdr[31:0], in_d};
                cnt <= cnt - 1'b1;
                if (cnt == 1) begin
                    sum <= 0; slot_v <= 0;
                    addr <= hdr[24:8];   // a2[0] a1 a0; hdr[7:0] is the length high byte
                    left <= {hdr[7:0], in_d} == 0 ? 17'h10000 : {1'b0, hdr[7:0], in_d};
                    if (kind == K_LOAD) begin
                        rtc_load <= 1;   // hdr holds all five clock bytes from the next cycle
                        st <= TAG; tag <= "u";
                    end else st <= kind == K_READ ? RD_ISSUE : WR;
                end
            end
            RD_ISSUE: if (!m_busy) st <= RD_WAIT;
            RD_WAIT: if (!m_busy) begin data <= m_rd; st <= RD_SEND; end
            RD_SEND: if (tx_ok) begin
                sum <= sum + data;
                addr <= addr + 1'b1; left <= left - 1'b1;
                if (left == 1) begin st <= TAG; tag <= sum + data; end
                else st <= RD_ISSUE;
            end
            WR: begin
                if (in_v && !slot_v && left != 0) begin data <= in_d; slot_v <= 1; end
                if (m_req) begin
                    slot_v <= 0; sum <= sum + data;
                    addr <= addr + 1'b1; left <= left - 1'b1;
                end
                if (left == 0 && !slot_v && !m_busy && !m_req) begin
                    st <= TAG; tag <= "b"; cnt <= 1;
                end
            end
            TAG: if (tx_ok) st <= cnt != 0 ? PAYLOAD : IDLE;
            PAYLOAD: if (tx_ok) begin
                cnt <= cnt - 1'b1;
                if (cnt == 1) st <= IDLE;
            end
        endcase
    end
endmodule
