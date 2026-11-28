//! Value conversions (Layer 0, design Â§4.2): text input and output for every
//! type, casts (explicit, assignment and implicit contexts follow
//! PostgreSQL's pg_cast for the supported types), typmod coercion and the
//! operators over the Q02/Q03/Q04 types. Cells are the tagged union in
//! types.sig with inline storage bounded by Config.text_bytes.
//!
//! The per-statement Session supplies what PostgreSQL takes from GUCs and
//! the transaction: the TimeZone (output and local-time input of
//! TIMESTAMPTZ), a zone-name resolver, transaction/statement start times and
//! the wall clock. Without a clock, now() and friends fail with 0A000.
const types = @import("types.sig");
const numeric = @import("numeric.sig");
const float_text = @import("float_text.sig");
const temporal = @import("temporal.sig");
const jsonb = @import("jsonb.sig");
const expr = @import("expr.sig");
const ast = @import("ast.sig");
const character = @import("character.sig");
const uuid = @import("uuid.sig");
const bytea = @import("bytea.sig");
const time_of_day = @import("time_of_day.sig");
const bit_string = @import("bit_string.sig");
const money = @import("money.sig");
const catalog_ids = @import("catalog_ids.sig");
const array_text = @import("array_text.sig");
const range_text = @import("range_text.sig");
const network = @import("network.sig");
const geometric = @import("geometric.sig");
const geometry = @import("geometry.sig");
const multirange = @import("multirange.sig");
const xml = @import("xml.sig");
const jsonpath = @import("jsonpath.sig");
const text_search = @import("text_search.sig");
const record_module = @import("record.sig");
const catalog_objects = @import("catalog_objects.sig");
const Error = types.Error;
const Type = types.Type;

/// The two relation kinds supported by PostgreSQL's session access guard.
/// current_schemas(): schemas the search path lists (ddl-dml, wave 4).
pub const schema_path_names = 10;
pub const RestrictedRelationKinds = packed struct {
    view: bool = false,
    foreign_table: bool = false,

    /// Only call for a relation in the user catalog. Built-in system views
    /// resolve separately and have no entries in caller-owned table storage.
    pub fn check(self: RestrictedRelationKinds, kind: u8) Error!void {
        if (kind == 'v' and self.view) return error.RestrictedNonSystemView;
        if (kind == 'f' and self.foreign_table) return error.RestrictedNonSystemForeignTable;
    }
};

pub const Session = struct {
    zone: temporal.Zone = .{},
    resolver: temporal.Resolver = .{},
    xml_document: bool = false,
    restricted_relation_kinds: RestrictedRelationKinds = .{},
    /// PostgreSQL-epoch microseconds (2000-01-01 UTC); null without a clock.
    transaction_us: ?i64 = null,
    statement_us: ?i64 = null,
    /// Current wall clock in PostgreSQL-epoch microseconds.
    clock: ?*const fn () ?i64 = null,
    /// Sequence functions, identity defaults and regclass lookups (set by
    /// the Database for each statement); null rejects them (0A000).
    sequences: ?*const SequenceHook = null,
    /// Internal rendering for the PostgreSQL binary-input bridge.
    regproc_numeric_output: bool = false,
    /// current_database(): the session's startup database.
    database: []const u8 = "postgres",
    /// The implicit catalog remains visible when a PostgreSQL session
    /// installs an empty explicit schema path.
    public_schema_on_path: bool = true,
    row_security: bool = true,
    synchronize_seqscans: bool = true,
    quote_all_identifiers: bool = false,
    /// default_text_search_config as a text_search.Config ordinal (wave 4
    /// text-json; 1 is english).
    text_search_config: u8 = 1,
    extra_float_digits: i8 = 1,
    mysql_keep_zero: bool = false,
    mysql_last_insert_id: u64 = 0,
    control: ?*types.ExecutionControl = null,
    /// Caller-backed bytes for catalog values and their text casts.
    value_bytes: ?*types.ValueBytes = null,
    /// Values of $1..$n while an EXECUTEd SQL prepared statement runs
    /// ([Config.statement_parameters]Cell of the Database; tx-session lane).
    params: ?*const anyopaque = null,
    /// Session functions (current_setting, set_config, advisory locks,
    /// pg_notify, pg_backend_pid); set by the Database per statement.
    engine: ?*const SessionHook = null,
    /// User function calls (B11 wave 3; set by the Database for each
    /// statement); null rejects them (0A000).
    routines: ?*const RoutineHook = null,
    /// The routine frame (Exec's ExprFrame) that routine variables of a
    /// statement run by a procedure or DO block read; null outside one.
    routine_frame: ?*const anyopaque = null,
    /// current_user and session_user as role OIDs (B11 wave 3): privilege
    /// and row-security checks use `role`. 10 is the bootstrap superuser
    /// every wire session authenticates as; SET ROLE changes `role`.
    role: u32 = 10,
    session_role: u32 = 10,
    /// SQL/XML scratch storage (B11 wave 5 xml lane): the Database's
    /// Config-sized region, used in stack order by XPath, XMLTABLE,
    /// XMLSERIALIZE ... INDENT and the table mapping functions; null
    /// outside a Database (0A000 then).
    xml_scratch: ?*types.ValueBytes = null,
    /// xmlbinary (B11 wave 5 xml lane): bytea values map to hex instead of
    /// base64 in SQL/XML.
    xml_binary_hex: bool = false,

    pub fn checkpoint(self: *const Session) Error!void {
        if (self.control) |control| try control.checkpoint();
    }
    pub fn checkpoints(self:*const Session,count:usize) Error!void {
        if(self.control) |control| try control.advance(count);
    }
};

pub const SequenceCall = enum { nextval, currval, setval, lastval, identity, regclass };

/// `name` is the regclass text (nextval/currval/setval; or `oid` when the
/// argument is a regclass); identity passes the table slot in `oid` and the
/// column in `value`; regclass resolves a relation name to its OID (-1 when
/// missing unless `called`, which raises 42P01).
pub const LargeObjectData = enum { create, read };

pub const LargeObjectFileHook = struct {
    authorize: *const fn (ptr: *anyopaque, function: u32) Error!void,
    call: *const fn (ptr: *anyopaque, operation: @import("large_object_file.sig").Operation, oid: u32, path: []const u8) Error!u32,
};

pub const SequenceHook = struct {
    large_object_file: ?LargeObjectFileHook = null,
    large_object_truncate: ?*const fn (ptr: *anyopaque, fd: i32, length: i64) Error!i32 = null,
    large_object: ?*const fn (ptr: *anyopaque, create: bool, oid: u32) Error!u32 = null,
    large_object_data: ?*const fn (ptr: *anyopaque, operation: LargeObjectData, oid: u32, offset: i64, input: []const u8, output: []u8, requested: ?usize) Error!usize = null,
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, kind: SequenceCall, name: []const u8, oid: u32, value: i64, called: bool) Error!i64,
    /// regclass output: the relation named by `oid`, if any.
    relation_name: *const fn (ptr: *anyopaque, oid: u32, out: *[64]u8) ?usize,
    relation_display_name: ?*const fn (ptr: *anyopaque, oid: u32, out: []u8) Error!?usize = null,
    /// Catalog-object text (B11 wave 3): a comment (obj_description,
    /// col_description, shobj_description) or a role name, written to `out`.
    catalog_text: ?*const fn (ptr: *anyopaque, kind: CatalogText, object: u32, classoid: u32, sub: i32, out: []u8) Error!?usize = null,
    schema_path: ?*const fn (ptr: *anyopaque, implicit: bool, names: *[schema_path_names][]const u8) usize = null,
    /// pg_get_serial_sequence(table, column): the qualified name of the
    /// sequence a column owns (SERIAL or identity) into `out`, null when it
    /// owns none (42P01 / 42703 for a missing table / column).
    serial_sequence: ?*const fn (ptr: *anyopaque, table: []const u8, column: []const u8, out: *[serial_name_bytes]u8) Error!?usize = null,
    /// Visibility of an existing relation in the owning catalog snapshot.
    relation_visible: ?*const fn (ptr: *anyopaque, oid: u32) ?bool = null,
    /// pg_function_is_visible: a routine of that OID visible on the path
    /// (null: no such routine).
    function_visible: ?*const fn (ptr: *anyopaque, oid: u32) ?bool = null,
    /// Index definition or one index attribute in the owning snapshot.
    index_definition: ?*const fn (ptr: *anyopaque, oid: u32, column: i32, pretty: bool, out: []u8) Error!?usize = null,
    constraint_definition: ?*const fn (ptr: *anyopaque, oid: u32, pretty: bool, out: []u8) Error!?usize = null,
    view_definition: ?*const fn (ptr: *anyopaque, oid: u32, pretty: bool, out: []u8) Error!?usize = null,
    statistics_columns: ?*const fn (ptr: *anyopaque, oid: u32, out: []u8) Error!?usize = null,
    relation_publishable: ?*const fn (ptr: *anyopaque, oid: u32) ?bool = null,
    partition_key_definition: ?*const fn (ptr: *anyopaque, oid: u32, out: []u8) Error!?usize = null,
    trigger_definition: ?*const fn (ptr: *anyopaque, oid: u32, pretty: bool, out: []u8) Error!?usize = null,
    rule_definition: ?*const fn (ptr: *anyopaque, oid: u32, pretty: bool, out: []u8) Error!?usize = null,
    partition_ancestors: ?*const fn (ptr: *anyopaque, oid: u32, out: []u32) Error!usize = null,
    namespace_lookup: ?*const fn (ptr: *anyopaque, name: []const u8, strict: bool) Error!?u32 = null,
    namespace_name: ?*const fn (ptr: *anyopaque, oid: u32, out: []u8) Error!?usize = null,
    routine_lookup: ?*const fn (ptr: *anyopaque, name: []const u8, strict: bool) Error!?u32 = null,
    routine_name: ?*const fn (ptr: *anyopaque, oid: u32, out: []u8) Error!?usize = null,
    /// SQL/XML table mapping (B11 wave 5 xml lane): runs `query` nested in
    /// the running statement, read-only under its snapshot, and passes its
    /// columns and rows to `sink` (a query that is not a SELECT is 22000).
    xml_query: ?*const fn (ptr: *anyopaque, query: []const u8, sink: *const XmlQuerySink) Error!void = null,
    /// cursor_to_xml / cursor_to_xmlschema (B11 wave 5 xml lane): the
    /// session cursor `name` (34000 when there is none) passes its columns
    /// to `sink`, then with `fetch` the rows of FETCH FORWARD `count`.
    xml_cursor: ?*const fn (ptr: *anyopaque, name: []const u8, count: i64, fetch: bool, sink: *const XmlQuerySink) Error!void = null,
    /// A user type's regtype output (domains, enums, composite types;
    /// schema-qualified when the search path does not find it; S071).
    type_name: ?*const fn (ptr: *anyopaque, oid: u32, out: []u8) Error!?usize = null,
    /// The fields of a composite type (B11 wave 5, composite lane): its
    /// catalog_objects.CompositeFields bytes, null when no such type.
    composite_layout: ?*const fn (ptr: *anyopaque, oid: u32) ?[]const u8 = null,
    /// regtype input of a user type name (`name` or `schema.name`, quoted
    /// or not; the search path finds an unqualified one): its OID, null
    /// when there is none (composite lane).
    type_oid: ?*const fn (ptr: *anyopaque, input: []const u8) Error!?u32 = null,
    /// has_*_privilege / pg_has_role (privileges lane): null is SQL NULL
    /// (an OID naming nothing).
    privilege: ?*const fn (ptr: *anyopaque, request: *const PrivilegeRequest) Error!?bool = null,
};

