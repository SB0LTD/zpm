//! TIME and TIME WITH TIME ZONE values (Layer 0), after PostgreSQL's date.c
//! and DecodeTimeOnly.
//!
//! TIME is microseconds since midnight, 00:00:00 through 24:00:00 inclusive.
//! TIMETZ adds the zone as seconds WEST of UTC (PostgreSQL's internal sign;
//! output shows the usual east-positive offset), limited to +-15:59:59.
//!
//! Accepted input (a subset of DecodeTimeOnly): optional leading ISO date
//! `YYYY-MM-DD` (ignored after validation) followed by a space or `T`;
//! `H[H]:MM[:SS[.fraction]]` or compact `HHMM`/`HHMMSS[.fraction]`;
//! optional `AM`/`PM`; optional zone `Z`, `UTC`, `GMT`, `[+-]HH[[:]MM[[:]SS]]`
//! or a zone name resolved by the session; `allballs`. A TIME ignores the
//! zone. A TIMETZ without one takes the session zone's offset on the
//! transaction date. Syntax errors are 22007, field values out of range
//! 22008. Fractions beyond microseconds round half up; TIME(p) rounds half
//! up to p digits (AdjustTimeForTypmod), and 24:00:00 is a valid result.
const types = @import("types.sig");
const temporal = @import("temporal.sig");
const Error = types.Error;

pub const usecs_per_day: i64 = temporal.usecs_per_day;
const usecs_per_second: i64 = temporal.usecs_per_second;
/// TZDISP_LIMIT - 1: the largest zone displacement in seconds.
pub const max_zone: i32 = 15 * 3600 + 59 * 60 + 59;

pub const TimeTz = struct {
    /// Microseconds since local midnight.
    us: i64 = 0,
    /// Seconds west of UTC.
    zone: i32 = 0,
};

pub fn validTime(us: i64) bool {
    return us >= 0 and us <= usecs_per_day;
}

pub fn validZone(zone: i64) bool {
    return zone >= -max_zone and zone <= max_zone;
}

/// timetz_cmp_internal: true (UTC-equivalent) time first, then the zone.
pub fn compareTimeTz(a: TimeTz, b: TimeTz) i8 {
    const left = a.us + @as(i64, a.zone) * usecs_per_second;
    const right = b.us + @as(i64, b.zone) * usecs_per_second;
    if (left != right) return if (left < right) -1 else 1;
    if (a.zone != b.zone) return if (a.zone < b.zone) -1 else 1;
    return 0;
}

// ---- input -----------------------------------------------------------------

fn digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn same(text: []const u8, word: []const u8) bool {
    if (text.len != word.len) return false;
    for (text, word) |a, b| if (lower(a) != b) return false;
    return true;
}

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 0x0b or byte == 0x0c;
}

const Scanner = struct {
    text: []const u8,
    at: usize = 0,

    fn peek(self: *const Scanner) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    fn skipSpace(self: *Scanner) void {
        while (self.at < self.text.len and space(self.text[self.at])) self.at += 1;
    }

    /// Up to `limit` digits; returns the count.
    fn number(self: *Scanner, out: *i64, limit: usize) usize {
        var count: usize = 0;
        var value: i64 = 0;
        while (count < limit and self.at < self.text.len and digit(self.text[self.at])) : (self.at += 1) {
            value = value * 10 + (self.text[self.at] - '0');
            count += 1;
        }
        out.* = value;
        return count;
    }

    fn runLength(self: *const Scanner) usize {
        var end = self.at;
        while (end < self.text.len and digit(self.text[end])) end += 1;
        return end - self.at;
    }
};

/// Fraction digits after a point, in microseconds rounded half up (the
/// result may equal one second).
fn fraction(s: *Scanner) i64 {
    var value: i64 = 0;
    var count: usize = 0;
    var round_up = false;
    while (s.at < s.text.len and digit(s.text[s.at])) : (s.at += 1) {
        const digit_value: i64 = s.text[s.at] - '0';
        if (count < 6) {
            value = value * 10 + digit_value;
        } else if (count == 6) round_up = digit_value >= 5;
        count += 1;
    }
    while (count < 6) : (count += 1) value *= 10;
    if (round_up) value += 1;
    return value;
}

/// `[+-]HH[[:]MM[[:]SS]]` as seconds WEST of UTC.
fn numericZone(s: *Scanner) Error!i32 {
    const negative = s.peek() == '-';
    s.at += 1;
    var hours: i64 = 0;
    var minutes: i64 = 0;
    var seconds: i64 = 0;
    const run = s.runLength();
    if (run == 0) return error.InvalidDatetimeFormat;
    if (run > 2 and s.peek() != ':') {
        // Compact HHMM or HHMMSS (or H/HMM forms).
        if (run != 4 and run != 6 and run != 3) return error.InvalidDatetimeFormat;
        _ = s.number(&hours, if (run == 3) 1 else 2);
        _ = s.number(&minutes, 2);
        if (run == 6) _ = s.number(&seconds, 2);
    } else {
        if (s.number(&hours, 2) == 0) return error.InvalidDatetimeFormat;
        if (s.peek() == ':') {
            s.at += 1;
            if (s.number(&minutes, 2) != 2) return error.InvalidDatetimeFormat;
            if (s.peek() == ':') {
                s.at += 1;
                if (s.number(&seconds, 2) != 2) return error.InvalidDatetimeFormat;
            }
        }
    }
    // DecodeTimezone: hours beyond 15, minutes or seconds beyond 59 are
    // DTERR_TZDISP_OVERFLOW (22009).
    if (hours > 15 or minutes > 59 or seconds > 59) return error.InvalidTimeZoneDisplacement;
    const east = hours * 3600 + minutes * 60 + seconds;
    return @intCast(if (negative) east else -east);
}

