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
[evidence.json](../tests/sql_conformance/evidence.json). This is the historical
first-batch record at `a7c4695`, not evidence for later changed source.

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

## Second batch: quantified scalar subqueries

`ANY`, `SOME` and `ALL` now support the six ordinary scalar comparison operators
over one-column subqueries, including correlated queries, CTEs, set-operation
results and aggregate operands. IN and quantified forms share binding and the
same evaluator. `ALL(op)` is normalized to `NOT ANY(opposite(op))`, preserving
three-valued logic without enlarging expression nodes. Ordinary non-associative
comparisons and valid post-sublink casts/operators have native-oracle tests.
New ANY/SOME keyword reservation preserves the frozen alpha identifier behavior.

The focused suite passes 3,582 assertions in ReleaseSafe and Debug on Windows.
Native PostgreSQL 18.3 passes all 1,152 generated NULL/empty/subset/operator cases
and 42 additional positive/negative SQL probes. Both implementations produce
matrix digest `7886b30b421deb63`; the digest identifies the finite test matrix,
not a proof for arbitrary SQL. Native evidence is
[quantified_oracle.json](../tests/sql_conformance/quantified_oracle.json).
All 26 default SQL contract executables pass in ReleaseSafe: 440,666 assertions.
The complete outputs, source hashes, red-before-green failures and Debug result
are in [quantified_evidence.json](../tests/sql_conformance/quantified_evidence.json).
Validation paused while another shared-host benchmark ran, then resumed the
unchecked contracts after that campaign completed. These are correctness results,
not throughput measurements.
Sig-only tests additionally check cache reset across statements, READ COMMITTED
and own-write/abort visibility, frozen replay names, work/cancellation errors,
workspace exhaustion and unchanged results after failures.

The tests found and corrected two shared issues: JSON equality was incorrectly
accepted by IN subqueries, and mixed REAL/exact comparisons rounded exact operands
to REAL instead of selecting the float8 comparison domain. Common-result typing
for GREATEST/CASE remains distinct from operator comparison typing. The default
expression-contract database footprint remains 315,168 bytes after normalization.

This is partial SELECT-context quantified-comparison support. DML contexts remain
unqualified. Array/row forms, LIKE/ILIKE and
custom operators remain open. The executor still materializes subqueries in
bounded workspace; it does not yet have constant-space streamed reducers for
large subquery results. Server wire preparation, crash/replay integration and
all-platform qualification remain separate work.

The semantic reference is PostgreSQL 18's
[subquery expressions](https://www.postgresql.org/docs/18/functions-subquery.html);
[row and array comparisons](https://www.postgresql.org/docs/18/functions-comparisons.html)
are separately specified and must not be inferred from these scalar-subquery tests.

## The broad audit remains red

The [inventory](../tests/sql_conformance/README.md) contains 118 stable smoke
programs. Native PostgreSQL 18.3 accepted all 102 transaction-harness programs;
16 require additional execution scopes. Expected results are checked into
`postgres18_oracle.json` with a manifest SHA-256, and generate an allocator-free
Sig core test executable.

Current core results: **3 smoke passes, 98 failures, 17 unexecuted scopes or
comparators**. A smoke pass does not close a full feature family. A core utility
rejection also does not establish what the server integration implements. The
suite intentionally exits with an error until the declared scope is qualified.

The separate PostgreSQL upstream inventory contains 755 standard feature records.
Their applicability/mapping is still unreviewed. Many routines, overloads,
administrative features and dialect-specific behaviors need additional contracts;
118 probes are not an exhaustive compatibility test suite.

## Next batches

1. Row predicates, remaining quantified forms and predicate syntax: extend native
   negative/type/NULL tests before implementation. Add streamed subquery reducers
   behind independent result/state tests and explicit workspace accounting.
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
