SHOW default_table_access_method;
SELECT current_setting('default_tablespace') = '';
SET default_table_access_method = HEAP;
SET default_table_access_method = "heap";
SELECT set_config('default_tablespace', 'pg_default', false);
CREATE TABLE placement_probe (id INT PRIMARY KEY);
SELECT a.amname, c.reltablespace FROM pg_class c JOIN pg_am a ON c.relam = a.oid WHERE c.relname = 'placement_probe';
BEGIN;
SET LOCAL default_tablespace = '';
SELECT current_setting('default_tablespace') = '';
ROLLBACK;
SHOW default_tablespace;
RESET default_tablespace;
SELECT current_setting('default_tablespace') = '';
\set ON_ERROR_STOP off
SET default_table_access_method = 'Heap';
\echo :SQLSTATE
SET default_table_access_method = fake;
\echo :SQLSTATE
SET default_table_access_method = btree;
\echo :SQLSTATE
SET default_tablespace = fake;
\echo :SQLSTATE
SET default_tablespace = pg_global;
CREATE TABLE global_placement (id INT);
\echo :SQLSTATE
