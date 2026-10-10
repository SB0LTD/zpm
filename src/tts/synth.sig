//! Interruptible Qwen3-TTS text-to-acoustic-code runtime for Nexus.
//!
//! This implements the released Base checkpoint's exact no-reference-voice
//! schedule: assistant-role prefill, English codec tags, streamed trailing
//! text, Talker codebook zero, and fifteen autoregressive predictor groups.
//! It emits one complete 16-code frame at a time while all matrix work remains
//! row-sliced through the native executor.

const std = @import("std");
const plan_module = @import("tts_talker_plan");
const backend = @import("tts_talker_backend");
const executor = @import("tts_talker_executor");
const sampler_module = @import("tts_sampler");

pub const TALKER_CONTEXT: usize = 128;
pub const PREDICTOR_CONTEXT: usize = 16;
pub const MAX_TEXT_TOKENS: usize = 96;
pub const MAX_FRAMES: usize = TALKER_CONTEXT - 9;
pub const PREFILL_POSITIONS: usize = 9;

pub const IM_START: u32 = 151_644;
pub const IM_END: u32 = 151_645;
pub const ASSISTANT: u32 = 77_091;
pub const NEWLINE: u32 = 198;

const TalkerWork = executor.WorkingSet(TALKER_CONTEXT);
const PredictorWork = executor.WorkingSet(PREDICTOR_CONTEXT);
const TALKER_KV_ELEMENTS = plan_module.TALKER_LAYERS * 2 * plan_module.KV_HEADS * TALKER_CONTEXT * plan_module.HEAD_DIM;
const PREDICTOR_KV_ELEMENTS = plan_module.PREDICTOR_LAYERS * 2 * plan_module.KV_HEADS * PREDICTOR_CONTEXT * plan_module.HEAD_DIM;

pub const Error = executor.Error || sampler_module.Error || error{
    InvalidState,
    InvalidPrompt,
    TextCapacity,
    FrameCapacity,
    NumericalFailure,
    Cancelled,
};

pub const State = enum(u8) {
    idle,
    talker_prepare,
    talker_running,
    predictor_prepare,
    predictor_running,
    frame_ready,
    complete,
    cancelled,
};

pub const Frame = struct {
    index: u16 = 0,
    codes: [plan_module.CODE_GROUPS]u16 = @splat(0),
};

pub const StepResult = enum(u8) { pending, frame_ready, complete };

/// Per-utterance voice controls — exactly the knobs the released Qwen3-TTS
/// checkpoint exposes. Defaults reproduce the pinned Base generation config.
///   - `language_token` selects the codec language (see `languageToken`).
///   - `think` toggles the Talker's think prefix (CODEC_THINK vs CODEC_NOTHINK).
///   - the sampler fields steer delivery (higher temperature/top_k = more
///     varied prosody; repetition_penalty discourages loops).
pub const VoiceConfig = struct {
    language_token: u16 = plan_module.CODEC_ENGLISH,
    think: bool = true,
    talker_temperature: f32 = 0.9,
    talker_top_k: u8 = 50,
    talker_repetition_penalty: f32 = 1.05,
    predictor_temperature: f32 = 0.9,
    predictor_top_k: u8 = 50,

    pub const default: VoiceConfig = .{};
};

/// The codec language tokens the released model understands (config.json
/// `codec_language_id`). Returns null for an unknown name.
pub fn languageToken(name: []const u8) ?u16 {
    const table = [_]struct { name: []const u8, token: u16 }{
        .{ .name = "english", .token = plan_module.CODEC_ENGLISH },
        .{ .name = "chinese", .token = 2055 },
        .{ .name = "german", .token = 2053 },
        .{ .name = "spanish", .token = 2054 },
        .{ .name = "italian", .token = 2070 },
        .{ .name = "portuguese", .token = 2071 },
        .{ .name = "japanese", .token = 2058 },
        .{ .name = "korean", .token = 2064 },
        .{ .name = "french", .token = 2061 },
        .{ .name = "russian", .token = 2069 },
    };
    for (table) |e| {
        if (e.name.len == name.len) {
            var eq = true;
            for (e.name, name) |a, b| {
                const lo = if (b >= 'A' and b <= 'Z') b + 32 else b;
                if (a != lo) {
                    eq = false;
                    break;
                }
            }
            if (eq) return e.token;
        }
    }
    return null;
}

