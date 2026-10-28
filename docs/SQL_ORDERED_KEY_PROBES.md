# Validated ordered integral key candidates

Repeated primary-key dimension lookups dominate a sampled million-row JDBC
star-join workload. A fixed per-table hint observes whether integral primary keys
match an initial base plus the physical directory slot, including bulk inserts.
An integral key minus that base provides a possible directory slot.
`lookupVersionAt` checks the slot's canonical visible
version under the actual statement snapshot and compares its exact integral key.
Only a matching visible version is accepted.

This is a speculative address calculation, not a new index or a contiguity
assumption. Missing/deleted rows, gaps, stale bounds, changed slot positions,
unmatched versions and unsupported types retain the existing hash/MVCC lookup.
The subtraction uses i128, including both extremes of signed BIGINT. Mismatched
inserts/key changes and moved directory slots disable the hint. Unordered and
sparse keys avoid the speculative read after the first mismatch. The hint is
fixed scalar metadata, not a per-row index or persistent cache. There is no extra
allocation, query scratch or new capacity requirement. Existing per-probe work/cancellation
checkpoints remain unchanged.

The index contract checks actual hint selection for bulk-loaded signed dense
keys and BIGINT boundary keys. It covers deletion, aborted minimum outliers,
own primary-key changes and rollback, reinserted slots and BIGINT boundaries.
Existing randomized index, snapshot/MVCC, streamed join and concurrent-reader
contracts still apply. Throughput improvement must be established independently
with the original reviewer queries; this document alone claims no speedup.
