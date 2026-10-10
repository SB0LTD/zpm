//! Stateful native Qwen3-TTS latent-to-PCM vocoder.
//!
//! The exact causal ConvNeXt and SnakeBeta decoder expands each 12.5 Hz latent
//! frame by 2*2*8*5*4*3 into 1,920 mono samples at 24 kHz.  Every causal and
//! transposed-convolution boundary has explicit persistent state, preventing
//! frame seams while retaining fixed storage and bounded execution.

const std = @import("std");
const sb0m = @import("tts_model_container");
const plan_module = @import("tts_codec_plan");
const backend = @import("tts_codec_backend");
const kernels = @import("tts_kernels");

const MAX_VALUES: usize = plan_module.SAMPLES_PER_FRAME * 96;
const RESIDUAL_HISTORY_VALUES: usize = 112_320;
const TRANSPOSE_CARRY_VALUES: usize = 9_120;

pub const Error = backend.Error || error{ InvalidPlan, InvalidShape, NonFinite };

pub const State = struct {
    pre_upsample_history: [plan_module.PRE_UPSAMPLE_STAGES][6 * plan_module.LATENT]f32 = @splat(@splat(0)),
    pre_upsample_cursor: [plan_module.PRE_UPSAMPLE_STAGES]u8 = @splat(0),
    pre_upsample_count: [plan_module.PRE_UPSAMPLE_STAGES]u8 = @splat(0),
    decoder_input_history: [6 * plan_module.LATENT]f32 = @splat(0),
    decoder_input_cursor: u8 = 0,
    decoder_input_count: u8 = 0,
    transpose_carry: [TRANSPOSE_CARRY_VALUES]f32 = @splat(0),
    residual_history: [RESIDUAL_HISTORY_VALUES]f32 = @splat(0),
    residual_cursor: [plan_module.DECODER_STAGES][plan_module.RESIDUAL_UNITS]u8 = @splat(@splat(0)),
    residual_count: [plan_module.DECODER_STAGES][plan_module.RESIDUAL_UNITS]u8 = @splat(@splat(0)),
    output_history: [6 * 96]f32 = @splat(0),
    output_cursor: u8 = 0,
    output_count: u8 = 0,

    pub fn reset(self: *State) void { self.* = .{}; }
};

pub const Workspace = struct {
    tensor: backend.Scratch = .{},
    a: [MAX_VALUES]f32 = @splat(0),
    b: [MAX_VALUES]f32 = @splat(0),
    c: [MAX_VALUES]f32 = @splat(0),
    flat: [backend.MAX_ROW_ELEMENTS]f32 = @splat(0),
    wide: [4 * plan_module.LATENT]f32 = @splat(0),
    bias: [4 * plan_module.LATENT]f32 = @splat(0),
    parameter_1: [4 * plan_module.LATENT]f32 = @splat(0),
    parameter_2: [4 * plan_module.LATENT]f32 = @splat(0),
};

