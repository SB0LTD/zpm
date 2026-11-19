//! @zpm/vhost — a vhost-user device backend in pure Sig (Linux, no libc):
//! QEMU's virtio device whose work this process does (`-chardev socket` +
//! `-device vhost-user-device-pci,chardev=...,virtio-id=N,num_vqs=Q`, the
//! guest's RAM shared: `-object memory-backend-memfd,share=on`).
//!
//! What it does:
//!   - the vhost-user protocol on a Unix socket (QEMU connects): features,
//!     the guest's memory table (each region a file descriptor, mapped
//!     here), each virtqueue's size, rings and eventfds;
//!   - the split virtqueues (virtio 1.x): each request the guest makes
//!     available, as a chain of device-readable then device-writable
//!     buffers, handed to the device's `Handler`; the bytes it wrote go back
//!     on the used ring and the guest is signalled.
//!
//! Offered: VIRTIO_F_VERSION_1 and the vhost-user protocol features bit,
//! no protocol features (no config space: config_size=0), no indirect
//! descriptors, no event index. One connection at a time; a request is
//! handled to its end before the next.
//!
//! Polling (`poll_us`): after a request the backend keeps reading the
//! queues for that long with the used ring's NO_NOTIFY flag up, so a
//! driver that honours it sends a burst of requests without a doorbell
//! each (a doorbell is a VM exit, dear under nested virtualization: KVM in
//! WSL). Then the flag comes down, the queues are read once more (a
//! request made meanwhile rang no doorbell) and the backend sleeps.
//!
//! `guestBytes` gives the device a guest-physical range as this process's
//! memory (the GPU forwarding maps it for the GPU).
//!
//! Allocation-free: fixed tables (MAX_REGIONS, MAX_QUEUES, MAX_CHAIN).

const std = @import("std");
const linux = std.os.linux;

pub const MAX_REGIONS = 8;
pub const MAX_QUEUES = 4;
pub const MAX_CHAIN = 16;

pub const Error = error{ Socket, Closed, BadMessage, BadRing };

// ── The protocol ────────────────────────────────────────────────────────────

pub const Req = enum(u32) {
    get_features = 1,
    set_features = 2,
    set_owner = 3,
    reset_owner = 4,
    set_mem_table = 5,
    set_log_base = 6,
    set_log_fd = 7,
    set_vring_num = 8,
    set_vring_addr = 9,
    set_vring_base = 10,
    get_vring_base = 11,
    set_vring_kick = 12,
    set_vring_call = 13,
    set_vring_err = 14,
    get_protocol_features = 15,
    set_protocol_features = 16,
    get_queue_num = 17,
    set_vring_enable = 18,
    get_config = 24,
    set_config = 25,
    _,
};

const FLAG_VERSION: u32 = 0x1;
const FLAG_REPLY: u32 = 0x4;
const FLAG_NEED_REPLY: u32 = 0x8;

pub const F_VERSION_1: u64 = 1 << 32;
pub const F_PROTOCOL_FEATURES: u64 = 1 << 30;
const VRING_NOFD: u64 = 0x100;

const Header = extern struct { request: u32, flags: u32, size: u32 };

const MemRegion = extern struct { gpa: u64, size: u64, uaddr: u64, mmap_offset: u64 };
const VringState = extern struct { index: u32, num: u32 };
const VringAddr = extern struct { index: u32, flags: u32, desc: u64, used: u64, avail: u64, log: u64 };

// ── Split virtqueues (virtio 1.x §2.7) ──────────────────────────────────────

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;
const UsedElem = extern struct { id: u32, len: u32 };

const Region = struct { gpa: u64 = 0, size: u64 = 0, uaddr: u64 = 0, host: [*]u8 = undefined, map: []align(4096) u8 = &.{} };

const Queue = struct {
    num: u32 = 0,
    desc: ?[*]volatile Desc = null,
    avail: ?[*]volatile u16 = null, // flags, idx, ring[num]
    used: ?[*]volatile u8 = null, // flags u16, idx u16, ring[num] of UsedElem
    last_avail: u16 = 0,
    kick: i32 = -1,
    call: i32 = -1,
    enabled: bool = false,
};

