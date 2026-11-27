\set ON_ERROR_STOP on
BEGIN;
CREATE ROLE view_qual_owner;
CREATE SCHEMA view_privilege_oracle;
CREATE TABLE view_privilege_oracle.source(id int);
INSERT INTO view_privilege_oracle.source VALUES (7);
CREATE VIEW view_privilege_oracle.v AS SELECT id FROM view_privilege_oracle.source;
ALTER VIEW view_privilege_oracle.v OWNER TO view_qual_owner;
GRANT USAGE ON SCHEMA view_privilege_oracle TO view_qual_owner;
GRANT SELECT ON view_privilege_oracle.source TO view_qual_owner;
SET LOCAL ROLE view_qual_owner;
DO $$BEGIN
 BEGIN
   EXECUTE 'CREATE OR REPLACE VIEW view_privilege_oracle.v AS SELECT id+1 AS id FROM view_privilege_oracle.source';
   RAISE EXCEPTION 'replacement without schema CREATE was accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END$$;
RESET ROLE;
GRANT CREATE ON SCHEMA view_privilege_oracle TO view_qual_owner;
SET LOCAL ROLE view_qual_owner;
CREATE OR REPLACE VIEW view_privilege_oracle.v AS SELECT id+1 AS id FROM view_privilege_oracle.source;
SELECT json_build_object('oracle',version(),'role',current_user,'value',id) FROM view_privilege_oracle.v;
RESET ROLE;
DO $$BEGIN IF has_schema_privilege('view_qual_owner','public','CREATE') THEN RAISE EXCEPTION 'oracle needs default public ACL'; END IF; END$$;
CREATE VIEW public.view_qual_public AS SELECT id FROM view_privilege_oracle.source;
ALTER VIEW public.view_qual_public OWNER TO view_qual_owner;
SET LOCAL ROLE view_qual_owner;
DO $$BEGIN
 BEGIN
   EXECUTE 'CREATE OR REPLACE VIEW public.view_qual_public AS SELECT id+2 AS id FROM view_privilege_oracle.source';
   RAISE EXCEPTION 'public replacement without CREATE was accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END$$;
RESET ROLE;
CREATE SCHEMA view_owned_oracle AUTHORIZATION view_qual_owner;
CREATE VIEW view_owned_oracle.v AS SELECT id FROM view_privilege_oracle.source;
ALTER VIEW view_owned_oracle.v OWNER TO view_qual_owner;
SET LOCAL ROLE view_qual_owner;
CREATE OR REPLACE VIEW view_owned_oracle.v AS SELECT id+3 AS id FROM view_privilege_oracle.source;
SELECT json_build_object('owned_schema_value',id) FROM view_owned_oracle.v;
ROLLBACK;
