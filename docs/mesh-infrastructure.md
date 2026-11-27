# Multi-peer infrastructure

This is reusable networking infrastructure, with synthetic record tests. It adds
no game content, world rules, consensus, ad integration or Solana settlement.

## Modules

`mesh-overlay` (`src/core/mesh_overlay.sig`, Layer 0) defines signed frames,
membership leases, a 64-sequence replay window per identity/incarnation, bounded
candidate retry budgets, an event queue and a bounded retransmission cache.
Payloads are opaque. The only dependency is Sig's standard crypto/computation
library. There are no OS calls, allocators, threads or implicit storage growth.

`mesh-network` (`src/transport/mesh_network.sig`, Layer 1) discovers candidates
through signed UDP advertisements and membership exchange over authenticated
QUIC links. It maintains several concurrent `mesh_transport.Mesh` sessions,
pins each discovered public identity and requires its channel-bound Ed25519
proof before application delivery. A signed advertisement is a candidate, not
evidence of a live session. Advertisements do not authorize ledger mutations.

The caller provides `Network(Members, Links, History).Storage` as static or other
long-lived storage. Each connection currently retains the transport's large
fixed stream backing. The three-node test uses **17,181,336 bytes per node** for
two links; the four-process lab uses **34,348,760 bytes per node** for four slots.
These are bounded footprints, not demonstrated mobile memory targets. Making
stream backing configurable is an explicit next infrastructure task.

`UdpSocket.borrow` provides send access to one shared listener while receiving
only from a caller-owned four-datagram inbox. The owner demultiplexes packets
by source endpoint. A borrower cannot consume another connection's packets or
close the listener. Existing standalone sockets retain their ownership behavior.
The smaller public identity initiates each pair's connection, avoiding duplicate
sessions. Source-address migration is not supported.

## Wire format and validation

All overlay messages use the same signed `ZMO1` v1 envelope:

| Bytes | Field |
| --- | --- |
| 0–4 | Magic `ZMO1`, version 1 |
| 5 | Kind: membership card, application data, or dial |
| 6–7 | Zero reserved bytes |
| 8–39 | Realm identifier |
| 40–71 | Origin Ed25519 public key |
| 72–79 | Durable process incarnation, LE u64 |
| 80–87 | Sender sequence, LE u64 |
| 88–95 | Expiration time in caller clock milliseconds, LE u64 |
| 96–97 | Payload length, LE u16 |
| 98–103 | Zero reserved bytes |
| 104 onward | Opaque payload, maximum 512 bytes |
| Final 64 | Ed25519 signature over all preceding bytes |

Membership/dial payloads contain IPv4 octets, an LE port and two zero reserved
bytes. Cards are 176 bytes; maximum application frames are 680 bytes. Realm,
canonical layout, expiry, address scope, signatures, incarnation and replay
windows are checked before accepting new application data. Known duplicate
headers can be discarded cheaply without verification; that path never applies,
forwards or advances state. Exact previously verified card bytes can be reused
without redoing crypto, but cannot renew their lease or reset retry budgets.

An application delivery queue that is full rejects the frame before advancing
its replay watermark, allowing a later retransmission. A rotating bounded cache
repeats valid signed frames, preserving the original signature. Forwarding does
not imply application acceptance, finality or durable delivery.

## Bounds and host responsibilities

- Member capacity is 2–64; link, event and history capacities are fixed at build
  time. New identities are rejected when the table is full. Replay watermarks
  are not evicted merely because a lease expires.
- Membership leases last at most 30 seconds. Hosts must use comparable clocks
  across machines, normally UTC milliseconds, and provide a policy for clock
  correction. Clock rollback is rejected. Same-host tests may use one monotonic
  clock; that clock is not suitable for communication across different machines.
- The host must persist an increasing incarnation **before** each restart and
  retain its identity securely. The lab uses public deterministic test keys and
  flushed incarnation files. Those identities are unsuitable for real users.
- Discovery sends at most five initial seed probes; failure is exposed after the
  30-second window. Per-peer attempts are bounded too. `retryDiscovery` explicitly
  resets the budget. Incoming authenticated sessions can still recover a listener.
