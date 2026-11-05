//! Routine statements and the bounded PL/pgSQL interpreter (Layer 0,
//! conformance lane B11 wave 3, docs/SQL_ROUTINES.md).
//!
//! Statements: CREATE [OR REPLACE] FUNCTION / PROCEDURE, DROP FUNCTION /
//! PROCEDURE, CALL, DO, CREATE [OR REPLACE] TRIGGER, DROP TRIGGER, CREATE
//! [OR REPLACE] RULE ... DO [ALSO | INSTEAD] NOTHING and DROP RULE. They are
//! recognized by their leading words (classify) and parsed here into
//! definitions with decoded names and texts; the Database executes them.
//!
//! PL/pgSQL runs straight from the body text: statements are scanned with
//! the SQL tokenizer and every expression is parsed, bound and evaluated
//! at the top of the statement's node pool, which is restored afterwards
//! (Host.routineEvaluate). One recursive-descent walk serves three modes:
//! `check` (CREATE FUNCTION / DO validation: syntax of every statement and
//! expression), `run` and `skip` (an untaken branch). Blocks with DECLARE,
//! assignment, IF, CASE, LOOP, WHILE, integer FOR, EXIT / CONTINUE with
//! labels, RETURN, RAISE, PERFORM, ASSERT, GET DIAGNOSTICS, NULL, SQL
//! statements with INTO (procedures and DO blocks only: their statements
//! run one after another) and EXCEPTION handlers (the block's writes roll
//! back) are supported. Every statement and loop iteration is a work-control
//! checkpoint. Nothing allocates: frames, texts and captured rows are fixed
//! arrays on the caller's stack.
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const ast = @import("ast.sig");
const parser = @import("parser.sig");
const binder = @import("binder.sig");
const expr = @import("expr.sig");
const dml = @import("dml.sig");
const routine_catalog = @import("routine_catalog.sig");
const value_module = @import("value.sig");
const Error = types.Error;
const Token = lexer.Token;

