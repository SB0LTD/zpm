# Typed aggregation across a producer/consumer boundary

This opt-in SQL executor path carries integral COUNT/SUM producer state directly
into a grouped unique-key consumer. It uses `factorized_aggregates`, whose library
default remains false. It does not change SQL syntax or result types.

For a grouped producer `(key, COUNT(*), SUM(value))`, the executor scans the fact
columns into caller-owned dense states `(row_count, total)`. It tests safe
producer-output predicates on these exact integers, probes each surviving key's
visible dimension once, and merges typed outer COUNT/SUM/AVG/MIN/MAX states.
Only the final groups become SQL Cells. Existing HAVING, projection, arithmetic,
rounding, sorting, DISTINCT and LIMIT finalization remain responsible for output.

The work is O(N + K + G log G), where N is fact rows, K the admitted key domain,
and G final groups. This removes producer row materialization and repeated NUMERIC
conversion for K keys; it does not eliminate the N-row scan. No performance ratio
is inferred from this complexity or from the algebra prototype.

## Conditions and safety

- The producer is a single base-table group with one direct integral key and
  exactly COUNT(*) plus direct integral SUM. No WHERE, HAVING, DISTINCT, ORDER,
  offset, limit, set operation or correlation is fused. Output aliases/order
  may vary; bound expressions, not SQL names or text, identify the channels.
- The SUM input must be non-null for every current row. Whole-table conservative
  bounds prove every producer prefix fits i64. Wider or nullable producers use
  the canonical executor, preserving SQL sums rather than truncating them.
- Fact summary/column projection must match the requested committed snapshot.
  Private writes and retained snapshots with newer fact projections fall back.
- A CTE has exactly one bound consumer, is idle, and is not recursive. Shared
  CTEs retain existing materialization ownership. Derived tables are eligible.
- The consumer joins one unique-primary-key base dimension on the producer key.
  ON expressions use the same non-throwing integral operand proof as factorized
  joins. Missing keys disappear; NULL producer keys cannot pass the PK equality.
  Dimension versions are looked up at the caller's snapshot.
- Consumer grouping uses supported direct dimension columns. Consumer measures
  use direct producer outputs. DISTINCT/FILTER aggregates fall back. Integer SUM
  additionally proves outer prefixes safe; wider totals use exact i128 states.
- Consumer WHERE accepts conjunctions of direct producer-channel comparisons
  with integral literals, including safe unbounded NUMERIC coercions. Other
  expressions retain canonical evaluation and error ordering.
- NUMERIC precision must cover the exact totals; smaller configured precisions
  fall back. Representative-sensitive float/numeric/interval group keys retain
  canonical grouping.

Dense states and final group states borrow the existing query Cell/reference
arena. Every byte is initialized before use. Wide span arithmetic and conservative
admission account for both budgets; widened or sparse domains fall back. A safe
workspace retry restores the arena and statistics but retains charged work.
Block scans, key probes, group probes and finalization obey execution controls.
Cancellation and failures do not replace the caller's previous result.

There is no new heap, persistent index, result cache, cross-snapshot answer reuse,
storage format, WAL change, or workload-name special case.

## Validation and remaining qualification

`tests/test_sql_factor_cte.sig` compares enabled and disabled real SQL execution,
plus an independent scalar model. It checks threshold boundaries, NULL keys,
signed totals, missing dimensions, reordered producer outputs, derived tables,
COUNT/SUM/AVG/MIN/MAX and ROUND output, HAVING, shared CTE fallback, throwing
expressions, private writes, old fact/dimension snapshots, failed flush, copy and
change-record replay, poisoned scratch, constrained reference fallback, work
limits, cancellation after producer execution, nullable and wider-than-i64
producer fallback, and empty tables.

Full-platform SQL contracts and unchanged full-data JDBC measurements must qualify
this candidate before enabling it by default in RAMSQL. This does not solve the
120 GB version-slot cost of a 100M-row default-width table, unsupported SQL cases,
or intra-query parallelism described in `SQL_ALGEBRAIC_EXECUTION.md`.
