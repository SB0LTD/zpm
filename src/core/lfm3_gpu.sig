//! @zpm/lfm3-gpu — LFM3's forward pass on an Adreno a7xx, in pure Sig.
//!
//! The same work as lfm3_executor.forwardInput, as one command stream per
//! call: per layer the pre-mixer RMSNorm and Q8_K quantization, the short
//! convolution or attention mixer, the residual (with LFM3's sandwich
//! norms), the SwiGLU FFN; then the output norm and the logits. Kernels are
//! lfm3_gpu_kernels'; the GPU is a zpm adreno Device (Galaxy's driver, or
//! the emulator in tests).
//!
//! Memory is the caller's device's, allocated once by `init` (no allocator
//! in sight afterwards): the model file, the f16 KV cache and the conv
//! state, activations for `max_batch` tokens, kernel code and the command
//! stream. The KV cache and conv state keep lfm3_executor's layout, and
//! `source()` maps the model file in the GPU's memory: a host can run the
//! CPU executor on the very same state (cpuCache()) when the GPU fails,
//! after restoreConv() undoes a half-run call's convolution state.

const std = @import("std");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const quantized = @import("quantized_linear");
const adreno = @import("adreno");
const kernels = @import("lfm3_gpu_kernels");

const ir3 = adreno.ir3;
const ir3_asm = adreno.ir3_asm;
const a7xx = adreno.a7xx;
const Device = adreno.device.Device;
const Buffer = adreno.device.Buffer;

pub const Error = error{
    /// The model's shapes are outside what the kernels do (head size 128,
    /// widths in 256-lane blocks, matrices of Q4_K/Q6_K rows in eights...).
    Unsupported,
    BatchCapacity,
    ContextCapacity,
    InvalidToken,
    StreamFull,
    /// The GPU did not finish the call (it hung or faulted): the
    /// host should run the call on the CPU (restoreConv first).
    DeviceLost,
} || adreno.device.Error || ir3_asm.Error || a7xx.Error || executor.Error;

pub const Options = struct {
    max_batch: u32 = 64,
    context: u32 = 4096,
    /// How long one call may take on the GPU before it counts as slow (it
    /// is waited for still: see `finish`).
    timeout_us: u64 = 10_000_000,
};

const MATRIX_VARIANTS = kernels.MAX_TOKENS;

/// The assembled kernels and where their code lives.
const Kernels = struct {
    q4k: [MATRIX_VARIANTS]ir3_asm.Kernel = undefined,
    q6k: [MATRIX_VARIANTS]ir3_asm.Kernel = undefined,
    q4k_va: [MATRIX_VARIANTS]u64 = undefined,
    q6k_va: [MATRIX_VARIANTS]u64 = undefined,
    norm_quant: ir3_asm.Kernel = undefined,
    norm_quant_va: u64 = 0,
    quant: ir3_asm.Kernel = undefined,
    quant_va: u64 = 0,
    residual: ir3_asm.Kernel = undefined,
    residual_va: u64 = 0,
    swiglu: ir3_asm.Kernel = undefined,
    swiglu_va: u64 = 0,
    conv: ir3_asm.Kernel = undefined,
    conv_va: u64 = 0,
    prepare: ir3_asm.Kernel = undefined,
    prepare_va: u64 = 0,
    attention: ir3_asm.Kernel = undefined,
    attention_va: u64 = 0,
};

/// Activation buffers (GPU address and CPU view), sized for max_batch.
const Scratch = struct {
    hidden: Buffer = .{},
    normalized: Buffer = .{},
    mixed: Buffer = .{},
    query: Buffer = .{},
    key: Buffer = .{},
    value: Buffer = .{},
    gate: Buffer = .{},
    mixer: Buffer = .{},
    projected: Buffer = .{},
    ffn_gate: Buffer = .{},
    ffn_up: Buffer = .{},
    act_q: Buffer = .{},
    act_d: Buffer = .{},
    act_sums: Buffer = .{},
    logits: Buffer = .{},
    rope_full: Buffer = .{},
    rope_swa: Buffer = .{},
};

