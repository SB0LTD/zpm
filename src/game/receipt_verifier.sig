//! Layer 0: single-use receipt binding. No callback self-authorizes: an effect is valid
//! only after bind matched the expected action AND the first matching consume. Integer-only,
//! allocator-free, caller-owned record. Rejections leave the receipt byte-for-byte unchanged.
pub const Error = error{ Unbound, WrongAction, AlreadyConsumed };

pub const Receipt = struct { action_hash: [32]u8, bound: bool = false, consumed: bool = false };

/// Whole-buffer accumulate-XOR, no early exit (same pattern as ledger_world.sameKey).
fn eq32(a: [32]u8, b: [32]u8) bool {
    var difference: u8 = 0;
    for (a, b) |x, y| difference |= x ^ y;
    return difference == 0;
}

/// All checks precede any mutation.
pub fn bind(r: *Receipt, callback_action_hash: *const [32]u8, expected: *const [32]u8) Error!void {
    if (r.bound) return error.AlreadyConsumed;
    if (!eq32(callback_action_hash.*, expected.*)) return error.WrongAction;
    r.action_hash = callback_action_hash.*;
    r.bound = true;
}

/// Single-use: a second consume of a consumed receipt returns AlreadyConsumed.
pub fn consume(r: *Receipt, action_hash: *const [32]u8) Error!void {
    if (!r.bound) return error.Unbound;
    if (r.consumed) return error.AlreadyConsumed;
    if (!eq32(r.action_hash, action_hash.*)) return error.WrongAction;
    r.consumed = true;
}
