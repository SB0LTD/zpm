//! Evaluation of the B11 wave-4 types-ext functions and operators (Layer
//! 0): network address functions and arithmetic (network.sig), macaddr8.
//!
//! Operators of these types are bound as calls of `ext_op` whose
//! `integer` is the ast.Op and whose arguments are the operands (one for
//! a prefix operator); they are named ?column? like PostgreSQL's.
//! `TypesExt(config, E)` is instantiated by expr.sig's `Eval` (`E`).
const types = @import("types.sig");
const ast = @import("ast.sig");
const value = @import("value.sig");
const network = @import("network.sig");
const Error = types.Error;
const none = ast.none;

pub fn TypesExt(comptime config: types.Config, comptime E: type) type {
    const V = types.Values(config);
    return struct {
        fn node(ctx: *const E.Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        fn textCell(bytes: []const u8) Error!V.Cell {
            if (bytes.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = bytes.len };
            @memcpy(text.bytes[0..bytes.len], bytes);
            return .{ .text = text };
        }

        /// Arguments of a call (at most four), NULL when absent.
        const Args = struct { cells: [4]V.Cell = @splat(.null_value), count: usize = 0 };

        fn arguments(ctx: *const E.Context, n: *const ast.Node) Error!Args {
            var out: Args = .{};
            var item = n.b;
            while (item != none and out.count < out.cells.len) : (item = node(ctx, item).next) {
                out.cells[out.count] = try E.eval(ctx, item);
                out.count += 1;
            }
            return out;
        }

        pub fn call(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const args = try arguments(ctx, n);
            // Every function here is strict.
            for (args.cells[0..args.count]) |*cell| if (cell.* == .null_value) return .null_value;
            const a = &args.cells[0];
            const b = &args.cells[1];
            return switch (n.func) {
                .ext_op => operator(@enumFromInt(n.integer), a, b, args.count, n.ty),
                .inet_abbrev => blk: {
                    var buffer: [64]u8 = undefined;
                    break :blk textCell(if (a.inet.cidr) network.abbrevCidr(&a.inet, &buffer) else network.format(&a.inet, false, &buffer));
                },
                .set_masklen => .{ .inet = try network.setMasklen(&a.inet, b.integer) },
                .hostmask => .{ .inet = network.hostmask(&a.inet) },
                .inet_merge => .{ .inet = try network.merge(&a.inet, &b.inet) },
                .inet_same_family => .{ .boolean = a.inet.family == b.inet.family },
                .macaddr8_set7bit => blk: {
                    var out = a.macaddr8;
                    out[0] |= 0x02;
                    break :blk .{ .macaddr8 = out };
                },
                .to_macaddr8 => .{ .macaddr8 = network.mac8FromMac(&a.macaddr) },
                .to_macaddr => .{ .macaddr = try network.macFromMac8(&a.macaddr8) },
                .mac_trunc => switch (a.*) {
                    .macaddr => |mac| .{ .macaddr = .{ mac[0], mac[1], mac[2], 0, 0, 0 } },
                    else => .{ .macaddr8 = .{ a.macaddr8[0], a.macaddr8[1], a.macaddr8[2], 0, 0, 0, 0, 0 } },
                },
                else => error.UnsupportedStatement,
            };
        }

        /// Operators over non-NULL operands.
        fn operator(op: ast.Op, a: *const V.Cell, b: *const V.Cell, count: usize, result: types.Type) Error!V.Cell {
            _ = result;
            switch (a.*) {
                .inet => |*left| switch (op) {
                    .add => return .{ .inet = try network.add(left, b.integer) },
                    .sub => {
                        if (b.* == .inet) return .{ .integer = try network.difference(left, &b.inet) };
                        // inet - int8: internal_inetpl(ip, -addend).
                        return .{ .inet = try network.add(left, -%b.integer) };
                    },
                    .bit_and => return .{ .inet = try network.bitwise(.both, left, &b.inet) },
                    .bit_or => return .{ .inet = try network.bitwise(.either, left, &b.inet) },
                    .bit_not => return .{ .inet = try network.bitwise(.not, left, left) },
                    else => return error.UndefinedFunction,
                },
                .integer => |addend| {
                    // int8 + inet.
                    if (op != .add or count != 2) return error.UndefinedFunction;
                    return .{ .inet = try network.add(&b.inet, addend) };
                },
                .macaddr => |left| {
                    var out: network.Mac = undefined;
                    for (&out, 0..) |*byte, index| byte.* = switch (op) {
                        .bit_and => left[index] & b.macaddr[index],
                        .bit_or => left[index] | b.macaddr[index],
                        .bit_not => ~left[index],
                        else => return error.UndefinedFunction,
                    };
                    return .{ .macaddr = out };
                },
                .macaddr8 => |left| {
                    var out: network.Mac8 = undefined;
                    for (&out, 0..) |*byte, index| byte.* = switch (op) {
                        .bit_and => left[index] & b.macaddr8[index],
                        .bit_or => left[index] | b.macaddr8[index],
                        .bit_not => ~left[index],
                        else => return error.UndefinedFunction,
                    };
                    return .{ .macaddr8 = out };
                },
                else => return error.UndefinedFunction,
            }
        }
    };
}
