# SQL privileges (conformance lane B11, wave 5)

Branch `w5/privileges` replaces wave 3's "one aclitem per table and grantee,
granted by the owner" with PostgreSQL's privilege model and closes the open
privilege features of the scoreboard: E081-05..08 (column UPDATE,
REFERENCES at table and column level, WITH GRANT OPTION), E081-09 (USAGE),
F034, F035, F037 (extended REVOKE, CASCADE, GRANT OPTION FOR), F311-05
(GRANT on ALL TABLES IN SCHEMA), F731 (INSERT column privileges), T217
(TRIGGER), T281 (column SELECT) and T332 (extended roles). Every behaviour
below was checked against native PostgreSQL 18.7.

`contract-sql-privileges` (tests/test_sql_privileges.sig) runs programs
recorded from native PostgreSQL 18.7
(tests/sql_conformance/privileges_programs.sql, recorded by
record_privileges.py into tests/sql_privileges_oracle.sig) through the
PostgreSQL wire session over a store connection: message order, column
metadata, command tags, SQLSTATEs, NoticeResponse SQLSTATE and text, and
rows must match. Every committed change record is applied to a replica
that must answer the ACL catalogs (relacl, attacl, nspacl, typacl,
pg_auth_members, pg_roles) exactly like the primary. Direct sections check
crafted change records, capacity (54000), atomicity and waits on
uncommitted grants. The only rewrite between the recording and the
contract is the bootstrap superuser's name (`postgres` there, `ramsql`
here).

## Rules

GRANT and REVOKE apply PostgreSQL's own algorithms
(src/core/sql/acl_update.sig, after acl.c and aclchk.c) to an in-memory ACL
in ACL order: `aclupdate`, `recursive_revoke`, `check_circularity`,
`aclmask`, `aclmask_direct`, `select_best_grantor`, `merge_acl_with_grant`
and `restrict_and_check_grant`. Hence:

- The grantor is the owner for owners and superusers, else the closest
  role (the current one, then the roles it inherits) holding the needed
  grant options. A delegated grant is recorded with that grantor
  (`w5p_b=r/w5p_a`).
- Without any grant option, a grantor holding no privilege on the object
  fails (42501); one holding some privilege only warns: `no privileges were
  granted for "t"` / `not all privileges were granted for "t"` (01007),
  `no privileges could be revoked for "t"` / `not all privileges could be
  revoked for "t"` (01006); columns say `for column "a" of relation "t"`.
- Grant options go to roles only (0LP01 for PUBLIC); granting options back
  to one's own grantor is 0LP01 (check_circularity).
- REVOKE removes privileges and options, REVOKE GRANT OPTION FOR only the
  options; grants that depended on them go with CASCADE and are 2BP01
  (`dependent privileges exist`) under RESTRICT, unless the grantee still
  holds the option through another grant or role.
- A table-level REVOKE of SELECT, INSERT, UPDATE or REFERENCES also revokes
  them from every column. GRANTED BY must name the current user (0A000).
- Privilege types are checked per object (0LP01: `USAGE` on a table,
  `CREATE` on a relation, `DELETE` on a column, column lists outside
  relations); GRANT ... ON TABLE of a sequence keeps its USAGE, SELECT and
  UPDATE and warns about the rest (0LP01 warning). Unknown words are 42601.
- ACL text keeps PostgreSQL's order (entries keep their position, new ones
  are appended) and is NULL until the first GRANT / REVOKE materializes it
  (types show `{=U/owner,owner=U/owner}` from then on; the public schema
  always shows its initdb ACL `{pg_database_owner=UC/pg_database_owner,
  =U/pg_database_owner}`, and belongs to pg_database_owner). attacl is
  NULL without column grants. The owner's own entry follows REVOKE too
  (`REVOKE SELECT ON t FROM owner`), and ALTER ... OWNER TO moves the ACL
  to the new owner (aclnewowner).

