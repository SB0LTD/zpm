//! Recursive-descent parser (Layer 0, design §4.1).
//!
//! Statements: CREATE/DROP TABLE; single-row INSERT [column list] VALUES
//! (expressions); [WITH [RECURSIVE] ...] SELECT [DISTINCT [ON (e, ...)]]
//! targets [FROM items joined by commas or [INNER|LEFT|RIGHT|FULL [OUTER]|
//! CROSS] JOIN ... ON e | USING (c, ...)] [WHERE e] [GROUP BY e, ...] [HAVING
//! e] {UNION|INTERSECT|EXCEPT [ALL] ...} [ORDER BY key [ASC|DESC] [NULLS
//! FIRST|LAST], ...] [LIMIT n|ALL] [OFFSET n] [FETCH FIRST n ROWS ONLY];
//! UPDATE t SET c = e, ... [WHERE e]; DELETE FROM t [WHERE e];
//! BEGIN/COMMIT/ROLLBACK [TRANSACTION]. Query blocks (subqueries, CTE bodies,
//! set-operation branches) live in Pool.queries; `Pool.complex` routes a
//! statement to the general engine.
//!
//! Expressions use PostgreSQL precedence, lowest first: OR, AND, NOT, IS,
//! comparison (non-associative), BETWEEN/IN/LIKE/ILIKE, `||` and the JSON
//! operators, `+ -`, `* / %`, AT TIME ZONE, unary `+ -`, `::`. Primaries
//! are literals (including typed literals such as DATE '...'), (qualified)
//! columns, parentheses, CASE, CAST, COALESCE, NULLIF, function calls,
//! CURRENT_TIMESTAMP / CURRENT_DATE and `$n`. Recursion and tree depth are bounded by
//! Config.expr_depth and nodes by Config.expr_nodes (StatementTooComplex).
//!
//! `legacy_alpha` first runs the frozen alpha recognizer (alpha.sig) so kind
//! 1/2 replay accepts exactly the alpha grammar; it must never grow.
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const ast = @import("ast.sig");
const alpha = @import("alpha.sig");
const numeric = @import("numeric.sig");
const Error = types.Error;
const Token = lexer.Token;
const Symbol = lexer.Symbol;
const none = ast.none;

pub const Mode = enum { standard, legacy_alpha };