- One tick drains at most 16 listener datagrams, considers one outbound candidate
  and queues at most three repair frames per link. The nominal repair interval
  is 100 ms; publications can bring that scan forward. New signed data is also
  queued immediately and forwarded after validation. Socket queues and QUIC
  frames have their own bounds. These are bounded-work and queue limits,
  not measured protection against hostile traffic or a congestion-control proof.
- Default scope is loopback. Explicit LAN mode admits RFC1918 IPv4 addresses.
  Public destinations and advertised public endpoints are rejected. LAN/public
  Internet, NAT traversal and adversarial membership are separate validation gates.
- Self-certifying discovery proves identity possession, not entitlement or
  Sybil resistance. Production admission policy and table turnover are open work.

## Tests and reproduction

```powershell
sig build test-mesh -j1
sig build test-udp test-conn test-quic-loopback test-no-alloc test-layer test-domain-agnostic -j1
sig test src/pkg/official_packages.sig
./tools/build-mesh-lab.ps1
./tools/run-mesh-lab.ps1 -Session example-session -BasePort 47200 -Victim 0
```

`test-mesh` includes three runnable contract suites; success requires actual
assertions, not discovery of an empty test set:

1. Overlay contracts: tampering and truncation, wrong realm/scope/expiry,
   unauthenticated ingress, capacity, out-of-order delivery, replay, incarnation
   changes, queue pressure and retry exhaustion.
2. Fault simulation: 128 deterministic schedules, eight nodes connected in a
   ring, 25% scheduled random loss, injected duplicates, reordered/delayed packets,
   a partition and a volatile-node restart. Synthetic monotone registers must
   converge. The scheduler also drops packets at crashed/partitioned endpoints
   and when its fixed queue is full, so total discarded traffic exceeds 25%.
   Transport and time are simulated; signed frames and the overlay code are real.
3. Real network contracts: three instances with two concurrent authenticated
   QUIC links each, discovery from one seed, actual socket delivery, a stopped
   incarnation, reconnect and recovery of a cached record. No fake TLS keys or
   forced authenticated states are used.

The lab launches **four independent Sig processes**, waits for initial records,
kills the configured participant, and leaves the others running for seven
seconds. Survivors must exchange newer records while that participant is down.
It restarts the same identity with a durably increased incarnation and checks
all four final hashes against an independently computed canonical SHA-256 hash.
`-Victim 0` stops the bootstrap participant, showing it is not a state authority.
Only processes started by the harness are stopped. Logs and reports are retained
under `sig-out/mesh-lab/SESSION/`; subsequent runs should use a fresh session.

October 15, 2026: session `infra-oct15-b` passed with the bootstrap participant
force-killed, all survivors advancing, and all four replicas finally matching
`00dbc162fced7f4dd630fee0deab289123d06d1c1ec3087b476a7653f7bd7924`.
The fault suite passed 28,800 assertions and overlay contracts 373 assertions;
real-network contracts passed 16. Package dependency/layer tests and focused
socket, authentication, no-allocation and domain-boundary checks passed.

The ARM64 Linux/Android network-contract binary compiled successfully. On
October 18 the durable-history harness also passed with four native peers on a
physical Android phone; see [the recovery evidence](mesh-history.md). The earlier
Android game remains unchanged. These single-device loopback tests do not
establish cross-device or public-network behavior for the new multi-peer service.

## Next infrastructure gates

The cache is finite and expires after 30 seconds. The separate
[durable-history layer](mesh-history.md) now provides signed snapshots, persistent
stream cursors and explicit gap recovery beyond that lease. The original gossip
API remains volatile. Durable state changes require the new journal/sync API;
its snapshots authenticate individual writers and carry no Solana finality claim.

The [mobile stream-memory profile and cross-device recovery](mesh-memory.md)
now pass on Windows and Android. Next: topology repair when peer slots
fill, authorized membership turnover, per-peer abuse limits, cross-device fault
testing and measurements at higher population. Transaction scheduling, batching
and ledger reconciliation remain separate layers with their own authority tests.
