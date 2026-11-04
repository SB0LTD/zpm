//! Evaluation of the B11 builtin function families (Layer 0).
//!
//! `Builtins(config, E)` is instantiated by expr.sig's `Eval` (`E`); it
//! evaluates the bound argument list left to right (PostgreSQL evaluates
//! every argument before applying a strict function's NULL rule), then calls
//! the allocator-free kernels in functions_string.sig and friends. A planned
//! NULL call (a syntactic NULL argument, see binder.bindSignature) returns
//! NULL without executing its arguments.
const types = @import("types.sig");
const ast = @import("ast.sig");
const strings = @import("functions_string.sig");
const Error = types.Error;
const none = ast.none;

pub fn Builtins(comptime config: types.Config, comptime E: type) type {
    const V = types.Values(config);
    return struct {
        const max_args = 4;

        fn node(ctx: *const E.Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        /// Evaluates every argument; true when one is NULL (strict result).
        fn arguments(ctx: *const E.Context, n: *const ast.Node, cells: *[max_args]V.Cell) Error!bool {
            var any_null = false;
            var item = n.b;
            var index: usize = 0;
            while (item != none) : (item = node(ctx, item).next) {
                if (index == max_args) return error.UndefinedFunction;
                cells[index] = try E.eval(ctx, item);
                if (cells[index] == .null_value) any_null = true;
                index += 1;
            }
            return any_null;
        }

        fn textOf(cell: *const V.Cell) []const u8 {
            return cell.text.slice();
        }

        fn int32Of(cell: *const V.Cell) i32 {
            return @intCast(cell.integer);
        }

        fn textCell(bytes: []const u8) Error!V.Cell {
            if (bytes.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = bytes.len };
            @memcpy(text.bytes[0..bytes.len], bytes);
            return .{ .text = text };
        }

        pub fn call(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            if (n.planned_null) return .null_value;
            const control = ctx.session.control;
            switch (n.func) {
                .concat, .concat_ws => return concat(ctx, n),
                else => {},
            }
            var cells: [max_args]V.Cell = undefined;
            if (try arguments(ctx, n, &cells)) return .null_value;
            var result: V.Text = .{};
            var out: strings.Out = .{ .bytes = &result.bytes };
            const count = argumentCount(ctx, n);
            switch (n.func) {
                .lower => try strings.mapCase(textOf(&cells[0]), .lower, &out, control),
                .upper => try strings.mapCase(textOf(&cells[0]), .upper, &out, control),
                .initcap => try strings.mapCase(textOf(&cells[0]), .initcap, &out, control),
                .char_length => return .{ .integer = @intCast(try strings.charLength(textOf(&cells[0]), control)) },
                .octet_length => return .{ .integer = @intCast(textOf(&cells[0]).len) },
                .bit_length => return .{ .integer = @as(i64, @intCast(textOf(&cells[0]).len)) * 8 },
                .ascii => return .{ .integer = strings.ascii(textOf(&cells[0])) },
                .substring => return textCell(try strings.substring(textOf(&cells[0]), cells[1].integer, if (count == 3) cells[2].integer else null, control)),
                .btrim, .ltrim, .rtrim => {
                    const set = if (count == 2) textOf(&cells[1]) else " ";
                    return textCell(try strings.trim(textOf(&cells[0]), set, n.func != .rtrim, n.func != .ltrim, control));
                },
                .strpos => return .{ .integer = try strings.position(textOf(&cells[0]), textOf(&cells[1]), control) },
                .starts_with => return .{ .boolean = strings.startsWith(textOf(&cells[0]), textOf(&cells[1])) },
                .replace => try strings.replace(textOf(&cells[0]), textOf(&cells[1]), textOf(&cells[2]), &out, control),
                .translate => try strings.translate(textOf(&cells[0]), textOf(&cells[1]), textOf(&cells[2]), &out, control),
                .left => return textCell(try strings.left(textOf(&cells[0]), int32Of(&cells[1]), control)),
                .right => return textCell(try strings.right(textOf(&cells[0]), int32Of(&cells[1]), control)),
                .repeat => try strings.repeat(textOf(&cells[0]), int32Of(&cells[1]), &out, control),
                .reverse => try strings.reverse(textOf(&cells[0]), &out, control),
                .lpad, .rpad => try strings.pad(textOf(&cells[0]), int32Of(&cells[1]), if (count == 3) textOf(&cells[2]) else " ", n.func == .lpad, &out, control),
                .split_part => return textCell(try strings.splitPart(textOf(&cells[0]), textOf(&cells[1]), int32Of(&cells[2]), control)),
                .chr => try strings.chr(cells[0].integer, &out),
                .overlay => {
                    const placing = textOf(&cells[1]);
                    const length: i32 = if (count == 4) int32Of(&cells[3]) else @intCast(try strings.charLength(placing, control));
                    try strings.overlay(textOf(&cells[0]), placing, int32Of(&cells[2]), length, &out, control);
                },
                .to_hex => try strings.toHex(cells[0].integer, if (node(ctx, n.b).ty == .int8) 64 else 32, &out),
                else => unreachable,
            }
            result.len = out.len;
            return .{ .text = result };
        }

        fn argumentCount(ctx: *const E.Context, n: *const ast.Node) usize {
            var count: usize = 0;
            var item = n.b;
            while (item != none) : (item = node(ctx, item).next) count += 1;
            return count;
        }

        /// concat/concat_ws: NULL arguments are skipped; each value prints
        /// through its output function (booleans as t/f). concat_ws with a
        /// NULL separator is NULL.
        fn concat(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            var result: V.Text = .{};
            var separator: V.Cell = .null_value;
            var item = n.b;
            if (n.func == .concat_ws) {
                separator = try E.eval(ctx, item);
                item = node(ctx, item).next;
            }
            // Every argument is evaluated before the (non-strict) call.
            const null_separator = n.func == .concat_ws and separator == .null_value;
            var first = true;
            while (item != none) : (item = node(ctx, item).next) {
                const cell = try E.eval(ctx, item);
                if (cell == .null_value or null_separator) continue;
                if (!first and n.func == .concat_ws) try E.appendCell(&result, &separator, false, ctx.session);
                try E.appendCell(&result, &cell, false, ctx.session);
                first = false;
            }
            return if (null_separator) .null_value else .{ .text = result };
        }
    };
}
