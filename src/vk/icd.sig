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
//! A Vulkan 1.1 device (instance version 1.1) for graphics and compute,
//! truthful about it (multiview and the features below apart; 4x
//! multisampling keeps one sample, "Multisampling" says how; PLAN.md says
//! what is left):
//!
//! - **One queue family**, GRAPHICS, COMPUTE and TRANSFER, one queue (wgpu
//!   takes an adapter whose first family has GRAPHICS).
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
//! - **Graphics** (the section "Graphics" below): images (1D, 2D, arrays,
//!   cube, 3D; mip levels) in the formats format.sig lists, views, samplers,
//!   render passes and framebuffers (the first subpass), graphics pipelines
//!   of vertex and fragment SPIR-V drawn by gfxapi's raster, draws (direct,
//!   indexed, indirect), clears, copies between buffers and images, blits.
//! - **Features**: robustBufferAccess (every buffer access checked against
//!   its descriptor's range in the kernel), fullDrawIndexUint32,
//!   independentBlend, multiDrawIndirect, drawIndirectFirstInstance.
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
const format = @import("format.sig");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const raster = gfxapi.raster;
const texture = gfxapi.texture;
const wl = gfxapi.wayland;
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
    /// dma-bufs out and in and fence files (Galaxy's render node, as EGL
    /// has them): external memory, semaphores and fences, and swapchains.
    /// Null: none of those extensions is offered.
    host: ?gfxapi.host.Host = null,
    /// the app's libwayland-client, found in the process (null: no Wayland
    /// surface is supported)
    wayland: ?*const fn () ?*const wl.Client = null,
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
pub const DEVICE_VERSION = makeVersion(1, 1, 0);
pub const DRIVER_VERSION = makeVersion(0, 1, 0);
/// The loader-ICD interface version this driver speaks.
pub const ICD_INTERFACE_VERSION: u32 = 5;
const ICD_LOADER_MAGIC: usize = 0x01CDC0DE;

/// `host`: offered only with the root's Host (Gpu.host): external memory
/// and swapchains.
const Ext = struct { name: []const u8, version: u32, host: bool = false };
pub const instance_extensions = [_]Ext{
    .{ .name = "VK_KHR_get_physical_device_properties2", .version = 2 },
    .{ .name = "VK_KHR_external_memory_capabilities", .version = 1 },
    .{ .name = "VK_KHR_external_semaphore_capabilities", .version = 1 },
    .{ .name = "VK_KHR_external_fence_capabilities", .version = 1 },
    .{ .name = "VK_KHR_surface", .version = 25 },
    .{ .name = "VK_KHR_wayland_surface", .version = 6 },
};
pub const device_extensions = [_]Ext{
    .{ .name = "VK_KHR_maintenance1", .version = 2 },
    .{ .name = "VK_KHR_storage_buffer_storage_class", .version = 1 },
    .{ .name = "VK_KHR_timeline_semaphore", .version = 2 },
    .{ .name = "VK_KHR_bind_memory2", .version = 1 },
    .{ .name = "VK_KHR_get_memory_requirements2", .version = 1 },
    .{ .name = "VK_KHR_dedicated_allocation", .version = 3 },
    .{ .name = "VK_KHR_image_format_list", .version = 1 },
    .{ .name = "VK_KHR_16bit_storage", .version = 1 },
    .{ .name = "VK_KHR_shader_float16_int8", .version = 1 },
    .{ .name = "VK_KHR_swapchain", .version = 70, .host = true },
    .{ .name = "VK_KHR_external_memory", .version = 1, .host = true },
    .{ .name = "VK_KHR_external_memory_fd", .version = 1, .host = true },
    .{ .name = "VK_EXT_external_memory_dma_buf", .version = 1, .host = true },
    .{ .name = "VK_EXT_image_drm_format_modifier", .version = 2, .host = true },
    .{ .name = "VK_KHR_external_semaphore", .version = 1, .host = true },
    .{ .name = "VK_KHR_external_semaphore_fd", .version = 1, .host = true },
    .{ .name = "VK_KHR_external_fence", .version = 1, .host = true },
    .{ .name = "VK_KHR_external_fence_fd", .version = 1, .host = true },
};

pub const MAX_INSTANCES = 8;
pub const MAX_DEVICES = 8;
pub const MAX_MEMORY = 4096;
pub const MAX_BUFFERS = 8192;
pub const MAX_SET_LAYOUTS = 512;
pub const MAX_LAYOUT_BINDINGS = 128;
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
const MAX_RUN_PARAMS = 2 * spirv.MAX_BINDINGS + MAX_PUSH_BYTES / 4 + 4 * spirv.MAX_BINDINGS + 8;
const STAGING_BYTES = 1 << 20;
const GROUP = 64;
const MAX_GROUPS: u32 = 65535;

const NONE: u32 = 0xffff_ffff;
const WHOLE_SIZE: u64 = ~@as(u64, 0);

