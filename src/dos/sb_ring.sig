//! A sound ring between emulated time and the host's audio: a device
//! pushes stereo frames at its own rate as time goes on (advance), the
//! host pulls them at its rate (audio). Linear interpolation between
//! frames; a ring that runs dry fades its last value out (no click); one
//! that fills past a few host periods drops its oldest frames, so the
//! delay stays short. The Sound Blaster, the OPL3 and the PC speaker each
//! keep one. No allocation: the frames are in the ring.

const std = @import("std");

/// Q12 unity gain.
pub const UNITY: i32 = 4096;

pub fn Ring(comptime N: u32) type {
    std.debug.assert(N & (N - 1) == 0);
    return struct {
        const Self = @This();

        buf: [N][2]i16 = [_][2]i16{.{ 0, 0 }} ** N,
        rd: u32 = 0,
        wr: u32 = 0,
        /// Position between buf[rd] and buf[rd + 1], in 1/65536 frames.
        frac: u32 = 0,
        last: [2]i32 = .{ 0, 0 },

        pub fn clear(self: *Self) void {
            self.rd = 0;
            self.wr = 0;
            self.frac = 0;
        }
        pub inline fn count(self: *const Self) u32 {
            return self.wr -% self.rd;
        }
        pub inline fn push(self: *Self, l: i16, r: i16) void {
            if (self.count() >= N) self.rd +%= 1;
            self.buf[self.wr & (N - 1)] = .{ l, r };
            self.wr +%= 1;
        }

        /// Adds the frames due into `out` (interleaved stereo at `rate`),
        /// read at `src_rate`, times the Q12 gains.
        pub fn mixInto(self: *Self, out: []i16, rate: u32, src_rate: u32, gain_l: i32, gain_r: i32) void {
            const frames = out.len / 2;
            if (frames == 0 or rate == 0) return;
            const step: u32 = if (src_rate == 0) 0 else @intCast(@min((@as(u64, src_rate) << 16) / rate, 1 << 24));
            const need: u64 = ((@as(u64, frames) * step + self.frac) >> 16) + 2;
            const avail = self.count();
            // Too far behind: drop the oldest, keep a little slack.
            if (avail > need * 2 + 512) {
                const keep: u32 = @intCast(need + 256);
                self.rd +%= avail - keep;
            }
            var i: usize = 0;
            while (i < frames) : (i += 1) {
                var v: [2]i32 = undefined;
                if (step != 0 and self.count() >= 2) {
                    const a = self.buf[self.rd & (N - 1)];
                    const b = self.buf[(self.rd +% 1) & (N - 1)];
                    const f: i32 = @intCast(self.frac >> 1);
                    v[0] = a[0] + (((@as(i32, b[0]) - a[0]) * f) >> 15);
                    v[1] = a[1] + (((@as(i32, b[1]) - a[1]) * f) >> 15);
                    self.last = v;
                    self.frac += step;
                    while (self.frac >= 0x10000 and self.count() >= 2) {
                        self.frac -= 0x10000;
                        self.rd +%= 1;
                    }
                    if (self.frac >= 0x10000) self.frac = 0xFFFF;
                } else {
                    // Dry: fade out.
                    self.last[0] -= self.last[0] >> 5;
                    self.last[1] -= self.last[1] >> 5;
                    if (self.last[0] > -32 and self.last[0] < 32) self.last[0] = 0;
                    if (self.last[1] > -32 and self.last[1] < 32) self.last[1] = 0;
                    v = self.last;
                }
                addSat(&out[i * 2], (v[0] * gain_l) >> 12);
                addSat(&out[i * 2 + 1], (v[1] * gain_r) >> 12);
            }
        }
    };
}

pub inline fn addSat(o: *i16, v: i32) void {
    const s = @as(i32, o.*) + v;
    o.* = @intCast(std.math.clamp(s, -32768, 32767));
}

pub inline fn sat16(v: i32) i16 {
    return @intCast(std.math.clamp(v, -32768, 32767));
}

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "sb_ring: resamples, fades out when dry, drops when behind" {
    var r: Ring(1024) = .{};
    var k: i16 = 0;
    while (k < 100) : (k += 1) r.push(k * 100, -k * 100);
    var out: [2 * 50]i16 = [_]i16{0} ** 100;
    // Twice the source rate: every other output frame is a midpoint.
    r.mixInto(&out, 22050, 11025, UNITY, UNITY);
    try t.expectEqual(@as(i16, 0), out[0]);
    try t.expectEqual(@as(i16, 50), out[2]);
    try t.expectEqual(@as(i16, 100), out[4]);
    try t.expectEqual(@as(i16, -100), out[5]);
    // Dry: the last value falls to silence without a step.
    r.clear();
    r.last = .{ 10000, 10000 };
    var dry: [2 * 400]i16 = [_]i16{0} ** 800;
    r.mixInto(&dry, 44100, 44100, UNITY, UNITY);
    try t.expect(dry[0] > 9000);
    try t.expect(dry[0] - dry[2] < 400);
    try t.expectEqual(@as(i16, 0), dry[798]);
    // Far behind: the ring keeps only what the next pulls need.
    k = 0;
    while (k < 1000) : (k += 1) r.push(1, 1);
    var small: [2 * 10]i16 = [_]i16{0} ** 20;
    r.mixInto(&small, 44100, 44100, UNITY, UNITY);
    try t.expect(r.count() < 600);
}
