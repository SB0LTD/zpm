//! DATE / TIMESTAMP / TIMESTAMPTZ / INTERVAL values (Layer 0, Q03).
//!
//! Representation is PostgreSQL's: DATE is i32 days and TIMESTAMP[TZ] i64
//! microseconds since 2000-01-01 (TIMESTAMPTZ in UTC), INTERVAL is
//! {months, days, microseconds}. +-infinity are the extreme values. Input is
//! ISO 8601 only (`YYYY-MM-DD[( |T)HH:MM[:SS[.frac]]][zone][ BC]`, zone `Z`,
//! `+-HH[[:]MM[[:]SS]]` or a zone name resolved through the session), plus
//! infinity, -infinity and epoch; malformed text is 22007, out-of-range
//! fields or values 22008. Output uses DateStyle ISO and IntervalStyle
//! postgres. Zones are UTC, fixed offsets, POSIX TZ strings or TZif data
//! (tzif.sig); local times in DST gaps/overlaps resolve as PostgreSQL's
//! DetermineTimeZoneOffset does.
const types = @import("types.sig");
const tzif = @import("tzif.sig");
const Error = types.Error;

pub const usecs_per_second: i64 = 1000000;
pub const usecs_per_day: i64 = 86400000000;
pub const usecs_per_hour: i64 = 3600000000;
pub const usecs_per_minute: i64 = 60000000;
/// Days and seconds between 1970-01-01 and 2000-01-01.
pub const unix_epoch_days: i64 = 10957;
pub const unix_epoch_seconds: i64 = 946684800;

pub const date_no_begin: i32 = -2147483648;
pub const date_no_end: i32 = 2147483647;
pub const timestamp_no_begin: i64 = -9223372036854775808;
pub const timestamp_no_end: i64 = 9223372036854775807;
/// PostgreSQL range limits (4714-11-24 BC .. 5874897-12-31 / 294276-12-31).
pub const min_date: i64 = -2451545;
pub const end_date: i64 = 2147483494 - 2451545;
pub const min_timestamp: i64 = -211813488000000000;
pub const end_timestamp: i64 = 9223371331200000000;

pub const Interval = struct {
    months: i32 = 0,
    days: i32 = 0,
    us: i64 = 0,
};

/// A session time zone. `offset` is seconds EAST of UTC (fixed zones).
pub const Zone = struct {
    kind: enum(u8) { utc, fixed, posix, tzif } = .utc,
    offset: i32 = 0,
    posix: tzif.Posix = .{},
    /// Validated TZif bytes owned by the caller (kind tzif).
    bytes: []const u8 = &.{},
};

/// Caller-supplied zone-name lookup (store/RAMSQL zone provider).
pub const Resolver = struct {
    context: ?*anyopaque = null,
    lookup: ?*const fn (?*anyopaque, []const u8, *Zone) Error!void = null,
};

pub fn validDate(days: i64) bool {
    return days >= min_date and days < end_date;
}

pub fn validTimestamp(us: i64) bool {
    return us >= min_timestamp and us < end_timestamp;
}

pub fn finiteDate(days: i32) bool {
    return days != date_no_begin and days != date_no_end;
}

pub fn finiteTimestamp(us: i64) bool {
    return us != timestamp_no_begin and us != timestamp_no_end;
}

// ---- calendar ------------------------------------------------------------

pub fn monthLength(year: i64, month: i64) i64 {
    const lengths = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var length = lengths[@intCast(month - 1)];
    if (month == 2 and tzif.leap(year)) length += 1;
    return length;
}

/// Days since 2000-01-01 of an astronomical-year civil date.
pub fn dateOf(year: i64, month: i64, day: i64) i64 {
    return tzif.daysFromCivil(year, month, day) - unix_epoch_days;
}

pub const Civil = struct { year: i64, month: i64, day: i64 };

pub fn civilOf(days: i64) Civil {
    const z = days + unix_epoch_days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{ .year = year, .month = month, .day = day };
}

// ---- zones ---------------------------------------------------------------

/// Seconds east of UTC in effect at `utc_us` (PostgreSQL epoch).
pub fn offsetAt(zone: *const Zone, utc_us: i64) i32 {
    const seconds = @divFloor(utc_us, usecs_per_second) + unix_epoch_seconds;
    return switch (zone.kind) {
        .utc => 0,
        .fixed => zone.offset,
        .posix => tzif.posixInfo(&zone.posix, seconds).offset,
        .tzif => blk: {
            const v = tzif.view(zone.bytes) catch break :blk 0;
            break :blk tzif.infoAt(&v, seconds).offset;
        },
    };
}

