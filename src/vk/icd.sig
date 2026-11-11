//! @zpm/vk icd — Galaxy's Vulkan driver: every entry point, behind the
//! loader's ICD interface (vk_icdNegotiateLoaderICDInterfaceVersion,
//! vk_icdGetInstanceProcAddr; the library's root exports them).
//!
//! It runs over zpm's GPU-neutral layer (docs/GPU.md): memory is
//! gpu.Device buffers, a compute pipeline is a SPIR-V entry point compiled
//! to KIR (src/spirv) and then by the device's backend (sm_120 on the RTX),
//! a queue submission is gpu.Device runs. The same code runs on the
//! emulated RTX and KIR's interpreter in tests.
//!
//! # What it is so far
//!
//! A Vulkan 1.0 compute device (instance version 1.1), truthful about it:
//!
//! - **One queue family**, COMPUTE and TRANSFER, one queue. No graphics
//!   yet, so wgpu does not take the adapter (it wants GRAPHICS on the
//!   first family); see PLAN.md.
//! - **Memory.** On a discrete GPU (the RTX): VRAM (device-local),
//!   system memory (host-visible, coherent, cached) and BAR1 VRAM
//!   (device-local and host-visible, coherent). On a unified one: one type,
//!   all of those. Coherence is the driver's: a submission makes the CPU's
//!   writes to mapped memory visible to the GPU (gpu.Device.toDevice), and
//!   every wait that sees work finished brings what the GPU wrote back
//!   (fromDevice), for the memory that work may have written.
//! - **Buffers, descriptor set layouts, pools and sets** (uniform and
//!   storage buffers, dynamic or not), **pipeline layouts** (up to 8 sets,
//!   128 bytes of push constants), **shader modules**, **compute pipelines**
//!   (specialization constants too), **pipeline caches** (empty).
//! - **Command buffers**: bind pipeline and sets, push constants, dispatch
//!   (direct and indirect), copy, fill and update buffers, pipeline barriers
//!   (the device runs dispatches in order, each seeing the writes before).
//!   Commands are recorded into 64 KiB blocks of a shared pool.
//! - **Submission and sync**: vkQueueSubmit runs each submission's work as
//!   gpu.Device runs; fences and binary and timeline semaphores
//!   (VK_KHR_timeline_semaphore) follow the device's fences, which signal in
//!   order.
//! - **Features**: robustBufferAccess (every buffer access checked against
//!   its descriptor's range in the kernel); nothing else.
//!
//! Handles: dispatchable ones point into a table of loader words (the
//! loader writes its dispatch table there); the others are a tag and an
//! index. Every table is fixed and lives in .bss (filled at the first
//! vkCreateInstance). One lock serializes the driver's calls.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const spirv = @import("spirv");
const abi = @import("abi.sig");
const kir = gpu.kir;
const ST = abi.StructureType;
const R = abi.result;
const Result = abi.Result;

// ── What the library root gives ────────────────────────────────────────────

pub const Compiler = *const fn (k: *const kir.Kernel, caps: gpu.Caps, work: *gpu.Work, out: []u8) anyerror!gpu.Binary;

/// The machine's GPU, as the root opens it.
pub const Gpu = struct {
    dev: gpu.Device,
    compile: Compiler,
    /// the backend's compile scratch (kir_sm120.WORK_BYTES on the RTX)
    work: []u8,
    /// PCI vendor and device (0: unknown)
    vendor_id: u32 = 0,
    device_id: u32 = 0,
};

/// Opens the GPU at the first vkEnumeratePhysicalDevices (null: none, and
/// the instance has no physical device). The root (or a test) sets it.
pub var opener: ?*const fn () ?Gpu = null;
/// Where the driver says why something failed (null: nowhere).
pub var log_fn: ?*const fn (msg: []const u8) void = null;

fn say(comptime fmt: []const u8, a: anytype) void {
    const lf = log_fn orelse return;
    var buf: [256]u8 = undefined;
    lf(std.fmt.bufPrint(&buf, fmt, a) catch buf[0..]);
}

// ── Versions, limits and the lists the driver reports ──────────────────────

pub fn makeVersion(major: u32, minor: u32, patch: u32) u32 {
    return major << 22 | minor << 12 | patch;
}
pub const INSTANCE_VERSION = makeVersion(1, 1, 0);
pub const DEVICE_VERSION = makeVersion(1, 0, 0);
pub const DRIVER_VERSION = makeVersion(0, 1, 0);
/// The loader-ICD interface version this driver speaks.
pub const ICD_INTERFACE_VERSION: u32 = 5;
const ICD_LOADER_MAGIC: usize = 0x01CDC0DE;

const Ext = struct { name: []const u8, version: u32 };
pub const instance_extensions = [_]Ext{
    .{ .name = "VK_KHR_get_physical_device_properties2", .version = 2 },
};
pub const device_extensions = [_]Ext{
    .{ .name = "VK_KHR_maintenance1", .version = 2 },
    .{ .name = "VK_KHR_storage_buffer_storage_class", .version = 1 },
    .{ .name = "VK_KHR_timeline_semaphore", .version = 2 },
};

pub const MAX_INSTANCES = 8;
pub const MAX_DEVICES = 8;
pub const MAX_MEMORY = 4096;
pub const MAX_BUFFERS = 8192;
pub const MAX_SET_LAYOUTS = 512;
pub const MAX_LAYOUT_BINDINGS = 64;
pub const MAX_PIPELINE_LAYOUTS = 512;
pub const MAX_SETS_PER_LAYOUT = 8;
pub const MAX_PUSH_BYTES = 128;
pub const MAX_POOLS = 256;
pub const MAX_SETS = 8192;
pub const MAX_DESCRIPTORS = 1 << 16;
pub const MAX_DYNAMIC = 32;
pub const MAX_SHADERS = 512;
pub const SHADER_WORDS = 2 << 20;
const SHADER_BLOCK_WORDS = 256;
pub const MAX_PIPELINES = 512;
pub const MAX_CMD_POOLS = 256;
pub const MAX_CMDBUFS = 1024;
pub const CMD_BLOCK = 64 * 1024;
pub const MAX_CMD_BLOCKS = 512;
const MAX_CB_BLOCKS = 64;
pub const MAX_FENCES = 1024;
pub const MAX_SEMAPHORES = 1024;
const MAX_PENDING = 16;
const MAX_CACHES = 64;
/// Dispatches one gpu.Device run takes from a submission.
const MAX_RUN = 256;
const MAX_RUN_PARAMS = 2 * spirv.MAX_BINDINGS + MAX_PUSH_BYTES / 4 + 8;
const STAGING_BYTES = 1 << 20;
const GROUP = 64;
const MAX_GROUPS: u32 = 65535;

const NONE: u32 = 0xffff_ffff;
const WHOLE_SIZE: u64 = ~@as(u64, 0);

const DescType = struct {
    const uniform_buffer = 6;
    const storage_buffer = 7;
    const uniform_buffer_dynamic = 8;
    const storage_buffer_dynamic = 9;
};

// ── The lock and the clock ─────────────────────────────────────────────────

var lock_word = std.atomic.Value(u32).init(0);

fn lock() void {
    while (lock_word.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) yieldCpu();
}
fn unlock() void {
    lock_word.store(0, .release);
}
fn yieldCpu() void {
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.syscall0(.sched_yield);
    } else std.atomic.spinLoopHint();
}

fn nowNs() u64 {
    if (comptime builtin.os.tag != .linux) return 0;
    const linux = std.os.linux;
    var ts: linux.timespec = undefined;
    _ = linux.syscall2(.clock_gettime, @backingInt(linux.CLOCK.MONOTONIC), @intFromPtr(&ts));
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ── Objects ────────────────────────────────────────────────────────────────

const Hdr = extern struct { loader: usize };

const Tag = enum(u8) { memory = 1, buffer, set_layout, pipeline_layout, pool, set, shader, pipeline, cmd_pool, fence, semaphore, cache };

fn handle(tag: Tag, i: u32) u64 {
    return @as(u64, @intFromEnum(tag)) << 48 | (@as(u64, i) + 1);
}
fn unhandle(tag: Tag, h: u64) ?u32 {
    if (h >> 48 != @intFromEnum(tag)) return null;
    const lo: u32 = @truncate(h);
    if (lo == 0) return null;
    return lo - 1;
}

const Instance = struct { live: bool, api: u32 };
const Device = struct {
    live: bool,
    inst: u32,
    robust: bool,
    lost: bool,
    last_fence: u64,
    copy32: ?gpu.Program,
    copy8: ?gpu.Program,
    fill32: ?gpu.Program,
    staging: gpu.Buffer,
    staging_used: u64,
    staging_fence: u64,
    readback: gpu.Buffer,
    dummy: gpu.Buffer,
};
const MemType = struct { flags: u32, heap: u32, kind: gpu.Kind };
const Memory = struct {
    live: bool,
    dev: u32,
    buf: gpu.Buffer,
    size: u64,
    host: bool,
    mapped: bool,
    dirty: bool,
    dirty_fence: u64,
};
const Buffer = struct { live: bool, dev: u32, size: u64, usage: u32, mem: u32, offset: u64 };
const LayoutBinding = struct { binding: u32, dtype: u32, count: u32, first: u32, dyn_first: u32 };
const SetLayout = struct {
    live: bool,
    destroyed: bool,
    refs: u32,
    n: u32,
    b: [MAX_LAYOUT_BINDINGS]LayoutBinding,
    n_desc: u32,
    n_dyn: u32,
};
const Desc = struct { buf: u32, offset: u64, range: u64 };
const Pool = struct { live: bool, dev: u32, flags: u32, max_sets: u32, n_sets: u32, max_desc: u32, used_desc: u32 };
const Set = struct { live: bool, pool: u32, layout: u32, first: u32, n: u32 };
const PipelineLayout = struct { live: bool, n_sets: u32, sets: [MAX_SETS_PER_LAYOUT]u32, push_bytes: u32 };
const Shader = struct { live: bool, at: u32, n: u32 };
const Pipeline = struct { live: bool, dev: u32, prog: gpu.Program, info: spirv.Info, writes: u32, param_words: u32 };
const CmdPool = struct { live: bool, dev: u32, flags: u32 };
const CbState = enum(u8) { initial, recording, executable, invalid };
const CmdBuf = struct {
    live: bool,
    pool: u32,
    dev: u32,
    state: CbState,
    blocks: [MAX_CB_BLOCKS]u16,
    n_blocks: u32,
    used: u32,
    failed: bool,
};
const Fence = struct { live: bool, signaled: bool, pending: u64 };
const Pending = struct { value: u64, fence: u64 };
const Semaphore = struct {
    live: bool,
    timeline: bool,
    value: u64,
    pend: [MAX_PENDING]Pending,
    n_pend: u32,
    signaled: bool,
};

/// A fixed set of blocks, handed out in runs (first fit).
fn Bitmap(comptime n: usize) type {
    return struct {
        bits: [n / 64]u64 = [_]u64{0} ** (n / 64),
        const Self = @This();
        fn get(s: *const Self, i: usize) bool {
            return s.bits[i / 64] >> @intCast(i % 64) & 1 != 0;
        }
        fn put(s: *Self, i: usize, v: bool) void {
            const m = @as(u64, 1) << @intCast(i % 64);
            if (v) s.bits[i / 64] |= m else s.bits[i / 64] &= ~m;
        }
        /// `count` free blocks in a row, now taken; their first.
        fn take(s: *Self, count: usize) ?u32 {
            if (count == 0) return 0;
            var run: usize = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (run == 0 and i % 64 == 0 and s.bits[i / 64] == ~@as(u64, 0)) {
                    i += 63;
                    continue;
                }
                if (s.get(i)) {
                    run = 0;
                    continue;
                }
                run += 1;
                if (run == count) {
                    const first = i + 1 - count;
                    for (first..i + 1) |j| s.put(j, true);
                    return @intCast(first);
                }
            }
            return null;
        }
        fn give(s: *Self, first: u32, count: usize) void {
            for (first..first + count) |j| s.put(j, false);
        }
    };
}

const T = struct {
    var ready = false;
    var the_gpu: ?Gpu = null;
    var gpu_tried = false;
    var mem_types: [3]MemType = undefined;
    var n_mem_types: u32 = 0;
    var inst_hdr: [MAX_INSTANCES]Hdr = undefined;
    var phys_hdr: [MAX_INSTANCES]Hdr = undefined;
    var instances: [MAX_INSTANCES]Instance = undefined;
    var dev_hdr: [MAX_DEVICES]Hdr = undefined;
    var queue_hdr: [MAX_DEVICES]Hdr = undefined;
    var devices: [MAX_DEVICES]Device = undefined;
    var memories: [MAX_MEMORY]Memory = undefined;
    var buffers: [MAX_BUFFERS]Buffer = undefined;
    var set_layouts: [MAX_SET_LAYOUTS]SetLayout = undefined;
    var pipeline_layouts: [MAX_PIPELINE_LAYOUTS]PipelineLayout = undefined;
    var pools: [MAX_POOLS]Pool = undefined;
    var sets: [MAX_SETS]Set = undefined;
    var descs: [MAX_DESCRIPTORS]Desc = undefined;
    var desc_map: Bitmap(MAX_DESCRIPTORS) = .{};
    var shaders: [MAX_SHADERS]Shader = undefined;
    var shader_words: [SHADER_WORDS]u32 = undefined;
    var shader_map: Bitmap(SHADER_WORDS / SHADER_BLOCK_WORDS) = .{};
    var pipelines: [MAX_PIPELINES]Pipeline = undefined;
    var cmd_pools: [MAX_CMD_POOLS]CmdPool = undefined;
    var cb_hdr: [MAX_CMDBUFS]Hdr = undefined;
    var cbs: [MAX_CMDBUFS]CmdBuf = undefined;
    var cmd_blocks: [MAX_CMD_BLOCKS][CMD_BLOCK]u8 align(8) = undefined;
    var cmd_map: Bitmap(MAX_CMD_BLOCKS) = .{};
    var fences: [MAX_FENCES]Fence = undefined;
    var semaphores: [MAX_SEMAPHORES]Semaphore = undefined;
    var caches: [MAX_CACHES]bool = undefined;
    // compiling
    var scratch: spirv.Scratch = undefined;
    var insts: [1 << 16]kir.Inst = undefined;
    var tys: [1 << 16]kir.Ty = undefined;
    var kernel: kir.Kernel = undefined;
    var code: [2 << 20]u8 align(16) = undefined;
    // running
    var ds: [MAX_RUN]gpu.Dispatch = undefined;
    var ds_bufs: [MAX_RUN][spirv.MAX_BINDINGS]gpu.Buffer = undefined;
    var ds_params: [MAX_RUN][MAX_RUN_PARAMS]u32 = undefined;
    var n_ds: u32 = 0;
};

