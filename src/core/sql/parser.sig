//! Recursive-descent parser for the bounded grammar (Layer 0).
//! Grammar: CREATE/DROP TABLE; single-row INSERT [column list] VALUES;
//! SELECT */columns FROM t [WHERE p AND ...] [ORDER BY c [ASC|DESC]
//! [NULLS FIRST|LAST]] [LIMIT n]; UPDATE t SET c = literal, ... [WHERE];
//! DELETE FROM t [WHERE]; BEGIN/COMMIT/ROLLBACK [TRANSACTION].
//! `legacy_alpha` accepts exactly the alpha grammar; it is the replay mode for
//! kind 1/2 SQL-text WAL records and must never grow with the main grammar.
const types = @import("types.sig");
const lexer_module = @import("lexer.sig");
const ast = @import("ast.sig");
const Error = types.Error;
const Lexer = lexer_module.Lexer;

pub const Mode = enum { standard, legacy_alpha };

const reserved = [_][]const u8{ "CREATE", "DROP", "INSERT", "SELECT", "UPDATE", "DELETE", "TABLE", "INTO", "VALUES", "FROM", "WHERE", "AND", "OR", "SET", "ORDER", "BY", "ASC", "DESC", "LIMIT", "IS", "NOT", "NULL", "TRUE", "FALSE", "PRIMARY", "KEY" };

