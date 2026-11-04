//! @zpm/lfm3-any — LFM3's forward pass on any GPU, in pure Sig: the
//! generalization of lfm3_gpu.sig (the Adreno's) and lfm3_nv.sig (the
//! RTX's), over a gpu.Device, with lfm3_kir's kernels compiled for the
//! device's target at `init`.
//!
//! The same work as lfm3_executor.forwardInput, as one ordered list of
//! dispatches per call: per layer the pre-mixer RMSNorm and Q8_K
//! quantization, the short convolution or attention mixer, the residual
//! (with LFM3's sandwich norms), the SwiGLU FFN; then the output norm and
//! the logits. The API is lfm3_gpu.Backend's: `init`, `newCache`, `forward`,
//! `toCpu`, `logits`, `hidden`, `source`, and the errors DeviceLost and
//! LongContext with the same meaning (the cache is as it was; toCpu, then
//! the CPU executor does the call).
//!
//! # Memory, by the device's memory model
//!
//! - Unified (the Surface's Adreno, Apple, Intel iGPUs): the weights are
//!   the model file itself, imported zero-copy (Device.import) when the
//!   device can and the file is mapped (galaxy-think's mmap); otherwise
//!   copied once into a `.device` buffer. Everything else is ordinary
//!   memory both sides see; toDevice/fromDevice are the cache maintenance a
//!   non-coherent GPU needs.
//! - Discrete (the Legion's RTX): the weights, activations, scratch and
//!   each sequence's KV cache are `.device` (VRAM). What the CPU reads after
//!   every call (the logits, the hidden row, the conv state) is `.host`;
//!   what it writes every call (RoPE tables, token rows) is `.upload`. When
//!   a `.device` buffer has no CPU view, data goes through a staging buffer
//!   and lfm3_kir's copy kernel (the model at init, token rows each call,
//!   the KV cache on toCpu and back).
//!
//! Between calls the conv state is the CPU's (a host keeps checkpoints of
//! it, as galaxy-think does): each call hands it to the GPU and takes it
//! back. The KV cache is the GPU's until toCpu hands it over.
//!
//! # Long context
//!
//! Attention runs split by keys (lfm3_kir's scores, softmax, values and
//! combine kernels) over any span up to Options.max_span positions (8192
//! by default: galaxy-think's slots), the scratch sized for
//! Options.attention_tokens tokens a launch. A call reaching further back
//! is error.LongContext.
//!
//! Allocation-free: buffers are the device's, the kernels' building and
//! the dispatch lists in the caller's Work (which must outlive the
//! backend).

const std = @import("std");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const quantized = @import("quantized_linear");
const gpu = @import("gpu");
pub const kernels = @import("lfm3_kir");

const kir = gpu.kir;
pub const Device = gpu.Device;
pub const Buffer = gpu.Buffer;
pub const Caps = gpu.Caps;
pub const Program = gpu.Program;

pub const Error = error{
    /// The model's shapes are outside what the kernels do (head size 128,
    /// widths in 256-lane blocks, Q4_K/Q6_K matrices, 2 to 8 conv taps,
    /// query groups in powers of two...), or the device's limits are.
    Unsupported,
    /// A kernel did not compile for the device (`compile_error` says why).
    CompileFailed,
    BatchCapacity,
    ContextCapacity,
    InvalidToken,
    /// More dispatches than the Work holds.
    StreamFull,
    /// The GPU did not finish the call (it hung or faulted): the cache is
    /// as it was before it, and the host runs the call on the CPU (toCpu
    /// first).
    DeviceLost,
    /// The call's attention reaches further back than Options.max_span:
    /// the host runs it on the CPU (toCpu first).
    LongContext,
} || gpu.Error || executor.Error;

pub const Options = struct {
    max_batch: u32 = 64,
    /// How long one call may take on the GPU before it counts as slow (it
    /// is waited for still: see `finish`).
    timeout_us: u64 = 10_000_000,
    /// The most positions one attention row reads on the GPU.
    max_span: u32 = 8192,
    /// Tokens one attention launch takes (its scratch: tokens x heads x
    /// max_span scores).
    attention_tokens: u32 = 16,
    /// Map the model file zero-copy where the device can (unified memory,
    /// caps.import, the file mapped).
    import: bool = true,
    /// Dispatches one Device.run takes at most (a call sends more as
    /// several runs, each waited for: nvidia_device takes 256).
    max_run: u32 = 256,
    /// Diagnose mode (lfm3_gpu's): every dispatch of a call is a run of its
    /// own, and `diagnose` is called with a line naming it before it is
    /// sent ("lfm3-any: dispatch 12, layer 2 of 24 (attention): matrix
    /// q4k, blk.2.attn_q.weight, tokens 0-7 of 16, groups 64x1x1"). Each is
    /// waited for diagnose_timeout_us, then a line says it is still running
    /// and the wait goes on until the device ends it; a failure is logged
    /// ("FAILED (<error>): <what>") and the call is error.DeviceLost with
    /// the cache as it was. So the last line before a fault or a hang names
    /// the kernel, the layer and the tensor. Slow: for checking a GPU.
    diagnose: ?*const fn (what: []const u8) void = null,
    diagnose_timeout_us: u64 = 2_000_000,
};

pub const MATRIX_VARIANTS = kernels.MAX_TOKENS;
/// Dispatches one call may send (Work's capacity).
pub const MAX_DISPATCHES = 4096;
const MAX_BINDINGS = 8;
const MAX_WORDS = 16;
const HALF_HEAD = kernels.HEAD_SIZE / 2;
/// A token row's bytes at most (8192 columns of Q6_K).
const MAX_ROW_BYTES = 8192 / quantized.QK_K * quantized.Q6_K_BLOCK_BYTES;
/// Staging chunk for uploads to `.device` memory without a CPU view.
const STAGING_BYTES = 4 << 20;

/// The caller's working storage: the kernels' KIR while they are built and
/// compiled, and each call's dispatch list. It must outlive the backend.
pub const Work = struct {
    insts: [16384]kir.Inst = undefined,
    tys: [16384]kir.Ty = undefined,
    // (the backends' working storage: kir_ir3 takes about 12 MB)
    compile_mem: [24 << 20]u8 align(16) = undefined,
    code: [512 << 10]u8 align(16) = undefined,
    dispatches: [MAX_DISPATCHES]gpu.Dispatch = undefined,
    /// What each dispatch is (diagnose mode's lines).
    descs: [MAX_DISPATCHES]Desc = undefined,
    buffers: [MAX_DISPATCHES * 4]Buffer = undefined,
    words: [MAX_DISPATCHES * 12]u32 = undefined,
};

