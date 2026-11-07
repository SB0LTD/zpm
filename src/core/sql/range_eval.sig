//! Evaluation of range expressions (Layer 0), after rangetypes.c: the
//! int4range(...) family of constructors, lower/upper and the bound
//! predicates, and the boolean range operators (@> <@ with a range or an
//! element, && << >> &< &> -|-). + * - are value.sig's range arithmetic.
const types = @import("types.sig");
const ast = @import("ast.sig");
const value = @import("value.sig");
const Error = types.Error;
const none = ast.none;

pub fn RangeEval(comptime config: types.Config, comptime E: type) type {
    const V = types.Values(config);
    const R = V.Ranges;
    const Io = value.Io(config);
    return struct {
        fn node(ctx: *const E.Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        pub fn call(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            if (n.func == .range_constructor) {
                // Not strict: a NULL bound is infinite; NULL flags give NULL.
                const lower = try E.eval(ctx, n.b);
                const upper_id = node(ctx, n.b).next;
                const upper = try E.eval(ctx, upper_id);
                const flags_id = node(ctx, upper_id).next;
                var flags: []const u8 = "[)";
                var flags_cell: V.Cell = .null_value;
                if (flags_id != none) {
                    flags_cell = try E.eval(ctx, flags_id);
                    if (flags_cell == .null_value) return .null_value;
                    flags = flags_cell.text.slice();
                }
                return Io.RangeText.construct(n.ty, &lower, &upper, flags);
            }
            const argument = try E.eval(ctx, n.b);
            if (argument == .null_value) return .null_value;
            const range = R.decode(argument.range.slice());
            return switch (n.func) {
                .range_lower => if (range.empty or range.lower.infinite) .null_value else range.lower.value,
                .range_upper => if (range.empty or range.upper.infinite) .null_value else range.upper.value,
                .isempty => .{ .boolean = range.empty },
                .lower_inc => .{ .boolean = !range.empty and !range.lower.infinite and range.lower.inclusive },
                .upper_inc => .{ .boolean = !range.empty and !range.upper.infinite and range.upper.inclusive },
                .lower_inf => .{ .boolean = !range.empty and range.lower.infinite },
                .upper_inf => .{ .boolean = !range.empty and range.upper.infinite },
                else => unreachable,
            };
        }

        /// A boolean range operator over non-NULL operands; @> and <@ take
        /// an element on the non-range side.
        pub fn predicate(op: ast.Op, left: *const V.Cell, right: *const V.Cell) Error!bool {
            if (op == .contains and right.* != .range) return R.containsElement(&R.decode(left.range.slice()), right);
            if (op == .contained and left.* != .range) return R.containsElement(&R.decode(right.range.slice()), left);
            const a = R.decode(left.range.slice());
            const b = R.decode(right.range.slice());
            return switch (op) {
                .contains => R.contains(&a, &b),
                .contained => R.contains(&b, &a),
                .overlap => R.overlaps(&a, &b),
                .shift_left => R.before(&a, &b),
                .shift_right => R.before(&b, &a),
                .over_left => R.overLeft(&a, &b),
                .over_right => R.overRight(&a, &b),
                .adjacent => try R.adjacent(&a, &b),
                else => error.UndefinedFunction,
            };
        }
    };
}
