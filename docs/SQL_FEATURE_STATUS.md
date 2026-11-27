# SQL-standard feature status

This scoreboard covers the 755 records of PostgreSQL's SQL-standard feature list
(`tests/sql_conformance/postgres18_features.json`, from `sql_features.txt`). It is
measured, not estimated: each in-scope feature has probe programs in
`tests/sql_conformance/features/`, recorded from native PostgreSQL 18.7 and executed
in-process against ZPM through its PostgreSQL wire session by `contract-sql-features`.
A feature is **closed** only when all of its probes match, **partial** when some do
and **open** when none do. Parent records aggregate their subfeatures.
The machine-readable form is `tests/sql_conformance/postgres18_feature_status.json`.

## Totals

- In scope: **453** of 755 records (302 out of scope: 296 that PostgreSQL does not support, 6 reviewed deviations).
- Closed: **263**
- Partial: **8**
- Open: **182**
- Probes: 253 of 434 match native PostgreSQL 18.7.

## Per family

| Family | Records | In scope | Closed | Partial | Open | Not applicable |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| B | 44 | 2 | 1 | 0 | 1 | 42 |
| E | 107 | 106 | 88 | 5 | 13 | 1 |
| F | 199 | 162 | 97 | 3 | 62 | 37 |
| M | 25 | 0 | 0 | 0 | 0 | 25 |
| R | 3 | 0 | 0 | 0 | 0 | 3 |
| S | 50 | 14 | 5 | 0 | 9 | 36 |
| T | 190 | 121 | 66 | 0 | 55 | 69 |
| X | 137 | 48 | 6 | 0 | 42 | 89 |

## Reviewed deviations

PostgreSQL lists these as supported, but they are out of scope here:

- `B012` Embedded C: Embedded C is the ECPG client precompiler; it reaches the engine through the wire protocol.
- `E182` Host language binding: Host language binding is provided by client libraries and precompilers, not the engine.
- `F181` Multiple module support: Multiple module support concerns SQL module/ECPG compilation units, not the engine.
- `F611` Indicator data types: Indicator data types belong to embedded SQL host variables (ECPG).
- `F771` Connection management: CONNECT / SET CONNECTION / DISCONNECT are embedded SQL client statements (ECPG).
- `T627` Window framed COUNT DISTINCT: Native PostgreSQL 18.7 rejects DISTINCT in window aggregates with 0A000 although sql_features.txt lists T627; probe T627.window_count_distinct records the rejection.

## Ranked work list

Open and partial in-scope features, grouped by engine area. Areas are ordered by how
much applications use them; inside an area, partial features (closest to closing) come
first, then core families (E, F) before T, S and X. Each line names the first
mismatching probe statement, with the native PostgreSQL 18.7 response first.

### Query composition: joins, subqueries, set operations, ORDER BY/FETCH/OFFSET (9)

- `F404` Range variable for common column names (open). 0/1 probes match; first gap: F404.join_using_alias #4 `SELECT j.id, x, y FROM a JOIN b USING (id) AS j` head: PostgreSQL 'T:id/23/4/-1,x/25/-1/-1,y/25/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `F471` Scalar subquery values (open). 0/1 probes match; first gap: F471.scalar_subquery #4 `UPDATE t SET a = (SELECT max(a) FROM t) + a` head: PostgreSQL 'C:UPDATE 2;Z:I', ZPM 'E:0A000;Z:I'
- `F641` Row and table constructors (open). 0/1 probes match; first gap: F641.row_constructors #4 `SELECT a, b FROM t WHERE (a, b) = (SELECT 1, 1)` head: PostgreSQL 'T:a/23/4/-1,b/23/4/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `F651` Catalog name qualifiers (open). 0/1 probes match; first gap: F651.catalog_qualifier #1 `INSERT INTO w4_features_probe.public.t VALUES (1)` head: PostgreSQL 'C:INSERT 0 1;Z:I', ZPM 'E:42601;Z:I'
- `F855` Nested ORDER BY in query expression (open). 0/1 probes match; first gap: F855.nested_order_by #0 `(SELECT 2 AS x ORDER BY 1) UNION ALL (SELECT 1 ORDER BY 1)` head: PostgreSQL 'T:x/23/4/-1;C:SELECT 2;Z:I', ZPM 'E:0A000;Z:I'
- `F856` Nested FETCH FIRST in query expression (open). 0/1 probes match; first gap: F856.nested_fetch_first #2 `(SELECT a FROM t ORDER BY a FETCH FIRST 2 ROWS ONLY) UNION ALL (SELECT a FROM t ORDER B...` head: PostgreSQL 'T:a/23/4/-1;C:SELECT 3;Z:I', ZPM 'E:0A000;Z:I'
- `F863` Nested OFFSET in query expression (open). 0/1 probes match; first gap: F863.nested_offset #2 `(SELECT a FROM t ORDER BY a OFFSET 3) UNION ALL (SELECT a FROM t ORDER BY a DESC OFFSET 3)` head: PostgreSQL 'T:a/23/4/-1;C:SELECT 2;Z:I', ZPM 'E:0A000;Z:I'
- `T133` Enhanced cycle mark values (open). 0/1 probes match; first gap: T133.cycle_marks #3 `WITH RECURSIVE w(a, b) AS (SELECT a, b FROM g WHERE a = 1 UNION ALL SELECT g.a, g.b FRO...` head: PostgreSQL 'T:a/23/4/-1,looped/16/1/-1,path/2287/-1/-1;C:SELECT 4;Z:I', ZPM 'E:0A000;Z:I'
- `S111` ONLY in query expressions (open). 0/1 probes match; first gap: S111.only #6 `SELECT a FROM ONLY (parent)` head: PostgreSQL 'T:a/23/4/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'

### DML and integrity constraints, MERGE, referential actions (12)

- `E141` Basic integrity constraints (partial). 7/8 probes match; first gap: E141-03.primary_key #8 `CREATE TABLE v(a INT PRIMARY KEY, b INT PRIMARY KEY)` head: PostgreSQL 'E:42P16;Z:I', ZPM 'E:42601;Z:I'
- `E141-03` Basic integrity constraints: PRIMARY KEY constraints (open). 0/1 probes match; first gap: E141-03.primary_key #8 `CREATE TABLE v(a INT PRIMARY KEY, b INT PRIMARY KEY)` head: PostgreSQL 'E:42P16;Z:I', ZPM 'E:42601;Z:I'
- `E153` Updatable queries with subqueries (open). 0/1 probes match; first gap: E153.updatable_subquery #4 `UPDATE t SET b = 1 WHERE a IN (SELECT a FROM u)` head: PostgreSQL 'C:UPDATE 2;Z:I', ZPM 'E:0A000;Z:I'
- `F200` TRUNCATE TABLE statement (open). 0/1 probes match; first gap: F200.truncate #12 `TRUNCATE p CASCADE` head: PostgreSQL 'C:TRUNCATE TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `F311-04` Schema definition statement: CREATE VIEW: WITH CHECK OPTION (open). 0/1 probes match; first gap: F311-04.check_option #1 `CREATE VIEW v AS SELECT a FROM t WHERE a > 0 WITH CHECK OPTION` head: PostgreSQL 'C:CREATE VIEW;Z:I', ZPM 'E:0A000;Z:I'
- `F492` Optional table constraint enforcement (open). 0/1 probes match; first gap: F492.not_enforced #0 `CREATE TABLE t(a INT, CONSTRAINT a_pos CHECK (a > 0) NOT ENFORCED)` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:42601;Z:I'
- `F672` Retrospective CHECK constraints (open). 0/1 probes match; first gap: F672.retrospective_check #1 `INSERT INTO t VALUES (DATE '2000-01-01')` head: PostgreSQL 'C:INSERT 0 1;Z:I', ZPM 'E:0A000;Z:I'
- `F701` Referential update actions (open). 0/1 probes match; first gap: F701.update_actions #14 `UPDATE p SET id = 20 WHERE id = 2` head: PostgreSQL 'E:23001;Z:I', ZPM 'E:23503;Z:I'
- `F751` View CHECK enhancements (open). 0/1 probes match; first gap: F751.view_check_enhancements #2 `CREATE VIEW v2 AS SELECT a FROM v1 WHERE a < 10 WITH LOCAL CHECK OPTION` head: PostgreSQL 'C:CREATE VIEW;Z:I', ZPM 'E:0A000;Z:I'
- `F781` Self-referencing operations (open). 0/1 probes match; first gap: F781.self_reference #3 `UPDATE t SET a = a + (SELECT max(a) FROM t) WHERE a < 3` head: PostgreSQL 'C:UPDATE 2;Z:I', ZPM 'E:0A000;Z:I'
- `T191` Referential action RESTRICT (open). 0/1 probes match; first gap: T191.restrict #4 `DELETE FROM p WHERE id = 1` head: PostgreSQL 'E:23001;Z:I', ZPM 'E:23503;Z:I'
- `T201` Comparable data types for referential constraints (open). 0/1 probes match; first gap: T201.comparable_fk_types #1 `CREATE TABLE c(pid INT REFERENCES p, pcode TEXT REFERENCES p(code))` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:42804;Z:I'

