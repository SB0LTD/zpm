# OpenCR 1.0: first-class full-Sig ZPM target

OpenCR joins OpenRB-150 and U2D2; OpenRB remains the simpler first servo fixture. OpenCR adds a Cortex-M7, onboard IMU, CAN, RS485 and considerably more peripheral access. It runs standalone Sig firmware, not the AArch64 SB0S kernel. Application and drivers are allocator-free `.sig`; no Arduino/HAL/ROS firmware is linked. The existing factory bootloader and its vendor uploader are external tools.

**Qualification: offline contracts and cross-compilation only. No physical board boot, enumeration, actuator or peripheral has been verified.** Drivers are implemented for the functions listed below, not a claim of complete STM32 HAL or USB class coverage.

## Build and USB-only boot

```powershell
.\examples\slowwire\build.ps1
sig build test-opencr
.\examples\slowwire\flash-opencr.ps1 -BootloaderPort COM8 -Uploader 'C:\path\to\opencr_ld.exe'
.\.build\slowwire\slowwire-host.exe --opencr COM7
```

Leave all actuator supplies disconnected initially. Enter the factory loader using the manufacturer's PUSH SW2 / RESET procedure. The script invokes `opencr_ld COM8 115200 opencr.bin 1`, checks vector/image bounds, and does not mass-erase or replace the bootloader. The uploader is not installed here. Recheck the COM number after application enumeration.

Application starts at **0x08040000**; aligned stack top is **0x20050000**. Vendor warm-shared RAM below 0x200114EC and the legacy EEPROM area at 0x08010000 are preserved by the application linker. Sector 7, 0x080C0000–0x08100000, is reserved for explicit scratch storage; its erase/program API is not EEPROM emulation. Do not assume scratch survives every future uploader. Firmware is limited to 512 KiB and the linker reserves 16 KiB stack. Initialization disables inherited caches/MPU, selects the 25 MHz HSE / 216 MHz PLL CPU and 48 MHz USB clocks, and starts an independent watchdog. Hardware oscillator/startup timing remains a bench gate.

USB uses a private lab identity and fixed-capacity CDC buffers. OpenCR and OpenRB serial descriptors use silicon IDs. A production VID/PID remains to be assigned. CDC is the USB device mode used by the fixture; OpenCR's USB host primitives are an alternate mode and cannot run simultaneously.

## XL330 power harness: required before actuation

The OpenCR DYNAMIXEL supply is a robot power rail, **not a dedicated regulated 5 V XL330 rail**. Keep its PF15 power enable disabled. The firmware does this even when fixture power is requested. Connect only TTL DATA and GND from OpenCR to the servo breakout; physically disconnect the board-side VDD conductor. Do not connect an ordinary complete three-wire cable to these 5 V servos.

Use the existing regulated 5 V / 3 A supply, 2 A fuse, physical DC power-cut switch and short 18 AWG trunk. Add a **Pololu Mini Pushbutton Power Switch LV #2808**, fitted headers, for the firmware-controlled high-side cut:

| Connection | Destination |
|---|---|
| Supply +5 V after fuse and physical cut | Switch VIN |
| Supply GND | Switch GND, OpenCR GND and servo GND |
| Switch VOUT | Servo breakout +5 V only |
| OpenCR expansion GPIO7, Arduino pin 56, PE10 | Switch CTRL |
| 10 kOhm resistor | CTRL to GND, mounted at switch |
| OpenCR TTL DATA | Servo breakout DATA |

Leave ON/OFF and pushbutton contacts unconnected. CTRL high requests ON and low requests OFF. The pull-down must hold the switch OFF with the MCU disconnected, in reset and in the factory loader. Verify this with a meter and a dummy load before connecting a servo; if the assembled module does not meet that test, do not commission it. The module's button/latch circuitry does not replace the independent physical power cut. No servo current flows through the breadboard or PE10. Board USB power is sufficient for the first logic checks; the servo supply is separate.

Boot, STOP, faults, USB session changes and shutdown set PE10 low. The watchdog resets the MCU after a hang; the external pull-down must keep power OFF during reset. Begin with one bare servo at 100 mA, then use the shared commissioning/calibration procedure in README. Maximum fixture setting remains 150 mA per axis. Do not add magnetic arms until stop, power cut and reconnect behaviour are measured.

## Driver surface and pin ownership

Import `opencr.sig` as a ZPM module. The facade exports `board`, `uart`, `usb`, `usb_host`, `io`, `spi`, `i2c`, `can`, `rtc`, `flash`, `imu` and `diagnostics`. Shared Protocol 2.0 and XL330 drivers remain in `slowwire.sig`. Low-level callers must coordinate ownership themselves; the USB diagnostics use `io.Mux` to reject collisions before changing pin modes.

