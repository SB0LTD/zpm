//! @zpm/vector-memory — exact, allocation-free semantic index.
//!
//! Vectors live in caller-selected, compile-time bounded inline storage.  Every
//! record is tied to a canonical event and to an encoder/schema domain; a
//! vector can suggest relevance but never becomes an authoritative fact.

const math = @import("sig_math");
const mem = @import("sig_mem");
const testing = @import("sig_testing");

pub const Error = error{
    CapacityExhausted,
    DuplicateEvent,
    InvalidEvent,
    InvalidDimension,
    InvalidDomain,
    InvalidConfidence,
    InvalidQuery,
    NonFinite,
    ZeroNorm,
};

pub const Privacy = enum(u8) {
    public,
    personal,
    sensitive,
    secret,
};

pub const Domain = struct {
    encoder: [16]u8,
    schema: [16]u8,

    pub fn eql(left: Domain, right: Domain) bool {
        return mem.eql(u8, &left.encoder, &right.encoder) and
            mem.eql(u8, &left.schema, &right.schema);
    }

    pub fn valid(self: Domain) bool {
        return !allZero(&self.encoder) and !allZero(&self.schema);
    }
};

pub const Metadata = struct {
    event_id: u64 = 0,
    payload_digest: [16]u8 = @splat(0),
    domain: Domain = .{ .encoder = @splat(0), .schema = @splat(0) },
    privacy: Privacy = .public,
    confidence_q16: u16 = 0,
    epoch: u64 = 0,
    norm: f32 = 0,
};

pub const Candidate = struct {
    event_id: u64,
    payload_digest: [16]u8,
    domain: Domain,
    privacy: Privacy,
    confidence_q16: u16,
    epoch: u64,
    vector: []const f32,
};

pub const Filter = struct {
    domain: Domain,
    maximum_privacy: Privacy = .secret,
    minimum_epoch: u64 = 0,
    minimum_confidence_q16: u16 = 0,
};

pub const Result = struct {
    event_id: u64,
    score: f32,
    confidence_q16: u16,
    epoch: u64,
    privacy: Privacy,
};

pub const SearchReceipt = struct {
    slots_examined: usize = 0,
    records_compared: usize = 0,
    vector_lanes_decoded: usize = 0,
    multiplications: usize = 0,
    additions: usize = 0,
    divisions: usize = 0,
    results: usize = 0,

    pub fn arithmeticOperations(self: SearchReceipt) usize {
        return self.multiplications + self.additions + self.divisions;
    }
};

const SlotState = enum(u8) { empty, writing, live, tombstone };

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

pub inline fn f32ToF16Bits(value: f32) u16 {
    const half: f16 = @floatCast(value);
    return @bitCast(half);
}

pub inline fn f16BitsToF32(value: u16) f32 {
    const half: f16 = @bitCast(value);
    return @floatCast(half);
}