### DDL and schema objects: tables, views, schemas, ALTER, domains, collations (19)

- `F031` Basic schema manipulation (partial). 5/7 probes match; first gap: F031-13.drop_table_restrict #3 `DROP VIEW v` head: PostgreSQL 'C:DROP VIEW;Z:I', ZPM 'C:DROP TABLE;Z:I'
- `F311` Schema definition statement (partial). 2/5 probes match; first gap: F311-01.create_schema #3 `CREATE SCHEMA t2 CREATE TABLE x(a INT) CREATE VIEW y AS SELECT a FROM x` head: PostgreSQL 'C:CREATE SCHEMA;Z:I', ZPM 'E:0A000;Z:I'
- `F031-13` Basic schema manipulation: DROP TABLE statement: RESTRICT clause (open). 0/1 probes match; first gap: F031-13.drop_table_restrict #3 `DROP VIEW v` head: PostgreSQL 'C:DROP VIEW;Z:I', ZPM 'C:DROP TABLE;Z:I'
- `F031-16` Basic schema manipulation: DROP VIEW statement: RESTRICT clause (open). 0/1 probes match; first gap: F031-16.drop_view_restrict #4 `DROP VIEW w RESTRICT` head: PostgreSQL 'C:DROP VIEW;Z:I', ZPM 'C:DROP TABLE;Z:I'
- `F033` ALTER TABLE statement: DROP COLUMN clause (open). 0/1 probes match; first gap: F033.drop_column #8 `ALTER TABLE t DROP COLUMN c CASCADE` head: PostgreSQL 'C:ALTER TABLE;Z:I', ZPM 'E:2BP01;Z:I'
- `F171` Multiple schemas per user (open). 0/1 probes match; first gap: F171.schemas #1 `CREATE SCHEMA s2 AUTHORIZATION CURRENT_USER` head: PostgreSQL 'C:CREATE SCHEMA;Z:I', ZPM 'E:0A000;Z:I'
- `F251` Domain support (open). 0/1 probes match; first gap: F251.domains #1 `CREATE DOMAIN code AS VARCHAR(3) NOT NULL DEFAULT 'abc'` head: PostgreSQL 'C:CREATE DOMAIN;Z:I', ZPM 'E:0A000;Z:I'
- `F311-01` Schema definition statement: CREATE SCHEMA (open). 0/1 probes match; first gap: F311-01.create_schema #3 `CREATE SCHEMA t2 CREATE TABLE x(a INT) CREATE VIEW y AS SELECT a FROM x` head: PostgreSQL 'C:CREATE SCHEMA;Z:I', ZPM 'E:0A000;Z:I'
- `F382` Alter column data type (open). 0/1 probes match; first gap: F382.alter_type #2 `ALTER TABLE t ALTER COLUMN a TYPE BIGINT` head: PostgreSQL 'C:ALTER TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `F384` Drop identity property clause (open). 0/1 probes match; first gap: F384.drop_identity #2 `ALTER TABLE t ALTER COLUMN id DROP IDENTITY` head: PostgreSQL 'C:ALTER TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `F385` Drop column generation expression clause (open). 0/1 probes match; first gap: F385.drop_expression #2 `ALTER TABLE t ALTER COLUMN b DROP EXPRESSION` head: PostgreSQL 'C:ALTER TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `F386` Set identity column generation clause (open). 0/1 probes match; first gap: F386.set_generation #2 `ALTER TABLE t ALTER COLUMN id SET GENERATED BY DEFAULT` head: PostgreSQL 'C:ALTER TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `F387` ALTER TABLE statement: ALTER COLUMN clause (open). 0/1 probes match; first gap: F387.alter_column #1 `ALTER TABLE t ALTER COLUMN a SET DEFAULT 1, ALTER COLUMN b TYPE VARCHAR(10)` head: PostgreSQL 'C:ALTER TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `F491` Constraint management (open). 0/1 probes match; first gap: F491.constraint_management #3 `SELECT conname, contype FROM pg_constraint WHERE conrelid = 't'::regclass ORDER BY conname` head: PostgreSQL 'T:conname/19/64/-1,contype/18/1/-1;C:SELECT 4;Z:I', ZPM 'T:conname/19/64/-1,contype/25/-1/-1;C:SELECT 2;Z:I'
- `F531` Temporary tables (open). 0/1 probes match; first gap: F531.temporary_tables #1 `CREATE TEMP TABLE tc(a INT) ON COMMIT DELETE ROWS` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:42601;Z:I'
- `F690` Collation support (open). 0/1 probes match; first gap: F690.collation #1 `CREATE TABLE t(s TEXT COLLATE "C")` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `F692` Extended collation support (open). 0/1 probes match; first gap: F692.extended_collation #0 `CREATE COLLATION mycoll (provider = libc, locale = 'C')` head: PostgreSQL 'C:CREATE COLLATION;Z:I', ZPM 'E:42601;Z:I'
- `F711` ALTER domain (open). 0/1 probes match; first gap: F711.alter_domain #1 `CREATE TABLE t(a d)` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `T178` Identity columns: simple restart option (open). 0/1 probes match; first gap: T178.identity_restart #2 `ALTER TABLE t ALTER COLUMN id RESTART` head: PostgreSQL 'C:ALTER TABLE;Z:I', ZPM 'E:0A000;Z:I'

### Core data types, casts and literals (1)

- `F421` National character (open). 0/1 probes match; first gap: F421.national_character #0 `CREATE TABLE t(a NCHAR(3), b NATIONAL CHARACTER VARYING(5), c NCHAR VARYING(4), d NATIO...` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:0A000;Z:I'

### Date, time, timestamp and interval (6)

