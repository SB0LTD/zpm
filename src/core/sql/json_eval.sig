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
    };
}
