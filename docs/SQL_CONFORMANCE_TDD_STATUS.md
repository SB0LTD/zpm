# SQL conformance TDD checkpoint

2026-10-29. Branch `feat/sql-conformance-tdd`, isolated from concurrent RAMSQL
performance work. Baseline: ZPM `53655a9a89a3ddff6f2f5829388b09a10c3d9c93`.

## Main integration

The SQL work was integrated with upstream main `41d8dac` and the useful changes
from legacy master `42deef7`, preserving both histories. The only master merge
conflict was build registration; SQL/performance and Solana/game registrations
are all retained. The resulting native build passes 32 SQL, five Solana and one
game contract executables, plus nine Python harness tests. Source hashes and
the full Windows ReleaseSafe build log are recorded in
[main integration provenance](research/main-integration-20261029/provenance.json).
Historical milestone evidence below describes its original commits; it must not
be mistaken for the current merged source fingerprint. The broad conformance
audit remains incomplete, and host tests do not qualify on-chain or Android
device deployment.

## Implemented in this batch

### Follow-up: bare NULL candidates in row lists

`ROW(a,b) IN (NULL,...)` and NOT IN now treat a bare NULL candidate as
unknown without constructing a record payload or evaluating that candidate's
left operand. Other candidates retain their normal comparison/evaluation rules.
This also covers empty constructors compared only with NULL.

The retained AST records name/grouping dependencies. Grouping validation checks
them without registering eliminated aggregates, so discarded aggregates do not
run or overflow. A flagged post-binding pass validates immutable constant
subexpressions, respecting CASE/COALESCE selection and avoiding sequence/clock
evaluation. Statements without NULL row candidates skip that pass. Binding and
grouping errors take precedence over constant-evaluation errors.

The new test first failed with UnsupportedStatement. The independent PostgreSQL
18.3 oracle passes 43 probes; the Sig contract passes 98 assertions in Windows
ReleaseSafe and Debug, including replay, cancellation, errors, grouping,
volatile calls and eliminated aggregates. Twelve Python tests verify the
harness/evidence. The earlier constructor-list contract now accepts its former
bare-NULL rejection case; its refreshed native evidence has 2,916 matrix queries
and 41 additional probes. Earlier assertion counts below are historical.

See [row NULL oracle](../tests/sql_conformance/row_null_oracle.json) and
[contract](../tests/test_sql_row_null_candidates.sig). This closes bare NULL
candidates; general record payloads, nested records and row subquery/ANY/ALL
forms remain unqualified. The constant pass is scoped to discarded row operands,
not a claim of complete PostgreSQL optimizer equivalence.

### Follow-up: flat row-constructor membership

`ROW(a,b) IN (ROW(x,y),...)` and tuple shorthand now bind independent
field-pair equality operators per candidate. A flat predicate list folds their
three-valued results and short-circuits on a match; NOT IN negates that result.
Each candidate owns its left expression, matching PostgreSQL's repeated
evaluation of volatile operands. Strict equality against a literal NULL omits
the other operand's evaluation, while runtime NULLs retain normal evaluation.

The implementation reuses the statement AST pool and existing row comparator;
it adds no record payload or heap allocation. Binding consumes O(candidates ×
fields) AST storage, with ordinary StatementTooComplex errors on exhaustion.
The flat list avoids an execution-depth increase per candidate: 64 candidates
pass with an expression-depth budget of five and sufficient AST storage.
Schema deparsing uses equivalent OR comparisons, subject to the existing
schema-expression size and depth budgets.

The contract first failed with UnsupportedStatement. The completed suite passes
5,928 assertions in Windows ReleaseSafe and Debug. The independent PostgreSQL
18.3 oracle passes 2,916 finite matrix cases plus 40 targeted probes covering
types, volatile calls, NULLs, grouping, joins, correlation, mutations and errors.
Schema replay, cancellation, work limits and AST exhaustion are checked in Sig.
See [membership oracle](../tests/sql_conformance/membership_oracle.json) and
[the contract](../tests/test_sql_row_membership.sig). Eleven Python tests check
the oracle/harness identity and semantic comparison machinery.

This qualifies flat constructor lists. General record values (including bare
NULL record candidates), nested records, row subquery membership and row
ANY/ALL remain unqualified and are not counted as passing compatibility cases.
PostgreSQL's [IN lowering](https://doxygen.postgresql.org/parse__expr_8c.html)
informs the repeated-left-expression design; performance superiority is not
claimed by these correctness tests.

### Follow-up: NULLIF cross-type results

`NULLIF(real, double precision)`, mixed date/timestamp comparisons, and
name/text comparisons now retain the selected equality operator's original
first-operand type and value. Numeric combinations that require promotion keep
their promoted result type. The comparison-only cast uses caller storage and
evaluates each operand once, including volatile sequence calls and aggregate
inputs. No AST child is duplicated, and evaluation checkpoints are preserved.

