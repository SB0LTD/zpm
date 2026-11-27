//! Geometric types lseg, line, path, polygon and circle (Layer 0), after
//! geo_ops.c (B11 wave 4, types-ext lane). point and box are geometric.sig.
//!
//! A value lives inline in one cell's byte budget: [0] its Kind, then
//! little-endian float8 words: lseg x1 y1 x2 y2, line A B C, circle x y r;
//! path and polygon store [1] closed (path only), [2..6] the u32 point
//! count and then x y per point. A path or polygon that does not fit the
//! cell is TextCapacity (54000).
//!
//! Input follows path_decode / pair_decode / line_decode / circle_in;
//! output path_encode, line_out and circle_out with float8out. Fuzzy
//! comparisons use EPSILON 1.0E-06 (FPeq, FPlt, ...); float8 arithmetic
//! reports overflow and underflow (22003) and division by zero (22012)
//! like float8_pl / float8_mul / float8_div. None of these types has a
//! btree or hash operator class; the internal byte order only serves
//! internal equality.
const types = @import("types.sig");
const float_text = @import("float_text.sig");
const geometric = @import("geometric.sig");
const Error = types.Error;
pub const Point = geometric.Point;
pub const Box = geometric.Box;

pub const Kind = enum(u8) { lseg = 1, line = 2, path = 3, polygon = 4, circle = 5 };

pub const epsilon: f64 = 1.0e-06;

pub fn fpZero(a: f64) bool {
    return @abs(a) <= epsilon;
}
pub fn fpEq(a: f64, b: f64) bool {
    return a == b or @abs(a - b) <= epsilon;
}
pub fn fpNe(a: f64, b: f64) bool {
    return !fpEq(a, b);
}
pub fn fpLt(a: f64, b: f64) bool {
    return b - a > epsilon;
}
pub fn fpLe(a: f64, b: f64) bool {
    return a - b <= epsilon;
}
pub fn fpGt(a: f64, b: f64) bool {
    return a - b > epsilon;
}
pub fn fpGe(a: f64, b: f64) bool {
    return b - a <= epsilon;
}

fn isInf(a: f64) bool {
    return a == a and (a - a) != (a - a);
}
fn isNan(a: f64) bool {
    return a != a;
}

/// float8_pl / float8_mi / float8_mul / float8_div.
pub fn plus(a: f64, b: f64) Error!f64 {
    const r = a + b;
    if (isInf(r) and !isInf(a) and !isInf(b)) return error.NumericValueOutOfRange;
    return r;
}
pub fn minus(a: f64, b: f64) Error!f64 {
    const r = a - b;
    if (isInf(r) and !isInf(a) and !isInf(b)) return error.NumericValueOutOfRange;
    return r;
}
pub fn times(a: f64, b: f64) Error!f64 {
    const r = a * b;
    if (isInf(r) and !isInf(a) and !isInf(b)) return error.NumericValueOutOfRange;
    if (r == 0.0 and a != 0.0 and b != 0.0) return error.NumericValueOutOfRange;
    return r;
}
pub fn divide(a: f64, b: f64) Error!f64 {
    if (b == 0.0 and !isNan(a)) return error.DivisionByZero;
    const r = a / b;
    if (isInf(r) and !isInf(a)) return error.NumericValueOutOfRange;
    if (r == 0.0 and a != 0.0 and !isInf(b)) return error.NumericValueOutOfRange;
    return r;
}

/// pg_hypot.
pub fn hypot(x_in: f64, y_in: f64) Error!f64 {
    if (isInf(x_in) or isInf(y_in)) return @as(f64, 1.0) / @as(f64, 0.0);
    if (isNan(x_in) or isNan(y_in)) return x_in + y_in;
    var x = @abs(x_in);
    var y = @abs(y_in);
    if (x < y) {
        const t = x;
        x = y;
        y = t;
    }
    if (y == 0.0) return x;
    const yx = y / x;
    const r = x * @sqrt(1.0 + yx * yx);
    if (isInf(r)) return error.NumericValueOutOfRange;
    if (r == 0.0) return error.NumericValueOutOfRange;
    return r;
}

/// point_dt.
pub fn distance(a: Point, b: Point) Error!f64 {
    return hypot(try minus(a.x, b.x), try minus(a.y, b.y));
}

/// point_eq_point: FPeq on both coordinates (NaN equal to NaN).
pub fn samePoint(a: Point, b: Point) bool {
    return (fpEq(a.x, b.x) and fpEq(a.y, b.y)) or (isNan(a.x) and isNan(b.x) and isNan(a.y) and isNan(b.y)) or
        (fpEq(a.x, b.x) and isNan(a.y) and isNan(b.y)) or (isNan(a.x) and isNan(b.x) and fpEq(a.y, b.y));
}

