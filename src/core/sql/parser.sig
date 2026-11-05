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
const sequence = @import("sequence.sig");
const character = @import("character.sig");
const bit_string = @import("bit_string.sig");
const array_module = @import("array.sig");
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
            const legacy_quantifier_name = self.mode == .legacy_alpha and (token.keyword == .any or token.keyword == .some);
            if (token.kind != .word or (lexer.reserved(token.keyword) and !legacy_quantifier_name)) return error.Syntax;
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

        /// A standalone expression (column DEFAULT / generation text) parsed
        /// into the statement's pool without resetting it; its spans refer to
        /// `source`, which must be evaluated with that source.
        pub fn parseExpression(source: []const u8, pool: *Ast.Pool) Error!u16 {
            var self = Self{ .tokens = .{ .source = source, .text_limit = config.text_bytes }, .pool = pool, .source = source, .mode = .standard };
            try self.advance();
            const id = try self.expression();
            if (self.current.kind != .end) return error.Syntax;
            return id;
        }

        fn statement(self: *Self) Error!Ast.Statement {
            if (try self.takeWord("CREATE")) {
                if (self.mode == .standard) if (try self.schemaObject()) |object| return object;
                if (self.mode == .standard and try self.takeWord("SEQUENCE")) return .{ .create_sequence = try self.createSequence() };
                if (self.mode == .standard and try self.takeRaw("schema")) {
                    var out: Ast.CreateSchema = .{ .if_not_exists = try self.ifNotExists() };
                    out.name = try self.identifier();
                    // AUTHORIZATION and schema elements are outside the subset.
                    if (self.current.kind != .end and !self.isSymbol(.semicolon)) return error.UnsupportedStatement;
                    try self.finish();
                    return .{ .create_schema = out };
                }
                return .{ .create_table = try self.create() };
            }
            if (try self.takeWord("DROP")) {
                if (self.mode == .standard and (self.rawWord("index") or self.rawWord("view") or self.rawWord("materialized"))) {
                    const index = try self.takeRaw("index");
                    const materialized = !index and try self.takeRaw("materialized");
                    if (!index and !try self.takeRaw("view")) return error.Syntax;
                    if (index) _ = try self.takeRaw("concurrently");
                    var drop: Ast.Drop = .{ .if_exists = try self.ifExists(), .name = undefined };
                    const reference = try self.qualifiedName();
                    drop.name = reference.name;
                    drop.schema = reference.schema;
                    if (self.isSymbol(.comma)) return error.UnsupportedStatement;
                    drop.cascade = try self.dropBehavior();
                    try self.finish();
                    if (index) return .{ .drop_index = drop };
                    return .{ .drop_view = .{ .drop = drop, .materialized = materialized } };
                }
                if (self.mode == .standard and try self.takeRaw("schema")) {
                    var out: Ast.DropSchema = .{ .if_exists = try self.ifExists() };
                    out.name = try self.identifier();
                    if (try self.takeRaw("cascade")) out.cascade = true else _ = try self.takeRaw("restrict");
                    try self.finish();
                    return .{ .drop_schema = out };
                }
                const sequence_kind = self.mode == .standard and try self.takeWord("SEQUENCE");
                if (!sequence_kind) try self.expectWord("TABLE");
                const conditional = self.mode == .standard and self.rawWord("if") and (try self.peek()).isWord("EXISTS");
                if (conditional) try self.advance();
                if (conditional) try self.expectWord("EXISTS");
                var drop: Ast.Drop = .{ .name = try self.identifier(), .if_exists = conditional };
                if (self.mode == .standard and try self.takeSymbol(.dot)) {
                    drop.schema = drop.name;
                    drop.name = try self.identifier();
                }
                if (self.mode == .standard) drop.cascade = try self.dropBehavior();
                try self.finish();
                return if (sequence_kind) .{ .drop_sequence = drop } else .{ .drop_table = drop };
            }
            if (try self.takeWord("INSERT")) return .{ .insert = try self.insert() };
            if (self.isWord("SELECT") or (self.mode == .standard and self.isWord("WITH"))) return self.topQuery();
            if (try self.takeWord("UPDATE")) return .{ .update = try self.update() };
            if (try self.takeWord("DELETE")) return .{ .delete = try self.delete() };
            if (self.mode == .standard and self.rawWord("copy")) {
                try self.advance();
                return .{ .copy = try self.copyStatement() };
            }
            if (self.mode == .standard and self.rawWord("refresh")) {
                try self.advance();
                if (!try self.takeRaw("materialized") or !try self.takeRaw("view")) return error.Syntax;
                if (try self.takeRaw("concurrently")) return error.UnsupportedStatement;
                const name = try self.qualifiedName();
                const with_data = try self.withData();
                try self.finish();
                return .{ .refresh_view = .{ .name = name, .with_data = with_data } };
            }
            if (self.mode == .standard and self.rawWord("merge")) {
                try self.advance();
                return .{ .merge = try self.merge() };
            }
            if (self.mode == .standard and self.isWord("SET") and wordIs(self.source, try self.peek(), "constraints")) {
                try self.advance();
                try self.advance();
                var out: Ast.SetConstraints = .{};
                if (try self.takeWord("ALL")) {
                    out.all = true;
                } else while (true) {
                    if (out.count == out.names.len) return error.TableCapacity;
                    out.names[out.count] = (try self.qualifiedName()).name;
                    out.count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
                if (try self.takeRaw("deferred")) {
                    out.deferred = true;
                } else if (!try self.takeRaw("immediate")) return error.Syntax;
                try self.finish();
                return .{ .set_constraints = out };
            }
            if (self.mode == .standard and self.rawWord("truncate")) {
                try self.advance();
                return .{ .truncate = try self.truncateStatement() };
            }
            if (self.mode == .standard and self.rawWord("alter")) {
                try self.advance();
                if (try self.takeWord("TABLE")) return .{ .alter_table = try self.alterTable() };
                if (try self.takeWord("SEQUENCE")) {
                    var out: Ast.AlterSequence = .{ .if_exists = try self.ifExists() };
                    out.name = try self.qualifiedName();
                    try self.sequenceOptions(&out.options);
                    // OWNED BY, RENAME TO, SET SCHEMA ... are outside the subset.
                    if (self.current.kind != .end and !self.isSymbol(.semicolon)) return error.UnsupportedStatement;
                    try self.finish();
                    return .{ .alter_sequence = out };
                }
                return error.UnsupportedStatement;
            }
            if (self.mode == .legacy_alpha) {
                if (try self.takeWord("BEGIN")) return self.legacyControl(.{ .begin = .default });
                if (try self.takeWord("COMMIT")) return self.legacyControl(.commit);
                if (try self.takeWord("ROLLBACK")) return self.legacyControl(.rollback);
                return error.UnsupportedStatement;
            }
            return .{ .control = try self.controlStatement() };
        }

        /// `[CASCADE | RESTRICT]`: true for CASCADE.
        fn dropBehavior(self: *Self) Error!bool {
            if (try self.takeRaw("cascade")) return true;
            _ = try self.takeRaw("restrict");
            return false;
        }

        /// `[WITH [NO] DATA]`: false for WITH NO DATA.
        fn withData(self: *Self) Error!bool {
            if (!self.isWord("WITH")) return true;
            const next = try self.peek();
            if (!next.isWord("NO") and !wordIs(self.source, next, "data")) return true;
            try self.advance();
            const no = try self.takeWord("NO");
            if (!try self.takeRaw("data")) return error.Syntax;
            return !no;
        }

        /// CREATE [OR REPLACE] [UNIQUE] INDEX | [TEMP] [MATERIALIZED] VIEW |
        /// TEMP TABLE; null for the other CREATE forms (nothing consumed
        /// except a TEMP/TEMPORARY/UNLOGGED prefix, recorded for TABLE).
        fn schemaObject(self: *Self) Error!?Ast.Statement {
            if (self.isWord("OR") and wordIs(self.source, try self.peek(), "replace")) return error.UnsupportedStatement;
            if (try self.takeRaw("unique")) {
                if (!try self.takeRaw("index")) return error.Syntax;
                return .{ .create_index = try self.createIndex(true) };
            }
            if (try self.takeRaw("index")) return .{ .create_index = try self.createIndex(false) };
            var temporary = false;
            if (try self.takeRaw("temp") or try self.takeRaw("temporary")) temporary = true else _ = try self.takeRaw("unlogged");
            if (try self.takeRaw("materialized")) {
                if (temporary or !try self.takeRaw("view")) return error.Syntax;
                return .{ .create_view = try self.createView(true) };
            }
            if (try self.takeRaw("view")) return .{ .create_view = try self.createView(false) };
            if (temporary) {
                var out = try self.create();
                out.temporary = true;
                return .{ .create_table = out };
            }
            return null;
        }

        fn createIndex(self: *Self, unique: bool) Error!Ast.CreateIndex {
            var out: Ast.CreateIndex = .{ .unique = unique };
            if (try self.takeRaw("concurrently")) return error.UnsupportedStatement;
            out.if_not_exists = try self.ifNotExists();
            if (!self.isWord("ON")) out.name = try self.identifier();
            if (out.if_not_exists and out.name == null) return error.Syntax;
            try self.expectWord("ON");
            _ = try self.takeWord("ONLY");
            out.table = try self.qualifiedName();
            if (try self.takeWord("USING")) {
                // Hash entries serve btree and hash requests; others are 0A000.
                if (!try self.takeRaw("btree") and !try self.takeRaw("hash")) return error.UnsupportedStatement;
            }
            try self.expectSymbol(.lparen);
            while (true) {
                if (out.count == config.columns) return error.ColumnCapacity;
                var element: Ast.IndexElement = .{};
                if (try self.takeSymbol(.lparen)) {
                    const start = self.tokenStart();
                    element.node = try self.expression();
                    element.expression = self.spanTo(start);
                    try self.expectSymbol(.rparen);
                } else {
                    element.column = try self.identifier();
                }
                if (try self.takeWord("DESC")) element.descending = true else _ = try self.takeWord("ASC");
                if (try self.takeWord("NULLS")) {
                    if (try self.takeWord("FIRST")) element.nulls_first = true else {
                        try self.expectWord("LAST");
                        element.nulls_first = false;
                    }
                }
                out.elements[out.count] = element;
                out.count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
            if (try self.takeRaw("include")) {
                try self.expectSymbol(.lparen);
                while (true) {
                    if (out.include_count == config.columns) return error.ColumnCapacity;
                    out.includes[out.include_count] = try self.identifier();
                    out.include_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
                try self.expectSymbol(.rparen);
            }
            out.nulls_not_distinct = try self.nullsDistinct();
            if (try self.takeWord("WHERE")) {
                const start = self.tokenStart();
                out.predicate_node = try self.expression();
                out.predicate = self.spanTo(start);
            }
            try self.finish();
            return out;
        }

        fn createView(self: *Self, materialized: bool) Error!Ast.CreateView {
            var out: Ast.CreateView = .{ .materialized = materialized };
            if (materialized) out.if_not_exists = try self.ifNotExists();
            out.name = try self.qualifiedName();
            if (try self.takeSymbol(.lparen)) {
                while (true) {
                    if (out.column_count == config.columns) return error.ColumnCapacity;
                    out.columns[out.column_count] = try self.identifier();
                    out.column_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
                try self.expectSymbol(.rparen);
            }
            try self.expectWord("AS");
            if (!self.isWord("SELECT") and !self.isWord("WITH")) return error.UnsupportedStatement;
            const start = self.tokenStart();
            out.query = try self.query();
            out.text = self.spanTo(start);
            if (materialized) out.with_data = try self.withData();
            if (!materialized and self.isWord("WITH")) return error.UnsupportedStatement;
            try self.finish();
            return out;
        }

        /// A query block of a stored view text inside `source` from `start`
        /// (statement source plus appended view texts): spans stay absolute.
        pub fn parseQueryAt(source: []const u8, start: usize, end: usize, pool: *Ast.Pool) Error!u16 {
            var self = Self{ .tokens = .{ .source = source[0..end], .position = start, .text_limit = config.text_bytes }, .pool = pool, .source = source[0..end], .mode = .standard };
            try self.advance();
            const complex = pool.complex;
            const id = try self.query();
            if (self.current.kind != .end) return error.Syntax;
            pool.complex = complex;
            return id;
        }

        /// MERGE INTO target [[AS] alias] USING source [[AS] alias] ON cond
        /// WHEN MATCHED [AND cond] THEN UPDATE SET ... | DELETE | DO NOTHING
        /// WHEN NOT MATCHED [BY TARGET] [AND cond] THEN INSERT [(cols)]
        /// VALUES (...) | DEFAULT VALUES | DO NOTHING
        /// WHEN NOT MATCHED BY SOURCE [AND cond] THEN UPDATE | DELETE | DO NOTHING.
        fn merge(self: *Self) Error!Ast.Merge {
            try self.expectWord("INTO");
            _ = try self.takeWord("ONLY");
            var out: Ast.Merge = .{ .table = try self.qualifiedName() };
            out.table.alias = try self.targetAlias();
            try self.expectWord("USING");
            const block = try self.pool.newQuery();
            try self.fromItem(&self.pool.queries[block], .first);
            const q = &self.pool.queries[block];
            if (q.items[0].query == none) q.from = .{ .schema = q.items[0].schema, .name = q.items[0].name, .alias = q.items[0].alias };
            q.targets[0] = .{ .star = true };
            q.count = 1;
            out.source = block;
            try self.expectWord("ON");
            out.on = try self.expression();
            while (try self.takeWord("WHEN")) {
                if (out.when_count == Ast.merge_clauses) return error.StatementTooComplex;
                var when: Ast.MergeWhen = .{};
                if (try self.takeWord("NOT")) {
                    when.matched = false;
                    if (!try self.takeRaw("matched")) return error.Syntax;
                    if (try self.takeWord("BY")) {
                        if (try self.takeRaw("source")) {
                            when.by_source = true;
                            when.matched = true;
                        } else if (!try self.takeRaw("target")) return error.Syntax;
                    }
                } else if (!try self.takeRaw("matched")) return error.Syntax;
                if (try self.takeWord("AND")) when.condition = try self.expression();
                try self.expectWord("THEN");
                if (try self.takeWord("DO")) {
                    try self.expectWord("NOTHING");
                    when.action = .nothing;
                } else if (when.matched) {
                    if (try self.takeWord("UPDATE")) {
                        try self.expectWord("SET");
                        when.action = .update;
                        while (true) {
                            try self.setItem(&when.assignments, &when.count);
                            if (!try self.takeSymbol(.comma)) break;
                        }
                    } else if (try self.takeWord("DELETE")) {
                        when.action = .delete;
                    } else return error.Syntax;
                } else {
                    try self.expectWord("INSERT");
                    when.action = .insert;
                    if (try self.takeSymbol(.lparen)) {
                        while (true) {
                            if (when.column_count == config.columns) return error.ColumnCapacity;
                            when.columns[when.column_count] = try self.identifier();
                            when.column_count += 1;
                            if (!try self.takeSymbol(.comma)) break;
                        }
                        try self.expectSymbol(.rparen);
                    }
                    if (try self.takeWord("OVERRIDING")) return error.UnsupportedStatement;
                    if (try self.takeWord("DEFAULT")) {
                        try self.expectWord("VALUES");
                    } else {
                        try self.expectWord("VALUES");
                        try self.expectSymbol(.lparen);
                        const row = try self.pool.add(.{ .kind = .values_row });
                        var last: u16 = none;
                        var items: usize = 0;
                        while (true) {
                            if (items == config.columns) return error.Syntax;
                            const item = try self.valueItem();
                            if (last == none) self.pool.nodes[row].b = item else self.pool.nodes[last].next = item;
                            last = item;
                            items += 1;
                            if (!try self.takeSymbol(.comma)) break;
                        }
                        try self.expectSymbol(.rparen);
                        self.pool.nodes[row].integer = @intCast(items);
                        when.values = row;
                    }
                }
                out.whens[out.when_count] = when;
                out.when_count += 1;
            }
            if (out.when_count == 0) return error.Syntax;
            if (self.isWord("RETURNING")) return error.UnsupportedStatement;
            try self.finish();
            return out;
        }

        /// `name` or `schema.name`.
        fn qualifiedName(self: *Self) Error!Ast.TableRef {
            var out: Ast.TableRef = .{ .name = try self.identifier() };
            if (try self.takeSymbol(.dot)) {
                out.schema = out.name;
                out.name = try self.identifier();
            }
            return out;
        }

        fn ifExists(self: *Self) Error!bool {
            if (!self.rawWord("if") or !(try self.peek()).isWord("EXISTS")) return false;
            try self.advance();
            try self.advance();
            return true;
        }

        fn pushAction(out: *Ast.AlterTable, action: Ast.AlterAction) Error!void {
            if (out.count == out.actions.len) return error.ColumnCapacity;
            out.actions[out.count] = action;
            out.count += 1;
        }

        /// ALTER TABLE [IF EXISTS] [ONLY] name [*] followed by
        /// RENAME [COLUMN] a TO b | RENAME TO name, or a list of
        /// ADD [COLUMN] [IF NOT EXISTS] column | ADD table_constraint |
        /// DROP [COLUMN] [IF EXISTS] c | DROP CONSTRAINT [IF EXISTS] n
        /// [RESTRICT | CASCADE] | ALTER [COLUMN] c SET DEFAULT e | DROP
        /// DEFAULT | SET NOT NULL | DROP NOT NULL. Other forms are 0A000.
        fn alterTable(self: *Self) Error!Ast.AlterTable {
            var out: Ast.AlterTable = .{ .if_exists = try self.ifExists() };
            _ = try self.takeWord("ONLY");
            out.table = try self.qualifiedName();
            _ = try self.takeSymbol(.star);
            if (try self.takeRaw("rename")) {
                if (try self.takeWord("TO")) {
                    try pushAction(&out, .{ .rename_table = try self.identifier() });
                } else {
                    if (self.isWord("CONSTRAINT")) return error.UnsupportedStatement;
                    _ = try self.takeRaw("column");
                    const from = try self.identifier();
                    try self.expectWord("TO");
                    try pushAction(&out, .{ .rename_column = .{ .from = from, .to = try self.identifier() } });
                }
                try self.finish();
                return out;
            }
            while (true) {
                if (try self.takeRaw("add")) {
                    if (try self.tableConstraint()) |constraint| {
                        try pushAction(&out, .{ .add_constraint = constraint });
                    } else {
                        _ = try self.takeRaw("column");
                        const conditional = try self.ifNotExists();
                        var constraints: [config.table_constraints]Ast.ConstraintDef = undefined;
                        var constraint_count: usize = 0;
                        var invalid = false;
                        var has_primary = false;
                        const column = try self.columnDef(false, &invalid, &has_primary, .{ .items = constraints[0..], .count = &constraint_count });
                        try pushAction(&out, .{ .add_column = .{ .column = column, .if_not_exists = conditional } });
                        for (constraints[0..constraint_count]) |constraint| try pushAction(&out, .{ .add_constraint = constraint });
                    }
                } else if (try self.takeWord("DROP")) {
                    if (try self.takeWord("CONSTRAINT")) {
                        const conditional = try self.ifExists();
                        try pushAction(&out, .{ .drop_constraint = .{ .if_exists = conditional, .name = try self.identifier() } });
                    } else {
                        _ = try self.takeRaw("column");
                        const conditional = try self.ifExists();
                        try pushAction(&out, .{ .drop_column = .{ .if_exists = conditional, .name = try self.identifier() } });
                    }
                    if (!try self.takeRaw("cascade")) _ = try self.takeRaw("restrict");
                } else if (try self.takeRaw("alter")) {
                    _ = try self.takeRaw("column");
                    const name = try self.identifier();
                    if (try self.takeWord("SET")) {
                        if (try self.takeWord("DEFAULT")) {
                            const start = self.tokenStart();
                            _ = try self.expression();
                            try pushAction(&out, .{ .set_default = .{ .column = name, .expression = self.spanTo(start) } });
                        } else if (try self.takeWord("NOT")) {
                            try self.expectWord("NULL");
                            try pushAction(&out, .{ .set_not_null = name });
                        } else return error.UnsupportedStatement;
                    } else if (try self.takeWord("DROP")) {
                        if (try self.takeWord("DEFAULT")) {
                            try pushAction(&out, .{ .drop_default = name });
                        } else if (try self.takeWord("NOT")) {
                            try self.expectWord("NULL");
                            try pushAction(&out, .{ .drop_not_null = name });
                        } else return error.UnsupportedStatement;
                    } else return error.UnsupportedStatement;
                } else return error.Syntax;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.finish();
            return out;
        }

        /// TRUNCATE [TABLE] [ONLY] name [*] [, ...] [RESTART IDENTITY |
        /// CONTINUE IDENTITY] [CASCADE | RESTRICT].
        fn truncateStatement(self: *Self) Error!Ast.Truncate {
            var out: Ast.Truncate = .{};
            _ = try self.takeWord("TABLE");
            while (true) {
                _ = try self.takeRaw("only");
                if (out.count == config.tables) return error.TableCapacity;
                out.tables[out.count] = try self.qualifiedName();
                out.count += 1;
                _ = try self.takeSymbol(.star);
                if (!try self.takeSymbol(.comma)) break;
            }
            if (try self.takeRaw("restart")) {
                if (!try self.takeRaw("identity")) return error.Syntax;
                out.restart_identity = true;
            } else if (try self.takeRaw("continue")) {
                if (!try self.takeRaw("identity")) return error.Syntax;
            }
            if (!try self.takeRaw("cascade")) _ = try self.takeRaw("restrict");
            try self.finish();
            return out;
        }

        /// The current token is the unquoted word `wanted` (any keyword
        /// class; COPY's words are not keywords of the tokenizer).
        fn rawWord(self: *const Self, comptime wanted: []const u8) bool {
            return wordIs(self.source, self.current, wanted);
        }

        fn takeRaw(self: *Self, comptime wanted: []const u8) Error!bool {
            if (!self.rawWord(wanted)) return false;
            try self.advance();
            return true;
        }

        /// COPY [BINARY] t [(columns)] FROM STDIN | COPY {t [(columns)] |
        /// (query)} TO STDOUT, then [WITH] (option [arg], ...) or the
        /// pre-9.0 option list (BINARY, DELIMITER [AS] 'c', NULL [AS] 's',
        /// CSV, HEADER, QUOTE [AS] 'q', ESCAPE [AS] 'e'). Files, PROGRAM,
        /// WHERE and FORCE_* options are outside the subset (0A000).
        fn copyStatement(self: *Self) Error!Ast.Copy {
            var out: Ast.Copy = .{};
            if (self.rawWord("binary")) {
                const next = try self.peek();
                if (next.kind == .word or next.kind == .quoted_word) {
                    try self.advance();
                    out.options.format = .binary;
                    out.options.format_set = true;
                }
            }
            if (try self.takeSymbol(.lparen)) {
                const start = self.tokenStart();
                var depth: usize = 1;
                while (true) {
                    if (self.current.kind == .end) return error.Syntax;
                    if (self.isSymbol(.lparen)) depth += 1;
                    if (self.isSymbol(.rparen)) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    try self.advance();
                }
                out.query = self.spanTo(start);
                try self.advance();
                if (out.query.?.len == 0) return error.Syntax;
            } else {
                const first = try self.identifier();
                if (try self.takeSymbol(.dot)) {
                    out.table = .{ .schema = first, .name = try self.identifier() };
                } else out.table = .{ .name = first };
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
            }
            if (try self.takeWord("FROM")) {
                if (out.query != null) return error.Syntax;
                out.direction = .from;
                if (!try self.takeRaw("stdin")) return if (self.current.kind == .string or self.rawWord("program")) error.UnsupportedStatement else error.Syntax;
            } else if (try self.takeRaw("to")) {
                out.direction = .to;
                if (!try self.takeRaw("stdout")) return if (self.current.kind == .string or self.rawWord("program")) error.UnsupportedStatement else error.Syntax;
            } else return error.Syntax;
            _ = try self.takeWord("WITH");
            if (try self.takeSymbol(.lparen)) {
                while (true) {
                    try self.copyGenericOption(&out.options);
                    if (!try self.takeSymbol(.comma)) break;
                }
                try self.expectSymbol(.rparen);
            } else try self.copyLegacyOptions(&out.options);
            if (self.isWord("WHERE")) return error.UnsupportedStatement;
            try self.finish();
            return out;
        }

        fn copyString(self: *Self, out: *ast.CopyText) Error!void {
            if (out.set) return error.Syntax;
            const token = self.current;
            out.set = true;
            switch (token.kind) {
                .string => {
                    out.len = token.len;
                    if (token.len <= out.bytes.len) lexer.decodeQuoted(self.source, token.quoted(), out.bytes[0..token.len]);
                },
                .word, .integer, .decimal => {
                    const raw = token.raw(self.source);
                    out.len = raw.len;
                    if (raw.len <= out.bytes.len) {
                        for (raw, 0..) |byte, index| out.bytes[index] = if (token.kind == .word) types.lower(byte) else byte;
                    }
                },
                else => return error.Syntax,
            }
            try self.advance();
        }

        /// One `name [argument]` item of the parenthesized option list.
        fn copyGenericOption(self: *Self, options: *ast.CopyOptions) Error!void {
            if (self.current.kind != .word) return error.Syntax;
            const name = self.current.raw(self.source);
            try self.advance();
            const has_argument = !(self.isSymbol(.comma) or self.isSymbol(.rparen));
            if (types.keyword(name, "format")) {
                if (options.format_set or !has_argument) return error.Syntax;
                var text: ast.CopyText = .{};
                try self.copyString(&text);
                const value = text.slice();
                options.format_set = true;
                options.format = if (types.keyword(value, "text")) .text else if (types.keyword(value, "csv")) .csv else if (types.keyword(value, "binary")) .binary else return error.InvalidParameterValue;
            } else if (types.keyword(name, "delimiter")) {
                if (!has_argument) return error.Syntax;
                try self.copyString(&options.delimiter);
            } else if (types.keyword(name, "null")) {
                if (!has_argument) return error.Syntax;
                try self.copyString(&options.null_string);
            } else if (types.keyword(name, "quote")) {
                if (!has_argument) return error.Syntax;
                try self.copyString(&options.quote);
            } else if (types.keyword(name, "escape")) {
                if (!has_argument) return error.Syntax;
                try self.copyString(&options.escape);
            } else if (types.keyword(name, "header")) {
                if (options.header_set) return error.Syntax;
                options.header_set = true;
                options.header = .on;
                if (!has_argument) return;
                var text: ast.CopyText = .{};
                try self.copyString(&text);
                const value = text.slice();
                if (types.keyword(value, "match")) {
                    options.header = .match;
                } else options.header = if (copyBoolean(value)) |on| (if (on) .on else .off) else return error.InvalidParameterValue;
            } else if (types.keyword(name, "freeze")) {
                if (options.freeze_set) return error.Syntax;
                options.freeze_set = true;
                if (has_argument) {
                    var text: ast.CopyText = .{};
                    try self.copyString(&text);
                    if (copyBoolean(text.slice()) == null) return error.InvalidParameterValue;
                }
            } else if (types.keyword(name, "encoding")) {
                if (options.encoding_set or !has_argument) return error.Syntax;
                options.encoding_set = true;
                var text: ast.CopyText = .{};
                try self.copyString(&text);
                if (!(types.keyword(text.slice(), "utf8") or types.keyword(text.slice(), "utf-8"))) return error.UnsupportedStatement;
            } else if (types.keyword(name, "force_quote") or types.keyword(name, "force_not_null") or types.keyword(name, "force_null") or
                types.keyword(name, "default") or types.keyword(name, "on_error") or types.keyword(name, "log_verbosity") or types.keyword(name, "reject_limit"))
            {
                return error.UnsupportedStatement;
            } else return error.Syntax;
        }

        /// parse_bool's spellings (and 0/1) for HEADER/FREEZE.
        fn copyBoolean(value: []const u8) ?bool {
            if (types.keyword(value, "true") or types.keyword(value, "on") or types.keyword(value, "1") or types.keyword(value, "t") or types.keyword(value, "yes")) return true;
            if (types.keyword(value, "false") or types.keyword(value, "off") or types.keyword(value, "0") or types.keyword(value, "f") or types.keyword(value, "no")) return false;
            return null;
        }

        fn copyLegacyOptions(self: *Self, options: *ast.CopyOptions) Error!void {
            while (self.current.kind == .word) {
                if (try self.takeRaw("binary")) {
                    if (options.format_set) return error.Syntax;
                    options.format = .binary;
                    options.format_set = true;
                } else if (try self.takeRaw("csv")) {
                    if (options.format_set) return error.Syntax;
                    options.format = .csv;
                    options.format_set = true;
                } else if (try self.takeRaw("header")) {
                    if (options.header_set) return error.Syntax;
                    options.header_set = true;
                    options.header = .on;
                } else if (try self.takeRaw("delimiter")) {
                    _ = try self.takeWord("AS");
                    try self.copyString(&options.delimiter);
                } else if (try self.takeWord("NULL")) {
                    _ = try self.takeWord("AS");
                    try self.copyString(&options.null_string);
                } else if (try self.takeRaw("quote")) {
                    _ = try self.takeWord("AS");
                    try self.copyString(&options.quote);
                } else if (try self.takeRaw("escape")) {
                    _ = try self.takeWord("AS");
                    try self.copyString(&options.escape);
                } else if (self.rawWord("force") or self.rawWord("freeze") or self.rawWord("encoding")) {
                    return error.UnsupportedStatement;
                } else return;
            }
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
                .integer, .int, .int4, .bigint, .int8, .smallint, .int2, .boolean, .@"bool", .text, .numeric, .decimal, .real, .float4, .float8, .float, .double, .name, .oid, .date, .timestamp, .timestamptz, .interval, .json, .jsonb, .regclass, .regtype => true,
                .varchar, .character, .char, .bpchar, .uuid, .bytea, .time, .timetz, .bit, .varbit, .money => true,
                .pg_lsn, .xid8, .int4range, .int8range, .numrange, .daterange, .tsrange, .tstzrange, .inet, .cidr, .macaddr, .point, .box, .xml => true,
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

        /// `(n)` of a character type: an unsigned integer constant (a sign
        /// is a syntax error), 1..10485760 (22023 otherwise). Without it,
        /// CHARACTER means CHARACTER(1) and VARCHAR/BPCHAR are unlimited.
        fn characterLength(self: *Self, default_one: bool) Error!i32 {
            if (!try self.takeSymbol(.lparen)) return if (default_one) character.typmodOf(1) else -1;
            if (self.current.kind != .integer) return error.Syntax;
            const length = self.current.integer;
            try self.advance();
            try self.expectSymbol(.rparen);
            return character.typmodOf(length);
        }

        /// `(n)` of BIT/VARBIT (typmod n, 1..83886080); BIT means BIT(1).
        fn bitLength(self: *Self, default_one: bool) Error!i32 {
            if (!try self.takeSymbol(.lparen)) return if (default_one) 1 else -1;
            if (self.current.kind != .integer) return error.Syntax;
            const length = self.current.integer;
            try self.advance();
            try self.expectSymbol(.rparen);
            return bit_string.typmodOf(length);
        }

        /// A type name with an optional array suffix: `[]`, `[n]` (repeated;
        /// sizes and dimensions are ignored) or `ARRAY [n]`.
        fn typeName(self: *Self) Error!TypeSpec {
            var spec = try self.scalarTypeName();
            var array = false;
            while (self.isSymbol(.lbracket)) {
                try self.advance();
                if (self.current.kind == .integer) try self.advance();
                try self.expectSymbol(.rbracket);
                array = true;
            }
            if (!array and self.rawWord("array")) {
                try self.advance();
                if (try self.takeSymbol(.lbracket)) {
                    if (self.current.kind != .integer) return error.Syntax;
                    try self.advance();
                    try self.expectSymbol(.rbracket);
                }
                array = true;
            }
            if (array) {
                if (spec.typmod == ast.regclass_typmod or spec.typmod == ast.regtype_typmod) return error.UnsupportedStatement;
                spec.ty = types.arrayType(spec.ty) orelse return error.Syntax;
            }
            return spec;
        }

        fn scalarTypeName(self: *Self) Error!TypeSpec {
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
                .regclass => .{ .ty = .oid, .typmod = ast.regclass_typmod },
                .regtype => .{ .ty = .oid, .typmod = ast.regtype_typmod },
                .varchar => .{ .ty = .varchar, .typmod = try self.characterLength(false) },
                .bpchar => .{ .ty = .bpchar, .typmod = try self.characterLength(false) },
                .uuid => .{ .ty = .uuid },
                .bytea => .{ .ty = .bytea },
                .time => blk: {
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
                    break :blk .{ .ty = if (zoned) .timetz else .time, .typmod = p };
                },
                .timetz => .{ .ty = .timetz, .typmod = try self.precision() },
                .bit => blk: {
                    const varying = try self.takeWord("VARYING");
                    break :blk .{ .ty = if (varying) .varbit else .bit, .typmod = try self.bitLength(!varying) };
                },
                .varbit => .{ .ty = .varbit, .typmod = try self.bitLength(false) },
                .money => .{ .ty = .money },
                .pg_lsn => .{ .ty = .pg_lsn },
                .xid8 => .{ .ty = .xid8 },
                .int4range => .{ .ty = .int4range },
                .int8range => .{ .ty = .int8range },
                .numrange => .{ .ty = .numrange },
                .daterange => .{ .ty = .daterange },
                .tsrange => .{ .ty = .tsrange },
                .tstzrange => .{ .ty = .tstzrange },
                .inet => .{ .ty = .inet },
                .cidr => .{ .ty = .cidr },
                .macaddr => .{ .ty = .macaddr },
                .point => .{ .ty = .point },
                .box => .{ .ty = .box },
                .xml => .{ .ty = .xml },
                .character, .char => blk: {
                    const varying = try self.takeWord("VARYING");
                    break :blk .{ .ty = if (varying) .varchar else .bpchar, .typmod = try self.characterLength(!varying) };
                },
                else => unreachable,
            };
        }

        /// A signed integer option value.
        fn signedInteger(self: *Self) Error!i64 {
            const negative = try self.takeSymbol(.minus);
            if (!negative) _ = try self.takeSymbol(.plus);
            if (self.current.kind == .decimal) return error.NumericValueOutOfRange;
            if (self.current.kind != .integer) return error.Syntax;
            const magnitude = self.current.integer;
            try self.advance();
            if (negative) {
                if (magnitude > 9223372036854775808) return error.NumericValueOutOfRange;
                return if (magnitude == 9223372036854775808) -0x7fffffffffffffff - 1 else -@as(i64, @intCast(magnitude));
            }
            if (magnitude > 9223372036854775807) return error.NumericValueOutOfRange;
            return @intCast(magnitude);
        }

        /// Sequence options (CREATE SEQUENCE and identity specifications).
        fn sequenceOptions(self: *Self, out: *sequence.Options) Error!void {
            var seen:u16=0;
            while (true) {
                var option:u16=0;
                if (try self.takeWord("INCREMENT")) {
                    option=1;
                    _ = try self.takeWord("BY");
                    out.increment = try self.signedInteger();
                } else if (try self.takeWord("MINVALUE")) {
                    option=2;
                    out.min = try self.signedInteger();
                } else if (try self.takeWord("MAXVALUE")) {
                    option=4;
                    out.max = try self.signedInteger();
                } else if (try self.takeWord("START")) {
                    option=8;
                    _ = try self.takeWord("WITH");
                    out.start = try self.signedInteger();
                } else if (try self.takeWord("CACHE")) {
                    option=16;
                    out.cache = try self.signedInteger();
                } else if (try self.takeWord("CYCLE")) {
                    option=32;
                    out.cycle = true;
                    out.cycle_set = true;
                } else if (self.mode == .standard and try self.takeRaw("restart")) {
                    option=128;
                    out.restart = true;
                    if (try self.takeWord("WITH")) {
                        out.restart_value = try self.signedInteger();
                    } else if (self.current.kind == .integer or (self.current.kind == .symbol and (self.current.symbol == .minus or self.current.symbol == .plus))) {
                        out.restart_value = try self.signedInteger();
                    }
                } else if (try self.takeWord("NO")) {
                    if (try self.takeWord("MINVALUE")) {
                        option=2;
                        out.min = null;
                        out.no_min = true;
                    } else if (try self.takeWord("MAXVALUE")) {
                        option=4;
                        out.max = null;
                        out.no_max = true;
                    } else {
                        try self.expectWord("CYCLE");
                        option=32;
                        out.cycle = false;
                        out.cycle_set = true;
                    }
                } else if (try self.takeWord("AS")) {
                    option=64;
                    const spec = try self.typeName();
                    out.type_oid = switch (spec.ty) {
                        .int2 => 21,
                        .int4 => 23,
                        .int8 => 20,
                        // Type validity is semantic: an existing conditional
                        // creation skips option validation before resolve().
                        else => 0xffffffff,
                    };
                } else return;
                if(seen&option!=0) out.duplicate_options=true;
                seen|=option;
            }
        }

        fn ifNotExists(self: *Self) Error!bool {
            if (self.mode != .standard or !self.rawWord("if") or !(try self.peek()).isWord("NOT")) return false;
            try self.advance();
            try self.expectWord("NOT");try self.expectWord("EXISTS");return true;
        }

        fn createSequence(self: *Self) Error!Ast.CreateSequence {
            const conditional = try self.ifNotExists();
            var out: Ast.CreateSequence = .{ .name = try self.identifier(), .if_not_exists = conditional };
            try self.sequenceOptions(&out.options);
            try self.finish();
            return out;
        }

        /// Source text from `start` to the current token (exclusive), trimmed.
        fn spanTo(self: *const Self, start: usize) ast.Span {
            var end = self.current.start;
            if (self.current.kind == .end) end = self.source.len;
            if (self.current.kind == .string or self.current.kind == .quoted_word) end -= self.current.prefix;
            while (end > start and (self.source[end - 1] == ' ' or self.source[end - 1] == '\t' or self.source[end - 1] == '\r' or self.source[end - 1] == '\n')) end -= 1;
            return .{ .start = start, .len = end - start };
        }

        fn tokenStart(self: *const Self) usize {
            return if (self.current.kind == .string or self.current.kind == .quoted_word) self.current.start - self.current.prefix else self.current.start;
        }

        /// Constraint list filled by CREATE TABLE or ALTER TABLE ADD.
        const ConstraintSink = struct { items: []Ast.ConstraintDef, count: *usize };

        fn pushConstraint(sink: ConstraintSink, definition: Ast.ConstraintDef) Error!void {
            if (sink.count.* == sink.items.len) return error.ColumnCapacity;
            sink.items[sink.count.*] = definition;
            sink.count.* += 1;
        }

        /// `(expr) [NO INHERIT]` after CHECK.
        fn checkConstraint(self: *Self, name: ?ast.Ident) Error!Ast.ConstraintDef {
            try self.expectSymbol(.lparen);
            const start = self.tokenStart();
            const node = try self.expression();
            var out: Ast.ConstraintDef = .{ .name = name, .kind = .check, .node = node };
            out.expression = self.spanTo(start);
            try self.expectSymbol(.rparen);
            if (self.isWord("NO") and wordIs(self.source, try self.peek(), "inherit")) {
                try self.advance();
                try self.advance();
            }
            return out;
        }

        /// `[NULLS [NOT] DISTINCT]` after UNIQUE; true for NOT DISTINCT.
        fn nullsDistinct(self: *Self) Error!bool {
            if (!try self.takeWord("NULLS")) return false;
            const not_distinct = try self.takeWord("NOT");
            try self.expectWord("DISTINCT");
            return not_distinct;
        }

        /// `(column, ...)` of a table-level UNIQUE or PRIMARY KEY.
        fn keyColumns(self: *Self, out: *Ast.ConstraintDef) Error!void {
            try self.expectSymbol(.lparen);
            while (true) {
                if (out.column_count == config.columns) return error.ColumnCapacity;
                out.columns[out.column_count] = try self.identifier();
                out.column_count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
        }

        /// A table constraint element ([CONSTRAINT name] CHECK (...) |
        /// UNIQUE [NULLS [NOT] DISTINCT] (...) | PRIMARY KEY (...)), or null
        /// when the element is a column definition.
        fn tableConstraint(self: *Self) Error!?Ast.ConstraintDef {
            if (self.mode != .standard) return null;
            var name: ?ast.Ident = null;
            if (try self.takeWord("CONSTRAINT")) {
                name = try self.identifier();
            } else {
                const next = try self.peek();
                const paren = next.kind == .symbol and next.symbol == .lparen;
                const starts = (self.rawWord("check") and paren) or (self.rawWord("unique") and (paren or next.isWord("NULLS"))) or self.isWord("PRIMARY") or
                    (self.rawWord("foreign") and next.isWord("KEY")) or (self.isWord("EXCLUDE") and (paren or next.isWord("USING")));
                if (!starts) return null;
            }
            if (try self.takeRaw("check")) return try self.checkConstraint(name);
            if (try self.takeRaw("unique")) {
                var out: Ast.ConstraintDef = .{ .name = name, .kind = .unique, .nulls_not_distinct = try self.nullsDistinct() };
                try self.keyColumns(&out);
                try self.deferrability(&out);
                return out;
            }
            if (try self.takeWord("PRIMARY")) {
                try self.expectWord("KEY");
                var out: Ast.ConstraintDef = .{ .name = name, .kind = .primary };
                try self.keyColumns(&out);
                try self.deferrability(&out);
                return out;
            }
            if (try self.takeRaw("foreign")) {
                try self.expectWord("KEY");
                var out: Ast.ConstraintDef = .{ .name = name, .kind = .foreign };
                try self.keyColumns(&out);
                if (!try self.takeRaw("references")) return error.Syntax;
                try self.references(&out);
                return out;
            }
            if (try self.takeWord("EXCLUDE")) {
                var out: Ast.ConstraintDef = .{ .name = name, .kind = .exclusion };
                if (try self.takeWord("USING")) {
                    if (!try self.takeRaw("gist") and !try self.takeRaw("btree") and !try self.takeRaw("hash")) return error.UnsupportedStatement;
                }
                try self.expectSymbol(.lparen);
                while (true) {
                    if (out.column_count == config.columns) return error.ColumnCapacity;
                    out.columns[out.column_count] = try self.identifier();
                    try self.expectWord("WITH");
                    if (try self.takeSymbol(.eq)) {
                        out.operators[out.column_count] = 1;
                    } else if (try self.takeSymbol(.ampersand)) {
                        // `&&` tokenizes as two `&`.
                        try self.expectSymbol(.ampersand);
                        out.operators[out.column_count] = 2;
                    } else return error.UnsupportedStatement;
                    out.column_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
                try self.expectSymbol(.rparen);
                if (self.isWord("WHERE") or self.rawWord("include")) return error.UnsupportedStatement;
                try self.deferrability(&out);
                return out;
            }
            return error.Syntax;
        }

        /// [NOT] DEFERRABLE [INITIALLY DEFERRED | IMMEDIATE], in any order.
        fn deferrability(self: *Self, out: *Ast.ConstraintDef) Error!void {
            while (true) {
                if (self.isWord("NOT") and wordIs(self.source, try self.peek(), "deferrable")) {
                    try self.advance();
                    try self.advance();
                    out.deferrable = false;
                } else if (try self.takeRaw("deferrable")) {
                    out.deferrable = true;
                } else if (try self.takeRaw("initially")) {
                    if (try self.takeRaw("deferred")) out.initially_deferred = true else if (try self.takeRaw("immediate")) out.initially_deferred = false else return error.Syntax;
                } else break;
            }
            if (out.initially_deferred) out.deferrable = true;
        }

        fn foreignAction(self: *Self) Error!Ast.ForeignAction {
            if (try self.takeWord("NO")) {
                if (!try self.takeRaw("action")) return error.Syntax;
                return .no_action;
            }
            if (try self.takeRaw("restrict")) return .restrict;
            if (try self.takeRaw("cascade")) return .cascade;
            try self.expectWord("SET");
            const action: Ast.ForeignAction = if (try self.takeWord("NULL")) .set_null else blk: {
                try self.expectWord("DEFAULT");
                break :blk .set_default;
            };
            // SET NULL / SET DEFAULT (column list) is outside the subset.
            if (self.isSymbol(.lparen)) return error.UnsupportedStatement;
            return action;
        }

        /// REFERENCES table [(columns)] [MATCH SIMPLE] [ON DELETE action]
        /// [ON UPDATE action] [deferrability]; MATCH FULL/PARTIAL are 0A000.
        fn references(self: *Self, out: *Ast.ConstraintDef) Error!void {
            out.ref_table = try self.qualifiedName();
            if (try self.takeSymbol(.lparen)) {
                while (true) {
                    if (out.ref_count == config.columns) return error.ColumnCapacity;
                    out.ref_columns[out.ref_count] = try self.identifier();
                    out.ref_count += 1;
                    if (!try self.takeSymbol(.comma)) break;
                }
                try self.expectSymbol(.rparen);
            }
            if (try self.takeRaw("match")) {
                if (!try self.takeRaw("simple")) return error.UnsupportedStatement;
            }
            while (self.isWord("ON")) {
                try self.advance();
                if (try self.takeWord("DELETE")) out.on_delete = try self.foreignAction() else {
                    try self.expectWord("UPDATE");
                    out.on_update = try self.foreignAction();
                }
            }
            try self.deferrability(out);
        }

        /// One column definition with its column constraints; CHECK, UNIQUE
        /// and named PRIMARY KEY constraints go to `sink`.
        fn columnDef(self: *Self, if_not_exists: bool, invalid: *bool, has_primary: *bool, sink: ConstraintSink) Error!Ast.ColumnDef {
            var column: Ast.ColumnDef = .{ .name = try self.identifier() };
            // SMALLSERIAL / SERIAL / BIGSERIAL: an integer column owning a
            // sequence that its DEFAULT draws from (binder).
            const serials = [_]struct { word: []const u8, ty: ast.TypeName, oid: u32 }{
                .{ .word = "serial", .ty = .int4, .oid = 23 },      .{ .word = "serial4", .ty = .int4, .oid = 23 },
                .{ .word = "bigserial", .ty = .int8, .oid = 20 },   .{ .word = "serial8", .ty = .int8, .oid = 20 },
                .{ .word = "smallserial", .ty = .int2, .oid = 21 }, .{ .word = "serial2", .ty = .int2, .oid = 21 },
            };
            for (serials) |serial| {
                if (self.mode == .standard and self.current.kind == .word and types.keyword(self.current.raw(self.source), serial.word)) {
                    try self.advance();
                    column.type_name = serial.ty;
                    column.serial = serial.oid;
                    break;
                }
            } else {
                const spec = try self.typeName();
                // regclass/regtype columns are outside the subset.
                if (spec.typmod < -1) return error.UnsupportedStatement;
                column.type_name = spec.ty;
                column.typmod = spec.typmod;
            }
            var has_not_null = false;
            while (true) {
                var name: ?ast.Ident = null;
                if (self.mode == .standard and try self.takeWord("CONSTRAINT")) name = try self.identifier();
                if (self.mode == .standard and try self.takeWord("DEFAULT")) {
                    if (column.default_kind != .none) {if(if_not_exists) invalid.*=true else return error.Syntax;}
                    column.default_kind = .default;
                    const start = self.tokenStart();
                    _ = try self.other();
                    column.expression = self.spanTo(start);
                } else if (self.mode == .standard and try self.takeWord("GENERATED")) {
                    if (column.default_kind != .none) {if(if_not_exists) invalid.*=true else return error.Syntax;}
                    var always = true;
                    if (try self.takeWord("BY")) {
                        try self.expectWord("DEFAULT");
                        always = false;
                    } else try self.expectWord("ALWAYS");
                    try self.expectWord("AS");
                    if (try self.takeWord("IDENTITY")) {
                        column.default_kind = if (always) .identity_always else .identity_by_default;
                        if (try self.takeSymbol(.lparen)) {
                            try self.sequenceOptions(&column.sequence);
                            try self.expectSymbol(.rparen);
                        }
                    } else {
                        if (!always) return error.Syntax;
                        try self.expectSymbol(.lparen);
                        const start = self.tokenStart();
                        _ = try self.expression();
                        column.expression = self.spanTo(start);
                        try self.expectSymbol(.rparen);
                        // PostgreSQL 18: VIRTUAL unless STORED is written.
                        if (!try self.takeWord("STORED")) {
                            _ = try self.takeRaw("virtual");
                            column.virtual = true;
                        }
                        column.default_kind = .generated;
                    }
                } else if (self.mode == .standard and self.isWord("NULL")) {
                    try self.advance();
                } else if (try self.takeWord("NOT")) {
                    if (has_not_null) {if(if_not_exists) invalid.*=true else return error.Syntax;}
                    try self.expectWord("NULL");
                    has_not_null = true;
                    column.not_null = true;
                } else if (try self.takeWord("PRIMARY")) {
                    if (has_primary.*) {if(if_not_exists) invalid.*=true else return error.Syntax;}
                    try self.expectWord("KEY");
                    has_primary.* = true;
                    column.primary_key = true;
                    column.not_null = true;
                    if (name != null) {
                        var definition: Ast.ConstraintDef = .{ .name = name, .kind = .primary, .column_count = 1 };
                        definition.columns[0] = column.name;
                        try pushConstraint(sink, definition);
                    }
                } else if (self.mode == .standard and try self.takeRaw("check")) {
                    try pushConstraint(sink, try self.checkConstraint(name));
                } else if (self.mode == .standard and try self.takeRaw("unique")) {
                    var definition: Ast.ConstraintDef = .{ .name = name, .kind = .unique, .nulls_not_distinct = try self.nullsDistinct(), .column_count = 1 };
                    definition.columns[0] = column.name;
                    try self.deferrability(&definition);
                    try pushConstraint(sink, definition);
                } else if (self.mode == .standard and try self.takeRaw("references")) {
                    var definition: Ast.ConstraintDef = .{ .name = name, .kind = .foreign, .column_count = 1 };
                    definition.columns[0] = column.name;
                    try self.references(&definition);
                    try pushConstraint(sink, definition);
                } else if (self.mode == .standard and (self.rawWord("deferrable") or self.rawWord("initially") or (self.isWord("NOT") and wordIs(self.source, try self.peek(), "deferrable")))) {
                    // After an unnamed column PRIMARY KEY: a deferrable
                    // primary key index is outside the subset.
                    var probe: Ast.ConstraintDef = .{};
                    try self.deferrability(&probe);
                    if (probe.deferrable) return error.UnsupportedStatement;
                } else {
                    if (name != null) return error.Syntax;
                    break;
                }
            }
            return column;
        }

        fn create(self: *Self) Error!Ast.CreateTable {
            try self.expectWord("TABLE");
            const conditional = try self.ifNotExists();
            const reference = try self.qualifiedName();
            var out: Ast.CreateTable = .{ .schema = reference.schema, .name = reference.name, .if_not_exists = conditional };
            if (self.mode == .standard) {
                if (try self.takeWord("AS")) return self.createAs(out);
                if (try self.takeRaw("partition")) {
                    if (!try self.takeRaw("of")) return error.Syntax;
                    out.partition_of = try self.qualifiedName();
                    try self.partitionBound(&out.bound);
                    if (self.rawWord("partition")) return error.UnsupportedStatement;
                    try self.finish();
                    return out;
                }
                // CREATE TABLE t (a, b) AS query: a bare column-name list.
                if (self.isSymbol(.lparen)) {
                    const next = try self.peek();
                    if (next.kind == .word or next.kind == .quoted_word) {
                        var copy = self.*;
                        try copy.advance();
                        const named = if (copy.identifier()) |_| true else |_| false;
                        if (named and (copy.isSymbol(.comma) or copy.isSymbol(.rparen))) {
                            try self.advance();
                            while (true) {
                                if (out.as_column_count == config.columns) return error.ColumnCapacity;
                                out.as_columns[out.as_column_count] = try self.identifier();
                                out.as_column_count += 1;
                                if (!try self.takeSymbol(.comma)) break;
                            }
                            try self.expectSymbol(.rparen);
                            try self.expectWord("AS");
                            return self.createAs(out);
                        }
                    }
                }
            }
            try self.expectSymbol(.lparen);
            var has_primary = false;
            const sink: ConstraintSink = .{ .items = out.constraints[0..], .count = &out.constraint_count };
            while (true) {
                if (self.mode == .standard and self.isWord("LIKE")) {
                    try self.advance();
                    if (out.like != null) return error.UnsupportedStatement;
                    var like: Ast.Like = .{ .table = try self.qualifiedName(), .position = out.count };
                    while (self.rawWord("including") or self.rawWord("excluding")) {
                        const including = try self.takeRaw("including");
                        if (!including) try self.advance();
                        const all = try self.takeWord("ALL");
                        var defaults = all;
                        var constraints = all;
                        var indexes = all;
                        var identity = all;
                        var generated = all;
                        if (!all) {
                            if (try self.takeWord("DEFAULT") or try self.takeRaw("defaults")) defaults = true
                            else if (try self.takeWord("CONSTRAINT") or try self.takeRaw("constraints")) constraints = true
                            else if (try self.takeRaw("indexes")) indexes = true
                            else if (try self.takeWord("IDENTITY")) identity = true
                            else if (try self.takeWord("GENERATED")) generated = true
                            else if (!try self.takeRaw("comments") and !try self.takeRaw("storage") and !try self.takeRaw("statistics") and !try self.takeRaw("compression")) return error.Syntax;
                        }
                        if (defaults) like.defaults = including;
                        if (constraints) like.constraints = including;
                        if (indexes) like.indexes = including;
                        if (identity) like.identity = including;
                        if (generated) like.generated = including;
                    }
                    out.like = like;
                    if (!try self.takeSymbol(.comma)) break;
                    continue;
                }
                if (try self.tableConstraint()) |constraint| {
                    if (constraint.kind == .primary) {
                        if (has_primary) {if(out.if_not_exists) out.invalid_definition=true else return error.InvalidTableDefinition;}
                        has_primary = true;
                    }
                    try pushConstraint(sink, constraint);
                } else {
                    if (out.count == config.columns) return error.ColumnCapacity;
                    out.columns[out.count] = try self.columnDef(out.if_not_exists, &out.invalid_definition, &has_primary, sink);
                    out.count += 1;
                }
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
            if (self.mode == .standard and try self.takeRaw("inherits")) {
                try self.expectSymbol(.lparen);
                out.inherits = try self.qualifiedName();
                if (self.isSymbol(.comma)) return error.UnsupportedStatement;
                try self.expectSymbol(.rparen);
            }
            if (self.mode == .standard and try self.takeRaw("partition")) {
                try self.expectWord("BY");
                if (try self.takeWord("RANGE")) out.partition_by = .range else if (try self.takeRaw("list")) out.partition_by = .list else return error.UnsupportedStatement;
                try self.expectSymbol(.lparen);
                out.partition_key = try self.identifier();
                if (!self.isSymbol(.rparen)) return error.UnsupportedStatement;
                try self.expectSymbol(.rparen);
            }
            try self.finish();
            return out;
        }

        /// CREATE TABLE ... AS query [WITH [NO] DATA].
        fn createAs(self: *Self, initial: Ast.CreateTable) Error!Ast.CreateTable {
            var out = initial;
            if (!self.isWord("SELECT") and !self.isWord("WITH")) return error.UnsupportedStatement;
            out.as_query = try self.query();
            out.with_data = try self.withData();
            try self.finish();
            return out;
        }

        /// FOR VALUES FROM (v) TO (v) | FOR VALUES IN (v, ...) | DEFAULT.
        fn partitionBound(self: *Self, out: *Ast.PartitionBound) Error!void {
            if (try self.takeWord("DEFAULT")) {
                out.kind = .default;
                return;
            }
            try self.expectWord("FOR");
            try self.expectWord("VALUES");
            if (try self.takeWord("FROM")) {
                out.kind = .range;
                for (0..2) |position| {
                    if (position == 1) try self.expectWord("TO");
                    try self.expectSymbol(.lparen);
                    if (try self.takeWord("MINVALUE")) {
                        out.minvalue = true;
                        out.values[position] = none;
                    } else if (try self.takeWord("MAXVALUE")) {
                        out.maxvalue = true;
                        out.values[position] = none;
                    } else out.values[position] = try self.expression();
                    if (self.isSymbol(.comma)) return error.UnsupportedStatement;
                    try self.expectSymbol(.rparen);
                }
                out.count = 2;
                return;
            }
            try self.expectWord("IN");
            out.kind = .list;
            try self.expectSymbol(.lparen);
            while (true) {
                if (out.count == out.values.len) return error.ColumnCapacity;
                out.values[out.count] = try self.expression();
                out.count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
        }

        fn insert(self: *Self) Error!Ast.Insert {
            try self.expectWord("INTO");
            var out: Ast.Insert = .{ .table = try self.identifier() };
            if (self.mode == .standard and try self.takeSymbol(.dot)) {
                out.schema = out.table;
                out.table = try self.identifier();
            }
            if (self.mode == .standard and try self.takeWord("AS")) out.alias = try self.identifier();
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
            if (self.mode == .standard and try self.takeWord("OVERRIDING")) {
                if (try self.takeWord("SYSTEM")) out.overriding = .system else {
                    try self.expectWord("USER");
                    out.overriding = .user;
                }
                try self.expectWord("VALUE");
            }
            if (self.mode == .standard and try self.takeWord("DEFAULT")) {
                try self.expectWord("VALUES");
                out.source = .default_values;
            } else if (self.mode == .standard and (self.isWord("SELECT") or self.isWord("WITH"))) {
                out.source = .query;
                out.query = try self.query();
            } else {
                try self.expectWord("VALUES");
                var previous: u16 = none;
                while (true) {
                    try self.expectSymbol(.lparen);
                    const row = try self.pool.add(.{ .kind = .values_row });
                    var last: u16 = none;
                    var items: usize = 0;
                    while (true) {
                        if (items == config.columns) return error.Syntax;
                        const item = try self.valueItem();
                        if (last == none) self.pool.nodes[row].b = item else self.pool.nodes[last].next = item;
                        last = item;
                        items += 1;
                        if (!try self.takeSymbol(.comma)) break;
                    }
                    try self.expectSymbol(.rparen);
                    self.pool.nodes[row].integer = @intCast(items);
                    if (previous == none) out.rows = row else self.pool.nodes[previous].next = row;
                    previous = row;
                    out.row_count += 1;
                    if (self.mode != .standard or !try self.takeSymbol(.comma)) break;
                }
            }
            if (self.mode == .standard and try self.takeWord("ON")) {
                try self.expectWord("CONFLICT");
                var conflict: Ast.OnConflict = .{};
                if (try self.takeSymbol(.lparen)) {
                    while (true) {
                        if (conflict.column_count == config.columns) return error.ColumnCapacity;
                        conflict.columns[conflict.column_count] = try self.identifier();
                        conflict.column_count += 1;
                        if (!try self.takeSymbol(.comma)) break;
                    }
                    try self.expectSymbol(.rparen);
                } else if (try self.takeWord("ON")) {
                    try self.expectWord("CONSTRAINT");
                    conflict.constraint = try self.identifier();
                }
                try self.expectWord("DO");
                if (!try self.takeWord("NOTHING")) {
                    try self.expectWord("UPDATE");
                    try self.expectWord("SET");
                    while (true) {
                        try self.setItem(&conflict.assignments, &conflict.count);
                        if (!try self.takeSymbol(.comma)) break;
                    }
                    conflict.where = try self.where();
                    conflict.action = .update;
                }
                out.conflict = conflict;
            }
            try self.returningClause(&out.returning);
            try self.finish();
            return out;
        }

        /// An INSERT VALUES item or SET value: an expression or DEFAULT.
        fn valueItem(self: *Self) Error!u16 {
            if (self.mode == .standard and try self.takeWord("DEFAULT")) return self.pool.add(.{ .kind = .default_value });
            return self.expression();
        }

        /// RETURNING targets: `*`, `t.*` or expressions with aliases.
        fn returningClause(self: *Self, out: *Ast.Returning) Error!void {
            if (self.mode != .standard or !try self.takeWord("RETURNING")) return;
            while (true) {
                if (out.count == config.columns) return error.ColumnCapacity;
                var target: Ast.Target = .{};
                if (try self.takeSymbol(.star)) {
                    target.star = true;
                } else {
                    target.expr = try self.expression();
                    const n = &self.pool.nodes[target.expr];
                    if (n.kind == .column and n.star) target.star = true else target.alias = try self.bareAlias();
                }
                out.targets[out.count] = target;
                out.count += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
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
                    limited = true;block.limit_present=true;
                    if (!(try self.takeWord("ALL")) and !(try self.takeWord("NULL"))) try self.countValue(&block.limit, &block.negative_limit);
                } else if (!offset_seen and self.mode == .standard and try self.takeWord("OFFSET")) {
                    offset_seen = true;block.offset_present=true;
                    self.pool.complex = true;
                    try self.countValue(&block.offset, &block.negative_offset);
                    _ = (try self.takeWord("ROW")) or (try self.takeWord("ROWS"));
                } else if (!limited and self.mode == .standard and try self.takeWord("FETCH")) {
                    limited = true;block.limit_present=true;
                    if (!(try self.takeWord("FIRST"))) try self.expectWord("NEXT");
                    block.limit = 1;
                    if (self.current.kind == .integer or self.isSymbol(.minus) or self.isSymbol(.lparen) or self.current.kind == .decimal) try self.countValue(&block.limit, &block.negative_limit);
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
                var empty=false;
                if(self.isSymbol(.lparen)) {
                    const next=try self.peek();
                    if(next.kind==.symbol and next.symbol==.rparen) {try self.advance();try self.advance();empty=true;out.rollup=true;}
                }
                if(!empty) {
                    out.rollup=try self.takeWord("ROLLUP");
                    if(out.rollup){try self.expectSymbol(.lparen);if(self.isSymbol(.rparen)) return error.Syntax;}
                    while (true) {
                        if (out.group_count == config.columns) return error.ColumnCapacity;
                        out.group[out.group_count] = try self.expression();
                        out.group_count += 1;
                        if (!try self.takeSymbol(.comma)) break;
                    }
                    if(out.rollup) try self.expectSymbol(.rparen);
                }
            }
            if (self.mode == .standard and try self.takeWord("HAVING")) {
                self.pool.complex = true;
                out.having = try self.expression();
            }
            if(self.mode==.standard and try self.takeWord("WINDOW")) {
                self.pool.complex=true;var previous:u16=none;
                while(true) {
                    const name=try self.identifier();try self.expectWord("AS");
                    const owner=try self.pool.add(.{.kind=.null_literal});
                    const window=try self.windowSpec(owner,false);
                    self.pool.windows[window].definition=name;
                    if(previous==none) out.window_defs=window else self.pool.windows[previous].next=window;
                    previous=window;if(!try self.takeSymbol(.comma)) break;
                }
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
                out.from = .{ .schema = out.items[0].schema, .name = out.items[0].name, .alias = out.items[0].alias };
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
            } else {
                if (self.mode == .standard and try self.takeWord("ONLY")) item.only = true;
                item.name = try self.identifier();
                if (self.mode == .standard and try self.takeSymbol(.dot)) {
                    item.schema = item.name;
                    item.name = try self.identifier();
                }
                if (self.mode == .standard and !item.only) _ = try self.takeSymbol(.star);
            }
            item.alias = try self.bareAlias();
            out.items[out.item_count] = item;
            out.item_count += 1;
        }

        /// A LIMIT/OFFSET/FETCH count; negative counts are reported by the
        /// binder (2201W / 2201X) after name resolution, as PostgreSQL
        /// reports them at execution. One pair of parentheses is accepted,
        /// since the wire codecs splice a negative bound parameter as `(-n)`.
        fn countValue(self: *Self, value: *u64, negative: *bool) Error!void {
            const parenthesized = try self.takeSymbol(.lparen);
            const minus = try self.takeSymbol(.minus);
            if (self.current.kind == .decimal) {
                // An integer beyond u64 (bigint out of range, as PostgreSQL).
                for (self.current.raw(self.source)) |byte| if (!types.digit(byte)) return error.Syntax;
                return error.IntegerOverflow;
            }
            if (self.current.kind != .integer) return error.Syntax;
            value.* = self.current.integer;
            try self.advance();
            if (parenthesized) try self.expectSymbol(.rparen);
            if (minus and value.* != 0) negative.* = true;
        }

        /// One SET item: `column = value`, or a multiple-column assignment
        /// `(a, b) = (v1, v2)` / `= ROW(...)` expanded into one item per
        /// column (42601 when the counts differ; a sub-SELECT source is 0A000).
        fn setItem(self: *Self, items: *[config.columns]Ast.Assignment, count: *usize) Error!void {
            if (self.mode != .standard or !self.isSymbol(.lparen)) {
                if (count.* == config.columns) return error.DuplicateColumn;
                const column = try self.identifier();
                try self.expectSymbol(.eq);
                items[count.*] = .{ .column = column, .value = try self.valueItem() };
                count.* += 1;
                return;
            }
            try self.advance();
            var columns: [config.columns]ast.Ident = undefined;
            var width: usize = 0;
            while (true) {
                if (width == config.columns) return error.DuplicateColumn;
                columns[width] = try self.identifier();
                width += 1;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rparen);
            try self.expectSymbol(.eq);
            const row = try self.takeWord("ROW");
            if (self.isSymbol(.lparen) and ((try self.peek()).isWord("SELECT") or (try self.peek()).isWord("WITH"))) return error.UnsupportedStatement;
            // `(a) = (v)` is a parenthesized scalar, not a row: 42601.
            if (!row and width == 1) return error.Syntax;
            try self.expectSymbol(.lparen);
            for (columns[0..width], 0..) |column, index| {
                if (index != 0) try self.expectSymbol(.comma);
                if (count.* == config.columns) return error.DuplicateColumn;
                items[count.*] = .{ .column = column, .value = try self.valueItem() };
                count.* += 1;
            }
            try self.expectSymbol(.rparen);
        }

        /// PostgreSQL reserved and type/function-name keywords the tokenizer
        /// does not classify: never a bare (AS-less) UPDATE/DELETE alias.
        fn reservedWord(raw: []const u8) bool {
            const words = [_][]const u8{
                "analyse", "analyze", "array", "both", "check", "collate", "column", "current_catalog", "current_role",
                "current_time", "current_user", "deferrable", "foreign", "grant", "initially", "leading",
                "localtime", "localtimestamp", "placing", "references", "session_user", "system_user", "trailing",
                "unique", "user", "variadic", "authorization", "binary", "collation", "concurrently", "current_schema",
                "freeze", "isnull", "notnull", "overlaps", "similar", "tablesample", "verbose",
            };
            for (words) |word| if (types.keyword(raw, word)) return true;
            return false;
        }

        /// UPDATE / DELETE target alias: AS label, or a bare identifier that
        /// is not a PostgreSQL reserved word.
        fn targetAlias(self: *Self) Error!?ast.Ident {
            if (try self.takeWord("AS")) return try self.label();
            if (self.current.kind == .quoted_word) return try self.identifier();
            if (self.current.kind == .word and !lexer.reserved(self.current.keyword) and !reservedWord(self.current.raw(self.source))) return try self.identifier();
            return null;
        }

        /// A FROM / USING list parsed into its own query block.
        fn fromBlock(self: *Self) Error!u16 {
            const block = try self.pool.newQuery();
            try self.fromList(&self.pool.queries[block]);
            self.pool.queries[block].targets[0] = .{ .star = true };
            self.pool.queries[block].count = 1;
            return block;
        }

        fn update(self: *Self) Error!Ast.Update {
            const only = self.mode == .standard and try self.takeWord("ONLY");
            var out: Ast.Update = .{ .table = try self.identifier(), .only = only };
            if (self.mode == .standard and try self.takeSymbol(.dot)) {
                out.schema = out.table;
                out.table = try self.identifier();
            }
            if (self.mode == .standard) out.alias = try self.targetAlias();
            try self.expectWord("SET");
            while (true) {
                try self.setItem(&out.assignments, &out.count);
                if (!try self.takeSymbol(.comma)) break;
            }
            if (self.mode == .standard and try self.takeWord("FROM")) out.from = try self.fromBlock();
            out.where = try self.where();
            try self.returningClause(&out.returning);
            try self.finish();
            return out;
        }

        fn delete(self: *Self) Error!Ast.Delete {
            try self.expectWord("FROM");
            const only = self.mode == .standard and try self.takeWord("ONLY");
            var out: Ast.Delete = .{ .table = try self.identifier(), .only = only };
            if (self.mode == .standard and try self.takeSymbol(.dot)) {
                out.schema = out.table;
                out.table = try self.identifier();
            }
            if (self.mode == .standard) out.alias = try self.targetAlias();
            if (self.mode == .standard and try self.takeWord("USING")) out.using = try self.fromBlock();
            out.where = try self.where();
            try self.returningClause(&out.returning);
            try self.finish();
            return out;
        }

        // ---- expressions ------------------------------------------------

        /// A token that cannot continue an expression after a bare column.
        /// A type name that continues past its first word (or into a
        /// modifier) before a typed literal: DOUBLE PRECISION, TIMESTAMP/TIME
        /// WITH[OUT] TIME ZONE, CHARACTER VARYING, NUMERIC(p,s), ...
        fn multiwordType(token: Token, after: Token) bool {
            const lparen = after.kind == .symbol and after.symbol == .lparen;
            return (token.isWord("DOUBLE") and after.isWord("PRECISION")) or
                ((token.isWord("TIMESTAMP") or token.isWord("TIME")) and (after.isWord("WITH") or after.isWord("WITHOUT"))) or
                ((token.isWord("CHARACTER") or token.isWord("CHAR") or token.isWord("BIT")) and after.isWord("VARYING")) or
                (lparen and (token.isWord("NUMERIC") or token.isWord("DECIMAL") or token.isWord("TIMESTAMP") or token.isWord("TIMESTAMPTZ") or
                token.isWord("TIME") or token.isWord("TIMETZ") or token.isWord("VARCHAR") or token.isWord("CHARACTER") or token.isWord("CHAR") or token.isWord("BPCHAR") or
                token.isWord("BIT") or token.isWord("VARBIT")));
        }

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
                const after = try self.peek();
                if (ends(after) and !(typeWord(self.current) and multiwordType(self.current, after))) {
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
                if (try self.takeWord("DISTINCT")) {
                    try self.expectWord("FROM");
                    const right = try self.comparison();
                    left = try self.pool.add(.{ .kind = .binary, .op = if (negated) .is_not_distinct else .is_distinct, .a = left, .b = right });
                    continue;
                }
                if (self.mode == .standard and (self.rawWord("normalized") or self.rawWord("nfc") or self.rawWord("nfd") or self.rawWord("nfkc") or self.rawWord("nfkd"))) {
                    left = try self.normalizedTail(left, negated);
                    continue;
                }
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
            var left = try self.pattern();
            while (self.comparisonOp()) |op| {
                try self.advance();
                if (self.mode == .standard and (self.isWord("ANY") or self.isWord("SOME") or self.isWord("ALL"))) {
                    const all = self.isWord("ALL");
                    try self.advance();
                    try self.expectSymbol(.lparen);
                    if (!self.isWord("SELECT") and !self.isWord("WITH") and !self.isSymbol(.lparen)) {
                        // `x op ANY/ALL (array)`: an array_any call over
                        // (x, array), with in_subquery's op/negated encoding.
                        const array = try self.expression();
                        try self.expectSymbol(.rparen);
                        const any = try self.pool.add(.{ .kind = .function, .func = .array_any, .op = if (all) oppositeComparison(op) else op, .negated = all, .b = left });
                        self.pool.nodes[left].next = array;
                        try self.pool.raise(any, left);
                        try self.pool.raise(any, array);
                        left = try self.castTail(any);
                        left = try self.atZoneTail(left);
                        left = try self.multiplicativeTail(left);
                        left = try self.additiveTail(left);
                        left = try self.otherTail(left);
                        left = try self.patternTail(left);
                        continue;
                    }
                    const inner = try self.query();
                    try self.expectSymbol(.rparen);
                    self.pool.complex = true;
                    // SQL three-valued De Morgan duality preserves NULL and
                    // empty-set semantics without a new AST storage field.
                    left = try self.pool.add(.{ .kind = .in_subquery, .op = if (all) oppositeComparison(op) else op, .negated = all, .a = left, .integer = inner });
                    // A completed sublink can itself be a higher-precedence
                    // operand: x=ANY(...)::text || 'suffix', or ... = TRUE.
                    left = try self.castTail(left);
                    left = try self.atZoneTail(left);
                    left = try self.multiplicativeTail(left);
                    left = try self.additiveTail(left);
                    left = try self.otherTail(left);
                    left = try self.patternTail(left);
                    continue;
                }
                const right = try self.pattern();
                // Ordinary comparisons are non-associative in PostgreSQL.
                if (self.comparisonOp() != null) return error.Syntax;
                return self.pool.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
            }
            return left;
        }

        fn oppositeComparison(op: ast.Op) ast.Op {
            return switch (op) {
                .eq => .ne, .ne => .eq, .lt => .ge,
                .le => .gt, .gt => .le, .ge => .lt,
                else => unreachable,
            };
        }

        fn lparenNext(token: Token) bool {
            return token.kind == .symbol and token.symbol == .lparen;
        }

        fn patternKeyword(token: Token) bool {
            return token.isWord("IN") or token.isWord("LIKE") or token.isWord("ILIKE") or token.isWord("BETWEEN");
        }

        fn pattern(self: *Self) Error!u16 {
            const left = try self.other();
            return self.patternTail(left);
        }

        fn patternTail(self: *Self, left: u16) Error!u16 {
            var negated = false;
            if (self.isWord("NOT") and patternKeyword(try self.peek())) {
                try self.advance();
                negated = true;
            }
            if (try self.takeWord("BETWEEN")) {
                const symmetric = try self.takeWord("SYMMETRIC");
                if (!symmetric) _ = try self.takeWord("ASYMMETRIC");
                const low = try self.other();
                try self.expectWord("AND");
                const high = try self.other();
                return self.pool.add(.{ .kind = .between, .negated = negated, .symmetric = symmetric, .a = left, .b = low, .c = high });
            }
            if (try self.takeWord("IN")) {
                try self.expectSymbol(.lparen);
                if (self.mode == .standard and (self.isWord("SELECT") or self.isWord("WITH"))) {
                    const inner = try self.query();
                    try self.expectSymbol(.rparen);
                    self.pool.complex = true;
                    return self.pool.add(.{ .kind = .in_subquery, .op = .eq, .negated = negated, .a = left, .integer = inner });
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
                const escape_node = if (try self.takeRaw("escape")) try self.other() else none;
                return self.pool.add(.{ .kind = .like, .negated = negated, .insensitive = insensitive, .a = left, .b = pattern_node, .c = escape_node });
            }
            return left;
        }

        fn other(self: *Self) Error!u16 {
            return self.otherTail(try self.additive());
        }

        fn otherTail(self: *Self, initial: u16) Error!u16 {
            var left = initial;
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
                    .ampersand => .bit_and,
                    .pipe => .bit_or,
                    .hash => .bit_xor,
                    .shift_left => .shift_left,
                    .shift_right => .shift_right,
                    .overlap => .overlap,
                    .over_left => .over_left,
                    .over_right => .over_right,
                    .adjacent => .adjacent,
                    .within_eq => .within_eq,
                    .contains_eq => .contains_eq,
                    .distance => .distance,
                    .same => .same,
                    else => break,
                };
                try self.advance();
                const right = try self.additive();
                left = try self.pool.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
            }
            return left;
        }

        fn additive(self: *Self) Error!u16 {
            return self.additiveTail(try self.multiplicative());
        }

        fn additiveTail(self: *Self, initial: u16) Error!u16 {
            var left = initial;
            while (self.isSymbol(.plus) or self.isSymbol(.minus)) {
                const op: ast.Op = if (self.isSymbol(.plus)) .add else .sub;
                try self.advance();
                const right = try self.multiplicative();
                left = try self.pool.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
            }
            return left;
        }

        fn multiplicative(self: *Self) Error!u16 {
            return self.multiplicativeTail(try self.atZone());
        }

        fn multiplicativeTail(self: *Self, initial: u16) Error!u16 {
            var left = initial;
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
            return self.atZoneTail(try self.unary());
        }

        fn atZoneTail(self: *Self, initial: u16) Error!u16 {
            var left = initial;
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
            if (self.mode == .standard and self.isSymbol(.tilde)) {
                // Prefix operators bind like PostgreSQL's generic Op: `~1+2`
                // is ~(1+2), while `~1||x` applies ~ first.
                try self.enter();
                defer self.leave();
                try self.advance();
                const operand = try self.additive();
                return self.pool.add(.{ .kind = .unary, .op = .bit_not, .a = operand });
            }
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
            return self.castTail(try self.primary());
        }

        fn castTail(self: *Self, initial: u16) Error!u16 {
            var node = initial;
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
            for ([_][]const u8{ "count", "sum", "avg", "min", "max", "bool_and", "bool_or", "every",
                "stddev", "stddev_pop", "stddev_samp", "variance", "var_pop", "var_samp", "corr", "covar_pop", "covar_samp",
                "regr_count", "regr_sxx", "regr_syy", "regr_sxy", "regr_avgx", "regr_avgy", "regr_slope", "regr_intercept",
                "regr_r2", "bit_and", "bit_or", "bit_xor" }) |word| {
                if (types.keyword(raw, word)) return true;
            }
            return false;
        }

        /// name(args) with `*`, DISTINCT/ALL and FILTER (WHERE ...) for aggregates.
        fn functionCall(self: *Self, name: ast.Ident) Error!u16 {
            try self.expectSymbol(.lparen);
            // Volatile sequence functions run on the general engine, which
            // evaluates every projection exactly once per row.
            const raw_name = name.span.slice(self.source);
            if (!name.quoted and (types.keyword(raw_name, "nextval") or types.keyword(raw_name, "setval"))) self.pool.complex = true;
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
            if(self.mode==.standard and try self.takeWord("OVER")) {
                self.pool.complex=true;
                self.pool.nodes[node].window=try self.windowSpec(node,true);
            }
            const n = &self.pool.nodes[node];
            if (n.distinct or n.c != none or self.aggregateName(name)) self.pool.complex = true;
            return node;
        }

        fn windowSpec(self:*Self,owner:u16,allow_bare:bool) Error!u16 {
            if(self.pool.window_len==self.pool.windows.len) return error.StatementTooComplex;
            const index=self.pool.window_len;self.pool.window_len+=1;
            self.pool.windows[index]=.{};const spec=&self.pool.windows[index];
            if(allow_bare and !self.isSymbol(.lparen)) {
                spec.base=try self.identifier();spec.direct=true;return @intCast(index);
            }
            try self.expectSymbol(.lparen);
            if((self.current.kind==.word or self.current.kind==.quoted_word) and !self.isWord("PARTITION") and !self.isWord("ORDER") and !self.isWord("ROWS") and !self.isWord("RANGE") and !self.isWord("GROUPS")) spec.base=try self.identifier();
                if(try self.takeWord("PARTITION")) {
                    try self.expectWord("BY");
                    while(true) {
                        if(spec.partition_count==config.columns) return error.ColumnCapacity;
                        const item=try self.expression();try self.pool.raise(owner,item);
                        spec.partition[spec.partition_count]=item;spec.partition_origin[spec.partition_count]=item;spec.partition_count+=1;
                        if(!try self.takeSymbol(.comma)) break;
                    }
                }
                if(try self.takeWord("ORDER")) {
                    try self.expectWord("BY");
                    while(true) {
                        if(spec.order_count==config.columns) return error.ColumnCapacity;
                        const item=try self.expression();try self.pool.raise(owner,item);
                        var key:Ast.OrderKey=.{.expr=item};
                        if(try self.takeWord("DESC")) key.descending=true else _=try self.takeWord("ASC");
                        if(try self.takeWord("NULLS")) {
                            if(try self.takeWord("FIRST")) key.nulls_first=true else {try self.expectWord("LAST");key.nulls_first=false;}
                        }
                        spec.order[spec.order_count]=key;spec.order_origin[spec.order_count]=item;spec.order_count+=1;
                        if(!try self.takeSymbol(.comma)) break;
                    }
                }
                if(self.isWord("ROWS") or self.isWord("GROUPS") or self.isWord("RANGE")) {
                    spec.framed=true;spec.frame=if(self.isWord("ROWS")) .rows else if(self.isWord("GROUPS")) .groups else .range;
                    try self.advance();const between=try self.takeWord("BETWEEN");
                    spec.start=try self.frameBound(owner);
                    if(between) {try self.expectWord("AND");spec.end=try self.frameBound(owner);}
                    if(spec.start.kind==.unbounded_following or spec.end.kind==.unbounded_preceding or @intFromEnum(spec.end.kind)<@intFromEnum(spec.start.kind)) return error.WindowingError;
                    if(try self.takeWord("EXCLUDE")) {
                        if(try self.takeWord("CURRENT")){try self.expectWord("ROW");spec.exclude=.current_row;}
                        else if(try self.takeWord("GROUP")) spec.exclude=.group
                        else if(try self.takeWord("TIES")) spec.exclude=.ties
                        else {try self.expectWord("NO");try self.expectWord("OTHERS");}
                    }
                }
            try self.expectSymbol(.rparen);return @intCast(index);
        }

        fn frameBound(self:*Self,owner:u16) Error!Ast.FrameBound {
            if(try self.takeWord("UNBOUNDED")) {
                if(try self.takeWord("PRECEDING")) return .{.kind=.unbounded_preceding};
                try self.expectWord("FOLLOWING");return .{.kind=.unbounded_following};
            }
            if(try self.takeWord("CURRENT")){try self.expectWord("ROW");return .{.kind=.current_row};}
            const offset=try self.expression();try self.pool.raise(owner,offset);
            if(try self.takeWord("PRECEDING")) return .{.kind=.preceding,.offset=offset};
            try self.expectWord("FOLLOWING");return .{.kind=.following,.offset=offset};
        }

        /// unicode_normal_form: NFC, NFD, NFKC or NFKD as a text literal.
        fn normalForm(self: *Self) Error!u16 {
            const token = self.current;
            if (!(self.rawWord("nfc") or self.rawWord("nfd") or self.rawWord("nfkc") or self.rawWord("nfkd"))) return error.Syntax;
            try self.advance();
            return self.pool.add(.{ .kind = .text_literal, .text = .{ .start = token.start, .end = token.end, .len = token.len } });
        }

        /// `x IS [NOT] [form] NORMALIZED` (is_normalized), after IS [NOT].
        fn normalizedTail(self: *Self, left: u16, negated: bool) Error!u16 {
            var list: ArgList = .{};
            list.push(self.pool, left);
            if (!self.rawWord("normalized")) list.push(self.pool, try self.normalForm());
            const token = self.current;
            if (!self.rawWord("normalized")) return error.Syntax;
            try self.advance();
            const name: ast.Ident = .{ .span = .{ .start = token.start, .len = token.len }, .len = token.len };
            const call = try self.callNode(name, .is_normalized, list);
            return if (negated) try self.pool.add(.{ .kind = .not_op, .a = call }) else call;
        }

        /// `row OVERLAPS row` (gram.y): both rows need exactly two members
        /// (42601); the call is overlaps(a, b, c, d).
        fn overlapsTail(self: *Self, left: u16) Error!u16 {
            if (self.mode != .standard or !self.rawWord("overlaps")) return left;
            const token = self.current;
            try self.advance();
            var right: u16 = none;
            if (self.isWord("ROW") and lparenNext(try self.peek())) {
                try self.advance();
                if ((try self.peek()).kind == .symbol and (try self.peek()).symbol == .rparen) return error.Syntax;
                right = try self.arguments(.row_constructor, false);
            } else {
                try self.expectSymbol(.lparen);
                const first = try self.expression();
                if (!self.isSymbol(.comma)) return error.Syntax;
                right = try self.pool.add(.{ .kind = .row_constructor, .b = first });
                var last = first;
                while (try self.takeSymbol(.comma)) {
                    const item = try self.expression();
                    self.pool.nodes[last].next = item;
                    try self.pool.raise(right, item);
                    last = item;
                }
                try self.expectSymbol(.rparen);
            }
            var list: ArgList = .{};
            var count: usize = 0;
            for ([_]u16{ left, right }) |row| {
                var members: usize = 0;
                var item = self.pool.nodes[row].b;
                while (item != none) {
                    const next = self.pool.nodes[item].next;
                    self.pool.nodes[item].next = none;
                    list.push(self.pool, item);
                    members += 1;
                    item = next;
                }
                if (members != 2) return error.Syntax;
                count += members;
            }
            const name: ast.Ident = .{ .span = .{ .start = token.start, .len = token.len }, .len = token.len };
            return try self.callNode(name, .overlaps, list);
        }

        /// A function argument list under construction (`next`-linked).
        const ArgList = struct {
            head: u16 = none,
            tail: u16 = none,

            fn push(list: *ArgList, pool: *Ast.Pool, item: u16) void {
                if (list.head == none) list.head = item else pool.nodes[list.tail].next = item;
                list.tail = item;
            }
        };

        fn callNode(self: *Self, name: ast.Ident, func: ast.Func, list: ArgList) Error!u16 {
            const node = try self.pool.add(.{ .kind = .function, .name = name, .func = func, .b = list.head });
            var item = list.head;
            while (item != none) : (item = self.pool.nodes[item].next) try self.pool.raise(node, item);
            return node;
        }

        fn expressionList(self: *Self, list: *ArgList) Error!void {
            list.push(self.pool, try self.expression());
            while (try self.takeSymbol(.comma)) list.push(self.pool, try self.expression());
        }

        /// SQL-syntax functions of gram.y func_expr_common_subexpr: TRIM,
        /// SUBSTRING, POSITION and OVERLAY, plus LEFT/RIGHT (reserved join
        /// words that also name functions). The current word precedes `(`.
        fn specialFunction(self: *Self) Error!?u16 {
            const token = self.current;
            const name: ast.Ident = .{ .span = .{ .start = token.start, .len = token.len }, .len = token.len };
            if (token.isWord("LEFT") or token.isWord("RIGHT")) {
                try self.advance();
                return try self.functionCall(name);
            }
            const Form = enum { trim, substring, position, overlay, extract, normalize };
            const form: Form = if (wordIs(self.source, token, "trim")) .trim else if (wordIs(self.source, token, "substring")) .substring else if (wordIs(self.source, token, "position")) .position else if (wordIs(self.source, token, "overlay")) .overlay else if (wordIs(self.source, token, "extract")) .extract else if (wordIs(self.source, token, "normalize")) .normalize else return null;
            try self.advance();
            try self.advance();
            try self.enter();
            defer self.leave();
            var list: ArgList = .{};
            var func: ast.Func = .none;
            switch (form) {
                .trim => {
                    func = .btrim;
                    if (try self.takeRaw("both")) {} else if (try self.takeRaw("leading")) {
                        func = .ltrim;
                    } else if (try self.takeRaw("trailing")) func = .rtrim;
                    // trim_list: a_expr FROM expr_list | FROM expr_list | expr_list.
                    if (try self.takeWord("FROM")) {
                        try self.expressionList(&list);
                    } else {
                        const first = try self.expression();
                        if (try self.takeWord("FROM")) {
                            try self.expressionList(&list);
                            list.push(self.pool, first);
                        } else {
                            list.push(self.pool, first);
                            while (try self.takeSymbol(.comma)) list.push(self.pool, try self.expression());
                        }
                    }
                },
                .substring => if (!self.isSymbol(.rparen)) {
                    list.push(self.pool, try self.expression());
                    if (try self.takeWord("FROM")) {
                        const start = try self.expression();
                        list.push(self.pool, start);
                        if (try self.takeWord("FOR")) list.push(self.pool, try self.expression());
                    } else if (try self.takeWord("FOR")) {
                        // substring(x FOR n) is substring(x, 1, n::int4); FROM may follow.
                        const count = try self.expression();
                        if (try self.takeWord("FROM")) {
                            list.push(self.pool, try self.expression());
                            list.push(self.pool, count);
                        } else {
                            list.push(self.pool, try self.pool.add(.{ .kind = .int_literal, .integer = 1 }));
                            list.push(self.pool, try self.pool.add(.{ .kind = .cast, .cast_type = .int4, .a = count }));
                        }
                    } else while (try self.takeSymbol(.comma)) list.push(self.pool, try self.expression());
                },
                .position => if (!self.isSymbol(.rparen)) {
                    func = .strpos;
                    const needle = try self.other();
                    try self.expectWord("IN");
                    list.push(self.pool, try self.other());
                    list.push(self.pool, needle);
                },
                .extract => if (!self.isSymbol(.rparen)) {
                    // extract_arg: an identifier, keyword or string constant,
                    // passed to extract(text, source) as a text literal.
                    const field = self.current;
                    const literal: lexer.Quoted = switch (field.kind) {
                        .string => field.quoted(),
                        .word, .quoted_word => blk: {
                            if (field.kind == .word and lexer.reserved(field.keyword)) return error.Syntax;
                            break :blk .{ .start = field.start, .end = field.end, .len = field.end - field.start };
                        },
                        else => return error.Syntax,
                    };
                    try self.advance();
                    list.push(self.pool, try self.pool.add(.{ .kind = .text_literal, .text = literal }));
                    try self.expectWord("FROM");
                    list.push(self.pool, try self.expression());
                },
                .normalize => if (!self.isSymbol(.rparen)) {
                    // NORMALIZE(a [, NFC|NFD|NFKC|NFKD]): the form is a keyword.
                    list.push(self.pool, try self.expression());
                    if (try self.takeSymbol(.comma)) list.push(self.pool, try self.normalForm());
                },
                .overlay => if (!self.isSymbol(.rparen)) {
                    list.push(self.pool, try self.expression());
                    if (try self.takeRaw("placing")) {
                        list.push(self.pool, try self.expression());
                        try self.expectWord("FROM");
                        list.push(self.pool, try self.expression());
                        if (try self.takeWord("FOR")) list.push(self.pool, try self.expression());
                    } else while (try self.takeSymbol(.comma)) list.push(self.pool, try self.expression());
                },
            }
            try self.expectSymbol(.rparen);
            return try self.callNode(name, func, list);
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
                    if (self.mode == .standard and try self.takeSymbol(.comma)) {
                        const row = try self.pool.add(.{ .kind = .row_constructor, .b = inner });
                        var last = inner;
                        while (true) {
                            const item = try self.expression();
                            self.pool.nodes[last].next = item;
                            try self.pool.raise(row, item);
                            last = item;
                            if (!try self.takeSymbol(.comma)) break;
                        }
                        try self.expectSymbol(.rparen);
                        return self.overlapsTail(row);
                    }
                    try self.expectSymbol(.rparen);
                    return self.subscriptTail(inner);
                },
                .end => return error.Syntax,
                .word, .quoted_word => {},
            }
            if (token.kind == .word) {
                if (try self.takeWord("NULL")) return self.pool.add(.{ .kind = .null_literal });
                if (try self.takeWord("TRUE")) return self.pool.add(.{ .kind = .bool_literal, .boolean = true });
                if (try self.takeWord("FALSE")) return self.pool.add(.{ .kind = .bool_literal, .boolean = false });
                if (try self.takeWord("CASE")) return self.caseExpr();
                if (self.mode == .standard and self.isWord("ROW") and lparenNext(try self.peek())) {
                    try self.advance();
                    const after = try self.peek();
                    if (after.kind == .symbol and after.symbol == .rparen) {
                        try self.advance();
                        try self.advance();
                        return self.overlapsTail(try self.pool.add(.{ .kind = .row_constructor }));
                    }
                    return self.overlapsTail(try self.arguments(.row_constructor, false));
                }
                if (try self.takeWord("CAST")) {
                    try self.expectSymbol(.lparen);
                    const inner = try self.expression();
                    try self.expectWord("AS");
                    const target = try self.typeName();
                    try self.expectSymbol(.rparen);
                    return self.pool.add(.{ .kind = .cast, .cast_type = target.ty, .typmod = target.typmod, .a = inner });
                }
                // Bit-string constant B'...' (the quote follows the B directly):
                // BIT without a typmod, read by bit_in.
                if (token.len == 1 and wordIs(self.source, token, "b")) {
                    const after = try self.peek();
                    if (after.kind == .string and after.start == token.end + 1) {
                        try self.advance();
                        const literal = self.current;
                        try self.advance();
                        const inner = try self.pool.add(.{ .kind = .text_literal, .text = literal.quoted() });
                        return self.pool.add(.{ .kind = .cast, .cast_type = .bit, .typmod = -1, .a = inner });
                    }
                }
                // Typed literal: DATE '...', TIMESTAMP [WITH TIME ZONE] '...', ...
                if (typeWord(token)) {
                    const after = try self.peek();
                    if (after.kind == .string or multiwordType(token, after)) {
                        const target = try self.typeName();
                        if (self.current.kind != .string) return error.Syntax;
                        const literal = self.current;
                        try self.advance();
                        const inner = try self.pool.add(.{ .kind = .text_literal, .text = literal.quoted() });
                        return self.pool.add(.{ .kind = .cast, .cast_type = target.ty, .typmod = target.typmod, .a = inner });
                    }
                }
                // XMLPARSE({DOCUMENT|CONTENT} expr [{PRESERVE|STRIP} WHITESPACE])
                // and XMLSERIALIZE({DOCUMENT|CONTENT} expr AS type).
                if (self.mode == .standard and (wordIs(self.source, token, "xmlparse") or wordIs(self.source, token, "xmlserialize")) and lparenNext(try self.peek())) {
                    const serialize = wordIs(self.source, token, "xmlserialize");
                    const name = try self.identifier();
                    try self.expectSymbol(.lparen);
                    var document = false;
                    if (try self.takeRaw("document")) {
                        document = true;
                    } else if (!try self.takeRaw("content")) return error.Syntax;
                    const argument = try self.expression();
                    var call: ast.Node = .{ .kind = .function, .func = if (serialize) .xmlserialize else .xmlparse, .name = name, .b = argument, .integer = @intFromBool(document) };
                    if (serialize) {
                        try self.expectWord("AS");
                        const target = try self.typeName();
                        call.cast_type = target.ty;
                        call.typmod = target.typmod;
                        if ((try self.takeRaw("indent")) or (try self.takeRaw("no"))) return error.UnsupportedStatement;
                    } else if ((try self.takeRaw("preserve")) or (try self.takeRaw("strip"))) {
                        if (!try self.takeRaw("whitespace")) return error.Syntax;
                    }
                    try self.expectSymbol(.rparen);
                    return self.pool.add(call);
                }
                // ARRAY[...] constructors.
                if (self.mode == .standard and wordIs(self.source, token, "array")) {
                    const after = try self.peek();
                    if (after.kind == .symbol and after.symbol == .lbracket) {
                        const name = try self.identifier();
                        return self.arrayConstructor(name);
                    }
                }
                // SQL-standard niladic functions.
                if (wordIs(self.source, token, "current_timestamp") or wordIs(self.source, token, "current_date")) {
                    const name = try self.identifier();
                    return self.pool.add(.{ .kind = .function, .name = name });
                }
                if (self.mode == .standard and lparenNext(try self.peek())) {
                    if (try self.specialFunction()) |id| return id;
                }
                if ((self.isWord("GREATEST") or self.isWord("LEAST")) and lparenNext(try self.peek())) {
                    const func: ast.Func = if (self.isWord("GREATEST")) .greatest else .least;
                    const name = try self.identifier();
                    const id = try self.arguments(.function, false);
                    self.pool.nodes[id].func = func;
                    self.pool.nodes[id].name = name;
                    return id;
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
                return self.subscriptTail(try self.pool.add(.{ .kind = .column, .name = column, .qualifier = name }));
            }
            return self.subscriptTail(try self.pool.add(.{ .kind = .column, .name = name }));
        }

        /// `[elem, ...]` after ARRAY (and nested `[...]` sub-arrays): an
        /// array_constructor call named `array`.
        fn arrayConstructor(self: *Self, name: ast.Ident) Error!u16 {
            try self.enter();
            defer self.leave();
            try self.expectSymbol(.lbracket);
            const node = try self.pool.add(.{ .kind = .function, .func = .array_constructor, .name = name });
            if (try self.takeSymbol(.rbracket)) return node;
            var last: u16 = none;
            while (true) {
                const item = if (self.isSymbol(.lbracket)) try self.arrayConstructor(name) else try self.expression();
                if (last == none) self.pool.nodes[node].b = item else self.pool.nodes[last].next = item;
                try self.pool.raise(node, item);
                last = item;
                if (!try self.takeSymbol(.comma)) break;
            }
            try self.expectSymbol(.rbracket);
            return node;
        }

        /// `base[i]`, `base[lo:hi]` (either bound optional), repeated: one
        /// array_subscript call over every subscript (array.Subscripts).
        fn subscriptTail(self: *Self, base: u16) Error!u16 {
            if (self.mode != .standard or !self.isSymbol(.lbracket)) return base;
            const node = try self.pool.add(.{ .kind = .function, .func = .array_subscript, .b = base, .name = self.pool.nodes[base].name });
            var layout: array_module.Subscripts = .{};
            var last = base;
            while (try self.takeSymbol(.lbracket)) {
                if (layout.count == array_module.max_dims) return error.ProgramLimitExceeded;
                var flag: u3 = 0;
                var bounds: [2]u16 = .{ none, none };
                if (!self.isSymbol(.colon)) {
                    bounds[0] = try self.expression();
                    flag |= array_module.Subscripts.lower_flag;
                }
                if (try self.takeSymbol(.colon)) {
                    flag |= array_module.Subscripts.slice_flag;
                    if (!self.isSymbol(.rbracket)) {
                        bounds[1] = try self.expression();
                        flag |= array_module.Subscripts.upper_flag;
                    }
                } else if (bounds[0] == none) return error.Syntax;
                try self.expectSymbol(.rbracket);
                for (bounds) |bound| if (bound != none) {
                    self.pool.nodes[last].next = bound;
                    try self.pool.raise(node, bound);
                    last = bound;
                };
                layout.flags[layout.count] = flag;
                layout.count += 1;
            }
            try self.pool.raise(node, base);
            self.pool.nodes[node].integer = layout.encode();
            return node;
        }
    };
}
