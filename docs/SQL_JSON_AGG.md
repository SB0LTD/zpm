# SQL JSON and aggregates (conformance lane B11, wave 3: json-agg)

Branch `b11/json-agg` closes six smoke programs of the 118-program
inventory test-first: PG.AGG.COLLECTION, PG.JSON.AGG, PG.AGG.ORDERED_SET,
PG.JSONB.MODIFY, PG.JSON.PATH and PG.JSON.TABLE. On its base (main
6f32405, 83 passes) the unchanged driver gives 89; it still exits 1
(SqlConformanceIncomplete) and no other program changed. A smoke pass is
not family closure.

`contract-sql-json-agg` (tests/test_sql_json_agg.sig, 6,240 assertions in
ReleaseSafe) covers every program with values in PostgreSQL text output,
column names and type OIDs, NULLs and empty inputs, exact errors with an
untouched result afterwards (failure atomicity), every work budget below
the statement's need (QueryWorkLimit, 54000) and every cancellation point
(57014), capacity limits, and replay of committed records (aggregate and
JSON results in int[], text, json, jsonb, jsonpath, jsonpath[] and float8
columns, JSON_TABLE rows, and rejected corrupt jsonpath bytes) into a
replica that must answer like the primary. Only the six oracle fixtures
from `postgres18_oracle.json` are native-verified; every other expectation
follows the PostgreSQL 18 documentation and source and is pending native
verification.

## Scope

| Program | Implemented | Not covered |
|---|---|---|
| AGG.COLLECTION | ORDER BY inside any aggregate call (keys, DESC, NULLS FIRST/LAST, DISTINCT with ORDER BY over its arguments); array_agg over scalars (1-D) and arrays (one more dimension); string_agg over text and bytea | window forms of these aggregates and aggregate ORDER BY over a window (0A000); collecting aggregates inside GROUPING SETS / ROLLUP / CUBE (0A000) |
| JSON.AGG | json_agg, jsonb_agg, json_object_agg, jsonb_object_agg with to_json / to_jsonb value conversion (numbers, NaN/infinity as strings, XSD dates and timestamps, json verbatim, jsonb, arrays, other types as strings); to_json and to_jsonb as functions | *_strict / *_unique variants, JSON_OBJECTAGG / JSON_ARRAYAGG syntax, composite values, json_build_* constructors |
| AGG.ORDERED_SET | WITHIN GROUP: percentile_cont (float8, interval), percentile_disc, mode, and the hypothetical-set rank, dense_rank, percent_rank, cume_dist | percentile_cont / percentile_disc over an array of fractions |
| JSONB.MODIFY | jsonb_set, jsonb_set_lax, jsonb_insert, jsonb_delete_path and #-, jsonb - text / integer / text[], ?| and ?&, jsonb_strip_nulls (strip_in_arrays), jsonb_pretty | jsonb subscripting assignment (`j['a'] = ...`), jsonb_concat beyond the existing ||, json (non-b) variants |
| JSON.PATH | the jsonpath type (OID 4072, canonical jsonpath_out text, casts from strings, wire send/receive version 1, columns and arrays); lax and strict modes; `$`, `@`, `$var`, `last`; `.key`, `.*`, `[*]`, `[i, j to k]`, `.**{m to n}`, filters; type(), size(), double(), ceiling(), floor(), abs(), number(), string(), boolean(), integer(), bigint(), decimal(p, s); + - * / % and unary +/-; == != < <= > >=, && \|\| !, exists(), is unknown, starts with; jsonb_path_exists / match / query_array / query_first (vars, silent) and @? / @@ | like_regex, keyvalue() and the datetime methods (0A000 at evaluation; they parse and print); jsonb_path_query (set-returning) and the *_tz variants |
| JSON.TABLE | JSON_TABLE in FROM, implicitly LATERAL: context item as jsonb, row path with PASSING, FOR ORDINALITY, JSON_VALUE-style and JSON_QUERY-style columns (FORMAT JSON, json/jsonb types, WITH [CONDITIONAL] WRAPPER, KEEP / OMIT QUOTES), EXISTS columns, ON EMPTY / ON ERROR (NULL, ERROR, DEFAULT, EMPTY ARRAY / OBJECT, TRUE / FALSE / UNKNOWN), table-level EMPTY / ERROR ON ERROR | NESTED PATH (0A000); composite column types; JSON_EXISTS / JSON_VALUE / JSON_QUERY as standalone expressions |

## Design

Collecting aggregates (`ast.collectingAggregate`) and any aggregate with
ORDER BY keys have no fixed-size transition state. The binder wraps their
arguments, sort keys (and the direct arguments of an ordered-set
aggregate) in one internal `aggregate_input` node, so every planner walk
sees all inputs. They run only on the sorted grouping operator
(Exec.collectAggregate): per group the inputs are materialized in the
statement workspace, the ignored rows dropped (NULL rules of each
aggregate), the rest merge-sorted (stable) by the keys, DISTINCT runs
collapsed, and one fold in `aggregates_collect.sig` builds the result.
Ordinary aggregates with ORDER BY run their usual transition over the
sorted inputs. Streamed, factorized and summary grouping paths never see
these plans. Direct arguments of an ordered-set aggregate are evaluated at
the group's first input row and may only read grouped expressions (42803).