fn markAll(comptime field: []const u8) void {
    for (&@field(T, field)) |*x| x.live = false;
}

fn ready() void {
    if (T.ready) return;
    for (&T.instances) |*x| x.live = false;
    markAll("devices");
    markAll("memories");
    markAll("buffers");
    markAll("set_layouts");
    markAll("pipeline_layouts");
    markAll("pools");
    markAll("sets");
    markAll("shaders");
    markAll("pipelines");
    markAll("cmd_pools");
    markAll("cbs");
    markAll("fences");
    markAll("semaphores");
    for (&T.caches) |*c| c.* = false;
    T.desc_map = .{};
    T.shader_map = .{};
    T.cmd_map = .{};
    T.ready = true;
}

/// Back to no objects and no GPU (tests: between cases, with every object gone).
pub fn reset() void {
    lock();
    defer unlock();
    T.ready = false;
    T.the_gpu = null;
    T.gpu_tried = false;
    ready();
}

fn theGpu() ?*Gpu {
    if (!T.gpu_tried) {
        T.gpu_tried = true;
        if (opener) |o| T.the_gpu = o();
        if (T.the_gpu) |*g| setMemTypes(g.dev.caps);
    }
    return if (T.the_gpu) |*g| g else null;
}

const MEM_DEVICE_LOCAL: u32 = 1;
const MEM_HOST_VISIBLE: u32 = 2;
const MEM_HOST_COHERENT: u32 = 4;
const MEM_HOST_CACHED: u32 = 8;

fn setMemTypes(caps: gpu.Caps) void {
    if (caps.memory == .discrete) {
        T.mem_types[0] = .{ .flags = MEM_DEVICE_LOCAL, .heap = 0, .kind = .device };
        T.mem_types[1] = .{ .flags = MEM_HOST_VISIBLE | MEM_HOST_COHERENT | MEM_HOST_CACHED, .heap = 1, .kind = .host };
        T.mem_types[2] = .{ .flags = MEM_DEVICE_LOCAL | MEM_HOST_VISIBLE | MEM_HOST_COHERENT, .heap = 0, .kind = .upload };
        T.n_mem_types = 3;
    } else {
        T.mem_types[0] = .{ .flags = MEM_DEVICE_LOCAL | MEM_HOST_VISIBLE | MEM_HOST_COHERENT | MEM_HOST_CACHED, .heap = 0, .kind = .host };
        T.n_mem_types = 1;
    }
}

fn findFree(comptime field: []const u8) ?u32 {
    for (&@field(T, field), 0..) |*x, i| if (!x.live) return @intCast(i);
    return null;
}

/// The index a dispatchable handle names in its table.
fn hdrIndex(comptime n: usize, table: *const [n]Hdr, h: ?*anyopaque) ?u32 {
    const p = @intFromPtr(h orelse return null);
    const base = @intFromPtr(&table[0]);
    if (p < base) return null;
    const off = p - base;
    if (off % @sizeOf(Hdr) != 0 or off / @sizeOf(Hdr) >= n) return null;
    return @intCast(off / @sizeOf(Hdr));
}

fn devOf(h: ?*anyopaque) ?u32 {
    const i = hdrIndex(MAX_DEVICES, &T.dev_hdr, h) orelse return null;
    return if (T.devices[i].live) i else null;
}

fn pNextChain(p: ?*const anyopaque) ?*const abi.BaseInStructure {
    return @ptrCast(@alignCast(p));
}
fn findIn(p: ?*const anyopaque, stype: u32) ?*const abi.BaseInStructure {
    var cur = pNextChain(p);
    while (cur) |c| {
        if (c.sType == stype) return c;
        cur = @ptrCast(c.pNext);
    }
    return null;
}

fn nextOut(c: *abi.BaseOutStructure) ?*abi.BaseOutStructure {
    return @ptrCast(c.pNext);
}

fn cstr(p: ?[*:0]const u8) []const u8 {
    return std.mem.span(p orelse return "");
}

fn copyName(dst: []u8, name: []const u8) void {
    @memset(dst, 0);
    const n = @min(dst.len - 1, name.len);
    @memcpy(dst[0..n], name[0..n]);
}

/// Vulkan's two-call enumeration: the count, or as many as fit (INCOMPLETE).
fn enumerate(comptime E: type, items: []const E, count: ?*u32, out: ?[*]E) Result {
    const c = count orelse return R.error_initialization_failed;
    const dst = out orelse {
        c.* = @intCast(items.len);
        return R.success;
    };
    const n = @min(c.*, items.len);
    for (0..n) |i| dst[i] = items[i];
    c.* = @intCast(n);
    return if (n < items.len) R.incomplete else R.success;
}

fn extList(comptime exts: []const Ext) [exts.len]abi.ExtensionProperties {
    var out: [exts.len]abi.ExtensionProperties = undefined;
    for (exts, 0..) |e, i| {
        copyName(&out[i].extensionName, e.name);
        out[i].specVersion = e.version;
    }
    return out;
}

fn hasExt(comptime exts: []const Ext, name: []const u8) bool {
    for (exts) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

// ── Global and instance commands ───────────────────────────────────────────

fn enumerateInstanceVersion(v: ?*u32) callconv(.c) Result {
    (v orelse return R.error_initialization_failed).* = INSTANCE_VERSION;
    return R.success;
}

fn enumerateInstanceExtensionProperties(layer: ?[*:0]const u8, count: ?*u32, out: ?[*]abi.ExtensionProperties) callconv(.c) Result {
    if (layer != null) return R.error_layer_not_present;
    const list = extList(&instance_extensions);
    return enumerate(abi.ExtensionProperties, &list, count, out);
}

fn enumerateInstanceLayerProperties(count: ?*u32, out: ?[*]abi.LayerProperties) callconv(.c) Result {
    return enumerate(abi.LayerProperties, &.{}, count, out);
}

fn createInstance(info: ?*const abi.InstanceCreateInfo, _: ?*const anyopaque, out: ?*?*anyopaque) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    ready();
    for (0..ci.enabledExtensionCount) |i| {
        const name = cstr(ci.ppEnabledExtensionNames.?[i]);
        if (!hasExt(&instance_extensions, name)) {
            say("vkCreateInstance: extension {s} is not supported", .{name});
            return R.error_extension_not_present;
        }
    }
    const i = findFree("instances") orelse return R.error_out_of_host_memory;
    var api: u32 = makeVersion(1, 0, 0);
    if (ci.pApplicationInfo) |app| {
        if (app[0].apiVersion != 0) api = app[0].apiVersion;
    }
    T.instances[i] = .{ .live = true, .api = api };
    T.inst_hdr[i] = .{ .loader = ICD_LOADER_MAGIC };
    T.phys_hdr[i] = .{ .loader = ICD_LOADER_MAGIC };
    (out orelse return R.error_initialization_failed).* = &T.inst_hdr[i];
    return R.success;
}

fn destroyInstance(inst: ?*anyopaque, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = hdrIndex(MAX_INSTANCES, &T.inst_hdr, inst) orelse return;
    T.instances[i].live = false;
}

fn instOf(h: ?*anyopaque) ?u32 {
    const i = hdrIndex(MAX_INSTANCES, &T.inst_hdr, h) orelse return null;
    return if (T.instances[i].live) i else null;
}
fn physOf(h: ?*anyopaque) ?u32 {
    const i = hdrIndex(MAX_INSTANCES, &T.phys_hdr, h) orelse return null;
    return if (T.instances[i].live) i else null;
}

fn enumeratePhysicalDevices(inst: ?*anyopaque, count: ?*u32, out: ?[*]?*anyopaque) callconv(.c) Result {
    lock();
    defer unlock();
    const i = instOf(inst) orelse return R.error_initialization_failed;
    if (theGpu() == null) return enumerate(?*anyopaque, &.{}, count, out);
    const list = [1]?*anyopaque{&T.phys_hdr[i]};
    return enumerate(?*anyopaque, &list, count, out);
}

fn enumeratePhysicalDeviceGroups(inst: ?*anyopaque, count: ?*u32, out: ?[*]abi.PhysicalDeviceGroupProperties) callconv(.c) Result {
    lock();
    defer unlock();
    const i = instOf(inst) orelse return R.error_initialization_failed;
    const c = count orelse return R.error_initialization_failed;
    const n: u32 = if (theGpu() != null) 1 else 0;
    const dst = out orelse {
        c.* = n;
        return R.success;
    };
    if (n == 0 or c.* == 0) {
        c.* = 0;
        return if (n == 0) R.success else R.incomplete;
    }
    dst[0].physicalDeviceCount = 1;
    dst[0].physicalDevices[0] = &T.phys_hdr[i];
    dst[0].subsetAllocation = 0;
    c.* = 1;
    return R.success;
}

fn features() abi.PhysicalDeviceFeatures {
    var f = std.mem.zeroes(abi.PhysicalDeviceFeatures);
    f.robustBufferAccess = 1;
    return f;
}

fn getPhysicalDeviceFeatures(_: ?*anyopaque, out: ?*abi.PhysicalDeviceFeatures) callconv(.c) void {
    (out orelse return).* = features();
}

fn fillFeatureChain(chain: ?*anyopaque) void {
    var cur: ?*abi.BaseOutStructure = @ptrCast(@alignCast(chain));
    while (cur) |c| : (cur = nextOut(c)) {
        switch (c.sType) {
            ST.physical_device_timeline_semaphore_features => {
                const tf: *abi.PhysicalDeviceTimelineSemaphoreFeatures = @ptrCast(@alignCast(c));
                tf.timelineSemaphore = 1;
            },
            else => {},
        }
    }
}

fn getPhysicalDeviceFeatures2(_: ?*anyopaque, out: ?*abi.PhysicalDeviceFeatures2) callconv(.c) void {
    const o = out orelse return;
    o.features = features();
    fillFeatureChain(o.pNext);
}

fn limits(caps: gpu.Caps) abi.PhysicalDeviceLimits {
    var l = std.mem.zeroes(abi.PhysicalDeviceLimits);
    l.maxUniformBufferRange = 65536;
    l.maxStorageBufferRange = 1 << 31;
    l.maxPushConstantsSize = MAX_PUSH_BYTES;
    l.maxMemoryAllocationCount = MAX_MEMORY;
    l.bufferImageGranularity = 1;
    l.maxBoundDescriptorSets = MAX_SETS_PER_LAYOUT;
    l.maxPerStageDescriptorUniformBuffers = spirv.MAX_BINDINGS / 2;
    l.maxPerStageDescriptorStorageBuffers = spirv.MAX_BINDINGS / 2;
    l.maxPerStageResources = spirv.MAX_BINDINGS;
    l.maxDescriptorSetUniformBuffers = MAX_LAYOUT_BINDINGS;
    l.maxDescriptorSetUniformBuffersDynamic = MAX_DYNAMIC / 2;
    l.maxDescriptorSetStorageBuffers = MAX_LAYOUT_BINDINGS;
    l.maxDescriptorSetStorageBuffersDynamic = MAX_DYNAMIC / 2;
    l.maxComputeSharedMemorySize = caps.shared_bytes;
    l.maxComputeWorkGroupCount = .{ MAX_GROUPS, MAX_GROUPS, MAX_GROUPS };
    l.maxComputeWorkGroupInvocations = caps.max_group;
    l.maxComputeWorkGroupSize = .{ caps.max_group, caps.max_group, @min(caps.max_group, 64) };
    l.minMemoryMapAlignment = 64;
    l.minTexelBufferOffsetAlignment = 16;
    l.minUniformBufferOffsetAlignment = 16;
    l.minStorageBufferOffsetAlignment = 16;
    l.timestampPeriod = if (caps.timestamp_hz != 0) 1.0e9 / @as(f32, @floatFromInt(caps.timestamp_hz)) else 1.0;
    l.discreteQueuePriorities = 2;
    l.optimalBufferCopyOffsetAlignment = 4;
    l.optimalBufferCopyRowPitchAlignment = 4;
    l.nonCoherentAtomSize = 64;
    return l;
}

fn properties() abi.PhysicalDeviceProperties {
    const g = theGpu().?;
    const caps = g.dev.caps;
    var p = std.mem.zeroes(abi.PhysicalDeviceProperties);
    p.apiVersion = DEVICE_VERSION;
    p.driverVersion = DRIVER_VERSION;
    p.vendorID = if (g.vendor_id != 0) g.vendor_id else switch (caps.vendor) {
        .nvidia => 0x10de,
        .qualcomm => 0x5143,
        .amd => 0x1002,
        .intel => 0x8086,
        .apple => 0x106b,
        .emulated => 0,
    };
    p.deviceID = g.device_id;
    p.deviceType = if (caps.vendor == .emulated) 4 else if (caps.memory == .discrete) 2 else 1;
    var name: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&name, "Galaxy Vulkan ({s})", .{caps.name}) catch name[0..];
    copyName(&p.deviceName, text);
    const uuid = "galaxy-vk-0.1.0\x00";
    @memcpy(&p.pipelineCacheUUID, uuid[0..16]);
    p.limits = limits(caps);
    return p;
}

