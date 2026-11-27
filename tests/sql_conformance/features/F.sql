-- # F series: SQL foundation features. See feature_probes.py for the format.

-- probe F021-01.columns
CREATE TABLE t(a INT NOT NULL, b VARCHAR(10) DEFAULT 'x', c NUMERIC(5,2));
SELECT column_name, ordinal_position, is_nullable, data_type, character_maximum_length, numeric_precision, numeric_scale, column_default FROM information_schema.columns WHERE table_name = 't' ORDER BY ordinal_position;

-- probe F021-01.identity_columns
CREATE TABLE t(id INT GENERATED ALWAYS AS IDENTITY, g INT GENERATED ALWAYS AS (id * 2) STORED);
SELECT column_name, is_identity, identity_generation, is_generated, generation_expression FROM information_schema.columns WHERE table_name = 't' ORDER BY ordinal_position;

-- probe F021-02.tables
CREATE TABLE t(a INT);
CREATE VIEW v AS SELECT a FROM t;
SELECT table_catalog = current_database(), table_schema, table_name, table_type, is_insertable_into FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name;

-- probe F021-03.views
CREATE TABLE t(a INT);
CREATE VIEW v AS SELECT a FROM t WHERE a > 0 WITH CHECK OPTION;
SELECT table_name, check_option, is_updatable, is_insertable_into FROM information_schema.views WHERE table_schema = 'public';

-- probe F021-04.table_constraints
CREATE TABLE p(id INT PRIMARY KEY, u INT UNIQUE, c INT CONSTRAINT c_pos CHECK (c > 0));
CREATE TABLE f(x INT CONSTRAINT f_fk REFERENCES p);
SELECT table_name, constraint_type, is_deferrable, initially_deferred FROM information_schema.table_constraints WHERE table_schema = 'public' AND constraint_type <> 'CHECK' ORDER BY table_name, constraint_type;
SELECT constraint_name FROM information_schema.table_constraints WHERE constraint_name IN ('c_pos', 'f_fk') ORDER BY 1;

-- probe F021-05.referential_constraints
CREATE TABLE p(id INT PRIMARY KEY);
CREATE TABLE f(x INT CONSTRAINT f_fk REFERENCES p ON DELETE CASCADE);
SELECT constraint_name, unique_constraint_name, match_option, update_rule, delete_rule FROM information_schema.referential_constraints;

-- probe F021-06.check_constraints
CREATE TABLE t(a INT CONSTRAINT a_pos CHECK (a > 0));
SELECT constraint_name, check_clause FROM information_schema.check_constraints WHERE constraint_name = 'a_pos';

-- probe F031-01.create_table
CREATE TABLE t(a INT, b TEXT, c DATE);
INSERT INTO t VALUES (1, 'x', '2024-02-29');
SELECT * FROM t;
CREATE TABLE t(a INT);
CREATE TABLE IF NOT EXISTS t(a INT);

-- probe F031-02.create_view
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 2), (3, 4);
CREATE VIEW v AS SELECT a + b AS s FROM t;
CREATE VIEW w(x, y) AS SELECT a, b FROM t WHERE a > 1;
SELECT s FROM v;
SELECT x, y FROM w;

-- probe F031-03.grant
CREATE ROLE w4f_r;
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
GRANT SELECT, INSERT ON t TO w4f_r;
GRANT ALL PRIVILEGES ON t TO PUBLIC;
REVOKE ALL PRIVILEGES ON t FROM PUBLIC;
SET ROLE w4f_r;
INSERT INTO t VALUES (2);
SELECT a FROM t;
DELETE FROM t;
RESET ROLE;

-- probe F031-04.add_column
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
ALTER TABLE t ADD COLUMN b INT DEFAULT 7;
ALTER TABLE t ADD c TEXT;
SELECT a, b, c FROM t;
ALTER TABLE t ADD COLUMN a INT;

-- probe F031-13.drop_table_restrict
CREATE TABLE t(a INT);
CREATE VIEW v AS SELECT a FROM t;
DROP TABLE t RESTRICT;
DROP VIEW v;
DROP TABLE t RESTRICT;
SELECT count(*) FROM information_schema.tables WHERE table_name = 't';

-- probe F031-16.drop_view_restrict
CREATE TABLE t(a INT);
CREATE VIEW v AS SELECT a FROM t;
CREATE VIEW w AS SELECT a FROM v;
DROP VIEW v RESTRICT;
DROP VIEW w RESTRICT;
DROP VIEW v RESTRICT;
SELECT * FROM v;

-- probe F031-19.revoke_restrict
CREATE ROLE w4f_r;
CREATE TABLE t(a INT);
GRANT SELECT ON t TO w4f_r;
REVOKE SELECT ON t FROM w4f_r RESTRICT;
SET ROLE w4f_r;
SELECT a FROM t;
RESET ROLE;

-- probe F032.cascade
CREATE TABLE t(a INT);
CREATE VIEW v AS SELECT a FROM t;
CREATE VIEW w AS SELECT a FROM v;
DROP TABLE t CASCADE;
SELECT * FROM v;
SELECT * FROM w;
CREATE SCHEMA s;
CREATE TABLE s.x(a INT);
DROP SCHEMA s;
DROP SCHEMA s CASCADE;

-- probe F033.drop_column
CREATE TABLE t(a INT, b INT, c INT);
INSERT INTO t VALUES (1, 2, 3);
ALTER TABLE t DROP COLUMN b;
SELECT * FROM t;
ALTER TABLE t DROP COLUMN b;
ALTER TABLE t DROP COLUMN IF EXISTS b;
CREATE VIEW v AS SELECT c FROM t;
ALTER TABLE t DROP COLUMN c RESTRICT;
ALTER TABLE t DROP COLUMN c CASCADE;
SELECT * FROM t;

-- probe F034.extended_revoke
CREATE ROLE w4f_r;
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1);
GRANT SELECT, UPDATE ON t TO w4f_r;
REVOKE UPDATE ON t FROM w4f_r;
SET ROLE w4f_r;
SELECT a FROM t;
UPDATE t SET b = 2;
RESET ROLE;
GRANT UPDATE (a) ON t TO w4f_r;
REVOKE UPDATE (a) ON t FROM w4f_r;
SET ROLE w4f_r;
UPDATE t SET a = 2;
RESET ROLE;

-- probe F035.revoke_cascade
CREATE ROLE w4f_a;
CREATE ROLE w4f_b;
CREATE TABLE t(a INT);
GRANT SELECT ON t TO w4f_a WITH GRANT OPTION;
SET ROLE w4f_a;
GRANT SELECT ON t TO w4f_b;
RESET ROLE;
REVOKE SELECT ON t FROM w4f_a;
REVOKE SELECT ON t FROM w4f_a CASCADE;
SELECT has_table_privilege('w4f_a', 't', 'SELECT'), has_table_privilege('w4f_b', 't', 'SELECT');

-- probe F036.revoke_non_owner
CREATE ROLE w4f_a;
CREATE ROLE w4f_b;
CREATE TABLE t(a INT);
GRANT SELECT ON t TO w4f_a WITH GRANT OPTION;
SET ROLE w4f_a;
GRANT SELECT ON t TO w4f_b;
REVOKE SELECT ON t FROM w4f_b;
RESET ROLE;
SET ROLE w4f_b;
SELECT a FROM t;
RESET ROLE;

-- probe F037.grant_option_for
CREATE ROLE w4f_a;
CREATE ROLE w4f_b;
CREATE TABLE t(a INT);
GRANT SELECT ON t TO w4f_a WITH GRANT OPTION;
REVOKE GRANT OPTION FOR SELECT ON t FROM w4f_a;
SET ROLE w4f_a;
SELECT a FROM t;
GRANT SELECT ON t TO w4f_b;
RESET ROLE;
SET ROLE w4f_b;
SELECT a FROM t;
RESET ROLE;

