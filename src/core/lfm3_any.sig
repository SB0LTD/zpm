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
    /// Every fsqrt (and fdiv) expanded in KIR (kir.expand) before the
    /// backend sees it: MUFU only as the seed of an expansion proved exact
    /// for any seed within its bound. kir_sm120's own fsqrt is ptxas's
    /// sqrt.rn (MUFU.RSQ and one FFMA correction), checked only on
    /// sm120_emu, whose MUFU is exact: on hardware a wrong step would show
    /// only there. For checking a GPU against its emulator; slower.
    exact_sqrt: bool = false,
    /// The matrices' layout for one-token passes (decode): 0, each shape's
    /// fastest on this GPU, timed at init with the model's own weights (the
    /// target's default where the device keeps no timestamps); 1, 2 or 4,
    /// that many lanes a thread for every shape. Every layout is the CPU's
    /// bits (lfm3_kir): only the time differs.
    matrix_lanes: u32 = 0,
};

pub const MATRIX_VARIANTS = kernels.MAX_TOKENS;
/// The layouts a one-token matrix pass is tried in: lanes a thread (8 / lanes
/// threads a row). Few long rows (ffn_down: 2048 rows of 30 blocks) want
/// many threads a row; many short ones, fewer.
pub const LAYOUT_LANES = [_]u32{ 1, 2, 4 };
/// A matrix shape of the model and the layout its one-token passes take,
/// with what each layout took when timed (ns; 0: not timed).
pub const Tuned = struct { q4: bool, rows: u32, blocks: u32, lanes: u32, ns: [LAYOUT_LANES.len]u64 = @splat(0) };
pub const MAX_TUNED = 32;
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
    /// One-token passes in each of LAYOUT_LANES (null where it is the
    /// target's default, which q4k[0] and q6k[0] are, or does not build).
    q4k1: [LAYOUT_LANES.len]?Program = @splat(null),
    q6k1: [LAYOUT_LANES.len]?Program = @splat(null),
    norm_quant: ?Program = null,
    quant: ?Program = null,
    swiglu: ?Program = null,
    residual: ?Program = null,
    /// residual and the norm+quant after it in one dispatch (null: apart)
    residual_norm: ?Program = null,
    conv: ?Program = null,
    prepare: ?Program = null,
    scores_decode: ?Program = null,
    scores_prefill: ?Program = null,
    softmax: ?Program = null,
    values_decode: ?Program = null,
    values_prefill: ?Program = null,
    combine: ?Program = null,
    copy: ?Program = null,
    /// the memory's read speed (readSpeed; null: not built)
    read: ?Program = null,
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
pub const List = struct {
    work: *Work,
    n: usize = 0,
    nb: usize = 0,
    nw: usize = 0,
    /// What the next dispatches are (set before they are added).
    what: Desc = .{},

    pub fn add(l: *List, prog: *const Program, groups: [3]u32, buffers: []const Buffer, words: []const u32) Error!void {
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
    pub fn named(l: *List, kernel: []const u8, tensor: ?u16, first: u32, count: u32) void {
        l.what.kernel = kernel;
        l.what.tensor = tensor;
        l.what.first = first;
        l.what.count = count;
    }

    pub fn slice(l: *const List) []const gpu.Dispatch {
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
        /// Each residual and the norm after it in one dispatch where the
        /// fused kernel built (locate turns it off: it checks them apart).
        fuse: bool = true,
        /// Each matrix shape's layout for one-token passes (tuneMatrices).
        tuned: [MAX_TUNED]Tuned = undefined,
        n_tuned: usize = 0,

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
            self.tuneMatrices();
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
            for (&k.q4k1) |*p| self.unload(p);
            for (&k.q6k1) |*p| self.unload(p);
            const progs = [_]*?Program{ &k.norm_quant, &k.quant, &k.swiglu, &k.residual, &k.residual_norm, &k.conv, &k.prepare, &k.scores_decode, &k.scores_prefill, &k.softmax, &k.values_decode, &k.values_prefill, &k.combine, &k.copy, &k.read };
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
            if (self.options.exact_sqrt) {
                // (the expansions' KIR in the compile memory's first part)
                const n = 2 * k.insts.len;
                const store = kir.Storage{ .insts = cw.take(kir.Inst, n) orelse return error.CompileFailed, .tys = cw.take(kir.Ty, n) orelse return error.CompileFailed };
                k = kir.expand(&k, self.caps, store) catch |e| {
                    self.compile_error = e;
                    return error.CompileFailed;
                };
            }
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
            // (the other layouts of one-token passes: one that does not
            // build for this GPU is left out)
            const default_lanes = kernels.Layout.of(caps).lanes;
            for (LAYOUT_LANES, 0..) |lanes, li| {
                if (lanes == default_lanes) continue;
                const lay = kernels.Layout{ .lanes = lanes };
                if (used.q4) self.build(&self.k.q4k1[li], kernels.matrixWith(s, caps, lay, .q4_k, 1)) catch {
                    self.k.q4k1[li] = null;
                };
                if (used.q6) self.build(&self.k.q6k1[li], kernels.matrixWith(s, caps, lay, .q6_k, 1)) catch {
                    self.k.q6k1[li] = null;
                };
            }
            self.compile_error = null;
            try self.build(&self.k.norm_quant, kernels.quant(s, caps, .norm));
            try self.build(&self.k.quant, kernels.quant(s, caps, .plain));
            try self.build(&self.k.swiglu, kernels.quant(s, caps, .swiglu));
            try self.build(&self.k.residual, kernels.residual(s, caps, plan.sandwich_norms));
            // (fused where it builds; apart otherwise, the same bits)
            self.build(&self.k.residual_norm, kernels.residualNormQuant(s, caps, plan.sandwich_norms)) catch {
                self.k.residual_norm = null;
            };
            self.compile_error = null;
            try self.build(&self.k.copy, kernels.copy(s, caps));
            self.build(&self.k.read, kernels.readProbe(s, caps)) catch {
                self.k.read = null;
            };
            self.compile_error = null;
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

        /// The GPU's memory speed now, in GB/s by its own timestamps: the
        /// weights' first `bytes` (up to 64 MiB) copied to memory of the
        /// device's own, read and written (2 x bytes moved). null: it keeps
        /// no timestamps, or there is no memory for the copy. A clock or
        /// power state shows here first (legion22: matrices 3 times faster
        /// once the GPU had been busy a while). A copy that fits the GPU's
        /// last-level cache (GB206's L2: 32 MiB) measures the cache, not
        /// the memory: readSpeed is the memory's figure.
        pub fn copySpeed(self: *Self, bytes: u64) ?f64 {
            const n = @min(bytes, 64 << 20, self.weights.bytes) / 16 * 16;
            if (n < 16 or n > std.math.maxInt(u32)) return null;
            const tmp = self.dev.alloc(n, .device) catch return null;
            defer self.dev.free(tmp);
            var l = List{ .work = self.work };
            var at: u64 = 0;
            while (at < n) {
                const words: u32 = @intCast(@min((n - at) / 16, 1 << 20));
                self.copyInto(&l, self.weights, @intCast(at), tmp, @intCast(at), words) catch return null;
                at += @as(u64, words) * 16;
            }
            self.runNow(&l) catch return null;
            const ns = self.dev.lastRunNs();
            if (ns == 0) return null;
            return @as(f64, @floatFromInt(2 * n)) / @as(f64, @floatFromInt(ns));
        }

        /// The memory's read speed now, in GB/s by the GPU's timestamps: the
        /// weights' first `bytes` (all of them at most) read once, nothing
        /// written. Larger than the GPU's caches (a few hundred MiB), it is
        /// the memory's own (VRAM on a discrete GPU, the shared DRAM on a
        /// unified one). null: no read kernel, no timestamps, or no room for
        /// its 16-byte targets.
        pub fn readSpeed(self: *Self, bytes: u64) ?f64 {
            const prog = if (self.k.read) |*p| p else return null;
            const n = @min(bytes, self.weights.bytes) / 16 * 16;
            if (n < 16 or n > std.math.maxInt(u32)) return null;
            const PIECE: u64 = 16 << 20;
            const pieces = (n + PIECE - 1) / PIECE;
            if (pieces > 64) return null;
            // a 16-byte target each, so no piece waits for another
            const tmp = self.dev.alloc(pieces * 256, .device) catch return null;
            defer self.dev.free(tmp);
            var l = List{ .work = self.work };
            l.what = .{ .kernel = "read probe" };
            var at: u64 = 0;
            var i: u64 = 0;
            while (at < n) : (i += 1) {
                const words: u32 = @intCast(@min(n - at, PIECE) / 16);
                var to = tmp;
                to.gpu += i * 256;
                to.bytes = 16;
                to.cpu = &.{};
                l.add(prog, kernels.copyGroups(words), &.{ self.weights, to }, &.{ words, @intCast(at), 0x5a5a_a5a5 }) catch return null;
                at += @as(u64, words) * 16;
            }
            self.runNow(&l) catch return null;
            const ns = self.dev.lastRunNs();
            if (ns == 0) return null;
            return @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(ns));
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
            var call = try self.begin(c, input, output);
            const l = &call.list;
            const count = call.count;
            const cache = &c.cpu;
            var ns: u64 = 0;
            if (self.options.diagnose) |log| {
                for (l.slice(), 0..) |*d, i| {
                    var buf: [256]u8 = undefined;
                    const what = self.describe(l, i, count, &buf);
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
            return self.complete(c, &call, output);
        }

        /// A call made and not yet run: its dispatches, its tokens.
        const Call = struct { list: List, count: usize, kv_back: bool, conv_bytes: usize };

        /// A call's checks, uploads and dispatch list (forward's first half).
        fn begin(self: *Self, c: *Cache, input: executor.Input, output: executor.Output) Error!Call {
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
                // (the norm after the layer's last residual: the next
                // layer's, or for one row the output's, fused with it)
                const next: ?NextNorm = if (li + 1 < plan.layer_count)
                    .{ .norm = plan.layers[li + 1].attn_norm, .rows = n, .out = self.s.normalized }
                else if (output != .none and count == 1)
                    .{ .norm = plan.output_norm, .rows = 1, .out = self.out_hidden }
                else
                    null;
                try self.layer(&l, ly, c, n, li == 0 or !self.fused(), next);
            }
            l.what = .{};
            if (output != .none) {
                // the last position's output norm (and its quantization)
                if (!(count == 1 and self.fused())) try self.normQuant(&l, @intCast((count - 1) * h * 4), plan.output_norm, 1, self.out_hidden);
                if (output == .logits) try self.linear(&l, try self.matrixOf(plan.output), 1, self.out_logits, plan.vocabulary_size * 4);
            }
            self.dispatches = @intCast(l.n);
            self.total_dispatches += l.n;
            return .{ .list = l, .count = count, .kv_back = kv_back, .conv_bytes = conv_bytes };
        }

        /// A call run: its state back, the cache advanced (forward's last part).
        fn complete(self: *Self, c: *Cache, call: *const Call, output: executor.Output) ?u32 {
            const h: usize = self.plan.hidden_size;
            if (call.kv_back) c.kv_on_cpu = false;
            self.dev.fromDevice(c.conv, 0, call.conv_bytes);
            c.cpu.position += call.count;
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
                .{ "residual", k.residual },          .{ "residual+norm+quant", k.residual_norm }, .{ "conv", k.conv },                         .{ "prepare", k.prepare },
                .{ "attention scores", k.scores_decode }, .{ "attention scores (tiles)", k.scores_prefill }, .{ "attention softmax", k.softmax },
                .{ "attention values", k.values_decode }, .{ "attention values (tiles)", k.values_prefill }, .{ "attention combine", k.combine },
                .{ "copy", k.copy },                  .{ "read probe", k.read },
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

        // ── Locating a difference from the CPU (diagnose boots) ────────────

        /// What locate found.
        pub const Where = struct {
            /// The first layer whose output differs from the CPU's (null:
            /// every layer's agrees; the output norm or the logits differ).
            layer: ?u8 = null,
            /// The dispatch (in that layer's run) whose output is not what
            /// the CPU computes from that dispatch's own inputs, and its
            /// kernel ("?" when every dispatch of the layer reproduces: then
            /// the difference came in through an input).
            dispatch: u32 = 0,
            kernel: []const u8 = "?",
            tensor: ?u16 = null,
            /// The buffer compared, the first element that differs, the
            /// largest difference, and it relative to the largest value.
            buffer: []const u8 = "",
            index: usize = 0,
            max_abs: f32 = 0,
            relative: f32 = 0,
        };

        /// The CPU executor locate compares with: the model as the CPU
        /// reads it, its packed weights (empty: the row kernels), a
        /// Workspace, and KV and conv storage for the call's context.
        pub fn CpuReference(comptime limits: executor.Limits) type {
            return struct {
                source: gguf.Source,
                weights: *const executor.PackedWeights(tensor_capacity),
                work: *executor.Workspace(limits),
                kv: []u16,
                conv: []f32,
                parallel: executor.Parallel = .{},
            };
        }

        /// Find where the GPU and the CPU executor part, for `input` run from
        /// position 0 of a fresh cache of `context` positions on both:
        ///
        /// 1. the whole model; equal hidden rows and logits: null;
        /// 2. the first layer whose hidden rows differ, by bisecting the
        ///    number of layers (each run from a fresh cache on both sides);
        /// 3. that layer's buffers against the CPU Workspace's (logged);
        /// 4. that layer run again one dispatch at a time, each dispatch's
        ///    output checked against what the CPU computes from its own
        ///    inputs (read back before it ran): the first that differs is
        ///    the kernel.
        ///
        /// "Differs": a difference larger than `tolerance` times the
        /// largest value compared (0: any bit). Every comparison is logged.
        /// For diagnose boots: slow (several forward passes on both sides);
        /// buffers without a CPU view (VRAM) are read back through the copy
        /// kernel into `.host` memory. The backend's caches are untouched.
        pub fn locate(self: *Self, comptime limits: executor.Limits, cpu: CpuReference(limits), input: executor.Input, context: u32, tolerance: f32, log: *const fn (what: []const u8) void) Error!?Where {
            const full = self.plan;
            defer self.plan = full;
            // (its runs are not diagnose mode's: their lines would drown its own)
            const diagnose = self.options.diagnose;
            self.options.diagnose = null;
            defer self.options.diagnose = diagnose;
            // (each dispatch checked against its CPU step: residual and norm apart)
            const fuse = self.fuse;
            self.fuse = false;
            defer self.fuse = fuse;
            var plan: lfm3.Plan = undefined;
            const n = full.layer_count;
            var line: [320]u8 = undefined;
            // 1. the whole model
            truncate(&plan, full, n);
            self.plan = &plan;
            const whole = try self.compareRun(limits, cpu, input, context, .logits, tolerance, log, n);
            if (!whole.hidden and !whole.output) {
                log("lfm3-any locate: the GPU's hidden rows and logits are the CPU's");
                return null;
            }
            if (!whole.hidden) {
                log(std.fmt.bufPrint(&line, "lfm3-any locate: every layer agrees; the {s} differs", .{whole.where.buffer}) catch "lfm3-any locate: the output differs");
                return whole.where;
            }
            // 2. bisect: differs(hi) and not differs(lo) (no layers: the CPU's rows)
            var lo: u8 = 0;
            var hi: u8 = n;
            while (hi - lo > 1) {
                const mid = lo + (hi - lo) / 2;
                truncate(&plan, full, mid);
                const r = try self.compareRun(limits, cpu, input, context, .none, tolerance, log, mid);
                if (r.hidden) hi = mid else lo = mid;
            }
            const li = hi - 1;
            log(std.fmt.bufPrint(&line, "lfm3-any locate: the first layer that differs is layer {d} of {d} ({s})", .{ li, n, if (full.layers[li].kind == .attention) "attention" else "short conv" }) catch "lfm3-any locate: a layer differs");
            // 3. its buffers against the Workspace's (both runs of hi layers)
            truncate(&plan, full, hi);
            _ = try self.compareRun(limits, cpu, input, context, .none, tolerance, log, hi);
            try self.compareWorkspace(limits, cpu, &full.layers[li], li, input, log);
            // 4. one dispatch at a time
            var where = try self.verifyLayer(input, context, li, tolerance, log);
            where.layer = li;
            return where;
        }

        fn truncate(plan: *lfm3.Plan, full: *const lfm3.Plan, layers: u8) void {
            plan.* = full.*;
            plan.layer_count = layers;
            plan.conv_layer_count = 0;
            plan.attention_layer_count = 0;
            for (plan.layers[0..layers]) |l| {
                if (l.kind == .attention) plan.attention_layer_count += 1 else plan.conv_layer_count += 1;
            }
        }

        const RunDiff = struct { hidden: bool, output: bool, where: Where = .{} };

        /// The CPU and the GPU on self.plan (truncated) from fresh caches;
        /// their hidden rows (and with `output`, the output norm's row and
        /// the logits) compared.
        fn compareRun(self: *Self, comptime limits: executor.Limits, cpu: CpuReference(limits), input: executor.Input, context: u32, output: executor.Output, tolerance: f32, log: *const fn (what: []const u8) void, layers: u8) Error!RunDiff {
            const plan = self.plan;
            const h: usize = plan.hidden_size;
            const count: usize = switch (input) {
                .tokens => |t| t.len,
                .embeddings => |e| e.len / h,
            };
            // the CPU
            const kv_n = if (plan.attention_layer_count > 0) try executor.requiredKvElements(plan, context) else 0;
            const conv_n = try executor.requiredConvElements(plan);
            if (cpu.kv.len < kv_n or cpu.conv.len < conv_n) return error.ContextCapacity;
            @memset(cpu.kv[0..kv_n], 0);
            @memset(cpu.conv[0..conv_n], 0);
            var cc = executor.Cache{ .kv = cpu.kv[0..kv_n], .conv = cpu.conv[0..conv_n], .context = context };
            _ = try executor.forwardInput(tensor_capacity, limits, cpu.source, self.index, plan, cpu.weights, cpu.work, &cc, input, output, cpu.parallel);
            // the GPU
            var gc = try self.newCache(context);
            defer self.freeCache(&gc);
            _ = try self.forward(&gc, input, output);
            const area = try self.dev.alloc(std.mem.alignForward(u64, self.s.hidden.bytes, 16), .host);
            defer self.dev.free(area);
            var at: u64 = 0;
            const rows = try self.readBack(self.s.hidden, area, &at);
            var r = RunDiff{ .hidden = false, .output = false };
            var line: [320]u8 = undefined;
            const hd = Check.of(f32s(rows)[0 .. count * h], cpu.work.hidden[0 .. count * h]);
            r.hidden = hd.differs(tolerance);
            log(hd.say(&line, "hidden rows", layers));
            if (output == .logits) {
                const nd = Check.of(self.hidden(), cpu.work.normalized[0..h]);
                log(nd.say(&line, "output norm's row", layers));
                const ld = Check.of(self.logits(), cpu.work.logits[0..plan.vocabulary_size]);
                log(ld.say(&line, "logits", layers));
                if (nd.differs(tolerance)) {
                    r.output = true;
                    r.where = nd.where("output norm's row", "norm+quant (output)", plan.output_norm.index);
                } else if (ld.differs(tolerance)) {
                    r.output = true;
                    r.where = ld.where("logits", if (self.index.tensors[plan.output.index].ggml_type == 12) "matrix q4k" else "matrix q6k", plan.output.index);
                }
            }
            return r;
        }

        /// The layer's buffers the CPU's Workspace also holds, after a run of
        /// layers 0..li on both: logged.
        fn compareWorkspace(self: *Self, comptime limits: executor.Limits, cpu: CpuReference(limits), ly: *const lfm3.Layer, li: u8, input: executor.Input, log: *const fn (what: []const u8) void) Error!void {
            const plan = self.plan;
            const h: usize = plan.hidden_size;
            const count: usize = switch (input) {
                .tokens => |t| t.len,
                .embeddings => |e| e.len / h,
            };
            const w = cpu.work;
            const s = &self.s;
            var line: [320]u8 = undefined;
            const Pair = struct { name: []const u8, gpu: Buffer, cpu: []const f32 };
            const q = plan.queryWidth();
            const kvw = @as(usize, ly.kv_head_count) * plan.head_size;
            const ff: usize = plan.feed_forward_size;
            const conv_pairs = [_]Pair{
                .{ .name = "mixed (in_proj)", .gpu = s.mixed, .cpu = w.mixed[0 .. count * 3 * h] },
                .{ .name = "mixer (conv)", .gpu = s.mixer, .cpu = w.mixer[0 .. count * h] },
            };
            const attn_pairs = [_]Pair{
                .{ .name = "value (attn_v)", .gpu = s.value, .cpu = w.value[0 .. count * kvw] },
                .{ .name = "gate (attn_gate)", .gpu = s.gate, .cpu = w.gate[0 .. count * plan.head_count] },
                .{ .name = "query (attn_q, prepared)", .gpu = s.query, .cpu = w.query[0 .. count * q] },
                .{ .name = "mixer (attention)", .gpu = s.mixer, .cpu = w.mixer[0 .. count * q] },
            };
            const ffn_pairs = [_]Pair{
                .{ .name = "normalized (ffn_norm)", .gpu = s.normalized, .cpu = w.normalized[0 .. count * h] },
                .{ .name = "ffn_up", .gpu = s.ffn_up, .cpu = w.ffn_up[0 .. count * ff] },
            };
            const first: []const Pair = if (ly.kind == .attention) &attn_pairs else &conv_pairs;
            var most: u64 = 16;
            for ([_][]const Pair{ first, &ffn_pairs }) |pairs| for (pairs) |p| {
                most = @max(most, std.mem.alignForward(u64, p.gpu.bytes, 16));
            };
            const area = try self.dev.alloc(most, .host);
            defer self.dev.free(area);
            for ([_][]const Pair{ first, &ffn_pairs }) |pairs| for (pairs) |p| {
                var at: u64 = 0;
                const got = try self.readBack(p.gpu, area, &at);
                log(Check.of(f32s(got)[0..p.cpu.len], p.cpu).say(&line, p.name, li + 1));
            };
        }

        fn f32s(bytes: []u8) []f32 {
            return @alignCast(std.mem.bytesAsSlice(f32, bytes[0 .. bytes.len & ~@as(usize, 3)]));
        }

        /// A comparison of what the GPU wrote with what the CPU computes.
        const Check = struct {
            max_abs: f32 = 0,
            max_ref: f32 = 0,
            first: ?usize = null,
            differing: usize = 0,
            count: usize = 0,

            fn add(c: *Check, i: usize, got: f32, want: f32) void {
                c.count += 1;
                c.max_ref = @max(c.max_ref, @abs(want));
                if (@as(u32, @bitCast(got)) == @as(u32, @bitCast(want))) return;
                c.differing += 1;
                if (c.first == null) c.first = i;
                const d = @abs(got - want);
                c.max_abs = if (d != d) std.math.inf(f32) else @max(c.max_abs, d);
            }

            fn of(got: []const f32, want: []const f32) Check {
                var c = Check{};
                for (got, want, 0..) |g, w, i| c.add(i, g, w);
                return c;
            }

            fn differs(c: *const Check, tolerance: f32) bool {
                if (c.differing == 0) return false;
                return !(c.max_abs <= tolerance * @max(c.max_ref, 1e-30));
            }

            fn relative(c: *const Check) f32 {
                return c.max_abs / @max(c.max_ref, 1e-30);
            }

            fn say(c: *const Check, buf: []u8, what: []const u8, layers: u8) []const u8 {
                if (c.differing == 0) return std.fmt.bufPrint(buf, "lfm3-any locate: {d} layers: {s}: the CPU's bits ({d} values)", .{ layers, what, c.count }) catch "lfm3-any locate";
                return std.fmt.bufPrint(buf, "lfm3-any locate: {d} layers: {s}: {d} of {d} differ, the first at {d}; max |diff| {e} = {e} of the largest", .{ layers, what, c.differing, c.count, c.first.?, c.max_abs, c.relative() }) catch "lfm3-any locate";
            }

            fn where(c: *const Check, buffer: []const u8, kernel: []const u8, tensor: ?u16) Where {
                return .{ .kernel = kernel, .tensor = tensor, .buffer = buffer, .index = c.first orelse 0, .max_abs = c.max_abs, .relative = c.relative() };
            }
        };

        /// Run layers 0..li from a fresh cache, layer li a dispatch at a
        /// time: each one's output against the CPU's from its own inputs.
        fn verifyLayer(self: *Self, input: executor.Input, context: u32, li: u8, tolerance: f32, log: *const fn (what: []const u8) void) Error!Where {
            var gc = try self.newCache(context);
            defer self.freeCache(&gc);
            var call = try self.begin(&gc, input, .none);
            const l = &call.list;
            const ds = l.slice();
            const descs = self.work.descs[0..l.n];
            // the snapshot area: the most bytes any of the layer's dispatches binds
            var most: u64 = 0;
            for (ds, descs) |d, w| {
                if (w.layer != li) continue;
                most = @max(most, self.boundBytes(d));
            }
            // (in four parts: the inputs before it ran (two), the outputs read
            // back (VRAM without a CPU view), the CPU's scratch)
            const third = std.mem.alignForward(u64, @max(most, 16), 16);
            const snap = try self.dev.alloc(third * 4, .host);
            defer self.dev.free(snap);
            var line: [320]u8 = undefined;
            var i: usize = 0;
            while (i < ds.len) {
                if (descs[i].layer != li) {
                    // (the dispatches before the layer, as one run)
                    var j = i;
                    while (j < ds.len and descs[j].layer != li) j += 1;
                    if (i > 0 and descs[i - 1].layer == li) break;
                    try self.runNowSlice(ds[i..j]);
                    i = j;
                    continue;
                }
                const group: usize = if (std.mem.eql(u8, descs[i].kernel, "attention scores")) 4 else 1;
                var buf: [256]u8 = undefined;
                const what = self.describe(l, i, call.count, &buf);
                const scratch = f32s(snap.cpu[@intCast(3 * third)..][0..@intCast(third)]);
                const r = try self.checkDispatch(ds[i..][0..group], descs[i], li, snap, 2 * third, scratch);
                if (r.c.count == 0) {
                    log(std.fmt.bufPrint(&line, "lfm3-any locate: {s}: not checked", .{what["lfm3-any: ".len..]}) catch "?");
                } else {
                    var b2: [320]u8 = undefined;
                    log(std.fmt.bufPrint(&line, "{s} <- {s}", .{ r.c.say(&b2, r.buffer, li + 1), what["lfm3-any: ".len..] }) catch "?");
                }
                if (r.c.differs(tolerance)) {
                    // (attention's four kernels are checked as one: by their output)
                    const name = if (group == 4) "attention (scores, softmax, values, combine)" else descs[i].kernel;
                    var w = r.c.where(r.buffer, name, descs[i].tensor);
                    w.dispatch = @intCast(i);
                    log(std.fmt.bufPrint(&line, "lfm3-any locate: FOUND: {s} (dispatch {d}) is not what the CPU computes from its own inputs", .{ name, i }) catch "?");
                    return w;
                }
                i += group;
            }
            log("lfm3-any locate: every dispatch of the layer is the CPU's from its own inputs: the difference came in through an input");
            return .{};
        }

        /// Run `ds` now (one run) and wait.
        fn runNowSlice(self: *Self, ds: []const gpu.Dispatch) Error!void {
            if (ds.len == 0) return;
            const fence = try self.dev.run(ds);
            try self.dev.wait(fence, std.math.maxInt(u64));
        }

        /// The bytes a dispatch binds, but the model's (each from a 16-byte
        /// boundary).
        fn boundBytes(self: *const Self, d: gpu.Dispatch) u64 {
            var n: u64 = 0;
            for (d.buffers) |b| {
                if (b.gpu != self.weights.gpu) n += std.mem.alignForward(u64, b.bytes, 16);
            }
            return n;
        }

        /// A buffer's bytes as the CPU sees them now: its own view (after
        /// fromDevice), or (VRAM without one) a copy the copy kernel makes
        /// into `area`, a `.host` buffer, at `at.*` (16-byte aligned), which
        /// it advances.
        fn readBack(self: *Self, b: Buffer, area: Buffer, at: *u64) Error![]u8 {
            const n: usize = @intCast(b.bytes);
            if (b.cpu.len >= n) {
                self.dev.fromDevice(b, 0, b.bytes);
                return b.cpu[0..n];
            }
            const start = at.*;
            if (b.bytes % 16 != 0 or start % 16 != 0 or start + b.bytes > area.cpu.len or start + b.bytes > std.math.maxInt(u32)) return error.Unsupported;
            const prog = if (self.k.copy) |*p| p else return error.Unsupported;
            const total = b.bytes / 16;
            var done_words: u64 = 0;
            while (done_words < total) {
                const words: u32 = @intCast(@min(total - done_words, 1 << 20));
                const bufs = [2]Buffer{ b, area };
                const ps = [3]u32{ words, @intCast(done_words * 16), @intCast(start + done_words * 16) };
                const d = gpu.Dispatch{ .prog = prog, .groups = kernels.copyGroups(words), .buffers = &bufs, .params = &ps };
                try self.runNowSlice((&d)[0..1]);
                done_words += words;
            }
            self.dev.fromDevice(area, start, b.bytes);
            at.* = start + b.bytes;
            return area.cpu[@intCast(start)..][0..n];
        }

        const DispatchCheck = struct { c: Check = .{}, buffer: []const u8 = "" };

        /// Snapshot a binding at `at` of the snapshot buffer (then the next
        /// 16-byte boundary).
        fn keep(self: *Self, snap: Buffer, at: *u64, b: Buffer) Error![]u8 {
            const n: usize = @intCast(b.bytes);
            const start = at.*;
            if (start + b.bytes > snap.cpu.len) return error.Unsupported;
            const dst = if (b.cpu.len >= n) blk: {
                self.dev.fromDevice(b, 0, b.bytes);
                const to = snap.cpu[@intCast(start)..][0..n];
                @memcpy(to, b.cpu[0..n]);
                break :blk to;
            } else try self.readBack(b, snap, at);
            at.* = std.mem.alignForward(u64, start + b.bytes, 16);
            return dst;
        }

        fn model(self: *const Self, off: u32, len: usize) ?[]const u8 {
            if (self.file.view(off, len, 1)) |v| return v;
            if (self.weights.cpu.len >= @as(usize, off) + len) return self.weights.cpu[off..][0..len];
            return null;
        }

        fn modelF32(self: *const Self, off: u32, n: usize) ?[]const f32 {
            const b = self.model(off, n * 4) orelse return null;
            if (@intFromPtr(b.ptr) % 4 != 0) return null;
            return @alignCast(std.mem.bytesAsSlice(f32, b));
        }

        /// Run a dispatch (or attention's four) alone, its output checked
        /// against the CPU's from its inputs as they were before it ran.
        fn checkDispatch(self: *Self, ds: []const gpu.Dispatch, w: Desc, li: u8, snap: Buffer, outs: u64, scratch: []f32) Error!DispatchCheck {
            const d = ds[0];
            const k = w.kernel;
            const plan = self.plan;
            var at: u64 = 0;
            var before: [8][]u8 = undefined;
            for (d.buffers, 0..) |b, bi| before[bi] = if (b.gpu == self.weights.gpu) &.{} else try self.keep(snap, &at, b);
            // attention's group: the gate (combine's binding 1) before too
            var gate_before: []u8 = &.{};
            if (ds.len == 4) gate_before = try self.keep(snap, &at, ds[3].buffers[1]);
            try self.runNowSlice(ds);
            const last = ds[ds.len - 1];
            // (what it wrote, read back: from `outs` of the snapshot buffer)
            var oat: u64 = outs;
            var r = DispatchCheck{};
            const p = d.params;
            var y: [8192]f32 = undefined;
            if (std.mem.eql(u8, k, "norm+quant") or std.mem.eql(u8, k, "quant") or std.mem.eql(u8, k, "swiglu+quant")) {
                // rows of K: (norm) the CPU's rmsNormRow, then quantizeQ8K, against
                // the normalized rows and the activation arrays
                const width: usize = p[0];
                const tokens: usize = d.groups[1];
                const xb = f32s(before[0]);
                const ub = f32s(before[1]);
                const normalized: []u8 = if (std.mem.eql(u8, k, "norm+quant")) try self.readBack(d.buffers[2], snap, &oat) else &.{};
                const aq_out = try self.readBack(d.buffers[3], snap, &oat);
                const ad_out = try self.readBack(d.buffers[4], snap, &oat);
                const as_out = try self.readBack(d.buffers[5], snap, &oat);
                for (0..tokens) |t| {
                    const x = xb[(p[3] / 4) + t * width ..][0..width];
                    if (std.mem.eql(u8, k, "norm+quant")) {
                        const wv = self.modelF32(p[4], width) orelse return r;
                        rmsNormRow(x, wv, y[0..width], @bitCast(p[2]));
                        const got = f32s(normalized)[(p[5] / 4) + t * width ..][0..width];
                        for (got, y[0..width], 0..) |g, v, e| r.c.add(t * width + e, g, v);
                        if (r.c.differing != 0) {
                            r.buffer = "normalized rows";
                            return r;
                        }
                    } else if (std.mem.eql(u8, k, "swiglu+quant")) {
                        const u = ub[t * width ..][0..width];
                        for (y[0..width], x, u) |*o, g, uv| o.* = (g / (1.0 + @exp(-g))) * uv;
                    } else @memcpy(y[0..width], x);
                    const blocks = width / quantized.QK_K;
                    var q8: [32]quantized.Q8KBlock = undefined;
                    quantized.quantizeQ8K(y[0..width], q8[0..blocks]) catch return r;
                    for (q8[0..blocks], 0..) |blk, bi| {
                        const index = t * blocks + bi;
                        const aq = aq_out[index * 256 ..][0..256];
                        const ad: f32 = @bitCast(std.mem.readInt(u32, ad_out[index * 4 ..][0..4], .little));
                        r.c.add(index * 256, ad, blk.d);
                        for (blk.qs, 0..) |qv, e| r.c.add(index * 256 + e, @floatFromInt(@as(i8, @bitCast(aq[e]))), @floatFromInt(qv));
                        for (blk.bsums, 0..) |bs, e| r.c.add(index * 256 + e, @floatFromInt(std.mem.readInt(i16, as_out[index * 32 + 2 * e ..][0..2], .little)), @floatFromInt(bs));
                    }
                }
                r.buffer = "activations (Q8_K)";
                return r;
            }
            if (std.mem.startsWith(u8, k, "matrix")) {
                // MatrixParams: row_bytes, blocks, rows, out_stride, strides, offsets
                const q4 = std.mem.eql(u8, k, "matrix q4k");
                const blocks: usize = p[1];
                const rows: usize = p[2];
                const tokens: usize = w.count;
                const wm = self.model(p[7], rows * p[0]) orelse return r;
                const out = try self.readBack(d.buffers[4], snap, &oat);
                for (0..tokens) |t| {
                    var acts: [32]quantized.Q8KBlock = undefined;
                    for (0..blocks) |bi| {
                        const aq = before[1][p[8] + t * p[4] + bi * 256 ..][0..256];
                        @memcpy(std.mem.asBytes(&acts[bi].qs), aq);
                        acts[bi].d = @bitCast(std.mem.readInt(u32, before[2][p[9] + t * p[5] + bi * 4 ..][0..4], .little));
                        @memcpy(std.mem.asBytes(&acts[bi].bsums), before[3][p[10] + t * p[6] + bi * 32 ..][0..32]);
                    }
                    for (0..rows) |row| {
                        const wrow = wm[row * p[0] ..][0..p[0]];
                        const want = if (q4) quantized.dotQ4KQ8KTile(1, wrow, .{&acts}, blocks)[0] else quantized.dotQ6KQ8KTile(1, wrow, .{&acts}, blocks)[0];
                        const got: f32 = @bitCast(std.mem.readInt(u32, out[p[11] + t * p[3] + row * 4 ..][0..4], .little));
                        r.c.add(t * rows + row, got, want);
                    }
                }
                r.buffer = "matrix outputs";
                return r;
            }
            if (std.mem.eql(u8, k, "residual")) {
                const width: usize = p[0];
                const tokens: usize = d.groups[1];
                const rows = f32s(try self.readBack(d.buffers[0], snap, &oat));
                for (0..tokens) |t| {
                    const blk = f32s(before[1])[t * width ..][0..width];
                    @memcpy(y[0..width], blk);
                    if (plan.sandwich_norms) {
                        const wv = self.modelF32(p[2], width) orelse return r;
                        rmsNormRow(blk, wv, y[0..width], @bitCast(p[1]));
                    }
                    const hb = f32s(before[0])[t * width ..][0..width];
                    const got = rows[t * width ..][0..width];
                    for (got, hb, y[0..width], 0..) |g, hv, v, e| r.c.add(t * width + e, g, hv + v);
                }
                r.buffer = "hidden rows";
                return r;
            }
            if (std.mem.eql(u8, k, "conv")) {
                const hw: usize = p[0];
                const tokens: usize = p[1];
                const taps: usize = plan.conv_kernel;
                const tw = self.modelF32(p[2], hw * taps) orelse return r;
                const state_n = (taps - 1) * hw;
                if (state_n + tokens * hw > scratch.len) return r;
                const state = scratch[0..state_n];
                const out = scratch[state_n..][0 .. tokens * hw];
                @memcpy(state, f32s(before[2])[p[3] / 4 ..][0..state_n]);
                executor.shortConvChannels(taps, hw, tw, state, f32s(before[0])[0 .. tokens * 3 * hw], tokens, out, 0, hw);
                const got = f32s(try self.readBack(d.buffers[3], snap, &oat))[0 .. tokens * hw];
                for (got, out, 0..) |g, v, e| r.c.add(e, g, v);
                const sgot = f32s(try self.readBack(d.buffers[2], snap, &oat))[p[3] / 4 ..][0..state_n];
                for (sgot, state, 0..) |g, v, e| r.c.add(tokens * hw + e, g, v);
                r.buffer = "conv outputs and state";
                return r;
            }
            if (std.mem.eql(u8, k, "prepare")) {
                // PrepareParams: heads, kv_heads, eps, first, context, slot, max_kv, qn, kn
                const heads: usize = p[0];
                const kvh: usize = p[1];
                const hd: usize = HEAD_SIZE;
                const tokens: usize = d.groups[1];
                const ly = &plan.layers[li];
                const qn = self.modelF32(p[7], hd) orelse return r;
                const kn = self.modelF32(p[8], hd) orelse return r;
                const factors: ?[]const f32 = if (!ly.sliding_window and self.has_factors) &self.factors else null;
                const base = if (ly.sliding_window) plan.rope_frequency_base_swa else plan.rope_frequency_base;
                const kv_out = try self.readBack(d.buffers[6], snap, &oat);
                const kvc: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, kv_out[0 .. kv_out.len & ~@as(usize, 1)]));
                const q_out = f32s(try self.readBack(d.buffers[0], snap, &oat));
                for (0..tokens) |t| {
                    const pos = p[3] + t;
                    var qrow: [64 * HEAD_SIZE]f32 = undefined;
                    var krow: [16 * HEAD_SIZE]f32 = undefined;
                    if (heads * hd > qrow.len or kvh * hd > krow.len) return r;
                    @memcpy(qrow[0 .. heads * hd], f32s(before[0])[t * heads * hd ..][0 .. heads * hd]);
                    @memcpy(krow[0 .. kvh * hd], f32s(before[1])[t * kvh * hd ..][0 .. kvh * hd]);
                    for (0..heads) |hh| rmsNormRow(qrow[hh * hd ..][0..hd], qn, qrow[hh * hd ..][0..hd], @bitCast(p[2]));
                    for (0..kvh) |hh| rmsNormRow(krow[hh * hd ..][0..hd], kn, krow[hh * hd ..][0..hd], @bitCast(p[2]));
                    executor.ropeNeox(qrow[0 .. heads * hd], heads, hd, pos, base, factors);
                    executor.ropeNeox(krow[0 .. kvh * hd], kvh, hd, pos, base, factors);
                    const qgot = q_out[t * heads * hd ..][0 .. heads * hd];
                    for (qgot, qrow[0 .. heads * hd], 0..) |g, v, e| r.c.add(t * heads * hd + e, g, @floatCast(@as(f16, @floatCast(v))));
                    const vrow = f32s(before[2])[t * kvh * hd ..][0 .. kvh * hd];
                    for (0..kvh) |hh| for (0..2) |isv| {
                        const row = ((((p[5] * 2 + isv) * p[6] + hh) * p[4]) + pos) * hd;
                        for (0..hd) |e| {
                            const want: f16 = @floatCast(if (isv == 0) krow[hh * hd + e] else vrow[hh * hd + e]);
                            r.c.add(t * heads * hd + e, @floatCast(@as(f16, @bitCast(kvc[row + e]))), @floatCast(want));
                        }
                    };
                }
                r.buffer = "prepared queries and KV rows";
                return r;
            }
            if (ds.len == 4) {
                // attention: AttnParams words; the CPU's AttentionTask on the
                // prepared queries and the KV cache as they were
                const heads: usize = p[0];
                const first: usize = p[2];
                const tokens: usize = p[3];
                const window: u32 = p[4];
                const context: usize = p[5];
                const slot: usize = p[6];
                const max_kv: usize = p[7];
                const group: usize = @as(usize, 1) << @intCast(p[10]);
                const hd: usize = HEAD_SIZE;
                const scale: f32 = @bitCast(p[11]);
                const qb = f32s(before[0]);
                const kvc: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, before[1][0 .. before[1].len & ~@as(usize, 1)]));
                const gb = f32s(gate_before);
                const outv = f32s(try self.readBack(last.buffers[2], snap, &oat));
                var scores: [8192]f32 = undefined;
                for (0..tokens) |t| for (0..heads) |hh| {
                    const pos = first + t;
                    const visible = lfm3.firstVisiblePosition(window != 0, window, pos);
                    const kh = hh / group;
                    const query = qb[(p[12] / 4) + (t * heads + hh) * hd ..][0..hd];
                    const kblock = ((slot * 2) * max_kv + kh) * context * hd;
                    const vblock = ((slot * 2 + 1) * max_kv + kh) * context * hd;
                    var maximum: f32 = -std.math.inf(f32);
                    if (pos + 1 - visible > scores.len) return r;
                    for (visible..pos + 1) |kp| {
                        var lanes: [8]f32 = @splat(0);
                        for (0..hd / 8) |ii| for (0..8) |ln| {
                            lanes[ln] += query[8 * ii + ln] * @as(f32, @floatCast(@as(f16, @bitCast(kvc[kblock + kp * hd + 8 * ii + ln]))));
                        };
                        var sum = lanes[0];
                        for (1..8) |ln| sum += lanes[ln];
                        scores[kp - visible] = sum * scale;
                        maximum = @max(maximum, scores[kp - visible]);
                    }
                    const length = pos + 1 - visible;
                    var total: f64 = 0;
                    for (scores[0..length]) |*sc| {
                        sc.* = @exp(sc.* - maximum);
                        total += sc.*;
                    }
                    const inverse: f32 = @floatCast(1.0 / total);
                    var acc: [HEAD_SIZE]f32 = @splat(0);
                    for (scores[0..length], visible..) |sc, kp| {
                        const wgt: f32 = @floatCast(@as(f16, @floatCast(sc * inverse)));
                        for (&acc, 0..) |*a, e| a.* += wgt * @as(f32, @floatCast(@as(f16, @bitCast(kvc[vblock + kp * hd + e]))));
                    }
                    const g = 1.0 / (1.0 + @exp(-gb[(p[13] / 4) + t * heads + hh]));
                    const got = outv[(p[14] / 4) + (t * heads + hh) * hd ..][0..hd];
                    for (got, acc, 0..) |gv, a, e| r.c.add((t * heads + hh) * hd + e, gv, a * g);
                };
                r.buffer = "attention outputs";
                return r;
            }
            return r;
        }

        /// The norm a layer's last residual is fused with.
        const NextNorm = struct { norm: lfm3.TensorRef, rows: u32, out: Buffer };

        fn fused(self: *const Self) bool {
            return self.fuse and self.k.residual_norm != null;
        }

        /// One layer: its attention norm first when `first` (else the
        /// layer before fused it with its last residual); its last residual
        /// fused with `next` when there is one and the fused kernel is.
        fn layer(self: *Self, l: *List, ly: *const lfm3.Layer, c: *const Cache, n: u32, first: bool, next: ?NextNorm) Error!void {
            const plan = self.plan;
            const h: u32 = plan.hidden_size;
            const s = &self.s;
            if (first) try self.normQuant(l, 0, ly.attn_norm, n, s.normalized);
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
            try self.residualNorm(l, ly.post_attention_norm, ly.ffn_norm, n, s.normalized);
            const ff: u32 = plan.feed_forward_size;
            try self.linear(l, try self.matrixOf(ly.ffn_gate), n, s.ffn_gate, ff * 4);
            try self.linear(l, try self.matrixOf(ly.ffn_up), n, s.ffn_up, ff * 4);
            l.named("swiglu+quant", null, 0, n);
            try l.add(&self.k.swiglu.?, kernels.quantGroups(self.caps, .swiglu, ff, n), &.{ s.ffn_gate, s.ffn_up, s.ffn_gate, s.act_q, s.act_d, s.act_sums }, &kernels.quantParams(ff, 0, 0, 0, 0));
            try self.linear(l, try self.matrixOf(ly.ffn_down), n, s.projected, h * 4);
            if (next) |nx| {
                if (self.fused() and nx.rows == n) {
                    try self.residualNorm(l, ly.post_ffw_norm, nx.norm, n, nx.out);
                    return;
                }
            }
            try self.residual(l, ly.post_ffw_norm, n);
        }

        /// residual(`post`), then normQuant(`norm`) of the same rows into
        /// `normalized`: one dispatch where the fused kernel is.
        fn residualNorm(self: *Self, l: *List, post: lfm3.TensorRef, norm: lfm3.TensorRef, n: u32, normalized: Buffer) Error!void {
            if (!self.fused()) {
                try self.residual(l, post, n);
                return self.normQuant(l, 0, norm, n, normalized);
            }
            const h = self.plan.hidden_size;
            const s = &self.s;
            const w = if (self.plan.sandwich_norms) try self.tensorOffset(post) else 0;
            l.named("residual+norm+quant", norm.index, 0, n);
            try l.add(&self.k.residual_norm.?, .{ 1, n, 1 }, &.{ s.hidden, s.projected, self.weights, normalized, s.act_q, s.act_d, s.act_sums }, &kernels.ResidualNormParams.words(h, self.plan.rms_norm_epsilon, 0, try self.tensorOffset(norm), 0, w));
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
                var program: *const Program = if (prog.*) |*pp| pp else return error.Unsupported;
                var groups = kernels.matrixGroups(self.caps, m.rows);
                if (tokens == 1) {
                    const lanes = self.lanesOf(m);
                    if (self.matrixProgram(m.q4, lanes)) |alt| {
                        program = alt;
                        groups = kernels.matrixGroupsWith(.{ .lanes = lanes }, m.rows);
                    }
                }
                l.named(if (m.q4) "matrix q4k" else "matrix q6k", m.tensor, first, tokens);
                try l.add(program, groups, &.{ self.weights, s.act_q, s.act_d, s.act_sums, out }, &p.words(.q4_k));
                first += tokens;
            }
        }

        // ── The matrices' layouts (adaptive) ──

        /// Each matrix shape's layouts and their times (for the log).
        pub fn tunings(self: *const Self) []const Tuned {
            return self.tuned[0..self.n_tuned];
        }

        /// The one-token program of `lanes` (the default's own, or an
        /// alternate's); null when it was not built.
        fn matrixProgram(self: *Self, q4: bool, lanes: u32) ?*const Program {
            if (lanes == kernels.Layout.of(self.caps).lanes) {
                const p = if (q4) &self.k.q4k[0] else &self.k.q6k[0];
                return if (p.*) |*pp| pp else null;
            }
            for (LAYOUT_LANES, 0..) |x, li| if (x == lanes) {
                const p = if (q4) &self.k.q4k1[li] else &self.k.q6k1[li];
                return if (p.*) |*pp| pp else null;
            };
            return null;
        }

        /// The layout a one-token pass over `m` takes.
        fn lanesOf(self: *const Self, m: MatrixInfo) u32 {
            for (self.tuned[0..self.n_tuned]) |t| {
                if (t.q4 == m.q4 and t.rows == m.rows and t.blocks == m.blocks) return t.lanes;
            }
            return kernels.Layout.of(self.caps).lanes;
        }

        /// Every matrix shape of the model file, its one-token pass timed
        /// in each layout on the model's own weights (the best of two runs
        /// each, the device's timestamps), the fastest kept. With
        /// options.matrix_lanes, that layout everywhere; where the device
        /// keeps no timestamps, the default. Only time differs: a failure
        /// here leaves the default.
        fn tuneMatrices(self: *Self) void {
            const default_lanes = kernels.Layout.of(self.caps).lanes;
            for (self.index.tensors[0..self.index.tensor_count], 0..) |*t, ti| {
                if (t.dimension_count != 2 or (t.ggml_type != 12 and t.ggml_type != 14)) continue;
                const blocks: u32 = @intCast(t.dimensions[0] / quantized.QK_K);
                const m = MatrixInfo{
                    .offset = @intCast(t.file_offset),
                    .row_bytes = @intCast(blocks * blockBytes(t.ggml_type)),
                    .rows = @intCast(t.dimensions[1]),
                    .blocks = blocks,
                    .q4 = t.ggml_type == 12,
                    .tensor = @intCast(ti),
                };
                var seen = false;
                for (self.tuned[0..self.n_tuned]) |x| {
                    if (x.q4 == m.q4 and x.rows == m.rows and x.blocks == m.blocks) seen = true;
                }
                if (seen) continue;
                if (self.n_tuned == MAX_TUNED) return;
                var tu = Tuned{ .q4 = m.q4, .rows = m.rows, .blocks = m.blocks, .lanes = default_lanes };
                if (self.options.matrix_lanes != 0) {
                    if (self.matrixProgram(m.q4, self.options.matrix_lanes) != null) tu.lanes = self.options.matrix_lanes;
                } else {
                    var best: u64 = 0;
                    for (LAYOUT_LANES, 0..) |lanes, li| {
                        const ns = self.timeMatrix(m, lanes) orelse continue;
                        tu.ns[li] = ns;
                        if (best == 0 or ns < best) {
                            best = ns;
                            tu.lanes = lanes;
                        }
                    }
                }
                self.tuned[self.n_tuned] = tu;
                self.n_tuned += 1;
            }
        }

        /// One one-token pass over `m` in `lanes`: the device's time (ns,
        /// the best of two), null when it cannot say.
        fn timeMatrix(self: *Self, m: MatrixInfo, lanes: u32) ?u64 {
            const prog = self.matrixProgram(m.q4, lanes) orelse return null;
            const s = &self.s;
            // (the scratch it writes: the FFN's, or the logits' for the vocabulary)
            const out = if (@as(u64, m.rows) * 4 <= s.ffn_gate.bytes) s.ffn_gate else if (@as(u64, m.rows) * 4 <= self.out_logits.bytes) self.out_logits else return null;
            const p = kernels.MatrixParams{
                .row_bytes = m.row_bytes,
                .blocks = m.blocks,
                .rows = m.rows,
                .out_stride = m.rows * 4,
                .weights = m.offset,
                .act_q = 0,
                .act_d = 0,
                .act_sums = 0,
                .out = 0,
            };
            var best: u64 = std.math.maxInt(u64);
            for (0..2) |_| {
                var l = List{ .work = self.work };
                l.named("matrix (timed)", m.tensor, 0, 1);
                l.add(prog, kernels.matrixGroupsWith(.{ .lanes = lanes }, m.rows), &.{ self.weights, s.act_q, s.act_d, s.act_sums, out }, &p.words(.q4_k)) catch return null;
                self.runNow(&l) catch return null;
                const ns = self.dev.lastRunNs();
                if (ns == 0) return null;
                best = @min(best, ns);
            }
            return best;
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

const HEAD_SIZE = kernels.HEAD_SIZE;

/// lfm3_executor's rmsNormRow (locate's CPU side).
fn rmsNormRow(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) void {
    var squares: f64 = 0;
    for (input) |value| squares += @as(f64, value) * value;
    const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
    const inverse = 1.0 / @sqrt(mean + epsilon);
    for (input, weight, output[0..input.len]) |value, scale, *destination| destination.* = value * inverse * scale;
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
