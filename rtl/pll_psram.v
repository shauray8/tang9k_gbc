// 27 MHz -> 81 MHz fabric clock; the controller generates a 20.25 MHz memory clock.
// CLKOUTD3 = CLKOUT / 3 = 27 MHz system clock, from the same VCO (648 MHz).
module pll_psram (
    input  clock_in,
    output clock_out,
    output clock_sys,
    output locked
);
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),
        .FBDIV_SEL(2),
        .ODIV_SEL(8),
        .DYN_SDIV_SEL(2),
        .CLKFB_SEL("internal"),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW1NR-9C")
    ) pll (
        .CLKIN(clock_in), .CLKOUT(clock_out), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(clock_sys),
        .LOCK(locked), .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0), .FBDSEL(6'b0), .IDSEL(6'b0),
        .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
endmodule
