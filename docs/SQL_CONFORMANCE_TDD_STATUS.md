# SQL conformance TDD checkpoint

## JSON and aggregates candidate (lane B11, wave 3) - 5 November 2026

Branch `b11/json-agg` (on 6f32405) closes six smoke programs test-first:
PG.AGG.COLLECTION, PG.JSON.AGG, PG.AGG.ORDERED_SET, PG.JSONB.MODIFY,
PG.JSON.PATH and PG.JSON.TABLE. The unchanged driver moves from 83 passes
to 89; it still exits 1 SqlConformanceIncomplete and no other program
changed. `contract-sql-json-agg` (tests/test_sql_json_agg.sig) covers
values, column names and OIDs, NULLs and empty inputs, exact SQLSTATEs
(22004, 22033-2203G, 42601, 42803, 42804, 42809, 42883, 42P10, 42701,
42704, 22023, 22003, 22012, 22P02, 2202E, 0A000, 54000, 54001), statement
atomicity, work budgets and cancellation, and replay into a replica. Only
the six oracle programs are native-verified; every other expectation is
pending native verification. Details, limits and open items:
docs/SQL_JSON_AGG.md.

Durability: no new change-record op (45-49 unused) and no new value tag
(32-35 unused). The new jsonpath type (OID 4072) stores its canonical text
with the existing text value tag; replay rejects a jsonpath that is not its
own canonical text (InvalidChangeRecord). pg_type grows from 78 to 80 rows.

## Routines candidate (lane B11, wave 3) - 5 November 2026

Branch `b11/routines` (rebased on f505a80) closes four smoke programs
test-first: PG.ROUTINE.FUNCTION, PG.ROUTINE.PROCEDURE, PG.ROUTINE.TRIGGER
and PG.ROUTINE.RULE. The unchanged driver moves from 79 passes to 83; it
still exits 1 SqlConformanceIncomplete and no other program changed.
`contract-sql-routines` (tests/test_sql_routines.sig, 663 assertions)
covers values, column names and OIDs, command tags, exact SQLSTATEs (42883,
42725, 42723, 42P13, 42809, 42P17, 42710, 42704, 42601, 42703, 42702,
2BP01, 0A000, P0001, P0002, P0003, 2F005, 20000, 22004, 22005, 22012,
22P02, 23502, 23505, 54000, 54001, 57014), statement atomicity, two-
transaction schedules (pending CREATE / DROP FUNCTION visibility and waits,
CREATE TRIGGER against a writer, a DO block restarted after a lock wait),
work budgets and cancellation inside routine loops, capacities, crafted
change records and replay of every committed record into a replica that
must answer, and fire its triggers and rules, like the primary. Only the
four oracle programs are native-verified; every other expectation is
pending native verification. Details, limits and open items:
docs/SQL_ROUTINES.md.

Durability: routines, triggers and rules are their own MVCC catalog objects
with change-record ops 60-65 (60/61 create/drop routine, 62/63 trigger,
64/65 rule; 66-69 reserved), each a length-prefixed payload validated
before anything applies. Existing records and the definition format are
unchanged.

## Transaction and session candidate (lane B11, wave 3) - 5 November 2026

Branch `b11/tx-session` (on 20e7528) closes eight smoke programs
test-first: PG.TX.ISOLATION, PG.TX.CHARACTERISTICS, PG.TX.LOCK_MODES,
PG.TX.TABLE_LOCK, PG.CURSOR, PG.SQL_PREPARE, PG.SESSION.SETTINGS and
PG.SESSION.NOTIFY. The unchanged driver moves from 71 passes to 79; it
still exits 1 SqlConformanceIncomplete and no other program changed.
`contract-sql-tx-session` (tests/test_sql_tx_session.sig) covers values,
column names, OIDs and typmods, exact SQLSTATEs (40001, 25001, 25006,
25P01, 55P03, 55000, 34000, 42P03, 26000, 42P05, 42601, 42804, 42P18,
42704, 22023, 42P01, 3F000, 0A000, 54000), statement atomicity,
two-connection schedules (REPEATABLE READ conflicts, SSI write skew and
pivots, DEFERRABLE waits, LOCK TABLE and row-lock matrices, advisory locks,
LISTEN/NOTIFY across store connections and the wire) and replay of
REPEATABLE READ / SERIALIZABLE commits into a replica. Only the eight
oracle programs are native-verified; every other expectation is pending
native verification. Details, limits and open items: docs/SQL_TX_SESSION.md.

