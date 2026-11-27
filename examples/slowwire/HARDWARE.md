# SlowWire feedback prototype: purchase and bring-up specification

Decision date: 2026-10-02. Budget: THB 5,000–12,000 excluding tools.

Use **OpenRB-150 as the main embedded controller and U2D2 as the direct-PC comparison**, sharing three ROBOTIS DYNAMIXEL XL330-M288-T TTL smart servos. Neither path requires a Pico or a discrete UART buffer. This is a provisional optimum for **repeatable feedback and driver development**, rather than minimum purchase cost. The motor mechanics and magnetic capture force still need experiments. The purchased bare DRV8841 chips do not drive these servos: the servos contain their own motor electronics.

The v0.2 supplied document is the mechanical starting point: stationary rear/front magnet arms below a flexible track and a centre arch magnet above it. The v0.1 large electromagnet array is a separate, substantially more expensive experiment. None of the documents establish measured locomotion. Smart-servo encoders measure horn motion, not cable displacement, magnet force, or foot traction. Record the cable with an overhead phone camera and a millimetre scale as independent motion feedback.

## Why these parts

- OpenRB-150 has a SAMD21 Cortex-M0+, native USB, four ready-wired TTL ports, automatic bus direction and a PA28-controlled servo supply switch. The Sig application leaves power off at boot and cuts it on STOP, USB session changes and faults. Its 3 A total port rating is a design constraint, not 3 A per servo. USB power is insufficient for this fixture; select external VIN(DXL).
- U2D2 provides a second, independent transport to the same TTL servos. It uses FTDI USB serial, not CDC ACM, and does not supply actuator power. The full-Sig host runs the same feedback service as OpenRB. If the host hangs, servo bus watchdogs are the remaining software protection; keep a physical power-cut switch.
- The preserved alternative Pico H has native full-speed USB, fitted headers, a known ROM UF2 loader and a Cortex-M0+ target already supported by the local Sig compiler. It runs standalone firmware, not the AArch64 SB0S kernel. The current firmware requires B2 silicon; older revisions need additional USB enumeration handling.
- XL330-M288-T has absolute 12-bit position feedback and readable current, velocity, input voltage, temperature and fault registers. It offers current-based position control at 5 V. Its low-speed gearing suits the fixture better than the faster M077. It uses TTL Protocol 2.0, not PWM or RS485.
- Only the optional Pico build needs a DIP-14 SN74LV125AN; it uses two channels for a protected half-duplex UART: one tri-state transmitter and one continuously enabled receiver. Its input voltage tolerance avoids exposing Pico GPIO to a 5 V UART source. Do not substitute a 74HC125 powered at 5 V or an I2C MOSFET level-shifter board.
- A documented smart servo avoids adding encoder boards, analogue load-feedback circuitry and uncertain clones to the first driver experiment. Plain SG90/MG90S servos cannot report position or current. A NEMA17/DRV8841 assembly would add power, gearing and encoders without improving this initial fixture.

## Engineering estimates and limits

Assume a 5 g magnet/holder, an additional 10 mN cable load and a 20 mm arm:

`torque = (0.005 * 9.81 + 0.010) * 0.020 = 0.00118 N m`.

A tenfold initial design allowance is `0.0118 N m`. The manufacturer's 5 V **stall** figure is `0.52 N m`; that is not a continuous operating rating. The margin motivates low current limits, not maximum force. Magnetic attraction can dominate these estimates and must be measured with the actual magnets and gaps. Begin at 100 mA, with firmware accepting at most 150 mA for this fixture. Current is supply current on XL330 and is not a calibrated force sensor.

At 20 mm radius, one commanded encoder increment corresponds to `2*pi*20/4096 = 0.0307 mm` of arc travel. This is command resolution, not guaranteed positioning accuracy or cable movement. A 5 mm vertical arm displacement needs approximately `asin(5/20) = 14.5 degrees`, about 165 encoder increments. Start with a small sweep; mechanically cap the cable arch at 10 mm.

Three simultaneous 5 V stall currents total `3*1.47 = 4.41 A`. OpenRB servo ports are rated **3 A total**, so full simultaneous stall is outside this design. Keep the 100 mA commissioning limits (150 mA maximum accepted), avoid stalled arms, and use a **5 V / 3 A** enclosed supply and a 2 A inline fuse for the initial fixture. The fuse is wiring protection, not a precision current limiter. Suggested exact model: **MEAN WELL GST18A05-P1J**, plus its IEC C13 mains lead and a matching 5.5/2.1 mm centre-positive DC socket. Do not buy a similarly named 12 V or 24 V variant.

