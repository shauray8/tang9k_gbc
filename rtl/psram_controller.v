// HyperBus controller for one 4 MiB Tang Nano 9K SiP memory die.
// Protocol: Winbond W955D8MBYA A01-001 sections 7, 9 and 12.
// Four fabric clocks per memory clock: data setup, CK rise, data/sample, CK fall.
// Plain registered I/O avoids device-specific ODDR/IDDR pipeline assumptions.
module PsramController #(
    parameter FREQ = 81_000_000,
    parameter LATENCY = 3
) (
    input clk,
    input resetn,
    input read, write,
    input [21:0] addr,
    input [15:0] din,
    input byte_write,
    output reg [15:0] dout,
    output busy,
    output [7:0] debug,
    output [1:0] O_psram_ck,
    output [1:0] O_psram_ck_n,
    inout [1:0] IO_psram_rwds,
    inout [15:0] IO_psram_dq,
    output [1:0] O_psram_cs_n
);
    localparam INIT_TIME = FREQ / 1000 * 160 / 1000;
    localparam TIMEOUT_CYCLES = FREQ / 1_000_000 * 3;
    localparam [3:0] CR_LATENCY = LATENCY == 3 ? 4'he :
                                 LATENCY == 4 ? 4'hf :
                                 LATENCY == 5 ? 4'h0 : 4'h1;
    localparam [2:0] INIT = 0, ACTIVE = 1, FINISH = 2,
                     RECOVER = 3, IDLE = 4, FAULT = 5;
    (* fsm_encoding = "one-hot" *) reg [2:0] state;
    reg [$clog2(INIT_TIME+1)-1:0] init_count;
    reg init_done;
    reg [1:0] phase;
    reg [5:0] cycle;
    reg [2:0] recovery;
    reg [$clog2(TIMEOUT_CYCLES+1)-1:0] elapsed;
    reg [47:0] ca;
    reg [15:0] data;
    reg configuring, writing, masked, upper;
    reg ck, cs_n, dq_drive, rwds_drive, rwds_out;
    reg [7:0] dq_out, first_byte;
    reg first_valid, read_complete;

    assign busy = state != IDLE;
    assign debug = {state == FAULT, state == ACTIVE, writing, configuring,
                    first_valid, read_complete, dq_drive, rwds_drive};
    assign O_psram_ck = {1'b0, ck};
    assign O_psram_ck_n = {1'b1, ~ck};
    assign O_psram_cs_n = {1'b1, cs_n};
    assign IO_psram_dq[7:0] = dq_drive ? dq_out : 8'bz;
    assign IO_psram_dq[15:8] = 8'bz;
    assign IO_psram_rwds[0] = rwds_drive ? rwds_out : 1'bz;
    assign IO_psram_rwds[1] = 1'bz;

    reg [7:0] dq_in;
    reg rwds_in;
    // GW1NR-9C die-0 pads span Y1..Y16. Anchor each input register beside
    // its pad: internal Fmax alone does not constrain pad-to-register skew.
    (* BEL = "X1Y1/DFF0" *) always @(posedge clk) dq_in[0] <= IO_psram_dq[0];
    (* BEL = "X1Y2/DFF0" *) always @(posedge clk) dq_in[1] <= IO_psram_dq[1];
    (* BEL = "X1Y2/DFF1" *) always @(posedge clk) dq_in[2] <= IO_psram_dq[2];
    (* BEL = "X1Y3/DFF0" *) always @(posedge clk) dq_in[3] <= IO_psram_dq[3];
    (* BEL = "X1Y8/DFF0" *) always @(posedge clk) dq_in[4] <= IO_psram_dq[4];
    (* BEL = "X1Y13/DFF0" *) always @(posedge clk) dq_in[5] <= IO_psram_dq[5];
    (* BEL = "X1Y15/DFF0" *) always @(posedge clk) dq_in[6] <= IO_psram_dq[6];
    (* BEL = "X1Y16/DFF0" *) always @(posedge clk) dq_in[7] <= IO_psram_dq[7];
    (* BEL = "X1Y16/DFF1" *) always @(posedge clk) rwds_in <= IO_psram_rwds[0];

    // Keep the wide power-up counter comparison off transaction-control paths.
    always @(posedge clk) begin
        if (!resetn) begin init_count <= 0; init_done <= 0; end
        else if (!init_done) begin
            if (init_count == INIT_TIME-1) init_done <= 1;
            else init_count <= init_count + 1'b1;
        end
    end

    wire start_config = state == INIT && init_done;
    wire start_request = state == IDLE && (read || write);
    wire abort_transfer = state == ACTIVE && elapsed == TIMEOUT_CYCLES-1;
    (* BEL = "X1Y7/DFF4" *) always @(posedge clk) begin
        if (!resetn || state == FINISH || abort_transfer) ck <= 0;
        else if (state == ACTIVE && phase[0]) ck <= !phase[1];
    end
    (* BEL = "X1Y5/DFF4" *) always @(posedge clk) begin
        if (!resetn || state == FINISH || abort_transfer) cs_n <= 1;
        else if (start_config || start_request) cs_n <= 0;
    end
    // Independent enables keep unrelated FSM transitions off the wide CA bus.
    always @(posedge clk) begin
        if (!resetn) ca <= 0;
        else if (start_config) ca <= 48'h600001000000;
        else if (start_request)
            ca <= {~write, 1'b0, 1'b1, 11'b0, addr[21:4], 13'b0, addr[3:1]};
        else if (state == ACTIVE && phase == 3 && cycle < 3)
            ca <= {ca[31:0], 16'b0};
    end
    always @(posedge clk) begin
        if (!resetn || start_config || start_request) begin
            phase <= 0; cycle <= 0; elapsed <= 0;
        end else if (state == ACTIVE) begin
            phase <= phase + 1'b1;
            elapsed <= elapsed + 1'b1;
            if (phase == 3) cycle <= cycle + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            state <= INIT;
            dq_drive <= 0; rwds_drive <= 0;
            dq_out <= 0; rwds_out <= 0; dout <= 0;
            recovery <= 0;
            data <= 0; configuring <= 0; writing <= 0;
            masked <= 0; upper <= 0;
            first_valid <= 0; first_byte <= 0; read_complete <= 0;
        end else case (state)
            INIT: if (init_done) begin
                // Register writes follow CA immediately, with RWDS undriven.
                // 35-ohm drive, fixed 2x latency, 32-byte wrap configuration.
                data <= {8'h9f, CR_LATENCY, 4'hf};
                configuring <= 1; writing <= 1;
                state <= ACTIVE;
            end
            IDLE: if (read || write) begin
                data <= din; writing <= write; configuring <= 0;
                masked <= byte_write; upper <= addr[0];
                first_valid <= 0; read_complete <= 0;
                state <= ACTIVE;
            end
            ACTIVE: begin
                case (phase)
                    0: begin
                        if (cycle < 3) begin dq_drive <= 1; dq_out <= ca[47:40]; end
                        else if (writing && cycle == (configuring ? 3 : 2+2*LATENCY)) begin
                            dq_drive <= 1; dq_out <= data[15:8];
                            rwds_drive <= !configuring;
                            rwds_out <= masked && !upper;
                        end else begin dq_drive <= 0; rwds_drive <= 0; end
                    end
                    2: begin
                        if (cycle < 3) dq_out <= ca[39:32];
                        else if (writing && cycle == (configuring ? 3 : 2+2*LATENCY)) begin
                            dq_out <= data[7:0]; rwds_out <= masked && upper;
                        end
                    end
                    3: begin
                        if ((writing && cycle == (configuring ? 3 : 2+2*LATENCY)) || read_complete)
                            state <= FINISH;
                    end
                endcase
                // Decode the pad registers one phase after the half-cycle
                // centers (phase 2/0). DQ and RWDS use the same capture edge.
                if (!writing && cycle >= 4 && (phase == 1 || phase == 3) && !read_complete) begin
                    if (rwds_in) begin
                        first_byte <= dq_in; first_valid <= 1;
                    end else if (!rwds_in && first_valid) begin
                        dout <= {first_byte, dq_in}; read_complete <= 1;
                    end
                end
                // Never fabricate a response to a missing memory strobe. End
                // the physical transaction before tCSM=4us; remain busy so the
                // bridge's existing timeout diagnostic reports the fault.
                if (elapsed == TIMEOUT_CYCLES-1) begin
                    state <= FAULT;
                    dq_drive <= 0; rwds_drive <= 0;
                end
            end
            FINISH: begin
                dq_drive <= 0; rwds_drive <= 0;
                recovery <= 0; state <= RECOVER;
            end
            RECOVER: if (recovery == 3) state <= IDLE;
                     else recovery <= recovery + 1'b1;
            default: ; // FAULT holds bus released until hardware reset.
        endcase
    end
endmodule
