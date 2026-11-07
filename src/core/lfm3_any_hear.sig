//! @zpm/lfm3-any-hear — LFM3-Audio's hearing encoder on any GPU, over a
//! gpu.Device with lfm3_kir's and lfm3_kir_hear's kernels: log-mel frames
//! to rows of the text model's input embeddings, streaming, as
//! lfm3_audio_encoder.encode (llama.cpp's clip_graph_lfm3a).
//!
//! The graph is the CPU's, op for op in its order: the three stride-2
//! convolutions (conv0, then dwpw twice), the linear map of the features,
//! the 17 LFM2 layers (normRows, Q8_0 matrices, the short convolution or
//! the sliding-window attention with per-head norms and RoPE, SwiGLU,
//! residuals), the final RMSNorm and LayerNorm, the projector's matrices
//! and GELU. lfm3_kir_hear's header says where its floats are the CPU's;
//! on a GPU that fuses the rows are the CPU's to the bit (tests/
//! test_lfm3_hear.sig), and on one that does not (the Adreno) the CPU's
//! fused steps go through Builder.fma's exact emulation, the CPU's bits too.
//!
//! `Encoder(CAPACITY)`: init(dev, &plan, &index, source, options, &work),
//! newStream() for a clip (its state on the GPU), encode(&stream, frames,
//! out) -> the rows (`plan.projection` values each) of lfm3_audio_encoder
//! .encode for the same frames after the same history; toCpu / fromCpu
//! hand a stream's state to the CPU encoder (its State) and back; reset
//! starts a new clip. The Work is lfm3_any's (a model that does not run
//! at the same time, galaxy-think's text model's, can share it).
//!
//! The stream's state stays on the GPU between calls, twice: the left
//! columns of the three convolutions, the short convolutions' taps, each
//! attention layer's last `window - 1` keys and values. A call reads one
//! copy and writes the other, so a call that fails (error.DeviceLost) leaves
//! the stream as it was, and the next call (or toCpu, then the CPU encoder)
//! goes on from there.
//!
//! A call of up to 64 frames (8 rows) is 308 dispatches with LFM3-Audio's
//! 10 conv and 7 attention layers (each of its 102 matrix launches takes 8
//! rows: one more a matrix per further 8), sent in runs of
//! Options.max_run (two of nvidia_device's 256).
//!
//! Memory as lfm3_any's: the mmproj file imported zero-copy on unified
//! memory when the device can, else copied once; scratch and the streams'
//! state in `.device`, the rows in `.host`, the frames and RoPE table
//! written each call in `.upload`. (VRAM without a CPU view: not yet, as
//! lfm3_any_audio.)

const std = @import("std");
const gguf = @import("gguf");
const gpu = @import("gpu");
const enc = @import("lfm3_audio_encoder");
const ops = @import("lfm3_audio_ops");
const kernels = @import("lfm3_kir");
const hear = @import("lfm3_kir_hear");
const any = @import("lfm3_any");

const kir = gpu.kir;
pub const Device = gpu.Device;
pub const Buffer = gpu.Buffer;
pub const Program = gpu.Program;
pub const DOWNSAMPLE = enc.DOWNSAMPLE;

pub const Error = any.Error || enc.Error;

pub const Options = struct {
    /// Output rows one encode call makes at most (8 mel frames each): the
    /// scratch and each stream's key/value rows are sized for it.
    positions: u32 = @intCast(enc.lfm3_audio_limits.positions),
    timeout_us: u64 = 10_000_000,
    import: bool = true,
    /// Dispatches one Device.run takes at most (a call sends more as
    /// several runs, each waited for: nvidia_device takes 256).
    max_run: u32 = 256,
};

const MATRIX_VARIANTS = kernels.MAX_TOKENS;
/// The LayerNorm's epsilon in the projector (llama.cpp's, ops.layerNorm's caller).
const LAYER_NORM_EPSILON: f32 = 1e-5;

const Programs = struct {
    q80: [MATRIX_VARIANTS]?Program = @splat(null),
    quant: ?Program = null,
    norm: ?Program = null,
    conv: ?Program = null,
    residual: ?Program = null,
    glu: ?Program = null,
    bias: ?Program = null,
    copy: ?Program = null,
    conv0: ?Program = null,
    dwpw: ?Program = null,
    head: ?Program = null,
    attend: ?Program = null,
    final: ?Program = null,
    gelu: ?Program = null,
};

const Matrix = struct { offset: u32, row_bytes: u32, rows: u32, blocks: u32, tensor: u16 };

