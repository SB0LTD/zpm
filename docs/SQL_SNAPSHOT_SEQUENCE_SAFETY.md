# Live snapshot and shared sequence durability

This allocator-free ZPM batch fixes two independently reproduced high-severity
findings: STO-02 and STO-04. It does not close the remaining hardening program.

## Snapshot ownership (STO-02)

Each transaction now holds an optional `running_snap` during statement bodies
and COPY startup. The reclamation horizon counts it, non-fresh parked pins,
and the `copy_snap` of every open COPY between data messages. Deferred cleanup
releases the running guard on success, terminal error and WouldBlock; parked
or COPY state retains ownership where required. Abort/free reset the guard.
No heap allocation, table clone, or per-client database snapshot is introduced.

The MVCC contract creates three rows, parks UPDATE after its first row, fills
all version slots with its blocker's writes, commits the blocker, then resumes.
Before the fix it silently succeeds with two affected rows instead of three.
After the fix it returns VersionCapacity (53200) and rolls back the entire
statement. Existing adequate-capacity EPQ schedules still complete normally.
The COPY contract verifies old versions survive both writer publication and
explicit vacuum between COPY messages, then become reclaimable after finish
or cancellation. Version pressure may require a capacity error; reclaiming
visible versions to turn that error into apparent success is incorrect.

## Global pending sequence log-ahead (STO-04)

A sequence's newly logged watermark is pending globally as soon as nextval,
identity or setval changes it, including while its owning transaction remains
live. Every durable commit includes globally pending watermarks before
publication clears them. Per-owner dirty bits remain a backstop for sequence
CREATEs that another transaction cannot yet persist. Later cache hits retain
the no-record path once the shared watermark has been durably published.
The implementation reuses the existing bounded sequence bitset and record
format; no extra sync or record is needed for each already-durable cache hit.

The replay regression keeps owner A live after drawing value 1, commits value 2
from B, and replays only acknowledged change records into a fresh database.
Before the fix B emits no record and recovery starts at 1, allowing 2 to be
issued again. After the fix recovery starts beyond the durable log-ahead.
Ascending/descending tests cover this schedule, subsequent no-record cache
hits, owner abort, and a pending CREATE whose obligation survives an unrelated
commit. RAMSQL adds process-kill tests and PostgreSQL crash differentials with
a live owner and committed consumer insert.

Sequence gaps remain intentional. Explicit setval and CYCLE can deliberately
reuse values; these fixes do not promise gapless or globally unique sequences
under those operations. Reference:
[PostgreSQL sequence guarantees](https://www.postgresql.org/docs/18/functions-sequence.html).

## Remaining boundaries

STO-05 (complete-length torn WAL tail), NET-02 (nested-comment placeholder
scanning), volatile DML replay, broader SQL features, and the formal FV-05/FV-08
proof obligations remain separate work. In particular, never solve torn-tail
availability by silently discarding a possibly acknowledged corrupt commit.
