//! Evaluation of the regular-expression functions (Layer 0, wave 4
//! text-json lane), after regexp.c and varlena.c of PostgreSQL 18:
//!   regexp_match, regexp_matches (set-returning), regexp_replace (flags,
//!   start and N-th occurrence), regexp_split_to_array and
//!   regexp_split_to_table (set-returning), regexp_count, regexp_instr,
//!   regexp_substr, substring(text FROM pattern) and substring(text
//!   SIMILAR pattern ESCAPE escape) / substring(text FROM pattern FOR
//!   escape).
//!
//! `RegexEval(config, E)` is instantiated by expr.sig's `Eval` (`E`); exec
//! drives the set-returning functions through `rows`. Positions are
//! characters; every match runs regex.sig's matcher (work checkpoints per
//! simulated position). Results are fresh cells (Config.text_bytes;
//! TextCapacity, 54000, beyond). Invalid start / N / endoption / subexpr
//! values and options are 22023 as in PostgreSQL.
const types = @import("types.sig");
const ast = @import("ast.sig");
const regex = @import("regex.sig");
const Error = types.Error;
const none = ast.none;

pub fn RegexEval(comptime config: types.Config, comptime E: type) type {
    const V = types.Values(config);
    const A = V.Arrays;
    const M = regex.Matcher(config.regex_states, config.text_bytes);
    return struct {
        /// One produced row of a set-returning function; false stops.
        pub const Sink = struct {
            context: *anyopaque,
            row: *const fn (*anyopaque, *const V.Cell) Error!bool,
        };

        fn node(ctx: *const E.Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        const Args = struct {
            cells: [7]V.Cell = undefined,
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

        fn textCell(bytes: []const u8) Error!V.Cell {
            if (bytes.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = bytes.len };
            @memcpy(text.bytes[0..bytes.len], bytes);
            return .{ .text = text };
        }

        fn textOf(cell: *const V.Cell) []const u8 {
            return if (cell.* == .bpchar) cell.bpchar.slice() else cell.text.slice();
        }

        /// The byte offset of 0-based character `index` (text.len + 1 when
        /// it lies beyond the end: no search starts there).
        fn byteOffset(subject: []const u8, index: i64) usize {
            var at: usize = 0;
            var remaining = index;
            while (remaining > 0) : (remaining -= 1) {
                if (at >= subject.len) return subject.len + 1;
                at += regex.decode(subject, at).len;
            }
            return at;
        }

        fn position(subject: []const u8, offset: i32) i64 {
            return @intCast(regex.charCount(subject, 0, @intCast(offset)) + 1);
        }

        /// parse_re_flags; `global_name` set refuses `g` (22023).
        fn options(cell: ?*const V.Cell, refuse_global: bool) Error!struct { flags: regex.Flags, global: bool } {
            const parsed = try regex.parseOptions(if (cell) |given| given.text.slice() else "", .{});
            if (refuse_global and parsed.global) return error.InvalidParameterValue;
            return .{ .flags = parsed.flags, .global = parsed.global };
        }

        /// setup_regexp_matches as an iterator: each qualifying match in
        /// m.caps (groups only when asked); split mode drops degenerate
        /// matches (empty at the start, or ending where the last one did).
        const Scan = struct {
            m: *M,
            subject: []const u8,
            control: ?*types.ExecutionControl,
            groups: bool,
            global: bool,
            split: bool = false,
            start: usize,
            previous_end: usize = 0,
            done: bool = false,

            fn next(self: *Scan) Error!bool {
                while (!self.done) {
                    if (self.start > self.subject.len or !try self.m.match(self.subject, self.start, self.groups, self.control)) {
                        self.done = true;
                        return false;
                    }
                    const so: usize = @intCast(self.m.caps[0].start);
                    const eo: usize = @intCast(self.m.caps[0].end);
                    const keep = !self.split or (so < self.subject.len and eo > self.previous_end);
                    self.previous_end = eo;
                    if (!self.global) {
                        self.done = true;
                    } else {
                        self.start = eo;
                        if (so == eo) self.start = if (eo < self.subject.len) eo + regex.decode(self.subject, eo).len else self.subject.len + 1;
                    }
                    if (keep) return true;
                }
                return false;
            }
        };

        fn compile(m: *M, pattern: []const u8, flags: regex.Flags) Error!void {
            try m.compile(pattern, flags, config.expr_depth);
        }

        /// build_regexp_match_result: the groups (or the whole match when
        /// there are none) as text[]; unmatched groups are NULL.
        fn matchArray(m: *const M, subject: []const u8) Error!V.Cell {
            const groups = m.groups();
            const count: usize = if (groups == 0) 1 else groups;
            var result: V.Text = .{};
            var writer = try A.Writer.begin(&result, &.{ .element = .text, .ndim = 1, .dims = .{ @intCast(count), 0, 0, 0, 0, 0 } });
            for (0..count) |index| {
                const capture = m.caps[if (groups == 0) 0 else index + 1];
                const cell: V.Cell = if (capture.start < 0) .null_value else try textCell(subject[@intCast(capture.start)..@intCast(capture.end)]);
                try writer.append(&cell);
            }
            return .{ .array = result };
        }

        fn int(cell: *const V.Cell) i64 {
            return cell.integer;
        }

        pub fn call(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            if (n.planned_null) return .null_value;
            var args: Args = .{};
            try arguments(ctx, n, &args);
            if (args.any_null) return .null_value;
            const control = ctx.session.control;
            const subject = textOf(&args.cells[0]);
            const pattern = args.cells[1].text.slice();
            var m: M = .{};
            switch (n.func) {
                .regexp_match => {
                    const parsed = try options(if (args.count == 3) &args.cells[2] else null, true);
                    try compile(&m, pattern, parsed.flags);
                    if (!try m.match(subject, 0, true, control)) return .null_value;
                    return matchArray(&m, subject);
                },
                .substring_regex, .substring_similar => {
                    var converted: [3 * config.text_bytes + 23]u8 = undefined;
                    const expression = if (n.func == .substring_similar) try regex.similarToRegex(pattern, args.cells[2].text.slice(), &converted) else pattern;
                    try compile(&m, expression, .{});
                    if (!try m.match(subject, 0, m.groups() > 0, control)) return .null_value;
                    const capture = m.caps[if (m.groups() > 0) 1 else 0];
                    if (capture.start < 0) return .null_value;
                    return textCell(subject[@intCast(capture.start)..@intCast(capture.end)]);
                },
                .regexp_replace => return replace(ctx, &m, &args),
                .regexp_split_to_array => {
                    const parsed = try options(if (args.count == 3) &args.cells[2] else null, true);
                    try compile(&m, pattern, parsed.flags);
                    // Count the pieces, then write them.
                    var scan: Scan = .{ .m = &m, .subject = subject, .control = control, .groups = false, .global = true, .split = true, .start = 0 };
                    var pieces: usize = 1;
                    while (try scan.next()) pieces += 1;
                    var result: V.Text = .{};
                    var writer = try A.Writer.begin(&result, &.{ .element = .text, .ndim = 1, .dims = .{ @intCast(pieces), 0, 0, 0, 0, 0 } });
                    scan = .{ .m = &m, .subject = subject, .control = control, .groups = false, .global = true, .split = true, .start = 0 };
                    var from: usize = 0;
                    while (try scan.next()) {
                        const cell = try textCell(subject[from..@intCast(m.caps[0].start)]);
                        try writer.append(&cell);
                        from = @intCast(m.caps[0].end);
                    }
                    const last = try textCell(subject[from..]);
                    try writer.append(&last);
                    return .{ .array = result };
                },
                .regexp_count, .regexp_instr, .regexp_substr => return positional(ctx, &m, n.func, &args),
                else => return error.UnsupportedStatement,
            }
        }

        /// regexp_count, regexp_instr and regexp_substr.
        fn positional(ctx: *const E.Context, m: *M, func: ast.Func, args: *const Args) Error!V.Cell {
            const subject = textOf(&args.cells[0]);
            const pattern = args.cells[1].text.slice();
            var start: i64 = 1;
            var occurrence: i64 = 1;
            var end_option: i64 = 0;
            var subexpr: i64 = 0;
            var flags_cell: ?*const V.Cell = null;
            if (args.count > 2) {
                start = int(&args.cells[2]);
                if (start <= 0) return error.InvalidParameterValue;
            }
            switch (func) {
                .regexp_count => {
                    if (args.count > 3) flags_cell = &args.cells[3];
                },
                .regexp_instr => {
                    if (args.count > 3) {
                        occurrence = int(&args.cells[3]);
                        if (occurrence <= 0) return error.InvalidParameterValue;
                    }
                    if (args.count > 4) {
                        end_option = int(&args.cells[4]);
                        if (end_option != 0 and end_option != 1) return error.InvalidParameterValue;
                    }
                    if (args.count > 5) flags_cell = &args.cells[5];
                    if (args.count > 6) {
                        subexpr = int(&args.cells[6]);
                        if (subexpr < 0) return error.InvalidParameterValue;
                    }
                },
                else => {
                    if (args.count > 3) {
                        occurrence = int(&args.cells[3]);
                        if (occurrence <= 0) return error.InvalidParameterValue;
                    }
                    if (args.count > 4) flags_cell = &args.cells[4];
                    if (args.count > 5) {
                        subexpr = int(&args.cells[5]);
                        if (subexpr < 0) return error.InvalidParameterValue;
                    }
                },
            }
            const parsed = try options(flags_cell, true);
            try compile(m, pattern, parsed.flags);
            const groups = m.groups();
            // Groups only when a subexpression is asked for and exists.
            const use_groups = subexpr > 0 and groups > 0;
            const patterns: i64 = if (use_groups) @intCast(groups) else 1;
            var scan: Scan = .{ .m = m, .subject = subject, .control = ctx.session.control, .groups = use_groups, .global = true, .start = byteOffset(subject, start - 1) };
            var count: i64 = 0;
            while (try scan.next()) {
                count += 1;
                if (func != .regexp_count and count == occurrence) break;
            }
            if (func == .regexp_count) return .{ .integer = count };
            const found = count == occurrence;
            if (!found or subexpr > patterns) return if (func == .regexp_instr) V.Cell{ .integer = 0 } else .null_value;
            const capture = m.caps[if (use_groups) @intCast(subexpr) else 0];
            if (capture.start < 0) return if (func == .regexp_instr) V.Cell{ .integer = 0 } else .null_value;
            if (func == .regexp_instr) return .{ .integer = position(subject, if (end_option == 1) capture.end else capture.start) };
            return textCell(subject[@intCast(capture.start)..@intCast(capture.end)]);
        }

        /// check_replace_text_has_escape: 2 with \1-\9, 1 with another
        /// escape, 0 without.
        fn escapeStatus(replacement: []const u8) u2 {
            var status: u2 = 0;
            var at: usize = 0;
            while (at < replacement.len) : (at += 1) {
                if (replacement[at] != '\\') continue;
                at += 1;
                if (at < replacement.len) {
                    if (replacement[at] >= '1' and replacement[at] <= '9') return 2;
                    status = 1;
                }
            }
            return status;
        }

        const Out = struct {
            bytes: [config.text_bytes]u8 = undefined,
            len: usize = 0,

            fn put(self: *Out, data: []const u8) Error!void {
                if (data.len > self.bytes.len - self.len) return error.TextCapacity;
                @memcpy(self.bytes[self.len..][0..data.len], data);
                self.len += data.len;
            }
        };

        /// appendStringInfoRegexpSubstr: \1-\9, \& and \\ in `replacement`.
        fn substitute(out: *Out, replacement: []const u8, m: *const M, subject: []const u8) Error!void {
            var at: usize = 0;
            while (at < replacement.len) {
                const chunk = at;
                while (at < replacement.len and replacement[at] != '\\') at += 1;
                try out.put(replacement[chunk..at]);
                if (at >= replacement.len) break;
                at += 1;
                if (at >= replacement.len) {
                    try out.put("\\");
                    break;
                }
                const byte = replacement[at];
                var capture: regex.Capture = .{};
                if (byte >= '1' and byte <= '9') {
                    const index: usize = byte - '0';
                    if (index <= m.groups()) capture = m.caps[index];
                    at += 1;
                } else if (byte == '&') {
                    capture = m.caps[0];
                    at += 1;
                } else if (byte == '\\') {
                    try out.put("\\");
                    at += 1;
                    continue;
                } else {
                    try out.put("\\");
                    continue;
                }
                if (capture.start >= 0) try out.put(subject[@intCast(capture.start)..@intCast(capture.end)]);
            }
        }

        /// regexp_replace(source, pattern, replacement [, start [, N]] [, flags])
        /// (replace_text_regexp). `n.integer` 1 selects the (start [, N
        /// [, flags]]) signatures over the (flags) one.
        fn replace(ctx: *const E.Context, m: *M, args: *const Args) Error!V.Cell {
            const subject = textOf(&args.cells[0]);
            const pattern = args.cells[1].text.slice();
            const replacement = args.cells[2].text.slice();
            var start: i64 = 1;
            var occurrence: i64 = 1;
            var flags_cell: ?*const V.Cell = null;
            const extended = args.count > 3 and args.cells[3] != .text;
            if (args.count > 3 and !extended) {
                // textregexreplace: an option that starts with a digit is
                // refused (it meant the start position).
                flags_cell = &args.cells[3];
            } else if (extended) {
                start = int(&args.cells[3]);
                if (start <= 0) return error.InvalidParameterValue;
                if (args.count > 4) {
                    occurrence = int(&args.cells[4]);
                    if (occurrence < 0) return error.InvalidParameterValue;
                }
                if (args.count > 5) flags_cell = &args.cells[5];
            }
            const parsed = try options(flags_cell, false);
            // Without N, the `g` option means every occurrence.
            if (args.count <= 4) occurrence = if (parsed.global) 0 else 1;
            try compile(m, pattern, parsed.flags);
            const status = escapeStatus(replacement);
            var out: Out = .{};
            var search = byteOffset(subject, start - 1);
            var copied: usize = 0;
            var matches: i64 = 0;
            while (search <= subject.len) {
                if (!try m.match(subject, search, status == 2, ctx.session.control)) break;
                matches += 1;
                const so: usize = @intCast(m.caps[0].start);
                const eo: usize = @intCast(m.caps[0].end);
                if (occurrence > 0 and matches != occurrence) {
                    search = eo;
                    if (so == eo) search = if (eo < subject.len) eo + regex.decode(subject, eo).len else subject.len + 1;
                    continue;
                }
                try out.put(subject[copied..so]);
                if (status > 0) try substitute(&out, replacement, m, subject) else try out.put(replacement);
                copied = eo;
                if (occurrence > 0) break;
                search = copied;
                if (so == eo) search = if (eo < subject.len) eo + regex.decode(subject, eo).len else subject.len + 1;
            }
            try out.put(subject[copied..]);
            return textCell(out.bytes[0..out.len]);
        }

        /// The rows of regexp_matches (text[] each) and regexp_split_to_table
        /// (text each) for one call; NULL arguments give no rows.
        pub fn rows(ctx: *const E.Context, n: *const ast.Node, sink: Sink) Error!void {
            var args: Args = .{};
            try arguments(ctx, n, &args);
            if (args.any_null) return;
            const control = ctx.session.control;
            const subject = textOf(&args.cells[0]);
            var m: M = .{};
            const split = n.func == .regexp_split_to_table;
            const parsed = try options(if (args.count == 3) &args.cells[2] else null, split);
            try compile(&m, args.cells[1].text.slice(), parsed.flags);
            var scan: Scan = .{ .m = &m, .subject = subject, .control = control, .groups = !split, .global = split or parsed.global, .split = split, .start = 0 };
            var from: usize = 0;
            while (try scan.next()) {
                if (control) |active| try active.checkpoint();
                const cell = if (split) try textCell(subject[from..@intCast(m.caps[0].start)]) else try matchArray(&m, subject);
                from = @intCast(m.caps[0].end);
                if (!try sink.row(sink.context, &cell)) return;
            }
            if (split) {
                const last = try textCell(subject[from..]);
                _ = try sink.row(sink.context, &last);
            }
        }
    };
}