fn getPhysicalDeviceProperties(_: ?*anyopaque, out: ?*abi.PhysicalDeviceProperties) callconv(.c) void {
    lock();
    defer unlock();
    if (theGpu() == null) return;
    (out orelse return).* = properties();
}

fn getPhysicalDeviceProperties2(_: ?*anyopaque, out: ?*abi.PhysicalDeviceProperties2) callconv(.c) void {
    lock();
    defer unlock();
    const g = theGpu() orelse return;
    const o = out orelse return;
    o.properties = properties();
    var cur: ?*abi.BaseOutStructure = @ptrCast(@alignCast(o.pNext));
    while (cur) |c| : (cur = nextOut(c)) {
        switch (c.sType) {
            ST.physical_device_timeline_semaphore_properties => {
                const tp: *abi.PhysicalDeviceTimelineSemaphoreProperties = @ptrCast(@alignCast(c));
                tp.maxTimelineSemaphoreValueDifference = std.math.maxInt(i64);
            },
            ST.physical_device_subgroup_properties => {
                const sp: *abi.PhysicalDeviceSubgroupProperties = @ptrCast(@alignCast(c));
                sp.subgroupSize = g.dev.caps.subgroup;
                sp.supportedStages = 0x20; // compute
                sp.supportedOperations = 0; // (no subgroup operations in the SPIR-V front end yet)
                sp.quadOperationsInAllStages = 0;
            },
            ST.physical_device_maintenance_3_properties => {
                const mp: *abi.PhysicalDeviceMaintenance3Properties = @ptrCast(@alignCast(c));
                mp.maxPerSetDescriptors = MAX_LAYOUT_BINDINGS;
                mp.maxMemoryAllocationSize = g.dev.caps.device_bytes;
            },
            ST.physical_device_id_properties => {
                const ip: *abi.PhysicalDeviceIDProperties = @ptrCast(@alignCast(c));
                const uuid = "galaxy-vk-device";
                @memcpy(&ip.deviceUUID, uuid[0..16]);
                const duuid = "galaxy-vk-driver";
                @memcpy(&ip.driverUUID, duuid[0..16]);
                @memset(&ip.deviceLUID, 0);
                ip.deviceNodeMask = 0;
                ip.deviceLUIDValid = 0;
            },
            else => {},
        }
    }
}

const queue_family = abi.QueueFamilyProperties{
    .queueFlags = 0x2 | 0x4, // COMPUTE | TRANSFER
    .queueCount = 1,
    .timestampValidBits = 0,
    .minImageTransferGranularity = .{ .width = 1, .height = 1, .depth = 1 },
};

fn getPhysicalDeviceQueueFamilyProperties(_: ?*anyopaque, count: ?*u32, out: ?[*]abi.QueueFamilyProperties) callconv(.c) void {
    _ = enumerate(abi.QueueFamilyProperties, &.{queue_family}, count, out);
}

fn getPhysicalDeviceQueueFamilyProperties2(_: ?*anyopaque, count: ?*u32, out: ?[*]abi.QueueFamilyProperties2) callconv(.c) void {
    const c = count orelse return;
    const dst = out orelse {
        c.* = 1;
        return;
    };
    if (c.* == 0) return;
    dst[0].queueFamilyProperties = queue_family;
    c.* = 1;
}

fn memoryProperties() abi.PhysicalDeviceMemoryProperties {
    var mp = std.mem.zeroes(abi.PhysicalDeviceMemoryProperties);
    const g = theGpu() orelse return mp;
    mp.memoryTypeCount = T.n_mem_types;
    for (T.mem_types[0..T.n_mem_types], 0..) |t, i| mp.memoryTypes[i] = .{ .propertyFlags = t.flags, .heapIndex = t.heap };
    const caps = g.dev.caps;
    mp.memoryHeaps[0] = .{ .size = if (caps.device_bytes != 0) caps.device_bytes else 1 << 30, .flags = 1 };
    mp.memoryHeapCount = 1;
    if (caps.memory == .discrete) {
        mp.memoryHeaps[1] = .{ .size = 4 << 30, .flags = 0 };
        mp.memoryHeapCount = 2;
    }
    return mp;
}

fn getPhysicalDeviceMemoryProperties(_: ?*anyopaque, out: ?*abi.PhysicalDeviceMemoryProperties) callconv(.c) void {
    lock();
    defer unlock();
    (out orelse return).* = memoryProperties();
}

fn getPhysicalDeviceMemoryProperties2(_: ?*anyopaque, out: ?*abi.PhysicalDeviceMemoryProperties2) callconv(.c) void {
    lock();
    defer unlock();
    (out orelse return).memoryProperties = memoryProperties();
}

fn getPhysicalDeviceFormatProperties(_: ?*anyopaque, _: u32, out: ?*abi.FormatProperties) callconv(.c) void {
    // (no images yet: no format has a feature)
    (out orelse return).* = std.mem.zeroes(abi.FormatProperties);
}

fn getPhysicalDeviceFormatProperties2(_: ?*anyopaque, _: u32, out: ?*abi.FormatProperties2) callconv(.c) void {
    (out orelse return).formatProperties = std.mem.zeroes(abi.FormatProperties);
}

fn getPhysicalDeviceImageFormatProperties(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: u32, _: ?*abi.ImageFormatProperties) callconv(.c) Result {
    return R.error_format_not_supported;
}

fn getPhysicalDeviceImageFormatProperties2(_: ?*anyopaque, _: ?*const abi.PhysicalDeviceImageFormatInfo2, _: ?*abi.ImageFormatProperties2) callconv(.c) Result {
    return R.error_format_not_supported;
}

fn getPhysicalDeviceSparseImageFormatProperties(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: u32, count: ?*u32, _: ?*anyopaque) callconv(.c) void {
    if (count) |c| c.* = 0;
}

fn getPhysicalDeviceSparseImageFormatProperties2(_: ?*anyopaque, _: ?*const anyopaque, count: ?*u32, _: ?*anyopaque) callconv(.c) void {
    if (count) |c| c.* = 0;
}

fn getPhysicalDeviceExternalBufferProperties(_: ?*anyopaque, _: ?*const anyopaque, out: ?*abi.ExternalBufferProperties) callconv(.c) void {
    (out orelse return).externalMemoryProperties = std.mem.zeroes(abi.ExternalMemoryProperties);
}

fn getPhysicalDeviceExternalFenceProperties(_: ?*anyopaque, _: ?*const anyopaque, out: ?*abi.ExternalFenceProperties) callconv(.c) void {
    const o = out orelse return;
    o.exportFromImportedHandleTypes = 0;
    o.compatibleHandleTypes = 0;
    o.externalFenceFeatures = 0;
}

fn getPhysicalDeviceExternalSemaphoreProperties(_: ?*anyopaque, _: ?*const anyopaque, out: ?*abi.ExternalSemaphoreProperties) callconv(.c) void {
    const o = out orelse return;
    o.exportFromImportedHandleTypes = 0;
    o.compatibleHandleTypes = 0;
    o.externalSemaphoreFeatures = 0;
}

fn enumerateDeviceExtensionProperties(_: ?*anyopaque, layer: ?[*:0]const u8, count: ?*u32, out: ?[*]abi.ExtensionProperties) callconv(.c) Result {
    if (layer != null) return R.error_layer_not_present;
    const list = extList(&device_extensions);
    return enumerate(abi.ExtensionProperties, &list, count, out);
}

fn enumerateDeviceLayerProperties(_: ?*anyopaque, count: ?*u32, out: ?[*]abi.LayerProperties) callconv(.c) Result {
    return enumerate(abi.LayerProperties, &.{}, count, out);
}

// ── Devices ────────────────────────────────────────────────────────────────

fn featuresOk(fp: *const abi.PhysicalDeviceFeatures) bool {
    const want: *const [@sizeOf(abi.PhysicalDeviceFeatures) / 4]u32 = @ptrCast(fp);
    const have_s = features();
    const have: *const [@sizeOf(abi.PhysicalDeviceFeatures) / 4]u32 = @ptrCast(&have_s);
    for (want, have) |w, h| if (w != 0 and h == 0) return false;
    return true;
}

fn createDevice(phys: ?*anyopaque, info: ?*const abi.DeviceCreateInfo, _: ?*const anyopaque, out: ?*?*anyopaque) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const pi = physOf(phys) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    for (0..ci.enabledExtensionCount) |i| {
        const name = cstr(ci.ppEnabledExtensionNames.?[i]);
        if (!hasExt(&device_extensions, name)) {
            say("vkCreateDevice: extension {s} is not supported", .{name});
            return R.error_extension_not_present;
        }
    }
    for (0..ci.queueCreateInfoCount) |i| {
        const q = ci.pQueueCreateInfos.?[i];
        if (q.queueFamilyIndex != 0 or q.queueCount > 1) return R.error_initialization_failed;
    }
    var robust = false;
    if (ci.pEnabledFeatures) |fp| {
        if (!featuresOk(&fp[0])) return R.error_feature_not_present;
        robust = fp[0].robustBufferAccess != 0;
    }
    if (findIn(ci.pNext, ST.physical_device_features_2)) |base| {
        const f2: *const abi.PhysicalDeviceFeatures2 = @ptrCast(@alignCast(base));
        if (!featuresOk(&f2.features)) return R.error_feature_not_present;
        robust = robust or f2.features.robustBufferAccess != 0;
    }
    const di = findFree("devices") orelse return R.error_too_many_objects;
    const dev = g.dev;
    var d = Device{
        .live = true,
        .inst = pi,
        .robust = robust,
        .lost = false,
        .last_fence = 0,
        .copy32 = null,
        .copy8 = null,
        .fill32 = null,
        .staging = undefined,
        .staging_used = 0,
        .staging_fence = 0,
        .readback = undefined,
        .dummy = undefined,
    };
    d.staging = dev.alloc(STAGING_BYTES, .upload) catch return R.error_out_of_device_memory;
    d.readback = dev.alloc(4096, .host) catch {
        dev.free(d.staging);
        return R.error_out_of_device_memory;
    };
    d.dummy = dev.alloc(4096, .device) catch {
        dev.free(d.staging);
        dev.free(d.readback);
        return R.error_out_of_device_memory;
    };
    d.copy32 = internalKernel(g, .copy32);
    d.copy8 = internalKernel(g, .copy8);
    d.fill32 = internalKernel(g, .fill32);
    if (d.copy32 == null or d.copy8 == null or d.fill32 == null) {
        say("vkCreateDevice: the copy kernels did not compile or load", .{});
        dropDevice(g, &d);
        return R.error_initialization_failed;
    }
    T.devices[di] = d;
    T.dev_hdr[di] = .{ .loader = ICD_LOADER_MAGIC };
    T.queue_hdr[di] = .{ .loader = ICD_LOADER_MAGIC };
    (out orelse return R.error_initialization_failed).* = &T.dev_hdr[di];
    return R.success;
}

fn dropDevice(g: *Gpu, d: *Device) void {
    const dev = g.dev;
    inline for (.{ "copy32", "copy8", "fill32" }) |f| {
        if (@field(d, f)) |*p| dev.unload(p);
        @field(d, f) = null;
    }
    dev.free(d.staging);
    dev.free(d.readback);
    dev.free(d.dummy);
}

fn destroyDevice(h: ?*anyopaque, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const di = devOf(h) orelse return;
    const g = theGpu() orelse return;
    const d = &T.devices[di];
    // (the app has waited for its work; free what is left of the device's)
    if (d.last_fence != 0) g.dev.wait(d.last_fence, 5_000_000) catch {};
    for (&T.pipelines) |*p| if (p.live and p.dev == di) {
        g.dev.unload(&p.prog);
        p.live = false;
    };
    for (&T.memories) |*m| if (m.live and m.dev == di) {
        g.dev.free(m.buf);
        m.live = false;
    };
    for (&T.buffers) |*b| if (b.live and b.dev == di) {
        b.live = false;
    };
    for (&T.cbs) |*cb| if (cb.live and cb.dev == di) freeCb(cb);
    for (&T.cmd_pools) |*p| if (p.live and p.dev == di) {
        p.live = false;
    };
    for (&T.pools, 0..) |*pl, pi| if (pl.live and pl.dev == di) dropPool(@intCast(pi), true);
    dropDevice(g, d);
    d.live = false;
}

fn getDeviceQueue(h: ?*anyopaque, family: u32, index: u32, out: ?*?*anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const di = devOf(h) orelse return;
    if (family != 0 or index != 0) return;
    (out orelse return).* = &T.queue_hdr[di];
}

fn getDeviceQueue2(h: ?*anyopaque, info: ?*const abi.DeviceQueueInfo2, out: ?*?*anyopaque) callconv(.c) void {
    const qi = info orelse return;
    getDeviceQueue(h, qi.queueFamilyIndex, qi.queueIndex, out);
}

fn queueDev(q: ?*anyopaque) ?u32 {
    const i = hdrIndex(MAX_DEVICES, &T.queue_hdr, q) orelse return null;
    return if (T.devices[i].live) i else null;
}

// ── The copy and fill kernels ──────────────────────────────────────────────

const Internal = enum { copy32, copy8, fill32 };

