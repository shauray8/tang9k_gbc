# Names are the synthesized clock nets reported by nextpnr.
create_clock -name system -period 39.682540 [get_nets core.clk]
create_clock -name psram_fabric -period 12.345679 [get_nets mclk]
