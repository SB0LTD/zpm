//! Catalog objects (conformance lane B11, wave 3): roles and role
//! membership, table privileges, row-level security, object comments,
//! foreign-data wrappers, foreign servers, publications and the built-in
//! extension row.
//!
//! Every object is one MVCC version in a fixed store (Config.catalog_objects
//! entries, 54000 TableCapacity beyond): created by a transaction (xmin),
//! deleted by one (xmax), visible under the same snapshot rules as table rows
//! (storage.sig), so the statements below are transactional. A change (ALTER
//! ROLE, GRANT on an existing grantee, COMMENT over a comment) deletes the
//! old version and creates a new one. Text payloads (comment text, policy
//! USING / WITH CHECK) live inline (Config.object_text_bytes, TextCapacity
//! beyond); policies name at most Config.policy_roles roles.
//!
//! Durability: change-record op 70 object_create carries a whole version and
//! op 71 object_drop the key of the version it deletes (layout below). The
//! table definition format is unchanged: owners, RLS flags and grants of a
//! table are `relation` / `acl` objects keyed by the table OID, and a DROP
//! TABLE drops them in the same record.
//!
//! Enums support catalog CREATE/DROP, pg_type and pg_enum, and standalone
//! literal casts with nominal result metadata. A type, its generated array
//! and all ordered labels have one MVCC lifetime and contiguous OID range.
//! ALTER TYPE, general enum expressions and enum storage require separate
//! type-system support. Composite CREATE/DROP publishes a catalog relation
//! and typed attributes. A standalone flat ROW literal can be cast to a
//! composite with supported built-in field types.
//! Field descriptors and enum labels share Config.object_text_bytes with
//! the generated array name, in their respective object kind. Composite
//! storage, nested expressions and typed tables require further support.
//!
//!   70 object_create kind u8, oid u32, target u32, grantee u32, sub i32,
//!                    owner u32, flags u32, grant_flags u32, name (len u8 +
//!                    bytes, may be empty), role_count u8 + role OIDs u32,
//!                    text_len u16 + bytes, split u16 (<= text_len)
//!                    domain only: version u8, base u8, not_null u8,
//!                    comparison u8, signed CHECK bound i64
//!                    enum only: version u8, label_count u16
//!                    (text is array name then length-prefixed labels)
//!                    composite only: version u8, field_count u16
//!                    (text is array name then fields: name len u8 + bytes,
//!                    built-in type OID u32, typmod i32)
//!   71 object_drop   kind u8, oid u32, target u32, grantee u32, sub i32
//!
//! Kinds and keys: 1 role (oid), 2 member (target role, grantee member),
//! 3 acl (target table, grantee role or 0 PUBLIC), 4 relation (target
//! table), 5 policy (oid), 6 comment (grantee classoid, target object, sub
//! column), 7 fdw (oid), 8 server (oid), 9 publication (oid), 10 domain
//! (oid, namespace), 11 enum (oid, namespace), 12 composite (oid, namespace).
//! Types append a versioned payload.
//!
//! Roles are SQL-level: the bootstrap superuser (OID 10, `ramsql`) is the
//! role every wire session runs as (RAMSQL authenticates one SCRAM user and
//! maps it to this role). CREATE ROLE makes roles that own nothing at first,
//! carry privileges and policies and can be entered with SET ROLE; they have
//! no passwords and can never authenticate on the wire.
const types = @import("types.sig");
const storage = @import("storage.sig");
const lexer = @import("lexer.sig");
const role_defaults = @import("role_defaults.sig");
const Error = types.Error;

pub const bootstrap_role: u32 = 10;
pub const bootstrap_name = "ramsql";
/// The PUBLIC pseudo-role in grants and policy role lists.
pub const public_role: u32 = 0;
pub const first_oid: u32 = 16384;

/// pg_description.classoid values (catalog relation OIDs).
pub const class_relation: u32 = 1259;
pub const class_namespace: u32 = 2615;
pub const class_authid: u32 = 1260;
pub const class_fdw: u32 = 2328;
pub const class_server: u32 = 1417;
pub const class_publication: u32 = 6104;
pub const class_policy: u32 = 3256;
pub const class_large_object: u32 = 2613;
pub const large_object_privileges = priv_select | priv_update;
/// The owner has implicit SELECT and UPDATE until an ACL is materialized.
pub const large_object_explicit_acl: u32 = 1 << 31;
/// Stored in grant_flags for an automatically generated large-object OID.
pub const large_object_generated_oid: u32 = 1;
pub const priv_execute: u32 = 1 << 7;

/// Built-in routines whose default ACL excludes PUBLIC.
pub fn restrictedRoutine(oid: u32) bool {
    return oid == 764 or oid == 765 or oid == 767;
}

/// The plpgsql row of pg_extension (installed in every PostgreSQL
/// database). PostgreSQL assigns its OID at initdb; ZPM fixes it.
pub const plpgsql_extension_oid: u32 = 13001;

pub const Kind = enum(u8) { role = 1, member = 2, acl = 3, relation = 4, policy = 5, comment = 6, fdw = 7, server = 8, publication = 9, domain = 10, enum_type = 11, composite_type = 12, statistics = 13, publication_table = 14, publication_schema = 15, schema_acl = 16, schema_acl_state = 17, schema_owner = 18, role_settings = 19, large_object = 20, large_object_acl = 21, large_object_default_acl = 22, builtin_routine_acl = 23, routine_default_acl = 24,
    // Privileges lane (B11 wave 5): kinds 100-104 match the lane's reserved
    // change-log range so concurrent lanes never collide on a kind number.
    /// Column grants of one (table, grantee, grantor): text byte c holds
    /// column c's privileges (low nibble) and grant options (high nibble).
    column_acl = 100,
    /// USAGE grants on a domain, enum or composite type.
    type_acl = 101,
    /// USAGE / SELECT / UPDATE grants on a sequence.
    sequence_acl = 102,
    _ };

/// Lowest and highest kind numbers of the privileges lane.
pub const first_lane_kind: u8 = @intFromEnum(Kind.column_acl);
pub const last_lane_kind: u8 = @intFromEnum(Kind.sequence_acl);

/// Grant rows (acl, schema_acl, column_acl, type_acl, sequence_acl): `sub`
/// is 0 for a grant issued by the object owner (`owner` holds the owner) and
/// the grantor's OID for a delegated grant (`owner` holds the grantor too).
pub fn grantRow(kind: Kind) bool {
    return kind == .acl or kind == .schema_acl or kind == .column_acl or kind == .type_acl or kind == .sequence_acl;
}

/// Marks the owner's own row (grantee = grantor = owner, sub 0) of a grant
/// kind: `flags` then holds the owner's explicit privileges, which replace
/// the kind's default. Its presence also materializes the ACL (relacl /
/// typacl stop being NULL), as PostgreSQL's first GRANT / REVOKE does.
pub const acl_explicit_owner: u32 = 1 << 31;

/// The grantor key of a grant row.
pub fn grantorKey(object_owner: u32, grantor: u32) i32 {
    return if (object_owner == grantor) 0 else @bitCast(grantor);
}

/// Column privilege nibble <-> AclMode bits (INSERT, SELECT, UPDATE,
/// REFERENCES; PostgreSQL's ACL_ALL_RIGHTS_COLUMN).
pub fn columnNibble(flags: u32) u8 {
    var out: u8 = 0;
    if (flags & priv_insert != 0) out |= 1;
    if (flags & priv_select != 0) out |= 2;
    if (flags & priv_update != 0) out |= 4;
    if (flags & priv_references != 0) out |= 8;
    return out;
}

pub fn columnFlags(nibble: u8) u32 {
    var out: u32 = 0;
    if (nibble & 1 != 0) out |= priv_insert;
    if (nibble & 2 != 0) out |= priv_select;
    if (nibble & 4 != 0) out |= priv_update;
    if (nibble & 8 != 0) out |= priv_references;
    return out;
}

/// PostgreSQL's predefined roles (initdb OIDs, pg_authid.dat): they exist
/// in every database, cannot log in and hold the documented effects
/// (pg_read_all_data, pg_write_all_data, pg_maintain, pg_database_owner).
pub const predefined_oids = [_]u32{ 3373, 3374, 3375, 3377, 4200, 4544, 4550, 4569, 4570, 4571, 6171, 6181, 6182, 6304, 6337, 6392 };
pub const predefined_names = [_][]const u8{ "pg_monitor", "pg_read_all_settings", "pg_read_all_stats", "pg_stat_scan_tables", "pg_signal_backend", "pg_checkpoint", "pg_use_reserved_connections", "pg_read_server_files", "pg_write_server_files", "pg_execute_server_program", "pg_database_owner", "pg_read_all_data", "pg_write_all_data", "pg_create_subscription", "pg_maintain", "pg_signal_autovacuum_worker" };
pub const role_pg_monitor: u32 = 3373;
pub const role_pg_database_owner: u32 = 6171;
pub const role_pg_read_all_data: u32 = 6181;
pub const role_pg_write_all_data: u32 = 6182;
pub const role_pg_maintain: u32 = 6337;
/// pg_monitor is a member of these three (bootstrap grants, pg_auth_members
/// OIDs 10308-10310).
pub const monitor_members = [_]u32{ 3374, 3375, 3377 };
pub const monitor_member_oids = [_]u32{ 10308, 10309, 10310 };
/// The built-in public schema.
pub const public_namespace: u32 = 2200;

pub fn predefinedRole(oid: u32) bool {
    for (predefined_oids) |known| if (known == oid) return true;
    return false;
}

pub fn predefinedName(oid: u32) ?[]const u8 {
    for (predefined_oids, predefined_names) |known, name| if (known == oid) return name;
    return null;
}

pub fn predefinedByName(name: []const u8) ?u32 {
    for (predefined_oids, predefined_names) |known, spelled| if (types.same(spelled, name)) return known;
    return null;
}

/// PUBLIC's routine default is stored with the owner marker, not as a role row.
pub const routine_default_public: u32 = 1 << 31;

pub fn defaultAcl(kind: Kind) bool {
    return kind == .large_object_default_acl or kind == .routine_default_acl;
}

pub fn defaultAclFlags(kind: Kind, namespace: u32) u32 {
    return if (kind == .routine_default_acl) (if (namespace == 0) priv_execute | routine_default_public else 0) else large_object_privileges;
}

pub fn publicationMembership(kind: Kind) bool {
    return kind == .publication_table or kind == .publication_schema;
}

pub fn publicationRelationKind(kind: u8) bool {
    return kind == 'r' or kind == 'p';
}

pub fn userType(kind: Kind) bool {
    return kind == .domain or kind == .enum_type or kind == .composite_type;
}

pub const enum_label_bytes: usize = 63;

pub const EnumLabels = struct {
    bytes: []const u8,

    /// Iterates a catalog payload that has already passed validation.
    pub fn next(self: *EnumLabels) ?[]const u8 {
        if (self.bytes.len == 0) return null;
        const len: usize = self.bytes[0];
        const label = self.bytes[1..][0..len];
        self.bytes = self.bytes[len + 1 ..];
        return label;
    }
};

pub const EncodedEnumLabels = struct { bytes: usize, count: u16 };

pub const CompositeField = struct { name: []const u8, oid: u32, typmod: i32 };

const composite_field_header = 1 + @sizeOf(u32) + @sizeOf(i32);

fn fieldWord(raw: []const u8) u32 {
    var value: u32 = 0;
    for (raw[0..4], 0..) |byte, index| value |= @as(u32, byte) << @intCast(index * 8);
    return value;
}

pub const CompositeFields = struct {
    bytes: []const u8,

    pub fn next(self: *CompositeFields) ?CompositeField {
        if (self.bytes.len == 0) return null;
        const name_len: usize = self.bytes[0];
        const payload = self.bytes[1 + name_len ..];
        const field: CompositeField = .{
            .name = self.bytes[1..][0..name_len],
            .oid = fieldWord(payload),
            .typmod = @bitCast(fieldWord(payload[4..])),
        };
        self.bytes = payload[8..];
        return field;
    }
};

/// Appends one already-bound built-in attribute. WAL validates the same
/// sequence independently before publishing the enclosing catalog object.
pub fn appendCompositeField(output: []u8, used: *usize, field: CompositeField) Error!void {
    const name_len = field.name.len;
    if (name_len == 0 or name_len > 255) return error.InvalidName;
    for (field.name) |byte| if (byte == 0) return error.InvalidName;
    var earlier: CompositeFields = .{ .bytes = output[0..used.*] };
    while (earlier.next()) |prior| if (types.same(prior.name, field.name)) return error.DuplicateColumn;
    const length = name_len + composite_field_header;
    if (length > output.len - used.*) return error.TextCapacity;
    const encoded = output[used.*..][0..length];
    encoded[0] = @intCast(name_len);
    @memcpy(encoded[1..][0..name_len], field.name);
    for ([_]u32{ field.oid, @bitCast(field.typmod) }, 0..) |word, index| {
        for (0..4) |byte| encoded[1 + name_len + index * 4 + byte] = @truncate(word >> @intCast(byte * 8));
    }
    used.* += length;
}

/// Freeze exact decoded label bytes into one caller-owned catalog payload.
pub fn encodeEnumLabels(source: []const u8, output: []u8, label_capacity: usize) Error!EncodedEnumLabels {
    var p: Parser = .{ .tokens = .{ .source = source, .text_limit = source.len }, .source = source, .name_bytes = label_capacity };
    try p.advance();
    var encoded: EncodedEnumLabels = .{ .bytes = 0, .count = 0 };
    if (p.current.kind == .end) return encoded;
    while (true) {
        if (encoded.count == 0xffff) return error.ProgramLimitExceeded;
        const quoted = try p.string();
        if (quoted.len > enum_label_bytes) return error.InvalidName;
        if (quoted.len > label_capacity) return error.NameCapacity;
        if (quoted.len + 1 > output.len - encoded.bytes) return error.TextCapacity;
        const label = output[encoded.bytes + 1 ..][0..quoted.len];
        lexer.decodeQuoted(source, quoted, label);
        for (label) |byte| if (byte == 0) return error.InvalidName;
        var earlier: EnumLabels = .{ .bytes = output[0..encoded.bytes] };
        while (earlier.next()) |prior| if (types.same(prior, label)) return error.PrimaryKeyViolation;
        output[encoded.bytes] = @intCast(label.len);
        encoded.bytes += label.len + 1;
        encoded.count += 1;
        if (!try p.takeSymbol(.comma)) break;
    }
    if (p.current.kind != .end) return error.Syntax;
    return encoded;
}

pub const DomainComparison = enum(u8) {
    none = 0, eq = 1, ne = 2, lt = 3, le = 4, gt = 5, ge = 6,

    fn reverse(self: DomainComparison) DomainComparison {
        return switch (self) { .lt => .gt, .le => .ge, .gt => .lt, .ge => .le, else => self };
    }

    pub fn accepts(self: DomainComparison, value: i64, bound: i64) bool {
        return switch (self) {
            .none => true, .eq => value == bound, .ne => value != bound,
            .lt => value < bound, .le => value <= bound, .gt => value > bound, .ge => value >= bound,
        };
    }
};

pub const Domain = struct {
    base: types.Type = .unknown,
    not_null: bool = false,
    comparison: DomainComparison = .none,
    bound: i64 = 0,
};

pub fn domainBase(base: types.Type) bool {
    return base == .int2 or base == .int4 or base == .int8;
}

/// Role attributes (pg_authid booleans).
pub const role_superuser: u32 = 1;
pub const role_inherit: u32 = 2;
pub const role_createrole: u32 = 4;
pub const role_createdb: u32 = 8;
pub const role_login: u32 = 16;
pub const role_replication: u32 = 32;
pub const role_bypassrls: u32 = 64;
pub const role_attributes: u32 = 127;

// Memberships written before per-edge options used flags = 0.
pub const member_configured: u32 = 1;
pub const member_inherit: u32 = 2;
pub const member_set: u32 = 4;
pub const member_admin: u32 = 1;
pub const MembershipPath = enum { any, inherit, set };

pub fn membershipFlags(inherit: bool, set: bool) u32 {
    return member_configured | (if (inherit) member_inherit else 0) | (if (set) member_set else 0);
}