Enforcement:

| Object | Privileges | Checked by |
|---|---|---|
| table, view, materialized view | SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER MAINTAIN | reads, DML, TRUNCATE, FOREIGN KEY creation (REFERENCES on every referenced column), CREATE TRIGGER (TRIGGER), REFRESH MATERIALIZED VIEW (MAINTAIN) |
| column | SELECT INSERT UPDATE REFERENCES | a FROM item admitted by column grants reads only granted columns (select list, `*`, WHERE, ORDER BY, joins, subqueries); INSERT target columns (none: some column), UPDATE SET targets, ON CONFLICT DO UPDATE SET, RETURNING and every column UPDATE / DELETE read |
| sequence | USAGE SELECT UPDATE | nextval (USAGE or UPDATE, also SERIAL defaults), currval / lastval (SELECT or USAGE), setval (UPDATE), SELECT from it (SELECT); identity columns need none |
| schema | USAGE CREATE | name lookup (USAGE), CREATE TABLE / VIEW / TYPE / DOMAIN (CREATE; PostgreSQL 15+: the public schema too) |
| domain, enum, composite type | USAGE | ACL kept and reported; casts need none (as PostgreSQL) |

Non-superusers may now create tables with defaults, CHECK and FOREIGN KEY
constraints; owned sequences (SERIAL, identity) and CREATE SEQUENCE remain
superuser-only.

Roles (PostgreSQL 16+): every pg_auth_members row records its grantor
(the bootstrap superuser for superusers, else the closest role holding
ADMIN OPTION; GRANTED BY a role the current one has the privileges of, that
holds ADMIN OPTION). The same membership may be granted by several
grantors; regranting it unchanged sends the NOTICE `role "c" has already
been granted membership in role "a" by role "b"`; REVOKE matches the
grantor PostgreSQL would pick and only warns (`role "c" has not been
granted membership in role "a" by role "ramsql"`) without such a grant.
REVOKE [ADMIN | INHERIT | SET] OPTION FOR, CASCADE and RESTRICT follow
plan_recursive_revoke. pg_database_owner cannot have or be a member
(0A000).

Predefined roles: the sixteen roles of PostgreSQL 18 exist with their
initdb OIDs (pg_roles, pg_authid; pg_monitor's three memberships in
pg_auth_members), are reserved (CREATE / ALTER 42939, DROP 2BP01) and
grant their effects: pg_read_all_data (SELECT everywhere, USAGE on every
schema), pg_write_all_data (INSERT, UPDATE, DELETE, USAGE), pg_maintain
(MAINTAIN), pg_database_owner (implicitly the database owner, the
bootstrap role). SET SESSION AUTHORIZATION resets SET ROLE; an unknown
role is 22023.

schema_to_xml, database_to_xml and their XML Schema forms list only the
relations the user may SELECT, in schemas it may use (PostgreSQL's
schema_get_xml_visible_tables / XML_VISIBLE_SCHEMAS).

Inquiry functions: has_table_privilege, has_column_privilege,
has_any_column_privilege, has_schema_privilege, has_sequence_privilege,
has_type_privilege and pg_has_role with an optional user and names or
OIDs; privilege lists are comma-separated, any case, optionally WITH GRANT
OPTION (pg_has_role: WITH ADMIN OPTION); unknown privilege words are
22023, unknown names 42704 / 42P01 / 3F000 / 42703, an OID naming nothing
NULL.

## Storage and durability

Grant rows are catalog objects (src/core/sql/catalog_objects.sig) carried
by the existing op 70 `object_create` / op 71 `object_drop` records; no
new op is used. Row identity is (object, grantee, grantor key): `sub` is 0
for a grant issued by the object owner (`owner` holds the owner, as wave 3
recorded every table grant) and the grantor's OID for a delegated grant
(`owner` holds it too). `oid` holds the entry's ACL position. The owner's
own entry is a marker row (grantee = owner, sub 0, grant flags bit 31 plus
its options, flags its privileges); its presence materializes the ACL.

