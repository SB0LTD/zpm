//! Caller-owned Safetensors index and float views. No file I/O or heap.
//! Format: https://github.com/safetensors/safetensors#format
//! Tensor names are unescaped UTF-8, rank <= 8, metadata <= 128 keys.
//! The caller retains immutable file bytes and index storage together.
const text = @import("sig_text");
pub const MAX_HEADER_BYTES = 8 * 1024 * 1024;
pub const MAX_RANK = 8;
pub const Error = error{ Truncated, HeaderTooLarge, InvalidJson, InvalidUtf8, UnsupportedName, UnsupportedDtype, CapacityExceeded, DuplicateKey, InvalidShape, InvalidOffsets, Overflow, WrongDtype, OutOfBounds };
pub const Dtype = enum {
    bf16,
    f16,
    f32,
    f64,
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    boolean,
    pub fn bytes(self: Dtype) usize {
        return switch (self) {
            .boolean, .i8, .u8 => 1,
            .bf16, .f16, .i16, .u16 => 2,
            .f32, .i32, .u32 => 4,
            .f64, .i64, .u64 => 8,
        };
    }
};
pub const TensorInfo = struct {
    name: []const u8 = "",
    dtype: Dtype = .bf16,
    offset: usize = 0,
    size: usize = 0,
    byte_size: usize = 0,
    shape: [MAX_RANK]usize = @splat(0),
    n_dims: u8 = 0,
};
pub const SafetensorsFile = struct {
    base: [*]const u8,
    file_size: usize,
    header_size: u64,
    data_offset: usize,
    /// Envelope only. Use Index.parse to validate all tensor metadata.
    pub fn init(base: [*]const u8, file_size: usize) ?SafetensorsFile {
        if (file_size < 8) return null;
        const hs = readLe(base[0..8]);
        if (hs > MAX_HEADER_BYTES or hs > file_size - 8 or hs == 0) return null;
        const start = 8 + @as(usize, @intCast(hs));
        if (base[8] != '{') return null;
        return .{ .base = base, .file_size = file_size, .header_size = hs, .data_offset = start };
    }
    pub fn headerJson(self: *const SafetensorsFile) []const u8 {
        return self.base[8..self.data_offset];
    }
    /// Legacy aligned little-endian view; rejects overflow and misalignment.
    pub fn tensorDataBf16(self: *const SafetensorsFile, offset: usize, count: usize) ?[*]const u16 {
        const available = self.file_size - self.data_offset;
        if (offset > available or count > (available - offset) / 2) return null;
        const ptr = self.base + self.data_offset + offset;
        if (@intFromPtr(ptr) % @alignOf(u16) != 0) return null;
        return @ptrCast(@alignCast(ptr));
    }
};
pub const Index = struct {
    file: SafetensorsFile,
    tensors: []const TensorInfo,
    /// Storage is scratch until success. Validate the entire header and exact
    /// data coverage, including duplicate names, overlaps, holes and overflow.
    pub fn parse(bytes: []const u8, storage: []TensorInfo) Error!Index {
        if (bytes.len < 8) return error.Truncated;
        if (readLe(bytes[0..8]) > MAX_HEADER_BYTES) return error.HeaderTooLarge;
        const file = SafetensorsFile.init(bytes.ptr, bytes.len) orelse return error.Truncated;
        const header = file.headerJson();
        if (!text.utf8ValidateSlice(header)) return error.InvalidUtf8;
        var parser = Parser{ .input = header };
        try parser.expect('{');
        var count: usize = 0;
        var metadata_seen = false;
        if (!parser.take('}')) while (true) {
            const name = try parser.string(false);
            try parser.expect(':');
            if (eql(name, "__metadata__")) {
                if (metadata_seen) return error.DuplicateKey;
                metadata_seen = true;
                try parser.metadata();
            } else {
                if (findTensor(storage[0..count], name) != null) return error.DuplicateKey;
                if (count == storage.len) return error.CapacityExceeded;
                var info = try parser.tensor();
                info.name = name;
                const available = bytes.len - file.data_offset;
                if (info.offset > available or info.byte_size > available - info.offset) return error.InvalidOffsets;
                storage[count] = info;
                count += 1;
            }
            if (parser.take('}')) break;
            try parser.expect(',');
        };
        parser.space();
        if (parser.pos != header.len) return error.InvalidJson;
        // Sort in caller storage; empty tensors precede nonempty tensors at
        // the same offset, allowing legal empty tensors at data boundaries.
        if (count > 1) for (1..count) |i| {
            const item = storage[i];
            var j = i;
            while (j > 0 and (storage[j - 1].offset > item.offset or
                (storage[j - 1].offset == item.offset and storage[j - 1].byte_size > item.byte_size))) : (j -= 1)
                storage[j] = storage[j - 1];
            storage[j] = item;
        };
        var covered: usize = 0;
        for (storage[0..count]) |info| {
            if (info.offset != covered) return error.InvalidOffsets;
            covered += info.byte_size;
        }
        if (covered != bytes.len - file.data_offset) return error.InvalidOffsets;
        return .{ .file = file, .tensors = storage[0..count] };
    }
    pub fn find(self: *const Index, name: []const u8) ?*const TensorInfo {
        return findTensor(self.tensors, name);
    }
    pub fn view(self: *const Index, name: []const u8) ?TensorView {
        const info = self.find(name) orelse return null;
        const start = self.file.data_offset + info.offset;
        return .{ .info = info, .data = self.file.base[start..][0..info.byte_size] };
    }
};
pub const TensorView = struct {
    info: *const TensorInfo,
    data: []const u8,
    /// Read BF16/F16/F32 directly, including from unaligned mappings.
    pub fn floatAt(self: TensorView, element: usize) Error!f32 {
        if (element >= self.info.size) return error.OutOfBounds;
        const width = self.info.dtype.bytes();
        if (element >= self.data.len / width) return error.OutOfBounds;
        const bits = readLe(self.data[element * width ..][0..width]);
        return switch (self.info.dtype) {
            .bf16 => bf16ToF32(@intCast(bits)),
            .f16 => @floatCast(@as(f16, @bitCast(@as(u16, @intCast(bits))))),
            .f32 => @bitCast(@as(u32, @intCast(bits))),
            else => error.WrongDtype,
        };
    }
};
pub fn bf16ToF32(value: u16) f32 {
    return @bitCast(@as(u32, value) << 16);
}
pub fn convertBf16ToF32(src: [*]const u16, dst: [*]f32, count: usize) void {
    for (0..count) |i| dst[i] = bf16ToF32(src[i]);
}
pub fn findTensor(infos: []const TensorInfo, name: []const u8) ?*const TensorInfo {
    for (infos) |*info| if (eql(info.name, name)) return info;
    return null;
}
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
fn readLe(bytes: []const u8) u64 {
    var result: u64 = 0;
    for (bytes, 0..) |byte, i| result |= @as(u64, byte) << @intCast(i * 8);
    return result;
}
const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    fn space(self: *Parser) void {
        while (self.pos < self.input.len) : (self.pos += 1) switch (self.input[self.pos]) {
            ' ', '\t', '\r', '\n' => {},
            else => return,
        };
    }
    fn take(self: *Parser, byte: u8) bool {
        self.space();
        if (self.pos == self.input.len or self.input[self.pos] != byte) return false;
        self.pos += 1;
        return true;
    }
    fn expect(self: *Parser, byte: u8) Error!void {
        if (!self.take(byte)) return error.InvalidJson;
    }
    fn hex4(self: *Parser) Error!u16 {
        if (self.input.len - self.pos < 4) return error.InvalidJson;
        var value: u16 = 0;
        for (self.input[self.pos..][0..4]) |byte| {
            const digit: u16 = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => return error.InvalidJson,
            };
            value = value * 16 + digit;
        }
        self.pos += 4;
        return value;
    }
    fn string(self: *Parser, escapes: bool) Error![]const u8 {
        try self.expect('"');
        const start = self.pos;
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            self.pos += 1;
            if (byte == '"') return self.input[start .. self.pos - 1];
            if (byte < 0x20) return error.InvalidJson;
            if (byte != '\\') continue;
            if (!escapes) return error.UnsupportedName;
            if (self.pos == self.input.len) return error.InvalidJson;
            const escaped = self.input[self.pos];
            self.pos += 1;
            switch (escaped) {
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
                'u' => {
                    const unit = try self.hex4();
                    if (unit >= 0xdc00 and unit <= 0xdfff) return error.InvalidJson;
                    if (unit >= 0xd800 and unit <= 0xdbff) {
                        if (self.input.len - self.pos < 2 or !eql(self.input[self.pos..][0..2], "\\u")) return error.InvalidJson;
                        self.pos += 2;
                        const low = try self.hex4();
                        if (low < 0xdc00 or low > 0xdfff) return error.InvalidJson;
                    }
                },
                else => return error.InvalidJson,
            }
        }
        return error.InvalidJson;
    }
    fn number(self: *Parser) Error!usize {
        self.space();
        const start = self.pos;
        var value: usize = 0;
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            if (byte < '0' or byte > '9') break;
            if (self.pos > start and self.input[start] == '0') return error.InvalidJson;
            const digit: usize = byte - '0';
            if (value > (~@as(usize, 0) - digit) / 10) return error.Overflow;
            value = value * 10 + digit;
            self.pos += 1;
        }
        if (self.pos == start) return error.InvalidJson;
        return value;
    }
    fn metadata(self: *Parser) Error!void {
        try self.expect('{');
        var keys: [128][]const u8 = undefined;
        var count: usize = 0;
        if (self.take('}')) return;
        while (true) {
            const key = try self.string(false);
            for (keys[0..count]) |old| if (eql(old, key)) return error.DuplicateKey;
            if (count == keys.len) return error.CapacityExceeded;
            keys[count] = key;
            count += 1;
            try self.expect(':');
            _ = try self.string(true);
            if (self.take('}')) return;
            try self.expect(',');
        }
    }
    fn tensor(self: *Parser) Error!TensorInfo {
        var info = TensorInfo{};
        var fields: u8 = 0;
        try self.expect('{');
        while (true) {
            const key = try self.string(false);
            try self.expect(':');
            const bit: u8 = if (eql(key, "dtype")) 1 else if (eql(key, "shape")) 2 else if (eql(key, "data_offsets")) 4 else return error.InvalidJson;
            if (fields & bit != 0) return error.DuplicateKey;
            fields |= bit;
            switch (bit) {
                1 => {
                    const dtype_name = try self.string(false);
                    info.dtype = dtype: {
                        inline for (.{ .{ "BF16", Dtype.bf16 }, .{ "F16", Dtype.f16 }, .{ "F32", Dtype.f32 }, .{ "F64", Dtype.f64 }, .{ "I8", Dtype.i8 }, .{ "U8", Dtype.u8 }, .{ "I16", Dtype.i16 }, .{ "U16", Dtype.u16 }, .{ "I32", Dtype.i32 }, .{ "U32", Dtype.u32 }, .{ "I64", Dtype.i64 }, .{ "U64", Dtype.u64 }, .{ "BOOL", Dtype.boolean } }) |pair| {
                            if (eql(dtype_name, pair[0])) break :dtype pair[1];
                        }
                        return error.UnsupportedDtype;
                    };
                },
                2 => {
                    try self.expect('[');
                    if (!self.take(']')) while (true) {
                        if (info.n_dims == MAX_RANK) return error.InvalidShape;
                        info.shape[info.n_dims] = try self.number();
                        info.n_dims += 1;
                        if (self.take(']')) break;
                        try self.expect(',');
                    };
                },
                4 => {
                    try self.expect('[');
                    info.offset = try self.number();
                    try self.expect(',');
                    const end = try self.number();
                    try self.expect(']');
                    if (end < info.offset) return error.InvalidOffsets;
                    info.byte_size = end - info.offset;
                },
                else => unreachable,
            }
            if (self.take('}')) break;
            try self.expect(',');
        }
        if (fields != 7) return error.InvalidJson;
        info.size = 1;
        for (info.shape[0..info.n_dims]) |dim| {
            if (dim != 0 and info.size > ~@as(usize, 0) / dim) return error.Overflow;
            info.size *= dim;
        }
        const width = info.dtype.bytes();
        if (info.size > ~@as(usize, 0) / width) return error.Overflow;
        if (info.byte_size != info.size * width) return error.InvalidShape;
        return info;
    }
};
