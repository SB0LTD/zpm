//! Strict, allocation-free GGUF v3 structural reader.
//!
//! The parser reads through a caller-owned random-access source. It never maps
//! or copies the complete model, never allocates, and does not know any model
//! product name. Successful parsing proves only that the container and tensor
//! spans are structurally safe; executor parity is a separate readiness gate.

const math = @import("sig_math");
const mem = @import("sig_mem");

pub const DEFAULT_ALIGNMENT: u32 = 32;
pub const MAX_KEY_BYTES: u64 = 65_535;
pub const MAX_STRING_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_ARRAY_ITEMS: u64 = 16 * 1024 * 1024;
pub const MAX_ARRAY_DEPTH: u8 = 4;

pub const Error = error{
    InvalidMagic,
    UnsupportedVersion,
    UnexpectedEof,
    InvalidMetadataType,
    InvalidMetadataKey,
    InvalidMetadataValue,
    MetadataLimit,
    InvalidAlignment,
    TooManyTensors,
    InvalidTensorName,
    InvalidTensorShape,
    UnsupportedTensorType,
    InvalidTensorOffset,
    OverlappingTensors,
    ArithmeticOverflow,
};

pub const ReadAtFn = *const fn (
    context: *const anyopaque,
    offset: u64,
    destination: []u8,
) bool;
pub const MapAtFn = *const fn (
    context: *const anyopaque,
    offset: u64,
    length: usize,
    alignment: usize,
) ?[*]const u8;

/// Storage-neutral, exact random-access byte source. Kernel storage backends
/// should put their own bounded cache beneath this interface.
pub const Source = struct {
    context: *const anyopaque,
    size: u64,
    read_at: ReadAtFn,
    map_at: ?MapAtFn = null,

    pub fn read(self: Source, offset: u64, destination: []u8) bool {
        const length: u64 = @intCast(destination.len);
        if (offset > self.size or length > self.size - offset) return false;
        if (destination.len == 0) return true;
        return self.read_at(self.context, offset, destination);
    }

    /// Borrow an immutable authenticated storage span when the backend can map
    /// it directly.  Executors use this for zero-copy tensor rows; parsers keep
    /// the portable read path.  The boundary is checked before the backend is
    /// called and the returned pointer is independently alignment-checked.
    pub fn view(self: Source, offset: u64, length: usize, alignment: usize) ?[]const u8 {
        if (alignment == 0 or alignment & (alignment - 1) != 0) return null;
        const length64: u64 = @intCast(length);
        if (offset > self.size or length64 > self.size - offset) return null;
        if (length == 0) return &.{};
        const mapper = self.map_at orelse return null;
        const pointer = mapper(self.context, offset, length, alignment) orelse return null;
        if (@intFromPtr(pointer) & (alignment - 1) != 0) return null;
        return pointer[0..length];
    }
};

pub const Summary = struct {
    version: u32 = 0,
    tensor_count: u64 = 0,
    metadata_count: u64 = 0,
    alignment: u32 = DEFAULT_ALIGNMENT,
    data_offset: u64 = 0,
    architecture: [64]u8 = @splat(0),
    architecture_len: u8 = 0,
    context_length: u64 = 0,
    embedding_length: u64 = 0,
    block_count: u64 = 0,
    head_count: u64 = 0,
    head_count_kv: u64 = 0,
    attention_key_length: u64 = 0,
    attention_value_length: u64 = 0,
    feed_forward_length: u64 = 0,
    vocab_size: u64 = 0,
    rope_frequency_base: f32 = 0,
    rms_norm_epsilon: f32 = 0,
    tokenizer_tokens: ArrayRef = .{},
    tokenizer_merges: ArrayRef = .{},
    tokenizer_scores: ArrayRef = .{},
    tokenizer_token_types: ArrayRef = .{},

    pub fn architectureSlice(self: *const Summary) []const u8 {
        return self.architecture[0..self.architecture_len];
    }
};

/// Reference to a standard GGUF metadata array. Variable-size elements stay
/// in authenticated model storage and can be indexed by a bounded second pass.
pub const ArrayRef = struct {
    present: bool = false,
    element_type: u32 = 0,
    count: u64 = 0,
    data_offset: u64 = 0,
};