const DescType = struct {
    const sampler = 0;
    const combined = 1;
    const sampled_image = 2;
    const storage_image = 3;
    const input_attachment = 10;
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

const Tag = enum(u8) { memory = 1, buffer, set_layout, pipeline_layout, pool, set, shader, pipeline, cmd_pool, fence, semaphore, cache, image, view, sampler, render_pass, framebuffer, gpipe, template, swapchain };

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
    xfer: ?gpu.Program,
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
    /// a swapchain's image's (freed with the swapchain)
    swapchain: bool = false,
};
const Buffer = struct { live: bool, dev: u32, size: u64, usage: u32, mem: u32, offset: u64 };
const LayoutBinding = struct { binding: u32, dtype: u32, count: u32, first: u32, dyn_first: u32, imm: u32 = NONE };
const SetLayout = struct {
    live: bool,
    destroyed: bool,
    refs: u32,
    n: u32,
    b: [MAX_LAYOUT_BINDINGS]LayoutBinding,
    n_desc: u32,
    n_dyn: u32,
};
const Desc = struct { buf: u32, offset: u64, range: u64, view: u32 = NONE, sampler: u32 = NONE };
const Pool = struct { live: bool, dev: u32, flags: u32, max_sets: u32, n_sets: u32, max_desc: u32, used_desc: u32 };
const Set = struct { live: bool, pool: u32, layout: u32, first: u32, n: u32 };
const PipelineLayout = struct { live: bool, n_sets: u32, sets: [MAX_SETS_PER_LAYOUT]u32, push_bytes: u32 };
/// (graphics pipelines compile their stages again for each colour
/// attachment and when first drawn: they hold the module)
const Shader = struct { live: bool, at: u32, n: u32, refs: u32 = 1 };
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
    /// made for export (VkExportSemaphoreCreateInfo): a submission that
    /// signals it is waited for (the external memory section says why)
    exported: bool = false,
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
    // graphics
    var images: [MAX_IMAGES]Image = undefined;
    var views: [MAX_VIEWS]View = undefined;
    var samplers: [MAX_SAMPLERS]Sampler = undefined;
    var render_passes: [MAX_RENDER_PASSES]RenderPass = undefined;
    var framebuffers: [MAX_FRAMEBUFFERS]Framebuffer = undefined;
    var gpipes: [MAX_GPIPES]GPipe = undefined;
    var templates: [MAX_TEMPLATES]Template = undefined;
    var swapchains: [MAX_SWAPCHAINS]Swapchain = undefined;
    /// the raster under every device's draws (gfxapi's engine), made at
    /// the first vkCreateDevice
    var eng: engine.Engine = undefined;
    var eng_live = false;
    var slabs: [16]engine.Slab = undefined;
    /// the colour a draw without colour attachments writes nothing to
    var null_color: gpu.Buffer = .{};
    /// KIR's interpreter's scratch, for draws whose kernels the GPU refused
    var cpu_work: [16 << 20]u8 align(64) = undefined;
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
    markAll("images");
    markAll("views");
    markAll("samplers");
    markAll("render_passes");
    markAll("framebuffers");
    markAll("gpipes");
    markAll("templates");
    markAll("swapchains");
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
    dropEngine();
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
    // (32-bit indices; each colour attachment is drawn by its own pass
    // of the raster, so blending is per attachment; indirect draws are
    // read back and looped)
    f.fullDrawIndexUint32 = 1;
    f.independentBlend = 1;
    f.multiDrawIndirect = 1;
    f.drawIndirectFirstInstance = 1;
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
            // (halves are f32 registers rounded to half precision, 16 bits
            // in memory: the SPIR-V front end's)
            ST.physical_device_16bit_storage_features => {
                const sf: *abi.PhysicalDevice16BitStorageFeatures = @ptrCast(@alignCast(c));
                sf.storageBuffer16BitAccess = 1;
                sf.uniformAndStorageBuffer16BitAccess = 1;
                sf.storagePushConstant16 = 1;
                sf.storageInputOutput16 = 1;
            },
            ST.physical_device_shader_float16_int8_features => {
                const hf: *abi.PhysicalDeviceShaderFloat16Int8Features = @ptrCast(@alignCast(c));
                hf.shaderFloat16 = 1;
                hf.shaderInt8 = 0;
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
    gfxLimits(&l);
    l.maxUniformBufferRange = 65536;
    l.maxStorageBufferRange = 1 << 31;
    l.maxPushConstantsSize = MAX_PUSH_BYTES;
    l.maxMemoryAllocationCount = MAX_MEMORY;
    l.bufferImageGranularity = 1;
    l.maxBoundDescriptorSets = MAX_SETS_PER_LAYOUT;
    // (a stage's buffers are its pipeline's KIR bindings, spirv.MAX_BINDINGS
    // of them: WebGPU's 12 uniform and 8 storage buffers a stage fit)
    l.maxPerStageDescriptorUniformBuffers = 12;
    l.maxPerStageDescriptorStorageBuffers = 8;
    l.maxDescriptorSetUniformBuffers = 24;
    l.maxDescriptorSetUniformBuffersDynamic = 8;
    l.maxDescriptorSetStorageBuffers = 16;
    l.maxDescriptorSetStorageBuffersDynamic = 4;
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
                // (the SPIR-V front end's, over KIR's shfl, vote and ballot;
                // a fragment shader's lanes are the raster's pixels, in quads)
                sp.supportedStages = 0x20 | 0x10; // compute, fragment
                // basic, vote, arithmetic, ballot, shuffle, relative, clustered, quad
                sp.supportedOperations = if (g.dev.caps.subgroup <= 32) 0xff else 0;
                sp.quadOperationsInAllStages = 0;
            },
            ST.physical_device_multiview_properties => {
                const mp: *abi.PhysicalDeviceMultiviewProperties = @ptrCast(@alignCast(c));
                mp.maxMultiviewViewCount = 1;
                mp.maxMultiviewInstanceIndex = 0x7ffffff;
            },
            ST.physical_device_point_clipping_properties => {
                const pp: *abi.PhysicalDevicePointClippingProperties = @ptrCast(@alignCast(c));
                pp.pointClippingBehavior = 0; // all clip planes
            },
            ST.physical_device_protected_memory_properties => {
                const pp: *abi.PhysicalDeviceProtectedMemoryProperties = @ptrCast(@alignCast(c));
                pp.protectedNoFault = 0;
            },
            ST.physical_device_maintenance_3_properties => {
                const mp: *abi.PhysicalDeviceMaintenance3Properties = @ptrCast(@alignCast(c));
                mp.maxPerSetDescriptors = MAX_LAYOUT_BINDINGS;
                // (and below: what one layout's bindings may hold)
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
    .queueFlags = 0x1 | 0x2 | 0x4, // GRAPHICS | COMPUTE | TRANSFER
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

fn formatProperties(f: u32) abi.FormatProperties {
    const p = format.props(f);
    return .{ .linearTilingFeatures = p.linear, .optimalTilingFeatures = p.optimal, .bufferFeatures = p.buffer };
}

fn getPhysicalDeviceFormatProperties(_: ?*anyopaque, f: u32, out: ?*abi.FormatProperties) callconv(.c) void {
    (out orelse return).* = formatProperties(f);
}

fn getPhysicalDeviceFormatProperties2(_: ?*anyopaque, f: u32, out: ?*abi.FormatProperties2) callconv(.c) void {
    const o = out orelse return;
    o.formatProperties = formatProperties(f);
    fillModifierList(f, o.pNext);
}

fn getPhysicalDeviceImageFormatProperties(_: ?*anyopaque, f: u32, ty: u32, tiling: u32, usage: u32, flags: u32, out: ?*abi.ImageFormatProperties) callconv(.c) Result {
    const o = out orelse return R.error_initialization_failed;
    return imageFormatProperties(f, ty, tiling, usage, flags, o);
}

fn getPhysicalDeviceImageFormatProperties2(_: ?*anyopaque, info: ?*const abi.PhysicalDeviceImageFormatInfo2, out: ?*abi.ImageFormatProperties2) callconv(.c) Result {
    const i = info orelse return R.error_initialization_failed;
    const o = out orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    // (a DRM format modifier: linear is the one there is)
    var tiling = i.tiling;
    if (tiling == abi.TILING_DRM_FORMAT_MODIFIER) {
        const b = findIn(i.pNext, ST.physical_device_image_drm_format_modifier_info_ext) orelse return R.error_format_not_supported;
        const mi: *const abi.PhysicalDeviceImageDrmFormatModifierInfoEXT = @ptrCast(@alignCast(b));
        if (mi.drmFormatModifier != abi.DRM_MOD_LINEAR) return R.error_format_not_supported;
        tiling = 1;
    }
    const res = imageFormatProperties(i.format, i.@"type", tiling, i.usage, i.flags, &o.imageFormatProperties);
    if (res != R.success) return res;
    var ext = std.mem.zeroes(abi.ExternalMemoryProperties);
    if (findIn(i.pNext, ST.physical_device_external_image_format_info)) |b| {
        const ei: *const abi.PhysicalDeviceExternalImageFormatInfo = @ptrCast(@alignCast(b));
        if (ei.handleType != 0) {
            ext = externalMemoryProps(ei.handleType);
            if (ext.externalMemoryFeatures == 0) return R.error_format_not_supported;
        }
    }
    var cur: ?*abi.BaseOutStructure = @ptrCast(@alignCast(o.pNext));
    while (cur) |c| : (cur = nextOut(c)) {
        if (c.sType == ST.external_image_format_properties) {
            const ep: *abi.ExternalImageFormatProperties = @ptrCast(@alignCast(c));
            ep.externalMemoryProperties = ext;
        }
    }
    return R.success;
}

fn getPhysicalDeviceSparseImageFormatProperties(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: u32, count: ?*u32, _: ?*anyopaque) callconv(.c) void {
    if (count) |c| c.* = 0;
}

fn getPhysicalDeviceSparseImageFormatProperties2(_: ?*anyopaque, _: ?*const anyopaque, count: ?*u32, _: ?*anyopaque) callconv(.c) void {
    if (count) |c| c.* = 0;
}

/// The device extensions this GPU has (those needing a Host only with one).
fn deviceExtensions(out: *[device_extensions.len]abi.ExtensionProperties) []const abi.ExtensionProperties {
    const all = comptime extList(&device_extensions);
    const host = hasHost();
    var n: usize = 0;
    for (device_extensions, 0..) |e, i| {
        if (e.host and !host) continue;
        out[n] = all[i];
        n += 1;
    }
    return out[0..n];
}

fn deviceHasExt(name: []const u8) bool {
    for (device_extensions) |e| {
        if (std.mem.eql(u8, e.name, name)) return !e.host or hasHost();
    }
    return false;
}

fn enumerateDeviceExtensionProperties(_: ?*anyopaque, layer: ?[*:0]const u8, count: ?*u32, out: ?[*]abi.ExtensionProperties) callconv(.c) Result {
    if (layer != null) return R.error_layer_not_present;
    lock();
    defer unlock();
    var buf: [device_extensions.len]abi.ExtensionProperties = undefined;
    return enumerate(abi.ExtensionProperties, deviceExtensions(&buf), count, out);
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
        if (!deviceHasExt(name)) {
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
        .xfer = null,
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
    d.xfer = xferKernel(g);
    if (d.copy32 == null or d.copy8 == null or d.fill32 == null or d.xfer == null) {
        say("vkCreateDevice: the copy kernels did not compile or load", .{});
        dropDevice(g, &d);
        return R.error_initialization_failed;
    }
    if (!T.eng_live) {
        T.eng.init(.{ .dev = dev, .compiler = g.compile, .work = g.work, .slabs = &T.slabs, .cpu_work = &T.cpu_work });
        T.eng_live = true;
        if (!T.eng.onGpu()) say("vkCreateDevice: the raster's kernels did not load ({s}): draws are dropped", .{if (T.eng.why) |w| @errorName(w) else "?"});
    }
    T.devices[di] = d;
    T.dev_hdr[di] = .{ .loader = ICD_LOADER_MAGIC };
    T.queue_hdr[di] = .{ .loader = ICD_LOADER_MAGIC };
    (out orelse return R.error_initialization_failed).* = &T.dev_hdr[di];
    return R.success;
}

fn dropDevice(g: *Gpu, d: *Device) void {
    const dev = g.dev;
    inline for (.{ "copy32", "copy8", "fill32", "xfer" }) |f| {
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
    for (&T.swapchains) |*sc| if (sc.live and sc.dev == di) dropSwapchain(g, sc);
    for (&T.pipelines) |*p| if (p.live and p.dev == di) {
        g.dev.unload(&p.prog);
        p.live = false;
    };
    dropDeviceGraphics(di);
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
    // (the raster goes with the last device)
    var any = false;
    for (&T.devices) |*x| any = any or x.live;
    if (!any) dropEngine();
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
    // a dma-buf in: this device's memory over it, zero-copy
    if (findIn(ai.pNext, ST.import_memory_fd_info_khr)) |base| {
        const im: *const abi.ImportMemoryFdInfoKHR = @ptrCast(@alignCast(base));
        if (im.handleType != 0) {
            const host = g.host orelse return R.error_invalid_external_handle;
            if (im.handleType & EXT_MEM_FDS == 0 or im.fd < 0) return R.error_invalid_external_handle;
            const ib = host.importFd(host.ctx, im.fd) orelse {
                say("vkAllocateMemory: the render node refused dma-buf fd {d}", .{im.fd});
                return R.error_invalid_external_handle;
            };
            if (ib.bytes < ai.allocationSize) {
                g.dev.free(ib);
                return R.error_invalid_external_handle;
            }
            // (the fd is the driver's now: the buffer holds the memory)
            host.close(host.ctx, im.fd);
            T.memories[mi] = .{ .live = true, .dev = di, .buf = ib, .size = ai.allocationSize, .host = t.flags & MEM_HOST_VISIBLE != 0 and ib.cpu.len != 0, .mapped = false, .dirty = false, .dirty_fence = 0 };
            (out orelse return R.error_initialization_failed).* = handle(.memory, mi);
            return R.success;
        }
    }
    // memory for export: system memory, as EGL's window buffers (what other
    // contexts and the compositor map)
    var kind = t.kind;
    if (findIn(ai.pNext, ST.export_memory_allocate_info)) |base| {
        const ex: *const abi.ExportMemoryAllocateInfo = @ptrCast(@alignCast(base));
        if (ex.handleTypes != 0) {
            if (g.host == null or ex.handleTypes & ~EXT_MEM_FDS != 0) return R.error_invalid_external_handle;
            kind = .host;
        }
    }
    const size = @max(ai.allocationSize, 4);
    const b = g.dev.alloc(size, kind) catch return R.error_out_of_device_memory;
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
    if (m.swapchain) return;
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
        // (an immutable sampler: the first one's, as the sets' descriptors start)
        if (b.pImmutableSamplers) |ims| {
            if (b.descriptorCount != 0 and (b.descriptorType == DescType.sampler or b.descriptorType == DescType.combined)) l.b[j].imm = unhandle(.sampler, ims[0]) orelse NONE;
        }
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
        for (l.b[0..l.n]) |b| {
            if (b.imm == NONE) continue;
            for (T.descs[first.? + b.first ..][0..b.count]) |*d| d.sampler = b.imm;
        }
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
            DescType.sampler, DescType.combined, DescType.sampled_image, DescType.storage_image, DescType.input_attachment => {
                for (0..w.descriptorCount) |e| {
                    const d = descAt(s, w.dstBinding, w.dstArrayElement + @as(u32, @intCast(e))) orelse break;
                    const ii = w.pImageInfo.?[e];
                    if (w.descriptorType != DescType.sampler) d.view = unhandle(.view, ii.imageView) orelse NONE;
                    if (w.descriptorType == DescType.sampler or w.descriptorType == DescType.combined) {
                        if (unhandle(.sampler, ii.sampler)) |si| d.sampler = si;
                    }
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
    T.shaders[i] = .{ .live = true, .at = at, .n = n, .refs = 1 };
    (out orelse return R.error_initialization_failed).* = handle(.shader, i);
    return R.success;
}

fn destroyShaderModule(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.shader, h) orelse return;
    if (!T.shaders[i].live) return;
    unrefShader(i);
}

fn unrefShader(i: u32) void {
    const s = &T.shaders[i];
    s.refs -= 1;
    if (s.refs != 0) return;
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
    var opts = spirv.Options{ .robust = T.devices[di].robust, .subgroup = theGpu().?.dev.caps.subgroup };
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
    if (unhandle(.gpipe, h)) |gi| return dropGPipe(gi);
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

const Cmd = enum(u16) { bind_pipeline, bind_sets, push, dispatch, dispatch_indirect, copy, fill, update, bind_gpipe, begin_pass, end_pass, bind_vb, bind_ib, viewport, scissor, stencil, blend_consts, draw, draw_indirect, clear_atts, copy_b2i, copy_i2b, copy_i2i, clear_image, blit };
const CmdHead = extern struct { tag: u16, pad: u16 = 0, size: u32 };

const BindSets = extern struct { point: u32, first: u32, count: u32, n_dyn: u32, sets: [MAX_SETS_PER_LAYOUT]u32, dyn: [MAX_DYNAMIC * 2]u32 };
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
    if (bind_point == 0) return put(cb, .bind_gpipe, unhandle(.gpipe, ph) orelse NONE);
    if (bind_point != 1) return;
    put(cb, .bind_pipeline, unhandle(.pipeline, ph) orelse NONE);
}

fn cmdBindDescriptorSets(h: ?*anyopaque, bind_point: u32, _: u64, first: u32, count: u32, sets: ?[*]const u64, n_dyn: u32, dyn: ?[*]const u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = cbOf(h) orelse return;
    if (bind_point > 1) return;
    if (first + count > MAX_SETS_PER_LAYOUT or n_dyn > MAX_DYNAMIC * 2) {
        cb.failed = true;
        return;
    }
    var b = BindSets{ .point = bind_point, .first = first, .count = count, .n_dyn = n_dyn, .sets = undefined, .dyn = undefined };
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
    gfx: Gfx = .{},

    fn dev(e: *Exec) *Device {
        return &T.devices[e.di];
    }

    /// Runs what is queued (one gpu.Device run); the device's last fence.
    fn flush(e: *Exec) Result {
        if (T.n_ds == 0) return R.success;
        e.toIcd();
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
        // (the raster's draws recorded so far run first: one queue, in order)
        e.toIcd();
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
            if (want.kind == .storage_image) {
                // the view's level and first layer, and the words the
                // front end addresses texels by (spirv's header); none
                // bound: 0 by 0, nothing read or written
                const v = viewOf(d.view) orelse continue;
                const im = &T.images[v.image];
                if (!im.live or im.mem == NONE or !T.memories[im.mem].live) continue;
                const lv = v.base_level;
                const depth = if (im.ty == 2) im.ld(lv) else v.layers;
                const w0 = p.info.imageWord(@intCast(i));
                bufs[i] = T.memories[im.mem].buf;
                params[2 * i] = @truncate(im.at(lv, if (im.ty == 2) 0 else v.base_layer));
                params[2 * i + 1] = @intCast(@min(im.slice(lv) * depth, 0xffff_ffff));
                params[w0] = im.pitch(lv);
                params[w0 + 1] = @intCast(@min(im.slice(lv), 0xffff_ffff));
                params[w0 + 2] = im.lw(lv) | im.lh(lv) << 16;
                params[w0 + 3] = depth;
                if (p.writes >> @intCast(i) & 1 != 0) e.markDirty(im.mem);
                continue;
            }
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
        const np = @max(p.info.paramWords(), p.param_words);
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
        e.gfx = .{};
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
                const sets = if (b.point == 0) &e.gfx.sets else &e.sets;
                const dyn = if (b.point == 0) &e.gfx.dyn else &e.dyn;
                var dyn_at: u32 = 0;
                for (0..b.count) |i| {
                    const set_no = b.first + i;
                    sets[set_no] = b.sets[i];
                    if (b.sets[i] == NONE) continue;
                    const l = &T.set_layouts[T.sets[b.sets[i]].layout];
                    for (0..l.n_dyn) |j| {
                        dyn[set_no][j] = if (dyn_at < b.n_dyn) b.dyn[dyn_at] else 0;
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
            else => e.graphics(tag, body),
        }
    }

    // ── Graphics (the raster's draws, transfers of images) ──

    /// The raster's recorded draws run (before a kernel of the driver's):
    /// the device's last fence is theirs then.
    fn toIcd(e: *Exec) void {
        if (!T.eng_live or T.eng.n_ops == 0) return;
        T.eng.flush();
        if (T.eng.lost) {
            e.dev().lost = true;
            e.err = R.error_device_lost;
            return;
        }
        if (T.eng.ran != 0) e.dev().last_fence = T.eng.fences[T.eng.ran % T.eng.fences.len];
    }

    /// The driver's queued kernels run (before a draw of the raster's).
    fn toEngine(e: *Exec) bool {
        if (T.n_ds == 0) return true;
        const res = e.flush();
        if (res != R.success) {
            e.err = res;
            return false;
        }
        return true;
    }

    fn sayOnce(e: *Exec, bit: u5, comptime fmt: []const u8, a: anytype) void {
        if (e.gfx.said >> bit & 1 != 0) return;
        e.gfx.said |= @as(u32, 1) << bit;
        say(fmt, a);
    }

    fn graphics(e: *Exec, tag: Cmd, body: []const u8) void {
        const gx = &e.gfx;
        switch (tag) {
            .bind_gpipe => gx.pipe = as(u32, body),
            .begin_pass => e.beginPass(as(BeginPass, body)),
            .end_pass => {
                e.resolvePass();
                gx.rp = NONE;
                gx.fb = NONE;
            },
            .bind_vb => {
                const b = as(BindVb, body);
                for (0..b.count) |i| {
                    const at = b.first + i;
                    if (at >= MAX_VB) break;
                    gx.vb[at] = .{ .buf = b.bufs[i], .off = b.offs[i] };
                }
            },
            .bind_ib => {
                const b = as(BindIb, body);
                gx.ib = b.buf;
                gx.ib_off = b.off;
                gx.ib_size = if (b.ty == 1) 4 else if (b.ty == 0) 2 else 1;
            },
            .viewport => gx.viewport = as(abi.Viewport, body),
            .scissor => gx.scissor = as(abi.Rect2D, body),
            .stencil => {
                const s = as(StencilSet, body);
                for (0..2) |f| {
                    if (s.faces >> @intCast(f) & 1 == 0) continue;
                    switch (s.what) {
                        0 => gx.sref[f] = @truncate(s.value),
                        1 => gx.scmask[f] = @truncate(s.value),
                        else => gx.swmask[f] = @truncate(s.value),
                    }
                }
            },
            .blend_consts => gx.consts = as([4]f32, body),
            .draw => e.draw(as(DrawCmd, body)),
            .draw_indirect => e.drawIndirect(as(DrawIndirect, body)),
            .clear_atts => e.clearAttachments(as(ClearAtts, body)),
            .copy_b2i, .copy_i2b => e.copyBufImage(as(BufImage, body), tag == .copy_b2i),
            .copy_i2i => e.copyImages(as(ImgImg, body)),
            .clear_image => e.clearImage(as(ClearImage, body)),
            .blit => e.blitImages(as(Blit, body)),
            else => {},
        }
    }

    /// A transfer-kernel run over (w, h, slices) texels.
    fn xfer(e: *Exec, src: gpu.Buffer, dst: gpu.Buffer, p: [X_PARAMS]u32, h: u32, slices: u32) void {
        if (p[X_W] == 0 or h == 0 or slices == 0) return;
        const d = e.dev();
        var z: u32 = 0;
        while (z < slices) {
            const nz = @min(slices - z, MAX_GROUPS);
            var q = p;
            q[X_SOFF] += z * p[X_SSLICE];
            q[X_DOFF] += z * p[X_DSLICE];
            var y: u32 = 0;
            while (y < h) {
                const ny = @min(h - y, MAX_GROUPS);
                var q2 = q;
                q2[X_SOFF] += y * p[X_SROW];
                q2[X_DOFF] += y * p[X_DROW];
                e.kernel(&d.xfer.?, .{ (p[X_W] + GROUP - 1) / GROUP, ny, nz }, &.{ src, dst }, &q2);
                y += ny;
            }
            z += nz;
        }
    }

    /// Fills a rectangle of an image's (level, layers) with a texel (the
    /// bits `keep` says kept, for 4-byte texels).
    fn fillImage(e: *Exec, im: *const Image, level: u32, layer0: u32, layers: u32, x0: u32, y0: u32, w: u32, h: u32, value: [4]u32, keep: u32) void {
        const l = @min(level, im.levels - 1);
        const x1 = @min(x0 + w, im.lw(l));
        const y1 = @min(y0 + h, im.lh(l));
        if (x1 <= x0 or y1 <= y0) return;
        const nl = @min(layers, im.slices(l) -| layer0);
        var p = [_]u32{0} ** X_PARAMS;
        const b = im.fi.bytes;
        p[X_DOFF] = @intCast(im.at(l, layer0) + @as(u64, y0) * im.pitch(l) + @as(u64, x0) * b);
        p[X_DROW] = im.pitch(l);
        p[X_DSLICE] = @intCast(im.slice(l));
        p[X_W] = x1 - x0;
        p[X_MODE] = @intFromEnum(XMode.fill);
        p[X_DB] = b;
        p[X_SB] = b;
        @memcpy(p[X_V..][0..4], &value);
        p[X_KEEP] = if (b == 4) keep else 0;
        e.xfer(e.dev().dummy, T.memories[im.mem].buf, p, y1 - y0, nl);
        e.markDirty(im.mem);
    }

    /// A depth-stencil clear's texel and kept bits.
    fn dsClear(depth: ?f32, stencil: ?u32) struct { v: u32, keep: u32 } {
        var v: u32 = 0;
        var keep: u32 = 0xffff_ffff;
        if (depth) |z| {
            v |= unorm(z, 16777215);
            keep &= 0xff00_0000;
        }
        if (stencil) |s| {
            v |= (s & 0xff) << 24;
            keep &= 0x00ff_ffff;
        }
        return .{ .v = v, .keep = keep };
    }

    /// Clears attachment `a` of the current framebuffer over `rect` (the
    /// framebuffer's coordinates), its aspects as `aspects` says.
    fn clearAtt(e: *Exec, a: u32, aspects: u32, cv: abi.ClearValue, x0: i32, y0: i32, w: u32, h: u32, layer0: u32, layers: u32) void {
        const fb = &T.framebuffers[e.gfx.fb];
        if (a >= fb.n) return;
        const v = viewOf(fb.views[a]) orelse return;
        const im = &T.images[v.image];
        const xs: u32 = @intCast(@max(x0, 0));
        const ys: u32 = @intCast(@max(y0, 0));
        const nl = @min(layers, v.layers);
        if (im.fi.aspects == format.ASPECT_COLOR) {
            e.fillImage(im, v.base_level, v.base_layer + layer0, nl, xs, ys, w, h, colorWords(im.fi, cv.color), 0);
        } else {
            const c = dsClear(if (aspects & format.ASPECT_DEPTH != 0 and im.fi.aspects & format.ASPECT_DEPTH != 0) cv.depthStencil.depth else null, if (aspects & format.ASPECT_STENCIL != 0 and im.fi.aspects & format.ASPECT_STENCIL != 0) cv.depthStencil.stencil else null);
            if (c.keep == 0xffff_ffff) return;
            e.fillImage(im, v.base_level, v.base_layer + layer0, nl, xs, ys, w, h, .{ c.v, 0, 0, 0 }, c.keep);
        }
    }

    fn beginPass(e: *Exec, b: BeginPass) void {
        const gx = &e.gfx;
        if (b.rp >= MAX_RENDER_PASSES or !T.render_passes[b.rp].live or b.fb >= MAX_FRAMEBUFFERS or !T.framebuffers[b.fb].live) return;
        gx.rp = b.rp;
        gx.fb = b.fb;
        gx.area = .{ .offset = .{ .x = b.x, .y = b.y }, .extent = .{ .width = b.w, .height = b.h } };
        const rp = &T.render_passes[b.rp];
        const fb = &T.framebuffers[b.fb];
        for (0..rp.n_att) |a| {
            const at = rp.att[a];
            const fi = format.image(at.fmt) orelse continue;
            var aspects: u32 = 0;
            if (fi.aspects == format.ASPECT_COLOR) {
                if (at.load == 1) aspects = format.ASPECT_COLOR;
            } else {
                if (at.load == 1) aspects |= format.ASPECT_DEPTH;
                if (at.sload == 1) aspects |= format.ASPECT_STENCIL;
            }
            if (aspects == 0 or a >= b.n) continue;
            e.clearAtt(@intCast(a), aspects, b.clears[a], b.x, b.y, b.w, b.h, 0, fb.layers);
        }
    }

    /// The pass's resolve attachments: each colour attachment's render
    /// area copied into its resolve attachment (one sample kept: a copy).
    fn resolvePass(e: *Exec) void {
        const gx = &e.gfx;
        if (gx.rp == NONE or gx.fb == NONE) return;
        const rp = &T.render_passes[gx.rp];
        const fb = &T.framebuffers[gx.fb];
        for (0..rp.n_color) |j| {
            const c = rp.color[j];
            const r_ = rp.resolve[j];
            if (c == NONE or r_ == NONE or c >= fb.n or r_ >= fb.n) continue;
            const sv = viewOf(fb.views[c]) orelse continue;
            const dv = viewOf(fb.views[r_]) orelse continue;
            const off = abi.Offset3D{ .x = gx.area.offset.x, .y = gx.area.offset.y, .z = 0 };
            e.copyImages(.{ .src = sv.image, .dst = dv.image, .region = .{
                .srcSubresource = .{ .aspectMask = format.ASPECT_COLOR, .mipLevel = sv.base_level, .baseArrayLayer = sv.base_layer, .layerCount = fb.layers },
                .srcOffset = off,
                .dstSubresource = .{ .aspectMask = format.ASPECT_COLOR, .mipLevel = dv.base_level, .baseArrayLayer = dv.base_layer, .layerCount = fb.layers },
                .dstOffset = off,
                .extent = .{ .width = @min(gx.area.extent.width, fb.w), .height = @min(gx.area.extent.height, fb.h), .depth = 1 },
            } });
        }
    }

    fn clearAttachments(e: *Exec, c: ClearAtts) void {
        if (e.gfx.rp == NONE) return;
        const rp = &T.render_passes[e.gfx.rp];
        for (c.atts[0..c.n_att]) |ca| {
            const a = if (ca.aspectMask & format.ASPECT_COLOR != 0) (if (ca.colorAttachment < rp.n_color) rp.color[ca.colorAttachment] else NONE) else rp.ds;
            if (a == NONE) continue;
            for (c.rects[0..c.n_rect]) |rc| {
                e.clearAtt(a, ca.aspectMask, ca.clearValue, rc.rect.offset.x, rc.rect.offset.y, rc.rect.extent.width, rc.rect.extent.height, rc.baseArrayLayer, rc.layerCount);
            }
        }
    }

    /// The descriptor (set, binding) names in the bound graphics sets, and
    /// its dynamic offset.
    fn gdesc(e: *Exec, set: u32, binding: u32) ?struct { d: Desc, dyn: u32, dtype: u32 } {
        if (set >= MAX_SETS_PER_LAYOUT) return null;
        const si = e.gfx.sets[set];
        if (si == NONE or !T.sets[si].live) return null;
        const s = &T.sets[si];
        const lb = layoutBinding(&T.set_layouts[s.layout], binding) orelse return null;
        return .{ .d = T.descs[s.first + lb.first], .dyn = if (lb.dyn_first != NONE) e.gfx.dyn[set][lb.dyn_first] else 0, .dtype = lb.dtype };
    }

    /// Reads n bytes at buffer bi's offset back to the CPU (indirect
    /// arguments): the work so far runs and is waited for.
    fn readArgs(e: *Exec, bi: u32, offset: u64, n: u64) ?[]const u32 {
        const pl = e.place(bi) orelse return null;
        const d = e.dev();
        if (n > d.readback.cpu.len) return null;
        e.copyMem(T.memories[pl.mem].buf, pl.off + offset, d.readback, 0, n);
        if (e.flush() != R.success) return null;
        e.g.dev.wait(d.last_fence, 10_000_000) catch return null;
        e.g.dev.fromDevice(d.readback, 0, n);
        return d.readback.words()[0..@intCast(n / 4)];
    }

    fn drawIndirect(e: *Exec, c: DrawIndirect) void {
        var off = c.offset;
        var left = c.n;
        while (left > 0) {
            const per: u32 = if (c.indexed != 0) 5 else 4;
            const stride: u64 = if (c.stride != 0) c.stride else per * 4;
            const batch: u32 = @intCast(@min(left, (4096 - per * 4) / stride + 1));
            const words = e.readArgs(c.buf, off, (batch - 1) * stride + per * 4) orelse {
                e.sayOnce(1, "vkCmdDraw*Indirect: the arguments could not be read", .{});
                return;
            };
            for (0..batch) |i| {
                const w = words[@intCast(i * stride / 4)..];
                if (c.indexed != 0) {
                    e.draw(.{ .count = w[0], .instances = w[1], .first = w[2], .vertex_offset = @bitCast(w[3]), .first_instance = w[4], .indexed = 1 });
                } else {
                    e.draw(.{ .count = w[0], .instances = w[1], .first = w[2], .vertex_offset = 0, .first_instance = w[3], .indexed = 0 });
                }
            }
            off += batch * stride;
            left -= batch;
        }
    }

    fn draw(e: *Exec, dc: DrawCmd) void {
        const gx = &e.gfx;
        const p = gpipeOf(gx.pipe) orelse return;
        if (gx.rp == NONE or p.discard or dc.count == 0 or dc.instances == 0) return;
        const topo: raster.Topology = switch (p.topology) {
            .triangles => .triangles,
            .strip => .strip,
            .fan => .fan,
            else => {
                e.sayOnce(2, "a draw of points or lines: not drawn (triangles only yet)", .{});
                return;
            },
        };
        if (!T.eng_live or !e.toEngine()) return;
        const rpass = &T.render_passes[gx.rp];
        const fb = &T.framebuffers[gx.fb];
        var words = [_]u32{0} ** W_WORDS;
        words[W_HEIGHT] = @bitCast(@as(f32, @floatFromInt(fb.h)));
        words[W_BASE_VERTEX] = if (dc.indexed != 0) @bitCast(dc.vertex_offset) else 0;
        words[W_BASE_INSTANCE] = dc.first_instance;
        @memcpy(words[W_PUSH..][0 .. MAX_PUSH_BYTES / 4], &e.push);
        var d = raster.Draw{ .pipe = &p.rp[0], .color = undefined };
        // buffers: their memories, views in the words
        var bimg: [spirv.MAX_BINDINGS]engine.Image = undefined;
        for (p.res.bufs[0..p.res.n_bufs], 0..) |b, j| {
            const x = e.gdesc(b.set, b.binding) orelse continue;
            const pl = e.place(x.d.buf) orelse continue;
            const range = if (x.d.range == WHOLE_SIZE) pl.size -| x.d.offset else x.d.range;
            bimg[j] = memImage(pl.mem);
            d.buffers[j] = &bimg[j];
            words[W_VIEWS + 2 * j] = @truncate(pl.off + x.d.offset + x.dyn);
            words[W_VIEWS + 2 * j + 1] = @intCast(@min(range, 0xffff_ffff));
            if (b.kind == .storage) e.markDirty(pl.mem);
        }
        // textures: their views as images, descriptors in the words
        var timg: [spirv.MAX_TEX]engine.Image = undefined;
        for (p.res.tex[0..p.res.n_tex], 0..) |ts, j| {
            const x = e.gdesc(ts.image.set, ts.image.binding) orelse continue;
            const v = viewOf(x.d.view) orelse continue;
            var smp: ?*const Sampler = null;
            if (ts.has_sampler) {
                if (e.gdesc(ts.sampler.set, ts.sampler.binding)) |sx| {
                    if (sx.d.sampler != NONE and sx.d.sampler < MAX_SAMPLERS and T.samplers[sx.d.sampler].live) smp = &T.samplers[sx.d.sampler];
                }
            }
            timg[j] = texImage(v);
            d.textures[j] = &timg[j];
            texture.descriptor(texState(&timg[j], v, smp), words[W_TEX + j * texture.DESC_WORDS ..][0..texture.DESC_WORDS]);
        }
        // vertex attributes
        var vimg: [raster.MAX_ATTRS]engine.Image = undefined;
        for (p.va[0..p.n_va]) |a| {
            if (a.location >= raster.MAX_ATTRS) continue;
            const vb = for (p.vb[0..p.n_vb]) |x| {
                if (x.binding == a.binding) break x;
            } else continue;
            if (a.binding >= MAX_VB) continue;
            const bound = gx.vb[a.binding];
            const pl = e.place(bound.buf) orelse continue;
            var off = pl.off + bound.off + a.offset;
            if (vb.rate == 0 and dc.indexed != 0 and dc.vertex_offset > 0) off += @as(u64, @intCast(dc.vertex_offset)) * vb.stride;
            if (vb.rate == 1) off += @as(u64, dc.first_instance) * vb.stride;
            vimg[a.location] = memImage(pl.mem);
            d.attrs[a.location] = .{ .buf = &vimg[a.location], .offset = @intCast(off), .stride = vb.stride, .comps = a.fi.comps, .size = a.fi.size, .float = a.fi.float, .signed = a.fi.signed, .normalized = a.fi.norm, .integer = a.fi.integer, .divisor = vb.rate };
        }
        if (dc.indexed != 0 and dc.vertex_offset < 0) e.sayOnce(3, "an indexed draw with a negative vertex offset: the attributes start at the index", .{});
        // indices
        var iimg: engine.Image = undefined;
        if (dc.indexed != 0) {
            const pl = e.place(gx.ib) orelse return;
            if (gx.ib_size == 1) {
                e.sayOnce(4, "8-bit indices are not drawn", .{});
                return;
            }
            iimg = memImage(pl.mem);
            d.index = &iimg;
            d.index_offset = @intCast(pl.off + gx.ib_off + @as(u64, dc.first) * gx.ib_size);
            d.index_size = gx.ib_size;
            d.first = 0;
        } else d.first = dc.first;
        d.count = dc.count;
        d.instances = dc.instances;
        d.topology = topo;
        // the viewport, flipped to the raster's y (from the bottom)
        const vp = if (p.dynamic & DYN_VIEWPORT != 0) gx.viewport else p.viewport;
        const hf: f32 = @floatFromInt(fb.h);
        d.center = .{ vp.x + vp.width / 2, hf - vp.y - vp.height / 2 };
        d.half = .{ vp.width / 2, -vp.height / 2 };
        d.depth_scale = vp.maxDepth - vp.minDepth;
        d.depth_bias = vp.minDepth;
        d.zmin = @min(vp.minDepth, vp.maxDepth);
        d.zmax = @max(vp.minDepth, vp.maxDepth);
        const sc = if (p.dynamic & DYN_SCISSOR != 0) gx.scissor else p.scissor;
        var x0: i64 = @max(@max(sc.offset.x, gx.area.offset.x), 0);
        var y0: i64 = @max(@max(sc.offset.y, gx.area.offset.y), 0);
        var x1: i64 = @min(@as(i64, sc.offset.x) + sc.extent.width, @as(i64, gx.area.offset.x) + gx.area.extent.width);
        var y1: i64 = @min(@as(i64, sc.offset.y) + sc.extent.height, @as(i64, gx.area.offset.y) + gx.area.extent.height);
        // (inside the viewport too)
        const vy0 = @min(vp.y, vp.y + vp.height);
        x0 = @max(x0, @as(i64, @intFromFloat(@floor(@max(vp.x, -1e9)))));
        y0 = @max(y0, @as(i64, @intFromFloat(@floor(@max(vy0, -1e9)))));
        x1 = @min(x1, @as(i64, @intFromFloat(@ceil(@min(vp.x + vp.width, 1e9)))));
        y1 = @min(y1, @as(i64, @intFromFloat(@ceil(@min(vy0 + @abs(vp.height), 1e9)))));
        x1 = @min(x1, fb.w);
        y1 = @min(y1, fb.h);
        if (x1 <= x0 or y1 <= y0) return;
        d.rect = .{ .x0 = @intCast(x0), .y0 = @intCast(@as(i64, fb.h) - y1), .x1 = @intCast(x1), .y1 = @intCast(@as(i64, fb.h) - y0) };
        d.cull = p.cull;
        d.front_ccw = p.front_ccw;
        // depth and stencil
        var dsimg: engine.Image = undefined;
        var ds_mem: u32 = NONE;
        if (rpass.ds != NONE and rpass.ds < fb.n) {
            if (attImage(fb.views[rpass.ds], 0, fb.h)) |img| {
                dsimg = img;
                const v = &T.views[fb.views[rpass.ds]];
                ds_mem = T.images[v.image].mem;
                const asp = T.images[v.image].fi.aspects;
                if (asp & format.ASPECT_DEPTH != 0 and p.depth_test) {
                    d.depth = &dsimg;
                    d.depth_test = true;
                    d.depth_func = p.depth_op;
                    d.depth_write = p.depth_write;
                }
                if (asp & format.ASPECT_STENCIL != 0 and p.stencil_test) {
                    d.stencil = &dsimg;
                    const ref = [2]u8{ if (p.dynamic & DYN_REF != 0) gx.sref[0] else @truncate(p.front.reference), if (p.dynamic & DYN_REF != 0) gx.sref[1] else @truncate(p.back.reference) };
                    const cm = [2]u8{ if (p.dynamic & DYN_CMASK != 0) gx.scmask[0] else @truncate(p.front.compareMask), if (p.dynamic & DYN_CMASK != 0) gx.scmask[1] else @truncate(p.back.compareMask) };
                    const wm = [2]u8{ if (p.dynamic & DYN_WMASK != 0) gx.swmask[0] else @truncate(p.front.writeMask), if (p.dynamic & DYN_WMASK != 0) gx.swmask[1] else @truncate(p.back.writeMask) };
                    d.stencil_front = stencilOf(p.front, ref[0], cm[0], wm[0]);
                    d.stencil_back = stencilOf(p.back, ref[1], cm[1], wm[1]);
                }
            }
        }
        d.uniforms = &words;
        const consts = if (p.dynamic & DYN_BLEND != 0) gx.consts else p.consts;
        // each colour attachment: a pass of the raster
        var drawn = false;
        var cimg: engine.Image = undefined;
        for (0..rpass.n_color) |j| {
            const ai = rpass.color[j];
            if (ai == NONE or ai >= fb.n or j >= p.n_var) continue;
            const bl = p.blend[j];
            if (bl.mask & 0xf == 0) continue;
            cimg = attImage(fb.views[ai], 0, fb.h) orelse continue;
            if (!cimg.format.renderable()) {
                e.sayOnce(5, "a colour attachment of format {s}: not drawn into", .{@tagName(cimg.format)});
                continue;
            }
            d.pipe = &p.rp[j];
            d.color = &cimg;
            d.keep = keepOf(cimg.format, bl.mask);
            d.blend = blendOf(bl, consts);
            if (drawn) {
                d.depth_write = false;
                if (d.depth_test) d.depth_func = 0b010;
                d.stencil = null;
            }
            e.engineDraw(&d);
            e.markDirty(T.images[T.views[fb.views[ai]].image].mem);
            drawn = true;
        }
        if (!drawn and (d.depth != null or d.stencil != null)) {
            // depth or stencil only: a colour nothing is written to
            const need = @as(u64, fb.w) * fb.h * 4;
            if (T.null_color.bytes < need) {
                if (T.null_color.bytes != 0) {
                    T.eng.finish();
                    e.g.dev.free(T.null_color);
                    T.null_color = .{};
                }
                T.null_color = e.g.dev.alloc(need, .device) catch {
                    e.sayOnce(7, "no memory for a depth-only draw", .{});
                    return;
                };
            }
            cimg = engine.wrap(T.null_color, fb.w, fb.h, fb.w * 4, .rgba8, true);
            d.pipe = &p.rp[0];
            d.color = &cimg;
            d.keep = 0xffff_ffff;
            d.blend = null;
            e.engineDraw(&d);
        }
        if (ds_mem != NONE and (d.depth_write or d.stencil != null)) e.markDirty(ds_mem);
    }

    /// A draw through the engine. One whose kernels the GPU refused runs on
    /// the CPU (KIR's interpreter: the stencil tile kernel does not fit
    /// sm_120's registers yet): the GPU's work is waited for and its writes
    /// fetched first, as the engine's own images would be.
    fn engineDraw(e: *Exec, d: *const raster.Draw) void {
        const p = d.pipe;
        const maybe_cpu = p.refused_by != null or (d.stencil != null and p.progs[3] == null);
        if (maybe_cpu) {
            e.toIcd();
            e.g.dev.wait(e.dev().last_fence, 10_000_000) catch {};
            for (&T.memories) |*m| {
                if (m.live and m.dev == e.di and m.buf.cpu.len != 0) e.g.dev.fromDevice(m.buf, 0, m.buf.cpu.len);
            }
        }
        if (!T.eng.draw(d)) e.sayOnce(6, "a draw was dropped (no memory for it, or its kernels did not load: {s})", .{if (T.eng.why_pipe) |w| @errorName(w) else "?"});
    }

    /// The transfer kernel's mode and texel bytes for one aspect between a
    /// buffer and an image (to_image: the buffer is the source).
    fn aspectMode(fi: *const format.Info, aspect: u32, to_image: bool) struct { mode: XMode, buf: u32, img: u32 } {
        if (aspect & format.ASPECT_STENCIL != 0 and aspect & format.ASPECT_DEPTH == 0 and fi.aspects & format.ASPECT_STENCIL != 0) {
            return .{ .mode = if (to_image) .s8_in else .s8_out, .buf = 1, .img = 4 };
        }
        if (fi.aspects & format.ASPECT_DEPTH != 0) {
            return switch (fi.depth) {
                .unorm16 => .{ .mode = if (to_image) .u16_to_d24 else .d24_to_u16, .buf = 2, .img = 4 },
                .float32 => .{ .mode = if (to_image) .f32_to_d24 else .d24_to_f32, .buf = 4, .img = 4 },
                else => .{ .mode = if (to_image) .d24_in else .copy, .buf = 4, .img = 4 },
            };
        }
        return .{ .mode = .copy, .buf = fi.bytes, .img = fi.bytes };
    }

    fn copyBufImage(e: *Exec, c: BufImage, to_image: bool) void {
        const pl = e.place(c.buf) orelse return;
        if (c.image >= MAX_IMAGES or !T.images[c.image].live) return;
        const im = &T.images[c.image];
        if (im.mem == NONE or !T.memories[im.mem].live) return;
        const r_ = c.region;
        const sub = r_.imageSubresource;
        const l = @min(sub.mipLevel, im.levels - 1);
        const m = aspectMode(im.fi, sub.aspectMask, to_image);
        const w = r_.imageExtent.width;
        const h = r_.imageExtent.height;
        const row_len = if (r_.bufferRowLength != 0) r_.bufferRowLength else w;
        const img_h = if (r_.bufferImageHeight != 0) r_.bufferImageHeight else h;
        const z0: u32 = if (im.ty == 2) @intCast(@max(r_.imageOffset.z, 0)) else sub.baseArrayLayer;
        const nz = if (im.ty == 2) r_.imageExtent.depth else sub.layerCount;
        const ix: u64 = @intCast(@max(r_.imageOffset.x, 0));
        const iy: u64 = @intCast(@max(r_.imageOffset.y, 0));
        const img_off: u32 = @intCast(im.at(l, z0) + iy * im.pitch(l) + ix * m.img);
        const buf_off: u32 = @intCast(pl.off + r_.bufferOffset);
        const brow = row_len * m.buf;
        var p = [_]u32{0} ** X_PARAMS;
        p[X_W] = w;
        p[X_MODE] = @intFromEnum(m.mode);
        if (to_image) {
            p[X_SOFF] = buf_off;
            p[X_SROW] = brow;
            p[X_SSLICE] = brow * img_h;
            p[X_SB] = m.buf;
            p[X_DOFF] = img_off;
            p[X_DROW] = im.pitch(l);
            p[X_DSLICE] = @intCast(im.slice(l));
            p[X_DB] = m.img;
            e.xfer(T.memories[pl.mem].buf, T.memories[im.mem].buf, p, h, nz);
            e.markDirty(im.mem);
        } else {
            p[X_SOFF] = img_off;
            p[X_SROW] = im.pitch(l);
            p[X_SSLICE] = @intCast(im.slice(l));
            p[X_SB] = m.img;
            p[X_DOFF] = buf_off;
            p[X_DROW] = brow;
            p[X_DSLICE] = brow * img_h;
            p[X_DB] = m.buf;
            e.xfer(T.memories[im.mem].buf, T.memories[pl.mem].buf, p, h, nz);
            e.markDirty(pl.mem);
        }
    }

    fn copyImages(e: *Exec, c: ImgImg) void {
        if (c.src >= MAX_IMAGES or c.dst >= MAX_IMAGES) return;
        const s = &T.images[c.src];
        const t = &T.images[c.dst];
        if (!s.live or !t.live or s.mem == NONE or t.mem == NONE) return;
        const r_ = c.region;
        const sl = @min(r_.srcSubresource.mipLevel, s.levels - 1);
        const dl = @min(r_.dstSubresource.mipLevel, t.levels - 1);
        const asp = r_.srcSubresource.aspectMask;
        const both = format.ASPECT_DEPTH | format.ASPECT_STENCIL;
        const mode: XMode = if (s.fi.aspects == both and asp & both != both) (if (asp & format.ASPECT_DEPTH != 0) .d24_in else .s8_word_in) else .copy;
        const b = s.fi.bytes;
        const sz: u32 = if (s.ty == 2) @intCast(@max(r_.srcOffset.z, 0)) else r_.srcSubresource.baseArrayLayer;
        const dz: u32 = if (t.ty == 2) @intCast(@max(r_.dstOffset.z, 0)) else r_.dstSubresource.baseArrayLayer;
        const nz = if (s.ty == 2) r_.extent.depth else r_.srcSubresource.layerCount;
        var p = [_]u32{0} ** X_PARAMS;
        p[X_W] = r_.extent.width;
        p[X_MODE] = @intFromEnum(mode);
        p[X_SB] = b;
        p[X_DB] = t.fi.bytes;
        p[X_SOFF] = @intCast(s.at(sl, sz) + @as(u64, @intCast(@max(r_.srcOffset.y, 0))) * s.pitch(sl) + @as(u64, @intCast(@max(r_.srcOffset.x, 0))) * b);
        p[X_SROW] = s.pitch(sl);
        p[X_SSLICE] = @intCast(s.slice(sl));
        p[X_DOFF] = @intCast(t.at(dl, dz) + @as(u64, @intCast(@max(r_.dstOffset.y, 0))) * t.pitch(dl) + @as(u64, @intCast(@max(r_.dstOffset.x, 0))) * t.fi.bytes);
        p[X_DROW] = t.pitch(dl);
        p[X_DSLICE] = @intCast(t.slice(dl));
        e.xfer(T.memories[s.mem].buf, T.memories[t.mem].buf, p, r_.extent.height, nz);
        e.markDirty(t.mem);
    }

    fn clearImage(e: *Exec, c: ClearImage) void {
        if (c.image >= MAX_IMAGES or !T.images[c.image].live) return;
        const im = &T.images[c.image];
        if (im.mem == NONE) return;
        const rg = c.range;
        const nlev = if (rg.levelCount == 0xffff_ffff) im.levels -| rg.baseMipLevel else rg.levelCount;
        for (0..nlev) |li| {
            const l = rg.baseMipLevel + @as(u32, @intCast(li));
            if (l >= im.levels) break;
            const nl = if (rg.layerCount == 0xffff_ffff) im.slices(l) -| rg.baseArrayLayer else rg.layerCount;
            if (c.depth_stencil == 0) {
                e.fillImage(im, l, rg.baseArrayLayer, nl, 0, 0, im.lw(l), im.lh(l), colorWords(im.fi, c.value.color), 0);
            } else {
                const x = dsClear(if (rg.aspectMask & format.ASPECT_DEPTH != 0) c.value.depthStencil.depth else null, if (rg.aspectMask & format.ASPECT_STENCIL != 0) c.value.depthStencil.stencil else null);
                e.fillImage(im, l, rg.baseArrayLayer, nl, 0, 0, im.lw(l), im.lh(l), .{ x.v, 0, 0, 0 }, x.keep);
            }
        }
    }

    /// vkCmdBlitImage: a copy where the sizes match; else the engine's
    /// blit (the formats it draws, a layer at a time).
    fn blitImages(e: *Exec, c: Blit) void {
        if (c.src >= MAX_IMAGES or c.dst >= MAX_IMAGES) return;
        const s = &T.images[c.src];
        const t = &T.images[c.dst];
        if (!s.live or !t.live or s.mem == NONE or t.mem == NONE) return;
        const r_ = c.region;
        const so = r_.srcOffsets;
        const do_ = r_.dstOffsets;
        const sw = so[1].x - so[0].x;
        const shh = so[1].y - so[0].y;
        const dw = do_[1].x - do_[0].x;
        const dh = do_[1].y - do_[0].y;
        if (sw == dw and shh == dh and sw > 0 and shh > 0 and s.fi.fmt == t.fi.fmt) {
            const ic = abi.ImageCopy{ .srcSubresource = r_.srcSubresource, .srcOffset = so[0], .dstSubresource = r_.dstSubresource, .dstOffset = do_[0], .extent = .{ .width = @intCast(sw), .height = @intCast(shh), .depth = @intCast(@max(so[1].z - so[0].z, 1)) } };
            return e.copyImages(.{ .src = c.src, .dst = c.dst, .region = ic });
        }
        if (!s.fi.fmt.renderable() or !t.fi.fmt.renderable() or s.ty == 2) {
            e.sayOnce(8, "a scaled blit of format {s}: not done", .{@tagName(s.fi.fmt)});
            return;
        }
        if (!e.toEngine()) return;
        const sl = @min(r_.srcSubresource.mipLevel, s.levels - 1);
        const dl = @min(r_.dstSubresource.mipLevel, t.levels - 1);
        for (0..@min(r_.srcSubresource.layerCount, r_.dstSubresource.layerCount)) |li| {
            const slay = r_.srcSubresource.baseArrayLayer + @as(u32, @intCast(li));
            const dlay = r_.dstSubresource.baseArrayLayer + @as(u32, @intCast(li));
            var si = engine.wrap(sliceBuf(T.memories[s.mem].buf, s.at(sl, slay), s.slice(sl)), s.lw(sl), s.lh(sl), s.pitch(sl), s.fi.fmt, true);
            var di = engine.wrap(sliceBuf(T.memories[t.mem].buf, t.at(dl, dlay), t.slice(dl)), t.lw(dl), t.lh(dl), t.pitch(dl), t.fi.fmt, true);
            // (in the engine's y, from the bottom)
            const dhf: i32 = @intCast(t.lh(dl));
            const shf: f32 = @floatFromInt(s.lh(sl));
            const gy0 = dhf - do_[0].y;
            const gy1 = dhf - do_[1].y;
            const rect = engine.Rect{ .x0 = @intCast(@max(@min(do_[0].x, do_[1].x), 0)), .y0 = @intCast(@max(@min(gy0, gy1), 0)), .x1 = @intCast(@max(do_[0].x, do_[1].x)), .y1 = @intCast(@max(gy0, gy1)) };
            const b = engine.Blit{
                .rect = rect,
                .dx0 = do_[0].x,
                .sx0 = @floatFromInt(so[0].x),
                .scale_x = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw)),
                .dy0 = gy0,
                .sy0 = shf - @as(f32, @floatFromInt(so[0].y)),
                .scale_y = @as(f32, @floatFromInt(shh)) / @as(f32, @floatFromInt(dh)),
                .linear = c.filter == 1,
            };
            if (!T.eng.blit(&si, &di, b)) e.sayOnce(9, "a blit was dropped", .{});
        }
        e.markDirty(t.mem);
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
    var wait_out = false;
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
        e.toIcd();
        finishDirty(d.last_fence);
        for (0..s.signalSemaphoreCount) |xi| {
            const sem = semOf(s.pSignalSemaphores.?[xi]) orelse continue;
            wait_out = wait_out or sem.exported;
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
    // (a semaphore another context waits on: the work done before it is told)
    if (wait_out and d.last_fence != 0) {
        const res = waitFence(g, d.last_fence, 2_000_000_000);
        if (res == R.error_device_lost) {
            d.lost = true;
            return res;
        }
        pullDone(g);
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
    if (findIn(ci.pNext, ST.export_semaphore_create_info)) |b| {
        const ei: *const abi.ExportSemaphoreCreateInfo = @ptrCast(@alignCast(b));
        s.exported = ei.handleTypes != 0;
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

// ── Graphics: what the driver draws with ───────────────────────────────────
//
// Draws are gfxapi's raster (the GL driver's draw path): a graphics
// pipeline is one raster.Pipeline a colour attachment, whose vertex and
// fragment code is the SPIR-V stages' (src/spirv emitStage, inside the
// raster's kernels), run by the engine (gfxapi's engine.sig) on the same
// gpu.Device and queue as the driver's own kernels, in order: the engine's
// recorded draws are flushed before a kernel of the driver's runs, and the
// driver's before a draw.
//
// Images are linear in memory (format.sig): level after level, each its
// layers (or a 3D level's slices) one after another, rows 4-byte aligned.
// A colour attachment is an engine image over one level and layer, row 0
// at the top (Vulkan's framebuffer y); the raster's y (GL's, from the
// bottom) is flipped through the framebuffer's height, so the viewport's
// transform and FragCoord are Vulkan's. Each colour attachment is drawn by
// its own pass of the raster (its fragment code writes that location);
// after the first, depth is tested EQUAL and not written, stencil is off.
//
// Not yet: real multisampling (4x keeps one sample), points and lines,
// primitive restart, depth bias, storage images outside compute shaders,
// FragDepth, scaled blits of the non-renderable formats.

/// Multisampling: VK_SAMPLE_COUNT_4_BIT, the one count past 1 here.
/// WebGPU needs 4x render targets (and their resolves); the raster has no
/// multisampling, so a 4x image keeps one sample a pixel (its memory a
/// 1-sample image's), drawn at the pixel's centre: rendering is right, not
/// antialiased. A resolve (vkCmdResolveImage, a subpass's resolve
/// attachments) is a copy; a multisampled texture's every sample reads that
/// one (textureNumSamples says 1).
const SAMPLES_4: u32 = 4;

pub const MAX_IMAGES = 4096;
pub const MAX_VIEWS = 8192;
pub const MAX_SAMPLERS = 4000;
pub const MAX_RENDER_PASSES = 512;
pub const MAX_FRAMEBUFFERS = 1024;
pub const MAX_GPIPES = 512;
pub const MAX_TEMPLATES = 256;
pub const MAX_COLOR = 8;
const MAX_ATT = MAX_COLOR + 1;
pub const MAX_VB = 16;
const MAX_TEMPLATE_ENTRIES = 64;
const MAX_LEVELS = engine.MAX_LEVELS;
pub const MAX_IMAGE_2D: u32 = 8192;
pub const MAX_IMAGE_3D: u32 = 2048;
pub const MAX_LAYERS: u32 = 256;

// The draw's words: the raster's uniform binding (spirv.StageIO's words).
const W_HEIGHT = 0;
const W_BASE_VERTEX = 1;
const W_BASE_INSTANCE = 2;
const W_PUSH = 4;
const W_VIEWS = W_PUSH + MAX_PUSH_BYTES / 4;
const W_TEX = W_VIEWS + 2 * spirv.MAX_BINDINGS;
const W_WORDS = W_TEX + spirv.MAX_TEX * texture.DESC_WORDS;

comptime {
    std.debug.assert(W_WORDS <= raster.MAX_UNIFORM_WORDS);
    std.debug.assert(spirv.MAX_TEX == texture.MAX_TEX and spirv.MAX_BINDINGS <= raster.MAX_BUFFERS);
    std.debug.assert(spirv.MAX_ATTRS == raster.MAX_ATTRS and spirv.MAX_VARYINGS == raster.MAX_VARYINGS);
}

const Image = struct {
    live: bool,
    dev: u32,
    fi: *const format.Info,
    /// 0: 1D, 1: 2D, 2: 3D
    ty: u32,
    w: u32,
    h: u32,
    d: u32,
    levels: u32,
    layers: u32,
    mem: u32,
    offset: u64,
    level_at: [MAX_LEVELS]u64,
    size: u64,

    fn lw(im: *const Image, l: u32) u32 {
        return @max(im.w >> @intCast(l), 1);
    }
    fn lh(im: *const Image, l: u32) u32 {
        return @max(im.h >> @intCast(l), 1);
    }
    fn ld(im: *const Image, l: u32) u32 {
        return if (im.ty == 2) @max(im.d >> @intCast(l), 1) else 1;
    }
    fn pitch(im: *const Image, l: u32) u32 {
        return std.mem.alignForward(u32, im.lw(l) * im.fi.bytes, 4);
    }
    /// bytes a layer (a 3D level's slice) of level l
    fn slice(im: *const Image, l: u32) u64 {
        return @as(u64, im.pitch(l)) * im.lh(l);
    }
    fn slices(im: *const Image, l: u32) u32 {
        return if (im.ty == 2) im.ld(l) else im.layers;
    }
    /// The byte of (level, layer or z) in its memory.
    fn at(im: *const Image, l: u32, layer: u32) u64 {
        return im.offset + im.level_at[l] + @as(u64, layer) * im.slice(l);
    }
};

const View = struct {
    live: bool,
    image: u32,
    vtype: u32,
    fi: *const format.Info,
    swz: [4]u3,
    aspect: u32,
    base_level: u32,
    levels: u32,
    base_layer: u32,
    layers: u32,
};

const Sampler = struct {
    live: bool,
    mag: bool,
    min: bool,
    mip_linear: bool,
    wrap: [3]texture.Wrap,
    compare: u3,
    min_lod: f32,
    max_lod: f32,
};

const Att = struct { fmt: u32, load: u32, sload: u32 };
const RenderPass = struct {
    live: bool,
    n_att: u32,
    att: [MAX_ATT]Att,
    n_color: u32,
    color: [MAX_COLOR]u32,
    ds: u32,
    /// colour attachment j's resolve attachment (NONE: none), copied into
    /// at the end of the pass (a 4x image keeps one sample: see MSAA)
    resolve: [MAX_COLOR]u32 = [_]u32{NONE} ** MAX_COLOR,
};
const Framebuffer = struct { live: bool, w: u32, h: u32, layers: u32, n: u32, views: [MAX_ATT]u32 };

const VBind = struct { binding: u32, stride: u32, rate: u32 };
const VAttr = struct { location: u32, binding: u32, fi: *const format.Info, offset: u32 };
const BlendAtt = struct { enable: bool, src_c: u32, dst_c: u32, op_c: u32, src_a: u32, dst_a: u32, op_a: u32, mask: u32 };
const Emit = struct { pipe: u32, loc: u32 };
const Topo = enum(u8) { triangles, strip, fan, points, lines };

const DYN_VIEWPORT: u32 = 1 << 0;
const DYN_SCISSOR: u32 = 1 << 1;
const DYN_BLEND: u32 = 1 << 4;
const DYN_CMASK: u32 = 1 << 6;
const DYN_WMASK: u32 = 1 << 7;
const DYN_REF: u32 = 1 << 8;

const GPipe = struct {
    live: bool,
    dev: u32,
    vs: u32,
    fs: u32,
    vs_name: [64]u8,
    fs_name: [64]u8,
    robust: bool,
    res: spirv.Resources,
    n_vb: u32,
    vb: [MAX_VB]VBind,
    n_va: u32,
    va: [raster.MAX_ATTRS]VAttr,
    topology: Topo,
    cull: u2,
    front_ccw: bool,
    discard: bool,
    depth_test: bool,
    depth_write: bool,
    depth_op: u3,
    stencil_test: bool,
    front: abi.StencilOpState,
    back: abi.StencilOpState,
    n_color: u32,
    blend: [MAX_COLOR]BlendAtt,
    consts: [4]f32,
    viewport: abi.Viewport,
    scissor: abi.Rect2D,
    dynamic: u32,
    n_var: u32,
    rp: [MAX_COLOR]raster.Pipeline,
    emit: [MAX_COLOR]Emit,
};

const TemplateEntry = struct { binding: u32, elem: u32, count: u32, dtype: u32, offset: usize, stride: usize };
const Template = struct { live: bool, n: u32, e: [MAX_TEMPLATE_ENTRIES]TemplateEntry };

const VbBound = struct { buf: u32, off: u64 };

/// The graphics state a command buffer's run keeps (Exec.gfx).
const Gfx = struct {
    pipe: u32 = NONE,
    sets: [MAX_SETS_PER_LAYOUT]u32 = [_]u32{NONE} ** MAX_SETS_PER_LAYOUT,
    dyn: [MAX_SETS_PER_LAYOUT][MAX_DYNAMIC]u32 = undefined,
    vb: [MAX_VB]VbBound = [_]VbBound{.{ .buf = NONE, .off = 0 }} ** MAX_VB,
    ib: u32 = NONE,
    ib_off: u64 = 0,
    ib_size: u8 = 2,
    rp: u32 = NONE,
    fb: u32 = NONE,
    area: abi.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 0, .height = 0 } },
    viewport: abi.Viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0, .minDepth = 0, .maxDepth = 1 },
    scissor: abi.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 0x7fff_ffff, .height = 0x7fff_ffff } },
    /// front, back: reference, compare mask, write mask
    sref: [2]u8 = .{ 0, 0 },
    scmask: [2]u8 = .{ 0xff, 0xff },
    swmask: [2]u8 = .{ 0xff, 0xff },
    consts: [4]f32 = .{ 0, 0, 0, 0 },
    said: u32 = 0,
};

fn gfxLimits(l: *abi.PhysicalDeviceLimits) void {
    l.maxImageDimension1D = MAX_IMAGE_2D;
    l.maxImageDimension2D = MAX_IMAGE_2D;
    l.maxImageDimension3D = MAX_IMAGE_3D;
    l.maxImageDimensionCube = MAX_IMAGE_2D;
    l.maxImageArrayLayers = MAX_LAYERS;
    l.maxSamplerAllocationCount = MAX_SAMPLERS;
    l.maxPerStageDescriptorSamplers = 16;
    l.maxPerStageDescriptorSampledImages = 16;
    // (storage images: compute shaders, spirv's storage formats; WebGPU's default is 4)
    l.maxPerStageDescriptorStorageImages = 4;
    l.maxPerStageDescriptorInputAttachments = 4;
    l.maxPerStageResources = 48;
    l.maxDescriptorSetSamplers = 32;
    l.maxDescriptorSetSampledImages = 32;
    l.maxDescriptorSetStorageImages = 8;
    l.maxDescriptorSetInputAttachments = 4;
    l.maxVertexInputAttributes = raster.MAX_ATTRS;
    l.maxVertexInputBindings = MAX_VB;
    l.maxVertexInputAttributeOffset = 2047;
    l.maxVertexInputBindingStride = 2048;
    // (the raster's 64 scalar varyings and the position)
    l.maxVertexOutputComponents = raster.MAX_VARYINGS + 4;
    l.maxFragmentInputComponents = raster.MAX_VARYINGS + 4;
    l.maxFragmentOutputAttachments = MAX_COLOR;
    l.maxFragmentCombinedOutputResources = MAX_COLOR + 8 + 4;
    l.subPixelPrecisionBits = 4;
    l.subTexelPrecisionBits = 8;
    l.mipmapPrecisionBits = 8;
    l.maxDrawIndexedIndexValue = 0xffff_ffff;
    l.maxDrawIndirectCount = 1 << 16;
    l.maxSamplerLodBias = 16;
    l.maxSamplerAnisotropy = 1;
    l.maxViewports = 1;
    l.maxViewportDimensions = .{ MAX_IMAGE_2D, MAX_IMAGE_2D };
    l.viewportBoundsRange = .{ -2 * @as(f32, MAX_IMAGE_2D), 2 * @as(f32, MAX_IMAGE_2D) };
    l.minTexelOffset = -8;
    l.maxTexelOffset = 7;
    l.minTexelGatherOffset = -8;
    l.maxTexelGatherOffset = 7;
    l.minInterpolationOffset = -0.5;
    l.maxInterpolationOffset = 0.4375;
    l.subPixelInterpolationOffsetBits = 4;
    l.maxFramebufferWidth = MAX_IMAGE_2D;
    l.maxFramebufferHeight = MAX_IMAGE_2D;
    l.maxFramebufferLayers = MAX_LAYERS;
    // (MSAA 4x as WebGPU needs it, one sample kept: see "Multisampling")
    l.framebufferColorSampleCounts = 1 | SAMPLES_4;
    l.framebufferDepthSampleCounts = 1 | SAMPLES_4;
    l.framebufferStencilSampleCounts = 1 | SAMPLES_4;
    l.framebufferNoAttachmentsSampleCounts = 1 | SAMPLES_4;
    l.maxColorAttachments = MAX_COLOR;
    l.sampledImageColorSampleCounts = 1 | SAMPLES_4;
    l.sampledImageIntegerSampleCounts = 1 | SAMPLES_4;
    l.sampledImageDepthSampleCounts = 1 | SAMPLES_4;
    l.sampledImageStencilSampleCounts = 1 | SAMPLES_4;
    l.storageImageSampleCounts = 1;
    l.maxSampleMaskWords = 1;
    l.pointSizeRange = .{ 1, 1 };
    l.lineWidthRange = .{ 1, 1 };
    l.standardSampleLocations = 1;
}

fn imageFormatProperties(f: u32, ty: u32, tiling: u32, usage: u32, flags: u32, o: *abi.ImageFormatProperties) Result {
    o.* = std.mem.zeroes(abi.ImageFormatProperties);
    const fi = format.image(f) orelse return R.error_format_not_supported;
    const p = format.props(f);
    const feats = if (tiling == 0) p.optimal else if (tiling == 1) p.linear else 0;
    if (feats == 0 or ty > 2) return R.error_format_not_supported;
    // usage: transfer src 1, dst 2, sampled 4, storage 8, colour 0x10, depth 0x20, transient 0x40, input 0x80
    if (usage & 0x8 != 0 and feats & format.Feature.storage == 0) return R.error_format_not_supported;
    if (usage & 0x10 != 0 and feats & format.Feature.color_attachment == 0) return R.error_format_not_supported;
    if (usage & 0x20 != 0 and feats & format.Feature.depth_stencil == 0) return R.error_format_not_supported;
    if (fi.aspects != format.ASPECT_COLOR and ty == 2) return R.error_format_not_supported;
    o.maxExtent = switch (ty) {
        0 => .{ .width = MAX_IMAGE_2D, .height = 1, .depth = 1 },
        1 => .{ .width = MAX_IMAGE_2D, .height = MAX_IMAGE_2D, .depth = 1 },
        else => .{ .width = MAX_IMAGE_3D, .height = MAX_IMAGE_3D, .depth = MAX_IMAGE_3D },
    };
    o.maxMipLevels = if (tiling == 1) 1 else MAX_LEVELS;
    o.maxArrayLayers = if (ty == 2 or tiling == 1) 1 else MAX_LAYERS;
    // (4x: optimal 2D attachments, not cube-compatible, not storage)
    const attach = feats & (format.Feature.color_attachment | format.Feature.depth_stencil) != 0;
    o.sampleCounts = if (tiling == 0 and ty == 1 and attach and flags & 0x10 == 0 and usage & 0x8 == 0) 1 | SAMPLES_4 else 1;
    o.maxResourceSize = 1 << 31;
    return R.success;
}

// ── Images ─────────────────────────────────────────────────────────────────

fn imgOf(h: u64) ?*Image {
    const i = unhandle(.image, h) orelse return null;
    return if (T.images[i].live) &T.images[i] else null;
}

fn createImage(dh: ?*anyopaque, info: ?*const abi.ImageCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const fi = format.image(ci.format) orelse {
        say("vkCreateImage: format {d} is not supported", .{ci.format});
        return R.error_format_not_supported;
    };
    if (ci.samples != 1 and ci.samples != SAMPLES_4) {
        say("vkCreateImage: {d} samples (1 or 4 here)", .{ci.samples});
        return R.error_feature_not_present;
    }
    const e = ci.extent;
    if (e.width == 0 or e.height == 0 or e.depth == 0 or ci.mipLevels == 0 or ci.arrayLayers == 0) return R.error_initialization_failed;
    if (ci.mipLevels > MAX_LEVELS or ci.arrayLayers > MAX_LAYERS or e.width > MAX_IMAGE_2D or e.height > MAX_IMAGE_2D or e.depth > MAX_IMAGE_3D) return R.error_out_of_device_memory;
    // a DRM format modifier: linear, the layout every image has
    var explicit: ?abi.SubresourceLayout = null;
    if (ci.tiling == abi.TILING_DRM_FORMAT_MODIFIER) {
        if (findIn(ci.pNext, ST.image_drm_format_modifier_list_create_info_ext)) |b| {
            const ml: *const abi.ImageDrmFormatModifierListCreateInfoEXT = @ptrCast(@alignCast(b));
            var linear = false;
            for (0..ml.drmFormatModifierCount) |k| linear = linear or ml.pDrmFormatModifiers.?[k] == abi.DRM_MOD_LINEAR;
            if (!linear) {
                say("vkCreateImage: no linear modifier among {d} (linear is the one here)", .{ml.drmFormatModifierCount});
                return R.error_format_not_supported;
            }
        } else if (findIn(ci.pNext, ST.image_drm_format_modifier_explicit_create_info_ext)) |b| {
            const xi: *const abi.ImageDrmFormatModifierExplicitCreateInfoEXT = @ptrCast(@alignCast(b));
            if (xi.drmFormatModifier != abi.DRM_MOD_LINEAR or xi.drmFormatModifierPlaneCount != 1) return R.error_invalid_drm_format_modifier_plane_layout_ext;
            explicit = xi.pPlaneLayouts.?[0];
        } else return R.error_initialization_failed;
        if (ci.mipLevels != 1 or ci.arrayLayers != 1 or ci.imageType != 1) return R.error_format_not_supported;
    }
    const i = findFree("images") orelse return R.error_too_many_objects;
    var im = Image{ .live = true, .dev = di, .fi = fi, .ty = ci.imageType, .w = e.width, .h = if (ci.imageType == 0) 1 else e.height, .d = if (ci.imageType == 2) e.depth else 1, .levels = ci.mipLevels, .layers = if (ci.imageType == 2) 1 else ci.arrayLayers, .mem = NONE, .offset = 0, .level_at = undefined, .size = 0 };
    var at: u64 = 0;
    for (0..im.levels) |l| {
        im.level_at[l] = at;
        at += im.slice(@intCast(l)) * im.slices(@intCast(l));
        at = std.mem.alignForward(u64, at, 16);
    }
    im.size = @max(at, 16);
    if (explicit) |pl| {
        if (pl.offset != 0 or pl.rowPitch != im.pitch(0)) {
            say("vkCreateImage: plane layout offset {d}, row pitch {d} (rows here are {d} bytes)", .{ pl.offset, pl.rowPitch, im.pitch(0) });
            return R.error_invalid_drm_format_modifier_plane_layout_ext;
        }
    }
    T.images[i] = im;
    (out orelse return R.error_initialization_failed).* = handle(.image, i);
    return R.success;
}

fn destroyImage(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const im = imgOf(h) orelse return;
    im.live = false;
}

fn imageRequirements(im: *const Image) abi.MemoryRequirements {
    return .{ .size = std.mem.alignForward(u64, im.size, 256), .alignment = 256, .memoryTypeBits = (@as(u32, 1) << @intCast(T.n_mem_types)) - 1 };
}

fn getImageMemoryRequirements(_: ?*anyopaque, h: u64, out: ?*abi.MemoryRequirements) callconv(.c) void {
    lock();
    defer unlock();
    const im = imgOf(h) orelse return;
    (out orelse return).* = imageRequirements(im);
}

fn getImageMemoryRequirements2(_: ?*anyopaque, info: ?*const abi.ImageMemoryRequirementsInfo2, out: ?*abi.MemoryRequirements2) callconv(.c) void {
    lock();
    defer unlock();
    const im = imgOf((info orelse return).image) orelse return;
    const o = out orelse return;
    o.memoryRequirements = imageRequirements(im);
    var cur: ?*abi.BaseOutStructure = @ptrCast(@alignCast(o.pNext));
    while (cur) |c| : (cur = nextOut(c)) {
        if (c.sType == ST.memory_dedicated_requirements) {
            const dr: *abi.MemoryDedicatedRequirements = @ptrCast(@alignCast(c));
            dr.prefersDedicatedAllocation = 0;
            dr.requiresDedicatedAllocation = 0;
        }
    }
}

fn getImageSparseMemoryRequirements(_: ?*anyopaque, _: u64, count: ?*u32, _: ?*anyopaque) callconv(.c) void {
    if (count) |c| c.* = 0;
}

fn getImageSparseMemoryRequirements2(_: ?*anyopaque, _: ?*const anyopaque, count: ?*u32, _: ?*anyopaque) callconv(.c) void {
    if (count) |c| c.* = 0;
}

fn bindImage(ih: u64, mh: u64, offset: u64) Result {
    const im = imgOf(ih) orelse return R.error_initialization_failed;
    const m = memOf(mh) orelse return R.error_initialization_failed;
    if (offset + im.size > m.size) return R.error_out_of_device_memory;
    im.mem = unhandle(.memory, mh).?;
    im.offset = offset;
    return R.success;
}

fn bindImageMemory(_: ?*anyopaque, ih: u64, mh: u64, offset: u64) callconv(.c) Result {
    lock();
    defer unlock();
    return bindImage(ih, mh, offset);
}

fn bindImageMemory2(_: ?*anyopaque, n: u32, infos: ?[*]const abi.BindImageMemoryInfo) callconv(.c) Result {
    lock();
    defer unlock();
    for (0..n) |i| {
        const bi = infos.?[i];
        const res = bindImage(bi.image, bi.memory, bi.memoryOffset);
        if (res != R.success) return res;
    }
    return R.success;
}

fn getImageSubresourceLayout(_: ?*anyopaque, h: u64, sub: ?*const abi.ImageSubresource, out: ?*abi.SubresourceLayout) callconv(.c) void {
    lock();
    defer unlock();
    const im = imgOf(h) orelse return;
    const s = sub orelse return;
    const o = out orelse return;
    const l = @min(s.mipLevel, im.levels - 1);
    o.offset = im.level_at[l] + @as(u64, s.arrayLayer) * im.slice(l);
    o.rowPitch = im.pitch(l);
    o.arrayPitch = im.slice(l);
    o.depthPitch = im.slice(l);
    o.size = im.slice(l) * (if (im.ty == 2) im.ld(l) else 1);
}

// ── Views and samplers ─────────────────────────────────────────────────────

fn swizzleOf(c: u32, i: u3) u3 {
    return switch (c) {
        0 => i, // identity
        1 => texture.SWZ_ZERO,
        2 => texture.SWZ_ONE,
        3...6 => @intCast(c - 3),
        else => i,
    };
}

fn createImageView(_: ?*anyopaque, info: ?*const abi.ImageViewCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const ii = unhandle(.image, ci.image) orelse return R.error_initialization_failed;
    const im = &T.images[ii];
    if (!im.live) return R.error_initialization_failed;
    const fi = format.image(ci.format) orelse return R.error_format_not_supported;
    const i = findFree("views") orelse return R.error_too_many_objects;
    const r_ = ci.subresourceRange;
    const levels = if (r_.levelCount == 0xffff_ffff) im.levels -| r_.baseMipLevel else r_.levelCount;
    const total_layers = if (im.ty == 2) im.d else im.layers;
    const layers = if (r_.layerCount == 0xffff_ffff) total_layers -| r_.baseArrayLayer else r_.layerCount;
    const cs = [4]u32{ ci.components.r, ci.components.g, ci.components.b, ci.components.a };
    var swz: [4]u3 = undefined;
    for (0..4) |c| swz[c] = swizzleOf(cs[c], @intCast(c));
    // (BGRA8's texels are B, G, R, A in memory)
    if (fi.fmt == .bgra8) {
        for (&swz) |*s| s.* = switch (s.*) {
            0 => 2,
            2 => 0,
            else => s.*,
        };
    }
    T.views[i] = .{ .live = true, .image = ii, .vtype = ci.viewType, .fi = fi, .swz = swz, .aspect = r_.aspectMask, .base_level = r_.baseMipLevel, .levels = @max(levels, 1), .base_layer = r_.baseArrayLayer, .layers = @max(layers, 1) };
    (out orelse return R.error_initialization_failed).* = handle(.view, i);
    return R.success;
}

fn destroyImageView(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.view, h) orelse return;
    T.views[i].live = false;
}

fn wrapOf(m: u32) texture.Wrap {
    return switch (m) {
        0 => .repeat,
        1, 4 => .mirror,
        else => .clamp,
    };
}

fn createSampler(_: ?*anyopaque, info: ?*const abi.SamplerCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const i = findFree("samplers") orelse return R.error_too_many_objects;
    T.samplers[i] = .{
        .live = true,
        .mag = ci.magFilter == 1,
        .min = ci.minFilter == 1,
        .mip_linear = ci.mipmapMode == 1,
        .wrap = .{ wrapOf(ci.addressModeU), wrapOf(ci.addressModeV), wrapOf(ci.addressModeW) },
        .compare = if (ci.compareEnable != 0) @intCast(ci.compareOp & 7) else 0,
        .min_lod = ci.minLod,
        .max_lod = ci.maxLod,
    };
    (out orelse return R.error_initialization_failed).* = handle(.sampler, i);
    return R.success;
}

fn destroySampler(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.sampler, h) orelse return;
    T.samplers[i].live = false;
}

fn createSamplerYcbcrConversion(_: ?*anyopaque, _: ?*const anyopaque, _: ?*const anyopaque, _: ?*u64) callconv(.c) Result {
    // (samplerYcbcrConversion is not a feature here)
    return R.error_feature_not_present;
}

fn destroySamplerYcbcrConversion(_: ?*anyopaque, _: u64, _: ?*const anyopaque) callconv(.c) void {}

// ── Render passes and framebuffers ─────────────────────────────────────────

fn createRenderPass(_: ?*anyopaque, info: ?*const abi.RenderPassCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    if (ci.attachmentCount > MAX_ATT or ci.subpassCount == 0) return R.error_initialization_failed;
    if (ci.subpassCount > 1) say("vkCreateRenderPass: {d} subpasses: only the first is drawn", .{ci.subpassCount});
    const i = findFree("render_passes") orelse return R.error_too_many_objects;
    var rp = RenderPass{ .live = true, .n_att = ci.attachmentCount, .att = undefined, .n_color = 0, .color = [_]u32{NONE} ** MAX_COLOR, .ds = NONE };
    for (0..ci.attachmentCount) |a| {
        const ad = ci.pAttachments.?[a];
        if (ad.samples != 1 and ad.samples != SAMPLES_4) return R.error_feature_not_present;
        rp.att[a] = .{ .fmt = ad.format, .load = ad.loadOp, .sload = ad.stencilLoadOp };
    }
    const sp = ci.pSubpasses.?[0];
    if (sp.colorAttachmentCount > MAX_COLOR) return R.error_initialization_failed;
    rp.n_color = sp.colorAttachmentCount;
    for (0..sp.colorAttachmentCount) |c| rp.color[c] = sp.pColorAttachments.?[c].attachment;
    if (sp.pResolveAttachments) |ra| {
        for (0..sp.colorAttachmentCount) |c| rp.resolve[c] = ra[c].attachment;
    }
    if (sp.pDepthStencilAttachment) |ds| rp.ds = ds.attachment;
    T.render_passes[i] = rp;
    (out orelse return R.error_initialization_failed).* = handle(.render_pass, i);
    return R.success;
}

fn destroyRenderPass(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.render_pass, h) orelse return;
    T.render_passes[i].live = false;
}