/// Table privileges as PostgreSQL's AclMode bits (aclitem letters arwdDxtm).
pub const priv_insert: u32 = 1 << 0;
pub const priv_select: u32 = 1 << 1;
pub const priv_update: u32 = 1 << 2;
pub const priv_delete: u32 = 1 << 3;
pub const priv_truncate: u32 = 1 << 4;
pub const priv_references: u32 = 1 << 5;
pub const priv_trigger: u32 = 1 << 6;
pub const priv_schema_usage: u32 = 1 << 8;
pub const priv_schema_create: u32 = 1 << 9;
pub const priv_maintain: u32 = 1 << 14;
pub const priv_temporary: u32 = 1 << 10;
pub const priv_connect: u32 = 1 << 11;
pub const table_privileges: u32 = priv_insert | priv_select | priv_update | priv_delete | priv_truncate | priv_references | priv_trigger | priv_maintain;
/// ACL_USAGE (sequences, schemas, types) and the per-kind privilege sets.
pub const priv_usage: u32 = priv_schema_usage;
pub const priv_create: u32 = priv_schema_create;
pub const column_privileges: u32 = priv_insert | priv_select | priv_update | priv_references;
pub const sequence_privileges: u32 = priv_usage | priv_select | priv_update;
pub const schema_privileges: u32 = priv_usage | priv_create;
pub const type_privileges: u32 = priv_usage;

/// The privilege set of a grant kind.
pub fn kindPrivileges(kind: Kind) u32 {
    return switch (kind) {
        .acl => table_privileges,
        .column_acl => column_privileges,
        .sequence_acl => sequence_privileges,
        .schema_acl => schema_privileges,
        .type_acl => type_privileges,
        else => 0,
    };
}

/// aclitem letters in PostgreSQL's ACL_ALL_RIGHTS_STR order (acl.h):
/// a r w d D x t X U C T c s A m.
pub const acl_letter_bits = [_]u32{ priv_insert, priv_select, priv_update, priv_delete, priv_truncate, priv_references, priv_trigger, priv_execute, priv_usage, priv_create, priv_maintain };
pub const acl_letters = "arwdDxtXUCm";

/// Writes the aclitem privilege letters of `flags` with `*` after each
/// privilege whose grant option `options` holds.
pub fn aclLetters(flags: u32, options: u32, out: *[2 * acl_letters.len]u8) []const u8 {
    var used: usize = 0;
    for (acl_letter_bits, acl_letters) |bit, letter| {
        if (flags & bit == 0) continue;
        out[used] = letter;
        used += 1;
        if (options & bit != 0) {
            out[used] = '*';
            used += 1;
        }
    }
    return out[0..used];
}

/// The table privileges in aclexplode order: bits, keywords and the
/// information_schema spelling (parallel arrays: no slice-holding structs).
pub const privilege_bits = [_]u32{ priv_insert, priv_select, priv_update, priv_delete, priv_truncate, priv_references, priv_trigger, priv_maintain };
pub const privilege_words = [_][]const u8{ "insert", "select", "update", "delete", "truncate", "references", "trigger", "maintain" };
pub const privilege_sql = [_][]const u8{ "INSERT", "SELECT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN" };

/// relation flags (pg_class.relrowsecurity / relforcerowsecurity).
pub const rls_enabled: u32 = 1;
pub const rls_forced: u32 = 2;

/// Policy flags: the command in the low byte, permissive bit, and which of
/// the two expressions are present (text[0..split] USING, the rest CHECK).
pub const Command = enum(u8) { all = 0, select = 1, insert = 2, update = 3, delete = 4 };
pub const policy_permissive: u32 = 0x100;
pub const policy_using: u32 = 0x200;
pub const policy_check: u32 = 0x400;

/// Server flags: srvtype / srvversion present (text[0..split] / the rest).
pub const server_type: u32 = 1;
pub const server_version: u32 = 2;

/// Publication flags (pg_publication booleans).
pub const pub_all_tables: u32 = 1;
pub const pub_insert: u32 = 2;
pub const pub_update: u32 = 4;
pub const pub_delete: u32 = 8;
pub const pub_truncate: u32 = 16;
pub const pub_via_root: u32 = 32;
pub const pub_default: u32 = pub_insert | pub_update | pub_delete | pub_truncate;

/// Names in one GRANT / REVOKE / DROP list (54000 ProgramLimitExceeded beyond).
pub const list_capacity: usize = 8;

// ---- statements ---------------------------------------------------------------

/// Same layout as ast.Ident: a span into the statement source; quoted names
/// keep their case, others fold.
pub const Span = struct { start: usize = 0, len: usize = 0 };
pub const Ident = struct { span: Span = .{}, quoted: bool = false, len: usize = 0 };
pub const Qualified = struct { has_schema: bool = false, schema: Ident = .{}, name: Ident = .{} };

pub const RoleKind = enum { role, user, group };
pub const RoleBoolean = role_defaults.Boolean;
pub const role_boolean_mask = role_defaults.mask;

pub const RoleDefaults = union(enum) {
    reset_all,
    reset: RoleBoolean,
    from_current: RoleBoolean,
    set: struct { setting: RoleBoolean, spelling: Span = .{}, quoted: ?lexer.Quoted = null },
};

pub const RoleSpec = struct {
    kind: RoleKind = .role,
    name: Ident = .{},
    set: u32 = 0,
    clear: u32 = 0,
    connlimit_set: bool = false,
    connlimit: i32 = -1,
    rename: bool = false,
    new_name: Ident = .{},
    /// CREATE ROLE ... IN ROLE a, b: the new role becomes a member of each.
    in_roles: [list_capacity]Ident = @splat(.{}),
    in_count: usize = 0,
    defaults: ?RoleDefaults = null,
};

pub const GranteeKind = enum(u8) { name, public, current_user, session_user, current_role };
pub const Grantee = struct { kind: GranteeKind = .name, name: Ident = .{} };

/// What a privilege GRANT / REVOKE names after ON (privileges lane).
pub const GrantObject = enum(u8) { table, sequence, schema, domain, type_name, all_tables, all_sequences };

/// `GRANT SELECT (a, b), UPDATE (c)`: one entry per (privilege, column).
pub const ColumnGrant = struct { privileges: u32 = 0, column: Ident = .{} };
/// (privilege, column) pairs in one GRANT / REVOKE (54000 beyond).
pub const column_grant_capacity: usize = 2 * list_capacity;

pub const Grant = struct {
    /// GRANT role TO role (membership) instead of table privileges.
    membership: bool = false,
    schema: bool = false,
    object: GrantObject = .table,
    /// Column privileges; `privileges` holds only the table-wide ones.
    columns: [column_grant_capacity]ColumnGrant = @splat(.{}),
    column_count: usize = 0,
    /// The privilege words as written, for 0LP01 checks per object kind.
    written: u32 = 0,
    all_privileges: bool = false,
    privileges: u32 = 0,
    tables: [list_capacity]Qualified = @splat(.{}),
    table_count: usize = 0,
    large_objects: [list_capacity]u32 = @splat(0),
    large_object_count: usize = 0,
    routine_defaults: bool = false,
    granted: [list_capacity]Ident = @splat(.{}),
    granted_count: usize = 0,
    grantees: [list_capacity]Grantee = @splat(.{}),
    grantee_count: usize = 0,
    /// WITH GRANT / ADMIN OPTION; for REVOKE, GRANT / ADMIN OPTION FOR.
    option: bool = false,
    admin: ?bool = null,
    inherit: ?bool = null,
    set: ?bool = null,
    grantor: ?Grantee = null,
    cascade: bool = false,
    /// REVOKE INHERIT / SET OPTION FOR role (PostgreSQL 16+).
    revoke_option: RevokeOption = .none,
};

pub const RevokeOption = enum(u8) { none, inherit, set };

pub const Policy = struct {
    name: Ident = .{},
    table: Qualified = .{},
    if_exists: bool = false,
    permissive: bool = true,
    command: Command = .all,
    command_set: bool = false,
    roles: [list_capacity]Grantee = @splat(.{}),
    role_count: usize = 0,
    has_using: bool = false,
    using: Span = .{},
    has_check: bool = false,
    check: Span = .{},
    rename: bool = false,
    new_name: Ident = .{},
};

pub const SecurityAction = enum { enable, disable, force, no_force, owner };
pub const TableSecurity = struct {
    table: Qualified = .{},
    if_exists: bool = false,
    action: SecurityAction = .enable,
    owner: Grantee = .{},
};

pub const CommentTarget = enum { table, view, materialized_view, sequence, index, foreign_table, column, schema, role, policy, fdw, server, publication, extension, large_object };
pub const Comment = struct {
    large_object: u32 = 0,
    target: CommentTarget = .table,
    object: Qualified = .{},
    column: Ident = .{},
    /// COMMENT ON POLICY name ON table.
    on: Qualified = .{},
    /// IS NULL removes the comment.
    has_text: bool = false,
    text: lexer.Quoted = .{ .start = 0, .end = 0, .len = 0 },
};

pub const Named = struct { name: Ident = .{}, if_not_exists: bool = false };
pub const Drop = struct { names: [list_capacity]Ident = @splat(.{}), count: usize = 0, if_exists: bool = false, cascade: bool = false };

pub const Server = struct {
    name: Ident = .{},
    if_not_exists: bool = false,
    fdw: Ident = .{},
    has_type: bool = false,
    server_type: lexer.Quoted = .{ .start = 0, .end = 0, .len = 0 },
    has_version: bool = false,
    version: lexer.Quoted = .{ .start = 0, .end = 0, .len = 0 },
};

pub const Publication = struct {
    pub const Member = union(enum) {
        table: struct { name: Qualified, only: bool },
        schema: Ident,
    };

    name: Ident = .{},
    flags: u32 = pub_default,
    members: [list_capacity]Member = undefined,
    count: usize = 0,
};
pub const statistics_kinds = [_][]const u8{ "d", "f", "m" };
const all_statistics_kinds: u32 = (1 << statistics_kinds.len) - 1;
pub const statistics_columns = 8;
pub const Statistics = struct {
    name: Qualified,
    table: Qualified = .{},
    columns: [statistics_columns]Ident = @splat(.{}),
    count: usize = 0,
    flags: u32 = all_statistics_kinds,
    if_not_exists: bool,
};
pub const AlterStatistics = struct { name: Qualified, if_exists: bool, target: i32 };
pub const CreateDomain = struct { name: Qualified, spec: Domain };
pub const LargeObjectDefaults = struct {
    owners: [list_capacity]Grantee = @splat(.{}),
    count: usize = 0,
    schemas: [list_capacity]Ident = @splat(.{}),
    schema_count: usize = 0,
    revoke: bool = false,
    grant: Grant = .{},
};
pub const CreateEnum = struct { name: Qualified, labels: Span };
pub const CreateComposite = struct { name: Qualified, fields: Span };
pub const DropTypes = struct { names: [list_capacity]Qualified = @splat(.{}), count: usize = 0, if_exists: bool = false,
    /// DROP TYPE ... CASCADE (composite lane: dependents decide).
    cascade: bool = false };

pub const Statement = union(enum) {
    create_role: RoleSpec,
    alter_role: RoleSpec,
    drop_role: Drop,
    grant: Grant,
    revoke: Grant,
    create_policy: Policy,
    alter_policy: Policy,
    drop_policy: Policy,
    table_security: TableSecurity,
    alter_schema_owner: struct { name: Ident, owner: Grantee },
    alter_large_object_owner: struct { oid: u32, owner: Grantee },
    alter_large_object_defaults: LargeObjectDefaults,
    comment: Comment,
    create_fdw: Named,
    drop_fdw: Drop,
    create_server: Server,
    drop_server: Drop,
    create_publication: Publication,
    drop_publication: Drop,
    create_statistics: Statistics,
    alter_statistics: AlterStatistics,
    drop_statistics: DropTypes,
    create_extension: Named,
    create_domain: CreateDomain,
    drop_domain: DropTypes,
    create_enum: CreateEnum,
    create_composite: CreateComposite,
    drop_type: DropTypes,
};

// ---- parser -------------------------------------------------------------------

/// Parses one catalog-object statement; null when `source` is some other
/// statement (nothing is reported then: the main parser takes it).
/// Recognized but unsupported forms are 0A000; malformed ones 42601.
pub fn parse(source: []const u8, comptime name_bytes: usize, comptime text_bytes: usize) Error!?Statement {
    return parseWithDialect(source, name_bytes, text_bytes, .postgres);
}

pub fn parseWithDialect(source: []const u8, comptime name_bytes: usize, comptime text_bytes: usize, dialect: types.Dialect) Error!?Statement {
    var p: Parser = .{ .tokens = .{ .source = source, .text_limit = text_bytes, .dialect = dialect }, .source = source, .name_bytes = name_bytes };
    try p.advance();
    if (try p.take("create")) {
        if (try p.take("domain")) return .{ .create_domain = try p.createDomain() };
        if (try p.take("type")) {
            // Enum literals are checked against the PostgreSQL label limit
            // after decoding, independently of expression text capacity.
            p.tokens.text_limit = source.len;
            return try p.createType();
        }
        if (try p.take("role")) return .{ .create_role = try p.roleSpec(.role, true) };
        if (p.word("user")) {
            try p.advance();
            if (p.word("mapping")) return error.UnsupportedStatement;
            return .{ .create_role = try p.roleSpec(.user, true) };
        }
        if (try p.take("group")) return .{ .create_role = try p.roleSpec(.group, true) };
        if (try p.take("policy")) return .{ .create_policy = try p.policy(.create) };
        if (try p.take("foreign")) {
            if (try p.take("data")) {
                try p.expect("wrapper");
                return .{ .create_fdw = try p.fdw() };
            }
            if (p.word("table")) return error.UnsupportedStatement;
            return error.Syntax;
        }
        if (try p.take("server")) return .{ .create_server = try p.server() };
        if (try p.take("publication")) return .{ .create_publication = try p.publication() };
        if (dialect == .postgres and try p.take("statistics")) return .{ .create_statistics = try p.statistics() };
        if (p.word("subscription")) return error.UnsupportedStatement;
        if (try p.take("extension")) {
            var out: Named = .{ .if_not_exists = try p.ifNotExists() };
            out.name = try p.ident();
            if (!p.atEnd()) return error.UnsupportedStatement;
            return .{ .create_extension = out };
        }
        return null;
    }
    if (try p.take("alter")) {
        if (dialect == .postgres and try p.take("default")) {
            try p.expect("privileges");
            return .{ .alter_large_object_defaults = try p.largeObjectDefaults() };
        }
        if (dialect == .postgres and try p.take("large")) {
            try p.expect("object");
            const oid = try p.objectId();
            try p.expect("owner");
            try p.expect("to");
            const owner = try p.grantee();
            if (owner.kind == .public) return error.Syntax;
            try p.finish();
            return .{ .alter_large_object_owner = .{ .oid = oid, .owner = owner } };
        }
        if (dialect == .postgres and try p.take("schema")) {
            const name = try p.ident();
            if (!try p.take("owner")) return error.UnsupportedStatement;
            try p.expect("to");
            const owner = try p.grantee();
            if (owner.kind == .public or !p.atEnd()) return error.Syntax;
            return .{ .alter_schema_owner = .{ .name = name, .owner = owner } };
        }
        if (dialect == .postgres and try p.take("statistics")) return .{ .alter_statistics = try p.alterStatistics() };
        if (p.word("domain") or p.word("type")) return error.UnsupportedStatement;
        if (try p.take("role") or try p.take("user") or try p.take("group")) return .{ .alter_role = try p.roleSpec(.role, false) };
        if (try p.take("policy")) return .{ .alter_policy = try p.policy(.alter) };
        if (try p.take("table")) return p.tableSecurity();
        return null;
    }
    if (try p.take("drop")) {
        if (dialect == .postgres and try p.take("statistics")) return .{ .drop_statistics = try p.dropQualifiedList() };
        if (try p.take("domain")) return .{ .drop_domain = try p.dropQualifiedList() };
        if (try p.take("type")) return .{ .drop_type = try p.dropQualifiedList() };
        if (try p.take("role") or try p.take("user") or try p.take("group")) return .{ .drop_role = try p.dropList() };
        if (try p.take("policy")) return .{ .drop_policy = try p.policy(.drop) };
        if (try p.take("foreign")) {
            if (try p.take("data")) {
                try p.expect("wrapper");
                return .{ .drop_fdw = try p.dropList() };
            }
            if (p.word("table")) return error.UnsupportedStatement;
            return error.Syntax;
        }
        if (try p.take("server")) return .{ .drop_server = try p.dropList() };
        if (try p.take("publication")) return .{ .drop_publication = try p.dropList() };
        if (p.word("extension") or p.word("subscription")) return error.UnsupportedStatement;
        return null;
    }
    if (try p.take("grant")) return .{ .grant = try p.grant(false, dialect == .postgres, false) };
    if (try p.take("revoke")) return .{ .revoke = try p.grant(true, dialect == .postgres, false) };
    if (try p.take("comment")) return .{ .comment = try p.comment(dialect == .postgres) };
    return null;
}

