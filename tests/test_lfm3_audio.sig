//! Executable contracts for LFM3-Audio's hearing encoder and speech
//! generator: plans read from GGUF metadata and tensors, streaming state
//! (chunked encoding and decoding equal one-shot), MaskGIT passes, the code
//! feedback sum, sampling bounds and error paths. Two small synthetic mmproj
//! files with LFM3-Audio's layer patterns and tensor names are written into
//! static storage; no download or heap storage is required.
const std = @import("std");
const gguf = @import("gguf");
const quantized = @import("quantized_linear");
const encoder = @import("lfm3_audio_encoder");
const speech = @import("lfm3_audio_gen");

const CAPACITY = 128;
const HIDDEN = 64;
const FEED = 64;
const HEAD = 32;
const KV = 32;
const MELS = 32;
const CHANNELS = 8;
const PROJECTION = 64;
const WINDOW = 4;
const KERNEL = 3;
const CODES = 8; // per codebook, plus the end code
const LEVELS = 2;
const FSQ_OUT = 32;

const ENCODER_LIMITS = encoder.Limits{ .positions = 8, .hidden = HIDDEN, .feed_forward = FEED, .query = HIDDEN, .kv_width = KV,
    .mels = MELS, .channels = CHANNELS, .projection = PROJECTION, .window = WINDOW, .kernel = KERNEL, .layers = 3 };
const GEN_LIMITS = speech.Limits{ .depth_hidden = HIDDEN, .depth_feed_forward = FEED, .depth_kv_width = KV, .depth_heads = 2,
    .vocabulary = CODES + 1, .backbone = HIDDEN, .codec_hidden = HIDDEN, .codec_feed_forward = FEED, .codec_kv_width = KV,
    .codec_heads = 2, .codec_layers = 3, .codec_kernel = KERNEL, .frames = 4, .history = 16 };

var assertions: usize = 0;
var executed_cases: usize = 0;

fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.Lfm3AudioContractFailed;
}
fn rejected(result: anytype, expected: anyerror) !void {
    if (result) |_| return error.InvalidOperationAccepted else |err| try check(err == expected);
}

