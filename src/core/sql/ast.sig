//! Statement syntax trees for the bounded grammar (Layer 0).
//! Identifiers and string literals are spans into the caller's source and are
//! only valid for the statement. Expression nodes live in a statement-scoped,
//! caller-owned pool (Database.workspace); exhausting it raises
//! StatementTooComplex (SQLSTATE 54001).
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const Error = types.Error;

pub const Span = struct {
    start: usize = 0,
    len: usize = 0,

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..][0..self.len];
    }
};

pub const Literal = union(enum) {
    null_value: void,
    integer: i64,
    boolean: bool,
    text: lexer.Quoted,
};

pub const Operator = enum { equal, not_equal, less, less_equal, greater, greater_equal, is_null, is_not_null };

/// Declared column type before the binder applies the INTEGER width.
pub const TypeName = enum { integer, bigint, boolean, text };

pub fn Ast(comptime config: types.Config) type {
    return struct {
        pub const NodeKind = enum { predicate, conjunction };

        /// `predicate`: column op value. `conjunction`: left AND right.
        pub const Node = struct {
            kind: NodeKind = .predicate,
            column: Span = .{},
            op: Operator = .equal,
            value: Literal = .null_value,
            left: u16 = 0,
            right: u16 = 0,
        };

        pub const Pool = struct {
            nodes: [config.expr_nodes]Node = undefined,
            len: usize = 0,

            pub fn reset(self: *Pool) void {
                self.len = 0;
            }

            pub fn add(self: *Pool, node: Node) Error!u16 {
                if (self.len == config.expr_nodes or self.len > 65535) return error.StatementTooComplex;
                self.nodes[self.len] = node;
                self.len += 1;
                return @intCast(self.len - 1);
            }
        };

        pub const ColumnDef = struct {
            name: Span = .{},
            type_name: TypeName = .integer,
            not_null: bool = false,
            primary_key: bool = false,
        };

        pub const CreateTable = struct {
            name: Span = .{},
            columns: [config.columns]ColumnDef = undefined,
            count: usize = 0,
        };

        pub const Insert = struct {
            table: Span = .{},
            explicit_columns: bool = false,
            columns: [config.columns]Span = undefined,
            column_count: usize = 0,
            values: [config.columns]Literal = undefined,
            value_count: usize = 0,
        };

        pub const Order = struct {
            column: Span = .{},
            descending: bool = false,
            nulls_first: ?bool = null,
        };

        pub const Select = struct {
            all: bool = false,
            targets: [config.columns]Span = undefined,
            count: usize = 0,
            table: Span = .{},
            where: ?u16 = null,
            order: ?Order = null,
            limit: u64 = config.rows_per_table,
        };

        pub const Assignment = struct {
            column: Span = .{},
            value: Literal = .null_value,
        };

        pub const Update = struct {
            table: Span = .{},
            assignments: [config.columns]Assignment = undefined,
            count: usize = 0,
            where: ?u16 = null,
        };

        pub const Delete = struct {
            table: Span = .{},
            where: ?u16 = null,
        };

        pub const Statement = union(enum) {
            create_table: CreateTable,
            drop_table: Span,
            insert: Insert,
            select: Select,
            update: Update,
            delete: Delete,
            begin: void,
            commit: void,
            rollback: void,
        };
    };
}