For a 30 cm one-way 18 AWG copper trunk, approximately `0.6 m * 0.021 ohm/m * 4.41 A = 0.056 V` conductor drop, before contacts. Use short 22 AWG servo branches with genuine connector cables; at 100 mA commission limits they have ample margin. The fuse protects wiring against a fault; software current limits do not replace it.

## Purchase list

Amounts below are **planning allowances**, not verified Thai delivered quotations. Search links are explicitly searches; Lazada hid listing details and no exact XL330 offer could be verified. Check the selected variant and delivered total before ordering. All three actuators must be XL330-M288-T, SKU **902-0163-000**.

| Item | Quantity | THB allowance | Source / exact search |
|---|---:|---:|---|
| Genuine XL330-M288-T with horn and mounting screws confirmed | 3 | 6,000–7,800 total | [ROBOTIS product](https://robotis.us/products/dynamixel-xl330-m288-t), [Lazada search](https://www.lazada.co.th/catalog/?q=XL330-M288-T) |
| OpenRB-150, genuine assembled board | 1 | 1,100–1,600 | [ROBOTIS manual](https://emanual.robotis.com/docs/en/parts/controller/openrb-150/), [Lazada search](https://www.lazada.co.th/catalog/?q=OpenRB-150) |
| U2D2, genuine USB-to-Dynamixel adapter | 1 | 1,300–2,200 | [ROBOTIS manual](https://emanual.robotis.com/docs/en/parts/interface/u2d2/), [Lazada search](https://www.lazada.co.th/catalog/?q=ROBOTIS%20U2D2) |
| Genuine regulated GST18A05-P1J 5 V/3 A brick, C13 lead, matching DC socket | 1 set | 500–900 | [manufacturer specification](https://www.meanwell.com/Upload/PDF/GST18A/GST18A-SPEC.PDF), [Lazada search](https://www.lazada.co.th/catalog/?q=GST18A05-P1J) |
| Genuine Robot Cable-X3P, JST-EH 3-pin, 180 mm; include feed cable | 4 cables total | 100–350 additional | One 180 mm cable is listed with each servo; confirm package, [Lazada search](https://www.lazada.co.th/catalog/?q=DYNAMIXEL%20Robot%20Cable%20X3P) |
| 18 AWG copper red/black trunk, 22 AWG branches, 26 AWG signal wire, screw terminals, ferrules/heat shrink | 1 set | 150–300 | [Lazada search](https://www.lazada.co.th/catalog/?q=18AWG%2022AWG%20silicone%20wire) |
| DC power-cut switch rated >=6 A at DC, 2 A inline fuse+holder, 1000 uF >=10 V capacitor | 1 set | 120–250 | [Lazada search](https://www.lazada.co.th/catalog/?q=DC%20switch%20inline%20fuse%20holder) |
| USB **data** cables: OpenRB USB-C; U2D2 USB-C or micro-B according to revision | 2 | 160–360 | [USB-C Lazada search](https://www.lazada.co.th/catalog/?q=USB%20C%20data%20cable), [micro-B search](https://www.lazada.co.th/catalog/?q=micro%20USB%20data%20cable) |
| Three 10x3 mm neodymium discs, small steel pickups, tape, rubber feet, PET strip, brackets, 20 mm arms, base, M2 screws | 1 set | 200–500 | [Lazada magnets](https://www.lazada.co.th/catalog/?q=neodymium%2010x3mm), [mounting hardware](https://www.lazada.co.th/catalog/?q=M2%20screws%20servo%20bracket) |

Combined planning allowance: **THB 9,630–14,260**, excluding tools and any unquoted import charges. Both controllers may exceed the THB 12,000 cap at the upper end. Keep the cap: use the first servo as the procurement/bench gate before paying for the other two if delivered prices exceed these allowances. Never silently replace the smart servos with PWM-only substitutes.

## Tools

Essential: a multimeter (check voltage, polarity and continuity), wire stripper, small side cutters, screwdriver set, tweezers, ruler/calipers, phone camera and a solid clamp/base. A temperature-controlled soldering iron, electronics solder, flux and heat shrink are useful for the external power breakout. OpenRB itself needs no interface soldering. A solderless breadboard is suitable for low-current logic signals; do not route servo power through it.

Recommended driver-debug tools: an 8-channel 3.3 V-compatible logic analyser sampling >=2 MHz for 57,600-baud UART, and a Raspberry Pi Debug Probe for SWD. A cheap 24 MHz analyser can inspect this UART but cannot validate 12 Mbit/s USB signal integrity. SWD is optional. OpenRB uses its factory USB bootloader; Pico uses UF2. An oscilloscope is useful later for supply dips, not required for the first USB echo test.

[Lazada multimeter search](https://www.lazada.co.th/catalog/?q=digital%20multimeter), [wire stripper](https://www.lazada.co.th/catalog/?q=wire%20stripper), [soldering station](https://www.lazada.co.th/catalog/?q=temperature%20controlled%20soldering%20station), [logic analyser](https://www.lazada.co.th/catalog/?q=24MHz%20logic%20analyzer), [Debug Probe](https://www.lazada.co.th/catalog/?q=Raspberry%20Pi%20Debug%20Probe).

## Main OpenRB wiring

1. With power disconnected, set the DXL power jumper to **VIN(DXL)** per the board drawing.
2. Supply positive -> 2 A fuse -> DC power-cut switch -> OpenRB VIN terminal; negative -> OpenRB GND. Set/check **5 V** with a multimeter before connecting XL330 units. The board supports higher voltages, but these servos do not.
3. Connect the labelled servos (rear ID 1, arch ID 2, front ID 3) to three TTL ports with genuine X3P cables. The fourth port remains spare. Do not use Dupont/breadboard contacts for servo power.
4. Connect the PC to OpenRB USB-C with a data cable. USB powers logic; VIN powers the switched servo rail. Keep magnets and arms off during electrical commissioning.

Use 18 AWG copper for the supply trunk and genuine servo cables for branches. No loose direction-control or level-shifter wires are needed. Do not feed the servo rail from the board's small auxiliary 5 V pin.

## U2D2 comparison wiring

Power off and disconnect OpenRB's DATA connection before switching paths. **Only one controller may drive this bus.** Use the same servos and IDs, not a second set.

PC USB -> U2D2 -> **3-pin TTL port** -> external powered X3P breakout -> servo chain. The breakout joins DATA straight through, all grounds together, and injects regulated 5 V into the servos' VDD. Use a proper JST-EH 3-pin/2.5 mm breakout or made-up X3P feed cable with screw terminals; check the connector drawing and continuity before power. Include its cost in the cable/wiring allowance. Never connect the 4-pin RS485 port to an XL330.

Keep the same upstream fuse and physical power-cut switch. U2D2 has no firmware-controlled power switch and does not power the servos through USB. Do not buy a 12 V supply bundled with another Dynamixel model. Confirm U2D2 cable type with the seller: newer units use USB-C; older stock uses micro-B.

## Preserved Pico wiring (optional alternative)

Power off while assembling. Check the manufacturer's connector drawing: do not infer the pin order from wire colours or reverse the drawing's mating view.

| Connection | Destination |
|---|---|
| USB data cable | PC to Pico micro-B; USB powers only Pico/interface |
| Pico 3V3, physical pin 36 | SN74LV125AN VCC pin 14; 100 nF to pin 7 at the chip |
| Pico GND, physical pin 3 | Buffer pin 7, external 5 V supply negative, servo connector GND |
| GP0, physical pin 1 (UART0 TX) | Buffer channel 1 A, pin 2 |
| GP2, physical pin 4 (direction, HIGH=receive) | Buffer channel 1 /OE, pin 1; 10 kohm pull-up to 3V3 |
| Buffer channel 1 Y, pin 3 | 33 ohm series resistor, then shared servo DATA bus |
| Servo DATA bus | Buffer channel 2 A, pin 5; 10 kohm pull-up to 3V3 |
| Buffer channel 2 /OE, pin 4 | GND; receiver remains enabled |
| Buffer channel 2 Y, pin 6 | GP1, physical pin 2 (UART0 RX) |
| Unused buffer /OE pins 10 and 13 | 3V3; unused input pins 9 and 12 to GND; outputs 8 and 11 unconnected |
| External +5 V | 2 A fuse, power-cut switch, distribution terminal, servo connector VDD |
| 1000 uF capacitor | Across servo distribution +5 V/GND; observe polarity |

Keep data/interface wiring approximately 20 cm or shorter for this first fixture. Keep the USB cable intact, insulate steel pickups, and strain-relieve both USB connectors. The moving span is part of the cable body; the PC and Pico connectors stay fixed.

**Do not connect the external +5 V servo rail to Pico VBUS, VSYS or 3V3.** Grounds connect. A power-cut switch must remove the servo rail without relying on USB commands. Use the specified low-current limits while keeping aggregate demand below the 3 A supply rating. A STOP drops torque: fit mechanical supports so a released magnet arm cannot fall into the cable.

## Evidence and daily gates

This checkout has executable Sig protocol tests, cross-compiled OpenRB and RP2040 firmware, a generated Pico UF2 and a U2D2 host executable. No OpenRB, U2D2, Pico or servo fixture was detected on this computer. Electrical operation, USB enumeration, feedback accuracy, thermal behaviour and locomotion remain **unverified**. The existing AArch64 QEMU USB lab is separate evidence for that OS; QEMU does not emulate this OpenRB/Pico fixture. Native SB0S CDC and FTDI host integration remain later tasks; the initial live commissioning clients use Windows COM.

| Day / gate | Work | Exit evidence |
|---|---|---|
| 0: software foundation | Bounded Protocol 2.0, XL330 control table, CRC-framed host link, USB CDC, RP2040 flash image | Sig tests, linked ELF, validated UF2 structure; complete in this checkout |
| 1: USB only | Flash OpenRB with servo supply disconnected; repeat USB-only checks on the U2D2 COM transport; enumerate; hello/heartbeat; repeat reconnect/reset | Correct descriptors, stable COM, matching replies, zero frame CRC failures |
| 2: one bare servo | Wire OpenRB VIN and power distribution; repeat the one-servo test using the U2D2 breakout; assign ID one device at a time; ping/config/read | Model 1200, measured 4.5–5.5 V, current/temp feedback; logic-analyser TX turnaround capture |
| 3: three servos, no magnets | IDs 1/2/3, readback, manual horn calibration, very small jogs | Every axis reports actual target; unplug/kill-host stops; no automatic restart |
| 4: magnetic fixture | Add arms/track/pickups, measure force and arch height, record cable scale | Repeatable clamp/release and <=10 mm arch without connector load |
| 5: finite gait | One cycle then two; record horn feedback AND cable displacement | Repeatability, no missed steps, no USB framing loss, no overtemp/voltage faults |
| 6+: native host | Add CDC ACM and FTDI host paths to the chosen SB0 kernel revision, preserve in-flight kernel work | Same protocol/limits under native SB0; hardware test with real USB passthrough |

Advance by evidence, not elapsed dates. Record each bench session in `BENCH_LOG.md`; do not enable autonomous motion before the previous gate passes.

## Primary references

- [ROBOTIS XL330-M288 manual](https://emanual.robotis.com/docs/en/dxl/x/xl330-m288/)
- [DYNAMIXEL Protocol 2.0](https://emanual.robotis.com/docs/en/dxl/protocol2/)
- [RP2040 datasheet and errata](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf)
- [Pico hardware](https://www.raspberrypi.com/products/raspberry-pi-pico/)
- [TI SN74LV125A](https://www.ti.com/product/SN74LV125A)
- [MEAN WELL GST60A](https://www.meanwell.com/Upload/PDF/GST18A/GST18A-SPEC.PDF)

User source documents were read as design material, not instructions: SB3_SlowWire_Whitepaper_v0.1.pdf, SB3_SlowWire_Low_Cost_Prototype_v0.2.pdf, and the v0.2 kit ZIP in the user's Downloads directory.

- [OpenRB-150 specifications and power selection](https://emanual.robotis.com/docs/en/parts/controller/openrb-150/)
- [OpenRB pin mapping and upload recipe](https://github.com/ROBOTIS-GIT/OpenRB-150)
- [U2D2 power and FTDI latency settings](https://emanual.robotis.com/docs/en/parts/interface/u2d2/)
- [Selected 5 V/3 A supply](https://www.meanwell.com/Upload/PDF/GST18A/GST18A-SPEC.PDF)

## OpenCR addition

OpenCR 1.0 is now a first-class optional expansion target alongside both selected paths. Share the same three XL330s and 5 V supply. Add a genuine board, micro-B data cable and separately switched 5 V breakout harness; its built-in DYNAMIXEL VDD is not suitable as an assumed 5 V servo supply. Full wiring, procurement searches, peripheral matrix and pin restrictions are in [OPENCR.md](OPENCR.md). The combined three-board purchase may exceed the original THB 12,000 ceiling; OpenRB remains the economical first bring-up board.
