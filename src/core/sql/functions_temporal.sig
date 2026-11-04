//! PostgreSQL date/time functions (Layer 0, B11): EXTRACT/date_part field
//! decoding and values, date_trunc, age, justify_*, make_date and
//! make_timestamp, following timestamp.c/date.c of PostgreSQL 18.
//!
//! Units decode as DecodeUnits/DecodeSpecial do (lower-cased, tokens
//! compared on their first 10 characters). An unknown unit is 22023, a known
//! unit that does not apply to the type 0A000, an out-of-range result 22008.
//! Calendar arithmetic is proleptic Gregorian with astronomical years
//! (0 = 1 BC), as timestamp2tm reports them. Infinite intervals are not
//! representable here, so age() of an infinite timestamp is 22008 where
//! PostgreSQL 18 returns an infinite interval.
const types = @import("types.sig");
const temporal = @import("temporal.sig");
const float_text = @import("float_text.sig");
const Error = types.Error;

pub const Field = enum { microsecond, millisecond, second, minute, hour, day, week, month, quarter, year, decade, century, millennium, timezone, timezone_hour, timezone_minute, dow, doy, isodow, isoyear, julian, epoch, reserved, unknown };

/// The deltatktbl entries (DecodeUnits).
const unit_table = [_]struct { token: []const u8, field: Field }{
    .{ .token = "c", .field = .century },          .{ .token = "cent", .field = .century },         .{ .token = "centuries", .field = .century },
    .{ .token = "century", .field = .century },    .{ .token = "d", .field = .day },                .{ .token = "day", .field = .day },
    .{ .token = "days", .field = .day },           .{ .token = "dec", .field = .decade },           .{ .token = "decade", .field = .decade },
    .{ .token = "decades", .field = .decade },     .{ .token = "decs", .field = .decade },          .{ .token = "h", .field = .hour },
    .{ .token = "hour", .field = .hour },          .{ .token = "hours", .field = .hour },           .{ .token = "hr", .field = .hour },
    .{ .token = "hrs", .field = .hour },           .{ .token = "m", .field = .minute },             .{ .token = "microsecon", .field = .microsecond },
    .{ .token = "mil", .field = .millennium },     .{ .token = "millennia", .field = .millennium }, .{ .token = "millennium", .field = .millennium },
    .{ .token = "millisecon", .field = .millisecond }, .{ .token = "mils", .field = .millennium },  .{ .token = "min", .field = .minute },
    .{ .token = "mins", .field = .minute },        .{ .token = "minute", .field = .minute },        .{ .token = "minutes", .field = .minute },
    .{ .token = "mon", .field = .month },          .{ .token = "mons", .field = .month },           .{ .token = "month", .field = .month },
    .{ .token = "months", .field = .month },       .{ .token = "ms", .field = .millisecond },       .{ .token = "msec", .field = .millisecond },
    .{ .token = "msecond", .field = .millisecond }, .{ .token = "mseconds", .field = .millisecond }, .{ .token = "msecs", .field = .millisecond },
    .{ .token = "qtr", .field = .quarter },        .{ .token = "quarter", .field = .quarter },      .{ .token = "s", .field = .second },
    .{ .token = "sec", .field = .second },         .{ .token = "second", .field = .second },        .{ .token = "seconds", .field = .second },
    .{ .token = "secs", .field = .second },        .{ .token = "timezone", .field = .timezone },    .{ .token = "timezone_h", .field = .timezone_hour },
    .{ .token = "timezone_m", .field = .timezone_minute }, .{ .token = "us", .field = .microsecond }, .{ .token = "usec", .field = .microsecond },
    .{ .token = "usecond", .field = .microsecond }, .{ .token = "useconds", .field = .microsecond }, .{ .token = "usecs", .field = .microsecond },
    .{ .token = "w", .field = .week },             .{ .token = "week", .field = .week },            .{ .token = "weeks", .field = .week },
    .{ .token = "y", .field = .year },             .{ .token = "year", .field = .year },            .{ .token = "years", .field = .year },
    .{ .token = "yr", .field = .year },            .{ .token = "yrs", .field = .year },
};

