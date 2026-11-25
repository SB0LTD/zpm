//! Shared requests for SQL and libpq large-object operations.
const storage = @import("storage.sig");
const types = @import("types.sig");

pub const inv_write: u32 = 0x20000;
pub const inv_read: u32 = 0x40000;

pub const Input = union(enum) {
    raw: []const u8,
    hex: []const u8,

    pub fn length(self: Input) types.Error!usize {
        return switch (self) {
            .raw => |data| data.len,
            .hex => |data| blk: {
                if (data.len % 2 != 0) return error.InvalidTextRepresentation;
                for (data) |byte| _ = try nibble(byte);
                break :blk data.len / 2;
            },
        };
    }

    fn nibble(byte: u8) types.Error!u8 {
        return switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => error.InvalidTextRepresentation,
        };
    }

    pub fn chunk(self: Input, offset: usize, scratch: []u8) []const u8 {
        return switch (self) {
            .raw => |data| data[offset..][0..scratch.len],
            .hex => |data| blk: {
                for (scratch, 0..) |*byte, index| {
                    const at = (offset + index) * 2;
                    byte.* = ((nibble(data[at]) catch unreachable) << 4) | (nibble(data[at + 1]) catch unreachable);
                }
                break :blk scratch;
            },
        };
    }
};

pub const Request = union(enum) {
    create: u32,
    unlink: u32,
    open: struct { oid: u32, mode: u32 },
    close: i32,
    read: struct { fd: i32, count: i32 },
    write: struct { fd: i32, bytes: Input },
    seek: struct { fd: i32, offset: i64, whence: i32, wide: bool },
    tell: struct { fd: i32, wide: bool },
    from_bytes: struct { oid: u32, bytes: Input },
    get: struct { oid: u32, offset: i64 = 0, count: ?i32 = null },
    put: struct { oid: u32, offset: i64, bytes: Input },

    pub fn writes(self: Request) bool {
        return switch (self) {
            .create, .unlink, .write, .from_bytes, .put => true,
            else => false,
        };
    }
};

pub const Response = union(enum) {
    oid: u32,
    int4: i32,
    int8: i64,
    bytes: usize,
    empty,
};

pub const Function = enum(u32) {
    lo_create = 715,
    lo_open = 952,
    lo_close = 953,
    loread = 954,
    lowrite = 955,
    lo_lseek = 956,
    lo_creat = 957,
    lo_tell = 958,
    lo_unlink = 964,
    lo_lseek64 = 3170,
    lo_tell64 = 3171,
    lo_from_bytea = 3457,
    lo_get = 3458,
    lo_get_fragment = 3459,
    lo_put = 3460,

    pub fn fromOid(oid: u32) ?Function {
        inline for (@typeInfo(Function).@"enum".field_names) |field| {
            const op = @field(Function, field);
            if (@intFromEnum(op) == oid) return op;
        }
        return null;
    }

    pub fn name(self: Function) []const u8 {
        return if (self == .lo_get_fragment) "lo_get" else @tagName(self);
    }

    pub fn argumentTypes(self: Function) []const u32 {
        return switch (self) {
            .lo_create, .lo_unlink, .lo_get => &.{26},
            .lo_open => &.{ 26, 23 },
            .lo_close, .lo_creat, .lo_tell, .lo_tell64 => &.{23},
            .loread => &.{ 23, 23 },
            .lowrite => &.{ 23, 17 },
            .lo_lseek => &.{ 23, 23, 23 },
            .lo_lseek64 => &.{ 23, 20, 23 },
            .lo_from_bytea => &.{ 26, 17 },
            .lo_get_fragment => &.{ 26, 20, 23 },
            .lo_put => &.{ 26, 20, 17 },
        };
    }

    pub fn resultType(self: Function) u32 {
        return switch (self) {
            .lo_create, .lo_creat, .lo_from_bytea => 26,
            .loread, .lo_get, .lo_get_fragment => 17,
            .lo_lseek64, .lo_tell64 => 20,
            .lo_put => 2278,
            else => 23,
        };
    }

    /// Arguments have been validated against argumentTypes and are non-null.
    pub fn request(self: Function, args: []const Argument) Request {
        return switch (self) {
            .lo_create => .{ .create = @intCast(args[0].number) },
            .lo_creat => .{ .create = 0 },
            .lo_unlink => .{ .unlink = @intCast(args[0].number) },
            .lo_open => .{ .open = .{ .oid = @intCast(args[0].number), .mode = @bitCast(@as(i32, @intCast(args[1].number))) } },
            .lo_close => .{ .close = @intCast(args[0].number) },
            .loread => .{ .read = .{ .fd = @intCast(args[0].number), .count = @intCast(args[1].number) } },
            .lowrite => .{ .write = .{ .fd = @intCast(args[0].number), .bytes = args[1].bytes } },
            .lo_lseek, .lo_lseek64 => .{ .seek = .{ .fd = @intCast(args[0].number), .offset = args[1].number, .whence = @intCast(args[2].number), .wide = self == .lo_lseek64 } },
            .lo_tell, .lo_tell64 => .{ .tell = .{ .fd = @intCast(args[0].number), .wide = self == .lo_tell64 } },
            .lo_from_bytea => .{ .from_bytes = .{ .oid = @intCast(args[0].number), .bytes = args[1].bytes } },
            .lo_get => .{ .get = .{ .oid = @intCast(args[0].number) } },
            .lo_get_fragment => .{ .get = .{ .oid = @intCast(args[0].number), .offset = args[1].number, .count = @intCast(args[2].number) } },
            .lo_put => .{ .put = .{ .oid = @intCast(args[0].number), .offset = args[1].number, .bytes = args[2].bytes } },
        };
    }
};

