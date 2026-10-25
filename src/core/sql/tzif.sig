//! TZif (RFC 8536) version 2+ decoding over caller-owned bytes, plus POSIX
//! TZ strings (Layer 0, Q03). Nothing is copied: a validated file is read in
//! place (big-endian arrays of the 64-bit section). Validation checks the
//! magic, version >= 2, every count against the file size, sorted
//! transitions, type and abbreviation indices; anything else is
//! InvalidSettingValue (22023) and the caller keeps no cache entry.
//!
//! Lookups follow PostgreSQL's localtime.c: before the first transition the
//! first standard type applies; after the last one the footer TZ rule (when
//! present) applies. Local-to-UTC conversion follows
//! DetermineTimeZoneOffset: in a spring-forward gap the offset before the
//! transition is used, in a fall-back overlap the offset after it
//! (PostgreSQL docs Appendix B.1).
const types = @import("types.sig");
const Error = types.Error;

fn be32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}

fn be64(bytes: []const u8) i64 {
    return @bitCast((@as(u64, be32(bytes[0..4])) << 32) | be32(bytes[4..8]));
}

const Header = struct { isutcnt: usize, isstdcnt: usize, leapcnt: usize, timecnt: usize, typecnt: usize, charcnt: usize };

fn header(bytes: []const u8) Error!Header {
    if (bytes.len < 44 or !types.same(bytes[0..4], "TZif")) return error.InvalidSettingValue;
    return .{
        .isutcnt = be32(bytes[20..24]),
        .isstdcnt = be32(bytes[24..28]),
        .leapcnt = be32(bytes[28..32]),
        .timecnt = be32(bytes[32..36]),
        .typecnt = be32(bytes[36..40]),
        .charcnt = be32(bytes[40..44]),
    };
}

fn blockSize(h: Header, time_size: usize) usize {
    return h.timecnt * time_size + h.timecnt + h.typecnt * 6 + h.charcnt + h.leapcnt * (time_size + 4) + h.isstdcnt + h.isutcnt;
}

/// Located 64-bit data block of a validated file.
pub const View = struct {
    bytes: []const u8,
    times: usize,
    indices: usize,
    infos: usize,
    timecnt: usize,
    typecnt: usize,
    footer: []const u8,

    fn transition(self: *const View, index: usize) i64 {
        return be64(self.bytes[self.times + index * 8 ..][0..8]);
    }

    fn typeAt(self: *const View, index: usize) u8 {
        return self.bytes[self.indices + index];
    }

    fn offsetOf(self: *const View, type_index: usize) i32 {
        return @bitCast(be32(self.bytes[self.infos + type_index * 6 ..][0..4]));
    }

    fn dstOf(self: *const View, type_index: usize) bool {
        return self.bytes[self.infos + type_index * 6 + 4] != 0;
    }
};

pub fn view(bytes: []const u8) Error!View {
    const first = try header(bytes);
    if (bytes[4] < '2') return error.InvalidSettingValue;
    const v1 = 44 + blockSize(first, 4);
    if (v1 > bytes.len) return error.InvalidSettingValue;
    const second = try header(bytes[v1..]);
    const start = v1 + 44;
    if (second.typecnt == 0 or second.typecnt > 256 or second.charcnt == 0) return error.InvalidSettingValue;
    const size = blockSize(second, 8);
    if (size > bytes.len - start) return error.InvalidSettingValue;
    var out: View = .{
        .bytes = bytes,
        .times = start,
        .indices = start + second.timecnt * 8,
        .infos = start + second.timecnt * 9,
        .timecnt = second.timecnt,
        .typecnt = second.typecnt,
        .footer = "",
    };
    const footer_start = start + size;
    if (footer_start < bytes.len) {
        if (bytes[footer_start] != '\n') return error.InvalidSettingValue;
        var end = footer_start + 1;
        while (end < bytes.len and bytes[end] != '\n') end += 1;
        if (end == bytes.len) return error.InvalidSettingValue;
        out.footer = bytes[footer_start + 1 .. end];
    }
    return out;
}

/// Full validation (done once when the caller loads a file).
pub fn validate(bytes: []const u8) Error!void {
    const v = try view(bytes);
    const charcnt = blk: {
        const h = try header(bytes[v.times - 44 ..]);
        break :blk h.charcnt;
    };
    var previous: i64 = -9223372036854775808;
    for (0..v.timecnt) |index| {
        const at = v.transition(index);
        if (index != 0 and at <= previous) return error.InvalidSettingValue;
        previous = at;
        if (v.typeAt(index) >= v.typecnt) return error.InvalidSettingValue;
    }
    for (0..v.typecnt) |index| {
        const offset = v.offsetOf(index);
        if (offset < -89999 or offset > 93599) return error.InvalidSettingValue;
        if (v.bytes[v.infos + index * 6 + 4] > 1) return error.InvalidSettingValue;
        if (v.bytes[v.infos + index * 6 + 5] >= charcnt) return error.InvalidSettingValue;
    }
    if (v.footer.len != 0) _ = try parsePosix(v.footer);
}