/// UTC microseconds of a local time in `zone` (DetermineTimeZoneOffset).
pub fn toUtc(zone: *const Zone, local_us: i64) Error!i64 {
    const seconds = @divFloor(local_us, usecs_per_second);
    const sub_second = @mod(local_us, usecs_per_second);
    const local = seconds + unix_epoch_seconds;
    const utc: i64 = switch (zone.kind) {
        .utc => local,
        .fixed => local - zone.offset,
        .posix => tzif.resolveLocal(local, tzif.posixBoundary(&zone.posix, local - 86400), tzif.posixInfo(&zone.posix, local - 86400)),
        .tzif => blk: {
            const v = tzif.view(zone.bytes) catch break :blk local;
            break :blk tzif.resolveLocal(local, tzif.nextBoundary(&v, local - 86400), tzif.infoAt(&v, local - 86400));
        },
    };
    return checkedAdd(try checkedMul(utc - unix_epoch_seconds, usecs_per_second), sub_second);
}

pub fn toLocal(zone: *const Zone, utc_us: i64) i64 {
    return utc_us + @as(i64, offsetAt(zone, utc_us)) * usecs_per_second;
}

// ---- text helpers --------------------------------------------------------

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 0x0b or byte == 0x0c;
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn insensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != y) return false;
    return true;
}

fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and space(text[start])) start += 1;
    while (end > start and space(text[end - 1])) end -= 1;
    return text[start..end];
}

const Scanner = struct {
    text: []const u8,
    at: usize = 0,

    fn peek(self: *const Scanner) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    fn done(self: *const Scanner) bool {
        return self.at >= self.text.len;
    }

    fn digits(self: *Scanner, out: *i64, max_count: usize) usize {
        var count: usize = 0;
        var value: i64 = 0;
        while (self.at < self.text.len and types.digit(self.text[self.at]) and count < max_count) : (self.at += 1) {
            value = value * 10 + (self.text[self.at] - '0');
            count += 1;
        }
        out.* = value;
        return count;
    }

    fn skipSpace(self: *Scanner) void {
        while (self.at < self.text.len and space(self.text[self.at])) self.at += 1;
    }
};

/// Fraction digits after a point to microseconds (rounded half up).
fn fraction(s: *Scanner) i64 {
    var value: i64 = 0;
    var count: usize = 0;
    var round_up = false;
    while (s.at < s.text.len and types.digit(s.text[s.at])) : (s.at += 1) {
        const digit_value = s.text[s.at] - '0';
        if (count < 6) {
            value = value * 10 + digit_value;
        } else if (count == 6) round_up = digit_value >= 5;
        count += 1;
    }
    while (count < 6) : (count += 1) value *= 10;
    if (round_up) value += 1;
    return value;
}

pub const Kind = enum { date, timestamp, timestamptz };

pub const Fields = struct {
    year: i64 = 2000,
    month: i64 = 1,
    day: i64 = 1,
    /// Microseconds since local midnight (may equal one day for 24:00).
    time: i64 = 0,
    zone_seconds: ?i64 = null,
    named: ?[]const u8 = null,
};

/// Parses `[+-]HH[[:]MM[[:]SS]]` (east-positive, ISO 8601 sign).
fn numericZone(s: *Scanner) Error!i64 {
    const negative = s.peek() == '-';
    s.at += 1;
    var hours: i64 = 0;
    const count = s.digits(&hours, 2);
    if (count == 0) return error.InvalidDatetimeFormat;
    var minutes: i64 = 0;
    var seconds: i64 = 0;
    if (count == 2 and types.digit(s.peek())) {
        if (s.digits(&minutes, 2) != 2) return error.InvalidDatetimeFormat;
        if (types.digit(s.peek()) and s.digits(&seconds, 2) != 2) return error.InvalidDatetimeFormat;
    } else if (s.peek() == ':') {
        s.at += 1;
        if (s.digits(&minutes, 2) != 2) return error.InvalidDatetimeFormat;
        if (s.peek() == ':') {
            s.at += 1;
            if (s.digits(&seconds, 2) != 2) return error.InvalidDatetimeFormat;
        }
    }
    if (hours > 15 or minutes > 59 or seconds > 59) return error.InvalidDatetimeFormat;
    const total = hours * 3600 + minutes * 60 + seconds;
    return if (negative) -total else total;
}

fn zoneNameByte(byte: u8) bool {
    return types.letter(byte) or types.digit(byte) or byte == '/' or byte == '+' or byte == '-';
}

