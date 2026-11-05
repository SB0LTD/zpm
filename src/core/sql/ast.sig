//! Statement syntax trees (Layer 0, design §4.1).
//! Identifiers and string literals are spans into the caller's source and are
//! only valid for the statement. Expression nodes live in a statement-scoped,
//! caller-owned pool (Database.workspace); exhausting it or exceeding
//! Config.expr_depth raises StatementTooComplex (SQLSTATE 54001). The binder
//! annotates nodes in place (types, column indices, coerced literals).
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const sequence = @import("sequence.sig");
const Error = types.Error;

/// Absent child / end of a sibling list.
pub const none: u16 = 0xffff;

pub const Span = struct {
    start: usize = 0,
    len: usize = 0,

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..][0..self.len];
    }
};

/// An identifier as written. Unquoted names fold to lower case; quoted
/// names keep their case and collapse `""`.
pub const Ident = struct {
    span: Span = .{},
    quoted: bool = false,
    /// Decoded length (quoted) or raw length.
    len: usize = 0,
};

/// Bound expression type (types.Type). Declared column and cast targets use
/// the same enum (never `unknown`) plus a typmod.
pub const Type = types.Type;
pub const TypeName = types.Type;

/// `arrow` ->, `arrow_text` ->>, `path` #>, `path_text` #>>, `contains` @>,
/// `contained` <@, `exists` ?.
pub const Op = enum { add, sub, mul, div, mod, concat, eq, ne, lt, le, gt, ge, neg, pos, arrow, arrow_text, path, path_text, contains, contained, exists, is_distinct, is_not_distinct,
    // Integer bitwise operators (B11): & | # << >> and prefix ~.
    bit_and, bit_or, bit_xor, shift_left, shift_right, bit_not,
    // Array/range overlap && (B11 advanced types).
    overlap,
    // Range &< &> -|-.
    over_left, over_right, adjacent,
    // Network <<= and >>=.
    within_eq, contains_eq,
    // Geometric <-> (distance) and ~= (same as).
    distance, same };

/// Built-in functions bound by name.
pub const Func = enum { none, grouping, window_call, to_char, now, transaction_timestamp, statement_timestamp, clock_timestamp, current_timestamp, current_date, jsonb_typeof, jsonb_array_length, nextval, currval, setval, lastval, identity_next, current_database, current_schema, to_regtype, to_regclass, format_type, pg_get_expr, regclass_in, regtype_in, regclass_out, regtype_out, round, abs, ceil, floor, trunc, sign, sqrt, greatest, least,
    // String functions (B11, functions_string.sig).
    lower, upper, initcap, char_length, octet_length, bit_length, substring, btrim, ltrim, rtrim, strpos, replace, left, right, repeat, reverse, lpad, rpad, split_part, starts_with, ascii, chr, translate, concat, concat_ws, overlay, to_hex,
    // Mathematical functions (B11, numeric_math.sig).
    power, ln, log, log10, exp, mod, div, pi, degrees, radians, cbrt, sin, cos, tan, cot, asin, acos, atan, atan2, gcd, lcm, scale, min_scale, trim_scale,
    // Date/time functions (B11, functions_temporal.sig); *_tz are the STABLE
    // timestamptz (session time zone) overloads chosen by the binder.
    extract, extract_tz, date_part, date_part_tz, date_trunc, date_trunc_tz, age, age_tz, justify_days, justify_hours, justify_interval, make_date, make_timestamp, isfinite,
    // (a, b) OVERLAPS (c, d); overlaps_tz is the STABLE timestamptz + interval form.
    overlaps, overlaps_tz,
    // Internal: the (Y, X) input of a two-argument aggregate, NULL when either is.
    aggregate_pair,
    // Formatting input functions (B11, functions_format.sig); STABLE.
    to_date, to_number, to_timestamp,
    // Unicode normalization (B11, functions_unicode.sig).
    normalize, is_normalized,
    // Arrays (B11 advanced types, array_eval.sig). array_constructor is
    // ARRAY[...] (arguments are elements or sub-arrays); array_subscript is
    // base[...]... with its subscript layout in `integer` (array_eval.sig);
    // array_any is `a op ANY/ALL (array)` encoded like in_subquery (op,
    // negated for ALL).
    array_constructor, array_subscript, array_any, array_length, cardinality, array_ndims, array_dims, array_lower, array_upper,
    array_append, array_prepend, array_cat, array_to_string,
    // Ranges (B11 advanced types, range_eval.sig): int4range(...) and the
    // other constructors (result type in the node), lower/upper of a range,
    // and the bound predicates.
    range_constructor, range_lower, range_upper, isempty, lower_inc, upper_inc, lower_inf, upper_inf,
    // Network address functions (B11 advanced types, network.sig).
    inet_host, masklen, inet_family, inet_network, broadcast, netmask,
    // Geometric functions (B11 advanced types, geometric.sig).
    point_constructor, box_constructor, area, center, width, height,
    // XML (B11 advanced types, xml.sig): XMLPARSE / XMLSERIALIZE (node
    // `integer` 1 for DOCUMENT; XMLSERIALIZE's target in cast_type/typmod)
    // and the well-formedness predicates.
    xmlparse, xmlserialize, xml_is_well_formed, xml_is_well_formed_document, xml_is_well_formed_content };