| Kind | Object | Payload |
|---|---|---|
| 3 `acl` | table, view, materialized view | flags = privileges, grant_flags = options |
| 16 `schema_acl` | schema (2200 public included; owner pg_database_owner) | USAGE, CREATE |
| 100 `column_acl` | table (one row per grantee and grantor) | text: per column a privilege byte (low nibble INSERT 1, SELECT 2, UPDATE 4, REFERENCES 8; high nibble their options) and its ACL position; flags / grant_flags are their unions |
| 101 `type_acl` | domain, enum, composite type | USAGE |
| 102 `sequence_acl` | sequence | USAGE, SELECT, UPDATE |
| 2 `member` | role membership | `sub` = grantor OID for rows written since this lane (legacy rows keep 0, grantor in `owner`) |

Kinds 100-104 are the lane's range (its reserved change-log numbers, so no
lane collides on a kind). Old records stay byte-identical and replay as
before: legacy table and schema grants (sub 0, position 0) keep their
meaning, and the first GRANT / REVOKE on such an object rewrites them in
the new form. Decoding validates every field (InvalidChangeRecord): column
bytes (even length, options within privileges, positions exactly where
privileges are, unions equal to the flags, a non-empty last column),
grantor keys, PUBLIC without options, positions, marker rows; replay
checks references after the whole record (ChangeRecordConflict): live
tables (and their column count), sequences, types, schemas and roles
(predefined roles included). Dropping a table, sequence, type or schema
drops its grant rows in the same record; ALTER TABLE moves column grants
with their columns.

## Errors

42501 (privileges, GRANT without any privilege, explicit grantor without
ADMIN OPTION), 0LP01 (invalid privilege type, grant options to PUBLIC,
circular grant options, membership cycles), 2BP01 (dependent privileges,
DROP of a predefined role), 42939 (ALTER of a predefined role), 0A000
(GRANTED BY another role, members of pg_database_owner, column grants on
sequences), 22023 (unknown privilege in an inquiry, unknown SET SESSION
AUTHORIZATION role), 42601, 42704, 42P01, 42703, 3F000, 42809, 54000.
Warnings 01006 / 01007 / 0LP01 / 01000 and the notice 00000 carry
PostgreSQL's text. Error messages remain the engine's error names.

## Limits

Config.catalog_objects bounds grant rows, markers and memberships
(TableCapacity 54000); a column grant row needs 2 bytes per column up to
its last granted column within Config.object_text_bytes (TextCapacity
54000); a column ACL keeps at most 255 entry positions (54000 beyond); one
GRANT names at most 16 (privilege, column) pairs and 8 objects or roles
(54000). The GRANT scratch (one ACL, its circularity copy, the relation's
ACL, column rows) lives in database storage.

## Not covered

- GRANT as a CREATE SCHEMA element (needs the schema-element grammar of
  the ddl-alter lane; standalone GRANT ... ON ALL TABLES IN SCHEMA works).
- information_schema privilege views (table_privileges column types,
  column_privileges, usage_privileges, role_* views): the catalog lane
  builds them on this model (E081-08's last statement and F231 wait on
  them).
- One notice per statement reaches the client (PostgreSQL may send
  several, e.g. one per column of an implied column revoke); per-column
  warnings for system columns (ZPM has none).
- USAGE on types is not checked when a column uses a type (ZPM tables
  hold no user-type columns); CREATE SEQUENCE, owned sequences, CREATE
  SCHEMA and database privileges stay superuser-only; LOCK, VACUUM and
  ANALYZE privileges; function privileges stay with the routine ACLs of
  wave 4; DROP OWNED / REASSIGN OWNED.
- Row security with column grants checks every column of the secured
  relation, and UPDATE ... FROM over a column-granted item every column
  of that item (both stricter than PostgreSQL).
