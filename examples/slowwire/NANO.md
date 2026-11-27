# Connected Nano bring-up

On 2026-10-05, the USB-only board on COM9 was identified by its STK500v1
bootloader as ATmega328P (signature 1E950F), at 57600 baud. The CH340 USB bridge
uses the official signed WCH 4.0.2026.2 driver. This is the classic 2 KiB SRAM,
32 KiB flash class of Nano, not a Nano ESP32 or Nano 33.

Galaxy owns adaptive context on the host. The Nano runs a bounded, allocator-free
Sig endpoint using the existing SlowWire protocol. Its single UART is occupied
by the USB bridge. Do not share D0/D1 with a DYNAMIXEL bus. OpenRB/OpenCR remain
the feedback-capable actuator backends; U2D2 remains the direct host bus option.

## What runs today

`nano.sig` implements ATmega328P reset vectors, SRAM initialization and native
Sig I/O, linked using AVR binutils. There is no Arduino runtime, C firmware,
Node or Caliber dependency. Application flash is limited to 30 KiB to preserve
the old bootloader. The linker reserves at least 1 KiB SRAM for the stack.

The endpoint starts with the LED off and all other GPIO as inputs, and advertises
zero motor axes. Identity, heartbeat, stop, telemetry and onboard LED commands
use the existing SW v1 frame and CRC. Motor configuration/arm/jog/run operations
return unsupported. This firmware is an I/O endpoint, not an actuator controller.
The software 500 ms lease turns off the LED without host traffic; it is not a
hardware motor safety mechanism.

Responses preserve sequence and set the operation's response bit (0x80).
Payload byte 0 is status: 0 success, 1 invalid arguments, 2 unsupported.
Identify/hello/board returns nine bytes: status, ABI=1, processor signature
1E 95 0F, capability mask LE16=7 (LED, internal reference ADC, capacitive input), zero axes, reserved zero. board_io accepts
exactly one byte, 0 or 1, for the onboard LED. Telemetry returns sixteen bytes:
status, state revision LE32, uptime milliseconds LE32, LED state, internal
bandgap ADC raw LE16, rejected-CRC counter LE32. The LED state is the commanded
register state, not an independent optical or electrical measurement. Internal
ADC is not actuator position/current feedback and is not calibrated voltage.

`nano-host.sig` imports the same `context_projection.sig` used by Galaxy.
Before LED commands it selects required policy, fresh CRC-verified observation
and the explicitly requested diagnostic action. Action dependencies retain
policy and telemetry provenance. Expired required telemetry refuses command
selection, and untrusted hypotheses cannot become instructions. The endpoint
still checks every command independently of host context selection.

This is a real-device validation harness using Galaxy's projection machinery.
It does not yet connect the complete Galaxy cognitive agent or its native USB
stack to this board, and makes no claim about model-driven motor control.
Native Galaxy CH340 transport and hardware actuator integration are outstanding
work before that larger system can be called complete.

## Build, flash and reproduce

Windows Sig 0.6.0 and WSL Ubuntu `binutils-avr` are used. The direct Sig
`build-exe` AVR path currently fails inside compiler_rt due to function-pointer
flash/generic address spaces. `build-obj` works; the freestanding startup supplies
the only needed runtime primitive, memcpy, in inline assembly.

```powershell
./examples/slowwire/build-nano.ps1
./examples/slowwire/flash-nano.ps1 -Port COM9 -Backup C:/Just-Things/Projects/sb0/.work/nano-bringup/original-flash.bin
./.build/slowwire-nano-host.exe COM9
```

Only use this flashing command with the identified USB-only ATmega328P board.
Flash verification checks the full 32768 bytes: application bytes, padding and
all untouched bytes, including the original bootloader. It never writes EEPROM,
fuses or lock bits. Original flash is backed up in the workspace bring-up folder.
The build command does not flash hardware.

The physical test passed identity, safe boot LED state, stale-context refusal,
unsupported arm, heartbeat retention, lease timeout, corrupt-command rejection,
and 200 context-selected LED command/telemetry cycles. It ended with the LED off.

Opcode 14 measures the charge response of one capacitive electrode and reports
relative firmware-loop counts. It is not calibrated capacitance or distance.
For the first appendage, use one 5–10 cm strand of the pictured enamelled copper
as the electrode, with a 4.7 MΩ resistor between Nano D2 and A0. Join the
electrode to the A0/resistor junction. The wire is the only appendage; the
resistor is the sensing element. Keep the enamel intact along the strand and
scrape about 5 mm from the end that enters the A0 node. Do not connect the
electrode to 5 V or GND. The firmware pulses D2 through the resistor and senses
the rise on A0; keep D2/A0 reserved for this circuit. The Studio trace should
rise when a finger approaches or touches the insulated wire. Longer wire and
higher resistance increase sensitivity but also noise and response time.
The existing 24 SlowWire core contracts also passed. See the checked-in
`nano-validation.json` for measured firmware identity and scoped results.

For the connected glass dashboard and interactive telemetry/control panels, see
[STUDIO.md](STUDIO.md). The UI lives on the host and communicates with this same
controller over the Nano's USB serial bridge.

Device register and memory specifications:
[Microchip ATmega328P](https://www.microchip.com/en-us/product/ATMEGA328P),
[official datasheet](https://docs.arduino.cc/resources/datasheets/Atmel-42735-8-bit-AVR-Microcontroller-ATmega328-328P_Datasheet.pdf).
