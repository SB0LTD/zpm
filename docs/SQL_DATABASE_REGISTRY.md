# PostgreSQL database registry

The in-memory registry manages names, durable OIDs, caller-owned Store pointers
and connection leases. The embedding serializes its operations. Its Store
backing stays at a stable address throughout registration and use. Runtime slot
and lease generations prevent stale handles from affecting recycled entries.
An embedding that retains a pointer beyond a connection's lifetime must hold
its own lease or include that use in its quiescence checks.

An embedding opts into PostgreSQL routing by exposing
`admitPostgresStartup(StartupAdmission)` on its protocol adapter. The hook runs
after successful SCRAM verification or with an explicit `.trusted` method when
the host configures trust. The adapter resolves the server-verified principal,
checks database CONNECT rights, acquires the lease, configures the database
session and publishes that binding together. It releases the provisional lease
on failure and the accepted lease after all connection work has stopped.
Startup option slices borrow the frame or the session's fixed buffer and must
be consumed synchronously. `SessionWithAdmission(DB, true)` accepts an
embedding-owned callback and a scratch slice of `routed_startup_capacity`
bytes as an alternative to extending the adapter type. SSL, GSS and cancellation requests follow their
existing transport paths. Adapters without the hook use the single-database
path.

The cluster utility parser recognizes standalone `CREATE DATABASE name` and
`DROP DATABASE [IF EXISTS] name` in the PostgreSQL dialect. Product integration
requires an explicit cluster command path, transaction-block checks and
ownership checks. The normal database executor remains responsible for
database-local SQL and WAL.

`Database.setDatabaseCatalog` optionally exposes the embedding's live OID,
name and owner rows through `pg_database`. The provider remains stable and
keeps a consistent view of its backing for the duration of SQL execution.

## Durable integration

The host needs a durable cluster journal that records each database's exact
name, stable OID, owner and physical Store/WAL identity. On startup, reconstruct
the published registry before listeners start, open each Store against the
recorded physical identity, and restore the OID high-water mark. OIDs allocated
to records that can survive a crash must never be reused. Catalogue access
should read the same published entries, and `current_database()` should report
the name from the bound lease.

1. For CREATE, check the role and command context, reserve the name and identity,
   initialize a new Store and WAL, and stage the Store. Persist the backing and
   its identity before committing the cluster publication record. Publish the
   staged Store in memory only after that commit. Incomplete staging must be
   recoverable as an orphan.
2. For DROP, check the role and command context, reject the current database
   and check for prepared transactions and other Store users. Fence the
   quiescent entry, durably record its tombstone, then return the Store and
   reclaim the backing. On a definite journal failure, cancel the fence. On
   uncertain publication, resolve the journal outcome before reopening access.
3. Pin each connection, detached executor and cancellation target to the same
   database identity throughout its work. Release the lease only after session,
   worker and background use has quiesced. Recycled Store addresses must
   invalidate database-specific cached state.

The product owns durable journaling, per-database Store provisioning,
identity policy, transport integration and crash/restart validation.
