\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA view_replace_hooks;
SET LOCAL search_path=view_replace_hooks,pg_catalog;
CREATE TABLE hook_source(id INT PRIMARY KEY,v INT);
INSERT INTO hook_source VALUES (1,5);
CREATE VIEW hook_view AS SELECT id,v FROM hook_source;
CREATE FUNCTION view_hook() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN UPDATE hook_source SET v=NEW.v WHERE id=OLD.id; RETURN NEW; END$$;
CREATE TRIGGER replacement_hook INSTEAD OF UPDATE ON hook_view FOR EACH ROW EXECUTE FUNCTION view_hook();
CREATE OR REPLACE VIEW hook_view AS SELECT id,v+10 AS v FROM hook_source;
UPDATE hook_view SET v=99 WHERE id=1;
DO $$BEGIN
 IF (SELECT v FROM hook_source) <> 99 OR (SELECT v FROM hook_view) <> 109 THEN RAISE EXCEPTION 'replacement lost update hook'; END IF;
END$$;
CREATE RULE keep_hook_rows AS ON DELETE TO hook_view DO INSTEAD NOTHING;
CREATE OR REPLACE VIEW hook_view AS SELECT id,v*2 AS v FROM hook_source;
DELETE FROM hook_view;
DO $$BEGIN
 IF (SELECT v FROM hook_source) <> 99 OR (SELECT v FROM hook_view) <> 198 THEN RAISE EXCEPTION 'replacement lost rule'; END IF;
END$$;
SELECT json_build_object('oracle',version(),'base',(SELECT v FROM hook_source),'view',(SELECT v FROM hook_view),'triggers',(SELECT count(*) FROM pg_trigger WHERE tgrelid='hook_view'::regclass),'rules',(SELECT count(*) FROM pg_rewrite WHERE ev_class='hook_view'::regclass));
ROLLBACK;
