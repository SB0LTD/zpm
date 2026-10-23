# Allocator-free in-memory SQL

`src/core/sql.sig` is the reusable Layer 0 `@zpm/sql` package. It imports only its own
`src/core/sql/*.sig` sub-files (relative imports; consumers import only `sql`) and
has no system libraries, platform dependencies, or allocator parameters. The RAMSQL
project consumes this engine rather than duplicating parsing and storage.

```zig
const sql = @import("sql");
const DB = sql.Database(.{
    .tables = 2, .columns = 4, .rows_per_table = 64,
    .name_bytes = 32, .text_bytes = 128, .predicates = 8,
});
var db: DB = .{};
var result: DB.Result = .{};
try db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)", &result);
try db.execute("INSERT INTO notes VALUES (1, 'hello')", &result);
try db.execute("SELECT body FROM notes WHERE id = 1", &result);
const body = result.rows[0].cells[0].text.slice();
```

Resolve the declared ZPM dependency through `ctx.getDependency("zpm")`, then
register `sql` at `dependency.modulePath("src/core/sql.sig", &path_buffer)`.
No transitive import wiring is required. ZPM's coarse `core` module also exposes
`core.sql`. Sig build dependencies are distributed as pinned GitHub archives;
the planned hosted ZPM registry is not required.

## Ownership and bounds

`Config` defines nonzero comptime bounds for tables, columns, rows per table,
identifier bytes, text bytes per cell, and predicates per WHERE clause. Defaults
are 4, 8, 128, 32, 128, and 8 respectively. `versions_per_table` (default
2 x rows), `tx_writes` (statement undo entries, default rows), `expr_nodes` (512)
and `expr_depth` (64) bound row versions and statement parsing. All schema, row
versions, indices, statement scratch and text live inline in `DB`. `DB.storageBytes()` equals `@sizeOf(DB)`. Results have separate caller
storage, measured by `@sizeOf(DB.Result)`; choose stack or static storage for the
profile's size. `tableCount()` returns the number of live tables.

`execute(source, &result)` accepts one statement and copies input names and
text. Successful SELECT copies headers/rows into result, without borrowing
database memory. Mutation results expose `affected_rows`; CREATE/DROP report 0.
Every error leaves the database and previous result unchanged. The caller
serializes calls. `Result.command` reports the statement kind.
`describe(source, &result)` parses and binds without executing (SELECT reports
column names and types).

Transactions (READ COMMITTED only): `begin()` returns a transaction slot
(`Config.transactions`, `TransactionCapacity` when full); `statement(slot,
source, &result, .{})` runs one statement as a statement subtransaction under a
new snapshot; `prepareCommit(slot, buffer)` encodes the kind-3 record without
changing state, `publishCommit(slot)` stamps and releases everything
infallibly, `abort(slot)` undoes the transaction. A statement that meets a lock
held by a live transaction returns `WouldBlock` with its work kept;
re-delivering it with `.resume = true` continues under the same snapshot
(EvalPlanQual on every remaining target). `abortStatement`, `failScope`,
`savepoint`/`release`/`rollbackTo`, `deadlocked` (bounded DFS over wait-for
bitsets) and `control(source)` (decoded BEGIN/COMMIT/SAVEPOINT/SET/SHOW/RESET
for the store) complete the API. Catalog relations (`cat_relations`,
`cat_attributes`, `cat_attrdef`, `cat_sequences`) are versioned like rows, so
DDL is transactional. `execute`, `executeWithCommit` and `executeChanges` are
single-statement autocommit conveniences. `usage()` reports open
transactions, held locks and uncommitted versions for leak checks.

Statements run through a lexer, a recursive-descent parser with a statement-scoped
node pool, and a binder. Exhausting the pool or depth raises `StatementTooComplex`
(SQLSTATE 54001). Each table stores a row directory (stable u64 rowids,
generation-checked slots, rowid order for unordered scans), a version arena and a
multi-entry primary-key index filtered by visibility. A transaction's new versions and
deletion marks stay invisible to others until it publishes; a failing statement undoes its own.
Superseded versions are reclaimed after each publication (at most 64) and on
demand, once no pinned snapshot of a parked statement can see them.
If none can be reclaimed the statement fails with `VersionCapacity` (53200), a
documented capacity limit where PostgreSQL would succeed.

`executeChanges(source, &result, record, &used, context, commit)` additionally
encodes the completed statement's row and DDL ops as a versioned little-endian
kind-3 change record; overflow is `TransactionLogCapacity` with no state change.
`applyChangeRecord(record, &scratch)` decodes and validates the whole record
against a caller-owned `ReplayScratch` before applying anything and fails closed
on unknown versions/ops (`UnsupportedLogVersion`), malformed bytes
(`InvalidChangeRecord`) or OID/rowid/key/capacity conflicts
(`ChangeRecordConflict`). `executeLegacy` replays alpha SQL-text WAL records
with the alpha grammar only; anything else is `UnsupportedLogVersion`.

