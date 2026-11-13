//! @zpm/va node — the decoder's side of Galaxy's render node
//! (/dev/dri/renderD128, nv_drm.sig on the PC's RTX): the 'G' calls a video
//! driver makes. The same calls, numbers and layouts as the GL driver's
//! client (src/gfxapi/node.sig), with the video ones:
//!
//!   G_INFO     out: u32 version, u32 chip, u32 faults, u32 lost, ...
//!   G_ALLOC    in: u64 size, u32 flags, u64 GPU address (0: one given);
//!              out: u32 handle, u64 GPU address, u64 mmap offset. Whole
//!              2 MiB units, zeroed. G_VRAM: in VRAM (slow for the CPU to
//!              read); without it, system memory the GPU maps (the CPU
//!              reads it at memory speed: decode targets live there).
//!   G_FREE     in: u32 handle.
//!   G_VSUBMIT  in: u32 handle, u32 byte offset, u32 dwords: a pushbuffer
//!              run on the open file's own channel on the video decoder
//!              (NVDEC0, made at the first one; ENODEV: no decoder); out:
//!              u32 fence of that channel.
//!   G_VWAIT    in: u32 fence, i64 absolute CLOCK_MONOTONIC deadline (0:
//!              just look): 0 done, ETIMEDOUT, EIO lost.
//!   G_ESUBMIT  _IOWR('G', 12, 16), G_VSUBMIT's struct: a pushbuffer run
//!              on the open file's own channel on the video encoder
//!              (NVENC0, made at the first one; ENODEV: no encoder); out:
//!              u32 fence of that channel. The kernel binds nothing: the
//!              pushbuffer starts with SET_OBJECT of the encoder's class.
//!   G_EWAIT    _IOW('G', 13, 16), G_VWAIT's struct, for the encoder
//!              channel's fences.
//!   PRIME_HANDLE_TO_FD (DRM's): a buffer as a dma-buf fd.
//!
//! `Node(Sys)`: `Sys` makes the system calls (`Linux` here; `Fake` below
//! is a kernel with a pretend decoder, for tests). Allocation-free.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const NODE = "/dev/dri/renderD128";

// _IOR/_IOW/_IOWR('G', nr, size), as galaxy_gpu_drm and nv_drm encode them.
pub const G_INFO: u32 = 0x8020_4700;
pub const G_ALLOC: u32 = 0xc020_4702;
pub const G_FREE: u32 = 0x4004_4703;
pub const G_VSUBMIT: u32 = 0xc010_470a;
pub const G_VWAIT: u32 = 0x4010_470b;
pub const G_ESUBMIT: u32 = 0xc010_470c;
pub const G_EWAIT: u32 = 0x4010_470d;
pub const PRIME_HANDLE_TO_FD: u32 = 0xc00c_642d;
pub const DRM_CLOEXEC: u32 = 0o2000000;
pub const DRM_RDWR: u32 = 2;
pub const G_VERSION: u32 = 1;
pub const G_VRAM: u32 = 2;
/// The RTX 5070 Laptop GPU (GB206): NVIDIA's vendor id over nouveau's
/// chipset number.
pub const CHIP_GB206: u32 = 0x10de_01b6;
/// nv_drm's buffers come in whole 2 MiB units.
pub const UNIT: usize = 2 << 20;

pub const EINTR = 4;
pub const EIO = 5;
pub const ENODEV = 19;
pub const EINVAL = 22;
pub const ETIMEDOUT = 110;
/// galaxy_gpu_drm's RESTART (the kernel restarts a waiting call; seen here
/// only if a restart ever escapes).
pub const ERESTART = 512;

pub const Info = struct {
    version: u32,
    chip: u32,
    faults: u32,
    lost: bool,
};

/// A buffer of the kernel's, mapped here.
pub const Buf = struct {
    /// the kernel's handle (0: none)
    handle: u32 = 0,
    va: u64 = 0,
    cpu: [*]u8 = undefined,
    /// bytes mapped (whole units)
    len: usize = 0,

    pub fn bytes(b: Buf) []u8 {
        return b.cpu[0..b.len];
    }
};

