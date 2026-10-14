//! Layer 0: canonical MGGP gossip / MGCK checkpoint-batch framing. Carries opaque
//! action and signature bytes verbatim; it verifies no signature and decodes no action.
//! Integer-only, allocator-free, caller-owned buffers.
const game = @import("ledger_world");
const aw = @import("action_wire");
const le = @import("solana_le");

pub const Key = game.Key;
pub const action_size = aw.size; // 60
pub const sig_size = 64;
pub const gossip_size = 184;
pub const batch_header_size = 32;
pub const transition_size = 156; // Key(32) + action(60) + sig(64)
pub const max_transitions = 64; // compile-time cap for MGCK

pub const Error = error{ InvalidLength, InvalidVersion, NonCanonical, TooManyTransitions };

/// `kind` is populated on decode from action[1] and ignored on encode (no distinct byte).
pub const GossipHeader = struct { world: u64, region: u32, sender: Key, nonce: u64, kind: u8 = 0 };
pub const BatchHeader = struct { world: u64, interval: u64, base_slot: u64, count: u16 };

pub fn encodeGossip(h: GossipHeader, action: [action_size]u8, sig: [sig_size]u8) [gossip_size]u8 {
    var out: [gossip_size]u8 = @splat(0);
    @memcpy(out[0..4], "MGGP");
    out[4] = 1;
    le.putLe(u64, out[8..16], h.world);
    le.putLe(u32, out[16..20], h.region);
    le.putLe(u64, out[20..28], h.nonce);
    @memcpy(out[28..60], &h.sender);
    @memcpy(out[60..120], &action);
    @memcpy(out[120..184], &sig);
    return out;
}

pub fn decodeGossipInto(input: []const u8, out: *GossipHeader, action_out: *[action_size]u8, sig_out: *[sig_size]u8) Error!void {
    if (input.len != gossip_size) return error.InvalidLength;
    inline for ("MGGP", 0..) |byte, i| if (byte != input[i]) return error.NonCanonical;
    if (input[4] != 1) return error.InvalidVersion;
    if (input[5] != 0 or input[6] != 0 or input[7] != 0) return error.NonCanonical;
    var sender: Key = undefined;
    @memcpy(&sender, input[28..60]);
    @memcpy(action_out, input[60..120]);
    @memcpy(sig_out, input[120..184]);
    out.* = .{
        .world = le.getLe(u64, input[8..16]),
        .region = le.getLe(u32, input[16..20]),
        .sender = sender,
        .nonce = le.getLe(u64, input[20..28]),
        .kind = action_out[1],
    };
}

pub fn encodeBatchHeader(h: BatchHeader) [batch_header_size]u8 {
    var out: [batch_header_size]u8 = @splat(0);
    @memcpy(out[0..4], "MGCK");
    out[4] = 1;
    le.putLe(u16, out[6..8], h.count);
    le.putLe(u64, out[8..16], h.world);
    le.putLe(u64, out[16..24], h.interval);
    le.putLe(u64, out[24..32], h.base_slot);
    return out;
}

/// Normative check order: length-floor -> magic -> version -> reserved -> cap -> exact length.
/// The cap check (TooManyTransitions) precedes the exact-length check (InvalidLength).
pub fn decodeBatchHeaderInto(input: []const u8, out: *BatchHeader) Error!void {
    if (input.len < batch_header_size) return error.InvalidLength;
    inline for ("MGCK", 0..) |byte, i| if (byte != input[i]) return error.NonCanonical;
    if (input[4] != 1) return error.InvalidVersion;
    if (input[5] != 0) return error.NonCanonical;
    const count = le.getLe(u16, input[6..8]);
    if (count > max_transitions) return error.TooManyTransitions;
    if (input.len != batch_header_size + @as(usize, count) * transition_size) return error.InvalidLength;
    out.* = .{
        .world = le.getLe(u64, input[8..16]),
        .interval = le.getLe(u64, input[16..24]),
        .base_slot = le.getLe(u64, input[24..32]),
        .count = count,
    };
}