// ---- POSIX TZ strings ----------------------------------------------------

pub const RuleDate = struct {
    kind: enum { month_week_day, julian, day_of_year } = .month_week_day,
    month: u8 = 1,
    week: u8 = 1,
    weekday: u8 = 0,
    day: u16 = 0,
    /// Local seconds after midnight (may be negative or exceed a day).
    time: i32 = 7200,
};

/// std_offset/dst_offset are seconds EAST of UTC (TZ strings are west).
pub const Posix = struct {
    std_offset: i32 = 0,
    has_dst: bool = false,
    dst_offset: i32 = 0,
    start: RuleDate = .{},
    end: RuleDate = .{},
};

const Cursor = struct {
    text: []const u8,
    at: usize = 0,

    fn peek(self: *const Cursor) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    fn name(self: *Cursor) Error!void {
        if (self.peek() == '<') {
            self.at += 1;
            while (self.at < self.text.len and self.text[self.at] != '>') self.at += 1;
            if (self.at == self.text.len) return error.InvalidSettingValue;
            self.at += 1;
            return;
        }
        while (self.at < self.text.len and types.letter(self.text[self.at]) and self.text[self.at] != '_') self.at += 1;
    }

    fn number(self: *Cursor, max: i32) Error!i32 {
        const start = self.at;
        var value: i32 = 0;
        while (self.at < self.text.len and types.digit(self.text[self.at])) : (self.at += 1) {
            value = value * 10 + (self.text[self.at] - '0');
            if (value > max) return error.InvalidSettingValue;
        }
        if (self.at == start) return error.InvalidSettingValue;
        return value;
    }

    /// [+-]hh[:mm[:ss]] in seconds (sign as written).
    fn time(self: *Cursor, max_hours: i32) Error!i32 {
        var negative = false;
        if (self.peek() == '+' or self.peek() == '-') {
            negative = self.peek() == '-';
            self.at += 1;
        }
        var total = try self.number(max_hours) * 3600;
        if (self.peek() == ':') {
            self.at += 1;
            total += try self.number(59) * 60;
            if (self.peek() == ':') {
                self.at += 1;
                total += try self.number(59);
            }
        }
        return if (negative) -total else total;
    }

    fn rule(self: *Cursor) Error!RuleDate {
        var out: RuleDate = .{};
        if (self.peek() == 'M') {
            self.at += 1;
            out.month = @intCast(try self.number(12));
            if (out.month == 0 or self.peek() != '.') return error.InvalidSettingValue;
            self.at += 1;
            out.week = @intCast(try self.number(5));
            if (out.week == 0 or self.peek() != '.') return error.InvalidSettingValue;
            self.at += 1;
            out.weekday = @intCast(try self.number(6));
        } else if (self.peek() == 'J') {
            self.at += 1;
            out.kind = .julian;
            out.day = @intCast(try self.number(365));
            if (out.day == 0) return error.InvalidSettingValue;
        } else {
            out.kind = .day_of_year;
            out.day = @intCast(try self.number(365));
        }
        if (self.peek() == '/') {
            self.at += 1;
            out.time = try self.time(167);
        }
        return out;
    }
};

/// Parses a POSIX TZ string such as `EST5EDT,M3.2.0,M11.1.0`, `<+05>-05`,
/// `UTC+3` or `+05:30` (offsets written west-positive).
pub fn parsePosix(text: []const u8) Error!Posix {
    var cursor: Cursor = .{ .text = text };
    try cursor.name();
    var out: Posix = .{};
    out.std_offset = -(try cursor.time(24));
    if (cursor.at == text.len) return out;
    const dst_start = cursor.at;
    try cursor.name();
    if (cursor.at == dst_start) return error.InvalidSettingValue;
    out.has_dst = true;
    out.dst_offset = out.std_offset + 3600;
    if (cursor.peek() != ',' and cursor.at < text.len) out.dst_offset = -(try cursor.time(24));
    if (cursor.peek() != ',') {
        // US default rules when none are given.
        out.start = .{ .month = 3, .week = 2, .weekday = 0 };
        out.end = .{ .month = 11, .week = 1, .weekday = 0 };
        if (cursor.at != text.len) return error.InvalidSettingValue;
        return out;
    }
    cursor.at += 1;
    out.start = try cursor.rule();
    if (cursor.peek() != ',') return error.InvalidSettingValue;
    cursor.at += 1;
    out.end = try cursor.rule();
    if (cursor.at != text.len) return error.InvalidSettingValue;
    return out;
}

// ---- calendar helpers (proleptic Gregorian, days since 1970-01-01) -------

pub fn leap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn yearOf(days: i64) i64 {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const month = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400;
    return if (month <= 2) y + 1 else y;
}

const month_days = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

