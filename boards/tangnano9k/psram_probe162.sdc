# Probe only: UART/crystal and divided system clocks remain at 27 MHz.
create_clock -name memory -period 6.172839 [get_nets mclk]