/// ISO date[/time[/zone]] fields; specials are handled by the callers.
fn parseFields(text: []const u8, kind: Kind) Error!Fields {
    var s: Scanner = .{ .text = text };
    var out: Fields = .{};
    var year: i64 = 0;
    if (s.digits(&year, 9) == 0 or s.peek() != '-') return error.InvalidDatetimeFormat;
    s.at += 1;
    var month: i64 = 0;
    if (s.digits(&month, 2) == 0 or s.peek() != '-') return error.InvalidDatetimeFormat;
    s.at += 1;
    var day: i64 = 0;
    if (s.digits(&day, 2) == 0) return error.InvalidDatetimeFormat;
    out.year = year;
    out.month = month;
    out.day = day;
    var have_time = false;
    if (s.peek() == 'T' or s.peek() == 't' or space(s.peek())) {
        const mark = s.at;
        if (s.peek() == 'T' or s.peek() == 't') s.at += 1 else s.skipSpace();
        if (types.digit(s.peek())) {
            var hour: i64 = 0;
            var minute: i64 = 0;
            var second: i64 = 0;
            if (s.digits(&hour, 2) == 0 or s.peek() != ':') return error.InvalidDatetimeFormat;
            s.at += 1;
            if (s.digits(&minute, 2) != 2) return error.InvalidDatetimeFormat;
            var micros: i64 = 0;
            if (s.peek() == ':') {
                s.at += 1;
                if (s.digits(&second, 2) != 2) return error.InvalidDatetimeFormat;
                if (s.peek() == '.') {
                    s.at += 1;
                    micros = fraction(&s);
                }
            }
            if (hour > 24 or minute > 59 or second > 60 or (hour == 24 and (minute != 0 or second != 0 or micros != 0)))
                return error.DatetimeFieldOverflow;
            out.time = ((hour * 60 + minute) * 60 + second) * usecs_per_second + micros;
            have_time = true;
        } else s.at = mark;
    }
    // Zone.
    s.skipSpace();
    if (!s.done()) {
        const byte = s.peek();
        if (byte == '+' or byte == '-') {
            if (!have_time) return error.InvalidDatetimeFormat;
            out.zone_seconds = try numericZone(&s);
        } else if (types.letter(byte) and !(insensitive(s.text[s.at..@min(s.text.len, s.at + 2)], "bc") and (s.at + 2 == s.text.len)) and
            !(insensitive(s.text[s.at..@min(s.text.len, s.at + 2)], "ad") and (s.at + 2 == s.text.len)))
        {
            const start = s.at;
            while (!s.done() and zoneNameByte(s.peek())) s.at += 1;
            const name = s.text[start..s.at];
            if (insensitive(name, "z") or insensitive(name, "utc") or insensitive(name, "gmt") or insensitive(name, "zulu")) {
                out.zone_seconds = 0;
            } else out.named = name;
        }
    }
    s.skipSpace();
    if (!s.done()) {
        const rest = s.text[s.at..];
        if (insensitive(rest, "bc")) {
            out.year = 1 - out.year;
        } else if (!insensitive(rest, "ad")) return error.InvalidDatetimeFormat;
    }
    if (year == 0) return error.DatetimeFieldOverflow;
    if (out.month < 1 or out.month > 12) return error.DatetimeFieldOverflow;
    if (out.day < 1 or out.day > monthLength(out.year, out.month)) return error.DatetimeFieldOverflow;
    _ = kind;
    return out;
}

fn special(text: []const u8) ?enum { pos, neg, epoch } {
    if (insensitive(text, "infinity") or insensitive(text, "+infinity")) return .pos;
    if (insensitive(text, "-infinity")) return .neg;
    if (insensitive(text, "epoch")) return .epoch;
    return null;
}

pub fn parseDate(input: []const u8) Error!i32 {
    const text = trim(input);
    if (special(text)) |which| return switch (which) {
        .pos => date_no_end,
        .neg => date_no_begin,
        .epoch => -@as(i32, @intCast(unix_epoch_days)),
    };
    const fields = try parseFields(text, .date);
    if (fields.year < -4713 or fields.year > 5874898) return error.DatetimeFieldOverflow;
    const days = dateOf(fields.year, fields.month, fields.day);
    if (!validDate(days)) return error.DatetimeFieldOverflow;
    return @intCast(days);
}