pub fn Parser(comptime config: types.Config) type {
    const Ast = ast.Ast(config);
    return struct {
        const Self = @This();
        lex: Lexer,
        pool: *Ast.Pool,
        mode: Mode,

        /// Parses exactly one statement. The pool is reset first.
        pub fn parse(source: []const u8, pool: *Ast.Pool, mode: Mode) Error!Ast.Statement {
            pool.reset();
            var self = Self{ .lex = .{ .source = source }, .pool = pool, .mode = mode };
            return self.statement();
        }

        fn statement(self: *Self) Error!Ast.Statement {
            if (self.lex.takeWord("CREATE")) return .{ .create_table = try self.create() };
            if (self.lex.takeWord("DROP")) {
                try self.lex.expectWord("TABLE");
                const name = try self.identifier();
                try self.lex.finish();
                return .{ .drop_table = name };
            }
            if (self.lex.takeWord("INSERT")) return .{ .insert = try self.insert() };
            if (self.lex.takeWord("SELECT")) return .{ .select = try self.select() };
            if (self.lex.takeWord("UPDATE")) return .{ .update = try self.update() };
            if (self.lex.takeWord("DELETE")) return .{ .delete = try self.delete() };
            if (self.lex.takeWord("BEGIN")) return self.control(.begin);
            if (self.lex.takeWord("COMMIT")) return self.control(.commit);
            if (self.lex.takeWord("ROLLBACK")) return self.control(.rollback);
            return error.UnsupportedStatement;
        }

        fn control(self: *Self, comptime tag: ControlTag) Error!Ast.Statement {
            _ = self.lex.takeWord("TRANSACTION");
            // Anything after transaction control stays an unsupported
            // statement (0A000), as before the pipeline split.
            self.lex.finish() catch return error.UnsupportedStatement;
            return @unionInit(Ast.Statement, @tagName(tag), {});
        }

        const ControlTag = enum { begin, commit, rollback };

        fn identifier(self: *Self) Error!ast.Span {
            const source = self.lex.word();
            if (source.len == 0) return error.Syntax;
            for (reserved) |word| if (types.keyword(source, word)) return error.Syntax;
            if (source.len > config.name_bytes) return error.NameCapacity;
            return .{ .start = self.lex.position - source.len, .len = source.len };
        }

        fn literalValue(self: *Self) Error!ast.Literal {
            if (self.lex.takeWord("NULL")) return .null_value;
            if (self.lex.takeWord("TRUE")) return .{ .boolean = true };
            if (self.lex.takeWord("FALSE")) return .{ .boolean = false };
            if (self.lex.take('\'')) return .{ .text = try self.lex.quoted(config.text_bytes) };
            const negative = self.lex.take('-');
            const magnitude = try self.lex.unsigned(if (negative) 9223372036854775808 else 9223372036854775807);
            const integer: i64 = if (negative)
                (if (magnitude == 9223372036854775808) -9223372036854775808 else -@as(i64, @intCast(magnitude)))
            else
                @intCast(magnitude);
            return .{ .integer = integer };
        }

        fn create(self: *Self) Error!Ast.CreateTable {
            try self.lex.expectWord("TABLE");
            var out: Ast.CreateTable = .{ .name = try self.identifier() };
            try self.lex.expect('(');
            var has_primary = false;
            while (true) {
                if (out.count == config.columns) return error.ColumnCapacity;
                var column: Ast.ColumnDef = .{ .name = try self.identifier() };
                if (self.lex.takeWord("INTEGER") or self.lex.takeWord("INT")) {
                    column.type_name = .integer;
                } else if (self.lex.takeWord("BIGINT") or self.lex.takeWord("INT8")) {
                    column.type_name = .bigint;
                } else if (self.lex.takeWord("BOOLEAN") or self.lex.takeWord("BOOL")) {
                    column.type_name = .boolean;
                } else if (self.lex.takeWord("TEXT")) {
                    column.type_name = .text;
                } else return error.Syntax;
                var has_not_null = false;
                while (true) {
                    if (self.lex.takeWord("NOT")) {
                        if (has_not_null) return error.Syntax;
                        try self.lex.expectWord("NULL");
                        has_not_null = true;
                        column.not_null = true;
                    } else if (self.lex.takeWord("PRIMARY")) {
                        if (has_primary) return error.Syntax;
                        try self.lex.expectWord("KEY");
                        has_primary = true;
                        column.primary_key = true;
                        column.not_null = true;
                    } else break;
                }
                out.columns[out.count] = column;
                out.count += 1;
                if (!self.lex.take(',')) break;
            }
            try self.lex.expect(')');
            try self.lex.finish();
            return out;
        }

        fn insert(self: *Self) Error!Ast.Insert {
            try self.lex.expectWord("INTO");
            var out: Ast.Insert = .{ .table = try self.identifier() };
            if (self.lex.take('(')) {
                out.explicit_columns = true;
                while (true) {
                    if (out.column_count == config.columns) return error.ColumnCapacity;
                    out.columns[out.column_count] = try self.identifier();
                    out.column_count += 1;
                    if (!self.lex.take(',')) break;
                }
                try self.lex.expect(')');
            }
            try self.lex.expectWord("VALUES");
            try self.lex.expect('(');
            while (true) {
                if (out.value_count == config.columns) return error.Syntax;
                out.values[out.value_count] = try self.literalValue();
                out.value_count += 1;
                if (!self.lex.take(',')) break;
            }
            try self.lex.expect(')');
            try self.lex.finish();
            return out;
        }

        fn predicate(self: *Self) Error!u16 {
            var node: Ast.Node = .{ .column = try self.identifier() };
            if (self.lex.takeWord("IS")) {
                node.op = if (self.lex.takeWord("NOT")) .is_not_null else .is_null;
                try self.lex.expectWord("NULL");
            } else {
                if (self.lex.take('=')) {
                    node.op = .equal;
                } else if (self.lex.take('!')) {
                    try self.lex.expect('=');
                    node.op = .not_equal;
                } else if (self.lex.take('<')) {
                    node.op = if (self.lex.take('=')) .less_equal else if (self.lex.take('>')) .not_equal else .less;
                } else if (self.lex.take('>')) {
                    node.op = if (self.lex.take('=')) .greater_equal else .greater;
                } else return error.Syntax;
                node.value = try self.literalValue();
            }
            return self.pool.add(node);
        }

        /// AND-only predicate list as a left-deep tree; depth equals the
        /// number of conjunctions and is bounded by Config.expr_depth.
        fn where(self: *Self) Error!?u16 {
            if (!self.lex.takeWord("WHERE")) return null;
            var root: ?u16 = null;
            var count: usize = 0;
            while (true) {
                if (count == config.predicates) return error.PredicateCapacity;
                const item = try self.predicate();
                count += 1;
                if (root) |left| {
                    if (count > config.expr_depth) return error.StatementTooComplex;
                    root = try self.pool.add(.{ .kind = .conjunction, .left = left, .right = item });
                } else root = item;
                if (!self.lex.takeWord("AND")) break;
            }
            return root;
        }

        fn select(self: *Self) Error!Ast.Select {
            var out: Ast.Select = .{ .all = self.lex.take('*') };
            if (!out.all) {
                while (true) {
                    if (out.count == config.columns) return error.ColumnCapacity;
                    out.targets[out.count] = try self.identifier();
                    out.count += 1;
                    if (!self.lex.take(',')) break;
                }
            }
            try self.lex.expectWord("FROM");
            out.table = try self.identifier();
            out.where = try self.where();
            if (self.lex.takeWord("ORDER")) {
                try self.lex.expectWord("BY");
                var order: Ast.Order = .{ .column = try self.identifier() };
                if (self.lex.takeWord("DESC")) order.descending = true else _ = self.lex.takeWord("ASC");
                if (self.lex.takeWord("NULLS")) {
                    if (self.lex.takeWord("FIRST")) order.nulls_first = true else if (self.lex.takeWord("LAST")) order.nulls_first = false else return error.Syntax;
                }
                out.order = order;
            }
            if (self.lex.takeWord("LIMIT")) out.limit = try self.lex.unsigned(18446744073709551615);
            try self.lex.finish();
            return out;
        }

        fn update(self: *Self) Error!Ast.Update {
            var out: Ast.Update = .{ .table = try self.identifier() };
            try self.lex.expectWord("SET");
            while (true) {
                if (out.count == config.columns) return error.DuplicateColumn;
                const column = try self.identifier();
                try self.lex.expect('=');
                out.assignments[out.count] = .{ .column = column, .value = try self.literalValue() };
                out.count += 1;
                if (!self.lex.take(',')) break;
            }
            out.where = try self.where();
            try self.lex.finish();
            return out;
        }

        fn delete(self: *Self) Error!Ast.Delete {
            try self.lex.expectWord("FROM");
            var out: Ast.Delete = .{ .table = try self.identifier() };
            out.where = try self.where();
            try self.lex.finish();
            return out;
        }
    };
}
