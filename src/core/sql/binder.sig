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
const array_module = @import("array.sig");
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
            /// CHECK / UNIQUE / named or composite PRIMARY KEY, named.
            constraints: [config.table_constraints]S.Constraint = undefined,
            constraint_count: usize = 0,
            namespace: u32 = catalog.public_namespace,
            /// SERIAL columns' owned sequences, created after the table.
            serials: [config.columns]Identity = undefined,
            serial_count: usize = 0,
            /// Relation kind, indexes (LIKE INCLUDING INDEXES), view query,
            /// inheritance and partitioning.
            extras: S.Extras = .{},
            /// CREATE TABLE AS / CREATE MATERIALIZED VIEW: root plan of the
            /// rows inserted (none: no rows).
            plan: u16 = none,
            command: types.CommandTag = .create_table,
            /// PARTITION OF: bound values checked against sibling partitions.
            parent_slot: ?usize = null,
        };

        /// DROP TABLE / VIEW / MATERIALIZED VIEW [CASCADE].
        pub const DropRelation = struct { slot: usize, cascade: bool, command: types.CommandTag };

        /// REFRESH MATERIALIZED VIEW: the view slot and its bound query.
        pub const Refresh = struct { slot: usize, plan: u16, with_data: bool };

        /// SET CONSTRAINTS: ALL, or constraint names (by table OID and
        /// constraint name), and the mode.
        pub const ConstraintRef = struct { oid: u32, name: V.Name };
        pub const SetConstraints = struct { all: bool, deferred: bool, names: [8]ConstraintRef = undefined, count: usize = 0 };

        /// ALTER SEQUENCE target slot and options (resolved against the
        /// sequence's current state when it runs).
        pub const AlterSequence = struct { slot: usize, options: sequence.Options };

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
            /// Bound CHECK expressions by constraint index (source: its text).
            checks: [config.table_constraints]u16 = @splat(none),
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
        /// UPDATE ... FROM: `from` is the root plan of `SELECT * FROM items`;
        /// FROM item i (relation i + 1 of WHERE/SET) starts at output
        /// column offsets[i + 1] of each joined row.
        pub const Update = struct { table: usize, values: [config.columns]u16, where: u16, key: u16, returning: Returning = .{}, defaults: [config.columns]u16 = @splat(none), generated: [config.columns]u16 = @splat(none), checks: [config.table_constraints]u16 = @splat(none), from: u16 = none, offsets: [config.relations]u16 = @splat(0) };

        /// DELETE ... USING: like Update.from.
        pub const Delete = struct { table: usize, where: u16, key: u16, returning: Returning = .{}, using: u16 = none, offsets: [config.relations]u16 = @splat(0) };

        /// Binds an UPDATE FROM / DELETE USING list as `SELECT * FROM items`
        /// and adds every item to the statement scope after the target
        /// (relation 0), so WHERE and SET resolve qualified and unqualified
        /// names over target and sources (42702 when ambiguous).
        fn bindSources(context: *const Context, block: u16, scope: *Scope, root: *u16, offsets: *[config.relations]u16) Error!void {
            const plans = context.plans orelse return error.UnsupportedStatement;
            const q = &context.pool.queries[block];
            if (q.item_count + 1 > config.relations) return error.StatementTooComplex;
            const plan_id = try bindPlan(context, block, null, null, false);
            const p = &plans.items[plan_id];
            var expected: usize = 0;
            for (q.items[0..q.item_count], 0..) |*item, position| {
                const source = p.sources[position];
                var rel: Relation = .{ .table = source.table, .plan = source.plan, .cte = source.cte, .view = source.view };
                if (source.table) |table| rel.name = context.tables[table].name;
                if (source.view) |view| rel.name = literalName(@tagName(view));
                if (source.cte != no_cte) rel.name = plans.ctes[source.cte].name;
                if (item.alias) |alias| rel.name = toName(context, alias);
                scope.rels[position + 1] = rel;
                // The star output lists each item's columns in order; a
                // USING merge would break the layout (0A000).
                offsets[position + 1] = @intCast(expected);
                const width = relationWidth(context, &rel);
                for (0..width) |column| {
                    if (expected + column >= p.count) return error.UnsupportedStatement;
                    const n = context.node(p.targets[expected + column]);
                    if (n.kind != .column or n.level != 0 or n.relation != position or n.column != column) return error.UnsupportedStatement;
                }
                expected += width;
            }
            if (expected != p.count) return error.UnsupportedStatement;
            scope.rel_count = q.item_count + 1;
            root.* = plan_id;
        }

        /// ON CONFLICT on the primary key (the only unique index). DO UPDATE
        /// evaluates `update` with the existing row as relation 0 and the
        /// proposed row (EXCLUDED) as relation 1.
        pub const Conflict = struct {
            action: ast.ConflictAction = .none,
            update: Update = .{ .table = 0, .values = @splat(none), .where = none, .key = none },
            /// No conflict target: DO NOTHING arbitrates every unique index.
            inferred: bool = false,
            /// The arbiter: the single-column primary key, a UNIQUE or
            /// composite PRIMARY KEY constraint (constraint index), a UNIQUE
            /// secondary index (index number), or every unique index.
            arbiter: Arbiter = .primary,
        };

        pub const Arbiter = union(enum) { primary, constraint: usize, index: usize, any };

        /// The unique index whose key columns are exactly `used` (42P10 when
        /// none); deferrable constraints are not arbiters (42809).
        fn inferArbiter(entry: *const S.Table, used: *const [config.columns]bool) Error!Arbiter {
            if (entry.primary_column) |primary| {
                var exact = true;
                for (used, 0..) |flag, column| exact = exact and flag == (column == primary);
                if (exact) return .primary;
            }
            for (entry.constraints[0..entry.constraint_count], 0..) |*constraint, index| {
                if (!S.scannedUnique(entry, constraint)) continue;
                if (!sameColumnSet(constraint.keyColumns(), used)) continue;
                if (constraint.deferrable) return error.WrongObjectType;
                return .{ .constraint = index };
            }
            for (entry.indexes[0..entry.index_count], 0..) |*index, which| {
                if (!index.unique or !sameColumnSet(index.keyColumns(), used)) continue;
                return .{ .index = which };
            }
            return error.InvalidColumnReference;
        }

        fn sameColumnSet(columns: []const u8, used: *const [config.columns]bool) bool {
            var count: usize = 0;
            for (used) |flag| {
                if (flag) count += 1;
            }
            if (count != columns.len) return false;
            for (columns) |column| if (column == S.expression_key or !used[column]) return false;
            return true;
        }

        pub const Bound = union(enum) {
            noop: types.CommandTag,
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
            truncate: Truncate,
            alter_table: AlterTable,
            alter_sequence: AlterSequence,
            create_schema: V.Name,
            drop_schema: DropSchema,
            drop_relation: DropRelation,
            refresh_view: Refresh,
            set_constraints: SetConstraints,
            merge: Merge,
        };

        /// MERGE: target table (relation 0) and source rows (`source` root
        /// plan of `SELECT * FROM source`, relation 1 at offsets[1]); each
        /// WHEN clause's condition, SET values / INSERT values and checks.
        pub const MergeWhen = struct {
            matched: bool,
            by_source: bool,
            condition: u16 = none,
            action: Ast.MergeAction,
            values: [config.columns]u16 = @splat(none),
            defaults: [config.columns]u16 = @splat(none),
            generated: [config.columns]u16 = @splat(none),
        };
        pub const Merge = struct {
            table: usize,
            source: u16,
            offsets: [config.relations]u16 = @splat(0),
            on: u16,
            whens: [Ast.merge_clauses]MergeWhen = undefined,
            when_count: usize = 0,
            checks: [config.table_constraints]u16 = @splat(none),
        };

        /// DROP SCHEMA target: its slot and OID.
        pub const DropSchema = struct { slot: usize, oid: u32, cascade: bool };

        /// ALTER TABLE: the complete new definition of table `table`. New
        /// column i reads old column sources[i], or is added (0xff) and
        /// filled with the once-evaluated DEFAULT `fills[i]` (text: its
        /// expression) or NULL. Existing rows are re-checked for the flagged
        /// NOT NULL columns and constraints.
        pub const AlterTable = struct {
            table: usize,
            name: V.Name,
            columns: [config.columns]V.Column,
            count: usize,
            constraints: [config.table_constraints]S.Constraint,
            constraint_count: usize,
            sources: [config.columns]u8,
            fills: [config.columns]u16 = @splat(none),
            check_not_null: [config.columns]bool = @splat(false),
            check_constraint: [config.table_constraints]bool = @splat(false),
            /// Kind, secondary indexes, view and partition definition after
            /// the statement (CREATE / DROP INDEX change only the indexes;
            /// a new index has OID 0 until the statement assigns one).
            extras: S.Extras = .{},
            command: types.CommandTag = .alter_table,
            /// CREATE UNIQUE INDEX: existing rows are checked for this index.
            check_index: ?usize = null,
        };

        /// TRUNCATE targets: distinct table slots in statement order.
        pub const Truncate = struct { tables: [config.tables]u8 = undefined, count: usize = 0, restart_identity: bool = false };

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
            planning_plan:?*const Plan=null,
            constant_dependencies:?*[config.ctes]bool=null,
            describe_only:bool=false,

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
            window_defs:u16=none,
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
            kind:Ast.WindowKind=.aggregate,mutable_keys:bool=false,materialized_full:bool=false,
            aggregate:Agg=.{.kind=.none,.arg=none,.filter=none,.distinct=false,.arg_ty=.unknown,.ty=.unknown},
            argument:u16=none,result:u16=0,output_node:u16=none,
            deferred_arg:u16=none,deferred_filter:u16=none,filter_column:u16=none,
            offset_arg:u16=none,default_arg:u16=none,offset_repeatable:bool=true,offset_total:bool=true,offset_prefix:bool=false,
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
            // Preserve validation before aggregate/window lowering detaches
            // arguments from CASE. Report only if this plan remains reachable.
            planned_checked:bool=false,
            planned_error:?Error=null,
            planned_targets:[2*config.columns]?Error=@splat(null),
            prunable:[2*config.columns]bool=@splat(false),
            required:[2*config.columns]bool=@splat(true),
            demanded:bool=false,
            constant_source_safe:bool=false,
            constant_outputs:[2*config.columns]V.Cell=undefined,
            constant_known:[2*config.columns]bool=@splat(false),
            constant_dependencies:[2*config.columns][config.ctes]bool=@splat(@splat(false)),
            windows:[config.columns]Window=undefined,window_count:usize=0,
            window_late:[2*config.columns]bool=.{false}**(2*config.columns),
            window_origins:[config.columns]u16=.{none}**config.columns,
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
            aggregate_required:[config.columns]bool=@splat(true),
            /// Conservatively retain aggregates registered from named WINDOW
            /// clauses, including definitions with no consuming WindowAgg.
            window_aggregate_count:usize=0,
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
            references:usize=0,
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
                .noop => |tag| tag,
                .create_table => |*create| create.command,
                .drop_relation => |*drop| drop.command,
                .refresh_view => .refresh_materialized_view,
                .set_constraints => .set_constraints,
                .merge => .merge,
                .drop_table => .drop_table,
                .create_sequence => .create_sequence,
                .drop_sequence => .drop_sequence,
                .insert => .insert,
                .select, .query => .select,
                .update => .update,
                .delete => .delete,
                .truncate => .truncate,
                .alter_table => |*alter| alter.command,
                .alter_sequence => .alter_sequence,
                .create_schema => .create_schema,
                .drop_schema => .drop_schema,
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
            // point and box have no ordinary comparison operators here.
            if (geometricType(left) or geometricType(right) or left == .xml or right == .xml) return error.UndefinedFunction;
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

        fn timeType(ty: ast.Type) bool {
            return ty == .time or ty == .timetz;
        }

        /// Operators of TIME/TIMETZ (date.c): time - time -> interval;
        /// time/timetz +- interval and interval + time/timetz keep the
        /// operand type; date + time -> timestamp and date + timetz ->
        /// timestamptz (either order). An untyped operand of `-` takes the
        /// time type (time - time) or interval (timetz - interval); for `+`
        /// both interval and date candidates remain, so it is ambiguous.
        fn timeArithmetic(context: *const Context, n: *ast.Node) Error!void {
            const add = n.op == .add;
            const sub = n.op == .sub;
            if (!add and !sub) return error.UndefinedFunction;
            var left = context.node(n.a).ty;
            var right = context.node(n.b).ty;
            if (left == .unknown or right == .unknown) {
                if (add) return error.AmbiguousFunction;
                if (right == .unknown) try coerce(context, n.b, if (left == .time) .time else .interval);
                if (left == .unknown) {
                    if (right != .time) return error.UndefinedFunction;
                    try coerce(context, n.a, .time);
                }
                left = context.node(n.a).ty;
                right = context.node(n.b).ty;
            }
            if (sub and left == .time and right == .time) {
                n.ty = .interval;
                return;
            }
            if (timeType(left) and right == .interval) {
                n.ty = left;
                return;
            }
            if (add and left == .interval and timeType(right)) {
                n.ty = right;
                return;
            }
            if (add and ((left == .date and timeType(right)) or (timeType(left) and right == .date))) {
                n.ty = if (left == .timetz or right == .timetz) .timestamptz else .timestamp;
                return;
            }
            return error.UndefinedFunction;
        }

        /// Operators of MONEY (cash.c): money +- money -> money; money *
        /// int2/int4/int8/float4/float8 and the reverse -> money; money /
        /// those -> money; money / money -> float8. NUMERIC operands resolve
        /// the float8 operators (numeric -> float8 is implicit). An untyped
        /// operand is money, except for `*` (float8, the preferred type).
        fn moneyArithmetic(context: *const Context, n: *ast.Node) Error!void {
            if (n.op != .add and n.op != .sub and n.op != .mul and n.op != .div) return error.UndefinedFunction;
            if (context.node(n.a).ty == .unknown) try coerce(context, n.a, if (n.op == .mul) .float8 else .money);
            if (context.node(n.b).ty == .unknown) try coerce(context, n.b, if (n.op == .mul) .float8 else .money);
            const left = context.node(n.a).ty;
            const right = context.node(n.b).ty;
            if (left == .money and right == .money) {
                if (n.op == .mul) return error.UndefinedFunction;
                n.ty = if (n.op == .div) .float8 else .money;
                return;
            }
            const scalar = if (left == .money) right else left;
            if (n.op == .add or n.op == .sub or (n.op == .div and right == .money)) return error.UndefinedFunction;
            if (!value.numericCategory(scalar)) return error.UndefinedFunction;
            if (scalar == .numeric) {
                if (left == .money) n.b = try convert(context, n.b, .float8, -1, .implicit) else n.a = try convert(context, n.a, .float8, -1, .implicit);
            }
            n.ty = .money;
        }

        /// pg_lsn operators: pg_lsn - pg_lsn -> numeric; pg_lsn + numeric,
        /// numeric + pg_lsn and pg_lsn - numeric -> pg_lsn. An untyped
        /// operand is taken as the other operand's type when that operator
        /// exists (`-`), otherwise as numeric (`+`).
        fn lsnArithmetic(context: *const Context, n: *ast.Node) Error!void {
            if (n.op != .add and n.op != .sub) return error.UndefinedFunction;
            if (context.node(n.a).ty == .unknown) try coerce(context, n.a, if (n.op == .sub) .pg_lsn else .numeric);
            if (context.node(n.b).ty == .unknown) try coerce(context, n.b, if (n.op == .sub) .pg_lsn else .numeric);
            const left = context.node(n.a).ty;
            const right = context.node(n.b).ty;
            if (left == .pg_lsn and right == .pg_lsn) {
                if (n.op != .sub) return error.UndefinedFunction;
                n.ty = .numeric;
                return;
            }
            const scalar = if (left == .pg_lsn) right else left;
            if (left != .pg_lsn and n.op == .sub) return error.UndefinedFunction;
            if (!value.numericCategory(scalar) or !value.castable(scalar, .numeric, .implicit)) return error.UndefinedFunction;
            if (left == .pg_lsn) n.b = try convert(context, n.b, .numeric, -1, .implicit) else n.a = try convert(context, n.a, .numeric, -1, .implicit);
            n.ty = .pg_lsn;
        }

        fn arithmeticType(context: *const Context, n: *ast.Node) Error!void {
            if (context.node(n.a).ty == .unknown and context.node(n.b).ty == .unknown) return error.AmbiguousFunction;
            if (context.node(n.a).ty == .money or context.node(n.b).ty == .money) return moneyArithmetic(context, n);
            if (context.node(n.a).ty == .pg_lsn or context.node(n.b).ty == .pg_lsn) return lsnArithmetic(context, n);
            if (types.isRange(context.node(n.a).ty) or types.isRange(context.node(n.b).ty)) return rangeOperator(context, n);
            if (timeType(context.node(n.a).ty) or timeType(context.node(n.b).ty)) return timeArithmetic(context, n);
            var left = context.node(n.a).ty;
            var right = context.node(n.b).ty;
            // An untyped literal takes the other operand's type, except
            // that datetime arithmetic takes an interval, and an interval
            // is scaled by double precision.
            if ((n.op == .mul or n.op == .div) and left == .interval and right == .unknown) {
                try coerce(context, n.b, .float8);
                right = .float8;
            }
            if (n.op == .mul and right == .interval and left == .unknown) {
                try coerce(context, n.a, .float8);
                left = .float8;
            }
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
            // interval * double precision, double precision * interval and
            // interval / double precision (interval_mul / interval_div).
            if ((n.op == .mul and (left == .interval) != (right == .interval)) or (n.op == .div and left == .interval)) {
                const factor_left = n.op == .mul and right == .interval;
                const factor_ty = if (factor_left) left else right;
                if (!value.numericCategory(factor_ty)) return error.UndefinedFunction;
                if (factor_left) n.a = try convert(context, n.a, .float8, -1, .implicit) else n.b = try convert(context, n.b, .float8, -1, .implicit);
                n.ty = .interval;
                return;
            }
            const add = n.op == .add;
            const sub = n.op == .sub;
            if (!add and !sub) return error.UndefinedFunction;
            // date +- integer, integer + date
            if (left == .date and value.integral(right)) {
                if (right == .int8) return error.UndefinedFunction;
                n.ty = .date;
                return;
            }
            if (add and value.integral(left) and right == .date) {
                if (left == .int8) return error.UndefinedFunction;
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

        /// int2/int4/int8 & | # (common integer type) and << >> (int4 count).
        fn bitwiseType(context: *const Context, n: *ast.Node) Error!void {
            const left = context.node(n.a).ty;
            const right = context.node(n.b).ty;
            if (n.op == .shift_left or n.op == .shift_right) {
                // An unknown left operand also matches bit and inet shifts.
                if (left == .unknown) return error.AmbiguousFunction;
                if (!value.integral(left)) return error.UndefinedFunction;
                if (right != .unknown and right != .int2 and right != .int4) return error.UndefinedFunction;
                n.b = try convert(context, n.b, .int4, -1, .implicit);
                n.ty = left;
                return;
            }
            if (left == .unknown and right == .unknown) return error.AmbiguousFunction;
            const target: ast.Type = if (left == .unknown) right else if (right == .unknown) left else if (value.integral(left) and value.integral(right)) value.arithmeticType(left, right) else return error.UndefinedFunction;
            if (!value.integral(target)) return error.UndefinedFunction;
            try coerce(context, n.a, target);
            try coerce(context, n.b, target);
            n.ty = target;
        }

        fn jsonOperator(context: *const Context, n: *ast.Node) Error!void {
            const left = context.node(n.a).ty;
            if (left == .unknown) return error.AmbiguousFunction;
            if (left != .jsonb and left != .json) return error.UndefinedFunction;
            const right_node = context.node(n.b);
            switch (n.op) {
                .arrow, .arrow_text => {
                    if (right_node.ty == .unknown) try coerce(context, n.b, .text);
                    const right = context.node(n.b).ty;
                    if (right != .text and right != .int2 and right != .int4) return error.UndefinedFunction;
                    n.ty = if (n.op == .arrow) left else .text;
                },
                .path, .path_text => {
                    // The right operand is a text[] literal only.
                    if (right_node.ty != .unknown or right_node.kind != .text_literal) return error.UndefinedFunction;
                    const text = E.literalText(context.source, right_node.text);
                    var items: [32][]const u8 = undefined;
                    _ = try Io.Documents.parsePath(text.slice(), &items);
                    right_node.ty = .text;
                    n.ty = if (n.op == .path) left else .text;
                },
                .contains, .contained => {
                    if (left != .jsonb) return error.UndefinedFunction;
                    n.b = try convert(context, n.b, .jsonb, -1, .implicit);
                    if (context.node(n.b).ty != .jsonb) return error.UndefinedFunction;
                    n.ty = .boolean;
                },
                .exists => {
                    if (left != .jsonb) return error.UndefinedFunction;
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
                .{ .name = "abs", .func = .abs },
                .{ .name = "ceil", .func = .ceil },
                .{ .name = "ceiling", .func = .ceil },
                .{ .name = "floor", .func = .floor },
                .{ .name = "trunc", .func = .trunc },
                .{ .name = "sign", .func = .sign },
                .{ .name = "sqrt", .func = .sqrt },
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
                // String functions (B11).
                .{ .name = "lower", .func = .lower },               .{ .name = "upper", .func = .upper },
                .{ .name = "initcap", .func = .initcap },           .{ .name = "length", .func = .char_length },
                .{ .name = "char_length", .func = .char_length },   .{ .name = "character_length", .func = .char_length },
                .{ .name = "octet_length", .func = .octet_length }, .{ .name = "bit_length", .func = .bit_length },
                .{ .name = "substring", .func = .substring },       .{ .name = "substr", .func = .substring },
                .{ .name = "btrim", .func = .btrim },               .{ .name = "ltrim", .func = .ltrim },
                .{ .name = "rtrim", .func = .rtrim },               .{ .name = "strpos", .func = .strpos },
                .{ .name = "position", .func = .strpos },           .{ .name = "replace", .func = .replace },
                .{ .name = "left", .func = .left },                 .{ .name = "right", .func = .right },
                .{ .name = "repeat", .func = .repeat },             .{ .name = "reverse", .func = .reverse },
                .{ .name = "lpad", .func = .lpad },                 .{ .name = "rpad", .func = .rpad },
                .{ .name = "split_part", .func = .split_part },     .{ .name = "starts_with", .func = .starts_with },
                .{ .name = "ascii", .func = .ascii },               .{ .name = "chr", .func = .chr },
                .{ .name = "translate", .func = .translate },       .{ .name = "concat", .func = .concat },
                .{ .name = "concat_ws", .func = .concat_ws },       .{ .name = "overlay", .func = .overlay },
                .{ .name = "to_hex", .func = .to_hex },
                // Mathematical functions (B11).
                .{ .name = "power", .func = .power },               .{ .name = "pow", .func = .power },
                .{ .name = "ln", .func = .ln },                     .{ .name = "log", .func = .log },
                .{ .name = "log10", .func = .log10 },               .{ .name = "exp", .func = .exp },
                .{ .name = "mod", .func = .mod },                   .{ .name = "div", .func = .div },
                .{ .name = "pi", .func = .pi },                     .{ .name = "degrees", .func = .degrees },
                .{ .name = "radians", .func = .radians },           .{ .name = "cbrt", .func = .cbrt },
                .{ .name = "sin", .func = .sin },                   .{ .name = "cos", .func = .cos },
                .{ .name = "tan", .func = .tan },                   .{ .name = "cot", .func = .cot },
                .{ .name = "asin", .func = .asin },                 .{ .name = "acos", .func = .acos },
                .{ .name = "atan", .func = .atan },                 .{ .name = "atan2", .func = .atan2 },
                .{ .name = "gcd", .func = .gcd },                   .{ .name = "lcm", .func = .lcm },
                .{ .name = "scale", .func = .scale },               .{ .name = "min_scale", .func = .min_scale },
                .{ .name = "trim_scale", .func = .trim_scale },
                // Date/time functions (B11).
                .{ .name = "extract", .func = .extract },           .{ .name = "date_part", .func = .date_part },
                .{ .name = "date_trunc", .func = .date_trunc },     .{ .name = "age", .func = .age },
                .{ .name = "justify_days", .func = .justify_days }, .{ .name = "justify_hours", .func = .justify_hours },
                .{ .name = "justify_interval", .func = .justify_interval }, .{ .name = "make_date", .func = .make_date },
                .{ .name = "make_timestamp", .func = .make_timestamp }, .{ .name = "isfinite", .func = .isfinite },
                // Formatting input functions (B11).
                .{ .name = "to_date", .func = .to_date },           .{ .name = "to_number", .func = .to_number },
                .{ .name = "to_timestamp", .func = .to_timestamp },
                // Unicode normalization (B11); NORMALIZE(...) is also SQL syntax.
                .{ .name = "normalize", .func = .normalize },       .{ .name = "is_normalized", .func = .is_normalized },
                // Array functions (B11 advanced types).
                .{ .name = "array_length", .func = .array_length }, .{ .name = "cardinality", .func = .cardinality },
                .{ .name = "array_ndims", .func = .array_ndims },   .{ .name = "array_dims", .func = .array_dims },
                .{ .name = "array_lower", .func = .array_lower },   .{ .name = "array_upper", .func = .array_upper },
                .{ .name = "array_append", .func = .array_append }, .{ .name = "array_prepend", .func = .array_prepend },
                .{ .name = "array_cat", .func = .array_cat },       .{ .name = "array_to_string", .func = .array_to_string },
                // Range constructors and functions (B11 advanced types).
                .{ .name = "int4range", .func = .range_constructor }, .{ .name = "int8range", .func = .range_constructor },
                .{ .name = "numrange", .func = .range_constructor }, .{ .name = "daterange", .func = .range_constructor },
                .{ .name = "tsrange", .func = .range_constructor }, .{ .name = "tstzrange", .func = .range_constructor },
                .{ .name = "isempty", .func = .isempty },           .{ .name = "lower_inc", .func = .lower_inc },
                .{ .name = "upper_inc", .func = .upper_inc },       .{ .name = "lower_inf", .func = .lower_inf },
                .{ .name = "upper_inf", .func = .upper_inf },
                // Network address functions (B11 advanced types).
                .{ .name = "host", .func = .inet_host },            .{ .name = "masklen", .func = .masklen },
                .{ .name = "family", .func = .inet_family },        .{ .name = "network", .func = .inet_network },
                .{ .name = "broadcast", .func = .broadcast },       .{ .name = "netmask", .func = .netmask },
                // Geometric functions (B11 advanced types).
                .{ .name = "point", .func = .point_constructor },   .{ .name = "box", .func = .box_constructor },
                .{ .name = "area", .func = .area },                 .{ .name = "center", .func = .center },
                .{ .name = "width", .func = .width },               .{ .name = "height", .func = .height },
                // XML predicates (B11 advanced types).
                .{ .name = "xml_is_well_formed", .func = .xml_is_well_formed },
                .{ .name = "xml_is_well_formed_document", .func = .xml_is_well_formed_document },
                .{ .name = "xml_is_well_formed_content", .func = .xml_is_well_formed_content },
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
                // B11 statistical and bitwise aggregates.
                .{ .name = "stddev", .agg = .stddev_samp },        .{ .name = "stddev_samp", .agg = .stddev_samp },
                .{ .name = "stddev_pop", .agg = .stddev_pop },      .{ .name = "variance", .agg = .var_samp },
                .{ .name = "var_samp", .agg = .var_samp },          .{ .name = "var_pop", .agg = .var_pop },
                .{ .name = "corr", .agg = .corr },                  .{ .name = "covar_pop", .agg = .covar_pop },
                .{ .name = "covar_samp", .agg = .covar_samp },      .{ .name = "regr_count", .agg = .regr_count },
                .{ .name = "regr_sxx", .agg = .regr_sxx },          .{ .name = "regr_syy", .agg = .regr_syy },
                .{ .name = "regr_sxy", .agg = .regr_sxy },          .{ .name = "regr_avgx", .agg = .regr_avgx },
                .{ .name = "regr_avgy", .agg = .regr_avgy },        .{ .name = "regr_slope", .agg = .regr_slope },
                .{ .name = "regr_intercept", .agg = .regr_intercept }, .{ .name = "regr_r2", .agg = .regr_r2 },
                .{ .name = "bit_and", .agg = .bit_and },            .{ .name = "bit_or", .agg = .bit_or },
                .{ .name = "bit_xor", .agg = .bit_xor },
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
            } else if (ast.pairAggregate(kind)) {
                try typePairAggregate(context, &inner, n);
            } else if (n.b == none or context.node(n.b).next != none) return error.UndefinedFunction;
            const arg = n.b;
            var arg_ty: ast.Type = .unknown;
            if (arg != none) {
                try typeExpr(context, &inner, arg);
                arg_ty = context.node(arg).ty;
                if (arg_ty == .unknown) switch (kind) {
                    .count, .min, .max => try coerce(context, arg, .text),
                    .bool_and, .bool_or => try coerce(context, arg, .boolean),
                    // Every overload is numeric: float8 is preferred.
                    .stddev_pop, .stddev_samp, .var_pop, .var_samp => try coerce(context, arg, .float8),
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

        /// corr/covar/regr_*(Y, X): both float8 (implicit numeric casts),
        /// wrapped in one aggregate_pair input; DISTINCT pairs are not provided.
        fn typePairAggregate(context: *const Context, scope: *const Scope, n: *ast.Node) Error!void {
            const y = n.b;
            if (y == none) return error.UndefinedFunction;
            const x = context.node(y).next;
            if (x == none or context.node(x).next != none) return error.UndefinedFunction;
            if (n.distinct) return error.UnsupportedStatement;
            context.node(y).next = none;
            var operands = [2]u16{ y, x };
            for (&operands) |*operand| {
                try typeExpr(context, scope, operand.*);
                const ty = context.node(operand.*).ty;
                if (ty != .unknown and !value.numericCategory(ty)) return error.UndefinedFunction;
                operand.* = try convert(context, operand.*, .float8, -1, .implicit);
            }
            context.node(operands[0]).next = operands[1];
            context.node(operands[1]).next = none;
            n.b = try context.pool.add(.{ .kind = .function, .func = .aggregate_pair, .b = operands[0], .ty = .text, .name = n.name });
            try context.pool.raise(n.b, operands[1]);
        }

        fn aggregateType(context:*const Context,n:*ast.Node,kind:ast.Agg,arg:u16,arg_ty:ast.Type) Error!ast.Type {
            return switch (kind) {
                .count, .count_star => .int8,
                .sum => switch (arg_ty) {
                    .int2, .int4 => .int8,
                    .int8, .numeric => .numeric,
                    .float4, .float8, .interval, .money => arg_ty,
                    else => return error.UndefinedFunction,
                },
                .avg => switch (arg_ty) {
                    .int2, .int4, .int8, .numeric => .numeric,
                    .float4, .float8 => .float8,
                    // interval_avg (PostgreSQL 18).
                    .interval => .interval,
                    // AVG(interval) is not provided (no interval / number).
                    else => return error.UndefinedFunction,
                },
                // array_larger/array_smaller compare whole arrays.
                .min, .max => if (types.isArray(arg_ty)) arg_ty else switch (arg_ty) {
                    .int2, .int4, .int8, .numeric, .float4, .float8, .text, .oid, .date, .timestamp, .timestamptz, .interval, .bpchar, .time, .timetz, .money => arg_ty,
                    // pg_lsn_larger/smaller and xid8_larger/smaller.
                    .pg_lsn, .xid8 => arg_ty,
                    // network_larger/network_smaller (cidr input converts).
                    .inet, .cidr => blk: {
                        n.b = try convert(context, arg, .inet, -1, .implicit);
                        break :blk .inet;
                    },
                    .name, .varchar => blk: {
                        n.b = try convert(context, arg, .text, -1, .implicit);
                        break :blk .text;
                    },
                    else => return error.UndefinedFunction,
                },
                .bool_and, .bool_or => if (arg_ty == .boolean) .boolean else return error.UndefinedFunction,
                .stddev_pop, .stddev_samp, .var_pop, .var_samp => switch (arg_ty) {
                    .int2, .int4, .int8, .numeric => .numeric,
                    .float4, .float8 => .float8,
                    else => return error.UndefinedFunction,
                },
                .regr_count => .int8,
                .corr, .covar_pop, .covar_samp, .regr_sxx, .regr_syy, .regr_sxy, .regr_avgx, .regr_avgy, .regr_slope, .regr_intercept, .regr_r2 => .float8,
                .bit_and, .bit_or, .bit_xor => if (value.integral(arg_ty)) arg_ty else return error.UndefinedFunction,
                .none => unreachable,
            };
        }

        fn repeatableWindowInput(context:*const Context,id:u16) bool {
            if(id==none) return true;const n=context.node(id);
            if(n.planned_null) return true;
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

        fn framePlanRepeatable(context:*const Context,id:u16,seen:*[config.subqueries]bool) bool {
            if(id==none) return true;
            const plans=plansOf(context);if(id>=plans.len) return false;
            if(seen[id]) return true;seen[id]=true;const p=&plans.items[id];
            if(p.correlated) return false;
            if(p.set_op!=.none) return framePlanRepeatable(context,p.left,seen) and framePlanRepeatable(context,p.right,seen);
            for(p.targets[0..p.width]) |target| if(!frameExprRepeatable(context,target,seen)) return false;
            if(!frameExprRepeatable(context,p.where,seen) or !frameExprRepeatable(context,p.having,seen)) return false;
            for(p.keys[0..p.key_count]) |key| if(!frameExprRepeatable(context,key,seen)) return false;
            for(p.aggs[0..p.agg_count]) |agg| if(!frameExprRepeatable(context,agg.arg,seen) or !frameExprRepeatable(context,agg.filter,seen)) return false;
            for(p.windows[0..p.window_count]) |win| if(win.mutable_keys or !win.offset_repeatable) return false;
            for(p.sources[0..p.source_count]) |source| if(!framePlanRepeatable(context,source.plan,seen) or !frameExprRepeatable(context,source.on,seen)) return false;
            return framePlanRepeatable(context,p.left,seen) and framePlanRepeatable(context,p.right,seen);
        }
        fn frameExprRepeatable(context:*const Context,id:u16,seen:*[config.subqueries]bool) bool {
            if(id==none) return true;const n=context.node(id);
            if(n.kind==.scalar_subquery or n.kind==.exists_subquery or n.kind==.in_subquery) {
                if(!framePlanRepeatable(context,@intCast(n.integer),seen)) return false;
                if(n.kind!=.in_subquery) return true;
            }
            if(n.kind==.function and !ast.canRepeatFunction(n.func) and n.func!=.jsonb_typeof and n.func!=.jsonb_array_length) return false;
            if(!frameExprRepeatable(context,n.a,seen) or !frameExprRepeatable(context,n.c,seen)) return false;
            if(listOwner(n.kind)) {var item=n.b;while(item!=none):(item=context.node(item).next) if(!frameExprRepeatable(context,item,seen)) return false;}
            else if(!frameExprRepeatable(context,n.b,seen)) return false;
            return true;
        }
        fn complexFrameRepeatable(context:*const Context,id:u16) bool {
            var seen:[config.subqueries]bool=@splat(false);return frameExprRepeatable(context,id,&seen);
        }
        fn repeatableFrameInput(context:*const Context,id:u16) bool {
            return repeatableWindowInput(context,id) or complexFrameRepeatable(context,id);
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
            // Native planning folds immutable errors even when an optimized
            // ranking frame or LIMIT0 will avoid runtime offset evaluation.
            if(generatedConstant(context,bound.offset)) _=try generatedValue(context,bound.offset);
        }

        fn valueWindowName(context:*const Context,n:*const ast.Node) bool {
            const name=toName(context,n.name);
            return types.same(name.slice(),"first_value") or types.same(name.slice(),"last_value") or types.same(name.slice(),"nth_value");
        }
        fn typeValueArguments(context:*const Context,scope:*const Scope,n:*ast.Node) Error!void {
            var inner=scope.*;inner.windows=false;inner.inside_window=true;
            if(n.c!=none) return error.UnsupportedStatement;
            if(n.star or n.b==none) return error.UndefinedFunction;
            const first=n.b;const second=context.node(first).next;
            const name=toName(context,n.name);const nth=types.same(name.slice(),"nth_value");
            if(nth) {if(second==none or context.node(second).next!=none) return error.UndefinedFunction;}
            else if(second!=none) return error.UndefinedFunction;
            try typeExpr(context,&inner,first);
            if(nth) {
                try typeExpr(context,&inner,second);
                const ty=context.node(second).ty;
                if(ty!=.unknown and ty!=.int2 and ty!=.int4) return error.UndefinedFunction;
                context.node(first).next=none;context.node(second).next=none;
                context.node(first).next=try convert(context,second,.int4,-1,.implicit);
            }
            n.ty=context.node(first).ty;
            if(n.ty==.unknown) return error.TypeMismatch;
        }

        fn offsetWindowName(context:*const Context,n:*const ast.Node) bool {
            const name=toName(context,n.name);
            return types.same(name.slice(),"lag") or types.same(name.slice(),"lead");
        }
        fn typeOffsetArguments(context:*const Context,scope:*const Scope,n:*ast.Node) Error!void {
            var inner=scope.*;inner.windows=false;inner.inside_window=true;
                if(n.c!=none) return error.UnsupportedStatement;
                if(n.star or n.b==none) return error.UndefinedFunction;
                var arguments:[3]u16=undefined;var count:usize=0;var item=n.b;
                while(item!=none) : (item=context.node(item).next) {
                    if(count==3) return error.UndefinedFunction;
                    arguments[count]=item;count+=1;try typeExpr(context,&inner,item);
                }
                if(count>=2) {
                    const ty=context.node(arguments[1]).ty;
                    if(ty!=.unknown and ty!=.int2 and ty!=.int4) return error.UndefinedFunction;
                }
                var target=context.node(arguments[0]).ty;
                if(count==3) unifyInto(&target,context.node(arguments[2]).ty) catch return error.UndefinedFunction;
                if(target==.unknown) target=.text;
                for(arguments[0..count]) |id| context.node(id).next=none;
                arguments[0]=try convert(context,arguments[0],target,-1,.implicit);
                if(count>=2) arguments[1]=try convert(context,arguments[1],.int4,-1,.implicit);
                if(count==3) arguments[2]=try convert(context,arguments[2],target,-1,.implicit);
                for(0..count-1) |index| context.node(arguments[index]).next=arguments[index+1];
                n.b=arguments[0];n.ty=target;
        }

        fn rankWindowName(context:*const Context,n:*const ast.Node) bool {
            const name=toName(context,n.name);
            return types.same(name.slice(),"rank") or types.same(name.slice(),"dense_rank") or types.same(name.slice(),"row_number") or types.same(name.slice(),"percent_rank") or types.same(name.slice(),"cume_dist");
        }
        fn typeRankArguments(context:*const Context,scope:*const Scope,n:*ast.Node) Error!void {
            var inner=scope.*;inner.windows=false;inner.inside_window=true;
            var item=n.b;
            while(item!=none) : (item=context.node(item).next) try typeExpr(context,&inner,item);
            const name=toName(context,n.name);
            if(n.b!=none) return if(types.same(name.slice(),"row_number")) error.UndefinedFunction else error.WrongObjectType;
            // Native PostgreSQL also accepts zero-argument window calls as fn(*).
            n.ty=if(types.same(name.slice(),"percent_rank") or types.same(name.slice(),"cume_dist")) .float8 else .int8;
        }
        fn typeNtileArgument(context:*const Context,scope:*const Scope,n:*ast.Node) Error!void {
            if(n.b==none or n.star or context.node(n.b).next!=none) return error.UndefinedFunction;
            var inner=scope.*;inner.windows=false;inner.inside_window=true;
            try typeExpr(context,&inner,n.b);
            const ty=context.node(n.b).ty;
            if(ty!=.unknown and ty!=.int2 and ty!=.int4) return error.UndefinedFunction;
            n.b=try convert(context,n.b,.int4,-1,.implicit);n.ty=.int4;
        }

        fn findWindow(context:*const Context,head:u16,stop:u16,name:ast.Ident) Error!?*Ast.Window {
            const wanted=toName(context,name);var id=head;
            while(id!=none and id!=stop) : (id=context.pool.windows[id].next) {
                try context.session.checkpoint();
                const spec=&context.pool.windows[id];
                if(spec.definition) |ident| if(types.same(wanted.slice(),toName(context,ident).slice())) return spec;
            }
            return null;
        }
        fn inheritWindow(context:*const Context,spec:*Ast.Window,head:u16,stop:u16) Error!void {
            const name=spec.base orelse return;
            const parent=(try findWindow(context,head,stop,name)) orelse return error.UndefinedObject;
            if(!spec.direct and (parent.framed or spec.partition_count!=0 or (parent.order_count!=0 and spec.order_count!=0))) return error.WindowingError;
            spec.partition_count=parent.partition_count;spec.partition_typed=parent.partition_typed;
            for(parent.partition[0..parent.partition_count],0..) |id,index| {spec.partition[index]=try cloneTree(context,id);spec.partition_origin[index]=parent.partition_origin[index];}
            if(spec.direct or spec.order_count==0) {
                spec.order_count=parent.order_count;spec.order_typed=parent.order_typed;
                for(parent.order[0..parent.order_count],0..) |key,index| {spec.order[index]=key;spec.order[index].expr=try cloneTree(context,key.expr);spec.order_origin[index]=parent.order_origin[index];}
            }
            if(spec.direct) {
                spec.frame=parent.frame;spec.framed=parent.framed;spec.start=parent.start;spec.end=parent.end;spec.exclude=parent.exclude;spec.bounds_typed=parent.bounds_typed;
                spec.start.offset=try cloneTree(context,parent.start.offset);spec.end.offset=try cloneTree(context,parent.end.offset);
            }
            spec.base=null;
        }
        fn resolveWindows(context:*const Context,head:u16) Error!void {
            var id=head;while(id!=none) : (id=context.pool.windows[id].next) {
                const spec=&context.pool.windows[id];
                if((try findWindow(context,head,id,spec.definition.?))!=null) return error.WindowingError;
                try inheritWindow(context,spec,head,id);
            }
        }
        fn typeWindowSpec(context:*const Context,scope:*const Scope,spec:*Ast.Window) Error!void {
            var inner=scope.*;inner.windows=false;inner.inside_window=true;
            if(!spec.partition_typed) for(spec.partition[0..spec.partition_count]) |id| {try valueExpr(context,&inner,id);try sortableType(context.node(id).ty);};
            if(!spec.order_typed) for(spec.order[0..spec.order_count]) |key| {try valueExpr(context,&inner,key.expr);try sortableType(context.node(key.expr).ty);};
            if(spec.frame==.groups and spec.order_count==0) return error.WindowingError;
            if(spec.frame==.range and (spec.start.offset!=none or spec.end.offset!=none)) {
                if(spec.order_count!=1) return error.WindowingError;
                if(!value.integral(context.node(spec.order[0].expr).ty)) return error.UnsupportedStatement;
            }
            if(!spec.bounds_typed) {try typeFrameOffset(context,scope,&spec.start);try typeFrameOffset(context,scope,&spec.end);}
            if(spec.exclude==.no_others and spec.start.kind==.unbounded_preceding) {
                if(spec.end.kind==.unbounded_following) spec.frame=.full
                else if(spec.end.kind==.current_row and spec.frame!=.default) spec.frame=if(spec.frame==.rows or spec.frame==.rows_prefix) .rows_prefix else .default;
            }
            if(!spec.partition_typed) for(spec.partition[0..spec.partition_count]) |id| if(generatedConstant(context,id)) {_=try generatedValue(context,id);};
            if(!spec.order_typed) for(spec.order[0..spec.order_count]) |key| if(generatedConstant(context,key.expr)) {_=try generatedValue(context,key.expr);};
            spec.partition_typed=true;spec.order_typed=true;spec.bounds_typed=true;
        }

        fn typeWindow(context:*const Context,scope:*const Scope,n:*ast.Node) Error!void {
            if(!scope.windows) return scope.window_error;
            if(n.distinct) return error.UnsupportedStatement;
            const spec=&context.pool.windows[n.window];
            try inheritWindow(context,spec,scope.window_defs,none);
            var inner=scope.*;inner.windows=false;inner.inside_window=true;
            const name=toName(context,n.name);
            const tile=types.same(name.slice(),"ntile");
            const ranking=rankWindowName(context,n) or tile;
            const offset_window=offsetWindowName(context,n);
            const value_window=valueWindowName(context,n);
            if(value_window) {
                try typeValueArguments(context,&inner,n);
            } else if(offset_window) {
                try typeOffsetArguments(context,&inner,n);
            } else if(tile) {
                try typeNtileArgument(context,&inner,n);
                if(n.c!=none) return error.UnsupportedStatement;
            } else if(ranking) {
                try typeRankArguments(context,&inner,n);
                if(n.c!=none) return error.UnsupportedStatement;
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
            try typeWindowSpec(context,scope,spec);
            if((spec.frame==.rows or spec.frame==.groups or spec.frame==.range) and !ranking and !offset_window and !value_window and (!repeatableWindowInput(context,n.b) or !repeatableWindowInput(context,n.c))) return error.UnsupportedStatement;
            n.func=.window_call;n.constant=false;
        }

        fn typeFunction(context: *const Context, scope: *const Scope, n: *ast.Node) Error!void {
            if(n.window!=none) return typeWindow(context,scope,n);
            if(valueWindowName(context,n)) {try typeValueArguments(context,scope,n);return error.WrongObjectType;}
            if(offsetWindowName(context,n)) {
                try typeOffsetArguments(context,scope,n);
                return error.WrongObjectType;
            }
            if(rankWindowName(context,n)) {try typeRankArguments(context,scope,n);return error.WrongObjectType;}
            const window_name=toName(context,n.name);
            if(types.same(window_name.slice(),"ntile")) {try typeNtileArgument(context,scope,n);return error.WrongObjectType;}
            switch (n.func) {
                // Bound internally (identity defaults, reg casts): already typed.
                .identity_next, .regclass_in, .regtype_in, .regclass_out, .regtype_out => {
                    n.constant = false;
                    return;
                },
                // Built by typePairAggregate with typed arguments.
                .aggregate_pair => return,
                else => {},
            }
            const agg = aggregateKind(context, n);
            if (agg != .none) return typeAggregate(context, scope, n, agg);
            if (n.distinct or n.c != none or n.star) return error.UndefinedFunction;
            // GREATEST/LEAST are grammar forms, not ordinary named functions.
            // GREATEST/LEAST and SQL-syntax calls (TRIM, POSITION) arrive bound.
            if (n.func == .none) n.func = functionName(context, n);
            var count: usize = 0;
            var item = n.b;
            while (item != none) : (item = context.node(item).next) {
                try typeExpr(context, scope, item);
                count += 1;
            }
            // lower(anyrange) / upper(anyrange) beside the string functions.
            if ((n.func == .lower or n.func == .upper) and count == 1 and types.isRange(context.node(n.b).ty)) n.func = if (n.func == .lower) .range_lower else .range_upper;
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
                .abs, .ceil, .floor, .trunc, .sign, .sqrt => {
                    const scaled=n.func==.trunc and count==2;
                    if(count!=1 and !scaled) return error.UndefinedFunction;
                    const first=n.b;const second=context.node(first).next;
                    const input=context.node(first).ty;
                    // TRUNC has additional native network-address overloads.
                    if(n.func==.trunc and count==1 and input==.unknown) return error.AmbiguousFunction;
                    switch(input){.unknown,.int2,.int4,.int8,.numeric,.float4,.float8=>{},else=>return error.UndefinedFunction}
                    if(scaled) {
                        if(input==.float4 or input==.float8) return error.UndefinedFunction;
                        const scale_type=context.node(second).ty;
                        if(scale_type!=.unknown and scale_type!=.int2 and scale_type!=.int4) return error.UndefinedFunction;
                    }
                    const target:ast.Type=if(scaled or input==.numeric) .numeric else if(n.func==.abs and input!=.unknown) input else .float8;
                    const argument=try convert(context,first,target,-1,.implicit);
                    const scale=if(scaled) try convert(context,second,.int4,-1,.implicit) else none;
                    context.node(argument).next=scale;if(scale!=none) context.node(scale).next=none;
                    n.b=argument;n.ty=target;
                    n.constant=isConstant(context,argument) and (scale==none or isConstant(context,scale));
                    n.planned_null=knownNull(context,argument) or (scale!=none and knownNull(context,scale));
                    if(n.planned_null) context.pool.planned_nulls=true;
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
                .lower, .upper, .initcap, .char_length, .octet_length, .bit_length, .substring, .btrim, .ltrim, .rtrim, .strpos, .replace,
                .left, .right, .repeat, .reverse, .lpad, .rpad, .split_part, .starts_with, .ascii, .chr, .translate, .concat, .concat_ws,
                .overlay, .to_hex => try typeStringFunction(context, n, count),
                .power, .ln, .log, .log10, .exp, .mod, .div, .pi, .degrees, .radians, .cbrt, .sin, .cos, .tan, .cot, .asin, .acos, .atan, .atan2, .gcd, .lcm, .scale, .min_scale, .trim_scale => try typeMathFunction(context, n, count),
                .extract, .extract_tz, .date_part, .date_part_tz, .date_trunc, .date_trunc_tz, .age, .age_tz, .justify_days, .justify_hours, .justify_interval, .make_date, .make_timestamp, .isfinite => try typeTemporalFunction(context, n, count),
                .overlaps, .overlaps_tz => try typeOverlaps(context, n, count),
                .aggregate_pair => unreachable,
                .normalize, .is_normalized => try bindSignature(context, n, if (count == 1) &[_]ast.Type{.text} else &[_]ast.Type{ .text, .text }, if (n.func == .normalize) .text else .boolean, true),
                .to_date => try bindSignature(context, n, &[_]ast.Type{ .text, .text }, .date, true),
                .to_number => try bindSignature(context, n, &[_]ast.Type{ .text, .text }, .numeric, true),
                // to_timestamp(text, text) or to_timestamp(double precision).
                .to_timestamp => try bindSignature(context, n, if (count == 1) &[_]ast.Type{.float8} else &[_]ast.Type{ .text, .text }, .timestamptz, true),
                .array_constructor, .array_subscript, .array_any, .array_length, .cardinality, .array_ndims, .array_dims, .array_lower, .array_upper,
                .array_append, .array_prepend, .array_cat, .array_to_string => try typeArrayFunction(context, n, count),
                .range_constructor, .range_lower, .range_upper, .isempty, .lower_inc, .upper_inc, .lower_inf, .upper_inf => try typeRangeFunction(context, n, count),
                .xmlparse => {
                    n.b = try convert(context, n.b, .text, -1, .implicit);
                    if (!value.stringType(context.node(n.b).ty)) return error.UndefinedFunction;
                    n.ty = .xml;
                    n.constant = isConstant(context, n.b);
                },
                .xmlserialize => {
                    // The argument must be xml (42804); the target a string type.
                    if (context.node(n.b).ty == .unknown) try coerce(context, n.b, .xml);
                    if (context.node(n.b).ty != .xml) return error.TypeMismatch;
                    if (!value.characterType(n.cast_type)) return error.CannotCoerce;
                    n.ty = n.cast_type;
                    n.constant = isConstant(context, n.b);
                },
                .xml_is_well_formed, .xml_is_well_formed_document, .xml_is_well_formed_content => try bindSignature(context, n, &[_]ast.Type{.text}, .boolean, true),
                .point_constructor => try bindSignature(context, n, &[_]ast.Type{ .float8, .float8 }, .point, true),
                .box_constructor => try bindSignature(context, n, &[_]ast.Type{ .point, .point }, .box, true),
                .area, .width, .height => try bindSignature(context, n, &[_]ast.Type{.box}, .float8, true),
                .center => try bindSignature(context, n, &[_]ast.Type{.box}, .point, true),
                .inet_host, .masklen, .inet_family, .inet_network, .broadcast, .netmask => {
                    // One inet argument (cidr converts implicitly).
                    if (count != 1) return error.UndefinedFunction;
                    n.b = try convert(context, n.b, .inet, -1, .implicit);
                    if (context.node(n.b).ty != .inet) return error.UndefinedFunction;
                    n.ty = switch (n.func) {
                        .inet_host => .text,
                        .masklen, .inet_family => .int4,
                        .inet_network => .cidr,
                        else => .inet,
                    };
                    n.constant = isConstant(context, n.b);
                },
            }
        }

        fn geometricType(ty: ast.Type) bool {
            return ty == .point or ty == .box;
        }

        /// point <-> point (float8), point ~= point, box ~= box, box @>
        /// point, point <@ box and box && box; an untyped side takes the
        /// operator's other operand type.
        fn geometricOperator(context: *const Context, n: *ast.Node) Error!void {
            const wanted: [2]ast.Type = switch (n.op) {
                .contains => .{ .box, .point },
                .contained => .{ .point, .box },
                .overlap => .{ .box, .box },
                .distance => .{ .point, .point },
                .same => blk: {
                    const known = if (context.node(n.a).ty != .unknown) context.node(n.a).ty else context.node(n.b).ty;
                    if (!geometricType(known)) return error.UndefinedFunction;
                    break :blk .{ known, known };
                },
                else => return error.UndefinedFunction,
            };
            for ([_]*u16{ &n.a, &n.b }, wanted) |side, target| {
                if (context.node(side.*).ty == .unknown) try coerce(context, side.*, target);
                if (context.node(side.*).ty != target) return error.UndefinedFunction;
            }
            n.ty = if (n.op == .distance) .float8 else .boolean;
        }

        fn networkType(ty: ast.Type) bool {
            return ty == .inet or ty == .cidr;
        }

        /// inet << <<= >> >>= && inet (cidr converts implicitly; an untyped
        /// side is inet).
        fn networkOperator(context: *const Context, n: *ast.Node) Error!void {
            if (context.node(n.a).ty == .unknown) try coerce(context, n.a, .inet);
            if (context.node(n.b).ty == .unknown) try coerce(context, n.b, .inet);
            if (!networkType(context.node(n.a).ty) or !networkType(context.node(n.b).ty)) return error.UndefinedFunction;
            n.a = try convert(context, n.a, .inet, -1, .implicit);
            n.b = try convert(context, n.b, .inet, -1, .implicit);
            n.ty = .boolean;
        }

        // ---- ranges (B11 advanced types) ------------------------------------

        fn rangeNamed(context: *const Context, n: *const ast.Node) ?ast.Type {
            const name = toName(context, n.name);
            for ([_]ast.Type{ .int4range, .int8range, .numrange, .daterange, .tsrange, .tstzrange }) |ty| {
                if (types.same(name.slice(), types.typeInfo(types.dataTypeOf(ty)).name)) return ty;
            }
            return null;
        }

        fn typeRangeFunction(context: *const Context, n: *ast.Node, count: usize) Error!void {
            if (n.func == .range_constructor) {
                // range(lower, upper [, flags]): bounds in the subtype.
                const range_type = rangeNamed(context, n) orelse return error.UndefinedFunction;
                const subtype = types.rangeSubtype(range_type).?;
                if (count != 2 and count != 3) return error.UndefinedFunction;
                var first = n.b;
                var second = context.node(first).next;
                var third = context.node(second).next;
                first = try convert(context, first, subtype, -1, .implicit);
                second = try convert(context, second, subtype, -1, .implicit);
                if (third != none) third = try convert(context, third, .text, -1, .implicit);
                if (third != none and !value.stringType(context.node(third).ty)) return error.UndefinedFunction;
                context.node(first).next = second;
                context.node(second).next = third;
                if (third != none) context.node(third).next = none;
                n.b = first;
                n.ty = range_type;
                n.constant = listConstant(context, n.b);
                return;
            }
            if (count != 1) return error.UndefinedFunction;
            const ty = context.node(n.b).ty;
            if (ty == .unknown) return error.TypeMismatch;
            const subtype = types.rangeSubtype(ty) orelse return error.UndefinedFunction;
            n.ty = switch (n.func) {
                .range_lower, .range_upper => subtype,
                else => .boolean,
            };
            n.constant = isConstant(context, n.b);
        }

        /// Range operators: both operands one range type (an untyped side
        /// takes the other's); @> and <@ also take an element of the
        /// subtype. + * - give the range type, the others boolean.
        fn rangeOperator(context: *const Context, n: *ast.Node) Error!void {
            const left = context.node(n.a).ty;
            const right = context.node(n.b).ty;
            if (n.op == .contains and types.isRange(left) and right != .unknown and !types.isRange(right)) {
                n.b = try convert(context, n.b, types.rangeSubtype(left).?, -1, .implicit);
                n.ty = .boolean;
                return;
            }
            if (n.op == .contained and types.isRange(right) and left != .unknown and !types.isRange(left)) {
                n.a = try convert(context, n.a, types.rangeSubtype(right).?, -1, .implicit);
                n.ty = .boolean;
                return;
            }
            if (left == .unknown) try coerce(context, n.a, right);
            if (right == .unknown) try coerce(context, n.b, left);
            const ty = context.node(n.a).ty;
            if (!types.isRange(ty) or context.node(n.b).ty != ty) return error.UndefinedFunction;
            n.ty = switch (n.op) {
                .add, .sub, .mul => ty,
                .contains, .contained, .overlap, .shift_left, .shift_right, .over_left, .over_right, .adjacent => .boolean,
                else => return error.UndefinedFunction,
            };
        }

        // ---- arrays (B11 advanced types) ------------------------------------

        const ArrayConcat = enum { operator, cat, append, prepend };

        /// The array type of `||` / array_cat / array_append / array_prepend
        /// (anycompatiblearray with anycompatiblearray or anycompatible),
        /// converting both operands. An untyped operand of `||` or array_cat
        /// is the other operand's array type.
        fn arrayConcatTypes(context: *const Context, first: *u16, second: *u16, kind_in: ArrayConcat) Error!ast.Type {
            const left = context.node(first.*).ty;
            const right = context.node(second.*).ty;
            const kind: ArrayConcat = if (kind_in != .operator) kind_in else if (types.isArray(left))
                (if (types.isArray(right) or right == .unknown) ArrayConcat.cat else .append)
            else if (left == .unknown) .cat else .prepend;
            switch (kind) {
                .cat => {
                    if (left == .unknown and right == .unknown) return error.TypeMismatch;
                    const array_ty = if (left == .unknown) right else if (right == .unknown) left else value.common(left, right) orelse return error.UndefinedFunction;
                    if (!types.isArray(array_ty)) return error.UndefinedFunction;
                    first.* = try convert(context, first.*, array_ty, -1, .implicit);
                    second.* = try convert(context, second.*, array_ty, -1, .implicit);
                    return array_ty;
                },
                .append, .prepend => {
                    const array_at = if (kind == .append) first else second;
                    const element_at = if (kind == .append) second else first;
                    const array_ty = context.node(array_at.*).ty;
                    const element_ty = context.node(element_at.*).ty;
                    if (array_ty != .unknown and !types.isArray(array_ty)) return error.UndefinedFunction;
                    if (types.isArray(element_ty)) return error.UndefinedFunction;
                    const element = if (array_ty == .unknown)
                        (if (element_ty == .unknown) return error.TypeMismatch else element_ty)
                    else if (element_ty == .unknown) types.elementType(array_ty).? else value.common(types.elementType(array_ty).?, element_ty) orelse return error.UndefinedFunction;
                    const result = types.arrayType(element) orelse return error.UndefinedFunction;
                    array_at.* = try convert(context, array_at.*, result, -1, .implicit);
                    element_at.* = try convert(context, element_at.*, element, -1, .implicit);
                    return result;
                },
                .operator => unreachable,
            }
        }

        /// anyarray @> <@ && anyarray: one array type (an untyped side
        /// takes the other's); unknown on both sides is ambiguous.
        fn arrayContainment(context: *const Context, n: *ast.Node) Error!void {
            const left = context.node(n.a).ty;
            const right = context.node(n.b).ty;
            if (left == .unknown and right == .unknown) return error.AmbiguousFunction;
            if (left == .unknown) try coerce(context, n.a, right);
            if (right == .unknown) try coerce(context, n.b, left);
            const ty = context.node(n.a).ty;
            if (!types.isArray(ty) or context.node(n.b).ty != ty) return error.UndefinedFunction;
            n.ty = .boolean;
        }

        /// An anyarray argument: untyped input cannot resolve the polymorphic
        /// type (42804), other non-array types have no such function (42883).
        fn arrayArgument(context: *const Context, id: u16) Error!void {
            const ty = context.node(id).ty;
            if (ty == .unknown) return error.TypeMismatch;
            if (!types.isArray(ty)) return error.UndefinedFunction;
        }

        /// Converts the `next`-linked list after `owner_first` to `target` in
        /// `mode`, relinking cast nodes in place.
        fn convertTail(context: *const Context, previous_in: u16, target: ast.Type, mode: value.Context) Error!void {
            var previous = previous_in;
            var item = context.node(previous).next;
            while (item != none) {
                const next = context.node(item).next;
                const converted = try convert(context, item, target, -1, mode);
                if (converted != item) {
                    context.node(converted).next = next;
                    context.node(item).next = none;
                    context.node(previous).next = converted;
                }
                previous = converted;
                item = next;
            }
        }

        fn typeArrayFunction(context: *const Context, n: *ast.Node, count: usize) Error!void {
            switch (n.func) {
                .array_constructor => {
                    // ARRAY[...]: the common type of the elements (untyped
                    // ones are text), or of the sub-arrays (multi-dimensional).
                    if (count == 0) return error.IndeterminateDatatype;
                    var common: ast.Type = .unknown;
                    var nested = false;
                    var item = n.b;
                    while (item != none) : (item = context.node(item).next) {
                        if (types.isArray(context.node(item).ty)) nested = true;
                        try unifyInto(&common, context.node(item).ty);
                    }
                    if (nested) {
                        if (!types.isArray(common)) return error.TypeMismatch;
                        n.b = try convertList(context, n.b, common);
                        n.ty = common;
                    } else {
                        if (common == .unknown) common = .text;
                        n.b = try convertList(context, n.b, common);
                        n.ty = types.arrayType(common) orelse return error.UndefinedObject;
                    }
                    n.constant = listConstant(context, n.b);
                },
                .array_subscript => {
                    const base_ty = context.node(n.b).ty;
                    const element = types.elementType(base_ty) orelse return error.TypeMismatch;
                    // Subscripts are int4 by assignment (array subscript
                    // must have type integer: 42804).
                    try convertTail(context, n.b, .int4, .assignment);
                    const layout = array_module.Subscripts.decode(n.integer);
                    n.ty = if (layout.slice()) base_ty else element;
                    n.typmod = outputTypmod(context, n.b);
                    n.constant = listConstant(context, n.b);
                },
                .array_any => {
                    var left = n.b;
                    var right = context.node(left).next;
                    if (context.node(right).ty == .unknown) {
                        const left_ty = context.node(left).ty;
                        try coerce(context, right, types.arrayType(if (left_ty == .unknown) .text else left_ty) orelse return error.UndefinedFunction);
                    }
                    const element = types.elementType(context.node(right).ty) orelse return error.WrongObjectType;
                    if (context.node(left).ty == .unknown) try coerce(context, left, element);
                    const left_ty = context.node(left).ty;
                    if (left_ty == .json or element == .json) return error.UndefinedFunction;
                    if (left_ty != element and !(value.integral(left_ty) and value.integral(element))) {
                        const target = value.comparisonType(left_ty, element) orelse return error.UndefinedFunction;
                        left = try convert(context, left, target, -1, .implicit);
                        if (target != element) right = try convert(context, right, types.arrayType(target) orelse return error.UndefinedFunction, -1, .implicit);
                    }
                    context.node(left).next = right;
                    context.node(right).next = none;
                    n.b = left;
                    n.ty = .boolean;
                    n.constant = isConstant(context, left) and isConstant(context, right);
                },
                .cardinality, .array_ndims, .array_dims => {
                    if (count != 1) return error.UndefinedFunction;
                    try arrayArgument(context, n.b);
                    n.ty = if (n.func == .array_dims) .text else .int4;
                    n.constant = isConstant(context, n.b);
                },
                .array_length, .array_lower, .array_upper => {
                    if (count != 2) return error.UndefinedFunction;
                    try arrayArgument(context, n.b);
                    try convertTail(context, n.b, .int4, .implicit);
                    n.ty = .int4;
                    n.constant = listConstant(context, n.b);
                },
                .array_append, .array_prepend, .array_cat => {
                    if (count != 2) return error.UndefinedFunction;
                    var first = n.b;
                    var second = context.node(first).next;
                    n.ty = try arrayConcatTypes(context, &first, &second, switch (n.func) {
                        .array_append => .append,
                        .array_prepend => .prepend,
                        else => .cat,
                    });
                    context.node(first).next = second;
                    context.node(second).next = none;
                    n.b = first;
                    n.constant = isConstant(context, first) and isConstant(context, second);
                },
                .array_to_string => {
                    if (count != 2 and count != 3) return error.UndefinedFunction;
                    try arrayArgument(context, n.b);
                    try convertTail(context, n.b, .text, .implicit);
                    var item = context.node(n.b).next;
                    while (item != none) : (item = context.node(item).next) if (!value.stringType(context.node(item).ty)) return error.UndefinedFunction;
                    n.ty = .text;
                    n.constant = listConstant(context, n.b);
                },
                else => unreachable,
            }
        }

        /// overlaps(start, end|interval, start, end|interval): timestamp
        /// when no argument is timestamptz and one is timestamp, else
        /// timestamptz (dates prefer it). Not strict: overlaps_timestamp
        /// has its own NULL rules. The interval forms of timestamptz are
        /// STABLE (zone-dependent addition).
        fn typeOverlaps(context: *const Context, n: *ast.Node, count: usize) Error!void {
            if (count != 4) return error.UndefinedFunction;
            var zoned = false;
            var plain = false;
            var interval = false;
            var item = n.b;
            var index: usize = 0;
            while (item != none) : ({
                item = context.node(item).next;
                index += 1;
            }) switch (context.node(item).ty) {
                .timestamptz => zoned = true,
                .timestamp => plain = true,
                .date => {},
                .interval => if (index % 2 == 1) {
                    interval = true;
                } else return error.UndefinedFunction,
                // An unknown end could be a datetime or an interval.
                .unknown => if (index % 2 == 1 and !knownNull(context, item)) return error.AmbiguousFunction,
                else => return error.UndefinedFunction,
            };
            const start: ast.Type = if (zoned or !plain) .timestamptz else .timestamp;
            var params: [4]ast.Type = .{ start, start, start, start };
            item = n.b;
            index = 0;
            while (item != none) : ({
                item = context.node(item).next;
                index += 1;
            }) if (context.node(item).ty == .interval) {
                params[index] = .interval;
            };
            try bindSignature(context, n, &params, .boolean, false);
            n.func = if (start == .timestamptz and interval) .overlaps_tz else .overlaps;
        }

        /// Date/time functions; timestamptz overloads (date arguments prefer
        /// timestamptz, the datetime category's preferred type) are STABLE.
        fn typeTemporalFunction(context: *const Context, n: *ast.Node, count: usize) Error!void {
            const T = ast.Type;
            switch (n.func) {
                .extract, .extract_tz, .date_part, .date_part_tz => {
                    if (count != 2) return error.UndefinedFunction;
                    const source = argumentType(context, n, 1);
                    const extract = n.func == .extract or n.func == .extract_tz;
                    const ty: T = switch (source) {
                        .unknown => return error.AmbiguousFunction,
                        .date => if (extract) .date else .timestamp,
                        .timestamp, .timestamptz, .interval => source,
                        else => return error.UndefinedFunction,
                    };
                    try bindSignature(context, n, &[_]T{ .text, ty }, if (extract) .numeric else .float8, true);
                    n.func = if (ty == .timestamptz) (if (extract) .extract_tz else .date_part_tz) else (if (extract) .extract else .date_part);
                },
                .date_trunc, .date_trunc_tz => {
                    if (count != 2) return error.UndefinedFunction;
                    const source = argumentType(context, n, 1);
                    const ty: T = switch (source) {
                        .unknown => return error.AmbiguousFunction,
                        .date, .timestamptz => .timestamptz,
                        .timestamp, .interval => source,
                        else => return error.UndefinedFunction,
                    };
                    try bindSignature(context, n, &[_]T{ .text, ty }, ty, true);
                    n.func = if (ty == .timestamptz) .date_trunc_tz else .date_trunc;
                },
                .age, .age_tz => {
                    if (count != 1 and count != 2) return error.UndefinedFunction;
                    var zoned = false;
                    var plain = false;
                    var item = n.b;
                    while (item != none) : (item = context.node(item).next) switch (context.node(item).ty) {
                        .timestamptz => zoned = true,
                        .timestamp => plain = true,
                        .date, .unknown => {},
                        else => return error.UndefinedFunction,
                    };
                    const ty: T = if (zoned or !plain) .timestamptz else .timestamp;
                    try bindSignature(context, n, if (count == 1) &[_]T{ty} else &[_]T{ ty, ty }, .interval, true);
                    // age(x) measures from current_date: STABLE.
                    n.func = if (ty == .timestamptz or count == 1) .age_tz else .age;
                },
                .justify_days, .justify_hours, .justify_interval => try bindSignature(context, n, &[_]T{.interval}, .interval, true),
                .make_date => try bindSignature(context, n, &[_]T{ .int4, .int4, .int4 }, .date, true),
                .make_timestamp => try bindSignature(context, n, &[_]T{ .int4, .int4, .int4, .int4, .int4, .float8 }, .timestamp, true),
                .isfinite => {
                    if (count != 1) return error.UndefinedFunction;
                    const ty = argumentType(context, n, 0);
                    switch (ty) {
                        .unknown => return error.AmbiguousFunction,
                        .date, .timestamp, .timestamptz, .interval => {},
                        else => return error.UndefinedFunction,
                    }
                    try bindSignature(context, n, &[_]T{ty}, .boolean, true);
                },
                else => unreachable,
            }
        }

        /// numeric when any argument is numeric and none is real/double,
        /// else double precision (PostgreSQL prefers float8 for integers).
        fn floatOrNumeric(context: *const Context, n: *const ast.Node) Error!ast.Type {
            var numeric_seen = false;
            var item = n.b;
            while (item != none) : (item = context.node(item).next) {
                switch (context.node(item).ty) {
                    .float4, .float8 => return .float8,
                    .numeric => numeric_seen = true,
                    .unknown, .int2, .int4, .int8 => {},
                    else => return error.UndefinedFunction,
                }
            }
            return if (numeric_seen) .numeric else .float8;
        }

        /// mod/gcd/lcm: the integer or numeric type of both operands.
        fn exactPair(context: *const Context, n: *const ast.Node, smallest: ast.Type) Error!ast.Type {
            const left = argumentType(context, n, 0);
            const right = argumentType(context, n, 1);
            if (left == .unknown and right == .unknown) return error.AmbiguousFunction;
            var result: ast.Type = smallest;
            for ([_]ast.Type{ left, right }) |ty| switch (ty) {
                .unknown => {},
                .int2, .int4, .int8, .numeric => if (value.numericRank(ty) > value.numericRank(result)) {
                    result = ty;
                },
                else => return error.UndefinedFunction,
            };
            return result;
        }

        /// PostgreSQL mathematical functions (float8 and numeric overloads).
        fn typeMathFunction(context: *const Context, n: *ast.Node, count: usize) Error!void {
            const T = ast.Type;
            switch (n.func) {
                .pi => try bindSignature(context, n, &[_]T{}, .float8, true),
                .ln, .log10, .exp => {
                    if (count != 1) return error.UndefinedFunction;
                    const ty = try floatOrNumeric(context, n);
                    try bindSignature(context, n, &[_]T{ty}, ty, true);
                },
                .log => {
                    if (count == 1) {
                        const ty = try floatOrNumeric(context, n);
                        try bindSignature(context, n, &[_]T{ty}, ty, true);
                    } else try bindSignature(context, n, &[_]T{ .numeric, .numeric }, .numeric, true);
                },
                .power => {
                    if (count != 2) return error.UndefinedFunction;
                    const ty = try floatOrNumeric(context, n);
                    try bindSignature(context, n, &[_]T{ ty, ty }, ty, true);
                },
                .cbrt, .degrees, .radians, .sin, .cos, .tan, .cot, .asin, .acos, .atan => try bindSignature(context, n, &[_]T{.float8}, .float8, true),
                .atan2 => try bindSignature(context, n, &[_]T{ .float8, .float8 }, .float8, true),
                .mod, .gcd, .lcm => {
                    if (count != 2) return error.UndefinedFunction;
                    const ty = try exactPair(context, n, if (n.func == .mod) .int2 else .int4);
                    try bindSignature(context, n, &[_]T{ ty, ty }, ty, true);
                },
                .div => try bindSignature(context, n, &[_]T{ .numeric, .numeric }, .numeric, true),
                .scale, .min_scale => try bindSignature(context, n, &[_]T{.numeric}, .int4, true),
                .trim_scale => try bindSignature(context, n, &[_]T{.numeric}, .numeric, true),
                else => unreachable,
            }
        }

        // ---- B11 builtins ----------------------------------------------------

        /// Binds a call to one fixed signature: an unknown argument takes the
        /// parameter type, a typed one needs an implicit cast (42883). A
        /// strict call with a syntactic NULL argument is planned NULL.
        fn bindSignature(context: *const Context, n: *ast.Node, params: []const ast.Type, result: ast.Type, strict: bool) Error!void {
            var args: [8]u16 = undefined;
            var count: usize = 0;
            var item = n.b;
            while (item != none) : (item = context.node(item).next) {
                if (count == args.len) return error.UndefinedFunction;
                args[count] = item;
                count += 1;
            }
            if (count != params.len) return error.UndefinedFunction;
            for (params, args[0..count]) |target, arg| {
                const ty = context.node(arg).ty;
                if (ty != .unknown and !value.castable(ty, target, .implicit)) return error.UndefinedFunction;
            }
            for (params, args[0..count]) |target, *arg| arg.* = try convert(context, arg.*, target, -1, .implicit);
            var constant = true;
            var planned = false;
            for (args[0..count], 0..) |arg, index| {
                context.node(arg).next = if (index + 1 < count) args[index + 1] else none;
                constant = constant and isConstant(context, arg);
                planned = planned or knownNull(context, arg);
            }
            if (count != 0) n.b = args[0];
            n.ty = result;
            n.constant = constant;
            n.planned_null = strict and planned;
            if (n.planned_null) context.pool.planned_nulls = true;
        }

        fn argumentType(context: *const Context, n: *const ast.Node, index: usize) ast.Type {
            var item = n.b;
            for (0..index) |_| item = context.node(item).next;
            return context.node(item).ty;
        }

        /// PostgreSQL string functions (pg_proc signatures over text/int4).
        fn typeStringFunction(context: *const Context, n: *ast.Node, count: usize) Error!void {
            const T = ast.Type;
            switch (n.func) {
                .lower, .upper, .initcap, .reverse => try bindSignature(context, n, &[_]T{.text}, .text, true),
                // octet_length(bpchar) counts CHAR(n) padding; the others read
                // CHAR(n) through text, which drops trailing spaces.
                .char_length, .octet_length, .bit_length, .ascii => try bindSignature(context, n, &[_]T{if (n.func == .octet_length and count == 1 and argumentType(context, n, 0) == .bpchar) .bpchar else .text}, .int4, true),
                .substring => {
                    // Unknown or text arguments after the first select the
                    // regular-expression overloads substring(text,text[,text]),
                    // which are not provided. With only NULL literals there the
                    // strict result is NULL text under either overload.
                    if (count >= 2 and count <= 3) {
                        var regex = true;
                        var concrete = false;
                        var item = context.node(n.b).next;
                        while (item != none) : (item = context.node(item).next) {
                            const ty = context.node(item).ty;
                            if (ty != .unknown and !value.stringType(ty)) regex = false;
                            if (!knownNull(context, item)) concrete = true;
                        }
                        if (regex and concrete) return error.UnsupportedStatement;
                    }
                    try bindSignature(context, n, if (count == 2) &[_]T{ .text, .int4 } else &[_]T{ .text, .int4, .int4 }, .text, true);
                },
                .btrim, .ltrim, .rtrim => try bindSignature(context, n, if (count == 1) &[_]T{.text} else &[_]T{ .text, .text }, .text, true),
                .strpos => try bindSignature(context, n, &[_]T{ .text, .text }, .int4, true),
                .starts_with => try bindSignature(context, n, &[_]T{ .text, .text }, .boolean, true),
                .replace, .translate => try bindSignature(context, n, &[_]T{ .text, .text, .text }, .text, true),
                .left, .right, .repeat => try bindSignature(context, n, &[_]T{ .text, .int4 }, .text, true),
                .lpad, .rpad => try bindSignature(context, n, if (count == 2) &[_]T{ .text, .int4 } else &[_]T{ .text, .int4, .text }, .text, true),
                .split_part => try bindSignature(context, n, &[_]T{ .text, .text, .int4 }, .text, true),
                .chr => try bindSignature(context, n, &[_]T{.int4}, .text, true),
                .overlay => try bindSignature(context, n, if (count == 3) &[_]T{ .text, .text, .int4 } else &[_]T{ .text, .text, .int4, .int4 }, .text, true),
                .to_hex => {
                    if (count != 1) return error.UndefinedFunction;
                    const ty = argumentType(context, n, 0);
                    try bindSignature(context, n, &[_]T{if (ty == .int8) .int8 else .int4}, .text, true);
                },
                .concat, .concat_ws => {
                    // VARIADIC "any": at least one variadic argument; values
                    // print through their output functions (STABLE, not strict).
                    if (count < (if (n.func == .concat) @as(usize, 1) else 2)) return error.UndefinedFunction;
                    var item = n.b;
                    var constant = true;
                    var index: usize = 0;
                    while (item != none) : (item = context.node(item).next) {
                        if (context.node(item).ty == .unknown) try coerce(context, item, .text);
                        if (index == 0 and n.func == .concat_ws and !value.castable(context.node(item).ty, .text, .implicit)) return error.UndefinedFunction;
                        constant = constant and isConstant(context, item);
                        index += 1;
                    }
                    if (n.func == .concat_ws and context.node(n.b).ty != .text) {
                        const separator = n.b;
                        const rest = context.node(separator).next;
                        const converted = try convert(context, separator, .text, -1, .implicit);
                        context.node(converted).next = rest;
                        if (converted != separator) context.node(separator).next = none;
                        n.b = converted;
                    }
                    n.ty = .text;
                    n.constant = constant;
                },
                else => unreachable,
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

        fn immutableGenerated(context:*const Context,id:u16) bool {
            return immutableExpression(context,id,false);
        }
        fn immutableExpression(context: *const Context, id: u16, allow_aggregates:bool) bool {
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
                .scalar_subquery, .exists_subquery, .in_subquery => return false,
                .aggregate => if(!allow_aggregates) return false,
                .row_compare => {
                    if (n.a != none) return true;
                    var item = n.b;
                    while (item != none) : (item = context.node(item).next) {
                        const pair = context.node(item);
                        if ((n.op == .eq or n.op == .ne) and (knownNull(context, pair.a) or knownNull(context, pair.b))) continue;
                        if (!immutableExpression(context, pair.a, allow_aggregates) or !immutableExpression(context, pair.b, allow_aggregates)) return false;
                    }
                    return true;
                },
                else => {},
            }
            if (!immutableExpression(context, n.a, allow_aggregates) or !immutableExpression(context, n.c, allow_aggregates)) return false;
            if (!listOwner(n.kind)) return immutableExpression(context, n.b, allow_aggregates);
            var item = n.b;
            while (item != none) : (item = context.node(item).next) if (!immutableExpression(context, item, allow_aggregates)) return false;
            return true;
        }

        fn generatedConstant(context: *const Context, id: u16) bool {
            return id != none and context.node(id).ty != .unknown and isConstant(context, id) and immutableGenerated(context, id);
        }

        fn constantColumn(context:*const Context,n:*const ast.Node) Error!bool {
            try context.session.checkpoint();
            const p=context.planning_plan orelse return false;
            if(n.level!=0 or n.relation>=p.source_count) return false;
            for(p.sources[0..p.source_count]) |source| if(source.join==.left or source.join==.right or source.join==.full) return false;
            const source=p.sources[n.relation];if(source.plan==none) return false;
            if(source.cte!=no_cte) {const cte=&plansOf(context).ctes[source.cte];if(cte.references>1 or cte.recursive) return false;}
            const child=&plansOf(context).items[source.plan];
            if(!child.constant_source_safe or child.set_op!=.none or child.grouped or child.window_count!=0 or child.correlated or
                n.column>=child.count or !child.constant_known[n.column]) return false;
            // A dependency set, not recursive re-proof of a shared expression
            // DAG, invalidates a value when later consumers materialize a CTE.
            const dependencies=&child.constant_dependencies[n.column];
            for(dependencies,0..) |needed,index| if(needed) {
                const cte=&plansOf(context).ctes[index];if(cte.references>1 or cte.recursive) return false;
            };
            if(context.constant_dependencies) |out| {
                for(dependencies,0..) |needed,index| out[index]=out[index] or needed;
                if(source.cte!=no_cte) out[source.cte]=true;
            }
            return true;
        }
        fn planningEvalContext(context:*const Context) E.Context {
            var out:E.Context=.{.source=context.source,.pool=context.pool,.session=context.session};
            if(context.planning_plan) |p| for(p.sources[0..p.source_count],0..) |source,index| {
                if(source.plan!=none) {const child=&plansOf(context).items[source.plan];out.tuple[index]=&child.constant_outputs;}
            };
            return out;
        }
        fn generatedValue(context: *const Context, id: u16) Error!V.Cell {
            const eval_context=planningEvalContext(context);
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

        /// Binds a CHECK constraint's text over the table row (relation 0):
        /// boolean (42804), no subquery (0A000), aggregate (42803) or window
        /// function (42P20).
        fn bindCheckText(context: *const Context, text: []const u8, table: usize) Error!u16 {
            var sub = context.*;
            sub.source = text;
            const id = try P.parseExpression(text, context.pool);
            try generatedSubqueries(&sub, id);
            const scope = tableScope(&sub, table);
            try typeExpr(&sub, &scope, id);
            try booleanArgument(&sub, id);
            markStoredSources(&sub, id, -1);
            return id;
        }

        /// Every CHECK constraint of the table, by constraint index.
        fn bindChecks(context: *const Context, index: usize, entry: *const S.Table, checks: *[config.table_constraints]u16) Error!void {
            for (entry.constraints[0..entry.constraint_count], 0..) |*constraint, position| {
                if (constraint.kind == .check) checks[position] = try bindCheckText(context, constraint.expression.slice(), index);
            }
        }

        /// The flagged CHECK constraints of a table (ALTER TABLE re-checks).
        pub fn bindFlaggedChecks(context: *const Context, index: usize, flags: *const [config.table_constraints]bool, checks: *[config.table_constraints]u16) Error!void {
            const entry = &context.tables[index];
            for (entry.constraints[0..entry.constraint_count], 0..) |*constraint, position| {
                if (constraint.kind == .check and flags[position]) checks[position] = try bindCheckText(context, constraint.expression.slice(), index);
            }
        }

        /// CHECK expressions of a table definition just written to storage
        /// (CREATE / ALTER), before its transaction publishes.
        pub fn validateConstraints(context: *const Context, index: usize) Error!void {
            var checks: [config.table_constraints]u16 = @splat(none);
            try bindChecks(context, index, &context.tables[index], &checks);
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

        /// PostgreSQL's primary-key constraint name `<table>_pkey`, or the
        /// name given with CONSTRAINT.
        fn primaryKeyName(entry: *const S.Table) Error!V.Name {
            if (S.primaryConstraint(entry)) |index| return entry.constraints[index].name;
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
                out.arbiter = blk: {
                    if (entry.primary_column != null) {
                        const name = try primaryKeyName(entry);
                        if (types.same(wanted.slice(), name.slice())) break :blk .primary;
                    }
                    for (entry.constraints[0..entry.constraint_count], 0..) |*constraint, position| {
                        if (!types.same(wanted.slice(), constraint.name.slice())) continue;
                        if (!S.scannedUnique(entry, constraint)) return error.UndefinedObject;
                        if (constraint.deferrable) return error.WrongObjectType;
                        break :blk .{ .constraint = position };
                    }
                    for (entry.indexes[0..entry.index_count], 0..) |*candidate, which| {
                        if (types.same(wanted.slice(), candidate.name.slice()) and candidate.unique) break :blk .{ .index = which };
                    }
                    return error.UndefinedObject;
                };
            } else if (conflict.column_count != 0) {
                var used: [config.columns]bool = @splat(false);
                for (conflict.columns[0..conflict.column_count]) |ident| used[try columnIndex(context, entry, ident)] = true;
                out.arbiter = try inferArbiter(entry, &used);
            } else if (conflict.action == .update) return error.Syntax else {
                out.arbiter = .any;
            }
            out.action = conflict.action;
            out.inferred = conflict.constraint == null and conflict.column_count == 0;
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
            try bindChecks(context, index, entry, &update.checks);
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

        fn foldableScalar(context: *const Context, id: u16) Error!bool {
            if(id==none) return true;
            const n=context.node(id);
            if(n.planned_null) return false;
            if(n.kind==.column) return (try constantColumn(context,n));
            if(n.kind==.case_expr) {
                if(n.a!=none and !(try foldableScalar(context,n.a))) return false;
                const operand=if(n.a!=none) generatedValue(context,n.a) catch |err| {if(planningControlError(err)) return err;return false;} else V.Cell.null_value;
                var arm=n.b;
                while(arm!=none):(arm=context.node(arm).next) {
                    const entry=context.node(arm);if(!(try foldableScalar(context,entry.a))) return false;
                    const candidate=generatedValue(context,entry.a) catch |err| {if(planningControlError(err)) return err;return false;};
                    const hit=if(n.a==none) candidate==.boolean and candidate.boolean else E.compareOp(.eq,&operand,&candidate)==true;
                    if(hit) return (try foldableScalar(context,entry.b));
                }
                return (try foldableScalar(context,n.c));
            }
            if(n.kind==.coalesce) {
                var item=n.b;
                while(item!=none):(item=context.node(item).next) {
                    if(!(try foldableScalar(context,item))) return false;
                    const cell=generatedValue(context,item) catch |err| {if(planningControlError(err)) return err;return false;};
                    if(cell!=.null_value) return true;
                }
                return true;
            }
            if(n.kind==.and_op or n.kind==.or_op) {
                if(!(try foldableScalar(context,n.a))) return false;
                const cell=generatedValue(context,n.a) catch |err| {if(planningControlError(err)) return err;return false;};
                if(cell==.boolean and cell.boolean==(n.kind==.or_op)) return true;
                return (try foldableScalar(context,n.b));
            }
            switch(n.kind) {
                .scalar_subquery,.exists_subquery,.in_subquery,.aggregate,.default_value,.values_row,.row_constructor,.row_compare,.row_in=>return false,
                .function=>if(!ast.immutableFunction(n.func)) return false,
                else=>{},
            }
            if(!immutableGenerated(context,id)) return false;
            if(!n.constant and context.planning_plan==null) return false;
            if(!(try foldableScalar(context,n.a)) or !(try foldableScalar(context,n.c))) return false;
            if(!listOwner(n.kind)) return (try foldableScalar(context,n.b));
            var item=n.b;while(item!=none):(item=context.node(item).next) if(!(try foldableScalar(context,item))) return false;
            return true;
        }

        fn planningControlError(err:Error) bool {
            return err==error.QueryCanceled or err==error.QueryWorkLimit;
        }

        fn constantTruth(context:*const Context,id:u16) Error!?V.Cell {
            if(id==none) return null;
            if((try foldableScalar(context,id))) return try generatedValue(context,id);
            const n=context.node(id);
            if(n.planned_null) return V.Cell.null_value;
            if(n.kind==.and_op or n.kind==.or_op) {
                const a=try constantTruth(context,n.a);
                if(a) |v| if(v==.boolean and v.boolean==(n.kind==.or_op)) return v;
                const b=try constantTruth(context,n.b);
                if(b) |v| if(v==.boolean and v.boolean==(n.kind==.or_op)) return v;
            }
            return null;
        }

        // A strict NULL record comparison discards runtime evaluation, but
        // PostgreSQL still simplifies immutable constant expressions first.
        // Never evaluate clocks, sequences, aggregates or subqueries here.
        fn validateDiscardedConstants(context: *const Context, id: u16) Error!void {
            if (id == none) return;
            const n = context.node(id);
            const eval_context=planningEvalContext(context);
            if ((try foldableScalar(context, id))) { _ = try E.eval(&eval_context, id); return; }
            if(n.kind==.and_op or n.kind==.or_op) {
                try validateDiscardedConstants(context,n.a);
                if(try constantTruth(context,n.a)) |v| if(v==.boolean and v.boolean==(n.kind==.or_op)) return;
                return validateDiscardedConstants(context,n.b);
            }
            if(n.window!=none) {
                const spec=&context.pool.windows[n.window];
                for(spec.partition[0..spec.partition_count]) |item| try validateDiscardedConstants(context,item);
                for(spec.order[0..spec.order_count]) |key| try validateDiscardedConstants(context,key.expr);
                try validateDiscardedConstants(context,spec.start.offset);try validateDiscardedConstants(context,spec.end.offset);
            }
            if (n.kind == .case_expr) {
                try validateDiscardedConstants(context, n.a);
                const known_operand = n.a == none or (try foldableScalar(context, n.a));
                const operand = if (n.a != none and known_operand) try E.eval(&eval_context, n.a) else V.Cell.null_value;
                var arm = n.b;
                while (arm != none) : (arm = context.node(arm).next) {
                    const entry = context.node(arm);
                    try validateDiscardedConstants(context, entry.a);
                    if (known_operand and (try foldableScalar(context, entry.a))) {
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
                    if ((try foldableScalar(context, item)) and (try E.eval(&eval_context, item)) != .null_value) return;
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
                    if (n.op == .bit_not and !value.integral(ty)) return error.UndefinedFunction;
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
                            const left_ty = context.node(n.a).ty;
                            const right_ty = context.node(n.b).ty;
                            if (types.isArray(left_ty) or types.isArray(right_ty)) {
                                n.ty = try arrayConcatTypes(context, &n.a, &n.b, .operator);
                                return;
                            }
                            if ((left_ty == .jsonb and (right_ty == .jsonb or right_ty == .unknown)) or
                                (right_ty == .jsonb and left_ty == .unknown)) {
                                try coerce(context, n.a, .jsonb);
                                try coerce(context, n.b, .jsonb);
                                n.ty = .jsonb;
                                return;
                            }
                            // bytea || bytea (byteacat); an untyped side is bytea.
                            if ((left_ty == .bytea and (right_ty == .bytea or right_ty == .unknown)) or
                                (right_ty == .bytea and left_ty == .unknown)) {
                                try coerce(context, n.a, .bytea);
                                try coerce(context, n.b, .bytea);
                                n.ty = .bytea;
                                return;
                            }
                            // text || text, text || anynonarray, anynonarray || text.
                            if (context.node(n.a).ty == .unknown) try coerce(context, n.a, .text);
                            if (context.node(n.b).ty == .unknown) try coerce(context, n.b, .text);
                            if (context.node(n.a).ty == .bpchar) n.a = try convert(context, n.a, .text, -1, .implicit);
                            if (context.node(n.b).ty == .bpchar) n.b = try convert(context, n.b, .text, -1, .implicit);
                            if (!value.stringType(context.node(n.a).ty) and !value.stringType(context.node(n.b).ty)) return error.UndefinedFunction;
                            n.ty = .text;
                        },
                        .contains, .contained => if (geometricType(context.node(n.a).ty) or geometricType(context.node(n.b).ty)) try geometricOperator(context, n) else if (types.isRange(context.node(n.a).ty) or types.isRange(context.node(n.b).ty)) try rangeOperator(context, n) else if (types.isArray(context.node(n.a).ty) or types.isArray(context.node(n.b).ty)) try arrayContainment(context, n) else try jsonOperator(context, n),
                        .distance, .same => try geometricOperator(context, n),
                        .overlap => if (geometricType(context.node(n.a).ty) or geometricType(context.node(n.b).ty)) try geometricOperator(context, n) else if (types.isRange(context.node(n.a).ty) or types.isRange(context.node(n.b).ty)) try rangeOperator(context, n) else if (networkType(context.node(n.a).ty) or networkType(context.node(n.b).ty)) try networkOperator(context, n) else try arrayContainment(context, n),
                        .within_eq, .contains_eq => try networkOperator(context, n),
                        .over_left, .over_right, .adjacent => try rangeOperator(context, n),
                        .arrow, .arrow_text, .path, .path_text, .exists => try jsonOperator(context, n),
                        .shift_left, .shift_right => if (types.isRange(context.node(n.a).ty) or types.isRange(context.node(n.b).ty)) try rangeOperator(context, n) else if (networkType(context.node(n.a).ty) or networkType(context.node(n.b).ty)) try networkOperator(context, n) else try bitwiseType(context, n),
                        .bit_and, .bit_or, .bit_xor => try bitwiseType(context, n),
                        .neg, .pos, .bit_not => unreachable,
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
                    if (context.node(n.b).ty == .bpchar) n.b = try convert(context, n.b, .text, -1, .implicit);
                    // name LIKE text (namelike) and varchar share text's
                    // representation; bpchar LIKE text reads the padded value.
                    const left_ty = context.node(n.a).ty;
                    const right_ty = context.node(n.b).ty;
                    if (!value.characterType(left_ty) or !value.stringType(right_ty)) return error.UndefinedFunction;
                    if (n.c != none) {
                        try typeExpr(context, scope, n.c);
                        try coerce(context, n.c, .text);
                        if (context.node(n.c).ty == .bpchar) n.c = try convert(context, n.c, .text, -1, .implicit);
                        const escape_ty = context.node(n.c).ty;
                        if (!value.stringType(escape_ty)) return error.UndefinedFunction;
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
                    if (inner.kind == .function and inner.func == .array_constructor and inner.b == none and types.isArray(target)) {
                        // ARRAY[]::type[]: the cast supplies the element type.
                        inner.ty = target;
                        inner.constant = true;
                    } else if (inner.kind == .decimal_literal and (target == .float4 or target == .float8)) {
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
                        _ = try Io.parseCast(target, n.typmod, text.slice(), context.session);
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
                        // TRIM(...) calls btrim/ltrim/rtrim, named after them.
                        // IS [form] NORMALIZED calls is_normalized.
                        .btrim, .ltrim, .rtrim, .is_normalized => break :blk .{ .name = @tagName(n.func), .strength = 2 },
                        // ARRAY[...]; a subscripted value keeps its base's name.
                        .array_constructor => break :blk .{ .name = "array", .strength = 2 },
                        .array_subscript => break :blk figure(context, n.b, buffer),
                        .array_any => break :blk .{ .name = "?column?", .strength = 0 },
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
                    const named_type = types.elementType(n.cast_type) orelse n.cast_type;
                    break :blk .{ .name = types.typeInfo(types.dataTypeOf(named_type)).name, .strength = 1 };
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

        /// The OID of a schema name: pg_catalog, public, information_schema
        /// or a user schema visible to the statement (3F000 otherwise).
        fn namespaceOf(context: *const Context, name: []const u8) Error!u32 {
            for (catalog.namespaces) |namespace| if (types.same(namespace.name, name)) return namespace.oid;
            const found = context.catalog.findSchema(name, context.snapshot) orelse return error.UndefinedSchema;
            return found.oid;
        }

        fn qualifierNamespace(context: *const Context, schema: ?ast.Ident) Error!u32 {
            const qualifier = schema orelse return catalog.public_namespace;
            return namespaceOf(context, toName(context, qualifier).slice());
        }

        /// A user table, optionally schema-qualified (public by default,
        /// as the default search_path).
        fn resolveQualified(context: *const Context, schema: ?ast.Ident, name: ast.Ident) Error!usize {
            // PostgreSQL reports a relation in a missing schema as 42P01.
            const namespace = qualifierNamespace(context, schema) catch |err| return if (err == error.UndefinedSchema) error.TableNotFound else err;
            const wanted = toName(context, name);
            const found = context.catalog.findIn(namespace, wanted.slice(), context.snapshot) orelse return error.TableNotFound;
            if (found.kind == 'S') return error.TableNotFound;
            return found.slot;
        }

        /// A FROM table: views, partitioned tables and inheritance parents
        /// were expanded before binding (Database.expandRelations).
        fn readableTable(context: *const Context, index: usize) Error!usize {
            switch (context.tables[index].relkind) {
                'r', 'm' => {},
                else => return error.UnsupportedStatement,
            }
            if (!context.tables[index].populated) return error.ObjectNotInPrerequisiteState;
            return index;
        }

        /// A DML target: a table (or a partitioned table for INSERT);
        /// materialized views are 42809, views 0A000.
        fn writableTable(context: *const Context, index: usize, routed: bool) Error!usize {
            switch (context.tables[index].relkind) {
                'r' => {},
                'p' => if (!routed) return error.UnsupportedStatement,
                'm' => return error.WrongObjectType,
                else => return error.UnsupportedStatement,
            }
            return index;
        }

        /// Visible table slots (every relation kind but sequences).
        fn visibleTables(context: *const Context, out: *[K.relation_rows]usize) usize {
            var relations: [K.relation_rows]K.Found = undefined;
            const count = context.catalog.visibleRelations(context.snapshot, &relations);
            var used: usize = 0;
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                out[used] = found.slot;
                used += 1;
            }
            return used;
        }

        /// An index-like relation name in `namespace`: a table's primary key
        /// or UNIQUE constraint index, or a secondary index.
        fn indexNameTaken(context: *const Context, namespace: u32, name: []const u8) bool {
            var slots: [K.relation_rows]usize = undefined;
            const count = visibleTables(context, &slots);
            for (slots[0..count]) |slot| {
                const entry = &context.tables[slot];
                if (entry.namespace != namespace) continue;
                for (entry.indexes[0..entry.index_count]) |*index| if (types.same(index.name.slice(), name)) return true;
                for (entry.constraints[0..entry.constraint_count]) |*constraint| {
                    if ((constraint.kind == .unique or constraint.kind == .primary or constraint.kind == .exclusion) and types.same(constraint.name.slice(), name)) return true;
                }
                if (entry.primary_column != null and S.primaryConstraint(entry) == null) {
                    const pkey = objectName(entry.name.slice(), "", "pkey");
                    if (types.same(pkey.slice(), name)) return true;
                }
            }
            return false;
        }

        fn relationNameTaken(context: *const Context, namespace: u32, name: []const u8) bool {
            return context.catalog.findIn(namespace, name, context.snapshot) != null or indexNameTaken(context, namespace, name);
        }

        /// Binds a stored expression text (index element or predicate) over
        /// the table row: immutable (42P17), no subquery or aggregate.
        fn bindIndexText(context: *const Context, text: []const u8, table: usize, predicate: bool) Error!u16 {
            var sub = context.*;
            sub.source = text;
            const id = try P.parseExpression(text, context.pool);
            try generatedSubqueries(&sub, id);
            const scope = tableScope(&sub, table);
            try typeExpr(&sub, &scope, id);
            if (predicate) try booleanArgument(&sub, id);
            if (!immutableExpression(&sub, id, false)) return error.InvalidObjectDefinition;
            return id;
        }

        /// PostgreSQL ChooseIndexName: table_col1_col2_idx (`expr` for an
        /// expression element), `key` for unique indexes, numbered until free.
        fn chooseIndexName(context: *const Context, entry: *const S.Table, columns: []const u8, unique: bool) V.Name {
            var name2: [256]u8 = undefined;
            var length: usize = 0;
            for (columns, 0..) |column, position| {
                if (position != 0) {
                    name2[length] = '_';
                    length += 1;
                }
                const part = if (column == S.expression_key) "expr" else entry.columns[column].name.slice();
                const take = @min(part.len, name2.len - length);
                @memcpy(name2[length..][0..take], part[0..take]);
                length += take;
            }
            const label: []const u8 = if (unique) "key" else "idx";
            var pass: usize = 0;
            while (true) : (pass += 1) {
                var buffer: [24]u8 = undefined;
                @memcpy(buffer[0..label.len], label);
                var size = label.len;
                if (pass != 0) {
                    var digits: [20]u8 = undefined;
                    var at: usize = digits.len;
                    var rest = pass;
                    while (true) {
                        at -= 1;
                        digits[at] = @intCast('0' + rest % 10);
                        rest /= 10;
                        if (rest == 0) break;
                    }
                    @memcpy(buffer[size..][0 .. digits.len - at], digits[at..]);
                    size += digits.len - at;
                }
                const candidate = objectName(entry.name.slice(), name2[0..length], buffer[0..size]);
                if (!relationNameTaken(context, entry.namespace, candidate.slice())) return candidate;
            }
        }

        /// The identity definition of table `index` as an ALTER TABLE.
        fn alterOf(context: *const Context, index: usize, tag: types.CommandTag) AlterTable {
            const entry = &context.tables[index];
            var out: AlterTable = .{ .table = index, .name = entry.name, .columns = entry.columns, .count = entry.column_count, .constraints = entry.constraints, .constraint_count = entry.constraint_count, .sources = undefined, .extras = S.extrasOf(entry), .command = tag };
            for (0..config.columns) |column| out.sources[column] = @intCast(column);
            return out;
        }

        fn bindCreateIndex(context: *const Context, create: *const Ast.CreateIndex) Error!Bound {
            const index = try resolveQualified(context, create.table.schema, create.table.name);
            const entry = &context.tables[index];
            switch (entry.relkind) {
                'r', 'm' => {},
                'p' => return error.UnsupportedStatement,
                else => return error.WrongObjectType,
            }
            var definition: S.Index = .{ .unique = create.unique, .nulls_not_distinct = create.nulls_not_distinct };
            var expressions: V.Text = .{};
            for (create.elements[0..create.count]) |*element| {
                var column: u8 = S.expression_key;
                if (element.column) |ident| {
                    column = @intCast(try columnIndex(context, entry, ident));
                    if (entry.columns[column].data_type == .json) return error.UndefinedFunction;
                } else {
                    const text = element.expression.slice(context.source);
                    if (expressions.len != 0) {
                        if (expressions.len == config.text_bytes) return error.TextCapacity;
                        expressions.bytes[expressions.len] = 0;
                        expressions.len += 1;
                    }
                    if (text.len > config.text_bytes - expressions.len) return error.TextCapacity;
                    @memcpy(expressions.bytes[expressions.len..][0..text.len], text);
                    expressions.len += text.len;
                    _ = try bindIndexText(context, text, index, false);
                }
                definition.keys[definition.key_count] = column;
                definition.options[definition.key_count] = @as(u8, @intFromBool(element.descending)) | (@as(u8, @intFromBool(element.nulls_first orelse element.descending)) << 1);
                definition.key_count += 1;
            }
            definition.expressions = expressions;
            for (create.includes[0..create.include_count]) |ident| {
                const column: u8 = @intCast(try columnIndex(context, entry, ident));
                for (definition.includes[0..definition.include_count]) |previous| if (previous == column) return error.DuplicateColumn;
                definition.includes[definition.include_count] = column;
                definition.include_count += 1;
            }
            if (create.predicate.len != 0) {
                const text = create.predicate.slice(context.source);
                if (text.len > config.text_bytes) return error.TextCapacity;
                _ = try bindIndexText(context, text, index, true);
                definition.predicate.len = text.len;
                @memcpy(definition.predicate.bytes[0..text.len], text);
            }
            // A unique index over expressions or with a predicate needs
            // per-row evaluation at every write: outside the subset.
            if (create.unique and (expressions.len != 0 or definition.predicate.len != 0)) return error.UnsupportedStatement;
            if (create.name) |ident| {
                definition.name = toName(context, ident);
                if (relationNameTaken(context, entry.namespace, definition.name.slice())) {
                    if (create.if_not_exists) return .{ .noop = .create_index };
                    return error.TableExists;
                }
            } else definition.name = chooseIndexName(context, entry, definition.keyColumns(), create.unique);
            if (entry.index_count == S.index_capacity or S.index_entry_capacity == 0) return error.IndexCapacity;
            var out = alterOf(context, index, .create_index);
            out.extras.indexes[out.extras.index_count] = definition;
            if (create.unique) out.check_index = out.extras.index_count;
            out.extras.index_count += 1;
            return .{ .alter_table = out };
        }

        fn bindDropIndex(context: *const Context, drop: *const Ast.Drop) Error!Bound {
            const namespace = qualifierNamespace(context, drop.schema) catch |err| {
                if (err == error.UndefinedSchema and drop.if_exists) return .{ .noop = .drop_index };
                return err;
            };
            const wanted = toName(context, drop.name);
            var slots: [K.relation_rows]usize = undefined;
            const count = visibleTables(context, &slots);
            for (slots[0..count]) |slot| {
                const entry = &context.tables[slot];
                if (entry.namespace != namespace) continue;
                for (entry.indexes[0..entry.index_count], 0..) |*index, position| {
                    if (!types.same(index.name.slice(), wanted.slice())) continue;
                    var out = alterOf(context, slot, .drop_index);
                    var at = position;
                    while (at + 1 < out.extras.index_count) : (at += 1) out.extras.indexes[at] = out.extras.indexes[at + 1];
                    out.extras.index_count -= 1;
                    return .{ .alter_table = out };
                }
            }
            // A constraint's index is dropped with the constraint (2BP01).
            if (indexNameTaken(context, namespace, wanted.slice())) return error.DependentObjects;
            if (context.catalog.findIn(namespace, wanted.slice(), context.snapshot) != null) return error.WrongObjectType;
            if (drop.if_exists) return .{ .noop = .drop_index };
            return error.UndefinedObject;
        }

        fn scopeFor(context: *const Context, from: ?Ast.TableRef) Error!Scope {
            const reference = from orelse return .{};
            const index = try readableTable(context, try resolveQualified(context, reference.schema, reference.name));
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
                // A subscript keeps the array's typmod (reftypmod).
                .function => if (n.func == .array_subscript or n.func == .xmlserialize) n.typmod else -1,
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
                try sortableType(context.node(id).ty);
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
            // No btree or hash operator classes (could not identify an
            // ordering/equality operator: 42883).
            if (ty == .point or ty == .box or ty == .xml) return error.UndefinedFunction;
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
            // Subscript layouts (array_subscript) and other call words.
            if (x.kind == .function and x.integer != y.integer) return false;
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
            if(n.kind==.function and n.func==.grouping) {
                var item=n.b;
                while(item!=none):(item=context.node(item).next) {
                    var found=false;
                    for(p.keys[0..p.key_count]) |key| if(sameExpr(context,item,key)){found=true;break;};
                    if(!found) return error.GroupingError;
                }
                return;
            }
            if(n.window!=none) {
                const spec=&context.pool.windows[n.window];
                for(spec.partition[0..spec.partition_count]) |item| try validateDiscardedGroup(context,p,item);
                for(spec.order[0..spec.order_count]) |key| try validateDiscardedGroup(context,p,key.expr);
            }
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
            if(n.planned_null) {
                var item=n.b;
                while(item!=none):(item=context.node(item).next) try validateDiscardedGroup(context,p,item);
                return;
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
            var scope: Scope = .{ .parent = parent, .plan = id, .ctes = env, .window_defs=q.window_defs };
            for (q.items[0..q.item_count], 0..) |*item, index| {
                var rel: Relation = .{};
                var source: Source = .{ .join = item.join };
                if (item.query != none) {
                    // Derived tables are not LATERAL: they see enclosing blocks
                    // only; an expanded view sees neither (it is a stored query).
                    const child = try bindPlan(context, item.query, if (item.view) null else parent, if (item.view) null else env, false);
                    rel.plan = child;
                    source.plan = child;
                    if (plans.items[child].correlated) plans.items[id].correlated = true;
                } else if (lookupCte(context, env, item.name)) |cte| {
                    rel.cte = cte;
                    rel.plan = plans.ctes[cte].plan;
                    rel.name = plans.ctes[cte].name;
                    source.cte = cte;
                    source.plan = rel.plan;
                    plans.ctes[cte].referenced = true;plans.ctes[cte].references+=1;
                    if (plans.items[rel.plan].correlated) plans.items[id].correlated = true;
                } else if (viewOf(context, item.schema, item.name)) |view| {
                    rel.view = view;
                    rel.name = literalName(@tagName(view));
                    source.view = view;
                } else {
                    const table = try readableTable(context, try resolveQualified(context, item.schema, item.name));
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
            try resolveWindows(context,q.window_defs);
            p.where = try bindWhere(context, &scope, q.where);
            for (q.group[0..q.group_count]) |expr_id| {
                p.keys[p.key_count] = try groupKey(context, &scope, q, expr_id);
                p.key_count += 1;
            }
            var saw = false;
            scope.aggregates = true;
            scope.windows = true;
            scope.saw_aggregate = &saw;
            var window_def=q.window_defs;
            while(window_def!=none) : (window_def=context.pool.windows[window_def].next) try typeWindowSpec(context,&scope,&context.pool.windows[window_def]);
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
            // Preserve diagnostics before lowering, separately for each output.
            // Child plans are validated later, after output demand is known.
            if(!context.describe_only) {
                var planning=context.*;planning.planning_plan=p;
                const constant_context=&planning;
                for(p.constant_outputs[0..p.width]) |*cell| cell.*=.null_value;
                var state:PlannedValidation=.{};
                var pending:?Error=null;
                for(p.targets[0..p.width],0..) |target,column| {
                    p.prunable[column]=immutableExpression(context,target,true);
                    planning.constant_dependencies=&p.constant_dependencies[column];
                    validateDiscardedConstants(constant_context,target) catch |err| {if(planningControlError(err)) return err;p.planned_targets[column]=err;};
                    if(p.planned_targets[column]==null) {
                        if(p.prunable[column] and (try foldableScalar(constant_context,target))) {
                            if(generatedValue(constant_context,target)) |value_cell| {p.constant_outputs[column]=value_cell;p.constant_known[column]=true;}
                            else |err| {if(planningControlError(err)) return err;p.planned_targets[column]=err;}
                        } else if(p.prunable[column] and context.node(target).planned_null) {p.constant_known[column]=true;p.constant_dependencies[column]=@splat(false);}
                    }
                    planning.constant_dependencies=null;
                    validatePlannedWindowTree(constant_context,&state,target) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                }
                for([_]u16{p.where,p.having}) |expression| validateDiscardedConstants(constant_context,expression) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                for(p.keys[0..p.key_count]) |expression| validateDiscardedConstants(constant_context,expression) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                for(p.sources[0..p.source_count]) |source| validateDiscardedConstants(constant_context,source.on) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                for(order_refs[0..q.order_count]) |ref| if(ref==.expr) {
                    validateDiscardedConstants(constant_context,ref.expr) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                    validatePlannedWindowTree(constant_context,&state,ref.expr) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                };
                for(on_refs[0..q.distinct_on_count]) |ref| if(ref==.expr) {
                    validateDiscardedConstants(constant_context,ref.expr) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                    validatePlannedWindowTree(constant_context,&state,ref.expr) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                };
                window_def=q.window_defs;
                while(window_def!=none):(window_def=context.pool.windows[window_def].next) {
                    validatePlannedWindowSpec(constant_context,&state,&context.pool.windows[window_def]) catch |err| {if(planningControlError(err)) return err;if(pending==null) pending=err;};
                }
                p.planned_checked=true;p.planned_error=pending;
            }
            p.rollup=q.rollup;
            p.grouped = q.rollup or p.key_count != 0 or saw or p.having != none;
            if (p.grouped) {
                window_def=q.window_defs;
                while(window_def!=none) : (window_def=context.pool.windows[window_def].next) {
                    const spec=&context.pool.windows[window_def];
                    for(spec.partition[0..spec.partition_count]) |item| try groupify(context,p,item);
                    for(spec.order[0..spec.order_count]) |key| try groupify(context,p,key.expr);
                }
                p.window_aggregate_count=p.agg_count;
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
            p.constant_source_safe=!q.distinct and q.order_count==0 and !q.limit_present and !q.offset_present;
            try lowerWindows(context,id);
            return id;
        }

        fn containsWindow(context:*const Context,id:u16) bool {
            if(id==none) return false;const n=context.node(id);if(n.window!=none) return true;
            if(n.planned_null) return false;
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
            const index=input.count;input.count+=1;input.targets[index]=try cloneTree(context,id);input.window_origins[index]=none;
            input.tys[index]=context.node(id).ty;input.typmods[index]=outputTypmod(context,id);
            input.names[index]=literalName("window_input");return @intCast(index);
        }
        // Sort/group clauses reuse equal expressions even when volatile;
        // window value arguments deliberately keep their separate evaluation.
        fn windowKeyInput(context:*const Context,input:*Plan,id:u16,origin:u16) Error!u16 {
            for(input.window_origins[0..input.count],0..) |old,index| if(old==origin) return @intCast(index);
            for(input.targets[0..input.count],0..) |old,index| {
                try context.session.checkpoint();
                if(sameExpr(context,old,id)) return @intCast(index);
            }
            const index=try windowInput(context,input,id);input.window_origins[index]=origin;return index;
        }

        fn lowerWindowTree(context:*const Context,p:*Plan,input:*Plan,id:u16) Error!void {
            if(id==none) return;const n=context.node(id);
            if(n.planned_null) return;
            if(n.kind==.function and n.func==.grouping) {
                const column=try windowInput(context,input,id);const ty=n.ty;const next=n.next;
                n.*=.{.kind=.column,.relation=0,.column=column,.ty=ty,.next=next};return;
            }
            if(n.window!=none) {
                if(p.window_count==config.columns) return error.StatementTooComplex;
                const spec=&context.pool.windows[n.window];
                var win:Window=.{.frame=spec.frame,.start=spec.start,.end=spec.end,.exclude=spec.exclude,.output_node=id};
                const name=toName(context,n.name);
                win.kind=if(types.same(name.slice(),"rank")) .rank else if(types.same(name.slice(),"dense_rank")) .dense_rank else if(types.same(name.slice(),"row_number")) .row_number else if(types.same(name.slice(),"lag")) .lag else if(types.same(name.slice(),"lead")) .lead else if(types.same(name.slice(),"percent_rank")) .percent_rank else if(types.same(name.slice(),"cume_dist")) .cume_dist else if(types.same(name.slice(),"ntile")) .ntile else if(types.same(name.slice(),"first_value")) .first_value else if(types.same(name.slice(),"last_value")) .last_value else if(types.same(name.slice(),"nth_value")) .nth_value else .aggregate;
                if(win.kind==.first_value or win.kind==.last_value or win.kind==.nth_value) {
                    win.offset_repeatable=repeatableFrameInput(context,spec.start.offset) and repeatableFrameInput(context,spec.end.offset);
                    // Value arguments stay lazy at the selected frame row.
                    var item=n.b;var index:usize=0;
                    while(item!=none) : (item=context.node(item).next) {
                        win.offset_repeatable=win.offset_repeatable and repeatableWindowInput(context,item);
                        win.offset_total=win.offset_total and (safeWindowOperand(context,item) or generatedConstant(context,item));
                        if(generatedConstant(context,item)) {
                            const constant=try generatedValue(context,item);
                            if(index==1 and constant!=.null_value and constant.integer<=0) win.offset_total=false;
                        } else if(index==1) win.offset_total=false;
                        const cloned=try cloneTree(context,item);try lowerWindowTree(context,p,input,cloned);
                        if(index==0) win.deferred_arg=cloned else win.offset_arg=cloned;
                        index+=1;
                    }
                    for([_]u16{spec.start.offset,spec.end.offset}) |bound| if(bound!=none) {
                        if(generatedConstant(context,bound)) {
                            const v=try generatedValue(context,bound);
                            if(v==.null_value or v.integer<0) win.offset_total=false;
                        } else win.offset_total=false;
                    };
                    // Reuse the bounded frame resolver without aggregate state.
                    switch(win.frame) {
                        .full=>{win.frame=.rows;win.start=.{.kind=.unbounded_preceding};win.end=.{.kind=.unbounded_following};},
                        .rows_prefix=>{win.frame=.rows;win.start=.{.kind=.unbounded_preceding};win.end=.{.kind=.current_row};},
                        .default=>{if(spec.order_count==0){win.frame=.rows;win.end=.{.kind=.unbounded_following};}else win.frame=.range;},
                        else=>{},
                    }
                } else if(win.kind==.lag or win.kind==.lead) {
                    win.offset_repeatable=repeatableFrameInput(context,spec.start.offset) and repeatableFrameInput(context,spec.end.offset);
                    // Value is evaluated at the selected row; offset/default
                    // at the current row, with default only outside partition.
                    // Fold immutable constants first, like the native planner.
                    var item=n.b;var index:usize=0;
                    while(item!=none) : (item=context.node(item).next) {
                        win.offset_repeatable=win.offset_repeatable and repeatableWindowInput(context,item);
                        win.offset_total=win.offset_total and (safeWindowOperand(context,item) or generatedConstant(context,item));
                        if(generatedConstant(context,item)) _=try generatedValue(context,item);
                        const cloned=try cloneTree(context,item);
                        try lowerWindowTree(context,p,input,cloned);
                        switch(index){0=>win.deferred_arg=cloned,1=>win.offset_arg=cloned,2=>win.default_arg=cloned,else=>unreachable}
                        index+=1;
                    }
                } else if(win.kind==.ntile) {
                    win.offset_repeatable=repeatableWindowInput(context,n.b);
                    win.offset_total=false;
                    if(generatedConstant(context,n.b)) {
                        const bucket=try generatedValue(context,n.b);
                        win.offset_total=bucket==.null_value or bucket.integer>0;
                    }
                    win.deferred_arg=try cloneTree(context,n.b);
                    try lowerWindowTree(context,p,input,win.deferred_arg);
                } else if(win.kind==.aggregate) {
                    win.offset_repeatable=repeatableWindowInput(context,n.b) and repeatableWindowInput(context,n.c) and repeatableFrameInput(context,spec.start.offset) and repeatableFrameInput(context,spec.end.offset);
                    // For a full unsorted partition, input projection evaluates
                    // argument columns together, preserving per-row interleaving.
                    // Only accumulators with no failure/side effect qualify.
                    const total_accumulator=n.agg==.count or n.agg==.count_star or n.agg==.min or n.agg==.max or n.agg==.bool_and or n.agg==.bool_or;
                    win.materialized_full=total_accumulator and spec.partition_count==0 and spec.order_count==0 and n.c==none and (spec.frame==.full or spec.frame==.default) and repeatableFrameInput(context,spec.start.offset) and repeatableFrameInput(context,spec.end.offset);
                    // PostgreSQL folds immutable constant inputs before a
                    // FILTER/frame can discard them; never execute volatile
                    // or session-dependent expressions during binding.
                    if(generatedConstant(context,n.b)) _=try generatedValue(context,n.b);
                    if(generatedConstant(context,n.c)) _=try generatedValue(context,n.c);
                    if(n.agg!=.count_star) {
                        const arg=context.node(n.b);
                        const bounded=spec.frame==.rows or spec.frame==.groups or spec.frame==.range;
                        const simple=arg.kind==.column or arg.kind==.null_literal or arg.kind==.int_literal or arg.kind==.bool_literal or arg.kind==.text_literal or arg.kind==.decimal_literal;
                        if((bounded or n.c!=none or (!repeatableWindowInput(context,n.b) and !win.materialized_full)) and !simple) {
                            win.deferred_arg=try cloneTree(context,n.b);try lowerWindowTree(context,p,input,win.deferred_arg);
                        } else win.argument=try windowInput(context,input,n.b);
                    }
                    win.aggregate=.{.kind=n.agg,.arg=none,.filter=none,.distinct=false,.arg_ty=if(n.b==none) .unknown else context.node(n.b).ty,.ty=n.ty};
                    if(n.c!=none) {
                        if(safeWindowFilter(context,n.c)) win.filter_column=try windowInput(context,input,n.c)
                        else {win.deferred_filter=try cloneTree(context,n.c);try lowerWindowTree(context,p,input,win.deferred_filter);}
                    }
                }
                for(spec.partition[0..spec.partition_count],0..) |item,key_index| {
                    win.mutable_keys=win.mutable_keys or !repeatableWindowInput(context,item);
                    win.partition[win.partition_count]=try windowKeyInput(context,input,item,spec.partition_origin[key_index]);win.partition_count+=1;
                }
                for(spec.order[0..spec.order_count],0..) |key,key_index| {
                    win.mutable_keys=win.mutable_keys or !repeatableWindowInput(context,key.expr);
                    win.order[win.order_count]=.{.column=try windowKeyInput(context,input,key.expr,spec.order_origin[key_index]),.descending=key.descending,.nulls_first=nullsFirst(&key)};win.order_count+=1;
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
        /// A final order already supplied by WindowAgg needs no blocking
        /// sort. Match the exact prefix that windowOutput can project after
        /// LIMIT; reject uncertain demand for throwing/volatile expressions.
        fn offsetPrefixOrder(context:*const Context,p:*const Plan,win:*const Window) bool {
            if(p.distinct!=.none or p.order_count>win.partition_count+win.order_count) return false;
            for(p.order[0..p.order_count],0..) |key,index| {
                const target=context.node(p.targets[key.column]);
                if(target.kind!=.column or target.level!=0 or target.relation!=0) return false;
                const expected:SortKey=if(index<win.partition_count)
                    .{.column=win.partition[index],.descending=false,.nulls_first=false}
                    else win.order[index-win.partition_count];
                if(target.column!=expected.column or key.descending!=expected.descending or key.nulls_first!=expected.nulls_first) return false;
            }
            if(p.order_count!=0) for(p.targets[0..p.width],0..) |id,index| {
                const kind=context.node(id).kind;
                if(!p.window_late[index] and kind!=.column and kind!=.null_literal and kind!=.bool_literal and kind!=.int_literal and kind!=.text_literal and kind!=.decimal_literal) return false;
            };
            return true;
        }

        fn lowerWindows(context:*const Context,id:u16) Error!void {
            const plans=plansOf(context);const p=&plans.items[id];var active=false;
            for(p.targets[0..p.width]) |target| active=active or containsWindow(context,target);
            if(!active) return;
            for(p.targets[0..p.width]) |target| {if(generatedConstant(context,target)) _=try generatedValue(context,target);}
            const child=try plans.add();const input=&plans.items[child];input.*=p.*;
            input.planned_checked=true;input.planned_error=null;input.planned_targets=@splat(null);input.constant_known=@splat(false);
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
            for(p.windows[0..p.window_count]) |*win| {
                if(p.limit!=0 and win.mutable_keys) for(p.window_late[0..p.width]) |late| {if(late) return error.UnsupportedStatement;};
                if(win.kind==.aggregate) {
                    if(p.limit!=0 and !win.offset_repeatable) {
                        const full=win.frame==.full or (win.frame==.default and win.order_count==0);
                        if(p.window_count!=1) {
                            for(p.windows[0..p.window_count]) |other| if(!other.materialized_full) return error.UnsupportedStatement;
                        } else if(p.limit!=0xffffffffffffffff and (!full or win.partition_count!=0)) return error.UnsupportedStatement;
                        for(p.window_late[0..p.width]) |late| if(late) return error.UnsupportedStatement;
                    }
                    continue;
                }
                if(win.kind!=.lag and win.kind!=.lead and win.kind!=.ntile and win.kind!=.first_value and win.kind!=.last_value and win.kind!=.nth_value) continue;
                win.offset_prefix=p.window_count==1 and offsetPrefixOrder(context,p,win);
                if(p.limit==0 or (win.offset_repeatable and win.offset_total)) continue;
                if(p.window_count!=1 or (p.limit!=0xffffffffffffffff and !win.offset_prefix)) return error.UnsupportedStatement;
                for(p.window_late[0..p.width]) |late| if(late) return error.UnsupportedStatement;
            }
            p.source_count=1;p.sources[0]=.{.plan=child};p.where=none;p.grouped=false;p.rollup=false;p.key_count=0;p.agg_count=0;p.window_aggregate_count=0;p.having=none;
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
            // Parent LIMIT/filter/joins can stop demand for a nested WindowAgg.
            // Until execution propagates that demand, nonrepeatable offset
            // windows are only safe in the root query plan.
            if(context.plans) |plans| for(plans.items[0..plans.len],0..) |*plan,index| {
                for(plan.windows[0..plan.window_count]) |win| if(plan.limit!=0 and (win.mutable_keys or !win.offset_repeatable or !win.offset_total)) {
                    if(bound!=.query or bound.query!=index) return error.UnsupportedStatement;
                };
            };
            if(context.describe_only) return bound;
            try planOutputDemand(context,&bound);
            try validatePlannedExpressions(context,&bound);
            return bound;
        }

        fn demandOutput(context:*const Context,plan_id:u16,column:?usize,changed:*bool) void {
            if(plan_id==none) return;
            const p=&plansOf(context).items[plan_id];
            if(!p.demanded) {p.demanded=true;changed.*=true;}
            if(column) |i| if(i<p.width and !p.required[i]) {p.required[i]=true;changed.*=true;};
        }
        fn demandAll(context:*const Context,plan_id:u16,changed:*bool) void {
            if(plan_id==none) return;
            demandOutput(context,plan_id,null,changed);
            for(0..plansOf(context).items[plan_id].width) |i| demandOutput(context,plan_id,i,changed);
        }
        fn demandExpr(context:*const Context,owner:u16,id:u16,changed:*bool) Error!void {
            if(id==none) return;
            const n=context.node(id);
            if(n.planned_null) return;
            if(n.kind==.column) {
                if(owner!=none and n.level==0) {
                    const p=&plansOf(context).items[owner];
                    if(p.grouped and n.relation==group_relation) {
                        if(n.column>=p.key_count) {
                            const index=n.column-p.key_count;
                            if(index<p.agg_count and !p.aggregate_required[index]) {p.aggregate_required[index]=true;changed.*=true;}
                        }
                    } else if(n.relation<p.source_count) demandOutput(context,p.sources[n.relation].plan,n.column,changed);
                }
                return;
            }
            if(n.kind==.scalar_subquery or n.kind==.exists_subquery or n.kind==.in_subquery) {
                demandAll(context,@intCast(n.integer),changed);
                if(n.kind==.in_subquery) try demandExpr(context,owner,n.a,changed);
                return;
            }
            if(n.kind==.case_expr) {
                try demandExpr(context,owner,n.a,changed);
                var known=n.a==none or (try foldableScalar(context,n.a));
                const operand=if(n.a!=none and known) generatedValue(context,n.a) catch |err| blk:{if(planningControlError(err)) return err;known=false;break :blk V.Cell.null_value;} else V.Cell.null_value;
                var arm=n.b;
                while(arm!=none):(arm=context.node(arm).next) {
                    const entry=context.node(arm);try demandExpr(context,owner,entry.a,changed);
                    if(known and (try foldableScalar(context,entry.a))) {
                        const candidate=generatedValue(context,entry.a) catch |err| {if(planningControlError(err)) return err;try demandExpr(context,owner,entry.b,changed);continue;};
                        const hit=if(n.a==none) candidate==.boolean and candidate.boolean else E.compareOp(.eq,&operand,&candidate)==true;
                        if(!hit) continue;
                        try demandExpr(context,owner,entry.b,changed);return;
                    }
                    try demandExpr(context,owner,entry.b,changed);
                }
                return demandExpr(context,owner,n.c,changed);
            }
            if(n.kind==.and_op or n.kind==.or_op) {
                try demandExpr(context,owner,n.a,changed);
                if(constantTruth(context,n.a) catch |err| blk:{if(planningControlError(err)) return err;break :blk null;}) |v| if(v==.boolean and v.boolean==(n.kind==.or_op)) return;
                return demandExpr(context,owner,n.b,changed);
            }
            if(n.kind==.coalesce) {
                var item=n.b;while(item!=none):(item=context.node(item).next) {
                    try demandExpr(context,owner,item,changed);
                    if((try foldableScalar(context,item)) and (generatedValue(context,item) catch |err| blk:{if(planningControlError(err)) return err;break :blk V.Cell.null_value;})!=.null_value) return;
                }
                return;
            }
            try demandExpr(context,owner,n.a,changed);try demandExpr(context,owner,n.c,changed);
            if(listOwner(n.kind)) {var item=n.b;while(item!=none):(item=context.node(item).next) try demandExpr(context,owner,item,changed);}
            else try demandExpr(context,owner,n.b,changed);
        }
        fn planOutputDemand(context:*const Context,bound:*const Bound) Error!void {
            const plans=context.plans orelse return;
            // Correlation, windows and set operations retain conservative
            // dependencies; plain derived outputs can be suppressed without changing
            // width, column numbering, bags or row cardinality.
            var conservative=bound.*!=.query;
            for(plans.items[0..plans.len]) |*p| conservative=conservative or p.correlated;
            for(plans.items[0..plans.len]) |*p| {p.demanded=conservative;p.required=@splat(conservative);p.aggregate_required=@splat(conservative);}
            if(conservative) return;
            var cte_references:[config.ctes]usize=@splat(0);
            for(plans.items[0..plans.len]) |*consumer| for(consumer.sources[0..consumer.source_count]) |source| {if(source.cte!=no_cte) cte_references[source.cte]+=1;};
            var changed=true;demandAll(context,bound.query,&changed);
            while(changed) {
                changed=false;try context.session.checkpoint();
                for(plans.items[0..plans.len],0..) |*p,index| {
                    if(!p.demanded) continue;
                    const owner:u16=@intCast(index);
                    for(0..p.window_aggregate_count) |i| if(!p.aggregate_required[i]) {p.aggregate_required[i]=true;changed=true;};
                    if(p.set_op!=.none) {demandAll(context,p.left,&changed);demandAll(context,p.right,&changed);continue;}
                    var planning=context.*;planning.planning_plan=p;const demand_context=&planning;
                    const barrier=p.window_count!=0;
                    for(0..p.width) |i| if(barrier or p.distinct!=.none or !p.prunable[i]) demandOutput(context,owner,i,&changed);
                    for(p.order[0..p.order_count]) |key| demandOutput(context,owner,key.column,&changed);
                    for(p.sources[0..p.source_count]) |source| {
                        var materialized=false;
                        if(source.cte!=no_cte) {
                            materialized=cte_references[source.cte]>1 or plans.ctes[source.cte].recursive;
                        }
                        if(barrier or materialized) demandAll(context,source.plan,&changed) else demandOutput(context,source.plan,null,&changed);
                        try demandExpr(demand_context,owner,source.on,&changed);
                    }
                    for(p.targets[0..p.width],0..) |expression,i| if(p.required[i]) try demandExpr(demand_context,owner,expression,&changed);
                    for(p.keys[0..p.key_count]) |expression| try demandExpr(demand_context,owner,expression,&changed);
                    for(p.aggs[0..p.agg_count],0..) |agg,i| if(p.aggregate_required[i]) {try demandExpr(demand_context,owner,agg.arg,&changed);try demandExpr(demand_context,owner,agg.filter,&changed);};
                    try demandExpr(demand_context,owner,p.where,&changed);try demandExpr(demand_context,owner,p.having,&changed);
                    for(p.windows[0..p.window_count]) |win| {
                        for([_]u16{win.deferred_arg,win.deferred_filter,win.offset_arg,win.default_arg,win.start.offset,win.end.offset}) |expression| try demandExpr(demand_context,owner,expression,&changed);
                    }
                }
            }
        }

        const PlannedValidation=struct { plans:[config.subqueries]bool=@splat(false) };

        // Window clauses are planned independently of CASE and even when an
        // unused named specification produces no WindowAgg. Its value/filter
        // arguments, in contrast, stay attached to the owning expression.
        fn validatePlannedWindowSpec(context:*const Context,seen:*PlannedValidation,spec:*const Ast.Window) Error!void {
            for(spec.partition[0..spec.partition_count]) |id| try validatePlannedTree(context,seen,id);
            for(spec.order[0..spec.order_count]) |key| try validatePlannedTree(context,seen,key.expr);
            try validatePlannedTree(context,seen,spec.start.offset);try validatePlannedTree(context,seen,spec.end.offset);
        }

        fn validatePlannedWindowTree(context:*const Context,seen:*PlannedValidation,id:u16) Error!void {
            if(id==none) return;const n=context.node(id);
            if(n.window!=none) try validatePlannedWindowSpec(context,seen,&context.pool.windows[n.window]);
            if(n.kind==.scalar_subquery or n.kind==.exists_subquery or n.kind==.in_subquery) return;
            try validatePlannedWindowTree(context,seen,n.a);try validatePlannedWindowTree(context,seen,n.c);
            if(listOwner(n.kind)) {
                var item=n.b;while(item!=none):(item=context.node(item).next) try validatePlannedWindowTree(context,seen,item);
            } else try validatePlannedWindowTree(context,seen,n.b);
        }

        fn containsPlannedNull(context: *const Context, id: u16) bool {
            if(id==none) return false;
            const n=context.node(id);
            if(n.planned_null) return true;
            if(n.kind==.scalar_subquery or n.kind==.exists_subquery or n.kind==.in_subquery) return true;
            if(containsPlannedNull(context,n.a) or containsPlannedNull(context,n.c)) return true;
            if(listOwner(n.kind)) {
                var item=n.b;
                while(item!=none):(item=context.node(item).next) if(containsPlannedNull(context,item)) return true;
            } else if(containsPlannedNull(context,n.b)) return true;
            return false;
        }

        /// Runs after semantic binding over live roots, preserving immutable
        /// diagnostics and reachable scalar plans. Known-NULL calls retain
        /// argument diagnostics without executing volatile/runtime children.
        /// CASE/COALESCE and boolean reachability precede detached execution.
        fn validatePlannedTree(context: *const Context, seen:*PlannedValidation, id: u16) Error!void {
            try validateDiscardedConstants(context,id);
            if(!containsPlannedNull(context,id)) return;
            try context.session.checkpoint();
            const n=context.node(id);
            if(n.planned_null) {
                var item=n.b;
                while(item!=none):(item=context.node(item).next) try validateDiscardedConstants(context,item);
                return;
            }
            if(n.kind==.scalar_subquery or n.kind==.exists_subquery or n.kind==.in_subquery) {
                if(n.kind==.in_subquery) try validatePlannedTree(context,seen,n.a);
                return validatePlannedPlan(context,seen,@intCast(n.integer));
            }
            const eval_context=planningEvalContext(context);
            if(n.kind==.case_expr) {
                try validatePlannedTree(context,seen,n.a);
                const known=n.a==none or (try foldableScalar(context,n.a));
                const operand=if(n.a!=none and known) try E.eval(&eval_context,n.a) else V.Cell.null_value;
                var arm=n.b;
                while(arm!=none):(arm=context.node(arm).next) {
                    const entry=context.node(arm);
                    try validatePlannedTree(context,seen,entry.a);
                    if(known and (try foldableScalar(context,entry.a))) {
                        const candidate=try E.eval(&eval_context,entry.a);
                        const hit=if(n.a==none) candidate==.boolean and candidate.boolean else E.compareOp(.eq,&operand,&candidate)==true;
                        if(!hit) continue;
                        try validatePlannedTree(context,seen,entry.b);return;
                    }
                    try validatePlannedTree(context,seen,entry.b);
                }
                return validatePlannedTree(context,seen,n.c);
            }
            if(n.kind==.coalesce) {
                var item=n.b;
                while(item!=none):(item=context.node(item).next) {
                    try validatePlannedTree(context,seen,item);
                    if((try foldableScalar(context,item)) and (try E.eval(&eval_context,item))!=.null_value) return;
                }
                return;
            }
            try validatePlannedTree(context,seen,n.a);try validatePlannedTree(context,seen,n.c);
            if(listOwner(n.kind)) {
                var item=n.b;
                while(item!=none):(item=context.node(item).next) try validatePlannedTree(context,seen,item);
            } else try validatePlannedTree(context,seen,n.b);
        }

        fn validatePlannedReturning(context:*const Context,seen:*PlannedValidation, returning:*const Returning) Error!void {
            for(returning.targets[0..returning.count]) |target| try validatePlannedTree(context,seen,target);
        }

        fn validatePlannedStored(context:*const Context,seen:*PlannedValidation, table:usize, ids:*const [config.columns]u16) Error!void {
            for(ids,0..) |id,column| if(id!=none) {
                var sub=context.*;
                sub.source=context.tables[table].columns[column].expression.slice();
                try validatePlannedTree(&sub,seen,id);
            };
        }

        fn validatePlannedUpdate(context:*const Context,seen:*PlannedValidation, update:*const Update) Error!void {
            for(update.values) |id| try validatePlannedTree(context,seen,id);
            try validatePlannedTree(context,seen,update.where);
            try validatePlannedStored(context,seen,update.table,&update.defaults);
            try validatePlannedStored(context,seen,update.table,&update.generated);
            try validatePlannedReturning(context,seen,&update.returning);
        }

        fn validatePlannedPlan(context:*const Context,seen:*PlannedValidation,plan_id:u16) Error!void {
            if(plan_id==none or seen.plans[plan_id]) return;
            seen.plans[plan_id]=true;
            const p=&plansOf(context).items[plan_id];
            if(!p.demanded) return;
            var planning=context.*;planning.planning_plan=p;const constant_context=&planning;
            if(p.planned_checked) {
                // CTE materialization is known only after all consumers bind.
                // Plain target trees remain intact, so refresh these diagnostics
                // before clauses while keeping original pre-lowering group/window errors.
                if(!p.grouped and p.window_count==0) for(p.targets[0..p.width],0..) |id,column| if(p.required[column]) try validateDiscardedConstants(constant_context,id);
                for(p.planned_targets[0..p.width],0..) |pending,column| if(p.required[column]) {if(pending) |err| return err;};
                if(p.planned_error) |err| return err;
            }
            try validatePlannedPlan(context,seen,p.left);try validatePlannedPlan(context,seen,p.right);
            if(p.set_op!=.none) return;
            for(p.sources[0..p.source_count]) |source| try validatePlannedPlan(context,seen,source.plan);
            for(p.targets[0..p.width],0..) |id,column| if(p.required[column]) try validatePlannedTree(constant_context,seen,id);
            for(p.keys[0..p.key_count]) |id| try validatePlannedTree(constant_context,seen,id);
            if(!p.planned_checked) for(p.aggs[0..p.agg_count]) |agg| {try validatePlannedTree(constant_context,seen,agg.arg);try validatePlannedTree(constant_context,seen,agg.filter);};
            for(p.sources[0..p.source_count]) |source| try validatePlannedTree(constant_context,seen,source.on);
            try validatePlannedTree(constant_context,seen,p.where);try validatePlannedTree(constant_context,seen,p.having);
            if(!p.planned_checked) for(p.windows[0..p.window_count]) |win| {
                for([_]u16{win.deferred_arg,win.deferred_filter,win.offset_arg,win.default_arg,win.start.offset,win.end.offset}) |id| try validatePlannedTree(constant_context,seen,id);
            };
        }

        fn validatePlannedExpressions(context:*const Context, bound:*const Bound) Error!void {
            var state:PlannedValidation=.{};const seen=&state;
            switch(bound.*) {
                .query=>|root| try validatePlannedPlan(context,seen,root),
                .select=>|*select| {
                    for(select.targets[0..select.count]) |id| try validatePlannedTree(context,seen,id);
                    for(select.order[0..select.order_count]) |key| try validatePlannedTree(context,seen,key.expr);
                    try validatePlannedTree(context,seen,select.where);
                },
                .insert=>|*insert| {
                    try validatePlannedPlan(context,seen,insert.plan);
                    var row=insert.rows;
                    while(row!=none):(row=context.node(row).next) {
                        var item=context.node(row).b;
                        while(item!=none):(item=context.node(item).next) try validatePlannedTree(context,seen,item);
                    }
                    try validatePlannedStored(context,seen,insert.table,&insert.defaults);
                    try validatePlannedStored(context,seen,insert.table,&insert.generated);
                    if(insert.conflict.action==.update) try validatePlannedUpdate(context,seen,&insert.conflict.update);
                    try validatePlannedReturning(context,seen,&insert.returning);
                },
                .update=>|*update| try validatePlannedUpdate(context,seen,update),
                .delete=>|*delete| {try validatePlannedTree(context,seen,delete.where);try validatePlannedReturning(context,seen,&delete.returning);},
                else=>{},
            }
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
                    const namespace = try qualifierNamespace(context, create.schema);
                    // pg_catalog / information_schema are not writable here.
                    if (namespace == catalog.catalog_namespace or namespace == catalog.information_namespace) return error.UnsupportedStatement;
                    if (context.catalog.findIn(namespace, table_name.slice(), context.snapshot) != null) {
                        if (create.if_not_exists) return .{ .noop = .create_table };
                        return error.TableExists;
                    }
                    if (create.invalid_definition) return error.Syntax;
                    if (create.like != null or create.inherits != null or create.partition_by != .none or create.partition_of != null or create.as_query != none) return error.UnsupportedStatement;
                    var out: Create = .{ .name = table_name, .columns = @splat(.{}), .count = create.count, .namespace = namespace };
                    // Owned sequences live in public: identity and SERIAL
                    // columns stay outside other schemas (0A000).
                    if (namespace != catalog.public_namespace) for (create.columns[0..create.count]) |*definition| {
                        if (definition.serial != 0 or definition.default_kind == .identity_always or definition.default_kind == .identity_by_default) return error.UnsupportedStatement;
                    };
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
                        if (definition.serial != 0) {
                            // PostgreSQL: multiple default values (42601).
                            if (definition.default_kind != .none) return error.Syntax;
                            const seq_name = try serialSequence(context, &out, column.name);
                            column.not_null = true;
                            column.default_kind = .default;
                            column.expression = try serialDefault(seq_name);
                            out.serials[out.serial_count] = .{ .column = @intCast(index), .name = seq_name, .spec = try sequence.resolve(.{ .type_oid = definition.serial }) };
                            out.serial_count += 1;
                        }
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
                    try bindTableConstraints(context, create.constraints[0..create.constraint_count], &out);
                    return .{ .create_table = out };
                },
                .drop_table => |drop| {
                    const wanted = toName(context, drop.name);
                    const namespace = qualifierNamespace(context, drop.schema) catch |err| {
                        if (err == error.UndefinedSchema and drop.if_exists) return .{ .noop = .drop_table };
                        return err;
                    };
                    const found = context.catalog.findIn(namespace, wanted.slice(), context.snapshot) orelse {
                        if (drop.if_exists) return .{ .noop = .drop_table };
                        return error.TableNotFound;
                    };
                    if (found.kind != 'r' and found.kind != 'p') return error.WrongObjectType;
                    if (drop.cascade) return .{ .drop_relation = .{ .slot = found.slot, .cascade = true, .command = .drop_table } };
                    return .{ .drop_table = found.slot };
                },
                .create_sequence => |*create| {
                    const name = toName(context, create.name);
                    if (context.catalog.find(name.slice(), context.snapshot) != null) {
                        if (create.if_not_exists) return .{ .noop = .create_sequence };
                        return error.TableExists;
                    }
                    return .{ .create_sequence = .{ .name = name, .spec = try sequence.resolve(create.options) } };
                },
                .drop_sequence => |drop| {
                    const wanted = toName(context, drop.name);
                    const found = context.catalog.find(wanted.slice(), context.snapshot) orelse {
                        if (drop.if_exists) return .{ .noop = .drop_sequence };
                        return error.TableNotFound;
                    };
                    if (found.kind != 'S') return error.WrongObjectType;
                    return .{ .drop_sequence = found.slot };
                },
                .insert => |*insert| {
                    const index = try writableTable(context, try resolveQualified(context, insert.schema, insert.table), true);
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
                    try bindChecks(context, index, entry, &out.checks);
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
                    const index = try writableTable(context, try resolveQualified(context, update.schema, update.table), false);
                    const entry = &context.tables[index];
                    var scope = tableScope(context, index);
                    if (update.alias) |alias| scope.rels[0].name = toName(context, alias);
                    var out: Update = .{ .table = index, .values = @splat(none), .where = none, .key = none };
                    if (update.from != none) try bindSources(context, update.from, &scope, &out.from, &out.offsets);
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
                    // The key probe reads relation 0 only: no probe with FROM.
                    out.key = if (out.from != none) none else primaryKey(context, entry, out.where);
                    const needed = assignedDefaults(context, &out.values);
                    try bindDefaults(context, index, entry, &needed, &out.defaults, &out.generated);
                    try bindChecks(context, index, entry, &out.checks);
                    out.returning = try bindReturning(context, index, &update.returning, update.alias);
                    return .{ .update = out };
                },
                .delete => |*delete| {
                    const index = try writableTable(context, try resolveQualified(context, delete.schema, delete.table), false);
                    var scope = tableScope(context, index);
                    if (delete.alias) |alias| scope.rels[0].name = toName(context, alias);
                    var out: Delete = .{ .table = index, .where = none, .key = none };
                    if (delete.using != none) try bindSources(context, delete.using, &scope, &out.using, &out.offsets);
                    out.where = try bindWhere(context, &scope, delete.where);
                    out.returning = try bindReturning(context, index, &delete.returning, delete.alias);
                    if (out.using == none) out.key = primaryKey(context, &context.tables[index], out.where);
                    return .{ .delete = out };
                },
                .control => |control| return .{ .control = control },
                // COPY runs through Database.copyInfo/copyBegin, never as a statement.
                .copy => return error.UnsupportedStatement,
                .truncate => |*truncate| return .{ .truncate = try bindTruncate(context, truncate) },
                .alter_table => |*alter| return bindAlter(context, alter),
                .create_schema => |*create| {
                    const name = toName(context, create.name);
                    var exists = context.catalog.findSchema(name.slice(), context.snapshot) != null;
                    for (catalog.namespaces) |namespace| exists = exists or types.same(namespace.name, name.slice());
                    if (exists) {
                        if (create.if_not_exists) return .{ .noop = .create_schema };
                        return error.DuplicateSchema;
                    }
                    return .{ .create_schema = name };
                },
                .drop_schema => |*drop| {
                    const name = toName(context, drop.name);
                    for (catalog.namespaces) |namespace| if (types.same(namespace.name, name.slice())) return error.UnsupportedStatement;
                    const found = context.catalog.findSchema(name.slice(), context.snapshot) orelse {
                        if (drop.if_exists) return .{ .noop = .drop_schema };
                        return error.UndefinedSchema;
                    };
                    return .{ .drop_schema = .{ .slot = found.slot, .oid = found.oid, .cascade = drop.cascade } };
                },
                .create_index => |*create| return bindCreateIndex(context, create),
                .drop_index => |*drop| return bindDropIndex(context, drop),
                .create_view => |*create| return bindCreateView(context, create),
                .drop_view => |*drop| return bindDropView(context, &drop.drop, drop.materialized),
                .refresh_view => |*refresh| return bindRefresh(context, refresh.name, refresh.with_data),
                .merge => |*merge| return bindMerge(context, merge),
                .set_constraints => |*set| return bindSetConstraints(context, set),
                .alter_sequence => |*alter| {
                    if (alter.name.schema) |qualifier| {
                        if (!types.same(toName(context, qualifier).slice(), "public")) return error.TableNotFound;
                    }
                    const wanted = toName(context, alter.name.name);
                    const found = context.catalog.find(wanted.slice(), context.snapshot) orelse {
                        if (alter.if_exists) return .{ .noop = .alter_sequence };
                        return error.TableNotFound;
                    };
                    if (found.kind != 'S') return error.WrongObjectType;
                    return .{ .alter_sequence = .{ .slot = found.slot, .options = alter.options } };
                },
            }
        }

        /// A SERIAL column's sequence `<table>_<column>_seq` (ChooseRelationName
        /// numbering when taken) and its DEFAULT text nextval('name'::regclass).
        fn serialSequence(context: *const Context, out: *const Create, column: V.Name) Error!V.Name {
            var taken: [config.columns + 1]S.Constraint = undefined;
            var count: usize = 0;
            for (out.serials[0..out.serial_count]) |serial| {
                taken[count] = .{ .name = serial.name };
                count += 1;
            }
            if (out.identity) |identity| {
                taken[count] = .{ .name = identity.name };
                count += 1;
            }
            return chooseName(context, out.name.slice(), column.slice(), "seq", taken[0..count], true);
        }

        fn serialDefault(name: V.Name) Error!V.Text {
            var out: V.Text = .{};
            try appendText(&out, "nextval('");
            var plain = name.len != 0 and !types.digit(name.bytes[0]);
            for (name.slice()) |byte| {
                if (!((byte >= 'a' and byte <= 'z') or types.digit(byte) or byte == '_')) plain = false;
            }
            if (!plain) try appendText(&out, "\"");
            for (name.slice()) |byte| try appendText(&out, if (byte == '\'') "''" else if (byte == '"') "\"\"" else &[_]u8{byte});
            if (!plain) try appendText(&out, "\"");
            try appendText(&out, "'::regclass)");
            return out;
        }

        // ---- ALTER TABLE ------------------------------------------------

        /// Quotes a name for stored expression text when it is not a plain
        /// lower-case, non-keyword identifier.
        fn appendIdentifier(out: *V.Text, name: []const u8) Error!void {
            var plain = name.len != 0 and !types.digit(name[0]) and lexer.classify(name) == .none;
            for (name) |byte| {
                if (!((byte >= 'a' and byte <= 'z') or types.digit(byte) or byte == '_')) plain = false;
            }
            if (plain) return appendText(out, name);
            try appendText(out, "\"");
            for (name) |byte| try appendText(out, if (byte == '"') "\"\"" else &[_]u8{byte});
            try appendText(out, "\"");
        }

        fn appendText(out: *V.Text, bytes: []const u8) Error!void {
            if (bytes.len > config.text_bytes - out.len) return error.TextCapacity;
            @memcpy(out.bytes[out.len..][0..bytes.len], bytes);
            out.len += bytes.len;
        }

        /// Rewrites column references `from` -> `to` in stored expression
        /// text (CHECK, generation) token by token. A name followed by `(`
        /// (a call) or `.` (a qualifier) is kept; other bytes are copied.
        fn renameReferences(text: []const u8, from: []const u8, to: []const u8) Error!V.Text {
            var out: V.Text = .{};
            var tokens: lexer.Tokenizer = .{ .source = text, .text_limit = config.text_bytes };
            var copied: usize = 0;
            var current = try tokens.next();
            while (current.kind != .end) {
                var ahead = tokens;
                const next = try ahead.next();
                if (current.kind == .word or current.kind == .quoted_word) {
                    var decoded: [config.name_bytes]u8 = undefined;
                    var matches = false;
                    if (current.kind == .word) {
                        const raw = current.raw(text);
                        matches = raw.len == from.len;
                        if (matches) for (raw, from) |byte, wanted| {
                            if (types.lower(byte) != wanted) matches = false;
                        };
                    } else if (current.len == from.len) {
                        lexer.decodeQuotedWith(text, current.quoted(), '"', &decoded);
                        matches = types.same(decoded[0..current.len], from);
                    }
                    const call = next.kind == .symbol and next.symbol == .lparen;
                    const qualifier = next.kind == .symbol and next.symbol == .dot;
                    if (matches and !call and !qualifier) {
                        const quoted = current.kind == .quoted_word;
                        const begin = if (quoted) current.start - 1 else current.start;
                        try appendText(&out, text[copied..begin]);
                        try appendIdentifier(&out, to);
                        copied = if (quoted) current.end + 1 else current.end;
                    }
                }
                current = try tokens.next();
            }
            try appendText(&out, text[copied..]);
            return out;
        }

        /// Columns of `columns` named by stored expression text.
        fn textColumns(context: *const Context, text: []const u8, columns: []const V.Column) Error![config.columns]bool {
            var seen: [config.columns]bool = @splat(false);
            const saved = context.pool.len;
            defer context.pool.len = saved;
            var sub = context.*;
            sub.source = text;
            const id = try P.parseExpression(text, context.pool);
            referencedColumns(&sub, id, columns, &seen);
            return seen;
        }

        /// A default that must be evaluated per row (volatile function or
        /// subquery): ALTER TABLE ADD COLUMN would need a table rewrite.
        fn volatileDefault(context: *const Context, id: u16) bool {
            if (id == none) return false;
            const n = context.node(id);
            switch (n.kind) {
                .scalar_subquery, .exists_subquery, .in_subquery => return true,
                .function => switch (n.func) {
                    .nextval, .setval, .currval, .lastval, .identity_next, .clock_timestamp => return true,
                    else => {},
                },
                else => {},
            }
            if (volatileDefault(context, n.a) or volatileDefault(context, n.c)) return true;
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) if (volatileDefault(context, item)) return true;
                return false;
            }
            return volatileDefault(context, n.b);
        }

        /// NUL-separated index expression texts.
        const Parts = struct {
            text: []const u8,
            at: usize = 0,
            done: bool = false,
            fn next(self: *Parts) ?[]const u8 {
                if (self.done or self.text.len == 0) return null;
                var end = self.at;
                while (end < self.text.len and self.text[end] != 0) end += 1;
                const part = self.text[self.at..end];
                if (end == self.text.len) self.done = true else self.at = end + 1;
                return part;
            }
        };

        fn std_split(text: []const u8) Parts {
            return .{ .text = text };
        }

        fn renameParts(text: []const u8, from: []const u8, to: []const u8) Error!V.Text {
            var out: V.Text = .{};
            var parts = std_split(text);
            var first = true;
            while (parts.next()) |part| {
                const renamed = try renameReferences(part, from, to);
                if (!first) {
                    if (out.len == config.text_bytes) return error.TextCapacity;
                    out.bytes[out.len] = 0;
                    out.len += 1;
                }
                first = false;
                if (renamed.len > config.text_bytes - out.len) return error.TextCapacity;
                @memcpy(out.bytes[out.len..][0..renamed.len], renamed.slice());
                out.len += renamed.len;
            }
            return out;
        }

        /// A visible table that inherits from (or is a partition of) `oid`.
        fn hasChildren(context: *const Context, oid: u32) bool {
            var slots: [K.relation_rows]usize = undefined;
            const count = visibleTables(context, &slots);
            for (slots[0..count]) |slot| if (context.tables[slot].parent == oid) return true;
            return false;
        }

        /// A visible view or materialized view that reads relation `oid`.
        fn dependentViews(context: *const Context, oid: u32) bool {
            var slots: [K.relation_rows]usize = undefined;
            const count = visibleTables(context, &slots);
            for (slots[0..count]) |slot| {
                const entry = &context.tables[slot];
                for (entry.depends[0..entry.depend_count]) |depend| if (depend == oid) return true;
            }
            return false;
        }

        /// Column `column` of `entry` is referenced by another table's
        /// FOREIGN KEY.
        fn referencedColumn(context: *const Context, entry: *const S.Table, column: usize) bool {
            var slots: [K.relation_rows]usize = undefined;
            const count = visibleTables(context, &slots);
            for (slots[0..count]) |slot| {
                const other = &context.tables[slot];
                if (other.oid == entry.oid) continue;
                for (other.constraints[0..other.constraint_count]) |*constraint| {
                    if (constraint.kind != .foreign or constraint.ref_oid != entry.oid) continue;
                    for (constraint.refColumns()) |key| if (key == column) return true;
                }
            }
            return false;
        }

        fn alterColumn(out: *const AlterTable, name: []const u8) ?usize {
            for (out.columns[0..out.count], 0..) |*column, index| if (types.same(column.name.slice(), name)) return index;
            return null;
        }

        fn removeConstraint(out: *AlterTable, index: usize) void {
            var at = index;
            while (at + 1 < out.constraint_count) : (at += 1) {
                out.constraints[at] = out.constraints[at + 1];
                out.check_constraint[at] = out.check_constraint[at + 1];
            }
            out.constraint_count -= 1;
            out.check_constraint[out.constraint_count] = false;
        }

        fn inPrimaryKey(out: *const AlterTable, column: usize) bool {
            if (out.columns[column].primary_key) return true;
            for (out.constraints[0..out.constraint_count]) |*constraint| {
                if (constraint.kind != .primary) continue;
                for (constraint.keyColumns()) |key| if (key == column) return true;
            }
            return false;
        }

        fn bindAlter(context: *const Context, alter: *const Ast.AlterTable) Error!Bound {
            const wanted = toName(context, alter.table.name);
            const namespace = qualifierNamespace(context, alter.table.schema) catch |err| {
                if (err == error.UndefinedSchema and alter.if_exists) return .{ .noop = .alter_table };
                return err;
            };
            const found = context.catalog.findIn(namespace, wanted.slice(), context.snapshot) orelse {
                if (alter.if_exists) return .{ .noop = .alter_table };
                return error.TableNotFound;
            };
            if (found.kind != 'r') return error.WrongObjectType;
            const index = found.slot;
            const entry = &context.tables[index];
            if (entry.relkind != 'r') return error.WrongObjectType;
            var out = alterOf(context, index, .alter_table);
            // Inheritance and partition definitions keep their column lists.
            if (entry.parent != 0 or hasChildren(context, entry.oid)) for (alter.actions[0..alter.count]) |*action| switch (action.*) {
                .add_column, .drop_column, .rename_column => return error.UnsupportedStatement,
                else => {},
            };
            // Views keep their stored text: their tables keep column names.
            if (dependentViews(context, entry.oid)) for (alter.actions[0..alter.count]) |*action| switch (action.*) {
                .drop_column => return error.DependentObjects,
                .rename_column, .rename_table => return error.UnsupportedStatement,
                else => {},
            };
            for (alter.actions[0..alter.count]) |*action| switch (action.*) {
                .add_column => |*add| {
                    const definition = &add.column;
                    const name = toName(context, definition.name);
                    if (alterColumn(&out, name.slice()) != null) {
                        if (add.if_not_exists) continue;
                        return error.DuplicateColumn;
                    }
                    if (out.count == config.columns) return error.ColumnCapacity;
                    var column: V.Column = .{ .name = name, .not_null = definition.not_null, .typmod = definition.typmod, .default_kind = definition.default_kind };
                    column.data_type = columnType(context, definition);
                    switch (definition.default_kind) {
                        // Identity and stored generation need per-row values
                        // (a table rewrite); a new primary key needs an index.
                        .identity_always, .identity_by_default, .generated => return error.UnsupportedStatement,
                        else => {},
                    }
                    if (definition.primary_key) return error.UnsupportedStatement;
                    const text = definition.expression.slice(context.source);
                    if (text.len > config.text_bytes) return error.TextCapacity;
                    column.expression.len = text.len;
                    @memcpy(column.expression.bytes[0..text.len], text);
                    if (column.default_kind == .default) {
                        const id = try bindExpressionText(context, &column, null, -1);
                        if (volatileDefault(context, id)) return error.UnsupportedStatement;
                        out.fills[out.count] = id;
                    }
                    out.sources[out.count] = 0xff;
                    out.check_not_null[out.count] = column.not_null;
                    out.columns[out.count] = column;
                    out.count += 1;
                },
                .drop_column => |*drop| {
                    const name = toName(context, drop.name);
                    const position = alterColumn(&out, name.slice()) orelse {
                        if (drop.if_exists) continue;
                        return error.ColumnNotFound;
                    };
                    // A table keeps at least one column; identity columns
                    // keep their positions (their sequences record them).
                    if (out.count == 1) return error.UnsupportedStatement;
                    for (out.columns[position..out.count]) |*column| switch (column.default_kind) {
                        .identity_always, .identity_by_default => return error.UnsupportedStatement,
                        else => {},
                    };
                    for (out.columns[0..out.count], 0..) |*column, other| {
                        if (other == position or column.default_kind != .generated) continue;
                        const seen = try textColumns(context, column.expression.slice(), out.columns[0..out.count]);
                        if (seen[position]) return error.DependentObjects;
                    }
                    // Other tables' foreign keys referencing it: 2BP01.
                    if (referencedColumn(context, entry, out.sources[position])) return error.DependentObjects;
                    // Indexes over the column go with it (PostgreSQL drops them).
                    var kept: usize = 0;
                    for (out.extras.indexes[0..out.extras.index_count]) |*candidate| {
                        var uses = false;
                        for (candidate.keyColumns()) |key| uses = uses or key == position;
                        for (candidate.includes[0..candidate.include_count]) |key| uses = uses or key == position;
                        for ([_][]const u8{ candidate.expressions.slice(), candidate.predicate.slice() }) |text| {
                            var parts = std_split(text);
                            while (parts.next()) |part| {
                                const seen = try textColumns(context, part, out.columns[0..out.count]);
                                uses = uses or seen[position];
                            }
                        }
                        if (uses) continue;
                        var copy = candidate.*;
                        for (copy.keys[0..copy.key_count]) |*key| if (key.* != S.expression_key and key.* > position) {
                            key.* -= 1;
                        };
                        for (copy.includes[0..copy.include_count]) |*key| if (key.* > position) {
                            key.* -= 1;
                        };
                        out.extras.indexes[kept] = copy;
                        kept += 1;
                    }
                    out.extras.index_count = kept;
                    // Constraints over the column go with it.
                    var at: usize = 0;
                    while (at < out.constraint_count) {
                        const constraint = &out.constraints[at];
                        var uses = false;
                        if (constraint.kind == .check) {
                            const seen = try textColumns(context, constraint.expression.slice(), out.columns[0..out.count]);
                            uses = seen[position];
                        } else for (constraint.keyColumns()) |key| {
                            if (key == position) uses = true;
                        }
                        if (uses) {
                            removeConstraint(&out, at);
                            continue;
                        }
                        for (constraint.columns[0..constraint.column_count]) |*key| {
                            if (key.* > position) key.* -= 1;
                        }
                        at += 1;
                    }
                    var column = position;
                    while (column + 1 < out.count) : (column += 1) {
                        out.columns[column] = out.columns[column + 1];
                        out.sources[column] = out.sources[column + 1];
                        out.fills[column] = out.fills[column + 1];
                        out.check_not_null[column] = out.check_not_null[column + 1];
                    }
                    out.count -= 1;
                },
                .rename_column => |*rename| {
                    const from = toName(context, rename.from);
                    const to = toName(context, rename.to);
                    const position = alterColumn(&out, from.slice()) orelse return error.ColumnNotFound;
                    if (alterColumn(&out, to.slice()) != null) return error.DuplicateColumn;
                    out.columns[position].name = to;
                    for (out.columns[0..out.count]) |*column| {
                        if (column.default_kind == .generated) column.expression = try renameReferences(column.expression.slice(), from.slice(), to.slice());
                    }
                    for (out.constraints[0..out.constraint_count]) |*constraint| {
                        if (constraint.kind == .check) constraint.expression = try renameReferences(constraint.expression.slice(), from.slice(), to.slice());
                    }
                    for (out.extras.indexes[0..out.extras.index_count]) |*candidate| {
                        candidate.expressions = try renameParts(candidate.expressions.slice(), from.slice(), to.slice());
                        candidate.predicate = try renameReferences(candidate.predicate.slice(), from.slice(), to.slice());
                    }
                },
                .set_default => |*set| {
                    const position = alterColumn(&out, toName(context, set.column).slice()) orelse return error.ColumnNotFound;
                    const column = &out.columns[position];
                    if (column.default_kind != .none and column.default_kind != .default) return error.Syntax;
                    const text = set.expression.slice(context.source);
                    if (text.len > config.text_bytes) return error.TextCapacity;
                    var candidate = column.*;
                    candidate.default_kind = .default;
                    candidate.expression.len = text.len;
                    @memcpy(candidate.expression.bytes[0..text.len], text);
                    _ = try bindExpressionText(context, &candidate, null, -1);
                    column.* = candidate;
                },
                .drop_default => |ident| {
                    const position = alterColumn(&out, toName(context, ident).slice()) orelse return error.ColumnNotFound;
                    const column = &out.columns[position];
                    if (column.default_kind != .none and column.default_kind != .default) return error.Syntax;
                    column.default_kind = .none;
                    column.expression = .{};
                },
                .set_not_null => |ident| {
                    const position = alterColumn(&out, toName(context, ident).slice()) orelse return error.ColumnNotFound;
                    if (!out.columns[position].not_null) out.check_not_null[position] = true;
                    out.columns[position].not_null = true;
                },
                .drop_not_null => |ident| {
                    const position = alterColumn(&out, toName(context, ident).slice()) orelse return error.ColumnNotFound;
                    if (inPrimaryKey(&out, position)) return error.InvalidTableDefinition;
                    switch (out.columns[position].default_kind) {
                        .identity_always, .identity_by_default => return error.Syntax,
                        else => {},
                    }
                    out.columns[position].not_null = false;
                    out.check_not_null[position] = false;
                },
                .add_constraint => |*definition| {
                    if (definition.kind == .primary) return error.UnsupportedStatement;
                    if (definition.name) |ident| {
                        const name = toName(context, ident);
                        for (out.constraints[0..out.constraint_count]) |*constraint| if (types.same(constraint.name.slice(), name.slice())) return error.DuplicateObject;
                    }
                    var staged: Create = .{ .name = out.name, .columns = out.columns, .count = out.count, .constraints = out.constraints, .constraint_count = out.constraint_count };
                    try bindTableConstraints(context, (definition)[0..1], &staged);
                    if (staged.constraint_count != out.constraint_count + 1) return error.UnsupportedStatement;
                    out.columns = staged.columns;
                    out.constraints = staged.constraints;
                    out.check_constraint[out.constraint_count] = true;
                    out.constraint_count += 1;
                },
                .drop_constraint => |*drop| {
                    const name = toName(context, drop.name);
                    var dropped = false;
                    for (out.constraints[0..out.constraint_count], 0..) |*constraint, at| {
                        if (!types.same(constraint.name.slice(), name.slice())) continue;
                        if (constraint.kind == .primary) for (out.columns[0..out.count]) |*column| {
                            column.primary_key = false;
                        };
                        removeConstraint(&out, at);
                        dropped = true;
                        break;
                    }
                    if (!dropped) {
                        // The default-named single-column primary key.
                        const pkey = objectName(out.name.slice(), "", "pkey");
                        for (out.columns[0..out.count]) |*column| if (column.primary_key and types.same(pkey.slice(), name.slice())) {
                            column.primary_key = false;
                            dropped = true;
                        };
                    }
                    if (!dropped and !drop.if_exists) return error.UndefinedObject;
                },
                .rename_table => |ident| {
                    const name = toName(context, ident);
                    if (context.catalog.findIn(entry.namespace, name.slice(), context.snapshot) != null) return error.TableExists;
                    // PostgreSQL keeps the index name `<old>_pkey`.
                    var primary = false;
                    for (out.columns[0..out.count]) |*column| primary = primary or column.primary_key;
                    var named = false;
                    for (out.constraints[0..out.constraint_count]) |*constraint| named = named or constraint.kind == .primary;
                    if (primary and !named) {
                        if (out.constraint_count == config.table_constraints) return error.ColumnCapacity;
                        var constraint: S.Constraint = .{ .kind = .primary, .name = objectName(out.name.slice(), "", "pkey"), .column_count = 1 };
                        for (out.columns[0..out.count], 0..) |*column, position| if (column.primary_key) {
                            constraint.columns[0] = @intCast(position);
                        };
                        out.constraints[out.constraint_count] = constraint;
                        out.constraint_count += 1;
                    }
                    out.name = name;
                },
            };
            return .{ .alter_table = out };
        }

        // ---- table constraints (CREATE TABLE / ALTER TABLE ADD) ----------

        /// PostgreSQL makeObjectName: name1[_name2]_label, shortening the
        /// longer part first so the whole fits NAMEDATALEN - 1 (63) bytes and
        /// Config.name_bytes.
        fn objectName(name1: []const u8, name2: []const u8, label: []const u8) V.Name {
            const limit = @min(@as(usize, 63), config.name_bytes);
            const overhead = label.len + 1 + (if (name2.len != 0) @as(usize, 1) else 0);
            const available = if (limit > overhead) limit - overhead else 0;
            var first = name1.len;
            var second = name2.len;
            while (first + second > available) {
                if (first > second) first -= 1 else second -= 1;
            }
            var out: V.Name = .{};
            const parts = [_][]const u8{ name1[0..first], if (name2.len != 0) "_" else "", name2[0..second], "_", label };
            for (parts) |part| {
                const room = config.name_bytes - out.len;
                const take = @min(room, part.len);
                @memcpy(out.bytes[out.len..][0..take], part[0..take]);
                out.len += take;
            }
            return out;
        }

        /// A constraint name already used by this definition, by another
        /// visible table's constraint (PostgreSQL names are per schema) or,
        /// for index-backed kinds, by a relation.
        fn constraintNameUsed(context: *const Context, table_name: []const u8, taken: []const S.Constraint, name: []const u8, relation: bool) bool {
            for (taken) |*constraint| if (types.same(constraint.name.slice(), name)) return true;
            if (relation) {
                if (types.same(table_name, name)) return true;
                if (context.catalog.find(name, context.snapshot) != null) return true;
            }
            var relations: [K.relation_rows]K.Found = undefined;
            const count = context.catalog.visibleRelations(context.snapshot, &relations);
            for (relations[0..count]) |found| {
                if (found.kind != 'r') continue;
                const entry = &context.tables[found.slot];
                if (types.same(entry.name.slice(), table_name)) continue;
                for (entry.constraints[0..entry.constraint_count]) |*constraint| if (types.same(constraint.name.slice(), name)) return true;
            }
            return false;
        }

        /// ChooseConstraintName / ChooseRelationName: label, then label1,
        /// label2, ... until unused.
        fn chooseName(context: *const Context, table_name: []const u8, name2: []const u8, label: []const u8, taken: []const S.Constraint, relation: bool) V.Name {
            var pass: usize = 0;
            while (true) : (pass += 1) {
                var buffer: [24]u8 = undefined;
                @memcpy(buffer[0..label.len], label);
                var length = label.len;
                if (pass != 0) {
                    var digits: [20]u8 = undefined;
                    var at: usize = digits.len;
                    var rest = pass;
                    while (true) {
                        at -= 1;
                        digits[at] = @intCast('0' + rest % 10);
                        rest /= 10;
                        if (rest == 0) break;
                    }
                    @memcpy(buffer[length..][0 .. digits.len - at], digits[at..]);
                    length += digits.len - at;
                }
                const candidate = objectName(table_name, name2, buffer[0..length]);
                if (!constraintNameUsed(context, table_name, taken, candidate.slice(), relation)) return candidate;
            }
        }

        fn definitionColumn(columns: []const V.Column, name: []const u8) ?u8 {
            for (columns, 0..) |*column, index| if (types.same(column.name.slice(), name)) return @intCast(index);
            return null;
        }

        /// Distinct columns of the definition a parsed expression names.
        fn referencedColumns(context: *const Context, id: u16, columns: []const V.Column, seen: *[config.columns]bool) void {
            if (id == none) return;
            const n = context.node(id);
            if (n.kind == .column and !n.star) {
                const name = toName(context, n.name);
                if (definitionColumn(columns, name.slice())) |column| seen[column] = true;
            }
            referencedColumns(context, n.a, columns, seen);
            referencedColumns(context, n.c, columns, seen);
            if (listOwner(n.kind)) {
                var item = n.b;
                while (item != none) : (item = context.node(item).next) referencedColumns(context, item, columns, seen);
            } else referencedColumns(context, n.b, columns, seen);
        }

        /// Resolves CHECK / UNIQUE / PRIMARY KEY definitions against the
        /// column list into named constraints. A single-column PRIMARY KEY
        /// marks its column (and keeps an entry only for a CONSTRAINT name);
        /// key columns become NOT NULL. Explicit duplicate names are 42710,
        /// index names already used by a relation 42P07, more than
        /// Config.table_constraints entries ColumnCapacity (54000).
        fn bindTableConstraints(context: *const Context, definitions: []const Ast.ConstraintDef, out: *Create) Error!void {
            const columns = out.columns[0..out.count];
            // Explicit names first, so generated names avoid them.
            for (definitions, 0..) |*definition, position| if (definition.name) |ident| {
                const name = toName(context, ident);
                for (definitions[0..position]) |*earlier| if (earlier.name) |other| {
                    if (types.same(toName(context, other).slice(), name.slice())) return error.DuplicateObject;
                };
                if (definition.kind != .check and definition.kind != .foreign and (types.same(name.slice(), out.name.slice()) or context.catalog.find(name.slice(), context.snapshot) != null)) return error.TableExists;
            };
            var named: [config.table_constraints]S.Constraint = undefined;
            var named_count: usize = 0;
            for (definitions) |*definition| if (definition.name) |ident| {
                named[named_count] = .{ .name = toName(context, ident) };
                named_count += 1;
            };
            for (definitions) |*definition| {
                var entry: S.Constraint = .{ .nulls_not_distinct = definition.nulls_not_distinct, .deferrable = definition.deferrable, .initially_deferred = definition.initially_deferred, .kind = switch (definition.kind) {
                    .check => .check,
                    .unique => .unique,
                    .primary => .primary,
                    .foreign => .foreign,
                    .exclusion => .exclusion,
                } };
                for (definition.columns[0..definition.column_count]) |ident| {
                    const wanted = toName(context, ident);
                    const column = definitionColumn(columns, wanted.slice()) orelse return error.ColumnNotFound;
                    for (entry.keyColumns()) |previous| if (previous == column) return error.DuplicateColumn;
                    if (out.columns[column].data_type == .json) return error.UndefinedFunction;
                    entry.columns[entry.column_count] = column;
                    entry.column_count += 1;
                }
                var name2: [256]u8 = undefined;
                var name2_len: usize = 0;
                switch (definition.kind) {
                    .check => {
                        const text = definition.expression.slice(context.source);
                        if (text.len > config.text_bytes) return error.TextCapacity;
                        entry.expression.len = text.len;
                        @memcpy(entry.expression.bytes[0..text.len], text);
                        var seen: [config.columns]bool = @splat(false);
                        referencedColumns(context, definition.node, columns, &seen);
                        var referenced: ?usize = null;
                        var distinct: usize = 0;
                        for (seen, 0..) |hit, column| if (hit) {
                            distinct += 1;
                            referenced = column;
                        };
                        if (distinct == 1) {
                            const column_name = columns[referenced.?].name.slice();
                            @memcpy(name2[0..column_name.len], column_name);
                            name2_len = column_name.len;
                        }
                    },
                    .unique => for (entry.keyColumns(), 0..) |column, position| {
                        const column_name = columns[column].name.slice();
                        if (position != 0) {
                            name2[name2_len] = '_';
                            name2_len += 1;
                        }
                        const take = @min(column_name.len, name2.len - name2_len);
                        @memcpy(name2[name2_len..][0..take], column_name[0..take]);
                        name2_len += take;
                    },
                    .foreign => try bindForeignKey(context, definition, out, &entry, &name2, &name2_len),
                    .exclusion => try bindExclusion(context, definition, out, &entry, &name2, &name2_len),
                    .primary => {
                        if (definition.deferrable) return error.UnsupportedStatement;
                        for (entry.keyColumns()) |column| out.columns[column].not_null = true;
                        if (entry.column_count == 1) {
                            for (columns, 0..) |*column, index| if (column.primary_key and index != entry.columns[0]) return error.InvalidTableDefinition;
                            out.columns[entry.columns[0]].primary_key = true;
                            if (definition.name == null) continue;
                        } else for (columns) |*column| if (column.primary_key) return error.InvalidTableDefinition;
                    },
                }
                if (definition.name) |ident| {
                    entry.name = toName(context, ident);
                } else {
                    const label: []const u8 = switch (definition.kind) {
                        .check => "check",
                        .unique => "key",
                        .primary => "pkey",
                        .foreign => "fkey",
                        .exclusion => "excl",
                    };
                    const taken = out.constraints[0..out.constraint_count];
                    entry.name = if (definition.kind == .primary)
                        objectName(out.name.slice(), "", label)
                    else blk: {
                        // Generated names also avoid every explicit name.
                        var avoid: [2 * config.table_constraints]S.Constraint = undefined;
                        @memcpy(avoid[0..taken.len], taken);
                        @memcpy(avoid[taken.len..][0..named_count], named[0..named_count]);
                        break :blk chooseName(context, out.name.slice(), name2[0..name2_len], label, avoid[0 .. taken.len + named_count], definition.kind != .check and definition.kind != .foreign);
                    };
                }
                if (out.constraint_count == config.table_constraints) return error.ColumnCapacity;
                out.constraints[out.constraint_count] = entry;
                out.constraint_count += 1;
            }
        }

        /// FOREIGN KEY ... REFERENCES table [(columns)]: the referenced
        /// columns default to its primary key and must be exactly a primary
        /// key or non-deferrable UNIQUE constraint or index of it (42830);
        /// the column types must match (42804). A reference to the table
        /// being created keeps ref_oid 0 until CREATE assigns its OID.
        fn bindForeignKey(context: *const Context, definition: *const Ast.ConstraintDef, out: *Create, entry: *S.Constraint, name2: *[256]u8, name2_len: *usize) Error!void {
            const columns = out.columns[0..out.count];
            for (entry.keyColumns(), 0..) |column, position| {
                if (position != 0) {
                    name2[name2_len.*] = '_';
                    name2_len.* += 1;
                }
                const column_name = columns[column].name.slice();
                const take = @min(column_name.len, name2.len - name2_len.*);
                @memcpy(name2[name2_len.*..][0..take], column_name[0..take]);
                name2_len.* += take;
            }
            entry.on_delete = @enumFromInt(@intFromEnum(definition.on_delete));
            entry.on_update = @enumFromInt(@intFromEnum(definition.on_update));
            const referenced_name = toName(context, definition.ref_table.name);
            const namespace = try qualifierNamespace(context, definition.ref_table.schema);
            const self_reference = namespace == out.namespace and types.same(referenced_name.slice(), out.name.slice());
            var parent_columns: []const V.Column = columns;
            var parent: ?*const S.Table = null;
            if (!self_reference) {
                const slot = try resolveQualified(context, definition.ref_table.schema, definition.ref_table.name);
                const table = &context.tables[slot];
                if (table.relkind != 'r') return error.WrongObjectType;
                parent = table;
                parent_columns = table.columns[0..table.column_count];
                entry.ref_oid = table.oid;
            }
            var used: [config.columns]bool = @splat(false);
            if (definition.ref_count == 0) {
                // The referenced table's primary key.
                var found = false;
                for (parent_columns, 0..) |*column, index| if (column.primary_key) {
                    entry.ref_columns[0] = @intCast(index);
                    used[index] = true;
                    found = true;
                    if (entry.column_count != 1) return error.InvalidForeignKey;
                };
                if (!found) {
                    const keys: []const u8 = if (parent) |table| (if (S.primaryConstraint(table)) |index| table.constraints[index].keyColumns() else &.{}) else &.{};
                    if (keys.len == 0 or keys.len != entry.column_count) return error.InvalidForeignKey;
                    for (keys, 0..) |key, position| {
                        entry.ref_columns[position] = key;
                        used[key] = true;
                    }
                }
            } else {
                if (definition.ref_count != entry.column_count) return error.InvalidForeignKey;
                for (definition.ref_columns[0..definition.ref_count], 0..) |ident, position| {
                    const wanted = toName(context, ident);
                    const column = definitionColumn(parent_columns, wanted.slice()) orelse return error.ColumnNotFound;
                    if (used[column]) return error.InvalidForeignKey;
                    used[column] = true;
                    entry.ref_columns[position] = column;
                }
            }
            // The referenced columns must carry a unique index.
            var unique = false;
            if (parent) |table| {
                if (table.primary_column) |primary| {
                    var exact = true;
                    for (used, 0..) |flag, column| exact = exact and flag == (column == primary);
                    unique = exact;
                }
                for (table.constraints[0..table.constraint_count]) |*constraint| {
                    if (S.scannedUnique(table, constraint) and !constraint.deferrable and sameColumnSet(constraint.keyColumns(), &used)) unique = true;
                }
                for (table.indexes[0..table.index_count]) |*index| {
                    if (index.unique and sameColumnSet(index.keyColumns(), &used)) unique = true;
                }
            } else {
                for (columns, 0..) |*column, index| {
                    if (column.primary_key) {
                        var exact = true;
                        for (used, 0..) |flag, other| exact = exact and flag == (other == index);
                        unique = unique or exact;
                    }
                }
                for (out.constraints[0..out.constraint_count]) |*constraint| {
                    if ((constraint.kind == .unique or constraint.kind == .primary) and !constraint.deferrable and sameColumnSet(constraint.keyColumns(), &used)) unique = true;
                }
            }
            if (!unique) return error.InvalidForeignKey;
            for (entry.keyColumns(), entry.refColumns()) |child, key| {
                const a = types.typeOfData(columns[child].data_type);
                const b = types.typeOfData(parent_columns[key].data_type);
                const integral = (a == .int2 or a == .int4 or a == .int8) and (b == .int2 or b == .int4 or b == .int8);
                if (a != b and !integral) return error.TypeMismatch;
            }
        }

        fn bindExclusion(context: *const Context, definition: *const Ast.ConstraintDef, out: *Create, entry: *S.Constraint, name2: *[256]u8, name2_len: *usize) Error!void {
            _ = context;
            _ = definition;
            _ = out;
            _ = entry;
            _ = name2;
            _ = name2_len;
            return error.UnsupportedStatement;
        }

        /// CREATE VIEW / CREATE MATERIALIZED VIEW: the query is bound now
        /// (its output columns become the relation's columns; a column list
        /// renames them) and stored as text, expanded again by each reader.
        /// Dependencies are the tables its plans read (and the views the
        /// statement expanded, added by the caller).
        fn bindCreateView(context: *const Context, create: *const Ast.CreateView) Error!Bound {
            const name = toName(context, create.name.name);
            const namespace = try qualifierNamespace(context, create.name.schema);
            if (namespace == catalog.catalog_namespace or namespace == catalog.information_namespace) return error.UnsupportedStatement;
            const tag: types.CommandTag = if (create.materialized) .create_materialized_view else .create_view;
            if (relationNameTaken(context, namespace, name.slice())) {
                if (create.if_not_exists) return .{ .noop = tag };
                return error.TableExists;
            }
            const plans = context.plans orelse return error.UnsupportedStatement;
            plans.reset();
            const root = try bindPlan(context, create.query, null, null, false);
            try resolveUnknown(context, root);
            const plan = &plans.items[root];
            if (create.column_count > plan.count) return error.Syntax;
            if (create.column_count != 0) {
                const top = &context.pool.queries[create.query];
                var star = top.set_op != .none;
                for (top.targets[0..top.count]) |*target| star = star or target.star;
                if (star) return error.UnsupportedStatement;
            }
            var out: Create = .{ .name = name, .columns = @splat(.{}), .count = plan.count, .namespace = namespace, .command = tag };
            if (plan.count > config.columns) return error.ColumnCapacity;
            for (0..plan.count) |index| {
                var column: V.Column = .{ .name = plan.names[index], .data_type = dataType(plan.tys[index]), .typmod = plan.typmods[index] };
                if (index < create.column_count) column.name = toName(context, create.columns[index]);
                for (out.columns[0..index]) |*previous| if (types.same(previous.name.slice(), column.name.slice())) return error.DuplicateColumn;
                out.columns[index] = column;
            }
            const text = create.text.slice(context.source);
            if (text.len > config.text_bytes) return error.TextCapacity;
            out.extras.relkind = if (create.materialized) 'm' else 'v';
            out.extras.query.len = text.len;
            @memcpy(out.extras.query.bytes[0..text.len], text);
            for (plans.items[0..plans.len]) |*item| for (item.sources[0..item.source_count]) |*source| {
                const table = source.table orelse continue;
                const oid = context.tables[table].oid;
                var known = false;
                for (out.extras.depends[0..out.extras.depend_count]) |existing| known = known or existing == oid;
                if (known) continue;
                out.extras.depends[out.extras.depend_count] = oid;
                out.extras.depend_count += 1;
            };
            if (create.materialized) {
                out.extras.populated = create.with_data;
                if (create.with_data) out.plan = root;
            }
            return .{ .create_table = out };
        }

        /// DROP VIEW / DROP MATERIALIZED VIEW (42809 for another kind).
        fn bindDropView(context: *const Context, drop: *const Ast.Drop, materialized: bool) Error!Bound {
            const tag: types.CommandTag = if (materialized) .drop_materialized_view else .drop_view;
            const namespace = qualifierNamespace(context, drop.schema) catch |err| {
                if (err == error.UndefinedSchema and drop.if_exists) return .{ .noop = tag };
                return err;
            };
            const wanted = toName(context, drop.name);
            const found = context.catalog.findIn(namespace, wanted.slice(), context.snapshot) orelse {
                if (drop.if_exists) return .{ .noop = tag };
                return error.TableNotFound;
            };
            if (found.kind != @as(u8, if (materialized) 'm' else 'v')) return error.WrongObjectType;
            return .{ .drop_relation = .{ .slot = found.slot, .cascade = drop.cascade, .command = tag } };
        }

        fn bindRefresh(context: *const Context, name: Ast.TableRef, with_data: bool) Error!Bound {
            _ = context;
            _ = name;
            _ = with_data;
            return error.UnsupportedStatement;
        }

        fn bindMerge(context: *const Context, merge: *const Ast.Merge) Error!Bound {
            _ = context;
            _ = merge;
            return error.UnsupportedStatement;
        }

        /// SET CONSTRAINTS names: every visible constraint with the name
        /// (42704 when none, 42809 when one is not deferrable).
        fn bindSetConstraints(context: *const Context, set: *const Ast.SetConstraints) Error!Bound {
            var out: SetConstraints = .{ .all = set.all, .deferred = set.deferred };
            var slots: [K.relation_rows]usize = undefined;
            const count = visibleTables(context, &slots);
            for (set.names[0..set.count]) |ident| {
                const name = toName(context, ident);
                var found = false;
                for (slots[0..count]) |slot| {
                    const entry = &context.tables[slot];
                    for (entry.constraints[0..entry.constraint_count]) |*constraint| {
                        if (!types.same(constraint.name.slice(), name.slice())) continue;
                        if (!constraint.deferrable) return error.WrongObjectType;
                        if (out.count == out.names.len) return error.TableCapacity;
                        out.names[out.count] = .{ .oid = entry.oid, .name = name };
                        out.count += 1;
                        found = true;
                    }
                }
                if (!found) return error.UndefinedObject;
            }
            return .{ .set_constraints = out };
        }

        /// The identity ALTER TABLE of a table (facade-built rewrites such as
        /// DROP ... CASCADE removing a foreign key).
        pub fn identityAlter(context: *const Context, index: usize) AlterTable {
            return alterOf(context, index, .alter_table);
        }

        /// A bound DEFAULT of column `column` of table `index` (NULL when it
        /// has none), for ON DELETE / UPDATE SET DEFAULT.
        pub fn columnDefault(context: *const Context, index: usize, column: usize) Error!u16 {
            const entry = &context.tables[index];
            const definition = &entry.columns[column];
            return switch (definition.default_kind) {
                .default => try bindExpressionText(context, definition, null, storedSource(index, column)),
                .identity_always, .identity_by_default => try context.pool.add(.{ .kind = .function, .func = .identity_next, .integer = @intCast(index), .column = @intCast(column), .ty = types.typeOfData(definition.data_type) }),
                else => none,
            };
        }

        /// A user table (not a sequence or view): 42P01 when missing, 42809
        /// for another relation kind.
        fn resolveRelationTable(context: *const Context, reference: Ast.TableRef) Error!usize {
            if (reference.schema != null) return resolveQualified(context, reference.schema, reference.name);
            const wanted = toName(context, reference.name);
            const found = context.catalog.find(wanted.slice(), context.snapshot) orelse return error.TableNotFound;
            if (found.kind != 'r') return error.WrongObjectType;
            return found.slot;
        }

        fn bindTruncate(context: *const Context, truncate: *const Ast.Truncate) Error!Truncate {
            var out: Truncate = .{ .restart_identity = truncate.restart_identity };
            for (truncate.tables[0..truncate.count]) |reference| {
                const index: u8 = @intCast(try resolveRelationTable(context, reference));
                for (out.tables[0..out.count]) |previous| {
                    if (previous == index) break;
                } else {
                    out.tables[out.count] = index;
                    out.count += 1;
                }
            }
            return out;
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
            checks: [config.table_constraints]u16 = @splat(none),
        };

        /// PostgreSQL CopyGetAttnums: without a column list every
        /// non-generated column in order; listed generated columns are
        /// 42P10, repeated ones 42701. Identity columns accept the supplied
        /// value (COPY ignores GENERATED ALWAYS, as PostgreSQL does).
        pub fn bindCopy(context: *const Context, copy: *const Ast.Copy, with_defaults: bool) Error!Copy {
            const index = try writableTable(context, try resolveQualified(context, copy.table.schema, copy.table.name), false);
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
                try bindChecks(context, index, entry, &out.checks);
            }
            try validateDiscardedRows(context);
            if(context.pool.planned_nulls) {
                var seen:PlannedValidation=.{};
                try validatePlannedStored(context,&seen,index,&out.defaults);
                try validatePlannedStored(context,&seen,index,&out.generated);
            }
            return out;
        }
    };
}
