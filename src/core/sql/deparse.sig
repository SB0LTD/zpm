//! Canonical text of column DEFAULT and generation expressions (Layer 0,
//! design §4.10): the form PostgreSQL's pg_get_expr and
//! information_schema.columns show for the supported expression subset.
//! A literal takes the column type (`'x'::text`, `5`, `true`), function calls
//! print as name(args) (nextval's argument as `'s'::regclass`), operators are
//! parenthesized `(a + b)`, casts print `(x)::type`. Anything else falls back
//! to the expression's source text.
const types = @import("types.sig");
const ast = @import("ast.sig");
const lexer = @import("lexer.sig");
const Error = types.Error;
const none = ast.none;

pub fn Deparse(comptime config: types.Config) type {
    const V = types.Values(config);
    const Ast = ast.Ast(config);
    return struct {
        const Writer = struct {
            out: *V.Text,
            fn bytes(self: *Writer, value: []const u8) Error!void {
                if (value.len > config.text_bytes - self.out.len) return error.TextCapacity;
                @memcpy(self.out.bytes[self.out.len..][0..value.len], value);
                self.out.len += value.len;
            }
        };

        const Context = struct {
            pool: *const Ast.Pool,
            source: []const u8,
            fn node(self: *const Context, id: u16) *const ast.Node {
                return &self.pool.nodes[id];
            }
        };

        /// Canonical text of the expression `id` (parsed from `source`)
        /// assigned to a column of `data_type`; the raw source when the
        /// expression is outside the supported subset.
        pub fn column(pool: *const Ast.Pool, source: []const u8, id: u16, data_type: types.DataType, out: *V.Text) Error!void {
            out.len = 0;
            const context: Context = .{ .pool = pool, .source = source };
            var writer: Writer = .{ .out = out };
            if (top(&context, id, data_type, &writer)) |_| return else |err| if (err == error.TextCapacity) return err;
            out.len = 0;
            var raw: Writer = .{ .out = out };
            try raw.bytes(source);
        }

        fn integral(data_type: types.DataType) bool {
            return data_type == .smallint or data_type == .integer32 or data_type == .integer;
        }

        fn quotedLiteral(context: *const Context, n: *const ast.Node, w: *Writer) Error!void {
            var text: V.Text = .{ .len = n.text.len };
            if (n.text.len > config.text_bytes) return error.TextCapacity;
            lexer.decodeQuoted(context.source, n.text, &text.bytes);
            try w.bytes("'");
            for (text.slice()) |byte| try w.bytes(if (byte == '\'') "''" else &[_]u8{byte});
            try w.bytes("'");
        }

        fn top(context: *const Context, id: u16, data_type: types.DataType, w: *Writer) Error!void {
            const n = context.node(id);
            switch (n.kind) {
                .int_literal => {
                    if (!integral(data_type) and data_type != .numeric and data_type != .real and data_type != .double) return error.UnsupportedStatement;
                    try integer(n.integer, w);
                },
                .text_literal => {
                    if (data_type == .boolean or integral(data_type)) return error.UnsupportedStatement;
                    try quotedLiteral(context, n, w);
                    try w.bytes("::");
                    try w.bytes(types.sqlTypeName(data_type));
                },
                .unary => {
                    const inner = context.node(n.a);
                    if (n.op != .neg or inner.kind != .int_literal or !integral(data_type)) return expression(context, id, w);
                    try w.bytes("'-");
                    try integer(inner.integer, w);
                    try w.bytes("'::");
                    try w.bytes(types.sqlTypeName(data_type));
                },
                else => try expression(context, id, w),
            }
        }

        fn integer(value: i64, w: *Writer) Error!void {
            var digits: [24]u8 = undefined;
            var index: usize = digits.len;
            var magnitude: u64 = if (value < 0) @as(u64, @bitCast(-%value)) else @intCast(value);
            while (true) {
                index -= 1;
                digits[index] = @intCast('0' + magnitude % 10);
                magnitude /= 10;
                if (magnitude == 0) break;
            }
            if (value < 0) {
                index -= 1;
                digits[index] = '-';
            }
            try w.bytes(digits[index..]);
        }

        fn opText(op: ast.Op) ?[]const u8 {
            return switch (op) {
                .add => " + ",
                .sub => " - ",
                .mul => " * ",
                .div => " / ",
                .mod => " % ",
                .concat => " || ",
                .eq => " = ", .ne => " <> ", .lt => " < ",
                .le => " <= ", .gt => " > ", .ge => " >= ",
                .is_distinct => " IS DISTINCT FROM ",
                .is_not_distinct => " IS NOT DISTINCT FROM ",
                else => null,
            };
        }

        fn rowText(context: *const Context, head: u16, pair_side: ?bool, w: *Writer) Error!void {
            try w.bytes("ROW(");
            var item = head; var first = true;
            while (item != none) : (item = context.node(item).next) {
                if (!first) try w.bytes(", ");
                const field = if (pair_side) |right| (if (right) context.node(item).b else context.node(item).a) else item;
                try expression(context, field, w);
                first = false;
            }
            try w.bytes(")");
        }

        fn expression(context: *const Context, id: u16, w: *Writer) Error!void {
            const n = context.node(id);
            switch (n.kind) {
                .row_constructor => try rowText(context, n.b, null, w),
                .row_compare => {
                    try w.bytes("(");
                    try rowText(context, n.b, false, w);
                    try w.bytes(opText(n.op) orelse return error.UnsupportedStatement);
                    try rowText(context, n.b, true, w);
                    try w.bytes(")");
                },
                .row_in => {
                    try w.bytes(if (n.negated) "NOT (" else "(");
                    var item = n.b;
                    var first = true;
                    while (item != none) : (item = context.node(item).next) {
                        if (!first) try w.bytes(" OR ");
                        try expression(context, item, w);
                        first = false;
                    }
                    try w.bytes(")");
                },
                .test_op => {
                    try w.bytes("(");
                    try expression(context, n.a, w);
                    try w.bytes(switch (n.test_kind) { .is_null => " IS NULL)", .is_not_null => " IS NOT NULL)", else => return error.UnsupportedStatement });
                },
                .int_literal => try integer(n.integer, w),
                .decimal_literal => try w.bytes(n.name.span.slice(context.source)),
                .bool_literal => try w.bytes(if (n.boolean) "true" else "false"),
                .null_literal => try w.bytes("NULL"),
                .text_literal => {
                    try quotedLiteral(context, n, w);
                    try w.bytes("::text");
                },
                .column => {
                    if (n.qualifier.len != 0 or n.star) return error.UnsupportedStatement;
                    try w.bytes(n.name.span.slice(context.source));
                },
                .binary => {
                    const op = opText(n.op) orelse return error.UnsupportedStatement;
                    try w.bytes("(");
                    try expression(context, n.a, w);
                    try w.bytes(op);
                    try expression(context, n.b, w);
                    try w.bytes(")");
                },
                .function => {
                    if (n.star or n.distinct or n.c != none) return error.UnsupportedStatement;
                    const raw = n.name.span.slice(context.source);
                    var lowered: [64]u8 = undefined;
                    if (raw.len > lowered.len) return error.UnsupportedStatement;
                    for (raw, 0..) |byte, index| lowered[index] = types.lower(byte);
                    const name = lowered[0..raw.len];
                    if (types.same(name, "current_timestamp") or types.same(name, "current_date")) {
                        for (raw, 0..) |byte, index| lowered[index] = if (byte >= 'a' and byte <= 'z') byte - 32 else byte;
                        try w.bytes(lowered[0..raw.len]);
                        return;
                    }
                    try w.bytes(name);
                    try w.bytes("(");
                    var item = n.b;
                    var first = true;
                    while (item != none) : (item = context.node(item).next) {
                        if (!first) try w.bytes(", ");
                        const argument = context.node(item);
                        if (first and types.same(name, "nextval") and argument.kind == .text_literal) {
                            try quotedLiteral(context, argument, w);
                            try w.bytes("::regclass");
                        } else try expression(context, item, w);
                        first = false;
                    }
                    try w.bytes(")");
                },
                .cast => {
                    const inner = context.node(n.a);
                    if (inner.kind == .text_literal) try quotedLiteral(context, inner, w) else {
                        try w.bytes("(");
                        try expression(context, n.a, w);
                        try w.bytes(")");
                    }
                    try w.bytes("::");
                    try w.bytes(types.sqlTypeName(types.dataTypeOf(n.cast_type)));
                },
                else => return error.UnsupportedStatement,
            }
        }
    };
}