pub fn decodeLatent(
    comptime capacity: usize,
    source: sb0m.Source,
    index: *const sb0m.Index(capacity),
    plan: *const plan_module.Plan,
    latent: *const [plan_module.LATENT]f32,
    state: *State,
    workspace: *Workspace,
    pcm: *[plan_module.SAMPLES_PER_FRAME]f32,
) Error!void {
    if (plan.bound_tensors != plan_module.BOUND_TENSORS) return error.InvalidPlan;
    @memcpy(workspace.a[0..plan_module.LATENT], latent);
    var frames: usize = 1;
    var current_channels: usize = plan_module.LATENT;

    for (plan.pre_upsample, 0..) |stage, stage_index| {
        try transposed(
            source,
            index,
            stage.transposed,
            workspace.a[0 .. frames * current_channels],
            frames,
            current_channels,
            current_channels,
            2,
            2,
            workspace.b[0 .. frames * 2 * current_channels],
            &.{},
            workspace,
        );
        frames *= 2;
        try convNext(
            source,
            index,
            stage.conv_next,
            workspace.b[0 .. frames * current_channels],
            frames,
            workspace.a[0 .. frames * current_channels],
            state.pre_upsample_history[stage_index][0..],
            &state.pre_upsample_cursor[stage_index],
            &state.pre_upsample_count[stage_index],
            workspace,
        );
    }

    try causalConv(
        source,
        index,
        plan.decoder_input,
        workspace.a[0 .. frames * plan_module.LATENT],
        frames,
        plan_module.LATENT,
        1536,
        7,
        1,
        workspace.b[0 .. frames * 1536],
        &state.decoder_input_history,
        &state.decoder_input_cursor,
        &state.decoder_input_count,
        workspace,
    );
    current_channels = 1536;
    @memcpy(workspace.a[0 .. frames * current_channels], workspace.b[0 .. frames * current_channels]);

    const output_channels = [_]usize{ 768, 384, 192, 96 };
    const strides = [_]usize{ 8, 5, 4, 3 };
    const kernel_sizes = [_]usize{ 16, 10, 8, 6 };
    const dilations = [_]usize{ 1, 3, 9 };
    for (plan.decoder_stages, output_channels, strides, kernel_sizes, 0..) |stage, next_channels, stride, kernel, stage_index| {
        try snakeSequence(source, index, stage.activation,
            workspace.a[0 .. frames * current_channels], frames, current_channels, workspace);
        const next_frames = frames * stride;
        const carry = transposeCarry(state, stage_index, next_channels, stride);
        try transposed(
            source,
            index,
            stage.transposed,
            workspace.a[0 .. frames * current_channels],
            frames,
            current_channels,
            next_channels,
            kernel,
            stride,
            workspace.b[0 .. next_frames * next_channels],
            carry,
            workspace,
        );
        frames = next_frames;
        current_channels = next_channels;
        for (stage.residual, dilations, 0..) |unit, dilation, unit_index| {
            try snakeTo(source, index, unit.act_1,
                workspace.b[0 .. frames * current_channels],
                workspace.a[0 .. frames * current_channels], frames, current_channels, workspace);
            const history = residualHistory(state, stage_index, unit_index, current_channels, 6 * dilation);
            try causalConv(
                source,
                index,
                unit.conv_1,
                workspace.a[0 .. frames * current_channels],
                frames,
                current_channels,
                current_channels,
                7,
                dilation,
                workspace.c[0 .. frames * current_channels],
                history,
                &state.residual_cursor[stage_index][unit_index],
                &state.residual_count[stage_index][unit_index],
                workspace,
            );
            try snakeTo(source, index, unit.act_2,
                workspace.c[0 .. frames * current_channels],
                workspace.a[0 .. frames * current_channels], frames, current_channels, workspace);
            // Kernel 1 has no temporal state.
            var no_history: [0]f32 = .{};
            var no_cursor: u8 = 0;
            var no_count: u8 = 0;
            try causalConv(
                source,
                index,
                unit.conv_2,
                workspace.a[0 .. frames * current_channels],
                frames,
                current_channels,
                current_channels,
                1,
                1,
                workspace.c[0 .. frames * current_channels],
                &no_history,
                &no_cursor,
                &no_count,
                workspace,
            );
            for (workspace.b[0 .. frames * current_channels], workspace.c[0 .. frames * current_channels]) |*residual, update|
                residual.* += update;
        }
        @memcpy(workspace.a[0 .. frames * current_channels], workspace.b[0 .. frames * current_channels]);
    }
    if (frames != plan_module.SAMPLES_PER_FRAME or current_channels != 96) return error.InvalidShape;
    try snakeSequence(source, index, plan.output_activation,
        workspace.a[0 .. frames * current_channels], frames, current_channels, workspace);
    try causalConv(
        source,
        index,
        plan.output_conv,
        workspace.a[0 .. frames * current_channels],
        frames,
        current_channels,
        1,
        7,
        1,
        workspace.b[0..frames],
        &state.output_history,
        &state.output_cursor,
        &state.output_count,
        workspace,
    );
    for (pcm, workspace.b[0..frames]) |*destination, sample| {
        destination.* = std.math.clamp(sample, -1, 1);
        if (!std.math.isFinite(destination.*)) return error.NonFinite;
    }
}

