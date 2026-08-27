//! Bounded, allocation-free vocabulary index over GGUF model storage.
//!
//! Token bytes remain in the authenticated GGUF artifact. The index stores
//! only offsets, lengths, hashes, and token ids, avoiding Gotliv's 32+ MiB
//! fixed token-text copy while retaining exact collision checks.

const gguf = @import("gguf.sig");

pub const Error = error{
    MissingVocabulary,
    InvalidVocabularyType,
    VocabularyCapacity,
    HashCapacity,
    TokenTooLong,
    DuplicateToken,
    UnexpectedEof,
    InvalidToken,
    BufferTooSmall,
    MissingMerges,
    InvalidMergesType,
    MergeCapacity,
    MergeTooLong,
    InvalidMerge,
    UnknownMergeToken,
    DuplicateMerge,
};

pub const Merge = struct { rank: u32, result_token: u32 };

/// Pair-to-rank table compiled once from `tokenizer.ggml.merges`. The merged
/// result id is resolved during construction so the hot BPE loop performs no
/// storage reads and no string concatenation.
pub fn MergeIndex(comptime hash_capacity: usize, comptime maximum_merge_bytes: usize) type {
    if (hash_capacity == 0 or (hash_capacity & (hash_capacity - 1)) != 0)
        @compileError("merge hash capacity must be a non-zero power of two");
    if (maximum_merge_bytes < 3) @compileError("merge scratch must hold two tokens and a separator");

    return struct {
        const Self = @This();
        pair_keys: [hash_capacity]u64 = @splat(0),
        rank_plus_one: [hash_capacity]u32 = @splat(0),
        result_tokens: [hash_capacity]u32 = @splat(0),
        count: usize = 0,

        pub fn staticBytes() usize { return @sizeOf(Self); }

        pub fn build(
            self: *Self,
            source: gguf.Source,
            merges: gguf.ArrayRef,
            vocabulary: anytype,
        ) Error!void {
            self.* = .{};
            if (!merges.present) return error.MissingMerges;
            if (merges.element_type != 8) return error.InvalidMergesType;
            if (merges.count > (hash_capacity * 3) / 4 or merges.count > math.maxInt(u32))
                return error.MergeCapacity;

            var position = merges.data_offset;
            var rank: u32 = 0;
            var scratch: [maximum_merge_bytes]u8 = undefined;
            var combined: [maximum_merge_bytes]u8 = undefined;
            while (rank < merges.count) : (rank += 1) {
                const length = try readU64(source, position);
                position = try add(position, 8);
                if (length > scratch.len) return error.MergeTooLong;
                if (length > source.size or position > source.size - length) return error.UnexpectedEof;
                const merge_text = scratch[0..@as(usize, @intCast(length))];
                if (!source.read(position, merge_text)) return error.UnexpectedEof;
                position = try add(position, length);

                const separator = mem.indexOfScalar(u8, merge_text, ' ') orelse return error.InvalidMerge;
                if (separator == 0 or separator + 1 == merge_text.len or
                    mem.indexOfScalarPos(u8, merge_text, separator + 1, ' ') != null) return error.InvalidMerge;
                const left_text = merge_text[0..separator];
                const right_text = merge_text[separator + 1 ..];
                const left = vocabulary.lookup(source, left_text) orelse return error.UnknownMergeToken;
                const right = vocabulary.lookup(source, right_text) orelse return error.UnknownMergeToken;
                if (left_text.len + right_text.len > combined.len) return error.MergeTooLong;
                @memcpy(combined[0..left_text.len], left_text);
                @memcpy(combined[left_text.len..][0..right_text.len], right_text);
                const result = vocabulary.lookup(source, combined[0 .. left_text.len + right_text.len]) orelse
                    return error.UnknownMergeToken;
                try self.insert(left, right, rank, result);
            }
            self.count = @intCast(merges.count);
        }

        pub fn find(self: *const Self, left: u32, right: u32) ?Merge {
            const key = pairKey(left, right);
            var slot: usize = @intCast(pairHash(key) & (hash_capacity - 1));
            var probes: usize = 0;
            while (probes < hash_capacity) : (probes += 1) {
                const stored_rank = self.rank_plus_one[slot];
                if (stored_rank == 0) return null;
                if (self.pair_keys[slot] == key) return .{
                    .rank = stored_rank - 1,
                    .result_token = self.result_tokens[slot],
                };
                slot = (slot + 1) & (hash_capacity - 1);
            }
            return null;
        }

        fn insert(self: *Self, left: u32, right: u32, rank: u32, result: u32) Error!void {
            const key = pairKey(left, right);
            var slot: usize = @intCast(pairHash(key) & (hash_capacity - 1));
            var probes: usize = 0;
            while (probes < hash_capacity) : (probes += 1) {
                if (self.rank_plus_one[slot] == 0) {
                    self.pair_keys[slot] = key;
                    self.rank_plus_one[slot] = rank + 1;
                    self.result_tokens[slot] = result;
                    return;
                }
                if (self.pair_keys[slot] == key) return error.DuplicateMerge;
                slot = (slot + 1) & (hash_capacity - 1);
            }
            return error.MergeCapacity;
        }
    };
}

