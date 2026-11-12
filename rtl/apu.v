// Fit-safe Game Boy audio compatibility voice for the Tang Nano 9K.
// All four channel trigger groups produce audio through one shared square voice;
// the newest trigger wins. Fixed CGB read masks preserve boot and unused-I/O behavior.
module apu (
    input             clk,
    input             rst,
    input             ce,
    input             wr,
    input             sel,
    input      [7:0]  addr_lo,
    input      [7:0]  din,
    output reg [7:0]  dout,
    output reg [9:0]  sample
);
    reg power, active, dac_on;
    reg [7:0] low, phase, step;

    // A fixed-level square bit avoids a second DAC datapath in the nearly full FPGA.
    always @(*) sample = power && active && phase[7] ? 10'h3FF : 10'h000;

    always @(posedge clk) begin
        if (rst) begin
            power <= 1; active <= 1; dac_on <= 1;
            low <= 0; phase <= 0; step <= 1;
        end else begin
            if (ce && active) phase <= phase + step;
            if (wr && sel) case (addr_lo)
                8'h12, 8'h17, 8'h21: begin
                    dac_on <= din[7:3] != 0;
                    if (din[7:3] == 0) active <= 0;
                end
                8'h13, 8'h18, 8'h1D: low <= din;
                8'h14, 8'h19: if (din[7]) begin
                    active <= dac_on;
                    step <= {din[2:0], low[7:3]} == 0 ? 1 : {din[2:0], low[7:3]};
                    phase <= 0;
                end
                8'h1E: if (din[7]) begin
                    active <= 1;
                    step <= {din[2:0], low[7:3]} == 0 ? 1 : {din[2:0], low[7:3]};
                    phase <= 0;
                end
                8'h23: if (din[7]) begin active <= dac_on; step <= 8'h31; phase <= 0; end
                8'h26: begin
                    power <= din[7];
                    if (!din[7]) active <= 0;
                end
                default: ;
            endcase
        end
    end

    always @(*) case (addr_lo)
        8'h10: dout = 8'h80;
        8'h11: dout = 8'hBF;
        8'h12: dout = 8'hF3;
        8'h13: dout = 8'hFF;
        8'h14: dout = 8'hBF;
        8'h15: dout = 8'hFF;
        8'h16: dout = 8'h3F;
        8'h17: dout = 8'h00;
        8'h18: dout = 8'hFF;
        8'h19: dout = 8'hBF;
        8'h1A: dout = 8'h7F;
        8'h1B: dout = 8'hFF;
        8'h1C: dout = 8'h9F;
        8'h1D: dout = 8'hFF;
        8'h1E: dout = 8'hBF;
        8'h1F: dout = 8'hFF;
        8'h20: dout = 8'hFF;
        8'h21: dout = 8'h00;
        8'h22: dout = 8'h00;
        8'h23: dout = 8'hBF;
        8'h24: dout = 8'h77;
        8'h25: dout = 8'hF3;
        8'h26: dout = {power, 3'b111, 3'b000, active};
        default: dout = 8'hFF;
    endcase
endmodule