fn internalKernel(g: *Gpu, which: Internal) ?gpu.Program {
    var k = kir.Kernel.init(.{ .insts = &T.insts, .tys = &T.tys }, @tagName(which), .{ GROUP, 1, 1 });
    const r = kir.r;
    const u = kir.u;
    const src = if (which == .fill32) 0 else k.binding();
    const dst = k.binding();
    const so = k.param(.u32, 0);
    const do = k.param(.u32, 1);
    const n = k.param(.u32, 2);
    const i = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(i), r(n))));
    switch (which) {
        .copy32 => {
            const off = k.op2(.shl, .u32, r(i), u(2));
            const v = k.load(.u32, kir.global(src, 32), r(k.op2(.iadd, .u32, r(so), r(off))));
            k.store(.u32, kir.global(dst, 32), r(k.op2(.iadd, .u32, r(do), r(off))), r(v));
        },
        .copy8 => {
            const v = k.load(.u32, kir.global(src, 8), r(k.op2(.iadd, .u32, r(so), r(i))));
            k.store(.u32, kir.global(dst, 8), r(k.op2(.iadd, .u32, r(do), r(i))), r(v));
        },
        .fill32 => {
            // (params: offset, words, value)
            const off = k.op2(.shl, .u32, r(i), u(2));
            const value = k.param(.u32, 3);
            k.store(.u32, kir.global(dst, 32), r(k.op2(.iadd, .u32, r(so), r(off))), r(value));

        },
    }
    k.endif();
    k.finish() catch return null;
    var work = gpu.Work.init(g.work);
    const bin = g.compile(&k, g.dev.caps, &work, &T.code) catch |e| {
        say("the {s} kernel did not compile ({s})", .{ @tagName(which), @errorName(e) });
        return null;
    };
    return g.dev.load(&bin) catch null;
}

// ── Memory ─────────────────────────────────────────────────────────────────

fn allocateMemory(h: ?*anyopaque, info: ?*const abi.MemoryAllocateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ai = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = devOf(h) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    if (ai.memoryTypeIndex >= T.n_mem_types) return R.error_out_of_device_memory;
    const t = T.mem_types[ai.memoryTypeIndex];
    const mi = findFree("memories") orelse return R.error_too_many_objects;
    const size = @max(ai.allocationSize, 4);
    const b = g.dev.alloc(size, t.kind) catch return R.error_out_of_device_memory;
    T.memories[mi] = .{ .live = true, .dev = di, .buf = b, .size = ai.allocationSize, .host = t.flags & MEM_HOST_VISIBLE != 0 and b.cpu.len != 0, .mapped = false, .dirty = false, .dirty_fence = 0 };
    (out orelse return R.error_initialization_failed).* = handle(.memory, mi);
    return R.success;
}

fn memOf(h: u64) ?*Memory {
    const i = unhandle(.memory, h) orelse return null;
    return if (T.memories[i].live) &T.memories[i] else null;
}

fn freeMemory(dh: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    _ = devOf(dh) orelse return;
    const m = memOf(h) orelse return;
    const g = theGpu() orelse return;
    g.dev.free(m.buf);
    m.live = false;
}

fn mapMemory(dh: ?*anyopaque, h: u64, offset: u64, size: u64, _: u32, out: ?*?*anyopaque) callconv(.c) Result {
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    const m = memOf(h) orelse return R.error_memory_map_failed;
    if (!m.host or offset >= m.size) return R.error_memory_map_failed;
    if (size != WHOLE_SIZE and offset + size > m.size) return R.error_memory_map_failed;
    const g = theGpu().?;
    if (m.dirty and g.dev.done(m.dirty_fence)) pull(g, m);
    m.mapped = true;
    (out orelse return R.error_memory_map_failed).* = m.buf.cpu.ptr + offset;
    return R.success;
}

fn unmapMemory(dh: ?*anyopaque, h: u64) callconv(.c) void {
    lock();
    defer unlock();
    _ = devOf(dh) orelse return;
    const m = memOf(h) orelse return;
    // (what was written goes to the GPU at the next submission)
    const g = theGpu().?;
    g.dev.toDevice(m.buf, 0, m.buf.cpu.len);
    m.mapped = false;
}

fn flushMappedMemoryRanges(dh: ?*anyopaque, n: u32, ranges: ?[*]const abi.MappedMemoryRange) callconv(.c) Result {
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu().?;
    for (0..n) |i| {
        const rg = ranges.?[i];
        const m = memOf(rg.memory) orelse continue;
        const len = if (rg.size == WHOLE_SIZE) m.buf.cpu.len - rg.offset else rg.size;
        g.dev.toDevice(m.buf, rg.offset, len);
    }
    return R.success;
}

fn invalidateMappedMemoryRanges(dh: ?*anyopaque, n: u32, ranges: ?[*]const abi.MappedMemoryRange) callconv(.c) Result {
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu().?;
    for (0..n) |i| {
        const m = memOf(ranges.?[i].memory) orelse continue;
        if (m.dirty and g.dev.done(m.dirty_fence)) pull(g, m);
    }
    return R.success;
}

fn getDeviceMemoryCommitment(_: ?*anyopaque, h: u64, out: ?*u64) callconv(.c) void {
    lock();
    defer unlock();
    const m = memOf(h) orelse return;
    (out orelse return).* = m.size;
}

/// What the GPU wrote to `m`, for the CPU.
fn pull(g: *Gpu, m: *Memory) void {
    if (m.host) g.dev.fromDevice(m.buf, 0, m.buf.cpu.len);
    m.dirty = false;
}

/// Brings back every memory the finished work wrote.
fn pullDone(g: *Gpu) void {
    for (&T.memories) |*m| {
        if (m.live and m.dirty and g.dev.done(m.dirty_fence)) pull(g, m);
    }
}

// ── Buffers ────────────────────────────────────────────────────────────────

fn createBuffer(dh: ?*anyopaque, info: ?*const abi.BufferCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const bi = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    if (bi.size > 1 << 31) return R.error_out_of_device_memory;
    const i = findFree("buffers") orelse return R.error_too_many_objects;
    T.buffers[i] = .{ .live = true, .dev = di, .size = bi.size, .usage = bi.usage, .mem = NONE, .offset = 0 };
    (out orelse return R.error_initialization_failed).* = handle(.buffer, i);
    return R.success;
}

fn bufOf(h: u64) ?*Buffer {
    const i = unhandle(.buffer, h) orelse return null;
    return if (T.buffers[i].live) &T.buffers[i] else null;
}

fn destroyBuffer(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const b = bufOf(h) orelse return;
    b.live = false;
}

fn requirements(b: *const Buffer) abi.MemoryRequirements {
    return .{ .size = std.mem.alignForward(u64, @max(b.size, 4), 16), .alignment = 256, .memoryTypeBits = (@as(u32, 1) << @intCast(T.n_mem_types)) - 1 };
}

fn getBufferMemoryRequirements(_: ?*anyopaque, h: u64, out: ?*abi.MemoryRequirements) callconv(.c) void {
    lock();
    defer unlock();
    const b = bufOf(h) orelse return;
    (out orelse return).* = requirements(b);
}

fn getBufferMemoryRequirements2(_: ?*anyopaque, info: ?*const abi.BufferMemoryRequirementsInfo2, out: ?*abi.MemoryRequirements2) callconv(.c) void {
    lock();
    defer unlock();
    const b = bufOf((info orelse return).buffer) orelse return;
    const o = out orelse return;
    o.memoryRequirements = requirements(b);
    var cur: ?*abi.BaseOutStructure = @ptrCast(@alignCast(o.pNext));
    while (cur) |c| : (cur = nextOut(c)) {
        if (c.sType == ST.memory_dedicated_requirements) {
            const dr: *abi.MemoryDedicatedRequirements = @ptrCast(@alignCast(c));
            dr.prefersDedicatedAllocation = 0;
            dr.requiresDedicatedAllocation = 0;
        }
    }
}

fn bind(bh: u64, mh: u64, offset: u64) Result {
    const b = bufOf(bh) orelse return R.error_initialization_failed;
    const m = memOf(mh) orelse return R.error_initialization_failed;
    const mi = unhandle(.memory, mh).?;
    if (offset + b.size > m.size) return R.error_out_of_device_memory;
    b.mem = mi;
    b.offset = offset;
    return R.success;
}

fn bindBufferMemory(_: ?*anyopaque, bh: u64, mh: u64, offset: u64) callconv(.c) Result {
    lock();
    defer unlock();
    return bind(bh, mh, offset);
}

fn bindBufferMemory2(_: ?*anyopaque, n: u32, infos: ?[*]const abi.BindBufferMemoryInfo) callconv(.c) Result {
    lock();
    defer unlock();
    for (0..n) |i| {
        const bi = infos.?[i];
        const res = bind(bi.buffer, bi.memory, bi.memoryOffset);
        if (res != R.success) return res;
    }
    return R.success;
}

// ── Descriptor set layouts, pools and sets ─────────────────────────────────

fn isDynamic(t: u32) bool {
    return t == DescType.uniform_buffer_dynamic or t == DescType.storage_buffer_dynamic;
}

fn createDescriptorSetLayout(_: ?*anyopaque, info: ?*const abi.DescriptorSetLayoutCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    if (ci.bindingCount > MAX_LAYOUT_BINDINGS) return R.error_out_of_host_memory;
    const i = findFree("set_layouts") orelse return R.error_too_many_objects;
    const l = &T.set_layouts[i];
    l.* = .{ .live = true, .destroyed = false, .refs = 1, .n = ci.bindingCount, .b = undefined, .n_desc = 0, .n_dyn = 0 };
    for (0..ci.bindingCount) |j| {
        const b = ci.pBindings.?[j];
        l.b[j] = .{ .binding = b.binding, .dtype = b.descriptorType, .count = b.descriptorCount, .first = 0, .dyn_first = NONE };
    }
    // in binding order: the descriptors' places, and the dynamic ones' order
    std.mem.sort(LayoutBinding, l.b[0..l.n], {}, struct {
        fn lt(_: void, a: LayoutBinding, b: LayoutBinding) bool {
            return a.binding < b.binding;
        }
    }.lt);
    for (l.b[0..l.n]) |*b| {
        b.first = l.n_desc;
        l.n_desc += b.count;
        if (isDynamic(b.dtype)) {
            b.dyn_first = l.n_dyn;
            l.n_dyn += b.count;
        }
    }
    if (l.n_dyn > MAX_DYNAMIC) {
        l.live = false;
        return R.error_out_of_host_memory;
    }
    (out orelse return R.error_initialization_failed).* = handle(.set_layout, i);
    return R.success;
}

fn unrefLayout(i: u32) void {
    const l = &T.set_layouts[i];
    l.refs -= 1;
    if (l.refs == 0) l.live = false;
}

fn destroyDescriptorSetLayout(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.set_layout, h) orelse return;
    const l = &T.set_layouts[i];
    if (!l.live or l.destroyed) return;
    l.destroyed = true;
    unrefLayout(i);
}

fn getDescriptorSetLayoutSupport(_: ?*anyopaque, info: ?*const abi.DescriptorSetLayoutCreateInfo, out: ?*abi.BaseOutStructure) callconv(.c) void {
    // (VkDescriptorSetLayoutSupport: sType, pNext, supported)
    const o = out orelse return;
    const supported: *u32 = @ptrFromInt(@intFromPtr(o) + @sizeOf(abi.BaseOutStructure));
    supported.* = @intFromBool((info orelse return).bindingCount <= MAX_LAYOUT_BINDINGS);
}

fn layoutBinding(l: *const SetLayout, binding: u32) ?*const LayoutBinding {
    for (l.b[0..l.n]) |*b| if (b.binding == binding) return b;
    return null;
}

fn createDescriptorPool(dh: ?*anyopaque, info: ?*const abi.DescriptorPoolCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const i = findFree("pools") orelse return R.error_too_many_objects;
    var total: u32 = 0;
    for (0..ci.poolSizeCount) |j| total += ci.pPoolSizes.?[j].descriptorCount;
    T.pools[i] = .{ .live = true, .dev = di, .flags = ci.flags, .max_sets = ci.maxSets, .n_sets = 0, .max_desc = total, .used_desc = 0 };
    (out orelse return R.error_initialization_failed).* = handle(.pool, i);
    return R.success;
}

fn freeSet(si: u32) void {
    const s = &T.sets[si];
    if (!s.live) return;
    T.desc_map.give(s.first, s.n);
    const p = &T.pools[s.pool];
    p.n_sets -= 1;
    p.used_desc -= s.n;
    unrefLayout(s.layout);
    s.live = false;
}

fn dropPool(pi: u32, destroy: bool) void {
    for (&T.sets, 0..) |*s, si| if (s.live and s.pool == pi) freeSet(@intCast(si));
    if (destroy) T.pools[pi].live = false;
}

fn destroyDescriptorPool(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const pi = unhandle(.pool, h) orelse return;
    if (!T.pools[pi].live) return;
    dropPool(pi, true);
}

fn resetDescriptorPool(_: ?*anyopaque, h: u64, _: u32) callconv(.c) Result {
    lock();
    defer unlock();
    const pi = unhandle(.pool, h) orelse return R.error_initialization_failed;
    if (!T.pools[pi].live) return R.error_initialization_failed;
    dropPool(pi, false);
    return R.success;
}

fn allocateDescriptorSets(_: ?*anyopaque, info: ?*const abi.DescriptorSetAllocateInfo, out: ?[*]u64) callconv(.c) Result {
    const ai = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const pi = unhandle(.pool, ai.descriptorPool) orelse return R.error_initialization_failed;
    const p = &T.pools[pi];
    if (!p.live) return R.error_initialization_failed;
    const dst = out orelse return R.error_initialization_failed;
    for (0..ai.descriptorSetCount) |j| {
        const li = unhandle(.set_layout, ai.pSetLayouts.?[j]) orelse return R.error_initialization_failed;
        const l = &T.set_layouts[li];
        var res: Result = R.success;
        if (p.n_sets >= p.max_sets or p.used_desc + l.n_desc > p.max_desc) res = R.error_out_of_pool_memory;
        const si = if (res == R.success) findFree("sets") else null;
        const first = if (si != null) T.desc_map.take(l.n_desc) else null;
        if (si == null or first == null) {
            if (res == R.success) res = if (si == null) R.error_out_of_pool_memory else R.error_fragmented_pool;
            // (the sets made so far go back, and every handle is null)
            for (0..j) |back| {
                if (unhandle(.set, dst[back])) |bs| freeSet(bs);
            }
            for (0..ai.descriptorSetCount) |x| dst[x] = 0;
            return res;
        }
        T.sets[si.?] = .{ .live = true, .pool = pi, .layout = li, .first = first.?, .n = l.n_desc };
        for (T.descs[first.?..][0..l.n_desc]) |*d| d.* = .{ .buf = NONE, .offset = 0, .range = 0 };
        l.refs += 1;
        p.n_sets += 1;
        p.used_desc += l.n_desc;
        dst[j] = handle(.set, si.?);
    }
    return R.success;
}