pub fn Backend(comptime tensor_capacity: usize) type {
    return struct {
        const Self = @This();

        dev: Device,
        options: Options,
        plan: *const lfm3.Plan,
        index: *const gguf.Index(tensor_capacity),
        model: Buffer,
        model_size: u64,
        kv: Buffer,
        conv: Buffer,
        conv_snapshot: Buffer,
        s: Scratch = .{},
        k: Kernels = .{},
        code: Buffer,
        ib: Buffer,
        /// The CPU wrote the KV/conv state last (a CPU fallback): it goes to
        /// the GPU before the next GPU call.
        cpu_dirty: bool = false,
        /// GPU calls that did not finish (each one fell back to the CPU), and
        /// why the last one did not.
        lost: u32 = 0,
        last_failure: ?adreno.device.Error = null,
        /// Calls that took longer than options.timeout_us (and finished).
        slow: u32 = 0,

        /// Check the model, allocate everything, copy the model file in,
        /// assemble the kernels. `work` is the assembler's working storage.
        pub fn init(dev: Device, plan: *const lfm3.Plan, index: *const gguf.Index(tensor_capacity), file: gguf.Source, options: Options, work: *ir3_asm.Work) Error!Self {
            try supported(plan, index, options);
            var self = Self{
                .dev = dev,
                .options = options,
                .plan = plan,
                .index = index,
                .model = try dev.alloc(@intCast(file.size)),
                .model_size = file.size,
                .kv = try dev.alloc(try executor.requiredKvElements(plan, options.context) * 2),
                .conv = try dev.alloc(@max(try executor.requiredConvElements(plan), 1) * 4),
                .conv_snapshot = try dev.alloc(@max(try executor.requiredConvElements(plan), 1) * 4),
                .code = try dev.alloc(256 * 1024),
                .ib = try dev.alloc(1 << 20),
            };
            // The model file, as the GPU (and the CPU fallback) reads it.
            var at: u64 = 0;
            while (at < file.size) {
                const n: usize = @intCast(@min(file.size - at, 4 << 20));
                if (!file.read(at, self.model.cpu[@intCast(at)..][0..n])) return error.StorageNotMapped;
                at += n;
            }
            dev.toDevice(self.model, 0, @intCast(file.size));
            @memset(self.kv.cpu, 0);
            @memset(self.conv.cpu, 0);
            dev.toDevice(self.kv, 0, self.kv.cpu.len);
            dev.toDevice(self.conv, 0, self.conv.cpu.len);
            try self.allocScratch();
            try self.assemble(work);
            return self;
        }

        fn allocScratch(self: *Self) Error!void {
            const b: usize = self.options.max_batch;
            const h: usize = self.plan.hidden_size;
            const ff: usize = self.plan.feed_forward_size;
            const q: usize = self.plan.queryWidth();
            const kvw: usize = @as(usize, self.plan.max_kv_head_count) * self.plan.head_size;
            const widest = @max(@max(h, q), ff);
            const d = self.dev;
            self.s.hidden = try d.alloc(b * h * 4);
            self.s.normalized = try d.alloc(b * h * 4);
            self.s.mixed = try d.alloc(b * 3 * h * 4);
            self.s.query = try d.alloc(b * q * 4);
            self.s.key = try d.alloc(b * @max(kvw, 1) * 4);
            self.s.value = try d.alloc(b * @max(kvw, 1) * 4);
            self.s.gate = try d.alloc(b * @as(usize, self.plan.head_count) * 4);
            self.s.mixer = try d.alloc(b * @max(q, h) * 4);
            self.s.projected = try d.alloc(b * h * 4);
            self.s.ffn_gate = try d.alloc(b * ff * 4);
            self.s.ffn_up = try d.alloc(b * ff * 4);
            self.s.act_q = try d.alloc(b * widest);
            self.s.act_d = try d.alloc(b * widest / kernels.QK_K * 4);
            self.s.act_sums = try d.alloc(b * widest / 16 * 2);
            self.s.logits = try d.alloc(@as(usize, self.plan.vocabulary_size) * 4);
            const rope_bytes = b * @as(usize, self.plan.head_size / 2) * 2 * 4;
            self.s.rope_full = try d.alloc(rope_bytes);
            self.s.rope_swa = try d.alloc(rope_bytes);
        }

        fn assemble(self: *Self, work: *ir3_asm.Work) Error!void {
            const code: []u64 = @alignCast(std.mem.bytesAsSlice(u64, self.code.cpu));
            var used: usize = 0;
            const put = struct {
                fn f(c: []u64, u: *usize, w: *ir3_asm.Work, src: []const u8, va_base: u64, out_va: *u64) Error!ir3_asm.Kernel {
                    // (code starts on 128-byte boundaries: SP_CS_BASE)
                    u.* = std.mem.alignForward(usize, u.*, 16);
                    const k = try ir3_asm.assemble(ir3.A7XX, src, w, c[u.*..]);
                    out_va.* = va_base + u.* * 8;
                    u.* += k.code.len;
                    return k;
                }
            }.f;
            const va = self.code.va;
            inline for (0..MATRIX_VARIANTS) |t| {
                self.k.q4k[t] = try put(code, &used, work, comptime kernels.q4kMatrixSource(t + 1), va, &self.k.q4k_va[t]);
                self.k.q6k[t] = try put(code, &used, work, comptime kernels.q6kMatrixSource(t + 1), va, &self.k.q6k_va[t]);
            }
            // (widths up to 4096: one wave per 256-lane block, 16 at most)
            const waves = self.plan.hidden_size / kernels.QK_K;
            self.k.norm_quant = try put(code, &used, work, normQuantSource(waves), va, &self.k.norm_quant_va);
            self.k.residual = try put(code, &used, work, residualSource(waves, self.plan.sandwich_norms), va, &self.k.residual_va);
            self.k.quant = try put(code, &used, work, comptime kernels.quantSource(false, 1), va, &self.k.quant_va);
            self.k.swiglu = try put(code, &used, work, comptime kernels.swigluSource(), va, &self.k.swiglu_va);
            self.k.conv = try put(code, &used, work, convSourceFor(self.plan.conv_kernel), va, &self.k.conv_va);
            self.k.prepare = try put(code, &used, work, comptime kernels.prepareSource(), va, &self.k.prepare_va);
            self.k.attention = try put(code, &used, work, comptime kernels.attentionSource(), va, &self.k.attention_va);
            self.dev.toDevice(self.code, 0, used * 8);
        }

        /// The model file in GPU memory, for the CPU executor (fallback, and
        /// the parts that stay on the CPU).
        pub fn source(self: *const Self) gguf.Source {
            return .{ .context = self, .size = self.model_size, .read_at = readAt, .map_at = mapAt };
        }

        fn readAt(context: *const anyopaque, offset: u64, destination: []u8) bool {
            const self: *const Self = @ptrCast(@alignCast(context));
            if (offset > self.model_size or destination.len > self.model_size - offset) return false;
            @memcpy(destination, self.model.cpu[@intCast(offset)..][0..destination.len]);
            return true;
        }

        fn mapAt(context: *const anyopaque, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
            const self: *const Self = @ptrCast(@alignCast(context));
            if (offset > self.model_size or length > self.model_size - offset) return null;
            const p = self.model.cpu[@intCast(offset)..].ptr;
            if (@intFromPtr(p) % alignment != 0) return null;
            return p;
        }

        /// The KV cache and conv state, in the executor's layout, for the CPU.
        pub fn cpuCache(self: *Self, position: usize) executor.Cache {
            const kv: []u16 = @alignCast(std.mem.bytesAsSlice(u16, self.kv.cpu));
            const conv: []f32 = @alignCast(std.mem.bytesAsSlice(f32, self.conv.cpu));
            const kv_n = executor.requiredKvElements(self.plan, self.options.context) catch 0;
            const conv_n = executor.requiredConvElements(self.plan) catch 0;
            return .{ .kv = kv[0..kv_n], .conv = conv[0..conv_n], .context = self.options.context, .position = position };
        }

        /// Hand the state to the CPU (call before running the CPU executor
        /// on cpuCache()); the next GPU call takes it back.
        pub fn toCpu(self: *Self) void {
            self.dev.fromDevice(self.kv, 0, self.kv.cpu.len);
            self.dev.fromDevice(self.conv, 0, self.conv.cpu.len);
            self.cpu_dirty = true;
        }

        /// Undo what a failed GPU call did to the convolution state (KV rows
        /// past the cache position are simply written again).
        pub fn restoreConv(self: *Self) void {
            @memcpy(self.conv.cpu, self.conv_snapshot.cpu);
            self.dev.toDevice(self.conv, 0, self.conv.cpu.len);
        }

        /// After the last call with Output.hidden or .logits: the output-normed
        /// hidden state of its last position.
        pub fn hidden(self: *const Self) []const f32 {
            const v: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, self.s.normalized.cpu));
            return v[0..self.plan.hidden_size];
        }

        /// After a call with Output.logits: the scores of its last position.
        pub fn logits(self: *const Self) []const f32 {
            const v: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, self.s.logits.cpu));
            return v[0..self.plan.vocabulary_size];
        }

        /// Run `input` at the cache's next positions (as the CPU's
        /// forwardInput) and advance it. With Output.logits, the greedy
        /// token. error.DeviceLost: the GPU did not finish; the cache is not
        /// advanced and restoreConv() + the CPU can redo the call.
        pub fn forward(self: *Self, cache: *executor.Cache, input: executor.Input, output: executor.Output) Error!?u32 {
            const plan = self.plan;
            const h: usize = plan.hidden_size;
            const count: usize = switch (input) {
                .tokens => |t| t.len,
                .embeddings => |e| e.len / h,
            };
            if (count == 0 or count > self.options.max_batch) return error.BatchCapacity;
            if (cache.position + count > self.options.context) return error.ContextCapacity;
            // State from a CPU fallback goes back to the GPU; the conv state is
            // kept so a failed call can be undone.
            if (self.cpu_dirty) {
                self.dev.toDevice(self.kv, 0, self.kv.cpu.len);
                self.dev.toDevice(self.conv, 0, self.conv.cpu.len);
                self.cpu_dirty = false;
            }
            self.dev.fromDevice(self.conv, 0, self.conv.cpu.len);
            @memcpy(self.conv_snapshot.cpu, self.conv.cpu);
            // Inputs: token rows dequantized here (one row each), or given rows.
            const hid: []f32 = @alignCast(std.mem.bytesAsSlice(f32, self.s.hidden.cpu));
            switch (input) {
                .tokens => |tokens| {
                    const emb = try self.matrixInfo(plan.token_embedding);
                    for (tokens, 0..) |token, slot| {
                        if (token >= plan.vocabulary_size) return error.InvalidToken;
                        const row = self.model.cpu[@intCast(emb.offset + @as(u64, token) * emb.row_bytes)..][0..emb.row_bytes];
                        const dst = hid[slot * h ..][0..h];
                        if (emb.q4) try quantized.dequantizeQ4K(dst, row) else try quantized.dequantizeQ6K(dst, row);
                    }
                },
                .embeddings => |rows| @memcpy(hid[0..rows.len], rows),
            }
            self.dev.toDevice(self.s.hidden, 0, count * h * 4);
            // RoPE: full layers by rope_frequency_base and the factors, sliding
            // ones by their own base.
            const half: usize = plan.head_size / 2;
            const factors: ?[]const f32 = if (plan.rope_factors.present()) try self.vector(plan.rope_factors, half) else null;
            kernels.ropeTable(@alignCast(std.mem.bytesAsSlice(f32, self.s.rope_full.cpu)), cache.position, count, plan.head_size, plan.rope_frequency_base, factors);
            kernels.ropeTable(@alignCast(std.mem.bytesAsSlice(f32, self.s.rope_swa.cpu)), cache.position, count, plan.head_size, plan.rope_frequency_base_swa, null);
            self.dev.toDevice(self.s.rope_full, 0, count * half * 8);
            self.dev.toDevice(self.s.rope_swa, 0, count * half * 8);

            var st = a7xx.Stream{ .buf = self.ib.words() };
            st.computeSetup();
            for (plan.layers[0..plan.layer_count]) |*l| try self.layer(&st, l, cache.position, count);
            if (output != .none) {
                // the last position's output norm (and its quantization)
                try self.normQuant(&st, self.s.hidden.va + (count - 1) * h * 4, plan.output_norm, 1);
                if (output == .logits) try self.linear(&st, plan.output, 1, self.s.logits.va);
            }
            st.cleanCaches();
            st.waitForIdle();
            st.check() catch return error.StreamFull;
            self.dev.toDevice(self.ib, 0, st.len * 4);
            const fence = self.dev.submit(self.ib, @intCast(st.len)) catch |e| return self.failed(e);
            self.finish(fence) catch |e| return self.failed(e);
            cache.position += count;
            if (output == .none) return null;
            self.dev.fromDevice(self.s.normalized, 0, h * 4);
            if (output == .hidden) return null;
            self.dev.fromDevice(self.s.logits, 0, self.s.logits.cpu.len);
            return @intCast(argmax(self.logits()));
        }

        /// Wait for a call's stream. One slower than options.timeout_us is
        /// counted and waited for still: until it is done the GPU may write
        /// the state a CPU fallback would take over, so only the driver ends
        /// the wait, with the work done or the GPU lost. (The device's wait
        /// must end by itself when the GPU hangs: Galaxy's do, the driver
        /// finding a fence that stopped moving.)
        fn finish(self: *Self, fence: adreno.device.Fence) adreno.device.Error!void {
            self.dev.wait(fence, self.options.timeout_us) catch |e| {
                if (e != error.Timeout) return e;
                self.slow += 1;
                return self.dev.wait(fence, std.math.maxInt(u64));
            };
        }

        fn failed(self: *Self, e: adreno.device.Error) Error {
            self.lost += 1;
            self.last_failure = e;
            return error.DeviceLost;
        }

        fn layer(self: *Self, st: *a7xx.Stream, l: *const lfm3.Layer, position: usize, count: usize) Error!void {
            const plan = self.plan;
            const h: u32 = plan.hidden_size;
            const n: u32 = @intCast(count);
            try self.normQuant(st, self.s.hidden.va, l.attn_norm, n);
            switch (l.kind) {
                .short_conv => {
                    try self.linear(st, l.in_proj, n, self.s.mixed.va);
                    const taps = try self.tensorAddress(l.conv);
                    const state = self.conv.va + @as(u64, l.slot) * (plan.conv_kernel - 1) * h * 4;
                    try st.program(&self.k.conv, self.k.conv_va);
                    st.constants(0, &(kernels.ConvConsts{ .mixed = self.s.mixed.va, .taps = taps, .state = state, .out = self.s.mixer.va, .hidden = h, .tokens = n }).dwords());
                    st.dispatch(&self.k.conv, .{ h / 64, 1, 1 });
                    st.waitForIdle();
                    try self.quant(st, self.s.mixer.va, h, n);
                    try self.linear(st, l.out_proj, n, self.s.projected.va);
                },
                .attention => {
                    const hd: u32 = plan.head_size;
                    // q, k, v and the gate read the same activations: no wait between
                    try self.linearNoWait(st, l.attn_q, n, self.s.query.va);
                    try self.linearNoWait(st, l.attn_k, n, self.s.key.va);
                    try self.linearNoWait(st, l.attn_v, n, self.s.value.va);
                    try self.linear(st, l.attn_gate, n, self.s.gate.va);
                    const ac = kernels.AttnConsts{
                        .query = self.s.query.va,
                        .key = self.s.key.va,
                        .value = self.s.value.va,
                        .query_norm = try self.tensorAddress(l.attn_q_norm),
                        .key_norm = try self.tensorAddress(l.attn_k_norm),
                        .rope = if (l.sliding_window) self.s.rope_swa.va else self.s.rope_full.va,
                        .gate = self.s.gate.va,
                        .out = self.s.mixer.va,
                        .kv = self.kv.va,
                        .heads = plan.head_count,
                        .kv_heads = l.kv_head_count,
                        .head_size = hd,
                        .context = self.options.context,
                        .slot = l.slot,
                        .max_kv_heads = plan.max_kv_head_count,
                        .first_position = @intCast(position),
                        .epsilon = plan.rms_norm_epsilon,
                        .window = if (l.sliding_window) plan.sliding_window else 0,
                    };
                    try st.program(&self.k.prepare, self.k.prepare_va);
                    st.constants(0, &ac.dwords());
                    st.dispatch(&self.k.prepare, .{ plan.head_count + 2 * @as(u32, l.kv_head_count), n, 1 });
                    st.waitForIdle();
                    try st.program(&self.k.attention, self.k.attention_va);
                    st.constants(0, &ac.dwords());
                    st.constants(6, &ac.outDwords());
                    st.dispatch(&self.k.attention, .{ plan.head_count, n, 1 });
                    st.waitForIdle();
                    try self.quant(st, self.s.mixer.va, @intCast(plan.queryWidth()), n);
                    try self.linear(st, l.attn_output, n, self.s.projected.va);
                },
            }
            try self.residual(st, l.post_attention_norm, n);
            try self.normQuant(st, self.s.hidden.va, l.ffn_norm, n);
            try self.linearNoWait(st, l.ffn_gate, n, self.s.ffn_gate.va);
            try self.linear(st, l.ffn_up, n, self.s.ffn_up.va);
            const ff: u32 = plan.feed_forward_size;
            try st.program(&self.k.swiglu, self.k.swiglu_va);
            st.constants(0, &(kernels.QuantConsts{ .x = self.s.ffn_gate.va, .norm_weight = self.s.ffn_up.va, .act_q = self.s.act_q.va, .act_d = self.s.act_d.va, .act_sums = self.s.act_sums.va, .k = ff }).dwords());
            st.dispatch(&self.k.swiglu, .{ ff / kernels.QK_K, n, 1 });
            st.waitForIdle();
            try self.linear(st, l.ffn_down, n, self.s.projected.va);
            try self.residual(st, l.post_ffw_norm, n);
        }

        /// RMSNorm `n` rows of hidden width at `x` into `normalized`, and
        /// quantize them into the activation arrays.
        fn normQuant(self: *Self, st: *a7xx.Stream, x: u64, norm: lfm3.TensorRef, n: u32) Error!void {
            const h = self.plan.hidden_size;
            try st.program(&self.k.norm_quant, self.k.norm_quant_va);
            st.constants(0, &(kernels.QuantConsts{ .x = x, .norm_weight = try self.tensorAddress(norm), .normalized = self.s.normalized.va, .act_q = self.s.act_q.va, .act_d = self.s.act_d.va, .act_sums = self.s.act_sums.va, .k = h, .epsilon = self.plan.rms_norm_epsilon }).dwords());
            st.dispatch(&self.k.norm_quant, .{ 1, n, 1 });
            st.waitForIdle();
        }

        fn quant(self: *Self, st: *a7xx.Stream, x: u64, width: u32, n: u32) Error!void {
            try st.program(&self.k.quant, self.k.quant_va);
            st.constants(0, &(kernels.QuantConsts{ .x = x, .act_q = self.s.act_q.va, .act_d = self.s.act_d.va, .act_sums = self.s.act_sums.va, .k = width }).dwords());
            st.dispatch(&self.k.quant, .{ width / kernels.QK_K, n, 1 });
            st.waitForIdle();
        }

        /// hidden += post_norm(projected) (sandwich norms) or + projected.
        fn residual(self: *Self, st: *a7xx.Stream, norm: lfm3.TensorRef, n: u32) Error!void {
            const h = self.plan.hidden_size;
            const w = if (self.plan.sandwich_norms) try self.tensorAddress(norm) else 0;
            try st.program(&self.k.residual, self.k.residual_va);
            st.constants(0, &(kernels.QuantConsts{ .x = self.s.projected.va, .norm_weight = w, .normalized = self.s.hidden.va, .act_q = 0, .act_d = 0, .act_sums = 0, .k = h, .epsilon = self.plan.rms_norm_epsilon }).dwords());
            st.dispatch(&self.k.residual, .{ 1, n, 1 });
            st.waitForIdle();
        }

        fn linear(self: *Self, st: *a7xx.Stream, ref: lfm3.TensorRef, n: u32, out: u64) Error!void {
            try self.linearNoWait(st, ref, n, out);
            st.waitForIdle();
        }

        /// out[t][row] = W[row] . activations[t]: passes of up to 8 tokens.
        fn linearNoWait(self: *Self, st: *a7xx.Stream, ref: lfm3.TensorRef, n: u32, out: u64) Error!void {
            const m = try self.matrixInfo(ref);
            const blocks: u32 = @intCast(m.columns / kernels.QK_K);
            var first: u32 = 0;
            while (first < n) {
                const tokens = @min(n - first, MATRIX_VARIANTS);
                const k = if (m.q4) &self.k.q4k[tokens - 1] else &self.k.q6k[tokens - 1];
                const va = if (m.q4) self.k.q4k_va[tokens - 1] else self.k.q6k_va[tokens - 1];
                try st.program(k, va);
                st.constants(0, &(kernels.MatrixConsts{
                    .weights = self.model.va + m.offset,
                    .act_q = self.s.act_q.va + @as(u64, first) * m.columns,
                    .act_d = self.s.act_d.va + @as(u64, first) * blocks * 4,
                    .act_sums = self.s.act_sums.va + @as(u64, first) * blocks * 32,
                    .out = out + @as(u64, first) * m.rows * 4,
                    .row_bytes = @intCast(m.row_bytes),
                    .blocks = blocks,
                    .rows = @intCast(m.rows),
                }).dwords());
                st.dispatch(k, .{ @intCast(m.rows / kernels.MATRIX_ROWS_PER_GROUP), 1, 1 });
                first += tokens;
            }
        }

        const MatrixInfo = struct { offset: u64, row_bytes: usize, rows: usize, columns: usize, q4: bool };

        fn matrixInfo(self: *const Self, ref: lfm3.TensorRef) Error!MatrixInfo {
            if (!ref.present()) return error.InvalidPlan;
            const t = &self.index.tensors[ref.index];
            if (t.dimension_count != 2 or (t.ggml_type != 12 and t.ggml_type != 14)) return error.Unsupported;
            const columns: usize = @intCast(t.dimensions[0]);
            const rows: usize = @intCast(t.dimensions[1]);
            const bb: usize = if (t.ggml_type == 12) kernels.Q4_K_BLOCK else kernels.Q6_K_BLOCK;
            return .{ .offset = t.file_offset, .row_bytes = columns / kernels.QK_K * bb, .rows = rows, .columns = columns, .q4 = t.ggml_type == 12 };
        }

        fn tensorAddress(self: *const Self, ref: lfm3.TensorRef) Error!u64 {
            if (!ref.present()) return error.InvalidPlan;
            return self.model.va + self.index.tensors[ref.index].file_offset;
        }

        fn vector(self: *const Self, ref: lfm3.TensorRef, n: usize) Error![]const f32 {
            const t = &self.index.tensors[ref.index];
            if (t.ggml_type != 0 or t.byte_size != n * 4) return error.InvalidPlan;
            const v: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, self.model.cpu[@intCast(t.file_offset)..][0 .. n * 4]));
            return v;
        }

        /// What the kernels can run.
        fn supported(plan: *const lfm3.Plan, index: *const gguf.Index(tensor_capacity), options: Options) Error!void {
            const h = plan.hidden_size;
            // (hidden widths of 1, 2, 4, 8 or 16 blocks: the row kernels' variants)
            if (h == 0 or h % kernels.QK_K != 0 or !std.math.isPowerOfTwo(h / kernels.QK_K) or h / kernels.QK_K > 16) return error.Unsupported;
            if (plan.feed_forward_size % kernels.QK_K != 0) return error.Unsupported;
            if (plan.queryWidth() % kernels.QK_K != 0) return error.Unsupported;
            if (plan.attention_layer_count > 0 and plan.head_size != 128) return error.Unsupported;
            if (plan.conv_layer_count > 0 and (plan.conv_kernel < 2 or plan.conv_kernel > 8)) return error.Unsupported;
            if (plan.attention_layer_count > 0 and (plan.head_count % @max(plan.max_kv_head_count, 1) != 0)) return error.Unsupported;
            if (options.context > kernels.MAX_ATTENTION_SPAN) return error.Unsupported;
            if (options.max_batch == 0 or options.max_batch > 64) return error.Unsupported;
            if (!plan.output.present()) return error.Unsupported;
            for (index.tensors[0..index.tensor_count]) |*t| {
                if (t.dimension_count == 2 and (t.ggml_type == 12 or t.ggml_type == 14)) {
                    if (t.dimensions[1] % kernels.MATRIX_ROWS_PER_GROUP != 0) return error.Unsupported;
                }
                // (GPU loads of 16-byte rows; f32 vectors on 4)
                if (t.file_offset % 16 != 0) return error.Unsupported;
            }
        }
    };
}

fn argmax(v: []const f32) usize {
    var best: usize = 0;
    for (v, 0..) |x, i| {
        if (x > v[best]) best = i;
    }
    return best;
}

// The kernels whose shape depends on the model, picked at run time from
// the variants the model can need.
fn normQuantSource(waves: u32) []const u8 {
    return switch (waves) {
        inline 1, 2, 4, 8, 16 => |w| comptime kernels.quantSource(true, w),
        else => unreachable,
    };
}

fn residualSource(waves: u32, postnorm: bool) []const u8 {
    return switch (waves) {
        inline 1, 2, 4, 8, 16 => |w| if (postnorm) comptime kernels.residualSource(true, w) else comptime kernels.residualSource(false, w),
        else => unreachable,
    };
}

fn convSourceFor(taps: u32) []const u8 {
    return switch (taps) {
        inline 2...8 => |t| comptime kernels.convSource(t),
        else => comptime kernels.convSource(3),
    };
}
