const std = @import("std");
const game = @import("ledger_world");
const aw = @import("action_wire");
const le = @import("solana_le");
const mesh = @import("mesh_wire");
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
fn randKey(s: *u64) game.Key {
    var key: game.Key = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) key[i] = @truncate(nextU64(s));
    return key;
}
pub fn main(init: std.process.Init) !void {
    var seed: u64 = 0x7777_1234_ABCD_0001;
    const s = &seed;

    // Feature: distributed-mmorpg-infrastructure, Property 2: signed state updates round-trip through the gossip wire.
    // Feature: distributed-mmorpg-infrastructure, Property 7: canonical records round-trip and reject malformed input.
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            // Opaque 60-byte action block: need NOT be a valid action_wire action.
            var action: [mesh.action_size]u8 = undefined;
            var a: usize = 0;
            while (a < mesh.action_size) : (a += 1) action[a] = @truncate(nextU64(s));
            // 64-byte opaque signature carried verbatim; no Ed25519 verification happens here.
            var sig: [mesh.sig_size]u8 = undefined;
            var g: usize = 0;
            while (g < mesh.sig_size) : (g += 1) sig[g] = @truncate(nextU64(s));
            const header: mesh.GossipHeader = .{ .world = nextU64(s), .region = @truncate(nextU64(s)), .sender = randKey(s), .nonce = nextU64(s), .kind = 0 };
            var bytes = mesh.encodeGossip(header, action, sig);
            var out: mesh.GossipHeader = undefined;
            var action_out: [mesh.action_size]u8 = undefined;
            var sig_out: [mesh.sig_size]u8 = undefined;
            try mesh.decodeGossipInto(&bytes, &out, &action_out, &sig_out);
            // Header equality EXCLUDES kind (kind is decode-derived from action[1]).
            try check(out.world == header.world and out.region == header.region and out.nonce == header.nonce and game.sameKey(out.sender, header.sender));
            try check(std.mem.eql(u8, &action_out, &action) and std.mem.eql(u8, &sig_out, &sig));
            try check(out.kind == action[1]);

            // FR2.7 precedence for MGGP.
            try rejects(error.InvalidLength, mesh.decodeGossipInto(bytes[0..183], &out, &action_out, &sig_out));
            var bad_magic = bytes;
            bad_magic[0] = 'X';
            try rejects(error.NonCanonical, mesh.decodeGossipInto(&bad_magic, &out, &action_out, &sig_out));
            var bad_ver = bytes;
            bad_ver[4] = 2;
            try rejects(error.InvalidVersion, mesh.decodeGossipInto(&bad_ver, &out, &action_out, &sig_out));
            var r5 = bytes;
            r5[5] = 1;
            try rejects(error.NonCanonical, mesh.decodeGossipInto(&r5, &out, &action_out, &sig_out));
            var r6 = bytes;
            r6[6] = 1;
            try rejects(error.NonCanonical, mesh.decodeGossipInto(&r6, &out, &action_out, &sig_out));
        }
    }

    // Feature: distributed-mmorpg-infrastructure, Property 7 (MGCK): batch header round-trips and enforces the transition cap.
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const count: u16 = @truncate(nextU64(s) % (mesh.max_transitions + 1));
            const h: mesh.BatchHeader = .{ .world = nextU64(s), .interval = nextU64(s), .base_slot = nextU64(s), .count = count };
            const hdr = mesh.encodeBatchHeader(h);
            // Build a full buffer: header + count*transition_size (all zero payload is fine; opaque).
            const total: usize = mesh.batch_header_size + @as(usize, count) * mesh.transition_size;
            var buf: [mesh.batch_header_size + mesh.max_transitions * mesh.transition_size]u8 = @splat(0);
            @memcpy(buf[0..mesh.batch_header_size], &hdr);
            var out: mesh.BatchHeader = undefined;
            try mesh.decodeBatchHeaderInto(buf[0..total], &out);
            try check(out.world == h.world and out.interval == h.interval and out.base_slot == h.base_slot and out.count == count);

            // count > max_transitions -> TooManyTransitions, even when total length is also wrong.
            var over = hdr;
            le.putLe(u16, over[6..8], mesh.max_transitions + 1);
            try rejects(error.TooManyTransitions, mesh.decodeBatchHeaderInto(&over, &out));

            // valid-cap count but non-matching total length -> InvalidLength.
            if (count > 0) {
                try rejects(error.InvalidLength, mesh.decodeBatchHeaderInto(buf[0 .. total - 1], &out));
            }

            // reserved byte 5 nonzero -> NonCanonical.
            var r5 = hdr;
            r5[5] = 1;
            try rejects(error.NonCanonical, mesh.decodeBatchHeaderInto(&r5, &out));
            // bad magic -> NonCanonical.
            var bad_magic = hdr;
            bad_magic[0] = 'X';
            try rejects(error.NonCanonical, mesh.decodeBatchHeaderInto(&bad_magic, &out));
            // bad version -> InvalidVersion.
            var bad_ver = hdr;
            bad_ver[4] = 2;
            try rejects(error.InvalidVersion, mesh.decodeBatchHeaderInto(&bad_ver, &out));
            // too short to read header -> InvalidLength.
            try rejects(error.InvalidLength, mesh.decodeBatchHeaderInto(hdr[0..31], &out));
        }
    }

    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "ZPM mesh-wire contracts PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
