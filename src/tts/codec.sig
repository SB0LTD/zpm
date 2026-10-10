//! Native Qwen3-TTS acoustic-frame decoder and bounded PCM submission contract.
//!
//! One 16-code frame produces exactly four 20 ms mono/24 kHz device periods.
//! The sink is injected by the platform, keeping the model layer independent
//! of VirtIO, Pixel AOC/TDM, or host audio APIs. Cancellation is checked before
//! inference and before every period transfer.

const std = @import("std");
const sb0m = @import("tts_model_container");
const plan_module = @import("tts_codec_plan");
const transformer = @import("tts_codec_transformer");
const vocoder = @import("tts_vocoder");

pub const PERIOD_SAMPLES: usize = 480;
pub const PERIODS_PER_FRAME: usize = plan_module.SAMPLES_PER_FRAME / PERIOD_SAMPLES;

pub const PcmSink = struct {
    context: ?*anyopaque,
    submit_fn: *const fn (?*anyopaque, u64, []const i16) bool,

    pub fn submit(self: PcmSink, correlation_id: u64, samples: []const i16) bool {
        return self.submit_fn(self.context, correlation_id, samples);
    }
};

pub const Error = transformer.Error || vocoder.Error || error{
    Cancelled,
    PlaybackBackpressure,
    InvalidSink,
};

pub const Runtime = struct {
    transformer_state: transformer.State = .{},
    vocoder_state: vocoder.State = .{},
    transformer_workspace: transformer.Workspace = .{},
    vocoder_workspace: vocoder.Workspace = .{},
    latent: [plan_module.LATENT]f32 = @splat(0),
    pcm: [plan_module.SAMPLES_PER_FRAME]f32 = @splat(0),
    period: [PERIOD_SAMPLES]i16 = @splat(0),
    cancelled: bool = false,
    frames_decoded: u64 = 0,
    periods_submitted: u64 = 0,
    // When true, the GPU vocoder (f32-exact, cuBLAS + custom kernels) decodes
    // the latent → PCM instead of the row-sliced CPU path. Set by enableGpu.
    gpu_vocoder: bool = false,
    // When true, the codes→latent transformer runs GPU-resident on the device
    // (its own f32 KV ring). Set by enableGpu.
    gpu_transformer: bool = false,

    pub fn reset(self: *Runtime) void {
        const keep_voc = self.gpu_vocoder;
        const keep_tr = self.gpu_transformer;
        self.* = .{};
        self.gpu_vocoder = keep_voc;
        self.gpu_transformer = keep_tr;
        if (keep_voc) vocoder.gpuResetCarry();
        if (keep_tr) transformer.gpuResetKv();
    }
    pub fn cancel(self: *Runtime) void { self.cancelled = true; }

    /// Try to move latent→PCM decoding onto the GPU: preload every vocoder
    /// weight into VRAM (dequantized f32) and switch decodeAndSubmit to the
    /// custom-kernel path. Returns true if the GPU vocoder is now active; on
    /// false the exact CPU vocoder stays in use. Call once after the plan is
    /// built. Idempotent.
    pub fn enableGpu(
        self: *Runtime,
        comptime capacity: usize,
        source: sb0m.Source,
        index: *const sb0m.Index(capacity),
        plan: *const plan_module.Plan,
    ) bool {
        if (self.gpu_vocoder) return true;
        if (!vocoder.gpuAvailable()) return false;
        if (!vocoder.gpuPreload(capacity, source, index, plan)) return false;
        vocoder.gpuResetCarry();
        self.gpu_vocoder = true;
        // Also move the codes→latent transformer onto the GPU when possible.
        // Independent of the vocoder: if this fails, the CPU transformer stays.
        if (transformer.gpuAvailable() and transformer.gpuPreload(capacity, source, index, plan)) {
            transformer.gpuResetKv();
            self.gpu_transformer = true;
        }
        return true;
    }



    pub fn decodeAndSubmit(
        self: *Runtime,
        comptime capacity: usize,
        source: sb0m.Source,
        index: *const sb0m.Index(capacity),
        plan: *const plan_module.Plan,
        codes: *const [plan_module.CODE_GROUPS]u16,
        correlation_id: u64,
        sink: PcmSink,
    ) Error!void {
        if (sink.context == null or correlation_id == 0) return error.InvalidSink;
        if (self.cancelled) return error.Cancelled;
        try transformer.decodeCodes(capacity, source, index, plan, codes,
            &self.transformer_state, &self.transformer_workspace, &self.latent, self.gpu_transformer);
        if (self.cancelled) return error.Cancelled;
        if (self.gpu_vocoder) {
            vocoder.decodeLatentGpu(capacity, source, index, plan, &self.latent,
                &self.vocoder_state, &self.pcm) catch {
                // On any GPU failure, fall back to the exact CPU path for this
                // frame (keeps correctness even if a launch/alloc hiccups).
                try vocoder.decodeLatent(capacity, source, index, plan, &self.latent,
                    &self.vocoder_state, &self.vocoder_workspace, &self.pcm);
            };
        } else {
            try vocoder.decodeLatent(capacity, source, index, plan, &self.latent,
                &self.vocoder_state, &self.vocoder_workspace, &self.pcm);
        }
        for (0..PERIODS_PER_FRAME) |period_index| {
            if (self.cancelled) return error.Cancelled;
            const source_period = self.pcm[period_index * PERIOD_SAMPLES ..][0..PERIOD_SAMPLES];
            f32ToPcm16(source_period, &self.period);
            if (!sink.submit(correlation_id, &self.period)) return error.PlaybackBackpressure;
            self.periods_submitted +|= 1;
        }
        self.frames_decoded +|= 1;
    }

    pub fn staticBytes() usize { return @sizeOf(Runtime); }
};

pub fn f32ToPcm16(input: []const f32, output: []i16) void {
    if (input.len != output.len) unreachable;
    for (input, output) |sample, *destination| {
        const finite = if (std.math.isFinite(sample)) sample else 0;
        const scaled = @round(std.math.clamp(finite, -1, 1) * 32767.0);
        destination.* = @intFromFloat(scaled);
    }
}

test "one acoustic frame is exactly four device periods" {
    try std.testing.expectEqual(@as(usize, 4), PERIODS_PER_FRAME);
    try std.testing.expectEqual(@as(usize, plan_module.SAMPLES_PER_FRAME), PERIODS_PER_FRAME * PERIOD_SAMPLES);
    try std.testing.expect(Runtime.staticBytes() < 8 * 1024 * 1024);
}

test "PCM conversion clamps and scrubs non-finite samples" {
    const input = [_]f32{ -2, -1, -0.5, 0, 0.5, 1, 2, std.math.nan(f32) };
    var output: [input.len]i16 = undefined;
    f32ToPcm16(&input, &output);
    try std.testing.expectEqual(@as(i16, -32767), output[0]);
    try std.testing.expectEqual(@as(i16, -32767), output[1]);
    try std.testing.expectEqual(@as(i16, 0), output[3]);
    try std.testing.expectEqual(@as(i16, 32767), output[5]);
    try std.testing.expectEqual(@as(i16, 32767), output[6]);
    try std.testing.expectEqual(@as(i16, 0), output[7]);
}
