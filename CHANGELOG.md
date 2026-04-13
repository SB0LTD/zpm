# Changelog

## 0.1.0 — 2025-06-20

Initial release — zpm transforms from a Windows-only Zig module library into a cross-platform package manager for the Zig ecosystem.

### Added

- **Package manager CLI** with 11 commands: init, install, uninstall, list, search, publish, validate, update, doctor, run, build
- **Cross-platform support** — Windows, macOS, and Linux via Platform Abstraction Layer (PAL) with comptime OS dispatch
- **Scoped package naming** — `@zpm/<package>` for official packages, `@<scope>/<name>` for third-party
- **Dependency resolver** — BFS traversal with deduplication, layer validation, and cycle detection
- **build.zig.zon manipulation** — zero-allocation ZON parser/writer for adding and removing dependencies
- **Package manifest format** — `zpm.pkg.zon` with protocol version, layer, platform, system libraries, and constraints
- **Layer validation** — enforces Layer 0 → 1 → 2 ordering in dependency graphs
- **Project scaffolding** — 9 templates: empty, cli-app, web-server, gui-app, library, package, window, gl-app, trading
- **Registry client** — HTTP-based with optional QUIC transport (`--transport quic`)
- **QUIC transport stack** — full RFC 9000/9001/9002/9221 implementation with Control, Bulk, and Hot lanes
- **Zig bootstrapper** — auto-detects and downloads Zig 0.16+ if not available
- **34 official @zpm/ packages** — existing modules (core, math, json, win32, gl, window, transport, render, etc.) as installable packages
- **Edit distance suggestions** — typo correction for unknown commands and flags
- **Offline mode** — `--offline` flag for air-gapped environments

### Architecture

- Layer 0 (Core): core, math, json — pure logic, no platform dependencies
- Layer 1 (Platform): win32, gl, window, timer, http, crypto, file-io, threading, logging, input, png, screenshot, mcp, seqlock
- Layer 1 (Transport): udp, packet, transport-crypto, recovery, streams, datagram, telemetry, scheduler, conn, appmap
- Layer 2 (Render): color, primitives, text, icon

### Targets

- Zig 0.16+ (officially supported)
- x86_64-windows, x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos
