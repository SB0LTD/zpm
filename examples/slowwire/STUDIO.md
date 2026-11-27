# SlowWire Studio

SlowWire Studio is a native Sig/Win32/OpenGL desktop workbench for the SlowWire
device link. It uses the same layered glass panels, fine grid lines, compact
status badges and restrained mint/cyan accents as SB0 Trade. The window is
translucent and DPI aware; its layout follows the current client size.

Build and launch it from PowerShell:

```powershell
./examples/slowwire/build-ui.ps1
./.build/slowwire-studio.exe
```

It discovers the USB serial Nano on COM9 at 57600 8N1, waits for its bootloader
reset, checks the ATmega328P signature, then polls telemetry at 4 Hz and sends
heartbeats while connected. If the link drops, the dashboard shows its state and
tries to reconnect. Closing the window sends stop before releasing the port.
An explicit `--port` option and device picker are planned; COM9 is the current
bring-up default.

The first view includes the controller identity and link status, a rolling
single-wire capacitive electrode chart, raw telemetry cards, CRC fault count, adaptive-context
selection lineage, activity receipts, and safe LED controls. LED commands are
constructed only after the native Galaxy context projection selects current
policy, fresh device telemetry and the owner-requested action. The firmware
validates the command and lease independently. It advertises zero motor axes.

The reusable UI state model is in `ui/model.sig`. It has fixed-capacity typed
sensor descriptors, a bounded 120-sample history per chart path, 32 activity
receipts and 32 widget descriptors. Sensor kinds cover digital and analog
values, capacitive charge counts, calibrated voltage, temperature, position, force and camera frames.
Widgets describe their kind, source and sensor separately from platform I/O.
`ui/widgets.sig` contains composable panel, metric, trend-chart, badge and event
feed components; `ui/app.sig` owns the Win32 lifecycle, link and layout.

The dashboard marks cameras, motor feedback, and other buses as unavailable
until an actual source reports them. Adding a camera or actuator therefore
means adding its transport/driver, registering its typed source and widgets,
and exposing only measured values. The Nano's internal bandgap ADC is not an
calibrated voltage or actuator feedback. The first appendage uses a single
enameled wire on A0 and a 4.7 MΩ resistor between A0 and D2; see [NANO.md](NANO.md)
for the wiring and safe bring-up steps.

The desktop app, like the rest of this package, has fixed-capacity runtime
storage and no UI toolkit dependency. Window, OpenGL, font rasterization and
Win32 serial support come from the workspace's shared ZPM platform modules.
The current board build and physical Nano test are documented in [NANO.md](NANO.md).
