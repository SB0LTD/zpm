//! @zpm/dxg fwd_server — the host's side of GPU forwarding (fwd.sig): each
//! request a guest makes, done on a Gpu.
//!
//! The guest's GPU window is reserved on the Gpu at `hello`. A `map` maps
//! the guest's own pages (found through `Guest`: the vhost-user memory
//! table) at the GPU address the guest chose, so the GPU reads and writes
//! guest RAM in place. Each channel is a dxg Channel (the 3D engine and
//! compute) whose fences the GPU also writes to the guest's status page.
//!
//! Allocation-free: the tables are fixed (MAX_MAPS, fwd.MAX_CHANNELS); the
//! rings' memory is the caller's (fwd.MAX_CHANNELS * gpu.RING_BYTES).

const std = @import("std");
const fwd = @import("fwd.sig");
const gpu = @import("gpu.sig");

pub const MAX_MAPS = 4096;

/// Guest-physical memory as this process's (null: not guest RAM, or not one
/// piece).
pub const Guest = struct {
    ctx: *anyopaque,
    bytes: *const fn (ctx: *anyopaque, gpa: u64, len: u64) ?[]u8,
};

pub const Server = struct {
    gpu: *gpu.Gpu,
    guest: Guest,
    rings: []align(4096) u8,
    window: bool = false,
    status_va: u64 = 0,
    status: gpu.Region = .{},
    chans: [fwd.MAX_CHANNELS]gpu.Channel = undefined,
    open: [fwd.MAX_CHANNELS]bool = [_]bool{false} ** fwd.MAX_CHANNELS,
    maps: [MAX_MAPS]gpu.Region = [_]gpu.Region{.{}} ** MAX_MAPS,
    /// Requests served, submissions, and the last refusal (for the log).
    served: u64 = 0,
    submits: u64 = 0,
    log: ?*const fn (line: []const u8) void = null,

    pub fn init(s: *Server, g: *gpu.Gpu, guest: Guest, rings: []align(4096) u8) void {
        s.* = .{ .gpu = g, .guest = guest, .rings = rings };
    }

    fn say(s: *Server, comptime fmt: []const u8, args: anytype) void {
        const l = s.log orelse return;
        var buf: [200]u8 = undefined;
        l(std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    /// A request, done; its answer.
    pub fn handle(s: *Server, r: fwd.Request) fwd.Response {
        s.served += 1;
        const op: fwd.Op = @enumFromInt(r.op);
        return switch (op) {
            .hello => s.hello(r),
            .status_page => s.statusPage(r),
            .map => s.map(r),
            .unmap => s.unmap(r),
            .open => s.openChannel(),
            .close => s.closeChannel(r.chan),
            .submit => s.submit(r),
            .state => s.state(r.chan),
            .map_video => s.mapVideo(r),
            _ => .{ .status = @intFromEnum(fwd.Status.invalid) },
        };
    }

    fn fail(st: fwd.Status) fwd.Response {
        return .{ .status = @intFromEnum(st) };
    }

    fn hello(s: *Server, r: fwd.Request) fwd.Response {
        if (r.a != fwd.VERSION) return fail(.invalid);
        if (!s.window) {
            s.gpu.reserve(fwd.WINDOW_START, fwd.WINDOW_END - fwd.WINDOW_START) catch {
                s.say("fwd: the GPU refused the guest's window", .{});
                return fail(.refused);
            };
            s.window = true;
        }
        s.say("fwd: hello from the guest (GPU {x}:{x})", .{ s.gpu.ids.vendor, s.gpu.ids.device });
        return .{ .a = @as(u64, s.gpu.ids.vendor) << 16 | s.gpu.ids.device, .b = fwd.WINDOW_START, .c = fwd.WINDOW_END };
    }

    /// The guest's pages [gpa, gpa + bytes) mapped at `va`.
    fn mapGuest(s: *Server, gpa: u64, va: u64, bytes: u64) ?gpu.Region {
        if (!s.window or !fwd.inWindow(va, bytes) or gpa % 4096 != 0) return null;
        const mem = s.guest.bytes(s.guest.ctx, gpa, bytes) orelse return null;
        const aligned: []align(4096) u8 = @alignCast(mem);
        return s.gpu.mapSystemAt(aligned, va) catch |e| {
            s.say("fwd: map 0x{x} ({d} KiB) at 0x{x}: {s}", .{ gpa, bytes >> 10, va, @errorName(e) });
            return null;
        };
    }

    fn statusPage(s: *Server, r: fwd.Request) fwd.Response {
        if (s.status.handle != 0) return fail(.busy);
        s.status = s.mapGuest(r.a, r.b, r.c) orelse return fail(.refused);
        s.status_va = r.b;
        return .{};
    }

    fn map(s: *Server, r: fwd.Request) fwd.Response {
        const slot = for (&s.maps) |*m| {
            if (m.handle == 0) break m;
        } else return fail(.busy);
        slot.* = s.mapGuest(r.a, r.b, r.c) orelse return fail(.refused);
        return .{ .a = slot.handle };
    }

    fn mapVideo(s: *Server, r: fwd.Request) fwd.Response {
        if (!s.window or !fwd.inWindow(r.b, r.c)) return fail(.invalid);
        const slot = for (&s.maps) |*m| {
            if (m.handle == 0) break m;
        } else return fail(.busy);
        slot.* = s.gpu.allocVideoAt(r.c, r.b) catch |e| {
            s.say("fwd: VRAM {d} KiB at 0x{x}: {s}", .{ r.c >> 10, r.b, @errorName(e) });
            return fail(.refused);
        };
        return .{ .a = slot.handle };
    }

    fn unmap(s: *Server, r: fwd.Request) fwd.Response {
        for (&s.maps) |*m| {
            if (m.handle == 0 or m.va != r.a) continue;
            s.gpu.release(m.*);
            m.* = .{};
            return .{};
        }
        return fail(.invalid);
    }

    fn openChannel(s: *Server) fwd.Response {
        if (s.status_va == 0) return fail(.invalid);
        var k: u32 = 1;
        while (k < fwd.MAX_CHANNELS) : (k += 1) {
            if (s.open[k]) continue;
            const ring: []align(4096) u8 = @alignCast(s.rings[k * gpu.RING_BYTES ..][0..gpu.RING_BYTES]);
            s.chans[k].open(s.gpu, ring, .{ .name = "galaxy-vm", .notify = s.status_va + fwd.fenceOffset(k) }) catch |e| {
                s.say("fwd: channel {d}: {s}", .{ k, @errorName(e) });
                return fail(.refused);
            };
            s.open[k] = true;
            s.say("fwd: channel {d} open", .{k});
            return .{ .chan = k };
        }
        return fail(.busy);
    }

    fn channel(s: *Server, k: u32) ?*gpu.Channel {
        if (k == 0 or k >= fwd.MAX_CHANNELS or !s.open[k]) return null;
        return &s.chans[k];
    }

    fn closeChannel(s: *Server, k: u32) fwd.Response {
        const c = s.channel(k) orelse return fail(.invalid);
        c.close();
        s.open[k] = false;
        return .{};
    }

    fn submit(s: *Server, r: fwd.Request) fwd.Response {
        const c = s.channel(r.chan) orelse return fail(.invalid);
        if (c.lost()) return fail(.lost);
        if (r.b == 0 or r.b > 0x1f_ffff or r.a < fwd.WINDOW_START or r.a >= fwd.WINDOW_END) return fail(.invalid);
        const f = c.submit(r.a, @intCast(r.b)) catch return fail(.refused);
        s.submits += 1;
        return .{ .chan = r.chan, .a = f };
    }

    fn state(s: *Server, k: u32) fwd.Response {
        const c = s.channel(k) orelse return fail(.invalid);
        return .{ .chan = k, .a = c.completed(), .b = @intFromBool(c.lost()) };
    }

    /// Everything the guest had, given back (it went away).
    pub fn reset(s: *Server) void {
        for (&s.open, 0..) |*o, k| {
            if (!o.*) continue;
            s.chans[k].close();
            o.* = false;
        }
        for (&s.maps) |*m| {
            if (m.handle != 0) s.gpu.release(m.*);
            m.* = .{};
        }
        if (s.status.handle != 0) s.gpu.release(s.status);
        s.status = .{};
        s.status_va = 0;
    }
};
