//! Allocation-free reader for the original Whisper GGML container.
//!
//! All slices borrow the caller's immutable, usually memory-mapped file. Tensor
//! and vocabulary directories are supplied by the caller and remain borrowed by
//! Model. GGML stores unaligned little-endian payloads and dimensions in
//! fastest-axis-first order; no alignment or host struct layout is assumed.
//! A valid container does not prove that every architecture tensor is present.
const std = @import("std");

pub const MAGIC: u32 = 0x67676d6c;
pub const MAX_NAME_BYTES: usize = 255;
pub const MAX_TOKEN_BYTES: usize = 1024;
pub const DEFAULT_TENSOR_CAPACITY: usize = 1024;
pub const DEFAULT_VOCABULARY_CAPACITY: usize = 52000;

pub const Error = error{
    InvalidMagic,
    UnexpectedEof,
    InvalidHeader,
    UnsupportedModelType,
    InvalidFilters,
    InvalidVocabulary,
    VocabularyCapacity,
    TensorCapacity,
    InvalidTensorName,
    DuplicateTensor,
    InvalidTensorShape,
    UnsupportedTensorType,
    ArithmeticOverflow,
    MissingTensors,
};

pub const HParams = struct {
    n_vocab: u32,
    n_audio_ctx: u32,
    n_audio_state: u32,
    n_audio_head: u32,
    n_audio_layer: u32,
    n_text_ctx: u32,
    n_text_state: u32,
    n_text_head: u32,
    n_text_layer: u32,
    n_mels: u32,
    ftype: u32,
};

pub const Encoding = enum(u8) { f32 = 0, f16 = 1 };
pub const Token = struct { bytes: []const u8 };

pub const Tensor = struct {
    name: []const u8,
    encoding: Encoding,
    rank: u8,
    dimensions: [4]u32,
    data: []const u8,

    pub fn elements(self: Tensor) usize {
        return self.data.len / @as(usize, if (self.encoding == .f32) 4 else 2);
    }

    pub fn rowElements(self: Tensor) usize {
        return self.dimensions[0];
    }
    pub fn rows(self: Tensor) usize {
        return self.elements() / self.rowElements();
    }

    /// Caller must keep flat_index < elements(). Payload may be unaligned.
    pub fn value(self: Tensor, flat_index: usize) f32 {
        std.debug.assert(flat_index < self.elements());
        return switch (self.encoding) {
            .f32 => readF32(self.data[flat_index * 4 ..][0..4]),
            .f16 => @floatCast(@as(f16, @bitCast(readU16(self.data[flat_index * 2 ..][0..2])))),
        };
    }

    /// Decode one contiguous row into caller-owned float storage.
    pub fn readRow(self: Tensor, row: usize, output: []f32) bool {
        if (row >= self.rows() or output.len != self.rowElements()) return false;
        const offset = row * output.len;
        for (output, 0..) |*element, column| element.* = self.value(offset + column);
        return true;
    }
};

pub const Filters = struct {
    n_mels: u32,
    /// Number of non-negative frequency bins (201 for a 400-point STFT).
    n_fft: u32,
    data: []const u8,

    pub fn value(self: Filters, mel: usize, bin: usize) f32 {
        std.debug.assert(mel < self.n_mels and bin < self.n_fft);
        return readF32(self.data[(mel * self.n_fft + bin) * 4 ..][0..4]);
    }
};

pub const Model = struct {
    hparams: HParams,
    filters: Filters,
    tensors: []const Tensor,
    /// Stored lexical vocabulary; control/timestamp tokens are implicit.
    vocabulary: []const Token,

    pub fn find(self: *const Model, name: []const u8) ?*const Tensor {
        const index = self.tensorIndex(name) orelse return null;
        return &self.tensors[index];
    }

    pub fn tensorIndex(self: *const Model, name: []const u8) ?usize {
        for (self.tensors, 0..) |tensor, index|
            if (std.mem.eql(u8, name, tensor.name)) return index;
        return null;
    }
};

