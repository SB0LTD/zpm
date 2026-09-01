//! @zpm/multimodal-now — schema-bound, budget-adaptive NOW feature fusion.
//!
//! Encoders do not share a coordinate system merely because their vectors have
//! equal length.  Every representation is therefore required to carry the same
//! admitted projection domain.  A VLM projector, audio adapter, or text model
//! may publish only after numerical parity proves its mapping into that domain.

const math = @import("sig_math");
const mem = @import("sig_mem");
const testing = @import("sig_testing");

pub const Q16_ONE: u16 = math.maxInt(u16);

pub const Modality = enum(u8) {
    text,
    vision,
    audio_semantic,
    audio_prosody,
    system,
};

pub const MODALITY_COUNT: usize = @intFromEnum(Modality.system) + 1;

pub const Domain = struct {
    encoder_family: [16]u8,
    projection_schema: [16]u8,

    pub fn valid(self: Domain) bool {
        return !allZero(&self.encoder_family) and !allZero(&self.projection_schema);
    }

    pub fn eql(left: Domain, right: Domain) bool {
        return mem.eql(u8, &left.encoder_family, &right.encoder_family) and
            mem.eql(u8, &left.projection_schema, &right.projection_schema);
    }
};

pub const Error = error{
    InvalidDomain,
    DomainMismatch,
    InvalidEvent,
    InvalidDimension,
    InvalidConfidence,
    InvalidHorizon,
    NonFinite,
    NoFreshRepresentation,
    ZeroNorm,
};

pub const PublishInput = struct {
    modality: Modality,
    domain: Domain,
    event_id: u64,
    timestamp_tick: u64,
    confidence_q16: u16,
    quality_q16: u16,
    prefix_dimensions: usize,
    vector: []const f32,
};

pub const FusionReceipt = struct {
    active_modalities: u8 = 0,
    active_mask: u8 = 0,
    selected_dimensions: u16 = 0,
    maximum_weight_q16: u16 = 0,
    multiplications: u64 = 0,
    additions: u64 = 0,
    divisions: u64 = 0,
    normalized: bool = false,

    pub fn arithmeticOperations(self: FusionReceipt) u64 {
        return self.multiplications + self.additions + self.divisions;
    }
};