/// point_sl.
pub fn slope(a: Point, b: Point) Error!f64 {
    if (fpEq(a.x, b.x)) return @as(f64, 1.0) / @as(f64, 0.0);
    if (fpEq(a.y, b.y)) return 0.0;
    return divide(try minus(a.y, b.y), try minus(a.x, b.x));
}

// ---- in-cell layout --------------------------------------------------------------

fn readWord(bytes: []const u8, at: usize) f64 {
    var bits: u64 = 0;
    for (0..8) |index| bits |= @as(u64, bytes[at + index]) << @intCast(index * 8);
    return @bitCast(bits);
}

pub fn kindOf(bytes: []const u8) Kind {
    return @enumFromInt(bytes[0]);
}

/// Word `index` of a fixed-size value (lseg, line, circle).
pub fn word(bytes: []const u8, index: usize) f64 {
    return readWord(bytes, 1 + index * 8);
}

pub fn count(bytes: []const u8) usize {
    return @as(usize, bytes[2]) | @as(usize, bytes[3]) << 8 | @as(usize, bytes[4]) << 16 | @as(usize, bytes[5]) << 24;
}

pub fn closed(bytes: []const u8) bool {
    return bytes[1] != 0;
}

pub fn pointAt(bytes: []const u8, index: usize) Point {
    return .{ .x = readWord(bytes, 6 + index * 16), .y = readWord(bytes, 6 + index * 16 + 8) };
}

pub const Lseg = struct { a: Point, b: Point };
pub const Line = struct { a: f64, b: f64, c: f64 };
pub const Circle = struct { center: Point, radius: f64 };

pub fn lseg(bytes: []const u8) Lseg {
    return .{ .a = .{ .x = word(bytes, 0), .y = word(bytes, 1) }, .b = .{ .x = word(bytes, 2), .y = word(bytes, 3) } };
}
pub fn line(bytes: []const u8) Line {
    return .{ .a = word(bytes, 0), .b = word(bytes, 1), .c = word(bytes, 2) };
}
pub fn circle(bytes: []const u8) Circle {
    return .{ .center = .{ .x = word(bytes, 0), .y = word(bytes, 1) }, .radius = word(bytes, 2) };
}

