-- # E series: SQL core. One probe header per program; see feature_probes.py.

-- probe E011-01.int
-- ordered
CREATE TABLE t(a INTEGER, b SMALLINT, c INT);
INSERT INTO t VALUES (1, 2, 3), (-4, 5, NULL);
SELECT a, b, c, a + b FROM t ORDER BY a;
SELECT 32767::smallint + 1::smallint;
SELECT 2147483647 + 1;
INSERT INTO t(b) VALUES (40000);

-- probe E011-02.float
SELECT 1.5::real, 2.25::double precision, 3.5::float, 4::float(10), 5::float(30);
SELECT pg_typeof(1.5::real), pg_typeof(1.5::float(24)), pg_typeof(1.5::float(25));
SELECT 1e308::float8 * 10;

-- probe E011-03.numeric
CREATE TABLE t(a DECIMAL(5,2), b NUMERIC(10), c NUMERIC);
INSERT INTO t VALUES (123.456, 12345.6, 0.1);
SELECT a, b, c, a + c FROM t;
INSERT INTO t VALUES (1234.5, 0, 0);
SELECT 1.10::numeric(4,2) * 3, 10::decimal / 4;

-- probe E011-04.arith
SELECT 7 + 3, 7 - 3, 7 * 3, 7 / 3, -7 / 2, 7.0 / 2, -(4), +5, 7 % 3;
SELECT 1 / 0;
SELECT 1.5 * 2::int, 2::smallint * 3::bigint;

-- probe E011-05.cmp
SELECT 1 < 2, 2 <= 2, 3 > 4, 4 >= 4, 5 = 5.0, 5 <> 6, 1.5::real = 1.5::float8, 2::smallint < 3::bigint;

-- probe E011-06.implicit
CREATE TABLE t(a SMALLINT, b INTEGER, c BIGINT, d NUMERIC(6,2), e REAL, f DOUBLE PRECISION);
INSERT INTO t VALUES (1, 2, 3, 4.5, 6.5, 7.25);
SELECT pg_typeof(a + b), pg_typeof(b + c), pg_typeof(c + d), pg_typeof(d + e), pg_typeof(a + f) FROM t;
UPDATE t SET a = 9.6, b = 10.4, d = 3;
SELECT a, b, d FROM t;

-- probe E021-01.char
CREATE TABLE t(a CHARACTER(5), b CHAR(3), c CHAR);
INSERT INTO t VALUES ('ab', 'x', 'y');
SELECT a, b, c, octet_length(a), a = 'ab' FROM t;
INSERT INTO t VALUES ('abcdefg', 'x', 'y');
SELECT pg_typeof(a), length(a || '|') FROM t;

-- probe E021-02.varchar
CREATE TABLE t(a CHARACTER VARYING(5), b VARCHAR(3), c VARCHAR);
INSERT INTO t VALUES ('ab ', 'xyz', 'long text');
SELECT a, b, c, length(a) FROM t;
INSERT INTO t VALUES ('abcdef', 'x', 'y');
INSERT INTO t VALUES ('abcde   ', 'x', 'y');
SELECT a, length(a) FROM t ORDER BY a;