fn convNext(source: sb0m.Source, index: anytype, block: plan_module.ConvNext,
    input: []const f32, frames: usize, output: []f32, history: []f32,
    cursor: *u8, count: *u8, workspace: *Workspace) Error!void {
    const channels = plan_module.LATENT;
    try backend.readVector(source, tensor(index, block.depthwise.bias), workspace.bias[0..channels], &workspace.tensor);
    for (0..frames) |frame| {
        const frame_input = input[frame * channels ..][0..channels];
        const frame_output = output[frame * channels ..][0..channels];
        for (0..channels) |channel| {
            try backend.readRow(source, tensor(index, block.depthwise.weight), channel,
                workspace.tensor.row[0..7], &workspace.tensor);
            var value = workspace.bias[channel] + workspace.tensor.row[6] * frame_input[channel];
            for (0..6) |tap| {
                const lag = 6 - tap;
                if (count.* >= lag) {
                    const slot = (@as(usize, cursor.*) + 6 - lag) % 6;
                    value += workspace.tensor.row[tap] * history[slot * channels + channel];
                }
            }
            frame_output[channel] = value;
        }
        pushHistory(history, 6, channels, cursor, count, frame_input);
    }
    try backend.readVector(source, tensor(index, block.norm_weight), workspace.parameter_1[0..channels], &workspace.tensor);
    try backend.readVector(source, tensor(index, block.norm_bias), workspace.parameter_2[0..channels], &workspace.tensor);
    for (0..frames) |frame| {
        const residual = input[frame * channels ..][0..channels];
        const hidden = output[frame * channels ..][0..channels];
        layerNorm(hidden, workspace.parameter_1[0..channels], workspace.parameter_2[0..channels]);
        try linear(source, index, block.pointwise_1, hidden, &workspace.wide, workspace);
        for (&workspace.wide) |*value| value.* = gelu(value.*);
        try linear(source, index, block.pointwise_2, &workspace.wide, workspace.flat[0..channels], workspace);
        // Gamma is deliberately loaded after the pointwise biases have reused the bias buffer.
        try backend.readVector(source, tensor(index, block.gamma), workspace.bias[0..channels], &workspace.tensor);
        for (hidden, workspace.flat[0..channels], workspace.bias[0..channels], residual) |*destination, update, gamma, original|
            destination.* = original + gamma * update;
    }
}

fn causalConv(source: sb0m.Source, index: anytype, conv: plan_module.Conv,
    input: []const f32, frames: usize, input_channels: usize, output_channels: usize,
    kernel: usize, dilation: usize, output: []f32, history: []f32,
    cursor: *u8, count: *u8, workspace: *Workspace) Error!void {
    const padding = (kernel - 1) * dilation;
    if (input.len != frames * input_channels or output.len != frames * output_channels or
        history.len != padding * input_channels or input_channels * kernel > workspace.flat.len)
        return error.InvalidShape;
    try backend.readVector(source, tensor(index, conv.bias), workspace.bias[0..output_channels], &workspace.tensor);
    for (0..frames) |frame| {
        const frame_input = input[frame * input_channels ..][0..input_channels];
        for (0..input_channels) |channel| {
            for (0..kernel) |tap| {
                const lag = (kernel - 1 - tap) * dilation;
                workspace.flat[channel * kernel + tap] = if (lag == 0) frame_input[channel] else if (count.* < lag) 0 else blk: {
                    const slot = (@as(usize, cursor.*) + padding - lag) % padding;
                    break :blk history[slot * input_channels + channel];
                };
            }
        }
        try backend.matvec(source, tensor(index, conv.weight), workspace.flat[0 .. input_channels * kernel],
            output[frame * output_channels ..][0..output_channels], workspace.bias[0..output_channels], &workspace.tensor);
        if (padding != 0) pushHistory(history, padding, input_channels, cursor, count, frame_input);
    }
}

fn transposed(source: sb0m.Source, index: anytype, conv: plan_module.Conv,
    input: []const f32, frames: usize, input_channels: usize, output_channels: usize,
    kernel: usize, stride: usize, output: []f32, carry: []f32, workspace: *Workspace) Error!void {
    const has_overlap = kernel > stride;
    if (kernel == 0 or stride == 0 or kernel < stride or input.len != frames * input_channels or
        output.len != frames * stride * output_channels or
        carry.len != (if (has_overlap) stride * output_channels else 0)) return error.InvalidShape;
    try backend.readVector(source, tensor(index, conv.bias), workspace.bias[0..output_channels], &workspace.tensor);
    for (0..frames) |frame| {
        const block = output[frame * stride * output_channels ..][0 .. stride * output_channels];
        for (0..stride) |phase| {
            for (0..output_channels) |channel| {
                block[phase * output_channels + channel] = workspace.bias[channel] +
                    if (has_overlap) carry[phase * output_channels + channel] else 0;
            }
        }
        if (has_overlap) @memset(carry, 0);
        for (0..input_channels) |input_channel| {
            try backend.readRow(source, tensor(index, conv.weight), input_channel,
                workspace.tensor.row[0 .. output_channels * kernel], &workspace.tensor);
            const activation = input[frame * input_channels + input_channel];
            for (0..output_channels) |output_channel| {
                const row = workspace.tensor.row[output_channel * kernel ..][0..kernel];
                for (0..stride) |phase| {
                    block[phase * output_channels + output_channel] += activation * row[phase];
                    if (has_overlap)
                        carry[phase * output_channels + output_channel] += activation * row[phase + stride];
                }
            }
        }
    }
}

