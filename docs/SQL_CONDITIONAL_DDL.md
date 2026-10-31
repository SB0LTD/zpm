# Conditional table and sequence DDL

The candidate adds CREATE TABLE/SEQUENCE IF NOT EXISTS and DROP TABLE/SEQUENCE
IF EXISTS within the existing SQL subset. Catalog lookup uses the statement's
MVCC snapshot, including its own transaction's visible schema changes. CREATE
skips any existing relation of the same name, including the other supported
relation kind. DROP skips only an absent relation; an existing object of the
wrong kind still raises42809. Existing table rows, defaults, identity metadata
and sequence values are preserved. Ordinary unquoted objects named `if` remain
valid; lookahead distinguishes their names from conditional clauses.

A skipped command binds to an explicit no-op with its original command tag and
zero affected rows. It does not reserve table/sequence slots, allocate OIDs,
create identity sequences or append schema mutations. Existing parser capacity
and supported-type/constraint rules still apply. The syntax must parse even
when execution skips creation. Wider CREATE variants, schemas, multiple-object
DROP, dependency modes and full PostgreSQL DDL compatibility remain open.

The runtime remains allocator-free in ZPM Layer0; RAMSQL only integrates it.
No WAL opcode/version changes are needed: only actual create/drop operations
enter the existing typed journal. Skipped autocommit statements must not invoke
commit callbacks or require an empty change record. Pending sequence state must
still be persisted when present; the no-op must not suppress earlier transaction
writes or carried sequence watermarks. Core contracts verify callback failures,
zero-length buffers for genuine no-ops, and WAL replay of carried sequence state.
Sequence DROP waits now refresh the catalog snapshot if no writes preceded the
wait; a retry skips committed deletion and performs deletion after rollback.

The pure database API models transactions through begin/statement/abort/commit;
SQL transaction-control statements belong to the store/server layer. Likewise,
the statement `writes` admission option is not full SQL READ ONLY semantics.
NoticeResponse messages for skipped conditional commands are not implemented by
this slice; success tags/data effects are a separate scope from notice parity.

Initial tests fail Syntax against the preceding main. Independent adversarial
review reproduced the IF-name regression and empty-record/callback bug before
their fixes. The conditional contract passes207 assertions, including49 frozen
PostgreSQL16.15 programs, API concurrency retries, WAL/replay, capacity/control
and cleanup. Independent review reran it and the existing MVCC351, catalog36,
change-log940, expressions397, DML229, expression-source75 and generated132
assertion suites in Linux ReleaseSafe; all exited0. The unchanged118-program
inventory advances to12 smoke passes,89 failures,17 unexecuted and intentionally
exits1 SqlConformanceIncomplete. Hosted/wire/PG18 qualification remains pending.
A smoke pass does not close the DDL family. Reproduce native fixtures with:

```powershell
python tools/capture_sql_conditional_ddl_oracle.py --psql wsl -d Ubuntu -u postgres psql
```

References: [PostgreSQL18 CREATE TABLE](https://www.postgresql.org/docs/18/sql-createtable.html)
and [DROP TABLE](https://www.postgresql.org/docs/18/sql-droptable.html).
