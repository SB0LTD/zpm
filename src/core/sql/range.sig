//! Range types (Layer 0), after rangetypes.c: int4range, int8range,
//! numrange, daterange, tsrange and tstzrange.
//!
//! A range lives inline in one cell's byte budget: [0] the subtype's
//! DataType ordinal, [1] flags (PostgreSQL's RANGE_EMPTY 0x01, LB_INC 0x02,
//! UB_INC 0x04, LB_INF 0x08, UB_INF 0x10), then the finite bounds' values in
//! the array element encoding (array.sig). Every stored range is canonical:
//! infinite bounds are exclusive, an empty range has no bounds, and the
//! discrete subtypes (int4, int8, date) use [lower, upper) form, so equality
//! is structural and hashing follows it.
//!
//! Ordering is range_cmp: empty first, then lower bounds, then upper
//! bounds (range_cmp_bounds: -infinity/+infinity, then values, then an
//! inclusive lower bound before an exclusive one and an exclusive upper
//! bound before an inclusive one).
const types = @import("types.sig");
const Error = types.Error;
const DataType = types.DataType;

pub const empty_flag: u8 = 0x01;
pub const lower_inclusive_flag: u8 = 0x02;
pub const upper_inclusive_flag: u8 = 0x04;
pub const lower_infinite_flag: u8 = 0x08;
pub const upper_infinite_flag: u8 = 0x10;

