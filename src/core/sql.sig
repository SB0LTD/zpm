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
//! Transactions, joins, expressions, aggregates, indices and persistence are
//! outside this initial SQL subset. No allocator, platform, or std dependency.

pub const Config = struct {
    tables: usize = 4,
    columns: usize = 8,
    rows_per_table: usize = 128,
    name_bytes: usize = 32,
    text_bytes: usize = 128,
    predicates: usize = 8,
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

pub const DataType = enum { integer, boolean, text };

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
    if (config.tables == 0 or config.columns == 0 or config.rows_per_table == 0 or
        config.name_bytes == 0 or config.text_bytes == 0 or config.predicates == 0)
        @compileError("SQL capacities must be non-zero");

    return struct {
        const Self = @This();

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
            rows: [config.rows_per_table]Row = @splat(.{}),
        };

        const Table = struct {
            live: bool = false,
            name: Name = .{},
            column_count: usize = 0,
            row_count: usize = 0,
            columns: [config.columns]Column = @splat(.{}),
            rows: [config.rows_per_table]Row = @splat(.{}),
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
            var parser = Parser{ .source = source };
            if (parser.takeWord("CREATE")) return self.create(&parser, result);
            if (parser.takeWord("DROP")) return self.drop(&parser, result);
            if (parser.takeWord("INSERT")) return self.insert(&parser, result);
            if (parser.takeWord("SELECT")) return self.select(&parser, result);
            if (parser.takeWord("UPDATE")) return self.update(&parser, result);
            if (parser.takeWord("DELETE")) return self.delete(&parser, result);
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

        fn create(self: *Self, parser: *Parser, result: *Result) Error!void {
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
            self.tables[index] = .{ .live = true, .name = name, .column_count = count, .columns = columns };
            result.* = .{};
        }

        fn drop(self: *Self, parser: *Parser, result: *Result) Error!void {
            try parser.expectWord("TABLE");
            const name = try parser.name();
            const index = try self.tableIndex(&name);
            try parser.finish();
            self.tables[index] = .{};
            result.* = .{};
        }

        fn validate(column: *const Column, value: *const Cell) Error!void {
            switch (value.*) {
                .null_value => if (column.not_null) return error.NotNullViolation,
                .integer => if (column.data_type != .integer) return error.TypeMismatch,
                .boolean => if (column.data_type != .boolean) return error.TypeMismatch,
                .text => if (column.data_type != .text) return error.TypeMismatch,
            }
        }

        fn insert(self: *Self, parser: *Parser, result: *Result) Error!void {
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
                    for (table.rows[0..table.row_count]) |*existing|
                        if (compare(&row.cells[index], &existing.cells[index]) == 0) return error.PrimaryKeyViolation;
                }
            }
            if (table.row_count == config.rows_per_table) return error.RowCapacity;
            table.rows[table.row_count] = row;
            table.row_count += 1;
            result.* = .{ .affected_rows = 1 };
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
            if (parser.takeWord("ORDER")) {
                try parser.expectWord("BY");
                const column_name = try parser.name();
                order_column = try columnIndex(table, &column_name);
                if (parser.takeWord("DESC")) descending = true else _ = parser.takeWord("ASC");
            }
            var limit: u64 = config.rows_per_table;
            if (parser.takeWord("LIMIT")) limit = try parser.unsigned(18446744073709551615);
            try parser.finish();
            var indices: [config.rows_per_table]usize = @splat(0);
            var found: usize = 0;
            for (table.rows[0..table.row_count], 0..) |*row, index| if (matches(row, &where)) {
                indices[found] = index;
                found += 1;
            };
            if (order_column) |column| {
                // Stable insertion sort over row indices avoids copying text
                // cells during sorting and preserves insertion order for ties.
                var index: usize = 1;
                while (index < found) : (index += 1) {
                    const selected = indices[index];
                    var position = index;
                    while (position != 0) {
                        const order = compare(&table.rows[selected].cells[column], &table.rows[indices[position - 1]].cells[column]);
                        if (if (descending) order <= 0 else order >= 0) break;
                        indices[position] = indices[position - 1];
                        position -= 1;
                    }
                    indices[position] = selected;
                }
            }
            result.* = .{};
            result.column_count = count;
            result.row_count = if (limit < found) @intCast(limit) else found;
            for (0..count) |index| result.column_names[index] = table.columns[projection[index]].name;
            for (0..result.row_count) |row_index| for (0..count) |column| {
                result.rows[row_index].cells[column] = table.rows[indices[row_index]].cells[projection[column]];
            };
        }

        fn update(self: *Self, parser: *Parser, result: *Result) Error!void {
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
            var selected: [config.rows_per_table]bool = @splat(false);
            var affected: usize = 0;
            for (table.rows[0..table.row_count], 0..) |*row, index| if (matches(row, &where)) {
                selected[index] = true;
                affected += 1;
            };
            // All assignments are literals. Assigning one primary-key value to
            // multiple rows necessarily collides; compare untouched rows too.
            if (affected != 0) {
                for (table.columns[0..table.column_count], 0..) |*column, index| {
                    if (!column.primary_key or !assigned[index]) continue;
                    if (affected > 1) return error.PrimaryKeyViolation;
                    for (table.rows[0..table.row_count], 0..) |*row, row_index|
                        if (!selected[row_index] and compare(&row.cells[index], &assignments.cells[index]) == 0) return error.PrimaryKeyViolation;
                }
            }
            for (0..table.row_count) |row_index| if (selected[row_index]) {
                for (0..table.column_count) |column| if (assigned[column]) {
                    table.rows[row_index].cells[column] = assignments.cells[column];
                };
            };
            result.* = .{ .affected_rows = affected };
        }

        fn delete(self: *Self, parser: *Parser, result: *Result) Error!void {
            try parser.expectWord("FROM");
            const name = try parser.name();
            const table = &self.tables[try self.tableIndex(&name)];
            const where = try filter(parser, table);
            try parser.finish();
            var kept: usize = 0;
            const old_count = table.row_count;
            for (0..old_count) |index| {
                if (matches(&table.rows[index], &where)) continue;
                if (kept != index) table.rows[kept] = table.rows[index];
                kept += 1;
            }
            for (kept..old_count) |index| table.rows[index] = .{};
            table.row_count = kept;
            result.* = .{ .affected_rows = old_count - kept };
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