fn getRenderAreaGranularity(_: ?*anyopaque, _: u64, out: ?*abi.Extent2D) callconv(.c) void {
    (out orelse return).* = .{ .width = 1, .height = 1 };
}

fn createFramebuffer(_: ?*anyopaque, info: ?*const abi.FramebufferCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    if (ci.attachmentCount > MAX_ATT) return R.error_initialization_failed;
    if (ci.flags & 1 != 0) return R.error_feature_not_present; // imageless
    const i = findFree("framebuffers") orelse return R.error_too_many_objects;
    var fb = Framebuffer{ .live = true, .w = ci.width, .h = ci.height, .layers = @max(ci.layers, 1), .n = ci.attachmentCount, .views = [_]u32{NONE} ** MAX_ATT };
    for (0..ci.attachmentCount) |a| fb.views[a] = unhandle(.view, ci.pAttachments.?[a]) orelse NONE;
    T.framebuffers[i] = fb;
    (out orelse return R.error_initialization_failed).* = handle(.framebuffer, i);
    return R.success;
}

fn destroyFramebuffer(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.framebuffer, h) orelse return;
    T.framebuffers[i].live = false;
}

// ── Descriptor update templates ────────────────────────────────────────────

fn createDescriptorUpdateTemplate(_: ?*anyopaque, info: ?*const abi.DescriptorUpdateTemplateCreateInfo, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    if (ci.descriptorUpdateEntryCount > MAX_TEMPLATE_ENTRIES or ci.templateType != 0) return R.error_out_of_host_memory;
    const i = findFree("templates") orelse return R.error_too_many_objects;
    var t = Template{ .live = true, .n = ci.descriptorUpdateEntryCount, .e = undefined };
    for (0..t.n) |j| {
        const x = ci.pDescriptorUpdateEntries.?[j];
        t.e[j] = .{ .binding = x.dstBinding, .elem = x.dstArrayElement, .count = x.descriptorCount, .dtype = x.descriptorType, .offset = x.offset, .stride = x.stride };
    }
    T.templates[i] = t;
    (out orelse return R.error_initialization_failed).* = handle(.template, i);
    return R.success;
}