pub fn Fusion(comptime dimension: usize, comptime minimum_prefix: usize) type {
    if (dimension == 0 or minimum_prefix == 0 or dimension % minimum_prefix != 0)
        @compileError("fusion dimensions must be non-zero multiples of the minimum prefix");

    return struct {
        const Self = @This();
        const Slot = struct {
            valid: bool = false,
            event_id: u64 = 0,
            timestamp_tick: u64 = 0,
            confidence_q16: u16 = 0,
            quality_q16: u16 = 0,
            prefix_dimensions: u16 = 0,
            vector: [dimension]f32 = @splat(0),
        };

        domain: Domain = .{ .encoder_family = @splat(0), .projection_schema = @splat(0) },
        configured: bool = false,
        // Zero keeps a global fusion service in true BSS; configure() installs
        // the first valid non-zero horizon before publication.
        freshness_horizon_ticks: u64 = 0,
        slots: [MODALITY_COUNT]Slot = @splat(.{}),
        publications: u64 = 0,
        rejections: u64 = 0,
        fusions: u64 = 0,

        pub fn staticBytes() usize { return @sizeOf(Self); }

        pub fn configure(self: *Self, domain: Domain, freshness_horizon_ticks: u64) Error!void {
            if (!domain.valid()) return error.InvalidDomain;
            if (freshness_horizon_ticks == 0) return error.InvalidHorizon;
            self.domain = domain;
            self.freshness_horizon_ticks = freshness_horizon_ticks;
            self.configured = true;
        }

        /// Publish is fail-atomic: all lanes are validated before replacing the
        /// previous modality observation.
        pub fn publish(self: *Self, input: PublishInput) Error!void {
            if (!self.configured or !input.domain.valid()) return self.reject(error.InvalidDomain);
            if (!self.domain.eql(input.domain)) return self.reject(error.DomainMismatch);
            if (input.event_id == 0) return self.reject(error.InvalidEvent);
            if (input.confidence_q16 == 0 or input.quality_q16 == 0)
                return self.reject(error.InvalidConfidence);
            if (input.prefix_dimensions < minimum_prefix or input.prefix_dimensions > dimension or
                input.prefix_dimensions % minimum_prefix != 0 or input.vector.len < input.prefix_dimensions)
                return self.reject(error.InvalidDimension);
            var candidate: [dimension]f32 = @splat(0);
            for (input.vector[0..input.prefix_dimensions], 0..) |value, lane| {
                if (!math.isFinite(value)) return self.reject(error.NonFinite);
                candidate[lane] = value;
            }
            self.slots[@intFromEnum(input.modality)] = .{
                .valid = true,
                .event_id = input.event_id,
                .timestamp_tick = input.timestamp_tick,
                .confidence_q16 = input.confidence_q16,
                .quality_q16 = input.quality_q16,
                .prefix_dimensions = @intCast(input.prefix_dimensions),
                .vector = candidate,
            };
            self.publications +|= 1;
        }

        /// Reliability/freshness weighted late fusion followed by L2
        /// normalization. Work is O(MD) with M fixed at five and D selected at
        /// runtime from admitted Matryoshka prefixes.
        pub fn fuse(self: *Self, now_tick: u64, selected_dimensions: usize, output: []f32) Error!FusionReceipt {
            if (!self.configured) return error.InvalidDomain;
            if (selected_dimensions < minimum_prefix or selected_dimensions > dimension or
                selected_dimensions % minimum_prefix != 0 or output.len < selected_dimensions)
                return error.InvalidDimension;
            @memset(output[0..selected_dimensions], 0);
            var denominators: [dimension]u64 = @splat(0);
            var receipt = FusionReceipt{ .selected_dimensions = @intCast(selected_dimensions) };

            for (self.slots, 0..) |slot, modality_index| {
                if (!slot.valid) continue;
                const freshness = freshnessQ16(now_tick, slot.timestamp_tick, self.freshness_horizon_ticks);
                if (freshness == 0) continue;
                const weight = combinedWeight(slot.confidence_q16, slot.quality_q16, freshness);
                if (weight == 0) continue;
                receipt.active_modalities +|= 1;
                receipt.active_mask |= @as(u8, 1) << @intCast(modality_index);
                receipt.maximum_weight_q16 = @max(receipt.maximum_weight_q16, weight);
                const lanes = @min(selected_dimensions, slot.prefix_dimensions);
                for (0..lanes) |lane| {
                    output[lane] += slot.vector[lane] * @as(f32, @floatFromInt(weight));
                    denominators[lane] +|= weight;
                    receipt.multiplications +|= 1;
                    receipt.additions +|= 1;
                }
            }
            if (receipt.active_modalities == 0) return error.NoFreshRepresentation;

            var squared_norm: f64 = 0;
            for (0..selected_dimensions) |lane| {
                if (denominators[lane] != 0) {
                    output[lane] /= @as(f32, @floatFromInt(denominators[lane]));
                    receipt.divisions +|= 1;
                }
                squared_norm += @as(f64, output[lane]) * @as(f64, output[lane]);
                receipt.multiplications +|= 1;
                receipt.additions +|= 1;
            }
            if (!math.isFiniteF64(squared_norm)) return error.NonFinite;
            if (squared_norm <= 0) return error.ZeroNorm;
            const inverse: f32 = @floatCast(1.0 / @sqrt(squared_norm));
            receipt.divisions +|= 1;
            for (output[0..selected_dimensions]) |*value| {
                value.* *= inverse;
                receipt.multiplications +|= 1;
            }
            receipt.normalized = true;
            self.fusions +|= 1;
            return receipt;
        }

        fn reject(self: *Self, failure: Error) Error {
            self.rejections +|= 1;
            return failure;
        }
    };
}