fn zoneNameByte(byte: u8) bool {
    return types.letter(byte) or digit(byte) or byte == '/' or byte == '+' or byte == '-';
}

pub const Parsed = struct {
    us: i64,
    /// Seconds west of UTC when the input named a zone.
    zone: ?i32 = null,
    /// A zone name that the caller resolves.
    named: ?[]const u8 = null,
    /// Days since 2000-01-01 of a leading date, if any.
    date: ?i64 = null,
};

fn leadingDate(s: *Scanner) Error!?i64 {
    // YYYY-MM-DD: at least four year digits followed by '-'.
    const run = s.runLength();
    if (run < 4 or s.at + run >= s.text.len or s.text[s.at + run] != '-') return null;
    var year: i64 = 0;
    if (run > 9) return error.InvalidDatetimeFormat;
    _ = s.number(&year, run);
    s.at += 1;
    var month: i64 = 0;
    if (s.number(&month, 2) == 0 or s.peek() != '-') return error.InvalidDatetimeFormat;
    s.at += 1;
    var day: i64 = 0;
    if (s.number(&day, 2) == 0) return error.InvalidDatetimeFormat;
    if (year == 0 or month < 1 or month > 12 or day < 1 or day > temporal.monthLength(year, month)) return error.DatetimeFieldOverflow;
    if (s.peek() == 'T' or s.peek() == 't') s.at += 1 else if (space(s.peek())) s.skipSpace() else return error.InvalidDatetimeFormat;
    return temporal.dateOf(year, month, day);
}

pub fn parse(input: []const u8) Error!Parsed {
    var s: Scanner = .{ .text = input };
    s.skipSpace();
    var end = input.len;
    while (end > s.at and space(input[end - 1])) end -= 1;
    s.text = input[0..end];
    if (same(s.text[s.at..], "allballs")) return .{ .us = 0, .zone = 0 };
    var out: Parsed = .{ .us = 0 };
    out.date = try leadingDate(&s);
    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var micros: i64 = 0;
    const run = s.runLength();
    if (run == 0) return error.InvalidDatetimeFormat;
    if (s.at + run < s.text.len and s.text[s.at + run] == ':') {
        if (run > 2) return error.InvalidDatetimeFormat;
        _ = s.number(&hour, 2);
        s.at += 1;
        if (s.number(&minute, 2) != 2) return error.InvalidDatetimeFormat;
        if (s.peek() == ':') {
            s.at += 1;
            if (s.number(&second, 2) != 2) return error.InvalidDatetimeFormat;
            if (s.peek() == '.') {
                s.at += 1;
                micros = fraction(&s);
            }
        }
    } else if (run == 6 or run == 4) {
        _ = s.number(&hour, 2);
        _ = s.number(&minute, 2);
        if (run == 6) {
            _ = s.number(&second, 2);
            if (s.peek() == '.') {
                s.at += 1;
                micros = fraction(&s);
            }
        }
    } else return error.InvalidDatetimeFormat;
    s.skipSpace();
    // AM/PM.
    if (s.text.len - s.at >= 2 and (same(s.text[s.at .. s.at + 2], "am") or same(s.text[s.at .. s.at + 2], "pm")) and
        (s.at + 2 == s.text.len or !types.letter(s.text[s.at + 2])))
    {
        const pm = lower(s.text[s.at]) == 'p';
        s.at += 2;
        if (hour < 1 or hour > 12) return error.DatetimeFieldOverflow;
        if (hour == 12) hour = 0;
        if (pm) hour += 12;
        s.skipSpace();
    }
    // Zone.
    if (s.at < s.text.len) {
        const byte = s.peek();
        if (byte == '+' or byte == '-') {
            out.zone = try numericZone(&s);
        } else if (types.letter(byte)) {
            const start = s.at;
            while (s.at < s.text.len and zoneNameByte(s.text[s.at])) s.at += 1;
            const name = s.text[start..s.at];
            if (same(name, "z") or same(name, "utc") or same(name, "gmt") or same(name, "zulu")) {
                out.zone = 0;
            } else out.named = name;
        } else return error.InvalidDatetimeFormat;
        s.skipSpace();
        if (s.at != s.text.len) return error.InvalidDatetimeFormat;
    }
    if (hour > 24 or minute > 59 or second > 60 or (hour == 24 and (minute != 0 or second != 0 or micros != 0)))
        return error.DatetimeFieldOverflow;
    out.us = ((hour * 60 + minute) * 60 + second) * usecs_per_second + micros;
    if (!validTime(out.us)) return error.DatetimeFieldOverflow;
    return out;
}