- `F051` Basic date and time (partial). 5/8 probes match; first gap: F051-06.current_date #0 `SELECT CURRENT_DATE = CURRENT_DATE, pg_typeof(CURRENT_DATE), CURRENT_DATE > DATE '2020-...` head: PostgreSQL 'T:?column?/16/1/-1,pg_typeof/2206/4/-1,?column?/16/1/-1;C:SE', ZPM 'E:0A000;Z:I'
- `F051-06` Basic date and time: CURRENT_DATE (open). 0/1 probes match; first gap: F051-06.current_date #0 `SELECT CURRENT_DATE = CURRENT_DATE, pg_typeof(CURRENT_DATE), CURRENT_DATE > DATE '2020-...` head: PostgreSQL 'T:?column?/16/1/-1,pg_typeof/2206/4/-1,?column?/16/1/-1;C:SE', ZPM 'E:0A000;Z:I'
- `F051-07` Basic date and time: LOCALTIME (open). 0/1 probes match; first gap: F051-07.localtime #0 `SELECT pg_typeof(LOCALTIME), pg_typeof(LOCALTIME(0)), LOCALTIME = LOCALTIME` head: PostgreSQL 'T:pg_typeof/2206/4/-1,pg_typeof/2206/4/-1,?column?/16/1/-1;C', ZPM 'E:42703;Z:I'
- `F051-08` Basic date and time: LOCALTIMESTAMP (open). 0/1 probes match; first gap: F051-08.localtimestamp #0 `SELECT pg_typeof(LOCALTIMESTAMP), pg_typeof(LOCALTIMESTAMP(2)), LOCALTIMESTAMP = LOCALT...` head: PostgreSQL 'T:pg_typeof/2206/4/-1,pg_typeof/2206/4/-1,?column?/16/1/-1,?', ZPM 'E:42703;Z:I'
- `F052` Intervals and datetime arithmetic (open). 0/1 probes match; first gap: F052.intervals #0 `SELECT INTERVAL '1 day', INTERVAL '2 hours 30 minutes', INTERVAL '1' YEAR, INTERVAL '1-...` head: PostgreSQL 'T:interval/1186/16/-1,interval/1186/16/-1,interval/1186/16/3', ZPM 'E:42601;Z:I'
- `F411` Time zone specification (open). 0/1 probes match; first gap: F411.time_zone #1 `SELECT TIMESTAMP '2024-01-01 12:00' AT TIME ZONE 'UTC', TIMESTAMPTZ '2024-01-01 12:00+0...` head: PostgreSQL 'T:timezone/1184/8/-1,timezone/1114/8/-1,timezone/1114/8/-1;C', ZPM 'E:42601;Z:I'

### Character strings and text functions (3)

- `E021` Character data types (partial). 11/12 probes match; first gap: E021-08.upper_lower #0 `SELECT UPPER('abcÄé'), LOWER('ABCxyz'), UPPER(NULL)` rows: PostgreSQL 'ABCÄÉ\|abcxyz\|\\N', ZPM 'ABCÄé\|abcxyz\|\\N'
- `E021-08` Character string types: UPPER and LOWER functions (open). 0/1 probes match; first gap: E021-08.upper_lower #0 `SELECT UPPER('abcÄé'), LOWER('ABCxyz'), UPPER(NULL)` rows: PostgreSQL 'ABCÄÉ\|abcxyz\|\\N', ZPM 'ABCÄé\|abcxyz\|\\N'
- `T581` Regular expression substring function (open). 0/1 probes match; first gap: T581.regex_substring #0 `SELECT SUBSTRING('foobar' SIMILAR '%#"o_b#"%' ESCAPE '#'), SUBSTRING('foobar' FROM '%#"...` head: PostgreSQL 'T:substring/25/-1/-1,substring/25/-1/-1,substring/25/-1/-1,s', ZPM 'E:42601;Z:I'

### Numeric functions (2)

- `T621` Enhanced numeric functions (open). 0/1 probes match; first gap: T621.numeric_functions #0 `SELECT ln(1), exp(0), power(2, 10), power(2.0, 0.5), sqrt(16), floor(-1.5), ceiling(1.2...` head: PostgreSQL 'T:ln/701/8/-1,exp/701/8/-1,power/701/8/-1,power/1700/-1/-1,s', ZPM 'E:42883;Z:I'
- `T622` Trigonometric functions (open). 0/1 probes match; first gap: T622.trig #0 `SELECT round(sin(0)::numeric, 6), round(cos(0)::numeric, 6), round(tan(pi() / 4)::numer...` head: PostgreSQL 'T:round/1700/-1/-1,round/1700/-1/-1,round/1700/-1/-1,round/1', ZPM 'E:42883;Z:I'

### Aggregates and grouping sets (1)

- `T626` ANY_VALUE (open). 0/1 probes match; first gap: T626.any_value #2 `SELECT g, any_value(v) FROM t GROUP BY g` head: PostgreSQL 'T:g/23/4/-1,any_value/23/4/-1;C:SELECT 2;Z:I', ZPM 'E:42883;Z:I'

### Transactions, savepoints, isolation and session (7)

- `E151` Transaction support (partial). 1/2 probes match; first gap: E151-01.commit #6 `START TRANSACTION` head: PostgreSQL 'C:START TRANSACTION;Z:T', ZPM 'C:BEGIN;Z:T'
- `E151-01` Transaction support: COMMIT statement (open). 0/1 probes match; first gap: E151-01.commit #6 `START TRANSACTION` head: PostgreSQL 'C:START TRANSACTION;Z:T', ZPM 'C:BEGIN;Z:T'
- `E171` SQLSTATE support (open). 0/1 probes match; first gap: E171.sqlstate #6 `SELEC 1` head: PostgreSQL 'E:42601;Z:I', ZPM 'E:0A000;Z:I'
- `F112` Isolation level READ UNCOMMITTED (open). 0/1 probes match; first gap: F112.read_uncommitted #0 `START TRANSACTION ISOLATION LEVEL READ UNCOMMITTED` head: PostgreSQL 'C:START TRANSACTION;Z:T', ZPM 'C:BEGIN;Z:T'
- `F761` Session management (open). 0/1 probes match; first gap: F761.session_management #6 `SET SCHEMA 's'` head: PostgreSQL 'C:SET;Z:I', ZPM 'E:42601;Z:I'
- `T241` START TRANSACTION statement (open). 0/1 probes match; first gap: T241.start_transaction #1 `START TRANSACTION` head: PostgreSQL 'C:START TRANSACTION;Z:T', ZPM 'C:BEGIN;Z:T'
- `T261` Chained transactions (open). 0/1 probes match; first gap: T261.chained #3 `COMMIT AND CHAIN` head: PostgreSQL 'C:COMMIT;Z:T', ZPM 'E:0A000;Z:E'

### Cursors (4)

- `E121` Basic cursor support (partial). 6/9 probes match; first gap: E121-06.positioned_update #5 `UPDATE t SET b = 9 WHERE CURRENT OF c` head: PostgreSQL 'C:UPDATE 1;Z:T', ZPM 'E:42601;Z:E'
- `E121-06` Basic cursor support: Positioned UPDATE statement (open). 0/1 probes match; first gap: E121-06.positioned_update #5 `UPDATE t SET b = 9 WHERE CURRENT OF c` head: PostgreSQL 'C:UPDATE 1;Z:T', ZPM 'E:42601;Z:E'
- `E121-07` Basic cursor support: Positioned DELETE statement (open). 0/1 probes match; first gap: E121-07.positioned_delete #5 `DELETE FROM t WHERE CURRENT OF c` head: PostgreSQL 'C:DELETE 1;Z:T', ZPM 'E:42601;Z:E'
- `E121-08` Basic cursor support: CLOSE statement (open). 0/1 probes match; first gap: E121-08.close #8 `CLOSE ALL` head: PostgreSQL 'C:CLOSE CURSOR ALL;Z:T', ZPM 'C:CLOSE CURSOR;Z:T'

### Triggers (5)

- `T212` Enhanced trigger capability (open). 0/1 probes match; first gap: T212.statement_triggers #3 `CREATE TRIGGER tr AFTER INSERT ON t REFERENCING NEW TABLE AS newrows FOR EACH STATEMENT...` head: PostgreSQL 'C:CREATE TRIGGER;Z:I', ZPM 'E:0A000;Z:I'
- `T213` INSTEAD OF triggers (open). 0/1 probes match; first gap: T213.instead_of #3 `CREATE TRIGGER tr INSTEAD OF INSERT ON v FOR EACH ROW EXECUTE FUNCTION v_ins()` head: PostgreSQL 'C:CREATE TRIGGER;Z:I', ZPM 'E:0A000;Z:I'
- `T215` AFTER triggers (open). 0/1 probes match; first gap: T215.after #4 `INSERT INTO t VALUES (1)` head: PostgreSQL 'C:INSERT 0 1;Z:I', ZPM 'E:0A000;Z:I'
- `T216` Ability to require true search condition before trigger is invoked (open). 0/1 probes match; first gap: T216.when #5 `INSERT INTO t VALUES (5), (15)` head: PostgreSQL 'C:INSERT 0 2;Z:I', ZPM 'E:0A000;Z:I'
- `T217` TRIGGER privilege (open). 0/1 probes match; first gap: T217.trigger_privilege #1 `GRANT CREATE ON SCHEMA public TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'

