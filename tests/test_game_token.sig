const std = @import("std");
const game = @import("ledger_world");
const le = @import("solana_le");
const token = @import("game_token");
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
fn eqKey(a: game.Key, b: game.Key) bool {
    return game.sameKey(a, b);
}
pub fn main(init: std.process.Init) !void {
    var seed: u64 = 0x5151_5151_A5A5_A5A5;
    const s = &seed;

    // Feature: distributed-mmorpg-infrastructure, Property 7: canonical records round-trip and reject malformed input.
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const authority = randKey(s);
            const b: token.Balance = .{ .authority = authority, .world = nextU64(s), .amount = nextU64(s), .nonce = nextU64(s) };
            var bytes = token.encodeBalance(b);
            var decoded: token.Balance = undefined;
            try token.decodeBalanceInto(&bytes, &decoded);
            try check(eqKey(decoded.authority, b.authority) and decoded.world == b.world and decoded.amount == b.amount and decoded.nonce == 0);
            // reserved byte 5 nonzero -> NonCanonical
            var r5 = bytes;
            r5[5] = 1;
            try rejects(error.NonCanonical, token.decodeBalanceInto(&r5, &decoded));
            // reserved u16 at 6..7 nonzero -> NonCanonical
            var r6 = bytes;
            r6[6] = 1;
            try rejects(error.NonCanonical, token.decodeBalanceInto(&r6, &decoded));
            // corrupt magic -> InvalidHeader
            var bad_magic = bytes;
            bad_magic[0] = 'X';
            try rejects(error.InvalidHeader, token.decodeBalanceInto(&bad_magic, &decoded));
            // bad version -> InvalidHeader
            var bad_ver = bytes;
            bad_ver[4] = 2;
            try rejects(error.InvalidHeader, token.decodeBalanceInto(&bad_ver, &decoded));
            // truncate -> InvalidLength
            try rejects(error.InvalidLength, token.decodeBalanceInto(bytes[0..55], &decoded));

            const m: token.Mint = .{ .world = nextU64(s), .authority = authority, .supply = nextU64(s), .cap = nextU64(s) };
            var mbytes = token.encodeMint(m);
            var mdecoded: token.Mint = undefined;
            try token.decodeMintInto(&mbytes, &mdecoded);
            try check(eqKey(mdecoded.authority, m.authority) and mdecoded.world == m.world and mdecoded.supply == m.supply and mdecoded.cap == m.cap);
            var mr5 = mbytes;
            mr5[5] = 1;
            try rejects(error.NonCanonical, token.decodeMintInto(&mr5, &mdecoded));
            var mbad_magic = mbytes;
            mbad_magic[0] = 'X';
            try rejects(error.InvalidHeader, token.decodeMintInto(&mbad_magic, &mdecoded));
            var mbad_ver = mbytes;
            mbad_ver[4] = 2;
            try rejects(error.InvalidHeader, token.decodeMintInto(&mbad_ver, &mdecoded));
            try rejects(error.InvalidLength, token.decodeMintInto(mbytes[0..63], &mdecoded));
        }
    }

    // Feature: distributed-mmorpg-infrastructure, Property 8: token supply is conserved across every accepted transfer.
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const authority = randKey(s);
            const from_amount = nextU64(s);
            // amount <= from_amount; force the full-sweep boundary (amount == from_amount) once per batch.
            const amount = if (i % 8 == 0) from_amount else (if (from_amount == 0) 0 else nextU64(s) % (from_amount + 1));
            // keep recipient amount small enough to avoid overflow for this leg.
            const to_amount = nextU64(s) % 0x1_0000_0000;
            var from: token.Balance = .{ .authority = authority, .world = 1, .amount = from_amount, .nonce = 0 };
            var to: token.Balance = .{ .authority = randKey(s), .world = 1, .amount = to_amount, .nonce = 0 };
            const before = from.amount + to.amount;
            try token.transfer(&from, &to, amount, &authority);
            try check(from.amount + to.amount == before);
            try check(from.amount == from_amount - amount and to.amount == to_amount + amount);
        }
    }

    // Feature: distributed-mmorpg-infrastructure, Property 9: no transfer produces a negative balance or integer overflow.
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const authority = randKey(s);
            // Insufficient: amount strictly greater than balance, both unchanged.
            const bal = nextU64(s) % 0x1_0000_0000;
            const over = bal + 1 + (nextU64(s) % 0x1_0000_0000);
            var from: token.Balance = .{ .authority = authority, .world = 1, .amount = bal, .nonce = 0 };
            var to: token.Balance = .{ .authority = randKey(s), .world = 1, .amount = 0, .nonce = 0 };
            const from_snap = token.encodeBalance(from);
            const to_snap = token.encodeBalance(to);
            try rejects(error.Insufficient, token.transfer(&from, &to, over, &authority));
            // Property 4 (atomic rollback): bytes unchanged after rejection.
            try check(std.mem.eql(u8, &token.encodeBalance(from), &from_snap) and std.mem.eql(u8, &token.encodeBalance(to), &to_snap));

            // amount == from.amount is accepted (not Insufficient).
            var sweep_from: token.Balance = .{ .authority = authority, .world = 1, .amount = bal, .nonce = 0 };
            var sweep_to: token.Balance = .{ .authority = randKey(s), .world = 1, .amount = 0, .nonce = 0 };
            try token.transfer(&sweep_from, &sweep_to, bal, &authority);
            try check(sweep_from.amount == 0 and sweep_to.amount == bal);

            // Overflow: recipient near u64 max.
            const credit = 1 + (nextU64(s) % 0xffff);
            var of_from: token.Balance = .{ .authority = authority, .world = 1, .amount = credit, .nonce = 0 };
            var of_to: token.Balance = .{ .authority = randKey(s), .world = 1, .amount = 0xffffffffffffffff - credit + 1, .nonce = 0 };
            const of_from_snap = token.encodeBalance(of_from);
            const of_to_snap = token.encodeBalance(of_to);
            try rejects(error.Overflow, token.transfer(&of_from, &of_to, credit, &authority));
            try check(std.mem.eql(u8, &token.encodeBalance(of_from), &of_from_snap) and std.mem.eql(u8, &token.encodeBalance(of_to), &of_to_snap));
        }
    }

    // Feature: distributed-mmorpg-infrastructure, Property 10: mints respect authority and never exceed the supply cap.
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const authority = randKey(s);
            const stranger = randKey(s);
            const cap = nextU64(s) % 0x1_0000_0000 + 1;
            const supply = nextU64(s) % cap;
            const amount = nextU64(s) % 0x1_0000;
            var mint: token.Mint = .{ .world = 1, .authority = authority, .supply = supply, .cap = cap };
            var to: token.Balance = .{ .authority = randKey(s), .world = 1, .amount = 0, .nonce = 0 };

            // Unauthorized leg: supply unchanged.
            if (!eqKey(stranger, authority)) {
                const mint_snap = token.encodeMint(mint);
                try rejects(error.Unauthorized, token.mintTo(&mint, &to, amount, &stranger));
                try check(std.mem.eql(u8, &token.encodeMint(mint), &mint_snap));
            }

            if (supply + amount <= cap) {
                try token.mintTo(&mint, &to, amount, &authority);
                try check(mint.supply == supply + amount and to.amount == amount);
                try check(mint.supply <= mint.cap);
            } else {
                const mint_snap = token.encodeMint(mint);
                try rejects(error.SupplyCapExceeded, token.mintTo(&mint, &to, amount, &authority));
                try check(std.mem.eql(u8, &token.encodeMint(mint), &mint_snap));
            }

            // multi-mint sequence keeps supply <= cap.
            var cap_mint: token.Mint = .{ .world = 1, .authority = authority, .supply = 0, .cap = 10 };
            var cap_to: token.Balance = .{ .authority = randKey(s), .world = 1, .amount = 0, .nonce = 0 };
            var k: usize = 0;
            while (k < 20) : (k += 1) {
                const step = nextU64(s) % 4;
                if (token.mintTo(&cap_mint, &cap_to, step, &authority)) {
                    try check(cap_mint.supply <= cap_mint.cap);
                } else |_| {
                    try check(cap_mint.supply <= cap_mint.cap);
                }
            }
        }
    }

    // Feature: distributed-mmorpg-infrastructure, Property 11: only the custody authority can move balances.
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const authority = randKey(s);
            const signer = if (i % 2 == 0) authority else randKey(s);
            var from: token.Balance = .{ .authority = authority, .world = 1, .amount = 1000, .nonce = 0 };
            var to: token.Balance = .{ .authority = randKey(s), .world = 1, .amount = 0, .nonce = 0 };
            const from_snap = token.encodeBalance(from);
            const to_snap = token.encodeBalance(to);
            if (eqKey(signer, authority)) {
                try token.transfer(&from, &to, 100, &signer);
                try check(from.amount == 900 and to.amount == 100);
            } else {
                try rejects(error.Unauthorized, token.transfer(&from, &to, 100, &signer));
                // Property 4: atomic rollback on unauthorized transfer.
                try check(std.mem.eql(u8, &token.encodeBalance(from), &from_snap) and std.mem.eql(u8, &token.encodeBalance(to), &to_snap));
            }
        }
    }

    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "ZPM game-token contracts PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