pub const Argument = union(enum) { null_value, number: i64, bytes: Input };

pub const SqlCall = struct {
    function: Function,
    request: ?Request,
};

fn tokenName(token: @import("lexer.sig").Token, source: []const u8, name: []const u8) bool {
    return switch (token.kind) {
        .word => types.keyword(token.raw(source), name),
        .quoted_word => token.form == .standard and types.same(token.raw(source), name),
        else => false,
    };
}

pub fn argumentNumber(oid: u32, data: []const u8) types.Error!i64 {
    const std = @import("std");
    return switch (oid) {
        26 => std.fmt.parseInt(u32, data, 10) catch error.InvalidTextRepresentation,
        23 => std.fmt.parseInt(i32, data, 10) catch error.InvalidTextRepresentation,
        20 => std.fmt.parseInt(i64, data, 10) catch error.InvalidTextRepresentation,
        else => error.TypeMismatch,
    };
}

/// Recognize a single built-in SELECT call whose arguments are literal
/// values. Other SELECT shapes continue to the general SQL binder.
pub fn parseSql(source: []const u8) types.Error!?SqlCall {
    const lexer = @import("lexer.sig");
    var tokens: lexer.Tokenizer = .{ .source = source, .text_limit = source.len };
    if (!tokenName(try tokens.next(), source, "select")) return null;
    var word = try tokens.next();
    var token = try tokens.next();
    if (token.symbol == .dot) {
        if (!tokenName(word, source, "pg_catalog")) return null;
        word = try tokens.next();
        token = try tokens.next();
    }
    if (token.symbol != .lparen) return null;
    var selected: ?Function = null;
    inline for (@typeInfo(Function).@"enum".field_names) |field| {
        const op = @field(Function, field);
        if (op != .lo_get_fragment and tokenName(word, source, op.name())) selected = op;
    }
    var function = selected orelse return null;
    var arguments: [3]Argument = undefined;
    var null_argument = false;
    var count: usize = 0;
    token = try tokens.next();
    while (token.symbol != .rparen) {
        if (function == .lo_get and count == 1) function = .lo_get_fragment;
        const expected = function.argumentTypes();
        if (count >= expected.len) return null;
        const oid = expected[count];
        const start = token.start;
        if (tokenName(token, source, "null")) {
            arguments[count] = .null_value;
            null_argument = true;
            token = try tokens.next();
        } else if (oid == 17) {
            if (token.kind != .string) return null;
            const raw = token.raw(source);
            const std = @import("std");
            const prefix: usize = if (token.form == .standard and std.mem.startsWith(u8, raw, &.{ '\\', 'x' })) 2
                else if (token.form == .escape and std.mem.startsWith(u8, raw, &.{ '\\', '\\', 'x' })) 3 else 0;
            arguments[count] = if (prefix != 0) .{ .bytes = .{ .hex = raw[prefix..] } }
                else if (token.form == .standard and raw.len == token.len and std.mem.indexOfScalar(u8, raw, '\\') == null)
                    .{ .bytes = .{ .raw = raw } }
                else return null;
            token = try tokens.next();
        } else {
            switch (token.kind) {
                .string => {
                    if (token.form != .standard) return null;
                    arguments[count] = .{ .number = try argumentNumber(oid, token.raw(source)) };
                },
                .integer => arguments[count] = .{ .number = try argumentNumber(oid, token.raw(source)) },
                .symbol => {
                    if (token.symbol != .minus or oid == 26) return null;
                    token = try tokens.next();
                    if (token.kind != .integer or token.start != start + 1) return null;
                    arguments[count] = .{ .number = try argumentNumber(oid, source[start..token.end]) };
                },
                else => return null,
            }
            token = try tokens.next();
        }
        while (token.symbol == .cast) {
            const cast = try tokens.next();
            const small = tokenName(cast, source, "int2") or tokenName(cast, source, "smallint");
            const regular = tokenName(cast, source, "int4") or tokenName(cast, source, "integer") or tokenName(cast, source, "int");
            const wide = tokenName(cast, source, "int8") or tokenName(cast, source, "bigint");
            const matches_cast = switch (oid) {
                17 => tokenName(cast, source, "bytea"),
                20 => small or regular or wide,
                23 => small or regular,
                26 => small or regular or wide or tokenName(cast, source, "oid"),
                else => false,
            };
            if (!matches_cast) return null;
            if (arguments[count] == .number) {
                const number = arguments[count].number;
                if ((small and (number < -32768 or number > 32767)) or (regular and (number < -2147483648 or number > 2147483647)))
                    return error.NumericValueOutOfRange;
            }
            token = try tokens.next();
        }
        count += 1;
        if (token.symbol == .rparen) break;
        if (token.symbol != .comma) return null;
        token = try tokens.next();
        if (token.symbol == .rparen) return null;
    }
    if (count != function.argumentTypes().len) return null;
    token = try tokens.next();
    if (token.symbol == .semicolon) token = try tokens.next();
    if (token.kind != .end) return null;
    return .{ .function = function, .request = if (null_argument) null else function.request(arguments[0..count]) };
}