-- probe F038.revoke_grantable
CREATE ROLE w4f_a;
CREATE TABLE t(a INT);
GRANT SELECT ON t TO w4f_a WITH GRANT OPTION;
REVOKE SELECT ON t FROM w4f_a;
SET ROLE w4f_a;
SELECT a FROM t;
RESET ROLE;

-- probe F041-01.inner
CREATE TABLE a(id INT, x TEXT);
CREATE TABLE b(id INT, y TEXT);
INSERT INTO a VALUES (1, 'a1'), (2, 'a2'), (3, 'a3');
INSERT INTO b VALUES (2, 'b2'), (3, 'b3'), (3, 'b3b'), (4, 'b4');
SELECT a.x, b.y FROM a JOIN b ON a.id = b.id;
SELECT a.x, b.y FROM a, b WHERE a.id = b.id AND b.y <> 'b3b';

-- probe F041-02.inner_keyword
CREATE TABLE a(id INT);
CREATE TABLE b(id INT);
INSERT INTO a VALUES (1), (2);
INSERT INTO b VALUES (2), (3);
SELECT a.id, b.id FROM a INNER JOIN b ON a.id = b.id;

-- probe F041-03.left
CREATE TABLE a(id INT);
CREATE TABLE b(id INT, v TEXT);
INSERT INTO a VALUES (1), (2), (NULL);
INSERT INTO b VALUES (2, 'x');
SELECT a.id, b.v FROM a LEFT OUTER JOIN b ON a.id = b.id;
SELECT a.id, b.v FROM a LEFT JOIN b ON a.id = b.id WHERE b.v IS NULL;

-- probe F041-04.right
CREATE TABLE a(id INT);
CREATE TABLE b(id INT, v TEXT);
INSERT INTO a VALUES (2);
INSERT INTO b VALUES (1, 'x'), (2, 'y');
SELECT a.id, b.v FROM a RIGHT OUTER JOIN b ON a.id = b.id;
SELECT a.id, b.v FROM a RIGHT JOIN b ON a.id = b.id AND b.v = 'x';

-- probe F041-05.nested_outer
CREATE TABLE a(id INT);
CREATE TABLE b(id INT);
CREATE TABLE c(id INT);
INSERT INTO a VALUES (1), (2), (3);
INSERT INTO b VALUES (2), (3);
INSERT INTO c VALUES (3);
SELECT a.id, b.id, c.id FROM a LEFT JOIN b ON a.id = b.id LEFT JOIN c ON b.id = c.id;
SELECT a.id, b.id, c.id FROM a LEFT JOIN (b LEFT JOIN c ON b.id = c.id) ON a.id = b.id;

-- probe F041-07.outer_inner_mix
CREATE TABLE a(id INT);
CREATE TABLE b(id INT);
CREATE TABLE c(id INT);
INSERT INTO a VALUES (1), (2);
INSERT INTO b VALUES (1), (2);
INSERT INTO c VALUES (2);
SELECT a.id, b.id, c.id FROM a LEFT JOIN (b JOIN c ON b.id = c.id) ON a.id = b.id;
SELECT a.id, c.id FROM a LEFT JOIN b ON a.id = b.id JOIN c ON b.id = c.id;

-- probe F041-08.all_comparisons
CREATE TABLE a(v INT);
CREATE TABLE b(w INT);
INSERT INTO a VALUES (1), (2), (3);
INSERT INTO b VALUES (2);
SELECT a.v FROM a JOIN b ON a.v < b.w;
SELECT a.v FROM a JOIN b ON a.v >= b.w;
SELECT a.v FROM a JOIN b ON a.v <> b.w;
SELECT a.v, b.w FROM a LEFT JOIN b ON a.v > b.w;

-- probe F051-01.date
CREATE TABLE t(d DATE);
INSERT INTO t VALUES (DATE '2024-02-29'), ('1999-12-31');
SELECT d FROM t ORDER BY d;
SELECT DATE '2024-03-01' - DATE '2024-02-01', DATE '2024-03-01' - 1;
SELECT DATE '2023-02-29';

-- probe F051-02.time
SELECT TIME '12:34:56', TIME(0) '12:34:56.789', TIME '23:59:59.123456', pg_typeof(TIME '01:02');
CREATE TABLE t(a TIME(2));
INSERT INTO t VALUES ('10:11:12.345');
SELECT a FROM t;

-- probe F051-03.timestamp
SELECT TIMESTAMP '2024-01-02 03:04:05', TIMESTAMP(0) '2024-01-02 03:04:05.6', TIMESTAMP(6) '2024-01-02 03:04:05.123456';
CREATE TABLE t(a TIMESTAMP(3), b TIMESTAMP);
INSERT INTO t VALUES ('2024-05-06 07:08:09.12345', '2024-05-06 07:08:09.12345');
SELECT a, b FROM t;

-- probe F051-04.compare
SELECT DATE '2024-01-01' < DATE '2024-01-02', TIME '10:00' > TIME '09:59:59', TIMESTAMP '2024-01-01 00:00' = TIMESTAMP '2024-01-01', DATE '2024-01-02' > TIMESTAMP '2024-01-01 23:59';

-- probe F051-05.cast
SELECT CAST('2024-02-03' AS DATE), CAST(DATE '2024-02-03' AS VARCHAR(20)), CAST('12:00:01' AS TIME), CAST(TIMESTAMP '2024-01-01 10:00' AS TEXT), CAST(TIMESTAMP '2024-01-01 10:00' AS DATE);
SELECT CAST('2024-13-01' AS DATE);

-- probe F051-06.current_date
SELECT CURRENT_DATE = CURRENT_DATE, pg_typeof(CURRENT_DATE), CURRENT_DATE > DATE '2020-01-01';

-- probe F051-07.localtime
SELECT pg_typeof(LOCALTIME), pg_typeof(LOCALTIME(0)), LOCALTIME = LOCALTIME;

-- probe F051-08.localtimestamp
SELECT pg_typeof(LOCALTIMESTAMP), pg_typeof(LOCALTIMESTAMP(2)), LOCALTIMESTAMP = LOCALTIMESTAMP, LOCALTIMESTAMP > TIMESTAMP '2020-01-01';

-- probe F052.intervals
SELECT INTERVAL '1 day', INTERVAL '2 hours 30 minutes', INTERVAL '1' YEAR, INTERVAL '1-2' YEAR TO MONTH, INTERVAL '3 4:05:06' DAY TO SECOND;
SELECT DATE '2024-01-31' + INTERVAL '1 month', TIMESTAMP '2024-01-01 10:00' - INTERVAL '90 minutes', TIME '10:00' + INTERVAL '3 hours';
SELECT TIMESTAMP '2024-03-01' - TIMESTAMP '2024-02-28 12:00', INTERVAL '1 day' * 3, INTERVAL '1 hour' / 2, EXTRACT(YEAR FROM DATE '2024-05-06'), EXTRACT(MINUTE FROM INTERVAL '1:23:45');

-- probe F053.overlaps
SELECT (DATE '2024-01-01', DATE '2024-02-01') OVERLAPS (DATE '2024-01-15', DATE '2024-03-01'), (DATE '2024-01-01', DATE '2024-02-01') OVERLAPS (DATE '2024-02-01', DATE '2024-03-01'), (TIMESTAMP '2024-01-01', INTERVAL '1 day') OVERLAPS (TIMESTAMP '2024-01-01 12:00', INTERVAL '1 hour');

-- probe F081.union_views
CREATE TABLE a(v INT);
CREATE TABLE b(v INT);
INSERT INTO a VALUES (1), (2);
INSERT INTO b VALUES (2), (3);
CREATE VIEW u AS SELECT v FROM a UNION SELECT v FROM b;
CREATE VIEW e AS SELECT v FROM a EXCEPT SELECT v FROM b;
SELECT v FROM u;
SELECT v FROM e;

