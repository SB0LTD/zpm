//! Bounded, allocation-free in-memory SQL (Layer 0).
//!
//! Database and result storage belong entirely to the caller. Identifiers and
//! text cells are copied inline; neither statements nor results borrow database
//! storage. Each execute accepts exactly one statement and failing statements
//! leave both the database and result unchanged. Callers serialize access.
//!
//! Supported: CREATE/DROP TABLE; single-row INSERT [column list] VALUES;
//! SELECT */column list, AND predicates, one ORDER BY and LIMIT; UPDATE literal
//! assignments; DELETE. Types are INTEGER, BOOLEAN, TEXT, NULL. Constraints are
//! NOT NULL and a single-column PRIMARY KEY. Identifiers are ASCII and case
//! insensitive; text comparison is bytewise. NULL comparisons are unknown and
//! therefore do not match WHERE, except explicit IS [NOT] NULL predicates.
//! Transactions, joins, expressions, aggregates, secondary indices and persistence are
//! outside this initial SQL subset. No allocator, platform, or std dependency.

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
};

pub const DataType = enum { integer, integer32, boolean, text };

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn letter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

fn digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

fn keyword(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (lower(left) != lower(right)) return false;
    return true;
}

fn bytesOrder(a: []const u8, b: []const u8) i8 {
    const count = @min(a.len, b.len);
    for (0..count) |index| {
        if (a[index] < b[index]) return -1;
        if (a[index] > b[index]) return 1;
    }
    return if (a.len < b.len) -1 else if (a.len > b.len) 1 else 0;
}

