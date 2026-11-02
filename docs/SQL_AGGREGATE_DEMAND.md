# Aggregate-state demand candidate

Status: runtime candidate, not qualified for merge or release. The historical red
plan/evidence remain in SQL_AGGREGATE_DEMAND_PLAN.md and the red evidence manifest.
The original118-program audit remains a separate incomplete gate.

## Layer, state and dependencies

Runtime changes belong to allocator-free ZPM L0 SQL. Each existing Plan gains a
fixed boolean array bounded by Config.columns, one slot for each registered
aggregate. No heap, AST expansion, producer subtree copying, output compaction or
row-width change is introduced. Output demand and aggregate-state demand form a
monotone fixed point; keys always retain cardinality dependencies, and lowered
group columns identify the required aggregate slots. HAVING, hidden ORDER BY,
DISTINCT, materialized/shared/recursive CTEs and volatile outputs retain required
work. Non-query binding, correlation and windows retain conservative boundaries.

Output pruning admits aggregates only through a separate immutability walk mode.
Generated-column/default restrictions keep their previous aggregate prohibition.
Full semantic binding still rejects invalid discarded expressions before deferred
planning diagnostics. Pre-lowering per-output diagnostics remain attached to their
own outputs; the demand pass never evaluates an aggregate.

## Execution and fallbacks

Generic grouping, streaming accumulation, DISTINCT layouts/updates, summary
states, ROLLUP transitions and finalization skip unneeded states. Suppressed slots
are explicitly initialized NULL; all indices and group cardinality remain stable.
Global aggregation over empty input still yields one row; ordinary GROUP BY empty
input still yields none. Reused/poisoned caller storage must never supply a value.

Specialized transitions decline partial-state layouts and use the existing
bounded generic streaming operator. All-live typed/factorized paths remain
eligible. One narrow fused-producer exception preserves its pure unfiltered,
non-DISTINCT COUNT(*) as an internal group-presence channel. It has no expression
or side effect, and bounded row identifiers keep its count representable. This
does not re-admit an unused SUM or expose a logically suppressed output.

LIMIT0 now stops query execution before aggregate/sort/window/set inputs start.
Binding still performs semantic and required immutable planning diagnostics.
Cancellation is checked even on the empty runtime return. The older LIMIT0
statistics assertion now requires zero scanned rows, rather than the prior two.

## Test-first evidence and qualification required

The frozen50-program PostgreSQL16.15/18.3 corpus originally reproduced25matches /
25gaps on ef6e3c0. Native-only calibration run41407604728 matched all50 expected
programs on both pinned versions; it intentionally does not qualify host execution.
The candidate's development core run passes50/50. The shared build contract is
registered as contract-sql-aggregate-demand, generated deterministically from the
fixture by tools/generate_sql_aggregate_demand.py.

New physical-path tests first failed on the unchanged runtime: a100000-row partial
aggregate with1024 query handles, a factorized join and a typed grouped query.
The factor/typed probes compare results with their existing independent models
and canonical executor while requiring the explicit partial-state fallback.
Compact gathered_rows counts transient row reconstruction, not stored input;
stream rows/groups and caller scratch bounds prove the intended operator.

The large streaming test also exercises mid-execution cancellation/work exhaustion,
unchanged previous results and zero lock/transaction ownership, poisoned reused
cells/refs, and reader/private-write visibility. Existing all-live specialized
path assertions must continue to pass. Final source reruns, independent runtime
review, PG16/18 wire/parameter modes, full platform/product/exact-release gates
are required before merge. No benchmark speedup is claimed.

Independent runtime review found no introduced blocking defect. It replayed the
50-program native16.15 corpus, generator check, aggregate contract and132 generated
restriction assertions, then compared adversarial probes against isolated HEAD
and the candidate. This approves the bounded implementation for qualification;
it does not replace the outstanding platform/product gates.

## Open boundaries

This does not close aggregate or general planner parity. DML-root demand remains
conservative; unused scalar-subquery projections, broader windows/correlation,
STABLE/session-sensitive pruning and other optimizer proofs remain open. The
separate high-exponent numeric-literal capacity finding remains open. Configured
numeric precision, AST, result, table and workspace capacities still apply.
The fallback preserves correctness and bounded streaming, not a claim of optimal
factorized performance for every partial-state query.

AGG-BOOL-ABSORBER-01 remains open and predates this change. With input v=0,1,
`SELECT SUM(1/v)>0 AND FALSE FROM t` and the corresponding `OR TRUE` return
false/true on native16.15, while both HEAD and candidate raise DivisionByZero.
Native also eliminates sequence calls in the analogous SUM(nextval(...)) forms;
both host versions still consume them. Right-hand absorbing boolean simplification
needs a separate native-backed contract preserving immutable planning errors and
volatile evaluation rules. The current output-demand slice does not close it.
