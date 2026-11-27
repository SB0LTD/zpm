-- # T series: enhanced SQL features. See feature_probes.py for the format.

-- probe T031.boolean
CREATE TABLE t(b BOOLEAN);
INSERT INTO t VALUES (TRUE), (FALSE), (NULL), ('yes'), ('off'), ('t');
SELECT b, NOT b, b AND TRUE, b OR FALSE FROM t ORDER BY b NULLS FIRST;
SELECT 'maybe'::boolean;
SELECT bool_and(b), bool_or(b), every(b) FROM t;

-- probe T054.greatest_least
SELECT GREATEST(1, 3, 2), LEAST(1, 3, 2), GREATEST('a', 'c', 'b'), LEAST(1, NULL, 2), GREATEST(NULL::int, NULL), GREATEST(1, 2.5), pg_typeof(GREATEST(1, 2.5));

-- probe T055.padding
SELECT lpad('ab', 5), lpad('ab', 5, 'xy'), rpad('ab', 5, '*'), lpad('abcdef', 3), rpad('', 2, 'z'), lpad('ab', 0);

-- probe T056.multichar_trim
SELECT TRIM(BOTH 'xy' FROM 'xyxabcyx'), TRIM(LEADING 'ab' FROM 'abbaXab'), TRIM(TRAILING 'ab' FROM 'Xabba'), ltrim('zzyx', 'zy'), rtrim('xyzz', 'z'), btrim('  a  ');

-- probe T061.ucs
SELECT length('日本語'), octet_length('日本語'), upper('ß'), substring('héllo wörld' FROM 7 FOR 5), position('ö' IN 'wörld'), 'ä' < 'b', chr(8364), ascii('€'), reverse('añb');

-- probe T071.bigint
CREATE TABLE t(a BIGINT);
INSERT INTO t VALUES (9223372036854775807), (-9223372036854775808);
SELECT a, pg_typeof(a) FROM t ORDER BY a;
SELECT 9223372036854775807 + 1;
SELECT 3000000000 * 2, pg_typeof(3000000000), sum(a) FROM t;

-- probe T081.optional_length
CREATE TABLE t(a VARCHAR, b CHARACTER VARYING);
INSERT INTO t VALUES (repeat('x', 300), 'y');
SELECT length(a), b FROM t;
SELECT character_maximum_length FROM information_schema.columns WHERE table_name = 't' ORDER BY ordinal_position;

-- probe T121.with
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3);
WITH x AS (SELECT a FROM t WHERE a > 1), y(b) AS (SELECT a * 10 FROM x) SELECT a, b FROM x JOIN y ON y.b = x.a * 10 ORDER BY a;
WITH x AS MATERIALIZED (SELECT 1 AS v) SELECT v FROM x;
WITH d AS (DELETE FROM t WHERE a = 1 RETURNING a) SELECT a FROM d;

-- probe T122.with_subquery
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3);
SELECT (WITH m AS (SELECT max(a) AS v FROM t) SELECT v FROM m);
SELECT a FROM t WHERE a IN (WITH x AS (SELECT 2 AS v) SELECT v FROM x);
SELECT * FROM (WITH x AS (SELECT a FROM t) SELECT count(*) FROM x) s;

-- probe T131.recursive
-- ordered
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5) SELECT i FROM n;
CREATE TABLE e(id INT, parent INT);
INSERT INTO e VALUES (1, NULL), (2, 1), (3, 2), (4, 1);
WITH RECURSIVE tree AS (SELECT id, 0 AS depth FROM e WHERE parent IS NULL UNION ALL SELECT e.id, tree.depth + 1 FROM e JOIN tree ON e.parent = tree.id) SELECT id, depth FROM tree ORDER BY id;
WITH RECURSIVE f(i) AS (SELECT 1 UNION SELECT i FROM f) SELECT i FROM f;

-- probe T132.recursive_subquery
SELECT (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 4) SELECT sum(i) FROM n);
SELECT x FROM (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i * 2 FROM n WHERE i < 8) SELECT max(i) AS x FROM n) s;

-- probe T133.cycle_marks
CREATE TABLE g(a INT, b INT);
INSERT INTO g VALUES (1, 2), (2, 3), (3, 1);
WITH RECURSIVE w(a, b) AS (SELECT a, b FROM g WHERE a = 1 UNION ALL SELECT g.a, g.b FROM g JOIN w ON g.a = w.b) CYCLE a SET looped TO 'Y' DEFAULT 'N' USING path SELECT a, b, looped FROM w;
WITH RECURSIVE w(a, b) AS (SELECT a, b FROM g WHERE a = 1 UNION ALL SELECT g.a, g.b FROM g JOIN w ON g.a = w.b) CYCLE a SET looped USING path SELECT a, looped, path FROM w;
WITH RECURSIVE w(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM w WHERE a < 3) SEARCH DEPTH FIRST BY a SET ord SELECT a, ord FROM w ORDER BY ord;

-- probe T141.similar
SELECT 'abc' SIMILAR TO 'a%', 'abc' SIMILAR TO '(a|b)bc', 'abc' SIMILAR TO 'a_', 'aXc' NOT SIMILAR TO 'a[a-z]c', 'a%c' SIMILAR TO 'a#%c' ESCAPE '#', 'abab' SIMILAR TO '(ab)+', 'abc' SIMILAR TO 'b';

-- probe T151.distinct_predicate
SELECT 1 IS DISTINCT FROM 2, 1 IS DISTINCT FROM 1, NULL IS DISTINCT FROM NULL, 1 IS DISTINCT FROM NULL, ROW(1, NULL) IS DISTINCT FROM ROW(1, NULL);
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (NULL);
SELECT count(*) FROM t WHERE a IS DISTINCT FROM 1;

-- probe T152.not_distinct
SELECT 1 IS NOT DISTINCT FROM 1, NULL IS NOT DISTINCT FROM NULL, 1 IS NOT DISTINCT FROM NULL, 'a' IS NOT DISTINCT FROM 'a';
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (NULL);
SELECT count(*) FROM t WHERE a IS NOT DISTINCT FROM NULL;