pub const Wait = enum { done, timeout, lost };

pub fn Node(comptime Sys: type) type {
    return struct {
        const Self = @This();

        sys: Sys,
        fd: i32 = -1,
        /// the GPU hung or went away: nothing more is asked of it
        lost: bool = false,

        /// A call: 0 or -errno. EIO or ENODEV on a call other than
        /// G_VSUBMIT or G_ESUBMIT (whose ENODEV only says there is no
        /// decoder or encoder): lost.
        fn call(n: *Self, req: u32, a: []u8) i64 {
            if (n.fd < 0) return -ENODEV;
            const r = n.sys.ioctl(n.fd, req, a);
            if (r == -EIO or (r == -ENODEV and req != G_VSUBMIT and req != G_ESUBMIT)) n.lost = true;
            return r;
        }

        pub fn info(n: *Self) ?Info {
            var a = [_]u8{0} ** 32;
            if (n.call(G_INFO, &a) != 0) return null;
            return .{ .version = rd32(&a, 0), .chip = rd32(&a, 4), .faults = rd32(&a, 8), .lost = rd32(&a, 12) != 0 };
        }

        /// A buffer of at least `size` bytes (G_VRAM in `flags` for VRAM),
        /// mapped; null when the kernel or mmap refuses.
        pub fn alloc(n: *Self, size: usize, flags: u32) ?Buf {
            if (n.lost or size == 0) return null;
            const len = std.mem.alignForward(usize, size, UNIT);
            var a = [_]u8{0} ** 32;
            wr64(&a, 0, len);
            wr32(&a, 8, flags);
            if (n.call(G_ALLOC, &a) != 0) return null;
            const handle = rd32(&a, 12);
            const at = n.sys.mapBuffer(n.fd, len, rd64(&a, 24));
            if (at < 0) {
                n.freeHandle(handle);
                return null;
            }
            return .{ .handle = handle, .va = rd64(&a, 16), .cpu = @ptrFromInt(@as(usize, @intCast(at))), .len = len };
        }

        pub fn free(n: *Self, b: *Buf) void {
            if (b.handle == 0) return;
            n.sys.unmap(@intFromPtr(b.cpu), b.len);
            n.freeHandle(b.handle);
            b.* = .{};
        }

        fn freeHandle(n: *Self, h: u32) void {
            var a = [_]u8{0} ** 4;
            wr32(&a, 0, h);
            _ = n.call(G_FREE, &a);
        }

        pub const SubmitError = error{ NoDecoder, Lost, Refused };
        pub const EncodeError = error{ NoEncoder, Lost, Refused };

        /// `dwords` of pushbuffer at byte `offset` of `b`, on the video
        /// channel: its fence.
        pub fn vsubmit(n: *Self, b: Buf, offset: u32, dwords: u32) SubmitError!u32 {
            return n.submitOn(G_VSUBMIT, b, offset, dwords) catch |e| switch (e) {
                error.NoEngine => error.NoDecoder,
                error.Lost => error.Lost,
                error.Refused => error.Refused,
            };
        }

        /// The same on the encoder's channel (G_ESUBMIT).
        pub fn esubmit(n: *Self, b: Buf, offset: u32, dwords: u32) EncodeError!u32 {
            return n.submitOn(G_ESUBMIT, b, offset, dwords) catch |e| switch (e) {
                error.NoEngine => error.NoEncoder,
                error.Lost => error.Lost,
                error.Refused => error.Refused,
            };
        }

        fn submitOn(n: *Self, req: u32, b: Buf, offset: u32, dwords: u32) error{ NoEngine, Lost, Refused }!u32 {
            if (n.lost) return error.Lost;
            var a = [_]u8{0} ** 16;
            wr32(&a, 0, b.handle);
            wr32(&a, 4, offset);
            wr32(&a, 8, dwords);
            const r = n.call(req, &a);
            if (r == -ENODEV) return error.NoEngine;
            if (r != 0) return if (n.lost) error.Lost else error.Refused;
            return rd32(&a, 12);
        }

        /// Wait for `fence` until `deadline_ns` (CLOCK_MONOTONIC; 0: only
        /// look).
        pub fn vwait(n: *Self, fence: u32, deadline_ns: i64) Wait {
            return n.waitOn(G_VWAIT, fence, deadline_ns);
        }

        /// The same for the encoder channel's fences (G_EWAIT).
        pub fn ewait(n: *Self, fence: u32, deadline_ns: i64) Wait {
            return n.waitOn(G_EWAIT, fence, deadline_ns);
        }

        fn waitOn(n: *Self, req: u32, fence: u32, deadline_ns: i64) Wait {
            if (n.lost) return .lost;
            var a = [_]u8{0} ** 16;
            wr32(&a, 0, fence);
            wr64(&a, 8, @bitCast(deadline_ns));
            while (true) {
                const r = n.call(req, &a);
                if (r == 0) return .done;
                if (r == -EINTR or r == -ERESTART) continue;
                if (r == -ETIMEDOUT) return .timeout;
                n.lost = true;
                return .lost;
            }
        }

        /// The buffer as a dma-buf fd, or -errno.
        pub fn exportFd(n: *Self, b: Buf) i64 {
            var a = [_]u8{0} ** 12;
            wr32(&a, 0, b.handle);
            wr32(&a, 4, DRM_CLOEXEC | DRM_RDWR);
            const r = n.call(PRIME_HANDLE_TO_FD, &a);
            if (r != 0) return r;
            return @as(i32, @bitCast(rd32(&a, 8)));
        }
    };
}

