# LAG and LEAD inventory slice

ZPM core binds PostgreSQL-style LAG/LEAD with one to three arguments. The result
is the common value/default type; the offset overload is int4 (int2/unknown may
coerce), not bigint/numeric/boolean. Omitted offset is1 and omitted default is
SQL NULL. Offsets are evaluated at the current row, may be negative or zero,
and NULL offsets yield SQL NULL. Value expressions evaluate at the selected
partition row. Defaults evaluate at the current row only outside the partition;
a selected SQL NULL does not activate the default. Immutable constant errors
are validated before execution, including an unused invalid constant default.

The executor reuses sorted partition handles and caller-owned cells. Target
index arithmetic is i64 over int4 offsets and u32 workspace handles, so INT_MIN
and INT_MAX cannot wrap. Each row and ordinary expression participates in
ExecutionControl. Arguments remain deferred instead of materializing values for
unselected rows. Frame boundaries do not restrict offset navigation; native-style
frame-offset validation still runs. A valid call without OVER gives42809.

## Qualification scope

The initial fixture set contains90 exact PostgreSQL16.15 programs with values,
result types and SQLSTATEs: partitions, reverse order, current-row-only frames,
positive/negative/zero/extreme/per-row/NULL offsets, NULL/default values, numeric
promotion, JSONB/text, invalid arity/types and runtime frame errors. Additional
core checks cover grouped aggregates, temporal promotion, lazy throwing inputs,
sequence side effects, work-budget/cancel cleanup and the projected-column budget.
The unchanged full inventory is still intentionally red; a smoke pass is not
closure of the window family.

Throwing or volatile offset expressions currently require a single window in the
root query and repeatable surrounding projections. For finite LIMIT, the final
ordering/projection must map directly to a prefix of the window ordering (or
have no final ORDER BY). The executor then evaluates only the consumed prefix,
including rows consumed by OFFSET, while retaining access to the full partition
for target navigation. Descending order and partition-order prefixes are tested. Partition keys use
PostgreSQL ASC NULLS LAST; nullable-partition sequence tests verify the actual
cross-partition evaluation order, and the demand proof uses the same policy.

Nested/CTE/DML/set-operation uses of non-total or nonrepeatable arguments, multiple
such windows and uncertain final-order demand return0A000. Materialized nested
execution cannot yet propagate demand or preserve interleaved side effects in
these combinations. Rejection avoids silently over-advancing sequences or
throwing from unconsumed rows. LIMIT0 retains no-execution behavior. These remain
explicit feature gaps, alongside correlated subqueries and named windows.

Other remaining windows include percent_rank, cume_dist, ntile, first_value,
last_value, nth_value, named-window inheritance, nonintegral RANGE offsets, and
broader demand/side-effect correctness. General array/record values and collations
are separate inventory foundations. No full-window, SQL compatibility, capacity
or benchmark claim is made by this slice.

Reference: [PostgreSQL18 window functions](https://www.postgresql.org/docs/18/functions-window.html).

## Observed candidate verification

ReleaseSafe offsets:2,017 assertions on Windows and independently on Linux.
The independent Linux reviewer also reran the unchanged windows contract
(8,801 assertions, work-threshold-dependent count) and frame contract
(106,873 assertions), all exit0. All90 frozen fixtures were independently
re-executed against PostgreSQL16 and matched. The baseline ae93633 fails the
first offset fixture with UndefinedFunction. Review reproduced and verified
fixes for internal tuple capacity, parent demand rejection, unconsumed throwing
inputs and nullable partition sequence order. No measured performance claim.

The unchanged118-program inventory yields **10 smoke passes /91 failures /
17 unexecuted**, with required exit1 SqlConformanceIncomplete. Input/output
hashes are in tests/sql_conformance/window_offsets_evidence.json. Hosted three-OS,
server wire and PG18 qualification is pending; broad family closure is incomplete.
