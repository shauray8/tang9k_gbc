// Probe-only test: write 512 bytes across 256 distinct LFSR word addresses, then read all back.
// Each reset changes the pattern, so stale contents from a preceding successful run cannot pass.
module psram_stress (
    input clk, rst, ready, busy,
    input [7:0] rd,
    output req, we,
    output [21:0] addr,
    output [7:0] wd,
    output reg done, passed,
    output reg [21:0] fail_addr,
    output reg [7:0] expected, actual
);
    reg [2:0] state;
    reg [8:0] index;
    reg [20:0] address_lfsr;
    reg reading;
    reg rst_d = 0;
    reg [7:0] generation = 0;
    always @(posedge clk) begin
        rst_d <= rst;
        if (rst && !rst_d) generation <= generation + 8'h3d;
    end
    wire [7:0] pattern = generation ^ address_lfsr[7:0] ^ index[7:0] ^ (index[0] ? 8'ha5 : 8'h5a);
    assign req = state == 1 && !busy;
    assign we = !reading;
    assign addr = {address_lfsr, index[0]};
    assign wd = pattern;
    always @(posedge clk) begin
        if (rst) begin
            state <= 0; index <= 0; address_lfsr <= 1; reading <= 0;
            done <= 0; passed <= 0; fail_addr <= 0; expected <= 0; actual <= 0;
        end else case (state)
            0: if (ready && !busy) state <= 1;
            1: if (!busy) state <= 2;
            2: state <= 3;
            3: if (!busy) begin
                if (reading && rd !== pattern) begin
                    fail_addr <= addr; expected <= pattern; actual <= rd;
                    done <= 1; passed <= 0; state <= 4;
                end else if (index == 9'd511) begin
                    if (reading) begin done <= 1; passed <= 1; state <= 4; end
                    else begin reading <= 1; index <= 0; address_lfsr <= 1; state <= 1; end
                end else begin
                    index <= index + 1'b1;
                    if (index[0]) address_lfsr <= {address_lfsr[19:0], address_lfsr[20] ^ address_lfsr[18]};
                    state <= 1;
                end
            end
            default: ;
        endcase
    end
endmodule
