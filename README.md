# Tang Nano 9K Game Boy Color

A Game Boy and Game Boy Color FPGA core for the Sipeed Tang Nano 9K. The release image runs games from the on-package PSRAM, outputs 1280×720 HDMI video, accepts a wired joypad or USB host input, and outputs mono audio for a powered speaker/amplifier.

## Implemented hardware

- SM83 CPU, interrupts, HALT/STOP, CGB double speed, and CGB ABCDE bypass-boot state
- DMG and CGB PPU with palettes, sprites, windows, STAT timing, OAM DMA, GDMA, and HDMA
- Fit-safe fixed-level mono compatibility APU: all four channel trigger/register groups drive one shared square voice, with CGB power/status masks. Autonomous sweep, envelope, length, waveform, noise generation, and channel mixing are not cycle-accurate.
- Timer, joypad, serial test output, WRAM/HRAM, and CGB undocumented I/O state
- ROM-only, MBC1, MBC1 multicart, MBC2, MBC3+RTC, and MBC5 cartridges
- Battery RAM and MBC3 RTC save transfer through the host
- 720p HDMI scaler with a six-line buffer
- UART ROM loader, launcher/menu, and box art. Non-release builds also include the in-game debug overlay; the release omits it to fit the FPGA.
- Optional open CGB boot ROM

ROMs up to and including 4 MiB are accepted. ROMs larger than 4 MiB are intentionally out of scope. A 4 MiB ROM occupies the complete active PSRAM die, so it cannot simultaneously use the current PSRAM-backed cartridge-RAM or boot-ROM regions.

## Build

The repository carries its OSS CAD Suite under `tools/oss-cad-suite`.

```sh
source env.sh
make release                 # build/fpga-release/gb.fs
make prog RELEASE=1          # volatile SRAM programming
make flash RELEASE=1         # persistent FPGA flash
make rom ROM=/path/game.gbc  # game in SPI flash at 0x100000
```

Release images must pass the physical PSRAM qualification before distribution:

```sh
sim/hwstress/qualify.sh build/fpga-release/gb.fs
```

## Controls and host

- S1: reset and reload the SPI-flash ROM
- S2: open the in-game overlay in non-release debug builds; unused by the release image
- External buttons: connect the configured `joy_n` header pins to GND; internal pull-ups are enabled
- USB host: `host/gbctl.py` loads ROMs and controls the running core
- Library UI: `host/library.py`

The external button bit order is `{Start, Select, B, A, Down, Up, Left, Right}`. See `boards/tangnano9k/tangnano9k.cst` for physical FPGA pins.

## Powered-speaker audio

`audio_pwm` is the fixed-level shared square voice on **FPGA pin 33**, physical **J5 pin 11** (`RGB_DE`). It is a 3.3 V logic signal, not a speaker driver.

Recommended connection:

```text
J5 pin 11 -- 1 kΩ --+-- 1 µF series capacitor --> powered amplifier AUX/input
                    |
                   10 nF
                    |
                   GND
FPGA GND ---------------------------------------> amplifier GND
```

The RC values are a conservative starting point. A powered speaker with an existing line input may already contain input coupling and filtering. Keep the series resistor. **Never connect a passive speaker directly to the FPGA pin.**

## Verification

```sh
sim/mooneye.py build/mooneye
sim/timer/run.sh
sim/apu/run.sh
sim/color/run.sh
sim/banktest/run.sh
sim/video/run.sh
sim/tmds/run.sh
```

The Mooneye runner targets CGB ABCDE behavior and marks only mutually exclusive hardware-model cases plus the greater-than-4-MiB MBC5 case as not applicable.

