// Time / calendar formatting — Unix epoch (seconds) → human-readable ASCII
// Layer 0: Core — pure math, no I/O, no platform imports
//
// Reusable across any module that renders timestamps: chart axes, logs,
// tooltips. All functions take a Unix timestamp in SECONDS and write ASCII
// into a caller-provided buffer, returning the number of bytes written.
//
// The date decomposition uses Howard Hinnant's civil-from-days algorithm,
// valid for the full proleptic Gregorian range.

/// Broken-down calendar fields for a Unix timestamp (UTC).
pub const Calendar = struct {
    year: i64 = 1970,
    month: u8 = 1, // 1..12
    day: u8 = 1, // 1..31
    hour: u8 = 0, // 0..23
    minute: u8 = 0, // 0..59
    second: u8 = 0, // 0..59
};

const MONTH_NAMES = [_][3]u8{
    "Jan".*, "Feb".*, "Mar".*, "Apr".*, "May".*, "Jun".*,
    "Jul".*, "Aug".*, "Sep".*, "Oct".*, "Nov".*, "Dec".*,
};

/// Decompose a Unix timestamp (seconds, UTC) into calendar fields.
pub fn toCalendar(ts: i64) Calendar {
    const day_secs = @mod(ts, 86400);
    const days = @divTrunc(ts - day_secs, 86400); // floor division of days since epoch

    // civil_from_days (Hinnant): days since 1970-01-01 → y/m/d
    const z = days + 719468; // shift epoch to 0000-03-01
    const era: i64 = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp: i64 = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    const year: i64 = if (m <= 2) y + 1 else y;

    return .{
        .year = year,
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divTrunc(day_secs, 3600)),
        .minute = @intCast(@divTrunc(@mod(day_secs, 3600), 60)),
        .second = @intCast(@mod(day_secs, 60)),
    };
}

fn two(out: []u8, pos: usize, v: u8) usize {
    out[pos] = '0' + v / 10;
    out[pos + 1] = '0' + v % 10;
    return pos + 2;
}

/// "HH:MM" (5 bytes).
pub fn time(out: []u8, ts: i64) usize {
    if (out.len < 5) return 0;
    const c = toCalendar(ts);
    var p: usize = 0;
    p = two(out, p, c.hour);
    out[p] = ':';
    p += 1;
    p = two(out, p, c.minute);
    return p;
}

/// "DD Mon" (6 bytes), e.g. "07 Feb".
pub fn date(out: []u8, ts: i64) usize {
    if (out.len < 6) return 0;
    const c = toCalendar(ts);
    var p: usize = 0;
    p = two(out, p, c.day);
    out[p] = ' ';
    p += 1;
    const name = MONTH_NAMES[c.month - 1];
    out[p] = name[0];
    out[p + 1] = name[1];
    out[p + 2] = name[2];
    return p + 3;
}

/// "DD Mon HH:MM" (12 bytes).
pub fn dateTime(out: []u8, ts: i64) usize {
    if (out.len < 12) return 0;
    var p = date(out, ts);
    out[p] = ' ';
    p += 1;
    p += time(out[p..], ts);
    return p;
}

/// "DD Mon YYYY" (11 bytes), e.g. "07 Feb 2026".
pub fn dateYear(out: []u8, ts: i64) usize {
    if (out.len < 11) return 0;
    var p = date(out, ts);
    out[p] = ' ';
    p += 1;
    const c = toCalendar(ts);
    const y: u32 = @intCast(if (c.year < 0) 0 else c.year);
    out[p] = '0' + @as(u8, @intCast((y / 1000) % 10));
    out[p + 1] = '0' + @as(u8, @intCast((y / 100) % 10));
    out[p + 2] = '0' + @as(u8, @intCast((y / 10) % 10));
    out[p + 3] = '0' + @as(u8, @intCast(y % 10));
    return p + 4;
}

/// True when `ts` sits exactly on a UTC midnight (start of a day).
pub fn isDayStart(ts: i64) bool {
    return @mod(ts, 86400) == 0;
}

/// Timeframe-aware axis label. Picks the most useful representation for a tick:
///   - at a day boundary, or when the timeframe is >= 1 day → date ("DD Mon")
///   - otherwise → time ("HH:MM")
/// `period_secs` is the candle period (e.g. 900 for 15m, 86400 for 1d).
/// `force_date` requests the date form regardless (used for the first visible
/// label so the axis always shows at least one date for context).
pub fn axisLabel(out: []u8, ts: i64, period_secs: i64, force_date: bool) usize {
    if (force_date or period_secs >= 86400 or isDayStart(ts)) {
        return date(out, ts);
    }
    return time(out, ts);
}
