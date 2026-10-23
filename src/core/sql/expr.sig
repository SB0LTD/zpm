//! Expression evaluation over bound nodes (Layer 0, design §4.1).
//!
//! Three-valued logic: AND/OR/NOT, IS [NOT] TRUE/FALSE/UNKNOWN/NULL, IN,
//! BETWEEN and LIKE follow PostgreSQL's NULL rules; WHERE keeps a row only
//! when its predicate is TRUE. Integer arithmetic is checked: int4/int8
//! overflow is IntegerOverflow (22003), division or modulo by zero is
//! DivisionByZero (22012), and text input to integer/boolean casts follows
//! int4in/int8in/boolin (22P02 on invalid input). Recursion follows the bound
//! tree, whose depth the parser limits to Config.expr_depth.
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const ast = @import("ast.sig");
const Error = types.Error;
const none = ast.none;

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 0x0b or byte == 0x0c;
}

fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and space(text[start])) start += 1;
    while (end > start and space(text[end - 1])) end -= 1;
    return text[start..end];
}

fn digitValue(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

/// PostgreSQL int4in/int8in: surrounding whitespace, an optional sign,
/// decimal or 0x/0o/0b digits with single underscores between digits.
pub fn parseInteger(input: []const u8, ty: ast.Type) Error!i64 {
    const text = trim(input);
    var index: usize = 0;
    var negative = false;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) {
        negative = text[index] == '-';
        index += 1;
    }
    var base: u64 = 10;
    if (index + 1 < text.len and text[index] == '0') {
        const marker = types.lower(text[index + 1]);
        if (marker == 'x' or marker == 'o' or marker == 'b') {
            base = if (marker == 'x') 16 else if (marker == 'o') 8 else 2;
            index += 2;
        }
    }
    var magnitude: u64 = 0;
    var digits: usize = 0;
    var overflow = false;
    var previous_underscore = false;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '_') {
            if (previous_underscore or (digits == 0 and base == 10)) return error.InvalidTextRepresentation;
            previous_underscore = true;
            continue;
        }
        const value: u64 = digitValue(byte) orelse return error.InvalidTextRepresentation;
        if (value >= base) return error.InvalidTextRepresentation;
        previous_underscore = false;
        digits += 1;
        if (magnitude > (18446744073709551615 - value) / base) overflow = true else magnitude = magnitude * base + value;
    }
    if (digits == 0 or previous_underscore) return error.InvalidTextRepresentation;
    const limit: u64 = if (ty == .int4) 2147483648 else 9223372036854775808;
    if (overflow or magnitude > limit or (!negative and magnitude == limit)) return error.IntegerOverflow;
    if (negative) return if (magnitude == 9223372036854775808) -9223372036854775808 else -@as(i64, @intCast(magnitude));
    return @intCast(magnitude);
}

fn prefixOf(text: []const u8, word: []const u8) bool {
    if (text.len == 0 or text.len > word.len) return false;
    for (text, word[0..text.len]) |a, b| if (types.lower(a) != b) return false;
    return true;
}

/// PostgreSQL boolin: unique prefixes of true/false/yes/no, on/off (two
/// characters at least), 1 and 0, case-insensitive, whitespace trimmed.
pub fn parseBoolean(input: []const u8) Error!bool {
    const text = trim(input);
    if (text.len == 0) return error.InvalidTextRepresentation;
    switch (types.lower(text[0])) {
        't' => if (prefixOf(text, "true")) return true,
        'f' => if (prefixOf(text, "false")) return false,
        'y' => if (prefixOf(text, "yes")) return true,
        'n' => if (prefixOf(text, "no")) return false,
        'o' => if (text.len >= 2) {
            if (prefixOf(text, "on")) return true;
            if (prefixOf(text, "off")) return false;
        },
        '1' => if (text.len == 1) return true,
        '0' => if (text.len == 1) return false,
        else => {},
    }
    return error.InvalidTextRepresentation;
}

pub fn checkRange(value: i64, ty: ast.Type) Error!i64 {
    if (ty == .int4 and (value < -2147483648 or value > 2147483647)) return error.IntegerOverflow;
    return value;
}

