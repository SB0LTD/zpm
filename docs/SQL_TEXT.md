# SQL text features (conformance lane B11, wave 3)

Branch `b11/text` closes four smoke programs of the 118-program inventory
test-first: PG.FUNC.DISCOVERY, PG.TEXT.COLLATION, PG.PRED.REGEX and
PG.TEXT.SEARCH. On main 4c028a6 (89 passes) the unchanged driver reports
93; it still exits 1 (SqlConformanceIncomplete) and no other program
changed. A smoke pass is not family closure.

`contract-sql-text` (tests/test_sql_text.sig, 3341 assertions) covers each
program with values in PostgreSQL text output, type OIDs, typmods and
column names, NULLs, exact errors with an untouched result afterwards
(statement atomicity), work budgets and cancellation points for regular
expressions and text search, the wire text of the new types and replay of
change records into a replica compared with sameDatabase/sameCatalog.
Only the four oracle fixtures of `postgres18_oracle.json` are
native-verified. Every other expectation is pending native verification:
each was compared by hand with a local PostgreSQL 18.3 (Ubuntu build,
database created with `LOCALE 'C'`, UTF8), which is not a recorded oracle
run. That includes the 343-expression regular-expression battery and the
363-expression text-search battery (243 written cases and 120 generated
parser inputs) embedded in the contract.

## Scope

| Program | Implemented | Not covered |
|---|---|---|
| Discovery | `pg_typeof("any")` returning regtype (2206; not strict, argument evaluated; unknown 705, regclass/regtype for the OID casts); regtype values with oid's operators (binary coercible, so `pg_typeof(x) = 'integer'` is 22P02 as in PostgreSQL), pg_cast casts, regtypein/regtypeout; `pg_get_serial_sequence(table, column)` for SERIAL and identity columns (regclass text, exact column name, `public.<quote_identifier>`) | `::regtype` / `to_regtype` still return the older OID marker (oid 26); quote_identifier does not quote keywords; a sequence's own columns and index attributes are approximated |
| Collation | `expr COLLATE any_name` (precedence between unary minus and AT TIME ZONE; b_expr contexts stop before it); "default", "C", "POSIX", "ucs_basic" (all identical to this C database); explicit derivation per parse_collate.c with 42P21 for different explicit collations (CASE results, IN, COALESCE, LIKE, GREATEST, NULLIF, ANY arrays, operators); 42804 before 42704; `pg_catalog.` qualification; deparse `(x COLLATE "C")`; column `COLLATE "default"` | column collations other than "default" (0A000: the table definition cannot carry them); pg_c_utf8, unicode, pg_unicode_fast (0A000); implicit collations of derived-table columns (never 42P22); pg_collation catalog and `COLLATION FOR`; a user schema qualifier is 3F000 even when the schema exists |
| Regular expressions | ARE syntax of regcomp.c compiled to a bounded Pike VM (regex.sig): escapes, brackets, classes, collating elements, equivalence classes, groups, alternation, bounds, non-greedy forms, all constraints, lookahead/lookbehind, comments, directors, embedded options and ERE via `(?e)`; `~ ~* !~ !~*` on text/varchar/name and padded bpchar; `[NOT] SIMILAR TO ... [ESCAPE]` through PostgreSQL 18's similar_escape; `similar_to_escape()`; `regexp_like()` with parse_re_flags options | back references, BREs (`(?b)`, and regexp_like options `b` and `e`, which parse_re_flags turns into BREs) and lookarounds nested deeper than three (0A000); match positions, so substring/regexp_replace/regexp_match/regexp_matches/regexp_split_* and the other regexp_* functions; non-ASCII case folding and classes (C ctype only) |
| Full text search | tsvector (3614) and tsquery (3615) types with array types, their text I/O (tsvector_parser.c, tsquery.c) kept as canonical text; the default parser as a mechanical translation of wparser_def.c's state tables (every token type, verified on 400 generated inputs); the `simple` configuration (regconfig names as identifiers, `pg_catalog.` qualified); `to_tsvector`, `to_tsquery`, `plainto_tsquery`, `phraseto_tsquery` (pushval_morph, stop-word cleanup); `@@` both ways with TS_execute / TS_phrase_execute (phrase distances, NOT and OR inside phrases, prefix and weight matches) | Snowball configurations and dictionaries (0A000); the one-argument forms and `text @@ tsquery`, which use default_text_search_config = pg_catalog.english (0A000); two untyped operands of @@ resolve to the json-agg lane's jsonb @@ jsonpath here, where PostgreSQL picks text @@ text; tsvector/tsquery comparison, ordering and hashing operators (42883 here); binary send/receive (0A000); websearch_to_tsquery, ts_rank, ts_headline, setweight, strip, length, the tsvector/tsquery operators other than @@, json/jsonb to_tsvector; regconfig as a type (the configuration must be an untyped literal or parameter) |

## Errors (SQLSTATE)

New: 42P21 CollationMismatch, 2201B InvalidRegularExpression, 2200C
InvalidEscapeCharacterUse. Also used: 42804 (COLLATE on a non-collatable
type, column collation type), 42704 (collation, text search configuration,
regtype input), 3F000 (collation schema), 0A000 (see Scope), 22P02,
22003, 22012, 22023 (regexp options, tsquery phrase distance above
16384), 22025 (SIMILAR TO escape), 42601 (tsvector/tsquery syntax), 42883,
42P01, 42703, 54000 (ProgramLimitExceeded for a regular-expression program
beyond Config.regex_states, the position arena of a phrase match, text
capacity), 54001 (nesting beyond Config.expr_depth), 57014.

## Limits and storage

Nothing allocates. A regular expression compiles into at most
Config.regex_states (new, default 512) instructions; bracket sets and
their non-ASCII ranges are sized from it. Matching keeps two thread lists
and a closure stack per simulation on the caller's stack and spends one
ExecutionControl checkpoint per text position, also inside lookarounds.
Text-search values live in the cell's Text (Config.text_bytes); parsing
and matching use caller-stack tables sized from text_bytes and nest at
most Config.expr_depth deep.

Change records: value tags 28 (tsvector) and 29 (tsquery) carry len u32 +
the canonical output text and are re-read on replay (anything that does not
re-read to itself is InvalidChangeRecord); tag 30 carries a regtype OID
(u32). Tag 31 and change-log ops 40-44 stay unused. No table-definition
format change. The built-in pg_type view grows from 80 to 86 rows
(regtype, tsvector, tsquery and their array types).