pub fn Database(comptime config: Config) type {
    if (config.integer_bits != 32 and config.integer_bits != 64) @compileError("SQL INTEGER width must be 32 or 64");
    if (config.tables == 0 or config.columns == 0 or config.rows_per_table == 0 or
        config.name_bytes == 0 or config.text_bytes == 0 or config.predicates == 0)
        @compileError("SQL capacities must be non-zero");

    return struct {
        const Self = @This();
        pub const integer_type: DataType = if (config.integer_bits == 32) .integer32 else .integer;

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

        pub const Cell = union(enum) {
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

        pub const Result = struct {
            column_count: usize = 0,
            row_count: usize = 0,
            affected_rows: usize = 0,
            column_names: [config.columns]Name = @splat(.{}),
            column_types: [config.columns]DataType = @splat(.integer),
            rows: [config.rows_per_table]Row = @splat(.{}),

            /// Only active ranges are observable; avoid clearing unused row capacity.
            pub fn clear(self: *Result, affected: usize) void {
                self.column_count = 0;
                self.row_count = 0;
                self.affected_rows = affected;
            }

            /// Copy the observable result, without touching unused capacity.
            /// Destination may be uninitialized; inactive ranges stay unreadable.
            pub fn copyFrom(self: *Result, source: *const Result) void {
                if (self == source) return;
                self.column_count = source.column_count;
                self.row_count = source.row_count;
                self.affected_rows = source.affected_rows;
                @memcpy(self.column_names[0..source.column_count], source.column_names[0..source.column_count]);
                @memcpy(self.column_types[0..source.column_count], source.column_types[0..source.column_count]);
                for (0..source.row_count) |row| {
                    @memcpy(self.rows[row].cells[0..source.column_count], source.rows[row].cells[0..source.column_count]);
                }
            }
        };

        const index_capacity = blk: {
            var capacity: usize = 2;
            while (capacity < config.rows_per_table * 2) capacity *= 2;
            break :blk capacity;
        };

        const Table = struct {
            live: bool = false,
            name: Name = .{},
            column_count: usize = 0,
            row_count: usize = 0,
            columns: [config.columns]Column = @splat(.{}),
            rows: [config.rows_per_table]Row = @splat(.{}),
            primary_column: ?usize = null,
            // Open addressing, <= 50% load; zero means vacant, other values row+1.
            primary_index: [index_capacity]usize = @splat(0),
        };

        const Operator = enum { equal, not_equal, less, less_equal, greater, greater_equal, is_null, is_not_null };
        const Predicate = struct {
            column: usize = 0,
            op: Operator = .equal,
            value: Cell = .null_value,
        };
        const Filter = struct {
            items: [config.predicates]Predicate = @splat(.{}),
            len: usize = 0,
        };

        tables: [config.tables]Table = @splat(.{}),

        /// Includes all caller-owned table, schema and text storage.
        pub fn storageBytes() usize {
            return @sizeOf(Self);
        }

        /// Copy a complete logical snapshot into distinct caller-owned storage.
        /// Only live tables, schemas, rows and indices are observable. Inactive
        /// table payloads and unused row capacity need neither copying nor zeroing.
        /// All operations must continue to respect live/column_count/row_count.
        pub fn copyFrom(self: *Self, source: *const Self) void {
            if (self == source) return;
            for (&self.tables, &source.tables) |*destination, *table| {
                destination.live = table.live;
                if (!table.live) continue;
                destination.name = table.name;
                destination.column_count = table.column_count;
                destination.row_count = table.row_count;
                destination.primary_column = table.primary_column;
                @memcpy(destination.columns[0..table.column_count], table.columns[0..table.column_count]);
                @memcpy(destination.rows[0..table.row_count], table.rows[0..table.row_count]);
                if (table.primary_column != null) destination.primary_index = table.primary_index;
            }
        }

        pub fn tableCount(self: *const Self) usize {
            var count: usize = 0;
            for (&self.tables) |*table| if (table.live) {
                count += 1;
            };
            return count;
        }

        /// Result contains copied SELECT rows or a mutation's affected_rows.
        /// Any error preserves the previous result and the whole database.
        pub fn execute(self: *Self, source: []const u8, result: *Result) Error!void {
            return self.executeInternal(source, result, NoCommit{});
        }

        const NoCommit = struct {
            fn before(_: @This()) Error!void {}
        };

        const CommitBoundary = struct {
            context: ?*anyopaque,
            commit: *const fn (?*anyopaque) anyerror!void,

            fn before(self: @This()) anyerror!void {
                try self.commit(self.context);
            }
        };

        /// Validate the entire statement before calling commit, then publish its
        /// mutation without any further fallible operation. SELECT never calls
        /// commit. Failed validation or commit preserves the database and result.
        /// The caller serializes access through the complete call. The callback
        /// must not mutate this database, source, or result, or reenter a write;
        /// read-only observation is permitted. The callback normally
        /// flushes a WAL record. No database snapshot or heap storage is needed.
        pub fn executeWithCommit(self: *Self, source: []const u8, result: *Result, context: ?*anyopaque, commit: *const fn (?*anyopaque) anyerror!void) anyerror!void {
            return self.executeInternal(source, result, CommitBoundary{ .context = context, .commit = commit });
        }

        fn executeInternal(self: *Self, source: []const u8, result: *Result, boundary: anytype) !void {
            var parser = Parser{ .source = source };
            if (parser.takeWord("CREATE")) return self.create(&parser, result, boundary);
            if (parser.takeWord("DROP")) return self.drop(&parser, result, boundary);
            if (parser.takeWord("INSERT")) return self.insert(&parser, result, boundary);
            if (parser.takeWord("SELECT")) return self.select(&parser, result);
            if (parser.takeWord("UPDATE")) return self.update(&parser, result, boundary);
            if (parser.takeWord("DELETE")) return self.delete(&parser, result, boundary);
            return error.UnsupportedStatement;
        }

        fn tableIndex(self: *const Self, name: *const Name) Error!usize {
            for (&self.tables, 0..) |*table, index|
                if (table.live and same(table.name.slice(), name.slice())) return index;
            return error.TableNotFound;
        }

        fn columnIndex(table: *const Table, name: *const Name) Error!usize {
            for (table.columns[0..table.column_count], 0..) |*column, index|
                if (same(column.name.slice(), name.slice())) return index;
            return error.ColumnNotFound;
        }

        fn hash(value: *const Cell) usize {
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

        fn primaryLookup(table: *const Table, value: *const Cell) ?usize {
            const column = table.primary_column orelse return null;
            if (value.* == .null_value) return null;
            var slot = hash(value) & (index_capacity - 1);
            for (0..index_capacity) |_| {
                const item = table.primary_index[slot];
                if (item == 0) return null;
                if (compare(&table.rows[item - 1].cells[column], value) == 0) return item - 1;
                slot = (slot + 1) & (index_capacity - 1);
            }
            return null;
        }

        fn indexRow(table: *Table, row: usize) void {
            const column = table.primary_column orelse return;
            var slot = hash(&table.rows[row].cells[column]) & (index_capacity - 1);
            while (table.primary_index[slot] != 0) slot = (slot + 1) & (index_capacity - 1);
            table.primary_index[slot] = row + 1;
        }

        fn rebuildIndex(table: *Table) void {
            @memset(&table.primary_index, 0);
            if (table.primary_column == null) return;
            for (0..table.row_count) |row| indexRow(table, row);
        }

        fn primaryPredicate(table: *const Table, where: *const Filter) ?*const Cell {
            const column = table.primary_column orelse return null;
            for (where.items[0..where.len]) |*item|
                if (item.column == column and item.op == .equal) return &item.value;
            return null;
        }

        fn create(self: *Self, parser: *Parser, result: *Result, boundary: anytype) !void {
            try parser.expectWord("TABLE");
            const name = try parser.name();
            for (&self.tables) |*table|
                if (table.live and same(table.name.slice(), name.slice())) return error.TableExists;
            try parser.expect('(');
            var columns: [config.columns]Column = @splat(.{});
            var count: usize = 0;
            var has_primary = false;
            while (true) {
                if (count == config.columns) return error.ColumnCapacity;
                var column: Column = .{ .name = try parser.name() };
                for (columns[0..count]) |*previous|
                    if (same(previous.name.slice(), column.name.slice())) return error.DuplicateColumn;
                if (parser.takeWord("INTEGER") or parser.takeWord("INT")) {
                    column.data_type = integer_type;
                } else if (parser.takeWord("BIGINT") or parser.takeWord("INT8")) {
                    column.data_type = .integer;
                } else if (parser.takeWord("BOOLEAN") or parser.takeWord("BOOL")) {
                    column.data_type = .boolean;
                } else if (parser.takeWord("TEXT")) {
                    column.data_type = .text;
                } else return error.Syntax;
                var has_not_null = false;
                while (true) {
                    if (parser.takeWord("NOT")) {
                        if (has_not_null) return error.Syntax;
                        try parser.expectWord("NULL");
                        has_not_null = true;
                        column.not_null = true;
                    } else if (parser.takeWord("PRIMARY")) {
                        if (has_primary) return error.Syntax;
                        try parser.expectWord("KEY");
                        has_primary = true;
                        column.primary_key = true;
                        column.not_null = true;
                    } else break;
                }
                columns[count] = column;
                count += 1;
                if (!parser.take(',')) break;
            }
            try parser.expect(')');
            try parser.finish();
            var destination: ?usize = null;
            for (&self.tables, 0..) |*table, index| if (!table.live) {
                destination = index;
                break;
            };
            const index = destination orelse return error.TableCapacity;
            const table = &self.tables[index];
            try boundary.before();
            table.live = true;
            table.name = name;
            table.column_count = count;
            table.row_count = 0;
            table.columns = columns;
            table.primary_column = null;
            @memset(&table.primary_index, 0);
            for (columns[0..count], 0..) |column, column_index|
                if (column.primary_key) {
                    self.tables[index].primary_column = column_index;
                };
            result.clear(0);
        }

        fn drop(self: *Self, parser: *Parser, result: *Result, boundary: anytype) !void {
            try parser.expectWord("TABLE");
            const name = try parser.name();
            const index = try self.tableIndex(&name);
            try parser.finish();
            try boundary.before();
            self.tables[index].live = false;
            result.clear(0);
        }

        fn validate(column: *const Column, value: *Cell) Error!void {
            if (config.boolean_integers and column.data_type == .boolean and value.* == .integer) {
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

        fn insert(self: *Self, parser: *Parser, result: *Result, boundary: anytype) !void {
            try parser.expectWord("INTO");
            const name = try parser.name();
            const table = &self.tables[try self.tableIndex(&name)];
            var mapping: [config.columns]usize = @splat(0);
            var mapped: [config.columns]bool = @splat(false);
            var count: usize = 0;
            if (parser.take('(')) {
                while (true) {
                    if (count == config.columns) return error.ColumnCapacity;
                    const column_name = try parser.name();
                    const index = try columnIndex(table, &column_name);
                    if (mapped[index]) return error.DuplicateColumn;
                    mapping[count] = index;
                    mapped[index] = true;
                    count += 1;
                    if (!parser.take(',')) break;
                }
                try parser.expect(')');
            } else {
                count = table.column_count;
                for (0..count) |index| mapping[index] = index;
            }
            try parser.expectWord("VALUES");
            try parser.expect('(');
            var row: Row = .{};
            for (0..count) |index| {
                if (index != 0) try parser.expect(',');
                row.cells[mapping[index]] = try parser.literal();
            }
            try parser.expect(')');
            try parser.finish();
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                try validate(column, &row.cells[index]);
                if (column.primary_key) {
                    if (primaryLookup(table, &row.cells[index]) != null) return error.PrimaryKeyViolation;
                }
            }
            if (table.row_count == config.rows_per_table) return error.RowCapacity;
            try boundary.before();
            table.rows[table.row_count] = row;
            indexRow(table, table.row_count);
            table.row_count += 1;
            result.clear(1);
        }

        fn filter(parser: *Parser, table: *const Table) Error!Filter {
            var out: Filter = .{};
            if (!parser.takeWord("WHERE")) return out;
            while (true) {
                if (out.len == config.predicates) return error.PredicateCapacity;
                const name = try parser.name();
                var predicate: Predicate = .{ .column = try columnIndex(table, &name) };
                if (parser.takeWord("IS")) {
                    predicate.op = if (parser.takeWord("NOT")) .is_not_null else .is_null;
                    try parser.expectWord("NULL");
                } else {
                    if (parser.take('=')) {
                        predicate.op = .equal;
                    } else if (parser.take('!')) {
                        try parser.expect('=');
                        predicate.op = .not_equal;
                    } else if (parser.take('<')) {
                        predicate.op = if (parser.take('=')) .less_equal else if (parser.take('>')) .not_equal else .less;
                    } else if (parser.take('>')) {
                        predicate.op = if (parser.take('=')) .greater_equal else .greater;
                    } else return error.Syntax;
                    predicate.value = try parser.literal();
                    if (predicate.value != .null_value) {
                        var column = table.columns[predicate.column];
                        column.not_null = false;
                        // PostgreSQL promotes out-of-range comparison constants;
                        // range enforcement belongs to assignment, not WHERE.
                        if (column.data_type == .integer32) column.data_type = .integer;
                        try validate(&column, &predicate.value);
                    }
                }
                out.items[out.len] = predicate;
                out.len += 1;
                if (!parser.takeWord("AND")) break;
            }
            return out;
        }

        /// NULL sorts first for ASC, last for DESC. Other values have strict
        /// schema types; no numeric/text or integer/boolean coercion occurs.
        fn compare(left: *const Cell, right: *const Cell) i8 {
            if (left.* == .null_value) return if (right.* == .null_value) 0 else -1;
            if (right.* == .null_value) return 1;
            return switch (left.*) {
                .null_value => 0,
                .integer => |value| if (value < right.integer) -1 else if (value > right.integer) 1 else 0,
                .boolean => |value| if (value == right.boolean) 0 else if (value) 1 else -1,
                .text => |*value| bytesOrder(value.slice(), right.text.slice()),
            };
        }

        fn matches(row: *const Row, where: *const Filter) bool {
            for (where.items[0..where.len]) |*predicate| {
                const value = &row.cells[predicate.column];
                if (predicate.op == .is_null) {
                    if (value.* != .null_value) return false;
                    continue;
                }
                if (predicate.op == .is_not_null) {
                    if (value.* == .null_value) return false;
                    continue;
                }
                if (value.* == .null_value or predicate.value == .null_value) return false;
                const order = compare(value, &predicate.value);
                const matched = switch (predicate.op) {
                    .equal => order == 0,
                    .not_equal => order != 0,
                    .less => order < 0,
                    .less_equal => order <= 0,
                    .greater => order > 0,
                    .greater_equal => order >= 0,
                    .is_null, .is_not_null => unreachable,
                };
                if (!matched) return false;
            }
            return true;
        }

        fn select(self: *Self, parser: *Parser, result: *Result) Error!void {
            const all = parser.take('*');
            var names: [config.columns]Name = @splat(.{});
            var count: usize = 0;
            if (!all) {
                while (true) {
                    if (count == config.columns) return error.ColumnCapacity;
                    names[count] = try parser.name();
                    count += 1;
                    if (!parser.take(',')) break;
                }
            }
            try parser.expectWord("FROM");
            const name = try parser.name();
            const table = &self.tables[try self.tableIndex(&name)];
            var projection: [config.columns]usize = @splat(0);
            if (all) {
                count = table.column_count;
                for (0..count) |index| projection[index] = index;
            } else {
                for (0..count) |index| projection[index] = try columnIndex(table, &names[index]);
            }
            const where = try filter(parser, table);
            var order_column: ?usize = null;
            var descending = false;
            var explicit_nulls_first: ?bool = null;
            if (parser.takeWord("ORDER")) {
                try parser.expectWord("BY");
                const column_name = try parser.name();
                order_column = try columnIndex(table, &column_name);
                if (parser.takeWord("DESC")) descending = true else _ = parser.takeWord("ASC");
                if (parser.takeWord("NULLS")) {
                    if (parser.takeWord("FIRST")) explicit_nulls_first = true else if (parser.takeWord("LAST")) explicit_nulls_first = false else return error.Syntax;
                }
            }
            var limit: u64 = config.rows_per_table;
            if (parser.takeWord("LIMIT")) limit = try parser.unsigned(18446744073709551615);
            try parser.finish();
            var indices: [config.rows_per_table]usize = undefined;
            var found: usize = 0;
            if (primaryPredicate(table, &where)) |key| {
                if (primaryLookup(table, key)) |index| {
                    if (matches(&table.rows[index], &where)) {
                        indices[0] = index;
                        found = 1;
                    }
                }
            } else if (limit != 0) {
                for (table.rows[0..table.row_count], 0..) |*row, index| if (matches(row, &where)) {
                    indices[found] = index;
                    found += 1;
                    if (order_column == null and found >= limit) break;
                };
            }
            if (order_column) |column| {
                const nulls_first = explicit_nulls_first orelse (config.nulls_first_ascending != descending);
                // Stable insertion sort over row indices avoids copying text
                // cells during sorting and preserves insertion order for ties.
                var index: usize = 1;
                while (index < found) : (index += 1) {
                    const selected = indices[index];
                    var position = index;
                    while (position != 0) {
                        const left = &table.rows[selected].cells[column];
                        const right = &table.rows[indices[position - 1]].cells[column];
                        const order = if (left.* == .null_value or right.* == .null_value) blk: {
                            if (left.* == .null_value and right.* == .null_value) break :blk @as(i8, 0);
                            break :blk if ((left.* == .null_value) == nulls_first) @as(i8, -1) else @as(i8, 1);
                        } else blk: {
                            const value = compare(left, right);
                            break :blk if (descending) -value else value;
                        };
                        if (order >= 0) break;
                        indices[position] = indices[position - 1];
                        position -= 1;
                    }
                    indices[position] = selected;
                }
            }
            result.clear(0);
            result.column_count = count;
            result.row_count = if (limit < found) @intCast(limit) else found;
            for (0..count) |index| {
                result.column_names[index] = table.columns[projection[index]].name;
                result.column_types[index] = table.columns[projection[index]].data_type;
            }
            for (0..result.row_count) |row_index| for (0..count) |column| {
                result.rows[row_index].cells[column] = table.rows[indices[row_index]].cells[projection[column]];
            };
        }

        fn update(self: *Self, parser: *Parser, result: *Result, boundary: anytype) !void {
            const name = try parser.name();
            const table = &self.tables[try self.tableIndex(&name)];
            try parser.expectWord("SET");
            var assignments: Row = .{};
            var assigned: [config.columns]bool = @splat(false);
            while (true) {
                const column_name = try parser.name();
                const column = try columnIndex(table, &column_name);
                if (assigned[column]) return error.DuplicateColumn;
                try parser.expect('=');
                assignments.cells[column] = try parser.literal();
                try validate(&table.columns[column], &assignments.cells[column]);
                assigned[column] = true;
                if (!parser.take(',')) break;
            }
            const where = try filter(parser, table);
            try parser.finish();
            var selected: [config.rows_per_table]bool = undefined;
            var affected: usize = 0;
            var last_selected: usize = 0;
            if (primaryPredicate(table, &where)) |key| {
                if (primaryLookup(table, key)) |index| {
                    if (matches(&table.rows[index], &where)) {
                        affected = 1;
                        last_selected = index;
                    }
                }
            } else {
                @memset(&selected, false);
                for (table.rows[0..table.row_count], 0..) |*row, index| if (matches(row, &where)) {
                    selected[index] = true;
                    affected += 1;
                    last_selected = index;
                };
            }
            // All assignments are literals. Assigning one primary-key value to
            // multiple rows necessarily collides; compare untouched rows too.
            if (affected != 0) {
                for (table.columns[0..table.column_count], 0..) |*column, index| {
                    if (!column.primary_key or !assigned[index]) continue;
                    if (affected > 1) return error.PrimaryKeyViolation;
                    if (primaryLookup(table, &assignments.cells[index])) |row_index|
                        if (row_index != last_selected) return error.PrimaryKeyViolation;
                }
            }
            try boundary.before();
            if (affected == 1) {
                for (0..table.column_count) |column| if (assigned[column]) {
                    table.rows[last_selected].cells[column] = assignments.cells[column];
                };
            } else if (affected > 1) {
                for (0..table.row_count) |row_index| if (selected[row_index]) {
                    for (0..table.column_count) |column| if (assigned[column]) {
                        table.rows[row_index].cells[column] = assignments.cells[column];
                    };
                };
            }
            if (affected != 0) {
                if (table.primary_column) |column| if (assigned[column]) {
                    rebuildIndex(table);
                };
            }
            result.clear(affected);
        }

        fn delete(self: *Self, parser: *Parser, result: *Result, boundary: anytype) !void {
            try parser.expectWord("FROM");
            const name = try parser.name();
            const table = &self.tables[try self.tableIndex(&name)];
            const where = try filter(parser, table);
            try parser.finish();
            try boundary.before();
            var kept: usize = 0;
            const old_count = table.row_count;
            for (0..old_count) |index| {
                if (matches(&table.rows[index], &where)) continue;
                if (kept != index) table.rows[kept] = table.rows[index];
                kept += 1;
            }
            // Discarded payloads are outside row_count and never observable.
            // New INSERTs initialize their complete row before publication.
            table.row_count = kept;
            if (kept != old_count) rebuildIndex(table);
            result.clear(old_count - kept);
        }

        const Parser = struct {
            source: []const u8,
            position: usize = 0,

            fn space(self: *Parser) void {
                while (self.position < self.source.len) {
                    const byte = self.source[self.position];
                    if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
                        self.position += 1;
                    } else if (byte == '-' and self.position + 1 < self.source.len and self.source[self.position + 1] == '-') {
                        self.position += 2;
                        while (self.position < self.source.len and self.source[self.position] != '\n') self.position += 1;
                    } else break;
                }
            }

            fn take(self: *Parser, byte: u8) bool {
                self.space();
                if (self.position == self.source.len or self.source[self.position] != byte) return false;
                self.position += 1;
                return true;
            }

            fn expect(self: *Parser, byte: u8) Error!void {
                if (!self.take(byte)) return error.Syntax;
            }

            fn word(self: *Parser) []const u8 {
                self.space();
                const start = self.position;
                if (start == self.source.len or !letter(self.source[start])) return self.source[start..start];
                self.position += 1;
                while (self.position < self.source.len and (letter(self.source[self.position]) or digit(self.source[self.position]))) self.position += 1;
                return self.source[start..self.position];
            }

            fn takeWord(self: *Parser, expected: []const u8) bool {
                const saved = self.position;
                if (keyword(self.word(), expected)) return true;
                self.position = saved;
                return false;
            }

            fn expectWord(self: *Parser, expected: []const u8) Error!void {
                if (!self.takeWord(expected)) return error.Syntax;
            }

            fn name(self: *Parser) Error!Name {
                const source = self.word();
                if (source.len == 0) return error.Syntax;
                for ([_][]const u8{ "CREATE", "DROP", "INSERT", "SELECT", "UPDATE", "DELETE", "TABLE", "INTO", "VALUES", "FROM", "WHERE", "AND", "OR", "SET", "ORDER", "BY", "ASC", "DESC", "LIMIT", "IS", "NOT", "NULL", "TRUE", "FALSE", "PRIMARY", "KEY" }) |reserved|
                    if (keyword(source, reserved)) return error.Syntax;
                if (source.len > config.name_bytes) return error.NameCapacity;
                var out: Name = .{ .len = source.len };
                for (source, 0..) |byte, index| out.bytes[index] = lower(byte);
                return out;
            }

            fn unsigned(self: *Parser, maximum: u64) Error!u64 {
                self.space();
                const start = self.position;
                var value: u64 = 0;
                while (self.position < self.source.len and digit(self.source[self.position])) : (self.position += 1) {
                    const next: u64 = self.source[self.position] - '0';
                    if (value > (maximum - next) / 10) return error.IntegerOverflow;
                    value = value * 10 + next;
                }
                if (start == self.position) return error.Syntax;
                if (self.position < self.source.len and letter(self.source[self.position])) return error.Syntax;
                return value;
            }

            fn literal(self: *Parser) Error!Cell {
                if (self.takeWord("NULL")) return .null_value;
                if (self.takeWord("TRUE")) return .{ .boolean = true };
                if (self.takeWord("FALSE")) return .{ .boolean = false };
                if (self.take('\'')) {
                    var text: Text = .{};
                    while (self.position < self.source.len) {
                        const byte = self.source[self.position];
                        self.position += 1;
                        if (byte == '\'') {
                            if (self.position == self.source.len or self.source[self.position] != '\'') return .{ .text = text };
                            self.position += 1;
                        }
                        if (text.len == config.text_bytes) return error.TextCapacity;
                        text.bytes[text.len] = byte;
                        text.len += 1;
                    }
                    return error.Syntax;
                }
                const negative = self.take('-');
                const magnitude = try self.unsigned(if (negative) 9223372036854775808 else 9223372036854775807);
                const integer: i64 = if (negative)
                    (if (magnitude == 9223372036854775808) -9223372036854775808 else -@as(i64, @intCast(magnitude)))
                else
                    @intCast(magnitude);
                return .{ .integer = integer };
            }

            fn finish(self: *Parser) Error!void {
                _ = self.take(';');
                self.space();
                if (self.position != self.source.len) return error.Syntax;
            }
        };
    };
}
