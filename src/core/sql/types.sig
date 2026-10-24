//! Shared SQL configuration, errors, command tags and cell values (Layer 0).
//! Sub-files of `sql.sig` import each other relatively; nothing outside the
//! `sql` module imports this file directly.
const numeric = @import("numeric.sig");
const temporal = @import("temporal.sig");
const jsonb = @import("jsonb.sig");

pub const Config = struct {
    tables: usize = 4,
    columns: usize = 8,
    rows_per_table: usize = 128,
    name_bytes: usize = 32,
    text_bytes: usize = 128,
    /// Maximum boolean leaf predicates (comparison, IS, IN, BETWEEN, LIKE)
    /// in one WHERE clause; more raise PredicateCapacity (54000).
    predicates: usize = 8,
    /// MySQL-style ordering by default; PostgreSQL uses false (ASC NULLS LAST).
    nulls_first_ascending: bool = true,
    /// What an unqualified INTEGER means outside the PostgreSQL dialect (MySQL
    /// and TDS sessions) and in legacy_alpha replay. On the PostgreSQL path
    /// INTEGER/INT/INT4 is always int4; BIGINT/INT8 is always int8.
    integer_bits: u8 = 64,
    /// Row-version arena slots per table. 0 selects 2 x rows_per_table; an
    /// explicit value must exceed rows_per_table.
    versions_per_table: usize = 0,
    /// Write-set entries per transaction (row versions, row marks and catalog
    /// versions it created or marked). 0 selects 2 x rows_per_table (at least
    /// 64); RAMSQL sets 4096. Exceeding it is WriteSetCapacity (53200) with
    /// the statement rolled back.
    tx_writes: usize = 0,
    /// Statement-scoped expression node pool inside Database.workspace.
    expr_nodes: usize = 512,
    /// Maximum parser nesting depth.
    expr_depth: usize = 64,
    /// Concurrent transaction slots (RAMSQL: clients + 2). Exhaustion is
    /// TransactionCapacity (53200).
    transactions: usize = 8,
    /// User savepoints per transaction; one more slot is reserved for the
    /// running statement's subtransaction.
    savepoints: usize = 32,
    /// FOR UPDATE / FOR SHARE row-lock entries shared by all transactions;
    /// exhaustion is LockCapacity (53200).
    row_locks: usize = 256,
    /// FOR SHARE holders per locked row.
    share_holders: usize = 8,
    /// Sequence catalog capacity (cat_sequences; sequences arrive with FEAT-007).
    sequences: usize = 16,
    /// NUMERIC coefficient capacity in decimal digits (1..76). Results that
    /// need more significant digits raise NumericCapacity (54000).
    numeric_digits: usize = 64,
    /// JSONB nesting depth; deeper documents raise StatementTooComplex (54001).
    json_depth: usize = 64,
    /// Query workspace row slots (design §4.9): sorts, groups, joins, CTEs,
    /// derived tables and set operations of one statement share
    /// work_rows x 2 x columns cells. 0 selects rows_per_table. Exhaustion is
    /// WorkspaceCapacity (54000) before anything is published.
    work_rows: usize = 0,
    /// Rows one statement can return (Result.rows). 0 selects rows_per_table.
    result_rows: usize = 0,
    /// FROM items (tables, derived tables, CTE references) per query block.
    relations: usize = 4,
    /// Query blocks per statement (subqueries, CTE bodies, set-operation
    /// branches); more raise StatementTooComplex (54001).
    subqueries: usize = 16,
    /// Common table expressions per statement (StatementTooComplex beyond).
    ctes: usize = 4,
};

pub fn workRows(comptime config: Config) usize {
    return if (config.work_rows == 0) config.rows_per_table else config.work_rows;
}

