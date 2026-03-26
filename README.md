<p align="center">
  <img src="zpm.png" alt="ZPM" width="200" />
</p>

<h1 align="center">ZPM</h1>

<p align="center">
  <em>Über alles.</em><br/>
  <sub>Hermetic Efficiency Interference Layer</sub>
</p>

<p align="center">
  <code>Unapologetic</code> · <code>Opinionated</code> · <code>Familiar</code> · <code>Efficient</code>
</p>

<p align="center">
  A coherent family of low-level Zig modules for building native Windows applications with OpenGL rendering.
</p>

---

## Principles

- No hidden allocations — all storage is stack or comptime-sized
- No implicit work — every cost is visible
- No standard library I/O at runtime — pure Win32 + OpenGL extern calls
- Explicit over convenient
- Zero-cost abstractions only

## Architecture

Four layers, strictly ordered — lower layers never import from higher layers.

### Layer 0: Core

Pure data types, math, storage, and logic. No platform dependencies, no I/O.

| Module | Source | Description |
|--------|--------|-------------|
| `core` | `src/core/root.zig` | Coarse-grained re-export of all core subsystems |
| `math` | `src/core/math.zig` | Sin/cos approximations, lerp, interpolation, pure math |
| `json` | `src/core/json.zig` | Minimal JSON parser |


Core also contains (accessed via `core.*`):

| Submodule | Source | Description |
|-----------|--------|-------------|
| `core.types` | `src/core/types.zig` | OHLCV, candle types, fundamental data structures |
| `core.fmt` | `src/core/fmt.zig` | Number/price formatting utilities |
| `core.config` | `src/core/config.zig` | Config parsing logic |
| `core.config_types` | `src/core/config_types.zig` | Config struct definitions (Subscription, Credentials) |
| `core.metadata` | `src/core/metadata.zig` | SourceMetadata — available symbols/intervals |
| `core.aggregator` | `src/core/aggregator.zig` | 1m → higher TF candle aggregation (pure math) |
| `core.trading.order` | `src/core/trading/order.zig` | Order types and structures |
| `core.trading.order_entry_state` | `src/core/trading/order_entry_state.zig` | Order entry panel state |
| `core.trading.orderbook` | `src/core/trading/orderbook.zig` | Order book depth data |
| `core.trading.position` | `src/core/trading/position.zig` | Position and balance types |
| `core.ui.action` | `src/core/ui/action.zig` | Action enum for dispatch |
| `core.ui.debug_state` | `src/core/ui/debug_state.zig` | Debug console state |
| `core.ui.settings_state` | `src/core/ui/settings_state.zig` | Settings overlay state |
| `core.ui.frame_state` | `src/core/ui/frame_state.zig` | Per-frame render state |
| `core.ui.ring_log` | `src/core/ui/ring_log.zig` | Fixed-size ring buffer log |
| `core.data.manager` | `src/core/data/manager.zig` | DataManager — candle storage and access |
| `core.data.data_types` | `src/core/data/types.zig` | Data layer type definitions |
| `core.data.cache_reader` | `src/core/data/cache_reader.zig` | Binary cache file reader |

### Layer 1: Platform

OS bindings and system services. Windows-only (Win32 API). May import from core.

| Module | Source | Description |
|--------|--------|-------------|
| `platform` | `src/platform/root.zig` | Coarse-grained re-export of all platform subsystems |
| `win32` | `src/platform/win32.zig` | Hand-written Win32 type/constant/extern bindings |
| `gl` | `src/platform/gl.zig` | OpenGL 1.x constants and function externs |
| `window` | `src/platform/window.zig` | Borderless WS_POPUP window creation and management |
| `input` | `src/platform/input/run.zig` | Keyboard + mouse input handling (directory module) |
| `timer` | `src/platform/timer.zig` | High-precision timer via QueryPerformanceCounter |
| `threading` | `src/platform/thread/run.zig` | Thread pool and worker management (directory module) |
| `http` | `src/platform/http.zig` | HTTP client via WinHTTP |
| `crypto` | `src/platform/crypto.zig` | HMAC-SHA256 via BCrypt |
| `file_io` | `src/platform/file.zig` | File I/O via Win32 CreateFile/ReadFile/WriteFile |
| `seqlock` | `src/platform/seqlock.zig` | Sequence lock for lock-free concurrent reads |
| `screenshot` | `src/platform/screenshot.zig` | GL framebuffer capture |
| `logging` | `src/platform/log/run.zig` | Logging subsystem (directory module) |
| `png` | `src/platform/png/encode.zig` | PNG encoder with deflate compression (directory module) |
| `mcp` | `src/platform/mcp/run.zig` | Embedded MCP server on 127.0.0.1:3001 (directory module) |

System libraries linked transitively: `kernel32`, `gdi32`, `user32`, `shell32`, `opengl32`, `winhttp`, `bcrypt`, `ws2_32`

### Layer 1: Transport

