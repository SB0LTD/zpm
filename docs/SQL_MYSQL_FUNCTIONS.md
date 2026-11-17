# MySQL IFNULL and DATE_ADD

- `IFNULL(a,b)` accepts signed INT and BIGINT operands and SQL NULL when the
  other operand has a supported type. It evaluates the second argument only
  if the first is NULL. Signed integer literals select BIGINT. This slice
  leaves mixed types, SMALLINT and two untyped NULLs unsupported.
- `DATE_ADD(base, INTERVAL count DAY)` and `DATE_ADD(base, INTERVAL count MONTH)`
  accept a DATE or canonical `YYYY-MM-DD` text, with a signed integral count.
  MONTH clips the day to the end of the destination month. SQL NULL propagates
  and canonical invalid dates return NULL. Inputs and results using year zero
  or earlier are outside this slice. Positive overflow past year 9999 returns
  NULL. Datetime inputs, alternate string formats, nonintegral counts, other
  interval units and MySQL warning reporting are unsupported.
- A DATE operand produces a DATE result. A canonical text operand produces
  MySQL fixed string type 254 with scale 31 and canonical date text. A DATE
  result uses type 10 with scale 0. The wire codec retains its existing
  defaults for collation, flags other than signedness, and field width. An unaliased
  function projection uses its source expression as the column name within
  the configured name capacity.
- The parser admits these forms in live MySQL SQL. Stored SQL definitions and
  alpha SQL replay retain their existing grammar.