/// Builds a value into caller-owned bytes.
pub const Writer = struct {
    bytes: []u8,
    len: usize = 0,

    fn put(self: *Writer, byte: u8) Error!void {
        if (self.len == self.bytes.len) return error.TextCapacity;
        self.bytes[self.len] = byte;
        self.len += 1;
    }

    pub fn float(self: *Writer, value: f64) Error!void {
        // Normalize -0 like PostgreSQL's arithmetic would not; keep bits.
        const bits: u64 = @bitCast(value);
        for (0..8) |index| try self.put(@truncate(bits >> @intCast(index * 8)));
    }

    pub fn point(self: *Writer, value: Point) Error!void {
        try self.float(value.x);
        try self.float(value.y);
    }

    pub fn begin(self: *Writer, kind: Kind) Error!void {
        self.len = 0;
        try self.put(@intFromEnum(kind));
    }

    /// A path or polygon header for `points` points.
    pub fn beginPoints(self: *Writer, kind: Kind, is_closed: bool, points: usize) Error!void {
        try self.begin(kind);
        try self.put(@intFromBool(is_closed));
        if (points > 0xffffffff) return error.TextCapacity;
        for (0..4) |index| try self.put(@truncate(points >> @intCast(index * 8)));
    }

    pub fn slice(self: *const Writer) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn writeLseg(out: *Writer, value: Lseg) Error!void {
    try out.begin(.lseg);
    try out.point(value.a);
    try out.point(value.b);
}
pub fn writeLine(out: *Writer, value: Line) Error!void {
    try out.begin(.line);
    try out.float(value.a);
    try out.float(value.b);
    try out.float(value.c);
}
pub fn writeCircle(out: *Writer, value: Circle) Error!void {
    try out.begin(.circle);
    try out.point(value.center);
    try out.float(value.radius);
}

// ---- input -------------------------------------------------------------------------

fn space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

const Cursor = struct {
    text: []const u8,
    at: usize = 0,

    fn peek(self: *const Cursor) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    fn skipSpace(self: *Cursor) void {
        while (self.at < self.text.len and space(self.text[self.at])) self.at += 1;
    }

    /// single_decode: a float8 up to the next delimiter (float8in).
    fn number(self: *Cursor) Error!f64 {
        const start = self.at;
        while (self.at < self.text.len) : (self.at += 1) switch (self.text[self.at]) {
            ',', '(', ')', '[', ']', '<', '>', '{', '}' => break,
            else => {},
        };
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

    fn lastOpen(self: *const Cursor) usize {
        var found = self.at;
        for (self.text[self.at..], self.at..) |c, index| if (c == '(') {
            found = index;
        };
        return found;
    }
};

/// path_decode over `points.len` points; returns whether the input used
/// the open delimiter `[`.
fn pathDecode(cursor: *Cursor, open_allowed: bool, points: []Point, out: ?*Writer) Error!bool {
    var depth: usize = 0;
    cursor.skipSpace();
    var open = false;
    if (cursor.peek() == '[') {
        if (!open_allowed) return error.InvalidTextRepresentation;
        open = true;
        depth += 1;
        cursor.at += 1;
    } else if (cursor.peek() == '(') {
        var inner = cursor.at + 1;
        while (inner < cursor.text.len and space(cursor.text[inner])) inner += 1;
        if (inner < cursor.text.len and cursor.text[inner] == '(') {
            depth += 1;
            cursor.at = inner;
        } else if (cursor.lastOpen() == cursor.at) {
            depth += 1;
            cursor.at = inner;
        }
    }
    for (points) |*slot| {
        const point = try cursor.pair();
        if (out) |writer| try writer.point(point) else slot.* = point;
        if (cursor.peek() == ',') cursor.at += 1;
    }
    while (depth > 0) {
        if (cursor.peek() == ')' or (cursor.peek() == ']' and open and depth == 1)) {
            depth -= 1;
            cursor.at += 1;
            cursor.skipSpace();
        } else return error.InvalidTextRepresentation;
    }
    return open;
}

/// pair_count: the number of points of `,`-separated pairs (an odd
/// count of commas), or null.
fn pairCount(text: []const u8) ?usize {
    var commas: usize = 0;
    for (text) |c| if (c == ',') {
        commas += 1;
    };
    return if (commas % 2 == 1) (commas + 1) / 2 else null;
}

pub fn parseLseg(input: []const u8, out: *Writer) Error!void {
    var cursor: Cursor = .{ .text = input };
    var points: [2]Point = undefined;
    _ = try pathDecode(&cursor, true, &points, null);
    if (cursor.at != input.len) return error.InvalidTextRepresentation;
    try writeLseg(out, .{ .a = points[0], .b = points[1] });
}

/// line_in: `{A,B,C}` (A and B not both zero) or two distinct points.
pub fn parseLine(input: []const u8, out: *Writer) Error!void {
    var cursor: Cursor = .{ .text = input };
    cursor.skipSpace();
    if (cursor.peek() == '{') {
        cursor.at += 1;
        var words: [3]f64 = undefined;
        for (&words, 0..) |*w, index| {
            w.* = try cursor.number();
            const want: u8 = if (index == 2) '}' else ',';
            if (cursor.peek() != want) return error.InvalidTextRepresentation;
            cursor.at += 1;
        }
        cursor.skipSpace();
        if (cursor.at != input.len) return error.InvalidTextRepresentation;
        if (fpZero(words[0]) and fpZero(words[1])) return error.InvalidTextRepresentation;
        return writeLine(out, .{ .a = words[0], .b = words[1], .c = words[2] });
    }
    var points: [2]Point = undefined;
    _ = try pathDecode(&cursor, true, &points, null);
    if (cursor.at != input.len) return error.InvalidTextRepresentation;
    if (samePoint(points[0], points[1])) return error.InvalidTextRepresentation;
    try writeLine(out, try lineThrough(points[0], try slope(points[0], points[1])));
}

/// line_construct.
pub fn lineThrough(point: Point, m: f64) Error!Line {
    if (isInf(m)) return .{ .a = -1.0, .b = 0.0, .c = point.x };
    if (m == 0) return .{ .a = 0.0, .b = -1.0, .c = point.y };
    var c = try minus(point.y, try times(m, point.x));
    if (c == 0.0) c = 0.0;
    return .{ .a = m, .b = -1.0, .c = c };
}

/// path_in: an optional single leading `(` around a path_decode list.
pub fn parsePath(input: []const u8, out: *Writer) Error!void {
    const points = pairCount(input) orelse return error.InvalidTextRepresentation;
    var cursor: Cursor = .{ .text = input };
    cursor.skipSpace();
    var depth: usize = 0;
    if (cursor.peek() == '(' and cursor.lastOpen() == cursor.at) {
        cursor.at += 1;
        depth = 1;
    }
    try out.beginPoints(.path, false, points);
    var scratch: [1]Point = undefined;
    const open = try pathDecodeInto(&cursor, true, points, &scratch, out);
    if (depth == 1) {
        if (cursor.peek() != ')') return error.InvalidTextRepresentation;
        cursor.at += 1;
        cursor.skipSpace();
    }
    if (cursor.at != input.len) return error.InvalidTextRepresentation;
    out.bytes[1] = @intFromBool(!open);
}

fn pathDecodeInto(cursor: *Cursor, open_allowed: bool, points: usize, scratch: *[1]Point, out: *Writer) Error!bool {
    // Decode point by point through the writer (no point array).
    var depth: usize = 0;
    cursor.skipSpace();
    var open = false;
    if (cursor.peek() == '[') {
        if (!open_allowed) return error.InvalidTextRepresentation;
        open = true;
        depth += 1;
        cursor.at += 1;
    } else if (cursor.peek() == '(') {
        var inner = cursor.at + 1;
        while (inner < cursor.text.len and space(cursor.text[inner])) inner += 1;
        if (inner < cursor.text.len and cursor.text[inner] == '(') {
            depth += 1;
            cursor.at = inner;
        } else if (cursor.lastOpen() == cursor.at) {
            depth += 1;
            cursor.at = inner;
        }
    }
    _ = scratch;
    for (0..points) |_| {
        try out.point(try cursor.pair());
        if (cursor.peek() == ',') cursor.at += 1;
    }
    while (depth > 0) {
        if (cursor.peek() == ')' or (cursor.peek() == ']' and open and depth == 1)) {
            depth -= 1;
            cursor.at += 1;
            cursor.skipSpace();
        } else return error.InvalidTextRepresentation;
    }
    return open;
}

/// poly_in: path_decode without the open form.
pub fn parsePolygon(input: []const u8, out: *Writer) Error!void {
    const points = pairCount(input) orelse return error.InvalidTextRepresentation;
    var cursor: Cursor = .{ .text = input };
    try out.beginPoints(.polygon, true, points);
    var scratch: [1]Point = undefined;
    _ = try pathDecodeInto(&cursor, false, points, &scratch, out);
    if (cursor.at != input.len) return error.InvalidTextRepresentation;
}

/// circle_in: `<(x,y),r>`, `((x,y),r)`, `(x,y),r` or `x,y,r`; a negative
/// radius is 22P02.
pub fn parseCircle(input: []const u8, out: *Writer) Error!void {
    var cursor: Cursor = .{ .text = input };
    cursor.skipSpace();
    var depth: usize = 0;
    if (cursor.peek() == '<') {
        depth += 1;
        cursor.at += 1;
    } else if (cursor.peek() == '(') {
        var inner = cursor.at + 1;
        while (inner < input.len and space(input[inner])) inner += 1;
        if (inner < input.len and input[inner] == '(') {
            depth += 1;
            cursor.at = inner;
        }
    }
    const center = try cursor.pair();
    if (cursor.peek() == ',') cursor.at += 1;
    const radius = try cursor.number();
    if (radius < 0.0) return error.InvalidTextRepresentation;
    while (depth > 0) {
        if (cursor.peek() == ')' or (cursor.peek() == '>' and depth == 1)) {
            depth -= 1;
            cursor.at += 1;
            cursor.skipSpace();
        } else return error.InvalidTextRepresentation;
    }
    if (cursor.at != input.len) return error.InvalidTextRepresentation;
    try writeCircle(out, .{ .center = center, .radius = radius });
}

// ---- output ------------------------------------------------------------------------

const Text = struct {
    buffer: []u8,
    len: usize = 0,
    fn byte(self: *Text, c: u8) void {
        self.buffer[self.len] = c;
        self.len += 1;
    }
    fn float(self: *Text, value: f64, digits: i8) void {
        self.len += float_text.format(f64, value, digits, self.buffer[self.len..]).len;
    }
    fn point(self: *Text, value: Point, digits: i8) void {
        self.byte('(');
        self.float(value.x, digits);
        self.byte(',');
        self.float(value.y, digits);
        self.byte(')');
    }
};

/// The text of a value; `buffer` must hold 52 bytes per point plus 8.
pub fn format(bytes: []const u8, digits: i8, buffer: []u8) []const u8 {
    var out: Text = .{ .buffer = buffer };
    switch (kindOf(bytes)) {
        .lseg => {
            const value = lseg(bytes);
            out.byte('[');
            out.point(value.a, digits);
            out.byte(',');
            out.point(value.b, digits);
            out.byte(']');
        },
        .line => {
            const value = line(bytes);
            out.byte('{');
            out.float(value.a, digits);
            out.byte(',');
            out.float(value.b, digits);
            out.byte(',');
            out.float(value.c, digits);
            out.byte('}');
        },
        .circle => {
            const value = circle(bytes);
            out.byte('<');
            out.point(value.center, digits);
            out.byte(',');
            out.float(value.radius, digits);
            out.byte('>');
        },
        .path, .polygon => {
            const is_open = kindOf(bytes) == .path and !closed(bytes);
            out.byte(if (is_open) '[' else '(');
            for (0..count(bytes)) |index| {
                if (index != 0) out.byte(',');
                out.point(pointAt(bytes, index), digits);
            }
            out.byte(if (is_open) ']' else ')');
        },
    }
    return buffer[0..out.len];
}

/// The longest text of a value of `bytes.len` bytes.
pub fn formatBytes(len: usize) usize {
    return 16 + (len / 16 + 1) * 52;
}

// ---- geo_ops.c operations ------------------------------------------------------------

/// line_construct through two points (line(point, point): 22023 when equal).
pub fn lineFromPoints(a: Point, b: Point) Error!Line {
    if (samePoint(a, b)) return error.InvalidParameterValue;
    return lineThrough(a, try slope(a, b));
}

/// point_invsl.
fn inverseSlope(a: Point, b: Point) Error!f64 {
    if (fpEq(a.x, b.x)) return 0.0;
    if (fpEq(a.y, b.y)) return @as(f64, 1.0) / @as(f64, 0.0);
    return divide(try minus(a.x, b.x), try minus(b.y, a.y));
}

/// line_invsl.
fn lineInverseSlope(value: Line) Error!f64 {
    if (fpZero(value.a)) return @as(f64, 1.0) / @as(f64, 0.0);
    if (fpZero(value.b)) return 0.0;
    return divide(value.b, value.a);
}

/// line_interpt_line.
fn lineIntersection(l1: Line, l2: Line) Error!?Point {
    var x: f64 = undefined;
    var y: f64 = undefined;
    if (!fpZero(l1.b)) {
        if (fpEq(l2.a, try times(l1.a, try divide(l2.b, l1.b)))) return null;
        x = try divide(try minus(try times(l1.b, l2.c), try times(l2.b, l1.c)), try minus(try times(l1.a, l2.b), try times(l2.a, l1.b)));
        y = try divide(-(try plus(try times(l1.a, x), l1.c)), l1.b);
    } else if (!fpZero(l2.b)) {
        if (fpEq(l1.a, try times(l2.a, try divide(l1.b, l2.b)))) return null;
        x = try divide(try minus(try times(l2.b, l1.c), try times(l1.b, l2.c)), try minus(try times(l2.a, l1.b), try times(l1.a, l2.b)));
        y = try divide(-(try plus(try times(l2.a, x), l2.c)), l2.b);
    } else return null;
    if (x == 0.0) x = 0.0;
    if (y == 0.0) y = 0.0;
    return .{ .x = x, .y = y };
}

/// lseg_contain_point.
pub fn lsegContains(segment: Lseg, point: Point) Error!bool {
    return fpEq(try plus(try distance(point, segment.a), try distance(point, segment.b)), try distance(segment.a, segment.b));
}

/// lseg_interpt_line.
fn lsegLineIntersection(segment: Lseg, value: Line) Error!?Point {
    const through = try lineThrough(segment.a, try slope(segment.a, segment.b));
    const point = (try lineIntersection(through, value)) orelse return null;
    if (!try lsegContains(segment, point)) return null;
    if (samePoint(segment.a, point)) return segment.a;
    if (samePoint(segment.b, point)) return segment.b;
    return point;
}

/// line_closept_point: the distance (NaN when no perpendicular meets).
pub fn lineDistance(value: Line, point: Point) Error!f64 {
    const perpendicular = try lineThrough(point, try lineInverseSlope(value));
    const meet = (try lineIntersection(perpendicular, value)) orelse return @as(f64, 0.0) / @as(f64, 0.0);
    return distance(meet, point);
}

/// lseg_closept_line (distance only).
fn lsegLineDistance(segment: Lseg, value: Line) Error!f64 {
    if (try lsegLineIntersection(segment, value) != null) return 0.0;
    const d1 = try lineDistance(value, segment.a);
    const d2 = try lineDistance(value, segment.b);
    return if (d1 < d2) d1 else d2;
}

/// lseg_closept_point: the closest point of a segment.
fn lsegClosest(segment: Lseg, point: Point) Error!Point {
    const perpendicular = try lineThrough(point, try inverseSlope(segment.a, segment.b));
    if (try lsegLineIntersection(segment, perpendicular)) |meet| return meet;
    const d1 = try lineDistance(perpendicular, segment.a);
    const d2 = try lineDistance(perpendicular, segment.b);
    return if (d1 < d2) segment.a else segment.b;
}

pub fn lsegDistance(segment: Lseg, point: Point) Error!f64 {
    return distance(try lsegClosest(segment, point), point);
}

/// box_closept_point (distance).
pub fn boxDistance(box: Box, point: Point) Error!f64 {
    if (box.high.x >= point.x and box.low.x <= point.x and box.high.y >= point.y and box.low.y <= point.y) return 0.0;
    var corner: Point = .{ .x = box.low.x, .y = box.high.y };
    var best = try lsegDistance(.{ .a = box.low, .b = corner }, point);
    var d = try lsegDistance(.{ .a = box.high, .b = corner }, point);
    if (d < best) best = d;
    corner = .{ .x = box.high.x, .y = box.low.y };
    d = try lsegDistance(.{ .a = box.low, .b = corner }, point);
    if (d < best) best = d;
    d = try lsegDistance(.{ .a = box.high, .b = corner }, point);
    if (d < best) best = d;
    return best;
}

/// line_distance.
pub fn lineLineDistance(l1: Line, l2: Line) Error!f64 {
    if (try lineIntersection(l1, l2) != null) return 0.0;
    var ratio: f64 = 1.0;
    if (!fpZero(l1.a) and !isNan(l1.a) and !fpZero(l2.a) and !isNan(l2.a)) {
        ratio = try divide(l1.a, l2.a);
    } else if (!fpZero(l1.b) and !isNan(l1.b) and !fpZero(l2.b) and !isNan(l2.b)) ratio = try divide(l1.b, l2.b);
    return divide(@abs(try minus(l1.c, try times(ratio, l2.c))), try hypot(l1.a, l1.b));
}

/// dist_ppath_internal (0 for a one-point open path).
pub fn pathDistance(bytes: []const u8, point: Point) Error!f64 {
    var result: f64 = 0.0;
    var have = false;
    const n = count(bytes);
    for (0..n) |i| {
        var previous: usize = undefined;
        if (i > 0) {
            previous = i - 1;
        } else {
            if (!closed(bytes)) continue;
            previous = n - 1;
        }
        const d = try lsegDistance(.{ .a = pointAt(bytes, previous), .b = pointAt(bytes, i) }, point);
        if (!have or d < result) {
            result = d;
            have = true;
        }
    }
    return result;
}

const on_polygon: i32 = 2147483647;

/// lseg_crossing.
fn crossing(x: f64, y: f64, prev_x: f64, prev_y: f64) Error!i32 {
    if (fpZero(y)) {
        if (fpZero(x)) return on_polygon;
        if (fpGt(x, 0)) {
            if (fpZero(prev_y)) return if (fpGt(prev_x, 0.0)) 0 else on_polygon;
            return if (fpLt(prev_y, 0.0)) 1 else -1;
        }
        if (fpZero(prev_y)) return if (fpLt(prev_x, 0.0)) 0 else on_polygon;
        return 0;
    }
    const y_sign: i32 = if (fpGt(y, 0.0)) 1 else -1;
    if (fpZero(prev_y)) return if (fpLt(prev_x, 0.0)) 0 else y_sign;
    if ((y_sign < 0 and fpLt(prev_y, 0.0)) or (y_sign > 0 and fpGt(prev_y, 0.0))) return 0;
    if (fpGe(x, 0.0) and fpGt(prev_x, 0.0)) return 2 * y_sign;
    if (fpLt(x, 0.0) and fpLe(prev_x, 0.0)) return 0;
    const z = try minus(try times(try minus(x, prev_x), y), try times(try minus(y, prev_y), x));
    if (fpZero(z)) return on_polygon;
    if ((y_sign < 0 and fpLt(z, 0.0)) or (y_sign > 0 and fpGt(z, 0.0))) return 0;
    return 2 * y_sign;
}

/// point_inside over the points of a path or polygon: 0 outside, 1
/// inside, 2 on the boundary.
pub fn inside(bytes: []const u8, point: Point) Error!u8 {
    const n = count(bytes);
    const first_point = pointAt(bytes, 0);
    const x0 = try minus(first_point.x, point.x);
    const y0 = try minus(first_point.y, point.y);
    var prev_x = x0;
    var prev_y = y0;
    var total: i64 = 0;
    for (1..n) |i| {
        const p = pointAt(bytes, i);
        const x = try minus(p.x, point.x);
        const y = try minus(p.y, point.y);
        const cross = try crossing(x, y, prev_x, prev_y);
        if (cross == on_polygon) return 2;
        total += cross;
        prev_x = x;
        prev_y = y;
    }
    const cross = try crossing(x0, y0, prev_x, prev_y);
    if (cross == on_polygon) return 2;
    total += cross;
    return if (total != 0) 1 else 0;
}

/// dist_ppoly_internal.
pub fn polygonDistance(bytes: []const u8, point: Point) Error!f64 {
    if (try inside(bytes, point) != 0) return 0.0;
    const n = count(bytes);
    var result = try lsegDistance(.{ .a = pointAt(bytes, 0), .b = pointAt(bytes, n - 1) }, point);
    for (0..n - 1) |i| {
        const d = try lsegDistance(.{ .a = pointAt(bytes, i), .b = pointAt(bytes, i + 1) }, point);
        if (d < result) result = d;
    }
    return result;
}

/// on_ppath.
pub fn pathContains(bytes: []const u8, point: Point) Error!bool {
    if (closed(bytes)) return try inside(bytes, point) != 0;
    const n = count(bytes);
    var a = try distance(point, pointAt(bytes, 0));
    for (0..n - 1) |i| {
        const b = try distance(point, pointAt(bytes, i + 1));
        if (fpEq(try plus(a, b), try distance(pointAt(bytes, i), pointAt(bytes, i + 1)))) return true;
        a = b;
    }
    return false;
}

/// on_pl.
pub fn lineContains(value: Line, point: Point) Error!bool {
    return fpZero(try plus(try plus(try times(value.a, point.x), try times(value.b, point.y)), value.c));
}

/// plist_same: equal point lists in either direction from any start.
pub fn samePolygon(a: []const u8, b: []const u8) bool {
    const n = count(a);
    if (n != count(b)) return false;
    for (0..n) |i| {
        if (!samePoint(pointAt(b, i), pointAt(a, 0))) continue;
        var ii: usize = 1;
        var j: usize = i + 1;
        while (ii < n) : ({
            ii += 1;
            j += 1;
        }) {
            if (j >= n) j = 0;
            if (!samePoint(pointAt(b, j), pointAt(a, ii))) break;
        }
        if (ii == n) return true;
        ii = 1;
        var k: isize = @as(isize, @intCast(i)) - 1;
        while (ii < n) : ({
            ii += 1;
            k -= 1;
        }) {
            if (k < 0) k = @intCast(n - 1);
            if (!samePoint(pointAt(b, @intCast(k)), pointAt(a, ii))) break;
        }
        if (ii == n) return true;
    }
    return false;
}

/// line_eq.
pub fn sameLine(l1: Line, l2: Line) Error!bool {
    if (isNan(l1.a) or isNan(l1.b) or isNan(l1.c) or isNan(l2.a) or isNan(l2.b) or isNan(l2.c))
        return l1.a == l2.a and l1.b == l2.b and l1.c == l2.c;
    var ratio: f64 = 1.0;
    if (!fpZero(l2.a)) {
        ratio = try divide(l1.a, l2.a);
    } else if (!fpZero(l2.b)) {
        ratio = try divide(l1.b, l2.b);
    } else if (!fpZero(l2.c)) ratio = try divide(l1.c, l2.c);
    return fpEq(l1.a, try times(ratio, l2.a)) and fpEq(l1.b, try times(ratio, l2.b)) and fpEq(l1.c, try times(ratio, l2.c));
}

pub fn circleArea(value: Circle) Error!f64 {
    return times(try times(value.radius, value.radius), 3.14159265358979323846);
}

/// box_ar.
pub fn boxArea(box: Box) Error!f64 {
    return times(try minus(box.high.x, box.low.x), try minus(box.high.y, box.low.y));
}

/// path_area (NULL, returned as null, for an open path).
pub fn pathArea(bytes: []const u8) Error!?f64 {
    if (!closed(bytes)) return null;
    const n = count(bytes);
    var area: f64 = 0.0;
    for (0..n) |i| {
        const j = (i + 1) % n;
        area = try plus(area, try times(pointAt(bytes, i).x, pointAt(bytes, j).y));
        area = try minus(area, try times(pointAt(bytes, i).y, pointAt(bytes, j).x));
    }
    return try divide(@abs(area), 2.0);
}

/// path_length.
pub fn pathLength(bytes: []const u8) Error!f64 {
    const n = count(bytes);
    var result: f64 = 0.0;
    for (0..n) |i| {
        var previous: usize = undefined;
        if (i > 0) {
            previous = i - 1;
        } else {
            if (!closed(bytes)) continue;
            previous = n - 1;
        }
        result = try plus(result, try distance(pointAt(bytes, previous), pointAt(bytes, i)));
    }
    return result;
}

pub const Arithmetic = enum { add, sub, mul, div };

/// point_add / point_sub / point_mul (complex) / point_div (complex).
pub fn pointArithmetic(kind: Arithmetic, a: Point, b: Point) Error!Point {
    return switch (kind) {
        .add => .{ .x = try plus(a.x, b.x), .y = try plus(a.y, b.y) },
        .sub => .{ .x = try minus(a.x, b.x), .y = try minus(a.y, b.y) },
        .mul => .{ .x = try minus(try times(a.x, b.x), try times(a.y, b.y)), .y = try plus(try times(a.x, b.y), try times(a.y, b.x)) },
        .div => blk: {
            const d = try plus(try times(b.x, b.x), try times(b.y, b.y));
            break :blk .{ .x = try divide(try plus(try times(a.x, b.x), try times(a.y, b.y)), d), .y = try divide(try minus(try times(a.y, b.x), try times(a.x, b.y)), d) };
        },
    };
}

/// circle (+ - * /) point.
pub fn circleArithmetic(kind: Arithmetic, value: Circle, point: Point) Error!Circle {
    var out: Circle = .{ .center = try pointArithmetic(kind, value.center, point), .radius = value.radius };
    switch (kind) {
        .mul => out.radius = try times(value.radius, try hypot(point.x, point.y)),
        .div => out.radius = try divide(value.radius, try hypot(point.x, point.y)),
        else => {},
    }
    return out;
}

/// poly_to_circle.
pub fn polygonCircle(bytes: []const u8) Error!Circle {
    const n = count(bytes);
    var center: Point = .{};
    for (0..n) |i| center = try pointArithmetic(.add, center, pointAt(bytes, i));
    const scale: f64 = @floatFromInt(n);
    center = .{ .x = try divide(center.x, scale), .y = try divide(center.y, scale) };
    var radius: f64 = 0.0;
    for (0..n) |i| radius = try plus(radius, try distance(pointAt(bytes, i), center));
    return .{ .center = center, .radius = try divide(radius, scale) };
}

/// The bounding box of a polygon's points (make_bound_box).
pub fn boundBox(bytes: []const u8) Box {
    var high = pointAt(bytes, 0);
    var low = high;
    for (1..count(bytes)) |i| {
        const p = pointAt(bytes, i);
        if (p.x > high.x) high.x = p.x;
        if (p.x < low.x) low.x = p.x;
        if (p.y > high.y) high.y = p.y;
        if (p.y < low.y) low.y = p.y;
    }
    return .{ .high = high, .low = low };
}

/// box(circle).
pub fn circleBox(value: Circle) Error!Box {
    const delta = try divide(value.radius, @sqrt(@as(f64, 2.0)));
    return .{ .high = .{ .x = try plus(value.center.x, delta), .y = try plus(value.center.y, delta) }, .low = .{ .x = try minus(value.center.x, delta), .y = try minus(value.center.y, delta) } };
}

/// circle(box).
pub fn boxCircle(box: Box) Error!Circle {
    const center: Point = .{ .x = try divide(try plus(box.high.x, box.low.x), 2.0), .y = try divide(try plus(box.high.y, box.low.y), 2.0) };
    return .{ .center = center, .radius = try distance(center, box.high) };
}

/// polygon(n, circle): 0A000 for radius zero, 22023 below two points.
pub fn circlePolygon(points: i64, value: Circle, out: *Writer) Error!void {
    if (fpZero(value.radius)) return error.UnsupportedStatement;
    if (points < 2) return error.InvalidParameterValue;
    const n: usize = @intCast(points);
    try out.beginPoints(.polygon, true, n);
    const step = try divide(2.0 * 3.14159265358979323846, @floatFromInt(n));
    for (0..n) |i| {
        const angle = try times(step, @floatFromInt(i));
        try out.point(.{ .x = try minus(value.center.x, try times(value.radius, @cos(angle))), .y = try plus(value.center.y, try times(value.radius, @sin(angle))) });
    }
}

/// line_parallel / line_perp / lseg_parallel / lseg_perp.
pub fn lineParallel(l1: Line, l2: Line) Error!bool {
    if (!fpZero(l1.b)) return fpEq(l2.a, try times(l1.a, try divide(l2.b, l1.b)));
    return fpZero(l2.b);
}
pub fn linePerpendicular(l1: Line, l2: Line) Error!bool {
    if (fpZero(l1.a)) return fpZero(l2.b);
    if (fpZero(l2.a)) return fpZero(l1.b);
    if (fpZero(l1.b)) return fpZero(l2.a);
    if (fpZero(l2.b)) return fpZero(l1.a);
    return fpEq(try divide(try times(l1.a, l2.b), try times(l1.b, l2.a)), -1.0);
}
pub fn lsegParallel(a: Lseg, b: Lseg) Error!bool {
    return fpEq(try slope(a.a, a.b), try slope(b.a, b.b));
}
pub fn lsegPerpendicular(a: Lseg, b: Lseg) Error!bool {
    return fpEq(try slope(a.a, a.b), try inverseSlope(b.a, b.b));
}

/// lseg_center.
pub fn lsegCenter(segment: Lseg) Error!Point {
    return .{ .x = try divide(try plus(segment.a.x, segment.b.x), 2.0), .y = try divide(try plus(segment.a.y, segment.b.y), 2.0) };
}

/// polygon(box): low-left, low-high, high-high, high-low.
pub fn boxPolygon(box: Box, out: *Writer) Error!void {
    try out.beginPoints(.polygon, true, 4);
    try out.point(box.low);
    try out.point(.{ .x = box.low.x, .y = box.high.y });
    try out.point(box.high);
    try out.point(.{ .x = box.high.x, .y = box.low.y });
}

/// polygon(path) (22023 for an open path) and path(polygon).
pub fn repoint(bytes: []const u8, kind: Kind, out: *Writer) Error!void {
    if (kind == .polygon and !closed(bytes)) return error.InvalidParameterValue;
    const n = count(bytes);
    try out.beginPoints(kind, true, n);
    for (0..n) |i| try out.point(pointAt(bytes, i));
}

/// Structural validity of replayed bytes (change records).
pub fn valid(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes[0] < 1 or bytes[0] > 5) return false;
    return switch (kindOf(bytes)) {
        .lseg => bytes.len == 33,
        .line => bytes.len == 25 and !(fpZero(word(bytes, 0)) and fpZero(word(bytes, 1))),
        .circle => bytes.len == 25 and !(word(bytes, 2) < 0.0),
        .path, .polygon => bytes.len >= 6 and bytes[1] <= 1 and (kindOf(bytes) == .path or bytes[1] == 1) and
            count(bytes) >= 1 and bytes.len == 6 + count(bytes) * 16,
    };
}
