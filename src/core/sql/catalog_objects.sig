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
//!   70 object_create kind u8, oid u32, target u32, grantee u32, sub i32,
//!                    owner u32, flags u32, grant_flags u32, name (len u8 +
//!                    bytes, may be empty), role_count u8 + role OIDs u32,
//!                    text_len u16 + bytes, split u16 (<= text_len)
//!   71 object_drop   kind u8, oid u32, target u32, grantee u32, sub i32
//!
//! Kinds and keys: 1 role (oid), 2 member (target role, grantee member),
//! 3 acl (target table, grantee role or 0 PUBLIC), 4 relation (target
//! table), 5 policy (oid), 6 comment (grantee classoid, target object, sub
//! column), 7 fdw (oid), 8 server (oid), 9 publication (oid).
//!
//! Roles are SQL-level: the bootstrap superuser (OID 10, `ramsql`) is the
//! role every wire session runs as (RAMSQL authenticates one SCRAM user and
//! maps it to this role). CREATE ROLE makes roles that own nothing at first,
//! carry privileges and policies and can be entered with SET ROLE; they have
//! no passwords and can never authenticate on the wire.
const types = @import("types.sig");
const storage = @import("storage.sig");
const lexer = @import("lexer.sig");
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

/// The plpgsql row of pg_extension (installed in every PostgreSQL
/// database). PostgreSQL assigns its OID at initdb; ZPM fixes it.
pub const plpgsql_extension_oid: u32 = 13001;

pub const Kind = enum(u8) { role = 1, member = 2, acl = 3, relation = 4, policy = 5, comment = 6, fdw = 7, server = 8, publication = 9, _ };

/// Role attributes (pg_authid booleans).
pub const role_superuser: u32 = 1;
pub const role_inherit: u32 = 2;
pub const role_createrole: u32 = 4;
pub const role_createdb: u32 = 8;
pub const role_login: u32 = 16;
pub const role_replication: u32 = 32;
pub const role_bypassrls: u32 = 64;
pub const role_attributes: u32 = 127;

/// Table privileges as PostgreSQL's AclMode bits (aclitem letters arwdDxtm).
pub const priv_insert: u32 = 1 << 0;
pub const priv_select: u32 = 1 << 1;
pub const priv_update: u32 = 1 << 2;
pub const priv_delete: u32 = 1 << 3;
pub const priv_truncate: u32 = 1 << 4;
pub const priv_references: u32 = 1 << 5;
pub const priv_trigger: u32 = 1 << 6;
pub const priv_maintain: u32 = 1 << 14;
pub const table_privileges: u32 = priv_insert | priv_select | priv_update | priv_delete | priv_truncate | priv_references | priv_trigger | priv_maintain;

pub const PrivilegeName = struct { bit: u32, letter: u8, word: []const u8, sql: []const u8 };
pub const privilege_names = [_]PrivilegeName{
    .{ .bit = priv_insert, .letter = 'a', .word = "insert", .sql = "INSERT" },
    .{ .bit = priv_select, .letter = 'r', .word = "select", .sql = "SELECT" },
    .{ .bit = priv_update, .letter = 'w', .word = "update", .sql = "UPDATE" },
    .{ .bit = priv_delete, .letter = 'd', .word = "delete", .sql = "DELETE" },
    .{ .bit = priv_truncate, .letter = 'D', .word = "truncate", .sql = "TRUNCATE" },
    .{ .bit = priv_references, .letter = 'x', .word = "references", .sql = "REFERENCES" },
    .{ .bit = priv_trigger, .letter = 't', .word = "trigger", .sql = "TRIGGER" },
    .{ .bit = priv_maintain, .letter = 'm', .word = "maintain", .sql = "MAINTAIN" },
};

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
};

pub const GranteeKind = enum(u8) { name, public, current_user, session_user, current_role };
pub const Grantee = struct { kind: GranteeKind = .name, name: Ident = .{} };

pub const Grant = struct {
    /// GRANT role TO role (membership) instead of table privileges.
    membership: bool = false,
    privileges: u32 = 0,
    tables: [list_capacity]Qualified = @splat(.{}),
    table_count: usize = 0,
    granted: [list_capacity]Ident = @splat(.{}),
    granted_count: usize = 0,
    grantees: [list_capacity]Grantee = @splat(.{}),
    grantee_count: usize = 0,
    /// WITH GRANT / ADMIN OPTION; for REVOKE, GRANT / ADMIN OPTION FOR.
    option: bool = false,
    cascade: bool = false,
};

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

