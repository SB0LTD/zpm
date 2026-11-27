//! Kind-3 change records (Layer 0, design Â§4.6).
//!
//! A record is architecture-independent little-endian bytes:
//!   header: version u16 (= 1), flags u16 (= 0), op_count u32
//!   ops, each: tag u8 then its fields
//!     1 create_table  oid u32, name, expr_format_version u16 (= 1),
//!                     column_count u8, columns: name, type_oid u32,
//!                     typmod i32 (-1, NUMERIC(p,s), TIMESTAMP[TZ](p) or
//!                     VARCHAR(n)/CHAR(n) n + 4),
//!                     flags u8 (1 not null, 2 primary key, bits 2..4 the
//!                     default kind: 1 DEFAULT, 2 identity ALWAYS, 3 identity
//!                     BY DEFAULT, 4 GENERATED ... STORED),
//!                     expression_len u16 + canonical expression source text
//!                     (DEFAULT / generation; 0 otherwise); with
//!                     expr_format_version 2 (written only when needed, so
//!                     version-1 records stay byte-identical) then:
//!                     namespace u32, constraint_count u8, constraints: kind
//!                     u8 (1 CHECK, 2 UNIQUE, 3 PRIMARY KEY), name, flags u8
//!                     (1 NULLS NOT DISTINCT), key column_count u8 + column
//!                     indexes u8, CHECK text_len u16 + source text
//!     2 drop_table    oid u32
//!     3 insert        oid u32, rowid u64, count u8, values
//!     4 update        oid u32, rowid u64, count u8, values (complete row)
//!     5 delete        oid u32, rowid u64
//!     6 catalog_counters next_oid u32, count u8, (oid u32, next_rowid u64)*
//!     7 create_sequence oid u32, name, type_oid u32, increment i64, min i64,
//!                     max i64, start i64, cycle u8, owner table oid u32 (0
//!                     none), owner column u8
//!     8 drop_sequence oid u32
//!     9 sequence      oid u32, last_value i64, is_called u8 (log-ahead value)
//!    (10 stays unassigned: existing contracts use it as the unknown-op probe)
//!    11 truncate      oid u32 (every row of the table is deleted; rows the
//!                     same record inserts later survive)
//!    12 alter_table   oid u32, the new definition (as create_table after its
//!                     OID), then per new column: source u8 (old column index,
//!                     or 255 for an added column followed by its fill value)
//!    13 create_sequence_cached  op 7's fields, then cache i64 (CACHE > 1;
//!                     CACHE 1 keeps writing op 7)
//!    14 alter_sequence oid u32, type_oid u32, increment i64, min i64, max
//!                     i64, start i64, cycle u8, cache i64, last_value i64,
//!                     is_called u8 (options and state after ALTER SEQUENCE)
//!    15 create_schema oid u32, name
//!    16 drop_schema   oid u32 (the schema holds no table at that point)
//!    17 catalog_counters_with_constraints: op 6 plus next constraint OID u32
//!    20 catalog_counters_with_defaults: op 17 plus next default OID u32
//!    18 create_owned_schema: op 15 plus nonzero owner role OID u32
//!    19 create_private_schema: op 18 with owner-only USAGE
//!    23 alter_sequence_ownership: op 14 plus table OID u32 and column u8
//!                     (zero table and column detach an automatic dependency)
//!    24 create_scoped_serial_sequence: op 21 layout for an automatic dependency
//!                     (checkpoint images also use it for an explicit attachment)
//!    60-65 routines, triggers and rules (B11 wave 3): payload_len u32 +
//!                     payload, decoded by routine_catalog.sig: 60
//!                     create_routine, 61 drop_routine, 62 create_trigger,
//!                     63 drop_trigger, 64 create_rule, 65 drop_rule (66-69
//!                     reserved). A dropped table's triggers and rules are
//!                     dropped by their own ops first; a dropped routine has
//!                     no trigger left.
//!   105 alter_table_rewrite (ddl-alter, wave 5): ALTER COLUMN TYPE. Op 12's
//!                     layout, where a rewritten column's source is 0xfe
//!                     followed by its old column index u8, then the
//!                     rewritten table: row_count u32 (every live row) and
//!                     per row rowid u64 + its complete new row (as op 4),
//!                     each live rowid exactly once, in any order. Op 12
//!                     records stay byte-identical; 106-114 stay reserved.
//!   115 view_check_option (B11 wave 5): oid u32, option u8 (1 LOCAL, 2
//!                     CASCADED). Written right after the op 1 / op 12 that
//!                     defines a view with WITH CHECK OPTION; a definition
//!                     replayed without it has none, so older records stay
//!                     byte-identical. 116-119 stay reserved.
//!    120 create_trigger_extended (B11 wave 5): a trigger with REFERENCING
//!                     transition tables or a constraint trigger
//!                     (routine_catalog.sig).
//!    121 create_cast / 122 drop_cast (B11 wave 5, composite lane): a user
//!                     cast, payload_len u32 + payload (routine_catalog.sig
//!                     encodeCast; drop: the OID); 123-124 stay reserved.
//!    85 create_rule_action (B11 wave 4): a rule with INSERT / UPDATE /
//!                     DELETE actions, payload_len u32 + payload: the op 64
//!                     payload, flags u8 (1: parenthesized actions) and the
//!                     action text (u16 + bytes, non-empty, no NUL). Op 64
//!                     records stay byte-identical; 86-89 stay reserved.
//!   Definitions (ops 1 and 12) use expr_format_version 3 only when they
//!   need it (older definitions stay byte-identical): column flags bit 5
//!   VIRTUAL; constraint kinds 4 FOREIGN KEY (then ref_oid u32, one
//!   referenced column u8 per key column, on_delete u8, on_update u8) and 5
//!   EXCLUDE (one operator u8 per key column: 1 =, 2 &&), constraint flags
//!   bit 1 DEFERRABLE, bit 2 INITIALLY DEFERRED; then relkind u8 ('r', 'v',
//!   'm', 'p'), index_count u8 and per secondary index: oid u32, name, flags
//!   u8 (1 unique, 2 nulls not distinct, 4 USING hash; an index without
//!   4 is an ordered btree index, also when logged before B11 wave 5 wrote
//!   the bit), key_count u8, keys (column u8 or
//!   255 for an expression), options u8 per key (1 DESC, 2 NULLS FIRST),
//!   include_count u8 + columns, expression texts (NUL-separated) and
//!   predicate text (each u16 + bytes); view query text (u16 + bytes),
//!   populated u8, dependency count u8 + OIDs u32; parent OID u32
//!   (INHERITS / PARTITION OF); partition strategy u8, key column u8, bound
//!   kind u8, value count u8, unbounded flags u8 and the bound values.
//!   CREATE / DROP INDEX are op 12 with the indexes changed; views and
//!   materialized views are op 1 / op 2 with their relkind and query.
//!   Definition version 4 appends the primary constraint OID (zero for an
//!   unkeyed relation), then one OID for each nonprimary constraint in
//!   definition order. Replaying versions 1-3 assigns these identities in
//!   record order and preserves them through legacy ALTER TABLE records.
//!   Definition version 5 adds one nonzero primary-index OID immediately
//!   after the version-4 identity fields. Versions 1-4 retain the implicit
//!   table OID + 1 alias for a primary key. Version 5 requires a primary key.
//!   name: len u8 + bytes. value: 0 null | 1 i64 | 2 bool u8 | 3 len u32 + bytes
//!   | 4 f32 bits u32 | 5 f64 bits u64 | 6 numeric {special u8, negative u8,
//!   dscale u16, coefficient 4 x u64} | 7 date i32 | 8 timestamp i64
//!   | 9 timestamptz i64 | 10 interval {months i32, days i32, us i64}
//!   | 11 jsonb len u32 + canonical bytes | 12 bpchar len u32 + padded bytes
//!   (VARCHAR values use 3) | 13 uuid 16 bytes | 14 bytea len u32 + bytes
//!   | 15 time i64 | 16 timetz {us i64, zone i32 seconds west}
//!   | 17 bit/varbit bit length u32 + packed bytes (zero padded)
//!   | 18 money i64 cents | 19 pg_lsn u64 | 20 xid8 u64
//!   | 21 array {element type OID u32, ndim u8, ndim x (dim u32, lbound
//!   i32), every element as a value (0 for NULL) in row-major order}.
//!   | 22 range {subtype OID u32, flags u8 (PostgreSQL's range flags), the
//!   finite bounds as values} | 23 inet/cidr {family u8 (4/6), bits u8,
//!   cidr u8, 16 address bytes} | 24 macaddr 6 bytes | 25 point {x, y as
//!   f64 bits u64} | 26 box {high x, high y, low x, low y as f64 bits}
//!   | 27 xml len u32 + the stored text | 28 tsvector / 29 tsquery len u32
//!   + canonical output text (re-read and checked on replay) | 30 regtype
//!   OID u32 | 31 PostgreSQL internal "char" byte | 32 regproc OID u32
//!   | 57 record {type OID u32 (2249 for an anonymous record), field count
//!   u8, per field: built-in type OID u32, typmod i32, value (never a
//!   record)} (B11 wave 5, composite lane).
//!    21 create_scoped_identity_sequence: op 7 plus cache i64 and schema OID u32.
//!    22 create_scoped_sequence: op 21's layout with no owning table.
//!    70 object_create / 71 object_drop: catalog objects (roles, grants,
//!                     policies, comments, wrappers, servers, publications);
//!                     layout in catalog_objects.sig (B11 wave 3)
//!   Array type OIDs (1007, ...) name a column's array type. Every value is
//!   checked against the column's type OID (create_table) before anything
//!   applies.
//! Ops may repeat a (table, rowid) and apply in record order.
//!
//! apply() decodes and validates the WHOLE record against a bounded,
//! caller-owned overlay before changing anything, then applies it without any
//! further failure. Unknown versions or ops fail closed with
//! UnsupportedLogVersion, malformed bytes with InvalidChangeRecord, and
//! unknown OIDs, rowid or key conflicts and capacity overflow with
//! ChangeRecordConflict. A create needs an unused OID at or above first_oid,
//! not an ascending one: OIDs are taken when CREATE runs, so concurrent DDL
//! commits out of OID order. The OID counter keeps the maximum seen.
const types = @import("types.sig");
const collation_module = @import("collation.sig");
const storage = @import("storage.sig");
const numeric = @import("numeric.sig");
const temporal = @import("temporal.sig");
const jsonb = @import("jsonb.sig");
const sequence = @import("sequence.sig");
const time_of_day = @import("time_of_day.sig");
const bit_string = @import("bit_string.sig");
const array = @import("array.sig");
const range = @import("range.sig");
const network = @import("network.sig");
const routine_catalog = @import("routine_catalog.sig");
const catalog_objects = @import("catalog_objects.sig");
const LargePages = @import("large_object_pages.sig");
const text_search = @import("text_search.sig");
const Error = types.Error;

fn std_zero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

pub const format_version: u16 = 1;
pub const header_size: usize = 8;
pub const first_oid: u32 = 16384;
/// Private definition code, distinct from the PostgreSQL NUMERIC wire OID.
const mysql_unsigned_type: u32 = 0xffff_fffe;
pub const expr_format_version: u16 = 1;
/// create_table definitions that carry a namespace and table constraints.
pub const definition_format_version: u16 = 2;
/// Definitions with relation kinds, secondary indexes, FOREIGN KEY /
/// EXCLUDE / deferrable constraints, virtual columns, view queries,
/// inheritance and partitioning (written only when needed: older
/// definitions keep versions 1 and 2 byte for byte).
pub const extensions_format_version: u16 = 3;
pub const constraint_identity_format_version: u16 = 4;
pub const primary_index_identity_format_version: u16 = 5;
pub const default_identity_format_version: u16 = 6;
/// ddl-dml (wave 4): version 6 plus constraint flag bits 3, NOT VALID (a
/// CHECK or FOREIGN KEY whose existing rows were not checked), and 4, NOT
/// ENFORCED (one never checked). Written only when a constraint has either:
/// older definitions stay byte-identical.
pub const not_valid_format_version: u16 = 7;
/// ddl-alter (wave 5): version 7 plus, after the version-5 fields, one
/// entry per column: flags u8 (1 collation, 2 NOT NULL constraint name, 4
/// domain), then collation OID u32, name (len u8 + bytes) and domain OID
/// u32 as flagged. Written only when some column has one of them: older
/// definitions stay byte-identical.
pub const column_extension_format_version: u16 = 8;

pub const Op = enum(u8) { create_table = 1, drop_table = 2, insert = 3, update = 4, delete = 5, catalog_counters = 6, create_sequence = 7, drop_sequence = 8, sequence = 9, truncate = 11, alter_table = 12, create_sequence_cached = 13, alter_sequence = 14, create_schema = 15, drop_schema = 16, catalog_counters_with_constraints = 17, create_owned_schema = 18, create_private_schema = 19, catalog_counters_with_defaults = 20, create_scoped_identity_sequence = 21, create_scoped_sequence = 22, alter_sequence_ownership = 23, create_scoped_serial_sequence = 24, create_routine = 60, drop_routine = 61, create_trigger = 62, drop_trigger = 63, create_rule = 64, drop_rule = 65, object_create = 70, object_drop = 71, large_object_page = 72, create_routine_extended = 80, create_rule_action = 85, alter_table_rewrite = 105, view_check_option = 115, create_trigger_extended = 120,
    // B11 wave 5 (composite lane): user casts.
    create_cast = 121, drop_cast = 122 };

fn Unsigned(comptime T: type) type {
    return switch (T) {
        u8 => u8,
        u16 => u16,
        u32, i32 => u32,
        u64, i64 => u64,
        else => @compileError("unsupported change-record integer"),
    };
}

fn put(comptime T: type, out: []u8, value: T) void {
    const Bits = Unsigned(T);
    const bits: Bits = @bitCast(value);
    for (0..@sizeOf(T)) |index| out[index] = @truncate(bits >> @intCast(index * 8));
}

fn get(comptime T: type, input: []const u8) T {
    const Bits = Unsigned(T);
    var bits: Bits = 0;
    for (0..@sizeOf(T)) |index| bits |= @as(Bits, input[index]) << @intCast(index * 8);
    return @bitCast(bits);
}

/// Validates the header and returns the op count.
pub fn opCount(record: []const u8) Error!u32 {
    if (record.len < header_size) return error.InvalidChangeRecord;
    if (get(u16, record[0..2]) != format_version or get(u16, record[2..4]) != 0) return error.UnsupportedLogVersion;
    return get(u32, record[4..8]);
}

/// Appends ops after `used` bytes of `buffer`, writing a header when the
/// record is empty. Nothing is published until finish() returns the new length.
pub const Writer = struct {
    buffer: []u8,
    base: usize,
    used: usize,
    ops: u32 = 0,

    pub fn init(buffer: []u8, used: usize) Error!Writer {
        if (used > buffer.len) return error.TransactionLogCapacity;
        var writer = Writer{ .buffer = buffer, .base = used, .used = used };
        if (used == 0) {
            const header = try writer.reserve(header_size);
            put(u16, header[0..2], format_version);
            put(u16, header[2..4], 0);
            put(u32, header[4..8], 0);
        } else if (used < header_size) return error.InvalidChangeRecord;
        return writer;
    }

    fn reserve(self: *Writer, count: usize) Error![]u8 {
        if (count > self.buffer.len - self.used) return error.TransactionLogCapacity;
        const out = self.buffer[self.used..][0..count];
        self.used += count;
        return out;
    }

    pub fn int(self: *Writer, comptime T: type, value: T) Error!void {
        put(T, try self.reserve(@sizeOf(T)), value);
    }

    pub fn bytes(self: *Writer, value: []const u8) Error!void {
        @memcpy(try self.reserve(value.len), value);
    }

    pub fn name(self: *Writer, value: []const u8) Error!void {
        try self.int(u8, @intCast(value.len));
        try self.bytes(value);
    }

    pub fn op(self: *Writer, tag: Op) Error!void {
        try self.int(u8, @intFromEnum(tag));
        self.ops += 1;
    }

    /// Updates the header count; returns the record's new length.
    pub fn finish(self: *Writer) Error!usize {
        const previous = get(u32, self.buffer[4..8]);
        if (self.ops > 0xffffffff - previous) return error.TransactionLogCapacity;
        put(u32, self.buffer[4..8], previous + self.ops);
        return self.used;
    }
};

const LargePageRecord = struct { key: LargePages.Key, bytes: ?[]const u8 };

/// Version 1, op 72: object OID, page number, and a complete page image.
/// The 0xffff length represents removal of a present page.
pub fn encodeLargeObjectPage(writer: *Writer, key: LargePages.Key, bytes: ?[]const u8) Error!void {
    if (key.oid == 0 or key.page > LargePages.end_page) return error.InvalidParameterValue;
    if (bytes) |data| {
        if (data.len > LargePages.page_bytes or (key.page == LargePages.end_page and data.len != 0))
            return error.InvalidParameterValue;
    }
    try writer.op(.large_object_page);
    try writer.int(u32, key.oid);
    try writer.int(u32, key.page);
    try writer.int(u16, if (bytes) |data| @intCast(data.len) else 0xffff);
    if (bytes) |data| try writer.bytes(data);
}

fn decodeLargeObjectPage(reader: *Reader) Error!LargePageRecord {
    const key: LargePages.Key = .{ .oid = try reader.int(u32), .page = try reader.int(u32) };
    const size = try reader.int(u16);
    if (key.oid == 0 or key.page > LargePages.end_page) return error.InvalidChangeRecord;
    if (size == 0xffff) return .{ .key = key, .bytes = null };
    if (size > LargePages.page_bytes or (key.page == LargePages.end_page and size != 0)) return error.InvalidChangeRecord;
    return .{ .key = key, .bytes = try reader.take(size) };
}

const Reader = struct {
    bytes: []const u8,
    position: usize = header_size,

    fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.position) return error.InvalidChangeRecord;
        const out = self.bytes[self.position..][0..count];
        self.position += count;
        return out;
    }

    fn int(self: *Reader, comptime T: type) Error!T {
        return get(T, try self.take(@sizeOf(T)));
    }

    fn name(self: *Reader) Error![]const u8 {
        const len = try self.int(u8);
        return self.take(len);
    }
};