pub const Runtime = struct {
    state: State = .idle,
    cancelled: bool = false,
    config: VoiceConfig = VoiceConfig.default,
    input_tokens: [MAX_TEXT_TOKENS]u32 = @splat(0),
    input_count: usize = 0,
    talker_position: usize = 0,
    predictor_position: usize = 0,
    emitted_frames: usize = 0,
    frame: Frame = .{},
    code_zero_history: [MAX_FRAMES]u16 = @splat(0),
    sampler: sampler_module.Sampler = sampler_module.Sampler.init(1),
    talker_session: executor.Session = .{},
    predictor_session: executor.Session = .{},
    talker_work: TalkerWork = .{},
    predictor_work: PredictorWork = .{},
    talker_kv: [TALKER_KV_ELEMENTS]u16 = @splat(0),
    predictor_kv: [PREDICTOR_KV_ELEMENTS]u16 = @splat(0),
    frontend_scratch: backend.Scratch = .{},
    text_embedding: [plan_module.TEXT_HIDDEN]f32 = @splat(0),
    projected_text: [plan_module.TEXT_HIDDEN]f32 = @splat(0),
    projection_bias: [plan_module.TEXT_HIDDEN]f32 = @splat(0),
    input_embedding: [plan_module.HIDDEN]f32 = @splat(0),
    codec_embedding: [plan_module.HIDDEN]f32 = @splat(0),
    tts_pad_embedding: [plan_module.HIDDEN]f32 = @splat(0),
    tts_bos_embedding: [plan_module.HIDDEN]f32 = @splat(0),
    tts_eos_embedding: [plan_module.HIDDEN]f32 = @splat(0),
    past_hidden: [plan_module.HIDDEN]f32 = @splat(0),

    // GPU-resident decoder forwards (talker 28L / predictor 5L). When `gpu` is
    // true, the whole per-token layer stack runs on the device (custom kernels +
    // cuBLAS, f32) in a single step instead of the row-sliced CPU executor.
    gpu: bool = false,
    gpu_talker: executor.GpuForward = .{},
    gpu_predictor: executor.GpuForward = .{},

    pub fn staticBytes() usize {
        return @sizeOf(Runtime);
    }

    /// Try to move both decoder forwards onto the GPU. Preloads every talker +
    /// predictor weight into VRAM. Returns true if the GPU path is active; on
    /// false the exact CPU executor stays in use. Call once after load.
    pub fn enableGpu(
        self: *Runtime,
        comptime tensor_capacity: usize,
        source: backend.Source,
        index: *const backend.Index(tensor_capacity),
        plan: *const plan_module.Plan,
    ) bool {
        if (self.gpu) return true;
        if (!executor.gpuAvailable()) return false;
        // Talker: 28 layers, context 128, with the codec_head for logits.
        if (!self.gpu_talker.init(plan.talker.layer_count, TALKER_CONTEXT)) return false;
        if (!self.gpu_talker.preload(tensor_capacity, source, index, &plan.talker, plan.codec_head)) return false;
        // Predictor: 5 layers, context 16, with all 15 predictor heads.
        if (!self.gpu_predictor.init(plan.predictor.layer_count, PREDICTOR_CONTEXT)) return false;
        var ok = self.gpu_predictor.preload(tensor_capacity, source, index, &plan.predictor, null);
        for (plan.predictor_heads) |h| ok = ok and self.gpu_predictor.preloadHead(source, index, h);
        if (!ok) return false;
        self.gpu = true;
        return true;
    }

    pub fn begin(
        self: *Runtime,
        comptime tensor_capacity: usize,
        source: backend.Source,
        index: *const backend.Index(tensor_capacity),
        plan: *const plan_module.Plan,
        tokens: []const u32,
        entropy_seed: u64,
        config: VoiceConfig,
    ) Error!void {
        if (self.state != .idle and self.state != .complete and self.state != .cancelled)
            return error.InvalidState;
        self.config = config;
        try validatePrompt(tokens);
        if (tokens.len > self.input_tokens.len) return error.TextCapacity;
        @memset(&self.talker_kv, 0);
        @memset(&self.predictor_kv, 0);
        @memset(&self.input_tokens, 0);
        @memcpy(self.input_tokens[0..tokens.len], tokens);
        self.input_count = tokens.len;
        self.talker_position = 0;
        self.predictor_position = 0;
        self.emitted_frames = 0;
        self.frame = .{};
        self.code_zero_history = @splat(0);
        self.sampler = sampler_module.Sampler.init(entropy_seed);
        self.talker_session = .{};
        self.predictor_session = .{};
        self.cancelled = false;
        if (self.gpu) {
            self.gpu_talker.resetKv();
            self.gpu_predictor.resetKv();
        }
        try projectText(source, index, plan, plan_module.TEXT_TTS_PAD, &self.tts_pad_embedding, self);
        try projectText(source, index, plan, plan_module.TEXT_TTS_BOS, &self.tts_bos_embedding, self);
        try projectText(source, index, plan, plan_module.TEXT_TTS_EOS, &self.tts_eos_embedding, self);
        self.state = .talker_prepare;
    }

    pub fn step(
        self: *Runtime,
        comptime tensor_capacity: usize,
        source: backend.Source,
        index: *const backend.Index(tensor_capacity),
        plan: *const plan_module.Plan,
        row_budget: usize,
        progress: executor.Progress,
    ) Error!StepResult {
        if (self.cancelled or self.state == .cancelled) return error.Cancelled;
        if (row_budget == 0) return error.InvalidState;
        return switch (self.state) {
            .idle => error.InvalidState,
            .talker_prepare => block: {
                try self.prepareTalkerInput(source, index, plan);
                self.talker_session = .{};
                const output_head: ?plan_module.TensorRef = if (self.talker_position + 1 >= PREFILL_POSITIONS)
                    plan.codec_head
                else
                    null;
                if (self.gpu) {
                    // GPU path: run the whole 28-layer forward in one step,
                    // producing normalized + logits, then reuse the completion
                    // logic. The device holds its own KV cache.
                    try self.gpu_talker.forward(
                        tensor_capacity,
                        source,
                        index,
                        &plan.talker,
                        &self.input_embedding,
                        self.talker_position,
                        output_head,
                        &self.talker_work.normalized,
                        if (output_head != null) self.talker_work.logits[0..plan_module.CODEC_VOCABULARY] else null,
                    );
                    break :block try self.completeTalker(output_head != null);
                }
                try executor.begin(
                    TALKER_CONTEXT,
                    &plan.talker,
                    &self.talker_kv,
                    &self.talker_session,
                    &self.talker_work,
                    &self.input_embedding,
                    self.talker_position,
                    output_head,
                );
                self.state = .talker_running;
                break :block .pending;
            },
            .talker_running => switch (try executor.step(
                tensor_capacity,
                TALKER_CONTEXT,
                source,
                index,
                &plan.talker,
                &self.talker_work,
                &self.talker_kv,
                &self.talker_session,
                row_budget,
                progress,
            )) {
                .pending => .pending,
                .complete => |selected| block: {
                    if (self.talker_position + 1 < PREFILL_POSITIONS) {
                        if (selected != null) return error.InvalidState;
                        self.talker_position += 1;
                        self.state = .talker_prepare;
                        break :block .pending;
                    }
                    if (selected == null) return error.InvalidState;
                    const code_zero = try self.sampleTalker();
                    if (code_zero == plan_module.CODEC_EOS) {
                        self.state = .complete;
                        break :block .complete;
                    }
                    self.frame = .{ .index = @intCast(self.emitted_frames) };
                    self.frame.codes[0] = code_zero;
                    @memcpy(&self.past_hidden, &self.talker_work.normalized);
                    @memset(&self.predictor_kv, 0);
                    self.predictor_position = 0;
                    self.predictor_session = .{};
                    self.state = .predictor_prepare;
                    break :block .pending;
                },
            },
            .predictor_prepare => block: {
                try self.preparePredictorInput(source, index, plan);
                self.predictor_session = .{};
                const output_head: ?plan_module.TensorRef = if (self.predictor_position == 0)
                    null
                else
                    plan.predictor_heads[self.predictor_position - 1];
                if (self.gpu) {
                    try self.gpu_predictor.forward(
                        tensor_capacity,
                        source,
                        index,
                        &plan.predictor,
                        &self.input_embedding,
                        self.predictor_position,
                        output_head,
                        &self.predictor_work.normalized,
                        if (output_head != null) self.predictor_work.logits[0..plan_module.ACOUSTIC_VOCABULARY] else null,
                    );
                    break :block try self.completePredictor(output_head != null);
                }
                try executor.begin(
                    PREDICTOR_CONTEXT,
                    &plan.predictor,
                    &self.predictor_kv,
                    &self.predictor_session,
                    &self.predictor_work,
                    &self.input_embedding,
                    self.predictor_position,
                    output_head,
                );
                self.state = .predictor_running;
                break :block .pending;
            },
            .predictor_running => switch (try executor.step(
                tensor_capacity,
                PREDICTOR_CONTEXT,
                source,
                index,
                &plan.predictor,
                &self.predictor_work,
                &self.predictor_kv,
                &self.predictor_session,
                row_budget,
                progress,
            )) {
                .pending => .pending,
                .complete => |selected| block: {
                    if (self.predictor_position == 0) {
                        if (selected != null) return error.InvalidState;
                    } else {
                        if (selected == null) return error.InvalidState;
                        self.frame.codes[self.predictor_position] = try self.sampler.sample(
                            self.predictor_work.logits[0..plan_module.ACOUSTIC_VOCABULARY],
                            &.{},
                            .{ .top_k = self.config.predictor_top_k, .temperature = self.config.predictor_temperature, .repetition_penalty = 1 },
                        );
                    }
                    if (self.predictor_position + 1 == plan_module.CODE_GROUPS) {
                        self.state = .frame_ready;
                        break :block .frame_ready;
                    }
                    self.predictor_position += 1;
                    self.state = .predictor_prepare;
                    break :block .pending;
                },
            },
            .frame_ready => .frame_ready,
            .complete => .complete,
            .cancelled => error.Cancelled,
        };
    }

    // Shared predictor-completion logic. `produced` = a logits head ran.
    fn completePredictor(self: *Runtime, produced: bool) Error!StepResult {
        if (self.predictor_position == 0) {
            if (produced) return error.InvalidState;
        } else {
            if (!produced) return error.InvalidState;
            self.frame.codes[self.predictor_position] = try self.sampler.sample(
                self.predictor_work.logits[0..plan_module.ACOUSTIC_VOCABULARY],
                &.{},
                .{ .top_k = self.config.predictor_top_k, .temperature = self.config.predictor_temperature, .repetition_penalty = 1 },
            );
        }
        if (self.predictor_position + 1 == plan_module.CODE_GROUPS) {
            self.state = .frame_ready;
            return .frame_ready;
        }
        self.predictor_position += 1;
        self.state = .predictor_prepare;
        return .pending;
    }

    // Shared talker-completion logic (used by both the CPU step path and the
    // GPU forward path). `produced` = a logits head ran this position.
    fn completeTalker(self: *Runtime, produced: bool) Error!StepResult {
        if (self.talker_position + 1 < PREFILL_POSITIONS) {
            if (produced) return error.InvalidState;
            self.talker_position += 1;
            self.state = .talker_prepare;
            return .pending;
        }
        if (!produced) return error.InvalidState;
        const code_zero = try self.sampleTalker();
        if (code_zero == plan_module.CODEC_EOS) {
            self.state = .complete;
            return .complete;
        }
        self.frame = .{ .index = @intCast(self.emitted_frames) };
        self.frame.codes[0] = code_zero;
        @memcpy(&self.past_hidden, &self.talker_work.normalized);
        @memset(&self.predictor_kv, 0);
        if (self.gpu) self.gpu_predictor.resetKv();
        self.predictor_position = 0;
        self.predictor_session = .{};
        self.state = .predictor_prepare;
        return .pending;
    }

    pub fn takeFrame(self: *Runtime, destination: *Frame) Error!void {
        if (self.state != .frame_ready) return error.InvalidState;
        destination.* = self.frame;
        self.code_zero_history[self.emitted_frames] = self.frame.codes[0];
        self.emitted_frames += 1;
        if (self.emitted_frames == MAX_FRAMES) {
            self.state = .complete;
            return;
        }
        self.talker_position += 1;
        self.state = .talker_prepare;
    }

    pub fn cancel(self: *Runtime) void {
        self.cancelled = true;
        self.talker_session = .{};
        self.predictor_session = .{};
        self.state = .cancelled;
    }

    fn sampleTalker(self: *Runtime) Error!u16 {
        if (self.emitted_frames < 2)
            self.talker_work.logits[plan_module.CODEC_EOS] = -1.0e30;
        return self.sampler.sample(
            self.talker_work.logits[0..plan_module.CODEC_VOCABULARY],
            self.code_zero_history[0..self.emitted_frames],
            .{
                .top_k = self.config.talker_top_k,
                .temperature = self.config.talker_temperature,
                .repetition_penalty = self.config.talker_repetition_penalty,
                .suppress_reserved = true,
            },
        );
    }

    fn prepareTalkerInput(self: *Runtime, source: backend.Source, index: anytype, plan: *const plan_module.Plan) Error!void {
        @memset(&self.input_embedding, 0);
        if (self.talker_position < 3) {
            try projectText(source, index, plan, self.input_tokens[self.talker_position], &self.input_embedding, self);
            return;
        }
        const codec_prefix = [_]u16{
            if (self.config.think) plan_module.CODEC_THINK else plan_module.CODEC_NOTHINK,
            plan_module.CODEC_THINK_BOS,
            self.config.language_token,
            plan_module.CODEC_THINK_EOS,
            plan_module.CODEC_PAD,
            plan_module.CODEC_BOS,
        };
        if (self.talker_position < 7) {
            self.input_embedding = self.tts_pad_embedding;
            try addCodec(source, index, plan, codec_prefix[self.talker_position - 3], &self.input_embedding, self);
            return;
        }
        if (self.talker_position == 7) {
            self.input_embedding = self.tts_bos_embedding;
            try addCodec(source, index, plan, plan_module.CODEC_PAD, &self.input_embedding, self);
            return;
        }
        if (self.talker_position == 8) {
            try projectText(source, index, plan, self.input_tokens[3], &self.input_embedding, self);
            try addCodec(source, index, plan, plan_module.CODEC_BOS, &self.input_embedding, self);
            return;
        }

        try backend.readEmbedding(source, tensor(index, plan.codec_embedding), self.frame.codes[0], &self.input_embedding, &self.frontend_scratch);
        for (1..plan_module.CODE_GROUPS) |group| {
            try backend.readEmbedding(
                source,
                tensor(index, plan.predictor_embeddings[group - 1]),
                self.frame.codes[group],
                &self.codec_embedding,
                &self.frontend_scratch,
            );
            try addVector(&self.input_embedding, &self.codec_embedding);
        }
        const trailing_index = self.emitted_frames;
        const remaining_text = self.input_count - 9;
        if (trailing_index < remaining_text) {
            try projectText(source, index, plan, self.input_tokens[4 + trailing_index], &self.codec_embedding, self);
        } else if (trailing_index == remaining_text) {
            self.codec_embedding = self.tts_eos_embedding;
        } else {
            self.codec_embedding = self.tts_pad_embedding;
        }
        try addVector(&self.input_embedding, &self.codec_embedding);
    }

    fn preparePredictorInput(self: *Runtime, source: backend.Source, index: anytype, plan: *const plan_module.Plan) Error!void {
        if (self.predictor_position == 0) {
            self.input_embedding = self.past_hidden;
        } else if (self.predictor_position == 1) {
            try backend.readEmbedding(source, tensor(index, plan.codec_embedding), self.frame.codes[0], &self.input_embedding, &self.frontend_scratch);
        } else {
            const group = self.predictor_position - 1;
            try backend.readEmbedding(
                source,
                tensor(index, plan.predictor_embeddings[group - 1]),
                self.frame.codes[group],
                &self.input_embedding,
                &self.frontend_scratch,
            );
        }
    }
};

