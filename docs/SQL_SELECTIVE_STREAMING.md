# Selective streaming joins and research direction

2026-10-28. This document distinguishes implemented execution changes from
research candidates. It does not claim benchmark leadership or full SQL parity.

## Implemented path

The reviewer-style fact/products/categories query starts with a selective
integral store predicate, followed by typed DATE comparisons. The existing
all-or-nothing early-filter test rejects the DATE expression and postpones
every predicate until after dimension probes. The instruction-pointer profile
of the actual five-million-row workload identifies repeated dimension lookups
and tuple traversal as major remaining costs after workspace-admission repair.

The streaming cursor now applies a safe leading conjunct in blocks of 64 fact
slots. It computes an exact selection mask from the committed integral
projection, then borrows full MVCC rows and probes dimensions only for survivors.
LLVM uses the existing vector comparison implementation; other backends retain
its scalar implementation. Storage, results and query arenas remain caller-owned.
The extra selection state is a fixed mask, position and predicate descriptor.
There is no query-answer cache, precomputed workload answer or input-sized list.

Eligibility requires the current committed projection, a non-null integral
column/literal comparison at the left edge of WHERE, and inner unique-key join
streaming. Conservative domain bounds disable a predicate that cannot reject
anything. Old snapshots, own writes, nullable prefixes and unsupported
expressions retain canonical evaluation. Every surviving row still evaluates
the complete WHERE clause before aggregation.

Moving rejection across a throwing ON clause or computed probe key would hide
an error. A conservative integral comparison proof now guards both the new
prefix path and the existing early WHERE movement in general/streaming joins.
The regression catches the previous suppression of division-by-zero in ON when
a later WHERE predicate is false. Result publication remains atomic on errors,
work limits and cancellation.

The independent 257-row model covers all six comparisons, reversed operands,
partial blocks, nullable/missing dimension keys, committed deletion, pinned old
snapshots, own writes, NULL/error ordering, unselective bounds and poisoned
scratch. It passes 284 assertions on Windows/Linux ReleaseSafe and the legacy
Sig 0.5.9 Linux Debug compiler. The initial fixture
performs 472 dimension probes before the optimization and 59 for its selective
store case after it; these are operation counts, not throughput measurements.
The existing 100k streaming and full SQL contracts remain separate requirements.

### Plan-local projection and visibility masks

Fact-column discovery now walks the current bound plan's expression roots,
including aggregate arguments/FILTER, grouping, WHERE/HAVING, targets and hidden
sort targets, DISTINCT ON and join predicates/probe keys. Relation indices are
local to each query block: scanning the entire statement pool previously let an
unrelated outer TEXT column disable a CTE's integral projection. Unsupported
expressions, excessive traversal or nonintegral fact dependencies retain the
canonical typed/MVCC path. The walk uses a depth and visit budget without heap
storage. CASE arms, argument lists and aggregate FILTER dependencies are covered
by independent scalar-answer regressions with poisoned scratch.

Live masks are shared by compact aggregates, projected filters and streaming
prefixes. LLVM batches sparse visibility bytes; other backends use a scalar
fallback. A valid current committed summary proving every scanned slot is live
allows a full mask without reading flags. Required-column non-null counts can
similarly avoid per-row null-mask loads. These proofs never apply to old
snapshots or a transaction's private writes. A pinned snapshot retaining a
deleted slot exercises the sparse path.

### Typed DATE projection

The next profile identified canonical fact-row borrowing as the largest sampled
active-code cost. DATE dependencies previously forced that path even though a
date is exactly an i32 day count. Durable publication and validated change-record
replay now write this payload into the existing i64 column-major backing.
Streaming projection reconstructs a DATE-tagged Cell, including NULL, negative
day counts and both infinity sentinels. This changes no backing size, persistent
record encoding or SQL comparison semantics. Other unsupported types still use
canonical versions. The final WHERE and aggregation evaluators remain unchanged.

