//! Self-custody Solana signing primitives. The host supplies 32 CSPRNG bytes;
//! no entropy, persistent storage, transport, branding, or allocator is hidden here.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub const MAX_MESSAGE: usize = 1024;
pub const Error = error{ InvalidKey, InvalidMessage };

pub fn publicKey(seed: *const [32]u8) Error![32]u8 {
    var pair = Ed25519.KeyPair.generateDeterministic(seed.*) catch return error.InvalidKey;
    defer wipe(std.mem.asBytes(&pair));
    return pair.public_key.toBytes();
}

/// Solana keypair files are seed || public key. Reject a mismatched public half.
pub fn validateKeypair(bytes: *const [64]u8) bool {
    const key = publicKey(bytes[0..32]) catch return false;
    return std.mem.eql(u8, &key, bytes[32..64]);
}

/// Approval and protocol/domain validation are mandatory host responsibilities.
pub fn sign(seed: *const [32]u8, message: []const u8) Error![64]u8 {
    if (message.len == 0 or message.len > MAX_MESSAGE) return error.InvalidMessage;
    var pair = Ed25519.KeyPair.generateDeterministic(seed.*) catch return error.InvalidKey;
    defer wipe(std.mem.asBytes(&pair));
    const signature = pair.sign(message, null) catch return error.InvalidKey;
    return signature.toBytes();
}

/// Volatile writes prevent dead-store elimination of caller-owned secret bytes.
pub fn wipe(bytes: []u8) void {
    for (bytes) |*byte| {
        const target: *volatile u8 = byte;
        target.* = 0;
    }
}
