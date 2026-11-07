//! Native OS CSPRNG contract. Distribution observations are sanity checks,
//! not a claim that statistical testing proves cryptographic quality.
const std = @import("std");
const builtin = @import("builtin");
const entropy = @import("entropy");
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.EntropyContractFailed;
}

pub fn main(init: std.process.Init) !void {
    var empty: [0]u8 = .{};
    try entropy.fill(&empty);
    try check(true);
    if (builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos) {
        var previous: [32]u8 = @splat(0);
        var current: [32]u8 = @splat(0);
        // Each accepted connection obtains a new 256-bit SCRAM nonce. A
        // duplicate here would expose a deterministic/reused nonce path.
        for (0..1024) |_| {
            try entropy.fill(&current);
            try check(!std.mem.eql(u8, &previous, &current));
            previous = current;
        }
        var guarded: [4098]u8 = @splat(0xa5);
        try entropy.fill(guarded[1 .. guarded.len - 1]);
        try check(guarded[0] == 0xa5 and guarded[guarded.len - 1] == 0xa5);
        var histogram: [256]u16 = @splat(0);
        for (guarded[1 .. guarded.len - 1]) |c| histogram[c] += 1;
        var present: usize = 0;
        for (histogram) |count| if (count != 0) {
            present += 1;
        };
        try check(present > 200);
        // Exercise empty and odd buffer sizes around the Linux 256-byte chunk.
        for ([_]usize{ 0, 1, 15, 16, 23, 24, 31, 32, 255, 256, 257, 511, 512, 513, 4096 }) |len| {
            @memset(&guarded, 0xa5);
            try entropy.fill(guarded[1..][0..len]);
            try check(guarded[0] == 0xa5 and guarded[len + 1] == 0xa5);
        }
    } else {
        var unsupported: [8]u8 = @splat(0xa5);
        if (entropy.fill(&unsupported)) |_| return error.UnsupportedEntropyAccepted else |err| try check(err == error.UnsupportedPlatform);
        for (unsupported) |c| try check(c == 0);
    }
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"entropy\",\"pass\":true,\"assertions\":{d},\"os\":\"{s}\"}}\n", .{ assertions, @tagName(builtin.os.tag) });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
