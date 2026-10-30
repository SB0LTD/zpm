# Typed DISTINCT over unique dimension chains

Status: opt-in implementation, pending complete native/platform and CI-only
performance qualification. No speedup or universal workload claim is made.

After the dimension-ID change, the original category/customer-DISTINCT case
accounts for 67.98% of summed single-client query time in the candidate's
three mixed trials from [CI run 40982373535](https://github.com/benor1470/dbMeter/actions/runs/40982373535/attempts/1).
That is observed JDBC client-time attribution, not PMU profiling.

## Exact membership belongs to the final group

For fact join key k, contract its visible unique-key dimension chain to a final
group label g(k). Multiple product keys and multiple categories can share that
label. The distinct count for label g is the cardinality of the union of its
nonnull fact values. Adding distinct counts computed independently per product
would count a customer twice when they buy different products in the same
category. This implementation therefore owns membership per **final label**.

`dimension_distinct_groups` defaults to false. The query privately constructs
a dense key-to-group-record mapping using the existing dimension contraction
infrastructure. Each record owns a label Cell, typed COUNT/SUM/AVG channels,
an independent row count and exact bitmaps for direct integral
COUNT(DISTINCT fact-column) channels. Separate DISTINCT inputs have independent
offsets/domains; ordinary aggregates still see every matched row.

During the fact scan, typed columns feed group states directly. NULL distinct
values are ignored, repeated bits do not increment the count, and NULL labels
group normally. Missing/NULL foreign keys or failed inner-join paths contribute
nothing. Distinct domains use conservative existing integer bounds; very wide
or sparse domains may be unsuitable and retain the ordinary executor.

The fact loop performs no dimension-version lookups, text hashing or fact Cell
materialization. It still scans required input columns and charges membership
work. It is not an answer cache, maintained aggregate or metadata-only count.

## Ownership, proofs and bounds

All mapping, hash tables, typed states, bitmaps and final handles borrow the
caller-owned query arena. Group records allocate lazily, and admission includes
dictionary rounding, final projection and both sorting phases. Bitmap layouts
reuse the existing exact grouped DISTINCT domain machinery. No shared derived
state, heap, new backing region or persistence format is introduced.

Only unique-primary-key inner chains with proven nonthrowing dependencies in
source order qualify. The first join must probe a direct integral fact key;
later probes and ON comparisons may use available dimensions and that fact key.
Grouping is by one direct exact dimension label; aggregate inputs are direct
facts. WHERE, FILTER, computed/throwing inputs, unsupported DISTINCT kinds,
outer/nonunique joins and unsupported types remain ordinary SQL.

Facts require a valid committed projection at the snapshot. Old fact snapshots
and private writes fall back; dimension lookups use their actual snapshot.
Checked-i64 sums retain the all-prefix proof, and exact wide arithmetic uses
normal finalization. Canonical label sorting precedes HAVING/projection/error
evaluation. Capacity fallback restores the arena and physical counters while
preserving charged work. Cancellation and failures never publish partial output.

## Qualification

The actual SQL/scalar/canonical suite executes 1,454 assertions per mode on
Windows/Linux ReleaseSafe and legacy Linux Debug. It covers unequal per-group
distinct counts and overlapping memberships across keys, multiple bitmap
domains, word boundaries through bit 256, duplicate/NULL labels, signed/nullable
inputs, missing keys, two/three-way chains, independent SUM/AVG channels,
nonunique/outer/WHERE/expression fallback, private writes, old fact/dimension
snapshots, failed flush, copy/replay, dictionary exhaustion, poisoned scratch,
work/cancel limits, all-NULL and zero-word domains, extreme sparse ranges, empty
results and small NUMERIC capacity. The existing 9,429-assertion dimension-ID
suite also passes in all three modes after sharing the mapper.

Benchmark the original weighted mix and existing category scenario in CI, with
same-library control/candidate binaries in AB/BA/AB order, original data,
independent expected CSV checks and unchanged timing phases. Keep every trial,
failure, p99 and source/binary hash. This selected diagnostic does not relax the
all-engine advantage gate or implement missing RANK/window/ROLLUP SQL operators.
