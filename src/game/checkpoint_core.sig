//! Layer 0: deterministic verdict classification for mesh/on-chain no-divergence.
//! classify delegates to ledger_world.applyRefs over faithful local copies, so a
//! verdict never corrupts the caller's authoritative base records. Integer-only.
const game = @import("ledger_world");

pub const Verdict = enum { settle, conflict, replay, bad_signature };
pub const RetryState = struct { attempts: u8 = 0, limit: u8 = 6 };
pub const game_max_nodes = 64;
pub const game_max_monsters = 64;
pub const max_players = 16;
pub const max_batch = 64;
pub const Transition = struct { player: u16, action: game.Action, context: game.Context, sig_ok: bool };

/// Off-chain bounded batch evaluator. Actions execute in supplied order over one
/// working snapshot. No caller record changes unless the entire batch accepts.
/// The caller verifies signatures and supplies the intended slot; this is never
/// authority to substitute mesh time for the validator's native Clock.
pub fn applyBatch(rules: *const game.Rules, players: []game.Player, resources: *const game.ResourceViews, batch: []const Transition) Verdict {
    if (players.len > max_players or resources.nodes.len > game_max_nodes or resources.monsters.len > game_max_monsters or batch.len > max_batch) return .conflict;
    var player_copy: [max_players]game.Player = undefined;
    var nodes: [game_max_nodes]game.Node = undefined;
    var monsters: [game_max_monsters]game.Monster = undefined;
    @memcpy(player_copy[0..players.len], players);
    @memcpy(nodes[0..resources.nodes.len], resources.nodes);
    @memcpy(monsters[0..resources.monsters.len], resources.monsters);
    var views: game.ResourceViews = .{ .nodes = nodes[0..resources.nodes.len], .monsters = monsters[0..resources.monsters.len] };
    for (batch) |*transition| {
        if (!transition.sig_ok) return .bad_signature;
        if (transition.player >= players.len) return .conflict;
        const player = &player_copy[transition.player];
        if (transition.action.nonce != player.nonce) return .replay;
        game.applyRefs(rules, player, &views, &transition.action, &transition.context) catch return .conflict;
    }
    @memcpy(players, player_copy[0..players.len]);
    @memcpy(resources.nodes, views.nodes);
    @memcpy(resources.monsters, views.monsters);
    return .settle;
}

/// Total function. Copy-then-evaluate: the caller's base records are left byte-for-byte
/// unchanged (only *const reads + local copies are touched). Decision order is normative:
///  (1) !sig_ok -> .bad_signature
///  (2) action.nonce != base_player.nonce -> .replay (surfaced before auth/world,
///      which both still reject, so no false accept)
///  (3) oversized resource views (either over cap) -> .conflict (copy nothing)
///  (4) applyRefs on the copies -> .settle on accept, .conflict on ANY apply error
///      (Exhausted, Cooldown, and every non-nonce reason map to .conflict, never .replay)
pub fn classify(
    rules: *const game.Rules,
    base_player: *const game.Player,
    resources: *const game.ResourceViews,
    action: *const game.Action,
    context: *const game.Context,
    sig_ok: bool,
) Verdict {
    if (!sig_ok) return .bad_signature;
    if (action.nonce != base_player.nonce) return .replay;
    var player_copy = base_player.*;
    var node_buf: [game_max_nodes]game.Node = undefined;
    var monster_buf: [game_max_monsters]game.Monster = undefined;
    if (resources.nodes.len > node_buf.len or resources.monsters.len > monster_buf.len)
        return .conflict;
    @memcpy(node_buf[0..resources.nodes.len], resources.nodes);
    @memcpy(monster_buf[0..resources.monsters.len], resources.monsters);
    var local_views: game.ResourceViews = .{
        .nodes = node_buf[0..resources.nodes.len],
        .monsters = monster_buf[0..resources.monsters.len],
    };
    if (game.applyRefs(rules, &player_copy, &local_views, action, context)) {
        return .settle;
    } else |_| {
        return .conflict;
    }
}

/// With limit = 6: true for attempts in [0,5], false for attempts >= 6. The caller
/// increments attempts on each failed submission; retainable never mutates state.
pub fn retainable(state: *RetryState) bool {
    return state.attempts < state.limit;
}