/// AdjustTimeForTypmod: precision 0..5 rounds half up; 6 or -1 keep.
pub fn round(us: i64, precision: i32) i64 {
    if (precision < 0 or precision >= 6) return us;
    var scale: i64 = 1;
    for (0..@intCast(6 - precision)) |_| scale *= 10;
    return @divTrunc(us + @divTrunc(scale, 2), scale) * scale;
}

/// Seconds west of UTC that `zone` has at local time `local_us`
/// (PostgreSQL epoch, DetermineTimeZoneOffset).
pub fn zoneWest(zone: *const temporal.Zone, local_us: i64) Error!i32 {
    const utc = try temporal.toUtc(zone, local_us);
    const east = @divFloor(local_us - utc, usecs_per_second);
    if (!validZone(east)) return error.DatetimeFieldOverflow;
    return @intCast(-east);
}

// ---- output ----------------------------------------------------------------

fn put(buffer: []u8, at: *usize, byte: u8) void {
    buffer[at.*] = byte;
    at.* += 1;
}

fn two(buffer: []u8, at: *usize, value: i64) void {
    put(buffer, at, @intCast('0' + @divTrunc(value, 10)));
    put(buffer, at, @intCast('0' + @mod(value, 10)));
}

fn writeTime(us: i64, buffer: []u8, at: *usize) void {
    two(buffer, at, @divTrunc(us, temporal.usecs_per_hour));
    put(buffer, at, ':');
    two(buffer, at, @divTrunc(@mod(us, temporal.usecs_per_hour), temporal.usecs_per_minute));
    put(buffer, at, ':');
    two(buffer, at, @divTrunc(@mod(us, temporal.usecs_per_minute), usecs_per_second));
    var micros = @mod(us, usecs_per_second);
    if (micros == 0) return;
    put(buffer, at, '.');
    var digits: usize = 6;
    while (@mod(micros, 10) == 0) {
        micros = @divTrunc(micros, 10);
        digits -= 1;
    }
    var index = digits;
    while (index > 0) {
        index -= 1;
        buffer[at.* + index] = @intCast('0' + @mod(micros, 10));
        micros = @divTrunc(micros, 10);
    }
    at.* += digits;
}

/// `HH:MM:SS[.ffffff]` (trailing fraction zeros dropped) into `buffer`.
pub fn format(us: i64, buffer: []u8) []const u8 {
    var at: usize = 0;
    writeTime(us, buffer, &at);
    return buffer[0..at];
}

/// TIMETZ output: the time, then `+HH`, `+HH:MM` or `+HH:MM:SS`.
pub fn formatTz(value: TimeTz, buffer: []u8) []const u8 {
    var at: usize = 0;
    writeTime(value.us, buffer, &at);
    const east: i64 = -@as(i64, value.zone);
    put(buffer, &at, if (east >= 0) '+' else '-');
    const magnitude: i64 = @intCast(@abs(east));
    two(buffer, &at, @divTrunc(magnitude, 3600));
    const minutes = @divTrunc(@mod(magnitude, 3600), 60);
    const seconds = @mod(magnitude, 60);
    if (minutes != 0 or seconds != 0) {
        put(buffer, &at, ':');
        two(buffer, &at, minutes);
        if (seconds != 0) {
            put(buffer, &at, ':');
            two(buffer, &at, seconds);
        }
    }
    return buffer[0..at];
}

// ---- operators ---------------------------------------------------------------

/// time + interval / time - interval (the interval's day and month parts
/// are ignored; the result wraps around midnight).
pub fn plus(us: i64, span: temporal.Interval, negative: bool) i64 {
    const delta = @mod(span.us, usecs_per_day);
    const moved = if (negative) us - delta else us + delta;
    return @mod(moved, usecs_per_day);
}

/// interval_time: the interval's time part modulo one day.
pub fn fromInterval(span: temporal.Interval) i64 {
    return @mod(span.us, usecs_per_day);
}

/// The time of day of a finite timestamp (local microseconds).
pub fn ofTimestamp(us: i64) i64 {
    return @mod(us, usecs_per_day);
}

/// date + time: a TIMESTAMP (infinite dates stay infinite; 22008 beyond
/// the timestamp range).
pub fn dateTime(days: i32, us: i64) Error!i64 {
    if (days == temporal.date_no_begin) return temporal.timestamp_no_begin;
    if (days == temporal.date_no_end) return temporal.timestamp_no_end;
    const base = try temporal.dateToTimestamp(days);
    const sum = @addWithOverflow(base, us);
    if (sum[1] != 0 or !temporal.validTimestamp(sum[0])) return error.DatetimeFieldOverflow;
    return sum[0];
}
