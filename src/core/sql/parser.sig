//! Recursive-descent parser (Layer 0, design §4.1).
//!
//! Statements: CREATE/DROP TABLE; single-row INSERT [column list] VALUES
//! (expressions); SELECT targets [FROM t [[AS] alias]] [WHERE e] [ORDER BY
//! key [ASC|DESC] [NULLS FIRST|LAST], ...] [LIMIT n]; UPDATE t SET c = e, ...
//! [WHERE e]; DELETE FROM t [WHERE e]; BEGIN/COMMIT/ROLLBACK [TRANSACTION].
//!
//! Expressions use PostgreSQL precedence, lowest first: OR, AND, NOT, IS,
//! comparison (non-associative), BETWEEN/IN/LIKE/ILIKE, `||` (and JSON
//! operators, tokenized only), `+ -`, `* / %`, unary `+ -`, `::`. Primaries
//! are literals, (qualified) columns, parentheses, CASE, CAST, COALESCE,
//! NULLIF, function calls and `$n`. Recursion and tree depth are bounded by
//! Config.expr_depth and nodes by Config.expr_nodes (StatementTooComplex).
//!
//! `legacy_alpha` first runs the frozen alpha recognizer (alpha.sig) so kind
//! 1/2 replay accepts exactly the alpha grammar; it must never grow.
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const ast = @import("ast.sig");
const alpha = @import("alpha.sig");
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
            if (try self.takeWord("SELECT")) return .{ .select = try self.select() };
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

        fn typeName(self: *Self) Error!ast.TypeName {
            const out: ast.TypeName = if (self.isWord("INTEGER") or self.isWord("INT") or self.isWord("INT4"))
                .integer
            else if (self.isWord("BIGINT") or self.isWord("INT8"))
                .bigint
            else if (self.isWord("BOOLEAN") or self.isWord("BOOL"))
                .boolean
            else if (self.isWord("TEXT"))
                .text
            else
                return error.Syntax;
            try self.advance();
            return out;
        }

        fn create(self: *Self) Error!Ast.CreateTable {
            try self.expectWord("TABLE");
            var out: Ast.CreateTable = .{ .name = try self.identifier() };
            try self.expectSymbol(.lparen);
            var has_primary = false;
            while (true) {
                if (out.count == config.columns) return error.ColumnCapacity;
                var column: Ast.ColumnDef = .{ .name = try self.identifier() };
                column.type_name = try self.typeName();
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

        fn select(self: *Self) Error!Ast.Select {
            var out: Ast.Select = .{};
            var star = false;
            while (true) {
                if (out.count == config.columns) return error.ColumnCapacity;
                var target: Ast.Target = .{};
                if (try self.takeSymbol(.star)) {
                    target.star = true;
                    star = true;
                } else {
                    target.expr = try self.expression();
                    target.alias = try self.bareAlias();
                }
                out.targets[out.count] = target;
                out.count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            if (try self.takeWord("FROM")) {
                var from: Ast.TableRef = .{ .name = try self.identifier() };
                from.alias = try self.bareAlias();
                out.from = from;
            } else if (star) return error.Syntax;
            out.where = try self.where();
            if (try self.takeWord("ORDER")) {
                try self.expectWord("BY");
                while (true) {
                    if (out.order_count == config.columns) return error.ColumnCapacity;
                    var key: Ast.OrderKey = .{ .expr = try self.expression() };
                    if (try self.takeWord("DESC")) key.descending = true else _ = try self.takeWord("ASC");
                    if (try self.takeWord("NULLS")) {
                        if (try self.takeWord("FIRST")) key.nulls_first = true else if (try self.takeWord("LAST")) key.nulls_first = false else return error.Syntax;
                    }
                    out.order[out.order_count] = key;
                    out.order_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
            }
            var limited = false;
            if (try self.takeWord("LIMIT")) {
                try self.limitValue(&out);
                limited = true;
            }
            if (self.mode == .standard and try self.takeWord("FOR")) {
                if (out.from == null) return error.Syntax;
                if (try self.takeWord("UPDATE")) out.lock.strength = .update else {
                    try self.expectWord("SHARE");
                    out.lock.strength = .share;
                }
                if (try self.takeWord("NOWAIT")) out.lock.wait = .nowait else if (try self.takeWord("SKIP")) {
                    try self.expectWord("LOCKED");
                    out.lock.wait = .skip_locked;
                }
                if (!limited and try self.takeWord("LIMIT")) try self.limitValue(&out);
            }
            try self.finish();
            return out;
        }

        fn limitValue(self: *Self, out: *Ast.Select) Error!void {
            if (self.current.kind != .integer) return error.Syntax;
            out.limit = self.current.integer;
            try self.advance();
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
                    else => !lexer.reserved(token.keyword),
                },
                else => false,
            };
        }

        pub fn expression(self: *Self) Error!u16 {
            try self.enter();
            defer self.leave();
            // Fast path for the common bare column (projection lists).
            if ((self.current.kind == .word and !lexer.reserved(self.current.keyword)) or self.current.kind == .quoted_word) {
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
                    .arrow, .arrow_text, .path, .path_text, .contains, .contained, .question => .json,
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
            var left = try self.unary();
            while (self.isSymbol(.star) or self.isSymbol(.slash) or self.isSymbol(.percent)) {
                const op: ast.Op = if (self.isSymbol(.star)) .mul else if (self.isSymbol(.slash)) .div else .mod;
                try self.advance();
                const right = try self.unary();
                left = try self.pool.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
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
                if (!(after.kind == .symbol and after.symbol == .cast)) {
                    const magnitude = self.current.integer;
                    if (magnitude > 9223372036854775808) return error.IntegerOverflow;
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
                node = try self.pool.add(.{ .kind = .cast, .cast_type = target, .a = node });
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
                    if (token.integer > 9223372036854775807) return error.IntegerOverflow;
                    try self.advance();
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
                    return self.pool.add(.{ .kind = .cast, .cast_type = target, .a = inner });
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
            const name = try self.identifier();
            if (self.isSymbol(.lparen)) {
                const node = try self.arguments(.function, true);
                self.pool.nodes[node].name = name;
                return node;
            }
            if (try self.takeSymbol(.dot)) {
                const column = try self.identifier();
                return self.pool.add(.{ .kind = .column, .name = column, .qualifier = name });
            }
            return self.pool.add(.{ .kind = .column, .name = name });
        }
    };
}
