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

/// A video channel's fence pushbuffers: 64 KiB of its ring memory, slots of
/// 32 bytes (a submission's fence is read by the engine after the guest's
/// work: one slot a submission, reused 2048 submissions on).
pub const VIDEO_FENCE_BYTES = 64 << 10;
pub const VIDEO_FENCE_SLOT = 32;

/// A video engine's fence: its semaphore release of `value` (32 bits) at
/// `va` (NVDEC's and NVENC's SEMAPHORE_A..C and SEMAPHORE_D: release, one
/// word), on subchannel 4.
pub fn videoFence(va: u64, value: u32) [8]u32 {
    const sub = @import("nv.sig").VIDEO_SUBCH;
    return .{
        hdr(sub, 0x240), @truncate(va >> 32),
        hdr(sub, 0x244), @truncate(va),
        hdr(sub, 0x248), value,
        hdr(sub, 0x304), 0,
    };
}

fn hdr(sub: u32, method: u32) u32 {
    return (1 << 29) | (1 << 16) | (sub << 13) | (method >> 2);
}

test "fwd_server: a video channel's fence pushbuffer" {
    const w = videoFence(0x40_0000_1008, 7);
    try std.testing.expectEqual(@as(u32, 0x2001_8090), w[0]);
    try std.testing.expectEqual(@as(u32, 0x40), w[1]);
    try std.testing.expectEqual(@as(u32, 0x1008), w[3]);
    try std.testing.expectEqual(@as(u32, 7), w[5]);
    try std.testing.expectEqual(@as(u32, 0x2001_80c1), w[6]);
}

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
    /// A video channel's (fwd.Engine.decoder, .encoder): its engine's own
    /// context (gpu.VideoChannel), the ring memory's first page mapped for
    /// the fence pushbuffers written after each submission, the last fence.
    video: [fwd.MAX_CHANNELS]bool = [_]bool{false} ** fwd.MAX_CHANNELS,
    vchans: [fwd.MAX_CHANNELS]gpu.VideoChannel = undefined,
    vfence_pb: [fwd.MAX_CHANNELS]gpu.Region = [_]gpu.Region{.{}} ** fwd.MAX_CHANNELS,
    vfence: [fwd.MAX_CHANNELS]u32 = [_]u32{0} ** fwd.MAX_CHANNELS,
    maps: [MAX_MAPS]gpu.Region = [_]gpu.Region{.{}} ** MAX_MAPS,
    /// Requests served, submissions, and the last refusal (for the log).
    served: u64 = 0,
    submits: u64 = 0,
    log: ?*const fn (line: []const u8) void = null,
    /// Channels whose loss the log has told.
    told: [fwd.MAX_CHANNELS]bool = [_]bool{false} ** fwd.MAX_CHANNELS,

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
            .open => s.openChannel(r.a),
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

    fn openChannel(s: *Server, engine: u64) fwd.Response {
        if (s.status_va == 0) return fail(.invalid);
        const want: fwd.Engine = @enumFromInt(engine);
        if (want != .graphics and want != .decoder and want != .encoder) return fail(.invalid);
        var k: u32 = 1;
        while (k < fwd.MAX_CHANNELS) : (k += 1) {
            if (s.open[k]) continue;
            const ring: []align(4096) u8 = @alignCast(s.rings[k * gpu.RING_BYTES ..][0..gpu.RING_BYTES]);
            if (want != .graphics) return s.openVideo(k, ring, if (want == .decoder) .decoder else .encoder);
            s.chans[k].open(s.gpu, ring, .{ .name = "galaxy-vm", .notify = s.status_va + fwd.fenceOffset(k) }) catch |e| {
                s.say("fwd: channel {d}: {s}", .{ k, @errorName(e) });
                return fail(.refused);
            };
            s.open[k] = true;
            s.told[k] = false;
            s.say("fwd: channel {d} open", .{k});
            return .{ .chan = k };
        }
        return fail(.busy);
    }

    /// Channel `k` a video engine's: its context, and a page of the ring
    /// memory (unused by it otherwise) for the fence pushbuffers.
    fn openVideo(s: *Server, k: u32, ring: []align(4096) u8, e: @import("nv.sig").VideoEngine) fwd.Response {
        s.vchans[k].open(s.gpu, e) catch |err| {
            s.say("fwd: channel {d} ({s}): {s}", .{ k, @tagName(e), @errorName(err) });
            return fail(.refused);
        };
        s.vfence_pb[k] = s.gpu.mapSystem(ring[0..VIDEO_FENCE_BYTES]) catch |err| {
            s.vchans[k].close();
            s.say("fwd: channel {d} ({s}): its fence page: {s}", .{ k, @tagName(e), @errorName(err) });
            return fail(.refused);
        };
        s.vfence[k] = 0;
        s.open[k] = true;
        s.video[k] = true;
        s.told[k] = false;
        s.say("fwd: channel {d} open: the video {s}", .{ k, @tagName(e) });
        return .{ .chan = k };
    }

    fn channel(s: *Server, k: u32) ?*gpu.Channel {
        if (k == 0 or k >= fwd.MAX_CHANNELS or !s.open[k] or s.video[k]) return null;
        return &s.chans[k];
    }

    fn closeChannel(s: *Server, k: u32) fwd.Response {
        if (k != 0 and k < fwd.MAX_CHANNELS and s.open[k] and s.video[k]) {
            s.closeVideo(k);
            return .{};
        }
        const c = s.channel(k) orelse return fail(.invalid);
        c.close();
        s.open[k] = false;
        return .{};
    }

    fn closeVideo(s: *Server, k: u32) void {
        s.vchans[k].close();
        s.gpu.release(s.vfence_pb[k]);
        s.vfence_pb[k] = .{};
        s.open[k] = false;
        s.video[k] = false;
    }

    /// A video channel's submission: the guest's pushbuffer, then the fence
    /// (the engine's semaphore release of the channel's next fence to its
    /// word in the status page, on subchannel 4: the host's own binding of
    /// the engine, beside the guest's on 0), each a submit_command.
    fn submitVideo(s: *Server, k: u32, r: fwd.Request) fwd.Response {
        s.vchans[k].submit(r.a, @intCast(r.b)) catch {
            s.say("fwd: channel {d} (video): submit refused, status {d}", .{ k, @import("kmt.sig").last_status });
            return fail(.refused);
        };
        s.vfence[k] +%= 1;
        const f = s.vfence[k];
        const slot = f % (VIDEO_FENCE_BYTES / VIDEO_FENCE_SLOT);
        const pb: [*]volatile u32 = @ptrCast(@alignCast(s.vfence_pb[k].cpu.ptr + slot * VIDEO_FENCE_SLOT));
        const at = s.status_va + fwd.fenceOffset(k);
        const words = videoFence(at, f);
        for (words, 0..) |w, i| pb[i] = w;
        s.vchans[k].submit(s.vfence_pb[k].va + slot * VIDEO_FENCE_SLOT, words.len) catch return fail(.refused);
        s.submits += 1;
        return .{ .chan = k, .a = f };
    }

    /// Channel `k` found lost: what dxgkrnl says of it, in the log (once).
    fn sayLost(s: *Server, k: u32) void {
        if (k >= fwd.MAX_CHANNELS or s.told[k]) return;
        s.told[k] = true;
        const c = &s.chans[k];
        if (s.gpu.fault()) |f| {
            s.say("fwd: channel {d} lost at fence {d} (submitted {d}): device execution state {d}, page fault at 0x{x} (stage {d}, flags 0x{x}, code 0x{x})", .{ k, c.completed(), c.fence, f.execution, f.va, f.stage, f.flags, f.code });
        } else s.say("fwd: channel {d} lost at fence {d} (submitted {d}); no device state", .{ k, c.completed(), c.fence });
    }

    fn submit(s: *Server, r: fwd.Request) fwd.Response {
        if (r.chan != 0 and r.chan < fwd.MAX_CHANNELS and s.open[r.chan] and s.video[r.chan]) {
            if (r.b == 0 or r.b > 0x1f_ffff or r.a < fwd.WINDOW_START or r.a >= fwd.WINDOW_END) return fail(.invalid);
            return s.submitVideo(r.chan, r);
        }
        const c = s.channel(r.chan) orelse return fail(.invalid);
        if (c.lost()) {
            s.sayLost(r.chan);
            return fail(.lost);
        }
        if (r.b == 0 or r.b > 0x1f_ffff or r.a < fwd.WINDOW_START or r.a >= fwd.WINDOW_END) return fail(.invalid);
        const f = c.submit(r.a, @intCast(r.b)) catch return fail(.refused);
        s.submits += 1;
        return .{ .chan = r.chan, .a = f };
    }

    fn state(s: *Server, k: u32) fwd.Response {
        if (k != 0 and k < fwd.MAX_CHANNELS and s.open[k] and s.video[k]) {
            // (the host keeps no fence of a video channel's: its word in
            // the status page is the one; no loss is seen from here)
            const w: u32 = if (s.status.cpu.len >= fwd.fenceOffset(k) + 4) std.mem.readInt(u32, s.status.cpu[fwd.fenceOffset(k)..][0..4], .little) else 0;
            return .{ .chan = k, .a = w };
        }
        const c = s.channel(k) orelse return fail(.invalid);
        if (c.lost()) s.sayLost(k);
        return .{ .chan = k, .a = c.completed(), .b = @intFromBool(c.lost()) };
    }

    /// Everything the guest had, given back (it went away).
    pub fn reset(s: *Server) void {
        for (&s.open, 0..) |*o, k| {
            if (!o.*) continue;
            if (s.video[k]) {
                s.closeVideo(@intCast(k));
                continue;
            }
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