fn freeDescriptorSets(_: ?*anyopaque, _: u64, n: u32, sets: ?[*]const u64) callconv(.c) Result {
    lock();
    defer unlock();
    for (0..n) |i| {
        const h = sets.?[i];
        if (h == 0) continue;
        freeSet(unhandle(.set, h) orelse continue);
    }
    return R.success;
}

fn setOf(h: u64) ?*Set {
    const i = unhandle(.set, h) orelse return null;
    return if (T.sets[i].live) &T.sets[i] else null;
}

/// Descriptor `elem` of `binding` in set `s` (array elements past a
/// binding's count run on into the next binding, as Vulkan says).
fn descAt(s: *const Set, binding: u32, elem: u32) ?*Desc {
    const l = &T.set_layouts[s.layout];
    const b = layoutBinding(l, binding) orelse return null;
    const at = b.first + elem;
    if (at >= s.n) return null;
    return &T.descs[s.first + at];
}

fn updateDescriptorSets(_: ?*anyopaque, nw: u32, writes: ?[*]const abi.WriteDescriptorSet, nc: u32, copies: ?[*]const abi.CopyDescriptorSet) callconv(.c) void {
    lock();
    defer unlock();
    for (0..nw) |i| {
        const w = writes.?[i];
        const s = setOf(w.dstSet) orelse continue;
        switch (w.descriptorType) {
            DescType.uniform_buffer, DescType.storage_buffer, DescType.uniform_buffer_dynamic, DescType.storage_buffer_dynamic => {
                for (0..w.descriptorCount) |e| {
                    const d = descAt(s, w.dstBinding, w.dstArrayElement + @as(u32, @intCast(e))) orelse break;
                    const bi = w.pBufferInfo.?[e];
                    d.* = .{ .buf = unhandle(.buffer, bi.buffer) orelse NONE, .offset = bi.offset, .range = bi.range };
                }
            },
            else => {},
        }
    }
    for (0..nc) |i| {
        const c = copies.?[i];
        const src = setOf(c.srcSet) orelse continue;
        const dst = setOf(c.dstSet) orelse continue;
        for (0..c.descriptorCount) |e| {
            const ee: u32 = @intCast(e);
            const sd = descAt(src, c.srcBinding, c.srcArrayElement + ee) orelse break;
            const dd = descAt(dst, c.dstBinding, c.dstArrayElement + ee) orelse break;
            dd.* = sd.*;
        }
    }
}

// ── Pipeline layouts, shader modules, caches, pipelines ────────────────────

fn createPipelineLayout(_: ?*anyopaque, info: ?*const abi.PipelineLayoutCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    if (ci.setLayoutCount > MAX_SETS_PER_LAYOUT) return R.error_out_of_host_memory;
    const i = findFree("pipeline_layouts") orelse return R.error_too_many_objects;
    var pl = PipelineLayout{ .live = true, .n_sets = ci.setLayoutCount, .sets = [_]u32{NONE} ** MAX_SETS_PER_LAYOUT, .push_bytes = 0 };
    for (0..ci.setLayoutCount) |j| {
        const li = unhandle(.set_layout, ci.pSetLayouts.?[j]) orelse NONE;
        pl.sets[j] = li;
        if (li != NONE) T.set_layouts[li].refs += 1;
    }
    for (0..ci.pushConstantRangeCount) |j| {
        const r = ci.pPushConstantRanges.?[j];
        pl.push_bytes = @max(pl.push_bytes, r.offset + r.size);
    }
    T.pipeline_layouts[i] = pl;
    (out orelse return R.error_initialization_failed).* = handle(.pipeline_layout, i);
    return R.success;
}

fn destroyPipelineLayout(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.pipeline_layout, h) orelse return;
    const pl = &T.pipeline_layouts[i];
    if (!pl.live) return;
    for (pl.sets[0..pl.n_sets]) |li| if (li != NONE) unrefLayout(li);
    pl.live = false;
}

fn createShaderModule(_: ?*anyopaque, info: ?*const abi.ShaderModuleCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const n: u32 = @intCast(ci.codeSize / 4);
    if (n < 5 or ci.pCode.?[0] != spirv.MAGIC) return R.error_initialization_failed;
    const i = findFree("shaders") orelse return R.error_too_many_objects;
    const blocks = (n + SHADER_BLOCK_WORDS - 1) / SHADER_BLOCK_WORDS;
    const first = T.shader_map.take(blocks) orelse return R.error_out_of_host_memory;
    const at = first * SHADER_BLOCK_WORDS;
    @memcpy(T.shader_words[at..][0..n], ci.pCode.?[0..n]);
    T.shaders[i] = .{ .live = true, .at = at, .n = n };
    (out orelse return R.error_initialization_failed).* = handle(.shader, i);
    return R.success;
}

fn destroyShaderModule(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.shader, h) orelse return;
    const s = &T.shaders[i];
    if (!s.live) return;
    T.shader_map.give(s.at / SHADER_BLOCK_WORDS, (s.n + SHADER_BLOCK_WORDS - 1) / SHADER_BLOCK_WORDS);
    s.live = false;
}

fn createPipelineCache(_: ?*anyopaque, _: ?*const abi.PipelineCacheCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    lock();
    defer unlock();
    for (&T.caches, 0..) |*c, i| if (!c.*) {
        c.* = true;
        (out orelse return R.error_initialization_failed).* = handle(.cache, @intCast(i));
        return R.success;
    };
    return R.error_too_many_objects;
}

fn destroyPipelineCache(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.cache, h) orelse return;
    T.caches[i] = false;
}

fn getPipelineCacheData(_: ?*anyopaque, _: u64, size: ?*usize, _: ?*anyopaque) callconv(.c) Result {
    // (nothing is cached: compiles are fast enough for now)
    (size orelse return R.error_initialization_failed).* = 0;
    return R.success;
}

fn mergePipelineCaches(_: ?*anyopaque, _: u64, _: u32, _: ?[*]const u64) callconv(.c) Result {
    return R.success;
}

fn compilePipeline(di: u32, ci: *const abi.ComputePipelineCreateInfo) ?Pipeline {
    const g = theGpu() orelse return null;
    const stage = ci.stage;
    if (stage.stage != 0x20) return null;
    const si = unhandle(.shader, stage.module) orelse return null;
    const sh = T.shaders[si];
    if (!sh.live) return null;
    var spec_entries: [64]spirv.SpecEntry = undefined;
    var opts = spirv.Options{ .robust = T.devices[di].robust };
    if (stage.pSpecializationInfo) |sp| {
        const n = @min(sp[0].mapEntryCount, spec_entries.len);
        for (0..n) |j| {
            const e = sp[0].pMapEntries.?[j];
            spec_entries[j] = .{ .id = e.constantID, .offset = e.offset, .size = @intCast(e.size) };
        }
        opts.spec = spec_entries[0..n];
        if (sp[0].pData) |pd| {
            const data: [*]const u8 = @ptrCast(pd);
            opts.spec_data = data[0..sp[0].dataSize];
        }
    }
    var gen = spirv.init(T.shader_words[sh.at..][0..sh.n], &T.scratch, opts);
    const name = cstr(stage.pName);
    const info = gen.compile(name, .{ .insts = &T.insts, .tys = &T.tys }, &T.kernel) catch |e| {
        say("vkCreateComputePipelines: {s}: {s} ({s})", .{ name, gen.diag(), @errorName(e) });
        return null;
    };
    var work = gpu.Work.init(g.work);
    const bin = g.compile(&T.kernel, g.dev.caps, &work, &T.code) catch |e| {
        say("vkCreateComputePipelines: {s}: the backend failed ({s})", .{ name, @errorName(e) });
        return null;
    };
    const prog = g.dev.load(&bin) catch |e| {
        say("vkCreateComputePipelines: {s}: the device did not load it ({s})", .{ name, @errorName(e) });
        return null;
    };
    return .{ .live = true, .dev = di, .prog = prog, .info = info, .writes = bin.writes, .param_words = bin.param_words };
}

fn createComputePipelines(dh: ?*anyopaque, _: u64, n: u32, infos: ?[*]const abi.ComputePipelineCreateInfo, _: ?*const anyopaque, out: ?[*]u64) callconv(.c) Result {
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const dst = out orelse return R.error_initialization_failed;
    var res: Result = R.success;
    for (0..n) |j| {
        dst[j] = 0;
        const i = findFree("pipelines") orelse {
            res = R.error_out_of_host_memory;
            continue;
        };
        const p = compilePipeline(di, &infos.?[j]) orelse {
            res = R.error_unknown;
            continue;
        };
        T.pipelines[i] = p;
        dst[j] = handle(.pipeline, i);
    }
    return res;
}

fn destroyPipeline(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.pipeline, h) orelse return;
    const p = &T.pipelines[i];
    if (!p.live) return;
    if (theGpu()) |g| g.dev.unload(&p.prog);
    p.live = false;
}

// ── Command pools and buffers ──────────────────────────────────────────────

fn createCommandPool(dh: ?*anyopaque, info: ?*const abi.CommandPoolCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    if (ci.queueFamilyIndex != 0) return R.error_initialization_failed;
    const i = findFree("cmd_pools") orelse return R.error_too_many_objects;
    T.cmd_pools[i] = .{ .live = true, .dev = di, .flags = ci.flags };
    (out orelse return R.error_initialization_failed).* = handle(.cmd_pool, i);
    return R.success;
}

fn freeCb(cb: *CmdBuf) void {
    releaseBlocks(cb);
    cb.live = false;
}

fn releaseBlocks(cb: *CmdBuf) void {
    for (cb.blocks[0..cb.n_blocks]) |b| T.cmd_map.give(b, 1);
    cb.n_blocks = 0;
    cb.used = 0;
    cb.failed = false;
}

fn destroyCommandPool(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const pi = unhandle(.cmd_pool, h) orelse return;
    if (!T.cmd_pools[pi].live) return;
    for (&T.cbs) |*cb| if (cb.live and cb.pool == pi) freeCb(cb);
    T.cmd_pools[pi].live = false;
}

fn resetCommandPool(_: ?*anyopaque, h: u64, _: u32) callconv(.c) Result {
    lock();
    defer unlock();
    const pi = unhandle(.cmd_pool, h) orelse return R.error_initialization_failed;
    for (&T.cbs) |*cb| if (cb.live and cb.pool == pi) {
        releaseBlocks(cb);
        cb.state = .initial;
    };
    return R.success;
}

fn trimCommandPool(_: ?*anyopaque, _: u64, _: u32) callconv(.c) void {}

fn allocateCommandBuffers(dh: ?*anyopaque, info: ?*const abi.CommandBufferAllocateInfo, out: ?[*]?*anyopaque) callconv(.c) Result {
    const ai = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const pi = unhandle(.cmd_pool, ai.commandPool) orelse return R.error_initialization_failed;
    if (ai.level != 0) return R.error_feature_not_present;
    const dst = out orelse return R.error_initialization_failed;
    for (0..ai.commandBufferCount) |j| {
        const i = findFree("cbs") orelse {
            for (0..j) |back| {
                const bi = hdrIndex(MAX_CMDBUFS, &T.cb_hdr, dst[back]).?;
                freeCb(&T.cbs[bi]);
            }
            for (0..ai.commandBufferCount) |x| dst[x] = null;
            return R.error_out_of_host_memory;
        };
        T.cbs[i] = .{ .live = true, .pool = pi, .dev = di, .state = .initial, .blocks = undefined, .n_blocks = 0, .used = 0, .failed = false };
        T.cb_hdr[i] = .{ .loader = ICD_LOADER_MAGIC };
        dst[j] = &T.cb_hdr[i];
    }
    return R.success;
}

fn cbOf(h: ?*anyopaque) ?*CmdBuf {
    const i = hdrIndex(MAX_CMDBUFS, &T.cb_hdr, h) orelse return null;
    return if (T.cbs[i].live) &T.cbs[i] else null;
}

fn freeCommandBuffers(_: ?*anyopaque, _: u64, n: u32, cbs: ?[*]const ?*anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    for (0..n) |i| if (cbOf(cbs.?[i])) |cb| freeCb(cb);
}

fn beginCommandBuffer(h: ?*anyopaque, _: ?*const abi.CommandBufferBeginInfo) callconv(.c) Result {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return R.error_initialization_failed;
    releaseBlocks(cb);
    cb.state = .recording;
    return R.success;
}

fn endCommandBuffer(h: ?*anyopaque) callconv(.c) Result {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return R.error_initialization_failed;
    if (cb.failed) {
        cb.state = .invalid;
        return R.error_out_of_host_memory;
    }
    cb.state = .executable;
    return R.success;
}

fn resetCommandBuffer(h: ?*anyopaque, _: u32) callconv(.c) Result {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return R.error_initialization_failed;
    releaseBlocks(cb);
    cb.state = .initial;
    return R.success;
}

// ── Recording: commands as bytes in the command buffer's blocks ────────────

const Cmd = enum(u16) { bind_pipeline, bind_sets, push, dispatch, dispatch_indirect, copy, fill, update };
const CmdHead = extern struct { tag: u16, pad: u16 = 0, size: u32 };