/// The compiled kernels (programs in device memory).
const Programs = struct {
    q4k: [MATRIX_VARIANTS]?Program = @splat(null),
    q6k: [MATRIX_VARIANTS]?Program = @splat(null),
    norm_quant: ?Program = null,
    quant: ?Program = null,
    swiglu: ?Program = null,
    residual: ?Program = null,
    conv: ?Program = null,
    prepare: ?Program = null,
    scores_decode: ?Program = null,
    scores_prefill: ?Program = null,
    softmax: ?Program = null,
    values_decode: ?Program = null,
    values_prefill: ?Program = null,
    combine: ?Program = null,
    copy: ?Program = null,
};

/// Activation buffers, sized for max_batch.
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
    scores: Buffer = .{},
    partial: Buffer = .{},
    /// (upload) the RoPE tables, written every call
    rope_full: Buffer = .{},
    rope_swa: Buffer = .{},
    /// (upload) token rows, when `hidden` has no CPU view
    input: Buffer = .{},
};

/// A sequence's state on the GPU: the KV cache and conv state in
/// lfm3_executor's layout. `cpu` is the executor's view of them: kv's and
/// conv's CPU views, or (kv without one) the host mirror's.
pub const Cache = struct {
    cpu: executor.Cache,
    kv: Buffer,
    /// (host) The executor's KV rows when `kv` has no CPU view.
    kv_host: ?Buffer = null,
    conv: Buffer,
    /// The CPU holds the KV rows (toCpu): they go to the GPU before its next
    /// call on this cache.
    kv_on_cpu: bool = false,
};

const MatrixInfo = struct { offset: u32, row_bytes: u32, rows: u32, blocks: u32, q4: bool, tensor: u16 };

/// What a dispatch is, for diagnose mode's lines.
pub const Desc = struct {
    kernel: []const u8 = "",
    /// The layer (none: the inputs' copies, the output norm, the logits).
    layer: ?u8 = null,
    /// The tensor it reads (an index in the gguf Index).
    tensor: ?u16 = null,
    /// The call's tokens it takes.
    first: u32 = 0,
    count: u32 = 0,
};

/// A call's dispatches as they are written (in the Work).
const List = struct {
    work: *Work,
    n: usize = 0,
    nb: usize = 0,
    nw: usize = 0,
    /// What the next dispatches are (set before they are added).
    what: Desc = .{},

    fn add(l: *List, prog: *const Program, groups: [3]u32, buffers: []const Buffer, words: []const u32) Error!void {
        if (l.n >= l.work.dispatches.len or l.nb + buffers.len > l.work.buffers.len or l.nw + words.len > l.work.words.len) return error.StreamFull;
        const bs = l.work.buffers[l.nb..][0..buffers.len];
        @memcpy(bs, buffers);
        const ws = l.work.words[l.nw..][0..words.len];
        @memcpy(ws, words);
        l.nb += buffers.len;
        l.nw += words.len;
        l.work.dispatches[l.n] = .{ .prog = prog, .groups = groups, .buffers = bs, .params = ws };
        l.work.descs[l.n] = l.what;
        l.n += 1;
    }

    /// The next dispatches' kernel, tensor and tokens (in the same layer).
    fn named(l: *List, kernel: []const u8, tensor: ?u16, first: u32, count: u32) void {
        l.what.kernel = kernel;
        l.what.tensor = tensor;
        l.what.first = first;
        l.what.count = count;
    }

    fn slice(l: *const List) []const gpu.Dispatch {
        return l.work.dispatches[0..l.n];
    }
};

