//! Evaluation of array expressions (Layer 0), after arrayfuncs.c and
//! array_userfuncs.c: ARRAY[...] constructors, subscripts and slices,
//! op ANY/ALL (array), the array functions, || concatenation and the
//! @> <@ && containment operators.
//!
//! `ArrayEval(config, E)` is instantiated by expr.sig's `Eval` (`E`). Every
//! result is built in a fresh caller-owned cell (Config.text_bytes); a
//! result that does not fit is TextCapacity (54000).
const types = @import("types.sig");
const ast = @import("ast.sig");
const array = @import("array.sig");
const value = @import("value.sig");
const geometry = @import("geometry.sig");
const Error = types.Error;
const none = ast.none;

pub fn ArrayEval(comptime config: types.Config, comptime E: type) type {
    const V = types.Values(config);
    const A = V.Arrays;
    const Io = value.Io(config);
    return struct {
        fn node(ctx: *const E.Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        fn elementData(ty: types.Type) types.DataType {
            return types.dataTypeOf(types.elementType(ty).?);
        }

        fn textCell(bytes: []const u8) Error!V.Cell {
            if (bytes.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = bytes.len };
            @memcpy(text.bytes[0..bytes.len], bytes);
            return .{ .text = text };
        }

        fn empty(element: types.DataType) Error!V.Cell {
            var result: V.Text = .{};
            _ = try A.Writer.begin(&result, &.{ .element = element });
            return .{ .array = result };
        }

        pub fn call(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            return switch (n.func) {
                .array_constructor => construct(ctx, n),
                .array_subscript => subscript(ctx, n),
                .array_any => any(ctx, n),
                .array_append, .array_prepend, .array_cat => blk: {
                    const first = try E.eval(ctx, n.b);
                    const second = try E.eval(ctx, node(ctx, n.b).next);
                    break :blk concat(switch (n.func) {
                        .array_append => .append,
                        .array_prepend => .prepend,
                        else => .cat,
                    }, &first, &second, n.ty);
                },
                .array_to_string => toString(ctx, n),
                .array_remove => remove(ctx, n),
                .array_position, .array_positions => findPosition(ctx, n),
                .array_replace => replace(ctx, n),
                .trim_array => trim(ctx, n),
                .array_fill => fill(ctx, n),
                .array_reverse, .array_shuffle, .array_sample => permute(ctx, n),
                .array_sort => sort(ctx, n),
                .string_to_array => split(ctx, n),
                .array_width_bucket => widthBucket(ctx, n),
                .array_set => assign(ctx, n),
                else => measure(ctx, n),
            };
        }

        // ---- B11 wave-4 types-ext: array_userfuncs.c --------------------------

        fn notDistinct(a: *const V.Cell, b: *const V.Cell) bool {
            const a_null = a.* == .null_value;
            const b_null = b.* == .null_value;
            if (a_null or b_null) return a_null and b_null;
            return V.compare(a, b) == 0;
        }

        /// array_position(array, value [, start]) / array_positions(array,
        /// value): one-dimensional arrays only (0A000), IS NOT DISTINCT FROM
        /// matching, positions in the array's own subscripts.
        fn findPosition(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const source = try E.eval(ctx, n.b);
            const needle_id = node(ctx, n.b).next;
            const needle = try E.eval(ctx, needle_id);
            const start_id = node(ctx, needle_id).next;
            const start: V.Cell = if (start_id == none) .null_value else try E.eval(ctx, start_id);
            if (source == .null_value) return .null_value;
            const bytes = source.array.slice();
            const shape = A.shape(bytes);
            if (shape.ndim > 1) return error.UnsupportedStatement;
            const all = n.func == .array_positions;
            if (shape.ndim == 0) return if (all) empty(.integer32) else .null_value;
            if (start_id != none and start == .null_value) return error.NullValueNotAllowed;
            const minimum: i64 = if (start_id == none) shape.lbounds[0] else start.integer;
            var found: usize = 0;
            var result: V.Text = .{};
            var writer: A.Writer = undefined;
            // array_positions: count, then write.
            for (0..@as(usize, if (all) 2 else 1)) |pass| {
                if (all and pass == 1) writer = try A.Writer.begin(&result, &.{ .element = .integer32, .ndim = if (found == 0) 0 else 1, .dims = .{ @intCast(found), 0, 0, 0, 0, 0 } });
                var reader = A.Reader.init(bytes);
                var cell: V.Cell = undefined;
                var index: i64 = shape.lbounds[0];
                while (reader.next(&cell)) : (index += 1) {
                    try ctx.session.checkpoint();
                    if (index < minimum or !notDistinct(&cell, &needle)) continue;
                    if (!all) return .{ .integer = index };
                    if (pass == 0) found += 1 else try writer.append(&.{ .integer = index });
                }
                if (!all) return .null_value;
                if (found == 0) return empty(.integer32);
            }
            return .{ .array = result };
        }

        /// array_replace(array, search, replacement): every element not
        /// distinct from `search`, at any dimension.
        fn replace(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const source = try E.eval(ctx, n.b);
            const search_id = node(ctx, n.b).next;
            const search = try E.eval(ctx, search_id);
            const replacement = try E.eval(ctx, node(ctx, search_id).next);
            if (source == .null_value) return .null_value;
            const shape = A.shape(source.array.slice());
            if (shape.ndim == 0) return source;
            var result: V.Text = .{};
            var writer = try A.Writer.begin(&result, &shape);
            var reader = A.Reader.init(source.array.slice());
            var cell: V.Cell = undefined;
            while (reader.next(&cell)) {
                try ctx.session.checkpoint();
                try writer.append(if (notDistinct(&cell, &search)) &replacement else &cell);
            }
            return .{ .array = result };
        }

        /// Writes `shape`'s header and then raw element bytes copied from
        /// `source` ranges; `nulls` sets the header flag.
        fn rawBegin(out: *V.Text, shape: *const array.Shape) Error!void {
            _ = try shape.checkedCount();
            out.len = try A.writeHeader(&out.bytes, shape);
        }

        fn rawCopy(out: *V.Text, bytes: []const u8) Error!void {
            try A.putBytes(out, bytes);
        }

        fn rawFinish(out: *V.Text, nulls: bool) V.Cell {
            if (nulls) out.bytes[2] |= 1;
            return .{ .array = out.* };
        }

        /// trim_array(array, n): drops the last n items of the first
        /// dimension (2202E unless 0 <= n <= its length).
        fn trim(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const source = try E.eval(ctx, n.b);
            const count = try E.eval(ctx, node(ctx, n.b).next);
            if (source == .null_value or count == .null_value) return .null_value;
            const bytes = source.array.slice();
            const shape = A.shape(bytes);
            const length: i64 = if (shape.ndim == 0) 0 else shape.dims[0];
            if (count.integer < 0 or count.integer > length) return error.ArraySubscriptError;
            if (count.integer == 0) return source;
            if (count.integer == length) return empty(shape.element);
            var layout = shape;
            layout.dims[0] = @intCast(length - count.integer);
            // A slice: every lower bound becomes 1.
            for (0..layout.ndim) |dim| layout.lbounds[dim] = 1;
            const kept = layout.count();
            var nulls = false;
            const start = A.bodyOffset(bytes);
            const end = A.skipElements(bytes, start, shape.element, kept, &nulls);
            var result: V.Text = .{};
            try rawBegin(&result, &layout);
            try rawCopy(&result, bytes[start..end]);
            return rawFinish(&result, nulls);
        }

        /// array_fill(value, dims [, lbounds]).
        fn fill(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const value_cell = try E.eval(ctx, n.b);
            const dims_id = node(ctx, n.b).next;
            const dims = try E.eval(ctx, dims_id);
            const bounds_id = node(ctx, dims_id).next;
            const bounds: V.Cell = if (bounds_id == none) .null_value else try E.eval(ctx, bounds_id);
            if (dims == .null_value or (bounds_id != none and bounds == .null_value)) return error.NullValueNotAllowed;
            var layout: array.Shape = .{ .element = elementData(n.ty) };
            const dims_shape = A.shape(dims.array.slice());
            if (dims_shape.ndim > 1) return error.ArraySubscriptError;
            if (dims_shape.ndim == 1 and dims_shape.lbounds[0] != 1) return error.ArraySubscriptError;
            if (dims_shape.has_nulls) return error.NullValueNotAllowed;
            const ndim: usize = if (dims_shape.ndim == 0) 0 else dims_shape.dims[0];
            if (ndim > array.max_dims) return error.ProgramLimitExceeded;
            if (bounds_id != none) {
                const bounds_shape = A.shape(bounds.array.slice());
                if (bounds_shape.ndim > 1) return error.ArraySubscriptError;
                if (bounds_shape.ndim == 1 and bounds_shape.lbounds[0] != 1) return error.ArraySubscriptError;
                if (bounds_shape.has_nulls) return error.NullValueNotAllowed;
                const bounds_count: usize = if (bounds_shape.ndim == 0) 0 else bounds_shape.dims[0];
                if (bounds_count != ndim) return error.ArraySubscriptError;
            }
            if (ndim == 0) return empty(layout.element);
            layout.ndim = ndim;
            var reader = A.Reader.init(dims.array.slice());
            var cell: V.Cell = undefined;
            var dim: usize = 0;
            var zero = false;
            while (reader.next(&cell)) : (dim += 1) {
                if (cell.integer < 0) return error.ProgramLimitExceeded;
                if (cell.integer == 0) zero = true;
                layout.dims[dim] = @intCast(cell.integer);
            }
            if (bounds_id != none) {
                reader = A.Reader.init(bounds.array.slice());
                dim = 0;
                while (reader.next(&cell)) : (dim += 1) layout.lbounds[dim] = @intCast(cell.integer);
            }
            _ = try layout.checkedCount();
            if (zero) return empty(layout.element);
            var result: V.Text = .{};
            var writer = try A.Writer.begin(&result, &layout);
            while (!writer.complete()) {
                try ctx.session.checkpoint();
                try writer.append(&value_cell);
            }
            return .{ .array = result };
        }

        /// Byte ranges of the first-dimension items of an array.
        const Items = struct {
            bytes: []const u8,
            element: types.DataType,
            count: usize,
            inner: usize,
            body: usize,

            fn of(bytes: []const u8) Items {
                const shape = A.shape(bytes);
                const count: usize = if (shape.ndim == 0) 0 else shape.dims[0];
                return .{ .bytes = bytes, .element = shape.element, .count = count, .inner = if (count == 0) 0 else shape.count() / count, .body = A.bodyOffset(bytes) };
            }

            /// [start, end) of item `index` in `buffer` (same layout).
            fn range(self: *const Items, buffer: []const u8, index: usize) [2]usize {
                var ignored = false;
                const start = A.skipElements(buffer, self.body, self.element, index * self.inner, &ignored);
                return .{ start, A.skipElements(buffer, start, self.element, self.inner, &ignored) };
            }
        };

        fn reverseBytes(bytes: []u8) void {
            var i: usize = 0;
            var j: usize = bytes.len;
            while (i + 1 < j) {
                j -= 1;
                const t = bytes[i];
                bytes[i] = bytes[j];
                bytes[j] = t;
                i += 1;
            }
        }

        /// Swaps items i < j of `out` (same layout as `items`) in place.
        fn swapItems(items: *const Items, out: *V.Text, i: usize, j: usize) void {
            if (i == j) return;
            const a = items.range(out.bytes[0..out.len], i);
            const b = items.range(out.bytes[0..out.len], j);
            // [A][mid][B] -> [B][mid][A] by reversals.
            const region = out.bytes[a[0]..b[1]];
            const a_len = a[1] - a[0];
            const b_len = b[1] - b[0];
            const mid_len = b[0] - a[1];
            reverseBytes(region);
            reverseBytes(region[0..b_len]);
            reverseBytes(region[b_len..][0..mid_len]);
            reverseBytes(region[b_len + mid_len ..][0..a_len]);
        }

        fn randomBelow(ctx: *const E.Context, bound: usize) Error!usize {
            const hook = ctx.session.engine orelse return error.UnsupportedStatement;
            var scratch: [1]u8 = undefined;
            const reply = try hook.call(hook.ptr, .random, "", "", 0, 0, 0, &scratch);
            const word: u64 = @bitCast(reply.integer);
            return @intCast(word % @as(u64, @intCast(bound)));
        }

        /// array_reverse, array_shuffle and array_sample reorder the items
        /// of the first dimension; a sample keeps its first n items of a
        /// shuffle (22023 unless 0 <= n <= length) with lower bound 1.
        fn permute(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const source = try E.eval(ctx, n.b);
            const size: V.Cell = if (n.func == .array_sample) try E.eval(ctx, node(ctx, n.b).next) else .null_value;
            if (source == .null_value or (n.func == .array_sample and size == .null_value)) return .null_value;
            const bytes = source.array.slice();
            const items = Items.of(bytes);
            if (n.func == .array_sample and (size.integer < 0 or size.integer > items.count)) return error.InvalidParameterValue;
            if (items.count == 0) return if (n.func == .array_sample) empty(items.element) else source;
            var result: V.Text = .{};
            result.len = bytes.len;
            if (bytes.len > result.bytes.len) return error.TextCapacity;
            @memcpy(result.bytes[0..bytes.len], bytes);
            switch (n.func) {
                .array_reverse => {
                    var i: usize = 0;
                    var j: usize = items.count - 1;
                    while (i < j) : ({
                        i += 1;
                        j -= 1;
                    }) {
                        try ctx.session.checkpoint();
                        swapItems(&items, &result, i, j);
                    }
                    return .{ .array = result };
                },
                else => {
                    // Fisher-Yates over the items; a sample fixes its prefix.
                    const wanted: usize = if (n.func == .array_sample) @intCast(size.integer) else items.count;
                    for (0..@min(wanted, items.count - 1)) |i| {
                        try ctx.session.checkpoint();
                        const j = i + try randomBelow(ctx, items.count - i);
                        swapItems(&items, &result, i, j);
                    }
                    if (n.func == .array_shuffle) return .{ .array = result };
                    if (wanted == 0) return empty(items.element);
                    var layout = A.shape(bytes);
                    layout.dims[0] = @intCast(wanted);
                    layout.lbounds[0] = 1;
                    var nulls = false;
                    const start = items.body;
                    const end = A.skipElements(result.bytes[0..result.len], start, items.element, wanted * items.inner, &nulls);
                    var sample: V.Text = .{};
                    try rawBegin(&sample, &layout);
                    try rawCopy(&sample, result.bytes[start..end]);
                    return rawFinish(&sample, nulls);
                },
            }
        }

        /// array_sort(array [, descending [, nulls_first]]): a stable sort
        /// of the first-dimension items (sub-arrays compare as arrays);
        /// NULLs last ascending and first descending unless nulls_first.
        fn sort(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const source = try E.eval(ctx, n.b);
            var descending = false;
            var item = node(ctx, n.b).next;
            var position_index: usize = 0;
            var nulls_first: ?bool = null;
            while (item != none) : ({
                item = node(ctx, item).next;
                position_index += 1;
            }) {
                const flag = try E.eval(ctx, item);
                if (flag == .null_value) return .null_value;
                if (position_index == 0) descending = flag.boolean else nulls_first = flag.boolean;
            }
            if (source == .null_value) return .null_value;
            const first_nulls = nulls_first orelse descending;
            const bytes = source.array.slice();
            const items = Items.of(bytes);
            if (items.count < 2) return source;
            if (n.integer != 0) return error.UnsupportedStatement;
            // Insertion sort into the output buffer: item i is inserted after
            // every earlier item that does not order after it.
            var result: V.Text = .{};
            result.len = items.body;
            @memcpy(result.bytes[0..items.body], bytes[0..items.body]);
            var placed: usize = 0;
            for (0..items.count) |i| {
                const from = items.range(bytes, i);
                var at = items.body;
                var k: usize = 0;
                while (k < placed) : (k += 1) {
                    try ctx.session.checkpoint();
                    var ignored = false;
                    const next = A.skipElements(result.bytes[0..result.len], at, items.element, items.inner, &ignored);
                    if (orderItems(bytes, from[0], result.bytes[0..result.len], at, items.element, items.inner, descending, first_nulls) < 0) break;
                    at = next;
                }
                const len = from[1] - from[0];
                if (len > result.bytes.len - result.len) return error.TextCapacity;
                const tail = result.len - at;
                // Shift the tail right (backwards copy) and insert.
                var index = tail;
                while (index > 0) {
                    index -= 1;
                    result.bytes[at + len + index] = result.bytes[at + index];
                }
                @memcpy(result.bytes[at..][0..len], bytes[from[0]..from[1]]);
                result.len += len;
                placed += 1;
            }
            return .{ .array = result };
        }

        /// The sort order of item `a` before item `b` (-1, 0, 1).
        fn orderItems(a: []const u8, a_at: usize, b: []const u8, b_at: usize, element: types.DataType, inner: usize, descending: bool, nulls_first: bool) i8 {
            if (inner == 1) {
                const a_null = a[a_at] == 0;
                const b_null = b[b_at] == 0;
                if (a_null or b_null) {
                    if (a_null and b_null) return 0;
                    return if (a_null == nulls_first) -1 else 1;
                }
            }
            const order = A.compareRuns(a, a_at, b, b_at, element, inner);
            return if (descending) -order else order;
        }

        /// string_to_array(text, delimiter [, null_string]).
        fn split(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const text = try E.eval(ctx, n.b);
            const delimiter_id = node(ctx, n.b).next;
            const delimiter = try E.eval(ctx, delimiter_id);
            const null_id = node(ctx, delimiter_id).next;
            const null_text: V.Cell = if (null_id == none) .null_value else try E.eval(ctx, null_id);
            if (text == .null_value) return .null_value;
            const input = text.text.slice();
            if (input.len == 0) return empty(.text);
            // Two passes: count, then write.
            var count: usize = 0;
            var result: V.Text = .{};
            var writer: A.Writer = undefined;
            for (0..2) |pass| {
                if (pass == 1) writer = try A.Writer.begin(&result, &.{ .element = .text, .ndim = 1, .dims = .{ @intCast(count), 0, 0, 0, 0, 0 } });
                var at: usize = 0;
                while (at <= input.len) {
                    try ctx.session.checkpoint();
                    var end: usize = undefined;
                    var next: usize = undefined;
                    if (delimiter == .null_value) {
                        if (at == input.len) break;
                        end = at + utf8Length(input[at]);
                        if (end > input.len) end = input.len;
                        next = end;
                    } else {
                        const separator = delimiter.text.slice();
                        if (separator.len == 0) {
                            end = input.len;
                        } else end = if (@import("std").mem.indexOfPos(u8, input, at, separator)) |found| found else input.len;
                        next = if (end == input.len) input.len + 1 else end + separator.len;
                    }
                    if (pass == 0) {
                        count += 1;
                    } else {
                        const piece = input[at..end];
                        const cell: V.Cell = if (null_text != .null_value and types.same(piece, null_text.text.slice())) .null_value else try textCell(piece);
                        try writer.append(&cell);
                    }
                    at = next;
                }
            }
            return .{ .array = result };
        }

        fn utf8Length(lead: u8) usize {
            if (lead < 0x80) return 1;
            if (lead >= 0xf0) return 4;
            if (lead >= 0xe0) return 3;
            if (lead >= 0xc0) return 2;
            return 1;
        }

        /// width_bucket(operand, thresholds): PostgreSQL's binary search
        /// (thresholds are assumed sorted).
        fn widthBucket(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const operand = try E.eval(ctx, n.b);
            const thresholds = try E.eval(ctx, node(ctx, n.b).next);
            if (operand == .null_value or thresholds == .null_value) return .null_value;
            const bytes = thresholds.array.slice();
            const shape = A.shape(bytes);
            if (shape.ndim > 1) return error.ArraySubscriptError;
            if (shape.has_nulls) return error.NullValueNotAllowed;
            const items = Items.of(bytes);
            var left: usize = 0;
            var right: usize = items.count;
            while (left < right) {
                try ctx.session.checkpoint();
                const middle = left + (right - left) / 2;
                var at = items.range(bytes, middle)[0];
                at += 1;
                const value_cell = A.decodeElement(bytes, &at, items.element);
                if (V.compare(&operand, &value_cell) < 0) right = middle else left = middle + 1;
            }
            return .{ .integer = @intCast(left) };
        }

        /// UPDATE SET a[...] = v (array_set_element / array_set_slice): a
        /// NULL base is an empty array; a one-dimensional (or empty) array
        /// extends with NULLs, other subscripts must be in range (2202E).
        fn assign(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const base = try E.eval(ctx, n.b);
            const value_id = node(ctx, n.b).next;
            const assigned = try E.eval(ctx, value_id);
            const layout = array.Subscripts.decode(n.integer);
            var lower: [array.max_dims]?i64 = @splat(null);
            var upper: [array.max_dims]?i64 = @splat(null);
            var item = node(ctx, value_id).next;
            for (0..layout.count) |index| {
                const flag = layout.flags[index];
                for ([_]u3{ array.Subscripts.lower_flag, array.Subscripts.upper_flag }) |which| {
                    if (flag & which == 0) continue;
                    const cell = try E.eval(ctx, item);
                    item = node(ctx, item).next;
                    if (cell == .null_value) return error.NullValueNotAllowed;
                    if (which == array.Subscripts.lower_flag) lower[index] = cell.integer else upper[index] = cell.integer;
                }
            }
            const element = elementData(n.ty);
            var source_bytes: []const u8 = &.{};
            var empty_bytes: V.Text = .{};
            if (base == .null_value) {
                empty_bytes.len = try A.writeHeader(&empty_bytes.bytes, &.{ .element = element });
                source_bytes = empty_bytes.bytes[0..empty_bytes.len];
            } else source_bytes = base.array.slice();
            const shape = A.shape(source_bytes);
            const slice = layout.slice();
            // Assigning NULL to a slice leaves the array unchanged.
            if (slice and assigned == .null_value) return base;
            var target = shape;
            var low: [array.max_dims]i64 = undefined;
            var high: [array.max_dims]i64 = undefined;
            if (shape.ndim == 0) {
                // An empty array takes the subscripts' shape.
                if (!slice) {
                    target.ndim = layout.count;
                    for (0..layout.count) |dim| {
                        low[dim] = lower[dim].?;
                        high[dim] = lower[dim].?;
                    }
                } else {
                    const value_shape = A.shape(assigned.array.slice());
                    target.ndim = layout.count;
                    for (0..layout.count) |dim| {
                        low[dim] = lower[dim] orelse return error.ArraySubscriptError;
                        high[dim] = upper[dim] orelse return error.ArraySubscriptError;
                        if (layout.flags[dim] & array.Subscripts.slice_flag == 0) {
                            high[dim] = low[dim];
                            low[dim] = 1;
                        }
                    }
                    _ = value_shape;
                }
                for (0..target.ndim) |dim| {
                    if (high[dim] < low[dim]) return error.ArraySubscriptError;
                    if (high[dim] - low[dim] + 1 > 2147483647 or low[dim] < -2147483648 or high[dim] > 2147483647) return error.ProgramLimitExceeded;
                    target.lbounds[dim] = @intCast(low[dim]);
                    target.dims[dim] = @intCast(high[dim] - low[dim] + 1);
                }
            } else {
                if (layout.count != shape.ndim) {
                    if (!slice or layout.count > shape.ndim) return error.ArraySubscriptError;
                }
                for (0..shape.ndim) |dim| {
                    var from: i64 = shape.lbounds[dim];
                    var to: i64 = shape.upper(dim);
                    if (dim < layout.count) {
                        const flag = layout.flags[dim];
                        if (!slice) {
                            from = lower[dim].?;
                            to = from;
                        } else if (flag & array.Subscripts.slice_flag == 0) {
                            from = 1;
                            to = lower[dim].?;
                        } else {
                            if (lower[dim]) |bound| from = bound;
                            if (upper[dim]) |bound| to = bound;
                        }
                    }
                    if (to < from) return error.ArraySubscriptError;
                    low[dim] = from;
                    high[dim] = to;
                    if (shape.ndim == 1) {
                        // One dimension: extend to cover the assignment.
                        const new_low = @min(from, @as(i64, shape.lbounds[0]));
                        const new_high = @max(to, shape.upper(0));
                        if (new_high - new_low + 1 > 2147483647 or new_high > 2147483647 or new_low < -2147483648) return error.ProgramLimitExceeded;
                        target.lbounds[0] = @intCast(new_low);
                        target.dims[0] = @intCast(new_high - new_low + 1);
                    } else if (from < shape.lbounds[dim] or to > shape.upper(dim)) return error.ArraySubscriptError;
                }
            }
            _ = try target.checkedCount();
            // The slice source supplies its elements in row-major order.
            var feed: A.Reader = undefined;
            if (slice) {
                feed = A.Reader.init(assigned.array.slice());
                var needed: usize = 1;
                for (0..target.ndim) |dim| needed *= @intCast(high[dim] - low[dim] + 1);
                if (feed.total < needed) return error.ArraySubscriptError;
            }
            var result: V.Text = .{};
            var writer = try A.Writer.begin(&result, &target);
            var old = A.Reader.init(source_bytes);
            var position: [array.max_dims]i64 = undefined;
            for (0..target.ndim) |dim| position[dim] = target.lbounds[dim];
            var cell: V.Cell = undefined;
            while (!writer.complete()) {
                try ctx.session.checkpoint();
                var inside_old = shape.ndim != 0;
                var inside_new = true;
                for (0..target.ndim) |dim| {
                    if (shape.ndim != 0 and (position[dim] < shape.lbounds[dim] or position[dim] > shape.upper(dim))) inside_old = false;
                    if (position[dim] < low[dim] or position[dim] > high[dim]) inside_new = false;
                }
                var old_value: V.Cell = .null_value;
                if (inside_old) _ = old.next(&old_value);
                if (inside_new) {
                    if (slice) {
                        _ = feed.next(&cell);
                        try writer.append(&cell);
                    } else try writer.append(&assigned);
                } else try writer.append(&old_value);
                var dim = target.ndim;
                while (dim > 0) {
                    dim -= 1;
                    position[dim] += 1;
                    if (position[dim] <= @as(i64, target.lbounds[dim]) + target.dims[dim] - 1) break;
                    position[dim] = target.lbounds[dim];
                }
            }
            return .{ .array = result };
        }

        /// ARRAY[...]: elements, or sub-arrays of matching dimensions and
        /// lower bounds (NULL or empty sub-arrays only if all are).
        fn construct(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            var count: usize = 0;
            var item = n.b;
            while (item != none) : (item = node(ctx, item).next) count += 1;
            var result: V.Text = .{};
            const nested = n.b != none and types.isArray(node(ctx, n.b).ty);
            if (!nested) {
                const layout: array.Shape = .{ .element = elementData(n.ty), .ndim = if (count == 0) 0 else 1, .dims = .{ @intCast(count), 0, 0, 0, 0, 0 } };
                var writer = try A.Writer.begin(&result, &layout);
                item = n.b;
                while (item != none) : (item = node(ctx, item).next) {
                    const cell = try E.eval(ctx, item);
                    try writer.append(&cell);
                }
                return .{ .array = result };
            }
            var writer: ?A.Writer = null;
            var inner: array.Shape = .{};
            var have_empty = false;
            item = n.b;
            while (item != none) : (item = node(ctx, item).next) {
                const cell = try E.eval(ctx, item);
                if (cell == .null_value) {
                    have_empty = true;
                    continue;
                }
                const shape = A.shape(cell.array.slice());
                if (shape.ndim == 0) {
                    have_empty = true;
                    continue;
                }
                if (writer == null) {
                    if (shape.ndim + 1 > array.max_dims) return error.ProgramLimitExceeded;
                    inner = shape;
                    var layout: array.Shape = .{ .element = shape.element, .ndim = shape.ndim + 1, .dims = .{ @intCast(count), 0, 0, 0, 0, 0 } };
                    for (0..shape.ndim) |dim| {
                        layout.dims[dim + 1] = shape.dims[dim];
                        layout.lbounds[dim + 1] = shape.lbounds[dim];
                    }
                    writer = try A.Writer.begin(&result, &layout);
                } else {
                    if (shape.ndim != inner.ndim) return error.ArraySubscriptError;
                    for (0..shape.ndim) |dim| if (shape.dims[dim] != inner.dims[dim] or shape.lbounds[dim] != inner.lbounds[dim]) return error.ArraySubscriptError;
                }
                if (have_empty) continue;
                var reader = A.Reader.init(cell.array.slice());
                var element: V.Cell = undefined;
                while (reader.next(&element)) try writer.?.append(&element);
            }
            if (writer == null) return empty(elementData(n.ty));
            if (have_empty) return error.ArraySubscriptError;
            return .{ .array = result };
        }

        /// Element fetch (NULL unless every dimension is subscripted and in
        /// range) or slice (bounds clipped to the array; a single number
        /// means 1:n; the result's lower bounds are 1).
        fn subscript(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const base = try E.eval(ctx, n.b);
            if (base == .null_value) return .null_value;
            const layout = array.Subscripts.decode(n.integer);
            var lower: [array.max_dims]?i64 = @splat(null);
            var upper: [array.max_dims]?i64 = @splat(null);
            var any_null = false;
            var item = node(ctx, n.b).next;
            for (0..layout.count) |index| {
                const flag = layout.flags[index];
                for ([_]u3{ array.Subscripts.lower_flag, array.Subscripts.upper_flag }) |which| {
                    if (flag & which == 0) continue;
                    const cell = try E.eval(ctx, item);
                    item = node(ctx, item).next;
                    if (cell == .null_value) {
                        any_null = true;
                        continue;
                    }
                    if (which == array.Subscripts.lower_flag) lower[index] = cell.integer else upper[index] = cell.integer;
                }
            }
            if (any_null) return .null_value;
            if (base == .point or base == .box or base == .geo) {
                // point[0..1], box/lseg[0..1] (corners), line[0..2]; a
                // second subscript or one out of range is NULL.
                if (layout.count != 1) return .null_value;
                const index = lower[0].?;
                switch (base) {
                    .point => |p| return if (index == 0) .{ .float8 = p.x } else if (index == 1) .{ .float8 = p.y } else .null_value,
                    .box => |b| return if (index == 0) .{ .point = b.high } else if (index == 1) .{ .point = b.low } else .null_value,
                    else => {
                        const bytes = base.geo.slice();
                        const limit: i64 = if (geometry.kindOf(bytes) == .line) 3 else 2;
                        if (index < 0 or index >= limit) return .null_value;
                        if (geometry.kindOf(bytes) == .line) return .{ .float8 = geometry.word(bytes, @intCast(index)) };
                        return .{ .point = .{ .x = geometry.word(bytes, @intCast(index * 2)), .y = geometry.word(bytes, @intCast(index * 2 + 1)) } };
                    },
                }
            }
            if (node(ctx, n.b).ty == .name) {
                // PostgreSQL treats name as a fixed-length zero-padded byte
                // array, with a zero-based index and a "char" result.
                if (layout.count != 1) return .null_value;
                const index = lower[0].?;
                if (index < 0 or index >= types.pg_name_bytes) return .null_value;
                const offset: usize = @intCast(index);
                const bytes = base.text.slice();
                return .{ .pg_internal_char = if (offset < @min(bytes.len, types.pg_name_bytes - 1)) bytes[offset] else 0 };
            }
            const bytes = base.array.slice();
            const shape = A.shape(bytes);
            if (!layout.slice()) {
                if (layout.count != shape.ndim) return .null_value;
                var offset: usize = 0;
                for (0..shape.ndim) |dim| {
                    const index = lower[dim].?;
                    if (index < shape.lbounds[dim] or index > shape.upper(dim)) return .null_value;
                    offset = offset * shape.dims[dim] + @as(usize, @intCast(index - shape.lbounds[dim]));
                }
                var reader = A.Reader.init(bytes);
                var cell: V.Cell = .null_value;
                for (0..offset) |_| reader.skip();
                _ = reader.next(&cell);
                return cell;
            }
            if (shape.ndim < layout.count or shape.ndim == 0) return empty(shape.element);
            var low: [array.max_dims]i64 = undefined;
            var high: [array.max_dims]i64 = undefined;
            var result_shape: array.Shape = .{ .element = shape.element, .ndim = shape.ndim };
            for (0..shape.ndim) |dim| {
                var from: i64 = shape.lbounds[dim];
                var to: i64 = shape.upper(dim);
                if (dim < layout.count) {
                    const flag = layout.flags[dim];
                    if (flag & array.Subscripts.slice_flag == 0) {
                        from = 1;
                        to = lower[dim].?;
                    } else {
                        if (lower[dim]) |bound| from = bound;
                        if (upper[dim]) |bound| to = bound;
                    }
                }
                from = @max(from, shape.lbounds[dim]);
                to = @min(to, shape.upper(dim));
                if (from > to) return empty(shape.element);
                low[dim] = from;
                high[dim] = to;
                result_shape.dims[dim] = @intCast(to - from + 1);
            }
            var result: V.Text = .{};
            var writer = try A.Writer.begin(&result, &result_shape);
            var reader = A.Reader.init(bytes);
            var position: [array.max_dims]i64 = undefined;
            for (0..shape.ndim) |dim| position[dim] = shape.lbounds[dim];
            var cell: V.Cell = undefined;
            while (reader.next(&cell)) {
                try ctx.session.checkpoint();
                var inside = true;
                for (0..shape.ndim) |dim| inside = inside and position[dim] >= low[dim] and position[dim] <= high[dim];
                if (inside) try writer.append(&cell);
                var dim = shape.ndim;
                while (dim > 0) {
                    dim -= 1;
                    position[dim] += 1;
                    if (position[dim] <= shape.upper(dim)) break;
                    position[dim] = shape.lbounds[dim];
                }
            }
            return .{ .array = result };
        }

        /// `x op ANY (array)`; ALL is NOT ANY with the opposite operator.
        /// An empty array is false (ANY) even for a NULL operand.
        fn any(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const left = try E.eval(ctx, n.b);
            const right = try E.eval(ctx, node(ctx, n.b).next);
            if (right == .null_value) return .null_value;
            var reader = A.Reader.init(right.array.slice());
            var cell: V.Cell = undefined;
            var found = false;
            var unknown = false;
            while (reader.next(&cell)) {
                try ctx.session.checkpoint();
                if (E.compareOp(n.op, &left, &cell)) |matched| {
                    if (matched) {
                        found = true;
                        break;
                    }
                } else unknown = true;
            }
            const result: ?bool = if (found) true else if (unknown) null else false;
            const final = if (n.negated) (if (result) |b| !b else null) else result;
            return if (final) |b| .{ .boolean = b } else .null_value;
        }

        pub const Concat = enum { cat, append, prepend };

        /// array_cat / array_append / array_prepend (not strict).
        pub fn concat(kind: Concat, left: *const V.Cell, right: *const V.Cell, result_ty: types.Type) Error!V.Cell {
            const element = elementData(result_ty);
            switch (kind) {
                .cat => {
                    if (left.* == .null_value) return right.*;
                    if (right.* == .null_value) return left.*;
                    const a = A.shape(left.array.slice());
                    const b = A.shape(right.array.slice());
                    if (a.ndim == 0) return right.*;
                    if (b.ndim == 0) return left.*;
                    var layout: array.Shape = .{ .element = element };
                    if (a.ndim == b.ndim) {
                        layout = a;
                        layout.element = element;
                        for (1..a.ndim) |dim| if (a.dims[dim] != b.dims[dim] or a.lbounds[dim] != b.lbounds[dim]) return error.ArraySubscriptError;
                        layout.dims[0] = a.dims[0] + b.dims[0];
                    } else if (a.ndim + 1 == b.ndim or b.ndim + 1 == a.ndim) {
                        const outer = if (a.ndim > b.ndim) a else b;
                        const added = if (a.ndim > b.ndim) b else a;
                        layout = outer;
                        layout.element = element;
                        layout.dims[0] += 1;
                        for (0..added.ndim) |dim| if (added.dims[dim] != outer.dims[dim + 1] or added.lbounds[dim] != outer.lbounds[dim + 1]) return error.ArraySubscriptError;
                    } else return error.ArraySubscriptError;
                    var result: V.Text = .{};
                    var writer = try A.Writer.begin(&result, &layout);
                    for ([_]*const V.Cell{ left, right }) |source| {
                        var reader = A.Reader.init(source.array.slice());
                        var cell: V.Cell = undefined;
                        while (reader.next(&cell)) try writer.append(&cell);
                    }
                    return .{ .array = result };
                },
                .append, .prepend => {
                    const array_cell = if (kind == .append) left else right;
                    const item = if (kind == .append) right else left;
                    var layout: array.Shape = .{ .element = element, .ndim = 1, .dims = .{ 1, 0, 0, 0, 0, 0 } };
                    if (array_cell.* != .null_value) {
                        const shape = A.shape(array_cell.array.slice());
                        if (shape.ndim > 1) return error.DataException;
                        if (shape.ndim == 1) {
                            layout.lbounds[0] = shape.lbounds[0];
                            layout.dims[0] = shape.dims[0] + 1;
                            // The new element's subscript must be an int4.
                            if ((kind == .append and shape.upper(0) + 1 > 2147483647) or (kind == .prepend and @as(i64, shape.lbounds[0]) - 1 < -2147483648)) return error.IntegerOverflow;
                        }
                    }
                    var result: V.Text = .{};
                    var writer = try A.Writer.begin(&result, &layout);
                    if (kind == .prepend) try writer.append(item);
                    if (array_cell.* != .null_value) {
                        var reader = A.Reader.init(array_cell.array.slice());
                        var cell: V.Cell = undefined;
                        while (reader.next(&cell)) try writer.append(&cell);
                    }
                    if (kind == .append) try writer.append(item);
                    return .{ .array = result };
                },
            }
        }

        /// arraycontained(inner, outer): every element of `inner` equals a
        /// non-NULL element of `outer` (a NULL element is never contained).
        fn contained(inner: []const u8, outer: []const u8, session: *const Io.SessionValues) Error!bool {
            var reader = A.Reader.init(inner);
            var cell: V.Cell = undefined;
            while (reader.next(&cell)) {
                if (cell == .null_value) return false;
                if (!try member(&cell, outer, session)) return false;
            }
            return true;
        }

        fn member(cell: *const V.Cell, outer: []const u8, session: *const Io.SessionValues) Error!bool {
            var reader = A.Reader.init(outer);
            var candidate: V.Cell = undefined;
            while (reader.next(&candidate)) {
                try session.checkpoint();
                if (candidate != .null_value and V.compare(cell, &candidate) == 0) return true;
            }
            return false;
        }

        /// @> <@ && over two arrays of one type.
        pub fn containment(op: ast.Op, left: *const V.Cell, right: *const V.Cell, session: *const Io.SessionValues) Error!bool {
            const a = left.array.slice();
            const b = right.array.slice();
            switch (op) {
                .contains => return contained(b, a, session),
                .contained => return contained(a, b, session),
                else => {
                    var reader = A.Reader.init(a);
                    var cell: V.Cell = undefined;
                    while (reader.next(&cell)) {
                        if (cell != .null_value and try member(&cell, b, session)) return true;
                    }
                    return false;
                },
            }
        }

        fn remove(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const source = try E.eval(ctx, n.b);
            const needle = try E.eval(ctx, node(ctx, n.b).next);
            if (source == .null_value) return .null_value;
            var layout = A.shape(source.array.slice());
            if (layout.ndim == 0) return source;
            if (layout.ndim != 1) return error.UnsupportedStatement;
            var reader = A.Reader.init(source.array.slice());
            var cell: V.Cell = undefined;
            var kept: u32 = 0;
            while (reader.next(&cell)) {
                try ctx.session.checkpoint();
                if (V.compare(&cell, &needle) != 0) kept += 1;
            }
            if (kept == layout.dims[0]) return source;
            if (kept == 0) return empty(layout.element);

            layout.dims[0] = kept;
            var out: V.Text = .{};
            var writer = try A.Writer.begin(&out, &layout);
            reader = A.Reader.init(source.array.slice());
            while (reader.next(&cell)) {
                try ctx.session.checkpoint();
                if (V.compare(&cell, &needle) != 0) try writer.append(&cell);
            }
            return .{ .array = out };
        }

        /// array_to_string(array, delimiter [, null_string]).
        fn toString(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const source = try E.eval(ctx, n.b);
            const delimiter_id = node(ctx, n.b).next;
            const delimiter = try E.eval(ctx, delimiter_id);
            const null_id = node(ctx, delimiter_id).next;
            const null_text: V.Cell = if (null_id == none) .null_value else try E.eval(ctx, null_id);
            if (source == .null_value or delimiter == .null_value) return .null_value;
            var out: V.Text = .{};
            var first = true;
            var reader = A.Reader.init(source.array.slice());
            var cell: V.Cell = undefined;
            var buffer: [Io.format_bytes]u8 = undefined;
            while (reader.next(&cell)) {
                try ctx.session.checkpoint();
                const text = if (cell == .null_value) (if (null_text == .null_value) continue else null_text.text.slice()) else try Io.format(&cell, false, ctx.session, &buffer);
                if (!first) try append(&out, delimiter.text.slice());
                try append(&out, text);
                first = false;
            }
            return .{ .text = out };
        }

        fn append(out: *V.Text, bytes: []const u8) Error!void {
            if (bytes.len > config.text_bytes - out.len) return error.TextCapacity;
            @memcpy(out.bytes[out.len..][0..bytes.len], bytes);
            out.len += bytes.len;
        }

        /// array_length/array_lower/array_upper (NULL outside the
        /// dimensions), cardinality, array_ndims and array_dims (NULL for
        /// the empty array).
        fn measure(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const source = try E.eval(ctx, n.b);
            const dim_id = node(ctx, n.b).next;
            const dim_cell: V.Cell = if (dim_id == none) .null_value else try E.eval(ctx, dim_id);
            if (source == .null_value or (dim_id != none and dim_cell == .null_value)) return .null_value;
            const shape = A.shape(source.array.slice());
            switch (n.func) {
                .cardinality => return .{ .integer = @intCast(shape.count()) },
                .array_ndims => return if (shape.ndim == 0) .null_value else .{ .integer = @intCast(shape.ndim) },
                .array_dims => {
                    if (shape.ndim == 0) return .null_value;
                    var buffer: [array.max_dims * 26]u8 = undefined;
                    return textCell(try Io.ArrayText.dimensions(&shape, &buffer));
                },
                else => {},
            }
            const dim = dim_cell.integer;
            if (dim < 1 or dim > shape.ndim) return .null_value;
            const index: usize = @intCast(dim - 1);
            return .{ .integer = switch (n.func) {
                .array_length => shape.dims[index],
                .array_lower => shape.lbounds[index],
                .array_upper => shape.upper(index),
                else => unreachable,
            } };
        }
    };
}
