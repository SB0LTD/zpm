//! Collection, JSON and ordered-set aggregates (Layer 0, B11 json-agg lane),
//! after PostgreSQL's array_agg/string_agg (array_userfuncs.c, varlena.c),
//! json[b]_agg/json[b]_object_agg (json.c, jsonb.c) and orderedsetaggs.c.
//!
//! Exec.collectAggregate materializes one group's inputs in the statement
//! workspace (values, then sort keys, per row), drops the rows the
//! aggregate ignores, sorts them by the keys and calls one fold here over
//! the ordered row handles. Results live inline in one cell (text_bytes);
//! a larger result is TextCapacity (54000). Folds poll the execution
//! control once per input row.
//!
//! NULL rules: array_agg, json[b]_agg keep NULL inputs (array NULL
//! elements, JSON null); string_agg skips a NULL value and appends nothing
//! for a NULL delimiter; a NULL object key is 22004 and a NULL value is
//! JSON null; ordered-set aggregates ignore NULL keys; hypothetical-set
//! aggregates sort NULLs by the key's NULLS FIRST/LAST. Every aggregate
//! returns NULL over no input rows except the hypothetical-set ones.
const types = @import("types.sig");
const ast = @import("ast.sig");
const value_module = @import("value.sig");
const array_module = @import("array.sig");
const json_build = @import("json_build.sig");
const temporal = @import("temporal.sig");
const stats = @import("aggregates_stat.sig");
const Error = types.Error;
const Type = types.Type;

