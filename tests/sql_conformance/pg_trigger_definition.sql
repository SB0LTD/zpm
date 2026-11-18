CREATE TABLE hits(id INT PRIMARY KEY, v INT, "Val L" INT);
CREATE FUNCTION bump() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN NEW.v := NEW.v + 1; RETURN NEW; END$$;
CREATE TRIGGER "watch""list" BEFORE UPDATE OF "Val L" OR INSERT ON hits FOR EACH ROW EXECUTE FUNCTION bump('it''s', '');
SELECT tgname, tgrelid <> 0, tgfoid <> 0, tgtype, tgenabled, tgisinternal, tgnargs, tgparentid
FROM pg_catalog.pg_trigger WHERE tgname = 'watch"list';
SELECT pg_catalog.pg_get_triggerdef(oid, true) FROM pg_catalog.pg_trigger WHERE tgname = 'watch"list';
SELECT pg_catalog.pg_get_triggerdef(oid) FROM pg_catalog.pg_trigger WHERE tgname = 'watch"list';
SELECT pg_catalog.pg_get_triggerdef(0::oid) IS NULL, pg_catalog.pg_get_triggerdef(NULL::oid) IS NULL;
SELECT pg_catalog.pg_get_triggerdef(oid, NULL::boolean) IS NULL FROM pg_catalog.pg_trigger WHERE tgname = 'watch"list';
SELECT t.tgname, pg_catalog.pg_get_triggerdef(t.oid, true), t.tgenabled, t.tgisinternal,
  CASE WHEN t.tgparentid != 0 THEN
    (SELECT u.tgrelid::pg_catalog.regclass
     FROM pg_catalog.pg_trigger AS u,
          pg_catalog.pg_partition_ancestors(t.tgrelid) WITH ORDINALITY AS a(relid, depth)
     WHERE u.tgname = t.tgname AND u.tgrelid = a.relid
           AND u.tgparentid = 0
     ORDER BY a.depth LIMIT 1)
  END AS parent
FROM pg_catalog.pg_trigger t
WHERE t.tgname = 'watch"list' AND (NOT t.tgisinternal OR (t.tgisinternal AND t.tgenabled = 'D'))
ORDER BY 1;
CREATE TRIGGER sample BEFORE UPDATE ON hits FOR EACH ROW WHEN (new.v > 0) EXECUTE FUNCTION bump();
SELECT pg_catalog.pg_get_triggerdef(oid, true) FROM pg_catalog.pg_trigger WHERE tgname = 'sample';
INSERT INTO hits VALUES (1, 2, 0);
SELECT v FROM hits;
DROP TRIGGER "watch""list" ON hits;
SELECT count(*) FROM pg_catalog.pg_trigger WHERE tgname = 'watch"list';
