// Powered-session MBC3 clock. Runs from the system oscillator, not CPU/PPU enables.
// Live registers and the software-latched snapshot are separate. The host saves and
// restores the live registers ({sec, min, hour, day-low, day-high}) between sessions.
module mbc3_rtc #(
    parameter integer CLOCK_HZ = 27000000
) (
    input clk,
    input rst,
    input latch_wr,
    input data_wr,
    input [3:0] select,
    input [7:0] din,
    output reg [7:0] dout,
    input host_load,
    input [39:0] host_d,
    output [39:0] live
);
    localparam integer DIV_BITS = CLOCK_HZ > 1 ? $clog2(CLOCK_HZ) : 1;
    reg [DIV_BITS-1:0] fraction;
    reg [5:0] seconds, minutes;
    reg [4:0] hours;
    reg [8:0] days;
    reg halt, carry, latch_zero;
    reg [5:0] snap_seconds, snap_minutes;
    reg [4:0] snap_hours;
    reg [8:0] snap_days;
    reg snap_halt, snap_carry;
    assign live = {2'b0, seconds, 2'b0, minutes, 3'b0, hours, days[7:0],
                   carry, halt, 5'b0, days[8]};

    always @(*) case (select)
        4'h8: dout = {2'b0, snap_seconds};
        4'h9: dout = {2'b0, snap_minutes};
        4'hA: dout = {3'b0, snap_hours};
        4'hB: dout = snap_days[7:0];
        4'hC: dout = {snap_carry, snap_halt, 5'b0, snap_days[8]};
        default: dout = 8'hFF;
    endcase

    always @(posedge clk) begin
        if (rst) begin
            fraction <= 0;
            seconds <= 0; minutes <= 0; hours <= 0; days <= 0;
            halt <= 0; carry <= 0; latch_zero <= 0;
            snap_seconds <= 0; snap_minutes <= 0; snap_hours <= 0; snap_days <= 0;
            snap_halt <= 0; snap_carry <= 0;
        end else begin
            if (!halt) begin
                if (fraction == CLOCK_HZ-1) begin
                    fraction <= 0;
                    seconds <= seconds + 1'b1;
                    if (seconds == 6'd59) begin
                        seconds <= 0;
                        minutes <= minutes + 1'b1;
                        if (minutes == 6'd59) begin
                            minutes <= 0;
                            hours <= hours + 1'b1;
                            if (hours == 5'd23) begin
                                hours <= 0;
                                days <= days + 1'b1;
                                if (days == 9'd511) carry <= 1;
                            end
                        end
                    end
                end else fraction <= fraction + 1'b1;
            end
            // Software halts the clock before setting its fields. A write wins
            // over a coincident tick of that field; other fields keep running.
            if (data_wr) case (select)
                4'h8: seconds <= din[5:0];
                4'h9: minutes <= din[5:0];
                4'hA: hours <= din[4:0];
                4'hB: days[7:0] <= din;
                4'hC: begin days[8] <= din[0]; halt <= din[6]; carry <= din[7]; end
                default: ;
            endcase
            if (latch_wr) begin
                latch_zero <= din == 0;
                if (latch_zero && din == 1) begin
                    snap_seconds <= seconds; snap_minutes <= minutes; snap_hours <= hours;
                    snap_days <= days; snap_halt <= halt; snap_carry <= carry;
                end
            end
            if (host_load) begin
                fraction <= 0;
                seconds <= host_d[37:32]; minutes <= host_d[29:24]; hours <= host_d[20:16];
                days <= {host_d[0], host_d[15:8]}; halt <= host_d[6]; carry <= host_d[7];
            end
        end
    end
endmodule