/// UNITS and RESERV entries of datetktbl (DecodeSpecial) beyond the above.
const special_table = [_]struct { token: []const u8, field: Field }{
    .{ .token = "dow", .field = .dow },        .{ .token = "doy", .field = .doy },          .{ .token = "epoch", .field = .epoch },
    .{ .token = "isodow", .field = .isodow },  .{ .token = "isoyear", .field = .isoyear },  .{ .token = "j", .field = .julian },
    .{ .token = "jd", .field = .julian },      .{ .token = "julian", .field = .julian },    .{ .token = "mm", .field = .minute },
    .{ .token = "+infinity", .field = .reserved }, .{ .token = "-infinity", .field = .reserved }, .{ .token = "infinity", .field = .reserved },
    .{ .token = "allballs", .field = .reserved }, .{ .token = "now", .field = .reserved }, .{ .token = "today", .field = .reserved },
    .{ .token = "tomorrow", .field = .reserved }, .{ .token = "yesterday", .field = .reserved },
};

fn lowerByte(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

/// strncmp(key, token, TOKMAXLEN) == 0 for the lower-cased key.
fn tokenMatch(key: []const u8, token: []const u8) bool {
    const compared = @min(key.len, 10);
    if (token.len < 10 and key.len != token.len) return false;
    if (token.len == 10 and key.len < 10) return false;
    for (key[0..compared], token[0..compared]) |a, b| if (lowerByte(a) != b) return false;
    return true;
}

/// DecodeUnits, then DecodeSpecial when `special` (EXTRACT/date_part).
pub fn decodeField(raw: []const u8, special: bool) Field {
    const key = raw[0..@min(raw.len, 63)];
    for (unit_table) |entry| if (tokenMatch(key, entry.token)) return entry.field;
    if (special) for (special_table) |entry| if (tokenMatch(key, entry.token)) return entry.field;
    return .unknown;
}

/// A part value: an integer, an exact decimal (value / 10^scale), a double,
/// an infinity or NULL.
pub const Part = union(enum) {
    integer: i64,
    decimal: struct { value: i128, scale: u8 },
    /// Julian day number plus a fraction time_us / 86400000000.
    julian: struct { day: i64, time: i64 },
    float: f64,
    infinity: bool,
    none: void,
};

pub const julian_epoch: i64 = 2451545;

pub fn julian(days: i64) i64 {
    return days + julian_epoch;
}

/// j2day: 0 = Sunday.
pub fn weekday(j: i64) i64 {
    return @mod(j + 1, 7);
}

fn date2j(year: i64, month: i64, day: i64) i64 {
    return temporal.dateOf(year, month, day) + julian_epoch;
}

/// date2isoweek.
pub fn isoWeek(year: i64, month: i64, day: i64) i64 {
    const dayn = date2j(year, month, day);
    var day4 = date2j(year, 1, 4);
    var day0 = weekday(day4 - 1);
    if (dayn < day4 - day0) {
        day4 = date2j(year - 1, 1, 4);
        day0 = weekday(day4 - 1);
    }
    var result = @divTrunc(dayn - (day4 - day0), 7) + 1;
    if (result >= 52) {
        day4 = date2j(year + 1, 1, 4);
        day0 = weekday(day4 - 1);
        if (dayn >= day4 - day0) result = @divTrunc(dayn - (day4 - day0), 7) + 1;
    }
    return result;
}

/// date2isoyear.
pub fn isoYear(year_in: i64, month: i64, day: i64) i64 {
    var year = year_in;
    const dayn = date2j(year, month, day);
    var day4 = date2j(year, 1, 4);
    var day0 = weekday(day4 - 1);
    if (dayn < day4 - day0) {
        day4 = date2j(year - 1, 1, 4);
        day0 = weekday(day4 - 1);
        year -= 1;
    }
    const result = @divTrunc(dayn - (day4 - day0), 7) + 1;
    if (result >= 52) {
        day4 = date2j(year + 1, 1, 4);
        day0 = weekday(day4 - 1);
        if (dayn >= day4 - day0) year += 1;
    }
    return year;
}

/// The broken-down local time of a finite timestamp (timestamp2tm).
pub const Tm = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    usec: i64,

    pub fn of(us: i64) Tm {
        const days = @divFloor(us, temporal.usecs_per_day);
        var time = us - days * temporal.usecs_per_day;
        const civil = temporal.civilOf(days);
        const hour = @divTrunc(time, temporal.usecs_per_hour);
        time -= hour * temporal.usecs_per_hour;
        const minute = @divTrunc(time, temporal.usecs_per_minute);
        time -= minute * temporal.usecs_per_minute;
        const second = @divTrunc(time, temporal.usecs_per_second);
        return .{ .year = civil.year, .month = civil.month, .day = civil.day, .hour = hour, .minute = minute, .second = second, .usec = time - second * temporal.usecs_per_second };
    }

    /// tm2timestamp with range checks (22008).
    pub fn timestamp(self: Tm) Error!i64 {
        if (self.year < -4713 or self.year > 294277) return error.DatetimeFieldOverflow;
        const days = temporal.dateOf(self.year, self.month, self.day);
        const time = ((self.hour * 60 + self.minute) * 60 + self.second) * temporal.usecs_per_second + self.usec;
        const value = @mulWithOverflow(days, temporal.usecs_per_day);
        if (value[1] != 0) return error.DatetimeFieldOverflow;
        const total = @addWithOverflow(value[0], time);
        if (total[1] != 0 or !temporal.validTimestamp(total[0])) return error.DatetimeFieldOverflow;
        return total[0];
    }
};