pub const TensorInfo = struct {
    name: [64]u8 = @splat(0),
    name_len: u8 = 0,
    dimension_count: u8 = 0,
    dimensions: [4]u64 = @splat(0),
    ggml_type: u32 = 0,
    relative_offset: u64 = 0,
    file_offset: u64 = 0,
    byte_size: u64 = 0,

    pub fn nameSlice(self: *const TensorInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub fn Index(comptime tensor_capacity: usize) type {
    if (tensor_capacity == 0) @compileError("GGUF tensor capacity must be non-zero");
    return struct {
        summary: Summary = .{},
        tensors: [tensor_capacity]TensorInfo = @splat(.{}),
        tensor_count: usize = 0,

        pub fn find(self: *const @This(), name: []const u8) ?*const TensorInfo {
            for (self.tensors[0..self.tensor_count]) |*tensor| {
                if (mem.eql(u8, tensor.nameSlice(), name)) return tensor;
            }
            return null;
        }
    };
}

const MetadataType = enum(u32) {
    uint8 = 0,
    int8 = 1,
    uint16 = 2,
    int16 = 3,
    uint32 = 4,
    int32 = 5,
    float32 = 6,
    boolean = 7,
    string = 8,
    array = 9,
    uint64 = 10,
    int64 = 11,
    float64 = 12,
};

const KeyRef = struct { offset: u64, length: u64 };

const Cursor = struct {
    source: Source,
    position: u64 = 0,

    fn readBytes(self: *Cursor, destination: []u8) Error!void {
        if (!self.source.read(self.position, destination)) return error.UnexpectedEof;
        self.position = try checkedAdd(self.position, @as(u64, @intCast(destination.len)));
    }

    fn skip(self: *Cursor, length: u64) Error!void {
        const end = try checkedAdd(self.position, length);
        if (end > self.source.size) return error.UnexpectedEof;
        self.position = end;
    }

    fn readU8(self: *Cursor) Error!u8 {
        var bytes: [1]u8 = undefined;
        try self.readBytes(&bytes);
        return bytes[0];
    }

    fn readU16(self: *Cursor) Error!u16 {
        var bytes: [2]u8 = undefined;
        try self.readBytes(&bytes);
        return mem.readInt(u16, &bytes, .little);
    }

    fn readU32(self: *Cursor) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.readBytes(&bytes);
        return mem.readInt(u32, &bytes, .little);
    }

    fn readU64(self: *Cursor) Error!u64 {
        var bytes: [8]u8 = undefined;
        try self.readBytes(&bytes);
        return mem.readInt(u64, &bytes, .little);
    }
};

pub const TypeTraits = struct { elements_per_block: u32, bytes_per_block: u32 };

/// Container sizing traits from the GGML ABI. Execution support is narrower
/// and must be declared by the selected compute backend independently.
pub fn typeTraits(raw: u32) ?TypeTraits {
    return switch (raw) {
        0 => .{ .elements_per_block = 1, .bytes_per_block = 4 }, // F32
        1 => .{ .elements_per_block = 1, .bytes_per_block = 2 }, // F16
        2 => .{ .elements_per_block = 32, .bytes_per_block = 18 }, // Q4_0
        3 => .{ .elements_per_block = 32, .bytes_per_block = 20 }, // Q4_1
        6 => .{ .elements_per_block = 32, .bytes_per_block = 22 }, // Q5_0
        7 => .{ .elements_per_block = 32, .bytes_per_block = 24 }, // Q5_1
        8 => .{ .elements_per_block = 32, .bytes_per_block = 34 }, // Q8_0
        9 => .{ .elements_per_block = 32, .bytes_per_block = 40 }, // Q8_1
        10 => .{ .elements_per_block = 256, .bytes_per_block = 84 }, // Q2_K
        11 => .{ .elements_per_block = 256, .bytes_per_block = 110 }, // Q3_K
        12 => .{ .elements_per_block = 256, .bytes_per_block = 144 }, // Q4_K
        13 => .{ .elements_per_block = 256, .bytes_per_block = 176 }, // Q5_K
        14 => .{ .elements_per_block = 256, .bytes_per_block = 210 }, // Q6_K
        15 => .{ .elements_per_block = 256, .bytes_per_block = 292 }, // Q8_K
        24 => .{ .elements_per_block = 1, .bytes_per_block = 1 }, // I8
        25 => .{ .elements_per_block = 1, .bytes_per_block = 2 }, // I16
        26 => .{ .elements_per_block = 1, .bytes_per_block = 4 }, // I32
        27 => .{ .elements_per_block = 1, .bytes_per_block = 8 }, // I64
        28 => .{ .elements_per_block = 1, .bytes_per_block = 8 }, // F64
        30 => .{ .elements_per_block = 1, .bytes_per_block = 2 }, // BF16
        else => null,
    };
}

/// Parse and validate a complete GGUF v3 index without reading tensor data.
pub fn parse(comptime tensor_capacity: usize, source: Source, out: *Index(tensor_capacity)) Error!void {
    out.* = .{};
    var cursor = Cursor{ .source = source };
    var magic: [4]u8 = undefined;
    try cursor.readBytes(&magic);
    if (!mem.eql(u8, &magic, "GGUF")) return error.InvalidMagic;

    const version = try cursor.readU32();
    if (version != 3) return error.UnsupportedVersion;
    const tensor_count = try cursor.readU64();
    const metadata_count = try cursor.readU64();
    if (tensor_count > tensor_capacity) return error.TooManyTensors;

    out.summary.version = version;
    out.summary.tensor_count = tensor_count;
    out.summary.metadata_count = metadata_count;

    var metadata_index: u64 = 0;
    while (metadata_index < metadata_count) : (metadata_index += 1) {
        const key_length = try cursor.readU64();
        if (key_length == 0 or key_length > MAX_KEY_BYTES) return error.InvalidMetadataKey;
        const key = KeyRef{ .offset = cursor.position, .length = key_length };
        try validateKey(source, key);
        try cursor.skip(key_length);
        const value_type = metadataType(try cursor.readU32()) orelse return error.InvalidMetadataType;
        try consumeMetadataValue(&cursor, value_type, 0, key, &out.summary);
    }

    out.tensor_count = @intCast(tensor_count);
    for (out.tensors[0..out.tensor_count]) |*tensor| {
        const name_length = try cursor.readU64();
        if (name_length == 0 or name_length > tensor.name.len) return error.InvalidTensorName;
        tensor.name_len = @intCast(name_length);
        try cursor.readBytes(tensor.name[0..tensor.name_len]);
        const dimensions = try cursor.readU32();
        if (dimensions == 0 or dimensions > tensor.dimensions.len) return error.InvalidTensorShape;
        tensor.dimension_count = @intCast(dimensions);
        for (tensor.dimensions[0..tensor.dimension_count]) |*dimension| {
            dimension.* = try cursor.readU64();
            if (dimension.* == 0) return error.InvalidTensorShape;
        }
        tensor.ggml_type = try cursor.readU32();
        tensor.relative_offset = try cursor.readU64();
    }

    const alignment = out.summary.alignment;
    if (alignment < 8 or alignment % 8 != 0) return error.InvalidAlignment;
    const data_offset = try alignForward(cursor.position, alignment);
    if (data_offset > source.size) return error.UnexpectedEof;
    out.summary.data_offset = data_offset;

    for (out.tensors[0..out.tensor_count], 0..) |*tensor, tensor_index| {
        if (tensor.relative_offset % alignment != 0) return error.InvalidTensorOffset;
        const traits = typeTraits(tensor.ggml_type) orelse return error.UnsupportedTensorType;
        if (tensor.dimensions[0] % traits.elements_per_block != 0) return error.InvalidTensorShape;

        var element_count: u64 = 1;
        for (tensor.dimensions[0..tensor.dimension_count]) |dimension| {
            element_count = try checkedMultiply(element_count, dimension);
        }
        if (element_count % traits.elements_per_block != 0) return error.InvalidTensorShape;
        const blocks = element_count / traits.elements_per_block;
        tensor.byte_size = try checkedMultiply(blocks, traits.bytes_per_block);
        tensor.file_offset = try checkedAdd(data_offset, tensor.relative_offset);
        const tensor_end = try checkedAdd(tensor.file_offset, tensor.byte_size);
        if (tensor_end > source.size) return error.UnexpectedEof;

        for (out.tensors[0..tensor_index]) |*prior| {
            const prior_end = try checkedAdd(prior.file_offset, prior.byte_size);
            if (tensor.file_offset < prior_end and prior.file_offset < tensor_end) {
                return error.OverlappingTensors;
            }
        }
    }
}

fn consumeMetadataValue(
    cursor: *Cursor,
    value_type: MetadataType,
    depth: u8,
    key: ?KeyRef,
    summary: *Summary,
) Error!void {
    switch (value_type) {
        .uint8, .int8 => try cursor.skip(1),
        .uint16, .int16 => try cursor.skip(2),
        .uint32 => {
            const value = try cursor.readU32();
            if (key) |present| recordInteger(cursor.source, present, value, summary);
        },
        .int32 => try cursor.skip(4),
        .float32 => {
            const value: f32 = @bitCast(try cursor.readU32());
            if (key) |present| recordFloat(cursor.source, present, value, summary);
        },
        .boolean => if (try cursor.readU8() > 1) return error.InvalidMetadataValue,
        .string => {
            const length = try cursor.readU64();
            if (length > MAX_STRING_BYTES) return error.MetadataLimit;
            if (key) |present| {
                if (try keyEquals(cursor.source, present, "general.architecture")) {
                    if (length == 0 or length > summary.architecture.len) return error.InvalidMetadataValue;
                    summary.architecture_len = @intCast(length);
                    try cursor.readBytes(summary.architecture[0..summary.architecture_len]);
                    if (!validArchitecture(summary.architectureSlice())) return error.InvalidMetadataValue;
                    return;
                }
            }
            try cursor.skip(length);
        },
        .array => {
            if (depth == MAX_ARRAY_DEPTH) return error.MetadataLimit;
            const element_type = metadataType(try cursor.readU32()) orelse return error.InvalidMetadataType;
            const count = try cursor.readU64();
            if (count > MAX_ARRAY_ITEMS) return error.MetadataLimit;
            if (key) |present| try recordArray(cursor.source, present, element_type, count, cursor.position, summary);
            if (primitiveWidth(element_type)) |width| {
                try cursor.skip(try checkedMultiply(count, width));
            } else {
                var index: u64 = 0;
                while (index < count) : (index += 1) {
                    try consumeMetadataValue(cursor, element_type, depth + 1, null, summary);
                }
            }
        },
        .uint64 => {
            const value = try cursor.readU64();
            if (key) |present| recordInteger(cursor.source, present, value, summary);
        },
        .int64, .float64 => try cursor.skip(8),
    }
}

fn recordArray(
    source: Source,
    key: KeyRef,
    element_type: MetadataType,
    count: u64,
    data_offset: u64,
    summary: *Summary,
) Error!void {
    const value = ArrayRef{
        .present = true,
        .element_type = @intFromEnum(element_type),
        .count = count,
        .data_offset = data_offset,
    };
    if (try keyEquals(source, key, "tokenizer.ggml.tokens")) {
        summary.tokenizer_tokens = value;
    } else if (try keyEquals(source, key, "tokenizer.ggml.merges")) {
        summary.tokenizer_merges = value;
    } else if (try keyEquals(source, key, "tokenizer.ggml.scores")) {
        summary.tokenizer_scores = value;
    } else if (try keyEquals(source, key, "tokenizer.ggml.token_type")) {
        summary.tokenizer_token_types = value;
    }
}

fn recordInteger(source: Source, key: KeyRef, value: u64, summary: *Summary) void {
    if (keyEquals(source, key, "general.alignment") catch false) {
        if (value <= math.maxInt(u32)) summary.alignment = @intCast(value) else summary.alignment = 0;
    } else if (keyEndsWith(source, key, ".context_length") catch false) {
        summary.context_length = value;
    } else if (keyEndsWith(source, key, ".embedding_length") catch false) {
        summary.embedding_length = value;
    } else if (keyEndsWith(source, key, ".block_count") catch false) {
        summary.block_count = value;
    } else if (keyEndsWith(source, key, ".attention.head_count_kv") catch false) {
        summary.head_count_kv = value;
    } else if (keyEndsWith(source, key, ".attention.head_count") catch false) {
        summary.head_count = value;
    } else if (keyEndsWith(source, key, ".attention.key_length") catch false) {
        summary.attention_key_length = value;
    } else if (keyEndsWith(source, key, ".attention.value_length") catch false) {
        summary.attention_value_length = value;
    } else if (keyEndsWith(source, key, ".feed_forward_length") catch false) {
        summary.feed_forward_length = value;
    } else if (keyEndsWith(source, key, ".vocab_size") catch false) {
        summary.vocab_size = value;
    }
}

fn recordFloat(source: Source, key: KeyRef, value: f32, summary: *Summary) void {
    if (keyEndsWith(source, key, ".rope.freq_base") catch false) {
        summary.rope_frequency_base = value;
    } else if (keyEndsWith(source, key, ".attention.layer_norm_rms_epsilon") catch false) {
        summary.rms_norm_epsilon = value;
    }
}

fn primitiveWidth(value_type: MetadataType) ?u64 {
    return switch (value_type) {
        .uint8, .int8 => 1,
        .uint16, .int16 => 2,
        .uint32, .int32, .float32 => 4,
        .uint64, .int64, .float64 => 8,
        // Boolean values must be validated individually.
        .boolean, .string, .array => null,
    };
}

fn metadataType(raw: u32) ?MetadataType {
    return switch (raw) {
        0 => .uint8,
        1 => .int8,
        2 => .uint16,
        3 => .int16,
        4 => .uint32,
        5 => .int32,
        6 => .float32,
        7 => .boolean,
        8 => .string,
        9 => .array,
        10 => .uint64,
        11 => .int64,
        12 => .float64,
        else => null,
    };
}

fn validateKey(source: Source, key: KeyRef) Error!void {
    var position: u64 = 0;
    var previous_dot = true;
    var scratch: [64]u8 = undefined;
    while (position < key.length) {
        const count: usize = @intCast(@min(key.length - position, scratch.len));
        if (!source.read(try checkedAdd(key.offset, position), scratch[0..count])) return error.UnexpectedEof;
        for (scratch[0..count]) |byte| {
            const valid = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '.';
            if (!valid or (byte == '.' and previous_dot)) return error.InvalidMetadataKey;
            previous_dot = byte == '.';
        }
        position += count;
    }
    if (previous_dot) return error.InvalidMetadataKey;
}

fn validArchitecture(value: []const u8) bool {
    for (value) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9'))) return false;
    return value.len != 0;
}

fn keyEquals(source: Source, key: KeyRef, literal: []const u8) Error!bool {
    if (key.length != literal.len) return false;
    return bytesEqualAt(source, key.offset, literal);
}

fn keyEndsWith(source: Source, key: KeyRef, suffix: []const u8) Error!bool {
    if (key.length < suffix.len) return false;
    return bytesEqualAt(source, key.offset + key.length - suffix.len, suffix);
}

fn bytesEqualAt(source: Source, offset: u64, expected: []const u8) Error!bool {
    var position: usize = 0;
    var scratch: [64]u8 = undefined;
    while (position < expected.len) {
        const count = @min(expected.len - position, scratch.len);
        if (!source.read(try checkedAdd(offset, position), scratch[0..count])) return error.UnexpectedEof;
        if (!mem.eql(u8, scratch[0..count], expected[position..][0..count])) return false;
        position += count;
    }
    return true;
}

fn alignForward(value: u64, alignment: u32) Error!u64 {
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return checkedAdd(value, alignment - remainder);
}

fn checkedAdd(left: u64, right: anytype) Error!u64 {
    const converted: u64 = @intCast(right);
    const result = @addWithOverflow(left, converted);
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

fn checkedMultiply(left: u64, right: anytype) Error!u64 {
    const converted: u64 = @intCast(right);
    const result = @mulWithOverflow(left, converted);
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

const SliceSource = struct {
    bytes: []const u8,

    fn readAt(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const SliceSource = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start > self.bytes.len or destination.len > self.bytes.len - start) return false;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
        return true;
    }

    fn mapAt(context: *const anyopaque, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
        const self: *const SliceSource = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start > self.bytes.len or length > self.bytes.len - start) return null;
        const pointer = self.bytes.ptr + start;
        if (@intFromPtr(pointer) & (alignment - 1) != 0) return null;
        return pointer;
    }

    fn source(self: *const SliceSource) Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = readAt, .map_at = mapAt };
    }
};

