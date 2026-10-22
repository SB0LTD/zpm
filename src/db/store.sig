//! Caller-owned, allocator-free SQL store with independent transaction snapshots.
//!
//! Callers serialize method calls (the network reactor already does this), but a
//! transaction never blocks another connection. A transaction reads its private
//! snapshot; a writing commit rejects any intervening committed write. This is
//! conservative optimistic isolation, not PostgreSQL's default READ COMMITTED.
//! Raw must accept exactly one statement, reject unsupported syntax, and leave
//! database/result unchanged on error. Its SELECT implementation is read-only.
//! Durable mode prepares a caller-owned candidate and invokes the synchronous
//! commit hook BEFORE publishing it or acknowledging success. No database-sized
//! automatic/stack storage is used. Hooks must not reenter this store.

pub const max_statement_bytes = 65536;

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn upper(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - 32 else byte;
}

fn whitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

// Match the strict SQL parser's whitespace and -- comments. Classification is
// deliberately limited to SELECT: unknown/future statements take the write path.
fn readonly(source: []const u8) bool {
    var offset: usize = 0;
    while (offset < source.len) {
        if (whitespace(source[offset])) {
            offset += 1;
        } else if (source[offset] == '-' and offset + 1 < source.len and source[offset + 1] == '-') {
            offset += 2;
            while (offset < source.len and source[offset] != '\n') offset += 1;
        } else break;
    }
    if (source.len - offset < 6) return false;
    for (source[offset..][0..6], "SELECT") |a, b| if (upper(a) != b) return false;
    offset += 6;
    if (offset == source.len) return true;
    const next = upper(source[offset]);
    return !((next >= 'A' and next <= 'Z') or (next >= '0' and next <= '9') or next == '_');
}

fn writeLength(bytes: []u8, length: usize) void {
    bytes[0] = @truncate(length);
    bytes[1] = @truncate(length >> 8);
    bytes[2] = @truncate(length >> 16);
    bytes[3] = @truncate(length >> 24);
}

/// A durable commit batch is [u32 little-endian length][SQL bytes], repeated.
/// Length framing preserves semicolons, newlines and comments inside literals.
/// The caller applies a complete batch to a scratch Raw and publishes only when
/// every statement succeeds; malformed/rejected batches must never partly apply.
pub const BatchIterator = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn next(self: *BatchIterator) !?[]const u8 {
        if (self.position == self.bytes.len) return null;
        if (self.position > self.bytes.len or self.bytes.len - self.position < 4) return error.InvalidCommitBatch;
        const header = self.bytes[self.position..][0..4];
        const length: usize = @as(usize, header[0]) | (@as(usize, header[1]) << 8) |
            (@as(usize, header[2]) << 16) | (@as(usize, header[3]) << 24);
        if (length == 0 or length > max_statement_bytes or length > self.bytes.len - self.position - 4) return error.InvalidCommitBatch;
        self.position += 4;
        const source = self.bytes[self.position..][0..length];
        self.position += length;
        return source;
    }
};

