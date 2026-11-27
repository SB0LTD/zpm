-- # S series: arrays, user-defined types and routine paths.

-- probe S071.sql_paths
CREATE SCHEMA s1;
CREATE SCHEMA s2;
CREATE FUNCTION s1.f() RETURNS TEXT LANGUAGE SQL AS $$SELECT 's1'$$;
CREATE FUNCTION s2.f() RETURNS TEXT LANGUAGE SQL AS $$SELECT 's2'$$;
CREATE DOMAIN s2.d AS INT;
SET search_path TO s2, s1, public;
SELECT f();
SELECT CAST(1 AS d), pg_typeof(CAST(1 AS d));
SET search_path TO s1, s2, public;
SELECT f();
SET search_path TO public;
SELECT f();
SELECT s2.f();

-- probe S090.minimal_arrays
CREATE TABLE t(a INT[], b TEXT[3]);
INSERT INTO t VALUES (ARRAY[1, 2, 3], ARRAY['x', 'y']), ('{4,NULL}', '{}');
SELECT a, b, a[2], b[1], cardinality(a) FROM t ORDER BY a[1];
SELECT ARRAY[1, 2] = ARRAY[1, 2], ARRAY[1, 2] < ARRAY[1, 3], pg_typeof(ARRAY[1, 2]);
SELECT (ARRAY[1, 2, 3])[5], (ARRAY[1, 2, 3])[0];

-- probe S092.arrays_udt
CREATE DOMAIN pos AS INT CHECK (VALUE > 0);
CREATE TYPE mood AS ENUM ('sad', 'happy');
CREATE TABLE t(a pos[], m mood[]);
INSERT INTO t VALUES (ARRAY[1, 2]::pos[], ARRAY['happy', 'sad']::mood[]);
SELECT a, m, m[1] FROM t;
INSERT INTO t VALUES (ARRAY[0]::pos[], NULL);

-- probe S095.array_by_query
CREATE TABLE t(a INT);
INSERT INTO t VALUES (3), (1), (2);
SELECT ARRAY(SELECT a FROM t ORDER BY a);
SELECT ARRAY(SELECT a FROM t WHERE a > 10);
SELECT ARRAY(SELECT a::text FROM t ORDER BY a DESC);

-- probe S096.optional_bounds
CREATE TABLE t(a INT ARRAY, b INT ARRAY[4], c INT[][]);
INSERT INTO t VALUES (ARRAY[1], ARRAY[1, 2, 3, 4, 5], ARRAY[[1, 2], [3, 4]]);
SELECT a, b, c, c[2][1] FROM t;

-- probe S098.array_agg
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 3), (1, 1), (2, NULL), (2, 2);
SELECT g, array_agg(v ORDER BY v) FROM t GROUP BY g ORDER BY g;
SELECT array_agg(v ORDER BY v DESC NULLS LAST) FROM t;
SELECT array_agg(DISTINCT g) FROM t;
SELECT array_agg(v) FROM t WHERE false;

-- probe S099.array_expressions
SELECT ARRAY[1, 2] || ARRAY[3], ARRAY[1, 2] || 3, 0 || ARRAY[1], cardinality(ARRAY[[1, 2], [3, 4]]), array_length(ARRAY[1, 2, 3], 1);
SELECT (ARRAY[1, 2, 3, 4])[2:3], (ARRAY['a', 'b', 'c'])[:2], array_position(ARRAY['a', 'b'], 'b'), array_upper(ARRAY[1, 2], 1);
SELECT 2 = ANY (ARRAY[1, 2]), ARRAY[1, 2] @> ARRAY[2], ARRAY[1] && ARRAY[2];

-- probe S111.only
CREATE TABLE parent(a INT);
CREATE TABLE child(b INT) INHERITS (parent);
INSERT INTO parent VALUES (1);
INSERT INTO child VALUES (2, 3);
SELECT a FROM parent ORDER BY a;
SELECT a FROM ONLY parent;
SELECT a FROM ONLY (parent);
UPDATE ONLY parent SET a = a + 10;
SELECT a FROM parent ORDER BY a;
DELETE FROM ONLY parent;
SELECT a FROM parent;

-- probe S201.routines_on_arrays
CREATE FUNCTION total(xs INT[]) RETURNS INT LANGUAGE SQL AS $$SELECT sum(x)::int FROM unnest(xs) x$$;
CREATE FUNCTION firsts(xs TEXT[]) RETURNS TEXT LANGUAGE SQL AS $$SELECT xs[1]$$;
SELECT total(ARRAY[1, 2, 3]), firsts(ARRAY['p', 'q']), total('{}');

-- probe S203.array_parameters
CREATE FUNCTION lenof(xs INT[]) RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN coalesce(array_length(xs, 1), 0); END$$;
CREATE PROCEDURE p(xs INT[], INOUT n INT) LANGUAGE plpgsql AS $$BEGIN n := cardinality(xs); END$$;
SELECT lenof(ARRAY[4, 5]), lenof(NULL);
CALL p(ARRAY[1, 2, 3], NULL);

-- probe S204.array_results
CREATE FUNCTION pair(a INT, b INT) RETURNS INT[] LANGUAGE SQL AS $$SELECT ARRAY[a, b]$$;
CREATE FUNCTION words() RETURNS TEXT[] LANGUAGE plpgsql AS $$BEGIN RETURN ARRAY['x', 'y']; END$$;
SELECT pair(1, 2), (pair(1, 2))[2], words(), pg_typeof(words());

-- probe S211.user_cast
CREATE TYPE pt AS (x INT, y INT);
CREATE FUNCTION pt_text(p pt) RETURNS TEXT LANGUAGE SQL AS $$SELECT p.x || ':' || p.y$$;
CREATE CAST (pt AS TEXT) WITH FUNCTION pt_text(pt);
SELECT CAST(ROW(1, 2)::pt AS TEXT);
CREATE DOMAIN money2 AS NUMERIC(10,2);
CREATE FUNCTION int_to_money2(i INT) RETURNS money2 LANGUAGE SQL AS $$SELECT (i / 100.0)::money2$$;
CREATE TYPE wrapper AS (v INT);
CREATE FUNCTION int_wrap(i INT) RETURNS wrapper LANGUAGE SQL AS $$SELECT ROW(i)::wrapper$$;
CREATE CAST (INT AS wrapper) WITH FUNCTION int_wrap(INT) AS ASSIGNMENT;
SELECT (5::wrapper).v;
DROP CAST (INT AS wrapper);
SELECT 5::wrapper;

-- probe S301.enhanced_unnest
SELECT * FROM unnest(ARRAY[1, 2], ARRAY['a', 'b', 'c']) AS u(n, s);
SELECT * FROM unnest(ARRAY['x', 'y']) WITH ORDINALITY AS u(v, i);
SELECT n FROM unnest(ARRAY[[1, 2], [3, 4]]) AS n;
CREATE TABLE t(id INT, xs INT[]);
INSERT INTO t VALUES (1, '{10,20}'), (2, '{30}');
SELECT id, x FROM t, unnest(xs) AS x;

-- probe S404.trim_array
SELECT trim_array(ARRAY[1, 2, 3, 4], 2), trim_array(ARRAY['a', 'b'], 0), trim_array(ARRAY[1], 1);
SELECT trim_array(ARRAY[1, 2], 3);
