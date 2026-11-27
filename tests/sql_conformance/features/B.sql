-- # B series: language bindings. Only direct SQL and the SQL routine
-- # language apply to a wire-protocol engine; B012 (ECPG) is client-side.

-- probe B021.direct_sql
SELECT 1 AS one;
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
SELECT a FROM t;

-- probe B128.routine_language_sql
CREATE FUNCTION f(x INT) RETURNS INT LANGUAGE SQL IMMUTABLE AS 'SELECT x * 2';
CREATE FUNCTION g(x INT) RETURNS INT LANGUAGE SQL RETURN x + 1;
CREATE FUNCTION h(x INT) RETURNS INT LANGUAGE SQL BEGIN ATOMIC SELECT x * 3; END;
SELECT f(2), g(2), h(2);
SELECT routine_name, routine_body FROM information_schema.routines WHERE routine_schema = 'public' ORDER BY routine_name;