fn snakeSequence(source: sb0m.Source, index: anytype, snake: plan_module.Snake,
    values: []f32, frames: usize, channels: usize, workspace: *Workspace) Error!void {
    try backend.readVector(source, tensor(index, snake.alpha), workspace.parameter_1[0..channels], &workspace.tensor);
    try backend.readVector(source, tensor(index, snake.beta), workspace.parameter_2[0..channels], &workspace.tensor);
    for (0..frames) |frame| for (0..channels) |channel| {
        const value = values[frame * channels + channel];
        const alpha = @exp(workspace.parameter_1[channel]);
        const beta = @exp(workspace.parameter_2[channel]);
        const sine = @sin(value * alpha);
        values[frame * channels + channel] = value + sine * sine / (beta + 0.000000001);
    };
}

fn snakeTo(source: sb0m.Source, index: anytype, snake: plan_module.Snake,
    input: []const f32, output: []f32, frames: usize, channels: usize, workspace: *Workspace) Error!void {
    @memcpy(output, input);
    try snakeSequence(source, index, snake, output, frames, channels, workspace);
}

fn linear(source: sb0m.Source, index: anytype, value: plan_module.Linear,
    input: []const f32, output: []f32, workspace: *Workspace) Error!void {
    try backend.readVector(source, tensor(index, value.bias), workspace.bias[0..output.len], &workspace.tensor);
    try backend.matvec(source, tensor(index, value.weight), input, output,
        workspace.bias[0..output.len], &workspace.tensor);
}

fn layerNorm(values: []f32, weight: []const f32, bias: []const f32) void {
    var sum: f64 = 0;
    for (values) |value| sum += value;
    const mean: f32 = @floatCast(sum / @as(f64, @floatFromInt(values.len)));
    var squared: f64 = 0;
    for (values) |value| {
        const centered = value - mean;
        squared += @as(f64, centered) * centered;
    }
    const inverse: f32 = @floatCast(1.0 / @sqrt(squared / @as(f64, @floatFromInt(values.len)) + 0.000001));
    for (values, weight, bias) |*value, scale, offset| value.* = (value.* - mean) * inverse * scale + offset;
}

fn pushHistory(history: []f32, slots: usize, channels: usize, cursor: *u8,
    count: *u8, input: []const f32) void {
    const slot: usize = cursor.*;
    @memcpy(history[slot * channels ..][0..channels], input);
    cursor.* = @intCast((slot + 1) % slots);
    count.* = @intCast(@min(@as(usize, count.*) + 1, slots));
}

fn transposeCarry(state: *State, stage: usize, channels: usize, stride: usize) []f32 {
    const offsets = [_]usize{ 0, 768 * 8, 768 * 8 + 384 * 5, 768 * 8 + 384 * 5 + 192 * 4 };
    return state.transpose_carry[offsets[stage]..][0 .. channels * stride];
}

fn residualHistory(state: *State, stage: usize, unit: usize, channels: usize, padding: usize) []f32 {
    const channel_table = [_]usize{ 768, 384, 192, 96 };
    const padding_table = [_]usize{ 6, 18, 54 };
    var offset: usize = 0;
    for (0..stage) |prior_stage| {
        for (padding_table) |prior_padding| offset += channel_table[prior_stage] * prior_padding;
    }
    for (0..unit) |prior_unit| offset += channels * padding_table[prior_unit];
    return state.residual_history[offset..][0 .. channels * padding];
}

fn gelu(value: f32) f32 {
    // PyTorch GELU's erf form. Sig's freestanding math surface does not expose
    // erf yet; this fixed polynomial has <1.5e-7 maximum absolute error.
    return 0.5 * value * (1.0 + erf(value * 0.7071067811865476));
}

fn erf(value: f32) f32 {
    const sign: f32 = if (value < 0) -1 else 1;
    const x = @abs(value);
    const t = 1.0 / (1.0 + 0.3275911 * x);
    const polynomial = (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t -
        0.284496736) * t + 0.254829592) * t;
    return sign * (1.0 - polynomial * @exp(-(x * x)));
}

fn tensor(index: anytype, reference: plan_module.TensorRef) *const sb0m.Tensor {
    if (!reference.present() or reference.index >= index.tensor_count) unreachable;
    return &index.tensors[reference.index];
}

test "vocoder state and scratch are fixed and correctly sized" {
    try std.testing.expectEqual(@as(usize, 112_320), RESIDUAL_HISTORY_VALUES);
    try std.testing.expectEqual(@as(usize, 9_120), TRANSPOSE_CARRY_VALUES);
    try std.testing.expect(@sizeOf(State) < 1024 * 1024);
    try std.testing.expect(@sizeOf(Workspace) < 3 * 1024 * 1024);
}

test "decoder expansion is exactly one 24 kHz frame" {
    try std.testing.expectEqual(@as(usize, plan_module.SAMPLES_PER_FRAME), 2 * 2 * 8 * 5 * 4 * 3);
    try std.testing.expectEqual(@as(usize, 24_000), plan_module.SAMPLE_RATE);
}

