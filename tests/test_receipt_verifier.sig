const std = @import("std");
const rv = @import("receipt_verifier");
var assertions: usize = 0;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.ContractFailed;
}
fn rejects(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAccepted else |actual| try check(actual == expected);
}
fn nextU64(s: *u64) u64 {
    s.* +%= 0x9E3779B97F4A7C15;
    var z = s.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}
fn randHash(s: *u64) [32]u8 {
    var h: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) h[i] = @truncate(nextU64(s));
    return h;
}
fn snapshot(r: rv.Receipt) [34]u8 {
    var out: [34]u8 = undefined;
    @memcpy(out[0..32], &r.action_hash);
    out[32] = @intFromBool(r.bound);
    out[33] = @intFromBool(r.consumed);
    return out;
}
pub fn main(init: std.process.Init) !void {
    var seed: u64 = 0x1357_9BDF_2468_ACE0;
    const s = &seed;

    // Feature: distributed-mmorpg-infrastructure, Property 17: a receipt binds exactly one action and is consumed at most once (single-use).
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const expected = randHash(s);
            // consume before any bind -> Unbound; receipt unchanged.
            var unbound: rv.Receipt = .{ .action_hash = @splat(0) };
            const unbound_snap = snapshot(unbound);
            try rejects(error.Unbound, rv.consume(&unbound, &expected));
            try check(std.mem.eql(u8, &snapshot(unbound), &unbound_snap));

            // bind with a mismatching callback -> WrongAction; receipt unchanged.
            const mismatch = randHash(s);
            if (!std.mem.eql(u8, &mismatch, &expected)) {
                var r: rv.Receipt = .{ .action_hash = @splat(0) };
                const r_snap = snapshot(r);
                try rejects(error.WrongAction, rv.bind(&r, &mismatch, &expected));
                try check(std.mem.eql(u8, &snapshot(r), &r_snap));
            }

            // bind with a matching callback -> success; then consume the same action succeeds.
            var r: rv.Receipt = .{ .action_hash = @splat(0) };
            try rv.bind(&r, &expected, &expected);
            try check(r.bound and !r.consumed and std.mem.eql(u8, &r.action_hash, &expected));

            // second bind -> AlreadyConsumed; recorded hash unchanged.
            const other = randHash(s);
            const bound_snap = snapshot(r);
            try rejects(error.AlreadyConsumed, rv.bind(&r, &other, &other));
            try check(std.mem.eql(u8, &snapshot(r), &bound_snap));

            // consume with a different action after bind -> WrongAction; receipt unchanged.
            if (!std.mem.eql(u8, &other, &expected)) {
                const pre = snapshot(r);
                try rejects(error.WrongAction, rv.consume(&r, &other));
                try check(std.mem.eql(u8, &snapshot(r), &pre));
            }

            // first matching consume -> success (effect becomes valid).
            try rv.consume(&r, &expected);
            try check(r.consumed);

            // second consume of a bound-and-consumed receipt -> AlreadyConsumed (single-use).
            const consumed_snap = snapshot(r);
            try rejects(error.AlreadyConsumed, rv.consume(&r, &expected));
            try check(std.mem.eql(u8, &snapshot(r), &consumed_snap));
        }
    }

    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "ZPM receipt-verifier contracts PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