pub fn Store(comptime capacity: usize, comptime dimension: usize) type {
    if (capacity == 0) @compileError("vector store capacity must be non-zero");
    if (dimension == 0) @compileError("vector dimension must be non-zero");

    return struct {
        const Self = @This();
        const Slot = struct {
            state: SlotState = .empty,
            metadata: Metadata = .{},
            vector: [dimension]u16 = @splat(0),
        };

        slots: [capacity]Slot = @splat(.{}),
        live_count: usize = 0,
        tombstone_count: usize = 0,

        pub fn staticBytes() usize {
            return @sizeOf(Self);
        }

        pub fn maximumRecords() usize {
            return capacity;
        }

        pub fn dimensions() usize {
            return dimension;
        }

        pub fn count(self: *const Self) usize {
            return self.live_count;
        }

        /// Insert is fail-atomic: all fields and every vector lane are checked
        /// and converted into stack scratch before a destination slot changes.
        pub fn insert(self: *Self, candidate: Candidate) Error!void {
            if (candidate.event_id == 0 or candidate.epoch == 0 or allZero(&candidate.payload_digest))
                return error.InvalidEvent;
            if (!candidate.domain.valid()) return error.InvalidDomain;
            if (candidate.vector.len != dimension) return error.InvalidDimension;
            if (candidate.confidence_q16 == 0) return error.InvalidConfidence;

            var converted: [dimension]u16 = undefined;
            var squared_norm: f64 = 0;
            for (candidate.vector, 0..) |value, lane| {
                if (!math.isFinite(value)) return error.NonFinite;
                converted[lane] = f32ToF16Bits(value);
                const restored = f16BitsToF32(converted[lane]);
                if (!math.isFinite(restored)) return error.NonFinite;
                squared_norm += @as(f64, restored) * @as(f64, restored);
            }
            if (!math.isFiniteF64(squared_norm) or squared_norm <= 0) return error.ZeroNorm;
            const norm: f32 = @floatCast(@sqrt(squared_norm));

            var destination: ?usize = null;
            var tombstone: ?usize = null;
            for (self.slots, 0..) |slot, index| switch (slot.state) {
                .live => {
                    if (slot.metadata.event_id == candidate.event_id and slot.metadata.domain.eql(candidate.domain))
                        return error.DuplicateEvent;
                },
                .empty => {
                    if (destination == null) destination = index;
                },
                .tombstone => {
                    if (tombstone == null) tombstone = index;
                },
                .writing => {},
            };
            const index = destination orelse tombstone orelse return error.CapacityExhausted;
            const reused_tombstone = self.slots[index].state == .tombstone;

            self.slots[index].state = .writing;
            self.slots[index].vector = converted;
            self.slots[index].metadata = .{
                .event_id = candidate.event_id,
                .payload_digest = candidate.payload_digest,
                .domain = candidate.domain,
                .privacy = candidate.privacy,
                .confidence_q16 = candidate.confidence_q16,
                .epoch = candidate.epoch,
                .norm = norm,
            };
            self.slots[index].state = .live;
            self.live_count += 1;
            if (reused_tombstone) self.tombstone_count -= 1;
        }

        pub fn eraseEvent(self: *Self, event_id: u64) usize {
            if (event_id == 0) return 0;
            var erased: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.state == .live and slot.metadata.event_id == event_id) {
                    slot.state = .tombstone;
                    slot.metadata = .{};
                    @memset(&slot.vector, 0);
                    erased += 1;
                }
            }
            self.live_count -= erased;
            self.tombstone_count += erased;
            return erased;
        }

        pub fn eraseAtOrAbovePrivacy(self: *Self, threshold: Privacy) usize {
            var erased: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.state == .live and @intFromEnum(slot.metadata.privacy) >= @intFromEnum(threshold)) {
                    slot.state = .tombstone;
                    slot.metadata = .{};
                    @memset(&slot.vector, 0);
                    erased += 1;
                }
            }
            self.live_count -= erased;
            self.tombstone_count += erased;
            return erased;
        }

        /// Exact cosine top-K.  Results are ordered by descending score and
        /// then ascending event ID, so equal-score replay is deterministic.
        pub fn search(
            self: *const Self,
            query: []const f32,
            filter: Filter,
            output: []Result,
        ) Error!SearchReceipt {
            if (query.len != dimension or output.len == 0) return error.InvalidQuery;
            if (!filter.domain.valid()) return error.InvalidDomain;

            var receipt = SearchReceipt{};
            var query_squared_norm: f64 = 0;
            for (query) |value| {
                if (!math.isFinite(value)) return error.NonFinite;
                query_squared_norm += @as(f64, value) * @as(f64, value);
                receipt.multiplications += 1;
                receipt.additions += 1;
            }
            if (!math.isFiniteF64(query_squared_norm) or query_squared_norm <= 0) return error.ZeroNorm;
            const query_norm: f32 = @floatCast(@sqrt(query_squared_norm));

            var result_count: usize = 0;
            for (self.slots) |slot| {
                receipt.slots_examined += 1;
                if (slot.state != .live or
                    !slot.metadata.domain.eql(filter.domain) or
                    @intFromEnum(slot.metadata.privacy) > @intFromEnum(filter.maximum_privacy) or
                    slot.metadata.epoch < filter.minimum_epoch or
                    slot.metadata.confidence_q16 < filter.minimum_confidence_q16) continue;

                receipt.records_compared += 1;
                var dot: f64 = 0;
                for (query, slot.vector) |query_value, stored_bits| {
                    dot += @as(f64, query_value) * @as(f64, f16BitsToF32(stored_bits));
                    receipt.vector_lanes_decoded += 1;
                    receipt.multiplications += 1;
                    receipt.additions += 1;
                }
                const denominator = query_norm * slot.metadata.norm;
                receipt.multiplications += 1;
                receipt.divisions += 1;
                const score: f32 = @floatCast(dot / denominator);
                const result = Result{
                    .event_id = slot.metadata.event_id,
                    .score = score,
                    .confidence_q16 = slot.metadata.confidence_q16,
                    .epoch = slot.metadata.epoch,
                    .privacy = slot.metadata.privacy,
                };
                insertResult(output, &result_count, result);
            }
            receipt.results = result_count;
            return receipt;
        }

        fn insertResult(output: []Result, result_count: *usize, candidate: Result) void {
            var position: usize = 0;
            while (position < result_count.* and !better(candidate, output[position])) : (position += 1) {}
            if (position >= output.len) return;
            const new_count = @min(result_count.* + 1, output.len);
            var cursor = new_count - 1;
            while (cursor > position) : (cursor -= 1) output[cursor] = output[cursor - 1];
            output[position] = candidate;
            result_count.* = new_count;
        }

        fn better(left: Result, right: Result) bool {
            return left.score > right.score or
                (left.score == right.score and left.event_id < right.event_id);
        }
    };
}



