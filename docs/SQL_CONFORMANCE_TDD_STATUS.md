# SQL conformance TDD checkpoint

## Latest candidate checkpoint - 1 November 2026

The unchanged 118-program driver has **12 smoke passes, 89 failures and 17
unexecuted scopes/comparators**, and still exits1 SqlConformanceIncomplete.
JSON extraction/concatenation, LAG/LEAD, distribution ranking and named windows
have finite implementations and qualified main integrations. Frame value windows
also qualified their declared finite scope; their native boundary differences
remain open (see SQL_WINDOW_VALUES.md). Conditional DDL and quoted-name recovery qualified and merged in ZPM PR93 and
RAMSQL PR46. ZPM database matrix41259206264, RAMSQL CI41259423089 and release
qualification41259423088 passed. The broad legacy ZPM graph retains four
unrelated SABR/TLS/TTS failures (314 successes,22 skips).

Basic ABS/CEIL/FLOOR/TRUNC/SIGN functions qualified and merged in ZPM PR94
(main f4e3c61) and RAMSQL PR47 (main79d0fc0). ZPM database matrix41262543271,
RAMSQL CI41300988243 and release qualification41300988055 passed; the latter
has24 active successes and2 policy skips. The initial release Windows job timed
out at20 minutes; reviewed job budget30 preserves all checks. The broad legacy
ZPM graph retains4 unrelated failures,316 successes and22 skips.

SQRT is the next candidate; [SQL_SQUARE_ROOT.md](SQL_SQUARE_ROOT.md) records
its current evidence and pending gates. The mathematical family remains open,
including POWER/LN and the explicit planner/precision gaps.
These results do not close the SQL inventory.

The dated checkpoints below preserve historical qualification evidence.

## Historical checkpoint â€” 30 October 2026, after PR consolidation

The original feature map is
[tests/sql_conformance/README.md](../tests/sql_conformance/README.md), backed by
118 stable programs in `cases.json` and the 755-record upstream feature list.
It has now been rerun on consolidated main
`2c0ac40afa11177158b1eac5f8e7cb9bce1c72c7`, whose complete source tree matches
the qualified integration source `0f5af8d`. The original SQL/expected oracle
programs were unchanged.

**Historical result: 8 smoke passes, 93 failures, 17 unexecuted scopes/comparators.**
The executable intentionally returns SqlConformanceIncomplete. Preserve the
former 6/95/17 output as `core_smoke_results.stage4.ndjson`; the new output,
source hashes, tree identity and expected nonzero exit are recorded in
[consolidation_evidence.json](../tests/sql_conformance/consolidation_evidence.json).
These are targeted gap probes, not a PostgreSQL compatibility percentage.

| Inventory item | Reconciled state |
| --- | --- |
| Aggregate windows | The original smoke program now passes; default/prefix totals are implemented |
| ROLLUP/GROUPING | The original smoke program now passes; flat prefixes/empty grouping set are implemented |
| Ranking/offset windows | Probe advances from Syntax to UndefinedFunction: ranking works, LAG/LEAD do not |
| Named windows/frames | Combined named-window probe still fails; bounded ROWS/GROUPS, integral RANGE, exclusions and aggregate FILTER are independently implemented/tested |
| Formatting | Temporal to_char works; the combined probe still fails because to_date/to_number are missing |
| Earlier predicate slices | NULL-safe equality, scalar-subquery ANY/SOME/ALL, flat row predicates/list membership/BETWEEN, LIKE ESCAPE and GREATEST/LEAST retain their stated finite coverage |
| System/native dialect cases | 17 are unexecuted in this driver; separate server tests do not imply full SQL or native MySQL/T-SQL qualification |

The frame/FILTER contract replays 397 PostgreSQL 16.15 fixtures and executes
106,873 assertions, with caller-owned prefix/tree state, scalar fallback,
snapshot/private-write, poisoning, limits, cancellation and side-effect checks.
Scope and algorithm limitations are in [SQL_WINDOW_FRAMES.md](SQL_WINDOW_FRAMES.md).
DISTINCT windows are unsupported in PostgreSQL itself and are not an additional
PostgreSQL-parity feature to implement.

