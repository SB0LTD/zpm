# Transaction control in procedures, SEARCH / CYCLE (B11 wave 5, proc-tx)

Branch `w5/proc-tx`. `contract-sql-proc-tx` (tests/test_sql_proc_tx.sig)
runs every statement through the PostgreSQL wire over store connections,
replays every committed record into a replica that must answer like the
primary after each step, and checks a crash between two COMMITs. Every
expectation was checked against native PostgreSQL 18.7 statement by
statement, except where this page says otherwise.

## COMMIT / ROLLBACK inside procedures and DO blocks (T261 in CALL / DO)

PL/pgSQL `COMMIT` / `ROLLBACK [AND [NO] CHAIN]` end the transaction in the
middle of a top-level CALL or DO that runs non-atomically, as PostgreSQL's
SPI_commit / SPI_rollback do. The CALL / DO goes on in a new transaction
with every variable intact (loop counters, INOUT values); CommandComplete is
still one `CALL` / `DO`.

| Context | Result |
|---|---|
| A single-statement simple Query in autocommit | allowed |
| The first command of an extended-protocol group (before Sync) | allowed; commands after it run in its last transaction |
| A later pipelined command of the same group | 2D000 (the group rolls back) |
| A multi-statement simple Query (implicit block), an explicit block | 2D000 |
| A function or trigger below, a SQL-language routine on the stack | 2D000 |
| Inside a block with an EXCEPTION clause in any routine on the stack | 2D000 |
| Inside the EXCEPTION handler itself | allowed (the block's subtransaction is gone) |
| A SECURITY DEFINER routine or one with SET clauses on the stack | 2D000 |
| Nested CALL / DO chains (procedure calling procedure, DO in DO) | allowed |
| `COMMIT` in a SQL-language procedure body | 0A000 (as before; PostgreSQL's error too) |

- **Mechanism.** `StatementOptions.transaction_control` carries the caller's
  `TransactionControl` hook. The store installs it for exactly the
  non-atomic cases above. At a COMMIT the engine calls `end(slot, commit)`:
  the store commits the transaction as it commits any (deferred constraint
  checks, `prepareCommit`, `commit_fn` writes and syncs the record, then
  `publishCommit`), or aborts it for ROLLBACK. The engine then begins the
  next transaction **in the same slot** (a new epoch) with the session's
  default modes, or the ended one's isolation level, READ ONLY and
  DEFERRABLE with AND CHAIN, opens a statement scope at its first write and
  gives the routine a new command id and snapshot. The store's slot, the
  implicit-statement commit at the end and the extended group's Sync all
  keep working on that slot. Each COMMIT is its own change record and
  replays alone; no change-log op or format changed.
- **Errors.** An error after a COMMIT rolls back only the work after it; the
  CALL fails with the error. A failing COMMIT (a deferred constraint, 23503;
  a full encode buffer, 53200; a persistence error) rolls that transaction
  back and fails the CALL with the store's own error (persistence errors
  also mark storage failed, 58030 for later writes).
- **Lock waits.** Before any COMMIT a wait parks the CALL and the
  re-delivered statement runs it again from its start (wave 3). After a
  COMMIT it cannot: the committed part would run twice, and nothing else can
  run while the single-threaded store waits inside a statement. Such a wait
  fails at once with 55P03 (lock_not_available), as a `lock_timeout` ends a
  wait in PostgreSQL; a handler in the routine may catch it, and only the
  work after the last COMMIT rolls back. **This differs from PostgreSQL,
  which waits** (with `lock_timeout` set, native PostgreSQL 18.7 gives the
  same results as this store; the contract's lock cases were checked that
  way). The same holds for a SERIALIZABLE READ ONLY DEFERRABLE safe-snapshot
  wait begun after a COMMIT.
- **Characteristics.** `SET TRANSACTION` now runs as a statement of a
  procedure or DO block (it was 0A000). Before any COMMIT the CALL has taken
  its snapshot, so a new isolation level, READ WRITE or DEFERRABLE is 25001
  (READ ONLY is allowed); right after a COMMIT / ROLLBACK, until the next SQL
  statement, the new transaction's modes may still change.
- **Clocks.** now() is the new transaction's start (the store's wall clock
  at the COMMIT), statement_timestamp() stays the CALL's;
  transaction_timeout restarts with each transaction. In an extended group
  SET LOCAL values end at the COMMIT.
- **Routine versions.** While a CALL that committed runs, routine versions
  are not reclaimed past the csn it started at, so a procedure that drops or
  replaces itself and commits keeps running its own body.

- **Deferred constraint triggers.** A COMMIT inside the CALL / DO first
  fires the pending events of deferred constraint triggers (T212) in the
  transaction it ends, as PostgreSQL does at every COMMIT: the trigger
  functions run as a statement of the routine, their writes join that
  transaction's record, and a raise fails the CALL and rolls that
  transaction back. ROLLBACK discards the events.

Not covered: `FOR record IN query LOOP` (and with it the holdable cursor a
COMMIT inside such a loop needs) is still outside the PL/pgSQL subset
(docs/SQL_ROUTINES.md); cursors declared in routines.

## Engine and store changes

- `src/core/sql.sig`: `StatementOptions.transaction_control`,
  `TransactionControl`, `Database.routineTransaction(atomic, commit, chain)`,
  `continueStatement`, `routineAtomic`, `routineSetTransaction`; `park()`
  fails a wait after an in-statement COMMIT; `statement()` ends in the last
  transaction's scope; routine statements refresh saved snapshots when the
  transaction changed under them.
- `src/core/sql/routine.sig`: the interpreter passes COMMIT vs ROLLBACK and
  AND CHAIN, and reports its EXCEPTION blocks (not while a handler runs).
- `src/db/store.sig`: `Connection.endStatementTransaction` (the hook),
  `Pending.nonatomic`, `statement_commit_error`.
- New Database fields (`statement_control`, `call_commits`,
  `call_object_horizon`, `routine_atomic`, `routine_fresh_transaction`) are
  per statement and reset in `copyState` and at every statement.

## Errors

Used: 2D000, 0A000, 25001, 25006, 55P03, 22012, 23503, 42883, 58030, 53200.
No new SQLSTATE mapping was needed.
