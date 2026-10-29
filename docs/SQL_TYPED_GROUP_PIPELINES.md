# Close execution coverage before tuning already fast kernels

Status: opt-in typed multi-aggregate implementation; correctness qualification
in progress. No throughput gain or production qualification is claimed.

## What the CI result actually says

[dbMeter CI attempt 2](https://github.com/benor1470/dbMeter/actions/runs/40859947997/attempts/2)
used a public Linux runner reporting four logical CPUs and 16,760,344,576 bytes
of RAM. RAMSQL source was `833e48be9d202c291561edbfbd511b2b4faa809f`.
The original 1M-row mixed workload passed its checks but lost to IRDB. Separate
original-case diagnostics show the customer aggregate winning and the selective
store aggregate winning at eight clients. These are different workload results,
not contradictory measurements or proof of general superiority.

Across all three RAMSQL single-client mixed trials, original histogram `sum`
and `count` fields attribute measured JDBC query time as follows. This is
client-time attribution, not sampled CPU profiling or a new local benchmark.

| Case | Mean query latency | Share of summed query latency |
| --- | ---: | ---: |
| Region aggregate | 9.450 ms | 2.33% |
| Category / distinct customers | 172.694 ms | 20.84% |
| Top products / two sums | 114.059 ms | 26.58% |
| Segment / discount grouping | 194.005 ms | 48.55% |
| Customer producer/consumer aggregate | 6.556 ms | 0.81% |
| Selective store/category aggregate | 1.733 ms | 0.89% |

Eliminating the last two query costs entirely would improve this observed
single-client mix by only about 1.7%, assuming its query distribution remains
fixed. Faster kernels for those two cases cannot close the mixed-workload gap.

## The architectural gap

The executor has useful typed islands, but their admission shapes are narrow.
The existing wide dense kernel requires COUNT(*) plus one SUM; compact grouping
rejects wide BIGINT measure inputs; factor-before-join excludes distinct
aggregates and fact-column grouping keys. Ordinary execution remains correct,
but switching to it restores per-row Cell/visibility/expression/grouping costs.

The next work is broader typed operator coverage, with ordinary SQL as a
semantic fallback. Cells should represent final SQL results and uncommon
expressions, rather than becoming the obligatory intermediate for every row.
[DuckDB's execution format](https://duckdb.org/docs/current/internals/vector)
and [push-based operator pipeline](https://duckdb.org/docs/current/internals/overview)
illustrate the general principle; they do not establish a RAMSQL speedup.

## First implementation: typed aggregate channels

`typed_grouped_aggregates` defaults to false. It fills uncovered committed,
unfiltered, one-integral-key GROUP BY shapes with direct COUNT/SUM/AVG channels.
Existing synopsis, compact and specialized wide kernels retain priority.
Unsupported DISTINCT, FILTER, expressions, visibility and workspace conditions
retain the existing executor.

For domain D and A aggregate channels, private state is proportional to D*A,
not the number of fact rows. Each channel carries an exact i128 sum and a
nonnull count; an independent row count distinguishes absent from all-NULL
groups. A separate NULL-key bucket preserves grouping semantics. SQL Cells are
created only for final groups, using the existing HAVING/projection/order/limit.

State borrows the caller's query arena. Domain admission includes conservative
final projection/reference space. No persistent cache, new backing allocation,
query-text recognition or CTE answer cache is introduced. The current projection
is used only when snapshot and publication evidence permits it. Checked-i64 SUM
requires a proof that every accumulation prefix fits; wide sums use exact i128
under the stored-row ceiling and ordinary NUMERIC finalization. Cancellation
and work-limit errors leave output private.

## Follow-through

1. Qualify this kernel against canonical execution, an independent scalar
   oracle, snapshots, private writes, replay, failure atomicity and small budgets.
   Measure improvements only in CI, retaining every original check and case.
2. Precontract eligible unique-key dimension paths into compact group IDs, then
   combine them with fact grouping keys. This targets segment/discount grouping
   without one customer-version probe and text hash per fact. Preserve missing
   keys, NULLs, nonunique-join bags and checked arithmetic.
3. Extend typed grouped DISTINCT using bounded per-group membership structures;
   budget by group/domain cardinality and fall back when dense bitmaps lose.
4. Replace padded base-version Cell arrays with typed base columns and bounded,
   snapshot-safe MVCC deltas. Current duplicate scan columns do not remove the
   documented 120GB/100M-version payload problem.
5. Introduce one global bounded pool of scan/reduction tasks for intra-query
   parallelism, with per-query grants and exact merge/error behavior. More
   connections already provide inter-query concurrency; they do not parallelize
   one scan.

SQL compatibility gaps remain independent: date formatting, windows and ROLLUP
still prevent the original full-suite qualification. Keep the dbMeter PR held
until its unchanged complete gate passes. A faster selected read or a green
correctness test is not that gate.
