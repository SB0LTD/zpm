# Plain-query output demand and immutable diagnostics

This candidate addresses two recorded examples: selected immutable errors must
still be planned with WHERE FALSE/LIMIT0, and unused immutable outputs of plain
derived tables must not raise errors. Runtime implementation belongs entirely
to allocator-free ZPM L0 SQL. RAMSQL will pin an immutable qualified archive.

## Representation and order

Semantic binding completes before deferred constant errors are reported. Each
plan records its own clause error and one error per output, captured before
aggregate/window lowering can detach arguments from their CASE owner. Lowered
window input plans do not revalidate detached arguments. CASE/COALESCE and ordered
AND/OR simplification retain their native reachability rules; immutable is
stronger than retry-safe, so clocks, sequences and session-dependent operations
are never executed as planner constants.

After binding, a monotone fixed point propagates output requirements through
plain sources. A plan can be required for its row cardinality with no value
columns requested. ORDER BY, DISTINCT and join/filter references retain their
inputs. Multiple consumers merge their required columns. Multiply referenced
and recursive CTEs retain their materialized outputs. Group/window, set-operation
and correlated dependencies remain conservative. No output width or column number
changes; generic projection writes an initialized NULL into each suppressed slot.

Each plan owns fixed-capacity constant-value slots and known bits, bounded by
its existing output capacity. The binder can evaluate immutable expressions using
known outputs of plain, nonnullable derived sources. Cells own their values;
no expression subtree is copied, no node/depth metadata changes and no row buffer
is placed on the evaluator stack. Normal runtime column reads are unchanged.
The known-bit proof precedes every planner read; unknown slots are never read.
This handles numeric/text/date constants without borrowing another node's literal
span. Groups, windows, sets, correlation and nullable outer-join bindings remain
conservative. Stable/volatile producers are not treated as immutable constants. DISTINCT,
ORDER BY, syntactically present LIMIT/OFFSET (including OFFSET0), and shared or
recursive CTEs are propagation barriers. Fixed CTE-dependency sets invalidate cached bindings when later consumers
materialize a CTE. Checking a shared output does not recursively re-prove its
producer expression DAG; each check is bounded by configured CTE count and is
charged to execution control. A14-level doubling-DAG regression must fit a
20000-work-unit caller grant.

For execution-query roots, strict-NULL row comparisons now participate in the same live-expression walk,
instead of a global scan of orphaned AST nodes. Stored-schema and COPY validators
retain their separate source-aware checks. Semantic binding still checks
discarded expressions, while CASE/boolean reachability and required outputs decide
which constant diagnostics survive. Demand discovery defers SQL errors; selected
outputs retain priority over clause errors after complete semantic binding.

All added state is fixed-size per plan, derived from existing configured columns,
plans and CTE capacities. Required bits only move false to true; the fixed point
terminates after at most the available plan/output bits change. Existing query
checkpoint cancellation applies. Statement errors must preserve caller results
and mutation atomicity; clocks/sequences retain runtime ownership.

## Evidence and boundaries

The first new contract fails on unchanged main with InvalidPlanAccepted for
`sqrt(-1::numeric) WHERE FALSE`; its separate red log is retained. Local native
PostgreSQL16.15 supplies94 frozen cases for values/types, domain/overflow errors,
semantic-error priority, CASE/COALESCE/boolean reachability, joins, CTEs,
cardinality, sequence effects and failed DML. Four native Parse/Describe probes
separately establish metadata timing and semantic errors. Eighty one-shot
cancellation positions exercise speculative evaluation without losing an abort.
Metadata-only binding retains semantic/type checks and defers these execution
constant diagnostics. Native binaries came from the
[official EDB archive](https://www.enterprisedb.com/download-postgresql-binaries),
verified against the [vendor-published SHA256](https://github.com/EnterpriseDB/edb-installers/issues/696)
25e6fcdfb8caec38691bf461125e7564508760666f7b8e5dc6a5f0818f58f81e.
They run as a separate loopback test cluster, never as a system service.
The public verifier accepts an explicit native endpoint and records its version.

This is not complete planner parity. Aggregate/window-state liveness and unused
scalar-subquery projections remain open, along with broader pull-up, outer-join,
correlated and session-sensitive proofs. Native examples outside this scope are
retained in tests/sql_conformance/planner_demand_open.json, not counted as passing
parity. Configured numeric/AST/workspace capacities still apply. The original
118-program inventory remains an independent deliberately incomplete gate.

Core regression, fresh independent review, PG16/18 differential, all supported
platforms and exact-artifact release qualification remain required before merge.
No speedup or production-readiness claim is made by this correctness slice.

## Hosted read-context correction

The first hosted broad graph exposed a separate private ReadContext metadata
path that used executable preparation and raised DivisionByZero during Describe.
Its failing log is preserved; this was an introduced regression, not one of the
four legacy transport/media failures. ReadContext now has a metadata-specific
describe operation. It retains semantic checks and cancellation, always clears
its prepared plan on return, and cannot feed a metadata-only plan to run().
Executable preparation still reports immutable errors on empty inputs. Store
Describe uses this operation for private readers. A subsequent Store Execute
re-prepares against the same caller-held snapshot; cancellation/preparation errors
remain sticky rather than being silently retried. The extended parallel-read
contract checks error timing, unusable metadata plans, semantic errors and reuse.