-- probe F111.isolation_levels
BEGIN ISOLATION LEVEL READ COMMITTED;
SHOW transaction_isolation;
COMMIT;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SHOW transaction_isolation;
COMMIT;
BEGIN;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SHOW transaction_isolation;
COMMIT;

-- probe F112.read_uncommitted
START TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SHOW transaction_isolation;
SELECT current_setting('transaction_isolation');
COMMIT;

-- probe F113.read_committed
CREATE TABLE t(a INT);
BEGIN ISOLATION LEVEL READ COMMITTED;
SHOW transaction_isolation;
INSERT INTO t VALUES (1);
SELECT a FROM t;
COMMIT;

-- probe F114.repeatable_read
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SHOW transaction_isolation;
COMMIT;
SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
SHOW transaction_isolation;
COMMIT;

-- probe F131-01.grouped_view_clauses
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 10), (1, 20), (2, 5), (3, 7), (3, 8);
CREATE VIEW gv AS SELECT g, sum(v) AS s, count(*) AS n FROM t GROUP BY g;
SELECT g, s FROM gv WHERE s > 10;
SELECT n, count(*) FROM gv GROUP BY n HAVING count(*) >= 1;

-- probe F131-02.grouped_view_join
CREATE TABLE t(g INT, v INT);
CREATE TABLE names(g INT, name TEXT);
INSERT INTO t VALUES (1, 10), (1, 20), (2, 5);
INSERT INTO names VALUES (1, 'one'), (2, 'two');
CREATE VIEW gv AS SELECT g, sum(v) AS s FROM t GROUP BY g;
SELECT names.name, gv.s FROM gv JOIN names ON names.g = gv.g;

-- probe F131-03.grouped_view_aggregate
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 10), (1, 20), (2, 5);
CREATE VIEW gv AS SELECT g, sum(v) AS s FROM t GROUP BY g;
SELECT max(s), min(s), sum(s), count(*) FROM gv;

-- probe F131-04.grouped_view_subquery
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 10), (1, 20), (2, 5), (2, 1);
CREATE VIEW gv AS SELECT g, sum(v) AS s FROM t GROUP BY g HAVING count(*) > 1;
SELECT g FROM gv WHERE s = (SELECT max(s) FROM gv);
SELECT g FROM t WHERE g IN (SELECT g FROM gv GROUP BY g HAVING max(s) > 6) GROUP BY g;

-- probe F131-05.grouped_view_single_row
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 10), (1, 20), (2, 5);
CREATE VIEW gv AS SELECT g, sum(v) AS s FROM t GROUP BY g;
SELECT s FROM gv WHERE g = 1;
SELECT count(*) FROM gv GROUP BY s HAVING s = 30;

-- probe F171.schemas
CREATE SCHEMA s1;
CREATE SCHEMA s2 AUTHORIZATION CURRENT_USER;
CREATE TABLE s1.t(a INT);
CREATE TABLE s2.t(a TEXT);
INSERT INTO s1.t VALUES (1);
INSERT INTO s2.t VALUES ('x');
SELECT a FROM s1.t;
SELECT a FROM s2.t;
SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 's_' ORDER BY 1;

-- probe F191.delete_actions
CREATE TABLE p(id INT PRIMARY KEY);
CREATE TABLE c1(id INT REFERENCES p ON DELETE CASCADE);
CREATE TABLE c2(id INT DEFAULT 2 REFERENCES p ON DELETE SET DEFAULT);
CREATE TABLE c3(id INT REFERENCES p ON DELETE SET NULL);
CREATE TABLE c4(id INT REFERENCES p ON DELETE NO ACTION);
INSERT INTO p VALUES (1), (2), (3);
INSERT INTO c1 VALUES (1), (2);
INSERT INTO c2 VALUES (1);
INSERT INTO c3 VALUES (1);
INSERT INTO c4 VALUES (3);
DELETE FROM p WHERE id = 1;
SELECT id FROM c1;
SELECT id FROM c2;
SELECT id FROM c3;
DELETE FROM p WHERE id = 3;

-- probe F200.truncate
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
TRUNCATE TABLE t;
SELECT count(*) FROM t;
INSERT INTO t VALUES (3);
BEGIN;
TRUNCATE t;
ROLLBACK;
SELECT a FROM t;
CREATE TABLE p(id INT PRIMARY KEY);
CREATE TABLE c(id INT REFERENCES p);
TRUNCATE p;
TRUNCATE p CASCADE;

-- probe F201.cast
SELECT CAST(1 AS TEXT), CAST('42' AS INTEGER), CAST(3.7 AS INTEGER), CAST(-3.5 AS INTEGER), CAST('1.5' AS NUMERIC(4,2)), CAST(1 AS BOOLEAN), CAST('t' AS BOOLEAN), CAST(NULL AS INT);
SELECT CAST('abc' AS INTEGER);
SELECT CAST(100000 AS SMALLINT);
SELECT CAST(12.345 AS DECIMAL(4,2)), CAST('abc' AS CHAR(2)), CAST(1e3 AS INT);

-- probe F202.truncate_restart
CREATE TABLE t(id INT GENERATED ALWAYS AS IDENTITY, v INT);
INSERT INTO t(v) VALUES (1), (2);
TRUNCATE t CONTINUE IDENTITY;
INSERT INTO t(v) VALUES (3);
SELECT id, v FROM t;
TRUNCATE t RESTART IDENTITY;
INSERT INTO t(v) VALUES (4);
SELECT id, v FROM t;

-- probe F221.explicit_defaults
CREATE TABLE t(a INT DEFAULT 1, b INT DEFAULT 2, c INT);
INSERT INTO t VALUES (DEFAULT, 5, DEFAULT);
INSERT INTO t(b, a) VALUES (DEFAULT, 9);
UPDATE t SET b = DEFAULT WHERE a = 1;
SELECT a, b, c FROM t ORDER BY a;

-- probe F222.default_values
CREATE TABLE t(a INT DEFAULT 1, b TEXT DEFAULT 'x', c INT);
INSERT INTO t DEFAULT VALUES;
INSERT INTO t DEFAULT VALUES;
SELECT a, b, c FROM t;

-- probe F231.privilege_tables
CREATE ROLE w4f_r;
CREATE TABLE t(a INT, b INT);
GRANT SELECT ON t TO w4f_r;
GRANT UPDATE (b) ON t TO w4f_r;
SELECT grantee, table_name, privilege_type, is_grantable FROM information_schema.table_privileges WHERE grantee = 'w4f_r';
SELECT grantee, table_name, column_name, privilege_type FROM information_schema.column_privileges WHERE grantee = 'w4f_r' ORDER BY column_name, privilege_type;
CREATE DOMAIN d AS INT;
GRANT USAGE ON DOMAIN d TO w4f_r;
SELECT grantee, object_name, object_type, privilege_type FROM information_schema.usage_privileges WHERE grantee = 'w4f_r';

-- probe F251.domains
CREATE DOMAIN pos AS INT CHECK (VALUE > 0);
CREATE DOMAIN code AS VARCHAR(3) NOT NULL DEFAULT 'abc';
CREATE TABLE t(a pos, b code);
INSERT INTO t(a) VALUES (1);
INSERT INTO t VALUES (0, 'x');
INSERT INTO t VALUES (2, NULL);
SELECT a, b, pg_typeof(a), pg_typeof(b) FROM t;
SELECT CAST(5 AS pos), CAST(-5 AS pos);
DROP DOMAIN pos;
DROP DOMAIN pos CASCADE;
SELECT column_name FROM information_schema.columns WHERE table_name = 't';

