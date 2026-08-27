# zpm/src/net/ — Networking Stack (Layer 0)

Zero-allocation, freestanding-compatible network protocol modules. Designed for bare-metal kernel use (GVE NIC on GCP) and general networking.

## Architecture

```
Application (QUIC server, HTTP client, metadata reporting)
    ├── http.sig        ← HTTP/1.1 client (GET/PUT, chunked, GCP metadata)
    ├── dns.sig         ← DNS resolver (A records, 8-entry cache)
    ├── dhcp.sig        ← DHCP client (DISCOVER→ACK, lease renewal)
    ├── tcp.sig         ← Full TCP (RFC 793/7323/5681, 16 connections)
    ├── udp.sig         ← UDP (port binding, checksum, dispatch)
    ├── icmp.sig        ← ICMP (echo reply, dest unreachable)
    ├── ipv4.sig        ← IPv4 (build/parse, routing, checksums)
    ├── arp.sig         ← ARP (table, resolve, gratuitous)
    ├── ethernet.sig    ← Ethernet II (frame build/parse, MAC utils)
    ├── interface.sig   ← NIC abstraction (function pointer struct)
    └── checksum.sig    ← RFC 1071 Internet checksum
```

## TCP Features (Full RFC Compliance)
- All 11 states (CLOSED through TIME_WAIT)
- Active open (connect) and passive open (listen/accept)
- SACK (4 blocks, RFC 2018)
- Window scaling (RFC 7323, shift up to 14)
- TCP timestamps / RTTM (RFC 7323)
- Nagle algorithm (configurable)
- NewReno congestion control (RFC 5681)
- RTO per RFC 6298 with exponential backoff
- Delayed ACK (200ms / 2 segments)
- Zero-window probing
- 32-bit sequence wraparound arithmetic

## Usage in Kernel

```sig
// In net_stack.sig (kernel integration module):
const tcp = @import("tcp.sig");
const udp = @import("udp.sig");
const arp = @import("arp.sig");

// Connect to metadata server
const handle = tcp.connect(our_ip, metadata_ip, 80) orelse return;
_ = tcp.send(handle, http_request);
```

## Usage Standalone

All modules use `@import("file.sig")` relative imports — no build system wiring needed. Just compile:

```
sig build-obj src/net/tcp.sig -target aarch64-freestanding
```

## Testing

Each module has inline `test` blocks. Run via build steps:

```
sig build test-net-checksum test-net-ethernet test-net-ipv4 test-net-udp test-net-tcp --zig-lib-dir <lib>
```

## Design Principles

1. **Zero allocation** — static tables, caller-provided buffers
2. **Freestanding** — no OS, compiles for bare-metal
3. **Self-contained** — relative file imports, no transitive dependency issues
4. **Inline tests** — each module proves its own correctness
5. **RFC compliant** — checksums verified, state machines complete