/// Where a stream's state lives in each of its two buffers (bytes).
const Layout = struct {
    left0: u32 = 0,
    left1: u32 = 0,
    left2: u32 = 0,
    conv: u32 = 0,
    conv_bytes: u32 = 0,
    kv: u32 = 0,
    /// One attention layer's rows: the window's `prefix`, then a call's.
    kv_layer: u32 = 0,
    kv_row: u32 = 0,
    bytes: u32 = 0,
};

/// One clip's state on the GPU (Encoder.newStream): two copies, `parity`
/// the current one, and the clip's position (output rows so far).
pub const Stream = struct {
    state: [2]Buffer = .{ .{}, .{} },
    parity: u1 = 0,
    position: usize = 0,
};

pub fn Encoder(comptime tensor_capacity: usize) type {
    return struct {
        const Self = @This();

        dev: Device,
        caps: gpu.Caps,
        options: Options,
        plan: *const enc.Plan,
        index: *const gguf.Index(tensor_capacity),
        file: gguf.Source,
        work: *any.Work,
        weights: Buffer = .{},
        imported: bool = false,
        k: Programs = .{},
        layout: Layout = .{},
        mel: Buffer = .{},
        rope: Buffer = .{},
        stage0: Buffer = .{},
        stage1: Buffer = .{},
        features: Buffer = .{},
        hidden: Buffer = .{},
        normalized: Buffer = .{},
        mixed: Buffer = .{},
        query: Buffer = .{},
        mixer: Buffer = .{},
        projected: Buffer = .{},
        ffn_gate: Buffer = .{},
        ffn_up: Buffer = .{},
        wide: Buffer = .{},
        act_q: Buffer = .{},
        act_d: Buffer = .{},
        out_rows: Buffer = .{},
        /// (host) a stream's state on its way to or from the CPU
        staging: Buffer = .{},
        lost: u32 = 0,
        /// The last encode's dispatches and runs.
        dispatches: u32 = 0,
        runs: u32 = 0,
        last_ns: u64 = 0,
        compile_error: ?anyerror = null,

        pub fn init(dev: Device, plan: *const enc.Plan, index: *const gguf.Index(tensor_capacity), file: gguf.Source, options: Options, work: *any.Work) Error!Self {
            var self = Self{ .dev = dev, .caps = dev.caps, .options = options, .plan = plan, .index = index, .file = file, .work = work };
            errdefer self.deinit();
            try self.supported();
            try self.compileAll();
            try self.placeWeights();
            try self.allocBuffers();
            return self;
        }

        pub fn deinit(self: *Self) void {
            const bufs = [_]*Buffer{ &self.mel, &self.rope, &self.stage0, &self.stage1, &self.features, &self.hidden, &self.normalized, &self.mixed, &self.query, &self.mixer, &self.projected, &self.ffn_gate, &self.ffn_up, &self.wide, &self.act_q, &self.act_d, &self.out_rows, &self.staging };
            for (bufs) |b| {
                if (b.bytes != 0) self.dev.free(b.*);
                b.* = .{};
            }
            if (!self.imported and self.weights.bytes != 0) self.dev.free(self.weights);
            self.weights = .{};
            for (&self.k.q80) |*p| self.unload(p);
            const progs = [_]*?Program{ &self.k.quant, &self.k.norm, &self.k.conv, &self.k.residual, &self.k.glu, &self.k.bias, &self.k.copy, &self.k.conv0, &self.k.dwpw, &self.k.head, &self.k.attend, &self.k.final, &self.k.gelu };
            for (progs) |p| self.unload(p);
        }

        fn unload(self: *Self, p: *?Program) void {
            if (p.*) |*prog| self.dev.unload(prog);
            p.* = null;
        }

        fn prefix(self: *const Self) u32 {
            return @intCast(self.plan.window - 1);
        }

        fn supported(self: *const Self) Error!void {
            const p = self.plan;
            const c = p.channels;
            if (self.options.positions == 0 or self.options.positions > 256 or self.options.max_run == 0) return error.Unsupported;
            if (p.layer_count == 0 or p.mels % DOWNSAMPLE != 0 or c == 0 or c % 8 != 0 or c > self.caps.max_group) return error.Unsupported;
            if (p.hidden % kernels.QK8_0 != 0 or p.feed_forward % kernels.QK8_0 != 0 or p.projection % kernels.QK8_0 != 0 or p.features() % kernels.QK8_0 != 0) return error.Unsupported;
            if (p.hidden % kernels.rowThreads(self.caps) != 0) return error.Unsupported;
            if (p.attention_layer_count > 0) {
                if (p.head_size == 0 or p.head_size % 32 != 0 or p.heads * p.head_size != p.hidden) return error.Unsupported;
                if (!std.math.isPowerOfTwo(p.heads / p.kv_heads) or p.heads % p.kv_heads != 0) return error.Unsupported;
                if (p.window < 2 or p.window > hear.MAX_WINDOW) return error.Unsupported;
            }
            if (p.conv_layer_count > 0 and (p.kernel < kernels.MIN_TAPS or p.kernel > kernels.MAX_TAPS)) return error.Unsupported;
            for (self.index.tensors[0..self.index.tensor_count]) |*t| {
                if (t.file_offset % 16 != 0) return error.Unsupported;
            }
            if (self.file.size > std.math.maxInt(u32)) return error.Unsupported;
        }

        fn build(self: *Self, slot: *?Program, kernel: kernels.Error!kir.Kernel) Error!void {
            var k = kernel catch |e| {
                self.compile_error = e;
                return if (e == error.Unsupported) error.Unsupported else error.CompileFailed;
            };
            var cw = gpu.Work.init(&self.work.compile_mem);
            const bin = gpu.compile(&k, self.caps, &cw, &self.work.code) catch |e| {
                self.compile_error = e;
                return error.CompileFailed;
            };
            slot.* = try self.dev.load(&bin);
        }

        fn compileAll(self: *Self) Error!void {
            const caps = self.caps;
            const p = self.plan;
            const s = kir.Storage{ .insts = &self.work.insts, .tys = &self.work.tys };
            for (0..MATRIX_VARIANTS) |t| try self.build(&self.k.q80[t], kernels.matrix(s, caps, .q8_0, @intCast(t + 1)));
            try self.build(&self.k.quant, kernels.q80Quant(s, caps));
            try self.build(&self.k.norm, kernels.normRows(s, caps, false));
            try self.build(&self.k.residual, kernels.residual(s, caps, false));
            try self.build(&self.k.glu, kernels.gluGgml(s, caps));
            try self.build(&self.k.bias, kernels.addBias(s, caps));
            try self.build(&self.k.copy, kernels.copy(s, caps));
            if (p.conv_layer_count > 0) try self.build(&self.k.conv, kernels.conv(s, caps, @intCast(p.kernel)));
            try self.build(&self.k.conv0, hear.conv0(s, caps));
            try self.build(&self.k.dwpw, hear.dwpw(s, caps, @intCast(p.channels)));
            if (p.attention_layer_count > 0) {
                try self.build(&self.k.head, hear.headNormRope(s, caps, @intCast(p.head_size)));
                try self.build(&self.k.attend, hear.attendWindow(s, caps, @intCast(p.head_size)));
            }
            try self.build(&self.k.final, hear.rmsLayerNorm(s, caps));
            try self.build(&self.k.gelu, hear.gelu(s, caps));
        }

        fn placeWeights(self: *Self) Error!void {
            const size = self.file.size;
            if (self.options.import and self.caps.memory == .unified and self.caps.import) {
                if (self.file.view(0, @intCast(size), 16)) |bytes| {
                    if (self.dev.import(@constCast(bytes))) |b| {
                        self.weights = b;
                        self.imported = true;
                        return;
                    }
                }
            }
            self.weights = try self.dev.alloc(std.mem.alignForward(u64, size, 16), .device);
            if (self.weights.cpu.len < size) return error.Unsupported; // (VRAM without a view: as lfm3_any_audio, not yet here)
            var at: u64 = 0;
            while (at < size) {
                const n: usize = @intCast(@min(size - at, 4 << 20));
                if (!self.file.read(at, self.weights.cpu[@intCast(at)..][0..n])) return error.StorageNotMapped;
                at += n;
            }
            self.dev.toDevice(self.weights, 0, size);
        }

        fn allocBuffers(self: *Self) Error!void {
            const p = self.plan;
            const n: u64 = self.options.positions;
            const c: u64 = p.channels;
            const f: u64 = p.mels;
            const h: u64 = p.hidden;
            const ff: u64 = p.feed_forward;
            const hs: u64 = p.head_size;
            const features: u64 = p.features();
            const projection: u64 = p.projection;
            const widest: u64 = @max(@max(features, ff), @max(projection, h));
            const dv = self.dev;
            self.mel = try dv.alloc(@as(u64, DOWNSAMPLE) * n * f * 4, .upload);
            self.rope = try dv.alloc(@max(n * hs * 4, 16), .upload);
            self.stage0 = try dv.alloc(4 * n * (f / 2) * c * 4, .device);
            self.stage1 = try dv.alloc(2 * n * (f / 4) * c * 4, .device);
            self.features = try dv.alloc(n * features * 4, .device);
            self.hidden = try dv.alloc(n * h * 4, .device);
            self.normalized = try dv.alloc(n * h * 4, .device);
            self.mixed = try dv.alloc(n * 3 * h * 4, .device);
            self.query = try dv.alloc(n * h * 4, .device);
            self.mixer = try dv.alloc(n * h * 4, .device);
            self.projected = try dv.alloc(n * h * 4, .device);
            self.ffn_gate = try dv.alloc(n * ff * 4, .device);
            self.ffn_up = try dv.alloc(n * ff * 4, .device);
            self.wide = try dv.alloc(n * projection * 4, .device);
            self.act_q = try dv.alloc(n * widest, .device);
            self.act_d = try dv.alloc(n * widest / kernels.QK8_0 * 4, .device);
            self.out_rows = try dv.alloc(n * projection * 4, .host);
            // a stream's state: the left columns, the conv taps, the windows
            const history: u64 = if (p.kernel > 0) p.kernel - 1 else 0;
            const conv_layers: u64 = p.conv_layer_count;
            const attention_layers: u64 = p.attention_layer_count;
            const window: u64 = p.window;
            const kvw: u64 = p.kvWidth();
            var lay: Layout = .{};
            var at: u64 = 0;
            lay.left0 = @intCast(at);
            at += f * 4;
            lay.left1 = @intCast(at);
            at += f / 2 * c * 4;
            lay.left2 = @intCast(at);
            at += f / 4 * c * 4;
            lay.conv = @intCast(at);
            const conv_bytes = conv_layers * history * h * 4;
            at += conv_bytes;
            lay.kv = @intCast(at);
            const kv_row = 2 * kvw * 4;
            const kv_layer = (window - 1 + n) * kv_row;
            at += attention_layers * kv_layer;
            if (at > std.math.maxInt(u32)) return error.Unsupported;
            lay.conv_bytes = @intCast(conv_bytes);
            lay.kv_row = @intCast(kv_row);
            lay.kv_layer = @intCast(kv_layer);
            if (at > std.math.maxInt(u32) or at % 16 != 0 or lay.kv_row % 16 != 0) return error.Unsupported;
            lay.bytes = @intCast(@max(at, 16));
            self.layout = lay;
            self.staging = try dv.alloc(lay.bytes, .host);
        }

        fn offsetOf(self: *const Self, ref: ops.Ref) Error!u32 {
            if (ref == ops.NONE or ref >= self.index.tensor_count) return error.InvalidModel;
            return @intCast(self.index.tensors[ref].file_offset);
        }

        fn matrixOf(self: *const Self, ref: ops.Ref) Error!Matrix {
            if (ref == ops.NONE or ref >= self.index.tensor_count) return error.InvalidModel;
            const t = &self.index.tensors[ref];
            if (t.ggml_type != 8 or t.dimension_count < 2) return error.Unsupported;
            const columns: u32 = @intCast(t.dimensions[0]);
            var rows: u64 = 1;
            for (t.dimensions[1..t.dimension_count]) |extent| rows *= extent;
            const blocks = columns / kernels.QK8_0;
            return .{ .offset = @intCast(t.file_offset), .row_bytes = blocks * kernels.Q8_0_BLOCK, .rows = @intCast(rows), .blocks = blocks, .tensor = ref };
        }

        // ── Streams ─────────────────────────────────────────────────────────

        /// A new clip's state on the GPU (zero, position 0).
        pub fn newStream(self: *Self) Error!Stream {
            var s = Stream{};
            s.state[0] = try self.dev.alloc(self.layout.bytes, .device);
            errdefer self.dev.free(s.state[0]);
            s.state[1] = try self.dev.alloc(self.layout.bytes, .device);
            errdefer self.dev.free(s.state[1]);
            try self.reset(&s);
            return s;
        }

        pub fn freeStream(self: *Self, s: *Stream) void {
            for (&s.state) |*b| {
                if (b.bytes != 0) self.dev.free(b.*);
                b.* = .{};
            }
        }

        /// Start a new clip on the stream (its state zero, as State.reset).
        pub fn reset(self: *Self, s: *Stream) Error!void {
            @memset(self.staging.cpu[0..self.layout.bytes], 0);
            try self.fromStaging(s);
            s.position = 0;
        }

        /// The stream's state as the CPU encoder's State (its `limits` must
        /// hold the model): the CPU can go on with the clip from here.
        pub fn toCpu(self: *Self, s: *const Stream, comptime limits: enc.Limits, state: *enc.State(limits)) Error!void {
            try enc.checkLimits(limits, self.plan);
            var l = any.List{ .work = self.work };
            try self.copy(&l, s.state[s.parity], 0, self.staging, 0, self.layout.bytes);
            try self.run(&l);
            self.dev.fromDevice(self.staging, 0, self.layout.bytes);
            const p = self.plan;
            const lay = self.layout;
            const v = self.stagingFloats();
            const f = p.mels;
            const c = p.channels;
            state.reset();
            state.position = s.position;
            @memcpy(state.ds0[0..f], v[lay.left0 / 4 ..][0..f]);
            @memcpy(state.ds1[0 .. f / 2 * c], v[lay.left1 / 4 ..][0 .. f / 2 * c]);
            @memcpy(state.ds2[0 .. f / 4 * c], v[lay.left2 / 4 ..][0 .. f / 4 * c]);
            @memcpy(state.conv[0 .. lay.conv_bytes / 4], v[lay.conv / 4 ..][0 .. lay.conv_bytes / 4]);
            const kvw = p.kvWidth();
            for (0..p.attention_layer_count) |slot| {
                for (0..p.window - 1) |r| {
                    const row = v[(lay.kv + slot * lay.kv_layer + r * lay.kv_row) / 4 ..];
                    const at = slot * (limits.window - 1) * limits.kv_width + r * kvw;
                    @memcpy(state.keys[at..][0..kvw], row[0..kvw]);
                    @memcpy(state.values[at..][0..kvw], row[kvw..][0..kvw]);
                }
            }
        }

        /// The CPU encoder's State onto the stream (the GPU goes on with the
        /// clip from it).
        pub fn fromCpu(self: *Self, s: *Stream, comptime limits: enc.Limits, state: *const enc.State(limits)) Error!void {
            try enc.checkLimits(limits, self.plan);
            const p = self.plan;
            const lay = self.layout;
            const v = self.stagingFloats();
            const f = p.mels;
            const c = p.channels;
            @memset(self.staging.cpu[0..lay.bytes], 0);
            @memcpy(v[lay.left0 / 4 ..][0..f], state.ds0[0..f]);
            @memcpy(v[lay.left1 / 4 ..][0 .. f / 2 * c], state.ds1[0 .. f / 2 * c]);
            @memcpy(v[lay.left2 / 4 ..][0 .. f / 4 * c], state.ds2[0 .. f / 4 * c]);
            @memcpy(v[lay.conv / 4 ..][0 .. lay.conv_bytes / 4], state.conv[0 .. lay.conv_bytes / 4]);
            const kvw = p.kvWidth();
            for (0..p.attention_layer_count) |slot| {
                for (0..p.window - 1) |r| {
                    const row = v[(lay.kv + slot * lay.kv_layer + r * lay.kv_row) / 4 ..];
                    const at = slot * (limits.window - 1) * limits.kv_width + r * kvw;
                    @memcpy(row[0..kvw], state.keys[at..][0..kvw]);
                    @memcpy(row[kvw..][0..kvw], state.values[at..][0..kvw]);
                }
            }
            try self.fromStaging(s);
            s.position = state.position;
        }

        fn stagingFloats(self: *const Self) []f32 {
            return @alignCast(std.mem.bytesAsSlice(f32, self.staging.cpu[0..self.layout.bytes]));
        }

        /// The staging buffer as the stream's current state.
        fn fromStaging(self: *Self, s: *Stream) Error!void {
            self.dev.toDevice(self.staging, 0, self.layout.bytes);
            var l = any.List{ .work = self.work };
            try self.copy(&l, self.staging, 0, s.state[s.parity], 0, self.layout.bytes);
            try self.run(&l);
        }

        // ── Dispatches ──────────────────────────────────────────────────────

        fn copy(self: *Self, l: *any.List, from: Buffer, from_off: u32, to: Buffer, to_off: u32, bytes: u32) Error!void {
            if (bytes == 0) return;
            const words16 = bytes / 16;
            l.named("copy", null, 0, 0);
            try l.add(&self.k.copy.?, kernels.copyGroups(words16), &.{ from, to }, &.{ words16, from_off, to_off });
        }

        /// out[t] = W . x[t] for `n` tokens of Q8_0 activations (from act
        /// token 0), all the matrix's rows.
        fn linear(self: *Self, l: *any.List, m: Matrix, n: u32, out: Buffer, out_off: u32, out_stride: u32) Error!void {
            var first: u32 = 0;
            while (first < n) {
                const tokens = @min(n - first, MATRIX_VARIANTS);
                const mp = kernels.MatrixParams{
                    .row_bytes = m.row_bytes,
                    .blocks = m.blocks,
                    .rows = m.rows,
                    .out_stride = out_stride,
                    .weights = m.offset,
                    .act_q = first * m.blocks * kernels.QK8_0,
                    .act_d = first * m.blocks * 4,
                    .act_sums = 0,
                    .out = out_off + first * out_stride,
                };
                l.named("matrix q8_0", m.tensor, first, tokens);
                try l.add(&self.k.q80[tokens - 1].?, kernels.matrixGroups(self.caps, m.rows), &.{ self.weights, self.act_q, self.act_d, self.act_d, out }, &mp.words(.q8_0));
                first += tokens;
            }
        }

        fn quant(self: *Self, l: *any.List, x: Buffer, width: u32, n: u32) Error!void {
            l.named("q8_0 quant", null, 0, n);
            try l.add(&self.k.quant.?, kernels.q80Groups(width, n), &.{ x, self.act_q, self.act_d }, &.{ width, width / kernels.QK8_0, 0 });
        }

        /// Quantize then multiply (ops.project), + bias when the model has one.
        fn project(self: *Self, l: *any.List, x: Buffer, ref: ops.Ref, bias: ops.Ref, n: u32, out: Buffer, out_off: u32, out_stride: u32) Error!void {
            const m = try self.matrixOf(ref);
            try self.quant(l, x, m.blocks * kernels.QK8_0, n);
            try self.linear(l, m, n, out, out_off, out_stride);
            if (bias != ops.NONE) {
                l.named("bias", bias, 0, n);
                try l.add(&self.k.bias.?, .{ (m.rows + 63) / 64, n, 1 }, &.{ out, self.weights }, &.{ m.rows, try self.offsetOf(bias) });
            }
        }

        fn norm(self: *Self, l: *any.List, weight: ops.Ref, n: u32) Error!void {
            l.named("norm", weight, 0, n);
            try l.add(&self.k.norm.?, .{ 1, n, 1 }, &.{ self.hidden, self.weights, self.normalized }, &.{ @as(u32, @intCast(self.plan.hidden)), @as(u32, @bitCast(self.plan.epsilon)), 0, try self.offsetOf(weight), 0, 0, 0, 0 });
        }

        fn residual(self: *Self, l: *any.List, n: u32) Error!void {
            l.named("residual", null, 0, n);
            try l.add(&self.k.residual.?, .{ 1, n, 1 }, &.{ self.hidden, self.projected, self.weights }, &.{ @as(u32, @intCast(self.plan.hidden)), 0, 0 });
        }

        fn run(self: *Self, l: *const any.List) Error!void {
            self.dispatches = @intCast(l.n);
            self.runs = 0;
            var ns: u64 = 0;
            var at: usize = 0;
            while (at < l.n) {
                const part = l.slice()[at..@min(l.n, at + self.options.max_run)];
                const fence = self.dev.run(part) catch {
                    self.lost += 1;
                    return error.DeviceLost;
                };
                self.dev.wait(fence, self.options.timeout_us) catch |e| {
                    if (e != error.Timeout) {
                        self.lost += 1;
                        return error.DeviceLost;
                    }
                    self.dev.wait(fence, std.math.maxInt(u64)) catch {
                        self.lost += 1;
                        return error.DeviceLost;
                    };
                };
                ns += self.dev.lastRunNs();
                self.runs += 1;
                at += part.len;
            }
            self.last_ns = ns;
        }

        // ── Encoding ────────────────────────────────────────────────────────

        /// lfm3_audio_encoder.encode on the GPU: `frames` (frame-major,
        /// frames.len / plan.mels of them, at most 8 * options.positions)
        /// following what the stream has seen; one row of plan.projection
        /// values per output position into `out`; returns the row count. A
        /// chunk must hold a multiple of 8 frames but for a clip's last. On
        /// an error the stream is as it was.
        pub fn encode(self: *Self, s: *Stream, frames: []const f32, out: []f32) Error!usize {
            const p = self.plan;
            const f: u32 = @intCast(p.mels);
            if (frames.len == 0 or frames.len % f != 0) return error.InvalidInput;
            if (frames.len / f > DOWNSAMPLE * self.options.positions) return error.Capacity;
            const count: u32 = @intCast(frames.len / f);
            const t1 = (count + 1) / 2;
            const t2 = (t1 + 1) / 2;
            const n = (t2 + 1) / 2;
            const width: u32 = @intCast(p.projection);
            if (out.len < n * width) return error.Capacity;
            if (s.position > std.math.maxInt(u32) - n) return error.Capacity;
            const c: u32 = @intCast(p.channels);
            const h: u32 = @intCast(p.hidden);
            const ff: u32 = @intCast(p.feed_forward);
            const lay = self.layout;
            const cur = s.state[s.parity];
            const nxt = s.state[1 - s.parity];

            // the per-call inputs: the frames, the positions' RoPE table
            const mel: []f32 = @alignCast(std.mem.bytesAsSlice(f32, self.mel.cpu[0 .. frames.len * 4]));
            @memcpy(mel, frames);
            self.dev.toDevice(self.mel, 0, frames.len * 4);
            if (p.attention_layer_count > 0) {
                const rope: []f32 = @alignCast(std.mem.bytesAsSlice(f32, self.rope.cpu[0 .. n * p.head_size * 4]));
                kernels.ropeTable(rope, s.position, n, p.head_size, p.rope_base, null);
                self.dev.toDevice(self.rope, 0, n * p.head_size * 4);
            }

            var l = any.List{ .work = self.work };
            // Stage 0: the full 3x3 conv of the frames, the left column the
            // stream's; the last frame the next call's left column.
            l.named("conv0", p.conv0_w, 0, count);
            try l.add(&self.k.conv0.?, hear.conv0Groups(c, f, t1), &.{ self.mel, cur, self.weights, self.stage0 }, &hear.conv0Params(f, count, try self.offsetOf(p.conv0_w), try self.offsetOf(p.conv0_b), c, 0, lay.left0, 0));
            try self.copy(&l, self.mel, (count - 1) * f * 4, nxt, lay.left0, f * 4);
            // Stages 1 and 2: depthwise + pointwise, SiLU; stage 2 writes the
            // features ([t][c][bin], ggml's frequency-fastest flattening).
            const b1 = f / 2;
            const b2 = f / 4;
            const b3 = f / 8;
            l.named("depthwise + pointwise 1", p.pw1_w, 0, t2);
            try l.add(&self.k.dwpw.?, hear.dwpwGroups(b1, t1), &.{ self.stage0, cur, self.weights, self.stage1 }, &(hear.DwpwParams{
                .bins = b1,
                .columns = t1,
                .c = c,
                .dw = try self.offsetOf(p.dw1_w),
                .dw_bias = try self.offsetOf(p.dw1_b),
                .pw = try self.offsetOf(p.pw1_w),
                .pw_bias = try self.offsetOf(p.pw1_b),
                .left = lay.left1,
                .out_column = b2 * c * 4,
                .out_bin = c * 4,
                .out_channel = 4,
            }).words());
            try self.copy(&l, self.stage0, (t1 - 1) * b1 * c * 4, nxt, lay.left1, b1 * c * 4);
            l.named("depthwise + pointwise 2", p.pw2_w, 0, n);
            try l.add(&self.k.dwpw.?, hear.dwpwGroups(b2, t2), &.{ self.stage1, cur, self.weights, self.features }, &(hear.DwpwParams{
                .bins = b2,
                .columns = t2,
                .c = c,
                .dw = try self.offsetOf(p.dw2_w),
                .dw_bias = try self.offsetOf(p.dw2_b),
                .pw = try self.offsetOf(p.pw2_w),
                .pw_bias = try self.offsetOf(p.pw2_b),
                .left = lay.left2,
                .out_column = b3 * c * 4,
                .out_bin = 4,
                .out_channel = b3 * 4,
            }).words());
            try self.copy(&l, self.stage1, (t2 - 1) * b2 * c * 4, nxt, lay.left2, b2 * c * 4);
            // the conv layers' taps: the next copy, updated in place below
            try self.copy(&l, cur, lay.conv, nxt, lay.conv, lay.conv_bytes);
            // the linear map of the features
            try self.project(&l, self.features, p.pre_out_w, p.pre_out_b, n, self.hidden, 0, h * 4);

            for (p.layers[0..p.layer_count], 0..) |*ly, li| {
                l.what.layer = @intCast(li);
                try self.norm(&l, ly.ln1, n);
                if (ly.attention) {
                    try self.attention(&l, ly, s, cur, nxt, n);
                } else {
                    try self.convBlock(&l, ly, nxt, n);
                }
                try self.residual(&l, n);
                try self.norm(&l, ly.ln2, n);
                const mg = try self.matrixOf(ly.ffn_gate);
                const mu = try self.matrixOf(ly.ffn_up);
                try self.quant(&l, self.normalized, h, n);
                try self.linear(&l, mg, n, self.ffn_gate, 0, ff * 4);
                try self.linear(&l, mu, n, self.ffn_up, 0, ff * 4);
                l.named("glu", null, 0, n);
                try l.add(&self.k.glu.?, .{ (n * ff + 63) / 64, 1, 1 }, &.{ self.ffn_gate, self.ffn_up }, &.{n * ff});
                try self.project(&l, self.ffn_gate, ly.ffn_down, ops.NONE, n, self.projected, 0, h * 4);
                try self.residual(&l, n);
            }
            l.what = .{};

            // the final RMSNorm, the projector's LayerNorm, Linear, GELU, Linear
            l.named("final norms", p.post_norm, 0, n);
            try l.add(&self.k.final.?, .{ 1, n, 1 }, &.{ self.hidden, self.weights, self.hidden }, &hear.finalParams(h, p.epsilon, LAYER_NORM_EPSILON, try self.offsetOf(p.post_norm), try self.offsetOf(p.mm0_w), try self.offsetOf(p.mm0_b), 0, 0));
            try self.project(&l, self.hidden, p.mm1_w, p.mm1_b, n, self.wide, 0, width * 4);
            l.named("gelu", null, 0, n);
            try l.add(&self.k.gelu.?, hear.geluGroups(n * width), &.{self.wide}, &.{ n * width, 0 });
            try self.project(&l, self.wide, p.mm3_w, p.mm3_b, n, self.out_rows, 0, width * 4);

            try self.run(&l);
            self.dev.fromDevice(self.out_rows, 0, n * width * 4);
            const rows: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, self.out_rows.cpu[0 .. n * width * 4]));
            if (!ops.allFinite(rows)) return error.NonFinite;
            @memcpy(out[0 .. n * width], rows);
            s.parity = 1 - s.parity;
            s.position += n;
            return n;
        }

        fn convBlock(self: *Self, l: *any.List, ly: *const enc.Layer, nxt: Buffer, n: u32) Error!void {
            const p = self.plan;
            const h: u32 = @intCast(p.hidden);
            const history: u32 = @intCast(p.kernel - 1);
            try self.project(l, self.normalized, ly.conv_in, ops.NONE, n, self.mixed, 0, 3 * h * 4);
            l.named("conv", ly.conv_dw, 0, n);
            const state_off = self.layout.conv + @as(u32, ly.slot) * history * h * 4;
            try l.add(&self.k.conv.?, kernels.convGroups(h), &.{ self.mixed, self.weights, nxt, self.mixer }, &.{ h, n, try self.offsetOf(ly.conv_dw), state_off });
            try self.project(l, self.mixer, ly.conv_out, ops.NONE, n, self.projected, 0, h * 4);
        }

        fn attention(self: *Self, l: *any.List, ly: *const enc.Layer, s: *const Stream, cur: Buffer, nxt: Buffer, n: u32) Error!void {
            const p = self.plan;
            const h: u32 = @intCast(p.hidden);
            const lay = self.layout;
            const pre = self.prefix();
            const kvw: u32 = @intCast(p.kvWidth());
            const heads: u32 = @intCast(p.heads);
            const kv_heads: u32 = @intCast(p.kv_heads);
            const kv_off = lay.kv + @as(u32, ly.slot) * lay.kv_layer;
            const new_rows = kv_off + pre * lay.kv_row;
            try self.quant(l, self.normalized, h, n);
            try self.linear(l, try self.matrixOf(ly.q), n, self.query, 0, h * 4);
            try self.linear(l, try self.matrixOf(ly.k), n, cur, new_rows, lay.kv_row);
            try self.linear(l, try self.matrixOf(ly.v), n, cur, new_rows + kvw * 4, lay.kv_row);
            const eps = p.epsilon;
            l.named("head norm + rope", ly.q_norm, 0, n);
            try l.add(&self.k.head.?, .{ heads, n, 1 }, &.{ self.query, self.weights, self.rope }, &hear.headParams(heads, eps, 0, try self.offsetOf(ly.q_norm), h * 4));
            l.named("head norm + rope", ly.k_norm, 0, n);
            try l.add(&self.k.head.?, .{ kv_heads, n, 1 }, &.{ cur, self.weights, self.rope }, &hear.headParams(kv_heads, eps, new_rows, try self.offsetOf(ly.k_norm), lay.kv_row));
            const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(p.head_size)));
            l.named("attention", null, 0, n);
            try l.add(&self.k.attend.?, .{ heads, n, 1 }, &.{ self.query, cur, self.mixer }, &(hear.AttendParams{
                .heads = heads,
                .group_log2 = std.math.log2_int(u32, heads / kv_heads),
                .base = @intCast(s.position),
                .prefix = pre,
                .scale = scale,
                .row_bytes = lay.kv_row,
                .values = kvw * 4,
                .kv = kv_off,
            }).words());
            // the last `prefix` rows of [window | chunk]: the next call's window
            try self.copy(l, cur, kv_off + n * lay.kv_row, nxt, kv_off, pre * lay.kv_row);
            try self.project(l, self.mixer, ly.o, ops.NONE, n, self.projected, 0, h * 4);
        }
    };
}
