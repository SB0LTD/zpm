//! Off-chain allocator-free signing, PDA derivation and bounded legacy transactions.
//! No RPC, renderer, filesystem or on-chain syscall dependency.
const std = @import("std");
pub const Key = [32]u8;
pub const MAX_TRANSACTION = 1232;
pub const Meta = struct { key: Key, writable: bool };
pub const Error = error{ Capacity, DuplicateAccount, InvalidSeed, SigningFailed, TooManySeeds, SeedTooLong, NoViableBump };
pub const Wallet = struct {
    pair: std.crypto.sign.Ed25519.KeyPair,
    pub fn fromSeed(seed: Key) Error!Wallet {
        return .{ .pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidSeed };
    }
    pub fn publicKey(self: *const Wallet) Key {
        return self.pair.public_key.toBytes();
    }
    /// Exactly one signer (the payer), one instruction and caller-owned output.
    pub fn transaction(self: *const Wallet, program: Key, blockhash: Key, metas: []const Meta, data: []const u8, output: []u8) Error!usize {
        if (metas.len > 8 or data.len > 1000) return error.Capacity;
        const payer = self.publicKey();
        if (std.mem.eql(u8, &payer, &program)) return error.DuplicateAccount;
        var keys: [10]Key = undefined;
        keys[0] = payer;
        var count: usize = 1;
        var readonly: u8 = 1;
        inline for (.{ true, false }) |writable| for (metas, 0..) |meta, i| {
            for (metas[0..i]) |previous| if (std.mem.eql(u8, &previous.key, &meta.key)) return error.DuplicateAccount;
            if (std.mem.eql(u8, &meta.key, &program)) return error.DuplicateAccount;
            if (meta.writable != writable or std.mem.eql(u8, &meta.key, &payer)) continue;
            keys[count] = meta.key;
            count += 1;
            if (!writable) readonly += 1;
        };
        const program_index: u8 = @intCast(count);
        keys[count] = program;
        count += 1;
        var packet: [MAX_TRANSACTION]u8 = undefined;
        var writer = Writer{ .out = &packet, .pos = 65 };
        try writer.bytes(&.{ 1, 0, readonly });
        try writer.short(count);
        for (keys[0..count]) |key| try writer.bytes(&key);
        try writer.bytes(&blockhash);
        try writer.short(1);
        try writer.bytes(&.{program_index});
        try writer.short(metas.len);
        for (metas) |meta| {
            for (keys[0..count], 0..) |key, index| if (std.mem.eql(u8, &key, &meta.key)) {
                try writer.bytes(&.{@intCast(index)});
                break;
            };
        }
        try writer.short(data.len);
        try writer.bytes(data);
        if (writer.pos > output.len) return error.Capacity;
        const signature = self.pair.sign(packet[65..writer.pos], null) catch return error.SigningFailed;
        packet[0] = 1;
        @memcpy(packet[1..65], &signature.toBytes());
        @memcpy(output[0..writer.pos], packet[0..writer.pos]);
        return writer.pos;
    }
};
const Writer = struct {
    out: []u8,
    pos: usize = 0,
    fn bytes(self: *Writer, value: []const u8) Error!void {
        if (value.len > self.out.len - self.pos) return error.Capacity;
        @memcpy(self.out[self.pos..][0..value.len], value);
        self.pos += value.len;
    }
    fn short(self: *Writer, value: usize) Error!void {
        if (value > 65535) return error.Capacity;
        var remaining = value;
        while (true) {
            var byte: u8 = @truncate(remaining & 127);
            remaining >>= 7;
            if (remaining != 0) byte |= 128;
            try self.bytes(&.{byte});
            if (remaining == 0) break;
        }
    }
};
pub fn onCurve(key: *const Key) bool {
    _ = std.crypto.ecc.Edwards25519.fromBytes(key.*) catch return false;
    return true;
}
pub fn findAddress(seeds: []const []const u8, program: *const Key, output: *Key) Error!u8 {
    if (seeds.len >= 16) return error.TooManySeeds;
    for (seeds) |seed| if (seed.len > 32) return error.SeedTooLong;
    var bump: u16 = 255;
    while (true) {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (seeds) |seed| hash.update(seed);
        hash.update(&.{@intCast(bump)});
        hash.update(program);
        hash.update("ProgramDerivedAddress");
        var key: Key = undefined;
        hash.final(&key);
        if (!onCurve(&key)) {
            output.* = key;
            return @intCast(bump);
        }
        if (bump == 0) return error.NoViableBump;
        bump -= 1;
    }
}