fn combinedWeight(confidence: u16, quality: u16, freshness: u16) u16 {
    const product: u64 = @as(u64, confidence) * quality * freshness;
    const denominator: u64 = @as(u64, Q16_ONE) * Q16_ONE;
    return @intCast(@min(@as(u64, Q16_ONE), (product + denominator / 2) / denominator));
}

fn freshnessQ16(now: u64, observed: u64, horizon: u64) u16 {
    if (observed >= now) return Q16_ONE;
    const age = now - observed;
    if (age >= horizon) return 0;
    const remaining = horizon - age;
    return @intCast(@min(@as(u64, Q16_ONE), (remaining * Q16_ONE) / horizon));
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn testDomain(seed: u8) Domain {
    return .{ .encoder_family = @splat(seed), .projection_schema = @splat(seed +% 1) };
}

test "fusion rejects unaligned spaces and publication is atomic" {
    var fusion = Fusion(8, 2){};
    try fusion.configure(testDomain(1), 100);
    const vector = [_]f32{ 1, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.DomainMismatch, fusion.publish(.{
        .modality = .vision,
        .domain = testDomain(2),
        .event_id = 1,
        .timestamp_tick = 1,
        .confidence_q16 = Q16_ONE,
        .quality_q16 = Q16_ONE,
        .prefix_dimensions = 8,
        .vector = &vector,
    }));
    try testing.expectEqual(@as(u64, 0), fusion.publications);
    try testing.expectEqual(@as(u64, 1), fusion.rejections);
}

test "fresh multimodal representations fuse to a normalized NOW vector" {
    var fusion = Fusion(8, 2){};
    const domain = testDomain(1);
    try fusion.configure(domain, 100);
    const vision = [_]f32{ 1, 0, 0, 0, 0, 0, 0, 0 };
    const audio = [_]f32{ 0, 1, 0, 0, 0, 0, 0, 0 };
    try fusion.publish(.{ .modality = .vision, .domain = domain, .event_id = 1, .timestamp_tick = 90, .confidence_q16 = Q16_ONE, .quality_q16 = Q16_ONE, .prefix_dimensions = 8, .vector = &vision });
    try fusion.publish(.{ .modality = .audio_semantic, .domain = domain, .event_id = 2, .timestamp_tick = 90, .confidence_q16 = Q16_ONE, .quality_q16 = Q16_ONE, .prefix_dimensions = 8, .vector = &audio });
    var output: [8]f32 = undefined;
    const receipt = try fusion.fuse(100, 8, &output);
    try testing.expectEqual(@as(u8, 2), receipt.active_modalities);
    try testing.expect(receipt.normalized);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), output[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), output[1], 0.0001);
}

test "Matryoshka prefix budget reduces exact fusion work" {
    var fusion = Fusion(64, 16){};
    const domain = testDomain(4);
    try fusion.configure(domain, 100);
    var vector: [64]f32 = @splat(0);
    vector[0] = 1;
    try fusion.publish(.{ .modality = .text, .domain = domain, .event_id = 1, .timestamp_tick = 1, .confidence_q16 = Q16_ONE, .quality_q16 = Q16_ONE, .prefix_dimensions = 64, .vector = &vector });
    var short: [64]f32 = undefined;
    const low = try fusion.fuse(1, 16, &short);
    const full = try fusion.fuse(1, 64, &short);
    // The one reciprocal-square-root division is prefix-independent; every
    // lane operation scales exactly with D.
    try testing.expect((low.arithmeticOperations() - 1) * 4 ==
        full.arithmeticOperations() - 1);
}

test "expired representations cannot animate stale ephemeral UI" {
    var fusion = Fusion(4, 2){};
    const domain = testDomain(1);
    try fusion.configure(domain, 10);
    const vector = [_]f32{ 1, 0, 0, 0 };
    try fusion.publish(.{ .modality = .system, .domain = domain, .event_id = 1, .timestamp_tick = 1, .confidence_q16 = Q16_ONE, .quality_q16 = Q16_ONE, .prefix_dimensions = 4, .vector = &vector });
    var output: [4]f32 = undefined;
    try testing.expectError(error.NoFreshRepresentation, fusion.fuse(11, 4, &output));
}
