// Launcher firmware sends A5, index-low, index-high, low^high^5A through
// the core's serial debug port. Explicit host arming prevents game serial
// output from becoming launcher commands. Hold a request until UART takes it.
module menu_bridge (
    input clk,
    input rst,
    input arm,
    input disarm,
    input ser_valid,
    input [7:0] ser_data,
    input take,
    output reg pending,
    output reg [15:0] index,
    output reg armed            // the launcher menu is running (armed by 'M' after its load)
);
    reg [1:0] step;
    always @(posedge clk) begin
        if (rst || disarm) begin
            armed <= 0; step <= 0; pending <= 0; index <= 0;
        end else if (arm) begin
            armed <= 1; step <= 0; pending <= 0;
        end else begin
            if (take) pending <= 0;
            if (armed && !pending && ser_valid) case (step)
                0: if (ser_data == 8'hA5) step <= 1;
                1: begin index[7:0] <= ser_data; step <= 2; end
                2: begin index[15:8] <= ser_data; step <= 3; end
                3: begin
                    if (ser_data == (index[7:0] ^ index[15:8] ^ 8'h5A)) begin
                        pending <= 1; step <= 0;
                    end else step <= ser_data == 8'hA5 ? 1 : 0;
                end
            endcase
        end
    end
endmodule
