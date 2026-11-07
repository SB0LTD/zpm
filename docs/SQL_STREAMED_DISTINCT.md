# Exact streamed integral COUNT(DISTINCT)

Grouped/scalar primary-key inner-join aggregation can maintain an exact bitmap
per integral COUNT(DISTINCT) argument and output group. Bits live in the existing
caller-owned query workspace. A row is counted only when its non-NULL argument
sets a previously clear bit after its aggregate FILTER passes. Separate arguments
and filters have separate states. Other aggregates consume the same streamed
tuple normally; no fact-sized handle or intermediate join list is retained.

Direct integral columns of physical sources use storage's conservative integer
bounds, which include all inserted versions and never shrink after deletion or
abort. These enclose old and own-write snapshots too. Wide/sparse ranges that
cannot fit the grant, computed arguments, non-integral types and non-count
DISTINCT aggregates retain the existing exact general operator. No approximate
cardinality algorithm, hidden heap, fixed distinct-value ceiling, or additional
stored synopsis is introduced. Distinct state still has a real memory cost.

Bitmaps borrow aligned Cell slots as bytes/words, initialized before reading;
those slots are never read as tagged Cells. Available workspace determines plan
eligibility and group capacity. Each distinct probe checkpoints; cancellation,
work exhaustion, and failed fallback preserve the previous result. Stream stats
report the actual bitmap bytes. Word pointers declare the workspace alignment.

Native contracts SQL-load 100,000 rows over a 50,000-value signed domain and 20
groups, checking exact independent set cardinalities with 512 query handles and
125,120 bitmap bytes. Three-way tests cover two distinct arguments from different
relations, duplicate/NULL values and keys, FILTER, empty input, pending/aborted
outliers, poisoned scratch and cancellation. The full i64 range and text DISTINCT
fall back correctly. Eight independent contexts also run exact distinct queries.
