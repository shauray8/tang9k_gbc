# FPGA Game Boy (DMG) on Tang Nano 9K

## Target and scope
- Board: Sipeed Tang Nano 9K, Gowin GW1NR-LV9QN88PC6/I5: 8640 LUT4, 6480 FF, 26 BSRAM blocks (18 Kbit each), 64 Mbit PSRAM, 32 Mbit SPI flash, HDMI connector.
- Game Boy Advance: feasibility is unproven; no synthesized GBA implementation or measured fit exists in this project.
- Game Boy Color: planned, not implemented. Double-speed CPU and color PPU need separate memory-bandwidth and logic-budget verification.
- Current build: DMG with file-backed ROM banking for MBC1/3/5. No physical cartridge interface. MBC3 RTC and broad mapper compatibility remain incomplete.

## Reproducing the build

The tested toolchain is [OSS CAD Suite 2026-11-04](https://github.com/YosysHQ/oss-cad-suite-build/releases/tag/2026-11-04), Darwin ARM64 on the development Mac. Extract it to `tools/oss-cad-suite`, or export `OSS_CAD_SUITE=/path/to/oss-cad-suite`. Run the suite's `activate` script once on macOS. Then, from this repository in Bash:

```bash
source env.sh
make bitstream
make flash
make rom ROM="/path/to/your/game.gb"
/usr/bin/python3 host/gbctl.py play
```

No ROMs or downloaded tools are bundled. For keyboard control, focus the pad window: arrows, Z/A, X/B, Enter/Start, Backspace/Select. Close that window before running `host/gbctl.py status`, `diagnose`, or `load`. `sim/psram/run.sh sweep` needs no ROM; `sim/run.sh /path/to/test.gb 600` runs a supplied ROM in the core simulation.

## PSRAM boot diagnostic
- Before loading a ROM, `rtl/psram_test.v` writes bytes `00 FF AA 55 12 34 81 6E` to addresses `000000..000003` and `200000..200003`, then reads all eight back. This checks adjacent byte lanes and one high address bit; it is not an exhaustive RAM test.
- On the first mismatch, ROM loading and CPU execution remain blocked. The five HDMI byte rows (green=1, MSB left) show expected byte, actual byte, `{done, passed, failing_address[21:16]}`, failing address bits 15:8, and bits 7:0. A completed failure has bit 7 set in row three.
- While the test is still pending, the five rows instead show controller flags, `{write, busy, address[21:16]}`, address bits 15:8, address bits 7:0, and elapsed fabric cycles. Controller flags are `{timeout, active, writing, configuring, first_byte_seen, read_complete, dq_drive, rwds_drive}`. A missing yellow bar is normal before the test passes and ROM loading begins.
- `/usr/bin/python3 host/gbctl.py diagnose` reads command `D`: nine bytes `{D, test_flags, controller_flags, address[21:16], address[15:8], address[7:0], expected, actual, elapsed_cycles}`. Test flags are `{done, pass, write, busy, ready, hang, request, logo_ok}`. Unlike the old client, USB UART initialization explicitly sets the FTDI baud/format/flow-control registers after reconnecting.
- After a pass, the rows return to ROM-header readback and bridge diagnostics. S1 reruns the test and reloads the ROM.
- The build fails on synthesis, routing, packing, or pipeline errors rather than accepting a pre-existing output file.
- `rtl/psram_controller.v` now uses four fabric phases per memory clock, with registered DQ/RWDS/CS/CK signals instead of ODDR/IDDR. The 81 MHz fabric produces 20.25 MHz CK and its complement; idle is CK=0, CK#=1.
- CR0=`0x9FEF`: 35-ohm drive, IL=3, fixed 2x latency. Register writes immediately follow the three CA clocks; memory writes start at zero-based clock 8. Reads take the first RWDS-high byte followed by its RWDS-low byte, not an arbitrary late burst sample.
- Missing read strobes release the physical bus before the 4 us maximum transaction duration and leave the controller busy; the bridge reports a timeout rather than returning fabricated data.
- `sim/psram/run.sh sweep` exercises the real controller, bridge and boot test against a pin-level HyperRAM model. It checks byte masks, all 22 address bits, ROM-bank/RAM-region boundaries, protocol timing, contention and the complete CDC round trip. All 15 tested delay combinations passed; maximum observed round trip was 833.322 ns versus an 833.333 ns DMG data deadline. That worst case reaches the two-pixel-clock setup boundary; it is not spare bandwidth for GBC double speed.
- The old DDR implementation reproduced `expected 00 / got 55` with a shortened modeled receive pipeline, despite correct memory contents. That demonstrates a receive-alignment defect under those conditions; the exact hardware pipeline has not been measured.
- Hardware isolation passed the eight-byte test at 27 MHz and 81 MHz fabric rates; direct and asynchronous-bridge probes each passed 20 reset/write/read repetitions at 81 MHz. The crystal-referenced probe measured 81.000 MHz memory fabric and approximately 25.207 MHz system clock (counter resolution approximately 0.105 MHz).
- Full-design placement affected correctness despite passing internal-clock timing. Receive FFs are now explicitly placed next to the GW1NR-9C die-0 DQ/RWDS pads, with CK and CS FFs also anchored near their pads. These board-specific BEL attributes preserve the four-phase schedule while reducing unmodeled pad-to-register and forwarded-clock routing skew.
- Sources: [Winbond protocol specification](https://cms.nacsemi.com/content/AuthDatasheets/Winbond/W955D8MBYA_85C_PKG_datasheet_A01-001_20190605.pdf), [zf3 controller and issues](https://github.com/zf3/psram-tang-nano-9k), [independent Nano9K hardware investigation](https://github.com/sabas0ba/hello_veryl/blob/de47429483ecaa137aac3ba68843993b30a37978/docs/psram.md). The new controller is implemented from the protocol specification; no unlicensed controller source was copied.

## Block diagram
```mermaid
flowchart LR
    Flash["SPI flash ROM file"] --> Loader["ROM loader"]
    USB["USB ROM upload"] --> Loader
    Loader --> Bridge["Byte request / response CDC"]
    Core["25.2 MHz domain: GB CPU, PPU, video"] <--> Bridge
    Bridge <--> Controller["81 MHz fabric: four-phase HyperBus controller"]
    Controller <-->|"20.25 MHz CK"| RAM["SiP PSRAM: ROM and cartridge RAM"]
    Core --> Ring["32-line ring buffer"]
    Ring --> HDMI["640×480 HDMI"]
```

## Clocking
- The GB core runs on one clock enable (`tick`) in the 25.2 MHz domain. It produces exactly 70224 dots per HDMI frame (800×525 = 420000 pixel clocks), so the GB runs at 60.00 Hz instead of 59.73 Hz (0.46% fast).
- `tick` spacing is 5–6 clocks. Every CPU input (bus data, IRQ lines, joypad) only changes on a tick edge. The CPU also registers `din` and the IRQ-pending vector one clock early. So all CPU-internal paths have at least 4 clocks to settle (multicycle by construction).
- The simulation testbench uses the same tick spacing as the hardware.
- Memory uses a separate 81 MHz fabric domain, constrained by `boards/tangnano9k/tangnano9k.sdc`. The pin model checks that requests return before the next DMG M-cycle. GBC double-speed bandwidth has not been established.

## Video without a frame buffer
- The 32-line ring buffer saves two BSRAM blocks compared with a full frame buffer. GB frame start is locked to HDMI position `TARGET = 380000` (line 475 of the previous HDMI frame).
- With 5.98 pixel clocks per dot, GB line *n* is fully written before HDMI line `24 + 3n` scans it. It is not overwritten by line *n+32* until HDMI has finished with it. Allowed phase window: −66142 … −28988 pixel clocks; −40000 is used.
- If the game turns the LCD off/on (frame phase changes), the tick generator pauses the core until HDMI reaches `TARGET` again. This takes at most one frame and is invisible because the first frame after LCD-on is blank on hardware too.
- Output: 3× integer scale, 480×432 centred in 640×480, DMG green palette.

## CPU (rtl/sm83.v)
- M-cycle accurate. Each M-cycle presents one bus operation, and opcode fetch overlaps the previous instruction's last cycle like the real SM83.
- Interrupt dispatch is 5 M-cycles. EI is delayed by one instruction. HALT wakes on IE&IF. The HALT bug is not emulated.
- IF/IE live inside the CPU.
- Reset release explicitly requests the opcode at `0x0100` before the first CPU M-cycle. Previously the first request was `0x0101`, so stale external-bus data could execute as the first opcode. The synthetic banking ROMs exposed this (`RST 38` from stale `FF`); fixing it also makes Blargg `instr_timing` complete instead of hanging.

## PPU (rtl/ppu.v)
- VRAM is a single BSRAM port shared with the CPU. The CPU is locked out in mode 3, as on hardware, so the PPU owns the port while drawing.
- OAM is 4×64×8 distributed LUT-RAM, so OAM scan reads a whole sprite entry per dot (40 entries in 80 dots, 10-per-line limit).
- Sprite pattern data is fetched at the start of mode 3 using the LCDC object size at fetch time (as hardware). Each sprite costs a 1-dot merge stall into an 8-pixel sprite FIFO (DMG X/OAM priority).
- BG/window: fetcher + 8-pixel shifter, SCX fine-scroll discard, window restarts the fetcher, internal window line counter.
- STAT interrupt uses a rising-edge OR of all sources (STAT blocking).

## Memory budget (BSRAM blocks)
| Use | Blocks |
|---|---|
| Cartridge ROM / RAM in PSRAM | 0 |
| WRAM 8 KB | 4 |
| VRAM 8 KB | 4 |
| Ring buffer 8192×2 | 1 |
| **Total** | **9 / 26** |

OAM DMA owns the ROM/WRAM bus while active and the CPU sees only HRAM/IO, as on hardware. Every memory stays single-ported.

## Verification status
| Test | Result |
|---|---|
| Blargg cpu_instrs 01–11 | all pass |
| Blargg instr_timing | pass |
| dmg-acid2 | pixel-exact vs reference |
| Earlier BRAM-ROM hardware: dmg-acid2 on HDMI | correct |
| Earlier BRAM-ROM hardware: 01-special loaded from SPI flash | Passed |
| Four-phase PSRAM pin-model regression | 15 delay combinations pass |
| Current full-design PSRAM eight-byte boot test | Pass; larger memory stress still needed |
| Batman loaded from SPI flash through PSRAM | User confirms game runs |
| ROM header self-check indicator | Investigation ongoing |

## Not yet implemented
- APU (sound)
- GBC CPU speed switching, color PPU, VRAM/WRAM banking and HDMA
- Boot ROM: the core starts at 0x0100 with post-boot register values
- Persistent cartridge-RAM saves and MBC3 RTC