`json_build.sig` converts values as datum_to_json / datum_to_jsonb do;
jsonb results are built as JSON text and parsed into the canonical binary
(sorted keys, last duplicate wins). JSONB modifications (`jsonb.sig`)
rewrite the binary with setPath's rules (jsonfuncs.c) and canonicalize.

`jsonpath.sig` holds the jsonpath scanner, a recursive-descent parser into a
bounded node pool, the canonical printer (jsonpath.c printJsonPathItem,
including its parenthesization), and the evaluator. Evaluation streams
items depth-first into sinks; predicate operands and subscripts use a
bounded item stack and computed values a scratch buffer, released in stack
order (a collector copies computed values it keeps). Every step polls the
execution control; recursion follows the parsed path and the document's
validated nesting. Errors that jsonpath_exec.c raises through RETURN_ERROR
(`jsonpath.suppressible`) become unknown inside predicates and NULL for
silent calls; a missing variable never does.

JSON_TABLE is a FROM plan (`Series.json_table`). json_eval.jsonTable
evaluates the context item, builds the PASSING object, runs the row path
once to count (a row path error then gives no rows, or propagates with
ERROR ON ERROR) and again to produce rows, evaluating each column path over
the row item. Column errors from SQL/JSON or the type's input function are
handled by the column's ON ERROR (NULL by default, FALSE for EXISTS, ERROR
when the table says ERROR ON ERROR); an ERROR ON EMPTY is itself handled by
ON ERROR unless that is ERROR, as ExecEvalJsonExprPath does.

## Errors (SQLSTATE)

New error names (all mapped in src/db/postgres.sig): NullValueNotAllowed
22004, SqlJsonArrayNotFound 22039, SqlJsonMemberNotFound 2203A,
SqlJsonObjectNotFound 2203C, InvalidSqlJsonSubscript 22033,
SingletonSqlJsonItemRequired 22038, NonNumericSqlJsonItem 22036,
SqlJsonNumberNotFound 2203B, SqlJsonScalarRequired 2203F,
SqlJsonItemCannotBeCast 2203G, MoreThanOneSqlJsonItem 22034, NoSqlJsonItem
22035. Also used: 42601 (jsonpath input, JSON_TABLE grammar), 42803
(nested aggregates, ungrouped direct arguments), 42804 (untyped
polymorphic arguments, JSON_TABLE context item), 42809 (WITHIN GROUP
required or not allowed, ORDER BY on a non-aggregate), 42725, 42883,
42P10 (DISTINCT with ORDER BY outside the arguments), 42701 (JSON_TABLE
column names), 42704 (missing jsonpath variable), 22023, 22003, 22012,
22P02, 2202E, 0A000, 54000 (TextCapacity, WorkspaceCapacity,
ProgramLimitExceeded), 54001, 57014, XX001 (InvalidChangeRecord).

## Limits and storage

Everything stays in the statement workspace, the node pool or bounded
stack buffers; nothing allocates. A collecting aggregate holds one
workspace row per input of its group (WorkspaceCapacity, 54000); every
aggregate, JSON and jsonpath result fits one cell (Config.text_bytes,
TextCapacity 54000); intermediate JSON text is bounded by
Io.format_bytes. New capacity constants: Config.jsonpath_nodes (128,
StatementTooComplex 54001 beyond) and Config.jsonpath_items (128,
ProgramLimitExceeded 54000 beyond); aggregate ORDER BY / WITHIN GROUP keys
are at most 24 per call (ColumnCapacity); a jsonb_set path reaches at most
Config.json_depth + 1 levels.

Durability: no new change-record op (45-49 unused) and no new value tag
(32-35 unused). A jsonpath value is a text cell holding its canonical text
and is written with the existing value tag 3; replay checks that a
jsonpath column's text is its own canonical form (InvalidChangeRecord
otherwise), so existing records stay byte-identical. The type catalog
gains jsonpath (4072) and _jsonpath (4073): pg_type grows from 78 to 80
rows (tests/test_sql_catalog.sig updated).

## Pending native verification

Everything outside the six oracle fixtures, in particular: json_agg's
`\n ` separator before array values, XSD timestamp text, jsonb_pretty of
empty containers, setPath edge cases (negative and out-of-range indexes,
jsonb_insert on objects), jsonpath canonical text for every construct,
.double() over strings (float8_numeric rounding), the item-method error
codes (22036 throughout), the treatment of json/jsonb JSON_TABLE columns
as JSON_QUERY columns, ERROR ON EMPTY being handled by ON ERROR, and the
EXISTS column conversions to integer and text.
