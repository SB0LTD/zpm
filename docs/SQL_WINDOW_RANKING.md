# Remaining distribution/ranking windows

This candidate adds percent_rank, cume_dist and ntile to ZPM core. percent_rank
returns (rank-1)/(partition_rows-1), or0 for a singleton. cume_dist returns the
end position of the current peer group divided by partition size. Both return
float8, use native NULL/peer ordering and disregard runtime frame bounds like
PostgreSQL's optimized ranking windows. Immutable frame-offset errors still
fold during binding, including unused1/0 with LIMIT0. This also improves the
existing ranking/frame paths.

cume_dist scans each peer run once and writes its ratio to that run. ntile keeps
only bucket number, rows in the bucket, boundary and remainder; there are no
new per-row arrays or allocators. Counts/state are bounded by existing u32 row
handles and positive int4 bucket counts. Frame and workspace/cell limits remain
the configured existing limits; no unlimited-capacity claim.

NTILE's count is evaluated at the current row until its first non-NULL value in
each partition. Leading NULL results do not initialize state. Once initialized,
subsequent counts are ignored, including NULL or invalid values. Non-positive
initial counts raise22014. A count larger than partition size yields successive
bucket numbers without empty leading buckets. No count is evaluated on empty
input or LIMIT0; immutable argument errors still fold before execution.

The root single-window prefix-demand rules from SQL_WINDOW_OFFSETS apply to
sensitive NTILE arguments. Constant positive/NULL counts are total and may be
nested/combined. Variable, throwing or volatile counts require a supported root
shape, with explicit0A000 for uncertain parent demand, interleaving or order.
These are remaining demand-propagation gaps, not completed NTILE closure.

The zero-argument ranking family also accepts native fn(*) forms and reports
42809 without OVER. Arguments to percent_rank/cume_dist/rank/dense_rank require
ordered-set aggregate syntax (still a separate unsupported family); row_number
with arguments remains42883.

Native reference: PostgreSQL18 functions-window documentation and
[REL_18_3 windowfuncs.c](https://raw.githubusercontent.com/postgres/postgres/REL_18_3/src/backend/utils/adt/windowfuncs.c).
The initial frozen PG16.15 oracle has62 programs, checked for value/type/error.
Additional tests exercise constant bucket-count distributions over varying row
counts, singleton/empty input, LIMIT0, frame-folding errors and work cancellation.
Hosted/native/PG18 qualification remains pending. Named windows and first/last/
nth_value, wider frames and complete SQL inventory closure remain open.

Observed ReleaseSafe ranking:3047assertions on Windows and independently Linux.
Independent existing windows8801, frames107703 and offsets2017 also pass; work-
budget sweep assertion totals vary with the charged operations. All62 native
PG16 fixtures and49 additional adversarial assertions pass. Baseline34f371c
fails first percent_rank fixture with UndefinedFunction. The unchanged118
programs remain10/91/17 and exit1 SqlConformanceIncomplete; source/output hashes
are in tests/sql_conformance/window_ranking_evidence.json. No throughput claim.
