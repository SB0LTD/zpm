//! Name resolution and typing (Layer 0, design §4.1). Binds a parsed
//! statement against the catalog visible to the statement snapshot without executing it, so
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
const catalog = @import("catalog.sig");
const value = @import("value.sig");
const Error = types.Error;
const none = ast.none;

pub fn Binder(comptime config: types.Config) type {
    const V = types.Values(config);
    const Ast = ast.Ast(config);
    const S = storage.Storage(config);
    const K = catalog.Catalog(config);
    const E = expr.Eval(config);
    const Io = value.Io(config);
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
            typmods: [config.columns]i32 = @splat(-1),
            count: usize,
            where: u16,
            /// Constant expression equal to the primary key (index probe), or none.
            key: u16,
            order: [config.columns]Key,
            order_count: usize,
            limit: u64,
            lock: ast.Locking = .{},
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
            control: ast.Control,
        };

        pub const Context = struct {
            source: []const u8,
            tables: *const [config.tables]S.Table,
            catalog: *const K,
            /// Statement snapshot: every name lookup reads the catalog under it.
            snapshot: storage.Snapshot,
            pool: *Ast.Pool,
            /// legacy_alpha replay: alpha INTEGER width and boolean integers.
            legacy: bool,
            dialect: types.Dialect,
            /// Time zone and resolver for datetime literals parsed at bind time.
            session: *const value.Session = &value.default_session,

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
                .control => |control| switch (control) {
                    .begin, .set_transaction => .begin,
                    .commit => .commit,
                    .rollback, .rollback_to => .rollback,
                    .savepoint => .savepoint,
                    .release => .release,
                    .set => .set,
                    .show => .show,
                    .reset => .reset,
                },
            };
        }

        pub fn dataType(ty: ast.Type) types.DataType {
            return types.dataTypeOf(ty);
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

        /// Catalog lookup under a snapshot (cat_relations, design M2).
        pub fn tableIndex(cat: *const K, wanted: []const u8, snap: storage.Snapshot) Error!usize {
            return cat.lookup(wanted, snap) orelse error.TableNotFound;
        }

        fn resolveTable(context: *const Context, ident: ast.Ident) Error!usize {
            const wanted = toName(context, ident);
            return tableIndex(context.catalog, wanted.slice(), context.snapshot);
        }

        fn columnIndex(context: *const Context, entry: *const S.Table, ident: ast.Ident) Error!usize {
            const wanted = toName(context, ident);
            for (entry.columns[0..entry.column_count], 0..) |*column, index|
                if (types.same(column.name.slice(), wanted.slice())) return index;
            return error.ColumnNotFound;
        }

        // ---- literal coercion ----------------------------------------------

        /// Resolves an untyped literal to `target`, parsing string input now
        /// (so `'x'::integer` and `id = 'x'` fail even over empty tables).
        fn coerce(context: *const Context, id: u16, target: ast.Type) Error!void {
            const n = context.node(id);
            if (n.ty != .unknown) return;
            if (n.kind == .text_literal) {
                const text = E.literalText(context.source, n.text);
                switch (target) {
                    .int2, .int4, .int8 => {
                        n.integer = try expr.parseInteger(text.slice(), if (target == .int2) .int4 else target);
                        if (target == .int2 and (n.integer < -32768 or n.integer > 32767)) return error.NumericValueOutOfRange;
                        n.kind = .int_literal;
                    },
                    .boolean => {
                        n.boolean = try expr.parseBoolean(text.slice());
                        n.kind = .bool_literal;
                    },
                    .text, .unknown => {},
                    // Validated now, converted again at evaluation.
                    else => _ = try Io.parse(target, -1, text.slice(), context.session),
                }
            }
            n.ty = if (target == .unknown) .text else target;
        }

        /// Wraps `id` in an implicit/assignment cast to `target` when needed.
        fn convert(context: *const Context, id: u16, target: ast.Type, typmod: i32, mode: value.Context) Error!u16 {
            const n = context.node(id);
            if (n.ty == .unknown) {
                try coerce(context, id, target);
                return id;
            }
            if (n.ty == target and typmod < 0) return id;
            // Integer cells need no conversion between int2/int4/int8 except
            // the range check, which assignment performs at store time.
            if (n.ty == target) return id;
            if (!value.castable(n.ty, target, mode)) return if (mode == .assignment) error.TypeMismatch else error.UndefinedFunction;
            const constant = n.constant;
            const cast_id = try context.pool.add(.{ .kind = .cast, .cast_type = target, .typmod = typmod, .a = id, .ty = target });
            context.node(cast_id).constant = constant;
            return cast_id;
        }

        /// Operands of a comparison: unknown takes the other side's type;
        /// numeric and datetime operands promote to their common type.
        fn comparable(context: *const Context, a: *u16, b: *u16) Error!void {
            const left = context.node(a.*).ty;
            const right = context.node(b.*).ty;
            if (left == .unknown and right == .unknown) {
                try coerce(context, a.*, .text);
                return coerce(context, b.*, .text);
            }
            if (left == .unknown) return coerce(context, a.*, right);
            if (right == .unknown) return coerce(context, b.*, left);
            if (left == .json or right == .json) return error.UndefinedFunction;
            if (left == right) return;
            if (value.integral(left) and value.integral(right)) return;
            if (context.legacy) {
                // Alpha replay compared boolean columns with integer 0/1.
                if (left == .boolean and context.node(b.*).kind == .int_literal) return legacyBoolean(context, b.*);
                if (right == .boolean and context.node(a.*).kind == .int_literal) return legacyBoolean(context, a.*);
            }
            const target = value.common(left, right) orelse return error.UndefinedFunction;
            a.* = try convert(context, a.*, target, -1, .implicit);
            b.* = try convert(context, b.*, target, -1, .implicit);
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

        /// Common type of CASE results / COALESCE arguments / IN lists
        /// (select_common_type).
        fn unifyInto(result: *ast.Type, ty: ast.Type) Error!void {
            if (ty == .unknown) return;
            if (result.* == .unknown) {
                result.* = ty;
                return;
            }
            result.* = value.common(result.*, ty) orelse return error.TypeMismatch;
        }

        /// Converts every member of a `next`-linked list to `target`,
        /// relinking cast nodes in place; returns the new head.
        fn convertList(context: *const Context, head: u16, target: ast.Type) Error!u16 {
            var first = head;
            var previous: u16 = none;
            var item = head;
            while (item != none) {
                const next = context.node(item).next;
                const converted = try convert(context, item, target, -1, .implicit);
                if (converted != item) {
                    context.node(converted).next = next;
                    context.node(item).next = none;
                    if (previous == none) first = converted else context.node(previous).next = converted;
                }
                previous = converted;
                item = next;
            }
            return first;
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

        fn arithmeticType(context: *const Context, n: *ast.Node) Error!void {
            if (context.node(n.a).ty == .unknown and context.node(n.b).ty == .unknown) return error.AmbiguousFunction;
            var left = context.node(n.a).ty;
            var right = context.node(n.b).ty;
            // An untyped literal takes the other operand's type, except
            // that datetime arithmetic takes an interval.
            if (left == .unknown) {
                try coerce(context, n.a, if (value.datetime(right) and right != .date) .interval else right);
                left = context.node(n.a).ty;
            }
            if (right == .unknown) {
                const target: ast.Type = if (left == .date) (if (n.op == .sub) .date else return error.AmbiguousFunction) else if (value.datetime(left)) .interval else left;
                try coerce(context, n.b, target);
                right = context.node(n.b).ty;
            }
            if (value.numericCategory(left) and value.numericCategory(right)) {
                const result = value.arithmeticType(left, right);
                if (n.op == .mod and (result == .float4 or result == .float8)) return error.UndefinedFunction;
                if (!value.integral(result)) {
                    n.a = try convert(context, n.a, result, -1, .implicit);
                    n.b = try convert(context, n.b, result, -1, .implicit);
                }
                n.ty = result;
                return;
            }
            const add = n.op == .add;
            const sub = n.op == .sub;
            if (!add and !sub) return error.UndefinedFunction;
            // date +- integer, integer + date
            if (left == .date and value.integral(right)) {
                n.ty = .date;
                return;
            }
            if (add and value.integral(left) and right == .date) {
                n.ty = .date;
                return;
            }
            if (sub and value.datetime(left) and value.datetime(right)) {
                if (left == .date and right == .date) {
                    n.ty = .int4;
                    return;
                }
                const target = value.common(left, right).?;
                n.a = try convert(context, n.a, target, -1, .implicit);
                n.b = try convert(context, n.b, target, -1, .implicit);
                n.ty = .interval;
                return;
            }
            if (value.datetime(left) and right == .interval) {
                if (left == .date) n.a = try convert(context, n.a, .timestamp, -1, .implicit);
                n.ty = if (left == .timestamptz) .timestamptz else .timestamp;
                return;
            }
            if (add and left == .interval and value.datetime(right)) {
                if (right == .date) n.b = try convert(context, n.b, .timestamp, -1, .implicit);
                n.ty = if (right == .timestamptz) .timestamptz else .timestamp;
                return;
            }
            if (left == .interval and right == .interval) {
                n.ty = .interval;
                return;
            }
            return error.UndefinedFunction;
        }

        fn jsonOperator(context: *const Context, n: *ast.Node) Error!void {
            const left = context.node(n.a).ty;
            if (left == .unknown) return error.AmbiguousFunction;
            if (left != .jsonb) return error.UndefinedFunction;
            const right_node = context.node(n.b);
            switch (n.op) {
                .arrow, .arrow_text => {
                    if (right_node.ty == .unknown) try coerce(context, n.b, .text);
                    const right = context.node(n.b).ty;
                    if (right != .text and !value.integral(right)) return error.UndefinedFunction;
                    n.ty = if (n.op == .arrow) .jsonb else .text;
                },
                .path, .path_text => {
                    // The right operand is a text[] literal only.
                    if (right_node.ty != .unknown or right_node.kind != .text_literal) return error.UndefinedFunction;
                    const text = E.literalText(context.source, right_node.text);
                    var items: [32][]const u8 = undefined;
                    _ = try Io.Documents.parsePath(text.slice(), &items);
                    right_node.ty = .text;
                    n.ty = if (n.op == .path) .jsonb else .text;
                },
                .contains, .contained => {
                    n.b = try convert(context, n.b, .jsonb, -1, .implicit);
                    if (context.node(n.b).ty != .jsonb) return error.UndefinedFunction;
                    n.ty = .boolean;
                },
                .exists => {
                    if (right_node.ty == .unknown) try coerce(context, n.b, .text);
                    if (context.node(n.b).ty != .text) return error.UndefinedFunction;
                    n.ty = .boolean;
                },
                else => unreachable,
            }
        }

        fn functionName(context: *const Context, n: *const ast.Node) ast.Func {
            const name = toName(context, n.name);
            const table = [_]struct { name: []const u8, func: ast.Func }{
                .{ .name = "now", .func = .now },
                .{ .name = "transaction_timestamp", .func = .transaction_timestamp },
                .{ .name = "statement_timestamp", .func = .statement_timestamp },
                .{ .name = "clock_timestamp", .func = .clock_timestamp },
                .{ .name = "current_timestamp", .func = .current_timestamp },
                .{ .name = "current_date", .func = .current_date },
                .{ .name = "jsonb_typeof", .func = .jsonb_typeof },
                .{ .name = "jsonb_array_length", .func = .jsonb_array_length },
            };
            for (table) |entry| if (types.same(name.slice(), entry.name)) return entry.func;
            return .none;
        }

        fn typeFunction(context: *const Context, scope: *const Scope, n: *ast.Node) Error!void {
            n.func = functionName(context, n);
            var count: usize = 0;
            var item = n.b;
            while (item != none) : (item = context.node(item).next) {
                try typeExpr(context, scope, item);
                count += 1;
            }
            switch (n.func) {
                .none => return error.UndefinedFunction,
                .now, .transaction_timestamp, .statement_timestamp, .clock_timestamp, .current_timestamp, .current_date => {
                    if (count != 0) return error.UndefinedFunction;
                    n.ty = if (n.func == .current_date) .date else .timestamptz;
                    // Volatile clocks are still row-independent.
                    n.constant = true;
                },
                .jsonb_typeof, .jsonb_array_length => {
                    if (count != 1) return error.UndefinedFunction;
                    n.b = try convert(context, n.b, .jsonb, -1, .implicit);
                    if (context.node(n.b).ty != .jsonb) return error.UndefinedFunction;
                    n.ty = if (n.func == .jsonb_typeof) .text else .int4;
                    n.constant = isConstant(context, n.b);
                },
            }
        }

        fn typeExpr(context: *const Context, scope: *const Scope, id: u16) Error!void {
            const n = context.node(id);
            n.constant = true;
            switch (n.kind) {
                .null_literal => n.ty = .unknown,
                .bool_literal => n.ty = .boolean,
                .int_literal => n.ty = if (n.integer >= -2147483648 and n.integer <= 2147483647) .int4 else .int8,
                .text_literal => n.ty = .unknown,
                .decimal_literal => {
                    // Validated now (54000 beyond numeric_digits).
                    _ = try Io.parse(.numeric, -1, n.name.span.slice(context.source), context.session);
                    n.ty = .numeric;
                },
                .param => return error.UndefinedParameter,
                .function => try typeFunction(context, scope, n),
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
                    n.ty = types.typeOfData(entry.columns[column].data_type);
                    n.typmod = entry.columns[column].typmod;
                    n.constant = false;
                },
                .unary => {
                    try typeExpr(context, scope, n.a);
                    const ty = context.node(n.a).ty;
                    if (ty == .unknown) return error.AmbiguousFunction;
                    if (!value.numericCategory(ty) and ty != .interval) return error.UndefinedFunction;
                    n.ty = ty;
                    n.constant = isConstant(context, n.a);
                },
                .binary => {
                    try typeExpr(context, scope, n.a);
                    try typeExpr(context, scope, n.b);
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                    switch (n.op) {
                        .eq, .ne, .lt, .le, .gt, .ge => {
                            try comparable(context, &n.a, &n.b);
                            n.ty = .boolean;
                        },
                        .add, .sub, .mul, .div, .mod => try arithmeticType(context, n),
                        .concat => {
                            // text || text, text || anynonarray, anynonarray || text.
                            if (context.node(n.a).ty == .unknown) try coerce(context, n.a, .text);
                            if (context.node(n.b).ty == .unknown) try coerce(context, n.b, .text);
                            if (!value.stringType(context.node(n.a).ty) and !value.stringType(context.node(n.b).ty)) return error.UndefinedFunction;
                            n.ty = .text;
                        },
                        .arrow, .arrow_text, .path, .path_text, .contains, .contained, .exists => try jsonOperator(context, n),
                        .neg, .pos => unreachable,
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
                    var result: ast.Type = .unknown;
                    for ([_]u16{ n.a, n.b, n.c }) |part| try unifyInto(&result, context.node(part).ty);
                    if (result == .unknown) result = .text;
                    if (result == .json) return error.UndefinedFunction;
                    if (!(value.integral(result) and value.integral(context.node(n.a).ty) and value.integral(context.node(n.b).ty) and value.integral(context.node(n.c).ty))) {
                        n.a = try convert(context, n.a, result, -1, .implicit);
                        n.b = try convert(context, n.b, result, -1, .implicit);
                        n.c = try convert(context, n.c, result, -1, .implicit);
                    }
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b) and isConstant(context, n.c);
                },
                .in_list => {
                    try typeExpr(context, scope, n.a);
                    var result: ast.Type = context.node(n.a).ty;
                    var item = n.b;
                    while (item != none) : (item = context.node(item).next) {
                        try typeExpr(context, scope, item);
                        try unifyInto(&result, context.node(item).ty);
                    }
                    if (result == .unknown) result = .text;
                    if (result == .json) return error.UndefinedFunction;
                    if (value.integral(result)) {
                        // int2/int4/int8 cells compare directly.
                        if (context.node(n.a).ty == .unknown) try coerce(context, n.a, result);
                        item = n.b;
                        while (item != none) : (item = context.node(item).next) {
                            const ty = context.node(item).ty;
                            if (ty == .unknown) try coerce(context, item, result) else if (!value.integral(ty)) return error.UndefinedFunction;
                        }
                    } else {
                        n.a = try convert(context, n.a, result, -1, .implicit);
                        n.b = try convertList(context, n.b, result);
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
                        if (n.a != none) try comparable(context, &n.a, &entry.a) else try booleanArgument(context, entry.a);
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
                    const widen = !value.integral(result);
                    arm = n.b;
                    while (arm != none) : (arm = context.node(arm).next) {
                        const entry = context.node(arm);
                        if (widen) entry.b = try convert(context, entry.b, result, -1, .implicit) else try coerce(context, entry.b, result);
                    }
                    if (n.c != none) {
                        if (widen) n.c = try convert(context, n.c, result, -1, .implicit) else try coerce(context, n.c, result);
                    }
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
                    if (value.integral(result)) {
                        item = n.b;
                        while (item != none) : (item = context.node(item).next) try coerce(context, item, result);
                    } else n.b = try convertList(context, n.b, result);
                    n.ty = result;
                    n.constant = listConstant(context, n.b);
                },
                .nullif => {
                    try typeExpr(context, scope, n.a);
                    try typeExpr(context, scope, n.b);
                    const original = context.node(n.a).ty;
                    try comparable(context, &n.a, &n.b);
                    n.ty = if (original == .unknown) context.node(n.a).ty else original;
                    if (context.node(n.a).ty != n.ty) {
                        // NULLIF returns the first argument's type.
                        n.ty = context.node(n.a).ty;
                    }
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                },
                .cast => {
                    const target = n.cast_type;
                    const inner = context.node(n.a);
                    if (inner.kind == .decimal_literal and (target == .float4 or target == .float8)) {
                        // numeric -> float8 is float8in of the numeric's text,
                        // so a float-cast literal is parsed as a float directly
                        // (no NUMERIC capacity limit for 1e100::float8).
                        _ = try Io.parse(target, -1, inner.name.span.slice(context.source), context.session);
                        inner.ty = target;
                        inner.constant = true;
                    } else try typeExpr(context, scope, n.a);
                    const from = context.node(n.a).ty;
                    if (from == .unknown) {
                        try coerce(context, n.a, target);
                    } else if (!value.castable(from, target, .explicit)) return error.CannotCoerce;
                    // Typmods are validated at bind time (eval applies them).
                    if (n.typmod >= 0 and context.node(n.a).kind == .text_literal) {
                        const text = E.literalText(context.source, context.node(n.a).text);
                        _ = try Io.parse(target, n.typmod, text.slice(), context.session);
                    }
                    n.ty = target;
                    n.constant = isConstant(context, n.a);
                },
                .at_zone => {
                    try typeExpr(context, scope, n.a);
                    try typeExpr(context, scope, n.b);
                    var ty = context.node(n.a).ty;
                    if (ty == .unknown or ty == .date) {
                        n.a = try convert(context, n.a, .timestamptz, -1, .implicit);
                        ty = .timestamptz;
                    }
                    if (ty != .timestamp and ty != .timestamptz) return error.UndefinedFunction;
                    try coerce(context, n.b, .text);
                    if (context.node(n.b).ty != .text) return error.UndefinedFunction;
                    n.ty = if (ty == .timestamptz) .timestamp else .timestamptz;
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                },
            }
        }

        /// Types an expression whose untyped result defaults to text.
        fn valueExpr(context: *const Context, scope: *const Scope, id: u16) Error!void {
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
                if (left.kind == .column and left.column == primary and right.constant and storedTag(entry, primary, right.ty)) return n.b;
                if (right.kind == .column and right.column == primary and left.constant and storedTag(entry, primary, left.ty)) return n.a;
            }
            return none;
        }

        /// Whether a probe value of type `ty` has the key column's cell tag.
        fn storedTag(entry: *const S.Table, column: usize, ty: ast.Type) bool {
            return V.cellTag(entry.columns[column].data_type) == V.cellTag(types.dataTypeOf(ty));
        }

        /// Assignment (INSERT values, UPDATE SET) typing: PostgreSQL
        /// assignment casts, plus integer 0/1 into boolean for MySQL/TDS.
        /// Returns the (possibly cast-wrapped) expression id.
        fn assignment(context: *const Context, id: u16, column: *const V.Column) Error!u16 {
            const target = types.typeOfData(column.data_type);
            const ty = context.node(id).ty;
            if (ty == .unknown) {
                try coerce(context, id, target);
                return id;
            }
            if (target == .boolean and value.integral(ty) and context.booleanIntegers()) return id;
            if (value.integral(target) and value.integral(ty)) return id;
            if (ty == target) return id;
            return convert(context, id, target, -1, .assignment);
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
                .at_zone => .{ .name = "timezone", .strength = 2 },
                .case_expr => .{ .name = "case", .strength = 1 },
                .cast => blk: {
                    const inner = figure(context, n.a, buffer);
                    if (inner.strength > 1) break :blk inner;
                    break :blk .{ .name = types.typeInfo(types.dataTypeOf(n.cast_type)).name, .strength = 1 };
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

        fn outputTypmod(context: *const Context, id: u16) i32 {
            const n = context.node(id);
            return switch (n.kind) {
                .column, .cast => n.typmod,
                else => -1,
            };
        }

        fn bindSelect(context: *const Context, select: *const Ast.Select) Error!Select {
            const scope = try scopeFor(context, select.from);
            var out: Select = .{ .table = scope.table, .targets = undefined, .names = undefined, .types = undefined, .count = 0, .where = none, .key = none, .order = undefined, .order_count = 0, .limit = select.limit, .lock = select.lock };
            for (select.targets[0..select.count]) |*target| {
                if (target.star) {
                    const entry = &context.tables[scope.table.?];
                    for (entry.columns[0..entry.column_count], 0..) |*column, index| {
                        if (out.count == config.columns) return error.ColumnCapacity;
                        const id = try context.pool.add(.{ .kind = .column, .column = @intCast(index), .ty = types.typeOfData(column.data_type), .typmod = column.typmod });
                        out.targets[out.count] = id;
                        out.names[out.count] = column.name;
                        out.types[out.count] = column.data_type;
                        out.typmods[out.count] = column.typmod;
                        out.count += 1;
                    }
                    continue;
                }
                if (out.count == config.columns) return error.ColumnCapacity;
                try valueExpr(context, &scope, target.expr);
                out.targets[out.count] = target.expr;
                out.names[out.count] = if (target.alias) |alias| toName(context, alias) else targetName(context, target.expr);
                out.types[out.count] = types.dataTypeOf(context.node(target.expr).ty);
                out.typmods[out.count] = outputTypmod(context, target.expr);
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
                    try valueExpr(context, &scope, id);
                }
                if (context.node(id).ty == .json) return error.UndefinedFunction;
                out.order[out.order_count] = .{ .expr = id, .descending = key.descending, .nulls_first = key.nulls_first };
                out.order_count += 1;
            }
            return out;
        }

        fn columnType(context: *const Context, definition: *const Ast.ColumnDef) types.DataType {
            const plain_integer: types.DataType = if (context.legacy or context.dialect != .postgres) integer_type else .integer32;
            return switch (definition.type_name) {
                .int4 => plain_integer,
                else => types.dataTypeOf(definition.type_name),
            };
        }

        pub fn bind(context: *const Context, statement: *const Ast.Statement) Error!Bound {
            switch (statement.*) {
                .create_table => |*create| {
                    const table_name = toName(context, create.name);
                    if (context.catalog.lookup(table_name.slice(), context.snapshot) != null) return error.TableExists;
                    var out: Create = .{ .name = table_name, .columns = @splat(.{}), .count = create.count };
                    for (create.columns[0..create.count], 0..) |*definition, index| {
                        var column: V.Column = .{ .name = toName(context, definition.name), .not_null = definition.not_null, .primary_key = definition.primary_key, .typmod = definition.typmod };
                        for (out.columns[0..index]) |*previous|
                            if (types.same(previous.name.slice(), column.name.slice())) return error.DuplicateColumn;
                        column.data_type = columnType(context, definition);
                        if (definition.primary_key and column.data_type == .json) return error.UndefinedFunction;
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
                        out.values[column] = try assignment(context, id, &entry.columns[column]);
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
                        out.values[column] = try assignment(context, item.value, &entry.columns[column]);
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
                .control => |control| return .{ .control = control },
            }
        }
    };
}