pub fn Routines(comptime config: types.Config) type {
    const V = types.Values(config);
    const P = parser.Parser(config);
    const B = binder.Binder(config);
    const E = expr.Eval(config);
    const D = dml.Dml(config);
    const RC = routine_catalog.Catalog(config);
    const text_limit = @max(config.text_bytes, config.routine_bytes);
    return struct {
        pub const Text = RC.Text;
        pub const Name = V.Name;

        pub const Kind = enum { create_function, create_procedure, drop_function, drop_procedure, call, do_block, create_trigger, drop_trigger, create_rule, drop_rule };

        /// A byte range of the statement source.
        pub const Span = struct { start: usize = 0, end: usize = 0 };

        pub const Arg = struct { name: Name = .{}, oid: u32 = 0, typmod: i32 = -1 };

        pub const CreateRoutine = struct {
            replace: bool = false,
            procedure: bool = false,
            name: Name = .{},
            args: [config.routine_args]Arg = @splat(.{}),
            arg_count: usize = 0,
            return_oid: u32 = routine_catalog.void_oid,
            return_typmod: i32 = -1,
            /// 0 SQL, 1 PL/pgSQL.
            language: u8 = 0,
            volatility: u8 = 'v',
            strict: bool = false,
            body: Text = .{},

            pub fn argOids(self: *const CreateRoutine, out: *[config.routine_args]u32) []const u32 {
                for (self.args[0..self.arg_count], 0..) |arg, index| out[index] = arg.oid;
                return out[0..self.arg_count];
            }
        };

        pub const DropRoutine = struct {
            procedure: bool = false,
            if_exists: bool = false,
            cascade: bool = false,
            name: Name = .{},
            /// An argument list was written (else the name must be unique).
            has_args: bool = false,
            args: [config.routine_args]u32 = @splat(0),
            arg_count: usize = 0,
        };

        pub const Call = struct {
            name: Name = .{},
            args: [config.routine_args]Span = @splat(.{}),
            arg_count: usize = 0,
        };

        pub const DoBlock = struct { body: Text = .{} };

        pub const TableName = struct { schema: Name = .{}, name: Name = .{} };

        pub const CreateTrigger = struct {
            replace: bool = false,
            name: Name = .{},
            tgtype: u8 = 0,
            columns: [config.columns]Name = @splat(.{}),
            column_count: usize = 0,
            table: TableName = .{},
            /// WHEN (condition) text inside the parentheses.
            when: Span = .{},
            function: Name = .{},
            args: [RC.arg_bytes]u8 = @splat(0),
            args_len: usize = 0,
            nargs: usize = 0,
        };

        pub const DropObject = struct { if_exists: bool = false, cascade: bool = false, name: Name = .{}, table: TableName = .{} };

        pub const CreateRule = struct {
            replace: bool = false,
            name: Name = .{},
            event: u8 = '4',
            table: TableName = .{},
            where: Span = .{},
            instead: bool = false,
        };

        pub const Statement = union(Kind) {
            create_function: CreateRoutine,
            create_procedure: CreateRoutine,
            drop_function: DropRoutine,
            drop_procedure: DropRoutine,
            call: Call,
            do_block: DoBlock,
            create_trigger: CreateTrigger,
            drop_trigger: DropObject,
            create_rule: CreateRule,
            drop_rule: DropObject,
        };

        // ---- tokens -------------------------------------------------------

        pub const Cursor = struct {
            source: []const u8,
            tokens: lexer.Tokenizer,
            current: Token = .{},

            pub fn init(source: []const u8, position: usize) Error!Cursor {
                var out = Cursor{ .source = source, .tokens = .{ .source = source, .position = position, .text_limit = text_limit } };
                try out.advance();
                return out;
            }

            pub fn advance(self: *Cursor) Error!void {
                self.current = try self.tokens.next();
            }

            pub fn peek(self: *const Cursor) Error!Token {
                var copy = self.tokens;
                return copy.next();
            }

            pub fn atEnd(self: *const Cursor) bool {
                return self.current.kind == .end;
            }

            pub fn is(self: *const Cursor, comptime wanted: []const u8) bool {
                return self.current.kind == .word and types.keyword(self.current.raw(self.source), wanted);
            }

            pub fn take(self: *Cursor, comptime wanted: []const u8) Error!bool {
                if (!self.is(wanted)) return false;
                try self.advance();
                return true;
            }

            pub fn expect(self: *Cursor, comptime wanted: []const u8) Error!void {
                if (!try self.take(wanted)) return error.Syntax;
            }

            pub fn symbol(self: *const Cursor, which: lexer.Symbol) bool {
                return self.current.kind == .symbol and self.current.symbol == which;
            }

            pub fn takeSymbol(self: *Cursor, which: lexer.Symbol) Error!bool {
                if (!self.symbol(which)) return false;
                try self.advance();
                return true;
            }

            pub fn expectSymbol(self: *Cursor, which: lexer.Symbol) Error!void {
                if (!try self.takeSymbol(which)) return error.Syntax;
            }

            /// Offset of the current token, its delimiters included.
            pub fn start(self: *const Cursor) usize {
                return self.current.start - self.current.prefix;
            }

            /// Offset after the current token, its delimiters included.
            pub fn after(self: *const Cursor) usize {
                return self.current.end + self.current.suffix;
            }

            /// An identifier (unquoted names fold to lower case).
            pub fn identifier(self: *Cursor) Error!Name {
                const token = self.current;
                var out: Name = .{};
                if (token.kind == .quoted_word) {
                    if (token.len > config.name_bytes) return error.NameCapacity;
                    lexer.decodeQuotedWith(self.source, token.quoted(), '"', &out.bytes);
                    out.len = token.len;
                } else if (token.kind == .word and !lexer.reserved(token.keyword)) {
                    if (token.len > config.name_bytes) return error.NameCapacity;
                    for (token.raw(self.source), 0..) |byte, index| out.bytes[index] = types.lower(byte);
                    out.len = token.len;
                } else return error.Syntax;
                try self.advance();
                return out;
            }

            /// A label: any word, reserved ones included.
            pub fn anyIdentifier(self: *Cursor) Error!Name {
                const token = self.current;
                if (token.kind != .word) return self.identifier();
                if (token.len > config.name_bytes) return error.NameCapacity;
                var out: Name = .{ .len = token.len };
                for (token.raw(self.source), 0..) |byte, index| out.bytes[index] = types.lower(byte);
                try self.advance();
                return out;
            }

            /// A string constant ('...', E'...', $$...$$), decoded into `out`.
            pub fn string(self: *Cursor, out: []u8) Error!usize {
                if (self.current.kind != .string) return error.Syntax;
                if (self.current.len > out.len) return error.TextCapacity;
                lexer.decodeQuoted(self.source, self.current.quoted(), out);
                const len = self.current.len;
                try self.advance();
                return len;
            }

            pub fn lexeme(self: *const Cursor) []const u8 {
                return self.current.raw(self.source);
            }
        };

        /// The statement kind of `source` from its leading words; null for
        /// every other statement.
        pub fn classify(source: []const u8) ?Kind {
            var cursor = Cursor.init(source, 0) catch return null;
            if (cursor.is("call")) return .call;
            if (cursor.is("do")) {
                const next = cursor.peek() catch return null;
                if (next.kind == .string or (next.kind == .word and types.keyword(next.raw(source), "language"))) return .do_block;
                return null;
            }
            const create = cursor.is("create");
            if (!create and !cursor.is("drop")) return null;
            cursor.advance() catch return null;
            if (create and cursor.is("or")) {
                cursor.advance() catch return null;
                if (!cursor.is("replace")) return null;
                cursor.advance() catch return null;
            }
            if (cursor.is("function")) return if (create) .create_function else .drop_function;
            if (cursor.is("procedure")) return if (create) .create_procedure else .drop_procedure;
            if (cursor.is("trigger")) return if (create) .create_trigger else .drop_trigger;
            if (cursor.is("constraint") and create) return .create_trigger;
            if (cursor.is("rule")) return if (create) .create_rule else .drop_rule;
            return null;
        }

        // ---- routine statements -------------------------------------------

        fn finish(cursor: *Cursor) Error!void {
            _ = try cursor.takeSymbol(.semicolon);
            if (!cursor.atEnd()) return error.Syntax;
        }

        /// A type name at the cursor (Host-independent: the parser's own
        /// type grammar), as OID and typmod; regclass/regtype are 0A000.
        fn typeAt(cursor: *Cursor, pool: anytype) Error!Arg {
            const at = try P.parseTypeAt(cursor.source, cursor.start(), pool);
            if (at.spec.typmod == ast.regclass_typmod or at.spec.typmod == ast.regtype_typmod) return error.UnsupportedStatement;
            cursor.* = try Cursor.init(cursor.source, at.end);
            return .{ .oid = types.typeOid(types.dataTypeOf(at.spec.ty)), .typmod = at.spec.typmod };
        }

        fn typeStart(cursor: *const Cursor) bool {
            return cursor.current.kind == .word;
        }

        /// `[IN] [name] type`; OUT / INOUT / VARIADIC and DEFAULT are 0A000.
        fn argument(cursor: *Cursor, pool: anytype, named: bool) Error!Arg {
            if (cursor.is("out") or cursor.is("inout") or cursor.is("variadic")) return error.UnsupportedStatement;
            if (cursor.is("in")) {
                const next = try cursor.peek();
                if (next.kind == .word or next.kind == .quoted_word) try cursor.advance();
            }
            var name: Name = .{};
            if (named) {
                // `name type` unless the first word is the whole type.
                var probe = cursor.*;
                const typed = typeAt(&probe, pool) catch null;
                const alone = if (typed != null) (probe.symbol(.comma) or probe.symbol(.rparen) or probe.is("default") or probe.symbol(.eq)) else false;
                if (!alone) name = try cursor.identifier();
            }
            var out = try typeAt(cursor, pool);
            out.name = name;
            if (cursor.is("default") or cursor.symbol(.eq)) return error.UnsupportedStatement;
            return out;
        }

        fn createRoutine(cursor: *Cursor, pool: anytype, out: *CreateRoutine) Error!void {
            out.* = .{};
            _ = try cursor.take("create");
            if (try cursor.take("or")) {
                try cursor.expect("replace");
                out.replace = true;
            }
            out.procedure = try cursor.take("procedure");
            if (!out.procedure) try cursor.expect("function");
            out.name = try cursor.identifier();
            // Schema-qualified routine names are outside the subset.
            if (cursor.symbol(.dot)) return error.UnsupportedStatement;
            try cursor.expectSymbol(.lparen);
            if (!try cursor.takeSymbol(.rparen)) while (true) {
                if (out.arg_count == config.routine_args) return error.ColumnCapacity;
                out.args[out.arg_count] = try argument(cursor, pool, true);
                out.arg_count += 1;
                if (try cursor.takeSymbol(.rparen)) break;
                try cursor.expectSymbol(.comma);
            };
            var returns = false;
            var language = false;
            var volatility = false;
            var strictness = false;
            var body = false;
            while (!cursor.atEnd() and !cursor.symbol(.semicolon)) {
                if (try cursor.take("returns")) {
                    if (cursor.is("null")) {
                        // RETURNS NULL ON NULL INPUT.
                        try cursor.advance();
                        try cursor.expect("on");
                        try cursor.expect("null");
                        try cursor.expect("input");
                        if (strictness) return error.Syntax;
                        strictness = true;
                        out.strict = true;
                        continue;
                    }
                    if (returns or out.procedure) return error.Syntax;
                    returns = true;
                    if (try cursor.take("trigger")) {
                        out.return_oid = routine_catalog.trigger_oid;
                    } else if (try cursor.take("void")) {
                        out.return_oid = routine_catalog.void_oid;
                    } else if (cursor.is("setof") or cursor.is("table") or cursor.is("record")) {
                        return error.UnsupportedStatement;
                    } else {
                        const ret = try typeAt(cursor, pool);
                        out.return_oid = ret.oid;
                        out.return_typmod = ret.typmod;
                    }
                } else if (try cursor.take("language")) {
                    if (language) return error.Syntax;
                    language = true;
                    var name_buffer: [32]u8 = undefined;
                    var raw: []const u8 = undefined;
                    if (cursor.current.kind == .string) {
                        const len = try cursor.string(&name_buffer);
                        raw = name_buffer[0..len];
                    } else if (cursor.current.kind == .word) {
                        raw = cursor.lexeme();
                        try cursor.advance();
                    } else return error.Syntax;
                    if (types.keyword(raw, "sql")) out.language = 0 else if (types.keyword(raw, "plpgsql")) out.language = 1 else return error.UndefinedObject;
                } else if (cursor.is("immutable") or cursor.is("stable") or cursor.is("volatile")) {
                    if (volatility) return error.Syntax;
                    volatility = true;
                    out.volatility = if (cursor.is("immutable")) 'i' else if (cursor.is("stable")) 's' else 'v';
                    try cursor.advance();
                } else if (try cursor.take("strict")) {
                    if (strictness) return error.Syntax;
                    strictness = true;
                    out.strict = true;
                } else if (try cursor.take("called")) {
                    try cursor.expect("on");
                    try cursor.expect("null");
                    try cursor.expect("input");
                    if (strictness) return error.Syntax;
                    strictness = true;
                } else if (cursor.is("not") or cursor.is("leakproof")) {
                    _ = try cursor.take("not");
                    try cursor.expect("leakproof");
                } else if (try cursor.take("security")) {
                    if (try cursor.take("definer")) return error.UnsupportedStatement;
                    try cursor.expect("invoker");
                } else if (try cursor.take("parallel")) {
                    if (!(try cursor.take("safe") or try cursor.take("unsafe") or try cursor.take("restricted"))) return error.Syntax;
                } else if (cursor.is("cost") or cursor.is("rows")) {
                    try cursor.advance();
                    if (cursor.current.kind != .integer and cursor.current.kind != .decimal) return error.Syntax;
                    try cursor.advance();
                } else if (try cursor.take("as")) {
                    if (body) return error.Syntax;
                    body = true;
                    out.body.len = try cursor.string(&out.body.bytes);
                    // AS 'obj_file', 'link_symbol' (C functions) is outside the subset.
                    if (cursor.symbol(.comma)) return error.UnsupportedStatement;
                } else if (cursor.is("return") or cursor.is("begin") or cursor.is("set") or cursor.is("window") or cursor.is("transform") or cursor.is("support")) {
                    return error.UnsupportedStatement;
                } else return error.Syntax;
            }
            try finish(cursor);
            if (!body) return error.InvalidFunctionDefinition;
            if (!language) return error.InvalidFunctionDefinition;
            if (!out.procedure and !returns) return error.InvalidFunctionDefinition;
            if (out.procedure and (volatility or strictness)) return error.InvalidFunctionDefinition;
        }

        fn dropRoutine(cursor: *Cursor, pool: anytype, out: *DropRoutine) Error!void {
            out.* = .{};
            try cursor.expect("drop");
            out.procedure = try cursor.take("procedure");
            if (!out.procedure) try cursor.expect("function");
            if (cursor.is("if")) {
                try cursor.advance();
                try cursor.expect("exists");
                out.if_exists = true;
            }
            out.name = try cursor.identifier();
            if (cursor.symbol(.dot)) return error.UnsupportedStatement;
            if (try cursor.takeSymbol(.lparen)) {
                out.has_args = true;
                if (!try cursor.takeSymbol(.rparen)) while (true) {
                    if (out.arg_count == config.routine_args) return error.ColumnCapacity;
                    out.args[out.arg_count] = (try argument(cursor, pool, true)).oid;
                    out.arg_count += 1;
                    if (try cursor.takeSymbol(.rparen)) break;
                    try cursor.expectSymbol(.comma);
                };
            }
            if (cursor.symbol(.comma)) return error.UnsupportedStatement;
            if (try cursor.take("cascade")) out.cascade = true else _ = try cursor.take("restrict");
            try finish(cursor);
        }

        /// The end of an expression starting at the cursor: the first `,`
        /// or `)` at depth 0 (CALL arguments). Leaves the cursor there.
        fn argumentEnd(cursor: *Cursor) Error!usize {
            var depth: usize = 0;
            while (!cursor.atEnd()) {
                if (cursor.symbol(.lparen) or cursor.symbol(.lbracket)) depth += 1;
                if (cursor.symbol(.rparen) or cursor.symbol(.rbracket)) {
                    if (depth == 0) return cursor.start();
                    depth -= 1;
                }
                if (depth == 0 and cursor.symbol(.comma)) return cursor.start();
                try cursor.advance();
            }
            return error.Syntax;
        }

        fn call(cursor: *Cursor, out: *Call) Error!void {
            out.* = .{};
            try cursor.expect("call");
            out.name = try cursor.identifier();
            if (cursor.symbol(.dot)) return error.UnsupportedStatement;
            try cursor.expectSymbol(.lparen);
            if (!try cursor.takeSymbol(.rparen)) while (true) {
                if (out.arg_count == config.routine_args) return error.ColumnCapacity;
                const begin = cursor.start();
                if (cursor.symbol(.comma) or cursor.symbol(.rparen)) return error.Syntax;
                const end = try argumentEnd(cursor);
                out.args[out.arg_count] = .{ .start = begin, .end = end };
                out.arg_count += 1;
                if (try cursor.takeSymbol(.rparen)) break;
                try cursor.expectSymbol(.comma);
            };
            try finish(cursor);
        }

        fn doBlock(cursor: *Cursor, out: *DoBlock) Error!void {
            out.* = .{};
            try cursor.expect("do");
            var language = false;
            var body = false;
            while (!cursor.atEnd() and !cursor.symbol(.semicolon)) {
                if (try cursor.take("language")) {
                    if (language) return error.Syntax;
                    language = true;
                    var buffer: [32]u8 = undefined;
                    if (cursor.current.kind == .string) {
                        const len = try cursor.string(&buffer);
                        if (types.keyword(buffer[0..len], "sql")) return error.UnsupportedStatement;
                        if (!types.keyword(buffer[0..len], "plpgsql")) return error.UndefinedObject;
                    } else {
                        if (cursor.is("sql")) return error.UnsupportedStatement;
                        if (!cursor.is("plpgsql")) return error.UndefinedObject;
                        try cursor.advance();
                    }
                } else if (cursor.current.kind == .string) {
                    if (body) return error.Syntax;
                    body = true;
                    out.body.len = try cursor.string(&out.body.bytes);
                } else return error.Syntax;
            }
            try finish(cursor);
            if (!body) return error.Syntax;
        }

        fn tableName(cursor: *Cursor) Error!TableName {
            var out: TableName = .{ .name = try cursor.identifier() };
            if (try cursor.takeSymbol(.dot)) {
                out.schema = out.name;
                out.name = try cursor.identifier();
            }
            return out;
        }

        /// The text inside a parenthesized condition; the cursor ends after `)`.
        fn parenthesized(cursor: *Cursor) Error!Span {
            try cursor.expectSymbol(.lparen);
            const begin = cursor.start();
            var depth: usize = 0;
            while (!cursor.atEnd()) {
                if (cursor.symbol(.lparen)) depth += 1;
                if (cursor.symbol(.rparen)) {
                    if (depth == 0) {
                        const end = cursor.start();
                        try cursor.advance();
                        if (end == begin) return error.Syntax;
                        return .{ .start = begin, .end = end };
                    }
                    depth -= 1;
                }
                try cursor.advance();
            }
            return error.Syntax;
        }

        fn createTrigger(cursor: *Cursor, out: *CreateTrigger) Error!void {
            out.* = .{};
            try cursor.expect("create");
            if (try cursor.take("or")) {
                try cursor.expect("replace");
                out.replace = true;
            }
            if (cursor.is("constraint")) return error.UnsupportedStatement;
            try cursor.expect("trigger");
            out.name = try cursor.identifier();
            if (try cursor.take("before")) {
                out.tgtype |= routine_catalog.tg_before;
            } else if (try cursor.take("instead")) {
                try cursor.expect("of");
                out.tgtype |= routine_catalog.tg_instead;
            } else try cursor.expect("after");
            while (true) {
                const bit: u8 = if (try cursor.take("insert")) routine_catalog.tg_insert else if (try cursor.take("delete")) routine_catalog.tg_delete else if (try cursor.take("truncate")) routine_catalog.tg_truncate else blk: {
                    try cursor.expect("update");
                    if (try cursor.take("of")) while (true) {
                        if (out.column_count == config.columns) return error.ColumnCapacity;
                        out.columns[out.column_count] = try cursor.identifier();
                        out.column_count += 1;
                        if (!try cursor.takeSymbol(.comma)) break;
                    };
                    break :blk routine_catalog.tg_update;
                };
                // An event listed twice is a syntax error in PostgreSQL.
                if (out.tgtype & bit != 0) return error.Syntax;
                out.tgtype |= bit;
                if (!try cursor.take("or")) break;
            }
            try cursor.expect("on");
            out.table = try tableName(cursor);
            if (cursor.is("from") or cursor.is("referencing") or cursor.is("deferrable") or cursor.is("initially") or cursor.is("not")) return error.UnsupportedStatement;
            if (try cursor.take("for")) {
                _ = try cursor.take("each");
                if (try cursor.take("row")) {
                    out.tgtype |= routine_catalog.tg_row;
                } else try cursor.expect("statement");
            }
            if (try cursor.take("when")) out.when = try parenthesized(cursor);
            try cursor.expect("execute");
            if (!try cursor.take("function")) try cursor.expect("procedure");
            out.function = try cursor.identifier();
            if (cursor.symbol(.dot)) return error.UnsupportedStatement;
            try cursor.expectSymbol(.lparen);
            if (!try cursor.takeSymbol(.rparen)) while (true) {
                // Arguments are literal strings, numbers or simple names.
                var buffer: [RC.arg_bytes]u8 = undefined;
                var len: usize = 0;
                switch (cursor.current.kind) {
                    .string => len = try cursor.string(&buffer),
                    .integer, .decimal, .word, .quoted_word => {
                        const raw = cursor.lexeme();
                        if (raw.len > buffer.len) return error.TextCapacity;
                        @memcpy(buffer[0..raw.len], raw);
                        len = raw.len;
                        try cursor.advance();
                    },
                    else => return error.Syntax,
                }
                for (buffer[0..len]) |byte| if (byte == 0) return error.CharacterNotInRepertoire;
                if (out.args_len + len + 1 > out.args.len or out.nargs == 255) return error.TextCapacity;
                @memcpy(out.args[out.args_len..][0..len], buffer[0..len]);
                out.args[out.args_len + len] = 0;
                out.args_len += len + 1;
                out.nargs += 1;
                if (try cursor.takeSymbol(.rparen)) break;
                try cursor.expectSymbol(.comma);
            };
            try finish(cursor);
        }

        fn dropObject(cursor: *Cursor, comptime what: []const u8, out: *DropObject) Error!void {
            out.* = .{};
            try cursor.expect("drop");
            try cursor.expect(what);
            if (cursor.is("if")) {
                try cursor.advance();
                try cursor.expect("exists");
                out.if_exists = true;
            }
            out.name = try cursor.identifier();
            try cursor.expect("on");
            out.table = try tableName(cursor);
            if (try cursor.take("cascade")) out.cascade = true else _ = try cursor.take("restrict");
            try finish(cursor);
        }

        fn createRule(cursor: *Cursor, out: *CreateRule) Error!void {
            out.* = .{};
            try cursor.expect("create");
            if (try cursor.take("or")) {
                try cursor.expect("replace");
                out.replace = true;
            }
            try cursor.expect("rule");
            out.name = try cursor.identifier();
            try cursor.expect("as");
            try cursor.expect("on");
            if (try cursor.take("select")) return error.UnsupportedStatement;
            out.event = if (try cursor.take("insert")) '3' else if (try cursor.take("update")) '2' else blk: {
                try cursor.expect("delete");
                break :blk '4';
            };
            try cursor.expect("to");
            out.table = try tableName(cursor);
            if (try cursor.take("where")) {
                const begin = cursor.start();
                var end = begin;
                while (!cursor.atEnd() and !cursor.is("do")) {
                    end = cursor.after();
                    try cursor.advance();
                }
                if (cursor.atEnd() or end == begin) return error.Syntax;
                out.where = .{ .start = begin, .end = end };
            }
            try cursor.expect("do");
            if (try cursor.take("instead")) {
                out.instead = true;
            } else _ = try cursor.take("also");
            // Actions other than NOTHING (query rewriting) are outside the subset.
            if (!try cursor.take("nothing")) return error.UnsupportedStatement;
            try finish(cursor);
        }

        /// Parses a routine statement (`classify` returned its kind).
        pub fn parse(source: []const u8, pool: anytype, out: *Statement) Error!void {
            const kind = classify(source) orelse return error.Syntax;
            var cursor = try Cursor.init(source, 0);
            switch (kind) {
                .create_function, .create_procedure => {
                    out.* = if (kind == .create_function) .{ .create_function = .{} } else .{ .create_procedure = .{} };
                    try createRoutine(&cursor, pool, if (kind == .create_function) &out.create_function else &out.create_procedure);
                },
                .drop_function, .drop_procedure => {
                    out.* = if (kind == .drop_function) .{ .drop_function = .{} } else .{ .drop_procedure = .{} };
                    try dropRoutine(&cursor, pool, if (kind == .drop_function) &out.drop_function else &out.drop_procedure);
                },
                .call => {
                    out.* = .{ .call = .{} };
                    try call(&cursor, &out.call);
                },
                .do_block => {
                    out.* = .{ .do_block = .{} };
                    try doBlock(&cursor, &out.do_block);
                },
                .create_trigger => {
                    out.* = .{ .create_trigger = .{} };
                    try createTrigger(&cursor, &out.create_trigger);
                },
                .drop_trigger => {
                    out.* = .{ .drop_trigger = .{} };
                    try dropObject(&cursor, "trigger", &out.drop_trigger);
                },
                .create_rule => {
                    out.* = .{ .create_rule = .{} };
                    try createRule(&cursor, &out.create_rule);
                },
                .drop_rule => {
                    out.* = .{ .drop_rule = .{} };
                    try dropObject(&cursor, "rule", &out.drop_rule);
                },
            }
        }

        pub fn command(kind: Kind) types.CommandTag {
            return switch (kind) {
                .create_function => .create_function,
                .create_procedure => .create_procedure,
                .drop_function => .drop_function,
                .drop_procedure => .drop_procedure,
                .call => .call,
                .do_block => .do_block,
                .create_trigger => .create_trigger,
                .drop_trigger => .drop_trigger,
                .create_rule => .create_rule,
                .drop_rule => .drop_rule,
            };
        }

        /// The statements of a SQL routine body (split at top-level `;`).
        pub const Statements = struct {
            source: []const u8,
            position: usize = 0,

            pub fn next(self: *Statements) Error!?Span {
                var cursor = try Cursor.init(self.source, self.position);
                while (cursor.symbol(.semicolon)) try cursor.advance();
                if (cursor.atEnd()) {
                    self.position = self.source.len;
                    return null;
                }
                const begin = cursor.start();
                var depth: usize = 0;
                while (!cursor.atEnd()) {
                    if (cursor.symbol(.lparen)) depth += 1;
                    if (cursor.symbol(.rparen) and depth > 0) depth -= 1;
                    if (depth == 0 and cursor.symbol(.semicolon)) break;
                    try cursor.advance();
                }
                const end = if (cursor.atEnd()) self.source.len else cursor.start();
                self.position = if (cursor.atEnd()) self.source.len else cursor.after();
                return .{ .start = begin, .end = end };
            }
        };

        // ---- PL/pgSQL ---------------------------------------------------

        /// Values of a running routine: variables (bound by name through
        /// `variables`, read by routine_param nodes through `frame`).
        pub const Frame = struct {
            variables: B.RoutineVariables = .{},
            cells: [config.routine_variables]V.Cell = @splat(.null_value),
            constant: [config.routine_variables]bool = @splat(false),
            not_null: [config.routine_variables]bool = @splat(false),
            new: ?*E.Row = null,
            old: ?*E.Row = null,
            /// FOUND's variable index.
            found: usize = 0,
            row_count: usize = 0,
            eframe: E.Frame = .{ .cells = undefined },

            pub fn evalFrame(self: *Frame) *const E.Frame {
                self.eframe = .{ .cells = &self.cells, .count = self.variables.count, .new = self.new, .old = self.old };
                return &self.eframe;
            }

            pub fn declare(self: *Frame, name: []const u8, ty: types.Type, typmod: i32) Error!usize {
                const count = self.variables.count;
                if (count == config.routine_variables) return error.ColumnCapacity;
                if (name.len > config.name_bytes) return error.NameCapacity;
                self.variables.items[count] = .{ .ty = ty, .typmod = typmod };
                self.variables.items[count].name.len = name.len;
                @memcpy(self.variables.items[count].name.bytes[0..name.len], name);
                self.cells[count] = .null_value;
                self.constant[count] = false;
                self.not_null[count] = false;
                self.variables.count = count + 1;
                return count;
            }

            pub fn set(self: *Frame, index: usize, cell: V.Cell) void {
                self.cells[index] = cell;
            }
        };

        /// A row a statement with INTO returned (its first row).
        pub const Capture = struct {
            cells: [config.columns]V.Cell = @splat(.null_value),
            tys: [config.columns]types.Type = @splat(.unknown),
            count: usize = 0,
            rows: usize = 0,
        };

        pub const Mode = enum { check, run, skip };

        pub const Purpose = enum { function, procedure, do_block, trigger };

        /// What RETURN produced in a trigger function.
        pub const Record = enum { none, new, old, null_row };

        pub const Signal = union(enum) {
            normal: void,
            exit: Name,
            next: Name,
            returned: void,
        };

        /// One INTO target or assignment target.
        const Target = struct {
            /// 0 variable, 1 NEW field, 2 OLD field.
            record: u8 = 0,
            index: usize = 0,
            ty: types.Type = .unknown,
            typmod: i32 = -1,
        };

        /// Exception condition names and SQLSTATEs the handlers and RAISE
        /// accept (others are 42704).
        const Condition = struct { name: []const u8, state: []const u8, err: Error };
        const conditions = [_]Condition{
            .{ .name = "division_by_zero", .state = "22012", .err = error.DivisionByZero },
            .{ .name = "unique_violation", .state = "23505", .err = error.PrimaryKeyViolation },
            .{ .name = "not_null_violation", .state = "23502", .err = error.NotNullViolation },
            .{ .name = "check_violation", .state = "23514", .err = error.CheckViolation },
            .{ .name = "foreign_key_violation", .state = "23503", .err = error.ForeignKeyViolation },
            .{ .name = "exclusion_violation", .state = "23P01", .err = error.ExclusionViolation },
            .{ .name = "raise_exception", .state = "P0001", .err = error.RaiseException },
            .{ .name = "no_data_found", .state = "P0002", .err = error.NoDataFound },
            .{ .name = "too_many_rows", .state = "P0003", .err = error.TooManyRows },
            .{ .name = "numeric_value_out_of_range", .state = "22003", .err = error.NumericValueOutOfRange },
            .{ .name = "numeric_value_out_of_range", .state = "22003", .err = error.IntegerOverflow },
            .{ .name = "invalid_text_representation", .state = "22P02", .err = error.InvalidTextRepresentation },
            .{ .name = "string_data_right_truncation", .state = "22001", .err = error.StringDataRightTruncation },
            .{ .name = "null_value_not_allowed", .state = "22004", .err = error.NullValueNotAllowed },
            .{ .name = "case_not_found", .state = "20000", .err = error.CaseNotFound },
            .{ .name = "cardinality_violation", .state = "21000", .err = error.CardinalityViolation },
            .{ .name = "undefined_table", .state = "42P01", .err = error.TableNotFound },
            .{ .name = "undefined_column", .state = "42703", .err = error.ColumnNotFound },
            .{ .name = "undefined_function", .state = "42883", .err = error.UndefinedFunction },
            .{ .name = "datatype_mismatch", .state = "42804", .err = error.TypeMismatch },
            .{ .name = "invalid_parameter_value", .state = "22023", .err = error.InvalidParameterValue },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.ProgramLimitExceeded },
            .{ .name = "assert_failure", .state = "P0004", .err = error.RaiseException },
        };

        /// Errors an EXCEPTION handler never catches (PostgreSQL: cancel
        /// and the work budget end the statement; a lock wait restarts it).
        fn uncatchable(err: Error) bool {
            return err == error.QueryCanceled or err == error.QueryWorkLimit or err == error.WouldBlock;
        }

        pub fn Interpreter(comptime Host: type) type {
            return struct {
                const Self = @This();
                host: *Host,
                source: []const u8,
                frame: *Frame,
                purpose: Purpose,
                cursor: Cursor = undefined,
                /// Function / trigger result.
                return_column: V.Column = .{},
                void_result: bool = false,
                returned: bool = false,
                result: V.Cell = .null_value,
                record: Record = .none,
                /// The error a running handler caught (RAISE without arguments).
                handling: ?Error = null,

                /// Validates (`check`) or runs the routine body.
                pub fn execute(self: *Self, mode: Mode) Error!void {
                    self.cursor = try Cursor.init(self.source, 0);
                    const name = try self.label();
                    if (!self.cursor.is("declare") and !self.cursor.is("begin")) return error.Syntax;
                    const signal = try self.block(mode, name, true);
                    if (!self.cursor.atEnd()) return error.Syntax;
                    if (mode != .run) return;
                    switch (signal) {
                        .exit, .next => return error.Syntax,
                        else => {},
                    }
                    if (self.returned) return;
                    switch (self.purpose) {
                        .trigger => return error.FunctionExecutedNoReturn,
                        .function => if (!self.void_result) return error.FunctionExecutedNoReturn,
                        else => {},
                    }
                }

                fn voidResult(self: *const Self) bool {
                    return self.void_result;
                }

                fn checkpoint(self: *Self, mode: Mode) Error!void {
                    if (mode == .run) try self.host.routineCheckpoint();
                }

                fn atBlockEnd(self: *const Self) bool {
                    const c = &self.cursor;
                    return c.atEnd() or c.is("end") or c.is("else") or c.is("elsif") or c.is("elseif") or c.is("when") or c.is("exception");
                }

                /// Statements until END / ELSE / ELSIF / WHEN / EXCEPTION.
                /// After a signal the rest are skipped.
                fn statementList(self: *Self, mode: Mode) Error!Signal {
                    var signal: Signal = .normal;
                    while (!self.atBlockEnd()) {
                        try self.checkpoint(mode);
                        const effective: Mode = if (mode == .run and signal != .normal) .skip else mode;
                        const outcome = try self.statement(effective);
                        if (effective == .run and outcome != .normal) signal = outcome;
                    }
                    if (self.cursor.atEnd()) return error.Syntax;
                    return signal;
                }

                fn label(self: *Self) Error!Name {
                    if (!self.cursor.symbol(.shift_left)) return .{};
                    try self.cursor.advance();
                    const name = try self.cursor.anyIdentifier();
                    try self.cursor.expectSymbol(.shift_right);
                    return name;
                }

                fn endLabel(self: *Self, wanted: Name) Error!void {
                    if (self.cursor.current.kind == .word or self.cursor.current.kind == .quoted_word) {
                        const name = try self.cursor.anyIdentifier();
                        if (wanted.len == 0 or !types.same(name.slice(), wanted.slice())) return error.Syntax;
                    }
                }

                fn statement(self: *Self, mode: Mode) Error!Signal {
                    const name = try self.label();
                    const c = &self.cursor;
                    if (c.is("declare") or c.is("begin")) return self.block(mode, name, false);
                    if (c.is("loop") or c.is("while") or c.is("for")) return self.loopStatement(mode, name);
                    if (name.len != 0) return error.Syntax;
                    if (c.is("if")) return self.ifStatement(mode);
                    if (c.is("case")) return self.caseStatement(mode);
                    if (c.is("exit") or c.is("continue")) return self.exitStatement(mode);
                    if (c.is("return")) return self.returnStatement(mode);
                    if (c.is("raise")) return self.raiseStatement(mode);
                    if (c.is("perform")) return self.performStatement(mode);
                    if (c.is("assert")) return self.assertStatement(mode);
                    if (c.is("get")) return self.diagnosticsStatement(mode);
                    if (c.is("null")) {
                        const next = try c.peek();
                        if (next.kind == .symbol and next.symbol == .semicolon) {
                            try c.advance();
                            try c.advance();
                            return .normal;
                        }
                    }
                    if (c.is("commit") or c.is("rollback")) return error.UnsupportedStatement;
                    if (sqlWord(c)) return self.sqlStatement(mode);
                    return self.assignment(mode);
                }

                fn sqlWord(c: *const Cursor) bool {
                    inline for (.{ "select", "insert", "update", "delete", "with", "values", "merge", "create", "drop", "alter", "truncate", "table", "call", "do", "lock", "set", "reset", "show" }) |word| {
                        if (c.is(word)) return true;
                    }
                    return false;
                }

                // ---- expressions ------------------------------------------

                const Stops = struct { then: bool = false, loop: bool = false, comma: bool = false, dots: bool = false, when: bool = false, into: bool = false, semicolon: bool = true };

                /// Scans one expression from the cursor; the cursor stops at
                /// the terminating token. Returns its span.
                fn expression(self: *Self, comptime stops: Stops) Error!Span {
                    const c = &self.cursor;
                    const begin = c.start();
                    var depth: usize = 0;
                    var cases: usize = 0;
                    while (!c.atEnd()) {
                        if (depth == 0 and cases == 0) {
                            if (stops.semicolon and c.symbol(.semicolon)) break;
                            if (stops.comma and c.symbol(.comma)) break;
                            if (stops.then and c.is("then")) break;
                            if (stops.loop and c.is("loop")) break;
                            if (stops.when and c.is("when")) break;
                            if (stops.into and c.is("into")) break;
                            if (stops.dots) if (dotsAt(c)) |at| {
                                if (at == begin) return error.Syntax;
                                c.* = try Cursor.init(c.source, at + 2);
                                return .{ .start = begin, .end = at };
                            };
                        }
                        if (c.symbol(.lparen) or c.symbol(.lbracket)) depth += 1;
                        if ((c.symbol(.rparen) or c.symbol(.rbracket))) {
                            if (depth == 0) return error.Syntax;
                            depth -= 1;
                        }
                        if (c.is("case")) cases += 1;
                        if (c.is("end") and cases > 0) cases -= 1;
                        try c.advance();
                    }
                    if (c.atEnd()) return error.Syntax;
                    const end = c.start();
                    if (end == begin) return error.Syntax;
                    return .{ .start = begin, .end = end };
                }

                /// A `..` inside or right after the current token.
                fn dotsAt(c: *const Cursor) ?usize {
                    const t = c.current;
                    switch (t.kind) {
                        .integer, .decimal, .symbol => {},
                        else => return null,
                    }
                    var at = t.start;
                    while (at < t.end) : (at += 1) {
                        if (c.source[at] == '.' and at + 1 < c.source.len and c.source[at + 1] == '.') return at;
                    }
                    return null;
                }

                fn evaluate(self: *Self, span: Span, mode: Mode, goal: ?*const V.Column) Error!V.Cell {
                    switch (mode) {
                        .skip => return .null_value,
                        .check => {
                            try self.host.routineCheck(self.source, span.start, span.end);
                            return .null_value;
                        },
                        .run => return self.host.routineEvaluate(self.frame, self.source, span.start, span.end, goal),
                    }
                }

                fn boolean(self: *Self, span: Span, mode: Mode) Error!bool {
                    const column: V.Column = .{ .data_type = .boolean };
                    const value = try self.evaluate(span, mode, &column);
                    return value == .boolean and value.boolean;
                }

                fn columnOf(ty: types.Type, typmod: i32) V.Column {
                    return .{ .data_type = types.dataTypeOf(ty), .typmod = typmod };
                }

                // ---- statements -------------------------------------------

                fn block(self: *Self, mode: Mode, name: Name, top: bool) Error!Signal {
                    const c = &self.cursor;
                    const saved = self.frame.variables.count;
                    defer self.frame.variables.count = saved;
                    if (try c.take("declare")) {
                        while (!c.is("begin")) {
                            if (c.atEnd()) return error.Syntax;
                            try self.declaration(mode);
                        }
                    }
                    try c.expect("begin");
                    const body = c.*;
                    const mark = if (mode == .run) self.host.routineMark() else undefined;
                    var signal: Signal = .normal;
                    var caught: ?Error = null;
                    if (mode == .run) {
                        signal = self.statementList(.run) catch |err| blk: {
                            if (uncatchable(err)) return err;
                            caught = err;
                            break :blk .normal;
                        };
                    } else signal = try self.statementList(mode);
                    if (caught != null) {
                        // Find the handlers: skip the rest of the body.
                        self.cursor = body;
                        _ = try self.statementList(.skip);
                    }
                    if (try c.take("exception")) {
                        if (caught != null) self.host.routineRollback(mark);
                        var handled = false;
                        while (try c.take("when")) {
                            var matches = false;
                            while (true) {
                                if (try c.take("sqlstate")) {
                                    var buffer: [8]u8 = undefined;
                                    const len = try c.string(&buffer);
                                    if (len != 5) return error.Syntax;
                                    if (caught) |err| matches = matches or stateMatches(buffer[0..5], err);
                                } else {
                                    const condition = try c.identifier();
                                    if (types.same(condition.slice(), "others")) {
                                        matches = matches or caught != null;
                                    } else {
                                        if (!knownCondition(condition.slice())) return error.UndefinedObject;
                                        if (caught) |err| matches = matches or nameMatches(condition.slice(), err);
                                    }
                                }
                                if (!try c.take("or")) break;
                            }
                            try c.expect("then");
                            const run_handler = mode == .run and caught != null and matches and !handled;
                            if (run_handler) {
                                handled = true;
                                const previous = self.handling;
                                self.handling = caught;
                                defer self.handling = previous;
                                signal = try self.statementList(.run);
                            } else _ = try self.statementList(if (mode == .check) .check else .skip);
                        }
                        if (caught) |err| if (!handled) return err;
                    } else if (caught) |err| return err;
                    try c.expect("end");
                    try self.endLabel(name);
                    if (top) {
                        _ = try c.takeSymbol(.semicolon);
                    } else try c.expectSymbol(.semicolon);
                    return self.consume(signal, name);
                }

                /// A labeled EXIT ends at its own block or loop.
                fn consume(self: *Self, signal: Signal, name: Name) Signal {
                    _ = self;
                    return switch (signal) {
                        .exit => |wanted| if (name.len != 0 and types.same(wanted.slice(), name.slice())) .normal else signal,
                        else => signal,
                    };
                }

                fn stateMatches(state: []const u8, err: Error) bool {
                    for (conditions) |entry| if (types.same(entry.state, state) and entry.err == err) return true;
                    return false;
                }

                fn nameMatches(name: []const u8, err: Error) bool {
                    for (conditions) |entry| if (types.same(entry.name, name) and entry.err == err) return true;
                    return false;
                }

                fn knownCondition(name: []const u8) bool {
                    for (conditions) |entry| if (types.same(entry.name, name)) return true;
                    return false;
                }

                fn declaration(self: *Self, mode: Mode) Error!void {
                    const c = &self.cursor;
                    const name = try c.identifier();
                    const constant = try c.take("constant");
                    if (c.is("alias") or c.is("cursor") or c.is("record") or c.is("refcursor")) return error.UnsupportedStatement;
                    const typed = try self.host.routineType(self.source, c.start());
                    self.cursor = try Cursor.init(self.source, typed.end);
                    if (self.cursor.symbol(.percent)) return error.UnsupportedStatement;
                    if (self.cursor.is("collate")) {
                        try self.cursor.advance();
                        _ = try self.cursor.identifier();
                    }
                    var not_null = false;
                    if (self.cursor.is("not")) {
                        try self.cursor.advance();
                        try self.cursor.expect("null");
                        not_null = true;
                    }
                    var initial: ?Span = null;
                    if (try self.cursor.take("default") or try self.assignOperator()) {
                        initial = try self.expression(.{});
                    }
                    try self.cursor.expectSymbol(.semicolon);
                    if (not_null and initial == null) return error.NullValueNotAllowed;
                    if (constant and initial == null) return error.Syntax;
                    const index = try self.frame.declare(name.slice(), typed.spec.ty, typed.spec.typmod);
                    self.frame.constant[index] = constant;
                    self.frame.not_null[index] = not_null;
                    if (initial) |span| {
                        if (mode == .run) {
                            const column = columnOf(typed.spec.ty, typed.spec.typmod);
                            // The default sees the variables declared before it.
                            self.frame.variables.count = index;
                            const value = self.evaluate(span, mode, &column) catch |err| {
                                self.frame.variables.count = index + 1;
                                return err;
                            };
                            self.frame.variables.count = index + 1;
                            try self.store(.{ .index = index, .ty = typed.spec.ty, .typmod = typed.spec.typmod }, value, true);
                        } else {
                            self.frame.variables.count = index;
                            _ = try self.evaluate(span, mode, null);
                            self.frame.variables.count = index + 1;
                        }
                    }
                }

                fn assignOperator(self: *Self) Error!bool {
                    const c = &self.cursor;
                    if (c.symbol(.colon)) {
                        const next = try c.peek();
                        if (next.kind == .symbol and next.symbol == .eq and next.start == c.current.end) {
                            try c.advance();
                            try c.advance();
                            return true;
                        }
                        return false;
                    }
                    return c.takeSymbol(.eq);
                }

                /// `name`, `record.field` (NEW / OLD in a trigger).
                fn target(self: *Self, mode: Mode) Error!Target {
                    const c = &self.cursor;
                    const first = try c.identifier();
                    if (try c.takeSymbol(.dot)) {
                        const field = try c.identifier();
                        const record: u8 = if (types.same(first.slice(), "new")) 1 else if (types.same(first.slice(), "old")) 2 else 0;
                        if (record == 0) return error.UnsupportedStatement;
                        const table = self.frame.variables.record_table orelse {
                            if (mode == .check) return .{ .record = record };
                            return error.TableNotFound;
                        };
                        for (table.columns[0..table.column_count], 0..) |*column, index| {
                            if (types.same(column.name.slice(), field.slice())) return .{ .record = record, .index = index, .ty = types.typeOfData(column.data_type), .typmod = column.typmod };
                        }
                        return error.ColumnNotFound;
                    }
                    if (c.symbol(.lbracket)) return error.UnsupportedStatement;
                    // An unknown target is a compile error in PostgreSQL (42601).
                    const index = self.frame.variables.find(first.slice()) orelse return error.Syntax;
                    const item = &self.frame.variables.items[index];
                    if (self.frame.constant[index]) return error.ErrorInAssignment;
                    return .{ .index = index, .ty = item.ty, .typmod = item.typmod };
                }

                /// Stores a value already converted to the target's type.
                fn store(self: *Self, place: Target, value: V.Cell, initializing: bool) Error!void {
                    _ = initializing;
                    const column = columnOf(place.ty, place.typmod);
                    const stored = try D.store(&column, value, self.host.routineSession());
                    switch (place.record) {
                        0 => {
                            if (stored == .null_value and self.frame.not_null[place.index]) return error.NullValueNotAllowed;
                            self.frame.cells[place.index] = stored;
                        },
                        1 => (self.frame.new orelse return error.ObjectNotInPrerequisiteState)[place.index] = stored,
                        else => (self.frame.old orelse return error.ObjectNotInPrerequisiteState)[place.index] = stored,
                    }
                }

                /// Converts a value of type `from` to the target (assignment).
                fn storeCast(self: *Self, place: Target, value: V.Cell, from: types.Type) Error!void {
                    var cell = value;
                    if (cell != .null_value and from != place.ty and from != .unknown) {
                        if (!value_module.castable(from, place.ty, .assignment) and !(value_module.integral(from) and value_module.integral(place.ty))) return error.TypeMismatch;
                        cell = try E.cast(cell, from, place.ty, place.typmod, self.host.routineSession());
                    } else if (cell != .null_value and from == .unknown and cell == .text and place.ty != .text) {
                        cell = try E.cast(cell, .text, place.ty, place.typmod, self.host.routineSession());
                    }
                    try self.store(place, cell, false);
                }

                fn assignment(self: *Self, mode: Mode) Error!Signal {
                    const place = try self.target(mode);
                    if (!try self.assignOperator()) return error.Syntax;
                    const span = try self.expression(.{});
                    try self.cursor.expectSymbol(.semicolon);
                    if (mode != .run) {
                        _ = try self.evaluate(span, mode, null);
                        return .normal;
                    }
                    const column = columnOf(place.ty, place.typmod);
                    const value = try self.evaluate(span, mode, &column);
                    try self.store(place, value, false);
                    return .normal;
                }

                fn ifStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("if");
                    var taken = false;
                    var signal: Signal = .normal;
                    while (true) {
                        const condition = try self.expression(.{ .then = true, .semicolon = false });
                        try c.expect("then");
                        const hit = !taken and mode != .skip and (mode == .check or try self.boolean(condition, mode));
                        if (mode == .check) _ = try self.evaluate(condition, mode, null);
                        const branch: Mode = if (mode == .check) .check else if (hit and mode == .run) .run else .skip;
                        const outcome = try self.statementList(branch);
                        if (branch == .run) {
                            taken = true;
                            signal = outcome;
                        }
                        if (try c.take("elsif") or try c.take("elseif")) continue;
                        break;
                    }
                    if (try c.take("else")) {
                        const branch: Mode = if (mode == .check) .check else if (!taken and mode == .run) .run else .skip;
                        const outcome = try self.statementList(branch);
                        if (branch == .run) signal = outcome;
                    }
                    try c.expect("end");
                    try c.expect("if");
                    try c.expectSymbol(.semicolon);
                    return signal;
                }

                fn caseStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("case");
                    var operand: ?Span = null;
                    if (!c.is("when")) operand = try self.expression(.{ .when = true, .semicolon = false });
                    if (mode == .check) if (operand) |span| {
                        _ = try self.evaluate(span, .check, null);
                    };
                    var taken = false;
                    var signal: Signal = .normal;
                    if (!c.is("when")) return error.Syntax;
                    while (try c.take("when")) {
                        var hit = false;
                        while (true) {
                            const value = try self.expression(.{ .then = true, .comma = true, .semicolon = false });
                            if (mode == .check) {
                                _ = try self.evaluate(value, .check, null);
                            } else if (mode == .run and !taken and !hit) {
                                hit = try self.caseMatch(operand, value);
                            }
                            if (!try c.takeSymbol(.comma)) break;
                        }
                        try c.expect("then");
                        const branch: Mode = if (mode == .check) .check else if (hit and mode == .run) .run else .skip;
                        const outcome = try self.statementList(branch);
                        if (branch == .run) {
                            taken = true;
                            signal = outcome;
                        }
                    }
                    var has_else = false;
                    if (try c.take("else")) {
                        has_else = true;
                        const branch: Mode = if (mode == .check) .check else if (!taken and mode == .run) .run else .skip;
                        const outcome = try self.statementList(branch);
                        if (branch == .run) {
                            taken = true;
                            signal = outcome;
                        }
                    }
                    try c.expect("end");
                    try c.expect("case");
                    try c.expectSymbol(.semicolon);
                    if (mode == .run and !taken and !has_else) return error.CaseNotFound;
                    return signal;
                }

                /// `operand = value` (searched CASE: `value` is the condition).
                fn caseMatch(self: *Self, operand: ?Span, value: Span) Error!bool {
                    const left = operand orelse return self.boolean(value, .run);
                    // Compare through one expression: (operand) = (value).
                    return self.host.routineCompare(self.frame, self.source, left, value);
                }

                fn loopStatement(self: *Self, mode: Mode, name: Name) Error!Signal {
                    const c = &self.cursor;
                    if (c.is("for")) return self.forStatement(mode, name);
                    var condition: ?Span = null;
                    if (try c.take("while")) {
                        condition = try self.expression(.{ .loop = true, .semicolon = false });
                        if (mode == .check) _ = try self.evaluate(condition.?, .check, null);
                    }
                    try c.expect("loop");
                    const body = c.*;
                    var signal: Signal = .normal;
                    if (mode == .run) {
                        while (true) {
                            try self.host.routineCheckpoint();
                            if (condition) |span| if (!try self.boolean(span, .run)) break;
                            self.cursor = body;
                            const outcome = try self.statementList(.run);
                            switch (outcome) {
                                .normal => {},
                                .next => |wanted| if (wanted.len != 0 and !types.same(wanted.slice(), name.slice())) {
                                    signal = outcome;
                                    break;
                                },
                                .exit => |wanted| {
                                    if (wanted.len != 0 and !types.same(wanted.slice(), name.slice())) signal = outcome;
                                    break;
                                },
                                .returned => {
                                    signal = outcome;
                                    break;
                                },
                            }
                        }
                    }
                    self.cursor = body;
                    _ = try self.statementList(if (mode == .check) .check else .skip);
                    try c.expect("end");
                    try c.expect("loop");
                    try self.endLabel(name);
                    try c.expectSymbol(.semicolon);
                    return signal;
                }

                fn forStatement(self: *Self, mode: Mode, name: Name) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("for");
                    const variable = try c.identifier();
                    try c.expect("in");
                    const reverse = try c.take("reverse");
                    // Query loops (FOR record IN SELECT ...) are outside the subset.
                    if (sqlWord(c)) return error.UnsupportedStatement;
                    const low = try self.expression(.{ .dots = true, .semicolon = false });
                    const high = try self.expression(.{ .loop = true, .semicolon = false });
                    var step_span: ?Span = null;
                    var high_span = high;
                    // `a .. b BY c`: BY splits the upper bound.
                    if (findWord(self.source, high, "by")) |at| {
                        high_span = .{ .start = high.start, .end = at };
                        step_span = .{ .start = at + 2, .end = high.end };
                    }
                    try c.expect("loop");
                    const body = c.*;
                    const saved = self.frame.variables.count;
                    defer self.frame.variables.count = saved;
                    const index = try self.frame.declare(variable.slice(), .int4, -1);
                    var signal: Signal = .normal;
                    if (mode == .check) {
                        _ = try self.evaluate(low, .check, null);
                        _ = try self.evaluate(high_span, .check, null);
                        if (step_span) |span| _ = try self.evaluate(span, .check, null);
                    }
                    if (mode == .run) {
                        const int_column: V.Column = .{ .data_type = .integer32 };
                        self.frame.variables.count = saved;
                        const first = try self.evaluate(low, .run, &int_column);
                        const last = try self.evaluate(high_span, .run, &int_column);
                        const step_value: V.Cell = if (step_span) |span| try self.evaluate(span, .run, &int_column) else .{ .integer = 1 };
                        self.frame.variables.count = saved + 1;
                        if (first == .null_value) return error.NullValueNotAllowed;
                        if (last == .null_value) return error.NullValueNotAllowed;
                        if (step_value == .null_value) return error.NullValueNotAllowed;
                        if (step_value.integer <= 0) return error.InvalidParameterValue;
                        var current = first.integer;
                        var iterated = false;
                        while (if (reverse) current >= last.integer else current <= last.integer) {
                            try self.host.routineCheckpoint();
                            iterated = true;
                            self.frame.cells[index] = .{ .integer = current };
                            self.cursor = body;
                            const outcome = try self.statementList(.run);
                            var stop = false;
                            switch (outcome) {
                                .normal => {},
                                .next => |wanted| if (wanted.len != 0 and !types.same(wanted.slice(), name.slice())) {
                                    signal = outcome;
                                    stop = true;
                                },
                                .exit => |wanted| {
                                    if (wanted.len != 0 and !types.same(wanted.slice(), name.slice())) signal = outcome;
                                    stop = true;
                                },
                                .returned => {
                                    signal = outcome;
                                    stop = true;
                                },
                            }
                            if (stop) break;
                            const moved = if (reverse) @subWithOverflow(current, step_value.integer) else @addWithOverflow(current, step_value.integer);
                            if (moved[1] != 0 or moved[0] > 2147483647 or moved[0] < -2147483648) break;
                            current = moved[0];
                        }
                        self.frame.cells[self.frame.found] = .{ .boolean = iterated };
                    }
                    self.cursor = body;
                    _ = try self.statementList(if (mode == .check) .check else .skip);
                    try c.expect("end");
                    try c.expect("loop");
                    try self.endLabel(name);
                    try c.expectSymbol(.semicolon);
                    return signal;
                }

                /// The offset of a top-level word inside a span.
                fn findWord(source: []const u8, span: Span, comptime word: []const u8) ?usize {
                    var cursor = Cursor.init(source[0..span.end], span.start) catch return null;
                    var depth: usize = 0;
                    while (!cursor.atEnd()) {
                        if (cursor.symbol(.lparen)) depth += 1;
                        if (cursor.symbol(.rparen) and depth > 0) depth -= 1;
                        if (depth == 0 and cursor.is(word)) return cursor.start();
                        cursor.advance() catch return null;
                    }
                    return null;
                }

                fn exitStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    const leave = c.is("exit");
                    try c.advance();
                    var name: Name = .{};
                    if (c.current.kind == .word and !c.is("when") or c.current.kind == .quoted_word) name = try c.anyIdentifier();
                    var condition: ?Span = null;
                    if (try c.take("when")) condition = try self.expression(.{});
                    try c.expectSymbol(.semicolon);
                    if (mode == .check) {
                        if (condition) |span| _ = try self.evaluate(span, .check, null);
                        return .normal;
                    }
                    if (mode != .run) return .normal;
                    if (condition) |span| if (!try self.boolean(span, .run)) return .normal;
                    return if (leave) .{ .exit = name } else .{ .next = name };
                }

                fn returnStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("return");
                    if (c.is("next") or c.is("query")) return error.UnsupportedStatement;
                    if (c.symbol(.semicolon)) {
                        try c.advance();
                        if (self.purpose == .function and !self.voidResult()) return error.Syntax;
                        if (self.purpose == .trigger) return error.Syntax;
                        if (mode == .run) self.returned = true;
                        return if (mode == .run) .returned else .normal;
                    }
                    if (self.purpose == .procedure or self.purpose == .do_block) return error.Syntax;
                    if (self.purpose == .function and self.voidResult()) return error.TypeMismatch;
                    if (self.purpose == .trigger) {
                        // RETURN NEW / OLD / NULL.
                        const which: Record = if (c.is("new")) .new else if (c.is("old")) .old else if (c.is("null")) .null_row else return error.UnsupportedStatement;
                        try c.advance();
                        try c.expectSymbol(.semicolon);
                        if (mode == .run) {
                            self.record = which;
                            self.returned = true;
                            return .returned;
                        }
                        return .normal;
                    }
                    const span = try self.expression(.{});
                    try c.expectSymbol(.semicolon);
                    if (mode != .run) {
                        _ = try self.evaluate(span, mode, null);
                        return .normal;
                    }
                    const value = try self.evaluate(span, .run, &self.return_column);
                    self.result = try D.store(&self.return_column, value, self.host.routineSession());
                    self.returned = true;
                    return .returned;
                }

                fn raiseStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("raise");
                    if (c.symbol(.semicolon)) {
                        try c.advance();
                        if (mode == .run) return self.handling orelse error.Syntax;
                        return .normal;
                    }
                    var exception = true;
                    inline for (.{ "debug", "log", "info", "notice", "warning" }) |level| {
                        if (c.is(level)) exception = false;
                    }
                    if (!exception or c.is("exception")) try c.advance();
                    var raised: Error = error.RaiseException;
                    if (c.current.kind == .string) {
                        var buffer: [config.text_bytes]u8 = undefined;
                        const len = try c.string(&buffer);
                        var placeholders: usize = 0;
                        var at: usize = 0;
                        while (at < len) : (at += 1) {
                            if (buffer[at] != '%') continue;
                            if (at + 1 < len and buffer[at + 1] == '%') {
                                at += 1;
                                continue;
                            }
                            placeholders += 1;
                        }
                        var given: usize = 0;
                        while (try c.takeSymbol(.comma)) {
                            const span = try self.expression(.{ .comma = true });
                            _ = try self.evaluate(span, mode, null);
                            given += 1;
                        }
                        if (given != placeholders) return error.Syntax;
                    } else if (try c.take("sqlstate")) {
                        var buffer: [8]u8 = undefined;
                        const len = try c.string(&buffer);
                        if (len != 5) return error.Syntax;
                        const found = stateIndex(buffer[0..5]) orelse return error.UnsupportedStatement;
                        raised = conditions[found].err;
                    } else if (c.current.kind == .word and !c.is("using")) {
                        const condition = try c.identifier();
                        const found = conditionIndex(condition.slice()) orelse return error.UndefinedObject;
                        raised = conditions[found].err;
                    }
                    if (try c.take("using")) while (true) {
                        const option = try c.identifier();
                        if (!try c.takeSymbol(.eq)) {
                            if (!try self.assignOperator()) return error.Syntax;
                        }
                        const span = try self.expression(.{ .comma = true });
                        if (types.same(option.slice(), "errcode")) {
                            // A literal condition name or SQLSTATE.
                            var probe = try Cursor.init(self.source[0..span.end], span.start);
                            var buffer: [64]u8 = undefined;
                            const len = probe.string(&buffer) catch return error.UnsupportedStatement;
                            const by_name = conditionIndex(buffer[0..len]);
                            const by_state: ?usize = if (len == 5) stateIndex(buffer[0..5]) else null;
                            const found = by_name orelse by_state orelse return error.UnsupportedStatement;
                            raised = conditions[found].err;
                        } else if (!types.same(option.slice(), "message") and !types.same(option.slice(), "detail") and !types.same(option.slice(), "hint")) {
                            return error.UnsupportedStatement;
                        } else _ = try self.evaluate(span, mode, null);
                        if (!try c.takeSymbol(.comma)) break;
                    };
                    try c.expectSymbol(.semicolon);
                    if (mode == .run and exception) return raised;
                    return .normal;
                }

                fn conditionIndex(name: []const u8) ?usize {
                    for (conditions, 0..) |entry, index| if (types.same(entry.name, name)) return index;
                    return null;
                }

                fn stateIndex(state: []const u8) ?usize {
                    for (conditions, 0..) |entry, index| if (types.same(entry.state, state)) return index;
                    return null;
                }

                fn performStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("perform");
                    const begin = c.start();
                    const span = try self.expression(.{});
                    try c.expectSymbol(.semicolon);
                    if (findWord(self.source, span, "from") != null or findWord(self.source, span, "where") != null) {
                        // PERFORM query: run `SELECT query` and discard it.
                        var buffer: [config.routine_bytes + 8]u8 = undefined;
                        const text = self.source[begin..span.end];
                        if (text.len + 7 > buffer.len) return error.TextCapacity;
                        @memcpy(buffer[0..7], "SELECT ");
                        @memcpy(buffer[7..][0..text.len], text);
                        if (mode == .skip) return .normal;
                        if (mode == .check) {
                            try self.host.routineCheckStatement(buffer[0 .. 7 + text.len]);
                            return .normal;
                        }
                        var capture: Capture = .{};
                        const rows = try self.host.routineStatement(self.frame, buffer[0 .. 7 + text.len], &capture);
                        self.frame.cells[self.frame.found] = .{ .boolean = rows != 0 };
                        self.frame.row_count = rows;
                        return .normal;
                    }
                    _ = try self.evaluate(span, mode, null);
                    if (mode == .run) {
                        self.frame.cells[self.frame.found] = .{ .boolean = true };
                        self.frame.row_count = 1;
                    }
                    return .normal;
                }

                fn assertStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("assert");
                    const condition = try self.expression(.{ .comma = true });
                    var message: ?Span = null;
                    if (try c.takeSymbol(.comma)) message = try self.expression(.{});
                    try c.expectSymbol(.semicolon);
                    if (mode == .check) {
                        _ = try self.evaluate(condition, .check, null);
                        if (message) |span| _ = try self.evaluate(span, .check, null);
                        return .normal;
                    }
                    if (mode != .run) return .normal;
                    const column: V.Column = .{ .data_type = .boolean };
                    const value = try self.evaluate(condition, .run, &column);
                    // NULL or false: assert_failure (P0004 is reported as P0001 here).
                    if (value != .boolean or !value.boolean) return error.RaiseException;
                    return .normal;
                }

                fn diagnosticsStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("get");
                    _ = try c.take("current");
                    try c.expect("diagnostics");
                    while (true) {
                        const place = try self.target(mode);
                        if (!try c.takeSymbol(.eq)) {
                            if (!try self.assignOperator()) return error.Syntax;
                        }
                        if (!try c.take("row_count")) return error.UnsupportedStatement;
                        if (mode == .run) try self.storeCast(place, .{ .integer = @intCast(self.frame.row_count) }, .int8);
                        if (!try c.takeSymbol(.comma)) break;
                    }
                    try c.expectSymbol(.semicolon);
                    return .normal;
                }

                /// A SQL statement: runs as its own statement (procedures and
                /// DO blocks only); `INTO [STRICT] targets` takes the first row.
                fn sqlStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    const begin = c.start();
                    const dml_into = c.is("insert");
                    var into_start: ?usize = null;
                    var into_end: usize = 0;
                    var strict = false;
                    var targets: [config.columns]Target = undefined;
                    var target_count: usize = 0;
                    var depth: usize = 0;
                    var seen_insert_into = false;
                    while (!c.atEnd()) {
                        if (c.symbol(.lparen)) depth += 1;
                        if (c.symbol(.rparen) and depth > 0) depth -= 1;
                        if (depth == 0 and c.symbol(.semicolon)) break;
                        if (depth == 0 and c.is("into") and into_start == null) {
                            if (dml_into and !seen_insert_into) {
                                seen_insert_into = true;
                            } else {
                                into_start = c.start();
                                try c.advance();
                                strict = try c.take("strict");
                                while (true) {
                                    if (target_count == targets.len) return error.ColumnCapacity;
                                    targets[target_count] = try self.target(mode);
                                    target_count += 1;
                                    if (!try c.takeSymbol(.comma)) break;
                                }
                                into_end = c.start();
                                continue;
                            }
                        }
                        try c.advance();
                    }
                    if (c.atEnd()) return error.Syntax;
                    const end = c.start();
                    try c.expectSymbol(.semicolon);
                    var buffer: [config.routine_bytes]u8 = undefined;
                    var text: []const u8 = self.source[begin..end];
                    if (into_start) |at| {
                        const head = self.source[begin..at];
                        const tail = self.source[into_end..end];
                        if (head.len + 1 + tail.len > buffer.len) return error.TextCapacity;
                        @memcpy(buffer[0..head.len], head);
                        buffer[head.len] = ' ';
                        @memcpy(buffer[head.len + 1 ..][0..tail.len], tail);
                        text = buffer[0 .. head.len + 1 + tail.len];
                    }
                    switch (mode) {
                        .skip => return .normal,
                        .check => {
                            try self.host.routineCheckStatement(text);
                            return .normal;
                        },
                        .run => {},
                    }
                    const select = types.keyword(firstWord(text), "select") or types.keyword(firstWord(text), "with") or types.keyword(firstWord(text), "values");
                    if (select and into_start == null) return error.Syntax;
                    var capture: Capture = .{};
                    const rows = try self.host.routineStatement(self.frame, text, if (into_start != null) &capture else null);
                    self.frame.row_count = rows;
                    self.frame.cells[self.frame.found] = .{ .boolean = rows != 0 };
                    if (into_start != null) {
                        if (strict and capture.rows == 0) return error.NoDataFound;
                        if (strict and capture.rows > 1) return error.TooManyRows;
                        if (capture.count != target_count and !(capture.rows == 0)) return error.Syntax;
                        for (targets[0..target_count], 0..) |place, index| {
                            const value: V.Cell = if (capture.rows == 0 or index >= capture.count) .null_value else capture.cells[index];
                            try self.storeCast(place, value, if (index < capture.count) capture.tys[index] else .unknown);
                        }
                    }
                    return .normal;
                }

                fn firstWord(text: []const u8) []const u8 {
                    var at: usize = 0;
                    while (at < text.len and !types.letter(text[at])) at += 1;
                    var end = at;
                    while (end < text.len and (types.letter(text[end]) or types.digit(text[end]))) end += 1;
                    return text[at..end];
                }
            };
        }
    };
}
