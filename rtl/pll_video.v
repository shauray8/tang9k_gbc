// 27 MHz -> 371.25 MHz TMDS serializer clock; CLKDIV /5 in top derives the 74.25 MHz 720p pixel clock.
// PFD = 27 / 4 = 6.75 MHz, CLKOUT = 6.75 * 55 = 371.25 MHz, VCO = 2 * 371.25 = 742.5 MHz.
module pll_video (
    input  clock_in,
    output clock_out,
    output locked
);
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(3),
        .FBDIV_SEL(54),
        .ODIV_SEL(2),
        .DYN_SDIV_SEL(2),
        .CLKFB_SEL("internal"),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW1NR-9C")
    ) pll (
        .CLKIN(clock_in), .CLKOUT(clock_out), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .LOCK(locked), .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0), .FBDSEL(6'b0), .IDSEL(6'b0),
        .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
endmodule