fn projectText(
    source: backend.Source,
    index: anytype,
    plan: *const plan_module.Plan,
    token: u32,
    output: *[plan_module.HIDDEN]f32,
    runtime: *Runtime,
) Error!void {
    if (token >= plan_module.TEXT_VOCABULARY) return error.InvalidPrompt;
    try backend.readEmbedding(source, tensor(index, plan.text_embedding), token, &runtime.text_embedding, &runtime.frontend_scratch);
    try backend.readVector(source, tensor(index, plan.text_projection_1_bias), &runtime.projection_bias, &runtime.frontend_scratch);
    try backend.prepareMatvec(&runtime.text_embedding, &runtime.frontend_scratch);
    const first = try backend.matvecRows(
        source,
        tensor(index, plan.text_projection_1),
        &runtime.text_embedding,
        &runtime.projected_text,
        &runtime.projection_bias,
        0,
        plan_module.TEXT_HIDDEN,
        &runtime.frontend_scratch,
    );
    if (first != plan_module.TEXT_HIDDEN) return error.InvalidState;
    for (&runtime.projected_text) |*value| {
        value.* = value.* / (1 + @exp(-value.*));
        if (!std.math.isFinite(value.*)) return error.NumericalFailure;
    }
    try backend.readVector(source, tensor(index, plan.text_projection_2_bias), runtime.projection_bias[0..plan_module.HIDDEN], &runtime.frontend_scratch);
    try backend.prepareMatvec(&runtime.projected_text, &runtime.frontend_scratch);
    const second = try backend.matvecRows(
        source,
        tensor(index, plan.text_projection_2),
        &runtime.projected_text,
        output,
        runtime.projection_bias[0..plan_module.HIDDEN],
        0,
        plan_module.HIDDEN,
        &runtime.frontend_scratch,
    );
    if (second != plan_module.HIDDEN) return error.InvalidState;
}