| Driver | Implemented functions and actual hardware |
|---|---|
| Board | Clock/reset handoff, GPIO, active-low LEDs, buttons/DIP, TIM5 1 MHz timebase, independent watchdog, external fixture power |
| UART / DYNAMIXEL | USART6 header PC6/7; USART2 BT1 PD5/6; UART8 BT2 PE1/0; USART3 DXL PC10/11 with PC9 direction and bounded turnaround |
| DYNAMIXEL | Shared TTL and RS485 physical interfaces on one USART3 bus; framing/CRC/status, existing typed XL330 feedback/control service |
| USB device | OTG-FS polled CDC ACM control/bulk, endpoint stalls, reset/suspend/session tracking, bounded receive ring, silicon serial descriptor |
| USB host | One directly attached FS/LS device, port reset, device descriptor/address, control and one-packet bulk/interrupt transactions; no hubs, class drivers, isochronous or DMA |
| SPI | SPI1 IMU PA5/PA6/PB5; SPI2 header PA9/PB14/PB15, CS PB9; SPI4 expansion PE12/13/14, CS PE11; modes and bounded transfers |
| I2C | I2C1 PB8/PB7 and I2C2 PB10/PB11, 7-bit addressing, 100 kHz, repeated start, NACK/arbitration/timeout handling |
| CAN | bxCAN2 PB12/13, standard/extended/RTR frames, 125/250/500/1000 kbit/s, loopback, mailboxes, FIFO overflow and error state |
| ADC / PWM | ADC1/3 12-bit single reads, battery divider estimate; six PWM outputs PB4, PA8, PA2, PA3, PB9, PB15, 1–20,000 Hz and 0–1000 duty |
| GPIO / OLLO / EXTI | Board pin mapping, holes rejected, resource claims, pull modes, polled edge flags; electrical GPIO/ADC access to OLLO connectors, no assumed sensor-specific protocol |
| IMU | MPU9250 + AK8963 or ICM20648 auto-detection, banked configuration, signed raw accel/gyro/temp; valid magnetic readings and factory adjustment on MPU9250 only |
| Buzzer | Bounded polled tone 50–4000 Hz; timing jitter possible during other transactions |
| RTC / backup | LSE time/date, validated leap calendar, 32 backup registers; unset clock requires explicit initialization |
| Flash | Reserved-sector bounds, read, explicit erase, aligned 1-to-0 word programming, verification; erase/program primitive executes from SRAM and feeds watchdog |

TTL and RS485 ports are parallel connections to the **same bus**, not six independent UARTs. IDs must be unique across both interfaces. Generic Protocol 2.0 framing does not supply a typed control table for every other servo model. Bluetooth connectors expose UART only; Bluetooth profiles are not implemented. Analog signals must remain within 0–3.3 V; use external 3.3 V I2C pull-ups. PWM pins PB9/PB15 conflict with SPI2; diagnostics reject that sharing. TIM5 is reserved for time. PE10, PF15, DXL, USB and onboard sensor/control pins cannot be repurposed through bench GPIO.

## USB bench console

Use `stop` before diagnostics. All peripheral mutation and transaction commands require a disarmed fixture with actuator supply OFF; button reading is also allowed while armed. Diagnostics outputs print decimal bytes. Multi-byte values are little endian; IMU axes and temperature are signed i16 raw units, not fused orientation or degrees Celsius. `board` returns board kind 3, diagnostic version 1, detected sensor model (0 until detected), CPU rate and capability bits.

Convenience commands:

```text
board
buttons
led 2 1
adc 16
gpio 2 2 0
pwm 1 50 75
imu
battery
i2c 0 104 0 1
i2cw 0 104 0 1
spi 0 128 0
can-start 2 1
can-read
tone 440 100
rtc
stop
```

`led` accepts 2–4; LED1 indicates fixture state. `adc` uses board numbers (A0 is 16). `gpio N MODE VALUE`: mode 0=input, 1=output, 2=pull-up. `pwm CHANNEL HZ DUTY`: channel 1–6, duty per thousand; PWM is GPIO waveform generation, not a feedback servo driver. `i2c/i2cw CHANNEL ADDRESS REGISTER COUNT_OR_VALUE` use channel 0/1 and 7-bit decimal addresses. `spi CHANNEL BYTE...` uses channel 0=header or 1=expansion and its fixed CS. `can-start RATE LOOPBACK`: rates 0/1/2/3 correspond to 125/250/500/1000 kbit/s. `stop` disables active diagnostic outputs as well as actuator power.

Raw `io BYTE...` exposes RPC opcode 13 subcommands. Opcode 12 is board information. Replies begin with the existing RPC status; the console omits the successful status from printed bytes.