const BindSets = extern struct { first: u32, count: u32, n_dyn: u32, sets: [MAX_SETS_PER_LAYOUT]u32, dyn: [MAX_DYNAMIC * 2]u32 };
const Push = extern struct { offset: u32, size: u32, bytes: [MAX_PUSH_BYTES]u8 };
const Dispatch = extern struct { x: u32, y: u32, z: u32 };
const Indirect = extern struct { buf: u32, pad: u32 = 0, offset: u64 };
const Copy = extern struct { src: u32, dst: u32, src_off: u64, dst_off: u64, size: u64 };
const Fill = extern struct { dst: u32, data: u32, off: u64, size: u64 };
const Update = extern struct { dst: u32, size: u32, off: u64 };

/// Room for a command of `payload` bytes (8-aligned), its header written.
fn record(cb: *CmdBuf, tag: Cmd, payload: usize) ?[]u8 {
    if (cb.failed or cb.state != .recording) return null;
    const size: u32 = @intCast(std.mem.alignForward(usize, @sizeOf(CmdHead) + payload, 8));
    if (size > CMD_BLOCK) {
        cb.failed = true;
        return null;
    }
    if (cb.n_blocks == 0 or cb.used + size > CMD_BLOCK) {
        if (cb.n_blocks == MAX_CB_BLOCKS) {
            cb.failed = true;
            return null;
        }
        // (a block's end not used: an empty header says so)
        if (cb.n_blocks != 0 and cb.used + @sizeOf(CmdHead) <= CMD_BLOCK) {
            const end: *CmdHead = @ptrCast(@alignCast(&T.cmd_blocks[cb.blocks[cb.n_blocks - 1]][cb.used]));
            end.* = .{ .tag = 0xffff, .size = 0 };
        }
        const b = T.cmd_map.take(1) orelse {
            cb.failed = true;
            return null;
        };
        cb.blocks[cb.n_blocks] = @intCast(b);
        cb.n_blocks += 1;
        cb.used = 0;
    }
    const at = &T.cmd_blocks[cb.blocks[cb.n_blocks - 1]];
    const head: *CmdHead = @ptrCast(@alignCast(&at[cb.used]));
    head.* = .{ .tag = @intFromEnum(tag), .size = size };
    const body = at[cb.used + @sizeOf(CmdHead) ..][0..payload];
    cb.used += size;
    return body;
}

fn put(cb: *CmdBuf, tag: Cmd, value: anytype) void {
    const body = record(cb, tag, @sizeOf(@TypeOf(value))) orelse return;
    @memcpy(body, std.mem.asBytes(&value));
}

fn cmdBindPipeline(h: ?*anyopaque, bind_point: u32, ph: u64) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    if (bind_point != 1) return;
    put(cb, .bind_pipeline, unhandle(.pipeline, ph) orelse NONE);
}

fn cmdBindDescriptorSets(h: ?*anyopaque, bind_point: u32, _: u64, first: u32, count: u32, sets: ?[*]const u64, n_dyn: u32, dyn: ?[*]const u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    if (bind_point != 1) return;
    if (first + count > MAX_SETS_PER_LAYOUT or n_dyn > MAX_DYNAMIC * 2) {
        cb.failed = true;
        return;
    }
    var b = BindSets{ .first = first, .count = count, .n_dyn = n_dyn, .sets = undefined, .dyn = undefined };
    for (0..count) |i| b.sets[i] = unhandle(.set, sets.?[i]) orelse NONE;
    for (0..n_dyn) |i| b.dyn[i] = dyn.?[i];
    put(cb, .bind_sets, b);
}

fn cmdPushConstants(h: ?*anyopaque, _: u64, _: u32, offset: u32, size: u32, values: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    if (offset + size > MAX_PUSH_BYTES) {
        cb.failed = true;
        return;
    }
    var p = Push{ .offset = offset, .size = size, .bytes = undefined };
    const src: [*]const u8 = @ptrCast(values orelse return);
    @memcpy(p.bytes[0..size], src[0..size]);
    put(cb, .push, p);
}

fn cmdDispatch(h: ?*anyopaque, x: u32, y: u32, z: u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    put(cb, .dispatch, Dispatch{ .x = x, .y = y, .z = z });
}

fn cmdDispatchBase(h: ?*anyopaque, bx: u32, by: u32, bz: u32, x: u32, y: u32, z: u32) callconv(.c) void {
    if (bx != 0 or by != 0 or bz != 0) {
        say("vkCmdDispatchBase: a base other than 0 is not supported", .{});
        return;
    }
    cmdDispatch(h, x, y, z);
}

fn cmdDispatchIndirect(h: ?*anyopaque, bh: u64, offset: u64) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    put(cb, .dispatch_indirect, Indirect{ .buf = unhandle(.buffer, bh) orelse NONE, .offset = offset });
}

fn cmdCopyBuffer(h: ?*anyopaque, src: u64, dst: u64, n: u32, regions: ?[*]const abi.BufferCopy) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    const s = unhandle(.buffer, src) orelse NONE;
    const d = unhandle(.buffer, dst) orelse NONE;
    for (0..n) |i| {
        const rg = regions.?[i];
        put(cb, .copy, Copy{ .src = s, .dst = d, .src_off = rg.srcOffset, .dst_off = rg.dstOffset, .size = rg.size });
    }
}

fn cmdFillBuffer(h: ?*anyopaque, dst: u64, offset: u64, size: u64, data: u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    put(cb, .fill, Fill{ .dst = unhandle(.buffer, dst) orelse NONE, .data = data, .off = offset, .size = size });
}

fn cmdUpdateBuffer(h: ?*anyopaque, dst: u64, offset: u64, size: u64, data: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    const src: [*]const u8 = @ptrCast(data orelse return);
    const d = unhandle(.buffer, dst) orelse NONE;
    // (in pieces a block holds)
    var done: u64 = 0;
    while (done < size) {
        const n: u32 = @intCast(@min(size - done, 32 * 1024));
        const body = record(cb, .update, @sizeOf(Update) + n) orelse return;
        const u = Update{ .dst = d, .size = n, .off = offset + done };
        @memcpy(body[0..@sizeOf(Update)], std.mem.asBytes(&u));
        @memcpy(body[@sizeOf(Update)..][0..n], src[done..][0..n]);
        done += n;
    }
}

fn cmdPipelineBarrier(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: ?*const anyopaque, _: u32, _: ?*const anyopaque, _: u32, _: ?*const anyopaque) callconv(.c) void {
    // (each dispatch of a run sees the writes of the ones before it)
}

// ── Running a submission ───────────────────────────────────────────────────

const Exec = struct {
    g: *Gpu,
    di: u32,
    pipe: u32 = NONE,
    sets: [MAX_SETS_PER_LAYOUT]u32 = [_]u32{NONE} ** MAX_SETS_PER_LAYOUT,
    dyn: [MAX_SETS_PER_LAYOUT][MAX_DYNAMIC]u32 = undefined,
    push: [MAX_PUSH_BYTES / 4]u32 = [_]u32{0} ** (MAX_PUSH_BYTES / 4),
    err: Result = R.success,

    fn dev(e: *Exec) *Device {
        return &T.devices[e.di];
    }

    /// Runs what is queued (one gpu.Device run); the device's last fence.
    fn flush(e: *Exec) Result {
        if (T.n_ds == 0) return R.success;
        const f = e.g.dev.run(T.ds[0..T.n_ds]) catch |err| {
            T.n_ds = 0;
            say("vkQueueSubmit: the GPU run failed ({s})", .{@errorName(err)});
            if (err == error.DeviceLost) {
                e.dev().lost = true;
                return R.error_device_lost;
            }
            return R.error_out_of_device_memory;
        };
        T.n_ds = 0;
        e.dev().last_fence = f;
        return R.success;
    }

    fn markDirty(e: *Exec, mi: u32) void {
        _ = e;
        T.memories[mi].dirty = true;
        // (set to the run's fence once it has one: see finishDirty)
        T.memories[mi].dirty_fence = 0;
    }

    /// The next dispatch slot (the queue run first when full).
    fn slot(e: *Exec) ?u32 {
        const cap = @min(MAX_RUN, e.g.dev.caps.max_run);
        if (T.n_ds >= cap) {
            const res = e.flush();
            if (res != R.success) {
                e.err = res;
                return null;
            }
        }
        T.n_ds += 1;
        return T.n_ds - 1;
    }

    fn kernel(e: *Exec, prog: *const gpu.Program, groups: [3]u32, bufs: []const gpu.Buffer, params: []const u32) void {
        const s = e.slot() orelse return;
        @memcpy(T.ds_bufs[s][0..bufs.len], bufs);
        @memcpy(T.ds_params[s][0..params.len], params);
        T.ds[s] = .{ .prog = prog, .groups = groups, .buffers = T.ds_bufs[s][0..bufs.len], .params = T.ds_params[s][0..params.len] };
    }

    /// The memory under buffer `bi` and the buffer's offset in it.
    fn place(e: *Exec, bi: u32) ?struct { mem: u32, off: u64, size: u64 } {
        _ = e;
        if (bi == NONE or bi >= MAX_BUFFERS) return null;
        const b = T.buffers[bi];
        if (!b.live or b.mem == NONE or !T.memories[b.mem].live) return null;
        return .{ .mem = b.mem, .off = b.offset, .size = b.size };
    }

    fn dispatch(e: *Exec, groups: [3]u32) void {
        if (groups[0] == 0 or groups[1] == 0 or groups[2] == 0) return;
        if (e.pipe == NONE) return;
        const p = &T.pipelines[e.pipe];
        if (!p.live) return;
        var bufs: [spirv.MAX_BINDINGS]gpu.Buffer = undefined;
        var params: [MAX_RUN_PARAMS]u32 = [_]u32{0} ** MAX_RUN_PARAMS;
        const nb = p.info.n_bindings;
        for (0..nb) |i| {
            const want = p.info.bindings[i];
            bufs[i] = e.dev().dummy;
            params[2 * i] = 0;
            params[2 * i + 1] = 0;
            if (want.set >= MAX_SETS_PER_LAYOUT) continue;
            const si = e.sets[want.set];
            if (si == NONE or !T.sets[si].live) continue;
            const set = &T.sets[si];
            const l = &T.set_layouts[set.layout];
            const lb = layoutBinding(l, want.binding) orelse continue;
            const d = T.descs[set.first + lb.first];
            const pl = e.place(d.buf) orelse continue;
            var off = pl.off + d.offset;
            if (lb.dyn_first != NONE) off += e.dyn[want.set][lb.dyn_first];
            const range = if (d.range == WHOLE_SIZE) pl.size -| d.offset else d.range;
            bufs[i] = T.memories[pl.mem].buf;
            params[2 * i] = @truncate(off);
            params[2 * i + 1] = @intCast(@min(range, 0xffff_ffff));
            if (p.writes >> @intCast(i) & 1 != 0) e.markDirty(pl.mem);
        }
        const pw = (p.info.push_bytes + 3) / 4;
        @memcpy(params[2 * nb ..][0..pw], e.push[0..pw]);
        const np = @max(2 * nb + pw, p.param_words);
        e.kernel(&p.prog, groups, bufs[0..nb], params[0..np]);
    }

    /// A copy of `size` bytes between two memories, as copy kernels.
    fn copyMem(e: *Exec, src: gpu.Buffer, src_off: u64, dst: gpu.Buffer, dst_off: u64, size: u64) void {
        const d = e.dev();
        const aligned = (src_off | dst_off | size) % 4 == 0;
        const unit: u64 = if (aligned) 4 else 1;
        const prog = if (aligned) &d.copy32.? else &d.copy8.?;
        const per: u64 = @as(u64, GROUP) * MAX_GROUPS;
        var done: u64 = 0;
        const total = size / unit;
        while (done < total) {
            const n = @min(total - done, per);
            const groups: u32 = @intCast((n + GROUP - 1) / GROUP);
            e.kernel(prog, .{ groups, 1, 1 }, &.{ src, dst }, &.{ @intCast(src_off + done * unit), @intCast(dst_off + done * unit), @intCast(n) });
            done += n;
        }
    }

    fn fill(e: *Exec, dst: gpu.Buffer, off: u64, words: u64, value: u32) void {
        const d = e.dev();
        const per: u64 = @as(u64, GROUP) * MAX_GROUPS;
        var done: u64 = 0;
        while (done < words) {
            const n = @min(words - done, per);
            const groups: u32 = @intCast((n + GROUP - 1) / GROUP);
            e.kernel(&d.fill32.?, .{ groups, 1, 1 }, &.{dst}, &.{ @intCast(off + done * 4), 0, @intCast(n), value });
            done += n;
        }
    }

    /// Staging room for `n` bytes (runs and waits for what used it last
    /// when it is full).
    fn stage(e: *Exec, n: u64) ?u64 {
        const d = e.dev();
        if (n > STAGING_BYTES) return null;
        if (d.staging_used + n > STAGING_BYTES) {
            if (e.flush() != R.success) return null;
            e.g.dev.wait(d.last_fence, 10_000_000) catch return null;
            d.staging_used = 0;
        }
        const at = d.staging_used;
        d.staging_used = std.mem.alignForward(u64, at + n, 16);
        return at;
    }

    /// An indirect dispatch's three counts, read from the GPU's buffer.
    fn indirect(e: *Exec, ind: Indirect) ?[3]u32 {
        const pl = e.place(ind.buf) orelse return null;
        const d = e.dev();
        e.copyMem(T.memories[pl.mem].buf, pl.off + ind.offset, d.readback, 0, 12);
        if (e.flush() != R.success) return null;
        e.g.dev.wait(d.last_fence, 10_000_000) catch return null;
        e.g.dev.fromDevice(d.readback, 0, 12);
        const w = d.readback.words();
        if (w.len < 3) return null;
        return .{ w[0], w[1], w[2] };
    }

    fn run(e: *Exec, cb: *const CmdBuf) void {
        // (a command buffer starts with nothing bound)
        e.pipe = NONE;
        e.sets = [_]u32{NONE} ** MAX_SETS_PER_LAYOUT;
        for (cb.blocks[0..cb.n_blocks], 0..) |bi, k| {
            const block = &T.cmd_blocks[bi];
            const end = if (k + 1 == cb.n_blocks) cb.used else CMD_BLOCK;
            var at: usize = 0;
            while (at + @sizeOf(CmdHead) <= end) {
                const head: *const CmdHead = @ptrCast(@alignCast(&block[at]));
                if (head.tag == 0xffff or head.size == 0) break;
                const body = block[at + @sizeOf(CmdHead) .. at + head.size];
                e.command(@enumFromInt(head.tag), body);
                if (e.err != R.success) return;
                at += head.size;
            }
        }
    }

    fn as(comptime P: type, body: []const u8) P {
        var v: P = undefined;
        @memcpy(std.mem.asBytes(&v), body[0..@sizeOf(P)]);
        return v;
    }

    fn command(e: *Exec, tag: Cmd, body: []const u8) void {
        switch (tag) {
            .bind_pipeline => e.pipe = as(u32, body),
            .bind_sets => {
                const b = as(BindSets, body);
                var dyn_at: u32 = 0;
                for (0..b.count) |i| {
                    const set_no = b.first + i;
                    e.sets[set_no] = b.sets[i];
                    if (b.sets[i] == NONE) continue;
                    const l = &T.set_layouts[T.sets[b.sets[i]].layout];
                    for (0..l.n_dyn) |j| {
                        e.dyn[set_no][j] = if (dyn_at < b.n_dyn) b.dyn[dyn_at] else 0;
                        dyn_at += 1;
                    }
                }
            },
            .push => {
                const p = as(Push, body);
                @memcpy(std.mem.sliceAsBytes(&e.push)[p.offset..][0..p.size], p.bytes[0..p.size]);
            },
            .dispatch => {
                const d = as(Dispatch, body);
                e.dispatch(.{ d.x, d.y, d.z });
            },
            .dispatch_indirect => {
                const groups = e.indirect(as(Indirect, body)) orelse {
                    say("vkCmdDispatchIndirect: the counts could not be read", .{});
                    return;
                };
                e.dispatch(groups);
            },
            .copy => {
                const c = as(Copy, body);
                const s = e.place(c.src) orelse return;
                const d = e.place(c.dst) orelse return;
                e.copyMem(T.memories[s.mem].buf, s.off + c.src_off, T.memories[d.mem].buf, d.off + c.dst_off, c.size);
                e.markDirty(d.mem);
            },
            .fill => {
                const f = as(Fill, body);
                const d = e.place(f.dst) orelse return;
                const size = if (f.size == WHOLE_SIZE) (d.size -| f.off) & ~@as(u64, 3) else f.size;
                e.fill(T.memories[d.mem].buf, d.off + f.off, size / 4, f.data);
                e.markDirty(d.mem);
            },
            .update => {
                const u = as(Update, body);
                const d = e.place(u.dst) orelse return;
                const data = body[@sizeOf(Update)..][0..u.size];
                const at = e.stage(u.size) orelse {
                    e.err = R.error_out_of_device_memory;
                    return;
                };
                const st = e.dev().staging;
                @memcpy(st.cpu[at..][0..u.size], data);
                e.g.dev.toDevice(st, at, u.size);
                e.copyMem(st, at, T.memories[d.mem].buf, d.off + u.off, u.size);
                e.markDirty(d.mem);
            },
        }
    }
};

