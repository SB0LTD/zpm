# SQL conformance inventory and closing plan

Status: incomplete; refreshed 30 October 2026 after PR consolidation on main
`2c0ac40afa11177158b1eac5f8e7cb9bce1c72c7` (engine source `0f5af8d`).
The original TDD baseline was `53655a9a89a3ddff6f2f5829388b09a10c3d9c93`.
PostgreSQL 18.3 is the frozen positive language oracle for this inventory;
PostgreSQL wire compatibility is a separate contract. MySQL and T-SQL targets
require their own versioned native oracles. See the
[current TDD checkpoint](../../docs/SQL_CONFORMANCE_TDD_STATUS.md) and
[refresh evidence](consolidation_evidence.json).

## What this inventory proves

`cases.json` defines 118 executable smoke programs with stable IDs. A smoke pass does not close a feature. `postgres18_features.json` preserves all 755 upstream feature records (459 YES, 296 NO), including bindings outside ordinary SQL. Applicability and mapping remain unreviewed; no assertion of exhaustive SQL coverage is made. The source is [PostgreSQL REL_18_3 sql_features.txt](https://github.com/postgres/postgres/blob/REL_18_3/src/backend/catalog/sql_features.txt), blob `ebe85337c2877ba927b1dee97bc54a9a80470f04`.

Every closure needs result values and exact types; NULL/empty/duplicate/order cases; negative SQLSTATE and atomicity cases; parameters and prepared execution; rollback/replay; cancellation and exhausted grants; concurrency where relevant; supported-platform runs. Preserve non-applicable dimensions with a reviewed reason. An accepted syntax tree alone is insufficient.

## Work sequence and gates

1. Pin the target and validate each positive fixture on native PostgreSQL. Invalid fixtures are test defects, never compatibility passes. Record server version, source SHA, machine, command and result.
2. Close one semantic slice at a time: first null-safe equality, then quantified/row predicates and scalar functions. Write failing contracts before modifying code. Keep the broad audit red while gaps remain.
3. Establish typed expression and relational IR invariants; expand types, NULL/collation rules, and scalar/aggregate contracts. Keep planner transformations behind explicit semantic proofs.
4. Complete relational composition: lateral/table functions, CTE forms, windows, advanced grouping and set operations. Compare generic and optimized execution on generated small tables against PostgreSQL, preserving bags and ordering.
5. Complete mutation/schema/dependencies: constraints, indexes, ALTER, views, MERGE, sequence lifecycle and generated columns. Test failures before/after WAL reservation and publication; replay must reproduce state.
6. Transactions, locks, cursors, role policies, catalogs, routines, COPY and administrative/integration SQL need dedicated multi-session/protocol/recovery suites. SQL syntax does not prove their system behavior.
7. Qualify other dialects independently using native MySQL and SQL Server. Never infer semantic compatibility from listener availability.
8. Only after correctness gates, measure physical design candidates on unchanged dbMeter plus larger independent distributions. Track regressions and retain generic fallbacks. Performance is not a substitute for conformance.

No calendar promise or universal speedup is implied. A release claiming complete compatibility is blocked until the declared scope has closure evidence and all unresolved applicable upstream records have been adjudicated.

## Concrete smoke specifications

Current core run: **8 smoke passes, 93 failures, 17 unexecuted scopes/comparators**.
The broad executable still deliberately exits with SqlConformanceIncomplete.
The former 6/95/17 result is retained at `core_smoke_results.stage4.ndjson`.
These probes are not a percentage of PostgreSQL compatibility. Core-only
rejection of a server utility does not prove absence in the server layer.
Some probes combine several features: their first failure does not mean every
component is missing. The annotations below separate those cases.

| ID | Feature | Core smoke status |
|---|---|---|
| PG.PRED.DISTINCT | NULL-safe equality | pass; closure incomplete |
| PG.PRED.QUANTIFIED | ANY/SOME/ALL, scalar subqueries with six ordinary comparison operators | pass; array/row/custom-operator forms and closure remain incomplete |
| PG.PRED.SYMMETRIC | Symmetric BETWEEN | pass; scalar/flat-row range contracts, broader closure incomplete |
| PG.PRED.OVERLAPS | Temporal overlaps | Syntax |
| PG.PRED.REGEX | Regular expressions | Syntax |
| PG.PRED.ESCAPE | LIKE escape clause | pass; UTF-8 LIKE/ASCII ILIKE contracts, collations and planner closure incomplete |
| PG.QUERY.WINDOW | Ranking/offset windows | candidate smoke pass; LAG/LEAD finite coverage, demand/other window closure incomplete |
| PG.QUERY.WINDOW_AGG | Window aggregates | pass; complete window family remains partial |
| PG.QUERY.WINDOW_FRAMES | Named windows and frame exclusions | Syntax at named-window form; bounded/excluded frames implemented separately |
| PG.GROUP.ROLLUP | ROLLUP/GROUPING | pass; flat ROLLUP/GROUPING only, broader grouping remains partial |
| PG.GROUP.CUBE | CUBE | UndefinedFunction |
| PG.GROUP.SETS | GROUPING SETS | Syntax |
| PG.AGG.COLLECTION | String/array aggregates | Syntax |
| PG.AGG.STATISTICAL | Statistical aggregates | UndefinedFunction |
| PG.AGG.ORDERED_SET | Ordered-set aggregates | Syntax |
| PG.AGG.BITWISE | Bitwise aggregates | UndefinedFunction |
| PG.AGG.INTERVAL | AVG(interval) | UndefinedFunction |
| PG.JOIN.LATERAL | LATERAL | Syntax |
| PG.JOIN.NATURAL | NATURAL JOIN | Syntax |
| PG.JOIN.TREE | Parenthesized join tree | UnsupportedStatement |
| PG.QUERY.TABLE_FUNCTION | Set-returning/table functions | Syntax |
| PG.QUERY.MODIFYING_CTE | Data-modifying CTE | Syntax |
| PG.QUERY.CTE_MATERIALIZATION | CTE materialization syntax | Syntax |
| PG.QUERY.RECURSIVE_SEARCH | Recursive SEARCH/CYCLE | Syntax |
| PG.QUERY.ROW | Flat constructor comparison predicates | pass; record values and remaining row forms unqualified |
| PG.QUERY.VALUES_TABLE | Standalone VALUES/TABLE | UnsupportedStatement |
| PG.QUERY.SAMPLE | TABLESAMPLE | Syntax |
| PG.QUERY.FETCH_TIES | FETCH WITH TIES | Syntax |
| PG.QUERY.LIMIT_EXPR | Expression LIMIT/OFFSET | Syntax |
| PG.DDL.SCHEMA | Schema lifecycle | Syntax |
| PG.DDL.ALTER | ALTER TABLE | UnsupportedStatement |
| PG.DDL.CREATE_VARIANTS | Temporary/CTAS/LIKE | Syntax |
| PG.DDL.INHERITANCE | Table inheritance | Syntax |
| PG.DDL.PARTITION | Partition lifecycle | Syntax |
| PG.DDL.IF_EXISTS | Conditional DDL | Syntax |
| PG.DDL.TRUNCATE | TRUNCATE | UnsupportedStatement |
| PG.DDL.DATABASE | Database lifecycle | UnexecutedScopeOrComparator |
| PG.CONSTRAINT.COMPOSITE | Composite/table-level primary key | Syntax |
| PG.CONSTRAINT.UNIQUE | UNIQUE/NULL rules | Syntax |
| PG.CONSTRAINT.CHECK | CHECK | Syntax |
| PG.CONSTRAINT.FK | Foreign-key actions | Syntax |
| PG.CONSTRAINT.DEFERRED | Deferred constraints | Syntax |
| PG.CONSTRAINT.EXCLUSION | Exclusion constraints | Syntax |
| PG.INDEX.SECONDARY | Secondary/index catalog | Syntax |
| PG.INDEX.ADVANCED | Composite/expression/partial/covering index | Syntax |
| PG.DML.UPDATE_FROM | UPDATE FROM | Syntax |
| PG.DML.DELETE_USING | DELETE USING | Syntax |
| PG.DML.TUPLE_ASSIGN | Tuple assignment | Syntax |
| PG.DML.MERGE | MERGE | UnsupportedStatement |
| PG.DML.UPSERT_UNIQUE | Non-PK upsert | Syntax |
| PG.SEQUENCE.EXTENDED | Sequence lifecycle/cache/SERIAL | Syntax |
| PG.DDL.VIRTUAL | Virtual generated columns | Syntax |
| PG.VIEW.ORDINARY | Views | Syntax |
| PG.VIEW.MATERIALIZED | Materialized views | Syntax |
| PG.TYPE.CHARACTER | VARCHAR/CHAR | Syntax |
| PG.TYPE.BINARY | BYTEA | Syntax |
| PG.TYPE.UUID | UUID | Syntax |
| PG.TYPE.TIME | TIME/TIMETZ | Syntax |
| PG.TYPE.MONEY | MONEY | Syntax |
| PG.TYPE.BIT | BIT/VARBIT | Syntax |
| PG.TYPE.NETWORK | Network/MAC | Syntax |
| PG.TYPE.GEOMETRIC | Geometric types | UndefinedFunction |
| PG.TYPE.XML | XML | Syntax |
| PG.TYPE.ARRAY | Arrays | Syntax |
| PG.TYPE.RANGE | Range/multirange | Syntax |
| PG.TYPE.ENUM_DOMAIN_COMPOSITE | User-defined types | Syntax |
| PG.TYPE.CATALOG_IDS | Additional catalog identifiers | Syntax |
| PG.JSON.OPS | JSON operators | candidate smoke pass; lexical extraction, broader JSON closure incomplete |
| PG.JSONB.MODIFY | Remaining JSONB operations | UndefinedFunction |
| PG.JSON.PATH | JSONPATH/SQL-JSON | UndefinedFunction |
| PG.JSON.TABLE | JSON_TABLE | Syntax |
| PG.JSON.AGG | JSON aggregates | Syntax |
| PG.FUNC.STRING | String functions | Syntax |
| PG.FUNC.NUMERIC | Numeric functions | UndefinedFunction |
| PG.FUNC.TEMPORAL | Temporal functions | Syntax |
| PG.FUNC.FORMAT | Formatting functions | UndefinedFunction for to_date/to_number; temporal to_char implemented separately |
| PG.FUNC.MINMAX | GREATEST/LEAST | pass; closure incomplete |
| PG.FUNC.DISCOVERY | Discovery functions | UndefinedFunction |
| PG.TEXT.COLLATION | Collation selection | Syntax |
| PG.TEXT.ENCODING | Unicode/codepoint functions | UndefinedFunction |
| PG.TEXT.LITERALS | Escape/dollar/Unicode literals | Syntax |
| PG.TEXT.SEARCH | Full text search | Syntax |
| PG.OP.BITWISE | Bitwise operators | Syntax |
| PG.TX.ISOLATION | Repeatable Read/Serializable | UnsupportedStatement |
| PG.TX.CHARACTERISTICS | Transaction characteristics | Syntax |
| PG.TX.LOCK_MODES | Additional row lock modes | Syntax |
| PG.TX.TABLE_LOCK | Explicit table/advisory locking | UnsupportedStatement |
| PG.TX.TWO_PHASE | Two-phase commit | UnexecutedScopeOrComparator |
| PG.CURSOR | Cursor lifecycle | UnsupportedStatement |
| PG.SQL_PREPARE | SQL prepared statements | UnsupportedStatement |
| PG.SESSION.SETTINGS | General settings/search_path | UnsupportedStatement |
| PG.SESSION.NOTIFY | Notifications | UnsupportedStatement |
| PG.SECURITY.ROLE | Roles/privileges | Syntax |
| PG.SECURITY.RLS | Row-level security | UnsupportedStatement |
| PG.ROUTINE.FUNCTION | SQL functions | Syntax |
| PG.ROUTINE.PROCEDURE | Procedures/DO | Syntax |
| PG.ROUTINE.TRIGGER | Triggers | Syntax |
| PG.ROUTINE.RULE | Rewrite rules | Syntax |
| PG.CATALOG | Catalog expansion | RowShapeMismatch |
| PG.UTILITY.EXPLAIN | Explain/analyze plans | UnexecutedScopeOrComparator |
| PG.UTILITY.MAINTENANCE | Maintenance commands | UnexecutedScopeOrComparator |
| PG.UTILITY.COMMENT | Object comments | UnsupportedStatement |
| PG.INTEGRATION.EXTENSION | Extension catalog visibility only; lifecycle remains untested | TableNotFound |
| PG.INTEGRATION.FOREIGN | Foreign server objects | Syntax |
| PG.INTEGRATION.REPLICATION | Publication catalog visibility only; replication remains untested | TableNotFound |
| PG.COPY.OPTIONS | COPY WHERE/options | UnexecutedScopeOrComparator |
| MYSQL.IDENTIFIERS | Backtick identifiers | UnexecutedScopeOrComparator |
| MYSQL.TYPES | Native unsigned types | UnexecutedScopeOrComparator |
| MYSQL.AUTO_INCREMENT | AUTO_INCREMENT | UnexecutedScopeOrComparator |
| MYSQL.REPLACE_UPSERT | REPLACE/upsert | UnexecutedScopeOrComparator |
| MYSQL.LIMIT | MySQL LIMIT forms | UnexecutedScopeOrComparator |
| MYSQL.FUNCTIONS | Native scalar functions | UnexecutedScopeOrComparator |
| TSQL.IDENTIFIERS | Bracket identifiers | UnexecutedScopeOrComparator |
| TSQL.TOP | TOP | UnexecutedScopeOrComparator |
| TSQL.OUTPUT | OUTPUT | UnexecutedScopeOrComparator |
| TSQL.APPLY | APPLY | UnexecutedScopeOrComparator |
| TSQL.FUNCTIONS | Native scalar functions | UnexecutedScopeOrComparator |
| TSQL.PROCEDURAL | Variables/errors/transactions | UnexecutedScopeOrComparator |

## Remaining work after consolidation

| Area | Available slice | Still missing or unqualified |
| --- | --- | --- |
| Windows | RANK/DENSE_RANK/ROW_NUMBER, aggregate FILTER, bounded ROWS/GROUPS, integral-key RANGE, exclusions | Named windows; LAG/LEAD/FIRST_VALUE/LAST_VALUE/NTH_VALUE/NTILE/PERCENT_RANK/CUME_DIST; numeric/float/temporal RANGE offsets; volatile moving inputs; correlated window-target subqueries |
| Grouping | Ordinary aggregates, flat ROLLUP/GROUPING and GROUP BY () | CUBE/general GROUPING SETS, composite/multiple ROLLUP, remaining aggregate families and DISTINCT domains |
| Formatting/functions | Temporal to_char; GREATEST/LEAST; existing numeric/JSON/sequence/catalog subset | to_date/to_number, numeric/interval/localized/ISO/timezone formatting, ordinary string/math/date/regex/discovery function families and overloads |
| Schema/types | Existing typed tables, identity/default/stored-generation slices | VARCHAR/CHAR, UUID/BYTEA, TIME/TIMETZ, arrays/general records/user types; SERIAL; conditional DDL; ALTER/TRUNCATE/views/schemas; secondary indexes; table/composite/UNIQUE/CHECK/FK/deferred constraints |
| Relational queries | Existing joins, scalar subqueries, recursive CTE subset, set operations | LATERAL/NATURAL/parenthesized joins, table functions, modifying/materialized CTE forms, SEARCH/CYCLE, standalone VALUES/TABLE, TABLESAMPLE, expression LIMIT/OFFSET and FETCH WITH TIES |
| Predicates/DML | Flat row comparison/list membership/BETWEEN, scalar-subquery quantified comparisons, RETURNING and PK upsert | General/nested record values, row subquery/ANY/ALL and array forms, OVERLAPS/regex, UPDATE FROM, DELETE USING, tuple assignment, MERGE and non-PK arbiters |
| System/dialect scope | Independently tested READ COMMITTED, savepoint, lock, prepared-wire and COPY subsets | Remaining isolation/transaction characteristics/locks, cursors, SQL PREPARE, settings/notifications, roles/RLS, routines/triggers/rules, expanded catalogs, COPY options, replication/extensions/foreign objects and native MySQL/T-SQL semantics |

DISTINCT window aggregates are unsupported by PostgreSQL too; they are not an
extra PostgreSQL-parity requirement. See [frame scope](../../docs/SQL_WINDOW_FRAMES.md)
for exact fast paths, scalar fallback and finite caller-workspace budgets.

Known wrong-result/error cases also need TDD closure. The earlier LIKE JOIN/WHERE
error-order mismatch and general planner constant/error timing remain open.
PG16 and PG18 themselves disagree on the retained discarded-row projection-error
probe. The newer RAMSQL hardening audit adds temporal overflow/interval parsing,
JSONB concatenation, infinite-date subtraction and name-binding divergences;
the consolidation does not fix those SQLF findings. See the
[application feature/divergence audit](https://github.com/SB0LTD/ramsql/blob/main/docs/compatibility/FEATURE_GAPS.md)
and [system gap plan](https://github.com/SB0LTD/ramsql/blob/main/compatibility/GAP_CLOSING_PLAN.md).

The 17 unexecuted cases require scope/comparator work, not a claim of 17 proven
engine absences. Prepared wire operations and selected session/transaction
commands already have separate server tests. The 755 upstream standard records
still need reviewed applicability and mappings, including overloads beyond these
118 probes. No full language or dialect closure follows from this inventory.

Original dbMeter full/subset correctness is separately 7/7 for all three engines
in run 41024725859. Its overall advantage gate failed, including stock 200-byte
text, nine-column and 20-additional-table probes. Those finite profile limits,
elastic schema/value storage, compact 100M-row base/MVCC storage and intra-query
parallelism remain system/infrastructure work; this driver's small test buffers
do not define production capacities. No local throughput was measured here.

## Running

The in-process first slice is `contract-sql-distinct` in `test-sql`. The differential audit is a separate development tool, deliberately outside the passing regression aggregate:

```powershell
python tests/sql_conformance/audit.py --oracle-port 55491 --candidate-port 55492 --report .sig-cache/sql-audit.json
```

Use owned disposable loopback test instances with trust authentication, matching database/user and extension/catalog setup. Each transaction fixture gets its own connection; disconnect rolls back. The harness compares typed metadata, command tags, transaction state, bags including multiplicity, NULLs and SQL errors. Cases with meaningful order must explicitly set `ordered: true`. OID-valued discovery cases need stable-object normalization before qualification; arbitrary database-local OIDs must never be equated directly. Session/cluster/COPY/native-dialect scopes are currently unexecuted and block qualification. Positive-oracle errors are reported as `oracle_invalid`. The audit always exits nonzero while only smoke coverage exists, including when every selected smoke passes. It does not silently skip gaps.

`postgres18_oracle.json` records the native PostgreSQL 18.3 fixture run, including
exact server version and manifest SHA-256 (UTF-8 with LF newlines): 102 valid programs and 16 unexecuted
scopes. Regenerate this evidence when changing SQL or target version. The generator
rejects stale evidence. To run the corresponding allocator-free core contracts:

```powershell
python tests/sql_conformance/generate_contracts.py --oracle-report tests/sql_conformance/postgres18_oracle.json --output .sig-cache/sql-conformance-generated.sig
sig build-exe -O ReleaseSafe --dep sql -Mroot=.sig-cache/sql-conformance-generated.sig -Msql=src/core/sql.sig -femit-bin=.sig-cache/sql-conformance.exe
.sig-cache/sql-conformance.exe
python -m unittest discover -s tests/sql_conformance -p test_audit.py
```

Use the repository-supported SDK/toolchain options if the installed compiler needs
an explicit library path. The generated core driver uses one transaction per
fixture and fixed caller-owned test storage (8 tables, 16 columns, 32 rows/table,
64 result/work rows, 512-byte cells, 2048 expression nodes). These are test budgets,
not production capacity claims. It checks column names, type OIDs, typmods, exact
formatted scalar values, NULLs and row multiplicity/order after each statement.
It does not test wire message tags, native SQL transaction commands, concurrency
or crash durability. Such cases cannot be closed from this driver. EXPLAIN requires
a structural comparator and remains unexecuted rather than comparing timing text.

The broad generated suite deliberately returns an error while any feature or
closure dimension is incomplete. Passing first-slice regressions and a red broad
audit are separate, visible facts; never rewrite the audit to return success for
unsupported SQL.

The quantified-comparison regression is `contract-sql-quantified`. To reproduce
its independent PostgreSQL oracle validation on an owned loopback test instance:

```powershell
python tests/sql_conformance/verify_quantified_oracle.py --port 55491 --report .sig-cache/quantified-oracle.json
```

The checked-in `quantified_oracle.json` pins the Sig contract and generator source
hashes. Harness tests reject stale source or matrix identity. The finite matrix
has 1,152 cases; 42 additional SQL examples cover types, precision boundaries,
nesting, correlation, operators and errors. Legacy replay, resource controls and
multi-session schedules are covered separately in Sig, not by this single-session
native run. Quantified support currently covers SELECT-context scalar subqueries and ordinary
`= <> != < <= > >=`; arrays, rows, LIKE/ILIKE/custom operators remain unqualified.
DML contexts remain unqualified. All 26 default SQL contracts pass; the complete
second-batch source/evidence record is `quantified_evidence.json`. The original
`evidence.json` is historical and refers to the archived first-batch smoke run.

The row-comparison checkpoint record is `row_evidence.json`: 27 passing default SQL contracts and
449,096 assertions. Its constructor-predicate suite has 8,430 assertions in both
ReleaseSafe and Debug. `row_oracle.json` records 4,160 independent matrix cases
and 49 additional PostgreSQL 18.3 probes. Reproduce the native part with:

```powershell
python tests/sql_conformance/verify_row_oracle.py --port 55491 --report .sig-cache/row-oracle.json
```

`contract-sql-row-predicates` covers flat constructor-to-constructor comparisons
and constructor NULL tests, including DML, grouping and scalar-subquery fields.
Record payloads, nested records, whole-row expansion, field selection and remaining
row membership/quantified forms are unqualified. Standalone/nested record examples
are explicitly rejected in the Sig suite and are excluded from native passing
scope; they are not counted as compatibility successes.

The NULLIF follow-up adds `contract-sql-nullif-types`: 24 native PostgreSQL
18.3 cases and 93 executable assertions covering cross-type result metadata,
payload representation, volatile evaluation, aggregates and error preservation.
Reproduce its oracle with:

```powershell
python tests/sql_conformance/verify_nullif_oracle.py --port 55491 --report .sig-cache/nullif-oracle.json
```

`nullif_oracle.json` pins the contract and oracle script hashes. The database
workflow runs all ten Python harness/evidence tests on each native OS. Earlier
contract totals above describe their historical checkpoints.

SQLancer-style TLP, NoREC and constant-folding metamorphic tests are additional oracles, not substitutes for native differential and crash tests. See [SQLancer papers](https://github.com/sqlancer/sqlancer/blob/main/docs/PAPERS.md) and [CODDTest](https://doi.org/10.1145/3709674). Bounded equivalence can strengthen optimizer checks but remains bounded: [VeriEQL](https://arxiv.org/abs/2403.03193).

Flat row-constructor IN/NOT IN lists are covered by
`contract-sql-row-membership`: 5,928 assertions, a 2,916-case three-valued
matrix, and 40 additional native PostgreSQL 18.3 probes. Reproduce the oracle:

```powershell
python tests/sql_conformance/verify_membership_oracle.py --port 55491 --report .sig-cache/membership-oracle.json
```

`membership_oracle.json` pins its contract/script hashes and matrix digest.
The eleven Python tests include identity checks for this evidence. The Sig
contract separately covers schema replay, work/cancellation and caller-storage
exhaustion. A 64-candidate list is tested with depth five and 1,024 AST nodes;
binding storage grows with candidate count and width. This is constructor-list
support, not general records or row IN subqueries/ANY/ALL. Bare NULL record
candidates and nested records remain explicitly unsupported. Historical
unqualified-scope lists in earlier oracle records describe those earlier batches.

Bare NULL record candidates are covered by `contract-sql-row-null-candidates`:
98 assertions and 43 PostgreSQL 18.3 probes. This closes the bare-NULL exclusion
above; refreshed constructor-list evidence includes 41 additional probes.
Grouping/name validation, constant errors, CASE/COALESCE, volatile suppression,
eliminated aggregates, replay and execution controls are covered. Reproduce with:

```powershell
python tests/sql_conformance/verify_row_null_oracle.py --port 55491 --report .sig-cache/row-null-oracle.json
```

`row_null_oracle.json` pins both source hashes. Twelve Python tests validate the
current harness and evidence. General record/nested values and row subquery
membership remain unqualified; constant validation is scoped to discarded row
operands and does not qualify the entire optimizer.

`contract-sql-between` covers scalar and flat row BETWEEN / NOT BETWEEN,
including ASYMMETRIC and SYMMETRIC: 17,939 assertions, 8,910 finite reference
cases and 62 additional PostgreSQL 18.3 probes. Reproduce its native oracle:

```powershell
python tests/sql_conformance/verify_between_oracle.py --port 55491 --report .sig-cache/between-oracle.json
```

`between_oracle.json` pins both sources and the matrix digest. Thirteen Python
tests validate current evidence. The Sig contract also checks replay, resource
controls and caller AST exhaustion. Ordinary lowering uses two comparisons and
symmetric lowering uses four; simple typed scalar ranges retain their compact
shape. Nested/general record payloads remain unqualified. This is correctness
evidence, not a benchmark result or full SQL compatibility claim.

`contract-sql-like-escape` covers explicit ESCAPE for LIKE/ILIKE and negated
forms: 16,348 assertions, 8,120 matrix cases and 44 additional PostgreSQL 18.3
probes. Reproduce its independent code-point DP/native oracle:

```powershell
python tests/sql_conformance/verify_like_oracle.py --port 55491 --report .sig-cache/like-oracle.json
```

`like_oracle.json` pins the contract/script and matrix digest. Fourteen Python
tests validate current evidence. Sig checks replay, an at-capacity pattern,
exact work exhaustion and cancellation inside matching. The matcher uses
constant scratch without a normalized-pattern buffer; worst-case rescanning is
still possible. Unicode case folding, collations, planner error timing and
filter placement remain unqualified. The concrete JOIN/filter error mismatch is
recorded in [the status document](../../docs/SQL_CONFORMANCE_TDD_STATUS.md).

`contract-sql-expression-sources` covers ownership and validation phases of
stored expressions: 75 assertions and 30 PostgreSQL 18.3 probes. Reproduce with:

```powershell
python tests/sql_conformance/verify_sources_oracle.py --port 55491 --report .sig-cache/sources-oracle.json
```

`sources_oracle.json` pins both sources; fifteen Python tests check current
evidence. Sig separately checks COPY component calls, work/cancellation and replay
after overwriting the caller's record buffer. The source owner uses existing AST
metadata with no retained pointers or node-size growth. Complete generated-column
restrictions and general planner error timing remain unqualified.

`contract-sql-generated-restrictions` covers stored generated-column immutability,
dependencies and supported branch reduction: 132 assertions and 52 PostgreSQL
18.3 probes. Reproduce its native oracle with:

```powershell
python tests/sql_conformance/verify_generated_oracle.py --port 55491 --report .sig-cache/generated-oracle.json
```

`generated_oracle.json` pins both sources. Sixteen Python tests validate current
evidence. Sig separately checks replay, sequence non-effects and interruption
during candidate CREATE validation; the wire error map checks 42P17. Virtual
generation, inheritance/partitioning, system-column rules, additional planner
reductions and complete coercion coverage remain unqualified. These results
cover explicit STORED generation within the documented expression subset.

## Latest inventory candidates —31 October2026

The unchanged118 programs now yield10 smoke passes,91 failures and17 unexecuted
scopes/comparators locally. The driver still exits1 SqlConformanceIncomplete.
The earlier8/93/17 consolidated evidence is retained as historical qualification;
JSON and offset-window candidates have separate hashed evidence manifests.
See [offset scope](../../docs/SQL_WINDOW_OFFSETS.md) and
[JSON scope](../../docs/SQL_JSON_OPERATORS.md). Candidate smoke success does not
close a feature family, and hosted qualification remains separate evidence.