/// A GGUF v3 file in static storage: metadata first, tensor infos second,
/// data last, every tensor 32-byte aligned.
const Fixture = struct {
    const Tensor = struct { name: [64]u8 = undefined, name_len: usize = 0, dims: [4]u64 = @splat(1), dim_count: u32 = 0, ggml_type: u32 = 0, offset: u64 = 0, size: u64 = 0 };
    const Key = struct { name: [64]u8 = undefined, name_len: usize = 0, float: bool = false, value: u32 = 0 };

    bytes: [1 << 20]u8 align(64) = undefined,
    used: usize = 0,
    data: [1 << 20]u8 align(64) = undefined,
    data_used: usize = 0,
    tensors: [CAPACITY]Tensor = @splat(.{}),
    tensor_count: usize = 0,
    keys: [32]Key = @splat(.{}),
    key_count: usize = 0,
    seed: u32 = 1,
    omit: []const u8 = "",
    index: gguf.Index(CAPACITY) = .{},

    fn reset(self: *Fixture, omit: []const u8) void {
        self.used = 0;
        self.data_used = 0;
        self.tensor_count = 0;
        self.key_count = 0;
        self.seed = 1;
        self.omit = omit;
    }

    fn keyU32(self: *Fixture, name: []const u8, value: u32) void {
        const key = &self.keys[self.key_count];
        @memcpy(key.name[0..name.len], name);
        key.name_len = name.len;
        key.value = value;
        key.float = false;
        self.key_count += 1;
    }
    fn keyF32(self: *Fixture, name: []const u8, value: f32) void {
        self.keyU32(name, @bitCast(value));
        self.keys[self.key_count - 1].float = true;
    }

    fn next(self: *Fixture) u32 {
        self.seed = self.seed *% 1664525 +% 1013904223;
        return self.seed >> 8;
    }
    fn unit(self: *Fixture) f32 {
        return @as(f32, @floatFromInt(self.next() % 1000)) / 1000.0;
    }

    /// kind: 'n' norm-like (0.75..1.25), 'b' small bias, 't' taps (+-0.5).
    fn vector(self: *Fixture, name: []const u8, dims: []const u64, kind: u8) !void {
        var elements: u64 = 1;
        for (dims) |d| elements *= d;
        const tensor = try self.begin(name, dims, 0, elements * 4) orelse return;
        for (0..@intCast(elements)) |_| {
            const u = self.unit();
            const value: f32 = switch (kind) {
                'n' => 0.75 + u / 2,
                'b' => (u - 0.5) / 10,
                else => u - 0.5,
            };
            self.putData(std.mem.asBytes(&value));
        }
        _ = tensor;
    }

    /// Q8_0 rows with patterned quants and a small positive f16 scale.
    fn matrix(self: *Fixture, name: []const u8, dims: []const u64) !void {
        var elements: u64 = 1;
        for (dims) |d| elements *= d;
        const blocks = elements / quantized.QK8_0;
        _ = try self.begin(name, dims, 8, blocks * quantized.Q8_0_BLOCK_BYTES) orelse return;
        for (0..@intCast(blocks)) |_| {
            var block: [quantized.Q8_0_BLOCK_BYTES]u8 = undefined;
            std.mem.writeInt(u16, block[0..2], @bitCast(@as(f16, 0.004)), .little);
            for (block[2..]) |*q| q.* = @bitCast(@as(i8, @intCast(@as(i32, @intCast(self.next() % 255)) - 127)));
            self.putData(&block);
        }
    }

    fn begin(self: *Fixture, name: []const u8, dims: []const u64, ggml_type: u32, size: u64) !?*Tensor {
        if (std.mem.eql(u8, name, self.omit)) return null;
        if (self.tensor_count == CAPACITY) return error.FixtureCapacity;
        self.data_used = std.mem.alignForward(usize, self.data_used, 32);
        const tensor = &self.tensors[self.tensor_count];
        @memcpy(tensor.name[0..name.len], name);
        tensor.name_len = name.len;
        tensor.dim_count = @intCast(dims.len);
        for (dims, 0..) |d, i| tensor.dims[i] = d;
        tensor.ggml_type = ggml_type;
        tensor.offset = self.data_used;
        tensor.size = size;
        if (self.data_used + size > self.data.len) return error.FixtureCapacity;
        self.tensor_count += 1;
        return tensor;
    }

    fn putData(self: *Fixture, value: []const u8) void {
        @memcpy(self.data[self.data_used..][0..value.len], value);
        self.data_used += value.len;
    }
    fn put(self: *Fixture, value: []const u8) void {
        @memcpy(self.bytes[self.used..][0..value.len], value);
        self.used += value.len;
    }
    fn put32(self: *Fixture, value: u32) void {
        self.put(std.mem.asBytes(&value));
    }
    fn put64(self: *Fixture, value: u64) void {
        self.put(std.mem.asBytes(&value));
    }
    fn string(self: *Fixture, value: []const u8) void {
        self.put64(value.len);
        self.put(value);
    }

    /// Serialize and parse.
    fn finish(self: *Fixture) !void {
        self.used = 0;
        self.put("GGUF");
        self.put32(3);
        self.put64(self.tensor_count);
        self.put64(self.key_count);
        for (self.keys[0..self.key_count]) |*key| {
            self.string(key.name[0..key.name_len]);
            self.put32(if (key.float) 6 else 4);
            self.put32(key.value);
        }
        for (self.tensors[0..self.tensor_count]) |*tensor| {
            self.string(tensor.name[0..tensor.name_len]);
            self.put32(tensor.dim_count);
            for (tensor.dims[0..tensor.dim_count]) |d| self.put64(d);
            self.put32(tensor.ggml_type);
            self.put64(tensor.offset);
        }
        self.used = std.mem.alignForward(usize, self.used, 32);
        if (self.used + self.data_used > self.bytes.len) return error.FixtureCapacity;
        @memcpy(self.bytes[self.used..][0..self.data_used], self.data[0..self.data_used]);
        self.used += self.data_used;
        try gguf.parse(CAPACITY, self.source(), &self.index);
    }

    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (offset > self.used or destination.len > self.used - @as(usize, @intCast(offset))) return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (offset > self.used or length > self.used - @as(usize, @intCast(offset))) return null;
        const pointer = self.bytes[@intCast(offset)..].ptr;
        if (@intFromPtr(pointer) % alignment != 0) return null;
        return pointer;
    }
    fn source(self: *const Fixture) gguf.Source {
        return .{ .context = self, .size = self.used, .read_at = read, .map_at = map };
    }
};

