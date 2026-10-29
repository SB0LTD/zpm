# SQL conformance inventory and closing plan

Status: incomplete. Baseline `53655a9a89a3ddff6f2f5829388b09a10c3d9c93`; isolated branch `feat/sql-conformance-tdd`. PostgreSQL 18.3 is the first explicit language target; PostgreSQL wire compatibility is a separate contract. MySQL and T-SQL targets require their own versioned native oracles.

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

Current core run: **4 smoke passes, 97 failures, 17 unexecuted scopes/comparators**. These are probes selected to expose gaps, not a percentage of PostgreSQL compatibility. Core-only rejection of a server utility does not prove absence in the server integration layer.

| ID | Feature | Core smoke status |
|---|---|---|
| PG.PRED.DISTINCT | NULL-safe equality | pass; closure incomplete |
| PG.PRED.QUANTIFIED | ANY/SOME/ALL, scalar subqueries with six ordinary comparison operators | pass; array/row/custom-operator forms and closure remain incomplete |
| PG.PRED.SYMMETRIC | Symmetric BETWEEN | Syntax |
| PG.PRED.OVERLAPS | Temporal overlaps | Syntax |
| PG.PRED.REGEX | Regular expressions | Syntax |
| PG.PRED.ESCAPE | LIKE escape clause | Syntax |
| PG.QUERY.WINDOW | Ranking/offset windows | Syntax |
| PG.QUERY.WINDOW_AGG | Window aggregates | Syntax |
| PG.QUERY.WINDOW_FRAMES | Named windows and frame exclusions | Syntax |
| PG.GROUP.ROLLUP | ROLLUP/GROUPING | UndefinedFunction |
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
| PG.JSON.OPS | JSON operators | UndefinedFunction |
| PG.JSONB.MODIFY | Remaining JSONB operations | UndefinedFunction |
| PG.JSON.PATH | JSONPATH/SQL-JSON | UndefinedFunction |
| PG.JSON.TABLE | JSON_TABLE | Syntax |
| PG.JSON.AGG | JSON aggregates | Syntax |
| PG.FUNC.STRING | String functions | Syntax |
| PG.FUNC.NUMERIC | Numeric functions | UndefinedFunction |
| PG.FUNC.TEMPORAL | Temporal functions | Syntax |
| PG.FUNC.FORMAT | Formatting functions | UndefinedFunction |
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

The current record is `row_evidence.json`: 27 passing default SQL contracts and
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
