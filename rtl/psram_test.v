// Destructive boot test, before ROM loading. Stops at the first mismatch.
module psram_test (
    input clk, rst, ready, busy,
    input [7:0] rd,
    output req, we,
    output [21:0] addr,
    output [7:0] wd,
    output reg done, passed,
    output reg [21:0] fail_addr,
    output reg [7:0] expected, actual
);
    reg [2:0] state, index;
    reg reading;
    function [7:0] pattern(input [2:0] n);
        case (n)
            0: pattern = 8'h00;
            1: pattern = 8'hff;
            2: pattern = 8'haa;
            3: pattern = 8'h55;
            4: pattern = 8'h12;
            5: pattern = 8'h34;
            6: pattern = 8'h81;
            7: pattern = 8'h6e;
        endcase
    endfunction
    assign req = state == 1 && !busy;
    assign wd = pattern(index);
    assign addr = {index[2], 19'b0, index[1:0]};
    assign we = !reading;
    always @(posedge clk) begin
        if (rst) begin
            state <= 0; index <= 0; reading <= 0;
            done <= 0; passed <= 0;
            fail_addr <= 0; expected <= 0; actual <= 0;
        end else case (state)
            0: if (ready && !busy) state <= 1;
            1: if (!busy) state <= 2;
            2: state <= 3; // allow bridge to assert busy after accepting req
            3: if (!busy) begin
                if (reading && rd !== pattern(index)) begin
                    fail_addr <= addr; expected <= pattern(index); actual <= rd;
                    done <= 1; passed <= 0; state <= 4;
                end else if (index == 7) begin
                    if (reading) begin done <= 1; passed <= 1; state <= 4; end
                    else begin reading <= 1; index <= 0; state <= 1; end
                end else begin index <= index + 1; state <= 1; end
            end
            default: ;
        endcase
    end
endmodule