/// The fields of composite type `oid` through the session's catalog hook.
pub fn compositeLayout(session: *const Session, oid: u32) ?[]const u8 {
    const hook = session.sequences orelse return null;
    const layout = hook.composite_layout orelse return null;
    return layout(hook.ptr, oid);
}

/// The receiver of an xml_query (B11 wave 5 xml lane).
pub const XmlQuerySink = struct {
    context: *anyopaque,
    /// Once, before the rows: the column count, names (Values(config).Name),
    /// types and typmods.
    columns: *const fn (context: *anyopaque, count: usize, names: *const anyopaque, tys: [*]const Type, typmods: [*]const i32) Error!void,
    /// Each row: its cells (Values(config).Cell), valid during the call.
    row: *const fn (context: *anyopaque, cells: *const anyopaque) Error!void,
};

pub const SessionCall = enum { current_setting, set_config, advisory_lock, advisory_try_lock, advisory_unlock, advisory_unlock_all, notify, backend_pid, recovery_status,
    // A pseudo-random 64-bit word (array_sample / array_shuffle, B11 wave 4).
    random };

pub fn routineOid(session: *const Session, input: []const u8, strict: bool) Error!?u32 {
    if (types.same(input, "-")) return 0;
    if (input.len != 0) {
        const digits_only = for (input) |byte| {
            if (!types.digit(byte)) break false;
        } else true;
        if (digits_only) return @as(?u32, @import("std").fmt.parseInt(u32, input, 10) catch return error.NumericValueOutOfRange);
    }
    if (session.sequences) |hook| {
        if (hook.routine_lookup) |lookup| return lookup(hook.ptr, input, strict);
    }
    if (strict) return error.UndefinedFunction;
    return null;
}

/// Advisory call flags: 1 shared, 2 transaction-level, 4 two int4 keys;
/// current_setting / set_config: 1 missing_ok / is_local.
pub const SessionReply = struct { integer: i64 = 0, len: usize = 0, null_value: bool = false };

/// Engine session functions: text arguments `a`/`b`, integer keys `x`/`y`,
/// text results written to `out` (`len`), booleans/integers in `integer`.
pub const SessionHook = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, kind: SessionCall, a: []const u8, b: []const u8, x: i64, y: i64, flags: u8, out: []u8) Error!SessionReply,
};
/// Room for `schema.name` with both parts quoted (pg_get_serial_sequence).
pub const serial_name_bytes = 520;

/// A user function call: `routine` is the routine slot, `args` the
/// evaluated argument cells (Values(config).Cell) and `out` receives the
/// result cell. The Database runs the body (B11 wave 3).
pub const RoutineHook = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, routine: usize, args: *const anyopaque, count: usize, out: *anyopaque) Error!void,
    /// A call with DEFAULT arguments (B11 wave 4): bit p of `defaulted`
    /// marks input p as taking its DEFAULT expression.
    call_defaults: ?*const fn (ptr: *anyopaque, routine: usize, args: *const anyopaque, count: usize, defaulted: u64, out: *anyopaque) Error!void = null,
    /// Before an inlined SQL body runs: EXECUTE privilege, DEFAULTs filled
    /// into `args` in place; false when STRICT meets a NULL argument.
    prepare: ?*const fn (ptr: *anyopaque, routine: usize, args: *anyopaque, count: usize, defaulted: u64) Error!bool = null,
    /// Rows of a routine in FROM (set-returning or several OUT columns):
    /// `emit(sink, cells)` once per row with the result columns.
    rows: ?*const fn (ptr: *anyopaque, routine: usize, args: *const anyopaque, count: usize, defaulted: u64, sink: *anyopaque, emit: *const fn (sink: *anyopaque, cells: *const anyopaque) Error!void) Error!void = null,
    /// Rows of a REFERENCING transition table (B11 wave 5): `code` is the
    /// firing trigger's window * 2 + 1 for OLD TABLE (+ 0 for NEW TABLE).
    transition: ?*const fn (ptr: *anyopaque, code: u64, sink: *anyopaque, emit: *const fn (sink: *anyopaque, cells: *const anyopaque) Error!void) Error!void = null,
};

pub const CatalogText = enum { description, shared_description, role_name, function_arguments, function_identity_arguments, function_result, function_sqlbody };

/// Access privilege inquiry (privileges lane, B11 wave 5).
pub const PrivilegeInquiry = enum(u8) { table, column, any_column, schema, sequence, type_usage, role };

/// A name or OID argument of a privilege inquiry (none: the current user).
pub const PrivilegeSubject = union(enum) { none, oid: i64, name: []const u8 };

pub const PrivilegeRequest = struct {
    inquiry: PrivilegeInquiry,
    user: PrivilegeSubject = .none,
    object: PrivilegeSubject,
    column: PrivilegeSubject = .none,
    privileges: []const u8,
};

pub const default_session: Session = .{};
const SessionType = Session;

pub const Context = enum { implicit, assignment, explicit };

/// The geometric types (point, box and the B11 wave-4 types).
pub fn geometryType(ty: Type) bool {
    return switch (ty) {
        .point, .box, .lseg, .line, .path, .polygon, .circle => true,
        else => false,
    };
}

pub fn numericCategory(ty: Type) bool {
    return switch (ty) {
        .int2, .int4, .int8, .numeric, .float4, .float8 => true,
        else => false,
    };
}

pub fn integral(ty: Type) bool {
    return ty == .int2 or ty == .int4 or ty == .int8;
}

pub fn stringType(ty: Type) bool {
    return ty == .text or ty == .name or ty == .varchar;
}

/// The string category including CHAR(n), whose values are padded and so
/// need a cast (rtrim) wherever TEXT operators read their bytes.
pub fn characterType(ty: Type) bool {
    return stringType(ty) or ty == .bpchar;
}

pub fn bitType(ty: Type) bool {
    return ty == .bit or ty == .varbit;
}