/// Unix seconds (UTC) of a rule's transition in `year`, given the local
/// offset in effect before it.
fn ruleTime(date: RuleDate, year: i64, offset_before: i32) i64 {
    const jan1 = daysFromCivil(year, 1, 1);
    const day: i64 = switch (date.kind) {
        .julian => blk: {
            var d: i64 = date.day - 1;
            if (leap(year) and date.day >= 60) d += 1;
            break :blk jan1 + d;
        },
        .day_of_year => jan1 + date.day,
        .month_week_day => blk: {
            const first = daysFromCivil(year, date.month, 1);
            // 1970-01-01 was a Thursday (4).
            const weekday = @mod(first + 4, 7);
            var d = first + @mod(@as(i64, date.weekday) - weekday, 7) + (@as(i64, date.week) - 1) * 7;
            var length = month_days[date.month - 1];
            if (date.month == 2 and leap(year)) length += 1;
            while (d >= first + length) d -= 7;
            break :blk d;
        },
    };
    return day * 86400 + date.time - offset_before;
}

pub const Info = struct { offset: i32, dst: bool };

fn posixAt(rule: *const Posix, utc: i64) Info {
    if (!rule.has_dst) return .{ .offset = rule.std_offset, .dst = false };
    const year = yearOf(@divFloor(utc + rule.std_offset, 86400));
    const start = ruleTime(rule.start, year, rule.std_offset);
    const end = ruleTime(rule.end, year, rule.dst_offset);
    const in_dst = if (start < end) utc >= start and utc < end else !(utc >= end and utc < start);
    return if (in_dst) .{ .offset = rule.dst_offset, .dst = true } else .{ .offset = rule.std_offset, .dst = false };
}

/// Next POSIX-rule transition strictly after `utc` (within two years).
fn posixNext(rule: *const Posix, utc: i64) ?struct { at: i64, after: Info } {
    if (!rule.has_dst) return null;
    const year = yearOf(@divFloor(utc + rule.std_offset, 86400));
    var best: ?i64 = null;
    var info: Info = undefined;
    var y = year - 1;
    while (y <= year + 1) : (y += 1) {
        const start = ruleTime(rule.start, y, rule.std_offset);
        const end = ruleTime(rule.end, y, rule.dst_offset);
        if (start > utc and (best == null or start < best.?)) {
            best = start;
            info = .{ .offset = rule.dst_offset, .dst = true };
        }
        if (end > utc and (best == null or end < best.?)) {
            best = end;
            info = .{ .offset = rule.std_offset, .dst = false };
        }
    }
    return if (best) |at| .{ .at = at, .after = info } else null;
}

fn firstStandard(v: *const View) usize {
    for (0..v.typecnt) |index| if (!v.dstOf(index)) return index;
    return 0;
}

/// Index of the last transition at or before `utc`, or null.
fn lastAtOrBefore(v: *const View, utc: i64) ?usize {
    if (v.timecnt == 0 or v.transition(0) > utc) return null;
    var low: usize = 0;
    var high: usize = v.timecnt;
    while (high - low > 1) {
        const middle = (low + high) / 2;
        if (v.transition(middle) <= utc) low = middle else high = middle;
    }
    return low;
}

/// Offset in effect at Unix seconds `utc`.
pub fn infoAt(v: *const View, utc: i64) Info {
    const index = lastAtOrBefore(v, utc) orelse {
        const t = firstStandard(v);
        return .{ .offset = v.offsetOf(t), .dst = v.dstOf(t) };
    };
    if (index + 1 == v.timecnt and v.footer.len != 0) {
        if (parsePosix(v.footer)) |rule| return posixAt(&rule, utc) else |_| {}
    }
    const t = v.typeAt(index);
    return .{ .offset = v.offsetOf(t), .dst = v.dstOf(t) };
}

/// pg_next_dst_boundary: the offset at `utc` and the next transition after it.
pub const Boundary = struct { before: Info, at: i64, after: Info };

pub fn nextBoundary(v: *const View, utc: i64) ?Boundary {
    const before = infoAt(v, utc);
    const index = lastAtOrBefore(v, utc);
    const next: usize = if (index) |i| i + 1 else 0;
    if (next < v.timecnt) {
        const t = v.typeAt(next);
        return .{ .before = before, .at = v.transition(next), .after = .{ .offset = v.offsetOf(t), .dst = v.dstOf(t) } };
    }
    if (v.footer.len == 0) return null;
    const rule = parsePosix(v.footer) catch return null;
    const found = posixNext(&rule, utc) orelse return null;
    return .{ .before = before, .at = found.at, .after = found.after };
}

pub fn posixBoundary(rule: *const Posix, utc: i64) ?Boundary {
    const found = posixNext(rule, utc) orelse return null;
    return .{ .before = posixAt(rule, utc), .at = found.at, .after = found.after };
}

pub fn posixInfo(rule: *const Posix, utc: i64) Info {
    return posixAt(rule, utc);
}

/// DetermineTimeZoneOffset over a boundary finder: UTC seconds for local
/// seconds `local`.
pub fn resolveLocal(local: i64, boundary: ?Boundary, steady: Info) i64 {
    const b = boundary orelse return local - steady.offset;
    const before_time = local - b.before.offset;
    const after_time = local - b.after.offset;
    if (before_time < b.at and after_time < b.at) return before_time;
    if (before_time > b.at and after_time >= b.at) return after_time;
    if (before_time > after_time) return before_time;
    return after_time;
}
