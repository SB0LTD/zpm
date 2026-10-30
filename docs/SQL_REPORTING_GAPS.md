# Reporting SQL: Q03/Q06 implementation record

The RAMSQL gap-closing plan owns the compatibility scope. This record covers
reusable ZPM code; it does not close the broad Q03/Q06 feature families or the
dbMeter correctness/performance gate.

## Temporal to_char (Q03)

`to_char(timestamp, text)` and `to_char(timestamptz, text)` return text.
DATE converts through the existing implicit timestamptz cast. Session time zones
therefore affect timestamp-with-zone formatting; plain timestamps keep their
local fields. Untyped first arguments remain ambiguous, as in PostgreSQL's
overloaded function. Numeric and interval formatting are not provided yet.

Supported templates: YYYY/YYY/YY/Y, Y,YYY, CC, MM, MONTH/Month/month,
MON/Mon/mon, DD/DDD, DAY/Day/day, DY/Dy/dy, D, WW/W, Q, J, HH/HH12/HH24,
MI, SS, SSSS/SSSSS, MS/US, FF1 through FF6, AM/PM and BC/AD (including
dotted/lowercase forms), FM and TH/th. Quoted literals and quote/backslash
escaping are supported. Ordinary non-template bytes are copied. ISO week-year,
time-zone-name/offset templates, Roman months and localized formatting modifiers
currently fail explicitly with UnsupportedStatement (0A000), rather than emit
invented values. Locale is the existing English/C behavior, not a new session
locale implementation. Infinite input and empty templates return NULL.

The formatter borrows caller output and performs a checked sizing/validation
pass before writing; capacity, unsupported-template, range and alias failures
leave the destination unchanged. SQL values still obey text_bytes. There is no
allocator, static answer cache, OS dependency or change to storage/WAL formats.
Temporal formatting is repeatable within an immutable query session but is not
classified as immutable: timestamp-with-zone output depends on the session.

The SQL contract replays 252 captured PostgreSQL 16.15 fixtures plus NULL,
signature, session-zone, grouping and error-atomicity checks. The fixture manifest
records the native reference, UTC session and byte hash. A separate primitive
contract verifies preflight capacity, unsupported-token, range and alias errors.
Native PostgreSQL 16/18 server differential qualification and the original 5M
dbMeter query remain required before declaring this concrete gate closed.

## Window functions (Q06 candidate)

The parser/binder now admit `OVER (...)` with partition expressions, independent
ordering and NULL placement. RANK, DENSE_RANK, ROW_NUMBER and the existing
ordinary aggregate families run over caller-owned materialized window inputs.
Window inputs are produced after WHERE/grouping/HAVING, with final ordering,
DISTINCT, OFFSET and LIMIT applied after windows. A grouped CTE's numeric total
can feed `SUM(revenue) OVER ()` before a top-N limit.

Default ordered aggregate frames include the complete current peer group;
unordered defaults cover the full partition. ROWS UNBOUNDED PRECEDING,
ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW, and the full unbounded ROWS
frame are provided. Ranking retains peer gaps. Each window keeps its own sort
keys; preceding window results are not reused as aggregate inputs. NULL/empty
input and aggregate result types use the existing typed SQL implementation.

The bound plan separates input materialization from window evaluation and final
projection, without a heap or persistent cache. Dependencies and window outputs
use the caller's existing expression, plan, column and query-workspace budgets;
the dependency count is bounded by Config.columns, windows by Config.columns,
and each query block containing windows adds one private plan. Exhaustion is a statement error. Work and
cancellation are checked through sorting, partition/peer scans, accumulation and
publication; no failed statement publishes partial results. Misplaced/nested
windows report PostgreSQL SQLSTATE 42P20.

The candidate replays 66 captured PostgreSQL queries and has 8,882 native
assertions including a work-limit and cancellation sweep across every execution
checkpoint. Full three-OS/native/server and original dbMeter qualification remain
pending. Ordinary aggregates containing window calls report 42803; misplaced
windows and windows nested inside window clauses report 42P20. This distinction
was caught by the PG16/18 server gate and has focused regression tests.
FILTER/DISTINCT window aggregates, bounded/moving frames, explicit
RANGE/GROUPS, named windows and correlated subqueries in the same window target
projection remain unsupported. This is not complete PostgreSQL window coverage.

## ROLLUP and GROUPING (Q06 candidate)

A flat `GROUP BY ROLLUP(k1, ..., kn)` creates each prefix and the grand total.
`GROUP BY ()` provides an empty grouping set; `ROLLUP()` remains a syntax error,
as in PostgreSQL. GROUPING arguments must match bound grouping expressions; the
rightmost argument supplies the low mask bit. Real NULL key groups remain
separate from rolled NULLs through an internal level tag. Empty input produces
only the grand-total row; HAVING is evaluated separately at every level.

Evaluate keys, aggregate filters and arguments once per admitted input, then
update independent prefix states. COUNT/SUM/AVG reuse the existing checked and
exact numeric transitions; averages never average already-finalized averages.
Direct integral COUNT(DISTINCT) uses independent exact membership per prefix,
so counts are not incorrectly added across subgroups. No base-table summary or
query-answer shortcut substitutes for the rows. Unique-key inner chains stream;
other joins use the existing bounded tuple operator. All group/hash/sort and
membership state borrows the caller's arena, with explicit capacity errors and
work/cancellation accounting. Final errors leave the published result untouched.

The candidate matches 31 PostgreSQL fixtures plus visibility, volatile-input,
poisoned-scratch, capacity, invalid-grouping and checkpoint sweeps: 19,443
assertions. It also preserves the prior 6,409-assertion committed group-synopsis
contract; that pre-existing synopsis is a separate mechanism, not SQL ROLLUP.
Snapshot/private-write tests observe the appropriate versions, and volatile
aggregate arguments execute once per input rather than once per rollup level.
Grouped windows can consume GROUPING masks and subtotal states after HAVING.

Multiple/composite ROLLUP elements, CUBE/general GROUPING SETS, and nonintegral
or computed DISTINCT membership remain unimplemented. Wide integral domains may
exceed the admitted bitmap/query budget. Native/platform/server differential
qualification and the unchanged original 5M dbMeter checks are still required.

## Remaining Q06 work

The unsupported window/grouping forms still require implementation and
qualification. Do not rewrite the reviewer's SQL or expected results to avoid
these operators. Preserve peer ties, NULL ordering, empty input, exact numeric
types, HAVING-before-window and LIMIT-after-window semantics. Rollup levels must
remain distinct from real NULL groups; subtotals cannot average group averages
or add independently computed DISTINCT counts.

References: PostgreSQL 18 [formatting](https://www.postgresql.org/docs/18/functions-formatting.html),
[window functions](https://www.postgresql.org/docs/18/functions-window.html),
[grouping sets](https://www.postgresql.org/docs/18/queries-table-expressions.html#QUERIES-GROUPING-SETS).
