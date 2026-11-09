//! @zpm/gfxapi node — a program's GPU on Galaxy: the 'G' calls of
//! /dev/dri/renderD128 (Galaxy's galaxy_gpu_drm.sig on the Surface's
//! Adreno, nv_drm.sig on the PC's RTX), as zpm's raw devices and then as a
//! gpu.Device. Galaxy's galaxy-think made these calls first (its
//! think_gpu.sig); this is the same client in zpm, for any program,
//! with what an app's graphics driver needs besides:
//!
//! - **Zero-copy import** (G_IMPORT): memory the program has (a texture's
//!   pixels, a mapped file) read by the GPU where it is. Read only for the
//!   GPU: a GPU write to a pinned page would skip copy on write.
//! - **PRIME export**: a buffer as a dma-buf fd (DRM_IOCTL_PRIME_HANDLE_TO_FD
//!   on the buffer's handle), for a window's frames to go to the
//!   compositor through zwp_linux_dmabuf_v1, zero-copy.
//! - **PRIME import**: a dma-buf fd (another program's buffer, an
//!   EGLImage's) as a buffer of this context: PRIME_FD_TO_HANDLE, then
//!   MSM_GEM_INFO for its GPU address and its mmap offset. The kernel
//!   answers an import of this context's own buffer, or of one imported
//!   before, with the same handle: such an entry is counted, not doubled.
//! - **Fence files** (G_FENCE_FD): a sync_file of the last submission, for
//!   EGL_ANDROID_native_fence_sync.
//!
//! The open file is the program's own GPU context (its own page table).
//! G_INFO's chip says which GPU answered; each GPU's raw Device is a view
//! of the same calls, buffers, submissions and loss.
//!
//! Buffers are the kernel's, mapped with mmap at their offset. One larger
//! than a piece (64 MiB) is made of pieces at consecutive GPU addresses (a
//! span G_RESERVE gave) and consecutive addresses here. The Adreno's are
//! cached for the CPU, kept in step from here as Mesa does on Linux:
//! toDevice cleans the lines (DC CVAC), fromDevice cleans and invalidates
//! them (DC CIVAC). The RTX's come in 2 MiB units, in VRAM (G_VRAM,
//! write-combined through BAR1) or system memory the GPU maps; PCIe snoops,
//! so toDevice only drains the write-combining buffers.
//!
//! A wait that times out leaves the work running; EIO means the GPU hung or
//! faulted: it is lost until reboot, every later call fails, and the
//! caller goes on with the CPU.
//!
//! `Node(Sys)`: `Sys` makes the calls (`Linux` here; `Fake`, below, is
//! Galaxy's kernel over zpm's emulated Adreno, for tests).
//!
//! Allocation-free: fixed tables (MAX_BUFFERS entries, MAX_PIECES each).

const std = @import("std");
const report = @import("report.sig");
const builtin = @import("builtin");
const linux = std.os.linux;
const gpu = @import("gpu");
const adreno = @import("adreno");
const nvidia = @import("nvidia");

const Buffer = adreno.device.Buffer;
const Device = adreno.device.Device;
const DeviceError = adreno.device.Error;
const Fence = adreno.device.Fence;
const NvBuffer = nvidia.device.Buffer;
const NvDevice = nvidia.device.Device;
const NvError = nvidia.device.Error;
const NvFence = nvidia.device.Fence;

pub const NODE = "/dev/dri/renderD128";
/// galaxy_gpu (nv_gpu on the PC) writes it once the GPU runs (and removes
/// it after a hang).
pub const READY = "/run/galaxy/gpu-ready";

// Galaxy's calls (galaxy_gpu_drm.sig, nv_drm.sig): Linux's _IOR/_IOW/_IOWR('G', nr, size).
pub const G_INFO: u32 = 0x8020_4700;
pub const G_RESERVE: u32 = 0xc010_4701;
pub const G_ALLOC: u32 = 0xc020_4702;
pub const G_FREE: u32 = 0x4004_4703;
pub const G_UNRESERVE: u32 = 0x4008_4708;
pub const G_BUFFER_INFO: u32 = 0xc020_4709;
pub const G_SUBMIT: u32 = 0xc010_4704;
pub const G_WAIT: u32 = 0x4010_4705;
pub const G_IMPORT: u32 = 0xc020_4706;
pub const G_FENCE_FD: u32 = 0xc008_4707;
pub const G_VERSION: u32 = 1;
/// G_ALLOC's flags: write-combined for the CPU (the Adreno's); in VRAM
/// (the RTX's; without it, system memory the GPU maps).
pub const G_WC: u32 = 1;
pub const G_VRAM: u32 = 2;
/// DRM's PRIME export (struct drm_prime_handle: u32 handle, u32 flags,
/// s32 fd), and its flags: DRM_CLOEXEC, DRM_RDWR.
pub const PRIME_HANDLE_TO_FD: u32 = 0xc00c_642d;
pub const DRM_CLOEXEC: u32 = 0o2000000;
pub const DRM_RDWR: u32 = 2;
pub const PRIME_FD_TO_HANDLE: u32 = 0xc00c_642e;
/// msm's struct drm_msm_gem_info {u32 handle, u32 info, u64 value, u32
/// len, u32 pad}; info 0: the mmap offset, 1: the GPU address (given now
/// if it has none).
pub const MSM_GEM_INFO: u32 = 0xc018_6443;

pub const CHIP_X1_45: u32 = 0x4303_0c00;
/// The RTX 5070 Laptop GPU's (nv_dev.CHIP_GB206): NVIDIA's PCI vendor id
/// over nouveau's chipset number, GB206 (sm_120).
pub const CHIP_GB206: u32 = 0x10de_01b6;

/// The GPUs this client knows.
pub const Kind = enum { adreno, nvidia };

/// Which GPU G_INFO's chip is, if it is one this client knows.
pub fn kindOf(chip: u32) ?Kind {
    return switch (chip) {
        CHIP_X1_45 => .adreno,
        CHIP_GB206 => .nvidia,
        else => null,
    };
}