fn yearPart(field: Field, year: i64) i64 {
    return switch (field) {
        .year => if (year > 0) year else year - 1,
        .decade => if (year >= 0) @divTrunc(year, 10) else -@divTrunc(8 - (year - 1), 10),
        .century => if (year > 0) @divTrunc(year + 99, 100) else -@divTrunc(99 - (year - 1), 100),
        .millennium => if (year > 0) @divTrunc(year + 999, 1000) else -@divTrunc(999 - (year - 1), 1000),
        else => unreachable,
    };
}

fn dateFields(field: Field, year: i64, month: i64, day: i64) ?i64 {
    return switch (field) {
        .day => day,
        .month => month,
        .quarter => @divTrunc(month - 1, 3) + 1,
        .week => isoWeek(year, month, day),
        .year, .decade, .century, .millennium => yearPart(field, year),
        .isoyear => blk: {
            const iso = isoYear(year, month, day);
            break :blk if (iso <= 0) iso - 1 else iso;
        },
        .dow, .isodow => blk: {
            const dow = weekday(date2j(year, month, day));
            break :blk if (field == .isodow and dow == 0) 7 else dow;
        },
        .doy => date2j(year, month, day) - date2j(year, 1, 1) + 1,
        else => null,
    };
}

fn unsupportedOrUnknown(field: Field) Error {
    return if (field == .unknown) error.InvalidParameterValue else error.UnsupportedStatement;
}

/// extract(field FROM date) (extract_date): integer numeric results.
pub fn datePart(field: Field, days: i32) Error!Part {
    if (!temporal.finiteDate(days)) {
        return switch (field) {
            .day, .month, .quarter, .week, .dow, .isodow, .doy => .none,
            .year, .decade, .century, .millennium, .julian, .isoyear, .epoch => .{ .infinity = days == temporal.date_no_end },
            else => unsupportedOrUnknown(field),
        };
    }
    const civil = temporal.civilOf(days);
    if (field == .julian) return .{ .integer = julian(days) };
    if (field == .epoch) return .{ .integer = (@as(i64, days) + temporal.unix_epoch_days) * 86400 };
    if (dateFields(field, civil.year, civil.month, civil.day)) |value| return .{ .integer = value };
    return unsupportedOrUnknown(field);
}

