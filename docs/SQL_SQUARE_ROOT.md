# SQRT implementation and native qualification

The candidate adds PostgreSQL-shaped SQRT overloads in ZPM Layer 0 SQL and
reuses the existing allocator-free integer-root primitive in Sig
`std.math.sqrt`. It introduces no duplicate public math module or runtime
dependency. A composition contract imports both official ZPM math and SQL
packages, guarding their independent module ownership. Integral/real/unknown
inputs choose float8; numeric inputs retain exact decimal arithmetic. Negative
inputs use SQLSTATE 2201F, including negative infinity; NaN, positive infinity,
NULL and float negative zero follow the native overload behavior.

The SQL test failed first: the baseline returned UndefinedFunction at
sqrt(1::numeric). The current Windows ReleaseSafe kernel verification passes
133,905 assertions and the SQL contract passes 375 assertions. The kernel
verification tests an existing SDK primitive; it is not evidence that a new
math function was missing from Sig. Native PostgreSQL 16.15 verifies 109 frozen
cases (88 independent Decimal results) plus 14 mutation/default probes across 21
statements. Capacity and work-control cases are explicitly Sig-only; they are
not native parity passes. Broader math and planner compatibility remain open.

## Exact bounded decimal algorithm

For a stored coefficient C and display scale d, let w be its base10000 weight
(zero uses w=0). Use the native scale rule t=max(16-(2w+1),d,0). This display
selection follows [PostgreSQL18.3 numeric_sqrt](https://github.com/postgres/postgres/blob/REL_18_3/src/backend/utils/adt/numeric.c#L3592).
The actual root can use independent integer arithmetic:

1. Compute the integer N=C*10^(2t-d).
2. Compute q=floor(sqrt(N)) and remainder r=N-q*q exactly.
3. Return coefficient q+(r>q) with display scale t.

The rounding threshold is (q+1/2)^2=q*q+q+1/4. Because N is integer, the
coefficient rounds upward exactly when r>q. No floating approximation enters
the decimal result. Sig already supplies the reusable exact integer kernel; SQL scale, errors and
special values stay in core/sql/numeric.sig. SQL uses that shared standard
module directly so public ZPM math and SQL modules can coexist.

The current numeric representation permits at most 76 coefficient digits and
120 display decimals. For its inputs, 2t-d is nonnegative and at most 120, so
N<10^196<2^652. A u1024 intermediate therefore suffices; the existing power table
already covers the required exponents. The standard kernel processes base4 digits with fixed storage and a bounded
number of steps. Before the kernel, the SQL implementation rejects capacities
exactly: with L = 10^digits, the rounded coefficient reaches L at integer
N>=L*L-L+1. Valid radicands therefore fit u512; u128/u256 kernels are selected
for smaller values, and zero takes a direct path.
No heap or general-purpose allocator is needed.

Configured output coefficient capacity still applies. Some native results need
more stored coefficient digits even though their inputs fit; those cases must
return NumericCapacity atomically, not truncate precision or overrun storage.
This work will not establish PostgreSQL's unrestricted numeric range.

## Validation and remaining gates

The composition contract passes 3 assertions. The kernel verification exhausts values 0..65536 against an independent linear oracle,
checks all u8 inputs, tiny and odd widths up to 1023 bits, maximal u1024 input,
and 512 wide square/rounding boundaries. The SQL test adds generated/default
values, failing multi-row INSERT/UPDATE atomicity, source ownership, poisoned
schema WAL replay, output capacity and work-control/reuse. The PostgreSQL codec
maps the domain error to 2201F and has an explicit mapping assertion.

Broader PostgreSQL constant-fold timing, unused derived-output pruning, full
mathematical overloads and unrestricted numeric precision are not established.
The unchanged broad inventory and remaining math programs must stay open. In
particular, `SELECT sqrt(-1::numeric) WHERE FALSE` raises2201F on native
PostgreSQL 16.15 but returns zero rows successfully on the candidate. This
observed general planner gap is recorded in
[square_root_planner_gaps.json](../tests/sql_conformance/square_root_planner_gaps.json);
it is excluded from passing parity counts and remains a required follow-up.


Reproduce local targeted evidence:

```powershell
python .scratch/inventory/run_contract.py test_integer_square_root math src/core/math.sig
python .scratch/inventory/run_composition.py
python .scratch/inventory/run_contract.py test_sql_square_root sql src/core/sql.sig
wsl -d Ubuntu -u postgres -- python3 /mnt/c/Just-Things/Projects/sb0/zpm-sql-square-root-20261101/tools/capture_sql_square_root_oracle.py --unix-socket /var/run/postgresql/.s.PGSQL.5432 --expected-version 160015 --report /mnt/c/Just-Things/Projects/sb0/zpm-sql-square-root-20261101/tests/fixtures/square_root_pg16.json
```

The scratch build helper uses the prepared matched Sig 0.6.4 SDK; both contracts
are registered under test-sql. The native tool uses 256 working Decimal digits
and verifies text/OID/typmod before generating expected data. An explicit
--contract option regenerates only the marked frozen-case block and preserves
manual adversarial tests. It never uses candidate output as its oracle.

Fresh independent review, final Linux/regression/inventory runs, RAMSQL wire
integration and hosted PG16/18/OS/release gates are still required before merge.

Final local Linux verification also passes 375 SQL,133905 kernel,3 composition
and 17327 PostgreSQL codec assertions. Expressions 397, DML 229, source 75,
generated 132, basic numeric 1266 and change-log 940 regressions pass. The unchanged
118-program inventory remains 12 smoke passes, 89 failures, 17 unexecuted, expected
exit 1 SqlConformanceIncomplete. Scoped independent review approved the declared
implementation and reproduced its native/Windows/composition evidence; the
explicit global planner gaps remain open. Input/output provenance is in
[square_root_evidence.json](../tests/sql_conformance/square_root_evidence.json).

The first hosted runs failed before contracts because the build graph registered
public math twice. Its existing registration now precedes contract imports;
all three contracts remain separate. Graph assembly with `sig build --help`
passes. Fresh hosted qualification is required for this graph correction.
The canonical build command for the three contracts also passes: six build/run
nodes succeed, zero fail,342 unrelated nodes are unselected. Independent static
review confirmed the registration-order correction against the actual SDK.