### Routines: functions, procedures, PL/pgSQL, overloading (12)

- `T321-04` Basic SQL-invoked routines: CALL statement (open). 0/1 probes match; first gap: T321-04.call #1 `CREATE PROCEDURE p(x INT, INOUT y INT) LANGUAGE plpgsql AS $$BEGIN INSERT INTO t VALUES...` head: PostgreSQL 'C:CREATE PROCEDURE;Z:I', ZPM 'E:0A000;Z:I'
- `T321-05` Basic SQL-invoked routines: RETURN statement (open). 0/1 probes match; first gap: T321-05.return #1 `CREATE FUNCTION r(x INT) RETURNS INT LANGUAGE SQL RETURN x * 3` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:0A000;Z:I'
- `T323` Explicit security for external routines (open). 0/1 probes match; first gap: T323.external_security #3 `CREATE FUNCTION peek() RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS $$BEGIN RETURN ...` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:0A000;Z:I'
- `T325` Qualified SQL parameter references (open). 0/1 probes match; first gap: T325.qualified_params #4 `SELECT f(2), g(5)` head: PostgreSQL 'T:f/20/8/-1,g/23/4/-1;C:SELECT 1;Z:I', ZPM 'E:0A000;Z:I'
- `T521` Named arguments in CALL statement (open). 0/1 probes match; first gap: T521.named_call_args #2 `CALL ins(y => 'b', x => 1)` head: PostgreSQL 'C:CALL;Z:I', ZPM 'E:42601;Z:I'
- `T523` Default values for INOUT parameters of SQL-invoked procedures (open). 0/1 probes match; first gap: T523.inout_defaults #0 `CREATE PROCEDURE p(INOUT a INT DEFAULT 5, INOUT b INT DEFAULT 6) LANGUAGE plpgsql AS $$...` head: PostgreSQL 'C:CREATE PROCEDURE;Z:I', ZPM 'E:0A000;Z:I'
- `T524` Named arguments in routine invocations other than a CALL statement (open). 0/1 probes match; first gap: T524.named_function_args #1 `SELECT f(b => 'x', a => 1), f(2, b => 'y'), f(a := 3, b := 'z')` head: PostgreSQL 'T:f/25/-1/-1,f/25/-1/-1,f/25/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `T525` Default values for parameters of SQL-invoked functions (open). 0/1 probes match; first gap: T525.function_defaults #0 `CREATE FUNCTION f(a INT, b INT DEFAULT 10, c TEXT DEFAULT 'd') RETURNS TEXT LANGUAGE SQ...` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:0A000;Z:I'
- `T651` SQL-schema statements in SQL routines (open). 0/1 probes match; first gap: T651.schema_statements_sql_routines #1 `SELECT mk()` head: PostgreSQL 'T:mk/2278/4/-1;C:SELECT 1;Z:I', ZPM 'E:0A000;Z:I'
- `T653` SQL-schema statements in external routines (open). 0/1 probes match; first gap: T653.schema_statements_external #0 `CREATE FUNCTION mk(n TEXT) RETURNS VOID LANGUAGE plpgsql AS $$BEGIN EXECUTE 'CREATE TAB...` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:42601;Z:I'
- `S071` SQL paths in function and type name resolution (open). 0/1 probes match; first gap: S071.sql_paths #2 `CREATE FUNCTION s1.f() RETURNS TEXT LANGUAGE SQL AS $$SELECT 's1'$$` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:0A000;Z:I'
- `S211` User-defined cast functions (open). 0/1 probes match; first gap: S211.user_cast #1 `CREATE FUNCTION pt_text(p pt) RETURNS TEXT LANGUAGE SQL AS $$SELECT p.x \|\| ':' \|\| p.y$$` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:42601;Z:I'

### Privileges and roles (13)

- `E081` Basic Privileges (partial). 5/10 probes match; first gap: E081-05.update_column_priv #3 `GRANT UPDATE (b) ON t TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `E081-05` Basic Privileges: UPDATE privilege at the column level (open). 0/1 probes match; first gap: E081-05.update_column_priv #3 `GRANT UPDATE (b) ON t TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `E081-06` Basic Privileges: REFERENCES privilege at the table level (open). 0/1 probes match; first gap: E081-06.references_priv #1 `GRANT CREATE ON SCHEMA public TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `E081-07` Basic Privileges: REFERENCES privilege at the column level (open). 0/1 probes match; first gap: E081-07.references_column_priv #1 `GRANT CREATE ON SCHEMA public TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `E081-08` Basic Privileges: WITH GRANT OPTION (open). 0/1 probes match; first gap: E081-08.grant_option #10 `GRANT SELECT ON t TO w4f_a` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:42501;Z:I'
- `E081-09` Basic Privileges: USAGE privilege (open). 0/1 probes match; first gap: E081-09.usage_priv #12 `GRANT USAGE ON DOMAIN d TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `F034` Extended REVOKE statement (open). 0/1 probes match; first gap: F034.extended_revoke #9 `GRANT UPDATE (a) ON t TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `F035` REVOKE with CASCADE (open). 0/1 probes match; first gap: F035.revoke_cascade #7 `REVOKE SELECT ON t FROM w4f_a` head: PostgreSQL 'E:2BP01;Z:I', ZPM 'C:REVOKE;Z:I'
- `F037` REVOKE statement: GRANT OPTION FOR clause (open). 0/1 probes match; first gap: F037.grant_option_for #7 `GRANT SELECT ON t TO w4f_b` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:42501;Z:I'
- `F311-05` Schema definition statement: GRANT statement (open). 0/1 probes match; first gap: F311-05.schema_grant #4 `GRANT SELECT ON ALL TABLES IN SCHEMA s TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `F731` INSERT column privileges (open). 0/1 probes match; first gap: F731.insert_column_privileges #2 `GRANT INSERT (a) ON t TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `T281` SELECT privilege with column granularity (open). 0/1 probes match; first gap: T281.column_select_privilege #3 `GRANT SELECT (a) ON t TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `T332` Extended roles (open). 0/1 probes match; first gap: T332.extended_roles #16 `SELECT count(*) FROM t` head: PostgreSQL 'T:count/20/8/-1;C:SELECT 1;Z:I', ZPM 'E:42501;Z:I'

### information_schema and catalog views (18)

