//! dxgreplay: NVIDIA's GPU setup on /dev/dxg replayed from a dxgtrace
//! recording, by a pure-Sig program (no libc, no libcuda), then zpm's own
//! work on the channel it made. The spike's question: does the host's
//! NVIDIA driver accept a device, contexts, queues and memory that its
//! user-mode driver did not make?
//!
//!   DXGTRACE_OUT=setup.dxgt LD_PRELOAD=./libdxgtrace.so ./cudaprobe
//!   sig build-exe -target x86_64-linux -OReleaseSafe --dep push
//!     -Mroot=tools/dxgreplay.sig -Mpush=src/nvidia/push.sig --name dxgreplay
//!   ./dxgreplay setup.dxgt
//!
//! Every ioctl the recording made before the "cuCtxCreate" mark is made
//! again, in order, with the same argument bytes, except:
//!   - the memory an argument pointed at (recorded) is copied into this
//!     program and the pointers to it changed to the copies;
//!   - an allocation NVIDIA backed with its own memory (allocation info
//!     `sysmem`) gets fresh shared memory here, as big as its GPU mapping;
//!   - a handle dxgkrnl answers differently from the recording is changed
//!     in every later argument;
//!   - NVIDIA's submissions and waits are left out (its channel set-up
//!     pushbuffers are not in the recording; a host semaphore release needs
//!     none of them), and a second's sleep stands in for the paging waits.
//! Then a host semaphore release (push.hostRelease) goes into the first
//! hardware queue's ring at entry 0, rung with submit_to_hw_queue (fence 1),
//! and the program watches the semaphore.
//!
//! Fixed buffers, no allocator.

const std = @import("std");
const linux = std.os.linux;
const push = @import("push");

var file: [64 << 20]u8 = undefined;
var arena: [32 << 20]u8 align(16) = undefined;
var arena_used: usize = 0;

const Rec = struct { off: usize, kind: u32, nr: u32, seq: u32, addr: u64, data: []u8, rc: i32 };

fn recAt(off: usize, len: usize) ?Rec {
    if (off + 32 > len) return null;
    const h = file[off..][0..32];
    if (!std.mem.eql(u8, h[0..4], "DXGT")) return null;
    const n = std.mem.readInt(u32, h[24..28], .little);
    if (off + 32 + n > len) return null;
    return .{
        .off = off,
        .kind = std.mem.readInt(u32, h[4..8], .little),
        .nr = std.mem.readInt(u32, h[8..12], .little),
        .seq = std.mem.readInt(u32, h[12..16], .little),
        .addr = std.mem.readInt(u64, h[16..24], .little),
        .data = file[off + 32 .. off + 32 + n],
        .rc = std.mem.readInt(i32, h[28..32], .little),
    };
}

fn next(r: Rec) usize {
    return r.off + 32 + r.data.len;
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}
fn wr64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    out(fmt, args);
    linux.exit(1);
}

fn alloc(n: usize) []u8 {
    const at = std.mem.alignForward(usize, arena_used, 16);
    if (at + n > arena.len) die("dxgreplay: the arena is full\n", .{});
    arena_used = at + n;
    return arena[at .. at + n];
}

/// Replaces every u64 equal to `from` (4-byte steps) with `to`.
fn patch64(b: []u8, from: u64, to: u64) void {
    if (b.len < 8) return;
    var i: usize = 0;
    while (i + 8 <= b.len) : (i += 4) {
        if (rd64(b, i) == from) wr64(b, i, to);
    }
}

// Handles dxgkrnl answered differently: recorded -> ours.
var remap: [4096][2]u32 = undefined;
var remap_n: usize = 0;

fn remapHandles(b: []u8) void {
    var i: usize = 0;
    while (i + 4 <= b.len) : (i += 4) {
        const v = rd32(b, i);
        for (remap[0..remap_n]) |m| {
            if (m[0] == v) {
                std.mem.writeInt(u32, b[i..][0..4], m[1], .little);
                break;
            }
        }
    }
}

fn isHandle(v: u32) bool {
    return v >= 0x4000_0000 and v < 0x4100_0000 and v & 0x3f == 0;
}

/// An allocation backed by memory here: its recorded handle, our CPU
/// address and bytes, and the GPU address the recording mapped it at.
const Mem = struct { handle: u32, cpu: u64, bytes: u64, gpu: u64 = 0 };
var mems: [256]Mem = undefined;
var mems_n: usize = 0;