pub fn resultRows(comptime config: Config) usize {
    return if (config.result_rows == 0) config.rows_per_table else config.result_rows;
}

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
    /// SQLSTATE 42883: no operator or function matches the argument types.
    UndefinedFunction,
    /// SQLSTATE 42725: an operator over untyped literals is ambiguous.
    AmbiguousFunction,
    /// SQLSTATE 42846: no cast exists between the two types.
    CannotCoerce,
    /// SQLSTATE 22P02: text is not valid input for the target type.
    InvalidTextRepresentation,
    /// SQLSTATE 22012.
    DivisionByZero,
    /// SQLSTATE 22025: a LIKE pattern ends with the escape character.
    InvalidEscapeSequence,
    /// SQLSTATE 42P02: a $n placeholder reached the engine unbound.
    UndefinedParameter,
    /// SQLSTATE 42P10: ORDER BY position out of range.
    InvalidColumnReference,
    /// Not an error for subtransaction purposes: the statement met a lock held
    /// by a live transaction and is parked (design §4.4/§4.5). Resume it by
    /// re-delivering the same statement.
    WouldBlock,
    /// SQLSTATE 40001: interim same-row conflict (unused once locks wait).
    SerializationFailure,
    /// SQLSTATE 40P01.
    DeadlockDetected,
    /// SQLSTATE 55P03: NOWAIT or lock_timeout.
    LockNotAvailable,
    /// SQLSTATE 57014: cancel request or statement_timeout.
    QueryCanceled,
    /// SQLSTATE 53200: the transaction table is full.
    TransactionCapacity,
    /// SQLSTATE 53200: a transaction's write set (Config.tx_writes) is full.
    WriteSetCapacity,
    /// SQLSTATE 53200: the row-lock table or a lock's share holders are full.
    LockCapacity,
    /// SQLSTATE 53200: a catalog relation has no free version or row.
    CatalogCapacity,
    /// SQLSTATE 53200: too many savepoints in one transaction.
    SavepointCapacity,
    /// SQLSTATE 3B001.
    SavepointNotFound,
    /// SQLSTATE 25P01: SAVEPOINT/RELEASE/ROLLBACK TO outside a block.
    NoActiveTransaction,
    /// SQLSTATE 25006: the caller does not permit writes (storage unavailable).
    ReadOnlyTransaction,
    /// SQLSTATE 42704: unrecognized configuration parameter.
    UndefinedSetting,
    /// SQLSTATE 22023: invalid value for a configuration parameter.
    InvalidSettingValue,
    /// SQLSTATE 22003: a NUMERIC, REAL/DOUBLE or SMALLINT value is out of range.
    NumericValueOutOfRange,
    /// SQLSTATE 54000: a NUMERIC result needs more than Config.numeric_digits
    /// significant digits or a larger display scale (capacity limit).
    NumericCapacity,
    /// SQLSTATE 22023: invalid type modifier or function argument.
    InvalidParameterValue,
    /// SQLSTATE 22007: text is not a valid date/time/interval.
    InvalidDatetimeFormat,
    /// SQLSTATE 22008: a date/time field or value is out of range.
    DatetimeFieldOverflow,
    /// SQLSTATE 22P05: \u0000 in JSONB.
    UntranslatableCharacter,
    /// SQLSTATE 0A000: the statement needs a wall clock and none is available.
    ClockUnavailable,
    /// SQLSTATE 54000: the statement's query workspace (Config.work_rows) is full.
    WorkspaceCapacity,
    /// SQLSTATE 42803: an ungrouped column or misplaced aggregate.
    GroupingError,
    /// SQLSTATE 42702: an unqualified column name matches several relations.
    AmbiguousColumn,
    /// SQLSTATE 21000: a scalar subquery returned more than one row.
    CardinalityViolation,
    /// SQLSTATE 2201W: LIMIT is negative.
    InvalidRowCountInLimit,
    /// SQLSTATE 2201X: OFFSET is negative.
    InvalidRowCountInResultOffset,
};

/// Session dialect. It changes only assignment coercion (MySQL/TDS BIT
/// clients send booleans as integer 0/1) and what an unqualified INTEGER
/// means (Config.integer_bits outside PostgreSQL). Expression typing is the
/// same in every dialect.
pub const Dialect = enum { postgres, mysql, tds };

/// Stored column / result types. `integer` is int8 (BIGINT) and
/// `integer32` int4 (INTEGER); the others are named after PostgreSQL.
pub const DataType = enum { integer, integer32, boolean, text, smallint, numeric, real, double, name, oid, date, timestamp, timestamptz, interval, json, jsonb };

/// Bound expression type. `unknown` is an untyped string or NULL literal
/// that has not been resolved by context yet.
pub const Type = enum { unknown, int2, int4, int8, numeric, float4, float8, boolean, text, name, oid, date, timestamp, timestamptz, interval, json, jsonb };

pub fn dataTypeOf(ty: Type) DataType {
    return switch (ty) {
        .int2 => .smallint,
        .int4 => .integer32,
        .int8 => .integer,
        .numeric => .numeric,
        .float4 => .real,
        .float8 => .double,
        .boolean => .boolean,
        .text, .unknown => .text,
        .name => .name,
        .oid => .oid,
        .date => .date,
        .timestamp => .timestamp,
        .timestamptz => .timestamptz,
        .interval => .interval,
        .json => .json,
        .jsonb => .jsonb,
    };
}

