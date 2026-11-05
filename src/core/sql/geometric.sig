//! Geometric types (Layer 0), after geo_ops.c: point and box.
//!
//! point_in/box_in read float8 coordinates with pair_decode/path_decode
//! (optional parentheses, surrounding whitespace); anything else is 22P02.
//! A box keeps its upper-right corner first: input corners are reordered.
//! Output uses float8out (extra_float_digits 1): `(x,y)` and
//! `(x2,y2),(x1,y1)`. Fuzzy comparisons use EPSILON 1.0E-06 like FPeq/FPle.
//! PostgreSQL has no btree ordering for either type; the cell order here is
//! only an internal total order (ORDER BY/GROUP BY of these types are 42883).
const types = @import("types.sig");
const float_text = @import("float_text.sig");
const Error = types.Error;

pub const Point = struct { x: f64 = 0, y: f64 = 0 };
pub const Box = struct { high: Point = .{}, low: Point = .{} };

const epsilon: f64 = 1.0e-06;

fn fuzzyEqual(a: f64, b: f64) bool {
    return a == b or @abs(a - b) <= epsilon;
}

fn fuzzyLessEqual(a: f64, b: f64) bool {
    return a - b <= epsilon;
}

fn space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

const Cursor = struct {
    text: []const u8,
    at: usize = 0,

    fn skipSpace(self: *Cursor) void {
        while (self.at < self.text.len and space(self.text[self.at])) self.at += 1;
    }

    fn peek(self: *const Cursor) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    /// single_decode: a float8 ending at a delimiter (float8in rules).
    fn number(self: *Cursor) Error!f64 {
        const start = self.at;
        while (self.at < self.text.len and self.text[self.at] != ',' and self.text[self.at] != ')' and self.text[self.at] != '(') self.at += 1;
        return float_text.parse(f64, self.text[start..self.at]) catch |err| return if (err == error.NumericValueOutOfRange) err else error.InvalidTextRepresentation;
    }

    /// pair_decode: `x,y` or `(x,y)`.
    fn pair(self: *Cursor) Error!Point {
        self.skipSpace();
        const delimited = self.peek() == '(';
        if (delimited) self.at += 1;
        const x = try self.number();
        if (self.peek() != ',') return error.InvalidTextRepresentation;
        self.at += 1;
        const y = try self.number();
        if (delimited) {
            if (self.peek() != ')') return error.InvalidTextRepresentation;
            self.at += 1;
            self.skipSpace();
        }
        return .{ .x = x, .y = y };
    }
};

pub fn parsePoint(input: []const u8) Error!Point {
    var cursor: Cursor = .{ .text = input };
    const point = try cursor.pair();
    if (cursor.at != input.len) return error.InvalidTextRepresentation;
    return point;
}

/// box_in: `(x1,y1),(x2,y2)`, `((x1,y1),(x2,y2))`, `x1,y1,x2,y2` or
/// `(x1,y1,x2,y2)`; the corners are reordered high/low.
pub fn parseBox(input: []const u8) Error!Box {
    var cursor: Cursor = .{ .text = input };
    cursor.skipSpace();
    var depth: usize = 0;
    if (cursor.peek() == '(') {
        var inner = cursor.at + 1;
        while (inner < input.len and space(input[inner])) inner += 1;
        var last_open = cursor.at;
        for (input, 0..) |c, index| if (c == '(') {
            last_open = index;
        };
        if (inner < input.len and input[inner] == '(') {
            depth = 1;
            cursor.at = inner;
        } else if (last_open == cursor.at) {
            depth = 1;
            cursor.at = inner;
        }
    }
    var corners: [2]Point = undefined;
    for (&corners) |*corner| {
        corner.* = try cursor.pair();
        if (cursor.peek() == ',') cursor.at += 1;
    }
    while (depth > 0) : (depth -= 1) {
        if (cursor.peek() != ')') return error.InvalidTextRepresentation;
        cursor.at += 1;
        cursor.skipSpace();
    }
    if (cursor.at != input.len) return error.InvalidTextRepresentation;
    return fromCorners(corners[0], corners[1]);
}

/// box(point, point) / box_in's corner reordering.
pub fn fromCorners(a: Point, b: Point) Box {
    return .{ .high = .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) }, .low = .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) } };
}

fn pairText(point: Point, buffer: []u8) []const u8 {
    var at: usize = 0;
    buffer[at] = '(';
    at += 1;
    at += float_text.format(f64, point.x, buffer[at..]).len;
    buffer[at] = ',';
    at += 1;
    at += float_text.format(f64, point.y, buffer[at..]).len;
    buffer[at] = ')';
    at += 1;
    return buffer[0..at];
}

/// point_out (at most 2 x 24 + 3 bytes).
pub fn formatPoint(point: Point, buffer: []u8) []const u8 {
    return pairText(point, buffer);
}

/// box_out: the high corner first.
pub fn formatBox(box: Box, buffer: []u8) []const u8 {
    var at = pairText(box.high, buffer).len;
    buffer[at] = ',';
    at += 1;
    at += pairText(box.low, buffer[at..]).len;
    return buffer[0..at];
}

/// An internal total order (floats ordered with NaN last).
fn floatOrder(a: f64, b: f64) i8 {
    const a_nan = a != a;
    const b_nan = b != b;
    if (a_nan or b_nan) return if (a_nan and b_nan) 0 else if (a_nan) 1 else -1;
    return if (a < b) -1 else if (a > b) 1 else 0;
}

pub fn comparePoints(a: Point, b: Point) i8 {
    const order = floatOrder(a.x, b.x);
    return if (order != 0) order else floatOrder(a.y, b.y);
}

pub fn compareBoxes(a: Box, b: Box) i8 {
    const order = comparePoints(a.high, b.high);
    return if (order != 0) order else comparePoints(a.low, b.low);
}

/// point_eq (~=).
pub fn samePoint(a: Point, b: Point) bool {
    return fuzzyEqual(a.x, b.x) and fuzzyEqual(a.y, b.y);
}

/// box_same (~=).
pub fn sameBox(a: Box, b: Box) bool {
    return samePoint(a.high, b.high) and samePoint(a.low, b.low);
}

/// point_distance (<->).
pub fn distance(a: Point, b: Point) f64 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

/// box_contain_pt (@>) / on_pb (<@).
pub fn containsPoint(box: Box, point: Point) bool {
    return box.high.x >= point.x and box.low.x <= point.x and box.high.y >= point.y and box.low.y <= point.y;
}

/// box_ov (&&).
pub fn overlaps(a: Box, b: Box) bool {
    return fuzzyLessEqual(a.low.x, b.high.x) and fuzzyLessEqual(b.low.x, a.high.x) and
        fuzzyLessEqual(a.low.y, b.high.y) and fuzzyLessEqual(b.low.y, a.high.y);
}

pub fn width(box: Box) f64 {
    return box.high.x - box.low.x;
}

pub fn height(box: Box) f64 {
    return box.high.y - box.low.y;
}

pub fn area(box: Box) f64 {
    return width(box) * height(box);
}

pub fn center(box: Box) Point {
    return .{ .x = (box.high.x + box.low.x) / 2.0, .y = (box.high.y + box.low.y) / 2.0 };
}
