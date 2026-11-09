SHELL := /bin/bash -eu -o pipefail
.DELETE_ON_ERROR:
OSS_CAD_SUITE ?= $(CURDIR)/tools/oss-cad-suite
TOOLS := $(OSS_CAD_SUITE)/bin
export OSS_CAD_SUITE
export PATH := $(TOOLS):$(PATH)

ROM    ?=
BUILD  := build/fpga
RTL    := rtl/top.v rtl/pll_video.v rtl/pll_psram.v rtl/hdmi.v rtl/spi_rom_loader.v rtl/cart_loader.v rtl/psram_bridge.v rtl/psram_controller.v rtl/uart_rx.v rtl/uart_tx.v rtl/gb.v rtl/sm83.v rtl/timer.v rtl/ppu.v
RTL += rtl/psram_test.v rtl/video_buffer.v
RTL += rtl/mbc3_rtc.v
RTL += rtl/menu_bridge.v rtl/host_mem.v
CST    := boards/tangnano9k/tangnano9k.cst
SDC    := boards/tangnano9k/tangnano9k.sdc
DEVICE := GW1NR-LV9QN88PC6/I5
PNR_SEED ?= 7   # qualified with sim/hwstress/qualify.sh (12 min clean); seeds 4, 9, 14 crash it
FAMILY := GW1N-9C

.PHONY: all bitstream prog flash rom sim clean arcade

all: bitstream


$(BUILD)/gb.json: $(RTL) Makefile
	@mkdir -p $(BUILD)
	cd $(BUILD) && yosys -q -l yosys.log -p "read_verilog $(addprefix $(CURDIR)/,$(RTL)); synth_gowin -noalu -nowidelut -top top -json gb.json"

$(BUILD)/pnr.json: $(BUILD)/gb.json $(CST) $(SDC)
	nextpnr-himbaechel -l $(BUILD)/pnr.log --seed $(PNR_SEED) --json $< --write $@ --device $(DEVICE) \
	  --vopt family=$(FAMILY) --vopt cst=$(CST) --sdc $(SDC) --freq 27 2>&1 | tee $(BUILD)/pnr.console.log

$(BUILD)/gb.fs: $(BUILD)/pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

bitstream: $(BUILD)/gb.fs

prog: $(BUILD)/gb.fs          # volatile (SRAM)
	openFPGALoader -b tangnano9k --freq 1000000 $<

flash: $(BUILD)/gb.fs         # persistent (SPI flash)
	openFPGALoader -b tangnano9k --freq 1000000 -f $<

rom:                          # write a ROM file to SPI flash @ 0x100000, then reboot
	@test -n "$(ROM)" || { printf '%s\n' 'Set ROM=/path/to/game.gb'; exit 2; }
	openFPGALoader -b tangnano9k --freq 1000000 --external-flash -o 0x100000 "$(ROM)"
	openFPGALoader -b tangnano9k -r

sim:
	@test -n "$(ROM)" || { printf '%s\n' 'Set ROM=/path/to/game.gb'; exit 2; }
	sim/run.sh "$(ROM)"

arcade: host/arcade/engine.bin   # launcher engine; needs rgbds (brew install rgbds)

host/arcade/engine.bin: host/arcade/engine.asm
	@mkdir -p build/arcade
	rgbasm -o build/arcade/engine.o $<
	rgblink -o build/arcade/engine.gb build/arcade/engine.o
	head -c 8192 build/arcade/engine.gb > $@

clean:
	rm -rf build

PROBE_FAST ?= 0
PROBE_BRIDGE ?= 0
PROBE_SYNC ?= 0
PROBE_MEM_MHZ ?= 81
PROBE_STRESS ?= 0
PROBE_BUILD := build/psram_probe$(if $(filter 1,$(PROBE_BRIDGE)),bridge$(if $(filter 1,$(PROBE_SYNC)),sync,),$(if $(filter 1,$(PROBE_FAST)),81,))$(if $(filter 162,$(PROBE_MEM_MHZ)),_162,)$(if $(filter 1,$(PROBE_STRESS)),_stress,)
PROBE_RTL := sim/psram/probe.v sim/psram/stress.v rtl/psram_controller.v rtl/psram_bridge.v rtl/psram_test.v rtl/uart_rx.v rtl/uart_tx.v rtl/pll_psram.v
PROBE_CST := boards/tangnano9k/psram_probe.cst
# The 162 MHz probe constrains only the memory domain that fast; USB stays at 27 MHz.
PROBE_SDC := $(if $(and $(filter 162,$(PROBE_MEM_MHZ)),$(filter 1,$(PROBE_FAST) $(PROBE_BRIDGE))),boards/tangnano9k/psram_probe162.sdc,)
PROBE_MHZ := $(if $(PROBE_SDC),27,$(if $(filter 1,$(PROBE_FAST) $(PROBE_BRIDGE)),81,27))

$(PROBE_BUILD)/probe.json: $(PROBE_RTL) Makefile
	@mkdir -p $(PROBE_BUILD)
	yosys -q -l $(PROBE_BUILD)/yosys.log -p "read_verilog $(PROBE_RTL); chparam -set FAST $(PROBE_FAST) -set BRIDGE $(PROBE_BRIDGE) -set SYNC $(PROBE_SYNC) -set MEM_MHZ $(PROBE_MEM_MHZ) -set STRESS $(PROBE_STRESS) psram_probe; synth_gowin -nowidelut -top psram_probe -json $@"

$(PROBE_BUILD)/pnr.json: $(PROBE_BUILD)/probe.json $(PROBE_CST) $(PROBE_SDC)
	nextpnr-himbaechel -l $(PROBE_BUILD)/pnr.log --json $< --write $@ --device $(DEVICE) \
	  --vopt family=$(FAMILY) --vopt cst=$(PROBE_CST) $(if $(PROBE_SDC),--sdc $(PROBE_SDC),) --freq $(PROBE_MHZ)

$(PROBE_BUILD)/probe.fs: $(PROBE_BUILD)/pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

.PHONY: psram-probe
psram-probe: $(PROBE_BUILD)/probe.fs