fn layerName(buffer: []u8, prefix: []const u8, layer: usize, suffix: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}{d}{s}", .{ prefix, layer, suffix }) catch unreachable;
}

/// Encoder: conv, attention, conv (the LFM3-Audio pattern in small).
fn writeEncoder(f: *Fixture, omit: []const u8) !void {
    f.reset(omit);
    f.keyU32("clip.audio.embedding_length", HIDDEN);
    f.keyU32("clip.audio.feed_forward_length", FEED);
    f.keyU32("clip.audio.block_count", 3);
    f.keyU32("clip.audio.attention.head_count", 2);
    f.keyU32("clip.audio.attention.head_count_kv", 1);
    f.keyU32("clip.audio.num_mel_bins", MELS);
    f.keyU32("clip.audio.window_size", WINDOW);
    f.keyU32("clip.audio.projection_dim", PROJECTION);
    f.keyF32("clip.audio.attention.layer_norm_epsilon", 1e-5);
    try f.vector("a.conv1d.0.weight", &.{ 3, 3, 1, CHANNELS }, 't');
    try f.vector("a.conv1d.0.bias", &.{ 1, 1, CHANNELS }, 'b');
    for ([_][]const u8{ "2", "5" }) |stage| {
        var name: [64]u8 = undefined;
        try f.vector(try std.fmt.bufPrint(&name, "a.conv1d.{s}.weight", .{stage}), &.{ 3, 3, 1, CHANNELS }, 't');
        try f.vector(try std.fmt.bufPrint(&name, "a.conv1d.{s}.bias", .{stage}), &.{ 1, 1, CHANNELS }, 'b');
    }
    for ([_][]const u8{ "3", "6" }) |stage| {
        var name: [64]u8 = undefined;
        try f.vector(try std.fmt.bufPrint(&name, "a.conv1d.{s}.weight", .{stage}), &.{ 1, 1, CHANNELS, CHANNELS }, 't');
        try f.vector(try std.fmt.bufPrint(&name, "a.conv1d.{s}.bias", .{stage}), &.{ 1, 1, CHANNELS }, 'b');
    }
    try f.matrix("a.pre_encode.out.weight", &.{ MELS / 8 * CHANNELS, HIDDEN });
    try f.vector("a.pre_encode.out.bias", &.{HIDDEN}, 'b');
    try f.vector("a.post_ln.weight", &.{HIDDEN}, 'n');
    try f.vector("mm.a.mlp.0.weight", &.{HIDDEN}, 'n');
    try f.vector("mm.a.mlp.0.bias", &.{HIDDEN}, 'b');
    try f.matrix("mm.a.mlp.1.weight", &.{ HIDDEN, PROJECTION });
    try f.vector("mm.a.mlp.1.bias", &.{PROJECTION}, 'b');
    try f.matrix("mm.a.mlp.3.weight", &.{ PROJECTION, PROJECTION });
    try f.vector("mm.a.mlp.3.bias", &.{PROJECTION}, 'b');
    for (0..3) |layer| try writeLayer(f, "a.blk.", layer, layer == 1, false, false);
    try f.finish();
}