/// Where an RTX buffer lives (see the top).
pub const Where = enum { vram, system };

const EINTR = 4;
const EIO = 5;
const ENODEV = 19;
const EINVAL = 22;
const ETIMEDOUT = 110;

const PAGE: usize = 4096;
/// nv_drm's buffers come in whole 2 MiB pages, at 2 MiB-aligned addresses.
pub const NV_UNIT: usize = 2 << 20;
pub const PIECE: usize = 64 << 20;
pub const MAX_BUFFERS = 256;
/// Pieces of one buffer (up to 4 GiB).
pub const MAX_PIECES = 64;

pub const Info = struct {
    version: u32,
    chip: u32,
    /// GPU faults and hangs since boot.
    faults: u32,
    lost: bool,
    /// The GPU's own counter: the Adreno's always-on one (19.2 MHz), the
    /// RTX's PTIMER (ns).
    timestamp: u64,
    clock_hz: u32,
    /// VRAM Galaxy has of the GPU (0 on the Adreno, which has none).
    vram_mib: u32,
};

pub fn Node(comptime Sys: type) type {
    return struct {
        const Self = @This();

        sys: Sys,
        fd: i32 = -1,
        /// The GPU hung or went away: nothing more is asked of it.
        lost: bool = false,
        /// Which GPU answered (open: G_INFO's chip).
        kind: Kind = .adreno,
        dma_import: bool = false,
        /// What the kernel's buffers come in: 4 KiB pages on the Adreno,
        /// 2 MiB on the RTX.
        unit: usize = PAGE,
        /// The size pieces are made in (a test makes it small; rounded up
        /// to whole units).
        piece: usize = PIECE,
        line: usize = 64,
        /// the fence of the last submission (0: none yet)
        last_seq: u32 = 0,
        buffers: [MAX_BUFFERS]Entry = [_]Entry{.{}} ** MAX_BUFFERS,

        const Entry = struct {
            used: bool = false,
            /// names held (an import of the same kernel buffer again)
            refs: u32 = 1,
            va: u64 = 0,
            reserved: bool = false,
            cpu: usize = 0,
            /// Bytes mapped here (every piece, rounded to whole units; 0
            /// for an import, which is the program's own memory).
            len: usize = 0,
            /// The first piece's size (a command stream must lie in it).
            first: usize = 0,
            n: usize = 0,
            handles: [MAX_PIECES]u32 = undefined,
        };

        pub const OpenError = error{ NoGpu, Unsupported };

        /// The GPU, if Galaxy has one running and it is one this client
        /// knows (otherwise the caller goes on with the CPU). `kind` says
        /// which Device to use.
        pub fn open(g: *Self) OpenError!Info {
            const fd = g.sys.open(NODE);
            if (fd < 0) return error.NoGpu;
            g.fd = @intCast(fd);
            g.lost = false;
            const i = g.info() orelse {
                g.close();
                return error.NoGpu;
            };
            const kind = kindOf(i.chip);
            if (i.version != G_VERSION or kind == null or i.lost) {
                g.close();
                return error.Unsupported;
            }
            g.kind = kind.?;
            var probe = [_]u8{0} ** 32;
            g.dma_import = g.kind == .adreno or g.call(G_BUFFER_INFO, &probe) == 0;
            g.unit = if (g.kind == .nvidia) NV_UNIT else PAGE;
            g.line = g.sys.cacheLine();
            return i;
        }

        pub fn info(g: *Self) ?Info {
            var a = [_]u8{0} ** 32;
            if (g.call(G_INFO, &a) != 0) return null;
            return .{
                .version = rd32(&a, 0),
                .chip = rd32(&a, 4),
                .faults = rd32(&a, 8),
                .lost = rd32(&a, 12) != 0,
                .timestamp = rd64(&a, 16),
                .clock_hz = rd32(&a, 24),
                .vram_mib = rd32(&a, 28),
            };
        }

        /// Every buffer and the node go (the kernel frees the pages once the
        /// GPU is done with them).
        pub fn close(g: *Self) void {
            for (&g.buffers) |*e| {
                if (e.used) g.release(e);
            }
            if (g.fd >= 0) g.sys.close(g.fd);
            g.fd = -1;
        }

        /// The Adreno's raw Device (an RTX gives it no memory).
        pub fn device(g: *Self) Device {
            return .{ .ctx = g, .vtable = &vtable };
        }

        /// The RTX's raw Device, its buffers `where` (an Adreno gives it no
        /// memory). Both views share the buffers, the submissions and the
        /// loss.
        pub fn nvDevice(g: *Self, where: Where) NvDevice {
            return .{
                .ctx = g,
                .vtable = switch (where) {
                    .vram => &nv_vram_vtable,
                    .system => &nv_system_vtable,
                },
                .timestamp_hz = nvidia.push.TIMESTAMP_HZ,
            };
        }

        /// Zero-copy import for gpu.adreno_device.Over (G_IMPORT).
        pub fn importer(g: *Self) gpu.adreno_device.Importer {
            return .{ .ctx = g, .import = importCall, .release = releaseCall };
        }

        /// The buffer `handle` (a raw Device's) as a dma-buf fd, or -errno.
        /// A buffer of several pieces has no one dma-buf (EINVAL).
        pub fn exportFd(g: *Self, handle: u32) i64 {
            const e = g.entryOf(handle) orelse return -EINVAL;
            if (e.n != 1 or e.len == 0) return -EINVAL;
            var a = [_]u8{0} ** 12;
            wr32(&a, 0, e.handles[0]);
            wr32(&a, 4, DRM_CLOEXEC | DRM_RDWR);
            const r = g.call(PRIME_HANDLE_TO_FD, &a);
            if (r != 0) return r;
            return @as(i32, @bitCast(rd32(&a, 8)));
        }

        const vtable = Device.VTable{
            .alloc = alloc,
            .free = free,
            .submit = submit,
            .wait = wait,
            .toDevice = toDevice,
            .fromDevice = fromDevice,
        };

        const nv_vram_vtable = NvDevice.VTable{
            .alloc = nvAllocVram,
            .free = nvFree,
            .submit = nvSubmit,
            .wait = nvWait,
            .toDevice = nvToDevice,
            .fromDevice = nvFromDevice,
        };

        const nv_system_vtable = NvDevice.VTable{
            .alloc = nvAllocSystem,
            .free = nvFree,
            .submit = nvSubmit,
            .wait = nvWait,
            .toDevice = nvToDevice,
            .fromDevice = nvFromDevice,
        };

        fn of(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }

        // ── The calls, for either GPU ───────────────────────────────────

        /// A call: 0 or -errno. EIO (a hang) or ENODEV (no GPU any more):
        /// lost from now on.
        fn call(g: *Self, req: u32, a: []u8) i64 {
            if (g.fd < 0) return -ENODEV;
            const r = g.sys.ioctl(g.fd, req, a);
            if (r == -EIO or r == -ENODEV) g.lost = true;
            return r;
        }

        const Piece = struct { handle: u32, va: u64, off: u64 };

        /// A buffer of the kernel's: at GPU address `at` (0: one given).
        fn newPiece(g: *Self, size: usize, at: u64, flags: u32) ?Piece {
            var a = [_]u8{0} ** 32;
            wr64(&a, 0, size);
            wr32(&a, 8, flags);
            wr64(&a, 16, at);
            const result = g.call(G_ALLOC, &a);
            if (result != 0) {
                report.say(.egl_error, "render-node allocation of {d} bytes failed: {d}", .{ size, result });
                return null;
            }
            return .{ .handle = rd32(&a, 12), .va = rd64(&a, 16), .off = rd64(&a, 24) };
        }

        fn freeHandle(g: *Self, h: u32) void {
            var a = [_]u8{0} ** 4;
            wr32(&a, 0, h);
            _ = g.call(G_FREE, &a);
        }

        fn release(g: *Self, e: *Entry) void {
            if (e.len != 0) g.sys.unmap(e.cpu, e.len);
            for (e.handles[0..e.n]) |h| g.freeHandle(h);
            if (e.reserved and g.kind == .nvidia) {
                var a: [8]u8 = undefined;
                wr64(&a, 0, e.va);
                _ = g.call(G_UNRESERVE, &a);
            }
            e.* = .{};
        }

        fn freeEntry(g: *Self) ?usize {
            for (&g.buffers, 0..) |*e, i| {
                if (!e.used) return i;
            }
            return null;
        }

        /// What allocIn made, for either GPU's Buffer.
        const Made = struct { va: u64, cpu: []u8, handle: u32 };

        /// A buffer of `size` bytes with G_ALLOC's `flags`, in pieces when
        /// it is larger than one.
        fn allocIn(g: *Self, size: usize, flags: u32) ?Made {
            // (whole units: the RTX's pieces must start on 2 MiB)
            const piece = std.mem.alignForward(usize, @max(g.piece, g.unit), g.unit);
            if (g.fd < 0 or g.lost or size == 0 or size > MAX_PIECES * piece) return null;
            const idx = g.freeEntry() orelse {
                report.say(.egl_error, "render-node buffer table is full allocating {d} bytes", .{size});
                return null;
            };
            const e = &g.buffers[idx];
            // (asked of the kernel in pages, which it rounds up to its
            // units; mapped, and laid out, in its units)
            const need = std.mem.alignForward(usize, size, PAGE);
            const len = std.mem.alignForward(usize, size, g.unit);
            e.* = .{ .used = true, .first = @min(len, piece) };
            if (len <= piece) {
                const p = g.newPiece(need, 0, flags) orelse return g.undo(e);
                e.handles[0] = p.handle;
                e.n = 1;
                e.va = p.va;
                const at = g.sys.mapBuffer(g.fd, 0, len, p.off);
                if (at < 0) {
                    report.say(.egl_error, "render-node mmap of {d} bytes failed: {d}", .{ len, at });
                    return g.undo(e);
                }
                e.cpu = @intCast(at);
                e.len = len;
            } else {
                const n = (len + piece - 1) / piece;
                var r = [_]u8{0} ** 16;
                wr64(&r, 0, len);
                if (g.call(G_RESERVE, &r) != 0) return g.undo(e);
                e.va = rd64(&r, 8);
                e.reserved = true;
                const span = g.sys.reserve(len);
                if (span < 0) return g.undo(e);
                e.cpu = @intCast(span);
                e.len = len;
                for (0..n) |k| {
                    const part = @min(piece, len - k * piece);
                    const p = g.newPiece(@min(piece, need - k * piece), e.va + k * piece, flags) orelse return g.undo(e);
                    e.handles[k] = p.handle;
                    e.n = k + 1;
                    const want = e.cpu + k * piece;
                    if (g.sys.mapBuffer(g.fd, want, part, p.off) != @as(i64, @intCast(want))) return g.undo(e);
                }
            }
            return .{ .va = e.va, .cpu = @as([*]u8, @ptrFromInt(e.cpu))[0..size], .handle = @intCast(idx + 1) };
        }

        fn undo(g: *Self, e: *Entry) ?Made {
            g.release(e);
            return null;
        }

        fn entryOf(g: *Self, handle: u32) ?*Entry {
            if (handle == 0 or handle > MAX_BUFFERS) return null;
            const e = &g.buffers[handle - 1];
            return if (e.used) e else null;
        }

        fn freeIn(g: *Self, handle: u32) void {
            const e = g.entryOf(handle) orelse return;
            e.refs -= 1;
            if (e.refs == 0) g.release(e);
        }

        /// A dma-buf of `size` bytes (its fd stays the caller's) as a
        /// buffer of this context: its GPU address, mapped here; null when
        /// the kernel refuses it.
        pub fn importFd(g: *Self, fd: i32) ?Buffer {
            if (g.fd < 0 or g.lost or !g.dma_import) return null;
            const size_i = g.sys.fdSize(fd);
            if (size_i <= 0) return null;
            const size: usize = @intCast(size_i);
            var a = [_]u8{0} ** 12;
            wr32(&a, 8, @bitCast(fd));
            if (g.call(PRIME_FD_TO_HANDLE, &a) != 0) return null;
            const kh = rd32(&a, 0);
            // (the same kernel buffer named already: one entry, counted)
            for (&g.buffers, 0..) |*e, i| {
                if (e.used and e.n == 1 and e.handles[0] == kh) {
                    e.refs += 1;
                    return .{ .va = e.va, .cpu = @as([*]u8, @ptrFromInt(e.cpu))[0..@min(size, e.len)], .handle = @intCast(i + 1) };
                }
            }
            const idx = g.freeEntry() orelse return g.dropHandle(kh);
            if (g.kind == .nvidia) {
                var info_buf = [_]u8{0} ** 32;
                wr32(&info_buf, 0, kh);
                if (g.call(G_BUFFER_INFO, &info_buf) != 0) return g.dropHandle(kh);
                const len = std.math.cast(usize, rd64(&info_buf, 24)) orelse return g.dropHandle(kh);
                if (len < size or len % g.unit != 0) return g.dropHandle(kh);
                return g.mapImported(idx, kh, rd64(&info_buf, 8), rd64(&info_buf, 16), len, size);
            }
            var gi = [_]u8{0} ** 24;
            wr32(&gi, 0, kh);
            wr32(&gi, 4, 1); // MSM_INFO_GET_IOVA
            if (g.call(MSM_GEM_INFO, &gi) != 0) return g.dropHandle(kh);
            const va = rd64(&gi, 8);
            wr32(&gi, 4, 0); // MSM_INFO_GET_OFFSET
            if (g.call(MSM_GEM_INFO, &gi) != 0) return g.dropHandle(kh);
            const len = std.mem.alignForward(usize, size, PAGE);
            return g.mapImported(idx, kh, va, rd64(&gi, 8), len, size);
        }

        fn mapImported(g: *Self, idx: usize, kh: u32, va: u64, off: u64, len: usize, size: usize) ?Buffer {
            const at = g.sys.mapBuffer(g.fd, 0, len, off);
            if (at < 0) return g.dropHandle(kh);
            const e = &g.buffers[idx];
            e.* = .{ .used = true, .va = va, .cpu = @intCast(at), .len = len, .first = len, .n = 1 };
            e.handles[0] = kh;
            return .{ .va = va, .cpu = @as([*]u8, @ptrFromInt(e.cpu))[0..size], .handle = @intCast(idx + 1) };
        }

        fn dropHandle(g: *Self, kh: u32) ?Buffer {
            g.freeHandle(kh);
            return null;
        }

        /// A sync_file of the last submission (of any of this process's
        /// GPU work: one in-order ring), or -errno.
        pub fn fenceFd(g: *Self) i64 {
            var a = [_]u8{0} ** 8;
            wr32(&a, 0, g.last_seq);
            const r = g.call(G_FENCE_FD, &a);
            if (r != 0) return r;
            return @as(i32, @bitCast(rd32(&a, 4)));
        }

        /// `dwords` of command stream at `va`, in the buffer `handle` (its
        /// first piece): the fence.
        fn submitIn(g: *Self, handle: u32, va: u64, dwords: u32) DeviceError!u64 {
            if (g.lost) return error.DeviceLost;
            const e = g.entryOf(handle) orelse return error.BadStream;
            if (e.len == 0 or va < e.va or va - e.va + @as(u64, dwords) * 4 > e.first) return error.BadStream;
            var a = [_]u8{0} ** 16;
            wr32(&a, 0, e.handles[0]);
            wr32(&a, 4, @intCast(va - e.va));
            wr32(&a, 8, dwords);
            if (g.call(G_SUBMIT, &a) != 0) return if (g.lost) error.DeviceLost else error.SubmitFailed;
            g.last_seq = rd32(&a, 12);
            return g.last_seq;
        }

        fn waitFor(g: *Self, f: u64, timeout_us: u64) DeviceError!void {
            if (g.lost) return error.DeviceLost;
            const now = g.sys.nowNs();
            const room: u64 = @intCast(@divTrunc(std.math.maxInt(i64) - now, 1000));
            var a = [_]u8{0} ** 16;
            wr32(&a, 0, @truncate(f));
            // (an absolute deadline: the kernel's sleeps do not stretch it)
            wr64(&a, 8, @bitCast(if (timeout_us >= room) std.math.maxInt(i64) else now + @as(i64, @intCast(timeout_us)) * 1000));
            while (true) {
                const r = g.call(G_WAIT, &a);
                if (r == 0) return;
                if (r == -EINTR) continue;
                if (r == -ETIMEDOUT) return error.Timeout;
                return error.DeviceLost;
            }
        }

        // ── Zero-copy import (the Adreno) ───────────────────────────────

        /// `cpu` mapped for the GPU in place (its whole pages), read only:
        /// a raw Buffer whose .va is cpu[0]'s GPU address.
        fn importIn(g: *Self, cpu: []u8) ?Buffer {
            if (g.fd < 0 or g.lost or cpu.len == 0 or g.kind != .adreno) return null;
            const idx = g.freeEntry() orelse return null;
            const at = @intFromPtr(cpu.ptr);
            const start = at & ~(PAGE - 1);
            const size = std.mem.alignForward(usize, at + cpu.len, PAGE) - start;
            var a = [_]u8{0} ** 32;
            wr64(&a, 0, size);
            wr64(&a, 24, start);
            if (g.call(G_IMPORT, &a) != 0) return null;
            const e = &g.buffers[idx];
            e.* = .{ .used = true, .va = rd64(&a, 16), .n = 1 };
            e.handles[0] = rd32(&a, 12);
            return .{ .va = e.va + (at - start), .cpu = cpu, .handle = @intCast(idx + 1) };
        }

        fn importCall(ctx: *anyopaque, cpu: []u8, writable: bool) ?Buffer {
            // (a GPU write to a pinned page skips copy on write: never)
            if (writable) return null;
            return of(ctx).importIn(cpu);
        }

        fn releaseCall(ctx: *anyopaque, handle: u32) void {
            of(ctx).freeIn(handle);
        }

        // ── The Adreno's Device ─────────────────────────────────────────

        fn alloc(ctx: *anyopaque, size: usize) ?Buffer {
            const g = of(ctx);
            if (g.kind != .adreno) return null;
            const m = g.allocIn(size, 0) orelse return null;
            return .{ .va = m.va, .cpu = m.cpu, .handle = m.handle };
        }

        fn free(ctx: *anyopaque, b: Buffer) void {
            of(ctx).freeIn(b.handle);
        }

        fn submit(ctx: *anyopaque, ib: Buffer, dwords: u32) DeviceError!Fence {
            return of(ctx).submitIn(ib.handle, ib.va, dwords);
        }

        fn wait(ctx: *anyopaque, f: Fence, timeout_us: u64) DeviceError!void {
            return of(ctx).waitFor(f, timeout_us);
        }

        fn toDevice(ctx: *anyopaque, b: Buffer, off: usize, len: usize) void {
            const g = of(ctx);
            g.sys.clean(@intFromPtr(b.cpu.ptr) + off, len, g.line);
        }

        fn fromDevice(ctx: *anyopaque, b: Buffer, off: usize, len: usize) void {
            const g = of(ctx);
            g.sys.flush(@intFromPtr(b.cpu.ptr) + off, len, g.line);
        }

        // ── The RTX's Device ────────────────────────────────────────────

        fn nvAlloc(g: *Self, size: usize, flags: u32) ?NvBuffer {
            if (g.kind != .nvidia) return null;
            const m = g.allocIn(size, flags) orelse return null;
            return .{ .va = m.va, .cpu = m.cpu, .handle = m.handle };
        }

        fn nvAllocVram(ctx: *anyopaque, size: usize) ?NvBuffer {
            return of(ctx).nvAlloc(size, G_VRAM);
        }

        fn nvAllocSystem(ctx: *anyopaque, size: usize) ?NvBuffer {
            return of(ctx).nvAlloc(size, 0);
        }

        fn nvFree(ctx: *anyopaque, b: NvBuffer) void {
            of(ctx).freeIn(b.handle);
        }

        fn nvSubmit(ctx: *anyopaque, pb: NvBuffer, dwords: u32) NvError!NvFence {
            const g = of(ctx);
            // (nv_drm refuses an empty pushbuffer)
            if (dwords == 0) return error.BadStream;
            // The CPU's writes through BAR1 drained before the kernel's
            // doorbell starts the work, whether or not toDevice was called.
            storeFence();
            return g.submitIn(pb.handle, pb.va, dwords);
        }

        fn nvWait(ctx: *anyopaque, f: NvFence, timeout_us: u64) NvError!void {
            return of(ctx).waitFor(f, timeout_us);
        }

        fn nvToDevice(ctx: *anyopaque, b: NvBuffer, off: usize, len: usize) void {
            const g = of(ctx);
            g.sys.clean(@intFromPtr(b.cpu.ptr) + off, len, g.line);
        }

        fn nvFromDevice(ctx: *anyopaque, b: NvBuffer, off: usize, len: usize) void {
            const g = of(ctx);
            g.sys.flush(@intFromPtr(b.cpu.ptr) + off, len, g.line);
        }
    };
}