pub fn Backend(comptime tensor_capacity: usize) type {
    return struct {
        const Self = @This();

        dev: Device,
        caps: Caps,
        options: Options,
        plan: *const lfm3.Plan,
        index: *const gguf.Index(tensor_capacity),
        /// The model file the host gave init (token rows, the RoPE factors;
        /// the weights themselves when imported).
        file: gguf.Source,
        work: *Work,
        weights: Buffer = .{},
        /// The weights are the file's own memory (imported).
        imported: bool = false,
        model_size: u64,
        factors: [HALF_HEAD]f32 = @splat(1),
        has_factors: bool = false,
        s: Scratch = .{},
        /// (host) The last call's output-normed hidden row and logits.
        out_hidden: Buffer = .{},
        out_logits: Buffer = .{},
        /// (host) The conv state as a call found it: put back when the
        /// call fails, the GPU having written part of it.
        conv_snapshot: Buffer = .{},
        k: Programs = .{},
        /// Attention workgroups: query heads (of one KV head) and tokens.
        heads_per_group: u32 = 1,
        tokens_per_group: u32 = 1,
        /// GPU calls that did not finish (each one fell back to the CPU), and
        /// why the last one did not.
        lost: u32 = 0,
        last_failure: ?gpu.Error = null,
        /// Calls that took longer than options.timeout_us (and finished).
        slow: u32 = 0,
        /// Dispatches the last call sent, and every call's.
        dispatches: u32 = 0,
        total_dispatches: u64 = 0,
        /// The device's time for the last call (ns; 0 when it does not say).
        last_ns: u64 = 0,
        /// Why the last kernel did not compile.
        compile_error: ?anyerror = null,

        /// Check the model, place the weights by the memory model, allocate
        /// everything, compile the kernels. `file` must outlive the backend,
        /// as must `work`.
        pub fn init(dev: Device, plan: *const lfm3.Plan, index: *const gguf.Index(tensor_capacity), file: gguf.Source, options: Options, work: *Work) Error!Self {
            try supported(plan, index, options, dev.caps);
            var self = Self{
                .dev = dev,
                .caps = dev.caps,
                .options = options,
                .plan = plan,
                .index = index,
                .file = file,
                .work = work,
                .model_size = file.size,
            };
            errdefer self.deinit();
            try self.compileAll();
            try self.placeWeights();
            try self.readFactors();
            try self.allocBuffers();
            return self;
        }

        /// Every buffer and program back to the device.
        pub fn deinit(self: *Self) void {
            const s = &self.s;
            const bufs = [_]*Buffer{ &s.hidden, &s.normalized, &s.mixed, &s.query, &s.key, &s.value, &s.gate, &s.mixer, &s.projected, &s.ffn_gate, &s.ffn_up, &s.act_q, &s.act_d, &s.act_sums, &s.scores, &s.partial, &s.rope_full, &s.rope_swa, &s.input, &self.out_hidden, &self.out_logits, &self.conv_snapshot };
            for (bufs) |b| self.release(b);
            if (!self.imported) self.release(&self.weights) else self.weights = .{};
            const k = &self.k;
            for (&k.q4k) |*p| self.unload(p);
            for (&k.q6k) |*p| self.unload(p);
            const progs = [_]*?Program{ &k.norm_quant, &k.quant, &k.swiglu, &k.residual, &k.conv, &k.prepare, &k.scores_decode, &k.scores_prefill, &k.softmax, &k.values_decode, &k.values_prefill, &k.combine, &k.copy };
            for (progs) |p| self.unload(p);
        }

        fn release(self: *Self, b: *Buffer) void {
            if (b.bytes != 0) self.dev.free(b.*);
            b.* = .{};
        }

        fn unload(self: *Self, p: *?Program) void {
            if (p.*) |*prog| self.dev.unload(prog);
            p.* = null;
        }

        // ── Kernels ──

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
            const plan = self.plan;
            const caps = self.caps;
            const s = kir.Storage{ .insts = &self.work.insts, .tys = &self.work.tys };
            const used = formatsUsed(plan, self.index);
            for (0..@min(self.options.max_batch, MATRIX_VARIANTS)) |t| {
                const tokens: u32 = @intCast(t + 1);
                if (used.q4) try self.build(&self.k.q4k[t], kernels.matrix(s, caps, .q4_k, tokens));
                if (used.q6) try self.build(&self.k.q6k[t], kernels.matrix(s, caps, .q6_k, tokens));
            }
            try self.build(&self.k.norm_quant, kernels.quant(s, caps, .norm));
            try self.build(&self.k.quant, kernels.quant(s, caps, .plain));
            try self.build(&self.k.swiglu, kernels.quant(s, caps, .swiglu));
            try self.build(&self.k.residual, kernels.residual(s, caps, plan.sandwich_norms));
            try self.build(&self.k.copy, kernels.copy(s, caps));
            if (plan.conv_layer_count > 0) try self.build(&self.k.conv, kernels.conv(s, caps, plan.conv_kernel));
            if (plan.attention_layer_count > 0) {
                const group = plan.head_count / attentionGroupSize(plan);
                const hg = @min(group, kernels.MAX_ROWS);
                self.heads_per_group = hg;
                self.tokens_per_group = 1;
                try self.build(&self.k.prepare, kernels.prepare(s, caps));
                try self.build(&self.k.scores_decode, kernels.attnScores(s, caps, hg, 1));
                try self.build(&self.k.values_decode, kernels.attnValues(s, caps, hg, 1));
                // The prefill tiles: as many tokens a workgroup as the
                // target's registers take (8 rows, else fewer; one token
                // is the decode kernels').
                var tt = kernels.MAX_ROWS / hg;
                while (tt > 1 and self.options.max_batch > 1) : (tt /= 2) {
                    self.build(&self.k.scores_prefill, kernels.attnScores(s, caps, hg, tt)) catch |e| {
                        if (e != error.CompileFailed) return e;
                        continue;
                    };
                    self.build(&self.k.values_prefill, kernels.attnValues(s, caps, hg, tt)) catch |e| {
                        self.unload(&self.k.scores_prefill);
                        if (e != error.CompileFailed) return e;
                        continue;
                    };
                    self.tokens_per_group = tt;
                    self.compile_error = null;
                    break;
                }
                try self.build(&self.k.softmax, kernels.attnSoftmax(s, caps));
                try self.build(&self.k.combine, kernels.attnCombine(s, caps));
            }
        }

        // ── Memory ──

        /// The weights by the memory model: the file itself (imported), or
        /// a copy in `.device` memory.
        fn placeWeights(self: *Self) Error!void {
            const size = self.file.size;
            if (size > std.math.maxInt(u32)) return error.Unsupported;
            if (self.options.import and self.caps.memory == .unified and self.caps.import) {
                if (self.file.view(0, @intCast(size), 16)) |bytes| {
                    if (self.dev.import(@constCast(bytes))) |b| {
                        self.weights = b;
                        self.imported = true;
                        return;
                    }
                }
            }
            // (whole 16-byte words: the staging path copies them)
            self.weights = try self.dev.alloc(std.mem.alignForward(u64, size, 16), .device);
            if (self.weights.cpu.len >= size) {
                var at: u64 = 0;
                while (at < size) {
                    const n: usize = @intCast(@min(size - at, 4 << 20));
                    if (!self.file.read(at, self.weights.cpu[@intCast(at)..][0..n])) return error.StorageNotMapped;
                    at += n;
                }
                self.dev.toDevice(self.weights, 0, size);
                return;
            }
            // (VRAM without a CPU view: through a staging buffer)
            const staging = try self.dev.alloc(STAGING_BYTES, .upload);
            defer self.dev.free(staging);
            var at: u64 = 0;
            while (at < size) {
                const n: usize = @intCast(@min(size - at, STAGING_BYTES));
                const padded = std.mem.alignForward(usize, n, 16);
                if (!self.file.read(at, staging.cpu[0..n])) return error.StorageNotMapped;
                @memset(staging.cpu[n..padded], 0);
                self.dev.toDevice(staging, 0, padded);
                var l = List{ .work = self.work };
                try self.copyInto(&l, staging, 0, self.weights, @intCast(at), @intCast(padded / 16));
                try self.runNow(&l);
                at += n;
            }
        }

        fn copyInto(self: *Self, l: *List, from: Buffer, from_off: u32, to: Buffer, to_off: u32, words: u32) Error!void {
            l.what = .{ .kernel = "copy" };
            try l.add(&self.k.copy.?, kernels.copyGroups(words), &.{ from, to }, &.{ words, from_off, to_off });
        }

        fn runNow(self: *Self, l: *const List) Error!void {
            if (l.n == 0) return;
            const fence = try self.dev.run(l.slice());
            try self.dev.wait(fence, std.math.maxInt(u64));
        }

        /// The full layers' RoPE frequency factors (from the file, once).
        fn readFactors(self: *Self) Error!void {
            const plan = self.plan;
            if (plan.attention_layer_count == 0 or !plan.rope_factors.present()) return;
            const t = try self.tensorOf(plan.rope_factors);
            if (t.ggml_type != 0 or t.byte_size != HALF_HEAD * 4) return error.InvalidPlan;
            if (!self.file.read(t.file_offset, std.mem.sliceAsBytes(&self.factors))) return error.StorageNotMapped;
            self.has_factors = true;
        }

        fn allocBuffers(self: *Self) Error!void {
            const plan = self.plan;
            const b: u64 = self.options.max_batch;
            const h: u64 = plan.hidden_size;
            const ff: u64 = plan.feed_forward_size;
            const q: u64 = plan.queryWidth();
            const kvw: u64 = @as(u64, plan.max_kv_head_count) * plan.head_size;
            const widest = @max(@max(h, q), ff);
            const d = self.dev;
            const s = &self.s;
            s.hidden = try d.alloc(b * h * 4, .device);
            s.normalized = try d.alloc(b * h * 4, .device);
            s.mixed = try d.alloc(b * 3 * h * 4, .device);
            s.query = try d.alloc(b * @max(q, 1) * 4, .device);
            s.key = try d.alloc(b * @max(kvw, 1) * 4, .device);
            s.value = try d.alloc(b * @max(kvw, 1) * 4, .device);
            s.gate = try d.alloc(b * @max(plan.head_count, 1) * 4, .device);
            s.mixer = try d.alloc(b * @max(q, h) * 4, .device);
            s.projected = try d.alloc(b * h * 4, .device);
            s.ffn_gate = try d.alloc(b * ff * 4, .device);
            s.ffn_up = try d.alloc(b * ff * 4, .device);
            s.act_q = try d.alloc(b * widest, .device);
            s.act_d = try d.alloc(b * widest / quantized.QK_K * 4, .device);
            s.act_sums = try d.alloc(b * widest / 16 * 2, .device);
            if (plan.attention_layer_count > 0) {
                const at: u64 = @min(self.options.attention_tokens, self.options.max_batch);
                s.scores = try d.alloc(at * plan.head_count * @as(u64, self.options.max_span) * 4, .device);
                s.partial = try d.alloc(at * plan.head_count * @as(u64, self.chunks()) * kernels.HEAD_SIZE * 4, .device);
                const rope_bytes = b * HALF_HEAD * 2 * 4;
                s.rope_full = try d.alloc(rope_bytes, .upload);
                s.rope_swa = try d.alloc(rope_bytes, .upload);
            }
            if (s.hidden.cpu.len == 0) s.input = try d.alloc(b * h * 4, .upload);
            self.out_hidden = try d.alloc(h * 4, .host);
            self.out_logits = try d.alloc(@as(u64, plan.vocabulary_size) * 4, .host);
            self.conv_snapshot = try d.alloc(@max(try executor.requiredConvElements(plan), 1) * 4, .host);
        }

        /// Partial outputs a row: the value chunks a span of max_span meets.
        fn chunks(self: *const Self) u32 {
            return self.options.max_span / kernels.VALUE_CHUNK + 2;
        }

        /// The model file in GPU memory (or the file itself where the
        /// weights are it, or the GPU's copy has no CPU view), for the CPU
        /// executor (fallback, and the parts that stay on the CPU).
        pub fn source(self: *const Self) gguf.Source {
            if (self.imported or self.weights.cpu.len < self.model_size) return self.file;
            return .{ .context = self, .size = self.model_size, .read_at = readAt, .map_at = mapAt };
        }

        fn readAt(context: *const anyopaque, offset: u64, destination: []u8) bool {
            const self: *const Self = @ptrCast(@alignCast(context));
            if (offset > self.model_size or destination.len > self.model_size - offset) return false;
            @memcpy(destination, self.weights.cpu[@intCast(offset)..][0..destination.len]);
            return true;
        }

        fn mapAt(context: *const anyopaque, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
            const self: *const Self = @ptrCast(@alignCast(context));
            if (offset > self.model_size or length > self.model_size - offset) return null;
            const p = self.weights.cpu[@intCast(offset)..].ptr;
            if (@intFromPtr(p) % alignment != 0) return null;
            return p;
        }

        /// A sequence's state for `context` positions, zeroed (position 0).
        pub fn newCache(self: *Self, context: u32) Error!Cache {
            const kv_n = if (self.plan.attention_layer_count > 0) try executor.requiredKvElements(self.plan, context) else 0;
            const conv_n = try executor.requiredConvElements(self.plan);
            const kv_bytes: u64 = @max(kv_n * 2, 16);
            if (kv_bytes > std.math.maxInt(u32)) return error.ContextCapacity;
            const kv = try self.dev.alloc(kv_bytes, .device);
            errdefer self.dev.free(kv);
            const conv = try self.dev.alloc(@max(conv_n, 1) * 4, .host);
            errdefer self.dev.free(conv);
            var c = Cache{ .cpu = undefined, .kv = kv, .conv = conv };
            var view: []u8 = kv.cpu;
            if (kv.cpu.len == 0) {
                const mirror = try self.dev.alloc(kv_bytes, .host);
                c.kv_host = mirror;
                view = mirror.cpu;
                @memset(view, 0);
                // (fresh device memory reads as zeros; the mirror matches it)
            } else {
                @memset(kv.cpu, 0);
                self.dev.toDevice(kv, 0, kv.bytes);
            }
            @memset(conv.cpu, 0);
            self.dev.toDevice(conv, 0, conv.bytes);
            const kv_view: []u16 = @alignCast(std.mem.bytesAsSlice(u16, view[0 .. kv_n * 2]));
            const conv_view: []f32 = @alignCast(std.mem.bytesAsSlice(f32, conv.cpu[0 .. conv_n * 4]));
            c.cpu = .{ .kv = kv_view, .conv = conv_view, .context = context };
            return c;
        }

        pub fn freeCache(self: *Self, c: *Cache) void {
            self.dev.free(c.kv);
            if (c.kv_host) |m| self.dev.free(m);
            self.dev.free(c.conv);
            c.* = undefined;
        }

        /// Hand the cache to the CPU: call before running the CPU executor on
        /// c.cpu. The next GPU call on it takes the KV rows back.
        pub fn toCpu(self: *Self, c: *Cache) void {
            if (c.kv_on_cpu) return;
            if (c.kv_host) |m| {
                var l = List{ .work = self.work };
                self.copyInto(&l, c.kv, 0, m, 0, @intCast(c.kv.bytes / 16)) catch return;
                self.runNow(&l) catch return;
                self.dev.fromDevice(m, 0, m.bytes);
            } else {
                self.dev.fromDevice(c.kv, 0, c.kv.bytes);
            }
            c.kv_on_cpu = true;
        }

        /// After the last call with Output.hidden or .logits: the output-normed
        /// hidden state of its last position.
        pub fn hidden(self: *const Self) []const f32 {
            const v: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, self.out_hidden.cpu));
            return v[0..self.plan.hidden_size];
        }

        /// After a call with Output.logits: the scores of its last position.
        pub fn logits(self: *const Self) []const f32 {
            const v: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, self.out_logits.cpu));
            return v[0..self.plan.vocabulary_size];
        }

        /// Run `input` at the cache's next positions (as the CPU's
        /// forwardInput) and advance it. With Output.logits, the greedy
        /// token. error.DeviceLost or error.LongContext: the cache is as it
        /// was, and toCpu() + the CPU executor can do the call.
        pub fn forward(self: *Self, c: *Cache, input: executor.Input, output: executor.Output) Error!?u32 {
            const cache = &c.cpu;
            const plan = self.plan;
            const h: usize = plan.hidden_size;
            const count: usize = switch (input) {
                .tokens => |t| t.len,
                .embeddings => |e| e.len / h,
            };
            if (count == 0 or count > self.options.max_batch) return error.BatchCapacity;
            switch (input) {
                .tokens => |tokens| for (tokens) |token| {
                    if (token >= plan.vocabulary_size) return error.InvalidToken;
                },
                .embeddings => |rows| if (rows.len % h != 0) return error.InvalidToken,
            }
            if (cache.position + count > cache.context) return error.ContextCapacity;
            if (self.span(cache.position + count) > self.options.max_span) return error.LongContext;
            var l = List{ .work = self.work };
            // KV rows from a CPU fallback, and the CPU's conv state, to the GPU;
            // the conv state kept so a failed call can be undone.
            // (the GPU's again once this call is done: a call that fails
            // takes them over again next time)
            const kv_back = c.kv_on_cpu;
            if (kv_back) {
                if (c.kv_host) |m| {
                    self.dev.toDevice(m, 0, m.bytes);
                    try self.copyInto(&l, m, 0, c.kv, 0, @intCast(c.kv.bytes / 16));
                } else self.dev.toDevice(c.kv, 0, c.kv.bytes);
            }
            const conv_bytes = cache.conv.len * 4;
            self.dev.toDevice(c.conv, 0, conv_bytes);
            @memcpy(self.conv_snapshot.cpu[0..conv_bytes], c.conv.cpu[0..conv_bytes]);
            // Inputs: token rows dequantized here from the file, or given rows.
            const direct = self.s.hidden.cpu.len != 0;
            const rows_buf = if (direct) self.s.hidden else self.s.input;
            const hid: []f32 = @alignCast(std.mem.bytesAsSlice(f32, rows_buf.cpu[0 .. count * h * 4]));
            switch (input) {
                .tokens => |tokens| for (tokens, 0..) |token, slot| try self.embed(token, hid[slot * h ..][0..h]),
                .embeddings => |rows| @memcpy(hid[0..rows.len], rows),
            }
            self.dev.toDevice(rows_buf, 0, count * h * 4);
            if (!direct) try self.copyInto(&l, self.s.input, 0, self.s.hidden, 0, @intCast(count * h * 4 / 16));
            // RoPE: full layers by rope_frequency_base and the factors, sliding
            // ones by their own base.
            if (plan.attention_layer_count > 0) {
                const factors: ?[]const f32 = if (self.has_factors) &self.factors else null;
                kernels.ropeTable(@alignCast(std.mem.bytesAsSlice(f32, self.s.rope_full.cpu)), cache.position, count, plan.head_size, plan.rope_frequency_base, factors);
                kernels.ropeTable(@alignCast(std.mem.bytesAsSlice(f32, self.s.rope_swa.cpu)), cache.position, count, plan.head_size, plan.rope_frequency_base_swa, null);
                self.dev.toDevice(self.s.rope_full, 0, count * HALF_HEAD * 8);
                self.dev.toDevice(self.s.rope_swa, 0, count * HALF_HEAD * 8);
            }

            const n: u32 = @intCast(count);
            for (plan.layers[0..plan.layer_count], 0..) |*ly, li| {
                l.what = .{ .layer = @intCast(li) };
                try self.layer(&l, ly, c, n);
            }
            l.what = .{};
            if (output != .none) {
                // the last position's output norm (and its quantization)
                try self.normQuant(&l, @intCast((count - 1) * h * 4), plan.output_norm, 1, self.out_hidden);
                if (output == .logits) try self.linear(&l, try self.matrixOf(plan.output), 1, self.out_logits, plan.vocabulary_size * 4);
            }
            self.dispatches = @intCast(l.n);
            self.total_dispatches += l.n;
            var ns: u64 = 0;
            if (self.options.diagnose) |log| {
                for (l.slice(), 0..) |*d, i| {
                    var buf: [256]u8 = undefined;
                    const what = self.describe(&l, i, count, &buf);
                    log(what);
                    const fence = self.dev.run(d[0..1]) catch |e| return self.diagnoseFailed(log, c, e, what);
                    self.dev.wait(fence, self.options.diagnose_timeout_us) catch |e| {
                        if (e != error.Timeout) return self.diagnoseFailed(log, c, e, what);
                        var b2: [320]u8 = undefined;
                        log(std.fmt.bufPrint(&b2, "lfm3-any: still running after {d} ms (a hang?): {s}", .{ self.options.diagnose_timeout_us / 1000, what["lfm3-any: ".len..] }) catch what);
                        self.slow += 1;
                        self.dev.wait(fence, std.math.maxInt(u64)) catch |e2| return self.diagnoseFailed(log, c, e2, what);
                    };
                    ns += self.dev.lastRunNs();
                }
                var b3: [128]u8 = undefined;
                log(std.fmt.bufPrint(&b3, "lfm3-any: forward of {d} tokens at position {d}: all {d} dispatches done", .{ count, cache.position, l.n }) catch "lfm3-any: forward done");
            } else {
                var at: usize = 0;
                while (at < l.n) {
                    const part = l.slice()[at..@min(l.n, at + self.options.max_run)];
                    const fence = self.dev.run(part) catch |e| return self.failed(c, e);
                    self.finish(fence) catch |e| return self.failed(c, e);
                    ns += self.dev.lastRunNs();
                    at += part.len;
                }
            }
            self.last_ns = ns;
            if (kv_back) c.kv_on_cpu = false;
            self.dev.fromDevice(c.conv, 0, conv_bytes);
            cache.position += count;
            if (output == .none) return null;
            self.dev.fromDevice(self.out_hidden, 0, h * 4);
            if (output == .hidden) return null;
            self.dev.fromDevice(self.out_logits, 0, self.out_logits.bytes);
            return @intCast(argmax(self.logits()));
        }

        /// Token `token`'s embedding row, dequantized from the file.
        fn embed(self: *const Self, token: u32, dst: []f32) Error!void {
            const t = try self.tensorOf(self.plan.token_embedding);
            const row_bytes = @as(usize, self.plan.hidden_size) / quantized.QK_K * blockBytes(t.ggml_type);
            const offset = t.file_offset + @as(u64, token) * row_bytes;
            var buf: [MAX_ROW_BYTES]u8 = undefined;
            const row = self.file.view(offset, row_bytes, 1) orelse blk: {
                if (row_bytes > buf.len or !self.file.read(offset, buf[0..row_bytes])) return error.StorageNotMapped;
                break :blk buf[0..row_bytes];
            };
            if (t.ggml_type == 12) try quantized.dequantizeQ4K(dst, row) else try quantized.dequantizeQ6K(dst, row);
        }

        /// Wait for a call. One slower than options.timeout_us is counted and
        /// waited for still: until it is done the GPU may write the state a
        /// CPU fallback would take over, so only the driver ends the wait,
        /// with the work done or the GPU lost.
        fn finish(self: *Self, fence: gpu.Fence) gpu.Error!void {
            self.dev.wait(fence, self.options.timeout_us) catch |e| {
                if (e != error.Timeout) return e;
                self.slow += 1;
                return self.dev.wait(fence, std.math.maxInt(u64));
            };
        }

        fn diagnoseFailed(self: *Self, log: *const fn (what: []const u8) void, c: *Cache, e: gpu.Error, what: []const u8) Error {
            var buf: [320]u8 = undefined;
            log(std.fmt.bufPrint(&buf, "lfm3-any: FAILED ({s}): {s}", .{ @errorName(e), what["lfm3-any: ".len..] }) catch what);
            return self.failed(c, e);
        }

        /// Dispatch `i` of the call in `l` as diagnose mode's line.
        fn describe(self: *const Self, l: *const List, i: usize, count: usize, buf: []u8) []const u8 {
            const d = l.work.dispatches[i];
            const w = l.work.descs[i];
            var at: usize = 0;
            const put = struct {
                fn f(b: []u8, n: *usize, comptime fmt: []const u8, args: anytype) void {
                    const s2 = std.fmt.bufPrint(b[n.*..], fmt, args) catch return;
                    n.* += s2.len;
                }
            }.f;
            put(buf, &at, "lfm3-any: dispatch {d}", .{i});
            if (w.layer) |li| {
                const kind: []const u8 = if (self.plan.layers[li].kind == .attention) "attention" else "short conv";
                put(buf, &at, ", layer {d} of {d} ({s})", .{ li, self.plan.layer_count, kind });
            } else put(buf, &at, " (no layer)", .{});
            put(buf, &at, ": {s}", .{w.kernel});
            if (w.tensor) |t| {
                const info = &self.index.tensors[t];
                put(buf, &at, ", {s}", .{info.name[0..info.name_len]});
            }
            if (w.count != 0) put(buf, &at, ", tokens {d}-{d} of {d}", .{ w.first, w.first + w.count - 1, count });
            put(buf, &at, ", groups {d}x{d}x{d}", .{ d.groups[0], d.groups[1], d.groups[2] });
            return buf[0..at];
        }

        /// The kernel whose program's code is at `code_va` (a device's
        /// fault address names it).
        pub fn kernelAt(self: *const Self, code_va: u64) []const u8 {
            const k = &self.k;
            for (k.q4k) |p| if (p) |pp| if (pp.code.gpu == code_va) return "matrix q4k";
            for (k.q6k) |p| if (p) |pp| if (pp.code.gpu == code_va) return "matrix q6k";
            const named = [_]struct { []const u8, ?Program }{
                .{ "norm+quant", k.norm_quant },      .{ "quant", k.quant },                       .{ "swiglu+quant", k.swiglu },
                .{ "residual", k.residual },          .{ "conv", k.conv },                         .{ "prepare", k.prepare },
                .{ "attention scores", k.scores_decode }, .{ "attention scores (tiles)", k.scores_prefill }, .{ "attention softmax", k.softmax },
                .{ "attention values", k.values_decode }, .{ "attention values (tiles)", k.values_prefill }, .{ "attention combine", k.combine },
                .{ "copy", k.copy },
            };
            for (named) |n| if (n[1]) |pp| if (pp.code.gpu == code_va) return n[0];
            return "?";
        }

        /// A call that did not finish: its conv state put back (the GPU may
        /// have written part of it; KV rows past the position are written
        /// again by the next call).
        fn failed(self: *Self, c: *Cache, e: gpu.Error) Error {
            self.lost += 1;
            self.last_failure = e;
            const n = c.cpu.conv.len * 4;
            @memcpy(c.conv.cpu[0..n], self.conv_snapshot.cpu[0..n]);
            self.dev.toDevice(c.conv, 0, n);
            return error.DeviceLost;
        }

        /// The most positions one attention layer reads for a call that
        /// ends at `end`.
        fn span(self: *const Self, end: usize) usize {
            var most: usize = 0;
            for (self.plan.layers[0..self.plan.layer_count]) |*l| {
                if (l.kind != .attention) continue;
                most = @max(most, if (l.sliding_window) @min(end, self.plan.sliding_window) else end);
            }
            return most;
        }

        fn layer(self: *Self, l: *List, ly: *const lfm3.Layer, c: *const Cache, n: u32) Error!void {
            const plan = self.plan;
            const h: u32 = plan.hidden_size;
            const s = &self.s;
            try self.normQuant(l, 0, ly.attn_norm, n, s.normalized);
            switch (ly.kind) {
                .short_conv => {
                    try self.linear(l, try self.matrixOf(ly.in_proj), n, s.mixed, 3 * h * 4);
                    const taps: u32 = plan.conv_kernel;
                    l.named("conv", ly.conv.index, 0, n);
                    try l.add(&self.k.conv.?, kernels.convGroups(h), &.{ s.mixed, self.weights, c.conv, s.mixer }, &.{ h, n, try self.tensorOffset(ly.conv), @as(u32, ly.slot) * (taps - 1) * h * 4 });
                    try self.quant(l, s.mixer, h, n);
                    try self.linear(l, try self.matrixOf(ly.out_proj), n, s.projected, h * 4);
                },
                .attention => try self.attention(l, ly, c, n),
            }
            try self.residual(l, ly.post_attention_norm, n);
            try self.normQuant(l, 0, ly.ffn_norm, n, s.normalized);
            const ff: u32 = plan.feed_forward_size;
            try self.linear(l, try self.matrixOf(ly.ffn_gate), n, s.ffn_gate, ff * 4);
            try self.linear(l, try self.matrixOf(ly.ffn_up), n, s.ffn_up, ff * 4);
            l.named("swiglu+quant", null, 0, n);
            try l.add(&self.k.swiglu.?, kernels.quantGroups(self.caps, .swiglu, ff, n), &.{ s.ffn_gate, s.ffn_up, s.ffn_gate, s.act_q, s.act_d, s.act_sums }, &kernels.quantParams(ff, 0, 0, 0, 0));
            try self.linear(l, try self.matrixOf(ly.ffn_down), n, s.projected, h * 4);
            try self.residual(l, ly.post_ffw_norm, n);
        }

        fn attention(self: *Self, l: *List, ly: *const lfm3.Layer, c: *const Cache, n: u32) Error!void {
            const plan = self.plan;
            const s = &self.s;
            const heads: u32 = plan.head_count;
            const kv_heads: u32 = ly.kv_head_count;
            const position: u32 = @intCast(c.cpu.position);
            try self.linear(l, try self.matrixOf(ly.attn_q), n, s.query, heads * kernels.HEAD_SIZE * 4);
            try self.linear(l, try self.matrixOf(ly.attn_k), n, s.key, kv_heads * kernels.HEAD_SIZE * 4);
            try self.linear(l, try self.matrixOf(ly.attn_v), n, s.value, kv_heads * kernels.HEAD_SIZE * 4);
            try self.linear(l, try self.matrixOf(ly.attn_gate), n, s.gate, heads * 4);
            const pp = kernels.PrepareParams{
                .heads = heads,
                .kv_heads = kv_heads,
                .epsilon = plan.rms_norm_epsilon,
                .first_position = position,
                .context = @intCast(c.cpu.context),
                .slot = ly.slot,
                .max_kv_heads = plan.max_kv_head_count,
                .query_norm = try self.tensorOffset(ly.attn_q_norm),
                .key_norm = try self.tensorOffset(ly.attn_k_norm),
            };
            const rope = if (ly.sliding_window) s.rope_swa else s.rope_full;
            l.named("prepare", null, 0, n);
            try l.add(&self.k.prepare.?, kernels.prepareGroups(heads, kv_heads, n), &.{ s.query, s.key, s.value, self.weights, self.weights, rope, c.kv }, &pp.words());
            // split by keys, in launches of attention_tokens tokens
            const at = @min(self.options.attention_tokens, self.options.max_batch);
            var t0: u32 = 0;
            while (t0 < n) : (t0 += at) {
                const tokens = @min(at, n - t0);
                const ap = kernels.AttnParams{
                    .heads = heads,
                    .kv_heads = kv_heads,
                    .first_position = position + t0,
                    .tokens = tokens,
                    .window = if (ly.sliding_window) plan.sliding_window else 0,
                    .context = @intCast(c.cpu.context),
                    .slot = ly.slot,
                    .max_kv_heads = plan.max_kv_head_count,
                    .span = self.options.max_span,
                    .chunks = self.chunks(),
                    .query = t0 * heads * kernels.HEAD_SIZE * 4,
                    .gate = t0 * heads * 4,
                    .out = t0 * heads * kernels.HEAD_SIZE * 4,
                };
                const words = ap.words();
                const prefill = tokens > 1 and self.k.scores_prefill != null;
                const hg = self.heads_per_group;
                const tt: u32 = if (prefill) self.tokens_per_group else 1;
                const scores = if (prefill) &self.k.scores_prefill.? else &self.k.scores_decode.?;
                const values = if (prefill) &self.k.values_prefill.? else &self.k.values_decode.?;
                l.named("attention scores", null, t0, tokens);
                try l.add(scores, kernels.scoreGroups(ap, hg, tt), &.{ s.query, c.kv, s.scores }, &words);
                l.named("attention softmax", null, t0, tokens);
                try l.add(&self.k.softmax.?, kernels.softmaxGroups(ap), &.{s.scores}, &words);
                l.named("attention values", null, t0, tokens);
                try l.add(values, kernels.valueGroups(ap, hg, tt), &.{ c.kv, s.scores, s.partial }, &words);
                l.named("attention combine", null, t0, tokens);
                try l.add(&self.k.combine.?, kernels.combineGroups(ap), &.{ s.partial, s.gate, s.mixer }, &words);
            }
            try self.quant(l, s.mixer, @intCast(plan.queryWidth()), n);
            try self.linear(l, try self.matrixOf(ly.attn_output), n, s.projected, plan.hidden_size * 4);
        }

        /// RMSNorm `n` rows of hidden width (from byte `x_off` of hidden)
        /// into `normalized`, and quantize them into the activation arrays.
        fn normQuant(self: *Self, l: *List, x_off: u32, norm: lfm3.TensorRef, n: u32, normalized: Buffer) Error!void {
            const h = self.plan.hidden_size;
            const s = &self.s;
            l.named("norm+quant", norm.index, x_off / (h * 4), n);
            try l.add(&self.k.norm_quant.?, kernels.quantGroups(self.caps, .norm, h, n), &.{ s.hidden, self.weights, normalized, s.act_q, s.act_d, s.act_sums }, &kernels.quantParams(h, self.plan.rms_norm_epsilon, x_off, try self.tensorOffset(norm), 0));
        }

        /// `n` rows of `width` in `x` into the activation arrays.
        fn quant(self: *Self, l: *List, x: Buffer, width: u32, n: u32) Error!void {
            const s = &self.s;
            l.named("quant", null, 0, n);
            try l.add(&self.k.quant.?, kernels.quantGroups(self.caps, .plain, width, n), &.{ x, x, x, s.act_q, s.act_d, s.act_sums }, &kernels.quantParams(width, 0, 0, 0, 0));
        }

        /// hidden += post_norm(projected) (sandwich norms) or + projected.
        fn residual(self: *Self, l: *List, norm: lfm3.TensorRef, n: u32) Error!void {
            const h = self.plan.hidden_size;
            const w = if (self.plan.sandwich_norms) try self.tensorOffset(norm) else 0;
            const s = &self.s;
            l.named("residual", if (self.plan.sandwich_norms) norm.index else null, 0, n);
            try l.add(&self.k.residual.?, .{ 1, n, 1 }, &.{ s.hidden, s.projected, self.weights }, &.{ h, @as(u32, @bitCast(self.plan.rms_norm_epsilon)), w });
        }

        /// out[t][row] = W[row] . activations[t]: passes of up to 8 tokens,
        /// each by the variant for its tokens.
        fn linear(self: *Self, l: *List, m: MatrixInfo, n: u32, out: Buffer, out_stride: u32) Error!void {
            const s = &self.s;
            const k: u32 = m.blocks * @as(u32, quantized.QK_K);
            var first: u32 = 0;
            while (first < n) {
                const tokens = @min(n - first, MATRIX_VARIANTS);
                const prog = if (m.q4) &self.k.q4k[tokens - 1] else &self.k.q6k[tokens - 1];
                const p = kernels.MatrixParams{
                    .row_bytes = m.row_bytes,
                    .blocks = m.blocks,
                    .rows = m.rows,
                    .out_stride = out_stride,
                    .weights = m.offset,
                    .act_q = first * k,
                    .act_d = first * m.blocks * 4,
                    .act_sums = first * m.blocks * 32,
                    .out = first * out_stride,
                };
                const program = if (prog.*) |*pp| pp else return error.Unsupported;
                l.named(if (m.q4) "matrix q4k" else "matrix q6k", m.tensor, first, tokens);
                try l.add(program, kernels.matrixGroups(self.caps, m.rows), &.{ self.weights, s.act_q, s.act_d, s.act_sums, out }, &p.words(.q4_k));
                first += tokens;
            }
        }

        fn tensorOf(self: *const Self, ref: lfm3.TensorRef) Error!*const gguf.TensorInfo {
            if (!ref.present() or ref.index >= self.index.tensor_count) return error.InvalidPlan;
            return &self.index.tensors[ref.index];
        }

        fn tensorOffset(self: *const Self, ref: lfm3.TensorRef) Error!u32 {
            return @intCast((try self.tensorOf(ref)).file_offset);
        }

        /// A matrix of the model file, as its kernel reads it.
        fn matrixOf(self: *const Self, ref: lfm3.TensorRef) Error!MatrixInfo {
            const t = try self.tensorOf(ref);
            if (t.dimension_count != 2 or (t.ggml_type != 12 and t.ggml_type != 14)) return error.Unsupported;
            const blocks: u32 = @intCast(t.dimensions[0] / quantized.QK_K);
            return .{
                .offset = @intCast(t.file_offset),
                .row_bytes = @intCast(blocks * blockBytes(t.ggml_type)),
                .rows = @intCast(t.dimensions[1]),
                .blocks = blocks,
                .q4 = t.ggml_type == 12,
                .tensor = ref.index,
            };
        }

        /// What the kernels and the device can run.
        fn supported(plan: *const lfm3.Plan, index: *const gguf.Index(tensor_capacity), options: Options, caps: Caps) Error!void {
            const h = plan.hidden_size;
            if (caps.subgroup < 8 or !std.math.isPowerOfTwo(caps.subgroup) or caps.max_group < 64) return error.Unsupported;
            const row_threads = kernels.rowThreads(caps);
            if (!std.math.isPowerOfTwo(row_threads)) return error.Unsupported;
            if (h == 0 or h % quantized.QK_K != 0 or h % row_threads != 0) return error.Unsupported;
            if (plan.feed_forward_size == 0 or plan.feed_forward_size % quantized.QK_K != 0) return error.Unsupported;
            if (plan.queryWidth() % quantized.QK_K != 0) return error.Unsupported;
            if (plan.vocabulary_size == 0 or !plan.output.present()) return error.Unsupported;
            if (options.max_batch == 0 or options.max_batch > 64 or options.attention_tokens == 0 or options.max_run == 0) return error.Unsupported;
            if (options.max_span < kernels.VALUE_CHUNK or options.max_span % kernels.VALUE_CHUNK != 0) return error.Unsupported;
            if (plan.layer_count == 0) return error.Unsupported;
            if (plan.conv_layer_count > 0 and (plan.conv_kernel < kernels.MIN_TAPS or plan.conv_kernel > kernels.MAX_TAPS)) return error.Unsupported;
            if (plan.attention_layer_count > 0) {
                if (plan.head_size != kernels.HEAD_SIZE or plan.head_count == 0 or plan.max_kv_head_count == 0) return error.Unsupported;
                const kv = attentionGroupSize(plan);
                if (kv == 0) return error.Unsupported;
                const group = plan.head_count / kv;
                if (!std.math.isPowerOfTwo(group)) return error.Unsupported;
                for (plan.layers[0..plan.layer_count]) |*l| {
                    if (l.kind == .attention and l.kv_head_count != kv) return error.Unsupported;
                }
            }
            for (index.tensors[0..index.tensor_count]) |*t| {
                // (GPU loads of 16-byte rows and f32 vectors)
                if (t.file_offset % 16 != 0) return error.Unsupported;
            }
            if (!plan.token_embedding.present()) return error.InvalidPlan;
            const emb = &index.tensors[plan.token_embedding.index];
            if (emb.ggml_type != 12 and emb.ggml_type != 14) return error.Unsupported;
            var it = Matrices{ .plan = plan };
            while (it.next()) |ref| {
                const t = &index.tensors[ref.index];
                if (t.dimension_count != 2 or (t.ggml_type != 12 and t.ggml_type != 14)) return error.Unsupported;
                if (t.dimensions[0] == 0 or t.dimensions[0] % quantized.QK_K != 0 or t.dimensions[1] == 0) return error.Unsupported;
            }
            if (launchesFor(plan, options.max_batch, @min(options.attention_tokens, options.max_batch)) > MAX_DISPATCHES) return error.Unsupported;
        }
    };
}

