//! SB0 tensor-program container v1.
//!
//! This is the native immutable model ABI used by SB0 runtimes.  It contains
//! a fixed header, fixed-size tensor directory, and 64-byte-aligned payloads;
//! parsing requires no allocator, string table, recursive metadata grammar,
//! loader, or host struct layout.  The authenticated USB envelope hashes the
//! complete file while this parser independently validates every range,
//! encoding, shape, name, and overlap before a tensor can be mapped.

const std = @import("std");

pub const MAGIC = [4]u8{ 'S', 'B', '0', 'M' };
pub const VERSION: u16 = 1;
pub const HEADER_BYTES: u16 = 128;
pub const ENTRY_BYTES: u16 = 192;
pub const ALIGNMENT: u64 = 64;
pub const NAME_BYTES: usize = 112;
pub const COMMIT_BYTES: usize = 40;
pub const MAX_RANK: usize = 4;

pub const ModelKind = enum(u16) {
    smolvlm2_500m = 1,
    smolvlm2_256m = 2,
    kitten_tts_nano = 3,
    qwen3_tts_0_6b_talker = 4,
    qwen3_tts_12hz_codec = 5,
};

pub const Encoding = enum(u8) {
    f16 = 1,
    sb0_q4 = 2,
    raw_u8 = 3,
};

pub const Header = struct {
    model_kind: ModelKind,
    tensor_count: u16,
    flags: u16,
    table_offset: u64,
    data_offset: u64,
    file_bytes: u64,
    source_bytes: u64,
    source_sha256: [32]u8,
    source_commit: [COMMIT_BYTES]u8,
    source_commit_len: u8,

    pub fn commit(self: *const Header) []const u8 {
        return self.source_commit[0..self.source_commit_len];
    }
};

pub const Tensor = struct {
    name_storage: [NAME_BYTES]u8 = @splat(0),
    name_len: u16 = 0,
    encoding: Encoding = .f16,
    rank: u8 = 0,
    dimensions: [MAX_RANK]u32 = @splat(0),
    data_offset: u64 = 0,
    data_bytes: u64 = 0,
    element_count: u64 = 0,
    source_offset: u64 = 0,
    source_bytes: u64 = 0,

    pub fn name(self: *const Tensor) []const u8 {
        return self.name_storage[0..self.name_len];
    }

    pub fn rowElements(self: *const Tensor) u64 {
        if (self.rank < 2) return self.element_count;
        var elements: u64 = 1;
        for (self.dimensions[1..self.rank]) |dimension| elements *= dimension;
        return elements;
    }

    pub fn rows(self: *const Tensor) u64 {
        return if (self.rank < 2) 1 else self.dimensions[0];
    }
};

pub fn Index(comptime capacity: usize) type {
    return struct {
        header: Header = undefined,
        tensors: [capacity]Tensor = @splat(Tensor{}),
        tensor_count: u16 = 0,

        pub fn find(self: *const @This(), name: []const u8) ?*const Tensor {
            for (self.tensors[0..self.tensor_count]) |*tensor|
                if (std.mem.eql(u8, tensor.name(), name)) return tensor;
            return null;
        }
    };
}

pub const Source = struct {
    context: *const anyopaque,
    size: u64,
    read_at: *const fn (*const anyopaque, u64, []u8) bool,
    map_at: ?*const fn (*const anyopaque, u64, usize, usize) ?[*]const u8 = null,

    pub fn read(self: Source, offset: u64, destination: []u8) bool {
        const end = @addWithOverflow(offset, @as(u64, @intCast(destination.len)));
        return end[1] == 0 and end[0] <= self.size and
            self.read_at(self.context, offset, destination);
    }

    pub fn map(self: Source, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
        const callback = self.map_at orelse return null;
        const end = @addWithOverflow(offset, @as(u64, @intCast(length)));
        if (alignment == 0 or alignment & (alignment - 1) != 0 or
            end[1] != 0 or end[0] > self.size) return null;
        return callback(self.context, offset, length, alignment);
    }
};

