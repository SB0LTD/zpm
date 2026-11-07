//! Canonical little-endian 60-byte RPG action. Never serialize native struct layout.
const game = @import("ledger_world");
pub const size = 60;
pub const Error = error{ InvalidLength, InvalidVersion, InvalidKind, NonCanonical };
fn put(comptime T: type, out: []u8, value: T) void {
    inline for (0..@sizeOf(T)) |i| out[i] = @truncate(value >> (i * 8));
}
fn get(comptime T: type, input: []const u8) T {
    var value: T = 0;
    inline for (0..@sizeOf(T)) |i| value |= @as(T, input[i]) << (i * 8);
    return value;
}
pub fn encode(action: game.Action) [size]u8 {
    var out: [size]u8 = @splat(0);
    out[0] = 1;
    out[1] = @backingInt(action.kind);
    put(u64, out[4..12], action.world);
    put(u64, out[12..20], action.nonce);
    @memcpy(out[20..52], &action.actor);
    put(u16, out[52..54], @bitCast(action.position.x));
    put(u16, out[54..56], @bitCast(action.position.z));
    put(u16, out[56..58], action.target);
    put(u16, out[58..60], action.amount);
    return out;
}
pub inline fn decode(input: []const u8) Error!game.Action {
    if (input.len != size) return error.InvalidLength;
    if (input[0] != 1) return error.InvalidVersion;
    if (input[2] != 0 or input[3] != 0) return error.NonCanonical;
    if (input[1] < 1 or input[1] > 5) return error.InvalidKind;
    var actor: game.Key = undefined;
    @memcpy(&actor, input[20..52]);
    return .{ .world = get(u64, input[4..12]), .nonce = get(u64, input[12..20]), .actor = actor, .kind = @fromBackingInt(@intCast(input[1])), .position = .{ .x = @bitCast(get(u16, input[52..54])), .z = @bitCast(get(u16, input[54..56])) }, .target = get(u16, input[56..58]), .amount = get(u16, input[58..60]) };
}
