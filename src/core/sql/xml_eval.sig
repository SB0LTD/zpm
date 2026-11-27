//! SQL/XML evaluation (Layer 0, B11 wave 5 xml lane), after PostgreSQL
//! 18's xml.c over the pure-Sig tree (xml_tree.sig) and XPath 1.0 engine
//! (xpath.sig): xpath(), xpath_exists(), XMLEXISTS, IS DOCUMENT,
//! XMLSERIALIZE ... INDENT, the rows of XMLTABLE and the SQL/XML table
//! mapping functions (table_to_xml, query_to_xml, schema_to_xml,
//! database_to_xml and their XML Schema forms).
//!
//! Every operation works in the session's XML scratch region (the
//! Database's Config-sized storage), taken and released in stack order so
//! nested uses (an XPath inside an XMLTABLE DEFAULT, a mapping query that
//! calls xpath()) share it. Results larger than a cell's inline text go to
//! the statement's value region. Going over a capacity is 54000.
//!
//! The table mapping functions run their queries (the catalog lookups and
//! `SELECT * FROM table`) through the Database's xml_query hook, nested in
//! the running statement under its snapshot, as PostgreSQL runs them
//! through SPI.
const std = @import("std");
const types = @import("types.sig");
const ast = @import("ast.sig");
const value = @import("value.sig");
const xml = @import("xml.sig");
const tree = @import("xml_tree.sig");
const xpath = @import("xpath.sig");
const lexer = @import("lexer.sig");
const Error = types.Error;
const none = ast.none;

const namespace_xsi = "http://www.w3.org/2001/XMLSchema-instance";
const namespace_xsd = "http://www.w3.org/2001/XMLSchema";

/// Bytes of the Database's XML scratch region for `config`.
pub fn scratchBytes(comptime config: types.Config) usize {
    return config.xml_nodes * @sizeOf(tree.Node) + config.xpath_nodes * @sizeOf(xpath.Expr) + config.xml_bytes + 64;
}