fn has(comptime targets: []const gpu.Target, comptime t: gpu.Target) bool {
    for (targets) |x| {
        if (x == t) return true;
    }
    return false;
}

/// The program's GPU as a gpu.Device, whichever it is, with only the
/// backends `targets` names linked (the Surface's image: ir3; the PC's:
/// sm_120). The adapters' state is here: a Gpu stays where it is made.
pub fn Gpu(comptime Sys: type, comptime targets: []const gpu.Target) type {
    const with_ir3 = has(targets, .ir3_a7xx);
    const with_nv = has(targets, .sm_120);
    return struct {
        const Self = @This();

        node: Node(Sys),
        over: gpu.adreno_device.Over = undefined,
        nv: if (with_nv) gpu.nvidia_device.Adapter else void = if (with_nv) .{} else {},

        pub const Error = Node(Sys).OpenError;

        /// The GPU (Galaxy's), as a Device: error.NoGpu without one,
        /// error.Unsupported for one whose backend this image lacks.
        pub fn open(g: *Self) Error!gpu.Device {
            const info = try g.node.open();
            switch (g.node.kind) {
                .adreno => if (with_ir3) {
                    g.over = gpu.adreno_device.Over.initWith(g.node.device(), gpu.adreno_device.x1_45_caps(@as(u64, 8) << 30), g.node.importer());
                    return g.over.device();
                },
                .nvidia => if (with_nv) {
                    return gpu.nvidia_device.over(&g.nv, g.node.nvDevice(.vram), g.node.nvDevice(.system), gpu.nvidia_device.rtx5070(@as(u64, info.vram_mib) << 20));
                },
            }
            g.node.close();
            return error.Unsupported;
        }

        /// The engine's compiler for this image (only `targets` linked).
        pub fn compile(k: *const gpu.kir.Kernel, caps: gpu.Caps, work: *gpu.Work, out: []u8) anyerror!gpu.Binary {
            return gpu.compileFor(targets, k, caps, work, out);
        }

        /// A gpu.Buffer of this GPU as a dma-buf fd (a window's frame), or
        /// -errno. The RTX's buffers carry nvidia_device's slot as their
        /// handle: the node knows them by the raw device's (legion43: the
        /// slot exported another buffer, "dma-buf smaller than its
        /// picture").
        pub fn exportFd(g: *Self, b: gpu.Buffer) i64 {
            if (with_nv and g.node.kind == .nvidia) {
                const h = g.nv.rawHandle(b) orelse return -EINVAL;
                return g.node.exportFd(h);
            }
            return g.node.exportFd(b.handle);
        }

        /// A dma-buf as a gpu.Buffer of this GPU (freed as any of its
        /// buffers), or null.
        pub fn importFd(g: *Self, fd: i32) ?gpu.Buffer {
            const b = g.node.importFd(fd) orelse return null;
            if (with_nv and g.node.kind == .nvidia) {
                return g.nv.adoptHost(.{ .va = b.va, .cpu = b.cpu, .handle = b.handle }) orelse {
                    g.node.freeIn(b.handle);
                    return null;
                };
            }
            return .{ .gpu = b.va, .cpu = b.cpu, .bytes = b.cpu.len, .handle = b.handle, .kind = .host };
        }

        /// A sync_file of the GPU work so far, or -errno.
        pub fn fenceFd(g: *Self) i64 {
            return g.node.fenceFd();
        }

        pub fn close(g: *Self) void {
            g.node.close();
        }
    };
}

