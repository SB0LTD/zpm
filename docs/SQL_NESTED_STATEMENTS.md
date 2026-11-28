# Nested statements, view updates and rule actions (conformance lane B11, wave 4)

Branch `w4/nested-stmts` gives the engine one facility that wave 3 left
open: SQL statements that run while another statement is executing. Four
features build on it: SQL inside trigger functions and inside functions
called from expressions, INSTEAD OF triggers on views, automatically
updatable views, and rule actions.

`contract-sql-nested-stmts` (tests/test_sql_nested_stmts.sig) covers every
section with values in PostgreSQL text output, command tags, exact errors
(the SQLSTATE through the error name), atomicity after a failure, lock
waits between two transactions, work control, capacities and replay. Every
committed record is applied to a replica, which must answer every probe
the way the primary does. Expected values were checked against native
PostgreSQL 18.7. The recorded oracle files stay on 18.3.

## The facility (src/core/sql/nested.sig)

A nested statement is a statement of a routine body that runs inside an
executing statement: the SQL of a PL/pgSQL trigger function, of a SQL or
PL/pgSQL function called from an expression, or a rule action
(`Database.routineStatement` when `routine_nested != 0`).

- **Workspace.** The suspended statement keeps its query cells, refs and
  value bytes where they are. The nested statement works only in the free
  middle of the query workspace (`Work.floor_*` and `Work.top_*`). Anything
  else the nested statement would overwrite is copied to the top of that
  free middle, below the suspended statement's top cells, and copied back
  when the nested statement ends, whether it succeeds or fails. That covers
  the used node pool, the plans, the expansion text, and the
  statement-scoped Database fields (outcome, data-modifying WITH state,
  INSERT progress, snapshots, routine frame, bind parameters). One `Stream`
  walk measures, saves and restores them. Nothing allocates. A workspace
  too full for the saved state is WorkspaceCapacity (54000).
- **Snapshots and command ids.** These follow PostgreSQL's SPI rules. A
  volatile routine runs `CommandCounterIncrement` before each statement and
  takes a new snapshot: the latest committed data under READ COMMITTED, the
  transaction snapshot under REPEATABLE READ and SERIALIZABLE (taken there
  if no statement took it yet). It also sees every earlier command of its
  own transaction, including the rows its calling statement wrote so far.
  Each of its expressions reads at the next command id. A STABLE or
  IMMUTABLE routine runs under its caller's snapshot. It cannot write
  (`INSERT is not allowed in a non-volatile function`, 0A000) or lock rows
  (0A000). The calling statement keeps its own command id and never sees
  its nested statements' writes.