fn writeLayer(f: *Fixture, prefix: []const u8, layer: usize, attention: bool, gate: bool, post: bool) !void {
    var name: [64]u8 = undefined;
    try f.vector(layerName(&name, prefix, layer, ".ln1.weight"), &.{HIDDEN}, 'n');
    try f.vector(layerName(&name, prefix, layer, ".ln2.weight"), &.{HIDDEN}, 'n');
    if (post) {
        try f.vector(layerName(&name, prefix, layer, ".attn_post_norm.weight"), &.{HIDDEN}, 'n');
        try f.vector(layerName(&name, prefix, layer, ".ffn_post_norm.weight"), &.{HIDDEN}, 'n');
    }
    try f.matrix(layerName(&name, prefix, layer, ".ffn_gate.weight"), &.{ HIDDEN, FEED });
    try f.matrix(layerName(&name, prefix, layer, ".ffn_up.weight"), &.{ HIDDEN, FEED });
    try f.matrix(layerName(&name, prefix, layer, ".ffn_down.weight"), &.{ FEED, HIDDEN });
    if (attention) {
        try f.matrix(layerName(&name, prefix, layer, ".attn_q.weight"), &.{ HIDDEN, HIDDEN });
        try f.matrix(layerName(&name, prefix, layer, ".attn_k.weight"), &.{ HIDDEN, KV });
        try f.matrix(layerName(&name, prefix, layer, ".attn_v.weight"), &.{ HIDDEN, KV });
        try f.matrix(layerName(&name, prefix, layer, ".attn_out.weight"), &.{ HIDDEN, HIDDEN });
        if (gate) try f.matrix(layerName(&name, prefix, layer, ".attn_gate.weight"), &.{ HIDDEN, 2 * 16 });
        try f.vector(layerName(&name, prefix, layer, ".attn_q_norm.weight"), &.{HEAD}, 'n');
        try f.vector(layerName(&name, prefix, layer, ".attn_k_norm.weight"), &.{HEAD}, 'n');
    } else {
        try f.vector(layerName(&name, prefix, layer, ".conv_dw.weight"), &.{ KERNEL, HIDDEN }, 't');
        try f.matrix(layerName(&name, prefix, layer, ".conv_pw1.weight"), &.{ HIDDEN, 3 * HIDDEN });
        try f.matrix(layerName(&name, prefix, layer, ".conv_pw2.weight"), &.{ HIDDEN, HIDDEN });
    }
}

/// Depthformer (two gated attention layers) and codec (conv, gated
/// attention, conv, with sandwich norms).
fn writeGenerator(f: *Fixture, omit: []const u8) !void {
    f.reset(omit);
    f.keyU32("clip.gen.audio.embedding_length", HIDDEN);
    f.keyU32("clip.gen.audio.feed_forward_length", FEED);
    f.keyU32("clip.gen.audio.block_count", 2);
    f.keyU32("clip.gen.audio.attention.head_count", 2);
    f.keyU32("clip.gen.audio.attention.head_count_kv", 1);
    f.keyU32("clip.gen.audio.projection_dim", HIDDEN);
    f.keyF32("clip.gen.audio.attention.layer_norm_epsilon", 1e-5);
    f.keyF32("clip.gen.audio.sampling.temp", 1.0);
    f.keyU32("clip.gen.audio.sampling.top_k", 4);
    f.keyF32("clip.gen.audio.sampling.penalty_repeat", 1.1);
    f.keyU32("clip.gen.audio.sampling.penalty_last_n", 8);
    try f.matrix("a.gen.code.embd.weight", &.{ HIDDEN, CODES + 1, speech.CODEBOOKS });
    try f.vector("a.gen.code.head_norm.weight", &.{ HIDDEN, speech.CODEBOOKS }, 'n');
    try f.vector("a.gen.code.mask_embd", &.{HIDDEN}, 't');
    try f.matrix("a.gen.code.out_embd.weight", &.{ HIDDEN, (CODES + 1) * speech.CODEBOOKS });
    try f.vector("a.gen.code.output_norm.weight", &.{HIDDEN}, 'n');
    try f.matrix("a.gen.code.proj_in.weight", &.{ HIDDEN, HIDDEN * speech.CODEBOOKS });
    try f.vector("a.gen.code.proj_in.bias", &.{HIDDEN * speech.CODEBOOKS}, 'b');
    for (0..2) |layer| try writeGateLayer(f, "a.gen.code.blk.", layer, true, false);
    try f.vector("a.gen.wav.quant.first.codebook.weight", &.{ LEVELS, CODES }, 't');
    try f.vector("a.gen.wav.quant.first.out_proj.weight", &.{ LEVELS * speech.CODEBOOKS, FSQ_OUT }, 't');
    try f.vector("a.gen.wav.quant.first.out_proj.bias", &.{FSQ_OUT}, 'b');
    try f.matrix("a.gen.wav.tfm.in_proj.weight", &.{ FSQ_OUT, HIDDEN });
    try f.vector("a.gen.wav.tfm.in_proj.bias", &.{HIDDEN}, 'b');
    try f.matrix("a.gen.wav.tfm.out_proj.weight", &.{ HIDDEN, 2 * speech.BINS });
    try f.vector("a.gen.wav.tfm.out_proj.bias", &.{2 * speech.BINS}, 'b');
    try f.vector("a.gen.wav.tfm.output_norm.weight", &.{HIDDEN}, 'n');
    for (0..3) |layer| try writeGateLayer(f, "a.gen.wav.tfm.blk.", layer, layer == 1, true);
    try f.finish();
}