// ═══════════════════════════════════════════════════════════════════════════
// GPU vocoder — device-resident mirror of decodeLatent (above).
//
// Every weight is dequantized to f32 in VRAM once (gpuPreload); every
// activation stays on the GPU across the whole stage chain, so a frame is
// decoded with one latent upload + one PCM download instead of re-reading conv
// weights from the file source for all 1,920 output samples. Full f32 (more
// faithful than the CPU Q4×Q8 path). Causal history / transpose carry are kept
// host-side (tiny) and shuttled per conv. If the custom-kernel pipeline is
// unavailable, gpuAvailable() is false and callers use the CPU decodeLatent.
// ═══════════════════════════════════════════════════════════════════════════

const LATENT = plan_module.LATENT;
const SAMPLES = plan_module.SAMPLES_PER_FRAME;
const GPU_HIST_MAX: usize = 54 * 1536; // max padding(54) × max channels(1536)

const GpuDevice = struct {
    a: kernels.CUdeviceptr = 0,
    b: kernels.CUdeviceptr = 0,
    c: kernels.CUdeviceptr = 0,
    wide: kernels.CUdeviceptr = 0,
    hist: kernels.CUdeviceptr = 0,
    ready: bool = false,
};
var gdev: GpuDevice = .{};

var g_hist_host: [GPU_HIST_MAX]f32 = @splat(0);
var g_pcm_host: [SAMPLES]f32 = @splat(0);
var g_frame_host: [1536]f32 = @splat(0);

// Per-decoder-stage prior input frame (transpose carry across calls).
const GCarry = struct { frame: *[1536]f32, count: *u8 };
var g_carry_frames: [plan_module.DECODER_STAGES][1536]f32 = @splat(@splat(0));
var g_carry_counts: [plan_module.DECODER_STAGES]u8 = @splat(0);

pub fn gpuAvailable() bool {
    return kernels.ready();
}

pub fn gpuInit() bool {
    if (gdev.ready) return true;
    if (!kernels.ready()) return false;
    gdev.a = kernels.alloc(MAX_VALUES);
    gdev.b = kernels.alloc(MAX_VALUES);
    gdev.c = kernels.alloc(MAX_VALUES);
    gdev.wide = kernels.alloc(4 * LATENT * 8);
    gdev.hist = kernels.alloc(GPU_HIST_MAX);
    if (gdev.a == 0 or gdev.b == 0 or gdev.c == 0 or gdev.wide == 0 or gdev.hist == 0) {
        gpuDeinit();
        return false;
    }
    gdev.ready = true;
    return true;
}

pub fn gpuDeinit() void {
    kernels.free(gdev.a);
    kernels.free(gdev.b);
    kernels.free(gdev.c);
    kernels.free(gdev.wide);
    kernels.free(gdev.hist);
    gdev = .{};
}

pub fn gpuResetCarry() void {
    g_carry_frames = @splat(@splat(0));
    g_carry_counts = @splat(0);
}

/// Preload every vocoder weight into VRAM (dequantized f32). Returns true if
/// all resident. Call once after the plan is built.
pub fn gpuPreload(comptime capacity: usize, source: sb0m.Source, index: *const sb0m.Index(capacity), plan: *const plan_module.Plan) bool {
    if (!gpuInit()) return false;
    var ok = true;
    for (plan.pre_upsample) |stage| {
        ok = ok and gpre(source, index, stage.transposed.weight);
        ok = ok and gpre(source, index, stage.transposed.bias);
        ok = ok and gpre(source, index, stage.conv_next.depthwise.weight);
        ok = ok and gpre(source, index, stage.conv_next.depthwise.bias);
        ok = ok and gpre(source, index, stage.conv_next.norm_weight);
        ok = ok and gpre(source, index, stage.conv_next.norm_bias);
        ok = ok and gpre(source, index, stage.conv_next.pointwise_1.weight);
        ok = ok and gpre(source, index, stage.conv_next.pointwise_1.bias);
        ok = ok and gpre(source, index, stage.conv_next.pointwise_2.weight);
        ok = ok and gpre(source, index, stage.conv_next.pointwise_2.bias);
        ok = ok and gpre(source, index, stage.conv_next.gamma);
    }
    ok = ok and gpre(source, index, plan.decoder_input.weight);
    ok = ok and gpre(source, index, plan.decoder_input.bias);
    for (plan.decoder_stages) |stage| {
        ok = ok and gpre(source, index, stage.activation.alpha);
        ok = ok and gpre(source, index, stage.activation.beta);
        ok = ok and gpre(source, index, stage.transposed.weight);
        ok = ok and gpre(source, index, stage.transposed.bias);
        for (stage.residual) |unit| {
            ok = ok and gpre(source, index, unit.act_1.alpha);
            ok = ok and gpre(source, index, unit.act_1.beta);
            ok = ok and gpre(source, index, unit.conv_1.weight);
            ok = ok and gpre(source, index, unit.conv_1.bias);
            ok = ok and gpre(source, index, unit.act_2.alpha);
            ok = ok and gpre(source, index, unit.act_2.beta);
            ok = ok and gpre(source, index, unit.conv_2.weight);
            ok = ok and gpre(source, index, unit.conv_2.bias);
        }
    }
    ok = ok and gpre(source, index, plan.output_activation.alpha);
    ok = ok and gpre(source, index, plan.output_activation.beta);
    ok = ok and gpre(source, index, plan.output_conv.weight);
    ok = ok and gpre(source, index, plan.output_conv.bias);
    return ok;
}

