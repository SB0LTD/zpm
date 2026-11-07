//! Optional compact snapshots for interleaved prompt families. The caller owns
//! every byte; entries are exclusive to one model/runtime/backend configuration.
//! Tokens are compared after key lookup. A key alone never admits cached KV.
const std = @import("std");
pub const Error = error{ InvalidShape, Capacity, AliasedStorage, InvalidSnapshot };
pub const Shape = struct { layers: usize, heads: usize, head_size: usize, context: usize };
pub const Entry = struct {
    tokens: []u32,
    kv: []u16,
    // Managed by Cache after init; callers must not mutate active descriptors.
    count: usize = 0,
    key: [32]u8 = @splat(0),
};
pub const Cache = struct {
    entries: []Entry,
    shape: Shape,
    active: []u16,
    next: usize = 0,

    pub fn init(entries: []Entry, shape: Shape, active: []u16, prompt: []u32) Error!Cache {
        if (entries.len == 0) return error.Capacity;
        const required = try elements(shape, shape.context);
        if (active.len < required) return error.Capacity;
        const metadata = std.mem.sliceAsBytes(entries);
        const live = std.mem.sliceAsBytes(active);
        const ids = std.mem.sliceAsBytes(prompt);
        if (overlap(metadata, live) or overlap(metadata, ids) or overlap(live, ids)) return error.AliasedStorage;
        for (entries, 0..) |entry, i| {
            if (entry.tokens.len == 0 or entry.tokens.len > shape.context or entry.kv.len < try elements(shape, entry.tokens.len)) return error.Capacity;
            const token_bytes = std.mem.sliceAsBytes(entry.tokens);
            const kv_bytes = std.mem.sliceAsBytes(entry.kv);
            for ([_][]const u8{ metadata, live, ids }) |reserved|
                if (overlap(token_bytes, reserved) or overlap(kv_bytes, reserved)) return error.AliasedStorage;
            if (overlap(token_bytes, kv_bytes)) return error.AliasedStorage;
            for (entries[0..i]) |prior| {
                for ([_][]const u8{ std.mem.sliceAsBytes(prior.tokens), std.mem.sliceAsBytes(prior.kv) }) |other|
                    if (overlap(token_bytes, other) or overlap(kv_bytes, other)) return error.AliasedStorage;
            }
        }
        var result = Cache{ .entries = entries, .shape = shape, .active = active };
        result.invalidate();
        return result;
    }
    pub fn invalidate(self: *Cache) void {
        for (self.entries) |*entry| entry.count = 0;
        self.next = 0;
    }
    /// Restore only a longer verified common prefix. Suffix slots are untouched;
    /// causal attention must still obey the caller's actual token position.
    pub fn restore(self: *Cache, key: *const [32]u8, tokens: []const u32, minimum: usize) Error!usize {
        if (tokens.len > self.shape.context or minimum > tokens.len) return error.Capacity;
        var best = minimum;
        var chosen: ?*Entry = null;
        for (self.entries) |*entry| {
            if (entry.count > entry.tokens.len or entry.tokens.len > self.shape.context or entry.kv.len < try elements(self.shape, entry.tokens.len)) return error.InvalidSnapshot;
            if (entry.count == 0 or !std.mem.eql(u8, &entry.key, key)) continue;
            var common: usize = 0;
            while (common < @min(entry.count, tokens.len) and tokens[common] == entry.tokens[common]) : (common += 1) {}
            if (common > best) { best = common; chosen = entry; }
        }
        if (chosen) |entry| copy(self.shape, self.active, self.shape.context, entry.kv, entry.tokens.len, best);
        return best;
    }
    /// Keep the latest bounded prefix per key. Full live KV/logits are retained
    /// separately by the executor; these snapshots do not cache answer logits.
    pub fn store(self: *Cache, key: *const [32]u8, tokens: []const u32) Error!void {
        if (tokens.len == 0 or tokens.len > self.shape.context) return error.Capacity;
        const token_bytes = std.mem.sliceAsBytes(tokens);
        if (overlap(token_bytes, std.mem.sliceAsBytes(self.entries)) or overlap(token_bytes, std.mem.sliceAsBytes(self.active))) return error.AliasedStorage;
        for (self.entries) |entry| {
            if (overlap(token_bytes, std.mem.sliceAsBytes(entry.tokens)) or overlap(token_bytes, std.mem.sliceAsBytes(entry.kv))) return error.AliasedStorage;
        }
        var chosen: ?*Entry = null;
        for (self.entries) |*entry| if (entry.count != 0 and std.mem.eql(u8, &entry.key, key)) { chosen = entry; break; };
        if (chosen == null) for (self.entries) |*entry| if (entry.count == 0) { chosen = entry; break; };
        if (chosen == null) {
            chosen = &self.entries[self.next];
            self.next = (self.next + 1) % self.entries.len;
        }
        const entry = chosen.?;
        if (entry.tokens.len == 0 or entry.tokens.len > self.shape.context or entry.kv.len < try elements(self.shape, entry.tokens.len)) return error.InvalidSnapshot;
        const count = @min(tokens.len, entry.tokens.len);
        copy(self.shape, entry.kv, entry.tokens.len, self.active, self.shape.context, count);
        @memcpy(entry.tokens[0..count], tokens[0..count]);
        entry.key = key.*;
        entry.count = count;
    }
};
fn elements(shape: Shape, context: usize) Error!usize {
    if (shape.layers == 0 or shape.heads == 0 or shape.head_size == 0 or shape.context == 0) return error.InvalidShape;
    var total: usize = 2;
    for ([_]usize{ shape.layers, shape.heads, shape.head_size, context }) |factor| {
        const value = @mulWithOverflow(total, factor);
        if (value[1] != 0) return error.InvalidShape;
        total = value[0];
    }
    return total;
}
fn overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const a = @intFromPtr(left.ptr);
    const b = @intFromPtr(right.ptr);
    return if (a <= b) b - a < left.len else a - b < right.len;
}
fn copy(shape: Shape, destination: []u16, destination_context: usize, source: []const u16, source_context: usize, count: usize) void {
    for (0..shape.layers * 2 * shape.heads) |head| {
        const to = head * destination_context * shape.head_size;
        const from = head * source_context * shape.head_size;
        @memcpy(destination[to..][0 .. count * shape.head_size], source[from..][0 .. count * shape.head_size]);
    }
}