Differential tests explicitly disable committed metadata and compare results
against canonical MVCC execution. They cover DATE MIN/MAX/COUNT, negative and BC
dates, infinities, nulls, private writes/abort, a pinned old snapshot, deletion,
copying into independent poisoned backing, failed durable flush, and applying
validated update/delete change records. Only durable publication/replay changes
the projection; a flush failure leaves both visible answers and projected values
unchanged.

### Caller-backed wide grouping

The five-million-row customer aggregation's follow-up profile is dominated by
group-key comparisons and per-row aggregate dispatch. A current committed,
single-source grouping with a bounded integral key, COUNT(*) and an integral
wide SUM/AVG can now use direct arithmetic buckets. Each bucket stores row
count, non-null count and an exact signed i128 total in bytes borrowed from the
existing query arena. It admits the entire conservative key domain only when
the caller's remaining scratch can hold state, output and finish handles;
otherwise the original collision-safe engine remains available. There is no
fixed 4096-key optimization cutoff, input-sized list or query-answer cache.

Storage references allow at most 2^31-1 rows. Even an i64 extreme per row has
total magnitude below 2^94, so i128 arithmetic is exact for every admitted
input, including cancellation between positive and negative values. NULL group
keys have a distinct bucket, and all-NULL sums remain NULL. The existing numeric
SUM/AVG finalizer, HAVING, projection and ORDER BY remain authoritative. The
general path handles filters, unsupported aggregates, sparse/widened domains,
old snapshots and private writes. This is an execution specialization, not a
larger compile-time array or a storage-format change.

A 12,011-row, 5003-key independent model exercises signed i64 extremes and
totals beyond i64, null keys/values, swapped aggregate order, exact AVG
comparison, pinned snapshots, retained tombstones, aborts, work cancellation,
empty results and extreme key intervals. Metadata-disabled execution supplies
an additional canonical differential check. Full workload timing is required
before claiming a performance advantage.

## Current research and applicable next experiments

### Proven narrower aggregate state

Wide grouped arithmetic now chooses a 16-byte `{i64 total, i64 rows}` state
when committed metadata proves the input non-null and its conservative bounds
prove every possible accumulation prefix fits i64. For live row count N and
input bounds [L,H], require `N*min(L,0) >= i64_min` and
`N*max(H,0) <= i64_max`, computing the proof in i128. Every group and every
partial sum contains at most N values, so this bounds partial sums even with
mixed signs; a small final total alone would not establish the proof.

The existing 32-byte exact i128 state handles nullable inputs, wider/unproven
bounds and old snapshots/private writes as before. Input bounds include
uncommitted and aborted versions, so an aborted extreme safely removes the
narrowing opportunity rather than making the proof optimistic. No hint hash,
write-time index, allocation or extra storage backing is introduced. Existing
NUMERIC SUM/AVG finalization and SQL result types remain unchanged.

The independent 5003-key model covers both nullable/non-null keys, dense and
retained-hole loops, old snapshots, exact averages, aborted bound widening,
extreme keys and sums that genuinely exceed i64. Metadata-disabled execution
remains the canonical differential reference. Smaller state is an execution
choice, not a new SQL range/cardinality limit.

### Sparse predicate cascades before dimension probes

After a selective leading predicate produces a mask, additional safe leading
AND conjuncts can refine only its surviving positions. Integral comparisons
and fact DATE comparisons/BETWEEN with binder-validated literal bounds use
exact committed lanes, avoiding a second full-column scan or full-row fetch.
The complete WHERE evaluator still checks every surviving joined tuple.

Collection stops at the first computed, unsupported or nullable conjunct;
it cannot move a later false predicate across a throwing expression. Existing
nonthrowing ON/probe and committed-snapshot guards remain required. NULL date
inputs therefore retain the original UNKNOWN/error behavior. A fixed descriptor
budget limits this optimization, not SQL result cardinality: excess conjuncts
remain in canonical evaluation. Cancellation/work checks precede every bounded
refinement, and separate counters retain leading/cascade rejection evidence.