pub const Descriptor = struct {
    oid: u32 = 0,
    offset: u64 = 0,
    snapshot: ?storage.Snapshot = null,
    depth: usize = 0,
    opened_cid: u32 = 0,
};

/// Entries are owned by one transaction. Read-only opens pin their statement
/// snapshot. The cached minimum keeps reclamation independent of handle count.
pub const Descriptors = struct {
    const Self = @This();
    pub const capacity = 64;
    entries: [capacity]Descriptor = @splat(.{}),
    min_csn: ?u64 = null,
    used: bool = false,

    fn refresh(self: *Self) void {
        self.min_csn = null;
        for (&self.entries) |*item| {
            if (item.oid == 0) continue;
            if (item.snapshot) |snap| self.min_csn = @min(self.min_csn orelse snap.csn, snap.csn);
        }
    }

    pub fn open(self: *Self, descriptor: Descriptor) types.Error!i32 {
        for (&self.entries, 0..) |*item, index| {
            if (item.oid != 0) continue;
            item.* = descriptor;
            self.used = true;
            if (descriptor.snapshot) |snap| self.min_csn = @min(self.min_csn orelse snap.csn, snap.csn);
            return @intCast(index);
        }
        return error.ProgramLimitExceeded;
    }

    pub fn find(self: *Self, fd: i32) types.Error!*Descriptor {
        if (fd < 0 or fd >= capacity or self.entries[@intCast(fd)].oid == 0) return error.InvalidParameterValue;
        return &self.entries[@intCast(fd)];
    }

    pub fn close(self: *Self, fd: i32) types.Error!void {
        (try self.find(fd)).* = .{};
        self.refresh();
    }

    pub fn unlink(self: *Self, oid: u32) void {
        for (&self.entries) |*item| if (item.oid == oid) {
            item.* = .{};
        };
        self.refresh();
    }

    pub fn discard(self: *Self, min_depth: usize, opened_cid: ?u32) void {
        for (&self.entries) |*item| {
            if (item.oid == 0) continue;
            if (item.depth >= min_depth and (opened_cid == null or item.opened_cid == opened_cid.?)) item.* = .{};
        }
        self.refresh();
    }

    pub fn release(self: *Self, depth: usize) void {
        for (&self.entries) |*item| if (item.oid != 0 and item.depth > depth) {
            item.depth = depth;
        };
    }
};
