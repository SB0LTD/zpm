# Dimension group IDs for mixed fact/dimension grouping

Status: opt-in implementation, pending full-platform and CI-only performance
qualification. No throughput or all-workload advantage is claimed here.

The measured original 1M mixed workload spends about 48.55% of RAMSQL's
single-client query time grouping customer segment and fact discount. The
existing factor-first kernel excludes fact grouping keys, so this shape uses
per-fact dimension probing, Cell evaluation and general hashing.

After typed multi-aggregation, the exact-main-configuration A/B campaign
[40976650837](https://github.com/benor1470/dbMeter/actions/runs/40976650837/attempts/1)
attributes 62.64% of summed single-client JDBC latency to segment/discount and
29.56% to category/DISTINCT across all three candidate mixed trials. These are
client-time shares, not PMU samples or a new local throughput measurement.

## Rewrite and ownership

For a unique dimension key k, let L(k) be its visible label after a pure ON
predicate. Intern equal labels as IDs g. A fact with foreign key k and integral
group key d contributes to state `(g(k), d)`. Missing/NULL foreign keys have no
inner-join contribution; a NULL dimension label is an ordinary grouping ID,
and NULL d has its own bucket. Multiple dimension keys sharing one label feed
the same aggregate channels. Uniqueness comes from the bound primary-key probe,
not assumed foreign-key validity or deduplicating a nonunique join.

The query builds a K-entry u32 key-to-ID mapping and caller-budgeted dictionary
hash/ticket arrays. Aggregate state is allocated lazily when a new label is
discovered: one state vector per integral fact-key position, carrying exact
i128 totals, nonnull channel counts and an independent matched-row count. Text
hashing and version lookup occur during dimension contraction, outside the fact
loop. Facts read committed typed columns, perform one mapping lookup and update
typed state. No fact-sized ordinal/Cell intermediate is built.

Final nonempty states become private group records. Canonical NULL-first key
sorting precedes ordinary aggregate finalization, HAVING, projection, ORDER BY,
OFFSET and LIMIT. This preserves output/error order; dictionary insertion order
must not become observable SQL grouping order.

All memory borrows the existing query arena. Budget admission covers mapping,
rounded dictionary buckets, lazily allocated state, worst-case final Cells and
both key/output sorting reference arrays. Arithmetic for these sizes is checked.
No new backing region, heap, persistent derived index or shared query cache is
introduced. Each mapping belongs to one query snapshot.

## Admission and fallbacks

`dimension_group_ids` defaults to false. The first implementation accepts one
unique-primary-key inner join, exactly one direct dimension grouping label and
one direct integral fact grouping column, no WHERE, and direct COUNT/SUM/AVG
fact channels. Label types are restricted to the existing exact summary-key
types. Additional ON comparisons can use integral dimension columns and the
fact join key, with pure comparisons/AND/OR. Other fact inputs, throwing or
computed ON expressions, DISTINCT/FILTER and computed grouping keys retain
ordinary SQL.

Facts must use a valid committed projection at the query snapshot. Private
writes and old fact projections fall back. Dimension rows are looked up at the
actual snapshot, including retained old versions after dimension publication.
Every checked-i64 SUM needs an all-prefix bound; wide channels preserve ordinary
NUMERIC finalization and reject insufficient configured precision from this path.

Insufficient domain/dictionary grants fall back without imposing a SQL row
limit. Dictionary overflow restores the query-arena mark and physical counters
before ordinary execution. Execution work remains charged; fallback cannot
bypass work limits or cancellation. Both key-domain work and bounded fact blocks
poll the existing control. Errors leave result publication atomic.

## Qualification

`test_sql_dimension_group_ids.sig` compares the actual executor with the
unchanged executor and an independent scalar model. It covers duplicate/NULL
labels, NULL/missing foreign keys, nullable/signed fact keys and measures,
multiple aggregates, AVG, group-key reversal and canonical order, safe/unsafe
ON predicates, LEFT/nonunique joins, DISTINCT/WHERE fallback, old fact/dimension
snapshots including primary-key changes, private writes, failed flush,
copy/replay, dictionary overflow under a small reference grant, poisoned scratch,
cancellation during mapping and fact folding, work limits, empty/all-NULL input,
extreme i64 domains/wide sums and small NUMERIC capacity.

Windows/Linux ReleaseSafe and legacy Linux Debug each execute 9,429 assertions.
Full-platform CI and the performance campaign are separate qualifications.

Measure the same original weighted mix and the original segment/discount query
in CI against a same-library control, on one runner in AB/BA/AB order. Preserve
every original CSV check, input size, timing phase and raw histogram. Selected
diagnostics do not relax the independent all-engine dbMeter gate.

This does not implement general hash joins, grouped DISTINCT, compressed base
storage or intra-query parallelism. Those remain separate architectural work.