fn destroyDescriptorUpdateTemplate(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const i = unhandle(.template, h) orelse return;
    T.templates[i].live = false;
}

fn updateDescriptorSetWithTemplate(dh: ?*anyopaque, set: u64, th: u64, data: ?*const anyopaque) callconv(.c) void {
    const base: [*]const u8 = @ptrCast(data orelse return);
    var t: Template = undefined;
    {
        lock();
        defer unlock();
        const ti = unhandle(.template, th) orelse return;
        if (!T.templates[ti].live) return;
        t = T.templates[ti];
    }
    for (t.e[0..t.n]) |x| {
        for (0..x.count) |c| {
            const p = base + x.offset + c * x.stride;
            var w = abi.WriteDescriptorSet{ .sType = ST.write_descriptor_set, .pNext = null, .dstSet = set, .dstBinding = x.binding, .dstArrayElement = x.elem + @as(u32, @intCast(c)), .descriptorCount = 1, .descriptorType = x.dtype, .pImageInfo = null, .pBufferInfo = null, .pTexelBufferView = null };
            switch (x.dtype) {
                DescType.uniform_buffer, DescType.storage_buffer, DescType.uniform_buffer_dynamic, DescType.storage_buffer_dynamic => w.pBufferInfo = @ptrCast(@alignCast(p)),
                DescType.sampler, DescType.combined, DescType.sampled_image, DescType.storage_image, DescType.input_attachment => w.pImageInfo = @ptrCast(@alignCast(p)),
                else => continue,
            }
            updateDescriptorSets(dh, 1, @ptrCast(&w), 0, null);
        }
    }
}