fn addCodec(source: backend.Source, index: anytype, plan: *const plan_module.Plan, code: u16, output: *[plan_module.HIDDEN]f32, runtime: *Runtime) Error!void {
    try backend.readEmbedding(source, tensor(index, plan.codec_embedding), code, &runtime.codec_embedding, &runtime.frontend_scratch);
    try addVector(output, &runtime.codec_embedding);
}

fn addVector(destination: []f32, addition: []const f32) Error!void {
    if (destination.len != addition.len) return error.InvalidState;
    for (destination, addition) |*value, added| {
        value.* += added;
        if (!std.math.isFinite(value.*)) return error.NumericalFailure;
    }
}

fn tensor(index: anytype, reference: plan_module.TensorRef) *const backend.TensorInfo {
    if (!reference.present() or reference.index >= index.tensor_count) unreachable;
    return &index.tensors[reference.index];
}

fn validatePrompt(tokens: []const u32) Error!void {
    if (tokens.len < 10 or tokens.len > MAX_TEXT_TOKENS or
        tokens[0] != IM_START or tokens[1] != ASSISTANT or tokens[2] != NEWLINE or
        tokens[tokens.len - 5] != IM_END or tokens[tokens.len - 4] != NEWLINE or
        tokens[tokens.len - 3] != IM_START or tokens[tokens.len - 2] != ASSISTANT or
        tokens[tokens.len - 1] != NEWLINE)
        return error.InvalidPrompt;
    for (tokens) |token| if (token >= plan_module.TEXT_VOCABULARY) return error.InvalidPrompt;
}