Durability: no new change-record op (50-59 unused) and no definition format
change; the lane adds transaction, lock and session state only.
SERIALIZABLE is SSI at relation granularity: sound, with more serialization
failures than PostgreSQL's tuple-level SSI; it is not claimed to match
PostgreSQL's failure set.

## Schema-object candidate (lane B11, wave 2) - 5 November 2026

Branch `b11/schema-objects` (rebased on d91020c) closes the thirteen
schema-object smoke programs test-first: PG.INDEX.SECONDARY,
PG.INDEX.ADVANCED, PG.DML.UPSERT_UNIQUE, PG.CONSTRAINT.FK,
PG.CONSTRAINT.DEFERRED, PG.CONSTRAINT.EXCLUSION, PG.VIEW.ORDINARY,
PG.VIEW.MATERIALIZED, PG.DDL.CREATE_VARIANTS, PG.DML.MERGE,
PG.DDL.VIRTUAL, PG.DDL.INHERITANCE and PG.DDL.PARTITION. The unchanged
driver moves from 45 passes (d91020c) to 58; it still exits 1
SqlConformanceIncomplete and no other program changed.
`contract-sql-schema-objects` (tests/test_sql_schema_objects.sig) covers
values, exact SQLSTATEs (23503, 23505, 23514, 23P01, 23502, 2BP01, 42P07,
42P01, 42703, 42704, 42701, 42804, 42809, 42830, 42P10, 42P16, 42P17,
55000, 21000, 428C9, 0A000, 54000), statement atomicity, concurrent
schedules (unique-index and upsert races, FOREIGN KEY insert against parent
delete, exclusion waits, deferred commits, MERGE EvalPlanQual and source
locks, DROP against view creators) and replay of every committed record
into a replica that must answer like the primary. Only the thirteen oracle
programs are native-verified; every other expectation is pending native
verification.

Durability: no new change-record op was needed. Every new object rides on
the existing table definition ops (1 create_table, 12 alter_table, 2
drop_table, 11 truncate, 3/4/5 rows) with definition format version 3,
written only when a definition needs it (version-1/2 records stay byte
identical and still replay): column flag bit 5 VIRTUAL; constraint kinds 4
FOREIGN KEY and 5 EXCLUDE with DEFERRABLE / INITIALLY DEFERRED flags;
relkind ('r', 'v', 'm', 'p'), secondary indexes with their OIDs, view query
text and dependencies, the inheritance / partition parent and the partition
strategy and bound. CREATE / DROP INDEX and REFRESH ... [NO] DATA rewrite
the table through op 12; views and materialized views are op 1 / op 2;
REFRESH logs op 11 plus inserts.

Limits: Config.table_indexes (4) secondary indexes per table and
Config.index_entries entries per index (0: the version arena; no storage
with external_storage), IndexCapacity 54000; Config.expansion_bytes (4096)
for a statement plus its expanded views / inheritance / partition texts,
TextCapacity 54000; Config.constraint_modes (8) SET CONSTRAINTS names;
8 MERGE WHEN clauses. CREATE / DROP INDEX and REFRESH WITH [NO] DATA copy
the table slot like ALTER TABLE (AccessExclusive, a free slot until
commit). Indexes are hash multimaps over plain key columns (equality only);
expression elements and predicates are definitions. UNIQUE / FOREIGN KEY /
EXCLUDE checks scan the version arena. Views are read-only; UPDATE/DELETE
through an inheritance parent with children and keys on partitioned tables
are 0A000; TEMP tables are ordinary durable tables. Non-deferrable foreign
keys are checked per row (PostgreSQL checks NO ACTION at statement end);
deferred checks never wait for another live writer (that writer's own
check sees the commit). No SQL family, production or native parity claim
follows from these smokes.

## Advanced types candidate (lane B11) - 5 November 2026

Branch `b11/types-advanced` (on 8458d77) closes six smoke programs
test-first: PG.TYPE.CATALOG_IDS, PG.TYPE.ARRAY, PG.TYPE.RANGE,
PG.TYPE.NETWORK, PG.TYPE.GEOMETRIC and PG.TYPE.XML. The unchanged driver
moves from 39 passes to 45; it still exits 1 SqlConformanceIncomplete and
no other program changed. `contract-sql-types-advanced`
(tests/test_sql_types_advanced.sig) covers values, OIDs/typmods, NULLs,
ordering and hash consistency, casts, exact SQLSTATEs, atomicity, wire
send/receive and replay compared with sameDatabase/sameCatalog. Only the
six oracle fixtures are native-verified; every other expectation is pending
native verification.