The independent model adds all six DATE comparisons, reversed operands,
exact probe/rejection bounds, a false DATE guard before division-by-zero, an
earlier throwing guard before that DATE predicate, and a nullable DATE that must
not hide a later error. This is a bounded fact-predicate cascade, not the full
RPT+ join-order/Bloom-transfer algorithm from the research below.

### Reuse binder-validated DATE literals

The post-projection selective-join profile still includes repeated temporal
parsing, field decoding and typmod work. The binder already validates an
untyped DATE literal once; execution previously discarded that proof and
repeated the conversion for each surviving fact. Binding now retains the exact
day count in the node's existing integer payload plus a validation flag. A
DATE cast over that validated literal reuses the same value. This adds no
query cache, input-dependent storage or mutable shared expression state.

Invalid literal errors still occur at their existing binding phase, including
behind FALSE. Computed text/date casts retain canonical lazy evaluation and
runtime errors. Only successfully prevalidated pure DATE literals are folded;
clock functions and timezone-dependent computed conversions are untouched.
Evaluation retains the literal child's checkpoint when bypassing its cast,
so cancellation/work charging stays equivalent. The independent fixture
compares both implicit DATE coercion and eight original-style joins against
the prior immutable source: all nine instrumented work totals match exactly.
That proof compares fold-only source `129a89db` with `c3b0c93f`; later cascades
charge their additional performed filter work separately.
Multiple distinct literals, reused node IDs, infinities, BC dates, private
writes and pinned snapshots remain covered by the surrounding contracts.

- [Robust Predicate Transfer with Dynamic Execution, PVLDB 2026](https://www.vldb.org/pvldb/vol19/p1278-qiao.pdf)
  combines asymmetric transfer plans, coarse/fine filters and runtime decisions
  about filter construction. The applicable lesson is to account for filter
  setup and scan costs, not add Bloom filters indiscriminately. Next experiment:
  bounded, caller-backed cascade filters for selective dimension predicates,
  with exact joins after filtering and measured admission/build costs. The
  present prefix optimization is not an implementation of the complete RPT+
  algorithm.
- [Parachute, VLDB 2025](https://duckdb.org/library/parachute/)
  investigates single-pass bidirectional information passing using join-induced
  fingerprints. Evaluate the persistent/update overhead before considering a
  derived index; any fingerprint may only reject provably impossible matches,
  with canonical equality/MVCC checks remaining authoritative. No such index is
  currently implemented here.
- [Indexing Join Inputs for Fast Queries and Maintenance, 2025](https://arxiv.org/abs/2502.10874)
  studies indexed representations between traditional indexes and materialized
  joins. Candidate work is an exact low-cardinality row-selection index, owned
  by explicit table backing and updated only after durable publication. It
  needs insert/update/delete/replay and old-snapshot tests, not just faster reads.
- [FastLanes: a next-generation file format, 2026 thesis](https://ir.cwi.nl/pub/36173)
  and its [VLDB 2025 artifact](https://github.com/cwida/fastlanes-vldb2025)
  motivate SIMD-friendly lightweight encodings and decoding only needed data.
  The largest capacity step remains compact typed base storage with sparse MVCC
  deltas. RAMSQL's inline version cells are still costly. Packed-column primitive
  tests alone do not establish SQL-store, WAL or recovery integration.

All proposed filters must preserve SQL's exact answers; approximate aggregates
or probabilistic result substitution are outside this work. Do not import the
papers' allocator-based engines or foreign runtimes into the Sig server.

## Acceptance before any performance claim

Pass independent correctness and rollback/snapshot contracts, then run the
unchanged original JDBC checks on the actual dataset. Keep other engine services,
builds and profilers stopped during throughput measurement. Record binary/input
hashes, capacity, CPU and latency. Repeat matched before/after runs and retain
negative results. The dbMeter workflow's advantage gate remains authoritative;
this design or its operation-count reduction does not justify merging it.
