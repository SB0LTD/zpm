//! Composite (row) values (Layer 0, B11 wave 5 composite lane), after
//! PostgreSQL's rowtypes.c.
//!
//! A record value lives inline in one cell (Config.text_bytes; a larger
//! value is TextCapacity, 54000):
//!   [0..4] type OID u32 (the composite type, or 2249 `record` for an
//!   anonymous record), [4] field count u8, then per field: DataType ordinal
//!   u8, typmod i32, flag u8 (0 NULL, 1 present) and, when present, the value
//!   as an array element payload (array.sig), or for an array-typed field a
//!   u16 length and the array's bytes. Integers are little-endian.
//! Fields are never records (no nesting, so no recursion). The payload is an
//! in-memory encoding: change records use value tag 57 (change_log.sig) and
//! the wire record_out / record_send.
//!
//! Ordering is record_cmp: field by field (two NULLs are equal and NULL sorts
//! after every value), then fewer fields first. Equality (record_eq) is
//! ordering equality, and hashing is consistent with it.
const types = @import("types.sig");
const Error = types.Error;
const DataType = types.DataType;

pub const header_bytes: usize = 5;
/// Fields of one record value (the count is one byte).
pub const max_fields: usize = 255;

fn readU32(bytes: []const u8, at: usize) u32 {
    var value: u32 = 0;
    for (0..4) |index| value |= @as(u32, bytes[at + index]) << @intCast(index * 8);
    return value;
}

fn writeU32(out: []u8, value: u32) void {
    for (0..4) |index| out[index] = @truncate(value >> @intCast(index * 8));
}

/// The record's type OID (2249 for an anonymous record).
pub fn typeOid(bytes: []const u8) u32 {
    if (bytes.len < header_bytes) return types.record_oid;
    return readU32(bytes, 0);
}

/// The number of fields.
pub fn fieldCount(bytes: []const u8) usize {
    if (bytes.len < header_bytes) return 0;
    return bytes[4];
}

/// isspace() in the C locale (record_out quoting, record_in).
pub fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

/// record_out's quoting of one field's text: double quotes when the text
/// is empty or holds a quote, backslash, parenthesis, comma or space;
/// quotes and backslashes are doubled inside them.
pub fn appendQuoted(out: []u8, used: *usize, text: []const u8) Error!void {
    var quote = text.len == 0;
    for (text) |byte| {
        if (byte == '"' or byte == '\\' or byte == '(' or byte == ')' or byte == ',' or space(byte)) {
            quote = true;
            break;
        }
    }
    var need: usize = text.len + if (quote) @as(usize, 2) else 0;
    for (text) |byte| {
        if (byte == '"' or byte == '\\') need += 1;
    }
    if (need > out.len - used.*) return error.TextCapacity;
    var at = used.*;
    if (quote) {
        out[at] = '"';
        at += 1;
    }
    for (text) |byte| {
        if (byte == '"' or byte == '\\') {
            out[at] = byte;
            at += 1;
        }
        out[at] = byte;
        at += 1;
    }
    if (quote) {
        out[at] = '"';
        at += 1;
    }
    used.* = at;
}

/// One field of record_in's text (rowtypes.c): null for an empty unquoted
/// field. `at` starts at the field and ends on its ',' or ')'.
pub const FieldText = struct { len: usize, null_value: bool };

pub fn scanField(input: []const u8, at: *usize, out: []u8) Error!FieldText {
    var i = at.*;
    if (i >= input.len) return error.InvalidTextRepresentation;
    if (input[i] == ',' or input[i] == ')') return .{ .len = 0, .null_value = true };
    var len: usize = 0;
    var quoted = false;
    while (true) {
        if (i >= input.len) return error.InvalidTextRepresentation;
        const byte = input[i];
        if (!quoted and (byte == ',' or byte == ')')) break;
        i += 1;
        var keep: ?u8 = null;
        if (byte == '\\') {
            if (i >= input.len) return error.InvalidTextRepresentation;
            keep = input[i];
            i += 1;
        } else if (byte == '"') {
            if (!quoted) {
                quoted = true;
            } else if (i < input.len and input[i] == '"') {
                keep = '"';
                i += 1;
            } else quoted = false;
        } else keep = byte;
        if (keep) |value| {
            if (len == out.len) return error.TextCapacity;
            out[len] = value;
            len += 1;
        }
    }
    at.* = i;
    return .{ .len = len, .null_value = false };
}