/// Conservative proof for repeated evaluation during an operator retry. Every
/// argument is checked separately by the pool walk, so wrapping a sequence,
/// clock or subquery in a pure function never makes its effects repeatable.
pub fn canRepeatFunction(func: Func) bool {
    return switch (func) {
        .grouping, .window_call, .to_char, .round, .abs, .ceil, .floor, .trunc, .sign, .sqrt, .greatest, .least => true,
        else => immutableBuiltin(func) or func == .concat or func == .concat_ws or
            func == .extract_tz or func == .date_part_tz or func == .date_trunc_tz or func == .overlaps_tz or
            func == .to_date or func == .to_number or func == .to_timestamp,
    };
}

/// PostgreSQL immutability is stronger than retry safety. Catalogue lookups
/// and clocks depend on session/database state even with constant arguments.
pub fn immutableFunction(func: Func) bool {
    return switch (func) {
        .round, .abs, .ceil, .floor, .trunc, .sign, .sqrt, .greatest, .least, .jsonb_typeof, .jsonb_array_length => true,
        else => immutableBuiltin(func),
    };
}

/// IMMUTABLE B11 builtins (pg_proc provolatile 'i'). concat/concat_ws are
/// STABLE: they use type output functions.
pub fn immutableBuiltin(func: Func) bool {
    return switch (func) {
        .lower, .upper, .initcap, .char_length, .octet_length, .bit_length, .substring, .btrim, .ltrim, .rtrim, .strpos, .replace,
        .left, .right, .repeat, .reverse, .lpad, .rpad, .split_part, .starts_with, .ascii, .chr, .translate, .overlay, .to_hex => true,
        .power, .ln, .log, .log10, .exp, .mod, .div, .pi, .degrees, .radians, .cbrt, .sin, .cos, .tan, .cot, .asin, .acos, .atan, .atan2, .gcd, .lcm, .scale, .min_scale, .trim_scale => true,
        .extract, .date_part, .date_trunc, .age, .justify_days, .justify_hours, .justify_interval, .make_date, .make_timestamp, .isfinite => true,
        .overlaps, .aggregate_pair, .normalize, .is_normalized => true,
        .array_constructor, .array_subscript, .array_any, .array_length, .cardinality, .array_ndims, .array_dims, .array_lower, .array_upper,
        .array_append, .array_prepend, .array_cat => true,
        .range_constructor, .range_lower, .range_upper, .isempty, .lower_inc, .upper_inc, .lower_inf, .upper_inf => true,
        .inet_host, .masklen, .inet_family, .inet_network, .broadcast, .netmask => true,
        .point_constructor, .box_constructor, .area, .center, .width, .height => true,
        .xmlparse, .xmlserialize, .xml_is_well_formed_document, .xml_is_well_formed_content => true,
        else => false,
    };
}

pub fn strictFunction(func: Func) bool {
    return switch (func) {
        .to_char, .round, .abs, .ceil, .floor, .trunc, .sign, .sqrt, .jsonb_typeof, .jsonb_array_length,
        .nextval, .currval, .setval, .lastval, .identity_next,
        .now, .transaction_timestamp, .statement_timestamp, .clock_timestamp,
        .current_timestamp, .current_date, .current_database, .current_schema,
        .to_regtype, .to_regclass, .pg_get_expr,
        .regclass_in, .regtype_in, .regclass_out, .regtype_out => true,
        .lower, .upper, .initcap, .char_length, .octet_length, .bit_length, .substring, .btrim, .ltrim, .rtrim, .strpos, .replace,
        .left, .right, .repeat, .reverse, .lpad, .rpad, .split_part, .starts_with, .ascii, .chr, .translate, .overlay, .to_hex => true,
        .power, .ln, .log, .log10, .exp, .mod, .div, .pi, .degrees, .radians, .cbrt, .sin, .cos, .tan, .cot, .asin, .acos, .atan, .atan2, .gcd, .lcm, .scale, .min_scale, .trim_scale => true,
        .extract, .extract_tz, .date_part, .date_part_tz, .date_trunc, .date_trunc_tz, .age, .age_tz, .justify_days, .justify_hours, .justify_interval, .make_date, .make_timestamp, .isfinite => true,
        .to_date, .to_number, .to_timestamp, .aggregate_pair, .normalize, .is_normalized => true,
        .array_length, .cardinality, .array_ndims, .array_dims, .array_lower, .array_upper => true,
        .range_lower, .range_upper, .isempty, .lower_inc, .upper_inc, .lower_inf, .upper_inf => true,
        .inet_host, .masklen, .inet_family, .inet_network, .broadcast, .netmask => true,
        .point_constructor, .box_constructor, .area, .center, .width, .height => true,
        .xml_is_well_formed, .xml_is_well_formed_document, .xml_is_well_formed_content => true,
        else => false,
    };
}

