//! Statement syntax trees (Layer 0, design §4.1).
//! Identifiers and string literals are spans into the caller's source and are
//! only valid for the statement. Expression nodes live in a statement-scoped,
//! caller-owned pool (Database.workspace); exhausting it or exceeding
//! Config.expr_depth raises StatementTooComplex (SQLSTATE 54001). The binder
//! annotates nodes in place (types, column indices, coerced literals).
const types = @import("types.sig");
const lexer = @import("lexer.sig");
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
pub const Op = enum { add, sub, mul, div, mod, concat, eq, ne, lt, le, gt, ge, neg, pos, arrow, arrow_text, path, path_text, contains, contained, exists };

/// Built-in functions bound by name.
pub const Func = enum { none, now, transaction_timestamp, statement_timestamp, clock_timestamp, current_timestamp, current_date, jsonb_typeof, jsonb_array_length };

pub const Test = enum { is_null, is_not_null, is_true, is_not_true, is_false, is_not_false, is_unknown, is_not_unknown };

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
};

/// Children by kind: unary/not/test/cast `a`; binary/and/or/nullif `a`,`b`;
/// between `a` BETWEEN `b` AND `c`; in_list `a` IN (`b` -> next ...);
/// like `a` LIKE `b`; case_expr operand `a` (or none), arms `b` -> next,
/// ELSE `c`; when_arm condition `a`, result `b`; coalesce/function args `b`
/// -> next.
pub const Node = struct {
    kind: NodeKind = .null_literal,
    op: Op = .add,
    test_kind: Test = .is_null,
    negated: bool = false,
    insensitive: bool = false,
    /// Constant subtree (no column reference); set by the binder.
    constant: bool = false,
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
};

pub fn Ast(comptime config: types.Config) type {
    return struct {
        pub const Pool = struct {
            nodes: [config.expr_nodes]Node = undefined,
            len: usize = 0,

            pub fn reset(self: *Pool) void {
                self.len = 0;
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
        };

        pub const CreateTable = struct {
            name: Ident = .{},
            columns: [config.columns]ColumnDef = undefined,
            count: usize = 0,
        };

        pub const Insert = struct {
            table: Ident = .{},
            explicit_columns: bool = false,
            columns: [config.columns]Ident = undefined,
            column_count: usize = 0,
            values: [config.columns]u16 = undefined,
            value_count: usize = 0,
        };

        pub const Target = struct {
            expr: u16 = none,
            star: bool = false,
            alias: ?Ident = null,
        };

        pub const OrderKey = struct {
            expr: u16 = none,
            descending: bool = false,
            nulls_first: ?bool = null,
        };

        pub const TableRef = struct {
            name: Ident = .{},
            alias: ?Ident = null,
        };

        pub const Select = struct {
            targets: [config.columns]Target = undefined,
            count: usize = 0,
            from: ?TableRef = null,
            where: u16 = none,
            order: [config.columns]OrderKey = undefined,
            order_count: usize = 0,
            limit: u64 = config.rows_per_table,
            lock: Locking = .{},
        };

        pub const Assignment = struct {
            column: Ident = .{},
            value: u16 = none,
        };

        pub const Update = struct {
            table: Ident = .{},
            assignments: [config.columns]Assignment = undefined,
            count: usize = 0,
            where: u16 = none,
        };

        pub const Delete = struct {
            table: Ident = .{},
            where: u16 = none,
        };

        pub const Statement = union(enum) {
            create_table: CreateTable,
            drop_table: Ident,
            insert: Insert,
            select: Select,
            update: Update,
            delete: Delete,
            control: Control,
        };
    };
}

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
