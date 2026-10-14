//! Stable account storage for deterministic ledger RPGs. Fixed widths, explicit LE.
const game = @import("ledger_world");
pub const Error = error{ InvalidLength, InvalidHeader, NonCanonical };
pub const PlayerRecord = struct { world: u64, player: game.Player };
pub const NodeRecord = struct { world: u64, id: u16, node: game.Node };
pub const MonsterRecord = struct { world: u64, id: u16, monster: game.Monster };
pub const player_size = 80;
pub const node_size = 32;
pub const monster_size = 24;
/// Caller-owned decode forms avoid aggregate returns on constrained ABIs.
pub noinline fn decodePlayerInto(input: []const u8, output: *PlayerRecord) Error!void {
    output.* = try decodePlayer(input);
}
pub noinline fn decodeNodeInto(input: []const u8, output: *NodeRecord) Error!void {
    output.* = try decodeNode(input);
}
pub noinline fn decodeMonsterInto(input: []const u8, output: *MonsterRecord) Error!void {
    output.* = try decodeMonster(input);
}
fn put(comptime T: type, out: []u8, value: T) void {
    inline for (0..@sizeOf(T)) |i| out[i] = @truncate(value >> (i * 8));
}
fn get(comptime T: type, input: []const u8) T {
    var value: T = 0;
    inline for (0..@sizeOf(T)) |i| value |= @as(T, input[i]) << (i * 8);
    return value;
}
fn header(input: []const u8, length: usize, comptime magic: []const u8) Error!void {
    if (input.len != length) return error.InvalidLength;
    inline for (magic, 0..) |byte, i| if (byte != input[i]) return error.InvalidHeader;
    if (input[4] != 1) return error.InvalidHeader;
    if (input[5] != 0) return error.NonCanonical;
}
pub inline fn encodePlayer(record: PlayerRecord) [player_size]u8 {
    var out: [player_size]u8 = @splat(0);
    @memcpy(out[0..4], "MGPL");
    out[4] = 1;
    put(u64, out[8..16], record.world);
    @memcpy(out[16..48], &record.player.owner);
    put(u64, out[48..56], record.player.nonce);
    put(u16, out[56..58], @bitCast(record.player.position.x));
    put(u16, out[58..60], @bitCast(record.player.position.z));
    put(u16, out[60..62], record.player.hp);
    put(u16, out[62..64], record.player.ore);
    put(u16, out[64..66], record.player.bars);
    put(u32, out[68..72], record.player.xp);
    put(u64, out[72..80], record.player.next_slot);
    return out;
}
pub inline fn decodePlayer(input: []const u8) Error!PlayerRecord {
    try header(input, player_size, "MGPL");
    if (input[6] != 0 or input[7] != 0 or input[66] != 0 or input[67] != 0) return error.NonCanonical;
    var owner: game.Key = undefined;
    @memcpy(&owner, input[16..48]);
    return .{ .world = get(u64, input[8..16]), .player = .{ .owner = owner, .nonce = get(u64, input[48..56]), .position = .{ .x = @bitCast(get(u16, input[56..58])), .z = @bitCast(get(u16, input[58..60])) }, .hp = get(u16, input[60..62]), .ore = get(u16, input[62..64]), .bars = get(u16, input[64..66]), .xp = get(u32, input[68..72]), .next_slot = get(u64, input[72..80]) } };
}
pub inline fn encodeNode(record: NodeRecord) [node_size]u8 {
    var out: [node_size]u8 = @splat(0);
    @memcpy(out[0..4], "MGND");
    out[4] = 1;
    put(u16, out[6..8], record.id);
    put(u64, out[8..16], record.world);
    put(u16, out[16..18], @bitCast(record.node.position.x));
    put(u16, out[18..20], @bitCast(record.node.position.z));
    put(u16, out[20..22], record.node.remaining);
    put(u64, out[24..32], record.node.ready_slot);
    return out;
}
pub inline fn decodeNode(input: []const u8) Error!NodeRecord {
    try header(input, node_size, "MGND");
    if (input[22] != 0 or input[23] != 0) return error.NonCanonical;
    return .{ .world = get(u64, input[8..16]), .id = get(u16, input[6..8]), .node = .{ .position = .{ .x = @bitCast(get(u16, input[16..18])), .z = @bitCast(get(u16, input[18..20])) }, .remaining = get(u16, input[20..22]), .ready_slot = get(u64, input[24..32]) } };
}
pub inline fn encodeMonster(record: MonsterRecord) [monster_size]u8 {
    var out: [monster_size]u8 = @splat(0);
    @memcpy(out[0..4], "MGMB");
    out[4] = 1;
    put(u16, out[6..8], record.id);
    put(u64, out[8..16], record.world);
    put(u16, out[16..18], @bitCast(record.monster.position.x));
    put(u16, out[18..20], @bitCast(record.monster.position.z));
    put(u16, out[20..22], record.monster.hp);
    return out;
}
pub inline fn decodeMonster(input: []const u8) Error!MonsterRecord {
    try header(input, monster_size, "MGMB");
    if (input[22] != 0 or input[23] != 0) return error.NonCanonical;
    return .{ .world = get(u64, input[8..16]), .id = get(u16, input[6..8]), .monster = .{ .position = .{ .x = @bitCast(get(u16, input[16..18])), .z = @bitCast(get(u16, input[18..20])) }, .hp = get(u16, input[20..22]) } };
}