pub const CommentTarget = enum { table, view, materialized_view, sequence, index, foreign_table, column, schema, role, policy, fdw, server, publication, extension };
pub const Comment = struct {
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

pub const Publication = struct { name: Ident = .{}, flags: u32 = pub_default };

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
    comment: Comment,
    create_fdw: Named,
    drop_fdw: Drop,
    create_server: Server,
    drop_server: Drop,
    create_publication: Publication,
    drop_publication: Drop,
    create_extension: Named,
};

// ---- parser -------------------------------------------------------------------

/// Parses one catalog-object statement; null when `source` is some other
/// statement (nothing is reported then: the main parser takes it).
/// Recognized but unsupported forms are 0A000; malformed ones 42601.
pub fn parse(source: []const u8, comptime name_bytes: usize, comptime text_bytes: usize) Error!?Statement {
    var p: Parser = .{ .tokens = .{ .source = source, .text_limit = text_bytes }, .source = source, .name_bytes = name_bytes };
    try p.advance();
    if (try p.take("create")) {
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
        if (try p.take("role") or try p.take("user") or try p.take("group")) return .{ .alter_role = try p.roleSpec(.role, false) };
        if (try p.take("policy")) return .{ .alter_policy = try p.policy(.alter) };
        if (try p.take("table")) return p.tableSecurity();
        return null;
    }
    if (try p.take("drop")) {
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
    if (try p.take("grant")) return .{ .grant = try p.grant(false) };
    if (try p.take("revoke")) return .{ .revoke = try p.grant(true) };
    if (try p.take("comment")) return .{ .comment = try p.comment() };
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
            if (self.word("set") or self.word("reset") or self.word("in")) return error.UnsupportedStatement;
        }
        _ = try self.take("with");
        var seen: u32 = 0;
        while (!self.atEnd()) {
            const attributes = [_]struct { on: []const u8, off: []const u8, bit: u32 }{
                .{ .on = "superuser", .off = "nosuperuser", .bit = role_superuser },
                .{ .on = "inherit", .off = "noinherit", .bit = role_inherit },
                .{ .on = "createrole", .off = "nocreaterole", .bit = role_createrole },
                .{ .on = "createdb", .off = "nocreatedb", .bit = role_createdb },
                .{ .on = "login", .off = "nologin", .bit = role_login },
                .{ .on = "replication", .off = "noreplication", .bit = role_replication },
                .{ .on = "bypassrls", .off = "nobypassrls", .bit = role_bypassrls },
            };
            var matched = false;
            if (self.current.kind == .word) {
                const raw = self.current.raw(self.source);
                for (attributes) |attribute| {
                    const on = types.keyword(raw, attribute.on);
                    if (!on and !types.keyword(raw, attribute.off)) continue;
                    // Conflicting or redundant options (42601).
                    if (seen & attribute.bit != 0) return error.Syntax;
                    seen |= attribute.bit;
                    if (on) {
                        out.set |= attribute.bit;
                        out.clear &= ~attribute.bit;
                    } else {
                        out.clear |= attribute.bit;
                        out.set &= ~attribute.bit;
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
        for (privilege_names) |entry| if (types.keyword(raw, entry.word)) return entry.bit;
        return null;
    }

    fn grant(self: *Parser, revoke: bool) Error!Grant {
        var out: Grant = .{};
        if (revoke) {
            if (self.word("grant") or self.word("admin")) {
                const admin = self.word("admin");
                try self.advance();
                try self.expect("option");
                try self.expect("for");
                out.option = true;
                out.membership = admin;
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
                all = true;
                names_ok = false;
            } else {
                const bit = if (self.current.kind == .word) privilegeWord(self.current.raw(self.source)) else null;
                if (bit) |known| privileges |= known else only_privileges = false;
                if (out.granted_count == list_capacity) return error.ProgramLimitExceeded;
                if (bit != null and self.current.keyword != .none and lexer.reserved(self.current.keyword)) {
                    // SELECT / UPDATE / DELETE / INSERT are reserved words: never role names.
                    names_ok = false;
                    try self.advance();
                } else {
                    out.granted[out.granted_count] = try self.roleName();
                    out.granted_count += 1;
                }
                // Column lists (GRANT SELECT (a) ...) are outside the subset.
                if (self.symbol(.lparen)) return error.UnsupportedStatement;
            }
            if (!try self.takeSymbol(.comma)) break;
        }
        if (try self.take("on")) {
            // Privileges on other object kinds are outside the subset.
            if (self.word("sequence") or self.word("schema") or self.word("database") or self.word("function") or self.word("procedure") or
                self.word("routine") or self.word("language") or self.word("type") or self.word("domain") or self.word("foreign") or
                self.word("large") or self.word("tablespace") or self.word("parameter") or self.word("all")) return error.UnsupportedStatement;
            if (!only_privileges and !all) return error.Syntax;
            out.privileges = if (all) table_privileges else privileges;
            _ = try self.take("table");
            while (true) {
                if (out.table_count == list_capacity) return error.ProgramLimitExceeded;
                out.tables[out.table_count] = try self.qualified();
                out.table_count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            out.granted_count = 0;
        } else {
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
                if (!try self.take("admin")) return error.UnsupportedStatement;
                if (!try self.take("option") and !try self.take("true")) return error.UnsupportedStatement;
            } else {
                try self.expect("grant");
                try self.expect("option");
            }
            out.option = true;
        }
        if (self.word("granted")) return error.UnsupportedStatement;
        if (revoke) out.cascade = try self.dropBehavior();
        try self.finish();
        return out;
    }

    fn comment(self: *Parser) Error!Comment {
        try self.expect("on");
        var out: Comment = .{};
        if (try self.take("table")) {
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
            if (!try self.take("all")) return error.UnsupportedStatement;
            // FOR ALL TABLES; FOR TABLE / TABLES IN SCHEMA are outside the subset.
            if (!try self.take("tables")) return error.Syntax;
            out.flags |= pub_all_tables;
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
    return kind == .role or kind == .member or kind == .policy or kind == .fdw or kind == .server or kind == .publication;
}

/// Kinds whose objects carry a unique name.
fn named(kind: Kind) bool {
    return kind == .role or kind == .policy or kind == .fdw or kind == .server or kind == .publication;
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
                .role, .policy, .fdw, .server, .publication => a.oid == b.oid,
                .member, .acl => a.target == b.target and a.grantee == b.grantee,
                .relation => a.target == b.target,
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
                if (kind == .policy and o.target != target) continue;
                return index;
            }
            return null;
        }

        /// The live transaction (other than the snapshot's) holding an
        /// uncommitted version of `o`, if any.
        fn pendingOf(o: *const Object, snap: storage.Snapshot) ?u16 {
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
                if (named(key.kind) and o.kind == key.kind and types.same(o.name.slice(), key.name.slice()) and (key.kind != .policy or o.target == key.target)) return other;
            }
            return null;
        }

        /// Another live transaction with an uncommitted object that names
        /// `oid` (as a role, table, wrapper or object of a comment).
        pub fn pendingReference(self: *const Self, oid: u32, snap: storage.Snapshot) ?u16 {
            for (&self.items) |*o| {
                const other = pendingOf(o, snap) orelse continue;
                if (o.oid == oid or o.target == oid or o.grantee == oid or o.owner == oid) return other;
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
            const index = self.byOid(.role, oid, snap) orelse return null;
            return self.items[index].flags;
        }

        pub fn roleName(self: *const Self, oid: u32, snap: storage.Snapshot) ?[]const u8 {
            if (oid == bootstrap_role) return bootstrap_name;
            const index = self.byOid(.role, oid, snap) orelse return null;
            return self.items[index].name.slice();
        }

        pub fn roleByName(self: *const Self, name: []const u8, snap: storage.Snapshot) ?u32 {
            if (types.same(name, bootstrap_name)) return bootstrap_role;
            const index = self.byName(.role, 0, name, snap) orelse return null;
            return self.items[index].oid;
        }

        pub fn superuser(self: *const Self, oid: u32, snap: storage.Snapshot) bool {
            const flags = self.roleFlags(oid, snap) orelse return false;
            return flags & role_superuser != 0;
        }

        /// `member` is `group` or (transitively) a member of it. With
        /// `inherit`, only through roles that inherit privileges
        /// (has_privs_of_role); without, any membership (SET ROLE).
        pub fn memberOf(self: *const Self, member: u32, group: u32, inherit: bool, snap: storage.Snapshot) bool {
            if (member == group) return true;
            // Breadth-first over at most `capacity` roles.
            var queue: [capacity + 1]u32 = undefined;
            queue[0] = member;
            var count: usize = 1;
            var next: usize = 0;
            while (next < count) : (next += 1) {
                const current = queue[next];
                if (inherit) {
                    const flags = self.roleFlags(current, snap) orelse continue;
                    if (flags & role_inherit == 0) continue;
                }
                for (&self.items) |*o| {
                    if (o.kind != .member or o.grantee != current or !visible(o, snap)) continue;
                    if (o.target == group) return true;
                    var known = false;
                    for (queue[0..count]) |seen| known = known or seen == o.target;
                    if (!known and count < queue.len) {
                        queue[count] = o.target;
                        count += 1;
                    }
                }
            }
            return false;
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

        /// Every privilege bit in `wanted` (pg_class_aclcheck): superusers
        /// and the owner hold all; otherwise grants to the role, a role it
        /// inherits from, or PUBLIC.
        pub fn tablePrivileges(self: *const Self, role: u32, table: u32, wanted: u32, snap: storage.Snapshot) bool {
            if (self.ownsTable(role, table, snap)) return true;
            var held: u32 = 0;
            for (&self.items) |*o| {
                if (o.kind != .acl or o.target != table or !visible(o, snap)) continue;
                if (o.grantee == public_role or self.memberOf(role, o.grantee, true, snap)) held |= o.flags;
            }
            return held & wanted == wanted;
        }

        /// Grant options held for `wanted` (owners hold them all).
        pub fn grantOptions(self: *const Self, role: u32, table: u32, wanted: u32, snap: storage.Snapshot) bool {
            if (self.ownsTable(role, table, snap)) return true;
            var held: u32 = 0;
            for (&self.items) |*o| {
                if (o.kind != .acl or o.target != table or !visible(o, snap)) continue;
                if (o.grantee == public_role or self.memberOf(role, o.grantee, true, snap)) held |= o.grant_flags;
            }
            return held & wanted == wanted;
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
            if (raw < 1 or raw > 9) return error.InvalidChangeRecord;
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
                .member => o.oid != 0 and o.target != 0 and o.grantee != 0 and o.sub == 0,
                .acl => o.oid == 0 and o.target != 0 and o.sub == 0,
                .relation => o.oid == 0 and o.target != 0 and o.grantee == 0 and o.sub == 0,
                .comment => o.oid == 0 and o.target != 0 and o.sub >= 0 and switch (o.grantee) {
                    class_relation => true,
                    class_namespace, class_authid, class_fdw, class_server, class_publication, class_policy => o.sub == 0,
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
                .member => !has_name and o.owner != 0 and o.flags == 0 and o.grant_flags <= 1 and o.role_count == 0 and o.text_len == 0 and o.target != o.grantee,
                .acl => !has_name and o.flags != 0 and o.flags & ~table_privileges == 0 and o.grant_flags & ~o.flags == 0 and o.role_count == 0 and o.text_len == 0 and o.owner != 0,
                .relation => !has_name and o.flags & ~(rls_enabled | rls_forced) == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len == 0 and o.owner != 0,
                .policy => has_name and o.flags & ~@as(u32, 0x7ff) == 0 and (o.flags & 0xff) <= 4 and o.grant_flags == 0 and o.role_count != 0 and o.owner == 0 and using_ok and check_ok,
                .comment => !has_name and o.owner == 0 and o.flags == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len != 0 and o.split == 0,
                .fdw => has_name and o.flags == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len == 0 and o.owner != 0,
                .server => has_name and o.target != 0 and o.flags & ~(server_type | server_version) == 0 and o.grant_flags == 0 and o.role_count == 0 and o.owner != 0 and
                    (o.flags & server_type != 0 or o.split == 0) and (o.flags & server_version != 0 or o.split == o.text_len),
                .publication => has_name and o.flags & ~@as(u32, 63) == 0 and o.grant_flags == 0 and o.role_count == 0 and o.text_len == 0 and o.owner != 0,
                _ => false,
            };
            if (!valid) return error.InvalidChangeRecord;
            return o;
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
            roles: [role_capacity]u32 = @splat(0),
            role_count: u8 = 0,
            name: V.Name = .{},
        };

        pub const Overlay = struct {
            items: [capacity]VObject = @splat(.{}),

            fn project(o: *const Object, live: bool) VObject {
                return .{ .used = o.used, .live = live, .kind = o.kind, .oid = o.oid, .target = o.target, .grantee = o.grantee, .sub = o.sub, .owner = o.owner, .roles = o.roles, .role_count = o.role_count, .name = o.name };
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
                    if (!v.used or !ownsOid(v.kind)) continue;
                    if (v.oid >= oid and v.oid - oid < width) return true;
                }
                return false;
            }

            pub fn roleExists(self: *const Overlay, oid: u32) bool {
                if (oid == bootstrap_role) return true;
                return self.liveOid(.role, oid);
            }

            fn liveOid(self: *const Overlay, kind: Kind, oid: u32) bool {
                for (&self.items) |*v| if (v.live and v.kind == kind and v.oid == oid) return true;
                return false;
            }

            /// Op 70 against the overlay. `ctx` answers objectTableLive,
            /// objectTableColumns, objectSequenceLive, objectSchemaLive and
            /// objectOidTaken for the record so far, and notes allocated OIDs
            /// (noteObjectOid).
            pub fn create(self: *Overlay, o: *const Object, ctx: anytype) Error!void {
                if (ownsOid(o.kind)) {
                    if (o.oid < first_oid or o.oid == 0xffffffff or ctx.objectOidTaken(o.oid)) return error.ChangeRecordConflict;
                }
                for (&self.items) |*v| {
                    if (!v.live) continue;
                    const existing = asObject(v);
                    if (sameKey(&existing, o)) return error.ChangeRecordConflict;
                    if (named(o.kind) and v.kind == o.kind and types.same(v.name.slice(), o.name.slice()) and (o.kind != .policy or v.target == o.target)) return error.ChangeRecordConflict;
                }
                if (o.kind == .role and (types.same(o.name.slice(), bootstrap_name) or reservedRoleName(o.name.slice()))) return error.ChangeRecordConflict;
                try self.references(o.kind, o.target, o.grantee, o.sub, o.owner, o.roles[0..o.role_count], ctx);
                for (&self.items) |*v| if (!v.used) {
                    v.* = project(o, true);
                    // A decoded version is not yet an entry: mark it taken.
                    v.used = true;
                    if (ownsOid(o.kind)) ctx.noteObjectOid(o.oid);
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
                    v.* = .{};
                    return;
                }
                return error.ChangeRecordConflict;
            }

            fn references(self: *const Overlay, kind: Kind, target: u32, grantee: u32, sub: i32, owner_oid: u32, roles: []const u32, ctx: anytype) Error!void {
                if (owner_oid != 0) {
                    if (!self.roleExists(owner_oid)) return error.ChangeRecordConflict;
                }
                switch (kind) {
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
                    .relation => {
                        if (!ctx.objectTableLive(target)) return error.ChangeRecordConflict;
                    },
                    .policy => {
                        if (!ctx.objectTableLive(target)) return error.ChangeRecordConflict;
                        for (roles) |role| {
                            if (role == public_role) continue;
                            if (!self.roleExists(role)) return error.ChangeRecordConflict;
                        }
                    },
                    .server => {
                        if (!self.liveOid(.fdw, target)) return error.ChangeRecordConflict;
                    },
                    .comment => {
                        const exists = switch (grantee) {
                            class_relation => if (ctx.objectTableColumns(target)) |columns| sub <= columns else sub == 0 and ctx.objectSequenceLive(target),
                            class_namespace => ctx.objectSchemaLive(target),
                            class_authid => self.roleExists(target),
                            class_fdw => self.liveOid(.fdw, target),
                            class_server => self.liveOid(.server, target),
                            class_publication => self.liveOid(.publication, target),
                            class_policy => self.liveOid(.policy, target),
                            else => false,
                        };
                        if (!exists) return error.ChangeRecordConflict;
                    },
                    else => {},
                }
            }

            /// After the whole record: every live object still names live
            /// tables, roles and objects (a DROP drops its dependents in
            /// the same record).
            pub fn finish(self: *const Overlay, ctx: anytype) Error!void {
                for (&self.items) |*v| {
                    if (!v.live) continue;
                    try self.references(v.kind, v.target, v.grantee, v.sub, v.owner, v.roles[0..v.role_count], ctx);
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