/// timestamp[tz] parts (timestamp_part_common / timestamptz_part_common).
/// `offset` is seconds east of UTC for timestamptz (null for timestamp);
/// `us` is then already local time. `numeric` selects EXTRACT's results.
pub fn timestampPart(field: Field, us: i64, epoch_us: i128, offset: ?i64, numeric: bool) Error!Part {
    if (!temporal.finiteTimestamp(us)) {
        return switch (field) {
            .microsecond, .millisecond, .second, .minute, .hour, .day, .month, .quarter, .week, .dow, .isodow, .doy => .none,
            .timezone, .timezone_hour, .timezone_minute => if (offset != null) .none else error.UnsupportedStatement,
            .year, .decade, .century, .millennium, .julian, .isoyear, .epoch => if (numeric) .{ .infinity = us == temporal.timestamp_no_end } else .{ .float = if (us == temporal.timestamp_no_end) inf() else -inf() },
            else => unsupportedOrUnknown(field),
        };
    }
    const tm = Tm.of(us);
    const micro = tm.second * 1000000 + tm.usec;
    switch (field) {
        .microsecond => return .{ .integer = micro },
        .millisecond => return if (numeric) .{ .decimal = .{ .value = micro, .scale = 3 } } else .{ .float = @as(f64, @floatFromInt(tm.second)) * 1000.0 + @as(f64, @floatFromInt(tm.usec)) / 1000.0 },
        .second => return if (numeric) .{ .decimal = .{ .value = micro, .scale = 6 } } else .{ .float = @as(f64, @floatFromInt(tm.second)) + @as(f64, @floatFromInt(tm.usec)) / 1000000.0 },
        .minute => return .{ .integer = tm.minute },
        .hour => return .{ .integer = tm.hour },
        .julian => {
            const day_number = date2j(tm.year, tm.month, tm.day);
            const time = ((tm.hour * 60 + tm.minute) * 60 + tm.second) * 1000000 + tm.usec;
            // Numeric: date2j + time/86400000000 (numeric division scale);
            // the evaluator builds it from integer and fraction.
            if (numeric) return .{ .julian = .{ .day = day_number, .time = time } };
            return .{ .float = @as(f64, @floatFromInt(day_number)) + @as(f64, @floatFromInt(time)) / 1000000.0 / 86400.0 };
        },
        .timezone, .timezone_hour, .timezone_minute => {
            const east = offset orelse return error.UnsupportedStatement;
            return .{ .integer = switch (field) {
                .timezone => east,
                .timezone_hour => @divTrunc(east, 3600),
                else => @rem(@divTrunc(east, 60), 60),
            } };
        },
        .epoch => {
            const delta = epoch_us;
            return if (numeric) .{ .decimal = .{ .value = delta, .scale = 6 } } else .{ .float = @as(f64, @floatFromInt(delta)) / 1000000.0 };
        },
        .reserved, .unknown => return unsupportedOrUnknown(field),
        else => {},
    }
    if (dateFields(field, tm.year, tm.month, tm.day)) |value| return .{ .integer = value };
    return error.UnsupportedStatement;
}

fn inf() f64 {
    return @bitCast(@as(u64, 0x7ff0000000000000));
}

/// interval2itm.
const Itm = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, usec: i64 };

fn itmOf(value: temporal.Interval) Itm {
    var time = value.us;
    const hour = @divTrunc(time, temporal.usecs_per_hour);
    time -= hour * temporal.usecs_per_hour;
    const minute = @divTrunc(time, temporal.usecs_per_minute);
    time -= minute * temporal.usecs_per_minute;
    const second = @divTrunc(time, temporal.usecs_per_second);
    return .{ .year = @divTrunc(@as(i64, value.months), 12), .month = @rem(@as(i64, value.months), 12), .day = value.days, .hour = hour, .minute = minute, .second = second, .usec = time - second * temporal.usecs_per_second };
}

/// itm2interval (22008 when a field does not fit).
fn intervalOf(tm: Itm) Error!temporal.Interval {
    const months = tm.year * 12 + tm.month;
    if (months < -2147483648 or months > 2147483647 or tm.day < -2147483648 or tm.day > 2147483647) return error.DatetimeFieldOverflow;
    const hours = @mulWithOverflow(tm.hour, temporal.usecs_per_hour);
    if (hours[1] != 0) return error.DatetimeFieldOverflow;
    const rest = (tm.minute * 60 + tm.second) * temporal.usecs_per_second + tm.usec;
    const time = @addWithOverflow(hours[0], rest);
    if (time[1] != 0) return error.DatetimeFieldOverflow;
    return .{ .months = @intCast(months), .days = @intCast(tm.day), .us = time[0] };
}