pub fn parse(bytes: []const u8, tensors: []Tensor, vocabulary: []Token) Error!Model {
    var cursor: Cursor = .{ .bytes = bytes };
    if (try cursor.u32le() != MAGIC) return error.InvalidMagic;
    const h: HParams = .{
        .n_vocab = try cursor.u32le(),
        .n_audio_ctx = try cursor.u32le(),
        .n_audio_state = try cursor.u32le(),
        .n_audio_head = try cursor.u32le(),
        .n_audio_layer = try cursor.u32le(),
        .n_text_ctx = try cursor.u32le(),
        .n_text_state = try cursor.u32le(),
        .n_text_head = try cursor.u32le(),
        .n_text_layer = try cursor.u32le(),
        .n_mels = try cursor.u32le(),
        .ftype = try cursor.u32le(),
    };
    if (h.n_vocab == 0 or h.n_vocab > 52000 or
        h.n_audio_ctx == 0 or h.n_audio_ctx > 65536 or
        h.n_text_ctx == 0 or h.n_text_ctx > 65536 or
        h.n_audio_state == 0 or h.n_audio_state > 16384 or
        h.n_text_state == 0 or h.n_text_state > 16384 or
        h.n_audio_head == 0 or h.n_audio_state % h.n_audio_head != 0 or
        h.n_text_head == 0 or h.n_text_state % h.n_text_head != 0 or
        h.n_audio_layer == 0 or h.n_audio_layer > 128 or
        h.n_text_layer == 0 or h.n_text_layer > 128 or
        h.n_mels == 0 or h.n_mels > 256) return error.InvalidHeader;
    if (h.ftype > 1) return error.UnsupportedModelType;

    const n_mels = try cursor.u32le();
    const n_fft = try cursor.u32le();
    if (n_mels != h.n_mels or n_fft != 201) return error.InvalidFilters;
    const filter_bytes = try cursor.take(try multiply(try multiply(n_mels, n_fft), 4));
    var filter_offset: usize = 0;
    while (filter_offset < filter_bytes.len) : (filter_offset += 4) {
        const value = readF32(filter_bytes[filter_offset..][0..4]);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidFilters;
    }

    const token_count = try cursor.u32le();
    if (token_count == 0 or token_count > h.n_vocab) return error.InvalidVocabulary;
    if (token_count > vocabulary.len) return error.VocabularyCapacity;
    for (vocabulary[0..token_count]) |*token| {
        const length = try cursor.u32le();
        if (length > MAX_TOKEN_BYTES) return error.InvalidVocabulary;
        token.* = .{ .bytes = try cursor.take(length) };
    }

    var tensor_count: usize = 0;
    while (cursor.offset < bytes.len) {
        if (tensor_count == tensors.len) return error.TensorCapacity;
        const rank = try cursor.u32le();
        const name_length = try cursor.u32le();
        const raw_type = try cursor.u32le();
        if (rank == 0 or rank > 4) return error.InvalidTensorShape;
        if (name_length == 0 or name_length > MAX_NAME_BYTES) return error.InvalidTensorName;
        const encoding: Encoding = switch (raw_type) {
            0 => .f32,
            1 => .f16,
            else => return error.UnsupportedTensorType,
        };
        var dimensions: [4]u32 = @splat(1);
        var count: usize = 1;
        for (dimensions[0..rank]) |*dimension| {
            dimension.* = try cursor.u32le();
            if (dimension.* == 0 or dimension.* > 16 * 1024 * 1024)
                return error.InvalidTensorShape;
            count = try multiply(count, dimension.*);
        }
        const name = try cursor.take(name_length);
        for (name) |byte| {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_'))
                return error.InvalidTensorName;
        }
        for (tensors[0..tensor_count]) |prior|
            if (std.mem.eql(u8, prior.name, name)) return error.DuplicateTensor;
        const data = try cursor.take(try multiply(count, if (encoding == .f32) @as(usize, 4) else 2));
        tensors[tensor_count] = .{
            .name = name,
            .encoding = encoding,
            .rank = @intCast(rank),
            .dimensions = dimensions,
            .data = data,
        };
        tensor_count += 1;
    }
    if (tensor_count == 0) return error.MissingTensors;
    return .{
        .hparams = h,
        .filters = .{ .n_mels = n_mels, .n_fft = n_fft, .data = filter_bytes },
        .tensors = tensors[0..tensor_count],
        .vocabulary = vocabulary[0..token_count],
    };
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,
    fn take(self: *Cursor, length: usize) Error![]const u8 {
        if (length > self.bytes.len - self.offset) return error.UnexpectedEof;
        const result = self.bytes[self.offset..][0..length];
        self.offset += length;
        return result;
    }
    fn u32le(self: *Cursor) Error!u32 {
        return readU32(try self.take(4));
    }
};

fn multiply(a: usize, b: usize) Error!usize {
    const product = @mulWithOverflow(a, b);
    if (product[1] != 0) return error.ArithmeticOverflow;
    return product[0];
}
fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}
fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}
fn readF32(bytes: []const u8) f32 {
    return @bitCast(readU32(bytes));
}

const testing = std.testing;

