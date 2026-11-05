# Secondary index storage with external_storage (conformance lane B11)

Branch `b11/index-storage` makes CREATE [UNIQUE] INDEX work when ZPM is built
with `external_storage = true`, as RAMSQL builds it. Before, the index entry
hashes were an inline array sized by `Config.index_entries` (0 under external
storage), so CREATE INDEX was IndexCapacity (54000) and setting the knob put
`tables x table_indexes x pow2(2 x entries) x 4` bytes inline and capped
every indexed table at `index_entries` versions.

## Design

- Under external storage `Table.index_slots` is a `[]u32` bound inside the
  caller's region (`StorageBacking.index_slots`). Index i of a table uses
  run i: `key_index.len` slots, the primary-key index's size, a power of two
  of at least 2 x the table's runtime versions. Entries therefore cover every
  version the arena can allocate (load <= 50%), and `indexRoom` never caps a
  table that has version room: a full arena is VersionCapacity (53200).
- `Config.external_indexes` (default 0, at most `table_indexes`) is the number
  of runs `bindMemory` / `bindMemoryFor` carve per table and
  `backingBytes` / `backingBytesFor` count. With 0 the memory plan is byte for
  byte what it was and CREATE INDEX stays 54000. `bindStorage` callers bind
  any count per table slot (a whole number of runs, at most `table_indexes`;
  overlap is rejected like every other buffer).
- Capacity is per table slot. CREATE INDEX and ALTER TABLE copy the table into
  a free slot; the copy's runs must hold every index (54000 otherwise, before
  anything changes). CREATE TABLE ... LIKE INCLUDING INDEXES checks its slot.
  `copyFromInto` refuses a destination slot with too few runs
  (WorkspaceCapacity) and rehashes entries for the destination's masks.
- Replay: no change-log format change. Index definitions already travel in
  definition format 3 (op 12, `create_table` / `alter_table`). Validation
  refuses a definition whose target slot has too few runs
  (ChangeRecordConflict, before any change), and apply re-checks it. Replay
  rebuilds entries from the versions (`redefine`, `writeVersion`).
- `setExtras` clears the runs of the indexes it installs, so a table created
  with indexes never reads uninitialized external memory or a reused slot's
  stale entries.
- Inline storage keeps its layout (`[table_indexes][pow2(2 x entries)]u32`
  per table) and behaviour. `index_entries` is now a compile error together
  with `external_storage`.

## Memory

Bytes per table per index are `4 x pow2(2 x versions)`, i.e. 8 to 16 bytes per
version per index:

| Runtime versions per table | Bytes per table per index |
|---|---|
| 1,024 (sql-storage `server_versions_per_table`) | 8,192 |
| 8,192 (RAMSQL default: rows 4096) | 65,536 |
| 1,000,000 or 1,048,576 | 8,388,608 |

A RAMSQL version is 1,200 bytes (8 columns, 128-byte text), so one index adds
0.7% to 1.3% of the version arena. RAMSQL's default plan (8 tables, rows 4096,
versions 8192) grows by 2 MiB with four indexes per table: 84,967,424 bytes
instead of 82,870,272. The inline sql-storage server profile stays at
12,684,176 bytes (its inline index slots are 8 x 4 x 8,192 = 262,144 bytes).

## Turning it on in RAMSQL

Add `.external_indexes = 4` (or fewer) to the `sql.Config` in RAMSQL's
`src/server.sig` (optionally `.table_indexes` to change the definition cap,
default 4). Nothing else changes: `storagePlan` already sizes the region
with `Raw.backingBytesFor(budgets, ref_count)`, `openStorage` binds it with
`bindMemoryFor`, and `describe` / `describeMachine` report and budget
`plan.bytes`, so the index bytes are counted, reserved and reported
automatically, per table from `table_versions` / `storage_versions`.

## Contract

`contract-sql-index-external` (tests/test_sql_index_external.sig) covers the
memory plans; CREATE INDEX and CREATE UNIQUE INDEX with index probes equal to
scans; 23505 on INSERT, UPDATE, multi-row statements and CREATE UNIQUE INDEX
over duplicates, each atomic; rollback and ROLLBACK TO with no stale entry;
version reclamation and a full arena; a unique-index race; ON CONFLICT with a
unique-index arbiter; DROP INDEX, composite indexes, ALTER TABLE, TRUNCATE and
a NULLS NOT DISTINCT unique index; CREATE TABLE LIKE INCLUDING INDEXES on
dirty memory; `copyFromInto`; replay into a second external database and
recovery into a third with a larger version budget; and the capacity edges
(54000 per slot and per definition, ChangeRecordConflict, invalid bindings).

Pending native verification (not in `postgres18_oracle.json`): the
PostgreSQL behaviour the contract asserts is the one the schema-objects lane
already asserts on inline storage (pg_indexes text, 23505 cases, ON CONFLICT
arbiters, NULLS NOT DISTINCT). 54000, 53200 and ChangeRecordConflict are ZPM
capacity results with no PostgreSQL counterpart.