pub fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
pub fn rd64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}
pub fn wr32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}
pub fn wr64(b: []u8, o: usize, v: u64) void {
    std.mem.writeInt(u64, b[o..][0..8], v, .little);
}

// ── Linux ───────────────────────────────────────────────────────────────────

fn result(r: usize) i64 {
    return @as(isize, @bitCast(r));
}

/// Galaxy's Linux calls (std.os.linux: no C library).
pub const Linux = struct {
    pub fn open(_: Linux, path: [*:0]const u8) i64 {
        return result(linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    }

    pub fn close(_: Linux, fd: i32) void {
        _ = linux.close(fd);
    }

    /// A new fd for `fd` (close on exec), or -errno.
    pub fn dup(_: Linux, fd: i32) i64 {
        return result(linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0));
    }

    pub fn ioctl(_: Linux, fd: i32, req: u32, arg: []u8) i64 {
        return result(linux.ioctl(fd, req, @intFromPtr(arg.ptr)));
    }

    /// A buffer's pages (its mmap offset on the node), anywhere.
    pub fn mapBuffer(_: Linux, fd: i32, len: usize, off: u64) i64 {
        return result(linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @bitCast(off)));
    }

    pub fn unmap(_: Linux, at: usize, len: usize) void {
        _ = linux.munmap(@ptrFromInt(at), len);
    }

    /// Read-write memory of `len` bytes, each page filled on first touch
    /// (MAP_NORESERVE), or -errno.
    pub fn reserve(_: Linux, len: usize) i64 {
        return result(linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0));
    }

    /// [at, at+len)'s pages given back (they read as zero again).
    pub fn discard(_: Linux, at: usize, len: usize) void {
        _ = linux.madvise(@ptrFromInt(at), len, linux.MADV.DONTNEED);
    }

    /// CLOCK_MONOTONIC by the system call itself (std's clock_gettime
    /// finds the vDSO through the C library's getauxval).
    pub fn nowNs(_: Linux) i64 {
        var ts: linux.timespec = undefined;
        _ = linux.syscall2(.clock_gettime, @backingInt(linux.CLOCK.MONOTONIC), @intFromPtr(&ts));
        return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
    }

    /// A line on stderr.
    pub fn say(_: Linux, line: []const u8) void {
        _ = linux.write(2, line.ptr, line.len);
    }

    pub fn yield(_: Linux) void {
        _ = linux.sched_yield();
    }
};