Array types are the unnamed values of DataType/Type (element ordinal with
bit 7 set), so every scalar type has its array type. Arrays, ranges and XML
live inline in the cell's text_bytes budget (54000 beyond it). New
change-record value tags: 19 pg_lsn, 20 xid8, 21 array, 22 range, 23
inet/cidr, 24 macaddr, 25 point, 26 box, 27 xml. Older records never use
them, so they replay unchanged. New SQLSTATEs: 42P18, 2202E, 22000, 2200N,
2200M and 2200L. The built-in pg_type view grows from 25 to 78 rows;
test_sql_catalog's workspace was raised to 128 rows to hold it.

PG.TYPE.ENUM_DOMAIN_COMPOSITE is not implemented. Its oracle expects the
database-local OIDs 18673/18682, which are artifacts of the native run's OID
counter. In addition, `sql.typeOid(DataType)` has no per-database type
identity. Multiranges, unnest, array element assignment, other geometric
types, macaddr8 and XPath functions also remain open.

## DDL, constraint and DML candidate (lane B11) - 4 November 2026

Branch `b11/ddl-constraints-dml` (started on 4ed58c9, rebased on 16788d4
with the types lane) closes ten smoke programs
test-first: PG.DDL.TRUNCATE, PG.CONSTRAINT.CHECK, PG.CONSTRAINT.UNIQUE,
PG.CONSTRAINT.COMPOSITE, PG.DDL.ALTER, PG.SEQUENCE.EXTENDED,
PG.DML.UPDATE_FROM, PG.DML.DELETE_USING, PG.DML.TUPLE_ASSIGN and
PG.DDL.SCHEMA. The unchanged driver moves from 12 passes/106 incomplete to
22/96 on 4ed58c9, and from 18/100 to 28/90 on 16788d4; it still exits 1
SqlConformanceIncomplete and no other program changed.
`contract-sql-ddl-core` (tests/test_sql_ddl_core.sig) covers values, exact
SQLSTATEs (23502, 23505, 23514, 42P16, 42710, 42P06, 3F000, 2BP01, 22023,
42702), atomicity, concurrent schedules (UNIQUE and key waits, table locks,
ALTER/ALTER SEQUENCE visibility) and replay of every committed record into a
replica that must answer like the primary. Only the ten oracle programs are
native-verified; every other expectation is pending native verification.

Every new effect is a change-record op: 11 truncate, 12 alter_table, 13
create_sequence_cached, 14 alter_sequence, 15 create_schema, 16
drop_schema (10 stays unassigned as the existing unknown-op probe), and
create_table definition format 2 (namespace and constraints), written only
when needed so version-1 records stay byte-identical. ALTER TABLE and ALTER
SEQUENCE copy into a free slot with the same OID and swap through the
versioned catalog; TRUNCATE marks rows in place with one write entry.
Limits: Config.table_constraints (8) and Config.schemas (4); UNIQUE scans
the version arena (no secondary index); ALTER needs a free table slot per
statement until commit. Evidence: `tests/sql_conformance/ddl_constraints_dml_evidence.json`.
No SQL family, production or native parity claim follows from these smokes.


## Qualified planner checkpoint - 2 November 2026

Plain derived-output demand and immutable error timing qualified and merged in
ZPM PR97 (main fe4479c) and RAMSQL PR51 (main c68e8f9). Database matrix41405262720
passed all five host/native-oracle jobs; Windows retained every check with an
independently reviewed45-minute job budget after two30-minute timeouts in the
final CLI checks. Core444 and parallel46 assertions/2400queries/eight threads
were independently reproduced. RAMSQL CI41367643673 passed all8 jobs and release
41367643674 passed25 active jobs plus one intentional duplicate skip.

The exact eight-target bundle is published as non-latest CI prerelease
ci-v0.3.0-beta.2-run.41367643674.1; all29 digests were verified. RAMSQL main,
qualified candidate and published source share tree e3a2624. Its immutable ZPM
pin ef6e3c0 is a merged ancestor; only the Windows CI budget file differs from
qualified ZPM main. Every runtime and test file is identical.

The broader ZPM graph still has four unchanged SABR/TLS/TTS failures, with324
successes and22skips. This is separate from the passing database/platform gates.
The original118-program inventory remains12smoke passes/89failures/17unexecuted,
with expected SqlConformanceIncomplete. No SQL family, production drop-in scope,
capacity limit or performance-superiority claim is closed by this slice.

