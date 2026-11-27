# Durable history and long-outage recovery

This layer persists bounded signed history, state and cursors for independent
single-writer streams. It is infrastructure for replication; game rules and
Solana settlement are separate consumers and authority layers.

## Components

- `mesh-history` (Layer 0) provides signed event chains, writer-signed snapshots,
  bounded retention, canonical journal images and a generic durable transaction
  wrapper. The application supplies a fixed-width canonical state reducer.
- `mesh-sync` (Layer 0) exchanges cursor requests, retained events, snapshots and
  explicit unavailable-history hints over an authenticated message channel.
- `mesh-file` and `fixed-journal` (Layer 1) implement bounded atomic file
  replacement with file flushes and, on Linux, parent-directory synchronization.

All participant/runtime code is Sig and allocator-free. The host supplies
long-lived storage and initializes it in place. Node and PowerShell only prepare
fixtures, control test processes and independently verify public test records.

## Stream contract

Each configured writer owns one stream, starting at cursor zero and the reducer's
declared initial state. Every event signs its realm, writer, sequence, previous
event hash and payload. A receiver accepts exactly the next sequence with the
expected predecessor. Duplicates and old events do not reapply state. Conflicting
heads fail closed. Transport incarnations and gossip sequence numbers remain
separate from these persistent stream cursors.

A local writer signs a current checkpoint after each committed increment. A
checkpoint identifies its stream cursor, event-chain head and canonical state.
A remote replica verifies that writer's signature and validates the snapshot
through the application reducer before using it for an explicit resynchronization.
It cannot use one writer's snapshot to change another writer's stream. The
configured writer roster is fixed for a journal; roster changes need migration.

**Snapshot trust is explicit:** a valid signature authenticates the writer's
assertion about its own state. It does not prove execution of omitted history,
resolve writer equivocation, provide consensus or establish Solana finality.
Applications requiring those properties must validate them separately.

Retention is bounded, not an indefinite audit archive. Receivers retain a signed
anchor plus the events needed to derive their current state. If accepting another
event would discard a required proof, they report `SnapshotRequired` instead of
silently losing it. An owner checkpoint permits safe compaction. A behind peer
gets the exact next retained event when available, otherwise an applicable signed
snapshot and subsequent events. At least one source must retain the needed proof.

## Durable transaction and recovery

An update is validated and applied to caller-owned staging storage. One canonical
image includes all stream cursors, heads, signed anchors and retained events.
The backend writes a temporary file, flushes it and atomically replaces the target.
Only after that succeeds does the in-memory live state advance. State and cursor
therefore share the same durability boundary.

Any save error is ambiguous: replacement might already have completed. The store
becomes poisoned and rejects further updates until it reloads the target. A
restart reconstructs state from signed anchors and events, checks each chain and
requires the reconstructed cursor/head to match the persisted metadata. Repeating
a previously committed signed event cannot increment the state again.

A missing journal is an error by default. Fresh creation requires explicit host
authorization. Corruption also fails closed; a valid `.tmp` alongside a damaged
target is not promoted automatically. Files are preserved for investigation.
This covers the reducer's stored state, not external side effects such as sending
payments or invoking callbacks. Those require a separate transactional outbox or
equivalent settlement protocol.

The backend assumes one process/thread owns each journal path and that its parent
directory is trusted. The host owns filesystem permissions, identity storage and
an increasing transport incarnation. Checksums detect damaged images; they do not
provide hardware-backed rollback protection. Replacing an entire journal with an
older valid image requires an external monotonic anchor to detect reliably.

## Wire and storage formats

Historical `ZMH1` frames deliberately have no gossip lease or wall-clock expiry:

| Bytes | Field |
| --- | --- |
| 0–4 | `ZMH1`, version 1 |
| 5–7 | Event/snapshot kind and two zero reserved bytes |
| 8–39 | Realm |
| 40–71 | Authorized writer public key |
| 72–79 | Persistent cursor, LE u64 |
| 80–111 | Previous event hash; snapshot kind uses current chain head |
| 112–113 | Payload length, LE u16 |
| 114–119 | Zero reserved bytes |
| 120 onward | Event payload or fixed canonical snapshot state |
| Final 64 | Writer Ed25519 signature |

Payload/state capacity is 224 bytes, making the largest historical frame 408
bytes. Sync replies wrap it in an 88-byte `ZMS1` prefix for a maximum of 496
bytes, fitting the existing 512-byte opaque gossip payload. Requests and
unavailable hints are 128 bytes. Replies bind recipient, writer, requesting
process incarnation and nonce. Old, unrelated or non-progress replies are
rejected. Unavailable hints and gap replies cannot cancel another peer's valid
outstanding answer. Larger snapshots need a future chunked-stream protocol.

