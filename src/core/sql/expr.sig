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
const value_module = @import("value.sig");
const temporal = @import("temporal.sig");
const float_text = @import("float_text.sig");
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
    if (ty == .int2 and (value < -32768 or value > 32767)) return error.NumericValueOutOfRange;
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
    const Io = value_module.Io(config);
    const J = Io.Documents;
    return struct {
        pub const Row = [config.columns]V.Cell;
        pub const Session = value_module.Session;


        /// Evaluates a subquery node (scalar value, or a boolean/NULL for
        /// EXISTS and IN) for the general query engine.
        pub const Hook = struct {
            ptr: *anyopaque,
            run: *const fn (ptr: *anyopaque, ctx: *const Context, id: u16) Error!V.Cell,
        };

        pub const Context = struct {
            source: []const u8,
            pool: *const Ast.Pool,
            /// Single-table row (simple SELECT and DML): relation 0.
            row: ?*const Row = null,
            session: *const Session = &value_module.default_session,
            /// General engine: one row per FROM item plus the grouped row
            /// (ast.groupRelation); null is a NULL-extended row.
            tuple: [config.relations + 1]?[*]const V.Cell = @splat(null),
            /// Enclosing block's context (correlated columns, `level` > 0).
            outer: ?*const Context = null,
            hook: ?*const Hook = null,
        };

        const null_cell: V.Cell = .null_value;

        pub fn columnRef(ctx: *const Context, n: *const ast.Node) *const V.Cell {
            var owner = ctx;
            var level = n.level;
            while (level != 0) : (level -= 1) owner = owner.outer.?;
            if (owner.row) |row| if (n.relation == 0) return &row[n.column];
            const base = owner.tuple[n.relation] orelse return &null_cell;
            return &base[n.column];
        }

        fn textCell(bytes: []const u8) Error!V.Cell {
            if (bytes.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = bytes.len };
            @memcpy(text.bytes[0..bytes.len], bytes);
            return .{ .text = text };
        }

        fn digitsCell(value: i64) Error!V.Cell {
            var buffer: [24]u8 = undefined;
            var index: usize = buffer.len;
            var magnitude: u64 = if (value < 0) @as(u64, @bitCast(-%value)) else @intCast(value);
            while (true) {
                index -= 1;
                buffer[index] = @intCast('0' + magnitude % 10);
                magnitude /= 10;
                if (magnitude == 0) break;
            }
            if (value < 0) {
                index -= 1;
                buffer[index] = '-';
            }
            return textCell(buffer[index..]);
        }

        /// format_type(oid, typmod): the SQL spelling with NUMERIC(p,s) and
        /// TIMESTAMP[TZ](p) modifiers; `???` for an unknown OID.
        fn formatType(oid: i64, typmod: i64) Error!V.Cell {
            const data_type = if (oid >= 0 and oid <= 0xffffffff) types.typeFromOid(@intCast(oid)) else null;
            const known = data_type orelse return textCell("???");
            var buffer: [64]u8 = undefined;
            var at: usize = 0;
            const append = struct {
                fn f(out: *[64]u8, position: *usize, bytes: []const u8) void {
                    @memcpy(out[position.*..][0..bytes.len], bytes);
                    position.* += bytes.len;
                }
            }.f;
            const number = struct {
                fn f(out: *[64]u8, position: *usize, value: i64) void {
                    var digits: [24]u8 = undefined;
                    var index: usize = digits.len;
                    var magnitude: u64 = @intCast(@max(value, 0));
                    while (true) {
                        index -= 1;
                        digits[index] = @intCast('0' + magnitude % 10);
                        magnitude /= 10;
                        if (magnitude == 0) break;
                    }
                    append(out, position, digits[index..]);
                }
            }.f;
            switch (known) {
                .numeric => if (typmod >= 4) {
                    const packed_value = typmod - 4;
                    append(&buffer, &at, "numeric(");
                    number(&buffer, &at, packed_value >> 16);
                    append(&buffer, &at, ",");
                    number(&buffer, &at, packed_value & 0xffff);
                    append(&buffer, &at, ")");
                    return textCell(buffer[0..at]);
                },
                .timestamp, .timestamptz => if (typmod >= 0) {
                    append(&buffer, &at, "timestamp(");
                    number(&buffer, &at, typmod);
                    append(&buffer, &at, if (known == .timestamp) ") without time zone" else ") with time zone");
                    return textCell(buffer[0..at]);
                },
                else => {},
            }
            return textCell(types.sqlTypeName(known));
        }

        /// Discovery functions and regclass/regtype conversions (design §4.10).
        fn catalogValue(ctx: *const Context, n: *const ast.Node) Error!V.Cell {
            switch (n.func) {
                .current_database => return textCell(ctx.session.database),
                .current_schema => return textCell("public"),
                else => {},
            }
            const first = try eval(ctx, n.b);
            if (first == .null_value) return .null_value;
            switch (n.func) {
                .to_regtype, .regtype_in => {
                    if (types.typeByName(first.text.slice())) |data_type| return .{ .integer = types.typeOid(data_type) };
                    if (n.func == .to_regtype) return .null_value;
                    return error.UndefinedObject;
                },
                .to_regclass, .regclass_in => {
                    const hook = ctx.session.sequences orelse return error.UnsupportedStatement;
                    const oid = try hook.call(hook.ptr, .regclass, first.text.slice(), 0, 0, n.func == .regclass_in);
                    if (oid < 0) return .null_value;
                    return .{ .integer = oid };
                },
                .regtype_out => {
                    const data_type = if (first.integer >= 0 and first.integer <= 0xffffffff) types.typeFromOid(@intCast(first.integer)) else null;
                    if (data_type) |known| return textCell(types.sqlTypeName(known));
                    return digitsCell(first.integer);
                },
                .regclass_out => {
                    const hook = ctx.session.sequences orelse return error.UnsupportedStatement;
                    var buffer: [64]u8 = undefined;
                    if (first.integer >= 0 and first.integer <= 0xffffffff) {
                        if (hook.relation_name(hook.ptr, @intCast(first.integer), &buffer)) |length| return textCell(buffer[0..length]);
                    }
                    return digitsCell(first.integer);
                },
                .format_type => {
                    const second = try eval(ctx, ctx.pool.nodes[n.b].next);
                    return formatType(first.integer, if (second == .null_value) -1 else second.integer);
                },
                .pg_get_expr => return first,
                else => unreachable,
            }
        }

        /// nextval/currval/setval/lastval and identity defaults through the
        /// session's sequence hook (strict: a NULL argument gives NULL).
        fn sequenceValue(ctx: *const Context, n: *const ast.Node) Error!V.Cell {
            const hook = ctx.session.sequences orelse return error.UnsupportedStatement;
            switch (n.func) {
                .lastval => return .{ .integer = try hook.call(hook.ptr, .lastval, "", 0, 0, false) },
                .identity_next => return .{ .integer = try hook.call(hook.ptr, .identity, "", @intCast(n.integer), n.column, false) },
                else => {},
            }
            const name_cell = try eval(ctx, n.b);
            if (name_cell == .null_value) return .null_value;
            // A regclass argument (OID) names the sequence directly.
            var oid: u32 = 0;
            var name: []const u8 = "";
            if (name_cell == .integer) {
                if (name_cell.integer <= 0 or name_cell.integer > 0xffffffff) return error.TableNotFound;
                oid = @intCast(name_cell.integer);
            } else name = name_cell.text.slice();
            if (n.func == .setval) {
                const second = ctx.pool.nodes[n.b].next;
                const amount = try eval(ctx, second);
                if (amount == .null_value) return .null_value;
                var called = true;
                const third = ctx.pool.nodes[second].next;
                if (third != ast.none) {
                    const flag = try eval(ctx, third);
                    if (flag == .null_value) return .null_value;
                    called = flag.boolean;
                }
                return .{ .integer = try hook.call(hook.ptr, .setval, name, oid, amount.integer, called) };
            }
            return .{ .integer = try hook.call(hook.ptr, if (n.func == .nextval) .nextval else .currval, name, oid, 0, false) };
        }

        pub fn literalText(source: []const u8, quoted: lexer.Quoted) V.Text {
            var text: V.Text = .{ .len = quoted.len };
            lexer.decodeQuoted(source, quoted, &text.bytes);
            return text;
        }

        pub fn appendCell(text: *V.Text, cell: *const V.Cell, verbose: bool, session: *const Session) Error!void {
            return Io.appendCell(text, cell, verbose, session);
        }

        pub fn toText(cell: *const V.Cell, verbose: bool, session: *const Session) Error!V.Cell {
            return Io.toText(cell, verbose, session);
        }

        /// Explicit or assignment cast of a value of type `from`.
        pub fn cast(cell: V.Cell, from: ast.Type, to: ast.Type, typmod: i32, session: *const Session) Error!V.Cell {
            return Io.cast(cell, from, to, typmod, session);
        }

        fn node(ctx: *const Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        /// Comparison of binder-compatible operands, also used by sublink folds.
        pub fn compareOp(op: ast.Op, left: *const V.Cell, right: *const V.Cell) ?bool {
            if (op == .is_distinct or op == .is_not_distinct) {
                const left_null = left.* == .null_value;
                const right_null = right.* == .null_value;
                const equal = if (left_null or right_null) left_null and right_null else V.compare(left, right) == 0;
                return if (op == .is_not_distinct) equal else !equal;
            }
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
            if (n.kind == .column) return columnRef(ctx, n);
            scratch.* = try eval(ctx, id);
            return scratch;
        }

        /// Same evaluation/checkpoint contract as eval, borrowing a stable row
        /// column or placing a computed value in caller-owned scratch.
        pub fn evalRef(ctx:*const Context,id:u16,scratch:*V.Cell) Error!*const V.Cell {
            const n=node(ctx,id);
            if(n.kind==.column) {
                try ctx.session.checkpoint();
                return columnRef(ctx,n);
            }
            scratch.*=try eval(ctx,id);
            return scratch;
        }

        fn boolCell(value: ?bool) V.Cell {
            return if (value) |b| .{ .boolean = b } else .null_value;
        }

        fn nullConstant(ctx: *const Context, id: u16) bool {
            const n = node(ctx, id);
            return n.kind == .null_literal or (n.kind == .cast and nullConstant(ctx, n.a));
        }

        fn rowTruth(ctx: *const Context, n: *const ast.Node) Error!?bool {
            var unknown = false;
            var item = n.b;
            while (item != none) : (item = node(ctx, item).next) {
                try ctx.session.checkpoint();
                const pair = node(ctx, item);
                // PostgreSQL folds a strict equality against a literal NULL
                // without evaluating the other operand, even when volatile.
                if ((n.op == .eq or n.op == .ne) and (nullConstant(ctx, pair.a) or nullConstant(ctx, pair.b))) {
                    unknown = true;
                    continue;
                }
                var left_value: V.Cell = undefined; var right_value: V.Cell = undefined;
                const left = try operandRef(ctx, pair.a, &left_value);
                const right = try operandRef(ctx, pair.b, &right_value);
                switch (n.op) {
                    .is_distinct, .is_not_distinct => {
                        if (compareOp(.is_distinct, left, right).?) return n.op == .is_distinct;
                    },
                    .eq, .ne => {
                        if (compareOp(.eq, left, right)) |equal| {
                            if (!equal) return n.op == .ne;
                        } else unknown = true;
                    },
                    .lt, .le, .gt, .ge => {
                        if (left.* == .null_value or right.* == .null_value) return null;
                        const order = V.compare(left, right);
                        if (order != 0) return if (n.op == .lt or n.op == .le) order < 0 else order > 0;
                    },
                    else => unreachable,
                }
            }
            if (unknown) return null;
            return switch (n.op) { .eq, .le, .ge, .is_not_distinct => true, .ne, .lt, .gt, .is_distinct => false, else => unreachable };
        }

        /// Evaluates a boolean-typed expression to TRUE, FALSE or NULL.
        pub fn truth(ctx: *const Context, id: u16) Error!?bool {
            const n = node(ctx, id);
            switch (n.kind) {
                .row_compare => return rowTruth(ctx, n),
                .row_in => {
                    var unknown = false;
                    var item = n.b;
                    while (item != none) : (item = node(ctx, item).next) {
                        try ctx.session.checkpoint();
                        if (try truth(ctx, item)) |matched| {
                            if (matched) return !n.negated;
                        } else unknown = true;
                    }
                    return if (unknown) null else n.negated;
                },
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
                        const arg = node(ctx, n.a);
                        if (arg.kind == .row_constructor) {
                            var item = arg.b;
                            while (item != none) : (item = node(ctx, item).next) {
                                var scratch: V.Cell = undefined;
                                const field = try evalRef(ctx, item, &scratch);
                                if ((field.* == .null_value) != (n.test_kind == .is_null)) return false;
                            }
                            return true;
                        }
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
                    if (n.op == .eq or n.op == .ne or n.op == .lt or n.op == .le or n.op == .gt or n.op == .ge or n.op == .is_distinct or n.op == .is_not_distinct) {
                        // Column operands compare in place, without a cell copy.
                        var left_value: V.Cell = undefined;
                        var right_value: V.Cell = undefined;
                        const left = try operandRef(ctx, n.a, &left_value);
                        const right = try operandRef(ctx, n.b, &right_value);
                        return compareOp(n.op, left, right);
                    }
                    if (n.op == .contains or n.op == .contained or n.op == .exists) {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return null;
                        return switch (n.op) {
                            .contains => J.contains(left.jsonb.slice(), right.jsonb.slice()),
                            .contained => J.contains(right.jsonb.slice(), left.jsonb.slice()),
                            else => J.exists(left.jsonb.slice(), right.text.slice()),
                        };
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

        fn clockValue(ctx: *const Context, func: ast.Func) Error!V.Cell {
            const session = ctx.session;
            const value: ?i64 = switch (func) {
                .now, .transaction_timestamp, .current_timestamp, .current_date => session.transaction_us,
                .statement_timestamp => session.statement_us,
                .clock_timestamp => if (session.clock) |clock| clock() else null,
                else => unreachable,
            };
            const us = value orelse return error.ClockUnavailable;
            if (func == .current_date) return .{ .date = temporal.timestampToDate(temporal.toLocal(&session.zone, us)) };
            return .{ .timestamptz = us };
        }

        fn jsonResult(bytes: []const u8, at: ?usize, as_text: bool) Error!V.Cell {
            const position = at orelse return .null_value;
            if (as_text) {
                var text: V.Text = .{};
                var out: J.Text = .{ .bytes = &text.bytes };
                if (!try J.renderText(bytes, position, &out)) return .null_value;
                text.len = out.len;
                return .{ .text = text };
            }
            var text: V.Text = .{};
            text.len = J.copyValue(bytes, position, &text.bytes).len;
            return .{ .jsonb = text };
        }

        pub fn eval(ctx: *const Context, id: u16) Error!V.Cell {
            try ctx.session.checkpoint();
            const n = node(ctx, id);
            switch (n.kind) {
                .null_literal => return .null_value,
                .bool_literal => return .{ .boolean = n.boolean },
                .int_literal => return .{ .integer = n.integer },
                .text_literal => {
                    if(n.ty==.date and n.date_bound) return .{.date=@intCast(n.integer)};
                    const text = literalText(ctx.source, n.text);
                    return switch (n.ty) {
                        .unknown, .text => .{ .text = text },
                        else => Io.parse(n.ty, n.typmod, text.slice(), ctx.session),
                    };
                },
                .decimal_literal => {
                    if (n.ty == .float4 or n.ty == .float8) return Io.parse(n.ty, -1, n.name.span.slice(ctx.source), ctx.session);
                    const number = try Io.parse(.numeric, -1, n.name.span.slice(ctx.source), ctx.session);
                    return if (n.ty == .numeric or n.ty == .unknown) number else Io.cast(number, .numeric, n.ty, -1, ctx.session);
                },
                .column => return columnRef(ctx, n).*,
                .scalar_subquery, .exists_subquery, .in_subquery => {
                    const hook = ctx.hook orelse return error.UnsupportedStatement;
                    return hook.run(hook.ptr, ctx, id);
                },
                .aggregate => unreachable,
                .values_row, .default_value => return error.Syntax,
                .row_constructor => return error.UnsupportedStatement,
                .row_compare, .row_in => return boolCell(try truth(ctx, id)),
                .and_op, .or_op, .not_op, .test_op, .between, .in_list, .like => return boolCell(try truth(ctx, id)),
                .unary => {
                    const value = try eval(ctx, n.a);
                    if (value == .null_value) return .null_value;
                    if (n.op == .pos) return value;
                    return Io.negate(&value, n.ty);
                },
                .binary => switch (n.op) {
                    .eq, .ne, .lt, .le, .gt, .ge, .is_distinct, .is_not_distinct, .contains, .contained, .exists => return boolCell(try truth(ctx, id)),
                    .concat => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        var text: V.Text = .{};
                        // anytextcat/textanycat cast booleans to 'true'/'false' (measured on PG18).
                        try appendCell(&text, &left, true, ctx.session);
                        try appendCell(&text, &right, true, ctx.session);
                        return .{ .text = text };
                    },
                    .add, .sub, .mul, .div, .mod => {
                        // Preserve left-to-right evaluation, including a right
                        // expression when the left is NULL. Borrow stable row
                        // columns instead of copying the full tagged payload.
                        var left_value: V.Cell = undefined;
                        var right_value: V.Cell = undefined;
                        const left = try evalRef(ctx, n.a, &left_value);
                        const right = try evalRef(ctx, n.b, &right_value);
                        if (left.* == .null_value or right.* == .null_value) return .null_value;
                        if (left.* == .integer and right.* == .integer and value_module.integral(n.ty))
                            return .{ .integer = try arithmetic(n.op, n.ty, left.integer, right.integer) };
                        return Io.arithmetic(n.op, left, right, n.ty, ctx.session);
                    },
                    .arrow, .arrow_text => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        const bytes = left.jsonb.slice();
                        const at = if (right == .integer) J.element(bytes, right.integer) else J.field(bytes, right.text.slice());
                        return jsonResult(bytes, at, n.op == .arrow_text);
                    },
                    .path, .path_text => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        const bytes = left.jsonb.slice();
                        return jsonResult(bytes, try J.path(bytes, right.text.slice()), n.op == .path_text);
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
                    if (n.ty != node(ctx, n.a).ty) {
                        // The binder inserted a comparison-only cast. Retain
                        // its original operand, evaluating volatile values once.
                        const conversion = node(ctx, n.a);
                        @import("std").debug.assert(conversion.kind == .cast);
                        try ctx.session.checkpoint();
                        const original = try eval(ctx, conversion.a);
                        const left = try cast(original, n.ty, conversion.cast_type, conversion.typmod, ctx.session);
                        const right = try eval(ctx, n.b);
                        if (compareOp(.eq, &left, &right) == true) return .null_value;
                        return original;
                    }
                    const left = try eval(ctx, n.a);
                    const right = try eval(ctx, n.b);
                    if (compareOp(.eq, &left, &right) == true) return .null_value;
                    return left;
                },
                .cast => {
                    if(n.cast_type==.date and n.date_bound) {
                        // The binder already parsed this literal child. Keep
                        // its observable evaluation checkpoint, then borrow
                        // the exact day count without repeating conversion.
                        try ctx.session.checkpoint();return .{.date=@intCast(n.integer)};
                    }
                    const value = try eval(ctx, n.a);
                    return cast(value, node(ctx, n.a).ty, n.cast_type, n.typmod, ctx.session);
                },
                .at_zone => {
                    const value = try eval(ctx, n.a);
                    const zone = try eval(ctx, n.b);
                    if (value == .null_value or zone == .null_value) return .null_value;
                    return Io.atZone(&value, zone.text.slice(), ctx.session);
                },
                .function => switch (n.func) {
                    .greatest, .least => {
                        var best: V.Cell = .null_value;
                        var item = n.b;
                        while (item != none) : (item = node(ctx, item).next) {
                            const candidate = try eval(ctx, item);
                            if (candidate == .null_value) continue;
                            if (best == .null_value) { best = candidate; continue; }
                            const order = V.compare(&candidate, &best);
                            if ((n.func == .greatest and order > 0) or (n.func == .least and order < 0)) best = candidate;
                        }
                        return best;
                    },
                    .round => {
                        const argument = try eval(ctx, n.b);
                        const scale_id = node(ctx, n.b).next;
                        const scale: V.Cell = if (scale_id == none) .{ .integer = 0 } else try eval(ctx, scale_id);
                        if (argument == .null_value or scale == .null_value) return .null_value;
                        if (n.ty == .float8) return .{ .float8 = float_text.rint(argument.float8) };
                        return .{ .numeric = try Io.Numerics.round(&argument.numeric, @intCast(scale.integer)) };
                    },
                    .now, .transaction_timestamp, .statement_timestamp, .clock_timestamp, .current_timestamp, .current_date => return clockValue(ctx, n.func),
                    .jsonb_typeof, .jsonb_array_length => {
                        const argument = try eval(ctx, n.b);
                        if (argument == .null_value) return .null_value;
                        const bytes = argument.jsonb.slice();
                        if (n.func == .jsonb_array_length) return .{ .integer = try J.arrayLength(bytes) };
                        var text: V.Text = .{};
                        const name = J.typeName(bytes);
                        @memcpy(text.bytes[0..name.len], name);
                        text.len = name.len;
                        return .{ .text = text };
                    },
                    .nextval, .currval, .setval, .lastval, .identity_next => return sequenceValue(ctx, n),
                    .current_database, .current_schema, .to_regtype, .to_regclass, .format_type, .pg_get_expr, .regclass_in, .regtype_in, .regclass_out, .regtype_out => return catalogValue(ctx, n),
                    .none => unreachable,
                },
                .param, .when_arm => unreachable,
            }
        }
    };
}