pub fn Records(comptime V: type) type {
    return struct {
        const Cell = V.Cell;
        const Text = V.Text;
        const A = V.Arrays;
        pub const capacity: usize = @as(Text, .{}).bytes.len;

        pub const Field = struct { data_type: DataType = .text, typmod: i32 = -1, cell: Cell = .null_value };

        /// The record's type OID (2249 for an anonymous record).
        pub fn typeOf(bytes: []const u8) u32 {
            return typeOid(bytes);
        }

        pub fn count(bytes: []const u8) usize {
            return fieldCount(bytes);
        }

        /// Appends the fields of one record into `out`.
        pub const Builder = struct {
            out: *Text,
            count: usize = 0,

            pub fn begin(out: *Text, type_oid: u32) Error!Builder {
                if (capacity < header_bytes) return error.TextCapacity;
                out.len = header_bytes;
                writeU32(out.bytes[0..4], type_oid);
                out.bytes[4] = 0;
                return .{ .out = out };
            }

            pub fn append(self: *Builder, data_type: DataType, typmod: i32, cell: *const Cell) Error!void {
                if (self.count == max_fields) return error.ColumnCapacity;
                if (data_type == .record) return error.UnsupportedStatement;
                var head: [6]u8 = undefined;
                head[0] = @intFromEnum(data_type);
                writeU32(head[1..5], @bitCast(typmod));
                head[5] = @intFromBool(cell.* != .null_value);
                try A.putBytes(self.out, &head);
                if (cell.* != .null_value) {
                    if (@as(V.CellTag, cell.*) != V.cellTag(data_type)) return error.TypeMismatch;
                    if (cell.* == .array) {
                        const bytes = cell.array.slice();
                        if (bytes.len > 0xffff) return error.TextCapacity;
                        try A.putBytes(self.out, &.{ @truncate(bytes.len), @truncate(bytes.len >> 8) });
                        try A.putBytes(self.out, bytes);
                    } else try A.encodeElement(self.out, data_type, cell);
                }
                self.count += 1;
                self.out.bytes[4] = @intCast(self.count);
            }
        };

        /// Reads the fields in order.
        pub const Reader = struct {
            bytes: []const u8,
            at: usize = header_bytes,
            index: usize = 0,
            total: usize = 0,

            pub fn init(bytes: []const u8) Reader {
                return .{ .bytes = bytes, .total = fieldCount(bytes) };
            }

            pub fn next(self: *Reader, out: *Field) bool {
                if (self.index >= self.total) return false;
                const raw = self.bytes;
                out.data_type = @enumFromInt(raw[self.at]);
                out.typmod = @bitCast(readU32(raw, self.at + 1));
                const present = raw[self.at + 5] != 0;
                self.at += 6;
                self.index += 1;
                if (!present) {
                    out.cell = .null_value;
                } else if (V.cellTag(out.data_type) == .array) {
                    const len = @as(usize, raw[self.at]) | (@as(usize, raw[self.at + 1]) << 8);
                    self.at += 2;
                    out.cell = .{ .array = Text.fromValueBytes(raw[self.at..][0..len]) };
                    self.at += len;
                } else out.cell = A.decodeElement(raw, &self.at, out.data_type);
                return true;
            }
        };

        /// Field `index` (0-based), or null past the last one.
        pub fn field(bytes: []const u8, index: usize) ?Field {
            var reader = Reader.init(bytes);
            var out: Field = .{};
            while (reader.next(&out)) {
                if (reader.index == index + 1) return out;
            }
            return null;
        }

        /// The record with field `index` replaced by `cell` (of the field's
        /// data type), into `out`.
        pub fn withField(bytes: []const u8, index: usize, cell: *const Cell, out: *Text) Error!void {
            var builder = try Builder.begin(out, typeOid(bytes));
            var reader = Reader.init(bytes);
            var item: Field = .{};
            while (reader.next(&item)) {
                try builder.append(item.data_type, item.typmod, if (reader.index == index + 1) cell else &item.cell);
            }
        }

        /// The same fields under another composite type OID.
        pub fn retyped(bytes: []const u8, type_oid: u32) Text {
            var out = Text.fromValueBytes(bytes);
            if (out.len >= header_bytes and !out.indirect()) writeU32(out.bytes[0..4], type_oid);
            return out;
        }

        pub fn compare(a: []const u8, b: []const u8) i8 {
            var x = Reader.init(a);
            var y = Reader.init(b);
            var p: Field = .{};
            var q: Field = .{};
            while (x.index < x.total and y.index < y.total) {
                _ = x.next(&p);
                _ = y.next(&q);
                const p_null = p.cell == .null_value;
                const q_null = q.cell == .null_value;
                if (p_null and q_null) continue;
                if (p_null) return 1;
                if (q_null) return -1;
                const order = V.compare(&p.cell, &q.cell);
                if (order != 0) return order;
            }
            if (x.total != y.total) return if (x.total < y.total) -1 else 1;
            return 0;
        }

        /// Consistent with compare: the type OID does not take part.
        pub fn hash(bytes: []const u8) u64 {
            var code: u64 = 0x243f6a8885a308d3 ^ @as(u64, fieldCount(bytes));
            var reader = Reader.init(bytes);
            var item: Field = .{};
            while (reader.next(&item)) {
                const word: u64 = if (item.cell == .null_value) 0x6a09e667f3bcc908 else V.hash(&item.cell);
                code = (code ^ word) *% 0xff51afd7ed558ccd;
                code ^= code >> 29;
            }
            return code;
        }

        /// Whether every field is NULL (`IS NULL`) or none is (`IS NOT
        /// NULL`), as PostgreSQL's row null tests.
        pub fn nullTest(bytes: []const u8, want_null: bool) bool {
            var reader = Reader.init(bytes);
            var item: Field = .{};
            while (reader.next(&item)) {
                if ((item.cell == .null_value) != want_null) return false;
            }
            return true;
        }
    };
}
