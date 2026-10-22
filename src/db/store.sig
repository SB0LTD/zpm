//! Shared bounded SQL store and serialized, isolated connection transactions.
//! A single caller-owned snapshot is copied on BEGIN, never on ordinary queries.
//! Concurrent connections receive DatabaseBusy until the owning transaction ends.

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub fn Store(comptime Raw: type) type {
    return struct {
        const Self = @This();
        database: Raw = .{},
        snapshot: Raw = .{},
        owner: u64 = 0,

        pub const Connection = struct {
            pub const Result = Raw.Result;
            store: *Self,
            id: u64,
            failed: bool = false,
            autocommit: bool = true,

            pub fn beginTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (self.failed) return error.TransactionFailed;
                if (self.store.owner == self.id) return;
                if (self.store.owner != 0) return error.DatabaseBusy;
                self.store.snapshot = self.store.database;
                self.store.owner = self.id;
                self.failed = false;
            }

            pub fn commitTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (self.store.owner != self.id) return;
                if (self.failed) self.store.database = self.store.snapshot;
                self.store.owner = 0;
                self.failed = false;
            }

            pub fn rollbackTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (self.store.owner != self.id) return;
                self.store.database = self.store.snapshot;
                self.store.owner = 0;
                self.failed = false;
            }

            pub fn failTransaction(self: *Connection) void {
                if (self.id != 0 and self.store.owner == self.id) self.failed = true;
            }

            pub fn transactionStatus(self: *const Connection) u8 {
                if (self.id == 0 or self.store.owner != self.id) return 'I';
                return if (self.failed) 'E' else 'T';
            }

            pub fn isAutocommit(self: *const Connection) bool {
                return self.autocommit;
            }

            pub fn setAutocommit(self: *Connection, enabled: bool) !void {
                if (enabled and !self.autocommit) try self.commitTransaction();
                self.autocommit = enabled;
            }

            pub fn disconnect(self: *Connection) void {
                self.rollbackTransaction() catch {};
            }

            pub fn execute(self: *Connection, source: []const u8, result: *Result) !void {
                if (self.id == 0) return error.InvalidConnection;
                // Normalize command syntax only; original SQL goes to the strict parser.
                var command: [4096]u8 = undefined;
                var count: usize = 0;
                var pending_space = false;
                for (source) |byte| {
                    if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
                        pending_space = count != 0;
                        continue;
                    }
                    if (pending_space and byte != ';') {
                        if (count == command.len) return error.Syntax;
                        command[count] = ' ';
                        count += 1;
                    }
                    pending_space = false;
                    if (count == command.len) return error.Syntax;
                    command[count] = if (byte >= 'a' and byte <= 'z') byte - 32 else byte;
                    count += 1;
                }
                if (count != 0 and command[count - 1] == ';') count -= 1;
                const cmd = command[0..count];
                if (same(cmd, "BEGIN") or same(cmd, "BEGIN TRANSACTION") or same(cmd, "START TRANSACTION")) {
                    try self.beginTransaction();
                    result.clear(0);
                    return;
                }
                if (same(cmd, "COMMIT") or same(cmd, "COMMIT TRANSACTION")) {
                    try self.commitTransaction();
                    result.clear(0);
                    return;
                }
                if (same(cmd, "ROLLBACK") or same(cmd, "ROLLBACK TRANSACTION")) {
                    try self.rollbackTransaction();
                    result.clear(0);
                    return;
                }
                if (self.store.owner != 0 and self.store.owner != self.id) return error.DatabaseBusy;
                if (self.failed) return error.TransactionFailed;
                if (same(cmd, "SET AUTOCOMMIT = 0") or same(cmd, "SET AUTOCOMMIT=0")) {
                    try self.setAutocommit(false);
                    result.clear(0);
                    return;
                }
                if (same(cmd, "SET AUTOCOMMIT = 1") or same(cmd, "SET AUTOCOMMIT=1")) {
                    try self.setAutocommit(true);
                    result.clear(0);
                    return;
                }
                if (same(cmd, "SET NAMES UTF8MB4") or same(cmd, "SET NAMES UTF8") or
                    same(cmd, "SET CLIENT_ENCODING = 'UTF8'") or same(cmd, "SET CLIENT_ENCODING TO 'UTF8'") or
                    same(cmd, "SET STANDARD_CONFORMING_STRINGS = ON") or same(cmd, "SET TIME ZONE 'UTC'") or
                    same(cmd, "SET TEXTSIZE 2147483647"))
                {
                    result.clear(0);
                    return;
                }
                if (!self.autocommit and self.store.owner == 0) try self.beginTransaction();
                if (same(cmd, "SELECT 1")) {
                    result.clear(0);
                    result.column_count = 1;
                    result.row_count = 1;
                    const name_length = @min(result.column_names[0].bytes.len, 8);
                    result.column_names[0] = .{ .len = name_length };
                    @memcpy(result.column_names[0].bytes[0..name_length], "?column?"[0..name_length]);
                    result.column_types[0] = .integer;
                    result.rows[0].cells[0] = .{ .integer = 1 };
                    return;
                }
                try self.store.database.execute(source, result);
            }
        };
    };
}
