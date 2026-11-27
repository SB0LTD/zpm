# SQL DDL and DML gaps (conformance lane B11, wave 4, ddl-dml)

Branch `w4/ddl-dml` closes gaps that earlier lanes left open in schema
objects (ZPM #114), transactions and sessions (#120) and catalog security
(#128). Every behaviour below was checked against native PostgreSQL 18.7
(statement by statement, values, SQLSTATEs and row order where PostgreSQL
defines it). `contract-sql-ddl-dml` (tests/test_sql_ddl_dml.sig) covers
values, exact SQLSTATEs, atomicity, concurrent schedules where a lock
decides, crafted change records and replay of every committed record into
a replica that must answer like the primary.

## Implemented

| Area | Implemented | Not covered |
|---|---|---|
| Inheritance and partitions | UPDATE / DELETE through an inheritance parent or a partitioned table run over every member (ONLY honoured; UPDATE ... FROM, DELETE ... USING, aliases, RETURNING over the parent's columns; privileges, rules and statement triggers of the named table, row triggers of each member). An UPDATE through a partitioned table moves a row whose key leaves its partition (delete + insert, the destination's NOT NULL / CHECK, 23514 when no partition takes it). TRUNCATE ONLY (42809 on a partitioned table) and TRUNCATE ... CASCADE. INHERITS merges same-named columns (NOT NULL from either, the local DEFAULT wins, 42804 on a type conflict) and accepts `()`. ALTER TABLE ATTACH / DETACH PARTITION (42804 column checks, 42809, 42P17 overlaps, 23514 rows, the DEFAULT partition's rows re-checked, DETACH ... CONCURRENTLY runs as the plain form, FINALIZE is 0A000). PRIMARY KEY / UNIQUE on partitioned tables when they include the partition key (0A000 otherwise); partitions copy them (also on ATTACH, checked over the rows) and ON CONFLICT arbitrates on the routed partition (0A000 when DO UPDATE would move the row) | multiple inheritance (`INHERITS (a, b)`, 0A000: definitions keep one parent); merging identity / generated columns (0A000); ATTACH of a table whose columns are in another order (0A000: rows route by position); ALTER TABLE ADD / DROP / RENAME COLUMN on family members and constraint propagation to children (existing 0A000 / per-table behaviour); `tableoid` over family reads and in RETURNING; data-modifying WITH on a family root (0A000); sub-partitioning (existing 0A000) |
| Constraints | Non-deferrable foreign keys are checked as their statement ends (a row may reference one inserted later; NO ACTION keys live again pass; RESTRICT fails whenever a changed key is still referenced, 23001 restrict_violation, also when the constraint is deferrable). ADD CHECK / FOREIGN KEY ... NOT VALID and VALIDATE CONSTRAINT (convalidated, pg_get_constraintdef `NOT VALID`, 42704, 42809, 0A000 for other kinds). CHECK / FOREIGN KEY [NOT] ENFORCED and ALTER CONSTRAINT ... [NOT] ENFORCED for foreign keys (42809 for CHECK, 55000 for VALIDATE of an unenforced one). RENAME CONSTRAINT (42704, 42710, 42P07; the index follows). ADD FOREIGN KEY referencing its own table. Foreign keys between text and varchar | RENAME / VALIDATE of a CHECK on an inheritance parent or child (0A000: PostgreSQL recurses); ALTER COLUMN TYPE [USING] (0A000) |
| Columns | ALTER COLUMN DROP IDENTITY [IF EXISTS], SET GENERATED ALWAYS / BY DEFAULT, RESTART [[WITH] n], DROP EXPRESSION [IF EXISTS] (55000 for another kind of column, 0A000 for a virtual one) | DROP COLUMN ... CASCADE of dependent views (2BP01 as before) |
| Indexes | CREATE / DROP INDEX CONCURRENTLY, outside transaction blocks only (25001); they build under the plain form's stronger lock | ordered (btree) secondary indexes, below |
| Locks | An UPDATE that keeps every key column takes FOR NO KEY UPDATE strength: FOR KEY SHARE and foreign key checks (now FOR KEY SHARE) do not wait for it; a key change waits for key sharers. LOCK TABLE on a view locks the relations its query reads, recursively (42809 for a materialized view) | |
| Row security | Policies of an inheritance parent or partitioned table filter every member's rows read or written through it; new rows a statement returns (or an UPDATE reads) must also pass the SELECT policies; WITH CHECK runs after stored generated columns and before NOT NULL and CHECK constraints | subqueries in policy expressions (0A000: policy texts are bound and deparsed like CHECK constraints) |
| Schemas and grammar | CREATE SCHEMA [name] AUTHORIZATION role / CURRENT_USER / CURRENT_ROLE / SESSION_USER (42704); FROM ONLY (name); two PRIMARY KEY columns 42P16; a word that starts no statement 42601; wire tags DROP VIEW / DROP MATERIALIZED VIEW / DROP INDEX, START TRANSACTION, CLOSE CURSOR ALL | CREATE SCHEMA with schema elements |

SET SESSION AUTHORIZATION was already implemented on main when this lane
started.

## Durability

- Table definition format 7 (`not_valid_format_version`): format 6 plus
  constraint flag bits 3 (NOT VALID) and 4 (NOT ENFORCED). It is written
  only when a constraint has either bit, so every older definition stays
  byte-identical; the decoder rejects the bits on any other constraint kind
  (InvalidChangeRecord) and versions above 7 (UnsupportedLogVersion).
- No change-log op was added (ops 90-99 stay unused). Family DML, row
  movement, ATTACH / DETACH, TRUNCATE CASCADE and the column commands ride on
  ops 3-5, 8, 11, 12 and 14.
- Replay validation now accepts a renamed constraint keeping its identity
  and an ATTACH that gives a keyless table its parent's primary key.

## Errors

New: 23001 RestrictViolation. Also used: 23514, 23503, 23505, 23502,
42501, 42704, 42710, 42P07, 42P01, 42P10, 42P16, 42P17, 42804, 42809,
42601, 55000, 25001, 0A000.

## Ordered (btree) secondary indexes: the design they need

Secondary indexes are hash multimaps of version references in
`Table.index_slots` (inline `index_entries` or bound `external_indexes`
slots, two per version). Range predicates, ORDER BY and LIMIT cannot use
them, and a sorted array in the same slots would cost O(n) moves per
insert, so ordered indexes are not implemented. They need:

1. A bounded B+tree per index in caller-owned storage: fixed-size nodes
   (fan-out from a `Config.index_fanout` constant) in a node arena carved
   next to the hash slots by `bindMemory` (external) or sized inline from
   `index_entries`, with a free list; a full arena is 54000.
2. Entries are version references, as in the hash (every version, filtered
   by visibility on scan; vacuum removes reclaimed versions). Fixed-width
   keys (integers, dates, timestamps) are cached in the node so comparisons
   do not read version rows; other keys compare through the version row,
   expression keys through their bound expression.
3. Planner support in the binder: `<`, `<=`, `>`, `>=`, BETWEEN and equality
   prefixes on key columns become range bounds; ORDER BY matching the key
   order (ASC / DESC, NULLS FIRST / LAST) scans the leaves in order and stops
   at LIMIT; expression elements match by canonical text; a partial index is
   used only when the query predicate implies the index predicate.
4. No WAL change: indexes are rebuilt from table data, as hash indexes are.

## Not done in this lane

TEMP tables with session lifetime (pg_temp, ON COMMIT DELETE ROWS / DROP),
`search_path` resolution for user schemas (the shared resolver routines-sig
would use), SHOW ALL, SET TRANSACTION SNAPSHOT / pg_export_snapshot, lazy
cursors, COMMENT ON INDEX / FUNCTION / TYPE / CONSTRAINT, column, sequence
and schema-usage privileges beyond what main has, ALTER COLUMN TYPE,
identifiers longer than 63 bytes (truncation) and varchar(3) yes/no
information_schema columns remain open.