- `F021` Basic information schema (open). 0/7 probes match; first gap: F021-01.columns #1 `SELECT column_name, ordinal_position, is_nullable, data_type, character_maximum_length,...` head: PostgreSQL 'T:column_name/19/64/-1,ordinal_position/23/4/-1,is_nullable/', ZPM 'T:column_name/19/64/-1,ordinal_position/23/4/-1,is_nullable/'
- `F021-01` Basic information schema: COLUMNS view (open). 0/2 probes match; first gap: F021-01.columns #1 `SELECT column_name, ordinal_position, is_nullable, data_type, character_maximum_length,...` head: PostgreSQL 'T:column_name/19/64/-1,ordinal_position/23/4/-1,is_nullable/', ZPM 'T:column_name/19/64/-1,ordinal_position/23/4/-1,is_nullable/'
- `F021-02` Basic information schema: TABLES view (open). 0/1 probes match; first gap: F021-02.tables #2 `SELECT table_catalog = current_database(), table_schema, table_name, table_type, is_ins...` head: PostgreSQL 'T:?column?/16/1/-1,table_schema/19/64/-1,table_name/19/64/-1', ZPM 'E:42703;Z:I'
- `F021-03` Basic information schema: VIEWS view (open). 0/1 probes match; first gap: F021-03.views #1 `CREATE VIEW v AS SELECT a FROM t WHERE a > 0 WITH CHECK OPTION` head: PostgreSQL 'C:CREATE VIEW;Z:I', ZPM 'E:0A000;Z:I'
- `F021-04` Basic information schema: TABLE_CONSTRAINTS view (open). 0/1 probes match; first gap: F021-04.table_constraints #2 `SELECT table_name, constraint_type, is_deferrable, initially_deferred FROM information_...` head: PostgreSQL 'T:table_name/19/64/-1,constraint_type/1043/-1/-1,is_deferrab', ZPM 'E:42703;Z:I'
- `F021-05` Basic information schema: REFERENTIAL_CONSTRAINTS view (open). 0/1 probes match; first gap: F021-05.referential_constraints #2 `SELECT constraint_name, unique_constraint_name, match_option, update_rule, delete_rule ...` head: PostgreSQL 'T:constraint_name/19/64/-1,unique_constraint_name/19/64/-1,m', ZPM 'E:42P01;Z:I'
- `F021-06` Basic information schema: CHECK_CONSTRAINTS view (open). 0/1 probes match; first gap: F021-06.check_constraints #1 `SELECT constraint_name, check_clause FROM information_schema.check_constraints WHERE co...` head: PostgreSQL 'T:constraint_name/19/64/-1,check_clause/1043/-1/-1;C:SELECT ', ZPM 'E:42P01;Z:I'
- `F231` Privilege tables (open). 0/1 probes match; first gap: F231.privilege_tables #3 `GRANT UPDATE (b) ON t TO w4f_r` head: PostgreSQL 'C:GRANT;Z:I', ZPM 'E:0A000;Z:I'
- `F341` Usage tables (open). 0/1 probes match; first gap: F341.usage_tables #1 `CREATE TABLE p(id INT PRIMARY KEY, x d)` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `F501` Features and conformance views (open). 0/2 probes match; first gap: F501-01.sql_features #0 `SELECT column_name FROM information_schema.columns WHERE table_schema = 'information_sc...` head: PostgreSQL 'T:column_name/19/64/-1;C:SELECT 7;Z:I', ZPM 'T:column_name/19/64/-1;C:SELECT 0;Z:I'
- `F501-01` Features and conformance views: SQL_FEATURES view (open). 0/1 probes match; first gap: F501-01.sql_features #0 `SELECT column_name FROM information_schema.columns WHERE table_schema = 'information_sc...` head: PostgreSQL 'T:column_name/19/64/-1;C:SELECT 7;Z:I', ZPM 'T:column_name/19/64/-1;C:SELECT 0;Z:I'
- `F501-02` Features and conformance views: SQL_SIZING view (open). 0/1 probes match; first gap: F501-02.sql_sizing #0 `SELECT column_name FROM information_schema.columns WHERE table_schema = 'information_sc...` head: PostgreSQL 'T:column_name/19/64/-1;C:SELECT 4;Z:I', ZPM 'T:column_name/19/64/-1;C:SELECT 0;Z:I'
- `F502` Enhanced documentation tables (open). 0/1 probes match; first gap: F502.documentation_tables #0 `SELECT column_name FROM information_schema.columns WHERE table_schema = 'information_sc...` head: PostgreSQL 'T:column_name/19/64/-1;C:SELECT 5;Z:I', ZPM 'T:column_name/19/64/-1;C:SELECT 0;Z:I'
- `F762` CURRENT_CATALOG (open). 0/1 probes match; first gap: F762.current_catalog #0 `SELECT CURRENT_CATALOG, current_database() = CURRENT_CATALOG, pg_typeof(CURRENT_CATALOG)` head: PostgreSQL 'T:current_catalog/19/64/-1,?column?/16/1/-1,pg_typeof/2206/4', ZPM 'E:42703;Z:I'
- `F763` CURRENT_SCHEMA (open). 0/1 probes match; first gap: F763.current_schema #0 `SELECT CURRENT_SCHEMA, current_schema(), pg_typeof(CURRENT_SCHEMA)` head: PostgreSQL 'T:current_schema/19/64/-1,current_schema/19/64/-1,pg_typeof/', ZPM 'E:42703;Z:I'
- `F869` SQL implementation info population (open). 0/1 probes match; first gap: F869.implementation_info #0 `SELECT implementation_info_name FROM information_schema.sql_implementation_info WHERE i...` head: PostgreSQL 'T:implementation_info_name/1043/-1/-1;C:SELECT 2;Z:I', ZPM 'E:42P01;Z:I'
- `T321-06` Basic SQL-invoked routines: ROUTINES view (open). 0/1 probes match; first gap: T321-06.routines_view #2 `SELECT routine_name, routine_type, data_type, external_language FROM information_schema...` head: PostgreSQL 'T:routine_name/19/64/-1,routine_type/1043/-1/-1,data_type/10', ZPM 'E:42P01;Z:I'
- `T321-07` Basic SQL-invoked routines: PARAMETERS view (open). 0/1 probes match; first gap: T321-07.parameters_view #0 `CREATE FUNCTION f1(a INT, INOUT b TEXT, OUT c DATE) LANGUAGE SQL AS $$SELECT b, CURRENT...` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:0A000;Z:I'

### Arrays and user-defined type arrays (6)

- `S092` Arrays of user-defined types (open). 0/1 probes match; first gap: S092.arrays_udt #2 `CREATE TABLE t(a pos[], m mood[])` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:0A000;Z:I'
- `S099` Array expressions (open). 0/1 probes match; first gap: S099.array_expressions #1 `SELECT (ARRAY[1, 2, 3, 4])[2:3], (ARRAY['a', 'b', 'c'])[:2], array_position(ARRAY['a', ...` head: PostgreSQL 'T:array/1007/-1/-1,array/1009/-1/-1,array_position/23/4/-1,a', ZPM 'E:42883;Z:I'
- `S201` SQL-invoked routines on arrays (open). 0/1 probes match; first gap: S201.routines_on_arrays #2 `SELECT total(ARRAY[1, 2, 3]), firsts(ARRAY['p', 'q']), total('{}')` head: PostgreSQL 'T:total/23/4/-1,firsts/25/-1/-1,total/23/4/-1;C:SELECT 1;Z:I', ZPM 'E:0A000;Z:I'
- `S203` Array parameters (open). 0/1 probes match; first gap: S203.array_parameters #1 `CREATE PROCEDURE p(xs INT[], INOUT n INT) LANGUAGE plpgsql AS $$BEGIN n := cardinality(...` head: PostgreSQL 'C:CREATE PROCEDURE;Z:I', ZPM 'E:0A000;Z:I'
- `S301` Enhanced UNNEST (open). 0/1 probes match; first gap: S301.enhanced_unnest #0 `SELECT * FROM unnest(ARRAY[1, 2], ARRAY['a', 'b', 'c']) AS u(n, s)` head: PostgreSQL 'T:n/23/4/-1,s/25/-1/-1;C:SELECT 3;Z:I', ZPM 'E:42883;Z:I'
- `S404` TRIM_ARRAY (open). 0/1 probes match; first gap: S404.trim_array #0 `SELECT trim_array(ARRAY[1, 2, 3, 4], 2), trim_array(ARRAY['a', 'b'], 0), trim_array(ARR...` head: PostgreSQL 'T:trim_array/1007/-1/-1,trim_array/1009/-1/-1,trim_array/100', ZPM 'E:42883;Z:I'

### SQL/JSON (24)