`ZMD1` journal images contain an 88-byte header (realm, storage-owner identity,
commit generation, writer count), followed by each writer's cursor/head,
length-delimited signed anchor and retained events, then a SHA-256 checksum.
State is reconstructed rather than trusted as an unsigned cached field. The
four-writer/four-event fixture has an 8,616-byte maximum image. Capacities are
compile-time parameters; there is no implicit disk or memory growth.

## Validation and reproduction

```powershell
sig build test-mesh-history -j1
sig build run-contract-mesh-network test-udp test-conn test-quic-loopback test-no-alloc test-layer test-domain-agnostic -j1
sig test src/pkg/official_packages.sig

./tools/build-mesh-lab.ps1 -Source src/mesh_history_lab.sig -Output sig-out/bin/mesh-history-lab.exe
./tools/run-mesh-history.ps1 -Session fresh-history-session -OutageSeconds 40

./tools/build-mesh-lab.ps1 -Source tests/mesh_file_crash.sig -Output sig-out/bin/mesh-file-crash.exe
./tools/test-mesh-file-crashes.ps1 -Session fresh-crash-session
```

The four-process lab starts at four increments per writer, kills the bootstrap
participant and advances the survivors to twelve. It keeps the bootstrap down
for 40 seconds, exceeding the gossip's 30-second lease, with only four events
retained per stream. The restarted process must load its existing cursor and
recover the missing state through signed snapshots. It then resumes writing;
all four replicas must reach twelve without duplicated increments. A second
restart checks that the committed state is immediately recoverable from disk.

The independent Node verifier validates every file checksum, realm/owner binding,
retained event and checkpoint signature. It regenerates the complete synthetic
event chains from public fixture seeds and checks every final head, cursor and
state against those independently generated bytes. Reading matching log lines
alone is insufficient; persisted files must pass as well.

October 15, 2026: `sig-out/mesh-history/history-oct15-d/` passed all four stages,
including peer authentication after the second restart. The earlier successful
`history-oct15-c` run is retained too.
The final canonical hash was
`eaaf837eb901ce96feaefc9d9de3aeac488528472597a03f5ec68eae28261f6b`.
Baseline, outage, convergence and second-restart reports retain the independent
checks. The first harness attempts are retained too: they exposed an empty-log
readiness race, which the persisted-file verifier caught and the harness fixed.

`file-crash-oct15-b` separately terminated real processes immediately before and
after durable replacement. Recovery returned cursor/state 1 before replacement
and 2 afterward. A corrupted target was rejected and preserved even with a valid
uncommitted temporary image beside it. These are process-crash tests, not physical
power-cut or storage-hardware guarantees.

The focused contracts cover malformed signed frames, every damaged image byte
and truncated image prefix, fabricated cursor metadata, wrong writers, replay,
chain conflicts, disk-save ambiguity and unsolicited replies. A further 128
seeded channel schedules inject loss, duplication, reordering, a 70-second
simulated outage, restart and failures on either side of the commit boundary.
Allocation/layer checks include the new modules.

October 18, 2026: the ARM64 runtime passed on the connected Samsung SM-S948B
(Android 17), using four separate native processes on that device. Session
`sig-out/mesh-history/android-history-oct18-b/` records baseline convergence,
40-second bootstrap outage, signed snapshot recovery and a second restart with
peer authentication. Independently verified persisted journals reached the same
final hash recorded above, with all four writer cursors and counters at twelve.
The tested binary SHA-256 is
`d17af77acd573584c2a40ae0d904c40f8462dbf4747b1620bcc29567a372d873`.
The launcher attempt `android-history-oct18-a` is preserved; its ADB shell
detachment issue was corrected before the successful run.

Reproduce on an ARM64 Android phone or compatible emulator:

```powershell
./tools/build-mesh-lab.ps1 -Source src/mesh_history_lab.sig -Output sig-out/bin/mesh-history-mobile-arm64 -Target aarch64-linux-musl
./tools/run-mesh-history-android.ps1 -Serial YOUR_ADB_SERIAL -Session fresh-android-history
```

The harness uses its own `/data/local/tmp/` directory and preserves journals and
logs. It stops only its recorded processes after checking their working directory.
It does not access the app wallet. This establishes native Android file/QUIC
recovery on one device; cross-device networking, app lifecycle and Solana
settlement remain separate gates. A sampled peer reported 3,496 kB resident
memory and 35,204 kB peak virtual memory; this sample is not a sustained-load
memory bound and does not replace configurable stream-buffer budgets.

## Next infrastructure work

The configurable mobile stream budget and Windows/Android recovery now pass;
see [mobile transport budgets](mesh-memory.md). Add admission/roster migration.
Larger records need bounded chunk assembly
with resumable transfer. Full archival history, protected rollback detection,
transaction outboxes, checkpoint settlement and reconciliation with Solana's
finalized state remain independent infrastructure milestones.