pub fn Parser(comptime config: types.Config) type {
    const Ast = ast.Ast(config);
    return struct {
        const Self = @This();
        tokens: lexer.Tokenizer,
        current: Token = .{},
        /// One-token lookahead cache: the token after current and the
        /// tokenizer state after it.
        peeked: Token = .{},
        after_peek: lexer.Tokenizer = undefined,
        has_peek: bool = false,
        pool: *Ast.Pool,
        source: []const u8,
        mode: Mode = .standard,
        recursion: usize = 0,

        /// Parses exactly one statement. The pool is reset first.
        pub fn parse(source: []const u8, pool: *Ast.Pool, mode: Mode) Error!Ast.Statement {
            pool.reset();
            if (mode == .legacy_alpha) try alpha.Recognizer(config).check(source);
            var self = Self{ .tokens = .{ .source = source, .text_limit = config.text_bytes }, .pool = pool, .source = source, .mode = mode };
            try self.advance();
            return self.statement();
        }

        fn advance(self: *Self) Error!void {
            if (self.has_peek) {
                self.current = self.peeked;
                self.tokens = self.after_peek;
                self.has_peek = false;
                return;
            }
            self.current = try self.tokens.next();
        }

        /// The token after `current`, without consuming anything.
        fn peek(self: *Self) Error!Token {
            if (!self.has_peek) {
                var copy = self.tokens;
                self.peeked = try copy.next();
                self.after_peek = copy;
                self.has_peek = true;
            }
            return self.peeked;
        }

        fn isWord(self: *const Self, comptime expected: []const u8) bool {
            return self.current.isWord(expected);
        }

        fn takeWord(self: *Self, comptime expected: []const u8) Error!bool {
            if (!self.isWord(expected)) return false;
            try self.advance();
            return true;
        }

        fn expectWord(self: *Self, comptime expected: []const u8) Error!void {
            if (!try self.takeWord(expected)) return error.Syntax;
        }

        fn isSymbol(self: *const Self, symbol: Symbol) bool {
            return self.current.kind == .symbol and self.current.symbol == symbol;
        }

        fn takeSymbol(self: *Self, symbol: Symbol) Error!bool {
            if (!self.isSymbol(symbol)) return false;
            try self.advance();
            return true;
        }

        fn expectSymbol(self: *Self, symbol: Symbol) Error!void {
            if (!try self.takeSymbol(symbol)) return error.Syntax;
        }

        fn wordIs(source: []const u8, token: Token, comptime wanted: []const u8) bool {
            return token.kind == .word and types.keyword(token.raw(source), wanted);
        }

        fn finish(self: *Self) Error!void {
            _ = try self.takeSymbol(.semicolon);
            if (self.current.kind != .end) return error.Syntax;
        }

        fn enter(self: *Self) Error!void {
            self.recursion += 1;
            if (self.recursion > config.expr_depth) return error.StatementTooComplex;
        }

        fn leave(self: *Self) void {
            self.recursion -= 1;
        }

        fn identCurrent(self: *const Self) Error!ast.Ident {
            const token = self.current;
            if (token.kind == .quoted_word) {
                if (token.len > config.name_bytes) return error.NameCapacity;
                return .{ .span = .{ .start = token.start, .len = token.end - token.start }, .quoted = true, .len = token.len };
            }
            if (token.kind != .word or lexer.reserved(token.keyword)) return error.Syntax;
            if (token.len > config.name_bytes) return error.NameCapacity;
            return .{ .span = .{ .start = token.start, .len = token.len }, .len = token.len };
        }

        fn identifier(self: *Self) Error!ast.Ident {
            const out = try self.identCurrent();
            try self.advance();
            return out;
        }

        /// `AS` labels may be any word, reserved or not.
        fn label(self: *Self) Error!ast.Ident {
            const token = self.current;
            if (token.kind == .word) {
                if (token.len > config.name_bytes) return error.NameCapacity;
                try self.advance();
                return .{ .span = .{ .start = token.start, .len = token.len }, .len = token.len };
            }
            return self.identifier();
        }

        fn bareAlias(self: *Self) Error!?ast.Ident {
            if (try self.takeWord("AS")) return try self.label();
            if (self.current.kind == .quoted_word or (self.current.kind == .word and !lexer.reserved(self.current.keyword)))
                return try self.identifier();
            return null;
        }

        fn statement(self: *Self) Error!Ast.Statement {
            if (try self.takeWord("CREATE")) return .{ .create_table = try self.create() };
            if (try self.takeWord("DROP")) {
                try self.expectWord("TABLE");
                const name = try self.identifier();
                try self.finish();
                return .{ .drop_table = name };
            }
            if (try self.takeWord("INSERT")) return .{ .insert = try self.insert() };
            if (self.isWord("SELECT") or (self.mode == .standard and self.isWord("WITH"))) return self.topQuery();
            if (try self.takeWord("UPDATE")) return .{ .update = try self.update() };
            if (try self.takeWord("DELETE")) return .{ .delete = try self.delete() };
            if (self.mode == .legacy_alpha) {
                if (try self.takeWord("BEGIN")) return self.legacyControl(.{ .begin = .default });
                if (try self.takeWord("COMMIT")) return self.legacyControl(.commit);
                if (try self.takeWord("ROLLBACK")) return self.legacyControl(.rollback);
                return error.UnsupportedStatement;
            }
            return .{ .control = try self.controlStatement() };
        }

        fn legacyControl(self: *Self, control: ast.Control) Error!Ast.Statement {
            _ = self.takeWord("TRANSACTION") catch return error.UnsupportedStatement;
            self.finish() catch return error.UnsupportedStatement;
            return .{ .control = control };
        }

        /// Transaction control and session commands (the store executes them).
        fn controlStatement(self: *Self) Error!ast.Control {
            // Trailing text after plain transaction control stays an
            // unsupported statement (0A000), as before the pipeline split.
            if (try self.takeWord("BEGIN")) {
                _ = (try self.takeWord("WORK")) or (try self.takeWord("TRANSACTION"));
                const level = try self.isolationClause();
                self.finish() catch return error.UnsupportedStatement;
                return .{ .begin = level };
            }
            if (try self.takeWord("START")) {
                try self.expectWord("TRANSACTION");
                const level = try self.isolationClause();
                self.finish() catch return error.UnsupportedStatement;
                return .{ .begin = level };
            }
            if ((try self.takeWord("COMMIT")) or (try self.takeWord("END"))) {
                _ = (try self.takeWord("WORK")) or (try self.takeWord("TRANSACTION"));
                self.finish() catch return error.UnsupportedStatement;
                return .commit;
            }
            if (try self.takeWord("ABORT")) {
                _ = (try self.takeWord("WORK")) or (try self.takeWord("TRANSACTION"));
                try self.finish();
                return .rollback;
            }
            if (try self.takeWord("ROLLBACK")) {
                _ = (try self.takeWord("WORK")) or (try self.takeWord("TRANSACTION"));
                if (try self.takeWord("TO")) {
                    _ = try self.takeWord("SAVEPOINT");
                    const name = try self.identifier();
                    try self.finish();
                    return .{ .rollback_to = name };
                }
                self.finish() catch return error.UnsupportedStatement;
                return .rollback;
            }
            if (try self.takeWord("SAVEPOINT")) {
                const name = try self.identifier();
                try self.finish();
                return .{ .savepoint = name };
            }
            if (try self.takeWord("RELEASE")) {
                _ = try self.takeWord("SAVEPOINT");
                const name = try self.identifier();
                try self.finish();
                return .{ .release = name };
            }
            if (try self.takeWord("SET")) {
                var local = false;
                if (try self.takeWord("LOCAL")) local = true else _ = try self.takeWord("SESSION");
                if (try self.takeWord("TRANSACTION")) {
                    const level = try self.isolationClause();
                    if (level == .default) return error.Syntax;
                    try self.finish();
                    return .{ .set_transaction = level };
                }
                if (try self.takeWord("TIME")) {
                    try self.expectWord("ZONE");
                    var value: ast.SettingValue = .{};
                    if (!try self.takeWord("LOCAL")) value = try self.settingValue();
                    try self.finish();
                    return .{ .set = .{ .local = local, .name = .{ .special = .time_zone }, .value = value } };
                }
                const name: ast.SettingName = .{ .ident = try self.label() };
                if (!try self.takeWord("TO")) try self.expectSymbol(.eq);
                const value = try self.settingValue();
                try self.finish();
                return .{ .set = .{ .local = local, .name = name, .value = value } };
            }
            if (try self.takeWord("SHOW")) {
                const name = try self.settingName();
                try self.finish();
                return .{ .show = name };
            }
            if (try self.takeWord("RESET")) {
                if (try self.takeWord("ALL")) {
                    try self.finish();
                    return .{ .reset = null };
                }
                const name = try self.settingName();
                try self.finish();
                return .{ .reset = name };
            }
            return error.UnsupportedStatement;
        }

        fn settingName(self: *Self) Error!ast.SettingName {
            if (try self.takeWord("TIME")) {
                try self.expectWord("ZONE");
                return .{ .special = .time_zone };
            }
            if (try self.takeWord("TRANSACTION")) {
                try self.expectWord("ISOLATION");
                try self.expectWord("LEVEL");
                return .{ .special = .transaction_isolation };
            }
            return .{ .ident = try self.label() };
        }

        fn settingValue(self: *Self) Error!ast.SettingValue {
            const token = self.current;
            if (token.kind == .word and token.isWord("DEFAULT")) {
                try self.advance();
                return .{ .kind = .default };
            }
            switch (token.kind) {
                .string => {
                    try self.advance();
                    return .{ .kind = .string, .quoted = token.quoted() };
                },
                .word => {
                    try self.advance();
                    return .{ .kind = .word, .span = .{ .start = token.start, .len = token.len } };
                },
                .integer, .decimal => {
                    try self.advance();
                    return .{ .kind = .number, .span = .{ .start = token.start, .len = token.end - token.start } };
                },
                .symbol => if (token.symbol == .minus) {
                    try self.advance();
                    const number = self.current;
                    if (number.kind != .integer and number.kind != .decimal) return error.Syntax;
                    try self.advance();
                    return .{ .kind = .number, .span = .{ .start = token.start, .len = number.end - token.start } };
                },
                else => {},
            }
            return error.Syntax;
        }

        /// [ISOLATION LEVEL {READ COMMITTED|READ UNCOMMITTED|REPEATABLE READ|SERIALIZABLE}]
        fn isolationClause(self: *Self) Error!ast.Isolation {
            if (!try self.takeWord("ISOLATION")) return .default;
            try self.expectWord("LEVEL");
            if (try self.takeWord("SERIALIZABLE")) return .serializable;
            if (try self.takeWord("REPEATABLE")) {
                try self.expectWord("READ");
                return .repeatable_read;
            }
            try self.expectWord("READ");
            if (try self.takeWord("COMMITTED")) return .read_committed;
            try self.expectWord("UNCOMMITTED");
            return .read_uncommitted;
        }

        pub const TypeSpec = struct { ty: ast.TypeName, typmod: i32 = -1 };

        fn typeWord(token: Token) bool {
            return switch (token.keyword) {
                .integer, .int, .int4, .bigint, .int8, .smallint, .int2, .boolean, .@"bool", .text, .numeric, .decimal, .real, .float4, .float8, .float, .double, .name, .oid, .date, .timestamp, .timestamptz, .interval, .json, .jsonb => true,
                else => false,
            };
        }

        fn typmodNumber(self: *Self) Error!i32 {
            var negative = false;
            if (try self.takeSymbol(.minus)) negative = true;
            if (self.current.kind != .integer or self.current.integer > 100000) return error.Syntax;
            const value: i32 = @intCast(self.current.integer);
            try self.advance();
            return if (negative) -value else value;
        }

        /// `(p)` timestamp precision: 0..6, larger values clamp to 6 as
        /// PostgreSQL does (it also warns).
        fn precision(self: *Self) Error!i32 {
            if (!try self.takeSymbol(.lparen)) return -1;
            const value = try self.typmodNumber();
            try self.expectSymbol(.rparen);
            if (value < 0) return error.InvalidParameterValue;
            return @min(value, 6);
        }

        fn typeName(self: *Self) Error!TypeSpec {
            const word = self.current;
            if (word.kind != .word or !typeWord(word)) return error.Syntax;
            try self.advance();
            return switch (word.keyword) {
                .integer, .int, .int4 => .{ .ty = .int4 },
                .bigint, .int8 => .{ .ty = .int8 },
                .smallint, .int2 => .{ .ty = .int2 },
                .boolean, .@"bool" => .{ .ty = .boolean },
                .text => .{ .ty = .text },
                .name => .{ .ty = .name },
                .oid => .{ .ty = .oid },
                .real, .float4 => .{ .ty = .float4 },
                .float8 => .{ .ty = .float8 },
                .double => blk: {
                    try self.expectWord("PRECISION");
                    break :blk .{ .ty = .float8 };
                },
                .float => blk: {
                    if (!try self.takeSymbol(.lparen)) break :blk .{ .ty = .float8 };
                    const bits = try self.typmodNumber();
                    try self.expectSymbol(.rparen);
                    if (bits < 1 or bits > 53) return error.InvalidParameterValue;
                    break :blk .{ .ty = if (bits <= 24) .float4 else .float8 };
                },
                .numeric, .decimal => blk: {
                    if (!try self.takeSymbol(.lparen)) break :blk .{ .ty = .numeric };
                    const p = try self.typmodNumber();
                    var s: i32 = 0;
                    if (try self.takeSymbol(.comma)) s = try self.typmodNumber();
                    try self.expectSymbol(.rparen);
                    break :blk .{ .ty = .numeric, .typmod = try numeric.Ops(config.numeric_digits).encodeTypmod(p, s) };
                },
                .date => .{ .ty = .date },
                .timestamp => blk: {
                    const p = try self.precision();
                    var zoned = false;
                    if (try self.takeWord("WITH")) {
                        try self.expectWord("TIME");
                        try self.expectWord("ZONE");
                        zoned = true;
                    } else if (try self.takeWord("WITHOUT")) {
                        try self.expectWord("TIME");
                        try self.expectWord("ZONE");
                    }
                    break :blk .{ .ty = if (zoned) .timestamptz else .timestamp, .typmod = p };
                },
                .timestamptz => .{ .ty = .timestamptz, .typmod = try self.precision() },
                .interval => .{ .ty = .interval },
                .json => .{ .ty = .json },
                .jsonb => .{ .ty = .jsonb },
                else => unreachable,
            };
        }

        fn create(self: *Self) Error!Ast.CreateTable {
            try self.expectWord("TABLE");
            var out: Ast.CreateTable = .{ .name = try self.identifier() };
            try self.expectSymbol(.lparen);
            var has_primary = false;
            while (true) {
                if (out.count == config.columns) return error.ColumnCapacity;
                var column: Ast.ColumnDef = .{ .name = try self.identifier() };
                const spec = try self.typeName();
                column.type_name = spec.ty;
                column.typmod = spec.typmod;
                var has_not_null = false;
                while (true) {
                    if (try self.takeWord("NOT")) {
                        if (has_not_null) return error.Syntax;
                        try self.expectWord("NULL");
                        has_not_null = true;
                        column.not_null = true;
                    } else if (try self.takeWord("PRIMARY")) {
                        if (has_primary) return error.Syntax;
                        try self.expectWord("KEY");
                        has_primary = true;
                        column.primary_key = true;
                        column.not_null = true;
                    } else break;
                }
                out.columns[out.count] = column;
                out.count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
            try self.finish();
            return out;
        }

        fn insert(self: *Self) Error!Ast.Insert {
            try self.expectWord("INTO");
            var out: Ast.Insert = .{ .table = try self.identifier() };
            if (try self.takeSymbol(.lparen)) {
                out.explicit_columns = true;
                while (true) {
                    if (out.column_count == config.columns) return error.ColumnCapacity;
                    out.columns[out.column_count] = try self.identifier();
                    out.column_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
                try self.expectSymbol(.rparen);
            }
            try self.expectWord("VALUES");
            try self.expectSymbol(.lparen);
            while (true) {
                if (out.value_count == config.columns) return error.Syntax;
                out.values[out.value_count] = try self.expression();
                out.value_count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
            try self.finish();
            return out;
        }

        fn where(self: *Self) Error!u16 {
            if (!try self.takeWord("WHERE")) return none;
            return self.expression();
        }

        /// A complete SELECT/WITH statement. Single-table queries without
        /// grouping, DISTINCT, OFFSET, subqueries, CTEs or set operations
        /// stay on the simple path (`.select`); the rest use the general
        /// query engine (`.query`).
        fn topQuery(self: *Self) Error!Ast.Statement {
            const top = try self.query();
            try self.finish();
            const block = &self.pool.queries[top];
            if (!self.pool.complex and block.set_op == .none) return .{ .select = top };
            if (block.lock.strength != .none) return error.UnsupportedStatement;
            return .{ .query = top };
        }

        /// [WITH [RECURSIVE] name [(columns)] AS (query), ...] set-expression
        /// [ORDER BY ...] [LIMIT n|ALL] [OFFSET n [ROW|ROWS]]
        /// [FETCH FIRST|NEXT [n] ROW|ROWS ONLY] [FOR UPDATE|SHARE ...].
        fn query(self: *Self) Error!u16 {
            try self.enter();
            defer self.leave();
            var ctes: [config.ctes]Ast.Cte = undefined;
            var cte_count: usize = 0;
            var recursive = false;
            if (self.mode == .standard and try self.takeWord("WITH")) {
                self.pool.complex = true;
                recursive = try self.takeWord("RECURSIVE");
                while (true) {
                    if (cte_count == config.ctes) return error.StatementTooComplex;
                    var cte: Ast.Cte = .{ .name = try self.identifier() };
                    if (try self.takeSymbol(.lparen)) {
                        while (true) {
                            if (cte.column_count == config.columns) return error.ColumnCapacity;
                            cte.columns[cte.column_count] = try self.identifier();
                            cte.column_count += 1;
                            if (!try self.takeSymbol(.comma)) break;
                        }
                        try self.expectSymbol(.rparen);
                    }
                    try self.expectWord("AS");
                    try self.expectSymbol(.lparen);
                    cte.query = try self.query();
                    try self.expectSymbol(.rparen);
                    ctes[cte_count] = cte;
                    cte_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
            }
            const top = try self.setExpression();
            const block = &self.pool.queries[top];
            if (cte_count != 0) {
                if (block.cte_count != 0) return error.Syntax;
                block.ctes = ctes;
                block.cte_count = cte_count;
                block.recursive = recursive;
            }
            if (try self.takeWord("ORDER")) {
                if (block.order_count != 0) return error.Syntax;
                try self.expectWord("BY");
                while (true) {
                    if (block.order_count == config.columns) return error.ColumnCapacity;
                    var key: Ast.OrderKey = .{ .expr = try self.expression() };
                    if (try self.takeWord("DESC")) key.descending = true else _ = try self.takeWord("ASC");
                    if (try self.takeWord("NULLS")) {
                        if (try self.takeWord("FIRST")) key.nulls_first = true else if (try self.takeWord("LAST")) key.nulls_first = false else return error.Syntax;
                    }
                    block.order[block.order_count] = key;
                    block.order_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
            }
            var limited = false;
            var offset_seen = false;
            while (true) {
                if (!limited and try self.takeWord("LIMIT")) {
                    limited = true;
                    if (!(try self.takeWord("ALL")) and !(try self.takeWord("NULL"))) try self.countValue(&block.limit, &block.negative_limit);
                } else if (!offset_seen and self.mode == .standard and try self.takeWord("OFFSET")) {
                    offset_seen = true;
                    self.pool.complex = true;
                    try self.countValue(&block.offset, &block.negative_offset);
                    _ = (try self.takeWord("ROW")) or (try self.takeWord("ROWS"));
                } else if (!limited and self.mode == .standard and try self.takeWord("FETCH")) {
                    limited = true;
                    if (!(try self.takeWord("FIRST"))) try self.expectWord("NEXT");
                    block.limit = 1;
                    if (self.current.kind == .integer or self.isSymbol(.minus) or self.current.kind == .decimal) try self.countValue(&block.limit, &block.negative_limit);
                    if (!(try self.takeWord("ROW"))) try self.expectWord("ROWS");
                    try self.expectWord("ONLY");
                } else break;
            }
            if (self.mode == .standard and try self.takeWord("FOR")) {
                if (block.set_op != .none or block.item_count == 0) return error.Syntax;
                if (try self.takeWord("UPDATE")) block.lock.strength = .update else {
                    try self.expectWord("SHARE");
                    block.lock.strength = .share;
                }
                if (try self.takeWord("NOWAIT")) block.lock.wait = .nowait else if (try self.takeWord("SKIP")) {
                    try self.expectWord("LOCKED");
                    block.lock.wait = .skip_locked;
                }
                if (!limited and try self.takeWord("LIMIT")) try self.countValue(&block.limit, &block.negative_limit);
            }
            return top;
        }

        /// UNION/EXCEPT (left-associative) over INTERSECT terms.
        fn setExpression(self: *Self) Error!u16 {
            var left = try self.setTerm();
            while (self.mode == .standard and (self.isWord("UNION") or self.isWord("EXCEPT"))) {
                const op: ast.SetOp = if (self.isWord("UNION")) .@"union" else .except;
                try self.advance();
                const all = try self.setQuantifier();
                const right = try self.setTerm();
                left = try self.setNode(op, all, left, right);
            }
            return left;
        }

        fn setTerm(self: *Self) Error!u16 {
            var left = try self.setPrimary();
            while (self.mode == .standard and try self.takeWord("INTERSECT")) {
                const all = try self.setQuantifier();
                const right = try self.setPrimary();
                left = try self.setNode(.intersect, all, left, right);
            }
            return left;
        }

        fn setQuantifier(self: *Self) Error!bool {
            if (try self.takeWord("ALL")) return true;
            _ = try self.takeWord("DISTINCT");
            return false;
        }

        fn setNode(self: *Self, op: ast.SetOp, all: bool, left: u16, right: u16) Error!u16 {
            self.pool.complex = true;
            const index = try self.pool.newQuery();
            const block = &self.pool.queries[index];
            block.set_op = op;
            block.set_all = all;
            block.left = left;
            block.right = right;
            return index;
        }

        fn setPrimary(self: *Self) Error!u16 {
            if (self.mode == .standard and try self.takeSymbol(.lparen)) {
                const inner = try self.query();
                try self.expectSymbol(.rparen);
                self.pool.complex = true;
                return inner;
            }
            try self.expectWord("SELECT");
            return self.core();
        }

        /// SELECT [DISTINCT [ON (exprs)] | ALL] targets [FROM items] [WHERE]
        /// [GROUP BY exprs] [HAVING expr].
        fn core(self: *Self) Error!u16 {
            const index = try self.pool.newQuery();
            const out = &self.pool.queries[index];
            if (self.mode == .standard and try self.takeWord("DISTINCT")) {
                self.pool.complex = true;
                out.distinct = true;
                if (try self.takeWord("ON")) {
                    try self.expectSymbol(.lparen);
                    while (true) {
                        if (out.distinct_on_count == config.columns) return error.ColumnCapacity;
                        out.distinct_on[out.distinct_on_count] = try self.expression();
                        out.distinct_on_count += 1;
                        if (!try self.takeSymbol(.comma)) break;
                    }
                    try self.expectSymbol(.rparen);
                }
            } else if (self.mode == .standard) _ = try self.takeWord("ALL");
            var star = false;
            while (true) {
                if (out.count == config.columns) return error.ColumnCapacity;
                var target: Ast.Target = .{};
                if (try self.takeSymbol(.star)) {
                    target.star = true;
                    star = true;
                } else {
                    target.expr = try self.expression();
                    const n = &self.pool.nodes[target.expr];
                    if (n.kind == .column and n.star) {
                        // t.*
                        target.star = true;
                        star = true;
                        self.pool.complex = true;
                    } else target.alias = try self.bareAlias();
                }
                out.targets[out.count] = target;
                out.count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            if (try self.takeWord("FROM")) {
                try self.fromList(out);
            } else if (star) return error.Syntax;
            out.where = try self.where();
            if (self.mode == .standard and try self.takeWord("GROUP")) {
                try self.expectWord("BY");
                self.pool.complex = true;
                while (true) {
                    if (out.group_count == config.columns) return error.ColumnCapacity;
                    out.group[out.group_count] = try self.expression();
                    out.group_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
            }
            if (self.mode == .standard and try self.takeWord("HAVING")) {
                self.pool.complex = true;
                out.having = try self.expression();
            }
            return index;
        }

        fn fromList(self: *Self, out: *Ast.Select) Error!void {
            try self.fromItem(out, .first);
            while (self.mode == .standard) {
                if (try self.takeSymbol(.comma)) {
                    try self.fromItem(out, .cross);
                    continue;
                }
                var kind: ast.JoinKind = .inner;
                if (try self.takeWord("JOIN")) {
                    kind = .inner;
                } else if (try self.takeWord("INNER")) {
                    try self.expectWord("JOIN");
                } else if (try self.takeWord("CROSS")) {
                    try self.expectWord("JOIN");
                    kind = .cross;
                } else if (self.isWord("LEFT") or self.isWord("RIGHT") or self.isWord("FULL")) {
                    kind = if (self.isWord("LEFT")) .left else if (self.isWord("RIGHT")) .right else .full;
                    try self.advance();
                    _ = try self.takeWord("OUTER");
                    try self.expectWord("JOIN");
                } else break;
                try self.fromItem(out, kind);
                if (kind == .cross) continue;
                const item = &out.items[out.item_count - 1];
                if (try self.takeWord("ON")) {
                    item.on = try self.expression();
                } else if (try self.takeWord("USING")) {
                    try self.expectSymbol(.lparen);
                    while (true) {
                        if (item.using_count == config.columns) return error.ColumnCapacity;
                        item.using[item.using_count] = try self.identifier();
                        item.using_count += 1;
                        if (!try self.takeSymbol(.comma)) break;
                    }
                    try self.expectSymbol(.rparen);
                } else return error.Syntax;
            }
            if (out.item_count == 1 and out.items[0].query == none) {
                out.from = .{ .name = out.items[0].name, .alias = out.items[0].alias };
            } else self.pool.complex = true;
        }

        fn fromItem(self: *Self, out: *Ast.Select, kind: ast.JoinKind) Error!void {
            if (out.item_count == config.relations) return error.StatementTooComplex;
            var item: Ast.FromItem = .{ .join = kind };
            if (self.mode == .standard and try self.takeSymbol(.lparen)) {
                if (!self.isWord("SELECT") and !self.isWord("WITH")) return error.UnsupportedStatement;
                item.query = try self.query();
                try self.expectSymbol(.rparen);
                self.pool.complex = true;
            } else item.name = try self.identifier();
            item.alias = try self.bareAlias();
            out.items[out.item_count] = item;
            out.item_count += 1;
        }

        /// A LIMIT/OFFSET/FETCH count; negative counts are reported by the
        /// binder (2201W / 2201X) after name resolution, as PostgreSQL
        /// reports them at execution.
        fn countValue(self: *Self, value: *u64, negative: *bool) Error!void {
            const minus = try self.takeSymbol(.minus);
            if (self.current.kind == .decimal) {
                // An integer beyond u64 (bigint out of range, as PostgreSQL).
                for (self.current.raw(self.source)) |byte| if (!types.digit(byte)) return error.Syntax;
                return error.IntegerOverflow;
            }
            if (self.current.kind != .integer) return error.Syntax;
            value.* = self.current.integer;
            try self.advance();
            if (minus and value.* != 0) negative.* = true;
        }

        fn update(self: *Self) Error!Ast.Update {
            var out: Ast.Update = .{ .table = try self.identifier() };
            try self.expectWord("SET");
            while (true) {
                if (out.count == config.columns) return error.DuplicateColumn;
                const column = try self.identifier();
                try self.expectSymbol(.eq);
                out.assignments[out.count] = .{ .column = column, .value = try self.expression() };
                out.count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            out.where = try self.where();
            try self.finish();
            return out;
        }

        fn delete(self: *Self) Error!Ast.Delete {
            try self.expectWord("FROM");
            var out: Ast.Delete = .{ .table = try self.identifier() };
            out.where = try self.where();
            try self.finish();
            return out;
        }

        // ---- expressions ------------------------------------------------

        /// A token that cannot continue an expression after a bare column.
        fn ends(token: Token) bool {
            return switch (token.kind) {
                .end => true,
                .symbol => token.symbol == .comma or token.symbol == .rparen or token.symbol == .semicolon,
                .quoted_word => true,
                .word => switch (token.keyword) {
                    .from, .as, .where, .order, .limit, .asc, .desc, .nulls => true,
                    .group, .having, .@"union", .intersect, .except, .offset, .fetch, .join, .inner, .left, .right, .full, .cross, .on, .using, .natural, .window => true,
                    // AT TIME ZONE continues the expression.
                    .at => false,
                    else => !lexer.reserved(token.keyword),
                },
                else => false,
            };
        }

        pub fn expression(self: *Self) Error!u16 {
            try self.enter();
            defer self.leave();
            // Fast path for the common bare column (projection lists).
            const niladic = wordIs(self.source, self.current, "current_timestamp") or wordIs(self.source, self.current, "current_date");
            if ((self.current.kind == .word and !lexer.reserved(self.current.keyword) and !niladic) or self.current.kind == .quoted_word) {
                if (ends(try self.peek())) {
                    const name = try self.identifier();
                    return self.pool.add(.{ .kind = .column, .name = name });
                }
            }
            var left = try self.andExpr();
            while (try self.takeWord("OR")) {
                const right = try self.andExpr();
                left = try self.pool.add(.{ .kind = .or_op, .a = left, .b = right });
            }
            return left;
        }

        fn andExpr(self: *Self) Error!u16 {
            var left = try self.notExpr();
            while (try self.takeWord("AND")) {
                const right = try self.notExpr();
                left = try self.pool.add(.{ .kind = .and_op, .a = left, .b = right });
            }
            return left;
        }

        fn notExpr(self: *Self) Error!u16 {
            if (try self.takeWord("NOT")) {
                try self.enter();
                defer self.leave();
                const operand = try self.notExpr();
                return self.pool.add(.{ .kind = .not_op, .a = operand });
            }
            return self.isExpr();
        }

        fn isExpr(self: *Self) Error!u16 {
            var left = try self.comparison();
            while (try self.takeWord("IS")) {
                const negated = try self.takeWord("NOT");
                const kind: ast.Test = if (try self.takeWord("NULL"))
                    (if (negated) .is_not_null else .is_null)
                else if (try self.takeWord("TRUE"))
                    (if (negated) .is_not_true else .is_true)
                else if (try self.takeWord("FALSE"))
                    (if (negated) .is_not_false else .is_false)
                else if (try self.takeWord("UNKNOWN"))
                    (if (negated) .is_not_unknown else .is_unknown)
                else
                    return error.Syntax;
                left = try self.pool.add(.{ .kind = .test_op, .test_kind = kind, .a = left });
            }
            return left;
        }

        fn comparisonOp(self: *const Self) ?ast.Op {
            if (self.current.kind != .symbol) return null;
            return switch (self.current.symbol) {
                .eq => .eq,
                .ne => .ne,
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
                else => null,
            };
        }

        fn comparison(self: *Self) Error!u16 {
            const left = try self.pattern();
            const op = self.comparisonOp() orelse return left;
            try self.advance();
            const right = try self.pattern();
            // Comparison operators are non-associative in PostgreSQL.
            if (self.comparisonOp() != null) return error.Syntax;
            return self.pool.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
        }

        fn lparenNext(token: Token) bool {
            return token.kind == .symbol and token.symbol == .lparen;
        }

        fn patternKeyword(token: Token) bool {
            return token.isWord("IN") or token.isWord("LIKE") or token.isWord("ILIKE") or token.isWord("BETWEEN");
        }

        fn pattern(self: *Self) Error!u16 {
            const left = try self.other();
            var negated = false;
            if (self.isWord("NOT") and patternKeyword(try self.peek())) {
                try self.advance();
                negated = true;
            }
            if (try self.takeWord("BETWEEN")) {
                const low = try self.other();
                try self.expectWord("AND");
                const high = try self.other();
                return self.pool.add(.{ .kind = .between, .negated = negated, .a = left, .b = low, .c = high });
            }
            if (try self.takeWord("IN")) {
                try self.expectSymbol(.lparen);
                if (self.mode == .standard and (self.isWord("SELECT") or self.isWord("WITH"))) {
                    const inner = try self.query();
                    try self.expectSymbol(.rparen);
                    self.pool.complex = true;
                    return self.pool.add(.{ .kind = .in_subquery, .negated = negated, .a = left, .integer = inner });
                }
                const first = try self.expression();
                const node = try self.pool.add(.{ .kind = .in_list, .negated = negated, .a = left, .b = first });
                var last = first;
                while (try self.takeSymbol(.comma)) {
                    const item = try self.expression();
                    self.pool.nodes[last].next = item;
                    try self.pool.raise(node, item);
                    last = item;
                }
                try self.expectSymbol(.rparen);
                return node;
            }
            const insensitive = self.isWord("ILIKE");
            if (insensitive or self.isWord("LIKE")) {
                try self.advance();
                const pattern_node = try self.other();
                return self.pool.add(.{ .kind = .like, .negated = negated, .insensitive = insensitive, .a = left, .b = pattern_node });
            }
            return left;
        }

        fn other(self: *Self) Error!u16 {
            var left = try self.additive();
            while (self.current.kind == .symbol) {
                const op: ast.Op = switch (self.current.symbol) {
                    .concat => .concat,
                    .arrow => .arrow,
                    .arrow_text => .arrow_text,
                    .path => .path,
                    .path_text => .path_text,
                    .contains => .contains,
                    .contained => .contained,
                    .question => .exists,
                    else => break,
                };
                try self.advance();
                const right = try self.additive();
                left = try self.pool.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
            }
            return left;
        }

        fn additive(self: *Self) Error!u16 {
            var left = try self.multiplicative();
            while (self.isSymbol(.plus) or self.isSymbol(.minus)) {
                const op: ast.Op = if (self.isSymbol(.plus)) .add else .sub;
                try self.advance();
                const right = try self.multiplicative();
                left = try self.pool.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
            }
            return left;
        }

        fn multiplicative(self: *Self) Error!u16 {
            var left = try self.atZone();
            while (self.isSymbol(.star) or self.isSymbol(.slash) or self.isSymbol(.percent)) {
                const op: ast.Op = if (self.isSymbol(.star)) .mul else if (self.isSymbol(.slash)) .div else .mod;
                try self.advance();
                const right = try self.atZone();
                left = try self.pool.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
            }
            return left;
        }

        /// `x AT TIME ZONE z` binds tighter than `*` and looser than unary minus.
        fn atZone(self: *Self) Error!u16 {
            var left = try self.unary();
            while (self.isWord("AT")) {
                const after = try self.peek();
                if (!after.isWord("TIME")) break;
                try self.advance();
                try self.advance();
                try self.expectWord("ZONE");
                const zone = try self.unary();
                left = try self.pool.add(.{ .kind = .at_zone, .a = left, .b = zone });
            }
            return left;
        }

        fn unary(self: *Self) Error!u16 {
            if (!self.isSymbol(.minus) and !self.isSymbol(.plus)) return self.castExpr();
            const negative = self.isSymbol(.minus);
            try self.enter();
            defer self.leave();
            try self.advance();
            if (negative and self.current.kind == .integer) {
                // PostgreSQL negates a numeric constant in the grammar, unless
                // `::` binds to the constant first.
                const after = try self.peek();
                if (!(after.kind == .symbol and after.symbol == .cast) and self.current.integer <= 9223372036854775808) {
                    const magnitude = self.current.integer;
                    const value: i64 = if (magnitude == 9223372036854775808) -9223372036854775808 else -@as(i64, @intCast(magnitude));
                    try self.advance();
                    return self.pool.add(.{ .kind = .int_literal, .integer = value });
                }
            }
            const operand = try self.unary();
            return self.pool.add(.{ .kind = .unary, .op = if (negative) .neg else .pos, .a = operand });
        }

        fn castExpr(self: *Self) Error!u16 {
            var node = try self.primary();
            while (try self.takeSymbol(.cast)) {
                const target = try self.typeName();
                node = try self.pool.add(.{ .kind = .cast, .cast_type = target.ty, .typmod = target.typmod, .a = node });
            }
            return node;
        }

        /// Parses `( expr, ... )` arguments into a list; returns its head.
        fn arguments(self: *Self, owner_kind: ast.NodeKind, allow_star: bool) Error!u16 {
            try self.expectSymbol(.lparen);
            if (allow_star and try self.takeSymbol(.star)) {
                try self.expectSymbol(.rparen);
                return self.pool.add(.{ .kind = owner_kind });
            }
            if (allow_star and try self.takeSymbol(.rparen)) return self.pool.add(.{ .kind = owner_kind });
            const first = try self.expression();
            const node = try self.pool.add(.{ .kind = owner_kind, .b = first });
            var last = first;
            while (try self.takeSymbol(.comma)) {
                const item = try self.expression();
                self.pool.nodes[last].next = item;
                try self.pool.raise(node, item);
                last = item;
            }
            try self.expectSymbol(.rparen);
            return node;
        }

        fn aggregateName(self: *const Self, name: ast.Ident) bool {
            const raw = name.span.slice(self.source);
            for ([_][]const u8{ "count", "sum", "avg", "min", "max", "bool_and", "bool_or", "every" }) |word| {
                if (types.keyword(raw, word)) return true;
            }
            return false;
        }

        /// name(args) with `*`, DISTINCT/ALL and FILTER (WHERE ...) for aggregates.
        fn functionCall(self: *Self, name: ast.Ident) Error!u16 {
            try self.expectSymbol(.lparen);
            var call: ast.Node = .{ .kind = .function, .name = name };
            var first: u16 = none;
            if (try self.takeSymbol(.star)) {
                call.star = true;
                try self.expectSymbol(.rparen);
            } else if (!try self.takeSymbol(.rparen)) {
                if (self.mode == .standard and try self.takeWord("DISTINCT")) {
                    call.distinct = true;
                } else if (self.mode == .standard) _ = try self.takeWord("ALL");
                first = try self.expression();
                call.b = first;
            }
            const node = try self.pool.add(call);
            if (first != none) {
                var last = first;
                while (try self.takeSymbol(.comma)) {
                    const item = try self.expression();
                    self.pool.nodes[last].next = item;
                    try self.pool.raise(node, item);
                    last = item;
                }
                try self.expectSymbol(.rparen);
            }
            if (self.mode == .standard and self.isWord("FILTER") and lparenNext(try self.peek())) {
                try self.advance();
                try self.advance();
                try self.expectWord("WHERE");
                const filter = try self.expression();
                try self.expectSymbol(.rparen);
                self.pool.nodes[node].c = filter;
                try self.pool.raise(node, filter);
            }
            const n = &self.pool.nodes[node];
            if (n.distinct or n.c != none or self.aggregateName(name)) self.pool.complex = true;
            return node;
        }

        fn caseExpr(self: *Self) Error!u16 {
            const operand = if (self.isWord("WHEN")) none else try self.expression();
            var first: u16 = none;
            var last: u16 = none;
            while (try self.takeWord("WHEN")) {
                const condition = try self.expression();
                try self.expectWord("THEN");
                const result = try self.expression();
                const arm = try self.pool.add(.{ .kind = .when_arm, .a = condition, .b = result });
                if (first == none) {
                    first = arm;
                } else {
                    self.pool.nodes[last].next = arm;
                }
                last = arm;
            }
            if (first == none) return error.Syntax;
            const otherwise = if (try self.takeWord("ELSE")) try self.expression() else none;
            try self.expectWord("END");
            const node = try self.pool.add(.{ .kind = .case_expr, .a = operand, .b = first, .c = otherwise });
            var arm = self.pool.nodes[first].next;
            while (arm != none) : (arm = self.pool.nodes[arm].next) try self.pool.raise(node, arm);
            return node;
        }

        fn primary(self: *Self) Error!u16 {
            const token = self.current;
            switch (token.kind) {
                .integer => {
                    try self.advance();
                    // Integer literals beyond int8 are NUMERIC, as in PostgreSQL.
                    if (token.integer > 9223372036854775807) return self.pool.add(.{ .kind = .decimal_literal, .name = .{ .span = .{ .start = token.start, .len = token.len } } });
                    return self.pool.add(.{ .kind = .int_literal, .integer = @intCast(token.integer) });
                },
                .decimal => {
                    try self.advance();
                    return self.pool.add(.{ .kind = .decimal_literal, .name = .{ .span = .{ .start = token.start, .len = token.len } } });
                },
                .string => {
                    try self.advance();
                    return self.pool.add(.{ .kind = .text_literal, .text = token.quoted() });
                },
                .parameter => {
                    try self.advance();
                    return self.pool.add(.{ .kind = .param, .integer = @intCast(token.integer) });
                },
                .symbol => {
                    if (token.symbol != .lparen) return error.Syntax;
                    try self.advance();
                    if (self.mode == .standard and (self.isWord("SELECT") or self.isWord("WITH"))) {
                        const query_index = try self.query();
                        try self.expectSymbol(.rparen);
                        self.pool.complex = true;
                        return self.pool.add(.{ .kind = .scalar_subquery, .integer = query_index });
                    }
                    const inner = try self.expression();
                    try self.expectSymbol(.rparen);
                    return inner;
                },
                .end => return error.Syntax,
                .word, .quoted_word => {},
            }
            if (token.kind == .word) {
                if (try self.takeWord("NULL")) return self.pool.add(.{ .kind = .null_literal });
                if (try self.takeWord("TRUE")) return self.pool.add(.{ .kind = .bool_literal, .boolean = true });
                if (try self.takeWord("FALSE")) return self.pool.add(.{ .kind = .bool_literal, .boolean = false });
                if (try self.takeWord("CASE")) return self.caseExpr();
                if (try self.takeWord("CAST")) {
                    try self.expectSymbol(.lparen);
                    const inner = try self.expression();
                    try self.expectWord("AS");
                    const target = try self.typeName();
                    try self.expectSymbol(.rparen);
                    return self.pool.add(.{ .kind = .cast, .cast_type = target.ty, .typmod = target.typmod, .a = inner });
                }
                // Typed literal: DATE '...', TIMESTAMP [WITH TIME ZONE] '...', ...
                if (typeWord(token)) {
                    const after = try self.peek();
                    const multiword = (token.isWord("DOUBLE") and after.isWord("PRECISION")) or
                        (token.isWord("TIMESTAMP") and (after.isWord("WITH") or after.isWord("WITHOUT"))) or
                        ((token.isWord("NUMERIC") or token.isWord("DECIMAL") or token.isWord("TIMESTAMP") or token.isWord("TIMESTAMPTZ")) and after.kind == .symbol and after.symbol == .lparen);
                    if (after.kind == .string or multiword) {
                        const target = try self.typeName();
                        if (self.current.kind != .string) return error.Syntax;
                        const literal = self.current;
                        try self.advance();
                        const inner = try self.pool.add(.{ .kind = .text_literal, .text = literal.quoted() });
                        return self.pool.add(.{ .kind = .cast, .cast_type = target.ty, .typmod = target.typmod, .a = inner });
                    }
                }
                // SQL-standard niladic functions.
                if (wordIs(self.source, token, "current_timestamp") or wordIs(self.source, token, "current_date")) {
                    const name = try self.identifier();
                    return self.pool.add(.{ .kind = .function, .name = name });
                }
                if ((self.isWord("COALESCE") or self.isWord("NULLIF")) and lparenNext(try self.peek())) {
                    const is_coalesce = self.isWord("COALESCE");
                    try self.advance();
                    const node = try self.arguments(if (is_coalesce) .coalesce else .nullif, false);
                    if (!is_coalesce) {
                        // NULLIF takes exactly two arguments: a = first, b = second.
                        const first = self.pool.nodes[node].b;
                        const second = self.pool.nodes[first].next;
                        if (second == none or self.pool.nodes[second].next != none) return error.Syntax;
                        self.pool.nodes[first].next = none;
                        self.pool.nodes[node].a = first;
                        self.pool.nodes[node].b = second;
                    }
                    return node;
                }
            }
            if (self.mode == .standard and token.kind == .word and self.isWord("EXISTS") and lparenNext(try self.peek())) {
                try self.advance();
                try self.advance();
                if (!self.isWord("SELECT") and !self.isWord("WITH")) return error.Syntax;
                const query_index = try self.query();
                try self.expectSymbol(.rparen);
                self.pool.complex = true;
                return self.pool.add(.{ .kind = .exists_subquery, .integer = query_index });
            }
            const name = try self.identifier();
            if (self.isSymbol(.lparen)) return self.functionCall(name);
            if (try self.takeSymbol(.dot)) {
                if (self.mode == .standard and try self.takeSymbol(.star)) return self.pool.add(.{ .kind = .column, .star = true, .qualifier = name });
                const column = try self.identifier();
                return self.pool.add(.{ .kind = .column, .name = column, .qualifier = name });
            }
            return self.pool.add(.{ .kind = .column, .name = name });
        }
    };
}