/// The bytes the recording later mapped allocation `handle` with
/// (map_gpu_va size_in_pages), from `from` on.
fn mappedBytes(from: usize, len: usize, handle: u32) u64 {
    var o = from;
    while (recAt(o, len)) |r| : (o = next(r)) {
        if (r.kind == 2 and r.nr == 0x0c and r.data.len >= 56 and rd32(r.data, 32) == handle) return rd64(r.data, 48) * 4096;
    }
    return 0;
}

const SKIP = [_]u32{ 0x0f, 0x12, 0x34, 0x35, 0x36, 0x3a, 0x3b };

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    if (argv.len < 2) die("usage: dxgreplay RECORDING.dxgt\n", .{});
    const ffd: isize = @bitCast(linux.open(argv[1], .{ .ACCMODE = .RDONLY }, 0));
    if (ffd < 0) die("dxgreplay: cannot open the recording\n", .{});
    var len: usize = 0;
    while (len < file.len) {
        const n: isize = @bitCast(linux.read(@intCast(ffd), file[len..].ptr, file.len - len));
        if (n <= 0) break;
        len += @intCast(n);
    }
    const dfd: isize = @bitCast(linux.open("/dev/dxg", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    if (dfd < 0) die("dxgreplay: cannot open /dev/dxg\n", .{});
    const dxg: i32 = @intCast(dfd);

    var queue0: ?struct { handle: u32, progress_cpu: u64, gpfifo_va: u64 } = null;
    var made: usize = 0;
    var off: usize = 0;
    while (recAt(off, len)) |r| : (off = next(r)) {
        if (r.kind == 6 and r.nr == 0 and std.mem.eql(u8, r.data, "cuCtxCreate")) break;
        if (r.kind != 1) continue;
        if (std.mem.indexOfScalar(u32, &SKIP, r.nr) != null) continue;

        // the argument and the memory it points at, copied
        const arg = alloc(r.data.len);
        @memcpy(arg, r.data);
        var blobs: [16]struct { from: u64, to: []u8 } = undefined;
        var nb: usize = 0;
        var o = next(r);
        while (recAt(o, len)) |b| : (o = next(b)) {
            if (b.kind != 3 or b.seq != r.seq or nb == blobs.len) break;
            const c = alloc(b.data.len);
            @memcpy(c, b.data);
            blobs[nb] = .{ .from = b.addr, .to = c };
            nb += 1;
        }
        for (blobs[0..nb]) |b| {
            patch64(arg, b.from, @intFromPtr(b.to.ptr));
            for (blobs[0..nb]) |c| patch64(c.to, b.from, @intFromPtr(b.to.ptr));
        }
        remapHandles(arg);
        for (blobs[0..nb]) |b| remapHandles(b.to);

        // the recorded answer (for the allocations' handles and checks)
        var rec_out: ?Rec = null;
        var rec_info_out: ?Rec = null;
        o = next(r);
        while (recAt(o, len)) |b| : (o = next(b)) {
            if (b.kind == 2 and b.seq == r.seq) {
                rec_out = b;
                var p = next(b);
                while (recAt(p, len)) |c| : (p = next(c)) {
                    if (c.kind != 4 or c.seq != r.seq) break;
                    if (r.nr == 0x06 and c.addr == rd64(r.data, 48)) rec_info_out = c;
                }
                break;
            }
        }

        // allocations NVIDIA backed with its own memory: ours instead
        if (r.nr == 0x06) {
            const count = rd32(arg, 44);
            const info_rec = rd64(r.data, 48);
            for (blobs[0..nb]) |b| {
                if (b.from != info_rec) continue;
                for (0..count) |i| {
                    const info = b.to[i * 96 ..][0..96];
                    if (rd64(info, 8) == 0) continue;
                    const handle = if (rec_info_out) |io| rd32(io.data, i * 96) else 0;
                    const bytes = mappedBytes(off, len, handle);
                    if (bytes == 0) die("dxgreplay: #{d}: allocation {x} is never mapped\n", .{ r.seq, handle });
                    const m: isize = @bitCast(linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0));
                    if (m < 0) die("dxgreplay: no memory for allocation {x}\n", .{handle});
                    wr64(info, 8, @intCast(m));
                    if (mems_n < mems.len) {
                        mems[mems_n] = .{ .handle = handle, .cpu = @intCast(m), .bytes = bytes };
                        mems_n += 1;
                    }
                }
            }
        }

        const req: u32 = 0xc000_0000 | (@as(u32, @intCast(arg.len)) << 16) | (0x47 << 8) | r.nr;
        const rc: isize = @bitCast(linux.ioctl(dxg, req, @intFromPtr(arg.ptr)));
        made += 1;
        if (rec_out) |ro| {
            if (rc != ro.rc) out("#{d} nr {x}: rc {d} (recorded {d})\n", .{ r.seq, r.nr, rc, ro.rc });
            // the handles it answered
            var i: usize = 0;
            while (i + 4 <= arg.len and i + 4 <= ro.data.len) : (i += 4) {
                const was_in = rd32(r.data, i);
                const want = rd32(ro.data, i);
                const got = rd32(arg, i);
                if (want != was_in and isHandle(want) and got != want and remap_n < remap.len) {
                    remap[remap_n] = .{ want, got };
                    remap_n += 1;
                }
            }
        }
        if (rc < 0) die("#{d} nr {x}: failed, errno {d}\n", .{ r.seq, r.nr, -rc });

        if (r.nr == 0x0c) {
            const h = rd32(r.data, 32);
            for (mems[0..mems_n]) |*m| {
                if (m.handle == h) m.gpu = rd64(arg, 88);
            }
        }
        if (r.nr == 0x18 and queue0 == null) {
            const priv = rd64(arg, 16);
            const p: [*]const u8 = @ptrFromInt(priv);
            queue0 = .{ .handle = rd32(arg, 24), .progress_cpu = rd64(arg, 32), .gpfifo_va = rd64(p[0..0x28], 0x18) };
        }
    }
    out("replayed {d} ioctls; {d} handles answered differently; {d} allocations backed here\n", .{ made, remap_n, mems_n });
    const q = queue0 orelse die("no hardware queue in the recording\n", .{});

    // the ring: the allocation mapped at the queue's GPFIFO address
    var ring_cpu: u64 = 0;
    var ring_bytes: u64 = 0;
    for (mems[0..mems_n]) |m| {
        if (m.gpu == q.gpfifo_va) {
            ring_cpu = m.cpu;
            ring_bytes = m.bytes;
        }
    }
    if (ring_cpu == 0 or ring_bytes < 2 << 20) die("the ring 0x{x} is not in memory here\n", .{q.gpfifo_va});
    out("queue {x}: ring 0x{x} (cpu 0x{x}), progress page 0x{x}\n", .{ q.handle, q.gpfifo_va, ring_cpu, q.progress_cpu });

    // the paging (maps, residency) finish
    const ts: linux.timespec = .{ .sec = 1, .nsec = 0 };
    _ = linux.nanosleep(&ts, null);

    // zpm's work: a host semaphore release, entry 0, rung with fence 1
    const pb_va = q.gpfifo_va + 0x10_0000;
    const sem_va = q.gpfifo_va + 0x18_0000;
    const pb: [*]u32 = @ptrFromInt(ring_cpu + 0x10_0000);
    const sem: *volatile u32 = @ptrFromInt(ring_cpu + 0x18_0000);
    sem.* = 0;
    const want: u32 = 0x5157_0001;
    const n = push.hostRelease(pb[0..16], sem_va, want) catch unreachable;
    const ring: [*]volatile u64 = @ptrFromInt(ring_cpu);
    ring[0] = push.gpEntry(pb_va, @intCast(n)) | (1 << 41);

    var priv: [536]u8 = [_]u8{0} ** 536;
    std.mem.writeInt(u32, priv[0..4], 0x4e56_4441, .little);
    std.mem.writeInt(u32, priv[4..8], 0x0001_0000, .little);
    std.mem.writeInt(u32, priv[12..16], 0x118, .little);
    std.mem.writeInt(u32, priv[16..20], 0x20, .little);
    std.mem.writeInt(u32, priv[20..24], 1, .little);
    std.mem.writeInt(u64, priv[120..128], 1, .little);
    std.mem.writeInt(u32, priv[272..276], 0x10, .little);
    var arg: [56]u8 = [_]u8{0} ** 56;
    std.mem.writeInt(u32, arg[0..4], q.handle, .little);
    wr64(&arg, 8, 1);
    wr64(&arg, 16, 0xdeadbeef);
    std.mem.writeInt(u32, arg[24..28], 1, .little);
    std.mem.writeInt(u32, arg[28..32], priv.len, .little);
    wr64(&arg, 32, @intFromPtr(&priv));
    const rc: isize = @bitCast(linux.ioctl(dxg, 0xc038_4734, @intFromPtr(&arg)));
    var t: u32 = 0;
    while (t < 1000) : (t += 1) {
        if (sem.* == want) {
            out("RAN: zpm's semaphore release on a channel set up without libcuda ({d} ms, submit rc {d})\n", .{ t, rc });
            linux.exit(0);
        }
        const ms: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&ms, null);
    }
    die("not run in 1 s (submit rc {d}, semaphore {x})\n", .{ rc, sem.* });
}