pub fn Ranges(comptime V: type) type {
    return struct {
        const A = V.Arrays;
        const Cell = V.Cell;

        pub const Bound = struct {
            value: Cell = .null_value,
            infinite: bool = true,
            inclusive: bool = false,
            lower: bool,
        };

        pub const Range = struct {
            subtype: DataType,
            empty: bool = false,
            lower: Bound = .{ .lower = true },
            upper: Bound = .{ .lower = false },
        };

        pub fn subtypeOf(bytes: []const u8) DataType {
            return @enumFromInt(bytes[0]);
        }

        pub fn decode(bytes: []const u8) Range {
            const flags = bytes[1];
            var out: Range = .{ .subtype = @enumFromInt(bytes[0]), .empty = flags & empty_flag != 0 };
            if (out.empty) return out;
            var at: usize = 2;
            out.lower.inclusive = flags & lower_inclusive_flag != 0;
            out.upper.inclusive = flags & upper_inclusive_flag != 0;
            if (flags & lower_infinite_flag == 0) {
                out.lower.infinite = false;
                out.lower.value = A.decodeElement(bytes, &at, out.subtype);
            }
            if (flags & upper_infinite_flag == 0) {
                out.upper.infinite = false;
                out.upper.value = A.decodeElement(bytes, &at, out.subtype);
            }
            return out;
        }

        /// Writes an already-made (validated, canonical) range.
        pub fn encode(range: *const Range, out: *V.Text) Error!void {
            out.len = 0;
            var flags: u8 = 0;
            if (range.empty) {
                flags = empty_flag;
            } else {
                if (range.lower.infinite) flags |= lower_infinite_flag else if (range.lower.inclusive) flags |= lower_inclusive_flag;
                if (range.upper.infinite) flags |= upper_infinite_flag else if (range.upper.inclusive) flags |= upper_inclusive_flag;
            }
            try A.putBytes(out, &.{ @intFromEnum(range.subtype), flags });
            if (range.empty) return;
            if (!range.lower.infinite) try A.encodeElement(out, range.subtype, &range.lower.value);
            if (!range.upper.infinite) try A.encodeElement(out, range.subtype, &range.upper.value);
        }

        /// range_cmp_bound_values: values only (infinities ordered).
        pub fn compareValues(a: *const Bound, b: *const Bound) i8 {
            if (a.infinite and b.infinite) return if (a.lower == b.lower) 0 else if (a.lower) -1 else 1;
            if (a.infinite) return if (a.lower) -1 else 1;
            if (b.infinite) return if (b.lower) 1 else -1;
            return V.compare(&a.value, &b.value);
        }

        /// range_cmp_bounds.
        pub fn compareBounds(a: *const Bound, b: *const Bound) i8 {
            const order = compareValues(a, b);
            if (order != 0 or a.infinite or b.infinite) return order;
            if (!a.inclusive and !b.inclusive) return if (a.lower == b.lower) 0 else if (a.lower) 1 else -1;
            if (!a.inclusive) return if (a.lower) 1 else -1;
            if (!b.inclusive) return if (b.lower) -1 else 1;
            return 0;
        }

        pub fn compareRanges(a: *const Range, b: *const Range) i8 {
            if (a.empty and b.empty) return 0;
            if (a.empty) return -1;
            if (b.empty) return 1;
            const order = compareBounds(&a.lower, &b.lower);
            if (order != 0) return order;
            return compareBounds(&a.upper, &b.upper);
        }

        pub fn compare(a: []const u8, b: []const u8) i8 {
            if (a[0] != b[0]) return if (a[0] < b[0]) -1 else 1;
            const left = decode(a);
            const right = decode(b);
            return compareRanges(&left, &right);
        }

        /// Consistent with compare: canonical ranges are equal exactly when
        /// their flags and bound values are.
        pub fn hash(bytes: []const u8) u64 {
            const range = decode(bytes);
            var code: u64 = 0x9e3779b97f4a7c15 ^ (@as(u64, bytes[0]) << 8 | bytes[1]);
            if (!range.lower.infinite and !range.empty) code = mix(code, V.hash(&range.lower.value));
            if (!range.upper.infinite and !range.empty) code = mix(code, V.hash(&range.upper.value) ^ 0x5bd1e995);
            return code;
        }

        fn mix(code: u64, word: u64) u64 {
            var out = (code ^ word) *% 0xff51afd7ed558ccd;
            out ^= out >> 33;
            return out;
        }

        pub fn discrete(subtype: DataType) bool {
            return subtype == .integer32 or subtype == .integer or subtype == .date;
        }

        /// The discrete successor of a bound value (int4pl/int8pl/date + 1).
        fn successor(subtype: DataType, value: *const Cell) Error!Cell {
            return switch (subtype) {
                .integer32 => if (value.integer >= 2147483647) error.IntegerOverflow else Cell{ .integer = value.integer + 1 },
                .integer => if (value.integer == 9223372036854775807) error.IntegerOverflow else Cell{ .integer = value.integer + 1 },
                // daterange_canonical leaves infinite dates alone.
                .date => if (value.date == 2147483647 or value.date == -2147483648) value.* else Cell{ .date = value.date + 1 },
                else => value.*,
            };
        }

        /// make_range: 22000 when the lower bound is above the upper one;
        /// equal bounds that are not both inclusive make an empty range;
        /// discrete subtypes are canonicalized to [lower, upper).
        pub fn make(subtype: DataType, lower_in: Bound, upper_in: Bound, empty_in: bool) Error!Range {
            var lower = lower_in;
            var upper = upper_in;
            lower.lower = true;
            upper.lower = false;
            if (lower.infinite) lower.inclusive = false;
            if (upper.infinite) upper.inclusive = false;
            var empty = empty_in;
            if (!empty and !lower.infinite and !upper.infinite) {
                const order = V.compare(&lower.value, &upper.value);
                if (order > 0) return error.DataException;
                if (order == 0 and !(lower.inclusive and upper.inclusive)) empty = true;
            }
            if (empty) return .{ .subtype = subtype, .empty = true };
            if (discrete(subtype)) {
                if (!lower.infinite and !lower.inclusive) {
                    lower.value = try successor(subtype, &lower.value);
                    lower.inclusive = true;
                }
                if (!upper.infinite and upper.inclusive) {
                    upper.value = try successor(subtype, &upper.value);
                    upper.inclusive = false;
                }
                if (!lower.infinite and !upper.infinite and V.compare(&lower.value, &upper.value) >= 0) return .{ .subtype = subtype, .empty = true };
            }
            return .{ .subtype = subtype, .lower = lower, .upper = upper };
        }

        // ---- operators (rangetypes.c) ---------------------------------------

        pub fn containsElement(range: *const Range, value: *const Cell) bool {
            if (range.empty) return false;
            if (!range.lower.infinite) {
                const order = V.compare(&range.lower.value, value);
                if (order > 0 or (order == 0 and !range.lower.inclusive)) return false;
            }
            if (!range.upper.infinite) {
                const order = V.compare(&range.upper.value, value);
                if (order < 0 or (order == 0 and !range.upper.inclusive)) return false;
            }
            return true;
        }

        pub fn contains(a: *const Range, b: *const Range) bool {
            if (b.empty) return true;
            if (a.empty) return false;
            return compareBounds(&a.lower, &b.lower) <= 0 and compareBounds(&a.upper, &b.upper) >= 0;
        }

        pub fn overlaps(a: *const Range, b: *const Range) bool {
            if (a.empty or b.empty) return false;
            if (compareBounds(&a.lower, &b.lower) >= 0 and compareBounds(&a.lower, &b.upper) <= 0) return true;
            if (compareBounds(&b.lower, &a.lower) >= 0 and compareBounds(&b.lower, &a.upper) <= 0) return true;
            return false;
        }

        /// << (strictly left) and >> (strictly right).
        pub fn before(a: *const Range, b: *const Range) bool {
            if (a.empty or b.empty) return false;
            return compareBounds(&a.upper, &b.lower) < 0;
        }

        /// &< (does not extend to the right) and &> (not to the left).
        pub fn overLeft(a: *const Range, b: *const Range) bool {
            if (a.empty or b.empty) return false;
            return compareBounds(&a.upper, &b.upper) <= 0;
        }

        pub fn overRight(a: *const Range, b: *const Range) bool {
            if (a.empty or b.empty) return false;
            return compareBounds(&a.lower, &b.lower) >= 0;
        }

        /// bounds_adjacent(upper, lower).
        fn boundsAdjacent(subtype: DataType, upper: Bound, lower: Bound) Error!bool {
            const order = compareValues(&upper, &lower);
            if (order < 0) {
                if (!discrete(subtype)) return false;
                var from = upper;
                var to = lower;
                from.inclusive = !from.inclusive;
                to.inclusive = !to.inclusive;
                const between = try make(subtype, from, to, false);
                return between.empty;
            }
            if (order == 0) return upper.inclusive != lower.inclusive;
            return false;
        }

        /// -|- (adjacent).
        pub fn adjacent(a: *const Range, b: *const Range) Error!bool {
            if (a.empty or b.empty) return false;
            return (try boundsAdjacent(a.subtype, a.upper, b.lower)) or (try boundsAdjacent(a.subtype, b.upper, a.lower));
        }

        /// + (union): 22000 when the result would not be contiguous.
        pub fn merge(a: *const Range, b: *const Range) Error!Range {
            if (b.empty) return a.*;
            if (a.empty) return b.*;
            if (!overlaps(a, b) and !try adjacent(a, b)) return error.DataException;
            const lower = if (compareBounds(&a.lower, &b.lower) < 0) a.lower else b.lower;
            const upper = if (compareBounds(&a.upper, &b.upper) > 0) a.upper else b.upper;
            return make(a.subtype, lower, upper, false);
        }

        /// * (intersection).
        pub fn intersect(a: *const Range, b: *const Range) Error!Range {
            if (a.empty or b.empty or !overlaps(a, b)) return .{ .subtype = a.subtype, .empty = true };
            const lower = if (compareBounds(&a.lower, &b.lower) >= 0) a.lower else b.lower;
            const upper = if (compareBounds(&a.upper, &b.upper) <= 0) a.upper else b.upper;
            return make(a.subtype, lower, upper, false);
        }

        /// - (difference): 22000 when the result would not be contiguous.
        pub fn minus(a: *const Range, b: *const Range) Error!Range {
            if (a.empty or b.empty) return a.*;
            const l1l2 = compareBounds(&a.lower, &b.lower);
            const l1u2 = compareBounds(&a.lower, &b.upper);
            const u1l2 = compareBounds(&a.upper, &b.lower);
            const u1u2 = compareBounds(&a.upper, &b.upper);
            if (l1l2 < 0 and u1u2 > 0) return error.DataException;
            if (l1u2 > 0 or u1l2 < 0) return a.*;
            if (l1l2 >= 0 and u1u2 <= 0) return .{ .subtype = a.subtype, .empty = true };
            if (l1l2 <= 0 and u1l2 >= 0 and u1u2 <= 0) {
                var upper = b.lower;
                upper.inclusive = !upper.inclusive;
                upper.lower = false;
                return make(a.subtype, a.lower, upper, false);
            }
            var lower = b.upper;
            lower.inclusive = !lower.inclusive;
            lower.lower = true;
            return make(a.subtype, lower, a.upper, false);
        }
    };
}
