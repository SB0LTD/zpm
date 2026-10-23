# Store API migration (READ COMMITTED, FEAT-004 / design §6)

The copy model is gone: `Store` no longer has `autocommit_workspace`,
`autocommit_result`, `generation` or the text `readonly()` classifier, and
`Store.Connection` no longer has `transaction_workspace`, `transaction_log`,
`log_used`, `dirty`, `logged` or `base_generation`. Generic Raw adapters
without the MVCC API (`TrackedDB`, `LegacyDB`) are no longer supported, so
their contracts were replaced by the guarantees below. Every assertion that
used a removed API now asserts the same guarantee through the new API.
Line numbers refer to `origin/main` (69ec5f2).

| File, origin line(s) | Old assertion | New assertion (current file) |
| --- | --- | --- |
| test_db_store.sig 32-33, 313-314; test_mysql.sig 87-88, 112-113, 158-159, 181-182, 218-221; test_tds.sig 130-131, 155-156, 196-197, 221-222, 256-259, 354-355, 430-431; test_pg_stream.sig 12, 75 | Each connection owns a `transaction_workspace` Raw copy | Connections hold no database copy; `mutationBoundaryStore` asserts `@sizeOf(Store.Connection) < DB.storageBytes() / 4` |
| test_db_store.sig 37, 45, 51 | `store.generation` unchanged by ROLLBACK, +1 by COMMIT | `store.database.csn` unchanged by ROLLBACK, +1 by a writing COMMIT |
| test_db_store.sig 66 | `!a.dirty and a.log_used == 0` after disconnect | `a.tx == null` and `quiescent()`: zero transactions, row/table locks and uncommitted versions |
| test_db_store.sig 101 (SerializationFailure, different rows) | Second writer's COMMIT fails 40001 | READ COMMITTED: both inserts commit; the next statement of `b` sees `a`'s commit (new snapshot per statement) |
| test_db_store.sig 113-115 | Read-only COMMIT keeps `generation` | Read-only COMMIT keeps `store.database.csn` |
| test_db_store.sig 128 (SerializationFailure, same row) | Stale DELETE-vs-UPDATE commit fails 40001 | The same-row UPDATE parks (`WouldBlock`, `blocked()`), `wakeReady()` after COMMIT, re-delivery re-checks the deleted row: UPDATE 0 |
| test_db_store.sig 134-136 | Missing / aliased workspace rejected | Transaction-table capacity: 8 open transactions, the 9th `beginTransaction` is `TransactionCapacity` (53200); all released on disconnect |
| test_db_store.sig 140-151 | Readonly-looking batches do not bump `generation`; `GenerationExhausted` | Same batches leave `store.database.csn` unchanged; generation exhaustion no longer exists (WAL sequence exhaustion stays in persistence) |
| test_db_store.sig 162-170, 210, 219, 252, 266, 292 (Probe `expected_generation`) | No publish before flush: `generation` unchanged while `commit_fn` runs | Probe reads `SELECT * FROM t` through a fresh snapshot inside `commit_fn` and sees the old row count (`observed`) |
| test_db_store.sig 192-197 | Durable store with `autocommit_workspace` and per-connection log | Durable store with one `encode_buffer` (transaction-bytes) |
| test_db_store.sig 203-221, 232-254, 268, 287 | `generation` checks around durable commits and failures | `store.database.csn` checks plus `quiescent()` after every failure |
| test_db_store.sig 218, 229, 246, 273 | `log_used` / `logged` bookkeeping | Commit record op count (`changeRecordOps == 2`), `connection.tx == null`, read-only test: autocommit and explicit read-only transactions never call `commit_fn` |
| test_db_store.sig 268 | Failed COMMIT leaves status `E` | Failed COMMIT ends the transaction (status `I`), as PostgreSQL does |
| test_db_store.sig 277-283 | `transaction_log` capacity: TransactionLogCapacity, state unchanged | Encode-buffer capacity: TransactionLogCapacity (53200), no hook call, state unchanged (`encode_buffer = encode[0..16]`) |
| test_db_store.sig 295 (SerializationFailure, durable) | Stale durable commit fails 40001 | Replaced by `parking()`: park-and-re-deliver (UPDATE 3 across a park) and unique-key race (commit -> 23505, rollback -> INSERT) |
| test_db_store.sig 300-305 | Aliased autocommit/transaction workspace -> InvalidWorkspace | No workspaces exist; removed with the API (aliasing is impossible) |
| test_db_store.sig 334-342 (SerializationFailure, 256 interleavings) | Second committer fails 40001; winner = first | Second writer parks, resumes after the first COMMIT and applies its change to the committed version: winner = second, `n` counts every update (no lost update), csn +2 |
| test_db_store.sig 378-471 (TrackedDB/LegacyDB) | `copies == 0`, legacy candidate path | `mutationBoundaryStore`: one record per durable write, failures poison storage, no database copy exists |
| test_sql.sig 398-442 (`copyFrom`) | Snapshot copy contract | Unchanged: `Database.copyFrom` remains for callers without open transactions |
| test_sql.sig 546-578 (`executeWithCommit`) | Observer inside the hook sees the old state | Unchanged, except an unpublished DROP TABLE now makes the observer wait (`WouldBlock` while AccessExclusive is held) |
| test_sql.sig `rejects`, `fuzzOne`, `execute` helpers (new) | Failure atomicity via untouched copies | Additionally `quiet(db)`: no transaction, lock or uncommitted version after every statement |
| test_mysql.sig 218-235; test_tds.sig 256-275 (concurrent commit) | Second writer's COMMIT fails | The same-row writer is `Reply.blocked` (consumed = written = 0), resumes after COMMIT with 0 rows |
| test_postgres.sig 532 | `SerializationFailure -> 40001` mapping | Unchanged mapping (still a defined engine error); `errorStates()` also maps every new error |

Per-contract assertion counts (`origin/main` -> now):

| Contract | origin/main | FEAT-004 |
| --- | --- | --- |
| contract-db_store | 2177 | 3058 |
| contract-sql | 7176 | 8432 |
| contract-mysql | 1167 | 1168 |
| contract-tds | 2660 | 2661 |
| contract-postgres | 14613 | 14773 |
| contract-pg_stream | 707 | 707 |
| contract-sql-mvcc (new) | - | 122 |
