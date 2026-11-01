# Basic numeric functions

This candidate implements `abs`, `ceil`/`ceiling`, `floor`, `trunc` and `sign`
in ZPM Layer 0. RAMSQL remains the facade/server integration layer. Runtime
storage and intermediate arithmetic are fixed-capacity and allocator-free.
This is a slice of the numeric inventory, not the whole mathematical family.

## Overloads and arithmetic

ABS preserves int2/int4/int8, real, double precision or numeric input types.
Integer minimum values raise 22003. The other one-argument functions select
numeric for numeric input and double precision for integral/real/double input.
Unknown literals prefer double precision, except one-argument TRUNC: native
PostgreSQL also has network-address overloads, so an unknown argument is
ambiguous (42725). TRUNC(numeric,int4) accepts implicit integral/numeric first
arguments and unknown/int2/int4 scale arguments; float and int8-scale variants
are rejected. CEILING is an alias for CEIL. Output typmods are unconstrained.

Decimal operations retain the existing exact coefficient/display model. ABS
preserves display scale; SIGN and directed integer operations return scale 0.
TRUNC rounds toward zero, including negative scales, and retains max(scale,0)
display decimals. Scale arithmetic widens before subtraction/negation, including
INT_MIN; expansion checks capacity before multiplication. NaN and infinities
follow their native overload behavior, including float SIGN(NaN)=0 and numeric
SIGN(NaN)=NaN. Float operations preserve native signed-zero behavior.

The configured numeric coefficient/display capacities still apply and errors
remain explicit. This work does not provide PostgreSQL's full numeric range,
new physical storage, additional functions (sqrt, power, logs, trig, etc.), or
arbitrary mathematical overloads. It makes no performance superiority claim.

## NULL, errors and side effects

Arguments are fully typed and semantically validated. A syntactic NULL or cast
chain to NULL marks a strict numeric call as producing NULL without executing
its children. Grouping validation still sees discarded dependencies; aggregate
registration and window lowering skip discarded execution. A NULL from a row
column retains eager argument evaluation, including sequence side effects.

A separate pass validates immutable constants inside these discarded calls
before aggregate/window lowering detaches arguments from their CASE owners.
Per-plan results are deferred until semantic binding completes and only reported
for reachable plans. Unused named-window frame/key specifications still receive
their independent native constant validation. It follows CASE/COALESCE
reachability and does not execute sequence calls, clocks, aggregates or
subqueries. Thus `trunc(NULL::numeric,(1/0)::int4)` raises 22012, while the same
call in a constant-false CASE branch is skipped. Stored default expressions use
their own source text and are evaluated at use, not at CREATE. Existing generated
expression validation and typed WAL replay are preserved. Broader PostgreSQL
constant folding, planner error timing and arbitrary expressions proven NULL are
not claimed by this narrow pass. In particular, unused derived-table output
pruning remains missing: PostgreSQL returns 7 for
`SELECT 7 FROM (SELECT trunc(NULL::numeric,(1/0)::int4) AS x) q`, while the
candidate reports 22012. This is tracked in
[the numeric planner gaps](../tests/sql_conformance/numeric_planner_gaps.json),
not counted as a passing parity test.

## Evidence and reproduction

The initial test on the preceding source failed `abs(-17)` with
UndefinedFunction (exit 1). The current ReleaseSafe contract passes 1,266
assertions, including a 204-query independently calculated decimal matrix.
The native PostgreSQL 16.15 verifier passes those 204 queries plus 116 additional
probes. Tests cover overload SQLSTATEs, decimal boundaries, NaN/infinity/zero,
strict calls with volatile/aggregate/window arguments, semantic errors, dead
branches, runtime NULLs, generated values, failed-statement atomicity, schema
WAL replay and execution control. The expression397, DML229, expression-source75, generated132, windows9035,
frame108118, value6179 and conditional220 regression suites passed during
implementation; final Linux also passes1266 assertions and independent review reruns both the
Windows contract and native oracle successfully. The unchanged118-program
inventory remains12 smoke passes,89 failures,17 unexecuted and exits1
SqlConformanceIncomplete (PG.FUNC.NUMERIC still stops at SQRT). Hashes and
counts are in [numeric_functions_evidence.json](../tests/sql_conformance/numeric_functions_evidence.json).
RAMSQL wire integration and hosted qualification remain pending.

```powershell
python .scratch/inventory/run_contract.py test_sql_numeric_functions sql src/core/sql.sig
wsl -d Ubuntu -u postgres -- python3 /mnt/c/Just-Things/Projects/sb0/zpm-sql-numeric-functions-20261101/tests/sql_conformance/verify_numeric_functions_oracle.py --port 5432 --unix-socket /var/run/postgresql/.s.PGSQL.5432 --expected-server-version 160015 --report /mnt/c/Just-Things/Projects/sb0/zpm-sql-numeric-functions-20261101/tests/sql_conformance/numeric_functions_oracle.json
```

The scratch helper uses the locally prepared matched Sig 0.6.4 SDK; the checked-in
contract is registered under `sig build test-sql`. The native verifier also
supports an explicitly selected TCP instance and exact expected server version.
No native oracle is replaced with candidate output.

Reference: [PostgreSQL mathematical functions](https://www.postgresql.org/docs/18/functions-math.html).