pub fn Store(comptime Raw: type) type {
    return struct {
        const Self = @This();
        pub const CommitFn = *const fn (?*anyopaque, []const u8) anyerror!void;

        database: Raw = .{},
        /// Caller owns the Store, so this result stays off the execute stack even
        /// when its configured row capacity is large. Only the durable candidate
        /// path uses it; ordinary SELECTs write directly to the caller's result.
        autocommit_result: Raw.Result = .{},
        generation: u64 = 0,
        /// Dedicated scratch space for durable autocommit, never a live tx view.
        autocommit_workspace: ?*Raw = null,
        commit_ctx: ?*anyopaque = null,
        commit_fn: ?CommitFn = null,
        durability_required: bool = false,
        /// A failed durable write requires recovery before further writes.
        storage_failed: bool = false,

        fn snapshot(destination: *Raw, source: *const Raw) void {
            if (@hasDecl(Raw, "copyFrom")) destination.copyFrom(source) else destination.* = source.*;
        }

        fn storageReady(self: *const Self) !void {
            if (self.storage_failed or (self.durability_required and self.commit_fn == null)) return error.StorageUnavailable;
            if (self.generation == 18446744073709551615) return error.GenerationExhausted;
        }

        fn persist(self: *Self, batch: []const u8) !void {
            try self.storageReady();
            if (self.commit_fn) |commit| {
                commit(self.commit_ctx, batch) catch |err| {
                    self.storage_failed = true;
                    return err;
                };
            }
        }

        pub const Connection = struct {
            pub const Result = Raw.Result;
            store: *Self,
            id: u64,
            failed: bool = false,
            autocommit: bool = true,
            /// Each connection needs distinct caller-owned transaction storage.
            transaction_workspace: ?*Raw = null,
            transaction_log: []u8 = &.{},
            in_transaction: bool = false,
            dirty: bool = false,
            base_generation: u64 = 0,
            log_used: usize = 0,
            logged: bool = false,

            pub fn beginTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (self.failed) return error.TransactionFailed;
                if (self.in_transaction) return;
                const workspace = self.transaction_workspace orelse return error.TransactionCapacity;
                if (workspace == &self.store.database or workspace == self.store.autocommit_workspace) return error.InvalidWorkspace;
                snapshot(workspace, &self.store.database);
                self.base_generation = self.store.generation;
                self.in_transaction = true;
                self.dirty = false;
                self.failed = false;
                self.log_used = 0;
                self.logged = self.store.commit_fn != null or self.store.durability_required;
            }

            fn resetTransaction(self: *Connection) void {
                // Stale workspace/log bytes are unreachable after this reset and
                // are overwritten when this connection begins another transaction.
                self.in_transaction = false;
                self.dirty = false;
                self.failed = false;
                self.log_used = 0;
                self.logged = false;
            }

            pub fn commitTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (!self.in_transaction) return;
                if (self.failed) {
                    self.resetTransaction();
                    return;
                }
                if (self.dirty) {
                    errdefer self.failed = true;
                    try self.store.storageReady();
                    const workspace = self.transaction_workspace orelse return error.InvalidWorkspace;
                    if (workspace == &self.store.database or workspace == self.store.autocommit_workspace) return error.InvalidWorkspace;
                    if (self.base_generation != self.store.generation) return error.SerializationFailure;
                    if (self.store.commit_fn != null and (!self.logged or self.log_used == 0)) return error.InvalidCommitBatch;
                    if (self.log_used > self.transaction_log.len) return error.InvalidCommitBatch;
                    try self.store.persist(self.transaction_log[0..self.log_used]);
                    snapshot(&self.store.database, workspace);
                    self.store.generation += 1;
                }
                self.resetTransaction();
            }

            pub fn rollbackTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                self.resetTransaction();
            }

            pub fn failTransaction(self: *Connection) void {
                if (self.id != 0 and self.in_transaction) self.failed = true;
            }

            pub fn transactionStatus(self: *const Connection) u8 {
                if (self.id == 0 or !self.in_transaction) return 'I';
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
                errdefer self.failTransaction();
                if (source.len == 0 or source.len > max_statement_bytes) return error.Syntax;
                // Normalize only bounded control commands. Long SQL still goes
                // intact to the strict parser without a second SQL-sized copy.
                var command: [256]u8 = undefined;
                var count: usize = 0;
                var pending_space = false;
                var long_command = false;
                for (source) |byte| {
                    if (whitespace(byte)) {
                        pending_space = count != 0;
                        continue;
                    }
                    if (pending_space and byte != ';') {
                        if (count == command.len) {
                            long_command = true;
                            break;
                        }
                        command[count] = ' ';
                        count += 1;
                    }
                    pending_space = false;
                    if (count == command.len) {
                        long_command = true;
                        break;
                    }
                    command[count] = upper(byte);
                    count += 1;
                }
                if (count != 0 and command[count - 1] == ';') count -= 1;
                const cmd = if (long_command) "" else command[0..count];
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
                if (!self.autocommit and !self.in_transaction) try self.beginTransaction();
                if (same(cmd, "SELECT 1")) {
                    result.clear(0);
                    result.column_count = 1;
                    result.row_count = 1;
                    const name_length = @min(result.column_names[0].bytes.len, 8);
                    result.column_names[0] = .{ .len = name_length };
                    @memcpy(result.column_names[0].bytes[0..name_length], "?column?"[0..name_length]);
                    result.column_types[0] = if (@hasDecl(Raw, "integer_type")) Raw.integer_type else .integer;
                    result.rows[0].cells[0] = .{ .integer = 1 };
                    return;
                }

                const reading = readonly(source);
                if (self.in_transaction) {
                    const workspace = self.transaction_workspace orelse return error.InvalidWorkspace;
                    if (!reading) {
                        try self.store.storageReady();
                        if (self.logged and (self.log_used > self.transaction_log.len or
                            source.len + 4 > self.transaction_log.len - self.log_used)) return error.TransactionLogCapacity;
                    }
                    try workspace.execute(source, result);
                    if (!reading) {
                        if (self.logged) {
                            writeLength(self.transaction_log[self.log_used..][0..4], source.len);
                            @memcpy(self.transaction_log[self.log_used + 4 ..][0..source.len], source);
                            self.log_used += source.len + 4;
                        }
                        self.dirty = true;
                    }
                    return;
                }
                if (reading) return self.store.database.execute(source, result);
                try self.store.storageReady();
                if (self.store.commit_fn == null) {
                    try self.store.database.execute(source, result);
                    self.store.generation += 1;
                    return;
                }
                const workspace = self.store.autocommit_workspace orelse return error.TransactionCapacity;
                if (workspace == &self.store.database or workspace == self.transaction_workspace) return error.InvalidWorkspace;
                if (result == &self.store.autocommit_result) return error.InvalidWorkspace;
                snapshot(workspace, &self.store.database);
                try workspace.execute(source, &self.store.autocommit_result);
                var batch: [max_statement_bytes + 4]u8 = undefined;
                writeLength(batch[0..4], source.len);
                @memcpy(batch[4..][0..source.len], source);
                try self.store.persist(batch[0 .. source.len + 4]);
                snapshot(&self.store.database, workspace);
                self.store.generation += 1;
                if (@hasDecl(Result, "copyFrom")) result.copyFrom(&self.store.autocommit_result) else result.* = self.store.autocommit_result;
            }
        };
    };
}