/// Galaxy's Linux calls.
pub const Linux = struct {
    fn result(r: usize) i64 {
        return @as(isize, @bitCast(r));
    }

    pub fn open(_: Linux, path: [*:0]const u8) i64 {
        return result(linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    }

    pub fn close(_: Linux, fd: i32) void {
        _ = linux.close(fd);
    }

    pub fn ioctl(_: Linux, fd: i32, req: u32, arg: []u8) i64 {
        return result(linux.ioctl(fd, req, @intFromPtr(arg.ptr)));
    }

    /// A buffer's pages (its mmap offset), at `at` (0: anywhere).
    pub fn mapBuffer(_: Linux, fd: i32, at: usize, len: usize, off: u64) i64 {
        const addr: ?[*]u8 = if (at != 0) @ptrFromInt(at) else null;
        return result(linux.mmap(addr, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .FIXED = at != 0 }, fd, @bitCast(off)));
    }

    /// Addresses held for a buffer's pieces (nothing behind them).
    pub fn reserve(_: Linux, len: usize) i64 {
        return result(linux.mmap(null, len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0));
    }

    pub fn unmap(_: Linux, at: usize, len: usize) void {
        _ = linux.munmap(@ptrFromInt(at), len);
    }

    /// A file's size (lseek to its end: a dma-buf's), or -errno.
    pub fn fdSize(_: Linux, fd: i32) i64 {
        return result(linux.lseek(fd, 0, linux.SEEK.END));
    }

    /// CLOCK_MONOTONIC by the system call itself: std's clock_gettime
    /// finds the vDSO through the C library's getauxval, which a library
    /// loaded into any program should not need (waits only read the clock
    /// to set a deadline).
    pub fn nowNs(_: Linux) i64 {
        var ts: linux.timespec = undefined;
        _ = linux.syscall2(.clock_gettime, @backingInt(linux.CLOCK.MONOTONIC), @intFromPtr(&ts));
        return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
    }

    /// The smallest data cache line (CTR_EL0.DminLine).
    pub fn cacheLine(_: Linux) usize {
        if (comptime builtin.cpu.arch != .aarch64) return 64;
        const ctr = asm volatile ("mrs %[r], ctr_el0"
            : [r] "=r" (-> u64),
        );
        return @as(usize, 4) << @intCast((ctr >> 16) & 0xf);
    }

    /// The CPU's writes to [at, at+len) for the GPU: the lines cleaned on
    /// AArch64 (the Adreno); on a PC the write-combining buffers drained
    /// (the RTX: PCIe snoops the rest).
    pub fn clean(_: Linux, at: usize, len: usize, line: usize) void {
        if (comptime builtin.cpu.arch == .x86_64) return storeFence();
        cacheOp("cvac", at, len, line);
    }

    /// The GPU's writes to [at, at+len) for the CPU: the lines cleaned and
    /// invalidated on AArch64; nothing on a PC (snooped, or uncached).
    pub fn flush(_: Linux, at: usize, len: usize, line: usize) void {
        cacheOp("civac", at, len, line);
    }
};

