//! Evaluation of the JSONB modification, conversion and SQL/JSON path
//! functions (Layer 0, B11 json-agg lane), after jsonfuncs.c, jsonb.c,
//! json.c and jsonpath_exec.c:
//!   jsonb_set, jsonb_set_lax, jsonb_insert, jsonb_delete_path and #-,
//!   jsonb - text | integer | text[], ?| and ?&, jsonb_strip_nulls,
//!   jsonb_pretty, to_json, to_jsonb, jsonb_path_exists / match /
//!   query_array / query_first and the @? / @@ operators.
//!
//! `JsonEval(config, E)` is instantiated by expr.sig's `Eval` (`E`). Every
//! result is a fresh cell (Config.text_bytes; TextCapacity beyond). Text
//! array paths hold one element per JSONB nesting level that a setPath
//! can reach; a two-dimensional path is 2202E, a NULL element 22004 where
//! it is reached and a non-integer one over an array 22P02.
const types = @import("types.sig");
const ast = @import("ast.sig");
const value = @import("value.sig");
const jsonb = @import("jsonb.sig");
const json_build = @import("json_build.sig");
const jsonpath = @import("jsonpath.sig");
const Error = types.Error;
const none = ast.none;

pub fn JsonEval(comptime config: types.Config, comptime E: type) type {
    const V = types.Values(config);
    const A = V.Arrays;
    const Io = value.Io(config);
    const J = Io.Documents;
    const JB = json_build.JsonBuild(config);
    const JP = jsonpath.Engine(config);
    return struct {
        fn node(ctx: *const E.Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        /// The call's evaluated arguments (at most six).
        const Args = struct {
            cells: [6]V.Cell = undefined,
            count: usize = 0,
            any_null: bool = false,
        };

        fn arguments(ctx: *const E.Context, n: *const ast.Node, args: *Args) Error!void {
            var item = n.b;
            while (item != none) : (item = node(ctx, item).next) {
                if (args.count == args.cells.len) return error.UndefinedFunction;
                args.cells[args.count] = try E.eval(ctx, item);
                if (args.cells[args.count] == .null_value) args.any_null = true;
                args.count += 1;
            }
        }

        fn jsonbCell(buffer: *const J.Buffer) Error!V.Cell {
            if (buffer.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = buffer.len };
            @memcpy(text.bytes[0..buffer.len], buffer.bytes[0..buffer.len]);
            return .{ .jsonb = text };
        }

        fn scalarRoot(bytes: []const u8) bool {
            return bytes[0] != @intFromEnum(jsonb.Tag.array) and bytes[0] != @intFromEnum(jsonb.Tag.object);
        }

        const max_keys = config.text_bytes / 3 + 1;

        /// A text[] argument as slices; 2202E when `flat` and it has more
        /// than one dimension.
        fn textArray(cell: *const V.Cell, out: []?[]const u8, flat: bool) Error!usize {
            const bytes = cell.array.slice();
            if (flat and A.shape(bytes).ndim > 1) return error.ArraySubscriptError;
            return A.textSlices(bytes, out);
        }

        pub fn call(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            if (n.planned_null) return .null_value;
            var args: Args = .{};
            try arguments(ctx, n, &args);
            const control = ctx.session.control;
            switch (n.func) {
                .jsonb_set, .jsonb_insert, .jsonb_delete_path, .jsonb_delete_path_op => {
                    if (args.any_null) return .null_value;
                    const target = args.cells[0].jsonb.slice();
                    var path: [J.max_path]?[]const u8 = undefined;
                    const path_len = try textArray(&args.cells[1], &path, true);
                    const deleting = n.func == .jsonb_delete_path or n.func == .jsonb_delete_path_op;
                    if (scalarRoot(target)) return error.InvalidParameterValue;
                    const flag = args.count > 3 and args.cells[3].boolean;
                    const create = n.func != .jsonb_set or args.count < 4 or flag;
                    if (n.func == .jsonb_set and jsonb.countAt(target, 0) == 0 and !create) return args.cells[0];
                    if (deleting and jsonb.countAt(target, 0) == 0) return args.cells[0];
                    if (path_len == 0) return args.cells[0];
                    const op: J.PathOp = switch (n.func) {
                        .jsonb_set => if (create) .create else .replace,
                        .jsonb_insert => if (flag) .insert_after else .insert_before,
                        else => .delete,
                    };
                    var out: J.Buffer = .{};
                    try J.setPath(target, path[0..@min(path_len, path.len)], path_len, op, if (deleting) "" else args.cells[2].jsonb.slice(), &out, control);
                    return jsonbCell(&out);
                },
                .jsonb_set_lax => {
                    // Not strict: target, path or create NULL give NULL; a
                    // NULL treatment is 22023; a NULL value follows it.
                    const create_null = args.count > 3 and args.cells[3] == .null_value;
                    if (args.cells[0] == .null_value or args.cells[1] == .null_value or create_null) return .null_value;
                    if (args.count > 4 and args.cells[4] == .null_value) return error.InvalidParameterValue;
                    const target = args.cells[0].jsonb.slice();
                    var path: [J.max_path]?[]const u8 = undefined;
                    const path_len = try textArray(&args.cells[1], &path, true);
                    if (scalarRoot(target)) return error.InvalidParameterValue;
                    const create = args.count < 4 or args.cells[3].boolean;
                    var op: J.PathOp = if (create) .create else .replace;
                    var new_value: []const u8 = "";
                    const json_null = [1]u8{@intFromEnum(jsonb.Tag.null_value)};
                    if (args.cells[2] != .null_value) {
                        new_value = args.cells[2].jsonb.slice();
                    } else {
                        const treatment: []const u8 = if (args.count > 4) args.cells[4].text.slice() else "use_json_null";
                        if (types.same(treatment, "raise_exception")) return error.NullValueNotAllowed;
                        if (types.same(treatment, "return_target")) return args.cells[0];
                        if (types.same(treatment, "use_json_null")) {
                            new_value = &json_null;
                        } else if (types.same(treatment, "delete_key")) {
                            op = .delete;
                        } else return error.InvalidParameterValue;
                    }
                    if (op != .delete and jsonb.countAt(target, 0) == 0 and !create) return args.cells[0];
                    if (op == .delete and jsonb.countAt(target, 0) == 0) return args.cells[0];
                    if (path_len == 0) return args.cells[0];
                    var out: J.Buffer = .{};
                    try J.setPath(target, path[0..@min(path_len, path.len)], path_len, op, new_value, &out, control);
                    return jsonbCell(&out);
                },
                .jsonb_minus_op => {
                    if (args.any_null) return .null_value;
                    const target = args.cells[0].jsonb.slice();
                    var out: J.Buffer = .{};
                    switch (args.cells[1]) {
                        .integer => |index| try J.deleteIndex(target, index, &out, control),
                        .text => |*key| {
                            const keys = [1]?[]const u8{key.slice()};
                            try J.deleteKeys(target, &keys, &out, control);
                        },
                        else => {
                            var keys: [max_keys]?[]const u8 = undefined;
                            const count = try textArray(&args.cells[1], &keys, true);
                            if (scalarRoot(target)) return error.InvalidParameterValue;
                            if (count == 0) return args.cells[0];
                            try J.deleteKeys(target, keys[0..@min(count, keys.len)], &out, control);
                        },
                    }
                    return jsonbCell(&out);
                },
                .jsonb_exists_any, .jsonb_exists_all, .jsonb_exists_any_op, .jsonb_exists_all_op => {
                    if (args.any_null) return .null_value;
                    const target = args.cells[0].jsonb.slice();
                    var keys: [max_keys]?[]const u8 = undefined;
                    const count = try textArray(&args.cells[1], &keys, false);
                    const any = n.func == .jsonb_exists_any or n.func == .jsonb_exists_any_op;
                    for (keys[0..@min(count, keys.len)]) |key| {
                        const text = key orelse continue;
                        if (control) |c| try c.checkpoint();
                        const found = J.exists(target, text);
                        if (any and found) return .{ .boolean = true };
                        if (!any and !found) return .{ .boolean = false };
                    }
                    return .{ .boolean = !any };
                },
                .jsonb_strip_nulls => {
                    if (args.any_null) return .null_value;
                    var out: J.Buffer = .{};
                    try J.stripNulls(args.cells[0].jsonb.slice(), 0, args.count > 1 and args.cells[1].boolean, &out, control);
                    return jsonbCell(&out);
                },
                .jsonb_pretty => {
                    if (args.any_null) return .null_value;
                    var text: V.Text = .{};
                    var out: J.Text = .{ .bytes = &text.bytes };
                    try J.pretty(args.cells[0].jsonb.slice(), 0, &out, 0, false, control);
                    text.len = out.len;
                    return .{ .text = text };
                },
                .to_json, .to_jsonb => {
                    if (args.any_null) return .null_value;
                    var buffer: [JB.buffer_bytes]u8 = undefined;
                    var out: json_build.Out = .{ .bytes = &buffer };
                    const jsonb_result = n.func == .to_jsonb;
                    try JB.append(&out, &args.cells[0], node(ctx, n.b).ty, false, jsonb_result, ctx.session);
                    return if (jsonb_result) JB.jsonbOf(&out, ctx.session) else JB.jsonOf(&out);
                },
                .jsonb_path_exists, .jsonb_path_match, .jsonb_path_query_array, .jsonb_path_query_first, .jsonb_path_exists_op, .jsonb_path_match_op => {
                    if (args.any_null) return .null_value;
                    const silent = n.func == .jsonb_path_exists_op or n.func == .jsonb_path_match_op or (args.count > 3 and args.cells[3].boolean);
                    const vars: ?[]const u8 = if (args.count > 2) args.cells[2].jsonb.slice() else null;
                    return pathCall(n.func, args.cells[0].jsonb.slice(), args.cells[1].text.slice(), vars, silent, ctx.session);
                },
                else => return error.UnsupportedStatement,
            }
        }

        const Collect = struct {
            mode: enum { exists, match, array, first },
            out: *J.Buffer,
            count: usize = 0,
            first_tag: jsonb.Tag = .null_value,
        };

        fn collectEmit(raw: ?*anyopaque, item: JP.Item) Error!bool {
            const state: *Collect = @ptrCast(@alignCast(raw.?));
            state.count += 1;
            switch (state.mode) {
                .exists => return true,
                .match => {
                    if (state.count == 1) state.first_tag = JP.tagOf(item);
                    return state.count > 1;
                },
                .array, .first => {
                    try state.out.append(item.bytes[item.at..][0..jsonb.sizeAt(item.bytes, item.at)]);
                    return state.mode == .first;
                },
            }
        }

        /// One SQL/JSON path evaluation (jsonb_path_* and @? / @@): a
        /// silent call turns suppressible errors into NULL.
        pub fn pathCall(func: ast.Func, document: []const u8, text: []const u8, vars: ?[]const u8, silent: bool, session: *const value.Session) Error!V.Cell {
            var path: JP.P = undefined;
            try path.parse(text, session.control);
            var context: JP.Context = undefined;
            try JP.init(&context, &path, document, vars, session.control, session);
            var out: J.Buffer = .{};
            var header: usize = 0;
            var state: Collect = .{ .out = &out, .mode = switch (func) {
                .jsonb_path_exists, .jsonb_path_exists_op => .exists,
                .jsonb_path_match, .jsonb_path_match_op => .match,
                .jsonb_path_query_array => .array,
                else => .first,
            } };
            if (state.mode == .array) header = try J.beginContainer(&out, false);
            const sink: JP.Sink = .{ .context = &state, .emit = collectEmit };
            _ = JP.run(&context, &sink) catch |err| {
                if (silent and jsonpath.suppressible(err)) return .null_value;
                return err;
            };
            switch (state.mode) {
                .exists => return .{ .boolean = state.count != 0 },
                .match => {
                    if (state.count == 1) switch (state.first_tag) {
                        .true_value => return .{ .boolean = true },
                        .false_value => return .{ .boolean = false },
                        .null_value => return .null_value,
                        else => {},
                    };
                    if (silent) return .null_value;
                    return error.SingletonSqlJsonItemRequired;
                },
                .array => {
                    try J.endContainer(&out, header, state.count);
                    var canonical: J.Buffer = .{};
                    try J.canonicalize(out.bytes[0..out.len], &canonical, session.control);
                    return jsonbCell(&canonical);
                },
                .first => {
                    if (state.count == 0) return .null_value;
                    return jsonbCell(&out);
                },
            }
        }

        // ---- JSON_TABLE (B11 json-agg lane) ---------------------------------

        pub const RowSink = struct {
            context: *anyopaque,
            row: *const fn (*anyopaque, []const V.Cell) Error!void,
        };

        /// Errors a column's ON ERROR behavior (and the table's EMPTY ON
        /// ERROR for the row path) handles: SQL/JSON errors and the
        /// conversion errors of the column type's input function. A missing
        /// variable, capacities and cancellation always propagate.
        pub fn catchable(err: Error) bool {
            if (jsonpath.suppressible(err)) return true;
            return switch (err) {
                error.InvalidTextRepresentation, error.StringDataRightTruncation, error.IntegerOverflow, error.InvalidDatetimeFormat,
                error.DatetimeFieldOverflow, error.IntervalFieldOverflow, error.MoreThanOneSqlJsonItem, error.SqlJsonScalarRequired,
                error.NoSqlJsonItem, error.InvalidParameterValue, error.CannotCoerce, error.StringDataLengthMismatch => true,
                else => false,
            };
        }

        const TableState = struct {
            ctx: *const E.Context,
            table: *const ast.Node,
            names: []const V.Name,
            tys: []const types.Type,
            typmods: []const i32,
            vars: ?[]const u8,
            sink: RowSink,
            error_on_error: bool,
            ordinal: i64 = 0,
            rows: usize = 0,
        };

        fn countEmit(raw: ?*anyopaque, _: JP.Item) Error!bool {
            const state: *TableState = @ptrCast(@alignCast(raw.?));
            state.rows += 1;
            return false;
        }

        fn rowEmit(raw: ?*anyopaque, item: JP.Item) Error!bool {
            const state: *TableState = @ptrCast(@alignCast(raw.?));
            state.ordinal += 1;
            var cells: [config.columns]V.Cell = undefined;
            var column: usize = 0;
            var member = state.table.b;
            while (member != none) : (member = node(state.ctx, member).next) {
                const n = node(state.ctx, member);
                if (n.func != .json_table_column) continue;
                cells[column] = try columnValue(state, n, item, state.names[column].slice(), state.tys[column], state.typmods[column]);
                column += 1;
            }
            try state.sink.row(state.sink.context, cells[0..column]);
            return false;
        }

        /// An identifier as written: unquoted folds to lower case; quoted
        /// keeps its case and collapses `""`.
        fn identifier(ctx: *const E.Context, ident: ast.Ident, out: *[64]u8) Error![]const u8 {
            const raw = ident.span.slice(ctx.source);
            var len: usize = 0;
            var index: usize = 0;
            while (index < raw.len) : (index += 1) {
                if (len == out.len) return error.NameCapacity;
                var c = raw[index];
                if (ident.quoted) {
                    if (c == '"' and index + 1 < raw.len and raw[index + 1] == '"') index += 1;
                } else c = types.lower(c);
                out[len] = c;
                len += 1;
            }
            return out[0..len];
        }

        /// The rows of JSON_TABLE node `id`: the row path over the context
        /// item (PASSING values as variables); per item every column in
        /// order. A row path error gives no rows (EMPTY ON ERROR, the
        /// default) or propagates (ERROR ON ERROR); it is found by a first
        /// counting pass, so no partial rows are ever produced.
        pub fn jsonTable(ctx: *const E.Context, id: u16, names: []const V.Name, tys: []const types.Type, typmods: []const i32, sink: RowSink) Error!void {
            const table = node(ctx, id);
            const document = try E.eval(ctx, table.a);
            if (document == .null_value) return;
            const path_cell = try E.eval(ctx, table.c);
            if (path_cell == .null_value) return;
            const control = ctx.session.control;
            // PASSING values as a jsonb object (to_jsonb of each value).
            var vars_cell: V.Cell = .null_value;
            var member = table.b;
            var any_passing = false;
            var buffer: [JB.buffer_bytes]u8 = undefined;
            var out: json_build.Out = .{ .bytes = &buffer };
            try out.byte('{');
            while (member != none) : (member = node(ctx, member).next) {
                const n = node(ctx, member);
                if (n.func != .json_table_passing) continue;
                if (any_passing) try out.append(", ");
                any_passing = true;
                var name_buffer: [64]u8 = undefined;
                try json_build.escaped(&out, try identifier(ctx, n.name, &name_buffer));
                try out.append(": ");
                const passed = try E.eval(ctx, n.b);
                try JB.append(&out, &passed, node(ctx, n.b).ty, false, true, ctx.session);
            }
            try out.byte('}');
            if (any_passing) vars_cell = try JB.jsonbOf(&out, ctx.session);
            const vars: ?[]const u8 = if (vars_cell == .jsonb) vars_cell.jsonb.slice() else null;
            var path: JP.P = undefined;
            try path.parse(path_cell.text.slice(), control);
            var state: TableState = .{ .ctx = ctx, .table = table, .names = names, .tys = tys, .typmods = typmods, .vars = vars, .sink = sink, .error_on_error = table.integer & 1 != 0 };
            {
                var counting: JP.Context = undefined;
                try JP.init(&counting, &path, document.jsonb.slice(), vars, control, ctx.session);
                const counter: JP.Sink = .{ .context = &state, .emit = countEmit };
                _ = JP.run(&counting, &counter) catch |err| {
                    if (!state.error_on_error and jsonpath.suppressible(err)) return;
                    return err;
                };
            }
            if (state.rows == 0) return;
            var rows: JP.Context = undefined;
            try JP.init(&rows, &path, document.jsonb.slice(), vars, control, ctx.session);
            const emitter: JP.Sink = .{ .context = &state, .emit = rowEmit };
            _ = try JP.run(&rows, &emitter);
        }

        fn columnValue(state: *TableState, n: *const ast.Node, item: JP.Item, name: []const u8, ty: types.Type, typmod: i32) Error!V.Cell {
            const spec = ast.JsonTableColumn.decode(n.integer);
            if (spec.kind == .ordinality) return .{ .integer = state.ordinal };
            var on_error = spec.on_error;
            if (on_error == .unspecified) on_error = if (state.error_on_error) .error_value else if (spec.kind == .exists) .false_value else .null_value;
            const produced = columnResult(state, n, &spec, item, name, ty, typmod) catch |err| {
                if (!catchable(err) or on_error == .error_value) return err;
                return behavior(state, n.c, on_error, ty, typmod);
            };
            if (produced) |cell| return cell;
            // Empty: ON EMPTY (NULL by default); its ERROR is itself handled
            // by ON ERROR unless that is ERROR (ExecEvalJsonExprPath).
            const on_empty = if (spec.on_empty == .unspecified) ast.JsonTableColumn.Behavior.null_value else spec.on_empty;
            if (on_empty == .error_value) {
                if (on_error == .error_value) return error.NoSqlJsonItem;
                return behavior(state, n.c, on_error, ty, typmod);
            }
            return behavior(state, n.b, on_empty, ty, typmod);
        }

        fn behavior(state: *TableState, default_id: u16, kind: ast.JsonTableColumn.Behavior, ty: types.Type, typmod: i32) Error!V.Cell {
            return switch (kind) {
                .unspecified, .null_value, .unknown => .null_value,
                .error_value => error.NoSqlJsonItem,
                .default_value => E.eval(state.ctx, default_id),
                .empty_array => convertText("[]", ty, typmod, state.ctx.session),
                .empty_object => convertText("{}", ty, typmod, state.ctx.session),
                .true_value, .false_value => booleanValue(kind == .true_value, ty, typmod, state.ctx.session),
            };
        }

        fn booleanValue(truth: bool, ty: types.Type, typmod: i32, session: *const value.Session) Error!V.Cell {
            if (ty == .boolean) return .{ .boolean = truth };
            if (value.integral(ty)) return .{ .integer = @intFromBool(truth) };
            return convertText(if (truth) "true" else "false", ty, typmod, session);
        }

        /// A JSON text or scalar text through the column type's input.
        fn convertText(text: []const u8, ty: types.Type, typmod: i32, session: *const value.Session) Error!V.Cell {
            return Io.parse(ty, typmod, text, session);
        }

        const ItemCollect = struct { out: *J.Buffer, count: usize = 0 };

        fn itemEmit(raw: ?*anyopaque, item: JP.Item) Error!bool {
            const state: *ItemCollect = @ptrCast(@alignCast(raw.?));
            state.count += 1;
            try state.out.append(item.bytes[item.at..][0..jsonb.sizeAt(item.bytes, item.at)]);
            return false;
        }

        /// The column's value, or null when its path found nothing.
        fn columnResult(state: *TableState, n: *const ast.Node, spec: *const ast.JsonTableColumn, item: JP.Item, name: []const u8, ty: types.Type, typmod: i32) Error!?V.Cell {
            const session = state.ctx.session;
            var path_cell: V.Cell = .null_value;
            var default_path: [80]u8 = undefined;
            var path_text: []const u8 = undefined;
            if (n.a != none) {
                path_cell = try E.eval(state.ctx, n.a);
                path_text = path_cell.text.slice();
            } else {
                // PATH defaults to $."name".
                var out: json_build.Out = .{ .bytes = &default_path };
                try out.append("$.");
                try json_build.escaped(&out, name);
                path_text = out.slice();
            }
            var path: JP.P = undefined;
            try path.parse(path_text, session.control);
            var context: JP.Context = undefined;
            try JP.initItem(&context, &path, item, state.vars, session.control, session);
            if (spec.kind == .exists) {
                var probe: J.Buffer = .{};
                var found: ItemCollect = .{ .out = &probe };
                const sink: JP.Sink = .{ .context = &found, .emit = existsEmit };
                _ = try JP.run(&context, &sink);
                return try booleanValue(found.count != 0, ty, typmod, session);
            }
            var collected: J.Buffer = .{};
            const header = try J.beginContainer(&collected, false);
            var state_items: ItemCollect = .{ .out = &collected };
            const sink: JP.Sink = .{ .context = &state_items, .emit = itemEmit };
            _ = try JP.run(&context, &sink);
            const count = state_items.count;
            if (count == 0) return null;
            try J.endContainer(&collected, header, count);
            const formatted = spec.format_json or spec.wrapper != .unspecified or spec.quotes != .unspecified or ty == .json or ty == .jsonb;
            const first = 5;
            if (!formatted) {
                // JSON_VALUE: one scalar item.
                if (count > 1) return error.MoreThanOneSqlJsonItem;
                const bytes = collected.bytes[0..collected.len];
                switch (@as(jsonb.Tag, @enumFromInt(bytes[first]))) {
                    .null_value => return .null_value,
                    .array, .object => return error.SqlJsonScalarRequired,
                    .string => return try convertText(jsonb.stringAt(bytes, first), ty, typmod, session),
                    else => {
                        var text: V.Text = .{};
                        var rendered: J.Text = .{ .bytes = &text.bytes };
                        try J.render(bytes, first, &rendered);
                        return try convertText(text.bytes[0..rendered.len], ty, typmod, session);
                    },
                }
            }
            // JSON_QUERY: the item, all items wrapped in an array, or 22034.
            const wrap = state_wrap: {
                break :state_wrap switch (spec.wrapper) {
                    .unconditional => true,
                    .conditional => count > 1,
                    else => false,
                };
            };
            if (!wrap and count > 1) return error.MoreThanOneSqlJsonItem;
            var canonical: J.Buffer = .{};
            if (wrap) {
                try J.canonicalize(collected.bytes[0..collected.len], &canonical, session.control);
            } else {
                try canonical.append(collected.bytes[first..collected.len]);
            }
            const result = canonical.bytes[0..canonical.len];
            if (ty == .jsonb) return try jsonbCell(&canonical);
            if (spec.quotes == .omit and result[0] == @intFromEnum(jsonb.Tag.string)) return try convertText(jsonb.stringAt(result, 0), ty, typmod, session);
            var text: V.Text = .{};
            var rendered: J.Text = .{ .bytes = &text.bytes };
            try J.render(result, 0, &rendered);
            return try convertText(text.bytes[0..rendered.len], ty, typmod, session);
        }

        fn existsEmit(raw: ?*anyopaque, _: JP.Item) Error!bool {
            const state: *ItemCollect = @ptrCast(@alignCast(raw.?));
            state.count += 1;
            return true;
        }
    };
}
