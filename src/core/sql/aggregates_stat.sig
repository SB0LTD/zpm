//! Statistical, bitwise and interval aggregate kernels (Layer 0, B11),
//! following PostgreSQL 18: float8_accum / float8_regr_accum (Youngs-Cramer
//! with their overflow and NaN rules) and the float8_* final functions;
//! numeric_stddev_internal for integer and numeric inputs (exact sums, then
//! select_div_scale division and a square root at that scale); and
//! interval_div for AVG(interval). States live in exec.sig's accumulators.
const types = @import("types.sig");
const numeric = @import("numeric.sig");
const numeric_math = @import("numeric_math.sig");
const temporal = @import("temporal.sig");
const float_text = @import("float_text.sig");
const Error = types.Error;
const Numeric = numeric.Numeric;

fn isInf(x: f64) bool {
    return float_text.isInf(x);
}

fn nan() f64 {
    return float_text.nan(f64);
}

/// float8_accum: `previous` inputs were already counted.
pub fn accumulateOne(previous: i64, x: f64, sx: *f64, sxx: *f64) Error!void {
    const n: f64 = @floatFromInt(previous + 1);
    const old_sx = sx.*;
    sx.* += x;
    if (previous > 0) {
        const tmp = x * n - sx.*;
        sxx.* += tmp * tmp / (n * @as(f64, @floatFromInt(previous)));
        if (isInf(sx.*) or isInf(sxx.*)) {
            if (!isInf(old_sx) and !isInf(x)) return error.NumericValueOutOfRange;
            sxx.* = nan();
        }
    } else if (x != x or isInf(x)) sxx.* = nan();
}

pub const Pair = struct { sx: *f64, sxx: *f64, sy: *f64, syy: *f64, sxy: *f64 };

/// float8_regr_accum(Y, X).
pub fn accumulatePair(previous: i64, y: f64, x: f64, s: Pair) Error!void {
    const n: f64 = @floatFromInt(previous + 1);
    const old_sx = s.sx.*;
    const old_sy = s.sy.*;
    s.sx.* += x;
    s.sy.* += y;
    if (previous > 0) {
        const tmp_x = x * n - s.sx.*;
        const tmp_y = y * n - s.sy.*;
        const scale = 1.0 / (n * @as(f64, @floatFromInt(previous)));
        s.sxx.* += tmp_x * tmp_x * scale;
        s.syy.* += tmp_y * tmp_y * scale;
        s.sxy.* += tmp_x * tmp_y * scale;
        if (isInf(s.sx.*) or isInf(s.sxx.*) or isInf(s.sy.*) or isInf(s.syy.*) or isInf(s.sxy.*)) {
            if (((isInf(s.sx.*) or isInf(s.sxx.*)) and !isInf(old_sx) and !isInf(x)) or
                ((isInf(s.sy.*) or isInf(s.syy.*)) and !isInf(old_sy) and !isInf(y)) or
                (isInf(s.sxy.*) and !isInf(old_sx) and !isInf(x) and !isInf(old_sy) and !isInf(y)))
                return error.NumericValueOutOfRange;
            if (isInf(s.sxx.*)) s.sxx.* = nan();
            if (isInf(s.syy.*)) s.syy.* = nan();
            if (isInf(s.sxy.*)) s.sxy.* = nan();
        }
    } else {
        if (x != x or isInf(x)) {
            s.sxx.* = nan();
            s.sxy.* = nan();
        }
        if (y != y or isInf(y)) {
            s.syy.* = nan();
            s.sxy.* = nan();
        }
    }
}

pub const Variance = enum { var_pop, var_samp, stddev_pop, stddev_samp };

/// float8_var_pop / var_samp / stddev_pop / stddev_samp.
pub fn varianceFloat(kind: Variance, count: i64, sxx: f64) ?f64 {
    const n: f64 = @floatFromInt(count);
    const sample = kind == .var_samp or kind == .stddev_samp;
    if (sample and n <= 1.0) return null;
    if (!sample and n == 0.0) return null;
    const value = sxx / (if (sample) n - 1.0 else n);
    return if (kind == .stddev_pop or kind == .stddev_samp) @sqrt(value) else value;
}

pub const Regression = enum { corr, covar_pop, covar_samp, regr_sxx, regr_syy, regr_sxy, regr_avgx, regr_avgy, regr_slope, regr_intercept, regr_r2 };

/// The float8 regression final functions.
pub fn regression(kind: Regression, count: i64, sx: f64, sxx: f64, sy: f64, syy: f64, sxy: f64) ?f64 {
    const n: f64 = @floatFromInt(count);
    if (kind == .covar_samp) return if (n < 2.0) null else sxy / (n - 1.0);
    if (n < 1.0) return null;
    return switch (kind) {
        .corr => if (sxx == 0 or syy == 0) null else sxy / @sqrt(sxx * syy),
        .covar_pop => sxy / n,
        .regr_sxx => sxx,
        .regr_syy => syy,
        .regr_sxy => sxy,
        .regr_avgx => sx / n,
        .regr_avgy => sy / n,
        .regr_slope => if (sxx == 0) null else sxy / sxx,
        .regr_intercept => if (sxx == 0) null else (sy - sx * sxy / sxx) / n,
        .regr_r2 => if (sxx == 0) null else if (syy == 0) 1.0 else (sxy * sxy) / (sxx * syy),
        .covar_samp => unreachable,
    };
}

