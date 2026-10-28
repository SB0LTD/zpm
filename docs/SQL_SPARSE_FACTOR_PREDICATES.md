# Sparse survivor predicates in factorized joins

The opt-in `sparse_factor_predicates` setting keeps vector evaluation for the
leading predicate and dense masks. When a preceding predicate leaves at most
eight of a block's 64 slots, later safe predicates inspect only those slots with
the existing exact `compactKeep` comparison/null logic. Eight is an execution
cost heuristic, not a SQL row, group, result or capacity limit. Its library
default remains false; it does not require block-presence metadata.

For selective equality followed by range predicates, later column reads now
scale with surviving rows instead of every slot in each surviving block. This
complements block-presence rejection: summaries can omit impossible blocks;
survivor masks omit already rejected rows within the remaining blocks. No input
is omitted without an exact predicate/negative-summary proof.

The surrounding factorized-join eligibility still requires current committed
projection visibility and non-throwing direct integral/validated DATE predicates.
NULL operands fail WHERE as in the vector mask. No computed, volatile, throwing
or correlated expression becomes movable. ON evaluation, dimension snapshots,
aggregate types, output/group ordering and result publication are unchanged.

There is no new backing storage, heap or persistent index. Scalar mask iteration
uses caller state and one stack predicate. Logical checkpoints remain unchanged;
tests compare exact work totals against the vector factor kernel. Statistics
record sparse predicate masks and the number of selected slots inspected.

`test_sql_sparse_factor.sig` compares actual sparse and vector SQL execution
against an independent row model: every comparison operator, reversed DATE
bound, nullable keys/dates/measures, signed values, i64 extremes, exact wide sums,
AVG output, partial blocks, sparse masks and throwing-expression atomicity.
`test_sql_sparse_factor_lifecycle.sig` reuses the complete factor-join canonical
and scalar contract with sparse predicates/presence summaries enabled, covering
snapshots, private writes, failed flush, copy/replay, workspace fallback,
cancellation, deletion/reinsert and overflow/precision boundaries.

Separate sampled profiles on the preceding source found whole-block comparison
and factor-fold instructions prominent. These are diagnostic wall-time samples,
not PMU cycle attribution. Paired original-data measurements must qualify this
candidate; its operation-count reduction is not a claimed throughput speedup.
