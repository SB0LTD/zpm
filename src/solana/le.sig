//! Layer 0 little-endian primitives. Callers validate slice lengths before access.
pub fn putLe(comptime T: type, output: []u8, value: T) void {
    inline for (0..@sizeOf(T)) |i| output[i] = @truncate(value >> (i * 8));
}
pub fn getLe(comptime T: type, input: []const u8) T {
    var value: T = 0;
    inline for (0..@sizeOf(T)) |i| value |= @as(T, input[i]) << (i * 8);
    return value;
}
pub fn readU64(input: []const u8, offset: usize) u64 {
    return getLe(u64, input[offset..][0..8]);
}