-- probe F261-01.simple_case
SELECT CASE 2 WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'other' END, CASE 5 WHEN 1 THEN 'one' END, CASE NULL::int WHEN NULL THEN 'null' ELSE 'not' END;

-- probe F261-02.searched_case
CREATE TABLE t(a INT);
INSERT INTO t VALUES (-1), (0), (1), (NULL);
SELECT a, CASE WHEN a < 0 THEN 'neg' WHEN a = 0 THEN 'zero' WHEN a > 0 THEN 'pos' ELSE 'null' END FROM t;
SELECT CASE WHEN false THEN 1/0 ELSE 1 END;

-- probe F261-03.nullif
SELECT NULLIF(1, 1), NULLIF(1, 2), NULLIF('a', 'b'), NULLIF(NULL::int, 1), pg_typeof(NULLIF(1, 2.5));

-- probe F261-04.coalesce
SELECT COALESCE(NULL, 2, 3), COALESCE(NULL::int, NULL), COALESCE('a', 'b'), COALESCE(NULL, 1.5, 2), pg_typeof(COALESCE(NULL, 1, 2.5));

-- probe F262.extended_case
SELECT CASE 5 WHEN 1 + 1 THEN 'a' WHEN 2 + 3 THEN 'b' END, CASE 'x' WHEN 'y' THEN 1 WHEN 'x' THEN 2 END;
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1), (1, 2);
SELECT CASE a WHEN b THEN 'eq' ELSE 'ne' END FROM t ORDER BY b;

-- probe F271.compound_literals
SELECT 'abc'
'def' AS x, 'a'
  'b'
  'c' AS y;

-- probe F281.like_enhancements
CREATE TABLE t(s TEXT, p TEXT, e TEXT);
INSERT INTO t VALUES ('abc', 'a%', '\'), ('a_c', 'a!_c', '!'), ('xyz', 'a%', '\');
SELECT s FROM t WHERE s LIKE p;
SELECT s FROM t WHERE s LIKE p ESCAPE e;
SELECT 'abc' LIKE lower('A%'), 'abc' LIKE 'a' || '%';

-- probe F292.unique_nulls
CREATE TABLE t(a INT UNIQUE NULLS NOT DISTINCT);
CREATE TABLE u(a INT UNIQUE NULLS DISTINCT);
INSERT INTO t VALUES (NULL);
INSERT INTO t VALUES (NULL);
INSERT INTO u VALUES (NULL), (NULL);
SELECT count(*) FROM t;
SELECT count(*) FROM u;

-- probe F302.intersect
CREATE TABLE a(v INT);
CREATE TABLE b(v INT);
INSERT INTO a VALUES (1), (2), (2), (3);
INSERT INTO b VALUES (2), (3), (3), (4);
SELECT v FROM a INTERSECT SELECT v FROM b;

-- probe F303.intersect_distinct
CREATE TABLE a(v INT);
CREATE TABLE b(v INT);
INSERT INTO a VALUES (1), (2), (2), (NULL);
INSERT INTO b VALUES (2), (2), (NULL);
SELECT v FROM a INTERSECT DISTINCT SELECT v FROM b;

-- probe F304.except_all
CREATE TABLE a(v INT);
CREATE TABLE b(v INT);
INSERT INTO a VALUES (1), (2), (2), (2), (NULL), (NULL);
INSERT INTO b VALUES (2), (NULL);
SELECT v FROM a EXCEPT ALL SELECT v FROM b;

-- probe F305.intersect_all
CREATE TABLE a(v INT);
CREATE TABLE b(v INT);
INSERT INTO a VALUES (1), (2), (2), (2), (NULL), (NULL);
INSERT INTO b VALUES (2), (2), (NULL);
SELECT v FROM a INTERSECT ALL SELECT v FROM b;

-- probe F311-01.create_schema
CREATE SCHEMA s;
CREATE SCHEMA IF NOT EXISTS s;
CREATE SCHEMA s;
CREATE SCHEMA t2 CREATE TABLE x(a INT) CREATE VIEW y AS SELECT a FROM x;
INSERT INTO t2.x VALUES (1);
SELECT a FROM t2.y;

-- probe F311-02.schema_table
CREATE SCHEMA s;
CREATE TABLE s.t(a INT PRIMARY KEY);
INSERT INTO s.t VALUES (1);
SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema = 's';

-- probe F311-03.schema_view
CREATE SCHEMA s;
CREATE TABLE s.t(a INT);
CREATE VIEW s.v AS SELECT a FROM s.t;
INSERT INTO s.t VALUES (4);
SELECT a FROM s.v;
SELECT * FROM v;

-- probe F311-04.check_option
CREATE TABLE t(a INT);
CREATE VIEW v AS SELECT a FROM t WHERE a > 0 WITH CHECK OPTION;
INSERT INTO v VALUES (1);
INSERT INTO v VALUES (-1);
UPDATE v SET a = -5;
SELECT a FROM t;

-- probe F311-05.schema_grant
CREATE ROLE w4f_r;
CREATE SCHEMA s;
CREATE TABLE s.t(a INT);
GRANT USAGE ON SCHEMA s TO w4f_r;
GRANT SELECT ON ALL TABLES IN SCHEMA s TO w4f_r;
SET ROLE w4f_r;
SELECT count(*) FROM s.t;
RESET ROLE;

-- probe F312.merge
CREATE TABLE t(id INT PRIMARY KEY, v INT);
CREATE TABLE s(id INT, v INT);
INSERT INTO t VALUES (1, 10), (2, 20);
INSERT INTO s VALUES (2, 200), (3, 300);
MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET v = s.v WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.v);
SELECT id, v FROM t ORDER BY id;

-- probe F313.enhanced_merge
CREATE TABLE t(id INT PRIMARY KEY, v INT);
CREATE TABLE s(id INT, v INT);
INSERT INTO t VALUES (1, 10), (2, 20), (3, 30);
INSERT INTO s VALUES (1, 1), (2, 2), (4, 4), (5, 5);
MERGE INTO t USING s ON t.id = s.id WHEN MATCHED AND s.v = 1 THEN UPDATE SET v = 100 WHEN MATCHED THEN UPDATE SET v = t.v + s.v WHEN NOT MATCHED AND s.v > 4 THEN INSERT (id, v) VALUES (s.id, s.v) WHEN NOT MATCHED THEN DO NOTHING;
SELECT id, v FROM t ORDER BY id;

-- probe F314.merge_delete
CREATE TABLE t(id INT PRIMARY KEY, v INT);
CREATE TABLE s(id INT, del BOOLEAN);
INSERT INTO t VALUES (1, 10), (2, 20), (3, 30);
INSERT INTO s VALUES (1, true), (2, false);
MERGE INTO t USING s ON t.id = s.id WHEN MATCHED AND s.del THEN DELETE WHEN MATCHED THEN UPDATE SET v = 0;
SELECT id, v FROM t ORDER BY id;

-- probe F321.user_authorization
CREATE ROLE w4f_u;
SELECT current_user = session_user, user = current_user;
SET SESSION AUTHORIZATION w4f_u;
SELECT current_user, session_user, user;
SET ROLE NONE;
RESET SESSION AUTHORIZATION;
SELECT current_user = session_user, current_user = 'w4f_u';

-- probe F341.usage_tables
CREATE DOMAIN d AS INT;
CREATE TABLE p(id INT PRIMARY KEY, x d);
CREATE TABLE c(pid INT CONSTRAINT c_fk REFERENCES p);
CREATE VIEW v AS SELECT id FROM p;
SELECT table_name, column_name FROM information_schema.column_domain_usage WHERE domain_name = 'd';
SELECT table_name, column_name, constraint_name FROM information_schema.constraint_column_usage WHERE constraint_name = 'c_fk';
SELECT table_name, column_name, ordinal_position FROM information_schema.key_column_usage WHERE constraint_name = 'c_fk';
SELECT view_name, table_name FROM information_schema.view_table_usage WHERE view_name = 'v';
SELECT view_name, table_name, column_name FROM information_schema.view_column_usage WHERE view_name = 'v';

