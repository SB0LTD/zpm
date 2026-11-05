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
const datetime_format = @import("datetime_format.sig");
const float_text = @import("float_text.sig");
const bytea_module = @import("bytea.sig");
const builtins = @import("functions_eval.sig");
const stats = @import("aggregates_stat.sig");
const array_eval = @import("array_eval.sig");
const range_eval = @import("range_eval.sig");
const network = @import("network.sig");
const geometric = @import("geometric.sig");
const xml_module = @import("xml.sig");
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

/// int2/int4/int8 bitwise operators. Shift counts are masked to the
/// operand width as on x86-64/AArch64 PostgreSQL builds (C shifts of the
/// promoted int, then truncation for int2); bits shifted out are lost.
pub fn bitwise(op: ast.Op, ty: ast.Type, left: i64, right: i64) i64 {
    return switch (op) {
        .bit_and => left & right,
        .bit_or => left | right,
        .bit_xor => left ^ right,
        .shift_left, .shift_right => if (ty == .int8) blk: {
            const count: u6 = @intCast(right & 63);
            break :blk if (op == .shift_left) left << count else left >> count;
        } else blk: {
            const count: u5 = @intCast(right & 31);
            const narrow: i32 = @intCast(left);
            const shifted: i32 = if (op == .shift_left) narrow << count else narrow >> count;
            break :blk if (ty == .int2) @as(i16, @truncate(shifted)) else shifted;
        },
        else => unreachable,
    };
}

fn utf8Length(byte: u8) usize {
    if (byte < 0xc0) return 1;
    if (byte < 0xe0) return 2;
    if (byte < 0xf0) return 3;
    return 4;
}

/// LIKE/ILIKE with PostgreSQL's default backslash escape.
pub fn like(text: []const u8, pattern: []const u8, insensitive: bool) Error!bool {
    return likeEscape(text, pattern, "\\", insensitive);
}

pub fn validateLikeEscape(escape: []const u8) Error!void {
    if (escape.len == 0) return;
    if (escape.len > 4) return error.InvalidEscapeSequence;
    // This input is exactly one scalar, not an arbitrary UTF-8 buffer.
    // Validate its lead/length before decoding so malformed input cannot reach
    // a decoder assertion. Scalar decoding also works on native SB0 backends
    // without the whole-buffer validator's vector reduction.
    const unicode = @import("std").unicode;
    const width = unicode.utf8ByteSequenceLength(escape[0]) catch return error.InvalidEscapeSequence;
    if (width != escape.len) return error.InvalidEscapeSequence;
    _ = unicode.utf8Decode(escape) catch return error.InvalidEscapeSequence;
}

fn escapeAt(pattern: []const u8, at: usize, escape: []const u8) bool {
    return escape.len != 0 and escape.len <= pattern.len - at and @import("std").mem.eql(u8, pattern[at..][0..escape.len], escape);
}

/// Empty disables escaping; otherwise escape is exactly one UTF-8 character.
/// Matching uses constant scratch and scans the original pattern directly.
pub fn likeEscape(text: []const u8, pattern: []const u8, escape: []const u8, insensitive: bool) Error!bool {
    try validateLikeEscape(escape);
    return likeMatch(text, pattern, escape, insensitive, null);
}