- `T811` Basic SQL/JSON constructor functions (open). 0/1 probes match; first gap: T811.json_constructors #0 `SELECT JSON_OBJECT('a' VALUE 1, 'b' VALUE 'x'), JSON_ARRAY(1, 'two', NULL), JSON_ARRAY(...` head: PostgreSQL 'T:json_object/114/-1/-1,json_array/114/-1/-1,json_array/114/', ZPM 'E:42601;Z:I'
- `T812` SQL/JSON: JSON_OBJECTAGG (open). 0/1 probes match; first gap: T812.json_objectagg #2 `SELECT JSON_OBJECTAGG(k VALUE v), JSON_OBJECTAGG(k VALUE v ABSENT ON NULL), JSON_OBJECT...` head: PostgreSQL 'T:json_objectagg/114/-1/-1,json_objectagg/114/-1/-1,json_obj', ZPM 'E:42601;Z:I'
- `T813` SQL/JSON: JSON_ARRAYAGG with ORDER BY (open). 0/1 probes match; first gap: T813.json_arrayagg_order #2 `SELECT JSON_ARRAYAGG(v ORDER BY v), JSON_ARRAYAGG(v ORDER BY v DESC NULL ON NULL), JSON...` head: PostgreSQL 'T:json_arrayagg/114/-1/-1,json_arrayagg/114/-1/-1,json_array', ZPM 'E:42601;Z:I'
- `T814` Colon in JSON_OBJECT or JSON_OBJECTAGG (open). 0/1 probes match; first gap: T814.json_colon #2 `SELECT JSON_OBJECT('a' : 1, 'b' : 'c'), JSON_OBJECTAGG(k : v) FROM t` head: PostgreSQL 'T:json_object/114/-1/-1,json_objectagg/114/-1/-1;C:SELECT 1;', ZPM 'E:42601;Z:I'
- `T821` Basic SQL/JSON query operators (open). 0/1 probes match; first gap: T821.json_query_operators #0 `SELECT JSON_EXISTS(jsonb '{"a": [1, 2]}', '$.a[1]'), JSON_EXISTS(jsonb '{"a": 1}', '$.b...` head: PostgreSQL 'T:json_exists/16/1/-1,json_exists/16/1/-1,json_value/25/-1/-', ZPM 'E:42601;Z:I'
- `T822` SQL/JSON: IS JSON WITH UNIQUE KEYS predicate (open). 0/1 probes match; first gap: T822.is_json_unique #0 `SELECT '{"a":1,"a":2}' IS JSON, '{"a":1,"a":2}' IS JSON WITH UNIQUE KEYS, '{"a":1,"b":2...` head: PostgreSQL 'T:?column?/16/1/-1,?column?/16/1/-1,?column?/16/1/-1,?column', ZPM 'E:42601;Z:I'
- `T823` SQL/JSON: PASSING clause (open). 0/1 probes match; first gap: T823.passing #0 `SELECT JSON_EXISTS(jsonb '{"a": 5}', '$.a ? (@ > $min)' PASSING 3 AS min), JSON_VALUE(j...` head: PostgreSQL 'T:json_exists/16/1/-1,json_value/25/-1/-1,json_query/3802/-1', ZPM 'E:42601;Z:I'
- `T825` SQL/JSON: ON EMPTY and ON ERROR clauses (open). 0/1 probes match; first gap: T825.on_empty_on_error #0 `SELECT JSON_VALUE(jsonb '{"a": 1}', '$.b' NULL ON EMPTY), JSON_VALUE(jsonb '{"a": "x"}'...` head: PostgreSQL 'T:json_value/25/-1/-1,json_value/23/4/-1,json_query/3802/-1/', ZPM 'E:42601;Z:I'
- `T826` General value expression in ON ERROR or ON EMPTY clauses (open). 0/1 probes match; first gap: T826.on_error_expressions #0 `SELECT JSON_VALUE(jsonb '{}', '$.a' DEFAULT 'none' ON EMPTY), JSON_VALUE(jsonb '{"a": "...` head: PostgreSQL 'T:json_value/25/-1/-1,json_value/23/4/-1,json_value/23/4/-1;', ZPM 'E:42601;Z:I'
- `T827` JSON_TABLE: sibling NESTED COLUMNS clauses (open). 0/1 probes match; first gap: T827.json_table_nested #0 `SELECT * FROM JSON_TABLE(jsonb '{"a": [1, 2], "b": ["x"]}', '$' COLUMNS (NESTED PATH '$...` head: PostgreSQL 'T:a/23/4/-1,b/25/-1/-1;C:SELECT 3;Z:I', ZPM 'E:0A000;Z:I'
- `T828` JSON_QUERY (open). 0/1 probes match; first gap: T828.json_query #0 `SELECT JSON_QUERY(jsonb '{"a": {"b": [1, 2]}}', '$.a'), JSON_QUERY(jsonb '[1, 2]', '$[0...` head: PostgreSQL 'T:json_query/3802/-1/-1,json_query/3802/-1/-1,json_query/380', ZPM 'E:42601;Z:I'
- `T829` JSON_QUERY: array wrapper options (open). 0/1 probes match; first gap: T829.array_wrapper #0 `SELECT JSON_QUERY(jsonb '[1, 2, 3]', '$[*]' WITH WRAPPER), JSON_QUERY(jsonb '[1]', '$[0...` head: PostgreSQL 'T:json_query/3802/-1/-1,json_query/3802/-1/-1,json_query/380', ZPM 'E:42601;Z:I'
- `T830` Enforcing unique keys in SQL/JSON constructor functions (open). 0/1 probes match; first gap: T830.constructor_unique_keys #0 `SELECT JSON_OBJECT('a' VALUE 1, 'a' VALUE 2)` head: PostgreSQL 'T:json_object/114/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `T831` SQL/JSON path language: strict mode (open). 0/1 probes match; first gap: T831.strict_mode #2 `SELECT jsonb_path_query_array('{"a": 1}', 'strict $.b', '{}', true), jsonb_path_exists(...` rows: PostgreSQL '[]\|t', ZPM '\\N\|t'
- `T832` SQL/JSON path language: item method (open). 0/1 probes match; first gap: T832.item_methods #0 `SELECT jsonb_path_query_first('[1, 2, 3]', '$.size()'), jsonb_path_query_first('"x"', '...` head: PostgreSQL 'T:jsonb_path_query_first/3802/-1/-1,jsonb_path_query_first/3', ZPM 'E:0A000;Z:I'
- `T837` SQL/JSON path language: regex_like predicate (open). 0/1 probes match; first gap: T837.like_regex #0 `SELECT jsonb_path_query_array('["abc", "ABD", "xyz"]', '$[*] ? (@ like_regex "^ab")'), ...` head: PostgreSQL 'T:jsonb_path_query_array/3802/-1/-1,jsonb_path_query_array/3', ZPM 'E:0A000;Z:I'
- `T851` SQL/JSON: optional keywords for default syntax (open). 0/1 probes match; first gap: T851.json_optional_keywords #0 `SELECT JSON_OBJECT('a' VALUE 1 NULL ON NULL), JSON_OBJECT('a' VALUE 2 ABSENT ON NULL), ...` head: PostgreSQL 'T:json_object/114/-1/-1,json_object/114/-1/-1,json_array/114', ZPM 'E:42601;Z:I'
- `T867` SQL/JSON item method: date() (open). 0/1 probes match; first gap: T867.date_method #0 `SELECT jsonb_path_query_first('"2024-02-29"', '$.date()'), jsonb_path_query_first('"202...` head: PostgreSQL 'T:jsonb_path_query_first/3802/-1/-1,jsonb_path_query_first/3', ZPM 'E:0A000;Z:I'
- `T873` SQL/JSON item method: time() (open). 0/1 probes match; first gap: T873.time_method #0 `SELECT jsonb_path_query_first('"10:20:30"', '$.time()'), jsonb_path_query_first('"10:20...` head: PostgreSQL 'T:jsonb_path_query_first/3802/-1/-1,jsonb_path_query_first/3', ZPM 'E:0A000;Z:I'
- `T874` SQL/JSON item method: time_tz() (open). 0/1 probes match; first gap: T874.time_tz_method #0 `SELECT jsonb_path_query_first('"10:20:30+02"', '$.time_tz()'), jsonb_path_query_first('...` head: PostgreSQL 'T:jsonb_path_query_first/3802/-1/-1,jsonb_path_query_first/3', ZPM 'E:0A000;Z:I'
- `T875` SQL/JSON item method: time precision (open). 0/1 probes match; first gap: T875.time_precision #0 `SELECT jsonb_path_query_first('"10:20:30.123456"', '$.time(2)'), jsonb_path_query_first...` head: PostgreSQL 'T:jsonb_path_query_first/3802/-1/-1,jsonb_path_query_first/3', ZPM 'E:0A000;Z:I'
- `T876` SQL/JSON item method: timestamp() (open). 0/1 probes match; first gap: T876.timestamp_method #0 `SELECT jsonb_path_query_first('"2024-01-02 03:04:05"', '$.timestamp()'), jsonb_path_que...` head: PostgreSQL 'T:jsonb_path_query_first/3802/-1/-1,jsonb_path_query_first/3', ZPM 'E:0A000;Z:I'
- `T877` SQL/JSON item method: timestamp_tz() (open). 0/1 probes match; first gap: T877.timestamp_tz_method #0 `SELECT jsonb_path_query_first('"2024-01-02 03:04:05+00"', '$.timestamp_tz()'), jsonb_pa...` head: PostgreSQL 'T:jsonb_path_query_first/3802/-1/-1,jsonb_path_query_first/3', ZPM 'E:0A000;Z:I'
- `T878` SQL/JSON item method: timestamp precision (open). 0/1 probes match; first gap: T878.timestamp_precision #0 `SELECT jsonb_path_query_first('"2024-01-02 03:04:05.6789"', '$.timestamp(1)'), jsonb_pa...` head: PostgreSQL 'T:jsonb_path_query_first/3802/-1/-1,jsonb_path_query_first/3', ZPM 'E:0A000;Z:I'