-- probe F361.subprograms
CREATE FUNCTION add1(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x + 1';
CREATE PROCEDURE noop() LANGUAGE SQL AS 'SELECT 1';
SELECT add1(4);
CALL noop();

-- probe F381.extended_schema
CREATE TABLE t(a INT, b INT);
ALTER TABLE t ALTER COLUMN a SET DEFAULT 5;
INSERT INTO t(b) VALUES (1);
ALTER TABLE t ALTER COLUMN a DROP DEFAULT;
INSERT INTO t(b) VALUES (2);
ALTER TABLE t ADD CONSTRAINT b_pos CHECK (b > 0);
INSERT INTO t VALUES (1, -1);
ALTER TABLE t DROP CONSTRAINT b_pos;
INSERT INTO t VALUES (1, -1);
SELECT a, b FROM t ORDER BY b;

-- probe F382.alter_type
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, '10'), (2, '20');
ALTER TABLE t ALTER COLUMN a TYPE BIGINT;
ALTER TABLE t ALTER COLUMN b SET DATA TYPE INT USING b::int;
SELECT a, b, pg_typeof(a), pg_typeof(b) FROM t ORDER BY a;
ALTER TABLE t ALTER COLUMN b TYPE DATE;

-- probe F383.set_not_null
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, NULL);
ALTER TABLE t ALTER COLUMN a SET NOT NULL;
ALTER TABLE t ALTER COLUMN b SET NOT NULL;
INSERT INTO t VALUES (NULL, 1);
ALTER TABLE t ALTER COLUMN a DROP NOT NULL;
INSERT INTO t VALUES (NULL, 1);
SELECT count(*) FROM t;

-- probe F384.drop_identity
CREATE TABLE t(id INT GENERATED BY DEFAULT AS IDENTITY, v INT);
INSERT INTO t(v) VALUES (1);
ALTER TABLE t ALTER COLUMN id DROP IDENTITY;
INSERT INTO t(v) VALUES (2);
ALTER TABLE t ALTER COLUMN id DROP IDENTITY;
ALTER TABLE t ALTER COLUMN id DROP IDENTITY IF EXISTS;
SELECT id, v FROM t ORDER BY v;

-- probe F385.drop_expression
CREATE TABLE t(a INT, b INT GENERATED ALWAYS AS (a * 2) STORED);
INSERT INTO t(a) VALUES (1);
ALTER TABLE t ALTER COLUMN b DROP EXPRESSION;
INSERT INTO t VALUES (2, 5);
UPDATE t SET a = 10 WHERE a = 1;
SELECT a, b FROM t ORDER BY a;

-- probe F386.set_generation
CREATE TABLE t(id INT GENERATED ALWAYS AS IDENTITY, v INT);
INSERT INTO t(id, v) VALUES (100, 1);
ALTER TABLE t ALTER COLUMN id SET GENERATED BY DEFAULT;
INSERT INTO t(id, v) VALUES (100, 1);
ALTER TABLE t ALTER COLUMN id SET GENERATED ALWAYS;
INSERT INTO t(id, v) VALUES (101, 2);
SELECT id, v FROM t;

-- probe F387.alter_column
CREATE TABLE t(a INT, b VARCHAR(5));
ALTER TABLE t ALTER COLUMN a SET DEFAULT 1, ALTER COLUMN b TYPE VARCHAR(10);
INSERT INTO t(b) VALUES ('abcdefgh');
ALTER TABLE t ALTER COLUMN a ADD GENERATED BY DEFAULT AS IDENTITY;
ALTER TABLE t ALTER COLUMN a DROP DEFAULT;
ALTER TABLE t ALTER COLUMN a ADD GENERATED BY DEFAULT AS IDENTITY;
SELECT a, b FROM t;

-- probe F388.add_drop_constraint
CREATE TABLE p(id INT);
CREATE TABLE c(id INT, pid INT);
ALTER TABLE p ADD CONSTRAINT p_pk PRIMARY KEY (id);
ALTER TABLE c ADD CONSTRAINT c_fk FOREIGN KEY (pid) REFERENCES p(id);
ALTER TABLE c ADD CONSTRAINT c_u UNIQUE (id);
INSERT INTO c VALUES (1, 9);
ALTER TABLE c DROP CONSTRAINT c_fk;
INSERT INTO c VALUES (1, 9);
INSERT INTO c VALUES (1, 9);
ALTER TABLE c DROP CONSTRAINT c_u;
ALTER TABLE c DROP CONSTRAINT IF EXISTS c_u;
INSERT INTO c VALUES (1, 9);
SELECT count(*) FROM c;

-- probe F391.long_identifiers
CREATE TABLE abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk(c123456789012345678901234567890123456789012345678901234567890123 INT);
INSERT INTO abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk VALUES (1);
SELECT c123456789012345678901234567890123456789012345678901234567890123 FROM abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk;
SELECT length(table_name) FROM information_schema.tables WHERE table_schema = 'public';
SELECT 1 AS abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz;

-- probe F392.unicode_identifiers
CREATE TABLE U&"d\0061t\+000061"(U&"\00e9" INT);
INSERT INTO data VALUES (1);
SELECT "é" FROM U&"d!0061ta" UESCAPE '!';

-- probe F393.unicode_literals
SELECT U&'d\0061t\+000061', U&'\00e9t\00e9', U&'d!0061t' UESCAPE '!', length(U&'\+01F600');

-- probe F394.normal_form
SELECT normalize(U&'\0061\0301', NFC) = U&'\00E1', U&'\00E1' IS NFC NORMALIZED, U&'\0061\0301' IS NFC NORMALIZED, U&'\0061\0301' IS NOT NFD NORMALIZED, length(normalize(U&'\00E1', NFD));

-- probe F401.extended_join
CREATE TABLE a(id INT, x TEXT);
CREATE TABLE b(id INT, y TEXT);
INSERT INTO a VALUES (1, 'a1'), (2, 'a2');
INSERT INTO b VALUES (2, 'b2'), (3, 'b3');
SELECT * FROM a NATURAL JOIN b;
SELECT * FROM a FULL JOIN b USING (id);
SELECT a.x, b.y FROM a CROSS JOIN b WHERE a.id < b.id;

-- probe F402.join_arrays
CREATE TABLE a(k INT[], x TEXT);
CREATE TABLE b(k INT[], y TEXT);
INSERT INTO a VALUES ('{1,2}', 'a'), ('{3}', 'b');
INSERT INTO b VALUES ('{1,2}', 'c'), ('{4}', 'd');
SELECT k, x, y FROM a JOIN b USING (k);
SELECT * FROM a NATURAL JOIN b;

-- probe F404.join_using_alias
CREATE TABLE a(id INT, x TEXT);
CREATE TABLE b(id INT, y TEXT);
INSERT INTO a VALUES (1, 'a'), (2, 'b');
INSERT INTO b VALUES (2, 'c');
SELECT j.id, x, y FROM a JOIN b USING (id) AS j;
SELECT id FROM a JOIN b USING (id);
SELECT a.id, b.id, id FROM a FULL JOIN b USING (id);

-- probe F405.natural
CREATE TABLE a(id INT, k INT, x TEXT);
CREATE TABLE b(k INT, id INT, y TEXT);
INSERT INTO a VALUES (1, 1, 'a'), (2, 2, 'b');
INSERT INTO b VALUES (1, 1, 'c'), (2, 3, 'd');
SELECT * FROM a NATURAL JOIN b;
SELECT * FROM a NATURAL LEFT JOIN b;

