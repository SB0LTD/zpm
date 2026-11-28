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

### Opt-in authenticated role mapping

Embedders using the shared PostgreSQL codec and store can configure a session
with `configureRoleAuthentication`. It uses the same SCRAM verifier and fresh
nonce as the existing configuration. After a successful proof, the store looks
up the verifier's exact username in the committed SQL role catalog and sets the
connection's SQL session identity before sending readiness. Ordinary roles must
have LOGIN and an unlimited connection count. Finite role connection limits
require admission accounting and are denied by this entry point. The bootstrap
role is available under its exact name `ramsql` when provisioned with that
username. Missing or ineligible roles fail the authentication exchange.

`configureAuthentication` retains the caller's existing session identity.
Credential provisioning, multi-verifier selection, TLS, database admission and
role connection accounting remain separate. RAMSQL's current configuration
continues to use its existing single-verifier bootstrap path.

## Scope

| Program | Implemented | Not covered |
|---|---|---|
| PG.CATALOG | pg_namespace / schemata list pg_toast (99); it is always empty and closed to CREATE TABLE / DROP SCHEMA | TOAST storage |
| PG.SECURITY.ROLE | CREATE / ALTER (attributes, CONNECTION LIMIT, RENAME) / DROP ROLE, CREATE ROLE ... IN ROLE, GRANT / REVOKE role [WITH ADMIN OPTION], GRANT / REVOKE table privileges [WITH GRANT OPTION] incl. ALL and PUBLIC, ALTER TABLE OWNER TO, SET [LOCAL] ROLE / RESET ROLE / SHOW role, current_user / session_user / current_role / user; 42501 checks on reads (FROM items, also subqueries), INSERT / UPDATE / DELETE / TRUNCATE / MERGE / COPY FROM, ownership for ALTER / DROP / REFRESH / CREATE INDEX, CREATE only for superusers (PostgreSQL 15+ public schema); pg_roles, pg_authid (superusers), pg_auth_members, pg_tables, information_schema.table_privileges | privileges on databases; passwords and VALID UNTIL; CREATEROLE creators are not made ADMIN of their roles. Column, sequence, schema and type privileges, grant chains with grantors, predefined roles and role grants keyed by grantor: [SQL_PRIVILEGES.md](SQL_PRIVILEGES.md) (wave 5) |
| PG.SECURITY.RLS | ENABLE / DISABLE / [NO] FORCE ROW LEVEL SECURITY, CREATE / ALTER (RENAME, TO, USING, WITH CHECK) / DROP POLICY, AS PERMISSIVE / RESTRICTIVE, FOR ALL / SELECT / INSERT / UPDATE / DELETE, TO roles / PUBLIC; reads see USING-filtered rows (permissive OR, restrictive AND, no policy = deny), UPDATE / DELETE targets are filtered (plus SELECT policies when they filter or return), new rows of INSERT / UPDATE must pass WITH CHECK (USING when absent; NULL fails) or 42501; owners bypass unless FORCE, superusers and BYPASSRLS always; views run with their owner's rights; pg_policy, pg_policies (canonical qual text) | subqueries in policy expressions (0A000, bound like CHECK); COPY FROM, MERGE, ON CONFLICT and data-modifying WITH under RLS (0A000); dropping a column a policy names is not prevented (the policy then fails when used). RLS on partitioned and inheritance parents, SELECT policies on returned rows and WITH CHECK before constraints: ddl-dml wave 4 (docs/SQL_DDL_DML.md) |
| PG.UTILITY.COMMENT | COMMENT ON TABLE / VIEW / MATERIALIZED VIEW / COLUMN / SEQUENCE / SCHEMA / ROLE / POLICY / FOREIGN DATA WRAPPER / SERVER / PUBLICATION IS 'text' / NULL ('' removes too); obj_description(oid [, catalog]), col_description, shobj_description; pg_description, pg_shdescription; comments die with their object and column comments follow ALTER TABLE | comments on indexes, extensions, functions, types, constraints (0A000) |
| PG.INTEGRATION.EXTENSION | pg_extension's plpgsql row; CREATE EXTENSION plpgsql is 42710 (IF NOT EXISTS: no-op) | every other extension (0A000), DROP / ALTER EXTENSION |
| PG.INTEGRATION.FOREIGN | CREATE / DROP FOREIGN DATA WRAPPER [NO HANDLER] [NO VALIDATOR] (superusers), CREATE [IF NOT EXISTS] / DROP SERVER [TYPE] [VERSION] (USAGE = wrapper owner); DROP ... CASCADE; pg_foreign_data_wrapper, pg_foreign_server. Catalog entries only | handlers, validators, OPTIONS, user mappings, foreign tables, IMPORT FOREIGN SCHEMA (0A000) |
| PG.INTEGRATION.REPLICATION | CREATE PUBLICATION [FOR ALL TABLES] [WITH (publish = ..., publish_via_partition_root)], DROP PUBLICATION (superusers); pg_publication. Catalog entries only | FOR TABLE / TABLES IN SCHEMA, ALTER PUBLICATION, logical decoding, subscriptions (0A000) |

`information_schema` (B11 wave 5) is described below. `pg_class` and
`pg_attribute` expose relation metadata to ordinary roles. The privilege
model (column, sequence, schema and type ACLs, grant options, grantors,
predefined roles) is the privileges lane's; see
[SQL_PRIVILEGES.md](SQL_PRIVILEGES.md).

## information_schema (B11 wave 5, catalog lane)

