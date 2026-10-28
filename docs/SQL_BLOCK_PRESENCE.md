# Conservative block-presence filtering

`block_presence_filters` is an opt-in optimization of the caller-backed committed
integral/DATE projection. Its library default is false. It changes physical
reads, not SQL answers, cardinality limits, result ownership or work accounting.

Each column has a 256-bit summary for every 64 directory slots. Publishing a
non-null integral/DATE value sets the bit indexed by its low eight bits. An
equality predicate whose bit is absent can reject that block without reading its
value lane. A present bit always requires the existing exact value/null/live
comparisons. Values separated by 256 can collide; deletion/update may leave old
bits set. These produce extra comparisons, never extra SQL rows or omissions.

The invariant is that every live, non-null projected value's bit is present in
its block. This is an exact negative filter, not an approximate SQL predicate.
It does not use query text, names, expected results or cached query answers.

## Ownership and lifecycle

- Backing is another distinct caller-owned slice. Checked layout calculations,
  backing validation, overlap checks and borrowed ReadContext validation include
  the new metadata. Disabled configurations require no new backing bytes.
- Newly reached blocks are initialized before use, including unused columns;
  unused capacity is not read. Partial blocks remain safe.
- Publication/replay updates bits in the existing infallible committed-projection
  publication step, after durable success. Private writes and aborts do not
  publish metadata. Failed-flush tests verify unchanged metadata bytes.
- Copies handle different source/destination row capacities and block strides.
  Slot compaction rebuilds summaries from live committed projection values after
  moves; it never leaves summaries describing the old slot positions.
- The surrounding projection eligibility proofs still govern old snapshots,
  private writes, throwing/nullable expression ordering and residual predicates.
  Unsupported/unaligned accesses retain ordinary comparisons.
- Blocks and predicates retain the existing logical checkpoints. Rejecting a
  block does not evade work limits, cancellation or error ownership.

Memory is `ceil(row_capacity/64) * columns * 32` bytes, charged in the ordinary
external backing budget. For five million rows and eight columns this is 20 MB
decimal, excluding small-table rounding. The executable contains no row-sized
metadata arrays. This does not solve the separate inline-version payload cost.

## Expected opportunity and rejection criteria

For independent uniform values from D distinct residues, an equality value is
absent from a full block with probability `(1 - 1/D)^64`. D=200 illustrates about
72.6% potentially rejected blocks. This is a distributional model, not a measured
speedup or guarantee. Each probe reads one logical u64 word; physical cache-line
traffic must be measured. Clustered data can reject more blocks; residue
collisions, low-cardinality mixed blocks or saturated summaries can reject none.

The extra metadata reads, publication work and compaction rebuilds can lose on
some workloads. Keep the option disabled until full-data paired measurements,
load/update costs and appropriate workload coverage justify enabling it. No
universal improvement is claimed. Later access-path selection should use actual
occupancy/selectivity and granted memory; a posting index can avoid more work for
very selective queries, at a different build/update/memory cost.

`tests/test_sql_block_presence.sig` compares enabled SQL with disabled execution
and an independent live-row model. It exercises signed/residue collisions,
partial blocks, NULLs, scalar and join aggregates, DATE predicates, i64 extremes,
private writes, retained snapshots, failed flush, copy into a different capacity,
change-record replay, metadata alias rejection, directory compaction, saturation,
work limits and identical logical work totals. Final assertion counts and native
platform results belong to the qualification record, not an unmeasured claim.
