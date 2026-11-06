# SQL catalog and security objects (conformance lane B11, wave 3)

Branch `b11/catalog-security` closes seven smoke programs of the
118-program inventory test-first: PG.CATALOG, PG.SECURITY.ROLE,
PG.SECURITY.RLS, PG.UTILITY.COMMENT, PG.INTEGRATION.EXTENSION,
PG.INTEGRATION.FOREIGN and PG.INTEGRATION.REPLICATION. On main 4c028a6
(with the routines and json-agg lanes) the unchanged driver moves from 89
smoke passes to 96; it still exits 1
(SqlConformanceIncomplete) and no other program changed.
PG.TYPE.ENUM_DOMAIN_COMPOSITE stays open (below). A smoke pass is not family
closure.

`contract-sql-catalog-security` (tests/test_sql_catalog_security.sig)
covers every program as the driver runs it, then values and PostgreSQL text
output, column names, type OIDs and typmods, NULLs, exact errors with the
state unchanged afterwards (atomicity), transactional abort, waits on
another transaction's uncommitted objects and table locks, capacity limits
(54000), and replay: every committed record is applied to a replica that
must answer the catalog probes exactly like the primary, and crafted
records fail closed. Only the seven oracle programs are native-verified;
every other expectation follows the PostgreSQL 18 documentation and source
(acl.c, aclchk.c, user.c, variable.c, rowsecurity.c, comment.c,
foreigncmds.c, publicationcmds.c) and is pending native verification.

## Design

One versioned store (src/core/sql/catalog_objects.sig) holds every new
catalog object as an MVCC version: created by a transaction (xmin),
deleted by one (xmax), visible under the same snapshot rules as table rows.
A change (ALTER ROLE, a GRANT to an existing grantee, a new comment)
deletes the old version and creates the new one, so every statement is
transactional and atomic. Kinds and identities: role (OID), member (role,
member; OID for pg_auth_members), acl (table, grantee or PUBLIC), relation
(table: owner, RLS flags), policy (OID), comment (classoid, object,
column), foreign-data wrapper, server and publication (OID). OIDs come from
the database counter like tables and sequences; an aborted creator returns
its OID when it is the newest.

Roles are SQL-level. The bootstrap superuser is OID 10, named `ramsql`
(the owner the views already reported); RAMSQL authenticates its single
SCRAM user and every wire session runs as that role. CREATE ROLE makes
roles without passwords (PASSWORD is 0A000): they never authenticate on
the wire and are entered with SET ROLE. `session_user` is the session
state's `session_role` (10 unless an embedding caller installs another),
`current_user` the SET ROLE value or the session user.

## Scope

| Program | Implemented | Not covered |
|---|---|---|
| PG.CATALOG | pg_namespace / schemata list pg_toast (99); it is always empty and closed to CREATE TABLE / DROP SCHEMA | TOAST storage |
| PG.SECURITY.ROLE | CREATE / ALTER (attributes, CONNECTION LIMIT, RENAME) / DROP ROLE, CREATE ROLE ... IN ROLE, GRANT / REVOKE role [WITH ADMIN OPTION], GRANT / REVOKE table privileges [WITH GRANT OPTION] incl. ALL and PUBLIC, ALTER TABLE OWNER TO, SET [LOCAL] ROLE / RESET ROLE / SHOW role, current_user / session_user / current_role / user; 42501 checks on reads (FROM items, also subqueries), INSERT / UPDATE / DELETE / TRUNCATE / MERGE / COPY FROM, ownership for ALTER / DROP / REFRESH / CREATE INDEX, CREATE only for superusers (PostgreSQL 15+ public schema); pg_roles, pg_authid (superusers), pg_auth_members, pg_tables, information_schema.table_privileges | column privileges, privileges on sequences, schemas, databases, functions; predefined roles (pg_read_all_data ...); passwords and VALID UNTIL; PostgreSQL 16 INHERIT / SET grant options; grant chains (one aclitem per table and grantee, grantor = owner); CREATEROLE creators are not made ADMIN of their roles; SET SESSION AUTHORIZATION |
| PG.SECURITY.RLS | ENABLE / DISABLE / [NO] FORCE ROW LEVEL SECURITY, CREATE / ALTER (RENAME, TO, USING, WITH CHECK) / DROP POLICY, AS PERMISSIVE / RESTRICTIVE, FOR ALL / SELECT / INSERT / UPDATE / DELETE, TO roles / PUBLIC; reads see USING-filtered rows (permissive OR, restrictive AND, no policy = deny), UPDATE / DELETE targets are filtered (plus SELECT policies when they filter or return), new rows of INSERT / UPDATE must pass WITH CHECK (USING when absent; NULL fails) or 42501; owners bypass unless FORCE, superusers and BYPASSRLS always; views run with their owner's rights; pg_policy, pg_policies (canonical qual text) | subqueries in policy expressions (0A000, bound like CHECK); RLS on partitioned or inheritance parents, COPY FROM, MERGE, ON CONFLICT and data-modifying WITH under RLS (0A000); RETURNING rows are not checked against SELECT policies; WITH CHECK runs after CHECK constraints (PostgreSQL checks it first); dropping a column a policy names is not prevented (the policy then fails when used) |
| PG.UTILITY.COMMENT | COMMENT ON TABLE / VIEW / MATERIALIZED VIEW / COLUMN / SEQUENCE / SCHEMA / ROLE / POLICY / FOREIGN DATA WRAPPER / SERVER / PUBLICATION IS 'text' / NULL ('' removes too); obj_description(oid [, catalog]), col_description, shobj_description; pg_description, pg_shdescription; comments die with their object and column comments follow ALTER TABLE | comments on indexes, extensions, functions, types, constraints (0A000) |
| PG.INTEGRATION.EXTENSION | pg_extension's plpgsql row; CREATE EXTENSION plpgsql is 42710 (IF NOT EXISTS: no-op) | every other extension (0A000), DROP / ALTER EXTENSION |
| PG.INTEGRATION.FOREIGN | CREATE / DROP FOREIGN DATA WRAPPER [NO HANDLER] [NO VALIDATOR] (superusers), CREATE [IF NOT EXISTS] / DROP SERVER [TYPE] [VERSION] (USAGE = wrapper owner); DROP ... CASCADE; pg_foreign_data_wrapper, pg_foreign_server. Catalog entries only | handlers, validators, OPTIONS, user mappings, foreign tables, IMPORT FOREIGN SCHEMA (0A000) |
| PG.INTEGRATION.REPLICATION | CREATE PUBLICATION [FOR ALL TABLES] [WITH (publish = ..., publish_via_partition_root)], DROP PUBLICATION (superusers); pg_publication. Catalog entries only | FOR TABLE / TABLES IN SCHEMA, ALTER PUBLICATION, logical decoding, subscriptions (0A000) |

