# SlowWire: full-Sig, ZPM-based feedback fixture

This example builds full-Sig **OpenRB-150 firmware**, a direct-PC **U2D2 commissioning path**, first-class **OpenCR 1.0 Cortex-M7 firmware and peripheral APIs**, and the preserved Pico alternative. The reusable drivers live in ZPM's core/platform layers and are exported by `slowwire.sig`. All application/protocol/board/packing code is `.sig` with fixed-capacity storage. The flash boot stage uses inline Thumb assembly inside Sig. No Arduino, C firmware SDK, TinyUSB, Python control script, libc or heap-backed application storage is linked. PowerShell and LLVM objcopy orchestrate builds and extract ELF sections.

**Status: offline tests and cross-compilation passed; physical boot and actuation unverified.** Read [HARDWARE.md](HARDWARE.md) for exact parts, engineering estimates, wiring, tools and procurement links. This checkout is isolated on `feat/slowwire-rp2040`; the original ZPM checkout's pending work is independent.

## Build

Run from Windows with the local Sig 0.6.0 toolchain and `llvm-objcopy` on PATH:

```powershell
.\examples\slowwire\build.ps1
sig build test-slowwire
sig build test-opencr
```

The script fails immediately on any compiler/test/tool failure. Outputs are in `.build/slowwire/`:

- `firmware.elf`, `firmware.bin`: freestanding Cortex-M0+ executable and flash payload.
- `boot2.elf`, `boot2.bin`: generic 03h XIP flash boot stage, at most 252 bytes.
- `slowwire.uf2`: CRC-padded boot stage and firmware in RP2040-family UF2 blocks.
- `openrb.elf`, `openrb.bin`, `openrb.hex`: Cortex-M0+ application at flash 0x2000, preserving the factory 8 KiB bootloader.
- `opencr.elf`, `opencr.bin`, `opencr.hex`: Cortex-M7 application at 0x08040000; sector 7 reserved for scratch storage.
- `opencr-driver-check.o`: compile-only coverage of host-mode/storage/EXTI APIs; never flashed.
- `slowwire-host.exe`: Windows console for OpenRB/Pico CDC and U2D2 FTDI COM, with `--self-test`.
- `slowwire-uf2.exe`: bounded binary-to-UF2 tool; validates stack/reset vectors before packing.
- `validation.json`: compiler version, image digest and explicit physical-test status.

No flashing command runs automatically. No OpenRB, U2D2 or RP2040 is attached to this workstation. Native AArch64 QEMU results cannot qualify the USB peripheral or servo bus of this board.

## First boot: OpenRB primary path

Keep VIN and all servos disconnected. Build, then double-tap RESET to enter the factory USB bootloader and note its COM port. Use **ROBOTIS's supported bossac-1.7.0-arduino3** uploader from the OpenRB board tools, not an arbitrary BOSSA release:

```powershell
.\examples\slowwire\flash-openrb.ps1 -BootloaderPort COM8 -Bossac 'C:\path\to\bossac.exe'
.\.build\slowwire\slowwire-host.exe --openrb COM7
```

The script uses the manufacturer's upload/verify recipe and validates the application vector and size first. No uploader is installed here, and no upload was attempted. The `.hex`/`.elf` also support optional SWD programming at **0x2000**, without mass erase or bootloader/fuse writes. Double-tap RESET is the recovery route; this firmware does not implement Arduino's 1200-baud bootloader touch.

The Sig application owns SAMD21 clock/GPIO/TC4+5/SERCOM2/USB registers directly. PA12/13 are the Dynamixel UART; PA28 is switched servo power; PB08 is the LED. SRAM endpoint banks are fixed capacity. It uses the same private lab USB identity and CRC-framed RPC as Pico. Physical enumeration, oscillator lock, DMA and bus turnaround still require bench validation.

After USB-only hello/reconnect checks pass, connect the 5 V VIN rail and **one bare servo**. `ping`, `provision` or `config` enables the rail, waits 300 ms and broadcasts torque-off; boot, hello and heartbeat leave power off. Follow the commissioning and calibration sections below. STOP/fault/session changes cut power and invalidate configuration; repeat `config` for all axes and verify/re-enter calibration before rearming.

## OpenCR first-class expansion target

Read [OPENCR.md](OPENCR.md) for its complete driver surface, pin ownership, USB diagnostic commands, upload procedure and bench gates. It shares the servo service but requires a separately switched 5 V servo harness: keep the built-in DYNAMIXEL VDD conductor disconnected. OpenCR adds CAN, RS485 and revision-aware IMU support. Peripheral hardware remains unverified.

## U2D2 direct-PC path