/// interval_part_common.
pub fn intervalPart(field: Field, value: temporal.Interval, numeric: bool) Error!Part {
    const tm = itmOf(value);
    const micro = tm.second * 1000000 + tm.usec;
    return switch (field) {
        .microsecond => .{ .integer = micro },
        .millisecond => if (numeric) .{ .decimal = .{ .value = micro, .scale = 3 } } else .{ .float = @as(f64, @floatFromInt(tm.second)) * 1000.0 + @as(f64, @floatFromInt(tm.usec)) / 1000.0 },
        .second => if (numeric) .{ .decimal = .{ .value = micro, .scale = 6 } } else .{ .float = @as(f64, @floatFromInt(tm.second)) + @as(f64, @floatFromInt(tm.usec)) / 1000000.0 },
        .minute => .{ .integer = tm.minute },
        .hour => .{ .integer = tm.hour },
        .day => .{ .integer = tm.day },
        .week => .{ .integer = @divTrunc(tm.day, 7) },
        .month => .{ .integer = tm.month },
        .quarter => .{ .integer = if (value.months >= 0) @divTrunc(tm.month, 3) + 1 else -(@divTrunc(@rem(-@as(i64, value.months), 12), 3) + 1) },
        .year => .{ .integer = tm.year },
        .decade => .{ .integer = @divTrunc(tm.year, 10) },
        .century => .{ .integer = @divTrunc(tm.year, 100) },
        .millennium => .{ .integer = @divTrunc(tm.year, 1000) },
        .epoch => blk: {
            const months: i64 = value.months;
            const seconds = (@as(i64, 4 * 365 + 1) * @divTrunc(months, 12) + 4 * 30 * @rem(months, 12) + 4 * @as(i64, value.days)) * (86400 / 4);
            if (numeric) {
                const scaled = @mulWithOverflow(seconds, 1000000);
                if (scaled[1] == 0) {
                    const total = @addWithOverflow(scaled[0], value.us);
                    if (total[1] == 0) break :blk .{ .decimal = .{ .value = total[0], .scale = 6 } };
                }
                return error.DatetimeFieldOverflow;
            }
            var result = @as(f64, @floatFromInt(value.us)) / 1000000.0;
            result += (365.25 * 86400.0) * @as(f64, @floatFromInt(@divTrunc(months, 12)));
            result += (30.0 * 86400.0) * @as(f64, @floatFromInt(@rem(months, 12)));
            result += 86400.0 * @as(f64, @floatFromInt(value.days));
            break :blk .{ .float = result };
        },
        .unknown => error.InvalidParameterValue,
        else => error.UnsupportedStatement,
    };
}

/// date_trunc on local fields (timestamp_trunc / timestamptz_trunc_internal).
/// Returns the truncated local time; `whole_days` reports units of a day or
/// more, which re-resolve the zone offset for timestamptz.
pub fn truncate(field: Field, us: i64, whole_days: *bool) Error!i64 {
    var tm = Tm.of(us);
    whole_days.* = false;
    switch (field) {
        .week => {
            const week = isoWeek(tm.year, tm.month, tm.day);
            var year = tm.year;
            if (week >= 52 and tm.month == 1) year -= 1;
            if (week <= 1 and tm.month == 12) year += 1;
            const day4 = date2j(year, 1, 4);
            const start = (week - 1) * 7 + (day4 - weekday(day4 - 1));
            const civil = temporal.civilOf(start - julian_epoch);
            tm = .{ .year = civil.year, .month = civil.month, .day = civil.day, .hour = 0, .minute = 0, .second = 0, .usec = 0 };
            whole_days.* = true;
        },
        .millennium, .century, .decade, .year, .quarter, .month, .day => {
            if (field == .millennium) tm.year = if (tm.year > 0) @divTrunc(tm.year + 999, 1000) * 1000 - 999 else -@divTrunc(999 - (tm.year - 1), 1000) * 1000 + 1;
            if (field == .millennium or field == .century) tm.year = if (tm.year > 0) @divTrunc(tm.year + 99, 100) * 100 - 99 else -@divTrunc(99 - (tm.year - 1), 100) * 100 + 1;
            if (field == .decade) tm.year = if (tm.year > 0) @divTrunc(tm.year, 10) * 10 else -@divTrunc(8 - (tm.year - 1), 10) * 10;
            if (field != .quarter and field != .month and field != .day) tm.month = 1;
            if (field != .month and field != .day) tm.month = 3 * @divTrunc(tm.month - 1, 3) + 1;
            if (field != .day) tm.day = 1;
            tm.hour = 0;
            tm.minute = 0;
            tm.second = 0;
            tm.usec = 0;
            whole_days.* = true;
        },
        .hour => {
            tm.minute = 0;
            tm.second = 0;
            tm.usec = 0;
        },
        .minute => {
            tm.second = 0;
            tm.usec = 0;
        },
        .second => tm.usec = 0,
        .millisecond => tm.usec = @divTrunc(tm.usec, 1000) * 1000,
        .microsecond => {},
        .unknown, .dow, .doy, .isodow, .isoyear, .julian, .epoch, .reserved => return error.InvalidParameterValue,
        else => return error.UnsupportedStatement,
    }
    return tm.timestamp();
}

