//! @zpm/lfm3-nv — LFM3's forward pass on NVIDIA's sm_120 (the Legion 5's
//! RTX 5070 Laptop GPU), in pure Sig: the twin of lfm3_gpu.sig (the
//! Adreno's), over an nvidia Device.
//!
//! The same work as lfm3_executor.forwardInput, as one pushbuffer per call:
//! per layer the pre-mixer RMSNorm and Q8_K quantization, the short
//! convolution or attention mixer, the residual (with LFM3's sandwich
//! norms), the SwiGLU FFN; then the output norm and the logits. The kernels
//! are lfm3_nv_matrix's (the Q4_K and Q6_K matrices, the Q8_K quantization
//! with and without RMSNorm) and lfm3_nv_ops' (the residual, SwiGLU, the
//! convolution, the attention prepare and attention), assembled once by
//! `init` with sm120_asm. The GPU is an nvidia Device: Galaxy's RTX driver
//! through its 'G' calls, or the emulated RTX in tests.
//!
//! # Memory
//!
//! Everything is allocated by `init` (no allocator in sight afterwards), on
//! two Devices. The main one is the RTX's VRAM: the model file, activations
//! for `max_batch` tokens, the kernels' code (each kernel at its own
//! 256-aligned address, zeros after it), the QMDs with their constant
//! buffers, the pushbuffer, and each sequence's f16 KV cache. The optional
//! `Options.host` is system memory the GPU maps: what the CPU reads after
//! every call goes there (the logits, the output-normed hidden row, each
//! sequence's conv state and the snapshot a failed call is undone from),
//! because the CPU's reads of write-combined VRAM through BAR1 cross PCIe a
//! word at a time. Without one, everything is the main Device's.
//!
//! Each sequence's state is a `Cache` (newCache, one per slot): the KV
//! cache and the conv state in lfm3_executor's layout, which the CPU maps
//! too, with the executor's view of them (`Cache.cpu`). So a host runs the
//! CPU executor on the very same state when the GPU fails (toCpu first,
//! error.DeviceLost) or for a call it does not take (error.LongContext).
//! Between calls the conv state is the CPU's (galaxy-think keeps checkpoints
//! of it): each call hands it to the GPU and fetches it back. The KV cache
//! is the GPU's until toCpu hands it over.
//!
//! Token rows are dequantized on the CPU from the model file the host gave
//! `init` (it must outlive the backend: galaxy-think's mapping does), not
//! from the GPU's copy, for the same reason. `source()` is that GPU copy, as
//! lfm3_gpu has it, for a CPU executor that must read exactly what the GPU
//! reads; on the PC it is slow to read.
//!
//! # The FFN's width
//!
//! lfm3_nv_matrix's Q6_K kernel takes rows of whole groups of 8 blocks (K
//! a multiple of 2048, rows 16-byte aligned). LFM3-Audio-2B's Q4_K_M file
//! has Q6_K ffn_down rows of 7680 (30 blocks, 6300 bytes) in 12 of its 24
//! layers. When a model has such an ffn_down, the FFN runs at its width
//! rounded up to 2048 (8192 for LFM3-Audio-2B): the gate
//! and up projections write their rows that far apart (the columns past the
//! model's stay zero), SwiGLU and the quantization run over the padded rows
//! (zeros stay zeros, and quantize to zero blocks), and every layer's
//! ffn_down is copied once into a buffer of its own with each row padded by
//! zero blocks (d = 0). Each padded block adds +0 to a row's lanes, so the
//! results are the CPU's to the bit still, at 2/30 more of ffn_down's reads.
//! (When the Q6_K kernel takes any block count, this padding can go.)
//!
//! # A call's pushbuffer
//!
//! Compute bound to its subchannel and its windows (push.computeSetup),
//! local memory when a kernel has a stack (none of the current ones do), the
//! shader caches invalidated (the code, the QMDs and their constant buffers
//! the CPU wrote since the SMs last ran), then the launches in order, then
//! WAIT_FOR_IDLE; the driver appends its own semaphore release (the fence).
//! Each launch is a QMD (qmd.build: the kernel's registers, its shared
//! bytes, the grid and block its launch helper gives) and its constant
//! buffer 0 (qmd.cbuf0: the kernel's Params from 0x380), in a slot of their
//! own, written by the CPU and handed over before the submit.
//!
//! # Launch ordering
//!
//! A launch that reads what the one before it wrote is preceded by
//! WAIT_FOR_IDLE (clcec0.h's 0x0110: the compute engine drains) and
//! INVALIDATE_SHADER_CACHES, the pair Galaxy's RTX renderer sends
//! (galaxy/ui/gfx_gpu.sig's waitIdle); each CTA ends with an L1 sysmembar
//! (the QMD's CWD_MEMBAR_TYPE) and each launch invalidates its data caches
//! (the QMD's INVALIDATES), so the second grid reads the first one's
//! writes. Launches that only read the same activations (q, k, v and the
//! gate; the FFN's gate and up; a matrix's passes of eight tokens) go
//! without a wait between them, as lfm3_gpu's linearNoWait. Tinygrad's
//! dependent QMDs (each QMD launching the next) would save the host
//! engine's round trips, but nothing here has run them on the Legion yet,
//! and the emulated RTX does not model them.
//!
//! Allocation-free: the buffers are the devices', the assembler's working
//! storage the caller's.

const std = @import("std");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const quantized = @import("quantized_linear");
const nvidia = @import("nvidia");
const matrix = @import("lfm3_nv_matrix");
const ops = @import("lfm3_nv_ops");

const sm120_asm = nvidia.sm120_asm;
const qmd = nvidia.qmd;
const push = nvidia.push;
pub const Device = nvidia.device.Device;
pub const Buffer = nvidia.device.Buffer;