Install/check the manufacturer's FTDI COM driver and select a 1 ms latency timer in the port's advanced settings, as recommended in the U2D2 manual. Wire external 5 V power and the 3-pin TTL port per HARDWARE.md, with OpenRB disconnected from DATA:

```powershell
.\.build\slowwire\slowwire-host.exe --u2d2 COM9
```

This sends native Dynamixel Protocol 2.0 at 57,600 baud through U2D2; no SlowWire RPC envelope goes onto the servo bus. The same Sig service performs configuration, calibration, feedback supervision and finite gait on the PC. All command syntax below remains the same. The host attempts torque-off at connection and exit; the physical switch and configured 500 ms servo watchdog cover a host failure. This path cannot cut supply power automatically.

**Native SB0 integration remains pending for both paths:** OpenRB requires CDC ACM host support; U2D2 requires FTDI USB serial support. The Windows FTDI driver is currently the transport underneath our Sig host. Existing QEMU USB tests do not establish either physical driver's operation.

## Preserved alternative: Pico first boot

1. Leave the external servo supply disconnected. Keep all servos and magnet arms unpowered.
2. Hold BOOTSEL while connecting Pico by a known USB data cable. Release when the `RPI-RP2` drive appears.
3. Copy `.build/slowwire/slowwire.uf2` to that drive. The ROM restarts into the Sig firmware.
4. Find the new COM number in Device Manager. USB identity is a private lab `cafe:4001`; no product VID allocation is claimed. A unique physical serial-number descriptor and an assigned identity are needed before distributing boards.
5. In a real Windows console, run `.build/slowwire/slowwire-host.exe COM7` (replace COM7). Successful `hello` proves enumeration and a matching CRC-framed application response. The power LED blinks while disarmed and stays lit while armed/running.
6. Repeatedly close/reopen and unplug/replug. Capture descriptor and host logs. This is the first hardware gate, not a declaration that the current image already works on a board.

Firmware rejects pre-B2 RP2040 silicon to avoid the older USB E5 reset problem. It runs CPU/peripheral at 125 MHz and USB at 48 MHz for E16; bulk-IN sends are limited to 48 bytes for the known E15 packet-size hazard. This prototype does not implement a general high-throughput USB stack. Hardware timing and reset/abort behaviour need the day-1 captures.

## Commission the bus, one servo at a time

Factory units all use ID 1 and 57,600 baud. **Connect exactly one servo when assigning an ID.** The provision command is a broadcast write: connecting multiple servos would assign them the same ID. It is intentionally refused after any axis is configured in the session.

With magnets/arms removed, verify external voltage/polarity and the selected controller wiring, then power only the servo rail. For each servo separately, reconnect a fresh console session and use:

```text
provision 1
ping 1
```

For the second and third units use `provision 2` / `ping 2`, then `provision 3` / `ping 3`. Label them rear=1, arch=2, front=3. Power off before reconnecting all three to the bus. The code stays at factory baud; do not change the EEPROM baud using another tool unless you also update the UART driver.

In a fresh session:

```text
config 1 100
config 2 100
config 3 100
read 1
read 2
read 3
```

`config` confirms model 1200, disables torque, clears the bus-watchdog latch, writes current-based position mode and a <=150 mA limit, reads back EEPROM mode/current limit, sets gentle profiles and a 500 ms servo watchdog. Normal telemetry polling keeps the bus active. An error latches the fixture fault and attempts broadcast torque-off. Use `stop` to acknowledge it; correct the problem and reconfigure/recalibrate before rearming.

`read` reports measured position/current/velocity/voltage/temperature, hardware-fault bits and controller state (`0=disarmed, 1=armed, 2=running, 3=fault`). Mode changes and torque enable can change position interpretation: the initial arm goals match the fresh measured position rather than jumping to a guessed centre.

## Calibration and first motion

Calibration is **volatile** and has no useful defaults. Reboot requires calibration again. With torque disabled, manually place a bare horn through a conservative safe sweep and read the position at each end. The example accepts a maximum span of 512 encoder increments (~45 degrees) and positions 0–4095. Never cross the encoder wrap for this first prototype.

Command syntax:

```text
cal AXIS LOW HIGH RELEASED ENGAGED
```

AXIS is 1–3; all four positions are measured/calibrated encoder increments. RELEASED and ENGAGED must be distinct and lie between LOW and HIGH. Use measured values; there is deliberately no copy-and-run numerical magnet calibration in this guide.

After every axis is configured, calibrated and freshly reporting healthy feedback:

```text
arm
jog AXIS TARGET
read AXIS
stop
```