pub fn VocabularyIndex(comptime vocabulary_capacity: usize, comptime hash_capacity: usize) type {
    if (vocabulary_capacity == 0) @compileError("vocabulary capacity must be non-zero");
    if (hash_capacity == 0 or (hash_capacity & (hash_capacity - 1)) != 0)
        @compileError("token hash capacity must be a non-zero power of two");

    return struct {
        const Self = @This();

        token_offsets: [vocabulary_capacity]u64 = @splat(0),
        token_lengths: [vocabulary_capacity]u16 = @splat(0),
        slot_hashes: [hash_capacity]u64 = @splat(0),
        slot_token_plus_one: [hash_capacity]u32 = @splat(0),
        count: usize = 0,

        pub fn staticBytes() usize {
            return @sizeOf(Self);
        }

        pub fn build(self: *Self, source: gguf.Source, vocabulary: gguf.ArrayRef) Error!void {
            self.* = .{};
            if (!vocabulary.present) return error.MissingVocabulary;
            if (vocabulary.element_type != 8) return error.InvalidVocabularyType;
            if (vocabulary.count > vocabulary_capacity or vocabulary.count > math.maxInt(u32) - 1)
                return error.VocabularyCapacity;
            // Keep maximum linear-probe load at 75%.
            if (vocabulary.count > (hash_capacity * 3) / 4) return error.HashCapacity;

            var position = vocabulary.data_offset;
            var token_id: u32 = 0;
            while (token_id < vocabulary.count) : (token_id += 1) {
                const length = try readU64(source, position);
                position = try add(position, 8);
                if (length > math.maxInt(u16)) return error.TokenTooLong;
                if (length > source.size or position > source.size - length) return error.UnexpectedEof;
                const hash = try hashAt(source, position, length);
                try self.insert(source, hash, position, @intCast(length), token_id);
                self.token_offsets[token_id] = position;
                self.token_lengths[token_id] = @intCast(length);
                position = try add(position, length);
            }
            self.count = @intCast(vocabulary.count);
        }

        pub fn lookup(self: *const Self, source: gguf.Source, token: []const u8) ?u32 {
            if (token.len > math.maxInt(u16)) return null;
            const hash = hashBytes(token);
            var slot: usize = @intCast(hash & (hash_capacity - 1));
            var probes: usize = 0;
            while (probes < hash_capacity) : (probes += 1) {
                const plus_one = self.slot_token_plus_one[slot];
                if (plus_one == 0) return null;
                const token_id = plus_one - 1;
                if (self.slot_hashes[slot] == hash and self.token_lengths[token_id] == token.len and
                    equalAt(source, self.token_offsets[token_id], token) catch false) return token_id;
                slot = (slot + 1) & (hash_capacity - 1);
            }
            return null;
        }

        pub fn tokenLength(self: *const Self, token_id: u32) Error!usize {
            if (token_id >= self.count) return error.InvalidToken;
            return self.token_lengths[token_id];
        }

        pub fn copyToken(self: *const Self, source: gguf.Source, token_id: u32, destination: []u8) Error!usize {
            if (token_id >= self.count) return error.InvalidToken;
            const length = self.token_lengths[token_id];
            if (destination.len < length) return error.BufferTooSmall;
            if (!source.read(self.token_offsets[token_id], destination[0..length])) return error.UnexpectedEof;
            return length;
        }

        fn insert(self: *Self, source: gguf.Source, hash: u64, offset: u64, length: u16, token_id: u32) Error!void {
            var slot: usize = @intCast(hash & (hash_capacity - 1));
            var probes: usize = 0;
            while (probes < hash_capacity) : (probes += 1) {
                const plus_one = self.slot_token_plus_one[slot];
                if (plus_one == 0) {
                    self.slot_hashes[slot] = hash;
                    self.slot_token_plus_one[slot] = token_id + 1;
                    return;
                }
                const existing = plus_one - 1;
                if (self.slot_hashes[slot] == hash and self.token_lengths[existing] == length and
                    try rangesEqual(source, self.token_offsets[existing], offset, length)) return error.DuplicateToken;
                slot = (slot + 1) & (hash_capacity - 1);
            }
            return error.HashCapacity;
        }
    };
}