/// Every memory the work so far may have written: the device's last fence.
fn finishDirty(fence: u64) void {
    for (&T.memories) |*m| {
        if (m.live and m.dirty and m.dirty_fence == 0) m.dirty_fence = fence;
    }
}

fn semOf(h: u64) ?*Semaphore {
    const i = unhandle(.semaphore, h) orelse return null;
    return if (T.semaphores[i].live) &T.semaphores[i] else null;
}

fn fenceOf(h: u64) ?*Fence {
    const i = unhandle(.fence, h) orelse return null;
    return if (T.fences[i].live) &T.fences[i] else null;
}

/// A timeline semaphore's value as far as the device's fences say.
fn semValue(g: *Gpu, s: *Semaphore) u64 {
    var keep: u32 = 0;
    for (s.pend[0..s.n_pend]) |p| {
        if (g.dev.done(p.fence)) {
            s.value = @max(s.value, p.value);
        } else {
            s.pend[keep] = p;
            keep += 1;
        }
    }
    s.n_pend = keep;
    return s.value;
}

fn queueSubmit(q: ?*anyopaque, n: u32, submits: ?[*]const abi.SubmitInfo, fh: u64) callconv(.c) Result {
    lock();
    defer unlock();
    const di = queueDev(q) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    if (T.devices[di].lost) return R.error_device_lost;
    // the CPU's writes to mapped memory, for the GPU
    for (&T.memories) |*m| {
        if (m.live and m.mapped and m.host) g.dev.toDevice(m.buf, 0, m.buf.cpu.len);
    }
    // the staging space, once what used it is done
    const d = &T.devices[di];
    if (d.staging_used != 0 and g.dev.done(d.last_fence)) d.staging_used = 0;
    var e = Exec{ .g = g, .di = di };
    T.n_ds = 0;
    for (0..n) |si| {
        const s = submits.?[si];
        const tl: ?*const abi.TimelineSemaphoreSubmitInfo = if (findIn(s.pNext, ST.timeline_semaphore_submit_info)) |b| @ptrCast(@alignCast(b)) else null;
        // waits: the queue runs in order, so work signaled earlier is
        // waited for already; a value only the host will signal is waited
        // for here
        for (0..s.waitSemaphoreCount) |wi| {
            const sem = semOf(s.pWaitSemaphores.?[wi]) orelse continue;
            if (!sem.timeline) {
                sem.signaled = false;
                continue;
            }
            const want = if (tl) |t| (if (t.pWaitSemaphoreValues) |v| v[wi] else 0) else 0;
            var spins: u32 = 0;
            while (semValue(g, sem) < want and sem.n_pend == 0 and spins < 5_000_000) : (spins += 1) {
                unlock();
                yieldCpu();
                lock();
            }
        }
        for (0..s.commandBufferCount) |ci| {
            const cb = cbOf(s.pCommandBuffers.?[ci]) orelse continue;
            if (cb.state != .executable) continue;
            e.run(cb);
            if (e.err != R.success) return e.err;
        }
        const res = e.flush();
        if (res != R.success) return res;
        finishDirty(d.last_fence);
        for (0..s.signalSemaphoreCount) |xi| {
            const sem = semOf(s.pSignalSemaphores.?[xi]) orelse continue;
            if (!sem.timeline) {
                sem.signaled = true;
                continue;
            }
            const v = if (tl) |t| (if (t.pSignalSemaphoreValues) |vs| vs[xi] else 0) else 0;
            if (d.last_fence == 0 or g.dev.done(d.last_fence)) {
                sem.value = @max(sem.value, v);
            } else if (sem.n_pend < MAX_PENDING) {
                sem.pend[sem.n_pend] = .{ .value = v, .fence = d.last_fence };
                sem.n_pend += 1;
            } else {
                // (too many in flight: wait for this one)
                g.dev.wait(d.last_fence, 10_000_000) catch {};
                sem.value = @max(sem.value, v);
            }
        }
    }
    if (fenceOf(fh)) |f| {
        if (d.last_fence == 0) {
            f.signaled = true;
        } else f.pending = d.last_fence;
    }
    return R.success;
}

/// Waits for device fence `f` with the lock let go between short waits;
/// false on a timeout.
fn waitFence(g: *Gpu, f: u64, timeout_ns: u64) Result {
    if (f == 0) return R.success;
    const start = nowNs();
    while (true) {
        if (g.dev.done(f)) return R.success;
        g.dev.wait(f, 1000) catch |err| switch (err) {
            error.Timeout => {},
            error.DeviceLost => return R.error_device_lost,
            else => return R.error_device_lost,
        };
        if (g.dev.done(f)) return R.success;
        if (timeout_ns == 0) return R.timeout;
        if (timeout_ns != WHOLE_SIZE and nowNs() -% start >= timeout_ns) return R.timeout;
        unlock();
        yieldCpu();
        lock();
    }
}

fn queueWaitIdle(q: ?*anyopaque) callconv(.c) Result {
    lock();
    defer unlock();
    const di = queueDev(q) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const res = waitFence(g, T.devices[di].last_fence, WHOLE_SIZE);
    pullDone(g);
    return res;
}

fn deviceWaitIdle(dh: ?*anyopaque) callconv(.c) Result {
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const res = waitFence(g, T.devices[di].last_fence, WHOLE_SIZE);
    pullDone(g);
    return res;
}

// ── Fences and semaphores ──────────────────────────────────────────────────

fn createFence(_: ?*anyopaque, info: ?*const abi.FenceCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const i = findFree("fences") orelse return R.error_too_many_objects;
    T.fences[i] = .{ .live = true, .signaled = ci.flags & 1 != 0, .pending = 0 };
    (out orelse return R.error_initialization_failed).* = handle(.fence, i);
    return R.success;
}

fn destroyFence(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const f = fenceOf(h) orelse return;
    f.live = false;
}

fn resetFences(_: ?*anyopaque, n: u32, fences: ?[*]const u64) callconv(.c) Result {
    lock();
    defer unlock();
    for (0..n) |i| if (fenceOf(fences.?[i])) |f| {
        f.signaled = false;
        f.pending = 0;
    };
    return R.success;
}

/// Whether fence f is signaled now (its device fence done turns it so).
fn fenceDone(g: *Gpu, f: *Fence) bool {
    if (f.signaled) return true;
    if (f.pending != 0 and g.dev.done(f.pending)) {
        f.signaled = true;
        f.pending = 0;
        pullDone(g);
    }
    return f.signaled;
}

fn getFenceStatus(dh: ?*anyopaque, h: u64) callconv(.c) Result {
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    if (T.devices[di].lost) return R.error_device_lost;
    const g = theGpu() orelse return R.error_initialization_failed;
    const f = fenceOf(h) orelse return R.error_initialization_failed;
    return if (fenceDone(g, f)) R.success else R.not_ready;
}

fn waitForFences(dh: ?*anyopaque, n: u32, fences: ?[*]const u64, wait_all: u32, timeout: u64) callconv(.c) Result {
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const start = nowNs();
    while (true) {
        if (T.devices[di].lost) return R.error_device_lost;
        var all = true;
        var any = false;
        var earliest: u64 = 0;
        for (0..n) |i| {
            const f = fenceOf(fences.?[i]) orelse continue;
            if (fenceDone(g, f)) {
                any = true;
            } else {
                all = false;
                if (f.pending != 0 and (earliest == 0 or f.pending < earliest)) earliest = f.pending;
            }
        }
        if (all or (wait_all == 0 and any)) return R.success;
        if (timeout == 0) return R.timeout;
        const spent = nowNs() -% start;
        if (timeout != WHOLE_SIZE and spent >= timeout) return R.timeout;
        if (earliest != 0) {
            const left = if (timeout == WHOLE_SIZE) WHOLE_SIZE else timeout - spent;
            const res = waitFence(g, earliest, @min(left, 1_000_000));
            if (res == R.error_device_lost) {
                T.devices[di].lost = true;
                return res;
            }
        } else {
            // (a fence no submission has: another thread may submit it)
            unlock();
            yieldCpu();
            lock();
        }
    }
}

fn createSemaphore(_: ?*anyopaque, info: ?*const abi.SemaphoreCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const i = findFree("semaphores") orelse return R.error_too_many_objects;
    var s = Semaphore{ .live = true, .timeline = false, .value = 0, .pend = undefined, .n_pend = 0, .signaled = false };
    if (findIn(ci.pNext, ST.semaphore_type_create_info)) |b| {
        const ti: *const abi.SemaphoreTypeCreateInfo = @ptrCast(@alignCast(b));
        if (ti.semaphoreType == 1) {
            s.timeline = true;
            s.value = ti.initialValue;
        }
    }
    T.semaphores[i] = s;
    (out orelse return R.error_initialization_failed).* = handle(.semaphore, i);
    return R.success;
}

fn destroySemaphore(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const s = semOf(h) orelse return;
    s.live = false;
}

fn getSemaphoreCounterValue(_: ?*anyopaque, h: u64, out: ?*u64) callconv(.c) Result {
    lock();
    defer unlock();
    const g = theGpu() orelse return R.error_initialization_failed;
    const s = semOf(h) orelse return R.error_initialization_failed;
    const v = semValue(g, s);
    if (s.n_pend == 0) pullDone(g);
    (out orelse return R.error_initialization_failed).* = v;
    return R.success;
}

fn signalSemaphore(_: ?*anyopaque, info: ?*const abi.SemaphoreSignalInfo) callconv(.c) Result {
    const si = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const s = semOf(si.semaphore) orelse return R.error_initialization_failed;
    s.value = @max(s.value, si.value);
    return R.success;
}

fn waitSemaphores(dh: ?*anyopaque, info: ?*const abi.SemaphoreWaitInfo, timeout: u64) callconv(.c) Result {
    const wi = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const any = wi.flags & 1 != 0;
    const start = nowNs();
    while (true) {
        var all = true;
        var one = false;
        var earliest: u64 = 0;
        for (0..wi.semaphoreCount) |i| {
            const s = semOf(wi.pSemaphores.?[i]) orelse continue;
            const want = wi.pValues.?[i];
            if (semValue(g, s) >= want) {
                one = true;
                continue;
            }
            all = false;
            for (s.pend[0..s.n_pend]) |p| {
                if (p.value >= want and (earliest == 0 or p.fence < earliest)) earliest = p.fence;
            }
        }
        if (all or (any and one)) {
            pullDone(g);
            return R.success;
        }
        if (timeout == 0) return R.timeout;
        const spent = nowNs() -% start;
        if (timeout != WHOLE_SIZE and spent >= timeout) return R.timeout;
        if (earliest != 0) {
            const res = waitFence(g, earliest, 1_000_000);
            if (res == R.error_device_lost) {
                T.devices[di].lost = true;
                return res;
            }
        } else {
            unlock();
            yieldCpu();
            lock();
        }
    }
}