fn writeGateLayer(f: *Fixture, prefix: []const u8, layer: usize, attention: bool, post: bool) !void {
    var name: [64]u8 = undefined;
    try writeLayer(f, prefix, layer, attention, false, post);
    if (attention) try f.matrix(layerName(&name, prefix, layer, ".attn_gate.weight"), &.{ HIDDEN, 2 });
}

var fixture: Fixture = .{};
var encoder_plan: encoder.Plan = .{};
var encoder_state: encoder.State(ENCODER_LIMITS) = .{};
var encoder_work: encoder.Workspace(ENCODER_LIMITS) = .{};
var gen_plan: speech.Plan = .{};
var depth_work: speech.DepthWorkspace(GEN_LIMITS) = .{};
var codec_state: speech.CodecState(GEN_LIMITS) = .{};
var codec_work: speech.CodecWorkspace(GEN_LIMITS) = .{};

fn melFrames(comptime count: usize) [count * MELS]f32 {
    var frames: [count * MELS]f32 = undefined;
    var state: u32 = 7;
    for (&frames) |*value| {
        state = state *% 1664525 +% 1013904223;
        value.* = @as(f32, @floatFromInt(state >> 8)) / 16777216.0 * 2.0 - 1.0;
    }
    return frames;
}

fn encoderPlan() !void {
    try writeEncoder(&fixture, "");
    try encoder.build(CAPACITY, fixture.source(), &fixture.index, &encoder_plan);
    try check(encoder_plan.layer_count == 3 and encoder_plan.conv_layer_count == 2 and encoder_plan.attention_layer_count == 1);
    try check(encoder_plan.layers[1].attention and !encoder_plan.layers[0].attention and encoder_plan.layers[2].slot == 1);
    try check(encoder_plan.head_size == HEAD and encoder_plan.heads == 2 and encoder_plan.kv_heads == 1 and encoder_plan.channels == CHANNELS);
    try check(encoder_plan.kernel == KERNEL and encoder_plan.window == WINDOW and encoder_plan.features() == 32);
    try check(encoder.positionsFor(0) == 0 and encoder.positionsFor(1) == 1 and encoder.positionsFor(8) == 1 and encoder.positionsFor(9) == 2 and encoder.positionsFor(416) == 52);
    // A missing tensor or key fails the build.
    try writeEncoder(&fixture, "a.blk.1.attn_k_norm.weight");
    try rejected(encoder.build(CAPACITY, fixture.source(), &fixture.index, &encoder_plan), error.InvalidModel);
    try writeEncoder(&fixture, "mm.a.mlp.3.bias");
    try rejected(encoder.build(CAPACITY, fixture.source(), &fixture.index, &encoder_plan), error.InvalidModel);
    executed_cases += 1;
}

