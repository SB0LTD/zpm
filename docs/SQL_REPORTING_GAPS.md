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

## Q06 remains open

RANK OVER, aggregate windows, partition/order/frame processing, and ROLLUP must
be implemented in parser/binder/execution with caller-owned storage and
cancellation. Do not rewrite the reviewer's SQL or expected results to avoid
these operators. Preserve peer ties, NULL ordering, empty input, exact numeric
types, HAVING-before-window and LIMIT-after-window semantics. Rollup levels must
remain distinct from real NULL groups; subtotals cannot average group averages
or add independently computed DISTINCT counts.

References: PostgreSQL 18 [formatting](https://www.postgresql.org/docs/18/functions-formatting.html),
[window functions](https://www.postgresql.org/docs/18/functions-window.html),
[grouping sets](https://www.postgresql.org/docs/18/queries-table-expressions.html#QUERIES-GROUPING-SETS).