The new contract first failed with OID 701 instead of PostgreSQL's 700. After
the fix, 24 PostgreSQL 18.3 oracle cases and 93 assertions pass in both Windows
ReleaseSafe and ReleaseFast. Coverage includes payload tags, NULL metadata,
sequences, column and aggregate inputs, and error/result preservation. See
[the oracle](../tests/sql_conformance/nullif_oracle.json) and
[the executable contract](../tests/test_sql_nullif_types.sig).
This closes a result-type bug; it does not qualify all SQL functionality.

### Original conformance batch

- Scalar `IS DISTINCT FROM` and `IS NOT DISTINCT FROM`: grammar, common comparison
  binding, non-null Boolean evaluation and expression deparsing. The evaluator
  borrows stable column operands and evaluates computed operands once. Existing
  unsupported fast paths conservatively fall back to generic execution.
- `GREATEST` and `LEAST`: special SQL grammar forms, common argument typing,
  PostgreSQL NULL exclusion, ordering over supported comparable scalar types,
  eager argument evaluation and schema-expression round trips. Quoted ordinary
  function names do not acquire these special semantics.
- Neither feature adds heap allocation, platform dependencies or a higher-layer
  RAMSQL dependency to the SQL core. Existing caller storage and work/cancellation
  contracts remain in force.

## Evidence

Both contracts failed before implementation: `Syntax` for null-safe equality and
`UndefinedFunction` for `GREATEST`. The recorded red outputs, exact source hashes,
toolchain and regression outputs are in
[evidence.json](../tests/sql_conformance/evidence.json). This is the historical
first-batch record at `a7c4695`, not evidence for later changed source.

The null-safe comparison suite passes 917 assertions in Windows ReleaseSafe and
Debug, including three-by-three typed NULL/value truth tables for 15 orderable
scalar families. Other cases cover mixed types, NaNs, aggregates and right-side
subqueries, joins, volatile sequences, errors, default/generated-expression replay,
work limits and cancellation. The min/max suite passes 49 assertions, covering
NULLs, common types, ordering, side effects, errors and schema replay. Its 23
positive/negative SQL examples were also checked on native PostgreSQL 18.3.

Existing expression, type, query, catalog, change-log, compact-scan and DML suites
pass on the changed SQL core. Harness tests verify wire fragmentation, NULL versus
empty text, Unicode, duplicate-preserving bag comparison, type/typmod metadata,
error rejection, and versioned manifest/evidence consistency.

This is Windows validation, not all-platform qualification. Prepared-wire behavior,
concurrent schedules and crash durability require integration-level closure.

## Second batch: quantified scalar subqueries

`ANY`, `SOME` and `ALL` now support the six ordinary scalar comparison operators
over one-column subqueries, including correlated queries, CTEs, set-operation
results and aggregate operands. IN and quantified forms share binding and the
same evaluator. `ALL(op)` is normalized to `NOT ANY(opposite(op))`, preserving
three-valued logic without enlarging expression nodes. Ordinary non-associative
comparisons and valid post-sublink casts/operators have native-oracle tests.
New ANY/SOME keyword reservation preserves the frozen alpha identifier behavior.

The focused suite passes 3,582 assertions in ReleaseSafe and Debug on Windows.
Native PostgreSQL 18.3 passes all 1,152 generated NULL/empty/subset/operator cases
and 42 additional positive/negative SQL probes. Both implementations produce
matrix digest `7886b30b421deb63`; the digest identifies the finite test matrix,
not a proof for arbitrary SQL. Native evidence is
[quantified_oracle.json](../tests/sql_conformance/quantified_oracle.json).
All 26 default SQL contract executables pass in ReleaseSafe: 440,666 assertions.
The complete outputs, source hashes, red-before-green failures and Debug result
are in [quantified_evidence.json](../tests/sql_conformance/quantified_evidence.json).
Validation paused while another shared-host benchmark ran, then resumed the
unchecked contracts after that campaign completed. These are correctness results,
not throughput measurements.
Sig-only tests additionally check cache reset across statements, READ COMMITTED
and own-write/abort visibility, frozen replay names, work/cancellation errors,
workspace exhaustion and unchanged results after failures.

The tests found and corrected two shared issues: JSON equality was incorrectly
accepted by IN subqueries, and mixed REAL/exact comparisons rounded exact operands
to REAL instead of selecting the float8 comparison domain. Common-result typing
for GREATEST/CASE remains distinct from operator comparison typing. The default
expression-contract database footprint remains 315,168 bytes after normalization.

