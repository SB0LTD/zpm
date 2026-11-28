//! information_schema rows (B11 wave 5, catalog lane): every view and table
//! of PostgreSQL 18's information_schema computed at scan time from the
//! versioned catalogs under the statement snapshot, with PostgreSQL's
//! privilege filters (pg_has_role USAGE, has_table_privilege and the other
//! has_*_privilege checks), column values and row order.
//!
//! Sources: src/backend/catalog/information_schema.sql (REL_18). System
//! relations (the implemented pg_catalog relations and information_schema
//! itself) are listed like PostgreSQL lists its catalogs: owned by the
//! bootstrap superuser, SELECT granted to PUBLIC except pg_authid,
//! pg_largeobject, pg_subscription, sql_parts and transforms. They are
//! computed natively, so they have no SQL view definition, constraints or
//! dependencies.
//!
//! ACLs come from the privileges lane's model (Database.nextAclItem and
//! nextColumnAclItem: relacl, attacl, typacl and sequence relacl with
//! grantors and grant options, acldefault until a GRANT / REVOKE).
//!
//! Not represented (empty or NULL here; nothing in the engine stores them):
//! columns typed by a domain,
//! WITH CHECK OPTION, temporary schemas, table row types, foreign tables,
//! user mappings, transforms, routine and view dependencies on routines.
const std = @import("std");
const types = @import("types.sig");
const storage = @import("storage.sig");
const catalog = @import("catalog.sig");
const IS = @import("information_schema.sig");
const CO = @import("catalog_objects.sig");
const exec = @import("exec.sig");
const value = @import("value.sig");
const ast = @import("ast.sig");
const parser = @import("parser.sig");
const lexer = @import("lexer.sig");
const collation = @import("collation.sig");
const operator_catalog = @import("operator_catalog.sig");
const routine_catalog = @import("routine_catalog.sig");
const privilege_graph = @import("privilege_graph.sig");

const Error = types.Error;
const View = catalog.View;
const DataType = types.DataType;
const Snapshot = storage.Snapshot;

/// PostgreSQL's NAMEDATALEN - 1: generated constraint names fit it.
const max_identifier: usize = 63;
/// pg_encoding_max_length(UTF8): character_octet_length factor.
const utf8_max_length: i64 = 4;
/// TRIGGER_TYPE_* bits of pg_trigger.tgtype.
const trigger_row: u8 = 1;
const trigger_before: u8 = 2;
const trigger_insert: u8 = 4;
const trigger_delete: u8 = 8;
const trigger_update: u8 = 16;
const trigger_instead: u8 = 64;
/// pg_relation_is_updatable event bits (1 << CMD_*).
const event_update: u8 = 4;
const event_insert: u8 = 8;
const event_delete: u8 = 16;
const all_events: u8 = event_update | event_insert | event_delete;

/// System relations that grant no SELECT to PUBLIC (PostgreSQL 18 ACLs).
fn publicSelect(view: View) bool {
    return switch (view) {
        .pg_authid, .pg_largeobject, .pg_subscription, .sql_parts, .transforms, ._pg_foreign_data_wrappers,
        ._pg_foreign_servers, ._pg_foreign_table_columns, ._pg_foreign_tables, ._pg_user_mappings => false,
        else => true,
    };
}

/// pg_catalog relations with a bootstrap OID are catalog tables; the
/// others (pg_tables, pg_roles ...) are views.
fn systemRelkind(view: View) u8 {
    if (IS.isInformationSchema(view)) return IS.relationKind(view);
    return if (catalog.bootstrapRelationOid(view) != null) 'r' else 'v';
}

