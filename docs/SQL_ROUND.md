# PostgreSQL ROUND overloads

The SQL binder and evaluator provide `round(numeric)`, `round(numeric, integer)`
and `round(double precision)`. The two-argument form accepts implicit numeric
input and an int4-compatible scale; it does not invent a float8/int4 overload.
Single integral, real and unknown arguments resolve to the preferred float8
overload, as verified against native PostgreSQL 18.3. A numeric argument retains
numeric output. NULL arguments produce NULL.

Decimal results reuse the existing fixed-precision numeric implementation and
round ties away from zero, including negative scales. Float8 uses deterministic
nearest-even rounding, retains signed zero and handles NaN/infinity without
unbounded integer conversion. This matches the native Windows reference;
PostgreSQL documents that floating tie behavior can vary by platform.
See the [PostgreSQL mathematical function reference](https://www.postgresql.org/docs/current/functions-math.html).

The existing numeric capacities still apply: default 64 coefficient digits and
120 display-scale places, configurable coefficient precision up to 76 digits.
Unrepresentable results return NumericCapacity rather than overflowing a wide
temporary. The entire int4 scale range is handled without subtraction overflow;
sufficiently negative scales produce zero and oversized positive scales fail
within the existing capacity contract. Special numeric values retain their value.

There is no allocator or libc dependency. The shared float rounding helper also
serves float-to-integer casts. The SQL function works over columns and aggregate
expressions; failed evaluation preserves the caller's previous result.
The executor recognizes ROUND as deterministic when selecting streaming
aggregation or safely retrying an operator. Its arguments are still inspected:
wrapping a sequence, clock or subquery cannot bypass the existing restrictions.
This also permits a streaming CTE when ROUND appears in its outer query.
The 100k-row streamed-aggregate contract uses only 1,024 query references and
checks grouped rounded SUM/AVG, an outer rounded CTE projection, and a wrapped
sequence call that must remain excluded from repeatable execution.

`test_sql_types.sig` exercises 2,001 signed decimal inputs against an independent
integer quantization model, 129 even/odd float half-steps, metadata/overload
resolution, NULLs, signed zero, large floats, special values, extreme scales,
coefficient widening, aggregate/HAVING expressions and publication on errors.
Measured native PostgreSQL fixture outputs are retained in
`tests/evidence/round-postgres-windows.json`. This closes the ROUND capability
gap; it does not establish full-suite five-million-row acceptance, window
functions, date formatting, grouping sets or general PostgreSQL parity.