pub fn typeOfData(data_type: DataType) Type {
    return switch (data_type) {
        .smallint => .int2,
        .integer32 => .int4,
        .integer => .int8,
        .numeric => .numeric,
        .real => .float4,
        .double => .float8,
        .boolean => .boolean,
        .text => .text,
        .name => .name,
        .oid => .oid,
        .date => .date,
        .timestamp => .timestamp,
        .timestamptz => .timestamptz,
        .interval => .interval,
        .json => .json,
        .jsonb => .jsonb,
    };
}

/// Static type table (pg_type subset): OID, typname, typlen, typcategory,
/// array type OID (arrays are reported for catalog fidelity only).
pub const TypeInfo = struct { oid: u32, name: []const u8, len: i16, category: u8, array: u32 };

pub fn typeInfo(data_type: DataType) TypeInfo {
    return switch (data_type) {
        .boolean => .{ .oid = 16, .name = "bool", .len = 1, .category = 'B', .array = 1000 },
        .name => .{ .oid = 19, .name = "name", .len = 64, .category = 'S', .array = 1003 },
        .integer => .{ .oid = 20, .name = "int8", .len = 8, .category = 'N', .array = 1016 },
        .smallint => .{ .oid = 21, .name = "int2", .len = 2, .category = 'N', .array = 1005 },
        .integer32 => .{ .oid = 23, .name = "int4", .len = 4, .category = 'N', .array = 1007 },
        .text => .{ .oid = 25, .name = "text", .len = -1, .category = 'S', .array = 1009 },
        .oid => .{ .oid = 26, .name = "oid", .len = 4, .category = 'N', .array = 1028 },
        .json => .{ .oid = 114, .name = "json", .len = -1, .category = 'U', .array = 199 },
        .real => .{ .oid = 700, .name = "float4", .len = 4, .category = 'N', .array = 1021 },
        .double => .{ .oid = 701, .name = "float8", .len = 8, .category = 'N', .array = 1022 },
        .date => .{ .oid = 1082, .name = "date", .len = 4, .category = 'D', .array = 1182 },
        .timestamp => .{ .oid = 1114, .name = "timestamp", .len = 8, .category = 'D', .array = 1115 },
        .timestamptz => .{ .oid = 1184, .name = "timestamptz", .len = 8, .category = 'D', .array = 1185 },
        .interval => .{ .oid = 1186, .name = "interval", .len = 16, .category = 'T', .array = 1187 },
        .numeric => .{ .oid = 1700, .name = "numeric", .len = -1, .category = 'N', .array = 1231 },
        .jsonb => .{ .oid = 3802, .name = "jsonb", .len = -1, .category = 'U', .array = 3807 },
    };
}

/// PostgreSQL type OIDs carried by change records and descriptions.
pub fn typeOid(data_type: DataType) u32 {
    return typeInfo(data_type).oid;
}

pub fn typeFromOid(oid: u32) ?DataType {
    inline for (@typeInfo(DataType).@"enum".field_names) |field| {
        if (typeInfo(@field(DataType, field)).oid == oid) return @field(DataType, field);
    }
    return null;
}