/// Chunks of 8 or 16 frames carrying the state give the same rows as the
/// whole clip at once; a shorter final chunk uses the right zero padding.
fn encoderStreaming() !void {
    try writeEncoder(&fixture, "");
    try encoder.build(CAPACITY, fixture.source(), &fixture.index, &encoder_plan);
    const frames = melFrames(60);
    var whole: [8 * PROJECTION]f32 = undefined;
    var chunked: [8 * PROJECTION]f32 = undefined;
    encoder_state.reset();
    const rows = try encoder.encode(CAPACITY, ENCODER_LIMITS, fixture.source(), &fixture.index, &encoder_plan, &encoder_state, &encoder_work, &frames, &whole, .{});
    try check(rows == encoder.positionsFor(60) and rows == 8 and encoder_state.position == 8);
    for (whole[0 .. rows * PROJECTION]) |value| try check(std.math.isFinite(value));
    encoder_state.reset();
    var produced: usize = 0;
    var first: usize = 0;
    for ([_]usize{ 16, 8, 24, 12 }) |count| {
        produced += try encoder.encode(CAPACITY, ENCODER_LIMITS, fixture.source(), &fixture.index, &encoder_plan, &encoder_state, &encoder_work, frames[first * MELS .. (first + count) * MELS], chunked[produced * PROJECTION ..], .{});
        first += count;
    }
    try check(produced == rows);
    try check(std.mem.eql(f32, whole[0 .. rows * PROJECTION], chunked[0 .. rows * PROJECTION]));
    // Encoding is causal: the first rows do not depend on later frames.
    encoder_state.reset();
    var prefix: [8 * PROJECTION]f32 = undefined;
    _ = try encoder.encode(CAPACITY, ENCODER_LIMITS, fixture.source(), &fixture.index, &encoder_plan, &encoder_state, &encoder_work, frames[0 .. 24 * MELS], &prefix, .{});
    try check(std.mem.eql(f32, whole[0 .. 3 * PROJECTION], prefix[0 .. 3 * PROJECTION]));
    executed_cases += 1;
}

fn encoderBounds() !void {
    try writeEncoder(&fixture, "");
    try encoder.build(CAPACITY, fixture.source(), &fixture.index, &encoder_plan);
    var out: [16 * PROJECTION]f32 = undefined;
    const frames = melFrames(72);
    encoder_state.reset();
    // More frames than 8 * positions, a partial frame, too little output.
    try rejected(encoder.encode(CAPACITY, ENCODER_LIMITS, fixture.source(), &fixture.index, &encoder_plan, &encoder_state, &encoder_work, &frames, &out, .{}), error.Capacity);
    try rejected(encoder.encode(CAPACITY, ENCODER_LIMITS, fixture.source(), &fixture.index, &encoder_plan, &encoder_state, &encoder_work, frames[0 .. MELS + 1], &out, .{}), error.InvalidInput);
    try rejected(encoder.encode(CAPACITY, ENCODER_LIMITS, fixture.source(), &fixture.index, &encoder_plan, &encoder_state, &encoder_work, frames[0 .. 16 * MELS], out[0..PROJECTION], .{}), error.Capacity);
    executed_cases += 1;
}

fn generatorPlan() !void {
    try writeGenerator(&fixture, "");
    try speech.build(CAPACITY, fixture.source(), &fixture.index, &gen_plan);
    try check(gen_plan.depth.layer_count == 2 and gen_plan.depth.attention_layer_count == 2 and gen_plan.depth.heads == 2 and gen_plan.depth.kv_heads == 1);
    try check(gen_plan.codec.layer_count == 3 and gen_plan.codec.conv_layer_count == 2 and gen_plan.codec.attention_layer_count == 1);
    try check(gen_plan.vocabulary == CODES + 1 and gen_plan.endCode() == CODES and gen_plan.levels == LEVELS and gen_plan.codec.kernel == KERNEL);
    try check(gen_plan.top_k == 4 and gen_plan.penalty_window == 8 and @abs(gen_plan.penalty - 1.1) < 1e-6);
    try writeGenerator(&fixture, "a.gen.wav.tfm.blk.1.attn_post_norm.weight");
    try speech.build(CAPACITY, fixture.source(), &fixture.index, &gen_plan); // post norms are optional
    try writeGenerator(&fixture, "a.gen.code.mask_embd");
    try rejected(speech.build(CAPACITY, fixture.source(), &fixture.index, &gen_plan), error.InvalidModel);
    executed_cases += 1;
}

