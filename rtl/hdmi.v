// DVI-over-HDMI output for Gowin GW1N: TMDS encode at pixel clock, 10:1 OSER10 (DDR, 5x clock),
// ELVDS_OBUF differential buffers.
module tmds_enc (
    input            clk,
    input      [7:0] d,
    input      [1:0] c,
    input            de,
    output reg [9:0] q
);
    wire [3:0] n1 = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
    wire xn = n1 > 4 || (n1 == 4 && !d[0]);
    wire [8:0] m;
    assign m[0] = d[0];
    genvar i;
    generate for (i = 1; i < 8; i = i + 1) begin : g
        assign m[i] = xn ? ~(m[i-1] ^ d[i]) : (m[i-1] ^ d[i]);
    end endgenerate
    assign m[8] = !xn;
    wire [3:0] m1 = m[0] + m[1] + m[2] + m[3] + m[4] + m[5] + m[6] + m[7];
    wire signed [5:0] bal = $signed({1'b0, m1, 1'b0}) - 6'sd8;   // #1 - #0
    reg signed [5:0] cnt;
    always @(posedge clk) begin
        if (!de) begin
            cnt <= 0;
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || bal == 0) begin
            q <= {~m[8], m[8], m[8] ? m[7:0] : ~m[7:0]};
            cnt <= m[8] ? cnt + bal : cnt - bal;
        end else if ((cnt > 0 && bal > 0) || (cnt < 0 && bal < 0)) begin
            q <= {1'b1, m[8], ~m[7:0]};
            cnt <= cnt + {4'b0, m[8], 1'b0} - bal;
        end else begin
            q <= {1'b0, m[8], m[7:0]};
            cnt <= cnt - {4'b0, !m[8], 1'b0} + bal;
        end
    end
endmodule

module hdmi_out (
    input        pclk,      // 25.2 MHz
    input        fclk,      // 126 MHz (5x)
    input        rst,
    input  [7:0] r, g, b,
    input        de, hs, vs,
    output       tmds_clk_p, tmds_clk_n,
    output [2:0] tmds_d_p, tmds_d_n
);
    wire [9:0] q0, q1, q2;
    tmds_enc e0 (.clk(pclk), .d(b), .c({vs, hs}), .de(de), .q(q0));
    tmds_enc e1 (.clk(pclk), .d(g), .c(2'b00),    .de(de), .q(q1));
    tmds_enc e2 (.clk(pclk), .d(r), .c(2'b00),    .de(de), .q(q2));

    wire [9:0] qs [0:3];
    assign qs[0] = q0; assign qs[1] = q1; assign qs[2] = q2; assign qs[3] = 10'b0000011111;
    wire [3:0] ser;
    genvar i;
    generate for (i = 0; i < 4; i = i + 1) begin : s
        OSER10 #(.GSREN("false"), .LSREN("true")) o (
            .Q(ser[i]),
            .D0(qs[i][0]), .D1(qs[i][1]), .D2(qs[i][2]), .D3(qs[i][3]), .D4(qs[i][4]),
            .D5(qs[i][5]), .D6(qs[i][6]), .D7(qs[i][7]), .D8(qs[i][8]), .D9(qs[i][9]),
            .PCLK(pclk), .FCLK(fclk), .RESET(rst)
        );
    end endgenerate
    ELVDS_OBUF b0 (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF b1 (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF b2 (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    ELVDS_OBUF bc (.I(ser[3]), .O(tmds_clk_p), .OB(tmds_clk_n));
endmodule
