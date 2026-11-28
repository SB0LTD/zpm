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
  trigger, a routine's SQL statements run as nested statements (wave 4,
  docs/SQL_NESTED_STATEMENTS.md).

## Catalogs

User-defined functions/procedures support EXECUTE grants with grant options,
owner-rooted delegation, RESTRICT/CASCADE, PUBLIC, inherited roles, function and
grantee lists, and GRANTED BY naming the current SQL user. ON ROUTINE accepts
mixed function/procedure targets. CREATE accepts unqualified or public-qualified
names, as do CALL, DROP and expression calls. An explicit public qualifier
resolves user routines before built-in name classification. Empty search paths
do not implicitly search public; explicit qualifiers still work. Other
namespaces and ALL ROUTINES IN SCHEMA remain
open. CREATE/DROP and privilege changes return 25006 in read-only transactions;
read-only CALL/DO remain available.

ALTER DEFAULT PRIVILEGES ON FUNCTIONS/ROUTINES supports global and IN SCHEMA
EXECUTE grants, PUBLIC, grant options and FOR ROLE/USER lists for future routines.
Defaults are taken from the actual creator, with committed catalog visibility
and the creator's own prior changes. Existing objects and OR REPLACE keep their
ACL. Schema defaults add to global grants/options and merge duplicate grantees;
schema REVOKE cannot remove global privileges. Namespace deletion removes its
templates. RSBASE09 preserves scoped defaults and validates schema references.
Other routine namespaces and default-privilege object classes remain open. The
TDD checkpoint records qualification and remaining privilege-family scope.

RSBASE10 compact images preserve supported public routines, delegated ACLs,
triggers and DO NOTHING rules, including subsequent owner/body/ACL WAL changes.
ALTER FUNCTION/PROCEDURE OWNER retains OIDs and transfers ACL owner endpoints.
Stock PG16/18 archives preserve these objects both ways; typed default ACLs and
definition output use caller-owned memory for long names/text. Other catalog
image classes and arbitrary rule actions remain
open. See the TDD checkpoint for exact qualification evidence.

`pg_proc.proacl` is a typed ACL array rendered in grant-dependency order, using
caller-owned value storage for ACLs larger than an inline cell. Every edge retains
its grantor, grantee and grant option. The shared `privilege_graph.sig` supplies
support propagation, cycle checks and topological rendering without allocation.

