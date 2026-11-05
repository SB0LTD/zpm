# SQL routines, triggers and rules (conformance lane B11, wave 3)

Branch `b11/routines` closes the four routine smoke programs of the
118-program inventory test-first: PG.ROUTINE.FUNCTION,
PG.ROUTINE.PROCEDURE, PG.ROUTINE.TRIGGER and PG.ROUTINE.RULE. On main
f505a80 the unchanged driver moves from 79 smoke passes to 83; it still
exits 1 (SqlConformanceIncomplete) and no other program changed. A smoke
pass is not family closure.

`contract-sql-routines` (tests/test_sql_routines.sig, 663 assertions, 125
replayed records) covers each program with values and PostgreSQL text
output, column names and type OIDs, command tags, exact errors with an
untouched database afterwards (atomicity), two-transaction schedules, work
budgets and cancellation, capacities and replay: every committed record is
applied to a replica that must answer every probe like the primary,
including the replayed triggers and rules firing on new statements. Only the
four oracle programs from `postgres18_oracle.json` are native-verified;
every other expectation follows the PostgreSQL 18 documentation and source
and is pending native verification.

## Design

Code: `src/core/sql/routine_catalog.sig` (object slots, MVCC stamps, change
records, replay validation) and `src/core/sql/routine.sig` (statement
parser and the PL/pgSQL interpreter); the Database executes them in
`src/core/sql.sig` (section "routines, triggers and rules").

- **Catalog objects.** Functions/procedures, triggers and rules are their
  own fixed slot arrays (`Config.routines`, `Config.triggers`,
  `Config.rules`). Each slot is one version with the MVCC stamps of a row
  version: created/deleted by a transaction and command id, published by
  the commit's csn, undone at abort. `CREATE OR REPLACE` marks the visible
  version deleted and writes a new version with the same OID (as ALTER
  TABLE does). A concurrent CREATE or DROP of the same object waits for the
  other transaction. OIDs come from the shared OID counter.
- **Statements** are recognized by their leading words before the SQL
  parser runs (`Routines.classify`) and parsed by `routine.sig`; they run
  as one statement subtransaction like any other statement.
- **SQL functions** called in expressions are bound by name and argument
  types (exact types count most, an untyped literal prefers a text
  parameter, ties are 42725) into a `routine` call node; the session's
  routine hook runs the body when the call is evaluated: every argument is
  evaluated once, STRICT returns NULL for a NULL argument, and the body's
  expression is parsed, bound with the parameters as variables and
  evaluated at the top of the statement's node pool, which is restored
  afterwards. Parameters are referenced by name, `function.name` or `$n`.
- **PL/pgSQL** runs straight from the body text: one recursive-descent walk
  either checks (CREATE FUNCTION, DO), runs or skips each statement, and
  every expression goes through the same parse/bind/evaluate path with the
  frame's variables (parameters, DECLAREd variables, FOUND, loop variables,
  NEW/OLD, TG_*). Variables live in a fixed frame on the caller's stack
  (`Config.routine_variables`). Every statement and loop iteration is a
  work-control checkpoint.
- **Procedures and DO.** CALL resolves the procedure like a function call
  (42809 when only a function matches). The statements of a SQL procedure
  body, and the SQL statements of a PL/pgSQL procedure or DO block, run one
  after another as statements of their own: each takes a new command id and
  snapshot (READ COMMITTED), sees the earlier statements' writes, and binds
  routine variables (PL/pgSQL: a name that is both a variable and a column
  is 42702). `SELECT ... INTO [STRICT]`, `... RETURNING ... INTO`,
  `GET DIAGNOSTICS ROW_COUNT`, FOUND and nested CALL / DO are supported. An
  EXCEPTION block rolls back the writes made inside it (write-set and lock
  watermark). A statement that must wait for a lock undoes the routine's
  writes and parks the CALL / DO statement; the re-delivered statement runs
  the routine again from its start, so every effect happens exactly once.