fn gpre(source: sb0m.Source, index: anytype, ref: plan_module.TensorRef) bool {
    if (!ref.present() or ref.index >= index.tensor_count) return false;
    return kernels.preloadWeight(source, &index.tensors[ref.index]);
}

fn gwp(index: anytype, ref: plan_module.TensorRef) kernels.CUdeviceptr {
    return kernels.weightPtr(index.tensors[ref.index].data_offset);
}

/// Decode one latent → PCM entirely on the GPU (f32-exact). `state` (host) is
/// the same State the CPU path uses; carries causal history between calls.
pub fn decodeLatentGpu(
    comptime capacity: usize,
    source: sb0m.Source,
    index: *const sb0m.Index(capacity),
    plan: *const plan_module.Plan,
    latent: *const [LATENT]f32,
    state: *State,
    pcm: *[SAMPLES]f32,
) Error!void {
    if (plan.bound_tensors != plan_module.BOUND_TENSORS) return error.InvalidPlan;
    if (!gdev.ready) return error.InvalidPlan;
    _ = source;

    if (!kernels.upload(gdev.a, latent[0..LATENT])) return error.NonFinite;
    var frames: usize = 1;
    var channels: usize = LATENT;

    for (plan.pre_upsample, 0..) |stage, si| {
        try gTransposed(index, stage.transposed, gdev.a, gdev.b, frames, channels, channels, 2, 2, null);
        frames *= 2;
        try gConvNext(index, stage.conv_next, gdev.b, gdev.a, frames,
            &state.pre_upsample_history[si], &state.pre_upsample_cursor[si], &state.pre_upsample_count[si]);
    }

    try gCausal(index, plan.decoder_input, gdev.a, gdev.b, frames, LATENT, 1536, 7, 1,
        &state.decoder_input_history, &state.decoder_input_cursor, &state.decoder_input_count);
    channels = 1536;
    if (!kernels.copyDevice(gdev.a, gdev.b, frames * channels)) return error.NonFinite;

    const out_channels = [_]usize{ 768, 384, 192, 96 };
    const strides = [_]usize{ 8, 5, 4, 3 };
    const kern = [_]usize{ 16, 10, 8, 6 };
    const dilations = [_]usize{ 1, 3, 9 };

    for (plan.decoder_stages, out_channels, strides, kern, 0..) |stage, next_ch, stride, kernel, si| {
        try gSnake(index, stage.activation, gdev.a, frames, channels);
        try gTransposed(index, stage.transposed, gdev.a, gdev.b, frames, channels, next_ch, kernel, stride,
            GCarry{ .frame = &g_carry_frames[si], .count = &g_carry_counts[si] });
        frames = frames * stride;
        channels = next_ch;
        for (stage.residual, dilations, 0..) |unit, dilation, ui| {
            if (!kernels.copyDevice(gdev.a, gdev.b, frames * channels)) return error.NonFinite;
            try gSnake(index, unit.act_1, gdev.a, frames, channels);
            try gCausal(index, unit.conv_1, gdev.a, gdev.c, frames, channels, channels, 7, dilation,
                gResidualHistory(state, si, ui, channels, 6 * dilation), &state.residual_cursor[si][ui], &state.residual_count[si][ui]);
            // conv_1 output is in c; snake(act_2) turns it into a (a = snake(c)).
            if (!kernels.copyDevice(gdev.a, gdev.c, frames * channels)) return error.NonFinite;
            try gSnake(index, unit.act_2, gdev.a, frames, channels);
            try gCausalNoHist(index, unit.conv_2, gdev.a, gdev.c, frames, channels, channels, 1, 1);
            if (!kernels.residualAdd(gdev.b, gdev.c, frames * channels)) return error.NonFinite;
        }
        if (!kernels.copyDevice(gdev.a, gdev.b, frames * channels)) return error.NonFinite;
    }
    if (frames != SAMPLES or channels != 96) return error.InvalidShape;

    try gSnake(index, plan.output_activation, gdev.a, frames, channels);
    try gCausal(index, plan.output_conv, gdev.a, gdev.b, frames, 96, 1, 7, 1,
        &state.output_history, &state.output_cursor, &state.output_count);

    if (!kernels.sync()) return error.NonFinite;
    if (!kernels.download(g_pcm_host[0..frames], gdev.b)) return error.NonFinite;
    for (pcm, g_pcm_host[0..frames]) |*d, s| {
        d.* = std.math.clamp(s, -1, 1);
        if (!std.math.isFinite(d.*)) return error.NonFinite;
    }
}