/// The KV head count of the attention layers (they all have the same).
fn attentionGroupSize(plan: *const lfm3.Plan) u32 {
    for (plan.layers[0..plan.layer_count]) |*l| {
        if (l.kind == .attention) return l.kv_head_count;
    }
    return 0;
}

const Formats = struct { q4: bool = false, q6: bool = false };

fn formatsUsed(plan: *const lfm3.Plan, index: anytype) Formats {
    var f = Formats{};
    var it = Matrices{ .plan = plan };
    while (it.next()) |ref| {
        switch (index.tensors[ref.index].ggml_type) {
            12 => f.q4 = true,
            14 => f.q6 = true,
            else => {},
        }
    }
    return f;
}

/// Every matrix the forward pass multiplies.
const Matrices = struct {
    plan: *const lfm3.Plan,
    layer: usize = 0,
    slot: usize = 0,

    fn next(self: *Matrices) ?lfm3.TensorRef {
        while (self.layer < self.plan.layer_count) {
            const l = &self.plan.layers[self.layer];
            const refs = [_]lfm3.TensorRef{ l.in_proj, l.out_proj, l.attn_q, l.attn_k, l.attn_v, l.attn_gate, l.attn_output, l.ffn_gate, l.ffn_up, l.ffn_down };
            while (self.slot < refs.len) {
                const ref = refs[self.slot];
                self.slot += 1;
                if (ref.present()) return ref;
            }
            self.layer += 1;
            self.slot = 0;
        }
        if (self.layer == self.plan.layer_count) {
            self.layer += 1;
            if (self.plan.output.present()) return self.plan.output;
        }
        return null;
    }
};

/// Dispatches one call of `tokens` tokens sends at most.
pub fn launchesFor(plan: *const lfm3.Plan, tokens: u32, attention_tokens: u32) u32 {
    const passes = (tokens + MATRIX_VARIANTS - 1) / MATRIX_VARIANTS;
    const attn = (tokens + attention_tokens - 1) / attention_tokens;
    var n: u32 = 4; // the inputs' and the KV rows' copies, the output norm, the logits
    for (plan.layers[0..plan.layer_count]) |*l| {
        // two norms, two residuals, SwiGLU; the FFN's three matrices
        n += 5 + 3 * passes;
        n += switch (l.kind) {
            .short_conv => 2 + 2 * passes,
            .attention => 2 + 4 * attn + 5 * passes,
        };
    }
    return n;
}

fn blockBytes(ggml_type: u32) usize {
    return if (ggml_type == 12) quantized.Q4_K_BLOCK_BYTES else quantized.Q6_K_BLOCK_BYTES;
}

fn argmax(v: []const f32) usize {
    var best: usize = 0;
    for (v, 0..) |x, i| {
        if (x > v[best]) best = i;
    }
    return best;
}