const math = @import("sig_math.sig");
const mem = @import("sig_mem.sig");
const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

fn hashBytes(bytes: []const u8) u64 {
    var hash = FNV_OFFSET;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= FNV_PRIME;
    }
    return hash;
}

inline fn pairKey(left: u32, right: u32) u64 {
    return (@as(u64, left) << 32) | right;
}

fn pairHash(key: u64) u64 {
    // SplitMix64 finalizer: bijective over u64 before table masking.
    var value = key +% 0x9e3779b97f4a7c15;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return value ^ (value >> 31);
}

fn hashAt(source: gguf.Source, offset: u64, length: u64) Error!u64 {
    var hash = FNV_OFFSET;
    var consumed: u64 = 0;
    var scratch: [64]u8 = undefined;
    while (consumed < length) {
        const count: usize = @intCast(@min(length - consumed, scratch.len));
        if (!source.read(try add(offset, consumed), scratch[0..count])) return error.UnexpectedEof;
        for (scratch[0..count]) |byte| {
            hash ^= byte;
            hash *%= FNV_PRIME;
        }
        consumed += count;
    }
    return hash;
}

fn equalAt(source: gguf.Source, offset: u64, expected: []const u8) Error!bool {
    var consumed: usize = 0;
    var scratch: [64]u8 = undefined;
    while (consumed < expected.len) {
        const count = @min(expected.len - consumed, scratch.len);
        if (!source.read(try add(offset, consumed), scratch[0..count])) return error.UnexpectedEof;
        if (!mem.eql(u8, scratch[0..count], expected[consumed..][0..count])) return false;
        consumed += count;
    }
    return true;
}

fn rangesEqual(source: gguf.Source, left: u64, right: u64, length: u64) Error!bool {
    var consumed: u64 = 0;
    var left_bytes: [64]u8 = undefined;
    var right_bytes: [64]u8 = undefined;
    while (consumed < length) {
        const count: usize = @intCast(@min(length - consumed, left_bytes.len));
        if (!source.read(try add(left, consumed), left_bytes[0..count]) or
            !source.read(try add(right, consumed), right_bytes[0..count])) return error.UnexpectedEof;
        if (!mem.eql(u8, left_bytes[0..count], right_bytes[0..count])) return false;
        consumed += count;
    }
    return true;
}

fn readU64(source: gguf.Source, offset: u64) Error!u64 {
    var bytes: [8]u8 = undefined;
    if (!source.read(offset, &bytes)) return error.UnexpectedEof;
    return mem.readInt(u64, &bytes, .little);
}

fn add(left: u64, right: anytype) Error!u64 {
    const result = @addWithOverflow(left, @as(u64, @intCast(right)));
    if (result[1] != 0) return error.UnexpectedEof;
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

    fn source(self: *const SliceSource) gguf.Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = readAt };
    }
};