/// pg_cast entries of the B11 types; null when the pair is not one of them.
fn extendedCast(from: Type, to: Type, context: Context) ?bool {
    if (from == .void or to == .void) {
        // void (B11 wave 4): void_in/void_out only, by I/O conversion.
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (to == .pg_internal_char) return switch (from) {
        .int4, .name => context == .explicit,
        .text, .varchar, .bpchar => context != .implicit,
        else => false,
    };
    if (from == .pg_internal_char) return switch (to) {
        .text => true,
        .varchar, .bpchar, .name => context != .implicit,
        .int4 => context == .explicit,
        else => false,
    };
    if (from == .bpchar or to == .bpchar) {
        // text/varchar <-> bpchar and bpchar -> name are implicit; name ->
        // bpchar is an assignment cast.
        if (characterType(from) and characterType(to)) return from != .name or context != .implicit;
        // I/O conversion: to a string type in assignment, from one explicitly.
        if (to == .bpchar) return context != .implicit;
        return context == .explicit;
    }
    if (from == .money or to == .money) {
        // int4/int8/numeric -> money and money -> numeric are assignment
        // casts; strings by I/O conversion; nothing else.
        if (to == .money and (from == .int4 or from == .int8 or from == .numeric)) return context != .implicit;
        if (from == .money and to == .numeric) return context != .implicit;
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (from == .macaddr8 or to == .macaddr8) {
        // macaddr <-> macaddr8 are implicit (B11 wave 4); strings by I/O.
        if ((from == .macaddr and to == .macaddr8) or (from == .macaddr8 and to == .macaddr)) return true;
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (from == .inet or from == .cidr or to == .inet or to == .cidr or from == .macaddr or to == .macaddr) {
        // cidr -> inet is implicit, inet -> cidr by assignment; strings by
        // I/O conversion (text(inet) by assignment).
        if (from == .cidr and to == .inet) return true;
        if (from == .inet and to == .cidr) return context != .implicit;
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (from == .jsonpath or to == .jsonpath) {
        // jsonpath has no pg_cast entries: strings by I/O conversion only.
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (from == .xml or to == .xml) {
        // xml -> text/varchar/bpchar by assignment (binary); text -> xml
        // explicitly (XMLPARSE CONTENT).
        if (from == .xml) return characterType(to) and context != .implicit;
        return characterType(from) and context == .explicit;
    }
    if (from == .tsvector or to == .tsvector or from == .tsquery or to == .tsquery) {
        // No pg_cast entries: strings by I/O conversion only.
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (from == .regtype or to == .regtype or from == .regproc or to == .regproc) {
        // OID aliases share binary casts with oid, integer casts and string I/O.
        const target_alias = to == .regtype or to == .regproc;
        const source_alias = from == .regtype or from == .regproc;
        if (from == .oid or to == .oid or (target_alias and integral(from))) return true;
        if (source_alias and (to == .int4 or to == .int8)) return context != .implicit;
        // conversion.
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (geometryType(from) or geometryType(to)) {
        // geo_ops casts (B11 wave 4): point -> box, path <-> polygon and
        // box -> polygon by assignment; the other conversions explicitly;
        // strings by I/O conversion.
        if ((from == .point and to == .box) or (from == .path and to == .polygon) or (from == .polygon and to == .path) or (from == .box and to == .polygon)) return context != .implicit;
        const explicit = switch (from) {
            .lseg => to == .point,
            .box => to == .point or to == .lseg or to == .circle,
            .polygon => to == .point or to == .box or to == .circle,
            .circle => to == .point or to == .box or to == .polygon,
            else => false,
        };
        if (explicit) return context == .explicit;
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (from == .point or to == .point or from == .box or to == .box) {
        // Geometric types: strings by I/O conversion only here.
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (multirange.isMultirange(from) or multirange.isMultirange(to)) {
        // range -> its multirange explicitly (B11 wave 4); strings by I/O.
        if (types.isRange(from) and multirange.ofRange(types.dataTypeOf(from)) == types.dataTypeOf(to)) return context == .explicit;
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (types.isRange(from) or types.isRange(to)) {
        // Ranges have no pg_cast entries: strings by I/O conversion only.
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (from == .pg_lsn or to == .pg_lsn or from == .xid8 or to == .xid8) {
        // pg_lsn and xid8 have no pg_cast entries for the supported types
        // (xid8 -> xid is outside them): strings by I/O conversion only.
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (bitType(from) or bitType(to)) {
        // bit <-> varbit are implicit (binary); int4/int8 <-> bit explicit.
        if (bitType(from) and bitType(to)) return true;
        if ((to == .bit and (from == .int4 or from == .int8)) or (from == .bit and (to == .int4 or to == .int8))) return context == .explicit;
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    if (from == .time or to == .time or from == .timetz or to == .timetz) {
        // pg_cast: time -> interval and time -> timetz are implicit;
        // interval/timestamp/timestamptz/timetz -> time and timestamptz ->
        // timetz are assignment casts; strings by I/O conversion.
        const implicit = (from == .time and (to == .interval or to == .timetz));
        const assignment = (to == .time and (from == .interval or from == .timestamp or from == .timestamptz or from == .timetz)) or
            (to == .timetz and from == .timestamptz);
        if (implicit) return true;
        if (assignment) return context != .implicit;
        if (stringType(to)) return context != .implicit;
        if (stringType(from)) return context == .explicit;
        return false;
    }
    return null;
}

/// select_common_type within the string category for the B11 types: TEXT is
/// preferred, NAME wins over VARCHAR/CHAR (implicit only one way), and
/// otherwise the first type wins.
fn characterCommon(a: Type, b: Type) Type {
    if (a == .text or b == .text) return .text;
    if (a == .name or b == .name) return .name;
    return a;
}

pub fn datetime(ty: Type) bool {
    return ty == .date or ty == .timestamp or ty == .timestamptz;
}

/// Promotion rank in the numeric category (int2 < ... < float8).
pub fn numericRank(ty: Type) u8 {
    return switch (ty) {
        .int2 => 0,
        .int4 => 1,
        .int8 => 2,
        .numeric => 3,
        .float4 => 4,
        .float8 => 5,
        else => 255,
    };
}

fn datetimeRank(ty: Type) u8 {
    return switch (ty) {
        .date => 0,
        .timestamp => 1,
        .timestamptz => 2,
        else => 255,
    };
}

/// Whether a cast from `from` to `to` exists in `context`.
pub fn castable(from: Type, to: Type, context: Context) bool {
    if (from == to) return true;
    if (from == .unknown) return true;
    if (to == .mysql_bigint_unsigned)
        return context == .assignment and (integral(from) or from == .numeric);
    if (from == .mysql_bigint_unsigned)
        return context == .explicit and (to == .numeric or stringType(to));
    if (types.elementType(from)) |element| {
        // array_coerce: an element cast in the same context; to strings by
        // I/O conversion (assignment).
        if (types.elementType(to)) |target| return castable(element, target, context);
        return stringType(to) and context != .implicit;
    }
    // From strings by I/O conversion (array_in), explicitly.
    if (types.isArray(to)) return stringType(from) and context == .explicit;
    if (extendedCast(from, to, context)) |allowed| return allowed;
    // Implicit promotions.
    if (numericCategory(from) and numericCategory(to) and numericRank(from) < numericRank(to)) return true;
    if (datetime(from) and datetime(to) and datetimeRank(from) < datetimeRank(to)) return true;
    if (stringType(from) and stringType(to)) return true;
    if ((from == .int2 or from == .int4 or from == .int8) and to == .oid) return true;
    if (context == .implicit) return false;
    // Assignment.
    if (numericCategory(from) and numericCategory(to)) return true;
    if (datetime(from) and datetime(to)) return true;
    if (stringType(to)) return true;
    if (from == .oid and (to == .int4 or to == .int8)) return true;
    if ((from == .json and to == .jsonb) or (from == .jsonb and to == .json)) return true;
    if (context == .assignment) return false;
    // Explicit only.
    if (stringType(from)) return true;
    if ((from == .boolean and to == .int4) or (from == .int4 and to == .boolean)) return true;
    return false;
}

/// select_common_type / operator promotion for two typed operands; null
/// when they do not unify.
/// Mixed REAL comparisons resolve a float8 operator, unlike CASE/GREATEST
/// common-type selection. Rounding an exact int/numeric to float4 first can
/// turn distinct values into equal ones (e.g. 16777217 and 16777216::real).
pub fn comparisonType(a: Type, b: Type) ?Type {
    // regtype has no operators of its own: oid's apply (binary coercible).
    if (a == .regtype or b == .regtype) return comparisonType(if (a == .regtype) .oid else a, if (b == .regtype) .oid else b);
    // point has no = operator and box compares only by area: neither has
    // ordinary comparison operators here.
    if (a == .point or b == .point or a == .box or b == .box) return null;
    if (a == .void or b == .void) return null;
    // xml and jsonpath have no comparison operators; tsvector/tsquery have none here.
    if (a == .xml or b == .xml or a == .jsonpath or b == .jsonpath or a == .tsvector or b == .tsvector or a == .tsquery or b == .tsquery) return null;
    if (a != b and (a == .pg_internal_char or b == .pg_internal_char)) {
        const other = if (a == .pg_internal_char) b else a;
        return if (characterType(other)) .text else null;
    }
    // anyarray operators need the same array type on both sides.
    if (a != b and (types.isArray(a) or types.isArray(b))) return null;
    if (a != b and numericCategory(a) and numericCategory(b) and (a == .float4 or b == .float4)) return .float8;
    // bit and varbit compare with varbit's operators (varbit is preferred).
    if (a != b and bitType(a) and bitType(b)) return .varbit;
    // bpchar with varchar resolves bpchareq (one exact operand, varchar is
    // binary-coercible); any other string mix compares as TEXT.
    if (a != b and characterType(a) and characterType(b) and (a == .bpchar or b == .bpchar))
        return if ((a == .bpchar or a == .varchar) and (b == .bpchar or b == .varchar)) .bpchar else .text;
    return common(a, b);
}

pub fn common(a: Type, b: Type) ?Type {
    if (a == b) return a;
    // cidr values take inet's operators.
    if ((a == .inet and b == .cidr) or (a == .cidr and b == .inet)) return .inet;
    // Arrays unify through their element types (ARRAY[] sub-arrays, ||).
    if (types.elementType(a)) |left| {
        const right = types.elementType(b) orelse return null;
        return types.arrayType(common(left, right) orelse return null);
    }
    if (types.isArray(b)) return null;
    // time -> timetz and time -> interval are implicit one way only.
    if ((a == .time and b == .timetz) or (a == .timetz and b == .time)) return .timetz;
    if ((a == .time and b == .interval) or (a == .interval and b == .time)) return .interval;
    if (bitType(a) and bitType(b)) return a;
    if ((a == .bpchar and stringType(b)) or (stringType(a) and b == .bpchar) or
        (a == .varchar and stringType(b)) or (stringType(a) and b == .varchar)) return characterCommon(a, b);
    if (numericCategory(a) and numericCategory(b)) {
        const high = if (numericRank(a) > numericRank(b)) a else b;
        return high;
    }
    if (datetime(a) and datetime(b)) return if (datetimeRank(a) > datetimeRank(b)) a else b;
    if (stringType(a) and stringType(b)) return .text;
    // int2/int4/int8 -> oid is implicit (catalog OID comparisons).
    if ((a == .oid and (b == .int2 or b == .int4 or b == .int8)) or (b == .oid and (a == .int2 or a == .int4 or a == .int8))) return .oid;
    return null;
}

/// Arithmetic result type over two numeric-category operands. float4 with
/// a non-float operand promotes to float8 (no int/numeric x float4
/// operators exist).
pub fn arithmeticType(a: Type, b: Type) Type {
    if (a == .float8 or b == .float8) return .float8;
    if (a == .float4 or b == .float4) return if (a == b) .float4 else .float8;
    if (a == .numeric or b == .numeric) return .numeric;
    if (a == .int8 or b == .int8) return .int8;
    if (a == .int4 or b == .int4) return .int4;
    return .int2;
}

pub fn integerRange(ty: Type) struct { low: i64, high: i64 } {
    return switch (ty) {
        .int2 => .{ .low = -32768, .high = 32767 },
        .int4 => .{ .low = -2147483648, .high = 2147483647 },
        .oid => .{ .low = 0, .high = 4294967295 },
        else => .{ .low = -9223372036854775808, .high = 9223372036854775807 },
    };
}

pub fn Io(comptime config: types.Config) type {
    const V = types.Values(config);
    const N = numeric.Ops(config.numeric_digits);
    const J = jsonb.Jsonb(config.text_bytes, config.json_depth, config.numeric_digits);
    const TS = text_search.TextSearch(config.text_bytes, config.expr_depth);
    return struct {
        pub const TextSearch = TS;
        pub const Text = V.Text;
        pub const Cell = V.Cell;
        pub const Numerics = N;

        /// Validate PostgreSQL UTF-8 text using the scalar streaming lexer.
        /// NUL is invalid. Callers with C-string input semantics clip first.
        pub fn validTextUtf8(input: []const u8) bool {
            var check: @import("lexer.sig").Utf8Check = .{};
            for (input) |byte| check.feed(byte);
            return check.finish();
        }

        pub const Documents = J;
        pub const SessionValues = SessionType;
        pub const typeInfo = types.typeInfo;
        pub const typeFromOid = types.typeFromOid;
        /// Array types (wire codecs): element types and in-cell arrays.
        pub const elementData = types.elementData;
        pub const arrayData = types.arrayData;
        pub const typeOfData = types.typeOfData;
        pub const dataTypeOf = types.dataTypeOf;
        pub const rangeSubtype = types.rangeSubtype;
        pub const Arrays = V.Arrays;
        pub const Ranges = V.Ranges;
        pub const Records = V.Records;
        pub const ArrayShape = @import("array.sig").Shape;
        /// Largest text form of one cell (codec buffers).
        pub const format_bytes: usize = @as(usize, @max(config.text_bytes * 8, numeric.format_bytes)) + 64;

        fn appendBytes(text: *V.Text, bytes: []const u8) Error!void {
            if (bytes.len > config.text_bytes - text.len) return error.TextCapacity;
            @memcpy(text.bytes[text.len..][0..bytes.len], bytes);
            text.len += bytes.len;
        }

        fn integerText(value: i64, buffer: []u8) []const u8 {
            var digits: [20]u8 = undefined;
            var index: usize = digits.len;
            var magnitude: u64 = if (value < 0) @as(u64, @bitCast(-%value)) else @intCast(value);
            while (true) {
                index -= 1;
                digits[index] = @intCast('0' + magnitude % 10);
                magnitude /= 10;
                if (magnitude == 0) break;
            }
            var at: usize = 0;
            if (value < 0) {
                buffer[0] = '-';
                at = 1;
            }
            @memcpy(buffer[at..][0 .. digits.len - index], digits[index..]);
            return buffer[0 .. at + digits.len - index];
        }

        /// Text output of a non-NULL cell into `buffer` (at least
        /// format_bytes long). `verbose` booleans are true/false (casts,
        /// assignment); otherwise t/f (the output function).
        pub fn format(cell: *const V.Cell, verbose: bool, session: *const Session, buffer: []u8) Error![]const u8 {
            return switch (cell.*) {
                .null_value => buffer[0..0],
                .integer => |value| integerText(value, buffer),
                .boolean => |value| copy(buffer, if (verbose) (if (value) "true" else "false") else (if (value) "t" else "f")),
                .text => |*value| if (value.len > buffer.len) error.TextCapacity else copy(buffer, value.slice()),
                .float4 => |value| float_text.format(f32, value, session.extra_float_digits, buffer),
                .float8 => |value| float_text.format(f64, value, session.extra_float_digits, buffer),
                .numeric => |*value| N.format(value, buffer),
                .date => |value| temporal.formatDate(value, buffer),
                .timestamp => |value| temporal.formatTimestamp(value, null, buffer),
                .timestamptz => |value| temporal.formatTimestamp(value, &session.zone, buffer),
                .interval => |value| temporal.formatInterval(value, buffer),
                .jsonb => |*value| blk: {
                    var out: J.Text = .{ .bytes = buffer };
                    try J.render(value.slice(), 0, &out);
                    break :blk buffer[0..out.len];
                },
                .bpchar => |*value| if (value.len > buffer.len)
                    error.TextCapacity
                else if (value.len != 0 and value.slice()[0] == 0)
                    buffer[0..0]
                else
                    copy(buffer, value.slice()),
                .uuid => |*value| uuid.format(value, buffer),
                .bytea => |*value| bytea.format(value.slice(), buffer),
                .time => |value| time_of_day.format(value, buffer),
                .timetz => |value| time_of_day.formatTz(value, buffer),
                .bits => |*value| value.format(buffer),
                .money => |value| money.format(value, buffer),
                .pg_lsn => |value| catalog_ids.formatLsn(value, buffer),
                .xid8 => |value| catalog_ids.formatXid8(value, buffer),
                .array => |*value| try ArrayText.format(value.slice(), session, buffer),
                .range => |*value| try RangeText.format(value.slice(), session, buffer),
                // inet hides a full-length netmask except in its text cast.
                .inet => |*value| network.format(value, value.cidr or verbose, buffer),
                .macaddr => |*value| network.formatMac(value, buffer),
                .macaddr8 => |*value| network.formatMac8(value, buffer),
                .geo => |*value| geometry.format(value.slice(), session.extra_float_digits, buffer),
                .multirange => |*value| try MultirangeText.format(value.slice(), session, buffer),
                .point => |value| geometric.formatPoint(value, session.extra_float_digits, buffer),
                .box => |value| geometric.formatBox(value, session.extra_float_digits, buffer),
                .xml => |*value| try xml.output(value.slice(), buffer),
                // regtypeout: the type's SQL name, or the number.
                .regtype => |oid| blk: {
                    if (types.regtypeName(oid)) |name| break :blk copy(buffer, name);
                    if (session.sequences) |hook| if (hook.type_name) |name| {
                        if (try name(hook.ptr, oid, buffer)) |used| break :blk buffer[0..used];
                    };
                    break :blk integerText(oid, buffer);
                },
                .regproc => |oid| blk: {
                    if (session.regproc_numeric_output) break :blk integerText(oid, buffer);
                    if (oid == 0) break :blk copy(buffer, "-");
                    if (session.sequences) |hook| if (hook.routine_name) |name| {
                        if (try name(hook.ptr, oid, buffer)) |used| break :blk buffer[0..used];
                    };
                    if (@import("catalog.sig").builtinRoutineName(oid)) |name| break :blk copy(buffer, name);
                    break :blk integerText(oid, buffer);
                },
                // Stored as their canonical output text.
                .tsvector, .tsquery => |*value| copy(buffer, value.slice()),
                .pg_internal_char => |value| if (value == 0)
                    buffer[0..0]
                else if (value < 128)
                    copy(buffer, &.{value})
                else
                    copy(buffer, &.{ '\\', '0' + (value >> 6), '0' + ((value >> 3) & 7), '0' + (value & 7) }),
                .record => |*value| try formatRecord(value.slice(), session, buffer),
            };
        }

        /// record_out (B11 wave 5, composite lane): `(f1,f2,...)`, each
        /// field's output text quoted as rowtypes.c does, NULL as nothing.
        fn formatRecord(bytes: []const u8, session: *const Session, buffer: []u8) Error![]const u8 {
            if (buffer.len < 2) return error.TextCapacity;
            buffer[0] = '(';
            var used: usize = 1;
            var reader = V.Records.Reader.init(bytes);
            var item: V.Records.Field = .{};
            var field_text: [format_bytes]u8 = undefined;
            while (reader.next(&item)) {
                if (reader.index > 1) {
                    if (used == buffer.len) return error.TextCapacity;
                    buffer[used] = ',';
                    used += 1;
                }
                if (item.cell == .null_value) continue;
                const text = try format(&item.cell, false, session, &field_text);
                try record_module.appendQuoted(buffer, &used, text);
            }
            if (used == buffer.len) return error.TextCapacity;
            buffer[used] = ')';
            return buffer[0 .. used + 1];
        }

        /// record_in (B11 wave 5, composite lane) of composite type `oid`
        /// whose fields are `layout`: 22P02 for malformed input (too few or
        /// too many columns, junk after the right parenthesis).
        pub fn parseRecord(input: []const u8, oid: u32, layout: []const u8, session: *const Session) Error!V.Cell {
            var at: usize = 0;
            while (at < input.len and record_module.space(input[at])) at += 1;
            if (at >= input.len or input[at] != '(') return error.InvalidTextRepresentation;
            at += 1;
            var out: V.Text = .{};
            var builder = try V.Records.Builder.begin(&out, oid);
            var fields: catalog_objects.CompositeFields = .{ .bytes = layout };
            var field_text: [format_bytes]u8 = undefined;
            var first = true;
            while (fields.next()) |field| {
                if (!first) {
                    // A missing comma: too few columns.
                    if (at >= input.len or input[at] != ',') return error.InvalidTextRepresentation;
                    at += 1;
                }
                first = false;
                const data_type = types.typeFromOid(field.oid) orelse return error.UnsupportedStatement;
                const scanned = try record_module.scanField(input, &at, &field_text);
                const cell: V.Cell = if (scanned.null_value) .null_value else try parse(types.typeOfData(data_type), field.typmod, field_text[0..scanned.len], session);
                try builder.append(data_type, field.typmod, &cell);
            }
            if (at >= input.len or input[at] != ')') return error.InvalidTextRepresentation;
            at += 1;
            while (at < input.len and record_module.space(input[at])) at += 1;
            if (at != input.len) return error.InvalidTextRepresentation;
            return .{ .record = out };
        }

        /// Record casts: to and from the string types by I/O conversion,
        /// between records when the target is anonymous or the same type,
        /// or when its fields have exactly the value's field types.
        fn castRecord(cell: V.Cell, to: Type, typmod: i32, session: *const Session) Error!V.Cell {
            if (cell == .record) {
                const bytes = cell.record.slice();
                if (to == .record) {
                    if (typmod <= 0 or V.Records.typeOf(bytes) == @as(u32, @intCast(typmod))) return cell;
                    const layout = compositeLayout(session, @intCast(typmod)) orelse return error.CannotCoerce;
                    var fields: catalog_objects.CompositeFields = .{ .bytes = layout };
                    var reader = V.Records.Reader.init(bytes);
                    var item: V.Records.Field = .{};
                    while (fields.next()) |field| {
                        if (!reader.next(&item)) return error.CannotCoerce;
                        if (types.typeOid(item.data_type) != field.oid or item.typmod != field.typmod) return error.CannotCoerce;
                    }
                    if (reader.index != reader.total) return error.CannotCoerce;
                    return .{ .record = V.Records.retyped(bytes, @intCast(typmod)) };
                }
                if (!characterType(to)) return error.CannotCoerce;
                var buffer: [format_bytes]u8 = undefined;
                return cast(try textCell(try format(&cell, false, session, &buffer)), .text, to, typmod, session);
            }
            return switch (cell) {
                .text => |*value| parse(.record, typmod, value.slice(), session),
                .bpchar => |*value| parse(.record, typmod, value.slice(), session),
                else => error.CannotCoerce,
            };
        }

        /// The lseg/line/path/polygon/circle layout (wire codecs).
        pub const Geometry = geometry;

        /// Multirange text I/O (multirange.sig).
        pub const MultirangeText = multirange.MultirangeText(config, @This());
        pub const Multiranges = V.Multiranges;

        /// multirange(range) and the range -> multirange cast.
        pub fn multirangeOf(range_cell: *const V.Cell) Error!V.Cell {
            var set: V.Text = .{};
            var scratch: V.Text = .{};
            const range = V.Ranges.decode(range_cell.range.slice());
            V.Multiranges.empty(types.rangeOfData(range.subtype).?, &set);
            try V.Multiranges.add(&set, &range, &scratch);
            return .{ .multirange = set };
        }

        fn geometryKind(ty: Type) geometry.Kind {
            return switch (ty) {
                .lseg => .lseg,
                .line => .line,
                .path => .path,
                .polygon => .polygon,
                else => .circle,
            };
        }

        /// The function-based geometric casts (B11 wave 4): point(box |
        /// lseg | polygon | circle), box(point | polygon | circle),
        /// lseg(box), circle(box | polygon), polygon(box | circle | path)
        /// and path(polygon).
        pub fn geometryCast(cell: *const V.Cell, to: Type) Error!V.Cell {
            var text: V.Text = .{};
            var out: geometry.Writer = .{ .bytes = &text.bytes };
            const bytes: []const u8 = if (cell.* == .geo) cell.geo.slice() else &.{};
            const kind: ?geometry.Kind = if (cell.* == .geo) geometry.kindOf(bytes) else null;
            switch (to) {
                .point => return .{ .point = switch (cell.*) {
                    .box => |value| geometric.center(value),
                    .geo => switch (kind.?) {
                        .lseg => try geometry.lsegCenter(geometry.lseg(bytes)),
                        .circle => geometry.circle(bytes).center,
                        .polygon => (try geometry.polygonCircle(bytes)).center,
                        else => return error.CannotCoerce,
                    },
                    else => return error.CannotCoerce,
                } },
                .box => return .{ .box = switch (cell.*) {
                    .point => |value| .{ .high = value, .low = value },
                    .geo => switch (kind.?) {
                        .polygon => geometry.boundBox(bytes),
                        .circle => try geometry.circleBox(geometry.circle(bytes)),
                        else => return error.CannotCoerce,
                    },
                    else => return error.CannotCoerce,
                } },
                .lseg => {
                    if (cell.* != .box) return error.CannotCoerce;
                    try geometry.writeLseg(&out, .{ .a = cell.box.high, .b = cell.box.low });
                },
                .circle => {
                    if (cell.* == .box) {
                        try geometry.writeCircle(&out, try geometry.boxCircle(cell.box));
                    } else if (kind == .polygon) {
                        try geometry.writeCircle(&out, try geometry.polygonCircle(bytes));
                    } else return error.CannotCoerce;
                },
                .polygon => {
                    if (cell.* == .box) {
                        try geometry.boxPolygon(cell.box, &out);
                    } else if (kind == .circle) {
                        try geometry.circlePolygon(12, geometry.circle(bytes), &out);
                    } else if (kind == .path) {
                        try geometry.repoint(bytes, .polygon, &out);
                    } else return error.CannotCoerce;
                },
                .path => {
                    if (kind != .polygon) return error.CannotCoerce;
                    try geometry.repoint(bytes, .path, &out);
                },
                else => return error.CannotCoerce,
            }
            text.len = out.len;
            return .{ .geo = text };
        }

        /// Range text I/O and constructors (range_text.sig).
        pub const RangeText = range_text.RangeText(config, @This());

        /// Array text I/O and element-wise casts (array_text.sig).
        pub const ArrayText = array_text.ArrayText(config, @This());

        fn copy(buffer: []u8, value: []const u8) []const u8 {
            @memcpy(buffer[0..value.len], value);
            return buffer[0..value.len];
        }

        pub fn appendCell(text: *V.Text, cell: *const V.Cell, verbose: bool, session: *const Session) Error!void {
            switch (cell.*) {
                .null_value => {},
                .text => |*value| try appendBytes(text, value.slice()),
                else => {
                    var buffer: [format_bytes]u8 = undefined;
                    try appendBytes(text, try format(cell, verbose, session, &buffer));
                },
            }
        }

        pub fn toText(cell: *const V.Cell, verbose: bool, session: *const Session) Error!V.Cell {
            if (cell.* == .null_value) return .null_value;
            if (cell.* == .text) return cell.*;
            if (comptime config.text_bytes >= @sizeOf(usize)) {
                if (V.largeBytes(cell) != null or (aclArray(cell) and session.value_bytes != null)) {
                    const arena = session.value_bytes orelse return error.TextCapacity;
                    const rendered = try format(cell, verbose, session, arena.available());
                    if (rendered.len > config.text_bytes) arena.used += rendered.len;
                    return .{ .text = V.Text.fromValueBytes(rendered) };
                }
            }
            var text: V.Text = .{};
            try appendCell(&text, cell, verbose, session);
            return .{ .text = text };
        }

        fn aclArray(cell: *const V.Cell) bool {
            return cell.* == .array and V.Arrays.elementType(cell.array.slice()) == .aclitem;
        }

        fn clipName(bytes: []const u8) []const u8 {
            if (bytes.len < types.pg_name_bytes) return bytes;
            var end: usize = types.pg_name_bytes - 1;
            while (end != 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
            return bytes[0..end];
        }

        fn textCell(bytes: []const u8) Error!V.Cell {
            var text: V.Text = .{};
            try appendBytes(&text, bytes);
            return .{ .text = text };
        }

        pub fn jsonbCell(source: []const u8) Error!V.Cell {
            return jsonbCellControlled(source, null);
        }

        pub fn jsonbCellControlled(source: []const u8, control: ?*types.ExecutionControl) Error!V.Cell {
            var buffer: J.Buffer = .{};
            try J.parseControlled(source, &buffer, control);
            var text: V.Text = .{};
            try appendBytes(&text, buffer.bytes[0..buffer.len]);
            return .{ .jsonb = text };
        }

        /// Input function of `ty` (typmod applied).
        fn checkedUnsigned(input: numeric.Numeric) Error!V.Cell {
            var value = input;
            if (value.special != .finite or value.negative) return error.IntegerOverflow;
            if (value.dscale != 0) {
                const exact = try N.round(&value, 0);
                if (numeric.compareValues(&value, &exact) != 0) return error.UnsupportedStatement;
                value = exact;
            }
            if (types.mysqlUnsignedValue(&value) == null) return error.IntegerOverflow;
            return .{ .numeric = value };
        }

        /// MySQL explicit integer casts preserve the 64-bit pattern.
        /// Assignment still uses checkedUnsigned/checkedInteger.
        pub fn mysqlIntegerCast(cell: V.Cell, target: Type) Error!V.Cell {
            const bits: u64 = switch (cell) {
                .null_value => return .null_value,
                .integer => |signed| @bitCast(signed),
                .numeric => |*unsigned| types.mysqlUnsignedValue(unsigned) orelse return error.TypeMismatch,
                else => return error.TypeMismatch,
            };
            if (target == .int8) return .{ .integer = @bitCast(bits) };
            if (target != .mysql_bigint_unsigned) return error.TypeMismatch;
            var value: numeric.Numeric = .{};
            value.setCoef(bits);
            return .{ .numeric = value };
        }

        pub fn parse(ty: Type, typmod: i32, input: []const u8, session: *const Session) Error!V.Cell {
            const cell: V.Cell = switch (ty) {
                .int2, .int4, .int8 => .{ .integer = blk: {
                    const value = try expr.parseInteger(input, if (ty == .int2) .int4 else ty);
                    if (ty == .int2 and (value < -32768 or value > 32767)) return error.NumericValueOutOfRange;
                    break :blk value;
                } },
                .oid, .xid => .{ .integer = blk: {
                    const value = expr.parseInteger(input, .int8) catch |err| return if (err == error.IntegerOverflow) error.NumericValueOutOfRange else err;
                    // oidin accepts -2^31..2^32-1, negatives wrap.
                    if (value < -2147483648 or value > 4294967295) return error.NumericValueOutOfRange;
                    break :blk if (value < 0) value + 4294967296 else value;
                } },
                .boolean => .{ .boolean = try expr.parseBoolean(input) },
                .text, .unknown, .json => blk: {
                    if (ty == .json) try J.validateJsonControlled(input, session.control);
                    break :blk try textCell(input);
                },
                .name => try textCell(clipName(input)),
                .numeric => .{ .numeric = try N.parse(input) },
                .mysql_bigint_unsigned => try checkedUnsigned(try N.parse(input)),
                .float4 => .{ .float4 = try float_text.parse(f32, input) },
                .float8 => .{ .float8 = try float_text.parse(f64, input) },
                .date => .{ .date = try temporal.parseDate(input) },
                .timestamp => .{ .timestamp = try temporal.parseTimestamp(input, .timestamp, &session.zone, session.resolver) },
                .timestamptz => .{ .timestamptz = try temporal.parseTimestamp(input, .timestamptz, &session.zone, session.resolver) },
                .interval => .{ .interval = try temporal.parseInterval(input) },
                .jsonb => try jsonbCellControlled(input, session.control),
                .varchar, .bpchar => {
                    try character.validateText(input);
                    return characterCell(input, ty, typmod, .implicit);
                },
                .uuid => .{ .uuid = try uuid.parse(input) },
                .bytea => blk: {
                    var bytes: V.Text = .{};
                    bytes.len = try bytea.parse(input, &bytes.bytes);
                    break :blk .{ .bytea = bytes };
                },
                .time, .timetz => try parseTime(ty, input, session),
                .bit, .varbit => .{ .bits = try V.BitString.parse(input) },
                .money => .{ .money = try money.parse(input) },
                .pg_lsn => .{ .pg_lsn = try catalog_ids.parseLsn(input) },
                .xid8 => .{ .xid8 = try catalog_ids.parseXid8(input) },
                .int4range, .int8range, .numrange, .daterange, .tsrange, .tstzrange => try RangeText.parse(ty, input, session),
                .inet, .cidr => .{ .inet = try network.parse(input, ty == .cidr) },
                .macaddr => .{ .macaddr = try network.parseMac(input) },
                .macaddr8 => .{ .macaddr8 = try network.parseMac8(input) },
                .int4multirange, .int8multirange, .nummultirange, .datemultirange, .tsmultirange, .tstzmultirange => return MultirangeText.parse(ty, input, session),
                .lseg, .line, .path, .polygon, .circle => blk: {
                    var text: V.Text = .{};
                    var writer: geometry.Writer = .{ .bytes = &text.bytes };
                    switch (ty) {
                        .lseg => try geometry.parseLseg(input, &writer),
                        .line => try geometry.parseLine(input, &writer),
                        .path => try geometry.parsePath(input, &writer),
                        .polygon => try geometry.parsePolygon(input, &writer),
                        else => try geometry.parseCircle(input, &writer),
                    }
                    text.len = writer.len;
                    break :blk .{ .geo = text };
                },
                .point => .{ .point = try geometric.parsePoint(input) },
                .box => .{ .box = try geometric.parseBox(input) },
                // xml_in: casts and textual input honor the session XML mode.
                .xml => blk: {
                    if (session.xml_document) {
                        if (!xml.validDocument(input)) return error.InvalidXmlDocument;
                    } else if (!xml.validContent(input)) return error.InvalidXmlContent;
                    break :blk .{ .xml = (try textCell(input)).text };
                },
                // jsonpath_in: the canonical text of the parsed path (B11).
                .jsonpath => blk: {
                    var buffer: [config.text_bytes]u8 = undefined;
                    break :blk try textCell(try jsonpath.Engine(config).canonical(input, &buffer, session.control));
                },
                .regtype => .{ .regtype = types.regtypeInput(input) catch |err| blk: {
                    // A user type name through the catalog hook (composite lane).
                    if (err != error.UndefinedObject) return err;
                    const hook = session.sequences orelse return err;
                    const lookup = hook.type_oid orelse return err;
                    break :blk (try lookup(hook.ptr, input)) orelse return err;
                } },
                .regproc => .{ .regproc = (try routineOid(session, input, true)) orelse return error.UndefinedFunction },
                .aclitem => return error.UnsupportedStatement,
                // void_in ignores its input.
                .void => .{ .text = .{} },
                // record_in: a named composite type's fields (the typmod
                // holds its OID); anonymous records have no input (0A000).
                .record => {
                    if (typmod <= 0) return error.UnsupportedStatement;
                    const layout = compositeLayout(session, @intCast(typmod)) orelse return error.UndefinedObject;
                    return parseRecord(input, @intCast(typmod), layout, session);
                },
                .pg_internal_char => .{ .pg_internal_char = parseInternalChar(input) },
                .tsvector, .tsquery => blk: {
                    var out: TS.Out = .{};
                    if (ty == .tsvector) try TS.vectorIn(input, &out) else try TS.queryIn(input, &out);
                    const text = (try textCell(out.slice())).text;
                    break :blk if (ty == .tsvector) V.Cell{ .tsvector = text } else V.Cell{ .tsquery = text };
                },
                // array_in applies the typmod to every element itself.
                _ => return ArrayText.parse(types.elementType(ty) orelse return error.UndefinedFunction, typmod, input, session),
            };
            return applyTypmod(cell, ty, typmod);
        }

        /// The session zone's offset (seconds west) on the transaction date,
        /// at local time `us` (a TIMETZ without an explicit zone).
        fn sessionZoneWest(zone: *const temporal.Zone, session: *const Session, us: i64) Error!i32 {
            const now = session.transaction_us orelse session.statement_us orelse 0;
            const today = @divFloor(temporal.toLocal(zone, now), temporal.usecs_per_day);
            return time_of_day.zoneWest(zone, today * temporal.usecs_per_day + us);
        }

        fn parseInternalChar(input: []const u8) u8 {
            if (input.len == 0) return 0;
            if (input.len == 4 and input[0] == '\\') {
                var byte: u8 = 0;
                for (input[1..]) |digit| {
                    if (digit < '0' or digit > '7') return input[0];
                    byte = (byte << 3) | (digit - '0');
                }
                return byte;
            }
            return input[0];
        }

        fn parseTime(ty: Type, input: []const u8, session: *const Session) Error!V.Cell {
            const parsed = try time_of_day.parse(input);
            var zone_west = parsed.zone;
            if (parsed.named) |name| {
                var zone: temporal.Zone = .{};
                const lookup = session.resolver.lookup orelse return error.InvalidParameterValue;
                lookup(session.resolver.context, name, &zone) catch return error.InvalidParameterValue;
                if (ty == .timetz) {
                    const day = parsed.date orelse @divFloor(temporal.toLocal(&zone, session.transaction_us orelse session.statement_us orelse 0), temporal.usecs_per_day);
                    // A leading date far outside the timestamp range has no
                    // zone offset (22008), never an overflow.
                    const midnight = @mulWithOverflow(day, temporal.usecs_per_day);
                    if (midnight[1] != 0 or !temporal.validTimestamp(midnight[0])) return error.DatetimeFieldOverflow;
                    zone_west = try time_of_day.zoneWest(&zone, midnight[0] + parsed.us);
                }
            }
            if (ty == .time) return .{ .time = parsed.us };
            const west = zone_west orelse try sessionZoneWest(&session.zone, session, parsed.us);
            return .{ .timetz = .{ .us = parsed.us, .zone = west } };
        }

        /// Input of a cast's literal (`'...'::type(n)`): PostgreSQL passes typmod
        /// -1 to the input function and then applies the explicit length
        /// coercion, so VARCHAR/CHAR truncate here instead of raising 22001.
        pub fn parseCast(ty: Type, typmod: i32, input: []const u8, session: *const Session) Error!V.Cell {
            if (ty == .varchar or ty == .bpchar) {
                try character.validateText(input);
                return characterCell(input, ty, typmod, .explicit);
            }
            return applyTypmodExplicit(try parse(ty, -1, input, session), ty, typmod);
        }

        /// A CHAR(n)/VARCHAR(n) value of `bytes` coerced to `typmod`.
        fn characterCell(bytes: []const u8, ty: Type, typmod: i32, mode: character.Mode) Error!V.Cell {
            const shape = if (ty == .bpchar) try character.bpchar(bytes, typmod, mode) else try character.varchar(bytes, typmod, mode);
            if (shape.pad > config.text_bytes or shape.keep > config.text_bytes - shape.pad) return error.TextCapacity;
            var text: V.Text = .{ .len = shape.keep + shape.pad };
            @memcpy(text.bytes[0..shape.keep], bytes[0..shape.keep]);
            @memset(text.bytes[shape.keep..text.len], ' ');
            return if (ty == .bpchar) .{ .bpchar = text } else .{ .text = text };
        }

        /// Length coercion of the explicit-cast kind (truncation, padding).
        pub fn applyTypmodExplicit(cell: V.Cell, ty: Type, typmod: i32) Error!V.Cell {
            if (typmod < 0 or cell == .null_value) return cell;
            if (cell == .array) return ArrayText.applyTypmod(cell.array.slice(), types.elementType(ty) orelse return cell, typmod, true);
            return switch (ty) {
                .varchar => switch (cell) {
                    .text => |*value| characterCell(value.slice(), .varchar, typmod, .explicit),
                    else => cell,
                },
                .bpchar => switch (cell) {
                    .bpchar => |*value| characterCell(value.slice(), .bpchar, typmod, .explicit),
                    else => cell,
                },
                .bit, .varbit => switch (cell) {
                    .bits => |*value| .{ .bits = try value.resized(try bit_string.coercedLength(value.len, typmod, ty == .bit, .explicit)) },
                    else => cell,
                },
                else => applyTypmod(cell, ty, typmod),
            };
        }

        /// Length coercion: NUMERIC(p,s) and TIMESTAMP[TZ](p).
        pub fn applyTypmod(cell: V.Cell, ty: Type, typmod: i32) Error!V.Cell {
            if (typmod < 0 or cell == .null_value) return cell;
            if (cell == .array) return ArrayText.applyTypmod(cell.array.slice(), types.elementType(ty) orelse return cell, typmod, false);
            return switch (ty) {
                .numeric => .{ .numeric = try N.applyTypmod(&cell.numeric, typmod) },
                .timestamp => .{ .timestamp = temporal.roundTimestamp(cell.timestamp, typmod) },
                .timestamptz => .{ .timestamptz = temporal.roundTimestamp(cell.timestamptz, typmod) },
                .varchar => switch (cell) {
                    .text => |*value| try characterCell(value.slice(), .varchar, typmod, .implicit),
                    else => cell,
                },
                .bpchar => switch (cell) {
                    .bpchar => |*value| try characterCell(value.slice(), .bpchar, typmod, .implicit),
                    else => cell,
                },
                .time => switch (cell) {
                    .time => |value| .{ .time = time_of_day.round(value, typmod) },
                    else => cell,
                },
                .timetz => switch (cell) {
                    .timetz => |value| .{ .timetz = .{ .us = time_of_day.round(value.us, typmod), .zone = value.zone } },
                    else => cell,
                },
                .bit, .varbit => switch (cell) {
                    .bits => |*value| blk: {
                        _ = try bit_string.coercedLength(value.len, typmod, ty == .bit, .implicit);
                        break :blk cell;
                    },
                    else => cell,
                },
                else => cell,
            };
        }

        fn floatToNumeric(value: f64, significant: usize) Error!numeric.Numeric {
            if (value != value) return numeric.nan();
            if (float_text.isInf(value)) return .{ .special = if (value < 0) .ninf else .pinf };
            if (value == 0) return .{};
            var buffer: [64]u8 = undefined;
            const text = float_text.roundedText(f64, value, significant, &buffer);
            // %g: drop trailing fraction zeros before numeric_in.
            var mantissa_end: usize = 0;
            while (mantissa_end < text.len and text[mantissa_end] != 'e') mantissa_end += 1;
            var trimmed = mantissa_end;
            var has_point = false;
            for (text[0..mantissa_end]) |c| if (c == '.') {
                has_point = true;
            };
            if (has_point) {
                while (trimmed > 0 and text[trimmed - 1] == '0') trimmed -= 1;
                if (trimmed > 0 and text[trimmed - 1] == '.') trimmed -= 1;
            }
            var joined: [64]u8 = undefined;
            @memcpy(joined[0..trimmed], text[0..trimmed]);
            @memcpy(joined[trimmed..][0 .. text.len - mantissa_end], text[mantissa_end..]);
            return N.parse(joined[0 .. trimmed + text.len - mantissa_end]);
        }

        fn numericToFloat(comptime T: type, value: *const numeric.Numeric) Error!T {
            switch (value.special) {
                .nan => return float_text.nan(T),
                .pinf => return float_text.inf(T),
                .ninf => return -float_text.inf(T),
                .finite => {},
            }
            var buffer: [numeric.format_bytes]u8 = undefined;
            return float_text.parse(T, N.format(value, &buffer));
        }

        fn checkedInteger(value: i64, ty: Type) Error!i64 {
            const range = integerRange(ty);
            if (value < range.low or value > range.high) return if (ty == .int4 or ty == .int8) error.IntegerOverflow else error.NumericValueOutOfRange;
            return value;
        }

        /// Explicit, assignment or implicit cast of a value of type `from`.
        pub fn cast(cell: V.Cell, from: Type, to: Type, typmod: i32, session: *const Session) Error!V.Cell {
            if (cell == .null_value) return .null_value;
            if (from == to and typmod < 0) return cell;
            if (cell == .pg_internal_char) {
                if (to == .int4) return .{ .integer = @as(i8, @bitCast(cell.pg_internal_char)) };
                if (to == .bpchar) return characterCell(&.{cell.pg_internal_char}, .bpchar, typmod, .explicit);
                if (!characterType(to)) return error.CannotCoerce;
                var buffer: [4]u8 = undefined;
                return cast(try textCell(try format(&cell, true, session, &buffer)), .text, to, typmod, session);
            }
            if (cell == .xml and to != .xml) {
                // xml -> text is binary coercible: the stored text (a wide
                // SQL/XML result keeps pointing at its bytes).
                if (!characterType(to)) return error.CannotCoerce;
                if (cell.xml.indirect()) return cast(.{ .text = cell.xml }, .text, to, typmod, session);
                return cast(try textCell(cell.xml.slice()), .text, to, typmod, session);
            }
            if ((cell == .regtype and to != .regtype) or (cell == .regproc and to != .regproc)) {
                const oid = if (cell == .regtype) cell.regtype else cell.regproc;
                if (to == .oid or to == .int8) return .{ .integer = oid };
                if (to == .int4) return .{ .integer = @as(i32, @bitCast(oid)) };
                if (!characterType(to)) return error.CannotCoerce;
                var buffer: [format_bytes]u8 = undefined;
                return cast(try textCell(try format(&cell, true, session, &buffer)), .text, to, typmod, session);
            }
            if ((to == .regtype or to == .regproc) and cell == .integer) {
                // int8 -> OID aliases checks the range; int4 wraps.
                const value = cell.integer;
                const oid: u32 = if (from == .int4 or from == .int2)
                    @bitCast(@as(i32, @intCast(value)))
                else if (value >= 0 and value <= 4294967295)
                    @intCast(value)
                else
                    return error.NumericValueOutOfRange;
                return if (to == .regtype) .{ .regtype = oid } else .{ .regproc = oid };
            }
            if ((to == .regtype or to == .regproc) and cell == .text) return parse(to, -1, cell.text.slice(), session);
            if (cell == .array and types.isArray(to)) {
                if (from == to) return applyTypmodExplicit(cell, to, typmod);
                return ArrayText.cast(cell.array.slice(), types.elementType(from) orelse return error.CannotCoerce, types.elementType(to).?, typmod, session);
            }
            if (cell == .record or to == .record) return castRecord(cell, to, typmod, session);
            if (cell == .bpchar and to != .bpchar) {
                // text(bpchar) drops trailing spaces for the string types;
                // other targets read bpcharout's padded text (I/O conversion).
                const bytes = cell.bpchar.slice();
                const text = try textCell(if (characterType(to)) character.trimmed(bytes) else bytes);
                return cast(text, .text, to, typmod, session);
            }
            const out: V.Cell = switch (to) {
                .aclitem => return error.UnsupportedStatement,
                // void_in ignores its input (I/O conversion from a string).
                .void => V.Cell{ .text = .{} },
                .record => unreachable,
                .pg_internal_char => switch (cell) {
                    .integer => |value| blk: {
                        if (value < -128 or value > 127) return error.NumericValueOutOfRange;
                        break :blk .{ .pg_internal_char = @bitCast(@as(i8, @intCast(value))) };
                    },
                    .text => |*value| .{ .pg_internal_char = parseInternalChar(value.slice()) },
                    .bpchar => |*value| .{ .pg_internal_char = parseInternalChar(value.slice()) },
                    else => return error.CannotCoerce,
                },
                .int2, .int4, .int8 => switch (cell) {
                    .integer => |value| blk: {
                        if (from == .oid and to == .int4) break :blk V.Cell{ .integer = if (value > 2147483647) value - 4294967296 else value };
                        break :blk V.Cell{ .integer = try checkedInteger(value, to) };
                    },
                    .boolean => |value| V.Cell{ .integer = @intFromBool(value) },
                    .numeric => |*value| blk: {
                        const range = integerRange(to);
                        break :blk V.Cell{ .integer = N.toInt(value, range.low, range.high) catch |err| return if (err == error.NumericValueOutOfRange and to != .int2) error.IntegerOverflow else err };
                    },
                    .float4 => |value| blk: {
                        const range = integerRange(to);
                        break :blk V.Cell{ .integer = float_text.toInt(value, range.low, range.high) catch return if (to == .int2) error.NumericValueOutOfRange else error.IntegerOverflow };
                    },
                    .float8 => |value| blk: {
                        const range = integerRange(to);
                        break :blk V.Cell{ .integer = float_text.toInt(value, range.low, range.high) catch return if (to == .int2) error.NumericValueOutOfRange else error.IntegerOverflow };
                    },
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    // bittoint4 / bittoint8.
                    .bits => |*value| V.Cell{ .integer = try value.toInteger(if (to == .int4) 32 else 64) },
                    else => return error.CannotCoerce,
                },
                .oid, .xid => switch (cell) {
                    .integer => |value| V.Cell{ .integer = if (from == .int4 and value < 0) value + 4294967296 else try checkedInteger(value, .oid) },
                    .text => |*value| try parse(.oid, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .boolean => switch (cell) {
                    .integer => |value| V.Cell{ .boolean = value != 0 },
                    .boolean => cell,
                    .text => |*value| V.Cell{ .boolean = try expr.parseBoolean(value.slice()) },
                    else => return error.CannotCoerce,
                },
                .mysql_bigint_unsigned => switch (cell) {
                    .integer => |value| try checkedUnsigned(N.fromInt(value)),
                    .numeric => |value| try checkedUnsigned(value),
                    .text => |*value| try parse(.mysql_bigint_unsigned, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .numeric => switch (cell) {
                    .integer => |value| V.Cell{ .numeric = N.fromInt(value) },
                    .numeric => cell,
                    .float4 => |value| V.Cell{ .numeric = try floatToNumeric(value, 6) },
                    .float8 => |value| V.Cell{ .numeric = try floatToNumeric(value, 15) },
                    .text => |*value| try parse(.numeric, -1, value.slice(), session),
                    // cash_numeric: the amount with scale 2.
                    .money => |value| blk: {
                        var digits: [32]u8 = undefined;
                        break :blk V.Cell{ .numeric = try N.parse(money.decimal(value, &digits)) };
                    },
                    else => return error.CannotCoerce,
                },
                .float4 => switch (cell) {
                    .integer => |value| V.Cell{ .float4 = @floatFromInt(value) },
                    .numeric => |*value| V.Cell{ .float4 = try numericToFloat(f32, value) },
                    .float4 => cell,
                    .float8 => |value| blk: {
                        const narrowed: f32 = @floatCast(value);
                        if (float_text.isInf(narrowed) and !float_text.isInf(value)) return error.NumericValueOutOfRange;
                        if (narrowed == 0 and value != 0) return error.NumericValueOutOfRange;
                        break :blk V.Cell{ .float4 = narrowed };
                    },
                    .text => |*value| try parse(.float4, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .float8 => switch (cell) {
                    .integer => |value| V.Cell{ .float8 = @floatFromInt(value) },
                    .numeric => |*value| V.Cell{ .float8 = try numericToFloat(f64, value) },
                    .float4 => |value| V.Cell{ .float8 = value },
                    .float8 => cell,
                    .text => |*value| try parse(.float8, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .text, .name => blk: {
                    if (V.largeBytes(&cell) != null or aclArray(&cell)) {
                        const text = try toText(&cell, true, session);
                        break :blk if (to == .name) try textCell(clipName(text.text.slice())) else text;
                    }
                    if (cell == .text) {
                        const bytes = cell.text.slice();
                        break :blk try textCell(if (to == .name) clipName(bytes) else bytes);
                    }
                    var buffer: [format_bytes]u8 = undefined;
                    const bytes = try format(&cell, true, session, &buffer);
                    break :blk try textCell(if (to == .name) clipName(bytes) else bytes);
                },
                .json => switch (cell) {
                    .text => |*value| blk: {
                        if (from != .json) try J.validateJsonControlled(value.slice(), session.control);
                        break :blk cell;
                    },
                    .jsonb => blk: {
                        var buffer: [format_bytes]u8 = undefined;
                        break :blk try textCell(try format(&cell, true, session, &buffer));
                    },
                    else => return error.CannotCoerce,
                },
                .jsonb => switch (cell) {
                    .text => |*value| try jsonbCellControlled(value.slice(), session.control),
                    .jsonb => cell,
                    else => return error.CannotCoerce,
                },
                .date => switch (cell) {
                    .date => cell,
                    .timestamp => |value| V.Cell{ .date = temporal.timestampToDate(value) },
                    .timestamptz => |value| V.Cell{ .date = temporal.timestampToDate(if (temporal.finiteTimestamp(value)) temporal.toLocal(&session.zone, value) else value) },
                    .text => |*value| try parse(.date, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .timestamp => switch (cell) {
                    .date => |value| V.Cell{ .timestamp = try temporal.dateToTimestamp(value) },
                    .timestamp => cell,
                    .timestamptz => |value| V.Cell{ .timestamp = if (temporal.finiteTimestamp(value)) temporal.toLocal(&session.zone, value) else value },
                    .text => |*value| try parse(.timestamp, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .timestamptz => switch (cell) {
                    .date => |value| blk: {
                        const local = try temporal.dateToTimestamp(value);
                        break :blk V.Cell{ .timestamptz = if (temporal.finiteTimestamp(local)) try temporal.toUtc(&session.zone, local) else local };
                    },
                    .timestamp => |value| V.Cell{ .timestamptz = if (temporal.finiteTimestamp(value)) try temporal.toUtc(&session.zone, value) else value },
                    .timestamptz => cell,
                    .text => |*value| try parse(.timestamptz, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .interval => switch (cell) {
                    .interval => cell,
                    .text => |*value| try parse(.interval, -1, value.slice(), session),
                    .time => |value| V.Cell{ .interval = .{ .us = value } },
                    else => return error.CannotCoerce,
                },
                .unknown => cell,
                .varchar => switch (cell) {
                    .text => cell,
                    else => try toText(&cell, true, session),
                },
                .bpchar => switch (cell) {
                    .text => |value| V.Cell{ .bpchar = value },
                    .bpchar => cell,
                    else => .{ .bpchar = (try toText(&cell, true, session)).text },
                },
                .uuid => switch (cell) {
                    .uuid => cell,
                    .text => |*value| try parse(.uuid, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .bytea => switch (cell) {
                    .bytea => cell,
                    .text => |*value| try parse(.bytea, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .time => switch (cell) {
                    .time => cell,
                    .timetz => |value| V.Cell{ .time = value.us },
                    // timestamp_time / timestamptz_time: infinity is NULL.
                    .timestamp => |value| if (temporal.finiteTimestamp(value)) V.Cell{ .time = time_of_day.ofTimestamp(value) } else @as(V.Cell, .null_value),
                    .timestamptz => |value| if (temporal.finiteTimestamp(value)) V.Cell{ .time = time_of_day.ofTimestamp(temporal.toLocal(&session.zone, value)) } else @as(V.Cell, .null_value),
                    .interval => |value| V.Cell{ .time = time_of_day.fromInterval(value) },
                    .text => |*value| try parse(.time, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .money => switch (cell) {
                    .money => cell,
                    // int4_cash / int8_cash.
                    .integer => |value| V.Cell{ .money = try money.fromInteger(value) },
                    // numeric_cash: amount * 100 rounded half away from zero.
                    .numeric => |*value| blk: {
                        const hundred = N.fromInt(money.scale);
                        const cents = try N.mul(value, &hundred);
                        break :blk V.Cell{ .money = try N.toInt(&cents, -9223372036854775808, 9223372036854775807) };
                    },
                    .text => |*value| try parse(.money, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .pg_lsn, .xid8 => switch (cell) {
                    .pg_lsn, .xid8 => cell,
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .inet => switch (cell) {
                    .inet => |value| blk: {
                        var out = value;
                        out.cidr = false;
                        break :blk V.Cell{ .inet = out };
                    },
                    .text => |*value| try parse(.inet, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                // cidr(inet): the host bits are cleared.
                .cidr => switch (cell) {
                    .inet => |*value| V.Cell{ .inet = network.network(value) },
                    .text => |*value| try parse(.cidr, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .int4multirange, .int8multirange, .nummultirange, .datemultirange, .tsmultirange, .tstzmultirange => switch (cell) {
                    .multirange => cell,
                    .range => try multirangeOf(&cell),
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .lseg, .line, .path, .polygon, .circle => switch (cell) {
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    .geo => if (geometryKind(to) == geometry.kindOf(cell.geo.slice())) cell else try geometryCast(&cell, to),
                    .box => try geometryCast(&cell, to),
                    else => return error.CannotCoerce,
                },
                .macaddr8 => switch (cell) {
                    .macaddr8 => cell,
                    .macaddr => |*value| V.Cell{ .macaddr8 = network.mac8FromMac(value) },
                    .text => |*value| try parse(.macaddr8, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .macaddr => switch (cell) {
                    .macaddr => cell,
                    .macaddr8 => |*value| V.Cell{ .macaddr = try network.macFromMac8(value) },
                    .text => |*value| try parse(.macaddr, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .xml => switch (cell) {
                    .text => |*value| try parse(.xml, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .jsonpath => switch (cell) {
                    .text => |*value| try parse(.jsonpath, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .tsvector, .tsquery => switch (cell) {
                    .tsvector, .tsquery => cell,
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                // Integers and text are converted above.
                .regtype => switch (cell) {
                    .regtype => cell,
                    else => return error.CannotCoerce,
                },
                .regproc => switch (cell) {
                    .regproc => cell,
                    else => return error.CannotCoerce,
                },
                .point, .box => switch (cell) {
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    else => if (@as(V.CellTag, cell) == V.cellTag(types.dataTypeOf(to))) cell else try geometryCast(&cell, to),
                },
                .int4range, .int8range, .numrange, .daterange, .tsrange, .tstzrange => switch (cell) {
                    .range => cell,
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                // Arrays from text by array_in (array -> array is above).
                _ => switch (cell) {
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .bit, .varbit => switch (cell) {
                    .bits => cell,
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    // bitfromint4 / bitfromint8: BIT(n), n defaulting to 1.
                    .integer => |value| if (to == .bit and (from == .int4 or from == .int8))
                        V.Cell{ .bits = try V.BitString.fromInteger(value, if (from == .int4) 32 else 64, if (typmod > 0) @intCast(typmod) else 1) }
                    else
                        return error.CannotCoerce,
                    else => return error.CannotCoerce,
                },
                .timetz => switch (cell) {
                    .timetz => cell,
                    .time => |value| V.Cell{ .timetz = .{ .us = value, .zone = try sessionZoneWest(&session.zone, session, value) } },
                    .timestamptz => |value| blk: {
                        if (!temporal.finiteTimestamp(value)) break :blk @as(V.Cell, .null_value);
                        const local = temporal.toLocal(&session.zone, value);
                        const east = @divFloor(local - value, temporal.usecs_per_second);
                        break :blk V.Cell{ .timetz = .{ .us = time_of_day.ofTimestamp(local), .zone = @intCast(-east) } };
                    },
                    .text => |*value| try parse(.timetz, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
            };
            return applyTypmodExplicit(out, to, typmod);
        }

        // ---- operators --------------------------------------------------

        const F8 = float_text.ArithmeticOf(f64);
        const F4 = float_text.ArithmeticOf(f32);

        /// + - * / % over same-typed numeric operands (the binder casts
        /// both sides to the operator's type) and the datetime operators.
        pub fn arithmetic(op: ast.Op, left: *const V.Cell, right: *const V.Cell, result: Type, session: *const Session) Error!V.Cell {
            if (try timeArithmetic(op, left, right)) |cell| return cell;
            if (try moneyArithmetic(op, left, right)) |cell| return cell;
            if (try lsnArithmetic(op, left, right)) |cell| return cell;
            if (left.* == .range and right.* == .range) return rangeArithmetic(op, left, right);
            switch (left.*) {
                .integer => |a| switch (right.*) {
                    .integer => |b| {
                        const value = try expr.arithmetic(op, .int8, a, b);
                        return .{ .integer = try checkedInteger(value, result) };
                    },
                    .date => |b| return .{ .date = try temporal.datePlusDays(b, a) },
                    else => {},
                },
                .numeric => |*a| {
                    const b = &right.numeric;
                    return .{ .numeric = switch (op) {
                        .add => try N.add(a, b),
                        .sub => try N.sub(a, b),
                        .mul => try N.mul(a, b),
                        .div => try N.div(a, b),
                        .mod => try N.mod(a, b),
                        else => unreachable,
                    } };
                },
                .float8 => |a| {
                    const b = right.float8;
                    return .{ .float8 = switch (op) {
                        .add => try F8.add(a, b),
                        .sub => try F8.sub(a, b),
                        .mul => try F8.mul(a, b),
                        .div => try F8.div(a, b),
                        else => return error.UndefinedFunction,
                    } };
                },
                .float4 => |a| {
                    const b = right.float4;
                    return .{ .float4 = switch (op) {
                        .add => try F4.add(a, b),
                        .sub => try F4.sub(a, b),
                        .mul => try F4.mul(a, b),
                        .div => try F4.div(a, b),
                        else => return error.UndefinedFunction,
                    } };
                },
                .date => |a| switch (right.*) {
                    .time => |b| return .{ .timestamp = try time_of_day.dateTime(a, b) },
                    .timetz => |b| return .{ .timestamptz = try dateTimeTz(a, b) },
                    .integer => |b| return .{ .date = try temporal.datePlusDays(a, if (op == .sub) -b else b) },
                    .date => |b| {
                        if (!temporal.finiteDate(a) or !temporal.finiteDate(b)) return error.DatetimeFieldOverflow;
                        return .{ .integer = @as(i64, a) - b };
                    },
                    else => {},
                },
                .timestamp => |a| switch (right.*) {
                    .interval => |b| return .{ .timestamp = try temporal.timestampPlus(a, if (op == .sub) try temporal.negateInterval(b) else b) },
                    .timestamp => |b| return .{ .interval = try temporal.timestampDifference(a, b) },
                    else => {},
                },
                .timestamptz => |a| switch (right.*) {
                    .interval => |b| return .{ .timestamptz = try temporal.timestamptzPlus(a, if (op == .sub) try temporal.negateInterval(b) else b, &session.zone) },
                    .timestamptz => |b| return .{ .interval = try temporal.timestampDifference(a, b) },
                    else => {},
                },
                .interval => |a| switch (right.*) {
                    .time => |b| return .{ .time = time_of_day.plus(b, a, false) },
                    .timetz => |b| return .{ .timetz = .{ .us = time_of_day.plus(b.us, a, false), .zone = b.zone } },
                    .interval => |b| return .{ .interval = try temporal.addIntervals(a, if (op == .sub) try temporal.negateInterval(b) else b) },
                    .timestamp => |b| return .{ .timestamp = try temporal.timestampPlus(b, a) },
                    .timestamptz => |b| return .{ .timestamptz = try temporal.timestamptzPlus(b, a, &session.zone) },
                    else => {},
                },
                else => {},
            }
            return error.UndefinedFunction;
        }

        /// time - time, time +- interval, time + date and the TIMETZ forms.
        fn timeArithmetic(op: ast.Op, left: *const V.Cell, right: *const V.Cell) Error!?V.Cell {
            switch (left.*) {
                .time => |a| switch (right.*) {
                    .time => |b| if (op == .sub) return .{ .interval = .{ .us = a - b } },
                    .interval => |b| return .{ .time = time_of_day.plus(a, b, op == .sub) },
                    .date => |b| if (op == .add) return .{ .timestamp = try time_of_day.dateTime(b, a) },
                    else => {},
                },
                .timetz => |a| switch (right.*) {
                    .interval => |b| return .{ .timetz = .{ .us = time_of_day.plus(a.us, b, op == .sub), .zone = a.zone } },
                    .date => |b| if (op == .add) return .{ .timestamptz = try dateTimeTz(b, a) },
                    else => {},
                },
                else => {},
            }
            return null;
        }

        /// pg_lsn operators (pg_lsn.c): pg_lsn - pg_lsn -> numeric, and
        /// pg_lsn +- numeric / numeric + pg_lsn -> pg_lsn. The sum goes through
        /// numeric and back (numeric_pg_lsn rounds to an integer): NaN bytes
        /// are 22023, an infinite result 0A000 and anything outside
        /// 0..2^64-1 is 22003.
        fn lsnArithmetic(op: ast.Op, left: *const V.Cell, right: *const V.Cell) Error!?V.Cell {
            if (left.* == .pg_lsn and right.* == .pg_lsn) {
                if (op != .sub) return error.UndefinedFunction;
                const a = try lsnNumeric(left.pg_lsn);
                const b = try lsnNumeric(right.pg_lsn);
                return .{ .numeric = try N.sub(&a, &b) };
            }
            const lsn_left = left.* == .pg_lsn and right.* == .numeric;
            const lsn_right = left.* == .numeric and right.* == .pg_lsn;
            if (!lsn_left and !lsn_right) return null;
            if (op != .add and !(op == .sub and lsn_left)) return error.UndefinedFunction;
            const bytes = if (lsn_left) &right.numeric else &left.numeric;
            if (bytes.special == .nan) return error.InvalidParameterValue;
            const position = try lsnNumeric(if (lsn_left) left.pg_lsn else right.pg_lsn);
            const sum = if (op == .add) try N.add(&position, bytes) else try N.sub(&position, bytes);
            if (sum.special != .finite) return error.UnsupportedStatement;
            const rounded = try N.round(&sum, 0);
            const raw = rounded.coef();
            if ((rounded.negative and raw != 0) or raw > 0xffffffffffffffff) return error.NumericValueOutOfRange;
            return .{ .pg_lsn = @intCast(raw) };
        }

        /// range + range (union), * (intersection) and - (difference).
        fn rangeArithmetic(op: ast.Op, left: *const V.Cell, right: *const V.Cell) Error!V.Cell {
            const a = V.Ranges.decode(left.range.slice());
            const b = V.Ranges.decode(right.range.slice());
            const result = switch (op) {
                .add => try V.Ranges.merge(&a, &b),
                .mul => try V.Ranges.intersect(&a, &b),
                .sub => try V.Ranges.minus(&a, &b),
                else => return error.UndefinedFunction,
            };
            return RangeText.encoded(&result);
        }

        fn lsnNumeric(value: u64) Error!numeric.Numeric {
            if (value != 0 and numeric.digitCount(value) > config.numeric_digits) return error.NumericCapacity;
            var out: numeric.Numeric = .{};
            out.setCoef(value);
            return out;
        }

        /// MONEY operators (cash.c): money +- money, money * / integer or
        /// float8, number * money and money / money (float8).
        fn moneyArithmetic(op: ast.Op, left: *const V.Cell, right: *const V.Cell) Error!?V.Cell {
            switch (left.*) {
                .money => |a| switch (right.*) {
                    .money => |b| return switch (op) {
                        .add => .{ .money = try money.add(a, b) },
                        .sub => .{ .money = try money.sub(a, b) },
                        .div => .{ .float8 = try money.ratio(a, b) },
                        else => error.UndefinedFunction,
                    },
                    .integer => |b| return switch (op) {
                        .mul => .{ .money = try money.mulInteger(a, b) },
                        .div => .{ .money = try money.divInteger(a, b) },
                        else => error.UndefinedFunction,
                    },
                    .float8, .float4 => {
                        const b: f64 = if (right.* == .float8) right.float8 else right.float4;
                        return switch (op) {
                            .mul => .{ .money = try money.mulFloat(a, b) },
                            .div => .{ .money = try money.divFloat(a, b) },
                            else => error.UndefinedFunction,
                        };
                    },
                    else => {},
                },
                .integer => |a| if (right.* == .money and op == .mul) return .{ .money = try money.mulInteger(right.money, a) },
                .float8 => |a| if (right.* == .money and op == .mul) return .{ .money = try money.mulFloat(right.money, a) },
                .float4 => |a| if (right.* == .money and op == .mul) return .{ .money = try money.mulFloat(right.money, a) },
                else => {},
            }
            return null;
        }

        /// date + timetz: the local date and time at the value's zone.
        fn dateTimeTz(days: i32, value: time_of_day.TimeTz) Error!i64 {
            const local = try time_of_day.dateTime(days, value.us);
            if (!temporal.finiteTimestamp(local)) return local;
            const sum = @addWithOverflow(local, @as(i64, value.zone) * temporal.usecs_per_second);
            if (sum[1] != 0 or !temporal.validTimestamp(sum[0])) return error.DatetimeFieldOverflow;
            return sum[0];
        }

        pub fn negate(cell: *const V.Cell, ty: Type) Error!V.Cell {
            return switch (cell.*) {
                .integer => |value| blk: {
                    if (value == -9223372036854775808) return error.IntegerOverflow;
                    break :blk .{ .integer = try checkedInteger(-value, ty) };
                },
                .numeric => |value| .{ .numeric = N.negate(value) },
                .float4 => |value| .{ .float4 = -value },
                .float8 => |value| .{ .float8 = -value },
                .interval => |value| .{ .interval = try temporal.negateInterval(value) },
                else => error.UndefinedFunction,
            };
        }

        /// AT TIME ZONE: timestamptz -> timestamp in the zone, timestamp ->
        /// timestamptz interpreting it as local time in the zone.
        pub fn atZone(cell: *const V.Cell, zone_name: []const u8, session: *const Session) Error!V.Cell {
            var zone: temporal.Zone = .{};
            try resolveZone(zone_name, session, &zone);
            return switch (cell.*) {
                .timestamptz => |value| .{ .timestamp = if (temporal.finiteTimestamp(value)) temporal.toLocal(&zone, value) else value },
                .timestamp => |value| .{ .timestamptz = if (temporal.finiteTimestamp(value)) try temporal.toUtc(&zone, value) else value },
                else => error.UndefinedFunction,
            };
        }

        pub fn resolveZone(name: []const u8, session: *const Session, zone: *temporal.Zone) Error!void {
            if (types.keyword(name, "utc") or types.keyword(name, "gmt") or types.keyword(name, "z") or types.keyword(name, "zulu")) {
                zone.* = .{};
                return;
            }
            const lookup = session.resolver.lookup orelse return error.InvalidParameterValue;
            lookup(session.resolver.context, name, zone) catch return error.InvalidParameterValue;
        }
    };
}