// ── A fake kernel (for tests) ───────────────────────────────────────────────

/// nv_drm's video calls with a pretend decoder and encoder: buffers are
/// anonymous memory at made-up GPU addresses; each G_VSUBMIT (G_ESUBMIT)
/// is recorded and handed to `decoder` (`encoder`, the test's), whose
/// work is done at once or, with `hold`, at the next wait; each channel
/// has its own fences; PRIME gives fd 100 + the handle. Memory calls are
/// Linux's.
pub const Fake = struct {
    chip: u32 = CHIP_GB206,
    has_decoder: bool = true,
    has_encoder: bool = true,
    hung: bool = false,
    /// the video channel faults at this G_VSUBMIT (1: the first, the
    /// init's probe; 0: never): that one is taken, never done, and from
    /// then on every G_VSUBMIT and G_VWAIT fails with EIO, as nv_drm's
    /// for a context whose channel GSP-RM recovered from a fault (the
    /// context's other calls go on)
    vfault_at: u32 = 0,
    vlost: bool = false,
    /// a submission's fence is done only once waited for (the GPU is busy)
    hold: bool = false,
    decoder: ?*const fn (*Fake, Submit) void = null,
    encoder: ?*const fn (*Fake, Submit) void = null,
    bufs: [64]FakeBuf = [_]FakeBuf{.{}} ** 64,
    next_va: u64 = 0x40_0000_0000,
    fence: u32 = 0,
    done: u32 = 0,
    live: u32 = 0,
    submits: [16]Submit = undefined,
    n_submits: u32 = 0,
    /// the encoder channel's
    efence: u32 = 0,
    edone: u32 = 0,
    esubmits: [16]Submit = undefined,
    n_esubmits: u32 = 0,
    waits: u32 = 0,
    exports: u32 = 0,
    lines: u32 = 0,
    dup_next: i32 = 200,

    pub const FakeBuf = struct { va: u64 = 0, mem: []u8 = &.{}, vram: bool = false };
    pub const Submit = struct { handle: u32, offset: u32, dwords: u32 };

    /// The bytes behind GPU address `va` (`len` of them), or null.
    pub fn at(k: *Fake, va: u64, len: usize) ?[]u8 {
        for (k.bufs) |b| {
            if (b.mem.len != 0 and va >= b.va and va + len <= b.va + b.mem.len) return b.mem[@intCast(va - b.va)..][0..len];
        }
        return null;
    }

    /// A submission's pushbuffer.
    pub fn push(k: *Fake, s: Submit) []const u32 {
        const b = k.bufs[s.handle];
        const bytes = b.mem[s.offset..][0 .. s.dwords * 4];
        return @alignCast(std.mem.bytesAsSlice(u32, bytes));
    }

    pub fn open(_: *Fake, _: [*:0]const u8) i64 {
        return 3;
    }
    pub fn close(_: *Fake, _: i32) void {}
    pub fn dup(k: *Fake, _: i32) i64 {
        k.dup_next += 1;
        return k.dup_next;
    }

    pub fn ioctl(k: *Fake, _: i32, req: u32, a: []u8) i64 {
        if (k.hung and req != G_INFO and req != G_FREE) return -EIO;
        switch (req) {
            G_INFO => {
                wr32(a, 0, G_VERSION);
                wr32(a, 4, k.chip);
                wr32(a, 12, @intFromBool(k.hung));
            },
            G_ALLOC => {
                const size = rd64(a, 0);
                if (size % UNIT != 0) return -EINVAL;
                const h = for (k.bufs[1..], 1..) |b, i| {
                    if (b.mem.len == 0) break i;
                } else return -12;
                const r = result(linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0));
                if (r < 0) return -12;
                k.bufs[h] = .{ .va = k.next_va, .mem = @as([*]u8, @ptrFromInt(@as(usize, @intCast(r))))[0..size], .vram = rd32(a, 8) & G_VRAM != 0 };
                k.next_va += size + UNIT;
                k.live += 1;
                wr32(a, 12, @intCast(h));
                wr64(a, 16, k.bufs[h].va);
                wr64(a, 24, @as(u64, h) << 32);
            },
            G_FREE => {
                const h = rd32(a, 0);
                if (h == 0 or h >= k.bufs.len or k.bufs[h].mem.len == 0) return -EINVAL;
                _ = linux.munmap(k.bufs[h].mem.ptr, k.bufs[h].mem.len);
                k.bufs[h] = .{};
                k.live -= 1;
            },
            G_VSUBMIT => {
                if (!k.has_decoder) return -ENODEV;
                if (k.vlost) return -EIO;
                const s = Submit{ .handle = rd32(a, 0), .offset = rd32(a, 4), .dwords = rd32(a, 8) };
                if (s.handle == 0 or s.handle >= k.bufs.len or k.bufs[s.handle].mem.len == 0) return -2;
                if (s.dwords == 0 or s.offset % 4 != 0 or s.offset + s.dwords * 4 > k.bufs[s.handle].mem.len) return -EINVAL;
                if (k.n_submits < k.submits.len) k.submits[k.n_submits] = s;
                k.n_submits += 1;
                if (k.n_submits == k.vfault_at) {
                    // (taken, then the channel faults: its fence never comes)
                    k.vlost = true;
                    k.fence += 1;
                    wr32(a, 12, k.fence);
                    return 0;
                }
                if (k.decoder) |d| d(k, s);
                k.fence += 1;
                if (!k.hold) k.done = k.fence;
                wr32(a, 12, k.fence);
            },
            G_VWAIT => {
                k.waits += 1;
                if (k.vlost) return -EIO;
                const f = rd32(a, 0);
                if (f > k.fence) return -EINVAL;
                if (f <= k.done) return 0;
                // (held work: done at a real wait, still running at a look)
                if (@as(i64, @bitCast(rd64(a, 8))) == 0) return -ETIMEDOUT;
                k.done = k.fence;
            },
            G_ESUBMIT => {
                if (!k.has_encoder) return -ENODEV;
                const s = Submit{ .handle = rd32(a, 0), .offset = rd32(a, 4), .dwords = rd32(a, 8) };
                if (s.handle == 0 or s.handle >= k.bufs.len or k.bufs[s.handle].mem.len == 0) return -2;
                if (s.dwords == 0 or s.offset % 4 != 0 or s.offset + s.dwords * 4 > k.bufs[s.handle].mem.len) return -EINVAL;
                if (k.n_esubmits < k.esubmits.len) k.esubmits[k.n_esubmits] = s;
                k.n_esubmits += 1;
                if (k.encoder) |e| e(k, s);
                k.efence += 1;
                if (!k.hold) k.edone = k.efence;
                wr32(a, 12, k.efence);
            },
            G_EWAIT => {
                k.waits += 1;
                const f = rd32(a, 0);
                if (f > k.efence) return -EINVAL;
                if (f <= k.edone) return 0;
                if (@as(i64, @bitCast(rd64(a, 8))) == 0) return -ETIMEDOUT;
                k.edone = k.efence;
            },
            PRIME_HANDLE_TO_FD => {
                const h = rd32(a, 0);
                if (h == 0 or h >= k.bufs.len or k.bufs[h].mem.len == 0) return -2;
                k.exports += 1;
                wr32(a, 8, 100 + h);
            },
            else => return -25,
        }
        return 0;
    }

    pub fn mapBuffer(k: *Fake, _: i32, len: usize, off: u64) i64 {
        const h: usize = @intCast(off >> 32);
        if (h >= k.bufs.len or k.bufs[h].mem.len < len) return -EINVAL;
        return @intCast(@intFromPtr(k.bufs[h].mem.ptr));
    }
    pub fn unmap(_: *Fake, _: usize, _: usize) void {}
    pub fn reserve(_: *Fake, len: usize) i64 {
        return Linux.reserve(.{}, len);
    }
    pub fn discard(_: *Fake, at_: usize, len: usize) void {
        Linux.discard(.{}, at_, len);
    }
    pub fn nowNs(_: *Fake) i64 {
        return 1_000_000_000;
    }
    pub fn say(k: *Fake, _: []const u8) void {
        k.lines += 1;
    }
    pub fn yield(_: *Fake) void {}
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "node: the calls' numbers are nv_drm's and DRM's" {
    // _IOR('G', 0, 32), _IOWR('G', 2, 32), _IOW('G', 3, 4),
    // _IOWR('G', 10, 16), _IOW('G', 11, 16), _IOWR('G', 12, 16),
    // _IOW('G', 13, 16); _IOWR('d', 0x2d, 12)
    const want = [_]u32{ (2 << 30) | (32 << 16) | 0x4700, (3 << 30) | (32 << 16) | 0x4702, (1 << 30) | (4 << 16) | 0x4703, (3 << 30) | (16 << 16) | 0x470a, (1 << 30) | (16 << 16) | 0x470b, (3 << 30) | (16 << 16) | 0x470c, (1 << 30) | (16 << 16) | 0x470d, (3 << 30) | (12 << 16) | 0x642d };
    try testing.expectEqualSlices(u32, &want, &[_]u32{ G_INFO, G_ALLOC, G_FREE, G_VSUBMIT, G_VWAIT, G_ESUBMIT, G_EWAIT, PRIME_HANDLE_TO_FD });
}

