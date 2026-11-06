// 27 MHz -> 81 or 162 MHz memory fabric, with a 27 MHz system output.
// Both plans keep the VCO at 648 MHz; the four-phase controller divides fabric by four.
module pll_psram #(parameter FREQ = 81_000_000) (
    input  clock_in,
    output clock_out,
    output clock_sys,
    output locked
);
    wire divided_clock, third_clock;
    assign clock_sys = FREQ == 162_000_000 ? divided_clock : third_clock;
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),
        .FBDIV_SEL(FREQ / 27_000_000 - 1),
        .ODIV_SEL(648_000_000 / FREQ),
        .DYN_SDIV_SEL(FREQ == 162_000_000 ? 6 : 2),
        .CLKFB_SEL("internal"),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW1NR-9C")
    ) pll (
        .CLKIN(clock_in), .CLKOUT(clock_out), .CLKOUTP(), .CLKOUTD(divided_clock), .CLKOUTD3(third_clock),
        .LOCK(locked), .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0), .FBDSEL(6'b0), .IDSEL(6'b0),
        .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
endmodule