fn gSnake(index: anytype, s: plan_module.Snake, x: kernels.CUdeviceptr, frames: usize, channels: usize) Error!void {
    const alpha = gwp(index, s.alpha);
    const beta = gwp(index, s.beta);
    if (alpha == 0 or beta == 0) return error.InvalidPlan;
    if (!kernels.snakeBeta(x, alpha, beta, frames, channels)) return error.NonFinite;
}

fn gConvNext(index: anytype, block: plan_module.ConvNext, input: kernels.CUdeviceptr, output: kernels.CUdeviceptr,
    frames: usize, history: []f32, cursor: *u8, count: *u8) Error!void {
    const ch = LATENT;
    const dw_w = gwp(index, block.depthwise.weight);
    const dw_b = gwp(index, block.depthwise.bias);
    try gDepthwise7(dw_w, dw_b, input, output, frames, ch, history, cursor, count);
    const nw = gwp(index, block.norm_weight);
    const nb = gwp(index, block.norm_bias);
    if (nw == 0 or nb == 0) return error.InvalidPlan;
    if (!kernels.layerNorm(output, nw, nb, frames, ch)) return error.NonFinite;
    const p1w = gwp(index, block.pointwise_1.weight);
    const p1b = gwp(index, block.pointwise_1.bias);
    const p2w = gwp(index, block.pointwise_2.weight);
    const p2b = gwp(index, block.pointwise_2.bias);
    const gamma = gwp(index, block.gamma);
    if (p1w == 0 or p1b == 0 or p2w == 0 or p2b == 0 or gamma == 0) return error.InvalidPlan;
    if (!kernels.gemmDeviceBatched(p1w, output, gdev.wide, 4 * ch, ch, frames)) return error.NonFinite;
    if (!kernels.addBiasRows(gdev.wide, p1b, frames, 4 * ch)) return error.NonFinite;
    if (!kernels.gelu(gdev.wide, frames * 4 * ch)) return error.NonFinite;
    if (!kernels.gemmDeviceBatched(p2w, gdev.wide, gdev.c, ch, 4 * ch, frames)) return error.NonFinite;
    if (!kernels.addBiasRows(gdev.c, p2b, frames, ch)) return error.NonFinite;
    if (!kernels.copyDevice(output, input, frames * ch)) return error.NonFinite;
    if (!kernels.scaleAddRows(output, gdev.c, gamma, frames, ch)) return error.NonFinite;
}

fn gCausal(index: anytype, conv: plan_module.Conv, input: kernels.CUdeviceptr, output: kernels.CUdeviceptr,
    frames: usize, in_ch: usize, out_ch: usize, kernel: usize, dilation: usize,
    history: []f32, cursor: *u8, count: *u8) Error!void {
    const w = gwp(index, conv.weight);
    const b = gwp(index, conv.bias);
    if (w == 0 or b == 0) return error.InvalidPlan;
    const padding = (kernel - 1) * dilation;
    const hist_count: usize = count.*;
    gLinearizeRing(history, padding, in_ch, cursor.*, count.*);
    var hist_ptr: kernels.CUdeviceptr = 0;
    if (padding != 0 and hist_count != 0) {
        if (!kernels.upload(gdev.hist, g_hist_host[0 .. hist_count * in_ch])) return error.NonFinite;
        hist_ptr = gdev.hist;
    }
    if (!kernels.causalConv1d(input, w, b, output, hist_ptr, hist_count, frames, in_ch, out_ch, kernel, dilation))
        return error.NonFinite;
    if (padding != 0) try gRefreshRing(history, padding, in_ch, cursor, count, input, frames);
}

fn gCausalNoHist(index: anytype, conv: plan_module.Conv, input: kernels.CUdeviceptr, output: kernels.CUdeviceptr,
    frames: usize, in_ch: usize, out_ch: usize, kernel: usize, dilation: usize) Error!void {
    const w = gwp(index, conv.weight);
    const b = gwp(index, conv.bias);
    if (w == 0 or b == 0) return error.InvalidPlan;
    if (!kernels.causalConv1d(input, w, b, output, 0, 0, frames, in_ch, out_ch, kernel, dilation))
        return error.NonFinite;
}

