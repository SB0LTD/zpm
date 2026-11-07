# Filtering committed integral columns before fetching versions

The reviewer's dbMeter query `SELECT id,val FROM t_N WHERE grp=? AND val>990000`
spent most sampled server time evaluating scalar predicates and visiting padded
row versions. A plain SELECT can instead scan the existing committed integral
projection in 64-slot blocks, then fetch full visible versions only for matches.
This adds no stored cache, heap allocation, database-specific SQL recognition,
or compiler behavior. Bound integral column/literal comparisons support all six
ordering/equality operators and conjunctions, including reversed operands.

The path requires a current committed snapshot, a valid projection at or before
that CSN, matching row/projection extents, non-null proofs for every predicate
column, no locking/order, and no finite LIMIT. Old snapshots, own writes, nullable
predicates, functions, arithmetic and other shapes use existing execution.
Projection targets are still evaluated against canonical MVCC versions, preserving
text/NULL values, expression errors, and publication atomicity. Sorted/top-k and
finite-limit plans retain their existing routes.

Each scanned slot is charged, including dead slots. Every comparison's literal
evaluation is charged only for rows that reached that AND term; this preserves
successful scalar execution's work count and short-circuit behavior. Polling and
cancellation remain bounded within 64 slots. A failure leaves the caller's result
unchanged. Filter handles are bounded by the existing query workspace, not by a
new hidden allocation.

The contract compares actual rows and execution charges with a separately
instantiated scalar executor, plus independent cardinalities. It covers reversed
bounds, all comparisons, multiple groups, text projection, deletion, updates,
old/own snapshots, NULL/OR/LIMIT/order fallback, cancellation and work exhaustion.
Eight independent contexts execute the new scan concurrently alongside lookup,
join, aggregate and ordered queries (2,400 checked queries total).

This is execution over an existing integral projection; canonical SQL row and
version storage is still inline. It does not deliver compact physical SQL
storage, automatic scheduling, or extended-protocol concurrent execution.