fn likeMatch(text: []const u8, pattern: []const u8, escape: []const u8, insensitive: bool, control: ?*types.ExecutionControl) Error!bool {
    var t: usize = 0;
    var p: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (control) |active| try active.checkpoint();
        if (p < pattern.len) {
            const escaped = escapeAt(pattern, p, escape);
            const byte = pattern[p];
            if (!escaped and byte == '%') {
                p += 1;
                // Collapse wildcard runs. A following trailing escape is an
                // error even when these underscores consumed the remaining text.
                while (p < pattern.len and !escapeAt(pattern, p, escape)) {
                    if (control) |active| try active.checkpoint();
                    if (pattern[p] == '%') { p += 1; continue; }
                    if (pattern[p] != '_') break;
                    if (t == text.len) return false;
                    t += @min(utf8Length(text[t]), text.len - t);
                    p += 1;
                }
                if (p == pattern.len) return true;
                if (escapeAt(pattern, p, escape) and p + escape.len == pattern.len) return error.InvalidEscapeSequence;
                star_p = p;
                star_t = t;
                continue;
            }
            if (!escaped and byte == '_') {
                t += @min(utf8Length(text[t]), text.len - t);
                p += 1;
                continue;
            }
            const literal_at = p + (if (escaped) escape.len else 0);
            if (literal_at == pattern.len) return error.InvalidEscapeSequence;
            const literal_width = @min(utf8Length(pattern[literal_at]), pattern.len - literal_at);
            const text_width = @min(utf8Length(text[t]), text.len - t);
            const matched = if (insensitive and literal_width == 1 and text_width == 1)
                types.lower(pattern[literal_at]) == types.lower(text[t])
            else text_width == literal_width and @import("std").mem.eql(u8, pattern[literal_at..][0..literal_width], text[t..][0..text_width]);
            if (matched) {
                p = literal_at + literal_width;
                t += text_width;
                continue;
            }
        }
        const resume_at = star_p orelse return false;
        if (star_t == text.len) return false;
        star_t += @min(utf8Length(text[star_t]), text.len - star_t);
        t = star_t;
        p = resume_at;
    }
    // Reaching the end of text does not examine a later trailing escape.
    while (p < pattern.len and pattern[p] == '%' and !escapeAt(pattern, p, escape)) {
        if (control) |active| try active.checkpoint();
        p += 1;
    }
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
            grouping_mask:u64=0,
            session: *const Session = &value_module.default_session,
            /// General engine: one row per FROM item plus the grouped row
            /// (ast.groupRelation); null is a NULL-extended row.
            tuple: [config.relations + 1]?[*]const V.Cell = @splat(null),
            /// Enclosing block's context (correlated columns, `level` > 0).
            outer: ?*const Context = null,
            hook: ?*const Hook = null,
            /// Routine frame (B11 wave 3) read by routine_param nodes; the
            /// innermost context with one wins, else Session.routine_frame.
            frame: ?*const Frame = null,
        };

        /// Values of a running routine: parameters / PL/pgSQL variables and
        /// the NEW and OLD rows of a trigger (null: a NULL record).
        pub const Frame = struct {
            cells: [*]const V.Cell,
            count: usize = 0,
            new: ?*const Row = null,
            old: ?*const Row = null,
        };

        fn routineFrame(ctx: *const Context) ?*const Frame {
            var current: ?*const Context = ctx;
            while (current) |entry| : (current = entry.outer) {
                if (entry.frame) |frame| return frame;
            }
            const shared = ctx.session.routine_frame orelse return null;
            return @ptrCast(@alignCast(shared));
        }

        fn routineValue(ctx: *const Context, n: *const ast.Node) Error!V.Cell {
            const frame = routineFrame(ctx) orelse return error.UnsupportedStatement;
            switch (n.relation) {
                0 => {
                    if (n.integer < 0 or n.integer >= frame.count) return error.UnsupportedStatement;
                    return frame.cells[@intCast(n.integer)];
                },
                1 => return if (frame.new) |row| row[n.column] else .null_value,
                else => return if (frame.old) |row| row[n.column] else .null_value,
            }
        }

        /// A user function call through the session's routine hook; every
        /// argument is evaluated once, left to right.
        fn routineCall(ctx: *const Context, n: *const ast.Node) Error!V.Cell {
            const hook = ctx.session.routines orelse return error.UnsupportedStatement;
            var args: [config.routine_args]V.Cell = undefined;
            var count: usize = 0;
            var item = n.b;
            while (item != none) : (item = node(ctx, item).next) {
                if (count == args.len) return error.ColumnCapacity;
                args[count] = try eval(ctx, item);
                count += 1;
            }
            var out: V.Cell = .null_value;
            try hook.call(hook.ptr, @intCast(n.integer), &args, count, &out);
            return out;
        }

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
            if (types.elementData(known)) |element| {
                // An array: its element type (with the typmod) and `[]`.
                var inner = try formatType(types.typeOid(element), typmod);
                if (inner.text.len + 2 > config.text_bytes) return error.TextCapacity;
                @memcpy(inner.text.bytes[inner.text.len..][0..2], "[]");
                inner.text.len += 2;
                return inner;
            }
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
                .time, .timetz => if (typmod >= 0) {
                    append(&buffer, &at, "time(");
                    number(&buffer, &at, typmod);
                    append(&buffer, &at, if (known == .time) ") without time zone" else ") with time zone");
                    return textCell(buffer[0..at]);
                },
                .bit, .varbit => if (typmod > 0) {
                    append(&buffer, &at, if (known == .bit) "bit(" else "bit varying(");
                    number(&buffer, &at, typmod);
                    append(&buffer, &at, ")");
                    return textCell(buffer[0..at]);
                },
                .varchar, .bpchar => if (typmod > 4) {
                    append(&buffer, &at, if (known == .varchar) "character varying(" else "character(");
                    number(&buffer, &at, typmod - 4);
                    append(&buffer, &at, ")");
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

        /// Session functions through the Database's session hook
        /// (tx-session lane). current_setting and the advisory functions
        /// are strict; set_config's NULL value resets the setting.
        fn sessionFunction(ctx: *const Context, n: *const ast.Node) Error!V.Cell {
            const hook = ctx.session.engine orelse return error.UnsupportedStatement;
            var args: [3]V.Cell = @splat(.null_value);
            var count: usize = 0;
            var item = n.b;
            while (item != ast.none and count < args.len) : (item = ctx.pool.nodes[item].next) {
                args[count] = try eval(ctx, item);
                count += 1;
            }
            var out: V.Text = .{};
            switch (n.func) {
                .pg_backend_pid => {
                    const reply = try hook.call(hook.ptr, .backend_pid, "", "", 0, 0, 0, &out.bytes);
                    return .{ .integer = reply.integer };
                },
                .current_setting => {
                    if (args[0] == .null_value or (count == 2 and args[1] == .null_value)) return .null_value;
                    const missing_ok = count == 2 and args[1].boolean;
                    const reply = try hook.call(hook.ptr, .current_setting, args[0].text.slice(), "", 0, 0, if (missing_ok) 1 else 0, &out.bytes);
                    if (reply.null_value) return .null_value;
                    out.len = reply.len;
                    return .{ .text = out };
                },
                .set_config => {
                    if (args[0] == .null_value) return error.InvalidParameterValue;
                    const local = args[2] != .null_value and args[2].boolean;
                    var flags: u8 = if (local) 1 else 0;
                    if (args[1] == .null_value) flags |= 2;
                    const value = if (args[1] == .null_value) "" else args[1].text.slice();
                    const reply = try hook.call(hook.ptr, .set_config, args[0].text.slice(), value, 0, 0, flags, &out.bytes);
                    if (reply.null_value) return .null_value;
                    out.len = reply.len;
                    return .{ .text = out };
                },
                else => {},
            }
            for (args[0..count]) |arg| if (arg == .null_value) return .null_value;
            var flags: u8 = 0;
            switch (n.func) {
                .pg_try_advisory_lock_shared, .pg_try_advisory_xact_lock_shared, .pg_advisory_unlock_shared => flags |= 1,
                else => {},
            }
            switch (n.func) {
                .pg_try_advisory_xact_lock, .pg_try_advisory_xact_lock_shared => flags |= 2,
                else => {},
            }
            if (count == 2) flags |= 4;
            const kind: value_module.SessionCall = switch (n.func) {
                .pg_advisory_unlock, .pg_advisory_unlock_shared => .advisory_unlock,
                else => .advisory_try_lock,
            };
            const second: i64 = if (count == 2) args[1].integer else 0;
            const reply = try hook.call(hook.ptr, kind, "", "", args[0].integer, second, flags, &out.bytes);
            return .{ .boolean = reply.integer != 0 };
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
            if (n.a != none) return null; // Strict comparison to a NULL record.
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
                    if (n.op == .contains or n.op == .contained or n.op == .exists or n.op == .overlap or n.op == .over_left or n.op == .over_right or n.op == .adjacent or n.op == .within_eq or n.op == .contains_eq or n.op == .same or
                        ((n.op == .shift_left or n.op == .shift_right) and n.ty == .boolean))
                    {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return null;
                        if (left == .range or right == .range) return try range_eval.RangeEval(config, @This()).predicate(n.op, &left, &right);
                        if (left == .point or left == .box) return switch (n.op) {
                            .same => if (left == .point) geometric.samePoint(left.point, right.point) else geometric.sameBox(left.box, right.box),
                            .contains => geometric.containsPoint(left.box, right.point),
                            .contained => geometric.containsPoint(right.box, left.point),
                            else => geometric.overlaps(left.box, right.box),
                        };
                        if (left == .inet) return switch (n.op) {
                            .shift_left => network.within(&left.inet, &right.inet, false),
                            .within_eq => network.within(&left.inet, &right.inet, true),
                            .shift_right => network.within(&right.inet, &left.inet, false),
                            .contains_eq => network.within(&right.inet, &left.inet, true),
                            else => network.overlaps(&left.inet, &right.inet),
                        };
                        if (left == .array) return try array_eval.ArrayEval(config, @This()).containment(n.op, &left, &right, ctx.session);
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
                    var escape: V.Cell = .null_value;
                    if (n.c != none) escape = try eval(ctx, n.c);
                    // like_escape(pattern, escape) is strict independently of
                    // the outer LIKE operator, after evaluating both arguments.
                    if (pattern == .null_value or (n.c != none and escape == .null_value)) return null;
                    const escape_text: []const u8 = if (n.c == none) "\\" else escape.text.slice();
                    try validateLikeEscape(escape_text);
                    if (value == .null_value) return null;
                    // bpchar LIKE text matches the padded value (bpcharlike).
                    const subject = if (value == .bpchar) value.bpchar.slice() else value.text.slice();
                    const matched = try likeMatch(subject, pattern.text.slice(), escape_text, n.insensitive, ctx.session.control);
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
                    if (n.op == .bit_not) return .{ .integer = try checkRange(~value.integer, n.ty) };
                    return Io.negate(&value, n.ty);
                },
                .binary => switch (n.op) {
                    .eq, .ne, .lt, .le, .gt, .ge, .is_distinct, .is_not_distinct, .contains, .contained, .exists, .overlap, .over_left, .over_right, .adjacent, .within_eq, .contains_eq, .same => return boolCell(try truth(ctx, id)),
                    .distance => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        return .{ .float8 = geometric.distance(left.point, right.point) };
                    },
                    .concat => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (types.isArray(n.ty)) {
                            // array_cat / array_append / array_prepend are not strict.
                            const left_array = types.isArray(node(ctx, n.a).ty);
                            const right_array = types.isArray(node(ctx, n.b).ty);
                            const kind: array_eval.ArrayEval(config, @This()).Concat = if (left_array and right_array) .cat else if (left_array) .append else .prepend;
                            return array_eval.ArrayEval(config, @This()).concat(kind, &left, &right, n.ty);
                        }
                        if (left == .null_value or right == .null_value) return .null_value;
                        if (n.ty == .jsonb) {
                            var out: J.Buffer = .{};
                            try J.concatControlled(left.jsonb.slice(), right.jsonb.slice(), &out, ctx.session.control);
                            var value: V.Text = .{};
                            @memcpy(value.bytes[0..out.len], out.bytes[0..out.len]);
                            value.len = out.len;
                            return .{ .jsonb = value };
                        }
                        if (n.ty == .bytea) {
                            var bytes: V.Text = .{};
                            bytes.len = try bytea_module.concat(left.bytea.slice(), right.bytea.slice(), &bytes.bytes);
                            return .{ .bytea = bytes };
                        }
                        var text: V.Text = .{};
                        // anytextcat/textanycat cast booleans to 'true'/'false' (measured on PG18).
                        try appendCell(&text, &left, true, ctx.session);
                        try appendCell(&text, &right, true, ctx.session);
                        return .{ .text = text };
                    },
                    .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
                        // Range << and >> are boolean predicates.
                        if (n.ty == .boolean) return boolCell(try truth(ctx, id));
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        return .{ .integer = bitwise(n.op, n.ty, left.integer, right.integer) };
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
                        if (n.ty == .interval and (n.op == .mul or n.op == .div)) {
                            const span = if (left.* == .interval) left.interval else right.interval;
                            const factor = if (left.* == .interval) right.float8 else left.float8;
                            return .{ .interval = if (n.op == .mul) try stats.intervalMultiply(span, factor) else try stats.intervalDivide(span, factor) };
                        }
                        return Io.arithmetic(n.op, left, right, n.ty, ctx.session);
                    },
                    .arrow, .arrow_text => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        if (node(ctx, n.a).ty == .json) {
                            var out: J.Buffer = .{};
                            const selector: J.JsonSelector = if (right == .integer) .{ .index = right.integer } else .{ .field = right.text.slice() };
                            if (!try J.extractJsonControlled(left.text.slice(), selector, n.op == .arrow_text, &out, ctx.session.control)) return .null_value;
                            var value: V.Text = .{};
                            @memcpy(value.bytes[0..out.len], out.bytes[0..out.len]);
                            value.len = out.len;
                            return .{ .text = value };
                        }
                        const bytes = left.jsonb.slice();
                        const at = if (right == .integer) J.element(bytes, right.integer) else J.field(bytes, right.text.slice());
                        return jsonResult(bytes, at, n.op == .arrow_text);
                    },
                    .path, .path_text => {
                        const left = try eval(ctx, n.a);
                        const right = try eval(ctx, n.b);
                        if (left == .null_value or right == .null_value) return .null_value;
                        if (node(ctx, n.a).ty == .json) {
                            var out: J.Buffer = .{};
                            if (!try J.extractJsonControlled(left.text.slice(), .{ .path = right.text.slice() }, n.op == .path_text, &out, ctx.session.control)) return .null_value;
                            var value: V.Text = .{};
                            @memcpy(value.bytes[0..out.len], out.bytes[0..out.len]);
                            value.len = out.len;
                            return .{ .text = value };
                        }
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
                    .grouping => {
                        var value:i64=0;var item=n.b;
                        while(item!=none):(item=node(ctx,item).next) {
                            const shift:u6=@intCast(n.integer-1-node(ctx,item).integer);
                            value=value*2+@as(i64,@intCast((ctx.grouping_mask>>shift)&1));
                        }
                        return .{.integer=value};
                    },
                    .window_call => unreachable,
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
                    .to_char => {
                        const argument=try eval(ctx,n.b);const format=try eval(ctx,node(ctx,n.b).next);
                        if(argument==.null_value or format==.null_value or format.text.len==0) return .null_value;
                        const us=if(argument==.timestamp) argument.timestamp else argument.timestamptz;
                        if(!temporal.finiteTimestamp(us)) return .null_value;
                        const local=if(argument==.timestamptz) temporal.toLocal(&ctx.session.zone,us) else us;
                        var text:V.Text=.{};
                        text.len=try datetime_format.format(local,format.text.slice(),&text.bytes);
                        return .{.text=text};
                    },
                    .abs, .ceil, .floor, .trunc, .sign, .sqrt => {
                        if(n.planned_null) return .null_value;
                        const argument=try eval(ctx,n.b);
                        const scale_id=node(ctx,n.b).next;
                        const scale:V.Cell=if(scale_id==none) .{.integer=0} else try eval(ctx,scale_id);
                        if(argument==.null_value or scale==.null_value) return .null_value;
                        if(n.ty==.numeric) return .{.numeric=switch(n.func){
                            .abs=>Io.Numerics.absolute(&argument.numeric),.sign=>Io.Numerics.signum(&argument.numeric),
                            .sqrt=>try Io.Numerics.sqrt(&argument.numeric),
                            .ceil,.floor=>try Io.Numerics.directedInteger(&argument.numeric,n.func==.ceil),
                            .trunc=>try Io.Numerics.trunc(&argument.numeric,@intCast(scale.integer)),else=>unreachable}};
                        if(n.ty==.float4) return .{.float4=@abs(argument.float4)};
                        if(n.ty==.float8) return .{.float8=switch(n.func){
                            .sqrt=>blk:{if(argument.float8<0) return error.InvalidArgumentForPowerFunction;break :blk @sqrt(argument.float8);},
                            .abs=>@abs(argument.float8),.ceil=>@ceil(argument.float8),.floor=>@floor(argument.float8),.trunc=>@trunc(argument.float8),
                            .sign=>if(argument.float8>0) @as(f64,1) else if(argument.float8<0) -1 else 0,else=>unreachable}};
                        if(argument.integer==(-0x7fffffffffffffff-1)) return error.IntegerOverflow;
                        return .{.integer=try checkRange(if(argument.integer<0) -argument.integer else argument.integer,n.ty)};
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
                    .lower, .upper, .initcap, .char_length, .octet_length, .bit_length, .substring, .btrim, .ltrim, .rtrim, .strpos, .replace,
                    .left, .right, .repeat, .reverse, .lpad, .rpad, .split_part, .starts_with, .ascii, .chr, .translate, .concat, .concat_ws,
                    .overlay, .to_hex => return builtins.Builtins(config, @This()).call(ctx, n),
                    .power, .ln, .log, .log10, .exp, .mod, .div, .pi, .degrees, .radians, .cbrt, .sin, .cos, .tan, .cot, .asin, .acos, .atan, .atan2, .gcd, .lcm, .scale, .min_scale, .trim_scale => return builtins.Builtins(config, @This()).call(ctx, n),
                    .extract, .extract_tz, .date_part, .date_part_tz, .date_trunc, .date_trunc_tz, .age, .age_tz, .justify_days, .justify_hours, .justify_interval, .make_date, .make_timestamp, .isfinite => return builtins.Builtins(config, @This()).call(ctx, n),
                    .overlaps, .overlaps_tz => return builtins.Builtins(config, @This()).call(ctx, n),
                    .to_date, .to_number, .to_timestamp => return builtins.Builtins(config, @This()).call(ctx, n),
                    .normalize, .is_normalized => return builtins.Builtins(config, @This()).call(ctx, n),
                    .array_constructor, .array_subscript, .array_any, .array_length, .cardinality, .array_ndims, .array_dims, .array_lower, .array_upper,
                    .array_append, .array_prepend, .array_cat, .array_to_string => return array_eval.ArrayEval(config, @This()).call(ctx, n),
                    .range_constructor, .range_lower, .range_upper, .isempty, .lower_inc, .upper_inc, .lower_inf, .upper_inf => return range_eval.RangeEval(config, @This()).call(ctx, n),
                    .current_setting, .set_config, .pg_try_advisory_lock, .pg_try_advisory_lock_shared, .pg_try_advisory_xact_lock, .pg_try_advisory_xact_lock_shared, .pg_advisory_unlock, .pg_advisory_unlock_shared, .pg_backend_pid => return sessionFunction(ctx, n),
                    .xmlparse, .xmlserialize, .xml_is_well_formed, .xml_is_well_formed_document, .xml_is_well_formed_content => {
                        const argument = try eval(ctx, n.b);
                        if (argument == .null_value) return .null_value;
                        const document = n.integer == 1;
                        switch (n.func) {
                            .xmlparse => {
                                const bytes = argument.text.slice();
                                if (document and !xml_module.validDocument(bytes)) return error.InvalidXmlDocument;
                                if (!document and !xml_module.validContent(bytes)) return error.InvalidXmlContent;
                                return .{ .xml = argument.text };
                            },
                            .xmlserialize => {
                                if (document and !xml_module.validDocument(argument.xml.slice())) return error.NotAnXmlDocument;
                                return cast(.{ .text = argument.xml }, .text, n.cast_type, n.typmod, ctx.session);
                            },
                            .xml_is_well_formed, .xml_is_well_formed_content => return .{ .boolean = xml_module.validContent(argument.text.slice()) },
                            else => return .{ .boolean = xml_module.validDocument(argument.text.slice()) },
                        }
                    },
                    .point_constructor, .box_constructor, .area, .center, .width, .height => {
                        if (n.planned_null) return .null_value;
                        const first = try eval(ctx, n.b);
                        const second_id = node(ctx, n.b).next;
                        const second: V.Cell = if (second_id == none) .null_value else try eval(ctx, second_id);
                        if (first == .null_value or (second_id != none and second == .null_value)) return .null_value;
                        return switch (n.func) {
                            .point_constructor => .{ .point = .{ .x = first.float8, .y = second.float8 } },
                            .box_constructor => .{ .box = geometric.fromCorners(first.point, second.point) },
                            .area => .{ .float8 = geometric.area(first.box) },
                            .width => .{ .float8 = geometric.width(first.box) },
                            .height => .{ .float8 = geometric.height(first.box) },
                            else => .{ .point = geometric.center(first.box) },
                        };
                    },
                    .inet_host, .masklen, .inet_family, .inet_network, .broadcast, .netmask => {
                        const argument = try eval(ctx, n.b);
                        if (argument == .null_value) return .null_value;
                        const address = &argument.inet;
                        return switch (n.func) {
                            .inet_host => blk: {
                                var full = address.*;
                                full.bits = full.maxBits();
                                var buffer: [64]u8 = undefined;
                                const shown = network.format(&full, false, &buffer);
                                if (shown.len > config.text_bytes) return error.TextCapacity;
                                var text: V.Text = .{ .len = shown.len };
                                @memcpy(text.bytes[0..shown.len], shown);
                                break :blk V.Cell{ .text = text };
                            },
                            .masklen => .{ .integer = address.bits },
                            .inet_family => .{ .integer = address.family },
                            .inet_network => .{ .inet = network.network(address) },
                            .broadcast => .{ .inet = network.broadcast(address) },
                            else => .{ .inet = network.netmask(address) },
                        };
                    },
                    .aggregate_pair => {
                        // Both inputs are evaluated; NULL skips the row (strict).
                        const y = try eval(ctx, n.b);
                        const x = try eval(ctx, node(ctx, n.b).next);
                        if (y == .null_value or x == .null_value) return .null_value;
                        if (comptime config.text_bytes < 16) {
                            return error.WorkspaceCapacity;
                        } else {
                            var pair: V.Text = .{ .len = 16 };
                            // Little-endian bytes through u64: the native SB0
                            // compiler rejects array/float @bitCast.
                            const y_bits: u64 = @bitCast(y.float8);
                            const x_bits: u64 = @bitCast(x.float8);
                            for (0..8) |i| {
                                pair.bytes[i] = @truncate(y_bits >> @intCast(i * 8));
                                pair.bytes[8 + i] = @truncate(x_bits >> @intCast(i * 8));
                            }
                            return .{ .text = pair };
                        }
                    },
                    .routine => return routineCall(ctx, n),
                    .routine_param => return routineValue(ctx, n),
                    .none => unreachable,
                },
                // $n of an EXECUTEd SQL prepared statement (tx-session lane).
                .param => {
                    const raw = ctx.session.params orelse return error.UndefinedParameter;
                    const values: *const [config.statement_parameters]V.Cell = @ptrCast(@alignCast(raw));
                    if (n.integer < 1 or n.integer > config.statement_parameters) return error.UndefinedParameter;
                    return values[@intCast(n.integer - 1)];
                },
                .when_arm => unreachable,
            }
        }
    };
}
