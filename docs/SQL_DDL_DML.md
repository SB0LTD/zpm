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
| Indexes | CREATE / DROP INDEX CONCURRENTLY, outside transaction blocks only (25001); they build under the plain form's stronger lock | ordered (btree) secondary indexes: implemented in wave 5, below |
| Locks | An UPDATE that keeps every key column takes FOR NO KEY UPDATE strength: FOR KEY SHARE and foreign key checks (now FOR KEY SHARE) do not wait for it; a key change waits for key sharers. LOCK TABLE on a view locks the relations its query reads, recursively (42809 for a materialized view) | |
| Row security | Policies of an inheritance parent or partitioned table filter every member's rows read or written through it; new rows a statement returns (or an UPDATE reads) must also pass the SELECT policies; WITH CHECK runs after stored generated columns and before NOT NULL and CHECK constraints | subqueries in policy expressions (0A000: policy texts are bound and deparsed like CHECK constraints) |
| search_path | SET search_path / SET SCHEMA 'name' with any schema names. One resolver (`Config.search_path_schemas`, default 8 existing schemas; missing schemas and ones without USAGE are skipped, `"$user"` is the current role's schema) drives unqualified tables, views and sequences (FROM items, DML targets, ALTER / DROP / TRUNCATE / LOCK / COMMENT, triggers and rules), regclass and nextval('name'), user types and the routines lane's routine lookup; an unqualified CREATE uses the path's first existing schema (3F000 with none); current_schema() / current_schemas() list the path | pg_catalog placement: built-in relations and functions still resolve before user schemas even when pg_catalog is listed later; pg_temp (no temporary schemas); CREATE VIEW / MATERIALIZED VIEW naming an unqualified relation outside public is 0A000 (stored view texts resolve through public); detached store reads run only with a path of `"$user"`, public, pg_catalog and pg_temp |
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

## Ordered (btree) secondary indexes (wave 5, btree lane)

Branch `w5/btree` implements the design wave 4 left here. Contract:
`contract-sql-btree` (tests/test_sql_btree.sig). PostgreSQL behaviour was
checked against native PostgreSQL 18.7.

### Access methods

- `CREATE INDEX` without `USING` is a btree index, as in PostgreSQL.
  `USING btree` is the same; `USING hash` keeps the hash entries of
  earlier waves. PostgreSQL's hash restrictions apply, in DefineIndex
  order: UNIQUE, INCLUDE and more than one key element are 0A000, as are
  ASC/DESC and NULLS FIRST/LAST. Other built-in methods (gist, gin, brin,
  spgist) are 0A000; an unknown method is 42704.
- pg_am lists hash (405, hashhandler); a hash index's pg_class.relam is
  405 and pg_indexes / pg_get_indexdef show `USING hash`.
- Durability: index flags bit 2 (value 4) marks USING hash. It is written
  only for hash indexes, so every record logged before stays
  byte-identical. A definition without the bit replays as a btree index:
  before this lane every index displayed `USING btree` and answered
  queries as a btree would (same rows), so replaying old logs as btree
  changes no visible semantics. The decoder rejects flags above 7 and a
  hash flag on a unique, multi-element, INCLUDE or ordered definition
  (InvalidChangeRecord). No change-log op was added; entries are rebuilt
  from the versions on replay, as hash entries are.

### Storage

- A btree index is a B+tree of row-version references in the index's run
  of `Table.index_slots`: inline runs of `index_run_capacity` u32 words,
  external runs bound by `bindMemory` / `bindMemoryFor` and counted by
  `backingBytes` / `backingBytesFor` (a run now holds the larger of the
  hash slots and the node arena: `Database.indexRunWords`).
- Nodes are `4 + 4 x index_fanout` words: a leaf entry is (cached key,
  version); an internal entry is (cached key, child, version) of the
  child's first leaf entry, so every separator is a live entry and a
  reclaimed version never leaves a stale separator. Node 0 of a run holds
  the root, height, free list and entry count.
- Entries order by the key elements (DESC and NULLS FIRST per element,
  values by the engine comparator: code-point order for text), then by
  row slot (heap order, which is the order a stable sort of a scan keeps
  for ties), then by version. The cached key is an order-preserving 8-byte
  abbreviation of the first element (integers, dates, timestamps, money,
  booleans, the first 8 bytes of text and bytea); equal cached keys fall
  back to the comparator.
- Every version is an entry (pending, dead and aborted ones until
  reclamation removes them); readers keep the entry whose version
  `visibleAt` returns for their snapshot, so each row appears once.
- Inserts split a full node (the left half keeps half + 1 entries);
  deletes borrow from a sibling holding more than half or merge with it;
  a root with one child gives way to it. Every non-root node keeps at
  least half its fanout, so the arena sized for the worst case of the
  entry capacity (`treeNodes`) always suffices and every operation touches
  at most `btree_depth` nodes per level. The contract checks order,
  separators, occupancy, height, links, counts and the arena bound after
  every change.
- Compaction moves rows to lower slots in order, so the slot tie-break
  stays valid without a rebuild.

### Planner and executor

- Single-table SELECT (`B.Select.index`, chosen in the binder): leading
  key elements fixed by `= constant` or `IS NULL`, then on the next element
  a range (`<`, `<=`, `>`, `>=`, BETWEEN, `IS NOT NULL`) or an IN list (up
  to 16 values, walked in index order, duplicates once). Bounds are
  literals, parameters and casts, arithmetic and immutable built-in calls
  over them; the column side may be a value-preserving cast (integer
  widening, varchar/text). The whole WHERE is re-checked on every
  candidate; a bound that fails to evaluate leaves the statement to the
  scan; a NULL bound matches nothing.
- ORDER BY is served by walking the index (backward for the reversed
  order, ASC/DESC and NULLS FIRST/LAST matched per element) when its keys,
  after the elements fixed by equality, are exactly the remaining key
  elements; LIMIT then stops the walk. Ties come out in heap order (a
  backward walk reverses each run of equal keys), so an index path returns
  the same rows in the same order as the scan and stable sort it replaces.
  A path that does not serve ORDER BY returns its rows in heap order, then
  sorts them as a scan's rows are sorted.
- An index with only an ORDER BY to serve is used with LIMIT (top-N).
  Choice between indexes: most leading equalities, then a range or list,
  then ORDER BY served, then covering, then the first index.
- Partial indexes are used only when the WHERE implies the predicate
  (equal conjuncts, `col IS NOT NULL` by a strict comparison, IN list or
  BETWEEN of col, and integer comparisons a narrower one implies). Their
  entries cover every row, so the choice never changes results.
- Expression elements take no part in the tree order: a lookup on an
  expression is not served (see below); a plain-column prefix before the
  first expression element is.
- INCLUDE columns: a query reading only key and INCLUDE columns shows as
  Index Only Scan (it still reads the version for visibility).
- UNIQUE indexes check through the tree with the existing dirty-snapshot
  rules (wait for another transaction's insert or delete of the key),
  including ON CONFLICT arbiters and CREATE UNIQUE INDEX over duplicates.
- Hash indexes serve `column = bound` (rows in heap order).
- min() / max() of a column that leads an ordered index (one ungrouped row,
  no WHERE, FILTER or DISTINCT; HAVING allowed) read the first visible
  non-NULL entry from the matching end.
- Nested-loop joins: an inner table whose ON has `inner.col = outer
  column` with col leading an ordered index (unique ones first, partial
  ones not) walks that index's equal keys per outer row. A primary-key
  probe keeps priority; the streaming and factorized join paths still read
  primary keys only.
- The only FROM item of a query plan (aggregates, DISTINCT, OFFSET,
  subquery and CTE bodies) reads its rows through the same index paths,
  in heap order. A streamable aggregate keeps its streaming scan when the
  index rows overflow the workspace, and over a compact column projection
  unless the path is an equality lookup (the projection streams a range
  faster than the index materializes it).
- EXPLAIN (FORMAT JSON): `Index Scan` (an ordered walk or a unique
  lookup), `Index Only Scan` (covering), `Bitmap Heap Scan` (rows in heap
  order), under `Sort` / `Limit` as with scans. EXPLAIN without ANALYZE
  reports the planned node of an index path ("Select Plan" otherwise, as
  before). Plans of the general engine show "Query Plan" as before.

### Capacity (54000, statement rolled back, nothing changed)

| Limit | Config | Checked |
|---|---|---|
| Node arena | `index_entries` (inline; external: every version) and `index_fanout` (default 32) size it | entries beyond the arena's worst case: `indexRoom` before the version is created; CREATE INDEX / ALTER over more versions |
| Depth | `index_depth` (0: derived, 8 at fanout 32) caps entries at 2 x (fanout/2)^depth - 1 | same checks |
| Entry bytes | `index_key_bytes` (default 2704, PostgreSQL's btree limit) over key and INCLUDE values | every new version (INSERT, UPDATE, COPY, replay) and CREATE INDEX over existing rows; hash indexes have no limit |

A replica with smaller limits refuses the record (ChangeRecordConflict for
definitions, IndexCapacity for rows).

### Memory

An external run is `max(pow2(2 x versions), (1 + treeNodes(versions)) x
(4 + 4 x fanout))` u32 words: about 35 bytes per version per index at
fanout 32 (8 to 16 for a hash before). RAMSQL's default plan (8 tables,
rows 4096, versions 8192, four indexes) is 92,129,280 bytes instead of
84,967,424 (contract-sql-index-external reports it). Inline runs follow the
same formula from `index_entries`.

### Measured cost (contract-sql-btree, 120,000 rows)

External storage with compact integral scans; `k` is indexed and `u`
holds the same values without an index. Mean time per statement on this
machine (shared with other builds; Debug and ReleaseSafe):

| Query | Debug index / scan | ReleaseSafe index / scan |
|---|---|---|
| `k = c` (1 row) | 24 µs / 205 µs | 4.5 µs / 27 µs |
| `k BETWEEN c AND c + 99` (100 rows) | 73 µs / 21.5 ms | 14 µs / 4.8 ms |
| `ORDER BY k DESC LIMIT 10` | 27 µs / 1.16 ms | 5.7 µs / 162 µs |
| `min(k), max(k)` | 38 µs / 21.3 ms | 5.1 µs / 3.0 ms |
| `count(*), sum(g)` over 1,200 rows | 400 µs / 398 µs | 51 µs / 50 µs |

The last row streams the compact projection in both forms (see above).
Index walks read only their range's entries (asserted).

### Not done

- Lookups on expression elements: entries are ordered by plain columns
  only. Ordering by an expression needs its value at every maintenance
  point (insert, reclamation, rebuild, replay), where storage has no
  statement pool to evaluate a bound expression; it needs an index-key
  program per table that storage can run on a version row.
- Index paths for UPDATE / DELETE targets and for multi-item plans other
  than the nested-loop inner side; OR / bitmap AND-OR combinations of
  several indexes; index paths that serve ORDER BY in the general plan
  engine; skip scans.
- UNIQUE / PRIMARY KEY constraints (not indexes) keep their scan or key
  index checks.
- EXPLAIN shows only the top node (the existing JSON format), not index
  names or conditions.

## Not done in this lane

TEMP tables with session lifetime (pg_temp, ON COMMIT DELETE ROWS / DROP),
pg_catalog placement in the search path, SHOW ALL, SET TRANSACTION SNAPSHOT / pg_export_snapshot, lazy
cursors, COMMENT ON INDEX / FUNCTION / TYPE / CONSTRAINT, column, sequence
and schema-usage privileges beyond what main has, ALTER COLUMN TYPE,
identifiers longer than 63 bytes (truncation) and varchar(3) yes/no
information_schema columns remain open.

## Wave 5 (ddl-alter) updates

Branch `w5/ddl-alter` (`contract-sql-ddl-alter`, tests/test_sql_ddl_alter.sig)
closes several "Not covered" entries above; checked against native
PostgreSQL 18.7.

- ALTER COLUMN TYPE [USING] rewrites the table (latest visible version of
  each row converted, other versions dropped), re-checks defaults, CHECK,
  NOT NULL, keys and foreign keys over the column (42804, 23502, 23503,
  23505, 23514), and is 0A000 for columns views or generated columns use;
  durable as change-log op 105. A REPEATABLE READ snapshot older than a
  row it would rewrite is 40001.
- DROP COLUMN ... CASCADE drops the views that use the column (column
  usage from binding each view's query), generated columns over it and
  other tables' foreign keys referencing it; RESTRICT stays 2BP01.
- CREATE SCHEMA with schema elements runs them in PostgreSQL's order with
  the new schema first in the search path (42P15, 42601, 0A000 as native).
- CREATE VIEW stores relation names resolved outside public qualified with
  their schema instead of 0A000.
- Table definition format 8 adds per-column collations, NOT NULL constraint
  names and domain OIDs; pg_constraint lists NOT NULL constraints.
