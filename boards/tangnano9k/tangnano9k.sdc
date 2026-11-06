# Names are the synthesized clock nets reported by nextpnr. Flattening keeps the lexicographically
# smallest alias of each net, so the top-level clk_*/mclk wires name these nets.
create_clock -name system -period 37.037037 [get_nets clk_sys]
create_clock -name psram_fabric -period 6.172839 [get_nets mclk]
create_clock -name video -period 13.468013 [get_nets clk_pix]
create_clock -name tmds_serial -period 2.693603 [get_nets clk_ser]
