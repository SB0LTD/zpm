//! Bounded structured scalar record representation for flat ROW literals.
//! Its layout matches PostgreSQL record_send: a big-endian field count,
//! then the built-in OID, signed length and payload of each field.
const types = @import("types.sig");
const Error = types.Error;

pub fn supports(data_type: types.DataType) bool {
    return switch (data_type) {
        .smallint, .integer32, .integer, .boolean, .text => true,
        else => false,
    };
}

fn read(raw: []const u8) u64 {
    var word: u64 = 0;
    for (raw) |byte| word = (word << 8) | byte;
    return word;
}

const Sink = struct {
    bytes: []u8,
    used: usize = 0,

    fn put(self: *Sink, raw: []const u8) Error!void {
        if (raw.len > self.bytes.len - self.used) return error.TextCapacity;
        @memcpy(self.bytes[self.used..][0..raw.len], raw);
        self.used += raw.len;
    }

    fn word(self: *Sink, value: u64, len: usize) Error!void {
        if (len > self.bytes.len - self.used) return error.TextCapacity;
        for (0..len) |i| self.bytes[self.used + i] = @truncate(value >> @intCast((len - 1 - i) * 8));
        self.used += len;
    }
};

pub fn begin(out: []u8, count: u32) Error!usize {
    var sink: Sink = .{ .bytes = out };
    try sink.word(count, 4);
    return sink.used;
}

pub fn append(comptime config: types.Config, out: []u8, used: *usize, data_type: types.DataType,
    cell: *const types.Values(config).Cell) Error!void {
    if (!supports(data_type)) return error.UnsupportedStatement;
    var sink: Sink = .{ .bytes = out, .used = used.* };
    try sink.word(types.typeOid(data_type), 4);
    if (cell.* == .null_value) {
        try sink.word(0xffffffff, 4);
    } else switch (data_type) {
        .smallint, .integer32, .integer => {
            if (cell.* != .integer) return error.TypeMismatch;
            const n = cell.integer;
            const width: usize = switch (data_type) {
                .smallint => blk: {
                    if (n < -32768 or n > 32767) return error.NumericValueOutOfRange;
                    break :blk 2;
                },
                .integer32 => blk: {
                    if (n < -2147483648 or n > 2147483647) return error.NumericValueOutOfRange;
                    break :blk 4;
                },
                else => 8,
            };
            try sink.word(width, 4);
            try sink.word(@bitCast(n), width);
        },
        .boolean => {
            if (cell.* != .boolean) return error.TypeMismatch;
            try sink.word(1, 4);
            try sink.word(@intFromBool(cell.boolean), 1);
        },
        .text => {
            if (cell.* != .text) return error.TypeMismatch;
            const bytes = cell.text.slice();
            try sink.word(bytes.len, 4);
            try sink.put(bytes);
        },
        else => unreachable,
    }
    used.* = sink.used;
}

fn number(sink: *Sink, value: i64) Error!void {
    var digits: [20]u8 = undefined;
    var at: usize = digits.len;
    var magnitude = @abs(value);
    while (true) {
        at -= 1;
        digits[at] = @as(u8, @intCast(magnitude % 10)) + '0';
        magnitude /= 10;
        if (magnitude == 0) break;
    }
    if (value < 0) {
        at -= 1;
        digits[at] = '-';
    }
    try sink.put(digits[at..]);
}

fn quoteText(sink: *Sink, bytes: []const u8) Error!void {
    var quote = bytes.len == 0;
    for (bytes) |byte| switch (byte) {
        ' ', '\t', '\n', '\r', '\x0b', '\x0c', '"', '\\', '(', ')', ',' => {
            quote = true;
            break;
        },
        else => {},
    };
    if (quote) try sink.put("\"");
    for (bytes) |byte| {
        if (byte == '"' or byte == '\\') try sink.put(&.{byte});
        try sink.put(&.{byte});
    }
    if (quote) try sink.put("\"");
}

/// Render the admitted built-in field values from their typed binary
/// representation, preserving NULL versus empty string and record quoting.
pub fn format(bytes: []const u8, out: []u8) Error!usize {
    if (bytes.len < 4) return error.InvalidBinaryRepresentation;
    const count: usize = @intCast(read(bytes[0..4]));
    var fields = bytes[4..];
    var sink: Sink = .{ .bytes = out };
    try sink.put("(");
    for (0..count) |index| {
        if (fields.len < 8) return error.InvalidBinaryRepresentation;
        if (index != 0) try sink.put(",");
        const data_type = types.typeFromOid(@intCast(read(fields[0..4]))) orelse return error.InvalidBinaryRepresentation;
        if (!supports(data_type)) return error.InvalidBinaryRepresentation;
        const len: usize = @intCast(read(fields[4..8]));
        fields = fields[8..];
        if (len == 0xffffffff) continue;
        if (len > fields.len) return error.InvalidBinaryRepresentation;
        const payload = fields[0..len];
        fields = fields[len..];
        switch (data_type) {
            .text => try quoteText(&sink, payload),
            .boolean => {
                if (len != 1 or payload[0] > 1) return error.InvalidBinaryRepresentation;
                try sink.put(if (payload[0] == 0) "f" else "t");
            },
            .smallint => {
                if (len != 2) return error.InvalidBinaryRepresentation;
                try number(&sink, @as(i16, @bitCast(@as(u16, @intCast(read(payload))))));
            },
            .integer32 => {
                if (len != 4) return error.InvalidBinaryRepresentation;
                try number(&sink, @as(i32, @bitCast(@as(u32, @intCast(read(payload))))));
            },
            .integer => {
                if (len != 8) return error.InvalidBinaryRepresentation;
                try number(&sink, @bitCast(read(payload)));
            },
            else => unreachable,
        }
    }
    if (fields.len != 0) return error.InvalidBinaryRepresentation;
    try sink.put(")");
    return sink.used;
}