-- probe T171.like_table
CREATE TABLE src(a INT NOT NULL, b TEXT DEFAULT 'x', c NUMERIC(5,2));
CREATE TABLE dst (LIKE src, d INT);
INSERT INTO dst(a, c) VALUES (1, 2.5);
SELECT a, b, c, d FROM dst;
INSERT INTO dst(b) VALUES ('y');
SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'dst' ORDER BY ordinal_position;

-- probe T172.create_table_as
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, 'x'), (2, 'y');
CREATE TABLE c AS SELECT a * 2 AS d, b FROM t WHERE a > 1;
SELECT d, b FROM c;
CREATE TABLE e(x, y) AS SELECT a, b FROM t WITH NO DATA;
SELECT count(*) FROM e;
CREATE TABLE f AS SELECT 1 AS one WITH DATA;
SELECT one FROM f;

-- probe T173.extended_like
CREATE TABLE src(a INT NOT NULL DEFAULT 7 CHECK (a > 0), b INT GENERATED ALWAYS AS (a * 2) STORED, c INT GENERATED BY DEFAULT AS IDENTITY);
CREATE TABLE d1 (LIKE src INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
CREATE TABLE d2 (LIKE src INCLUDING ALL);
INSERT INTO d1(c) VALUES (1);
INSERT INTO d1(a, c) VALUES (-1, 1);
SELECT a, b, c FROM d1;
INSERT INTO d2 DEFAULT VALUES;
SELECT a, b, c FROM d2;

-- probe T174.identity
CREATE TABLE t(id INT GENERATED ALWAYS AS IDENTITY, v TEXT);
CREATE TABLE u(id BIGINT GENERATED BY DEFAULT AS IDENTITY (START WITH 10 INCREMENT BY 5), v TEXT);
INSERT INTO t(v) VALUES ('a'), ('b');
INSERT INTO t(id, v) VALUES (5, 'c');
INSERT INTO t(id, v) OVERRIDING SYSTEM VALUE VALUES (5, 'c');
INSERT INTO u(v) VALUES ('x');
INSERT INTO u(id, v) VALUES (1, 'y');
INSERT INTO u(v) VALUES ('z');
SELECT id, v FROM t ORDER BY id;
SELECT id, v FROM u ORDER BY id;

-- probe T177.sequence_restart
CREATE SEQUENCE s START WITH 5;
SELECT nextval('s'), nextval('s');
ALTER SEQUENCE s RESTART;
SELECT nextval('s');
ALTER SEQUENCE s RESTART WITH 100;
SELECT nextval('s');

-- probe T178.identity_restart
CREATE TABLE t(id INT GENERATED ALWAYS AS IDENTITY, v INT);
INSERT INTO t(v) VALUES (1), (2);
ALTER TABLE t ALTER COLUMN id RESTART;
INSERT INTO t(v) VALUES (3);
ALTER TABLE t ALTER COLUMN id RESTART WITH 50;
INSERT INTO t(v) VALUES (4);
SELECT id, v FROM t ORDER BY v;

-- probe T191.restrict
CREATE TABLE p(id INT PRIMARY KEY);
CREATE TABLE c(pid INT REFERENCES p ON DELETE RESTRICT ON UPDATE RESTRICT);
INSERT INTO p VALUES (1), (2);
INSERT INTO c VALUES (1);
DELETE FROM p WHERE id = 1;
UPDATE p SET id = 9 WHERE id = 1;
DELETE FROM p WHERE id = 2;
SELECT id FROM p;
SELECT delete_rule, update_rule FROM information_schema.referential_constraints;

-- probe T201.comparable_fk_types
CREATE TABLE p(id BIGINT PRIMARY KEY, code VARCHAR(10) UNIQUE);
CREATE TABLE c(pid INT REFERENCES p, pcode TEXT REFERENCES p(code));
INSERT INTO p VALUES (1, 'a');
INSERT INTO c VALUES (1, 'a');
INSERT INTO c VALUES (2, 'a');
INSERT INTO c VALUES (1, 'b');
CREATE TABLE bad(pid DATE REFERENCES p);
SELECT count(*) FROM c;

-- probe T212.statement_triggers
CREATE TABLE t(a INT);
CREATE TABLE log(n INT);
CREATE FUNCTION count_rows() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN INSERT INTO log SELECT count(*) FROM newrows; RETURN NULL; END$$;
CREATE TRIGGER tr AFTER INSERT ON t REFERENCING NEW TABLE AS newrows FOR EACH STATEMENT EXECUTE FUNCTION count_rows();
INSERT INTO t VALUES (1), (2), (3);
INSERT INTO t SELECT 1 WHERE false;
SELECT n FROM log ORDER BY n;

-- probe T213.instead_of
CREATE TABLE t(a INT);
CREATE VIEW v AS SELECT a, a * 2 AS b FROM t;
CREATE FUNCTION v_ins() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN INSERT INTO t VALUES (NEW.a + 100); RETURN NEW; END$$;
CREATE TRIGGER tr INSTEAD OF INSERT ON v FOR EACH ROW EXECUTE FUNCTION v_ins();
INSERT INTO v(a) VALUES (1);
SELECT a, b FROM v;

-- probe T214.before
CREATE TABLE t(a INT, b TEXT);
CREATE FUNCTION fix() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN NEW.b := upper(NEW.b); IF NEW.a < 0 THEN RETURN NULL; END IF; RETURN NEW; END$$;
CREATE TRIGGER tr BEFORE INSERT OR UPDATE ON t FOR EACH ROW EXECUTE FUNCTION fix();
INSERT INTO t VALUES (1, 'x'), (-1, 'y');
UPDATE t SET b = 'z';
SELECT a, b FROM t;

-- probe T215.after
CREATE TABLE t(a INT);
CREATE TABLE audit(op TEXT, v INT);
CREATE FUNCTION aud() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN IF TG_OP = 'DELETE' THEN INSERT INTO audit VALUES (TG_OP, OLD.a); ELSE INSERT INTO audit VALUES (TG_OP, NEW.a); END IF; RETURN NULL; END$$;
CREATE TRIGGER tr AFTER INSERT OR UPDATE OR DELETE ON t FOR EACH ROW EXECUTE FUNCTION aud();
INSERT INTO t VALUES (1);
UPDATE t SET a = 2;
DELETE FROM t;
SELECT op, v FROM audit ORDER BY op;

-- probe T216.when
CREATE TABLE t(a INT);
CREATE TABLE log(v INT);
CREATE FUNCTION lg() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (NEW.a); RETURN NEW; END$$;
CREATE TRIGGER tr AFTER INSERT ON t FOR EACH ROW WHEN (NEW.a > 10) EXECUTE FUNCTION lg();
CREATE TRIGGER tu AFTER UPDATE ON t FOR EACH ROW WHEN (OLD.a IS DISTINCT FROM NEW.a) EXECUTE FUNCTION lg();
INSERT INTO t VALUES (5), (15);
UPDATE t SET a = a;
UPDATE t SET a = 7 WHERE a = 5;
SELECT v FROM log ORDER BY v;

-- probe T217.trigger_privilege
CREATE ROLE w4f_r;
GRANT CREATE ON SCHEMA public TO w4f_r;
CREATE TABLE t(a INT);
CREATE FUNCTION nothing() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$;
SET ROLE w4f_r;
CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION nothing();
RESET ROLE;
GRANT TRIGGER ON t TO w4f_r;
SET ROLE w4f_r;
CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION nothing();
RESET ROLE;

-- probe T241.start_transaction
CREATE TABLE t(a INT);
START TRANSACTION;
INSERT INTO t VALUES (1);
COMMIT;
START TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ ONLY;
SHOW transaction_isolation;
SHOW transaction_read_only;
COMMIT;
START TRANSACTION READ WRITE;
SELECT a FROM t;
ROLLBACK;

-- probe T261.chained
CREATE TABLE t(a INT);
BEGIN ISOLATION LEVEL REPEATABLE READ;
INSERT INTO t VALUES (1);
COMMIT AND CHAIN;
SHOW transaction_isolation;
INSERT INTO t VALUES (2);
ROLLBACK AND CHAIN;
SHOW transaction_isolation;
COMMIT AND NO CHAIN;
SELECT a FROM t;
COMMIT AND CHAIN;

-- probe T271.savepoints
CREATE TABLE t(a INT);
BEGIN;
INSERT INTO t VALUES (1);
SAVEPOINT s1;
INSERT INTO t VALUES (2);
SAVEPOINT s2;
INSERT INTO t VALUES (3);
ROLLBACK TO SAVEPOINT s1;
INSERT INTO t VALUES (4);
RELEASE SAVEPOINT s1;
ROLLBACK TO s2;
ROLLBACK;
BEGIN;
INSERT INTO t VALUES (1);
SAVEPOINT a;
SELECT 1/0;
ROLLBACK TO a;
INSERT INTO t VALUES (4);
COMMIT;
SELECT a FROM t ORDER BY a;
SAVEPOINT outside;

-- probe T281.column_select_privilege
CREATE ROLE w4f_r;
CREATE TABLE t(a INT, secret INT);
INSERT INTO t VALUES (1, 99);
GRANT SELECT (a) ON t TO w4f_r;
SET ROLE w4f_r;
SELECT a FROM t;
SELECT secret FROM t;
SELECT * FROM t;
SELECT count(*) FROM t;
RESET ROLE;

-- probe T285.derived_column_names
SELECT * FROM (SELECT count(*), max(1), 1 + 1, 'x'::text, CAST(1 AS INT), coalesce(1, 2), CASE WHEN true THEN 1 END) s;
CREATE TABLE t(a INT);
SELECT * FROM (SELECT a, a AS b, t.a FROM t) s;

-- probe T312.overlay
SELECT OVERLAY('abcdef' PLACING 'XY' FROM 3), OVERLAY('abcdef' PLACING 'XY' FROM 3 FOR 0), OVERLAY('abcdef' PLACING '' FROM 2 FOR 3), OVERLAY('abc' PLACING 'XYZW' FROM 2 FOR 1);

-- probe T321-01.user_functions
CREATE FUNCTION sq(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x * x';
CREATE FUNCTION greet(n TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN RETURN 'hi ' || n; END$$;
SELECT sq(7), greet('bob');
SELECT sq(NULL);
CREATE FUNCTION sq(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x';
DROP FUNCTION sq(INT);
SELECT sq(2);

-- probe T321-02.procedures
CREATE TABLE t(a INT);
CREATE PROCEDURE ins(v INT) LANGUAGE SQL AS $$INSERT INTO t VALUES (v)$$;
CREATE PROCEDURE ins2(v INT) LANGUAGE plpgsql AS $$BEGIN INSERT INTO t VALUES (v * 2); END$$;
CALL ins(1);
CALL ins2(2);
SELECT a FROM t ORDER BY a;
SELECT ins(1);
DROP PROCEDURE ins(INT);

-- probe T321-03.invocation
CREATE FUNCTION add(a INT, b INT) RETURNS INT LANGUAGE SQL AS 'SELECT a + b';
CREATE TABLE t(x INT);
INSERT INTO t VALUES (1), (2);
SELECT add(x, 10) FROM t ORDER BY 1;
SELECT x FROM t WHERE add(x, x) = 4;
SELECT add(add(1, 2), 3);
SELECT add(1);

-- probe T321-04.call
CREATE TABLE t(a INT);
CREATE PROCEDURE p(x INT, INOUT y INT) LANGUAGE plpgsql AS $$BEGIN INSERT INTO t VALUES (x); y := x * 10; END$$;
CALL p(3, NULL);
CALL p(4, 0);
SELECT a FROM t ORDER BY a;
CALL missing_proc();

-- probe T321-05.return
CREATE FUNCTION sgn(x INT) RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN IF x < 0 THEN RETURN 'neg'; END IF; RETURN 'nonneg'; END$$;
CREATE FUNCTION r(x INT) RETURNS INT LANGUAGE SQL RETURN x * 3;
CREATE PROCEDURE early(INOUT x INT) LANGUAGE plpgsql AS $$BEGIN x := 1; RETURN; x := 2; END$$;
SELECT sgn(-1), sgn(1), r(2);
CALL early(0);

-- probe T321-06.routines_view
CREATE FUNCTION f1(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x';
CREATE PROCEDURE p1() LANGUAGE SQL AS 'SELECT 1';
SELECT routine_name, routine_type, data_type, external_language FROM information_schema.routines WHERE routine_schema = 'public' ORDER BY routine_name;

-- probe T321-07.parameters_view
CREATE FUNCTION f1(a INT, INOUT b TEXT, OUT c DATE) LANGUAGE SQL AS $$SELECT b, CURRENT_DATE$$;
SELECT ordinal_position, parameter_mode, parameter_name, data_type FROM information_schema.parameters WHERE specific_schema = 'public' ORDER BY ordinal_position;

-- probe T323.external_security
CREATE ROLE w4f_r;
CREATE TABLE secret(v INT);
INSERT INTO secret VALUES (42);
CREATE FUNCTION peek() RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS $$BEGIN RETURN (SELECT v FROM secret); END$$;
CREATE FUNCTION peek2() RETURNS INT LANGUAGE plpgsql SECURITY INVOKER AS $$BEGIN RETURN (SELECT v FROM secret); END$$;
SET ROLE w4f_r;
SELECT peek();
SELECT peek2();
RESET ROLE;
SELECT routine_name, security_type FROM information_schema.routines WHERE routine_name LIKE 'peek%' ORDER BY 1;

-- probe T325.qualified_params
CREATE TABLE t(x INT);
INSERT INTO t VALUES (1), (2);
CREATE FUNCTION f(x INT) RETURNS BIGINT LANGUAGE SQL AS $$SELECT count(*) FROM t WHERE t.x = f.x$$;
CREATE FUNCTION g(x INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN g.x + 1; END$$;
SELECT f(2), g(5);

-- probe T331.roles
CREATE ROLE w4f_reader;
CREATE ROLE w4f_u;
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
GRANT SELECT ON t TO w4f_reader;
GRANT w4f_reader TO w4f_u;
SET ROLE w4f_u;
SELECT a FROM t;
SET ROLE w4f_reader;
SELECT current_user;
RESET ROLE;
REVOKE w4f_reader FROM w4f_u;
SET ROLE w4f_u;
SELECT a FROM t;
RESET ROLE;
DROP ROLE w4f_reader;
SELECT rolname FROM pg_roles WHERE rolname LIKE 'w4f%' ORDER BY 1;

-- probe T332.extended_roles
CREATE ROLE w4f_a;
CREATE ROLE w4f_b;
CREATE ROLE w4f_c;
CREATE TABLE t(a INT);
GRANT SELECT ON t TO w4f_a;
GRANT w4f_a TO w4f_b WITH ADMIN OPTION;
SELECT CURRENT_ROLE = current_user;
SET ROLE w4f_b;
SELECT CURRENT_ROLE;
GRANT w4f_a TO w4f_c;
RESET ROLE;
SET ROLE w4f_c;
SELECT count(*) FROM t;
RESET ROLE;
REVOKE w4f_a FROM w4f_c;
SET ROLE w4f_c;
SELECT count(*) FROM t;
RESET ROLE;

-- probe T341.overloading
CREATE FUNCTION f(x INT) RETURNS TEXT LANGUAGE SQL AS $$SELECT 'int'$$;
CREATE FUNCTION f(x TEXT) RETURNS TEXT LANGUAGE SQL AS $$SELECT 'text'$$;
CREATE FUNCTION f(x INT, y INT) RETURNS TEXT LANGUAGE SQL AS $$SELECT 'two'$$;
CREATE PROCEDURE p(x INT) LANGUAGE SQL AS $$SELECT 1$$;
CREATE PROCEDURE p(x TEXT) LANGUAGE SQL AS $$SELECT 2$$;
SELECT f(1), f('a'::text), f(1, 2);
CALL p(1);
CALL p('a'::text);
DROP FUNCTION f(TEXT);
SELECT f('1');

-- probe T351.bracketed_comments
SELECT /* comment */ 1 /* another /* nested */ comment */ + 2 AS x;
SELECT 3 /* multi
line */ AS y;

-- probe T431.grouping
CREATE TABLE t(a TEXT, b TEXT, v INT);
INSERT INTO t VALUES ('x', 'p', 1), ('x', 'q', 2), ('y', 'p', 3);
SELECT a, b, sum(v), GROUPING(a) FROM t GROUP BY ROLLUP (a, b);
SELECT a, b, sum(v) FROM t GROUP BY CUBE (a, b);
SELECT a, b, sum(v) FROM t GROUP BY GROUPING SETS ((a), (b), ());

-- probe T432.nested_grouping_sets
CREATE TABLE t(a TEXT, b TEXT, c TEXT, v INT);
INSERT INTO t VALUES ('x', 'p', 'm', 1), ('x', 'q', 'm', 2), ('y', 'p', 'n', 3);
SELECT a, b, c, sum(v) FROM t GROUP BY a, GROUPING SETS ((b), (c));
SELECT a, b, sum(v) FROM t GROUP BY GROUPING SETS (ROLLUP (a, b), (b));
SELECT a, c, count(*) FROM t GROUP BY ROLLUP (a), CUBE (c);

-- probe T433.multi_arg_grouping
CREATE TABLE t(a TEXT, b TEXT, v INT);
INSERT INTO t VALUES ('x', 'p', 1), ('y', 'q', 2);
SELECT a, b, GROUPING(a, b), GROUPING(b, a), sum(v) FROM t GROUP BY CUBE (a, b);

-- probe T434.group_by_distinct
CREATE TABLE t(a TEXT, b TEXT, v INT);
INSERT INTO t VALUES ('x', 'p', 1), ('y', 'q', 2);
SELECT a, b, sum(v) FROM t GROUP BY DISTINCT ROLLUP (a, b), ROLLUP (a);
SELECT count(*) FROM (SELECT a, b FROM t GROUP BY ALL ROLLUP (a, b), ROLLUP (a)) s;

-- probe T441.abs_mod
SELECT ABS(-5), ABS(3.5), ABS(-2::smallint), MOD(10, 3), MOD(-10, 3), MOD(10.5, 3), MOD(7, -2), pg_typeof(ABS(-2::bigint));
SELECT MOD(1, 0);

-- probe T461.symmetric_between
SELECT 2 BETWEEN SYMMETRIC 3 AND 1, 2 BETWEEN ASYMMETRIC 3 AND 1, 5 NOT BETWEEN SYMMETRIC 1 AND 3, 'b' BETWEEN SYMMETRIC 'c' AND 'a';

-- probe T491.lateral
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3);
SELECT t.a, l.x FROM t, LATERAL (SELECT t.a * 10 AS x) l;
SELECT t.a, l.n FROM t CROSS JOIN LATERAL (SELECT count(*) AS n FROM t u WHERE u.a <= t.a) l;
SELECT t.a, l.v FROM t LEFT JOIN LATERAL (SELECT a AS v FROM t u WHERE u.a > t.a ORDER BY u.a LIMIT 1) l ON true;
SELECT t.a, s FROM t, LATERAL generate_series(1, t.a) s WHERE t.a = 2;

-- probe T501.enhanced_exists
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 2);
SELECT EXISTS (SELECT a, b FROM t), EXISTS (SELECT 1 UNION SELECT 2), EXISTS (SELECT * FROM t WHERE a = 5 UNION ALL SELECT * FROM t WHERE b = 2);
SELECT EXISTS (VALUES (1)), EXISTS (TABLE t);

-- probe T521.named_call_args
CREATE TABLE t(a INT, b TEXT);
CREATE PROCEDURE ins(x INT, y TEXT) LANGUAGE SQL AS $$INSERT INTO t VALUES (x, y)$$;
CALL ins(y => 'b', x => 1);
CALL ins(2, y => 'c');
CALL ins(x => 3, 'd');
SELECT a, b FROM t ORDER BY a;

-- probe T523.inout_defaults
CREATE PROCEDURE p(INOUT a INT DEFAULT 5, INOUT b INT DEFAULT 6) LANGUAGE plpgsql AS $$BEGIN a := a + 1; b := b + 1; END$$;
CALL p();
CALL p(10);
CALL p(b => 0);

-- probe T524.named_function_args
CREATE FUNCTION f(a INT, b TEXT) RETURNS TEXT LANGUAGE SQL AS $$SELECT b || a$$;
SELECT f(b => 'x', a => 1), f(2, b => 'y'), f(a := 3, b := 'z');
SELECT f(c => 1);

-- probe T525.function_defaults
CREATE FUNCTION f(a INT, b INT DEFAULT 10, c TEXT DEFAULT 'd') RETURNS TEXT LANGUAGE SQL AS $$SELECT a + b || c$$;
SELECT f(1), f(1, 2), f(1, 2, 'x'), f(1, c => 'y');

-- probe T551.optional_keywords
-- ordered
CREATE TABLE t(a INT, b TIMESTAMP WITHOUT TIME ZONE);
INSERT INTO t VALUES (2, TIMESTAMP '2024-01-01'), (1, NULL);
SELECT a FROM t UNION DISTINCT SELECT a FROM t ORDER BY a ASC;
SELECT a FROM t ORDER BY b ASC NULLS LAST;
SELECT ALL a FROM t ORDER BY a DESC;
SELECT a FROM t AS x LEFT OUTER JOIN (SELECT 1 AS k) AS y ON x.a = y.k ORDER BY a;
SELECT CAST(1 AS INTEGER), CAST('x' AS CHARACTER VARYING(3)), 2::DOUBLE PRECISION;

-- probe T581.regex_substring
SELECT SUBSTRING('foobar' SIMILAR '%#"o_b#"%' ESCAPE '#'), SUBSTRING('foobar' FROM '%#"o_b#"%' FOR '#'), SUBSTRING('foobar' SIMILAR 'x#"y#"z' ESCAPE '#'), SUBSTRING('abc123' FROM '[0-9]+');

-- probe T591.unique_nullable
CREATE TABLE t(a INT UNIQUE, b INT, c INT, UNIQUE (b, c));
INSERT INTO t VALUES (NULL, 1, NULL), (NULL, 1, NULL);
INSERT INTO t VALUES (1, 2, 2);
INSERT INTO t VALUES (1, 3, 3);
INSERT INTO t VALUES (2, 2, 2);
SELECT count(*) FROM t;

-- probe T611.elementary_olap
CREATE TABLE t(g TEXT, v INT);
INSERT INTO t VALUES ('a', 10), ('a', 20), ('a', 20), ('b', 5);
SELECT g, v, row_number() OVER (PARTITION BY g ORDER BY v), rank() OVER (PARTITION BY g ORDER BY v), dense_rank() OVER (ORDER BY v DESC) FROM t;
SELECT g, v, sum(v) OVER (PARTITION BY g), count(*) OVER (), avg(v) OVER (ORDER BY v ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t;

-- probe T612.advanced_olap
CREATE TABLE t(g TEXT, v INT);
INSERT INTO t VALUES ('a', 10), ('a', 20), ('a', 30), ('b', 5);
SELECT g, v, percent_rank() OVER w, cume_dist() OVER w FROM t WINDOW w AS (PARTITION BY g ORDER BY v);
SELECT v, sum(v) OVER (ORDER BY v RANGE BETWEEN 10 PRECEDING AND CURRENT ROW), max(v) OVER (ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) FROM t;
SELECT v, count(*) FILTER (WHERE v > 10) OVER (ORDER BY v) FROM t;

-- probe T613.sampling
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3);
SELECT a FROM t TABLESAMPLE BERNOULLI (100);
SELECT count(*) FROM t TABLESAMPLE SYSTEM (0);
SELECT count(*) FROM t TABLESAMPLE BERNOULLI (100) REPEATABLE (42);

-- probe T614.ntile
CREATE TABLE t(v INT);
INSERT INTO t VALUES (1), (2), (3), (4), (5);
SELECT v, ntile(2) OVER (ORDER BY v), ntile(3) OVER (ORDER BY v DESC) FROM t;
SELECT ntile(0) OVER () FROM t;

-- probe T615.lead_lag
CREATE TABLE t(v INT);
INSERT INTO t VALUES (1), (2), (4);
SELECT v, lag(v) OVER (ORDER BY v), lead(v) OVER (ORDER BY v), lag(v, 2, -1) OVER (ORDER BY v), lead(v, 1, 0) OVER (ORDER BY v DESC) FROM t;

-- probe T617.first_last_value
CREATE TABLE t(g TEXT, v INT);
INSERT INTO t VALUES ('a', 1), ('a', 2), ('a', 3), ('b', 9);
SELECT g, v, first_value(v) OVER w, last_value(v) OVER w, last_value(v) OVER (PARTITION BY g ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM t WINDOW w AS (PARTITION BY g ORDER BY v);

-- probe T620.groups_frame
CREATE TABLE t(v INT);
INSERT INTO t VALUES (1), (1), (2), (3), (3);
SELECT v, sum(v) OVER (ORDER BY v GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW), count(*) OVER (ORDER BY v GROUPS BETWEEN CURRENT ROW AND 1 FOLLOWING EXCLUDE GROUP) FROM t;

-- probe T621.numeric_functions
SELECT ln(1), exp(0), power(2, 10), power(2.0, 0.5), sqrt(16), floor(-1.5), ceiling(1.2), ceil(-1.2), width_bucket(5.5, 0, 10, 4), round(2.567, 2), trunc(-2.7);
SELECT sqrt(-1);
SELECT ln(0);

-- probe T622.trig
SELECT round(sin(0)::numeric, 6), round(cos(0)::numeric, 6), round(tan(pi() / 4)::numeric, 6), round(asin(1)::numeric, 6), round(acos(1)::numeric, 6), round(atan(1)::numeric, 6), round(sinh(0)::numeric, 6), round(cosh(0)::numeric, 6), round(tanh(0)::numeric, 6), round(atan2(1, 1)::numeric, 6), round(sind(30)::numeric, 6);

-- probe T623.general_log
SELECT log(2.0, 8.0), log(10, 1000), round(log(2, 10)::numeric, 6);
SELECT log(1, 10);

-- probe T624.common_log
SELECT log10(1000), log(100), log10(0.01), pg_typeof(log10(10));

-- probe T626.any_value
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 5), (1, 5), (2, 7);
SELECT g, any_value(v) FROM t GROUP BY g;
SELECT any_value(v) FROM t WHERE false;

-- probe T627.window_count_distinct
CREATE TABLE t(v INT);
INSERT INTO t VALUES (1), (1), (2);
SELECT v, count(DISTINCT v) OVER () FROM t;

-- probe T631.in_one_element
SELECT 1 IN (1), 2 IN (1), NULL IN (1), 'a' NOT IN ('b');
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
SELECT a FROM t WHERE a IN (2);

-- probe T651.schema_statements_sql_routines
CREATE FUNCTION mk() RETURNS VOID LANGUAGE SQL AS $$CREATE TABLE made(a INT)$$;
SELECT mk();
INSERT INTO made VALUES (1);
SELECT a FROM made;
CREATE PROCEDURE drop_it() LANGUAGE SQL AS $$DROP TABLE made$$;
CALL drop_it();
SELECT count(*) FROM information_schema.tables WHERE table_name = 'made';

-- probe T653.schema_statements_external
CREATE FUNCTION mk(n TEXT) RETURNS VOID LANGUAGE plpgsql AS $$BEGIN EXECUTE 'CREATE TABLE ' || quote_ident(n) || '(a INT)'; CREATE TABLE fixed(b INT); END$$;
SELECT mk('dyn');
SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY 1;

-- probe T655.cyclic_routines
CREATE FUNCTION is_even(n INT) RETURNS BOOLEAN LANGUAGE plpgsql AS $$BEGIN IF n = 0 THEN RETURN true; END IF; RETURN is_odd(n - 1); END$$;
CREATE FUNCTION is_odd(n INT) RETURNS BOOLEAN LANGUAGE plpgsql AS $$BEGIN IF n = 0 THEN RETURN false; END IF; RETURN is_even(n - 1); END$$;
SELECT is_even(4), is_odd(4), is_even(7);

-- probe T661.non_decimal_literals
SELECT 0x1F, 0o17, 0b101, 0XFF, -0x10, pg_typeof(0x7FFFFFFF), pg_typeof(0x80000000);

-- probe T662.underscores
SELECT 1_000_000, 0x_FF, 1_000.000_1, 1_2e1_0;
SELECT 1__0;

-- probe T670.mixed_statements
BEGIN;
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
ALTER TABLE t ADD COLUMN b INT DEFAULT 2;
UPDATE t SET b = b + a;
SELECT a, b FROM t;
ROLLBACK;
SELECT count(*) FROM information_schema.tables WHERE table_name = 't';

-- probe T803.json_type
SELECT '{"a": 1, "b": [true, null]}'::json;
SELECT '[1, 2'::json;
SELECT '{"a":1,"a":2}'::json, ('{"x": 1}'::json -> 'x')::text, '{"a": {"b": 2}}'::json #>> '{a,b}';
CREATE TABLE t(j JSON);
INSERT INTO t VALUES ('{"k": "v"}');
SELECT j ->> 'k' FROM t;

-- probe T811.json_constructors
SELECT JSON_OBJECT('a' VALUE 1, 'b' VALUE 'x'), JSON_ARRAY(1, 'two', NULL), JSON_ARRAY(1, NULL NULL ON NULL), JSON_OBJECT('a' VALUE NULL ABSENT ON NULL), JSON_OBJECT(), JSON_ARRAY();
SELECT JSON_OBJECT('a' VALUE 1 RETURNING jsonb), pg_typeof(JSON_ARRAY(1 RETURNING jsonb));

-- probe T812.json_objectagg
CREATE TABLE t(k TEXT, v INT);
INSERT INTO t VALUES ('a', 1), ('b', NULL);
SELECT JSON_OBJECTAGG(k VALUE v), JSON_OBJECTAGG(k VALUE v ABSENT ON NULL), JSON_OBJECTAGG(k VALUE v RETURNING jsonb) FROM t;

-- probe T813.json_arrayagg_order
CREATE TABLE t(v INT);
INSERT INTO t VALUES (3), (1), (NULL), (2);
SELECT JSON_ARRAYAGG(v ORDER BY v), JSON_ARRAYAGG(v ORDER BY v DESC NULL ON NULL), JSON_ARRAYAGG(v ORDER BY v RETURNING jsonb) FROM t;

-- probe T814.json_colon
CREATE TABLE t(k TEXT, v INT);
INSERT INTO t VALUES ('x', 1);
SELECT JSON_OBJECT('a' : 1, 'b' : 'c'), JSON_OBJECTAGG(k : v) FROM t;

-- probe T821.json_query_operators
SELECT JSON_EXISTS(jsonb '{"a": [1, 2]}', '$.a[1]'), JSON_EXISTS(jsonb '{"a": 1}', '$.b'), JSON_VALUE(jsonb '{"a": {"b": "x"}}', '$.a.b'), JSON_VALUE(jsonb '{"a": 5}', '$.a' RETURNING INT) + 1, JSON_QUERY(jsonb '{"a": [1, 2]}', '$.a');
SELECT * FROM JSON_TABLE(jsonb '[{"id": 1, "n": "x"}, {"id": 2}]', '$[*]' COLUMNS (id INT PATH '$.id', n TEXT PATH '$.n')) jt;

-- probe T822.is_json_unique
SELECT '{"a":1,"a":2}' IS JSON, '{"a":1,"a":2}' IS JSON WITH UNIQUE KEYS, '{"a":1,"b":2}' IS JSON WITH UNIQUE KEYS, '[1]' IS JSON OBJECT, '[1]' IS JSON ARRAY, '1' IS JSON SCALAR, 'x' IS JSON, '{"a":1}' IS JSON WITHOUT UNIQUE KEYS;

-- probe T823.passing
SELECT JSON_EXISTS(jsonb '{"a": 5}', '$.a ? (@ > $min)' PASSING 3 AS min), JSON_VALUE(jsonb '[10, 20]', '$[$i]' PASSING 1 AS i), JSON_QUERY(jsonb '{"k": [1]}', '$.k' PASSING 'x' AS unused);

-- probe T825.on_empty_on_error
SELECT JSON_VALUE(jsonb '{"a": 1}', '$.b' NULL ON EMPTY), JSON_VALUE(jsonb '{"a": "x"}', '$.a' RETURNING INT NULL ON ERROR), JSON_QUERY(jsonb '{}', '$.a' EMPTY ARRAY ON EMPTY), JSON_EXISTS(jsonb '{}', 'strict $.a' FALSE ON ERROR);
SELECT JSON_VALUE(jsonb '{"a": "x"}', '$.a' RETURNING INT ERROR ON ERROR);
SELECT JSON_VALUE(jsonb '{}', 'strict $.a' ERROR ON ERROR);

-- probe T826.on_error_expressions
SELECT JSON_VALUE(jsonb '{}', '$.a' DEFAULT 'none' ON EMPTY), JSON_VALUE(jsonb '{"a": "x"}', '$.a' RETURNING INT DEFAULT -1 ON ERROR), JSON_VALUE(jsonb '{}', '$.a' RETURNING INT DEFAULT 2 + 3 ON EMPTY);

-- probe T827.json_table_nested
SELECT * FROM JSON_TABLE(jsonb '{"a": [1, 2], "b": ["x"]}', '$' COLUMNS (NESTED PATH '$.a[*]' COLUMNS (a INT PATH '$'), NESTED PATH '$.b[*]' COLUMNS (b TEXT PATH '$'))) jt;

-- probe T828.json_query
SELECT JSON_QUERY(jsonb '{"a": {"b": [1, 2]}}', '$.a'), JSON_QUERY(jsonb '[1, 2]', '$[0]'), JSON_QUERY(jsonb '{"a": "s"}', '$.a' OMIT QUOTES), JSON_QUERY(jsonb '{"a": "s"}', '$.a' KEEP QUOTES), JSON_QUERY(jsonb '{"a": [1]}', '$.a' RETURNING TEXT);

-- probe T829.array_wrapper
SELECT JSON_QUERY(jsonb '[1, 2, 3]', '$[*]' WITH WRAPPER), JSON_QUERY(jsonb '[1]', '$[0]' WITH CONDITIONAL WRAPPER), JSON_QUERY(jsonb '[[1]]', '$[0]' WITH CONDITIONAL WRAPPER), JSON_QUERY(jsonb '[1, 2]', '$[*]' WITHOUT WRAPPER NULL ON ERROR), JSON_QUERY(jsonb '[1]', '$[0]' WITH UNCONDITIONAL ARRAY WRAPPER);
SELECT JSON_QUERY(jsonb '[1, 2]', '$[*]' WITHOUT WRAPPER ERROR ON ERROR);

-- probe T830.constructor_unique_keys
SELECT JSON_OBJECT('a' VALUE 1, 'a' VALUE 2);
SELECT JSON_OBJECT('a' VALUE 1, 'a' VALUE 2 WITH UNIQUE KEYS);
SELECT JSON_OBJECT('a' VALUE 1, 'b' VALUE 2 WITH UNIQUE);
SELECT JSON_OBJECTAGG(k VALUE 1 WITH UNIQUE KEYS) FROM (VALUES ('x'), ('x')) v(k);

-- probe T831.strict_mode
SELECT jsonb_path_query_array('{"a": [1, 2]}', 'lax $.a.b'), jsonb_path_exists('{"a": 1}', 'lax $.b'), jsonb_path_query_array('[1, [2, 3]]', 'lax $[*][*]');
SELECT jsonb_path_query_first('{"a": 1}', 'strict $.b');
SELECT jsonb_path_query_array('{"a": 1}', 'strict $.b', '{}', true), jsonb_path_exists('{"a": [1]}', 'strict $.a.size()');

-- probe T832.item_methods
SELECT jsonb_path_query_first('[1, 2, 3]', '$.size()'), jsonb_path_query_first('"x"', '$.type()'), jsonb_path_query_first('"1.5"', '$.double()'), jsonb_path_query_first('-2.5', '$.abs()'), jsonb_path_query_first('2.4', '$.ceiling()'), jsonb_path_query_first('2.6', '$.floor()'), jsonb_path_query_array('{"a": 1}', '$.keyvalue()');

-- probe T833.multiple_subscripts
SELECT jsonb_path_query_array('[0, 1, 2, 3, 4]', '$[0, 2 to 3]'), jsonb_path_query_array('[0, 1, 2]', '$[last]'), jsonb_path_query_array('[0, 1, 2]', '$[1 to last]');

-- probe T834.wildcard_member
SELECT jsonb_path_query_array('{"a": 1, "b": {"c": 2}}', '$.*'), jsonb_path_query_array('{"a": {"x": 1}, "b": {"x": 2}}', '$.*.x'), jsonb_path_query_array('{"a": [1, {"b": 2}]}', '$.**.b');

-- probe T835.filter_expressions
SELECT jsonb_path_query_array('[1, 5, 10]', '$[*] ? (@ > 3)'), jsonb_path_query_array('[{"a": 1}, {"a": 2}]', '$[*] ? (@.a == 2 || @.a < 0)'), jsonb_path_query_array('[1, null, "x"]', '$[*] ? (@ != null && exists(@))'), jsonb_path_query_array('[1, 2]', '$[*] ? (!(@ == 1))');

-- probe T836.starts_with
SELECT jsonb_path_query_array('["apple", "banana", "avocado"]', '$[*] ? (@ starts with "a")'), jsonb_path_exists('"hello"', '$ ? (@ starts with "he")');

-- probe T837.like_regex
SELECT jsonb_path_query_array('["abc", "ABD", "xyz"]', '$[*] ? (@ like_regex "^ab")'), jsonb_path_query_array('["abc", "ABD"]', '$[*] ? (@ like_regex "^ab" flag "i")');

-- probe T840.path_hex_literals
SELECT jsonb_path_query_first('16', '$ ? (@ == 0x10)'), jsonb_path_query_first('{"a": 9}', '$.a ? (@ == 0o11)'), jsonb_path_query_first('[5]', '$[0] ? (@ == 0b101)'), jsonb_path_query_first('1000', '$ ? (@ == 1_000)');

-- probe T851.json_optional_keywords
SELECT JSON_OBJECT('a' VALUE 1 NULL ON NULL), JSON_OBJECT('a' VALUE 2 ABSENT ON NULL), JSON_ARRAY('[1]' FORMAT JSON), JSON_QUERY(jsonb '{"a": 1}', '$.a' WITHOUT ARRAY WRAPPER), JSON_EXISTS(jsonb '{}', '$.a' FALSE ON ERROR), JSON_VALUE(jsonb '{"a": "x"}', '$.a' RETURNING TEXT NULL ON EMPTY NULL ON ERROR);

-- probe T865.bigint_method
SELECT jsonb_path_query_first('"12345678901"', '$.bigint()'), jsonb_path_query_first('1.9', '$.bigint()');
SELECT jsonb_path_query_first('"x"', '$.bigint()');

-- probe T866.boolean_method
SELECT jsonb_path_query_first('"true"', '$.boolean()'), jsonb_path_query_first('0', '$.boolean()'), jsonb_path_query_first('"no"', '$.boolean()');

-- probe T867.date_method
SELECT jsonb_path_query_first('"2024-02-29"', '$.date()'), jsonb_path_query_first('"2024-02-29"', '$.date().type()');
SELECT jsonb_path_query_first('"not a date"', '$.date()');

-- probe T868.decimal_method
SELECT jsonb_path_query_first('"1.25"', '$.decimal()'), jsonb_path_query_first('3', '$.decimal().type()');

-- probe T869.decimal_precision
SELECT jsonb_path_query_first('1234.5678', '$.decimal(6, 2)'), jsonb_path_query_first('"12.345"', '$.decimal(4, 1)');
SELECT jsonb_path_query_first('12345.6', '$.decimal(4, 1)');

-- probe T870.integer_method
SELECT jsonb_path_query_first('"42"', '$.integer()'), jsonb_path_query_first('2.5', '$.integer()');
SELECT jsonb_path_query_first('"12345678901"', '$.integer()');

-- probe T871.number_method
SELECT jsonb_path_query_first('"1.5e2"', '$.number()'), jsonb_path_query_first('7', '$.number().type()');

-- probe T872.string_method
SELECT jsonb_path_query_first('12.5', '$.string()'), jsonb_path_query_first('true', '$.string()'), jsonb_path_query_first('"x"', '$.string().type()');

-- probe T873.time_method
SELECT jsonb_path_query_first('"10:20:30"', '$.time()'), jsonb_path_query_first('"10:20:30"', '$.time().type()');

-- probe T874.time_tz_method
SELECT jsonb_path_query_first('"10:20:30+02"', '$.time_tz()'), jsonb_path_query_first('"10:20:30+02"', '$.time_tz().type()');

-- probe T875.time_precision
SELECT jsonb_path_query_first('"10:20:30.123456"', '$.time(2)'), jsonb_path_query_first('"10:20:30.5+01"', '$.time_tz(0)');

-- probe T876.timestamp_method
SELECT jsonb_path_query_first('"2024-01-02 03:04:05"', '$.timestamp()'), jsonb_path_query_first('"2024-01-02T03:04:05"', '$.timestamp().type()');

-- probe T877.timestamp_tz_method
SELECT jsonb_path_query_first('"2024-01-02 03:04:05+00"', '$.timestamp_tz()'), jsonb_path_query_first('"2024-01-02 03:04:05-05"', '$.timestamp_tz().type()');

-- probe T878.timestamp_precision
SELECT jsonb_path_query_first('"2024-01-02 03:04:05.6789"', '$.timestamp(1)'), jsonb_path_query_first('"2024-01-02 03:04:05.6789+00"', '$.timestamp_tz(3)');

-- probe T879.json_equality
SELECT '{"a": 1, "b": 2}'::jsonb = '{"b": 2, "a": 1}'::jsonb, '[1, 2]'::jsonb = '[2, 1]'::jsonb, '1.0'::jsonb = '1'::jsonb, '{"a": 1}'::jsonb <> '{"a": "1"}'::jsonb;
CREATE TABLE t(j JSONB);
INSERT INTO t VALUES ('{"x": 1}'), ('{"x": 2}');
SELECT j FROM t WHERE j = '{"x": 2}';

-- probe T880.json_grouping
CREATE TABLE t(j JSONB, v INT);
INSERT INTO t VALUES ('{"a": 1, "b": 2}', 1), ('{"b": 2, "a": 1}', 2), ('[1]', 3);
SELECT j, sum(v) FROM t GROUP BY j;
SELECT DISTINCT j FROM t;
SELECT count(DISTINCT j) FROM t;