/// TIMESTAMP (zone ignored) or TIMESTAMPTZ (UTC; zone from the text or the
/// session zone).
pub fn parseTimestamp(input: []const u8, kind: Kind, session_zone: *const Zone, resolver: Resolver) Error!i64 {
    const text = trim(input);
    if (special(text)) |which| return switch (which) {
        .pos => timestamp_no_end,
        .neg => timestamp_no_begin,
        .epoch => -unix_epoch_seconds * usecs_per_second,
    };
    const fields = try parseFields(text, kind);
    if (fields.year < -4713 or fields.year > 294277) return error.DatetimeFieldOverflow;
    const days = dateOf(fields.year, fields.month, fields.day);
    if (days < min_date or days > end_date) return error.DatetimeFieldOverflow;
    const local = try checkedAdd(try checkedMul(days, usecs_per_day), fields.time);
    var value = local;
    if (kind == .timestamptz) {
        if (fields.zone_seconds) |offset| {
            value = try checkedAdd(local, -offset * usecs_per_second);
        } else if (fields.named) |name| {
            var zone: Zone = .{};
            const lookup = resolver.lookup orelse return error.InvalidSettingValue;
            try lookup(resolver.context, name, &zone);
            value = try toUtc(&zone, local);
        } else value = try toUtc(session_zone, local);
    } else if (fields.named) |name| {
        // A zone name on TIMESTAMP input must still be a valid zone.
        var zone: Zone = .{};
        const lookup = resolver.lookup orelse return error.InvalidSettingValue;
        try lookup(resolver.context, name, &zone);
    }
    if (!validTimestamp(value)) return error.DatetimeFieldOverflow;
    return value;
}

/// AdjustTimestampForTypmod: precision 0..6, half away from zero.
pub fn roundTimestamp(us: i64, precision: i32) i64 {
    if (precision < 0 or precision >= 6 or !finiteTimestamp(us)) return us;
    var scale: i64 = 1;
    for (0..@intCast(6 - precision)) |_| scale *= 10;
    const offset = @divTrunc(scale, 2);
    if (us >= 0) return @divTrunc(us + offset, scale) * scale;
    return -(@divTrunc(-us + offset, scale) * scale);
}

// ---- output --------------------------------------------------------------

const Out = struct {
    bytes: []u8,
    at: usize = 0,

    fn byte(self: *Out, value: u8) void {
        self.bytes[self.at] = value;
        self.at += 1;
    }

    fn text(self: *Out, value: []const u8) void {
        @memcpy(self.bytes[self.at..][0..value.len], value);
        self.at += value.len;
    }

    fn number(self: *Out, value: u64, width: usize) void {
        var reversed: [20]u8 = undefined;
        var count: usize = 0;
        var rest = value;
        while (true) {
            reversed[count] = @intCast('0' + rest % 10);
            count += 1;
            rest /= 10;
            if (rest == 0) break;
        }
        while (count < width) : (count += 1) reversed[count] = '0';
        while (count > 0) {
            count -= 1;
            self.byte(reversed[count]);
        }
    }

    fn signed(self: *Out, value: i64) void {
        if (value < 0) self.byte('-');
        self.number(@abs(value), 1);
    }

    fn slice(self: *const Out) []const u8 {
        return self.bytes[0..self.at];
    }
};

fn writeDate(out: *Out, civil: Civil) void {
    const display: i64 = if (civil.year > 0) civil.year else 1 - civil.year;
    out.number(@intCast(display), 4);
    out.byte('-');
    out.number(@intCast(civil.month), 2);
    out.byte('-');
    out.number(@intCast(civil.day), 2);
}

fn writeSeconds(out: *Out, seconds: i64, micros: i64) void {
    out.number(@intCast(seconds), 2);
    if (micros == 0) return;
    out.byte('.');
    var digits: [6]u8 = undefined;
    var rest: u64 = @intCast(micros);
    var index: usize = 6;
    while (index > 0) {
        index -= 1;
        digits[index] = @intCast('0' + rest % 10);
        rest /= 10;
    }
    var length: usize = 6;
    while (length > 0 and digits[length - 1] == '0') length -= 1;
    out.text(digits[0..length]);
}

fn writeTime(out: *Out, time: i64) void {
    const hours = @divTrunc(time, usecs_per_hour);
    const minutes = @divTrunc(@mod(time, usecs_per_hour), usecs_per_minute);
    const seconds = @divTrunc(@mod(time, usecs_per_minute), usecs_per_second);
    out.number(@intCast(hours), 2);
    out.byte(':');
    out.number(@intCast(minutes), 2);
    out.byte(':');
    writeSeconds(out, seconds, @mod(time, usecs_per_second));
}

pub fn formatDate(days: i32, buffer: []u8) []const u8 {
    if (days == date_no_end) return copyText(buffer, "infinity");
    if (days == date_no_begin) return copyText(buffer, "-infinity");
    var out: Out = .{ .bytes = buffer };
    const civil = civilOf(days);
    writeDate(&out, civil);
    if (civil.year <= 0) out.text(" BC");
    return out.slice();
}