pub fn XmlEval(comptime config: types.Config, comptime E: type) type {
    const V = types.Values(config);
    const Io = value.Io(config);
    const A = V.Arrays;
    return struct {
        fn node(ctx: *const E.Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        // ---- scratch ---------------------------------------------------------

        const Scratch = struct {
            region: *types.ValueBytes,

            fn mark(self: Scratch) usize {
                return self.region.used;
            }

            fn release(self: Scratch, to: usize) void {
                self.region.used = to;
            }

            fn take(self: Scratch, comptime T: type, count: usize) Error![]T {
                const base = @intFromPtr(self.region.bytes.ptr);
                const current = base + self.region.used;
                const aligned = (current + @alignOf(T) - 1) / @alignOf(T) * @alignOf(T);
                const at = aligned - base;
                const size = count * @sizeOf(T);
                if (at > self.region.bytes.len or size > self.region.bytes.len - at) return error.ProgramLimitExceeded;
                self.region.used = at + size;
                const pointer: [*]T = @ptrCast(@alignCast(self.region.bytes.ptr + at));
                return pointer[0..count];
            }

            /// The free bytes (not taken).
            fn rest(self: Scratch) []u8 {
                return self.region.bytes[self.region.used..];
            }

            fn append(self: Scratch, data: []const u8) Error!void {
                const out = try self.take(u8, data.len);
                @memcpy(out, data);
            }
        };

        fn scratch(ctx: *const E.Context) Error!Scratch {
            return .{ .region = ctx.session.xml_scratch orelse return error.UnsupportedStatement };
        }

        // ---- cells -------------------------------------------------------------

        /// A text-like cell of `tag` over `bytes`: inline when it fits,
        /// else copied into the statement's value region.
        fn wideCell(ctx: *const E.Context, comptime tag: std.meta.Tag(V.Cell), bytes: []const u8) Error!V.Cell {
            var text: V.Text = .{};
            if (bytes.len <= config.text_bytes) {
                text.len = bytes.len;
                @memcpy(text.bytes[0..bytes.len], bytes);
            } else {
                const region = ctx.session.value_bytes orelse return error.TextCapacity;
                text = V.Text.fromValueBytes(try region.copy(bytes));
            }
            return @unionInit(V.Cell, @tagName(tag), text);
        }

        fn textArgument(cell: *const V.Cell) []const u8 {
            return switch (cell.*) {
                .text, .bpchar, .xml => |*text| text.slice(),
                else => "",
            };
        }

        // ---- documents and expressions ----------------------------------------

        /// XPath's document (xpath_internal, XmlTableSetDocument): a well
        /// formed document whose namespaces resolve, else 2200M.
        fn document(ctx: *const E.Context, s: Scratch, text: []const u8) Error!tree.Tree {
            if (!xml.validDocument(text)) return error.InvalidXmlDocument;
            var parsed: tree.Tree = .{ .source = text, .nodes = try s.take(tree.Node, config.xml_nodes), .text = try s.take(u8, text.len + 64), .control = ctx.session.control };
            try tree.parse(&parsed, .{});
            if (parsed.namespace_error) return error.InvalidXmlDocument;
            return parsed;
        }

        /// xmlXPathCtxtCompile into scratch (the unused node slots are
        /// given back).
        fn compile(s: Scratch, text: []const u8, bindings: []const xpath.Binding) Error!xpath.Compiled {
            const exprs = try s.take(xpath.Expr, config.xpath_nodes);
            const compiled = try xpath.compile(text, bindings, exprs, config.xpath_depth);
            s.region.used = @intFromPtr(compiled.exprs.ptr) + compiled.exprs.len * @sizeOf(xpath.Expr) - @intFromPtr(s.region.bytes.ptr);
            return compiled;
        }

        /// Evaluation storage: the rest of the scratch region.
        fn space(s: Scratch) xpath.Space {
            return .{ .bytes = s.rest() };
        }

        /// An item of an XPath result as xml_xmlnodetoxmltype writes it:
        /// attributes, text and namespace nodes as their escaped string
        /// value, other nodes dumped from a copy.
        fn nodeText(t: *const tree.Tree, ctx: *xpath.Context, item: u32, out: *tree.Out) Error!void {
            const kind = t.node(item).kind;
            if (kind == .attribute or kind == .text or kind == .namespace) {
                const mark = ctx.space.mark();
                defer ctx.space.release(mark);
                try tree.escapeText(try xpath.nodeString(ctx, item), out);
                return;
            }
            try tree.dumpCopy(t, item, out);
        }

        /// map_sql_value_to_xml_value of an XPath scalar (boolean, float8
        /// or string).
        fn scalarText(ctx: *const E.Context, result: xpath.Value, out: *tree.Out) Error!void {
            switch (result) {
                .boolean => |flag| try out.add(if (flag) "true" else "false"),
                .number => |number| {
                    var buffer: [Io.format_bytes]u8 = undefined;
                    const cell: V.Cell = .{ .float8 = number };
                    try out.add(try Io.format(&cell, false, ctx.session, &buffer));
                },
                .string => |text| try tree.escapeText(text, out),
                .nodes => unreachable,
            }
        }

        /// The text[] namespace mapping of xpath(): '{}' or a 2-D array of
        /// (name, uri) pairs (22000 otherwise). Only the shape is checked
        /// here (PostgreSQL checks it first).
        fn checkNamespaces(cell: *const V.Cell) Error!void {
            const shape = A.shape(cell.array.slice());
            if (shape.ndim == 0) return;
            if (shape.ndim != 2 or shape.dims[1] != 2) return error.DataException;
        }

        /// The pairs, copied into scratch (22004 for a NULL name or URI;
        /// an empty name cannot be registered: XX000).
        fn namespaces(s: Scratch, cell: *const V.Cell) Error![]xpath.Binding {
            const bytes = cell.array.slice();
            const shape = A.shape(bytes);
            if (shape.ndim == 0) return &.{};
            const count = shape.count() / 2;
            const bindings = try s.take(xpath.Binding, count);
            var reader = A.Reader.init(bytes);
            var element: V.Cell = undefined;
            for (bindings) |*binding| {
                var parts: [2][]const u8 = undefined;
                for (&parts) |*part| {
                    if (!reader.next(&element)) return error.DataException;
                    if (element == .null_value) return error.NullValueNotAllowed;
                    const text = textArgument(&element);
                    const copy = try s.take(u8, text.len);
                    @memcpy(copy, text);
                    part.* = copy;
                }
                binding.* = .{ .prefix = parts[0], .uri = parts[1] };
            }
            for (bindings) |binding| if (binding.prefix.len == 0) return error.InternalError;
            return bindings;
        }

        /// xpath(), xpath_exists() and XMLEXISTS.
        fn evaluatePath(ctx: *const E.Context, n: *const ast.Node, which: ast.XmlFn) Error!V.Cell {
            var args: [3]V.Cell = undefined;
            var count: usize = 0;
            var item = n.b;
            while (item != none and count < args.len) : (item = node(ctx, item).next) {
                args[count] = try E.eval(ctx, item);
                count += 1;
            }
            for (args[0..count]) |*cell| if (cell.* == .null_value) return .null_value;
            if (count == 3) try checkNamespaces(&args[2]);
            const path_text = textArgument(&args[0]);
            if (path_text.len == 0) return error.InvalidArgumentForXquery;
            const s = try scratch(ctx);
            const mark = s.mark();
            defer s.release(mark);
            var parsed = try document(ctx, s, args[1].xml.slice());
            const bindings = if (count == 3) try namespaces(s, &args[2]) else &[_]xpath.Binding{};
            const compiled = try compile(s, path_text, bindings);
            var storage = space(s);
            var xctx: xpath.Context = .{ .tree = &parsed, .space = &storage, .path = &compiled, .bindings = bindings, .control = ctx.session.control };
            const result = try xpath.evaluate(&xctx, 0);
            if (which != .xpath) return .{ .boolean = if (result == .nodes) result.nodes.len != 0 else true };
            // The array is written after the evaluation's storage.
            var out: tree.Out = .{ .bytes = storage.bytes[storage.used..] };
            const items: usize = if (result == .nodes) result.nodes.len else 1;
            var shape: @import("array.sig").Shape = .{ .element = .xml };
            if (items != 0) {
                shape.ndim = 1;
                shape.dims[0] = @intCast(items);
            }
            out.len = try A.writeHeader(out.bytes, &shape);
            for (0..items) |index| {
                try ctx.session.checkpoint();
                try out.byte(1);
                const length_at = out.len;
                try out.add(&.{ 0, 0 });
                const start = out.len;
                if (result == .nodes) try nodeText(&parsed, &xctx, result.nodes[index], &out) else try scalarText(ctx, result, &out);
                const length = out.len - start;
                if (length > 0xffff) return error.TextCapacity;
                out.bytes[length_at] = @truncate(length);
                out.bytes[length_at + 1] = @truncate(length >> 8);
            }
            return wideCell(ctx, .array, out.slice());
        }

        // ---- xml_call ------------------------------------------------------------

        pub fn call(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            const which: ast.XmlFn = @enumFromInt(n.integer);
            switch (which) {
                .xpath, .xpath_exists, .xmlexists => return evaluatePath(ctx, n, which),
                .is_document => {
                    const argument = try E.eval(ctx, n.b);
                    if (argument == .null_value) return .null_value;
                    return .{ .boolean = xml.validDocument(argument.xml.slice()) };
                },
                else => return mapping(ctx, n, which),
            }
        }

        // ---- XMLSERIALIZE ... INDENT ------------------------------------------------

        /// xmltotext_with_options with indent: the value parsed without
        /// ignorable white space (as DOCUMENT, or as content unless it has
        /// a DOCTYPE; 2200L when it does not parse so) and saved formatted.
        pub fn indent(ctx: *const E.Context, text: []const u8, document_option: bool) Error!V.Cell {
            const decl = xml.declaration(text) orelse return error.NotAnXmlDocument;
            var as_document = document_option;
            if (!document_option) {
                if (!xml.validContent(text)) return error.NotAnXmlDocument;
                as_document = doctype(text[decl.len..]);
            }
            if (as_document and !xml.validDocument(text)) return error.NotAnXmlDocument;
            const s = try scratch(ctx);
            const mark = s.mark();
            defer s.release(mark);
            var parsed: tree.Tree = .{ .source = text, .nodes = try s.take(tree.Node, config.xml_nodes), .text = try s.take(u8, text.len + 64), .control = ctx.session.control };
            try tree.parse(&parsed, .{ .mode = if (as_document) .document else .content, .keep_blanks = false, .replace_entities = true });
            var out: tree.Out = .{ .bytes = s.rest() };
            const version = if (decl.version_len == 0) "1.0" else text[decl.version_start..][0..decl.version_len];
            try tree.indented(&parsed, if (as_document) .document else .content, decl.len != 0, version, decl.standalone, &out);
            // xmlSaveDoc ends a document with a newline; only DOCUMENT
            // strips it.
            if (as_document and !document_option) try out.byte(10);
            return wideCell(ctx, .text, out.slice());
        }

        /// xml_doctype_in_content: a DOCTYPE after leading comments, PIs
        /// and white space.
        fn doctype(text: []const u8) bool {
            var at: usize = 0;
            while (true) {
                while (at < text.len and (text[at] == ' ' or text[at] == '\t' or text[at] == '\n' or text[at] == '\r')) at += 1;
                if (std.mem.startsWith(u8, text[at..], "<!DOCTYPE")) return true;
                if (std.mem.startsWith(u8, text[at..], "<!--")) {
                    const end = std.mem.indexOfPos(u8, text, at + 4, "-->") orelse return false;
                    at = end + 3;
                    continue;
                }
                if (std.mem.startsWith(u8, text[at..], "<?")) {
                    const end = std.mem.indexOfPos(u8, text, at + 2, "?>") orelse return false;
                    at = end + 2;
                    continue;
                }
                return false;
            }
        }

        // ---- XMLTABLE --------------------------------------------------------------

        pub const RowSink = struct {
            context: *anyopaque,
            row: *const fn (*anyopaque, []const V.Cell) Error!void,
        };

        /// An identifier as written: unquoted folds to lower case; quoted
        /// keeps its case and collapses `""`.
        fn identifier(ctx: *const E.Context, ident: ast.Ident, out: []u8) Error![]const u8 {
            if (ident.len > out.len) return error.NameCapacity;
            if (ident.quoted) {
                lexer.decodeQuotedIdentifier(ctx.source, .{ .start = ident.span.start, .end = ident.span.start + ident.span.len, .len = ident.len }, out);
            } else for (ident.span.slice(ctx.source)[0..ident.len], 0..) |byte, index| {
                out[index] = types.lower(byte);
            }
            return out[0..ident.len];
        }

        const Column = struct { compiled: xpath.Compiled = undefined, ordinality: bool = false };

        /// The rows of XMLTABLE node `id` (nodeTableFuncscan.c with
        /// xml.c's XmlTable* routines): a NULL document gives no rows; then
        /// the namespaces (a NULL URI 22004, DEFAULT 0A000), the row path
        /// and each column path (NULL 22004, empty 10608; a missing PATH is
        /// the column name) are installed, the row path evaluated over the
        /// document and, per row node, every column: FOR ORDINALITY counts
        /// from 1; otherwise the column path over the row node (no node:
        /// NULL, then DEFAULT; one node: its string value; several: 21000,
        /// all concatenated for xml) is the column type's input, and NOT
        /// NULL rejects a NULL (22004).
        pub fn xmlTable(ctx: *const E.Context, id: u16, tys: []const types.Type, typmods: []const i32, sink: RowSink) Error!void {
            const table = node(ctx, id);
            const doc = try E.eval(ctx, table.a);
            if (doc == .null_value) return;
            const s = try scratch(ctx);
            const mark = s.mark();
            defer s.release(mark);
            var parsed = try document(ctx, s, doc.xml.slice());
            // Namespaces.
            var namespace_count: usize = 0;
            var member = table.b;
            while (member != none) : (member = node(ctx, member).next) {
                if (node(ctx, member).func == .xmltable_namespace) namespace_count += 1;
            }
            const bindings = try s.take(xpath.Binding, namespace_count);
            var bound: usize = 0;
            member = table.b;
            while (member != none) : (member = node(ctx, member).next) {
                const n = node(ctx, member);
                if (n.func != .xmltable_namespace) continue;
                const uri_cell = try E.eval(ctx, n.b);
                if (uri_cell == .null_value) return error.NullValueNotAllowed;
                if (n.integer == 1) return error.UnsupportedStatement;
                var name_buffer: [256]u8 = undefined;
                const prefix = try identifier(ctx, n.name, &name_buffer);
                const prefix_copy = try s.take(u8, prefix.len);
                @memcpy(prefix_copy, prefix);
                const uri = textArgument(&uri_cell);
                const uri_copy = try s.take(u8, uri.len);
                @memcpy(uri_copy, uri);
                bindings[bound] = .{ .prefix = prefix_copy, .uri = uri_copy };
                bound += 1;
            }
            // The row path.
            const row_cell = try E.eval(ctx, table.c);
            if (row_cell == .null_value) return error.NullValueNotAllowed;
            const row_text = textArgument(&row_cell);
            if (row_text.len == 0) return error.InvalidArgumentForXquery;
            const row_path = try compile(s, row_text, bindings);
            // Column paths.
            var columns: [config.columns]Column = @splat(.{});
            var column_count: usize = 0;
            member = table.b;
            while (member != none) : (member = node(ctx, member).next) {
                const n = node(ctx, member);
                if (n.func != .xmltable_column) continue;
                if (column_count == columns.len) return error.ColumnCapacity;
                const spec = ast.XmlTableColumn.decode(n.integer);
                const column = &columns[column_count];
                column_count += 1;
                column.ordinality = spec.ordinality;
                if (spec.ordinality) continue;
                var name_buffer: [256]u8 = undefined;
                var path_text: []const u8 = undefined;
                if (n.a != none) {
                    const path_cell = try E.eval(ctx, n.a);
                    if (path_cell == .null_value) return error.NullValueNotAllowed;
                    const text = textArgument(&path_cell);
                    const copy = try s.take(u8, text.len);
                    @memcpy(copy, text);
                    path_text = copy;
                } else {
                    const name = try identifier(ctx, n.name, &name_buffer);
                    const copy = try s.take(u8, name.len);
                    @memcpy(copy, name);
                    path_text = copy;
                }
                if (path_text.len == 0) return error.InvalidArgumentForXquery;
                column.compiled = try compile(s, path_text, bindings);
            }
            // Rows: the row path's nodes, kept apart from evaluation storage.
            var row_storage = space(s);
            var row_ctx: xpath.Context = .{ .tree = &parsed, .space = &row_storage, .path = &row_path, .bindings = bindings, .control = ctx.session.control };
            const rows = try xpath.evaluate(&row_ctx, 0);
            if (rows != .nodes) return;
            // Keep the evaluation's storage (the row set is in it), then
            // copy the rows past it.
            s.region.used += row_storage.used;
            const row_nodes = try s.take(u32, rows.nodes.len);
            for (row_nodes, rows.nodes) |*slot, row_node| slot.* = row_node;
            var ordinal: i64 = 1;
            for (row_nodes) |row_node| {
                try ctx.session.checkpoint();
                var cells: [config.columns]V.Cell = undefined;
                var column_index: usize = 0;
                member = table.b;
                while (member != none) : (member = node(ctx, member).next) {
                    const n = node(ctx, member);
                    if (n.func != .xmltable_column) continue;
                    const column = &columns[column_index];
                    const spec = ast.XmlTableColumn.decode(n.integer);
                    var cell: V.Cell = .null_value;
                    if (column.ordinality) {
                        cell = .{ .integer = ordinal };
                    } else {
                        cell = try columnValue(ctx, s, &parsed, column, bindings, row_node, tys[column_index], typmods[column_index]);
                        if (cell == .null_value and n.b != none) cell = try E.eval(ctx, n.b);
                        if (cell == .null_value and spec.not_null) return error.NullValueNotAllowed;
                    }
                    cells[column_index] = cell;
                    column_index += 1;
                }
                ordinal += 1;
                try sink.row(sink.context, cells[0..column_index]);
            }
        }

        /// XmlTableGetValue for one column of one row.
        fn columnValue(ctx: *const E.Context, s: Scratch, parsed: *tree.Tree, column: *const Column, bindings: []const xpath.Binding, row_node: u32, ty: types.Type, typmod: i32) Error!V.Cell {
            const mark = s.mark();
            defer s.release(mark);
            var storage = space(s);
            var xctx: xpath.Context = .{ .tree = parsed, .space = &storage, .path = &column.compiled, .bindings = bindings, .control = ctx.session.control };
            const result = try xpath.evaluate(&xctx, row_node);
            var out: tree.Out = .{ .bytes = storage.bytes[storage.used..] };
            var number_buffer: [64]u8 = undefined;
            var text: []const u8 = undefined;
            switch (result) {
                .nodes => |items| {
                    if (items.len == 0) return .null_value;
                    if (ty == .xml) {
                        for (items) |item| try nodeText(parsed, &xctx, item, &out);
                        text = out.slice();
                    } else {
                        if (items.len > 1) return error.CardinalityViolation;
                        text = try xpath.nodeString(&xctx, items[0]);
                    }
                },
                .string => |string| {
                    if (ty == .xml) {
                        try tree.escapeText(string, &out);
                        text = out.slice();
                    } else text = string;
                },
                .boolean => |flag| {
                    // Booleans become numbers for numeric column types.
                    text = if (value.numericCategory(ty)) (if (flag) "1" else "0") else (if (flag) "true" else "false");
                },
                .number => |number| text = xpath.formatNumber(number, &number_buffer),
            }
            return input(ctx, ty, typmod, text);
        }

        /// The column type's input function over `text`; long text and
        /// xml go to the value region.
        fn input(ctx: *const E.Context, ty: types.Type, typmod: i32, text: []const u8) Error!V.Cell {
            if (text.len > config.text_bytes and (ty == .text or ty == .xml)) {
                if (ty == .xml) {
                    if (ctx.session.xml_document) {
                        if (!xml.validDocument(text)) return error.InvalidXmlDocument;
                    } else if (!xml.validContent(text)) return error.InvalidXmlContent;
                    return wideCell(ctx, .xml, text);
                }
                return wideCell(ctx, .text, text);
            }
            return Io.parse(ty, typmod, text, ctx.session);
        }

        // ---- SQL/XML table mapping ---------------------------------------------------

        const Options = struct {
            nulls: bool = false,
            tableforest: bool = false,
            targetns: []const u8 = "",
        };

        /// map_sql_identifier_to_xml_name: ':' (anywhere when fully
        /// escaped, else only first), a '_' starting "_x", a leading "xml"
        /// when fully escaped, '.' when escape_period, and characters that
        /// are not XML name characters become _xHHHH_.
        fn mapName(identifier_text: []const u8, fully: bool, escape_period: bool, out: *tree.Out) Error!void {
            var index: usize = 0;
            while (index < identifier_text.len) {
                const c = identifier_text[index];
                var length: usize = 1;
                var code: u32 = c;
                if (c >= 0xc0) {
                    length = if (c >= 0xf0) 4 else if (c >= 0xe0) 3 else 2;
                    if (index + length > identifier_text.len) length = identifier_text.len - index;
                    code = c & (@as(u8, 0xff) >> @intCast(length + 1));
                    for (identifier_text[index + 1 .. index + length]) |next| code = code << 6 | (next & 0x3f);
                }
                if (c == ':' and (index == 0 or fully)) {
                    try out.add("_x003A_");
                } else if (c == '_' and index + 1 < identifier_text.len and identifier_text[index + 1] == 'x') {
                    try out.add("_x005F_");
                } else if (fully and index == 0 and identifier_text.len >= 3 and types.lower(c) == 'x' and types.lower(identifier_text[1]) == 'm' and types.lower(identifier_text[2]) == 'l') {
                    try out.add(if (c == 'x') "_x0078_" else "_x0058_");
                } else if (escape_period and c == '.') {
                    try out.add("_x002E_");
                } else {
                    const first_ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':' or c >= 0x80;
                    const later_ok = first_ok or (c >= '0' and c <= '9') or c == '.' or c == '-';
                    if (if (index == 0) !first_ok else !later_ok) {
                        try hexName(code, out);
                    } else try out.add(identifier_text[index .. index + length]);
                }
                index += length;
            }
        }

        fn hexName(code: u32, out: *tree.Out) Error!void {
            const digits = "0123456789ABCDEF";
            try out.add("_x");
            var buffer: [8]u8 = undefined;
            var count: usize = 0;
            var rest = code;
            while (rest != 0 or count < 4) : (rest >>= 4) {
                buffer[count] = digits[rest & 15];
                count += 1;
            }
            while (count > 0) {
                count -= 1;
                try out.byte(buffer[count]);
            }
            try out.byte('_');
        }

        /// Appends to the scratch region (the mapping output grows there).
        const Writer = struct {
            s: Scratch,
            start: usize,

            fn add(self: *Writer, data: []const u8) Error!void {
                try self.s.append(data);
            }

            fn name(self: *Writer, identifier_text: []const u8, fully: bool, escape_period: bool) Error!void {
                var buffer: [1024]u8 = undefined;
                var out: tree.Out = .{ .bytes = &buffer };
                try mapName(identifier_text, fully, escape_period, &out);
                try self.add(out.slice());
            }

            fn slice(self: *const Writer) []const u8 {
                return self.s.region.bytes[self.start..self.s.region.used];
            }
        };

        const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

        /// map_sql_value_to_xml_value (escaping strings): booleans, XSD
        /// dates and timestamps (infinite ones 22008), bytea in base64
        /// (CRLF every 72 characters) or hex per xmlbinary, arrays as
        /// <element> sequences, xml as is, other values their output text.
        fn mapValue(ctx: *const E.Context, cell: *const V.Cell, w: *Writer) Error!void {
            switch (cell.*) {
                .null_value => {},
                .xml => |*text| try w.add(text.slice()),
                .boolean => |flag| try w.add(if (flag) "true" else "false"),
                .bytea => |*bytes| {
                    const data = bytes.slice();
                    if (ctx.session.xml_binary_hex) {
                        const digits = "0123456789ABCDEF";
                        for (data) |byte| try w.add(&.{ digits[byte >> 4], digits[byte & 15] });
                        return;
                    }
                    var index: usize = 0;
                    var line: usize = 0;
                    while (index < data.len) : (index += 3) {
                        if (line >= 72) {
                            try w.add("\r\n");
                            line = 0;
                        }
                        const rest = data.len - index;
                        const word: u32 = @as(u32, data[index]) << 16 | (if (rest > 1) @as(u32, data[index + 1]) << 8 else 0) | (if (rest > 2) @as(u32, data[index + 2]) else 0);
                        try w.add(&.{
                            base64_alphabet[word >> 18],
                            base64_alphabet[(word >> 12) & 63],
                            if (rest > 1) base64_alphabet[(word >> 6) & 63] else '=',
                            if (rest > 2) base64_alphabet[word & 63] else '=',
                        });
                        line += 4;
                    }
                },
                .array => |*items| {
                    var reader = A.Reader.init(items.slice());
                    var element: V.Cell = undefined;
                    while (reader.next(&element)) {
                        try ctx.session.checkpoint();
                        if (element == .null_value) continue;
                        try w.add("<element>");
                        try mapValue(ctx, &element, w);
                        try w.add("</element>");
                    }
                },
                .text, .bpchar => |*text| try escapeTo(text.slice(), w),
                else => {
                    var buffer: [Io.format_bytes]u8 = undefined;
                    var shown = try Io.format(cell, false, ctx.session, &buffer);
                    switch (cell.*) {
                        .date => |days| if (days == std.math.minInt(i32) or days == std.math.maxInt(i32)) return error.DatetimeFieldOverflow,
                        .timestamp, .timestamptz => |us| {
                            if (us == std.math.minInt(i64) or us == std.math.maxInt(i64)) return error.DatetimeFieldOverflow;
                            // XML Schema dateTime: 'T' between date and
                            // time, a +hh offset as +hh:mm.
                            for (buffer[0..shown.len]) |*c| if (c.* == ' ') {
                                c.* = 'T';
                                break;
                            };
                            if (cell.* == .timestamptz and shown.len >= 3 and (shown[shown.len - 3] == '+' or shown[shown.len - 3] == '-')) {
                                buffer[shown.len] = ':';
                                buffer[shown.len + 1] = '0';
                                buffer[shown.len + 2] = '0';
                                shown = buffer[0 .. shown.len + 3];
                            }
                        },
                        else => {},
                    }
                    try escapeTo(shown, w);
                },
            }
        }

        fn escapeTo(data: []const u8, w: *Writer) Error!void {
            var start: usize = 0;
            for (data, 0..) |c, index| {
                const replacement: ?[]const u8 = switch (c) {
                    '&' => "&amp;",
                    '<' => "&lt;",
                    '>' => "&gt;",
                    '\r' => "&#x0d;",
                    else => null,
                };
                if (replacement) |text| {
                    try w.add(data[start..index]);
                    try w.add(text);
                    start = index + 1;
                }
            }
            try w.add(data[start..]);
        }

        /// Query results passed to the mapping writers.
        const Collector = struct {
            ctx: *const E.Context,
            w: *Writer,
            options: Options,
            /// The table element name (escaped) for rows; null: "row" /
            /// "table".
            table_name: ?[]const u8,
            top_level: bool,
            /// Columns (names mapped when they arrive).
            count: usize = 0,
            names: [config.columns][]const u8 = undefined,
            name_bytes: [config.columns * 128]u8 = undefined,
            tys: [config.columns]types.Type = undefined,
            typmods: [config.columns]i32 = undefined,

            fn columns(raw: *anyopaque, count: usize, names_raw: *const anyopaque, tys: [*]const types.Type, typmods: [*]const i32) Error!void {
                const self: *Collector = @ptrCast(@alignCast(raw));
                if (count > config.columns) return error.ColumnCapacity;
                const names: [*]const V.Name = @ptrCast(@alignCast(names_raw));
                var used: usize = 0;
                for (0..count) |index| {
                    var out: tree.Out = .{ .bytes = self.name_bytes[used..] };
                    try mapName(names[index].slice(), true, false, &out);
                    self.names[index] = self.name_bytes[used..][0..out.len];
                    used += out.len;
                    self.tys[index] = tys[index];
                    self.typmods[index] = typmods[index];
                }
                self.count = count;
            }

            /// SPI_sql_row_to_xmlelement.
            fn row(raw: *anyopaque, cells_raw: *const anyopaque) Error!void {
                const self: *Collector = @ptrCast(@alignCast(raw));
                const cells: [*]const V.Cell = @ptrCast(@alignCast(cells_raw));
                const w = self.w;
                try self.ctx.session.checkpoint();
                const element = self.table_name orelse (if (self.options.tableforest) "row" else "table");
                if (self.options.tableforest) {
                    try rootStart(w, element, null, self.options.targetns, self.top_level);
                } else try w.add("<row>\n");
                for (0..self.count) |index| {
                    const cell = &cells[index];
                    if (cell.* == .null_value) {
                        if (self.options.nulls) {
                            try w.add("  <");
                            try w.add(self.names[index]);
                            try w.add(" xsi:nil=\"true\"/>\n");
                        }
                        continue;
                    }
                    try w.add("  <");
                    try w.add(self.names[index]);
                    try w.add(">");
                    try mapValue(self.ctx, cell, w);
                    try w.add("</");
                    try w.add(self.names[index]);
                    try w.add(">\n");
                }
                if (self.options.tableforest) {
                    try rootEnd(w, element);
                    try w.add("\n");
                } else try w.add("</row>\n\n");
            }
        };

        /// xmldata_root_element_start.
        fn rootStart(w: *Writer, element: []const u8, xmlschema: ?[]const u8, targetns: []const u8, top_level: bool) Error!void {
            try w.add("<");
            try w.add(element);
            if (top_level) {
                try w.add(" xmlns:xsi=\"" ++ namespace_xsi ++ "\"");
                if (targetns.len > 0) {
                    try w.add(" xmlns=\"");
                    try w.add(targetns);
                    try w.add("\"");
                }
            }
            if (xmlschema != null) {
                if (targetns.len > 0) {
                    try w.add(" xsi:schemaLocation=\"");
                    try w.add(targetns);
                    try w.add(" #\"");
                } else try w.add(" xsi:noNamespaceSchemaLocation=\"#\"");
            }
            try w.add(">\n");
        }

        fn rootEnd(w: *Writer, element: []const u8) Error!void {
            try w.add("</");
            try w.add(element);
            try w.add(">\n");
        }

        fn hook(ctx: *const E.Context) Error!*const value.SequenceHook {
            const sequences = ctx.session.sequences orelse return error.UnsupportedStatement;
            if (sequences.xml_query == null) return error.UnsupportedStatement;
            return sequences;
        }

        fn runQuery(ctx: *const E.Context, query: []const u8, collector: *Collector) Error!void {
            const sequences = try hook(ctx);
            const sink: value.XmlQuerySink = .{ .context = collector, .columns = &Collector.columns, .row = &Collector.row };
            try sequences.xml_query.?(sequences.ptr, query, &sink);
        }

        /// query_to_xml_internal: the root element (unless a table forest),
        /// an XML Schema when given, then a row element per row.
        fn queryToXml(ctx: *const E.Context, w: *Writer, query: []const u8, table_name: ?[]const u8, xmlschema: ?[]const u8, options: Options, top_level: bool) Error!void {
            var name_buffer: [1024]u8 = undefined;
            var element: []const u8 = "table";
            if (table_name) |raw| {
                var out: tree.Out = .{ .bytes = &name_buffer };
                try mapName(raw, true, false, &out);
                element = out.slice();
            }
            if (!options.tableforest) {
                try rootStart(w, element, xmlschema, options.targetns, top_level);
                try w.add("\n");
            }
            if (xmlschema) |schema_text| {
                try w.add(schema_text);
                try w.add("\n\n");
            }
            var collector: Collector = .{ .ctx = ctx, .w = w, .options = options, .table_name = if (table_name != null) element else null, .top_level = top_level };
            try runQuery(ctx, query, &collector);
            if (!options.tableforest) try rootEnd(w, element);
        }

        // Catalog lookups through the mapping query hook.

        const Relation = struct {
            name: [128]u8 = undefined,
            name_len: usize = 0,
            schema: [128]u8 = undefined,
            schema_len: usize = 0,
            display: [300]u8 = undefined,
            display_len: usize = 0,
            found: bool = false,

            fn nameSlice(self: *const Relation) []const u8 {
                return self.name[0..self.name_len];
            }
            fn schemaSlice(self: *const Relation) []const u8 {
                return self.schema[0..self.schema_len];
            }
            fn displaySlice(self: *const Relation) []const u8 {
                return self.display[0..self.display_len];
            }
        };

        const RelationSink = struct {
            relation: *Relation,

            fn columns(_: *anyopaque, _: usize, _: *const anyopaque, _: [*]const types.Type, _: [*]const i32) Error!void {}

            fn row(raw: *anyopaque, cells_raw: *const anyopaque) Error!void {
                const self: *RelationSink = @ptrCast(@alignCast(raw));
                const cells: [*]const V.Cell = @ptrCast(@alignCast(cells_raw));
                const r = self.relation;
                r.found = true;
                inline for (.{ .{ "name", "name_len" }, .{ "schema", "schema_len" }, .{ "display", "display_len" } }, 0..) |field, index| {
                    const text = textArgument(&cells[index]);
                    const target = &@field(r, field[0]);
                    if (text.len > target.len) return error.NameCapacity;
                    @memcpy(target[0..text.len], text);
                    @field(r, field[1]) = text.len;
                }
            }
        };

        fn integerText(number: i64, buffer: []u8) []const u8 {
            var index: usize = buffer.len;
            var rest: u64 = @abs(number);
            while (true) {
                index -= 1;
                buffer[index] = @intCast('0' + rest % 10);
                rest /= 10;
                if (rest == 0) break;
            }
            if (number < 0) {
                index -= 1;
                buffer[index] = '-';
            }
            return buffer[index..];
        }

        /// The name, schema and regclass text of relation `oid`.
        fn relation(ctx: *const E.Context, oid: i64) Error!Relation {
            var query_buffer: [400]u8 = undefined;
            var number_buffer: [24]u8 = undefined;
            const query = std.fmt.bufPrint(&query_buffer, "SELECT c.relname::text, n.nspname::text, c.oid::regclass::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = {s}", .{integerText(oid, &number_buffer)}) catch return error.TextCapacity;
            var result: Relation = .{};
            var sink_state: RelationSink = .{ .relation = &result };
            const sequences = try hook(ctx);
            const sink: value.XmlQuerySink = .{ .context = &sink_state, .columns = &RelationSink.columns, .row = &RelationSink.row };
            try sequences.xml_query.?(sequences.ptr, query, &sink);
            if (!result.found) return error.TableNotFound;
            return result;
        }

        /// The relations of a schema (relkind r, m and v, by name) or of
        /// the database's visible schemas, as OIDs.
        const OidSink = struct {
            oids: []u32,
            count: usize = 0,

            fn columns(_: *anyopaque, _: usize, _: *const anyopaque, _: [*]const types.Type, _: [*]const i32) Error!void {}

            fn row(raw: *anyopaque, cells_raw: *const anyopaque) Error!void {
                const self: *OidSink = @ptrCast(@alignCast(raw));
                const cells: [*]const V.Cell = @ptrCast(@alignCast(cells_raw));
                if (self.count == self.oids.len) return error.ProgramLimitExceeded;
                self.oids[self.count] = @intCast(cells[0].integer);
                self.count += 1;
            }
        };

        fn oidQuery(ctx: *const E.Context, query: []const u8, oids: []u32) Error!usize {
            var sink_state: OidSink = .{ .oids = oids };
            const sequences = try hook(ctx);
            const sink: value.XmlQuerySink = .{ .context = &sink_state, .columns = &OidSink.columns, .row = &OidSink.row };
            try sequences.xml_query.?(sequences.ptr, query, &sink);
            return sink_state.count;
        }

        /// A string literal of `text` in SQL (quotes doubled).
        fn literal(text: []const u8, out: *tree.Out) Error!void {
            try out.byte('\'');
            for (text) |c| {
                if (c == '\'') try out.byte('\'');
                try out.byte(c);
            }
            try out.byte('\'');
        }

        const schema_tables_query = "SELECT c.oid FROM pg_catalog.pg_class c WHERE c.relnamespace = {s} AND c.relkind IN ('r', 'm', 'v') ORDER BY c.relname";
        const visible_schemas_query = "SELECT n.oid FROM pg_catalog.pg_namespace n WHERE NOT (n.nspname ~ '^pg_' OR n.nspname = 'information_schema') ORDER BY n.nspname";
        const database_tables_query = "SELECT c.oid FROM pg_catalog.pg_class c WHERE c.relkind IN ('r', 'm', 'v') AND c.relnamespace IN (SELECT n.oid FROM pg_catalog.pg_namespace n WHERE NOT (n.nspname ~ '^pg_' OR n.nspname = 'information_schema')) ORDER BY c.oid";

        /// LookupExplicitNamespace: the OID of a schema (3F000 when there
        /// is none).
        fn schemaOid(ctx: *const E.Context, name: []const u8) Error!u32 {
            var buffer: [512]u8 = undefined;
            var out: tree.Out = .{ .bytes = &buffer };
            try out.add("SELECT n.oid FROM pg_catalog.pg_namespace n WHERE n.nspname = ");
            try literal(name, &out);
            var oids: [1]u32 = undefined;
            if (try oidQuery(ctx, out.slice(), &oids) == 0) return error.UndefinedSchema;
            return oids[0];
        }

        fn schemaTables(ctx: *const E.Context, nsp: u32, oids: []u32) Error!usize {
            var buffer: [256]u8 = undefined;
            var number_buffer: [24]u8 = undefined;
            const query = std.fmt.bufPrint(&buffer, schema_tables_query, .{integerText(nsp, &number_buffer)}) catch return error.TextCapacity;
            return oidQuery(ctx, query, oids);
        }

        const NameSink = struct {
            out: []u8,
            len: usize = 0,

            fn columns(_: *anyopaque, _: usize, _: *const anyopaque, _: [*]const types.Type, _: [*]const i32) Error!void {}

            fn row(raw: *anyopaque, cells_raw: *const anyopaque) Error!void {
                const self: *NameSink = @ptrCast(@alignCast(raw));
                const cells: [*]const V.Cell = @ptrCast(@alignCast(cells_raw));
                const text = textArgument(&cells[0]);
                if (text.len > self.out.len) return error.NameCapacity;
                @memcpy(self.out[0..text.len], text);
                self.len = text.len;
            }
        };

        fn schemaName(ctx: *const E.Context, nsp: u32, out: []u8) Error![]const u8 {
            var buffer: [160]u8 = undefined;
            var number_buffer: [24]u8 = undefined;
            const query = std.fmt.bufPrint(&buffer, "SELECT n.nspname::text FROM pg_catalog.pg_namespace n WHERE n.oid = {s}", .{integerText(nsp, &number_buffer)}) catch return error.TextCapacity;
            var sink_state: NameSink = .{ .out = out };
            const sequences = try hook(ctx);
            const sink: value.XmlQuerySink = .{ .context = &sink_state, .columns = &NameSink.columns, .row = &NameSink.row };
            try sequences.xml_query.?(sequences.ptr, query, &sink);
            return out[0..sink_state.len];
        }

        /// table_to_xml_internal: SELECT * FROM the relation's regclass text.
        fn tableToXml(ctx: *const E.Context, w: *Writer, oid: i64, xmlschema: ?[]const u8, options: Options, top_level: bool) Error!void {
            const rel = try relation(ctx, oid);
            var buffer: [400]u8 = undefined;
            const query = std.fmt.bufPrint(&buffer, "SELECT * FROM {s}", .{rel.displaySlice()}) catch return error.TextCapacity;
            try queryToXml(ctx, w, query, rel.nameSlice(), xmlschema, options, top_level);
        }

        /// schema_to_xml_internal.
        fn schemaToXml(ctx: *const E.Context, w: *Writer, nsp: u32, xmlschema: ?[]const u8, options: Options, top_level: bool) Error!void {
            var name_buffer: [128]u8 = undefined;
            const schema = try schemaName(ctx, nsp, &name_buffer);
            var element_buffer: [1024]u8 = undefined;
            var element: tree.Out = .{ .bytes = &element_buffer };
            try mapName(schema, true, false, &element);
            try rootStart(w, element.slice(), xmlschema, options.targetns, top_level);
            try w.add("\n");
            if (xmlschema) |schema_text| {
                try w.add(schema_text);
                try w.add("\n\n");
            }
            var oids: [config.tables]u32 = undefined;
            const count = try schemaTables(ctx, nsp, &oids);
            for (oids[0..count]) |oid| {
                try tableToXml(ctx, w, oid, null, options, false);
                try w.add("\n");
            }
            try rootEnd(w, element.slice());
        }

        /// database_to_xml_internal.
        fn databaseToXml(ctx: *const E.Context, w: *Writer, xmlschema: ?[]const u8, options: Options) Error!void {
            var element_buffer: [1024]u8 = undefined;
            var element: tree.Out = .{ .bytes = &element_buffer };
            try mapName(ctx.session.database, true, false, &element);
            try rootStart(w, element.slice(), xmlschema, options.targetns, true);
            try w.add("\n");
            if (xmlschema) |schema_text| {
                try w.add(schema_text);
                try w.add("\n\n");
            }
            var schemas: [config.schemas + 4]u32 = undefined;
            const count = try oidQuery(ctx, visible_schemas_query, &schemas);
            for (schemas[0..count]) |nsp| {
                try schemaToXml(ctx, w, nsp, null, options, false);
                try w.add("\n");
            }
            try rootEnd(w, element.slice());
        }

        // XML Schema (map_sql_*_to_xmlschema).

        fn xsdStart(w: *Writer, targetns: []const u8) Error!void {
            try w.add("<xsd:schema\n    xmlns:xsd=\"" ++ namespace_xsd ++ "\"");
            if (targetns.len > 0) {
                try w.add("\n    targetNamespace=\"");
                try w.add(targetns);
                try w.add("\"\n    elementFormDefault=\"qualified\"");
            }
            try w.add(">\n\n");
        }

        /// map_multipart_sql_identifier_to_xml_name.
        fn multipart(w: *Writer, parts: []const []const u8) Error!void {
            for (parts, 0..) |part, index| {
                if (index != 0) try w.add(".");
                try w.name(part, true, true);
            }
        }

        /// map_sql_type_to_xml_name (typmod -1, as the table mappings use).
        fn typeName(ctx: *const E.Context, w: *Writer, ty: types.Type) Error!void {
            const fixed: ?[]const u8 = switch (ty) {
                .bpchar => "CHAR",
                .varchar => "VARCHAR",
                .numeric => "NUMERIC",
                .int4 => "INTEGER",
                .int2 => "SMALLINT",
                .int8 => "BIGINT",
                .float4 => "REAL",
                .float8 => "DOUBLE",
                .boolean => "BOOLEAN",
                .time => "TIME",
                .timetz => "TIME_WTZ",
                .timestamp => "TIMESTAMP",
                .timestamptz => "TIMESTAMP_WTZ",
                .date => "DATE",
                .xml => "XML",
                else => null,
            };
            if (fixed) |text| return w.add(text);
            try multipart(w, &.{ "UDT", ctx.session.database, "pg_catalog", types.typeInfo(types.dataTypeOf(ty)).name });
        }

        /// map_sql_type_to_xmlschema_type (typmod -1).
        fn schemaType(ctx: *const E.Context, w: *Writer, ty: types.Type) Error!void {
            if (ty == .xml) {
                try w.add("<xsd:complexType mixed=\"true\">\n  <xsd:sequence>\n    <xsd:any name=\"element\" minOccurs=\"0\" maxOccurs=\"unbounded\" processContents=\"skip\"/>\n  </xsd:sequence>\n</xsd:complexType>\n");
                return;
            }
            try w.add("<xsd:simpleType name=\"");
            try typeName(ctx, w, ty);
            try w.add("\">\n");
            switch (ty) {
                .bpchar, .varchar, .text => try w.add("  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n"),
                .bytea => try w.add(if (ctx.session.xml_binary_hex) "  <xsd:restriction base=\"xsd:hexBinary\">\n  </xsd:restriction>\n" else "  <xsd:restriction base=\"xsd:base64Binary\">\n  </xsd:restriction>\n"),
                .int2 => try w.add("  <xsd:restriction base=\"xsd:short\">\n    <xsd:maxInclusive value=\"32767\"/>\n    <xsd:minInclusive value=\"-32768\"/>\n  </xsd:restriction>\n"),
                .int4 => try w.add("  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n"),
                .int8 => try w.add("  <xsd:restriction base=\"xsd:long\">\n    <xsd:maxInclusive value=\"9223372036854775807\"/>\n    <xsd:minInclusive value=\"-9223372036854775808\"/>\n  </xsd:restriction>\n"),
                .float4 => try w.add("  <xsd:restriction base=\"xsd:float\"></xsd:restriction>\n"),
                .float8 => try w.add("  <xsd:restriction base=\"xsd:double\"></xsd:restriction>\n"),
                .boolean => try w.add("  <xsd:restriction base=\"xsd:boolean\"></xsd:restriction>\n"),
                .time, .timetz => {
                    try w.add("  <xsd:restriction base=\"xsd:time\">\n    <xsd:pattern value=\"\\p{Nd}{2}:\\p{Nd}{2}:\\p{Nd}{2}(.\\p{Nd}+)?");
                    if (ty == .timetz) try w.add("(\\+|-)\\p{Nd}{2}:\\p{Nd}{2}");
                    try w.add("\"/>\n  </xsd:restriction>\n");
                },
                .timestamp, .timestamptz => {
                    try w.add("  <xsd:restriction base=\"xsd:dateTime\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}T\\p{Nd}{2}:\\p{Nd}{2}:\\p{Nd}{2}(.\\p{Nd}+)?");
                    if (ty == .timestamptz) try w.add("(\\+|-)\\p{Nd}{2}:\\p{Nd}{2}");
                    try w.add("\"/>\n  </xsd:restriction>\n");
                },
                .date => try w.add("  <xsd:restriction base=\"xsd:date\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}\"/>\n  </xsd:restriction>\n"),
                else => {},
            }
            try w.add("</xsd:simpleType>\n");
        }

        /// map_sql_typecoll_to_xmlschema_types: each distinct column type
        /// once, in order of first use.
        fn typeCollection(ctx: *const E.Context, w: *Writer, tys: []const types.Type) Error!void {
            for (tys, 0..) |ty, index| {
                var seen = false;
                for (tys[0..index]) |earlier| seen = seen or earlier == ty;
                if (seen) continue;
                try schemaType(ctx, w, ty);
                try w.add("\n");
            }
        }

        /// Column names and types of a query (no rows).
        const ShapeSink = struct {
            count: usize = 0,
            names: [config.columns]V.Name = undefined,
            tys: [config.columns]types.Type = undefined,

            fn columns(raw: *anyopaque, count: usize, names_raw: *const anyopaque, tys: [*]const types.Type, _: [*]const i32) Error!void {
                const self: *ShapeSink = @ptrCast(@alignCast(raw));
                if (count > config.columns) return error.ColumnCapacity;
                const names: [*]const V.Name = @ptrCast(@alignCast(names_raw));
                for (0..count) |index| {
                    self.names[index] = names[index];
                    self.tys[index] = tys[index];
                }
                self.count = count;
            }

            fn row(_: *anyopaque, _: *const anyopaque) Error!void {}
        };

        fn queryShape(ctx: *const E.Context, query: []const u8, shape: *ShapeSink) Error!void {
            const sequences = try hook(ctx);
            const sink: value.XmlQuerySink = .{ .context = shape, .columns = &ShapeSink.columns, .row = &ShapeSink.row };
            try sequences.xml_query.?(sequences.ptr, query, &sink);
        }

        /// map_sql_table_to_xmlschema (`rel` null for a query).
        fn tableSchema(ctx: *const E.Context, w: *Writer, shape: *const ShapeSink, rel: ?*const Relation, options: Options) Error!void {
            try xsdStart(w, options.targetns);
            try typeCollection(ctx, w, shape.tys[0..shape.count]);
            const row_start = w.s.region.used;
            if (rel) |r| try multipart(w, &.{ "RowType", ctx.session.database, r.schemaSlice(), r.nameSlice() }) else try w.add("RowType");
            const row_type = try copyOut(w, row_start);
            const table_start = w.s.region.used;
            if (rel) |r| try multipart(w, &.{ "TableType", ctx.session.database, r.schemaSlice(), r.nameSlice() }) else try w.add("TableType");
            const table_type = try copyOut(w, table_start);
            var element_buffer: [1024]u8 = undefined;
            var element: tree.Out = .{ .bytes = &element_buffer };
            if (rel) |r| try mapName(r.nameSlice(), true, false, &element) else try element.add(if (options.tableforest) "row" else "table");
            try w.add("<xsd:complexType name=\"");
            try w.add(row_type.slice());
            try w.add("\">\n  <xsd:sequence>\n");
            for (0..shape.count) |index| {
                try w.add("    <xsd:element name=\"");
                try w.name(shape.names[index].slice(), true, false);
                try w.add("\" type=\"");
                try typeName(ctx, w, shape.tys[index]);
                try w.add(if (options.nulls) "\" nillable=\"true\"></xsd:element>\n" else "\" minOccurs=\"0\"></xsd:element>\n");
            }
            try w.add("  </xsd:sequence>\n</xsd:complexType>\n\n");
            if (!options.tableforest) {
                try w.add("<xsd:complexType name=\"");
                try w.add(table_type.slice());
                try w.add("\">\n  <xsd:sequence>\n    <xsd:element name=\"row\" type=\"");
                try w.add(row_type.slice());
                try w.add("\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n");
                try w.add("<xsd:element name=\"");
                try w.add(element.slice());
                try w.add("\" type=\"");
                try w.add(table_type.slice());
                try w.add("\"/>\n\n");
            } else {
                try w.add("<xsd:element name=\"");
                try w.add(element.slice());
                try w.add("\" type=\"");
                try w.add(row_type.slice());
                try w.add("\"/>\n\n");
            }
            try w.add("</xsd:schema>");
        }

        /// Moves the bytes written since `start` into a small buffer (they
        /// are names inside the output being built) and drops them.
        const Small = struct {
            bytes: [1024]u8 = undefined,
            len: usize = 0,
            fn slice(self: *const Small) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        fn copyOut(w: *Writer, start: usize) Error!Small {
            var out: Small = .{};
            const written = w.s.region.bytes[start..w.s.region.used];
            if (written.len > out.bytes.len) return error.NameCapacity;
            @memcpy(out.bytes[0..written.len], written);
            out.len = written.len;
            w.s.region.used = start;
            return out;
        }

        /// map_sql_schema_to_xmlschema_types.
        fn schemaTypes(ctx: *const E.Context, w: *Writer, schema: []const u8, tables: []const Relation, options: Options) Error!void {
            try w.add("<xsd:complexType name=\"");
            try multipart(w, &.{ "SchemaType", ctx.session.database, schema });
            try w.add(if (!options.tableforest) "\">\n  <xsd:all>\n" else "\">\n  <xsd:sequence>\n");
            for (tables) |*rel| {
                try w.add("    <xsd:element name=\"");
                try w.name(rel.nameSlice(), true, false);
                try w.add("\" type=\"");
                try multipart(w, &.{ if (options.tableforest) "RowType" else "TableType", ctx.session.database, schema, rel.nameSlice() });
                try w.add(if (!options.tableforest) "\"/>\n" else "\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n");
            }
            try w.add(if (!options.tableforest) "  </xsd:all>\n" else "  </xsd:sequence>\n");
            try w.add("</xsd:complexType>\n\n<xsd:element name=\"");
            try w.name(schema, true, false);
            try w.add("\" type=\"");
            try multipart(w, &.{ "SchemaType", ctx.session.database, schema });
            try w.add("\"/>\n\n");
        }

        /// The column types of the given relations, in order (for the type
        /// collection of schema and database schemas).
        fn relationTypes(ctx: *const E.Context, oids: []const u32, rels: []Relation, tys: []types.Type) Error!usize {
            var count: usize = 0;
            for (oids, 0..) |oid, index| {
                rels[index] = try relation(ctx, oid);
                var buffer: [400]u8 = undefined;
                const query = std.fmt.bufPrint(&buffer, "SELECT * FROM {s}", .{rels[index].displaySlice()}) catch return error.TextCapacity;
                var shape: ShapeSink = .{};
                try queryShape(ctx, query, &shape);
                for (shape.tys[0..shape.count]) |ty| {
                    if (count == tys.len) return error.ProgramLimitExceeded;
                    tys[count] = ty;
                    count += 1;
                }
            }
            return count;
        }

        /// schema_to_xmlschema_internal.
        fn schemaSchema(ctx: *const E.Context, w: *Writer, schema: []const u8, options: Options) Error!void {
            const nsp = try schemaOid(ctx, schema);
            try xsdStart(w, options.targetns);
            var oids: [config.tables]u32 = undefined;
            const count = try schemaTables(ctx, nsp, &oids);
            var rels: [config.tables]Relation = undefined;
            var tys: [config.tables * config.columns]types.Type = undefined;
            const type_count = try relationTypes(ctx, oids[0..count], rels[0..count], &tys);
            try typeCollection(ctx, w, tys[0..type_count]);
            try schemaTypes(ctx, w, schema, rels[0..count], options);
            try w.add("</xsd:schema>");
        }

        /// database_to_xmlschema_internal.
        fn databaseSchema(ctx: *const E.Context, w: *Writer, options: Options) Error!void {
            try xsdStart(w, options.targetns);
            var oids: [config.tables]u32 = undefined;
            const count = try oidQuery(ctx, database_tables_query, &oids);
            var rels: [config.tables]Relation = undefined;
            var tys: [config.tables * config.columns]types.Type = undefined;
            const type_count = try relationTypes(ctx, oids[0..count], rels[0..count], &tys);
            try typeCollection(ctx, w, tys[0..type_count]);
            // map_sql_catalog_to_xmlschema_types.
            try w.add("<xsd:complexType name=\"");
            try multipart(w, &.{ "CatalogType", ctx.session.database });
            try w.add("\">\n  <xsd:all>\n");
            var schemas: [config.schemas + 4]u32 = undefined;
            const schema_count = try oidQuery(ctx, visible_schemas_query, &schemas);
            for (schemas[0..schema_count]) |nsp| {
                var name_buffer: [128]u8 = undefined;
                const schema = try schemaName(ctx, nsp, &name_buffer);
                try w.add("    <xsd:element name=\"");
                try w.name(schema, true, false);
                try w.add("\" type=\"");
                try multipart(w, &.{ "SchemaType", ctx.session.database, schema });
                try w.add("\"/>\n");
            }
            try w.add("  </xsd:all>\n</xsd:complexType>\n\n<xsd:element name=\"");
            try w.name(ctx.session.database, true, false);
            try w.add("\" type=\"");
            try multipart(w, &.{ "CatalogType", ctx.session.database });
            try w.add("\"/>\n\n</xsd:schema>");
        }

        /// The table mapping functions. Arguments are strict.
        fn mapping(ctx: *const E.Context, n: *const ast.Node, which: ast.XmlFn) Error!V.Cell {
            var args: [5]V.Cell = undefined;
            var count: usize = 0;
            var item = n.b;
            while (item != none and count < args.len) : (item = node(ctx, item).next) {
                args[count] = try E.eval(ctx, item);
                count += 1;
            }
            for (args[0..count]) |*cell| if (cell.* == .null_value) return .null_value;
            const s = try scratch(ctx);
            const mark = s.mark();
            defer s.release(mark);
            var w: Writer = .{ .s = s, .start = s.region.used };
            const database = which == .database_to_xml or which == .database_to_xmlschema or which == .database_to_xml_and_xmlschema;
            const first: usize = if (database) 0 else 1;
            const options: Options = .{ .nulls = args[first].boolean, .tableforest = args[first + 1].boolean, .targetns = textArgument(&args[first + 2]) };
            switch (which) {
                .table_to_xml => try tableToXml(ctx, &w, args[0].integer, null, options, true),
                .query_to_xml => try queryToXml(ctx, &w, textArgument(&args[0]), null, null, options, true),
                .table_to_xmlschema, .table_to_xml_and_xmlschema => {
                    const rel = try relation(ctx, args[0].integer);
                    var buffer: [400]u8 = undefined;
                    const query = std.fmt.bufPrint(&buffer, "SELECT * FROM {s}", .{rel.displaySlice()}) catch return error.TextCapacity;
                    var shape: ShapeSink = .{};
                    try queryShape(ctx, query, &shape);
                    try tableSchema(ctx, &w, &shape, &rel, options);
                    if (which == .table_to_xml_and_xmlschema) {
                        const schema_text = w.slice();
                        var data: Writer = .{ .s = s, .start = s.region.used };
                        try tableToXml(ctx, &data, args[0].integer, schema_text, options, true);
                        return wideCell(ctx, .xml, data.slice());
                    }
                },
                .query_to_xmlschema, .query_to_xml_and_xmlschema => {
                    var shape: ShapeSink = .{};
                    try queryShape(ctx, textArgument(&args[0]), &shape);
                    try tableSchema(ctx, &w, &shape, null, options);
                    if (which == .query_to_xml_and_xmlschema) {
                        const schema_text = w.slice();
                        var data: Writer = .{ .s = s, .start = s.region.used };
                        try queryToXml(ctx, &data, textArgument(&args[0]), null, schema_text, options, true);
                        return wideCell(ctx, .xml, data.slice());
                    }
                },
                .schema_to_xml => try schemaToXml(ctx, &w, try schemaOid(ctx, textArgument(&args[0])), null, options, true),
                .schema_to_xmlschema, .schema_to_xml_and_xmlschema => {
                    try schemaSchema(ctx, &w, textArgument(&args[0]), options);
                    if (which == .schema_to_xml_and_xmlschema) {
                        const schema_text = w.slice();
                        var data: Writer = .{ .s = s, .start = s.region.used };
                        try schemaToXml(ctx, &data, try schemaOid(ctx, textArgument(&args[0])), schema_text, options, true);
                        return wideCell(ctx, .xml, data.slice());
                    }
                },
                .database_to_xml => try databaseToXml(ctx, &w, null, options),
                .database_to_xmlschema, .database_to_xml_and_xmlschema => {
                    try databaseSchema(ctx, &w, options);
                    if (which == .database_to_xml_and_xmlschema) {
                        const schema_text = w.slice();
                        var data: Writer = .{ .s = s, .start = s.region.used };
                        try databaseToXml(ctx, &data, schema_text, options);
                        return wideCell(ctx, .xml, data.slice());
                    }
                },
                .cursor_to_xml, .cursor_to_xmlschema => return error.UnsupportedStatement,
                else => unreachable,
            }
            return wideCell(ctx, .xml, w.slice());
        }
    };
}