test "node: alloc, submit, wait, export, no decoder, lost" {
    var k = Fake{};
    var n = Node(*Fake){ .sys = &k, .fd = 3 };
    try testing.expectEqual(CHIP_GB206, n.info().?.chip);
    var b = n.alloc(5000, 0).?;
    try testing.expectEqual(UNIT, b.len);
    b.bytes()[4] = 9;
    try testing.expectEqual(@as(u8, 9), k.at(b.va + 4, 1).?[0]);
    try testing.expectEqual(@as(i64, 100 + b.handle), n.exportFd(b));
    k.hold = true;
    const f = try n.vsubmit(b, 0, 2);
    try testing.expectEqual(Wait.timeout, n.vwait(f, 0));
    try testing.expectEqual(Wait.done, n.vwait(f, 5_000_000_000));
    k.has_decoder = false;
    try testing.expectError(error.NoDecoder, n.vsubmit(b, 0, 2));
    try testing.expect(!n.lost);
    k.has_decoder = true;
    k.hung = true;
    try testing.expectError(error.Lost, n.vsubmit(b, 0, 2));
    try testing.expect(n.lost);
    n.free(&b);
    try testing.expectEqual(@as(u32, 0), k.live);
}

test "node: the encoder's channel: its own fences, no encoder, lost" {
    var k = Fake{};
    var n = Node(*Fake){ .sys = &k, .fd = 3 };
    var b = n.alloc(4096, 0).?;
    k.hold = true;
    const d = try n.vsubmit(b, 0, 2);
    const e = try n.esubmit(b, 0, 2);
    try testing.expectEqual(@as(u32, 1), d);
    try testing.expectEqual(@as(u32, 1), e);
    try testing.expectEqual(@as(u32, 1), k.n_esubmits);
    try testing.expectEqual(Wait.timeout, n.ewait(e, 0));
    try testing.expectEqual(Wait.done, n.ewait(e, 5_000_000_000));
    // (the decoder's fence still running: the channels are apart)
    try testing.expectEqual(Wait.timeout, n.vwait(d, 0));
    k.has_encoder = false;
    try testing.expectError(error.NoEncoder, n.esubmit(b, 0, 2));
    try testing.expect(!n.lost);
    k.has_encoder = true;
    k.hung = true;
    try testing.expectError(error.Lost, n.esubmit(b, 0, 2));
    try testing.expect(n.lost);
    try testing.expectEqual(Wait.lost, n.ewait(e, 0));
    n.free(&b);
}
