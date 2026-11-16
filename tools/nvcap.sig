//! nvcap: what NVIDIA's own user-mode driver gives GB206's NVENC, captured
//! from inside the encoding process (LD_PRELOAD), for comparing with
//! zpm's va driver (src/va/nvenc.sig).
//!
//!   sig build-lib -dynamic -target x86_64-linux-gnu -lc -OReleaseSafe -fPIC
//!     tools/nvcap.sig --name nvcap -femit-bin=libnvcap.so
//!   NVCAP_OUT=hevc.nvcap LD_PRELOAD=./libnvcap.so ffmpeg ... -c:v hevc_nvenc ...
//!   python3 tools/nvcap_summary.py hevc.nvcap --methods
//!   python3 tools/nvcap_fields.py src/va/nvenc.sig hevc.nvcap H265
//!
//! WSL: NVIDIA's libraries (/usr/lib/wsl/lib) reach the GPU through
//! /dev/dxg ioctls (libdxcore imports libc's ioctl), and their buffers for
//! the GPU are shared mappings another process cannot read (/proc/<pid>/mem
//! refuses them). So this library wraps ioctl: before each ioctl on
//! /dev/dxg it scans the process's own readable shared mappings for
//!   - NVENC picture setups: a 256-aligned dword whose top half is an
//!     NVENC class (0xcfb7 GB20x, ...) and whose next dword holds a frame
//!     width less one; SETUP bytes from there are recorded;
//!   - pushbuffer windows: a method header (incrementing, non-incrementing
//!     or one-increment) whose methods cover SET_IN_DRV_PIC_SETUP (0x710);
//!     WINDOW bytes around it are recorded;
//! each once (by content), with the ioctl's sequence number, so the
//! records come in submission order. Fixed buffers, no allocator.
//!
//! Records (little endian): "NVCP", u32 kind (1 setup, 2 push, 3 note),
//! u64 the CPU address, u32 ioctl number, u32 length, then the bytes.

const std = @import("std");
const linux = std.os.linux;

const SETUP = 32 << 10;
const WINDOW = 2048;
const MAX_REGION = 256 << 20;
const MAX_SEEN = 1 << 14;
const NVENC_CLASSES = [_]u16{ 0xcfb7, 0xceb7, 0xc9b7, 0xc7b7, 0xc5b7, 0xc4b7 };

extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
const RTLD_NEXT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const IoctlFn = *const fn (c_int, c_ulong, usize) callconv(.c) c_int;
var real_ioctl: ?IoctlFn = null;

var lock = std.atomic.Value(u32).init(0);
var out_fd: i32 = -2;
var seq: u32 = 0;
var seen: [MAX_SEEN]u64 = [_]u64{0} ** MAX_SEEN;
var seen_n: usize = 0;
/// fds known to be /dev/dxg (1) or something else (2), by fd number
var fd_kind: [4096]u8 = [_]u8{0} ** 4096;
var maps_buf: [2 << 20]u8 = undefined;
var noted_regions = false;

export fn ioctl(fd: c_int, req: c_ulong, arg: usize) callconv(.c) c_int {
    if (real_ioctl == null) {
        const p = dlsym(RTLD_NEXT, "ioctl") orelse return -1;
        real_ioctl = @ptrCast(p);
    }
    if (isDxg(fd) and lock.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        defer lock.store(0, .release);
        seq +%= 1;
        scan();
    }
    return real_ioctl.?(fd, req, arg);
}

fn isDxg(fd: c_int) bool {
    if (fd < 0 or fd >= fd_kind.len) return false;
    const i: usize = @intCast(fd);
    if (fd_kind[i] == 0) {
        var path: [32]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&path, "/proc/self/fd/{d}", .{fd}, 0) catch return false;
        var target: [64]u8 = undefined;
        const rc = linux.readlink(p.ptr, &target, target.len);
        const n: isize = @bitCast(rc);
        fd_kind[i] = if (n > 0 and std.mem.eql(u8, target[0..@intCast(n)], "/dev/dxg")) 1 else 2;
    }
    return fd_kind[i] == 1;
}

fn openOut() void {
    if (out_fd != -2) return;
    const name: [*:0]const u8 = getenv("NVCAP_OUT") orelse "/tmp/nvcap.bin";
    const rc = linux.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    const n: isize = @bitCast(rc);
    out_fd = if (n >= 0) @intCast(n) else -1;
}

fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(out_fd, bytes[off..].ptr, bytes.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn record(kind: u32, addr: usize, bytes: []const u8) void {
    openOut();
    if (out_fd < 0) return;
    var head: [24]u8 = undefined;
    @memcpy(head[0..4], "NVCP");
    std.mem.writeInt(u32, head[4..8], kind, .little);
    std.mem.writeInt(u64, head[8..16], addr, .little);
    std.mem.writeInt(u32, head[16..20], seq, .little);
    std.mem.writeInt(u32, head[20..24], @intCast(bytes.len), .little);
    writeAll(&head);
    writeAll(bytes);
}

/// Whether `bytes` was recorded before (and remembers it).
fn seenBefore(kind: u32, bytes: []const u8) bool {
    const h = std.hash.Wyhash.hash(kind, bytes);
    for (seen[0..seen_n]) |s| if (s == h) return true;
    if (seen_n < MAX_SEEN) {
        seen[seen_n] = h;
        seen_n += 1;
    }
    return false;
}

fn scan() void {
    const fd_rc = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const fd_n: isize = @bitCast(fd_rc);
    if (fd_n < 0) return;
    const fd: i32 = @intCast(fd_n);
    var len: usize = 0;
    while (len < maps_buf.len) {
        const rc = linux.read(fd, maps_buf[len..].ptr, maps_buf.len - len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        len += @intCast(n);
    }
    _ = linux.close(fd);
    var lines = std.mem.tokenizeScalar(u8, maps_buf[0..len], '\n');
    while (lines.next()) |line| {
        // lo-hi perms offset dev inode [path]
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const range = f.next() orelse continue;
        const perms = f.next() orelse continue;
        _ = f.next();
        _ = f.next();
        _ = f.next();
        const path = f.rest();
        if (perms.len < 4 or perms[0] != 'r' or perms[3] != 's') continue;
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const lo = std.fmt.parseInt(usize, range[0..dash], 16) catch continue;
        const hi = std.fmt.parseInt(usize, range[dash + 1 ..], 16) catch continue;
        if (hi <= lo or hi - lo > MAX_REGION) continue;
        if (!noted_regions) {
            var note: [200]u8 = undefined;
            const s = std.fmt.bufPrint(&note, "region {x}-{x} {s} {s}", .{ lo, hi, perms, path }) catch continue;
            record(3, lo, s);
        }
        scanRegion(@as([*]const u8, @ptrFromInt(lo))[0 .. hi - lo], lo);
    }
    noted_regions = true;
}

fn isClass(top: u32) bool {
    for (NVENC_CLASSES) |c| if (top == c) return true;
    return false;
}

fn scanRegion(mem: []const u8, base: usize) void {
    // setups: 256-aligned
    var off: usize = 0;
    while (off + 8 <= mem.len) : (off += 256) {
        const w = std.mem.readInt(u32, mem[off..][0..4], .little);
        if (!isClass(w >> 16) or (w & 0xff00) != 0) continue;
        const w1 = std.mem.readInt(u32, mem[off + 4 ..][0..4], .little);
        const wm1 = w1 & 0xffff;
        if (wm1 < 15 or wm1 > 8191) continue;
        const bytes = mem[off..@min(mem.len, off + SETUP)];
        if (!seenBefore(1, bytes)) record(1, base + off, bytes);
    }
    // pushbuffer windows: a method header covering 0x710
    off = 0;
    while (off + 8 <= mem.len) : (off += 4) {
        const h = std.mem.readInt(u32, mem[off..][0..4], .little);
        const op = h >> 29;
        if (op != 1 and op != 3 and op != 5) continue;
        const count = (h >> 16) & 0x1fff;
        const first = (h & 0xfff) << 2;
        if (count == 0 or count > 64) continue;
        const last = if (op == 1) first + 4 * (count - 1) else if (op == 5) first + 4 else first;
        if (!(first <= 0x710 and 0x710 <= last)) continue;
        if (first < 0x700 or first > 0x710) continue;
        const a = off -| WINDOW / 2;
        const bytes = mem[a..@min(mem.len, a + WINDOW)];
        if (!seenBefore(2, bytes)) record(2, base + a, bytes);
        off += 4 * count;
    }
}