pub fn arithmetic(op: ast.Op, ty: ast.Type, left: i64, right: i64) Error!i64 {
    const value: i64 = switch (op) {
        .add => blk: {
            const sum = @addWithOverflow(left, right);
            if (sum[1] != 0) return error.IntegerOverflow;
            break :blk sum[0];
        },
        .sub => blk: {
            const difference = @subWithOverflow(left, right);
            if (difference[1] != 0) return error.IntegerOverflow;
            break :blk difference[0];
        },
        .mul => blk: {
            const product = @mulWithOverflow(left, right);
            if (product[1] != 0) return error.IntegerOverflow;
            break :blk product[0];
        },
        .div => blk: {
            if (right == 0) return error.DivisionByZero;
            if (right == -1) {
                if (left == -9223372036854775808) return error.IntegerOverflow;
                break :blk -left;
            }
            break :blk @divTrunc(left, right);
        },
        .mod => blk: {
            if (right == 0) return error.DivisionByZero;
            if (right == -1) break :blk 0;
            break :blk @rem(left, right);
        },
        else => unreachable,
    };
    return checkRange(value, ty);
}

fn utf8Length(byte: u8) usize {
    if (byte < 0xc0) return 1;
    if (byte < 0xe0) return 2;
    if (byte < 0xf0) return 3;
    return 4;
}

/// LIKE/ILIKE with `%`, `_` (one UTF-8 character) and the default `\` escape.
pub fn like(text: []const u8, pattern: []const u8, insensitive: bool) Error!bool {
    var t: usize = 0;
    var p: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len) {
            const byte = pattern[p];
            if (byte == '%') {
                p += 1;
                star_p = p;
                star_t = t;
                continue;
            }
            if (byte == '_') {
                t += @min(utf8Length(text[t]), text.len - t);
                p += 1;
                continue;
            }
            var literal = byte;
            var width: usize = 1;
            if (byte == '\\') {
                if (p + 1 == pattern.len) return error.InvalidEscapeSequence;
                literal = pattern[p + 1];
                width = 2;
            }
            const matched = if (insensitive) types.lower(literal) == types.lower(text[t]) else literal == text[t];
            if (matched) {
                p += width;
                t += 1;
                continue;
            }
        }
        const resume_at = star_p orelse return false;
        star_t += @min(utf8Length(text[star_t]), text.len - star_t);
        t = star_t;
        p = resume_at;
    }
    while (p < pattern.len and pattern[p] == '%') p += 1;
    if (p < pattern.len and pattern[p] == '\\' and p + 1 == pattern.len) return error.InvalidEscapeSequence;
    return p == pattern.len;
}

