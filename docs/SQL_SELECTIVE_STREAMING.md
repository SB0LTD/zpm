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

## Current research and applicable next experiments

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