pub const Error = error{
    UnexpectedEof,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    UnsupportedModel,
    TooManyTensors,
    InvalidTensorName,
    InvalidEncoding,
    InvalidTensorShape,
    InvalidTensorRange,
    OverlappingTensors,
    ArithmeticOverflow,
};

pub fn parse(comptime capacity: usize, source: Source, out: *Index(capacity)) Error!void {
    var header_bytes: [HEADER_BYTES]u8 = undefined;
    if (!source.read(0, &header_bytes)) return error.UnexpectedEof;
    if (!std.mem.eql(u8, header_bytes[0..4], &MAGIC)) return error.InvalidMagic;
    if (get16(&header_bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (get16(&header_bytes, 6) != HEADER_BYTES or
        get16(&header_bytes, 12) != ENTRY_BYTES or !zeros(header_bytes[121..128]))
        return error.InvalidHeader;

    const model_kind: ModelKind = switch (get16(&header_bytes, 8)) {
        1 => .smolvlm2_500m,
        2 => .smolvlm2_256m,
        3 => .kitten_tts_nano,
        4 => .qwen3_tts_0_6b_talker,
        5 => .qwen3_tts_12hz_codec,
        else => return error.UnsupportedModel,
    };
    const tensor_count = get16(&header_bytes, 10);
    if (tensor_count == 0 or tensor_count > capacity) return error.TooManyTensors;
    const table_offset = get64(&header_bytes, 16);
    const data_offset = get64(&header_bytes, 24);
    const file_bytes = get64(&header_bytes, 32);
    const source_bytes = get64(&header_bytes, 40);
    const commit_len = header_bytes[120];
    const table_bytes = try multiply(tensor_count, ENTRY_BYTES);
    const table_end = try add(table_offset, table_bytes);
    if (table_offset != HEADER_BYTES or data_offset % ALIGNMENT != 0 or
        table_end > data_offset or file_bytes != source.size or
        file_bytes < data_offset or commit_len == 0 or commit_len > COMMIT_BYTES)
        return error.InvalidHeader;

    out.* = .{};
    out.header = .{
        .model_kind = model_kind,
        .tensor_count = tensor_count,
        .flags = get16(&header_bytes, 14),
        .table_offset = table_offset,
        .data_offset = data_offset,
        .file_bytes = file_bytes,
        .source_bytes = source_bytes,
        .source_sha256 = header_bytes[48..80].*,
        .source_commit = header_bytes[80..120].*,
        .source_commit_len = commit_len,
    };
    out.tensor_count = tensor_count;

    var entry_bytes: [ENTRY_BYTES]u8 = undefined;
    for (out.tensors[0..tensor_count], 0..) |*tensor, tensor_index| {
        const entry_offset = try add(table_offset, try multiply(tensor_index, ENTRY_BYTES));
        if (!source.read(entry_offset, &entry_bytes)) return error.UnexpectedEof;
        const name_len = get16(&entry_bytes, 112);
        if (name_len == 0 or name_len > NAME_BYTES or
            !validName(entry_bytes[0..name_len]) or
            !zeros(entry_bytes[name_len..NAME_BYTES]) or
            !zeros(entry_bytes[156..160]) or !zeros(entry_bytes[176..192]))
            return error.InvalidTensorName;
        tensor.name_len = name_len;
        @memcpy(tensor.name_storage[0..name_len], entry_bytes[0..name_len]);
        tensor.encoding = switch (entry_bytes[114]) {
            1 => .f16,
            2 => .sb0_q4,
            3 => .raw_u8,
            else => return error.InvalidEncoding,
        };
        tensor.rank = entry_bytes[115];
        if (tensor.rank == 0 or tensor.rank > MAX_RANK)
            return error.InvalidTensorShape;
        var elements: u64 = 1;
        for (0..MAX_RANK) |dimension_index| {
            const dimension = get32(&entry_bytes, 116 + dimension_index * 4);
            tensor.dimensions[dimension_index] = dimension;
            if (dimension_index < tensor.rank) {
                if (dimension == 0) return error.InvalidTensorShape;
                elements = try multiply(elements, dimension);
            } else if (dimension != 0) return error.InvalidTensorShape;
        }
        tensor.data_offset = get64(&entry_bytes, 132);
        tensor.data_bytes = get64(&entry_bytes, 140);
        tensor.element_count = get64(&entry_bytes, 148);
        tensor.source_offset = get64(&entry_bytes, 160);
        tensor.source_bytes = get64(&entry_bytes, 168);
        if (tensor.element_count != elements or tensor.data_offset % ALIGNMENT != 0 or
            tensor.data_offset < data_offset or tensor.source_bytes == 0)
            return error.InvalidTensorShape;
        const expected = try encodedBytes(tensor.encoding, elements, tensor.rowElements());
        const tensor_end = try add(tensor.data_offset, tensor.data_bytes);
        if (expected != tensor.data_bytes or tensor_end > file_bytes)
            return error.InvalidTensorRange;

        for (out.tensors[0..tensor_index]) |*prior| {
            if (std.mem.eql(u8, prior.name(), tensor.name())) return error.InvalidTensorName;
            const prior_end = try add(prior.data_offset, prior.data_bytes);
            if (tensor.data_offset < prior_end and prior.data_offset < tensor_end)
                return error.OverlappingTensors;
        }
    }
}

pub fn encodedBytes(encoding: Encoding, elements: u64, row_elements: u64) Error!u64 {
    if (elements == 0 or row_elements == 0 or elements % row_elements != 0)
        return error.InvalidTensorShape;
    return switch (encoding) {
        .f16 => multiply(elements, 2),
        .raw_u8 => elements,
        .sb0_q4 => if (row_elements % 32 != 0)
            error.InvalidTensorShape
        else
            multiply(elements / 32, 18),
    };
}

pub fn encodeHeader(header: Header, destination: *[HEADER_BYTES]u8) Error!void {
    destination.* = @splat(0);
    destination[0..4].* = MAGIC;
    put16(destination, 4, VERSION);
    put16(destination, 6, HEADER_BYTES);
    put16(destination, 8, @backingInt(header.model_kind));
    put16(destination, 10, header.tensor_count);
    put16(destination, 12, ENTRY_BYTES);
    put16(destination, 14, header.flags);
    put64(destination, 16, header.table_offset);
    put64(destination, 24, header.data_offset);
    put64(destination, 32, header.file_bytes);
    put64(destination, 40, header.source_bytes);
    destination[48..80].* = header.source_sha256;
    if (header.source_commit_len == 0 or header.source_commit_len > COMMIT_BYTES)
        return error.InvalidHeader;
    @memcpy(destination[80..][0..header.source_commit_len], header.commit());
    destination[120] = header.source_commit_len;
}

pub fn encodeTensor(tensor: Tensor, destination: *[ENTRY_BYTES]u8) Error!void {
    destination.* = @splat(0);
    if (tensor.name_len == 0 or tensor.name_len > NAME_BYTES or
        !validName(tensor.name())) return error.InvalidTensorName;
    @memcpy(destination[0..tensor.name_len], tensor.name());
    put16(destination, 112, tensor.name_len);
    destination[114] = @backingInt(tensor.encoding);
    destination[115] = tensor.rank;
    for (tensor.dimensions, 0..) |dimension, index|
        put32(destination, 116 + index * 4, dimension);
    put64(destination, 132, tensor.data_offset);
    put64(destination, 140, tensor.data_bytes);
    put64(destination, 148, tensor.element_count);
    put64(destination, 160, tensor.source_offset);
    put64(destination, 168, tensor.source_bytes);
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') return false;
    for (name) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or byte == '.' or byte == '_';
        if (!valid) return false;
    }
    return true;
}

fn zeros(bytes: []const u8) bool {
    var combined: u8 = 0;
    for (bytes) |byte| combined |= byte;
    return combined == 0;
}

fn add(left: anytype, right: anytype) Error!u64 {
    const result = @addWithOverflow(@as(u64, @intCast(left)), @as(u64, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

fn multiply(left: anytype, right: anytype) Error!u64 {
    const result = @mulWithOverflow(@as(u64, @intCast(left)), @as(u64, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

fn get16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn get32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24);
}

fn get64(bytes: []const u8, offset: usize) u64 {
    var value: u64 = 0;
    for (0..8) |byte| value |= @as(u64, bytes[offset + byte]) << @intCast(byte * 8);
    return value;
}

fn put16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn put32(bytes: []u8, offset: usize, value: u32) void {
    for (0..4) |byte| bytes[offset + byte] = @truncate(value >> @intCast(byte * 8));
}

fn put64(bytes: []u8, offset: usize, value: u64) void {
    for (0..8) |byte| bytes[offset + byte] = @truncate(value >> @intCast(byte * 8));
}

const testing = std.testing;

const MemorySource = struct {
    bytes: []const u8,
    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const MemorySource = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or destination.len > self.bytes.len - @as(usize, @intCast(offset)))
            return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn source(self: *const MemorySource) Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = read };
    }
};

test "SB0 tensor program round trips a native quantized tensor" {
    var bytes: [320]u8 = @splat(0);
    var header = Header{
        .model_kind = .smolvlm2_500m,
        .tensor_count = 1,
        .flags = 0,
        .table_offset = HEADER_BYTES,
        .data_offset = 320,
        .file_bytes = bytes.len,
        .source_bytes = 128,
        .source_sha256 = @splat(0x5a),
        .source_commit = @splat(0),
        .source_commit_len = 4,
    };
    header.source_commit[0..4].* = "test".*;
    try encodeHeader(header, bytes[0..HEADER_BYTES]);
    var tensor: Tensor = .{
        .name_len = 6,
        .encoding = .sb0_q4,
        .rank = 2,
        .dimensions = .{ 2, 32, 0, 0 },
        .data_offset = 320,
        .data_bytes = 36,
        .element_count = 64,
        .source_offset = 64,
        .source_bytes = 256,
    };
    tensor.name_storage[0..6].* = "weight".*;
    // Enlarge the logical source to include the encoded tensor payload.
    var complete: [356]u8 = @splat(0);
    @memcpy(complete[0..bytes.len], &bytes);
    header.file_bytes = complete.len;
    try encodeHeader(header, complete[0..HEADER_BYTES]);
    try encodeTensor(tensor, complete[HEADER_BYTES..][0..ENTRY_BYTES]);
    var source = MemorySource{ .bytes = &complete };
    var index: Index(4) = .{};
    try parse(4, source.source(), &index);
    try testing.expectEqual(ModelKind.smolvlm2_500m, index.header.model_kind);
    try testing.expectEqualStrings("test", index.header.commit());
    try testing.expectEqualStrings("weight", index.tensors[0].name());
    try testing.expectEqual(@as(u64, 32), index.tensors[0].rowElements());
}

test "SB0 tensor program rejects an overlapping payload" {
    var bytes: [576]u8 = @splat(0);
    var header = Header{
        .model_kind = .smolvlm2_500m,
        .tensor_count = 2,
        .flags = 0,
        .table_offset = HEADER_BYTES,
        .data_offset = 512,
        .file_bytes = bytes.len,
        .source_bytes = 512,
        .source_sha256 = @splat(1),
        .source_commit = @splat(0),
        .source_commit_len = 1,
    };
    header.source_commit[0] = 'x';
    try encodeHeader(header, bytes[0..HEADER_BYTES]);
    for (0..2) |index| {
        var tensor: Tensor = .{
            .name_len = 2,
            .encoding = .f16,
            .rank = 1,
            .dimensions = .{ 16, 0, 0, 0 },
            .data_offset = 512,
            .data_bytes = 32,
            .element_count = 16,
            .source_offset = index * 64,
            .source_bytes = 64,
        };
        tensor.name_storage[0] = 'w';
        tensor.name_storage[1] = '0' + @as(u8, @intCast(index));
        try encodeTensor(tensor, bytes[HEADER_BYTES + index * ENTRY_BYTES ..][0..ENTRY_BYTES]);
    }
    var source = MemorySource{ .bytes = &bytes };
    var index: Index(2) = .{};
    try testing.expectError(error.OverlappingTensors, parse(2, source.source(), &index));
}
