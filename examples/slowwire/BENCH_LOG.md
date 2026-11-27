# SlowWire bench log

## 2026-10-02 — offline foundation

- Branch: feat/slowwire-rp2040 in the isolated zpm-slowwire worktree.
- Sig core contracts pass; firmware and tools build; UF2 structure/vector checks pass.
- No attached Pico/servo fixture detected. Physical boot, electrical timing and movement untested.
- Native SB0S CDC-host integration pending; Windows commissioning client is the first hardware route.

## 2026-10-02 — OpenRB primary and U2D2 comparison

- Shared full-Sig commissioning/gait service; OpenRB SAMD21 clock, timing, UART, USB CDC and power-switch implementation; U2D2 Windows FTDI-COM transport.
- 23 offline tests pass, including power-off boot, host watchdog power cut, broken-bus shutdown, disarmed recovery and measured overtemperature.
- OpenRB firmware cross-compiles and its application vectors fit the 0x2000/32 KiB SRAM layout. Host compiles and framing self-test passes. Pico alternative still builds.
- Factory bootloader/upload recipe verified against ROBOTIS board sources; uploader not installed and flashing not attempted.
- No physical USB, UART, power or motion result claimed. SB0 CDC/FTDI host drivers remain pending.
- First hardware gate: OpenRB USB-only enumeration/hello, then one XL330 without arms. Repeat one-servo checks through U2D2 using the same servo.

## Bench session template (both paths)

Date/operator:
Gate number:
Firmware UF2 SHA256:
Host tool version / OS:
Controller path / board revision / serial:
Servo IDs/model/firmware:
Measured supply voltage idle / motion:
Current limit per axis:
Calibration low/high/released/engaged:
UART/USB trace filenames:
Cable arch height:
Camera/scale displacement per cycle:
Host unplug / process kill / reset outcome:
Faults and reproduction steps:
Pass/fail and next change:

## 2026-10-02 — OpenCR first-class target

- Added allocator-free Cortex-M7 board facade, clocks/timer/watchdog/power, USB CDC device, direct-device USB host primitives, four UARTs/shared TTL+RS485 DXL, SPI/I2C/CAN, ADC/PWM/GPIO/EXTI/OLLO electrical access, revision-aware IMU, buzzer, RTC/backup and reserved flash scratch storage.
- 24 shared SlowWire tests and 18 OpenCR aggregate tests passed. Aggregate tests overlap common protocol tests; these are not 42 unique peripheral tests.
- Full build passed for Pico/OpenRB/OpenCR firmware, Windows commissioning host and compile-only Cortex-M7 driver coverage. Host frame self-test and application vector checks passed.
- OpenCR ELF: text 19,956 bytes, initialized data 628 bytes, BSS 512 bytes. Linker reserves factory-loader/legacy EEPROM areas, scratch sector 7 and 16 KiB stack. Application bin SHA256: 22D1B509E57B19B4179B3A1C325773DB4B644E1C8ECADAF20C00795F5A6D03A4.
- Flash erase/program primitive inspected in coverage-object disassembly: SRAM section has no external calls. USB host classes/hubs and typed tables for other servo models are not implemented.
- OpenRB/OpenCR CDC serial descriptors now derive from silicon IDs and survive bus reset. Private lab VID/PID is unchanged.
- Physical upload, board boot, USB, bus timing, switch harness, IMU, storage and actuator tests remain unperformed. No uploader or board attached. Native SB0 CDC/FTDI host integration remains pending.
- Required OpenCR harness: disable PF15 robot rail; remove TTL VDD conductor; external regulated 5 V high-side switch controlled by PE10 with default-off pull-down. Verify reset/loader/off behaviour against a dummy load before attaching XL330.
- See OPENCR.md for commands, pin ownership, procurement searches and ordered daily bench gates.
