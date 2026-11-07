# SQL query composition (conformance lane B11)

Branch `b11/query-composition` closes thirteen smoke programs of the
118-program inventory test-first: PG.JOIN.NATURAL, PG.JOIN.TREE,
PG.QUERY.VALUES_TABLE, PG.QUERY.LIMIT_EXPR, PG.QUERY.FETCH_TIES,
PG.GROUP.SETS, PG.GROUP.CUBE, PG.QUERY.CTE_MATERIALIZATION,
PG.JOIN.LATERAL, PG.QUERY.TABLE_FUNCTION, PG.QUERY.RECURSIVE_SEARCH,
PG.QUERY.MODIFYING_CTE and PG.QUERY.SAMPLE. The unchanged driver moved from
39 smoke passes to 52 on the lane's base (12abe24) and, rebased onto the
types and schema-object lanes (4efd284, 58 passes), gives 71; it still exits
1 (SqlConformanceIncomplete) and no other program changed. A smoke pass is
not family closure.

`contract-sql-query-composition` (tests/test_sql_query_composition.sig)
covers each program with values and PostgreSQL text output, column names and
type OIDs, order and multiplicity, NULLs and empty inputs, exact errors with
an untouched result afterwards (failure atomicity), every work budget below
the statement's need (QueryWorkLimit, 54000) and every cancellation point
(57014). Only the oracle fixtures from `postgres18_oracle.json` are
native-verified; every other expectation follows the PostgreSQL 18
documentation and source and is pending native verification.

## Scope

| Program | Implemented | Not covered |
|---|---|---|
| NATURAL | NATURAL [INNER/LEFT/RIGHT/FULL] JOIN as USING over shared names in left order; merged INNER/LEFT/RIGHT columns take the common type; SELECT * lists each join's merged columns before its operands | chained USING after a FULL join uses the left base column, not the COALESCE |
| Join trees | parenthesized joined tables anywhere; right operand groups joined as a whole (Exec.joinGeneral); group-scoped ON | aliases on a join tree (0A000) |
| VALUES / TABLE | VALUES blocks in every query position, common column types, columnN names, ORDER BY names/positions; TABLE [ONLY] name | ORDER BY expressions over VALUES (0A000) |
| LIMIT / OFFSET | any count expression; constants fold, others run once per execution (OFFSET first) | runtime counts on window plans, correlated sublinks inside a count (0A000) |
| WITH TIES | FETCH FIRST n ROWS WITH TIES over all ORDER BY keys, after OFFSET | FOR UPDATE with a general query (existing 0A000) |
| GROUPING SETS / CUBE | nested elements, composite items, cross products, GROUP BY DISTINCT; one-pass hash executor with GROUPING() | COUNT(DISTINCT) beyond integral base-table columns (0A000, as ROLLUP) |
| [NOT] MATERIALIZED | accepted; always one materialization (PostgreSQL never inlines volatile bodies) | inlining-dependent predicate pushdown and lazy CTE scans |
| LATERAL | LATERAL subqueries, reruns per left tuple, LEFT JOIN LATERAL | RIGHT/FULL with a LATERAL reference (42P10, as PostgreSQL) |
| Table functions | generate_series over int4/int8/numeric/timestamp[tz]; scalar functions in FROM; WITH ORDINALITY; column alias lists on every FROM item | unnest/other set-returning functions, ROWS FROM, set-returning functions in the target list |
| SEARCH / CYCLE | depth/breadth-first keys for ORDER BY seq, cycle marks with custom TO/DEFAULT, terminating cycles | selecting the record-typed seq/path columns (0A000); search columns outside integer/boolean/text/date/timestamp (0A000) |
| Data-modifying WITH | INSERT/UPDATE/DELETE ... RETURNING entries, run once each in statement order under the statement snapshot, before the main SELECT; row locks, waits and resume; atomic with the statement | DML as the main statement after WITH; entries that read sibling CTEs; RETURNING of UPDATE ... FROM source columns |
| TABLESAMPLE | BERNOULLI and SYSTEM with PostgreSQL's hash and cutoff, REPEATABLE seeds, 0/100 exact | PostgreSQL's physical page layout (partial samples differ from a native server) |

## Errors (SQLSTATE)

42601 (NATURAL with ON/USING, WITH TIES without ORDER BY, unequal VALUES
rows, SEARCH/CYCLE naming), 42701 (USING or search/cycle column repeated),
42702 (ambiguous NATURAL/USING column), 42703, 42P01 (scope of a join group or
LATERAL), 42P10 (LIMIT variables, LATERAL with RIGHT/FULL, too many column
aliases), 42803, 42P20, 42804 (LIMIT and TABLESAMPLE types, CYCLE TO/DEFAULT),
42725 (generate_series over untyped arguments), 42883, 42809 (TABLESAMPLE
on a non-table), 42704 (unknown TABLESAMPLE method), 2201W, 2201X, 22023
(generate_series step/NaN), 22P02, 22012, 21000, 23505, 2202H and 2202G (new:
InvalidTablesampleArgument, InvalidTablesampleRepeat), 0A000, 54000
(workspace, text key, CUBE beyond 12 elements), 54001 (node pool, more than
4096 grouping sets), 57014, 25006.

## Limits and storage

Everything stays in the caller-owned statement workspace and node pool;
nothing allocates. Grouping-set masks are pool nodes (at most 64 distinct
keys, at most 4096 sets). The depth-first SEARCH key lives in one text cell
(Config.text_bytes; 9 bytes per integer level). Data-modifying entries are
at most Config.ctes per statement; their RETURNING rows are pinned at the top
of the query workspace until the statement ends. TABLESAMPLE models
64-row heap blocks. Plans for the new composition forms keep every output
(no demand pruning). Join trees, LATERAL items, table functions and sampled
tables never take the probe, streamed or factorized join paths; grouping
sets use their own executor and leave the ROLLUP and plain GROUP BY paths
unchanged.