/// interval_trunc.
pub fn truncateInterval(field: Field, value: temporal.Interval) Error!temporal.Interval {
    var tm = itmOf(value);
    switch (field) {
        .millennium, .century, .decade, .year, .quarter, .month, .day, .hour, .minute, .second => {
            if (field == .millennium) tm.year = @divTrunc(tm.year, 1000) * 1000;
            if (field == .millennium or field == .century) tm.year = @divTrunc(tm.year, 100) * 100;
            if (field == .millennium or field == .century or field == .decade) tm.year = @divTrunc(tm.year, 10) * 10;
            const rank: u8 = switch (field) {
                .millennium, .century, .decade, .year => 0,
                .quarter => 1,
                .month => 2,
                .day => 3,
                .hour => 4,
                .minute => 5,
                else => 6,
            };
            if (rank == 0) tm.month = 0;
            if (rank <= 1) tm.month = 3 * @divTrunc(tm.month, 3);
            if (rank <= 2) tm.day = 0;
            if (rank <= 3) tm.hour = 0;
            if (rank <= 4) tm.minute = 0;
            if (rank <= 5) tm.second = 0;
            tm.usec = 0;
        },
        .millisecond => tm.usec = @divTrunc(tm.usec, 1000) * 1000,
        .microsecond => {},
        .unknown, .dow, .doy, .isodow, .isoyear, .julian, .epoch, .reserved => return error.InvalidParameterValue,
        else => return error.UnsupportedStatement,
    }
    return intervalOf(tm);
}

fn leapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn monthDays(year: i64, month: i64) i64 {
    const lengths = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return lengths[@intCast(month - 1)] + @as(i64, if (month == 2 and leapYear(year)) 1 else 0);
}

/// timestamp_age on local times: the symbolic year/month/day difference.
pub fn age(a: i64, b: i64) Error!temporal.Interval {
    if (!temporal.finiteTimestamp(a) or !temporal.finiteTimestamp(b)) return error.DatetimeFieldOverflow;
    const t1 = Tm.of(a);
    const t2 = Tm.of(b);
    var tm: Itm = .{ .usec = t1.usec - t2.usec, .second = t1.second - t2.second, .minute = t1.minute - t2.minute, .hour = t1.hour - t2.hour, .day = t1.day - t2.day, .month = t1.month - t2.month, .year = t1.year - t2.year };
    const flip = a < b;
    if (flip) tm = negate(tm);
    while (tm.usec < 0) {
        tm.usec += 1000000;
        tm.second -= 1;
    }
    while (tm.second < 0) {
        tm.second += 60;
        tm.minute -= 1;
    }
    while (tm.minute < 0) {
        tm.minute += 60;
        tm.hour -= 1;
    }
    while (tm.hour < 0) {
        tm.hour += 24;
        tm.day -= 1;
    }
    while (tm.day < 0) {
        tm.day += if (flip) monthDays(t1.year, t1.month) else monthDays(t2.year, t2.month);
        tm.month -= 1;
    }
    while (tm.month < 0) {
        tm.month += 12;
        tm.year -= 1;
    }
    if (flip) tm = negate(tm);
    return intervalOf(tm);
}

fn negate(tm: Itm) Itm {
    return .{ .year = -tm.year, .month = -tm.month, .day = -tm.day, .hour = -tm.hour, .minute = -tm.minute, .second = -tm.second, .usec = -tm.usec };
}

fn addMonths(months: i32, extra: i64) Error!i32 {
    const total = @as(i64, months) + extra;
    if (total < -2147483648 or total > 2147483647) return error.DatetimeFieldOverflow;
    return @intCast(total);
}

