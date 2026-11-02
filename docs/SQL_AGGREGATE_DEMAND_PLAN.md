# Aggregate-state demand gap-closing plan

Status: test-first investigation on a separate branch; implementation is missing.
This does not change the original118-program inventory or claim SQL compatibility.
The baseline is ZPM ef6e3c0486ca76a3bfe70f3d91acda22c7491c16, still under hosted
qualification in PR97 when these observations were captured.

An unused calculation such as SUM(1/0) currently makes a derived query fail even
when its parent only requests the number7. PostgreSQL can return7 in that case.
It still raises division-by-zero if ORDER BY, DISTINCT or a shared materialized
CTE needs that aggregate result. Volatile sequence calls must retain their native
effects. Simply removing a binder barrier would hide required dependencies while
leaving optimized aggregate execution inconsistent.

Sixteen probes match native PostgreSQL16.15 reference observations at the wire.
On the baseline, six match and ten expose gaps. The standalone allocator-free
contract reproduces exactly6matches/10gaps, exits1 SqlAggregateDemandIncomplete,
and checks OIDs, integer values, row counts and sequence effects. It is deliberately
not registered in the green regression aggregate. The frozen native events and
source hashes are retained; PG18 characterization and broader adversarial dimensions
remain required. Passing the existing six examples does not close a feature.

Current qualified-candidate work only suppresses plain derived projections.
The grouped/window barrier remains explicit in binder.planOutputDemand.
Removing that barrier alone would be wrong: generic grouping, streamed/factorized
transitions and group-row finalization still evaluate every registered aggregate.

## First native-backed red cases

Retain existing planner_demand_open.json examples, then add native16/18 cases for:
- unused SUM(1/0), mixed live/dead aggregate outputs and empty input;
- GROUP BY, HAVING, hidden ORDER BY, DISTINCT and LIMIT/OFFSET dependencies;
- shared aggregate deduplication and live/dead FILTER, DISTINCT aggregate inputs;
- volatile sequence arguments and filters, CASE reachability, semantic error priority;
- ROLLUP/cardinality and repeated/shared/recursive CTE materialization barriers;
- bound/binary execution, repeated prepares, snapshot/private-write consistency;
- cancellation at each phase, exhausted grants, poisoned workspace/results, failed DML.
Native results must decide volatile behavior; do not infer it from immutability or
reuse an execution-totality proof as a side-effect proof.

## Representation and implementation boundaries

1. Keep output width and group-row indices stable. Add fixed caller-owned aggregate
   demand bits bounded by existing aggregate capacity; no heap and no AST expansion.
2. Teach dependency discovery about lowered group_relation columns: keys retain
   cardinality dependencies, aggregate slots retain their args and FILTER only when
   semantically live. HAVING/ORDER/DISTINCT and non-prunable effects retain producers.
3. Preserve pre-lowering output diagnostics and native error priority. Full semantic
   binding remains mandatory for pruned expressions.
4. Preserve one row for ungrouped aggregation over empty input, grouped bags and
   all conservative ROLLUP/CTE barriers. Do not conflate cardinality with value demand.
5. Initialize every suppressed aggregate slot to NULL. Update generic aggregate
   evaluation, streamed transition initialization/update/finalization, and projection.
6. Initially refuse optimized transition/factorized paths with unproven partial-state
   demand; use a tested generic fallback. Never silently omit a required state.
7. Keep window and scalar-subquery output liveness separate until their ordering,
   frame, correlation and volatility proofs have native-backed coverage.

## Qualification

Test first, independent review, full existing grouped/window/rollup suites, original
118-program audit with honest incomplete exit, PG16/18 wire modes, all supported
platforms and exact release qualification. No family closure or speedup claim from
passing these finite cases. This file is a next-slice investigation note, not evidence
that the work is implemented.
