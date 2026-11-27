//! Synthetic infrastructure fixture; not game rules or production authority.
const history = @import("mesh_history");
pub const Counter = struct {
    pub fn initial() [8]u8 {
        return @splat(0);
    }
    pub fn validate(state: *const [8]u8) !void {
        if (history.get(u64, state) > 1_000_000) return error.InvalidCounter;
    }
    pub fn apply(state: *[8]u8, payload: []const u8) !void {
        if (payload.len != 8) return error.InvalidCounter;
        const amount = history.get(u64, payload);
        if (amount == 0 or amount > 10) return error.InvalidCounter;
        const current = history.get(u64, state);
        if (current > 1_000_000 - amount) return error.InvalidCounter;
        history.put(u64, state, current + amount);
    }
};
pub fn delta(value: u64) [8]u8 {
    var out: [8]u8 = undefined;
    history.put(u64, &out, value);
    return out;
}