// ── Graphics pipelines ─────────────────────────────────────────────────────

fn gpipeOf(i: u32) ?*GPipe {
    if (i == NONE or i >= MAX_GPIPES or !T.gpipes[i].live) return null;
    return &T.gpipes[i];
}

fn nameInto(dst: *[64]u8, p: ?[*:0]const u8) void {
    copyName(dst, cstr(p));
}

fn createGraphicsPipelines(dh: ?*anyopaque, _: u64, n: u32, infos: ?[*]const abi.GraphicsPipelineCreateInfo, _: ?*const anyopaque, out: ?[*]u64) callconv(.c) Result {
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const dst = out orelse return R.error_initialization_failed;
    var res: Result = R.success;
    for (0..n) |j| {
        dst[j] = 0;
        const i = findFree("gpipes") orelse {
            res = R.error_out_of_host_memory;
            continue;
        };
        const r_ = makeGPipe(di, @intCast(i), &infos.?[j]);
        if (r_ != R.success) {
            res = r_;
            continue;
        }
        dst[j] = handle(.gpipe, @intCast(i));
    }
    return res;
}

fn makeGPipe(di: u32, pi: u32, ci: *const abi.GraphicsPipelineCreateInfo) Result {
    const p = &T.gpipes[pi];
    p.* = .{
        .live = false,
        .dev = di,
        .vs = NONE,
        .fs = NONE,
        .vs_name = [_]u8{0} ** 64,
        .fs_name = [_]u8{0} ** 64,
        .robust = T.devices[di].robust,
        .res = .{},
        .n_vb = 0,
        .vb = undefined,
        .n_va = 0,
        .va = undefined,
        .topology = .triangles,
        .cull = 0,
        .front_ccw = true,
        .discard = false,
        .depth_test = false,
        .depth_write = false,
        .depth_op = 0,
        .stencil_test = false,
        .front = std.mem.zeroes(abi.StencilOpState),
        .back = std.mem.zeroes(abi.StencilOpState),
        .n_color = 0,
        .blend = undefined,
        .consts = .{ 0, 0, 0, 0 },
        .viewport = std.mem.zeroes(abi.Viewport),
        .scissor = std.mem.zeroes(abi.Rect2D),
        .dynamic = 0,
        .n_var = 0,
        .rp = undefined,
        .emit = undefined,
    };
    for (0..ci.stageCount) |s| {
        const st = ci.pStages.?[s];
        const mi = unhandle(.shader, st.module) orelse return R.error_initialization_failed;
        if (!T.shaders[mi].live) return R.error_initialization_failed;
        switch (st.stage) {
            0x1 => {
                p.vs = mi;
                nameInto(&p.vs_name, st.pName);
            },
            0x10 => {
                p.fs = mi;
                nameInto(&p.fs_name, st.pName);
            },
            else => {
                say("vkCreateGraphicsPipelines: shader stage 0x{x} (vertex and fragment only)", .{st.stage});
                return R.error_feature_not_present;
            },
        }
    }
    if (p.vs == NONE) return R.error_initialization_failed;
    // vertex input
    if (ci.pVertexInputState) |vi| {
        if (vi.vertexBindingDescriptionCount > MAX_VB or vi.vertexAttributeDescriptionCount > raster.MAX_ATTRS) return R.error_initialization_failed;
        p.n_vb = vi.vertexBindingDescriptionCount;
        for (0..p.n_vb) |b| {
            const x = vi.pVertexBindingDescriptions.?[b];
            p.vb[b] = .{ .binding = x.binding, .stride = x.stride, .rate = x.inputRate };
        }
        p.n_va = vi.vertexAttributeDescriptionCount;
        for (0..p.n_va) |a| {
            const x = vi.pVertexAttributeDescriptions.?[a];
            const fi = format.vertex(x.format) orelse {
                say("vkCreateGraphicsPipelines: vertex format {d} is not supported", .{x.format});
                return R.error_format_not_supported;
            };
            p.va[a] = .{ .location = x.location, .binding = x.binding, .fi = fi, .offset = x.offset };
        }
    }
    p.topology = if (ci.pInputAssemblyState) |ia| switch (ia.topology) {
        0 => Topo.points,
        1, 2 => Topo.lines,
        3 => Topo.triangles,
        4 => Topo.strip,
        5 => Topo.fan,
        else => Topo.triangles,
    } else .triangles;
    if (ci.pRasterizationState) |rs| {
        p.cull = @intCast(rs.cullMode & 3);
        p.front_ccw = rs.frontFace == 0;
        p.discard = rs.rasterizerDiscardEnable != 0;
        if (rs.polygonMode != 0) say("vkCreateGraphicsPipelines: polygon mode {d} is drawn filled", .{rs.polygonMode});
    } else p.front_ccw = true;
    if (ci.pDepthStencilState) |ds| {
        p.depth_test = ds.depthTestEnable != 0;
        p.depth_write = ds.depthWriteEnable != 0;
        p.depth_op = @intCast(ds.depthCompareOp & 7);
        p.stencil_test = ds.stencilTestEnable != 0;
        p.front = ds.front;
        p.back = ds.back;
    }
    // the subpass's colour attachments: one raster pipeline each
    const rpi = unhandle(.render_pass, ci.renderPass) orelse return R.error_initialization_failed;
    const rpass = &T.render_passes[rpi];
    p.n_color = rpass.n_color;
    for (0..MAX_COLOR) |c| p.blend[c] = .{ .enable = false, .src_c = 1, .dst_c = 0, .op_c = 0, .src_a = 1, .dst_a = 0, .op_a = 0, .mask = 0xf };
    if (ci.pColorBlendState) |cb| {
        for (0..@min(cb.attachmentCount, MAX_COLOR)) |c| {
            const a = cb.pAttachments.?[c];
            p.blend[c] = .{ .enable = a.blendEnable != 0, .src_c = a.srcColorBlendFactor, .dst_c = a.dstColorBlendFactor, .op_c = a.colorBlendOp, .src_a = a.srcAlphaBlendFactor, .dst_a = a.dstAlphaBlendFactor, .op_a = a.alphaBlendOp, .mask = a.colorWriteMask };
        }
        p.consts = cb.blendConstants;
        if (cb.logicOpEnable != 0) say("vkCreateGraphicsPipelines: logic ops are not drawn", .{});
    }
    if (ci.pViewportState) |vs| {
        if (vs.pViewports) |v| p.viewport = v[0];
        if (vs.pScissors) |s| p.scissor = s[0];
    }
    if (ci.pDynamicState) |ds| {
        for (0..ds.dynamicStateCount) |x| {
            const st = ds.pDynamicStates.?[x];
            if (st < 32) p.dynamic |= @as(u32, 1) << @intCast(st);
        }
    }
    // the stages compiled once, gathering what they bind
    if (!dryRun(p)) return R.error_unknown;
    p.res.frozen = true;
    p.n_var = @max(p.n_color, 1);
    var top: u8 = 0;
    for (0..raster.MAX_ATTRS) |a| {
        if (p.res.attrs >> @intCast(a) & 1 != 0) top = @intCast(a + 1);
    }
    for (0..p.n_var) |v| {
        p.emit[v] = .{ .pipe = pi, .loc = if (p.n_color == 0) NONE else @intCast(v) };
        p.rp[v] = raster.Pipeline.init(.{
            .ctx = &p.emit[v],
            .attrs = top,
            .varyings = @max(p.res.varyings_out, p.res.varyings_in),
            .flat = p.res.flat,
            .textures = p.res.n_tex,
            .buffers = p.res.n_bufs,
            .quads = p.res.quads,
            .vertex = &emitVertex,
            .fragment = &emitFragment,
        });
    }
    T.shaders[p.vs].refs += 1;
    if (p.fs != NONE) T.shaders[p.fs].refs += 1;
    p.live = true;
    return R.success;
}

fn dropGPipe(gi: u32) void {
    const p = &T.gpipes[gi];
    if (!p.live) return;
    if (T.eng_live) {
        for (p.rp[0..p.n_var]) |*rp| T.eng.unloadPipeline(rp);
    }
    unrefShader(p.vs);
    if (p.fs != NONE) unrefShader(p.fs);
    p.live = false;
}

fn dropDeviceGraphics(di: u32) void {
    for (&T.gpipes, 0..) |*p, i| if (p.live and p.dev == di) dropGPipe(@intCast(i));
    for (&T.images) |*im| if (im.live and im.dev == di) {
        im.live = false;
    };
}

fn dropEngine() void {
    if (!T.eng_live) return;
    if (T.null_color.cpu.len != 0 or T.null_color.gpu != 0) {
        T.eng.finish();
        if (T.eng.dev) |d| d.free(T.null_color);
        T.null_color = .{};
    }
    T.eng.deinit();
    T.eng_live = false;
}

/// The stage `st` of pipeline p into k (Resources gathered or named).
fn emitStage(p: *const GPipe, st: spirv.Stage, k: *kir.Kernel, io: *spirv.StageIO, res: *spirv.Resources) bool {
    const mi = if (st == .vertex) p.vs else p.fs;
    const sh = T.shaders[mi];
    var gen = spirv.init(T.shader_words[sh.at..][0..sh.n], &T.scratch, .{ .robust = p.robust, .stage = st, .subgroup = theGpu().?.dev.caps.subgroup });
    const name = std.mem.sliceTo(if (st == .vertex) &p.vs_name else &p.fs_name, 0);
    gen.emitStage(name, k, io, res) catch |e| {
        say("vkCreateGraphicsPipelines: {s}: {s} ({s})", .{ name, gen.diag(), @errorName(e) });
        return false;
    };
    return true;
}

/// Each stage compiled once into a throwaway kernel: what the pipeline
/// binds (buffers, textures), its varyings, whether it takes derivatives.
fn dryRun(p: *GPipe) bool {
    const s = kir.Storage{ .insts = &T.insts, .tys = &T.tys };
    var tc = TexCtx{ .tex = 0, .uni = 0 };
    const ops = texOps(&tc);
    {
        var k = kir.Kernel.init(s, "vk_dry_vertex", .{ raster.VERTEX_GROUP, 1, 1 });
        tc.uni = k.binding();
        tc.tex = k.bindings;
        for (0..spirv.MAX_TEX) |_| _ = k.binding();
        const bufs = k.bindings;
        for (0..spirv.MAX_BINDINGS) |_| _ = k.binding();
        var attr: [raster.MAX_ATTRS][4]kir.V = undefined;
        for (&attr) |*a| for (a) |*c| {
            c.* = k.reg(.f32);
        };
        var io = stageIo(tc.uni, bufs, &ops);
        io.attr = &attr;
        io.vertex_id = k.reg(.u32);
        io.instance_id = k.reg(.u32);
        if (!emitStage(p, .vertex, &k, &io, &p.res)) return false;
        if (!dryFinish(&k, "vertex")) return false;
    }
    if (p.fs != NONE) {
        var k = kir.Kernel.init(s, "vk_dry_fragment", .{ raster.TILE, raster.TILE, 1 });
        tc.uni = k.binding();
        tc.tex = k.bindings;
        for (0..spirv.MAX_TEX) |_| _ = k.binding();
        const bufs = k.bindings;
        for (0..spirv.MAX_BINDINGS) |_| _ = k.binding();
        var vary: [raster.MAX_VARYINGS]kir.V = undefined;
        for (&vary) |*v| v.* = k.reg(.f32);
        var io = stageIo(tc.uni, bufs, &ops);
        io.varying_in = &vary;
        for (&io.frag_coord) |*c| c.* = k.reg(.f32);
        io.front_facing = k.reg(.pred);
        io.color_loc = 0;
        if (!emitStage(p, .fragment, &k, &io, &p.res)) return false;
        if (!dryFinish(&k, "fragment")) return false;
    }
    return true;
}

/// A stage's code verifies (KIR's types and structure) as compiled alone.
fn dryFinish(k: *kir.Kernel, stage: []const u8) bool {
    k.finish() catch |e| {
        say("vkCreateGraphicsPipelines: the {s} stage's KIR does not verify ({s})", .{ stage, @errorName(e) });
        return false;
    };
    return true;
}

fn stageIo(uni: u8, bufs: u8, ops: *const spirv.TexOps) spirv.StageIO {
    return .{
        .uni = uni,
        .word_height = W_HEIGHT,
        .word_base_vertex = W_BASE_VERTEX,
        .word_base_instance = W_BASE_INSTANCE,
        .word_push = W_PUSH,
        .word_views = W_VIEWS,
        .buffers = bufs,
        .tex = ops,
        .quad_x = raster.QUAD_X,
        .quad_y = raster.QUAD_Y,
    };
}

/// raster.Shaders.vertex: the vertex stage's SPIR-V.
fn emitVertex(ctx: ?*const anyopaque, k: *kir.Kernel, vio: *raster.VertexIO) void {
    const em: *const Emit = @ptrCast(@alignCast(ctx.?));
    const p = &T.gpipes[em.pipe];
    var tc = TexCtx{ .tex = vio.textures, .uni = vio.uniforms };
    const ops = texOps(&tc);
    var io = stageIo(vio.uniforms, vio.buffers, &ops);
    io.attr = &vio.attr;
    io.vertex_id = vio.vertex_id;
    io.instance_id = vio.instance_id;
    var res = p.res;
    if (!emitStage(p, .vertex, k, &io, &res)) {
        if (k.err == null) k.err = error.BadOperand;
        return;
    }
    vio.position = io.position;
    const n = p.rp[0].shaders.varyings;
    for (0..n) |j| vio.varying[j] = if (io.varying_out[j] != .none) io.varying_out[j] else k.mov(.f32, kir.f(0));
}

/// raster.Shaders.fragment: the fragment stage's SPIR-V, writing the
/// variant's colour location.
fn emitFragment(ctx: ?*const anyopaque, k: *kir.Kernel, fio: *raster.FragmentIO) void {
    const em: *const Emit = @ptrCast(@alignCast(ctx.?));
    const p = &T.gpipes[em.pipe];
    if (p.fs == NONE) {
        for (&fio.color) |*c| c.* = k.mov(.f32, kir.f(0));
        return;
    }
    var tc = TexCtx{ .tex = fio.textures, .uni = fio.uniforms };
    const ops = texOps(&tc);
    var io = stageIo(fio.uniforms, fio.buffers, &ops);
    io.varying_in = &fio.varying;
    io.frag_coord = fio.frag_coord;
    io.front_facing = fio.front_facing;
    io.quads = fio.quads;
    io.odd_x = fio.odd_x;
    io.odd_y = fio.odd_y;
    io.color_loc = em.loc;
    var res = p.res;
    if (!emitStage(p, .fragment, k, &io, &res)) {
        if (k.err == null) k.err = error.BadOperand;
        return;
    }
    fio.color = io.color;
    fio.discard = io.discard;
    fio.derivatives = p.res.quads;
}

// ── Textures: spirv's TexOps over gfxapi's texture.sig ─────────────────────

const TexCtx = struct { tex: u8, uni: u8 };

fn texOps(tc: *const TexCtx) spirv.TexOps {
    return .{ .ctx = tc, .sample = &texSample, .fetch = &texFetch, .size = &texSize, .levels = &texLevels };
}

fn texSlot(ctx: ?*const anyopaque, img: spirv.ImageRef) texture.Slot {
    const tc: *const TexCtx = @ptrCast(@alignCast(ctx.?));
    return .{ .b = tc.tex + @as(u8, @intCast(img.slot)), .uni = tc.uni, .word = W_TEX + img.slot * texture.DESC_WORDS, .volume = img.dim == .d3, .cube = img.dim == .cube, .shadow = img.compare };
}

fn texKind(img: spirv.ImageRef) texture.Kind {
    return switch (img.kind) {
        .float => .float,
        .int => .int,
        .uint => .uint,
    };
}

fn texSample(ctx: ?*const anyopaque, k: *kir.Kernel, img: spirv.ImageRef, c: [4]kir.Arg, lod: spirv.Lod, off: [3]i32) [4]kir.Arg {
    var slot = texSlot(ctx, img);
    var s = c[0];
    var t = c[1];
    var z: ?kir.Arg = null;
    var cube: ?texture.CubeProjection = null;
    switch (img.dim) {
        .d1 => {
            t = kir.f(0.5);
            if (img.arrayed) z = c[1];
        },
        .d3 => {
            z = c[2];
            slot.offset_z = off[2];
        },
        .cube => {
            const pj = texture.cubeProject(k, c[0], c[1], c[2]);
            s = pj.s;
            t = pj.t;
            z = pj.face;
            if (img.arrayed) {
                const layer = k.cvt(.f32, .u32, .rne, c[3]);
                z = kir.r(k.op3(.imad, .u32, kir.r(layer), kir.u(6), pj.face));
            }
            cube = pj;
        },
        else => if (img.arrayed) {
            z = c[2];
        },
    }
    const tl: texture.Lod = switch (lod) {
        .base => .base,
        .level => |x| .{ .level = x },
        .grad => |gr| blk: {
            if (cube) |pj| {
                const dx = texture.cubeGradient(k, pj, gr.dx[0], gr.dx[1], gr.dx[2]);
                const dy = texture.cubeGradient(k, pj, gr.dy[0], gr.dy[1], gr.dy[2]);
                break :blk .{ .grad = .{ .dsdx = dx[0], .dtdx = dx[1], .dsdy = dy[0], .dtdy = dy[1], .bias = gr.bias } };
            }
            const two = img.dim != .d1;
            const vol = img.dim == .d3;
            break :blk .{ .grad = .{ .dsdx = gr.dx[0], .dtdx = if (two) gr.dx[1] else kir.f(0), .dsdy = gr.dy[0], .dtdy = if (two) gr.dy[1] else kir.f(0), .bias = gr.bias, .drdx = if (vol) gr.dx[2] else kir.f(0), .drdy = if (vol) gr.dy[2] else kir.f(0) } };
        },
    };
    return texture.sampleArray(k, slot, s, t, z, texKind(img), .{ off[0], off[1] }, tl);
}