The consolidation merged ZPM PRs 77, 81 and 82â€“85 and RAMSQL PRs 30, 34 and 36.
It includes the newer parameter-boundary, DDL-replay, lock-upgrade and explicit
durable-create fixes plus the committed hardening audit. Seven inconclusive
performance experiments and the failed-advantage dbMeter workflow PR were closed
with branches/evidence preserved. All 17 original PRs are accounted for; see the
[consolidation decisions](PR_CONSOLIDATION_20261030.md).

Fresh qualification: ZPM's Linux/macOS/Windows database matrix
[41114412805](https://github.com/SB0LTD/zpm/actions/runs/41114412805) passes;
RAMSQL [CI 41114733707](https://github.com/SB0LTD/ramsql/actions/runs/41114733707)
and [release matrix 41114733789](https://github.com/SB0LTD/ramsql/actions/runs/41114733789)
pass all 32 active checks, including PG16/PG18 memory/durable+SCRAM, hosted exact
artifacts and native SB0X/SB0K. The broad legacy graph retains four unrelated
SABR/TLS/TTS failures, with 300 successes and 22 skips; it is not reported green.

### Temporal correctness follow-up

The SQLF-01 overflow paths and SQLF-05 infinite-date subtraction are now covered
by checked arithmetic/operator fixes and PostgreSQL boundary regressions; see
[SQL_TEMPORAL_BOUNDARIES.md](SQL_TEMPORAL_BOUNDARIES.md). This does not change the
118-program feature inventory or close interval syntax, JSONB or wider temporal
feature gaps. The FV-12 formal proof remains open.

### Snapshot and sequence safety follow-up â€” 31 October 2026

STO-02 and STO-04 now have reproduced regressions and implementation fixes:
running/COPY snapshots participate in reclamation, and a consumer commit
persists a live owner's pending sequence watermark. See
[SQL_SNAPSHOT_SEQUENCE_SAFETY.md](SQL_SNAPSHOT_SEQUENCE_SAFETY.md) for exact scope.
This is safety work and does not close additional SQL feature-map programs.
STO-05, NET-02 and the listed SQL feature gaps remain open.

### What is still missing

1. **Correctness before expansion.** General filter/error placement and planner
   constant folding remain unqualified. Retain the LIKE JOIN/WHERE mismatch and
   native PG16/PG18 projection-timing disagreement. The newer hardening audit's
   SQLF interval parsing, JSONB concatenation and ambiguous-binding cases remain
   open. The temporal follow-up above changes temporal/value/binder source after
   the consolidation baseline; it does not close the remaining feature probes.
2. **Common schema and types.** VARCHAR/CHAR, UUID/BYTEA, TIME/TIMETZ, arrays and
   general records; SERIAL, IF [NOT] EXISTS, ALTER/TRUNCATE, views/schemas,
   secondary indexes and table/composite/UNIQUE/CHECK/FK/deferred constraints
   still block ordinary application schemas. Virtual generation, inheritance
   and partitioning remain beyond the qualified stored-generation slice.
3. **Ordinary functions/operators.** String/math/date/regex/discovery families,
   to_date/to_number, numeric/interval/localized/ISO/timezone formatting,
   remaining JSON/JSONB/SQL-JSON operations and additional aggregates/overloads.
4. **Query composition.** Named and remaining built-in windows; nonintegral or
   temporal RANGE offsets; volatile moving inputs; CUBE/general GROUPING SETS
   and composite ROLLUP; LATERAL/NATURAL/parenthesized joins, table functions,
   modifying/materialized CTE forms, SEARCH/CYCLE, VALUES/TABLE, TABLESAMPLE,
   expression LIMIT/OFFSET and FETCH WITH TIES. Row subquery/ANY/ALL, nested
   records, array predicates and OVERLAPS also remain open.
5. **Mutation and systems.** UPDATE FROM, DELETE USING, tuple assignment, MERGE,
   non-PK arbiters, broader sequence lifecycle; remaining isolation/transaction
   characteristics/locks, cursors, SQL PREPARE, settings/notifications, roles/RLS,
   routines/triggers/rules, catalogs, COPY options, administrative/integration SQL
   and independently qualified native MySQL/T-SQL behavior. READ COMMITTED,
   savepoint, wire-prepare and COPY subsets already have separate passing tests;
   they must not be relabeled wholly absent by a core-only utility failure.
6. **Scale and coverage.** Elastic schema/value storage, compact typed base/MVCC
   data and intra-query scheduling are still needed for the requested 100M-row
   workloads. Original dbMeter full/subset correctness is separately 7/7, but
   run 41024725859 fails its overall advantage gate, including stock 200-byte
   text, nine-column and 20-additional-table probes. No universal performance or
   production-readiness claim follows. The 755 upstream records still need
   reviewed applicability and mappings; these 118 programs do not cover every
   PostgreSQL feature or overload.

The per-ID table in the inventory retains every failure/unexecuted entry.
The newer [RAMSQL feature/divergence audit](https://github.com/SB0LTD/ramsql/blob/main/docs/compatibility/FEATURE_GAPS.md)
and [hardening plan](https://github.com/SB0LTD/ramsql/blob/main/PLAN.md) add
application priorities, safety findings and layer ownership. System findings
such as NET-02 and STO-02/04/05 remain open after the four wave-zero fixes.

## Historical implementation checkpoints

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

### Follow-up: stored generated-column restrictions (2026-10-30)

Stored generation now rejects active mutable functions and context-sensitive
casts/operators with InvalidObjectDefinition (SQLSTATE 42P17). Self-references
and references to other generated columns are rejected even inside discarded
branches. Subqueries are rejected with 0A000; aggregate binding retains 42803.
Built-in immutability/strictness metadata is separate from physical retry safety.
Ordinary defaults retain their permitted volatile behavior.

A scoped planning pass reduces supported CASE, COALESCE, NULLIF, strict NULL
and Boolean-annihilator forms before checking immutability. Functions removed by
these reductions are never executed. Replacements preserve coercion boundaries,
including int4 overflow before widening to int8. Unreachable pool nodes are
excluded from deferred validation; reachable stored operands keep their source
owner. Constants use existing AST slots, with no heap allocation or node-size
increase. No claim of complete PostgreSQL expression-planner equivalence follows.

The first contract failed because an active nextval-generated column was
accepted. The completed suite passes 132 assertions in Windows ReleaseSafe and
Debug, including no sequence/clock effects during planning, hidden mutable calls,
generated dependencies, casts, arithmetic, rollback, replay and interruption
after candidate CREATE metadata exists. Native PostgreSQL 18.3 passes 52 probes.
Sixteen Python tests validate harness/evidence identity. The protocol mapping
contract explicitly checks 42P17. See
[generated oracle](../tests/sql_conformance/generated_oracle.json) and
[contract](../tests/test_sql_generated_restrictions.sig).

Virtual generation, inheritance/partitioning, system-column rules, additional
planner reductions and complete coercion/overload coverage remain unqualified.
These finite results do not close the entire generated-column feature family.

### Follow-up: stored expression source ownership

Deferred validation now resolves literal spans against the owning stored
column expression, instead of the surrounding CREATE/INSERT/UPDATE/COPY SQL.
Strict NULL comparison nodes reuse their existing integer metadata slot for
an owner index; no source pointer is retained and the AST node size is unchanged.
DDL defaults are type-checked without prematurely evaluating discarded
constants. Needed defaults are validated when binding the consuming statement;
defaults overridden by supplied values or unchanged UPDATE columns are not bound.
The masks cover VALUES rows, INSERT SELECT, conflict updates and COPY mapping.

Generated expressions are bound against caller-owned candidate table metadata
before CREATE publishes. Detected binding and discarded-constant errors abort it;
the table is absent afterward and the name can be reused. This does not qualify
every generated-column restriction, such as volatility or generated dependencies.

The new test first failed with InvalidTextRepresentation on a valid numeric
default. It now passes 75 assertions in Windows ReleaseSafe and Debug; 30 native
PostgreSQL 18.3 probes confirm default/generated error phases, source independence,
unused defaults, updates, conflict handling and rollback. Sig additionally checks
COPY components, cancellation/work exhaustion and schema replay after overwriting
the original record buffer. Fifteen Python tests verify harness/evidence identity.
See [source oracle](../tests/sql_conformance/sources_oracle.json) and
[contract](../tests/test_sql_expression_sources.sig).

This closes the stored-source audit item identified in the ESCAPE batch.
General planner error-order equivalence and complete generated-column constraints
remain unqualified. Storage remains caller-owned and existing AST budgets apply.
Performance remains to be measured independently of these correctness tests.

### Follow-up: LIKE / ILIKE ESCAPE

LIKE/ILIKE and their negated forms now accept ESCAPE expressions: empty disables
escaping, otherwise one UTF-8 character is required. Custom escapes include
multibyte characters and wildcard characters themselves. Input, pattern and
escape are evaluated in order; NULL pattern/escape propagation follows the
strict pattern-conversion operation independently of the outer match. Invalid
escape strings use the existing SQLSTATE 22025. Trailing pattern escapes are
reported only when the matching path reaches them, correcting the old test
that expected an error after the input had already ended.

The matcher scans the original pattern with constant scratch, avoiding a
rewritten-pattern buffer and its expansion/capacity costs. UTF-8 underscores
consume one character. ASCII ILIKE folding retains the existing scope; Unicode
case folding and locale/nondeterministic collations remain unqualified. Worst
case rescanning is O(text length Ã— pattern length); matcher and wildcard-run
loops now honor work/cancellation controls. An eight-byte pattern at an
eight-byte text budget succeeds without a larger temporary pattern buffer.

The new contract first failed with Syntax. The completed suite passes 16,348
assertions in Windows ReleaseSafe and Debug. PostgreSQL 18.3 passes 8,120 matrix
cases plus 44 targeted probes, with an independent code-point dynamic-program
reference. Sig additionally checks schema replay, exact work limits and
mid-match cancellation. Fourteen Python tests check harness/evidence identity.
See [oracle](../tests/sql_conformance/like_oracle.json) and
[contract](../tests/test_sql_like_escape.sig).

The ESCAPE-era broad audit had six smoke passes, 95 failures and 17 unexecuted
scopes/comparators. The former four-pass output is preserved as
`core_smoke_results.stage3.ndjson`. These are smoke counts, not a compatibility
percentage or a claim that whole feature families are closed.

**Open planner gap:** with the test fixture's invalid escape on row 8,
`SELECT COUNT(*) FROM lt x JOIN lt y ON x.v LIKE y.p ESCAPE y.e WHERE y.id=1`
returns 1 in PostgreSQL but raises InvalidEscapeSequence in the core because ON
is evaluated before the filtering WHERE clause. The passing JOIN contract uses
a prefiltered relation and does not count that query as compatible. General
filter/error ordering and planner constant-fold error timing remain unqualified.
Stored-expression source ownership then needed dedicated default/generated
audits; the later source-ownership and generation-restriction follow-ups above
address those concrete cases. General planner timing remains open.

### Follow-up: scalar and row BETWEEN variants

Flat row constructors now support BETWEEN / NOT BETWEEN, with optional
ASYMMETRIC or SYMMETRIC. Complex or mixed-domain scalar ranges use the same
lowering. Each comparison resolves its own operand types and owns the required
expression copies, matching PostgreSQL's repeated volatile evaluation. This
also fixes scalar mixed-REAL precision loss from coercing all three operands
into one result type. Simple typed scalar ranges retain their compact scan
shape, including the existing DATE column/literal path.

The lowering uses existing comparison and AND/OR nodes: ordinary ranges need
two comparisons; symmetric ranges need four. All AST storage comes from the
statement pool. Row field comparisons retain lexicographic NULL and
short-circuit behavior. Bare NULL record bounds reuse strict NULL comparison
metadata, including dependency validation and discarded-constant checks. No
record payload or heap allocation is introduced. Deparsing handles the lowered
Boolean forms and compact ranges for default/generated-expression replay.

The new contract first failed with UnsupportedStatement. It passes 17,939
assertions in Windows ReleaseSafe and Debug. The PostgreSQL 18.3 oracle passes
8,910 finite matrix cases plus 62 targeted probes for types, precision,
volatile evaluation, NULL bounds, correlation, grouping, joins, DML and errors.
Sig additionally checks replay, execution controls and AST exhaustion. Thirteen
Python tests verify harness and oracle identity. See
[range oracle](../tests/sql_conformance/between_oracle.json) and
[contract](../tests/test_sql_between.sig).

This qualifies scalar and flat constructor range predicates. General record
payloads and nested records remain unqualified. AST expansion consumes caller
capacity and reports StatementTooComplex on exhaustion; these correctness
checks do not establish performance superiority. The lowering follows
[PostgreSQL comparison semantics](https://www.postgresql.org/docs/18/functions-comparison.html).

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
it adds no record payload or heap allocation. Binding consumes O(candidates Ã—
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

The row-comparison checkpoint proof is [row_evidence.json](../tests/sql_conformance/row_evidence.json),
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

Current core results: **8 smoke passes, 93 failures, 17 unexecuted scopes or
comparators**. A smoke pass does not close a full feature family. A core utility
rejection also does not establish what the server integration implements. The
suite intentionally exits with an error until the declared scope is qualified.

The separate PostgreSQL upstream inventory contains 755 standard feature records.
Their applicability/mapping is still unreviewed. Many routines, overloads,
administrative features and dialect-specific behaviors need additional contracts;
118 probes are not an exhaustive compatibility test suite.

## Next batches

1. Close known wrong-result/crash and planner-order cases with failing native
   differential regressions first; preserve the scoped successes already proved.
2. Prioritize schema/type/constraint and ordinary-function blockers from the
   application audit, then complete the remaining relational/window/grouping and
   row/array predicate forms listed in the current checkpoint. Record payload
   ownership must be defined before exposing general record results. Streamed
   subquery reducers need independent state/result and workspace contracts.
3. Complete schema dependencies and DML, including WAL failure/replay and all
   newly exposed constraint/concurrency interactions.
4. Multi-session transaction, locking, security, routine, COPY, catalog and native
   dialect harnesses. Adjudicate every applicable upstream feature before a full
   compatibility claim.
5. Apply the [costed execution design](SQL_EXECUTION_REDESIGN.md) through measured,
   separately tested physical implementations. Typed base blocks, MVCC deltas,
   shared task scheduling and adaptive operators remain proposals until validated.

No release or performance-superiority claim follows from this checkpoint. The
next release decision needs the declared SQL scope, integration/system evidence,
and reproducible workload results in addition to these core regressions.

### JSON inventory candidate — 31 October 2026

The next slice implements plain JSON extraction and JSONB concatenation and
changes the canonicalizer/work-control paths. Local re-execution of the unchanged
118 programs gives **9 smoke passes / 92 failures / 17 unexecuted**, with the
required SqlConformanceIncomplete failure. The consolidated 8/93/17 baseline above
remains historical qualification evidence. PG.JSONB.MODIFY still fails because
jsonb_set is missing; JSON constructors, aggregates, paths and table functions
remain open. See [SQL_JSON_OPERATORS.md](SQL_JSON_OPERATORS.md) for exact scope,
regressions and capacity limits. Cross-platform/wire qualification is pending.

### Offset-window inventory candidate —31 October2026

LAG/LEAD implement typed offsets/defaults, lazy selected-row evaluation and
bounded root-query prefix demand. Native-reference and independent adversarial
checks are documented in [SQL_WINDOW_OFFSETS.md](SQL_WINDOW_OFFSETS.md). The
unchanged inventory now gives **10 smoke passes /91 failures /17 unexecuted**
locally and retains SqlConformanceIncomplete. PG.QUERY.WINDOW advances; named
windows and the wider family remain incomplete. Non-total/nonrepeatable nested
or uncertain demand combinations reject explicitly; no complete SQL claim.
Hosted qualification is pending.

### Distribution/ranking candidate —31 October2026

percent_rank/cume_dist/ntile add native-backed coverage within the existing
window family. The118-program smoke counts remain10/91/17: do not count each
new function as a closed feature family or a compatibility percentage. See
[SQL_WINDOW_RANKING.md](SQL_WINDOW_RANKING.md) for scope, native quirks, remaining
demand restrictions and independent tests. Hosted/wire qualification pending.

### Named-window candidate, 31 October 2026

WINDOW definitions and scoped inheritance advance PG.QUERY.WINDOW_FRAMES. The
unchanged118-program inventory now gives **11 smoke passes /90 failures /
17 unexecuted**, with mandatory SqlConformanceIncomplete. See
[SQL_NAMED_WINDOWS.md](SQL_NAMED_WINDOWS.md) for native-backed scope, volatile
evaluation fixes, explicit unsupported combinations and capacity/control checks.
Five Linux ReleaseSafe suites pass: named1832, frames108118, offsets2023,
ranking3053 and windows9035. Independent review reproduced all five,27 native
fixtures and extra scalar-key/sequence-interleaving probes. Cross-platform,
wire and PG18 qualification remain separate pending gates. Complete SQL,
window-family and performance-superiority claims remain unsupported.

### Frame value-window candidate - 31 October 2026

first_value/last_value/nth_value now have scoped implementation and78 native
reference programs,600 independent interval-membership property queries,
work/cancel/error/reuse and lazy side-effect checks. Linux ReleaseSafe passes:
value6179, named1832, frames108118, offsets2023, ranking3053, windows9035;
PostgreSQL protocol17325. The unchanged118 inventory remains11/90/17 and
intentionally exits1 SqlConformanceIncomplete. The separate evidence manifest
pins current source/output hashes; historical manifests describe older slices.

Native parity remains incomplete:12 extra EXCLUDE TIES boundary programs retain
four PostgreSQL16 value differences against independently observed array_agg
frame membership. A separate native executor XX000/mark-state discrepancy is
also documented. These differences are not passing compatibility evidence;
PG18 version characterization, hosted/wire qualification and broader SQL closure
remain pending. See the value-window scope document and boundary fixture.

### Conditional DDL candidate - 1 November 2026

PG.DDL.IF_EXISTS now passes the unchanged smoke program: **12 passes /89 failures /
17 unexecuted**, with mandatory SqlConformanceIncomplete. CREATE/DROP TABLE and
SEQUENCE conditional clauses preserve existing state and skip empty durability
work while retaining carried sequence persistence. Adversarial tests corrected
IF identifiers, skipped semantic validation, repeated sequence options and stale
DROP SEQUENCE retry snapshots. Core207 assertions and seven existing suites pass
in Linux ReleaseSafe and were independently rerun.49 frozen native programs match.
See SQL_CONDITIONAL_DDL.md and conditional_ddl_evidence.json for scope/provenance.
NoticeResponse, full READ ONLY semantics, wider DDL variants, hosted/wire/PG18
qualification and the full SQL inventory remain open. No throughput claim follows.


### Conditional DDL durability correction - 1 November 2026

The first candidate's hosted durable run exposed unreplayable quoted schema
names. The corrected decoder preserves bounded non-NUL identifier bytes; quoted
identifier NULs are rejected before publication. Core220 assertions and the
seven existing regression suites pass in Linux ReleaseSafe. The broad118 driver
still gives12/89/17 and exits1. Updated evidence includes lexer/change-log hashes.
The preserved failing WAL and recovery gate are documented in SQL_CONDITIONAL_DDL.md.
Fresh hosted and full durable-wire recovery remain pending; no compatibility or
production-completeness claim follows from the earlier49 live case successes.
