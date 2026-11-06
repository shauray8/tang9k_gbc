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
    output reg response_valid, // response captured; physical bus recovery may still be active
    output [7:0] debug,
    output [1:0] O_psram_ck,
    output [1:0] O_psram_ck_n,
    inout [1:0] IO_psram_rwds,
    inout [15:0] IO_psram_dq,
    output [1:0] O_psram_cs_n
);
    localparam INIT_TIME = FREQ / 1000 * 160 / 1000;
    localparam TIMEOUT_CYCLES = FREQ / 1_000_000 * 3;
    localparam CYCLE_BITS = $clog2(TIMEOUT_CYCLES / 4 + 2);
    localparam RECOVERY_CYCLES = ((FREQ / 1_000_000 * 36 + 999) / 1000) > 4 ?
                                (FREQ / 1_000_000 * 36 + 999) / 1000 : 4;
    localparam [3:0] CR_LATENCY = LATENCY == 3 ? 4'he :
                                 LATENCY == 4 ? 4'hf :
                                 LATENCY == 5 ? 4'h0 : 4'h1;
    localparam [2:0] INIT = 0, ACTIVE = 1, FINISH = 2,
                     RECOVER = 3, IDLE = 4, FAULT = 5, PREPARE = 6;
    (* fsm_encoding = "one-hot" *) reg [2:0] state;
    reg [$clog2(INIT_TIME+1)-1:0] init_count;
    reg init_done;
    reg [1:0] phase;
    reg [CYCLE_BITS-1:0] cycle;
    reg [$clog2(RECOVERY_CYCLES)-1:0] recovery;
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

    wire accept_config = state == INIT && init_done;
    wire accept_request = state == IDLE && (read || write);
    reg start_config, start_request;
    always @(posedge clk)
        if (!resetn) begin start_config <= 0; start_request <= 0; end
        else begin start_config <= accept_config; start_request <= accept_request; end
    reg expired;
    // Register the terminal decode one count early, preserving the same timeout edge.
    always @(posedge clk)
        if (!resetn || start_config || start_request) expired <= 0;
        else expired <= state == ACTIVE && elapsed == TIMEOUT_CYCLES-2;
    wire abort_transfer = state == ACTIVE && expired;
    // Hold a registered response until the next command. Clear on acceptance so
    // the bridge's launch stage cannot mistake the previous word for a new one.
    always @(posedge clk)
        if (!resetn || accept_request || abort_transfer) response_valid <= 0;
        else if (!configuring && state != FAULT && (read_complete || state == FINISH)) response_valid <= 1;
    (* BEL = "X1Y7/DFF4" *) always @(posedge clk) begin
        if (!resetn || state == FINISH || abort_transfer) ck <= 0;
        else if (state == ACTIVE && phase[0]) ck <= !phase[1];
    end
    (* BEL = "X1Y5/DFF4" *) always @(posedge clk) begin
        if (!resetn || state == FINISH || abort_transfer) cs_n <= 1;
        else if (start_config || start_request) cs_n <= 0;
    end
    reg ca_shift, ca_enable, ca_cycle, write_cycle, read_window;
    reg end_cycle;
    always @(posedge clk)
        if (!resetn) end_cycle <= 0;
        else end_cycle <= state == ACTIVE && phase == 2 && !expired;
    always @(posedge clk)
        if (!resetn) ca_enable <= 0;
        else ca_enable <= accept_config || accept_request || (state == ACTIVE && phase == 2 && ca_cycle);
    always @(posedge clk)
        if (!resetn) ca_shift <= 0;
        else ca_shift <= state == ACTIVE && phase == 2 && ca_cycle;
    // These three controls are mutually exclusive. A parallel data mux avoids
    // a priority chain on the command shift register's enable and data inputs.
    wire [47:0] request_ca = {~writing, 1'b0, 1'b1, 11'b0, addr[21:4], 13'b0, addr[3:1]};
    always @(posedge clk) begin
        if (!resetn) ca <= 0;
        else if (ca_enable)
            ca <= ({48{start_config}} & 48'h600001000000) |
                  ({48{start_request}} & request_ca) |
                  ({48{ca_shift}} & {ca[31:0], 16'b0});
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
    reg before_last_ca, before_write;
    always @(posedge clk) begin
        before_last_ca <= cycle < 2;
        before_write <= writing && cycle == (configuring ? 2 : 1+2*LATENCY);
        if (!resetn || start_config || start_request) begin
            ca_cycle <= 1; write_cycle <= 0; read_window <= 0;
        end
        else if (end_cycle) begin
            ca_cycle <= before_last_ca;
            write_cycle <= before_write;
            if (!ca_cycle) read_window <= 1;
        end
    end
    // Predecode the receive edge in the preceding setup phase. Pad samples are
    // still consumed at phase 1/3, without a phase/cycle/state chain on dout's enable.
    reg rx_enable;
    always @(posedge clk) begin
        if (!resetn) begin
            rx_enable <= 0; first_valid <= 0; first_byte <= 0;
            read_complete <= 0; dout <= 0;
        end else begin
            rx_enable <= state == ACTIVE && !writing && read_window && !phase[0];
            if (accept_request) begin first_valid <= 0; read_complete <= 0; end
            else if (rx_enable && !read_complete) begin
                if (rwds_in) first_valid <= 1;
                else if (!rwds_in && first_valid) read_complete <= 1;
            end
            // Command acceptance is IDLE-only; rx_enable comes from ACTIVE.
            // Their disjoint phases let data capture avoid the command-reset priority mux.
            if (rx_enable && !read_complete && rwds_in) first_byte <= dq_in;
            if (rx_enable && !read_complete && !rwds_in && first_valid)
                dout <= {first_byte, dq_in};
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            state <= INIT;
            dq_drive <= 0; rwds_drive <= 0;
            dq_out <= 0; rwds_out <= 0;
            recovery <= 0;
            data <= 0; configuring <= 0; writing <= 0;
            masked <= 0; upper <= 0;
        end else case (state)
            INIT: if (init_done) begin
                // Register writes follow CA immediately, with RWDS undriven.
                // 35-ohm drive, fixed 2x latency, 32-byte wrap configuration.
                data <= {8'h9f, CR_LATENCY, 4'hf};
                configuring <= 1; writing <= 1;
                state <= PREPARE;
            end
            IDLE: if (read || write) begin
                data <= din; writing <= write; configuring <= 0;
                masked <= byte_write; upper <= addr[0];
                state <= PREPARE;
            end
            PREPARE: state <= ACTIVE;
            ACTIVE: begin
                case (phase)
                    0: begin
                        if (ca_cycle) begin dq_drive <= 1; dq_out <= ca[47:40]; end
                        else if (write_cycle) begin
                            dq_drive <= 1; dq_out <= data[15:8];
                            rwds_drive <= !configuring;
                            rwds_out <= masked && !upper;
                        end else begin dq_drive <= 0; rwds_drive <= 0; end
                    end
                    2: begin
                        if (ca_cycle) dq_out <= ca[39:32];
                        else if (write_cycle) begin
                            dq_out <= data[7:0]; rwds_out <= masked && upper;
                        end
                    end
                    3: begin
                        if (write_cycle || read_complete)
                            state <= FINISH;
                    end
                endcase
                // Never fabricate a response to a missing memory strobe. End
                // the physical transaction before tCSM=4us; remain busy so the
                // bridge's existing timeout diagnostic reports the fault.
                if (abort_transfer) begin
                    state <= FAULT;
                    dq_drive <= 0; rwds_drive <= 0;
                end
            end
            FINISH: begin
                dq_drive <= 0; rwds_drive <= 0;
                recovery <= 0; state <= RECOVER;
            end
            RECOVER: if (recovery == RECOVERY_CYCLES-1) state <= IDLE;
                     else recovery <= recovery + 1'b1;
            default: ; // FAULT holds bus released until hardware reset.
        endcase
    end
endmodule
