// Streams bytes from the on-board SPI flash (READ 0x03 at FLASH_ADDR) after reset, until `stop`.
// SPI mode 0, SCLK = clk/4 (6.3 MHz at 25.2 MHz). `hold` freezes SCLK (allowed at any point in SPI).
module spi_rom_loader #(parameter [23:0] FLASH_ADDR = 24'h100000) (
    input             clk,
    input             rst,
    input             hold,
    input             stop,
    output reg        busy,
    output reg        valid,
    output reg [7:0]  data,
    output reg        sclk,
    output reg        cs_n,
    output reg        mosi,
    input             miso
);
    reg [1:0] q;
    reg [5:0] cbit;              // command/address bit counter (0..31)
    reg [2:0] dbit;
    reg [31:0] cmd;
    reg [7:0] sh;
    reg data_phase;
    always @(posedge clk) begin
        valid <= 0;
        if (rst) begin
            busy <= 1; cs_n <= 1; sclk <= 0; mosi <= 0; q <= 0; cbit <= 0; dbit <= 0;
            data_phase <= 0; cmd <= {8'h03, FLASH_ADDR};
        end else if (busy && stop) begin
            busy <= 0; cs_n <= 1; sclk <= 0;
        end else if (busy && !hold) begin
            cs_n <= 0;
            q <= q + 1;
            case (q)
                2'd0: begin sclk <= 0; if (!data_phase) mosi <= cmd[31]; end
                2'd1: sclk <= 1;
                2'd3: begin
                    if (!data_phase) begin
                        cmd <= cmd << 1; cbit <= cbit + 1;
                        if (cbit == 6'd31) data_phase <= 1;
                    end else begin
                        sh <= {sh[6:0], miso}; dbit <= dbit + 1;
                        if (dbit == 3'd7) begin valid <= 1; data <= {sh[6:0], miso}; end
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