/// Revealing a code changes its own position's input and, through
/// attention, every logit row; masked passes repeat exactly.
fn maskGitPasses() !void {
    try writeGenerator(&fixture, "");
    try speech.build(CAPACITY, fixture.source(), &fixture.index, &gen_plan);
    var hidden_state: [HIDDEN]f32 = undefined;
    for (&hidden_state, 0..) |*value, i| value.* = @sin(@as(f32, @floatFromInt(i)) * 0.37);
    var codes: [speech.CODEBOOKS]i32 = @splat(-1);
    const n = speech.CODEBOOKS * (CODES + 1);
    try speech.projectState(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &depth_work, &hidden_state, .{});
    try speech.codePass(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &depth_work, &codes, .{});
    var masked: [n]f32 = undefined;
    @memcpy(&masked, depth_work.logits[0..n]);
    for (masked) |value| try check(std.math.isFinite(value));
    try speech.codePass(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &depth_work, &codes, .{});
    try check(std.mem.eql(f32, &masked, depth_work.logits[0..n]));
    codes[3] = 5;
    try speech.codePass(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &depth_work, &codes, .{});
    var changed_rows: usize = 0;
    for (0..speech.CODEBOOKS) |book| {
        if (!std.mem.eql(f32, masked[book * (CODES + 1) ..][0 .. CODES + 1], depth_work.logits[book * (CODES + 1) ..][0 .. CODES + 1])) changed_rows += 1;
    }
    try check(changed_rows == speech.CODEBOOKS);
    codes[3] = CODES + 1;
    try rejected(speech.codePass(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &depth_work, &codes, .{}), error.InvalidInput);
    executed_cases += 1;
}

/// The feedback row is the sum of the 12 codes' output embeddings.
fn feedbackSum() !void {
    try writeGenerator(&fixture, "");
    try speech.build(CAPACITY, fixture.source(), &fixture.index, &gen_plan);
    const codes = [speech.CODEBOOKS]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 8, 3 };
    var out: [HIDDEN]f32 = undefined;
    var scratch: [speech.CODEBOOKS * HIDDEN]f32 = undefined;
    try speech.feedback(CAPACITY, fixture.source(), &fixture.index, &gen_plan, &codes, &out, &scratch);
    const table = fixture.index.find("a.gen.code.out_embd.weight").?;
    const bytes = fixture.bytes[@intCast(table.file_offset)..];
    const row_bytes = HIDDEN / quantized.QK8_0 * quantized.Q8_0_BLOCK_BYTES;
    for (0..HIDDEN) |lane| {
        var expected: f64 = 0;
        for (codes, 0..) |code, book| {
            var row: [HIDDEN]f32 = undefined;
            try quantized.dequantizeQ80(&row, bytes[(book * (CODES + 1) + @as(usize, @intCast(code))) * row_bytes ..][0..row_bytes]);
            expected += row[lane];
        }
        try check(out[lane] == @as(f32, @floatCast(expected)));
    }
    var bad = codes;
    bad[0] = -1;
    try rejected(speech.feedback(CAPACITY, fixture.source(), &fixture.index, &gen_plan, &bad, &out, &scratch), error.InvalidInput);
    executed_cases += 1;
}

/// Greedy frames are reproducible; sampled codes stay in range; the reveal
/// order is a permutation of the codebooks.
fn speakerFrames() !void {
    try writeGenerator(&fixture, "");
    try speech.build(CAPACITY, fixture.source(), &fixture.index, &gen_plan);
    var hidden_state: [HIDDEN]f32 = undefined;
    for (&hidden_state, 0..) |*value, i| value.* = @cos(@as(f32, @floatFromInt(i)) * 0.21);
    var greedy = speech.modelSampling(&gen_plan, 42);
    greedy.temperature = 0;
    var first = speech.Speaker(GEN_LIMITS).init(greedy);
    var second = speech.Speaker(GEN_LIMITS).init(greedy);
    for (0..3) |_| {
        const a = try first.frame(CAPACITY, fixture.source(), &fixture.index, &gen_plan, &depth_work, &hidden_state, .{});
        const b = try second.frame(CAPACITY, fixture.source(), &fixture.index, &gen_plan, &depth_work, &hidden_state, .{});
        try check(std.mem.eql(i32, &a.codes, &b.codes) and a.end == b.end);
        for (a.codes) |code| try check(code >= 0 and code <= CODES);
    }
    var sampled = speech.Speaker(GEN_LIMITS).init(speech.modelSampling(&gen_plan, 7));
    for (0..20) |_| {
        const frame = try sampled.frame(CAPACITY, fixture.source(), &fixture.index, &gen_plan, &depth_work, &hidden_state, .{});
        if (frame.end) {
            for (frame.codes) |code| try check(code == CODES);
            break;
        }
        for (frame.codes) |code| try check(code >= 0 and code < CODES);
    }
    var rng = speech.Mt19937.init(5489);
    try check(rng.next() == 3499211612);
    var seen: [speech.CODEBOOKS]bool = @splat(false);
    for (speech.frameOrder(&rng)) |book| seen[book] = true;
    for (seen) |present| try check(present);
    executed_cases += 1;
}