/// The device's side: one request's buffers in, the bytes written out.
pub const Handler = struct {
    ctx: *anyopaque,
    request: *const fn (ctx: *anyopaque, queue: u32, readable: []const []const u8, writable: []const []u8) u32,
};

pub const Backend = struct {
    listen_fd: i32 = -1,
    conn: i32 = -1,
    features: u64 = F_VERSION_1 | F_PROTOCOL_FEATURES,
    acked: u64 = 0,
    regions: [MAX_REGIONS]Region = [_]Region{.{}} ** MAX_REGIONS,
    nregions: usize = 0,
    queues: [MAX_QUEUES]Queue = [_]Queue{.{}} ** MAX_QUEUES,
    nqueues: u32 = 1,
    msg: [512]u8 align(8) = undefined,
    /// Requests handled (for the log).
    handled: u64 = 0,
    log: ?*const fn (line: []const u8) void = null,
    /// How long to keep polling the queues after a request (us; 0: never).
    poll_us: u64 = 0,

    /// Listens on Unix socket `path` (replaced if it exists), for a
    /// device with `nqueues` virtqueues.
    pub fn listen(b: *Backend, path: [:0]const u8, nqueues: u32) Error!void {
        b.nqueues = @min(nqueues, MAX_QUEUES);
        _ = linux.unlink(path);
        const fd: isize = @bitCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
        if (fd < 0) return error.Socket;
        b.listen_fd = @intCast(fd);
        var addr: linux.sockaddr.un = .{ .path = [_]u8{0} ** 108 };
        if (path.len >= addr.path.len) return error.Socket;
        @memcpy(addr.path[0..path.len], path);
        if (@as(isize, @bitCast(linux.bind(b.listen_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)))) < 0) return error.Socket;
        if (@as(isize, @bitCast(linux.listen(b.listen_fd, 1))) < 0) return error.Socket;
    }

    /// Waits for QEMU, then serves it until it goes away.
    pub fn serve(b: *Backend, h: Handler) Error!void {
        const c: isize = @bitCast(linux.accept4(b.listen_fd, null, null, linux.SOCK.CLOEXEC));
        if (c < 0) return error.Socket;
        b.conn = @intCast(c);
        b.say("vhost: QEMU connected", .{});
        defer b.disconnect();
        var fds: [1 + MAX_QUEUES]linux.pollfd = undefined;
        while (true) {
            var n: usize = 0;
            fds[n] = .{ .fd = b.conn, .events = linux.POLL.IN };
            n += 1;
            var which: [MAX_QUEUES]u32 = undefined;
            for (b.queues[0..b.nqueues], 0..) |q, i| {
                if (q.kick < 0) continue;
                which[n - 1] = @intCast(i);
                fds[n] = .{ .fd = q.kick, .events = linux.POLL.IN };
                n += 1;
            }
            const rc: isize = @bitCast(linux.poll(&fds, @intCast(n), -1));
            if (rc < 0) continue;
            if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0 and fds[0].revents & linux.POLL.IN == 0) return;
            if (fds[0].revents & linux.POLL.IN != 0) {
                b.message() catch |e| {
                    if (e == error.Closed) return;
                    return e;
                };
            }
            var got: usize = 0;
            for (fds[1..n], 0..) |f, k| {
                if (f.revents & linux.POLL.IN == 0) continue;
                var v: u64 = 0;
                _ = linux.read(f.fd, @ptrCast(&v), 8);
                got += b.drain(which[k], h);
            }
            if (got != 0 and b.poll_us != 0) b.pollAwhile(h);
        }
    }

    fn disconnect(b: *Backend) void {
        for (&b.queues) |*q| {
            if (q.kick >= 0) _ = linux.close(q.kick);
            if (q.call >= 0) _ = linux.close(q.call);
            q.* = .{};
        }
        b.unmapAll();
        _ = linux.close(b.conn);
        b.conn = -1;
        b.say("vhost: QEMU went away", .{});
    }

    fn unmapAll(b: *Backend) void {
        for (b.regions[0..b.nregions]) |r| _ = linux.munmap(r.map.ptr, r.map.len);
        b.nregions = 0;
    }

    fn say(b: *Backend, comptime fmt: []const u8, args: anytype) void {
        const l = b.log orelse return;
        var buf: [200]u8 = undefined;
        l(std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    // ── Messages ───────────────────────────────────────────────────────────

    /// One message from QEMU (and the file descriptors it carries).
    fn message(b: *Backend) Error!void {
        var fdbuf: [MAX_REGIONS]i32 = undefined;
        const nfds = try b.receive(&fdbuf);
        const hdr = std.mem.bytesToValue(Header, b.msg[0..12]);
        const p = b.msg[12..][0..hdr.size];
        const req: Req = @enumFromInt(hdr.request);
        var reply_u64: ?u64 = null;
        switch (req) {
            .get_features => reply_u64 = b.features,
            .set_features => b.acked = std.mem.readInt(u64, p[0..8], .little),
            .get_protocol_features => reply_u64 = 0,
            .set_protocol_features, .set_owner, .reset_owner, .set_log_base => {},
            .get_queue_num => reply_u64 = b.nqueues,
            .set_mem_table => try b.memTable(p, fdbuf[0..nfds]),
            .set_vring_num => {
                const s = std.mem.bytesToValue(VringState, p[0..8]);
                if (s.index < b.nqueues) b.queues[s.index].num = s.num;
            },
            .set_vring_addr => {
                const a = std.mem.bytesToValue(VringAddr, p[0..40]);
                if (a.index < b.nqueues) {
                    const q = &b.queues[a.index];
                    q.desc = @ptrCast(@alignCast(b.fromUser(a.desc) orelse return error.BadRing));
                    q.avail = @ptrCast(@alignCast(b.fromUser(a.avail) orelse return error.BadRing));
                    q.used = @ptrCast(b.fromUser(a.used) orelse return error.BadRing);
                }
            },
            .set_vring_base => {
                const s = std.mem.bytesToValue(VringState, p[0..8]);
                if (s.index < b.nqueues) b.queues[s.index].last_avail = @truncate(s.num);
            },
            .get_vring_base => {
                const s = std.mem.bytesToValue(VringState, p[0..8]);
                var r = VringState{ .index = s.index, .num = 0 };
                if (s.index < b.nqueues) {
                    const q = &b.queues[s.index];
                    r.num = q.last_avail;
                    if (q.kick >= 0) _ = linux.close(q.kick);
                    q.kick = -1;
                    q.enabled = false;
                }
                try b.reply(req, std.mem.asBytes(&r));
            },
            .set_vring_kick, .set_vring_call, .set_vring_err => {
                const v = std.mem.readInt(u64, p[0..8], .little);
                const idx: u32 = @intCast(v & 0xff);
                const fd: i32 = if (v & VRING_NOFD == 0 and nfds > 0) fdbuf[0] else -1;
                if (idx >= b.nqueues or req == .set_vring_err) {
                    if (fd >= 0) _ = linux.close(fd);
                } else {
                    const q = &b.queues[idx];
                    const slot = if (req == .set_vring_kick) &q.kick else &q.call;
                    if (slot.* >= 0) _ = linux.close(slot.*);
                    slot.* = fd;
                    // (without the protocol features a ring starts with its kick)
                    if (req == .set_vring_kick and b.acked & F_PROTOCOL_FEATURES == 0) q.enabled = true;
                }
            },
            .set_vring_enable => {
                const s = std.mem.bytesToValue(VringState, p[0..8]);
                if (s.index < b.nqueues) b.queues[s.index].enabled = s.num != 0;
            },
            else => {
                b.say("vhost: request {d} not handled", .{hdr.request});
                for (fdbuf[0..nfds]) |fd| _ = linux.close(fd);
            },
        }
        if (reply_u64) |v| {
            var x = v;
            try b.reply(req, std.mem.asBytes(&x));
        } else if (hdr.flags & FLAG_NEED_REPLY != 0 and req != .get_vring_base) {
            var zero: u64 = 0;
            try b.reply(req, std.mem.asBytes(&zero));
        }
    }

    /// The next message into `msg`, its descriptors into `fds`.
    fn receive(b: *Backend, fds: *[MAX_REGIONS]i32) Error!usize {
        var control: [256]u8 align(8) = undefined;
        var iov = [_]std.posix.iovec{.{ .base = &b.msg, .len = 12 }};
        var mh = linux.msghdr{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
        const n: isize = @bitCast(linux.recvmsg(b.conn, &mh, linux.MSG.CMSG_CLOEXEC));
        if (n == 0) return error.Closed;
        if (n != 12) return error.BadMessage;
        // the descriptors (SCM_RIGHTS)
        var nfds: usize = 0;
        var off: usize = 0;
        while (off + @sizeOf(linux.cmsghdr) <= mh.controllen) {
            const c = std.mem.bytesToValue(linux.cmsghdr, control[off..][0..@sizeOf(linux.cmsghdr)]);
            if (c.len < @sizeOf(linux.cmsghdr)) break;
            if (c.level == linux.SOL.SOCKET and c.type == linux.SCM.RIGHTS) {
                const data = control[off + @sizeOf(linux.cmsghdr) .. off + c.len];
                var k: usize = 0;
                while (k + 4 <= data.len and nfds < fds.len) : (k += 4) {
                    fds[nfds] = std.mem.readInt(i32, data[k..][0..4], .little);
                    nfds += 1;
                }
            }
            off += std.mem.alignForward(usize, c.len, 8);
        }
        const size = std.mem.readInt(u32, b.msg[8..12], .little);
        if (size > b.msg.len - 12) return error.BadMessage;
        var got: usize = 0;
        while (got < size) {
            const r: isize = @bitCast(linux.read(b.conn, b.msg[12 + got ..].ptr, size - got));
            if (r <= 0) return error.Closed;
            got += @intCast(r);
        }
        return nfds;
    }

    fn reply(b: *Backend, req: Req, payload: []const u8) Error!void {
        var out: [64]u8 align(8) = undefined;
        const hdr = Header{ .request = @intFromEnum(req), .flags = FLAG_VERSION | FLAG_REPLY, .size = @intCast(payload.len) };
        @memcpy(out[0..12], std.mem.asBytes(&hdr));
        @memcpy(out[12..][0..payload.len], payload);
        const total = 12 + payload.len;
        const w: isize = @bitCast(linux.write(b.conn, &out, total));
        if (w != @as(isize, @intCast(total))) return error.Closed;
    }

    fn memTable(b: *Backend, p: []const u8, fds: []const i32) Error!void {
        b.unmapAll();
        const n = std.mem.readInt(u32, p[0..4], .little);
        if (n > MAX_REGIONS or n > fds.len) return error.BadMessage;
        for (0..n) |i| {
            const r = std.mem.bytesToValue(MemRegion, p[8 + 32 * i ..][0..32]);
            const len = r.size + r.mmap_offset;
            const m: isize = @bitCast(linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fds[i], 0));
            _ = linux.close(fds[i]);
            if (m < 0) return error.BadMessage;
            const base: [*]align(4096) u8 = @ptrFromInt(@as(usize, @intCast(m)));
            b.regions[i] = .{ .gpa = r.gpa, .size = r.size, .uaddr = r.uaddr, .host = base + r.mmap_offset, .map = base[0..len] };
            b.say("vhost: guest memory 0x{x}..0x{x} ({d} MiB)", .{ r.gpa, r.gpa + r.size, r.size >> 20 });
        }
        b.nregions = n;
    }

    /// QEMU's address of guest memory (the rings') as this process's.
    fn fromUser(b: *const Backend, uaddr: u64) ?[*]u8 {
        for (b.regions[0..b.nregions]) |r| {
            if (uaddr >= r.uaddr and uaddr < r.uaddr + r.size) return r.host + (uaddr - r.uaddr);
        }
        return null;
    }

    /// Guest-physical [gpa, gpa + len) as this process's memory, when it
    /// lies in one region.
    pub fn guestBytes(b: *const Backend, gpa: u64, len: u64) ?[]u8 {
        for (b.regions[0..b.nregions]) |r| {
            if (gpa >= r.gpa and len <= r.size and gpa - r.gpa <= r.size - len) return (r.host + (gpa - r.gpa))[0..len];
        }
        return null;
    }

    // ── Requests ───────────────────────────────────────────────────────────

    /// Every request the guest has made available on queue `qi`, handled.
    /// The queues read for `poll_us` after the last request, doorbells off.
    fn pollAwhile(b: *Backend, h: Handler) void {
        b.setNoNotify(true);
        var last = nowUs();
        while (nowUs() - last < b.poll_us) {
            var got: usize = 0;
            for (0..b.nqueues) |qi| got += b.drain(@intCast(qi), h);
            if (got != 0) last = nowUs() else std.atomic.spinLoopHint();
        }
        b.setNoNotify(false);
        fullFence();
        for (0..b.nqueues) |qi| _ = b.drain(@intCast(qi), h);
    }

    fn setNoNotify(b: *Backend, on: bool) void {
        for (b.queues[0..b.nqueues]) |q| {
            const used = q.used orelse continue;
            const flags: *volatile u16 = @ptrCast(@alignCast(used));
            flags.* = if (on) USED_NO_NOTIFY else 0;
        }
    }

    fn drain(b: *Backend, qi: u32, h: Handler) usize {
        const q = &b.queues[qi];
        if (!q.enabled or q.desc == null or q.avail == null or q.used == null or q.num == 0) return 0;
        var count: usize = 0;
        const avail = q.avail.?;
        const used_idx: *volatile u16 = @ptrCast(@alignCast(q.used.? + 2));
        const used_ring: [*]volatile UsedElem = @ptrCast(@alignCast(q.used.? + 4));
        var signal = false;
        while (true) {
            const avail_idx = avail[1];
            if (q.last_avail == avail_idx) break;
            const head = avail[2 + q.last_avail % q.num];
            var readable: [MAX_CHAIN][]const u8 = undefined;
            var writable: [MAX_CHAIN][]u8 = undefined;
            var nr: usize = 0;
            var nw: usize = 0;
            var i: u16 = head;
            var steps: usize = 0;
            while (steps < MAX_CHAIN) : (steps += 1) {
                if (i >= q.num) break;
                const d = q.desc.?[i];
                if (b.guestBytes(d.addr, d.len)) |bytes| {
                    if (d.flags & DESC_WRITE != 0) {
                        writable[nw] = bytes;
                        nw += 1;
                    } else {
                        readable[nr] = bytes;
                        nr += 1;
                    }
                }
                if (d.flags & DESC_NEXT == 0) break;
                i = d.next;
            }
            const written = h.request(h.ctx, qi, readable[0..nr], writable[0..nw]);
            const u = used_idx.*;
            used_ring[u % q.num] = .{ .id = head, .len = written };
            fullFence();
            used_idx.* = u +% 1;
            q.last_avail +%= 1;
            b.handled += 1;
            count += 1;
            signal = true;
        }
        if (signal and q.call >= 0) {
            var one: u64 = 1;
            _ = linux.write(q.call, @ptrCast(&one), 8);
        }
        return count;
    }
};

/// The used ring's flag that tells the driver not to ring (virtio 1.x).
const USED_NO_NOTIFY: u16 = 1;

fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

var fence_word: u32 = 0;
fn fullFence() void {
    _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst);
}

test "the protocol's layouts" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(MemRegion));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(VringAddr));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Desc));
}

test "guestBytes stays inside a region" {
    var mem: [8192]u8 align(4096) = undefined;
    var b = Backend{};
    b.regions[0] = .{ .gpa = 0x1000, .size = 4096, .uaddr = 0, .host = &mem };
    b.nregions = 1;
    try std.testing.expect(b.guestBytes(0x1000, 4096) != null);
    try std.testing.expect(b.guestBytes(0x1800, 2048) != null);
    try std.testing.expect(b.guestBytes(0x1800, 2049) == null);
    try std.testing.expect(b.guestBytes(0xfff, 2) == null);
}
