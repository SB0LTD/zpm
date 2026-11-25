//! Names and canonical values for PostgreSQL role defaults.
const std = @import("std");

/// Stable bit positions in catalog records.
pub const Boolean = enum(u3) {
    check_function_bodies,
    quote_all_identifiers,
    row_security,
    synchronize_seqscans,
    default_transaction_read_only,
    default_transaction_deferrable,

    pub fn bit(self: Boolean) u32 {
        return @as(u32, 1) << @as(u5, @intFromEnum(self));
    }
};

const names = @typeInfo(Boolean).@"enum".field_names;
pub const mask: u32 = (1 << names.len) - 1;

/// Array text values have in-memory symbols. Wire and WAL writers emit the
/// decoded strings.
const entries = blk: {
    var values: [2 * names.len][]const u8 = undefined;
    for (names, 0..) |name, i| {
        values[2 * i] = name ++ "=off";
        values[2 * i + 1] = name ++ "=on";
    }
    break :blk values;
};

pub fn symbol(text: []const u8) ?u8 {
    for (entries, 0..) |value, i| {
        if (std.mem.eql(u8, text, value)) return @intCast(i + 2);
    }
    return null;
}

pub fn string(code: u8) []const u8 {
    return entries[code - 2];
}