fn texFetch(ctx: ?*const anyopaque, k: *kir.Kernel, img: spirv.ImageRef, c: [4]kir.Arg, lod: kir.Arg) [4]kir.Arg {
    const slot = texSlot(ctx, img);
    const y: kir.Arg = if (img.dim == .d1) kir.u(0) else c[1];
    const layer: ?kir.Arg = switch (img.dim) {
        .d1 => if (img.arrayed) c[1] else null,
        .d3, .cube => c[2],
        else => if (img.arrayed) c[2] else null,
    };
    return texture.fetchArray(k, slot, c[0], y, layer, texKind(img), .{ 0, 0 }, lod);
}

fn texSize(ctx: ?*const anyopaque, k: *kir.Kernel, img: spirv.ImageRef, lod: kir.Arg) [3]kir.Arg {
    const slot = texSlot(ctx, img);
    const sz = texture.size(k, slot, lod);
    const layered = img.arrayed or img.dim == .d3;
    var layers: kir.Arg = if (layered) texture.layerSize(k, slot, lod) else kir.u(1);
    if (img.dim == .cube and img.arrayed) {
        // (layers / 6: the cubes)
        layers = kir.r(k.op2(.shr, .u32, kir.r(k.op2(.imulhi, .u32, layers, kir.u(0xAAAA_AAAB))), kir.u(2)));
    }
    if (img.dim == .d1) return .{ sz[0], layers, kir.u(0) };
    return .{ sz[0], sz[1], layers };
}

fn texLevels(ctx: ?*const anyopaque, k: *kir.Kernel, img: spirv.ImageRef) kir.Arg {
    const slot = texSlot(ctx, img);
    // (the descriptor's last word: the view's levels)
    return kir.r(raster.uniform(k, .u32, slot.uni, slot.word + texture.DESC_WORDS - 1));
}

// ── Images for the engine ──────────────────────────────────────────────────

fn sliceBuf(b: gpu.Buffer, off: u64, len: u64) gpu.Buffer {
    var v = b;
    if (v.gpu != 0) v.gpu += off;
    v.cpu = if (b.cpu.len >= off + len) b.cpu[@intCast(off)..][0..@intCast(len)] else &.{};
    v.bytes = len;
    return v;
}

/// A whole memory as an engine image (a buffer binding, vertices, indices).
fn memImage(mi: u32) engine.Image {
    return engine.wrap(T.memories[mi].buf, 1, 1, 4, .r32ui, false);
}

fn viewOf(vi: u32) ?*View {
    if (vi == NONE or vi >= MAX_VIEWS or !T.views[vi].live) return null;
    const v = &T.views[vi];
    const im = &T.images[v.image];
    if (!im.live or im.mem == NONE or !T.memories[im.mem].live) return null;
    return v;
}

/// An attachment: one level and layer of a view, `h` rows (the
/// framebuffer's), row 0 at the top.
fn attImage(vi: u32, layer: u32, h: u32) ?engine.Image {
    const v = viewOf(vi) orelse return null;
    const im = &T.images[v.image];
    const l = v.base_level;
    const rows = @min(h, im.lh(l));
    const buf = sliceBuf(T.memories[im.mem].buf, im.at(l, v.base_layer + layer), @as(u64, im.pitch(l)) * rows);
    return engine.wrap(buf, im.lw(l), rows, im.pitch(l), im.fi.fmt, true);
}

/// A view as a texture: its levels from its base, its layers from its first.
fn texImage(v: *const View) engine.Image {
    const im = &T.images[v.image];
    const b = v.base_level;
    const buf = sliceBuf(T.memories[im.mem].buf, im.offset, im.size);
    var img = engine.wrap(buf, im.lw(b), im.lh(b), im.pitch(b), im.fi.fmt, false);
    const n = @min(v.levels, MAX_LEVELS - b, im.levels - b);
    img.levels = @intCast(n);
    for (0..n) |l| {
        const lv: u32 = b + @as(u32, @intCast(l));
        img.level_at[l] = @intCast(im.level_at[lv] + (if (im.ty == 2) 0 else @as(u64, v.base_layer) * im.slice(lv)));
    }
    return img;
}

fn texState(img: *engine.Image, v: *const View, s: ?*const Sampler) texture.State {
    const im = &T.images[v.image];
    var st = texture.State{
        .img = img,
        .layers = if (im.ty == 2) im.ld(v.base_level) else v.layers,
        .srgb = v.fi.srgb,
        .swizzle = v.swz,
        .base = 0,
        .last = @intCast(img.levels - 1),
    };
    if (s) |x| {
        st.wrap_s = x.wrap[0];
        st.wrap_t = x.wrap[1];
        st.wrap_r = x.wrap[2];
        st.compare = x.compare;
        st.linear = x.mag;
        st.min_linear = x.min;
        st.mip = if (img.levels > 1) (if (x.mip_linear) texture.Mip.linear else .nearest) else .none;
        st.min_lod = x.min_lod;
        st.max_lod = x.max_lod;
    } else {
        st.wrap_s = .clamp;
        st.wrap_t = .clamp;
        st.wrap_r = .clamp;
    }
    return st;
}

// ── Colours, blending, clears ──────────────────────────────────────────────

fn unorm(x: f32, max: f32) u32 {
    const c = std.math.clamp(x, 0, 1);
    return @intFromFloat(@round(c * max));
}

fn srgbEncode(x: f32) f32 {
    const c = std.math.clamp(x, 0, 1);
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

/// A clear colour as the format's texel (up to four words).
fn colorWords(fi: *const format.Info, cv: abi.ClearColorValue) [4]u32 {
    var w = [4]u32{ 0, 0, 0, 0 };
    switch (fi.fmt) {
        .rgba8, .bgra8, .r8, .rg8 => {
            var c = cv.float32;
            if (fi.srgb) for (c[0..3]) |*x| {
                x.* = srgbEncode(x.*);
            };
            const b = [4]u32{ unorm(c[0], 255), unorm(c[1], 255), unorm(c[2], 255), unorm(c[3], 255) };
            w[0] = switch (fi.fmt) {
                .bgra8 => b[2] | b[1] << 8 | b[0] << 16 | b[3] << 24,
                .r8 => b[0],
                .rg8 => b[0] | b[1] << 8,
                else => b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24,
            };
        },
        .r16 => w[0] = unorm(cv.float32[0], 65535),
        .rg16 => w[0] = unorm(cv.float32[0], 65535) | unorm(cv.float32[1], 65535) << 16,
        else => w = cv.uint32,
    }
    return w;
}

/// The bits of a colour attachment's pixel a write mask keeps.
fn keepOf(f: engine.Format, mask: u32) u32 {
    // the byte of R, G, B, A in the pixel
    const at: [4]u5 = if (f == .bgra8) .{ 16, 8, 0, 24 } else .{ 0, 8, 16, 24 };
    var keep: u32 = 0;
    for (0..4) |c| {
        if (mask >> @intCast(c) & 1 == 0) keep |= @as(u32, 0xff) << at[c];
    }
    return keep;
}

fn factorOf(vf: u32, cst: [4]f32) raster.Factor {
    return switch (vf) {
        0 => .{},
        1 => .{ .c = .{ 1, 1, 1, 1 } },
        2 => .{ .ks = 1 },
        3 => .{ .c = .{ 1, 1, 1, 1 }, .ks = -1 },
        4 => .{ .kd = 1 },
        5 => .{ .c = .{ 1, 1, 1, 1 }, .kd = -1 },
        6 => .{ .ksa = 1 },
        7 => .{ .c = .{ 1, 1, 1, 1 }, .ksa = -1 },
        8 => .{ .kda = 1 },
        9 => .{ .c = .{ 1, 1, 1, 1 }, .kda = -1 },
        10 => .{ .c = cst },
        11 => .{ .c = .{ 1 - cst[0], 1 - cst[1], 1 - cst[2], 1 - cst[3] } },
        12 => .{ .c = .{ cst[3], cst[3], cst[3], cst[3] } },
        13 => .{ .c = .{ 1 - cst[3], 1 - cst[3], 1 - cst[3], 1 - cst[3] } },
        14 => .{ .c = .{ 1, 1, 1, 1 } }, // (alpha's SRC_ALPHA_SATURATE is ONE)
        else => .{},
    };
}

fn blendOf(b: BlendAtt, cst: [4]f32) ?raster.Blend {
    if (!b.enable) return null;
    return .{
        .src_rgb = factorOf(b.src_c, cst),
        .dst_rgb = factorOf(b.dst_c, cst),
        .src_a = factorOf(b.src_a, cst),
        .dst_a = factorOf(b.dst_a, cst),
        .saturate = b.src_c == 14,
        .eq_rgb = @enumFromInt(@as(u8, @intCast(@min(b.op_c, 4)))),
        .eq_a = @enumFromInt(@as(u8, @intCast(@min(b.op_a, 4)))),
    };
}

fn stencilOf(s: abi.StencilOpState, ref: u8, cmask: u8, wmask: u8) raster.Stencil {
    return .{
        .func = @intCast(s.compareOp & 7),
        .reference = ref,
        .value_mask = cmask,
        .write_mask = wmask,
        .fail = @enumFromInt(@as(u3, @intCast(s.failOp & 7))),
        .depth_fail = @enumFromInt(@as(u3, @intCast(s.depthFailOp & 7))),
        .pass = @enumFromInt(@as(u3, @intCast(s.passOp & 7))),
    };
}

// ── The transfer kernel: texel copies, conversions and fills ───────────────
//
// One thread a texel of a row; groups: (width / GROUP, rows, slices).
// Params: src offset, row and slice bytes; dst the same; width; mode;
// src and dst texel bytes; four value words; the bits a fill keeps.

const X_SOFF = 0;
const X_SROW = 1;
const X_SSLICE = 2;
const X_DOFF = 3;
const X_DROW = 4;
const X_DSLICE = 5;
const X_W = 6;
const X_MODE = 7;
const X_SB = 8;
const X_DB = 9;
const X_V = 10;
const X_KEEP = 14;
const X_PARAMS = 15;

const XMode = enum(u32) {
    /// SB bytes as they are
    copy = 0,
    d24_to_f32 = 1,
    f32_to_d24 = 2,
    d24_to_u16 = 3,
    u16_to_d24 = 4,
    s8_out = 5,
    s8_in = 6,
    d24_in = 7,
    fill = 8,
    s8_word_in = 9,
};

fn xferKernel(g: *Gpu) ?gpu.Program {
    var k = kir.Kernel.init(.{ .insts = &T.insts, .tys = &T.tys }, "vk_xfer", .{ GROUP, 1, 1 });
    const r = kir.r;
    const u = kir.u;
    const src = k.binding();
    const dst = k.binding();
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(k.param(.u32, X_W)))));
    const y = k.gid(1);
    const z = k.gid(2);
    const sb = k.param(.u32, X_SB);
    const db = k.param(.u32, X_DB);
    const s = k.op3(.imad, .u32, r(x), r(sb), r(k.op3(.imad, .u32, r(y), r(k.param(.u32, X_SROW)), r(k.op3(.imad, .u32, r(z), r(k.param(.u32, X_SSLICE)), r(k.param(.u32, X_SOFF)))))));
    const d = k.op3(.imad, .u32, r(x), r(db), r(k.op3(.imad, .u32, r(y), r(k.param(.u32, X_DROW)), r(k.op3(.imad, .u32, r(z), r(k.param(.u32, X_DSLICE)), r(k.param(.u32, X_DOFF)))))));
    const mode = k.param(.u32, X_MODE);
    const is = struct {
        fn f_(kk: *kir.Kernel, v: kir.V, m: XMode) kir.V {
            return kk.cmp(.u32, .eq, r(v), u(@intFromEnum(m)));
        }
    }.f_;
    const at = struct {
        fn f_(kk: *kir.Kernel, a: kir.V, add: u32) kir.Arg {
            return if (add == 0) r(a) else r(kk.op2(.iadd, .u32, r(a), u(add)));
        }
    }.f_;
    const g32 = kir.global(dst, 32);
    // fill
    k.ifp(r(is(&k, mode, .fill)));
    {
        k.ifp(r(k.cmp(.u32, .eq, r(db), u(1))));
        k.store(.u32, kir.global(dst, 8), r(d), r(k.param(.u32, X_V)));
        k.els();
        k.ifp(r(k.cmp(.u32, .eq, r(db), u(2))));
        k.store(.u32, kir.global(dst, 16), r(d), r(k.param(.u32, X_V)));
        k.els();
        const keep = k.param(.u32, X_KEEP);
        const old = k.load(.u32, g32, r(d));
        const v = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old), r(keep))), r(k.op2(.@"and", .u32, r(k.param(.u32, X_V)), r(k.op1(.not, .u32, r(keep))))));
        k.store(.u32, g32, r(d), r(v));
        for (1..4) |w| {
            k.ifp(r(k.cmp(.u32, .gt, r(db), u(@intCast(4 * w)))));
            k.store(.u32, g32, at(&k, d, @intCast(4 * w)), r(k.param(.u32, @intCast(X_V + w))));
            k.endif();
        }
        k.endif();
        k.endif();
    }
    k.els();
    k.ifp(r(is(&k, mode, .copy)));
    {
        k.ifp(r(k.cmp(.u32, .eq, r(sb), u(1))));
        k.store(.u32, kir.global(dst, 8), r(d), r(k.load(.u32, kir.global(src, 8), r(s))));
        k.els();
        k.ifp(r(k.cmp(.u32, .eq, r(sb), u(2))));
        k.store(.u32, kir.global(dst, 16), r(d), r(k.load(.u32, kir.global(src, 16), r(s))));
        k.els();
        for (0..4) |w| {
            k.ifp(r(k.cmp(.u32, .gt, r(sb), u(@intCast(4 * w)))));
            k.store(.u32, g32, at(&k, d, @intCast(4 * w)), r(k.load(.u32, kir.global(src, 32), at(&k, s, @intCast(4 * w)))));
            k.endif();
        }
        k.endif();
        k.endif();
    }
    k.els();
    {
        // the depth and stencil conversions: one word of the image's a texel
        const w32 = k.load(.u32, kir.global(src, 32), r(k.op2(.@"and", .u32, r(s), u(0xffff_fffc))));
        const lo24 = k.op2(.@"and", .u32, r(w32), u(0x00ff_ffff));
        k.ifp(r(is(&k, mode, .d24_to_f32)));
        k.store(.f32, g32, r(d), r(k.op2(.fmul, .f32, r(k.cvt(.u32, .f32, .rne, r(lo24))), kir.f(1.0 / 16777215.0))));
        k.endif();
        k.ifp(r(is(&k, mode, .d24_to_u16)));
        const f = k.op2(.fmul, .f32, r(k.cvt(.u32, .f32, .rne, r(lo24))), kir.f(65535.0 / 16777215.0));
        k.store(.u32, kir.global(dst, 16), r(d), r(k.cvt(.f32, .u32, .rne, r(f))));
        k.endif();
        k.ifp(r(is(&k, mode, .s8_out)));
        k.store(.u32, kir.global(dst, 8), r(d), r(k.op2(.shr, .u32, r(w32), u(24))));
        k.endif();
        // into an image's word: the other aspect kept
        const in_d = k.op2(.por, .pred, r(is(&k, mode, .f32_to_d24)), r(k.op2(.por, .pred, r(is(&k, mode, .u16_to_d24)), r(is(&k, mode, .d24_in)))));
        const in_s = k.op2(.por, .pred, r(is(&k, mode, .s8_in)), r(is(&k, mode, .s8_word_in)));
        k.ifp(r(k.op2(.por, .pred, r(in_d), r(in_s))));
        {
            const old = k.load(.u32, g32, r(d));
            const v = k.reg(.u32);
            k.set(v, .mov, r(lo24), kir.no, kir.no);
            k.ifp(r(is(&k, mode, .f32_to_d24)));
            {
                const fv = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(k.mov(.f32, r(w32))), kir.f(0))), kir.f(1));
                k.set(v, .mov, r(k.cvt(.f32, .u32, .rne, r(k.op2(.fmul, .f32, r(fv), kir.f(16777215.0))))), kir.no, kir.no);
            }
            k.endif();
            k.ifp(r(is(&k, mode, .u16_to_d24)));
            {
                const h = k.load(.u32, kir.global(src, 16), r(s));
                k.set(v, .@"or", r(k.op2(.shl, .u32, r(h), u(8))), r(k.op2(.shr, .u32, r(h), u(8))), kir.no);
            }
            k.endif();
            k.ifp(r(in_s));
            {
                const b = k.reg(.u32);
                k.set(b, .shr, r(w32), u(24), kir.no);
                k.ifp(r(is(&k, mode, .s8_in)));
                k.set(b, .mov, r(k.load(.u32, kir.global(src, 8), r(s))), kir.no, kir.no);
                k.endif();
                k.store(.u32, g32, r(d), r(k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old), u(0x00ff_ffff))), r(k.op2(.shl, .u32, r(b), u(24))))));
            }
            k.els();
            k.store(.u32, g32, r(d), r(k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old), u(0xff00_0000))), r(v))));
            k.endif();
        }
        k.endif();
    }
    k.endif();
    k.endif();
    k.endif();
    k.finish() catch |e| {
        say("the transfer kernel does not verify ({s})", .{@errorName(e)});
        return null;
    };
    var work = gpu.Work.init(g.work);
    const bin = g.compile(&k, g.dev.caps, &work, &T.code) catch |e| {
        say("the transfer kernel did not compile ({s})", .{@errorName(e)});
        return null;
    };
    return g.dev.load(&bin) catch null;
}

// ── Recording graphics commands ────────────────────────────────────────────

const BeginPass = extern struct { rp: u32, fb: u32, x: i32, y: i32, w: u32, h: u32, n: u32, pad: u32 = 0, clears: [MAX_ATT]abi.ClearValue };
const BindVb = extern struct { first: u32, count: u32, bufs: [MAX_VB]u32, offs: [MAX_VB]u64 };
const BindIb = extern struct { buf: u32, ty: u32, off: u64 };
const StencilSet = extern struct { faces: u32, what: u32, value: u32 };
const DrawCmd = extern struct { count: u32, instances: u32, first: u32, vertex_offset: i32, first_instance: u32, indexed: u32 };
const DrawIndirect = extern struct { buf: u32, indexed: u32, offset: u64, n: u32, stride: u32 };
const MAX_CLEAR_RECTS = 8;
const ClearAtts = extern struct { n_att: u32, n_rect: u32, atts: [MAX_ATT]abi.ClearAttachment, rects: [MAX_CLEAR_RECTS]abi.ClearRect };
const BufImage = extern struct { buf: u32, image: u32, region: abi.BufferImageCopy };
const ImgImg = extern struct { src: u32, dst: u32, region: abi.ImageCopy };
const ClearImage = extern struct { image: u32, depth_stencil: u32, value: abi.ClearValue, range: abi.ImageSubresourceRange };
const Blit = extern struct { src: u32, dst: u32, filter: u32, region: abi.ImageBlit };

fn recording(h: ?*anyopaque) ?*CmdBuf {
    return cbOf(h);
}

fn cmdBeginRenderPass(h: ?*anyopaque, info: ?*const abi.RenderPassBeginInfo, _: u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    const bi = info orelse return;
    var b = BeginPass{ .rp = unhandle(.render_pass, bi.renderPass) orelse NONE, .fb = unhandle(.framebuffer, bi.framebuffer) orelse NONE, .x = bi.renderArea.offset.x, .y = bi.renderArea.offset.y, .w = bi.renderArea.extent.width, .h = bi.renderArea.extent.height, .n = @min(bi.clearValueCount, MAX_ATT), .clears = undefined };
    for (0..b.n) |i| b.clears[i] = bi.pClearValues.?[i];
    put(cb, .begin_pass, b);
}

fn cmdEndRenderPass(h: ?*anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    put(cb, .end_pass, @as(u32, 0));
}

fn cmdNextSubpass(_: ?*anyopaque, _: u32) callconv(.c) void {
    say("vkCmdNextSubpass: only the first subpass is drawn", .{});
}

fn cmdBindVertexBuffers(h: ?*anyopaque, first: u32, count: u32, bufs: ?[*]const u64, offs: ?[*]const u64) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    var b = BindVb{ .first = first, .count = @min(count, MAX_VB), .bufs = undefined, .offs = undefined };
    for (0..b.count) |i| {
        b.bufs[i] = unhandle(.buffer, bufs.?[i]) orelse NONE;
        b.offs[i] = offs.?[i];
    }
    put(cb, .bind_vb, b);
}

fn cmdBindIndexBuffer(h: ?*anyopaque, buf: u64, off: u64, ty: u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    put(cb, .bind_ib, BindIb{ .buf = unhandle(.buffer, buf) orelse NONE, .ty = if (ty == 1000265000) 2 else ty, .off = off });
}

fn cmdSetViewport(h: ?*anyopaque, first: u32, count: u32, vps: ?[*]const abi.Viewport) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    if (first != 0 or count == 0) return;
    put(cb, .viewport, vps.?[0]);
}

fn cmdSetScissor(h: ?*anyopaque, first: u32, count: u32, rects: ?[*]const abi.Rect2D) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    if (first != 0 or count == 0) return;
    put(cb, .scissor, rects.?[0]);
}

fn stencilSet(h: ?*anyopaque, faces: u32, what: u32, value: u32) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    put(cb, .stencil, StencilSet{ .faces = faces, .what = what, .value = value });
}
fn cmdSetStencilReference(h: ?*anyopaque, faces: u32, v: u32) callconv(.c) void {
    stencilSet(h, faces, 0, v);
}
fn cmdSetStencilCompareMask(h: ?*anyopaque, faces: u32, v: u32) callconv(.c) void {
    stencilSet(h, faces, 1, v);
}
fn cmdSetStencilWriteMask(h: ?*anyopaque, faces: u32, v: u32) callconv(.c) void {
    stencilSet(h, faces, 2, v);
}

