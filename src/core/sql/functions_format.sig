//! to_date / to_timestamp(text, text) and to_number input templates
//! (Layer 0, B11), following PostgreSQL 18 formatting.c (DCH_from_char,
//! do_to_timestamp, NUM_processor/NUM_numpart_from_char) in the C locale:
//! English month/day names, "." decimal point, "," group separator, "+"/"-"
//! signs.
//!
//! Supported date/time fields: YYYY YYY YY Y Y,YYY CC MM MON Mon mon MONTH
//! Month month DD DDD D DAY Day day DY Dy dy J Q W WW HH HH12 HH24 MI SS
//! SSSS SSSSS MS US AM PM A.M. P.M. AD BC A.D. B.C. (and their lower-case
//! spellings) with the FM/TM prefixes, TH/th/SP suffixes and FX. ISO week
//! fields, time zone fields, RM and FF1-FF6 fail with 0A000. Number
//! templates support 9 0 . D , G S MI PL SG FM L B and literal text;
//! V, EEEE, RN and PR fail with 0A000. Errors: 22007 for malformed input,
//! 22008 for out-of-range fields, 22P02 when no digits remain, 22003 when
//! the value exceeds the template's precision, 42601 for two decimal points.
//! All loops are bounded by the template and input and call the checkpoint.
const types = @import("types.sig");
const temporal = @import("temporal.sig");
const Error = types.Error;

pub const Control = ?*types.ExecutionControl;