/// Cast typmods marking `::regclass` / `::regtype` (OID-valued casts).
pub const regclass_typmod: i32 = -2;
pub const regtype_typmod: i32 = -3;

/// Node.reg: an OID-valued expression known to be a regclass / regtype.
pub const Reg = enum(u8) { none, regclass, regtype };

pub const Test = enum { is_null, is_not_null, is_true, is_not_true, is_false, is_not_false, is_unknown, is_not_unknown };

/// Aggregate functions (design §4.9). `count_star` is COUNT(*).
pub const Agg = enum { none, count, count_star, sum, avg, min, max, bool_and, bool_or,
    // Statistical (B11, aggregates_stat.sig): one-argument variance family and
    // two-argument (Y, X) float8 regression aggregates; integer bitwise folds.
    stddev_pop, stddev_samp, var_pop, var_samp, corr, covar_pop, covar_samp, regr_count, regr_sxx, regr_syy,
    regr_sxy, regr_avgx, regr_avgy, regr_slope, regr_intercept, regr_r2, bit_and, bit_or, bit_xor };

/// Two-argument (Y, X) aggregates; their argument is an aggregate_pair node.
pub fn pairAggregate(agg: Agg) bool {
    return switch (agg) {
        .corr, .covar_pop, .covar_samp, .regr_count, .regr_sxx, .regr_syy, .regr_sxy, .regr_avgx, .regr_avgy, .regr_slope, .regr_intercept, .regr_r2 => true,
        else => false,
    };
}

/// Relation slot of the grouped row (keys then aggregates) after grouping.
pub fn groupRelation(comptime config: types.Config) u8 {
    return @intCast(config.relations);
}

pub const NodeKind = enum {
    null_literal,
    bool_literal,
    int_literal,
    text_literal,
    decimal_literal,
    column,
    param,
    unary,
    binary,
    and_op,
    or_op,
    not_op,
    test_op,
    between,
    in_list,
    like,
    case_expr,
    when_arm,
    coalesce,
    nullif,
    cast,
    function,
    /// `a` AT TIME ZONE `b`.
    at_zone,
    /// Aggregate call: argument `a` (none for COUNT(*)), FILTER `c`.
    /// Replaced by a grouped-row column during binding.
    aggregate,
    /// `(SELECT ...)`; `integer` is the query (parser) / plan (binder) index.
    scalar_subquery,
    /// EXISTS (SELECT ...).
    exists_subquery,
    /// `a` [NOT] IN (SELECT ...), or `a op ANY/SOME/ALL (SELECT ...)`.
    /// IN is equality ANY. ALL is NOT ANY with the opposite comparison.
    in_subquery,
    /// One INSERT VALUES row: items `b` -> next; rows are linked by `next`.
    values_row,
    /// The DEFAULT keyword as an INSERT VALUES item or SET value.
    default_value,
    /// Structural ROW(...) / (x,y), only in qualified predicate contexts.
    /// Members are `b` -> next; this is not a scalar record value type.
    row_constructor,
    /// Bound field-pair comparisons in `b` -> next, with the row operator `op`.
    /// With `a` present and `b` absent, strict comparison to a bare NULL record:
    /// `a` retains binding dependencies but is never evaluated at runtime.
    /// Its `integer` is the deferred-validation source owner: 0 = statement,
    /// -1 = excluded (DDL default or unreachable subtree), positive =
    /// 1 + table*columns + column.
    row_compare,
    /// Bound flat IN candidates: row_compare nodes in `b` -> next.
    /// Each owns a separate left expression, as PostgreSQL's OR expansion does.
    row_in,
};