QUIC transport stack — a generic, reusable QUIC implementation that knows nothing about packages, registries, or zpm semantics. The core modules can be reused for any custom binary protocol. Only `appmap.zig` bridges zpm-specific operations to QUIC lanes.

Implements RFCs 9000 (QUIC v1), 9001 (QUIC-TLS), 9002 (loss detection/congestion control, NewReno), 9221 (DATAGRAM frames), 9368 (compatible version negotiation), and 9369 (QUIC v2). Cryptographic operations use Windows BCrypt (AES-128-GCM, HKDF-SHA256) and SChannel (TLS 1.3) — platform-native, FIPS-validated primitives.

Minimum OS requirement: Windows 10 version 1903+ (SChannel TLS 1.3 support).

| Module | Source | Description |
|--------|--------|-------------|
| `transport` | `src/transport/root.zig` | Coarse-grained re-export of all transport sub-modules |
| `udp` | `src/transport/udp.zig` | Win32 UDP socket I/O (non-blocking send/receive via Winsock2) |
| `packet` | `src/transport/packet.zig` | QUIC packet parsing and serialization (RFC 9000 §17, §19) |
| `transport_crypto` | `src/transport/crypto.zig` | TLS 1.3 integration and packet protection (RFC 9001, BCrypt/SChannel) |
| `recovery` | `src/transport/recovery.zig` | Loss detection and congestion control (RFC 9002, NewReno) |
| `streams` | `src/transport/streams.zig` | Stream management with flow control (RFC 9000 §2) |
| `datagram` | `src/transport/datagram.zig` | DATAGRAM frame handling (RFC 9221) |
| `scheduler` | `src/transport/scheduler.zig` | Packet assembly and pacing |
| `conn` | `src/transport/conn.zig` | Connection state machine (RFC 9000 §10) |
| `telemetry` | `src/transport/telemetry.zig` | Per-connection counters and diagnostics |
| `appmap` | `src/transport/appmap.zig` | Application protocol mapping (zpm-specific, maps registry ops to QUIC lanes) |

System libraries linked transitively: `ws2_32`, `bcrypt`, `secur32`, `kernel32`

#### Lane Architecture

Three application lanes map to QUIC primitives:

| Lane | QUIC Primitive | Semantics | Use Cases |
|------|---------------|-----------|-----------|
| Control | Bidirectional stream 0 | Reliable, ordered | Handshake, auth, resolve, publish, search, close |
| Bulk | Bidirectional streams 4+ | Reliable, ordered, parallel | Tarball download, snapshot transfer |
| Hot | DATAGRAM frames (RFC 9221) | Unreliable, latest-wins | Invalidation, version announcements, telemetry |

Stream ID allocation: stream 0 for Control, streams 4/8/12/… for Bulk (client-initiated bidirectional, one per transfer), DATAGRAM frames for Hot (no stream ID).

### Layer 2: Render

Drawing primitives and text rendering. May import from platform and core.

| Module | Source | Description |
|--------|--------|-------------|
| `render` | `src/render/root.zig` | Coarse-grained re-export of all render subsystems |
| `color` | `src/render/color.zig` | Color types and constants |
| `primitives` | `src/render/primitives.zig` | GL immediate-mode drawing: rect, line, candle, glow |
| `text` | `src/render/text.zig` | Bitmap font rasterization (Win32 GDI → GL texture atlas) |
| `icon` | `src/render/icon.zig` | ICO file loading → GL texture |

## Usage

The app depends on `zpm` as a path dependency. Modules are imported by name:

```zig
// Granular imports (preferred)
const math = @import("math");
const gl = @import("gl");
const primitives = @import("primitives");

// Coarse-grained imports
const core = @import("core");
const platform = @import("platform");
const transport = @import("transport");
const render = @import("render");
```

### QUIC Transport Example

```zig
const conn = @import("conn");
const appmap = @import("appmap");

// Create a QUIC connection (client-initiated)
var connection = conn.Connection.initClient(server_addr);

// Drive the connection — call tick() in your event loop
// tick() processes incoming packets, drives the TLS handshake,
// runs loss detection, and assembles outgoing packets
const result = connection.tick(recv_buf[0..bytes_read], &send_buf);

// Use the application protocol mapping for registry operations
// appmap translates resolve/publish/search into lane-appropriate messages:
//   Control lane (stream 0)  — resolve, publish, search, auth
//   Bulk lane (streams 4+)   — tarball download, snapshots
//   Hot lane (DATAGRAM)      — invalidation, version announcements
var app = appmap.AppMap.init(&connection);
app.sendResolveRequest(scope, name, version);
```

```
zig build run
```

---

<p align="center">
  Every byte accounted for. Every cycle earned.
</p>

<p align="center">
  <a href="https://discord.gg/tXwz7dAt">Discord</a> · <a href="https://ko-fi.com/shadovvbeast">Ko-fi</a>
</p>
