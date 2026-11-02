# Application compatibility closing plan

Baseline: qualified aggregate-demand SQL source fbaeee24; merged ZPM main also
contains Galaxy's unrelated network/ML integration. PostgreSQL16/18 are the
versioned behavioral references. The original118-program gap audit remains red;
its counts are not a compatibility percentage. All stages below are incomplete.

## Dependency order

| Stage | Scope | Evidence required before closure |
| --- | --- | --- |
| APP-01 | VARCHAR / CHARACTER VARYING first, then CHAR/BPCHAR | Native values/OIDs/typmods, character versus byte lengths, explicit versus assignment casts, NULL/trailing spaces, errors/atomicity, expressions/defaults/generated columns, binary parameters/COPY, catalog metadata, WAL/replay, snapshots, capacity/cancellation |
| APP-02 | BYTEA, UUID, TIME/TIMETZ and remaining common scalar types | Native codecs and operators, casts/overloads, metadata, durability and malformed/overflow tests; each type independently scoped |
| APP-03 | General UNIQUE and composite keys with reusable index primitives | NULL policy, conflicts within/between statements, concurrent arbitration, rollback/replay, index ownership and failure atomicity; no linear-scan-only scale claim |
| APP-04 | CHECK constraints, then foreign keys | Three-valued logic, validated immutable definitions, action ordering, deferred scopes separately, multi-table atomicity and concurrency |
| APP-05 | Schema lifecycle, ALTER/TRUNCATE, views and schema qualification | Dependencies, rename/drop behavior, prepared metadata, concurrent DDL and crash-safe catalog replay |
| APP-06 | Catalog and migration/application qualification | Independent real migration scripts and ORM clients; exact supported versions; report unsupported discovery/utility operations rather than accepting no-ops |
| APP-07 | Remaining relational/function families | LATERAL, grouping sets/CUBE, aggregate families, string/math/date functions; separately frozen native contracts |
| APP-08 | Security, transactions and operational compatibility | Roles/privileges, TLS/channel binding, stronger isolation, checkpoint/compaction, online backup, upgrade and fault evidence |
| APP-09 | Production scale and efficiency | Matched CI dbMeter plus representative100M-row multi-table workloads, sustained memory/version pressure, all-core throughput and tail latency; correctness gates first |

The next implementation is APP-01 VARCHAR, retaining text-backed caller-owned
cells while preserving a distinct type/OID and length modifier. CHAR/BPCHAR is a
separate follow-up: padding and comparison/hash rules cannot be approximated by
VARCHAR. Constraints depend on stable type/coercion and durable catalog behavior.

## Per-slice workflow

1. Freeze positive and negative observations from native PostgreSQL, including
   values, types, typmods, command tags, SQLSTATE and follow-up state/effects.
2. Add a generated allocator-free contract and observe the unchanged runtime fail.
3. Implement reusable behavior only in ZPM L0 SQL or the appropriate shared codec
   layer. RAMSQL remains integration/policy. Preserve immutable archive pins.
4. Exercise mutation failures, rollback/replay, prepared text/binary/COPY paths,
   cancellation, exhausted grants, poisoned reuse and concurrency where applicable.
5. Independently review the diff and declared scope. Qualify all supported hosts,
   native reference versions and exact release images before merging.
6. Publish successful full release matrices as non-latest prereleases. Reconcile
   the inventory with observed evidence; leave broader families explicitly open.

No stage is closed by parsing syntax, passing a smoke query or returning a mock
catalog row. No production/drop-in/universal-performance claim follows from a
finite slice. Dynamic machine admission does not remove configured value/schema
capacities; exceeding a resource budget must remain a recoverable, atomic error.
