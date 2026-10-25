//! Bounded allocation-free TDS 7.2–7.4 SQL batch endpoint.
//!
//! Implements PRELOGIN, LOGIN7, SQL_BATCH, sp_executesql RPC with native integer,
//! boolean, NVARCHAR and NULL bindings, transaction manager requests and typed
//! COLMETADATA/ROW/DONE responses. Other RPC/prepared statements, bulk copy,
//! MARS, integrated authentication, TLS and TDS 8 are explicitly unsupported.
//! Login is empty-password local trust; the server owner must restrict access.
//! Source: Microsoft [MS-TDS], sections 2.2.4–2.2.7.

pub const max_request_bytes: usize = 65536;
pub const max_parameters: usize = 32;
/// `blocked`: the statement is parked on a lock (consumed = written = 0);
/// re-deliver the same packet when the store reports progress.
pub const Reply = struct { consumed: usize = 0, written: usize = 0, close: bool = false, blocked: bool = false };
/// WouldBlock never leaves handle(); it becomes Reply.blocked.
pub const Error = error{ BufferTooSmall, MalformedPacket, RequestTooLarge, InvalidSequence, InvalidState, InvalidUnicode, UnsupportedValue, UnsupportedRpc, WouldBlock };

fn le(source: []const u8) u64 {
    var value: u64 = 0;
    for (source, 0..) |byte, index| value |= @as(u64, byte) << @intCast(index * 8);
    return value;
}

fn be16(source: []const u8) usize {
    return @as(usize, source[0]) * 256 + source[1];
}

fn utf8Next(source: []const u8, position: *usize) Error!u21 {
    if (position.* >= source.len) return error.InvalidUnicode;
    const first = source[position.*];
    position.* += 1;
    if (first < 0x80) return first;
    const count: usize = if (first >= 0xc2 and first <= 0xdf) 1 else if (first >= 0xe0 and first <= 0xef) 2 else if (first >= 0xf0 and first <= 0xf4) 3 else return error.InvalidUnicode;
    if (count > source.len - position.*) return error.InvalidUnicode;
    var point: u21 = first & (if (count == 1) @as(u8, 0x1f) else if (count == 2) @as(u8, 0x0f) else @as(u8, 7));
    for (0..count) |_| {
        const byte = source[position.*];
        position.* += 1;
        if (byte & 0xc0 != 0x80) return error.InvalidUnicode;
        point = (point << 6) | (byte & 0x3f);
    }
    if ((count == 1 and point < 0x80) or (count == 2 and point < 0x800) or
        (count == 3 and point < 0x10000) or (point >= 0xd800 and point <= 0xdfff) or point > 0x10ffff)
        return error.InvalidUnicode;
    return point;
}

fn utf16Length(source: []const u8) Error!usize {
    var position: usize = 0;
    var count: usize = 0;
    while (position < source.len) {
        const point = try utf8Next(source, &position);
        count += if (point < 0x10000) @as(usize, 1) else 2;
    }
    return count;
}

fn fromUtf16(source: []const u8, target: []u8) Error![]const u8 {
    if (source.len % 2 != 0) return error.InvalidUnicode;
    var position: usize = 0;
    var written: usize = 0;
    while (position < source.len) {
        var point: u21 = @intCast(le(source[position..][0..2]));
        position += 2;
        if (point >= 0xd800 and point <= 0xdbff) {
            if (position == source.len) return error.InvalidUnicode;
            const low: u21 = @intCast(le(source[position..][0..2]));
            position += 2;
            if (low < 0xdc00 or low > 0xdfff) return error.InvalidUnicode;
            point = 0x10000 + ((point - 0xd800) << 10) + low - 0xdc00;
        } else if (point >= 0xdc00 and point <= 0xdfff) return error.InvalidUnicode;
        const count: usize = if (point < 0x80) 1 else if (point < 0x800) 2 else if (point < 0x10000) 3 else 4;
        if (count > target.len - written) return error.RequestTooLarge;
        switch (count) {
            1 => target[written] = @intCast(point),
            2 => {
                target[written] = 0xc0 | @as(u8, @intCast(point >> 6));
                target[written + 1] = 0x80 | @as(u8, @intCast(point & 0x3f));
            },
            3 => {
                target[written] = 0xe0 | @as(u8, @intCast(point >> 12));
                target[written + 1] = 0x80 | @as(u8, @intCast((point >> 6) & 0x3f));
                target[written + 2] = 0x80 | @as(u8, @intCast(point & 0x3f));
            },
            else => {
                target[written] = 0xf0 | @as(u8, @intCast(point >> 18));
                target[written + 1] = 0x80 | @as(u8, @intCast((point >> 12) & 0x3f));
                target[written + 2] = 0x80 | @as(u8, @intCast((point >> 6) & 0x3f));
                target[written + 3] = 0x80 | @as(u8, @intCast(point & 0x3f));
            },
        }
        written += count;
    }
    return target[0..written];
}

fn unicodeEqual(source: []const u8, text: []const u8) bool {
    if (source.len != text.len * 2) return false;
    for (text, 0..) |byte, index| if (source[index * 2] != byte or source[index * 2 + 1] != 0) return false;
    return true;
}