fn testDomain(seed: u8) Domain {
    return .{ .encoder = @splat(seed), .schema = @splat(seed +% 1) };
}

fn testDigest(seed: u8) [16]u8 {
    return @splat(seed);
}

test "insert is fail-atomic and rejects duplicate canonical events" {
    const Index = Store(2, 3);
    var index = Index{};
    const valid = [_]f32{ 1, 0, 0 };
    try index.insert(.{
        .event_id = 7,
        .payload_digest = testDigest(7),
        .domain = testDomain(1),
        .privacy = .personal,
        .confidence_q16 = 60_000,
        .epoch = 1,
        .vector = &valid,
    });
    try testing.expectEqual(@as(usize, 1), index.count());
    try testing.expectError(error.DuplicateEvent, index.insert(.{
        .event_id = 7,
        .payload_digest = testDigest(8),
        .domain = testDomain(1),
        .privacy = .public,
        .confidence_q16 = 1,
        .epoch = 2,
        .vector = &valid,
    }));
    const invalid = [_]f32{ 0, (0.0 / @as(f32, 0.0)), 0 };
    try testing.expectError(error.NonFinite, index.insert(.{
        .event_id = 8,
        .payload_digest = testDigest(8),
        .domain = testDomain(1),
        .privacy = .public,
        .confidence_q16 = 1,
        .epoch = 2,
        .vector = &invalid,
    }));
    try testing.expectEqual(@as(usize, 1), index.count());
}

test "exact top-K is deterministic and domain separated" {
    const Index = Store(4, 3);
    var index = Index{};
    const first = [_]f32{ 1, 0, 0 };
    const second = [_]f32{ 1, 0, 0 };
    const other_domain = [_]f32{ 100, 0, 0 };
    try index.insert(.{ .event_id = 9, .payload_digest = testDigest(9), .domain = testDomain(2), .privacy = .public, .confidence_q16 = 9, .epoch = 1, .vector = &first });
    try index.insert(.{ .event_id = 3, .payload_digest = testDigest(3), .domain = testDomain(2), .privacy = .public, .confidence_q16 = 3, .epoch = 2, .vector = &second });
    try index.insert(.{ .event_id = 1, .payload_digest = testDigest(1), .domain = testDomain(8), .privacy = .public, .confidence_q16 = 1, .epoch = 3, .vector = &other_domain });

    var results: [2]Result = undefined;
    const receipt = try index.search(&first, .{ .domain = testDomain(2) }, &results);
    if (receipt.results != 2) return error.TestUnexpectedResult;
    if (results[0].event_id != 3) return error.TestUnexpectedResult;
    if (results[1].event_id != 9) return error.TestUnexpectedResult;
    if (receipt.records_compared != 2) return error.TestUnexpectedResult;
    if (receipt.vector_lanes_decoded != 3 * 2) return error.TestUnexpectedResult;
}

test "privacy erasure zeroes live capacity and tombstones are reusable" {
    const Index = Store(2, 2);
    var index = Index{};
    const vector = [_]f32{ 0, 1 };
    try index.insert(.{ .event_id = 1, .payload_digest = testDigest(1), .domain = testDomain(1), .privacy = .secret, .confidence_q16 = 1, .epoch = 1, .vector = &vector });
    try testing.expectEqual(@as(usize, 1), index.eraseAtOrAbovePrivacy(.sensitive));
    try testing.expectEqual(@as(usize, 0), index.count());
    try index.insert(.{ .event_id = 2, .payload_digest = testDigest(2), .domain = testDomain(1), .privacy = .public, .confidence_q16 = 1, .epoch = 2, .vector = &vector });
    try testing.expectEqual(@as(usize, 1), index.eraseEvent(2));
    try testing.expectEqual(@as(usize, 0), index.eraseEvent(2));
}

test "one event may carry independent encoder domains" {
    const Index = Store(2, 2);
    var index = Index{};
    const vector = [_]f32{ 1, 1 };
    try index.insert(.{ .event_id = 4, .payload_digest = testDigest(4), .domain = testDomain(1), .privacy = .public, .confidence_q16 = 1, .epoch = 1, .vector = &vector });
    try index.insert(.{ .event_id = 4, .payload_digest = testDigest(4), .domain = testDomain(2), .privacy = .public, .confidence_q16 = 1, .epoch = 1, .vector = &vector });
    try testing.expectEqual(@as(usize, 2), index.count());
    try testing.expectEqual(@as(usize, 2), index.eraseEvent(4));
}

test "static memory is an exact compile-time receipt" {
    const Tiny = Store(3, 5);
    try testing.expectEqual(@sizeOf(Tiny), Tiny.staticBytes());
    try testing.expectEqual(@as(usize, 3), Tiny.maximumRecords());
    try testing.expectEqual(@as(usize, 5), Tiny.dimensions());
    try testing.expect(Tiny.staticBytes() >= 3 * 5 * @sizeOf(u16));
}