fn cmdSetBlendConstants(h: ?*anyopaque, c: ?*const [4]f32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    put(cb, .blend_consts, (c orelse return).*);
}

fn cmdSetDepthBias(_: ?*anyopaque, _: f32, _: f32, _: f32) callconv(.c) void {}
fn cmdSetLineWidth(_: ?*anyopaque, _: f32) callconv(.c) void {}
fn cmdSetDepthBounds(_: ?*anyopaque, _: f32, _: f32) callconv(.c) void {}
fn cmdSetDeviceMask(_: ?*anyopaque, _: u32) callconv(.c) void {}

fn getDeviceGroupPeerMemoryFeatures(_: ?*anyopaque, _: u32, _: u32, _: u32, out: ?*u32) callconv(.c) void {
    (out orelse return).* = 0xf;
}

fn cmdDraw(h: ?*anyopaque, vc: u32, ic: u32, fv: u32, fi: u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    put(cb, .draw, DrawCmd{ .count = vc, .instances = ic, .first = fv, .vertex_offset = 0, .first_instance = fi, .indexed = 0 });
}

fn cmdDrawIndexed(h: ?*anyopaque, ic: u32, inst: u32, first: u32, vo: i32, fi: u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    put(cb, .draw, DrawCmd{ .count = ic, .instances = inst, .first = first, .vertex_offset = vo, .first_instance = fi, .indexed = 1 });
}

fn drawIndirect(h: ?*anyopaque, buf: u64, off: u64, n: u32, stride: u32, indexed: u32) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    if (n == 0) return;
    put(cb, .draw_indirect, DrawIndirect{ .buf = unhandle(.buffer, buf) orelse NONE, .indexed = indexed, .offset = off, .n = n, .stride = stride });
}
fn cmdDrawIndirect(h: ?*anyopaque, buf: u64, off: u64, n: u32, stride: u32) callconv(.c) void {
    drawIndirect(h, buf, off, n, stride, 0);
}
fn cmdDrawIndexedIndirect(h: ?*anyopaque, buf: u64, off: u64, n: u32, stride: u32) callconv(.c) void {
    drawIndirect(h, buf, off, n, stride, 1);
}

fn cmdClearAttachments(h: ?*anyopaque, na: u32, atts: ?[*]const abi.ClearAttachment, nr: u32, rects: ?[*]const abi.ClearRect) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    var done: u32 = 0;
    while (done < nr) {
        var c = ClearAtts{ .n_att = @min(na, MAX_ATT), .n_rect = @min(nr - done, MAX_CLEAR_RECTS), .atts = undefined, .rects = undefined };
        for (0..c.n_att) |i| c.atts[i] = atts.?[i];
        for (0..c.n_rect) |i| c.rects[i] = rects.?[done + i];
        put(cb, .clear_atts, c);
        done += c.n_rect;
    }
}

fn cmdCopyBufferToImage(h: ?*anyopaque, buf: u64, img: u64, _: u32, n: u32, regions: ?[*]const abi.BufferImageCopy) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    for (0..n) |i| put(cb, .copy_b2i, BufImage{ .buf = unhandle(.buffer, buf) orelse NONE, .image = unhandle(.image, img) orelse NONE, .region = regions.?[i] });
}

fn cmdCopyImageToBuffer(h: ?*anyopaque, img: u64, _: u32, buf: u64, n: u32, regions: ?[*]const abi.BufferImageCopy) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    for (0..n) |i| put(cb, .copy_i2b, BufImage{ .buf = unhandle(.buffer, buf) orelse NONE, .image = unhandle(.image, img) orelse NONE, .region = regions.?[i] });
}

fn cmdCopyImage(h: ?*anyopaque, src: u64, _: u32, dst: u64, _: u32, n: u32, regions: ?[*]const abi.ImageCopy) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    for (0..n) |i| put(cb, .copy_i2i, ImgImg{ .src = unhandle(.image, src) orelse NONE, .dst = unhandle(.image, dst) orelse NONE, .region = regions.?[i] });
}

/// (4x images keep one sample: a resolve is a copy)
fn cmdResolveImage(h: ?*anyopaque, src: u64, sl: u32, dst: u64, dl: u32, n: u32, regions: ?[*]const abi.ImageCopy) callconv(.c) void {
    cmdCopyImage(h, src, sl, dst, dl, n, regions);
}

fn cmdBlitImage(h: ?*anyopaque, src: u64, _: u32, dst: u64, _: u32, n: u32, regions: ?[*]const abi.ImageBlit, filter: u32) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    for (0..n) |i| put(cb, .blit, Blit{ .src = unhandle(.image, src) orelse NONE, .dst = unhandle(.image, dst) orelse NONE, .filter = filter, .region = regions.?[i] });
}

fn cmdClearColorImage(h: ?*anyopaque, img: u64, _: u32, color: ?*const abi.ClearColorValue, n: u32, ranges: ?[*]const abi.ImageSubresourceRange) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    const c = color orelse return;
    for (0..n) |i| put(cb, .clear_image, ClearImage{ .image = unhandle(.image, img) orelse NONE, .depth_stencil = 0, .value = .{ .color = c.* }, .range = ranges.?[i] });
}

fn cmdClearDepthStencilImage(h: ?*anyopaque, img: u64, _: u32, ds: ?*const abi.ClearDepthStencilValue, n: u32, ranges: ?[*]const abi.ImageSubresourceRange) callconv(.c) void {
    lock();
    defer unlock();
    const cb = recording(h) orelse return;
    const v = ds orelse return;
    for (0..n) |i| put(cb, .clear_image, ClearImage{ .image = unhandle(.image, img) orelse NONE, .depth_stencil = 1, .value = .{ .depthStencil = v.* }, .range = ranges.?[i] });
}

// ── External memory, semaphores and fences (fds) ───────────────────────────
//
// What Firefox's WebGPU shares with WebRender (wgpu_bindings' server.rs on
// Linux: VK_KHR_external_memory_fd, VK_EXT_external_memory_dma_buf,
// VK_EXT_image_drm_format_modifier, VK_KHR_external_semaphore_fd), over
// the root's Host (Galaxy's render node: PRIME export and import, fence
// files). Without a Host none of it is offered.
//
// - **Memory out**: memory allocated for export (VkExportMemoryAllocateInfo)
//   is system memory the GPU maps, whatever its type says, as EGL's window
//   buffers are (the compositor and other contexts map such dma-bufs);
//   vkGetMemoryFdKHR is its dma-buf (PRIME), opaque fds the same.
// - **Memory in**: VkImportMemoryFdInfoKHR maps a dma-buf as this device's
//   memory (PRIME import), zero-copy; the fd is the driver's then (closed).
// - **Images**: every image is linear, so DRM_FORMAT_MOD_LINEAR is the one
//   modifier, one plane, rows as format.sig keeps them; an explicit layout
//   must be that one.
// - **Semaphores**: exported ones (opaque fd or sync_file) are fence files
//   of everything submitted so far. A submission that signals a semaphore
//   made for export waits for its work before vkQueueSubmit returns: the
//   other side (Firefox's WebRender on Galaxy's GL, which has no
//   EXT_semaphore_fd to wait with) then finds the pixels done. Imported
//   ones are waited for on the CPU at import (sync_files poll).

const EXT_MEM_FDS: u32 = abi.ExternalHandle.opaque_fd | abi.ExternalHandle.dma_buf;
const EXT_SEM_FDS: u32 = abi.ExternalHandle.opaque_fd | abi.ExternalHandle.semaphore_sync_fd;
const EXT_FENCE_FDS: u32 = abi.ExternalHandle.opaque_fd | abi.ExternalHandle.fence_sync_fd;

fn hasHost() bool {
    const g = theGpu() orelse return false;
    return g.host != null;
}

fn externalMemoryProps(handle_type: u32) abi.ExternalMemoryProperties {
    if (!hasHost() or handle_type & EXT_MEM_FDS == 0 or @popCount(handle_type) != 1) return std.mem.zeroes(abi.ExternalMemoryProperties);
    return .{
        .externalMemoryFeatures = abi.ExternalHandle.memory_exportable | abi.ExternalHandle.memory_importable,
        .exportFromImportedHandleTypes = EXT_MEM_FDS,
        .compatibleHandleTypes = EXT_MEM_FDS,
    };
}

fn getPhysicalDeviceExternalBufferProperties(_: ?*anyopaque, info: ?*const abi.PhysicalDeviceExternalBufferInfo, out: ?*abi.ExternalBufferProperties) callconv(.c) void {
    lock();
    defer unlock();
    const o = out orelse return;
    o.externalMemoryProperties = externalMemoryProps(if (info) |i| i.handleType else 0);
}

fn getPhysicalDeviceExternalFenceProperties(_: ?*anyopaque, info: ?*const abi.PhysicalDeviceExternalFenceInfo, out: ?*abi.ExternalFenceProperties) callconv(.c) void {
    lock();
    defer unlock();
    const o = out orelse return;
    const t = if (info) |i| i.handleType else 0;
    const ok = hasHost() and t == abi.ExternalHandle.fence_sync_fd;
    o.exportFromImportedHandleTypes = if (ok) t else 0;
    o.compatibleHandleTypes = if (ok) t else 0;
    o.externalFenceFeatures = if (ok) abi.ExternalHandle.exportable | abi.ExternalHandle.importable else 0;
}

fn getPhysicalDeviceExternalSemaphoreProperties(_: ?*anyopaque, info: ?*const abi.PhysicalDeviceExternalSemaphoreInfo, out: ?*abi.ExternalSemaphoreProperties) callconv(.c) void {
    lock();
    defer unlock();
    const o = out orelse return;
    const t = if (info) |i| i.handleType else 0;
    // (binary semaphores: a timeline one asked for in the chain is not exported)
    var timeline = false;
    if (info) |i| if (findIn(i.pNext, ST.semaphore_type_create_info)) |b| {
        const ti: *const abi.SemaphoreTypeCreateInfo = @ptrCast(@alignCast(b));
        timeline = ti.semaphoreType == 1;
    };
    const ok = hasHost() and !timeline and t & EXT_SEM_FDS != 0 and @popCount(t) == 1;
    o.exportFromImportedHandleTypes = if (ok) t else 0;
    o.compatibleHandleTypes = if (ok) t else 0;
    o.externalSemaphoreFeatures = if (ok) abi.ExternalHandle.exportable | abi.ExternalHandle.importable else 0;
}

fn getMemoryFd(dh: ?*anyopaque, info: ?*const abi.MemoryGetFdInfoKHR, out: ?*i32) callconv(.c) Result {
    const gi = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const h = g.host orelse return R.error_invalid_external_handle;
    if (gi.handleType & EXT_MEM_FDS == 0) return R.error_invalid_external_handle;
    const m = memOf(gi.memory) orelse return R.error_invalid_external_handle;
    const fd = h.exportFd(h.ctx, m.buf);
    if (fd < 0) {
        say("vkGetMemoryFdKHR: the render node gave no dma-buf (errno {d})", .{-fd});
        return R.error_too_many_objects;
    }
    (out orelse return R.error_initialization_failed).* = @intCast(fd);
    return R.success;
}

fn getMemoryFdProperties(dh: ?*anyopaque, handle_type: u32, fd: i32, out: ?*abi.MemoryFdPropertiesKHR) callconv(.c) Result {
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    if (!hasHost() or handle_type != abi.ExternalHandle.dma_buf or fd < 0) return R.error_invalid_external_handle;
    (out orelse return R.error_initialization_failed).memoryTypeBits = (@as(u32, 1) << @intCast(T.n_mem_types)) - 1;
    return R.success;
}

fn getSemaphoreFd(dh: ?*anyopaque, info: ?*const abi.SemaphoreGetFdInfoKHR, out: ?*i32) callconv(.c) Result {
    const gi = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const h = g.host orelse return R.error_invalid_external_handle;
    if (gi.handleType & EXT_SEM_FDS == 0) return R.error_invalid_external_handle;
    const s = semOf(gi.semaphore) orelse return R.error_invalid_external_handle;
    // (a fence file of everything submitted so far: its signal comes
    // after, in the in-order queue, or was waited for already)
    const fd = h.fenceFd(h.ctx);
    if (fd < 0) {
        say("vkGetSemaphoreFdKHR: the render node gave no fence file (errno {d})", .{-fd});
        return R.error_too_many_objects;
    }
    // (a sync_file export takes the payload: the semaphore is unsignaled)
    if (gi.handleType == abi.ExternalHandle.semaphore_sync_fd) s.signaled = false;
    (out orelse return R.error_initialization_failed).* = @intCast(fd);
    return R.success;
}

/// An imported fence file, waited for on the CPU (at most a second) and closed.
fn settleFd(h: gfxapi.host.Host, fd: i32) void {
    if (fd < 0) return;
    _ = h.poll(h.ctx, fd, 1000);
    h.close(h.ctx, fd);
}

fn importSemaphoreFd(dh: ?*anyopaque, info: ?*const abi.ImportSemaphoreFdInfoKHR) callconv(.c) Result {
    const ii = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const h = g.host orelse return R.error_invalid_external_handle;
    if (ii.handleType & EXT_SEM_FDS == 0) return R.error_invalid_external_handle;
    const s = semOf(ii.semaphore) orelse return R.error_invalid_external_handle;
    if (s.timeline) return R.error_invalid_external_handle;
    settleFd(h, ii.fd);
    s.signaled = true;
    return R.success;
}

fn getFenceFd(dh: ?*anyopaque, info: ?*const abi.FenceGetFdInfoKHR, out: ?*i32) callconv(.c) Result {
    const gi = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const h = g.host orelse return R.error_invalid_external_handle;
    if (gi.handleType != abi.ExternalHandle.fence_sync_fd) return R.error_invalid_external_handle;
    const f = fenceOf(gi.fence) orelse return R.error_invalid_external_handle;
    const o = out orelse return R.error_initialization_failed;
    // (signaled already: -1, as the spec lets a sync_file export say)
    if (fenceDone(g, f)) {
        o.* = -1;
        return R.success;
    }
    const fd = h.fenceFd(h.ctx);
    if (fd < 0) return R.error_too_many_objects;
    o.* = @intCast(fd);
    return R.success;
}

fn importFenceFd(dh: ?*anyopaque, info: ?*const abi.ImportFenceFdInfoKHR) callconv(.c) Result {
    const ii = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    _ = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const h = g.host orelse return R.error_invalid_external_handle;
    if (ii.handleType != abi.ExternalHandle.fence_sync_fd) return R.error_invalid_external_handle;
    const f = fenceOf(ii.fence) orelse return R.error_invalid_external_handle;
    settleFd(h, ii.fd);
    f.signaled = true;
    f.pending = 0;
    return R.success;
}

fn getImageDrmFormatModifierProperties(_: ?*anyopaque, ih: u64, out: ?*abi.ImageDrmFormatModifierPropertiesEXT) callconv(.c) Result {
    lock();
    defer unlock();
    _ = imgOf(ih) orelse return R.error_initialization_failed;
    (out orelse return R.error_initialization_failed).drmFormatModifier = abi.DRM_MOD_LINEAR;
    return R.success;
}

/// VkDrmFormatModifierPropertiesListEXT for format `f`: linear, where the
/// format has linear images.
fn fillModifierList(f: u32, chain: ?*anyopaque) void {
    const lin = format.props(f).linear;
    var cur: ?*abi.BaseOutStructure = @ptrCast(@alignCast(chain));
    while (cur) |c| : (cur = nextOut(c)) {
        if (c.sType != ST.drm_format_modifier_properties_list_ext) continue;
        const ml: *abi.DrmFormatModifierPropertiesListEXT = @ptrCast(@alignCast(c));
        const n: u32 = if (lin != 0) 1 else 0;
        if (ml.pDrmFormatModifierProperties) |arr| {
            if (ml.drmFormatModifierCount >= 1 and n == 1) arr[0] = .{ .drmFormatModifier = abi.DRM_MOD_LINEAR, .drmFormatModifierPlaneCount = 1, .drmFormatModifierTilingFeatures = lin };
            ml.drmFormatModifierCount = @min(ml.drmFormatModifierCount, n);
        } else ml.drmFormatModifierCount = n;
    }
}

// ── Presentation: VK_KHR_surface, VK_KHR_wayland_surface, VK_KHR_swapchain ─
//
// The loader makes a Wayland VkSurfaceKHR itself (its VkIcdSurfaceWayland:
// the app's wl_display and wl_surface) and hands it here. A swapchain is
// gfxapi's Wayland platform (wayland.sig) as EGL's windows use it: the
// app's libwayland-client (the root's `wayland`), a queue of the
// driver's own, zwp_linux_dmabuf_v1. Its images are linear BGRA8 images in
// system memory, each a dma-buf (PRIME) made a wl_buffer by create_immed
// (DRM ARGB8888, or XRGB8888 for an opaque swapchain). vkAcquireNextImageKHR
// takes an image the compositor has released (dispatching the driver's
// queue, waiting for a release when every image is out); its semaphore and
// fence are signaled at once. vkQueuePresentKHR attaches, damages the
// whole buffer, commits and flushes, after the work submitted before it
// (the queue runs in order; Galaxy's dma-buf fences cover the GPU's
// writes, as for EGL's swaps). FIFO waits for the frame callback of the
// frame before (one frame on the screen at a time); MAILBOX does not.

pub const MAX_SWAPCHAINS = 16;
pub const MAX_SC_IMAGES = 4;
const SC_FORMAT: u32 = 44; // VK_FORMAT_B8G8R8A8_UNORM
const PRESENT_MAILBOX: u32 = 1;
const PRESENT_FIFO: u32 = 2;
const SUBOPTIMAL: Result = 1000001003;
const SURFACE_EXTENT_ANY: u32 = 0xffff_ffff;
// (wl_surface's, zwp_linux_dmabuf_v1's and its params' requests)
const WL_SURFACE_ATTACH = 1;
const WL_SURFACE_DAMAGE = 2;
const WL_SURFACE_FRAME = 3;
const WL_SURFACE_COMMIT = 6;
const WL_SURFACE_DAMAGE_BUFFER = 9;
const WL_BUFFER_DESTROY = 0;
const DMABUF_CREATE_PARAMS = 1;
const PARAMS_DESTROY = 0;
const PARAMS_ADD = 1;
const PARAMS_CREATE_IMMED = 3;

const ScImage = struct {
    image: u32 = NONE,
    mem: u32 = NONE,
    buf: ?*wl.Proxy = null,
    /// the compositor holds it (attached, not released yet)
    busy: bool = false,
    /// the app holds it (acquired, not presented yet)
    acquired: bool = false,
};

const Swapchain = struct {
    live: bool = false,
    dev: u32 = 0,
    display: wl.Display = undefined,
    surface: ?*wl.Proxy = null,
    n: u32 = 0,
    imgs: [MAX_SC_IMAGES]ScImage = [_]ScImage{.{}} ** MAX_SC_IMAGES,
    frame_cb: ?*wl.Proxy = null,
    fifo: bool = true,
    alpha: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    /// replaced by a newer swapchain (oldSwapchain): nothing more to acquire
    retired: bool = false,
    presents: u64 = 0,
};

fn wsiClient(g: *Gpu) ?*const wl.Client {
    if (g.host == null) return null;
    const f = g.wayland orelse return null;
    return f();
}

fn surfaceOf(h: u64) ?*const abi.IcdSurfaceWayland {
    if (h == 0) return null;
    const s: *const abi.IcdSurfaceWayland = @ptrFromInt(@as(usize, @intCast(h)));
    if (s.platform != abi.ICD_WSI_PLATFORM_WAYLAND or s.display == null or s.surface == null) return null;
    return s;
}

fn scOf(h: u64) ?*Swapchain {
    const i = unhandle(.swapchain, h) orelse return null;
    return if (T.swapchains[i].live) &T.swapchains[i] else null;
}

fn getPhysicalDeviceSurfaceSupport(_: ?*anyopaque, family: u32, surface: u64, out: ?*u32) callconv(.c) Result {
    lock();
    defer unlock();
    const g = theGpu() orelse return R.error_initialization_failed;
    const ok = family == 0 and surfaceOf(surface) != null and wsiClient(g) != null;
    (out orelse return R.error_initialization_failed).* = @intFromBool(ok);
    return R.success;
}

fn getPhysicalDeviceWaylandPresentationSupport(_: ?*anyopaque, family: u32, display: ?*anyopaque) callconv(.c) u32 {
    lock();
    defer unlock();
    const g = theGpu() orelse return 0;
    return @intFromBool(family == 0 and display != null and wsiClient(g) != null);
}

fn surfaceCaps() abi.SurfaceCapabilitiesKHR {
    return .{
        .minImageCount = 2,
        .maxImageCount = MAX_SC_IMAGES,
        // (Wayland: the swapchain's size is the window's)
        .currentExtent = .{ .width = SURFACE_EXTENT_ANY, .height = SURFACE_EXTENT_ANY },
        .minImageExtent = .{ .width = 1, .height = 1 },
        .maxImageExtent = .{ .width = MAX_IMAGE_2D, .height = MAX_IMAGE_2D },
        .maxImageArrayLayers = 1,
        .supportedTransforms = 1, // identity
        .currentTransform = 1,
        .supportedCompositeAlpha = 0x1 | 0x2, // opaque, premultiplied
        // transfer src and dst, sampled, colour attachment
        .supportedUsageFlags = 0x1 | 0x2 | 0x4 | 0x10,
    };
}

fn getPhysicalDeviceSurfaceCapabilities(_: ?*anyopaque, surface: u64, out: ?*abi.SurfaceCapabilitiesKHR) callconv(.c) Result {
    lock();
    defer unlock();
    _ = surfaceOf(surface) orelse return R.error_surface_lost_khr;
    (out orelse return R.error_initialization_failed).* = surfaceCaps();
    return R.success;
}