pub fn Rows(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const X = exec.Exec(config);
    const A = ast.Ast(config);
    const P = parser.Parser(config);
    const G = @import("deparse.sig").Deparse(config);
    const O = CO.Objects(config);
    const K = catalog.Catalog(config);
    const RC = routine_catalog.Catalog(config);
    const Cell = V.Cell;
    const Sink = X.RowSink;

    return struct {
        pub fn fill(db: anytype, session: *const value.Session, snap: Snapshot, pool: *A.Pool, view: View, sink: *Sink) Error!void {
            var relations: [K.relation_rows]K.Found = undefined;
            const count = db.catalog.visibleRelations(snap, &relations);
            var context: Context(@TypeOf(db)) = .{
                .db = db,
                .session = session,
                .snap = snap,
                .pool = pool,
                .sink = sink,
                .role = session.role,
                .database = session.database,
                .relations = relations[0..count],
            };
            return context.run(view);
        }

        fn int(number: i64) Cell {
            return .{ .integer = number };
        }

        fn optionalInt(number: ?i64) Cell {
            return if (number) |known| .{ .integer = known } else .null_value;
        }

        /// A text cell over bytes that outlive the statement (static
        /// catalog data): never copied.
        fn static(bytes: []const u8) Error!Cell {
            if (bytes.len > config.text_bytes and comptime config.text_bytes < @sizeOf(usize)) return error.TextCapacity;
            return .{ .text = V.Text.fromValueBytes(bytes) };
        }

        fn yesNo(yes: bool) Error!Cell {
            return static(if (yes) "YES" else "NO");
        }

        // ---- type descriptors (_pg_char_max_length and friends) ----------

        fn dataTypeName(data_type: DataType) []const u8 {
            return if (types.elementData(data_type) != null) "ARRAY" else types.sqlTypeName(data_type);
        }

        fn udtName(data_type: DataType) []const u8 {
            return types.typeInfo(data_type).name;
        }

        fn charMaxLength(data_type: DataType, typmod: i32) ?i64 {
            if (typmod == -1) return null;
            return switch (data_type) {
                .varchar, .bpchar => typmod - 4,
                .bit, .varbit => typmod,
                else => null,
            };
        }

        fn charOctetLength(data_type: DataType, typmod: i32) ?i64 {
            return switch (data_type) {
                .text, .varchar, .bpchar => if (typmod == -1) 1 << 30 else (charMaxLength(data_type, typmod) orelse return null) * utf8_max_length,
                else => null,
            };
        }

        fn numericPrecision(data_type: DataType, typmod: i32) ?i64 {
            return switch (data_type) {
                .smallint => 16,
                .integer32 => 32,
                .integer => 64,
                .numeric, .mysql_bigint_unsigned => if (typmod == -1) null else ((typmod - 4) >> 16) & 0xffff,
                .real => 24,
                .double => 53,
                else => null,
            };
        }

        fn numericRadix(data_type: DataType) ?i64 {
            return switch (data_type) {
                .smallint, .integer32, .integer, .real, .double => 2,
                .numeric, .mysql_bigint_unsigned => 10,
                else => null,
            };
        }

        fn numericScale(data_type: DataType, typmod: i32) ?i64 {
            return switch (data_type) {
                .smallint, .integer32, .integer => 0,
                .numeric, .mysql_bigint_unsigned => if (typmod == -1) null else (typmod - 4) & 0xffff,
                else => null,
            };
        }

        fn datetimePrecision(data_type: DataType, typmod: i32) ?i64 {
            return switch (data_type) {
                .date => 0,
                .time, .timestamp, .timestamptz, .timetz => if (typmod < 0) 6 else typmod,
                .interval => if (typmod < 0 or typmod & 0xffff == 0xffff) 6 else typmod & 0xffff,
                else => null,
            };
        }

        /// The collation name of a column of this type, NULL for the
        /// database default (information_schema omits pg_catalog.default).
        fn collationName(data_type: DataType, domain: ?IS.Domain) ?[]const u8 {
            if (domain) |known| return switch (known) {
                .id, .chars, .yes_no => "C",
                else => null,
            };
            const oid = collation.typeCollation(types.typeOfData(data_type));
            if (oid == 0 or oid == collation.oids[0]) return null;
            for (collation.oids, collation.names) |candidate, name| if (candidate == oid) return name;
            return null;
        }

        fn Context(comptime Db: type) type {
            return struct {
                const Self = @This();

                db: Db,
                session: *const value.Session,
                snap: Snapshot,
                pool: *A.Pool,
                sink: *Sink,
                role: u32,
                database: []const u8,
                relations: []const K.Found,
                /// seesColumn's table and whether all its columns show.
                column_memo: u32 = 0,
                column_memo_all: bool = false,

                fn objects(self: *const Self) *const O {
                    return &self.db.catalog_objects;
                }

                // ---- cells --------------------------------------------------

                /// A text cell; text past Config.text_bytes goes to the
                /// statement's value bytes.
                fn text(self: *const Self, bytes: []const u8) Error!Cell {
                    if (bytes.len <= config.text_bytes) {
                        var out: V.Text = .{ .len = bytes.len };
                        @memcpy(out.bytes[0..bytes.len], bytes);
                        return .{ .text = out };
                    }
                    if (comptime config.text_bytes < @sizeOf(usize)) return error.TextCapacity;
                    const values = self.sink.valueBytes() orelse return error.WorkspaceCapacity;
                    return .{ .text = V.Text.fromValueBytes(try values.copy(bytes)) };
                }

                fn optionalText(self: *const Self, bytes: ?[]const u8) Error!Cell {
                    return if (bytes) |known| self.text(known) else .null_value;
                }

                fn catalogName(self: *const Self) Error!Cell {
                    return self.text(self.database);
                }

                fn number(self: *const Self, value_number: i64) Error!Cell {
                    var digits: [24]u8 = undefined;
                    return self.text(std.fmt.bufPrint(&digits, "{d}", .{value_number}) catch unreachable);
                }

                /// nameconcatoid(name, oid): `name_oid`, the name cut to fit.
                fn specificName(self: *const Self, name: []const u8, oid: u32) Error!Cell {
                    var buffer: [max_identifier + 1]u8 = undefined;
                    var digits: [16]u8 = undefined;
                    const suffix = std.fmt.bufPrint(&digits, "_{d}", .{oid}) catch unreachable;
                    const keep = @min(name.len, max_identifier - suffix.len);
                    @memcpy(buffer[0..keep], name[0..keep]);
                    @memcpy(buffer[keep..][0..suffix.len], suffix);
                    return self.text(buffer[0 .. keep + suffix.len]);
                }

                fn add(self: *const Self, cells: []const Cell) Error!void {
                    try self.sink.add(cells);
                }

                // ---- roles and privileges -----------------------------------

                fn superuser(self: *const Self) bool {
                    return self.objects().superuser(self.role, self.snap);
                }

                /// pg_has_role(target, 'USAGE') for the current role.
                fn hasRole(self: *const Self, target: u32) bool {
                    if (target == CO.public_role) return false;
                    return self.superuser() or self.objects().memberOf(self.role, target, true, self.snap);
                }

                /// pg_has_role(member, target, 'USAGE').
                fn roleHasRole(self: *const Self, member: u32, target: u32) bool {
                    if (member == CO.public_role) return false;
                    return self.objects().superuser(member, self.snap) or self.objects().memberOf(member, target, true, self.snap);
                }

                fn roleName(self: *const Self, oid: u32) []const u8 {
                    if (oid == CO.public_role) return "PUBLIC";
                    return self.objects().roleName(oid, self.snap) orelse "";
                }

                /// The ACL row filter of the *_privileges views.
                fn showsGrant(self: *const Self, grantor: u32, grantee: u32) bool {
                    return self.hasRole(grantor) or self.hasRole(grantee) or grantee == CO.public_role;
                }

                fn tableOwner(self: *const Self, table: *const S.Table) u32 {
                    return self.objects().owner(table.oid, self.snap);
                }

                fn tableAny(self: *const Self, table: *const S.Table, mask: u32) bool {
                    return self.objects().tableHasAnyPrivilege(self.role, table.oid, mask, self.snap);
                }

                /// has_any_column_privilege(oid, mask): a table privilege or
                /// a column grant on any column.
                fn anyColumn(self: *const Self, table: *const S.Table, mask: u32) bool {
                    return self.tableAny(table, mask) or self.objects().anyColumnGrant(self.role, table.oid, table.column_count, mask, self.snap);
                }

                const column_privilege_mask = CO.priv_insert | CO.priv_select | CO.priv_update | CO.priv_references;

                /// tables/views: owner, any table privilege, any column
                /// privilege (SELECT, INSERT, UPDATE, REFERENCES).
                fn seesRelation(self: *const Self, table: *const S.Table) bool {
                    return self.hasRole(self.tableOwner(table)) or self.tableAny(table, CO.table_privileges & ~CO.priv_maintain) or
                        self.anyColumn(table, column_privilege_mask);
                }

                /// table_constraints / referential_constraints / triggers:
                /// SELECT omitted, per the SQL standard.
                fn seesConstraints(self: *const Self, table: *const S.Table) bool {
                    const mask = CO.priv_insert | CO.priv_update | CO.priv_delete | CO.priv_truncate | CO.priv_references | CO.priv_trigger;
                    return self.hasRole(self.tableOwner(table)) or self.tableAny(table, mask) or
                        self.anyColumn(table, CO.priv_insert | CO.priv_update | CO.priv_references);
                }

                /// Some column passes seesColumn (a quick per-table test).
                fn seesColumns(self: *const Self, table: *const S.Table) bool {
                    return self.hasRole(self.tableOwner(table)) or self.anyColumn(table, column_privilege_mask);
                }

                /// columns / key_column_usage: pg_has_role(owner) or
                /// has_column_privilege(SELECT, INSERT, UPDATE, REFERENCES)
                /// on the column (`index` 0-based); table grants cover it.
                fn seesColumn(self: *Self, table: *const S.Table, index: usize) bool {
                    // Owner or table-wide privileges decide once per table.
                    if (self.column_memo != table.oid) {
                        self.column_memo = table.oid;
                        self.column_memo_all = self.hasRole(self.tableOwner(table)) or self.tableAny(table, column_privilege_mask);
                    }
                    if (self.column_memo_all) return true;
                    return self.objects().columnGrantMask(self.role, table.oid, index, self.snap) & column_privilege_mask != 0;
                }

                fn columnAllowed(self: *const Self, table: *const S.Table, index: usize, mask: u32) bool {
                    if (self.hasRole(self.tableOwner(table))) return true;
                    return self.objects().columnPrivilegeMask(self.role, table.oid, index, self.snap) & mask != 0;
                }

                fn seesSystemRelation(self: *const Self, view: View) bool {
                    return self.superuser() or self.hasRole(CO.bootstrap_role) or publicSelect(view);
                }

                // ---- namespaces ---------------------------------------------

                /// A composite type's schema and name (composite lane): a
                /// composite column's typmod, or a routine type's OID.
                const UserType = struct { schema: []const u8, name: []const u8 };

                fn compositeType(self: *const Self, oid: u32) ?UserType {
                    const index = self.objects().byOid(.composite_type, oid, self.snap) orelse return null;
                    const object = &self.objects().items[index];
                    return .{ .schema = self.namespaceName(object.target), .name = object.name.slice() };
                }

                fn namespaceName(self: *const Self, oid: u32) []const u8 {
                    for (catalog.namespaces) |namespace| if (namespace.oid == oid) return namespace.name;
                    for (&self.db.schemas) |*schema| if (schema.live and schema.oid == oid) return schema.name.slice();
                    return "";
                }

                fn schemaOwner(self: *const Self, schema: anytype) u32 {
                    const key: O.Object = .{ .kind = .schema_owner, .target = schema.oid };
                    const index = self.objects().findKey(&key, self.snap) orelse return schema.owner;
                    return self.objects().items[index].owner;
                }

                /// has_schema_privilege(oid, 'CREATE, USAGE').
                fn schemaPrivilege(self: *const Self, oid: u32, owner: u32) bool {
                    return self.objects().schemaPrivilegeMask(self.role, oid, owner, self.snap) & (CO.priv_usage | CO.priv_create) != 0;
                }

                // ---- relations ----------------------------------------------

                fn visibleTable(self: *const Self, oid: u32) ?*const S.Table {
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.oid == oid) return table;
                    }
                    return null;
                }

                /// Every implemented system relation: pg_catalog, then
                /// information_schema (each in its own order).
                fn systemView(self: *const Self, index: usize) ?View {
                    const fields = @typeInfo(View).@"enum".field_names.len;
                    if (index < fields) {
                        const view: View = @enumFromInt(index);
                        if (IS.isInformationSchema(view)) return null;
                        const found = self.db.catalog.findSystemView("pg_catalog", @tagName(view)) orelse return null;
                        return if (found == view) view else null;
                    }
                    const position = index - fields;
                    if (position >= IS.relation_count) return null;
                    return IS.viewAt(position);
                }

                const system_view_slots = @typeInfo(View).@"enum".field_names.len + IS.relation_count;

                fn systemNamespace(view: View) []const u8 {
                    return if (IS.isInformationSchema(view)) "information_schema" else "pg_catalog";
                }

                fn primaryColumns(table: *const S.Table, out: *[config.columns]u8) []const u8 {
                    if (table.primary_column) |column| {
                        out[0] = @intCast(column);
                        return out[0..1];
                    }
                    const index = S.primaryConstraint(table) orelse return out[0..0];
                    const keys = table.constraints[index].keyColumns();
                    @memcpy(out[0..keys.len], keys);
                    return out[0..keys.len];
                }

                fn primaryName(table: *const S.Table, out: *[max_identifier + 8]u8) []const u8 {
                    if (S.primaryConstraint(table)) |index| return table.constraints[index].name.slice();
                    const name = table.name.slice();
                    const keep = @min(name.len, max_identifier - 5);
                    @memcpy(out[0..keep], name[0..keep]);
                    @memcpy(out[keep..][0..5], "_pkey");
                    return out[0 .. keep + 5];
                }

                /// PostgreSQL's makeObjectName(table, column, "not_null"):
                /// the longer part is cut until the name fits 63 bytes.
                fn notNullName(table: []const u8, column: []const u8, out: *[max_identifier + 1]u8) []const u8 {
                    const label = "not_null";
                    const room = @min(max_identifier, config.name_bytes) -| (label.len + 2);
                    var first = table.len;
                    var second = column.len;
                    while (first + second > room) {
                        if (first > second) first -= 1 else second -= 1;
                    }
                    first = clipUtf8(table, first);
                    second = clipUtf8(column, second);
                    var at: usize = 0;
                    for ([_][]const u8{ table[0..first], "_", column[0..second], "_", label }) |part| {
                        @memcpy(out[at..][0..part.len], part);
                        at += part.len;
                    }
                    return out[0..at];
                }

                /// The name of a column's NOT NULL constraint: the one its
                /// definition stores (ddl-alter: named, inherited or kept
                /// across renames), else makeObjectName's.
                fn columnNotNullName(table: *const S.Table, index: usize, out: *[max_identifier + 1]u8) []const u8 {
                    const stored = table.columns[index].not_null_name.slice();
                    if (stored.len != 0 and stored.len <= out.len) {
                        @memcpy(out[0..stored.len], stored);
                        return out[0..stored.len];
                    }
                    return notNullName(table.name.slice(), table.columns[index].name.slice(), out);
                }

                fn clipUtf8(bytes: []const u8, length: usize) usize {
                    var end = length;
                    while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
                    return end;
                }

                fn notNullColumn(table: *const S.Table, column: usize, keys: []const u8) bool {
                    if (table.columns[column].not_null) return true;
                    for (keys) |key| if (key == column) return true;
                    return false;
                }

                /// The referenced table's primary key or UNIQUE key columns
                /// a foreign key uses, and the constraint's name (null for
                /// a unique index that is no constraint).
                const ReferencedKey = struct { columns: []const u8, name: ?[]const u8 };

                fn referencedKey(self: *const Self, constraint: *const S.Constraint, parent: *const S.Table, keys: *[config.columns]u8, name: *[max_identifier + 8]u8) ?ReferencedKey {
                    _ = self;
                    const wanted = constraint.refColumns();
                    const primary = primaryColumns(parent, keys);
                    if (sameKeySet(wanted, primary)) return .{ .columns = primary, .name = primaryName(parent, name) };
                    for (parent.constraints[0..parent.constraint_count]) |*item| {
                        if (item.kind == .unique and sameKeySet(wanted, item.keyColumns())) return .{ .columns = item.keyColumns(), .name = item.name.slice() };
                    }
                    for (parent.indexes[0..parent.index_count]) |*index| {
                        if (index.unique and index.predicate.len == 0 and sameKeySet(wanted, index.keyColumns())) return .{ .columns = index.keyColumns(), .name = null };
                    }
                    return null;
                }

                fn sameKeySet(expected: []const u8, actual: []const u8) bool {
                    if (expected.len != actual.len or expected.len == 0) return false;
                    for (expected) |column| {
                        if (std.mem.indexOfScalar(u8, actual, column) == null) return false;
                    }
                    return true;
                }

                // ---- dispatch -----------------------------------------------

                fn run(self: *Self, view: View) Error!void {
                    switch (view) {
                        .information_schema_catalog_name => try self.add(&.{try self.catalogName()}),
                        .sql_features, .sql_implementation_info, .sql_parts, .sql_sizing => try self.staticTable(view),
                        .schemata => try self.schemata(),
                        .tables => try self.tables(),
                        .views => try self.views(),
                        .columns => try self.columns(),
                        .table_constraints => try self.tableConstraints(),
                        .check_constraints => try self.checkConstraints(),
                        .key_column_usage => try self.keyColumnUsage(),
                        .referential_constraints => try self.referentialConstraints(),
                        .constraint_column_usage => try self.constraintColumnUsage(),
                        .constraint_table_usage => try self.constraintTableUsage(),
                        .table_privileges, .role_table_grants => try self.tablePrivileges(view == .role_table_grants),
                        .column_privileges, .role_column_grants => try self.columnPrivileges(view == .role_column_grants),
                        .enabled_roles => try self.enabledRoles(),
                        .applicable_roles, .administrable_role_authorizations => try self.applicableRoles(view == .administrable_role_authorizations),
                        .routines => try self.routines(),
                        .parameters => try self.parameters(),
                        .routine_privileges, .role_routine_grants => try self.routinePrivileges(view == .role_routine_grants),
                        .sequences => try self.sequences(),
                        .domains => try self.domains(),
                        .domain_constraints => try self.domainConstraints(),
                        .domain_udt_usage => try self.domainUdtUsage(),
                        .usage_privileges, .role_usage_grants => try self.usagePrivileges(view == .role_usage_grants),
                        .udt_privileges, .role_udt_grants => try self.udtPrivileges(view == .role_udt_grants),
                        .triggers => try self.triggers(),
                        .triggered_update_columns => try self.triggeredUpdateColumns(),
                        .view_table_usage, .view_column_usage => try self.viewUsage(view == .view_column_usage),
                        .column_udt_usage => try self.columnUdtUsage(),
                        .column_column_usage => try self.columnColumnUsage(),
                        .element_types => try self.elementTypes(),
                        .attributes => try self.attributes(),
                        .user_defined_types => try self.userDefinedTypes(),
                        .data_type_privileges => try self.dataTypePrivileges(),
                        .character_sets => try self.add(&.{ .null_value, .null_value, try static("UTF8"), try static("UCS"), try static("UTF8"), try self.catalogName(), .null_value, .null_value }),
                        .collations, .collation_character_set_applicability => try self.collations(view),
                        .foreign_data_wrappers => try self.foreignDataWrappers(),
                        .foreign_servers => try self.foreignServers(),
                        ._pg_foreign_data_wrappers => try self.helperWrappers(),
                        ._pg_foreign_servers => try self.helperServers(),
                        ._pg_foreign_table_columns, ._pg_foreign_tables, ._pg_user_mappings => {},
                        // No column domains, options, foreign tables, user
                        // mappings, transforms or routine dependencies.
                        .column_domain_usage => try self.columnDomainUsage(),
                        .column_options, .foreign_data_wrapper_options, .foreign_server_options,
                        .foreign_table_options, .foreign_tables, .user_mapping_options, .user_mappings, .transforms,
                        .check_constraint_routine_usage, .routine_column_usage, .routine_routine_usage,
                        .routine_sequence_usage, .routine_table_usage, .view_routine_usage,
                        => {},
                        else => return error.UnsupportedStatement,
                    }
                }

                // ---- static tables ------------------------------------------

                /// sql_features, sql_implementation_info, sql_parts and
                /// sql_sizing: PostgreSQL 18's contents. DBMS VERSION follows
                /// the server_version the wire reports; sizing rows that
                /// describe this engine's limits use its configuration.
                fn staticTable(self: *Self, view: View) Error!void {
                    const source: []const u8 = switch (view) {
                        .sql_features => IS.data.sql_features,
                        .sql_implementation_info => IS.data.sql_implementation_info,
                        .sql_parts => IS.data.sql_parts,
                        else => IS.data.sql_sizing,
                    };
                    const width = IS.columnsOf(view).len;
                    var lines = std.mem.splitScalar(u8, source, '\n');
                    while (lines.next()) |line| {
                        var cells: [8]Cell = undefined;
                        var fields = std.mem.splitScalar(u8, line, '|');
                        var index: usize = 0;
                        while (fields.next()) |field| : (index += 1) {
                            if (index == width) return error.InvalidParameterValue;
                            const column = IS.columnsOf(view)[index];
                            if (types.same(field, "\\N")) {
                                cells[index] = .null_value;
                            } else if (column.ty == .int4) {
                                cells[index] = int(std.fmt.parseInt(i64, field, 10) catch return error.InvalidParameterValue);
                            } else cells[index] = try static(field);
                        }
                        if (index != width) return error.InvalidParameterValue;
                        if (view == .sql_implementation_info and types.same(cells[0].text.slice(), "18")) {
                            cells[3] = try static(dbms_version);
                        }
                        if (view == .sql_sizing) {
                            const id = cells[0].integer;
                            if (id == 100) cells[2] = int(@intCast(types.projectionColumns(config)));
                            if (id == 101) cells[2] = int(@intCast(config.columns));
                        }
                        try self.add(cells[0..width]);
                    }
                }

                /// The wire's server_version (16.0) in initdb's format.
                const dbms_version = "16.00.0000";

                // ---- schemata -----------------------------------------------

                fn schemata(self: *Self) Error!void {
                    // pg_namespace physical order: pg_toast, pg_catalog,
                    // public, information_schema, then user schemas.
                    for ([_]u32{ catalog.toast_namespace, catalog.catalog_namespace, catalog.public_namespace, catalog.information_namespace }) |oid| {
                        // Built-in schemas grant USAGE to PUBLIC except pg_toast.
                        if (oid == catalog.toast_namespace and !self.hasRole(CO.bootstrap_role)) continue;
                        if (oid == catalog.public_namespace) {
                            // Owned by pg_database_owner; its ACL can change.
                            const owner = CO.role_pg_database_owner;
                            if (!self.hasRole(owner) and !self.schemaPrivilege(oid, owner)) continue;
                            try self.schemaRow(self.namespaceName(oid), owner);
                            continue;
                        }
                        try self.schemaRow(self.namespaceName(oid), CO.bootstrap_role);
                    }
                    var schemas: [K.relation_rows]K.SchemaFound = undefined;
                    const count = self.db.catalog.visibleSchemas(self.snap, &schemas);
                    for (schemas[0..count]) |found| {
                        const schema = &self.db.schemas[found.slot];
                        const owner = self.schemaOwner(schema);
                        if (!self.hasRole(owner) and !self.schemaPrivilege(found.oid, owner)) continue;
                        try self.schemaRow(schema.name.slice(), owner);
                    }
                }

                fn schemaRow(self: *Self, name: []const u8, owner: u32) Error!void {
                    try self.add(&.{ try self.catalogName(), try self.text(name), try self.text(self.roleName(owner)), .null_value, .null_value, .null_value, .null_value });
                }

                // ---- tables, views and columns ------------------------------

                fn tables(self: *Self) Error!void {
                    for (0..system_view_slots) |index| {
                        const view = self.systemView(index) orelse continue;
                        if (!self.seesSystemRelation(view)) continue;
                        const kind = systemRelkind(view);
                        try self.tableRow(systemNamespace(view), @tagName(view), kind, kind == 'r');
                    }
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        switch (table.relkind) {
                            'r', 'p', 'v' => {},
                            else => continue,
                        }
                        if (!self.seesRelation(table)) continue;
                        const insertable = table.relkind != 'v' or self.updatableEvents(table) & event_insert != 0;
                        try self.tableRow(self.namespaceName(table.namespace), table.name.slice(), table.relkind, insertable);
                    }
                }

                fn tableRow(self: *Self, schema: []const u8, name: []const u8, relkind: u8, insertable: bool) Error!void {
                    const table_type: []const u8 = switch (relkind) {
                        'v' => "VIEW",
                        'f' => "FOREIGN",
                        else => "BASE TABLE",
                    };
                    try self.add(&.{
                        try self.catalogName(), try self.text(schema), try self.text(name), try static(table_type),
                        .null_value,            .null_value,           .null_value,         .null_value,
                        .null_value,            try yesNo(insertable),     try yesNo(false),        .null_value,
                    });
                }

                fn views(self: *Self) Error!void {
                    for (0..system_view_slots) |index| {
                        const view = self.systemView(index) orelse continue;
                        if (systemRelkind(view) != 'v' or !self.seesSystemRelation(view)) continue;
                        try self.add(&.{
                            try self.catalogName(), try static(systemNamespace(view)), try static(@tagName(view)), .null_value,
                            try static("NONE"),     try yesNo(false),                       try yesNo(false),                 try yesNo(false),
                            try yesNo(false),           try yesNo(false),
                        });
                    }
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.relkind != 'v' or !self.seesRelation(table)) continue;
                        const definition: Cell = if (self.hasRole(self.tableOwner(table))) try self.viewDefinition(table) else .null_value;
                        const events = self.updatableEvents(table);
                        try self.add(&.{
                            try self.catalogName(),                         try self.text(self.namespaceName(table.namespace)),
                            try self.text(table.name.slice()),              definition,
                            try static(viewCheckOption(table)),             try yesNo(events & (event_update | event_delete) == event_update | event_delete),
                            try yesNo(events & event_insert != 0),              try yesNo(self.insteadTrigger(table, trigger_update)),
                            try yesNo(self.insteadTrigger(table, trigger_delete)), try yesNo(self.insteadTrigger(table, trigger_insert)),
                        });
                    }
                }

                /// views.check_option from CREATE VIEW ... WITH [LOCAL |
                /// CASCADED] CHECK OPTION (S.Table.check_option: 0 none,
                /// 1 LOCAL, 2 CASCADED).
                fn viewCheckOption(table: *const S.Table) []const u8 {
                    return switch (table.check_option) {
                        1 => "LOCAL",
                        2 => "CASCADED",
                        else => "NONE",
                    };
                }

                fn viewDefinition(self: *Self, table: *const S.Table) Error!Cell {
                    const Db0 = @typeInfo(Db).pointer.child;
                    const db_mutable: *Db0 = @constCast(self.db);
                    return @import("expr.sig").Eval(config).renderCatalogDefinition(db_mutable, &Db0.postgresViewDefinition, table.oid, false, self.sink.valueBytes());
                }

                /// tgtype & (ROW | INSTEAD | event) on the view.
                fn insteadTrigger(self: *const Self, table: *const S.Table, event: u8) bool {
                    const wanted = trigger_row | trigger_instead | event;
                    for (&self.db.objects.triggers) |*trigger| {
                        if (trigger.live and trigger.table_oid == table.oid and trigger.stamp.visible(self.snap) and trigger.tgtype & wanted == wanted) return true;
                    }
                    return false;
                }

                /// pg_relation_is_updatable(oid, false): a view's events are
                /// those of its unconditional DO INSTEAD rules, plus, when it
                /// is automatically updatable (view_query_is_auto_updatable),
                /// the events its base relation supports (INSERT and UPDATE
                /// need an updatable column). E(v) = R(v) | (A(v) & E(base)),
                /// folded down the chain of base views without recursion.
                fn updatableEvents(self: *Self, table: *const S.Table) u8 {
                    if (table.relkind == 'r' or table.relkind == 'p') return all_events;
                    if (table.relkind != 'v') return 0;
                    var events: u8 = 0;
                    var mask: u8 = all_events;
                    var current = table;
                    for (0..config.tables) |_| {
                        events |= mask & self.ruleEvents(current);
                        const shape = self.autoUpdatable(current) orelse break;
                        if (!shape.columns) mask &= event_delete;
                        const base = self.visibleTable(shape.base) orelse break;
                        if (base.relkind == 'r' or base.relkind == 'p') {
                            events |= mask;
                            break;
                        }
                        if (base.relkind != 'v') break;
                        current = base;
                    }
                    return events;
                }

                /// Events covered by an unconditional DO INSTEAD rule.
                fn ruleEvents(self: *const Self, table: *const S.Table) u8 {
                    var events: u8 = 0;
                    for (&self.db.objects.rules) |*rule| {
                        if (!rule.live or rule.table_oid != table.oid or !rule.stamp.visible(self.snap)) continue;
                        if (!rule.instead or rule.where.len != 0) continue;
                        events |= switch (rule.event) {
                            '2' => event_update,
                            '3' => event_insert,
                            '4' => event_delete,
                            else => 0,
                        };
                    }
                    return events;
                }

                const AutoShape = struct { base: u32, columns: bool, plain: [config.columns]bool };

                /// view_query_is_auto_updatable over the stored definition,
                /// parsed into the statement pool above its live nodes.
                fn autoUpdatable(self: *Self, table: *const S.Table) ?AutoShape {
                    const pool = self.pool;
                    const saved = .{ pool.len, pool.query_len, pool.window_len, pool.complex };
                    defer {
                        pool.len = saved[0];
                        pool.query_len = saved[1];
                        pool.window_len = saved[2];
                        pool.complex = saved[3];
                    }
                    const source = table.query.slice();
                    const root = P.parseQueryAt(source, 0, source.len, pool) catch return null;
                    const q = &pool.queries[root];
                    if (q.distinct or q.distinct_on_count != 0 or q.group_count != 0 or q.grouping_sets != ast.none or q.rollup) return null;
                    if (q.having != ast.none or q.set_op != .none or q.cte_count != 0 or q.limit_present or q.offset_present) return null;
                    if (q.limit_expr != ast.none or q.offset_expr != ast.none or q.values != ast.none) return null;
                    if (q.item_count != 1) return null;
                    const item = &q.items[0];
                    if (item.query != ast.none or item.function != ast.none or item.join != .first or item.sample_method != 0 or item.column_aliases != ast.none) return null;
                    for (q.targets[0..q.count]) |target| {
                        if (target.star) continue;
                        if (contains(pool, target.expr, .aggregate) or containsWindow(pool, target.expr)) return null;
                    }
                    var schema_buffer: [256]u8 = undefined;
                    var name_buffer: [256]u8 = undefined;
                    const schema_name: ?[]const u8 = if (item.schema) |schema| identifier(source, schema, &schema_buffer) else null;
                    const name = identifier(source, item.name, &name_buffer);
                    const base = self.findRelation(schema_name, name) orelse return null;
                    if (base.relkind != 'r' and base.relkind != 'p' and base.relkind != 'v') return null;
                    var shape: AutoShape = .{ .base = base.oid, .columns = false, .plain = @splat(false) };
                    var count: usize = 0;
                    for (q.targets[0..q.count]) |target| {
                        if (target.star) {
                            for (0..base.column_count) |_| {
                                if (count < config.columns) shape.plain[count] = true;
                                count += 1;
                            }
                            continue;
                        }
                        const node = &pool.nodes[target.expr];
                        const plain = node.kind == .column and !node.star;
                        if (count < config.columns) shape.plain[count] = plain;
                        count += 1;
                    }
                    for (shape.plain[0..@min(count, config.columns)]) |plain| shape.columns = shape.columns or plain;
                    return shape;
                }

                fn findRelation(self: *const Self, schema: ?[]const u8, name: []const u8) ?*const S.Table {
                    const namespace: u32 = if (schema) |wanted| blk: {
                        for (catalog.namespaces) |known| if (types.same(known.name, wanted)) break :blk known.oid;
                        const found = self.db.catalog.findSchema(wanted, self.snap) orelse return null;
                        break :blk found.oid;
                    } else catalog.public_namespace;
                    const found = self.db.catalog.findIn(namespace, name, self.snap) orelse return null;
                    if (found.kind == 'S') return null;
                    return &self.db.tables[found.slot];
                }

                fn contains(pool: *const A.Pool, id: u16, kind: ast.NodeKind) bool {
                    if (id == ast.none) return false;
                    const node = &pool.nodes[id];
                    if (node.kind == kind) return true;
                    for ([_]u16{ node.a, node.b, node.c }) |child| {
                        var item = child;
                        while (item != ast.none) : (item = pool.nodes[item].next) if (contains(pool, item, kind)) return true;
                    }
                    return false;
                }

                fn containsWindow(pool: *const A.Pool, id: u16) bool {
                    if (id == ast.none) return false;
                    const node = &pool.nodes[id];
                    if (node.window != ast.none) return true;
                    for ([_]u16{ node.a, node.b, node.c }) |child| {
                        var item = child;
                        while (item != ast.none) : (item = pool.nodes[item].next) if (containsWindow(pool, item)) return true;
                    }
                    return false;
                }

                /// A decoded identifier: quoted keeps case, plain folds.
                fn identifier(source: []const u8, ident: ast.Ident, out: *[256]u8) []const u8 {
                    if (ident.len > out.len) return "";
                    if (ident.quoted) {
                        lexer.decodeQuotedIdentifier(source, .{ .start = ident.span.start, .end = ident.span.start + ident.span.len, .len = ident.len }, out);
                        return out[0..ident.len];
                    }
                    const raw = ident.span.slice(source);
                    if (raw.len > out.len) return "";
                    for (raw, 0..) |byte, index| out[index] = types.lower(byte);
                    return out[0..raw.len];
                }

                const ColumnShape = struct {
                    name: []const u8,
                    position: usize,
                    data_type: DataType,
                    typmod: i32,
                    domain: ?IS.Domain = null,
                    not_null: bool = false,
                    default: Cell = .null_value,
                    identity: u8 = 0,
                    sequence: ?*const S.Table = null,
                    seq_index: ?usize = null,
                    generated: Cell = .null_value,
                    is_generated: bool = false,
                    updatable: bool = true,
                    /// A catalog table's or information_schema relation's
                    /// string column: collation "C", as initdb creates them.
                    catalog_collation: bool = false,
                    /// A stored column collation (ddl-alter definition format
                    /// 8): its pg_collation OID, 0 for the type's default.
                    collation_oid: u32 = 0,
                };

                fn columns(self: *Self) Error!void {
                    for (0..system_view_slots) |index| {
                        const view = self.systemView(index) orelse continue;
                        if (!self.seesSystemRelation(view)) continue;
                        const updatable = systemRelkind(view) == 'r';
                        for (catalog.viewColumns(view), 1..) |column, position| {
                            const data_type = if (column.domain) |domain| types.dataTypeOf(IS.domainType(domain)) else types.dataTypeOf(column.ty);
                            try self.columnRow(systemNamespace(view), @tagName(view), .{
                                .name = column.name, .position = position, .data_type = data_type,
                                .typmod = column.typmod, .domain = column.domain, .updatable = updatable,
                                .catalog_collation = updatable or IS.isInformationSchema(view),
                            });
                        }
                    }
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        switch (table.relkind) {
                            'r', 'p', 'v' => {},
                            else => continue,
                        }
                        if (!self.seesColumns(table)) continue;
                        // pg_column_is_updatable: an INSTEAD UPDATE rule, or a
                        // plain column of an automatically updatable view
                        // whose base supports UPDATE.
                        var shape: ?AutoShape = null;
                        var view_update = false;
                        var rule_update = false;
                        if (table.relkind == 'v') {
                            shape = self.autoUpdatable(table);
                            rule_update = self.ruleEvents(table) & event_update != 0;
                            view_update = self.updatableEvents(table) & event_update != 0;
                        }
                        var keys: [config.columns]u8 = undefined;
                        const primary = primaryColumns(table, &keys);
                        const schema = self.namespaceName(table.namespace);
                        for (table.columns[0..table.column_count], 0..) |*column, index| {
                            if (!self.seesColumn(table, index)) continue;
                            const kind = column.default_kind;
                            const identity: u8 = switch (kind) {
                                .identity_always => 'a',
                                .identity_by_default => 'd',
                                else => 0,
                            };
                            const DbType = @typeInfo(Db).pointer.child;
                            try self.columnRow(schema, table.name.slice(), .{
                                .name = column.name.slice(),
                                .position = index + 1,
                                .data_type = if (column.data_type == .mysql_bigint_unsigned) .numeric else column.data_type,
                                .typmod = column.typmod,
                                .not_null = notNullColumn(table, index, primary),
                                .collation_oid = column.collation,
                                .default = if (kind == .default) DbType.expressionTextWithPool(self.pool, column) else .null_value,
                                .identity = identity,
                                .seq_index = if (identity != 0) self.identitySequence(table.oid, index) else null,
                                .is_generated = kind == .generated,
                                .generated = if (kind == .generated) DbType.expressionTextWithPool(self.pool, column) else .null_value,
                                .updatable = if (table.relkind == 'v') rule_update or (view_update and if (shape) |known| known.plain[index] else false) else true,
                            });
                        }
                    }
                }

                fn identitySequence(self: *const Self, table_oid: u32, column: usize) ?usize {
                    for (self.relations) |found| {
                        if (found.kind != 'S') continue;
                        const seq = &self.db.seqs[found.slot];
                        if (seq.owner == table_oid and seq.owner_column == column) return found.slot;
                    }
                    return null;
                }

                fn columnRow(self: *Self, schema: []const u8, table: []const u8, column: ColumnShape) Error!void {
                    const data_type = column.data_type;
                    const typmod = column.typmod;
                    const collation_name = if (column.collation_oid != 0) collation.nameOfOid(column.collation_oid) else if (column.catalog_collation and collation.collatable(types.typeOfData(data_type))) "C" else collationName(data_type, column.domain);
                    const composite: ?UserType = if (data_type == .record and typmod > 0) self.compositeType(@intCast(typmod)) else null;
                    const udt = if (composite) |known| known.name else udtName(data_type);
                    var identity_cells: [5]Cell = @splat(.null_value);
                    var cycle: Cell = try yesNo(false);
                    if (column.seq_index) |slot| {
                        const spec = self.db.seqs[slot].spec;
                        identity_cells = .{ try self.number(spec.start), try self.number(spec.increment), try self.number(spec.max), try self.number(spec.min), .null_value };
                        cycle = try yesNo(spec.cycle);
                    }
                    try self.add(&.{
                        try self.catalogName(),                         try self.text(schema),
                        try self.text(table),                           try self.text(column.name),
                        int(@intCast(column.position)),                 if (column.is_generated) .null_value else column.default,
                        try yesNo(!column.not_null),                        try static(if (composite != null) "USER-DEFINED" else dataTypeName(data_type)),
                        optionalInt(charMaxLength(data_type, typmod)),  optionalInt(charOctetLength(data_type, typmod)),
                        optionalInt(numericPrecision(data_type, typmod)), optionalInt(numericRadix(data_type)),
                        optionalInt(numericScale(data_type, typmod)),   optionalInt(datetimePrecision(data_type, typmod)),
                        .null_value,                                    .null_value,
                        .null_value,                                    .null_value,
                        .null_value,                                    if (collation_name != null) try self.catalogName() else .null_value,
                        if (collation_name != null) try static("pg_catalog") else .null_value, try self.optionalText(collation_name),
                        if (column.domain != null) try self.catalogName() else .null_value, if (column.domain != null) try static("information_schema") else .null_value,
                        if (column.domain) |domain| try static(IS.domainName(domain)) else .null_value, try self.catalogName(),
                        if (composite) |known| try self.text(known.schema) else try static("pg_catalog"), try self.text(udt),
                        .null_value,                                    .null_value,
                        .null_value,                                    .null_value,
                        try self.number(@intCast(column.position)),     try yesNo(false),
                        try yesNo(column.identity != 0),                    if (column.identity == 0) .null_value else try static(if (column.identity == 'a') "ALWAYS" else "BY DEFAULT"),
                        identity_cells[0],                              identity_cells[1],
                        identity_cells[2],                              identity_cells[3],
                        cycle,                                          try static(if (column.is_generated) "ALWAYS" else "NEVER"),
                        column.generated,                               try yesNo(column.updatable),
                    });
                }

                // ---- constraints --------------------------------------------

                fn constraintPrefix(self: *const Self, schema: []const u8, name: []const u8) Error![3]Cell {
                    return .{ try self.catalogName(), try self.text(schema), try self.text(name) };
                }

                fn tableConstraints(self: *Self) Error!void {
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.relkind != 'r' and table.relkind != 'p') continue;
                        if (!self.seesConstraints(table)) continue;
                        const schema = self.namespaceName(table.namespace);
                        var keys: [config.columns]u8 = undefined;
                        const primary = primaryColumns(table, &keys);
                        for (table.constraints[0..table.constraint_count]) |*constraint| {
                            if (constraint.kind != .check) continue;
                            try self.tableConstraintRow(schema, table, constraint.name.slice(), "CHECK", constraint, null);
                        }
                        for (0..table.column_count) |index| {
                            if (!notNullColumn(table, index, primary)) continue;
                            var buffer: [max_identifier + 1]u8 = undefined;
                            try self.tableConstraintRow(schema, table, columnNotNullName(table, index, &buffer), "CHECK", null, null);
                        }
                        if (S.keyed(table)) {
                            var name: [max_identifier + 8]u8 = undefined;
                            const item = if (S.primaryConstraint(table)) |position| &table.constraints[position] else null;
                            try self.tableConstraintRow(schema, table, primaryName(table, &name), "PRIMARY KEY", item, null);
                        }
                        for (table.constraints[0..table.constraint_count]) |*constraint| {
                            const kind: []const u8 = switch (constraint.kind) {
                                .unique => "UNIQUE",
                                .foreign => "FOREIGN KEY",
                                else => continue,
                            };
                            try self.tableConstraintRow(schema, table, constraint.name.slice(), kind, constraint, if (constraint.kind == .unique) !constraint.nulls_not_distinct else null);
                        }
                    }
                }

                fn tableConstraintRow(self: *Self, schema: []const u8, table: *const S.Table, name: []const u8, kind: []const u8, constraint: ?*const S.Constraint, nulls_distinct: ?bool) Error!void {
                    const prefix = try self.constraintPrefix(schema, name);
                    const deferrable = if (constraint) |item| item.deferrable else false;
                    const deferred = if (constraint) |item| item.initially_deferred else false;
                    const enforced = if (constraint) |item| !item.not_enforced else true;
                    try self.add(&.{
                        prefix[0], prefix[1], prefix[2], try self.catalogName(), try self.text(schema), try self.text(table.name.slice()),
                        try static(kind), try yesNo(deferrable), try yesNo(deferred), try yesNo(enforced),
                        if (nulls_distinct) |yes| try yesNo(yes) else .null_value,
                    });
                }

                fn checkConstraints(self: *Self) Error!void {
                    // information_schema's own domains (cardinal_number,
                    // yes_or_no) come first, as initdb creates them.
                    if (self.hasRole(CO.bootstrap_role)) {
                        try self.checkRow("information_schema", "cardinal_number_domain_check", "(VALUE >= 0)");
                        try self.checkRow("information_schema", "yes_or_no_check", "((VALUE)::text = ANY ((ARRAY['YES'::character varying, 'NO'::character varying])::text[]))");
                    }
                    for (&self.objects().items) |*o| {
                        if (o.kind != .domain or !O.visible(o, self.snap) or !self.hasRole(o.owner)) continue;
                        if (o.domain.comparison != .none) {
                            var name: [max_identifier + 1]u8 = undefined;
                            var clause: [64]u8 = undefined;
                            try self.checkRow(self.namespaceName(o.target), domainConstraintName(o.name.slice(), "check", &name), domainCheckClause(o.domain, &clause));
                        }
                    }
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (!self.hasRole(self.tableOwner(table))) continue;
                        const schema = self.namespaceName(table.namespace);
                        for (table.constraints[0..table.constraint_count]) |*constraint| {
                            if (constraint.kind != .check) continue;
                            var clause: [config.text_bytes + 2]u8 = undefined;
                            const expression = constraint.expression.slice();
                            if (expression.len + 2 > clause.len) return error.TextCapacity;
                            clause[0] = '(';
                            @memcpy(clause[1..][0..expression.len], expression);
                            clause[expression.len + 1] = ')';
                            try self.checkRow(schema, constraint.name.slice(), clause[0 .. expression.len + 2]);
                        }
                    }
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.relkind != 'r' and table.relkind != 'p') continue;
                        if (!self.hasRole(self.tableOwner(table))) continue;
                        const schema = self.namespaceName(table.namespace);
                        var keys: [config.columns]u8 = undefined;
                        const primary = primaryColumns(table, &keys);
                        for (0..table.column_count) |index| {
                            if (!notNullColumn(table, index, primary)) continue;
                            var name: [max_identifier + 1]u8 = undefined;
                            var clause: [max_identifier + 24]u8 = undefined;
                            const column = table.columns[index].name.slice();
                            const text_clause = std.fmt.bufPrint(&clause, "{s} IS NOT NULL", .{column}) catch return error.TextCapacity;
                            try self.checkRow(schema, columnNotNullName(table, index, &name), text_clause);
                        }
                    }
                    for (&self.objects().items) |*o| {
                        if (o.kind != .domain or !O.visible(o, self.snap) or !self.hasRole(o.owner) or !o.domain.not_null) continue;
                        var name: [max_identifier + 1]u8 = undefined;
                        try self.checkRow(self.namespaceName(o.target), domainConstraintName(o.name.slice(), "not_null", &name), "VALUE IS NOT NULL");
                    }
                }

                fn checkRow(self: *Self, schema: []const u8, name: []const u8, clause: []const u8) Error!void {
                    const prefix = try self.constraintPrefix(schema, name);
                    try self.add(&.{ prefix[0], prefix[1], prefix[2], try self.text(clause) });
                }

                /// `<domain>_<label>`, the domain part cut to fit.
                fn domainConstraintName(domain: []const u8, label: []const u8, out: *[max_identifier + 1]u8) []const u8 {
                    const keep = clipUtf8(domain, @min(domain.len, @min(max_identifier, config.name_bytes) -| (label.len + 1)));
                    @memcpy(out[0..keep], domain[0..keep]);
                    out[keep] = '_';
                    @memcpy(out[keep + 1 ..][0..label.len], label);
                    return out[0 .. keep + 1 + label.len];
                }

                fn domainCheckClause(domain: CO.Domain, out: *[64]u8) []const u8 {
                    const op: []const u8 = switch (domain.comparison) {
                        .eq => "=",
                        .ne => "<>",
                        .lt => "<",
                        .le => "<=",
                        .gt => ">",
                        .ge => ">=",
                        .none => return "",
                    };
                    return std.fmt.bufPrint(out, "(VALUE {s} {d})", .{ op, domain.bound }) catch "";
                }

                fn keyColumnUsage(self: *Self) Error!void {
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.relkind != 'r' and table.relkind != 'p') continue;
                        if (!self.seesColumns(table)) continue;
                        const schema = self.namespaceName(table.namespace);
                        var keys: [config.columns]u8 = undefined;
                        const primary = primaryColumns(table, &keys);
                        if (primary.len != 0) {
                            var name: [max_identifier + 8]u8 = undefined;
                            const pkey = primaryName(table, &name);
                            for (primary, 1..) |column, position| try self.keyRow(schema, pkey, table, column, position, null);
                        }
                        for (table.constraints[0..table.constraint_count]) |*constraint| {
                            switch (constraint.kind) {
                                .unique => for (constraint.keyColumns(), 1..) |column, position| {
                                    try self.keyRow(schema, constraint.name.slice(), table, column, position, null);
                                },
                                .foreign => {
                                    var parent_keys: [config.columns]u8 = undefined;
                                    var parent_name: [max_identifier + 8]u8 = undefined;
                                    const parent = self.visibleTable(constraint.ref_oid);
                                    const referenced = if (parent) |known| self.referencedKey(constraint, known, &parent_keys, &parent_name) else null;
                                    for (constraint.keyColumns(), constraint.refColumns(), 1..) |column, ref_column, position| {
                                        var unique_position: ?i64 = null;
                                        if (referenced) |key| {
                                            if (std.mem.indexOfScalar(u8, key.columns, ref_column)) |at| unique_position = @intCast(at + 1);
                                        }
                                        try self.keyRow(schema, constraint.name.slice(), table, column, position, unique_position);
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }

                fn keyRow(self: *Self, schema: []const u8, name: []const u8, table: *const S.Table, column: u8, position: usize, unique_position: ?i64) Error!void {
                    if (!self.seesColumn(table, column)) return;
                    const prefix = try self.constraintPrefix(schema, name);
                    try self.add(&.{
                        prefix[0], prefix[1], prefix[2], try self.catalogName(), try self.text(schema), try self.text(table.name.slice()),
                        try self.text(table.columns[column].name.slice()), int(@intCast(position)), optionalInt(unique_position),
                    });
                }

                fn referentialConstraints(self: *Self) Error!void {
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (!self.seesConstraints(table)) continue;
                        const schema = self.namespaceName(table.namespace);
                        for (table.constraints[0..table.constraint_count]) |*constraint| {
                            if (constraint.kind != .foreign) continue;
                            var parent_keys: [config.columns]u8 = undefined;
                            var parent_name: [max_identifier + 8]u8 = undefined;
                            const parent = self.visibleTable(constraint.ref_oid);
                            const referenced = if (parent) |known| self.referencedKey(constraint, known, &parent_keys, &parent_name) else null;
                            const unique_name: ?[]const u8 = if (referenced) |key| key.name else null;
                            const prefix = try self.constraintPrefix(schema, constraint.name.slice());
                            try self.add(&.{
                                prefix[0], prefix[1], prefix[2],
                                if (unique_name != null) try self.catalogName() else .null_value,
                                if (unique_name != null) try self.text(self.namespaceName(parent.?.namespace)) else .null_value,
                                try self.optionalText(unique_name),
                                try static("NONE"), try static(actionText(constraint.on_update)), try static(actionText(constraint.on_delete)),
                            });
                        }
                    }
                }

                fn actionText(action: S.ForeignAction) []const u8 {
                    return switch (action) {
                        .no_action => "NO ACTION",
                        .restrict => "RESTRICT",
                        .cascade => "CASCADE",
                        .set_null => "SET NULL",
                        .set_default => "SET DEFAULT",
                    };
                }

                fn usageRow(self: *Self, table_schema: []const u8, table: []const u8, column: ?[]const u8, constraint_schema: []const u8, constraint: []const u8) Error!void {
                    if (column) |name| {
                        try self.add(&.{ try self.catalogName(), try self.text(table_schema), try self.text(table), try self.text(name),
                            try self.catalogName(), try self.text(constraint_schema), try self.text(constraint) });
                    } else {
                        try self.add(&.{ try self.catalogName(), try self.text(table_schema), try self.text(table),
                            try self.catalogName(), try self.text(constraint_schema), try self.text(constraint) });
                    }
                }

                fn constraintColumnUsage(self: *Self) Error!void {
                    // CHECK constraints: the columns their expression names.
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.relkind != 'r' and table.relkind != 'p') continue;
                        if (!self.hasRole(self.tableOwner(table))) continue;
                        const schema = self.namespaceName(table.namespace);
                        for (table.constraints[0..table.constraint_count]) |*constraint| {
                            if (constraint.kind != .check) continue;
                            const used = self.expressionColumns(table, constraint.expression.slice());
                            for (0..table.column_count) |column| {
                                if (used & (@as(u256, 1) << @intCast(column)) == 0) continue;
                                try self.usageRow(schema, table.name.slice(), table.columns[column].name.slice(), schema, constraint.name.slice());
                            }
                        }
                    }
                    // NOT NULL constraints.
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.relkind != 'r' and table.relkind != 'p') continue;
                        if (!self.hasRole(self.tableOwner(table))) continue;
                        const schema = self.namespaceName(table.namespace);
                        var keys: [config.columns]u8 = undefined;
                        const primary = primaryColumns(table, &keys);
                        for (0..table.column_count) |index| {
                            if (!notNullColumn(table, index, primary)) continue;
                            var name: [max_identifier + 1]u8 = undefined;
                            const column = table.columns[index].name.slice();
                            try self.usageRow(schema, table.name.slice(), column, schema, columnNotNullName(table, index, &name));
                        }
                    }
                    // PRIMARY KEY, UNIQUE and FOREIGN KEY (referenced columns).
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.relkind != 'r' and table.relkind != 'p') continue;
                        const schema = self.namespaceName(table.namespace);
                        var keys: [config.columns]u8 = undefined;
                        const primary = primaryColumns(table, &keys);
                        if (primary.len != 0 and self.hasRole(self.tableOwner(table))) {
                            var name: [max_identifier + 8]u8 = undefined;
                            const pkey = primaryName(table, &name);
                            for (0..table.column_count) |column| {
                                if (std.mem.indexOfScalar(u8, primary, @intCast(column)) == null) continue;
                                try self.usageRow(schema, table.name.slice(), table.columns[column].name.slice(), schema, pkey);
                            }
                        }
                        for (table.constraints[0..table.constraint_count]) |*constraint| {
                            switch (constraint.kind) {
                                .unique => {
                                    if (!self.hasRole(self.tableOwner(table))) continue;
                                    for (0..table.column_count) |column| {
                                        if (std.mem.indexOfScalar(u8, constraint.keyColumns(), @intCast(column)) == null) continue;
                                        try self.usageRow(schema, table.name.slice(), table.columns[column].name.slice(), schema, constraint.name.slice());
                                    }
                                },
                                .foreign => {
                                    const parent = self.visibleTable(constraint.ref_oid) orelse continue;
                                    if (parent.relkind != 'r' and parent.relkind != 'p') continue;
                                    if (!self.hasRole(self.tableOwner(parent))) continue;
                                    const parent_schema = self.namespaceName(parent.namespace);
                                    for (0..parent.column_count) |column| {
                                        if (std.mem.indexOfScalar(u8, constraint.refColumns(), @intCast(column)) == null) continue;
                                        try self.usageRow(parent_schema, parent.name.slice(), parent.columns[column].name.slice(), schema, constraint.name.slice());
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }

                /// The table columns a stored expression names (bit per
                /// column), parsed into the pool above its live nodes.
                fn expressionColumns(self: *Self, table: *const S.Table, source: []const u8) u256 {
                    const pool = self.pool;
                    const saved = .{ pool.len, pool.query_len, pool.window_len, pool.complex };
                    defer {
                        pool.len = saved[0];
                        pool.query_len = saved[1];
                        pool.window_len = saved[2];
                        pool.complex = saved[3];
                    }
                    const first = pool.len;
                    _ = P.parseExpression(source, pool) catch return 0;
                    var used: u256 = 0;
                    for (pool.nodes[first..pool.len]) |*node| {
                        if (node.kind != .column or node.star) continue;
                        var buffer: [256]u8 = undefined;
                        const name = identifier(source, node.name, &buffer);
                        for (table.columns[0..table.column_count], 0..) |*column, index| {
                            if (types.same(column.name.slice(), name)) used |= @as(u256, 1) << @intCast(index);
                        }
                    }
                    return used;
                }

                fn constraintTableUsage(self: *Self) Error!void {
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (table.relkind != 'r' and table.relkind != 'p') continue;
                        const schema = self.namespaceName(table.namespace);
                        if (S.keyed(table) and self.hasRole(self.tableOwner(table))) {
                            var name: [max_identifier + 8]u8 = undefined;
                            try self.usageRow(schema, table.name.slice(), null, schema, primaryName(table, &name));
                        }
                        for (table.constraints[0..table.constraint_count]) |*constraint| {
                            switch (constraint.kind) {
                                .unique => if (self.hasRole(self.tableOwner(table))) {
                                    try self.usageRow(schema, table.name.slice(), null, schema, constraint.name.slice());
                                },
                                .foreign => {
                                    const parent = self.visibleTable(constraint.ref_oid) orelse continue;
                                    if (parent.relkind != 'r' and parent.relkind != 'p') continue;
                                    if (!self.hasRole(self.tableOwner(parent))) continue;
                                    try self.usageRow(self.namespaceName(parent.namespace), parent.name.slice(), null, schema, constraint.name.slice());
                                },
                                else => {},
                            }
                        }
                    }
                }

                // ---- privileges ---------------------------------------------

                /// One aclexplode entry: grantor, grantee, privileges and
                /// their grant options (is_grantable).
                const AclEntry = struct { grantor: u32, grantee: u32, flags: u32, options: u32 };

                const AclKey = @typeInfo(Db).pointer.child.AclKey;

                /// aclexplode(coalesce(acl, acldefault)) of an object, one
                /// entry per call in ACL order (the privileges lane's model:
                /// owner entry, grants with their grantors and options).
                const AclCursor = struct {
                    kind: CO.Kind,
                    target: u32,
                    owner: u32,
                    after: ?AclKey = null,

                    fn next(cursor: *AclCursor, context: *const Self) ?AclEntry {
                        const item = context.db.nextAclItem(cursor.kind, cursor.target, cursor.owner, cursor.after, context.snap) orelse return null;
                        cursor.after = item.key;
                        return .{ .grantor = item.grantor, .grantee = item.grantee, .flags = item.privileges, .options = item.options };
                    }
                };

                /// aclexplode(attacl) of one column (0-based; none by default).
                const ColumnCursor = struct {
                    table: u32,
                    column: usize,
                    after: ?AclKey = null,

                    fn next(cursor: *ColumnCursor, context: *const Self) ?AclEntry {
                        const item = context.db.nextColumnAclItem(cursor.table, cursor.column, cursor.after, context.snap) orelse return null;
                        cursor.after = item.key;
                        return .{ .grantor = item.grantor, .grantee = item.grantee, .flags = item.privileges, .options = item.options };
                    }
                };

                /// The relacl entry of (grantee, grantor) on a table, if any.
                fn relationEntry(self: *const Self, table_oid: u32, owner: u32, grantee: u32, grantor: u32) ?AclEntry {
                    var cursor: AclCursor = .{ .kind = .acl, .target = table_oid, .owner = owner };
                    while (cursor.next(self)) |entry| {
                        if (entry.grantee == grantee and entry.grantor == grantor) return entry;
                    }
                    return null;
                }

                fn systemAcl(view: View, out: *[2]AclEntry) []const AclEntry {
                    out[0] = .{ .grantor = CO.bootstrap_role, .grantee = CO.bootstrap_role, .flags = CO.table_privileges, .options = 0 };
                    if (!publicSelect(view)) return out[0..1];
                    out[1] = .{ .grantor = CO.bootstrap_role, .grantee = CO.public_role, .flags = CO.priv_select, .options = 0 };
                    return out[0..2];
                }

                /// role_*_grants: the grantor or grantee is an enabled role.
                fn enabledGrant(self: *const Self, grantor: u32, grantee: u32) bool {
                    return self.hasRole(grantor) or self.hasRole(grantee);
                }

                fn tablePrivileges(self: *Self, role_grants: bool) Error!void {
                    var entries: [2]AclEntry = undefined;
                    for (0..system_view_slots) |index| {
                        const view = self.systemView(index) orelse continue;
                        const kind = systemRelkind(view);
                        _ = kind;
                        for (systemAcl(view, &entries)) |entry| {
                            try self.tablePrivilegeRows(systemNamespace(view), @tagName(view), CO.bootstrap_role, entry, role_grants);
                        }
                    }
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        switch (table.relkind) {
                            'r', 'p', 'v', 'f' => {},
                            else => continue,
                        }
                        const owner = self.tableOwner(table);
                        const schema = self.namespaceName(table.namespace);
                        var cursor: AclCursor = .{ .kind = .acl, .target = table.oid, .owner = owner };
                        while (cursor.next(self)) |entry| try self.tablePrivilegeRows(schema, table.name.slice(), owner, entry, role_grants);
                    }
                }

                fn tablePrivilegeRows(self: *Self, schema: []const u8, name: []const u8, owner: u32, entry: AclEntry, role_grants: bool) Error!void {
                    if (!self.showsGrant(entry.grantor, entry.grantee)) return;
                    if (role_grants and !self.enabledGrant(entry.grantor, entry.grantee)) return;
                    const grantable_owner = self.roleHasRole(entry.grantee, owner);
                    for (CO.privilege_bits, CO.privilege_sql) |bit, spelling| {
                        if (entry.flags & bit == 0 or bit == CO.priv_maintain) continue;
                        try self.add(&.{
                            try self.text(self.roleName(entry.grantor)), try self.text(self.roleName(entry.grantee)), try self.catalogName(),
                            try self.text(schema), try self.text(name), try static(spelling),
                            try yesNo(grantable_owner or entry.options & bit != 0), try yesNo(bit == CO.priv_select),
                        });
                    }
                }

                /// The UNION of aclexplode(relacl) over every column and
                /// aclexplode(attacl) per column: a column entry repeating
                /// a table entry (same grantor, grantee, privilege and
                /// grantability) is listed once.
                fn columnPrivileges(self: *Self, role_grants: bool) Error!void {
                    var entries: [2]AclEntry = undefined;
                    for (0..system_view_slots) |index| {
                        const view = self.systemView(index) orelse continue;
                        const acl = systemAcl(view, &entries);
                        for (catalog.viewColumns(view)) |column| {
                            for (acl) |entry| try self.columnPrivilegeRows(systemNamespace(view), @tagName(view), column.name, CO.bootstrap_role, entry, role_grants);
                        }
                    }
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        switch (table.relkind) {
                            'r', 'p', 'v', 'f' => {},
                            else => continue,
                        }
                        const owner = self.tableOwner(table);
                        const schema = self.namespaceName(table.namespace);
                        for (table.columns[0..table.column_count], 0..) |*column, index| {
                            var cursor: AclCursor = .{ .kind = .acl, .target = table.oid, .owner = owner };
                            while (cursor.next(self)) |entry| try self.columnPrivilegeRows(schema, table.name.slice(), column.name.slice(), owner, entry, role_grants);
                            var own: ColumnCursor = .{ .table = table.oid, .column = index };
                            while (own.next(self)) |entry| {
                                var unique = entry;
                                if (self.relationEntry(table.oid, owner, entry.grantee, entry.grantor)) |shared| {
                                    // Bits whose grantability matches the table entry's.
                                    const same = shared.flags & ~(shared.options ^ entry.options);
                                    unique.flags &= ~same;
                                    unique.options &= unique.flags;
                                }
                                try self.columnPrivilegeRows(schema, table.name.slice(), column.name.slice(), owner, unique, role_grants);
                            }
                        }
                    }
                }

                fn columnPrivilegeRows(self: *Self, schema: []const u8, table: []const u8, column: []const u8, owner: u32, entry: AclEntry, role_grants: bool) Error!void {
                    if (entry.flags & column_privilege_mask == 0) return;
                    if (!self.showsGrant(entry.grantor, entry.grantee)) return;
                    if (role_grants and !self.enabledGrant(entry.grantor, entry.grantee)) return;
                    const grantable_owner = self.roleHasRole(entry.grantee, owner);
                    for (CO.privilege_bits, CO.privilege_sql) |bit, spelling| {
                        if (entry.flags & bit & column_privilege_mask == 0) continue;
                        try self.add(&.{
                            try self.text(self.roleName(entry.grantor)), try self.text(self.roleName(entry.grantee)), try self.catalogName(),
                            try self.text(schema), try self.text(table), try self.text(column), try static(spelling),
                            try yesNo(grantable_owner or entry.options & bit != 0),
                        });
                    }
                }

                // ---- roles --------------------------------------------------

                fn enabledRoles(self: *Self) Error!void {
                    if (self.hasRole(CO.bootstrap_role)) try self.add(&.{try static(CO.bootstrap_name)});
                    for (&self.objects().items) |*o| {
                        if (o.kind != .role or !O.visible(o, self.snap) or !self.hasRole(o.oid)) continue;
                        try self.add(&.{try self.text(o.name.slice())});
                    }
                }

                fn applicableRoles(self: *Self, administrable: bool) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .member or !O.visible(o, self.snap) or !self.hasRole(o.grantee)) continue;
                        const admin = o.grant_flags & CO.member_admin != 0;
                        if (administrable and !admin) continue;
                        try self.add(&.{ try self.text(self.roleName(o.grantee)), try self.text(self.roleName(o.target)), try yesNo(admin) });
                    }
                }

                // ---- routines -----------------------------------------------

                const RoutineShape = struct {
                    oid: u32,
                    name: []const u8,
                    namespace: u32 = catalog.catalog_namespace,
                    owner: u32 = CO.bootstrap_role,
                    kind: u8 = 'f',
                    language: u32,
                    volatility: u8,
                    strict: bool,
                    result: u32,
                    source: []const u8,
                    definer: bool = false,
                    user: ?*const RC.Routine = null,
                    builtin_args: []const u32 = &.{},
                    owner_only: bool = false,
                };

                /// Every routine pg_proc lists, in its order.
                fn routineAt(self: *const Self, index: usize) ?RoutineShape {
                    var position = index;
                    if (position < catalog.builtin_callbacks.len) {
                        const callback = catalog.builtin_callbacks[position];
                        return .{ .oid = callback.oid, .name = callback.name, .language = callback.language, .volatility = callback.volatility,
                            .strict = callback.strict, .result = callback.result, .source = callback.source orelse callback.name,
                            .builtin_args = callback.args, .owner_only = callback.owner_execute_only };
                    }
                    position -= catalog.builtin_callbacks.len;
                    if (position < catalog.access_methods.len) {
                        const am = catalog.access_methods[position];
                        return .{ .oid = am.handler, .name = am.handler_name, .language = operator_catalog.internal_language_oid, .volatility = 'v',
                            .strict = true, .result = am.result, .source = am.handler_name, .builtin_args = &internal_argument };
                    }
                    position -= catalog.access_methods.len;
                    if (position < operator_catalog.functions.len) return null;
                    position -= operator_catalog.functions.len;
                    if (position >= config.routines) return null;
                    const routine = &self.db.objects.routines[position];
                    if (!routine.live or !routine.stamp.visible(self.snap)) return null;
                    return .{ .oid = routine.oid, .name = routine.name.slice(), .namespace = routine.namespace, .owner = routine.owner,
                        .kind = routine.kind, .language = if (routine.language == 0) catalog.sql_language_oid else catalog.plpgsql_language_oid,
                        .volatility = routine.volatility, .strict = routine.strict, .result = routine.return_oid,
                        .source = routine.body.slice(), .definer = routine.security_definer, .user = routine };
                }

                const internal_argument = [_]u32{catalog.internal_type_oid};

                const routine_slots = catalog.builtin_callbacks.len + catalog.access_methods.len + operator_catalog.functions.len + config.routines;

                /// Operator functions are listed through their own table.
                fn operatorRoutine(index: usize) ?RoutineShape {
                    const start = catalog.builtin_callbacks.len + catalog.access_methods.len;
                    if (index < start or index >= start + operator_catalog.functions.len) return null;
                    const op = operator_catalog.functions[index - start];
                    return .{ .oid = op.function_oid, .name = op.function_name, .language = operator_catalog.internal_language_oid,
                        .volatility = op.volatility, .strict = op.strict, .result = op.result, .source = op.function_name };
                }

                fn routineShape(self: *const Self, index: usize) ?RoutineShape {
                    return operatorRoutine(index) orelse self.routineAt(index);
                }

                /// The input types of a routine in declaration order.
                fn operatorArguments(index: usize, out: *[2]u32) []const u32 {
                    const start = catalog.builtin_callbacks.len + catalog.access_methods.len;
                    const op = operator_catalog.functions[index - start];
                    if (op.left == 0) {
                        out[0] = op.right;
                        return out[0..1];
                    }
                    out.* = .{ op.left, op.right };
                    return out[0..2];
                }

                /// pg_has_role(proowner) OR has_function_privilege(EXECUTE).
                fn seesRoutine(self: *const Self, routine: *const RoutineShape) bool {
                    if (self.hasRole(routine.owner)) return true;
                    var edges: [@as(usize, config.routine_acl_entries) + 2]privilege_graph.Edge = undefined;
                    const acl = self.routineEdges(routine, &edges);
                    for (acl) |edge| {
                        if (edge.flags == 0) continue;
                        if (edge.grantee == CO.public_role or self.objects().memberOf(self.role, edge.grantee, true, self.snap)) return true;
                    }
                    return false;
                }

                /// aclexplode(coalesce(proacl, acldefault('f', proowner))).
                fn routineEdges(self: *const Self, routine: *const RoutineShape, out: *[@as(usize, config.routine_acl_entries) + 2]privilege_graph.Edge) []const privilege_graph.Edge {
                    const execute: u32 = 1 << 7;
                    if (routine.user) |user| {
                        if (user.acl.explicit) {
                            const graph = user.acl.graph(user.owner, out);
                            var states: [@as(usize, config.routine_acl_entries) + 2]privilege_graph.Graph.State = undefined;
                            graph.start(&states);
                            var ordered: [@as(usize, config.routine_acl_entries) + 2]privilege_graph.Edge = undefined;
                            var count: usize = 0;
                            while (graph.next(&states)) |step| {
                                ordered[count] = out[step.index];
                                ordered[count].flags = step.flags;
                                count += 1;
                            }
                            @memcpy(out[0..count], ordered[0..count]);
                            return out[0..count];
                        }
                    } else if (routine.owner_only or self.builtinRestricted(routine.oid)) {
                        out[0] = .{ .grantor = routine.owner, .grantee = routine.owner, .flags = execute, .options = 0 };
                        return out[0..1];
                    }
                    out[0] = .{ .grantor = routine.owner, .grantee = CO.public_role, .flags = execute, .options = 0 };
                    out[1] = .{ .grantor = routine.owner, .grantee = routine.owner, .flags = execute, .options = 0 };
                    return out[0..2];
                }

                fn builtinRestricted(self: *const Self, oid: u32) bool {
                    _ = self;
                    return CO.restrictedRoutine(oid);
                }

                /// format_type of a routine's argument or result type,
                /// including the pseudo-types routines use.
                fn typeName(oid: u32) []const u8 {
                    if (types.regtypeName(oid)) |name| return name;
                    return pseudoTypeName(oid);
                }

                fn pseudoTypeName(oid: u32) []const u8 {
                    for (catalog.builtin_pseudo_types) |pseudo| if (pseudo.oid == oid) return pseudo.name;
                    return switch (oid) {
                        routine_catalog.void_oid => "void",
                        routine_catalog.trigger_oid => "trigger",
                        2249 => "record",
                        else => "-",
                    };
                }

                fn typeUdtName(oid: u32) []const u8 {
                    if (types.typeFromOid(oid)) |data_type| return udtName(data_type);
                    return pseudoTypeName(oid);
                }

                fn typeDataName(oid: u32) []const u8 {
                    if (types.typeFromOid(oid)) |data_type| return dataTypeName(data_type);
                    return typeName(oid);
                }

                fn languageName(oid: u32) []const u8 {
                    return switch (oid) {
                        operator_catalog.internal_language_oid => "INTERNAL",
                        catalog.sql_language_oid => "SQL",
                        catalog.plpgsql_language_oid => "PLPGSQL",
                        else => "C",
                    };
                }

                fn routines(self: *Self) Error!void {
                    for (0..routine_slots) |index| {
                        const routine = self.routineShape(index) orelse continue;
                        if (!self.seesRoutine(&routine)) continue;
                        const schema = self.namespaceName(routine.namespace);
                        const procedure = routine.kind == 'p';
                        var cells: [82]Cell = @splat(.null_value);
                        cells[0] = try self.catalogName();
                        cells[1] = try self.text(schema);
                        cells[2] = try self.specificName(routine.name, routine.oid);
                        cells[3] = try self.catalogName();
                        cells[4] = try self.text(schema);
                        cells[5] = try self.text(routine.name);
                        cells[6] = try static(if (procedure) "PROCEDURE" else "FUNCTION");
                        if (!procedure) {
                            const composite = self.compositeType(routine.result);
                            cells[13] = try static(if (composite != null) "USER-DEFINED" else typeDataName(routine.result));
                            cells[28] = try self.catalogName();
                            cells[29] = if (composite) |known| try self.text(known.schema) else try static("pg_catalog");
                            cells[30] = if (composite) |known| try self.text(known.name) else try static(typeUdtName(routine.result));
                            cells[35] = try static("0");
                        }
                        cells[36] = try static(if (routine.language == catalog.sql_language_oid) "SQL" else "EXTERNAL");
                        if (self.hasRole(routine.owner)) cells[37] = try self.text(routine.source);
                        cells[39] = try static(languageName(routine.language));
                        cells[40] = try static("GENERAL");
                        cells[41] = try yesNo(routine.volatility == 'i');
                        cells[42] = try static("MODIFIES");
                        if (!procedure) cells[43] = try yesNo(routine.strict);
                        cells[45] = try yesNo(true);
                        cells[46] = int(0);
                        cells[49] = try static(if (routine.definer) "DEFINER" else "INVOKER");
                        cells[53] = try yesNo(false);
                        cells[57] = try yesNo(false);
                        try self.add(&cells);
                    }
                }

                const Parameter = struct { oid: u32, mode: u8, name: []const u8, default: ?[]const u8 = null };

                /// proallargtypes order: every declared parameter.
                fn routineParameters(self: *const Self, index: usize, routine: *const RoutineShape, out: *[@as(usize, config.routine_args) * 2 + 2]Parameter) []const Parameter {
                    _ = self;
                    var count: usize = 0;
                    if (routine.user) |user| {
                        if (user.param_count == 0) {
                            for (user.args(), 0..) |oid, position| {
                                out[count] = .{ .oid = oid, .mode = user.arg_modes[position], .name = user.arg_names[position].slice(),
                                    .default = if (position >= user.arg_count - user.default_count) user.defaultText(position) else null };
                                count += 1;
                            }
                            return out[0..count];
                        }
                        var input: usize = 0;
                        var output: usize = 0;
                        for (user.param_modes[0..user.param_count]) |mode| {
                            switch (mode) {
                                'i', 'b', 'v' => {
                                    if (input >= user.arg_count) break;
                                    out[count] = .{ .oid = user.arg_oids[input], .mode = mode, .name = user.arg_names[input].slice(),
                                        .default = if (input >= user.arg_count - user.default_count) user.defaultText(input) else null };
                                    if (mode == 'b') {
                                        while (output < user.out_count and user.out_inputs[output] != input) output += 1;
                                        if (output < user.out_count) output += 1;
                                    }
                                    input += 1;
                                },
                                else => {
                                    while (output < user.out_count and user.out_inputs[output] != 0xff) output += 1;
                                    if (output >= user.out_count) break;
                                    out[count] = .{ .oid = user.out_oids[output], .mode = mode, .name = user.out_names[output].slice() };
                                    output += 1;
                                },
                            }
                            count += 1;
                        }
                        return out[0..count];
                    }
                    var pair: [2]u32 = undefined;
                    const args = if (operatorRoutine(index) != null) operatorArguments(index, &pair) else routine.builtin_args;
                    for (args) |oid| {
                        out[count] = .{ .oid = oid, .mode = 'i', .name = "" };
                        count += 1;
                    }
                    return out[0..count];
                }

                fn parameters(self: *Self) Error!void {
                    for (0..routine_slots) |index| {
                        const routine = self.routineShape(index) orelse continue;
                        if (!self.seesRoutine(&routine)) continue;
                        var buffer: [@as(usize, config.routine_args) * 2 + 2]Parameter = undefined;
                        const list = self.routineParameters(index, &routine, &buffer);
                        const schema = self.namespaceName(routine.namespace);
                        const owner_sees = self.hasRole(routine.owner);
                        for (list, 1..) |parameter, position| {
                            var cells: [32]Cell = @splat(.null_value);
                            cells[0] = try self.catalogName();
                            cells[1] = try self.text(schema);
                            cells[2] = try self.specificName(routine.name, routine.oid);
                            cells[3] = int(@intCast(position));
                            cells[4] = try static(switch (parameter.mode) {
                                'o', 't' => "OUT",
                                'b' => "INOUT",
                                else => "IN",
                            });
                            cells[5] = try yesNo(false);
                            cells[6] = try yesNo(false);
                            if (parameter.name.len != 0) cells[7] = try self.text(parameter.name);
                            const composite = self.compositeType(parameter.oid);
                            cells[8] = try static(if (composite != null) "USER-DEFINED" else typeDataName(parameter.oid));
                            cells[23] = try self.catalogName();
                            cells[24] = if (composite) |known| try self.text(known.schema) else try static("pg_catalog");
                            cells[25] = if (composite) |known| try self.text(known.name) else try static(typeUdtName(parameter.oid));
                            cells[30] = try self.number(@intCast(position));
                            if (owner_sees) {
                                if (parameter.default) |default| cells[31] = self.typedDefault(default, parameter.oid);
                            }
                            try self.add(&cells);
                        }
                    }
                }

                /// pg_get_function_arg_default: the DEFAULT expression
                /// deparsed for the parameter's type (`'q'::text`).
                fn typedDefault(self: *Self, source: []const u8, oid: u32) Cell {
                    const pool = self.pool;
                    const saved = .{ pool.len, pool.query_len, pool.window_len, pool.complex };
                    defer {
                        pool.len = saved[0];
                        pool.query_len = saved[1];
                        pool.window_len = saved[2];
                        pool.complex = saved[3];
                    }
                    const fallback = self.text(source) catch Cell.null_value;
                    const data_type = types.typeFromOid(oid) orelse return fallback;
                    const id = P.parseExpression(source, pool) catch return fallback;
                    var out: V.Text = .{};
                    G.column(pool, source, id, data_type, &out) catch return fallback;
                    return .{ .text = out };
                }

                fn routinePrivileges(self: *Self, role_grants: bool) Error!void {
                    for (0..routine_slots) |index| {
                        const routine = self.routineShape(index) orelse continue;
                        var edges: [@as(usize, config.routine_acl_entries) + 2]privilege_graph.Edge = undefined;
                        const schema = self.namespaceName(routine.namespace);
                        for (self.routineEdges(&routine, &edges)) |edge| {
                            if (edge.flags == 0) continue;
                            if (!self.showsGrant(edge.grantor, edge.grantee)) continue;
                            if (role_grants and !self.enabledGrant(edge.grantor, edge.grantee)) continue;
                            try self.add(&.{
                                try self.text(self.roleName(edge.grantor)), try self.text(self.roleName(edge.grantee)),
                                try self.catalogName(),                     try self.text(schema),
                                try self.specificName(routine.name, routine.oid), try self.catalogName(),
                                try self.text(schema),                      try self.text(routine.name),
                                try static("EXECUTE"),                      try yesNo(self.roleHasRole(edge.grantee, routine.owner) or edge.options != 0),
                            });
                        }
                    }
                }

                // ---- sequences ----------------------------------------------

                fn sequenceOwner(self: *const Self, seq: anytype) u32 {
                    if (seq.owner == 0) return CO.bootstrap_role;
                    return self.objects().owner(seq.owner, self.snap);
                }

                /// An identity column's sequence (pg_depend deptype 'i').
                fn identityOwned(self: *const Self, seq: anytype) bool {
                    if (seq.owner == 0) return false;
                    const table = self.visibleTable(seq.owner) orelse return false;
                    if (seq.owner_column >= table.column_count) return false;
                    return switch (table.columns[seq.owner_column].default_kind) {
                        .identity_always, .identity_by_default => true,
                        else => false,
                    };
                }

                fn sequences(self: *Self) Error!void {
                    for (self.relations) |found| {
                        if (found.kind != 'S') continue;
                        const seq = &self.db.seqs[found.slot];
                        if (self.identityOwned(seq)) continue;
                        // pg_has_role(owner) or has_sequence_privilege(SELECT,
                        // UPDATE, USAGE).
                        const owner = self.sequenceOwner(seq);
                        const held = self.objects().objectPrivilegeMask(.sequence_acl, seq.oid, owner, self.role, 0, self.snap) |
                            (self.objects().predefinedPrivileges(self.role, self.snap) & (CO.priv_select | CO.priv_update));
                        if (!self.hasRole(owner) and held & (CO.priv_select | CO.priv_update | CO.priv_usage) == 0) continue;
                        const data_type = types.typeFromOid(seq.spec.type_oid) orelse .integer;
                        try self.add(&.{
                            try self.catalogName(), try self.text(self.namespaceName(seq.namespace)), try self.text(seq.name.slice()),
                            try static(types.sqlTypeName(data_type)), optionalInt(numericPrecision(data_type, -1)), int(2), int(0),
                            try self.number(seq.spec.start), try self.number(seq.spec.min), try self.number(seq.spec.max),
                            try self.number(seq.spec.increment), try yesNo(seq.spec.cycle),
                        });
                    }
                }

                // ---- domains and types --------------------------------------

                const is_domains = [_]IS.Domain{ .id, .number, .chars, .yes_no, .stamp };

                fn domains(self: *Self) Error!void {
                    // pg_type order: sql_identifier, cardinal_number, user
                    // domains interleave by OID; information_schema's own
                    // domains are listed first, then user domains.
                    for (is_domains) |domain| {
                        const data_type = types.dataTypeOf(IS.domainType(domain));
                        const typmod = IS.domainTypmod(domain);
                        try self.domainRow("information_schema", IS.domainName(domain), data_type, typmod, collationName(data_type, domain),
                            if (domain == .stamp) "CURRENT_TIMESTAMP(2)" else null);
                    }
                    for (&self.objects().items) |*o| {
                        if (o.kind != .domain or !O.visible(o, self.snap)) continue;
                        if (!self.hasRole(o.owner) and !self.typeUsage(o)) continue;
                        try self.domainRow(self.namespaceName(o.target), o.name.slice(), types.dataTypeOf(o.domain.base), -1, null, null);
                    }
                }

                /// has_type_privilege(oid, 'USAGE'): PUBLIC holds USAGE
                /// until the type's ACL is materialized.
                fn typeUsage(self: *const Self, o: *const O.Object) bool {
                    return self.objects().objectPrivilegeMask(.type_acl, o.oid, o.owner, self.role, CO.priv_usage, self.snap) & CO.priv_usage != 0;
                }

                fn domainRow(self: *Self, schema: []const u8, name: []const u8, data_type: DataType, typmod: i32, collation_name: ?[]const u8, default: ?[]const u8) Error!void {
                    try self.add(&.{
                        try self.catalogName(),                               try self.text(schema),
                        try self.text(name),                                  try static(dataTypeName(data_type)),
                        optionalInt(charMaxLength(data_type, typmod)),        optionalInt(charOctetLength(data_type, typmod)),
                        .null_value,                                          .null_value,
                        .null_value,                                          if (collation_name != null) try self.catalogName() else .null_value,
                        if (collation_name != null) try static("pg_catalog") else .null_value, try self.optionalText(collation_name),
                        optionalInt(numericPrecision(data_type, typmod)),     optionalInt(numericRadix(data_type)),
                        optionalInt(numericScale(data_type, typmod)),         optionalInt(datetimePrecision(data_type, typmod)),
                        .null_value,                                          .null_value,
                        try self.optionalText(default),                       try self.catalogName(),
                        try static("pg_catalog"),                             try static(udtName(data_type)),
                        .null_value,                                          .null_value,
                        .null_value,                                          .null_value,
                        try static("1"),
                    });
                }

                fn domainConstraints(self: *Self) Error!void {
                    try self.domainConstraintRow("information_schema", "cardinal_number_domain_check", "cardinal_number");
                    try self.domainConstraintRow("information_schema", "yes_or_no_check", "yes_or_no");
                    for (&self.objects().items) |*o| {
                        if (o.kind != .domain or !O.visible(o, self.snap)) continue;
                        if (!self.hasRole(o.owner) and !self.typeUsage(o)) continue;
                        const schema = self.namespaceName(o.target);
                        var name: [max_identifier + 1]u8 = undefined;
                        if (o.domain.not_null) try self.domainConstraintRow(schema, domainConstraintName(o.name.slice(), "not_null", &name), o.name.slice());
                        if (o.domain.comparison != .none) try self.domainConstraintRow(schema, domainConstraintName(o.name.slice(), "check", &name), o.name.slice());
                    }
                }

                fn domainConstraintRow(self: *Self, schema: []const u8, name: []const u8, domain: []const u8) Error!void {
                    const prefix = try self.constraintPrefix(schema, name);
                    try self.add(&.{ prefix[0], prefix[1], prefix[2], try self.catalogName(), try self.text(schema), try self.text(domain), try yesNo(false), try yesNo(false) });
                }

                fn domainUdtUsage(self: *Self) Error!void {
                    if (!self.hasRole(CO.bootstrap_role)) return;
                    for (&self.objects().items) |*o| {
                        if (o.kind != .domain or !O.visible(o, self.snap)) continue;
                        try self.add(&.{ try self.catalogName(), try static("pg_catalog"), try static(udtName(types.dataTypeOf(o.domain.base))),
                            try self.catalogName(), try self.text(self.namespaceName(o.target)), try self.text(o.name.slice()) });
                    }
                    for (is_domains) |domain| {
                        try self.add(&.{ try self.catalogName(), try static("pg_catalog"), try static(udtName(types.dataTypeOf(IS.domainType(domain)))),
                            try self.catalogName(), try static("information_schema"), try static(IS.domainName(domain)) });
                    }
                }

                fn usagePrivileges(self: *Self, role_grants: bool) Error!void {
                    // Collations: implicit PUBLIC usage (UTF8 or any encoding).
                    if (!role_grants) {
                        for (collation.names) |name| {
                            try self.add(&.{ try static(CO.bootstrap_name), try static("PUBLIC"), try self.catalogName(), try static("pg_catalog"),
                                try static(name), try static("COLLATION"), try static("USAGE"), try yesNo(false) });
                        }
                    } else if (self.hasRole(CO.bootstrap_role)) {
                        for (collation.names) |name| {
                            try self.add(&.{ try static(CO.bootstrap_name), try static("PUBLIC"), try self.catalogName(), try static("pg_catalog"),
                                try static(name), try static("COLLATION"), try static("USAGE"), try yesNo(false) });
                        }
                    }
                    // Domains: acldefault('T') = PUBLIC and owner USAGE.
                    for (is_domains) |domain| {
                        try self.defaultUsageRows("information_schema", IS.domainName(domain), "DOMAIN", CO.bootstrap_role, role_grants);
                    }
                    for (&self.objects().items) |*o| {
                        if (o.kind != .domain or !O.visible(o, self.snap)) continue;
                        try self.aclUsageRows(.type_acl, o.oid, self.namespaceName(o.target), o.name.slice(), "DOMAIN", o.owner, role_grants);
                    }
                    // Foreign-data wrappers and servers: owner USAGE only.
                    for (&self.objects().items) |*o| {
                        if (o.kind != .fdw or !O.visible(o, self.snap)) continue;
                        try self.ownerUsageRow("", o.name.slice(), "FOREIGN DATA WRAPPER", o.owner, role_grants);
                    }
                    for (&self.objects().items) |*o| {
                        if (o.kind != .server or !O.visible(o, self.snap)) continue;
                        try self.ownerUsageRow("", o.name.slice(), "FOREIGN SERVER", o.owner, role_grants);
                    }
                    // Sequences appear only with an explicit relacl
                    // (PostgreSQL explodes acldefault('r'), which has no
                    // USAGE).
                    for (self.relations) |found| {
                        if (found.kind != 'S') continue;
                        const seq = &self.db.seqs[found.slot];
                        const owner = self.sequenceOwner(seq);
                        if (!self.db.aclStored(.sequence_acl, seq.oid, owner, self.snap)) continue;
                        try self.aclUsageRows(.sequence_acl, seq.oid, self.namespaceName(seq.namespace), seq.name.slice(), "SEQUENCE", owner, role_grants);
                    }
                }

                /// The USAGE entries of an object's ACL.
                fn aclUsageRows(self: *Self, kind: CO.Kind, oid: u32, schema: []const u8, name: []const u8, label: []const u8, owner: u32, role_grants: bool) Error!void {
                    var cursor: AclCursor = .{ .kind = kind, .target = oid, .owner = owner };
                    while (cursor.next(self)) |entry| {
                        if (entry.flags & CO.priv_usage == 0) continue;
                        if (!self.showsGrant(entry.grantor, entry.grantee)) continue;
                        if (role_grants and !self.enabledGrant(entry.grantor, entry.grantee)) continue;
                        try self.usageGrantRow(schema, name, label, entry.grantor, entry.grantee, self.roleHasRole(entry.grantee, owner) or entry.options & CO.priv_usage != 0);
                    }
                }

                fn defaultUsageRows(self: *Self, schema: []const u8, name: []const u8, kind: []const u8, owner: u32, role_grants: bool) Error!void {
                    for ([_]u32{ CO.public_role, owner }) |grantee| {
                        if (!self.showsGrant(owner, grantee)) continue;
                        if (role_grants and !self.enabledGrant(owner, grantee)) continue;
                        try self.usageGrantRow(schema, name, kind, owner, grantee, self.roleHasRole(grantee, owner));
                    }
                }

                fn ownerUsageRow(self: *Self, schema: []const u8, name: []const u8, kind: []const u8, owner: u32, role_grants: bool) Error!void {
                    if (!self.showsGrant(owner, owner)) return;
                    if (role_grants and !self.enabledGrant(owner, owner)) return;
                    try self.usageGrantRow(schema, name, kind, owner, owner, true);
                }

                fn usageGrantRow(self: *Self, schema: []const u8, name: []const u8, kind: []const u8, grantor: u32, grantee: u32, grantable: bool) Error!void {
                    try self.add(&.{ try self.text(self.roleName(grantor)), try self.text(self.roleName(grantee)), try self.catalogName(),
                        try self.text(schema), try self.text(name), try static(kind), try static("USAGE"), try yesNo(grantable) });
                }

                fn udtPrivileges(self: *Self, role_grants: bool) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .composite_type or !O.visible(o, self.snap)) continue;
                        var cursor: AclCursor = .{ .kind = .type_acl, .target = o.oid, .owner = o.owner };
                        while (cursor.next(self)) |entry| {
                            if (entry.flags & CO.priv_usage == 0) continue;
                            if (!self.showsGrant(entry.grantor, entry.grantee)) continue;
                            if (role_grants and !self.enabledGrant(entry.grantor, entry.grantee)) continue;
                            try self.add(&.{ try self.text(self.roleName(entry.grantor)), try self.text(self.roleName(entry.grantee)), try self.catalogName(),
                                try self.text(self.namespaceName(o.target)), try self.text(o.name.slice()), try static("TYPE USAGE"),
                                try yesNo(self.roleHasRole(entry.grantee, o.owner) or entry.options & CO.priv_usage != 0) });
                        }
                    }
                }

                fn attributes(self: *Self) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .composite_type or !O.visible(o, self.snap)) continue;
                        if (!self.hasRole(o.owner) and !self.typeUsage(o)) continue;
                        const schema = self.namespaceName(o.target);
                        var fields = o.compositeFields();
                        var position: usize = 1;
                        while (fields.next()) |field| : (position += 1) {
                            const data_type = types.typeFromOid(field.oid) orelse continue;
                            const typmod = field.typmod;
                            const collation_name = collationName(data_type, null);
                            try self.add(&.{
                                try self.catalogName(),                               try self.text(schema),
                                try self.text(o.name.slice()),                        try self.text(field.name),
                                int(@intCast(position)),                              .null_value,
                                try yesNo(true),                                          try static(dataTypeName(data_type)),
                                optionalInt(charMaxLength(data_type, typmod)),        optionalInt(charOctetLength(data_type, typmod)),
                                .null_value,                                          .null_value,
                                .null_value,                                          if (collation_name != null) try self.catalogName() else .null_value,
                                if (collation_name != null) try static("pg_catalog") else .null_value, try self.optionalText(collation_name),
                                optionalInt(numericPrecision(data_type, typmod)),     optionalInt(numericRadix(data_type)),
                                optionalInt(numericScale(data_type, typmod)),         optionalInt(datetimePrecision(data_type, typmod)),
                                .null_value,                                          .null_value,
                                try self.catalogName(),                               try static("pg_catalog"),
                                try static(udtName(data_type)),                       .null_value,
                                .null_value,                                          .null_value,
                                .null_value,                                          try self.number(@intCast(position)),
                                try yesNo(false),
                            });
                        }
                    }
                }

                fn userDefinedTypes(self: *Self) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .composite_type or !O.visible(o, self.snap)) continue;
                        if (!self.hasRole(o.owner) and !self.typeUsage(o)) continue;
                        var cells: [29]Cell = @splat(.null_value);
                        cells[0] = try self.catalogName();
                        cells[1] = try self.text(self.namespaceName(o.target));
                        cells[2] = try self.text(o.name.slice());
                        cells[3] = try static("STRUCTURED");
                        cells[4] = try yesNo(true);
                        try self.add(&cells);
                    }
                }

                // ---- triggers -----------------------------------------------

                fn triggerDefinition(self: *Self, oid: u32) Error!Cell {
                    const Db0 = @typeInfo(Db).pointer.child;
                    const db_mutable: *Db0 = @constCast(self.db);
                    return @import("expr.sig").Eval(config).renderCatalogDefinition(db_mutable, &Db0.postgresTriggerDefinition, oid, false, self.sink.valueBytes());
                }

                fn triggers(self: *Self) Error!void {
                    for (&self.db.objects.triggers) |*trigger| {
                        if (!trigger.live or !trigger.stamp.visible(self.snap)) continue;
                        const table = self.visibleTable(trigger.table_oid) orelse continue;
                        if (!self.seesConstraints(table)) continue;
                        const schema = self.namespaceName(table.namespace);
                        const definition = try self.triggerDefinition(trigger.oid);
                        const full: []const u8 = if (definition == .text) definition.text.slice() else "";
                        const statement = if (std.mem.indexOf(u8, full, "EXECUTE FUNCTION")) |at| full[at..] else full;
                        var condition: ?[]const u8 = null;
                        if (self.hasRole(self.tableOwner(table))) {
                            if (std.mem.indexOf(u8, full, " WHEN (")) |start| {
                                if (std.mem.lastIndexOf(u8, full, ") EXECUTE FUNCTION")) |end| {
                                    if (end > start + 7) condition = full[start + 7 .. end];
                                }
                            }
                        }
                        for ([_]u8{ trigger_insert, trigger_delete, trigger_update }) |event| {
                            if (trigger.tgtype & event == 0) continue;
                            try self.add(&.{
                                try self.catalogName(), try self.text(schema), try self.text(trigger.name.slice()),
                                try static(switch (event) {
                                    trigger_insert => "INSERT",
                                    trigger_delete => "DELETE",
                                    else => "UPDATE",
                                }),
                                try self.catalogName(), try self.text(schema), try self.text(table.name.slice()),
                                int(self.actionOrder(trigger, table, event)),
                                try self.optionalText(condition), try self.text(statement),
                                try static(if (trigger.tgtype & trigger_row != 0) "ROW" else "STATEMENT"),
                                try static(switch (trigger.tgtype & (trigger_before | trigger_instead)) {
                                    trigger_before => "BEFORE",
                                    trigger_instead => "INSTEAD OF",
                                    else => "AFTER",
                                }),
                                // REFERENCING OLD / NEW TABLE names (T212).
                                if (trigger.old_table.len != 0) try self.text(trigger.old_table.slice()) else .null_value,
                                if (trigger.new_table.len != 0) try self.text(trigger.new_table.slice()) else .null_value,
                                .null_value, .null_value, .null_value,
                            });
                        }
                    }
                }

                /// rank() over (table, event, ROW / STATEMENT, timing)
                /// ordered by trigger name.
                fn actionOrder(self: *const Self, trigger: anytype, table: *const S.Table, event: u8) i64 {
                    var rank: i64 = 1;
                    const timing = trigger.tgtype & (trigger_before | trigger_instead);
                    for (&self.db.objects.triggers) |*other| {
                        if (!other.live or !other.stamp.visible(self.snap) or other.table_oid != table.oid) continue;
                        if (other.tgtype & event == 0 or other.tgtype & trigger_row != trigger.tgtype & trigger_row) continue;
                        if (other.tgtype & (trigger_before | trigger_instead) != timing) continue;
                        if (std.mem.order(u8, other.name.slice(), trigger.name.slice()) == .lt) rank += 1;
                    }
                    return rank;
                }

                fn triggeredUpdateColumns(self: *Self) Error!void {
                    for (&self.db.objects.triggers) |*trigger| {
                        if (!trigger.live or !trigger.stamp.visible(self.snap)) continue;
                        const table = self.visibleTable(trigger.table_oid) orelse continue;
                        const schema = self.namespaceName(table.namespace);
                        for (trigger.columns[0..trigger.column_count]) |column| {
                            if (column >= table.column_count) continue;
                            // has_column_privilege(INSERT, UPDATE, REFERENCES).
                            if (!self.columnAllowed(table, column, CO.priv_insert | CO.priv_update | CO.priv_references)) continue;
                            try self.add(&.{ try self.catalogName(), try self.text(schema), try self.text(trigger.name.slice()),
                                try self.catalogName(), try self.text(schema), try self.text(table.name.slice()),
                                try self.text(table.columns[column].name.slice()) });
                        }
                    }
                }

                // ---- view usage ---------------------------------------------

                /// view_table_usage / view_column_usage: the relations a
                /// view's definition names directly (PostgreSQL records no
                /// dependency through a base view) and the columns of each
                /// it references.
                fn viewUsage(self: *Self, with_columns: bool) Error!void {
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const view = &self.db.tables[found.slot];
                        if (view.relkind != 'v') continue;
                        const view_schema = self.namespaceName(view.namespace);
                        var direct: [config.tables]u32 = undefined;
                        var used: [config.tables]u256 = @splat(0);
                        const count = self.viewReferences(view, &direct, &used);
                        for (direct[0..count], used[0..count]) |oid, columns_used| {
                            const table = self.visibleTable(oid) orelse continue;
                            switch (table.relkind) {
                                'r', 'p', 'v', 'f' => {},
                                else => continue,
                            }
                            if (!self.hasRole(self.tableOwner(table))) continue;
                            const table_schema = self.namespaceName(table.namespace);
                            if (!with_columns) {
                                try self.add(&.{ try self.catalogName(), try self.text(view_schema), try self.text(view.name.slice()),
                                    try self.catalogName(), try self.text(table_schema), try self.text(table.name.slice()) });
                                continue;
                            }
                            for (table.columns[0..table.column_count], 0..) |*column, index| {
                                if (columns_used & (@as(u256, 1) << @intCast(index)) == 0) continue;
                                try self.add(&.{ try self.catalogName(), try self.text(view_schema), try self.text(view.name.slice()),
                                    try self.catalogName(), try self.text(table_schema), try self.text(table.name.slice()),
                                    try self.text(column.name.slice()) });
                            }
                        }
                    }
                }

                /// The relations named by a view definition's FROM items
                /// (CTE references excluded) in order of first mention, and
                /// per relation the columns referenced: `*` or `name.*`
                /// takes every column; `q.c` the column c of the items
                /// whose alias or name is q; a bare `c` the column c of
                /// every item that has one. Parsed into the statement pool
                /// above its live nodes.
                fn viewReferences(self: *Self, view: *const S.Table, direct: *[config.tables]u32, used: *[config.tables]u256) usize {
                    const pool = self.pool;
                    const saved = .{ pool.len, pool.query_len, pool.window_len, pool.complex };
                    defer {
                        pool.len = saved[0];
                        pool.query_len = saved[1];
                        pool.window_len = saved[2];
                        pool.complex = saved[3];
                    }
                    const source = view.query.slice();
                    const first_node = pool.len;
                    const first_query = pool.query_len;
                    _ = P.parseQueryAt(source, 0, source.len, pool) catch return 0;
                    const blocks = pool.queries[first_query..pool.query_len];
                    var count: usize = 0;
                    for (blocks) |*q| for (q.items[0..q.item_count]) |*item| {
                        const table = self.itemRelation(source, blocks, item) orelse continue;
                        var known = false;
                        for (direct[0..count]) |oid| known = known or oid == table.oid;
                        if (known or count == direct.len) continue;
                        direct[count] = table.oid;
                        count += 1;
                    };
                    // `SELECT *` (a star target without a node) reads every
                    // column of its block's items.
                    for (blocks) |*q| for (q.targets[0..q.count]) |target| {
                        if (!target.star or target.expr != ast.none) continue;
                        for (q.items[0..q.item_count]) |*item| {
                            const table = self.itemRelation(source, blocks, item) orelse continue;
                            markAll(direct[0..count], used, table);
                        }
                    };
                    for (pool.nodes[first_node..pool.len]) |*node| {
                        if (node.kind != .column) continue;
                        var name_buffer: [256]u8 = undefined;
                        var qualifier_buffer: [256]u8 = undefined;
                        const name = identifier(source, node.name, &name_buffer);
                        const qualifier: []const u8 = if (node.qualifier.len == 0) "" else identifier(source, node.qualifier, &qualifier_buffer);
                        for (blocks) |*q| for (q.items[0..q.item_count]) |*item| {
                            const table = self.itemRelation(source, blocks, item) orelse continue;
                            if (qualifier.len != 0) {
                                var alias_buffer: [256]u8 = undefined;
                                const label = if (item.alias) |alias| identifier(source, alias, &alias_buffer) else identifier(source, item.name, &alias_buffer);
                                if (!types.same(label, qualifier)) continue;
                            }
                            if (node.star) {
                                if (qualifier.len != 0) markAll(direct[0..count], used, table);
                                continue;
                            }
                            for (table.columns[0..table.column_count], 0..) |*column, index| {
                                if (!types.same(column.name.slice(), name)) continue;
                                for (direct[0..count], 0..) |oid, position| {
                                    if (oid == table.oid) used[position] |= @as(u256, 1) << @intCast(index);
                                }
                            }
                        };
                    }
                    return count;
                }

                fn markAll(direct: []const u32, used: *[config.tables]u256, table: *const S.Table) void {
                    for (direct, 0..) |oid, position| {
                        if (oid == table.oid) used[position] = (@as(u256, 1) << @intCast(table.column_count)) -% 1;
                    }
                }

                /// The relation a FROM item names (not a subquery, function
                /// or CTE reference).
                fn itemRelation(self: *const Self, source: []const u8, blocks: []const A.Select, item: *const A.FromItem) ?*const S.Table {
                    if (item.query != ast.none or item.function != ast.none or item.name.len == 0) return null;
                    var name_buffer: [256]u8 = undefined;
                    const name = identifier(source, item.name, &name_buffer);
                    if (item.schema == null) {
                        for (blocks) |*block| for (block.ctes[0..block.cte_count]) |*cte| {
                            var cte_buffer: [256]u8 = undefined;
                            if (types.same(identifier(source, cte.name, &cte_buffer), name)) return null;
                        };
                    }
                    var schema_buffer: [256]u8 = undefined;
                    const schema: ?[]const u8 = if (item.schema) |qualifier| identifier(source, qualifier, &schema_buffer) else null;
                    return self.findRelation(schema, name);
                }

                // ---- type usage ---------------------------------------------

                fn columnUdtUsage(self: *Self) Error!void {
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        switch (table.relkind) {
                            'r', 'p', 'v', 'f' => {},
                            else => continue,
                        }
                        // Built-in types are owned by the bootstrap role.
                        if (!self.hasRole(CO.bootstrap_role)) continue;
                        const schema = self.namespaceName(table.namespace);
                        for (table.columns[0..table.column_count]) |*column| {
                            const data_type = if (column.data_type == .mysql_bigint_unsigned) .numeric else column.data_type;
                            try self.add(&.{ try self.catalogName(), try static("pg_catalog"), try static(udtName(data_type)),
                                try self.catalogName(), try self.text(schema), try self.text(table.name.slice()), try self.text(column.name.slice()) });
                        }
                    }
                }

                /// Columns typed by a domain the role owns: information_schema's
                /// own relations (their domains belong to the bootstrap
                /// role). Table columns cannot have a domain type yet.
                fn columnDomainUsage(self: *Self) Error!void {
                    if (!self.hasRole(CO.bootstrap_role)) return;
                    for (0..IS.relation_count) |index| {
                        const view = IS.viewAt(index);
                        for (catalog.viewColumns(view)) |column| {
                            const domain = column.domain orelse continue;
                            try self.add(&.{ try self.catalogName(), try static("information_schema"), try static(IS.domainName(domain)),
                                try self.catalogName(), try static("information_schema"), try static(@tagName(view)), try static(column.name) });
                        }
                    }
                }

                fn columnColumnUsage(self: *Self) Error!void {
                    const DbType = @typeInfo(Db).pointer.child;
                    _ = DbType;
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        if (!self.hasRole(self.tableOwner(table))) continue;
                        const schema = self.namespaceName(table.namespace);
                        for (table.columns[0..table.column_count], 0..) |*column, index| {
                            if (column.default_kind != .generated) continue;
                            const used = self.expressionColumns(table, column.expression.slice());
                            for (table.columns[0..table.column_count], 0..) |*source_column, source_index| {
                                if (source_index == index or used & (@as(u256, 1) << @intCast(source_index)) == 0) continue;
                                try self.add(&.{ try self.catalogName(), try self.text(schema), try self.text(table.name.slice()),
                                    try self.text(source_column.name.slice()), try self.text(column.name.slice()) });
                            }
                        }
                    }
                }

                /// element_types: the array-typed columns, attributes,
                /// domains and routine parameters / results.
                fn elementTypes(self: *Self) Error!void {
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        switch (table.relkind) {
                            'r', 'p', 'v', 'f' => {},
                            else => continue,
                        }
                        if (!self.seesColumns(table)) continue;
                        const schema = self.namespaceName(table.namespace);
                        for (table.columns[0..table.column_count], 1..) |*column, position| {
                            if (!self.seesColumn(table, position - 1)) continue;
                            const element = types.elementData(column.data_type) orelse continue;
                            try self.elementRow(schema, table.name.slice(), "TABLE", position, element);
                        }
                    }
                    for (&self.objects().items) |*o| {
                        if (o.kind != .composite_type or !O.visible(o, self.snap)) continue;
                        if (!self.hasRole(o.owner) and !self.typeUsage(o)) continue;
                        var fields = o.compositeFields();
                        var position: usize = 1;
                        while (fields.next()) |field| : (position += 1) {
                            const data_type = types.typeFromOid(field.oid) orelse continue;
                            const element = types.elementData(data_type) orelse continue;
                            try self.elementRow(self.namespaceName(o.target), o.name.slice(), "USER-DEFINED TYPE", position, element);
                        }
                    }
                    for (0..routine_slots) |index| {
                        const routine = self.routineShape(index) orelse continue;
                        if (!self.seesRoutine(&routine)) continue;
                        var buffer: [@as(usize, config.routine_args) * 2 + 2]Parameter = undefined;
                        const list = self.routineParameters(index, &routine, &buffer);
                        var name_buffer: [max_identifier + 1]u8 = undefined;
                        const specific = specificText(routine.name, routine.oid, &name_buffer);
                        const schema = self.namespaceName(routine.namespace);
                        for (list, 1..) |parameter, position| {
                            const data_type = types.typeFromOid(parameter.oid) orelse continue;
                            const element = types.elementData(data_type) orelse continue;
                            try self.elementRow(schema, specific, "ROUTINE", position, element);
                        }
                        if (routine.kind != 'p') {
                            const data_type = types.typeFromOid(routine.result) orelse continue;
                            const element = types.elementData(data_type) orelse continue;
                            try self.elementRow(schema, specific, "ROUTINE", 0, element);
                        }
                    }
                }

                fn specificText(name: []const u8, oid: u32, out: *[max_identifier + 1]u8) []const u8 {
                    var digits: [16]u8 = undefined;
                    const suffix = std.fmt.bufPrint(&digits, "_{d}", .{oid}) catch unreachable;
                    const keep = @min(name.len, max_identifier - suffix.len);
                    @memcpy(out[0..keep], name[0..keep]);
                    @memcpy(out[keep..][0..suffix.len], suffix);
                    return out[0 .. keep + suffix.len];
                }

                fn elementRow(self: *Self, schema: []const u8, name: []const u8, kind: []const u8, position: usize, element: DataType) Error!void {
                    var cells: [28]Cell = @splat(.null_value);
                    cells[0] = try self.catalogName();
                    cells[1] = try self.text(schema);
                    cells[2] = try self.text(name);
                    cells[3] = try static(kind);
                    cells[4] = try self.number(@intCast(position));
                    cells[5] = try static(dataTypeName(element));
                    const collation_name = collationName(element, null);
                    if (collation_name) |collation_text| {
                        cells[11] = try self.catalogName();
                        cells[12] = try static("pg_catalog");
                        cells[13] = try self.text(collation_text);
                    }
                    cells[20] = try self.catalogName();
                    cells[21] = try static("pg_catalog");
                    cells[22] = try static(udtName(element));
                    var dtd: [24]u8 = undefined;
                    cells[27] = try self.text(std.fmt.bufPrint(&dtd, "a{d}", .{position}) catch unreachable);
                    try self.add(&cells);
                }

                /// The union of the dtd_identifier sources: attributes,
                /// columns, domains, parameters and routines.
                fn dataTypePrivileges(self: *Self) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .composite_type or !O.visible(o, self.snap)) continue;
                        if (!self.hasRole(o.owner) and !self.typeUsage(o)) continue;
                        var fields = o.compositeFields();
                        var position: usize = 1;
                        while (fields.next()) |_| : (position += 1) {
                            try self.dtdRow(self.namespaceName(o.target), o.name.slice(), "USER-DEFINED TYPE", position);
                        }
                    }
                    for (0..system_view_slots) |index| {
                        const view = self.systemView(index) orelse continue;
                        if (!self.seesSystemRelation(view)) continue;
                        for (1..catalog.viewColumns(view).len + 1) |position| try self.dtdRow(systemNamespace(view), @tagName(view), "TABLE", position);
                    }
                    for (self.relations) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.db.tables[found.slot];
                        switch (table.relkind) {
                            'r', 'p', 'v', 'f' => {},
                            else => continue,
                        }
                        if (!self.seesColumns(table)) continue;
                        for (1..table.column_count + 1) |position| {
                            if (!self.seesColumn(table, position - 1)) continue;
                            try self.dtdRow(self.namespaceName(table.namespace), table.name.slice(), "TABLE", position);
                        }
                    }
                    for (is_domains) |domain| try self.dtdRow("information_schema", IS.domainName(domain), "DOMAIN", 1);
                    for (&self.objects().items) |*o| {
                        if (o.kind != .domain or !O.visible(o, self.snap)) continue;
                        if (!self.hasRole(o.owner) and !self.typeUsage(o)) continue;
                        try self.dtdRow(self.namespaceName(o.target), o.name.slice(), "DOMAIN", 1);
                    }
                    for (0..routine_slots) |index| {
                        const routine = self.routineShape(index) orelse continue;
                        if (!self.seesRoutine(&routine)) continue;
                        var buffer: [@as(usize, config.routine_args) * 2 + 2]Parameter = undefined;
                        const list = self.routineParameters(index, &routine, &buffer);
                        var name_buffer: [max_identifier + 1]u8 = undefined;
                        const specific = specificText(routine.name, routine.oid, &name_buffer);
                        for (1..list.len + 1) |position| try self.dtdRow(self.namespaceName(routine.namespace), specific, "ROUTINE", position);
                    }
                    for (0..routine_slots) |index| {
                        const routine = self.routineShape(index) orelse continue;
                        if (!self.seesRoutine(&routine)) continue;
                        var name_buffer: [max_identifier + 1]u8 = undefined;
                        const specific = specificText(routine.name, routine.oid, &name_buffer);
                        try self.add(&.{ try self.catalogName(), try self.text(self.namespaceName(routine.namespace)), try self.text(specific),
                            try static("ROUTINE"), if (routine.kind == 'p') .null_value else try static("0") });
                    }
                }

                fn dtdRow(self: *Self, schema: []const u8, name: []const u8, kind: []const u8, position: usize) Error!void {
                    try self.add(&.{ try self.catalogName(), try self.text(schema), try self.text(name), try static(kind), try self.number(@intCast(position)) });
                }

                // ---- collations and foreign data ----------------------------

                fn collations(self: *Self, view: View) Error!void {
                    for (collation.oids, collation.names) |oid, name| {
                        // ucs_basic is UTF8-only; the database is UTF8.
                        _ = oid;
                        if (view == .collations) {
                            try self.add(&.{ try self.catalogName(), try static("pg_catalog"), try static(name), try static("NO PAD") });
                        } else {
                            try self.add(&.{ try self.catalogName(), try static("pg_catalog"), try static(name), .null_value, .null_value, try static("UTF8") });
                        }
                    }
                }

                /// The owner, or anyone with USAGE (wrapper and server ACLs
                /// are owner-only here).
                fn foreignDataWrappers(self: *Self) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .fdw or !O.visible(o, self.snap) or !self.hasRole(o.owner)) continue;
                        try self.add(&.{ try self.catalogName(), try self.text(o.name.slice()), try self.text(self.roleName(o.owner)), .null_value, try static("c") });
                    }
                }

                /// _pg_foreign_data_wrappers: wrappers whose owner the role
                /// has (wrapper ACLs are owner-only); no options.
                fn helperWrappers(self: *Self) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .fdw or !O.visible(o, self.snap) or !self.hasRole(o.owner)) continue;
                        try self.add(&.{ int(o.oid), int(o.owner), .null_value, try self.catalogName(), try self.text(o.name.slice()),
                            try self.text(self.roleName(o.owner)), try static("c") });
                    }
                }

                fn helperServers(self: *Self) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .server or !O.visible(o, self.snap) or !self.hasRole(o.owner)) continue;
                        var wrapper: []const u8 = "";
                        for (&self.objects().items) |*w| {
                            if (w.kind == .fdw and w.oid == o.target and O.visible(w, self.snap)) wrapper = w.name.slice();
                        }
                        try self.add(&.{
                            int(o.oid), .null_value, try self.catalogName(), try self.text(o.name.slice()), try self.catalogName(), try self.text(wrapper),
                            if (o.flags & CO.server_type != 0) try self.text(o.usingText()) else .null_value,
                            if (o.flags & CO.server_version != 0) try self.text(o.checkText()) else .null_value,
                            try self.text(self.roleName(o.owner)),
                        });
                    }
                }

                fn foreignServers(self: *Self) Error!void {
                    for (&self.objects().items) |*o| {
                        if (o.kind != .server or !O.visible(o, self.snap) or !self.hasRole(o.owner)) continue;
                        var wrapper: []const u8 = "";
                        for (&self.objects().items) |*w| {
                            if (w.kind == .fdw and w.oid == o.target and O.visible(w, self.snap)) wrapper = w.name.slice();
                        }
                        try self.add(&.{
                            try self.catalogName(), try self.text(o.name.slice()), try self.catalogName(), try self.text(wrapper),
                            if (o.flags & CO.server_type != 0) try self.text(o.usingText()) else .null_value,
                            if (o.flags & CO.server_version != 0) try self.text(o.checkText()) else .null_value,
                            try self.text(self.roleName(o.owner)),
                        });
                    }
                }
            };
        }
    };
}