fn tick(control: Control) Error!void {
    if (control) |active| try active.checkpoint();
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

/// is_separator_char: printable ASCII that is not a letter or digit.
fn separatorChar(byte: u8) bool {
    return byte > 0x20 and byte < 0x7f and !(byte >= 'A' and byte <= 'Z') and !(byte >= 'a' and byte <= 'z') and !digit(byte);
}

fn utf8Width(text: []const u8, at: usize) usize {
    const byte = text[at];
    const width: usize = if (byte & 0x80 == 0) 1 else if (byte & 0xe0 == 0xc0) 2 else if (byte & 0xf0 == 0xe0) 3 else if (byte & 0xf8 == 0xf0) 4 else 1;
    return @min(width, text.len - at);
}

// ---- date/time templates ----------------------------------------------

const Key = enum { y_yyy, yyyy, yyy, yy, y, cc, mm, mon, month, dd, ddd, d, day, dy, j, q, w, ww, hh, hh12, hh24, mi, ss, ssss, ms, us, am, ampm_long, ad, adbc_long, fx, unsupported };

const Keyword = struct { name: []const u8, key: Key, digits: bool, len: u8 };

/// DCH_keywords in match order (longer spellings first).
const keywords = [_]Keyword{
    .{ .name = "A.D.", .key = .adbc_long, .digits = false, .len = 4 }, .{ .name = "A.M.", .key = .ampm_long, .digits = false, .len = 4 },
    .{ .name = "AD", .key = .ad, .digits = false, .len = 2 },          .{ .name = "AM", .key = .am, .digits = false, .len = 2 },
    .{ .name = "B.C.", .key = .adbc_long, .digits = false, .len = 4 }, .{ .name = "BC", .key = .ad, .digits = false, .len = 2 },
    .{ .name = "CC", .key = .cc, .digits = true, .len = 2 },           .{ .name = "DAY", .key = .day, .digits = false, .len = 3 },
    .{ .name = "DDD", .key = .ddd, .digits = true, .len = 3 },         .{ .name = "DD", .key = .dd, .digits = true, .len = 2 },
    .{ .name = "DY", .key = .dy, .digits = false, .len = 2 },          .{ .name = "Day", .key = .day, .digits = false, .len = 3 },
    .{ .name = "Dy", .key = .dy, .digits = false, .len = 2 },          .{ .name = "D", .key = .d, .digits = true, .len = 1 },
    .{ .name = "FF1", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "FF2", .key = .unsupported, .digits = true, .len = 3 },
    .{ .name = "FF3", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "FF4", .key = .unsupported, .digits = true, .len = 3 },
    .{ .name = "FF5", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "FF6", .key = .unsupported, .digits = true, .len = 3 },
    .{ .name = "FX", .key = .fx, .digits = false, .len = 2 },          .{ .name = "HH24", .key = .hh24, .digits = true, .len = 2 },
    .{ .name = "HH12", .key = .hh12, .digits = true, .len = 2 },       .{ .name = "HH", .key = .hh, .digits = true, .len = 2 },
    .{ .name = "IDDD", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "ID", .key = .unsupported, .digits = true, .len = 1 },
    .{ .name = "IW", .key = .unsupported, .digits = true, .len = 2 },  .{ .name = "IYYY", .key = .unsupported, .digits = true, .len = 4 },
    .{ .name = "IYY", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "IY", .key = .unsupported, .digits = true, .len = 2 },
    .{ .name = "I", .key = .unsupported, .digits = true, .len = 1 },   .{ .name = "J", .key = .j, .digits = true, .len = 1 },
    .{ .name = "MI", .key = .mi, .digits = true, .len = 2 },           .{ .name = "MM", .key = .mm, .digits = true, .len = 2 },
    .{ .name = "MONTH", .key = .month, .digits = false, .len = 5 },    .{ .name = "MON", .key = .mon, .digits = false, .len = 3 },
    .{ .name = "MS", .key = .ms, .digits = true, .len = 3 },           .{ .name = "Month", .key = .month, .digits = false, .len = 5 },
    .{ .name = "Mon", .key = .mon, .digits = false, .len = 3 },        .{ .name = "OF", .key = .unsupported, .digits = false, .len = 2 },
    .{ .name = "P.M.", .key = .ampm_long, .digits = false, .len = 4 }, .{ .name = "PM", .key = .am, .digits = false, .len = 2 },
    .{ .name = "Q", .key = .q, .digits = true, .len = 1 },             .{ .name = "RM", .key = .unsupported, .digits = false, .len = 2 },
    .{ .name = "SSSSS", .key = .ssss, .digits = true, .len = 5 },      .{ .name = "SSSS", .key = .ssss, .digits = true, .len = 4 },
    .{ .name = "SS", .key = .ss, .digits = true, .len = 2 },           .{ .name = "TZH", .key = .unsupported, .digits = false, .len = 2 },
    .{ .name = "TZM", .key = .unsupported, .digits = true, .len = 2 }, .{ .name = "TZ", .key = .unsupported, .digits = false, .len = 2 },
    .{ .name = "US", .key = .us, .digits = true, .len = 6 },           .{ .name = "WW", .key = .ww, .digits = true, .len = 2 },
    .{ .name = "W", .key = .w, .digits = true, .len = 1 },             .{ .name = "Y,YYY", .key = .y_yyy, .digits = true, .len = 5 },
    .{ .name = "YYYY", .key = .yyyy, .digits = true, .len = 4 },       .{ .name = "YYY", .key = .yyy, .digits = true, .len = 3 },
    .{ .name = "YY", .key = .yy, .digits = true, .len = 2 },           .{ .name = "Y", .key = .y, .digits = true, .len = 1 },
    .{ .name = "a.d.", .key = .adbc_long, .digits = false, .len = 4 }, .{ .name = "a.m.", .key = .ampm_long, .digits = false, .len = 4 },
    .{ .name = "ad", .key = .ad, .digits = false, .len = 2 },          .{ .name = "am", .key = .am, .digits = false, .len = 2 },
    .{ .name = "b.c.", .key = .adbc_long, .digits = false, .len = 4 }, .{ .name = "bc", .key = .ad, .digits = false, .len = 2 },
    .{ .name = "cc", .key = .cc, .digits = true, .len = 2 },           .{ .name = "day", .key = .day, .digits = false, .len = 3 },
    .{ .name = "ddd", .key = .ddd, .digits = true, .len = 3 },         .{ .name = "dd", .key = .dd, .digits = true, .len = 2 },
    .{ .name = "dy", .key = .dy, .digits = false, .len = 2 },          .{ .name = "d", .key = .d, .digits = true, .len = 1 },
    .{ .name = "ff1", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "ff2", .key = .unsupported, .digits = true, .len = 3 },
    .{ .name = "ff3", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "ff4", .key = .unsupported, .digits = true, .len = 3 },
    .{ .name = "ff5", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "ff6", .key = .unsupported, .digits = true, .len = 3 },
    .{ .name = "fx", .key = .fx, .digits = false, .len = 2 },          .{ .name = "hh24", .key = .hh24, .digits = true, .len = 2 },
    .{ .name = "hh12", .key = .hh12, .digits = true, .len = 2 },       .{ .name = "hh", .key = .hh, .digits = true, .len = 2 },
    .{ .name = "iddd", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "id", .key = .unsupported, .digits = true, .len = 1 },
    .{ .name = "iw", .key = .unsupported, .digits = true, .len = 2 },  .{ .name = "iyyy", .key = .unsupported, .digits = true, .len = 4 },
    .{ .name = "iyy", .key = .unsupported, .digits = true, .len = 3 }, .{ .name = "iy", .key = .unsupported, .digits = true, .len = 2 },
    .{ .name = "i", .key = .unsupported, .digits = true, .len = 1 },   .{ .name = "j", .key = .j, .digits = true, .len = 1 },
    .{ .name = "mi", .key = .mi, .digits = true, .len = 2 },           .{ .name = "mm", .key = .mm, .digits = true, .len = 2 },
    .{ .name = "month", .key = .month, .digits = false, .len = 5 },    .{ .name = "mon", .key = .mon, .digits = false, .len = 3 },
    .{ .name = "ms", .key = .ms, .digits = true, .len = 3 },           .{ .name = "of", .key = .unsupported, .digits = false, .len = 2 },
    .{ .name = "p.m.", .key = .ampm_long, .digits = false, .len = 4 }, .{ .name = "pm", .key = .am, .digits = false, .len = 2 },
    .{ .name = "q", .key = .q, .digits = true, .len = 1 },             .{ .name = "rm", .key = .unsupported, .digits = false, .len = 2 },
    .{ .name = "sssss", .key = .ssss, .digits = true, .len = 5 },      .{ .name = "ssss", .key = .ssss, .digits = true, .len = 4 },
    .{ .name = "ss", .key = .ss, .digits = true, .len = 2 },           .{ .name = "tzh", .key = .unsupported, .digits = false, .len = 2 },
    .{ .name = "tzm", .key = .unsupported, .digits = true, .len = 2 }, .{ .name = "tz", .key = .unsupported, .digits = false, .len = 2 },
    .{ .name = "us", .key = .us, .digits = true, .len = 6 },           .{ .name = "ww", .key = .ww, .digits = true, .len = 2 },
    .{ .name = "w", .key = .w, .digits = true, .len = 1 },             .{ .name = "y,yyy", .key = .y_yyy, .digits = true, .len = 5 },
    .{ .name = "yyyy", .key = .yyyy, .digits = true, .len = 4 },       .{ .name = "yyy", .key = .yyy, .digits = true, .len = 3 },
    .{ .name = "yy", .key = .yy, .digits = true, .len = 2 },           .{ .name = "y", .key = .y, .digits = true, .len = 1 },
};

const NodeKind = enum { action, space, separator, char, end };

const Node = struct {
    kind: NodeKind = .end,
    keyword: Keyword = undefined,
    fill: bool = false,
    th: bool = false,
    /// Template bytes consumed.
    width: usize = 0,
};

fn prefixed(text: []const u8, word: []const u8) bool {
    if (text.len < word.len) return false;
    for (text[0..word.len], word) |a, b| if (a != b) return false;
    return true;
}

/// parse_format for one node starting at `at`.
fn nodeAt(template: []const u8, at: usize) Node {
    if (at >= template.len) return .{};
    var at_now = at;
    var fill = false;
    if (prefixed(template[at_now..], "FM") or prefixed(template[at_now..], "fm")) {
        fill = true;
        at_now += 2;
    } else if (prefixed(template[at_now..], "TM") or prefixed(template[at_now..], "tm")) {
        at_now += 2;
    }
    if (at_now < template.len) for (keywords) |keyword| {
        if (!prefixed(template[at_now..], keyword.name)) continue;
        var node: Node = .{ .kind = .action, .keyword = keyword, .fill = fill };
        var end = at_now + keyword.name.len;
        if (prefixed(template[end..], "TH") or prefixed(template[end..], "th")) {
            node.th = true;
            end += 2;
        } else if (prefixed(template[end..], "SP") or prefixed(template[end..], "sp")) end += 2;
        node.width = end - at;
        return node;
    };
    if (at_now >= template.len) return .{ .kind = .char, .width = at_now - at };
    var start = at_now;
    if (template[start] == '\\' and start + 1 < template.len and template[start + 1] == '"') start += 1;
    const width = utf8Width(template, start);
    const byte = template[start];
    const kind: NodeKind = if (separatorChar(byte)) .separator else if (space(byte)) .space else .char;
    return .{ .kind = kind, .width = start + width - at };
}

/// TmFromChar.
const Fields = struct {
    year: i64 = 0,
    yysz: u8 = 0,
    bc: i64 = 0,
    cc: i64 = 0,
    mm: i64 = 0,
    dd: i64 = 0,
    ddd: i64 = 0,
    d: i64 = 0,
    j: i64 = 0,
    w: i64 = 0,
    ww: i64 = 0,
    hh: i64 = 0,
    mi: i64 = 0,
    ss: i64 = 0,
    ssss: i64 = 0,
    ms: i64 = 0,
    us: i64 = 0,
    pm: i64 = 0,
    twelve: bool = false,
};

/// from_char_set_int: a field set twice to different values is 22007.
fn setField(field: *i64, value: i64) Error!void {
    if (field.* != 0 and field.* != value) return error.InvalidDatetimeFormat;
    field.* = value;
}

/// strtol from `at`: leading space, optional sign, decimal digits.
fn strtol(input: []const u8, at: usize, limit: usize) struct { value: i64, end: usize, overflow: bool } {
    var p = at;
    while (p < limit and space(input[p])) p += 1;
    var negative = false;
    if (p < limit and (input[p] == '+' or input[p] == '-')) {
        negative = input[p] == '-';
        p += 1;
    }
    const digits_start = p;
    var value: i64 = 0;
    var overflow = false;
    while (p < limit and digit(input[p])) : (p += 1) {
        if (value > (9223372036854775807 - 9) / 10) overflow = true else value = value * 10 + (input[p] - '0');
    }
    if (p == digits_start) return .{ .value = 0, .end = at, .overflow = false };
    return .{ .value = if (negative) -value else value, .end = p, .overflow = overflow };
}

/// is_next_separator.
fn nextIsSeparator(template: []const u8, node: Node, after: usize) bool {
    if (node.th) return true;
    const next = nodeAt(template, after);
    return switch (next.kind) {
        .end => true,
        .action => !next.keyword.digits,
        .char, .space, .separator => !(next.width == 1 and digit(template[after])),
    };
}

/// from_char_parse_int_len: returns the parsed value and advances `at`.
fn parseInt(input: []const u8, at: *usize, len: usize, slurp: bool) Error!i64 {
    const init = at.*;
    var p = at.*;
    while (p < input.len and space(input[p])) p += 1;
    if (slurp) {
        const parsed = strtol(input, init, input.len);
        if (parsed.end == init) return error.InvalidDatetimeFormat;
        if (parsed.overflow or parsed.value < -2147483648 or parsed.value > 2147483647) return error.DatetimeFieldOverflow;
        at.* = parsed.end;
        return parsed.value;
    }
    const available = input.len - p;
    if (available < len) return error.InvalidDatetimeFormat;
    const parsed = strtol(input, p, p + len);
    const used = parsed.end - p;
    if (parsed.end == p) return error.InvalidDatetimeFormat;
    if (used < len) return error.InvalidDatetimeFormat;
    if (parsed.overflow or parsed.value < -2147483648 or parsed.value > 2147483647) return error.DatetimeFieldOverflow;
    at.* = parsed.end;
    return parsed.value;
}

/// from_char_seq_search: case-insensitive prefix match of a word list.
fn seqSearch(input: []const u8, at: *usize, words: []const []const u8) Error!i64 {
    for (words, 0..) |word, index| {
        if (input.len - at.* < word.len) continue;
        var same = true;
        for (input[at.*..][0..word.len], word) |a, b| if (lower(a) != lower(b)) {
            same = false;
            break;
        };
        if (same) {
            at.* += word.len;
            return @intCast(index);
        }
    }
    return error.InvalidDatetimeFormat;
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const month_abbrevs = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const day_abbrevs = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

fn skipTh(input: []const u8, at: *usize, node: Node) void {
    if (!node.th) return;
    for (0..2) |_| if (at.* < input.len) {
        at.* += utf8Width(input, at.*);
    };
}

/// DCH_from_char (non-standard mode).
fn fromChar(input: []const u8, template: []const u8, out: *Fields, control: Control) Error!void {
    var t: usize = 0;
    var s: usize = 0;
    var fx = false;
    var extra_skip: i64 = 0;
    var first = true;
    while (true) {
        try tick(control);
        const node = nodeAt(template, t);
        if (node.kind == .end or s >= input.len) break;
        const after = t + node.width;
        if (!fx and (node.kind != .action or node.keyword.key != .fx) and (node.kind == .action or first)) {
            while (s < input.len and space(input[s])) {
                s += 1;
                extra_skip += 1;
            }
        }
        first = false;
        t = after;
        if (node.kind == .space or node.kind == .separator) {
            if (!fx) {
                extra_skip -= 1;
                if (s < input.len and (space(input[s]) or separatorChar(input[s]))) {
                    s += 1;
                    extra_skip += 1;
                }
            } else if (s < input.len) s += utf8Width(input, s);
            continue;
        }
        if (node.kind == .char) {
            if (node.width == 0) continue;
            if (!fx) {
                if (extra_skip > 0) extra_skip -= 1 else s += utf8Width(input, s);
            } else s += utf8Width(input, s);
            continue;
        }
        const slurp = node.fill or nextIsSeparator(template, node, after);
        const len = node.keyword.len;
        switch (node.keyword.key) {
            .unsupported => return error.UnsupportedStatement,
            .fx => fx = true,
            .am => {
                const value = try seqSearch(input, &s, &.{ "am", "pm", "AM", "PM" });
                try setField(&out.pm, @mod(value, 2));
                out.twelve = true;
            },
            .ampm_long => {
                const value = try seqSearch(input, &s, &.{ "a.m.", "p.m.", "A.M.", "P.M." });
                try setField(&out.pm, @mod(value, 2));
                out.twelve = true;
            },
            .ad => try setField(&out.bc, @mod(try seqSearch(input, &s, &.{ "ad", "bc", "AD", "BC" }), 2)),
            .adbc_long => try setField(&out.bc, @mod(try seqSearch(input, &s, &.{ "a.d.", "b.c.", "A.D.", "B.C." }), 2)),
            .month => try setField(&out.mm, try seqSearch(input, &s, &month_names) + 1),
            .mon => try setField(&out.mm, try seqSearch(input, &s, &month_abbrevs) + 1),
            .day => try setField(&out.d, try seqSearch(input, &s, &day_names) + 1),
            .dy => try setField(&out.d, try seqSearch(input, &s, &day_abbrevs) + 1),
            .y_yyy => {
                // sscanf("%d,%03d"): thousands, a comma and three digits.
                const thousands = strtol(input, s, input.len);
                if (thousands.end == s or thousands.end >= input.len or input[thousands.end] != ',') return error.InvalidDatetimeFormat;
                const rest = strtol(input, thousands.end + 1, @min(input.len, thousands.end + 4));
                if (rest.end == thousands.end + 1) return error.InvalidDatetimeFormat;
                try setField(&out.year, thousands.value * 1000 + rest.value);
                out.yysz = 4;
                s = rest.end;
                skipTh(input, &s, node);
            },
            else => {
                const start = s;
                const value = try parseInt(input, &s, len, slurp);
                const used = s - start;
                switch (node.keyword.key) {
                    .yyyy => {
                        try setField(&out.year, value);
                        out.yysz = 4;
                    },
                    .yyy, .yy, .y => {
                        try setField(&out.year, if (used < 4) adjustYear(value) else value);
                        out.yysz = switch (node.keyword.key) {
                            .yyy => 3,
                            .yy => 2,
                            else => 1,
                        };
                    },
                    .cc => try setField(&out.cc, value),
                    .mm => try setField(&out.mm, value),
                    .dd => try setField(&out.dd, value),
                    .ddd => try setField(&out.ddd, value),
                    .d => try setField(&out.d, value),
                    .j => try setField(&out.j, value),
                    .q => {},
                    .w => try setField(&out.w, value),
                    .ww => try setField(&out.ww, value),
                    .hh, .hh12 => {
                        try setField(&out.hh, value);
                        out.twelve = true;
                    },
                    .hh24 => try setField(&out.hh, value),
                    .mi => try setField(&out.mi, value),
                    .ss => try setField(&out.ss, value),
                    .ssss => try setField(&out.ssss, value),
                    .ms => try setField(&out.ms, value * @as(i64, if (used == 1) 100 else if (used == 2) 10 else 1)),
                    .us => try setField(&out.us, value * @as(i64, switch (used) {
                        1 => 100000,
                        2 => 10000,
                        3 => 1000,
                        4 => 100,
                        5 => 10,
                        else => 1,
                    })),
                    else => unreachable,
                }
                skipTh(input, &s, node);
            },
        }
        if (!fx) {
            extra_skip = 0;
            while (s < input.len and space(input[s])) {
                s += 1;
                extra_skip += 1;
            }
        }
    }
}

/// adjust_partial_year_to_2020.
fn adjustYear(year: i64) i64 {
    if (year < 70) return year + 2000;
    if (year < 100) return year + 1900;
    if (year < 520) return year + 2000;
    if (year < 1000) return year + 1000;
    return year;
}

fn leap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn monthLength(year: i64, month: i64) i64 {
    const lengths = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return lengths[@intCast(month - 1)] + @as(i64, if (month == 2 and leap(year)) 1 else 0);
}

/// Broken-down result of do_to_timestamp (astronomical year).
pub const Parsed = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, usec: i64 };

/// do_to_timestamp: parse `input` with `template` into local fields.
pub fn parseTimestamp(input: []const u8, template: []const u8, control: Control) Error!Parsed {
    var f: Fields = .{};
    if (template.len != 0) try fromChar(input, template, &f, control);
    var tm: Parsed = .{ .year = 0, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .usec = 0 };
    var has_year = false;
    var has_month = false;
    var has_day = false;
    if (f.ssss != 0) {
        tm.hour = @divTrunc(f.ssss, 3600);
        tm.minute = @divTrunc(@rem(f.ssss, 3600), 60);
        tm.second = @rem(f.ssss, 60);
    }
    if (f.ss != 0) tm.second = f.ss;
    if (f.mi != 0) tm.minute = f.mi;
    if (f.hh != 0) tm.hour = f.hh;
    if (f.twelve) {
        if (tm.hour < 1 or tm.hour > 12) return error.InvalidDatetimeFormat;
        if (f.pm != 0 and tm.hour < 12) tm.hour += 12 else if (f.pm == 0 and tm.hour == 12) tm.hour = 0;
    }
    if (f.year != 0) {
        if (f.cc != 0 and f.yysz <= 2) {
            const cc = if (f.bc != 0) -f.cc else f.cc;
            const partial = @rem(f.year, 100);
            tm.year = if (partial != 0) (if (cc >= 0) (cc - 1) * 100 + partial else (cc + 1) * 100 - partial + 1) else cc * 100 + @as(i64, if (cc >= 0) 0 else 1);
        } else {
            tm.year = if (f.bc != 0) -f.year else f.year;
            if (tm.year < 0) tm.year += 1;
        }
        has_year = true;
    } else if (f.cc != 0) {
        const cc = if (f.bc != 0) -f.cc else f.cc;
        tm.year = if (cc >= 0) (cc - 1) * 100 + 1 else cc * 100 + 1;
        has_year = true;
    }
    if (f.j != 0) {
        const civil = temporal.civilOf(f.j - 2451545);
        tm.year = civil.year;
        tm.month = civil.month;
        tm.day = civil.day;
        has_year = true;
        has_month = true;
        has_day = true;
    }
    if (f.ww != 0) f.ddd = (f.ww - 1) * 7 + 1;
    if (f.w != 0) f.dd = (f.w - 1) * 7 + 1;
    if (f.dd != 0) {
        tm.day = f.dd;
        has_day = true;
    }
    if (f.mm != 0) {
        tm.month = f.mm;
        has_month = true;
    }
    if (f.ddd != 0 and (tm.month <= 1 or tm.day <= 1)) {
        if (tm.year == 0 and f.bc == 0) return error.InvalidDatetimeFormat;
        const sums_common = [_]i64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 };
        const sums_leap = [_]i64{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 };
        const sums = if (leap(tm.year)) sums_leap else sums_common;
        var month: usize = 1;
        while (month <= 12) : (month += 1) if (f.ddd <= sums[month]) break;
        if (month > 12) month = 12;
        if (tm.month <= 1) tm.month = @intCast(month);
        if (tm.day <= 1) tm.day = f.ddd - sums[month - 1];
        has_month = true;
        has_day = true;
    }
    if (f.ms != 0) tm.usec += f.ms * 1000;
    if (f.us != 0) tm.usec += f.us;
    // ValidateDate.
    if (has_month and (tm.month < 1 or tm.month > 12)) return error.DatetimeFieldOverflow;
    if (has_day and (tm.day < 1 or tm.day > 31)) return error.DatetimeFieldOverflow;
    if (has_year and has_month and has_day and tm.day > monthLength(tm.year, tm.month)) return error.DatetimeFieldOverflow;
    if (tm.hour < 0 or tm.hour >= 24 or tm.minute < 0 or tm.minute >= 60 or tm.second < 0 or tm.second >= 60 or tm.usec < 0 or tm.usec >= 1000000) return error.DatetimeFieldOverflow;
    return tm;
}

