# Independent SQL read execution

`Database.ReadContext` owns the mutable parser, binder, plan and execution
workspace for one reader. It borrows one shared database; it does not copy table
storage, row versions, indexes or database state. Multiple contexts can execute
on native workers at once. Default database and transaction methods still require
serialization.

The owner must exclude **all** storage/catalog/sequence mutations and storage
reclamation throughout execution. With split `prepare` / `run`, that ownership
must cover both operations and their interval. A context is not a snapshot pin,
a transactional lock manager, or an implementation of simultaneous readers and
writers over mutating structures. A shared reader/writer gate is one supported
way to meet the contract. Lock exclusive ownership before any default database
operation that could mutate storage; do not acquire upgrades recursively.

For external storage/workspace, size a private caller buffer with
`ReadContext.backingBytes(work_rows)` and attach it with `bindMemory`. Each
context, workspace, result and query source must keep exclusive or immutable
ownership as appropriate. Do not copy a live context or share its writable
scratch/results with another reader. Binding and execution reject overlap with
the context, database metadata/backing, source and result. Scratch exhaustion
remains an explicit SQL capacity error, with no hidden heap fallback.

`execute(db, sql, snapshot, result)` performs parsing, binding and execution.
`prepare` and `run` expose the same path for a caller routing an existing wire
codec. Prepared source remains borrowed and immutable. The caller supplies the
statement snapshot and concurrency-safe session clocks/zone resolver/control.
System views use the context's own deparser scratch and the same supplied
snapshot; they do not borrow the database's mutable session or node pool.

Only SELECT/general read queries are accepted. Row-locking SELECT, DML, DDL,
transaction controls and sequence operations are rejected. Sequence hooks are
disabled before binding, so a supplied hook cannot accidentally advance a
sequence during constant processing. Normal database APIs retain those features.

`Store.Connection.read_context` is an explicit adapter for an autocommit codec
call over the **same** store. While set, `execute` accepts only the exact prepared
source and `valueSession` returns the reader's private session. It rejects active
transactions, pending statements, failed state and mismatched databases/source.
The caller clears the adapter before releasing shared ownership; transaction,
COPY, portal and session-control calls remain on the serialized route.

`worker_thread.RwLock` supplies native Windows SRW shared/exclusive ownership and
a Linux no-libc gate with explicit writer intent and futex-backed wakeups. Queued
Linux writers prevent an unbounded stream of new readers bypassing them.
Controls remain at stable caller-owned addresses; no thread detach or heap-backed
thread runtime is introduced.

`sig build test-parallel-read test-workers -Doptimize=ReleaseSafe` exercises one
shared database with eight real workers and 2,000 PK/filter/aggregate/join/sort/
subquery SQL executions. A checkpoint barrier forces all eight contexts to meet
inside execution. Additional cases cover aliases, forbidden mutation, catalog
views, work cancellation, committed/own uncommitted visibility and store adapter
state. The gate contract checks 12,000 shared reads and 4,000 exclusive writes.
Use `-Dlink-libc=false` on Linux for actual native worker execution. Unsupported
worker platforms run SQL serially and report that distinction explicitly.

These engine contracts alone do not claim network-server integration, parallel
writers, 100M-row table storage, comprehensive dialect support or benchmark wins.