- **Triggers.** BEFORE ROW triggers run inside the INSERT / UPDATE / DELETE
  (and MERGE, ON CONFLICT DO UPDATE) row paths after defaults and SET
  values and before NOT NULL, stored generated columns and CHECK
  constraints (PostgreSQL's order); NEW changes in place, RETURN NULL skips
  the row, RETURN OLD keeps the old row. AFTER ROW triggers fire at the end
  of the statement over the statement's own slice of the write set, in
  write order (PostgreSQL's after-trigger queue), so a statement that parks
  and resumes fires each exactly once. Statement triggers fire before and
  after the statement (also with no qualifying row, and for TRUNCATE).
  Triggers of one kind fire in name order; triggers of a partitioned table
  fire for rows of its partitions. WHEN conditions and UPDATE OF columns
  are honored. CREATE / DROP TRIGGER take AccessExclusive on the table
  (PostgreSQL's CREATE TRIGGER takes ShareRowExclusive, which readers do
  not wait for; this engine has no such mode).
- **Rules.** `CREATE [OR REPLACE] RULE ... ON INSERT | UPDATE | DELETE TO t
  [WHERE cond] DO [ALSO | INSTEAD] NOTHING`. An unconditional INSTEAD rule
  turns the statement into nothing (after its table lock); a conditional
  one skips the rows whose qualification is TRUE (PostgreSQL adds
  `qual IS NOT TRUE`); ALSO NOTHING changes nothing. RETURNING with an
  INSTEAD rule, MERGE, ON CONFLICT and data-modifying WITH on a table with
  rules are 0A000, as in PostgreSQL.
- **Dependencies.** DROP TABLE drops the table's triggers and rules (their
  drops are recorded first); DROP FUNCTION of a trigger function is 2BP01
  unless CASCADE drops the triggers.
- **Recursion.** Routine calls and trigger firings nest up to
  `Config.routine_depth`; deeper is 54001. Inside an expression or a
  trigger, a routine cannot run SQL statements of its own (0A000).

## Catalogs

`pg_proc` (oid, proname, pronamespace, prokind, prolang as the language
name, provolatile, proisstrict, pronargs, prorettype, proargtypes as text,
prosrc), `pg_trigger` (oid, tgrelid, tgname, tgfoid, tgtype with
PostgreSQL's bits, tgenabled, tgisinternal, tgnargs), `pg_rewrite` (oid,
rulename, ev_class, ev_type, ev_enabled, is_instead) and `pg_rules`
(schemaname, tablename, rulename, definition in pg_get_ruledef's layout).

## Durability

Change-record ops (each `tag u8, payload_len u32, payload`, decoded and
validated by routine_catalog.sig): 60 create_routine, 61 drop_routine, 62
create_trigger, 63 drop_trigger, 64 create_rule, 65 drop_rule; 66-69 stay
reserved. Payload layouts are in routine_catalog.sig's header. Existing
records and the table definition format are unchanged (no definition
version bump). Replay validates every op against an overlay (names, OIDs,
referenced tables and functions, capacities; InvalidChangeRecord for bad
bytes, ChangeRecordConflict for conflicts) before applying anything.

## Limits (Config, each with a default)

| Constant | Default | Beyond |
|---|---|---|
| `routines` | 8 | 54000 (TableCapacity) |
| `triggers` | 8 | 54000 (TableCapacity) |
| `rules` | 4 | 54000 (TableCapacity) |
| `routine_args` | 8 | 54000 (ColumnCapacity) |
| `routine_bytes` | 1024 (body, WHEN, rule qualification) | 54000 (TextCapacity) |
| `routine_depth` | 16 | 54001 (StackDepthExceeded) |
| `routine_variables` | 24 | 54000 (ColumnCapacity) |

A replaced or dropped version keeps its slot until the reclamation horizon
passes it, so OR REPLACE needs a free slot.

## Errors (SQLSTATE)

New: 42723 (DuplicateFunction), 42P13 (InvalidFunctionDefinition), P0001
(RaiseException; ASSERT failures are reported as P0001, PostgreSQL P0004),
P0002 (NoDataFound), P0003 (TooManyRows), 2F005 (FunctionExecutedNoReturn),
20000 (CaseNotFound), 54001 (StackDepthExceeded), 22004
(NullValueNotAllowed), 22005 (ErrorInAssignment). Also used: 42883, 42725,
42809, 42P17, 42710, 42704, 42601, 42703, 42702, 2BP01, 0A000, 23502,
23505, 22012, 22P02, 54000, 57014, 55P03.

## Not covered (open)

- INSTEAD OF triggers (views stay read-only; CREATE TRIGGER ... INSTEAD OF
  is 0A000) and rule actions other than NOTHING (query rewriting) - both
  need statements running inside a data-modifying statement.
- SQL statements inside functions called from expressions and inside
  trigger functions (0A000); SQL function bodies other than one SELECT of
  one expression without FROM are 0A000 when called from an expression
  (they are validated at CREATE; the same statements run in SQL
  procedures).
- OUT / INOUT / VARIADIC parameters, DEFAULT arguments, named arguments,
  RETURNS SETOF / TABLE / record, RETURN NEXT / QUERY, polymorphic types,
  %TYPE / %ROWTYPE / record variables, cursors, FOREACH, FOR over queries,
  dynamic EXECUTE, schema-qualified routine names, SECURITY DEFINER, SET.
- Transaction control (COMMIT / ROLLBACK) inside procedures and DO blocks
  is 0A000 (PostgreSQL allows it outside a transaction block).
- TG_ARGV (TG_NARGS is provided); REFERENCING transition tables;
  constraint triggers; referential actions and COPY FROM do not fire user
  triggers (AFTER ROW triggers do see rows a referential action wrote).
- RAISE messages are not delivered to the client (no notice channel);
  RAISE / USING ERRCODE accept the conditions of the handler table only.
- pg_rules shows a WHERE qualification as written, where PostgreSQL
  deparses it (`(old.id < 3)`); overload resolution is a simplified form
  of PostgreSQL's (exact > implicit, untyped literal prefers text).
- A recursive SQL function cannot be created (its own body does not bind
  yet, as in PostgreSQL); recursion goes through PL/pgSQL.
- User functions are 0A000 in detached reads (ReadContext).
- Statement-level triggers of data-modifying WITH entries do not fire;
  BEFORE STATEMENT triggers fire again when a parked statement resumes.

Pending native verification: everything in the contract beyond the four
oracle programs, in particular the error codes of definition checks,
pg_proc / pg_trigger / pg_rewrite / pg_rules contents, the AFTER-trigger
and statement-trigger timing, rule qualification semantics and the
CALL/DO restart on a lock wait.
