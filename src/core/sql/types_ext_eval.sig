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
const multirange = @import("multirange.sig");
const xml_publish = @import("xml_publish.sig");
const lexer = @import("lexer.sig");
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
            if (n.func == .multirange_constructor) return construct(ctx, n);
            const args = try arguments(ctx, n);
            // Every function here is strict.
            for (args.cells[0..args.count]) |*cell| if (cell.* == .null_value) return .null_value;
            const a = &args.cells[0];
            const b = &args.cells[1];
            return switch (n.func) {
                .ext_op => if (a.* == .multirange or b.* == .multirange) multirangeOperator(@enumFromInt(n.integer), a, b) else if (a.* == .geo or b.* == .geo or a.* == .point or a.* == .box) geometryOperator(@enumFromInt(n.integer), a, b) else operator(@enumFromInt(n.integer), a, b, args.count, n.ty),
                .geo_call => geometryCall(@enumFromInt(n.integer), &args),
                .multirange_of => value.Io(config).multirangeOf(a),
                .range_merge => blk: {
                    if (args.count == 2) {
                        // The smallest range covering both (range_merge(r, r)).
                        const x = R.decode(a.range.slice());
                        const y = R.decode(b.range.slice());
                        if (x.empty) break :blk b.*;
                        if (y.empty) break :blk a.*;
                        const lower = if (R.compareBounds(&x.lower, &y.lower) < 0) x.lower else y.lower;
                        const upper = if (R.compareBounds(&x.upper, &y.upper) > 0) x.upper else y.upper;
                        break :blk rangeCell(&(try R.make(x.subtype, lower, upper, false)));
                    }
                    break :blk rangeCell(&M.span(a.multirange.slice()));
                },
                .mr_call => blk: {
                    const span = M.span(a.multirange.slice());
                    break :blk switch (@as(ast.MultirangeFn, @enumFromInt(n.integer))) {
                        .lower => if (span.empty or span.lower.infinite) .null_value else span.lower.value,
                        .upper => if (span.empty or span.upper.infinite) .null_value else span.upper.value,
                        .isempty => .{ .boolean = span.empty },
                        .lower_inc => .{ .boolean = !span.empty and !span.lower.infinite and span.lower.inclusive },
                        .upper_inc => .{ .boolean = !span.empty and !span.upper.infinite and span.upper.inclusive },
                        .lower_inf => .{ .boolean = !span.empty and span.lower.infinite },
                        .upper_inf => .{ .boolean = !span.empty and span.upper.infinite },
                    };
                },
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

        const R = V.Ranges;
        const M = V.Multiranges;
        const Io = value.Io(config);
        const P = xml_publish;

        /// An identifier of the statement (folded unless quoted).
        fn identText(ctx: *const E.Context, ident: ast.Ident, buffer: []u8) Error![]const u8 {
            if (ident.len > buffer.len) return error.NameCapacity;
            const len = ident.len;
            if (ident.quoted) {
                lexer.decodeQuotedIdentifier(ctx.source, .{ .start = ident.span.start, .end = ident.span.start + ident.span.len, .len = ident.len }, buffer);
            } else for (ident.span.slice(ctx.source)[0..len], 0..) |byte, index| {
                buffer[index] = types.lower(byte);
            }
            return buffer[0..len];
        }

        const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

        /// map_sql_value_to_xml_value: xml as is, booleans true/false,
        /// timestamps in XML Schema form, bytea in base64, arrays as
        /// <element> sequences, everything else its output text (escaped
        /// when `escape`).
        fn xmlValue(cell: *const V.Cell, escape: bool, session: *const value.Session, out: *P.Out) Error!void {
            switch (cell.*) {
                .null_value => {},
                .xml => |*text| try out.add(text.slice()),
                .boolean => |flag| try out.add(if (flag) "true" else "false"),
                .bytea => |*bytes| {
                    const data = bytes.slice();
                    // xmlbinary (B11 wave 5 xml lane): hex, or base64 with
                    // libxml2's CRLF after every 72 characters.
                    if (session.xml_binary_hex) {
                        const digits = "0123456789ABCDEF";
                        for (data) |byte| {
                            try out.byte(digits[byte >> 4]);
                            try out.byte(digits[byte & 15]);
                        }
                        return;
                    }
                    var index: usize = 0;
                    var line: usize = 0;
                    while (index < data.len) : (index += 3) {
                        if (line >= 72) {
                            try out.add(&.{ 13, 10 });
                            line = 0;
                        }
                        line += 4;
                        const rest = data.len - index;
                        const word: u32 = @as(u32, data[index]) << 16 | (if (rest > 1) @as(u32, data[index + 1]) << 8 else 0) | (if (rest > 2) @as(u32, data[index + 2]) else 0);
                        try out.byte(base64_alphabet[word >> 18]);
                        try out.byte(base64_alphabet[(word >> 12) & 63]);
                        try out.byte(if (rest > 1) base64_alphabet[(word >> 6) & 63] else '=');
                        try out.byte(if (rest > 2) base64_alphabet[word & 63] else '=');
                    }
                },
                .array => |*items| {
                    var reader = V.Arrays.Reader.init(items.slice());
                    var element: V.Cell = undefined;
                    while (reader.next(&element)) {
                        if (element == .null_value) continue;
                        try out.add("<element>");
                        try xmlValue(&element, true, session, out);
                        try out.add("</element>");
                    }
                },
                else => {
                    var buffer: [Io.format_bytes]u8 = undefined;
                    var shown = try Io.format(cell, false, session, &buffer);
                    if (cell.* == .timestamp or cell.* == .timestamptz) {
                        // XML Schema dateTime: 'T' between date and time,
                        // and a +hh offset as +hh:mm.
                        for (buffer[0..shown.len]) |*c| if (c.* == ' ') {
                            c.* = 'T';
                        };
                        if (cell.* == .timestamptz and shown.len >= 3 and (shown[shown.len - 3] == '+' or shown[shown.len - 3] == '-')) {
                            buffer[shown.len] = ':';
                            buffer[shown.len + 1] = '0';
                            buffer[shown.len + 2] = '0';
                            shown = buffer[0 .. shown.len + 3];
                        }
                    }
                    if (escape) try P.text(shown, out) else try out.add(shown);
                },
            }
        }

        fn xmlCell(out: *const P.Out, text: *V.Text) V.Cell {
            text.len = out.len;
            return .{ .xml = text.* };
        }

        /// XMLELEMENT, XMLFOREST, XMLCONCAT, XMLCOMMENT, XMLPI, XMLROOT.
        pub fn xmlCall(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            var text: V.Text = .{};
            var out: P.Out = .{ .bytes = &text.bytes };
            var name_buffer: [256]u8 = undefined;
            switch (n.func) {
                .xmlelement => {
                    const element = try identText(ctx, node(ctx, n.b).name, &name_buffer);
                    try out.byte('<');
                    const name_start = out.len;
                    try P.name(element, &out);
                    const name_end = out.len;
                    var item = node(ctx, n.b).next;
                    for (0..@as(usize, @intCast(n.integer))) |_| {
                        const attribute = node(ctx, item);
                        const cell = try E.eval(ctx, attribute.b);
                        if (cell != .null_value) {
                            try out.byte(' ');
                            try P.name(try identText(ctx, attribute.name, &name_buffer), &out);
                            try out.add("=\"");
                            var value_text: V.Text = .{};
                            var value_out: P.Out = .{ .bytes = &value_text.bytes };
                            try xmlValue(&cell, false, ctx.session, &value_out);
                            try P.attribute(value_out.slice(), &out);
                            try out.byte('"');
                        }
                        item = attribute.next;
                    }
                    var content = false;
                    while (item != none) : (item = node(ctx, item).next) {
                        const cell = try E.eval(ctx, item);
                        if (cell == .null_value) continue;
                        if (!content) try out.byte('>');
                        content = true;
                        try xmlValue(&cell, true, ctx.session, &out);
                    }
                    if (!content) return blk: {
                        try out.add("/>");
                        break :blk xmlCell(&out, &text);
                    };
                    try out.add("</");
                    var tag: [512]u8 = undefined;
                    const tag_len = name_end - name_start;
                    if (tag_len > tag.len) return error.TextCapacity;
                    @memcpy(tag[0..tag_len], text.bytes[name_start..name_end]);
                    try out.add(tag[0..tag_len]);
                    try out.byte('>');
                    return xmlCell(&out, &text);
                },
                .xmlforest => {
                    var any = false;
                    var item = n.b;
                    while (item != none) : (item = node(ctx, item).next) {
                        const attribute = node(ctx, item);
                        const cell = try E.eval(ctx, attribute.b);
                        if (cell == .null_value) continue;
                        any = true;
                        const tag = try identText(ctx, attribute.name, &name_buffer);
                        try out.byte('<');
                        try P.name(tag, &out);
                        try out.byte('>');
                        try xmlValue(&cell, true, ctx.session, &out);
                        try out.add("</");
                        try P.name(tag, &out);
                        try out.byte('>');
                    }
                    return if (any) xmlCell(&out, &text) else .null_value;
                },
                .xmlconcat => {
                    var any = false;
                    var item = n.b;
                    while (item != none) : (item = node(ctx, item).next) {
                        const cell = try E.eval(ctx, item);
                        if (cell == .null_value) continue;
                        any = true;
                        try out.add(cell.xml.slice());
                    }
                    return if (any) xmlCell(&out, &text) else .null_value;
                },
                .xmlcomment => {
                    const cell = try E.eval(ctx, n.b);
                    if (cell == .null_value) return .null_value;
                    // xmltext(text) shares the node: its text, escaped.
                    var called: [16]u8 = undefined;
                    if (types.same(try identText(ctx, n.name, &called), "xmltext")) {
                        try P.text(cell.text.slice(), &out);
                        return xmlCell(&out, &text);
                    }
                    try P.comment(cell.text.slice(), &out);
                    return xmlCell(&out, &text);
                },
                .xmlpi => {
                    const target = try identText(ctx, node(ctx, n.b).name, &name_buffer);
                    const content_id = node(ctx, n.b).next;
                    var content: ?[]const u8 = null;
                    var cell: V.Cell = .null_value;
                    if (content_id != none) {
                        cell = try E.eval(ctx, content_id);
                        if (cell == .null_value) {
                            // The target is still checked (2200T).
                            if (types.keyword(target, "xml")) return error.InvalidXmlProcessingInstruction;
                            return .null_value;
                        }
                        content = cell.text.slice();
                    }
                    try P.processingInstruction(target, content, &out);
                    return xmlCell(&out, &text);
                },
                .xmlroot => {
                    const cell = try E.eval(ctx, n.b);
                    var version: ?[]const u8 = null;
                    var version_cell: V.Cell = .null_value;
                    if (n.integer & 1 != 0) {
                        version_cell = try E.eval(ctx, node(ctx, n.b).next);
                        if (version_cell != .null_value) version = version_cell.text.slice();
                    }
                    if (cell == .null_value) return .null_value;
                    const standalone: ?bool = switch ((n.integer >> 1) & 3) {
                        1 => true,
                        2 => false,
                        else => null,
                    };
                    try P.root(cell.xml.slice(), version, standalone, &out);
                    return xmlCell(&out, &text);
                },
                else => return error.UnsupportedStatement,
            }
        }

        /// XMLAGG: the concatenation of the non-NULL inputs.
        pub fn xmlAggregate(cells: []const V.Cell, handles: []const u32, session: *const value.Session) Error!V.Cell {
            if (handles.len == 0) return .null_value;
            var text: V.Text = .{};
            var out: P.Out = .{ .bytes = &text.bytes };
            for (handles) |handle| {
                try session.checkpoint();
                try out.add(cells[handle].xml.slice());
            }
            return xmlCell(&out, &text);
        }

        fn rangeCell(range: *const R.Range) Error!V.Cell {
            var text: V.Text = .{};
            try R.encode(range, &text);
            return .{ .range = text };
        }

        /// int4multirange(r1, r2, ...): not strict; one NULL argument gives
        /// NULL, a NULL among several is 22004.
        fn construct(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const range_type = multirange.rangeOf(types.dataTypeOf(n.ty)).?;
            var set: V.Text = .{};
            var scratch: V.Text = .{};
            M.empty(range_type, &set);
            var item = n.b;
            while (item != none) : (item = node(ctx, item).next) {
                const cell = try E.eval(ctx, item);
                if (cell == .null_value) return if (n.integer == 1) .null_value else error.NullValueNotAllowed;
                const range = R.decode(cell.range.slice());
                try M.add(&set, &range, &scratch);
            }
            return .{ .multirange = set };
        }

        /// The ranges of a multirange as an array of its range type (unnest).
        pub fn rangesArray(cell: *const V.Cell) Error!V.Cell {
            const bytes = cell.multirange.slice();
            const total = M.count(bytes);
            var result: V.Text = .{};
            var writer = try V.Arrays.Writer.begin(&result, &.{ .element = M.rangeType(bytes), .ndim = if (total == 0) 0 else 1, .dims = .{ @intCast(total), 0, 0, 0, 0, 0 } });
            var it = M.iterate(bytes);
            while (it.nextBytes()) |raw| {
                const range_cell: V.Cell = .{ .range = V.Text.fromValueBytes(raw) };
                try writer.append(&range_cell);
            }
            return .{ .array = result };
        }

        /// range_agg / range_intersect_agg over the collected non-NULL inputs.
        pub fn rangeAggregate(cells: []const V.Cell, handles: []const u32, unite: bool, result: types.Type, session: *const value.Session) Error!V.Cell {
            if (handles.len == 0) return .null_value;
            var set: V.Text = .{};
            var scratch: V.Text = .{};
            var next: V.Text = .{};
            if (types.isRange(result)) {
                // range_intersect_agg(anyrange): a range.
                var acc = R.decode(cells[handles[0]].range.slice());
                for (handles[1..]) |handle| {
                    try session.checkpoint();
                    const range = R.decode(cells[handle].range.slice());
                    acc = try R.intersect(&acc, &range);
                }
                return rangeCell(&acc);
            }
            const range_type = multirange.rangeOf(types.dataTypeOf(result)).?;
            const first = &cells[handles[0]];
            if (first.* == .range) {
                M.empty(range_type, &set);
                for (handles) |handle| {
                    try session.checkpoint();
                    const range = R.decode(cells[handle].range.slice());
                    try M.add(&set, &range, &scratch);
                }
                return .{ .multirange = set };
            }
            const bytes = first.multirange.slice();
            if (bytes.len > set.bytes.len) return error.TextCapacity;
            @memcpy(set.bytes[0..bytes.len], bytes);
            set.len = bytes.len;
            for (handles[1..]) |handle| {
                try session.checkpoint();
                const other = cells[handle].multirange.slice();
                if (unite) try M.unite(set.slice(), other, &next, &scratch) else try M.intersect(set.slice(), other, &next, &scratch);
                set = next;
            }
            return .{ .multirange = set };
        }

        /// Multirange operators over non-NULL operands (bound signatures).
        fn multirangeOperator(op: ast.Op, a: *const V.Cell, b: *const V.Cell) Error!V.Cell {
            var out: V.Text = .{};
            var scratch: V.Text = .{};
            switch (op) {
                .add, .sub, .mul => {
                    const x = a.multirange.slice();
                    const y = b.multirange.slice();
                    switch (op) {
                        .add => try M.unite(x, y, &out, &scratch),
                        .sub => try M.subtract(x, y, &out, &scratch),
                        else => try M.intersect(x, y, &out, &scratch),
                    }
                    return .{ .multirange = out };
                },
                .contains, .contained => {
                    const outer = if (op == .contains) a else b;
                    const inner = if (op == .contains) b else a;
                    if (outer.* == .range) {
                        // range @> multirange: the span must fit.
                        const range = R.decode(outer.range.slice());
                        const span = M.span(inner.multirange.slice());
                        return .{ .boolean = R.contains(&range, &span) };
                    }
                    const set = outer.multirange.slice();
                    return .{ .boolean = switch (inner.*) {
                        .multirange => M.containsMultirange(set, inner.multirange.slice()),
                        .range => M.containsRange(set, &R.decode(inner.range.slice())),
                        else => M.containsElement(set, inner),
                    } };
                },
                else => {},
            }
            // Span-based: && (any pair), << >> &< &> -|-.
            const x = if (a.* == .multirange) M.span(a.multirange.slice()) else R.decode(a.range.slice());
            const y = if (b.* == .multirange) M.span(b.multirange.slice()) else R.decode(b.range.slice());
            return .{ .boolean = switch (op) {
                .overlap => blk: {
                    if (a.* == .multirange and b.* == .multirange) break :blk M.overlapsMultirange(a.multirange.slice(), b.multirange.slice());
                    if (a.* == .multirange) break :blk M.overlapsRange(a.multirange.slice(), &y);
                    break :blk M.overlapsRange(b.multirange.slice(), &x);
                },
                .shift_left => R.before(&x, &y),
                .shift_right => R.before(&y, &x),
                .over_left => R.overLeft(&x, &y),
                .over_right => R.overRight(&x, &y),
                .adjacent => try R.adjacent(&x, &y),
                else => return error.UndefinedFunction,
            } };
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