## PG.TYPE.ENUM_DOMAIN_COMPOSITE

Not implemented. The oracle expects the enum and composite type OIDs 18673
and 18682. PostgreSQL's allocation for the program's statements is
deterministic relative to its start: the enum takes an array OID (18672),
its type OID (18673) and one even OID per label (18674, 18676); the domain
an array OID, its type and its CHECK constraint (18677-18679); the
composite a relation, an array and its row type (18680-18682). The start,
however, is the native cluster's OID counter after every earlier program of
the oracle run (each in a rolled-back transaction, OIDs are never reused):
2,278 OIDs above where a fresh database would be after the base fixture.
The driver runs every program on a fresh ZPM database whose counter starts
at 16384, and ZPM allocates two OIDs per keyed table where PostgreSQL
allocates five. The only way to report 18673 would be to seed the counter
with the oracle's value, which is special-casing an expected value; the
program therefore stays incomplete. Real support would also need a type
catalog (versioned pg_type / pg_enum / pg_attribute rows), a dynamic type
identity whose OID reaches result metadata (`sql.typeOid` maps the u8
DataType statically; widening DataType or adding per-column OIDs to Result
touches every lane), type-name resolution in the parser and binder,
domain constraint checks (23514 / 23502), composite row values and their
I/O, and table definition format 4 for columns of user-defined types. The
lane's reserved value tags 36-41 and definition format 4 stay unused.

## Errors (SQLSTATE)

New: 42501 InsufficientPrivilege (privileges, ownership, role attributes,
RLS WITH CHECK, SET ROLE to a role the session user is not a member of),
42939 ReservedName (public, none, pg_*), 55006 ObjectInUse (DROP ROLE of
the current or session user), 0LP01 InvalidGrantOperation (role membership
cycles). Also used: 42710, 42704, 2BP01, 42P01, 42703, 42809, 3F000,
42601, 42804, 0A000, 22023 (unknown SET ROLE target, invalid publish
option, CONNECTION LIMIT below -1), 25006 (catalog statements in READ ONLY
transactions), 54000.

## Durability

Change-record op 70 `object_create` carries a whole version (kind, OID,
target, grantee, sub, owner, flags, grant flags, name, role list, text,
split) and op 71 `object_drop` the identity of the version it deletes; ops
72-79 stay reserved (unknown today: UnsupportedLogVersion). A DROP writes
the drops of its dependents (grants, owner entry, policies, comments,
memberships, servers) in the same record. Replay validates every field
(InvalidChangeRecord), OIDs (unused, at or above 16384), identities and
names (unique), references when created, and after the whole record that
no live object names a dropped table, role, wrapper or object
(ChangeRecordConflict); the validation overlay mirrors the store entry by
entry, so a validated record applies infallibly. Existing records, ops and
value tags are unchanged, and the table definition format is not bumped.

## Concurrency

A statement waits (parks) for another live transaction that holds an
uncommitted version with the same identity or name, or one that names the
object it drops; it re-snapshots when it has not written yet. GRANT,
REVOKE and COMMENT on a table take AccessShare (so DROP TABLE waits for
them); CREATE / ALTER / DROP POLICY, ENABLE / FORCE ROW LEVEL SECURITY and
OWNER TO take AccessExclusive, as PostgreSQL does.

## Limits

Config.catalog_objects (32) object versions, including uncommitted ones and
dead ones until reclaimed (TableCapacity 54000); Config.object_text_bytes
(256) of comment or policy text (TextCapacity 54000); Config.policy_roles
(4) roles per policy (ProgramLimitExceeded 54000); eight names per GRANT,
REVOKE, DROP or IN ROLE list (catalog_objects.list_capacity, 54000).
Nothing allocates. Detached (parallel) store reads run only for sessions
without SET ROLE; the others take the serialized, privilege-checked path.
PREPARE and Describe check no privileges (EXECUTE does), as PostgreSQL's
parse analysis. Statements run by CALL and DO use the invoker's
privileges and row security (SECURITY INVOKER); EXECUTE privileges on
functions and procedures are not modelled, and CREATE FUNCTION body
analysis checks no table privileges.