const Parser = struct {
    tokens: lexer.Tokenizer,
    current: lexer.Token = .{},
    source: []const u8,
    name_bytes: usize,

    fn advance(self: *Parser) Error!void {
        self.current = try self.tokens.next();
    }

    /// An unquoted word spelled `expected` (any case).
    fn word(self: *const Parser, comptime expected: []const u8) bool {
        return self.current.kind == .word and types.keyword(self.current.raw(self.source), expected);
    }

    fn take(self: *Parser, comptime expected: []const u8) Error!bool {
        if (!self.word(expected)) return false;
        try self.advance();
        return true;
    }

    fn expect(self: *Parser, comptime expected: []const u8) Error!void {
        if (!try self.take(expected)) return error.Syntax;
    }

    fn symbol(self: *const Parser, wanted: lexer.Symbol) bool {
        return self.current.kind == .symbol and self.current.symbol == wanted;
    }

    fn takeSymbol(self: *Parser, wanted: lexer.Symbol) Error!bool {
        if (!self.symbol(wanted)) return false;
        try self.advance();
        return true;
    }

    fn expectSymbol(self: *Parser, wanted: lexer.Symbol) Error!void {
        if (!try self.takeSymbol(wanted)) return error.Syntax;
    }

    fn atEnd(self: *const Parser) bool {
        return self.current.kind == .end or self.symbol(.semicolon);
    }

    fn finish(self: *Parser) Error!void {
        _ = try self.takeSymbol(.semicolon);
        if (self.current.kind != .end) return error.Syntax;
    }

    /// A name: a quoted identifier, or a word that is not reserved.
    fn ident(self: *Parser) Error!Ident {
        const token = self.current;
        if (token.kind == .quoted_word) {
            if (token.len > self.name_bytes) return error.NameCapacity;
            try self.advance();
            return .{ .span = .{ .start = token.start, .len = token.end - token.start }, .quoted = true, .len = token.len };
        }
        if (token.kind != .word or lexer.reserved(token.keyword)) return error.Syntax;
        if (token.len > self.name_bytes) return error.NameCapacity;
        try self.advance();
        return .{ .span = .{ .start = token.start, .len = token.len }, .len = token.len };
    }

    fn qualified(self: *Parser) Error!Qualified {
        var out: Qualified = .{ .name = try self.ident() };
        if (try self.takeSymbol(.dot)) {
            out.schema = out.name;
            out.has_schema = true;
            out.name = try self.ident();
        }
        return out;
    }

    fn string(self: *Parser) Error!lexer.Quoted {
        if (self.current.kind != .string) return error.Syntax;
        const out = self.current.quoted();
        try self.advance();
        return out;
    }

    fn ifExists(self: *Parser) Error!bool {
        if (!self.word("if")) return false;
        try self.advance();
        try self.expect("exists");
        return true;
    }

    fn ifNotExists(self: *Parser) Error!bool {
        if (!self.word("if")) return false;
        try self.advance();
        try self.expect("not");
        try self.expect("exists");
        return true;
    }

    fn dropBehavior(self: *Parser) Error!bool {
        if (try self.take("cascade")) return true;
        _ = try self.take("restrict");
        return false;
    }

    fn domainInteger(self: *Parser) Error!i64 {
        const negative = try self.takeSymbol(.minus);
        if (!negative) _ = try self.takeSymbol(.plus);
        if (self.current.kind != .integer) return error.UnsupportedStatement;
        const magnitude = self.current.integer;
        const limit: u64 = if (negative) 0x8000000000000000 else 0x7fffffffffffffff;
        if (magnitude > limit) return error.NumericValueOutOfRange;
        try self.advance();
        return if (negative) @bitCast(0 -% magnitude) else @intCast(magnitude);
    }

    fn domainComparison(self: *Parser) Error!DomainComparison {
        if (self.current.kind != .symbol) return error.UnsupportedStatement;
        const op: DomainComparison = switch (self.current.symbol) {
            .eq => .eq, .ne => .ne, .lt => .lt, .le => .le, .gt => .gt, .ge => .ge,
            else => return error.UnsupportedStatement,
        };
        try self.advance();
        return op;
    }

    fn createDomain(self: *Parser) Error!CreateDomain {
        const name = try self.qualified();
        _ = try self.take("as");
        var spec: Domain = .{};
        if (try self.take("smallint") or try self.take("int2")) {
            spec.base = .int2;
        } else if (try self.take("integer") or try self.take("int") or try self.take("int4")) {
            spec.base = .int4;
        } else if (try self.take("bigint") or try self.take("int8")) {
            spec.base = .int8;
        } else return error.UnsupportedStatement;
        var null_seen = false;
        while (!self.atEnd()) {
            if (!null_seen and (self.word("null") or self.word("not"))) {
                spec.not_null = try self.take("not");
                try self.expect("null");
                null_seen = true;
            } else if (spec.comparison == .none and try self.take("check")) {
                try self.expectSymbol(.lparen);
                const value_first = try self.take("value");
                if (!value_first) spec.bound = try self.domainInteger();
                spec.comparison = try self.domainComparison();
                if (value_first) {
                    spec.bound = try self.domainInteger();
                } else {
                    try self.expect("value");
                    spec.comparison = spec.comparison.reverse();
                }
                if (!try self.takeSymbol(.rparen)) return error.UnsupportedStatement;
            } else return error.UnsupportedStatement;
        }
        try self.finish();
        return .{ .name = name, .spec = spec };
    }

    fn createType(self: *Parser) Error!Statement {
        const name = try self.qualified();
        if (!try self.take("as")) return error.UnsupportedStatement;
        if (try self.take("enum")) return .{ .create_enum = .{ .name = name, .labels = try self.enumBody() } };
        if (!self.symbol(.lparen)) return error.UnsupportedStatement;
        return .{ .create_composite = .{ .name = name, .fields = try self.compositeBody() } };
    }

    fn enumBody(self: *Parser) Error!Span {
        if (!self.symbol(.lparen)) return error.Syntax;
        const start = self.current.end;
        try self.advance();
        if (!self.symbol(.rparen)) {
            while (true) {
                _ = try self.string();
                if (!try self.takeSymbol(.comma)) break;
            }
        }
        const end = self.current.start;
        try self.expectSymbol(.rparen);
        try self.finish();
        return .{ .start = start, .len = end - start };
    }

    fn compositeBody(self: *Parser) Error!Span {
        const start = self.current.end;
        try self.advance();
        var depth: usize = 1;
        while (true) {
            if (self.atEnd()) return error.Syntax;
            if (self.symbol(.lparen)) depth += 1;
            if (self.symbol(.rparen)) {
                depth -= 1;
                if (depth == 0) break;
            }
            try self.advance();
        }
        const end = self.current.start;
        try self.advance();
        try self.finish();
        return .{ .start = start, .len = end - start };
    }

    fn dropQualifiedList(self: *Parser) Error!DropTypes {
        var drop: DropTypes = .{ .if_exists = try self.ifExists() };
        while (true) {
            if (drop.count == list_capacity) return error.ProgramLimitExceeded;
            drop.names[drop.count] = try self.qualified();
            drop.count += 1;
            if (!try self.takeSymbol(.comma)) break;
        }
        // Type arrays and enum labels always follow the owning type;
        // composite columns and routines decide on CASCADE (composite lane).
        drop.cascade = try self.dropBehavior();
        try self.finish();
        return drop;
    }

    fn statistics(self: *Parser) Error!Statistics {
        const conditional = try self.ifNotExists();
        if (self.word("on") or self.symbol(.lparen)) return error.UnsupportedStatement;
        var out: Statistics = .{ .name = try self.qualified(), .if_not_exists = conditional };
        if (try self.takeSymbol(.lparen)) {
            out.flags = 0;
            while (true) {
                const flag: u32 = if (try self.take("ndistinct")) 1 else if (try self.take("dependencies")) 2 else if (try self.take("mcv")) 4 else return error.Syntax;
                out.flags |= flag;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
        }
        try self.expect("on");
        while (true) {
            if (out.count == statistics_columns) return error.ProgramLimitExceeded;
            if (self.symbol(.lparen)) return error.UnsupportedStatement;
            out.columns[out.count] = try self.ident();
            out.count += 1;
            if (!try self.takeSymbol(.comma)) break;
        }
        if (!try self.take("from")) return error.UnsupportedStatement;
        out.table = try self.qualified();
        if (!self.atEnd()) return error.UnsupportedStatement;
        try self.finish();
        return out;
    }

    fn alterStatistics(self: *Parser) Error!AlterStatistics {
        const conditional = try self.ifExists();
        const name = try self.qualified();
        if (!try self.take("set") or !try self.take("statistics")) return error.UnsupportedStatement;
        const target = try self.domainInteger();
        if (target < -1) return error.InvalidParameterValue;
        try self.finish();
        return .{ .name = name, .if_exists = conditional, .target = @intCast(@min(target, 10000)) };
    }

    fn dropList(self: *Parser) Error!Drop {
        var out: Drop = .{ .if_exists = try self.ifExists() };
        while (true) {
            if (out.count == list_capacity) return error.ProgramLimitExceeded;
            out.names[out.count] = try self.ident();
            out.count += 1;
            if (!try self.takeSymbol(.comma)) break;
        }
        out.cascade = try self.dropBehavior();
        try self.finish();
        return out;
    }

    /// PUBLIC, CURRENT_USER, SESSION_USER, CURRENT_ROLE or a role name.
    fn grantee(self: *Parser) Error!Grantee {
        if (self.current.kind == .word) {
            const raw = self.current.raw(self.source);
            const special: ?GranteeKind = if (types.keyword(raw, "public")) .public else if (types.keyword(raw, "current_user")) .current_user else if (types.keyword(raw, "session_user")) .session_user else if (types.keyword(raw, "current_role")) .current_role else null;
            if (special) |kind| {
                try self.advance();
                return .{ .kind = kind };
            }
            _ = try self.take("group");
        }
        return .{ .name = try self.roleName() };
    }

    /// Role names may be non-reserved keywords; `user`, `role` and the
    /// special role names are not plain names.
    fn roleName(self: *Parser) Error!Ident {
        if (self.current.kind == .word) {
            const raw = self.current.raw(self.source);
            for ([_][]const u8{ "current_user", "session_user", "current_role", "user", "none" }) |reserved| {
                if (types.keyword(raw, reserved)) return error.Syntax;
            }
        }
        return self.ident();
    }

    fn roleSpec(self: *Parser, kind: RoleKind, create: bool) Error!RoleSpec {
        var out: RoleSpec = .{ .kind = kind };
        if (!create and (self.word("all") or self.word("current_user") or self.word("session_user") or self.word("current_role"))) return error.UnsupportedStatement;
        out.name = try self.roleName();
        if (kind == .user and create) out.set |= role_login;
        if (!create) {
            if (try self.take("rename")) {
                try self.expect("to");
                out.rename = true;
                out.new_name = try self.roleName();
                try self.finish();
                return out;
            }
            if (try self.take("set")) {
                out.defaults = try self.roleDefaults(false);
                return out;
            }
            if (try self.take("reset")) {
                out.defaults = try self.roleDefaults(true);
                return out;
            }
            if (self.word("in")) return error.UnsupportedStatement;
        }
        _ = try self.take("with");
        var seen: u32 = 0;
        while (!self.atEnd()) {
            const on_words = [_][]const u8{ "superuser", "inherit", "createrole", "createdb", "login", "replication", "bypassrls" };
            const off_words = [_][]const u8{ "nosuperuser", "noinherit", "nocreaterole", "nocreatedb", "nologin", "noreplication", "nobypassrls" };
            const bits = [_]u32{ role_superuser, role_inherit, role_createrole, role_createdb, role_login, role_replication, role_bypassrls };
            var matched = false;
            if (self.current.kind == .word) {
                const raw = self.current.raw(self.source);
                for (on_words, off_words, bits) |on_word, off_word, bit| {
                    const on = types.keyword(raw, on_word);
                    if (!on and !types.keyword(raw, off_word)) continue;
                    // Conflicting or redundant options (42601).
                    if (seen & bit != 0) return error.Syntax;
                    seen |= bit;
                    if (on) {
                        out.set |= bit;
                        out.clear &= ~bit;
                    } else {
                        out.clear |= bit;
                        out.set &= ~bit;
                    }
                    matched = true;
                    break;
                }
            }
            if (matched) {
                try self.advance();
                continue;
            }
            if (try self.take("connection")) {
                try self.expect("limit");
                if (out.connlimit_set) return error.Syntax;
                const negative = try self.takeSymbol(.minus);
                if (self.current.kind != .integer or self.current.integer > 0x7fffffff) return error.Syntax;
                const magnitude: i32 = @intCast(self.current.integer);
                try self.advance();
                out.connlimit = if (negative) -magnitude else magnitude;
                if (out.connlimit < -1) return error.InvalidParameterValue;
                out.connlimit_set = true;
                continue;
            }
            if (create and try self.take("in")) {
                if (!try self.take("role")) try self.expect("group");
                while (true) {
                    if (out.in_count == list_capacity) return error.ProgramLimitExceeded;
                    out.in_roles[out.in_count] = try self.roleName();
                    out.in_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
                continue;
            }
            // Passwords (RAMSQL authenticates only its SCRAM user), expiry,
            // SYSID and member lists are outside the subset.
            if (self.word("password") or self.word("encrypted") or self.word("unencrypted") or self.word("valid") or
                self.word("sysid") or self.word("role") or self.word("admin") or self.word("user")) return error.UnsupportedStatement;
            return error.Syntax;
        }
        try self.finish();
        return out;
    }

    fn roleDefaults(self: *Parser, reset: bool) Error!RoleDefaults {
        if (reset and try self.take("all")) {
            try self.finish();
            return .reset_all;
        }
        const token = self.current;
        if (token.kind != .word and token.kind != .quoted_word) return error.Syntax;
        const name = token.raw(self.source);
        const setting = inline for (@typeInfo(RoleBoolean).@"enum".field_names) |field| {
            const matches = if (token.kind == .quoted_word) types.same(name, field) else types.keyword(name, field);
            if (matches) break @field(RoleBoolean, field);
        } else return error.UnsupportedStatement;
        try self.advance();
        if (reset) {
            try self.finish();
            return .{ .reset = setting };
        }
        if (try self.take("from")) {
            try self.expect("current");
            try self.finish();
            return .{ .from_current = setting };
        }
        if (!try self.take("to") and !try self.takeSymbol(.eq)) return error.Syntax;
        if (try self.take("default")) {
            try self.finish();
            return .{ .reset = setting };
        }
        const value = self.current;
        if (value.kind != .word and value.kind != .string and value.kind != .integer) return error.Syntax;
        const spelling: Span = .{ .start = value.start, .len = value.end - value.start };
        try self.advance();
        try self.finish();
        return .{ .set = .{ .setting = setting, .spelling = spelling, .quoted = if (value.kind == .string) value.quoted() else null } };
    }

    const PolicyForm = enum { create, alter, drop };

    fn policy(self: *Parser, form: PolicyForm) Error!Policy {
        var out: Policy = .{};
        if (form == .drop) out.if_exists = try self.ifExists();
        out.name = try self.ident();
        try self.expect("on");
        out.table = try self.qualified();
        switch (form) {
            .drop => {
                _ = try self.dropBehavior();
                try self.finish();
                return out;
            },
            .alter => if (try self.take("rename")) {
                try self.expect("to");
                out.rename = true;
                out.new_name = try self.ident();
                try self.finish();
                return out;
            },
            .create => {
                if (try self.take("as")) {
                    if (try self.take("restrictive")) out.permissive = false else try self.expect("permissive");
                }
                if (try self.take("for")) {
                    out.command_set = true;
                    out.command = if (try self.take("all")) .all else if (try self.take("select")) .select else if (try self.take("insert")) .insert else if (try self.take("update")) .update else if (try self.take("delete")) .delete else return error.Syntax;
                }
            },
        }
        if (try self.take("to")) {
            while (true) {
                if (out.role_count == list_capacity) return error.ProgramLimitExceeded;
                out.roles[out.role_count] = try self.grantee();
                out.role_count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
        }
        if (try self.take("using")) {
            out.using = try self.parenthesized();
            out.has_using = true;
        }
        if (try self.take("with")) {
            try self.expect("check");
            out.check = try self.parenthesized();
            out.has_check = true;
        }
        try self.finish();
        if (form == .alter and out.role_count == 0 and !out.has_using and !out.has_check) return error.Syntax;
        return out;
    }

    /// `( expression )`: the span between the parentheses, balanced.
    fn parenthesized(self: *Parser) Error!Span {
        if (!self.symbol(.lparen)) return error.Syntax;
        try self.advance();
        const start = self.current.start - self.current.prefix;
        var depth: usize = 1;
        while (true) {
            if (self.current.kind == .end) return error.Syntax;
            if (self.current.dialectQuotedIdentifier(self.source)) return error.UnsupportedStatement;
            if (self.symbol(.lparen)) depth += 1;
            if (self.symbol(.rparen)) {
                depth -= 1;
                if (depth == 0) break;
            }
            try self.advance();
        }
        const end = self.current.start;
        try self.advance();
        if (end <= start) return error.Syntax;
        return .{ .start = start, .len = end - start };
    }

    /// ALTER TABLE ... {ENABLE|DISABLE|FORCE|NO FORCE} ROW LEVEL SECURITY
    /// or OWNER TO; null for every other ALTER TABLE.
    fn tableSecurity(self: *Parser) Error!?Statement {
        var out: TableSecurity = .{ .if_exists = try self.ifExists() };
        _ = try self.take("only");
        out.table = self.qualified() catch return null;
        _ = try self.takeSymbol(.star);
        if (try self.take("owner")) {
            try self.expect("to");
            out.action = .owner;
            out.owner = try self.grantee();
            if (out.owner.kind == .public) return error.Syntax;
        } else {
            if (try self.take("enable")) {
                out.action = .enable;
            } else if (try self.take("disable")) {
                out.action = .disable;
            } else if (try self.take("force")) {
                out.action = .force;
            } else if (self.word("no")) {
                try self.advance();
                if (!try self.take("force")) return null;
                out.action = .no_force;
            } else return null;
            if (!self.word("row")) return null;
            try self.advance();
            try self.expect("level");
            try self.expect("security");
        }
        // Combining these with other ALTER TABLE actions is outside the subset.
        if (self.symbol(.comma)) return error.UnsupportedStatement;
        try self.finish();
        return .{ .table_security = out };
    }

    fn privilegeWord(raw: []const u8) ?u32 {
        if (types.keyword(raw, "execute")) return priv_execute;
        if (types.keyword(raw, "usage")) return priv_schema_usage;
        if (types.keyword(raw, "create")) return priv_schema_create;
        // Database privileges: recognized, never valid on the objects here (0LP01).
        if (types.keyword(raw, "temporary") or types.keyword(raw, "temp")) return priv_temporary;
        if (types.keyword(raw, "connect")) return priv_connect;
        for (privilege_words, privilege_bits) |spelled, bit| if (types.keyword(raw, spelled)) return bit;
        return null;
    }

    /// `( column [, ...] )` after a privilege word (ALL: every column privilege).
    fn columnList(self: *Parser, out: *Grant, privileges: u32) Error!void {
        try self.expectSymbol(.lparen);
        while (true) {
            if (out.column_count == column_grant_capacity) return error.ProgramLimitExceeded;
            out.columns[out.column_count] = .{ .privileges = privileges, .column = try self.ident() };
            out.column_count += 1;
            if (!try self.takeSymbol(.comma)) break;
        }
        try self.expectSymbol(.rparen);
    }

    fn objectId(self: *Parser) Error!u32 {
        if (self.current.kind != .integer) return error.Syntax;
        if (self.current.integer > 0xffff_ffff) return error.NumericValueOutOfRange;
        const oid: u32 = @intCast(self.current.integer);
        try self.advance();
        return oid;
    }

    fn largeObjectDefaults(self: *Parser) Error!LargeObjectDefaults {
        var out: LargeObjectDefaults = .{};
        while (true) {
            if (try self.take("for")) {
                if (out.count != 0) return error.Syntax;
                if (!try self.take("role")) try self.expect("user");
                while (true) {
                    if (out.count == list_capacity) return error.ProgramLimitExceeded;
                    const owner = try self.grantee();
                    if (owner.kind == .public) return error.InvalidGrantOperation;
                    out.owners[out.count] = owner;
                    out.count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
            } else if (try self.take("in")) {
                if (out.schema_count != 0) return error.Syntax;
                try self.expect("schema");
                while (true) {
                    if (out.schema_count == list_capacity) return error.ProgramLimitExceeded;
                    out.schemas[out.schema_count] = try self.ident();
                    out.schema_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
            } else break;
        }
        out.revoke = try self.take("revoke");
        if (!out.revoke) try self.expect("grant");
        out.grant = try self.grant(out.revoke, true, true);
        if (out.schema_count != 0 and !out.grant.routine_defaults) return error.InvalidGrantOperation;
        return out;
    }

    fn grant(self: *Parser, revoke: bool, postgres: bool, comptime defaults: bool) Error!Grant {
        var out: Grant = .{};
        if (revoke) {
            if (self.word("grant") or self.word("admin")) {
                const admin = self.word("admin");
                try self.advance();
                try self.expect("option");
                try self.expect("for");
                out.option = true;
                out.membership = admin;
            } else if (self.word("inherit") or self.word("set")) {
                // REVOKE { INHERIT | SET } OPTION FOR role FROM member.
                const inherit = self.word("inherit");
                var lookahead = self.tokens;
                const next = try lookahead.next();
                if (next.kind == .word and types.keyword(next.raw(self.source), "option")) {
                    try self.advance();
                    try self.expect("option");
                    try self.expect("for");
                    out.revoke_option = if (inherit) .inherit else .set;
                    out.membership = true;
                }
            }
        }
        // Items up to ON (privileges) or TO / FROM (roles).
        var privileges: u32 = 0;
        var all = false;
        var names_ok = true;
        var only_privileges = true;
        while (true) {
            if (self.word("all")) {
                try self.advance();
                _ = try self.take("privileges");
                names_ok = false;
                // ALL (columns): every column privilege on those columns.
                if (self.symbol(.lparen)) try self.columnList(&out, column_privileges) else all = true;
            } else {
                const bit = if (self.current.kind == .word) privilegeWord(self.current.raw(self.source)) else null;
                if (bit) |known| out.written |= known else only_privileges = false;
                if (out.granted_count == list_capacity) return error.ProgramLimitExceeded;
                if (bit != null and self.current.keyword != .none and lexer.reserved(self.current.keyword)) {
                    // SELECT / UPDATE / DELETE / INSERT are reserved words: never role names.
                    names_ok = false;
                    try self.advance();
                } else {
                    out.granted[out.granted_count] = try self.roleName();
                    out.granted_count += 1;
                }
                if (self.symbol(.lparen)) {
                    // GRANT SELECT (a, b) ...: column privileges.
                    const known = bit orelse return error.Syntax;
                    names_ok = false;
                    try self.columnList(&out, known);
                } else if (bit) |known| privileges |= known;
            }
            if (!try self.takeSymbol(.comma)) break;
        }
        if (try self.take("on")) {
            out.schema = try self.take("schema");
            out.routine_defaults = defaults and (try self.take("functions") or try self.take("routines"));
            const large_object = !out.schema and postgres and try self.take("large");
            if (defaults and !large_object and !out.routine_defaults) return error.UnsupportedStatement;
            if (large_object) try self.expect(if (defaults) "objects" else "object");
            if (!out.schema and !large_object and !out.routine_defaults) {
                if (postgres and try self.take("sequence")) {
                    out.object = .sequence;
                } else if (postgres and try self.take("domain")) {
                    out.object = .domain;
                } else if (postgres and try self.take("type")) {
                    out.object = .type_name;
                } else if (postgres and self.word("all")) {
                    try self.advance();
                    if (try self.take("tables")) {
                        out.object = .all_tables;
                    } else if (try self.take("sequences")) {
                        out.object = .all_sequences;
                    } else return error.UnsupportedStatement;
                    try self.expect("in");
                    try self.expect("schema");
                } else if (self.word("sequence") or self.word("database") or self.word("function") or self.word("procedure") or
                    self.word("routine") or self.word("language") or self.word("type") or self.word("domain") or self.word("foreign") or
                    self.word("large") or self.word("tablespace") or self.word("parameter") or self.word("all")) return error.UnsupportedStatement;
            }
            if (out.schema) out.object = .schema;
            if (!only_privileges and !all) return error.Syntax;
            if (out.column_count != 0 and (large_object or out.routine_defaults or out.object != .table)) return error.InvalidGrantOperation;
            if (large_object) {
                if (out.membership) return error.Syntax;
                if (privileges & ~large_object_privileges != 0) return error.InvalidGrantOperation;
                out.privileges = if (all) large_object_privileges else privileges;
                out.all_privileges = all;
                while (!defaults) {
                    if (out.large_object_count == list_capacity) return error.ProgramLimitExceeded;
                    out.large_objects[out.large_object_count] = try self.objectId();
                    out.large_object_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
            } else if (out.routine_defaults) {
                if (out.membership) return error.Syntax;
                if (privileges & ~priv_execute != 0) return error.InvalidGrantOperation;
                out.privileges = if (all) priv_execute else privileges;
                out.all_privileges = all;
            } else if (out.object == .table) {
                _ = try self.take("table");
            }
            if (!large_object and !out.routine_defaults) {
                // Privilege types are validated per object at execution
                // (0LP01 after the objects and grantees resolve).
                out.privileges = privileges;
                out.all_privileges = all;
                while (true) {
                    if (out.table_count == list_capacity) return error.ProgramLimitExceeded;
                    out.tables[out.table_count] = try self.qualified();
                    out.table_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
            }
            out.granted_count = 0;
        } else {
            if (defaults) return error.Syntax;
            if (!names_ok or out.granted_count == 0) return error.Syntax;
            if (revoke and out.option and !out.membership) return error.Syntax;
            out.membership = true;
        }
        if (revoke) try self.expect("from") else try self.expect("to");
        while (true) {
            if (out.grantee_count == list_capacity) return error.ProgramLimitExceeded;
            out.grantees[out.grantee_count] = try self.grantee();
            out.grantee_count += 1;
            if (!try self.takeSymbol(.comma)) break;
        }
        if (!revoke and try self.take("with")) {
            if (out.membership) {
                while (true) {
                    const option = if (try self.take("admin")) &out.admin
                        else if (try self.take("inherit")) &out.inherit
                        else if (try self.take("set")) &out.set
                        else return error.Syntax;
                    if (option.* != null) return error.Syntax;
                    option.* = if (try self.take("false")) false
                        else if (try self.take("true") or try self.take("option")) true
                        else return error.Syntax;
                    if (!try self.takeSymbol(.comma)) break;
                }
            } else {
                try self.expect("grant");
                try self.expect("option");
                out.option = true;
            }
        }
        if (try self.take("granted")) {
            if (defaults) return error.Syntax;
            try self.expect("by");
            out.grantor = try self.grantee();
        }
        if (revoke) out.cascade = try self.dropBehavior();
        try self.finish();
        return out;
    }

    fn comment(self: *Parser, postgres: bool) Error!Comment {
        try self.expect("on");
        var out: Comment = .{};
        if (postgres and try self.take("large")) {
            try self.expect("object");
            out.target = .large_object;
            out.large_object = try self.objectId();
        } else if (try self.take("table")) {
            out.target = .table;
            out.object = try self.qualified();
        } else if (try self.take("view")) {
            out.target = .view;
            out.object = try self.qualified();
        } else if (try self.take("materialized")) {
            try self.expect("view");
            out.target = .materialized_view;
            out.object = try self.qualified();
        } else if (try self.take("sequence")) {
            out.target = .sequence;
            out.object = try self.qualified();
        } else if (try self.take("index")) {
            out.target = .index;
            out.object = try self.qualified();
        } else if (try self.take("column")) {
            out.target = .column;
            // [schema.]table.column
            const first = try self.ident();
            try self.expectSymbol(.dot);
            const second = try self.ident();
            if (try self.takeSymbol(.dot)) {
                out.object = .{ .has_schema = true, .schema = first, .name = second };
                out.column = try self.ident();
            } else {
                out.object = .{ .name = first };
                out.column = second;
            }
        } else if (try self.take("schema")) {
            out.target = .schema;
            out.object = .{ .name = try self.ident() };
        } else if (try self.take("role")) {
            out.target = .role;
            out.object = .{ .name = try self.roleName() };
        } else if (try self.take("policy")) {
            out.target = .policy;
            out.object = .{ .name = try self.ident() };
            try self.expect("on");
            out.on = try self.qualified();
        } else if (try self.take("foreign")) {
            if (try self.take("data")) {
                try self.expect("wrapper");
                out.target = .fdw;
                out.object = .{ .name = try self.ident() };
            } else if (try self.take("table")) {
                out.target = .foreign_table;
                out.object = try self.qualified();
            } else return error.Syntax;
        } else if (try self.take("server")) {
            out.target = .server;
            out.object = .{ .name = try self.ident() };
        } else if (try self.take("publication")) {
            out.target = .publication;
            out.object = .{ .name = try self.ident() };
        } else if (try self.take("extension")) {
            out.target = .extension;
            out.object = .{ .name = try self.ident() };
        } else return error.UnsupportedStatement;
        try self.expect("is");
        if (self.current.kind == .word and self.current.isWord("NULL")) {
            try self.advance();
        } else {
            out.text = try self.string();
            out.has_text = true;
        }
        try self.finish();
        return out;
    }

    fn fdw(self: *Parser) Error!Named {
        const out: Named = .{ .name = try self.ident() };
        while (!self.atEnd()) {
            if (self.word("no")) {
                try self.advance();
                if (!try self.take("handler")) try self.expect("validator");
                continue;
            }
            // Handler / validator functions and options are outside the subset.
            if (self.word("handler") or self.word("validator") or self.word("options")) return error.UnsupportedStatement;
            return error.Syntax;
        }
        try self.finish();
        return out;
    }

    fn server(self: *Parser) Error!Server {
        var out: Server = .{ .if_not_exists = try self.ifNotExists() };
        out.name = try self.ident();
        if (try self.take("type")) {
            out.server_type = try self.string();
            out.has_type = true;
        }
        if (try self.take("version")) {
            out.version = try self.string();
            out.has_version = true;
        }
        try self.expect("foreign");
        try self.expect("data");
        try self.expect("wrapper");
        out.fdw = try self.ident();
        if (self.word("options")) return error.UnsupportedStatement;
        try self.finish();
        return out;
    }

    fn publication(self: *Parser) Error!Publication {
        var out: Publication = .{ .name = try self.ident() };
        if (try self.take("for")) {
            if (try self.take("all")) {
                try self.expect("tables");
                out.flags |= pub_all_tables;
            } else try self.publicationMembers(&out);
        }
        if (try self.take("with")) {
            try self.expectSymbol(.lparen);
            var seen_publish = false;
            var seen_root = false;
            while (true) {
                if (try self.take("publish")) {
                    if (seen_publish) return error.Syntax;
                    seen_publish = true;
                    try self.expectSymbol(.eq);
                    const quoted = try self.string();
                    out.flags = (out.flags & ~pub_default) | try publishList(self.source, quoted);
                } else if (try self.take("publish_via_partition_root")) {
                    if (seen_root) return error.Syntax;
                    seen_root = true;
                    var on = true;
                    if (try self.takeSymbol(.eq)) {
                        if (self.current.kind == .word and (self.current.isWord("TRUE") or types.keyword(self.current.raw(self.source), "on"))) {
                            try self.advance();
                        } else if (self.current.kind == .word and (self.current.isWord("FALSE") or types.keyword(self.current.raw(self.source), "off"))) {
                            on = false;
                            try self.advance();
                        } else return error.InvalidParameterValue;
                    }
                    if (on) out.flags |= pub_via_root else out.flags &= ~pub_via_root;
                } else if (self.current.kind == .word) {
                    // publish_generated_columns and unknown parameters.
                    return error.UnsupportedStatement;
                } else return error.Syntax;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
        }
        try self.finish();
        return out;
    }

    fn publicationMembers(self: *Parser, publication_spec: *Publication) Error!void {
        var schemas = false;
        while (true) {
            if (try self.take("tables")) {
                try self.expect("in");
                try self.expect("schema");
                schemas = true;
            } else if (try self.take("table")) {
                schemas = false;
            } else if (publication_spec.count == 0) return error.Syntax;
            if (publication_spec.count == list_capacity) return error.ProgramLimitExceeded;
            const member: Publication.Member = if (schemas) blk: {
                if (self.word("current_schema")) return error.UnsupportedStatement;
                break :blk .{ .schema = try self.ident() };
            } else blk: {
                const only = try self.take("only");
                const table = try self.qualified();
                const include_descendants = try self.takeSymbol(.star);
                if (only and include_descendants) return error.Syntax;
                if (self.symbol(.lparen) or self.word("where")) return error.UnsupportedStatement;
                break :blk .{ .table = .{ .name = table, .only = only } };
            };
            publication_spec.members[publication_spec.count] = member;
            publication_spec.count += 1;
            if (!try self.takeSymbol(.comma)) break;
        }
    }
};

/// The `publish` option: a comma-separated list of insert, update, delete
/// and truncate (22023 for anything else).
fn publishList(source: []const u8, quoted: lexer.Quoted) Error!u32 {
    if (quoted.form != .standard) return error.UnsupportedStatement;
    const raw = source[quoted.start..quoted.end];
    var flags: u32 = 0;
    var start: usize = 0;
    while (start <= raw.len) {
        var end = start;
        while (end < raw.len and raw[end] != ',') end += 1;
        var a = start;
        var b = end;
        while (a < b and raw[a] == ' ') a += 1;
        while (b > a and raw[b - 1] == ' ') b -= 1;
        const item = raw[a..b];
        if (item.len != 0) {
            if (types.keyword(item, "insert")) flags |= pub_insert else if (types.keyword(item, "update")) flags |= pub_update else if (types.keyword(item, "delete")) flags |= pub_delete else if (types.keyword(item, "truncate")) flags |= pub_truncate else return error.InvalidParameterValue;
        }
        start = end + 1;
    }
    return flags;
}

/// Whether a role name is reserved: `public`, `none` and the pg_ prefix
/// (42939).
pub fn reservedRoleName(name: []const u8) bool {
    if (types.same(name, "public") or types.same(name, "none")) return true;
    return name.len >= 3 and name[0] == 'p' and name[1] == 'g' and name[2] == '_';
}

// ---- the versioned object store ----------------------------------------------

/// Little-endian reads over a change record (InvalidChangeRecord past its end).
pub const Cursor = struct {
    bytes: []const u8,
    position: *usize,

    fn take(self: Cursor, count: usize) Error![]const u8 {
        if (self.position.* > self.bytes.len or count > self.bytes.len - self.position.*) return error.InvalidChangeRecord;
        const out = self.bytes[self.position.*..][0..count];
        self.position.* += count;
        return out;
    }

    fn int(self: Cursor, comptime T: type) Error!T {
        const Bits = switch (@sizeOf(T)) {
            1 => u8,
            2 => u16,
            4 => u32,
            8 => u64,
            else => @compileError("unsupported object field"),
        };
        const raw = try self.take(@sizeOf(T));
        var bits: Bits = 0;
        for (0..@sizeOf(T)) |index| bits |= @as(Bits, raw[index]) << @intCast(index * 8);
        return @bitCast(bits);
    }
};

/// Kinds whose objects own an OID (allocated from the database counter).
pub fn ownsOid(kind: Kind) bool {
    return kind == .role or kind == .member or kind == .policy or kind == .fdw or kind == .server or kind == .publication or kind == .statistics or publicationMembership(kind) or userType(kind);
}

/// Kinds whose objects carry a unique name.
fn named(kind: Kind) bool {
    return kind == .role or kind == .policy or kind == .fdw or kind == .server or kind == .publication or kind == .statistics or userType(kind);
}

fn scoped(kind: Kind) bool {
    return kind == .policy or kind == .statistics or userType(kind);
}

pub fn Objects(comptime config: types.Config) type {
    const V = types.Values(config);
    if (config.object_text_bytes > 0xffff) @compileError("object_text_bytes must fit u16");
    if (config.policy_roles == 0 or config.policy_roles > 255) @compileError("policy_roles must be 1..255");
    if (config.catalog_objects == 0) @compileError("catalog_objects must be non-zero");
    return struct {
        const Self = @This();
        pub const capacity = config.catalog_objects;
        pub const text_capacity = config.object_text_bytes;
        pub const role_capacity = config.policy_roles;

        pub const Object = struct {
            used: bool = false,
            xmin: storage.TxRef = .{},
            xmin_cid: u32 = 0,
            xmin_csn: u64 = 0,
            xmax: storage.TxRef = .{},
            xmax_cid: u32 = 0,
            xmax_csn: u64 = 0,
            kind: Kind = .role,
            oid: u32 = 0,
            target: u32 = 0,
            grantee: u32 = 0,
            sub: i32 = 0,
            owner: u32 = 0,
            flags: u32 = 0,
            grant_flags: u32 = 0,
            name: V.Name = .{},
            roles: [role_capacity]u32 = @splat(0),
            role_count: u8 = 0,
            text: [text_capacity]u8 = @splat(0),
            text_len: u16 = 0,
            split: u16 = 0,
            /// Domain text is the array name. Enum text splits the array
            /// name from the packed label sequence.
            domain: Domain = .{},
            enum_label_count: u16 = 0,
            composite_field_count: u16 = 0,

            pub fn largeObjectLength(self: *const Object) u64 {
                if (comptime text_capacity < 8) return 0;
                return if (self.text_len == 8) @import("std").mem.readInt(u64, self.text[0..8], .little) else 0;
            }

            pub fn setLargeObjectLength(self: *Object, length: u64) Error!void {
                self.text_len = 0;
                if (length == 0) return;
                if (comptime text_capacity < 8) return error.TextCapacity;
                @import("std").mem.writeInt(u64, self.text[0..8], length, .little);
                self.text_len = 8;
            }

            pub fn oidWidth(self: *const Object) u32 {
                if (self.kind == .composite_type) return 3;
                if (userType(self.kind)) return 2 + @as(u32, self.enum_label_count);
                if (defaultAcl(self.kind)) return @intFromBool(self.oid != 0);
                return @intFromBool(ownsOid(self.kind));
            }

            pub fn arrayName(self: *const Object) []const u8 {
                return if (self.kind == .domain) self.textSlice() else self.text[0..self.split];
            }

            pub fn enumLabels(self: *const Object) EnumLabels {
                return .{ .bytes = self.text[self.split..self.text_len] };
            }

            pub fn compositeFields(self: *const Object) CompositeFields {
                return .{ .bytes = self.text[self.split..self.text_len] };
            }

            pub fn compositeRelationOid(self: *const Object) u32 {
                return self.oid + 2;
            }

            pub fn textSlice(self: *const Object) []const u8 {
                return self.text[0..self.text_len];
            }

            pub fn usingText(self: *const Object) []const u8 {
                return self.text[0..self.split];
            }

            pub fn checkText(self: *const Object) []const u8 {
                return self.text[self.split..self.text_len];
            }

            pub fn roleList(self: *const Object) []const u32 {
                return self.roles[0..self.role_count];
            }

            pub fn setText(self: *Object, first: []const u8, second: []const u8) Error!void {
                if (first.len + second.len > text_capacity) return error.TextCapacity;
                @memcpy(self.text[0..first.len], first);
                @memcpy(self.text[first.len..][0..second.len], second);
                self.split = @intCast(first.len);
                self.text_len = @intCast(first.len + second.len);
            }

            pub fn setName(self: *Object, value: []const u8) Error!void {
                if (value.len > config.name_bytes) return error.NameCapacity;
                self.name = .{ .len = value.len };
                @memcpy(self.name.bytes[0..value.len], value);
            }
        };

        items: [capacity]Object = @splat(.{}),

        fn created(o: *const Object, snap: storage.Snapshot) bool {
            if (o.xmin_csn != 0) return o.xmin_csn <= snap.csn;
            return snap.own(o.xmin) and o.xmin_cid < snap.cid;
        }

        fn deleted(o: *const Object, snap: storage.Snapshot) bool {
            if (o.xmax.epoch == 0) return false;
            if (o.xmax_csn != 0) return o.xmax_csn <= snap.csn;
            return snap.own(o.xmax) and o.xmax_cid < snap.cid;
        }

        pub fn visible(o: *const Object, snap: storage.Snapshot) bool {
            return o.used and created(o, snap) and !deleted(o, snap);
        }

        /// Same identity: the key of its kind.
        pub fn sameKey(a: *const Object, b: *const Object) bool {
            if (a.kind != b.kind) return false;
            return switch (a.kind) {
                .role, .policy, .fdw, .server, .publication, .statistics => a.oid == b.oid,
                .publication_table, .publication_schema => a.oid == b.oid and a.target == b.target and a.grantee == b.grantee,
                .domain, .enum_type, .composite_type => a.oid == b.oid and a.target == b.target,
                .large_object_default_acl => a.target == b.target and a.grantee == b.grantee,
                // Grant rows and memberships are keyed by their grantor too
                // (sub: 0 for the owner / legacy rows, else the grantor).
                .member, .acl, .schema_acl, .column_acl, .type_acl, .sequence_acl,
                .large_object_acl, .builtin_routine_acl, .routine_default_acl => a.target == b.target and a.grantee == b.grantee and a.sub == b.sub,
                .relation, .schema_acl_state, .schema_owner, .role_settings, .large_object => a.target == b.target,
                .comment => a.grantee == b.grantee and a.target == b.target and a.sub == b.sub,
                _ => false,
            };
        }

        /// The visible version with `key`'s identity.
        pub fn findKey(self: *const Self, key: *const Object, snap: storage.Snapshot) ?usize {
            for (&self.items, 0..) |*o, index| if (visible(o, snap) and sameKey(o, key)) return index;
            return null;
        }

        pub fn byOid(self: *const Self, kind: Kind, oid: u32, snap: storage.Snapshot) ?usize {
            for (&self.items, 0..) |*o, index| if (o.kind == kind and o.oid == oid and visible(o, snap)) return index;
            return null;
        }

        /// A visible named object (policies: of table `target`).
        pub fn byName(self: *const Self, kind: Kind, target: u32, name: []const u8, snap: storage.Snapshot) ?usize {
            for (&self.items, 0..) |*o, index| {
                if (o.kind != kind or !visible(o, snap) or !types.same(o.name.slice(), name)) continue;
                if (scoped(kind) and o.target != target) continue;
                return index;
            }
            return null;
        }

        pub fn userTypeNameTaken(self: *const Self, namespace: u32, name: []const u8, snap: storage.Snapshot) bool {
            for (&self.items) |*o| if (userType(o.kind) and o.target == namespace and visible(o, snap)) {
                if (types.same(o.name.slice(), name) or types.same(o.arrayName(), name)) return true;
            };
            return false;
        }

        pub fn pendingUserTypeName(self: *const Self, namespace: u32, name: []const u8, snap: storage.Snapshot) ?u16 {
            for (&self.items) |*o| {
                const other = pendingOf(o, snap) orelse continue;
                if (userType(o.kind) and o.target == namespace and (types.same(o.name.slice(), name) or types.same(o.arrayName(), name))) return other;
            }
            return null;
        }

        pub fn pendingCompositeRelationName(self: *const Self, namespace: u32, name: []const u8, snap: storage.Snapshot) ?u16 {
            for (&self.items) |*o| {
                if (o.kind != .composite_type or o.target != namespace or !types.same(o.name.slice(), name)) continue;
                if (pendingOf(o, snap)) |other| return other;
            }
            return null;
        }

        /// The live transaction (other than the snapshot's) holding an
        /// uncommitted version of `o`, if any.
        pub fn pendingOf(o: *const Object, snap: storage.Snapshot) ?u16 {
            if (!o.used) return null;
            if (o.xmin_csn == 0 and !snap.own(o.xmin)) return o.xmin.slot;
            if (o.xmax.epoch != 0 and o.xmax_csn == 0 and !snap.own(o.xmax)) return o.xmax.slot;
            return null;
        }

        /// Another live transaction creating or deleting an object with
        /// this identity, or (for named kinds) this name.
        pub fn pendingConflict(self: *const Self, key: *const Object, snap: storage.Snapshot) ?u16 {
            for (&self.items) |*o| {
                const other = pendingOf(o, snap) orelse continue;
                if (sameKey(o, key)) return other;
                if (named(key.kind) and o.kind == key.kind and types.same(o.name.slice(), key.name.slice()) and (!scoped(key.kind) or o.target == key.target)) return other;
            }
            return null;
        }

        /// Another live transaction with an uncommitted object that names
        /// `oid` (as a role, table, wrapper or object of a comment).
        pub fn pendingReference(self: *const Self, oid: u32, snap: storage.Snapshot) ?u16 {
            for (&self.items) |*o| {
                const other = pendingOf(o, snap) orelse continue;
                const large_object = o.kind == .large_object or o.kind == .large_object_acl or
                    (o.kind == .comment and o.grantee == class_large_object);
                if (o.owner == oid or (!large_object and (o.oid == oid or o.target == oid or o.grantee == oid)) or
                    (o.kind == .large_object_acl and o.grantee == oid) or
                    (o.kind == .routine_default_acl and @as(u32, @bitCast(o.sub)) == oid)) return other;
                for (o.roleList()) |role| if (role == oid) return other;
            }
            return null;
        }

        /// A free entry, reclaiming versions dead at `horizon` first when full.
        pub fn allocate(self: *Self, horizon: u64) Error!usize {
            for (&self.items, 0..) |*o, index| if (!o.used) return index;
            _ = self.vacuum(horizon);
            for (&self.items, 0..) |*o, index| if (!o.used) return index;
            return error.TableCapacity;
        }

        pub fn vacuum(self: *Self, horizon: u64) usize {
            var freed: usize = 0;
            for (&self.items) |*o| if (o.used and o.xmax.epoch != 0 and o.xmax_csn != 0 and o.xmax_csn <= horizon) {
                o.* = .{};
                freed += 1;
            };
            return freed;
        }

        /// Writes `value` as a new version created by `xmin` (csn 0: uncommitted).
        pub fn insert(self: *Self, index: usize, value: *const Object, xmin: storage.TxRef, cid: u32, csn: u64) void {
            const o = &self.items[index];
            o.* = value.*;
            o.used = true;
            o.xmin = xmin;
            o.xmin_cid = cid;
            o.xmin_csn = csn;
            o.xmax = .{};
            o.xmax_cid = 0;
            o.xmax_csn = 0;
        }

        pub fn mark(self: *Self, index: usize, xmax: storage.TxRef, cid: u32) void {
            const o = &self.items[index];
            o.xmax = xmax;
            o.xmax_cid = cid;
            o.xmax_csn = 0;
        }

        pub fn undoInsert(self: *Self, index: usize) void {
            self.items[index] = .{};
        }

        pub fn undoDelete(self: *Self, index: usize) void {
            const o = &self.items[index];
            o.xmax = .{};
            o.xmax_cid = 0;
            o.xmax_csn = 0;
        }

        pub fn stampInsert(self: *Self, index: usize, csn: u64) void {
            self.items[index].xmin_csn = csn;
        }

        pub fn stampDelete(self: *Self, index: usize, csn: u64) void {
            self.items[index].xmax_csn = csn;
        }

        /// Uncommitted versions (leak checks).
        pub fn pending(self: *const Self) usize {
            var count: usize = 0;
            for (&self.items) |*o| if (o.used and (o.xmin_csn == 0 or (o.xmax.epoch != 0 and o.xmax_csn == 0))) {
                count += 1;
            };
            return count;
        }

        // ---- roles, privileges and row security ------------------------

        /// Role attributes (null: no such role).
        pub fn roleFlags(self: *const Self, oid: u32, snap: storage.Snapshot) ?u32 {
            if (oid == bootstrap_role) return role_attributes;
            if (predefinedRole(oid)) return role_inherit;
            const index = self.byOid(.role, oid, snap) orelse return null;
            return self.items[index].flags;
        }

        pub fn roleName(self: *const Self, oid: u32, snap: storage.Snapshot) ?[]const u8 {
            if (oid == bootstrap_role) return bootstrap_name;
            if (predefinedName(oid)) |name| return name;
            const index = self.byOid(.role, oid, snap) orelse return null;
            return self.items[index].name.slice();
        }

        pub fn roleByName(self: *const Self, name: []const u8, snap: storage.Snapshot) ?u32 {
            if (types.same(name, bootstrap_name)) return bootstrap_role;
            if (predefinedByName(name)) |oid| return oid;
            const index = self.byName(.role, 0, name, snap) orelse return null;
            return self.items[index].oid;
        }

        pub fn superuser(self: *const Self, oid: u32, snap: storage.Snapshot) bool {
            const flags = self.roleFlags(oid, snap) orelse return false;
            return flags & role_superuser != 0;
        }

        pub fn membershipInherits(self: *const Self, entry: *const Object, snap: storage.Snapshot) bool {
            if (entry.flags != 0) return entry.flags & member_inherit != 0;
            return (self.roleFlags(entry.grantee, snap) orelse 0) & role_inherit != 0;
        }

        pub fn membershipCanSet(entry: *const Object) bool {
            return entry.flags == 0 or entry.flags & member_set != 0;
        }

        /// Walk either all edges (cycle detection) or only edges that allow
        /// the requested use of a membership.
        pub fn membershipPath(self: *const Self, member: u32, group: u32, path: MembershipPath, snap: storage.Snapshot) bool {
            if (member == group) return true;
            // Breadth-first over at most `capacity` roles.
            var queue: [capacity + 1]u32 = undefined;
            queue[0] = member;
            var count: usize = 1;
            var next: usize = 0;
            while (next < count) : (next += 1) {
                const current = queue[next];
                // Built-in memberships: the database owner (the bootstrap
                // role) is implicitly pg_database_owner; pg_monitor is a
                // member of pg_read_all_settings, pg_read_all_stats and
                // pg_stat_scan_tables (inherit and set, granted at initdb).
                if (current == bootstrap_role and group == role_pg_database_owner) return true;
                if (current == role_pg_monitor) {
                    for (monitor_members) |implied| if (implied == group) return true;
                }
                for (&self.items) |*o| {
                    if (o.kind != .member or o.grantee != current or !visible(o, snap)) continue;
                    if (path == .inherit and !self.membershipInherits(o, snap)) continue;
                    if (path == .set and !membershipCanSet(o)) continue;
                    if (o.target == group) return true;
                    var known = false;
                    for (queue[0..count]) |seen| known = known or seen == o.target;
                    if (!known and count < queue.len) {
                        queue[count] = o.target;
                        count += 1;
                    }
                }
                if (current == role_pg_monitor) for (monitor_members) |implied| {
                    var known = false;
                    for (queue[0..count]) |seen| known = known or seen == implied;
                    if (!known and count < queue.len) {
                        queue[count] = implied;
                        count += 1;
                    }
                };
            }
            return false;
        }

        /// A role holds `privileged` through membership (inherited) in a
        /// predefined role: pg_read_all_data (SELECT on every relation,
        /// USAGE on every schema), pg_write_all_data (INSERT, UPDATE,
        /// DELETE, USAGE on schemas) and pg_maintain (MAINTAIN).
        pub fn predefinedPrivileges(self: *const Self, role: u32, snap: storage.Snapshot) u32 {
            var held: u32 = 0;
            if (self.memberOf(role, role_pg_read_all_data, true, snap)) held |= priv_select | priv_usage;
            if (self.memberOf(role, role_pg_write_all_data, true, snap)) held |= priv_insert | priv_update | priv_delete | priv_usage;
            if (self.memberOf(role, role_pg_maintain, true, snap)) held |= priv_maintain;
            return held;
        }

        pub fn memberOf(self: *const Self, member: u32, group: u32, inherit: bool, snap: storage.Snapshot) bool {
            return self.membershipPath(member, group, if (inherit) .inherit else .any, snap);
        }

        /// The relation object of a table (owner, RLS flags), if any.
        pub fn relation(self: *const Self, table: u32, snap: storage.Snapshot) ?usize {
            const key: Object = .{ .kind = .relation, .target = table };
            return self.findKey(&key, snap);
        }

        pub fn owner(self: *const Self, table: u32, snap: storage.Snapshot) u32 {
            const index = self.relation(table, snap) orelse return bootstrap_role;
            return self.items[index].owner;
        }

        pub fn securityFlags(self: *const Self, table: u32, snap: storage.Snapshot) u32 {
            const index = self.relation(table, snap) orelse return 0;
            return self.items[index].flags;
        }

        /// Superuser, or has the owner's privileges.
        pub fn ownsTable(self: *const Self, role: u32, table: u32, snap: storage.Snapshot) bool {
            return self.superuser(role, snap) or self.memberOf(role, self.owner(table, snap), true, snap);
        }

        /// A private schema's implicit owner USAGE and explicit additions.
        /// The owner can revoke its ordinary privilege without losing the
        /// authority to grant it again.
        pub fn schemaUsage(self: *const Self, role: u32, namespace: u32, owner_role: u32, snap: storage.Snapshot) bool {
            return self.schemaPrivilegeMask(role, namespace, owner_role, snap) & priv_usage != 0;
        }

        /// The schema's ACL was materialized by a GRANT / REVOKE.
        pub fn schemaMaterialized(self: *const Self, namespace: u32, snap: storage.Snapshot) bool {
            const key: Object = .{ .kind = .schema_acl_state, .target = namespace };
            return self.findKey(&key, snap) != null;
        }

        /// USAGE / CREATE on a schema (the public schema grants PUBLIC
        /// USAGE until its ACL is materialized; pg_read_all_data and
        /// pg_write_all_data hold USAGE everywhere).
        pub fn schemaPrivilegeMask(self: *const Self, role: u32, namespace: u32, owner_role: u32, snap: storage.Snapshot) u32 {
            var held = self.objectPrivilegeMask(.schema_acl, namespace, owner_role, role, 0, snap);
            if (namespace == public_namespace and !self.schemaMaterialized(namespace, snap)) held |= priv_usage;
            return held | (self.predefinedPrivileges(role, snap) & priv_usage);
        }

        /// The owner's marker row of a grant kind on `target`, if any.
        pub fn ownerMarker(self: *const Self, kind: Kind, target: u32, owner_role: u32, snap: storage.Snapshot) ?usize {
            for (&self.items, 0..) |*o, index| {
                if (o.kind != kind or o.target != target or o.grantee != owner_role or o.sub != 0 or !visible(o, snap)) continue;
                if (o.grant_flags & acl_explicit_owner != 0) return index;
            }
            return null;
        }

        /// The owner's own privileges on an object: its marker row's, else
        /// every privilege of the kind (a legacy schema row without USAGE
        /// leaves CREATE).
        pub fn ownerPrivileges(self: *const Self, kind: Kind, target: u32, owner_role: u32, snap: storage.Snapshot) u32 {
            for (&self.items) |*o| {
                if (o.kind != kind or o.target != target or o.grantee != owner_role or o.sub != 0 or !visible(o, snap)) continue;
                if (o.grant_flags & acl_explicit_owner != 0) return o.flags;
                if (kind == .schema_acl and o.oid == 0 and o.flags == 0) return priv_schema_create;
            }
            return kindPrivileges(kind);
        }

        /// Whether a grant row is an ordinary grant (not the owner's marker
        /// row and not a legacy no-op grant from the owner to itself).
        pub fn grantEntry(o: *const Object, owner_role: u32) bool {
            if (o.grant_flags & acl_explicit_owner != 0) return false;
            return !(o.sub == 0 and o.grantee == owner_role);
        }

        /// Privileges `role` holds on an object through the rows of `kind`:
        /// the owner's own ones when it inherits the owner, and every grant
        /// to PUBLIC or to a role it inherits. `public_default` is PUBLIC's
        /// privilege while the ACL is not materialized (types: USAGE).
        pub fn objectPrivilegeMask(self: *const Self, kind: Kind, target: u32, owner_role: u32, role: u32, public_default: u32, snap: storage.Snapshot) u32 {
            if (self.superuser(role, snap)) return ~@as(u32, 0);
            var held: u32 = 0;
            if (self.memberOf(role, owner_role, true, snap)) held |= self.ownerPrivileges(kind, target, owner_role, snap);
            if (public_default != 0 and self.ownerMarker(kind, target, owner_role, snap) == null) held |= public_default;
            for (&self.items) |*o| {
                if (o.kind != kind or o.target != target or !visible(o, snap) or !grantEntry(o, owner_role)) continue;
                if (o.grantee == public_role or self.memberOf(role, o.grantee, true, snap)) held |= o.flags;
            }
            return held;
        }

        /// The privileges held on a relation: ownership, table-wide grants
        /// and the predefined data roles.
        pub fn tablePrivilegeMask(self: *const Self, role: u32, table: u32, snap: storage.Snapshot) u32 {
            const held = self.objectPrivilegeMask(.acl, table, self.owner(table, snap), role, 0, snap);
            return held | (self.predefinedPrivileges(role, snap) & table_privileges);
        }

        /// Column privileges of `role` on column `column` (0-based) from
        /// column grants alone (table-wide privileges apply separately).
        pub fn columnGrantMask(self: *const Self, role: u32, table: u32, column: usize, snap: storage.Snapshot) u32 {
            var held: u32 = 0;
            const super = self.superuser(role, snap);
            for (&self.items) |*o| {
                if (o.kind != .column_acl or o.target != table or !visible(o, snap)) continue;
                if (2 * column + 1 >= o.text_len) continue;
                if (super or o.grantee == public_role or self.memberOf(role, o.grantee, true, snap)) held |= columnFlags(o.text[2 * column] & 0x0f);
            }
            return held;
        }

        /// The privileges `role` holds on one column: table-wide ones plus
        /// the column's own grants.
        pub fn columnPrivilegeMask(self: *const Self, role: u32, table: u32, column: usize, snap: storage.Snapshot) u32 {
            return self.tablePrivilegeMask(role, table, snap) | self.columnGrantMask(role, table, column, snap);
        }

        /// Any column of the table (below `columns`) carries one of `wanted`
        /// through a column grant.
        pub fn anyColumnGrant(self: *const Self, role: u32, table: u32, columns: usize, wanted: u32, snap: storage.Snapshot) bool {
            for (0..columns) |column| {
                if (self.columnGrantMask(role, table, column, snap) & wanted != 0) return true;
            }
            return false;
        }

        /// Every requested privilege is required for statement access.
        pub fn tablePrivileges(self: *const Self, role: u32, table: u32, wanted: u32, snap: storage.Snapshot) bool {
            return self.tablePrivilegeMask(role, table, snap) & wanted == wanted;
        }

        /// Any requested privilege suffices for information-schema discovery.
        pub fn tableHasAnyPrivilege(self: *const Self, role: u32, table: u32, wanted: u32, snap: storage.Snapshot) bool {
            return self.tablePrivilegeMask(role, table, snap) & wanted != 0;
        }

        /// Row security applies to `role` reading or writing `table`
        /// (check_enable_rls): enabled, and the role is no superuser, has no
        /// BYPASSRLS and is not the owner unless FORCE is set.
        pub fn rowSecurity(self: *const Self, role: u32, table: u32, snap: storage.Snapshot) bool {
            const flags = self.securityFlags(table, snap);
            if (flags & rls_enabled == 0) return false;
            const attributes = self.roleFlags(role, snap) orelse 0;
            if (attributes & (role_superuser | role_bypassrls) != 0) return false;
            if (flags & rls_forced == 0 and self.memberOf(role, self.owner(table, snap), true, snap)) return false;
            return true;
        }

        fn policyApplies(self: *const Self, o: *const Object, role: u32, command: Command, snap: storage.Snapshot) bool {
            const policy_command: Command = @enumFromInt(@as(u8, @truncate(o.flags)));
            if (policy_command != .all and policy_command != command) return false;
            for (o.roleList()) |listed| {
                if (listed == public_role or self.memberOf(role, listed, true, snap)) return true;
            }
            return false;
        }

        /// Appends the combined row-security expression for `command` on
        /// `table` (rowsecurity.c): the permissive expressions OR-ed (none:
        /// `false`), AND-ed with every restrictive one. `check` selects the
        /// WITH CHECK expressions (falling back to USING), else USING.
        pub fn securityText(self: *const Self, role: u32, table: u32, command: Command, check: bool, snap: storage.Snapshot, out: []u8, length: *usize) Error!void {
            var text: Appender = .{ .out = out, .len = length };
            try text.add("((");
            var permissive: usize = 0;
            for (&self.items) |*o| {
                if (o.kind != .policy or o.target != table or o.flags & policy_permissive == 0 or !visible(o, snap)) continue;
                if (!self.policyApplies(o, role, command, snap)) continue;
                const expression = policyExpression(o, check) orelse continue;
                if (permissive != 0) try text.add(") OR (");
                try text.add(expression);
                permissive += 1;
            }
            if (permissive == 0) try text.add("false");
            try text.add("))");
            for (&self.items) |*o| {
                if (o.kind != .policy or o.target != table or o.flags & policy_permissive != 0 or !visible(o, snap)) continue;
                if (!self.policyApplies(o, role, command, snap)) continue;
                const expression = policyExpression(o, check) orelse continue;
                try text.add(" AND (");
                try text.add(expression);
                try text.add(")");
            }
        }

        fn policyExpression(o: *const Object, check: bool) ?[]const u8 {
            if (check and o.flags & policy_check != 0) return o.checkText();
            if (o.flags & policy_using != 0) return o.usingText();
            return null;
        }

        /// The comment on (classoid, object, sub); classoid 0 matches any
        /// catalog (obj_description(oid)).
        pub fn description(self: *const Self, object: u32, classoid: u32, sub: i32, snap: storage.Snapshot) ?[]const u8 {
            for (&self.items) |*o| {
                if (o.kind != .comment or o.target != object or o.sub != sub or !visible(o, snap)) continue;
                if (classoid != 0 and o.grantee != classoid) continue;
                // Role comments are shared (pg_shdescription).
                if (classoid == 0 and o.grantee == class_authid) continue;
                return o.textSlice();
            }
            return null;
        }

        // ---- change records (ops 70 / 71) ------------------------------

        pub fn encodeCreate(writer: anytype, o: *const Object) Error!void {
            try writer.int(u8, @intFromEnum(o.kind));
            try writer.int(u32, o.oid);
            try writer.int(u32, o.target);
            try writer.int(u32, o.grantee);
            try writer.int(i32, o.sub);
            try writer.int(u32, o.owner);
            try writer.int(u32, o.flags);
            try writer.int(u32, o.grant_flags);
            try writer.name(o.name.slice());
            try writer.int(u8, o.role_count);
            for (o.roleList()) |role| try writer.int(u32, role);
            try writer.int(u16, o.text_len);
            try writer.bytes(o.textSlice());
            try writer.int(u16, o.split);
            if (o.kind == .domain) {
                try writer.int(u8, 1);
                try writer.int(u8, @intFromEnum(o.domain.base));
                try writer.int(u8, @intFromBool(o.domain.not_null));
                try writer.int(u8, @intFromEnum(o.domain.comparison));
                try writer.int(i64, o.domain.bound);
            } else if (o.kind == .enum_type) {
                try writer.int(u8, 1);
                try writer.int(u16, o.enum_label_count);
            } else if (o.kind == .composite_type) {
                try writer.int(u8, 1);
                try writer.int(u16, o.composite_field_count);
            }
        }

        pub fn encodeDrop(writer: anytype, o: *const Object) Error!void {
            try writer.int(u8, @intFromEnum(o.kind));
            try writer.int(u32, o.oid);
            try writer.int(u32, o.target);
            try writer.int(u32, o.grantee);
            try writer.int(i32, o.sub);
        }

        fn decodeKind(cursor: Cursor) Error!Kind {
            const raw = try cursor.int(u8);
            const known = (raw >= 1 and raw <= @intFromEnum(Kind.routine_default_acl)) or (raw >= first_lane_kind and raw <= last_lane_kind);
            if (!known) return error.InvalidChangeRecord;
            return @enumFromInt(raw);
        }

        /// A key-only object (op 71); unused key fields must be zero.
        pub fn decodeDrop(bytes: []const u8, position: *usize) Error!Object {
            const cursor: Cursor = .{ .bytes = bytes, .position = position };
            var o: Object = .{ .kind = try decodeKind(cursor) };
            o.oid = try cursor.int(u32);
            o.target = try cursor.int(u32);
            o.grantee = try cursor.int(u32);
            o.sub = try cursor.int(i32);
            try checkKey(&o);
            return o;
        }

        fn checkKey(o: *const Object) Error!void {
            const ok = switch (o.kind) {
                .role, .fdw, .publication => o.oid != 0 and o.target == 0 and o.grantee == 0 and o.sub == 0,
                .policy, .server => o.oid != 0 and o.grantee == 0 and o.sub == 0,
                .domain, .enum_type, .composite_type => o.oid != 0 and o.target != 0 and o.grantee == 0 and o.sub == 0,
                .statistics => o.oid != 0 and o.target != 0 and o.grantee != 0 and o.sub >= -1 and o.sub <= 10000,
                .publication_table, .publication_schema => o.oid != 0 and o.target != 0 and o.grantee != 0 and o.sub == 0,
                // Memberships and grant rows: sub 0 (owner / bootstrap /
                // legacy grantor) or the grantor's OID. Grant rows carry
                // their ACL position in `oid` (0 on legacy rows).
                .member => o.oid != 0 and o.target != 0 and o.grantee != 0,
                .acl, .schema_acl, .column_acl, .type_acl, .sequence_acl => o.target != 0,
                // Legacy owner-issued grants keep sub = 0. Delegated grants
                // put their grantor OID in that key field, including in drops.
                .large_object_acl => o.oid == 0 and o.target != 0,
                .builtin_routine_acl => o.oid == 0 and restrictedRoutine(o.target),
                .large_object_default_acl, .routine_default_acl => o.target != 0 and (o.kind == .routine_default_acl or o.sub == 0) and
                    ((o.oid != 0) == (o.target == o.grantee)),
                .relation, .schema_acl_state, .schema_owner, .role_settings, .large_object => o.oid == 0 and o.target != 0 and o.grantee == 0 and o.sub == 0,
                .comment => o.oid == 0 and o.target != 0 and o.sub >= 0 and switch (o.grantee) {
                    class_relation => true,
                    class_namespace, class_authid, class_fdw, class_server, class_publication, class_policy, class_large_object => o.sub == 0,
                    else => false,
                },
                _ => false,
            };
            if (!ok) return error.InvalidChangeRecord;
        }

        /// A whole version (op 70), validated field by field.
        pub fn decodeCreate(bytes: []const u8, position: *usize) Error!Object {
            const cursor: Cursor = .{ .bytes = bytes, .position = position };
            var o: Object = .{ .kind = try decodeKind(cursor) };
            o.oid = try cursor.int(u32);
            o.target = try cursor.int(u32);
            o.grantee = try cursor.int(u32);
            o.sub = try cursor.int(i32);
            o.owner = try cursor.int(u32);
            o.flags = try cursor.int(u32);
            o.grant_flags = try cursor.int(u32);
            try checkKey(&o);
            const name_len = try cursor.int(u8);
            if (name_len > config.name_bytes) return error.InvalidChangeRecord;
            const name_bytes = try cursor.take(name_len);
            for (name_bytes) |byte| if (byte == 0) return error.InvalidChangeRecord;
            o.name = .{ .len = name_len };
            @memcpy(o.name.bytes[0..name_len], name_bytes);
            const role_count = try cursor.int(u8);
            if (role_count > role_capacity) return error.InvalidChangeRecord;
            o.role_count = role_count;
            for (0..role_count) |index| o.roles[index] = try cursor.int(u32);
            const text_len = try cursor.int(u16);
            if (text_len > text_capacity) return error.InvalidChangeRecord;
            @memcpy(o.text[0..text_len], try cursor.take(text_len));
            o.text_len = text_len;
            o.split = try cursor.int(u16);
            if (o.split > o.text_len) return error.InvalidChangeRecord;
            const has_name = name_len != 0;
            const using_ok = if (o.flags & policy_using != 0) o.split != 0 else o.split == 0;
            const check_ok = if (o.flags & policy_check != 0) o.split != o.text_len else o.split == o.text_len;
            const valid = switch (o.kind) {
                .role => has_name and o.owner == 0 and o.flags & ~role_attributes == 0 and o.role_count == 0 and o.text_len == 0,
                .member => !has_name and o.owner != 0 and
                    (o.flags == 0 or (o.flags & member_configured != 0 and o.flags & ~(member_configured | member_inherit | member_set) == 0)) and
                    o.grant_flags <= member_admin and o.role_count == 0 and o.text_len == 0 and o.target != o.grantee and
                    (o.sub == 0 or o.owner == @as(u32, @bitCast(o.sub))),
                // Legacy table grants (sub 0, ordinal 0) keep their old rule.
                .acl => !has_name and o.role_count == 0 and o.text_len == 0 and o.owner != 0 and
                    ((o.sub == 0 and o.oid == 0 and o.flags != 0 and o.flags & ~table_privileges == 0 and o.grant_flags & ~o.flags == 0) or
                    grantRowValid(&o, table_privileges)),
                .sequence_acl, .type_acl => !has_name and o.role_count == 0 and o.text_len == 0 and o.owner != 0 and
                    grantRowValid(&o, kindPrivileges(o.kind)),
                .column_acl => !has_name and o.role_count == 0 and o.owner != 0 and o.split == 0 and
                    (o.sub == 0 or o.owner == @as(u32, @bitCast(o.sub))) and columnRowValid(&o),
                .large_object => !has_name and o.owner != 0 and o.role_count == 0 and
                    (o.text_len == 0 or (o.text_len == 8 and o.largeObjectLength() != 0 and o.largeObjectLength() <= @import("large_object_pages.sig").max_size)) and o.split == 0 and
                    o.grant_flags & ~(large_object_generated_oid | large_object_privileges) == 0 and
                    (o.grant_flags & large_object_generated_oid == 0 or (o.target >= first_oid and o.target < 0xffff_ffff)) and
                    o.grant_flags & large_object_privileges & ~o.flags == 0 and
                    (o.flags == 0 or (o.flags & large_object_explicit_acl != 0 and o.flags & ~(large_object_explicit_acl | large_object_privileges) == 0)),
                .large_object_acl => !has_name and o.owner != 0 and o.role_count == 0 and o.text_len == 0 and
                    (o.sub == 0 or o.owner == @as(u32, @bitCast(o.sub))) and
                    o.flags != 0 and o.flags & ~large_object_privileges == 0 and (o.owner != o.grantee or (o.sub != 0 and o.grant_flags == 0)) and
                    o.grant_flags & ~o.flags == 0 and (o.grantee != public_role or o.grant_flags == 0),
                .large_object_default_acl => !has_name and o.owner == o.target and o.role_count == 0 and
                    o.text_len == 0 and o.split == 0 and (o.oid != 0 or o.flags != 0) and
                    o.flags & ~large_object_privileges == 0 and o.grant_flags & ~o.flags == 0 and
                    (o.grantee != public_role or o.grant_flags == 0),
                .routine_default_acl => !has_name and o.owner == o.target and o.role_count == 0 and
                    o.text_len == 0 and o.split == 0 and o.grantee != public_role and
                    (o.oid != 0 or o.flags != 0) and
                    o.flags & ~(priv_execute | (if (o.oid != 0) routine_default_public else @as(u32, 0))) == 0 and
                    o.grant_flags & ~priv_execute == 0 and o.grant_flags & ~o.flags == 0,
                .builtin_routine_acl => !has_name and o.owner != 0 and o.role_count == 0 and o.text_len == 0 and o.split == 0 and
                    o.sub == (if (o.owner == bootstrap_role) @as(i32, 0) else @as(i32, @bitCast(o.owner))) and
                    (o.flags != 0 or (o.owner == bootstrap_role and o.grantee == bootstrap_role)) and
                    o.flags & ~priv_execute == 0 and o.grant_flags & ~o.flags == 0 and
                    (o.grantee != public_role or o.grant_flags == 0),
                // Legacy schema rows: USAGE grants, or the owner without its
                // USAGE (flags 0, no marker: the owner keeps CREATE).
                .schema_acl => !has_name and o.owner != 0 and o.role_count == 0 and o.text_len == 0 and
                    ((o.sub == 0 and o.oid == 0 and o.grant_flags == 0 and (o.flags == priv_schema_usage or (o.flags == 0 and o.grantee == o.owner))) or
                    grantRowValid(&o, schema_privileges)),
                .schema_acl_state, .schema_owner => !has_name and o.owner != 0 and o.flags == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len == 0,
                .role_settings => !has_name and o.owner == 0 and o.flags != 0 and o.flags & ~role_boolean_mask == 0 and
                    o.grant_flags & ~o.flags == 0 and o.role_count == 0 and o.text_len == 0,
                .relation => !has_name and o.flags & ~(rls_enabled | rls_forced) == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len == 0 and o.owner != 0,
                .policy => has_name and o.flags & ~@as(u32, 0x7ff) == 0 and (o.flags & 0xff) <= 4 and o.grant_flags == 0 and o.role_count != 0 and o.owner == 0 and using_ok and check_ok,
                .comment => !has_name and o.owner == 0 and o.flags == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len != 0 and o.split == 0,
                .fdw => has_name and o.flags == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len == 0 and o.owner != 0,
                .server => has_name and o.target != 0 and o.flags & ~(server_type | server_version) == 0 and o.grant_flags == 0 and o.role_count == 0 and o.owner != 0 and
                    (o.flags & server_type != 0 or o.split == 0) and (o.flags & server_version != 0 or o.split == o.text_len),
                .publication => has_name and o.flags & ~@as(u32, 63) == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len == 0 and o.owner != 0,
                .statistics => has_name and o.flags != 0 and o.flags & ~all_statistics_kinds == 0 and o.grant_flags == 0 and o.role_count == 0 and
                    o.owner != 0 and o.split == o.text_len and o.text_len >= 2 and o.text_len <= statistics_columns,
                .publication_table, .publication_schema => !has_name and o.owner == 0 and o.flags == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len == 0,
                .domain => has_name and o.owner != 0 and o.flags == 0 and o.grant_flags == 0 and o.role_count == 0 and o.split == 0 and
                    o.text_len != 0 and o.text_len <= config.name_bytes and o.text[0] == '_' and !types.same(o.name.slice(), o.textSlice()),
                .enum_type, .composite_type => has_name and o.owner != 0 and o.flags == 0 and o.grant_flags == 0 and o.role_count == 0 and
                    o.split != 0 and o.split <= config.name_bytes and o.text[0] == '_' and !types.same(o.name.slice(), o.arrayName()),
                _ => false,
            };
            if (!valid) return error.InvalidChangeRecord;
            if (o.kind == .domain) {
                for (o.textSlice()) |byte| if (byte == 0) return error.InvalidChangeRecord;
                if (try cursor.int(u8) != 1) return error.UnsupportedLogVersion;
                const base: types.Type = @enumFromInt(try cursor.int(u8));
                const not_null = try cursor.int(u8);
                const comparison = try cursor.int(u8);
                const bound = try cursor.int(i64);
                if (!domainBase(base) or not_null > 1 or comparison > 6 or (comparison == 0 and bound != 0)) return error.InvalidChangeRecord;
                o.domain = .{ .base = base, .not_null = not_null != 0, .comparison = @enumFromInt(comparison), .bound = bound };
            } else if (o.kind == .enum_type) {
                for (o.arrayName()) |byte| if (byte == 0) return error.InvalidChangeRecord;
                if (try cursor.int(u8) != 1) return error.UnsupportedLogVersion;
                o.enum_label_count = try cursor.int(u16);
                try validateEnumLabels(o.text[o.split..o.text_len], o.enum_label_count);
            } else if (o.kind == .composite_type) {
                for (o.arrayName()) |byte| if (byte == 0) return error.InvalidChangeRecord;
                if (try cursor.int(u8) != 1) return error.UnsupportedLogVersion;
                o.composite_field_count = try cursor.int(u16);
                try validateCompositeFields(o.text[o.split..o.text_len], o.composite_field_count);
            } else if (o.kind == .statistics) {
                for (o.textSlice()[1..], o.textSlice()[0..o.text_len - 1]) |next, prior| {
                    if (next <= prior) return error.InvalidChangeRecord;
                }
            }
            return o;
        }

        /// A grant row of privilege set `all` (privileges lane): the owner's
        /// marker row (sub 0, grantee = owner, flags its explicit privileges
        /// and options, `oid` its ACL position), or a grant with nonzero privileges,
        /// options within them, PUBLIC without options, a grantor key that
        /// matches `owner` when delegated, and a nonzero ACL position.
        fn grantRowValid(o: *const Object, all: u32) bool {
            if (o.split != 0) return false;
            if (o.grant_flags & acl_explicit_owner != 0)
                return o.sub == 0 and o.grantee == o.owner and o.flags & ~all == 0 and (o.grant_flags & ~acl_explicit_owner) & ~o.flags == 0;
            return o.oid != 0 and o.flags != 0 and o.flags & ~all == 0 and o.grant_flags & ~o.flags == 0 and
                (o.sub == 0 or o.owner == @as(u32, @bitCast(o.sub))) and !(o.sub == 0 and o.grantee == o.owner) and
                (o.grantee != public_role or o.grant_flags == 0);
        }

        /// Column grant bytes: per column a privilege / option byte and its
        /// ACL position (both zero for a column without privileges); the
        /// row's flags and grant_flags are their unions.
        fn columnRowValid(o: *const Object) bool {
            if (o.oid != 0 or o.text_len < 2 or o.text_len % 2 != 0) return false;
            var flags: u32 = 0;
            var options: u32 = 0;
            var index: usize = 0;
            while (index + 1 < o.text_len) : (index += 2) {
                const bits = o.text[index];
                const privileges = bits & 0x0f;
                const granted = bits >> 4;
                if ((privileges == 0) != (o.text[index + 1] == 0) or granted & ~privileges != 0) return false;
                flags |= columnFlags(privileges);
                options |= columnFlags(granted);
            }
            if (o.text[o.text_len - 2] == 0) return false;
            return flags != 0 and flags == o.flags and options == o.grant_flags and (o.grantee != public_role or options == 0);
        }

        fn validateEnumLabels(bytes: []const u8, expected: u16) Error!void {
            var offset: usize = 0;
            var count: usize = 0;
            while (offset < bytes.len) {
                const length: usize = bytes[offset];
                if (length > bytes.len - offset - 1 or length > enum_label_bytes or
                    length > config.name_bytes or length > config.text_bytes) return error.InvalidChangeRecord;
                const label = bytes[offset + 1 ..][0..length];
                for (label) |byte| if (byte == 0) return error.InvalidChangeRecord;
                var earlier: EnumLabels = .{ .bytes = bytes[0..offset] };
                while (earlier.next()) |prior| if (types.same(prior, label)) return error.InvalidChangeRecord;
                offset += length + 1;
                count += 1;
            }
            if (count != expected) return error.InvalidChangeRecord;
        }

        fn validateCompositeFields(bytes: []const u8, expected: u16) Error!void {
            if (expected > config.columns) return error.ChangeRecordConflict;
            var fields: CompositeFields = .{ .bytes = bytes };
            var count: usize = 0;
            while (fields.bytes.len != 0) {
                const name_len: usize = fields.bytes[0];
                if (name_len == 0 or name_len > config.name_bytes or name_len > config.text_bytes or
                    name_len + composite_field_header > fields.bytes.len) return error.InvalidChangeRecord;
                const offset = bytes.len - fields.bytes.len;
                const field = fields.next().?;
                const data_type = types.typeFromOid(field.oid) orelse return error.InvalidChangeRecord;
                if (data_type == .record) return error.InvalidChangeRecord;
                if (!types.validTypeTypmod(config, data_type, field.typmod)) return error.InvalidChangeRecord;
                for (field.name) |byte| if (byte == 0) return error.InvalidChangeRecord;
                var earlier: CompositeFields = .{ .bytes = bytes[0..offset] };
                while (earlier.next()) |prior| if (types.same(prior.name, field.name)) return error.InvalidChangeRecord;
                count += 1;
            }
            if (count != expected) return error.InvalidChangeRecord;
        }

        /// Replay of op 70: the first free entry (validation reserved it).
        pub fn applyCreate(self: *Self, value: *const Object, epoch: u32, cid: u32, csn: u64) void {
            for (&self.items, 0..) |*o, index| if (!o.used) {
                self.insert(index, value, .{ .epoch = epoch }, cid, csn);
                return;
            };
        }

        /// Replay of op 71: the committed version is freed at once (replay
        /// has no snapshots, as for tables).
        pub fn applyDrop(self: *Self, key: *const Object) void {
            for (&self.items) |*o| if (o.used and o.xmin_csn != 0 and o.xmax.epoch == 0 and sameKey(o, key)) {
                o.* = .{};
                return;
            };
        }

        /// The validation overlay: one entry per store entry, mirroring
        /// exactly what apply will do (creates take the first free entry,
        /// drops free theirs), so a validated record applies infallibly.
        pub const VObject = struct {
            used: bool = false,
            live: bool = false,
            kind: Kind = .role,
            oid: u32 = 0,
            target: u32 = 0,
            grantee: u32 = 0,
            sub: i32 = 0,
            owner: u32 = 0,
            publication_all_tables: bool = false,
            large_object_explicit_acl: bool = false,
            large_object_length: u64 = 0,
            acl_flags: u32 = 0,
            acl_options: u32 = 0,
            roles: [role_capacity]u32 = @splat(0),
            role_count: u8 = 0,
            name: V.Name = .{},
            array_name: V.Name = .{},
            oid_width: u32 = 0,
            last_statistics_column: u8 = 0,
            /// Columns a column_acl row covers (privileges lane).
            acl_columns: u16 = 0,
        };

        pub const Overlay = struct {
            items: [capacity]VObject = @splat(.{}),

            fn project(o: *const Object, live: bool) VObject {
                var out: VObject = .{ .used = o.used, .live = live, .kind = o.kind, .oid = o.oid, .target = o.target, .grantee = o.grantee, .sub = o.sub, .owner = o.owner, .roles = o.roles, .role_count = o.role_count, .name = o.name };
                out.oid_width = o.oidWidth();
                out.publication_all_tables = o.kind == .publication and o.flags & pub_all_tables != 0;
                out.large_object_explicit_acl = o.kind == .large_object and o.flags & large_object_explicit_acl != 0;
                if (o.kind == .large_object) out.large_object_length = o.largeObjectLength();
                if (o.kind == .large_object_acl or o.kind == .builtin_routine_acl) {
                    out.acl_flags = o.flags;
                    out.acl_options = o.grant_flags;
                }
                if (o.kind == .statistics) out.last_statistics_column = o.text[o.text_len - 1];
                if (o.kind == .column_acl) out.acl_columns = o.text_len / 2;
                if (userType(o.kind)) {
                    const name = o.arrayName();
                    out.array_name.len = name.len;
                    @memcpy(out.array_name.bytes[0..name.len], name);
                }
                return out;
            }

            /// A replayable entry is committed and never marked: apply only
            /// drops those (anything else stays used).
            pub fn init(self: *Overlay, store: *const Self) void {
                for (&self.items, &store.items) |*v, *o| {
                    const live = o.used and o.xmin_csn != 0 and o.xmax.epoch == 0;
                    v.* = project(o, live);
                }
            }

            fn asObject(v: *const VObject) Object {
                return .{ .kind = v.kind, .oid = v.oid, .target = v.target, .grantee = v.grantee, .sub = v.sub };
            }

            /// Any entry (also uncommitted or dead) owning an OID in [oid, oid + width).
            pub fn oidTaken(self: *const Overlay, oid: u32, width: u32) bool {
                for (&self.items) |*v| {
                    if (!v.used or v.oid_width == 0) continue;
                    if (@as(u64, v.oid) < @as(u64, oid) + width and @as(u64, oid) < @as(u64, v.oid) + v.oid_width) return true;
                }
                return false;
            }

            pub fn largeObjectLength(self: *const Overlay, oid: u32) ?u64 {
                for (&self.items) |*item| {
                    if (item.live and item.kind == .large_object and item.target == oid) return item.large_object_length;
                }
                return null;
            }

            pub fn roleExists(self: *const Overlay, oid: u32) bool {
                if (oid == bootstrap_role or predefinedRole(oid)) return true;
                return self.liveOid(.role, oid);
            }

            fn typeLive(self: *const Overlay, oid: u32) bool {
                return self.liveOid(.domain, oid) or self.liveOid(.enum_type, oid) or self.liveOid(.composite_type, oid);
            }

            pub fn userTypeNameTaken(self: *const Overlay, namespace: u32, name: []const u8) bool {
                for (&self.items) |*v| if (v.live and userType(v.kind) and v.target == namespace) {
                    if (types.same(v.name.slice(), name) or types.same(v.array_name.slice(), name)) return true;
                };
                return false;
            }

            pub fn compositeRelationNameTaken(self: *const Overlay, namespace: u32, name: []const u8) bool {
                for (&self.items) |*v| if (v.live and v.kind == .composite_type and v.target == namespace and types.same(v.name.slice(), name)) return true;
                return false;
            }

            fn liveOid(self: *const Overlay, kind: Kind, oid: u32) bool {
                for (&self.items) |*v| if (v.live and v.kind == kind and v.oid == oid) return true;
                return false;
            }

            /// A live composite type (B11 wave 5: composite table columns).
            pub fn compositeLive(self: *const Overlay, oid: u32) bool {
                return self.liveOid(.composite_type, oid);
            }

            /// Op 70 against the overlay. `ctx` answers objectTableLive,
            /// objectTableColumns, objectSequenceLive, objectSchemaLive and
            /// objectOidTaken for the record so far, and notes allocated OIDs
            /// (noteObjectOid).
            pub fn create(self: *Overlay, o: *const Object, ctx: anytype) Error!void {
                const width = o.oidWidth();
                if (width != 0) {
                    if (o.oid < first_oid or o.oid > 0xffffffff - width or ctx.objectOidTaken(o.oid, width)) return error.ChangeRecordConflict;
                }
                if (userType(o.kind) and (self.userTypeNameTaken(o.target, o.name.slice()) or self.userTypeNameTaken(o.target, o.arrayName()) or
                    ctx.objectRelationNameTaken(o.target, o.name.slice()) or ctx.objectRelationNameTaken(o.target, o.arrayName()))) return error.ChangeRecordConflict;
                if (o.kind == .composite_type and ctx.objectSequenceNameTaken(o.target, o.name.slice())) return error.ChangeRecordConflict;
                for (&self.items) |*v| {
                    if (!v.live) continue;
                    const existing = asObject(v);
                    if (sameKey(&existing, o)) return error.ChangeRecordConflict;
                    if (publicationMembership(o.kind) and v.kind == o.kind and v.target == o.target and v.grantee == o.grantee) return error.ChangeRecordConflict;
                    if (!userType(o.kind) and named(o.kind) and v.kind == o.kind and (!scoped(o.kind) or v.target == o.target) and
                        types.same(v.name.slice(), o.name.slice())) return error.ChangeRecordConflict;
                }
                if (o.kind == .role and (types.same(o.name.slice(), bootstrap_name) or reservedRoleName(o.name.slice()))) return error.ChangeRecordConflict;
                const projected = project(o, true);
                try self.references(&projected, ctx);
                for (&self.items) |*v| if (!v.used) {
                    v.* = projected;
                    // A decoded version is not yet an entry: mark it taken.
                    v.used = true;
                    if (width != 0) ctx.noteObjectOid(o.oid + width - 1);
                    if (o.kind == .large_object and o.grant_flags & large_object_generated_oid != 0) ctx.noteObjectOid(o.target);
                    return;
                };
                return error.ChangeRecordConflict;
            }

            /// Op 71: the live version with this identity.
            pub fn drop(self: *Overlay, key: *const Object) Error!void {
                for (&self.items) |*v| {
                    if (!v.live) continue;
                    const existing = asObject(v);
                    if (!sameKey(&existing, key)) continue;
                    if (defaultAcl(v.kind) and v.oid != key.oid) return error.ChangeRecordConflict;
                    v.* = .{};
                    return;
                }
                return error.ChangeRecordConflict;
            }

            pub fn schemaOwner(self: *const Overlay, target: u32, original: u32) u32 {
                for (&self.items) |*v| {
                    if (v.live and v.kind == .schema_owner and v.target == target) return v.owner;
                }
                return original;
            }

            fn references(self: *const Overlay, v: *const VObject, ctx: anytype) Error!void {
                const target = v.target;
                const grantee = v.grantee;
                if (v.owner != 0 and !self.roleExists(v.owner)) return error.ChangeRecordConflict;
                switch (v.kind) {
                    .statistics => {
                        const columns = ctx.objectTableColumns(grantee) orelse return error.ChangeRecordConflict;
                        if (v.last_statistics_column >= columns or !ctx.objectSchemaLive(target)) return error.ChangeRecordConflict;
                    },
                    .publication_table => {
                        if (!self.explicitPublication(target) or !ctx.objectTablePublishable(grantee)) return error.ChangeRecordConflict;
                    },
                    .publication_schema => {
                        if (!self.explicitPublication(target) or (grantee != 2200 and grantee < first_oid) or !ctx.objectSchemaLive(grantee)) return error.ChangeRecordConflict;
                    },
                    .member => {
                        const group_live = self.roleExists(target);
                        const member_live = self.roleExists(grantee);
                        if (!group_live) return error.ChangeRecordConflict;
                        if (!member_live) return error.ChangeRecordConflict;
                    },
                    .acl => {
                        const table_live = ctx.objectTableLive(target);
                        if (!table_live) return error.ChangeRecordConflict;
                        if (grantee != public_role) {
                            if (!self.roleExists(grantee)) return error.ChangeRecordConflict;
                        }
                    },
                    .large_object_acl => {
                        var object_owner: ?u32 = null;
                        for (&self.items) |*entry| {
                            if (entry.live and entry.kind == .large_object and entry.target == target and entry.large_object_explicit_acl) {
                                object_owner = entry.owner;
                                break;
                            }
                        }
                        const large_owner = object_owner orelse return error.ChangeRecordConflict;
                        if ((v.sub == 0) != (large_owner == v.owner) or
                            (grantee != public_role and !self.roleExists(grantee))) return error.ChangeRecordConflict;
                    },
                    .large_object_default_acl, .routine_default_acl => {
                        if (grantee != public_role and !self.roleExists(grantee)) return error.ChangeRecordConflict;
                        if (v.kind == .routine_default_acl and v.sub != 0 and !ctx.objectSchemaLive(@as(u32, @bitCast(v.sub)))) return error.ChangeRecordConflict;
                        if (v.oid == 0) {
                            for (&self.items) |*entry| {
                                if (entry.live and entry.kind == v.kind and
                                    entry.target == target and entry.sub == v.sub and entry.oid != 0) break;
                            } else return error.ChangeRecordConflict;
                        }
                    },
                    .builtin_routine_acl => {
                        if (grantee != public_role and !self.roleExists(grantee)) return error.ChangeRecordConflict;
                    },
                    .schema_acl => {
                        // The public schema (owned by pg_database_owner)
                        // carries grants since the privileges lane.
                        const original = if (target == public_namespace) role_pg_database_owner else ctx.objectPrivateSchemaOwner(target) orelse return error.ChangeRecordConflict;
                        if (v.sub == 0 and self.schemaOwner(target, original) != v.owner) return error.ChangeRecordConflict;
                        if (grantee != public_role and !self.roleExists(grantee)) return error.ChangeRecordConflict;
                    },
                    .schema_acl_state => {
                        const original = if (target == public_namespace) role_pg_database_owner else ctx.objectPrivateSchemaOwner(target) orelse return error.ChangeRecordConflict;
                        if (self.schemaOwner(target, original) != v.owner) return error.ChangeRecordConflict;
                    },
                    .column_acl => {
                        const columns = ctx.objectTableColumns(target) orelse return error.ChangeRecordConflict;
                        if (v.acl_columns > columns) return error.ChangeRecordConflict;
                        if (grantee != public_role and !self.roleExists(grantee)) return error.ChangeRecordConflict;
                    },
                    .type_acl => {
                        if (!self.typeLive(target)) return error.ChangeRecordConflict;
                        if (grantee != public_role and !self.roleExists(grantee)) return error.ChangeRecordConflict;
                    },
                    .sequence_acl => {
                        if (!ctx.objectSequenceLive(target)) return error.ChangeRecordConflict;
                        if (grantee != public_role and !self.roleExists(grantee)) return error.ChangeRecordConflict;
                    },
                    .schema_owner => if (ctx.objectPrivateSchemaOwner(target) == null) return error.ChangeRecordConflict,
                    .role_settings => if (!self.roleExists(target)) return error.ChangeRecordConflict,
                    .relation => {
                        if (!ctx.objectTableLive(target)) return error.ChangeRecordConflict;
                    },
                    .policy => {
                        if (!ctx.objectTableLive(target)) return error.ChangeRecordConflict;
                        for (v.roles[0..v.role_count]) |role| {
                            if (role == public_role) continue;
                            if (!self.roleExists(role)) return error.ChangeRecordConflict;
                        }
                    },
                    .server => {
                        if (!self.liveOid(.fdw, target)) return error.ChangeRecordConflict;
                    },
                    .domain, .enum_type, .composite_type => {
                        if ((target != 2200 and target < first_oid) or !ctx.objectSchemaLive(target)) return error.ChangeRecordConflict;
                    },
                    .comment => {
                        const exists = switch (grantee) {
                            class_relation => if (ctx.objectTableColumns(target)) |columns| v.sub <= columns else v.sub == 0 and ctx.objectSequenceLive(target),
                            class_namespace => ctx.objectSchemaLive(target),
                            class_authid => self.roleExists(target),
                            class_fdw => self.liveOid(.fdw, target),
                            class_server => self.liveOid(.server, target),
                            class_publication => self.liveOid(.publication, target),
                            class_policy => self.liveOid(.policy, target),
                            class_large_object => blk: {
                                for (&self.items) |*entry| {
                                    if (entry.live and entry.kind == .large_object and entry.target == target) break :blk true;
                                }
                                break :blk false;
                            },
                            else => false,
                        };
                        if (!exists) return error.ChangeRecordConflict;
                    },
                    else => {},
                }
            }

            fn explicitPublication(self: *const Overlay, oid: u32) bool {
                for (&self.items) |*v| {
                    if (v.live and v.kind == .publication and v.oid == oid) return !v.publication_all_tables;
                }
                return false;
            }

            /// After the whole record: every live object still names live
            /// tables, roles and objects (a DROP drops its dependents in
            /// the same record).
            pub fn finish(self: *const Overlay, ctx: anytype) Error!void {
                for (&self.items) |*v| {
                    if (!v.live) continue;
                    try self.references(v, ctx);
                }
            }

            /// A frame or sealed base image must leave every delegated grant
            /// supported by an unbroken grant-option path from the owner.
            pub fn verifyLargeObjectGrants(self: *const Overlay) Error!void {
                const acl = @import("privilege_graph.sig");
                for (&self.items, 0..) |*entry, index| {
                    if (!entry.live or (entry.kind != .large_object_acl and entry.kind != .builtin_routine_acl) or entry.sub == 0) continue;
                    for (self.items[0..index]) |*prior| {
                        if (prior.live and prior.kind == entry.kind and prior.sub != 0 and prior.target == entry.target) break;
                    } else {
                        var edges: [capacity]acl.Edge = undefined;
                        var support: [capacity]acl.Graph.State = undefined;
                        var graph: acl.Graph = .{ .edges = &edges, .owner = 0, .privileges = large_object_privileges };
                        if (entry.kind == .builtin_routine_acl) {
                            graph.owner = bootstrap_role;
                            graph.privileges = priv_execute;
                        }
                        for (&self.items) |*item| {
                            if (!item.live or item.target != entry.target) continue;
                            if (entry.kind == .large_object_acl and item.kind == .large_object) graph.owner = item.owner;
                            if (item.kind == entry.kind) graph.add(.{
                                .grantor = item.owner, .grantee = item.grantee, .flags = item.acl_flags, .options = item.acl_options,
                            });
                        }
                        graph.support(&support, null);
                        for (edges[0..graph.len], support[0..graph.len]) |edge, state| {
                            if (edge.flags & ~state.available != 0) return error.ChangeRecordConflict;
                        }
                    }
                }
            }
        };
    };
}

/// Bounded text appends (TextCapacity beyond the buffer).
pub const Appender = struct {
    out: []u8,
    len: *usize,

    pub fn add(self: *Appender, bytes: []const u8) Error!void {
        if (bytes.len > self.out.len - self.len.*) return error.TextCapacity;
        @memcpy(self.out[self.len.*..][0..bytes.len], bytes);
        self.len.* += bytes.len;
    }

    pub fn quoted(self: *Appender, name: []const u8) Error!void {
        try self.add("\"");
        for (name) |byte| {
            try self.add(&[1]u8{byte});
            if (byte == '"') try self.add("\"");
        }
        try self.add("\"");
    }
};
