//! Layer 0: deterministic MGTB balance / MGTM mint arithmetic. Caller-owned records,
//! integer-only, allocator-free. The host verifies the signer and account identity.
const game = @import("ledger_world");
const le = @import("solana_le");

pub const Key = game.Key; // [32]u8, re-exported for callers
pub const balance_size = 56;
pub const mint_size = 64; // 64-byte MGTM: cap u64 at offset 56

pub const Error = error{ InvalidLength, InvalidHeader, NonCanonical, Insufficient, Overflow, SupplyCapExceeded, Unauthorized };

/// `nonce` exists per the data model but is NOT serialized in MGTB v1 (decode sets 0).
pub const Balance = struct { authority: Key, world: u64, amount: u64, nonce: u64 = 0 };
pub const Mint = struct { world: u64, authority: Key, supply: u64, cap: u64 };

fn header(input: []const u8, length: usize, comptime magic: []const u8) Error!void {
    if (input.len != length) return error.InvalidLength;
    inline for (magic, 0..) |byte, i| if (byte != input[i]) return error.InvalidHeader;
    if (input[4] != 1) return error.InvalidHeader;
    if (input[5] != 0) return error.NonCanonical;
}

pub fn decodeBalanceInto(input: []const u8, out: *Balance) Error!void {
    try header(input, balance_size, "MGTB");
    if (input[6] != 0 or input[7] != 0) return error.NonCanonical;
    var authority: Key = undefined;
    @memcpy(&authority, input[16..48]);
    out.* = .{
        .authority = authority,
        .world = le.getLe(u64, input[8..16]),
        .amount = le.getLe(u64, input[48..56]),
        .nonce = 0,
    };
}

pub fn decodeMintInto(input: []const u8, out: *Mint) Error!void {
    try header(input, mint_size, "MGTM");
    if (input[6] != 0 or input[7] != 0) return error.NonCanonical;
    var authority: Key = undefined;
    @memcpy(&authority, input[16..48]);
    out.* = .{
        .world = le.getLe(u64, input[8..16]),
        .authority = authority,
        .supply = le.getLe(u64, input[48..56]),
        .cap = le.getLe(u64, input[56..64]),
    };
}

pub fn encodeBalance(b: Balance) [balance_size]u8 {
    var out: [balance_size]u8 = @splat(0);
    @memcpy(out[0..4], "MGTB");
    out[4] = 1;
    le.putLe(u64, out[8..16], b.world);
    @memcpy(out[16..48], &b.authority);
    le.putLe(u64, out[48..56], b.amount);
    return out;
}

pub fn encodeMint(m: Mint) [mint_size]u8 {
    var out: [mint_size]u8 = @splat(0);
    @memcpy(out[0..4], "MGTM");
    out[4] = 1;
    le.putLe(u64, out[8..16], m.world);
    @memcpy(out[16..48], &m.authority);
    le.putLe(u64, out[48..56], m.supply);
    le.putLe(u64, out[56..64], m.cap);
    return out;
}

/// All checks precede any mutation: a rejection leaves both records byte-for-byte unchanged.
pub fn transfer(from: *Balance, to: *Balance, amount: u64, signer: *const Key) Error!void {
    if (!game.sameKey(from.authority, signer.*)) return error.Unauthorized;
    if (amount > from.amount) return error.Insufficient;
    if (to.amount > 0xffffffffffffffff - amount) return error.Overflow;
    from.amount -= amount;
    to.amount += amount;
}

/// All checks precede any mutation: a rejection leaves mint and recipient unchanged.
pub fn mintTo(mint: *Mint, to: *Balance, amount: u64, signer: *const Key) Error!void {
    if (!game.sameKey(mint.authority, signer.*)) return error.Unauthorized;
    if (mint.supply > 0xffffffffffffffff - amount) return error.Overflow;
    if (mint.supply + amount > mint.cap) return error.SupplyCapExceeded;
    if (to.amount > 0xffffffffffffffff - amount) return error.Overflow;
    mint.supply += amount;
    to.amount += amount;
}
