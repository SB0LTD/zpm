# Costed allocator-free SQL execution design

Proposal, 2026-10-29. This document specifies experiments and correctness gates;
it does not claim that the proposed infrastructure is implemented or faster.
See the [conformance plan](../tests/sql_conformance/README.md) for language scope.

## Objective and limits of optimization

Choose a physical plan minimizing measured latency/resource cost for a declared
workload, subject to exact SQL semantics, durability, snapshot isolation rules,
caller-owned memory, cancellation and platform support. There is no universally
optimal plan across unknown distributions, read/write ratios and machines.

A useful lower bound is `T >= max(bytes_read / effective_bandwidth,
CPU_work / effective_compute_rate)`. Dependencies, synchronization, I/O and queueing
can only add time. Calibrate both rates on the target machine; this expression is
not a predictive proof or a claimed speedup. Track estimate uncertainty and
fallback when a plan's assumptions fail.

For a maintained access structure, require roughly
`read_rate * (scan_cost - indexed_cost) > write_rate * maintenance_cost + build_cost / amortization_horizon`,
subject to memory and recovery costs. This explains why the same design need not
win both a write-heavy workload and a stable analytical workload.

## Semantic foundation before physical specialization

Keep a typed logical expression/relational IR and a generic reference executor.
Every expression carries type/typmod, nullability, collation, volatility and
ownership. Reordering requires proof about NULLs, duplicates, errors, visibility
and observable side effects. An outer-join predicate cannot be pushed down solely
because it mentions one input. Division errors and sequence evaluation must not
vanish through an invalid rewrite.

The planner selects index/hash/merge/streaming or factorized joins. Physical
operators consume column batches or borrowed selections with explicit lifetimes;
they never retain pointers into statement pools past their owners. Retrying or
abandoning an optimized path cannot repeat volatile calls or publish partial rows.
Generic execution remains available for every supported expression.

## Physical storage and global memory ownership

Use typed, encoded immutable base blocks plus sparse changed-column MVCC deltas.
Avoid reserving a maximum-width variant Cell for every stored scalar. Integral
frame-of-reference blocks need `ceil(log2(max-min+1))` bits per non-null value,
with a full-width fallback and independent null map. Dictionary/RLE choices depend
on data distribution. Exact NUMERIC cannot be silently converted to float.

Account for `base + nullmaps/dictionaries + indexes + active_and_retired_deltas +
query_grants + IO_buffers + safety_headroom`. Allocation-free execution still needs
OS-backed regions or caller-provided budgets; it cannot promise infinite storage.
Machine discovery is an upper bound, not permission to consume every byte needed
by other processes. Admit queries from a shared global grant pool and report
resource errors without corrupting state. No full-table budget per table/client.

Maintain snapshot pins and a reclamation horizon before retiring base blocks or
deltas. Reserve/validate a commit and its log payload before durable flush;
publication of base and maintained structures follows successful durability.
Acceleration state has version/invalidation rules and a correct fallback.

## Execution candidates and research

These are design inputs, not imported runtimes or RAMSQL performance evidence.