pub const Error = error{
    /// The model's shapes are outside what the kernels do (a hidden size
    /// other than 1024, 2048, 4096 or 8192, head size 128, widths in
    /// 256-lane blocks, Q6_K matrices other than ffn_down in rows of whole
    /// 2048s, 2 to 8 conv taps...).
    Unsupported,
    BatchCapacity,
    ContextCapacity,
    InvalidToken,
    /// More launches than the slots `init` made for max_batch tokens.
    StreamFull,
    /// The GPU did not finish the call (it hung or faulted, or a kernel
    /// tripped the emulator): the cache is as it was before it, and the host
    /// runs the call on the CPU (toCpu first).
    DeviceLost,
    /// The call's attention would reach further back than the GPU's kernel
    /// does (MAX_ATTENTION_SPAN positions): the host runs it on the CPU
    /// (toCpu first).
    LongContext,
} || nvidia.device.Error || sm120_asm.Error || qmd.Error || executor.Error;

pub const Options = struct {
    max_batch: u32 = 64,
    /// How long one call may take on the GPU before it counts as slow (it
    /// is waited for still: see `finish`).
    timeout_us: u64 = 10_000_000,
    /// System memory the GPU maps (Galaxy's `nvDevice(.system)`), for what
    /// the CPU reads after every call: the logits, the hidden row, the conv
    /// state and its snapshot. Only its alloc, free, toDevice and fromDevice
    /// are used; the main Device submits. None: the main Device's memory.
    host: ?Device = null,
};

/// The most positions an attention layer reads on the GPU (a call reaching
/// further back is error.LongContext: the CPU's).
pub const MAX_ATTENTION_SPAN = ops.MAX_ATTENTION_SPAN;
const MATRIX_VARIANTS = matrix.MAX_TOKENS;

/// A launch's slot: its QMD at 0 (256-aligned), constant buffer 0 at 0x200
/// (64-aligned).
const SLOT_BYTES = 0x600;
const CBUF_AT = 0x200;
/// The kernels' code: about 400 KiB for the 16 matrix variants and the rest.
const CODE_BYTES = 1 << 20;
/// Zeros after each kernel (the SMs' prefetch reads past a program's end;
/// the emulated RTX reads a program up to its first all-zero instruction).
const CODE_GAP = 256;
/// Pushbuffer dwords a launch takes at most: WAIT_FOR_IDLE and
/// INVALIDATE_SHADER_CACHES before it, SEND_PCAS_A and SEND_SIGNALING_PCAS2_B.
const DWORDS_PER_LAUNCH = 8;
const SETUP_DWORDS = 32;

/// clcec0.h's WAIT_FOR_IDLE (galaxy/ui/gfx_gpu.sig's).
const WAIT_FOR_IDLE: u32 = 0x0110;

/// GB206's GR as GSP-RM reports it (48 warps an SM, 2 SMs a TPC, 3 GPCs of
/// 8 TPCs), for local memory's sizes when a kernel has a stack.
const WARPS_PER_SM = 48;
const SMS_PER_TPC = 2;
const TPCS = 24;

/// A token row's bytes at most (8192 columns of Q6_K).
const MAX_ROW_BYTES = 8192 / quantized.QK_K * quantized.Q6_K_BLOCK_BYTES;
const HALF_HEAD = ops.HEAD_SIZE / 2;

/// One assembled kernel: where its code is, and what its QMD needs.
const Program = struct {
    va: u64 = 0,
    bytes: u32 = 0,
    registers: u32 = 0,
    /// Its parameter bytes (constant buffer 0 from 0x380).
    params: u32 = 0,
    /// Local memory a thread (qmd.localSize's per_thread), 0 without a stack.
    local: u32 = 0,
};

const Kernels = struct {
    q4k: [MATRIX_VARIANTS]Program = @splat(.{}),
    q6k: [MATRIX_VARIANTS]Program = @splat(.{}),
    norm_quant: Program = .{},
    quant: Program = .{},
    residual: Program = .{},
    swiglu: Program = .{},
    conv: Program = .{},
    prepare: Program = .{},
    attention: Program = .{},
};

/// Activation buffers (VRAM), sized for max_batch.
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
    rope_full: Buffer = .{},
    rope_swa: Buffer = .{},
};

/// A sequence's state: the KV cache (VRAM) and the conv state (the host's
/// memory) in lfm3_executor's layout, which the CPU maps too. `cpu` is the
/// executor's view of them (its slices are kv's and conv's CPU views).
pub const Cache = struct {
    cpu: executor.Cache,
    kv: Buffer,
    conv: Buffer,
    /// The CPU holds the KV rows (toCpu): they go to the GPU before its next
    /// call on this cache.
    kv_on_cpu: bool = false,
};

/// A matrix as its kernel reads it.
const MatrixInfo = struct {
    va: u64,
    row_bytes: u32,
    rows: u32,
    blocks: u32,
    format: matrix.Format,
};

/// What a QMD gets from a launch helper.
const Shape = struct { grid: [3]u32, block: [3]u32, shared: u32 = 0 };

fn matrixShape(s: matrix.Shape) Shape {
    return .{ .grid = s.grid, .block = s.block, .shared = s.shared };
}

fn opsShape(l: ops.Launch) Shape {
    return .{ .grid = l.grid, .block = l.block, .shared = l.shared_bytes };
}

/// A call's pushbuffer and launch slots, as they are written.
const Batch = struct {
    p: push.Push,
    slots: Buffer,
    capacity: u32,
    n: u32 = 0,
    /// The next launch reads what the ones before it wrote.
    wait: bool = false,

    fn barrier(b: *Batch) void {
        if (b.n > 0) b.wait = true;
    }
};

/// The compute engine idle, then the shader caches invalidated (Galaxy's
/// renderer's waitIdle): what one launch wrote, the next reads.
fn waitIdle(p: *push.Push) void {
    p.method(push.SUBCH_COMPUTE, WAIT_FOR_IDLE, &.{0});
    p.invalidateShaderCaches();
}