`Result` contains `column_count`, `row_count`, `affected_rows`,
`column_names[config.columns]`, and `rows[config.rows_per_table]`. Each row has
`cells[config.columns]`; `Cell` is a tagged union of `.null_value`,
`.integer: i64`, `.boolean: bool`, and `.text: Text`. `Name.slice()` and
`Text.slice()` borrow their owning value. Do not retain such a slice after
moving or overwriting that owner.

`DB.copyFrom(&source)` copies a complete logical snapshot into distinct storage,
including live schemas, rows and primary-key indices. `Result.copyFrom` copies
only active headers and cells. Both accept uninitialized destination storage;
callers must never inspect inactive table/row/column ranges. `DB.copyFrom`
requires a source without open transactions; the store never copies a
database. CREATE/DROP/DELETE leave inactive row payloads alone.

`executeWithCommit(source, &result, context, commit)` adds a synchronous commit
boundary without introducing a storage dependency into Layer 0. Each mutation
fully parses and validates syntax, types, constraints and capacity first, calls
`commit(context)` exactly once, then applies the validated change without a
further fallible operation. SELECT never calls the hook. Hook failure preserves
the complete database and previous result. The caller serializes the entire
call; the hook must not change the database, source or result, or reenter a write.
Read-only observation is permitted. A hook can flush WAL before publication
without a database-sized candidate or a second parse. Ordinary `execute` uses
the same validation/application path with a compile-time no-op boundary.

## SQL subset

CREATE/DROP TABLE; single-row INSERT with optional column mapping and expression
values; SELECT expressions or `*` with optional `FROM table [[AS] alias]` (one
table; no FROM evaluates one row); UPDATE with expression SET; DELETE. Columns
have INTEGER/INT/INT4, BIGINT/INT8, BOOLEAN/BOOL, or TEXT types, with NOT NULL
and one single-column PRIMARY KEY. The primary key is also non-null. Omitted
INSERT columns become NULL.

