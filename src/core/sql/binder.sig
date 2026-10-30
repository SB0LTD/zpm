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
const sequence = @import("sequence.sig");
const parser = @import("parser.sig");
const Error = types.Error;
const none = ast.none;

pub fn Binder(comptime config: types.Config) type {
    const V = types.Values(config);
    const Ast = ast.Ast(config);
    const S = storage.Storage(config);
    const K = catalog.Catalog(config);
    const E = expr.Eval(config);
    const Io = value.Io(config);
    const P = parser.Parser(config);
    return struct {
        /// INTEGER outside the PostgreSQL dialect and in legacy replay.
        pub const integer_type: types.DataType = if (config.integer_bits == 32) .integer32 else .integer;

        /// An identity column's owned sequence `<table>_<column>_seq`.
        pub const Identity = struct { column: u8, name: V.Name, spec: sequence.Spec };

        pub const Create = struct {
            name: V.Name,
            columns: [config.columns]V.Column,
            count: usize,
            identity: ?Identity = null,
        };

        pub const CreateSequence = struct { name: V.Name, spec: sequence.Spec };

        /// RETURNING output columns, evaluated over one table row (relation 0).
        pub const Returning = struct {
            targets: [config.columns]u16 = undefined,
            names: [config.columns]V.Name = undefined,
            types: [config.columns]types.DataType = undefined,
            typmods: [config.columns]i32 = undefined,
            count: usize = 0,
        };

        /// VALUES: `rows` is the first values_row node; item p of every row
        /// is assigned to column mapping[p] (a default_value item, or an
        /// unlisted column, takes the column default). INSERT ... SELECT:
        /// `plan` is the root plan and `values[c]` reads its output row as
        /// relation 1. DEFAULT VALUES: neither (one row of defaults).
        pub const Insert = struct {
            table: usize,
            rows: u16 = none,
            row_count: usize = 0,
            mapping: [config.columns]u8 = undefined,
            count: usize = 0,
            plan: u16 = none,
            values: [config.columns]u16 = @splat(none),
            /// Column defaults (DEFAULT expression or identity nextval) and
            /// stored generation expressions; both evaluate with the
            /// column's expression text as source.
            defaults: [config.columns]u16 = @splat(none),
            generated: [config.columns]u16 = @splat(none),
            conflict: Conflict = .{},
            returning: Returning = .{},
        };

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

        /// `values[c]` is the expression assigned to column c (a
        /// default_value node for SET c = DEFAULT), or none.
        pub const Update = struct { table: usize, values: [config.columns]u16, where: u16, key: u16, returning: Returning = .{}, defaults: [config.columns]u16 = @splat(none), generated: [config.columns]u16 = @splat(none) };

        pub const Delete = struct { table: usize, where: u16, key: u16, returning: Returning = .{} };

        /// ON CONFLICT on the primary key (the only unique index). DO UPDATE
        /// evaluates `update` with the existing row as relation 0 and the
        /// proposed row (EXCLUDED) as relation 1.
        pub const Conflict = struct {
            action: ast.ConflictAction = .none,
            update: Update = .{ .table = 0, .values = @splat(none), .where = none, .key = none },
        };

        pub const Bound = union(enum) {
            create_table: Create,
            drop_table: usize,
            create_sequence: CreateSequence,
            /// Sequence slot.
            drop_sequence: usize,
            insert: Insert,
            select: Select,
            /// Root plan of a general query (Context.plans).
            query: u16,
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
            /// Plan storage for general queries; null rejects subqueries.
            plans: ?*Plans = null,

            fn node(self: *const Context, id: u16) *ast.Node {
                return &self.pool.nodes[id];
            }

            fn booleanIntegers(self: *const Context) bool {
                return self.legacy or self.dialect != .postgres;
            }
        };

        pub const no_cte: u8 = 0xff;
        pub const group_relation = ast.groupRelation(config);

        /// A FROM item visible to expressions: a base table, or the result
        /// of a derived table / CTE plan.
        pub const Relation = struct {
            /// Qualifying name: the alias, else the table or CTE name.
            name: V.Name = .{},
            table: ?usize = null,
            plan: u16 = none,
            cte: u8 = no_cte,
            /// A system view (catalog.sig) computed at scan time.
            view: ?catalog.View = null,
        };

        /// USING column merged from the relations joined before `right`.
        const Using = struct { ident: ast.Ident, left: u8, left_column: u16, right: u8, right_column: u16, join: ast.JoinKind };

        /// CTE names visible to a query block (innermost WITH first).
        const CteEnv = struct {
            ids: [config.ctes]u8 = undefined,
            count: usize = 0,
            parent: ?*const CteEnv = null,
        };

        const Scope = struct {
            rels: [config.relations]Relation = undefined,
            rel_count: usize = 0,
            using: [config.columns]Using = undefined,
            using_count: usize = 0,
            /// Enclosing query block (correlated column references).
            parent: ?*const Scope = null,
            /// Plan being bound; none on the simple single-table path.
            plan: u16 = none,
            /// Aggregate calls are allowed (targets, HAVING, ORDER BY).
            aggregates: bool = false,
            windows: bool = false,
            window_error:Error=error.WindowingError,
            inside_window:bool=false,
            saw_aggregate: ?*bool = null,
            ctes: ?*const CteEnv = null,
        };

        pub const SortKey = struct { column: u16, descending: bool, nulls_first: bool };

        pub const Agg = struct { kind: ast.Agg, arg: u16, filter: u16, distinct: bool, arg_ty: ast.Type, ty: ast.Type };

        /// One FROM item of a plan, joined to the items before it.
        pub const Source = struct {
            table: ?usize = null,
            view: ?catalog.View = null,
            plan: u16 = none,
            cte: u8 = no_cte,
            join: ast.JoinKind = .first,
            on: u16 = none,
            /// Expression over earlier items equal to this table's primary
            /// key (nested-loop index probe), or none.
            probe: u16 = none,
        };

        pub const Window=struct {
            kind:Ast.WindowKind=.aggregate,
            aggregate:Agg=.{.kind=.none,.arg=none,.filter=none,.distinct=false,.arg_ty=.unknown,.ty=.unknown},
            argument:u16=none,result:u16=0,output_node:u16=none,
            deferred_arg:u16=none,deferred_filter:u16=none,filter_column:u16=none,
            partition:[config.columns]u16=undefined,partition_count:usize=0,
            order:[config.columns]SortKey=undefined,order_count:usize=0,
            frame:Ast.Frame=.default,
            start:Ast.FrameBound=.{.kind=.unbounded_preceding},end:Ast.FrameBound=.{},
            exclude:Ast.Exclusion=.no_others,
        };

        pub const Distinct = enum { none, all, on };

        /// A bound query block of the general engine (design §4.9). Its
        /// materialized rows are `width` cells: the `count` visible output
        /// columns, then resjunk sort keys.
        pub const Plan = struct {
            windows:[config.columns]Window=undefined,window_count:usize=0,
            window_late:[2*config.columns]bool=.{false}**(2*config.columns),
            set_op: ast.SetOp = .none,
            set_all: bool = false,
            left: u16 = none,
            right: u16 = none,
            sources: [config.relations]Source = undefined,
            source_count: usize = 0,
            where: u16 = none,
            grouped: bool = false,
            rollup:bool=false,
            keys: [config.columns]u16 = undefined,
            key_count: usize = 0,
            aggs: [config.columns]Agg = undefined,
            agg_count: usize = 0,
            having: u16 = none,
            targets: [2 * config.columns]u16 = undefined,
            count: usize = 0,
            width: usize = 0,
            names: [config.columns]V.Name = undefined,
            tys: [config.columns]ast.Type = undefined,
            typmods: [config.columns]i32 = undefined,
            order: [2 * config.columns]SortKey = undefined,
            order_count: usize = 0,
            distinct: Distinct = .none,
            distinct_on: [config.columns]u16 = undefined,
            distinct_on_count: usize = 0,
            limit: u64 = 0xffffffffffffffff,
            offset: u64 = 0,
            /// References a column of an enclosing block (re-run per row).
            correlated: bool = false,
        };

        pub const CteDef = struct {
            name: V.Name = .{},
            plan: u16 = none,
            /// WITH RECURSIVE body: `plan` is a UNION [ALL] whose right
            /// branch reads the working table.
            recursive: bool = false,
            referenced: bool = false,
        };

        /// Statement-scoped plans (inside Database.workspace).
        pub const Plans = struct {
            items: [config.subqueries]Plan = undefined,
            len: usize = 0,
            ctes: [config.ctes]CteDef = undefined,
            cte_len: usize = 0,

            pub fn reset(self: *Plans) void {
                self.len = 0;
                self.cte_len = 0;
            }

            fn add(self: *Plans) Error!u16 {
                if (self.len == config.subqueries) return error.StatementTooComplex;
                self.items[self.len] = .{};
                self.len += 1;
                return @intCast(self.len - 1);
            }
        };

        pub fn command(bound: *const Bound) types.CommandTag {
            return switch (bound.*) {
                .create_table => .create_table,
                .drop_table => .drop_table,
                .create_sequence => .create_sequence,
                .drop_sequence => .drop_sequence,
                .insert => .insert,
                .select, .query => .select,
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
                    .date=>{
                        const date=try Io.parse(target,-1,text.slice(),context.session);
                        n.integer=date.date;n.date_bound=true;
                    },
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
            const target = value.comparisonType(left, right) orelse return error.UndefinedFunction;
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
                .{ .name = "to_char", .func = .to_char },
                .{ .name = "grouping", .func = .grouping },
                .{ .name = "round", .func = .round },
                .{ .name = "transaction_timestamp", .func = .transaction_timestamp },
                .{ .name = "statement_timestamp", .func = .statement_timestamp },
                .{ .name = "clock_timestamp", .func = .clock_timestamp },
                .{ .name = "current_timestamp", .func = .current_timestamp },
                .{ .name = "current_date", .func = .current_date },
                .{ .name = "jsonb_typeof", .func = .jsonb_typeof },
                .{ .name = "jsonb_array_length", .func = .jsonb_array_length },
                .{ .name = "nextval", .func = .nextval },
                .{ .name = "currval", .func = .currval },
                .{ .name = "setval", .func = .setval },
                .{ .name = "lastval", .func = .lastval },
                .{ .name = "current_database", .func = .current_database },
                .{ .name = "current_schema", .func = .current_schema },
                .{ .name = "to_regtype", .func = .to_regtype },
                .{ .name = "to_regclass", .func = .to_regclass },
                .{ .name = "format_type", .func = .format_type },
                .{ .name = "pg_get_expr", .func = .pg_get_expr },
            };
            for (table) |entry| if (types.same(name.slice(), entry.name)) return entry.func;
            return .none;
        }

        fn aggregateKind(context: *const Context, n: *const ast.Node) ast.Agg {
            const name = toName(context, n.name);
            const table = [_]struct { name: []const u8, agg: ast.Agg }{
                .{ .name = "count", .agg = .count },
                .{ .name = "sum", .agg = .sum },
                .{ .name = "avg", .agg = .avg },
                .{ .name = "min", .agg = .min },
                .{ .name = "max", .agg = .max },
                .{ .name = "bool_and", .agg = .bool_and },
                .{ .name = "every", .agg = .bool_and },
                .{ .name = "bool_or", .agg = .bool_or },
            };
            for (table) |entry| if (types.same(name.slice(), entry.name)) return entry.agg;
            return .none;
        }

        /// Types an aggregate call (PostgreSQL result types: COUNT int8,
        /// SUM(int2/int4) int8, SUM(int8)/AVG(integers) numeric, AVG(float)
        /// float8). Its argument and FILTER see the input rows and cannot
        /// contain aggregates (42803).
        fn typeAggregate(context: *const Context, scope: *const Scope, n: *ast.Node, kind_in: ast.Agg) Error!void {
            if (!scope.aggregates) return error.GroupingError;
            var inner = scope.*;
            inner.aggregates = false;
            inner.windows = false;
            inner.window_error=if(scope.inside_window) error.WindowingError else error.GroupingError;
            var kind = kind_in;
            if (n.star) {
                if (kind != .count or n.distinct) return error.Syntax;
                kind = .count_star;
            } else if (n.b == none or context.node(n.b).next != none) return error.UndefinedFunction;
            const arg = n.b;
            var arg_ty: ast.Type = .unknown;
            if (arg != none) {
                try typeExpr(context, &inner, arg);
                arg_ty = context.node(arg).ty;
                if (arg_ty == .unknown) switch (kind) {
                    .count, .min, .max => try coerce(context, arg, .text),
                    .bool_and, .bool_or => try coerce(context, arg, .boolean),
                    else => return error.AmbiguousFunction,
                };
                arg_ty = context.node(arg).ty;
            }
            if (n.c != none) {
                inner.window_error=error.WindowingError;
                try typeExpr(context, &inner, n.c);
                try booleanArgument(context, n.c);
            }
            const result=try aggregateType(context,n,kind,arg,arg_ty);
            n.kind = .aggregate;
            n.agg = kind;
            n.a = n.b;
            n.b = none;
            n.ty = result;
            n.typmod = -1;
            n.constant = false;
            if (scope.saw_aggregate) |flag| flag.* = true;
        }

        fn aggregateType(context:*const Context,n:*ast.Node,kind:ast.Agg,arg:u16,arg_ty:ast.Type) Error!ast.Type {
            return switch (kind) {
                .count, .count_star => .int8,
                .sum => switch (arg_ty) {
                    .int2, .int4 => .int8,
                    .int8, .numeric => .numeric,
                    .float4, .float8, .interval => arg_ty,
                    else => return error.UndefinedFunction,
                },
                .avg => switch (arg_ty) {
                    .int2, .int4, .int8, .numeric => .numeric,
                    .float4, .float8 => .float8,
                    // AVG(interval) is not provided (no interval / number).
                    else => return error.UndefinedFunction,
                },
                .min, .max => switch (arg_ty) {
                    .int2, .int4, .int8, .numeric, .float4, .float8, .text, .oid, .date, .timestamp, .timestamptz, .interval => arg_ty,
                    .name => blk: {
                        n.b = try convert(context, arg, .text, -1, .implicit);
                        break :blk .text;
                    },
                    else => return error.UndefinedFunction,
                },
                .bool_and, .bool_or => if (arg_ty == .boolean) .boolean else return error.UndefinedFunction,
                .none => unreachable,
            };
        }

        fn repeatableWindowInput(context:*const Context,id:u16) bool {
            if(id==none) return true;const n=context.node(id);
            switch(n.kind){
                .function=>if(!ast.canRepeatFunction(n.func) and n.func!=.jsonb_typeof and n.func!=.jsonb_array_length) return false,
                .scalar_subquery,.exists_subquery,.in_subquery=>return false,
                else=>{},
            }
            if(!repeatableWindowInput(context,n.a) or !repeatableWindowInput(context,n.c)) return false;
            if(listOwner(n.kind)){var item=n.b;while(item!=none):(item=context.node(item).next) if(!repeatableWindowInput(context,item)) return false;}
            else if(!repeatableWindowInput(context,n.b)) return false;
            return true;
        }

        fn frameVariable(context:*const Context,id:u16) bool {
            if(id==none) return false;const node=context.node(id);
            if(node.kind==.column) return true;
            if(node.kind==.scalar_subquery or node.kind==.exists_subquery or node.kind==.in_subquery) {
                if(plansOf(context).items[@intCast(node.integer)].correlated) return true;
                if(node.kind!=.in_subquery) return false;
            }
            if(frameVariable(context,node.a) or frameVariable(context,node.c)) return true;
            if(listOwner(node.kind)){var item=node.b;while(item!=none):(item=context.node(item).next) if(frameVariable(context,item)) return true;}
            else if(frameVariable(context,node.b)) return true;
            return false;
        }
        fn typeFrameOffset(context:*const Context,scope:*const Scope,bound:*Ast.FrameBound) Error!void {
            if(bound.offset==none) return;
            var inner=scope.*;inner.aggregates=false;inner.windows=false;
            try typeExpr(context,&inner,bound.offset);
            if(frameVariable(context,bound.offset)) return error.InvalidColumnReference;
            const ty=context.node(bound.offset).ty;
            if(ty!=.unknown and !value.castable(ty,.int8,.assignment)) return error.TypeMismatch;
            bound.offset=try convert(context,bound.offset,.int8,-1,.assignment);
        }

        fn typeWindow(context:*const Context,scope:*const Scope,n:*ast.Node) Error!void {
            if(!scope.windows) return scope.window_error;
            if(n.distinct) return error.UnsupportedStatement;
            const spec=&context.pool.windows[n.window];
            var inner=scope.*;inner.windows=false;inner.inside_window=true;
            const name=toName(context,n.name);
            const ranking=types.same(name.slice(),"rank") or types.same(name.slice(),"dense_rank") or types.same(name.slice(),"row_number");
            if(ranking) {
                if(n.c!=none) return error.UnsupportedStatement;
                if(n.b!=none or n.star) return error.UndefinedFunction;
                n.ty=.int8;
            } else {
                var kind=aggregateKind(context,n);
                if(kind==.none) return error.UndefinedFunction;
                if(n.star) {if(kind!=.count) return error.Syntax;kind=.count_star;}
                else if(n.b==none or context.node(n.b).next!=none) return error.UndefinedFunction;
                if(n.b!=none) try typeExpr(context,&inner,n.b);
                var ty:ast.Type=if(n.b==none) .unknown else context.node(n.b).ty;
                if(n.b!=none and ty==.unknown) {
                    switch(kind){.count,.min,.max=>try coerce(context,n.b,.text),.bool_and,.bool_or=>try coerce(context,n.b,.boolean),else=>return error.AmbiguousFunction}
                    ty=context.node(n.b).ty;
                }
                n.ty=try aggregateType(context,n,kind,n.b,ty);n.agg=kind;
            }
            if(n.c!=none) {
                var filter_scope=inner;filter_scope.aggregates=false;
                try typeExpr(context,&filter_scope,n.c);try booleanArgument(context,n.c);
            }
            for(spec.partition[0..spec.partition_count]) |id| {try valueExpr(context,&inner,id);try sortableType(context.node(id).ty);}
            for(spec.order[0..spec.order_count]) |key| {try valueExpr(context,&inner,key.expr);try sortableType(context.node(key.expr).ty);}
            if(spec.frame==.groups and spec.order_count==0) return error.WindowingError;
            if(spec.frame==.range and (spec.start.offset!=none or spec.end.offset!=none)) {
                if(spec.order_count!=1) return error.WindowingError;
                if(!value.integral(context.node(spec.order[0].expr).ty)) return error.UnsupportedStatement;
            }
            try typeFrameOffset(context,scope,&spec.start);try typeFrameOffset(context,scope,&spec.end);
            if(spec.exclude==.no_others and spec.start.kind==.unbounded_preceding) {
                if(spec.end.kind==.unbounded_following) spec.frame=.full
                else if(spec.end.kind==.current_row and spec.frame!=.default) spec.frame=if(spec.frame==.rows) .rows_prefix else .default;
            }
            if((spec.frame==.rows or spec.frame==.groups or spec.frame==.range) and !ranking and (!repeatableWindowInput(context,n.b) or !repeatableWindowInput(context,n.c))) return error.UnsupportedStatement;
            n.func=.window_call;n.constant=false;
        }

        fn typeFunction(context: *const Context, scope: *const Scope, n: *ast.Node) Error!void {
            if(n.window!=none) return typeWindow(context,scope,n);
            switch (n.func) {
                // Bound internally (identity defaults, reg casts): already typed.
                .identity_next, .regclass_in, .regtype_in, .regclass_out, .regtype_out => {
                    n.constant = false;
                    return;
                },
                else => {},
            }
            const agg = aggregateKind(context, n);
            if (agg != .none) return typeAggregate(context, scope, n, agg);
            if (n.distinct or n.c != none or n.star) return error.UndefinedFunction;
            // GREATEST/LEAST are grammar forms, not ordinary named functions.
            if (n.func != .greatest and n.func != .least) n.func = functionName(context, n);
            var count: usize = 0;
            var item = n.b;
            while (item != none) : (item = context.node(item).next) {
                try typeExpr(context, scope, item);
                count += 1;
            }
            switch (n.func) {
                .grouping => {
                    if(!scope.aggregates) return error.GroupingError;
                    if(count==0 or count>31) return error.InvalidParameterValue;
                    n.ty=.int4;n.constant=false;
                    if(scope.saw_aggregate) |flag| flag.*=true;
                },
                .window_call => unreachable,
                .none => return error.UndefinedFunction,
                .greatest, .least => {
                    if (count == 0) return error.Syntax;
                    var target: ast.Type = .unknown;
                    item = n.b;
                    while (item != none) : (item = context.node(item).next) try unifyInto(&target, context.node(item).ty);
                    if (target == .unknown) target = .text;
                    if (target == .json) return error.UndefinedFunction;
                    n.b = try convertList(context, n.b, target);
                    n.ty = target;
                    n.constant = listConstant(context, n.b);
                },
                .to_char => {
                    if (count != 2) return error.UndefinedFunction;
                    const first=n.b;const second=context.node(first).next;
                    const ty=context.node(first).ty;
                    if(ty==.unknown) return error.AmbiguousFunction;
                    const target:ast.Type=switch(ty){.date=>.timestamptz,.timestamp,.timestamptz=>ty,else=>return error.UndefinedFunction};
                    const argument=try convert(context,first,target,-1,.implicit);
                    const format=try convert(context,second,.text,-1,.implicit);
                    context.node(argument).next=format;context.node(format).next=none;
                    n.b=argument;n.ty=.text;n.constant=isConstant(context,argument) and isConstant(context,format);
                },
                .round => {
                    if (count != 1 and count != 2) return error.UndefinedFunction;
                    const first = n.b;
                    const second = context.node(first).next;
                    // PostgreSQL prefers float8 for one unknown/integral/real
                    // argument; two arguments have only the numeric,int4 form.
                    const target: ast.Type = if (count == 2 or context.node(first).ty == .numeric) .numeric else .float8;
                    const argument = try convert(context, first, target, -1, .implicit);
                    const scale = if (count == 2) try convert(context, second, .int4, -1, .implicit) else none;
                    context.node(argument).next = scale;
                    if (scale != none) context.node(scale).next = none;
                    n.b = argument;
                    n.ty = target;
                    n.constant = isConstant(context, argument) and (scale == none or isConstant(context, scale));
                },
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
                // Sequence functions (regclass arguments as text; volatile).
                .nextval, .currval, .setval, .lastval => {
                    const wanted: []const ast.Type = switch (n.func) {
                        .lastval => &.{},
                        .setval => if (count == 3) &.{ .text, .int8, .boolean } else &.{ .text, .int8 },
                        else => &.{.text},
                    };
                    if (count != wanted.len) return error.UndefinedFunction;
                    var args: [3]u16 = undefined;
                    var arg_item = n.b;
                    for (0..count) |index| {
                        args[index] = arg_item;
                        arg_item = context.node(arg_item).next;
                    }
                    for (wanted, 0..) |target, index| {
                        const ty = context.node(args[index]).ty;
                        // A regclass (OID) names the sequence directly.
                        if (index == 0 and ty == .oid) continue;
                        if (ty != .unknown and ty != target and !(value.integral(ty) and value.integral(target))) return error.UndefinedFunction;
                        args[index] = try convert(context, args[index], target, -1, .implicit);
                    }
                    for (0..count) |index| context.node(args[index]).next = if (index + 1 < count) args[index + 1] else none;
                    if (count != 0) n.b = args[0];
                    n.ty = .int8;
                    n.constant = false;
                },
                // Catalog discovery functions (design §4.10).
                .current_database, .current_schema => {
                    if (count != 0) return error.UndefinedFunction;
                    n.ty = .name;
                },
                .to_regtype, .to_regclass => {
                    if (count != 1) return error.UndefinedFunction;
                    const ty = context.node(n.b).ty;
                    if (ty == .unknown) try coerce(context, n.b, .text) else if (ty != .text and ty != .name) return error.UndefinedFunction;
                    n.ty = .oid;
                    // PostgreSQL returns regtype / regclass: `::text` prints the name.
                    n.reg = if (n.func == .to_regtype) .regtype else .regclass;
                    n.constant = false;
                },
                .format_type => {
                    if (count != 2) return error.UndefinedFunction;
                    const first = n.b;
                    const second = context.node(first).next;
                    for ([_]u16{ first, second }) |argument| {
                        const ty = context.node(argument).ty;
                        if (ty == .unknown) try coerce(context, argument, .int4) else if (!value.integral(ty) and ty != .oid) return error.UndefinedFunction;
                    }
                    n.ty = .text;
                    n.constant = isConstant(context, first) and isConstant(context, second);
                },
                .pg_get_expr => {
                    if (count != 2 and count != 3) return error.UndefinedFunction;
                    if (context.node(n.b).ty == .unknown) try coerce(context, n.b, .text);
                    if (context.node(n.b).ty != .text) return error.UndefinedFunction;
                    n.ty = .text;
                    n.constant = false;
                },
                .identity_next, .regclass_in, .regtype_in, .regclass_out, .regtype_out => unreachable,
            }
        }

        /// `x::regclass` / `x::regtype`: text input becomes a lookup (42P01 /
        /// 42704 when missing); an integer or OID keeps its value. The result
        /// is an OID tagged with its reg type, so `::text` prints the name.
        fn regCast(context: *const Context, scope: *const Scope, n: *ast.Node) Error!void {
            const reg: ast.Reg = if (n.typmod == ast.regclass_typmod) .regclass else .regtype;
            try typeExpr(context, scope, n.a);
            const from = context.node(n.a).ty;
            if (from == .unknown or from == .text or from == .name) {
                if (from == .unknown) try coerce(context, n.a, .text);
                n.kind = .function;
                n.func = if (reg == .regclass) .regclass_in else .regtype_in;
                n.b = n.a;
                n.a = none;
                n.ty = .oid;
                n.typmod = -1;
                n.reg = reg;
                n.constant = false;
                return;
            }
            if (!value.integral(from) and from != .oid) return error.CannotCoerce;
            n.cast_type = .oid;
            n.typmod = -1;
            n.ty = .oid;
            n.reg = reg;
            n.constant = isConstant(context, n.a);
        }

        /// Binds a column's DEFAULT or generation text (its own source) into
        /// the statement pool; generation expressions see the row (relation 0).
        fn storedSource(table: usize, column: usize) i64 {
            return 1 + @as(i64, @intCast(table * config.columns + column));
        }

        fn bindExpressionText(context: *const Context, column: *const V.Column, row_table: ?usize, source_owner: i64) Error!u16 {
            var sub = context.*;
            sub.source = column.expression.slice();
            const start = context.pool.len;
            const id = try P.parseExpression(sub.source, context.pool);
            if (row_table != null) try generatedSubqueries(&sub, id);
            const scope: Scope = if (row_table) |table| tableScope(&sub, table) else .{};
            try typeExpr(&sub, &scope, id);
            const assigned = try assignment(&sub, id, column);
            if (row_table) |table| {
                try generatedReferences(&sub, assigned, table);
                try simplifyGenerated(&sub, assigned);
                if (!immutableGenerated(&sub, assigned)) return error.InvalidObjectDefinition;
            }
            // Store an index, never a pointer into temporary CREATE metadata.
            for (context.pool.nodes[start..context.pool.len]) |*n| {
                if (n.kind == .row_compare and n.a != none) n.integer = -1;
            }
            markStoredSources(&sub, assigned, source_owner);
            return assigned;
        }

        fn markStoredSources(context: *const Context, id: u16, owner: i64) void {
            if (id == none) return;
            const n = context.node(id);
            if (n.kind == .row_compare and n.a != none) n.integer = owner;
            markStoredSources(context, n.a, owner);
            markStoredSources(context, n.c, owner);
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) markStoredSources(context, item, owner);
            } else markStoredSources(context, n.b, owner);
        }

        fn generatedSubqueries(context: *const Context, id: u16) Error!void {
            if (id == none) return;
            const n = context.node(id);
            switch (n.kind) { .scalar_subquery, .exists_subquery, .in_subquery => return error.UnsupportedStatement, else => {} }
            try generatedSubqueries(context, n.a);
            try generatedSubqueries(context, n.c);
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) try generatedSubqueries(context, item);
            } else try generatedSubqueries(context, n.b);
        }

        fn generatedReferences(context: *const Context, id: u16, table: usize) Error!void {
            if (id == none) return;
            const n = context.node(id);
            if (n.kind == .column and n.level == 0 and n.relation == 0 and context.tables[table].columns[n.column].default_kind == .generated) return error.InvalidObjectDefinition;
            try generatedReferences(context, n.a, table);
            try generatedReferences(context, n.c, table);
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) try generatedReferences(context, item, table);
            } else try generatedReferences(context, n.b, table);
        }

        fn knownNull(context: *const Context, id: u16) bool {
            if (id == none) return false;
            const n = context.node(id);
            return n.kind == .null_literal or (n.kind == .cast and knownNull(context, n.a));
        }

        fn immutableGenerated(context: *const Context, id: u16) bool {
            if (id == none) return true;
            const n = context.node(id);
            switch (n.kind) {
                .function => if (!ast.immutableFunction(n.func)) return false,
                .cast => {
                    const from = context.node(n.a).ty; const to = n.cast_type;
                    if (from != to) {
                        if (value.stringType(from) and (value.datetime(to) or to == .interval)) return false;
                        if (value.stringType(to) and (value.datetime(from) or from == .interval)) return false;
                        if ((from == .timestamptz and value.datetime(to)) or (to == .timestamptz and value.datetime(from))) return false;
                    }
                },
                .binary => if ((n.op == .add or n.op == .sub) and n.ty == .timestamptz and
                    (context.node(n.a).ty == .interval or context.node(n.b).ty == .interval)) return false,
                .scalar_subquery, .exists_subquery, .in_subquery, .aggregate => return false,
                .row_compare => {
                    if (n.a != none) return true;
                    var item = n.b;
                    while (item != none) : (item = context.node(item).next) {
                        const pair = context.node(item);
                        if ((n.op == .eq or n.op == .ne) and (knownNull(context, pair.a) or knownNull(context, pair.b))) continue;
                        if (!immutableGenerated(context, pair.a) or !immutableGenerated(context, pair.b)) return false;
                    }
                    return true;
                },
                else => {},
            }
            if (!immutableGenerated(context, n.a) or !immutableGenerated(context, n.c)) return false;
            if (!listOwner(n.kind)) return immutableGenerated(context, n.b);
            var item = n.b;
            while (item != none) : (item = context.node(item).next) if (!immutableGenerated(context, item)) return false;
            return true;
        }

        fn generatedConstant(context: *const Context, id: u16) bool {
            return id != none and context.node(id).ty != .unknown and isConstant(context, id) and immutableGenerated(context, id);
        }

        fn generatedValue(context: *const Context, id: u16) Error!V.Cell {
            const eval_context: E.Context = .{ .source = context.source, .pool = context.pool, .session = context.session };
            return E.eval(&eval_context, id);
        }

        fn generatedLiteral(context: *const Context, id: u16, boolean: ?bool) void {
            const n = context.node(id);
            n.* = .{ .kind = if (boolean == null) .null_literal else .bool_literal, .ty = n.ty, .boolean = boolean orelse false, .constant = true, .next = n.next, .name = n.name };
        }

        fn generatedReplace(context: *const Context, id: u16, replacement: u16) Error!void {
            const n = context.node(id);
            var source = replacement;
            if (context.node(source).ty != n.ty) source = try context.pool.add(.{ .kind = .cast, .a = source, .cast_type = n.ty, .ty = n.ty, .typmod = n.typmod, .constant = isConstant(context, source) });
            const next = n.next; const name = n.name;
            n.* = context.node(source).*; n.next = next; n.name = name;
        }

        /// Plan only the supported expression subset, without executing mutable
        /// calls. Pruned AST nodes remain in the pool but cannot be evaluated.
        fn simplifyGenerated(context: *const Context, id: u16) Error!void {
            if (id == none) return;
            const n = context.node(id);
            if (n.kind == .column) return;
            if (n.kind == .case_expr) {
                try simplifyGenerated(context, n.a);
                const known = n.a == none or generatedConstant(context, n.a);
                const operand = if (n.a != none and known) try generatedValue(context, n.a) else V.Cell.null_value;
                var head: u16 = none; var tail: u16 = none; var arm = n.b;
                while (arm != none) {
                    const entry = context.node(arm); const next = entry.next;
                    try simplifyGenerated(context, entry.a);
                    if (known and generatedConstant(context, entry.a)) {
                        const candidate = try generatedValue(context, entry.a);
                        const hit = if (n.a == none) candidate == .boolean and candidate.boolean else E.compareOp(.eq, &operand, &candidate) == true;
                        if (!hit) { arm = next; continue; }
                        try simplifyGenerated(context, entry.b);
                        if (head == none) return generatedReplace(context, id, entry.b);
                        n.c = entry.b; break;
                    }
                    try simplifyGenerated(context, entry.b);
                    entry.constant = isConstant(context, entry.a) and isConstant(context, entry.b);
                    if (head == none) head = arm else context.node(tail).next = arm;
                    tail = arm; entry.next = none; arm = next;
                }
                n.b = head;
                try simplifyGenerated(context, n.c);
                if (head == none) {
                    if (n.c != none) return generatedReplace(context, id, n.c);
                    generatedLiteral(context, id, null); return;
                }
                n.constant = isConstant(context, n.a) and listConstant(context, n.b) and isConstant(context, n.c);
                return;
            }
            if (n.kind == .coalesce) {
                var head: u16 = none; var tail: u16 = none; var item = n.b;
                while (item != none) {
                    const next = context.node(item).next;
                    try simplifyGenerated(context, item);
                    if (generatedConstant(context, item)) {
                        if ((try generatedValue(context, item)) == .null_value) { item = next; continue; }
                        if (head == none) return generatedReplace(context, id, item);
                        context.node(tail).next = item; context.node(item).next = none; n.b = head;
                        n.constant = listConstant(context, head); return;
                    }
                    if (head == none) head = item else context.node(tail).next = item;
                    tail = item; context.node(item).next = none; item = next;
                }
                n.b = head; n.constant = listConstant(context, head);
                if (head == none) generatedLiteral(context, id, null);
                return;
            }
            if (n.kind == .row_compare and n.a == none) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) {
                    const pair = context.node(item);
                    try simplifyGenerated(context, pair.a); try simplifyGenerated(context, pair.b);
                    pair.constant = isConstant(context, pair.a) and isConstant(context, pair.b);
                }
                n.constant = listConstant(context, n.b); return;
            }
            if (n.kind == .and_op or n.kind == .or_op) {
                const annihilator = n.kind == .or_op;
                try simplifyGenerated(context, n.a);
                if (generatedConstant(context, n.a)) {
                    const folded = try generatedValue(context, n.a);
                    if (folded == .boolean and folded.boolean == annihilator) { generatedLiteral(context, id, annihilator); return; }
                }
                try simplifyGenerated(context, n.b);
                if (generatedConstant(context, n.b)) {
                    const folded = try generatedValue(context, n.b);
                    if (folded == .boolean and folded.boolean == annihilator) { generatedLiteral(context, id, annihilator); return; }
                }
                n.constant = isConstant(context, n.a) and isConstant(context, n.b); return;
            }
            try simplifyGenerated(context, n.a); try simplifyGenerated(context, n.c);
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) try simplifyGenerated(context, item);
                n.constant = isConstant(context, n.a) and isConstant(context, n.c) and listConstant(context, n.b);
            } else {
                try simplifyGenerated(context, n.b);
                n.constant = isConstant(context, n.a) and isConstant(context, n.b) and isConstant(context, n.c);
            }
            if (n.kind == .row_compare and n.a != none) { generatedLiteral(context, id, null); return; }
            if (n.kind == .cast and knownNull(context, n.a)) { generatedLiteral(context, id, null); return; }
            if (n.kind == .nullif and knownNull(context, n.a)) { generatedLiteral(context, id, null); return; }
            if (n.kind == .binary and n.op != .is_distinct and n.op != .is_not_distinct and (knownNull(context, n.a) or knownNull(context, n.b))) { generatedLiteral(context, id, null); return; }
            if (n.kind == .function and ast.strictFunction(n.func)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) if (knownNull(context, item)) { generatedLiteral(context, id, null); return; };
            }
            if (n.kind == .like and n.c != none and generatedConstant(context, n.b) and generatedConstant(context, n.c)) {
                const pattern = try generatedValue(context, n.b); const escape = try generatedValue(context, n.c);
                if (pattern != .null_value and escape != .null_value) try expr.validateLikeEscape(escape.text.slice());
            }
            if (generatedConstant(context, id)) {
                const evaluated = try generatedValue(context, id);
                if (evaluated == .null_value) generatedLiteral(context, id, null) else if (evaluated == .boolean) generatedLiteral(context, id, evaluated.boolean);
                if (evaluated == .integer) n.* = .{ .kind = .int_literal, .integer = evaluated.integer, .ty = n.ty, .constant = true, .next = n.next, .name = n.name };
            }
        }

        fn assignedDefaults(context: *const Context, values: *const [config.columns]u16) [config.columns]bool {
            var needed: [config.columns]bool = @splat(false);
            for (values, 0..) |id, column| needed[column] = id != none and context.node(id).kind == .default_value;
            return needed;
        }

        fn insertedDefaults(context: *const Context, insert: *const Insert) [config.columns]bool {
            if (insert.plan != none) {
                var needed: [config.columns]bool = undefined;
                for (insert.values, 0..) |id, column| needed[column] = id == none;
                return needed;
            }
            var needed: [config.columns]bool = @splat(true);
            if (insert.rows == none) return needed;
            for (insert.mapping[0..insert.count]) |column| needed[column] = false;
            var row = insert.rows;
            while (row != none) : (row = context.node(row).next) {
                var item = context.node(row).b;
                var position: usize = 0;
                while (item != none) : (item = context.node(item).next) {
                    if (context.node(item).kind == .default_value) needed[insert.mapping[position]] = true;
                    position += 1;
                }
            }
            return needed;
        }

        fn bindDefaults(context: *const Context, index: usize, entry: *const S.Table, needed: *const [config.columns]bool, defaults: *[config.columns]u16, generated: *[config.columns]u16) Error!void {
            for (entry.columns[0..entry.column_count], 0..) |*column, position| switch (column.default_kind) {
                .none => {},
                .identity_always, .identity_by_default => defaults[position] = try context.pool.add(.{ .kind = .function, .func = .identity_next, .integer = @intCast(index), .column = @intCast(position), .ty = types.typeOfData(column.data_type) }),
                .default => if (needed[position]) { defaults[position] = try bindExpressionText(context, column, null, storedSource(index, position)); },
                .generated => generated[position] = try bindExpressionText(context, column, index, storedSource(index, position)),
            };
        }

        /// An explicit (non-DEFAULT) value for a column: GENERATED columns
        /// and ALWAYS identities reject it (428C9) unless OVERRIDING SYSTEM
        /// VALUE; OVERRIDING USER VALUE replaces identity values with the
        /// default. Returns whether the value is used.
        fn explicitValue(column: *const V.Column, overriding: ast.Overriding) Error!bool {
            switch (column.default_kind) {
                .generated => return error.GeneratedAlways,
                .identity_always => {
                    if (overriding == .user) return false;
                    if (overriding != .system) return error.GeneratedAlways;
                },
                .identity_by_default => if (overriding == .user) return false,
                else => {},
            }
            return true;
        }

        /// PostgreSQL's primary-key constraint name `<table>_pkey`.
        fn primaryKeyName(entry: *const S.Table) Error!V.Name {
            var out: V.Name = .{};
            for ([_][]const u8{ entry.name.slice(), "_pkey" }) |part| {
                if (part.len > config.name_bytes - out.len) return error.NameCapacity;
                @memcpy(out.bytes[out.len..][0..part.len], part);
                out.len += part.len;
            }
            return out;
        }

        fn bindAssignments(context: *const Context, scope: *const Scope, entry: *const S.Table, assignments: []const Ast.Assignment, values: *[config.columns]u16) Error!void {
            for (assignments) |*item| {
                const column = try columnIndex(context, entry, item.column);
                if (values[column] != none) return error.DuplicateColumn;
                if (context.node(item.value).kind == .default_value) {
                    values[column] = item.value;
                    continue;
                }
                switch (entry.columns[column].default_kind) {
                    .generated, .identity_always => return error.GeneratedAlways,
                    else => {},
                }
                try typeExpr(context, scope, item.value);
                values[column] = try assignment(context, item.value, &entry.columns[column]);
            }
        }

        /// The conflict arbiter must be the primary key (42P10 otherwise; a
        /// missing named constraint is 42704; DO UPDATE needs a target).
        fn bindConflict(context: *const Context, index: usize, entry: *const S.Table, table_alias: ?ast.Ident, conflict: *const Ast.OnConflict, out: *Conflict) Error!void {
            if (conflict.constraint) |ident| {
                const wanted = toName(context, ident);
                if (entry.primary_column == null) return error.UndefinedObject;
                const name = try primaryKeyName(entry);
                if (!types.same(wanted.slice(), name.slice())) return error.UndefinedObject;
            } else if (conflict.column_count != 0) {
                var used: [config.columns]bool = @splat(false);
                for (conflict.columns[0..conflict.column_count]) |ident| used[try columnIndex(context, entry, ident)] = true;
                const primary = entry.primary_column orelse return error.InvalidColumnReference;
                for (used, 0..) |flag, column| if (flag != (column == primary)) return error.InvalidColumnReference;
            } else if (conflict.action == .update) return error.Syntax;
            out.action = conflict.action;
            if (conflict.action != .update) return;
            var scope = tableScope(context, index);
            if (table_alias) |name| scope.rels[0].name = toName(context, name);
            // EXCLUDED is an ordinary relation name: an unqualified column
            // present in both is ambiguous (42702), as in PostgreSQL.
            scope.rels[1] = .{ .table = index, .name = literalName("excluded") };
            scope.rel_count = 2;
            var update: Update = .{ .table = index, .values = @splat(none), .where = none, .key = none };
            try bindAssignments(context, &scope, entry, conflict.assignments[0..conflict.count], &update.values);
            update.where = try bindWhere(context, &scope, conflict.where);
            const needed = assignedDefaults(context, &update.values);
            try bindDefaults(context, index, entry, &needed, &update.defaults, &update.generated);
            out.update = update;
        }

        fn integerColumn(data_type: types.DataType) bool {
            return data_type == .smallint or data_type == .integer32 or data_type == .integer;
        }

        fn identityName(table: V.Name, column: V.Name) Error!V.Name {
            const parts = [_][]const u8{ table.slice(), "_", column.slice(), "_seq" };
            var out: V.Name = .{};
            for (parts) |part| {
                if (part.len > config.name_bytes - out.len) return error.NameCapacity;
                @memcpy(out.bytes[out.len..][0..part.len], part);
                out.len += part.len;
            }
            return out;
        }

        fn bindRowFields(context: *const Context, scope: *const Scope, id: u16) Error!void {
            const row = context.node(id);
            var item = row.b;
            while (item != none) : (item = context.node(item).next) {
                const field_node = context.node(item);
                if (field_node.kind == .row_constructor) return error.UnsupportedStatement;
                // A clone of a bound field retains its scope and plan IDs.
                // Only unresolved fields need binding again (literals are
                // idempotent; a bound subquery must not be rebound as syntax).
                if (field_node.ty == .unknown) try typeExpr(context, scope, item);
            }
            row.constant = listConstant(context, row.b);
        }

        fn bindRowCompare(context: *const Context, scope: *const Scope, id: u16) Error!void {
            const n = context.node(id);
            if (context.node(n.a).kind != .row_constructor or context.node(n.b).kind != .row_constructor) return error.UndefinedFunction;
            switch (n.op) { .eq, .ne, .lt, .le, .gt, .ge, .is_distinct, .is_not_distinct => {}, else => return error.UndefinedFunction }
            try bindRowFields(context, scope, n.a);
            try bindRowFields(context, scope, n.b);
            var left = context.node(n.a).b;
            var right = context.node(n.b).b;
            var l = left; var r = right;
            while (l != none and r != none) { l = context.node(l).next; r = context.node(r).next; }
            if (l != none or r != none) return error.Syntax;
            if (left == none) {
                if (n.op != .is_distinct and n.op != .is_not_distinct) return error.UnsupportedStatement;
                n.* = .{ .kind = .bool_literal, .boolean = n.op == .is_not_distinct, .ty = .boolean, .constant = true, .next = n.next, .name = n.name };
                return;
            }
            var head: u16 = none; var tail: u16 = none;
            while (left != none) {
                const left_next = context.node(left).next;
                const right_next = context.node(right).next;
                // Row fields require an operator even when one literal is
                // NULL: unlike a scalar IS DISTINCT FROM NULL shortcut.
                if (context.node(left).ty == .json or context.node(right).ty == .json) return error.UndefinedFunction;
                const pair = try context.pool.add(.{ .kind = .binary, .op = n.op, .a = left, .b = right, .ty = .boolean });
                const key = context.node(pair);
                try comparable(context, &key.a, &key.b);
                key.constant = isConstant(context, key.a) and isConstant(context, key.b);
                try context.pool.raise(pair, key.a);
                try context.pool.raise(pair, key.b);
                if (head == none) head = pair else context.node(tail).next = pair;
                tail = pair;
                left = left_next; right = right_next;
            }
            n.* = .{ .kind = .row_compare, .op = n.op, .b = head, .ty = .boolean, .constant = listConstant(context, head), .next = n.next, .name = n.name, .depth = 1 };
            var item = head;
            while (item != none) : (item = context.node(item).next) try context.pool.raise(id, item);
        }

        fn foldableScalar(context: *const Context, id: u16) bool {
            if (id == none) return true;
            const n = context.node(id);
            if (!n.constant) return false;
            switch (n.kind) {
                .function => if (!ast.canRepeatFunction(n.func) and n.func != .jsonb_typeof and n.func != .jsonb_array_length) return false,
                .row_constructor, .row_compare, .row_in => return false,
                else => {},
            }
            if (!foldableScalar(context, n.a) or !foldableScalar(context, n.c)) return false;
            if (!listOwner(n.kind)) return foldableScalar(context, n.b);
            var item = n.b;
            while (item != none) : (item = context.node(item).next) if (!foldableScalar(context, item)) return false;
            return true;
        }

        // A strict NULL record comparison discards runtime evaluation, but
        // PostgreSQL still simplifies immutable constant expressions first.
        // Never evaluate clocks, sequences, aggregates or subqueries here.
        fn validateDiscardedConstants(context: *const Context, id: u16) Error!void {
            if (id == none) return;
            const n = context.node(id);
            const eval_context: E.Context = .{ .source = context.source, .pool = context.pool, .session = context.session };
            if (foldableScalar(context, id)) { _ = try E.eval(&eval_context, id); return; }
            if (n.kind == .case_expr) {
                try validateDiscardedConstants(context, n.a);
                const known_operand = n.a == none or foldableScalar(context, n.a);
                const operand = if (n.a != none and known_operand) try E.eval(&eval_context, n.a) else V.Cell.null_value;
                var arm = n.b;
                while (arm != none) : (arm = context.node(arm).next) {
                    const entry = context.node(arm);
                    try validateDiscardedConstants(context, entry.a);
                    if (known_operand and foldableScalar(context, entry.a)) {
                        const candidate = try E.eval(&eval_context, entry.a);
                        const matches = if (n.a == none) candidate == .boolean and candidate.boolean else E.compareOp(.eq, &operand, &candidate) == true;
                        if (!matches) continue;
                        try validateDiscardedConstants(context, entry.b);
                        return;
                    }
                    try validateDiscardedConstants(context, entry.b);
                }
                return validateDiscardedConstants(context, n.c);
            }
            if (n.kind == .coalesce) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) {
                    try validateDiscardedConstants(context, item);
                    if (foldableScalar(context, item) and (try E.eval(&eval_context, item)) != .null_value) return;
                }
                return;
            }
            try validateDiscardedConstants(context, n.a);
            try validateDiscardedConstants(context, n.c);
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) try validateDiscardedConstants(context, item);
            } else try validateDiscardedConstants(context, n.b);
        }

        fn bindRowIn(context: *const Context, scope: *const Scope, id: u16) Error!void {
            const n = context.node(id);
            const original = n.a;
            try bindRowFields(context, scope, original);
            var item = n.b;
            var head: u16 = none;
            var tail: u16 = none;
            while (item != none) {
                const next = context.node(item).next;
                // Keep the original unresolved literal types until the last
                // candidate: each equality operator resolves independently.
                const left = if (next == none) original else try cloneTree(context, original);
                var comparison: u16 = undefined;
                if (context.node(item).kind == .null_literal) {
                    context.pool.discarded_row_constants = true;
                    // Keep dependencies for grouping/name validation, without
                    // creating a record payload or evaluating the operand.
                    comparison = try context.pool.add(.{ .kind = .row_compare, .op = .eq, .a = left, .ty = .boolean, .constant = isConstant(context, left) });
                } else {
                    if (context.node(item).kind != .row_constructor) return error.UndefinedFunction;
                    comparison = try context.pool.add(.{ .kind = .binary, .op = .eq, .a = left, .b = item });
                    try bindRowCompare(context, scope, comparison);
                }
                if (head == none) head = comparison else context.node(tail).next = comparison;
                tail = comparison;
                item = next;
            }
            n.* = .{ .kind = .row_in, .b = head, .negated = n.negated, .ty = .boolean, .constant = listConstant(context, head), .next = n.next, .name = n.name };
            item = head;
            while (item != none) : (item = context.node(item).next) try context.pool.raise(id, item);
        }

        fn simpleRangeOperand(n: *const ast.Node) bool {
            return switch (n.kind) {
                .column, .null_literal, .bool_literal, .int_literal, .text_literal, .decimal_literal => true,
                .cast => n.date_bound,
                else => false,
            };
        }

        fn rangeComparison(context: *const Context, scope: *const Scope, left: u16, right: u16, op: ast.Op) Error!u16 {
            const a = try cloneTree(context, left);
            const b = try cloneTree(context, right);
            const id = try context.pool.add(.{ .kind = .binary, .op = op, .a = a, .b = b, .ty = .boolean });
            const n = context.node(id);
            const left_row = context.node(a).kind == .row_constructor;
            const right_row = context.node(b).kind == .row_constructor;
            if (left_row or right_row) {
                if ((left_row and context.node(b).kind == .null_literal) or (right_row and context.node(a).kind == .null_literal)) {
                    context.pool.discarded_row_constants = true;
                    const row = if (left_row) a else b;
                    n.* = .{ .kind = .row_compare, .op = op, .a = row, .ty = .boolean, .constant = isConstant(context, row), .depth = n.depth };
                } else try bindRowCompare(context, scope, id);
            } else {
                if (context.node(a).ty == .json or context.node(b).ty == .json) return error.UndefinedFunction;
                try comparable(context, &n.a, &n.b);
                n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                try context.pool.raise(id, n.a);
                try context.pool.raise(id, n.b);
            }
            return id;
        }

        fn rangeBoolean(context: *const Context, kind: ast.NodeKind, a: u16, b: u16) Error!u16 {
            return context.pool.add(.{ .kind = kind, .a = a, .b = b, .ty = .boolean, .constant = isConstant(context, a) and isConstant(context, b) });
        }

        fn bindBetween(context: *const Context, scope: *const Scope, id: u16) Error!void {
            const n = context.node(id);
            for ([_]u16{n.a, n.b, n.c}) |part| {
                if (context.node(part).kind == .row_constructor) try bindRowFields(context, scope, part) else try typeExpr(context, scope, part);
            }
            const a = context.node(n.a); const b = context.node(n.b); const c = context.node(n.c);
            // Keep the existing compact date/integral scan shape where operands
            // are repeatable simple values in the same comparison domain.
            if (!n.symmetric and a.ty != .unknown and a.ty != .json and
                a.kind != .row_constructor and b.kind != .row_constructor and c.kind != .row_constructor and
                simpleRangeOperand(a) and simpleRangeOperand(b) and simpleRangeOperand(c) and
                ((a.ty == b.ty and a.ty == c.ty) or (value.integral(a.ty) and value.integral(b.ty) and value.integral(c.ty)))) {
                n.ty = .boolean;
                n.constant = isConstant(context, n.a) and isConstant(context, n.b) and isConstant(context, n.c);
                return;
            }
            const first = try rangeComparison(context, scope, n.a, n.b, if (n.negated) .lt else .ge);
            const second = try rangeComparison(context, scope, n.a, n.c, if (n.negated) .gt else .le);
            const inner: ast.NodeKind = if (n.negated) .or_op else .and_op;
            var left = first; var right = second; var kind = inner;
            if (n.symmetric) {
                left = try rangeBoolean(context, inner, first, second);
                const third = try rangeComparison(context, scope, n.a, n.c, if (n.negated) .lt else .ge);
                const fourth = try rangeComparison(context, scope, n.a, n.b, if (n.negated) .gt else .le);
                right = try rangeBoolean(context, inner, third, fourth);
                kind = if (n.negated) .and_op else .or_op;
            }
            n.* = .{ .kind = kind, .a = left, .b = right, .ty = .boolean, .constant = isConstant(context, left) and isConstant(context, right), .next = n.next, .name = n.name };
            try context.pool.raise(id, left);
            try context.pool.raise(id, right);
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
                // DEFAULT outside an INSERT VALUES item or SET value (42601).
                .values_row, .default_value => return error.Syntax,
                .row_constructor => return error.UnsupportedStatement,
                // Internal comparison lists have already bound every field.
                .row_compare, .row_in => { n.ty = .boolean; n.constant = isConstant(context, n.a) and listConstant(context, n.b); },
                .function => try typeFunction(context, scope, n),
                .when_arm => unreachable,
                .column => {
                    if (n.star) return error.Syntax;
                    try resolveColumn(context, scope, n);
                },
                // Already typed (a shared subtree typed twice).
                .aggregate => n.constant = false,
                .scalar_subquery, .exists_subquery, .in_subquery => try typeSubquery(context, scope, n),
                .unary => {
                    try typeExpr(context, scope, n.a);
                    const ty = context.node(n.a).ty;
                    if (ty == .unknown) return error.AmbiguousFunction;
                    if (!value.numericCategory(ty) and ty != .interval) return error.UndefinedFunction;
                    n.ty = ty;
                    n.constant = isConstant(context, n.a);
                },
                .binary => {
                    if (context.node(n.a).kind == .row_constructor or context.node(n.b).kind == .row_constructor) return bindRowCompare(context, scope, id);
                    try typeExpr(context, scope, n.a);
                    try typeExpr(context, scope, n.b);
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                    switch (n.op) {
                        .eq, .ne, .lt, .le, .gt, .ge, .is_distinct, .is_not_distinct => {
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
                    if (context.node(n.a).kind == .row_constructor) {
                        if (n.test_kind != .is_null and n.test_kind != .is_not_null) return error.TypeMismatch;
                        try bindRowFields(context, scope, n.a);
                        var item = context.node(n.a).b;
                        while (item != none) : (item = context.node(item).next) {
                            if (context.node(item).ty == .unknown) try coerce(context, item, .text);
                        }
                        n.ty = .boolean;
                        n.constant = listConstant(context, context.node(n.a).b);
                        return;
                    }
                    try typeExpr(context, scope, n.a);
                    if (n.test_kind == .is_null or n.test_kind == .is_not_null) {
                        if (context.node(n.a).ty == .unknown) try coerce(context, n.a, .text);
                    } else try booleanArgument(context, n.a);
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a);
                },
                .between => {
                    try bindBetween(context, scope, id);
                },
                .in_list => {
                    if (context.node(n.a).kind == .row_constructor) return bindRowIn(context, scope, id);
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
                    // name LIKE text (namelike) shares text's representation.
                    const left_ty = context.node(n.a).ty;
                    const right_ty = context.node(n.b).ty;
                    if ((left_ty != .text and left_ty != .name) or (right_ty != .text and right_ty != .name)) return error.UndefinedFunction;
                    if (n.c != none) {
                        try typeExpr(context, scope, n.c);
                        try coerce(context, n.c, .text);
                        const escape_ty = context.node(n.c).ty;
                        if (escape_ty != .text and escape_ty != .name) return error.UndefinedFunction;
                    }
                    n.ty = .boolean;
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b) and isConstant(context, n.c);
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
                    const right = context.node(n.b).ty;
                    // PostgreSQL has direct cross-type equality operators for
                    // these families. Our comparison casts must not change the
                    // returned first operand's type or representation.
                    const preserve = ((original == .float4 or original == .float8) and
                        (right == .float4 or right == .float8)) or
                        (value.datetime(original) and value.datetime(right)) or
                        (value.stringType(original) and value.stringType(right));
                    try comparable(context, &n.a, &n.b);
                    n.ty = if (preserve) original else context.node(n.a).ty;
                    n.constant = isConstant(context, n.a) and isConstant(context, n.b);
                },
                .cast => {
                    n.date_bound=false;
                    if (n.typmod == ast.regclass_typmod or n.typmod == ast.regtype_typmod) return regCast(context, scope, n);
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
                    const reg = context.node(n.a).reg;
                    if (target == .text and reg != .none) {
                        // regclass/regtype output: the relation or type name.
                        n.kind = .function;
                        n.func = if (reg == .regclass) .regclass_out else .regtype_out;
                        n.b = n.a;
                        n.a = none;
                        n.ty = .text;
                        n.constant = false;
                        return;
                    }
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
                    const bound=context.node(n.a);
                    if(target==.date and bound.kind==.text_literal and bound.ty==.date and bound.date_bound) {
                        n.date_bound=true;n.integer=bound.integer;
                    }
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
                .test_op, .between, .in_list, .like, .row_compare, .row_in => true,
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
                    switch (n.func) {
                        // Converted casts: `x::regclass::text` is named like a cast.
                        .regclass_out, .regtype_out => {
                            const inner = figure(context, n.b, buffer);
                            if (inner.strength > 1) break :blk inner;
                            break :blk .{ .name = "text", .strength = 1 };
                        },
                        .regclass_in, .regtype_in => {
                            const inner = figure(context, n.b, buffer);
                            if (inner.strength > 1) break :blk inner;
                            break :blk .{ .name = if (n.func == .regclass_in) "regclass" else "regtype", .strength = 1 };
                        },
                        else => {},
                    }
                    buffer.* = toName(context, n.name);
                    break :blk .{ .name = buffer.slice(), .strength = 2 };
                },
                // A merged FULL JOIN USING column keeps its column name.
                .coalesce => if (n.name.len != 0) blk: {
                    buffer.* = toName(context, n.name);
                    break :blk .{ .name = buffer.slice(), .strength = 2 };
                } else .{ .name = "coalesce", .strength = 2 },
                .aggregate => blk: {
                    buffer.* = toName(context, n.name);
                    break :blk .{ .name = buffer.slice(), .strength = 2 };
                },
                // PostgreSQL names a scalar subquery after its only column.
                .scalar_subquery => blk: {
                    buffer.* = context.plans.?.items[@intCast(n.integer)].names[0];
                    break :blk .{ .name = buffer.slice(), .strength = 2 };
                },
                .exists_subquery => .{ .name = "exists", .strength = 2 },
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

        /// The system view a FROM name denotes (pg_catalog first, as
        /// PostgreSQL's implicit search_path), if any.
        fn viewOf(context: *const Context, schema: ?ast.Ident, name: ast.Ident) ?catalog.View {
            const wanted = toName(context, name);
            if (schema) |qualifier| {
                const schema_name = toName(context, qualifier);
                return catalog.findView(schema_name.slice(), wanted.slice());
            }
            return catalog.findView(null, wanted.slice());
        }

        /// A user table, optionally qualified with `public`.
        fn resolveQualified(context: *const Context, schema: ?ast.Ident, name: ast.Ident) Error!usize {
            if (schema) |qualifier| {
                const schema_name = toName(context, qualifier);
                if (!types.same(schema_name.slice(), "public")) return error.TableNotFound;
            }
            return resolveTable(context, name);
        }

        fn scopeFor(context: *const Context, from: ?Ast.TableRef) Error!Scope {
            const reference = from orelse return .{};
            const index = try resolveQualified(context, reference.schema, reference.name);
            var out = tableScope(context, index);
            if (reference.alias) |alias| out.rels[0].name = toName(context, alias);
            return out;
        }

        fn tableScope(context: *const Context, index: usize) Scope {
            var out: Scope = .{ .rel_count = 1 };
            out.rels[0] = .{ .table = index, .name = context.tables[index].name };
            return out;
        }

        fn singleTable(scope: *const Scope) ?usize {
            return if (scope.rel_count == 0) null else scope.rels[0].table;
        }

        fn outputTypmod(context: *const Context, id: u16) i32 {
            const n = context.node(id);
            return switch (n.kind) {
                .column, .cast => n.typmod,
                else => -1,
            };
        }

        /// RETURNING over the target table's row (`*`, `t.*`, expressions);
        /// `alias` (INSERT ... AS alias) replaces the table name.
        fn bindReturning(context: *const Context, index: usize, list: *const Ast.Returning, table_alias: ?ast.Ident) Error!Returning {
            var out: Returning = .{};
            if (list.count == 0) return out;
            var scope = tableScope(context, index);
            if (table_alias) |name| scope.rels[0].name = toName(context, name);
            const entry = &context.tables[index];
            for (list.targets[0..list.count]) |*target| {
                if (target.star) {
                    if (target.expr != none) {
                        const qualifier = toName(context, context.node(target.expr).qualifier);
                        if (!types.same(qualifier.slice(), scope.rels[0].name.slice())) return error.TableNotFound;
                    }
                    for (entry.columns[0..entry.column_count], 0..) |*column, position| {
                        if (out.count == config.columns) return error.ColumnCapacity;
                        out.targets[out.count] = try context.pool.add(.{ .kind = .column, .column = @intCast(position), .ty = types.typeOfData(column.data_type), .typmod = column.typmod });
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
            return out;
        }

        fn bindValues(context: *const Context, entry: *const S.Table, out: *Insert, overriding: ast.Overriding) Error!void {
            const empty: Scope = .{};
            var row = out.rows;
            while (row != none) : (row = context.node(row).next) {
                if (context.node(row).integer != out.count) return error.Syntax;
                var previous: u16 = none;
                var item = context.node(row).b;
                var position: usize = 0;
                while (item != none) : (position += 1) {
                    const next = context.node(item).next;
                    var converted = item;
                    if (context.node(item).kind != .default_value and !try explicitValue(&entry.columns[out.mapping[position]], overriding)) {
                        context.node(item).kind = .default_value;
                    }
                    if (context.node(item).kind != .default_value) {
                        try typeExpr(context, &empty, item);
                        converted = try assignment(context, item, &entry.columns[out.mapping[position]]);
                    }
                    if (converted != item) {
                        context.node(converted).next = next;
                        context.node(item).next = none;
                        if (previous == none) context.node(row).b = converted else context.node(previous).next = converted;
                    }
                    previous = converted;
                    item = next;
                }
            }
        }

        /// INSERT ... SELECT: untyped output literals take the target column
        /// type (PostgreSQL does not resolve unknowns in an INSERT's SELECT).
        fn bindInsertQuery(context: *const Context, entry: *const S.Table, query_index: u16, out: *Insert, overriding: ast.Overriding) Error!void {
            const plans = context.plans orelse return error.UnsupportedStatement;
            plans.reset();
            const root = try bindPlan(context, query_index, null, null, true);
            const p = &plans.items[root];
            if (p.count != out.count) return error.Syntax;
            for (0..p.count) |position| if (p.tys[position] == .unknown) {
                try castColumn(context, root, position, types.typeOfData(entry.columns[out.mapping[position]].data_type));
            };
            try resolveUnknown(context, root);
            for (0..p.count) |position| {
                const column = out.mapping[position];
                if (!try explicitValue(&entry.columns[column], overriding)) continue;
                const id = try context.pool.add(.{ .kind = .column, .relation = 1, .column = @intCast(position), .ty = p.tys[position], .typmod = p.typmods[position] });
                out.values[column] = try assignment(context, id, &entry.columns[column]);
            }
            out.plan = root;
        }

        fn bindSelect(context: *const Context, select: *const Ast.Select) Error!Select {
            const scope = try scopeFor(context, select.from);
            var out: Select = .{ .table = singleTable(&scope), .targets = undefined, .names = undefined, .types = undefined, .count = 0, .where = none, .key = none, .order = undefined, .order_count = 0, .limit = select.limit, .lock = select.lock };
            for (select.targets[0..select.count]) |*target| {
                if (target.star) {
                    const entry = &context.tables[out.table.?];
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
            if (out.table) |index| out.key = primaryKey(context, &context.tables[index], out.where);
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
            if (select.negative_limit) return error.InvalidRowCountInLimit;
            return out;
        }

        // ---- general queries (design §4.9) ---------------------------------

        fn plansOf(context: *const Context) *Plans {
            return context.plans.?;
        }

        fn relationWidth(context: *const Context, rel: *const Relation) usize {
            if (rel.view) |view| return catalog.viewColumns(view).len;
            if (rel.table) |index| return context.tables[index].column_count;
            return plansOf(context).items[rel.plan].count;
        }

        fn relationColumnName(context: *const Context, rel: *const Relation, column: usize) []const u8 {
            if (rel.view) |view| return catalog.viewColumns(view)[column].name;
            if (rel.table) |index| return context.tables[index].columns[column].name.slice();
            return plansOf(context).items[rel.plan].names[column].slice();
        }

        fn relationColumnType(context: *const Context, rel: *const Relation, column: usize) ast.Type {
            if (rel.view) |view| return catalog.viewColumns(view)[column].ty;
            if (rel.table) |index| return types.typeOfData(context.tables[index].columns[column].data_type);
            return plansOf(context).items[rel.plan].tys[column];
        }

        fn relationColumnTypmod(context: *const Context, rel: *const Relation, column: usize) i32 {
            if (rel.view != null) return -1;
            if (rel.table) |index| return context.tables[index].columns[column].typmod;
            return plansOf(context).items[rel.plan].typmods[column];
        }

        fn findColumn(context: *const Context, rel: *const Relation, wanted: []const u8) ?usize {
            for (0..relationWidth(context, rel)) |column| {
                if (types.same(relationColumnName(context, rel, column), wanted)) return column;
            }
            return null;
        }

        /// Marks every plan between `scope` and the scope `level` blocks up
        /// as correlated (re-executed per outer row).
        fn markCorrelated(context: *const Context, scope: *const Scope, level: u8) void {
            var current: ?*const Scope = scope;
            var remaining = level;
            while (remaining != 0) : (remaining -= 1) {
                const s = current orelse return;
                if (s.plan != none) plansOf(context).items[s.plan].correlated = true;
                current = s.parent;
            }
        }

        fn bindColumn(context: *const Context, scope: *const Scope, n: *ast.Node, owner: *const Scope, level: u8, relation: usize, column: usize) void {
            const rel = &owner.rels[relation];
            n.kind = .column;
            n.relation = @intCast(relation);
            n.column = @intCast(column);
            n.level = level;
            n.ty = relationColumnType(context, rel, column);
            n.typmod = relationColumnTypmod(context, rel, column);
            n.constant = false;
            markCorrelated(context, scope, level);
        }

        fn columnNode(context: *const Context, scope: *const Scope, relation: usize, column: usize) Error!u16 {
            const id = try context.pool.add(.{ .kind = .column });
            bindColumn(context, scope, context.node(id), scope, 0, relation, column);
            return id;
        }

        /// A merged USING column: the left column (INNER/LEFT), the right
        /// one (RIGHT) or COALESCE(left, right) (FULL).
        fn bindUsing(context: *const Context, scope: *const Scope, n: *ast.Node, owner: *const Scope, level: u8, entry: *const Using) Error!void {
            switch (entry.join) {
                .right => bindColumn(context, scope, n, owner, level, entry.right, entry.right_column),
                .full => {
                    const next = n.next;
                    const name = n.name;
                    const left = try context.pool.add(.{ .kind = .column });
                    bindColumn(context, scope, context.node(left), owner, level, entry.left, entry.left_column);
                    const right = try context.pool.add(.{ .kind = .column });
                    bindColumn(context, scope, context.node(right), owner, level, entry.right, entry.right_column);
                    const target = value.common(context.node(left).ty, context.node(right).ty) orelse return error.TypeMismatch;
                    context.node(left).next = right;
                    const head = try convertList(context, left, target);
                    n.* = .{ .kind = .coalesce, .b = head, .ty = target, .next = next, .name = name, .depth = 3 };
                },
                else => bindColumn(context, scope, n, owner, level, entry.left, entry.left_column),
            }
        }

        /// Resolves a column through the scope chain: qualified names match
        /// a FROM item's alias (else table/CTE name), unqualified names
        /// must be unique among the block's items (42702).
        fn resolveColumn(context: *const Context, scope: *const Scope, n: *ast.Node) Error!void {
            const wanted = toName(context, n.name);
            const qualifier: ?V.Name = if (n.qualifier.len != 0) toName(context, n.qualifier) else null;
            var current: ?*const Scope = scope;
            var level: u8 = 0;
            while (current) |s| {
                defer {
                    current = s.parent;
                    level += 1;
                }
                if (qualifier) |q| {
                    for (s.rels[0..s.rel_count], 0..) |*rel, index| {
                        if (!types.same(rel.name.slice(), q.slice())) continue;
                        const column = findColumn(context, rel, wanted.slice()) orelse return error.ColumnNotFound;
                        return bindColumn(context, scope, n, s, level, index, column);
                    }
                    continue;
                }
                var position = s.using_count;
                while (position != 0) {
                    position -= 1;
                    const entry = &s.using[position];
                    const name = toName(context, entry.ident);
                    if (types.same(name.slice(), wanted.slice())) return bindUsing(context, scope, n, s, level, entry);
                }
                var found: ?[2]usize = null;
                for (s.rels[0..s.rel_count], 0..) |*rel, index| {
                    const column = findColumn(context, rel, wanted.slice()) orelse continue;
                    if (found != null) return error.AmbiguousColumn;
                    found = .{ index, column };
                }
                if (found) |hit| return bindColumn(context, scope, n, s, level, hit[0], hit[1]);
            }
            return if (qualifier != null) error.TableNotFound else error.ColumnNotFound;
        }

        fn typeSubquery(context: *const Context, scope: *const Scope, n: *ast.Node) Error!void {
            const plans = context.plans orelse return error.UnsupportedStatement;
            if (n.kind == .in_subquery) try typeExpr(context, scope, n.a);
            const plan_id = try bindPlan(context, @intCast(n.integer), scope, scope.ctes, false);
            n.integer = plan_id;
            const plan = &plans.items[plan_id];
            if (n.kind != .exists_subquery and plan.count != 1) return error.Syntax;
            switch (n.kind) {
                .scalar_subquery => {
                    n.ty = plan.tys[0];
                    n.typmod = plan.typmods[0];
                },
                .exists_subquery => n.ty = .boolean,
                .in_subquery => {
                    const left = context.node(n.a).ty;
                    const right = plan.tys[0];
                    if (left == .json or right == .json) return error.UndefinedFunction;
                    if (left == .unknown) {
                        try coerce(context, n.a, right);
                    } else if (left != right and !(value.integral(left) and value.integral(right))) {
                        const target = value.comparisonType(left, right) orelse return error.UndefinedFunction;
                        n.a = try convert(context, n.a, target, -1, .implicit);
                        try castColumn(context, plan_id, 0, target);
                    }
                    n.ty = .boolean;
                },
                else => unreachable,
            }
            n.constant = false;
        }

        fn lookupCte(context: *const Context, env: ?*const CteEnv, ident: ast.Ident) ?u8 {
            const wanted = toName(context, ident);
            const plans = plansOf(context);
            var current = env;
            while (current) |e| : (current = e.parent) {
                var index = e.count;
                while (index != 0) {
                    index -= 1;
                    if (types.same(plans.ctes[e.ids[index]].name.slice(), wanted.slice())) return e.ids[index];
                }
            }
            return null;
        }

        /// Casts output column `column` of a plan (both branches of a set
        /// operation) to `target`.
        fn castColumn(context: *const Context, plan_id: u16, column: usize, target: ast.Type) Error!void {
            const p = &plansOf(context).items[plan_id];
            if (p.tys[column] == target) return;
            if (p.set_op != .none) {
                try castColumn(context, p.left, column, target);
                try castColumn(context, p.right, column, target);
            } else {
                const id = p.targets[column];
                const ty = context.node(id).ty;
                if (ty == .unknown) {
                    try coerce(context, id, target);
                } else if (!(value.integral(ty) and value.integral(target))) {
                    p.targets[column] = try convert(context, id, target, -1, .implicit);
                }
            }
            p.tys[column] = target;
            p.typmods[column] = -1;
        }

        /// Untyped output columns (literals in set-operation branches) become text.
        fn resolveUnknown(context: *const Context, plan_id: u16) Error!void {
            const p = &plansOf(context).items[plan_id];
            for (0..p.count) |column| if (p.tys[column] == .unknown) try castColumn(context, plan_id, column, .text);
        }

        fn bindPlan(context: *const Context, query_index: u16, parent: ?*const Scope, env: ?*const CteEnv, branch: bool) Error!u16 {
            const q = &context.pool.queries[query_index];
            if (q.lock.strength != .none) return error.UnsupportedStatement;
            var local: CteEnv = .{ .parent = env };
            var visible = env;
            if (q.cte_count != 0) {
                for (q.ctes[0..q.cte_count]) |*cte| try bindCte(context, q, cte, parent, &local);
                visible = &local;
            }
            if (q.set_op != .none) {
                const id = try bindSetOp(context, q, parent, visible);
                if (!branch) try resolveUnknown(context, id);
                return id;
            }
            return bindCore(context, q, parent, visible, branch);
        }

        fn applyAliases(context: *const Context, plan_id: u16, cte: *const Ast.Cte) Error!void {
            if (cte.column_count == 0) return;
            const p = &plansOf(context).items[plan_id];
            if (cte.column_count > p.count) return error.InvalidColumnReference;
            for (cte.columns[0..cte.column_count], 0..) |ident, index| p.names[index] = toName(context, ident);
        }

        /// Binds one WITH entry. A WITH RECURSIVE body of the form
        /// `non-recursive UNION [ALL] recursive` that references itself is
        /// iterated to a fixpoint by the executor.
        fn bindCte(context: *const Context, q: *const Ast.Select, cte: *const Ast.Cte, parent: ?*const Scope, local: *CteEnv) Error!void {
            const plans = plansOf(context);
            if (plans.cte_len == config.ctes) return error.StatementTooComplex;
            const name = toName(context, cte.name);
            for (local.ids[0..local.count]) |other| if (types.same(plans.ctes[other].name.slice(), name.slice())) return error.Syntax;
            const id: u8 = @intCast(plans.cte_len);
            plans.cte_len += 1;
            plans.ctes[id] = .{ .name = name };
            const body = &context.pool.queries[cte.query];
            if (q.recursive and body.set_op == .@"union" and body.cte_count == 0) {
                if (body.order_count != 0 or body.limit != 0xffffffffffffffff or body.offset != 0) return error.UnsupportedStatement;
                const plan_id = try plans.add();
                const left = try bindPlan(context, body.left, parent, local, true);
                try resolveUnknown(context, left);
                const l = &plans.items[left];
                const p = &plans.items[plan_id];
                p.set_op = .@"union";
                p.set_all = body.set_all;
                p.left = left;
                p.count = l.count;
                p.width = l.count;
                for (0..l.count) |column| {
                    p.names[column] = l.names[column];
                    p.tys[column] = l.tys[column];
                    p.typmods[column] = l.typmods[column];
                }
                try applyAliases(context, plan_id, cte);
                plans.ctes[id].plan = plan_id;
                plans.ctes[id].recursive = true;
                var with_self = local.*;
                with_self.ids[with_self.count] = id;
                with_self.count += 1;
                const right = try bindPlan(context, body.right, parent, &with_self, true);
                const r = &plans.items[right];
                if (r.count != p.count) return error.Syntax;
                p.right = right;
                for (0..p.count) |column| {
                    const rt = r.tys[column];
                    const lt = p.tys[column];
                    if (rt == lt or (value.integral(rt) and value.integral(lt))) continue;
                    if (rt != .unknown and !value.castable(rt, lt, .implicit)) return error.TypeMismatch;
                    try castColumn(context, right, column, lt);
                }
                p.correlated = l.correlated or r.correlated;
                if (!plans.ctes[id].referenced) plans.ctes[id].recursive = false;
            } else {
                const plan_id = try bindPlan(context, cte.query, parent, local, false);
                try applyAliases(context, plan_id, cte);
                plans.ctes[id].plan = plan_id;
            }
            local.ids[local.count] = id;
            local.count += 1;
        }

        fn nullsFirst(key: *const Ast.OrderKey) bool {
            return key.nulls_first orelse (config.nulls_first_ascending != key.descending);
        }

        fn checkCounts(q: *const Ast.Select, p: *Plan) Error!void {
            p.limit = q.limit;
            p.offset = q.offset;
            if (q.negative_offset) return error.InvalidRowCountInResultOffset;
            if (q.negative_limit) return error.InvalidRowCountInLimit;
        }

        fn sortableType(ty: ast.Type) Error!void {
            if (ty == .json) return error.UndefinedFunction;
        }

        fn bindSetOp(context: *const Context, q: *const Ast.Select, parent: ?*const Scope, env: ?*const CteEnv) Error!u16 {
            const plans = plansOf(context);
            const id = try plans.add();
            const left = try bindPlan(context, q.left, parent, env, true);
            const right = try bindPlan(context, q.right, parent, env, true);
            const l = &plans.items[left];
            const r = &plans.items[right];
            if (l.count != r.count) return error.Syntax;
            const p = &plans.items[id];
            p.set_op = q.set_op;
            p.set_all = q.set_all;
            p.left = left;
            p.right = right;
            p.count = l.count;
            p.width = l.count;
            p.correlated = l.correlated or r.correlated;
            for (0..l.count) |column| {
                const lt = l.tys[column];
                const rt = r.tys[column];
                const target: ast.Type = if (lt == .unknown) rt else if (rt == .unknown) lt else if (lt == rt) lt else value.common(lt, rt) orelse return error.TypeMismatch;
                const typmod: i32 = if (l.typmods[column] == r.typmods[column]) l.typmods[column] else -1;
                if (target != .unknown) {
                    try castColumn(context, left, column, target);
                    try castColumn(context, right, column, target);
                }
                p.names[column] = l.names[column];
                p.tys[column] = target;
                p.typmods[column] = if (target == lt and target == rt) typmod else -1;
                if (!q.set_all) try sortableType(target);
            }
            // ORDER BY over a set operation names result columns only.
            for (q.order[0..q.order_count]) |*key| {
                const n = context.node(key.expr);
                var column: ?usize = null;
                if (n.kind == .int_literal) {
                    if (n.integer < 1 or n.integer > p.count) return error.InvalidColumnReference;
                    column = @intCast(n.integer - 1);
                } else if (n.kind == .column and n.qualifier.len == 0 and !n.star) {
                    const wanted = toName(context, n.name);
                    for (p.names[0..p.count], 0..) |*name, index| if (types.same(name.slice(), wanted.slice())) {
                        column = index;
                        break;
                    };
                }
                const index = column orelse return error.UnsupportedStatement;
                try sortableType(p.tys[index]);
                p.order[p.order_count] = .{ .column = @intCast(index), .descending = key.descending, .nulls_first = nullsFirst(key) };
                p.order_count += 1;
            }
            try checkCounts(q, p);
            return id;
        }

        const OrderRef = union(enum) { column: u16, expr: u16 };

        /// ORDER BY / DISTINCT ON item: a position, an output column name,
        /// or an input expression.
        fn orderRef(context: *const Context, scope: *const Scope, p: *const Plan, id: u16) Error!OrderRef {
            const n = context.node(id);
            if (n.kind == .int_literal) {
                if (n.integer < 1 or n.integer > p.count) return error.InvalidColumnReference;
                return .{ .column = @intCast(n.integer - 1) };
            }
            if (n.kind == .column and n.qualifier.len == 0 and !n.star) {
                const wanted = toName(context, n.name);
                for (p.names[0..p.count], 0..) |*name, index| if (types.same(name.slice(), wanted.slice())) return .{ .column = @intCast(index) };
            }
            try valueExpr(context, scope, id);
            return .{ .expr = id };
        }

        /// The materialized column of an order item; input expressions equal
        /// to a target reuse it, others become resjunk columns (forbidden
        /// for SELECT DISTINCT: 42P10).
        fn refColumn(context: *const Context, p: *Plan, ref: OrderRef, forbid_resjunk: bool) Error!u16 {
            switch (ref) {
                .column => |column| return column,
                .expr => |id| {
                    for (0..p.width) |index| if (sameExpr(context, p.targets[index], id)) {
                        if (forbid_resjunk and index >= p.count) return error.InvalidColumnReference;
                        return @intCast(index);
                    };
                    if (forbid_resjunk) return error.InvalidColumnReference;
                    if (p.width == 2 * config.columns) return error.StatementTooComplex;
                    p.targets[p.width] = id;
                    p.width += 1;
                    return @intCast(p.width - 1);
                },
            }
        }

        fn planColumnType(p: *const Plan, context: *const Context, column: u16) ast.Type {
            return if (column < p.count) p.tys[column] else context.node(p.targets[column]).ty;
        }

        fn inputHas(context: *const Context, scope: *const Scope, wanted: []const u8) bool {
            for (scope.using[0..scope.using_count]) |*entry| {
                const name = toName(context, entry.ident);
                if (types.same(name.slice(), wanted)) return true;
            }
            for (scope.rels[0..scope.rel_count]) |*rel| if (findColumn(context, rel, wanted) != null) return true;
            return false;
        }

        fn listOwner(kind: ast.NodeKind) bool {
            return switch (kind) {
                .in_list, .case_expr, .coalesce, .function, .row_constructor, .row_compare, .row_in => true,
                else => false,
            };
        }

        fn cloneTree(context: *const Context, id: u16) Error!u16 {
            if (id == none) return none;
            var copy = context.node(id).*;
            copy.a = try cloneTree(context, copy.a);
            copy.c = try cloneTree(context, copy.c);
            if (listOwner(copy.kind)) {
                var head: u16 = none;
                var last: u16 = none;
                var item = copy.b;
                while (item != none) : (item = context.node(item).next) {
                    const cloned = try cloneTree(context, item);
                    if (head == none) head = cloned else context.node(last).next = cloned;
                    last = cloned;
                }
                copy.b = head;
            } else copy.b = try cloneTree(context, copy.b);
            copy.next = none;
            return context.pool.add(copy);
        }

        /// GROUP BY item: a target position, an input expression, or (when
        /// no input column has the name) an output alias.
        fn groupKey(context: *const Context, scope: *const Scope, q: *const Ast.Select, id: u16) Error!u16 {
            const n = context.node(id);
            var key = id;
            if (n.kind == .int_literal) {
                if (n.integer < 1 or n.integer > q.count) return error.InvalidColumnReference;
                const target = &q.targets[@intCast(n.integer - 1)];
                for (q.targets[0..@intCast(n.integer)]) |*t| if (t.star) return error.UnsupportedStatement;
                key = try cloneTree(context, target.expr);
            } else if (n.kind == .column and n.qualifier.len == 0 and !n.star) {
                const wanted = toName(context, n.name);
                if (!inputHas(context, scope, wanted.slice())) {
                    for (q.targets[0..q.count]) |*target| {
                        const alias = target.alias orelse continue;
                        const name = toName(context, alias);
                        if (types.same(name.slice(), wanted.slice())) {
                            key = try cloneTree(context, target.expr);
                            break;
                        }
                    }
                }
            }
            var inner = scope.*;
            inner.aggregates = false;
            inner.saw_aggregate = null;
            try valueExpr(context, &inner, key);
            try sortableType(context.node(key).ty);
            return key;
        }

        /// Structural equality of bound expressions (GROUP BY matching,
        /// ORDER BY reuse, aggregate deduplication).
        fn sameExpr(context: *const Context, a: u16, b: u16) bool {
            if (a == b) return true;
            if (a == none or b == none) return false;
            const x = context.node(a);
            const y = context.node(b);
            if (x.kind != y.kind or x.ty != y.ty or x.window!=none or y.window!=none) return false;
            switch (x.kind) {
                .column => return x.relation == y.relation and x.column == y.column and x.level == y.level,
                .int_literal => return x.integer == y.integer,
                .bool_literal => return x.boolean == y.boolean,
                .null_literal => return true,
                .param => return x.integer == y.integer,
                .text_literal => {
                    const left = E.literalText(context.source, x.text);
                    const right = E.literalText(context.source, y.text);
                    return types.same(left.slice(), right.slice());
                },
                .decimal_literal => return types.same(x.name.span.slice(context.source), y.name.span.slice(context.source)),
                .scalar_subquery, .exists_subquery, .in_subquery => return false,
                else => {},
            }
            if (x.op != y.op or x.test_kind != y.test_kind or x.negated != y.negated or x.insensitive != y.insensitive or
                x.cast_type != y.cast_type or x.typmod != y.typmod or x.func != y.func or x.agg != y.agg or x.distinct != y.distinct) return false;
            if (!sameExpr(context, x.a, y.a) or !sameExpr(context, x.c, y.c)) return false;
            if (!listOwner(x.kind)) return sameExpr(context, x.b, y.b);
            var left = x.b;
            var right = y.b;
            while (left != none and right != none) {
                if (!sameExpr(context, left, right)) return false;
                left = context.node(left).next;
                right = context.node(right).next;
            }
            return left == none and right == none;
        }

        fn registerAgg(context: *const Context, p: *Plan, id: u16) Error!usize {
            const n = context.node(id);
            for (p.aggs[0..p.agg_count], 0..) |*agg, index| {
                if (agg.kind == n.agg and agg.distinct == n.distinct and sameExpr(context, agg.arg, n.a) and sameExpr(context, agg.filter, n.c)) return index;
            }
            if (p.agg_count == config.columns) return error.StatementTooComplex;
            p.aggs[p.agg_count] = .{ .kind = n.agg, .arg = n.a, .filter = n.c, .distinct = n.distinct, .arg_ty = if (n.a == none) .unknown else context.node(n.a).ty, .ty = n.ty };
            p.agg_count += 1;
            return p.agg_count - 1;
        }

        fn groupColumn(n: *ast.Node, column: usize, typmod: i32) void {
            const next = n.next;
            const ty = n.ty;
            const name = n.name;
            n.* = .{ .kind = .column, .relation = group_relation, .column = @intCast(column), .ty = ty, .typmod = typmod, .next = next, .name = name };
        }

        /// Rewrites a post-grouping expression: GROUP BY keys and aggregate
        /// calls become grouped-row columns; any other column of this block
        /// is a GroupingError (42803).
        fn validateDiscardedGroup(context: *const Context, p: *const Plan, id: u16) Error!void {
            if (id == none) return;
            for (p.keys[0..p.key_count]) |key| if (sameExpr(context, id, key)) return;
            const n = context.node(id);
            switch (n.kind) {
                // Binding already validated aggregate arguments and nesting.
                // An aggregate eliminated by strict NULL must not execute.
                .aggregate, .scalar_subquery, .exists_subquery => return,
                .column => if (n.level == 0) return error.GroupingError else return,
                else => {},
            }
            try validateDiscardedGroup(context, p, n.a);
            try validateDiscardedGroup(context, p, n.c);
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) try validateDiscardedGroup(context, p, item);
            } else try validateDiscardedGroup(context, p, n.b);
        }

        fn groupify(context: *const Context, p: *Plan, id: u16) Error!void {
            if (id == none) return;
            const n = context.node(id);
            if(n.kind==.function and n.func==.grouping) {
                var item=n.b;
                while(item!=none):(item=context.node(item).next) {
                    var found:?usize=null;
                    for(p.keys[0..p.key_count],0..) |key,index| if(sameExpr(context,item,key)){found=index;break;};
                    const index=found orelse return error.GroupingError;
                    const arg=context.node(item);const next=arg.next;
                    arg.*=.{.kind=.int_literal,.integer=@intCast(index),.ty=.int4,.constant=true,.next=next};
                }
                n.integer=@intCast(p.key_count);return;
            }
            if(n.window!=none) {
                const spec=&context.pool.windows[n.window];
                for(spec.partition[0..spec.partition_count]) |item| try groupify(context,p,item);
                for(spec.order[0..spec.order_count]) |key| try groupify(context,p,key.expr);
            }
            for (p.keys[0..p.key_count], 0..) |key, index| {
                if (sameExpr(context, id, key)) return groupColumn(n, index, context.node(key).typmod);
            }
            switch (n.kind) {
                .row_compare => if (n.a != none) return validateDiscardedGroup(context, p, n.a),
                .aggregate => {
                    const index = try registerAgg(context, p, id);
                    return groupColumn(n, p.key_count + index, -1);
                },
                .column => if (n.level == 0) return error.GroupingError else return,
                .scalar_subquery, .exists_subquery => return,
                .in_subquery => return groupify(context, p, n.a),
                else => {},
            }
            try groupify(context, p, n.a);
            try groupify(context, p, n.c);
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) try groupify(context, p, item);
            } else try groupify(context, p, n.b);
        }

        fn expandStar(context: *const Context, scope: *const Scope, p: *Plan, target: *const Ast.Target) Error!void {
            var only: ?usize = null;
            if (target.expr != none) {
                const qualifier = toName(context, context.node(target.expr).qualifier);
                for (scope.rels[0..scope.rel_count], 0..) |*rel, index| if (types.same(rel.name.slice(), qualifier.slice())) {
                    only = index;
                    break;
                };
                if (only == null) return error.TableNotFound;
            } else {
                if (scope.rel_count == 0) return error.Syntax;
                for (scope.using[0..scope.using_count]) |*entry| {
                    const id = try context.pool.add(.{ .kind = .column, .name = entry.ident });
                    try typeExpr(context, scope, id);
                    try addTarget(context, p, id, toName(context, entry.ident));
                }
            }
            for (scope.rels[0..scope.rel_count], 0..) |*rel, index| {
                if (only) |wanted| if (wanted != index) continue;
                columns: for (0..relationWidth(context, rel)) |column| {
                    if (only == null) for (scope.using[0..scope.using_count]) |*entry| {
                        if ((entry.left == index and entry.left_column == column) or (entry.right == index and entry.right_column == column)) continue :columns;
                    };
                    const id = try columnNode(context, scope, index, column);
                    var name: V.Name = .{};
                    const raw = relationColumnName(context, rel, column);
                    name.len = raw.len;
                    @memcpy(name.bytes[0..raw.len], raw);
                    try addTarget(context, p, id, name);
                }
            }
        }

        fn addTarget(context: *const Context, p: *Plan, id: u16, name: V.Name) Error!void {
            if (p.count == config.columns) return error.ColumnCapacity;
            p.targets[p.count] = id;
            p.names[p.count] = name;
            p.tys[p.count] = context.node(id).ty;
            p.typmods[p.count] = outputTypmod(context, id);
            p.count += 1;
        }

        /// JOIN ... USING (columns): records merged columns and returns the
        /// equality condition.
        fn bindUsingClause(context: *const Context, scope: *Scope, item: *const Ast.FromItem, index: usize) Error!u16 {
            var condition: u16 = none;
            for (item.using[0..item.using_count]) |ident| {
                const wanted = toName(context, ident);
                const right = findColumn(context, &scope.rels[index], wanted.slice()) orelse return error.ColumnNotFound;
                var left: ?[2]usize = null;
                var position = scope.using_count;
                while (position != 0) {
                    position -= 1;
                    const entry = &scope.using[position];
                    const name = toName(context, entry.ident);
                    if (types.same(name.slice(), wanted.slice())) {
                        left = .{ entry.left, entry.left_column };
                        break;
                    }
                }
                if (left == null) for (scope.rels[0..index], 0..) |*rel, rel_index| {
                    const column = findColumn(context, rel, wanted.slice()) orelse continue;
                    if (left != null) return error.AmbiguousColumn;
                    left = .{ rel_index, column };
                };
                const hit = left orelse return error.ColumnNotFound;
                if (scope.using_count == config.columns) return error.ColumnCapacity;
                scope.using[scope.using_count] = .{ .ident = ident, .left = @intCast(hit[0]), .left_column = @intCast(hit[1]), .right = @intCast(index), .right_column = @intCast(right), .join = item.join };
                scope.using_count += 1;
                const a = try columnNode(context, scope, hit[0], hit[1]);
                const b = try columnNode(context, scope, index, right);
                const eq = try context.pool.add(.{ .kind = .binary, .op = .eq, .a = a, .b = b, .ty = .boolean });
                const node = context.node(eq);
                try comparable(context, &node.a, &node.b);
                condition = if (condition == none) eq else try context.pool.add(.{ .kind = .and_op, .a = condition, .b = eq, .ty = .boolean });
            }
            return condition;
        }

        fn refsBelow(context: *const Context, id: u16, index: usize) bool {
            if (id == none) return true;
            const n = context.node(id);
            switch (n.kind) {
                .column => return n.level != 0 or n.relation < index,
                .scalar_subquery, .exists_subquery, .in_subquery, .aggregate => return false,
                else => {},
            }
            if (!refsBelow(context, n.a, index) or !refsBelow(context, n.c, index)) return false;
            if (!listOwner(n.kind)) return refsBelow(context, n.b, index);
            var item = n.b;
            while (item != none) : (item = context.node(item).next) if (!refsBelow(context, item, index)) return false;
            return true;
        }

        /// A top-level `item.pk = expr(earlier items)` conjunct of ON.
        fn joinProbe(context: *const Context, table: usize, on: u16, index: usize) u16 {
            const entry = &context.tables[table];
            const primary = entry.primary_column orelse return none;
            if (on == none) return none;
            var stack: [config.expr_depth + 2]u16 = undefined;
            var used: usize = 1;
            stack[0] = on;
            while (used != 0) {
                used -= 1;
                const n = context.node(stack[used]);
                if (n.kind == .and_op) {
                    if (used + 2 > stack.len) return none;
                    stack[used] = n.b;
                    stack[used + 1] = n.a;
                    used += 2;
                    continue;
                }
                if (n.kind != .binary or n.op != .eq) continue;
                for ([2][2]u16{ .{ n.a, n.b }, .{ n.b, n.a } }) |pair| {
                    const key = context.node(pair[0]);
                    if (key.kind == .column and key.level == 0 and key.relation == index and key.column == primary and
                        refsBelow(context, pair[1], index) and storedTag(entry, primary, context.node(pair[1]).ty)) return pair[1];
                }
            }
            return none;
        }

        fn bindCore(context: *const Context, q: *const Ast.Select, parent: ?*const Scope, env: ?*const CteEnv, branch: bool) Error!u16 {
            const plans = plansOf(context);
            const id = try plans.add();
            var scope: Scope = .{ .parent = parent, .plan = id, .ctes = env };
            for (q.items[0..q.item_count], 0..) |*item, index| {
                var rel: Relation = .{};
                var source: Source = .{ .join = item.join };
                if (item.query != none) {
                    // Derived tables are not LATERAL: they see enclosing blocks only.
                    const child = try bindPlan(context, item.query, parent, env, false);
                    rel.plan = child;
                    source.plan = child;
                    if (plans.items[child].correlated) plans.items[id].correlated = true;
                } else if (lookupCte(context, env, item.name)) |cte| {
                    rel.cte = cte;
                    rel.plan = plans.ctes[cte].plan;
                    rel.name = plans.ctes[cte].name;
                    source.cte = cte;
                    source.plan = rel.plan;
                    plans.ctes[cte].referenced = true;
                    if (plans.items[rel.plan].correlated) plans.items[id].correlated = true;
                } else if (viewOf(context, item.schema, item.name)) |view| {
                    rel.view = view;
                    rel.name = literalName(@tagName(view));
                    source.view = view;
                } else {
                    const table = try resolveQualified(context, item.schema, item.name);
                    rel.table = table;
                    rel.name = context.tables[table].name;
                    source.table = table;
                }
                if (item.alias) |alias| rel.name = toName(context, alias);
                scope.rels[index] = rel;
                scope.rel_count = index + 1;
                if (item.using_count != 0) {
                    source.on = try bindUsingClause(context, &scope, item, index);
                } else if (item.on != none) source.on = try bindWhere(context, &scope, item.on);
                if (source.table) |table| if (item.join == .inner or item.join == .left) {
                    source.probe = joinProbe(context, table, source.on, index);
                };
                plans.items[id].sources[index] = source;
            }
            const p = &plans.items[id];
            p.source_count = q.item_count;
            p.where = try bindWhere(context, &scope, q.where);
            for (q.group[0..q.group_count]) |expr_id| {
                p.keys[p.key_count] = try groupKey(context, &scope, q, expr_id);
                p.key_count += 1;
            }
            var saw = false;
            scope.aggregates = true;
            scope.windows = true;
            scope.saw_aggregate = &saw;
            for (q.targets[0..q.count]) |*target| {
                if (target.star) {
                    try expandStar(context, &scope, p, target);
                    continue;
                }
                if (branch) try typeExpr(context, &scope, target.expr) else try valueExpr(context, &scope, target.expr);
                const name = if (target.alias) |alias| toName(context, alias) else targetName(context, target.expr);
                try addTarget(context, p, target.expr, name);
            }
            p.width = p.count;
            if (q.having != none) {
                scope.windows=false;
                try typeExpr(context, &scope, q.having);
                try booleanArgument(context, q.having);
                p.having = q.having;
            }
            scope.windows=true;
            var order_refs: [config.columns]OrderRef = undefined;
            for (q.order[0..q.order_count], 0..) |*key, index| order_refs[index] = try orderRef(context, &scope, p, key.expr);
            var on_refs: [config.columns]OrderRef = undefined;
            for (q.distinct_on[0..q.distinct_on_count], 0..) |expr_id, index| on_refs[index] = try orderRef(context, &scope, p, expr_id);
            p.rollup=q.rollup;
            p.grouped = q.rollup or p.key_count != 0 or saw or p.having != none;
            if (p.grouped) {
                for (p.targets[0..p.count]) |target| try groupify(context, p, target);
                try groupify(context, p, p.having);
                for (order_refs[0..q.order_count]) |ref| if (ref == .expr) try groupify(context, p, ref.expr);
                for (on_refs[0..q.distinct_on_count]) |ref| if (ref == .expr) try groupify(context, p, ref.expr);
                for (0..p.count) |column| {
                    p.tys[column] = context.node(p.targets[column]).ty;
                    p.typmods[column] = outputTypmod(context, p.targets[column]);
                }
            }
            const plain_distinct = q.distinct and q.distinct_on_count == 0;
            var order: [config.columns]SortKey = undefined;
            for (q.order[0..q.order_count], 0..) |*key, index| {
                const column = try refColumn(context, p, order_refs[index], plain_distinct);
                try sortableType(planColumnType(p, context, column));
                order[index] = .{ .column = column, .descending = key.descending, .nulls_first = nullsFirst(key) };
            }
            const order_count = q.order_count;
            if (plain_distinct) {
                p.distinct = .all;
                for (order[0..order_count]) |key| appendKey(p, key);
                for (0..p.count) |column| {
                    try sortableType(p.tys[column]);
                    appendKey(p, .{ .column = @intCast(column), .descending = false, .nulls_first = config.nulls_first_ascending });
                }
            } else if (q.distinct_on_count != 0) {
                p.distinct = .on;
                for (on_refs[0..q.distinct_on_count]) |ref| {
                    const column = try refColumn(context, p, ref, false);
                    try sortableType(planColumnType(p, context, column));
                    var duplicate = false;
                    for (p.distinct_on[0..p.distinct_on_count]) |other| duplicate = duplicate or other == column;
                    if (duplicate) continue;
                    p.distinct_on[p.distinct_on_count] = column;
                    p.distinct_on_count += 1;
                }
                // PostgreSQL transformDistinctOnClause: DISTINCT ON items must
                // be the leading ORDER BY items (42P10 otherwise).
                var skipped = false;
                for (order[0..order_count]) |key| {
                    if (member(p.distinct_on[0..p.distinct_on_count], key.column)) {
                        if (skipped) return error.InvalidColumnReference;
                        appendKey(p, key);
                    } else skipped = true;
                }
                for (p.distinct_on[0..p.distinct_on_count]) |column| {
                    if (hasKey(p, column)) continue;
                    if (skipped) return error.InvalidColumnReference;
                    appendKey(p, .{ .column = column, .descending = false, .nulls_first = config.nulls_first_ascending });
                }
                for (order[0..order_count]) |key| appendKey(p, key);
            } else {
                for (order[0..order_count]) |key| appendKey(p, key);
            }
            try checkCounts(q, p);
            try lowerWindows(context,id);
            return id;
        }

        fn containsWindow(context:*const Context,id:u16) bool {
            if(id==none) return false;const n=context.node(id);if(n.window!=none) return true;
            if(n.kind==.scalar_subquery or n.kind==.exists_subquery) return false;
            if(containsWindow(context,n.a) or containsWindow(context,n.c)) return true;
            if(listOwner(n.kind)) {var item=n.b;while(item!=none):(item=context.node(item).next) if(containsWindow(context,item)) return true;}
            else if(containsWindow(context,n.b)) return true;
            return false;
        }
        fn safeWindowOperand(context:*const Context,id:u16) bool {
            if(id==none) return false;
            return switch(context.node(id).kind){.column,.null_literal,.bool_literal,.int_literal,.text_literal,.decimal_literal=>true,else=>false};
        }
        fn safeWindowFilter(context:*const Context,id:u16) bool {
            const n=context.node(id);
            return switch(n.kind){
                .column,.null_literal,.bool_literal=>true,
                .test_op=>safeWindowOperand(context,n.a),
                .not_op=>safeWindowFilter(context,n.a),
                .and_op,.or_op=>safeWindowFilter(context,n.a) and safeWindowFilter(context,n.b),
                .binary=>switch(n.op){.eq,.ne,.lt,.le,.gt,.ge,.is_distinct,.is_not_distinct=>safeWindowOperand(context,n.a) and safeWindowOperand(context,n.b),else=>false},
                else=>false,
            };
        }

        fn windowInput(context:*const Context,input:*Plan,id:u16) Error!u16 {
            if(repeatableWindowInput(context,id)) for(input.targets[0..input.count],0..) |old,i| if(sameExpr(context,old,id)) return @intCast(i);
            if(input.count==config.columns) return error.StatementTooComplex;
            const index=input.count;input.count+=1;input.targets[index]=try cloneTree(context,id);
            input.tys[index]=context.node(id).ty;input.typmods[index]=outputTypmod(context,id);
            input.names[index]=literalName("window_input");return @intCast(index);
        }
        fn lowerWindowTree(context:*const Context,p:*Plan,input:*Plan,id:u16) Error!void {
            if(id==none) return;const n=context.node(id);
            if(n.kind==.function and n.func==.grouping) {
                const column=try windowInput(context,input,id);const ty=n.ty;const next=n.next;
                n.*=.{.kind=.column,.relation=0,.column=column,.ty=ty,.next=next};return;
            }
            if(n.window!=none) {
                if(p.window_count==config.columns) return error.StatementTooComplex;
                const spec=&context.pool.windows[n.window];
                var win:Window=.{.frame=spec.frame,.start=spec.start,.end=spec.end,.exclude=spec.exclude,.output_node=id};
                const name=toName(context,n.name);
                win.kind=if(types.same(name.slice(),"rank")) .rank else if(types.same(name.slice(),"dense_rank")) .dense_rank else if(types.same(name.slice(),"row_number")) .row_number else .aggregate;
                if(win.kind==.aggregate) {
                    // PostgreSQL folds immutable constant inputs before a
                    // FILTER/frame can discard them; never execute volatile
                    // or session-dependent expressions during binding.
                    if(generatedConstant(context,n.b)) _=try generatedValue(context,n.b);
                    if(generatedConstant(context,n.c)) _=try generatedValue(context,n.c);
                    if(n.agg!=.count_star) {
                        const arg=context.node(n.b);
                        const bounded=spec.frame==.rows or spec.frame==.groups or spec.frame==.range;
                        const simple=arg.kind==.column or arg.kind==.null_literal or arg.kind==.int_literal or arg.kind==.bool_literal or arg.kind==.text_literal or arg.kind==.decimal_literal;
                        if((bounded or n.c!=none) and !simple) {
                            win.deferred_arg=try cloneTree(context,n.b);try lowerWindowTree(context,p,input,win.deferred_arg);
                        } else win.argument=try windowInput(context,input,n.b);
                    }
                    win.aggregate=.{.kind=n.agg,.arg=none,.filter=none,.distinct=false,.arg_ty=if(n.b==none) .unknown else context.node(n.b).ty,.ty=n.ty};
                    if(n.c!=none) {
                        if(safeWindowFilter(context,n.c)) win.filter_column=try windowInput(context,input,n.c)
                        else {win.deferred_filter=try cloneTree(context,n.c);try lowerWindowTree(context,p,input,win.deferred_filter);}
                    }
                }
                for(spec.partition[0..spec.partition_count]) |item| {win.partition[win.partition_count]=try windowInput(context,input,item);win.partition_count+=1;}
                for(spec.order[0..spec.order_count]) |key| {
                    win.order[win.order_count]=.{.column=try windowInput(context,input,key.expr),.descending=key.descending,.nulls_first=nullsFirst(&key)};win.order_count+=1;
                }
                const next=n.next;const ty=n.ty;
                n.*=.{.kind=.column,.relation=0,.ty=ty,.next=next};
                p.windows[p.window_count]=win;p.window_count+=1;return;
            }
            if(n.kind==.column and n.level==0) {
                const column=try windowInput(context,input,id);n.relation=0;n.column=column;return;
            }
            if(n.kind==.scalar_subquery or n.kind==.exists_subquery or n.kind==.in_subquery) {
                if(plansOf(context).items[@intCast(n.integer)].correlated) return error.UnsupportedStatement;
                if(n.kind!=.in_subquery) return;
            }
            try lowerWindowTree(context,p,input,n.a);try lowerWindowTree(context,p,input,n.c);
            if(listOwner(n.kind)) {var item=n.b;while(item!=none):(item=context.node(item).next) try lowerWindowTree(context,p,input,item);}
            else try lowerWindowTree(context,p,input,n.b);
        }
        fn lowerWindows(context:*const Context,id:u16) Error!void {
            const plans=plansOf(context);const p=&plans.items[id];var active=false;
            for(p.targets[0..p.width]) |target| active=active or containsWindow(context,target);
            if(!active) return;
            for(p.targets[0..p.width]) |target| {if(generatedConstant(context,target)) _=try generatedValue(context,target);}
            const child=try plans.add();const input=&plans.items[child];input.*=p.*;
            input.count=0;input.width=0;input.window_count=0;input.order_count=0;input.distinct=.none;
            input.limit=0xffffffffffffffff;input.offset=0;
            for(p.targets[0..p.width]) |*target| {
                target.*=try cloneTree(context,target.*);try lowerWindowTree(context,p,input,target.*);
            }
            input.width=input.count+p.window_count;
            for(p.windows[0..p.window_count],0..) |*win,index| {
                win.result=@intCast(input.count+index);context.node(win.output_node).column=win.result;
                input.targets[win.result]=try context.pool.add(.{.kind=.null_literal,.ty=.unknown,.constant=true});
            }
            for(p.targets[0..p.width],0..) |target,index| p.window_late[index]=!repeatableWindowInput(context,target);
            p.source_count=1;p.sources[0]=.{.plan=child};p.where=none;p.grouped=false;p.rollup=false;p.key_count=0;p.agg_count=0;p.having=none;
        }

        fn member(list: []const u16, column: u16) bool {
            for (list) |item| if (item == column) return true;
            return false;
        }

        fn hasKey(p: *const Plan, column: u16) bool {
            for (p.order[0..p.order_count]) |key| if (key.column == column) return true;
            return false;
        }

        /// Appends a sort key unless its column already sorts earlier.
        fn appendKey(p: *Plan, key: SortKey) void {
            if (hasKey(p, key.column)) return;
            p.order[p.order_count] = key;
            p.order_count += 1;
        }

        fn columnType(context: *const Context, definition: *const Ast.ColumnDef) types.DataType {
            const plain_integer: types.DataType = if (context.legacy or context.dialect != .postgres) integer_type else .integer32;
            return switch (definition.type_name) {
                .int4 => plain_integer,
                else => types.dataTypeOf(definition.type_name),
            };
        }

        pub fn bind(context: *const Context, statement: *const Ast.Statement) Error!Bound {
            const bound = try bindStatement(context, statement);
            try validateDiscardedRows(context);
            return bound;
        }

        fn validateDiscardedRows(context: *const Context) Error!void {
            if (!context.pool.discarded_row_constants) return;
            for (context.pool.nodes[0..context.pool.len]) |*n| {
                if (n.kind != .row_compare or n.a == none or n.integer < 0) continue;
                var sub = context.*;
                if (n.integer > 0) {
                    const owner: usize = @intCast(n.integer - 1);
                    sub.source = context.tables[owner / config.columns].columns[owner % config.columns].expression.slice();
                }
                try validateDiscardedConstants(&sub, n.a);
            }
        }

        /// Validate generated expressions after the candidate schema exists in
        /// caller-owned table storage, before the CREATE transaction publishes.
        pub fn validateGenerated(context: *const Context, index: usize) Error!void {
            const entry = &context.tables[index];
            for (entry.columns[0..entry.column_count], 0..) |*column, position| {
                if (column.default_kind == .generated) _ = try bindExpressionText(context, column, index, storedSource(index, position));
            }
            try validateDiscardedRows(context);
        }

        fn bindStatement(context: *const Context, statement: *const Ast.Statement) Error!Bound {
            if (context.plans) |plans| plans.reset();
            switch (statement.*) {
                .create_table => |*create| {
                    const table_name = toName(context, create.name);
                    if (context.catalog.find(table_name.slice(), context.snapshot) != null) return error.TableExists;
                    var out: Create = .{ .name = table_name, .columns = @splat(.{}), .count = create.count };
                    for (create.columns[0..create.count], 0..) |*definition, index| {
                        var column: V.Column = .{ .name = toName(context, definition.name), .not_null = definition.not_null, .primary_key = definition.primary_key, .typmod = definition.typmod, .default_kind = definition.default_kind };
                        for (out.columns[0..index]) |*previous|
                            if (types.same(previous.name.slice(), column.name.slice())) return error.DuplicateColumn;
                        column.data_type = columnType(context, definition);
                        if (definition.primary_key and column.data_type == .json) return error.UndefinedFunction;
                        const text = definition.expression.slice(context.source);
                        if (text.len > config.text_bytes) return error.TextCapacity;
                        column.expression.len = text.len;
                        @memcpy(column.expression.bytes[0..text.len], text);
                        switch (definition.default_kind) {
                            .identity_always, .identity_by_default => {
                                if (!integerColumn(column.data_type)) return error.TypeMismatch;
                                if (out.identity != null) return error.UnsupportedStatement;
                                column.not_null = true;
                                var options = definition.sequence;
                                if (options.type_oid == 0) options.type_oid = types.typeOid(column.data_type);
                                const seq_name = try identityName(table_name, column.name);
                                if (context.catalog.find(seq_name.slice(), context.snapshot) != null) return error.TableExists;
                                out.identity = .{ .column = @intCast(index), .name = seq_name, .spec = try sequence.resolve(options) };
                            },
                            // Type-checked now; evaluated per row.
                            .default => _ = try bindExpressionText(context, &column, null, -1),
                            else => {},
                        }
                        out.columns[index] = column;
                    }
                    return .{ .create_table = out };
                },
                .drop_table => |ident| {
                    const wanted = toName(context, ident);
                    const found = context.catalog.find(wanted.slice(), context.snapshot) orelse return error.TableNotFound;
                    if (found.kind != 'r') return error.WrongObjectType;
                    return .{ .drop_table = found.slot };
                },
                .create_sequence => |*create| {
                    const name = toName(context, create.name);
                    if (context.catalog.find(name.slice(), context.snapshot) != null) return error.TableExists;
                    return .{ .create_sequence = .{ .name = name, .spec = try sequence.resolve(create.options) } };
                },
                .drop_sequence => |ident| {
                    const wanted = toName(context, ident);
                    const found = context.catalog.find(wanted.slice(), context.snapshot) orelse return error.TableNotFound;
                    if (found.kind != 'S') return error.WrongObjectType;
                    return .{ .drop_sequence = found.slot };
                },
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
                    var out: Insert = .{ .table = index, .count = count, .rows = insert.rows, .row_count = insert.row_count };
                    for (0..count) |position| out.mapping[position] = @intCast(mapping[position]);
                    switch (insert.source) {
                        .values => try bindValues(context, entry, &out, insert.overriding),
                        .query => try bindInsertQuery(context, entry, insert.query, &out, insert.overriding),
                        .default_values => if (insert.explicit_columns) return error.Syntax,
                    }
                    const needed = insertedDefaults(context, &out);
                    try bindDefaults(context, index, entry, &needed, &out.defaults, &out.generated);
                    if (insert.conflict) |*conflict| try bindConflict(context, index, entry, insert.alias, conflict, &out.conflict);
                    out.returning = try bindReturning(context, index, &insert.returning, insert.alias);
                    return .{ .insert = out };
                },
                .select => |index| {
                    const q = &context.pool.queries[index];
                    // A system view runs on the general engine (scan-time rows).
                    if (q.from) |reference| if (viewOf(context, reference.schema, reference.name) != null) {
                        if (context.plans == null) return error.UnsupportedStatement;
                        const root = try bindPlan(context, index, null, null, false);
                        try resolveUnknown(context, root);
                        return .{ .query = root };
                    };
                    return .{ .select = try bindSelect(context, q) };
                },
                .query => |index| {
                    const plans = context.plans orelse return error.UnsupportedStatement;
                    plans.reset();
                    const root = try bindPlan(context, index, null, null, false);
                    try resolveUnknown(context, root);
                    return .{ .query = root };
                },
                .update => |*update| {
                    const index = try resolveTable(context, update.table);
                    const entry = &context.tables[index];
                    const scope = tableScope(context, index);
                    var out: Update = .{ .table = index, .values = @splat(none), .where = none, .key = none };
                    for (update.assignments[0..update.count]) |*item| {
                        const column = try columnIndex(context, entry, item.column);
                        if (out.values[column] != none) return error.DuplicateColumn;
                        if (context.node(item.value).kind == .default_value) {
                            out.values[column] = item.value;
                            continue;
                        }
                        switch (entry.columns[column].default_kind) {
                            .generated, .identity_always => return error.GeneratedAlways,
                            else => {},
                        }
                        try typeExpr(context, &scope, item.value);
                        out.values[column] = try assignment(context, item.value, &entry.columns[column]);
                    }
                    out.where = try bindWhere(context, &scope, update.where);
                    out.key = primaryKey(context, entry, out.where);
                    const needed = assignedDefaults(context, &out.values);
                    try bindDefaults(context, index, entry, &needed, &out.defaults, &out.generated);
                    out.returning = try bindReturning(context, index, &update.returning, null);
                    return .{ .update = out };
                },
                .delete => |*delete| {
                    const index = try resolveTable(context, delete.table);
                    const scope = tableScope(context, index);
                    const where = try bindWhere(context, &scope, delete.where);
                    const returning = try bindReturning(context, index, &delete.returning, null);
                    return .{ .delete = .{ .table = index, .where = where, .key = primaryKey(context, &context.tables[index], where), .returning = returning } };
                },
                .control => |control| return .{ .control = control },
                // COPY runs through Database.copyInfo/copyBegin, never as a statement.
                .copy => return error.UnsupportedStatement,
            }
        }

        /// COPY's target: field p fills column mapping[p]; every other
        /// column takes its default (identity, DEFAULT, NULL) and generated
        /// columns are computed. COPY TO lists the columns it emits.
        pub const Copy = struct {
            table: usize,
            mapping: [config.columns]u8 = undefined,
            count: usize = 0,
            defaults: [config.columns]u16 = @splat(none),
            generated: [config.columns]u16 = @splat(none),
        };

        /// PostgreSQL CopyGetAttnums: without a column list every
        /// non-generated column in order; listed generated columns are
        /// 42P10, repeated ones 42701. Identity columns accept the supplied
        /// value (COPY ignores GENERATED ALWAYS, as PostgreSQL does).
        pub fn bindCopy(context: *const Context, copy: *const Ast.Copy, with_defaults: bool) Error!Copy {
            const index = try resolveQualified(context, copy.table.schema, copy.table.name);
            const entry = &context.tables[index];
            var out: Copy = .{ .table = index };
            if (copy.explicit_columns) {
                var mapped: [config.columns]bool = @splat(false);
                for (copy.columns[0..copy.column_count]) |ident| {
                    const column = try columnIndex(context, entry, ident);
                    if (mapped[column]) return error.DuplicateColumn;
                    if (entry.columns[column].default_kind == .generated) return error.InvalidColumnReference;
                    mapped[column] = true;
                    out.mapping[out.count] = @intCast(column);
                    out.count += 1;
                }
            } else {
                for (entry.columns[0..entry.column_count], 0..) |*column, position| {
                    if (column.default_kind == .generated) continue;
                    out.mapping[out.count] = @intCast(position);
                    out.count += 1;
                }
            }
            if (with_defaults) {
                var needed: [config.columns]bool = @splat(true);
                for (out.mapping[0..out.count]) |column| needed[column] = false;
                try bindDefaults(context, index, entry, &needed, &out.defaults, &out.generated);
            }
            try validateDiscardedRows(context);
            return out;
        }
    };
}
