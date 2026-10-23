//! Name resolution and typing (Layer 0, design §4.1). Binds a parsed
//! statement against the committed catalog without executing it, so
//! describe() never mutates data.
//!
//! Every expression is typed with PostgreSQL's implicit-cast rules for the
//! supported types (int4, int8, boolean, text): untyped string/NULL literals
//! take their type from context (and are parsed now, so `'x'::integer` and
//! `id = 'x'` raise 22P02 even over empty tables); int4/int8 mix to int8;
//! there is no integer-to-boolean coercion in expressions (`WHERE id` is
//! 42804 in every dialect); an operator with no matching signature is
//! UndefinedFunction (42883). Output columns are named like PostgreSQL
//! (column name, function name, cast type name or `?column?`).
//!
//! Bound statements keep node indices into the statement-scoped pool and
//! text-literal spans into the source; both stay valid until the statement
//! finishes executing. Names and catalog references are copied.
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const ast = @import("ast.sig");
const storage = @import("storage.sig");
const expr = @import("expr.sig");
const Error = types.Error;
const none = ast.none;

pub fn Binder(comptime config: types.Config) type {
    const V = types.Values(config);
    const Ast = ast.Ast(config);
    const S = storage.Storage(config);
    return struct {
        /// INTEGER outside the PostgreSQL dialect and in legacy replay.
        pub const integer_type: types.DataType = if (config.integer_bits == 32) .integer32 else .integer;

        pub const Create = struct {
            name: V.Name,
            columns: [config.columns]V.Column,
            count: usize,
        };

        /// `values[c]` is the expression assigned to column c, or none (NULL).
        pub const Insert = struct { table: usize, values: [config.columns]u16 };

        pub const Key = struct { expr: u16, descending: bool, nulls_first: ?bool };

        pub const Select = struct {
            table: ?usize,
            targets: [config.columns]u16,
            names: [config.columns]V.Name,
            types: [config.columns]types.DataType,
            count: usize,
            where: u16,
            /// Constant expression equal to the primary key (index probe), or none.
            key: u16,
            order: [config.columns]Key,
            order_count: usize,
            limit: u64,
        };

        /// `values[c]` is the expression assigned to column c, or none.
        pub const Update = struct { table: usize, values: [config.columns]u16, where: u16, key: u16 };

        pub const Delete = struct { table: usize, where: u16, key: u16 };

        pub const Bound = union(enum) {
            create_table: Create,
            drop_table: usize,
            insert: Insert,
            select: Select,
            update: Update,
            delete: Delete,
            begin: void,
            commit: void,
            rollback: void,
        };

        pub const Context = struct {
            source: []const u8,
            tables: *const [config.tables]S.Table,
            pool: *Ast.Pool,
            /// legacy_alpha replay: alpha INTEGER width and boolean integers.
            legacy: bool,
            dialect: types.Dialect,

            fn node(self: *const Context, id: u16) *ast.Node {
                return &self.pool.nodes[id];
            }

            fn booleanIntegers(self: *const Context) bool {
                return self.legacy or self.dialect != .postgres;
            }
        };

        const Scope = struct {
            table: ?usize = null,
            name: V.Name = .{},
            alias: ?V.Name = null,
        };

        pub fn command(bound: *const Bound) types.CommandTag {
            return switch (bound.*) {
                .create_table => .create_table,
                .drop_table => .drop_table,
                .insert => .insert,
                .select => .select,
                .update => .update,
                .delete => .delete,
                .begin => .begin,
                .commit => .commit,
                .rollback => .rollback,
            };
        }

        pub fn dataType(ty: ast.Type) types.DataType {
            return switch (ty) {
                .int4 => .integer32,
                .int8 => .integer,
                .boolean => .boolean,
                .text, .unknown => .text,
            };
        }

        fn fromData(data_type: types.DataType) ast.Type {
            return switch (data_type) {
                .integer32 => .int4,
                .integer => .int8,
                .boolean => .boolean,
                .text => .text,
            };
        }

        fn fromTypeName(name: ast.TypeName) ast.Type {
            return switch (name) {
                .integer => .int4,
                .bigint => .int8,
                .boolean => .boolean,
                .text => .text,
            };
        }

        fn integral(ty: ast.Type) bool {
            return ty == .int4 or ty == .int8;
        }

        fn toName(context: *const Context, ident: ast.Ident) V.Name {
            var out: V.Name = .{ .len = ident.len };
            const raw = ident.span.slice(context.source);
            if (ident.quoted) {
                lexer.decodeQuotedWith(context.source, .{ .start = ident.span.start, .end = ident.span.start + ident.span.len, .len = ident.len }, '"', &out.bytes);
            } else for (raw, 0..) |byte, index| out.bytes[index] = types.lower(byte);
            return out;
        }

        fn literalName(text: []const u8) V.Name {
            const length = @min(text.len, config.name_bytes);
            var out: V.Name = .{ .len = length };
            @memcpy(out.bytes[0..length], text[0..length]);
            return out;
        }

        /// Committed catalog lookup; a pending CREATE is not yet visible.
        pub fn tableIndex(tables: *const [config.tables]S.Table, wanted: []const u8) Error!usize {
            for (tables, 0..) |*table, index|
                if (table.live and types.same(table.name.slice(), wanted)) return index;
            return error.TableNotFound;
        }

        fn resolveTable(context: *const Context, ident: ast.Ident) Error!usize {
            const wanted = toName(context, ident);
            return tableIndex(context.tables, wanted.slice());
        }

        fn columnIndex(context: *const Context, entry: *const S.Table, ident: ast.Ident) Error!usize {
            const wanted = toName(context, ident);
            for (entry.columns[0..entry.column_count], 0..) |*column, index|
                if (types.same(column.name.slice(), wanted.slice())) return index;
            return error.ColumnNotFound;
        }

        // ---- literal coercion ----------------------------------------------

        /// Resolves an untyped literal to `target`, parsing string input now.
        fn coerce(context: *const Context, id: u16, target: ast.Type) Error!void {
            const n = context.node(id);
            if (n.ty != .unknown) return;
            if (n.kind == .text_literal) {
                const text = expr.Eval(config).literalText(context.source, n.text);
                switch (target) {
                    .int4, .int8 => {
                        n.integer = try expr.parseInteger(text.slice(), target);
                        n.kind = .int_literal;
                    },
                    .boolean => {
                        n.boolean = try expr.parseBoolean(text.slice());
                        n.kind = .bool_literal;
                    },
                    .text, .unknown => {},
                }
            }
            n.ty = if (target == .unknown) .text else target;
        }

        /// Operands of a comparison: unknown takes the other side's type;
        /// int4/int8 compare directly; anything else has no operator.
        fn comparable(context: *const Context, a: u16, b: u16) Error!void {
            const left = context.node(a).ty;
            const right = context.node(b).ty;
            if (left == .unknown and right == .unknown) {
                try coerce(context, a, .text);
                return coerce(context, b, .text);
            }
            if (left == .unknown) return coerce(context, a, right);
            if (right == .unknown) return coerce(context, b, left);
            if (left == right or (integral(left) and integral(right))) return;
            if (context.legacy) {
                // Alpha replay compared boolean columns with integer 0/1.
                if (left == .boolean and context.node(b).kind == .int_literal) return legacyBoolean(context, b);
                if (right == .boolean and context.node(a).kind == .int_literal) return legacyBoolean(context, a);
            }
            return error.UndefinedFunction;
        }

        fn legacyBoolean(context: *const Context, id: u16) Error!void {
            const n = context.node(id);
            if (n.integer != 0 and n.integer != 1) return error.TypeMismatch;
            n.boolean = n.integer == 1;
            n.kind = .bool_literal;
            n.ty = .boolean;
        }

        fn booleanArgument(context: *const Context, id: u16) Error!void {
            const ty = context.node(id).ty;
            if (ty == .unknown) return coerce(context, id, .boolean);
            if (ty != .boolean) return error.TypeMismatch;
        }

        /// Common type of CASE results / COALESCE arguments (select_common_type).
        fn unifyInto(result: *ast.Type, ty: ast.Type) Error!void {
            if (ty == .unknown) return;
            if (result.* == .unknown) {
                result.* = ty;
            } else if (integral(result.*) and integral(ty)) {
                if (ty == .int8) result.* = .int8;
            } else if (result.* != ty) return error.TypeMismatch;
        }

        // ---- expression typing ----------------------------------------------

        fn isConstant(context: *const Context, id: u16) bool {
            return id == none or context.node(id).constant;
        }

        fn listConstant(context: *const Context, head: u16) bool {
            var item = head;
            while (item != none) : (item = context.node(item).next) if (!context.node(item).constant) return false;
            return true;
        }

        fn typeExpr(context: *const Context, scope: *const Scope, id: u16) Error!void {
            const n = context.node(id);
            n.constant = true;
            switch (n.kind) {
                .null_literal => n.ty = .unknown,
                .bool_literal => n.ty = .boolean,
                .int_literal => n.ty = if (n.integer >= -2147483648 and n.integer <= 2147483647) .int4 else .int8,
                .text_literal => n.ty = .unknown,
                // NUMERIC arrives with Q02 (step 3.2).
                .decimal_literal => return error.UnsupportedStatement,
                .param => return error.UndefinedParameter,
                .function => return error.UndefinedFunction,
                .when_arm => unreachable,
                .column => {
                    const table_index = scope.table orelse return error.ColumnNotFound;
                    if (n.qualifier.len != 0) {
                        const qualifier = toName(context, n.qualifier);
                        const matches = if (scope.alias) |alias| types.same(alias.slice(), qualifier.slice()) else types.same(scope.name.slice(), qualifier.slice());
                        if (!matches) return error.TableNotFound;
                    }
                    const entry = &context.tables[table_index];
                    const column = try columnIndex(context, entry, n.name);
                    n.column = @intCast(column);
                    n.ty = fromData(entry.columns[column].data_type);
                    n.constant = false;
                },
                .unary => {
                    try typeExpr(context, scope, n.a);
                    const ty = context.node(n.a).ty;
                    if (ty == .unknown) return error.AmbiguousFunction;
                    if (!integral(ty)) return error.UndefinedFunction;
                    n.ty = ty;
                    n.constant = isConstant(context, n.a);
                },
                .binary => {
                    try typeExpr(context, scope, n.a);
                    try typeExpr(context, scope, n.b);
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                    const left = context.node(n.a).ty;
                    const right = context.node(n.b).ty;
                    switch (n.op) {
                        .eq, .ne, .lt, .le, .gt, .ge => {
                            try comparable(context, n.a, n.b);
                            n.ty = .boolean;
                        },
                        .add, .sub, .mul, .div, .mod => {
                            if (left == .unknown and right == .unknown) return error.AmbiguousFunction;
                            if (left == .unknown and integral(right)) try coerce(context, n.a, right);
                            if (right == .unknown and integral(left)) try coerce(context, n.b, left);
                            const l = context.node(n.a).ty;
                            const r = context.node(n.b).ty;
                            if (!integral(l) or !integral(r)) return error.UndefinedFunction;
                            n.ty = if (l == .int8 or r == .int8) .int8 else .int4;
                        },
                        .concat => {
                            // text || text, text || anynonarray, anynonarray || text.
                            if (left == .unknown) try coerce(context, n.a, .text);
                            if (right == .unknown) try coerce(context, n.b, .text);
                            if (context.node(n.a).ty != .text and context.node(n.b).ty != .text) return error.UndefinedFunction;
                            n.ty = .text;
                        },
                        // JSON operators arrive with Q04 (step 3.2).
                        else => return error.UndefinedFunction,
                    }
                },
                .and_op, .or_op => {
                    try typeExpr(context, scope, n.a);
                    try booleanArgument(context, n.a);
                    try typeExpr(context, scope, n.b);
                    try booleanArgument(context, n.b);
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                },
                .not_op => {
                    try typeExpr(context, scope, n.a);
                    try booleanArgument(context, n.a);
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a);
                },
                .test_op => {
                    try typeExpr(context, scope, n.a);
                    if (n.test_kind == .is_null or n.test_kind == .is_not_null) {
                        if (context.node(n.a).ty == .unknown) try coerce(context, n.a, .text);
                    } else try booleanArgument(context, n.a);
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a);
                },
                .between => {
                    try typeExpr(context, scope, n.a);
                    try typeExpr(context, scope, n.b);
                    try typeExpr(context, scope, n.c);
                    try comparable(context, n.a, n.b);
                    try comparable(context, n.a, n.c);
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b) and isConstant(context, n.c);
                },
                .in_list => {
                    try typeExpr(context, scope, n.a);
                    var item = n.b;
                    while (item != none) : (item = context.node(item).next) {
                        try typeExpr(context, scope, item);
                        try comparable(context, n.a, item);
                    }
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a) and listConstant(context, n.b);
                },
                .like => {
                    try typeExpr(context, scope, n.a);
                    try typeExpr(context, scope, n.b);
                    try coerce(context, n.a, .text);
                    try coerce(context, n.b, .text);
                    if (context.node(n.a).ty != .text or context.node(n.b).ty != .text) return error.UndefinedFunction;
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                },
                .case_expr => {
                    var constant = true;
                    if (n.a != none) {
                        try typeExpr(context, scope, n.a);
                        constant = isConstant(context, n.a);
                    }
                    var result: ast.Type = .unknown;
                    var arm = n.b;
                    while (arm != none) : (arm = context.node(arm).next) {
                        const entry = context.node(arm);
                        try typeExpr(context, scope, entry.a);
                        if (n.a != none) try comparable(context, n.a, entry.a) else try booleanArgument(context, entry.a);
                        try typeExpr(context, scope, entry.b);
                        try unifyInto(&result, context.node(entry.b).ty);
                        entry.constant = isConstant(context, entry.a) and isConstant(context, entry.b);
                        constant = constant and entry.constant;
                    }
                    if (n.c != none) {
                        try typeExpr(context, scope, n.c);
                        try unifyInto(&result, context.node(n.c).ty);
                        constant = constant and isConstant(context, n.c);
                    }
                    if (result == .unknown) result = .text;
                    arm = n.b;
                    while (arm != none) : (arm = context.node(arm).next) try coerce(context, context.node(arm).b, result);
                    if (n.c != none) try coerce(context, n.c, result);
                    n.ty = result;
                    n.constant = constant;
                },
                .coalesce => {
                    var result: ast.Type = .unknown;
                    var item = n.b;
                    while (item != none) : (item = context.node(item).next) {
                        try typeExpr(context, scope, item);
                        try unifyInto(&result, context.node(item).ty);
                    }
                    if (result == .unknown) result = .text;
                    item = n.b;
                    while (item != none) : (item = context.node(item).next) try coerce(context, item, result);
                    n.ty = result;
                    n.constant = listConstant(context, n.b);
                },
                .nullif => {
                    try typeExpr(context, scope, n.a);
                    try typeExpr(context, scope, n.b);
                    try comparable(context, n.a, n.b);
                    n.ty = context.node(n.a).ty;
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                },
                .cast => {
                    try typeExpr(context, scope, n.a);
                    const target = fromTypeName(n.cast_type);
                    const from = context.node(n.a).ty;
                    if (from == .unknown) {
                        try coerce(context, n.a, target);
                    } else {
                        const allowed = switch (target) {
                            .int4, .text => true,
                            .int8 => from != .boolean,
                            .boolean => from != .int8,
                            .unknown => unreachable,
                        };
                        if (!allowed) return error.CannotCoerce;
                    }
                    n.ty = target;
                    n.constant = isConstant(context, n.a);
                },
            }
        }

        /// Types an expression whose untyped result defaults to text.
        fn value(context: *const Context, scope: *const Scope, id: u16) Error!void {
            try typeExpr(context, scope, id);
            if (context.node(id).ty == .unknown) try coerce(context, id, .text);
        }

        fn isPredicate(n: *const ast.Node) bool {
            return switch (n.kind) {
                .test_op, .between, .in_list, .like => true,
                .binary => n.op == .eq or n.op == .ne or n.op == .lt or n.op == .le or n.op == .gt or n.op == .ge,
                else => false,
            };
        }

        /// WHERE: at most Config.predicates leaf predicates; must be boolean.
        fn bindWhere(context: *const Context, scope: *const Scope, root: u16) Error!u16 {
            if (root == none) return none;
            var stack: [config.expr_depth + 2]u16 = undefined;
            var used: usize = 1;
            stack[0] = root;
            var leaves: usize = 0;
            while (used != 0) {
                used -= 1;
                const n = context.node(stack[used]);
                switch (n.kind) {
                    .and_op, .or_op => {
                        stack[used] = n.b;
                        stack[used + 1] = n.a;
                        used += 2;
                    },
                    .not_op => {
                        stack[used] = n.a;
                        used += 1;
                    },
                    else => if (isPredicate(n)) {
                        leaves += 1;
                    },
                }
            }
            if (leaves > config.predicates) return error.PredicateCapacity;
            try typeExpr(context, scope, root);
            try booleanArgument(context, root);
            return root;
        }

        /// A top-level `pk = constant` conjunct, for the primary-key probe.
        fn primaryKey(context: *const Context, entry: *const S.Table, root: u16) u16 {
            const primary = entry.primary_column orelse return none;
            if (root == none) return none;
            var stack: [config.expr_depth + 2]u16 = undefined;
            var used: usize = 1;
            stack[0] = root;
            while (used != 0) {
                used -= 1;
                const n = context.node(stack[used]);
                if (n.kind == .and_op) {
                    stack[used] = n.b;
                    stack[used + 1] = n.a;
                    used += 2;
                    continue;
                }
                if (n.kind != .binary or n.op != .eq) continue;
                const left = context.node(n.a);
                const right = context.node(n.b);
                if (left.kind == .column and left.column == primary and right.constant) return n.b;
                if (right.kind == .column and right.column == primary and left.constant) return n.a;
            }
            return none;
        }

        /// Assignment (INSERT values, UPDATE SET) typing: PostgreSQL
        /// assignment casts, plus integer 0/1 into boolean for MySQL/TDS.
        fn assignment(context: *const Context, id: u16, column: *const V.Column) Error!void {
            const target = fromData(column.data_type);
            const ty = context.node(id).ty;
            if (ty == .unknown) return coerce(context, id, target);
            const ok = switch (target) {
                .int4, .int8 => integral(ty),
                .boolean => ty == .boolean or (integral(ty) and context.booleanIntegers()),
                .text => true,
                .unknown => unreachable,
            };
            if (!ok) return error.TypeMismatch;
        }

        const Strength = struct { name: []const u8, strength: u8 };

        fn figure(context: *const Context, id: u16, buffer: *V.Name) Strength {
            const n = context.node(id);
            return switch (n.kind) {
                .column => blk: {
                    buffer.* = toName(context, n.name);
                    break :blk .{ .name = buffer.slice(), .strength = 2 };
                },
                .function => blk: {
                    buffer.* = toName(context, n.name);
                    break :blk .{ .name = buffer.slice(), .strength = 2 };
                },
                .coalesce => .{ .name = "coalesce", .strength = 2 },
                .nullif => .{ .name = "nullif", .strength = 2 },
                .case_expr => .{ .name = "case", .strength = 1 },
                .cast => blk: {
                    const inner = figure(context, n.a, buffer);
                    if (inner.strength > 1) break :blk inner;
                    break :blk .{ .name = switch (n.cast_type) {
                        .integer => "int4",
                        .bigint => "int8",
                        .boolean => "bool",
                        .text => "text",
                    }, .strength = 1 };
                },
                else => .{ .name = "?column?", .strength = 0 },
            };
        }

        fn targetName(context: *const Context, id: u16) V.Name {
            var buffer: V.Name = .{};
            const result = figure(context, id, &buffer);
            return literalName(result.name);
        }

        fn scopeFor(context: *const Context, from: ?Ast.TableRef) Error!Scope {
            const reference = from orelse return .{};
            const index = try resolveTable(context, reference.name);
            var out: Scope = .{ .table = index, .name = context.tables[index].name };
            if (reference.alias) |alias| out.alias = toName(context, alias);
            return out;
        }

        fn tableScope(context: *const Context, index: usize) Scope {
            return .{ .table = index, .name = context.tables[index].name };
        }

        fn bindSelect(context: *const Context, select: *const Ast.Select) Error!Select {
            const scope = try scopeFor(context, select.from);
            var out: Select = .{ .table = scope.table, .targets = undefined, .names = undefined, .types = undefined, .count = 0, .where = none, .key = none, .order = undefined, .order_count = 0, .limit = select.limit };
            for (select.targets[0..select.count]) |*target| {
                if (target.star) {
                    const entry = &context.tables[scope.table.?];
                    for (entry.columns[0..entry.column_count], 0..) |*column, index| {
                        if (out.count == config.columns) return error.ColumnCapacity;
                        const id = try context.pool.add(.{ .kind = .column, .column = @intCast(index), .ty = fromData(column.data_type) });
                        out.targets[out.count] = id;
                        out.names[out.count] = column.name;
                        out.types[out.count] = column.data_type;
                        out.count += 1;
                    }
                    continue;
                }
                if (out.count == config.columns) return error.ColumnCapacity;
                try value(context, &scope, target.expr);
                out.targets[out.count] = target.expr;
                out.names[out.count] = if (target.alias) |alias| toName(context, alias) else targetName(context, target.expr);
                out.types[out.count] = dataType(context.node(target.expr).ty);
                out.count += 1;
            }
            out.where = try bindWhere(context, &scope, select.where);
            if (scope.table) |index| out.key = primaryKey(context, &context.tables[index], out.where);
            for (select.order[0..select.order_count]) |*key| {
                var id = key.expr;
                const n = context.node(id);
                if (n.kind == .int_literal) {
                    // ORDER BY <position>.
                    if (n.integer < 1 or n.integer > out.count) return error.InvalidColumnReference;
                    id = out.targets[@intCast(n.integer - 1)];
                } else blk: {
                    if (n.kind == .column and n.qualifier.len == 0) {
                        // An output column name wins over an input column.
                        const wanted = toName(context, n.name);
                        for (out.names[0..out.count], 0..) |*name, index| if (types.same(name.slice(), wanted.slice())) {
                            id = out.targets[index];
                            break :blk;
                        };
                    }
                    try value(context, &scope, id);
                }
                out.order[out.order_count] = .{ .expr = id, .descending = key.descending, .nulls_first = key.nulls_first };
                out.order_count += 1;
            }
            return out;
        }

        pub fn bind(context: *const Context, statement: *const Ast.Statement) Error!Bound {
            switch (statement.*) {
                .create_table => |*create| {
                    const table_name = toName(context, create.name);
                    for (context.tables) |*entry|
                        if (entry.live and types.same(entry.name.slice(), table_name.slice())) return error.TableExists;
                    var out: Create = .{ .name = table_name, .columns = @splat(.{}), .count = create.count };
                    const plain_integer: types.DataType = if (context.legacy or context.dialect != .postgres) integer_type else .integer32;
                    for (create.columns[0..create.count], 0..) |*definition, index| {
                        var column: V.Column = .{ .name = toName(context, definition.name), .not_null = definition.not_null, .primary_key = definition.primary_key };
                        for (out.columns[0..index]) |*previous|
                            if (types.same(previous.name.slice(), column.name.slice())) return error.DuplicateColumn;
                        column.data_type = switch (definition.type_name) {
                            .integer => plain_integer,
                            .bigint => .integer,
                            .boolean => .boolean,
                            .text => .text,
                        };
                        out.columns[index] = column;
                    }
                    return .{ .create_table = out };
                },
                .drop_table => |ident| return .{ .drop_table = try resolveTable(context, ident) },
                .insert => |*insert| {
                    const index = try resolveTable(context, insert.table);
                    const entry = &context.tables[index];
                    var mapping: [config.columns]usize = @splat(0);
                    var mapped: [config.columns]bool = @splat(false);
                    var count: usize = 0;
                    if (insert.explicit_columns) {
                        for (insert.columns[0..insert.column_count]) |ident| {
                            const column = try columnIndex(context, entry, ident);
                            if (mapped[column]) return error.DuplicateColumn;
                            mapping[count] = column;
                            mapped[column] = true;
                            count += 1;
                        }
                    } else {
                        count = entry.column_count;
                        for (0..count) |column| mapping[column] = column;
                    }
                    if (insert.value_count != count) return error.Syntax;
                    var out: Insert = .{ .table = index, .values = @splat(none) };
                    const empty: Scope = .{};
                    for (0..count) |position| {
                        const id = insert.values[position];
                        const column = mapping[position];
                        try typeExpr(context, &empty, id);
                        try assignment(context, id, &entry.columns[column]);
                        out.values[column] = id;
                    }
                    return .{ .insert = out };
                },
                .select => |*select| return .{ .select = try bindSelect(context, select) },
                .update => |*update| {
                    const index = try resolveTable(context, update.table);
                    const entry = &context.tables[index];
                    const scope = tableScope(context, index);
                    var out: Update = .{ .table = index, .values = @splat(none), .where = none, .key = none };
                    for (update.assignments[0..update.count]) |*item| {
                        const column = try columnIndex(context, entry, item.column);
                        if (out.values[column] != none) return error.DuplicateColumn;
                        try typeExpr(context, &scope, item.value);
                        try assignment(context, item.value, &entry.columns[column]);
                        out.values[column] = item.value;
                    }
                    out.where = try bindWhere(context, &scope, update.where);
                    out.key = primaryKey(context, entry, out.where);
                    return .{ .update = out };
                },
                .delete => |*delete| {
                    const index = try resolveTable(context, delete.table);
                    const scope = tableScope(context, index);
                    const where = try bindWhere(context, &scope, delete.where);
                    return .{ .delete = .{ .table = index, .where = where, .key = primaryKey(context, &context.tables[index], where) } };
                },
                .begin => return .begin,
                .commit => return .commit,
                .rollback => return .rollback,
            }
        }
    };
}