Every relation of PostgreSQL 18's information_schema exists: the 60 views,
the four tables `sql_features`, `sql_implementation_info`, `sql_parts` and
`sql_sizing`, and the five internal `_pg_*` helper views
(src/core/sql/information_schema.sig, rows in information_schema_rows.sig).
Nothing is stored: each is computed at scan time from the versioned catalogs
under the statement snapshot, so a transaction sees its own uncommitted DDL,
an aborted one leaves no trace, and a replica built from the change records
answers like its primary. No change-log op, value tag or definition format
was added.

Shapes. Column names, order and types are generated from native PostgreSQL
18.7 (tools/gen_information_schema.py into information_schema_data.sig).
Columns carry their information_schema domain and, as PostgreSQL does, the
wire reports the domain's base type: `sql_identifier` name (19/64/-1),
`cardinal_number` int4, `character_data` varchar, `yes_or_no` varchar(3)
(typmod 7), `time_stamp` timestamptz(2). `information_schema.columns`
reports those domains (`domain_name`), collation "C" for the string columns
of catalog tables and information_schema relations, and the five domains
appear in `domains`, `domain_constraints`, `domain_udt_usage`,
`check_constraints`, `column_domain_usage` and `usage_privileges`.

Rows follow information_schema.sql (REL_18): privilege filters use
`pg_has_role(..., 'USAGE')` (superusers and members, with INHERIT) and the
table grants (`tables`/`views`/`columns` any of SELECT, INSERT, UPDATE,
DELETE, TRUNCATE, REFERENCES, TRIGGER; constraints and triggers without
SELECT); `*_privileges` explode the owner's default and each grant and list
rows whose grantor or grantee the role has, or PUBLIC; `role_*_grants`
narrow them to enabled roles. MAINTAIN is not listed (PostgreSQL 18).
PostgreSQL 18's NOT NULL constraints are listed as `<table>_<column>_not_null`
CHECK constraints (`table_constraints`, `check_constraints`,
`constraint_column_usage`), including primary-key columns. `views` reports
`check_option` (WITH [LOCAL | CASCADED] CHECK OPTION) and `is_updatable` /
`is_insertable_into` from pg_relation_is_updatable (an
automatically updatable view chain, unconditional INSTEAD rules) and the
INSTEAD OF trigger flags; `columns.is_updatable` follows
pg_column_is_updatable. `routines` and `parameters` cover user routines
(modes, typed `parameter_default`, `security_type` DEFINER / INVOKER) and
the built-ins pg_proc lists. `triggers` reports the REFERENCING transition
table names (routines-trig lane) in `action_reference_old_table` /
`action_reference_new_table`.
`sql_features`, `sql_implementation_info`, `sql_parts` and `sql_sizing` hold
PostgreSQL 18's rows in physical order, PostgreSQL's own `is_supported`
values included; DBMS VERSION is `16.00.0000` (the wire's server_version
16.0) and the sizing rows for columns per table / per SELECT report this
configuration's limits. System relations (the implemented pg_catalog
relations and information_schema itself) are listed in `tables`, `columns`,
`views`, `*_privileges` with PostgreSQL's catalog ACLs: owned by the
bootstrap superuser, SELECT to PUBLIC except pg_authid, pg_largeobject,
pg_subscription, sql_parts, transforms and the `_pg_*` views.

Also: CURRENT_CATALOG and CURRENT_SCHEMA (niladic; `current_catalog()` is
42601), `version()` (`PostgreSQL 16.0 on <arch>-<os>, compiled by Sig,
64-bit`), `pg_function_is_visible(oid)` (psql's `\df`), pg_constraint
`conkey` / `confkey` (int2[]; a CHECK's columns in order of first
appearance), "char" typing of pg_class.relpersistence / relreplident,
pg_constraint.contype / confupdtype / confdeltype / confmatchtype,
pg_type.typcategory / typdelim, pg_collation.collprovider and
pg_policy.polcmd, and PostgreSQL's CASE column naming (a named ELSE result
names the column). With the `schema.table.column` references of F651
(dml-temp lane), SQLAlchemy's reflection queries (`pg_catalog.pg_class.relname`,
`unnest(conkey)`, `generate_subscripts`) answer like PostgreSQL.

A lone catalog source filters each candidate row with every available,
infallible conjunct of the WHERE clause (comparisons, IN lists and LIKE
with a literal pattern), so filtered scans of the wide views keep only
matching rows; an unfiltered scan wider than the workspace is 54000.

Privilege views read the privileges lane's ACL model (column, type and
sequence ACLs included; see [SQL_PRIVILEGES.md](SQL_PRIVILEGES.md)).
Not represented, because nothing in the engine stores it: columns typed by
a domain, temporary schemas,
table row types (`udt_privileges` lists composite types only), named NOT
NULL constraints, foreign tables, options and user mappings, transforms,
dependencies of routines and of system views (`routine_*_usage`,
`check_constraint_routine_usage`, `view_routine_usage` are empty; system
views have no `view_definition`). `views.view_definition`,
`check_clause` and `triggers.action_condition` show the stored text as
pg_get_viewdef / pg_get_constraintdef / pg_get_triggerdef do, not
PostgreSQL's deparsed form. The public schema's owner is the bootstrap
role (PostgreSQL 15+ uses pg_database_owner).

`contract-sql-catalog-views` (tests/test_sql_catalog_views.sig) replays
tests/sql_conformance/catalog_views/*.sql through the wire and compares
every response with the native PostgreSQL 18.7 recording
(tools/capture_sql_catalog_views.py, test_sql_catalog_views_cases.sig),
then checks snapshots, atomicity, replay and capacity.

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
