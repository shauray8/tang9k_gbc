// 8N1 UART receiver. div = clk / baud, selectable at run time.
module uart_rx (
    input            clk,
    input      [8:0] div,
    input            rx,
    output reg       valid,
    output reg [7:0] data
);
    reg [1:0] sync = 2'b11;
    reg [8:0] cnt;
    reg [3:0] bitn;
    reg busy = 0;
    reg [7:0] sh;
    always @(posedge clk) begin
        sync <= {sync[0], rx};
        valid <= 0;
        if (!busy) begin
            if (!sync[1]) begin busy <= 1; cnt <= div >> 1; bitn <= 0; end
        end else if (cnt != 0) cnt <= cnt - 1;
        else begin
            cnt <= div - 1'b1;
            bitn <= bitn + 1;
            if (bitn == 0) begin if (sync[1]) busy <= 0; end      // false start
            else if (bitn <= 8) sh <= {sync[1], sh[7:1]};
            else begin busy <= 0; if (sync[1]) begin valid <= 1; data <= sh; end end
        end
    end
endmodule
