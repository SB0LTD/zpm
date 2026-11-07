//! @zpm/lfm3-any-codec — LFM3-Audio's speech codec on any GPU, over a
//! gpu.Device with lfm3_kir's and lfm3_kir_codec's kernels: the codec
//! decoder of lfm3_audio_gen (decode) from a frame's twelve codes to its
//! polar spectrum (FSQ decode, the in-projection, 6x upsampling, the LFM
//! layers with their short convolutions and windowed gated attention, the
//! output norm and projection), so galaxy-think's speaking runs it on the
//! GPU. The polar spectrum then goes into the CPU's own ISTFT (exp, cos,
//! sin and lfm3_audio_gen.Istft, cheap): the same spectrum, the same PCM.
//!
//! The CPU's graph is ggml's (lfm3_audio_ops), and the kernels repeat its
//! operations in its order (lfm3_kir_codec's header): on a GPU that fuses
//! (Caps.fused_fma) the polar spectrum is the CPU's to the bit, and where
//! it does not each fused step is Builder.fma's exact emulation, the CPU's
//! bits too.
//!
//! `Codec(CAPACITY)`: init(dev, &plan, &index, source, options, &work);
//! decode(limits, &state, codes, pcm) and finish(limits, &state, pcm) as
//! lfm3_audio_gen's decode and finish, with the same CodecState: its
//! position and its ISTFT are the CPU's, its windows (the short
//! convolutions' and the attention layers' carried keys and values) the
//! GPU's between calls. `save` hands them to the CPU (then
//! lfm3_audio_gen.decode goes on from the state); a decode after the CPU's
//! (or after a reset) takes them from the state again. A call that fails
//! leaves the GPU's windows as they were (each call works on a copy), so
//! `save` then the CPU's decode of the same codes goes on exactly. The
//! Work is lfm3_any's (a backend that does not run at the same time can
//! share it).
//!
//! Memory as lfm3_any_audio's: the mmproj file imported zero-copy on
//! unified memory when the device can, else copied once; scratch and the
//! windows in `.device`, the polar spectrum in `.host`, each call's codes
//! and RoPE table in `.upload` (and windows going to or from a `.device`
//! buffer without a CPU view through an `.upload` or `.host` one and the
//! copy kernel).

const std = @import("std");
const gguf = @import("gguf");
const gpu = @import("gpu");
const gen = @import("lfm3_audio_gen");
const ops = @import("lfm3_audio_ops");
const kernels = @import("lfm3_kir");
const ck = @import("lfm3_kir_codec");
const any = @import("lfm3_any");

const kir = gpu.kir;
pub const Device = gpu.Device;
pub const Buffer = gpu.Buffer;
pub const Program = gpu.Program;
pub const CODEBOOKS = gen.CODEBOOKS;
pub const BINS = gen.BINS;
pub const FRAME_STACK = gen.FRAME_STACK;
const STACK: u32 = FRAME_STACK;

pub const Error = any.Error || gen.Error;

pub const Options = struct {
    timeout_us: u64 = 10_000_000,
    import: bool = true,
    /// Frames one decode call takes at most (the scratch's size).
    max_frames: u32 = gen.lfm3_audio_limits.frames,
    /// Dispatches one Device.run takes at most (a call sends more as
    /// several runs, each waited for: nvidia_device takes 256).
    max_run: u32 = 256,
};

/// lfm3_audio_gen's CODEC_WINDOW - 1: the keys an attention layer carries.
pub const PREFIX = 29;
/// lfm3_audio_gen's RoPE base (its ROPE_BASE).
const ROPE_BASE: f32 = 1_000_000;
const MATRIX_VARIANTS = kernels.MAX_TOKENS;

comptime {
    if (ck.CODEBOOKS != CODEBOOKS) @compileError("lfm3_kir_codec's codebooks are not lfm3_audio_gen's");
}