/// numeric_stddev_internal over exact sums of x and x*x.
pub fn varianceNumeric(comptime digits: usize, kind: Variance, count: i64, sum: *const Numeric, square: *const Numeric, special: bool) Error!?Numeric {
    const N = numeric.Ops(digits);
    const M = numeric_math.Math(digits);
    const sample = kind == .var_samp or kind == .stddev_samp;
    if (count == 0 or (sample and count <= 1)) return null;
    if (special) return numeric.nan();
    const n = N.fromInt(count);
    // rscale = 2 * dscale(sumX) keeps both products exact.
    const sum_squared = try N.mul(sum, sum);
    const scaled_square = try N.mul(&n, square);
    const numerator = try N.sub(&scaled_square, &sum_squared);
    if (numerator.isZero() or numerator.negative) return N.fromInt(0);
    const denominator = if (sample) try N.mul(&n, &N.fromInt(count - 1)) else try N.mul(&n, &n);
    const variance = try N.div(&numerator, &denominator);
    if (kind == .var_pop or kind == .var_samp) return variance;
    return try M.sqrtAt(&variance, variance.dscale);
}

/// interval_div(span, factor) for a finite span and factor > 0.
pub fn intervalDivide(span: temporal.Interval, factor: f64) Error!temporal.Interval {
    if (factor == 0) return error.DivisionByZero;
    if (factor != factor) return error.DatetimeFieldOverflow;
    const month_double = @as(f64, @floatFromInt(span.months)) / factor;
    if (month_double != month_double or month_double < -2147483648.0 or month_double >= 2147483648.0) return error.DatetimeFieldOverflow;
    const months: i32 = @intFromFloat(@trunc(month_double));
    const day_double = @as(f64, @floatFromInt(span.days)) / factor;
    if (day_double != day_double or day_double < -2147483648.0 or day_double >= 2147483648.0) return error.DatetimeFieldOverflow;
    var days: i64 = @intFromFloat(@trunc(day_double));
    var month_remainder_days = (@as(f64, @floatFromInt(span.months)) / factor - @as(f64, @floatFromInt(months))) * 30.0;
    month_remainder_days = tsRound(month_remainder_days);
    const whole_remainder: i64 = @intFromFloat(@trunc(month_remainder_days));
    var sec_remainder = (@as(f64, @floatFromInt(span.days)) / factor - @as(f64, @floatFromInt(days)) + month_remainder_days - @as(f64, @floatFromInt(whole_remainder))) * 86400.0;
    sec_remainder = tsRound(sec_remainder);
    if (@abs(sec_remainder) >= 86400.0) {
        const carry: i64 = @intFromFloat(@trunc(sec_remainder / 86400.0));
        days += carry;
        if (days < -2147483648 or days > 2147483647) return error.DatetimeFieldOverflow;
        sec_remainder -= @as(f64, @floatFromInt(carry)) * 86400.0;
    }
    days += whole_remainder;
    if (days < -2147483648 or days > 2147483647) return error.DatetimeFieldOverflow;
    const time_double = float_text.rint(@as(f64, @floatFromInt(span.us)) / factor + sec_remainder * 1000000.0);
    if (time_double != time_double or time_double < -9223372036854775808.0 or time_double >= 9223372036854775808.0) return error.DatetimeFieldOverflow;
    return .{ .months = months, .days = @intCast(days), .us = @intFromFloat(time_double) };
}

/// interval_mul(span, factor) for a finite span (interval * double
/// precision). Infinite intervals are not representable (22008).
pub fn intervalMultiply(span: temporal.Interval, factor: f64) Error!temporal.Interval {
    if (factor != factor or isInf(factor)) return error.DatetimeFieldOverflow;
    const month_double = @as(f64, @floatFromInt(span.months)) * factor;
    if (month_double != month_double or month_double < -2147483648.0 or month_double >= 2147483648.0) return error.DatetimeFieldOverflow;
    const months: i32 = @intFromFloat(@trunc(month_double));
    const day_double = @as(f64, @floatFromInt(span.days)) * factor;
    if (day_double != day_double or day_double < -2147483648.0 or day_double >= 2147483648.0) return error.DatetimeFieldOverflow;
    var days: i64 = @intFromFloat(@trunc(day_double));
    var month_remainder_days = (@as(f64, @floatFromInt(span.months)) * factor - @as(f64, @floatFromInt(months))) * 30.0;
    month_remainder_days = tsRound(month_remainder_days);
    const whole_remainder: i64 = @intFromFloat(@trunc(month_remainder_days));
    var sec_remainder = (@as(f64, @floatFromInt(span.days)) * factor - @as(f64, @floatFromInt(days)) + month_remainder_days - @as(f64, @floatFromInt(whole_remainder))) * 86400.0;
    sec_remainder = tsRound(sec_remainder);
    if (@abs(sec_remainder) >= 86400.0) {
        const carry: i64 = @intFromFloat(@trunc(sec_remainder / 86400.0));
        days += carry;
        if (days < -2147483648 or days > 2147483647) return error.DatetimeFieldOverflow;
        sec_remainder -= @as(f64, @floatFromInt(carry)) * 86400.0;
    }
    days += whole_remainder;
    if (days < -2147483648 or days > 2147483647) return error.DatetimeFieldOverflow;
    const time_double = float_text.rint(@as(f64, @floatFromInt(span.us)) * factor + sec_remainder * 1000000.0);
    if (time_double != time_double or time_double < -9223372036854775808.0 or time_double >= 9223372036854775808.0) return error.DatetimeFieldOverflow;
    return .{ .months = months, .days = @intCast(days), .us = @intFromFloat(time_double) };
}

/// TSROUND: round to 1e-6 (TS_PREC_INV 1000000.0).
fn tsRound(value: f64) f64 {
    return float_text.rint(value * 1000000.0) / 1000000.0;
}
