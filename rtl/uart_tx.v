// 8N1 UART transmitter with a 16-entry FIFO (15 usable). div = clk / baud, run-time selectable.
// ready = FIFO has room: a write with we && ready is accepted; writes while !ready are dropped.
// idle = FIFO empty and the line back at the stop bit: safe to change div.
module uart_tx (
    input            clk,
    input            rst,
    input      [8:0] div,
    input            we,
    input      [7:0] wd,
    output           ready,
    output           idle,
    output reg       tx
);
    reg [7:0] fifo [0:15];
    reg [3:0] wp, rp;
    reg [9:0] sh;
    reg [3:0] n;
    reg [8:0] cnt;
    assign ready = wp + 4'd1 != rp;
    assign idle = rp == wp && n == 0 && cnt == 0;
    always @(posedge clk) begin
        if (rst) begin wp <= 0; rp <= 0; n <= 0; tx <= 1; cnt <= 0; end
        else begin
            if (we && ready) begin fifo[wp] <= wd; wp <= wp + 1; end
            if (cnt != 0) cnt <= cnt - 1;
            else if (n != 0) begin
                tx <= sh[0]; sh <= sh >> 1; n <= n - 1; cnt <= div - 1'b1;
            end else if (rp != wp) begin
                sh <= {1'b1, fifo[rp], 1'b0}; rp <= rp + 1; n <= 10;
            end
        end
    end
endmodule