| Subcommand | Request bytes after subcommand | Successful data |
|---:|---|---|
| 1 | none | Buttons/DIP bitmask |
| 2 | LED internal index 1–3, boolean | none |
| 3 | ADC board pin | u16 raw |
| 4 | PWM index 0–5, Hz u16, duty u16 | none |
| 5 | Board pin, mode, value | GPIO boolean |
| 6 | none | Model, accel[3], gyro[3], temperature, magnetic-valid, optional magnetic[3] |
| 7 | I2C channel, address, tx length, rx length, tx bytes | RX bytes, each length <=32 |
| 8 | SPI channel, 1–32 TX bytes | RX bytes |
| 9 | CAN rate index, loopback boolean | none |
| 10 | CAN ID u32, flags (extended=1, RTR=2), length, data | none |
| 11 | none | Present, ID u32, flags, length, data when present |
| 12 | UART channel 0=header/1=BT1/2=BT2, rate 0=9600/1=57600/2=115200, tx length, rx length, TX | RX bytes, lengths <=32 |
| 13 | none | RTC calendar; first unset read reports Busy |
| 14 | Scratch offset u32, length <=32 | Read-only scratch bytes |
| 15 | none | Estimated input millivolts u32 |
| 16 | Buzzer Hz u16, duration ms u16 | none |
| 17 | Year u16, month, day, weekday 1–7, hour, minute, second | Set RTC |
| 18 | Backup index 0–31, write boolean, optional value u32 | Backup value u32 |

Flash erase/program and USB host mode are explicit library APIs and compile-covered by `opencr_driver_check.sig`; they are not exposed by the CDC bench console. The coverage object is never run or flashed. RTC requests allow 5 s on the host for initial LSE startup while actuator power is OFF. CDC remains serviced during peripheral waits.

## Systematic hardware gates

1. Day 1: USB-only flash, `hello`/`board`, serial descriptor, reconnect/reset/suspend captures. Check clock and power-enable defaults with a meter/scope.
2. Day 2: dummy-load switch tests, physical cut, watchdog reset, USB loss and STOP. Record voltage transients. One unmounted XL330: provisioning, torque-off, feedback and current limit. Compare OpenRB/U2D2/OpenCR using the same servo and supply.
3. Day 3: UART loopbacks, SPI loopback, 3.3 V ADC references, PWM scope measurements, button/EXTI, I2C reference sensor, both IMU revisions where available. CAN loopback first, then second node and bus termination; test disconnect/NACK/timeout paths.
4. Day 4: RTC set/read/reset and backup retention; isolated scratch erase/program/read with power loss recovery experiments. Test USB host separately with correctly powered OTG wiring; direct device enumeration is the first gate.
5. Day 5: commission three servos, independent camera measurements and low-current finite gait, with magnets introduced last. Save logs and observed failures before increasing scope.

Native SB0S still needs CDC ACM host integration for OpenRB/OpenCR and FTDI host integration for U2D2. QEMU OS tests do not qualify these physical interfaces. No daily automation has been created.

## Purchase additions and tools

Add one genuine **OpenCR 1.0, SKU 903-0257-000**, one micro-B USB data cable, the #2808 switch/header pair, 10 kOhm pull-down, insulated TTL power-breakout harness and breadboard signal jumpers. Share the three XL330s, supply, horns, wiring and tools with the other paths. Do not buy three more motors. OpenCR is an additional lab board and may push the combined purchase past THB 12,000; obtain a delivered Thai quote before committing. Lazada links below are exact-name searches, not verified stocked offers.

- [OpenCR Lazada search](https://www.lazada.co.th/catalog/?q=OpenCR%201.0)
- [Pololu 2808 Lazada search](https://www.lazada.co.th/catalog/?q=Pololu%202808), [manufacturer wiring and ratings](https://www.pololu.com/product/2808)
- [Micro-B data cable](https://www.lazada.co.th/catalog/?q=micro%20USB%20data%20cable)
- [Headers and Dupont signal leads](https://www.lazada.co.th/catalog/?q=2.54mm%20headers%20dupont), [10 kOhm resistors](https://www.lazada.co.th/catalog/?q=10k%20resistor)
- [CAN cable and 120-ohm termination](https://www.lazada.co.th/catalog/?q=CAN%20twisted%20pair%20120%20ohm)

Minimum tools: multimeter, wire stripper, soldering iron/solder, small screwdrivers and insulated terminal connections. A logic analyzer and oscilloscope are needed to qualify USB/UART turnaround, PWM and power transients; a second CAN node is needed for physical CAN testing. SWD/ST-LINK and OTG host adapter are optional later additions; the factory USB loader is the initial programming route. USB protocol capture on Windows and timestamped logs are useful without changing application language.

References: [ROBOTIS board manual](https://emanual.robotis.com/docs/en/parts/controller/opencr10/), [official board sources](https://github.com/ROBOTIS-GIT/OpenCR), [official hardware schematics](https://github.com/ROBOTIS-GIT/OpenCR-Hardware), [STM32F746 documentation](https://www.st.com/en/microcontrollers-microprocessors/stm32f746zg.html). The board revision matters: older MPU9250 includes magnetometry; newer ICM20648 has six axes only.
