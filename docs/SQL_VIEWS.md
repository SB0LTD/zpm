# View replacement

`CREATE OR REPLACE VIEW` creates an absent view or changes the SELECT of an
existing ordinary view. The existing column prefix must keep its names, data
types and typmods; incompatible replacements return 42P16. Another relation kind
returns 42809. Quoted schema/view names and declared column aliases use the normal
identifier binder. Temporary views and view options remain open. Automatic
updatability, INSTEAD OF triggers and rule actions are provided by the merged
[nested statement implementation](SQL_NESTED_STATEMENTS.md). Replacement must
retain their OID links; an integration contract checks trigger and rule effects
after changing the SELECT to a computed projection.
Trigger deparsing also retains INSTEAD OF timing; emitting AFTER instead made
stock dumps invalid when restored to native PostgreSQL. Full/pretty definition
and WAL contracts accompany the real archive round trip.

Replacement uses the existing transactional definition rewrite, retaining the
relation OID, owner, ACLs and existing column defaults. The old definition remains
visible to other snapshots until publication. Rollback discards the replacement;
WAL restores the new definition without a format change. The owner check and
access-exclusive lock are the same checks used by other definition changes. New
query dependencies take access-share locks before publication.
Replacement also checks namespace CREATE authority. Native PostgreSQL rejects a
view owner who lacks that right. The supported authorization model permits an
owned private schema and rejects unauthorized public/other schemas; granular
schema privilege GRANT/REVOKE remains open. The regression retains the old SELECT
after rejection and checks successful replacement in the owner's private schema.
Expanded view reads now also retain access-share locks on the view definition;
locking only their underlying tables previously let replacement bypass readers.
The expanded-view list is deduplicated before applying its caller-owned budget.

PostgreSQL accepts circular view definitions and rejects their expansion on read
with 42P17. Expansion now keeps a bounded ancestry per appended query block, so
the same view in two sibling FROM items is legal while a repeated ancestor fails.
Queries without views do not initialize ancestry storage. Ancestry uses bounded
stack scratch sized by the caller's query-block capacity; no allocator is introduced.

Appending columns is supported when no stored view depends on the replaced view.
With dependent views it currently returns 0A000: stored stars are expanded again
at read time and must first be frozen to their creation-time projection. This is
an explicit compatibility gap. Transitive dependency lists can also retain old
base-relation dependencies after a replacement. ALTER VIEW column rename,
stored references outside the supported public path, temporary views/options
and complete dependency graph normalization remain open. General relation and
routine search_path resolution is implemented by the merged wave-4 lanes;
stored view text still has the restrictions in [DDL/DML](SQL_DDL_DML.md).
Experimental heterogeneous packed banks retain
the existing ALTER-definition restriction; this change does not qualify them.

The routine contract tests replacement, unchanged OIDs, dependent reads, shape
errors, quoted aliases, owner/ACL preservation, rollback, lock waits and WAL
replay. Native PostgreSQL 18.3 independently checks values and SQLSTATEs.
RamSQL's stock archive fixture exercises replacement and rollback on both native
PostgreSQL and RamSQL, then checks plain/custom archives in both directions and
deparsed return-rule actions. PG16 and PG18 CI must pass before merging.

Stored view SQL now uses the query-expansion budget instead of a user cell's
inline text budget. A real native dump containing a qualified CTE reproduced
TextCapacity with 128-byte cells. Ordinary and materialized definitions now own
up to max(text_bytes, expansion_bytes), capped at 65,535 bytes by the existing
WAL length field; the default is 4,096 bytes. This is an explicit bounded
metadata budget, not unlimited statement storage. Longer pg_views/pg_matviews
definition cells use caller-owned result memory, including across replacement;
unreferenced definition columns do not consume that memory. Contracts cover
reads, replacement, materialization and WAL replay with genuine SQL over 128 bytes.
Compact base images still reject view metadata; this change qualifies WAL replay,
not complete checkpoint support for views.

Reference: [PostgreSQL CREATE VIEW](https://www.postgresql.org/docs/18/sql-createview.html).
