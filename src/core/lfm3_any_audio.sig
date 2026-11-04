//! @zpm/lfm3-any-audio — LFM3-Audio's networks on any GPU, over a
//! gpu.Device with lfm3_kir's kernels: the depthformer that turns the text
//! model's hidden state into speech codes (lfm3_audio_gen's projectState
//! and codePass), so galaxy-think's Speaker can run its three MaskGIT
//! passes a frame on the GPU.
//!
//! The CPU's graph is ggml's (lfm3_audio_ops): Q8_0 matrices with a fused
//! epilogue, RMSNorm over f32-rounded squares summed in f64, ggml_v_expf
//! and ggml_vec_dot_f32 built of fused multiply-adds. The kernels repeat
//! those operations in that order, so on a GPU that fuses (Caps.fused_fma)
//! the logits are the CPU's to the bit; on one that does not (the Adreno)
//! each fused step rounds twice (a float path, within about 1e-6).
//!
//! `Depth(CAPACITY)`: init(dev, &plan, &index, source, options, &work),
//! projectState(hidden_state), codePass(&codes) -> the CODEBOOKS *
//! vocabulary logits, codebook-major, as lfm3_audio_gen's
//! DepthWorkspace.logits. The Work is lfm3_any's (a backend that does not
//! run at the same time, galaxy-think's text model's, can share it).
//!
//! Memory as lfm3_any's: the mmproj file imported zero-copy on unified
//! memory when the device can, else copied once; scratch in `.device`, the
//! logits in `.host`, the hidden state written each frame in `.upload`.
//!
//! Open: the hearing encoder (lfm3_audio_encoder) and the codec before its
//! ISTFT are still the CPU's.

const std = @import("std");
const gguf = @import("gguf");
const gpu = @import("gpu");
const gen = @import("lfm3_audio_gen");
const ops = @import("lfm3_audio_ops");
const kernels = @import("lfm3_kir");
const any = @import("lfm3_any");

const kir = gpu.kir;
pub const Device = gpu.Device;
pub const Buffer = gpu.Buffer;
pub const Program = gpu.Program;
pub const CODEBOOKS = gen.CODEBOOKS;

pub const Error = any.Error || gen.Error;

pub const Options = struct {
    timeout_us: u64 = 10_000_000,
    import: bool = true,
};

/// lfm3_audio_gen's RoPE base (its ROPE_BASE).
const ROPE_BASE: f32 = 1_000_000;
const HEAD = 32;
const MATRIX_VARIANTS = kernels.MAX_TOKENS;

const Programs = struct {
    q80: [MATRIX_VARIANTS]?Program = @splat(null),
    quant: ?Program = null,
    norm: ?Program = null,
    norm2: ?Program = null,
    head: ?Program = null,
    attend: ?Program = null,
    attend_gated: ?Program = null,
    glu: ?Program = null,
    input: ?Program = null,
    bias: ?Program = null,
    residual: ?Program = null,
};

const Matrix = struct { offset: u32, row_bytes: u32, rows: u32, blocks: u32, tensor: u16 };