-- probe F406.full_outer
CREATE TABLE a(id INT);
CREATE TABLE b(id INT);
INSERT INTO a VALUES (1), (2), (NULL);
INSERT INTO b VALUES (2), (3), (NULL);
SELECT a.id, b.id FROM a FULL OUTER JOIN b ON a.id = b.id;
SELECT a.id, b.id FROM a FULL JOIN b ON a.id = b.id AND a.id > 5;

-- probe F407.cross
CREATE TABLE a(x INT);
CREATE TABLE b(y TEXT);
INSERT INTO a VALUES (1), (2);
INSERT INTO b VALUES ('p'), ('q');
SELECT x, y FROM a CROSS JOIN b;
SELECT count(*) FROM a CROSS JOIN b CROSS JOIN a AS c;

-- probe F411.time_zone
SELECT TIMESTAMP WITH TIME ZONE '2024-01-01 12:00:00+02', TIMESTAMPTZ '2024-07-01 00:00:00 UTC', TIME WITH TIME ZONE '10:00:00+05:30';
SELECT TIMESTAMP '2024-01-01 12:00' AT TIME ZONE 'UTC', TIMESTAMPTZ '2024-01-01 12:00+00' AT TIME ZONE '+03:00', TIMESTAMPTZ '2024-01-01 12:00+00' AT LOCAL;
SET TIME ZONE '-05:00';
SELECT TIMESTAMPTZ '2024-01-01 12:00+00';
SET TIME ZONE 'UTC';
SHOW TimeZone;
SELECT EXTRACT(TIMEZONE_HOUR FROM TIMESTAMPTZ '2024-01-01 00:00+00');

-- probe F421.national_character
CREATE TABLE t(a NCHAR(3), b NATIONAL CHARACTER VARYING(5), c NCHAR VARYING(4), d NATIONAL CHAR(2));
INSERT INTO t VALUES (N'ab', N'xyz', 'pq', 'z');
SELECT a, b, c, d, pg_typeof(a), pg_typeof(b) FROM t;
SELECT N'national', pg_typeof(N'x');

-- probe F431.scroll_cursor
-- ordered
BEGIN;
DECLARE c SCROLL CURSOR FOR SELECT x FROM generate_series(1, 5) x ORDER BY x;
FETCH NEXT FROM c;
FETCH PRIOR FROM c;
FETCH LAST FROM c;
FETCH FIRST FROM c;
FETCH ABSOLUTE 3 FROM c;
FETCH RELATIVE -1 FROM c;
COMMIT;

-- probe F432.fetch_next
BEGIN;
DECLARE c CURSOR FOR SELECT x FROM generate_series(1, 3) x;
FETCH NEXT FROM c;
FETCH NEXT IN c;
COMMIT;

-- probe F433.fetch_first
BEGIN;
DECLARE c SCROLL CURSOR FOR SELECT x FROM generate_series(1, 3) x;
FETCH LAST FROM c;
FETCH FIRST FROM c;
FETCH FIRST FROM c;
COMMIT;

-- probe F434.fetch_last
BEGIN;
DECLARE c SCROLL CURSOR FOR SELECT x FROM generate_series(1, 3) x;
FETCH LAST FROM c;
FETCH NEXT FROM c;
FETCH LAST FROM c;
COMMIT;

-- probe F435.fetch_prior
BEGIN;
DECLARE c SCROLL CURSOR FOR SELECT x FROM generate_series(1, 3) x;
FETCH NEXT FROM c;
FETCH NEXT FROM c;
FETCH PRIOR FROM c;
FETCH PRIOR FROM c;
COMMIT;

-- probe F436.fetch_absolute
BEGIN;
DECLARE c SCROLL CURSOR FOR SELECT x FROM generate_series(10, 14) x;
FETCH ABSOLUTE 2 FROM c;
FETCH ABSOLUTE -1 FROM c;
FETCH ABSOLUTE 9 FROM c;
FETCH ABSOLUTE 1 FROM c;
COMMIT;

-- probe F437.fetch_relative
BEGIN;
DECLARE c SCROLL CURSOR FOR SELECT x FROM generate_series(10, 14) x;
FETCH RELATIVE 2 FROM c;
FETCH RELATIVE 2 FROM c;
FETCH RELATIVE -3 FROM c;
FETCH RELATIVE 0 FROM c;
COMMIT;

-- probe F438.scrollable
-- ordered
BEGIN;
DECLARE c SCROLL CURSOR FOR SELECT x FROM generate_series(1, 4) x;
FETCH FORWARD 2 FROM c;
FETCH BACKWARD 1 FROM c;
MOVE LAST IN c;
FETCH BACKWARD ALL FROM c;
COMMIT;
BEGIN;
DECLARE d NO SCROLL CURSOR FOR SELECT 1;
FETCH NEXT FROM d;
FETCH PRIOR FROM d;
ROLLBACK;

-- probe F441.extended_set_functions
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 2), (3, 4), (5, NULL);
SELECT sum(a * b), max(a + coalesce(b, 0)), count(a + b), avg(a * 2.0), min(CASE WHEN a > 1 THEN a END) FROM t;

-- probe F442.mixed_columns_set_functions
CREATE TABLE a(id INT, x INT);
CREATE TABLE b(id INT, y INT);
INSERT INTO a VALUES (1, 10), (2, 20);
INSERT INTO b VALUES (1, 1), (2, 2);
SELECT sum(a.x + b.y), max(a.x * b.y) FROM a JOIN b ON a.id = b.id;
SELECT a.id, (SELECT sum(a.x + b.y) FROM b) FROM a ORDER BY a.id;

-- probe F471.scalar_subquery
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
SELECT (SELECT max(a) FROM t), (SELECT a FROM t WHERE a > 5), (SELECT count(*) FROM t) + 1;
SELECT a, (SELECT a * 10) FROM t ORDER BY a;
UPDATE t SET a = (SELECT max(a) FROM t) + a;
SELECT a FROM t ORDER BY a;

-- probe F481.expanded_null
SELECT ROW(NULL, NULL) IS NULL, ROW(1, NULL) IS NULL, ROW(1, NULL) IS NOT NULL, ROW(1, 2) IS NOT NULL;
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (NULL, NULL), (1, NULL), (1, 1);
SELECT count(*) FROM t WHERE (a, b) IS NULL;
SELECT count(*) FROM t WHERE (a, b) IS NOT NULL;

-- probe F491.constraint_management
CREATE TABLE t(a INT CONSTRAINT a_pos CHECK (a > 0), b INT CONSTRAINT b_nn NOT NULL, CONSTRAINT t_pk PRIMARY KEY (a));
INSERT INTO t VALUES (-1, 1);
INSERT INTO t VALUES (1, NULL);
SELECT conname, contype FROM pg_constraint WHERE conrelid = 't'::regclass ORDER BY conname;
ALTER TABLE t DROP CONSTRAINT a_pos;
INSERT INTO t VALUES (-1, 1);
ALTER TABLE t RENAME CONSTRAINT t_pk TO t_key;
SELECT conname FROM pg_constraint WHERE conrelid = 't'::regclass AND contype = 'p';

-- probe F492.not_enforced
CREATE TABLE t(a INT, CONSTRAINT a_pos CHECK (a > 0) NOT ENFORCED);
INSERT INTO t VALUES (-1);
ALTER TABLE t ALTER CONSTRAINT a_pos ENFORCED;
DELETE FROM t;
ALTER TABLE t ALTER CONSTRAINT a_pos ENFORCED;
INSERT INTO t VALUES (-2);
SELECT conenforced FROM pg_constraint WHERE conname = 'a_pos';
CREATE TABLE p(id INT PRIMARY KEY);
CREATE TABLE c(pid INT REFERENCES p NOT ENFORCED);
INSERT INTO c VALUES (5);
SELECT count(*) FROM c;

