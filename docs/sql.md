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

CREATE/DROP TABLE; CREATE/DROP SEQUENCE; INSERT [AS alias] with optional column
mapping and multi-row VALUES (DEFAULT items), INSERT ... SELECT or DEFAULT
VALUES, OVERRIDING SYSTEM|USER VALUE and ON CONFLICT on the primary key (DO
NOTHING / DO UPDATE SET ... [WHERE], EXCLUDED); SELECT; UPDATE with expression
SET (`SET col = DEFAULT`); DELETE; RETURNING on INSERT/UPDATE/DELETE. Columns
have SMALLINT/INT2, INTEGER/INT/INT4, BIGINT/INT8, NUMERIC/DECIMAL[(p[,s])],
REAL/FLOAT4, DOUBLE PRECISION/FLOAT8/FLOAT[(p)], BOOLEAN/BOOL, TEXT, NAME, OID,
DATE, TIMESTAMP[(p)] [WITH|WITHOUT TIME ZONE], TIMESTAMPTZ[(p)], INTERVAL, JSON
or JSONB types, with NOT NULL and one single-column PRIMARY KEY. The primary
key is also non-null. Omitted INSERT columns take their DEFAULT (NULL without
one).

### DML, defaults, identity and sequences (Q09/Q10, design §4.11, §5.10-§5.13)

RETURNING rows are the statement's write slice in order (new versions for
INSERT/UPDATE, deleted versions for DELETE), evaluated into the statement
workspace after the statement succeeds, so a statement parked on a lock and
resumed emits every row exactly once and a failure returns none. A resumed
multi-row INSERT continues after the source rows it already handled
(`Tx.progress`). Column DEFAULT expressions are stored as source text
(change-record `create_table` carries the default kind and text) and bound per
statement against that text; identity columns own a sequence (`<t>_<c>_seq`,
relkind S, dropped with the table); stored generated columns are recomputed
after every other column on insert and update. Errors: `GeneratedAlways`
(428C9), `SequenceLimit` (2200H), `SequenceNotReady` (55000),
`WrongObjectType` (42809), `DependentObjects` (2BP01), `UndefinedObject`
(42704).

ON CONFLICT checks the proposed key against the newest committed or own
version (`dml.keyCheck`, not the statement snapshot): an in-progress inserter
or deleter parks the statement and the row is retried on resume; a row this
statement already wrote is `CardinalityViolation` (21000) for DO UPDATE; DO
UPDATE locks the row (EvalPlanQual `target`) and evaluates SET/WHERE with the
existing row as relation 0 and EXCLUDED as relation 1.

Sequences (`sql/sequence.sig`, `Config.sequences` slots) are
non-transactional and follow PostgreSQL's nextval with CACHE 1 and
SEQ_LOG_VALS = 32: a nextval that exhausts its log count records a log-ahead
value that rides on the transaction's change record (op 9); an aborted
transaction's value is carried (`Database.seq_carried`) into the next record
any transaction writes, and `readOnly()` is false while a transaction has its
own or the database has carried sequence values. Ops 7/8 create and drop
sequences. currval/lastval state is per session (`SequenceSession`, set by
the caller; Store.Connection owns one). The value hook
(`value.Session.sequences`) also serves regclass lookups.

### System views (P01, design §4.10)

`catalog.sig` defines the views (`pg_type`, `pg_namespace`, `pg_class`,
`pg_attribute`, `pg_index`, `pg_attrdef`, `pg_sequence`, and
`information_schema.schemata/tables/columns/table_constraints/key_column_usage`)
as virtual FROM items: the executor asks the Database for their rows at scan
time (`Exec.Work.views`), computed from cat_relations visible to the
statement snapshot, the table definitions, the sequence slots and the static
type table, so they change after every committed or own DDL. A primary key's
index takes the OID after its table's (`<table>_pkey`). DEFAULT and generation
expressions are shown through `deparse.sig`. regclass/regtype casts are OID
values tagged for `::text` output. "char", regproc, int2vector, character_data
and yes_or_no columns are TEXT.

### Value types (Q02/Q03/Q04)

Cells are a tagged union (`types.sig`) with inline storage bounded by
`Config.text_bytes`: integers (int2/int4/int8/oid), booleans, text
(text/name/json), float4, float8, NUMERIC (`numeric.sig`: coefficient below
10^`Config.numeric_digits` (default 64, at most 76) and display scale at most
120; more is `NumericCapacity`, 54000), DATE (i32 days), TIMESTAMP/TIMESTAMPTZ
(i64 microseconds since 2000-01-01, TIMESTAMPTZ in UTC), INTERVAL (months,
days, microseconds) and JSONB (canonical binary, `jsonb.sig`). Typmods are
stored per column (`Column.typmod`, `Result.column_typmods`, PostgreSQL's
encoding) and carried by kind-3 create_table records; every new value type has
a change-record encoding that replay validates against the column type OID
(JSONB bytes are structurally checked). `value.sig` holds text I/O, casts in
the implicit/assignment/explicit contexts and the operators:

- NUMERIC: numeric_in forms (`_` separators, exponents, NaN, [+-]Infinity),
  half-away-from-zero rounding, PostgreSQL 15+ typmods (precision 1..1000,
  scale -1000..1000, precision above `numeric_digits` is 54000 at DDL),
  `select_div_scale` for `/`, mod scale max(dscales), NaN sorting last and no
  negative zero; numeric-to-int casts round half away (22003 out of range,
  0A000 for NaN/Infinity).
- REAL/DOUBLE (`float_text.sig`): the float8in grammar measured on musl is
  checked before `std.fmt.parseFloat` (decimal, `0x..p` hex, Infinity/inf/NaN,
  trimmed whitespace; 22P02 otherwise, 22003 out of range); output is the
  shortest round-trip digits (`std.fmt.float.render`) laid out like float8out
  with extra_float_digits = 1; overflow/underflow 22003, `/ 0` 22012;
  float-to-int casts use rint; float-to-numeric uses 15 (float4: 6)
  significant digits as float8_numeric does.
- Promotion: int2 < int4 < int8 < numeric < float4 < float8, with float4 and a
  non-float operand promoting to float8; date < timestamp < timestamptz. The
  binder inserts implicit cast nodes so operators always see one type.
- Temporal (`temporal.sig`, `tzif.sig`): ISO 8601 input only (`T`/space,
  fractions rounded to microseconds, `Z`/`+-HH[[:]MM[[:]SS]]`, a zone name, BC),
  infinity/-infinity/epoch, PostgreSQL range limits (22008) and 22007 for bad
  text; DateStyle ISO and IntervalStyle postgres output; `+ -` for date/int,
  date/date, timestamp(tz)/interval (months and days in session local time for
  timestamptz), timestamp - timestamp with justify_hours, AT TIME ZONE,
  now()/CURRENT_TIMESTAMP/transaction_timestamp() (transaction start),
  statement_timestamp(), clock_timestamp(), CURRENT_DATE. Zones are UTC,
  fixed offsets, POSIX TZ strings or TZif v2+ bytes owned by the caller and
  decoded in place (footer rules after the last transition); local times in
  DST gaps take the offset before the transition and overlaps the offset
  after it (DetermineTimeZoneOffset). The session (`Database.session`,
  `value.Session`) supplies the zone, a zone-name resolver and the clocks;
  without a clock the time functions fail with `ClockUnavailable` (0A000).
- JSON keeps validated input verbatim; JSONB orders keys by (length, bytes),
  keeps the last duplicate, stores numbers as NUMERIC, nests at most
  `Config.json_depth` (64; deeper is 54001), validates `\u` escapes and
  surrogate pairs (`\u0000` is `UntranslatableCharacter`, 22P05) and prints
  with PostgreSQL spacing. Operators: `-> ->> #> #>> @> <@ ?` (a top-level
  scalar is a one-element pseudo array; `#>` takes a `'{a,b}'` literal), `=`
  and PostgreSQL's btree ordering, `jsonb_typeof`, `jsonb_array_length`, casts
  text/json/jsonb. Strings compare bytewise (the reference uses its collation).

The only std symbols `sql.sig` and `sql/*.sig` use are `std.fmt.parseFloat`
and `std.fmt.float.render` (both in `float_text.sig`).

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
`UndefinedParameter`. Integer literals beyond int8 and decimal/exponent
literals are NUMERIC (a decimal literal cast to a float type is parsed as a
float). Other functions (`pg_typeof` included), JSON (non-B) operators and
window functions are not supported.

### Queries (Q06/Q07/Q08, design §4.9)

Single-table SELECTs without grouping, DISTINCT, OFFSET, subqueries, CTEs or
set operations keep the direct scan path (and FOR UPDATE/SHARE). Everything
else is bound into statement-scoped plans (`Config.subqueries` query blocks,
`Config.relations` FROM items per block, `Config.ctes` CTEs per statement;
`StatementTooComplex` beyond) and executed in `Database.workspace`:

- FROM: tables, CTE names and derived tables `(SELECT ...) alias`, joined
  left-deep with INNER/LEFT/RIGHT/FULL [OUTER]/CROSS JOIN ... ON | USING
  (merged columns; FULL is COALESCE) and commas. Nested loops; an ON conjunct
  `inner.pk = expression over earlier items` of an INNER/LEFT join probes the
  primary-key index; RIGHT/FULL track matched inner rows in the workspace.
  Unqualified names must be unique across a block's items
  (`AmbiguousColumn`, 42702); an unknown qualifier is `TableNotFound` (42P01).