fn copyText(buffer: []u8, value: []const u8) []const u8 {
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

/// TIMESTAMP output, or TIMESTAMPTZ output in `zone` when non-null.
pub fn formatTimestamp(us: i64, zone: ?*const Zone, buffer: []u8) []const u8 {
    if (us == timestamp_no_end) return copyText(buffer, "infinity");
    if (us == timestamp_no_begin) return copyText(buffer, "-infinity");
    var out: Out = .{ .bytes = buffer };
    var offset: i64 = 0;
    if (zone) |z| offset = offsetAt(z, us);
    const local = us + offset * usecs_per_second;
    const days = @divFloor(local, usecs_per_day);
    const civil = civilOf(days);
    writeDate(&out, civil);
    out.byte(' ');
    writeTime(&out, local - days * usecs_per_day);
    if (zone != null) {
        out.byte(if (offset < 0) '-' else '+');
        const magnitude: u64 = @abs(offset);
        out.number(magnitude / 3600, 2);
        if (magnitude % 3600 != 0) {
            out.byte(':');
            out.number((magnitude % 3600) / 60, 2);
            if (magnitude % 60 != 0) {
                out.byte(':');
                out.number(magnitude % 60, 2);
            }
        }
    }
    if (civil.year <= 0) out.text(" BC");
    return out.slice();
}

/// IntervalStyle postgres (EncodeInterval).
pub fn formatInterval(value: Interval, buffer: []u8) []const u8 {
    var out: Out = .{ .bytes = buffer };
    var is_zero = true;
    var is_before = false;
    const year: i64 = @divTrunc(@as(i64, value.months), 12);
    const month: i64 = @rem(@as(i64, value.months), 12);
    const parts = [_]struct { value: i64, unit: []const u8 }{
        .{ .value = year, .unit = "year" }, .{ .value = month, .unit = "mon" }, .{ .value = value.days, .unit = "day" },
    };
    for (parts) |part| {
        if (part.value == 0) continue;
        if (!is_zero) out.byte(' ');
        if (is_before and part.value > 0) out.byte('+');
        out.signed(part.value);
        out.byte(' ');
        out.text(part.unit);
        if (part.value != 1) out.byte('s');
        is_before = part.value < 0;
        is_zero = false;
    }
    const time = value.us;
    if (is_zero or time != 0) {
        if (!is_zero) out.byte(' ');
        if (time < 0) out.byte('-') else if (is_before) out.byte('+');
        const magnitude: u64 = @abs(time);
        out.number(magnitude / @as(u64, usecs_per_hour), 2);
        out.byte(':');
        out.number((magnitude % @as(u64, usecs_per_hour)) / @as(u64, usecs_per_minute), 2);
        out.byte(':');
        writeSeconds(&out, @intCast((magnitude % @as(u64, usecs_per_minute)) / @as(u64, usecs_per_second)), @intCast(magnitude % @as(u64, usecs_per_second)));
    }
    return out.slice();
}

// ---- interval input -------------------------------------------------------

const Unit = enum { microsecond, millisecond, second, minute, hour, day, week, month, year, decade, century, millennium };

fn unitOf(word: []const u8) ?Unit {
    const table = [_]struct { name: []const u8, unit: Unit }{
        .{ .name = "microsecond", .unit = .microsecond }, .{ .name = "microseconds", .unit = .microsecond }, .{ .name = "usec", .unit = .microsecond }, .{ .name = "usecs", .unit = .microsecond }, .{ .name = "us", .unit = .microsecond },
        .{ .name = "millisecond", .unit = .millisecond }, .{ .name = "milliseconds", .unit = .millisecond }, .{ .name = "msec", .unit = .millisecond }, .{ .name = "msecs", .unit = .millisecond }, .{ .name = "ms", .unit = .millisecond },
        .{ .name = "second", .unit = .second },           .{ .name = "seconds", .unit = .second },           .{ .name = "sec", .unit = .second },           .{ .name = "secs", .unit = .second },           .{ .name = "s", .unit = .second },
        .{ .name = "minute", .unit = .minute },           .{ .name = "minutes", .unit = .minute },           .{ .name = "min", .unit = .minute },           .{ .name = "mins", .unit = .minute },           .{ .name = "m", .unit = .minute },
        .{ .name = "hour", .unit = .hour },               .{ .name = "hours", .unit = .hour },               .{ .name = "hr", .unit = .hour },              .{ .name = "hrs", .unit = .hour },              .{ .name = "h", .unit = .hour },
        .{ .name = "day", .unit = .day },                 .{ .name = "days", .unit = .day },                 .{ .name = "d", .unit = .day },
        .{ .name = "week", .unit = .week },               .{ .name = "weeks", .unit = .week },               .{ .name = "w", .unit = .week },
        .{ .name = "month", .unit = .month },             .{ .name = "months", .unit = .month },             .{ .name = "mon", .unit = .month },            .{ .name = "mons", .unit = .month },
        .{ .name = "year", .unit = .year },               .{ .name = "years", .unit = .year },               .{ .name = "yr", .unit = .year },              .{ .name = "yrs", .unit = .year },              .{ .name = "y", .unit = .year },
        .{ .name = "decade", .unit = .decade },           .{ .name = "decades", .unit = .decade },
        .{ .name = "century", .unit = .century },         .{ .name = "centuries", .unit = .century },        .{ .name = "c", .unit = .century },
        .{ .name = "millennium", .unit = .millennium },   .{ .name = "millennia", .unit = .millennium },     .{ .name = "millenniums", .unit = .millennium },
    };
    for (table) |entry| if (insensitive(word, entry.name)) return entry.unit;
    return null;
}

/// A decimal number as integer part and a fraction in 1e-9 units.
const Number = struct { negative: bool, whole: i64, nanos: i64 };

fn checkedAdd(a: i64, b: i64) Error!i64 {
    const sum = @addWithOverflow(a, b);
    if (sum[1] != 0) return error.DatetimeFieldOverflow;
    return sum[0];
}

fn checkedMul(a: i64, b: i64) Error!i64 {
    const product = @mulWithOverflow(a, b);
    if (product[1] != 0) return error.DatetimeFieldOverflow;
    return product[0];
}

const Accumulator = struct {
    months: i64 = 0,
    days: i64 = 0,
    us: i64 = 0,

    /// Fractional part (nanos/1e9) of `scale` days as days and microseconds.
    fn fractionalDays(self: *Accumulator, sign: i64, nanos: i64, scale: i64) Error!void {
        // value in days * 1e9
        const total = nanos * scale;
        const whole_days = @divTrunc(total, 1000000000);
        self.days = try checkedAdd(self.days, sign * whole_days);
        const rest = total - whole_days * 1000000000;
        // rest/1e9 days in microseconds, rounded.
        const micros = @divTrunc(rest * 86400 + 500, 1000);
        self.us = try checkedAdd(self.us, sign * micros);
    }

    // Sign each part before addition so INT64_MIN remains representable.
    fn signedMicros(sign: i64, whole: i64, scale: i64, fraction_us: i64) Error!i64 {
        return checkedAdd(try checkedMul(sign * whole, scale), sign * fraction_us);
    }

    fn add(self: *Accumulator, amount: Number, unit: Unit) Error!void {
        const sign: i64 = if (amount.negative) -1 else 1;
        const whole = amount.whole;
        const nanos = amount.nanos;
        switch (unit) {
            .microsecond => self.us = try checkedAdd(self.us, try signedMicros(sign, whole, 1, @divTrunc(nanos + 500000000, 1000000000))),
            .millisecond => self.us = try checkedAdd(self.us, try signedMicros(sign, whole, 1000, @divTrunc(nanos + 500000, 1000000))),
            .second => self.us = try checkedAdd(self.us, try signedMicros(sign, whole, usecs_per_second, @divTrunc(nanos + 500, 1000))),
            .minute => self.us = try checkedAdd(self.us, try signedMicros(sign, whole, usecs_per_minute, @divTrunc(nanos * 60 + 500, 1000))),
            .hour => self.us = try checkedAdd(self.us, try signedMicros(sign, whole, usecs_per_hour, @divTrunc(nanos * 3600 + 500, 1000))),
            .day => {
                self.days = try checkedAdd(self.days, sign * whole);
                try self.fractionalDays(sign, nanos, 1);
            },
            .week => {
                self.days = try checkedAdd(self.days, sign * try checkedMul(whole, 7));
                try self.fractionalDays(sign, nanos, 7);
            },
            .month => {
                self.months = try checkedAdd(self.months, sign * whole);
                try self.fractionalDays(sign, nanos, 30);
            },
            .year, .decade, .century, .millennium => {
                const scale: i64 = switch (unit) {
                    .year => 1,
                    .decade => 10,
                    .century => 100,
                    else => 1000,
                };
                self.months = try checkedAdd(self.months, sign * try checkedMul(whole, scale * 12));
                // rint(frac * scale * 12) months.
                const extra = @divTrunc(nanos * scale * 12 + 500000000, 1000000000);
                self.months = try checkedAdd(self.months, sign * extra);
            },
        }
    }
};

fn number(s: *Scanner) Error!?Number {
    var out: Number = .{ .negative = false, .whole = 0, .nanos = 0 };
    if (s.peek() == '+' or s.peek() == '-') {
        out.negative = s.peek() == '-';
        s.at += 1;
    }
    const start = s.at;
    while (types.digit(s.peek())) : (s.at += 1) {
        out.whole = try checkedAdd(try checkedMul(out.whole, 10), s.peek() - '0');
    }
    var count: usize = s.at - start;
    if (s.peek() == '.') {
        s.at += 1;
        var scale: i64 = 100000000;
        while (types.digit(s.peek())) : (s.at += 1) {
            out.nanos += (s.peek() - '0') * scale;
            scale = @divTrunc(scale, 10);
            count += 1;
        }
    }
    if (count == 0) return null;
    return out;
}

/// IntervalStyle postgres input: `[@] {number unit | [+-]hh:mm[:ss[.f]]}... [ago]`.
pub fn parseInterval(input: []const u8) Error!Interval {
    return parseIntervalFields(input) catch |err| switch (err) {
        error.DatetimeFieldOverflow => error.IntervalFieldOverflow,
        else => err,
    };
}

fn parseIntervalFields(input: []const u8) Error!Interval {
    const text = trim(input);
    var s: Scanner = .{ .text = text };
    var acc: Accumulator = .{};
    var any = false;
    var ago = false;
    s.skipSpace();
    if (s.peek() == '@') {
        s.at += 1;
        s.skipSpace();
    }
    while (!s.done()) {
        if (ago) return error.InvalidDatetimeFormat;
        if (types.letter(s.peek())) {
            const start = s.at;
            while (types.letter(s.peek())) s.at += 1;
            if (!insensitive(s.text[start..s.at], "ago")) return error.InvalidDatetimeFormat;
            ago = true;
            s.skipSpace();
            continue;
        }
        const mark = s.at;
        const value = (try number(&s)) orelse return error.InvalidDatetimeFormat;
        if (s.peek() == ':') {
            // hh:mm[:ss[.frac]]
            s.at = mark;
            var negative = false;
            if (s.peek() == '+' or s.peek() == '-') {
                negative = s.peek() == '-';
                s.at += 1;
            }
            var hours: i64 = 0;
            var minutes: i64 = 0;
            var seconds: i64 = 0;
            if (s.digits(&hours, 18) == 0 or s.peek() != ':') return error.InvalidDatetimeFormat;
            s.at += 1;
            if (s.digits(&minutes, 2) == 0) return error.InvalidDatetimeFormat;
            var micros: i64 = 0;
            if (s.peek() == ':') {
                s.at += 1;
                if (s.digits(&seconds, 2) == 0) return error.InvalidDatetimeFormat;
                if (s.peek() == '.') {
                    s.at += 1;
                    micros = fraction(&s);
                }
            }
            if (minutes > 59 or seconds > 59) return error.DatetimeFieldOverflow;
            var total = try checkedAdd(try checkedMul(hours, usecs_per_hour), (minutes * 60 + seconds) * usecs_per_second + micros);
            if (negative) total = -total;
            acc.us = try checkedAdd(acc.us, total);
            any = true;
            s.skipSpace();
            continue;
        }
        s.skipSpace();
        var unit: Unit = .second;
        if (types.letter(s.peek())) {
            const start = s.at;
            while (types.letter(s.peek())) s.at += 1;
            const word = s.text[start..s.at];
            if (insensitive(word, "ago")) {
                s.at = start;
            } else unit = unitOf(word) orelse return error.InvalidDatetimeFormat;
        } else if (!s.done() and !types.digit(s.peek()) and s.peek() != '+' and s.peek() != '-') return error.InvalidDatetimeFormat;
        try acc.add(value, unit);
        any = true;
        s.skipSpace();
    }
    if (!any) return error.InvalidDatetimeFormat;
    if (ago) {
        acc.months = try checkedMul(acc.months, -1);
        acc.days = try checkedMul(acc.days, -1);
        acc.us = try checkedMul(acc.us, -1);
    }
    if (acc.months < -2147483648 or acc.months > 2147483647 or acc.days < -2147483648 or acc.days > 2147483647) return error.DatetimeFieldOverflow;
    return .{ .months = @intCast(acc.months), .days = @intCast(acc.days), .us = acc.us };
}

// ---- arithmetic ----------------------------------------------------------

pub fn intervalSpan(value: Interval) i128 {
    return (@as(i128, value.months) * 30 + value.days) * usecs_per_day + value.us;
}

pub fn compareInterval(a: Interval, b: Interval) i8 {
    const left = intervalSpan(a);
    const right = intervalSpan(b);
    return if (left < right) -1 else if (left > right) 1 else 0;
}

pub fn negateInterval(value: Interval) Error!Interval {
    if (value.months == -2147483648 or value.days == -2147483648 or value.us == timestamp_no_begin) return error.DatetimeFieldOverflow;
    return .{ .months = -value.months, .days = -value.days, .us = -value.us };
}

pub fn addIntervals(a: Interval, b: Interval) Error!Interval {
    const months = @addWithOverflow(a.months, b.months);
    const days = @addWithOverflow(a.days, b.days);
    const us = @addWithOverflow(a.us, b.us);
    if (months[1] != 0 or days[1] != 0 or us[1] != 0) return error.DatetimeFieldOverflow;
    return .{ .months = months[0], .days = days[0], .us = us[0] };
}

/// Adds months (clamping the day) and days to a local timestamp.
fn addCalendar(local: i64, months: i32, days: i32) Error!i64 {
    var value = local;
    if (months != 0) {
        const day_index = @divFloor(value, usecs_per_day);
        const time = value - day_index * usecs_per_day;
        const civil = civilOf(day_index);
        const total = civil.year * 12 + (civil.month - 1) + months;
        const year = @divFloor(total, 12);
        const month = total - year * 12 + 1;
        if (year < -4713 or year > 294277) return error.DatetimeFieldOverflow;
        const day = @min(civil.day, monthLength(year, month));
        value = try checkedAdd(try checkedMul(dateOf(year, month, day), usecs_per_day), time);
    }
    if (days != 0) value = try checkedAdd(value, try checkedMul(days, usecs_per_day));
    return value;
}

pub fn timestampPlus(us: i64, span: Interval) Error!i64 {
    if (!finiteTimestamp(us)) return us;
    var value = try addCalendar(us, span.months, span.days);
    value = try checkedAdd(value, span.us);
    if (!validTimestamp(value)) return error.DatetimeFieldOverflow;
    return value;
}

/// timestamptz + interval: months and days in local time of `zone`.
pub fn timestamptzPlus(us: i64, span: Interval, zone: *const Zone) Error!i64 {
    if (!finiteTimestamp(us)) return us;
    var value = us;
    if (span.months != 0 or span.days != 0) {
        const local = try addCalendar(toLocal(zone, us), span.months, span.days);
        value = try toUtc(zone, local);
    }
    value = try checkedAdd(value, span.us);
    if (!validTimestamp(value)) return error.DatetimeFieldOverflow;
    return value;
}

/// timestamp - timestamp, then justify_hours.
pub fn timestampDifference(a: i64, b: i64) Error!Interval {
    if (!finiteTimestamp(a) or !finiteTimestamp(b)) return error.DatetimeFieldOverflow;
    const difference = @subWithOverflow(a, b);
    if (difference[1] != 0) return error.DatetimeFieldOverflow;
    var time = difference[0];
    var days = @divTrunc(time, usecs_per_day);
    time -= days * usecs_per_day;
    if (days > 0 and time < 0) {
        time += usecs_per_day;
        days -= 1;
    } else if (days < 0 and time > 0) {
        time -= usecs_per_day;
        days += 1;
    }
    return .{ .months = 0, .days = @intCast(days), .us = time };
}

pub fn datePlusDays(days: i32, delta: i64) Error!i32 {
    if (!finiteDate(days)) return days;
    const value = try checkedAdd(days, delta);
    if (!validDate(value)) return error.DatetimeFieldOverflow;
    return @intCast(value);
}

pub fn dateToTimestamp(days: i32) Error!i64 {
    if (days == date_no_begin) return timestamp_no_begin;
    if (days == date_no_end) return timestamp_no_end;
    const value = try checkedMul(days, usecs_per_day);
    if (!validTimestamp(value)) return error.DatetimeFieldOverflow;
    return value;
}

pub fn timestampToDate(us: i64) i32 {
    if (us == timestamp_no_begin) return date_no_begin;
    if (us == timestamp_no_end) return date_no_end;
    return @intCast(@divFloor(us, usecs_per_day));
}

/// Unix microseconds (wall clock) to the PostgreSQL epoch.
pub fn fromUnixUs(unix_us: i64) i64 {
    return unix_us - unix_epoch_seconds * usecs_per_second;
}