-- probe F501-01.sql_features
SELECT column_name FROM information_schema.columns WHERE table_schema = 'information_schema' AND table_name = 'sql_features' ORDER BY ordinal_position;
SELECT count(*) > 0 FROM information_schema.sql_features WHERE feature_id = 'E011';

-- probe F501-02.sql_sizing
SELECT column_name FROM information_schema.columns WHERE table_schema = 'information_schema' AND table_name = 'sql_sizing' ORDER BY ordinal_position;
SELECT count(*) > 0 FROM information_schema.sql_sizing;

-- probe F502.documentation_tables
SELECT column_name FROM information_schema.columns WHERE table_schema = 'information_schema' AND table_name = 'sql_implementation_info' ORDER BY ordinal_position;
SELECT column_name FROM information_schema.columns WHERE table_schema = 'information_schema' AND table_name = 'sql_parts' ORDER BY ordinal_position;
SELECT count(*) > 0 FROM information_schema.sql_parts;

-- probe F531.temporary_tables
CREATE TEMPORARY TABLE tt(a INT);
CREATE TEMP TABLE tc(a INT) ON COMMIT DELETE ROWS;
INSERT INTO tt VALUES (1);
SELECT a FROM tt;
BEGIN;
INSERT INTO tc VALUES (1);
SELECT count(*) FROM tc;
COMMIT;
SELECT count(*) FROM tc;
SELECT table_type FROM information_schema.tables WHERE table_name = 'tt';
CREATE TEMP TABLE td(a INT) ON COMMIT DROP;

-- probe F555.seconds_precision
SELECT TIME(3) '10:00:00.123456', TIMESTAMP(1) '2024-01-01 10:00:00.15', TIMESTAMP(6) '2024-01-01 10:00:00.1234567', CAST(TIME '10:00:00.987654' AS TIME(4));
CREATE TABLE t(a TIMESTAMP(2), b TIME(5));
INSERT INTO t VALUES ('2024-01-01 00:00:00.999', '00:00:00.1234567');
SELECT a, b FROM t;

-- probe F561.full_value_expressions
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 2), (3, 4);
SELECT a FROM t WHERE a + 1 IN (b, b * 2, (SELECT max(b) FROM t));
SELECT a FROM t WHERE (a * 2) BETWEEN b - 1 AND b + 1;
SELECT CASE WHEN a > 1 THEN b ELSE a END * 10 FROM t ORDER BY 1;

-- probe F571.truth_tests
SELECT true IS TRUE, false IS NOT TRUE, NULL::boolean IS UNKNOWN, NULL::boolean IS NOT UNKNOWN, false IS FALSE, NULL::boolean IS NOT FALSE, (1 > 2) IS FALSE;
CREATE TABLE t(b BOOLEAN);
INSERT INTO t VALUES (true), (false), (NULL);
SELECT count(*) FROM t WHERE b IS NOT TRUE;

-- probe F591.derived_tables
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 2), (3, 4);
SELECT s.x FROM (SELECT a + b AS x FROM t) AS s WHERE s.x > 3;
SELECT * FROM (SELECT a FROM t WHERE a > 1) d;
SELECT d.c1 FROM (SELECT a, b FROM t) AS d(c1, c2) ORDER BY 1;
SELECT count(*) FROM (SELECT a FROM t) AS d1, (SELECT b FROM t) AS d2;

-- probe F641.row_constructors
SELECT ROW(1, 2) = ROW(1, 2), (1, 2) < (1, 3), (1, 'a') <> (1, 'b'), ROW(1, NULL) = ROW(1, 2), (2, 1) > (1, 9);
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1), (1, 2), (2, 1);
SELECT a, b FROM t WHERE (a, b) IN ((1, 2), (2, 1));
SELECT a, b FROM t WHERE (a, b) = (SELECT 1, 1);
UPDATE t SET (a, b) = (b, a) WHERE a = 1 AND b = 2;
SELECT a, b FROM t ORDER BY a, b;

-- probe F651.catalog_qualifier
CREATE TABLE t(a INT);
INSERT INTO w4_features_probe.public.t VALUES (1);
SELECT a FROM w4_features_probe.public.t;
SELECT w4_features_probe.public.t.a FROM w4_features_probe.public.t;
SELECT a FROM otherdb.public.t;

-- probe F661.simple_tables
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, 'x');
VALUES (1, 'a'), (2, 'b');
TABLE t;
SELECT * FROM (VALUES (1), (2)) AS v(n);
SELECT column1, column2 FROM (VALUES (1, 'a')) v;

-- probe F672.retrospective_check
CREATE TABLE t(d DATE CHECK (d <= CURRENT_DATE));
INSERT INTO t VALUES (DATE '2000-01-01');
INSERT INTO t VALUES (DATE '9999-01-01');
SELECT count(*) FROM t;

-- probe F690.collation
SELECT 'a' < 'B' COLLATE "C", 'a' < 'B' COLLATE "POSIX", 'abc' COLLATE "C" = 'abc';
CREATE TABLE t(s TEXT COLLATE "C");
INSERT INTO t VALUES ('b'), ('B'), ('a');
SELECT s FROM t ORDER BY s;
SELECT s FROM t ORDER BY s COLLATE "C" DESC;
SELECT collation_name FROM information_schema.columns WHERE table_name = 't';

-- probe F692.extended_collation
CREATE COLLATION mycoll (provider = libc, locale = 'C');
CREATE DOMAIN dc AS TEXT COLLATE "C";
CREATE TABLE t(a dc, b TEXT COLLATE mycoll);
INSERT INTO t VALUES ('b', 'B'), ('A', 'a');
SELECT a FROM t ORDER BY a;
SELECT b FROM t ORDER BY b COLLATE mycoll;
SELECT collation_name FROM information_schema.collations WHERE collation_name = 'mycoll';

-- probe F701.update_actions
CREATE TABLE p(id INT PRIMARY KEY);
CREATE TABLE c1(id INT REFERENCES p ON UPDATE CASCADE);
CREATE TABLE c2(id INT REFERENCES p ON UPDATE SET NULL);
CREATE TABLE c3(id INT DEFAULT 0 REFERENCES p ON UPDATE SET DEFAULT);
CREATE TABLE c4(id INT REFERENCES p ON UPDATE RESTRICT);
INSERT INTO p VALUES (0), (1), (2);
INSERT INTO c1 VALUES (1);
INSERT INTO c2 VALUES (1);
INSERT INTO c3 VALUES (1);
INSERT INTO c4 VALUES (2);
UPDATE p SET id = 10 WHERE id = 1;
SELECT id FROM c1;
SELECT id FROM c2;
SELECT id FROM c3;
UPDATE p SET id = 20 WHERE id = 2;

-- probe F711.alter_domain
CREATE DOMAIN d AS INT;
CREATE TABLE t(a d);
INSERT INTO t VALUES (-1), (NULL);
ALTER DOMAIN d SET DEFAULT 5;
INSERT INTO t DEFAULT VALUES;
ALTER DOMAIN d ADD CONSTRAINT d_pos CHECK (VALUE > 0);
DELETE FROM t WHERE a < 0;
ALTER DOMAIN d ADD CONSTRAINT d_pos CHECK (VALUE > 0);
INSERT INTO t VALUES (-2);
ALTER DOMAIN d DROP CONSTRAINT d_pos;
INSERT INTO t VALUES (-2);
ALTER DOMAIN d SET NOT NULL;
DELETE FROM t WHERE a IS NULL;
ALTER DOMAIN d SET NOT NULL;
ALTER DOMAIN d DROP DEFAULT;
SELECT a FROM t ORDER BY a;

