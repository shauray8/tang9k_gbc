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
    input req, we, // one command pulse plus write-enable metadata
    input [21:0] addr,
    input [15:0] din,
    input byte_write,
    output reg [15:0] dout,
    output reg busy,
    output reg response_valid, // response captured; physical bus recovery may still be active
    output [7:0] debug,
    output [1:0] O_psram_ck,
    output [1:0] O_psram_ck_n,
    inout [1:0] IO_psram_rwds,
    inout [15:0] IO_psram_dq,
    output [1:0] O_psram_cs_n
);
    localparam INIT_TIME = FREQ / 1000 * 160 / 1000;
    localparam INIT_BITS = $clog2(INIT_TIME+1);
    localparam TIMEOUT_CYCLES = FREQ / 1_000_000 * 3;
    localparam CYCLE_BITS = $clog2(TIMEOUT_CYCLES / 4 + 2);
    localparam ELAPSED_BITS = $clog2(TIMEOUT_CYCLES+1);
    localparam RECOVERY_CYCLES = ((FREQ / 1_000_000 * 36 + 999) / 1000) > 4 ?
                                (FREQ / 1_000_000 * 36 + 999) / 1000 : 4;
    localparam [3:0] CR_LATENCY = LATENCY == 3 ? 4'he :
                                 LATENCY == 4 ? 4'hf :
                                 LATENCY == 5 ? 4'h0 : 4'h1;
    localparam [2:0] INIT = 0, ACTIVE = 1, FINISH = 2,
                     RECOVER = 3, IDLE = 4, FAULT = 5, PREPARE = 6;
    (* fsm_encoding = "one-hot" *) reg [2:0] state;
    reg [INIT_BITS-1:0] init_count;
    reg [(INIT_BITS-1)/2:3] init_carry;
    reg init_done, init_last, init_run;
    reg [(INIT_BITS+3)/4-1:0] init_terminal;
    reg [1:0] phase;
    reg [CYCLE_BITS-1:0] cycle;
    reg [$clog2(RECOVERY_CYCLES)-1:0] recovery;
    reg [ELAPSED_BITS-1:0] elapsed;
    reg [(ELAPSED_BITS-1)/2:2] elapsed_carry;
    reg elapsed_roll;
    reg [47:0] ca;
    reg [15:0] data;
    reg configuring, writing, masked, upper;
    reg ck, cs_n, dq_drive, rwds_drive, rwds_out;
    reg [7:0] dq_out, first_byte;
    reg first_valid, read_complete;

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

    // Two-stage nibble decode predicts the terminal edge without changing
    // the 160 us delay or putting a wide comparator on a feedback path.
    genvar t;
    generate for (t = 0; t < INIT_BITS; t = t + 4) begin: init_terminal_group
        localparam WIDTH = INIT_BITS-t > 3 ? 4 : INIT_BITS-t;
        localparam [WIDTH-1:0] LAST = (INIT_TIME-3) >> t;
        always @(posedge clk)
            if (!resetn) init_terminal[t/4] <= 0;
            else init_terminal[t/4] <= init_count[t +: WIDTH] == LAST;
    end endgenerate
    always @(posedge clk) begin
        if (!resetn) begin init_last <= 0; init_done <= 0; init_run <= 1; end
        else begin
            init_last <= &init_terminal;
            init_done <= init_done || init_last;
            if (&init_terminal) init_run <= 0;
        end
    end
    reg init_roll;
    always @(posedge clk)
        if (!resetn) init_roll <= 0;
        else init_roll <= init_count[5:0] == 6'd62;
    // The upper chunks change only every 64 clocks. Pipeline their carry
    // prefix between those edges instead of synthesizing a 15-bit carry chain.
    genvar p;
    generate for (p = 0; p < INIT_BITS; p = p + 2) begin: init_group
        localparam WIDTH = INIT_BITS-p > 1 ? 2 : 1;
        if (p == 0) begin: low
            always @(posedge clk)
                if (!resetn) init_count[p +: WIDTH] <= 0;
                else if (init_run) init_count[p +: WIDTH] <= init_count[p +: WIDTH] + 1'b1;
        end else if (p < 6) begin: fast
            reg carry;
            always @(posedge clk) begin
                if (!resetn) begin init_count[p +: WIDTH] <= 0; carry <= 0; end
                else if (init_run) begin
                    carry <= init_count[p-1:0] == {{(p-1){1'b1}}, 1'b0};
                    if (carry) init_count[p +: WIDTH] <= init_count[p +: WIDTH] + 1'b1;
                end
            end
        end else begin: slow
            if (p == 6) always @(posedge clk) init_carry[p/2] <= 1'b1;
            else always @(posedge clk)
                if (!resetn) init_carry[p/2] <= 0;
                else init_carry[p/2] <= init_carry[p/2-1] && init_count[p-1 -: 2] == 2'b11;
            always @(posedge clk)
                if (!resetn) init_count[p +: WIDTH] <= 0;
                else if (init_run && init_roll && init_carry[p/2])
                    init_count[p +: WIDTH] <= init_count[p +: WIDTH] + 1'b1;
        end
    end endgenerate

    wire accept_config = state == INIT && init_done;
    wire accept_request = state == IDLE && req;
    reg start_config, start_request, start_transfer;
    always @(posedge clk)
        if (!resetn) begin start_config <= 0; start_request <= 0; start_transfer <= 0; end
        else begin
            start_config <= accept_config; start_request <= accept_request;
            start_transfer <= accept_config || accept_request;
        end
    reg expired;
    // Register the terminal decode one count early, preserving the same timeout edge.
    always @(posedge clk)
        if (!resetn || start_transfer) expired <= 0;
        else expired <= state == ACTIVE && elapsed == TIMEOUT_CYCLES-2;
    wire abort_transfer = state == ACTIVE && expired;
    // Responses are visible during completion, then clear through recovery
    // before another command can launch. No acceptance-to-valid reset path.
    always @(posedge clk)
        if (!resetn || abort_transfer) response_valid <= 0;
        else response_valid <= !configuring &&
                               ((state == ACTIVE && read_complete) || state == FINISH);
    (* BEL = "X1Y7/DFF4" *) always @(posedge clk) begin
        if (!resetn || state == FINISH || abort_transfer) ck <= 0;
        else if (state == ACTIVE && phase[0]) ck <= !phase[1];
    end
    (* BEL = "X1Y5/DFF4" *) always @(posedge clk) begin
        if (!resetn || state == FINISH || abort_transfer) cs_n <= 1;
        else if (start_transfer) cs_n <= 0;
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
    // Four-bit prescaler; upper chunks have sixteen clocks to propagate their
    // registered carry prefix. Counter values and the timeout edge are unchanged.
    always @(posedge clk)
        if (!resetn || start_transfer) elapsed_roll <= 0;
        else if (state == ACTIVE) elapsed_roll <= elapsed[3:0] == 4'he;
    genvar e;
    generate for (e = 0; e < ELAPSED_BITS; e = e + 2) begin: elapsed_group
        localparam WIDTH = ELAPSED_BITS-e > 1 ? 2 : 1;
        if (e == 0) begin: low
            always @(posedge clk)
                if (!resetn || start_transfer) elapsed[e +: WIDTH] <= 0;
                else if (state == ACTIVE) elapsed[e +: WIDTH] <= elapsed[e +: WIDTH] + 1'b1;
        end else if (e < 4) begin: fast
            reg carry;
            always @(posedge clk) begin
                if (!resetn || start_transfer) begin
                    elapsed[e +: WIDTH] <= 0; carry <= 0;
                end else if (state == ACTIVE) begin
                    carry <= elapsed[e-1:0] == {{(e-1){1'b1}}, 1'b0};
                    if (carry) elapsed[e +: WIDTH] <= elapsed[e +: WIDTH] + 1'b1;
                end
            end
        end else begin: slow
            if (e == 4) always @(posedge clk) elapsed_carry[e/2] <= 1'b1;
            else always @(posedge clk)
                if (!resetn || start_transfer) elapsed_carry[e/2] <= 0;
                else elapsed_carry[e/2] <= elapsed_carry[e/2-1] && elapsed[e-1 -: 2] == 2'b11;
            always @(posedge clk)
                if (!resetn || start_transfer) elapsed[e +: WIDTH] <= 0;
                else if (state == ACTIVE && elapsed_roll && elapsed_carry[e/2])
                    elapsed[e +: WIDTH] <= elapsed[e +: WIDTH] + 1'b1;
        end
    end endgenerate
    always @(posedge clk) begin
        if (!resetn || start_transfer) begin
            phase <= 0; cycle <= 0;
        end else if (state == ACTIVE) begin
            phase <= phase + 1'b1;
            if (phase == 3) cycle <= cycle + 1'b1;
        end
    end
    reg before_last_ca, before_write;
    always @(posedge clk) begin
        before_last_ca <= cycle < 2;
        before_write <= writing && cycle == (configuring ? 2 : 1+2*LATENCY);
        if (!resetn || start_transfer) begin
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

    // Transmit registers must also stay beside the die-0 pads: at 162 MHz
    // there is only one fabric clock of data setup before forwarded CK.
    wire tx_update = state == ACTIVE && !phase[0] && (ca_cycle || write_cycle);
    wire [7:0] tx_byte = ca_cycle ?
                        (phase[1] ? ca[39:32] : ca[47:40]) :
                        (phase[1] ? data[7:0] : data[15:8]);
    (* BEL = "X1Y1/DFF2" *) always @(posedge clk)
        if (!resetn) dq_out[0] <= 0; else if (tx_update) dq_out[0] <= tx_byte[0];
    (* BEL = "X1Y2/DFF2" *) always @(posedge clk)
        if (!resetn) dq_out[1] <= 0; else if (tx_update) dq_out[1] <= tx_byte[1];
    (* BEL = "X1Y2/DFF3" *) always @(posedge clk)
        if (!resetn) dq_out[2] <= 0; else if (tx_update) dq_out[2] <= tx_byte[2];
    (* BEL = "X1Y3/DFF2" *) always @(posedge clk)
        if (!resetn) dq_out[3] <= 0; else if (tx_update) dq_out[3] <= tx_byte[3];
    (* BEL = "X1Y8/DFF2" *) always @(posedge clk)
        if (!resetn) dq_out[4] <= 0; else if (tx_update) dq_out[4] <= tx_byte[4];
    (* BEL = "X1Y13/DFF2" *) always @(posedge clk)
        if (!resetn) dq_out[5] <= 0; else if (tx_update) dq_out[5] <= tx_byte[5];
    (* BEL = "X1Y15/DFF2" *) always @(posedge clk)
        if (!resetn) dq_out[6] <= 0; else if (tx_update) dq_out[6] <= tx_byte[6];
    (* BEL = "X1Y16/DFF2" *) always @(posedge clk)
        if (!resetn) dq_out[7] <= 0; else if (tx_update) dq_out[7] <= tx_byte[7];
    (* BEL = "X1Y16/DFF4" *) always @(posedge clk)
        if (!resetn) rwds_out <= 0;
        else if (state == ACTIVE && !phase[0] && !ca_cycle && write_cycle)
            rwds_out <= masked && (phase[1] ? upper : !upper);

    always @(posedge clk) begin
        if (!resetn) begin
            state <= INIT; busy <= 1;
            dq_drive <= 0; rwds_drive <= 0;
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
            IDLE: if (req) begin
                busy <= 1;
                data <= din; writing <= we; configuring <= 0;
                masked <= byte_write; upper <= addr[0];
                state <= PREPARE;
            end
            PREPARE: state <= ACTIVE;
            ACTIVE: begin
                case (phase)
                    0: begin
                        if (ca_cycle) dq_drive <= 1;
                        else if (write_cycle) begin
                            dq_drive <= 1;
                            rwds_drive <= !configuring;
                        end else begin dq_drive <= 0; rwds_drive <= 0; end
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
            RECOVER: if (recovery == RECOVERY_CYCLES-1) begin state <= IDLE; busy <= 0; end
                     else recovery <= recovery + 1'b1;
            default: ; // FAULT holds bus released until hardware reset.
        endcase
    end
endmodule