### SQL/XML (42)

- `X014` Attributes of XML type (open). 0/1 probes match; first gap: X014.xml_attributes #1 `SELECT (ROW(1, '<p/>')::doc).body` head: PostgreSQL 'T:body/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `X016` Persistent XML values (open). 0/1 probes match; first gap: X016.persistent_xml #3 `SELECT xpath('/root/a/text()', x) FROM t` head: PostgreSQL 'T:xpath/143/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X020` XMLConcat (open). 0/1 probes match; first gap: X020.xmlconcat #0 `SELECT XMLCONCAT('<a/>', '<b>x</b>'), XMLCONCAT(NULL, '<c/>'), XMLCONCAT(NULL, NULL)` head: PostgreSQL 'T:xmlconcat/142/-1/-1,xmlconcat/142/-1/-1,xmlconcat/142/-1/-', ZPM 'E:42883;Z:I'
- `X031` XMLElement (open). 0/1 probes match; first gap: X031.xmlelement #0 `SELECT XMLELEMENT(NAME foo), XMLELEMENT(NAME foo, XMLATTRIBUTES(1 AS bar, 'x' AS "Baz")...` head: PostgreSQL 'T:xmlelement/142/-1/-1,xmlelement/142/-1/-1,xmlelement/142/-', ZPM 'E:42601;Z:I'
- `X032` XMLForest (open). 0/1 probes match; first gap: X032.xmlforest #0 `SELECT XMLFOREST(1 AS a, 'x' AS b, NULL AS c)` head: PostgreSQL 'T:xmlforest/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `X034` XMLAgg (open). 0/1 probes match; first gap: X034.xmlagg #2 `SELECT XMLAGG(XMLELEMENT(NAME v, v) ORDER BY v) FROM t` head: PostgreSQL 'T:xmlagg/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `X035` XMLAgg: ORDER BY option (open). 0/1 probes match; first gap: X035.xmlagg_order #2 `SELECT XMLAGG(XMLELEMENT(NAME n, v) ORDER BY v DESC) FROM t` head: PostgreSQL 'T:xmlagg/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `X036` XMLComment (open). 0/1 probes match; first gap: X036.xmlcomment #0 `SELECT XMLCOMMENT('hello'), XMLCOMMENT(NULL)` head: PostgreSQL 'T:xmlcomment/142/-1/-1,xmlcomment/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X037` XMLPI (open). 0/1 probes match; first gap: X037.xmlpi #0 `SELECT XMLPI(NAME php, 'echo 1;'), XMLPI(NAME foo)` head: PostgreSQL 'T:xmlpi/142/-1/-1,xmlpi/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `X038` XMLText (open). 0/1 probes match; first gap: X038.xmltext #0 `SELECT XMLTEXT('a < b & c'), XMLTEXT(NULL)` head: PostgreSQL 'T:xmltext/142/-1/-1,xmltext/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X040` Basic table mapping (open). 0/1 probes match; first gap: X040.table_mapping #2 `SELECT table_to_xml('t', false, false, '')` head: PostgreSQL 'T:table_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X041` Basic table mapping: null absent (open). 0/1 probes match; first gap: X041.table_mapping_null_absent #2 `SELECT table_to_xml('t', false, false, '')` head: PostgreSQL 'T:table_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X042` Basic table mapping: null as nil (open). 0/1 probes match; first gap: X042.table_mapping_null_nil #2 `SELECT table_to_xml('t', true, false, '')` head: PostgreSQL 'T:table_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X043` Basic table mapping: table as forest (open). 0/1 probes match; first gap: X043.table_mapping_forest #2 `SELECT table_to_xml('t', false, true, '')` head: PostgreSQL 'T:table_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X044` Basic table mapping: table as element (open). 0/1 probes match; first gap: X044.table_mapping_element #2 `SELECT table_to_xml('t', false, false, '')` head: PostgreSQL 'T:table_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X045` Basic table mapping: with target namespace (open). 0/1 probes match; first gap: X045.table_mapping_namespace #2 `SELECT table_to_xml('t', false, false, 'urn:example')` head: PostgreSQL 'T:table_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X046` Basic table mapping: data mapping (open). 0/1 probes match; first gap: X046.table_mapping_data #2 `SELECT table_to_xml('t', false, false, '')` head: PostgreSQL 'T:table_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X047` Basic table mapping: metadata mapping (open). 0/1 probes match; first gap: X047.table_mapping_metadata #1 `SELECT table_to_xmlschema('t', false, false, '')` head: PostgreSQL 'T:table_to_xmlschema/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X048` Basic table mapping: base64 encoding of binary strings (open). 0/1 probes match; first gap: X048.table_mapping_base64 #2 `SET xmlbinary = base64` head: PostgreSQL 'C:SET;Z:I', ZPM 'E:42704;Z:I'
- `X049` Basic table mapping: hex encoding of binary strings (open). 0/1 probes match; first gap: X049.table_mapping_hex #2 `SET xmlbinary = hex` head: PostgreSQL 'C:SET;Z:I', ZPM 'E:42704;Z:I'
- `X050` Advanced table mapping (open). 0/1 probes match; first gap: X050.advanced_mapping #3 `SELECT schema_to_xml('s', false, false, '')` head: PostgreSQL 'T:schema_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X051` Advanced table mapping: null absent (open). 0/1 probes match; first gap: X051.advanced_null_absent #3 `SELECT schema_to_xml('s', false, false, '')` head: PostgreSQL 'T:schema_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X052` Advanced table mapping: null as nil (open). 0/1 probes match; first gap: X052.advanced_null_nil #3 `SELECT schema_to_xml('s', true, false, '')` head: PostgreSQL 'T:schema_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X053` Advanced table mapping: table as forest (open). 0/1 probes match; first gap: X053.advanced_forest #3 `SELECT schema_to_xml('s', false, true, '')` head: PostgreSQL 'T:schema_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X054` Advanced table mapping: table as element (open). 0/1 probes match; first gap: X054.advanced_element #3 `SELECT schema_to_xml('s', false, false, '')` head: PostgreSQL 'T:schema_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X055` Advanced table mapping: with target namespace (open). 0/1 probes match; first gap: X055.advanced_namespace #2 `SELECT schema_to_xml('s', false, false, 'urn:x')` head: PostgreSQL 'T:schema_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X056` Advanced table mapping: data mapping (open). 0/1 probes match; first gap: X056.advanced_data #3 `SELECT schema_to_xml('s', false, false, '')` head: PostgreSQL 'T:schema_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X057` Advanced table mapping: metadata mapping (open). 0/1 probes match; first gap: X057.advanced_metadata #2 `SELECT schema_to_xmlschema('s', false, false, '')` head: PostgreSQL 'T:schema_to_xmlschema/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X058` Advanced table mapping: base64 encoding of binary strings (open). 0/1 probes match; first gap: X058.advanced_base64 #3 `SET xmlbinary = base64` head: PostgreSQL 'C:SET;Z:I', ZPM 'E:42704;Z:I'
- `X059` Advanced table mapping: hex encoding of binary strings (open). 0/1 probes match; first gap: X059.advanced_hex #3 `SET xmlbinary = hex` head: PostgreSQL 'C:SET;Z:I', ZPM 'E:42704;Z:I'
- `X069` XMLSerialize: INDENT (open). 0/1 probes match; first gap: X069.xmlserialize_indent #0 `SELECT XMLSERIALIZE(DOCUMENT '<a><b>1</b></a>' AS TEXT INDENT), XMLSERIALIZE(CONTENT '<...` head: PostgreSQL 'T:xmlserialize/25/-1/-1,xmlserialize/25/-1/-1;C:SELECT 1;Z:I', ZPM 'E:0A000;Z:I'
- `X072` XMLSerialize: character string serialization (open). 0/1 probes match; first gap: X072.xmlserialize #0 `SELECT XMLSERIALIZE(CONTENT XMLELEMENT(NAME e, 1) AS CHARACTER VARYING(30))` head: PostgreSQL 'T:xmlserialize/1043/-1/34;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `X090` XML document predicate (open). 0/1 probes match; first gap: X090.document_predicate #0 `SELECT '<a/>'::xml IS DOCUMENT, 'x<a/>'::xml IS DOCUMENT, '<a/>'::xml IS NOT DOCUMENT, ...` head: PostgreSQL 'T:?column?/16/1/-1,?column?/16/1/-1,?column?/16/1/-1,?column', ZPM 'E:42601;Z:I'
- `X120` XML parameters in SQL routines (open). 0/1 probes match; first gap: X120.xml_params_sql_routines #0 `CREATE FUNCTION wrap(x XML) RETURNS XML LANGUAGE SQL AS $$SELECT XMLELEMENT(NAME w, x)$$` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:42601;Z:I'
- `X121` XML parameters in external routines (open). 0/1 probes match; first gap: X121.xml_params_external #1 `SELECT root_name('<abc/>')` head: PostgreSQL 'T:root_name/25/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X221` XML passing mechanism BY VALUE (open). 0/1 probes match; first gap: X221.passing_by_value #0 `SELECT * FROM XMLTABLE('/r/i' PASSING BY VALUE '<r><i>1</i><i>2</i></r>' COLUMNS v INT ...` head: PostgreSQL 'T:v/23/4/-1;C:SELECT 2;Z:I', ZPM 'E:42601;Z:I'
- `X301` XMLTable: derived column list option (open). 0/1 probes match; first gap: X301.xmltable_columns #0 `SELECT * FROM XMLTABLE('/rows/row' PASSING '<rows><row a="1"><b>x</b></row><row a="2"><...` head: PostgreSQL 'T:a/23/4/-1,b/25/-1/-1;C:SELECT 2;Z:I', ZPM 'E:42601;Z:I'
- `X302` XMLTable: ordinality column option (open). 0/1 probes match; first gap: X302.xmltable_ordinality #0 `SELECT * FROM XMLTABLE('/r/i' PASSING '<r><i>p</i><i>q</i></r>' COLUMNS n FOR ORDINALIT...` head: PostgreSQL 'T:n/23/4/-1,v/25/-1/-1;C:SELECT 2;Z:I', ZPM 'E:42601;Z:I'
- `X303` XMLTable: column default option (open). 0/1 probes match; first gap: X303.xmltable_default #0 `SELECT * FROM XMLTABLE('/r/i' PASSING '<r><i v="1"/><i/></r>' COLUMNS v INT PATH '@v' D...` head: PostgreSQL 'T:v/23/4/-1;C:SELECT 2;Z:I', ZPM 'E:42601;Z:I'
- `X304` XMLTable: passing a context item (open). 0/1 probes match; first gap: X304.xmltable_context #0 `SELECT * FROM XMLTABLE('i' PASSING '<i>9</i>' COLUMNS v INT PATH '.')` head: PostgreSQL 'T:v/23/4/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `X400` Name and identifier mapping (open). 0/1 probes match; first gap: X400.name_mapping #2 `SELECT table_to_xml('"a b"', false, false, '')` head: PostgreSQL 'T:table_to_xml/142/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42883;Z:I'
- `X410` Alter column data type: XML type (open). 0/1 probes match; first gap: X410.alter_xml_type #2 `ALTER TABLE t ALTER COLUMN x TYPE XML USING x::xml` head: PostgreSQL 'C:ALTER TABLE;Z:I', ZPM 'E:0A000;Z:I'