/// IS_VALID_JULIAN then the day count (to_date).
pub fn toDate(parsed: Parsed) Error!i32 {
    if (parsed.month < 1 or parsed.month > 12) return error.DatetimeFieldOverflow;
    if (parsed.year < -4713 or (parsed.year == -4713 and parsed.month < 11) or parsed.year > 5874898) return error.DatetimeFieldOverflow;
    const days = temporal.dateOf(parsed.year, parsed.month, parsed.day);
    if (!temporal.validDate(days)) return error.DatetimeFieldOverflow;
    return @intCast(days);
}

/// Local timestamp microseconds (tm2timestamp range checks).
pub fn toLocalTimestamp(parsed: Parsed) Error!i64 {
    const days: i64 = try toDate(parsed);
    const time = ((parsed.hour * 60 + parsed.minute) * 60 + parsed.second) * temporal.usecs_per_second + parsed.usec;
    const total = days * temporal.usecs_per_day + time;
    if (!temporal.validTimestamp(total)) return error.DatetimeFieldOverflow;
    return total;
}

// ---- number templates ---------------------------------------------------

const NumKey = enum { nine, zero, dec, d, comma, g, s, mi, pl, sg, fm, l, b, th, unsupported };

fn numKeyAt(template: []const u8, at: usize) ?struct { key: NumKey, width: usize } {
    const table = [_]struct { name: []const u8, key: NumKey }{
        .{ .name = "EEEE", .key = .unsupported }, .{ .name = "eeee", .key = .unsupported },
        .{ .name = "FM", .key = .fm },   .{ .name = "fm", .key = .fm },   .{ .name = "MI", .key = .mi },   .{ .name = "mi", .key = .mi },
        .{ .name = "PL", .key = .pl },   .{ .name = "pl", .key = .pl },   .{ .name = "PR", .key = .unsupported }, .{ .name = "pr", .key = .unsupported },
        .{ .name = "RN", .key = .unsupported }, .{ .name = "rn", .key = .unsupported }, .{ .name = "SG", .key = .sg }, .{ .name = "sg", .key = .sg },
        .{ .name = "SP", .key = .th },   .{ .name = "sp", .key = .th },   .{ .name = "TH", .key = .th },   .{ .name = "th", .key = .th },
        .{ .name = "9", .key = .nine },  .{ .name = "0", .key = .zero },  .{ .name = ".", .key = .dec },   .{ .name = ",", .key = .comma },
        .{ .name = "B", .key = .b },     .{ .name = "b", .key = .b },     .{ .name = "D", .key = .d },     .{ .name = "d", .key = .d },
        .{ .name = "G", .key = .g },     .{ .name = "g", .key = .g },     .{ .name = "L", .key = .l },     .{ .name = "l", .key = .l },
        .{ .name = "S", .key = .s },     .{ .name = "s", .key = .s },     .{ .name = "V", .key = .unsupported }, .{ .name = "v", .key = .unsupported },
    };
    for (table) |entry| if (prefixed(template[at..], entry.name)) return .{ .key = entry.key, .width = entry.name.len };
    return null;
}