/// The CPU's stores before it reach memory before any after it: on x86-64
/// SFENCE drains the write-combining buffers BAR1's VRAM mappings fill,
/// which neither the system call nor the kernel's doorbell write waits for.
pub fn storeFence() void {
    switch (comptime builtin.cpu.arch) {
        .x86_64 => asm volatile ("sfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dsb st" ::: .{ .memory = true }),
        else => {},
    }
}

/// DC `op` on every line of [at, at+len), then a barrier: done for the
/// whole system (the GPU is outside our shareability domain).
fn cacheOp(comptime op: []const u8, at: usize, len: usize, line: usize) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (len == 0) return;
    var p = at & ~(line - 1);
    while (p < at + len) : (p += line) {
        asm volatile ("dc " ++ op ++ ", %[p]"
            :
            : [p] "r" (p),
            : .{ .memory = true });
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
fn rd64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}
fn wr32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}
fn wr64(b: []u8, o: usize, v: u64) void {
    std.mem.writeInt(u64, b[o..][0..8], v, .little);
}

// ── A fake Galaxy kernel over zpm's emulated Adreno (for tests) ─────────────

/// Galaxy's calls as galaxy_gpu_drm answers them, each buffer one of the
/// emulator's (its GPU address the emulator's, its pages in the emulator's
/// memory: the "process" maps them where they are). The emulated GPU's
/// memory is apart from the CPU's, as the Adreno's caches are: what is not
/// cleaned or flushed is not seen. Imports are mapped as the CPU's own
/// bytes; PRIME gives fd 100 + the kernel's handle.
pub const Fake = struct {
    emu: *adreno.device.EmuDevice,
    chip: u32 = CHIP_X1_45,
    present: bool = true,
    hung: bool = false,
    /// Waits run out (the GPU is slow).
    slow: bool = false,
    /// The G_ALLOC that fails (counting from 1; 0: none).
    fail_alloc: u32 = 0,
    allocs: u32 = 0,
    pieces: [256]Buffer = [_]Buffer{.{}} ** 256,
    live: u32 = 0,
    imports: u32 = 0,
    exports: u32 = 0,
    prime_imports: u32 = 0,
    fence_fds: u32 = 0,
    reserved: usize = 0,
    import_va: u64 = 0x80_0000_0000,

    fn next(k: *Fake) usize {
        return std.mem.alignForward(usize, k.emu.used, PAGE);
    }

    pub fn open(k: *Fake, _: [*:0]const u8) i64 {
        return if (k.present) 3 else -2;
    }
    pub fn close(_: *Fake, _: i32) void {}

    pub fn ioctl(k: *Fake, _: i32, req: u32, a: []u8) i64 {
        if (k.hung and req != G_INFO and req != G_FREE) return -EIO;
        switch (req) {
            G_INFO => {
                wr32(a, 0, G_VERSION);
                wr32(a, 4, k.chip);
                wr32(a, 12, @intFromBool(k.hung));
            },
            G_RESERVE => wr64(a, 8, k.emu.va_base + k.next()),
            G_BUFFER_INFO => {
                const handle = rd32(a, 0);
                if (handle == 0) return 0;
                if (handle >= k.pieces.len or k.pieces[handle].va == 0) return -EINVAL;
                const buf = k.pieces[handle];
                wr64(a, 8, buf.va);
                wr64(a, 16, @as(u64, handle) << 32);
                wr64(a, 24, buf.cpu.len);
            },
            G_ALLOC => {
                k.allocs += 1;
                if (k.allocs == k.fail_alloc) return -12;
                const at = rd64(a, 16);
                if (at != 0 and at != k.emu.va_base + k.next()) return -EINVAL;
                const b = k.emu.device().alloc(rd64(a, 0)) catch return -12;
                k.pieces[b.handle] = b;
                k.live += 1;
                wr32(a, 12, b.handle);
                wr64(a, 16, b.va);
                wr64(a, 24, @as(u64, b.handle) << 32);
            },
            G_IMPORT => {
                const size = rd64(a, 0);
                const here = rd64(a, 24);
                if (size == 0 or here % PAGE != 0 or k.emu.n_regions == k.emu.regions.len) return -EINVAL;
                const va = k.import_va;
                k.import_va += std.mem.alignForward(u64, size, PAGE);
                // (the GPU reads the process's own pages)
                k.emu.regions[k.emu.n_regions] = .{ .va = va, .bytes = @as([*]u8, @ptrFromInt(here))[0..size] };
                k.emu.n_regions += 1;
                const h: u32 = @intCast(k.emu.n_regions);
                k.pieces[h] = .{ .va = va, .handle = h };
                k.live += 1;
                k.imports += 1;
                wr32(a, 12, h);
                wr64(a, 16, va);
            },
            G_FREE => {
                const h = rd32(a, 0);
                if (k.pieces[h].va == 0) return -EINVAL;
                k.pieces[h] = .{};
                k.live -= 1;
            },
            G_SUBMIT => {
                const b = k.pieces[rd32(a, 0)];
                if (b.va == 0) return -2;
                const ib = Buffer{ .va = b.va + rd32(a, 4), .handle = b.handle };
                wr32(a, 12, @intCast(k.emu.device().submit(ib, rd32(a, 8)) catch return -EINVAL));
            },
            G_WAIT => {
                if (k.slow) return -ETIMEDOUT;
                k.emu.device().wait(rd32(a, 0), 0) catch return -EINVAL;
            },
            G_FENCE_FD => {
                k.fence_fds += 1;
                wr32(a, 4, 300 + rd32(a, 0));
            },
            PRIME_FD_TO_HANDLE => {
                // (fds 100 + handle: what PRIME_HANDLE_TO_FD gave; the
                // same buffer, as the kernel's own context answers)
                const fd = rd32(a, 8);
                if (fd < 100 or fd - 100 >= k.pieces.len or k.pieces[fd - 100].va == 0) return -EINVAL;
                k.prime_imports += 1;
                wr32(a, 0, fd - 100);
            },
            MSM_GEM_INFO => {
                const h = rd32(a, 0);
                if (h >= k.pieces.len or k.pieces[h].va == 0) return -2;
                switch (rd32(a, 4)) {
                    0 => wr64(a, 8, @as(u64, h) << 32),
                    1 => wr64(a, 8, k.pieces[h].va),
                    else => return -EINVAL,
                }
            },
            PRIME_HANDLE_TO_FD => {
                const h = rd32(a, 0);
                if (h >= k.pieces.len or k.pieces[h].va == 0) return -2;
                if (rd32(a, 4) != DRM_CLOEXEC | DRM_RDWR) return -EINVAL;
                k.exports += 1;
                wr32(a, 8, 100 + h);
            },
            else => return -25,
        }
        return 0;
    }

    pub fn mapBuffer(k: *Fake, _: i32, at: usize, len: usize, off: u64) i64 {
        const b = k.pieces[@intCast(off >> 32)];
        if (b.va == 0 or len > std.mem.alignForward(usize, b.cpu.len, PAGE)) return -EINVAL;
        const here = @intFromPtr(b.cpu.ptr);
        if (at != 0 and at != here) return -EINVAL;
        return @intCast(here);
    }
    pub fn reserve(k: *Fake, len: usize) i64 {
        k.reserved += len;
        return @intCast(@intFromPtr(k.emu.arena.ptr) + k.next());
    }
    pub fn unmap(_: *Fake, _: usize, _: usize) void {}
    pub fn fdSize(k: *Fake, fd: i32) i64 {
        if (fd < 100 or fd - 100 >= k.pieces.len) return -9;
        const b = k.pieces[@intCast(fd - 100)];
        return if (b.va == 0) -9 else @intCast(b.cpu.len);
    }
    pub fn nowNs(_: *Fake) i64 {
        return 1_000_000_000;
    }
    pub fn cacheLine(_: *Fake) usize {
        return 64;
    }
    // (the emulated GPU's memory is apart from ours: cleaning hands our
    // bytes over, flushing fetches the GPU's; an import is ours already)
    pub fn clean(k: *Fake, at: usize, len: usize, _: usize) void {
        if (k.inArena(at, len)) k.emu.cpuToGpu(at, len);
    }
    pub fn flush(k: *Fake, at: usize, len: usize, _: usize) void {
        if (k.inArena(at, len)) k.emu.gpuToCpu(at, len);
    }
    fn inArena(k: *const Fake, at: usize, len: usize) bool {
        const base = @intFromPtr(k.emu.arena.ptr);
        return at >= base and at - base + len <= k.emu.arena.len;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

var test_arena: [8 << 20]u8 align(4096) = undefined;
var test_gpu_view: [8 << 20]u8 align(4096) = undefined;
var test_emu: adreno.device.EmuDevice = undefined;

fn testNode(k: *Fake) Node(*Fake) {
    // (buffers packed, as the fake kernel's G_RESERVE and G_ALLOC at an
    // address assume)
    test_emu = .{ .arena = &test_arena, .gpu_view = &test_gpu_view, .guard = 0 };
    k.* = .{ .emu = &test_emu };
    return .{ .sys = k };
}

test "node: the calls' numbers are galaxy_gpu_drm's and DRM's" {
    // _IOR('G', 0, 32), _IOWR('G', 1, 16), _IOWR('G', 2, 32), _IOW('G', 3, 4),
    // _IOWR('G', 4, 16), _IOW('G', 5, 16), _IOWR('G', 6, 32); _IOWR('d', 0x2d, 12)
    const want = [_]u32{ (2 << 30) | (32 << 16) | 0x4700, (3 << 30) | (16 << 16) | 0x4701, (3 << 30) | (32 << 16) | 0x4702, (1 << 30) | (4 << 16) | 0x4703, (3 << 30) | (16 << 16) | 0x4704, (1 << 30) | (16 << 16) | 0x4705, (3 << 30) | (32 << 16) | 0x4706, (3 << 30) | (12 << 16) | 0x642d };
    try std.testing.expectEqualSlices(u32, &want, &[_]u32{ G_INFO, G_RESERVE, G_ALLOC, G_FREE, G_SUBMIT, G_WAIT, G_IMPORT, PRIME_HANDLE_TO_FD });
    try std.testing.expectEqual(@as(u32, 0x80000), DRM_CLOEXEC);
}

test "node: RTX PRIME import maps a shared buffer and counts repeated imports" {
    var k: Fake = undefined;
    var g = testNode(&k);
    k.chip = CHIP_GB206;
    _ = try g.open();
    defer g.close();
    try std.testing.expect(g.dma_import);
    const external = g.newPiece(NV_UNIT, 0, 0).?;
    const fd: i32 = @intCast(100 + external.handle);
    const first = g.importFd(fd).?;
    const second = g.importFd(fd).?;
    try std.testing.expectEqual(external.va, first.va);
    try std.testing.expectEqual(NV_UNIT, first.cpu.len);
    try std.testing.expectEqual(first.handle, second.handle);
    first.cpu[17] = 42;
    try std.testing.expectEqual(@as(u8, 42), second.cpu[17]);
    g.freeIn(first.handle);
    try std.testing.expectEqual(@as(u32, 1), k.live);
    g.freeIn(second.handle);
    try std.testing.expectEqual(@as(u32, 0), k.live);
}

test "node: buffers, an import, an export, a hang, no GPU" {
    var k: Fake = undefined;
    var g = testNode(&k);
    const i = try g.open();
    try std.testing.expectEqual(CHIP_X1_45, i.chip);
    const d = g.device();
    const b = try d.alloc(5000);
    try std.testing.expectEqual(@as(usize, 5000), b.cpu.len);
    // the CPU's bytes reach the GPU only once cleaned
    b.cpu[0] = 7;
    try std.testing.expectEqual(@as(u8, 0), test_gpu_view[@intFromPtr(b.cpu.ptr) - @intFromPtr(&test_arena)]);
    d.toDevice(b, 0, 1);
    try std.testing.expectEqual(@as(u8, 7), test_gpu_view[@intFromPtr(b.cpu.ptr) - @intFromPtr(&test_arena)]);
    // an export: the buffer's kernel handle as PRIME's
    const fd = g.exportFd(b.handle);
    try std.testing.expectEqual(@as(i64, 100 + g.buffers[b.handle - 1].handles[0]), fd);
    try std.testing.expectEqual(@as(i64, -EINVAL), g.exportFd(77));
    // an import: the CPU's bytes in place, at their offset in the page
    var mine: [3 * PAGE]u8 align(PAGE) = undefined;
    const imp = g.importer();
    try std.testing.expect(imp.import(imp.ctx, mine[10..20], true) == null);
    const m = imp.import(imp.ctx, mine[PAGE + 10 .. PAGE + 20], false).?;
    try std.testing.expectEqual(@as(u32, 1), k.imports);
    try std.testing.expectEqual(@as(u64, 10), m.va % PAGE);
    try std.testing.expectEqual(@as(i64, -EINVAL), g.exportFd(m.handle)); // (an import is the program's)
    imp.release(imp.ctx, m.handle);
    try std.testing.expectEqual(@as(u32, 1), k.live);
    // a dma-buf in: this context's own buffer, named twice, freed with the
    // last name
    const im = g.importFd(@intCast(fd)).?;
    try std.testing.expectEqual(b.handle, im.handle);
    try std.testing.expectEqual(b.va, im.va);
    try std.testing.expectEqual(@intFromPtr(b.cpu.ptr), @intFromPtr(im.cpu.ptr));
    d.free(im);
    try std.testing.expect(g.entryOf(b.handle) != null);
    try std.testing.expect(g.importFd(77) == null);
    // a fence file of the last submission
    try std.testing.expectEqual(@as(i64, 300), g.fenceFd());
    try std.testing.expectEqual(@as(u32, 1), k.fence_fds);
    // a hang: lost from now on
    k.hung = true;
    try std.testing.expectError(error.DeviceLost, d.wait(1, 1000));
    try std.testing.expect(g.lost);
    try std.testing.expectError(error.OutOfMemory, d.alloc(4096));
    g.close();
    try std.testing.expectEqual(@as(u32, 0), k.live);
    try std.testing.expectError(error.Unsupported, g.open());
    k.present = false;
    try std.testing.expectError(error.NoGpu, g.open());
}