pub fn Backend(comptime tensor_capacity: usize) type {
    return struct {
        const Self = @This();

        dev: Device,
        /// Where the CPU's per-call reads live (Options.host, or dev).
        host: Device,
        options: Options,
        plan: *const lfm3.Plan,
        index: *const gguf.Index(tensor_capacity),
        /// The model file the host gave init (token rows, the RoPE factors).
        file: gguf.Source,
        model: Buffer = .{},
        model_size: u64,
        /// Each layer's ffn_down with its rows padded to `ffn_width` (none
        /// when the model's need no padding: see the module's doc).
        padded: Buffer = .{},
        padded_at: [lfm3.MAX_LAYERS]u64 = @splat(0),
        /// The FFN's width as the GPU runs it.
        ffn_width: u32,
        factors: [HALF_HEAD]f32 = @splat(1),
        has_factors: bool = false,
        s: Scratch = .{},
        /// (host) The last call's output-normed hidden row and logits.
        out_hidden: Buffer = .{},
        out_logits: Buffer = .{},
        /// (host) The conv state as a call found it (the CPU's only): put
        /// back when the call fails, the GPU having written part of it.
        conv_snapshot: Buffer = .{},
        k: Kernels = .{},
        code: Buffer = .{},
        local_memory: Buffer = .{},
        local: ?push.Local = null,
        slots: Buffer = .{},
        slot_count: u32 = 0,
        pb: Buffer = .{},
        /// GPU calls that did not finish (each one fell back to the CPU), and
        /// why the last one did not.
        lost: u32 = 0,
        last_failure: ?nvidia.device.Error = null,
        /// Calls that took longer than options.timeout_us (and finished).
        slow: u32 = 0,
        /// Launches the last call sent, and every call's.
        last_launches: u32 = 0,
        launches: u64 = 0,

        /// Check the model, allocate everything, copy the model file in,
        /// assemble the kernels. `file` must outlive the backend; `work` is
        /// the assembler's working storage.
        pub fn init(dev: Device, plan: *const lfm3.Plan, index: *const gguf.Index(tensor_capacity), file: gguf.Source, options: Options, work: *sm120_asm.Work) Error!Self {
            const ffn_width = try supported(plan, index, options);
            var self = Self{
                .dev = dev,
                .host = options.host orelse dev,
                .options = options,
                .plan = plan,
                .index = index,
                .file = file,
                .model_size = file.size,
                .ffn_width = ffn_width,
            };
            errdefer self.deinit();
            // The model file, as the GPU (and a CPU executor on source())
            // reads it. (16 bytes past it readable, as the matrix kernels
            // want their weights.)
            self.model = try dev.alloc(@intCast(file.size + 256));
            var at: u64 = 0;
            while (at < file.size) {
                const n: usize = @intCast(@min(file.size - at, 4 << 20));
                if (!file.read(at, self.model.cpu[@intCast(at)..][0..n])) return error.StorageNotMapped;
                at += n;
            }
            @memset(self.model.cpu[@intCast(file.size)..], 0);
            dev.toDevice(self.model, 0, self.model.cpu.len);
            try self.padFfnDown();
            try self.readFactors();
            try self.allocBuffers();
            try self.assemble(work);
            return self;
        }

        /// Every buffer back to its device.
        pub fn deinit(self: *Self) void {
            const vram = [_]*Buffer{ &self.model, &self.padded, &self.code, &self.local_memory, &self.slots, &self.pb };
            for (vram) |b| self.release(self.dev, b);
            const s = &self.s;
            const scratch = [_]*Buffer{ &s.hidden, &s.normalized, &s.mixed, &s.query, &s.key, &s.value, &s.gate, &s.mixer, &s.projected, &s.ffn_gate, &s.ffn_up, &s.act_q, &s.act_d, &s.act_sums, &s.rope_full, &s.rope_swa };
            for (scratch) |b| self.release(self.dev, b);
            const host = [_]*Buffer{ &self.out_hidden, &self.out_logits, &self.conv_snapshot };
            for (host) |b| self.release(self.host, b);
        }

        fn release(self: *Self, d: Device, b: *Buffer) void {
            _ = self;
            if (b.cpu.len != 0) d.free(b.*);
            b.* = .{};
        }

        /// Each layer's ffn_down with its rows padded to ffn_width by zero
        /// blocks, read from the file (when the FFN runs wider than the
        /// model's: see the module's doc).
        fn padFfnDown(self: *Self) Error!void {
            const plan = self.plan;
            if (self.ffn_width == plan.feed_forward_size) return;
            const blocks: usize = plan.feed_forward_size / quantized.QK_K;
            const padded_blocks: usize = self.ffn_width / quantized.QK_K;
            var total: usize = 0;
            for (plan.layers[0..plan.layer_count]) |*l| {
                const t = try self.tensorOf(l.ffn_down);
                total += @as(usize, plan.hidden_size) * padded_blocks * blockBytes(t.ggml_type);
            }
            self.padded = try self.dev.alloc(total);
            var at: usize = 0;
            for (plan.layers[0..plan.layer_count], 0..) |*l, li| {
                const t = try self.tensorOf(l.ffn_down);
                const bb = blockBytes(t.ggml_type);
                const row = blocks * bb;
                const padded_row = padded_blocks * bb;
                self.padded_at[li] = at;
                for (0..plan.hidden_size) |r| {
                    const dst = self.padded.cpu[at + r * padded_row ..][0..padded_row];
                    if (!self.file.read(t.file_offset + @as(u64, r) * row, dst[0..row])) return error.StorageNotMapped;
                    @memset(dst[row..], 0);
                }
                at += @as(usize, plan.hidden_size) * padded_row;
            }
            self.dev.toDevice(self.padded, 0, total);
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
            const b: usize = self.options.max_batch;
            const h: usize = plan.hidden_size;
            const ff: usize = self.ffn_width;
            const q: usize = plan.queryWidth();
            const kvw: usize = @as(usize, plan.max_kv_head_count) * plan.head_size;
            const widest = @max(@max(h, q), ff);
            const d = self.dev;
            self.s.hidden = try d.alloc(b * h * 4);
            self.s.normalized = try d.alloc(b * h * 4);
            self.s.mixed = try d.alloc(b * 3 * h * 4);
            self.s.query = try d.alloc(b * @max(q, 1) * 4);
            self.s.key = try d.alloc(b * @max(kvw, 1) * 4);
            self.s.value = try d.alloc(b * @max(kvw, 1) * 4);
            self.s.gate = try d.alloc(b * @as(usize, @max(plan.head_count, 1)) * 4);
            self.s.mixer = try d.alloc(b * @max(q, h) * 4);
            self.s.projected = try d.alloc(b * h * 4);
            self.s.ffn_gate = try d.alloc(b * ff * 4);
            self.s.ffn_up = try d.alloc(b * ff * 4);
            self.s.act_q = try d.alloc(b * widest);
            self.s.act_d = try d.alloc(b * widest / quantized.QK_K * 4);
            self.s.act_sums = try d.alloc(b * widest / 16 * 2);
            const rope_bytes = b * HALF_HEAD * 2 * 4;
            self.s.rope_full = try d.alloc(rope_bytes);
            self.s.rope_swa = try d.alloc(rope_bytes);
            // (the FFN's padding columns are never written by the matrices:
            // zeros, from both sides)
            @memset(self.s.ffn_gate.cpu, 0);
            @memset(self.s.ffn_up.cpu, 0);
            d.toDevice(self.s.ffn_gate, 0, self.s.ffn_gate.cpu.len);
            d.toDevice(self.s.ffn_up, 0, self.s.ffn_up.cpu.len);
            self.out_hidden = try self.host.alloc(h * 4);
            self.out_logits = try self.host.alloc(@as(usize, plan.vocabulary_size) * 4);
            self.conv_snapshot = try self.host.alloc(@max(try executor.requiredConvElements(plan), 1) * 4);
            self.slot_count = launchesFor(plan, self.options.max_batch);
            self.slots = try d.alloc(@as(usize, self.slot_count) * SLOT_BYTES);
            self.pb = try d.alloc((SETUP_DWORDS + @as(usize, self.slot_count) * DWORDS_PER_LAUNCH) * 4);
        }

        /// Assemble every kernel the model needs into the code buffer, each
        /// at its own 256-aligned address with zeros after it.
        fn assemble(self: *Self, work: *sm120_asm.Work) Error!void {
            const plan = self.plan;
            self.code = try self.dev.alloc(CODE_BYTES);
            const words: []u64 = @alignCast(std.mem.bytesAsSlice(u64, self.code.cpu));
            var at = Placer{ .words = words, .va = self.code.va, .work = work };
            const passes = @min(self.options.max_batch, MATRIX_VARIANTS);
            const used = self.formatsUsed();
            for (0..passes) |t| {
                const tokens: u32 = @intCast(t + 1);
                if (used.q4) self.k.q4k[t] = try at.put(try matrix.matrixSource(.q4_k, tokens));
                if (used.q6) self.k.q6k[t] = try at.put(try matrix.matrixSource(.q6_k, tokens));
            }
            const waves: u32 = @intCast(plan.hidden_size / quantized.QK_K);
            self.k.norm_quant = try at.put(try matrix.q8kQuantSource(true, waves));
            self.k.quant = try at.put(comptime matrix.q8kQuant(false, 1));
            self.k.residual = try at.put(try residualSource(plan.sandwich_norms, plan.hidden_size));
            self.k.swiglu = try at.put(comptime ops.swiglu.source());
            if (plan.conv_layer_count > 0) self.k.conv = try at.put(try convSource(plan.conv_kernel));
            if (plan.attention_layer_count > 0) {
                self.k.prepare = try at.put(comptime ops.prepare.source());
                self.k.attention = try at.put(comptime ops.attention.source());
            }
            self.dev.toDevice(self.code, 0, at.used * 8);
            // Local memory for the kernels with a stack (none have one now).
            if (at.stack > 0) {
                const s = qmd.localSize(at.stack, WARPS_PER_SM, SMS_PER_TPC, TPCS);
                self.local_memory = try self.dev.alloc(@intCast(s.total));
                self.local = .{ .va = self.local_memory.va, .per_tpc = s.per_tpc };
            }
        }

        const Formats = struct { q4: bool = false, q6: bool = false };

        /// The matrix formats the forward pass multiplies.
        fn formatsUsed(self: *const Self) Formats {
            var f = Formats{};
            var it = Matrices{ .plan = self.plan };
            while (it.next()) |ref| {
                switch (self.index.tensors[ref.index].ggml_type) {
                    12 => f.q4 = true,
                    14 => f.q6 = true,
                    else => {},
                }
            }
            return f;
        }

        /// The model file in GPU memory, for a CPU executor that must read
        /// what the GPU reads (lfm3_gpu's). On the PC it is VRAM behind
        /// BAR1, slow for the CPU: a host falling back reads its own mapping
        /// of the file (galaxy-think does).
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

        /// A sequence's state for `context` positions, zeroed (position 0):
        /// the KV cache in VRAM, the conv state in the host's memory.
        pub fn newCache(self: *Self, context: u32) Error!Cache {
            const kv_n = try executor.requiredKvElements(self.plan, context);
            const conv_n = try executor.requiredConvElements(self.plan);
            const kv = try self.dev.alloc(kv_n * 2);
            errdefer self.dev.free(kv);
            const conv = try self.host.alloc(@max(conv_n, 1) * 4);
            @memset(kv.cpu, 0);
            @memset(conv.cpu, 0);
            self.dev.toDevice(kv, 0, kv.cpu.len);
            self.host.toDevice(conv, 0, conv.cpu.len);
            const kv_view: []u16 = @alignCast(std.mem.bytesAsSlice(u16, kv.cpu));
            const conv_view: []f32 = @alignCast(std.mem.bytesAsSlice(f32, conv.cpu));
            return .{ .cpu = .{ .kv = kv_view[0..kv_n], .conv = conv_view[0..conv_n], .context = context }, .kv = kv, .conv = conv };
        }

        pub fn freeCache(self: *Self, c: *Cache) void {
            self.dev.free(c.kv);
            self.host.free(c.conv);
            c.* = undefined;
        }

        /// Hand the cache to the CPU: call before running the CPU executor on
        /// c.cpu. The next GPU call on it takes the KV rows back.
        pub fn toCpu(self: *Self, c: *Cache) void {
            self.dev.fromDevice(c.kv, 0, c.kv.cpu.len);
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
                .tokens => |tokens| {
                    for (tokens) |token| {
                        if (token >= plan.vocabulary_size) return error.InvalidToken;
                    }
                },
                .embeddings => |rows| {
                    if (rows.len % h != 0) return error.InvalidToken;
                },
            }
            if (cache.position + count > cache.context) return error.ContextCapacity;
            if (self.span(cache.position + count) > MAX_ATTENTION_SPAN) return error.LongContext;
            // KV rows from a CPU fallback, and the CPU's conv state, to the GPU;
            // the conv state kept so a failed call can be undone.
            if (c.kv_on_cpu) {
                self.dev.toDevice(c.kv, 0, c.kv.cpu.len);
                c.kv_on_cpu = false;
            }
            const conv_bytes = cache.conv.len * 4;
            self.host.toDevice(c.conv, 0, conv_bytes);
            @memcpy(self.conv_snapshot.cpu[0..conv_bytes], c.conv.cpu[0..conv_bytes]);
            // Inputs: token rows dequantized here from the file, or given rows.
            const hid: []f32 = @alignCast(std.mem.bytesAsSlice(f32, self.s.hidden.cpu));
            switch (input) {
                .tokens => |tokens| {
                    for (tokens, 0..) |token, slot| try self.embed(token, hid[slot * h ..][0..h]);
                },
                .embeddings => |rows| @memcpy(hid[0..rows.len], rows),
            }
            self.dev.toDevice(self.s.hidden, 0, count * h * 4);
            // RoPE: full layers by rope_frequency_base and the factors, sliding
            // ones by their own base.
            if (plan.attention_layer_count > 0) {
                const factors: ?[]const f32 = if (self.has_factors) &self.factors else null;
                ops.ropeTable(@alignCast(std.mem.bytesAsSlice(f32, self.s.rope_full.cpu)), cache.position, count, plan.head_size, plan.rope_frequency_base, factors);
                ops.ropeTable(@alignCast(std.mem.bytesAsSlice(f32, self.s.rope_swa.cpu)), cache.position, count, plan.head_size, plan.rope_frequency_base_swa, null);
                self.dev.toDevice(self.s.rope_full, 0, count * HALF_HEAD * 8);
                self.dev.toDevice(self.s.rope_swa, 0, count * HALF_HEAD * 8);
            }

            var b = Batch{ .p = .{ .buf = self.pb.words() }, .slots = self.slots, .capacity = self.slot_count };
            b.p.computeSetup(.{});
            if (self.local) |l| b.p.localMemory(l);
            b.p.invalidateShaderCaches();
            for (plan.layers[0..plan.layer_count]) |*l| try self.layer(&b, l, c, count);
            if (output != .none) {
                // the last position's output norm (and its quantization)
                try self.normQuant(&b, self.s.hidden.va + (count - 1) * h * 4, plan.output_norm, 1, self.out_hidden.va);
                if (output == .logits) try self.linear(&b, try self.matrixOf(plan.output), 1, self.out_logits.va, plan.vocabulary_size * 4);
            }
            b.p.method(push.SUBCH_COMPUTE, WAIT_FOR_IDLE, &.{0});
            b.p.check() catch return error.StreamFull;
            self.dev.toDevice(self.slots, 0, @as(usize, b.n) * SLOT_BYTES);
            self.dev.toDevice(self.pb, 0, b.p.len * 4);
            self.last_launches = b.n;
            self.launches += b.n;
            const fence = self.dev.submit(self.pb, @intCast(b.p.len)) catch |e| return self.failed(c, e);
            self.finish(fence) catch |e| return self.failed(c, e);
            self.host.fromDevice(c.conv, 0, conv_bytes);
            cache.position += count;
            if (output == .none) return null;
            self.host.fromDevice(self.out_hidden, 0, h * 4);
            if (output == .hidden) return null;
            self.host.fromDevice(self.out_logits, 0, self.out_logits.cpu.len);
            return @intCast(argmax(self.logits()));
        }

        /// Token `token`'s embedding row, dequantized from the file.
        fn embed(self: *const Self, token: u32, dst: []f32) Error!void {
            const t = try self.tensorOf(self.plan.token_embedding);
            const row_bytes = @as(usize, self.plan.hidden_size) / quantized.QK_K * blockBytes(t.ggml_type);
            const offset = t.file_offset + @as(u64, token) * row_bytes;
            var buf: [MAX_ROW_BYTES]u8 = undefined;
            const row = self.file.view(offset, row_bytes, 1) orelse blk: {
                if (!self.file.read(offset, buf[0..row_bytes])) return error.StorageNotMapped;
                break :blk buf[0..row_bytes];
            };
            if (t.ggml_type == 12) try quantized.dequantizeQ4K(dst, row) else try quantized.dequantizeQ6K(dst, row);
        }

        /// Wait for a call's pushbuffer. One slower than options.timeout_us
        /// is counted and waited for still: until it is done the GPU may
        /// write the state a CPU fallback would take over, so only the
        /// driver ends the wait, with the work done or the GPU lost.
        fn finish(self: *Self, fence: nvidia.device.Fence) nvidia.device.Error!void {
            self.dev.wait(fence, self.options.timeout_us) catch |e| {
                if (e != error.Timeout) return e;
                self.slow += 1;
                return self.dev.wait(fence, std.math.maxInt(u64));
            };
        }

        /// A call that did not finish: its conv state put back (the GPU may
        /// have written part of it; KV rows past the position are written
        /// again by the next call).
        fn failed(self: *Self, c: *Cache, e: nvidia.device.Error) Error {
            self.lost += 1;
            self.last_failure = e;
            const n = c.cpu.conv.len * 4;
            @memcpy(c.conv.cpu[0..n], self.conv_snapshot.cpu[0..n]);
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

        fn layer(self: *Self, b: *Batch, l: *const lfm3.Layer, c: *const Cache, count: usize) Error!void {
            const plan = self.plan;
            const h: u32 = plan.hidden_size;
            const n: u32 = @intCast(count);
            const s = &self.s;
            try self.normQuant(b, s.hidden.va, l.attn_norm, n, s.normalized.va);
            switch (l.kind) {
                .short_conv => {
                    try self.linear(b, try self.matrixOf(l.in_proj), n, s.mixed.va, 3 * h * 4);
                    const taps: u32 = plan.conv_kernel;
                    const state = c.conv.va + @as(u64, l.slot) * (taps - 1) * h * 4;
                    try self.launch(b, &self.k.conv, opsShape(try ops.conv.launch(taps, h, n)), &ops.conv.Params{
                        .mixed = s.mixed.va,
                        .taps = try self.tensorAddress(l.conv),
                        .state = state,
                        .out = s.mixer.va,
                        .hidden = h,
                        .tokens = n,
                    });
                    b.barrier();
                    try self.quant(b, s.mixer.va, h, n);
                    try self.linear(b, try self.matrixOf(l.out_proj), n, s.projected.va, h * 4);
                },
                .attention => {
                    const heads: u32 = plan.head_count;
                    const kv_heads: u32 = l.kv_head_count;
                    const position: u32 = @intCast(c.cpu.position);
                    const window: u32 = if (l.sliding_window) plan.sliding_window else 0;
                    const kv = ops.KvCache{ .kv = c.kv.va, .context = @intCast(c.cpu.context), .max_kv_heads = plan.max_kv_head_count };
                    // q, k, v and the gate read the same activations: no wait between
                    try self.linearNoWait(b, try self.matrixOf(l.attn_q), n, s.query.va, heads * ops.HEAD_SIZE * 4);
                    try self.linearNoWait(b, try self.matrixOf(l.attn_k), n, s.key.va, kv_heads * ops.HEAD_SIZE * 4);
                    try self.linearNoWait(b, try self.matrixOf(l.attn_v), n, s.value.va, kv_heads * ops.HEAD_SIZE * 4);
                    try self.linear(b, try self.matrixOf(l.attn_gate), n, s.gate.va, heads * 4);
                    try self.launch(b, &self.k.prepare, opsShape(try ops.prepare.launch(heads, kv_heads, n)), &ops.prepare.params(.{
                        .query = s.query.va,
                        .key = s.key.va,
                        .value = s.value.va,
                        .query_norm = try self.tensorAddress(l.attn_q_norm),
                        .key_norm = try self.tensorAddress(l.attn_k_norm),
                        .rope = if (l.sliding_window) s.rope_swa.va else s.rope_full.va,
                        .cache = kv,
                        .slot = l.slot,
                        .heads = heads,
                        .kv_heads = kv_heads,
                        .first_position = position,
                        .epsilon = plan.rms_norm_epsilon,
                    }));
                    b.barrier();
                    try self.launch(b, &self.k.attention, opsShape(try ops.attention.launch(heads, kv_heads, n, position, window)), &ops.attention.params(.{
                        .query = s.query.va,
                        .gate = s.gate.va,
                        .out = s.mixer.va,
                        .cache = kv,
                        .slot = l.slot,
                        .heads = heads,
                        .kv_heads = kv_heads,
                        .first_position = position,
                        .window = window,
                    }));
                    b.barrier();
                    try self.quant(b, s.mixer.va, @intCast(plan.queryWidth()), n);
                    try self.linear(b, try self.matrixOf(l.attn_output), n, s.projected.va, h * 4);
                },
            }
            try self.residual(b, l.post_attention_norm, n);
            try self.normQuant(b, s.hidden.va, l.ffn_norm, n, s.normalized.va);
            // (the FFN's rows ffn_width apart: its padding, when there is)
            const ff = self.ffn_width;
            try self.linearNoWait(b, try self.matrixOf(l.ffn_gate), n, s.ffn_gate.va, ff * 4);
            try self.linear(b, try self.matrixOf(l.ffn_up), n, s.ffn_up.va, ff * 4);
            try self.launch(b, &self.k.swiglu, opsShape(try ops.swiglu.launch(n * ff)), &ops.swiglu.Params{ .gate = s.ffn_gate.va, .up = s.ffn_up.va, .out = s.ffn_gate.va, .count = n * ff });
            b.barrier();
            try self.quant(b, s.ffn_gate.va, ff, n);
            try self.linear(b, try self.downOf(l), n, s.projected.va, h * 4);
            try self.residual(b, l.post_ffw_norm, n);
        }

        /// RMSNorm `n` rows of hidden width at `x` into `normalized`, and
        /// quantize them into the activation arrays.
        fn normQuant(self: *Self, b: *Batch, x: u64, norm: lfm3.TensorRef, n: u32, normalized: u64) Error!void {
            const h = self.plan.hidden_size;
            var p = matrix.QuantParams.of(x, self.s.act_q.va, self.s.act_d.va, self.s.act_sums.va, h);
            p.norm_weight = try self.tensorAddress(norm);
            p.normalized = normalized;
            p.epsilon = self.plan.rms_norm_epsilon;
            try self.launch(b, &self.k.norm_quant, matrixShape(try matrix.quantLaunch(true, n, h)), &p);
            b.barrier();
        }

        /// `n` rows of `width` at `x` into the activation arrays.
        fn quant(self: *Self, b: *Batch, x: u64, width: u32, n: u32) Error!void {
            const p = matrix.QuantParams.of(x, self.s.act_q.va, self.s.act_d.va, self.s.act_sums.va, width);
            try self.launch(b, &self.k.quant, matrixShape(try matrix.quantLaunch(false, n, width)), &p);
            b.barrier();
        }

        /// hidden += post_norm(projected) (sandwich norms) or + projected.
        fn residual(self: *Self, b: *Batch, norm: lfm3.TensorRef, n: u32) Error!void {
            const h = self.plan.hidden_size;
            const postnorm = self.plan.sandwich_norms;
            const w = if (postnorm) try self.tensorAddress(norm) else 0;
            try self.launch(b, &self.k.residual, opsShape(try ops.residual.launch(postnorm, h, n)), &ops.residual.params(self.s.hidden.va, self.s.projected.va, w, h, self.plan.rms_norm_epsilon));
            b.barrier();
        }

        fn linear(self: *Self, b: *Batch, m: MatrixInfo, n: u32, out: u64, out_stride: u32) Error!void {
            try self.linearNoWait(b, m, n, out, out_stride);
            b.barrier();
        }

        /// out[t][row] = W[row] . activations[t]: passes of up to 8 tokens,
        /// each by the variant for its tokens (they read their own
        /// activations and write their own rows: no wait between).
        fn linearNoWait(self: *Self, b: *Batch, m: MatrixInfo, n: u32, out: u64, out_stride: u32) Error!void {
            const k: u64 = @as(u64, m.blocks) * quantized.QK_K;
            var first: u32 = 0;
            while (first < n) {
                const tokens = @min(n - first, MATRIX_VARIANTS);
                const prog = if (m.format == .q4_k) &self.k.q4k[tokens - 1] else &self.k.q6k[tokens - 1];
                try self.launch(b, prog, matrixShape(try matrix.matrixLaunch(m.format, tokens, m.rows, m.blocks)), &matrix.MatrixParams{
                    .weights = m.va,
                    .act_q = self.s.act_q.va + first * k,
                    .act_d = self.s.act_d.va + @as(u64, first) * m.blocks * 4,
                    .act_sums = self.s.act_sums.va + @as(u64, first) * m.blocks * 32,
                    .out = out + @as(u64, first) * out_stride,
                    .row_bytes = m.row_bytes,
                    .blocks = m.blocks,
                    .rows = m.rows,
                    .out_stride = out_stride,
                });
                first += tokens;
            }
        }

        /// One launch: its QMD and constant buffer 0 in the next slot, sent
        /// after the launches before it are done when it reads what they
        /// wrote (Batch.barrier).
        fn launch(self: *Self, b: *Batch, prog: *const Program, shape: Shape, params: anytype) Error!void {
            _ = self;
            const bytes = std.mem.asBytes(params);
            // (a kernel not assembled, or Params that are not its text's)
            if (prog.bytes == 0 or bytes.len != prog.params) return error.Unsupported;
            if (b.n >= b.capacity) return error.StreamFull;
            const at = @as(usize, b.n) * SLOT_BYTES;
            b.n += 1;
            const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(b.slots.cpu[at..][0..qmd.QMD_BYTES]));
            try qmd.build(q, .{
                .prog_va = prog.va,
                .prog_bytes = prog.bytes,
                .cbuf_va = b.slots.va + at + CBUF_AT,
                .registers = prog.registers,
                .grid = shape.grid,
                .block = shape.block,
                .local_bytes = prog.local,
                .shared_bytes = shape.shared,
            });
            const cb: *[qmd.CBUF0_WORDS]u32 = @ptrCast(@alignCast(b.slots.cpu[at + CBUF_AT ..][0..qmd.CBUF0_BYTES]));
            try qmd.cbuf0(cb, shape.grid, shape.block, bytes);
            if (b.wait) {
                waitIdle(&b.p);
                b.wait = false;
            }
            b.p.launch(b.slots.va + at);
        }

        fn tensorOf(self: *const Self, ref: lfm3.TensorRef) Error!*const gguf.TensorInfo {
            if (!ref.present() or ref.index >= self.index.tensor_count) return error.InvalidPlan;
            return &self.index.tensors[ref.index];
        }

        /// A matrix of the model file, as its kernel reads it.
        fn matrixOf(self: *const Self, ref: lfm3.TensorRef) Error!MatrixInfo {
            const t = try self.tensorOf(ref);
            if (t.dimension_count != 2 or (t.ggml_type != 12 and t.ggml_type != 14)) return error.Unsupported;
            const blocks: u32 = @intCast(t.dimensions[0] / quantized.QK_K);
            return .{
                .va = self.model.va + t.file_offset,
                .row_bytes = @intCast(blocks * blockBytes(t.ggml_type)),
                .rows = @intCast(t.dimensions[1]),
                .blocks = blocks,
                .format = if (t.ggml_type == 12) .q4_k else .q6_k,
            };
        }

        /// A layer's ffn_down: the file's, or its padded copy.
        fn downOf(self: *const Self, l: *const lfm3.Layer) Error!MatrixInfo {
            var m = try self.matrixOf(l.ffn_down);
            if (self.ffn_width == self.plan.feed_forward_size) return m;
            const li = (@intFromPtr(l) - @intFromPtr(&self.plan.layers[0])) / @sizeOf(lfm3.Layer);
            const t = try self.tensorOf(l.ffn_down);
            m.blocks = @intCast(self.ffn_width / quantized.QK_K);
            m.row_bytes = @intCast(m.blocks * blockBytes(t.ggml_type));
            m.va = self.padded.va + self.padded_at[li];
            return m;
        }

        fn tensorAddress(self: *const Self, ref: lfm3.TensorRef) Error!u64 {
            const t = try self.tensorOf(ref);
            return self.model.va + t.file_offset;
        }

        /// What the kernels can run; the FFN's width as the GPU runs it.
        fn supported(plan: *const lfm3.Plan, index: *const gguf.Index(tensor_capacity), options: Options) Error!u32 {
            const h = plan.hidden_size;
            // (the residual's widths in 1024s, the norm's rows of 1 to 32
            // blocks a power of two: 1024, 2048, 4096, 8192)
            if (h == 0 or h % 1024 != 0 or h > ops.residual.MAX_WIDTH or !std.math.isPowerOfTwo(h / quantized.QK_K)) return error.Unsupported;
            if (plan.feed_forward_size == 0 or plan.feed_forward_size % quantized.QK_K != 0) return error.Unsupported;
            if (plan.queryWidth() % quantized.QK_K != 0) return error.Unsupported;
            if (plan.vocabulary_size == 0 or !plan.output.present()) return error.Unsupported;
            if (options.max_batch == 0 or options.max_batch > 64) return error.Unsupported;
            if (plan.layer_count == 0 or plan.conv_layer_count == 0) return error.Unsupported;
            if (plan.conv_kernel < ops.conv.MIN_TAPS or plan.conv_kernel > ops.conv.MAX_TAPS) return error.Unsupported;
            if (plan.attention_layer_count > 0) {
                if (plan.head_size != ops.HEAD_SIZE or plan.head_count == 0 or plan.max_kv_head_count == 0) return error.Unsupported;
                for (plan.layers[0..plan.layer_count]) |*l| {
                    if (l.kind == .attention and (l.kv_head_count == 0 or plan.head_count % l.kv_head_count != 0)) return error.Unsupported;
                }
            }
            for (index.tensors[0..index.tensor_count]) |*t| {
                // (GPU loads of 16-byte rows and f32 vectors)
                if (t.file_offset % 16 != 0) return error.Unsupported;
            }
            if (!plan.token_embedding.present()) return error.InvalidPlan;
            const emb = &index.tensors[plan.token_embedding.index];
            if (emb.ggml_type != 12 and emb.ggml_type != 14) return error.Unsupported;
            // Every matrix the pass multiplies: Q4_K or Q6_K, Q6_K in whole
            // groups of 8 blocks (ffn_down's can be padded to them).
            var pad = false;
            var it = Matrices{ .plan = plan };
            while (it.next()) |ref| {
                const t = &index.tensors[ref.index];
                if (t.dimension_count != 2 or (t.ggml_type != 12 and t.ggml_type != 14)) return error.Unsupported;
                if (t.dimensions[0] == 0 or t.dimensions[0] % quantized.QK_K != 0 or t.dimensions[1] == 0) return error.Unsupported;
                if (t.ggml_type == 14 and (t.dimensions[0] / quantized.QK_K) % 8 != 0) {
                    if (!it.at_ffn_down) return error.Unsupported;
                    pad = true;
                }
            }
            return if (pad) @intCast(std.mem.alignForward(usize, plan.feed_forward_size, 8 * quantized.QK_K)) else plan.feed_forward_size;
        }
    };
}