const Programs = struct {
    q80: [MATRIX_VARIANTS]?Program = @splat(null),
    quant: ?Program = null,
    norm: ?Program = null,
    head: ?Program = null,
    attend: ?Program = null,
    attend_gated: ?Program = null,
    glu: ?Program = null,
    bias: ?Program = null,
    residual: ?Program = null,
    conv: ?Program = null,
    copy: ?Program = null,
    fsq: ?Program = null,
    upsample: ?Program = null,
};

const Matrix = struct { offset: u32, row_bytes: u32, rows: u32, blocks: u32, tensor: u16 };

pub fn Codec(comptime tensor_capacity: usize) type {
    return struct {
        const Self = @This();

        dev: Device,
        caps: gpu.Caps,
        options: Options,
        plan: *const gen.Plan,
        index: *const gguf.Index(tensor_capacity),
        file: gguf.Source,
        work: *any.Work,
        weights: Buffer = .{},
        imported: bool = false,
        k: Programs = .{},
        /// (upload) the call's codes, i32 [frames][12]
        codes_in: Buffer = .{},
        fsq_out: Buffer = .{},
        frames: Buffer = .{},
        hidden: Buffer = .{},
        normalized: Buffer = .{},
        mixed: Buffer = .{},
        mixer: Buffer = .{},
        projected: Buffer = .{},
        query: Buffer = .{},
        keys: Buffer = .{},
        values: Buffer = .{},
        gate: Buffer = .{},
        ffn_gate: Buffer = .{},
        ffn_up: Buffer = .{},
        act_q: Buffer = .{},
        act_d: Buffer = .{},
        /// (upload) the call's RoPE table
        rope: Buffer = .{},
        /// (host) the call's polar spectrum, f32 [positions][2 * BINS]
        polar_out: Buffer = .{},
        /// The windows, twice: `cur` holds the stream's, a call works on
        /// the other and makes it the stream's when it succeeds. Each:
        /// [conv (conv layers x (kernel - 1) x hidden) | keys (attention
        /// layers x PREFIX x kv width) | values (as keys)], f32, the CPU's
        /// CodecState layout.
        windows: [2]Buffer = .{ .{}, .{} },
        cur: u1 = 0,
        /// (upload, host) the windows on their way in and out, when the
        /// windows have no CPU view
        staging: Buffer = .{},
        readback: Buffer = .{},
        /// The stream position the GPU's windows are at (null: none, they
        /// come from the state at the next decode).
        at: ?usize = null,
        /// The positions of the last call (its polar rows).
        positions: usize = 0,
        lost: u32 = 0,
        dispatches: u32 = 0,
        compile_error: ?anyerror = null,

        pub fn init(dev: Device, plan: *const gen.Plan, index: *const gguf.Index(tensor_capacity), file: gguf.Source, options: Options, work: *any.Work) Error!Self {
            var self = Self{ .dev = dev, .caps = dev.caps, .options = options, .plan = plan, .index = index, .file = file, .work = work };
            errdefer self.deinit();
            try self.supported();
            try self.compileAll();
            try self.placeWeights();
            try self.allocBuffers();
            return self;
        }

        pub fn deinit(self: *Self) void {
            const bufs = [_]*Buffer{ &self.codes_in, &self.fsq_out, &self.frames, &self.hidden, &self.normalized, &self.mixed, &self.mixer, &self.projected, &self.query, &self.keys, &self.values, &self.gate, &self.ffn_gate, &self.ffn_up, &self.act_q, &self.act_d, &self.rope, &self.polar_out, &self.windows[0], &self.windows[1], &self.staging, &self.readback };
            for (bufs) |b| {
                if (b.bytes != 0) self.dev.free(b.*);
                b.* = .{};
            }
            if (!self.imported and self.weights.bytes != 0) self.dev.free(self.weights);
            self.weights = .{};
            for (&self.k.q80) |*p| self.unload(p);
            const progs = [_]*?Program{ &self.k.quant, &self.k.norm, &self.k.head, &self.k.attend, &self.k.attend_gated, &self.k.glu, &self.k.bias, &self.k.residual, &self.k.conv, &self.k.copy, &self.k.fsq, &self.k.upsample };
            for (progs) |p| self.unload(p);
        }

        fn unload(self: *Self, p: *?Program) void {
            if (p.*) |*prog| self.dev.unload(prog);
            p.* = null;
        }

        /// The most positions one call has (max_frames frames).
        fn maxPositions(self: *const Self) u32 {
            return self.options.max_frames * STACK;
        }

        fn fsqWidth(self: *const Self) u32 {
            return @intCast(ops.dimension(self.index, self.plan.fsq_out_w, 1));
        }

        fn supported(self: *const Self) Error!void {
            const plan = self.plan;
            const cs = &plan.codec;
            const hs = cs.head_size;
            if (cs.layer_count == 0 or self.options.max_frames == 0) return error.Unsupported;
            if (cs.hidden % kernels.QK8_0 != 0 or cs.feed_forward % kernels.QK8_0 != 0 or self.fsqWidth() % kernels.QK8_0 != 0) return error.Unsupported;
            // (the residual kernel's rows in whole passes of its threads)
            if (cs.hidden % kernels.rowThreads(self.caps) != 0) return error.Unsupported;
            if (plan.levels == 0 or plan.levels * CODEBOOKS > 64) return error.Unsupported;
            if (cs.conv_layer_count > 0 and (cs.kernel < kernels.MIN_TAPS or cs.kernel > kernels.MAX_TAPS)) return error.Unsupported;
            if (cs.attention_layer_count > 0) {
                if (hs < 32 or hs > 128 or hs % 32 != 0 or !std.math.isPowerOfTwo(hs)) return error.Unsupported;
                if (cs.heads == 0 or cs.kv_heads == 0 or !std.math.isPowerOfTwo(cs.heads / cs.kv_heads)) return error.Unsupported;
                if (cs.heads * hs != cs.hidden) return error.Unsupported;
                if (PREFIX + self.maxPositions() > ck.MAX_ROW) return error.Unsupported;
            }
            // (the copy kernel's 16-byte words: rows of 4 floats)
            if (cs.hidden % 4 != 0 or cs.kvWidth() % 4 != 0) return error.Unsupported;
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
            const cs = &self.plan.codec;
            const s = kir.Storage{ .insts = &self.work.insts, .tys = &self.work.tys };
            for (0..MATRIX_VARIANTS) |t| try self.build(&self.k.q80[t], kernels.matrix(s, caps, .q8_0, @intCast(t + 1)));
            try self.build(&self.k.quant, kernels.q80Quant(s, caps));
            try self.build(&self.k.norm, kernels.normRows(s, caps, false));
            try self.build(&self.k.glu, kernels.gluGgml(s, caps));
            try self.build(&self.k.bias, kernels.addBias(s, caps));
            try self.build(&self.k.residual, kernels.residual(s, caps, false));
            try self.build(&self.k.copy, kernels.copy(s, caps));
            try self.build(&self.k.fsq, ck.fsq(s, caps));
            try self.build(&self.k.upsample, ck.upsample(s, caps));
            if (cs.conv_layer_count > 0) try self.build(&self.k.conv, kernels.conv(s, caps, @intCast(cs.kernel)));
            if (cs.attention_layer_count > 0) {
                const hs: u32 = @intCast(cs.head_size);
                try self.build(&self.k.head, kernels.headNormRope(s, caps, hs));
                try self.build(&self.k.attend, ck.attendWindow(s, caps, hs, false));
                try self.build(&self.k.attend_gated, ck.attendWindow(s, caps, hs, true));
            }
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

        /// The windows' sections (bytes): conv, keys, values.
        fn convBytes(self: *const Self) u64 {
            const cs = &self.plan.codec;
            const history = if (cs.conv_layer_count > 0) cs.kernel - 1 else 0;
            return @as(u64, cs.conv_layer_count) * history * cs.hidden * 4;
        }

        fn kvBytes(self: *const Self) u64 {
            const cs = &self.plan.codec;
            return @as(u64, cs.attention_layer_count) * PREFIX * cs.kvWidth() * 4;
        }

        fn windowBytes(self: *const Self) u64 {
            return self.convBytes() + 2 * self.kvBytes();
        }

        fn allocBuffers(self: *Self) Error!void {
            const cs = &self.plan.codec;
            const frames: u64 = self.options.max_frames;
            const p: u64 = self.maxPositions();
            const c: u64 = cs.hidden;
            const ff: u64 = cs.feed_forward;
            const kvw: u64 = cs.kvWidth();
            const fw: u64 = self.fsqWidth();
            const widest = @max(@max(c, ff), fw);
            const dv = self.dev;
            self.codes_in = try dv.alloc(frames * CODEBOOKS * 4, .upload);
            self.fsq_out = try dv.alloc(frames * fw * 4, .device);
            self.frames = try dv.alloc(frames * c * 4, .device);
            self.hidden = try dv.alloc(p * c * 4, .device);
            self.normalized = try dv.alloc(p * c * 4, .device);
            self.mixed = try dv.alloc(p * 3 * c * 4, .device);
            self.mixer = try dv.alloc(p * c * 4, .device);
            self.projected = try dv.alloc(p * c * 4, .device);
            self.query = try dv.alloc(p * c * 4, .device);
            self.keys = try dv.alloc(@max((PREFIX + p) * kvw * 4, 16), .device);
            self.values = try dv.alloc(@max((PREFIX + p) * kvw * 4, 16), .device);
            self.gate = try dv.alloc(@max(p * cs.heads * 4, 16), .device);
            self.ffn_gate = try dv.alloc(p * ff * 4, .device);
            self.ffn_up = try dv.alloc(p * ff * 4, .device);
            self.act_q = try dv.alloc(p * widest, .device);
            self.act_d = try dv.alloc(p * widest / kernels.QK8_0 * 4, .device);
            self.rope = try dv.alloc(@max(p * cs.head_size * 4, 16), .upload);
            self.polar_out = try dv.alloc(p * 2 * BINS * 4, .host);
            const wb = @max(self.windowBytes(), 16);
            self.windows[0] = try dv.alloc(wb, .device);
            self.windows[1] = try dv.alloc(wb, .device);
            if (self.windows[0].cpu.len < wb or self.windows[1].cpu.len < wb) {
                self.staging = try dv.alloc(wb, .upload);
                self.readback = try dv.alloc(wb, .host);
            }
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

        /// out[t] = W . x[t] for `n` tokens of Q8_0 activations, from out
        /// byte `out_off`, rows `out_stride` bytes apart.
        fn linear(self: *Self, l: *any.List, m: Matrix, n: u32, out: Buffer, out_off: u32, out_stride: u32) Error!void {
            var first: u32 = 0;
            while (first < n) {
                const tokens = @min(n - first, MATRIX_VARIANTS);
                const p = kernels.MatrixParams{
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
                try l.add(&self.k.q80[tokens - 1].?, kernels.matrixGroups(self.caps, m.rows), &.{ self.weights, self.act_q, self.act_d, self.act_d, out }, &p.words(.q8_0));
                first += tokens;
            }
        }

        fn quant(self: *Self, l: *any.List, x: Buffer, width: u32, n: u32) Error!void {
            l.named("q8_0 quant", null, 0, n);
            try l.add(&self.k.quant.?, kernels.q80Groups(width, n), &.{ x, self.act_q, self.act_d }, &.{ width, width / kernels.QK8_0, 0 });
        }

        fn norm(self: *Self, l: *any.List, x: Buffer, weight: ops.Ref, n: u32, out: Buffer) Error!void {
            l.named("norm", weight, 0, n);
            try l.add(&self.k.norm.?, .{ 1, n, 1 }, &.{ x, self.weights, out }, &.{ @as(u32, @intCast(self.plan.codec.hidden)), @as(u32, @bitCast(self.plan.codec.epsilon)), 0, try self.offsetOf(weight), 0, 0, 0, 0 });
        }

        fn residual(self: *Self, l: *any.List, n: u32) Error!void {
            l.named("residual", null, 0, n);
            try l.add(&self.k.residual.?, .{ 1, n, 1 }, &.{ self.hidden, self.projected, self.weights }, &.{ @as(u32, @intCast(self.plan.codec.hidden)), 0, 0 });
        }

        /// `bytes` (a multiple of 16) from `from` at byte `from_off` to `to` at `to_off`.
        fn copyBytes(self: *Self, l: *any.List, from: Buffer, from_off: u64, to: Buffer, to_off: u64, bytes: u64) Error!void {
            if (bytes == 0) return;
            const words16: u32 = @intCast(bytes / 16);
            l.named("copy", null, 0, 0);
            try l.add(&self.k.copy.?, kernels.copyGroups(words16), &.{ from, to }, &.{ words16, @as(u32, @intCast(from_off)), @as(u32, @intCast(to_off)) });
        }

        fn run(self: *Self, l: *const any.List) Error!void {
            self.dispatches = @intCast(l.n);
            const all = l.slice();
            const most: usize = @max(self.options.max_run, 1);
            var at: usize = 0;
            while (at < all.len) {
                const n = @min(all.len - at, most);
                const fence = self.dev.run(all[at..][0..n]) catch {
                    self.lost += 1;
                    return error.DeviceLost;
                };
                self.dev.wait(fence, std.math.maxInt(u64)) catch {
                    self.lost += 1;
                    return error.DeviceLost;
                };
                at += n;
            }
        }

        /// lfm3_audio_gen.decode on the GPU up to the polar spectrum, then
        /// the CPU's ISTFT: `codes` (frame-major, CODEBOOKS a frame, no end
        /// code) after what `state` has decoded; appends the PCM samples to
        /// `pcm` and returns their count. The state's position and ISTFT
        /// are updated as the CPU's decode does; its windows are the GPU's
        /// (`save` hands them back).
        pub fn decode(self: *Self, comptime limits: gen.Limits, state: *gen.CodecState(limits), codes: []const i32, pcm: []f32) Error!usize {
            const plan = self.plan;
            try gen.checkLimits(limits, plan);
            if (codes.len == 0 or codes.len % CODEBOOKS != 0) return error.InvalidInput;
            const count = codes.len / CODEBOOKS;
            if (count > limits.frames or count > self.options.max_frames) return error.Capacity;
            const positions = count * FRAME_STACK;
            if (pcm.len < positions * gen.HOP) return error.Capacity;
            for (codes) |code| if (code < 0 or code >= plan.vocabulary - 1) return error.InvalidInput;
            try self.polarOnGpu(limits, state, codes);
            state.position += positions;
            self.at = state.position;

            var written: usize = 0;
            var spectrum: [2 * BINS]f32 = undefined;
            const rows = self.polar();
            for (0..positions) |p| {
                const row = rows[p * 2 * BINS ..][0 .. 2 * BINS];
                for (0..BINS) |j| {
                    const magnitude = @exp(row[j]);
                    spectrum[2 * j] = magnitude * @cos(row[BINS + j]);
                    spectrum[2 * j + 1] = magnitude * @sin(row[BINS + j]);
                }
                written += state.istft.frame(&spectrum, pcm[written..]);
            }
            return written;
        }

        /// lfm3_audio_gen.finish: the samples the ISTFT still holds, and the
        /// state reset (the GPU's windows with it) for a new utterance.
        pub fn finish(self: *Self, comptime limits: gen.Limits, state: *gen.CodecState(limits), pcm: []f32) Error!usize {
            const count = try gen.finish(limits, state, pcm);
            self.at = null;
            return count;
        }

        /// A new utterance: the state reset, and the GPU's windows with it.
        pub fn reset(self: *Self, comptime limits: gen.Limits, state: *gen.CodecState(limits)) void {
            state.reset();
            self.at = null;
        }

        /// The last decode's polar spectrum: [positions][2 * BINS], the
        /// log-magnitudes then the phases of each position (the CPU's
        /// CodecWorkspace.polar).
        pub fn polar(self: *const Self) []const f32 {
            const v: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, self.polar_out.cpu));
            return v[0 .. self.positions * 2 * BINS];
        }

        /// The GPU's windows into `state` (its conv, keys and values, in
        /// lfm3_audio_gen's layout), so the CPU's decode goes on from it.
        /// The GPU keeps them too: a decode at the same position goes on
        /// on the GPU.
        pub fn save(self: *Self, comptime limits: gen.Limits, state: *gen.CodecState(limits)) Error!void {
            try gen.checkLimits(limits, self.plan);
            const at = self.at orelse return; // (none: the state's are the stream's)
            if (at != state.position) return error.InvalidInput;
            const bytes = self.windowBytes();
            const w = self.windows[self.cur];
            var from = w;
            if (w.cpu.len < bytes) {
                var l = any.List{ .work = self.work };
                try self.copyBytes(&l, w, 0, self.readback, 0, bytes);
                try self.run(&l);
                from = self.readback;
            }
            self.dev.fromDevice(from, 0, bytes);
            const all: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, from.cpu[0..@intCast(bytes)]));
            const conv_n: usize = @intCast(self.convBytes() / 4);
            const kv_n: usize = @intCast(self.kvBytes() / 4);
            @memcpy(state.conv[0..conv_n], all[0..conv_n]);
            @memcpy(state.keys[0..kv_n], all[conv_n..][0..kv_n]);
            @memcpy(state.values[0..kv_n], all[conv_n + kv_n ..][0..kv_n]);
        }

        /// The state's windows onto the GPU (the current ones).
        fn loadWindows(self: *Self, comptime limits: gen.Limits, state: *const gen.CodecState(limits)) Error!void {
            const bytes = self.windowBytes();
            const w = self.windows[self.cur];
            const into = if (w.cpu.len >= bytes) w else self.staging;
            const all: []f32 = @alignCast(std.mem.bytesAsSlice(f32, into.cpu[0..@intCast(bytes)]));
            const conv_n: usize = @intCast(self.convBytes() / 4);
            const kv_n: usize = @intCast(self.kvBytes() / 4);
            @memcpy(all[0..conv_n], state.conv[0..conv_n]);
            @memcpy(all[conv_n..][0..kv_n], state.keys[0..kv_n]);
            @memcpy(all[conv_n + kv_n ..][0..kv_n], state.values[0..kv_n]);
            self.dev.toDevice(into, 0, bytes);
            if (into.gpu != w.gpu) {
                var l = any.List{ .work = self.work };
                try self.copyBytes(&l, self.staging, 0, w, 0, bytes);
                try self.run(&l);
            }
            self.at = state.position;
        }

        /// The GPU's part of a decode: the call's polar spectrum into
        /// polar_out, the windows moved on (into the other buffer, made the
        /// stream's when the call succeeds).
        fn polarOnGpu(self: *Self, comptime limits: gen.Limits, state: *gen.CodecState(limits), codes: []const i32) Error!void {
            const plan = self.plan;
            const cs = &plan.codec;
            if (self.at == null or self.at.? != state.position) try self.loadWindows(limits, state);
            const count: u32 = @intCast(codes.len / CODEBOOKS);
            const n: u32 = count * STACK;
            const c: u32 = @intCast(cs.hidden);
            const fw = self.fsqWidth();
            const next: u1 = self.cur ^ 1;
            const win = self.windows[next];
            // the call's inputs: its codes and its RoPE table
            const dst: []i32 = @alignCast(std.mem.bytesAsSlice(i32, self.codes_in.cpu[0 .. codes.len * 4]));
            @memcpy(dst, codes);
            self.dev.toDevice(self.codes_in, 0, codes.len * 4);
            if (cs.attention_layer_count > 0) {
                const rope_n = @as(usize, n) * cs.head_size;
                kernels.ropeTable(@alignCast(std.mem.bytesAsSlice(f32, self.rope.cpu[0 .. rope_n * 4])), state.position, n, cs.head_size, ROPE_BASE, null);
                self.dev.toDevice(self.rope, 0, rope_n * 4);
            }

            var l = any.List{ .work = self.work };
            try self.copyBytes(&l, self.windows[self.cur], 0, win, 0, self.windowBytes());
            l.named("fsq", plan.fsq_out_w, 0, count);
            try l.add(&self.k.fsq.?, ck.fsqGroups(fw, count), &.{ self.codes_in, self.weights, self.fsq_out }, &.{ @as(u32, @intCast(plan.levels)), fw, try self.offsetOf(plan.fsq_codebook), try self.offsetOf(plan.fsq_out_w), try self.offsetOf(plan.fsq_out_b) });
            try self.quant(&l, self.fsq_out, fw, count);
            try self.linear(&l, try self.matrixOf(plan.codec_in_w), count, self.frames, 0, c * 4);
            l.named("bias + upsample", plan.codec_in_b, 0, n);
            try l.add(&self.k.upsample.?, ck.upsampleGroups(c, STACK, count), &.{ self.frames, self.weights, self.hidden }, &.{ c, STACK, try self.offsetOf(plan.codec_in_b) });
            for (plan.codec_layers[0..cs.layer_count], 0..) |*ly, li| {
                l.what.layer = @intCast(li);
                try self.layer(&l, ly, n, state.position, win);
            }
            l.what = .{};
            try self.norm(&l, self.hidden, plan.codec_norm, n, self.normalized);
            try self.quant(&l, self.normalized, c, n);
            const out = try self.matrixOf(plan.codec_out_w);
            try self.linear(&l, out, n, self.polar_out, 0, out.rows * 4);
            l.named("bias", plan.codec_out_b, 0, n);
            try l.add(&self.k.bias.?, .{ (out.rows + 63) / 64, n, 1 }, &.{ self.polar_out, self.weights }, &.{ out.rows, try self.offsetOf(plan.codec_out_b) });
            try self.run(&l);
            self.dev.fromDevice(self.polar_out, 0, @as(u64, n) * 2 * BINS * 4);
            self.positions = n;
            self.cur = next;
        }

        /// One LFM layer of the codec (lfm3_audio_gen.lfmLayer with its
        /// window), on `n` positions from stream position `base`; the
        /// layer's windows in `win`.
        fn layer(self: *Self, l: *any.List, ly: *const gen.Layer, n: u32, base: usize, win: Buffer) Error!void {
            const cs = &self.plan.codec;
            const c: u32 = @intCast(cs.hidden);
            const ff: u32 = @intCast(cs.feed_forward);
            try self.norm(l, self.hidden, ly.ln1, n, self.normalized);
            try self.quant(l, self.normalized, c, n);
            if (ly.attention) {
                try self.attention(l, ly, n, base, win);
            } else {
                const m_in = try self.matrixOf(ly.conv_in);
                try self.linear(l, m_in, n, self.mixed, 0, 3 * c * 4);
                const history: u32 = @intCast(cs.kernel - 1);
                l.named("conv", ly.conv_dw, 0, n);
                try l.add(&self.k.conv.?, kernels.convGroups(c), &.{ self.mixed, self.weights, win, self.mixer }, &.{ c, n, try self.offsetOf(ly.conv_dw), @as(u32, ly.slot) * history * c * 4 });
                try self.quant(l, self.mixer, c, n);
                try self.linear(l, try self.matrixOf(ly.conv_out), n, self.projected, 0, c * 4);
            }
            if (ly.attn_post_norm != ops.NONE) try self.norm(l, self.projected, ly.attn_post_norm, n, self.projected);
            try self.residual(l, n);
            try self.norm(l, self.hidden, ly.ln2, n, self.normalized);
            try self.quant(l, self.normalized, c, n);
            try self.linear(l, try self.matrixOf(ly.ffn_gate), n, self.ffn_gate, 0, ff * 4);
            try self.linear(l, try self.matrixOf(ly.ffn_up), n, self.ffn_up, 0, ff * 4);
            l.named("glu", null, 0, n);
            try l.add(&self.k.glu.?, .{ (n * ff + 63) / 64, 1, 1 }, &.{ self.ffn_gate, self.ffn_up }, &.{n * ff});
            try self.quant(l, self.ffn_gate, ff, n);
            try self.linear(l, try self.matrixOf(ly.ffn_down), n, self.projected, 0, c * 4);
            if (ly.ffn_post_norm != ops.NONE) try self.norm(l, self.projected, ly.ffn_post_norm, n, self.projected);
            try self.residual(l, n);
        }

        /// lfm3_audio_gen.attention with its window: the carried keys and
        /// values in front of the call's, per-head norms and RoPE, the
        /// windowed attention, the window moved on, the output projection.
        fn attention(self: *Self, l: *any.List, ly: *const gen.Layer, n: u32, base: usize, win: Buffer) Error!void {
            const cs = &self.plan.codec;
            const c: u32 = @intCast(cs.hidden);
            const heads: u32 = @intCast(cs.heads);
            const kv_heads: u32 = @intCast(cs.kv_heads);
            const hs: u32 = @intCast(cs.head_size);
            const qw = heads * hs;
            const kvw = kv_heads * hs;
            const eps: u32 = @bitCast(cs.epsilon);
            const window_bytes: u64 = @as(u64, PREFIX) * kvw * 4;
            const keys_at = self.convBytes() + @as(u64, ly.slot) * window_bytes;
            const values_at = self.convBytes() + self.kvBytes() + @as(u64, ly.slot) * window_bytes;
            // the window in front of the call's keys and values
            try self.copyBytes(l, win, keys_at, self.keys, 0, window_bytes);
            try self.copyBytes(l, win, values_at, self.values, 0, window_bytes);
            try self.linear(l, try self.matrixOf(ly.q), n, self.query, 0, qw * 4);
            try self.linear(l, try self.matrixOf(ly.k), n, self.keys, PREFIX * kvw * 4, kvw * 4);
            try self.linear(l, try self.matrixOf(ly.v), n, self.values, PREFIX * kvw * 4, kvw * 4);
            const gated = ly.gate != ops.NONE;
            if (gated) try self.linear(l, try self.matrixOf(ly.gate), n, self.gate, 0, heads * 4);
            l.named("head norm + rope", ly.q_norm, 0, n);
            try l.add(&self.k.head.?, .{ heads, n, 1 }, &.{ self.query, self.weights, self.rope }, &.{ heads, eps, 0, try self.offsetOf(ly.q_norm) });
            l.named("head norm + rope", ly.k_norm, 0, n);
            try l.add(&self.k.head.?, .{ kv_heads, n, 1 }, &.{ self.keys, self.weights, self.rope }, &.{ kv_heads, eps, PREFIX * kvw * 4, try self.offsetOf(ly.k_norm) });
            const p = ck.WindowParams{
                .heads = heads,
                .group_log2 = std.math.log2_int(u32, heads / kv_heads),
                .tokens = n,
                .prefix = PREFIX,
                .earliest = if (base < PREFIX) @intCast(PREFIX - base) else 0,
                .scale = 1.0 / @sqrt(@as(f32, @floatFromInt(hs))),
            };
            l.named("attention", null, 0, n);
            try l.add(if (gated) &self.k.attend_gated.? else &self.k.attend.?, ck.windowGroups(heads, n), &.{ self.query, self.keys, self.values, self.gate, self.mixer }, &p.words());
            // the window moved on: the row's last PREFIX keys and values
            try self.copyBytes(l, self.keys, @as(u64, n) * kvw * 4, win, keys_at, window_bytes);
            try self.copyBytes(l, self.values, @as(u64, n) * kvw * 4, win, values_at, window_bytes);
            try self.quant(l, self.mixer, qw, n);
            try self.linear(l, try self.matrixOf(ly.o), n, self.projected, 0, c * 4);
        }
    };
}
