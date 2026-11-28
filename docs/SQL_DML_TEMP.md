# DML, query shapes, cursors and view check options (B11 wave 5, dml-temp)

Branch `w5/dml-temp`. Every behaviour below was checked against native
PostgreSQL 18.7, statement by statement (values, NULLs, SQLSTATEs and row
order where the statement orders). `contract-sql-dml-temp`
(tests/test_sql_dml_temp.sig) runs 212 wire steps through store connections,
replays every committed record into a replica that must answer like the
primary, and feeds crafted change records to the decoder.

## Implemented

| Area | Behaviour |
|---|---|
| Subqueries in DML (E153, F781, F471) | Scalar, `IN` and `EXISTS` subqueries in UPDATE / DELETE WHERE, UPDATE SET and INSERT VALUES, also over the target table itself. One statement-lifetime runner (`X.StatementQueries`) evaluates them under the statement snapshot: uncorrelated results are computed once, correlated ones per row, and rows the statement writes carry its command id, so they stay invisible (PostgreSQL's snapshot semantics). Views whose WHERE has a subquery update through the wave-4 rewrite. 21000 for a scalar subquery with two rows, atomically. |
| Row subqueries (F641) | `(a, b) op (SELECT x, y ...)` for `=`, `<>`, `<`, `<=`, `>`, `>=`: each field reads its own output column of the same plan. 42601 for a column-count mismatch or `IS [NOT] DISTINCT FROM` (PostgreSQL reads a one-column subquery there), 21000 for two rows, NULLs for no row. |
| USING join alias (F404) | `JOIN ... USING (c, ...) AS alias`: `alias.c` reads the merged column (the left, right or COALESCEd one by join kind); any other `alias.x` is 42703. |
| Catalog names (F651) | `catalog.schema.name` for FROM items, INSERT / UPDATE / DELETE targets and other qualified relation names, and `[catalog.]schema.table.column` references. The catalog must be the session's database (0A000 otherwise, PostgreSQL's cross-database reference); a statement holds `ast.catalog_ref_capacity` (8) qualifiers (54001 beyond). |
| Nested query clauses (F855, F856, F863) | A statement or FROM item that starts with a parenthesized query: ORDER BY, LIMIT / FETCH and OFFSET inside set-operation operands. In FROM, the token after the matching `)` decides between a query and a join group (`((SELECT ...) s JOIN t ON ...)` stays a join). The same clause on both sides of a parenthesis is 42601. |
| AND CHAIN (T261) | `COMMIT / END / ROLLBACK / ABORT [WORK | TRANSACTION] AND [NO] CHAIN`: 25P01 outside a block; the next block begins at once with the ending one's isolation level, READ ONLY and DEFERRABLE. After a failure outside any savepoint the next block takes the session defaults (PostgreSQL's abort has undone the transaction settings); inside a savepoint it keeps them. The tag is ROLLBACK when the block failed. |
| Time zone intervals (F761) | `SET [LOCAL] TIME ZONE INTERVAL 'text' [HOUR | MINUTE | HOUR TO MINUTE]` as a fixed offset (`<+02>-02`). A bare number counts in the qualifier's last field, finer fields are dropped; days or months are 22023, other qualifiers 42601. SET SESSION CHARACTERISTICS and SET SCHEMA were already on main. |
| Positioned DML (E121-06, E121-07) | `UPDATE / DELETE ... WHERE CURRENT OF cursor` (RETURNING included). A cursor over a single-table query on the simple path keeps each output row's rowid from DECLARE: FOR UPDATE / SHARE cursors in output order; other cursors only without ORDER BY, as PostgreSQL's plan search finds no scan under a Sort. 34000 for no such cursor; 24000 for a held cursor from a previous transaction, one not on a row, or one that is not a simply updatable scan of the target (joins, aggregates, another table). A deleted current row gives DELETE 0 / UPDATE 0. |
| pg_cursors (E121-08) | The session's open cursors: name, the DECLARE text, is_holdable, is_binary (false), is_scrollable (as declared) and creation_time from the statement clock. The text shares the cursor value pool (54000 when full). Detached reads reject the view like pg_settings. |
| WITH CHECK OPTION (F311-04, F751) | `CREATE [OR REPLACE] VIEW ... WITH [LOCAL | CASCADED] CHECK OPTION` and `WITH (check_option = local | cascaded)`. The view must be automatically updatable (0A000), another value is 22023, other view options stay 0A000, and OR REPLACE replaces the option. INSERT and UPDATE through views evaluate, after the row's constraints, a view's own WHERE when it has the option and the WHERE of every view below a CASCADED one, rewritten over the base table by the wave-4 rewrite; FALSE or NULL is 44000. `S.Table.check_option` (0 none, 1 LOCAL, 2 CASCADED) is where information_schema.views reads it. |
| CURRENT_DATE in CHECK (F672) | Works whenever the session has a wall clock (RAMSQL always does). |

## Durability

- New change-log op **115** `view_check_option`: oid u32, option u8 (1
  LOCAL, 2 CASCADED), written right after the op 1 / op 12 that defines a
  view with the option. A definition replayed without it has none, so every
  older record stays byte-identical and no table definition format changed.
  The decoder rejects an option outside 1..2 or a relation that is not a view
  (InvalidChangeRecord) and an unknown OID (ChangeRecordConflict). Ops
  116-119 stay reserved for this lane.
- Everything else rides on existing ops: DML subqueries, positioned DML and
  chained transactions write ordinary row records.

## Errors

New: 24000 InvalidCursorState. Also used: 44000, 42601, 42703, 0A000,
21000, 22023, 25P01, 34000, 54000, 54001, 23505, 23514.

## Not done

- **TEMP tables (F531)** need real session-private storage: a per-session
  `pg_temp_N` namespace that unqualified relation lookup searches first (but
  never routines or CREATE without TEMP), change-record filtering for every
  write kind on temp relations (rows, create / drop / alter, sequences,
  triggers and other objects that name them), ON COMMIT DELETE ROWS / DROP
  inside the committing transaction, a drop transaction at session end, a
  per-session slot bound, information_schema's `LOCAL TEMPORARY` and a
  PREPARE TRANSACTION rejection. CREATE TEMP TABLE still creates an ordinary
  table and ON COMMIT is 42601.
- **COMMIT / ROLLBACK inside procedures (T261 in CALL / DO)** needs the store
  to write, sync and publish a change record in the middle of a statement and
  to make a lock wait after such a commit block instead of re-running the CALL
  from its start, with crash-style replay qualification.
- **Enhanced cycle marks (T133)**: the SEARCH sequence and CYCLE path columns
  need an anonymous record-array type (OID 2287) and its text output; they
  stay 0A000.
- **ALTER VIEW SET / RESET (check_option)**: ALTER VIEW is not parsed yet.
- **RESTRICT (T191)**: RESTRICT itself works (23001); the probe's remaining
  gap is information_schema.referential_constraints (catalog lane).
- **F751's last probe statement** reads information_schema.views.check_option
  (catalog lane), and **F672's probe** fails only because the features
  harness store has no wall clock.
- pg_cursors.statement is the single statement, not the whole Query message
  text PostgreSQL shows (with its trailing semicolon). RETURNING subqueries
  and `(a, b) IN (SELECT x, y ...)` stay 0A000. A three-part
  `schema.table.column` reference does not check the schema.
