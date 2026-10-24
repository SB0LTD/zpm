//! Frozen alpha-grammar recognizer (Layer 0), used only by `legacy_alpha`
//! replay of kind 1/2 SQL-text WAL records. It accepts exactly the grammar the
//! alpha releases executed and must never grow with the main grammar:
//! CREATE/DROP TABLE; single-row INSERT [column list] VALUES literals;
//! SELECT */columns FROM t [WHERE column op literal AND ...] [ORDER BY c
//! [ASC|DESC] [NULLS FIRST|LAST]] [LIMIT n]; UPDATE t SET c = literal, ...
//! [WHERE]; DELETE FROM t [WHERE]. Accepted statements are then executed by
//! the standard pipeline, whose grammar is a superset.
const types = @import("types.sig");
const lexer_module = @import("lexer.sig");
const Error = types.Error;
const Lexer = lexer_module.Lexer;

const reserved = [_][]const u8{ "CREATE", "DROP", "INSERT", "SELECT", "UPDATE", "DELETE", "TABLE", "INTO", "VALUES", "FROM", "WHERE", "AND", "OR", "SET", "ORDER", "BY", "ASC", "DESC", "LIMIT", "IS", "NOT", "NULL", "TRUE", "FALSE", "PRIMARY", "KEY" };

pub fn Recognizer(comptime config: types.Config) type {
    return struct {
        const Self = @This();
        lex: Lexer,

        pub fn check(source: []const u8) Error!void {
            var self = Self{ .lex = .{ .source = source } };
            return self.statement();
        }

        fn statement(self: *Self) Error!void {
            if (self.lex.takeWord("CREATE")) return self.create();
            if (self.lex.takeWord("DROP")) {
                try self.lex.expectWord("TABLE");
                try self.identifier();
                return self.lex.finish();
            }
            if (self.lex.takeWord("INSERT")) return self.insert();
            if (self.lex.takeWord("SELECT")) return self.select();
            if (self.lex.takeWord("UPDATE")) return self.update();
            if (self.lex.takeWord("DELETE")) return self.delete();
            return error.UnsupportedStatement;
        }

        fn identifier(self: *Self) Error!void {
            const source = self.lex.word();
            if (source.len == 0) return error.Syntax;
            for (reserved) |word| if (types.keyword(source, word)) return error.Syntax;
            if (source.len > config.name_bytes) return error.NameCapacity;
        }

        fn literalValue(self: *Self) Error!void {
            if (self.lex.takeWord("NULL") or self.lex.takeWord("TRUE") or self.lex.takeWord("FALSE")) return;
            if (self.lex.take('\'')) {
                _ = try self.lex.quoted(config.text_bytes);
                return;
            }
            const negative = self.lex.take('-');
            _ = try self.lex.unsigned(if (negative) 9223372036854775808 else 9223372036854775807);
        }

        fn create(self: *Self) Error!void {
            try self.lex.expectWord("TABLE");
            try self.identifier();
            try self.lex.expect('(');
            var count: usize = 0;
            var has_primary = false;
            while (true) {
                if (count == config.columns) return error.ColumnCapacity;
                try self.identifier();
                if (!(self.lex.takeWord("INTEGER") or self.lex.takeWord("INT") or self.lex.takeWord("BIGINT") or
                    self.lex.takeWord("INT8") or self.lex.takeWord("BOOLEAN") or self.lex.takeWord("BOOL") or
                    self.lex.takeWord("TEXT"))) return error.Syntax;
                var has_not_null = false;
                while (true) {
                    if (self.lex.takeWord("NOT")) {
                        if (has_not_null) return error.Syntax;
                        try self.lex.expectWord("NULL");
                        has_not_null = true;
                    } else if (self.lex.takeWord("PRIMARY")) {
                        if (has_primary) return error.Syntax;
                        try self.lex.expectWord("KEY");
                        has_primary = true;
                    } else break;
                }
                count += 1;
                if (!self.lex.take(',')) break;
            }
            try self.lex.expect(')');
            try self.lex.finish();
        }

        fn insert(self: *Self) Error!void {
            try self.lex.expectWord("INTO");
            try self.identifier();
            if (self.lex.take('(')) {
                var count: usize = 0;
                while (true) {
                    if (count == config.columns) return error.ColumnCapacity;
                    try self.identifier();
                    count += 1;
                    if (!self.lex.take(',')) break;
                }
                try self.lex.expect(')');
            }
            try self.lex.expectWord("VALUES");
            try self.lex.expect('(');
            var values: usize = 0;
            while (true) {
                if (values == config.columns) return error.Syntax;
                try self.literalValue();
                values += 1;
                if (!self.lex.take(',')) break;
            }
            try self.lex.expect(')');
            try self.lex.finish();
        }

        fn predicate(self: *Self) Error!void {
            try self.identifier();
            if (self.lex.takeWord("IS")) {
                _ = self.lex.takeWord("NOT");
                return self.lex.expectWord("NULL");
            }
            if (self.lex.take('=')) {} else if (self.lex.take('!')) {
                try self.lex.expect('=');
            } else if (self.lex.take('<')) {
                _ = self.lex.take('=') or self.lex.take('>');
            } else if (self.lex.take('>')) {
                _ = self.lex.take('=');
            } else return error.Syntax;
            try self.literalValue();
        }

        fn where(self: *Self) Error!void {
            if (!self.lex.takeWord("WHERE")) return;
            var count: usize = 0;
            while (true) {
                if (count == config.predicates) return error.PredicateCapacity;
                try self.predicate();
                count += 1;
                if (!self.lex.takeWord("AND")) break;
            }
        }

        fn select(self: *Self) Error!void {
            if (!self.lex.take('*')) {
                var count: usize = 0;
                while (true) {
                    if (count == config.columns) return error.ColumnCapacity;
                    try self.identifier();
                    count += 1;
                    if (!self.lex.take(',')) break;
                }
            }
            try self.lex.expectWord("FROM");
            try self.identifier();
            try self.where();
            if (self.lex.takeWord("ORDER")) {
                try self.lex.expectWord("BY");
                try self.identifier();
                if (!self.lex.takeWord("DESC")) _ = self.lex.takeWord("ASC");
                if (self.lex.takeWord("NULLS")) {
                    if (!self.lex.takeWord("FIRST") and !self.lex.takeWord("LAST")) return error.Syntax;
                }
            }
            if (self.lex.takeWord("LIMIT")) _ = try self.lex.unsigned(18446744073709551615);
            try self.lex.finish();
        }

        fn update(self: *Self) Error!void {
            try self.identifier();
            try self.lex.expectWord("SET");
            var count: usize = 0;
            while (true) {
                if (count == config.columns) return error.DuplicateColumn;
                try self.identifier();
                try self.lex.expect('=');
                try self.literalValue();
                count += 1;
                if (!self.lex.take(',')) break;
            }
            try self.where();
            try self.lex.finish();
        }

        fn delete(self: *Self) Error!void {
            try self.lex.expectWord("FROM");
            try self.identifier();
            try self.where();
            try self.lex.finish();
        }
    };
}