### Lexical: identifiers, comments, literals (5)

- `F271` Compound character literals (open). 0/1 probes match; first gap: F271.compound_literals #0 `SELECT 'abc' 'def' AS x, 'a' 'b' 'c' AS y` head: PostgreSQL 'T:x/25/-1/-1,y/25/-1/-1;C:SELECT 1;Z:I', ZPM 'E:42601;Z:I'
- `F391` Long identifiers (open). 0/1 probes match; first gap: F391.long_identifiers #0 `CREATE TABLE abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk(c123456789...` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:54000;Z:I'
- `F392` Unicode escapes in identifiers (open). 0/1 probes match; first gap: F392.unicode_identifiers #0 `CREATE TABLE U&"d\0061t\+000061"(U&"\00e9" INT)` head: PostgreSQL 'C:CREATE TABLE;Z:I', ZPM 'E:42601;Z:I'
- `T661` Non-decimal integer literals (open). 0/1 probes match; first gap: T661.non_decimal_literals #0 `SELECT 0x1F, 0o17, 0b101, 0XFF, -0x10, pg_typeof(0x7FFFFFFF), pg_typeof(0x80000000)` head: PostgreSQL 'T:?column?/23/4/-1,?column?/23/4/-1,?column?/23/4/-1,?column', ZPM 'E:42601;Z:I'
- `T662` Underscores in numeric literals (open). 0/1 probes match; first gap: T662.underscores #0 `SELECT 1_000_000, 0x_FF, 1_000.000_1, 1_2e1_0` head: PostgreSQL 'T:?column?/23/4/-1,?column?/23/4/-1,?column?/1700/-1/-1,?col', ZPM 'E:42601;Z:I'

### Language bindings (1)

- `B128` Routine language SQL (open). 0/1 probes match; first gap: B128.routine_language_sql #1 `CREATE FUNCTION g(x INT) RETURNS INT LANGUAGE SQL RETURN x + 1` head: PostgreSQL 'C:CREATE FUNCTION;Z:I', ZPM 'E:0A000;Z:I'

## Reproducing

```
python tests/sql_conformance/verify_feature_oracle.py          # native PostgreSQL 18.x on 55491
python tests/sql_conformance/generate_feature_contract.py      # writes tests/test_sql_features.sig
sig build run-contract-sql-features -Doptimize=ReleaseSafe -j1  # or build-exe and capture stdout
python tests/sql_conformance/feature_status.py --results <ndjson>
```

The contract fails only when a probe that this scoreboard records as passing stops
passing. Newly passing probes print as improvements; rerun `feature_status.py` and
`generate_feature_contract.py` to fold them in.
