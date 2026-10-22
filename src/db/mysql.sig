//! Allocation-free MySQL protocol 10 / protocol 4.1 text-query endpoint.
//!
//! The owner supplies input/output storage and a serialized database adapter.
//! This endpoint is for explicitly trusted local connections: TLS and password
//! authentication are unavailable; nonempty password responses are rejected.
//! Supports COM_QUERY, COM_INIT_DB, COM_PING and COM_QUIT. Prepared statements,
//! compression, multiple statements/results and replication are not supported.
//! Source: dev.mysql.com/doc/dev/mysql-server/latest/PAGE_PROTOCOL.html.

pub const max_request_bytes: usize = 65536;
pub const Reply = struct { consumed: usize = 0, written: usize = 0, close: bool = false };
pub const Error = error{ BufferTooSmall, MalformedPacket, RequestTooLarge, InvalidSequence, InvalidState };

const protocol_41: u32 = 0x200;
const secure_connection: u32 = 0x8000;
const plugin_auth: u32 = 0x80000;
const connect_attrs: u32 = 0x100000;
const lenenc_auth: u32 = 0x200000;
const capabilities: u32 = 1 | 4 | 8 | protocol_41 | 0x2000 | secure_connection | plugin_auth | connect_attrs | lenenc_auth;

fn readLe(source: []const u8) u64 {
    var value: u64 = 0;
    for (source, 0..) |byte, index| value |= @as(u64, byte) << @intCast(index * 8);
    return value;
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

fn terminated(source: []const u8, position: *usize) Error![]const u8 {
    const start = position.*;
    while (position.* < source.len and source[position.*] != 0) position.* += 1;
    if (position.* == source.len) return error.MalformedPacket;
    const end = position.*;
    position.* += 1;
    return source[start..end];
}

fn readLength(source: []const u8, position: *usize) Error!usize {
    if (position.* >= source.len) return error.MalformedPacket;
    const first = source[position.*];
    position.* += 1;
    if (first < 0xfb) return first;
    const bytes: usize = switch (first) { 0xfc => 2, 0xfd => 3, 0xfe => 8, else => return error.MalformedPacket };
    if (bytes > source.len - position.*) return error.MalformedPacket;
    const value = readLe(source[position.*..][0..bytes]);
    position.* += bytes;
    if (value > max_request_bytes) return error.RequestTooLarge;
    return @intCast(value);
}

const Writer = struct {
    output: []u8,
    pos: usize = 0,
    sequence: u8 = 0,

    fn bytes(self: *Writer, value: []const u8) Error!void {
        if (value.len > self.output.len - self.pos) return error.BufferTooSmall;
        @memcpy(self.output[self.pos..][0..value.len], value);
        self.pos += value.len;
    }

    fn byte(self: *Writer, value: u8) Error!void {
        if (self.pos == self.output.len) return error.BufferTooSmall;
        self.output[self.pos] = value;
        self.pos += 1;
    }

    fn number(self: *Writer, value: u64, comptime count: usize) Error!void {
        for (0..count) |index| try self.byte(@truncate(value >> @intCast(index * 8)));
    }

    fn length(self: *Writer, value: usize) Error!void {
        if (value < 0xfb) return self.byte(@intCast(value));
        if (value <= 0xffff) {
            try self.byte(0xfc);
            return self.number(value, 2);
        }
        if (value <= 0xffffff) {
            try self.byte(0xfd);
            return self.number(value, 3);
        }
        try self.byte(0xfe);
        try self.number(value, 8);
    }

    fn string(self: *Writer, value: []const u8) Error!void {
        try self.length(value.len);
        try self.bytes(value);
    }

    fn packet(self: *Writer) Error!usize {
        const start = self.pos;
        try self.number(0, 3);
        try self.byte(self.sequence);
        self.sequence +%= 1;
        return start;
    }

    fn finish(self: *Writer, start: usize) Error!void {
        const len = self.pos - start - 4;
        if (len > 0xffffff) return error.BufferTooSmall;
        for (0..3) |index| self.output[start + index] = @truncate(len >> @intCast(index * 8));
    }

    fn ok(self: *Writer, affected: usize, status: u16) Error!void {
        const start = try self.packet();
        try self.byte(0);
        try self.length(affected);
        try self.byte(0); // last_insert_id
        try self.number(status, 2);
        try self.number(0, 2); // warnings
        try self.finish(start);
    }

    fn eof(self: *Writer, status: u16) Error!void {
        const start = try self.packet();
        try self.byte(0xfe);
        try self.number(0, 2); // warnings
        try self.number(status, 2);
        try self.finish(start);
    }

    fn failure(self: *Writer, code: u16, state: []const u8, message: []const u8) Error!void {
        const start = try self.packet();
        try self.byte(0xff);
        try self.number(code, 2);
        try self.byte('#');
        try self.bytes(state);
        try self.bytes(message);
        try self.finish(start);
    }

    fn decimal(self: *Writer, value: i64) Error!void {
        var scratch: [21]u8 = undefined;
        var position = scratch.len;
        var magnitude: u64 = if (value < 0) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
        while (true) {
            position -= 1;
            scratch[position] = @as(u8, @intCast(magnitude % 10)) + '0';
            magnitude /= 10;
            if (magnitude == 0) break;
        }
        if (value < 0) {
            position -= 1;
            scratch[position] = '-';
        }
        try self.string(scratch[position..]);
    }
};

pub fn Session(comptime DB: type) type {
    return struct {
        const Self = @This();
        authenticated: bool = false,
        greeted: bool = false,
        closed: bool = false,
        result: DB.Result = .{},

        /// A conservative bound for the complete largest possible response.
        /// Provision before processing requests so successful mutations cannot
        /// subsequently fail while encoding their response.
        pub fn responseCapacity() usize {
            return @sizeOf(DB.Result) * 2 + 4096;
        }

        pub fn begin(self: *Self, out: []u8) Error!usize {
            if (self.greeted or self.closed) return error.InvalidState;
            var writer: Writer = .{ .output = out };
            const start = try writer.packet();
            try writer.byte(10);
            try writer.bytes("8.0.0-RAMSQL\x00");
            try writer.number(1, 4);
            try writer.bytes("RAMSQL01\x00");
            try writer.number(capabilities & 0xffff, 2);
            try writer.byte(45); // utf8mb4_general_ci
            try writer.number(2, 2); // SERVER_STATUS_AUTOCOMMIT
            try writer.number(capabilities >> 16, 2);
            try writer.byte(21);
            try writer.bytes(&@as([10]u8, @splat(0)));
            try writer.bytes("RAMSQLLOCAL1\x00");
            try writer.bytes("mysql_native_password\x00");
            try writer.finish(start);
            self.greeted = true;
            return writer.pos;
        }

        fn status(_: *const Self, db: *DB) u16 {
            var flags: u16 = 2;
            if (@hasDecl(DB, "isAutocommit")) flags = if (db.isAutocommit()) 2 else 0;
            if (@hasDecl(DB, "transactionStatus")) {
                if (db.transactionStatus() != 'I') flags |= 1;
            }
            return flags;
        }

        fn authenticate(self: *Self, payload: []const u8, writer: *Writer) Error!bool {
            if (payload.len < 32) return error.MalformedPacket;
            const client: u32 = @intCast(readLe(payload[0..4]));
            if (client & protocol_41 == 0 or client & (0x20 | 0x800) != 0) {
                try writer.failure(1045, "28000", "RAMSQL requires uncompressed protocol 4.1; TLS is unavailable");
                return false;
            }
            var position: usize = 32;
            _ = try terminated(payload, &position); // local trust username
            var auth: []const u8 = undefined;
            if (client & lenenc_auth != 0) {
                const count = try readLength(payload, &position);
                if (count > payload.len - position) return error.MalformedPacket;
                auth = payload[position..][0..count];
                position += count;
            } else if (client & secure_connection != 0) {
                if (position == payload.len) return error.MalformedPacket;
                const count: usize = payload[position];
                position += 1;
                if (count > payload.len - position) return error.MalformedPacket;
                auth = payload[position..][0..count];
                position += count;
            } else auth = try terminated(payload, &position);
            if (auth.len != 0) {
                try writer.failure(1045, "28000", "RAMSQL local trust accepts empty passwords only");
                return false;
            }
            if (client & 8 != 0) {
                const database = try terminated(payload, &position);
                if (database.len != 0 and !equal(database, "ramsql")) {
                    try writer.failure(1049, "42000", "Unknown database; use ramsql");
                    return false;
                }
            }
            if (client & plugin_auth != 0) {
                const plugin = try terminated(payload, &position);
                if (plugin.len != 0 and !equal(plugin, "mysql_native_password")) {
                    try writer.failure(1251, "08004", "Only mysql_native_password with an empty password is available");
                    return false;
                }
            }
            if (client & connect_attrs != 0) {
                const count = try readLength(payload, &position);
                if (count > payload.len - position) return error.MalformedPacket;
                const end = position + count;
                while (position < end) {
                    const key = try readLength(payload[0..end], &position);
                    if (key > end - position) return error.MalformedPacket;
                    position += key;
                    const value = try readLength(payload[0..end], &position);
                    if (value > end - position) return error.MalformedPacket;
                    position += value;
                }
            }
            if (position != payload.len) return error.MalformedPacket;
            try writer.ok(0, 2);
            self.authenticated = true;
            return true;
        }

        fn sqlError(writer: *Writer, err: anyerror) Error!void {
            const details: struct { u16, []const u8 } = switch (err) {
                error.TableNotFound => .{ 1146, "42S02" },
                error.TableExists => .{ 1050, "42S01" },
                error.ColumnNotFound => .{ 1054, "42S22" },
                error.PrimaryKeyViolation => .{ 1062, "23000" },
                error.NotNullViolation => .{ 1048, "23000" },
                error.TypeMismatch, error.IntegerOverflow => .{ 1264, "22003" },
                error.DatabaseBusy => .{ 1205, "HY000" },
                else => .{ 1064, "42000" },
            };
            try writer.failure(details[0], details[1], @errorName(err));
        }

        fn results(self: *Self, writer: *Writer, flags: u16) Error!void {
            if (self.result.column_count == 0) return writer.ok(self.result.affected_rows, flags);
            var start = try writer.packet();
            try writer.length(self.result.column_count);
            try writer.finish(start);
            for (0..self.result.column_count) |column| {
                start = try writer.packet();
                try writer.string("def");
                try writer.string("ramsql");
                try writer.string(""); // table
                try writer.string(""); // original table
                try writer.string(self.result.column_names[column].slice());
                try writer.string(""); // original name
                try writer.byte(0x0c);
                try writer.number(45, 2);
                const kind = self.result.column_types[column];
                try writer.number(switch (kind) { .integer => 20, .boolean => 1, .text => 65535 }, 4);
                try writer.byte(switch (kind) { .integer => 8, .boolean => 1, .text => 253 });
                try writer.number(0, 2); // nullable, signed
                try writer.byte(0); // decimals
                try writer.number(0, 2);
                try writer.finish(start);
            }
            try writer.eof(flags);
            for (self.result.rows[0..self.result.row_count]) |*row| {
                start = try writer.packet();
                for (row.cells[0..self.result.column_count]) |*cell| switch (cell.*) {
                    .null_value => try writer.byte(0xfb),
                    .integer => |value| try writer.decimal(value),
                    .boolean => |value| try writer.string(if (value) "1" else "0"),
                    .text => |*value| try writer.string(value.slice()),
                };
                try writer.finish(start);
            }
            try writer.eof(flags);
        }

        pub fn handle(self: *Self, db: *DB, input: []const u8, out: []u8) Error!Reply {
            if (!self.greeted or self.closed) return error.InvalidState;
            if (input.len < 4) return .{};
            const length: usize = @intCast(readLe(input[0..3]));
            if (length > max_request_bytes - 4) return error.RequestTooLarge;
            if (length > input.len - 4) return .{};
            if (input[3] != (if (self.authenticated) @as(u8, 0) else @as(u8, 1))) return error.InvalidSequence;
            if (out.len < responseCapacity()) return error.BufferTooSmall;
            var writer: Writer = .{ .output = out, .sequence = if (self.authenticated) 1 else 2 };
            const payload = input[4..][0..length];
            var reply: Reply = .{ .consumed = length + 4 };
            if (!self.authenticated) {
                reply.close = !try self.authenticate(payload, &writer);
            } else {
                if (payload.len == 0) return error.MalformedPacket;
                switch (payload[0]) {
                    1 => {
                        if (payload.len != 1) return error.MalformedPacket;
                        reply.close = true;
                    },
                    2 => {
                        if (equal(payload[1..], "ramsql")) try writer.ok(0, self.status(db)) else
                            try writer.failure(1049, "42000", "Unknown database; use ramsql");
                    },
                    3 => {
                        if (db.execute(payload[1..], &self.result)) |_| {
                            try self.results(&writer, self.status(db));
                        } else |err| try sqlError(&writer, err);
                    },
                    14 => {
                        if (payload.len != 1) return error.MalformedPacket;
                        try writer.ok(0, self.status(db));
                    },
                    else => try writer.failure(1047, "08S01", "Unsupported MySQL command"),
                }
            }
            reply.written = writer.pos;
            self.closed = reply.close;
            return reply;
        }
    };
}