| Candidate | Primary source | Integration experiment and rejection criterion |
|---|---|---|
| Adaptive factorization and multiway joins | [CIDR 2025](https://www.vldb.org/cidrdb/papers/2025/p21-gro.pdf) | Compare against tuple pipelines across skew/fanout/selectivity. Keep only paths with proven bag/NULL semantics and measured crossover rules; never factorize everything. |
| SIMD-oriented exact codecs | [FastLanes thesis, January 2026](https://ir.cwi.nl/pub/36173) | Prototype codecs in pure Sig behind existing storage interfaces. Measure decode throughput, update/recovery cost and bytes/value, with adversarial full-width fallback. |
| Runtime predicate transfer | [VLDB 2026](https://www.vldb.org/pvldb/vol19/p1278-qiao.pdf) | Filter semijoin candidates without false negatives. Test highly skewed joins, outer joins, snapshot changes, cancellation and build-memory exhaustion. |
| Selective late materialization | [VLDB 2025](https://www.vldb.org/pvldb/vol18/p4616-liu.pdf) | Choose per-column fetch timing using observed selectivity and gather cost. Reject when random gathers cost more than a sequential scan. |
| Shared window evaluation | [Window co-evaluation, 2026](https://arxiv.org/abs/2608.06043) | Share only compatible order/partition/frame state. Verify peer groups, NULL ordering, EXCLUDE and boundary behavior against native PostgreSQL. |
| Snapshot-consistent auxiliary accelerators | [JetStream preprint, October 2026](https://arxiv.org/abs/2610.20527) | Explore maintained structures over common transactional base data with explicit invalidation/recovery. Do not copy benchmark-specific answers or generalize the paper's reported speedups to RAMSQL. |

Use a single budgeted worker pool with dynamically sized batches/tasks, calibrated
per core/NUMA node. Independent concurrent queries share capacity; no one pool per
connection and no assumption that more workers always improve small lookups.
Measure parallel speedup, aggregate throughput, tail latency and fairness together.
Native query code generation is a later option only if profiles justify it and
code-page ownership/recovery remain compatible with allocator-free constraints.

## TDD and acceptance sequence

1. Build independent exact-value/type/error contracts and native-oracle fixtures.
2. Add generated small-table differential tests; bags, NULLs, duplicates and order
   are required. Add transaction/recovery and cancellation schedules separately.
3. Use [CODDTest](https://doi.org/10.1145/3709674) constant-folding metamorphisms,
   [SQLancer](https://github.com/sqlancer/sqlancer/blob/main/docs/PAPERS.md)
   partitioning/reference techniques and bounded [VeriEQL](https://arxiv.org/abs/2403.03193)
   reasoning where applicable. Bounded checks are not proofs for arbitrary data.
4. Introduce one physical change behind a deterministic forced-path switch; verify
   optimized vs reference results and state before any throughput measurement.
5. Profile separately from throughput campaigns. Record cycles, bytes, branches,
   cache/TLB misses, allocation/region grants, scheduling and synchronization.
6. Benchmark unchanged reviewer workloads plus independent skew/null/wide/text,
   complex-join, mutation and 100M-row-per-table cases on documented hardware.
   Actual database SQL tests are required; a packed-array microbenchmark does not
   establish large-table SQL support. Run paired randomized order with confidence
   intervals, including cold/warm state and concurrent read/write clients.
7. Publish source SHA, flags, raw measurements and regressions. Claim superiority
   only over named versions/workloads demonstrated by reproducible runs.

## Quantified comparisons: implemented normalization and next physical step

The scalar-subquery implementation normalizes `x op ALL(Q)` to
`NOT (x opposite(op) ANY(Q))`. SQL's three-valued De Morgan duality preserves
empty sets and NULLs. This reuses the IN/ANY sublink and its existing negation bit
without enlarging expression nodes. Six ordinary comparison operators are covered;
array, row, LIKE/ILIKE and custom-operator forms still need their own contracts.

The current executor materializes the subquery in caller-bounded workspace. That
is a known physical limitation, not a claim of constant-memory execution. A future
streamed reducer can use `(row_count, nonnull_count, min, max)` for inequalities:
`x < ANY(Q)` depends on the maximum non-null value, while `x > ANY(Q)` depends on
the minimum. Universal inequalities follow through the same De Morgan rule.
`x <> ANY(Q)` and `x = ALL(Q)` also admit exact extrema summaries. NULL/empty
state remains explicit. Summarize in the resolved comparison type domain; the
mixed REAL/exact-number precision bug demonstrates why raw-type conversion rules
cannot be guessed from common-result typing.

Extrema and counts cannot answer arbitrary equality membership: `{1,1,3}` and
`{1,2,3}` have identical counts/min/max but differ for `2 = ANY(Q)`. That path
needs an exact set, suitable index or streamed comparisons. A Bloom filter can
reject impossible matches; it cannot certify SQL equality. Maintained summaries
must cover the exact predicate and visible snapshot, with correct update/delete
invalidation. None of these future physical reducers is implemented by the
normalization change.

## Layer ownership

ZPM owns reusable AST/binding/type rules, relational operators, storage and
resource/protocol primitives. RAMSQL owns listeners, deployment policy, durability
orchestration and server-level integration. Sig owns language/compiler support.
New SQL features must not depend on a higher-layer RAMSQL runtime. Native database
servers and Python are test oracles/tools only, never production dependencies.