pub fn Collect(comptime config: types.Config) type {
    const V = types.Values(config);
    const A = V.Arrays;
    const JB = json_build.JsonBuild(config);
    return struct {
        pub const Session = value_module.Session;

        /// The sorted rows of one group: row `r`, column `c` is
        /// cells[handles[r] + c].
        pub const Rows = struct {
            cells: []const V.Cell,
            handles: []const u32,

            pub fn at(self: *const Rows, index: usize, column: usize) *const V.Cell {
                return &self.cells[self.handles[index] + column];
            }
        };

        fn poll(session: *const Session) Error!void {
            if (session.control) |control| try control.checkpoint();
        }

        /// array_agg(anynonarray): a one-dimensional array with lower bound
        /// 1; array_agg(anyarray): one more dimension over equal-shaped
        /// inputs (22004 for a NULL, 2202E for an empty or differently
        /// shaped input; 54000 beyond six dimensions).
        pub fn arrayAgg(rows: Rows, arg_ty: Type, session: *const Session) Error!V.Cell {
            if (rows.handles.len == 0) return .null_value;
            var text: V.Text = .{};
            if (types.elementType(arg_ty) == null) {
                const element = types.dataTypeOf(arg_ty);
                var layout: array_module.Shape = .{ .element = element, .ndim = 1 };
                if (rows.handles.len > 0x7ffffff) return error.ProgramLimitExceeded;
                layout.dims[0] = @intCast(rows.handles.len);
                var writer = try A.Writer.begin(&text, &layout);
                for (0..rows.handles.len) |index| {
                    try poll(session);
                    try writer.append(rows.at(index, 0));
                }
                return .{ .array = text };
            }
            const first = rows.at(0, 0);
            if (first.* == .null_value) return error.NullValueNotAllowed;
            const inner = A.shape(first.array.slice());
            if (inner.ndim == 0) return error.ArraySubscriptError;
            if (inner.ndim + 1 > array_module.max_dims) return error.ProgramLimitExceeded;
            var layout: array_module.Shape = .{ .element = inner.element, .ndim = inner.ndim + 1 };
            if (rows.handles.len > 0x7ffffff) return error.ProgramLimitExceeded;
            layout.dims[0] = @intCast(rows.handles.len);
            for (0..inner.ndim) |dim| {
                layout.dims[dim + 1] = inner.dims[dim];
                layout.lbounds[dim + 1] = inner.lbounds[dim];
            }
            for (0..rows.handles.len) |index| {
                const cell = rows.at(index, 0);
                if (cell.* == .null_value) return error.NullValueNotAllowed;
                const shape = A.shape(cell.array.slice());
                if (shape.ndim == 0) return error.ArraySubscriptError;
                if (shape.ndim != inner.ndim) return error.ArraySubscriptError;
                for (0..inner.ndim) |dim| if (shape.dims[dim] != inner.dims[dim] or shape.lbounds[dim] != inner.lbounds[dim]) return error.ArraySubscriptError;
            }
            var writer = try A.Writer.begin(&text, &layout);
            var element: V.Cell = undefined;
            for (0..rows.handles.len) |index| {
                try poll(session);
                var reader = A.Reader.init(rows.at(index, 0).array.slice());
                while (reader.next(&element)) try writer.append(&element);
            }
            return .{ .array = text };
        }

        /// string_agg(value, delimiter): every non-NULL value preceded by
        /// its row's delimiter (none when NULL); the first delimiter is
        /// dropped. Text or bytea.
        pub fn stringAgg(rows: Rows, binary: bool, session: *const Session) Error!V.Cell {
            if (rows.handles.len == 0) return .null_value;
            var text: V.Text = .{};
            for (0..rows.handles.len) |index| {
                try poll(session);
                const piece = rows.at(index, 0);
                const delimiter = rows.at(index, 1);
                if (index != 0 and delimiter.* != .null_value) try appendBytes(&text, bytesOf(delimiter));
                try appendBytes(&text, bytesOf(piece));
            }
            return if (binary) .{ .bytea = text } else .{ .text = text };
        }

        fn bytesOf(cell: *const V.Cell) []const u8 {
            return switch (cell.*) {
                .bytea => |*value| value.slice(),
                .text => |*value| value.slice(),
                .bpchar => |*value| value.slice(),
                else => "",
            };
        }

        fn appendBytes(text: *V.Text, bytes: []const u8) Error!void {
            if (bytes.len > config.text_bytes - text.len) return error.TextCapacity;
            @memcpy(text.bytes[text.len..][0..bytes.len], bytes);
            text.len += bytes.len;
        }

        /// json_agg / jsonb_agg: `[v1, v2]`; json separates a later array
        /// value with ", \n " as json_agg_transfn does.
        pub fn jsonAgg(rows: Rows, arg_ty: Type, jsonb: bool, session: *const Session) Error!V.Cell {
            if (rows.handles.len == 0) return .null_value;
            var buffer: [JB.buffer_bytes]u8 = undefined;
            var out: json_build.Out = .{ .bytes = &buffer };
            try out.byte('[');
            const structured = json_build.category(arg_ty) == .array;
            for (0..rows.handles.len) |index| {
                try poll(session);
                const cell = rows.at(index, 0);
                if (index != 0) {
                    try out.append(", ");
                    if (!jsonb and structured and cell.* != .null_value) try out.append("\n ");
                }
                try JB.append(&out, cell, arg_ty, false, jsonb, session);
            }
            try out.byte(']');
            return if (jsonb) JB.jsonbOf(&out, session) else JB.jsonOf(&out);
        }

        /// json_object_agg `{ "k" : v, ... }` / jsonb_object_agg (keys
        /// sorted, the last duplicate wins). A NULL key is 22004.
        pub fn objectAgg(rows: Rows, key_ty: Type, value_ty: Type, jsonb: bool, session: *const Session) Error!V.Cell {
            if (rows.handles.len == 0) return .null_value;
            var buffer: [JB.buffer_bytes]u8 = undefined;
            var out: json_build.Out = .{ .bytes = &buffer };
            try out.append(if (jsonb) "{" else "{ ");
            for (0..rows.handles.len) |index| {
                try poll(session);
                const key = rows.at(index, 0);
                if (key.* == .null_value) return error.NullValueNotAllowed;
                if (index != 0) try out.append(", ");
                try JB.append(&out, key, key_ty, true, jsonb, session);
                try out.append(if (jsonb) ": " else " : ");
                try JB.append(&out, rows.at(index, 1), value_ty, false, jsonb, session);
            }
            try out.append(if (jsonb) "}" else " }");
            return if (jsonb) JB.jsonbOf(&out, session) else JB.jsonOf(&out);
        }

        /// The fraction of percentile_cont/percentile_disc: NULL gives a
        /// NULL result, outside [0, 1] (or NaN) is 22003.
        pub fn fraction(cell: *const V.Cell) Error!?f64 {
            if (cell.* == .null_value) return null;
            const value = cell.float8;
            if (!(value >= 0 and value <= 1)) return error.NumericValueOutOfRange;
            return value;
        }

        /// percentile_cont: linear interpolation between the rows at
        /// floor/ceil(fraction * (n - 1)) (float8 or interval keys).
        pub fn percentileCont(rows: Rows, percentile: f64, ty: Type) Error!V.Cell {
            const count = rows.handles.len;
            if (count == 0) return .null_value;
            const position = percentile * @as(f64, @floatFromInt(count - 1));
            const first_row: usize = @intFromFloat(@floor(position));
            const second_row: usize = @intFromFloat(@ceil(position));
            const low = rows.at(first_row, 0);
            if (first_row == second_row) return low.*;
            const high = rows.at(second_row, 0);
            const proportion = position - @as(f64, @floatFromInt(first_row));
            if (ty == .interval) {
                // interval_lerp: lo + (hi - lo) * pct.
                const difference = try temporal.addIntervals(high.interval, try temporal.negateInterval(low.interval));
                const scaled = try stats.intervalMultiply(difference, proportion);
                return .{ .interval = try temporal.addIntervals(scaled, low.interval) };
            }
            return .{ .float8 = low.float8 + proportion * (high.float8 - low.float8) };
        }

        /// percentile_disc: the first row whose position K satisfies
        /// K / n >= fraction (K = ceil(fraction * n), at least 1).
        pub fn percentileDisc(rows: Rows, percentile: f64) V.Cell {
            const count = rows.handles.len;
            if (count == 0) return .null_value;
            var rownum: usize = @intFromFloat(@ceil(percentile * @as(f64, @floatFromInt(count))));
            if (rownum == 0) rownum = 1;
            if (rownum > count) rownum = count;
            return rows.at(rownum - 1, 0).*;
        }

        /// mode: the most frequent key; ties go to the first in sort order.
        pub fn mode(rows: Rows, session: *const Session) Error!V.Cell {
            const count = rows.handles.len;
            if (count == 0) return .null_value;
            var best: usize = 0;
            var best_frequency: usize = 0;
            var run_start: usize = 0;
            for (1..count + 1) |index| {
                try poll(session);
                if (index < count and V.compare(rows.at(index, 0), rows.at(run_start, 0)) == 0) continue;
                const frequency = index - run_start;
                if (frequency > best_frequency) {
                    best = run_start;
                    best_frequency = frequency;
                }
                run_start = index;
            }
            return rows.at(best, 0).*;
        }

        /// Sort key order of one key column (direction and NULL placement).
        pub const Key = struct { descending: bool, nulls_first: bool };

        pub fn keyOrder(x: *const V.Cell, y: *const V.Cell, key: Key) i8 {
            const x_null = x.* == .null_value;
            const y_null = y.* == .null_value;
            if (x_null or y_null) {
                if (x_null and y_null) return 0;
                return if (x_null == key.nulls_first) -1 else 1;
            }
            const order = V.compare(x, y);
            return if (key.descending) -order else order;
        }

        /// Order of row `index` against the hypothetical row.
        fn hypotheticalOrder(rows: *const Rows, index: usize, hypothetical: []const V.Cell, keys: []const Key) i8 {
            for (hypothetical, keys, 0..) |*value, key, column| {
                const order = keyOrder(rows.at(index, column), value, key);
                if (order != 0) return order;
            }
            return 0;
        }

        pub const Hypothetical = enum { rank, dense_rank, percent_rank, cume_dist };

        /// rank/dense_rank/percent_rank/cume_dist of the hypothetical row
        /// among the sorted rows (hypothetical_rank_common: it sorts before
        /// its peers, after them for cume_dist).
        pub fn hypotheticalSet(rows: Rows, hypothetical: []const V.Cell, keys: []const Key, kind: Hypothetical, session: *const Session) Error!V.Cell {
            const count = rows.handles.len;
            var before: usize = 0;
            var distinct_before: usize = 0;
            for (0..count) |index| {
                try poll(session);
                const order = hypotheticalOrder(&rows, index, hypothetical, keys);
                if (order > 0 or (order == 0 and kind != .cume_dist)) break;
                before += 1;
                if (index == 0) {
                    distinct_before = 1;
                } else {
                    var equal = true;
                    for (keys, 0..) |key, column| {
                        if (keyOrder(rows.at(index, column), rows.at(index - 1, column), key) != 0) {
                            equal = false;
                            break;
                        }
                    }
                    if (!equal) distinct_before += 1;
                }
            }
            const rank: i64 = @intCast(before + 1);
            return switch (kind) {
                .rank => .{ .integer = rank },
                .dense_rank => .{ .integer = @intCast(distinct_before + 1) },
                .percent_rank => .{ .float8 = if (count == 0) 0 else @as(f64, @floatFromInt(rank - 1)) / @as(f64, @floatFromInt(count)) },
                .cume_dist => .{ .float8 = @as(f64, @floatFromInt(rank)) / @as(f64, @floatFromInt(count + 1)) },
            };
        }
    };
}
