# SQL transactions and session state (conformance lane B11, tx-session)

Branch `b11/tx-session` closes eight smoke programs of the 118-program
inventory test-first: PG.TX.ISOLATION, PG.TX.CHARACTERISTICS,
PG.TX.LOCK_MODES, PG.TX.TABLE_LOCK, PG.CURSOR, PG.SQL_PREPARE,
PG.SESSION.SETTINGS and PG.SESSION.NOTIFY. The unchanged driver moves from
71 smoke passes (20e7528) to 79; it still exits 1 (SqlConformanceIncomplete)
and no other program changed. A smoke pass is not family closure.

`contract-sql-tx-session` (tests/test_sql_tx_session.sig) runs the eight
oracle programs as the driver does, then concurrent schedules of engine
transactions and of two (or three) store connections, the PostgreSQL wire
(NotificationResponse, command tags, SQLSTATEs), every new capacity
(54000) and replay of REPEATABLE READ / SERIALIZABLE commits into a replica
that must answer like the primary. Only the oracle fixtures are
native-verified; every other expectation follows the PostgreSQL 18
documentation and source and is pending native verification.

## Design

- Transaction modes live in the transaction (mvcc.sig `Tx`): isolation,
  READ ONLY, DEFERRABLE, the transaction snapshot and the SERIALIZABLE
  record. `begin()` copies the session's default_transaction_* settings.
- Session state belongs to the connection (session.sig `State`): engine
  settings with their transactional stack, SQL prepared statements and
  pending LISTEN/UNLISTEN. `Store.Connection` owns one and installs it as
  `Database.session_state` with every call (callers without connections
  use `default_session_state`); `disconnect()` calls `endSession()`.
- Shared engine pools: cursor rows (Config.cursors, Config.cursor_rows),
  the notification ring, listeners and pending NOTIFY entries, advisory
  locks (locks.sig) and SERIALIZABLE records (ssi.sig).
- `Database.statement()` executes SET / SHOW / RESET / SET TRANSACTION
  and the session commands itself, so the conformance driver (one
  transaction, no connection) runs them; the store keeps executing its own
  settings (TimeZone, timeouts, DateStyle, ...) and routes the engine's.

## Scope

