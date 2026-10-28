# Aggregate before unique-key joins

Status: an experimental, opt-in SQL execution path. No database speedup or
production qualification is claimed until the unchanged wire benchmarks pass.
This implements the first join kernel from the
[algebraic execution design](SQL_ALGEBRAIC_EXECUTION.md); nested CTE fusion,
compact base storage and intra-query tasks remain separate work.

Enable `Config.factorized_aggregates` together with external storage and compact
integral scans. The library default is false. Unsupported queries keep the
ordinary executor. Admission failure does not introduce a SQL cardinality cap.

## Actual execution

1. Bind SQL normally, preserving binding errors and dialect/type semantics.
2. Prove eligibility and conservatively admit all key-domain state, hash/group
   records, projection cells and reference handles from the caller's workspace.
3. Scan live committed fact slots in blocks. Apply exact integral/validated DATE
   predicates and fold direct COUNT/SUM/AVG inputs into typed per-key states.
4. For each active key, resolve the unique-key dimension chain at the statement
   snapshot and evaluate its safe ON conditions. Missing/NULL paths contribute
   no inner-join rows.
5. Merge the partial states by final group keys, sort keys canonically, and use
   the existing aggregate, HAVING, projection, ORDER BY and result finalizers.

No fact Row or Cell tuple is reconstructed for this scan. Scratch holds a row
count and `(nonnull count, i128 total)` channels, indexed by the admitted fact
join-key domain. Dimension values are borrowed synchronously from visible
versions. Result ownership remains in the existing executor.

For a unique-key dimension chain, every fact contributes to at most one path.
Distributivity therefore replaces dimension probes per selected fact with
dimension probes per participating key. This is not a claim that scan cost
disappears or that total runtime improves by the same factor.

## Eligibility and fallbacks

- Current committed fact projection, valid metadata and matching scan/directory
  extent. Private writes and newer fact projections at old snapshots fall back.
- At least two sources; unique-primary-key inner probes to base tables. The
  first probe uses one direct integral fact column. Later probe/ON operands may
  use dimensions and that same fact key, never other fact columns.
- ON expressions are non-throwing integral comparisons/Boolean combinations.
  Computed probes, throwing ON clauses and other fact-dependent ON inputs fall back.
- Fact WHERE is a conjunction of direct integral/literal or validated DATE
  comparisons/ranges. Computed, volatile, correlated and unsupported predicates
  fall back, preserving three-valued logic and error evaluation.
- At least one final group key, consisting of supported direct dimension
  columns. Numeric/float/interval representative-sensitive keys and computed
  keys retain the canonical path.
- Direct fact COUNT/SUM/AVG channels; no aggregate FILTER or DISTINCT input.
  COUNT may use nonintegral columns because only its null bitmap is needed.
- Every integer SUM prefix must be proved within i64 using conservative whole
  table bounds. Wide sums fit i128 because row references admit fewer than 2^31
  i64 inputs. Small NUMERIC configurations retain canonical capacity errors.

No foreign-key existence is assumed. Non-unique dimensions are handled by the
existing bag-correct executor. No query-name/SQL-text pattern, precomputed query
answer, persistent result cache or input-sized comptime array is introduced.

## Ownership, budgets and interruption

All state borrows reserved Cell bytes/reference handles in the existing query
arena. Typed state is initialized before use and never read as tagged Cells.
The key domain is admitted from both actual Cell and reference budgets, with
checked wide domain arithmetic. Sparse/widened domains retain normal SQL.
The completed operator records actual reserved Cell/reference deltas.

Fact blocks, per-key probes, hash probes and sort/finalization use the existing
execution control. Fewer joins change the amount of logical work performed;
there is no promise of identical work totals to the row algorithm. Work limits
and cancellation still fail before the caller's previous result is replaced.
The surrounding executor retains charged work on a safe workspace retry.

This does not change storage publication, WAL ordering or replay. Tests verify
failed flush, rollback, retained snapshots, dimension-key version changes,
copying and change-record replay against the canonical executor.

## Validation

`tests/test_sql_factor_join.sig` enables the actual path and compares it with
the disabled canonical executor plus an independent row model. Windows/Linux
ReleaseSafe and legacy Linux Debug each pass **1,824 assertions**. Coverage
includes nullable keys/measures/groups, missing dimensions, every DATE comparison,
negative and wider-than-i64 sums, AVG, all-null measures, empty selection, ON
guards, private writes, old fact and dimension visibility, publication failure,
copy/replay, cancellation during the fold, poisoned workspace, constrained
reference-budget fallback, aborted extrema, non-unique bag joins, DISTINCT and
small NUMERIC capacity errors. The fixture's 513 rows exceed its 128 work rows.

The existing library configuration keeps this path disabled, retaining baseline
SQL contracts. Native full-SQL CI and independent-client server measurements
remain required before making RAMSQL's default opt-in or claiming a speedup.