fn getPhysicalDeviceSurfaceFormats(_: ?*anyopaque, surface: u64, count: ?*u32, out: ?[*]abi.SurfaceFormatKHR) callconv(.c) Result {
    lock();
    defer unlock();
    _ = surfaceOf(surface) orelse return R.error_surface_lost_khr;
    // (BGRA8, sRGB colour space: what the raster writes and Wayland's ARGB8888 is)
    return enumerate(abi.SurfaceFormatKHR, &.{.{ .format = SC_FORMAT, .colorSpace = 0 }}, count, out);
}

fn getPhysicalDeviceSurfacePresentModes(_: ?*anyopaque, surface: u64, count: ?*u32, out: ?[*]u32) callconv(.c) Result {
    lock();
    defer unlock();
    _ = surfaceOf(surface) orelse return R.error_surface_lost_khr;
    return enumerate(u32, &.{ PRESENT_FIFO, PRESENT_MAILBOX }, count, out);
}

fn getPhysicalDevicePresentRectangles(_: ?*anyopaque, surface: u64, count: ?*u32, out: ?[*]abi.Rect2D) callconv(.c) Result {
    _ = surfaceOf(surface) orelse return R.error_surface_lost_khr;
    const all = abi.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = MAX_IMAGE_2D, .height = MAX_IMAGE_2D } };
    return enumerate(abi.Rect2D, &.{all}, count, out);
}

fn getDeviceGroupPresentCapabilities(_: ?*anyopaque, out: ?*abi.DeviceGroupPresentCapabilitiesKHR) callconv(.c) Result {
    const o = out orelse return R.error_initialization_failed;
    @memset(&o.presentMask, 0);
    o.presentMask[0] = 1;
    o.modes = 1; // local
    return R.success;
}

fn getDeviceGroupSurfacePresentModes(_: ?*anyopaque, _: u64, out: ?*u32) callconv(.c) Result {
    (out orelse return R.error_initialization_failed).* = 1;
    return R.success;
}

fn createSwapchain(dh: ?*anyopaque, info: ?*const abi.SwapchainCreateInfoKHR, _: ?*const anyopaque, out: ?*u64) callconv(.c) Result {
    const ci = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = devOf(dh) orelse return R.error_initialization_failed;
    const g = theGpu() orelse return R.error_initialization_failed;
    const h = g.host orelse return R.error_initialization_failed;
    const c = wsiClient(g) orelse return R.error_surface_lost_khr;
    const surf = surfaceOf(ci.surface) orelse return R.error_surface_lost_khr;
    if (ci.imageFormat != SC_FORMAT or ci.imageArrayLayers != 1) {
        say("vkCreateSwapchainKHR: format {d}, {d} layers (BGRA8 UNORM, one layer)", .{ ci.imageFormat, ci.imageArrayLayers });
        return R.error_initialization_failed;
    }
    const w = ci.imageExtent.width;
    const hh = ci.imageExtent.height;
    if (w == 0 or hh == 0 or w > MAX_IMAGE_2D or hh > MAX_IMAGE_2D or ci.minImageCount > MAX_SC_IMAGES) return R.error_initialization_failed;
    // the swapchain it replaces gives nothing more to acquire
    if (scOf(ci.oldSwapchain)) |old| old.retired = true;
    const si = findFree("swapchains") orelse return R.error_too_many_objects;
    const sc = &T.swapchains[si];
    sc.* = .{ .live = true, .dev = di, .fifo = ci.presentMode != PRESENT_MAILBOX and ci.presentMode != 0, .alpha = ci.compositeAlpha != 0x1, .w = w, .h = hh };
    if (!sc.display.init(c, h, @ptrCast(surf.display.?))) {
        sc.live = false;
        say("vkCreateSwapchainKHR: the compositor offers no linear dma-bufs", .{});
        return R.error_surface_lost_khr;
    }
    if (!sc.display.takes(sc.alpha)) sc.alpha = !sc.alpha;
    sc.surface = c.create_wrapper(@ptrCast(surf.surface.?));
    if (sc.surface == null) {
        dropSwapchain(g, sc);
        return R.error_surface_lost_khr;
    }
    c.set_queue(sc.surface.?, sc.display.queue);
    sc.n = @max(ci.minImageCount, 2);
    for (0..sc.n) |i| {
        if (!makeScImage(g, h, sc, @intCast(i))) {
            dropSwapchain(g, sc);
            return R.error_out_of_device_memory;
        }
    }
    (out orelse return R.error_initialization_failed).* = handle(.swapchain, si);
    return R.success;
}

/// Image `i` of `sc`: an image and its memory (system memory), its
/// dma-buf a wl_buffer.
fn makeScImage(g: *Gpu, h: gfxapi.host.Host, sc: *Swapchain, i: u32) bool {
    const c = sc.display.c;
    const fi = format.image(SC_FORMAT).?;
    const ii = findFree("images") orelse return false;
    var im = Image{ .live = true, .dev = sc.dev, .fi = fi, .ty = 1, .w = sc.w, .h = sc.h, .d = 1, .levels = 1, .layers = 1, .mem = NONE, .offset = 0, .level_at = undefined, .size = 0 };
    im.level_at[0] = 0;
    im.size = std.mem.alignForward(u64, im.slice(0), 256);
    const mi = findFree("memories") orelse return false;
    const buf = g.dev.alloc(im.size, .host) catch return false;
    T.memories[mi] = .{ .live = true, .dev = sc.dev, .buf = buf, .size = im.size, .host = false, .mapped = false, .dirty = false, .dirty_fence = 0, .swapchain = true };
    im.mem = mi;
    T.images[ii] = im;
    sc.imgs[i] = .{ .image = ii, .mem = mi };
    const fd = h.exportFd(h.ctx, buf);
    if (fd < 0) {
        say("vkCreateSwapchainKHR: no dma-buf for a {d}x{d} image (errno {d})", .{ sc.w, sc.h, -fd });
        return false;
    }
    defer h.close(h.ctx, @intCast(fd));
    var none = [_]wl.Arg{.{ .o = null }};
    const params = c.send(sc.display.dmabuf.?, DMABUF_CREATE_PARAMS, &wl.params_interface, null, 0, &none) orelse return false;
    var add = [_]wl.Arg{ .{ .h = @intCast(fd) }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = im.pitch(0) }, .{ .u = @intCast(abi.DRM_MOD_LINEAR >> 32) }, .{ .u = @truncate(abi.DRM_MOD_LINEAR) } };
    _ = c.send(params, PARAMS_ADD, null, null, 0, &add);
    const drm: u32 = if (sc.alpha) wl.DRM_FORMAT_ARGB8888 else wl.DRM_FORMAT_XRGB8888;
    var immed = [_]wl.Arg{ .{ .o = null }, .{ .i = @intCast(sc.w) }, .{ .i = @intCast(sc.h) }, .{ .u = drm }, .{ .u = 0 } };
    sc.imgs[i].buf = c.send(params, PARAMS_CREATE_IMMED, c.buffer_interface, 1, 0, &immed);
    _ = c.send(params, PARAMS_DESTROY, null, null, wl.DESTROY, &none);
    const b = sc.imgs[i].buf orelse return false;
    _ = c.add_dispatcher(b, &onScBuffer, &sc.imgs[i], null);
    return true;
}

fn dropSwapchain(g: *Gpu, sc: *Swapchain) void {
    const c = sc.display.c;
    var none = [_]wl.Arg{.{ .o = null }};
    // (the GPU's work on its images done first)
    const d = &T.devices[sc.dev];
    if (d.live and d.last_fence != 0) _ = waitFence(g, d.last_fence, 1_000_000_000);
    if (sc.frame_cb) |p| c.destroy(p);
    sc.frame_cb = null;
    for (sc.imgs[0..sc.n]) |*x| {
        if (x.buf) |p| _ = c.send(p, WL_BUFFER_DESTROY, null, null, wl.DESTROY, &none);
        if (x.mem != NONE and T.memories[x.mem].live) {
            g.dev.free(T.memories[x.mem].buf);
            T.memories[x.mem].live = false;
        }
        if (x.image != NONE) T.images[x.image].live = false;
        x.* = .{};
    }
    if (sc.surface) |p| c.wrapper_destroy(p);
    sc.surface = null;
    sc.display.deinit();
    sc.live = false;
}

fn destroySwapchain(_: ?*anyopaque, h: u64, _: ?*const anyopaque) callconv(.c) void {
    lock();
    defer unlock();
    const sc = scOf(h) orelse return;
    const g = theGpu() orelse return;
    dropSwapchain(g, sc);
}

fn getSwapchainImages(_: ?*anyopaque, h: u64, count: ?*u32, out: ?[*]u64) callconv(.c) Result {
    lock();
    defer unlock();
    const sc = scOf(h) orelse return R.error_initialization_failed;
    var list: [MAX_SC_IMAGES]u64 = undefined;
    for (sc.imgs[0..sc.n], 0..) |x, i| list[i] = handle(.image, x.image);
    return enumerate(u64, list[0..sc.n], count, out);
}

/// An image of `sc` the compositor and the app do not hold, waiting for a
/// release up to `timeout` (with the lock let go while it waits).
fn acquireImage(sc_h: u64, timeout: u64, sem: u64, fence: u64, out: ?*u32) Result {
    var sc = scOf(sc_h) orelse return R.error_initialization_failed;
    if (sc.retired) return R.error_out_of_date_khr;
    const c = sc.display.c;
    _ = c.dispatch_pending(sc.display.native, sc.display.queue.?);
    while (true) {
        for (sc.imgs[0..sc.n], 0..) |*x, i| {
            if (x.busy or x.acquired) continue;
            x.acquired = true;
            if (semOf(sem)) |s| s.signaled = true;
            if (fenceOf(fence)) |f| {
                f.signaled = true;
                f.pending = 0;
            }
            (out orelse return R.error_initialization_failed).* = @intCast(i);
            return R.success;
        }
        if (timeout == 0) return R.not_ready;
        const native = sc.display.native;
        const q = sc.display.queue.?;
        unlock();
        const r = c.dispatch_queue(native, q);
        lock();
        sc = scOf(sc_h) orelse return R.error_out_of_date_khr;
        if (r < 0) return R.error_surface_lost_khr;
    }
}

fn acquireNextImage(_: ?*anyopaque, h: u64, timeout: u64, sem: u64, fence: u64, out: ?*u32) callconv(.c) Result {
    lock();
    defer unlock();
    return acquireImage(h, timeout, sem, fence, out);
}

fn acquireNextImage2(_: ?*anyopaque, info: ?*const abi.AcquireNextImageInfoKHR, out: ?*u32) callconv(.c) Result {
    const ai = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    return acquireImage(ai.swapchain, ai.timeout, ai.semaphore, ai.fence, out);
}

/// Image `idx` of the swapchain `sc_h` to the compositor.
fn presentOne(sc_h: u64, idx: u32) Result {
    var sc = scOf(sc_h) orelse return R.error_initialization_failed;
    if (idx >= sc.n or !sc.imgs[idx].acquired) return R.error_initialization_failed;
    const c = sc.display.c;
    // (FIFO: one frame on the screen at a time)
    while (sc.fifo and sc.frame_cb != null) {
        const native = sc.display.native;
        const q = sc.display.queue.?;
        unlock();
        const r = c.dispatch_queue(native, q);
        lock();
        sc = scOf(sc_h) orelse return R.error_out_of_date_khr;
        if (r < 0) return R.error_surface_lost_khr;
    }
    const surface = sc.surface orelse return R.error_surface_lost_khr;
    const x = &sc.imgs[idx];
    var none = [_]wl.Arg{.{ .o = null }};
    if (sc.fifo) {
        sc.frame_cb = c.send(surface, WL_SURFACE_FRAME, c.callback_interface, null, 0, &none);
        if (sc.frame_cb) |cb| _ = c.add_dispatcher(cb, &onScFrame, sc, null);
    }
    var at = [_]wl.Arg{ .{ .o = x.buf }, .{ .i = 0 }, .{ .i = 0 } };
    _ = c.send(surface, WL_SURFACE_ATTACH, null, null, 0, &at);
    const op: u32 = if (c.get_version(surface) >= 4) WL_SURFACE_DAMAGE_BUFFER else WL_SURFACE_DAMAGE;
    var all = [_]wl.Arg{ .{ .i = 0 }, .{ .i = 0 }, .{ .i = std.math.maxInt(i32) }, .{ .i = std.math.maxInt(i32) } };
    _ = c.send(surface, op, null, null, 0, &all);
    _ = c.send(surface, WL_SURFACE_COMMIT, null, null, 0, &none);
    _ = c.flush(sc.display.native);
    x.acquired = false;
    x.busy = true;
    sc.presents += 1;
    return if (sc.retired) SUBOPTIMAL else R.success;
}

fn queuePresent(q: ?*anyopaque, info: ?*const abi.PresentInfoKHR) callconv(.c) Result {
    const pi = info orelse return R.error_initialization_failed;
    lock();
    defer unlock();
    const di = queueDev(q) orelse return R.error_initialization_failed;
    if (T.devices[di].lost) return R.error_device_lost;
    // (the queue runs in order: what signaled these was submitted before)
    for (0..pi.waitSemaphoreCount) |i| {
        if (semOf(pi.pWaitSemaphores.?[i])) |s| s.signaled = false;
    }
    var worst: Result = R.success;
    for (0..pi.swapchainCount) |k| {
        const r = presentOne(pi.pSwapchains.?[k], pi.pImageIndices.?[k]);
        if (pi.pResults) |rs| rs[k] = r;
        if (r < 0 and (worst >= 0 or r < worst)) worst = r else if (r > 0 and worst == R.success) worst = r;
    }
    return worst;
}

fn onScBuffer(impl: ?*const anyopaque, target: ?*anyopaque, opcode: u32, msg: ?*const wl.Message, args: [*]wl.Arg) callconv(.c) c_int {
    _ = .{ target, msg, args };
    if (opcode != 0) return 0; // release
    const x: *ScImage = @ptrCast(@alignCast(@constCast(impl.?)));
    x.busy = false;
    return 0;
}

fn onScFrame(impl: ?*const anyopaque, target: ?*anyopaque, opcode: u32, msg: ?*const wl.Message, args: [*]wl.Arg) callconv(.c) c_int {
    _ = .{ msg, args };
    if (opcode != 0) return 0; // done
    const sc: *Swapchain = @ptrCast(@alignCast(@constCast(impl.?)));
    if (target) |t| sc.display.c.destroy(@ptrCast(t));
    if (sc.frame_cb == @as(?*wl.Proxy, @ptrCast(target))) sc.frame_cb = null;
    return 0;
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
    entry("vkCreateImage", &createImage, .device),
    entry("vkDestroyImage", &destroyImage, .device),
    entry("vkGetImageMemoryRequirements", &getImageMemoryRequirements, .device),
    entry("vkGetImageMemoryRequirements2", &getImageMemoryRequirements2, .device),
    entry("vkGetImageMemoryRequirements2KHR", &getImageMemoryRequirements2, .device),
    entry("vkGetImageSparseMemoryRequirements", &getImageSparseMemoryRequirements, .device),
    entry("vkGetImageSparseMemoryRequirements2", &getImageSparseMemoryRequirements2, .device),
    entry("vkGetImageSparseMemoryRequirements2KHR", &getImageSparseMemoryRequirements2, .device),
    entry("vkBindImageMemory", &bindImageMemory, .device),
    entry("vkBindImageMemory2", &bindImageMemory2, .device),
    entry("vkBindImageMemory2KHR", &bindImageMemory2, .device),
    entry("vkGetImageSubresourceLayout", &getImageSubresourceLayout, .device),
    entry("vkCreateImageView", &createImageView, .device),
    entry("vkDestroyImageView", &destroyImageView, .device),
    entry("vkCreateSampler", &createSampler, .device),
    entry("vkDestroySampler", &destroySampler, .device),
    entry("vkCreateSamplerYcbcrConversion", &createSamplerYcbcrConversion, .device),
    entry("vkDestroySamplerYcbcrConversion", &destroySamplerYcbcrConversion, .device),
    entry("vkCreateRenderPass", &createRenderPass, .device),
    entry("vkDestroyRenderPass", &destroyRenderPass, .device),
    entry("vkGetRenderAreaGranularity", &getRenderAreaGranularity, .device),
    entry("vkCreateFramebuffer", &createFramebuffer, .device),
    entry("vkDestroyFramebuffer", &destroyFramebuffer, .device),
    entry("vkCreateGraphicsPipelines", &createGraphicsPipelines, .device),
    entry("vkCreateDescriptorUpdateTemplate", &createDescriptorUpdateTemplate, .device),
    entry("vkCreateDescriptorUpdateTemplateKHR", &createDescriptorUpdateTemplate, .device),
    entry("vkDestroyDescriptorUpdateTemplate", &destroyDescriptorUpdateTemplate, .device),
    entry("vkDestroyDescriptorUpdateTemplateKHR", &destroyDescriptorUpdateTemplate, .device),
    entry("vkUpdateDescriptorSetWithTemplate", &updateDescriptorSetWithTemplate, .device),
    entry("vkUpdateDescriptorSetWithTemplateKHR", &updateDescriptorSetWithTemplate, .device),
    entry("vkGetDeviceGroupPeerMemoryFeatures", &getDeviceGroupPeerMemoryFeatures, .device),
    entry("vkCmdSetDeviceMask", &cmdSetDeviceMask, .device),
    entry("vkCmdBeginRenderPass", &cmdBeginRenderPass, .device),
    entry("vkCmdEndRenderPass", &cmdEndRenderPass, .device),
    entry("vkCmdNextSubpass", &cmdNextSubpass, .device),
    entry("vkCmdBindVertexBuffers", &cmdBindVertexBuffers, .device),
    entry("vkCmdBindIndexBuffer", &cmdBindIndexBuffer, .device),
    entry("vkCmdSetViewport", &cmdSetViewport, .device),
    entry("vkCmdSetScissor", &cmdSetScissor, .device),
    entry("vkCmdSetStencilReference", &cmdSetStencilReference, .device),
    entry("vkCmdSetStencilCompareMask", &cmdSetStencilCompareMask, .device),
    entry("vkCmdSetStencilWriteMask", &cmdSetStencilWriteMask, .device),
    entry("vkCmdSetBlendConstants", &cmdSetBlendConstants, .device),
    entry("vkCmdSetDepthBias", &cmdSetDepthBias, .device),
    entry("vkCmdSetLineWidth", &cmdSetLineWidth, .device),
    entry("vkCmdSetDepthBounds", &cmdSetDepthBounds, .device),
    entry("vkCmdDraw", &cmdDraw, .device),
    entry("vkCmdDrawIndexed", &cmdDrawIndexed, .device),
    entry("vkCmdDrawIndirect", &cmdDrawIndirect, .device),
    entry("vkCmdDrawIndexedIndirect", &cmdDrawIndexedIndirect, .device),
    entry("vkCmdClearAttachments", &cmdClearAttachments, .device),
    entry("vkCmdCopyBufferToImage", &cmdCopyBufferToImage, .device),
    entry("vkCmdCopyImageToBuffer", &cmdCopyImageToBuffer, .device),
    entry("vkCmdCopyImage", &cmdCopyImage, .device),
    entry("vkCmdBlitImage", &cmdBlitImage, .device),
    entry("vkCmdResolveImage", &cmdResolveImage, .device),
    entry("vkCmdClearColorImage", &cmdClearColorImage, .device),
    entry("vkCmdClearDepthStencilImage", &cmdClearDepthStencilImage, .device),
    // external memory, semaphores, fences; DRM format modifiers
    entry("vkGetPhysicalDeviceExternalBufferPropertiesKHR", &getPhysicalDeviceExternalBufferProperties, .physical),
    entry("vkGetPhysicalDeviceExternalFencePropertiesKHR", &getPhysicalDeviceExternalFenceProperties, .physical),
    entry("vkGetPhysicalDeviceExternalSemaphorePropertiesKHR", &getPhysicalDeviceExternalSemaphoreProperties, .physical),
    entry("vkGetMemoryFdKHR", &getMemoryFd, .device),
    entry("vkGetMemoryFdPropertiesKHR", &getMemoryFdProperties, .device),
    entry("vkGetSemaphoreFdKHR", &getSemaphoreFd, .device),
    entry("vkImportSemaphoreFdKHR", &importSemaphoreFd, .device),
    entry("vkGetFenceFdKHR", &getFenceFd, .device),
    entry("vkImportFenceFdKHR", &importFenceFd, .device),
    entry("vkGetImageDrmFormatModifierPropertiesEXT", &getImageDrmFormatModifierProperties, .device),
    // presentation
    entry("vkGetPhysicalDeviceSurfaceSupportKHR", &getPhysicalDeviceSurfaceSupport, .physical),
    entry("vkGetPhysicalDeviceSurfaceCapabilitiesKHR", &getPhysicalDeviceSurfaceCapabilities, .physical),
    entry("vkGetPhysicalDeviceSurfaceFormatsKHR", &getPhysicalDeviceSurfaceFormats, .physical),
    entry("vkGetPhysicalDeviceSurfacePresentModesKHR", &getPhysicalDeviceSurfacePresentModes, .physical),
    entry("vkGetPhysicalDeviceWaylandPresentationSupportKHR", &getPhysicalDeviceWaylandPresentationSupport, .physical),
    entry("vkGetPhysicalDevicePresentRectanglesKHR", &getPhysicalDevicePresentRectangles, .physical),
    entry("vkGetDeviceGroupPresentCapabilitiesKHR", &getDeviceGroupPresentCapabilities, .device),
    entry("vkGetDeviceGroupSurfacePresentModesKHR", &getDeviceGroupSurfacePresentModes, .device),
    entry("vkCreateSwapchainKHR", &createSwapchain, .device),
    entry("vkDestroySwapchainKHR", &destroySwapchain, .device),
    entry("vkGetSwapchainImagesKHR", &getSwapchainImages, .device),
    entry("vkAcquireNextImageKHR", &acquireNextImage, .device),
    entry("vkAcquireNextImage2KHR", &acquireNextImage2, .device),
    entry("vkQueuePresentKHR", &queuePresent, .device),
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
