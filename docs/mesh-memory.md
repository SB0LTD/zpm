# Mobile transport budgets

October 18, 2026: stream storage is caller-owned and configurable in Sig.
`streams.Storage(budget)` owns stream descriptors and the send/receive arrays.
Initialization binds slices into those arrays in place; storage must stay at a
stable address for the lifetime of its manager or connection. Reinitializing
resets counters and rings without allocating or retaining old data as readable.

`streams.StreamArray` names the default storage profile: 64 tracked slots, each
with 65,536 bytes per direction. It is now a storage struct; direct users of the
old array representation must access `.items`. Existing callers that only pass
its address to connection/manager initialization keep that calling pattern.
`streams.mobile_budget` selects four tracked slots, each with 16,384 bytes per
direction. A ring reserves one byte to distinguish empty from full. Full writes
are short writes; an exhausted stream table rejects new streams without growth.
Closed stream IDs remain tracked until connection reinitialization; this change
does not add safe stream retirement or an unlimited sequence of checkpoints.

The default `Network(members, links, history)` retains the default storage
profile. Mobile hosts opt in explicitly:

```zig
const Net = network.NetworkWithBudget(16, 4, 32, streams.mobile_budget);
var storage: Net.Storage = undefined;
```

The same four-link history harness reports these compile-time reservations on
Windows and ARM64. They include the network object and its caller-owned storage,
not the complete process, history journal or OS socket buffers:

| Profile | Streams per link | Bytes per direction per stream | Network + storage bytes |
| --- | ---: | ---: | ---: |
| Default | 64 | 65,536 | 34,359,192 |
| Mobile | 4 | 16,384 | 1,294,488 |

That is a 96.2% reduction in this reservation. It is not a peak RSS or bandwidth
guarantee. Connection count, datagram queues, membership, gossip history and disk
images remain separately bounded by their existing capacities. Work budgets per
tick are not hard network-rate limits. MineGrind's live-session and checkpoint
adapters also select the mobile profile in source; the installed APK was not
replaced by this infrastructure test.

Connection transport parameters advertise backed receive windows and split the
tracked slots between bidirectional and unidirectional limits. Fresh outgoing
streams honor the peer's advertised initial window for their direction and
initiator. TLS now preserves client transport parameters through authenticated
handshake completion on the server, as it already did for server parameters on
the client. Mixed-profile tests transfer a 10,016-byte checkpoint in both
directions through real QUIC sockets and check the negotiated mobile limit.
This does not implement larger, resumable snapshot transfers or a general QUIC
conformance claim.

## Cross-device evidence

`sig-out/mesh-history/mobile-cross-oct18-f/` contains the successful final run:
two native Windows peers and two native ARM64 peers on the Samsung SM-S948B,
connected through the private IPv4 network provided by USB tethering. The harness
force-killed Windows peer zero for 40 seconds while the three survivors advanced
their counters from four to twelve. After restart it recovered signed snapshots,
then resumed its own writes. A second restart killed Android peer two, required
its persisted cursor twelve and authenticated a peer again.

At every phase, the independent Node verifier checked all four journal files,
including signatures, complete regenerated event-chain heads, state and cursors.
All replicas finished at twelve with canonical hash
`eaaf837eb901ce96feaefc9d9de3aeac488528472597a03f5ec68eae28261f6b`.
The ARM64 binary SHA-256 was
`b8ab1f56e56aa07a72166bd24ba65ff4e4142cdbbec7b87388f2dc054d3b7210`.
The run exercises headless infrastructure, not Android app background/resume,
public-network reachability or Solana settlement. App wallet data was untouched.

The first attempts are preserved. They exposed a disconnected Windows Wi-Fi
address and a real clock-skew bug: the original upper lease check rejected
freshly signed frames from a phone about 200 ms ahead. Senders still create
30-second leases. Receivers now allow at most five seconds of sender clock lead,
so no accepted frame expires more than 35 seconds into the receiver's future.
The expiry deadline remains strict, with no stale-packet grace. Signatures,
incarnation checks and replay windows remain required. Focused contracts cover
the exact lead boundary, rejection beyond it, and rejection at expiry.

## Reproduction

Use addresses belonging to connected interfaces; a deprecated address from a
disconnected adapter is insufficient. Both devices must permit the test UDP
traffic. The harness does not alter firewall rules or network settings.

```powershell
./tools/build-mesh-lab.ps1 -Source src/mesh_history_lab.sig -Output sig-out/bin/mesh-history-mobile.exe
./tools/build-mesh-lab.ps1 -Source src/mesh_history_lab.sig -Output sig-out/bin/mesh-history-mobile-arm64 -Target aarch64-linux-musl
./tools/run-mesh-history-android.ps1 -Serial YOUR_SERIAL -Session fresh-cross-device -WindowsAddress HOST_PRIVATE_IPV4 -AndroidAddress PHONE_PRIVATE_IPV4

sig build test-streams test-conn test-quic-loopback test-tls13 test-scheduler test-appmap test-h3-server test-shared-source test-no-alloc test-layer test-domain-agnostic -j1
sig build run-contract-mesh-overlay run-contract-mesh-faults test-mesh-history -j1
```

Without the two address arguments, the same harness starts all four peers on the
Android device over loopback. Journals, logs and failed attempts are preserved.
The harness stops only processes it started; Android cleanup verifies their
working directories before killing them.

Next priorities are resumable chunked snapshots, admission and roster migration,
then Android app lifecycle and sustained-load measurements. Durable settlement
outboxes and finalized-ledger reconciliation remain separate infrastructure.