pub fn Depth(comptime tensor_capacity: usize) type {
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
        state: Buffer = .{},
        hidden: Buffer = .{},
        normalized: Buffer = .{},
        query: Buffer = .{},
        keys: Buffer = .{},
        values: Buffer = .{},
        gate: Buffer = .{},
        mixer: Buffer = .{},
        projected: Buffer = .{},
        ffn_gate: Buffer = .{},
        ffn_up: Buffer = .{},
        act_q: Buffer = .{},
        act_d: Buffer = .{},
        rope: Buffer = .{},
        backbone_in: Buffer = .{},
        out_logits: Buffer = .{},
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
            const bufs = [_]*Buffer{ &self.state, &self.hidden, &self.normalized, &self.query, &self.keys, &self.values, &self.gate, &self.mixer, &self.projected, &self.ffn_gate, &self.ffn_up, &self.act_q, &self.act_d, &self.rope, &self.backbone_in, &self.out_logits };
            for (bufs) |b| {
                if (b.bytes != 0) self.dev.free(b.*);
                b.* = .{};
            }
            if (!self.imported and self.weights.bytes != 0) self.dev.free(self.weights);
            self.weights = .{};
            for (&self.k.q80) |*p| self.unload(p);
            const progs = [_]*?Program{ &self.k.quant, &self.k.norm, &self.k.norm2, &self.k.head, &self.k.attend, &self.k.attend_gated, &self.k.glu, &self.k.input, &self.k.bias, &self.k.residual };
            for (progs) |p| self.unload(p);
        }

        fn unload(self: *Self, p: *?Program) void {
            if (p.*) |*prog| self.dev.unload(prog);
            p.* = null;
        }

        fn supported(self: *const Self) Error!void {
            const d = &self.plan.depth;
            if (d.head_size != HEAD or d.heads == 0 or d.kv_heads == 0 or !std.math.isPowerOfTwo(d.heads / d.kv_heads)) return error.Unsupported;
            if (d.hidden % kernels.QK8_0 != 0 or d.feed_forward % kernels.QK8_0 != 0 or self.plan.backbone % kernels.QK8_0 != 0) return error.Unsupported;
            if (d.conv_layer_count != 0 or d.layer_count == 0) return error.Unsupported;
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
            const s = kir.Storage{ .insts = &self.work.insts, .tys = &self.work.tys };
            for (0..MATRIX_VARIANTS) |t| try self.build(&self.k.q80[t], kernels.matrix(s, caps, .q8_0, @intCast(t + 1)));
            try self.build(&self.k.quant, kernels.q80Quant(s, caps));
            try self.build(&self.k.norm, kernels.normRows(s, caps, false));
            try self.build(&self.k.norm2, kernels.normRows(s, caps, true));
            try self.build(&self.k.head, kernels.headNormRope(s, caps, HEAD));
            try self.build(&self.k.attend, kernels.attendGgml(s, caps, false));
            try self.build(&self.k.attend_gated, kernels.attendGgml(s, caps, true));
            try self.build(&self.k.glu, kernels.gluGgml(s, caps));
            try self.build(&self.k.input, kernels.depthInput(s, caps));
            try self.build(&self.k.bias, kernels.addBias(s, caps));
            try self.build(&self.k.residual, kernels.residual(s, caps, false));
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
            if (self.weights.cpu.len < size) return error.Unsupported; // (VRAM without a view: as lfm3_any, not yet here)
            var at: u64 = 0;
            while (at < size) {
                const n: usize = @intCast(@min(size - at, 4 << 20));
                if (!self.file.read(at, self.weights.cpu[@intCast(at)..][0..n])) return error.StorageNotMapped;
                at += n;
            }
            self.dev.toDevice(self.weights, 0, size);
        }

        fn allocBuffers(self: *Self) Error!void {
            const d = &self.plan.depth;
            const n: u64 = CODEBOOKS;
            const h: u64 = d.hidden;
            const q: u64 = d.heads * d.head_size;
            const kvw: u64 = d.kv_heads * d.head_size;
            const ff: u64 = d.feed_forward;
            const widest = @max(@max(h, ff), @max(q, self.plan.backbone));
            const dv = self.dev;
            self.state = try dv.alloc(n * h * 4, .device);
            self.hidden = try dv.alloc(n * h * 4, .device);
            self.normalized = try dv.alloc(n * h * 4, .device);
            self.query = try dv.alloc(n * q * 4, .device);
            self.keys = try dv.alloc(n * kvw * 4, .device);
            self.values = try dv.alloc(n * kvw * 4, .device);
            self.gate = try dv.alloc(n * d.heads * 4, .device);
            self.mixer = try dv.alloc(n * q * 4, .device);
            self.projected = try dv.alloc(n * h * 4, .device);
            self.ffn_gate = try dv.alloc(n * ff * 4, .device);
            self.ffn_up = try dv.alloc(n * ff * 4, .device);
            self.act_q = try dv.alloc(n * widest, .device);
            self.act_d = try dv.alloc(n * widest / kernels.QK8_0 * 4, .device);
            self.rope = try dv.alloc(n * HEAD / 2 * 2 * 4, .upload);
            self.backbone_in = try dv.alloc(@as(u64, self.plan.backbone) * 4, .upload);
            self.out_logits = try dv.alloc(n * self.plan.vocabulary * 4, .host);
            // the positions are 0..11 every pass: the table once
            kernels.ropeTable(@alignCast(std.mem.bytesAsSlice(f32, self.rope.cpu)), 0, CODEBOOKS, HEAD, ROPE_BASE, null);
            self.dev.toDevice(self.rope, 0, self.rope.bytes);
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

        /// out[t] = W . x[t] for `n` tokens of Q8_0 activations (from act
        /// token `first_act`), `rows` rows from `row0` (the logits' slice of
        /// the tied table).
        fn linear(self: *Self, l: *any.List, m: Matrix, n: u32, out: Buffer, out_off: u32, out_stride: u32, row0: u32, rows: u32, first_act: u32) Error!void {
            var first: u32 = 0;
            while (first < n) {
                const tokens = @min(n - first, MATRIX_VARIANTS);
                const p = kernels.MatrixParams{
                    .row_bytes = m.row_bytes,
                    .blocks = m.blocks,
                    .rows = rows,
                    .out_stride = out_stride,
                    .weights = m.offset + row0 * m.row_bytes,
                    .act_q = (first_act + first) * m.blocks * kernels.QK8_0,
                    .act_d = (first_act + first) * m.blocks * 4,
                    .act_sums = 0,
                    .out = out_off + first * out_stride,
                };
                l.named("matrix q8_0", m.tensor, first, tokens);
                try l.add(&self.k.q80[tokens - 1].?, kernels.matrixGroups(self.caps, rows), &.{ self.weights, self.act_q, self.act_d, self.act_d, out }, &p.words(.q8_0));
                first += tokens;
            }
        }

        fn quant(self: *Self, l: *any.List, x: Buffer, width: u32, n: u32) Error!void {
            l.named("q8_0 quant", null, 0, n);
            try l.add(&self.k.quant.?, kernels.q80Groups(width, n), &.{ x, self.act_q, self.act_d }, &.{ width, width / kernels.QK8_0, 0 });
        }

        fn norm(self: *Self, l: *any.List, x: Buffer, weight: ops.Ref, n: u32, out: Buffer) Error!void {
            l.named("norm", weight, 0, n);
            try l.add(&self.k.norm.?, .{ 1, n, 1 }, &.{ x, self.weights, out }, &.{ @as(u32, @intCast(self.plan.depth.hidden)), @as(u32, @bitCast(self.plan.depth.epsilon)), 0, try self.offsetOf(weight), 0, 0, 0, 0 });
        }

        fn run(self: *Self, l: *const any.List) Error!void {
            self.dispatches = @intCast(l.n);
            const fence = self.dev.run(l.slice()) catch {
                self.lost += 1;
                return error.DeviceLost;
            };
            self.dev.wait(fence, std.math.maxInt(u64)) catch {
                self.lost += 1;
                return error.DeviceLost;
            };
        }

        /// lfm3_audio_gen.projectState: proj_in(hidden_state) + its bias, the
        /// twelve starting rows of a frame's passes.
        pub fn projectState(self: *Self, hidden_state: []const f32) Error!void {
            const plan = self.plan;
            if (hidden_state.len != plan.backbone) return error.InvalidInput;
            const dst: []f32 = @alignCast(std.mem.bytesAsSlice(f32, self.backbone_in.cpu[0 .. plan.backbone * 4]));
            @memcpy(dst, hidden_state);
            self.dev.toDevice(self.backbone_in, 0, plan.backbone * 4);
            var l = any.List{ .work = self.work };
            const bb: u32 = @intCast(plan.backbone);
            try self.quant(&l, self.backbone_in, bb, 1);
            const m = try self.matrixOf(plan.proj_in_w);
            const width: u32 = @intCast(CODEBOOKS * plan.depth.hidden);
            try self.linear(&l, m, 1, self.state, 0, width * 4, 0, m.rows, 0);
            l.named("bias", plan.proj_in_b, 0, 1);
            try l.add(&self.k.bias.?, .{ (width + 63) / 64, 1, 1 }, &.{ self.state, self.weights }, &.{ width, try self.offsetOf(plan.proj_in_b) });
            try self.run(&l);
        }

        /// lfm3_audio_gen.codePass: one MaskGIT pass over the twelve
        /// codebooks (codes[i] revealed, or -1 masked); the logits,
        /// codebook-major.
        pub fn codePass(self: *Self, codes: *const [CODEBOOKS]i32) Error![]const f32 {
            const plan = self.plan;
            const dp = &plan.depth;
            const d: u32 = @intCast(dp.hidden);
            const n: u32 = CODEBOOKS;
            for (codes) |c| if (c >= @as(i32, @intCast(plan.vocabulary))) return error.InvalidInput;
            var l = any.List{ .work = self.work };
            const table = try self.matrixOf(plan.code_embd);
            var words: [5 + CODEBOOKS]u32 = undefined;
            words[0] = d;
            words[1] = table.offset;
            words[2] = table.row_bytes;
            words[3] = @intCast(plan.vocabulary);
            words[4] = try self.offsetOf(plan.mask_embd);
            for (codes, 0..) |c, i| words[5 + i] = @bitCast(c);
            l.named("input", plan.code_embd, 0, n);
            try l.add(&self.k.input.?, .{ (d + 63) / 64, n, 1 }, &.{ self.state, self.weights, self.hidden }, &words);
            for (plan.depth_layers[0..dp.layer_count], 0..) |*ly, li| {
                l.what.layer = @intCast(li);
                try self.layer(&l, ly);
            }
            l.what = .{};
            // the output norm, then each codebook's head norm, in place
            l.named("norm twice", plan.head_norm, 0, n);
            try l.add(&self.k.norm2.?, .{ 1, n, 1 }, &.{ self.hidden, self.weights, self.hidden }, &.{ d, @as(u32, @bitCast(dp.epsilon)), 0, try self.offsetOf(plan.output_norm), 0, 0, try self.offsetOf(plan.head_norm), d * 4 });
            try self.quant(&l, self.hidden, d, n);
            // each codebook against its slice of the tied table
            const vocab: u32 = @intCast(plan.vocabulary);
            for (0..CODEBOOKS) |book| {
                const b32: u32 = @intCast(book);
                try self.linear(&l, table, 1, self.out_logits, b32 * vocab * 4, vocab * 4, b32 * vocab, vocab, b32);
            }
            try self.run(&l);
            self.dev.fromDevice(self.out_logits, 0, self.out_logits.bytes);
            return self.logits();
        }

        pub fn logits(self: *const Self) []const f32 {
            const v: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, self.out_logits.cpu));
            return v[0 .. CODEBOOKS * self.plan.vocabulary];
        }

        fn layer(self: *Self, l: *any.List, ly: *const gen.Layer) Error!void {
            const dp = &self.plan.depth;
            const d: u32 = @intCast(dp.hidden);
            const n: u32 = CODEBOOKS;
            const heads: u32 = @intCast(dp.heads);
            const kv_heads: u32 = @intCast(dp.kv_heads);
            const qw = heads * HEAD;
            const kvw = kv_heads * HEAD;
            const ff: u32 = @intCast(dp.feed_forward);
            const eps: u32 = @bitCast(dp.epsilon);
            try self.norm(l, self.hidden, ly.ln1, n, self.normalized);
            try self.quant(l, self.normalized, d, n);
            const mq = try self.matrixOf(ly.q);
            const mk = try self.matrixOf(ly.k);
            const mv = try self.matrixOf(ly.v);
            try self.linear(l, mq, n, self.query, 0, qw * 4, 0, mq.rows, 0);
            try self.linear(l, mk, n, self.keys, 0, kvw * 4, 0, mk.rows, 0);
            try self.linear(l, mv, n, self.values, 0, kvw * 4, 0, mv.rows, 0);
            const gated = ly.gate != ops.NONE;
            if (gated) {
                const mg = try self.matrixOf(ly.gate);
                try self.linear(l, mg, n, self.gate, 0, heads * 4, 0, mg.rows, 0);
            }
            l.named("head norm + rope", ly.q_norm, 0, n);
            try l.add(&self.k.head.?, .{ heads, n, 1 }, &.{ self.query, self.weights, self.rope }, &.{ heads, eps, 0, try self.offsetOf(ly.q_norm) });
            l.named("head norm + rope", ly.k_norm, 0, n);
            try l.add(&self.k.head.?, .{ kv_heads, n, 1 }, &.{ self.keys, self.weights, self.rope }, &.{ kv_heads, eps, 0, try self.offsetOf(ly.k_norm) });
            const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(HEAD)));
            l.named("attention", null, 0, n);
            try l.add(if (gated) &self.k.attend_gated.? else &self.k.attend.?, .{ heads, n, 1 }, &.{ self.query, self.keys, self.values, self.gate, self.mixer }, &.{ heads, std.math.log2_int(u32, heads / kv_heads), n, @as(u32, @bitCast(scale)) });
            try self.quant(l, self.mixer, qw, n);
            const mo = try self.matrixOf(ly.o);
            try self.linear(l, mo, n, self.projected, 0, d * 4, 0, mo.rows, 0);
            if (ly.attn_post_norm != ops.NONE) try self.norm(l, self.projected, ly.attn_post_norm, n, self.projected);
            l.named("residual", null, 0, n);
            try l.add(&self.k.residual.?, .{ 1, n, 1 }, &.{ self.hidden, self.projected, self.weights }, &.{ d, 0, 0 });
            try self.norm(l, self.hidden, ly.ln2, n, self.normalized);
            try self.quant(l, self.normalized, d, n);
            const mgate = try self.matrixOf(ly.ffn_gate);
            const mup = try self.matrixOf(ly.ffn_up);
            try self.linear(l, mgate, n, self.ffn_gate, 0, ff * 4, 0, mgate.rows, 0);
            try self.linear(l, mup, n, self.ffn_up, 0, ff * 4, 0, mup.rows, 0);
            l.named("glu", null, 0, n);
            try l.add(&self.k.glu.?, .{ (n * ff + 63) / 64, 1, 1 }, &.{ self.ffn_gate, self.ffn_up }, &.{n * ff});
            try self.quant(l, self.ffn_gate, ff, n);
            const mdown = try self.matrixOf(ly.ffn_down);
            try self.linear(l, mdown, n, self.projected, 0, d * 4, 0, mdown.rows, 0);
            if (ly.ffn_post_norm != ops.NONE) try self.norm(l, self.projected, ly.ffn_post_norm, n, self.projected);
            l.named("residual", null, 0, n);
            try l.add(&self.k.residual.?, .{ 1, n, 1 }, &.{ self.hidden, self.projected, self.weights }, &.{ d, 0, 0 });
        }
    };
}