-- probe F731.insert_column_privileges
CREATE ROLE w4f_r;
CREATE TABLE t(a INT, b INT);
GRANT INSERT (a) ON t TO w4f_r;
SET ROLE w4f_r;
INSERT INTO t(a) VALUES (1);
INSERT INTO t(a, b) VALUES (2, 2);
INSERT INTO t(b) VALUES (3);
RESET ROLE;
SELECT a, b FROM t;

-- probe F751.view_check_enhancements
CREATE TABLE t(a INT);
CREATE VIEW v1 AS SELECT a FROM t WHERE a > 0;
CREATE VIEW v2 AS SELECT a FROM v1 WHERE a < 10 WITH LOCAL CHECK OPTION;
CREATE VIEW v3 AS SELECT a FROM v1 WHERE a < 10 WITH CASCADED CHECK OPTION;
INSERT INTO v2 VALUES (-5);
INSERT INTO v2 VALUES (20);
INSERT INTO v3 VALUES (-5);
INSERT INTO v3 VALUES (5);
SELECT a FROM t ORDER BY a;
SELECT table_name, check_option FROM information_schema.views WHERE table_name IN ('v2', 'v3') ORDER BY 1;

-- probe F761.session_management
SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;
SHOW default_transaction_read_only;
CREATE TABLE t(a INT);
SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE;
CREATE TABLE t(a INT);
CREATE SCHEMA s;
SET SCHEMA 's';
SHOW search_path;
CREATE TABLE u(b INT);
SELECT table_schema FROM information_schema.tables WHERE table_name = 'u';
SET TIME ZONE INTERVAL '+02:00' HOUR TO MINUTE;
SHOW TimeZone;

-- probe F762.current_catalog
SELECT CURRENT_CATALOG, current_database() = CURRENT_CATALOG, pg_typeof(CURRENT_CATALOG);

-- probe F763.current_schema
SELECT CURRENT_SCHEMA, current_schema(), pg_typeof(CURRENT_SCHEMA);
CREATE SCHEMA s;
SET search_path TO s, public;
SELECT CURRENT_SCHEMA;

-- probe F781.self_reference
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
INSERT INTO t SELECT a + 10 FROM t;
UPDATE t SET a = a + (SELECT max(a) FROM t) WHERE a < 3;
DELETE FROM t WHERE a = (SELECT min(a) FROM t);
SELECT a FROM t ORDER BY a;

-- probe F791.insensitive_cursor
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
BEGIN;
DECLARE c INSENSITIVE CURSOR FOR SELECT a FROM t ORDER BY a;
INSERT INTO t VALUES (3);
FETCH ALL FROM c;
COMMIT;

-- probe F801.full_set_function
CREATE TABLE t(a INT, b INT);
INSERT INTO t VALUES (1, 1), (1, 2), (2, 2), (2, 2);
SELECT count(DISTINCT a), count(DISTINCT b), sum(DISTINCT b), count(*) FROM t;
SELECT a, count(DISTINCT b), avg(DISTINCT b) FROM t GROUP BY a ORDER BY a;

-- probe F850.order_by_query_expression
-- ordered
SELECT 3 AS x UNION SELECT 1 UNION SELECT 2 ORDER BY x DESC;
SELECT 1 AS x UNION ALL SELECT 2 ORDER BY 1;

-- probe F851.order_by_subquery
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (3), (1), (2);
SELECT a FROM (SELECT a FROM t ORDER BY a DESC) s;
SELECT a FROM t WHERE a IN (SELECT a FROM t ORDER BY a LIMIT 2) ORDER BY a;

-- probe F852.order_by_view
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (3), (1), (2);
CREATE VIEW v AS SELECT a FROM t ORDER BY a DESC;
SELECT a FROM v;

-- probe F855.nested_order_by
-- ordered
(SELECT 2 AS x ORDER BY 1) UNION ALL (SELECT 1 ORDER BY 1);
SELECT x FROM ((SELECT 3 AS x UNION SELECT 1 ORDER BY x LIMIT 1) UNION ALL SELECT 5) s ORDER BY x;

-- probe F856.nested_fetch_first
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
(SELECT a FROM t ORDER BY a FETCH FIRST 2 ROWS ONLY) UNION ALL (SELECT a FROM t ORDER BY a DESC FETCH FIRST 1 ROW ONLY);

-- probe F857.top_fetch_first
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
SELECT a FROM t ORDER BY a FETCH FIRST 2 ROWS ONLY;
SELECT a FROM t ORDER BY a DESC FETCH NEXT ROW ONLY;
SELECT a FROM t ORDER BY a FETCH FIRST 0 ROWS ONLY;

-- probe F858.fetch_first_subquery
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
SELECT a FROM t WHERE a IN (SELECT a FROM t ORDER BY a DESC FETCH FIRST 2 ROWS ONLY);
SELECT count(*) FROM (SELECT a FROM t FETCH FIRST 3 ROWS ONLY) s;

-- probe F859.fetch_first_view
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
CREATE VIEW v AS SELECT a FROM t ORDER BY a FETCH FIRST 2 ROWS ONLY;
SELECT a FROM v;

-- probe F860.dynamic_fetch_first
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
SELECT a FROM t ORDER BY a FETCH FIRST (1 + 1) ROWS ONLY;
PREPARE q(int) AS SELECT a FROM t ORDER BY a FETCH FIRST $1 ROWS ONLY;
EXECUTE q(3);
SELECT a FROM t ORDER BY a FETCH FIRST (SELECT 1) ROWS ONLY;

-- probe F861.top_offset
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
SELECT a FROM t ORDER BY a OFFSET 2 ROWS;
SELECT a FROM t ORDER BY a OFFSET 1 ROW FETCH NEXT 2 ROWS ONLY;
SELECT a FROM t ORDER BY a OFFSET 10;

-- probe F862.offset_subquery
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
SELECT a FROM t WHERE a IN (SELECT a FROM t ORDER BY a OFFSET 3 ROWS);
SELECT count(*) FROM (SELECT a FROM t ORDER BY a OFFSET 1) s;

-- probe F863.nested_offset
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
(SELECT a FROM t ORDER BY a OFFSET 3) UNION ALL (SELECT a FROM t ORDER BY a DESC OFFSET 3);

-- probe F864.offset_view
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
CREATE VIEW v AS SELECT a FROM t ORDER BY a OFFSET 2 ROWS;
SELECT a FROM v;

-- probe F865.dynamic_offset
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (3), (4);
SELECT a FROM t ORDER BY a OFFSET (1 + 2) ROWS;
PREPARE q(int) AS SELECT a FROM t ORDER BY a OFFSET $1;
EXECUTE q(2);

-- probe F867.with_ties
-- ordered
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2), (2), (3);
SELECT a FROM t ORDER BY a FETCH FIRST 2 ROWS WITH TIES;
SELECT a FROM t ORDER BY a DESC FETCH FIRST 1 ROW WITH TIES;
SELECT a FROM t FETCH FIRST 2 ROWS WITH TIES;

-- probe F868.order_by_grouped
-- ordered
CREATE TABLE t(g INT, v INT);
INSERT INTO t VALUES (1, 10), (2, 5), (2, 6), (3, 1);
SELECT g, sum(v) FROM t GROUP BY g ORDER BY sum(v) DESC;
SELECT g FROM t GROUP BY g ORDER BY count(*) DESC, g;
SELECT g, max(v) AS m FROM t GROUP BY g ORDER BY m;

-- probe F869.implementation_info
SELECT implementation_info_name FROM information_schema.sql_implementation_info WHERE implementation_info_id IN ('17', '18') ORDER BY implementation_info_id;
SELECT count(*) > 0 FROM information_schema.sql_implementation_info;
