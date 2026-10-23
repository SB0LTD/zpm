//! Shared SQL configuration, errors, command tags and cell values (Layer 0).
//! Sub-files of `sql.sig` import each other relatively; nothing outside the
//! `sql` module imports this file directly.

pub const Config = struct {
    tables: usize = 4,
    columns: usize = 8,
    rows_per_table: usize = 128,
    name_bytes: usize = 32,
    text_bytes: usize = 128,
    predicates: usize = 8,
    /// MySQL/MSSQL BIT clients encode booleans as integer 0/1.
    boolean_integers: bool = false,
    /// MySQL-style ordering by default; PostgreSQL uses false (ASC NULLS LAST).
    nulls_first_ascending: bool = true,
    /// Preserve the library's historical 64-bit INTEGER by default. PostgreSQL
    /// servers select 32; BIGINT always provides the full signed 64-bit range.
    integer_bits: u8 = 64,
    /// Row-version arena slots per table. 0 selects 2 x rows_per_table; an
    /// explicit value must exceed rows_per_table.
    versions_per_table: usize = 0,
    /// Statement-local undo entries. 0 selects rows_per_table, the most rows a
    /// single statement can touch; an explicit value must not be smaller.
    tx_writes: usize = 0,
    /// Statement-scoped expression node pool inside Database.workspace.
    expr_nodes: usize = 512,
    /// Maximum parser nesting depth.
    expr_depth: usize = 64,
};

pub const Error = error{
    Syntax,
    UnsupportedStatement,
    TableCapacity,
    ColumnCapacity,
    RowCapacity,
    NameCapacity,
    TextCapacity,
    PredicateCapacity,
    TableExists,
    TableNotFound,
    ColumnNotFound,
    DuplicateColumn,
    TypeMismatch,
    NotNullViolation,
    PrimaryKeyViolation,
    IntegerOverflow,
    /// SQLSTATE 54001: node pool or parser depth exhausted.
    StatementTooComplex,
    /// SQLSTATE 53200: no reclaimable row version or directory slot remains.
    VersionCapacity,
    /// SQLSTATE 53200: a change record does not fit its caller-owned buffer.
    TransactionLogCapacity,
    /// Unknown change-record version or a legacy SQL record outside the alpha grammar.
    UnsupportedLogVersion,
    /// Truncated, corrupt or structurally invalid change record.
    InvalidChangeRecord,
    /// A change record names an unknown OID, a conflicting rowid or exceeds capacity.
    ChangeRecordConflict,
};

pub const DataType = enum { integer, integer32, boolean, text };

/// PostgreSQL type OIDs carried by change records and descriptions.
pub fn typeOid(data_type: DataType) u32 {
    return switch (data_type) {
        .integer => 20,
        .integer32 => 23,
        .boolean => 16,
        .text => 25,
    };
}

pub fn typeFromOid(oid: u32) ?DataType {
    return switch (oid) {
        20 => .integer,
        23 => .integer32,
        16 => .boolean,
        25 => .text,
        else => null,
    };
}

/// Statement kind of a completed (or described) statement.
pub const CommandTag = enum { none, select, insert, update, delete, create_table, drop_table, begin, commit, rollback };

pub fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

pub fn letter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

pub fn digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

pub fn keyword(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (lower(left) != lower(right)) return false;
    return true;
}

pub fn bytesOrder(a: []const u8, b: []const u8) i8 {
    const count = @min(a.len, b.len);
    for (0..count) |index| {
        if (a[index] < b[index]) return -1;
        if (a[index] > b[index]) return 1;
    }
    return if (a.len < b.len) -1 else if (a.len > b.len) 1 else 0;
}

pub fn Values(comptime config: Config) type {
    return struct {
        pub const Name = struct {
            bytes: [config.name_bytes]u8 = @splat(0),
            len: usize = 0,

            pub fn slice(self: *const Name) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        pub const Text = struct {
            bytes: [config.text_bytes]u8 = @splat(0),
            len: usize = 0,

            pub fn slice(self: *const Text) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        pub const CellTag = enum { null_value, integer, boolean, text };

        pub const Cell = union(CellTag) {
            null_value: void,
            integer: i64,
            boolean: bool,
            text: Text,
        };

        pub const Row = struct {
            cells: [config.columns]Cell = @splat(.null_value),
        };

        pub const Column = struct {
            name: Name = .{},
            data_type: DataType = .integer,
            not_null: bool = false,
            primary_key: bool = false,
        };

        /// NULL sorts first for ASC, last for DESC. Other values have strict
        /// schema types; no numeric/text or integer/boolean coercion occurs.
        pub fn compare(left: *const Cell, right: *const Cell) i8 {
            if (left.* == .null_value) return if (right.* == .null_value) 0 else -1;
            if (right.* == .null_value) return 1;
            return switch (left.*) {
                .null_value => 0,
                .integer => |value| if (value < right.integer) -1 else if (value > right.integer) 1 else 0,
                .boolean => |value| if (value == right.boolean) 0 else if (value) 1 else -1,
                .text => |*value| bytesOrder(value.slice(), right.text.slice()),
            };
        }

        pub fn hash(value: *const Cell) usize {
            var code: u64 = 14695981039346656037;
            switch (value.*) {
                .integer => |integer| {
                    var bits: u64 = @bitCast(integer);
                    for (0..8) |_| {
                        code = (code ^ @as(u8, @truncate(bits))) *% 1099511628211;
                        bits >>= 8;
                    }
                },
                .text => |*text| for (text.slice()) |byte| {
                    code = (code ^ byte) *% 1099511628211;
                },
                .boolean => |boolean| code = @intFromBool(boolean),
                .null_value => unreachable,
            }
            // Mix low bits before the power-of-two table mask.
            code ^= code >> 33;
            code *%= 0xff51afd7ed558ccd;
            code ^= code >> 33;
            return @truncate(code);
        }

        /// Assignment and comparison coercion for the supported type set.
        pub fn validate(column: *const Column, value: *Cell, boolean_integers: bool) Error!void {
            if (boolean_integers and column.data_type == .boolean and value.* == .integer) {
                // Capture the payload before changing the active union tag.
                const integer = value.integer;
                if (integer != 0 and integer != 1) return error.TypeMismatch;
                const boolean = integer == 1;
                value.* = .{ .boolean = boolean };
            }
            switch (value.*) {
                .null_value => if (column.not_null) return error.NotNullViolation,
                .integer => |integer| {
                    if (column.data_type != .integer and column.data_type != .integer32) return error.TypeMismatch;
                    if (column.data_type == .integer32 and (integer < -2147483648 or integer > 2147483647)) return error.IntegerOverflow;
                },
                .boolean => if (column.data_type != .boolean) return error.TypeMismatch,
                .text => if (column.data_type != .text) return error.TypeMismatch,
            }
        }
    };
}