`pg_proc` (oid, proname, pronamespace, prokind, prolang as the language
name, provolatile, proisstrict, pronargs, prorettype, proargtypes as text,
prosrc), `pg_trigger` (oid, tgrelid, tgname, tgfoid, tgtype with
PostgreSQL's bits, tgenabled, tgisinternal, tgnargs, tgparentid), `pg_rewrite` (oid,
rulename, ev_class, ev_type, ev_enabled, is_instead) and `pg_rules`
(schemaname, tablename, rulename, definition in pg_get_ruledef's layout).

`pg_get_ruledef` also renders the implicit `_RETURN` rules exposed by `pg_rewrite`
for supported views and materialized views. Their actual SELECT is rendered using
the view-definition writer, preserving declared column aliases and qualifying
dependencies. The target respects pretty mode and `quote_all_identifiers`.
Caller-owned value storage handles definitions wider than an inline text cell;
exhausted storage returns an error without truncation. `pg_rules` excludes these
implicit rules. Formatting can differ from native PostgreSQL; executing the SELECT
action must retain the view's rows, column names and type OIDs. Stock PG16/18
qualification passes both directions in
[CI 46033230142](https://github.com/SB0LTD/ramsql/actions/runs/46033230142).
Debug/ReleaseSafe routine contracts also pass on the 4 MiB Linux CI stack in
[ZPM CI 46036894578](https://github.com/SB0LTD/zpm/actions/runs/46036894578).

`pg_get_triggerdef(oid [, pretty])` renders the stored trigger version visible
to the statement, including decoded arguments and UPDATE OF column names.
The default qualifies the target table schema. Pretty output elides it when
the relation is visible through the supported catalog path. WHEN expressions
retain their stored SQL spelling. Each supported trigger is user-created and
enabled in origin mode, so its metadata reports `O`, `false` and a zero
parent OID. Partition trigger dispatch reuses the stored parent trigger.

## Durability

Change-record ops (each `tag u8, payload_len u32, payload`, decoded and
validated by routine_catalog.sig): 60 create_routine, 61 drop_routine, 62
create_trigger, 63 drop_trigger, 64 create_rule, 65 drop_rule; 66-69 stay
reserved. Payload layouts are in routine_catalog.sig's header. Existing
records and the table definition format are unchanged (no definition
version bump). Replay validates every op against an overlay (names, OIDs,
referenced tables and functions, capacities; InvalidChangeRecord for bad
bytes, ChangeRecordConflict for conflicts) before applying anything.

The optional routine ACL payload retains the old flags/count/grantee encoding
for owner-issued ordinary grants. Flag 0x80 selects extended entries (grantee
u32, grantor u32, option u8); flag 0x04 retains an explicit owner grant option.
Older records remain readable. Replay rejects disconnected grant chains and
invalid roles/options before changing the live catalog.

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
| `routine_acl_entries` | 16 grantor/grantee pairs, plus owner/PUBLIC markers | 54000 (ProgramLimitExceeded) |

A replaced or dropped version keeps its slot until the reclamation horizon
passes it, so OR REPLACE needs a free slot.

## Errors (SQLSTATE)

New: 42723 (DuplicateFunction), 42P13 (InvalidFunctionDefinition), P0001
(RaiseException), P0004 (AssertFailure, wave 4), 0Z002
(StackedDiagnosticsAccessedWithoutActiveHandler, wave 4), 2D000
(InvalidTransactionTermination, wave 4),
P0002 (NoDataFound), P0003 (TooManyRows), 2F005 (FunctionExecutedNoReturn),
20000 (CaseNotFound), 54001 (StackDepthExceeded), 22004
(NullValueNotAllowed), 22005 (ErrorInAssignment). Also used: 42883, 42725,
42809, 42P17, 42710, 42704, 42601, 42703, 42702, 2BP01, 0A000, 23502,
23505, 22012, 22P02, 54000, 57014, 55P03.

## Wave 4: signatures, sets, SQL bodies (routines-sig lane)

`contract-sql-routines-sig` (tests/test_sql_routines_sig.sig) covers this
section with values, column names and type OIDs, exact errors, atomicity
and replay; every expectation was checked against native PostgreSQL 18.7.

- **Schemas.** CREATE FUNCTION / PROCEDURE in any schema (3F000 when it
  is missing; a user schema needs CREATE on it), qualified calls, CALL,
  DROP with or without a signature (IF EXISTS on a missing schema is a
  no-op; 42725 for an ambiguous name), trigger functions and regproc
  lookup. Unqualified names search the search path in order (`"$user"`,
  public); a routine with the same input types in an earlier schema hides
  later ones, and unqualified CREATE uses the first existing schema.
  pg_catalog's place in the path counts since wave 5 (below). DROP SCHEMA RESTRICT keeps routines (2BP01); CASCADE drops
  them (and their triggers) before the schema. SET search_path itself
  accepts only `$user`, public, pg_catalog and pg_temp (session lane), so
  paths over other schemas cannot be set yet.
- **Parameters.** IN, OUT, INOUT and VARIADIC modes, DEFAULT values and
  named notation (`name => v`, `name := v`). Matching follows PostgreSQL:
  positional then named arguments (a positional one after a named one,
  or a repeated name, is 42601), VARIADIC expansion of trailing arguments
  (named notation reaches a variadic routine only with VARIADIC), DEFAULTs
  for unfilled inputs, 42725 when candidates tie, and a candidate without
  variadic expansion preferred. The 42P13 rules (unique input names and
  output names, VARIADIC last and an array, DEFAULT only on inputs and on
  every later input, a result type matching the OUT parameters) and the
  OR REPLACE rules (result columns, input names and existing defaults
  stay) hold. DEFAULT expressions are analyzed at CREATE (no column 42703,
  subquery 0A000 or aggregate 42803; assignment to the parameter type,
  42804; constants evaluated, so 22P02 shows at CREATE) and evaluated in
  the caller's context per call. One OUT parameter is the function value.
  CALL fills OUT parameters with placeholders and returns the outputs as
  a row; a CALL inside a routine assigns them to the caller's variables
  (42601 when an argument is not a variable). Built-in functions accept no
  named arguments here (42883).
- **Sets.** RETURNS SETOF / TABLE and routines with several OUT parameters
  are table functions in FROM, with column alias lists, WITH ORDINALITY
  and LATERAL arguments; result columns are named after the OUT / TABLE
  parameters (else the function or the alias). PL/pgSQL adds rows with
  RETURN NEXT (42804 in a non-set function or with an expression beside
  OUT parameters; 42601 without either). A STRICT set function with a
  NULL argument returns no row.
- **SQL bodies.** A body that is one read-only query (SELECT ... FROM,
  WITH, VALUES, a subquery) is appended to the statement like a view and
  bound as a correlated plan over the arguments' frame: in FROM it gives
  the rows, in an expression its first row (NULL for none), converted to
  the result type. Its tables are checked with the caller's privileges.
  `RETURN expression` and `BEGIN ATOMIC ... END` bodies are accepted (and
  imply LANGUAGE SQL; prosrc shows the kept text where PostgreSQL has an
  empty prosrc). SECURITY DEFINER and SET routines are not inlined.
- **SECURITY DEFINER and SET.** A SECURITY DEFINER routine (function,
  procedure or trigger function) runs as its owner: current_user and
  every privilege check inside it. SET clauses hold for the call and are
  undone afterwards together with any setting the routine changed; an
  unknown setting is 42704 and a bad value 22023 at CREATE; settings the
  store implements, SET ROLE and transaction modes are 0A000. pg_proc
  reports prosecdef, proretset and prorows; proconfig since wave 5.
- **Diagnostics.** SQLSTATE and SQLERRM inside handlers, GET STACKED
  DIAGNOSTICS (RETURNED_SQLSTATE, MESSAGE_TEXT, PG_EXCEPTION_DETAIL,
  PG_EXCEPTION_HINT, COLUMN_NAME, CONSTRAINT_NAME, PG_DATATYPE_NAME,
  TABLE_NAME, SCHEMA_NAME; 0Z002 outside a handler), RAISE message
  formatting and its USING options, condition classes (`data_exception`
  or SQLSTATE '22000' catch class 22), and ASSERT as assert_failure
  (P0004), which OTHERS does not catch. SQLERRM is PostgreSQL's text for
  RAISE, ASSERT and conditions with a fixed message; other engine errors
  report the engine's diagnostic text. PG_EXCEPTION_CONTEXT, PG_CONTEXT
  and PG_ROUTINE_OID: wave 5 (below).
- **Transaction control.** COMMIT / ROLLBACK [AND [NO] CHAIN] in PL/pgSQL
  procedures and DO blocks are accepted at CREATE and fail with 2D000
  where PostgreSQL forbids them (an explicit transaction block, a function
  or trigger below, a block with an EXCEPTION clause, a SECURITY DEFINER or
  SET routine on the stack). Where PostgreSQL allows them (a top-level
  CALL / DO run non-atomically) they end the transaction in the middle of
  the statement since B11 wave 5 (proc-tx lane, docs/SQL_PROC_TX.md): each
  COMMIT writes, syncs and publishes its own record through the store, and
  a lock wait after one fails with 55P03 instead of re-running the CALL.
  Callers without the store's transaction hook (Database.execute and
  executeChanges in autocommit) still get 0A000.

Change-log op 80 (create_routine_extended) carries routines with these
features: an extension (modes, OUT / TABLE parameter types, DEFAULT
texts, retset and SECURITY DEFINER flags, SET clauses) before the op-60
payload. Routines without them keep op 60 byte for byte; replay validates
every extension byte (modes against the inputs, VARIADIC arrays, result
types against the OUT parameters, NUL-terminated defaults and settings)
before applying it. RSBASE10 images refuse such routines before writing
(SnapshotUnsupportedState). Ops 81-84 stay reserved for this lane.


## Wave 5: schema statements, paths, context, transition tables (routines-trig lane)

`contract-sql-routines-trig` (tests/test_sql_routines_trig.sig, 449
assertions, 223 replayed records) covers this section with values in PostgreSQL text output, command tags, exact errors
(the SQLSTATE through the error name), atomicity after a failure and
replay: every committed record is applied to a replica that must answer
every probe like the primary. Expected values were checked against native
PostgreSQL 18.7.

- **SQL-schema statements in routines (T651, T653).** DDL runs inside SQL
  and PL/pgSQL functions called from expressions (as nested statements),
  in procedures and DO blocks, routine DDL (CREATE FUNCTION, TRIGGER,
  RULE ...) included; a STABLE or IMMUTABLE routine runs none (0A000).
  DROP / ALTER / TRUNCATE / CREATE INDEX of a table a suspended statement
  uses (its sources and its target) is 55006, PostgreSQL's
  CheckTableNotInUse. Void functions are values of the void type in
  expressions and FROM (NULL from a SQL body, an empty non-NULL value from
  PL/pgSQL, as in PostgreSQL). SQL bodies are analyzed past utility
  statements, as PostgreSQL 18 does: a later statement naming a table an
  earlier one would create is 42P01 at CREATE.
- **EXECUTE.** `EXECUTE command [INTO [STRICT] targets] [USING values]`
  (either clause first) and `RETURN QUERY EXECUTE ... USING`: the string's
  statements run as statements of the routine (nested inside a running
  statement) with the USING values as `$1..$n` and none of the routine's
  variables; INTO takes the last statement's first row (42601 for a
  command that returns no data), ROW_COUNT changes and FOUND does not; a
  NULL string is 22004; an untyped USING literal is text.
- **Assignment.** PL/pgSQL assignment, INTO targets and DECLARE defaults
  convert through the types' text forms when no assignment cast exists
  (exec_cast_value's I/O coercion): `r INT := '7'::text` works and
  `r INT := true` is 22P02.
- **Routine context.** `GET DIAGNOSTICS PG_CONTEXT` and `GET STACKED
  DIAGNOSTICS PG_EXCEPTION_CONTEXT` render PostgreSQL's error-context
  lines, innermost first: `PL/pgSQL function name(argument types) line N
  at STATEMENT` (schema-qualified when the path does not find it;
  `inline_code_block` for DO; `during statement block local variable
  initialization`), `SQL statement "..."` for statements run through SPI
  (SQL statements, PERFORM, EXECUTE, RETURN QUERY, CALL), `PL/pgSQL
  expression "..."` / `PL/pgSQL assignment "..."` for expressions that
  read tables or are constant (PostgreSQL folds those while planning),
  and `SQL function "f" statement N`. PG_EXCEPTION_CONTEXT is the context
  the caught error had where it was raised. `PG_ROUTINE_OID` is the
  routine's OID (0 in DO). A context longer than a text value is 54000.
- **proconfig and SET clauses.** pg_proc.proconfig lists the SET clauses
  as PostgreSQL stores them (`name=value`, a string's content, a search
  path's items as quoted identifiers joined by `, `). `SET name FROM
  CURRENT` stores the session's value at CREATE, and custom
  `prefix.name` settings are accepted.
- **SQL paths (S071).** A domain resolves through search_path anywhere in
  a query, and pg_typeof reports it; regtype output names user types
  (schema-qualified when the path does not find them), also on the wire.
  pg_catalog listed after a schema lets that schema's function with a
  built-in's input types hide the built-in; a user function takes calls
  no built-in of its name accepts (`length(5)` with `public.length(int)`).
- **Set-returning functions in the select list.** One user set-returning
  call (RETURNS SETOF / TABLE of one column) may sit in a select-list
  target, which is evaluated per row it returns (PostgreSQL's
  ProjectSet); anywhere else it is 0A000.
- **RETURNS SETOF table.** The table's (or view's) columns become the
  routine's TABLE columns, as of CREATE (PostgreSQL keeps the row type;
  this catalog has no pg_type rows for tables, so prorettype is record or
  the single column's type). They are no PL/pgSQL variables (op-80 flag
  4). A missing relation is 42704.
- **External routines (T653).** No C library can be loaded here: CREATE
  FUNCTION ... LANGUAGE C (AS 'obj_file' [, 'link_symbol']) is 58P01,
  PostgreSQL's answer for a missing object file. Other unknown languages
  are 42704 as before.

Triggers:

- **Transition tables (T212).** `REFERENCING OLD TABLE AS o NEW TABLE AS
  n` on AFTER triggers: the statement's rows of the trigger's table (and
  its partitions), also none, read like relations by the trigger
  function's own statements and its EXECUTE (not by functions it calls),
  after CTE names and before relations. They cannot be modified (0A000).
  CREATE TRIGGER follows PostgreSQL's checks and order: views 42809, ROW
  triggers on partitions or inheritance children 0A000, non-AFTER 42P17,
  TRUNCATE 0A000, more than one event 0A000, column lists 0A000, ROW
  variables 0A000, OLD without DELETE / UPDATE and NEW without INSERT /
  UPDATE 42P17, a transition named twice or both with one name 42P17.
- **Constraint triggers.** `CREATE CONSTRAINT TRIGGER name AFTER events ON
  t [FROM r] [NOT] DEFERRABLE [INITIALLY IMMEDIATE | DEFERRED] FOR EACH ROW
  ...`. An immediate one fires like an AFTER ROW trigger. A deferred one's
  events fire at COMMIT and PREPARE TRANSACTION (an autocommit statement
  before it commits), or when SET CONSTRAINTS name /
  ALL IMMEDIATE makes it immediate, in write order with each row's
  triggers in name order; an error there rolls the transaction back. SET
  CONSTRAINTS on a NOT DEFERRABLE one is 42809. CREATE OR REPLACE
  CONSTRAINT TRIGGER is 0A000; BEFORE, FOR EACH STATEMENT, REFERENCING and
  NOT DEFERRABLE INITIALLY DEFERRED are 42601.
- **pg_trigger / pg_get_triggerdef.** pg_trigger gains tgconstrrelid,
  tgconstraint, tgdeferrable, tginitdeferred, tgoldtable and tgnewtable;
  pg_get_triggerdef renders CONSTRAINT, FROM, the deferral and REFERENCING
  in PostgreSQL's layout.
- **Referential actions fire the referencing table's triggers.** ON DELETE
  / UPDATE CASCADE, SET NULL and SET DEFAULT run as statements on the
  referencing table: its BEFORE STATEMENT triggers fire once per
  statement (also when no row references the key), BEFORE ROW triggers
  per row (NULL keeps the row; a row a trigger changed itself is 27000),
  and the action rows' AFTER ROW events and each action table's AFTER
  STATEMENT follow the statement's own AFTER ROW and AFTER STATEMENT
  events, in PostgreSQL's order.
- **COPY FROM fires triggers.** BEFORE STATEMENT at its start, BEFORE ROW
  per row after the defaults (NULL skips the row; NEW may fix it before
  NOT NULL, generated columns and CHECK), AFTER ROW and AFTER STATEMENT
  at its end. The triggers' SQL uses statement storage the caller gives
  with the COPY (Store.copyBeginWith; the PostgreSQL wire passes its
  result).

Durability: change-log op 120 (`create_trigger_extended`) carries a
trigger with transition tables or a constraint trigger: flags u8 (1 OLD
TABLE, 2 NEW TABLE, 4 constraint, 8 DEFERRABLE, 16 INITIALLY DEFERRED),
the transition names, for a constraint trigger its constraint OID and
FROM table OID, then the op-62 payload. Replay validates every byte
against PostgreSQL's rules and the overlay (live tables, unused OIDs).
Op 62 records stay byte-identical; catalog images (RSBASE) refuse op-120
triggers (0A000). Ops 121-124 stay reserved. Op 80 gains flag 4 (SETOF
a table's row type); records without it are unchanged. Nothing else
changed in the log: proconfig and FROM CURRENT live in op-80 SET texts.

New SQLSTATEs: none (55006 ObjectInUse, 58P01 UndefinedFile and 22004
were mapped). Used: 55006, 58P01, 22004, 42601, P0002, P0003, 42P02,
42703, 22P02, 22007, 54000, 42P17, 0A000, 42809, 42P01, P0001, 27000,
23514, 42883, 42704, 55P03.

Not covered (open):

- Record values, user casts and several set-returning calls in one select
  list: the composite lane (below) covers them; its section lists what
  stays open.
- Referential actions run while the parent rows change, so the
  referencing table's BEFORE triggers fire before the parent's AFTER ROW
  triggers; PostgreSQL runs the actions from its after-trigger queue,
  interleaved with the parent's AFTER ROW triggers. Multi-level cascades
  fire their AFTER events in write order.
- Constraint triggers have no pg_constraint row (contype 't'). An
  autocommit statement with RETURNING whose rows leave deferred
  constraint-trigger events is 0A000 (its rows wait in the workspace the
  trigger statements reuse); PostgreSQL returns them.
- A lock wait inside COPY's triggers is 55P03 (the COPY cannot park
  there); deferred constraint triggers left at a COMMIT without statement
  storage (a Store commit from copyEnd without copyBeginWith) are 0A000.
- PG_EXCEPTION_CONTEXT for errors PostgreSQL raises while planning (for
  example while inlining a SQL function) can differ.
- T323: SECURITY DEFINER / INVOKER work (wave 4);
  information_schema.routines (security_type) belongs to the catalog
  lane. LANGUAGE internal routines are 42704 (PostgreSQL maps them to
  its built-in C symbols).
- Rule actions stay as wave 4 left them (docs/SQL_NESTED_STATEMENTS.md):
  SELECT and NOTIFY actions and RETURNING in actions are 0A000 at CREATE
  RULE; ALSO or conditional INSTEAD rules on a view without INSTEAD OF
  triggers are 0A000 where PostgreSQL runs the automatic update beside an
  ALSO action and reports 55000 otherwise; an action runs once per row
  where PostgreSQL runs it once joined with all the original rows (an
  aggregating ALSO action over 3 inserted rows sums 3 times in
  PostgreSQL).

## Wave 5: composite values, user casts, ProjectSet (composite lane)

`contract-sql-composite` (tests/test_sql_composite.sig, 467 assertions,
55 replayed records) covers this section with values in PostgreSQL text
output, column names and type OIDs, exact errors (the SQLSTATE through the
error name), atomicity after a failure, replay (every committed record is
applied to a replica that must answer every probe like the primary) and
corrupted records that must fail closed. Expected values were checked
against native PostgreSQL 18.7.

- **Composite values (X014, F641).** A record is one cell
  (`src/core/sql/record.sig`): its type OID (a composite type, or 2249
  `record` for an anonymous record), then per field its built-in type,
  typmod and value; fields are never records. `ROW(...)` and `(a, b)` are
  values of type `record` (fields f1, f2, ...; an untyped field reads as
  text). A cast to a composite type works anywhere in an expression: a
  row constructor converts field by field (explicitly in a cast, by
  assignment for a column; a different count is 42846), an untyped literal
  is read by record_in (PostgreSQL's quoting; 22P02 for too few or too many
  columns or junk after the parenthesis), a string by I/O conversion, a
  record of the same type passes and an anonymous record is checked field
  by field when evaluated. `'...'::record` and an untyped side of a
  record comparison are 0A000 (input of anonymous composite types). Text
  output is record_out (`(1,"a b",)`), binary output record_send.
  `pg_typeof`, RowDescription and pg_attribute name the composite type:
  a result column of a composite type carries the type's OID as its
  nominal type with typmod -1 (an anonymous record is OID 2249).
- **Field selection.** `(x).field` (42809 when `x` is no record, 42703
  for a missing field; a field name may be any keyword), `(x).*` in a
  select list (one column per field), `variable.field` for composite
  routine parameters and PL/pgSQL variables. `(f()).*` evaluates `f`
  once per field, as PostgreSQL does.
- **Comparison.** Two row constructors (or a row constructor and a row
  subquery) compare row-wise with SQL NULL semantics; other record
  comparisons are record_eq / record_cmp: two NULL fields are equal and a
  NULL field sorts after every value. A row constructor beside a
  composite value, or two composite types, must have the same field types
  (42804); two composite types with them compare. `IS [NOT] NULL` tests
  every field. ORDER BY, GROUP BY, DISTINCT, `min` / `max`, CASE and
  COALESCE work on records; `to_json` and `row_to_json(record [,
  pretty])` render objects.
- **Composite columns.** `CREATE TABLE t (d doc)` stores records whose
  type is the column's. The column is `record` (type OID 2249) with the
  composite type's OID as its typmod in the definition encoding, so the
  table definition format is unchanged; pg_attribute reports the type's
  OID and typmod -1. Values are change-log value tag 57 (the record's type
  OID u32, a field count u8, then per field a built-in type OID u32, a
  typmod i32 and the value; never a record), validated on replay against
  the column type and every field's own checks. Replay also checks that a
  composite column's type is live and refuses to drop a type a live
  column, routine or cast uses. Domain and enum columns stay 0A000, a
  `record` column is 42P16 and an unknown type 42704. Base images
  (RSBASE) refuse composite columns.
- **Routines.** Composite parameters and results (pg_proc stores the
  type's OID); a SQL body may return a record or one column per field.
  A function with several OUT parameters is an anonymous record in an
  expression (`f()`, `(f()).a`, `(f()).*`). DROP TYPE of a type a
  column, routine or cast uses is 2BP01 (CASCADE is 0A000 here), also
  when another transaction is creating that dependent or committed it
  after the dropper's snapshot; a column, routine or cast naming a type
  another transaction is dropping is 40001 (PostgreSQL waits on the
  type's lock), so a dependent never outlives its type in the log.
- **PL/pgSQL variables.** `DECLARE p pt` and `DECLARE r record`;
  assignment, field assignment (a NULL composite becomes a row of NULLs),
  `SELECT ... INTO` a lone composite or record target from separate
  columns and RETURN of a composite. A record variable keeps the shape of
  the row it last took (Config.routine_records shapes per frame; 54000
  beyond); before its first row it is 55000.
- **User casts (S211).** `CREATE CAST (source AS target) {WITH FUNCTION
  f[(types)] | WITHOUT FUNCTION | WITH INOUT} [AS ASSIGNMENT | AS
  IMPLICIT]` and `DROP CAST [IF EXISTS] (source AS target) [CASCADE |
  RESTRICT]`, with CreateCast's checks: types exist (42704), are no
  pseudo-type (42809) and differ (42P17); the caller owns one of them
  (42501); no cast exists for the pair, built-in or user (42710); the
  function is a normal, non-set function of one to three arguments (the
  source type, int4, boolean) returning the target type (42P17); WITHOUT
  FUNCTION needs physically compatible built-in types (42P17; between
  different cell kinds 0A000 here). Casts are routine-catalog objects
  with MVCC versions (Config.casts) and pg_cast rows. Explicit,
  assignment and implicit coercion consult them before the built-in
  rules, as find_coercion_pathway does: WITH FUNCTION calls the function
  (passing the typmod and explicitness when it takes them), WITH INOUT
  converts through text and WITHOUT FUNCTION relabels; a cast of another
  context leaves no coercion path (no I/O fallback). DROP FUNCTION of a
  cast function is 2BP01 unless CASCADE drops the cast. regtype input
  resolves user type names.
- **ProjectSet.** Every set-returning call of a select list
  (generate_series, unnest, generate_subscripts, regexp_matches,
  regexp_split_to_table, jsonb_path_query, user set-returning routines),
  at the top of a target or inside an expression, runs once per input row
  (after aggregation in a grouped select list) and the calls are zipped as
  in PostgreSQL 10+: the longest decides the row count, exhausted calls
  yield NULL and a call with no rows contributes NULLs. Their values are
  chained in workspace cells (54000 when they do not fit). A call in
  WHERE, CASE, COALESCE or an aggregate's arguments is 0A000, as in
  PostgreSQL. `(f()).*` over a set-returning `f` runs it once for all
  its fields.
- **information_schema.** A composite column, routine result or
  parameter is `USER-DEFINED` with the type's schema and name as its
  udt (columns, routines, parameters); user_defined_types and attributes
  list composite types as native 18.7 does.
  `information_schema._pg_expandarray(anyarray)` is a select-list
  set-returning call returning the anonymous record (x, n): every element
  in storage order with its ordinal (PostgreSQL 18's unnest WITH
  ORDINALITY body; NULL yields nothing, an untyped literal is 42804).
  `(record).field` and `(record).*` follow a derived table's or CTE's
  anonymous record column to the target that computes it, as
  expandRecordVariable does, so pgjdbc's getPrimaryKeys shape
  `(result.KEYS).x` binds. pg_index.indkey is text here, not int2vector,
  so that query itself still needs the catalog's int2vector.

Durability: change-log ops 121 `create_cast` (payload: oid u32, source and
target type OIDs u32, function OID u32, context u8 `e` / `a` / `i`, method
u8 `f` / `i` / `b`) and 122 `drop_cast` (the OID), validated on replay
(method and context, function present for method `f` only, a live
function of one to three arguments taking the source and returning the
target, live composite types, one cast per pair, the function outliving
its casts); 123-124 stay reserved. Value tag 57 carries records (above);
58 stays reserved. Routine records (ops 60 / 80) may name composite type
OIDs, checked against the live types on replay. Existing records and the
table definition format are unchanged; base images (RSBASE) refuse casts,
composite columns and routines naming composite types.

Limits: Config.casts (4 cast versions; TableCapacity, 54000, beyond) and
Config.routine_records (4 record shapes per PL/pgSQL frame; 54000 beyond).
A record value fits one cell (Config.text_bytes; TextCapacity, 54000).

New SQLSTATE mappings: none. Used: 42846, 42809, 42703, 42804, 42P16,
42704, 22P02, 0A000, 2BP01, 42710, 42P17, 42501, 55000, 22023, 2200N,
54000, 40001.

Not covered (open):

- Records of records (a composite field of a composite or row type),
  arrays of composite types, domain and enum table columns.
- A table's row type: PostgreSQL gives every table a pg_type row; this
  catalog has none, so `SELECT t FROM t`, `t.*` as a function argument,
  `DECLARE r t` and `RETURNS t` stay 42703 / 42704. `(ROW(1,'a')).*` on
  a constant row constructor works here where PostgreSQL raises XX000.
- DROP TYPE ... CASCADE over columns, routines or casts (0A000); field
  assignment in UPDATE (`SET d.body = ...`); `FOR r IN SELECT` loops.
- S211's probe also creates a domain over NUMERIC(10,2) and a function
  returning it: domains support only integer bases with a comparison CHECK
  (0A000), so that probe stays open although CREATE / DROP CAST pass.
- A set-returning call nested in another one's arguments
  (`generate_series(1, generate_series(1, 3))`) is 0A000 where PostgreSQL
  stacks ProjectSet nodes. JSON set-returning functions (json_each,
  jsonb_array_elements, ...) and string_to_table do not exist yet.

## Not covered (open)

- INSTEAD OF triggers, automatically updatable views, rule actions, SQL
  in trigger functions and in functions called from expressions,
  data-modifying and multi-statement SQL bodies called from an
  expression, RETURN QUERY and CALL from a function run as nested
  statements (wave 4 nested-stmts lane, docs/SQL_NESTED_STATEMENTS.md,
  which lists what stays open).
- RETURNS record without OUT parameters, polymorphic types, %TYPE /
  %ROWTYPE, cursors, FOREACH and FOR over queries remain open (record
  values and record variables: the composite lane above).
- COMMIT / ROLLBACK where PostgreSQL allows them work through the store
  (docs/SQL_PROC_TX.md); a lock wait after one fails instead of waiting.
- A SQL body is validated under the session's settings, not the
  routine's SET clauses (PostgreSQL applies them at CREATE).
- A SQL function whose query body calls itself exceeds the inlining
  capacity (Config.subqueries, 54000).
- RAISE messages are not delivered to the client (no notice channel);
  RAISE / USING ERRCODE accept the conditions of the handler table only
  (an unknown five-character SQLSTATE is 0A000).
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