pub const Number = struct {
    /// Sign then digits with an optional '.'.
    bytes: [256]u8 = undefined,
    len: usize = 0,
    /// Digits before the template's decimal point and digits read after it.
    pre: usize = 0,
    post: usize = 0,
};

/// NUM_processor input mode: the number text and its scale/precision.
pub fn toNumber(input: []const u8, template: []const u8, out: *Number, control: Control) Error!void {
    // NUMDesc_prepare: count template digits and flags.
    var pre: usize = 0;
    var post: usize = 0;
    var decimal = false;
    var lsign = false;
    var plus_minus = false;
    var at: usize = 0;
    while (at < template.len) {
        try tick(control);
        if (numKeyAt(template, at)) |found| {
            switch (found.key) {
                .nine, .zero => if (decimal) {
                    post += 1;
                } else {
                    pre += 1;
                },
                .dec, .d => {
                    if (decimal) return error.Syntax;
                    decimal = true;
                },
                .s => lsign = true,
                .mi, .pl, .sg => plus_minus = true,
                .unsupported => return error.UnsupportedStatement,
                else => {},
            }
            at += found.width;
        } else at += utf8Width(template, at);
    }
    out.len = 1;
    out.bytes[0] = ' ';
    var read_pre: usize = 0;
    var read_post: usize = 0;
    var read_dec = false;
    var s: usize = 0;
    at = 0;
    while (at < template.len) {
        try tick(control);
        if (s >= input.len) break;
        const found = numKeyAt(template, at) orelse {
            // Non-pattern template characters skip one input character.
            at += utf8Width(template, at);
            s += utf8Width(input, s);
            continue;
        };
        at += found.width;
        switch (found.key) {
            .nine, .zero, .dec, .d => {
                if (input[s] == ' ') s += 1;
                if (s >= input.len) {
                    s += 1;
                    continue;
                }
                var read = false;
                if (out.bytes[0] == ' ' and (found.key == .nine or found.key == .zero) and read_pre + read_post == 0) {
                    if (input[s] == '-') {
                        out.bytes[0] = '-';
                        s += 1;
                    } else if (input[s] == '+') {
                        out.bytes[0] = '+';
                        s += 1;
                    }
                }
                if (s >= input.len) continue;
                if (digit(input[s])) {
                    if (!(read_dec and read_post == post)) {
                        if (out.len == out.bytes.len) return error.TextCapacity;
                        out.bytes[out.len] = input[s];
                        out.len += 1;
                        if (read_dec) read_post += 1 else read_pre += 1;
                        read = true;
                    }
                } else if (decimal and !read_dec and input[s] == '.') {
                    if (out.len == out.bytes.len) return error.TextCapacity;
                    out.bytes[out.len] = '.';
                    out.len += 1;
                    read_dec = true;
                    read = true;
                }
                if (read and out.bytes[0] == ' ' and read_pre + read_post > 0 and lsign and s + 1 < input.len and !digit(input[s + 1])) {
                    if (input[s + 1] == '-' or input[s + 1] == '+') {
                        out.bytes[0] = input[s + 1];
                        s += 1;
                    }
                } else if (!read and out.bytes[0] == ' ' and read_pre + read_post > 0 and !lsign and plus_minus and (input[s] == '-' or input[s] == '+')) {
                    out.bytes[0] = input[s];
                }
                s += 1;
            },
            .comma, .g => {
                if (input[s] == ',') s += 1;
            },
            .mi, .pl, .sg => {
                const accepts_minus = found.key != .pl;
                const accepts_plus = found.key != .mi;
                if ((accepts_minus and input[s] == '-') or (accepts_plus and input[s] == '+')) {
                    out.bytes[0] = input[s];
                    s += 1;
                } else eatNonData(input, &s, 1);
            },
            .l => eatNonData(input, &s, 1),
            .th => eatNonData(input, &s, 2),
            else => {},
        }
    }
    out.pre = pre;
    out.post = read_post;
    if (out.bytes[out.len - 1] == '.') out.len -= 1;
}

/// NUM_eat_non_data_chars.
fn eatNonData(input: []const u8, s: *usize, count: usize) void {
    for (0..count) |_| {
        if (s.* >= input.len) return;
        const byte = input[s.*];
        if (digit(byte) or byte == '.' or byte == ',' or byte == '+' or byte == '-') return;
        s.* += utf8Width(input, s.*);
    }
}