pub fn Eval(comptime config: types.Config) type {
    const V = types.Values(config);
    const Ast = ast.Ast(config);
    return struct {
        pub const Row = [config.columns]V.Cell;

        pub const Context = struct {
            source: []const u8,
            pool: *const Ast.Pool,
            row: ?*const Row = null,
        };

        pub fn literalText(source: []const u8, quoted: lexer.Quoted) V.Text {
            var text: V.Text = .{ .len = quoted.len };
            lexer.decodeQuoted(source, quoted, &text.bytes);
            return text;
        }

        fn appendBytes(text: *V.Text, bytes: []const u8) Error!void {
            if (bytes.len > config.text_bytes - text.len) return error.TextCapacity;
            @memcpy(text.bytes[text.len..][0..bytes.len], bytes);
            text.len += bytes.len;
        }

        fn appendInteger(text: *V.Text, value: i64) Error!void {
            var digits: [20]u8 = undefined;
            var index: usize = digits.len;
            var magnitude: u64 = if (value < 0) @as(u64, @bitCast(-%value)) else @intCast(value);
            while (true) {
                index -= 1;
                digits[index] = @intCast('0' + magnitude % 10);
                magnitude /= 10;
                if (magnitude == 0) break;
            }
            if (value < 0) try appendBytes(text, "-");
            try appendBytes(text, digits[index..]);
        }

        /// Text form of a non-NULL cell. `verbose` booleans are true/false
        /// (casts, assignment); otherwise t/f (the output function).
        pub fn appendCell(text: *V.Text, cell: *const V.Cell, verbose: bool) Error!void {
            switch (cell.*) {
                .null_value => {},
                .integer => |value| try appendInteger(text, value),
                .boolean => |value| try appendBytes(text, if (verbose) (if (value) "true" else "false") else (if (value) "t" else "f")),
                .text => |*value| try appendBytes(text, value.slice()),
            }
        }

        pub fn toText(cell: *const V.Cell, verbose: bool) Error!V.Cell {
            if (cell.* == .null_value) return .null_value;
            var text: V.Text = .{};
            try appendCell(&text, cell, verbose);
            return .{ .text = text };
        }

        /// Explicit or assignment cast of a value of type `from`.
        pub fn cast(cell: V.Cell, from: ast.Type, to: ast.TypeName) Error!V.Cell {
            if (cell == .null_value) return .null_value;
            switch (to) {
                .integer, .bigint => {
                    const target: ast.Type = if (to == .integer) .int4 else .int8;
                    return switch (cell) {
                        .integer => |value| .{ .integer = try checkRange(value, target) },
                        .boolean => |value| .{ .integer = @intFromBool(value) },
                        .text => |*value| .{ .integer = try parseInteger(value.slice(), target) },
                        .null_value => unreachable,
                    };
                },
                .boolean => return switch (cell) {
                    .integer => |value| .{ .boolean = value != 0 },
                    .boolean => cell,
                    .text => |*value| .{ .boolean = try parseBoolean(value.slice()) },
                    .null_value => unreachable,
                },
                .text => {
                    _ = from;
                    return toText(&cell, true);
                },
            }
        }

        fn node(ctx: *const Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        fn compareOp(op: ast.Op, left: *const V.Cell, right: *const V.Cell) ?bool {
            if (left.* == .null_value or right.* == .null_value) return null;
            const order = V.compare(left, right);
            return switch (op) {
                .eq => order == 0,
                .ne => order != 0,
                .lt => order < 0,
                .le => order <= 0,
                .gt => order > 0,
                .ge => order >= 0,
                else => unreachable,
            };
        }

        fn operandRef(ctx: *const Context, id: u16, scratch: *V.Cell) Error!*const V.Cell {
            const n = node(ctx, id);
            if (n.kind == .column) return &ctx.row.?[n.column];
            scratch.* = try eval(ctx, id);
            return scratch;
        }

        fn boolCell(value: ?bool) V.Cell {
            return if (value) |b| .{ .boolean = b } else .null_value;
        }

        /// Evaluates a boolean-typed expression to TRUE, FALSE or NULL.
        pub fn truth(ctx: *const Context, id: u16) Error!?bool {
            const n = node(ctx, id);
            switch (n.kind) {
                .and_op => {
                    const left = try truth(ctx, n.a);
                    if (left == false) return false;
                    const right = try truth(ctx, n.b);
                    if (right == false) return false;
                    if (left == null or right == null) return null;
                    return true;
                },
                .or_op => {
                    const left = try truth(ctx, n.a);
                    if (left == true) return true;
                    const right = try truth(ctx, n.b);
                    if (right == true) return true;
                    if (left == null or right == null) return null;
                    return false;
                },
                .not_op => {
                    const value = try truth(ctx, n.a);
                    return if (value) |b| !b else null;
                },
                .test_op => {
                    if (n.test_kind == .is_null or n.test_kind == .is_not_null) {
                        const value = try eval(ctx, n.a);
                        return (value == .null_value) == (n.test_kind == .is_null);
                    }
                    const value = try truth(ctx, n.a);
                    return switch (n.test_kind) {
                        .is_true => value == true,
                        .is_not_true => value != true,
                        .is_false => value == false,
                        .is_not_false => value != false,
                        .is_unknown => value == null,
                        .is_not_unknown => value != null,
                        .is_null, .is_not_null => unreachable,
                    };
                },
                .binary => {
                    if (n.op == .eq or n.op == .ne or n.op == .lt or n.op == .le or n.op == .gt or n.op == .ge) {
                        // Column operands compare in place, without a cell copy.
                        var left_value: V.Cell = undefined;
                        var right_value: V.Cell = undefined;
                        const left = try operandRef(ctx, n.a, &left_value);
                        const right = try operandRef(ctx, n.b, &right_value);
                        return compareOp(n.op, left, right);
                    }
                },
                .between => {
                    // a BETWEEN b AND c is a >= b AND a <= c (PostgreSQL
                    // expands it); NOT BETWEEN is its 3VL negation.
                    const value = try eval(ctx, n.a);
                    const low = try eval(ctx, n.b);
                    const first = compareOp(.ge, &value, &low);
                    var result: ?bool = false;
                    if (first != false) {
                        const high = try eval(ctx, n.c);
                        const second = compareOp(.le, &value, &high);
                        result = if (second == false) false else if (first == null or second == null) null else true;
                    }
                    return if (n.negated) (if (result) |b| !b else null) else result;
                },
                .in_list => {
                    // Every list element is evaluated (PostgreSQL builds the array first).
                    const value = try eval(ctx, n.a);
                    var found = false;
                    var saw_null = value == .null_value;
                    var item = n.b;
                    while (item != none) : (item = node(ctx, item).next) {
                        const candidate = try eval(ctx, item);
                        if (compareOp(.eq, &value, &candidate)) |equal| {
                            if (equal) found = true;
                        } else saw_null = true;
                    }
                    const result: ?bool = if (found) true else if (saw_null) null else false;
                    return if (n.negated) (if (result) |b| !b else null) else result;
                },
                .like => {
                    const value = try eval(ctx, n.a);
                    const pattern = try eval(ctx, n.b);
                    if (value == .null_value or pattern == .null_value) return null;
                    const matched = try like(value.text.slice(), pattern.text.slice(), n.insensitive);
                    return matched != n.negated;
                },
                else => {},
            }
            const value = try eval(ctx, id);
            return switch (value) {
                .null_value => null,
                .boolean => |b| b,
                else => unreachable,
            };
        }

        pub fn eval(ctx: *const Context, id: u16) Error!V.Cell {
            const n = node(ctx, id);
            switch (n.kind) {
                .null_literal => return .null_value,
                .bool_literal => return .{ .boolean = n.boolean },
                .int_literal => return .{ .integer = n.integer },
                .text_literal => return .{ .text = literalText(ctx.source, n.text) },
                .column => return ctx.row.?[n.column],
                .and_op, .or_op, .not_op, .test_op, .between, .in_list, .like => return boolCell(try truth(ctx, id)),
                .unary => {
                    const value = try eval(ctx, n.a);
                    if (value == .null_value) return .null_value;
                    if (n.op == .pos) return value;
                    if (value.integer == -9223372036854775808) return error.IntegerOverflow;
                    return .{ .integer = try checkRange(-value.integer, n.ty) };
                },
                .binary => switch (n.op) {
                    .eq, .ne, .lt, .le, .gt, .ge => return boolCell(try truth(ctx, id)),
                    .concat => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        var text: V.Text = .{};
                        // anytextcat/textanycat cast booleans to 'true'/'false' (measured on PG18).
                        try appendCell(&text, &left, true);
                        try appendCell(&text, &right, true);
                        return .{ .text = text };
                    },
                    .add, .sub, .mul, .div, .mod => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        return .{ .integer = try arithmetic(n.op, n.ty, left.integer, right.integer) };
                    },
                    else => unreachable,
                },
                .case_expr => {
                    var operand: V.Cell = .null_value;
                    if (n.a != none) operand = try eval(ctx, n.a);
                    var arm = n.b;
                    while (arm != none) : (arm = node(ctx, arm).next) {
                        const entry = node(ctx, arm);
                        const hit = if (n.a == none) (try truth(ctx, entry.a)) == true else blk: {
                            const candidate = try eval(ctx, entry.a);
                            break :blk compareOp(.eq, &operand, &candidate) == true;
                        };
                        if (hit) return eval(ctx, entry.b);
                    }
                    return if (n.c != none) eval(ctx, n.c) else .null_value;
                },
                .coalesce => {
                    var item = n.b;
                    while (item != none) : (item = node(ctx, item).next) {
                        const value = try eval(ctx, item);
                        if (value != .null_value) return value;
                    }
                    return .null_value;
                },
                .nullif => {
                    const left = try eval(ctx, n.a);
                    const right = try eval(ctx, n.b);
                    if (compareOp(.eq, &left, &right) == true) return .null_value;
                    return left;
                },
                .cast => {
                    const value = try eval(ctx, n.a);
                    return cast(value, node(ctx, n.a).ty, n.cast_type);
                },
                .decimal_literal, .param, .function, .when_arm => unreachable,
            }
        }
    };
}