/// Decoding frame by frame equals decoding them in one call (to f32
/// rounding: the reference's softmax groups follow the key-row length), and
/// every frame yields SAMPLES_PER_FRAME samples after the initial trim.
fn codecStreaming() !void {
    try writeGenerator(&fixture, "");
    try speech.build(CAPACITY, fixture.source(), &fixture.index, &gen_plan);
    var codes: [4 * speech.CODEBOOKS]i32 = undefined;
    for (&codes, 0..) |*code, i| code.* = @intCast((i * 5 + 3) % CODES);
    var whole: [4 * speech.SAMPLES_PER_FRAME + speech.FFT_SIZE]f32 = undefined;
    var stepped: [4 * speech.SAMPLES_PER_FRAME + speech.FFT_SIZE]f32 = undefined;
    codec_state.reset();
    var count = try speech.decode(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &codec_state, &codec_work, &codes, &whole, .{});
    try check(count == 4 * speech.SAMPLES_PER_FRAME - (speech.FFT_SIZE - speech.HOP) / 2);
    count += try speech.finish(GEN_LIMITS, &codec_state, whole[count..]);
    try check(count == 4 * speech.SAMPLES_PER_FRAME and codec_state.position == 0);
    var stepped_count: usize = 0;
    for (0..4) |frame| {
        stepped_count += try speech.decode(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &codec_state, &codec_work, codes[frame * speech.CODEBOOKS ..][0..speech.CODEBOOKS], stepped[stepped_count..], .{});
    }
    stepped_count += try speech.finish(GEN_LIMITS, &codec_state, stepped[stepped_count..]);
    try check(stepped_count == count);
    var error_sum: f64 = 0;
    var signal: f64 = 0;
    for (whole[0..count], stepped[0..count]) |a, b| {
        try check(std.math.isFinite(a));
        error_sum += (a - b) * (a - b);
        signal += a * a;
    }
    try check(signal > 0 and @sqrt(error_sum / signal) < 1e-4);
    var bad = codes;
    bad[0] = CODES; // the end code has no waveform
    try rejected(speech.decode(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &codec_state, &codec_work, bad[0..speech.CODEBOOKS], &whole, .{}), error.InvalidInput);
    try rejected(speech.decode(CAPACITY, GEN_LIMITS, fixture.source(), &fixture.index, &gen_plan, &codec_state, &codec_work, codes[0..5], &whole, .{}), error.InvalidInput);
    executed_cases += 1;
}

fn runCases() !void {
    try encoderPlan();
    try encoderStreaming();
    try encoderBounds();
    try generatorPlan();
    try maskGitPasses();
    try feedbackSum();
    try speakerFrames();
    try codecStreaming();
}

// The cases again as a test, for targets with no process to run `main` on
// (tools/aarch64_qemu runs them on bare-metal AArch64).
test "lfm3 audio contract cases" {
    try runCases();
}

pub fn main(init: std.process.Init) !void {
    if (comptime @import("builtin").os.tag == .windows) {
        if (std.mem.indexOf(u16, init.minimal.args.vector,
            std.unicode.utf8ToUtf16LeStringLiteral("--prove-failure")) != null) try check(false);
    } else {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        _ = args.next();
        if (args.next()) |argument| {
            if (std.mem.eql(u8, argument, "--prove-failure")) try check(false) else return error.UnknownArgument;
        }
    }
    try runCases();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer,
        "{{\"suite\":\"lfm3-audio\",\"pass\":true,\"cases\":{d},\"assertions\":{d}}}\n",
        .{ executed_cases, assertions });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