/// justify_days: 30-day months.
pub fn justifyDays(value: temporal.Interval) Error!temporal.Interval {
    var out = value;
    const whole: i32 = @divTrunc(out.days, 30);
    out.days -= whole * 30;
    out.months = try addMonths(out.months, whole);
    if (out.months > 0 and out.days < 0) {
        out.days += 30;
        out.months -= 1;
    } else if (out.months < 0 and out.days > 0) {
        out.days -= 30;
        out.months += 1;
    }
    return out;
}

/// justify_hours: 24-hour days.
pub fn justifyHours(value: temporal.Interval) Error!temporal.Interval {
    var out = value;
    const whole = @divTrunc(out.us, temporal.usecs_per_day);
    out.us -= whole * temporal.usecs_per_day;
    const days = @as(i64, out.days) + whole;
    if (days < -2147483648 or days > 2147483647) return error.DatetimeFieldOverflow;
    out.days = @intCast(days);
    if (out.days > 0 and out.us < 0) {
        out.us += temporal.usecs_per_day;
        out.days -= 1;
    } else if (out.days < 0 and out.us > 0) {
        out.us -= temporal.usecs_per_day;
        out.days += 1;
    }
    return out;
}

/// justify_interval.
pub fn justifyInterval(value: temporal.Interval) Error!temporal.Interval {
    var out = value;
    if ((out.days > 0 and out.us > 0) or (out.days < 0 and out.us < 0)) {
        const whole: i32 = @divTrunc(out.days, 30);
        out.days -= whole * 30;
        out.months = try addMonths(out.months, whole);
    }
    const whole_days = @divTrunc(out.us, temporal.usecs_per_day);
    out.us -= whole_days * temporal.usecs_per_day;
    var days = @as(i64, out.days) + whole_days;
    const whole_months = @divTrunc(days, 30);
    days -= whole_months * 30;
    out.months = try addMonths(out.months, whole_months);
    out.days = @intCast(days);
    if (out.months > 0 and (out.days < 0 or (out.days == 0 and out.us < 0))) {
        out.days += 30;
        out.months -= 1;
    } else if (out.months < 0 and (out.days > 0 or (out.days == 0 and out.us > 0))) {
        out.days -= 30;
        out.months += 1;
    }
    if (out.days > 0 and out.us < 0) {
        out.us += temporal.usecs_per_day;
        out.days -= 1;
    } else if (out.days < 0 and out.us > 0) {
        out.us -= temporal.usecs_per_day;
        out.days += 1;
    }
    return out;
}

/// make_date: negative years are BC; ValidateDate failures are 22008.
pub fn makeDate(year_in: i64, month: i64, day: i64) Error!i32 {
    if (year_in == 0 or month < 1 or month > 12 or day < 1) return error.DatetimeFieldOverflow;
    // BC year n is astronomical year 1 - n.
    const year = if (year_in < 0) year_in + 1 else year_in;
    if (day > monthDays(year, month)) return error.DatetimeFieldOverflow;
    if (year < -4713 or year > 5874897) return error.DatetimeFieldOverflow;
    const days = temporal.dateOf(year, month, day);
    if (!temporal.validDate(days)) return error.DatetimeFieldOverflow;
    return @intCast(days);
}

/// make_timestamp (seconds as double precision, rounded to microseconds).
pub fn makeTimestamp(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: f64) Error!i64 {
    const days = try makeDate(year, month, day);
    // float_time_overflows: 0 <= hour <= 24, 0 <= min < 60, 0 <= sec <= 60,
    // and at most 24:00:00 in total.
    if (hour < 0 or hour > 24 or minute < 0 or minute > 59 or !(second >= 0) or second > 60) return error.DatetimeFieldOverflow;
    const micros = float_text.rint(second * 1000000.0);
    const time = (hour * 60 + minute) * 60 * temporal.usecs_per_second + @as(i64, @intFromFloat(micros));
    if (time > temporal.usecs_per_day) return error.DatetimeFieldOverflow;
    const total = @as(i64, days) * temporal.usecs_per_day + time;
    if (!temporal.validTimestamp(total)) return error.DatetimeFieldOverflow;
    return total;
}