-- probe E021-03.literals
SELECT 'abc', 'it''s', '', 'a''''b';
SELECT pg_typeof('abc'), 'x' = 'x';

-- probe E021-04.char_length
SELECT CHARACTER_LENGTH('abc'), CHAR_LENGTH('héllo'), CHARACTER_LENGTH(''), CHAR_LENGTH(NULL::text);
SELECT CHAR_LENGTH('ab   '::char(5)), CHARACTER_LENGTH('ab   '::varchar(5));

-- probe E021-05.octet_length
SELECT OCTET_LENGTH('abc'), OCTET_LENGTH('héllo'), OCTET_LENGTH(''), OCTET_LENGTH('ab'::char(4));

-- probe E021-06.substring
SELECT SUBSTRING('abcdef' FROM 2 FOR 3), SUBSTRING('abcdef' FROM 4), SUBSTRING('abcdef' FOR 2), SUBSTRING('abc' FROM 0 FOR 2), SUBSTRING('abc' FROM 5);
SELECT SUBSTRING('abc' FROM 1 FOR -1);

-- probe E021-07.concat
SELECT 'ab' || 'cd', 'x' || NULL, 'a' || 1, 'ab'::char(4) || 'c';

-- probe E021-08.upper_lower
SELECT UPPER('abcÄé'), LOWER('ABCxyz'), UPPER(NULL);

-- probe E021-09.trim
SELECT TRIM('  ab  '), TRIM(LEADING FROM '  ab  '), TRIM(TRAILING FROM '  ab  '), TRIM(BOTH 'x' FROM 'xxabxx'), TRIM(LEADING 'x' FROM 'xxab'), TRIM('x' FROM 'xabx');

-- probe E021-10.implicit
CREATE TABLE t(a CHAR(4), b VARCHAR(10), c TEXT);
INSERT INTO t VALUES ('ab', 'cd', 'ef');
SELECT a || b, b || c, pg_typeof(a || b), a = 'ab  ', b = 'cd'::char(4) FROM t;
UPDATE t SET b = a, c = a;
SELECT b, c, length(b) FROM t;

-- probe E021-11.position
SELECT POSITION('c' IN 'abcabc'), POSITION('z' IN 'abc'), POSITION('' IN 'abc'), POSITION('é' IN 'aéb');

-- probe E021-12.compare
SELECT 'a' < 'b', 'abc' = 'abc', 'abc' < 'abd', 'B' < 'a', 'ab'::char(4) = 'ab', 'ab ' = 'ab', 'ab'::varchar = 'ab';

-- probe E031-01.delimited
CREATE TABLE "My Table"("Col A" INT, "select" INT, "x""y" INT);
INSERT INTO "My Table" VALUES (1, 2, 3);
SELECT "Col A", "select", "x""y" FROM "My Table";
SELECT * FROM "my table";

-- probe E031-02.lower
CREATE TABLE MixedCase(SomeCol INT);
INSERT INTO mixedcase VALUES (1);
SELECT SOMECOL, somecol FROM MIXEDCASE;
SELECT "SomeCol" FROM mixedcase;

-- probe E031-03.underscore
CREATE TABLE t_(c_ INT, _d INT);
INSERT INTO t_ VALUES (1, 2);
SELECT c_, _d FROM t_;

-- probe E051-01.distinct
-- ordered
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1), (1, 1), (2, NULL), (2, NULL), (3, 4);
SELECT DISTINCT a, b FROM t ORDER BY a;
SELECT DISTINCT b FROM t ORDER BY b;
SELECT ALL a FROM t ORDER BY a;

-- probe E051-02.group_by
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 10), (1, 20), (2, 5), (NULL, 7), (NULL, 8);
SELECT g, sum(v), count(*) FROM t GROUP BY g;
SELECT g FROM t GROUP BY g, g;

-- probe E051-04.group_by_hidden
CREATE TABLE t(g INT, h INT, v INT);
INSERT INTO t VALUES (1, 1, 10), (1, 2, 20), (2, 1, 5);
SELECT sum(v) FROM t GROUP BY g, h;
SELECT count(*) FROM t GROUP BY g;

-- probe E051-05.rename
SELECT 1 AS one, 2 two, 3 AS "Three";
CREATE TABLE t(a INT);
INSERT INTO t VALUES (5);
SELECT a AS b, a + 1 AS "c d" FROM t;

-- probe E051-06.having
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 10), (1, 20), (2, 5), (3, 1), (3, 2);
SELECT g, sum(v) FROM t GROUP BY g HAVING sum(v) > 4;
SELECT count(*) FROM t HAVING count(*) > 100;
SELECT g FROM t GROUP BY g HAVING min(v) < 3 AND count(*) = 2;

-- probe E051-07.qualified_star
CREATE TABLE a(x INT, y INT);
CREATE TABLE b(z INT);
INSERT INTO a VALUES (1, 2);
INSERT INTO b VALUES (3);
SELECT a.*, b.* FROM a, b;
SELECT b.*, a.x FROM a, b;

-- probe E051-08.correlation
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
SELECT x.a FROM t AS x WHERE x.a = 2;
SELECT x.a, y.a FROM t x, t y WHERE x.a < y.a;
SELECT t.a FROM t AS x;

-- probe E051-09.rename_from
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 2);
SELECT x.p, x.q FROM t AS x(p, q);
SELECT p, b FROM t AS x(p);
SELECT * FROM t AS x(p, q, r);

-- probe E061-01.comparison
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, NULL);
SELECT a FROM t WHERE a = 2;
SELECT a FROM t WHERE a <> 2;
SELECT a FROM t WHERE b >= 'a';
SELECT a FROM t WHERE a < 3 AND a > 1;
SELECT NULL = NULL, 1 = NULL;

-- probe E061-02.between
SELECT 2 BETWEEN 1 AND 3, 5 BETWEEN 1 AND 3, 2 NOT BETWEEN 1 AND 3, NULL BETWEEN 1 AND 2, 'b' BETWEEN 'a' AND 'c', 3 BETWEEN 3 AND 1;

-- probe E061-03.in_list
SELECT 2 IN (1, 2, 3), 4 IN (1, 2, 3), 4 NOT IN (1, 2), 4 IN (1, NULL), 4 NOT IN (1, NULL), NULL IN (1), 'b' IN ('a', 'b');

-- probe E061-04.like
SELECT 'abc' LIKE 'a%', 'abc' LIKE '_b_', 'abc' LIKE 'b%', 'abc' NOT LIKE '%z%', 'a%c' LIKE 'a%c', NULL LIKE 'a', 'ABC' LIKE 'abc', '' LIKE '%';

-- probe E061-05.like_escape
SELECT 'a%c' LIKE 'a\%c', 'abc' LIKE 'a\%c', 'a_c' LIKE 'a#_c' ESCAPE '#', 'abc' LIKE 'a#_c' ESCAPE '#', 'a#c' LIKE 'a##c' ESCAPE '#';
SELECT 'abc' LIKE 'a%' ESCAPE 'xy';

-- probe E061-06.null
SELECT NULL IS NULL, 1 IS NULL, 1 IS NOT NULL, NULL IS NOT NULL;
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (NULL), (NULL);
SELECT count(*) FROM t WHERE a IS NULL;

-- probe E061-07.quantified
SELECT 2 = ANY (ARRAY[1, 2]), 3 > ALL (ARRAY[1, 2]), 3 < SOME (ARRAY[1, 2]), 1 = ALL (ARRAY[]::int[]), 1 = ANY (ARRAY[]::int[]);
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3);
SELECT 3 >= ALL (SELECT a FROM t), 4 = ANY (SELECT a FROM t), 2 <> ALL (SELECT a FROM t), 1 < SOME (SELECT a FROM t);

-- probe E061-08.exists
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
SELECT EXISTS (SELECT 1 FROM t WHERE a = 2), EXISTS (SELECT 1 FROM t WHERE a = 5), NOT EXISTS (SELECT * FROM t WHERE a > 10);

-- probe E061-09.subquery_cmp
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3);
SELECT a FROM t WHERE a = (SELECT max(a) FROM t);
SELECT a FROM t WHERE a > (SELECT min(a) FROM t WHERE a > 5);
SELECT a FROM t WHERE a = (SELECT a FROM t);

-- probe E061-11.subquery_in
CREATE TABLE t(a INT);
CREATE TABLE u(b INT);
INSERT INTO t VALUES (1), (2), (3);
INSERT INTO u VALUES (2), (3), (NULL);
SELECT a FROM t WHERE a IN (SELECT b FROM u);
SELECT a FROM t WHERE a NOT IN (SELECT b FROM u);
SELECT a FROM t WHERE a NOT IN (SELECT b FROM u WHERE b IS NOT NULL);

-- probe E061-12.subquery_quantified
CREATE TABLE t(a INT);
CREATE TABLE u(b INT);
INSERT INTO t VALUES (1), (2), (3);
INSERT INTO u VALUES (2), (3);
SELECT a FROM t WHERE a < ALL (SELECT b FROM u);
SELECT a FROM t WHERE a = SOME (SELECT b FROM u);
SELECT a FROM t WHERE a > ANY (SELECT b FROM u);

-- probe E061-13.correlated
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 10), (1, 20), (2, 5), (2, 7);
SELECT g, v FROM t AS o WHERE v = (SELECT max(v) FROM t WHERE g = o.g);
SELECT g, (SELECT count(*) FROM t i WHERE i.g = o.g AND i.v < o.v) FROM t o;
SELECT g FROM t o WHERE EXISTS (SELECT 1 FROM t i WHERE i.g = o.g AND i.v > 15);

-- probe E061-14.search
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1), (1, 2), (2, 1), (NULL, 1);
SELECT a, b FROM t WHERE (a = 1 OR b = 1) AND NOT (a = 2);
SELECT a, b FROM t WHERE NOT (a = 1) OR a IS NULL;
SELECT (NULL AND FALSE), (NULL OR TRUE), (NULL AND TRUE), NOT NULL::boolean;

-- probe E071-01.union
-- ordered
SELECT 1 UNION SELECT 2 UNION SELECT 1 ORDER BY 1;
SELECT 1 UNION DISTINCT SELECT 1;
SELECT NULL::int UNION SELECT NULL::int;

-- probe E071-02.union_all
SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 2;

-- probe E071-03.except
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (1), (2), (3), (NULL);
SELECT a FROM t EXCEPT SELECT 2;
SELECT a FROM t EXCEPT DISTINCT SELECT NULL::int;

-- probe E071-05.mixed_types
SELECT 1 UNION SELECT 2.5;
SELECT 'a'::char(3) UNION SELECT 'bc'::varchar(5);
SELECT 1::smallint UNION ALL SELECT 2::bigint;
SELECT pg_typeof(x) FROM (SELECT 1 AS x UNION SELECT 2.5) s LIMIT 1;

-- probe E071-06.in_subqueries
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
SELECT a FROM t WHERE a IN (SELECT 1 UNION SELECT 3);
SELECT count(*) FROM (SELECT a FROM t EXCEPT SELECT 2) s;
SELECT a FROM t WHERE EXISTS (SELECT 1 WHERE a = 4 UNION ALL SELECT 1 WHERE a = 1);

-- probe E081-01.select_priv
CREATE ROLE w4f_r;
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
SET ROLE w4f_r;
SELECT a FROM t;
RESET ROLE;
GRANT SELECT ON t TO w4f_r;
SET ROLE w4f_r;
SELECT a FROM t;
INSERT INTO t VALUES (2);
RESET ROLE;

-- probe E081-02.delete_priv
CREATE ROLE w4f_r;
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
SET ROLE w4f_r;
DELETE FROM t;
RESET ROLE;
GRANT DELETE ON TABLE t TO w4f_r;
SET ROLE w4f_r;
DELETE FROM t;
DELETE FROM t WHERE a = 1;
RESET ROLE;
GRANT SELECT ON t TO w4f_r;
SET ROLE w4f_r;
DELETE FROM t WHERE a = 1;
RESET ROLE;
SELECT a FROM t;

-- probe E081-03.insert_priv
CREATE ROLE w4f_r;
CREATE TABLE t(a INT);
SET ROLE w4f_r;
INSERT INTO t VALUES (1);
RESET ROLE;
GRANT INSERT ON t TO w4f_r;
SET ROLE w4f_r;
INSERT INTO t VALUES (2);
SELECT a FROM t;
RESET ROLE;
SELECT a FROM t;

-- probe E081-04.update_priv
CREATE ROLE w4f_r;
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1);
SET ROLE w4f_r;
UPDATE t SET b = 2;
RESET ROLE;
GRANT UPDATE ON t TO w4f_r;
SET ROLE w4f_r;
UPDATE t SET b = 3;
UPDATE t SET b = 4 WHERE a = 1;
RESET ROLE;
SELECT a, b FROM t;

-- probe E081-05.update_column_priv
CREATE ROLE w4f_r;
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1);
GRANT UPDATE (b) ON t TO w4f_r;
SET ROLE w4f_r;
UPDATE t SET b = 5;
UPDATE t SET a = 5;
RESET ROLE;
SELECT a, b FROM t;

-- probe E081-06.references_priv
CREATE ROLE w4f_r;
GRANT CREATE ON SCHEMA public TO w4f_r;
CREATE TABLE p(id INT PRIMARY KEY);
SET ROLE w4f_r;
CREATE TABLE c(id INT REFERENCES p);
RESET ROLE;
GRANT REFERENCES ON p TO w4f_r;
SET ROLE w4f_r;
CREATE TABLE c(id INT REFERENCES p);
RESET ROLE;
SELECT count(*) FROM information_schema.table_constraints WHERE table_name = 'c' AND constraint_type = 'FOREIGN KEY';

-- probe E081-07.references_column_priv
CREATE ROLE w4f_r;
GRANT CREATE ON SCHEMA public TO w4f_r;
CREATE TABLE p(id INT PRIMARY KEY, k INT UNIQUE);
GRANT REFERENCES (k) ON p TO w4f_r;
SET ROLE w4f_r;
CREATE TABLE c1(x INT REFERENCES p(id));
CREATE TABLE c2(x INT REFERENCES p(k));
RESET ROLE;
SELECT table_name FROM information_schema.tables WHERE table_name IN ('c1', 'c2');

-- probe E081-08.grant_option
CREATE ROLE w4f_a;
CREATE ROLE w4f_b;
CREATE TABLE t(a INT);
INSERT INTO t VALUES (7);
GRANT SELECT ON t TO w4f_a WITH GRANT OPTION;
SET ROLE w4f_a;
GRANT SELECT ON t TO w4f_b;
RESET ROLE;
SET ROLE w4f_b;
SELECT a FROM t;
GRANT SELECT ON t TO w4f_a;
RESET ROLE;
SELECT grantee, privilege_type, is_grantable FROM information_schema.table_privileges WHERE table_name = 't' AND grantee LIKE 'w4f%' ORDER BY grantee;

-- probe E081-09.usage_priv
CREATE ROLE w4f_r;
CREATE SCHEMA s;
CREATE TABLE s.t(a INT);
GRANT SELECT ON s.t TO w4f_r;
SET ROLE w4f_r;
SELECT a FROM s.t;
RESET ROLE;
GRANT USAGE ON SCHEMA s TO w4f_r;
SET ROLE w4f_r;
SELECT count(*) FROM s.t;
RESET ROLE;
CREATE DOMAIN d AS INT;
GRANT USAGE ON DOMAIN d TO w4f_r;
SET ROLE w4f_r;
SELECT CAST(1 AS d);
RESET ROLE;

-- probe E081-10.execute_priv
CREATE ROLE w4f_r;
CREATE FUNCTION f() RETURNS INT LANGUAGE SQL AS 'SELECT 42';
REVOKE EXECUTE ON FUNCTION f() FROM PUBLIC;
SET ROLE w4f_r;
SELECT f();
RESET ROLE;
GRANT EXECUTE ON FUNCTION f() TO w4f_r;
SET ROLE w4f_r;
SELECT f();
RESET ROLE;

-- probe E091-01.avg
CREATE TABLE t(a INT, b NUMERIC, c FLOAT8);
INSERT INTO t VALUES (1, 1.5, 1), (2, 2.5, 2), (4, NULL, NULL);
SELECT avg(a), avg(b), avg(c), pg_typeof(avg(a)), pg_typeof(avg(c)) FROM t;
SELECT avg(a) FROM t WHERE a > 10;

-- probe E091-02.count
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (NULL), (1);
SELECT count(*), count(a), count(1), pg_typeof(count(*)) FROM t;
SELECT count(*) FROM t WHERE a > 5;

-- probe E091-03.max
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, 'b'), (3, 'a'), (NULL, NULL);
SELECT max(a), max(b), max(a) FILTER (WHERE a < 3) FROM t;
SELECT max(a) FROM t WHERE false;

-- probe E091-04.min
CREATE TABLE t(a INT, b TEXT, c DATE);
INSERT INTO t VALUES (1, 'b', '2020-01-02'), (3, 'a', '2019-05-06'), (NULL, NULL, NULL);
SELECT min(a), min(b), min(c) FROM t;
SELECT min(a) FROM t WHERE false;

-- probe E091-05.sum
CREATE TABLE t(a INT, b BIGINT, c NUMERIC(5,2), d REAL);
INSERT INTO t VALUES (1, 10, 1.25, 0.5), (2, NULL, 2.50, 1.5);
SELECT sum(a), sum(b), sum(c), sum(d), pg_typeof(sum(a)), pg_typeof(sum(b)) FROM t;
SELECT sum(a) FROM t WHERE false;

-- probe E091-06.all
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (1), (2), (NULL);
SELECT count(ALL a), sum(ALL a), avg(ALL a), max(ALL a) FROM t;

-- probe E091-07.distinct
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (1), (2), (NULL);
SELECT count(DISTINCT a), sum(DISTINCT a), avg(DISTINCT a), min(DISTINCT a) FROM t;

-- probe E101-01.insert
-- ordered
CREATE TABLE t(a INT, b TEXT DEFAULT 'd', c INT);
INSERT INTO t VALUES (1, 'x', 2);
INSERT INTO t(c, a) VALUES (3, 2);
INSERT INTO t VALUES (3, 'y', NULL), (4, 'z', 5);
INSERT INTO t SELECT a + 10, b, c FROM t WHERE a < 3;
SELECT a, b, c FROM t ORDER BY a;
INSERT INTO t VALUES (1, 2, 3, 4);

-- probe E101-03.update
-- ordered
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1), (2, 2), (3, 3);
UPDATE t SET b = b * 10 WHERE a >= 2;
UPDATE t SET a = a + 1, b = a;
UPDATE t SET b = 0 WHERE a > 100;
SELECT a, b FROM t ORDER BY a;

-- probe E101-04.delete
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (NULL);
DELETE FROM t WHERE a = 2;
DELETE FROM t WHERE a IS NULL;
SELECT a FROM t;
DELETE FROM t;
SELECT count(*) FROM t;

-- probe E111.single_row
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, 'one'), (2, 'two');
SELECT b FROM t WHERE a = 2;
SELECT count(*) FROM t;
SELECT (SELECT b FROM t WHERE a = 1) AS v;
SELECT (SELECT b FROM t) AS v;

-- probe E121-01.declare
BEGIN;
DECLARE c CURSOR FOR SELECT n FROM (VALUES (1), (2), (3)) v(n) ORDER BY n;
FETCH c;
FETCH c;
CLOSE c;
COMMIT;
DECLARE c CURSOR FOR SELECT 1;

-- probe E121-02.order_hidden
-- ordered
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 3), (2, 1), (3, 2);
SELECT a FROM t ORDER BY b;
BEGIN;
DECLARE c CURSOR FOR SELECT a FROM t ORDER BY b DESC;
FETCH 3 FROM c;
COMMIT;

-- probe E121-03.order_expr
-- ordered
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 3), (2, 1), (3, 2);
SELECT a FROM t ORDER BY a * -1;
SELECT a, b FROM t ORDER BY a + b DESC, a;
SELECT a FROM t ORDER BY CASE WHEN a = 2 THEN 0 ELSE 1 END, a;

-- probe E121-04.open
BEGIN;
DECLARE c CURSOR FOR SELECT x FROM (VALUES (1), (2)) v(x) ORDER BY x;
FETCH NEXT FROM c;
FETCH NEXT FROM c;
FETCH NEXT FROM c;
COMMIT;

-- probe E121-06.positioned_update
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 0), (2, 0);
BEGIN;
DECLARE c CURSOR FOR SELECT a FROM t WHERE a = 2 FOR UPDATE;
FETCH c;
UPDATE t SET b = 9 WHERE CURRENT OF c;
COMMIT;
SELECT a, b FROM t;

-- probe E121-07.positioned_delete
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3);
BEGIN;
DECLARE c CURSOR FOR SELECT a FROM t WHERE a >= 2 ORDER BY a FOR UPDATE;
FETCH c;
DELETE FROM t WHERE CURRENT OF c;
COMMIT;
SELECT a FROM t;

-- probe E121-08.close
BEGIN;
DECLARE c CURSOR FOR SELECT 1;
CLOSE c;
FETCH c;
ROLLBACK;
BEGIN;
DECLARE c1 CURSOR FOR SELECT 1;
DECLARE c2 CURSOR FOR SELECT 2;
CLOSE ALL;
SELECT count(*) FROM pg_cursors;
COMMIT;

-- probe E121-10.fetch_next
-- ordered
BEGIN;
DECLARE c CURSOR FOR SELECT x FROM (VALUES (10), (20), (30)) v(x) ORDER BY x;
FETCH FROM c;
FETCH c;
FETCH 5 FROM c;
COMMIT;

-- probe E121-17.with_hold
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
BEGIN;
DECLARE c CURSOR WITH HOLD FOR SELECT a FROM t ORDER BY a;
COMMIT;
FETCH c;
FETCH c;
CLOSE c;

-- probe E131.nulls
-- ordered
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (NULL, NULL), (1, 'x');
SELECT a, b, a + 1, b || 'y', coalesce(a, -1) FROM t ORDER BY a NULLS FIRST;
SELECT a FROM t ORDER BY a;
SELECT a FROM t ORDER BY a DESC;

-- probe E141-01.not_null
CREATE TABLE t(a INT NOT NULL, b INT);
INSERT INTO t VALUES (NULL, 1);
INSERT INTO t(b) VALUES (2);
INSERT INTO t VALUES (1, NULL);
UPDATE t SET a = NULL;
SELECT a, b FROM t;

-- probe E141-02.unique_not_null
CREATE TABLE t(a INT NOT NULL UNIQUE, b INT NOT NULL, c INT NOT NULL, UNIQUE (b, c));
INSERT INTO t VALUES (1, 1, 1);
INSERT INTO t VALUES (1, 2, 2);
INSERT INTO t VALUES (2, 1, 1);
INSERT INTO t VALUES (2, 1, 2);
UPDATE t SET a = 1 WHERE a = 2;
SELECT a, b, c FROM t;

-- probe E141-03.primary_key
CREATE TABLE t(a INT PRIMARY KEY, b INT);
CREATE TABLE u(a INT, b INT, PRIMARY KEY (a, b));
INSERT INTO t VALUES (1, 1);
INSERT INTO t VALUES (1, 2);
INSERT INTO u VALUES (1, 1), (1, 2);
INSERT INTO u VALUES (1, 1);
SELECT count(*) FROM t;
SELECT count(*) FROM u;
CREATE TABLE v(a INT PRIMARY KEY, b INT PRIMARY KEY);

-- probe E141-04.foreign_key
CREATE TABLE p(id INT PRIMARY KEY);
CREATE TABLE c(id INT, pid INT REFERENCES p);
INSERT INTO p VALUES (1), (2);
INSERT INTO c VALUES (1, 1), (2, NULL);
INSERT INTO c VALUES (3, 3);
DELETE FROM p WHERE id = 1;
UPDATE p SET id = 5 WHERE id = 1;
DELETE FROM p WHERE id = 2;
SELECT id FROM p;

-- probe E141-06.check
CREATE TABLE t(a INT CHECK (a > 0), b INT, CONSTRAINT bc CHECK (b < a));
INSERT INTO t VALUES (1, 0);
INSERT INTO t VALUES (0, -1);
INSERT INTO t VALUES (2, 3);
INSERT INTO t VALUES (NULL, NULL);
UPDATE t SET b = 10 WHERE a = 1;
SELECT a, b FROM t;

-- probe E141-07.defaults
CREATE TABLE t(a INT DEFAULT 5, b TEXT DEFAULT 'x', c DATE DEFAULT DATE '2020-01-01', d INT);
INSERT INTO t(d) VALUES (1);
INSERT INTO t VALUES (DEFAULT, DEFAULT, DEFAULT, 2);
INSERT INTO t DEFAULT VALUES;
SELECT a, b, c, d FROM t;

-- probe E141-08.pk_not_null
CREATE TABLE t(a INT PRIMARY KEY, b INT);
INSERT INTO t VALUES (NULL, 1);
SELECT attnotnull FROM pg_attribute WHERE attrelid = 't'::regclass AND attname = 'a';

-- probe E141-10.fk_any_order
CREATE TABLE p(a INT, b INT, PRIMARY KEY (a, b));
CREATE TABLE c(x INT, y INT, FOREIGN KEY (y, x) REFERENCES p(b, a));
INSERT INTO p VALUES (1, 2);
INSERT INTO c VALUES (1, 2);
INSERT INTO c VALUES (2, 1);
SELECT x, y FROM c;

-- probe E151-01.commit
CREATE TABLE t(a INT);
BEGIN;
INSERT INTO t VALUES (1);
COMMIT;
SELECT a FROM t;
COMMIT WORK;
START TRANSACTION;
INSERT INTO t VALUES (2);
COMMIT WORK;
SELECT count(*) FROM t;

-- probe E151-02.rollback
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
BEGIN;
INSERT INTO t VALUES (2);
DELETE FROM t WHERE a = 1;
ROLLBACK;
SELECT a FROM t;
BEGIN;
SELECT 1/0;
ROLLBACK WORK;
SELECT count(*) FROM t;
ROLLBACK;

-- probe E152-01.serializable
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SHOW transaction_isolation;
COMMIT;
BEGIN;
SELECT 1;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
ROLLBACK;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- probe E152-02.read_only
CREATE TABLE t(a INT);
BEGIN;
SET TRANSACTION READ ONLY;
SHOW transaction_read_only;
INSERT INTO t VALUES (1);
ROLLBACK;
BEGIN;
SET TRANSACTION READ WRITE;
INSERT INTO t VALUES (2);
COMMIT;
SELECT a FROM t;

-- probe E153.updatable_subquery
CREATE TABLE t(a INT, b INT);
CREATE TABLE u(a INT);
INSERT INTO t VALUES (1, 0), (2, 0), (3, 0);
INSERT INTO u VALUES (2), (3);
UPDATE t SET b = 1 WHERE a IN (SELECT a FROM u);
DELETE FROM t WHERE a = (SELECT max(a) FROM u);
CREATE VIEW v AS SELECT a, b FROM t WHERE a IN (SELECT a FROM u);
UPDATE v SET b = 7;
SELECT a, b FROM t;

-- probe E161.dash_comments
SELECT 1 -- trailing comment
 + 2;
-- a full-line comment inside a statement
SELECT 'a--b' AS x;

-- probe E171.sqlstate
SELECT 1/0;
SELECT * FROM missing_table;
SELECT 'x'::int;
CREATE TABLE t(a INT PRIMARY KEY);
INSERT INTO t VALUES (1), (1);
SELECT missing_column FROM t;
SELEC 1;