| Program | Implemented | Not covered |
|---|---|---|
| Isolation | READ COMMITTED; REPEATABLE READ keeps the first snapshot-taking statement's snapshot (PlannedStmtRequiresSnapshot: SET/SHOW/LOCK/FETCH/LISTEN/NOTIFY take none) and raises 40001 where READ COMMITTED would follow a concurrent update or delete (UPDATE, DELETE, MERGE, SELECT FOR ..., ON CONFLICT on an invisible row, FK actions); SERIALIZABLE = REPEATABLE READ plus SSI (below); READ UNCOMMITTED behaves as READ COMMITTED and shows as itself | catalog lookups use the transaction snapshot (PostgreSQL uses a fresh catalog snapshot, so a table created after the snapshot is 42P01 here) |
| SERIALIZABLE | SSI at relation granularity: SIREAD on every table read (AccessShare/RowShare, UPDATE/DELETE/MERGE targets, ON CONFLICT), writes on DML/TRUNCATE/DDL targets, rw-antidependency edges between overlapping SERIALIZABLE transactions, failure (40001) of the transaction creating an edge that makes either end a pivot; a failed transaction is doomed (its COMMIT is 40001, also after ROLLBACK TO); committed records kept while overlapped, folded into summary flags when dropped. Sound: no serialization anomaly among SERIALIZABLE transactions commits | tuple/page granularity and PostgreSQL's "T3 commits first" and read-only refinements: more 40001s than PostgreSQL (two SERIALIZABLE transactions that read and write the same table always conflict); no summarization under memory pressure (a full record table is 54000) |
| Characteristics | BEGIN / START TRANSACTION / SET TRANSACTION / SET SESSION CHARACTERISTICS AS TRANSACTION with any mode list; PostgreSQL's check hooks (25001 after the first query or inside a savepoint for isolation, READ WRITE and DEFERRABLE); READ ONLY: 25006 for DML, DDL, data-modifying WITH, SELECT FOR ..., nextval/setval, COPY FROM and LOCK above ROW EXCLUSIVE, before anything runs; SERIALIZABLE READ ONLY DEFERRABLE waits (parks) until no SERIALIZABLE read-write transaction holds a snapshot, then runs untracked; SHOW/SET transaction_isolation, transaction_read_only, transaction_deferrable, default_transaction_* | SET TRANSACTION SNAPSHOT (0A000); PostgreSQL's weaker safe-snapshot condition |
| Row locks | FOR UPDATE / NO KEY UPDATE / SHARE / KEY SHARE with PostgreSQL's conflict matrix and in-place upgrades (undone with the subtransaction); OF names (42P01 for a name not in FROM) | UPDATE/DELETE's implicit lock always has FOR UPDATE strength (a non-key UPDATE is NO KEY UPDATE in PostgreSQL, so FOR KEY SHARE waits for it here); locking clauses on joins (existing 0A000) |
| LOCK TABLE | all eight modes with PostgreSQL's conflict matrix, against the engine's own AccessShare / RowShare (SELECT FOR ...) / RowExclusive / AccessExclusive locks, FIFO waits, NOWAIT (55P03), ONLY and inheritance/partition children; 25P01 outside a block | views (0A000; PostgreSQL locks the view's base tables) |
| Advisory locks | pg_try_advisory_lock[_shared], pg_try_advisory_xact_lock[_shared] (bigint and int4,int4), pg_advisory_unlock[_shared]; reentrant; session-level locks survive rollback and end with the session; transaction-level ones end with the (sub)transaction | the blocking and void forms (pg_advisory_lock, pg_advisory_xact_lock, pg_advisory_unlock_all) need a void type (42883 today) |
| Settings | SET / SET LOCAL / RESET / RESET ALL / SHOW of search_path, default_transaction_*, transaction_* and placeholders (`prefix.name`); transactional like guc.c (ROLLBACK, ROLLBACK TO, RELEASE, error scopes, SET LOCAL ends with the transaction, a failed statement undoes its set_config); current_setting(name [, missing_ok]) and set_config(name, value, is_local) for engine and store settings; search_path list syntax flattened as PostgreSQL shows it | search_path values other than public with "$user", pg_catalog, pg_temp (0A000: name resolution here is pg_catalog then public); SHOW ALL; a placeholder created and rolled back disappears (PostgreSQL keeps it defined) |
| Cursors | DECLARE [BINARY] [ASENSITIVE/INSENSITIVE] [[NO] SCROLL] CURSOR [WITH/WITHOUT HOLD] FOR query; FETCH/MOVE NEXT, PRIOR, FIRST, LAST, ABSOLUTE, RELATIVE, n, ALL, FORWARD, BACKWARD with PostgreSQL's positions and counts; NO SCROLL never moves back (55000); CLOSE [ALL]; per-session names (42P03, 34000); WITH HOLD survives COMMIT; cursors of a rolled-back (sub)transaction are dropped | rows are materialized at DECLARE (PostgreSQL runs lazily): volatile functions, errors and FOR UPDATE locks happen at DECLARE for every row; BINARY cursors (0A000); unspecified SCROLL allows backward moves for every plan |
| SQL PREPARE | PREPARE name [(types)] AS SELECT/VALUES/INSERT/UPDATE/DELETE/MERGE, parse analysis at PREPARE; EXECUTE with arguments coerced to the declared types in assignment context ($n are real parameters: `SELECT $1` is ?column?); DEALLOCATE [PREPARE] name/ALL; not transactional; 42P05, 26000, 42601 (argument count), 42804; the wire's DEALLOCATE reaches both namespaces | type inference for undeclared parameters (42P18 here); plan caching (each EXECUTE re-binds) |
| LISTEN / NOTIFY | LISTEN / UNLISTEN [*] take effect at commit (dropped with the (sub)transaction); NOTIFY channel [, 'payload'] queued per transaction, folded duplicates, dropped by ROLLBACK / ROLLBACK TO / a failed statement, published at commit in order; a listener reads from its own position (own notifications included); the codec sends NotificationResponse ('A': pid, channel, payload) before ReadyForQuery and through `Session.notifications()` while idle | pg_notify() (void result); pg_listening_channels(); payloads beyond Config.notify_payload_bytes (54000; PostgreSQL's limit is 8000 bytes, 22023 here at 8000) |

## Errors (SQLSTATE)

40001 SerializationFailure (concurrent update/delete, SSI), 25001
ActiveSqlTransaction, 25006 ReadOnlyTransaction, 25P01 NoActiveTransaction
(LOCK / DECLARE without HOLD outside a block), 55P03 LockNotAvailable,
55000 ObjectNotInPrerequisiteState (NO SCROLL), 34000 PortalNotFound,
42P03 DuplicatePortal, 26000 StatementNotFound, 42P05 DuplicateStatement,
42601 Syntax (EXECUTE argument count), 42804 TypeMismatch, 42P18
IndeterminateDatatype, 42704 UndefinedSetting, 22023 InvalidSettingValue /
InvalidParameterValue, 42P01, 42809, 3F000, 0A000 UnsupportedStatement,
54000 SessionCapacity.

## Capacities (Config, SessionCapacity 54000 unless noted)

statement_parameters 16, prepared_statements 8, prepared_bytes 1024,
cursors 4, cursor_rows 64 (0 = result_rows; the row pool is inline in the Database), custom_settings 4, setting_bytes
64, setting_snapshots 4 (savepoint levels that change settings),
listen_channels 8, listeners 8, notify_queue 32, notify_pending 16,
notify_payload_bytes 256, advisory_locks 32, serializable_transactions 0
(= 2 x transactions). The lock list now holds tables x 8 + row_locks x 4 +
advisory_locks x 2 entries (LockCapacity 53200 as before).

## Durability

No change-record op or value tag was added (ops 50-59 stay unused) and
the table definition format is unchanged: everything here is session or
lock state. Transactions committed under REPEATABLE READ and SERIALIZABLE
write the same records as before; the contract replays them into a replica.

## Pending native verification

Everything outside the eight oracle fixtures, in particular: the 25001 /
25006 / 40001 schedules, SSI outcomes (PostgreSQL may let the disjoint-row
write skew variants commit where this engine fails one), cursor positions
and MOVE counts, set_config / current_setting results, search_path
flattening, NOTIFY ordering and folding, advisory-lock results and the wire
command tags (FETCH n, MOVE n, DEALLOCATE ALL).