test "official assistant prompt boundary is exact" {
    const tokens = [_]u32{ IM_START, ASSISTANT, NEWLINE, 9707, 13, IM_END, NEWLINE, IM_START, ASSISTANT, NEWLINE };
    try validatePrompt(&tokens);
    var invalid = tokens;
    invalid[invalid.len - 3] = 0;
    try std.testing.expectError(error.InvalidPrompt, validatePrompt(&invalid));
}

test "runtime footprint includes both explicit KV domains" {
    try std.testing.expectEqual(@as(usize, 7_340_032), TALKER_KV_ELEMENTS);
    try std.testing.expectEqual(@as(usize, 163_840), PREDICTOR_KV_ELEMENTS);
    try std.testing.expect(Runtime.staticBytes() < 16 * 1024 * 1024);
}

test "language tokens map to the released codec ids and reject unknowns" {
    try std.testing.expectEqual(@as(?u16, plan_module.CODEC_ENGLISH), languageToken("english"));
    try std.testing.expectEqual(@as(?u16, plan_module.CODEC_ENGLISH), languageToken("English")); // case-insensitive
    try std.testing.expectEqual(@as(?u16, 2058), languageToken("japanese"));
    try std.testing.expectEqual(@as(?u16, 2069), languageToken("russian"));
    try std.testing.expectEqual(@as(?u16, null), languageToken("klingon"));
}

test "default voice config matches the pinned base generation config" {
    const c = VoiceConfig.default;
    try std.testing.expectEqual(plan_module.CODEC_ENGLISH, c.language_token);
    try std.testing.expect(c.think);
    try std.testing.expectEqual(@as(u8, 50), c.talker_top_k);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), c.talker_temperature, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), c.talker_repetition_penalty, 1e-6);
}