This is partial SELECT-context quantified-comparison support. DML contexts remain
unqualified. Array/row forms, LIKE/ILIKE and
custom operators remain open. The executor still materializes subqueries in
bounded workspace; it does not yet have constant-space streamed reducers for
large subquery results. Server wire preparation, crash/replay integration and
all-platform qualification remain separate work.

The semantic reference is PostgreSQL 18's
[subquery expressions](https://www.postgresql.org/docs/18/functions-subquery.html);
[row and array comparisons](https://www.postgresql.org/docs/18/functions-comparisons.html)
are separately specified and must not be inferred from these scalar-subquery tests.

## Third batch: flat row-constructor predicates

Explicit `ROW(a,b)` and implicit `(a,b)` constructors now support `= <> != < <= >
>= IS DISTINCT FROM IS NOT DISTINCT FROM` against another flat constructor.
Constructor `IS NULL` and `IS NOT NULL` tests follow their separate all-fields
rules; neither is implemented as the complement of the other. Ordering stops at
the first unequal or NULL pair, while equality can continue past NULLs to find a
later mismatch. Empty constructors follow the native distinction: ordinary
comparison is unsupported, distinctness and NULL tests have defined Boolean results.

Binding builds a list of typed field pairs in caller-owned statement storage.
Execution borrows stable column operands and uses fixed Cell scratch rather than
constructing a heap record or copying every field into a temporary tuple. AST
cloning, grouping rewrites, dependency walks, safe early filters and expression
deparsing visit every field. Defaults/generated expressions survive kind-3 schema
record replay without changing the log format.

All 27 default SQL contract executables pass: 449,096 assertions. The focused row
suite passes 8,430 assertions in ReleaseSafe and Debug. Native PostgreSQL 18.3
passes the independent 4,160-case matrix plus 49 additional SQL probes, covering
NULLs, order, types, sequence effects, correlation, grouping, DML and errors.
Both implementations identify the matrix as `c35321a7fe106b6f`. Additional Sig
contracts check schema replay, cancellation, exhausted AST grants and untouched
results after failures. A 16-field predicate works with an eight-column result
configuration; the explicit AST-budget test rejects excess work without truncation.

Current proof is [row_evidence.json](../tests/sql_conformance/row_evidence.json),
with [row_oracle.json](../tests/sql_conformance/row_oracle.json). The previous
quantified record is historical at `b2d8474` and retains its archived smoke run.
These are Windows correctness results, not database throughput measurements.

This does not provide general record values. Projection/storage of records,
nested records, field selection, whole-row/table-star expansion, row membership,
quantified row comparisons and row BETWEEN remain open. Those scopes must not
be inferred from a passing constructor-predicate test. Prepared-wire and other
platform qualification also remain incomplete. Native semantics are specified in
[PostgreSQL row comparisons](https://www.postgresql.org/docs/18/functions-comparisons.html).

## The broad audit remains red

The [inventory](../tests/sql_conformance/README.md) contains 118 stable smoke
programs. Native PostgreSQL 18.3 accepted all 102 transaction-harness programs;
16 require additional execution scopes. Expected results are checked into
`postgres18_oracle.json` with a manifest SHA-256, and generate an allocator-free
Sig core test executable.

Current core results: **4 smoke passes, 97 failures, 17 unexecuted scopes or
comparators**. A smoke pass does not close a full feature family. A core utility
rejection also does not establish what the server integration implements. The
suite intentionally exits with an error until the declared scope is qualified.

The separate PostgreSQL upstream inventory contains 755 standard feature records.
Their applicability/mapping is still unreviewed. Many routines, overloads,
administrative features and dialect-specific behaviors need additional contracts;
118 probes are not an exhaustive compatibility test suite.

## Next batches

1. Remaining row membership/quantified forms and general record values need
   native type, NULL and volatile-operand tests first. Record payload ownership
   and shape must be defined before exposing record results. Add streamed
   subquery reducers behind independent result/state tests and explicit workspace
   accounting; then continue the remaining predicate syntax.
2. Expand semantic typing/function contracts, then relational composition,
   windows and grouping; retain independent reference execution and explicit
   optimizer legality checks.
3. Schema/dependency/constraint and DML features, including WAL failures and replay.
4. Multi-session transaction, locking, security, routine, COPY, catalog and native
   dialect harnesses. Adjudicate every applicable upstream feature before a full
   compatibility claim.
5. Apply the [costed execution design](SQL_EXECUTION_REDESIGN.md) through measured,
   separately tested physical implementations. Typed base blocks, MVCC deltas,
   shared task scheduling and adaptive operators remain proposals until validated.

No release or performance-superiority claim follows from this checkpoint. The
next release decision needs the declared SQL scope, integration/system evidence,
and reproducible workload results in addition to these core regressions.