/// Children by kind: unary/not/test/cast `a`; binary/and/or/nullif `a`,`b`;
/// between `a` BETWEEN `b` AND `c`; in_list `a` IN (`b` -> next ...);
/// like `a` LIKE `b` [ESCAPE `c`]; case_expr operand `a` (or none), arms `b` -> next,
/// ELSE `c`; when_arm condition `a`, result `b`; coalesce/function args `b`
/// -> next. row_constructor/row_compare/row_in own a `b` -> next list.
pub const Node = struct {
    /// OVER specification in the statement's caller-owned window pool.
    window: u16 = none,
    kind: NodeKind = .null_literal,
    op: Op = .add,
    test_kind: Test = .is_null,
    negated: bool = false,
    /// BETWEEN SYMMETRIC; consumed by binding into ordinary comparisons.
    symmetric: bool = false,
    insensitive: bool = false,
    /// Constant subtree (no column reference); set by the binder.
    constant: bool = false,
    /// Numeric strict call with a syntactic NULL argument. Keep its children
    /// for semantic/constant validation; do not execute or lower them.
    planned_null: bool = false,
    /// Binder-validated DATE literal: integer stores its exact day count.
    date_bound: bool = false,
    ty: Type = .unknown,
    cast_type: TypeName = .int4,
    /// Cast target typmod (-1 none).
    typmod: i32 = -1,
    func: Func = .none,
    depth: u16 = 1,
    a: u16 = none,
    b: u16 = none,
    c: u16 = none,
    next: u16 = none,
    name: Ident = .{},
    qualifier: Ident = .{},
    text: lexer.Quoted = .{ .start = 0, .end = 0, .len = 0 },
    integer: i64 = 0,
    boolean: bool = false,
    /// Bound column index (column nodes).
    column: u16 = 0,
    /// Bound FROM item of a column (groupRelation for grouped-row columns).
    relation: u8 = 0,
    /// Enclosing query levels up to the column's scope (correlation).
    level: u8 = 0,
    /// DISTINCT inside an aggregate call.
    distinct: bool = false,
    /// `f(*)`, or `t.*` / `*` in a target list.
    star: bool = false,
    agg: Agg = .none,
    reg: Reg = .none,
};

