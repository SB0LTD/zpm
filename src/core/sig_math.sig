//! sig_math — Pure math utilities for zpm modules.
//! No std dependency. Uses compiler builtins + IEEE 754 bit ops.
//! Import as: const math = @import("sig_math.sig");

pub fn isFinite(x: f32) bool {
    const bits: u32 = @bitCast(x);
    return (bits & 0x7F800000) != 0x7F800000;
}

pub fn isFiniteF64(x: f64) bool {
    const bits: u64 = @bitCast(x);
    return (bits & 0x7FF0000000000000) != 0x7FF0000000000000;
}

pub fn isNan(x: f32) bool {
    const bits: u32 = @bitCast(x);
    return (bits & 0x7F800000) == 0x7F800000 and (bits & 0x007FFFFF) != 0;
}

pub fn maxInt(comptime T: type) T {
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        return (1 << (info.bits - 1)) - 1;
    } else {
        return ~@as(T, 0);
    }
}

pub fn pow(base: f32, exponent: f32) f32 {
    if (exponent == 0.0) return 1.0;
    if (base == 0.0) return 0.0;
    if (base == 1.0) return 1.0;
    if (base > 0.0) return @exp(exponent * @log(base));
    const int_exp: i32 = @intFromFloat(exponent);
    const magnitude = @exp(exponent * @log(-base));
    return if (@rem(int_exp, 2) != 0) -magnitude else magnitude;
}

pub fn tanh(x: f32) f32 {
    if (x > 10.0) return 1.0;
    if (x < -10.0) return -1.0;
    const e2x = @exp(2.0 * x);
    return (e2x - 1.0) / (e2x + 1.0);
}

pub fn clamp(val: anytype, lower: @TypeOf(val), upper: @TypeOf(val)) @TypeOf(val) {
    return if (val < lower) lower else if (val > upper) upper else val;
}

/// Absolute value of an f32 without libm. Branchless-friendly.
pub fn absF(x: f32) f32 {
    return if (x < 0) -x else x;
}

pub fn rotl(comptime T: type, x: T, r: anytype) T {
    const bits = @typeInfo(T).int.bits;
    const shift: u6 = @intCast(@as(u32, @intCast(r)) % bits);
    return (x << shift) | (x >> (@as(u6, @intCast(bits - @as(u32, shift)))));
}

pub const pi: f32 = 3.14159265358979323846;
