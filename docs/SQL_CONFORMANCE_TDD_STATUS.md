# SQL conformance TDD checkpoint

2026-10-29. Branch `feat/sql-conformance-tdd`, isolated from concurrent RAMSQL
performance work. Baseline: ZPM `53655a9a89a3ddff6f2f5829388b09a10c3d9c93`.

## Implemented in this batch

- Scalar `IS DISTINCT FROM` and `IS NOT DISTINCT FROM`: grammar, common comparison
  binding, non-null Boolean evaluation and expression deparsing. The evaluator
  borrows stable column operands and evaluates computed operands once. Existing
  unsupported fast paths conservatively fall back to generic execution.
- `GREATEST` and `LEAST`: special SQL grammar forms, common argument typing,
  PostgreSQL NULL exclusion, ordering over supported comparable scalar types,
  eager argument evaluation and schema-expression round trips. Quoted ordinary
  function names do not acquire these special semantics.
- Neither feature adds heap allocation, platform dependencies or a higher-layer
  RAMSQL dependency to the SQL core. Existing caller storage and work/cancellation
  contracts remain in force.

## Evidence

Both contracts failed before implementation: `Syntax` for null-safe equality and
`UndefinedFunction` for `GREATEST`. The recorded red outputs, exact source hashes,
toolchain and regression outputs are in
[evidence.json](../tests/sql_conformance/evidence.json).

The null-safe comparison suite passes 917 assertions in Windows ReleaseSafe and
Debug, including three-by-three typed NULL/value truth tables for 15 orderable
scalar families. Other cases cover mixed types, NaNs, aggregates and right-side
subqueries, joins, volatile sequences, errors, default/generated-expression replay,
work limits and cancellation. The min/max suite passes 49 assertions, covering
NULLs, common types, ordering, side effects, errors and schema replay. Its 23
positive/negative SQL examples were also checked on native PostgreSQL 18.3.

Existing expression, type, query, catalog, change-log, compact-scan and DML suites
pass on the changed SQL core. Harness tests verify wire fragmentation, NULL versus
empty text, Unicode, duplicate-preserving bag comparison, type/typmod metadata,
error rejection, and versioned manifest/evidence consistency.

This is Windows validation, not all-platform qualification. Prepared-wire behavior,
concurrent schedules and crash durability require integration-level closure.

## The broad audit remains red

The [inventory](../tests/sql_conformance/README.md) contains 118 stable smoke
programs. Native PostgreSQL 18.3 accepted all 102 transaction-harness programs;
16 require additional execution scopes. Expected results are checked into
`postgres18_oracle.json` with a manifest SHA-256, and generate an allocator-free
Sig core test executable.

Current core results: **2 smoke passes, 99 failures, 17 unexecuted scopes or
comparators**. A smoke pass does not close a full feature family. A core utility
rejection also does not establish what the server integration implements. The
suite intentionally exits with an error until the declared scope is qualified.

The separate PostgreSQL upstream inventory contains 755 standard feature records.
Their applicability/mapping is still unreviewed. Many routines, overloads,
administrative features and dialect-specific behaviors need additional contracts;
118 probes are not an exhaustive compatibility test suite.

## Next batches

1. Quantified comparisons, row predicates and remaining predicate syntax: extend
   native-oracle negative/type/NULL tests first, then bind and execute one form at
   a time. Add expression-level differential/metamorphic generation.
2. Expand semantic typing/function contracts, then relational composition,
   windows and grouping; retain independent reference execution and explicit
   optimizer legality checks.
3. Schema/dependency/constraint and DML features, including WAL failures and replay.
4. Multi-session transaction, locking, security, routine, COPY, catalog and native
   dialect harnesses. Adjudicate every applicable upstream feature before a full
   compatibility claim.
5. Apply the [costed execution design](SQL_EXECUTION_REDESIGN.md) through measured,
   separately tested physical implementations. Typed base blocks, MVCC deltas,
   shared task scheduling and adaptive operators remain proposals until validated.

No release or performance-superiority claim follows from this checkpoint. The
next release decision needs the declared SQL scope, integration/system evidence,
and reproducible workload results in addition to these core regressions.