/// Every matrix the forward pass multiplies (lfm3_executor's Matrices), and
/// whether the last one was an ffn_down.
const Matrices = struct {
    plan: *const lfm3.Plan,
    layer: usize = 0,
    slot: usize = 0,
    at_ffn_down: bool = false,

    fn next(self: *Matrices) ?lfm3.TensorRef {
        while (self.layer < self.plan.layer_count) {
            const l = &self.plan.layers[self.layer];
            const refs = [_]lfm3.TensorRef{ l.in_proj, l.out_proj, l.attn_q, l.attn_k, l.attn_v, l.attn_gate, l.attn_output, l.ffn_gate, l.ffn_up, l.ffn_down };
            while (self.slot < refs.len) {
                const ref = refs[self.slot];
                self.at_ffn_down = self.slot == refs.len - 1;
                self.slot += 1;
                if (ref.present()) return ref;
            }
            self.layer += 1;
            self.slot = 0;
        }
        if (self.layer == self.plan.layer_count) {
            self.layer += 1;
            self.at_ffn_down = false;
            if (self.plan.output.present()) return self.plan.output;
        }
        return null;
    }
};

/// Launches one call of `tokens` tokens sends at most.
fn launchesFor(plan: *const lfm3.Plan, tokens: u32) u32 {
    const passes = (tokens + MATRIX_VARIANTS - 1) / MATRIX_VARIANTS;
    var n: u32 = 2; // the output norm, the logits (one token)
    for (plan.layers[0..plan.layer_count]) |*l| {
        // two norms, two residuals, SwiGLU and its quantization; the FFN's
        // three matrices
        n += 6 + 3 * passes;
        n += switch (l.kind) {
            .short_conv => 2 + 2 * passes,
            .attention => 3 + 5 * passes,
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

/// Kernels placed one after another in the code buffer.
const Placer = struct {
    words: []u64,
    va: u64,
    work: *sm120_asm.Work,
    used: usize = 0,
    /// The most stack any kernel has.
    stack: u32 = 0,

    fn put(p: *Placer, text: []const u8) Error!Program {
        // (QMD program addresses are 256-aligned: 32 words)
        p.used = std.mem.alignForward(usize, p.used, CODE_GAP / 8);
        if (p.used >= p.words.len) return error.BufferTooSmall;
        const k = try sm120_asm.assemble(text, p.words[p.used..], p.work);
        const at = p.used;
        p.used += k.code.len;
        if (p.used + CODE_GAP / 8 > p.words.len) return error.BufferTooSmall;
        @memset(p.words[p.used..][0 .. CODE_GAP / 8], 0);
        p.used += CODE_GAP / 8;
        p.stack = @max(p.stack, k.stack);
        return .{
            .va = p.va + at * 8,
            .bytes = @intCast(k.code.len * 8),
            .registers = k.registers,
            .params = k.params,
            .local = if (k.stack > 0) qmd.localSize(k.stack, WARPS_PER_SM, SMS_PER_TPC, TPCS).per_thread else 0,
        };
    }
};

// The kernels whose shape depends on the model, picked at run time from
// the variants a model can need.
fn residualSource(postnorm: bool, width: u32) Error![]const u8 {
    return switch (width) {
        inline 1024, 2048, 4096, 8192 => |w| if (postnorm) comptime ops.residual.source(true, w) else comptime ops.residual.source(false, w),
        else => error.Unsupported,
    };
}

fn convSource(taps: u32) Error![]const u8 {
    return switch (taps) {
        inline ops.conv.MIN_TAPS...ops.conv.MAX_TAPS => |t| comptime ops.conv.source(t),
        else => error.Unsupported,
    };
}
