//! BIT(n) and BIT VARYING(n) values (Layer 0), after PostgreSQL's varbit.c.
//!
//! A bit string is a bit length and its bits packed most significant first,
//! with the unused low bits of the last byte zero (VARBIT_PAD). Both types
//! share the representation and the ordering of bit_cmp: memcmp over the
//! common bytes, then the shorter string first. Typmods are the declared
//! length n itself (1..83886080, 22023 otherwise); BIT defaults to BIT(1).
//!
//! Input (bit_in/varbit_in): an optional leading `b`/`B` (binary digits)
//! or `x`/`X` (hex digits, four bits each); any other digit is 22P02.
//! Length coercion: BIT(n) assignment/input demands exactly n bits (22026),
//! explicit casts zero-pad or truncate; BIT VARYING(n) assignment/input
//! rejects longer strings (22001), explicit casts truncate.
//!
//! Capacity: at most Config.text_bytes * 8 bits per value (TextCapacity,
//! 54000, beyond); the text form needs one byte per bit.
const types = @import("types.sig");
const Error = types.Error;

/// MaxAttrSize * BITS_PER_BYTE.
pub const max_length: u64 = 83886080;

pub fn Bits(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        /// Length in bits.
        len: usize = 0,

        pub const max_bits = capacity * 8;

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..byteLength(self.len)];
        }

        pub fn bit(self: *const @This(), index: usize) bool {
            return self.bytes[index / 8] & (@as(u8, 0x80) >> @intCast(index % 8)) != 0;
        }

        fn set(self: *@This(), index: usize) void {
            self.bytes[index / 8] |= @as(u8, 0x80) >> @intCast(index % 8);
        }

        /// bit_in without a typmod.
        pub fn parse(input: []const u8) Error!@This() {
            var out: @This() = .{};
            var text = input;
            var hex = false;
            if (text.len != 0 and (text[0] == 'b' or text[0] == 'B')) {
                text = text[1..];
            } else if (text.len != 0 and (text[0] == 'x' or text[0] == 'X')) {
                text = text[1..];
                hex = true;
            }
            const width: usize = if (hex) 4 else 1;
            if (text.len > max_bits / width) return error.TextCapacity;
            for (text, 0..) |byte, index| {
                if (hex) {
                    const nibble: u8 = switch (byte) {
                        '0'...'9' => byte - '0',
                        'a'...'f' => byte - 'a' + 10,
                        'A'...'F' => byte - 'A' + 10,
                        else => return error.InvalidTextRepresentation,
                    };
                    for (0..4) |offset| {
                        if (nibble & (@as(u8, 8) >> @intCast(offset)) != 0) out.set(index * 4 + offset);
                    }
                } else switch (byte) {
                    '0' => {},
                    '1' => out.set(index),
                    else => return error.InvalidTextRepresentation,
                }
            }
            out.len = text.len * width;
            return out;
        }

        /// One '0'/'1' per bit into `buffer` (at least len bytes).
        pub fn format(self: *const @This(), buffer: []u8) []const u8 {
            for (0..self.len) |index| buffer[index] = if (self.bit(index)) '1' else '0';
            return buffer[0..self.len];
        }

        /// The first `length` bits, zero-padded on the right.
        pub fn resized(self: *const @This(), length: usize) Error!@This() {
            if (length > max_bits) return error.TextCapacity;
            var out: @This() = .{ .len = length };
            const keep = @min(length, self.len);
            for (0..keep) |index| if (self.bit(index)) out.set(index);
            return out;
        }

        /// bit_cmp.
        pub fn compare(a: *const @This(), b: *const @This()) i8 {
            const left = a.slice();
            const right = b.slice();
            const count = @min(left.len, right.len);
            for (left[0..count], right[0..count]) |x, y| {
                if (x != y) return if (x < y) -1 else 1;
            }
            if (a.len != b.len) return if (a.len < b.len) -1 else 1;
            return 0;
        }

        /// Whether the unused bits of the last byte are zero (change records).
        pub fn padded(self: *const @This()) bool {
            if (self.len > max_bits) return false;
            if (self.len % 8 == 0) return true;
            const last = self.bytes[self.len / 8];
            return last & (@as(u8, 0xff) >> @intCast(self.len % 8)) == 0;
        }

        /// bitfromint4/bitfromint8: the low `length` bits of `value`, sign
        /// extended beyond the source width (`source_bits` 32 or 64).
        pub fn fromInteger(value: i64, source_bits: u7, length: usize) Error!@This() {
            if (length > max_bits) return error.TextCapacity;
            var out: @This() = .{ .len = length };
            for (0..length) |index| {
                // Bit `index` from the left is source bit (length - 1 - index).
                const position = length - 1 - index;
                const shift: u6 = @intCast(@min(position, source_bits - 1));
                if ((value >> shift) & 1 != 0) out.set(index);
            }
            return out;
        }

        /// bittoint4/bittoint8: the bits as an unsigned number of at most
        /// `target_bits` bits, reinterpreted as signed (22003 if longer).
        pub fn toInteger(self: *const @This(), target_bits: u7) Error!i64 {
            if (self.len > target_bits) return error.IntegerOverflow;
            var result: u64 = 0;
            for (0..self.len) |index| result = (result << 1) | @intFromBool(self.bit(index));
            if (target_bits == 32) return @as(i32, @bitCast(@as(u32, @truncate(result))));
            return @bitCast(result);
        }
    };
}

/// Typmod of a declared length.
pub fn typmodOf(length: u64) Error!i32 {
    if (length < 1 or length > max_length) return error.InvalidParameterValue;
    return @intCast(length);
}

pub fn validTypmod(typmod: i32) bool {
    return typmod == -1 or (typmod >= 1 and typmod <= @as(i32, @intCast(max_length)));
}

pub fn byteLength(bits: usize) usize {
    return bits / 8 + @intFromBool(bits % 8 != 0);
}

pub const Mode = enum { implicit, explicit };

/// The length a BIT(n) (fixed) or BIT VARYING(n) value takes under
/// `typmod`, or the error of the implicit coercion.
pub fn coercedLength(bits: usize, typmod: i32, fixed: bool, mode: Mode) Error!usize {
    if (typmod <= 0) return bits;
    const length: usize = @intCast(typmod);
    if (fixed) {
        if (bits == length) return bits;
        if (mode == .implicit) return error.StringDataLengthMismatch;
        return length;
    }
    if (bits <= length) return bits;
    if (mode == .implicit) return error.StringDataRightTruncation;
    return length;
}