- **Writes and atomicity.** Nested writes join the statement's
  subtransaction, so an uncaught error anywhere undoes the whole statement.
  A PL/pgSQL EXCEPTION block undoes only the writes made since the block
  began. AFTER ROW triggers and RETURNING read only the writes of their own
  statement: the scan stops at the write-set end it saw at the start, and
  each write's command id must match. A nested statement's AFTER triggers
  fire at the end of that nested statement. A row that a triggered
  statement already changed cannot be updated or deleted by the statement
  that fired the trigger (27000, PostgreSQL's TM_SelfModified rule).
- **Lock waits.** If a statement must wait while any nested statement ran
  in it, the whole statement is undone. Its write slice, locks, progress
  and data-modifying WITH state all go. The re-delivered statement starts
  over with a fresh snapshot, so no trigger or function effect happens
  twice. A procedure statement (CALL / DO) already restarted this way in
  wave 3.
- **Depth.** `Config.nested_statements` (default 8) bounds nesting; deeper
  is 54001. Debug builds hold 16 levels of trigger recursion under a 4 MiB
  stack; 32 overflow it.
- **Work control.** Every nested statement is a checkpoint, and so is
  every statement and loop iteration of a routine body. A cancel or the
  work budget ends the whole statement; an EXCEPTION block never catches
  them.
- **Table scans.** An INSERT that needs a new row slot never compacts a
  table that a suspended statement scans (54000 instead). Simple
  single-table SELECTs that call a user function run in the query engine.
  The simple path evaluates projections twice, once to validate and once
  to publish, and keeps its scan state outside the workspace.
- Inside a running statement, queries, INSERT / UPDATE / DELETE / MERGE,
  CALL, DO and (B11 wave 5) DDL run; DDL on a table a suspended statement
  uses is 55006 (docs/SQL_ROUTINES.md, Wave 5).
- **Values leaving a nested statement.** These are SELECT / RETURNING ...
  INTO captures, table-reading PL/pgSQL expressions, SQL body results, and
  rows kept for RETURN QUERY and set-returning bodies. Each value is copied
  into the routine frame's variables or into the kept rows (`ownCell`). A
  value up to Config.text_bytes is inline and is copied with its cell.
  Only a wider value points into the nested statement's value region,
  which the next statement reuses. Such a value can only be a wide catalog
  rendering such as pg_get_viewdef, or a record or array decoded in place,
  and it does not fit that bounded storage: 54000 (TextCapacity), with the
  statement undone. PERFORM keeps no values. Values coming in (arguments,
  NEW / OLD, the suspended statement's rows) stay valid because the nested
  statement's value bytes start above the suspended statement's
  (`Work.floor_values`).

## SQL in functions and trigger functions

- PL/pgSQL `SELECT ... INTO [STRICT]`, `INSERT / UPDATE / DELETE ...
  [RETURNING ... INTO]`, `PERFORM`, `FOUND` and `GET DIAGNOSTICS
  ROW_COUNT` work in trigger functions and in functions called from
  expressions. PL/pgSQL expressions that read tables (`n := (SELECT ...)`,
  `IF EXISTS (...)`) run as `SELECT expr`, as PostgreSQL's exec_eval_expr
  does.
- SQL-language bodies other than one expression without FROM run every
  statement as a nested statement. The result is the first column of the
  final statement's first row (NULL without rows or for void). The entry
  point is `Database.sqlFunctionBody(frame, body, result_column,
  void_result)`. The routines-sig lane's DML and set-returning SQL bodies
  can call it; set-returning bodies still need the final statement's rows
  collected.
- `TG_ARGV` is a `text[]` indexed from 0 (`[0:n-1]={...}`), NULL without
  arguments, as in PostgreSQL.
- **RETURN QUERY** runs its query as a nested statement and adds the rows
  to the function's result. The query's columns must match the result
  row's count and types: 42804, PostgreSQL's "structure of query does not
  match function result type". FOUND and ROW_COUNT are set.
  `Database.routineReturnQuery` keeps a statement's rows for its caller
  (`RowStaging`) at the top of the free query workspace, then emits them
  through the function's row sink.
- **SQL bodies that are not inlined.** These are data-modifying bodies,
  bodies with several statements, and volatile bodies. A volatile body is
  never inlined, so each of its statements takes a new snapshot, as
  PostgreSQL does: it inlines neither volatile set-returning functions nor
  scalar bodies that read tables.
  - From an expression, the body's first row is the value.
  - From FROM, a set-returning body emits every row of its final query or
    RETURNING. Any other body emits its first row: the OUT parameters, or
    a row of NULLs without one.
  - An inlined body evaluated where no subquery runner exists (the row
    paths of INSERT / UPDATE / DELETE) runs nested instead.
- CALL inside a function and `RETURN (SELECT ...)` work. COMMIT / ROLLBACK
  in a procedure (`routineTransaction`) stay 0A000. Committing in the
  middle of a CALL needs a change record per partial transaction, which
  the store's protocol does not offer. That is not part of nested
  statement execution.

## Views as INSERT / UPDATE / DELETE targets

- **INSTEAD OF row triggers.** NEW and OLD have the view's columns. For
  UPDATE and DELETE the view's rows are read once under the statement
  snapshot and kept below the workspace floors; the statement's WHERE and
  SET are then evaluated over the view's columns. A NULL result skips the
  row and is not counted. RETURNING reads the row the trigger returned, or
  OLD for DELETE. Statement triggers of the view fire around the
  statement. CREATE TRIGGER follows PostgreSQL: INSTEAD OF only on views
  (42809), FOR EACH ROW only, no column list and no WHEN (0A000), and
  views have no BEFORE / AFTER row triggers (42809).
- **Automatically updatable views.** A view over one table or view without
  DISTINCT, GROUP BY, HAVING, set operations, WITH, LIMIT / OFFSET,
  aggregates or window functions is rewritten onto its base relation, as
  PostgreSQL's rewriteTargetView does:
  - view column names map to base columns, and reads of computed columns
    become their expressions;
  - `RETURNING *` returns the view's columns;
  - UPDATE and DELETE keep only rows of the view (the view's WHERE);
  - views over views repeat the rewrite.

  The user needs the privilege on the view, and the view's owner needs it
  on the base relation. Base triggers, rules and constraints apply.
  Writing a computed column is 0A000. Base columns the view does not show
  are 42703.

  Other views are 55000. `Database.lastErrorDetail()` returns PostgreSQL's
  errdetail (`Database.view_details`): DISTINCT, GROUP BY, HAVING, set
  operations, WITH, LIMIT / OFFSET, aggregates, window functions, not one
  table or view, or no updatable column. A view with no updatable column
  can still DELETE, as in PostgreSQL.

## Rule actions

- `CREATE RULE ... DO [ALSO | INSTEAD] action` takes one INSERT, UPDATE or
  DELETE, or several in parentheses. Actions can use NEW / OLD and a WHERE
  condition, on tables and on views.
- Each action runs as a nested statement once per row of the original
  statement, with NEW / OLD bound:
  - INSERT actions run after the original. Its rows are computed again,
    defaults included, because PostgreSQL copies the expressions into
    each action (a serial default advances again).
  - UPDATE and DELETE actions run before the original, over the rows its
    WHERE keeps.
- An unconditional INSTEAD rule replaces the original. The command tag
  then counts the last INSTEAD action of the original's kind. A
  conditional INSTEAD rule keeps the original for the other rows.
- On a view, an unconditional INSTEAD rule replaces the statement. Other
  rules run beside its INSTEAD OF triggers.
- Errors:
  - OLD in an ON INSERT rule or NEW in an ON DELETE rule is 42P17.
  - An action that reaches a relation whose actions are already running
    is PostgreSQL's "infinite recursion detected in rules" (42P17).
  - SELECT and NOTIFY actions are 0A000.
  - RETURNING with an INSTEAD rule is 0A000, as in PostgreSQL without a
    RETURNING action.
- `pg_rules` and `pg_get_ruledef` show actions as written, in PostgreSQL's
  layout. PostgreSQL deparses them.

## Durability

- Op 85 `create_rule_action` is a rule with actions. Its payload is the op
  64 payload, then flags u8 (1: the actions were in parentheses), then the
  action text (u16 length + bytes, non-empty, no NUL). Replay validates it
  like op 64.
- Op 64 records stay byte-identical, and ops 86-89 stay reserved.
- Catalog images (RSBASE) refuse rules with actions: `encodeRule` returns
  0A000 rather than dropping the action.
- Nothing else changed in the log. Views, triggers and the other features
  add no records.

## Limits

| Constant | Default | Beyond |
|---|---|---|
| `nested_statements` | 8 | 54001 (StackDepthExceeded) |
| query workspace for saved statements | `work_rows` x 2 x `columns` cells (shared) | 54000 (WorkspaceCapacity) |
| rule-action relations running at once | 8 | 54001 |

## SQLSTATEs

New: 27000 (TriggeredDataChangeViolation) and 44000
(WithCheckOptionViolation). WithCheckOptionViolation is mapped but not
raised yet. Also used: 54001, 54000, 0A000, 55000, 42P17, 42809, 42703,
42501, 23505, P0001, P0003, 57014.

## Not covered (open)

- **WITH CHECK OPTION** (F311-04, F751). It needs CREATE VIEW grammar and
  a persisted view option, and CREATE VIEW DDL is being changed by ZPM
  #332. 44000 is mapped for it.
- **information_schema views.** information_schema.views and
  information_schema.columns.is_updatable do not exist yet.
- **Rule actions:**
  - SELECT and NOTIFY actions;
  - RETURNING in actions;
  - ALSO or conditional rules on a view without INSTEAD OF triggers (0A000);
  - actions that aggregate across the original's rows. PostgreSQL runs
    each action once, joined with them; here it runs once per row.
- **Views:**
  - a view over a view that has INSTEAD OF triggers (0A000);
  - ON CONFLICT on views;
  - reads of computed view columns inside subqueries;
  - base-relation row security, which is applied as the current user,
    not the view owner;
  - COPY into a view.
- **Trigger extras:** transition tables, constraint triggers and
  triggers fired by referential actions and COPY FROM are done in wave 5
  (docs/SQL_ROUTINES.md); T217 (TRIGGER privilege) belongs to the
  privileges lane.
- **Other:**
  - `INSERT ... VALUES ((subquery))` is 0A000 in every context;
  - a value wider than Config.text_bytes cannot leave a nested statement
    (54000; PostgreSQL has no such bound).
