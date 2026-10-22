# Bounded database server building blocks

These packages implement the reusable parts of RAMSQL. The product repository
owns the listeners, capacity profile and reactor policy.

- `sql` (Layer 0): owned schemas/rows, fixed primary-key hash index, typed SQL.
- `db_store` (Layer 0): a generic `Store(RawDatabase)` and per-connection adapter.
- `postgres`, `mysql`, `tds` (Layer 1): pure, socket-independent wire sessions.
- `scram`, `durable_log` (Layer 0): authentication state and portable committed WAL frames.
- `db_file`, `entropy` (Layer 1): native durable files and cryptographic entropy.
- `tcp_server` (Layer 1): nonblocking Winsock/Linux syscall socket primitives.

All storage is fixed or caller-owned, and runtime code is Sig. Wire codecs
have no allocator or socket dependencies. Native platform bindings belong only
to platform primitives. Lower layers do not import RAMSQL.

## Session API and framing

Each codec exposes `Session(DB)`, where DB provides `Result` and `execute`.
The shared-store connection additionally supplies transaction/status methods.
Call `session.handle(&connection, input, output)` with the bytes available; the
reply reports `consumed`, `written`, and `close`. A zero consumed count means
an incomplete frame. Retain unconsumed input, send all output using partial-write
tracking, and call again only after output drains. MySQL `begin(output)` emits
the initial greeting; TDS `begin` returns zero; PostgreSQL waits for startup.

`Session.responseCapacity()` is the conservative output capacity required
before accepting a request. Too-small output is rejected before executing a
mutation. PostgreSQL bounds packets at 16 KiB, SQL at 4 KiB, parameters at 32,
and statements/portals at eight each. MySQL/TDS request storage is bounded at
64 KiB. Oversized/malformed input fails explicitly. A PostgreSQL session keeps
one materialized suspended result at a time; conflicting portal execution is
rejected rather than overwriting it.

PostgreSQL supports simple and extended queries, named statement lifecycle,
typed text/binary parameters and rows, SQLSTATE errors and synchronization.
MySQL supports protocol 10, COM_QUERY, PING, INIT_DB and text results; COM_STMT
binary preparation is not implemented. TDS 7.2–7.4 supports PRELOGIN/LOGIN7,
SQL_BATCH, typed nullable values, packet fragmentation, transaction-manager
messages and bounded `sp_executesql` RPC with integer/boolean/NVARCHAR/NULL
parameters. RPC substitution validates the entire request first and respects
quoted strings, identifiers and comments. Other RPC and unsupported data types
return errors.

These are bounded compatibility subsets, not complete SQL dialect or catalog
implementations. PostgreSQL optionally enforces SCRAM-SHA-256: import `scram`,
construct/import a Verifier, and call configureAuthentication with a fresh native
CSPRNG nonce before startup. Default sessions retain trust for explicit test
callers. MySQL/TDS still require an external trusted-interface policy. TLS and
SCRAM channel binding are not implemented.

## Transactions and durability

`Store(Raw)` owns committed state and a generation. Each connection needs a
unique nonzero id and a distinct caller-owned `transaction_workspace`. BEGIN
copies committed state into this workspace. Changes remain private; writing
commits fail with SerializationFailure if another commit changed the generation.
Read-only commits do not conflict. Disconnect discards private state. This
conservative optimistic isolation differs from PostgreSQL READ COMMITTED.

Durable callers supply `autocommit_workspace`, `commit_ctx`, `commit_fn`, and
set `durability_required`. Each connection also supplies a bounded
`transaction_log`. Commit batches use repeated little-endian u32 length + SQL
bytes; `BatchIterator` validates them without splitting literals or comments.
The synchronous hook must persist a complete batch before returning. The store
publishes only after hook success. Hook failure poisons subsequent writes.
Read-only statements do not copy the database; durable writes prepare a candidate.

`durable_log.append` writes a versioned checksummed header, payload and commit
trailer, then syncs. `recover` checks complete records, contiguous sequences and
checksums before replay. Only an incomplete physical tail is truncated; complete
corruption and semantic replay failures abort recovery. Callers must replay each
batch atomically. `db_file.File` holds an exclusive writer lock on Windows/Linux,
provides complete append/fsync/truncate, and poisons failed writers. Atomic file
publication helpers are for caller-validated backups/snapshots; never replace
an active WAL inode or truncate it without a persisted sequence anchor.

Runtime wiring and storage lifecycle remain product policy in RAMSQL. WAL v1
replays SQL, so upgrades must preserve parser/type semantics or migrate formats.
Capacity must cover every historical state, including rows later deleted.

## TCP API

Pair `init()` / `deinit()`. `listen([4]u8, port)` returns a nonblocking IPv4
listener. `localPort` reports ephemeral port assignments. `accept`, `recv` and
`send` return null on would-block; recv zero means EOF. Send may be partial.
Accepted sockets enable TCP_NODELAY. `waitMasked` uses caller read/write
interest arrays and overwrites them with readiness; `wait` retains the simpler
all-readable-sockets API. The bound is 63 client descriptors plus a listener.
The Linux implementation uses direct syscalls; Windows uses native Winsock.

## Contracts

Run `sig build test-db test-sql -Doptimize=ReleaseSafe --summary all`.
Executable tests cover protocol framing/lengths, error recovery, parameter types,
Unicode/surrogates, output preflight, transactions, malformed/fuzzed input and
real TCP backpressure. Randomized index tests compare against an independent
flat model while forcing integer/text keys into the same hash bucket, changing
keys, compacting deletes, reusing slots, and copying/restoring snapshots.

RAMSQL separately tests raw live TCP behavior and psycopg, PyMySQL and python-tds
on shared listeners. Performance reports separate native execution from TCP and
client decoding. Compatibility references are the official PostgreSQL frontend/
backend protocol documentation, MySQL Client/Server Protocol documentation and
Microsoft's MS-TDS specification.
