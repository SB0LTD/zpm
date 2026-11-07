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
                else => measure(ctx, n),
            };
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