fn lower(value: u8) u8 {
    return if (value >= 'A' and value <= 'Z') value + 32 else value;
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}

fn nameByte(value: u8) bool {
    return (value >= 'a' and value <= 'z') or (value >= 'A' and value <= 'Z') or (value >= '0' and value <= '9') or value == '_';
}

fn whitespace(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\r' or value == '\n';
}

const Cursor = struct {
    source: []const u8,
    position: usize = 0,
    fn take(self: *Cursor, count: usize) Error![]const u8 {
        if (count > self.source.len - self.position) return error.MalformedPacket;
        const result = self.source[self.position..][0..count];
        self.position += count;
        return result;
    }
    fn number(self: *Cursor, count: usize) Error!u64 {
        return le(try self.take(count));
    }
};

const Family = enum { integer, boolean, text };
const Parameter = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    family: Family = .integer,
    literal_offset: usize = 0,
    literal_len: usize = 0,
    supplied: bool = false,
};
const RpcValue = union(enum) { null_value: void, integer: i64, boolean: bool, text: []const u8 };

const Writer = struct {
    out: []u8,
    packet_size: usize = 4096,
    pos: usize = 0,
    start: usize = 0,
    packet_id: u8 = 1,

    fn open(self: *Writer) Error!void {
        if (self.out.len - self.pos < 8) return error.BufferTooSmall;
        self.start = self.pos;
        @memset(self.out[self.pos..][0..8], 0);
        self.out[self.pos] = 4; // server reply
        self.out[self.pos + 6] = self.packet_id;
        self.packet_id +%= 1;
        self.pos += 8;
    }

    fn seal(self: *Writer, final: bool) void {
        const count = self.pos - self.start;
        self.out[self.start + 1] = if (final) 1 else 0;
        self.out[self.start + 2] = @intCast(count >> 8);
        self.out[self.start + 3] = @truncate(count);
    }

    fn byte(self: *Writer, value: u8) Error!void {
        if (self.pos - self.start == self.packet_size) {
            self.seal(false);
            try self.open();
        }
        if (self.pos == self.out.len) return error.BufferTooSmall;
        self.out[self.pos] = value;
        self.pos += 1;
    }

    fn bytes(self: *Writer, value: []const u8) Error!void {
        for (value) |item| try self.byte(item);
    }

    fn number(self: *Writer, value: u64, comptime count: usize) Error!void {
        for (0..count) |index| try self.byte(@truncate(value >> @intCast(index * 8)));
    }

    fn big(self: *Writer, value: u32) Error!void {
        for (0..4) |index| try self.byte(@truncate(value >> @intCast((3 - index) * 8)));
    }

    fn unicode(self: *Writer, value: []const u8) Error!void {
        var position: usize = 0;
        while (position < value.len) {
            const point = try utf8Next(value, &position);
            if (point < 0x10000) {
                try self.number(point, 2);
            } else {
                try self.number(0xd800 + ((point - 0x10000) >> 10), 2);
                try self.number(0xdc00 + ((point - 0x10000) & 0x3ff), 2);
            }
        }
    }

    fn doneToken(self: *Writer, token: u8, flags: u16, count: usize) Error!void {
        try self.byte(token);
        try self.number(flags, 2);
        try self.number(0, 2);
        try self.number(count, 8);
    }

    fn done(self: *Writer, flags: u16, count: usize) Error!void {
        return self.doneToken(0xfd, flags, count);
    }

    fn failureToken(self: *Writer, code: u32, message: []const u8, completion: u8) Error!void {
        const units = try utf16Length(message);
        if (units > 32767) return error.UnsupportedValue;
        try self.byte(0xaa);
        try self.number(4 + 1 + 1 + 2 + units * 2 + 1 + 1 + 4, 2);
        try self.number(code, 4);
        try self.byte(1); // state
        try self.byte(16); // user error severity
        try self.number(units, 2);
        try self.unicode(message);
        try self.byte(0); // server
        try self.byte(0); // procedure
        try self.number(1, 4); // line
        try self.doneToken(completion, 2, 0);
    }

    fn failure(self: *Writer, code: u32, message: []const u8) Error!void {
        return self.failureToken(code, message, 0xfd);
    }

    fn transaction(self: *Writer, kind: u8) Error!void {
        try self.byte(0xe3); // ENVCHANGE
        try self.number(11, 2);
        try self.byte(kind);
        if (kind == 8) {
            try self.byte(8);
            try self.number(1, 8);
            try self.byte(0);
        } else {
            try self.byte(0);
            try self.byte(8);
            try self.number(1, 8);
        }
    }
};