const Fixture = struct {
    bytes: [2048]u8 = @splat(0),
    length: usize = 0,
    tensor_offset: usize = 0,
    fn integer(self: *Fixture, value: u32) void {
        for (0..4) |i| self.bytes[self.length + i] = @truncate(value >> @as(u5, @intCast(i * 8)));
        self.length += 4;
    }
    fn raw(self: *Fixture, value: []const u8) void {
        @memcpy(self.bytes[self.length..][0..value.len], value);
        self.length += value.len;
    }
    fn tensor(self: *Fixture, name: []const u8) void {
        self.integer(2);
        self.integer(@intCast(name.len));
        self.integer(1);
        self.integer(2);
        self.integer(1);
        self.raw(name);
        self.raw(&.{ 0x00, 0x3c, 0x00, 0xc0 }); // 1, -2 in F16, deliberately unaligned.
    }
    fn init() Fixture {
        var result: Fixture = .{};
        for ([_]u32{ MAGIC, 51866, 1500, 1280, 20, 32, 448, 1280, 20, 4, 1, 1, 1, 201 }) |value|
            result.integer(value);
        for (0..201) |_| result.integer(@bitCast(@as(f32, 0.125)));
        result.integer(2);
        result.integer(2);
        result.raw("\xd7\x90");
        result.integer(1);
        result.raw("!");
        result.tensor_offset = result.length;
        result.tensor("encoder.weight");
        return result;
    }
};

test "GGML reader borrows unaligned F16 values and raw Hebrew token bytes" {
    var fixture = Fixture.init();
    var tensors: [2]Tensor = undefined;
    var vocabulary: [2]Token = undefined;
    const parsed = try parse(fixture.bytes[0..fixture.length], &tensors, &vocabulary);
    try testing.expectEqual(@as(u32, 32), parsed.hparams.n_audio_layer);
    try testing.expectEqual(@as(usize, 1), parsed.tensors.len);
    try testing.expectEqualStrings("\xd7\x90", parsed.vocabulary[0].bytes);
    try testing.expectEqual(@as(f32, 0.125), parsed.filters.value(0, 200));
    const tensor = parsed.find("encoder.weight").?;
    try testing.expectEqual(@as(f32, 1), tensor.value(0));
    try testing.expectEqual(@as(f32, -2), tensor.value(1));
    var row: [2]f32 = undefined;
    try testing.expect(tensor.readRow(0, &row));
    try testing.expect(!tensor.readRow(1, &row));
    try testing.expectEqual(@as(usize, 0), parsed.tensorIndex("encoder.weight").?);
}

test "GGML reader rejects every truncation and directory capacity failure" {
    var fixture = Fixture.init();
    var tensors: [1]Tensor = undefined;
    var vocabulary: [2]Token = undefined;
    for (0..fixture.length) |cut| {
        if (parse(fixture.bytes[0..cut], &tensors, &vocabulary)) |_| return error.TestUnexpectedResult else |_| {}
    }
    try testing.expectError(error.TensorCapacity, parse(fixture.bytes[0..fixture.length], &.{}, &vocabulary));
    try testing.expectError(error.VocabularyCapacity, parse(fixture.bytes[0..fixture.length], &tensors, vocabulary[0..1]));
}

test "GGML reader rejects duplicate names unsupported encodings and invalid headers" {
    var fixture = Fixture.init();
    var tensors: [2]Tensor = undefined;
    var vocabulary: [2]Token = undefined;
    fixture.tensor("encoder.weight");
    try testing.expectError(error.DuplicateTensor, parse(fixture.bytes[0..fixture.length], &tensors, &vocabulary));
    fixture = Fixture.init();
    fixture.bytes[fixture.tensor_offset + 8] = 2;
    try testing.expectError(error.UnsupportedTensorType, parse(fixture.bytes[0..fixture.length], &tensors, &vocabulary));
    fixture = Fixture.init();
    fixture.bytes[44] = 2;
    try testing.expectError(error.UnsupportedModelType, parse(fixture.bytes[0..fixture.length], &tensors, &vocabulary));
    fixture = Fixture.init();
    fixture.bytes[16] = 0; // n_audio_head = 0.
    try testing.expectError(error.InvalidHeader, parse(fixture.bytes[0..fixture.length], &tensors, &vocabulary));
    fixture = Fixture.init();
    fixture.bytes[56] = 0xff;
    fixture.bytes[57] = 0xff;
    fixture.bytes[58] = 0xff;
    fixture.bytes[59] = 0x7f; // NaN mel weight.
    try testing.expectError(error.InvalidFilters, parse(fixture.bytes[0..fixture.length], &tensors, &vocabulary));
}
