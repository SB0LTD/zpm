# Validated ordered integral key candidates

Repeated primary-key dimension lookups dominate a sampled million-row JDBC
star-join workload. For a table whose primary-key order is increasing (or has
one value), an integral key minus the conservative lower bound provides a
possible directory slot. `lookupVersionAt` checks the slot's canonical visible
version under the actual statement snapshot and compares its exact integral key.
Only a matching visible version is accepted.

This is a speculative address calculation, not a new index or a contiguity
assumption. Missing/deleted rows, gaps, stale bounds, changed slot positions,
unmatched versions and unsupported types retain the existing hash/MVCC lookup.
The subtraction uses i128, including both extremes of signed BIGINT. Unordered
keys avoid the speculative read. There is no extra allocation, persistent cache,
query scratch or new capacity requirement. Existing per-probe work/cancellation
checkpoints remain unchanged.

The index contract covers signed dense keys, deletion, aborted minimum outliers,
own primary-key changes and rollback, reinserted slots and BIGINT boundaries.
Existing randomized index, snapshot/MVCC, streamed join and concurrent-reader
contracts still apply. Throughput improvement must be established independently
with the original reviewer queries; this document alone claims no speedup.