pub fn ChangeLog(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const overlay_capacity = blk: {
        var capacity: usize = 2;
        const entries: usize = if (config.external_storage)
            (if (config.tx_writes == 0) @max(config.rows_per_table * 2, 64) else config.tx_writes)
        else config.rows_per_table * config.tables;
        while (capacity < entries * 4) capacity *= 2;
        break :blk capacity;
    };
    const RC = routine_catalog.Catalog(config);
    const O = catalog_objects.Objects(config);
    return struct {
        // ----- encoding -------------------------------------------------

        /// An object op (B11 wave 3): tag, payload length u32, payload.
        pub fn encodeObject(writer: *Writer, tag: Op, payload: []const u8) Error!void {
            try writer.op(tag);
            try writer.int(u32, @intCast(payload.len));
            try writer.bytes(payload);
        }

        pub fn encodeValue(writer: *Writer, cell: *const V.Cell) Error!void {
            switch (cell.*) {
                .null_value => try writer.int(u8, 0),
                .integer => |value| {
                    try writer.int(u8, 1);
                    try writer.int(i64, value);
                },
                .boolean => |value| {
                    try writer.int(u8, 2);
                    try writer.int(u8, @intFromBool(value));
                },
                .text => |*text| {
                    try writer.int(u8, 3);
                    try writer.int(u32, @intCast(text.len));
                    try writer.bytes(text.slice());
                },
                .float4 => |value| {
                    try writer.int(u8, 4);
                    try writer.int(u32, @bitCast(value));
                },
                .float8 => |value| {
                    try writer.int(u8, 5);
                    try writer.int(u64, @bitCast(value));
                },
                .numeric => |*value| {
                    try writer.int(u8, 6);
                    try writer.int(u8, @intFromEnum(value.special));
                    try writer.int(u8, @intFromBool(value.negative));
                    try writer.int(u16, value.dscale);
                    for (value.limbs) |limb| try writer.int(u64, limb);
                },
                .date => |value| {
                    try writer.int(u8, 7);
                    try writer.int(i32, value);
                },
                .timestamp => |value| {
                    try writer.int(u8, 8);
                    try writer.int(i64, value);
                },
                .timestamptz => |value| {
                    try writer.int(u8, 9);
                    try writer.int(i64, value);
                },
                .interval => |value| {
                    try writer.int(u8, 10);
                    try writer.int(i32, value.months);
                    try writer.int(i32, value.days);
                    try writer.int(i64, value.us);
                },
                .jsonb => |*document| {
                    try writer.int(u8, 11);
                    try writer.int(u32, @intCast(document.len));
                    try writer.bytes(document.slice());
                },
                .bpchar => |*text| {
                    try writer.int(u8, 12);
                    try writer.int(u32, @intCast(text.len));
                    try writer.bytes(text.slice());
                },
                .uuid => |*bytes| {
                    try writer.int(u8, 13);
                    try writer.bytes(bytes);
                },
                .bytea => |*bytes| {
                    try writer.int(u8, 14);
                    try writer.int(u32, @intCast(bytes.len));
                    try writer.bytes(bytes.slice());
                },
                .time => |value| {
                    try writer.int(u8, 15);
                    try writer.int(i64, value);
                },
                .timetz => |value| {
                    try writer.int(u8, 16);
                    try writer.int(i64, value.us);
                    try writer.int(i32, value.zone);
                },
                .money => |value| {
                    try writer.int(u8, 18);
                    try writer.int(i64, value);
                },
                .bits => |*value| {
                    try writer.int(u8, 17);
                    try writer.int(u32, @intCast(value.len));
                    try writer.bytes(value.slice());
                },
                .pg_lsn => |value| {
                    try writer.int(u8, 19);
                    try writer.int(u64, value);
                },
                .xid8 => |value| {
                    try writer.int(u8, 20);
                    try writer.int(u64, value);
                },
                .inet => |*value| {
                    try writer.int(u8, 23);
                    try writer.bytes(&.{ value.family, value.bits, @intFromBool(value.cidr) });
                    try writer.bytes(&value.address);
                },
                .macaddr => |*value| {
                    try writer.int(u8, 24);
                    try writer.bytes(value);
                },
                // B11 wave 4 (types-ext): value tag 40 (multirange): range
                // type OID, u16 count, then each range as a tag-22 value.
                .multirange => |*set| {
                    const MR = V.Multiranges;
                    try writer.int(u8, 40);
                    try writer.int(u32, types.typeOid(MR.rangeType(set.slice())));
                    try writer.int(u16, @intCast(MR.count(set.slice())));
                    var it = MR.iterate(set.slice());
                    while (it.nextBytes()) |raw| {
                        const range_cell: V.Cell = .{ .range = V.Text.fromValueBytes(raw) };
                        try encodeValue(writer, &range_cell);
                    }
                },
                // B11 wave 4 (types-ext): value tag 41, validated on replay.
                .geo => |*text| {
                    try writer.int(u8, 41);
                    try writer.int(u32, @intCast(text.len));
                    try writer.bytes(text.slice());
                },
                // B11 wave 4 (types-ext): value tag 46.
                .macaddr8 => |*value| {
                    try writer.int(u8, 46);
                    try writer.bytes(value);
                },
                .xml => |*text| {
                    try writer.int(u8, 27);
                    try writer.int(u32, @intCast(text.len));
                    try writer.bytes(text.slice());
                },
                .pg_internal_char => |value| {
                    try writer.int(u8, 31);
                    try writer.int(u8, value);
                },
                .regtype => |oid| {
                    try writer.int(u8, 30);
                    try writer.int(u32, oid);
                },
                .regproc => |oid| {
                    try writer.int(u8, 32);
                    try writer.int(u32, oid);
                },
                .tsvector, .tsquery => |*text| {
                    try writer.int(u8, if (cell.* == .tsvector) 28 else 29);
                    try writer.int(u32, @intCast(text.len));
                    try writer.bytes(text.slice());
                },
                .point => |value| {
                    try writer.int(u8, 25);
                    try writer.int(u64, @bitCast(value.x));
                    try writer.int(u64, @bitCast(value.y));
                },
                .box => |value| {
                    try writer.int(u8, 26);
                    for ([_]f64{ value.high.x, value.high.y, value.low.x, value.low.y }) |coordinate| try writer.int(u64, @bitCast(coordinate));
                },
                .range => |*span| {
                    const value = V.Ranges.decode(span.slice());
                    try writer.int(u8, 22);
                    try writer.int(u32, types.typeOid(value.subtype));
                    try writer.int(u8, span.bytes[1]);
                    if (!value.empty and !value.lower.infinite) try encodeValue(writer, &value.lower.value);
                    if (!value.empty and !value.upper.infinite) try encodeValue(writer, &value.upper.value);
                },
                // B11 wave 5 (composite lane): value tag 57, a record: its
                // type OID u32 (2249 anonymous), field count u8, then per
                // field its type OID u32, typmod i32 and value (no records).
                .record => |*fields| {
                    const bytes = fields.slice();
                    try writer.int(u8, 57);
                    try writer.int(u32, V.Records.typeOf(bytes));
                    try writer.int(u8, @intCast(V.Records.count(bytes)));
                    var reader = V.Records.Reader.init(bytes);
                    var item: V.Records.Field = .{};
                    while (reader.next(&item)) {
                        try writer.int(u32, types.typeOid(item.data_type));
                        try writer.int(i32, item.typmod);
                        try encodeValue(writer, &item.cell);
                    }
                },
                .array => |*items| {
                    const shape = V.Arrays.shape(items.slice());
                    try writer.int(u8, 21);
                    try writer.int(u32, types.typeOid(shape.element));
                    try writer.int(u8, @intCast(shape.ndim));
                    for (0..shape.ndim) |dim| {
                        try writer.int(u32, shape.dims[dim]);
                        try writer.int(i32, shape.lbounds[dim]);
                    }
                    var reader = V.Arrays.Reader.init(items.slice());
                    var element: V.Cell = undefined;
                    while (reader.next(&element)) try encodeValue(writer, &element);
                },
            }
        }

        pub fn encodeCreate(writer: *Writer, table: *const S.Table) Error!void {
            try writer.op(.create_table);
            try writer.int(u32, table.oid);
            try encodeDefinition(writer, table);
            try encodeViewOptions(writer, table);
        }

        /// Op 115 after a view definition with a check option.
        fn encodeViewOptions(writer: *Writer, table: *const S.Table) Error!void {
            if (table.relkind != 'v' or table.check_option == 0) return;
            try writer.op(.view_check_option);
            try writer.int(u32, table.oid);
            try writer.int(u8, table.check_option);
        }

        /// Name, format version, columns and (version 2) namespace and
        /// constraints of a table definition.
        pub fn encodeDefinition(writer: *Writer, table: *const S.Table) Error!void {
            var v8 = false;
            for (table.columns[0..table.column_count]) |*column| v8 = v8 or columnExtended(column);
            var v7 = v8;
            for (table.constraints[0..table.constraint_count]) |*constraint| v7 = v7 or constraint.not_valid or constraint.not_enforced;
            var v6 = v7;
            for (table.columns[0..table.column_count]) |*column| v6 = v6 or column.default_oid != 0;
            const v5 = v6 or table.primary_index_oid != 0;
            const v4 = v5 or table.primary_constraint_oid != 0 or table.constraint_count != 0;
            const v3 = v4 or S.extended(table);
            const extended = v3 or table.namespace != public_namespace or table.constraint_count != 0;
            try writer.name(table.name.slice());
            try writer.int(u16, if (v8) column_extension_format_version else if (v7) not_valid_format_version else if (v6) default_identity_format_version else if (v5) primary_index_identity_format_version else if (v4) constraint_identity_format_version else if (v3) extensions_format_version else if (extended) definition_format_version else expr_format_version);
            try writer.int(u8, @intCast(table.column_count));
            for (table.columns[0..table.column_count]) |*column| {
                try writer.name(column.name.slice());
                try writer.int(u32, if (column.data_type == .mysql_bigint_unsigned) mysql_unsigned_type else types.typeOid(column.data_type));
                try writer.int(i32, column.typmod);
                try writer.int(u8, @as(u8, @intFromBool(column.not_null)) | (@as(u8, @intFromBool(column.primary_key)) << 1) | (@as(u8, @intFromEnum(column.default_kind)) << 2) | (@as(u8, @intFromBool(column.virtual)) << 5));
                const text = column.expression.slice();
                try writer.int(u16, @intCast(text.len));
                try writer.bytes(text);
                if (v6 and text.len != 0) try writer.int(u32, column.default_oid);
            }
            if (!extended) return;
            try writer.int(u32, table.namespace);
            try writer.int(u8, @intCast(table.constraint_count));
            for (table.constraints[0..table.constraint_count]) |*constraint| {
                try writer.int(u8, @intFromEnum(constraint.kind));
                try writer.name(constraint.name.slice());
                try writer.int(u8, @as(u8, @intFromBool(constraint.nulls_not_distinct)) | (@as(u8, @intFromBool(constraint.deferrable)) << 1) | (@as(u8, @intFromBool(constraint.initially_deferred)) << 2) | (@as(u8, @intFromBool(constraint.not_valid)) << 3) | (@as(u8, @intFromBool(constraint.not_enforced)) << 4));
                try writer.int(u8, constraint.column_count);
                try writer.bytes(constraint.keyColumns());
                const text = constraint.expression.slice();
                try writer.int(u16, @intCast(text.len));
                try writer.bytes(text);
                switch (constraint.kind) {
                    .foreign => {
                        try writer.int(u32, constraint.ref_oid);
                        try writer.bytes(constraint.refColumns());
                        try writer.int(u8, @intFromEnum(constraint.on_delete));
                        try writer.int(u8, @intFromEnum(constraint.on_update));
                    },
                    .exclusion => for (constraint.operators[0..constraint.column_count]) |operator| try writer.int(u8, @intFromEnum(operator)),
                    else => {},
                }
            }
            if (!v3) return;
            try writer.int(u8, table.relkind);
            try writer.int(u8, @intCast(table.index_count));
            for (table.indexes[0..table.index_count]) |*index| {
                try writer.int(u32, index.oid);
                try writer.name(index.name.slice());
                try writer.int(u8, @as(u8, @intFromBool(index.unique)) | (@as(u8, @intFromBool(index.nulls_not_distinct)) << 1) | (@as(u8, @intFromBool(index.hash)) << 2));
                try writer.int(u8, index.key_count);
                try writer.bytes(index.keyColumns());
                try writer.bytes(index.options[0..index.key_count]);
                try writer.int(u8, index.include_count);
                try writer.bytes(index.includes[0..index.include_count]);
                for ([_][]const u8{ index.expressions.slice(), index.predicate.slice() }) |text| {
                    try writer.int(u16, @intCast(text.len));
                    try writer.bytes(text);
                }
            }
            const query = table.query.slice();
            try writer.int(u16, @intCast(query.len));
            try writer.bytes(query);
            try writer.int(u8, @intFromBool(table.populated));
            try writer.int(u8, @intCast(table.depend_count));
            for (table.depends[0..table.depend_count]) |oid| try writer.int(u32, oid);
            try writer.int(u32, table.parent);
            const partition = &table.partition;
            try writer.int(u8, @intFromEnum(partition.strategy));
            try writer.int(u8, partition.key);
            try writer.int(u8, @intFromEnum(partition.bound));
            try writer.int(u8, partition.count);
            try writer.int(u8, partition.unbounded);
            for (partition.values[0..partition.count]) |*cell| try encodeValue(writer, cell);
            if (v4) {
                try writer.int(u32, table.primary_constraint_oid);
                for (table.constraints[0..table.constraint_count]) |*constraint| {
                    if (constraint.kind != .primary) try writer.int(u32, constraint.oid);
                }
            }
            if (v5) try writer.int(u32, table.primary_index_oid);
            if (v8) for (table.columns[0..table.column_count]) |*column| {
                const flags: u8 = @as(u8, @intFromBool(column.collation != 0)) | (@as(u8, @intFromBool(column.not_null_name.len != 0)) << 1) | (@as(u8, @intFromBool(column.domain != 0)) << 2);
                try writer.int(u8, flags);
                if (column.collation != 0) try writer.int(u32, column.collation);
                if (column.not_null_name.len != 0) try writer.name(column.not_null_name.slice());
                if (column.domain != 0) try writer.int(u32, column.domain);
            };
        }

        /// A column with a format-8 attribute (collation, constraint name, domain).
        fn columnExtended(column: *const V.Column) bool {
            return column.collation != 0 or column.not_null_name.len != 0 or column.domain != 0;
        }

        pub fn encodeCreateSequence(writer: *Writer, seq: anytype, serial: bool) Error!void {
            const scoped = seq.namespace != public_namespace;
            const operation: Op = if (scoped)
                if (seq.owner == 0) .create_scoped_sequence else if (serial) .create_scoped_serial_sequence else .create_scoped_identity_sequence
            else if (seq.spec.cache != 1) .create_sequence_cached else .create_sequence;
            try writer.op(operation);
            try writer.int(u32, seq.oid);
            try writer.name(seq.name.slice());
            try writer.int(u32, seq.spec.type_oid);
            try writer.int(i64, seq.spec.increment);
            try writer.int(i64, seq.spec.min);
            try writer.int(i64, seq.spec.max);
            try writer.int(i64, seq.spec.start);
            try writer.int(u8, @intFromBool(seq.spec.cycle));
            try writer.int(u32, seq.owner);
            try writer.int(u8, seq.owner_column);
            if (scoped or seq.spec.cache != 1) try writer.int(i64, seq.spec.cache);
            if (scoped) try writer.int(u32, seq.namespace);
        }

        pub fn encodeCreateSchema(writer: *Writer, schema: anytype) Error!void {
            const owner_field = schema.private_usage or schema.owner != catalog_objects.bootstrap_role;
            try writer.op(if (schema.private_usage) .create_private_schema else if (owner_field) .create_owned_schema else .create_schema);
            try writer.int(u32, schema.oid);
            try writer.name(schema.name.slice());
            if (owner_field) try writer.int(u32, schema.owner);
        }

        pub fn encodeDropSchema(writer: *Writer, oid: u32) Error!void {
            try writer.op(.drop_schema);
            try writer.int(u32, oid);
        }

        pub fn encodeAlterSequence(writer: *Writer, seq: anytype, ownership_changed: bool) Error!void {
            try writer.op(if (ownership_changed) .alter_sequence_ownership else .alter_sequence);
            try writer.int(u32, seq.oid);
            try writer.int(u32, seq.spec.type_oid);
            try writer.int(i64, seq.spec.increment);
            try writer.int(i64, seq.spec.min);
            try writer.int(i64, seq.spec.max);
            try writer.int(i64, seq.spec.start);
            try writer.int(u8, @intFromBool(seq.spec.cycle));
            try writer.int(i64, seq.spec.cache);
            try writer.int(i64, seq.last_value);
            try writer.int(u8, @intFromBool(seq.is_called));
            if (ownership_changed) {
                try writer.int(u32, seq.owner);
                try writer.int(u8, seq.owner_column);
            }
        }

        pub fn encodeDropSequence(writer: *Writer, oid: u32) Error!void {
            try writer.op(.drop_sequence);
            try writer.int(u32, oid);
        }

        pub fn encodeSequenceValue(writer: *Writer, oid: u32, last_value: i64, called: bool) Error!void {
            try writer.op(.sequence);
            try writer.int(u32, oid);
            try writer.int(i64, last_value);
            try writer.int(u8, @intFromBool(called));
        }

        pub fn encodeDrop(writer: *Writer, oid: u32) Error!void {
            try writer.op(.drop_table);
            try writer.int(u32, oid);
        }

        pub fn encodeTruncate(writer: *Writer, oid: u32) Error!void {
            try writer.op(.truncate);
            try writer.int(u32, oid);
        }

        /// ALTER TABLE: the definition after the statement and how each new
        /// column is obtained from the previous one.
        pub fn encodeAlter(writer: *Writer, table: *const S.Table, sources: []const u8, fills: []const V.Cell) Error!void {
            try writer.op(.alter_table);
            try writer.int(u32, table.oid);
            try encodeDefinition(writer, table);
            for (sources, 0..) |origin, column| {
                try writer.int(u8, origin);
                if (origin == 0xff) try encodeValue(writer, &fills[column]);
            }
            try encodeViewOptions(writer, table);
        }

        /// ALTER COLUMN TYPE (op 105): the definition, each new column's
        /// source (0xfe + old index for a rewritten one) and the row count;
        /// encodeRewriteRow follows for each of the `rows` rows.
        pub fn encodeAlterRewrite(writer: *Writer, table: *const S.Table, sources: []const u8, fills: []const V.Cell, rewritten: []const bool, rows: u32) Error!void {
            try writer.op(.alter_table_rewrite);
            try writer.int(u32, table.oid);
            try encodeDefinition(writer, table);
            for (sources, 0..) |origin, column| {
                if (rewritten[column]) {
                    try writer.int(u8, 0xfe);
                    try writer.int(u8, origin);
                    continue;
                }
                try writer.int(u8, origin);
                if (origin == 0xff) try encodeValue(writer, &fills[column]);
            }
            try writer.int(u32, rows);
        }

        pub fn encodeRewriteRow(writer: *Writer, rowid: u64, cells: []const V.Cell) Error!void {
            try writer.int(u64, rowid);
            try encodeCells(writer, cells);
        }

        pub fn encodeRow(writer: *Writer, tag: Op, oid: u32, rowid: u64, cells: []const V.Cell) Error!void {
            try writer.op(tag);
            try writer.int(u32, oid);
            try writer.int(u64, rowid);
            try encodeCells(writer, cells);
        }

        fn encodeCells(writer: *Writer, cells: []const V.Cell) Error!void {
            try writer.int(u8, @intCast(cells.len));
            for (cells) |*cell| try encodeValue(writer, cell);
        }

        /// Prepared DML uses the same typed cell encoding as committed WAL.
        /// Its separate envelope also records before-images for exact replay
        /// against the committed state at the decision or end of recovery.
        pub fn encodePreparedRow(writer: *Writer, tag: Op, oid: u32, rowid: u64, old: []const V.Cell, new: []const V.Cell) Error!void {
            try writer.op(tag);
            try writer.int(u32, oid);
            try writer.int(u64, rowid);
            if (tag != .insert) try encodeCells(writer, old);
            if (tag != .delete) try encodeCells(writer, new);
        }

        pub const PreparedRow = struct {
            tag: Op,
            oid: u32,
            rowid: u64,
            old_count: usize = 0,
            new_count: usize = 0,
        };

        pub const PreparedReader = struct {
            reader: Reader,
            remaining: u32,

            pub fn init(record: []const u8) Error!PreparedReader {
                return .{ .reader = .{ .bytes = record }, .remaining = try opCount(record) };
            }

            pub fn next(self: *PreparedReader, old: *V.Row, new: *V.Row) Error!?PreparedRow {
                if (self.remaining == 0) {
                    if (self.reader.position != self.reader.bytes.len) return error.InvalidChangeRecord;
                    return null;
                }
                const tag: Op = switch (try self.reader.int(u8)) {
                    @intFromEnum(Op.insert) => .insert,
                    @intFromEnum(Op.update) => .update,
                    @intFromEnum(Op.delete) => .delete,
                    else => return error.InvalidChangeRecord,
                };
                var row: PreparedRow = .{ .tag = tag, .oid = try self.reader.int(u32), .rowid = try self.reader.int(u64) };
                if (row.oid == 0 or row.rowid == 0 or row.rowid == 0xffffffffffffffff) return error.InvalidChangeRecord;
                if (tag != .insert) row.old_count = try self.readCells(old);
                if (tag != .delete) row.new_count = try self.readCells(new);
                self.remaining -= 1;
                return row;
            }

            fn readCells(self: *PreparedReader, row: *V.Row) Error!usize {
                const count = try self.reader.int(u8);
                if (count == 0 or count > config.columns) return error.InvalidChangeRecord;
                row.* = .{};
                for (row.cells[0..count]) |*cell| cell.* = (try decodeValue(&self.reader)).cell;
                return count;
            }
        };

        pub fn encodeDelete(writer: *Writer, oid: u32, rowid: u64) Error!void {
            try writer.op(.delete);
            try writer.int(u32, oid);
            try writer.int(u64, rowid);
        }

        /// Catalog counters and every live table's next rowid.
        pub fn encodeCounters(writer: *Writer, next_oid: u32, next_constraint_oid: u32, next_default_oid: u32, tables: *const [config.tables]S.Table) Error!void {
            const tag: Op = if (next_default_oid != first_oid) .catalog_counters_with_defaults else
                if (next_constraint_oid != first_oid) .catalog_counters_with_constraints else .catalog_counters;
            try writer.op(tag);
            try writer.int(u32, next_oid);
            // Committed tables only: a dropped or ALTERed slot awaiting
            // reclamation, or an uncommitted one, has no replayed OID.
            var count: u8 = 0;
            for (tables) |*table| if (S.committedTable(table)) {
                count += 1;
            };
            try writer.int(u8, count);
            for (tables) |*table| if (S.committedTable(table)) {
                try writer.int(u32, table.oid);
                try writer.int(u64, table.next_rowid);
            };
            if (tag != .catalog_counters) try writer.int(u32, next_constraint_oid);
            if (tag == .catalog_counters_with_defaults) try writer.int(u32, next_default_oid);
        }

        // ----- validation overlay ---------------------------------------

        const RowEntry = struct {
            epoch: u32 = 0,
            table: u8 = 0,
            live: bool = false,
            has_key: bool = false,
            /// Listed by the current op 105 (each row once, ddl-alter).
            rewritten: bool = false,
            rowid: u64 = 0,
            key_offset: u32 = 0,
        };

        const KeyEntry = struct {
            epoch: u32 = 0,
            table: u8 = 0,
            hash: usize = 0,
            rowid: u64 = 0,
        };

        const VTable = struct {
            live: bool = false,
            /// Rows of this slot still come from the database (not recreated).
            base: bool = false,
            mutated: bool = false,
            late_primary: bool = false,
            /// A primary key, with an optional explicit index identity.
            keyed: bool = false,
            primary_index_oid: u32 = 0,
            namespace: u32 = 2200,
            oid: u32 = 0,
            name: V.Name = .{},
            column_count: usize = 0,
            columns: [config.columns]V.Column = undefined,
            primary: ?usize = null,
            base_next_rowid: u64 = 0,
            next_rowid: u64 = 0,
            live_rows: usize = 0,
            relkind: u8 = 'r',
            /// Secondary index OIDs of the definition.
            index_count: usize = 0,
            index_oids: [S.index_capacity]u32 = @splat(0),
            constraint_ids: ConstraintIdentities = .{},
        };

        const ConstraintIdentities = struct {
            const Entry = struct { name: V.Name, kind: S.ConstraintKind, oid: u32 };
            primary: u32 = 0,
            count: usize = 0,
            entries: [S.constraint_capacity]Entry = undefined,

            fn from(primary: u32, constraints: []const S.Constraint) ConstraintIdentities {
                var ids: ConstraintIdentities = .{ .primary = primary };
                for (constraints) |*constraint| {
                    if (constraint.kind == .primary) continue;
                    ids.entries[ids.count] = .{ .name = constraint.name, .kind = constraint.kind, .oid = constraint.oid };
                    ids.count += 1;
                }
                return ids;
            }

            fn sameConstraint(ids: *const ConstraintIdentities, constraint: *const S.Constraint) u32 {
                for (ids.entries[0..ids.count]) |*entry| {
                    if (entry.kind == constraint.kind and types.same(entry.name.slice(), constraint.name.slice())) return entry.oid;
                }
                return 0;
            }

            fn has(ids: *const ConstraintIdentities, oid: u32) bool {
                if (ids.primary == oid) return true;
                for (ids.entries[0..ids.count]) |*entry| if (entry.oid == oid) return true;
                return false;
            }
        };

        const VSeq = struct {
            live: bool = false,
            oid: u32 = 0,
            namespace: u32 = public_namespace,
            name: V.Name = .{},
            owner: u32 = 0,
            owner_column: u8 = 0,
            identity: bool = false,
        };
        const VSchema = struct { live: bool = false, oid: u32 = 0, owner: u32 = catalog_objects.bootstrap_role, private_usage: bool = false, name: V.Name = .{} };

        const PageOverlay = struct {
            const write_capacity: usize = if (config.tx_writes == 0) @max(config.rows_per_table * 2, 64) else config.tx_writes;
            const cap = @as(usize, write_capacity) * @as(usize, 2);
            const Entry = struct { key: u64 = 0, size: ?u16 = null };
            items: [cap]Entry = undefined,
            active: bool = false,
            live: usize = 0,
            audit: bool = false,

            fn position(self: *const PageOverlay, key: LargePages.Key) Error!usize {
                const id = key.rowId();
                var at: usize = @intCast((id *% 0x9e3779b97f4a7c15 ^ (id >> 29)) % cap);
                for (0..cap) |_| {
                    if (self.items[at].key == 0 or self.items[at].key == id) return at;
                    at = (at + 1) % cap;
                }
                return error.ChangeRecordConflict;
            }

            fn validate(self: *PageOverlay, page: LargePageRecord, pages: *const LargePages.Pages, catalog_overlay: *const O.Overlay, at: u64) Error!void {
                if (!self.active) {
                    self.items = @splat(.{});
                    self.live = pages.committed_count;
                    self.active = true;
                }
                const length = catalog_overlay.largeObjectLength(page.key.oid) orelse return error.ChangeRecordConflict;
                const found = try self.position(page.key);
                const entry = &self.items[found];
                const existed = if (entry.key == 0) pages.page(page.key, .{ .csn = at }) != null else entry.size != null;
                if (page.bytes) |data| {
                    if (!pageFits(page.key, data.len, length)) return error.ChangeRecordConflict;
                    if (!existed) {
                        if (self.live == pages.capacity()) return error.ChangeRecordConflict;
                        self.live += 1;
                    }
                } else {
                    if (!existed) return error.ChangeRecordConflict;
                    self.live -= 1;
                }
                entry.* = .{ .key = page.key.rowId(), .size = if (page.bytes) |data| @intCast(data.len) else null };
            }

            fn finish(self: *const PageOverlay, db: anytype, catalog_overlay: *const O.Overlay) Error!void {
                if (self.active) {
                    for (&self.items) |*entry| {
                        const size = entry.size orelse continue;
                        const key: LargePages.Key = .{ .oid = @truncate(entry.key >> 32), .page = @truncate(entry.key) };
                        const length = catalog_overlay.largeObjectLength(key.oid) orelse return error.ChangeRecordConflict;
                        if (!pageFits(key, size, length)) return error.ChangeRecordConflict;
                    }
                }
                if (!self.audit) return;
                const pages = &db.large_pages.?;
                const snapshot: storage.Snapshot = .{ .csn = db.csn };
                var may_have_removed_pages = false;
                for (&db.catalog_objects.items) |*object| {
                    if (object.kind != .large_object or !O.visible(object, snapshot)) continue;
                    const after = catalog_overlay.largeObjectLength(object.target);
                    if (after == null or after.? < object.largeObjectLength()) {
                        may_have_removed_pages = true;
                        break;
                    }
                }
                if (!may_have_removed_pages) return;
                var cursor: LargePages.Pages.Cursor = .{};
                var previous_oid: u32 = 0;
                var length: ?u64 = null;
                while (cursor.next(pages, snapshot)) |item| {
                    if (self.active and self.items[try self.position(item.key)].key != 0) continue;
                    if (item.key.oid != previous_oid) {
                        previous_oid = item.key.oid;
                        length = catalog_overlay.largeObjectLength(item.key.oid);
                    }
                    if (!pageFits(item.key, pages.versionBytes(item.version).len, length orelse return error.ChangeRecordConflict))
                        return error.ChangeRecordConflict;
                }
            }
        };

        fn pageFits(key: LargePages.Key, size: usize, length: u64) bool {
            return @as(u64, key.page) * LargePages.page_bytes + size <= length;
        }

        /// Caller-owned replay overlay. Bounded by 2 x rows x tables live
        /// entries (rows touched from the database plus rows created by the
        /// record that are still alive) at <= 50% load. Reset is O(1).
        pub const Scratch = struct {
            epoch: u32 = 0,
            rows: [overlay_capacity]RowEntry = @splat(.{}),
            keys: [overlay_capacity]KeyEntry = @splat(.{}),
            tables: [config.tables]VTable = undefined,
            seqs: [config.sequences]VSeq = undefined,
            schemas: [config.schemas]VSchema = undefined,
            /// Routines, triggers and rules (B11 wave 3).
            objects: RC.Overlay = .{},
            /// Catalog objects (catalog-security lane, catalog_objects.sig).
            object_overlay: O.Overlay = .{},
            large_pages: PageOverlay = .{},
        };

        /// What object ops (routine_catalog.validateOp) may ask the overlay.
        fn ObjectChecks(comptime D: type) type {
            return struct {
                db: D,
                scratch: *Scratch,

                pub fn oidTaken(self: @This(), oid: u32) bool {
                    return oidTakenIn(self.db, self.scratch, oid, 1);
                }

                pub fn tableLive(self: @This(), oid: u32) bool {
                    _ = findVTable(self.scratch, oid) catch return false;
                    return true;
                }

                pub fn namespaceKnown(self: @This(), namespace: u32) bool {
                    return knownNamespace(self.scratch, namespace);
                }

                /// A live composite type (B11 wave 5, composite lane).
                pub fn compositeLive(self: @This(), oid: u32) bool {
                    return self.scratch.object_overlay.compositeLive(oid);
                }
            };
        }

        /// A composite column's type (its typmod) is a live composite type
        /// (B11 wave 5, composite lane).
        fn compositeColumns(scratch: *const Scratch, definition: *const Definition) Error!void {
            for (definition.columns[0..definition.count]) |*column| {
                if (column.data_type != .record) continue;
                if (column.typmod <= 0 or !scratch.object_overlay.compositeLive(@intCast(column.typmod))) return error.ChangeRecordConflict;
            }
        }

        /// Whether a live table has a column of composite type `oid`.
        fn compositeInUse(scratch: *const Scratch, oid: u32) bool {
            for (&scratch.tables) |*vt| {
                if (!vt.live) continue;
                for (vt.columns[0..vt.column_count]) |*column| {
                    if (column.data_type == .record and column.typmod == @as(i64, oid)) return true;
                }
            }
            return false;
        }

        /// What catalog-object validation asks of the record so far.
        fn ObjectCheck(comptime DB: type) type {
            return struct {
                db: DB,
                scratch: *Scratch,
                next_oid: *u32,

                pub fn objectOidTaken(self: *const @This(), oid: u32, width: u32) bool {
                    return oidTaken(self.db, self.scratch, oid, width);
                }

                pub fn objectRelationNameTaken(self: *const @This(), namespace: u32, name: []const u8) bool {
                    return tableNameTaken(self.scratch, name, namespace);
                }

                pub fn objectSequenceNameTaken(self: *const @This(), namespace: u32, name: []const u8) bool {
                    return sequenceNameTaken(self.scratch, name, namespace);
                }

                pub fn noteObjectOid(self: *const @This(), oid: u32) void {
                    self.next_oid.* = @max(self.next_oid.*, oid + 1);
                }

                pub fn objectTableLive(self: *const @This(), oid: u32) bool {
                    return self.objectTableColumns(oid) != null;
                }

                pub fn objectTablePublishable(self: *const @This(), oid: u32) bool {
                    for (&self.scratch.tables) |*table| {
                        if (table.live and table.oid == oid) return catalog_objects.publicationRelationKind(table.relkind);
                    }
                    return false;
                }

                pub fn objectTableColumns(self: *const @This(), oid: u32) ?usize {
                    for (&self.scratch.tables) |*vt| if (vt.live and vt.oid == oid) return vt.column_count;
                    return null;
                }

                pub fn objectSequenceLive(self: *const @This(), oid: u32) bool {
                    for (&self.scratch.seqs) |*vs| if (vs.live and vs.oid == oid) return true;
                    return false;
                }

                pub fn objectPrivateSchemaOwner(self: *const @This(), oid: u32) ?u32 {
                    for (&self.scratch.schemas) |*schema| {
                        if (schema.live and schema.private_usage and schema.oid == oid) return schema.owner;
                    }
                    return null;
                }

                pub fn objectSchemaLive(self: *const @This(), oid: u32) bool {
                    if (oid == 11 or oid == 99 or oid == public_namespace or oid == 13000) return true;
                    for (&self.scratch.schemas) |*vs| if (vs.live and vs.oid == oid) return true;
                    return false;
                }
            };
        }

        const SequenceDefinition = struct { oid: u32, name: V.Name, spec: sequence.Spec, owner: u32, owner_column: u8, namespace: u32 = public_namespace };

        fn decodeCreateSequence(reader: *Reader, tag: u8) Error!SequenceDefinition {
            var out: SequenceDefinition = .{ .oid = try reader.int(u32), .name = .{}, .spec = .{}, .owner = 0, .owner_column = 0 };
            const seq_name = try reader.name();
            if (!validName(seq_name)) return error.InvalidChangeRecord;
            out.name.len = seq_name.len;
            @memcpy(out.name.bytes[0..seq_name.len], seq_name);
            out.spec.type_oid = try reader.int(u32);
            out.spec.increment = try reader.int(i64);
            out.spec.min = try reader.int(i64);
            out.spec.max = try reader.int(i64);
            out.spec.start = try reader.int(i64);
            const cycle = try reader.int(u8);
            if (cycle > 1) return error.InvalidChangeRecord;
            out.spec.cycle = cycle == 1;
            out.owner = try reader.int(u32);
            out.owner_column = try reader.int(u8);
            if (tag == @intFromEnum(Op.create_sequence_cached)) {
                out.spec.cache = try reader.int(i64);
                if (out.spec.cache <= 1) return error.InvalidChangeRecord;
            } else if (tag == @intFromEnum(Op.create_scoped_identity_sequence) or tag == @intFromEnum(Op.create_scoped_sequence) or
                tag == @intFromEnum(Op.create_scoped_serial_sequence))
            {
                out.spec.cache = try reader.int(i64);
                out.namespace = try reader.int(u32);
                if (out.spec.cache < 1 or out.namespace < first_oid) return error.InvalidChangeRecord;
                if (tag == @intFromEnum(Op.create_scoped_sequence)) {
                    if (out.owner != 0 or out.owner_column != 0) return error.InvalidChangeRecord;
                } else if (out.owner == 0) return error.InvalidChangeRecord;
            }
            const spec = out.spec;
            if ((spec.type_oid != 20 and spec.type_oid != 21 and spec.type_oid != 23) or spec.increment == 0 or spec.min >= spec.max or spec.start < spec.min or spec.start > spec.max)
                return error.InvalidChangeRecord;
            return out;
        }

        fn validSpec(spec: sequence.Spec) bool {
            return (spec.type_oid == 20 or spec.type_oid == 21 or spec.type_oid == 23) and spec.increment != 0 and spec.min < spec.max and
                spec.start >= spec.min and spec.start <= spec.max and spec.cache >= 1;
        }

        /// Op 14 fields after the OID.
        const SequenceState = struct { spec: sequence.Spec, last_value: i64, is_called: bool };

        fn decodeSequenceState(reader: *Reader) Error!SequenceState {
            var out: SequenceState = .{ .spec = .{}, .last_value = 0, .is_called = false };
            out.spec.type_oid = try reader.int(u32);
            out.spec.increment = try reader.int(i64);
            out.spec.min = try reader.int(i64);
            out.spec.max = try reader.int(i64);
            out.spec.start = try reader.int(i64);
            const cycle = try reader.int(u8);
            out.spec.cache = try reader.int(i64);
            out.last_value = try reader.int(i64);
            const called = try reader.int(u8);
            if (cycle > 1 or called > 1 or !validSpec(out.spec)) return error.InvalidChangeRecord;
            out.spec.cycle = cycle == 1;
            out.is_called = called == 1;
            if (out.last_value < out.spec.min or out.last_value > out.spec.max) return error.InvalidChangeRecord;
            return out;
        }

        fn findVSeq(scratch: *Scratch, oid: u32) Error!usize {
            for (&scratch.seqs, 0..) |*seq, index| if (seq.live and seq.oid == oid) return index;
            return error.ChangeRecordConflict;
        }

        /// Relation names, including sequences, are unique per schema.
        fn tableNameTaken(scratch: *const Scratch, name: []const u8, namespace: u32) bool {
            for (&scratch.tables) |*vt| if (vt.live and vt.namespace == namespace and types.same(vt.name.slice(), name)) return true;
            return false;
        }

        fn sequenceNameTaken(scratch: *const Scratch, name: []const u8, namespace: u32) bool {
            for (&scratch.seqs) |*seq| if (seq.live and seq.namespace == namespace and types.same(seq.name.slice(), name)) return true;
            return false;
        }

        fn relationNameTaken(scratch: *const Scratch, name: []const u8, namespace: u32) bool {
            return tableNameTaken(scratch, name, namespace) or sequenceNameTaken(scratch, name, namespace);
        }

        fn nameTaken(scratch: *const Scratch, name: []const u8, namespace: u32) bool {
            return relationNameTaken(scratch, name, namespace) or scratch.object_overlay.userTypeNameTaken(namespace, name);
        }

        fn findVSchema(scratch: *Scratch, oid: u32) Error!usize {
            for (&scratch.schemas, 0..) |*schema, index| if (schema.live and schema.oid == oid) return index;
            return error.ChangeRecordConflict;
        }

        fn overlaps(start: u32, width: u32, oid: u32, oid_width: u32) bool {
            return @as(u64, oid) < @as(u64, start) + width and @as(u64, start) < @as(u64, oid) + oid_width;
        }

        /// Whether [oid, oid + width) meets an OID the record or the database
        /// still holds: a table and its primary-key index, or a
        /// sequence. Database slots count until reclaimed, even uncommitted.
        fn oidTaken(db: anytype, scratch: *const Scratch, oid: u32, width: u32) bool {
            for (&scratch.objects.objects) |*object| if (object.live and overlaps(object.oid, 1, oid, width)) return true;
            return oidTakenIn(db, scratch, oid, width);
        }

        fn oidTakenIn(db: anytype, scratch: *const Scratch, oid: u32, width: u32) bool {
            for (&scratch.tables) |*vt| if (vt.live) {
                if (overlaps(vt.oid, 1, oid, width) or overlaps(S.primaryIndexAlias(vt.oid, vt.keyed, vt.primary_index_oid), 1, oid, width)) return true;
                for (vt.index_oids[0..vt.index_count]) |index_oid| if (overlaps(index_oid, 1, oid, width)) return true;
            };
            for (&db.tables) |*table| if (table.live) for (table.indexes[0..table.index_count]) |*index| {
                if (overlaps(index.oid, 1, oid, width)) return true;
            };
            for (&scratch.seqs) |*vs| if (vs.live and overlaps(vs.oid, 1, oid, width)) return true;
            for (&db.tables) |*table| if (table.live) {
                if (overlaps(table.oid, 1, oid, width) or overlaps(S.primaryIndexOid(table), 1, oid, width)) return true;
            };
            for (&db.seqs) |*seq| if (seq.live and overlaps(seq.oid, 1, oid, width)) return true;
            for (&scratch.schemas) |*vs| if (vs.live and overlaps(vs.oid, 1, oid, width)) return true;
            for (&db.schemas) |*schema| if (schema.live and overlaps(schema.oid, 1, oid, width)) return true;
            if (scratch.object_overlay.oidTaken(oid, width)) return true;
            return false;
        }

        const mask = overlay_capacity - 1;

        fn rowHome(table: u8, rowid: u64) usize {
            return storage.mix(rowid ^ (@as(u64, table) << 56)) & mask;
        }

        fn keyHome(table: u8, hash: usize) usize {
            return storage.mix(@as(u64, hash) ^ (@as(u64, table) << 56)) & mask;
        }

        fn findRow(scratch: *Scratch, table: u8, rowid: u64) ?usize {
            var position = rowHome(table, rowid);
            while (true) {
                const entry = &scratch.rows[position];
                if (entry.epoch != scratch.epoch) return null;
                if (entry.table == table and entry.rowid == rowid) return position;
                position = (position + 1) & mask;
            }
        }

        fn putRow(scratch: *Scratch, value: RowEntry) Error!void {
            if (findRow(scratch, value.table, value.rowid)) |position| {
                scratch.rows[position] = value;
                return;
            }
            var position = rowHome(value.table, value.rowid);
            var probes: usize = 0;
            while (scratch.rows[position].epoch == scratch.epoch) : (position = (position + 1) & mask) {
                probes += 1;
                if (probes == overlay_capacity / 2) return error.ChangeRecordConflict;
            }
            scratch.rows[position] = value;
        }

        fn removeRowAt(scratch: *Scratch, start: usize) void {
            var hole = start;
            var probe = start;
            while (true) {
                probe = (probe + 1) & mask;
                const entry = scratch.rows[probe];
                if (entry.epoch != scratch.epoch) break;
                const distance_entry = (probe -% rowHome(entry.table, entry.rowid)) & mask;
                if (((probe -% hole) & mask) <= distance_entry) {
                    scratch.rows[hole] = entry;
                    hole = probe;
                }
            }
            scratch.rows[hole].epoch = scratch.epoch -% 1;
        }

        fn putKey(scratch: *Scratch, table: u8, hash: usize, rowid: u64) Error!void {
            var position = keyHome(table, hash);
            var probes: usize = 0;
            while (scratch.keys[position].epoch == scratch.epoch) : (position = (position + 1) & mask) {
                probes += 1;
                if (probes == overlay_capacity / 2) return error.ChangeRecordConflict;
            }
            scratch.keys[position] = .{ .epoch = scratch.epoch, .table = table, .hash = hash, .rowid = rowid };
        }

        fn removeKeyAt(scratch: *Scratch, start: usize) void {
            var hole = start;
            var probe = start;
            while (true) {
                probe = (probe + 1) & mask;
                const entry = scratch.keys[probe];
                if (entry.epoch != scratch.epoch) break;
                const distance_entry = (probe -% keyHome(entry.table, entry.hash)) & mask;
                if (((probe -% hole) & mask) <= distance_entry) {
                    scratch.keys[hole] = entry;
                    hole = probe;
                }
            }
            scratch.keys[hole].epoch = scratch.epoch -% 1;
        }

        fn removeKey(scratch: *Scratch, table: u8, hash: usize, rowid: u64) void {
            var position = keyHome(table, hash);
            while (scratch.keys[position].epoch == scratch.epoch) : (position = (position + 1) & mask) {
                const entry = &scratch.keys[position];
                if (entry.table == table and entry.hash == hash and entry.rowid == rowid) {
                    removeKeyAt(scratch, position);
                    return;
                }
            }
        }

        /// Removes every overlay entry of a dropped table slot. Backward
        /// shifts only move entries into the current or a later hole, so
        /// re-checking the same position visits every entry.
        fn purge(scratch: *Scratch, table: u8) void {
            var position: usize = 0;
            while (position < overlay_capacity) {
                const entry = &scratch.rows[position];
                if (entry.epoch == scratch.epoch and entry.table == table) {
                    removeRowAt(scratch, position);
                    continue;
                }
                position += 1;
            }
            position = 0;
            while (position < overlay_capacity) {
                const entry = &scratch.keys[position];
                if (entry.epoch == scratch.epoch and entry.table == table) {
                    removeKeyAt(scratch, position);
                    continue;
                }
                position += 1;
            }
        }

        // ----- decoding -------------------------------------------------

        const Value = struct { cell: V.Cell, offset: u32 };

        fn decodeValue(reader: *Reader) Error!Value {
            const offset: u32 = @intCast(reader.position);
            const tag = try reader.int(u8);
            const cell: V.Cell = switch (tag) {
                0 => .null_value,
                1 => .{ .integer = try reader.int(i64) },
                2 => blk: {
                    const value = try reader.int(u8);
                    if (value > 1) return error.InvalidChangeRecord;
                    break :blk .{ .boolean = value == 1 };
                },
                3, 11, 12, 14 => blk: {
                    const len = try reader.int(u32);
                    if (len > config.text_bytes) return error.ChangeRecordConflict;
                    var text: V.Text = .{ .len = len };
                    @memcpy(text.bytes[0..len], try reader.take(len));
                    if (tag == 3) break :blk .{ .text = text };
                    if (tag == 12) break :blk .{ .bpchar = text };
                    if (tag == 14) break :blk .{ .bytea = text };
                    if (!jsonb.validBinary(text.slice(), config.json_depth, config.numeric_digits)) return error.InvalidChangeRecord;
                    break :blk .{ .jsonb = text };
                },
                4 => .{ .float4 = @bitCast(try reader.int(u32)) },
                5 => .{ .float8 = @bitCast(try reader.int(u64)) },
                6 => blk: {
                    const special = try reader.int(u8);
                    const negative = try reader.int(u8);
                    if (special > 3 or negative > 1) return error.InvalidChangeRecord;
                    var out: numeric.Numeric = .{ .special = @enumFromInt(special), .negative = negative == 1, .dscale = try reader.int(u16) };
                    for (&out.limbs) |*limb| limb.* = try reader.int(u64);
                    if (out.dscale > numeric.max_scale or numeric.digitCount(out.coef()) > config.numeric_digits) return error.InvalidChangeRecord;
                    if (out.special != .finite and (out.coef() != 0 or out.dscale != 0 or out.negative)) return error.InvalidChangeRecord;
                    if (out.negative and out.coef() == 0) return error.InvalidChangeRecord;
                    break :blk .{ .numeric = out };
                },
                7 => blk: {
                    const days = try reader.int(i32);
                    if (temporal.finiteDate(days) and !temporal.validDate(days)) return error.InvalidChangeRecord;
                    break :blk .{ .date = days };
                },
                8, 9 => blk: {
                    const us = try reader.int(i64);
                    if (temporal.finiteTimestamp(us) and !temporal.validTimestamp(us)) return error.InvalidChangeRecord;
                    break :blk if (tag == 8) V.Cell{ .timestamp = us } else V.Cell{ .timestamptz = us };
                },
                10 => .{ .interval = .{ .months = try reader.int(i32), .days = try reader.int(i32), .us = try reader.int(i64) } },
                13 => .{ .uuid = (try reader.take(16))[0..16].* },
                15 => blk: {
                    const us = try reader.int(i64);
                    if (!time_of_day.validTime(us)) return error.InvalidChangeRecord;
                    break :blk .{ .time = us };
                },
                18 => .{ .money = try reader.int(i64) },
                19 => .{ .pg_lsn = try reader.int(u64) },
                20 => .{ .xid8 = try reader.int(u64) },
                21 => try decodeArray(reader),
                22 => try decodeRange(reader),
                23 => blk: {
                    const head = try reader.take(3);
                    var value: network.Inet = .{ .family = head[0], .bits = head[1], .cidr = head[2] == 1 };
                    @memcpy(&value.address, try reader.take(16));
                    if ((value.family != 4 and value.family != 6) or value.bits > value.maxBits() or head[2] > 1) return error.InvalidChangeRecord;
                    if (value.family == 4 and !std_zero(value.address[4..])) return error.InvalidChangeRecord;
                    if (value.cidr and !network.maskClean(&value)) return error.InvalidChangeRecord;
                    break :blk .{ .inet = value };
                },
                24 => .{ .macaddr = (try reader.take(6))[0..6].* },
                46 => .{ .macaddr8 = (try reader.take(8))[0..8].* },
                40 => try decodeMultirange(reader),
                57 => try decodeRecord(reader),
                41 => blk: {
                    const len = try reader.int(u32);
                    if (len > config.text_bytes) return error.ChangeRecordConflict;
                    var text: V.Text = .{ .len = len };
                    @memcpy(text.bytes[0..len], try reader.take(len));
                    if (!@import("geometry.sig").valid(text.slice())) return error.InvalidChangeRecord;
                    break :blk .{ .geo = text };
                },
                30 => .{ .regtype = try reader.int(u32) },
                31 => .{ .pg_internal_char = try reader.int(u8) },
                32 => .{ .regproc = try reader.int(u32) },
                28, 29 => blk: {
                    const len = try reader.int(u32);
                    if (len > config.text_bytes) return error.ChangeRecordConflict;
                    var text: V.Text = .{ .len = len };
                    @memcpy(text.bytes[0..len], try reader.take(len));
                    // Only canonical text (what the engine writes) replays.
                    const TS = text_search.TextSearch(config.text_bytes, config.expr_depth);
                    if (tag == 28) {
                        if (!TS.canonicalVector(text.slice())) return error.InvalidChangeRecord;
                        break :blk .{ .tsvector = text };
                    }
                    if (!TS.canonicalQuery(text.slice())) return error.InvalidChangeRecord;
                    break :blk .{ .tsquery = text };
                },
                27 => blk: {
                    const len = try reader.int(u32);
                    if (len > config.text_bytes) return error.ChangeRecordConflict;
                    var text: V.Text = .{ .len = len };
                    @memcpy(text.bytes[0..len], try reader.take(len));
                    break :blk .{ .xml = text };
                },
                25 => blk: {
                    const x: f64 = @bitCast(try reader.int(u64));
                    break :blk .{ .point = .{ .x = x, .y = @bitCast(try reader.int(u64)) } };
                },
                26 => blk: {
                    var coordinates: [4]f64 = undefined;
                    for (&coordinates) |*coordinate| coordinate.* = @bitCast(try reader.int(u64));
                    // box_in keeps the high corner first.
                    if (coordinates[0] < coordinates[2] or coordinates[1] < coordinates[3]) return error.InvalidChangeRecord;
                    break :blk .{ .box = .{ .high = .{ .x = coordinates[0], .y = coordinates[1] }, .low = .{ .x = coordinates[2], .y = coordinates[3] } } };
                },
                17 => blk: {
                    const bits = try reader.int(u32);
                    if (bits > V.BitString.max_bits) return error.ChangeRecordConflict;
                    var value: V.BitString = .{ .len = bits };
                    const count = bit_string.byteLength(bits);
                    @memcpy(value.bytes[0..count], try reader.take(count));
                    if (!value.padded()) return error.InvalidChangeRecord;
                    break :blk .{ .bits = value };
                },
                16 => blk: {
                    const us = try reader.int(i64);
                    const zone = try reader.int(i32);
                    if (!time_of_day.validTime(us) or !time_of_day.validZone(zone)) return error.InvalidChangeRecord;
                    break :blk .{ .timetz = .{ .us = us, .zone = zone } };
                },
                else => return error.InvalidChangeRecord,
            };
            return .{ .cell = cell, .offset = offset };
        }

        /// Value tag 21: a scalar element type, at most six dimensions and
        /// exactly the shape's element count, each NULL or of the element's
        /// cell kind; capacity overflow is ChangeRecordConflict.
        fn decodeArray(reader: *Reader) Error!V.Cell {
            const element = types.typeFromOid(try reader.int(u32)) orelse return error.InvalidChangeRecord;
            if (types.elementData(element) != null) return error.InvalidChangeRecord;
            var shape: array.Shape = .{ .element = element, .ndim = try reader.int(u8) };
            if (shape.ndim > array.max_dims) return error.InvalidChangeRecord;
            for (0..shape.ndim) |dim| {
                shape.dims[dim] = try reader.int(u32);
                shape.lbounds[dim] = try reader.int(i32);
                if (shape.dims[dim] == 0) return error.InvalidChangeRecord;
            }
            var result: V.Text = .{};
            var writer = V.Arrays.Writer.begin(&result, &shape) catch |err| return if (err == error.TextCapacity) error.ChangeRecordConflict else error.InvalidChangeRecord;
            while (!writer.complete()) {
                // Elements are scalars: no nested arrays (and no recursion).
                if (reader.position < reader.bytes.len and reader.bytes[reader.position] == 21) return error.InvalidChangeRecord;
                const item = (try decodeValue(reader)).cell;
                if (item != .null_value and @as(V.CellTag, item) != V.cellTag(element)) return error.InvalidChangeRecord;
                writer.append(&item) catch |err| return if (err == error.TextCapacity) error.ChangeRecordConflict else error.InvalidChangeRecord;
            }
            return .{ .array = result };
        }

        /// Value tag 22: a range subtype, known flags and its finite bounds
        /// of the subtype's cell kind; the range is remade (validated and
        /// canonical) before it is accepted.
        fn decodeRange(reader: *Reader) Error!V.Cell {
            const subtype = types.typeFromOid(try reader.int(u32)) orelse return error.InvalidChangeRecord;
            if (types.rangeOfData(subtype) == null) return error.InvalidChangeRecord;
            const flags = try reader.int(u8);
            if (flags & ~@as(u8, 0x1f) != 0) return error.InvalidChangeRecord;
            const R = V.Ranges;
            var lower: R.Bound = .{ .lower = true, .inclusive = flags & range.lower_inclusive_flag != 0 };
            var upper: R.Bound = .{ .lower = false, .inclusive = flags & range.upper_inclusive_flag != 0 };
            const empty = flags & range.empty_flag != 0;
            for ([_]*R.Bound{ &lower, &upper }, [_]u8{ range.lower_infinite_flag, range.upper_infinite_flag }) |bound, infinite| {
                if (empty or flags & infinite != 0) continue;
                if (reader.position < reader.bytes.len and (reader.bytes[reader.position] == 21 or reader.bytes[reader.position] == 22)) return error.InvalidChangeRecord;
                const cell = (try decodeValue(reader)).cell;
                if (@as(V.CellTag, cell) != V.cellTag(subtype)) return error.InvalidChangeRecord;
                bound.value = cell;
                bound.infinite = false;
            }
            const made = R.make(subtype, lower, upper, empty) catch return error.InvalidChangeRecord;
            var out: V.Text = .{};
            R.encode(&made, &out) catch return error.ChangeRecordConflict;
            return .{ .range = out };
        }

        /// Value tag 57 (B11 wave 5, composite lane): a record's type OID
        /// (`record` or an allocated OID), a field count and per field a
        /// built-in type OID, a typmod valid for it and a value of its cell
        /// kind (never another record: no recursion). The in-cell record is
        /// rebuilt; capacity overflow is ChangeRecordConflict.
        fn decodeRecord(reader: *Reader) Error!V.Cell {
            const type_oid = try reader.int(u32);
            if (type_oid != types.record_oid and type_oid < first_oid) return error.InvalidChangeRecord;
            const count = try reader.int(u8);
            var out: V.Text = .{};
            var builder = V.Records.Builder.begin(&out, type_oid) catch return error.ChangeRecordConflict;
            for (0..count) |_| {
                const data_type = types.typeFromOid(try reader.int(u32)) orelse return error.InvalidChangeRecord;
                if (data_type == .record or data_type == .void or data_type == .mysql_bigint_unsigned) return error.InvalidChangeRecord;
                const typmod = try reader.int(i32);
                if (!types.validTypeTypmod(config, data_type, typmod)) return error.InvalidChangeRecord;
                if (reader.position < reader.bytes.len and reader.bytes[reader.position] == 57) return error.InvalidChangeRecord;
                const cell = (try decodeValue(reader)).cell;
                if (cell != .null_value and @as(V.CellTag, cell) != V.cellTag(data_type)) return error.InvalidChangeRecord;
                const member: V.Column = .{ .data_type = data_type, .typmod = typmod };
                V.validate(&member, &cell) catch return error.InvalidChangeRecord;
                builder.append(data_type, typmod, &cell) catch |err| return if (err == error.TextCapacity) error.ChangeRecordConflict else error.InvalidChangeRecord;
            }
            return .{ .record = out };
        }

        /// Value tag 40: a range type, a count and that many tag-22
        /// ranges; replay rebuilds the multirange and accepts it only when
        /// the record was canonical (sorted, disjoint, non-adjacent).
        fn decodeMultirange(reader: *Reader) Error!V.Cell {
            const range_type = types.typeFromOid(try reader.int(u32)) orelse return error.InvalidChangeRecord;
            if (types.rangeSubtype(types.typeOfData(range_type)) == null) return error.InvalidChangeRecord;
            const MR = V.Multiranges;
            const total = try reader.int(u16);
            var set: V.Text = .{};
            var scratch_text: V.Text = .{};
            MR.empty(range_type, &set);
            for (0..total) |_| {
                if (reader.position >= reader.bytes.len or reader.bytes[reader.position] != 22) return error.InvalidChangeRecord;
                reader.position += 1;
                const cell = try decodeRange(reader);
                const component = V.Ranges.decode(cell.range.slice());
                if (component.empty or V.Ranges.subtypeOf(cell.range.slice()) != types.dataTypeOf(types.rangeSubtype(types.typeOfData(range_type)).?)) return error.InvalidChangeRecord;
                MR.add(&set, &component, &scratch_text) catch return error.ChangeRecordConflict;
            }
            if (MR.count(set.slice()) != total) return error.InvalidChangeRecord;
            return .{ .multirange = set };
        }

        fn valueAt(record: []const u8, offset: u32) Error!V.Cell {
            var reader = Reader{ .bytes = record, .position = offset };
            return (try decodeValue(&reader)).cell;
        }

        fn sameValue(left: *const V.Cell, right: *const V.Cell) bool {
            if (@as(V.CellTag, left.*) != @as(V.CellTag, right.*)) return false;
            return V.compare(left, right) == 0;
        }

        const Definition = struct {
            oid: u32,
            name: V.Name,
            columns: [config.columns]V.Column,
            count: usize,
            namespace: u32 = public_namespace,
            constraints: [S.constraint_capacity]S.Constraint = undefined,
            constraint_count: usize = 0,
            has_constraint_ids: bool = false,
            primary_constraint_oid: u32 = 0,
            primary_index_oid: u32 = 0,
            extras: S.Extras = .{},

            fn keyed(self: *const Definition) bool {
                for (self.columns[0..self.count]) |*column| if (column.primary_key) return true;
                for (self.constraints[0..self.constraint_count]) |*constraint| if (constraint.kind == .primary) return true;
                return false;
            }
        };

        const public_namespace: u32 = 2200;

        fn validName(value: []const u8) bool {
            // These are decoded identifier bytes, not unquoted SQL tokens.
            // Quoted names preserve case, punctuation and non-ASCII bytes.
            if (value.len == 0 or value.len > config.name_bytes) return false;
            for (value) |byte| if (byte == 0) return false;
            return true;
        }

        fn decodeCreate(reader: *Reader) Error!Definition {
            var out: Definition = .{ .oid = try reader.int(u32), .name = .{}, .columns = @splat(.{}), .count = 0 };
            try decodeDefinition(reader, &out);
            return out;
        }

        /// Version-2 tail: namespace and constraints, each checked against
        /// the decoded columns.
        fn decodeConstraints(reader: *Reader, out: *Definition, version: u16) Error!void {
            const v3 = version >= extensions_format_version;
            out.namespace = try reader.int(u32);
            const count = try reader.int(u8);
            if (count > S.constraint_capacity) return error.ChangeRecordConflict;
            var primary_entries: usize = 0;
            var flagged: ?usize = null;
            for (out.columns[0..out.count], 0..) |*column, index| if (column.primary_key) {
                flagged = index;
            };
            for (0..count) |index| {
                var constraint: S.Constraint = .{};
                const kind = try reader.int(u8);
                if (kind < 1 or kind > @as(u8, if (v3) 5 else 3)) return error.InvalidChangeRecord;
                constraint.kind = @enumFromInt(kind);
                const constraint_name = try reader.name();
                if (!validName(constraint_name)) return error.InvalidChangeRecord;
                constraint.name.len = constraint_name.len;
                @memcpy(constraint.name.bytes[0..constraint_name.len], constraint_name);
                for (out.constraints[0..index]) |*previous| if (types.same(previous.name.slice(), constraint.name.slice())) return error.InvalidChangeRecord;
                const flags = try reader.int(u8);
                if (flags > @as(u8, if (version >= not_valid_format_version) 31 else if (v3) 7 else 1)) return error.InvalidChangeRecord;
                constraint.nulls_not_distinct = flags & 1 != 0;
                constraint.deferrable = flags & 2 != 0;
                constraint.initially_deferred = flags & 4 != 0;
                constraint.not_valid = flags & 8 != 0;
                constraint.not_enforced = flags & 16 != 0;
                if ((constraint.not_valid or constraint.not_enforced) and constraint.kind != .check and constraint.kind != .foreign) return error.InvalidChangeRecord;
                if (constraint.initially_deferred and !constraint.deferrable) return error.InvalidChangeRecord;
                constraint.column_count = try reader.int(u8);
                if (constraint.column_count > out.count) return error.InvalidChangeRecord;
                const columns = try reader.take(constraint.column_count);
                for (columns, 0..) |column, position| {
                    if (column >= out.count) return error.InvalidChangeRecord;
                    for (columns[0..position]) |previous| if (previous == column) return error.InvalidChangeRecord;
                    constraint.columns[position] = column;
                }
                const text_len = try reader.int(u16);
                if (text_len > config.text_bytes) return error.ChangeRecordConflict;
                const text = try reader.take(text_len);
                constraint.expression.len = text_len;
                @memcpy(constraint.expression.bytes[0..text_len], text);
                switch (constraint.kind) {
                    .check => if (constraint.column_count != 0 or text_len == 0 or constraint.deferrable) return error.InvalidChangeRecord,
                    .unique => if (constraint.column_count == 0 or text_len != 0) return error.InvalidChangeRecord,
                    .foreign => {
                        if (constraint.column_count == 0 or text_len != 0 or constraint.nulls_not_distinct) return error.InvalidChangeRecord;
                        constraint.ref_oid = try reader.int(u32);
                        if (constraint.ref_oid < first_oid) return error.InvalidChangeRecord;
                        const referenced = try reader.take(constraint.column_count);
                        @memcpy(constraint.ref_columns[0..constraint.column_count], referenced);
                        for (referenced) |column| if (column >= config.columns) return error.InvalidChangeRecord;
                        const on_delete = try reader.int(u8);
                        const on_update = try reader.int(u8);
                        if (on_delete > 4 or on_update > 4) return error.InvalidChangeRecord;
                        constraint.on_delete = @enumFromInt(on_delete);
                        constraint.on_update = @enumFromInt(on_update);
                    },
                    .exclusion => {
                        if (constraint.column_count == 0 or text_len != 0 or constraint.nulls_not_distinct) return error.InvalidChangeRecord;
                        for (constraint.operators[0..constraint.column_count]) |*operator| {
                            const code = try reader.int(u8);
                            if (code < 1 or code > 2) return error.InvalidChangeRecord;
                            operator.* = @enumFromInt(code);
                        }
                    },
                    .primary => {
                        primary_entries += 1;
                        if (constraint.column_count == 0 or text_len != 0 or constraint.nulls_not_distinct) return error.InvalidChangeRecord;
                        if (constraint.column_count == 1) {
                            if (flagged != constraint.columns[0]) return error.InvalidChangeRecord;
                        } else {
                            if (flagged != null) return error.InvalidChangeRecord;
                            for (constraint.keyColumns()) |column| if (!out.columns[column].not_null) return error.InvalidChangeRecord;
                        }
                    },
                }
                out.constraints[index] = constraint;
            }
            if (primary_entries > 1) return error.InvalidChangeRecord;
            out.constraint_count = count;
        }

        fn decodeText(reader: *Reader, out: anytype) Error!void {
            const length = try reader.int(u16);
            if (length > out.bytes.len) return error.ChangeRecordConflict;
            const text = try reader.take(length);
            out.len = length;
            @memcpy(out.bytes[0..length], text);
        }

        /// Version-3 tail: relation kind, secondary indexes, view query and
        /// dependencies, inheritance parent and partitioning.
        fn decodeExtras(reader: *Reader, out: *Definition) Error!void {
            const extras = &out.extras;
            extras.relkind = try reader.int(u8);
            switch (extras.relkind) {
                'r', 'v', 'm', 'p' => {},
                else => return error.InvalidChangeRecord,
            }
            const index_count = try reader.int(u8);
            if (index_count > S.index_capacity) return error.ChangeRecordConflict;
            extras.index_count = index_count;
            for (extras.indexes[0..index_count], 0..) |*index, position| {
                index.* = .{};
                index.oid = try reader.int(u32);
                if (index.oid < first_oid or index.oid >= 0xfffffffe) return error.InvalidChangeRecord;
                const index_name = try reader.name();
                if (!validName(index_name)) return error.InvalidChangeRecord;
                index.name.len = index_name.len;
                @memcpy(index.name.bytes[0..index_name.len], index_name);
                for (extras.indexes[0..position]) |*previous| {
                    if (previous.oid == index.oid or types.same(previous.name.slice(), index.name.slice())) return error.InvalidChangeRecord;
                }
                const flags = try reader.int(u8);
                if (flags > 7) return error.InvalidChangeRecord;
                index.unique = flags & 1 != 0;
                index.nulls_not_distinct = flags & 2 != 0;
                index.hash = flags & 4 != 0;
                index.key_count = try reader.int(u8);
                if (index.key_count == 0 or index.key_count > config.columns) return error.InvalidChangeRecord;
                @memcpy(index.keys[0..index.key_count], try reader.take(index.key_count));
                @memcpy(index.options[0..index.key_count], try reader.take(index.key_count));
                var expressions: usize = 0;
                for (index.keyColumns(), index.options[0..index.key_count]) |column, option| {
                    if (option > 3) return error.InvalidChangeRecord;
                    if (column == S.expression_key) expressions += 1 else if (column >= out.count) return error.InvalidChangeRecord;
                }
                index.include_count = try reader.int(u8);
                if (index.include_count > config.columns) return error.InvalidChangeRecord;
                @memcpy(index.includes[0..index.include_count], try reader.take(index.include_count));
                for (index.includes[0..index.include_count]) |column| if (column >= out.count) return error.InvalidChangeRecord;
                try decodeText(reader, &index.expressions);
                try decodeText(reader, &index.predicate);
                var parts: usize = if (index.expressions.len == 0) 0 else 1;
                for (index.expressions.slice()) |byte| {
                    if (byte == 0) parts += 1;
                }
                if (parts != expressions) return error.InvalidChangeRecord;
                if (index.unique and (expressions != 0 or index.predicate.len != 0)) return error.InvalidChangeRecord;
                // A hash index has one key element, no ordering options, no
                // INCLUDE columns and is never unique.
                if (index.hash) {
                    if (index.unique or index.key_count != 1 or index.include_count != 0 or index.options[0] != 0) return error.InvalidChangeRecord;
                }
            }
            try decodeText(reader, &extras.query);
            const view = extras.relkind == 'v' or extras.relkind == 'm';
            if (view != (extras.query.len != 0)) return error.InvalidChangeRecord;
            const populated = try reader.int(u8);
            if (populated > 1) return error.InvalidChangeRecord;
            extras.populated = populated == 1;
            extras.depend_count = try reader.int(u8);
            if (extras.depend_count > config.tables) return error.ChangeRecordConflict;
            for (extras.depends[0..extras.depend_count]) |*oid| oid.* = try reader.int(u32);
            extras.parent = try reader.int(u32);
            const partition = &extras.partition;
            const strategy = try reader.int(u8);
            partition.key = try reader.int(u8);
            const bound = try reader.int(u8);
            partition.count = try reader.int(u8);
            partition.unbounded = try reader.int(u8);
            if (strategy > 2 or bound > 3 or partition.count > S.partition_values or partition.unbounded > 3) return error.InvalidChangeRecord;
            partition.strategy = @enumFromInt(strategy);
            partition.bound = @enumFromInt(bound);
            if ((partition.strategy == .none) != (extras.relkind != 'p')) return error.InvalidChangeRecord;
            if (partition.strategy != .none and partition.key >= out.count) return error.InvalidChangeRecord;
            if (partition.bound != .none and extras.parent == 0) return error.InvalidChangeRecord;
            for (partition.values[0..partition.count]) |*cell| cell.* = (try decodeValue(reader)).cell;
        }

        fn decodeDefinition(reader: *Reader, out: *Definition) Error!void {
            const table_name = try reader.name();
            if (!validName(table_name)) return error.InvalidChangeRecord;
            out.name.len = table_name.len;
            @memcpy(out.name.bytes[0..table_name.len], table_name);
            const version = try reader.int(u16);
            if (version < expr_format_version or version > column_extension_format_version) return error.UnsupportedLogVersion;
            out.count = try reader.int(u8);
            if (out.count == 0) return error.InvalidChangeRecord;
            if (out.count > config.columns) return error.ChangeRecordConflict;
            var has_primary = false;
            for (0..out.count) |index| {
                const column_name = try reader.name();
                if (!validName(column_name)) return error.InvalidChangeRecord;
                var column: V.Column = .{ .name = .{ .len = column_name.len } };
                @memcpy(column.name.bytes[0..column_name.len], column_name);
                for (out.columns[0..index]) |*previous|
                    if (types.same(previous.name.slice(), column.name.slice())) return error.InvalidChangeRecord;
                const type_code = try reader.int(u32);
                column.data_type = if (type_code == mysql_unsigned_type) .mysql_bigint_unsigned else
                    types.typeFromOid(type_code) orelse return error.UnsupportedLogVersion;
                column.typmod = try reader.int(i32);
                if (!types.validTypeTypmod(config, column.data_type, column.typmod)) return error.InvalidChangeRecord;
                var flags = try reader.int(u8);
                if (version >= extensions_format_version) {
                    column.virtual = flags & 0x20 != 0;
                    flags &= 0x1f;
                }
                if (flags >> 2 > @intFromEnum(types.DefaultKind.mysql_auto_increment)) return error.InvalidChangeRecord;
                column.not_null = flags & 1 != 0;
                column.primary_key = flags & 2 != 0;
                column.default_kind = @enumFromInt(flags >> 2);
                if (column.data_type == .mysql_bigint_unsigned and column.default_kind != .none)
                    return error.InvalidChangeRecord;
                if (column.primary_key) {
                    if (has_primary or !column.not_null) return error.InvalidChangeRecord;
                    has_primary = true;
                }
                const text_len = try reader.int(u16);
                const needs_text = column.default_kind == .default or column.default_kind == .generated;
                if (needs_text != (text_len != 0)) return error.InvalidChangeRecord;
                if (text_len > config.text_bytes) return error.ChangeRecordConflict;
                const text = try reader.take(text_len);
                column.expression.len = text_len;
                @memcpy(column.expression.bytes[0..text_len], text);
                if (version >= default_identity_format_version and needs_text) {
                    column.default_oid = try reader.int(u32);
                    if (!validConstraintOid(column.default_oid)) return error.InvalidChangeRecord;
                    for (out.columns[0..index]) |*previous| {
                        if (previous.default_oid == column.default_oid) return error.InvalidChangeRecord;
                    }
                }
                if ((column.default_kind == .identity_always or column.default_kind == .identity_by_default) and
                    (!column.not_null or (column.data_type != .smallint and column.data_type != .integer32 and column.data_type != .integer)))
                    return error.InvalidChangeRecord;
                if (column.default_kind == .mysql_auto_increment and (!column.primary_key or
                    (column.data_type != .integer32 and column.data_type != .integer))) return error.InvalidChangeRecord;
                out.columns[index] = column;
            }
            for (out.columns[0..out.count]) |*column| if (column.virtual and column.default_kind != .generated) return error.InvalidChangeRecord;
            if (version != expr_format_version) try decodeConstraints(reader, out, version);
            if (version >= extensions_format_version) try decodeExtras(reader, out);
            if (version >= constraint_identity_format_version) {
                out.has_constraint_ids = true;
                out.primary_constraint_oid = try reader.int(u32);
                if (out.keyed()) {
                    if (!validConstraintOid(out.primary_constraint_oid)) return error.InvalidChangeRecord;
                } else if (out.primary_constraint_oid != 0) return error.InvalidChangeRecord;
                for (out.constraints[0..out.constraint_count], 0..) |*constraint, i| {
                    if (constraint.kind == .primary) continue;
                    constraint.oid = try reader.int(u32);
                    if (!validConstraintOid(constraint.oid) or constraint.oid == out.primary_constraint_oid) return error.InvalidChangeRecord;
                    for (out.constraints[0..i]) |*previous| if (constraint.oid == previous.oid) return error.InvalidChangeRecord;
                }
            }
            if (version >= primary_index_identity_format_version) {
                out.primary_index_oid = try reader.int(u32);
                if (version == primary_index_identity_format_version or out.primary_index_oid != 0) {
                    if (!out.keyed() or !validConstraintOid(out.primary_index_oid) or out.primary_index_oid == out.oid) return error.InvalidChangeRecord;
                }
            }
            if (version >= column_extension_format_version) {
                var any = false;
                for (out.columns[0..out.count]) |*column| {
                    const flags = try reader.int(u8);
                    if (flags == 0) continue;
                    if (flags > 7) return error.InvalidChangeRecord;
                    any = true;
                    if (flags & 1 != 0) {
                        column.collation = try reader.int(u32);
                        // A known collation of a collatable column.
                        if (!collation_module.collatable(types.typeOfData(column.data_type)) or !collation_module.storedOid(column.collation)) return error.InvalidChangeRecord;
                    }
                    if (flags & 2 != 0) {
                        const label = try reader.name();
                        if (!validName(label) or label.len > config.name_bytes or !column.not_null) return error.InvalidChangeRecord;
                        column.not_null_name.len = label.len;
                        @memcpy(column.not_null_name.bytes[0..label.len], label);
                    }
                    if (flags & 4 != 0) {
                        column.domain = try reader.int(u32);
                        if (column.domain < first_oid) return error.InvalidChangeRecord;
                    }
                }
                if (!any) return error.InvalidChangeRecord;
            }
        }

        pub fn assignDefaultOids(columns: []V.Column, previous: []const V.Column, sources: []const u8, next: *u32) Error!void {
            for (columns, 0..) |*column, index| {
                column.default_oid = 0;
                if (column.default_kind != .default and column.default_kind != .generated) continue;
                if (sources.len != 0 and sources[index] < previous.len) {
                    const old = &previous[sources[index]];
                    if (old.default_kind == column.default_kind and (column.default_kind == .generated or
                        types.same(old.expression.slice(), column.expression.slice()))) column.default_oid = old.default_oid;
                }
                if (column.default_oid == 0) {
                    if (next.* == 0xffffffff) return error.TableCapacity;
                    column.default_oid = next.*;
                    next.* += 1;
                }
            }
        }

        fn resolveDefaultOids(definition: *Definition, previous: []const V.Column, sources: []const u8, next: *u32) Error!void {
            const columns = definition.columns[0..definition.count];
            // A version with persisted identities encodes all expressions.
            for (columns) |*column| {
                if (column.default_oid == 0) continue;
                for (columns) |*other| next.* = @max(next.*, other.default_oid + 1);
                return;
            }
            try assignDefaultOids(columns, previous, sources, next);
        }

        fn validateDefaultOids(scratch: *const Scratch, definition: *const Definition, replaced: ?usize, sources: []const u8) Error!void {
            for (definition.columns[0..definition.count], 0..) |*column, position| {
                if (column.default_oid == 0) continue;
                for (&scratch.tables, 0..) |*table, index| {
                    if (!table.live) continue;
                    for (table.columns[0..table.column_count], 0..) |*prior, prior_position| {
                        if (prior.default_oid != column.default_oid) continue;
                        if (replaced != index or sources[position] != prior_position) return error.ChangeRecordConflict;
                    }
                }
            }
        }

        fn validConstraintOid(oid: u32) bool {
            return oid >= first_oid and oid < 0xffffffff;
        }

        fn resolveConstraintOid(encoded: u32, legacy: bool, saved: u32, next: *u32) Error!u32 {
            if (!legacy) {
                next.* = @max(next.*, encoded + 1);
                return encoded;
            }
            if (saved != 0) return saved;
            if (!validConstraintOid(next.*)) return error.ChangeRecordConflict;
            const oid = next.*;
            next.* += 1;
            return oid;
        }

        fn resolveConstraintOids(definition: *Definition, previous: *const ConstraintIdentities, next: *u32) Error!void {
            const legacy = !definition.has_constraint_ids;
            if (definition.keyed()) {
                definition.primary_constraint_oid = try resolveConstraintOid(definition.primary_constraint_oid, legacy, previous.primary, next);
            }
            for (definition.constraints[0..definition.constraint_count]) |*constraint| {
                if (constraint.kind == .primary) continue;
                constraint.oid = try resolveConstraintOid(constraint.oid, legacy, previous.sameConstraint(constraint), next);
            }
        }

        fn constraintOidTaken(scratch: *const Scratch, oid: u32) bool {
            for (&scratch.tables) |*table| if (table.live and table.constraint_ids.has(oid)) return true;
            return false;
        }

        fn validateConstraintOids(scratch: *const Scratch, definition: *const Definition, previous: *const ConstraintIdentities) Error!void {
            const primary = definition.primary_constraint_oid;
            if (primary != 0 and primary != previous.primary and constraintOidTaken(scratch, primary)) return error.ChangeRecordConflict;
            for (definition.constraints[0..definition.constraint_count]) |*constraint| {
                if (constraint.kind == .primary) continue;
                // RENAME CONSTRAINT keeps the identity under a new name (ddl-dml).
                if (constraint.oid != previous.sameConstraint(constraint) and !previous.has(constraint.oid) and constraintOidTaken(scratch, constraint.oid)) return error.ChangeRecordConflict;
            }
        }

        /// Namespaces a replayed definition may name: public or a live schema.
        fn knownNamespace(scratch: *Scratch, namespace: u32) bool {
            if (namespace == public_namespace) return true;
            _ = findVSchema(scratch, namespace) catch return false;
            return true;
        }

        fn findVTable(scratch: *Scratch, oid: u32) Error!u8 {
            for (&scratch.tables, 0..) |*table, index| if (table.live and table.oid == oid) return @intCast(index);
            return error.ChangeRecordConflict;
        }

        /// Decodes `count` values for the table into row, checking types.
        fn decodeRow(reader: *Reader, table: *const VTable, row: *V.Row, key_offset: *u32) Error!void {
            const count = try reader.int(u8);
            if (count != table.column_count) return error.ChangeRecordConflict;
            for (0..count) |index| {
                const value = try decodeValue(reader);
                row.cells[index] = value.cell;
                // Stored values are already typed; integers must fit int4 columns.
                // A jsonpath that is not its own canonical text is corrupt
                // bytes (InvalidChangeRecord); other mismatches conflict.
                V.validate(&table.columns[index], &row.cells[index]) catch |err| return if (err == error.InvalidTextRepresentation) error.InvalidChangeRecord else error.ChangeRecordConflict;
                if (table.primary == index) key_offset.* = value.offset;
            }
        }

        fn rowExists(db: anytype, scratch: *Scratch, table: u8, rowid: u64) bool {
            if (findRow(scratch, table, rowid)) |position| return scratch.rows[position].live;
            const vt = &scratch.tables[table];
            if (!vt.base or rowid >= vt.base_next_rowid) return false;
            const entry = &db.tables[table];
            const slot = S.findRow(entry, rowid) orelse return false;
            return S.visible(entry, slot) != null;
        }

        fn keyTaken(db: anytype, scratch: *Scratch, record: []const u8, table: u8, key: *const V.Cell, exclude: u64) Error!bool {
            const vt = &scratch.tables[table];
            if (vt.base) {
                const entry = &db.tables[table];
                if (S.lookupKey(entry, key)) |slot| {
                    const rowid = entry.rows[slot].rowid;
                    if (rowid != exclude) {
                        const position = findRow(scratch, table, rowid) orelse return true;
                        const touched = &scratch.rows[position];
                        if (touched.live and touched.has_key) {
                            const current = try valueAt(record, touched.key_offset);
                            if (sameValue(&current, key)) return true;
                        }
                    }
                }
            }
            const hash = V.hash(key);
            var position = keyHome(table, hash);
            while (scratch.keys[position].epoch == scratch.epoch) : (position = (position + 1) & mask) {
                const entry = &scratch.keys[position];
                if (entry.table != table or entry.hash != hash or entry.rowid == exclude) continue;
                const row = findRow(scratch, table, entry.rowid) orelse continue;
                const current = try valueAt(record, scratch.rows[row].key_offset);
                if (sameValue(&current, key)) return true;
            }
            return false;
        }

        fn noteMutation(table: *VTable) Error!void {
            if (table.late_primary) return error.ChangeRecordConflict;
            table.mutated = true;
        }

        fn rangesOverlap(a: usize, a_len: usize, b: usize, b_len: usize) bool {
            if (a_len == 0 or b_len == 0) return false;
            return if (a <= b) b - a < a_len else a - b < b_len;
        }

        /// Op 105's rows (ddl-alter, wave 5): exactly the table's live rows,
        /// each once, complete and typed by the new definition, with unique
        /// keys. A rewritten key column leaves the database's key index
        /// stale, so the overlay then holds every row and key of the table.
        fn validateRewriteRows(db: anytype, scratch: *Scratch, record: []const u8, reader: *Reader, index: u8, rewritten: *const [config.columns]bool, row: *V.Row) Error!void {
            const vt = &scratch.tables[index];
            var any = false;
            for (rewritten[0..vt.column_count]) |flag| any = any or flag;
            if (!any) return error.InvalidChangeRecord;
            const count = try reader.int(u32);
            if (count != vt.live_rows) return error.ChangeRecordConflict;
            const rekey = if (vt.primary) |column| rewritten[column] else false;
            for (&scratch.rows) |*entry| {
                if (entry.epoch == scratch.epoch and entry.table == index) entry.rewritten = false;
            }
            if (rekey) {
                var position: usize = 0;
                while (position < overlay_capacity) {
                    const entry = &scratch.keys[position];
                    if (entry.epoch == scratch.epoch and entry.table == index) {
                        removeKeyAt(scratch, position);
                        continue;
                    }
                    position += 1;
                }
            }
            for (0..count) |_| {
                const rowid = try reader.int(u64);
                if (!rowExists(db, scratch, index, rowid)) return error.ChangeRecordConflict;
                const existing = findRow(scratch, index, rowid);
                if (existing) |position| if (scratch.rows[position].rewritten) return error.InvalidChangeRecord;
                var key_offset: u32 = 0;
                try decodeRow(reader, vt, row, &key_offset);
                if (vt.primary) |column| {
                    const base = vt.base;
                    if (rekey) vt.base = false;
                    const taken = keyTaken(db, scratch, record, index, &row.cells[column], rowid);
                    vt.base = base;
                    if (try taken) return error.ChangeRecordConflict;
                    if (!rekey) if (existing) |position| if (scratch.rows[position].has_key) {
                        const old = try valueAt(record, scratch.rows[position].key_offset);
                        removeKey(scratch, index, V.hash(&old), rowid);
                    };
                    try putKey(scratch, index, V.hash(&row.cells[column]), rowid);
                }
                try putRow(scratch, .{ .epoch = scratch.epoch, .table = index, .live = true, .has_key = vt.primary != null, .rowid = rowid, .key_offset = key_offset, .rewritten = true });
            }
            if (rekey) vt.base = false;
        }

        fn validateLatePrimary(db: anytype, scratch: *Scratch, record: []const u8, index: usize, columns: []const u8, definitions: []const V.Column) Error!void {
            if (!db.replayQuiescent()) return error.ChangeRecordConflict;
            const table = &db.tables[index];
            const bank = table.key_index[0..];
            const bank_start = @intFromPtr(bank.ptr);
            const bank_bytes = bank.len * @sizeOf(u32);
            if (rangesOverlap(bank_start, bank_bytes, @intFromPtr(record.ptr), record.len) or
                rangesOverlap(bank_start, bank_bytes, @intFromPtr(scratch), @sizeOf(Scratch))) return error.InvalidParameterValue;
            S.validatePrimaryColumns(table, columns, definitions, storage.committed_view, null) catch return error.ChangeRecordConflict;
        }

        pub const BaseImageRecord = struct {
            csn: u64,
            op: Op,
            bank: usize = 0,
            table_count: usize = 0,
            with_defaults: bool = false,
            with_schemas: bool = false,
            with_routines: bool = false,
            catalog_kind: ?catalog_objects.Kind = null,
        };

        fn baseImageSchema(relkind: u8, indexes: usize, parent: u32, dependencies: usize, constraints: usize, columns: []const V.Column, with_defaults: bool) bool {
            if (relkind != 'r' or indexes != 0 or parent != 0 or dependencies != 0 or constraints != 0) return false;
            for (columns) |column| {
                if (column.virtual) return false;
                // Composite columns need their types first (composite lane).
                if (column.data_type == .record) return false;
                switch (column.default_kind) {
                    .none => {},
                    .default, .identity_always, .identity_by_default => if (!with_defaults) return false,
                    else => return false,
                }
            }
            return true;
        }

        pub fn supportsBaseImage(table: *const S.Table) bool {
            return baseImageSchema(table.relkind, table.index_count, table.parent, table.depend_count, table.constraint_count, table.columns[0..table.column_count], true);
        }

        fn validate(db: anytype, record: []const u8, scratch: *Scratch, image: anytype) Error!void {
            const base_image = @TypeOf(image) == BaseImageRecord;
            const count = try opCount(record);
            const base_sequence = if (comptime base_image) image.op == .create_sequence else false;
            if (comptime base_image) {
                const required: usize = if (base_sequence) 2 else 1;
                if (count == 0 or count > config.tx_writes or (image.op != .insert and count != required))
                    return error.InvalidChangeRecord;
            }
            scratch.epoch +%= 1;
            if (scratch.epoch == 0) {
                @memset(&scratch.rows, .{});
                @memset(&scratch.keys, .{});
                scratch.epoch = 1;
            }
            for (&scratch.tables, &db.tables) |*vt, *table| {
                const committed = S.committedTable(table);
                vt.* = .{ .live = committed, .base = committed };
                if (!committed) continue;
                vt.oid = table.oid;
                vt.keyed = S.keyed(table);
                vt.primary_index_oid = table.primary_index_oid;
                vt.namespace = table.namespace;
                vt.name = table.name;
                vt.column_count = table.column_count;
                vt.columns = table.columns;
                vt.primary = table.primary_column;
                vt.base_next_rowid = table.next_rowid;
                vt.next_rowid = table.next_rowid;
                // Replay updates committed summaries with every published row
                // transition. Cross-check the count against occupied slots:
                // legacy or pinned state can retain rows with no live version.
                const summary = &table.summary;
                vt.live_rows = if (summary.valid and summary.csn != 0 and summary.csn <= db.csn and
                    summary.rows >= 0 and @as(u64, @intCast(summary.rows)) == table.row_used)
                    table.row_used
                else
                    S.liveRows(table);
                vt.relkind = table.relkind;
                vt.index_count = table.index_count;
                for (table.indexes[0..table.index_count], 0..) |*index, position| vt.index_oids[position] = index.oid;
                vt.constraint_ids = ConstraintIdentities.from(table.primary_constraint_oid, table.constraints[0..table.constraint_count]);
            }
            for (&scratch.seqs, &db.seqs) |*vs, *seq| {
                vs.* = .{ .live = seq.live and !seq.pending_create and seq.dead_csn == 0, .oid = seq.oid, .namespace = seq.namespace,
                    .name = seq.name, .owner = seq.owner, .owner_column = seq.owner_column };
                if (vs.live and seq.namespace != public_namespace and seq.owner != 0) {
                    const owner = &scratch.tables[try findVTable(scratch, seq.owner)];
                    if (seq.owner_column >= owner.column_count) return error.ChangeRecordConflict;
                    const kind = owner.columns[seq.owner_column].default_kind;
                    vs.identity = kind == .identity_always or kind == .identity_by_default;
                }
            }
            for (&scratch.schemas, &db.schemas) |*vs, *schema| {
                vs.* = .{ .live = schema.live and !schema.pending_create and schema.dead_csn == 0, .oid = schema.oid, .owner = schema.owner, .private_usage = schema.private_usage, .name = schema.name };
            }
            RC.beginOverlay(&scratch.objects, &db.objects);
            scratch.object_overlay.init(&db.catalog_objects);
            scratch.large_pages.active = false;
            scratch.large_pages.audit = false;
            var next_oid: u32 = first_oid + db.oid_counter;
            var next_constraint_oid = db.next_constraint_oid;
            var next_default_oid = db.next_default_oid;
            const object_check: ObjectCheck(@TypeOf(db)) = .{ .db = db, .scratch = scratch, .next_oid = &next_oid };
            var reader = Reader{ .bytes = record };
            var row: V.Row = .{};
            var check_schema_owners = false;
            var check_routine_references = false;
            var check_large_object_grants = false;
            var image_sequence: SequenceDefinition = undefined;
            for (0..count) |part| {
                const tag = try reader.int(u8);
                if (comptime base_image) {
                    const required = if (base_sequence and part == 1) Op.sequence else image.op;
                    const cached_definition = base_sequence and part == 0 and tag == @intFromEnum(Op.create_sequence_cached);
                    const scoped_sequence = image.with_schemas and base_sequence and part == 0 and
                        (tag == @intFromEnum(Op.create_scoped_sequence) or tag == @intFromEnum(Op.create_scoped_identity_sequence) or
                            tag == @intFromEnum(Op.create_scoped_serial_sequence));
                    const private_schema = image.with_schemas and required == .create_schema and tag == @intFromEnum(Op.create_private_schema);
                    if (tag != @intFromEnum(required) and !cached_definition and !scoped_sequence and !private_schema) return error.InvalidChangeRecord;
                }
                switch (tag) {
                    @intFromEnum(Op.create_table) => {
                        var definition = try decodeCreate(&reader);
                        // OIDs are taken when CREATE runs, so concurrent DDL
                        // commits in any OID order (STO-01): an OID need only
                        // be unused, not ascending. A primary key's index owns
                        // the next OID.
                        const width: u32 = 1 + @as(u32, @intFromBool(definition.keyed() and definition.primary_index_oid == 0));
                        if (!knownNamespace(scratch, definition.namespace)) return error.ChangeRecordConflict;
                        if (definition.oid < first_oid or definition.oid >= 0xfffffffe or oidTaken(db, scratch, definition.oid, width)) return error.ChangeRecordConflict;
                        if (definition.primary_index_oid != 0 and oidTaken(db, scratch, definition.primary_index_oid, 1)) return error.ChangeRecordConflict;
                        if (nameTaken(scratch, definition.name.slice(), definition.namespace)) return error.ChangeRecordConflict;
                        try compositeColumns(scratch, &definition);
                        const columns = definition.columns[0..definition.count];
                        var free: ?usize = null;
                        for (&scratch.tables, 0..) |*vt, index| {
                            if (!vt.live and free == null and S.createBankFits(&db.tables[index], columns, definition.extras.index_count)) free = index;
                        }
                        const index = free orelse return error.ChangeRecordConflict;
                        if (comptime base_image) {
                            const extras = &definition.extras;
                            if (index != image.bank or (!image.with_schemas and definition.namespace != public_namespace) or
                                !baseImageSchema(extras.relkind, extras.index_count,
                                extras.parent, extras.depend_count, definition.constraint_count, columns, image.with_defaults)) return error.ChangeRecordConflict;
                        }
                        if (!S.indexFits(&db.tables[index], definition.extras.index_count, 0)) return error.ChangeRecordConflict;
                        try validateExtras(db, scratch, &definition, null);
                        try resolveConstraintOids(&definition, &.{}, &next_constraint_oid);
                        try validateConstraintOids(scratch, &definition, &.{});
                        try resolveDefaultOids(&definition, &.{}, &.{}, &next_default_oid);
                        try validateDefaultOids(scratch, &definition, null, &.{});
                        purge(scratch, @intCast(index));
                        const vt = &scratch.tables[index];
                        vt.* = .{ .live = true, .mutated = true, .keyed = definition.keyed(), .primary_index_oid = definition.primary_index_oid, .namespace = definition.namespace, .oid = definition.oid, .name = definition.name, .column_count = definition.count, .columns = definition.columns, .next_rowid = 1, .relkind = definition.extras.relkind };
                        for (definition.columns[0..definition.count], 0..) |column, position| if (column.primary_key) {
                            vt.primary = position;
                        };
                        next_oid = @max(next_oid, definition.oid + width, definition.primary_index_oid + 1);
                        noteIndexes(vt, &definition, &next_oid);
                        vt.constraint_ids = ConstraintIdentities.from(definition.primary_constraint_oid, definition.constraints[0..definition.constraint_count]);
                    },
                    @intFromEnum(Op.drop_table) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        try noteMutation(&scratch.tables[index]);
                        scratch.tables[index].live = false;
                        scratch.tables[index].base = false;
                        purge(scratch, index);
                    },
                    @intFromEnum(Op.alter_table), @intFromEnum(Op.alter_table_rewrite) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        if (S.anyIntegralBank(&db.tables)) return error.ChangeRecordConflict;
                        const vt = &scratch.tables[index];
                        var definition: Definition = .{ .oid = vt.oid, .name = .{}, .columns = @splat(.{}), .count = 0 };
                        try decodeDefinition(&reader, &definition);
                        if (definition.namespace != vt.namespace) return error.ChangeRecordConflict;
                        try compositeColumns(scratch, &definition);
                        if (!types.same(definition.name.slice(), vt.name.slice()) and nameTaken(scratch, definition.name.slice(), vt.namespace)) return error.ChangeRecordConflict;
                        // ALTER COLUMN TYPE (op 105, ddl-alter): 0xfe marks a
                        // rewritten column, followed by its old position.
                        const rewrite = tag == @intFromEnum(Op.alter_table_rewrite);
                        var rewritten: [config.columns]bool = @splat(false);
                        var sources: [config.columns]u8 = undefined;
                        var used: [config.columns]bool = @splat(false);
                        for (definition.columns[0..definition.count], 0..) |*column, position| {
                            var origin = try reader.int(u8);
                            if (rewrite and origin == 0xfe) {
                                origin = try reader.int(u8);
                                if (origin >= vt.column_count or used[origin]) return error.ChangeRecordConflict;
                                used[origin] = true;
                                sources[position] = origin;
                                rewritten[position] = true;
                                continue;
                            }
                            sources[position] = origin;
                            if (origin == 0xff) {
                                const fill = (try decodeValue(&reader)).cell;
                                V.validate(column, &fill) catch |err| {
                                    // A NULL fill under NOT NULL is valid only for an empty table.
                                    if (err != error.NotNullViolation or vt.live_rows != 0) return error.ChangeRecordConflict;
                                };
                                continue;
                            }
                            if (origin >= vt.column_count or used[origin]) return error.ChangeRecordConflict;
                            used[origin] = true;
                            const previous = &vt.columns[origin];
                            if (previous.data_type != column.data_type or previous.typmod != column.typmod) return error.ChangeRecordConflict;
                        }
                        // The key column survives (moved or not) or the key is gone.
                        var primary: ?usize = null;
                        for (definition.columns[0..definition.count], 0..) |*column, position| if (column.primary_key) {
                            primary = position;
                        };
                        const late = definition.keyed() and !vt.keyed;
                        if (late and rewrite) return error.ChangeRecordConflict;
                        if (late) {
                            const base = &db.tables[index];
                            if (vt.mutated or !vt.base or definition.primary_index_oid == 0 or
                                // ATTACH PARTITION may give a plain table its parent's key (ddl-dml).
                                base.relkind != 'r' or base.parent != 0 or
                                definition.constraint_count != base.constraint_count + 1 or definition.extras.index_count != vt.index_count or
                                definition.count != vt.column_count or !types.same(definition.name.slice(), vt.name.slice()) or
                                oidTaken(db, scratch, definition.primary_index_oid, 1)) return error.ChangeRecordConflict;
                            for (definition.extras.indexes[0..vt.index_count], vt.index_oids[0..vt.index_count]) |*new, old| {
                                if (new.oid != old) return error.ChangeRecordConflict;
                            }
                            for (sources[0..definition.count], 0..) |source, column| {
                                if (source != column or !types.same(vt.columns[column].name.slice(), definition.columns[column].name.slice())) return error.ChangeRecordConflict;
                            }
                            const scalar = [1]u8{@intCast(primary orelse 0)};
                            const columns = if (primary != null) &scalar else blk: {
                                for (definition.constraints[0..definition.constraint_count]) |*constraint| {
                                    if (constraint.kind == .primary) break :blk constraint.keyColumns();
                                }
                                return error.ChangeRecordConflict;
                            };
                            try validateLatePrimary(db, scratch, record, index, columns, definition.columns[0..definition.count]);
                            vt.late_primary = true;
                            next_oid = @max(next_oid, definition.primary_index_oid + 1);
                        } else {
                            try noteMutation(vt);
                            if (primary) |column| {
                                const old = vt.primary orelse return error.ChangeRecordConflict;
                                if (sources[column] != old) return error.ChangeRecordConflict;
                            }
                            if (definition.keyed() and definition.primary_index_oid != vt.primary_index_oid) return error.ChangeRecordConflict;
                        }
                        if (definition.extras.relkind != vt.relkind) return error.ChangeRecordConflict;
                        if (!S.indexFits(&db.tables[index], definition.extras.index_count, 0)) return error.ChangeRecordConflict;
                        try validateExtras(db, scratch, &definition, vt);
                        try resolveConstraintOids(&definition, &vt.constraint_ids, &next_constraint_oid);
                        try validateConstraintOids(scratch, &definition, &vt.constraint_ids);
                        try resolveDefaultOids(&definition, vt.columns[0..vt.column_count], sources[0..definition.count], &next_default_oid);
                        try validateDefaultOids(scratch, &definition, index, sources[0..definition.count]);
                        noteIndexes(vt, &definition, &next_oid);
                        vt.constraint_ids = ConstraintIdentities.from(definition.primary_constraint_oid, definition.constraints[0..definition.constraint_count]);
                        // Identity sequences keep their column positions.
                        for (&db.seqs) |*seq| {
                            if (!seq.live or seq.owner != vt.oid or !vt.base) continue;
                            if (seq.owner_column >= definition.count or sources[seq.owner_column] != seq.owner_column) return error.ChangeRecordConflict;
                        }
                        vt.name = definition.name;
                        vt.columns = definition.columns;
                        vt.column_count = definition.count;
                        vt.primary = primary;
                        vt.keyed = definition.keyed();
                        vt.primary_index_oid = definition.primary_index_oid;
                        if (rewrite) try validateRewriteRows(db, scratch, record, &reader, index, &rewritten, &row);
                    },
                    @intFromEnum(Op.view_check_option) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        if (scratch.tables[index].relkind != 'v') return error.InvalidChangeRecord;
                        const option = try reader.int(u8);
                        if (option == 0 or option > 2) return error.InvalidChangeRecord;
                    },
                    @intFromEnum(Op.truncate) => {
                        // Every database row and every row created so far by
                        // this record is gone; later inserts may reuse keys.
                        const index = try findVTable(scratch, try reader.int(u32));
                        const vt = &scratch.tables[index];
                        try noteMutation(vt);
                        purge(scratch, index);
                        vt.base = false;
                        vt.live_rows = 0;
                    },
                    @intFromEnum(Op.insert) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        if (comptime base_image) if (index != image.bank) return error.ChangeRecordConflict;
                        const vt = &scratch.tables[index];
                        try noteMutation(vt);
                        const rowid = try reader.int(u64);
                        // Concurrent transactions commit in any order, so rowids
                        // need only be unused, not ascending.
                        if (rowid == 0 or rowid == 0xffffffffffffffff or rowExists(db, scratch, index, rowid)) return error.ChangeRecordConflict;
                        if (findRow(scratch, index, rowid) != null) return error.ChangeRecordConflict;
                        var key_offset: u32 = 0;
                        try decodeRow(&reader, vt, &row, &key_offset);
                        if (vt.live_rows >= db.tables[index].rows.len) return error.ChangeRecordConflict;
                        if (vt.primary) |column| {
                            if (try keyTaken(db, scratch, record, index, &row.cells[column], 0)) return error.ChangeRecordConflict;
                            try putKey(scratch, index, V.hash(&row.cells[column]), rowid);
                        }
                        try putRow(scratch, .{ .epoch = scratch.epoch, .table = index, .live = true, .has_key = vt.primary != null, .rowid = rowid, .key_offset = key_offset });
                        if (rowid + 1 > vt.next_rowid) vt.next_rowid = rowid + 1;
                        vt.live_rows += 1;
                    },
                    @intFromEnum(Op.update) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        const vt = &scratch.tables[index];
                        try noteMutation(vt);
                        const rowid = try reader.int(u64);
                        if (!rowExists(db, scratch, index, rowid)) return error.ChangeRecordConflict;
                        var key_offset: u32 = 0;
                        try decodeRow(&reader, vt, &row, &key_offset);
                        if (vt.primary) |column| {
                            if (try keyTaken(db, scratch, record, index, &row.cells[column], rowid)) return error.ChangeRecordConflict;
                            if (findRow(scratch, index, rowid)) |position| {
                                if (scratch.rows[position].has_key) {
                                    const old = try valueAt(record, scratch.rows[position].key_offset);
                                    removeKey(scratch, index, V.hash(&old), rowid);
                                }
                            }
                            try putKey(scratch, index, V.hash(&row.cells[column]), rowid);
                        }
                        try putRow(scratch, .{ .epoch = scratch.epoch, .table = index, .live = true, .has_key = vt.primary != null, .rowid = rowid, .key_offset = key_offset });
                    },
                    @intFromEnum(Op.delete) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        const vt = &scratch.tables[index];
                        try noteMutation(vt);
                        const rowid = try reader.int(u64);
                        if (!rowExists(db, scratch, index, rowid)) return error.ChangeRecordConflict;
                        const created = !vt.base or rowid >= vt.base_next_rowid;
                        if (findRow(scratch, index, rowid)) |position| {
                            if (scratch.rows[position].has_key) {
                                const old = try valueAt(record, scratch.rows[position].key_offset);
                                removeKey(scratch, index, V.hash(&old), rowid);
                            }
                            if (created) removeRowAt(scratch, position);
                        }
                        if (!created) try putRow(scratch, .{ .epoch = scratch.epoch, .table = index, .live = false, .rowid = rowid });
                        vt.live_rows -= 1;
                    },
                    @intFromEnum(Op.catalog_counters), @intFromEnum(Op.catalog_counters_with_constraints), @intFromEnum(Op.catalog_counters_with_defaults) => {
                        const counter = try reader.int(u32);
                        // next_oid is the maximum so far; a counter never lowers it.
                        if (counter < next_oid) return error.ChangeRecordConflict;
                        next_oid = counter;
                        const tables = try reader.int(u8);
                        if (comptime base_image) if (tables != image.table_count) return error.InvalidChangeRecord;
                        if (tables > config.tables) return error.ChangeRecordConflict;
                        var seen: if (base_image) [config.tables]bool else void = if (base_image) @splat(false) else {};
                        for (0..tables) |_| {
                            const index = try findVTable(scratch, try reader.int(u32));
                            if (comptime base_image) {
                                if (seen[index]) return error.InvalidChangeRecord;
                                seen[index] = true;
                            }
                            const next = try reader.int(u64);
                            if (next < scratch.tables[index].next_rowid) return error.ChangeRecordConflict;
                            scratch.tables[index].next_rowid = next;
                        }
                        if (tag != @intFromEnum(Op.catalog_counters)) {
                            const constraint_counter = try reader.int(u32);
                            if (constraint_counter < next_constraint_oid) return error.ChangeRecordConflict;
                            next_constraint_oid = constraint_counter;
                        }
                        if (tag == @intFromEnum(Op.catalog_counters_with_defaults)) {
                            const default_counter = try reader.int(u32);
                            if (default_counter < next_default_oid) return error.ChangeRecordConflict;
                            next_default_oid = default_counter;
                        }
                    },
                    @intFromEnum(Op.alter_sequence), @intFromEnum(Op.alter_sequence_ownership) => {
                        const index = try findVSeq(scratch, try reader.int(u32));
                        _ = try decodeSequenceState(&reader);
                        if (tag == @intFromEnum(Op.alter_sequence_ownership)) {
                            const seq = &scratch.seqs[index];
                            if (seq.owner != 0) {
                                const old = &scratch.tables[try findVTable(scratch, seq.owner)];
                                if (seq.owner_column >= old.column_count) return error.ChangeRecordConflict;
                                switch (old.columns[seq.owner_column].default_kind) {
                                    .identity_always, .identity_by_default, .mysql_auto_increment => return error.ChangeRecordConflict,
                                    else => {},
                                }
                            }
                            const owner = try reader.int(u32);
                            const column = try reader.int(u8);
                            if (owner != 0) {
                                const target = &scratch.tables[try findVTable(scratch, owner)];
                                if ((target.relkind != 'r' and target.relkind != 'p') or
                                    target.namespace != seq.namespace or column >= target.column_count)
                                    return error.ChangeRecordConflict;
                                switch (target.columns[column].default_kind) {
                                    .identity_always, .identity_by_default, .mysql_auto_increment => return error.ChangeRecordConflict,
                                    else => {},
                                }
                            } else if (column != 0) return error.InvalidChangeRecord;
                            seq.owner = owner;
                            seq.owner_column = column;
                        }
                    },
                    @intFromEnum(Op.create_schema), @intFromEnum(Op.create_owned_schema), @intFromEnum(Op.create_private_schema) => {
                        const oid = try reader.int(u32);
                        const schema_name = try reader.name();
                        const owner = if (tag != @intFromEnum(Op.create_schema)) try reader.int(u32) else catalog_objects.bootstrap_role;
                        if (!validName(schema_name)) return error.InvalidChangeRecord;
                        if (oid < first_oid or oid == 0xffffffff or oidTaken(db, scratch, oid, 1)) return error.ChangeRecordConflict;
                        if (!scratch.object_overlay.roleExists(owner)) return error.ChangeRecordConflict;
                        for (&scratch.schemas) |*vs| if (vs.live and types.same(vs.name.slice(), schema_name)) return error.ChangeRecordConflict;
                        var free: ?usize = null;
                        for (&scratch.schemas, 0..) |*vs, index| if (!vs.live and free == null) {
                            free = index;
                        };
                        const index = free orelse return error.ChangeRecordConflict;
                        scratch.schemas[index] = .{ .live = true, .oid = oid, .owner = owner, .private_usage = tag == @intFromEnum(Op.create_private_schema), .name = .{ .len = schema_name.len } };
                        @memcpy(scratch.schemas[index].name.bytes[0..schema_name.len], schema_name);
                        next_oid = @max(next_oid, oid + 1);
                    },
                    @intFromEnum(Op.drop_schema) => {
                        const index = try findVSchema(scratch, try reader.int(u32));
                        for (&scratch.tables) |*vt| if (vt.live and vt.namespace == scratch.schemas[index].oid) return error.ChangeRecordConflict;
                        if (RC.overlayNamespaceUsed(&scratch.objects, scratch.schemas[index].oid)) return error.ChangeRecordConflict;
                        scratch.schemas[index].live = false;
                    },
                    @intFromEnum(Op.create_routine)...@intFromEnum(Op.drop_rule), @intFromEnum(Op.create_routine_extended), @intFromEnum(Op.create_rule_action), @intFromEnum(Op.create_trigger_extended), @intFromEnum(Op.create_cast), @intFromEnum(Op.drop_cast) => {
                        const payload = try reader.take(try reader.int(u32));
                        const checks: ObjectChecks(@TypeOf(db)) = .{ .db = db, .scratch = scratch };
                        if (try RC.validateOp(&scratch.objects, tag, payload, checks)) |oid| next_oid = @max(next_oid, oid + 1);
                        check_routine_references = true;
                    },
                    @intFromEnum(Op.create_sequence), @intFromEnum(Op.create_sequence_cached), @intFromEnum(Op.create_scoped_identity_sequence), @intFromEnum(Op.create_scoped_sequence), @intFromEnum(Op.create_scoped_serial_sequence) => {
                        const definition = try decodeCreateSequence(&reader, tag);
                        if (base_sequence) {
                            if ((definition.owner == 0 and definition.owner_column != 0) or
                                (!image.with_defaults and definition.owner != 0)) return error.InvalidChangeRecord;
                            image_sequence = definition;
                        }
                        if (definition.oid < first_oid or definition.oid == 0xffffffff or oidTaken(db, scratch, definition.oid, 1)) return error.ChangeRecordConflict;
                        if (!object_check.objectSchemaLive(definition.namespace)) return error.ChangeRecordConflict;
                        if (relationNameTaken(scratch, definition.name.slice(), definition.namespace) or
                            scratch.object_overlay.compositeRelationNameTaken(definition.namespace, definition.name.slice())) return error.ChangeRecordConflict;
                        if (definition.owner != 0) {
                            const owner = try findVTable(scratch, definition.owner);
                            if (definition.owner_column >= scratch.tables[owner].column_count) return error.ChangeRecordConflict;
                            if (!base_image and tag == @intFromEnum(Op.create_scoped_serial_sequence) and
                                scratch.tables[owner].columns[definition.owner_column].default_kind != .default)
                                return error.ChangeRecordConflict;
                            if (tag == @intFromEnum(Op.create_scoped_identity_sequence) or
                                (!base_image and tag == @intFromEnum(Op.create_scoped_serial_sequence)))
                            {
                                for (&scratch.seqs) |*seq| {
                                    if (seq.live and seq.owner == definition.owner and seq.owner_column == definition.owner_column) return error.ChangeRecordConflict;
                                }
                            }
                        }
                        var free: ?usize = null;
                        for (&scratch.seqs, 0..) |*vs, index| if (!vs.live and free == null) {
                            free = index;
                        };
                        const index = free orelse return error.ChangeRecordConflict;
                        scratch.seqs[index] = .{ .live = true, .oid = definition.oid, .namespace = definition.namespace, .name = definition.name,
                            .owner = definition.owner, .owner_column = definition.owner_column,
                            .identity = tag == @intFromEnum(Op.create_scoped_identity_sequence),
                        };
                        next_oid = @max(next_oid, definition.oid + 1);
                    },
                    @intFromEnum(Op.drop_sequence) => {
                        const index = try findVSeq(scratch, try reader.int(u32));
                        scratch.seqs[index].live = false;
                    },
                    @intFromEnum(Op.sequence) => {
                        const oid = try reader.int(u32);
                        _ = try findVSeq(scratch, oid);
                        const value = try reader.int(i64);
                        const called = try reader.int(u8);
                        if (called > 1) return error.InvalidChangeRecord;
                        if (base_sequence and (oid != image_sequence.oid or
                            value < image_sequence.spec.min or value > image_sequence.spec.max)) return error.InvalidChangeRecord;
                    },
                    @intFromEnum(Op.object_create) => {
                        const object = try O.decodeCreate(record, &reader.position);
                        if (comptime base_image) {
                            if (image.catalog_kind != object.kind or
                                (object.kind == .comment and object.grantee != catalog_objects.class_large_object))
                                return error.InvalidChangeRecord;
                        }
                        if (object.kind == .large_object and object.largeObjectLength() != 0 and db.large_pages == null)
                            return error.ChangeRecordConflict;
                        try scratch.object_overlay.create(&object, &object_check);
                        check_large_object_grants = check_large_object_grants or object.kind == .large_object_acl or object.kind == .builtin_routine_acl;
                    },
                    @intFromEnum(Op.object_drop) => {
                        const key = try O.decodeDrop(record, &reader.position);
                        if (key.kind == .large_object) {
                            if (db.large_pages) |*pages| {
                                if ((scratch.object_overlay.largeObjectLength(key.target) orelse 0) != 0 or
                                    pages.page(.{ .oid = key.target, .page = 0 }, .{ .csn = db.csn }) != null)
                                    scratch.large_pages.audit = true;
                            }
                        }
                        // A composite type a live column uses stays (composite lane).
                        if (key.kind == .composite_type and (compositeInUse(scratch, key.oid) or RC.overlayUsesType(&scratch.objects, key.oid))) return error.ChangeRecordConflict;
                        try scratch.object_overlay.drop(&key);
                        check_schema_owners = check_schema_owners or key.kind == .role;
                        check_large_object_grants = check_large_object_grants or key.kind == .large_object_acl or key.kind == .builtin_routine_acl;
                    },
                    @intFromEnum(Op.large_object_page) => {
                        const page = try decodeLargeObjectPage(&reader);
                        if (!db.replayQuiescent() or db.large_pages == null) return error.ChangeRecordConflict;
                        try scratch.large_pages.validate(page, &db.large_pages.?, &scratch.object_overlay, db.csn);
                    },
                    else => return error.UnsupportedLogVersion,
                }
            }
            if (reader.position != record.len) return error.InvalidChangeRecord;
            for (&scratch.seqs) |*seq| {
                if (!seq.live or seq.namespace == public_namespace) continue;
                if (!object_check.objectSchemaLive(seq.namespace)) return error.ChangeRecordConflict;
                if (seq.owner == 0) continue;
                const owner = &scratch.tables[try findVTable(scratch, seq.owner)];
                if (seq.namespace != owner.namespace or seq.owner_column >= owner.column_count) return error.ChangeRecordConflict;
                const kind = owner.columns[seq.owner_column].default_kind;
                if (seq.identity and kind != .identity_always and kind != .identity_by_default) return error.ChangeRecordConflict;
            }
            // Objects never outlive the tables, roles and objects they name.
            try scratch.object_overlay.finish(&object_check);
            if (!base_image and check_large_object_grants) try scratch.object_overlay.verifyLargeObjectGrants();
            try scratch.large_pages.finish(db, &scratch.object_overlay);
            if (check_routine_references or check_schema_owners) try RC.finishOverlay(&scratch.objects, &scratch.object_overlay);
            if (check_schema_owners) for (&scratch.schemas) |*schema| {
                if (schema.live and !scratch.object_overlay.roleExists(scratch.object_overlay.schemaOwner(schema.oid, schema.owner))) return error.ChangeRecordConflict;
            };
        }

        /// Version-3 definition parts against the overlay: new secondary
        /// index OIDs unused (`previous` keeps its own), referenced and parent
        /// tables live (or the definition itself).
        fn validateExtras(db: anytype, scratch: *Scratch, definition: *const Definition, previous: ?*const VTable) Error!void {
            const primary_alias = S.primaryIndexAlias(definition.oid, definition.keyed(), definition.primary_index_oid);
            for (definition.extras.indexes[0..definition.extras.index_count]) |*index| {
                if (index.oid == primary_alias) return error.ChangeRecordConflict;
                if (previous) |vt| {
                    var kept = false;
                    for (vt.index_oids[0..vt.index_count]) |oid| kept = kept or oid == index.oid;
                    if (kept) continue;
                }
                if (index.oid == definition.oid or oidTaken(db, scratch, index.oid, 1)) return error.ChangeRecordConflict;
            }
            for (definition.constraints[0..definition.constraint_count]) |*constraint| {
                if (constraint.kind != .foreign or constraint.ref_oid == definition.oid) continue;
                const referenced = try findVTable(scratch, constraint.ref_oid);
                for (constraint.refColumns()) |column| if (column >= scratch.tables[referenced].column_count) return error.ChangeRecordConflict;
            }
            if (definition.extras.parent != 0 and definition.extras.parent != definition.oid) _ = try findVTable(scratch, definition.extras.parent);
        }

        fn noteIndexes(vt: *VTable, definition: *const Definition, next_oid: *u32) void {
            vt.index_count = definition.extras.index_count;
            for (definition.extras.indexes[0..definition.extras.index_count], 0..) |*index, position| {
                vt.index_oids[position] = index.oid;
                next_oid.* = @max(next_oid.*, index.oid + 1);
            }
        }

        fn explicitPrimaryHighWater(definition: *const Definition) u32 {
            return if (definition.primary_index_oid == 0) 0 else definition.primary_index_oid + 1 - first_oid;
        }

        fn indexOidWidth(extras: *const S.Extras) u32 {
            var high: u32 = 0;
            for (extras.indexes[0..extras.index_count]) |*index| high = @max(high, index.oid + 1 - first_oid);
            return high;
        }

        fn seqByOid(db: anytype, oid: u32) Error!usize {
            for (&db.seqs, 0..) |*seq, index| if (seq.live and seq.oid == oid) return index;
            return error.ChangeRecordConflict;
        }

        // ----- application (infallible after validation) ----------------

        fn tableByOid(db: anytype, oid: u32) Error!*S.Table {
            for (&db.tables) |*table| if (S.committedTable(table) and table.oid == oid) return table;
            return error.ChangeRecordConflict;
        }

        fn writeVersion(db: anytype, table: *S.Table, slot: u32, older: u32, row: *const V.Row, csn: u64) Error!u32 {
            try S.ensureVersions(table, 1, csn);
            try S.admitVersion(table, &row.cells);
            const version = S.createVersion(table, .{ .row = slot, .xmin = .{ .epoch = db.epoch }, .cid = db.cid, .csn = csn, .older = older }, &row.cells);
            S.indexKey(table, version);
            if (older == 0) {
                S.summarize(table, version, true, csn);
                S.scanPublish(table, version, true);
            }
            return version;
        }

        fn retire(db: anytype, table: *S.Table, version: u32, csn: u64) void {
            const entry = &table.versions[version];
            entry.markDeletion(.{ .epoch = db.epoch }, db.cid);
            entry.publishDeletion(csn);
            S.reclaimVersion(table, version);
        }

        /// `db` provides tables, catalog OID counters, csn, cid and epoch.
        pub fn apply(db: anytype, record: []const u8, scratch: *Scratch) Error!void {
            return applyRecord(db, record, scratch, null);
        }

        /// Restore one checked image part into an unpublished startup store.
        /// All image parts share the original committed SQL CSN.
        pub fn applyBaseImageRecord(db: anytype, record: []const u8, scratch: *Scratch, image: BaseImageRecord) Error!void {
            if (image.csn == 0 or (db.csn != 0 and db.csn != image.csn)) return error.InvalidParameterValue;
            switch (image.op) {
                .create_table, .insert => if (image.bank >= config.tables) return error.InvalidChangeRecord,
                .create_sequence => {},
                .create_schema => if (!image.with_schemas) return error.InvalidChangeRecord,
                .create_routine, .create_trigger, .create_rule => if (!image.with_routines) return error.InvalidChangeRecord,
                .object_create => switch (image.catalog_kind orelse return error.InvalidChangeRecord) {
                    .role, .large_object, .large_object_acl, .large_object_default_acl, .builtin_routine_acl, .routine_default_acl, .comment => {},
                    else => return error.InvalidChangeRecord,
                },
                .catalog_counters, .catalog_counters_with_constraints, .catalog_counters_with_defaults => if (image.table_count > config.tables) return error.InvalidChangeRecord,
                else => return error.InvalidChangeRecord,
            }
            return applyRecord(db, record, scratch, image);
        }

        fn applyRecord(db: anytype, record: []const u8, scratch: *Scratch, image: anytype) Error!void {
            const scratch_start = @intFromPtr(scratch);
            if (rangesOverlap(scratch_start, @sizeOf(Scratch), @intFromPtr(db), @sizeOf(@TypeOf(db.*))) or
                rangesOverlap(scratch_start, @sizeOf(Scratch), @intFromPtr(record.ptr), record.len)) return error.InvalidParameterValue;
            if (comptime config.external_storage) for (&db.tables) |*table| {
                const bank = table.key_index;
                if (rangesOverlap(scratch_start, @sizeOf(Scratch), @intFromPtr(bank.ptr), bank.len * @sizeOf(u32))) return error.InvalidParameterValue;
            };
            if (db.large_pages) |*pages| {
                const backing = pages.backing();
                inline for (.{ "rows", "versions", "version_rows", "row_index", "key_index" }) |field| {
                    const bank = @field(backing, field);
                    const bytes = bank.len * @sizeOf(@TypeOf(bank[0]));
                    if (rangesOverlap(scratch_start, @sizeOf(Scratch), @intFromPtr(bank.ptr), bytes) or
                        rangesOverlap(@intFromPtr(record.ptr), record.len, @intFromPtr(bank.ptr), bytes))
                        return error.InvalidParameterValue;
                }
            }
            try validate(db, record, scratch, image);
            // Validated: the remaining errors are unreachable invariants.
            const csn = if (comptime @TypeOf(image) == BaseImageRecord) image.csn else db.csn + 1;
            if (scratch.large_pages.active) db.large_pages.?.replayStart(db.csn);
            db.epoch +%= 1;
            if (db.epoch == 0) db.epoch = 1;
            db.cid +%= 1;
            const count = try opCount(record);
            var reader = Reader{ .bytes = record };
            var row: V.Row = .{};
            for (0..count) |_| {
                const tag = try reader.int(u8);
                switch (tag) {
                    @intFromEnum(Op.create_table) => {
                        var definition = try decodeCreate(&reader);
                        try resolveConstraintOids(&definition, &.{}, &db.next_constraint_oid);
                        try resolveDefaultOids(&definition, &.{}, &.{}, &db.next_default_oid);
                        const columns = definition.columns[0..definition.count];
                        for (&db.tables, 0..) |*table, index| if (!table.live and S.createBankFits(table, columns, definition.extras.index_count)) {
                            if (!S.indexFits(table, definition.extras.index_count, 0)) return error.ChangeRecordConflict;
                            S.reset(table, definition.oid, definition.name, columns);
                            table.namespace = definition.namespace;
                            table.primary_constraint_oid = definition.primary_constraint_oid;
                            table.primary_index_oid = definition.primary_index_oid;
                            S.setConstraints(table, definition.constraints[0..definition.constraint_count]);
                            S.setExtras(table, &definition.extras);
                            S.initSummary(table, csn);
                            try db.replayCreate(index, csn);
                            // Creates arrive in any OID order: keep the maximum.
                            db.oid_counter = @max(db.oid_counter, definition.oid + S.oidWidth(table) - first_oid, indexOidWidth(&definition.extras), explicitPrimaryHighWater(&definition));
                            break;
                        };
                    },
                    @intFromEnum(Op.alter_table), @intFromEnum(Op.alter_table_rewrite) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        var definition: Definition = .{ .oid = table.oid, .name = .{}, .columns = @splat(.{}), .count = 0 };
                        try decodeDefinition(&reader, &definition);
                        const prior = ConstraintIdentities.from(table.primary_constraint_oid, table.constraints[0..table.constraint_count]);
                        try resolveConstraintOids(&definition, &prior, &db.next_constraint_oid);
                        const rewrite = tag == @intFromEnum(Op.alter_table_rewrite);
                        var sources: [config.columns]u8 = undefined;
                        // A rewritten column starts NULL; op 105's rows set it.
                        var layout: [config.columns]u8 = undefined;
                        var fills: [config.columns]V.Cell = @splat(.null_value);
                        for (0..definition.count) |position| {
                            sources[position] = try reader.int(u8);
                            layout[position] = sources[position];
                            if (rewrite and sources[position] == 0xfe) {
                                sources[position] = try reader.int(u8);
                                layout[position] = 0xff;
                                continue;
                            }
                            if (sources[position] == 0xff) fills[position] = (try decodeValue(&reader)).cell;
                        }
                        try resolveDefaultOids(&definition, table.columns[0..table.column_count], sources[0..definition.count], &db.next_default_oid);
                        const old_count = table.column_count;
                        if (!S.indexFits(table, definition.extras.index_count, 0)) return error.ChangeRecordConflict;
                        // Existing rows must fit every ordered index entry
                        // (a replica with a smaller index_key_bytes).
                        var identity = definition.count == table.column_count;
                        for (sources[0..definition.count], 0..) |origin, position| identity = identity and origin == position;
                        if (identity) for (definition.extras.indexes[0..definition.extras.index_count]) |*index| {
                            if (!S.keysFit(table, index)) return error.ChangeRecordConflict;
                        };
                        if (rewrite) {
                            S.redefinePending(table, definition.name, definition.columns[0..definition.count], definition.constraints[0..definition.constraint_count], &definition.extras, layout[0..definition.count], fills[0..definition.count]);
                            // Replay keeps no old snapshots: each row keeps its
                            // current version, which takes its rewritten row.
                            for (0..table.row_high) |slot| {
                                if (table.rows[slot].newest == 0) continue;
                                S.pruneRow(table, @intCast(slot), S.visible(table, slot));
                            }
                            const rows = try reader.int(u32);
                            for (0..rows) |_| {
                                const rowid = try reader.int(u64);
                                const columns = try reader.int(u8);
                                row = .{};
                                for (0..columns) |position| row.cells[position] = (try decodeValue(&reader)).cell;
                                const slot = S.findRow(table, rowid) orelse return error.ChangeRecordConflict;
                                const version = S.visible(table, slot) orelse return error.ChangeRecordConflict;
                                for (0..columns) |position| S.setVersionCell(table, version, position, row.cells[position]);
                            }
                            S.finishRelayout(table);
                        } else S.redefine(table, definition.name, definition.columns[0..definition.count], definition.constraints[0..definition.constraint_count], &definition.extras, sources[0..definition.count], fills[0..definition.count]);
                        table.primary_constraint_oid = definition.primary_constraint_oid;
                        table.primary_index_oid = definition.primary_index_oid;
                        db.oid_counter = @max(db.oid_counter, indexOidWidth(&definition.extras), explicitPrimaryHighWater(&definition));
                        S.rebuildCommitted(table, csn);
                        try db.replayAlter((@intFromPtr(table) - @intFromPtr(&db.tables[0])) / @sizeOf(S.Table), old_count, csn);
                    },
                    @intFromEnum(Op.view_check_option) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        table.check_option = try reader.int(u8);
                    },
                    @intFromEnum(Op.truncate) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        for (0..table.row_high) |slot| {
                            if (table.rows[slot].newest == 0) continue;
                            const old = S.visible(table, slot) orelse continue;
                            S.summarize(table, old, false, csn);
                            S.scanPublish(table, old, false);
                            retire(db, table, old, csn);
                        }
                        if (table.relkind != 'm') S.publishTruncate(table, csn);
                    },
                    @intFromEnum(Op.drop_table) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        db.replayDrop((@intFromPtr(table) - @intFromPtr(&db.tables[0])) / @sizeOf(S.Table), csn);
                        // Replay has no snapshot: the slot is free at once.
                        table.live = false;
                        table.dead_csn = 0;
                    },
                    @intFromEnum(Op.insert), @intFromEnum(Op.update) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        const rowid = try reader.int(u64);
                        const columns = try reader.int(u8);
                        row = .{};
                        for (0..columns) |index| row.cells[index] = (try decodeValue(&reader)).cell;
                        if (tag == @intFromEnum(Op.insert)) {
                            try S.ensureVersions(table, 1, csn);
                            try S.admitVersion(table, &row.cells);
                            try S.ensureRowSlot(table, csn);
                            const slot = S.allocRow(table, rowid);
                            _ = try writeVersion(db, table, slot, 0, &row, csn);
                            if (rowid + 1 > table.next_rowid) table.next_rowid = rowid + 1;
                        } else {
                            const slot = S.findRow(table, rowid) orelse return error.ChangeRecordConflict;
                            const old = S.visible(table, slot) orelse return error.ChangeRecordConflict;
                            const new = try writeVersion(db, table, slot, old + 1, &row, csn);
                            S.summarizeUpdate(table, old, new, csn);
                            S.scanPublish(table, new, true);
                            retire(db, table, old, csn);
                        }
                    },
                    @intFromEnum(Op.delete) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        const slot = S.findRow(table, try reader.int(u64)) orelse return error.ChangeRecordConflict;
                        const old = S.visible(table, slot) orelse return error.ChangeRecordConflict;
                        S.summarize(table, old, false, csn);
                        S.scanPublish(table, old, false);
                        retire(db, table, old, csn);
                    },
                    @intFromEnum(Op.catalog_counters), @intFromEnum(Op.catalog_counters_with_constraints), @intFromEnum(Op.catalog_counters_with_defaults) => {
                        db.oid_counter = (try reader.int(u32)) - first_oid;
                        const tables = try reader.int(u8);
                        for (0..tables) |_| {
                            const table = try tableByOid(db, try reader.int(u32));
                            table.next_rowid = try reader.int(u64);
                        }
                        if (tag != @intFromEnum(Op.catalog_counters)) db.next_constraint_oid = try reader.int(u32);
                        if (tag == @intFromEnum(Op.catalog_counters_with_defaults)) db.next_default_oid = try reader.int(u32);
                    },
                    @intFromEnum(Op.alter_sequence), @intFromEnum(Op.alter_sequence_ownership) => {
                        const index = try seqByOid(db, try reader.int(u32));
                        const state = try decodeSequenceState(&reader);
                        db.seqs[index].spec = state.spec;
                        sequence.Sequences(config).restore(&db.seqs[index], state.last_value, state.is_called);
                        if (tag == @intFromEnum(Op.alter_sequence_ownership)) {
                            db.seqs[index].owner = try reader.int(u32);
                            db.seqs[index].owner_column = try reader.int(u8);
                        }
                    },
                    @intFromEnum(Op.create_schema), @intFromEnum(Op.create_owned_schema), @intFromEnum(Op.create_private_schema) => {
                        const oid = try reader.int(u32);
                        const schema_name = try reader.name();
                        const owner = if (tag != @intFromEnum(Op.create_schema)) try reader.int(u32) else catalog_objects.bootstrap_role;
                        for (&db.schemas, 0..) |*schema, index| if (!schema.live) {
                            schema.* = .{ .live = true, .oid = oid, .owner = owner, .private_usage = tag == @intFromEnum(Op.create_private_schema), .name = .{ .len = schema_name.len } };
                            @memcpy(schema.name.bytes[0..schema_name.len], schema_name);
                            try db.replayCreateSchema(index, csn);
                            break;
                        };
                        db.oid_counter = @max(db.oid_counter, oid + 1 - first_oid);
                    },
                    @intFromEnum(Op.drop_schema) => {
                        const oid = try reader.int(u32);
                        for (&db.schemas, 0..) |*schema, index| if (schema.live and schema.oid == oid) {
                            db.replayDropSchema(index, csn);
                            schema.live = false;
                            break;
                        };
                    },
                    @intFromEnum(Op.create_routine)...@intFromEnum(Op.drop_rule), @intFromEnum(Op.create_routine_extended), @intFromEnum(Op.create_rule_action), @intFromEnum(Op.create_trigger_extended), @intFromEnum(Op.create_cast), @intFromEnum(Op.drop_cast) => {
                        const payload = try reader.take(try reader.int(u32));
                        try db.replayObject(tag, payload, csn);
                    },
                    @intFromEnum(Op.create_sequence), @intFromEnum(Op.create_sequence_cached), @intFromEnum(Op.create_scoped_identity_sequence), @intFromEnum(Op.create_scoped_sequence), @intFromEnum(Op.create_scoped_serial_sequence) => {
                        const definition = try decodeCreateSequence(&reader, tag);
                        for (&db.seqs, 0..) |*seq, index| if (!seq.live) {
                            sequence.Sequences(config).init(seq, definition.oid, definition.name, definition.spec, definition.owner, definition.owner_column);
                            seq.namespace = definition.namespace;
                            try db.replayCreateSequence(index, csn);
                            break;
                        };
                        db.oid_counter = @max(db.oid_counter, definition.oid + 1 - first_oid);
                    },
                    @intFromEnum(Op.drop_sequence) => {
                        const index = try seqByOid(db, try reader.int(u32));
                        db.replayDropSequence(index, csn);
                        db.seqs[index].live = false;
                    },
                    @intFromEnum(Op.sequence) => {
                        const index = try seqByOid(db, try reader.int(u32));
                        const last_value = try reader.int(i64);
                        const called = try reader.int(u8) == 1;
                        sequence.Sequences(config).restore(&db.seqs[index], last_value, called);
                    },
                    @intFromEnum(Op.object_create) => {
                        const object = try O.decodeCreate(record, &reader.position);
                        db.catalog_objects.applyCreate(&object, db.epoch, db.cid, csn);
                        const width = object.oidWidth();
                        if (width != 0) db.oid_counter = @max(db.oid_counter, object.oid + width - first_oid);
                        if (object.kind == .large_object and object.grant_flags & catalog_objects.large_object_generated_oid != 0)
                            db.oid_counter = @max(db.oid_counter, object.target + 1 - first_oid);
                    },
                    @intFromEnum(Op.object_drop) => {
                        const key = try O.decodeDrop(record, &reader.position);
                        db.catalog_objects.applyDrop(&key);
                    },
                    @intFromEnum(Op.large_object_page) => {
                        const page = try decodeLargeObjectPage(&reader);
                        db.large_pages.?.replay(page.key, page.bytes, csn);
                    },
                    else => return error.UnsupportedLogVersion,
                }
            }
            db.csn = csn;
        }
    };
}
