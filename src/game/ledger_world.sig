//! Layer 0: deterministic, allocation-free RPG transitions. No clock, RPC or renderer.
//! The host supplies a verified signer and authoritative ledger slot.
pub const Key = [32]u8;
pub const Position = struct { x: i16 = 0, z: i16 = 0 };
pub const Kind = enum(u8) { move = 1, mine = 2, craft = 3, attack = 4, rest = 5 };
pub const Action = struct {
    world: u64,
    nonce: u64,
    actor: Key,
    kind: Kind,
    position: Position = .{},
    target: u16 = 0,
    amount: u16 = 0,
};
pub const Player = struct {
    owner: Key,
    nonce: u64 = 0,
    position: Position = .{},
    hp: u16 = 100,
    ore: u16 = 0,
    bars: u16 = 0,
    xp: u32 = 0,
    next_slot: u64 = 0,
};
pub const Node = struct { position: Position, remaining: u16 = 100, ready_slot: u64 = 0 };
pub const Monster = struct { position: Position, hp: u16 = 30 };
pub const Rules = struct {
    world: u64 = 1,
    extent: i16 = 64,
    action_slots: u16 = 2,
    node_slots: u16 = 4,
    inventory_limit: u16 = 999,
};
pub const Context = struct { signer: Key, slot: u64 };
pub const ResourceViews = struct { nodes: []Node, monsters: []Monster };
/// Pointer ABI for constrained targets with five argument registers.
pub noinline fn applyRefs(rules: *const Rules, player: *Player, resources: *const ResourceViews, action: *const Action, context: *const Context) Error!void {
    return apply(rules.*, player, resources.nodes, resources.monsters, action.*, context.*);
}
pub const Error = error{ Unauthorized, WrongWorld, Replay, Exhausted, Cooldown, InvalidAction, OutOfBounds, OutOfRange, Depleted, InventoryFull, Dead, MissingResource };

pub fn sameKey(a: Key, b: Key) bool {
    var difference: u8 = 0;
    for (a, b) |x, y| difference |= x ^ y;
    return difference == 0;
}
pub fn distance(a: Position, b: Position) u32 {
    const dx: i32 = @as(i32, a.x) - b.x;
    const dz: i32 = @as(i32, a.z) - b.z;
    return @intCast(@abs(dx) + @abs(dz));
}
fn addXp(player: *Player, amount: u32) Error!void {
    if (player.xp > 0xffffffff - amount) return error.Exhausted;
    player.xp += amount;
}

/// Only touched accounts are copied. Rejection leaves every supplied account unchanged.
/// Account identity/ownership, target binding and signer verification belong to the host.
pub fn apply(rules: Rules, player: *Player, nodes: []Node, monsters: []Monster, action: Action, context: Context) Error!void {
    if (!sameKey(player.owner, context.signer) or !sameKey(player.owner, action.actor)) return error.Unauthorized;
    if (action.world != rules.world) return error.WrongWorld;
    if (action.nonce != player.nonce) return error.Replay;
    if (player.nonce == 0xffffffffffffffff or context.slot > @as(u64, 0xffffffffffffffff) - rules.action_slots) return error.Exhausted;
    if (context.slot < player.next_slot) return error.Cooldown;
    if (rules.extent <= 0) return error.OutOfBounds;
    if (action.amount != 0) return error.InvalidAction;
    if (action.kind != .move and (action.position.x != 0 or action.position.z != 0)) return error.InvalidAction;
    if (action.kind != .mine and action.kind != .attack and action.target != 0) return error.InvalidAction;
    if (player.hp == 0 and action.kind != .rest) return error.Dead;
    var next = player.*;
    var node_next: ?Node = null;
    var monster_next: ?Monster = null;
    switch (action.kind) {
        .move => {
            if (@abs(@as(i32, action.position.x)) > @as(u32, @intCast(rules.extent)) or @abs(@as(i32, action.position.z)) > @as(u32, @intCast(rules.extent))) return error.OutOfBounds;
            if (distance(next.position, action.position) != 1) return error.OutOfRange;
            next.position = action.position;
        },
        .mine => {
            if (action.target >= nodes.len) return error.InvalidAction;
            var node = nodes[action.target];
            if (distance(next.position, node.position) > 1) return error.OutOfRange;
            if (node.remaining == 0) return error.Depleted;
            if (context.slot < node.ready_slot) return error.Cooldown;
            if (next.ore >= rules.inventory_limit) return error.InventoryFull;
            if (context.slot > @as(u64, 0xffffffffffffffff) - rules.node_slots) return error.Exhausted;
            next.ore += 1;
            try addXp(&next, 10);
            node.remaining -= 1;
            node.ready_slot = context.slot + rules.node_slots;
            node_next = node;
        },
        .craft => {
            if (next.ore < 3) return error.MissingResource;
            if (next.bars >= rules.inventory_limit) return error.InventoryFull;
            next.ore -= 3;
            next.bars += 1;
            try addXp(&next, 20);
        },
        .attack => {
            if (action.target >= monsters.len) return error.InvalidAction;
            var monster = monsters[action.target];
            if (monster.hp == 0) return error.Dead;
            if (distance(next.position, monster.position) > 1) return error.OutOfRange;
            const damage: u16 = if (next.bars > 0) 15 else 10;
            monster.hp -|= damage;
            if (monster.hp == 0) try addXp(&next, 50) else next.hp -|= 7;
            monster_next = monster;
        },
        .rest => {
            if (distance(next.position, .{}) > 1) return error.OutOfRange;
            next.hp = 100;
        },
    }
    next.nonce += 1;
    next.next_slot = context.slot + rules.action_slots;
    player.* = next;
    if (node_next) |node| nodes[action.target] = node;
    if (monster_next) |monster| monsters[action.target] = monster;
}