const FixtureWriter = struct {
    bytes: [1024]u8 = @splat(0),
    position: usize = 0,

    fn put(self: *FixtureWriter, value: []const u8) void {
        @memcpy(self.bytes[self.position..][0..value.len], value);
        self.position += value.len;
    }

    fn putU32(self: *FixtureWriter, value: u32) void {
        mem.writeInt(u32, self.bytes[self.position..][0..4], value, .little);
        self.position += 4;
    }

    fn putU64(self: *FixtureWriter, value: u64) void {
        mem.writeInt(u64, self.bytes[self.position..][0..8], value, .little);
        self.position += 8;
    }

    fn string(self: *FixtureWriter, value: []const u8) void {
        self.putU64(value.len);
        self.put(value);
    }

    fn alignTo(self: *FixtureWriter, alignment: usize) void {
        self.position = mem.alignForward(self.position, alignment);
    }
};

fn basicFixture(dimension: u64, file_size: *usize) FixtureWriter {
    var writer = FixtureWriter{};
    writer.put("GGUF");
    writer.putU32(3);
    writer.putU64(1);
    writer.putU64(3);
    writer.string("general.architecture");
    writer.putU32(@intFromEnum(MetadataType.string));
    writer.string("qwen3vl");
    writer.string("general.alignment");
    writer.putU32(@intFromEnum(MetadataType.uint32));
    writer.putU32(32);
    writer.string("qwen3vl.block_count");
    writer.putU32(@intFromEnum(MetadataType.uint64));
    writer.putU64(28);
    writer.string("blk.0.attn_q.weight");
    writer.putU32(1);
    writer.putU64(dimension);
    writer.putU32(12);
    writer.putU64(0);
    writer.alignTo(32);
    file_size.* = writer.position + 144;
    writer.position = file_size.*;
    return writer;
}