- Subqueries: scalar (`CardinalityViolation`, 21000, for more than one row),
  [NOT] IN (SQL NULL semantics) and [NOT] EXISTS, correlated (re-run per
  outer row, scratch released afterwards) or not (run once per statement).
- Grouping: GROUP BY keys (expressions, positions, output aliases when no
  input column has the name) are evaluated once per row, merge-sorted and
  grouped by runs of equal keys (NULLs equal). COUNT(*), COUNT, SUM, AVG, MIN,
  MAX, BOOL_AND/EVERY, BOOL_OR with DISTINCT (sort-based) and FILTER (WHERE);
  HAVING. Result types: COUNT int8, SUM(int2/int4) int8, SUM(int8)/SUM(numeric)
  and AVG of integers/numeric NUMERIC (numeric_div scale), SUM(float4) float4,
  AVG(float) float8 with float8_accum's overflow check (22003). Empty input
  gives COUNT 0 and NULL otherwise; no GROUP BY means exactly one group.
  Ungrouped columns and misplaced or nested aggregates are `GroupingError`
  (42803). AVG(interval) is not provided.
- DISTINCT / DISTINCT ON are sort-based (NULLs equal); ORDER BY items outside
  the select list of a SELECT DISTINCT, or DISTINCT ON items that are not the
  leading ORDER BY items, are `InvalidColumnReference` (42P10). OFFSET,
  LIMIT ALL/NULL and FETCH FIRST|NEXT [n] ROW|ROWS ONLY; negative counts are
  `InvalidRowCountInLimit` (2201W) / `InvalidRowCountInResultOffset` (2201X).
- WITH [RECURSIVE] CTEs are materialized once per statement; a recursive CTE
  (`non-recursive UNION [ALL] recursive`) iterates over the previous step's
  rows until a step adds none (UNION drops rows already produced). UNION,
  INTERSECT and EXCEPT [ALL] use stable sorting and run multiplicities; their
  ORDER BY names result columns only (expressions are `UnsupportedStatement`).
- Workspace: `Config.work_rows` (0 = rows_per_table) x 2 x columns cells and
  proportional index arrays. Scratch grows from the bottom; materialized CTEs
  and uncorrelated subquery results are copied to the top for the statement.
  Exhaustion (for example a non-terminating WITH RECURSIVE or a large cross
  join) is `WorkspaceCapacity` (54000) before the result is written.
  `Result.rows` holds `Config.result_rows` (0 = rows_per_table) rows
  (`RowCapacity` beyond).

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
`InvalidEscapeSequence`, `UndefinedParameter`, `InvalidColumnReference`,
`NumericValueOutOfRange`, `NumericCapacity`, `InvalidParameterValue`,
`InvalidDatetimeFormat`, `DatetimeFieldOverflow`, `UntranslatableCharacter`,
`ClockUnavailable`, `WorkspaceCapacity`, `GroupingError`, `AmbiguousColumn`,
`CardinalityViolation`, `InvalidRowCountInLimit`,
`InvalidRowCountInResultOffset`, `GeneratedAlways`, `SequenceLimit`,
`SequenceNotReady`, `WrongObjectType`, `DependentObjects`, `UndefinedObject`
and the
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

Window functions, LATERAL and NATURAL joins, data-modifying CTEs, secondary
indexes, arrays, zone abbreviations, non-ISO
DateStyle and other IntervalStyles, functions beyond those listed above, and
complete SQL-standard or PostgreSQL conformance remain unimplemented. The reusable shared transaction adapter and wire sessions are
documented in [database-server.md](database-server.md).
## Validation

Run `sig build test-sql --summary all` with Sig 0.6.3. The target compiles and
executes `tests/test_sql.sig`, `test_sql_index.sig`, `test_sql_storage.sig`,
`test_sql_change_log.sig`, `test_sql_expr.sig`, `test_sql_mvcc.sig`,
`test_sql_types.sig` (value types, zones, JSONB and typed change-record round
trips), `test_sql_query.sig`, `test_sql_dml.sig` (RETURNING, defaults,
identity, sequences, upsert, durability of sequence values) and
`test_sql_catalog.sig` (system views), emitting assertion, statement, and fuzz
counts.
It is also included in `sig build test`. The executable's `--prove-failure`
option deliberately returns nonzero, including release modes. Contracts cover
operations, ownership, fail-atomic constraints, capacity exhaustion/reuse,
integer limits, malformed syntax, NULL semantics, deterministic fuzz inputs,
expression precedence, truth tables, SQLSTATE classes and failure-after-many-rows
atomicity.