pub fn Ast(comptime config: types.Config) type {
    return struct {
        pub const Pool = struct {
            windows:[config.columns*config.subqueries]Window=undefined,
            window_len:usize=0,
            nodes: [config.expr_nodes]Node = undefined,
            len: usize = 0,
            /// Query blocks of the statement (top query, subqueries, CTE
            /// bodies, set-operation branches).
            queries: [config.subqueries]Select = undefined,
            query_len: usize = 0,
            /// The statement needs the general query engine (joins,
            /// grouping, DISTINCT, OFFSET, subqueries, CTEs, set operations).
            complex: bool = false,
            /// Strict NULL record comparisons need a post-binding constant pass.
            discarded_row_constants: bool = false,
            planned_nulls: bool = false,

            pub fn reset(self: *Pool) void {
                self.window_len=0;
                self.len = 0;
                self.query_len = 0;
                self.complex = false;
                self.discarded_row_constants = false;
                self.planned_nulls = false;
            }

            /// A new default query block, initialized in place (blocks are
            /// large; they are never copied while parsing).
            pub fn newQuery(self: *Pool) Error!u16 {
                if (self.query_len == config.subqueries) return error.StatementTooComplex;
                self.queries[self.query_len] = .{};
                self.query_len += 1;
                return @intCast(self.query_len - 1);
            }

            /// Adds a node whose depth is one more than its deepest child.
            pub fn add(self: *Pool, node: Node) Error!u16 {
                if (self.len == config.expr_nodes or self.len >= none) return error.StatementTooComplex;
                var copy = node;
                var depth: u16 = 0;
                for ([_]u16{ node.a, node.b, node.c }) |child| {
                    if (child != none) depth = @max(depth, self.nodes[child].depth);
                }
                copy.depth = depth + 1;
                if (copy.depth > config.expr_depth) return error.StatementTooComplex;
                self.nodes[self.len] = copy;
                self.len += 1;
                return @intCast(self.len - 1);
            }

            /// Links list members; the list's depth covers every member.
            pub fn raise(self: *Pool, owner: u16, member: u16) Error!void {
                const depth = self.nodes[member].depth + 1;
                if (depth > config.expr_depth) return error.StatementTooComplex;
                if (depth > self.nodes[owner].depth) self.nodes[owner].depth = depth;
            }
        };

        pub const ColumnDef = struct {
            name: Ident = .{},
            type_name: TypeName = .int4,
            typmod: i32 = -1,
            not_null: bool = false,
            primary_key: bool = false,
            default_kind: types.DefaultKind = .none,
            /// DEFAULT / GENERATED ... AS (expr) source text.
            expression: Span = .{},
            /// Identity sequence options.
            sequence: sequence.Options = .{},
            /// SERIAL family: the owned sequence's AS type OID (0: none).
            serial: u32 = 0,
            /// GENERATED ALWAYS AS (expr) VIRTUAL (or without STORED).
            virtual: bool = false,
        };

        /// ALTER SEQUENCE [IF EXISTS] name options (RESTART included).
        pub const AlterSequence = struct {
            if_exists: bool = false,
            name: TableRef = .{},
            options: sequence.Options = .{},
        };

        pub const ConstraintKind = enum { check, unique, primary, foreign, exclusion };

        /// FOREIGN KEY ON DELETE / ON UPDATE actions.
        pub const ForeignAction = enum(u8) { no_action = 0, restrict = 1, cascade = 2, set_null = 3, set_default = 4 };

        /// A CHECK, UNIQUE or PRIMARY KEY constraint as written, at column
        /// or table level. Column-level UNIQUE / PRIMARY KEY list their own
        /// column. `expression` is the CHECK source text and `node` its parsed
        /// root (statement pool) for naming.
        pub const ConstraintDef = struct {
            name: ?Ident = null,
            kind: ConstraintKind = .check,
            expression: Span = .{},
            node: u16 = none,
            columns: [config.columns]Ident = undefined,
            column_count: usize = 0,
            nulls_not_distinct: bool = false,
            deferrable: bool = false,
            initially_deferred: bool = false,
            /// FOREIGN KEY: REFERENCES table [(columns)] and actions.
            ref_table: TableRef = .{},
            ref_columns: [config.columns]Ident = undefined,
            ref_count: usize = 0,
            on_delete: ForeignAction = .no_action,
            on_update: ForeignAction = .no_action,
            /// EXCLUDE: operator per element (1 `=`, 2 `&&`).
            operators: [config.columns]u8 = undefined,
        };

        /// LIKE source [INCLUDING | EXCLUDING option ...] inside CREATE TABLE:
        /// `position` is the column index its columns take.
        pub const Like = struct {
            table: TableRef = .{},
            position: usize = 0,
            defaults: bool = false,
            constraints: bool = false,
            indexes: bool = false,
            identity: bool = false,
            generated: bool = false,
        };

        pub const PartitionStrategy = enum { none, range, list };

        /// FOR VALUES FROM (...) TO (...) | IN (...) | DEFAULT: expression
        /// nodes (MINVALUE / MAXVALUE are `minvalue` / `maxvalue` flags).
        pub const PartitionBound = struct {
            kind: enum { none, range, list, default } = .none,
            values: [4]u16 = @splat(none),
            count: usize = 0,
            minvalue: bool = false,
            maxvalue: bool = false,
        };

        pub const CreateTable = struct {
            if_not_exists: bool = false,
            invalid_definition: bool = false,
            schema: ?Ident = null,
            name: Ident = .{},
            columns: [config.columns]ColumnDef = undefined,
            count: usize = 0,
            constraints: [config.table_constraints]ConstraintDef = undefined,
            constraint_count: usize = 0,
            /// CREATE TEMP / TEMPORARY (an ordinary table in this engine).
            temporary: bool = false,
            like: ?Like = null,
            inherits: ?TableRef = null,
            partition_by: PartitionStrategy = .none,
            partition_key: Ident = .{},
            /// PARTITION OF parent FOR VALUES ...
            partition_of: ?TableRef = null,
            bound: PartitionBound = .{},
            /// CREATE TABLE ... AS query [WITH [NO] DATA]: Pool.queries index.
            as_query: u16 = none,
            as_columns: [config.columns]Ident = undefined,
            as_column_count: usize = 0,
            with_data: bool = true,
        };

        /// CREATE [UNIQUE] INDEX [IF NOT EXISTS] [name] ON table [USING m]
        /// (element [ASC|DESC] [NULLS FIRST|LAST], ...) [INCLUDE (columns)]
        /// [NULLS [NOT] DISTINCT] [WHERE predicate]. An element is a column
        /// (`column`) or an expression (`expression` source span).
        pub const IndexElement = struct { column: ?Ident = null, expression: Span = .{}, node: u16 = none, descending: bool = false, nulls_first: ?bool = null };
        pub const CreateIndex = struct {
            unique: bool = false,
            if_not_exists: bool = false,
            name: ?Ident = null,
            table: TableRef = .{},
            elements: [config.columns]IndexElement = undefined,
            count: usize = 0,
            includes: [config.columns]Ident = undefined,
            include_count: usize = 0,
            nulls_not_distinct: bool = false,
            predicate: Span = .{},
            predicate_node: u16 = none,
        };

        /// CREATE [OR REPLACE] [TEMP] VIEW / CREATE MATERIALIZED VIEW name
        /// [(columns)] AS query [WITH [NO] DATA].
        pub const CreateView = struct {
            materialized: bool = false,
            if_not_exists: bool = false,
            name: TableRef = .{},
            columns: [config.columns]Ident = undefined,
            column_count: usize = 0,
            query: u16 = none,
            text: Span = .{},
            with_data: bool = true,
        };

        /// MERGE INTO target [AS alias] USING source ON condition WHEN ...
        pub const MergeAction = enum { update, delete, insert, nothing };
        pub const MergeWhen = struct {
            matched: bool = true,
            /// WHEN NOT MATCHED BY SOURCE.
            by_source: bool = false,
            condition: u16 = none,
            action: MergeAction = .nothing,
            assignments: [config.columns]Assignment = undefined,
            count: usize = 0,
            columns: [config.columns]Ident = undefined,
            column_count: usize = 0,
            /// INSERT VALUES row (a values_row node) or none (DEFAULT VALUES).
            values: u16 = none,
        };
        pub const merge_clauses: usize = 4;
        pub const Merge = struct {
            table: TableRef = .{},
            /// USING items (a FROM-list query block, SELECT *).
            source: u16 = none,
            on: u16 = none,
            whens: [merge_clauses]MergeWhen = undefined,
            when_count: usize = 0,
        };

        /// SET CONSTRAINTS { ALL | name [, ...] } { DEFERRED | IMMEDIATE }.
        pub const SetConstraints = struct {
            all: bool = false,
            names: [8]Ident = undefined,
            count: usize = 0,
            deferred: bool = false,
        };

        pub const CreateSequence = struct {
            if_not_exists: bool = false,
            name: Ident = .{},
            options: sequence.Options = .{},
        };

        pub const Drop = struct { name: Ident, if_exists: bool = false, schema: ?Ident = null, cascade: bool = false };

        /// CREATE SCHEMA [IF NOT EXISTS] name.
        pub const CreateSchema = struct { name: Ident = .{}, if_not_exists: bool = false };

        /// DROP SCHEMA [IF EXISTS] name [CASCADE | RESTRICT].
        pub const DropSchema = struct { name: Ident = .{}, if_exists: bool = false, cascade: bool = false };

        pub const Target = struct {
            expr: u16 = none,
            star: bool = false,
            alias: ?Ident = null,
        };

        /// RETURNING target list (count 0: none).
        pub const Returning = struct {
            targets: [config.columns]Target = undefined,
            count: usize = 0,
        };

        pub const InsertSource = enum { values, query, default_values };

        /// ON CONFLICT [(columns) | ON CONSTRAINT name] DO NOTHING |
        /// DO UPDATE SET ... [WHERE ...].
        pub const OnConflict = struct {
            columns: [config.columns]Ident = undefined,
            column_count: usize = 0,
            constraint: ?Ident = null,
            action: ConflictAction = .nothing,
            assignments: [config.columns]Assignment = undefined,
            count: usize = 0,
            where: u16 = none,
        };

        pub const Insert = struct {
            schema: ?Ident = null,
            table: Ident = .{},
            alias: ?Ident = null,
            explicit_columns: bool = false,
            columns: [config.columns]Ident = undefined,
            column_count: usize = 0,
            source: InsertSource = .values,
            /// First values_row node (VALUES rows linked by `next`).
            rows: u16 = none,
            row_count: usize = 0,
            /// INSERT ... SELECT: index into Pool.queries.
            query: u16 = none,
            overriding: Overriding = .none,
            conflict: ?OnConflict = null,
            returning: Returning = .{},
        };

        pub const OrderKey = struct {
            expr: u16 = none,
            descending: bool = false,
            nulls_first: ?bool = null,
        };

        pub const WindowKind=enum {aggregate,rank,dense_rank,row_number,lag,lead,percent_rank,cume_dist,ntile,first_value,last_value,nth_value};
        pub const Frame=enum {default,rows_prefix,full,rows,groups,range};
        pub const BoundKind=enum {unbounded_preceding,preceding,current_row,following,unbounded_following};
        pub const FrameBound=struct {kind:BoundKind=.current_row,offset:u16=none};
        pub const Exclusion=enum {no_others,current_row,group,ties};
        pub const Window=struct {
            definition:?Ident=null,base:?Ident=null,direct:bool=false,framed:bool=false,next:u16=none,
            partition_typed:bool=false,order_typed:bool=false,bounds_typed:bool=false,
            partition_origin:[config.columns]u16=undefined,order_origin:[config.columns]u16=undefined,
            partition:[config.columns]u16=undefined,partition_count:usize=0,
            order:[config.columns]OrderKey=undefined,order_count:usize=0,
            frame:Frame=.default,
            start:FrameBound=.{.kind=.unbounded_preceding},end:FrameBound=.{},
            exclude:Exclusion=.no_others,
        };

        pub const TableRef = struct {
            schema: ?Ident = null,
            name: Ident = .{},
            alias: ?Ident = null,
        };

        /// One FROM item: a table or CTE name, or a derived table
        /// (`query` != none), joined to the items before it.
        pub const FromItem = struct {
            /// pg_catalog / information_schema / public qualifier.
            schema: ?Ident = null,
            name: Ident = .{},
            alias: ?Ident = null,
            query: u16 = none,
            join: JoinKind = .first,
            on: u16 = none,
            using: [config.columns]Ident = undefined,
            using_count: usize = 0,
            /// FROM ONLY name: no inheritance children.
            only: bool = false,
        };

        pub const Cte = struct {
            name: Ident = .{},
            columns: [config.columns]Ident = undefined,
            column_count: usize = 0,
            query: u16 = none,
        };

        /// A query block: a SELECT core, or a set operation over the
        /// blocks `left` and `right` (set_op != none). ORDER BY, LIMIT and
        /// OFFSET apply to the block's result.
        pub const Select = struct {
            targets: [config.columns]Target = undefined,
            count: usize = 0,
            /// The single FROM table of a simple statement.
            from: ?TableRef = null,
            items: [config.relations]FromItem = undefined,
            item_count: usize = 0,
            where: u16 = none,
            distinct: bool = false,
            distinct_on: [config.columns]u16 = undefined,
            distinct_on_count: usize = 0,
            group: [config.columns]u16 = undefined,
            group_count: usize = 0,
            rollup:bool=false,
            having: u16 = none,
            window_defs:u16=none,
            order: [config.columns]OrderKey = undefined,
            order_count: usize = 0,
            /// No LIMIT (or LIMIT ALL) is maxInt(u64).
            limit: u64 = 0xffffffffffffffff,
            offset: u64 = 0,
            limit_present:bool=false,
            offset_present:bool=false,
            negative_limit: bool = false,
            negative_offset: bool = false,
            lock: Locking = .{},
            set_op: SetOp = .none,
            set_all: bool = false,
            left: u16 = none,
            right: u16 = none,
            ctes: [config.ctes]Cte = undefined,
            cte_count: usize = 0,
            recursive: bool = false,
        };

        pub const Assignment = struct {
            column: Ident = .{},
            value: u16 = none,
        };

        pub const Update = struct {
            schema: ?Ident = null,
            table: Ident = .{},
            assignments: [config.columns]Assignment = undefined,
            count: usize = 0,
            where: u16 = none,
            returning: Returning = .{},
            alias: ?Ident = null,
            /// UPDATE ... FROM items: a query block (index into Pool.queries)
            /// holding only the FROM list, or none.
            from: u16 = none,
        };

        pub const Delete = struct {
            schema: ?Ident = null,
            table: Ident = .{},
            where: u16 = none,
            returning: Returning = .{},
            alias: ?Ident = null,
            /// DELETE ... USING items (a FROM-list query block), or none.
            using: u16 = none,
        };

        /// COPY t [(columns)] FROM STDIN | COPY t [(columns)] | (query) TO
        /// STDOUT, with options. `query` is the raw text of `(query)`.
        pub const Copy = struct {
            table: TableRef = .{},
            explicit_columns: bool = false,
            columns: [config.columns]Ident = undefined,
            column_count: usize = 0,
            query: ?Span = null,
            direction: CopyDirection = .from,
            options: CopyOptions = .{},
        };

        /// TRUNCATE [TABLE] [ONLY] name [, ...] [RESTART | CONTINUE IDENTITY]
        /// [CASCADE | RESTRICT].
        pub const Truncate = struct {
            tables: [config.tables]TableRef = undefined,
            count: usize = 0,
            restart_identity: bool = false,
        };

        /// One ALTER TABLE action. Column-level CHECK / UNIQUE of an ADD
        /// COLUMN follow it as add_constraint actions.
        pub const AlterAction = union(enum) {
            add_column: struct { column: ColumnDef, if_not_exists: bool = false },
            drop_column: struct { name: Ident, if_exists: bool = false },
            rename_column: struct { from: Ident, to: Ident },
            set_default: struct { column: Ident, expression: Span },
            drop_default: Ident,
            set_not_null: Ident,
            drop_not_null: Ident,
            add_constraint: ConstraintDef,
            drop_constraint: struct { name: Ident, if_exists: bool = false },
            rename_table: Ident,
        };

        /// ALTER TABLE [IF EXISTS] [ONLY] name action [, ...] | RENAME ...
        pub const AlterTable = struct {
            if_exists: bool = false,
            table: TableRef = .{},
            actions: [config.columns]AlterAction = undefined,
            count: usize = 0,
        };

        pub const Statement = union(enum) {
            create_table: CreateTable,
            drop_table: Drop,
            create_sequence: CreateSequence,
            drop_sequence: Drop,
            insert: Insert,
            /// A simple single-table SELECT: index into Pool.queries.
            select: u16,
            /// A query for the general engine: index into Pool.queries.
            query: u16,
            update: Update,
            delete: Delete,
            control: Control,
            copy: Copy,
            truncate: Truncate,
            alter_table: AlterTable,
            alter_sequence: AlterSequence,
            create_schema: CreateSchema,
            drop_schema: DropSchema,
            create_index: CreateIndex,
            drop_index: Drop,
            create_view: CreateView,
            /// DROP VIEW / DROP MATERIALIZED VIEW (`materialized`).
            drop_view: struct { drop: Drop, materialized: bool },
            refresh_view: struct { name: TableRef, with_data: bool = true },
            merge: Merge,
            set_constraints: SetConstraints,
        };
    };
}