fn gTransposed(index: anytype, conv: plan_module.Conv, input: kernels.CUdeviceptr, output: kernels.CUdeviceptr,
    frames: usize, in_ch: usize, out_ch: usize, kernel: usize, stride: usize, carry: ?GCarry) Error!void {
    const w = gwp(index, conv.weight);
    const b = gwp(index, conv.bias);
    if (w == 0 or b == 0) return error.InvalidPlan;
    var carry_ptr: kernels.CUdeviceptr = 0;
    var carry_in: usize = 0;
    if (carry) |cs| {
        if (cs.count.* != 0) {
            if (!kernels.upload(gdev.hist, cs.frame[0..in_ch])) return error.NonFinite;
            carry_ptr = gdev.hist;
            carry_in = 1;
        }
    }
    if (!kernels.transposedConv1d(input, w, b, output, carry_ptr, carry_in, frames, in_ch, out_ch, kernel, stride))
        return error.NonFinite;
    if (carry) |cs| {
        if (kernel > stride) {
            if (!kernels.sync()) return error.NonFinite;
            const last = frames - 1;
            if (!kernels.download(cs.frame[0..in_ch], input + @as(kernels.CUdeviceptr, last * in_ch) * @sizeOf(f32)))
                return error.NonFinite;
            cs.count.* = 1;
        }
    }
}

fn gDepthwise7(w: kernels.CUdeviceptr, b: kernels.CUdeviceptr, input: kernels.CUdeviceptr, output: kernels.CUdeviceptr,
    frames: usize, channels: usize, history: []f32, cursor: *u8, count: *u8) Error!void {
    const padding: usize = 6;
    const hist_count: usize = count.*;
    gLinearizeRing(history, padding, channels, cursor.*, count.*);
    var hist_ptr: kernels.CUdeviceptr = 0;
    if (hist_count != 0) {
        if (!kernels.upload(gdev.hist, g_hist_host[0 .. hist_count * channels])) return error.NonFinite;
        hist_ptr = gdev.hist;
    }
    if (!kernels.depthwiseConv1d(input, w, b, output, hist_ptr, hist_count, frames, channels, 7))
        return error.NonFinite;
    try gRefreshRing(history, padding, channels, cursor, count, input, frames);
}

fn gLinearizeRing(ring: []const f32, padding: usize, channels: usize, cursor: u8, count: u8) void {
    if (padding == 0 or count == 0) return;
    const cnt: usize = count;
    const oldest = (@as(usize, cursor) + padding - cnt) % padding;
    for (0..cnt) |j| {
        const slot = (oldest + j) % padding;
        @memcpy(g_hist_host[j * channels ..][0..channels], ring[slot * channels ..][0..channels]);
    }
}

fn gRefreshRing(ring: []f32, padding: usize, channels: usize, cursor: *u8, count: *u8, input: kernels.CUdeviceptr, frames: usize) Error!void {
    if (padding == 0) return;
    if (!kernels.sync()) return error.NonFinite;
    const keep = @min(padding, frames);
    if (keep < padding) {
        var f: usize = 0;
        while (f < frames) : (f += 1) {
            if (!kernels.download(g_frame_host[0..channels], input + @as(kernels.CUdeviceptr, f * channels) * @sizeOf(f32)))
                return error.NonFinite;
            const slot: usize = cursor.*;
            @memcpy(ring[slot * channels ..][0..channels], g_frame_host[0..channels]);
            cursor.* = @intCast((slot + 1) % padding);
            count.* = @intCast(@min(@as(usize, count.*) + 1, padding));
        }
        return;
    }
    for (0..padding) |j| {
        const src_frame = frames - padding + j;
        if (!kernels.download(ring[j * channels ..][0..channels], input + @as(kernels.CUdeviceptr, src_frame * channels) * @sizeOf(f32)))
            return error.NonFinite;
    }
    cursor.* = 0;
    count.* = @intCast(padding);
}

fn gResidualHistory(state: *State, stage: usize, unit: usize, channels: usize, padding: usize) []f32 {
    const channel_table = [_]usize{ 768, 384, 192, 96 };
    const padding_table = [_]usize{ 6, 18, 54 };
    var offset: usize = 0;
    for (0..stage) |ps| {
        for (padding_table) |pp| offset += channel_table[ps] * pp;
    }
    for (0..unit) |pu| offset += channels * padding_table[pu];
    return state.residual_history[offset..][0 .. channels * padding];
}
