# Budgeted window frames and aggregate FILTER

Implementation candidate, 30 October 2026. The reusable implementation lives in
`src/core/sql/`; PostgreSQL SQLSTATE mapping lives in `src/db/postgres.sig`.
RAMSQL owns server integration and independent PG16/PG18 qualification.

## SQL scope

Existing RANK, DENSE_RANK, ROW_NUMBER and ordinary aggregate windows now accept
ROWS and GROUPS bounds, integral-key RANGE offsets and all four exclusions:
EXCLUDE NO OTHERS, CURRENT ROW, GROUP and TIES. Bounds admit UNBOUNDED
PRECEDING/FOLLOWING, CURRENT ROW and scalar offsets PRECEDING/FOLLOWING.
GROUPS requires ordering; offset RANGE requires exactly one integral ordering
key. RANGE without offsets uses peer boundaries for any supported sortable key.
Ascending/descending keys and explicit NULL placement retain their meaning.

Aggregate FILTER is evaluated before its argument. A NULL or false filter does
not evaluate the argument. Complex moving-frame inputs run only for selected
frame rows; expressions on rows outside every frame cannot introduce errors.
Immutable constant roots are checked during binding, including a constant
division by zero beneath a false FILTER. This is focused constant-expression
handling, not a complete PostgreSQL optimizer or constant-folding implementation.
Ordinary aggregates inside a window FILTER are grouping errors (42803);
nested/misplaced windows are windowing errors (42P20). Ranking FILTER and
DISTINCT window aggregates remain unsupported (0A000); PostgreSQL also rejects
DISTINCT window aggregates.

Offsets cannot refer to query columns or correlated inputs. Uncorrelated scalar
subqueries and parameters use the existing typed expression machinery. Aggregate
frame offsets execute once per window/query, even with empty input; NULL and
negative values report 22004 and 22013. Ranking ignores runtime frame offsets.
LIMIT 0 skips window execution while preserving binding errors. Illegal bound
categories report 42P20; arithmetic uses widened values before clamping, including
int64 extrema and offsets. Empty frames retain each aggregate's empty semantics.

Windows consume WHERE/grouping/HAVING output. Final DISTINCT, ordering, OFFSET
and LIMIT follow window evaluation. When deterministic targets are trivial
columns/literals and final ordering uses bound columns without DISTINCT, input
handles are ordered/trimmed before projection. Complex deterministic targets
retain eager projection. Unsorted volatile/nonrepeatable targets are deferred
until their rows are returned, even when another target requires eager output.
That path preserves original input ordinals through sorting using contiguous
output cells, without a per-row mapping allocation. Targets used for sorting or
DISTINCT must execute before those operations. No reviewer SQL is rewritten.

Independent CI exposed a native-version disagreement for `SELECT id,10/(id-1),
SUM(v) OVER () FROM compat ORDER BY id DESC LIMIT 1` with ids 1..3: PG16
returns a row, while PG18 raises 22012. The initial candidate matched PG16; the
revised complex deterministic path follows eager PG18 behavior. The contradictory
native results are retained in RAMSQL's progress evidence; this error-timing
difference remains documented rather than claiming both plans agree. Portable
differential projection checks filter out the invalid denominator or select the
invalid row. Original dbMeter SQL and expected results are untouched.

## Algorithms and caller memory

After sorting, partition and peer boundaries are found with charged scans.
Positional ROWS bounds take constant work; GROUPS uses the peer boundary array;
integral RANGE performs two binary searches per row over non-NULL ordered keys.

For materialized safe inputs, COUNT, integral SUM/AVG and Boolean aggregates use
exact prefix states (`i128` total and `i64` count). A frame uses prefix differences;
exclusions remove their intersections and TIES retains the selected current row.
State construction is O(N), followed by constant aggregate work per frame. The
range-bound searches and sorting retain their separate costs. MIN/MAX use a
segment tree of input ordinals: O(N) construction and O(log N) range queries,
including excluded frames, without duplicating full SQL Cells.

Safe direct-column comparisons and Boolean FILTER predicates can be materialized
once and use the same fast paths. Complex arguments/filters preserve deferred
evaluation through the scalar path. Numeric/float SUM/AVG and other complex
moving expressions may scan each selected frame; this candidate does not promise
linear work for all aggregates. Volatile/subquery moving aggregate arguments or
FILTERs fail explicitly with 0A000 until their transition/restart semantics are
implemented. Unbounded existing paths retain volatile input evaluation and do
not deduplicate volatile expressions between windows.

All input, output, peer, prefix and tree storage borrows the caller's existing
query arena; scratch is released between windows. If the optional prefix/tree
state does not fit, execution uses the work-budgeted scalar path. Mandatory
materialization and peer buffers can still exhaust capacity with a SQL error.
The dependency/window count uses Config.columns; expression and plan budgets
also remain finite. There is no heap allocator, persistent result cache, new
storage format or WAL change. Sorting, scans, searches, tree operations, scalar
visits and publication check work/cancellation budgets. Failure preserves the
previous published result.

## Evidence and remaining gates

`tests/test_sql_window_frames.sig` replays 397 real PostgreSQL 16.15 reference
queries. `tests/evidence/window-frames-pg16.json` records the setup, version and
exact TSV SHA-256. Additional contracts cover SQLSTATEs, sequence side effects,
snapshot/private-write visibility, poisoned memory, constrained-grant fallback,
large integer totals and exhaustive checkpoint cancellation/work-limit sweeps.
Operation counters assert prefix/tree execution instead of quadratic rescans for
eligible inputs. The contract is part of `test-sql` in hosted database CI.
No local throughput measurements are evidence for this candidate.

Named windows; remaining built-in functions such as LAG/LEAD/value windows;
numeric/float/temporal offset RANGE; volatile moving inputs; correlated subqueries
in a window target; and broader grouping-set support remain open. Full hosted
matrix, PG16/PG18 memory/durable+SCRAM and original workload evidence must follow
the final pinned source. Materialized windows do not establish 100M-row capacity,
full PostgreSQL compatibility, production readiness or a benchmark advantage.

Semantics references: PostgreSQL 18
[window syntax](https://www.postgresql.org/docs/18/sql-expressions.html#SYNTAX-WINDOW-FUNCTIONS)
and [window functions](https://www.postgresql.org/docs/18/functions-window.html).