Expressions (Q01) use PostgreSQL precedence, lowest first: OR, AND, NOT, IS,
comparison (non-associative), BETWEEN/IN/LIKE/ILIKE, `||`, `+ -`, `* / %`,
unary `+ -`, `::`. Supported forms: literals, (qualified) columns, parentheses,
`=`, `<>`/`!=`, `<`, `<=`, `>`, `>=`, AND/OR/NOT with three-valued logic,
`IS [NOT] NULL|TRUE|FALSE|UNKNOWN`, `[NOT] IN (list)`, `[NOT] BETWEEN`,
`[NOT] LIKE|ILIKE` (`%`, `_`, default `\` escape), `||`, checked integer
arithmetic, `CASE` (searched and simple), `COALESCE`, `NULLIF`, `x::type` and
`CAST(x AS type)`. The binder types every expression with PostgreSQL's
implicit-cast rules for this type set: untyped string/NULL literals take their
type from context and are parsed at bind time (`'x'::integer` and `id = 'x'`
are 22P02 even on empty tables); int4 and int8 mix to int8; there is no
integer-to-boolean coercion (`WHERE id` is `TypeMismatch`/42804); an operator
with no matching signature is `UndefinedFunction` (42883), `unknown + unknown`
is `AmbiguousFunction` (42725), an impossible cast is `CannotCoerce` (42846).
Evaluation checks int4/int8 overflow (`IntegerOverflow`, 22003) and division
or modulo by zero (`DivisionByZero`, 22012); text input to integer and boolean
casts follows int4in/int8in (signs, whitespace, `_`, 0x/0o/0b) and boolin.
Assignments (INSERT values, UPDATE SET) use PostgreSQL assignment casts:
int8 into int4 is range checked, integers and booleans convert into TEXT.
Output columns are named like PostgreSQL (column, `coalesce`/`nullif`/`case`,
cast type name such as `int4`, or `?column?`; `AS` aliases and quoted
identifiers keep their case). `$n` reaching the engine is
`UndefinedParameter`; decimal literals are `UnsupportedStatement` until NUMERIC.
Other functions, JSON operators, aggregates, joins and subqueries are not
supported.

WHERE keeps a row only when its predicate is TRUE. A top-level `pk = constant`
conjunct (any constant expression) uses the primary-key index. At most
`Config.predicates` leaf predicates may appear in one WHERE (`PredicateCapacity`).
ORDER BY takes up to `columns` keys: expressions, output positions (out of
range is `InvalidColumnReference`, 42P10) or output names, each with ASC/DESC and
NULLS FIRST/LAST, then LIMIT. Sorting is a stable merge sort; with NULL first
ascending and last descending by default (`Config.nulls_first_ascending = false`
selects PostgreSQL's inverse defaults). Text compares bytewise.

UPDATE and DELETE visit rows in rowid order; WHERE, SET evaluation and
primary-key checks interleave per row like a PostgreSQL heap scan. A key is
taken by any committed row this statement has not already replaced, or by a
version this statement created (so `SET id = id + 1` over 1, 2, 3 is a
violation, as in PostgreSQL for that physical order). Any error, including one
after hundreds of rows, leaves zero rows changed. A failing SELECT never
writes its result: fallible projections and sort keys are evaluated first.

Dialect: `Database.dialect` (`.postgres` default, `.mysql`, `.tds`) is session
state set by the caller before each statement; `db_store` connections set it,
and the MySQL/TDS sessions set theirs on their first message. On `.postgres`
an unqualified INTEGER is always int4 and BIGINT int8. On `.mysql`/`.tds`
`Config.integer_bits` (default 64) selects INTEGER's width and integer 0/1 may
be assigned to BOOLEAN; expression typing is identical in every dialect.
Cells retain the shared i64 payload. The wire sessions report the correct width
(PostgreSQL OIDs 23/20, MySQL LONG/LONGLONG, TDS INTN 4/8), including binary
encoding and prepared parameter inference. Applications persisting SQL must
version this schema interpretation separately: `durable_log.appendKind` /
`recoverKind` provide a checked payload kind. Never replay 64-bit INTEGER logs
under a 32-bit INTEGER schema interpretation without an explicit migration.
`executeLegacy` keeps the alpha interpretation (integer_bits, boolean 0/1 in
assignments and comparisons) and accepts only the frozen alpha grammar.

Keywords and unquoted ASCII identifiers are case insensitive; double-quoted
identifiers keep their case. Strings use apostrophes, escaped by doubling them;
integer literals are signed 64-bit. Optional final semicolon, whitespace, `--`
and nested `/* */` comments are accepted. Identifiers and text have explicit
byte capacities (text results of `||` included). SQL text is never executed as
a batch, and unsupported trailing clauses are rejected before mutation.

Errors include `Syntax`, `UnsupportedStatement`, `TableCapacity`,
`ColumnCapacity`, `RowCapacity`, `NameCapacity`, `TextCapacity`,
`PredicateCapacity`, `TableExists`, `TableNotFound`, `ColumnNotFound`,
`DuplicateColumn`, `TypeMismatch`, `NotNullViolation`, `PrimaryKeyViolation`,
`IntegerOverflow`, `StatementTooComplex`, `VersionCapacity`,
`TransactionLogCapacity`, `UnsupportedLogVersion`, `InvalidChangeRecord`,
`ChangeRecordConflict`, `UndefinedFunction`, `AmbiguousFunction`,
`CannotCoerce`, `InvalidTextRepresentation`, `DivisionByZero`,
`InvalidEscapeSequence`, `UndefinedParameter`, `InvalidColumnReference` and the
transaction errors `WouldBlock` (never sent to clients), `SerializationFailure`,
`DeadlockDetected`, `LockNotAvailable`, `QueryCanceled`, `TransactionCapacity`,
`WriteSetCapacity`, `LockCapacity`, `CatalogCapacity`, `SavepointCapacity`,
`SavepointNotFound`, `NoActiveTransaction`, `ReadOnlyTransaction`,
`UndefinedSetting` and `InvalidSettingValue`.
`postgres.knownSqlstate` maps every one of them explicitly.

Primary keys use a fixed multi-entry open-addressing hash index (key to version,
maximum 50% load). Equality lookups and duplicate detection use that index. LIMIT
without ordering stops scanning once enough rows match. Result clearing changes
only active counts; callers must observe the active ranges. Column types are
reported even when a SELECT returns zero rows.

Joins, aggregates, secondary indexes, NUMERIC and other types, functions beyond
COALESCE/NULLIF, and complete SQL-standard or PostgreSQL conformance remain
unimplemented. The reusable shared transaction adapter and wire sessions are
documented in [database-server.md](database-server.md).
## Validation

Run `sig build test-sql --summary all` with Sig 0.6.3. The target compiles and
executes `tests/test_sql.sig`, `test_sql_index.sig`, `test_sql_storage.sig` and
`test_sql_change_log.sig`, emitting assertion, statement, and fuzz counts.
It is also included in `sig build test`. The executable's `--prove-failure`
option deliberately returns nonzero, including release modes. Contracts cover
operations, ownership, fail-atomic constraints, capacity exhaustion/reuse,
integer limits, malformed syntax, NULL semantics, deterministic fuzz inputs,
expression precedence, truth tables, SQLSTATE classes and failure-after-many-rows
atomicity.
