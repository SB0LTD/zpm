# Allocator-free in-memory SQL

`src/core/sql.sig` is the reusable Layer 0 `@zpm/sql` package. It has no imports,
system libraries, platform dependencies, or allocator parameters. The RAMSQL
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
are 4, 8, 128, 32, 128, and 8 respectively. All schema, rows, and text live inline
in `DB`. `DB.storageBytes()` equals `@sizeOf(DB)`. Results have separate caller
storage, measured by `@sizeOf(DB.Result)`; choose stack or static storage for the
profile's size. `tableCount()` returns the number of live tables.

`execute(source, &result)` accepts one statement and copies input names and
text. Successful SELECT copies headers/rows into result, without borrowing
database memory. Mutation results expose `affected_rows`; CREATE/DROP report 0.
Every error leaves the database and previous result unchanged. The caller
serializes access. There is no locking or transaction manager.

`Result` contains `column_count`, `row_count`, `affected_rows`,
`column_names[config.columns]`, and `rows[config.rows_per_table]`. Each row has
`cells[config.columns]`; `Cell` is a tagged union of `.null_value`,
`.integer: i64`, `.boolean: bool`, and `.text: Text`. `Name.slice()` and
`Text.slice()` borrow their owning value. Do not retain such a slice after
moving or overwriting that owner.

## SQL subset

CREATE/DROP TABLE; single-row INSERT with optional column mapping; SELECT
projection or `*`; UPDATE literal assignments; DELETE. Columns have INTEGER/INT,
BOOLEAN/BOOL, or TEXT types, with NOT NULL and one single-column PRIMARY KEY.
The primary key is also non-null. Omitted INSERT columns become NULL.

WHERE accepts `=`, `!=`, `<>`, `<`, `<=`, `>`, `>=`, `IS NULL`, `IS NOT NULL`,
and bounded AND conjunctions. No implicit type conversion occurs, including
predicates on empty tables. Ordinary comparisons involving NULL do not match.
One ORDER BY column with ASC/DESC is supported, followed by LIMIT. Ordering is
stable, with NULL first ascending and last descending. Text compares bytewise.

Keywords and unquoted ASCII identifiers are case insensitive. Strings use
apostrophes, escaped by doubling them; integer literals are signed 64-bit.
Optional final semicolon, whitespace, and `--` comments are accepted.
Identifiers and text have explicit byte capacities. SQL text is never executed
as a batch, and unsupported trailing clauses are rejected before mutation.

Errors include `Syntax`, `UnsupportedStatement`, `TableCapacity`,
`ColumnCapacity`, `RowCapacity`, `NameCapacity`, `TextCapacity`,
`PredicateCapacity`, `TableExists`, `TableNotFound`, `ColumnNotFound`,
`DuplicateColumn`, `TypeMismatch`, `NotNullViolation`, `PrimaryKeyViolation`,
and `IntegerOverflow`.

Primary keys use a fixed open-addressing hash index with a maximum 50% load.
Equality lookups and duplicate detection use that index. Delete compaction and
key-changing updates rebuild references after validation. LIMIT without ordering
stops scanning once enough rows match. Result clearing changes only active
counts; callers must observe the active ranges. Column types are reported even
when a SELECT returns zero rows. `Config.boolean_integers` optionally accepts
integer 0/1 as boolean client values; the default remains strictly typed.

Other predicates scan rows and ordering uses bounded insertion sorting. Joins,
general expressions, aggregates, secondary indexes, persistence, and complete
SQL-standard conformance remain unimplemented. The reusable shared transaction
adapter and wire sessions are documented in [database-server.md](database-server.md).

## Validation

Run `sig build test-sql --summary all` with Sig 0.6.3. The target compiles and
executes `tests/test_sql.sig`, emitting assertion, statement, and fuzz counts.
It is also included in `sig build test`. The executable's `--prove-failure`
option deliberately returns nonzero, including release modes. Contracts cover
operations, ownership, fail-atomic constraints, capacity exhaustion/reuse,
integer limits, malformed syntax, NULL semantics, and deterministic fuzz inputs.