For `jog`, substitute one axis and a target inside its own calibrated bounds. First use only a few increments with no attached arms. `arm` is an explicit operation; opening the port, flashing, reconnecting, heartbeat and reading telemetry never arm. Keep the console open: it sends heartbeat every 100 ms while polling keyboard events without blocking. `Ctrl-C`, `stop` and `quit` attempt torque-off; a closed/killed/unplugged host trips the 500 ms firmware heartbeat timeout. Stale servo feedback (>250 ms), a hardware fault, out-of-range measured position, >55 C temperature threshold or voltage outside 4.5–5.5 V also trip. The current trip threshold includes 25 mA measurement/transient allowance above the configured limit. This is supervised laboratory firmware, not a certified emergency-stop system.

Once the magnetic capture/release and cable-height gates in HARDWARE.md pass, `run 1` requests one finite cycle; `run 2` requests two. Seven phases alternate rear anchoring, arch formation, front anchoring, rear release, flattening and anchor recovery. Every transition waits for all target errors to be <=16 increments and velocity magnitude <=5 register units for at least 150 ms. A phase timeout is 3 s. Completing the finite cycle leaves the fixture armed at the final pose; issue `stop` when finished. Current/encoder feedback does not establish that the cable actually moved: use the camera/scale.

`watch 1` streams round-robin telemetry; `watch 0` disables console printing. If the console stalls, the firmware trips independently. The servo's bus watchdog stops goal updates on lost bus traffic; it does not substitute for a physical cut of the 5 V actuator rail.

## Protocol and layers

| Module | Responsibility |
|---|---|
| `src/core/device/dynamixel2.sig` | CRC-16, byte stuffing, bounded encode/decode and streaming status receive, read/write/sync-write |
| `src/core/device/xl330.sig` | Model check, typed register operations, safe commissioning, signed telemetry, torque and bounded position |
| `src/core/device/slowwire_link.sig` | CDC wire envelope and incremental CRC-checked parsing |
| `src/core/device/slowwire.sig` | Three-axis calibration, host/feedback watchdogs, finite feedback-supervised gait |
| `src/core/device/usb_cdc.sig` | CDC descriptors, standard/class request policy, delayed address and endpoint halt |
| `src/core/device/uf2.sig` | ROM CRC and UF2 block format |
| `src/platform/rp2040/` | Clocks/GPIO/timer, half-duplex UART, physical USB device endpoint operations |
| `src/platform/windows/slowwire_io.sig` | Fixed-buffer Win32 serial/files/console transport |
| `examples/slowwire/main.sig` | Boot/vector/startup and board application wiring |

Core modules never import platform modules. The façade is an import root so relative paths remain within the ZPM module boundary. Wire the example using `--dep zpm_slowwire -Mroot=... -Mzpm_slowwire=slowwire.sig`; no package downloads are required. The root build graph exposes `slowwire` and `test-slowwire`.

USB CDC frames are `53 57 01 LEN SEQ_LO SEQ_HI OP PAYLOAD CRC_LO CRC_HI`, where LEN is 0–48. CRC is DYNAMIXEL's MSB-first polynomial 0x8005, initial zero, over header and payload. Replies use `OP|0x80`; first reply payload byte is status. Sequence numbers wrap modulo 65536. A duplicate last request with identical contents resends the cached reply without repeating motion; stale sequences are discarded. Opening a new DTR session resets sequence tracking and disarms. STOP is honoured even with a stale sequence. The client uses one request in flight.

Opcodes: hello=1, heartbeat=2, stop=3, identify=4, configure=5, telemetry=6, calibrate=7, arm=8, jog=9, run=10, provision=11. Firmware axis indices are 0–2; the console presents 1–3. All multi-byte values are little-endian. Configure/jog payload is axis:u8 + limit/target:u16; calibration is axis:u8 plus four u16 values. Replies return status 0=success, 1=other/device/protocol error, 2=range, 3=busy, 4=missing configuration/calibration/arm, 5=UART timeout, 6=stale/fault, 7=wrong model. Refer to `slowwire_service.sig` for the telemetry response layout.

## Verification scope

The tests execute real packet generation/parsing and the actual typed XL330 operations against a mock register bus. They cover published CRC vectors, stuffed packets, corrupt CRC, noise and capacity boundaries, duplicate sync IDs, negative telemetry, EEPROM torque-off ordering/readback, wrong-ID/device errors, calibration limits, timer wrap, stale feedback, faults/temperature, blocked gait and two complete measured gait cycles. USB policy tests cover descriptors, deferred address/configuration, short reads, class lengths and endpoint halt/clear. UF2 tests include the seed-zero boot-ROM CRC check vector.

These are not tests of the physical USB PHY, flash startup, UART turnaround, servo mechanics or native SB0S CDC host driver. Next work is hardware logs and captured failures, then native-host integration against the chosen kernel commit. Preserve the original repositories' unpushed changes and record that exact kernel baseline when starting that integration.