// ── The entry points by name ───────────────────────────────────────────────

pub const Level = enum { global, instance, physical, device };
const Proc = struct { name: []const u8, f: *const anyopaque, level: Level };

fn entry(name: []const u8, f: *const anyopaque, level: Level) Proc {
    return .{ .name = name, .f = f, .level = level };
}

const procs = [_]Proc{
    entry("vkEnumerateInstanceVersion", &enumerateInstanceVersion, .global),
    entry("vkEnumerateInstanceExtensionProperties", &enumerateInstanceExtensionProperties, .global),
    entry("vkEnumerateInstanceLayerProperties", &enumerateInstanceLayerProperties, .global),
    entry("vkCreateInstance", &createInstance, .global),
    entry("vkGetInstanceProcAddr", &getInstanceProcAddr, .global),
    entry("vkDestroyInstance", &destroyInstance, .instance),
    entry("vkEnumeratePhysicalDevices", &enumeratePhysicalDevices, .instance),
    entry("vkEnumeratePhysicalDeviceGroups", &enumeratePhysicalDeviceGroups, .instance),
    entry("vkEnumeratePhysicalDeviceGroupsKHR", &enumeratePhysicalDeviceGroups, .instance),
    entry("vkGetPhysicalDeviceFeatures", &getPhysicalDeviceFeatures, .physical),
    entry("vkGetPhysicalDeviceFeatures2", &getPhysicalDeviceFeatures2, .physical),
    entry("vkGetPhysicalDeviceFeatures2KHR", &getPhysicalDeviceFeatures2, .physical),
    entry("vkGetPhysicalDeviceProperties", &getPhysicalDeviceProperties, .physical),
    entry("vkGetPhysicalDeviceProperties2", &getPhysicalDeviceProperties2, .physical),
    entry("vkGetPhysicalDeviceProperties2KHR", &getPhysicalDeviceProperties2, .physical),
    entry("vkGetPhysicalDeviceQueueFamilyProperties", &getPhysicalDeviceQueueFamilyProperties, .physical),
    entry("vkGetPhysicalDeviceQueueFamilyProperties2", &getPhysicalDeviceQueueFamilyProperties2, .physical),
    entry("vkGetPhysicalDeviceQueueFamilyProperties2KHR", &getPhysicalDeviceQueueFamilyProperties2, .physical),
    entry("vkGetPhysicalDeviceMemoryProperties", &getPhysicalDeviceMemoryProperties, .physical),
    entry("vkGetPhysicalDeviceMemoryProperties2", &getPhysicalDeviceMemoryProperties2, .physical),
    entry("vkGetPhysicalDeviceMemoryProperties2KHR", &getPhysicalDeviceMemoryProperties2, .physical),
    entry("vkGetPhysicalDeviceFormatProperties", &getPhysicalDeviceFormatProperties, .physical),
    entry("vkGetPhysicalDeviceFormatProperties2", &getPhysicalDeviceFormatProperties2, .physical),
    entry("vkGetPhysicalDeviceFormatProperties2KHR", &getPhysicalDeviceFormatProperties2, .physical),
    entry("vkGetPhysicalDeviceImageFormatProperties", &getPhysicalDeviceImageFormatProperties, .physical),
    entry("vkGetPhysicalDeviceImageFormatProperties2", &getPhysicalDeviceImageFormatProperties2, .physical),
    entry("vkGetPhysicalDeviceImageFormatProperties2KHR", &getPhysicalDeviceImageFormatProperties2, .physical),
    entry("vkGetPhysicalDeviceSparseImageFormatProperties", &getPhysicalDeviceSparseImageFormatProperties, .physical),
    entry("vkGetPhysicalDeviceSparseImageFormatProperties2", &getPhysicalDeviceSparseImageFormatProperties2, .physical),
    entry("vkGetPhysicalDeviceSparseImageFormatProperties2KHR", &getPhysicalDeviceSparseImageFormatProperties2, .physical),
    entry("vkGetPhysicalDeviceExternalBufferProperties", &getPhysicalDeviceExternalBufferProperties, .physical),
    entry("vkGetPhysicalDeviceExternalFenceProperties", &getPhysicalDeviceExternalFenceProperties, .physical),
    entry("vkGetPhysicalDeviceExternalSemaphoreProperties", &getPhysicalDeviceExternalSemaphoreProperties, .physical),
    entry("vkEnumerateDeviceExtensionProperties", &enumerateDeviceExtensionProperties, .physical),
    entry("vkEnumerateDeviceLayerProperties", &enumerateDeviceLayerProperties, .physical),
    entry("vkCreateDevice", &createDevice, .physical),
    entry("vkGetDeviceProcAddr", &getDeviceProcAddr, .device),
    entry("vkDestroyDevice", &destroyDevice, .device),
    entry("vkGetDeviceQueue", &getDeviceQueue, .device),
    entry("vkGetDeviceQueue2", &getDeviceQueue2, .device),
    entry("vkQueueSubmit", &queueSubmit, .device),
    entry("vkQueueWaitIdle", &queueWaitIdle, .device),
    entry("vkDeviceWaitIdle", &deviceWaitIdle, .device),
    entry("vkAllocateMemory", &allocateMemory, .device),
    entry("vkFreeMemory", &freeMemory, .device),
    entry("vkMapMemory", &mapMemory, .device),
    entry("vkUnmapMemory", &unmapMemory, .device),
    entry("vkFlushMappedMemoryRanges", &flushMappedMemoryRanges, .device),
    entry("vkInvalidateMappedMemoryRanges", &invalidateMappedMemoryRanges, .device),
    entry("vkGetDeviceMemoryCommitment", &getDeviceMemoryCommitment, .device),
    entry("vkCreateBuffer", &createBuffer, .device),
    entry("vkDestroyBuffer", &destroyBuffer, .device),
    entry("vkGetBufferMemoryRequirements", &getBufferMemoryRequirements, .device),
    entry("vkGetBufferMemoryRequirements2", &getBufferMemoryRequirements2, .device),
    entry("vkGetBufferMemoryRequirements2KHR", &getBufferMemoryRequirements2, .device),
    entry("vkBindBufferMemory", &bindBufferMemory, .device),
    entry("vkBindBufferMemory2", &bindBufferMemory2, .device),
    entry("vkBindBufferMemory2KHR", &bindBufferMemory2, .device),
    entry("vkCreateDescriptorSetLayout", &createDescriptorSetLayout, .device),
    entry("vkDestroyDescriptorSetLayout", &destroyDescriptorSetLayout, .device),
    entry("vkGetDescriptorSetLayoutSupport", &getDescriptorSetLayoutSupport, .device),
    entry("vkCreateDescriptorPool", &createDescriptorPool, .device),
    entry("vkDestroyDescriptorPool", &destroyDescriptorPool, .device),
    entry("vkResetDescriptorPool", &resetDescriptorPool, .device),
    entry("vkAllocateDescriptorSets", &allocateDescriptorSets, .device),
    entry("vkFreeDescriptorSets", &freeDescriptorSets, .device),
    entry("vkUpdateDescriptorSets", &updateDescriptorSets, .device),
    entry("vkCreatePipelineLayout", &createPipelineLayout, .device),
    entry("vkDestroyPipelineLayout", &destroyPipelineLayout, .device),
    entry("vkCreateShaderModule", &createShaderModule, .device),
    entry("vkDestroyShaderModule", &destroyShaderModule, .device),
    entry("vkCreatePipelineCache", &createPipelineCache, .device),
    entry("vkDestroyPipelineCache", &destroyPipelineCache, .device),
    entry("vkGetPipelineCacheData", &getPipelineCacheData, .device),
    entry("vkMergePipelineCaches", &mergePipelineCaches, .device),
    entry("vkCreateComputePipelines", &createComputePipelines, .device),
    entry("vkDestroyPipeline", &destroyPipeline, .device),
    entry("vkCreateCommandPool", &createCommandPool, .device),
    entry("vkDestroyCommandPool", &destroyCommandPool, .device),
    entry("vkResetCommandPool", &resetCommandPool, .device),
    entry("vkTrimCommandPool", &trimCommandPool, .device),
    entry("vkTrimCommandPoolKHR", &trimCommandPool, .device),
    entry("vkAllocateCommandBuffers", &allocateCommandBuffers, .device),
    entry("vkFreeCommandBuffers", &freeCommandBuffers, .device),
    entry("vkBeginCommandBuffer", &beginCommandBuffer, .device),
    entry("vkEndCommandBuffer", &endCommandBuffer, .device),
    entry("vkResetCommandBuffer", &resetCommandBuffer, .device),
    entry("vkCmdBindPipeline", &cmdBindPipeline, .device),
    entry("vkCmdBindDescriptorSets", &cmdBindDescriptorSets, .device),
    entry("vkCmdPushConstants", &cmdPushConstants, .device),
    entry("vkCmdDispatch", &cmdDispatch, .device),
    entry("vkCmdDispatchBase", &cmdDispatchBase, .device),
    entry("vkCmdDispatchIndirect", &cmdDispatchIndirect, .device),
    entry("vkCmdCopyBuffer", &cmdCopyBuffer, .device),
    entry("vkCmdFillBuffer", &cmdFillBuffer, .device),
    entry("vkCmdUpdateBuffer", &cmdUpdateBuffer, .device),
    entry("vkCmdPipelineBarrier", &cmdPipelineBarrier, .device),
    entry("vkCreateFence", &createFence, .device),
    entry("vkDestroyFence", &destroyFence, .device),
    entry("vkResetFences", &resetFences, .device),
    entry("vkGetFenceStatus", &getFenceStatus, .device),
    entry("vkWaitForFences", &waitForFences, .device),
    entry("vkCreateSemaphore", &createSemaphore, .device),
    entry("vkDestroySemaphore", &destroySemaphore, .device),
    entry("vkGetSemaphoreCounterValue", &getSemaphoreCounterValue, .device),
    entry("vkGetSemaphoreCounterValueKHR", &getSemaphoreCounterValue, .device),
    entry("vkWaitSemaphores", &waitSemaphores, .device),
    entry("vkWaitSemaphoresKHR", &waitSemaphores, .device),
    entry("vkSignalSemaphore", &signalSemaphore, .device),
    entry("vkSignalSemaphoreKHR", &signalSemaphore, .device),
};

fn find(name: []const u8) ?Proc {
    for (procs) |x| if (std.mem.eql(u8, x.name, name)) return x;
    return null;
}

pub const PFN = ?*const anyopaque;

/// vk_icdGetInstanceProcAddr and vkGetInstanceProcAddr: every entry point
/// (with no instance: the global ones only).
pub fn getInstanceProcAddr(inst: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) PFN {
    const x = find(cstr(name)) orelse return null;
    if (inst == null and x.level != .global) return null;
    return x.f;
}

/// vkGetDeviceProcAddr: the device-level entry points.
pub fn getDeviceProcAddr(_: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) PFN {
    const x = find(cstr(name)) orelse return null;
    return if (x.level == .device) x.f else null;
}

/// vk_icdGetPhysicalDeviceProcAddr: the physical-device-level ones.
pub fn getPhysicalDeviceProcAddr(_: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) PFN {
    const x = find(cstr(name)) orelse return null;
    return if (x.level == .physical) x.f else null;
}

/// vk_icdNegotiateLoaderICDInterfaceVersion: the loader's highest version
/// in, the one both speak out.
pub fn negotiate(version: ?*u32) callconv(.c) Result {
    const v = version orelse return R.error_incompatible_driver;
    if (v.* < 2) return R.error_incompatible_driver;
    v.* = @min(v.*, ICD_INTERFACE_VERSION);
    return R.success;
}

test "icd: handles round-trip and keep their kinds apart" {
    const h = handle(.buffer, 7);
    try std.testing.expectEqual(@as(?u32, 7), unhandle(.buffer, h));
    try std.testing.expectEqual(@as(?u32, null), unhandle(.memory, h));
    try std.testing.expectEqual(@as(?u32, null), unhandle(.buffer, 0));
}

test "icd: the block bitmap hands out runs, first fit" {
    var b: Bitmap(256) = .{};
    try std.testing.expectEqual(@as(?u32, 0), b.take(3));
    try std.testing.expectEqual(@as(?u32, 3), b.take(64));
    b.give(0, 3);
    try std.testing.expectEqual(@as(?u32, 0), b.take(2));
    try std.testing.expectEqual(@as(?u32, 67), b.take(189));
    try std.testing.expectEqual(@as(?u32, null), b.take(2));
    try std.testing.expectEqual(@as(?u32, 2), b.take(1));
}

test "icd: every entry point's name is unique, and the loader's lookups find them by level" {
    for (procs, 0..) |a, i| for (procs[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    try std.testing.expect(getInstanceProcAddr(null, "vkCreateInstance") != null);
    try std.testing.expect(getInstanceProcAddr(null, "vkCreateDevice") == null);
    try std.testing.expect(getDeviceProcAddr(null, "vkCmdDispatch") != null);
    try std.testing.expect(getDeviceProcAddr(null, "vkCreateInstance") == null);
    try std.testing.expect(getPhysicalDeviceProcAddr(null, "vkGetPhysicalDeviceProperties2KHR") != null);
    var v: u32 = 7;
    try std.testing.expectEqual(R.success, negotiate(&v));
    try std.testing.expectEqual(ICD_INTERFACE_VERSION, v);
}