pub const CopyDirection = enum { from, to };
pub const CopyFormat = enum { text, csv, binary };
pub const CopyHeader = enum { off, on, match };

/// A decoded COPY option string (DELIMITER, NULL, QUOTE, ESCAPE). `len` is
/// the decoded length even when it exceeds `bytes` (validation rejects it).
pub const CopyText = struct {
    set: bool = false,
    bytes: [64]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const CopyText) []const u8 {
        return self.bytes[0..@min(self.len, self.bytes.len)];
    }
};

/// COPY options as written; Database.copyInfo validates them and fills the
/// PostgreSQL defaults (text: tab and \N; csv: comma, empty NULL, `"`).
pub const CopyOptions = struct {
    format: CopyFormat = .text,
    format_set: bool = false,
    delimiter: CopyText = .{},
    null_string: CopyText = .{},
    quote: CopyText = .{},
    escape: CopyText = .{},
    header: CopyHeader = .off,
    header_set: bool = false,
    freeze_set: bool = false,
    encoding_set: bool = false,
};

pub const Overriding = enum { none, system, user };

pub const ConflictAction = enum { none, nothing, update };

pub const JoinKind = enum { first, cross, inner, left, right, full };
pub const SetOp = enum { none, @"union", intersect, except };

/// SELECT ... FOR UPDATE|SHARE [NOWAIT|SKIP LOCKED].
pub const LockStrength = enum { none, update, share };
pub const LockWait = enum { block, nowait, skip_locked };
pub const Locking = struct { strength: LockStrength = .none, wait: LockWait = .block };

pub const Isolation = enum { default, read_uncommitted, read_committed, repeatable_read, serializable };

/// A configuration parameter name: an identifier, or the special SQL forms
/// TIME ZONE and TRANSACTION ISOLATION LEVEL.
pub const SettingName = struct {
    ident: Ident = .{},
    special: enum { none, time_zone, transaction_isolation } = .none,
};

/// SET value: DEFAULT, LOCAL (TIME ZONE LOCAL), a word, a string literal or
/// a (signed) number. `span` is the raw word/number; `quoted` the string.
pub const SettingValue = struct {
    kind: enum { default, word, string, number } = .default,
    span: Span = .{},
    quoted: lexer.Quoted = .{ .start = 0, .end = 0, .len = 0 },
};

/// Transaction control and session commands; executed by the store, never
/// by a single statement.
pub const Control = union(enum) {
    begin: Isolation,
    commit: void,
    rollback: void,
    savepoint: Ident,
    release: Ident,
    rollback_to: Ident,
    set: struct { local: bool, name: SettingName, value: SettingValue },
    set_transaction: Isolation,
    show: SettingName,
    /// null = RESET ALL.
    reset: ?SettingName,
};
