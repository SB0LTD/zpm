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
const geometry = @import("geometry.sig");
const geometric = @import("geometric.sig");
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
                .ext_op => if (a.* == .geo or b.* == .geo or a.* == .point or a.* == .box) geometryOperator(@enumFromInt(n.integer), a, b) else operator(@enumFromInt(n.integer), a, b, args.count, n.ty),
                .geo_call => geometryCall(@enumFromInt(n.integer), &args),
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

        fn geoCell(bytes: []const u8) Error!V.Cell {
            if (bytes.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = bytes.len };
            @memcpy(text.bytes[0..bytes.len], bytes);
            return .{ .geo = text };
        }

        fn writtenCell(text: *V.Text, out: *const geometry.Writer) V.Cell {
            text.len = out.len;
            return .{ .geo = text.* };
        }

        fn kind(cell: *const V.Cell) ?geometry.Kind {
            return if (cell.* == .geo) geometry.kindOf(cell.geo.slice()) else null;
        }

        /// The geometric functions (geo_call).
        fn geometryCall(which: ast.GeoFn, args: *const Args) Error!V.Cell {
            const a = &args.cells[0];
            const b = &args.cells[1];
            var text: V.Text = .{};
            var out: geometry.Writer = .{ .bytes = &text.bytes };
            const bytes: []const u8 = if (a.* == .geo) a.geo.slice() else &.{};
            switch (which) {
                .area => {
                    if (kind(a) == .circle) return .{ .float8 = try geometry.circleArea(geometry.circle(bytes)) };
                    return if (try geometry.pathArea(bytes)) |area| .{ .float8 = area } else .null_value;
                },
                .center => return .{ .point = geometry.circle(bytes).center },
                .length => {
                    if (kind(a) == .lseg) {
                        const segment = geometry.lseg(bytes);
                        return .{ .float8 = try geometry.distance(segment.a, segment.b) };
                    }
                    return .{ .float8 = try geometry.pathLength(bytes) };
                },
                .npoints => return .{ .integer = @intCast(geometry.count(bytes)) },
                .radius => return .{ .float8 = geometry.circle(bytes).radius },
                .diameter => return .{ .float8 = try geometry.times(geometry.circle(bytes).radius, 2.0) },
                .isclosed => return .{ .boolean = geometry.closed(bytes) },
                .isopen => return .{ .boolean = !geometry.closed(bytes) },
                .pclose, .popen => {
                    var copy = a.*;
                    copy.geo.bytes[1] = @intFromBool(which == .pclose);
                    return copy;
                },
                .slope => return .{ .float8 = try geometry.slope(a.point, b.point) },
                .diagonal => {
                    try geometry.writeLseg(&out, .{ .a = a.box.high, .b = a.box.low });
                    return writtenCell(&text, &out);
                },
                .bound_box => return .{ .box = .{
                    .high = .{ .x = @max(a.box.high.x, b.box.high.x), .y = @max(a.box.high.y, b.box.high.y) },
                    .low = .{ .x = @min(a.box.low.x, b.box.low.x), .y = @min(a.box.low.y, b.box.low.y) },
                } },
                .box => return E.cast(a.*, if (a.* == .point) .point else if (kind(a) == .circle) .circle else .polygon, .box, -1, &default_session),
                .circle => {
                    if (args.count == 2) {
                        try geometry.writeCircle(&out, .{ .center = a.point, .radius = b.float8 });
                        return writtenCell(&text, &out);
                    }
                    return E.cast(a.*, if (a.* == .box) .box else .polygon, .circle, -1, &default_session);
                },
                .line => {
                    try geometry.writeLine(&out, try geometry.lineFromPoints(a.point, b.point));
                    return writtenCell(&text, &out);
                },
                .lseg => {
                    if (args.count == 2) {
                        try geometry.writeLseg(&out, .{ .a = a.point, .b = b.point });
                    } else try geometry.writeLseg(&out, .{ .a = a.box.high, .b = a.box.low });
                    return writtenCell(&text, &out);
                },
                .path => {
                    try geometry.repoint(bytes, .path, &out);
                    return writtenCell(&text, &out);
                },
                .polygon => {
                    if (args.count == 2) {
                        try geometry.circlePolygon(a.integer, geometry.circle(b.geo.slice()), &out);
                        return writtenCell(&text, &out);
                    }
                    return E.cast(a.*, if (a.* == .box) .box else if (kind(a) == .circle) .circle else .path, .polygon, -1, &default_session);
                },
                .point => return E.cast(a.*, if (a.* == .box) .box else switch (kind(a).?) {
                    .circle => .circle,
                    .lseg => .lseg,
                    else => .polygon,
                }, .point, -1, &default_session),
                .ishorizontal, .isvertical => {
                    const horizontal = which == .ishorizontal;
                    if (args.count == 2) return .{ .boolean = if (horizontal) geometry.fpEq(a.point.y, b.point.y) else geometry.fpEq(a.point.x, b.point.x) };
                    if (kind(a) == .line) {
                        const coefficients = geometry.line(bytes);
                        return .{ .boolean = geometry.fpZero(if (horizontal) coefficients.a else coefficients.b) };
                    }
                    const segment = geometry.lseg(bytes);
                    return .{ .boolean = if (horizontal) geometry.fpEq(segment.a.y, segment.b.y) else geometry.fpEq(segment.a.x, segment.b.x) };
                },
                .isparallel, .isperp => {
                    const parallel = which == .isparallel;
                    if (kind(a) == .line) {
                        const l1 = geometry.line(bytes);
                        const l2 = geometry.line(b.geo.slice());
                        return .{ .boolean = if (parallel) try geometry.lineParallel(l1, l2) else try geometry.linePerpendicular(l1, l2) };
                    }
                    const s1 = geometry.lseg(bytes);
                    const s2 = geometry.lseg(b.geo.slice());
                    return .{ .boolean = if (parallel) try geometry.lsegParallel(s1, s2) else try geometry.lsegPerpendicular(s1, s2) };
                },
                .pt_contained_circle => return geometryOperator(.contained, a, b),
                .pt_contained_poly => return geometryOperator(.contained, a, b),
            }
        }

        const default_session: value.Session = .{};

        /// geo_ops.c operators over non-NULL operands (bound signatures only).
        fn geometryOperator(op: ast.Op, a: *const V.Cell, b: *const V.Cell) Error!V.Cell {
            const G = geometry;
            const left = kind(a);
            const right = kind(b);
            var text: V.Text = .{};
            var out: G.Writer = .{ .bytes = &text.bytes };
            switch (op) {
                .add, .sub, .mul, .div => {
                    const arithmetic: G.Arithmetic = switch (op) {
                        .add => .add,
                        .sub => .sub,
                        .mul => .mul,
                        else => .div,
                    };
                    if (a.* == .point) return .{ .point = try G.pointArithmetic(arithmetic, a.point, b.point) };
                    if (a.* == .box) {
                        const high = try G.pointArithmetic(arithmetic, a.box.high, b.point);
                        const low = try G.pointArithmetic(arithmetic, a.box.low, b.point);
                        return .{ .box = geometric.fromCorners(high, low) };
                    }
                    if (left == .circle) {
                        try G.writeCircle(&out, try G.circleArithmetic(arithmetic, G.circle(a.geo.slice()), b.point));
                        return writtenCell(&text, &out);
                    }
                    const bytes = a.geo.slice();
                    if (b.* == .geo) {
                        // path + path: open paths concatenate; NULL otherwise.
                        const other = b.geo.slice();
                        if (G.closed(bytes) or G.closed(other)) return .null_value;
                        try out.beginPoints(.path, false, G.count(bytes) + G.count(other));
                        for (0..G.count(bytes)) |i| try out.point(G.pointAt(bytes, i));
                        for (0..G.count(other)) |i| try out.point(G.pointAt(other, i));
                        return writtenCell(&text, &out);
                    }
                    try out.beginPoints(.path, G.closed(bytes), G.count(bytes));
                    for (0..G.count(bytes)) |i| try out.point(try G.pointArithmetic(arithmetic, G.pointAt(bytes, i), b.point));
                    return writtenCell(&text, &out);
                },
                .eq, .ne, .lt, .gt, .le, .ge => {
                    if (a.* == .point) return .{ .boolean = !G.samePoint(a.point, b.point) };
                    if (left == .line) return .{ .boolean = try G.sameLine(G.line(a.geo.slice()), G.line(b.geo.slice())) };
                    if (left == .path) {
                        const x = G.count(a.geo.slice());
                        const y = G.count(b.geo.slice());
                        return .{ .boolean = switch (op) {
                            .eq => x == y,
                            .lt => x < y,
                            .gt => x > y,
                            .le => x <= y,
                            else => x >= y,
                        } };
                    }
                    if (left == .lseg and (op == .eq or op == .ne)) {
                        const s = G.lseg(a.geo.slice());
                        const t = G.lseg(b.geo.slice());
                        const same = G.samePoint(s.a, t.a) and G.samePoint(s.b, t.b);
                        return .{ .boolean = if (op == .eq) same else !same };
                    }
                    // Measures: box and circle areas, lseg lengths.
                    const x: f64 = if (a.* == .box) try G.boxArea(a.box) else if (left == .circle) try G.circleArea(G.circle(a.geo.slice())) else blk: {
                        const s = G.lseg(a.geo.slice());
                        break :blk try G.distance(s.a, s.b);
                    };
                    const y: f64 = if (b.* == .box) try G.boxArea(b.box) else if (right == .circle) try G.circleArea(G.circle(b.geo.slice())) else blk: {
                        const s = G.lseg(b.geo.slice());
                        break :blk try G.distance(s.a, s.b);
                    };
                    return .{ .boolean = switch (op) {
                        .eq => G.fpEq(x, y),
                        .ne => G.fpNe(x, y),
                        .lt => G.fpLt(x, y),
                        .gt => G.fpGt(x, y),
                        .le => G.fpLe(x, y),
                        else => G.fpGe(x, y),
                    } };
                },
                .same => {
                    if (left == .polygon) return .{ .boolean = G.samePolygon(a.geo.slice(), b.geo.slice()) };
                    const c1 = G.circle(a.geo.slice());
                    const c2 = G.circle(b.geo.slice());
                    return .{ .boolean = ((c1.radius != c1.radius and c2.radius != c2.radius) or G.fpEq(c1.radius, c2.radius)) and G.samePoint(c1.center, c2.center) };
                },
                .distance => {
                    // Put the point (or the first circle/line) on the left.
                    const swapped = b.* == .point;
                    const p = if (swapped) b else a;
                    const q = if (swapped) a else b;
                    if (p.* == .point) {
                        const point = p.point;
                        if (q.* == .box) return .{ .float8 = try G.boxDistance(q.box, point) };
                        const bytes = q.geo.slice();
                        return .{ .float8 = switch (G.kindOf(bytes)) {
                            .circle => blk: {
                                const c = G.circle(bytes);
                                const d = try G.minus(try G.distance(point, c.center), c.radius);
                                break :blk if (d < 0.0) 0.0 else d;
                            },
                            .lseg => try G.lsegDistance(G.lseg(bytes), point),
                            .line => try G.lineDistance(G.line(bytes), point),
                            .path => try G.pathDistance(bytes, point),
                            .polygon => try G.polygonDistance(bytes, point),
                        } };
                    }
                    if (left == .line) return .{ .float8 = try G.lineLineDistance(G.line(a.geo.slice()), G.line(b.geo.slice())) };
                    const c1 = G.circle(a.geo.slice());
                    const c2 = G.circle(b.geo.slice());
                    const d = try G.minus(try G.distance(c1.center, c2.center), try G.plus(c1.radius, c2.radius));
                    return .{ .float8 = if (d < 0.0) 0.0 else d };
                },
                .contains, .contained => {
                    const outer = if (op == .contains) a else b;
                    const inner = if (op == .contains) b else a;
                    if (outer.* == .box) {
                        const x = outer.box;
                        const y = inner.box;
                        return .{ .boolean = G.fpGe(x.high.x, y.high.x) and G.fpLe(x.low.x, y.low.x) and G.fpGe(x.high.y, y.high.y) and G.fpLe(x.low.y, y.low.y) };
                    }
                    const bytes = outer.geo.slice();
                    switch (G.kindOf(bytes)) {
                        .circle => {
                            const c = G.circle(bytes);
                            if (inner.* == .point) return .{ .boolean = G.fpLe(try G.distance(c.center, inner.point), c.radius) };
                            const d = G.circle(inner.geo.slice());
                            return .{ .boolean = G.fpLe(try G.plus(try G.distance(c.center, d.center), d.radius), c.radius) };
                        },
                        .polygon => return .{ .boolean = try G.inside(bytes, inner.point) != 0 },
                        .path => return .{ .boolean = try G.pathContains(bytes, inner.point) },
                        .lseg => return .{ .boolean = try G.lsegContains(G.lseg(bytes), inner.point) },
                        .line => return .{ .boolean = try G.lineContains(G.line(bytes), inner.point) },
                    }
                },
                .overlap => {
                    const c1 = G.circle(a.geo.slice());
                    const c2 = G.circle(b.geo.slice());
                    return .{ .boolean = G.fpLe(try G.distance(c1.center, c2.center), try G.plus(c1.radius, c2.radius)) };
                },
                .shift_left, .shift_right, .over_left, .over_right => {
                    // Horizontal extents: box corners or circle center +- radius.
                    var low1: f64 = undefined;
                    var high1: f64 = undefined;
                    var low2: f64 = undefined;
                    var high2: f64 = undefined;
                    if (a.* == .box) {
                        low1 = a.box.low.x;
                        high1 = a.box.high.x;
                        low2 = b.box.low.x;
                        high2 = b.box.high.x;
                    } else {
                        const c1 = G.circle(a.geo.slice());
                        const c2 = G.circle(b.geo.slice());
                        low1 = try G.minus(c1.center.x, c1.radius);
                        high1 = try G.plus(c1.center.x, c1.radius);
                        low2 = try G.minus(c2.center.x, c2.radius);
                        high2 = try G.plus(c2.center.x, c2.radius);
                    }
                    return .{ .boolean = switch (op) {
                        .shift_left => G.fpLt(high1, low2),
                        .shift_right => G.fpGt(low1, high2),
                        .over_left => G.fpLe(high1, high2),
                        else => G.fpGe(low1, low2),
                    } };
                },
                else => return error.UndefinedFunction,
            }
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