test "interleaved KV snapshots restore exact prefix across every layer value head and stride" {
    const shape = Shape{ .layers = 2, .heads = 2, .head_size = 3, .context = 8 };
    var live: [384]u16 = undefined;
    for (&live, 0..) |*value, i| value.* = @intCast(i + 1);
    const original = live;
    var prompt: [8]u32 = undefined;
    var ids: [2][3]u32 = undefined;
    var saved: [2][144]u16 = undefined;
    var entries = [_]Entry{ .{ .tokens = &ids[0], .kv = &saved[0] }, .{ .tokens = &ids[1], .kv = &saved[1] } };
    var cache = try Cache.init(&entries, shape, &live, &prompt);
    const first: [32]u8 = @splat(1);
    const second: [32]u8 = @splat(2);
    try cache.store(&first, &.{ 10, 11, 12, 13 });
    @memset(&live, 999);
    try cache.store(&second, &.{ 20, 21 });
    try std.testing.expectEqual(@as(usize, 1), try cache.restore(&first, &.{ 10, 99 }, 1));
    // Existing prefix length wins if no snapshot extends it.
    try std.testing.expectEqual(@as(usize, 1), try cache.restore(&second, &.{ 99 }, 1));
    try std.testing.expectEqual(@as(usize, 2), try cache.restore(&first, &.{ 10, 11, 77 }, 0));
    for (0..8) |head| for (0..24) |lane| {
        const at = head * 24 + lane;
        try std.testing.expectEqual(if (lane < 6) original[at] else @as(u16, 999), live[at]);
    };
    cache.invalidate();
    try std.testing.expectEqual(@as(usize, 0), try cache.restore(&first, &.{ 10, 11 }, 0));
}

test "prefix snapshots reject storage overlap capacity overflow and corrupt metadata" {
    var live: [16]u16 = undefined;
    var ids: [4]u32 = undefined;
    var tokens: [2]u32 = undefined;
    var saved: [8]u16 = undefined;
    var entries = [_]Entry{.{ .tokens = &tokens, .kv = &saved, .count = 123 }};
    const shape = Shape{ .layers = 1, .heads = 1, .head_size = 2, .context = 4 };
    try std.testing.expectError(error.Capacity, Cache.init(&entries, shape, live[0..15], &ids));
    try std.testing.expectEqual(@as(usize, 123), entries[0].count);
    entries[0].kv = live[0..8];
    try std.testing.expectError(error.AliasedStorage, Cache.init(&entries, shape, &live, &ids));
    entries[0].kv = &saved;
    var cache = try Cache.init(&entries, shape, &live, &ids);
    entries[0].count = 3;
    try std.testing.expectError(error.InvalidSnapshot, cache.restore(&@splat(0), &.{1}, 0));
    try std.testing.expectError(error.InvalidShape, elements(.{ .layers = std.math.maxInt(usize), .heads = 1, .head_size = 1, .context = 1 }, 1));
}

test "bounded snapshot eviction never confuses keys or truncated token prefixes" {
    var active: [8]u16 = @splat(7);
    var prompt: [4]u32 = undefined;
    var tokens: [1]u32 = undefined;
    var saved: [2]u16 = undefined;
    var entries = [_]Entry{.{ .tokens = &tokens, .kv = &saved }};
    var cache = try Cache.init(&entries, .{ .layers = 1, .heads = 1, .head_size = 1, .context = 4 }, &active, &prompt);
    const first: [32]u8 = @splat(1);
    const second: [32]u8 = @splat(2);
    try cache.store(&first, &.{ 40, 41 });
    try std.testing.expectEqual(@as(usize, 1), entries[0].count);
    try cache.store(&second, &.{ 50, 51 });
    try std.testing.expectEqual(@as(usize, 0), try cache.restore(&first, &.{40}, 0));
    try std.testing.expectEqual(@as(usize, 0), try cache.restore(&second, &.{40}, 0));
    try std.testing.expectEqual(@as(usize, 1), try cache.restore(&second, &.{ 50, 99 }, 0));
    try std.testing.expectError(error.Capacity, cache.restore(&second, &.{50}, 2));
    try std.testing.expectError(error.AliasedStorage, cache.store(&second, &tokens));
}