## Aggregate-state demand investigation - 2 November 2026

A separate50-program native16.15 corpus reproduced25matches and25gaps on the
test-first baseline. The runtime candidate now passes all50 in ReleaseSafe.
These probes do not change the original118-program audit. Runtime aggregate-state
liveness is implemented in the candidate, but not yet qualified or merged.
Full CI caught a missing dependency for aggregates in unused named WINDOW
definitions. A native16 supplement adds three programs (53total), with a red
50pass/3gap checkpoint and a fixed aggregate-prefix dependency under qualification.
Duplicate groups, NULL/empty aggregates, row-dependent
errors, FILTER/DISTINCT, volatility and semantic errors now have frozen probes.
Native16.15/18.3 expectations each replay50/50 in oracle-calibration CI41407604728.
Physical-path tests now cover bounded streaming, typed/factorized fallbacks,
cancellation/work exhaustion, poisoned reuse and reader/private-write visibility.
Independent runtime review found no introduced blocking defect. Parameters and
full platform/product qualification remain open. See [the implementation scope](SQL_AGGREGATE_DEMAND.md)
and [historical test-first plan](SQL_AGGREGATE_DEMAND_PLAN.md). Existing right-hand
boolean absorbers still evaluate aggregates that PostgreSQL eliminates; that
separate parity gap is explicitly open. A separate
high-exponent numeric-literal capacity finding is retained rather than hidden by
the explicit float8 inputs used to isolate aggregate overflow.

## Historical planner candidate checkpoint - 2 November 2026

The concrete unused-derived TRUNC and empty-input SQRT examples have candidate
fixes in [SQL_PLANNER_DEMAND.md](SQL_PLANNER_DEMAND.md). Native PostgreSQL16.15
verifies94 execution cases plus4 Parse/Describe probes. The core contract adds
metadata/type checks,80 one-shot cancellation positions and existing depth bounds.
Required output bits and owned constant values are caller-backed, with no AST
substitution or hidden allocator. General grouping/window-state, scalar-subquery
output pruning, correlation and complete planner parity remain open. This is not
a SQL-family closure or a full-inventory compatibility percentage. Fresh hosted
qualification and final independent review are required before this candidate merges.

NET-02's shared-tokenizer slice qualified and merged in ZPM PR96 (main1440f9a)
and RAMSQL PR50 (main1c13ab7). Native16.15/18.3 each passed78 template cases;
all three ZPM database hosts, RAMSQL CI41339791061 and release41339791138 passed.
The exact eight-target bundle published automatically as a non-latest CI prerelease.

## Latest qualified checkpoint - 1 November 2026

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

SQRT qualified and merged in ZPM PR95 (main69f7555) and RAMSQL PR48
(main2756280). ZPM database matrix41310830772 passed all three host platforms;
RAMSQL CI41311411830 and release41311411851 passed. The initial PG18 durable
RC2 timing observation failed; the unchanged failed-job retry passed, with
original evidence retained and no relaxed waits. The automatic-publication
follow-up RAMSQL PR49 qualified on CI41315141760 and release41315141691,
then merged as0815419. Its exact bundle is published as a non-latest prerelease.
[SQL_SQUARE_ROOT.md](SQL_SQUARE_ROOT.md) records the scoped implementation. The mathematical family remains open,
including POWER/LN and the explicit planner/precision gaps.
The canonical core_smoke_results.ndjson now contains the recorded12/89/17
result. Its older8/93/17 consolidation rows are preserved separately;
[checkpoint_20261101.json](../tests/sql_conformance/checkpoint_20261101.json)
binds both files to the prior execution evidence. No new run is claimed by this
document reconciliation. These results do not close the SQL inventory.

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
   general records; SERIAL, ALTER/TRUNCATE, views/schemas,
   secondary indexes and table/composite/UNIQUE/CHECK/FK/deferred constraints
   still block ordinary application schemas. Virtual generation, inheritance
   and partitioning remain beyond the qualified stored-generation slice.
3. **Ordinary functions/operators.** String/math/date/regex/discovery families,
   to_date/to_number, numeric/interval/localized/ISO/timezone formatting,
   remaining JSON/JSONB/SQL-JSON operations and additional aggregates/overloads.
4. **Query composition.** Remaining window forms beyond the qualified named,
   offset, ranking and frame-value slices; nonintegral or
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
NET-02 and STO-05 remain open; STO-02/04 have qualified snapshot/sequence fixes.
The historical lists below must be read with these dated updates.

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