/// Statement kind of a completed (or described) statement.
pub const CommandTag = enum { none, select, insert, update, delete, create_table, drop_table, begin, commit, rollback, savepoint, release, set, show, reset };

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

        /// smallint/int4/int8/oid are `integer`; text/name/json are `text`;
        /// `jsonb` holds the canonical binary (jsonb.sig) in a Text.
        pub const CellTag = enum { null_value, integer, boolean, text, float4, float8, numeric, date, timestamp, timestamptz, interval, jsonb };

        pub const Cell = union(CellTag) {
            null_value: void,
            integer: i64,
            boolean: bool,
            text: Text,
            float4: f32,
            float8: f64,
            numeric: numeric.Numeric,
            date: i32,
            timestamp: i64,
            timestamptz: i64,
            interval: temporal.Interval,
            jsonb: Text,
        };

        pub const Row = struct {
            cells: [config.columns]Cell = @splat(.null_value),
        };

        pub const Column = struct {
            name: Name = .{},
            data_type: DataType = .integer,
            /// PostgreSQL atttypmod: NUMERIC(p,s) ((p << 16) | s) + 4,
            /// TIMESTAMP[TZ](p) p; -1 when absent.
            typmod: i32 = -1,
            not_null: bool = false,
            primary_key: bool = false,
        };

        pub fn cellTag(data_type: DataType) CellTag {
            return switch (data_type) {
                .integer, .integer32, .smallint, .oid => .integer,
                .boolean => .boolean,
                .text, .name, .json => .text,
                .real => .float4,
                .double => .float8,
                .numeric => .numeric,
                .date => .date,
                .timestamp => .timestamp,
                .timestamptz => .timestamptz,
                .interval => .interval,
                .jsonb => .jsonb,
            };
        }

        /// NULL sorts first for ASC, last for DESC. Values have strict schema
        /// types (the binder inserts every implicit cast), so both sides carry
        /// the same tag; different tags order by tag.
        pub fn compare(left: *const Cell, right: *const Cell) i8 {
            if (left.* == .null_value) return if (right.* == .null_value) 0 else -1;
            if (right.* == .null_value) return 1;
            const lt = @intFromEnum(@as(CellTag, left.*));
            const rt = @intFromEnum(@as(CellTag, right.*));
            if (lt != rt) return if (lt < rt) -1 else 1;
            return switch (left.*) {
                .null_value => 0,
                .integer => |value| order(i64, value, right.integer),
                .boolean => |value| if (value == right.boolean) 0 else if (value) 1 else -1,
                .text => |*value| bytesOrder(value.slice(), right.text.slice()),
                .float4 => |value| floatOrder(f32, value, right.float4),
                .float8 => |value| floatOrder(f64, value, right.float8),
                .numeric => |*value| numeric.compareValues(value, &right.numeric),
                .date => |value| order(i32, value, right.date),
                .timestamp => |value| order(i64, value, right.timestamp),
                .timestamptz => |value| order(i64, value, right.timestamptz),
                .interval => |value| temporal.compareInterval(value, right.interval),
                .jsonb => |*value| J.compare(value.slice(), right.jsonb.slice()),
            };
        }

        const J = jsonb.Jsonb(config.text_bytes, config.json_depth, config.numeric_digits);

        fn order(comptime T: type, a: T, b: T) i8 {
            return if (a < b) -1 else if (a > b) 1 else 0;
        }

        fn floatOrder(comptime T: type, a: T, b: T) i8 {
            const a_nan = a != a;
            const b_nan = b != b;
            if (a_nan or b_nan) return if (a_nan and b_nan) 0 else if (a_nan) 1 else -1;
            return order(T, a, b);
        }

        fn mix(code: *u64, bits_in: u64) void {
            var bits = bits_in;
            for (0..8) |_| {
                code.* = (code.* ^ @as(u8, @truncate(bits))) *% 1099511628211;
                bits >>= 8;
            }
        }

        /// Consistent with compare: equal values hash equally.
        pub fn hash(value: *const Cell) usize {
            var code: u64 = 14695981039346656037;
            mix(&code, @intFromEnum(@as(CellTag, value.*)));
            switch (value.*) {
                .integer => |integer| mix(&code, @bitCast(integer)),
                .text => |*text| for (text.slice()) |byte| {
                    code = (code ^ byte) *% 1099511628211;
                },
                .boolean => |boolean| code = @intFromBool(boolean),
                .float4 => |float| mix(&code, @bitCast(normalFloat(@floatCast(float)))),
                .float8 => |float| mix(&code, @bitCast(normalFloat(float))),
                .numeric => |*number| for (numeric.numeric_hash(number)) |limb| mix(&code, limb),
                .date => |days| mix(&code, @bitCast(@as(i64, days))),
                .timestamp, .timestamptz => |us| mix(&code, @bitCast(us)),
                .interval => |span| {
                    const total = temporal.intervalSpan(span);
                    mix(&code, @truncate(@as(u128, @bitCast(total))));
                    mix(&code, @truncate(@as(u128, @bitCast(total)) >> 64));
                },
                .jsonb => |*document| J.hash(document.slice(), 0, &code),
                .null_value => unreachable,
            }
            // Mix low bits before the power-of-two table mask.
            code ^= code >> 33;
            code *%= 0xff51afd7ed558ccd;
            code ^= code >> 33;
            return @truncate(code);
        }

        fn normalFloat(value: f64) f64 {
            if (value != value) return @bitCast(@as(u64, 0x7ff8000000000000));
            return if (value == 0) 0 else value;
        }

        /// Stored-value checks: NOT NULL, exact type tag and integer ranges.
        pub fn validate(column: *const Column, value: *const Cell) Error!void {
            if (value.* == .null_value) {
                if (column.not_null) return error.NotNullViolation;
                return;
            }
            if (@as(CellTag, value.*) != cellTag(column.data_type)) return error.TypeMismatch;
            if (value.* == .integer) {
                const integer = value.integer;
                switch (column.data_type) {
                    .integer32 => if (integer < -2147483648 or integer > 2147483647) return error.IntegerOverflow,
                    .smallint => if (integer < -32768 or integer > 32767) return error.NumericValueOutOfRange,
                    .oid => if (integer < 0 or integer > 4294967295) return error.NumericValueOutOfRange,
                    else => {},
                }
            }
        }
    };
}