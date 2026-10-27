# Bounded aggregation over unique-key inner joins

The general SQL executor can stream grouped/scalar aggregates over one base
table followed by inner joins that probe each dimension's primary key. It scans
one visible fact version, resolves at most one visible version per dimension,
checks ON/WHERE conditions and updates the existing aggregate state. It does
not build input-sized fact-handle lists or left-deep intermediate tuple lists.

Arithmetic and probe inputs borrow stable column cells for their synchronous
use; computed expressions retain private temporaries and left-to-right
evaluation. Primary-key probes reuse their visible version hit instead of
walking its MVCC chain again.

When caller-backed committed integer projections are enabled, eligible fact
inputs gather only referenced integral columns into a query-private row. Live
and NULL flags come from the real publication-maintained projection. The guard
requires committed-only execution, a valid summary, and a projection publication
CSN no newer than the snapshot. Own writes, older snapshots and referenced
non-integral columns retain versioned rows. An unused text/numeric column does
not prevent an integral gather. No new stored projection or cached SQL result is
introduced; `StreamStats.gathered_rows` exposes actual use. The private row stays
alive until aggregation consumes it, and never escapes into a public result.

For these plans, aggregate workspace depends on group cardinality and aggregate
state, rather than input cardinality. Group keys, NULL grouping, FILTER/HAVING,
projection, ordering and result publication use the existing operators. Unique
probes can depend on earlier dimensions as well as the fact. Missing/NULL keys
and failed residual ON conditions exclude the tuple. Every probe uses the same
snapshot as the fact scan, including an owning transaction's pending versions.

The route requires grouped output, a physical base table, and a primary-key
probe for every later inner source. Non-count/non-integral DISTINCT aggregates, outer joins, non-key
joins and expressions with functions/subqueries retain the existing general
path. Existing finite-LIMIT eligibility and repeatability checks remain in
force. Whole-table summaries, compact scalar/group scans and dense domains are
restricted to single-source plans; a dimension join must never accidentally
reuse a fact-only summary or skip its join predicates.

The aggregate hash table remains caller-bounded. High group cardinality can
exhaust it. Repeatable plans may retry the existing sort/group implementation
when that fits; retries retain execution-budget charges. Exhaustion, arithmetic
errors and cancellation preserve the previous public result. This change does
not provide spill storage, arbitrary many-to-many streaming joins, concurrent
writers, compact physical SQL storage or unlimited SQL capacity.

`tests/test_sql_stream_group.sig` loads 100,000 fact rows and two dimensions
through SQL, then checks a three-table grouped query using only 512 query handles
and 1,024 workspace cells. The same workspace is checked at 512 and 100,000 rows.
An independent integer model covers NULL keys/values/groups, missing keys,
counts and multiplied sums. Additional cases cover scalar aggregates, chained
probes, residual ON/WHERE conditions, empty results, forbidden shapes, excessive
groups, cancellation, work limits, poisoned scratch reuse and committed/own
pending dimension visibility. The previous executor reproduced WorkspaceCapacity
at the first 512-row joined fixture. This is a bounded-execution correctness
contract; it is not a 100M-row storage or reference-engine benchmark claim.

Additional gather contracts cover pending fact writes, committed deletions,
referenced text/numeric fallback, unused non-integral columns and old snapshot
fallback after publication. Eight native private contexts also execute the
gathered joins; arithmetic contracts check NULL/error behavior, computed/numeric/
float operands, scalar subqueries, sequence evaluation order and result atomicity.

Run `sig build run-contract-sql-stream-group -Doptimize=ReleaseSafe` with a
matched Sig toolchain. Windows and no-libc Linux execute assertions locally;
the database-platform workflow also runs this contract on macOS.
