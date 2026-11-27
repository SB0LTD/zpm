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
const std = @import("std");
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const ast = @import("ast.sig");
const parser = @import("parser.sig");
const binder = @import("binder.sig");
const expr = @import("expr.sig");
const dml = @import("dml.sig");
const routine_catalog = @import("routine_catalog.sig");
const catalog_objects = @import("catalog_objects.sig");
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

        pub const Kind = enum { create_function, create_procedure, drop_function, drop_procedure, call, do_block, create_trigger, drop_trigger, create_rule, drop_rule, grant_execute, revoke_execute, alter_function, alter_procedure };

        /// A byte range of the statement source.
        pub const Span = struct { start: usize = 0, end: usize = 0 };

        /// A declared parameter: its mode ('i' IN, 'o' OUT, 'b' INOUT, 'v'
        /// VARIADIC, 't' a RETURNS TABLE column) and DEFAULT text.
        pub const Arg = struct { name: Name = .{}, oid: u32 = 0, typmod: i32 = -1, mode: u8 = 'i', default: Span = .{} };

        pub fn inputMode(mode: u8) bool {
            return mode == 'i' or mode == 'b' or mode == 'v';
        }

        pub fn outputMode(mode: u8) bool {
            return mode == 'o' or mode == 'b' or mode == 't';
        }

        pub const CreateRoutine = struct {
            replace: bool = false,
            procedure: bool = false,
            has_schema: bool = false,
            schema: Name = .{},
            name: Name = .{},
            /// Every declared parameter (RETURNS TABLE columns last).
            args: [config.routine_args]Arg = @splat(.{}),
            arg_count: usize = 0,
            return_oid: u32 = routine_catalog.void_oid,
            return_typmod: i32 = -1,
            /// 0 SQL, 1 PL/pgSQL.
            language: u8 = 0,
            volatility: u8 = 'v',
            strict: bool = false,
            body: Text = .{},
            /// B11 wave 4: RETURNS given, RETURNS SETOF / TABLE, RETURNS
            /// record, SECURITY DEFINER and SET clauses (`name=value`,
            /// NUL-terminated).
            returns: bool = false,
            retset: bool = false,
            record: bool = false,
            security_definer: bool = false,
            /// The body is SQL-standard (RETURN / BEGIN ATOMIC).
            sql_body: bool = false,
            settings: [RC.arg_bytes]u8 = @splat(0),
            settings_len: usize = 0,
            setting_count: usize = 0,

            /// The input types (the routine's signature).
            pub fn argOids(self: *const CreateRoutine, out: *[config.routine_args]u32) []const u32 {
                var count: usize = 0;
                for (self.args[0..self.arg_count]) |arg| {
                    if (!inputMode(arg.mode)) continue;
                    out[count] = arg.oid;
                    count += 1;
                }
                return out[0..count];
            }

            pub fn outputCount(self: *const CreateRoutine) usize {
                var count: usize = 0;
                for (self.args[0..self.arg_count]) |arg| count += @intFromBool(outputMode(arg.mode));
                return count;
            }
        };

        pub const DropRoutine = struct {
            procedure: bool = false,
            any_kind: bool = false,
            has_schema: bool = false,
            schema: Name = .{},
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
            has_schema: bool = false,
            schema: Name = .{},
            args: [config.routine_args]Span = @splat(.{}),
            /// Named notation (`name => value`); empty when positional.
            names: [config.routine_args]Name = @splat(.{}),
            arg_count: usize = 0,
            /// The last argument is marked VARIADIC.
            variadic: bool = false,
        };

        pub const AlterOwner = struct { routine: DropRoutine = .{}, owner: catalog_objects.Grantee = .{} };

        pub const ExecuteTarget = struct {
            routine: DropRoutine = .{},
            schema: Name = .{},
        };

        pub const ExecuteGrant = struct {
            targets: [catalog_objects.list_capacity]ExecuteTarget = @splat(.{}),
            target_count: usize = 0,
            grantees: [catalog_objects.list_capacity]catalog_objects.Grantee = @splat(.{}),
            grantee_count: usize = 0,
            grantor: ?catalog_objects.Grantee = null,
            option: bool = false,
            cascade: bool = false,
        };

        pub const DoBlock = struct { body: Text = .{} };

        pub const TableName = struct { schema: Name = .{}, name: Name = .{} };

        pub const CreateTrigger = struct {
            replace: bool = false,
            has_function_schema: bool = false,
            function_schema: Name = .{},
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
            /// The action statements (B11 wave 4): empty for NOTHING; the
            /// text inside the parentheses of `( a; b )` (`multiple`).
            action: Span = .{},
            multiple: bool = false,
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
            grant_execute: ExecuteGrant,
            revoke_execute: ExecuteGrant,
            alter_function: AlterOwner,
            alter_procedure: AlterOwner,
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
            if (cursor.is("alter")) {
                cursor.advance() catch return null;
                if (cursor.is("function")) return .alter_function;
                if (cursor.is("procedure")) return .alter_procedure;
                return null;
            }
            if (cursor.is("grant") or cursor.is("revoke")) {
                const grant = cursor.is("grant");
                cursor.advance() catch return null;
                if (!grant and cursor.is("grant")) {
                    cursor.advance() catch return null;
                    if (!cursor.is("option")) return null;
                    cursor.advance() catch return null;
                    if (!cursor.is("for")) return null;
                    cursor.advance() catch return null;
                }
                if (cursor.is("execute")) return if (grant) .grant_execute else .revoke_execute;
                if (!cursor.is("all")) return null;
                cursor.advance() catch return null;
                if (cursor.is("privileges")) cursor.advance() catch return null;
                if (!cursor.is("on")) return null;
                cursor.advance() catch return null;
                if (!cursor.is("function") and !cursor.is("procedure") and !cursor.is("routine")) return null;
                return if (grant) .grant_execute else .revoke_execute;
            }
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
            if (ast.regKind(at.spec.typmod) != .none) return error.UnsupportedStatement;
            cursor.* = try Cursor.init(cursor.source, at.end);
            return .{ .oid = types.typeOid(types.dataTypeOf(at.spec.ty)), .typmod = at.spec.typmod };
        }

        fn typeStart(cursor: *const Cursor) bool {
            return cursor.current.kind == .word;
        }

        /// `[IN | OUT | INOUT | VARIADIC] [name] type [{DEFAULT | =} expr]`
        /// (a DEFAULT only where `defaults` allows it: CREATE).
        fn argument(cursor: *Cursor, pool: anytype, named: bool, defaults: bool) Error!Arg {
            var mode: u8 = 'i';
            if (cursor.is("in") or cursor.is("out") or cursor.is("inout") or cursor.is("variadic")) {
                const next = try cursor.peek();
                if (next.kind == .word or next.kind == .quoted_word) {
                    mode = if (cursor.is("in")) 'i' else if (cursor.is("out")) 'o' else if (cursor.is("inout")) 'b' else 'v';
                    try cursor.advance();
                }
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
            out.mode = mode;
            if (cursor.is("default") or cursor.symbol(.eq)) {
                if (!defaults) return error.Syntax;
                try cursor.advance();
                const begin = cursor.start();
                var depth: usize = 0;
                while (!cursor.atEnd()) {
                    if (cursor.symbol(.lparen) or cursor.symbol(.lbracket)) depth += 1;
                    if (cursor.symbol(.rparen) or cursor.symbol(.rbracket)) {
                        if (depth == 0) break;
                        depth -= 1;
                    }
                    if (depth == 0 and cursor.symbol(.comma)) break;
                    try cursor.advance();
                }
                const end = cursor.start();
                if (cursor.atEnd() or end == begin) return error.Syntax;
                out.default = .{ .start = begin, .end = end };
            }
            return out;
        }

        /// PostgreSQL's parameter-list rules (42P13): unique input names
        /// and unique output names, one VARIADIC array as the last input,
        /// DEFAULT only on inputs and on every input after the first one,
        /// and a result type that agrees with the OUT parameters.
        fn validateSignature(out: *CreateRoutine) Error!void {
            const params = out.args[0..out.arg_count];
            var seen_default = false;
            var inputs: usize = 0;
            var last_input: usize = 0;
            for (params, 0..) |arg, index| {
                if (inputMode(arg.mode)) {
                    inputs += 1;
                    last_input = index;
                    if (arg.default.end != 0) seen_default = true else if (seen_default) return error.InvalidFunctionDefinition;
                } else if (arg.default.end != 0) return error.InvalidFunctionDefinition;
                if (arg.name.len != 0) for (params[0..index]) |other| {
                    if (!types.same(other.name.slice(), arg.name.slice())) continue;
                    if ((inputMode(arg.mode) and inputMode(other.mode)) or (outputMode(arg.mode) and outputMode(other.mode))) return error.InvalidFunctionDefinition;
                };
            }
            for (params, 0..) |arg, index| {
                if (arg.mode != 'v') continue;
                if (index != last_input) return error.InvalidFunctionDefinition;
                const data = types.typeFromOid(arg.oid) orelse return error.InvalidFunctionDefinition;
                if (types.elementData(data) == null) return error.InvalidFunctionDefinition;
            }
            const outputs = out.outputCount();
            if (out.procedure) {
                if (outputs != 0) out.return_oid = routine_catalog.record_oid;
                return;
            }
            var table = false;
            for (params) |arg| table = table or arg.mode == 't';
            if (table) {
                for (params) |arg| if (arg.mode == 'o' or arg.mode == 'b') return error.InvalidFunctionDefinition;
            }
            if (outputs == 0) {
                // RETURNS record needs OUT parameters (or a column list).
                if (out.record) return error.UnsupportedStatement;
                if (!out.returns) return error.InvalidFunctionDefinition;
                return;
            }
            var first: Arg = .{};
            for (params) |arg| if (outputMode(arg.mode)) {
                first = arg;
                break;
            };
            if (outputs == 1) {
                if (out.returns and !table and (out.record or out.return_oid != first.oid)) return error.InvalidFunctionDefinition;
                out.return_oid = first.oid;
                out.return_typmod = first.typmod;
            } else {
                if (out.returns and !table and !out.record) return error.InvalidFunctionDefinition;
                out.return_oid = routine_catalog.record_oid;
                out.return_typmod = -1;
            }
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
            out.name = try qualifiedName(cursor, &out.has_schema, &out.schema);
            try cursor.expectSymbol(.lparen);
            if (!try cursor.takeSymbol(.rparen)) while (true) {
                if (out.arg_count == config.routine_args) return error.ColumnCapacity;
                out.args[out.arg_count] = try argument(cursor, pool, true, true);
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
                    out.returns = true;
                    if (try cursor.take("table")) {
                        // RETURNS TABLE (name type, ...): TABLE columns.
                        out.retset = true;
                        try cursor.expectSymbol(.lparen);
                        while (true) {
                            if (out.arg_count == config.routine_args) return error.ColumnCapacity;
                            var column: Arg = .{ .mode = 't', .name = try cursor.identifier() };
                            const typed = try typeAt(cursor, pool);
                            column.oid = typed.oid;
                            column.typmod = typed.typmod;
                            out.args[out.arg_count] = column;
                            out.arg_count += 1;
                            if (try cursor.takeSymbol(.rparen)) break;
                            try cursor.expectSymbol(.comma);
                        }
                        continue;
                    }
                    if (try cursor.take("setof")) out.retset = true;
                    if (try cursor.take("trigger")) {
                        if (out.retset) return error.InvalidFunctionDefinition;
                        out.return_oid = routine_catalog.trigger_oid;
                    } else if (try cursor.take("void")) {
                        out.return_oid = routine_catalog.void_oid;
                    } else if (try cursor.take("record")) {
                        out.record = true;
                        out.return_oid = routine_catalog.record_oid;
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
                    if (try cursor.take("definer")) {
                        out.security_definer = true;
                    } else try cursor.expect("invoker");
                } else if (cursor.is("external")) {
                    // [EXTERNAL] SECURITY { DEFINER | INVOKER }.
                    try cursor.advance();
                    try cursor.expect("security");
                    if (try cursor.take("definer")) {
                        out.security_definer = true;
                    } else try cursor.expect("invoker");
                } else if (try cursor.take("set")) {
                    try settingClause(cursor, out);
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
                } else if (cursor.is("return") or cursor.is("begin")) {
                    // SQL-standard bodies (B11 wave 4): RETURN expression,
                    // kept as `SELECT expression`, and BEGIN ATOMIC
                    // statements END, kept as the statements. Both close
                    // the definition and imply LANGUAGE SQL.
                    if (body) return error.Syntax;
                    body = true;
                    out.sql_body = true;
                    try sqlBody(cursor, out);
                    break;
                } else if (cursor.is("window") or cursor.is("transform") or cursor.is("support")) {
                    return error.UnsupportedStatement;
                } else return error.Syntax;
            }
            try finish(cursor);
            if (!body) return error.InvalidFunctionDefinition;
            if (out.sql_body and language and out.language != 0) return error.InvalidFunctionDefinition;
            if (!language and !out.sql_body) return error.InvalidFunctionDefinition;
            if (out.procedure and (volatility or strictness)) return error.InvalidFunctionDefinition;
            try validateSignature(out);
        }

        fn sqlBody(cursor: *Cursor, out: *CreateRoutine) Error!void {
            if (try cursor.take("return")) {
                const begin = cursor.start();
                var end = begin;
                while (!cursor.atEnd() and !cursor.symbol(.semicolon)) {
                    end = cursor.after();
                    try cursor.advance();
                }
                const expression = std.mem.trim(u8, cursor.source[begin..end], " \t\r\n");
                if (expression.len == 0) return error.Syntax;
                if (expression.len + 7 > out.body.bytes.len) return error.TextCapacity;
                @memcpy(out.body.bytes[0..7], "SELECT ");
                @memcpy(out.body.bytes[7..][0..expression.len], expression);
                out.body.len = expression.len + 7;
                return;
            }
            try cursor.expect("begin");
            try cursor.expect("atomic");
            const begin = cursor.start();
            var end = begin;
            var depth: usize = 0;
            var cases: usize = 0;
            while (true) {
                if (cursor.atEnd()) return error.Syntax;
                if (cursor.symbol(.lparen)) depth += 1;
                if (cursor.symbol(.rparen) and depth > 0) depth -= 1;
                if (cursor.is("case")) cases += 1;
                if (cursor.is("end")) {
                    if (cases > 0) {
                        cases -= 1;
                    } else if (depth == 0) {
                        end = cursor.start();
                        try cursor.advance();
                        break;
                    }
                }
                try cursor.advance();
            }
            const statements = std.mem.trim(u8, cursor.source[begin..end], " \t\r\n");
            if (statements.len > out.body.bytes.len) return error.TextCapacity;
            @memcpy(out.body.bytes[0..statements.len], statements);
            out.body.len = statements.len;
        }

        /// `SET name { TO | = } value [, ...]` or `SET name FROM CURRENT`
        /// (0A000): kept as `name=value`, the value's source text.
        fn settingClause(cursor: *Cursor, out: *CreateRoutine) Error!void {
            const name = try cursor.anyIdentifier();
            if (cursor.is("from")) return error.UnsupportedStatement;
            if (!try cursor.take("to")) try cursor.expectSymbol(.eq);
            const begin = cursor.start();
            var end = begin;
            while (true) {
                _ = try cursor.takeSymbol(.minus);
                const kind = cursor.current.kind;
                if (kind != .word and kind != .quoted_word and kind != .string and kind != .integer and kind != .decimal) return error.Syntax;
                end = cursor.after();
                try cursor.advance();
                if (!try cursor.takeSymbol(.comma)) break;
            }
            const value = std.mem.trim(u8, cursor.source[begin..end], " \t\r\n");
            const length = name.len + 1 + value.len + 1;
            if (out.settings_len + length > out.settings.len or out.setting_count == 255) return error.TextCapacity;
            @memcpy(out.settings[out.settings_len..][0..name.len], name.slice());
            out.settings[out.settings_len + name.len] = '=';
            @memcpy(out.settings[out.settings_len + name.len + 1 ..][0..value.len], value);
            out.settings[out.settings_len + length - 1] = 0;
            out.settings_len += length;
            out.setting_count += 1;
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
            out.name = try qualifiedName(cursor, &out.has_schema, &out.schema);
            try routineSignature(cursor, pool, out);
            if (cursor.symbol(.comma)) return error.UnsupportedStatement;
            if (try cursor.take("cascade")) out.cascade = true else _ = try cursor.take("restrict");
            try finish(cursor);
        }

        fn alterOwner(cursor: *Cursor, pool: anytype, out: *AlterOwner) Error!void {
            out.* = .{};
            try cursor.expect("alter");
            out.routine.procedure = try cursor.take("procedure");
            if (!out.routine.procedure) try cursor.expect("function");
            out.routine.name = try qualifiedName(cursor, &out.routine.has_schema, &out.routine.schema);
            try routineSignature(cursor, pool, &out.routine);
            if (!try cursor.take("owner")) return error.UnsupportedStatement;
            try cursor.expect("to");
            out.owner = try executeRole(cursor);
            try finish(cursor);
        }

        fn routineSignature(cursor: *Cursor, pool: anytype, out: *DropRoutine) Error!void {
            if (try cursor.takeSymbol(.lparen)) {
                out.has_args = true;
                if (!try cursor.takeSymbol(.rparen)) while (true) {
                    if (out.arg_count == config.routine_args) return error.ColumnCapacity;
                    // Only inputs identify a routine (OUT ones are skipped).
                    const arg = try argument(cursor, pool, true, false);
                    if (!inputMode(arg.mode)) {
                        if (try cursor.takeSymbol(.rparen)) break;
                        try cursor.expectSymbol(.comma);
                        continue;
                    }
                    out.args[out.arg_count] = arg.oid;
                    out.arg_count += 1;
                    if (try cursor.takeSymbol(.rparen)) break;
                    try cursor.expectSymbol(.comma);
                };
            }
        }

        fn executeGrant(cursor: *Cursor, pool: anytype, out: *ExecuteGrant, comptime revoke: bool) Error!void {
            try cursor.expect(if (revoke) "revoke" else "grant");
            if (revoke and try cursor.take("grant")) {
                try cursor.expect("option");
                try cursor.expect("for");
                out.option = true;
            }
            if (try cursor.take("all")) _ = try cursor.take("privileges") else try cursor.expect("execute");
            try cursor.expect("on");
            const any_kind = try cursor.take("routine");
            const procedure = !any_kind and try cursor.take("procedure");
            if (!procedure and !any_kind) try cursor.expect("function");
            while (true) {
                if (out.target_count == out.targets.len) return error.ProgramLimitExceeded;
                const target = &out.targets[out.target_count];
                target.routine.procedure = procedure;
                target.routine.any_kind = any_kind;
                target.routine.name = try cursor.identifier();
                if (try cursor.takeSymbol(.dot)) {
                    target.routine.has_schema = true;
                    target.schema = target.routine.name;
                    target.routine.schema = target.schema;
                    if (!types.same(target.schema.slice(), "public") and !types.same(target.schema.slice(), "pg_catalog")) return error.UnsupportedStatement;
                    target.routine.name = try cursor.identifier();
                }
                try routineSignature(cursor, pool, &target.routine);
                out.target_count += 1;
                if (!try cursor.takeSymbol(.comma)) break;
            }
            try cursor.expect(if (revoke) "from" else "to");
            while (true) {
                if (out.grantee_count == out.grantees.len) return error.ProgramLimitExceeded;
                out.grantees[out.grantee_count] = try executeRole(cursor);
                out.grantee_count += 1;
                if (!try cursor.takeSymbol(.comma)) break;
            }
            if (!revoke and try cursor.take("with")) {
                try cursor.expect("grant");
                try cursor.expect("option");
                out.option = true;
            }
            if (try cursor.take("granted")) {
                try cursor.expect("by");
                out.grantor = try executeRole(cursor);
            }
            if (revoke) {
                out.cascade = try cursor.take("cascade");
                if (!out.cascade) _ = try cursor.take("restrict");
            }
            try finish(cursor);
        }

        fn executeRole(cursor: *Cursor) Error!catalog_objects.Grantee {
            if (cursor.current.kind == .word) {
                const kind: ?catalog_objects.GranteeKind = if (cursor.is("public")) .public
                    else if (cursor.is("current_user")) .current_user
                    else if (cursor.is("current_role")) .current_role
                    else if (cursor.is("session_user")) .session_user else null;
                if (kind) |special| {
                    try cursor.advance();
                    return .{ .kind = special };
                }
                _ = try cursor.take("group");
                if (cursor.is("user") or cursor.is("none")) return error.Syntax;
            }
            const token = cursor.current;
            _ = try cursor.identifier();
            return .{ .name = .{
                .span = .{ .start = token.start, .len = token.end - token.start },
                .quoted = token.kind == .quoted_word, .len = token.len,
            } };
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

        /// `[schema.]name`: the schema is resolved when the statement runs.
        fn qualifiedName(cursor: *Cursor, has_schema: *bool, schema: *Name) Error!Name {
            var name = try cursor.identifier();
            if (try cursor.takeSymbol(.dot)) {
                has_schema.* = true;
                schema.* = name;
                name = try cursor.identifier();
            }
            return name;
        }

        fn call(cursor: *Cursor, out: *Call) Error!void {
            out.* = .{};
            try cursor.expect("call");
            out.name = try qualifiedName(cursor, &out.has_schema, &out.schema);
            try cursor.expectSymbol(.lparen);
            var named = false;
            if (!try cursor.takeSymbol(.rparen)) while (true) {
                if (out.arg_count == config.routine_args) return error.ColumnCapacity;
                // VARIADIC only on the last argument; no positional one
                // after a named one (42601).
                if (out.variadic) return error.Syntax;
                if (cursor.is("variadic")) {
                    try cursor.advance();
                    out.variadic = true;
                }
                if (try namedAhead(cursor)) {
                    out.names[out.arg_count] = try cursor.identifier();
                    try cursor.advance();
                    try cursor.advance();
                    named = true;
                } else if (named) return error.Syntax;
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

        /// `name =>` or `name :=` (adjacent symbols) at the cursor.
        fn namedAhead(cursor: *const Cursor) Error!bool {
            if (cursor.current.kind != .word and cursor.current.kind != .quoted_word) return false;
            var copy = cursor.tokens;
            const second = try copy.next();
            if (second.kind != .symbol or (second.symbol != .eq and second.symbol != .colon)) return false;
            const third = try copy.next();
            if (third.kind != .symbol or third.start != second.end) return false;
            return (second.symbol == .eq and third.symbol == .gt) or (second.symbol == .colon and third.symbol == .eq);
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
            out.function = try qualifiedName(cursor, &out.has_function_schema, &out.function_schema);
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
            if (try cursor.take("nothing")) return finish(cursor);
            // INSERT / UPDATE / DELETE actions (B11 wave 4), one or several
            // in parentheses; SELECT and NOTIFY actions are outside it.
            if (cursor.symbol(.lparen)) {
                out.action = try parenthesized(cursor);
                out.multiple = true;
            } else {
                const begin = cursor.start();
                var end = begin;
                var depth: usize = 0;
                while (!cursor.atEnd()) {
                    if (cursor.symbol(.lparen)) depth += 1;
                    if (cursor.symbol(.rparen) and depth > 0) depth -= 1;
                    if (depth == 0 and cursor.symbol(.semicolon)) break;
                    end = cursor.after();
                    try cursor.advance();
                }
                if (end == begin) return error.Syntax;
                out.action = .{ .start = begin, .end = end };
            }
            try finish(cursor);
            if (out.action.end == out.action.start) return error.Syntax;
            var statements: Statements = .{ .source = cursor.source[0..out.action.end], .position = out.action.start };
            var count: usize = 0;
            while (try statements.next()) |span| {
                const word = firstWordOf(cursor.source[span.start..span.end]);
                const known = types.keyword(word, "insert") or types.keyword(word, "update") or types.keyword(word, "delete");
                if (!known) return if (types.keyword(word, "select") or types.keyword(word, "notify") or types.keyword(word, "with") or types.keyword(word, "values")) error.UnsupportedStatement else error.Syntax;
                count += 1;
            }
            if (count == 0) return error.Syntax;
        }

        pub fn firstWordOf(text: []const u8) []const u8 {
            var at: usize = 0;
            while (at < text.len and !types.letter(text[at])) at += 1;
            var end = at;
            while (end < text.len and (types.letter(text[end]) or types.digit(text[end]))) end += 1;
            return text[at..end];
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
                .alter_function, .alter_procedure => {
                    out.* = if (kind == .alter_function) .{ .alter_function = .{} } else .{ .alter_procedure = .{} };
                    try alterOwner(&cursor, pool, if (kind == .alter_function) &out.alter_function else &out.alter_procedure);
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
                .grant_execute => {
                    out.* = .{ .grant_execute = .{} };
                    try executeGrant(&cursor, pool, &out.grant_execute, false);
                },
                .revoke_execute => {
                    out.* = .{ .revoke_execute = .{} };
                    try executeGrant(&cursor, pool, &out.revoke_execute, true);
                },
            }
        }

        pub fn command(kind: Kind) types.CommandTag {
            return switch (kind) {
                .create_function => .create_function,
                .create_procedure => .create_procedure,
                .drop_function => .drop_function,
                .drop_procedure => .drop_procedure,
                .alter_function => .alter_function,
                .alter_procedure => .alter_procedure,
                .call => .call,
                .do_block => .do_block,
                .create_trigger => .create_trigger,
                .drop_trigger => .drop_trigger,
                .create_rule => .create_rule,
                .drop_rule => .drop_rule,
                .grant_execute => .grant,
                .revoke_execute => .revoke,
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
            eframe: E.Frame = undefined,

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

        /// Receives one result row (B11 wave 4: set-returning routines).
        pub const Emit = struct { ptr: *anyopaque, call: *const fn (ptr: *anyopaque, cells: *const anyopaque) Error!void };

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

        /// Exception condition names (PostgreSQL's plerrcodes.h) and the
        /// SQLSTATE of each engine error, for handlers, RAISE, SQLSTATE /
        /// SQLERRM and GET STACKED DIAGNOSTICS. The first entry of an error
        /// is its SQLSTATE; the first entry of a state is the error RAISE
        /// SQLSTATE / ERRCODE raises. `message` is PostgreSQL's fixed
        /// message text where it has no variable parts (else empty: SQLERRM
        /// reports the engine's diagnostic text). Unknown names are 42704.
        const Condition = struct { name: []const u8, state: []const u8, err: Error, message: []const u8 = "" };
        const conditions = [_]Condition{
            .{ .name = "division_by_zero", .state = "22012", .err = error.DivisionByZero, .message = "division by zero" },
            .{ .name = "unique_violation", .state = "23505", .err = error.PrimaryKeyViolation },
            .{ .name = "not_null_violation", .state = "23502", .err = error.NotNullViolation },
            .{ .name = "check_violation", .state = "23514", .err = error.CheckViolation },
            .{ .name = "foreign_key_violation", .state = "23503", .err = error.ForeignKeyViolation },
            .{ .name = "exclusion_violation", .state = "23P01", .err = error.ExclusionViolation },
            .{ .name = "raise_exception", .state = "P0001", .err = error.RaiseException },
            .{ .name = "no_data_found", .state = "P0002", .err = error.NoDataFound, .message = "query returned no rows" },
            .{ .name = "too_many_rows", .state = "P0003", .err = error.TooManyRows, .message = "query returned more than one row" },
            .{ .name = "assert_failure", .state = "P0004", .err = error.AssertFailure, .message = "assertion failed" },
            .{ .name = "numeric_value_out_of_range", .state = "22003", .err = error.NumericValueOutOfRange },
            .{ .name = "numeric_value_out_of_range", .state = "22003", .err = error.IntegerOverflow },
            .{ .name = "invalid_text_representation", .state = "22P02", .err = error.InvalidTextRepresentation },
            .{ .name = "string_data_right_truncation", .state = "22001", .err = error.StringDataRightTruncation },
            .{ .name = "null_value_not_allowed", .state = "22004", .err = error.NullValueNotAllowed },
            .{ .name = "null_value_not_allowed", .state = "22004", .err = error.NullWindowFrameOffset },
            .{ .name = "case_not_found", .state = "20000", .err = error.CaseNotFound, .message = "case not found" },
            .{ .name = "cardinality_violation", .state = "21000", .err = error.CardinalityViolation },
            .{ .name = "undefined_table", .state = "42P01", .err = error.TableNotFound },
            .{ .name = "undefined_column", .state = "42703", .err = error.ColumnNotFound },
            .{ .name = "undefined_function", .state = "42883", .err = error.UndefinedFunction },
            .{ .name = "datatype_mismatch", .state = "42804", .err = error.TypeMismatch },
            .{ .name = "invalid_parameter_value", .state = "22023", .err = error.InvalidParameterValue },
            .{ .name = "invalid_parameter_value", .state = "22023", .err = error.InvalidSettingValue },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.ProgramLimitExceeded },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.TableCapacity },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.ColumnCapacity },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.RowCapacity },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.NameCapacity },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.TextCapacity },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.WorkspaceCapacity },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.NumericCapacity },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.IndexCapacity },
            .{ .name = "program_limit_exceeded", .state = "54000", .err = error.SessionCapacity },
            .{ .name = "statement_too_complex", .state = "54001", .err = error.StatementTooComplex },
            .{ .name = "statement_too_complex", .state = "54001", .err = error.StackDepthExceeded },
            .{ .name = "out_of_memory", .state = "53200", .err = error.WriteSetCapacity },
            .{ .name = "out_of_memory", .state = "53200", .err = error.LockCapacity },
            .{ .name = "out_of_memory", .state = "53200", .err = error.VersionCapacity },
            .{ .name = "feature_not_supported", .state = "0A000", .err = error.UnsupportedStatement },
            .{ .name = "data_exception", .state = "22000", .err = error.DataException },
            .{ .name = "error_in_assignment", .state = "22005", .err = error.ErrorInAssignment },
            .{ .name = "invalid_datetime_format", .state = "22007", .err = error.InvalidDatetimeFormat },
            .{ .name = "datetime_field_overflow", .state = "22008", .err = error.DatetimeFieldOverflow },
            .{ .name = "invalid_time_zone_displacement_value", .state = "22009", .err = error.InvalidTimeZoneDisplacement },
            .{ .name = "invalid_use_of_escape_character", .state = "2200C", .err = error.InvalidEscapeCharacterUse },
            .{ .name = "sequence_generator_limit_exceeded", .state = "2200H", .err = error.SequenceLimit },
            .{ .name = "not_an_xml_document", .state = "2200L", .err = error.NotAnXmlDocument },
            .{ .name = "invalid_xml_document", .state = "2200M", .err = error.InvalidXmlDocument },
            .{ .name = "invalid_xml_content", .state = "2200N", .err = error.InvalidXmlContent },
            .{ .name = "substring_error", .state = "22011", .err = error.SubstringError },
            .{ .name = "invalid_preceding_or_following_size", .state = "22013", .err = error.InvalidWindowFrameOffset },
            .{ .name = "invalid_argument_for_ntile_function", .state = "22014", .err = error.InvalidArgumentForNtile },
            .{ .name = "interval_field_overflow", .state = "22015", .err = error.IntervalFieldOverflow },
            .{ .name = "invalid_argument_for_nth_value_function", .state = "22016", .err = error.InvalidArgumentForNthValue },
            .{ .name = "invalid_regular_expression", .state = "2201B", .err = error.InvalidRegularExpression },
            .{ .name = "invalid_argument_for_logarithm", .state = "2201E", .err = error.InvalidArgumentForLogarithm },
            .{ .name = "invalid_argument_for_power_function", .state = "2201F", .err = error.InvalidArgumentForPowerFunction },
            .{ .name = "invalid_row_count_in_limit_clause", .state = "2201W", .err = error.InvalidRowCountInLimit },
            .{ .name = "invalid_row_count_in_result_offset_clause", .state = "2201X", .err = error.InvalidRowCountInResultOffset },
            .{ .name = "character_not_in_repertoire", .state = "22021", .err = error.CharacterNotInRepertoire },
            .{ .name = "invalid_escape_sequence", .state = "22025", .err = error.InvalidEscapeSequence },
            .{ .name = "string_data_length_mismatch", .state = "22026", .err = error.StringDataLengthMismatch },
            .{ .name = "array_subscript_error", .state = "2202E", .err = error.ArraySubscriptError },
            .{ .name = "invalid_tablesample_repeat", .state = "2202G", .err = error.InvalidTablesampleRepeat },
            .{ .name = "invalid_tablesample_argument", .state = "2202H", .err = error.InvalidTablesampleArgument },
            .{ .name = "invalid_sql_json_subscript", .state = "22033", .err = error.InvalidSqlJsonSubscript },
            .{ .name = "more_than_one_sql_json_item", .state = "22034", .err = error.MoreThanOneSqlJsonItem },
            .{ .name = "no_sql_json_item", .state = "22035", .err = error.NoSqlJsonItem },
            .{ .name = "non_numeric_sql_json_item", .state = "22036", .err = error.NonNumericSqlJsonItem },
            .{ .name = "singleton_sql_json_item_required", .state = "22038", .err = error.SingletonSqlJsonItemRequired },
            .{ .name = "sql_json_array_not_found", .state = "22039", .err = error.SqlJsonArrayNotFound },
            .{ .name = "sql_json_member_not_found", .state = "2203A", .err = error.SqlJsonMemberNotFound },
            .{ .name = "sql_json_number_not_found", .state = "2203B", .err = error.SqlJsonNumberNotFound },
            .{ .name = "sql_json_object_not_found", .state = "2203C", .err = error.SqlJsonObjectNotFound },
            .{ .name = "sql_json_scalar_required", .state = "2203F", .err = error.SqlJsonScalarRequired },
            .{ .name = "sql_json_item_cannot_be_cast_to_target_type", .state = "2203G", .err = error.SqlJsonItemCannotBeCast },
            .{ .name = "invalid_binary_representation", .state = "22P03", .err = error.InvalidBinaryRepresentation },
            .{ .name = "bad_copy_file_format", .state = "22P04", .err = error.BadCopyFormat },
            .{ .name = "untranslatable_character", .state = "22P05", .err = error.UntranslatableCharacter },
            .{ .name = "active_sql_transaction", .state = "25001", .err = error.ActiveSqlTransaction },
            .{ .name = "read_only_sql_transaction", .state = "25006", .err = error.ReadOnlyTransaction },
            .{ .name = "no_active_sql_transaction", .state = "25P01", .err = error.NoActiveTransaction },
            .{ .name = "invalid_sql_statement_name", .state = "26000", .err = error.StatementNotFound },
            .{ .name = "dependent_objects_still_exist", .state = "2BP01", .err = error.DependentObjects },
            .{ .name = "function_executed_no_return_statement", .state = "2F005", .err = error.FunctionExecutedNoReturn, .message = "control reached end of function without RETURN" },
            .{ .name = "invalid_cursor_name", .state = "34000", .err = error.PortalNotFound },
            .{ .name = "invalid_savepoint_specification", .state = "3B001", .err = error.SavepointNotFound },
            .{ .name = "invalid_schema_name", .state = "3F000", .err = error.UndefinedSchema },
            .{ .name = "serialization_failure", .state = "40001", .err = error.SerializationFailure },
            .{ .name = "deadlock_detected", .state = "40P01", .err = error.DeadlockDetected },
            .{ .name = "insufficient_privilege", .state = "42501", .err = error.InsufficientPrivilege },
            .{ .name = "syntax_error", .state = "42601", .err = error.Syntax },
            .{ .name = "invalid_name", .state = "42602", .err = error.InvalidName },
            .{ .name = "duplicate_column", .state = "42701", .err = error.DuplicateColumn },
            .{ .name = "ambiguous_column", .state = "42702", .err = error.AmbiguousColumn },
            .{ .name = "undefined_object", .state = "42704", .err = error.UndefinedObject },
            .{ .name = "undefined_object", .state = "42704", .err = error.UndefinedSetting },
            .{ .name = "duplicate_object", .state = "42710", .err = error.DuplicateObject },
            .{ .name = "duplicate_function", .state = "42723", .err = error.DuplicateFunction },
            .{ .name = "ambiguous_function", .state = "42725", .err = error.AmbiguousFunction },
            .{ .name = "grouping_error", .state = "42803", .err = error.GroupingError },
            .{ .name = "wrong_object_type", .state = "42809", .err = error.WrongObjectType },
            .{ .name = "invalid_foreign_key", .state = "42830", .err = error.InvalidForeignKey },
            .{ .name = "cannot_coerce", .state = "42846", .err = error.CannotCoerce },
            .{ .name = "generated_always", .state = "428C9", .err = error.GeneratedAlways },
            .{ .name = "reserved_name", .state = "42939", .err = error.ReservedName },
            .{ .name = "undefined_parameter", .state = "42P02", .err = error.UndefinedParameter },
            .{ .name = "duplicate_cursor", .state = "42P03", .err = error.DuplicatePortal },
            .{ .name = "duplicate_prepared_statement", .state = "42P05", .err = error.DuplicateStatement },
            .{ .name = "duplicate_schema", .state = "42P06", .err = error.DuplicateSchema },
            .{ .name = "duplicate_table", .state = "42P07", .err = error.TableExists },
            .{ .name = "invalid_column_reference", .state = "42P10", .err = error.InvalidColumnReference },
            .{ .name = "invalid_function_definition", .state = "42P13", .err = error.InvalidFunctionDefinition },
            .{ .name = "invalid_table_definition", .state = "42P16", .err = error.InvalidTableDefinition },
            .{ .name = "invalid_object_definition", .state = "42P17", .err = error.InvalidObjectDefinition },
            .{ .name = "indeterminate_datatype", .state = "42P18", .err = error.IndeterminateDatatype },
            .{ .name = "windowing_error", .state = "42P20", .err = error.WindowingError },
            .{ .name = "collation_mismatch", .state = "42P21", .err = error.CollationMismatch },
            .{ .name = "object_not_in_prerequisite_state", .state = "55000", .err = error.ObjectNotInPrerequisiteState },
            .{ .name = "object_not_in_prerequisite_state", .state = "55000", .err = error.SequenceNotReady },
            .{ .name = "object_in_use", .state = "55006", .err = error.ObjectInUse },
            .{ .name = "lock_not_available", .state = "55P03", .err = error.LockNotAvailable },
            .{ .name = "query_canceled", .state = "57014", .err = error.QueryCanceled },
            .{ .name = "invalid_grant_operation", .state = "0LP01", .err = error.InvalidGrantOperation },
            .{ .name = "stacked_diagnostics_accessed_without_active_handler", .state = "0Z002", .err = error.StackedDiagnosticsAccessedWithoutActiveHandler },
            .{ .name = "invalid_transaction_termination", .state = "2D000", .err = error.InvalidTransactionTermination },
        };

        /// What a handler sees of the error it caught (SQLSTATE, SQLERRM and
        /// GET STACKED DIAGNOSTICS). RAISE and ASSERT fill one in the host
        /// (routineRaise) before raising; other errors are described from
        /// the conditions table (routineDiagnostics).
        pub const Diagnostics = struct {
            active: bool = false,
            err: Error = error.RaiseException,
            state: [5]u8 = "P0001".*,
            message: V.Text = .{},
            detail: V.Text = .{},
            hint: V.Text = .{},
            column: V.Text = .{},
            constraint: V.Text = .{},
            datatype: V.Text = .{},
            table: V.Text = .{},
            schema: V.Text = .{},

            /// The error's own description (no RAISE text).
            pub fn describe(err: Error, out: *Diagnostics) void {
                out.* = .{ .err = err };
                const found = errorIndex(err);
                out.state = if (found) |index| conditions[index].state[0..5].* else "XX000".*;
                const message = if (found) |index| (if (conditions[index].message.len != 0) conditions[index].message else @errorName(err)) else @errorName(err);
                setText(&out.message, message);
            }
        };

        pub fn setText(out: *V.Text, bytes: []const u8) void {
            const length = @min(bytes.len, config.text_bytes);
            @memcpy(out.bytes[0..length], bytes[0..length]);
            out.len = length;
        }

        fn errorIndex(err: Error) ?usize {
            for (conditions, 0..) |entry, index| if (entry.err == err) return index;
            return null;
        }

        /// A condition's SQLSTATE matches the error's own, or its class when
        /// the condition is a class (`data_exception`, SQLSTATE '22000').
        fn stateCovers(condition: []const u8, err: Error) bool {
            const index = errorIndex(err) orelse return false;
            const state = conditions[index].state;
            if (types.same(condition, state)) return true;
            return types.same(condition[2..5], "000") and types.same(condition[0..2], state[0..2]);
        }

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
                /// Its description (GET STACKED DIAGNOSTICS, re-RAISE).
                diag: ?*const Diagnostics = null,
                /// A set-returning function (B11 wave 4): RETURN NEXT emits
                /// a row through `rows` (the expression, or the OUT / TABLE
                /// variables `outputs` in result-column order).
                retset: bool = false,
                outputs: [config.routine_args]u8 = undefined,
                output_count: usize = 0,
                rows: ?Emit = null,
                /// Blocks with an EXCEPTION clause around the running
                /// statement (transaction control is 2D000 inside one).
                atomic_depth: usize = 0,

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
                    if (c.is("commit") or c.is("rollback")) return self.transactionStatement(mode);
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

                const Stops = struct { then: bool = false, loop: bool = false, comma: bool = false, dots: bool = false, when: bool = false, into: bool = false, semicolon: bool = true, using: bool = false };

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
                            if (stops.using and c.is("using")) break;
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
                    // A block with handlers is a subtransaction: COMMIT and
                    // ROLLBACK are not allowed inside it (PostgreSQL 2D000).
                    const atomic = mode == .run and (self.purpose == .procedure or self.purpose == .do_block) and try self.hasHandlers();
                    if (atomic) self.atomic_depth += 1;
                    defer if (atomic) {
                        self.atomic_depth -= 1;
                    };
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
                                        // OTHERS excludes ASSERT_FAILURE (and QUERY_CANCELED).
                                        matches = matches or (caught != null and caught.? != error.AssertFailure);
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
                                signal = try self.handler(caught.?);
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
                    return stateCovers(state, err);
                }

                fn nameMatches(name: []const u8, err: Error) bool {
                    for (conditions) |entry| if (types.same(entry.name, name) and stateCovers(entry.state, err)) return true;
                    return false;
                }

                /// Runs a matching handler: SQLSTATE and SQLERRM are its own
                /// variables and GET STACKED DIAGNOSTICS reads `diag`. Kept
                /// out of block() so only a running handler holds them.
                noinline fn handler(self: *Self, err: Error) Error!Signal {
                    var diag: Diagnostics = undefined;
                    self.host.routineDiagnostics(err, &diag);
                    const previous_diag = self.diag;
                    const previous = self.handling;
                    self.diag = &diag;
                    self.handling = err;
                    const saved = self.frame.variables.count;
                    defer {
                        self.diag = previous_diag;
                        self.handling = previous;
                        self.frame.variables.count = saved;
                    }
                    const state = try self.frame.declare("sqlstate", .text, -1);
                    var cell: V.Cell = .{ .text = .{} };
                    setText(&cell.text, &diag.state);
                    self.frame.cells[state] = cell;
                    const message = try self.frame.declare("sqlerrm", .text, -1);
                    self.frame.cells[message] = .{ .text = diag.message };
                    return self.statementList(.run);
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
                    if (c.is("next")) return self.returnNext(mode);
                    if (c.is("query")) return self.returnQuery(mode);
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

                /// Whether the block at the cursor (after BEGIN) has an
                /// EXCEPTION clause: its statements are scanned, not run.
                fn hasHandlers(self: *Self) Error!bool {
                    const saved = self.cursor;
                    defer self.cursor = saved;
                    _ = try self.statementList(.skip);
                    return self.cursor.is("exception");
                }

                /// COMMIT / ROLLBACK [AND [NO] CHAIN] in a procedure or DO
                /// block: the host decides (2D000 where PostgreSQL forbids
                /// it; the allowed case needs a commit inside the running
                /// statement, which the store does not offer: 0A000).
                noinline fn transactionStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.advance();
                    _ = try c.take("transaction") or try c.take("work");
                    if (try c.take("and")) {
                        _ = try c.take("no");
                        try c.expect("chain");
                    }
                    try c.expectSymbol(.semicolon);
                    if (mode != .run) return .normal;
                    if (self.purpose != .procedure and self.purpose != .do_block) return error.InvalidTransactionTermination;
                    try self.host.routineTransaction(self.atomic_depth != 0);
                    return .normal;
                }

                /// RETURN NEXT [expression]: one more row of a set-returning
                /// function (42804 outside one, or with an expression beside
                /// OUT parameters; 42601 without one and without them).
                noinline fn returnNext(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("next");
                    if (self.purpose != .function or !self.retset) return error.TypeMismatch;
                    var row: [config.routine_args]V.Cell = undefined;
                    if (c.symbol(.semicolon)) {
                        try c.advance();
                        if (self.output_count == 0) return error.Syntax;
                        if (mode != .run) return .normal;
                        for (self.outputs[0..self.output_count], 0..) |variable, column| row[column] = self.frame.cells[variable];
                    } else {
                        if (self.output_count != 0) return error.TypeMismatch;
                        const span = try self.expression(.{});
                        try c.expectSymbol(.semicolon);
                        if (mode != .run) {
                            _ = try self.evaluate(span, mode, null);
                            return .normal;
                        }
                        const value = try self.evaluate(span, .run, &self.return_column);
                        row[0] = try D.store(&self.return_column, value, self.host.routineSession());
                    }
                    const sink = self.rows orelse return error.UnsupportedStatement;
                    try sink.call(sink.ptr, &row);
                    return .normal;
                }

                /// RETURN QUERY runs a query inside the running statement:
                /// checked at CREATE, 0A000 when run (nested statement
                /// execution is not available to functions here).
                noinline fn returnQuery(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("query");
                    if (self.purpose != .function or !self.retset) return error.TypeMismatch;
                    if (c.is("execute")) return error.UnsupportedStatement;
                    const begin = c.start();
                    var depth: usize = 0;
                    while (!c.atEnd()) {
                        if (c.symbol(.lparen)) depth += 1;
                        if (c.symbol(.rparen) and depth > 0) depth -= 1;
                        if (depth == 0 and c.symbol(.semicolon)) break;
                        try c.advance();
                    }
                    if (c.atEnd()) return error.Syntax;
                    const end = c.start();
                    try c.expectSymbol(.semicolon);
                    switch (mode) {
                        .check => try self.host.routineCheckStatement(self.source[begin..end]),
                        .run => return error.UnsupportedStatement,
                        .skip => {},
                    }
                    return .normal;
                }

                noinline fn raiseStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("raise");
                    if (c.symbol(.semicolon)) {
                        try c.advance();
                        if (mode == .run) {
                            // Re-raise: the caught error keeps its description.
                            const err = self.handling orelse return error.Syntax;
                            if (self.diag) |diag| self.host.routineRaise(diag);
                            return err;
                        }
                        return .normal;
                    }
                    var exception = true;
                    inline for (.{ "debug", "log", "info", "notice", "warning" }) |level| {
                        if (c.is(level)) exception = false;
                    }
                    if (!exception or c.is("exception")) try c.advance();
                    // Only a raised error's description is kept (no notice channel).
                    const describe = mode == .run and exception;
                    var diag: Diagnostics = .{ .active = true };
                    var raised: Error = error.RaiseException;
                    var has_message = false;
                    var condition_text: ?[]const u8 = null;
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
                        var spans: [config.routine_args]Span = undefined;
                        while (try c.takeSymbol(.comma)) {
                            const span = try self.expression(.{ .comma = true, .using = true });
                            if (given < spans.len) spans[given] = span;
                            given += 1;
                        }
                        if (given != placeholders) return error.Syntax;
                        if (given > spans.len) return error.ColumnCapacity;
                        has_message = true;
                        if (describe) {
                            try self.format(buffer[0..len], spans[0..given], &diag.message);
                        } else for (spans[0..given]) |span| {
                            _ = try self.evaluate(span, mode, null);
                        }
                    } else if (try c.take("sqlstate")) {
                        var buffer: [8]u8 = undefined;
                        const len = try c.string(&buffer);
                        if (len != 5) return error.Syntax;
                        const found = stateIndex(buffer[0..5]) orelse return error.UnsupportedStatement;
                        raised = conditions[found].err;
                        diag.state = buffer[0..5].*;
                        setText(&diag.message, buffer[0..5]);
                        has_message = true;
                    } else if (c.current.kind == .word and !c.is("using")) {
                        const condition = try c.identifier();
                        const found = conditionIndex(condition.slice()) orelse return error.UndefinedObject;
                        raised = conditions[found].err;
                        condition_text = conditions[found].name;
                        diag.state = conditions[found].state[0..5].*;
                    }
                    if (try c.take("using")) while (true) {
                        const option = try c.anyIdentifier();
                        if (!try c.takeSymbol(.eq)) {
                            if (!try self.assignOperator()) return error.Syntax;
                        }
                        const span = try self.expression(.{ .comma = true });
                        const o = option.slice();
                        if (types.same(o, "errcode")) {
                            // A literal condition name or SQLSTATE.
                            var probe = try Cursor.init(self.source[0..span.end], span.start);
                            var buffer: [64]u8 = undefined;
                            const len = probe.string(&buffer) catch return error.UnsupportedStatement;
                            const by_name = conditionIndex(buffer[0..len]);
                            const by_state: ?usize = if (len == 5) stateIndex(buffer[0..5]) else null;
                            const found = by_name orelse by_state orelse return if (len == 5) error.UnsupportedStatement else error.UndefinedObject;
                            raised = conditions[found].err;
                            diag.state = if (by_name == null) buffer[0..5].* else conditions[found].state[0..5].*;
                        } else {
                            const field: ?*V.Text = if (types.same(o, "message")) &diag.message else if (types.same(o, "detail")) &diag.detail else if (types.same(o, "hint")) &diag.hint else if (types.same(o, "column")) &diag.column else if (types.same(o, "constraint")) &diag.constraint else if (types.same(o, "datatype")) &diag.datatype else if (types.same(o, "table")) &diag.table else if (types.same(o, "schema")) &diag.schema else null;
                            const out = field orelse return error.UnsupportedStatement;
                            // MESSAGE beside a format string is 42601.
                            if (types.same(o, "message") and has_message) return error.Syntax;
                            if (describe) {
                                const text_column: V.Column = .{ .data_type = .text };
                                const value = try self.evaluate(span, mode, &text_column);
                                // A NULL option is 22004 in PostgreSQL.
                                if (value != .text) return error.NullValueNotAllowed;
                                out.* = value.text;
                            } else _ = try self.evaluate(span, mode, null);
                            if (types.same(o, "message")) has_message = true;
                        }
                        if (!try c.takeSymbol(.comma)) break;
                    };
                    try c.expectSymbol(.semicolon);
                    if (describe) {
                        diag.err = raised;
                        // Without a message: the condition name, else the SQLSTATE.
                        if (!has_message) {
                            if (condition_text) |name| setText(&diag.message, name) else if (raised == error.RaiseException and types.same(&diag.state, "P0001")) setText(&diag.message, "raise_exception") else setText(&diag.message, &diag.state);
                        }
                        self.host.routineRaise(&diag);
                        return raised;
                    }
                    return .normal;
                }

                /// RAISE's message: each `%` takes the next argument's text
                /// (`<NULL>` for NULL), `%%` is a literal `%`.
                fn format(self: *Self, pattern: []const u8, spans: []const Span, out: *V.Text) Error!void {
                    out.* = .{};
                    var used: usize = 0;
                    var next: usize = 0;
                    var at: usize = 0;
                    const text_column: V.Column = .{ .data_type = .text };
                    while (at < pattern.len) : (at += 1) {
                        var piece: []const u8 = pattern[at .. at + 1];
                        var value: V.Cell = .null_value;
                        if (pattern[at] == '%') {
                            if (at + 1 < pattern.len and pattern[at + 1] == '%') {
                                at += 1;
                            } else {
                                value = try self.evaluate(spans[next], .run, &text_column);
                                next += 1;
                                piece = if (value == .text) value.text.slice() else "<NULL>";
                            }
                        }
                        if (piece.len > out.bytes.len - used) return error.TextCapacity;
                        @memcpy(out.bytes[used..][0..piece.len], piece);
                        used += piece.len;
                    }
                    out.len = used;
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
                    // NULL or false: assert_failure (P0004), with the message
                    // (its text) or PostgreSQL's "assertion failed".
                    if (value == .boolean and value.boolean) return .normal;
                    return self.assertFailed(message);
                }

                noinline fn assertFailed(self: *Self, message: ?Span) Error {
                    var diag: Diagnostics = .{ .active = true, .err = error.AssertFailure, .state = "P0004".* };
                    setText(&diag.message, "assertion failed");
                    if (message) |span| {
                        const text_column: V.Column = .{ .data_type = .text };
                        const text = try self.evaluate(span, .run, &text_column);
                        if (text == .text) diag.message = text.text;
                    }
                    self.host.routineRaise(&diag);
                    return error.AssertFailure;
                }

                /// GET [CURRENT] DIAGNOSTICS (ROW_COUNT) and GET STACKED
                /// DIAGNOSTICS inside a handler (the caught error's SQLSTATE,
                /// message, detail, hint and RAISE USING names; 0Z002 outside
                /// a handler). PG_CONTEXT, PG_EXCEPTION_CONTEXT and
                /// PG_ROUTINE_OID are 0A000.
                fn diagnosticsStatement(self: *Self, mode: Mode) Error!Signal {
                    const c = &self.cursor;
                    try c.expect("get");
                    const stacked = try c.take("stacked");
                    if (!stacked) _ = try c.take("current");
                    try c.expect("diagnostics");
                    if (stacked and mode == .run and self.diag == null) return error.StackedDiagnosticsAccessedWithoutActiveHandler;
                    while (true) {
                        const place = try self.target(mode);
                        if (!try c.takeSymbol(.eq)) {
                            if (!try self.assignOperator()) return error.Syntax;
                        }
                        const item = try c.anyIdentifier();
                        const i = item.slice();
                        if (!stacked) {
                            if (!types.same(i, "row_count")) return if (types.same(i, "pg_context") or types.same(i, "pg_routine_oid")) error.UnsupportedStatement else error.Syntax;
                            if (mode == .run) try self.storeCast(place, .{ .integer = @intCast(self.frame.row_count) }, .int8);
                        } else {
                            if (types.same(i, "pg_exception_context")) return error.UnsupportedStatement;
                            const diag = self.diag;
                            const value: ?*const V.Text = if (diag == null) null else if (types.same(i, "message_text")) &diag.?.message else if (types.same(i, "pg_exception_detail")) &diag.?.detail else if (types.same(i, "pg_exception_hint")) &diag.?.hint else if (types.same(i, "column_name")) &diag.?.column else if (types.same(i, "constraint_name")) &diag.?.constraint else if (types.same(i, "pg_datatype_name")) &diag.?.datatype else if (types.same(i, "table_name")) &diag.?.table else if (types.same(i, "schema_name")) &diag.?.schema else null;
                            const known = types.same(i, "returned_sqlstate") or types.same(i, "message_text") or types.same(i, "pg_exception_detail") or types.same(i, "pg_exception_hint") or types.same(i, "column_name") or types.same(i, "constraint_name") or types.same(i, "pg_datatype_name") or types.same(i, "table_name") or types.same(i, "schema_name");
                            if (!known) return error.Syntax;
                            if (mode == .run) {
                                var cell: V.Cell = .{ .text = .{} };
                                if (value) |text| cell.text = text.* else setText(&cell.text, &diag.?.state);
                                try self.storeCast(place, cell, .text);
                            }
                        }
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
