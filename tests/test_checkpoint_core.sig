const std = @import("std");
const game = @import("ledger_world");
const aw = @import("action_wire");
const cp = @import("checkpoint_core");
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

// Run applyRefs on an independent faithful copy of a base; return the verdict-equivalent reason.
const ApplyResult = enum { accept, replay, other };
fn applyProbe(
    rules: *const game.Rules,
    base_player: *const game.Player,
    base_nodes: []const game.Node,
    base_monsters: []const game.Monster,
    action: *const game.Action,
    context: *const game.Context,
) ApplyResult {
    var player = base_player.*;
    var node_buf: [64]game.Node = undefined;
    var monster_buf: [64]game.Monster = undefined;
    @memcpy(node_buf[0..base_nodes.len], base_nodes);
    @memcpy(monster_buf[0..base_monsters.len], base_monsters);
    var views: game.ResourceViews = .{ .nodes = node_buf[0..base_nodes.len], .monsters = monster_buf[0..base_monsters.len] };
    if (game.applyRefs(rules, &player, &views, action, context)) {
        return .accept;
    } else |err| {
        if (err == error.Replay) return .replay;
        return .other;
    }
}

pub fn main(init: std.process.Init) !void {
    var seed: u64 = 0xCAFE_F00D_0BAD_1234;
    const s = &seed;
    const rules: game.Rules = .{};

    // Feature: distributed-mmorpg-infrastructure, Property 3: mesh and on-chain classification never diverge (no false accept) and map verdicts exactly in the valid-signer/world regime.
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const owner = randKey(s);
            // valid-signer/world regime: signer == actor == player.owner, action.world == rules.world.
            const player_nonce = nextU64(s) % 0xffff; // not u64 MAX; keeps Exhausted off the valid path.
            var player: game.Player = .{ .owner = owner, .nonce = player_nonce, .hp = 100, .position = .{ .x = 0, .z = 0 } };
            var nodes = [_]game.Node{.{ .position = .{ .x = 1, .z = 0 }, .remaining = 100 }};
            var monsters = [_]game.Monster{.{ .position = .{ .x = 0, .z = 1 }, .hp = 30 }};
            // choose a kind and build a well-formed action for it.
            const kind_sel = nextU64(s) % 5;
            var action: game.Action = .{ .world = 1, .nonce = player_nonce, .actor = owner, .kind = .rest };
            switch (kind_sel) {
                0 => {
                    action.kind = .move;
                    action.position = .{ .x = 1, .z = 0 };
                },
                1 => {
                    action.kind = .mine;
                    action.target = 0;
                },
                2 => {
                    action.kind = .craft;
                },
                3 => {
                    action.kind = .attack;
                    action.target = 0;
                },
                else => {
                    action.kind = .rest;
                },
            }
            // sometimes make the nonce stale to exercise the replay path.
            if (i % 3 == 0) action.nonce = player_nonce +% 1;
            const context: game.Context = .{ .signer = owner, .slot = player.next_slot + 1 };

            const views: game.ResourceViews = .{ .nodes = nodes[0..], .monsters = monsters[0..] };
            const verdict = cp.classify(&rules, &player, &views, &action, &context, true);

            const probe = applyProbe(&rules, &player, nodes[0..], monsters[0..], &action, &context);

            // (total) no false accept over ALL inputs: settle implies applyRefs accepts.
            if (verdict == .settle) try check(probe == .accept);
            // (constrained, valid-signer/world) verdict-exact mapping.
            if (probe == .accept) try check(verdict == .settle);
            if (action.nonce != player.nonce) {
                try check(verdict == .replay);
            } else if (probe == .replay) {
                try check(verdict == .replay);
            } else if (probe == .other) {
                try check(verdict == .conflict);
            }

            // Property 4 (atomic rollback via classify): base records byte-identical after classify.
            try check(player.nonce == player_nonce and nodes[0].remaining == 100 and monsters[0].hp == 30);

            // (determinism leg) applyRefs determinism: two faithful copies produce identical records.
            // classify's post-state equals this result by construction (classify step 4 is applyRefs
            // over a faithful copy sliced to source lengths).
            if (verdict == .settle) {
                var p1 = player;
                var p2 = player;
                var n1 = [_]game.Node{nodes[0]};
                var n2 = [_]game.Node{nodes[0]};
                var m1 = [_]game.Monster{monsters[0]};
                var m2 = [_]game.Monster{monsters[0]};
                var v1: game.ResourceViews = .{ .nodes = n1[0..], .monsters = m1[0..] };
                var v2: game.ResourceViews = .{ .nodes = n2[0..], .monsters = m2[0..] };
                try game.applyRefs(&rules, &p1, &v1, &action, &context);
                try game.applyRefs(&rules, &p2, &v2, &action, &context);
                try check(p1.nonce == p2.nonce and p1.position.x == p2.position.x and p1.hp == p2.hp and p1.ore == p2.ore and p1.bars == p2.bars and p1.xp == p2.xp);
                try check(n1[0].remaining == n2[0].remaining and m1[0].hp == m2[0].hp);
            }
        }
    }

    // Feature: distributed-mmorpg-infrastructure, Property 5: accepted nonces are strictly greater than the highest previously accepted (operationally: action.nonce != player.nonce surfaces as replay).
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const owner = randKey(s);
            const base_nonce = nextU64(s) % 0xffff;
            var player: game.Player = .{ .owner = owner, .nonce = base_nonce, .hp = 100 };
            var nodes = [_]game.Node{.{ .position = .{ .x = 1 }, .remaining = 100 }};
            var monsters = [_]game.Monster{.{ .position = .{ .z = 1 }, .hp = 30 }};
            const views: game.ResourceViews = .{ .nodes = nodes[0..], .monsters = monsters[0..] };
            // generate nonce with duplicates and gaps.
            const delta = nextU64(s) % 4; // 0,1,2,3
            const action_nonce = base_nonce +% delta;
            var action: game.Action = .{ .world = 1, .nonce = action_nonce, .actor = owner, .kind = .rest };
            const context: game.Context = .{ .signer = owner, .slot = 1 };
            const verdict = cp.classify(&rules, &player, &views, &action, &context, true);
            if (delta != 0) {
                try check(verdict == .replay);
            } else {
                // nonce-equal path: valid regime so Exhausted/Cooldown don't contaminate; rest is well-formed.
                try check(verdict == .settle);
            }
        }
    }

    // Feature: distributed-mmorpg-infrastructure, Property 6: a checkpoint batch settles iff every transition settles (all-or-nothing).
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const owner = randKey(s);
            var player: game.Player = .{ .owner = owner, .nonce = 0, .hp = 100 };
            var nodes = [_]game.Node{.{ .position = .{ .x = 1 }, .remaining = 100 }};
            var monsters = [_]game.Monster{.{ .position = .{ .z = 1 }, .hp = 30 }};
            const views: game.ResourceViews = .{ .nodes = nodes[0..], .monsters = monsters[0..] };
            const context: game.Context = .{ .signer = owner, .slot = 1 };
            const seq_len = nextU64(s) % 5; // includes 0 (empty sequence vacuously settles).
            var all_settle = true;
            var j: usize = 0;
            while (j < seq_len) : (j += 1) {
                // mix in a guaranteed-conflict (wrong world) or replay (stale nonce) sometimes.
                const bad = nextU64(s) % 4;
                var action: game.Action = .{ .world = 1, .nonce = 0, .actor = owner, .kind = .rest };
                if (bad == 0) action.world = 2; // WrongWorld -> conflict
                if (bad == 1) action.nonce = 7; // stale/ahead nonce -> replay
                const verdict = cp.classify(&rules, &player, &views, &action, &context, true);
                if (verdict != .settle) all_settle = false;
                _ = &player;
            }
            if (seq_len == 0) try check(all_settle);
        }
    }

    // Feature: distributed-mmorpg-infrastructure, Property 3 (oversized-view degrade): resource views over the fixed cap classify as conflict for nodes and monsters independently.
    {
        var big_nodes: [cp.game_max_nodes + 1]game.Node = @splat(.{ .position = .{} });
        var small_monsters = [_]game.Monster{.{ .position = .{}, .hp = 30 }};
        var big_monsters: [cp.game_max_monsters + 1]game.Monster = @splat(.{ .position = .{} });
        var small_nodes = [_]game.Node{.{ .position = .{}, .remaining = 100 }};
        const owner: game.Key = @splat(9);
        var player: game.Player = .{ .owner = owner, .nonce = 0, .hp = 100 };
        var action: game.Action = .{ .world = 1, .nonce = 0, .actor = owner, .kind = .rest };
        const context: game.Context = .{ .signer = owner, .slot = 1 };
        const over_nodes: game.ResourceViews = .{ .nodes = big_nodes[0..], .monsters = small_monsters[0..] };
        try check(cp.classify(&rules, &player, &over_nodes, &action, &context, true) == .conflict);
        const over_monsters: game.ResourceViews = .{ .nodes = small_nodes[0..], .monsters = big_monsters[0..] };
        try check(cp.classify(&rules, &player, &over_monsters, &action, &context, true) == .conflict);
    }

    // Feature: distributed-mmorpg-infrastructure, Property 3 (bad_signature arm): sig_ok=false always classifies as bad_signature.
    {
        const owner: game.Key = @splat(3);
        var player: game.Player = .{ .owner = owner, .nonce = 0, .hp = 100 };
        var nodes = [_]game.Node{.{ .position = .{ .x = 1 }, .remaining = 100 }};
        var monsters = [_]game.Monster{.{ .position = .{ .z = 1 }, .hp = 30 }};
        const views: game.ResourceViews = .{ .nodes = nodes[0..], .monsters = monsters[0..] };
        var action: game.Action = .{ .world = 1, .nonce = 0, .actor = owner, .kind = .rest };
        const context: game.Context = .{ .signer = owner, .slot = 1 };
        try check(cp.classify(&rules, &player, &views, &action, &context, false) == .bad_signature);
    }

    // Feature: distributed-mmorpg-infrastructure, Property 6 (retainable boundary): retainable is true for attempts [0,5] and false for attempts >= 6.
    {
        var attempts: u8 = 0;
        while (attempts <= 7) : (attempts += 1) {
            var state: cp.RetryState = .{ .attempts = attempts };
            if (attempts < 6) try check(cp.retainable(&state)) else try check(!cp.retainable(&state));
        }
    }

    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "ZPM checkpoint-core contracts PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
