# zpm/src/net/ — Networking Stack (Layer 0)

Zero-allocation, freestanding-compatible network protocol modules. Designed for bare-metal kernel use (GVE NIC on GCP) and general networking.

## Architecture

```
Application (QUIC server, HTTP client, metadata reporting)
    ├── http.sig        ← HTTP/1.1 client (GET/PUT, chunked, GCP metadata)
    ├── dns.sig         ← DNS resolver (A records, 8-entry cache, anti-spoofing)
    ├── dhcp.sig        ← DHCP client (DISCOVER→ACK, T1 renew / T2 rebind)
    ├── tcp.sig         ← TCP (RFC 9293/5681/6298/7323, 32 connections)
    ├── udp.sig         ← UDP (port binding, checksum, dispatch)
    ├── icmp.sig        ← ICMP (echo reply, dest unreachable)
    ├── ipv4.sig        ← IPv4 (build/parse, routing, checksums)
    ├── arp.sig         ← ARP (table, resolve, gratuitous)
    ├── ethernet.sig    ← Ethernet II (frame build/parse, MAC utils)
    ├── interface.sig   ← NIC abstraction (function pointer struct)
    └── checksum.sig    ← RFC 1071 Internet checksum
```

## TCP Features
- All RFC 9293 states; active open (connect) and passive open (listen/accept)
- RST/SYN validation with challenge ACKs (RFC 5961)
- MSS, window scale (shift up to 14) and SACK-permitted options
- Send/receive ring buffers (32 KiB / 512 KiB per connection); the advertised
  window is the free space, so its right edge never shrinks
- RTO per RFC 6298 (Karn, exponential backoff, 200 ms floor), go-back-N
- NewReno congestion control (RFC 5681/6582): fast retransmit, fast recovery
- Out-of-order reassembly (one range) reported with a SACK block
- Delayed ACK (40 ms / every 2nd segment), Nagle (configurable)
- Window updates on read, zero-window probing
- Graceful close (FIN after queued data), short client TIME_WAIT
- RFC 6528-style ISNs and randomized ephemeral ports from a caller seed (`seed`)
- Time comes from the caller: `tick(now_us, ...)`

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
sig build test-net-checksum test-net-ethernet test-net-ipv4 test-net-udp test-net-tcp test-net-dns test-net-dhcp
```

## Design Principles

1. **Zero allocation** — static tables, caller-provided buffers
2. **Freestanding** — no OS, compiles for bare-metal
3. **Self-contained** — relative file imports, no transitive dependency issues
4. **Inline tests** — each module proves its own correctness
5. **RFC compliant** — checksums verified, state machines complete