pub fn Session(comptime DB: type) type {
    return struct {
        const Self = @This();
        const State = enum { prelogin, login, ready, closed };
        state: State = .prelogin,
        packet_size: usize = 4096,
        version: u32 = 0x74000004,
        message: [max_request_bytes]u8 = undefined,
        message_len: usize = 0,
        message_type: u8 = 0,
        next_packet_id: u8 = 0,
        query: [max_request_bytes]u8 = undefined,
        rpc_values: [max_request_bytes]u8 = undefined,
        rpc_expanded: [max_request_bytes]u8 = undefined,
        rpc_parameters: [max_parameters]Parameter = undefined,
        result: DB.Result = .{},

        pub fn responseCapacity() usize {
            // Includes UTF-16 expansion plus every packet/metadata header. The
            // minimum negotiated packet size is 512, so headers add < 1.6%.
            return @sizeOf(DB.Result) * 3 + 4096;
        }

        pub fn begin(_: *Self, _: []u8) Error!usize {
            return 0;
        }

        fn prelogin(self: *Self, source: []const u8, writer: *Writer) Error!bool {
            var position: usize = 0;
            var encryption: u8 = 2;
            var found_encryption = false;
            var seen: [256]bool = @splat(false);
            while (true) {
                if (position >= source.len) return error.MalformedPacket;
                const token = source[position];
                if (token == 0xff) break;
                if (source.len - position < 5 or seen[token]) return error.MalformedPacket;
                seen[token] = true;
                const offset = be16(source[position + 1 ..][0..2]);
                const len = be16(source[position + 3 ..][0..2]);
                if (offset > source.len or len > source.len - offset) return error.MalformedPacket;
                if (token == 1) {
                    if (len != 1) return error.MalformedPacket;
                    encryption = source[offset];
                    found_encryption = true;
                }
                position += 5;
            }
            // Every option points beyond the complete option table.
            var entry: usize = 0;
            while (entry < position) : (entry += 5) if (be16(source[entry + 1 ..][0..2]) < position + 1) return error.MalformedPacket;
            if (!found_encryption or encryption > 3) return error.MalformedPacket;
            try writer.bytes(&.{ 0, 0, 16, 0, 6, 1, 0, 22, 0, 1, 4, 0, 23, 0, 1, 0xff });
            try writer.bytes(&.{ 16, 0, 0, 0, 0, 0, 2, 0 }); // version, ENCRYPT_NOT_SUP, MARS disabled
            const close = encryption == 1 or encryption == 3;
            self.state = if (close) .closed else .login;
            return close;
        }

        fn loginField(source: []const u8, offset: usize) Error![]const u8 {
            const start: usize = @intCast(le(source[offset..][0..2]));
            const count: usize = @intCast(le(source[offset + 2 ..][0..2]));
            if (count == 0) return source[0..0];
            if (start < 94 or start > source.len or count * 2 > source.len - start) return error.MalformedPacket;
            return source[start..][0 .. count * 2];
        }

        fn login(self: *Self, source: []const u8, writer: *Writer) Error!bool {
            if (source.len < 94 or le(source[0..4]) != source.len) return error.MalformedPacket;
            const version: u32 = @intCast(le(source[4..8]));
            switch (version) {
                0x72090002, 0x730a0003, 0x730b0003, 0x74000004 => {},
                else => {
                    try writer.failure(18456, "RAMSQL supports TDS 7.2 through 7.4");
                    return true;
                },
            }
            // Bound every variable-length field before accessing any contents.
            inline for (.{ 36, 40, 44, 48, 52, 60, 64, 68, 82, 86 }) |offset| _ = try loginField(source, offset);
            if (source[25] & 0x80 != 0 or source[27] & 0x11 != 0 or le(source[80..82]) != 0 or le(source[90..94]) != 0 or
                (try loginField(source, 44)).len != 0 or (try loginField(source, 86)).len != 0)
            {
                try writer.failure(18456, "RAMSQL local trust requires empty password; integrated and federated authentication are unavailable");
                return true;
            }
            if ((try loginField(source, 82)).len != 0) {
                try writer.failure(18456, "Attaching databases is unavailable");
                return true;
            }
            const database = try loginField(source, 68);
            if (database.len != 0 and !unicodeEqual(database, "ramsql")) {
                try writer.failure(4060, "Unknown database; use ramsql");
                return true;
            }
            const requested: usize = @intCast(le(source[8..12]));
            if (requested < 512 or requested > 32767) {
                try writer.failure(18456, "Packet size must be between 512 and 32767 bytes");
                return true;
            }
            self.version = version;
            self.packet_size = requested;
            // Keep this login response within the original 4096-byte packet.
            try writer.byte(0xad);
            try writer.number(22, 2); // fixed 10 + 6 UTF-16 product characters
            try writer.byte(1);
            try writer.big(version);
            try writer.byte(6);
            try writer.unicode("RAMSQL");
            try writer.bytes(&.{ 16, 0, 0, 0 });
            // Database ENVCHANGE, with both lengths in Unicode characters.
            try writer.byte(0xe3);
            try writer.number(15, 2);
            try writer.byte(1);
            try writer.byte(6);
            try writer.unicode("ramsql");
            try writer.byte(0);
            try writer.done(0, 0);
            self.state = .ready;
            return false;
        }

        fn allHeaders(source: []const u8) Error![]const u8 {
            if (source.len < 4) return error.MalformedPacket;
            const total: usize = @intCast(le(source[0..4]));
            if (total < 4 or total > source.len) return error.MalformedPacket;
            var position: usize = 4;
            var transaction = false;
            var seen: [4]bool = @splat(false);
            while (position < total) {
                if (total - position < 6) return error.MalformedPacket;
                const length: usize = @intCast(le(source[position..][0..4]));
                const kind: usize = @intCast(le(source[position + 4 ..][0..2]));
                if (length < 6 or length > total - position or kind == 0 or kind >= seen.len or seen[kind]) return error.MalformedPacket;
                seen[kind] = true;
                if (kind == 2) {
                    if (length != 18) return error.MalformedPacket;
                    transaction = true;
                }
                position += length;
            }
            if (!transaction) return error.MalformedPacket;
            return source[total..];
        }

        fn txStatus(db: *DB) u8 {
            return if (@hasDecl(DB, "transactionStatus")) db.transactionStatus() else 'I';
        }

        fn notifyTransaction(writer: *Writer, before: u8, after: u8, rollback: bool) Error!void {
            if (before == 'I' and after != 'I') try writer.transaction(8) else if (before != 'I' and after == 'I') try writer.transaction(if (rollback) 10 else 9);
        }

        fn isRollback(source: []const u8) bool {
            var position: usize = 0;
            while (position < source.len and (source[position] == ' ' or source[position] == '\t' or source[position] == '\r' or source[position] == '\n')) position += 1;
            const word = "rollback";
            if (source.len - position < word.len) return false;
            for (word, 0..) |byte, index| {
                const actual = source[position + index];
                if (actual != byte and actual != byte - 32) return false;
            }
            return true;
        }


        /// New types (NUMERIC, REAL/DOUBLE, temporal, JSON) travel as TEXT
        /// columns here: native metadata is not implemented (flag F-M).
        fn textify(db: *DB, result: *DB.Result) anyerror!void {
            if (!@hasDecl(DB.Result, "textify")) return;
            const session = if (@hasDecl(DB, "valueSession")) db.valueSession() else DB.Result.default_session;
            try result.textify(session);
        }

        fn results(self: *Self, writer: *Writer, completion: u8) Error!void {
            // Validate all text before writing COLMETADATA, so encoding errors
            // produce a complete ERROR/DONE response instead of partial rows.
            for (0..self.result.column_count) |column| {
                if (try utf16Length(self.result.column_names[column].slice()) > 255) return error.UnsupportedValue;
            }
            for (self.result.rows[0..self.result.row_count]) |*row| for (row.cells[0..self.result.column_count]) |*cell| switch (cell.*) {
                .text => |*value| if (try utf16Length(value.slice()) > 32767) return error.UnsupportedValue,
                else => {},
            };
            if (self.result.column_count != 0) {
                try writer.byte(0x81);
                try writer.number(self.result.column_count, 2);
                for (0..self.result.column_count) |column| {
                    try writer.number(0, 4); // usertype (TDS 7.2+)
                    try writer.number(1, 2); // nullable
                    switch (self.result.column_types[column]) {
                        .integer => {
                            try writer.byte(0x26);
                            try writer.byte(8);
                        }, // INTN/BIGINT
                        .integer32 => {
                            try writer.byte(0x26);
                            try writer.byte(4);
                        }, // INTN/INT
                        .boolean => {
                            try writer.byte(0x68);
                            try writer.byte(1);
                        }, // BITN
                        else => {
                            try writer.byte(0xe7); // NVARCHAR
                            try writer.number(65534, 2);
                            try writer.bytes(&.{ 9, 4, 0xd0, 0, 0x34 }); // SQL_Latin1_General_CP1_CI_AS
                        },
                    }
                    const name = self.result.column_names[column].slice();
                    try writer.byte(@intCast(try utf16Length(name)));
                    try writer.unicode(name);
                }
                for (self.result.rows[0..self.result.row_count]) |*row| {
                    try writer.byte(0xd1);
                    for (row.cells[0..self.result.column_count], 0..) |*cell, column| switch (cell.*) {
                        .null_value => switch (self.result.column_types[column]) {
                            .integer, .integer32, .boolean => try writer.byte(0),
                            else => try writer.number(0xffff, 2),
                        },
                        .integer => |value| {
                            if (self.result.column_types[column] == .integer32) {
                                try writer.byte(4);
                                try writer.number(@bitCast(value), 4);
                            } else {
                                try writer.byte(8);
                                try writer.number(@bitCast(value), 8);
                            }
                        },
                        .boolean => |value| {
                            try writer.byte(1);
                            try writer.byte(if (value) 1 else 0);
                        },
                        .text => |*value| {
                            try writer.number((try utf16Length(value.slice())) * 2, 2);
                            try writer.unicode(value.slice());
                        },
                        // textify() rendered every other type as text.
                        else => unreachable,
                    };
                }
            }
            try writer.doneToken(completion, 0x10 | (if (completion == 0xff) @as(u16, 1) else 0), if (self.result.column_count == 0) self.result.affected_rows else self.result.row_count);
        }

        fn batch(self: *Self, db: *DB, source: []const u8, writer: *Writer) Error!void {
            const text = try allHeaders(source);
            const query = fromUtf16(text, &self.query) catch |err| {
                return writer.failure(102, @errorName(err));
            };
            if (query.len == 0) return writer.done(0, 0);
            const before = txStatus(db);
            if (db.execute(query, &self.result)) |_| {
                try notifyTransaction(writer, before, txStatus(db), isRollback(query));
                textify(db, &self.result) catch |err| return writer.failure(245, @errorName(err));
                self.results(writer, 0xfd) catch |err| {
                    if (err == error.BufferTooSmall) return err;
                    try writer.failure(245, @errorName(err));
                };
            } else |err| if (blockedError(err)) return error.WouldBlock else try writer.failure(switch (err) {
                error.TableNotFound => 208,
                error.ColumnNotFound => 207,
                error.PrimaryKeyViolation => 2627,
                error.NotNullViolation => 515,
                error.DatabaseBusy => 1222,
                else => 102,
            }, @errorName(err));
        }

        /// Decode a bounded native RPC parameter. NVARCHAR(max) PLP chunks are
        /// reassembled into caller-owned session scratch before UTF-16 decode;
        /// a chunk boundary is allowed in the middle of a surrogate pair.
        fn rpcValue(self: *Self, cursor: *Cursor) Error!RpcValue {
            const kind = try cursor.number(1);
            switch (kind) {
                0x1f => return .null_value,
                0x26, 0x30, 0x34, 0x38, 0x7f => {
                    const size: usize = if (kind == 0x26) @intCast(try cursor.number(1)) else switch (kind) {
                        0x30 => 1,
                        0x34 => 2,
                        0x38 => 4,
                        else => 8,
                    };
                    if (size != 1 and size != 2 and size != 4 and size != 8) return error.MalformedPacket;
                    if (kind == 0x26) {
                        const count = try cursor.number(1);
                        if (count == 0) return .null_value;
                        if (count != size) return error.MalformedPacket;
                    }
                    const raw = try cursor.number(size);
                    const signed: i64 = switch (size) {
                        1 => @intCast(raw), // SQL TINYINT is unsigned
                        2 => @as(i16, @bitCast(@as(u16, @intCast(raw)))),
                        4 => @as(i32, @bitCast(@as(u32, @intCast(raw)))),
                        else => @bitCast(raw),
                    };
                    return .{ .integer = signed };
                },
                0x68, 0x32 => {
                    if (kind == 0x68) {
                        if (try cursor.number(1) != 1) return error.MalformedPacket;
                        const count = try cursor.number(1);
                        if (count == 0) return .null_value;
                        if (count != 1) return error.MalformedPacket;
                    }
                    const value = try cursor.number(1);
                    if (value > 1) return error.MalformedPacket;
                    return .{ .boolean = value == 1 };
                },
                0xe7, 0xef => {
                    const maximum = try cursor.number(2);
                    _ = try cursor.take(5); // collation; NVARCHAR always UTF-16
                    if (maximum != 0xffff) {
                        if (maximum > 8000 or maximum % 2 != 0) return error.MalformedPacket;
                        const count: usize = @intCast(try cursor.number(2));
                        if (count == 0xffff) return .null_value;
                        if (count > maximum or count % 2 != 0) return error.MalformedPacket;
                        return .{ .text = try cursor.take(count) };
                    }
                    if (kind != 0xe7) return error.MalformedPacket;
                    const total = try cursor.number(8);
                    if (total == 0xffffffffffffffff) return .null_value;
                    if (total != 0xfffffffffffffffe and total > max_request_bytes) return error.RequestTooLarge;
                    var written: usize = 0;
                    while (true) {
                        const count: usize = @intCast(try cursor.number(4));
                        if (count == 0) break;
                        if (count > self.rpc_expanded.len - written) return error.RequestTooLarge;
                        @memcpy(self.rpc_expanded[written..][0..count], try cursor.take(count));
                        written += count;
                    }
                    if ((total != 0xfffffffffffffffe and total != written) or written % 2 != 0) return error.MalformedPacket;
                    return .{ .text = self.rpc_expanded[0..written] };
                },
                else => return error.UnsupportedRpc,
            }
        }

        fn declarations(self: *Self, source: []const u8) Error!usize {
            var count: usize = 0;
            var position: usize = 0;
            while (position < source.len) {
                while (position < source.len and whitespace(source[position])) position += 1;
                if (position == source.len) break;
                if (count == self.rpc_parameters.len or source[position] != '@') return error.UnsupportedRpc;
                const start = position;
                position += 1;
                while (position < source.len and nameByte(source[position])) position += 1;
                if (position == start + 1 or position - start > 128 or position == source.len or !whitespace(source[position])) return error.MalformedPacket;
                const name = source[start..position];
                for (self.rpc_parameters[0..count]) |*previous| if (equal(name, previous.name[0..previous.name_len])) return error.MalformedPacket;
                var parameter: Parameter = .{};
                @memcpy(parameter.name[0..name.len], name);
                parameter.name_len = name.len;
                while (position < source.len and whitespace(source[position])) position += 1;
                const type_start = position;
                while (position < source.len and nameByte(source[position])) position += 1;
                const type_name = source[type_start..position];
                if (equal(type_name, "int") or equal(type_name, "integer") or equal(type_name, "bigint") or equal(type_name, "smallint") or equal(type_name, "tinyint")) {
                    parameter.family = .integer;
                } else if (equal(type_name, "bit") or equal(type_name, "boolean")) {
                    parameter.family = .boolean;
                } else if (equal(type_name, "nvarchar") or equal(type_name, "nchar")) {
                    parameter.family = .text;
                    while (position < source.len and whitespace(source[position])) position += 1;
                    if (position == source.len or source[position] != '(') return error.MalformedPacket;
                    position += 1;
                    while (position < source.len and whitespace(source[position])) position += 1;
                    const length_start = position;
                    while (position < source.len and nameByte(source[position])) position += 1;
                    const length = source[length_start..position];
                    if (!equal(length, "max")) {
                        if (length.len == 0) return error.MalformedPacket;
                        var units: usize = 0;
                        for (length) |byte| {
                            if (byte < '0' or byte > '9' or units > 4000) return error.MalformedPacket;
                            units = units * 10 + byte - '0';
                        }
                        if (units == 0 or units > 4000) return error.UnsupportedRpc;
                    }
                    while (position < source.len and whitespace(source[position])) position += 1;
                    if (position == source.len or source[position] != ')') return error.MalformedPacket;
                    position += 1;
                } else return error.UnsupportedRpc;
                self.rpc_parameters[count] = parameter;
                count += 1;
                while (position < source.len and whitespace(source[position])) position += 1;
                if (position == source.len) break;
                if (source[position] != ',') return error.UnsupportedRpc;
                position += 1;
                if (position == source.len) return error.MalformedPacket;
            }
            return count;
        }

        fn append(target: []u8, position: *usize, text: []const u8) Error!void {
            if (text.len > target.len - position.*) return error.RequestTooLarge;
            @memcpy(target[position.*..][0..text.len], text);
            position.* += text.len;
        }

        fn literal(self: *Self, value: RpcValue, parameter: *Parameter, position: *usize) Error!void {
            parameter.literal_offset = position.*;
            switch (value) {
                .null_value => try append(&self.rpc_values, position, "NULL"),
                .boolean => |flag| {
                    if (parameter.family != .boolean) return error.UnsupportedRpc;
                    try append(&self.rpc_values, position, if (flag) "TRUE" else "FALSE");
                },
                .integer => |integer| {
                    if (parameter.family != .integer) return error.UnsupportedRpc;
                    var scratch: [21]u8 = undefined;
                    var start = scratch.len;
                    var magnitude: u64 = if (integer < 0) @as(u64, @intCast(-(integer + 1))) + 1 else @intCast(integer);
                    while (true) {
                        start -= 1;
                        scratch[start] = '0' + @as(u8, @intCast(magnitude % 10));
                        magnitude /= 10;
                        if (magnitude == 0) break;
                    }
                    if (integer < 0) {
                        start -= 1;
                        scratch[start] = '-';
                    }
                    try append(&self.rpc_values, position, scratch[start..]);
                },
                .text => |utf16| {
                    if (parameter.family != .text or position.* == self.rpc_values.len) return error.UnsupportedRpc;
                    const start = position.*;
                    const decoded = try fromUtf16(utf16, self.rpc_values[start + 1 ..]);
                    var quotes: usize = 0;
                    for (decoded) |byte| if (byte == '\'') {
                        quotes += 1;
                    };
                    if (decoded.len + quotes + 2 > self.rpc_values.len - start) return error.RequestTooLarge;
                    var source = start + 1 + decoded.len;
                    var destination = source + quotes;
                    self.rpc_values[destination] = '\'';
                    while (source > start + 1) {
                        source -= 1;
                        const byte = self.rpc_values[source];
                        destination -= 1;
                        self.rpc_values[destination] = byte;
                        if (byte == '\'') {
                            destination -= 1;
                            self.rpc_values[destination] = byte;
                        }
                    }
                    self.rpc_values[start] = '\'';
                    position.* = start + decoded.len + quotes + 2;
                },
            }
            parameter.literal_len = position.* - parameter.literal_offset;
            parameter.supplied = true;
        }

        fn expand(self: *Self, source: []const u8, count: usize) Error![]const u8 {
            var position: usize = 0;
            var written: usize = 0;
            while (position < source.len) {
                const start = position;
                if (source[position] == '\'' or source[position] == '"' or source[position] == '[') {
                    const quote = if (source[position] == '[') @as(u8, ']') else source[position];
                    position += 1;
                    var closed = false;
                    while (position < source.len) {
                        const byte = source[position];
                        position += 1;
                        if (byte == quote) {
                            if (position < source.len and source[position] == quote) {
                                position += 1;
                                continue;
                            }
                            closed = true;
                            break;
                        }
                    }
                    if (!closed) return error.MalformedPacket;
                    try append(&self.rpc_expanded, &written, source[start..position]);
                } else if (source[position] == '-' and position + 1 < source.len and source[position + 1] == '-') {
                    while (position < source.len and source[position] != '\n') position += 1;
                    try append(&self.rpc_expanded, &written, source[start..position]);
                } else if (source[position] == '/' and position + 1 < source.len and source[position + 1] == '*') {
                    position += 2;
                    var depth: usize = 1;
                    while (position + 1 < source.len and depth != 0) {
                        if (source[position] == '/' and source[position + 1] == '*') {
                            depth += 1;
                            position += 2;
                        } else if (source[position] == '*' and source[position + 1] == '/') {
                            depth -= 1;
                            position += 2;
                        } else position += 1;
                    }
                    if (depth != 0) return error.MalformedPacket;
                    try append(&self.rpc_expanded, &written, source[start..position]);
                } else if (source[position] == '@') {
                    if (position != 0 and nameByte(source[position - 1])) return error.MalformedPacket;
                    position += 1;
                    while (position < source.len and nameByte(source[position])) position += 1;
                    const name = source[start..position];
                    var found = false;
                    for (self.rpc_parameters[0..count]) |*parameter| {
                        if (equal(name, parameter.name[0..parameter.name_len])) {
                            try append(&self.rpc_expanded, &written, self.rpc_values[parameter.literal_offset..][0..parameter.literal_len]);
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.UnsupportedRpc;
                } else {
                    position += 1;
                    try append(&self.rpc_expanded, &written, source[start..position]);
                }
            }
            return self.rpc_expanded[0..written];
        }

        fn parseRpc(self: *Self, source: []const u8) Error![]const u8 {
            var cursor: Cursor = .{ .source = try allHeaders(source) };
            const procedure = try cursor.number(2);
            if (procedure == 0xffff) {
                if (try cursor.number(2) != 10) return error.UnsupportedRpc;
            } else {
                if (procedure > 128 or !unicodeEqual(try cursor.take(@intCast(procedure * 2)), "sp_executesql")) return error.UnsupportedRpc;
            }
            if (try cursor.number(2) != 0) return error.UnsupportedRpc; // metadata/recompile flags
            var count: usize = 0;
            var query_len: usize = 0;
            var values_len: usize = 0;
            var supplied: usize = 0;
            var ordinal: usize = 0;
            while (cursor.position < cursor.source.len) : (ordinal += 1) {
                const name_units = try cursor.number(1);
                if (name_units > 128) return error.UnsupportedRpc;
                var name_buffer: [128]u8 = undefined;
                const name = try fromUtf16(try cursor.take(@intCast(name_units * 2)), &name_buffer);
                if (try cursor.number(1) != 0) return error.UnsupportedRpc; // output/default/encrypted parameters
                const value = try self.rpcValue(&cursor);
                if (ordinal == 0) {
                    if (name.len != 0 and !equal(name, "@stmt")) return error.UnsupportedRpc;
                    switch (value) {
                        .text => |text| query_len = (try fromUtf16(text, &self.query)).len,
                        else => return error.UnsupportedRpc,
                    }
                } else if (ordinal == 1) {
                    if (name.len != 0 and !equal(name, "@params")) return error.UnsupportedRpc;
                    switch (value) {
                        .text => |text| count = try self.declarations(try fromUtf16(text, &self.rpc_values)),
                        .null_value => count = 0,
                        else => return error.UnsupportedRpc,
                    }
                } else {
                    if (supplied == count) return error.UnsupportedRpc;
                    var matched: ?usize = null;
                    if (name.len == 0) matched = supplied else for (self.rpc_parameters[0..count], 0..) |*parameter, index| {
                        if (equal(name, parameter.name[0..parameter.name_len])) {
                            matched = index;
                            break;
                        }
                    }
                    const index = matched orelse return error.UnsupportedRpc;
                    if (self.rpc_parameters[index].supplied) return error.MalformedPacket;
                    try self.literal(value, &self.rpc_parameters[index], &values_len);
                    supplied += 1;
                }
            }
            if (ordinal == 0 or supplied != count) return error.MalformedPacket;
            return self.expand(self.query[0..query_len], count);
        }

        fn rpc(self: *Self, db: *DB, source: []const u8, writer: *Writer) Error!void {
            const query = self.parseRpc(source) catch |err| return writer.failureToken(2812, @errorName(err), 0xfe);
            const before = txStatus(db);
            if (db.execute(query, &self.result)) |_| {
                try notifyTransaction(writer, before, txStatus(db), isRollback(query));
                textify(db, &self.result) catch |err| return writer.failureToken(245, @errorName(err), 0xfe);
                self.results(writer, 0xff) catch |err| return writer.failureToken(245, @errorName(err), 0xfe);
                try writer.byte(0x79); // RETURNSTATUS
                try writer.number(0, 4);
                try writer.doneToken(0xfe, 0, 0); // DONEPROC
            } else |err| if (blockedError(err)) return error.WouldBlock else try writer.failureToken(switch (err) {
                error.TableNotFound => 208,
                error.ColumnNotFound => 207,
                error.PrimaryKeyViolation => 2627,
                error.NotNullViolation => 515,
                error.DatabaseBusy => 1222,
                else => 102,
            }, @errorName(err), 0xfe);
        }

        fn blockedError(err: anytype) bool {
            const any: anyerror = err;
            return any == error.WouldBlock;
        }

        fn transactionRequest(db: *DB, source: []const u8, writer: *Writer) Error!void {
            const payload = try allHeaders(source);
            if (payload.len < 4) return error.MalformedPacket;
            const operation = le(payload[0..2]);
            if (!@hasDecl(DB, "beginTransaction")) return writer.failure(40510, "Transactions are unavailable for this database adapter");
            if (operation == 5) {
                const name_bytes: usize = @as(usize, payload[3]) * 2;
                if (payload.len != 4 + name_bytes or payload[2] > 4) return error.MalformedPacket;
                if (db.beginTransaction()) |_| {
                    try writer.transaction(8);
                    try writer.done(0, 0);
                } else |err| try writer.failure(1222, @errorName(err));
            } else if (operation == 7 or operation == 8) {
                const name_bytes: usize = @as(usize, payload[2]) * 2;
                if (name_bytes > payload.len - 4) return error.MalformedPacket;
                const flags = payload[3 + name_bytes];
                const continuation = flags & 1 != 0;
                if (flags & 0xfe != 0 or payload.len != 4 + name_bytes + (if (continuation) @as(usize, 2) else 0)) return error.MalformedPacket;
                if (continuation and (payload[4 + name_bytes] > 4 or payload[5 + name_bytes] != 0)) return error.MalformedPacket;
                const before = txStatus(db);
                const outcome = if (operation == 7) db.commitTransaction() else db.rollbackTransaction();
                if (outcome) |_| {
                    if (before != 'I') try writer.transaction(if (operation == 7) 9 else 10);
                    if (continuation) {
                        if (db.beginTransaction()) |_| {
                            try writer.transaction(8);
                        } else |err| return writer.failure(1222, @errorName(err));
                    }
                    try writer.done(0, 0);
                } else |err| try writer.failure(1222, @errorName(err));
            } else try writer.failure(40510, "Unsupported TDS transaction manager operation");
        }

        pub fn handle(self: *Self, db: *DB, input: []const u8, out: []u8) Error!Reply {
            // TDS BIT parameters arrive as integer 0/1 (design §4.2).
            if (@hasField(DB, "dialect")) db.dialect = .tds;
            if (self.state == .closed) return error.InvalidState;
            if (input.len < 8) return .{};
            const packet_length = be16(input[2..4]);
            if (packet_length < 8 or input[7] != 0 or input[1] & 0xfe != 0) return error.MalformedPacket;
            if (input.len < packet_length) return .{};
            if (out.len < responseCapacity()) return error.BufferTooSmall;
            const payload = input[8..packet_length];
            if (payload.len > self.message.len - self.message_len) return error.RequestTooLarge;
            if (self.message_len != 0 and (input[0] != self.message_type or input[6] != self.next_packet_id)) return error.InvalidSequence;
            const final = input[1] & 1 != 0;
            if (!final and payload.len == 0) return error.MalformedPacket;
            const saved_len = self.message_len;
            const saved_id = self.next_packet_id;
            if (!final or self.message_len != 0) {
                if (self.message_len == 0) self.message_type = input[0];
                @memcpy(self.message[self.message_len..][0..payload.len], payload);
                self.message_len += payload.len;
                self.next_packet_id = input[6] +% 1;
                if (!final) return .{ .consumed = packet_length };
            }
            const source = if (self.message_len == 0) payload else self.message[0..self.message_len];
            var keep_message = false;
            defer {
                if (!keep_message) self.message_len = 0;
            }
            var writer: Writer = .{ .out = out, .packet_size = self.packet_size };
            try writer.open();
            var reply: Reply = .{ .consumed = packet_length };
            const outcome: Error!void = switch (self.state) {
                .prelogin => blk: {
                    if (input[0] != 0x12) return error.InvalidState;
                    reply.close = try self.prelogin(source, &writer);
                    break :blk {};
                },
                .login => blk: {
                    if (input[0] != 0x10) return error.InvalidState;
                    reply.close = try self.login(source, &writer);
                    break :blk {};
                },
                .ready => switch (input[0]) {
                    1 => self.batch(db, source, &writer),
                    3 => self.rpc(db, source, &writer),
                    6 => writer.done(0x20, 0), // ATTENTION acknowledgement
                    0x0e => transactionRequest(db, source, &writer),
                    else => writer.failure(40510, "Unsupported TDS packet type"),
                },
                .closed => return error.InvalidState,
            };
            outcome catch |err| {
                if (err != error.WouldBlock) return err;
                // Parked: the final packet is re-delivered, so drop it from
                // the reassembly buffer and keep the earlier packets.
                keep_message = saved_len != 0;
                self.message_len = saved_len;
                self.next_packet_id = saved_id;
                return .{ .blocked = true };
            };
            writer.seal(true);
            reply.written = writer.pos;
            if (reply.close) self.state = .closed;
            return reply;
        }
    };
}
