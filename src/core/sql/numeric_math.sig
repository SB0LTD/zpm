//! NUMERIC transcendental and integer-valued functions (Layer 0, B11):
//! ln, log, log10, exp, power, div, gcd, lcm, scale, min_scale and
//! trim_scale with PostgreSQL 18's result scales (numeric.c).
//!
//! Values are computed in caller-stack fixed point (i1024, `w` fractional
//! digits) with at least `guard` extra digits and rounded half away from
//! zero to PostgreSQL's rscale, so results are correctly rounded except when
//! the exact value lies within about 10^-(rscale+6) of a rounding boundary.
//! Results beyond Config.numeric_digits or numeric.max_scale are
//! NumericCapacity (54000), the existing NUMERIC capacity contract.
//! Series loops call the statement's execution checkpoint.
const std = @import("std");
const types = @import("types.sig");
const numeric = @import("numeric.sig");
const float_text = @import("float_text.sig");
const Error = types.Error;
const Numeric = numeric.Numeric;

pub const Control = ?*types.ExecutionControl;

fn tick(control: Control) Error!void {
    if (control) |active| try active.checkpoint();
}

const Big = i1024;
const guard: usize = 12;
/// Largest working precision (fixed-point products need 2w+2 digits).
const max_working: usize = 150;

const pow10_big = blk: {
    @setEvalBranchQuota(200000);
    var table: [308]Big = undefined;
    table[0] = 1;
    for (1..table.len) |index| table[index] = table[index - 1] * 10;
    break :blk table;
};

fn ten(power: usize) Error!Big {
    if (power >= pow10_big.len) return error.NumericCapacity;
    return pow10_big[power];
}

fn digitCount(value: Big) usize {
    var count: usize = 0;
    const magnitude = if (value < 0) -value else value;
    while (count < pow10_big.len and magnitude >= pow10_big[count]) count += 1;
    return count;
}

fn isqrt(value: Big) Big {
    if (value <= 0) return 0;
    const unsigned: u1024 = @intCast(value);
    return @intCast(std.math.sqrt(unsigned));
}

/// round(value / 10^drop), half away from zero.
fn roundDown(value: Big, drop: usize) Error!Big {
    if (drop == 0) return value;
    const unit = try ten(drop);
    const magnitude = if (value < 0) -value else value;
    var quotient = @divTrunc(magnitude, unit);
    if (@rem(magnitude, unit) * 2 >= unit) quotient += 1;
    return if (value < 0) -quotient else quotient;
}

pub fn Math(comptime digits: usize) type {
    const N = numeric.Ops(digits);
    return struct {
        /// A finite value from a signed coefficient at `scale` decimals.
        pub fn make(value: Big, scale: usize) Error!Numeric {
            if (scale > numeric.max_scale) return error.NumericCapacity;
            const magnitude = if (value < 0) -value else value;
            if (magnitude >= pow10_big[digits]) return error.NumericCapacity;
            var out: Numeric = .{ .dscale = @intCast(scale), .negative = value < 0 };
            out.setCoef(@intCast(magnitude));
            return out;
        }

        fn signed(value: *const Numeric) Big {
            const magnitude: Big = @intCast(value.coef());
            return if (value.negative) -magnitude else magnitude;
        }

        /// x as fixed point with `w` decimals (truncated toward zero).
        fn fixed(value: *const Numeric, w: usize) Error!Big {
            const raw = signed(value);
            if (w >= value.dscale) return raw * try ten(w - value.dscale);
            return @divTrunc(raw, try ten(value.dscale - w));
        }

        // ---- PostgreSQL's scale estimates --------------------------------

        /// Decimal exponent of the leading digit of a non-zero finite value.
        fn exponent(value: *const Numeric) i32 {
            return @as(i32, @intCast(numeric.digitCount(value.coef()))) - 1 - @as(i32, value.dscale);
        }

        /// numericvar_to_double_no_overflow: the decimal text through strtod.
        pub fn toDouble(value: *const Numeric) f64 {
            var buffer: [numeric.format_bytes]u8 = undefined;
            const text = N.format(value, &buffer);
            return float_text.parse(f64, text) catch 0;
        }

        /// estimate_ln_dweight over base-10000 digits.
        pub fn lnWeight(value: *const Numeric) Error!i32 {
            if (value.negative or value.isZero()) return 0;
            const one: Numeric = N.fromInt(1);
            const low: Numeric = .{ .limbs = .{ 9, 0, 0, 0 }, .dscale = 1 };
            const high: Numeric = .{ .limbs = .{ 11, 0, 0, 0 }, .dscale = 1 };
            if (numeric.compareValues(value, &low) >= 0 and numeric.compareValues(value, &high) <= 0) {
                const delta = try N.sub(value, &one);
                if (delta.isZero()) return 0;
                return exponent(&delta);
            }
            // First one or two base-10000 digits and the decimal weight.
            const groups = N.toBase10000(value);
            var leading: f64 = @floatFromInt(groups.digits[0]);
            var dweight: i32 = @as(i32, groups.weight) * 4;
            if (groups.ndigits > 1) {
                leading = leading * 10000 + @as(f64, @floatFromInt(groups.digits[1]));
                dweight -= 4;
            }
            const ln_value = @log(leading) + @as(f64, @floatFromInt(dweight)) * 2.302585092994046;
            const weight = @log10(@abs(ln_value));
            if (!(weight > -1000 and weight < 1000)) return 0;
            return @intFromFloat(@trunc(weight));
        }

        fn clampScale(scale: i64) i64 {
            return @min(@max(scale, 0), numeric.max_display_scale);
        }

        // ---- fixed-point kernels ----------------------------------------

        /// ln(m) for m = M / 10^w in [1, 10], by square-root reduction to
        /// below 1.1 and the atanh series 2(z + z^3/3 + ...).
        fn lnMantissa(start: Big, w: usize, control: Control) Error!Big {
            const one = try ten(w);
            var m = start;
            var halvings: u6 = 0;
            while (m * 10 > one * 11) : (halvings += 1) m = isqrt(m * one);
            const z = @divTrunc((m - one) * one, m + one);
            const z2 = @divTrunc(z * z, one);
            var term = z;
            var sum = z;
            var k: Big = 1;
            while (true) {
                try tick(control);
                term = @divTrunc(term * z2, one);
                k += 2;
                const part = @divTrunc(term, k);
                if (part == 0) break;
                sum += part;
            }
            return sum * 2 * (@as(Big, 1) << halvings);
        }

        /// ln(x) for finite x > 0 with `w` fractional digits.
        fn lnFixed(value: *const Numeric, w: usize, control: Control) Error!Big {
            const e = exponent(value);
            const leading_digits: usize = numeric.digitCount(value.coef());
            const raw: Big = @intCast(value.coef());
            const mantissa = if (leading_digits - 1 <= w) raw * try ten(w - (leading_digits - 1)) else @divTrunc(raw, try ten(leading_digits - 1 - w));
            var result = try lnMantissa(mantissa, w, control);
            if (e != 0) result += @as(Big, e) * try lnMantissa(10 * try ten(w), w, control);
            return result;
        }

        /// e^r for |r| <= 1.2 (fixed point, w decimals): halve 9 times,
        /// Taylor series, square back.
        fn expSmall(r: Big, w: usize, control: Control) Error!Big {
            const one = try ten(w);
            const halved = @divTrunc(r, 512);
            var term = one;
            var sum = one;
            var k: Big = 1;
            while (true) {
                try tick(control);
                term = @divTrunc(@divTrunc(term * halved, one), k);
                if (term == 0) break;
                sum += term;
                k += 1;
            }
            for (0..9) |_| sum = @divTrunc(sum * sum, one);
            return sum;
        }

        fn errorIfSpecialNegative(value: *const Numeric) Error!void {
            if (value.special == .ninf or (value.special == .finite and value.negative and !value.isZero())) return error.InvalidArgumentForLogarithm;
            if (value.isZero()) return error.InvalidArgumentForLogarithm;
        }

        /// ln(x) rounded to `rscale` decimals (ln_var).
        fn lnAt(value: *const Numeric, rscale: usize, control: Control) Error!Big {
            if (value.isZero()) return error.InvalidArgumentForLogarithm;
            if (value.negative) return error.InvalidArgumentForLogarithm;
            const w = rscale + guard;
            if (w > max_working) return error.NumericCapacity;
            return roundDown(try lnFixed(value, w, control), guard);
        }

        /// numeric_ln.
        pub fn ln(value: *const Numeric, control: Control) Error!Numeric {
            if (value.special != .finite) {
                if (value.special == .ninf) return error.InvalidArgumentForLogarithm;
                return value.*;
            }
            if (value.isZero() or value.negative) return error.InvalidArgumentForLogarithm;
            var rscale: i64 = 16 - @as(i64, try lnWeight(value));
            rscale = clampScale(@max(rscale, value.dscale));
            if (rscale > numeric.max_scale) return error.NumericCapacity;
            const scale: usize = @intCast(rscale);
            return make(try lnAt(value, scale, control), scale);
        }

        /// numeric_log(base, x) (log_var); log(x) is log(10, x).
        pub fn log(base: *const Numeric, value: *const Numeric, control: Control) Error!Numeric {
            if (base.special != .finite or value.special != .finite) {
                if (base.special == .nan or value.special == .nan) return numeric.nan();
                const sb = signOf(base);
                const sv = signOf(value);
                if (sb < 0 or sv < 0) return error.InvalidArgumentForLogarithm;
                if (sb == 0 or sv == 0) return error.InvalidArgumentForLogarithm;
                if (base.special == .pinf) return if (value.special == .pinf) numeric.nan() else .{};
                return .{ .special = .pinf };
            }
            const base_weight = try lnWeight(base);
            const value_weight = try lnWeight(value);
            const result_weight: i64 = @as(i64, value_weight) - base_weight;
            var rscale: i64 = 16 - result_weight;
            rscale = clampScale(@max(@max(rscale, base.dscale), value.dscale));
            if (rscale > numeric.max_scale) return error.NumericCapacity;
            const base_scale = @max(rscale + result_weight - base_weight + 8, 0);
            const value_scale = @max(rscale + result_weight - value_weight + 8, 0);
            if (base_scale > max_working or value_scale > max_working) return error.NumericCapacity;
            const ln_base = try lnAt(base, @intCast(base_scale), control);
            const ln_value = try lnAt(value, @intCast(value_scale), control);
            if (ln_base == 0) return error.DivisionByZero;
            // div_var(ln_num, ln_base, rscale, round): both are fixed point.
            const scale: usize = @intCast(rscale);
            const numerator_shift = scale + @as(usize, @intCast(base_scale)) + 1;
            if (numerator_shift < @as(usize, @intCast(value_scale))) return error.NumericCapacity;
            const shifted = ln_value * try ten(numerator_shift - @as(usize, @intCast(value_scale)));
            return make(try roundDown(@divTrunc(shifted, ln_base), 1), scale);
        }

        fn signOf(value: *const Numeric) i8 {
            return switch (value.special) {
                .ninf => -1,
                .pinf => 1,
                .nan => 0,
                .finite => if (value.isZero()) 0 else if (value.negative) -1 else 1,
            };
        }

        /// e^x rounded to `rscale` decimals for a fixed-point exponent `x`
        /// with `scale` decimals.
        fn expAt(x: Big, scale: usize, rscale: usize, control: Control) Error!Numeric {
            // x = k ln10 + r with |r| <= 1.16; e^x = e^r 10^k.
            // exp_var: |x| >= 3 * NUMERIC_MAX_RESULT_SCALE overflows or is 0.
            const whole = @divTrunc(x, try ten(scale));
            if (whole >= 6000) return error.NumericValueOutOfRange;
            if (whole <= -6000) return make(0, rscale);
            const approx: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(whole)))) / 2.302585092994046;
            if (@abs(approx) > 400) return error.NumericCapacity;
            const k: i64 = @intFromFloat(@round(approx));
            const w_signed: i64 = @as(i64, @intCast(rscale)) + k + @as(i64, guard);
            if (w_signed < @as(i64, guard) or w_signed > max_working) return error.NumericCapacity;
            const w: usize = @intCast(w_signed);
            const precise = w + 4;
            const x_fixed = if (precise >= scale) x * try ten(precise - scale) else @divTrunc(x, try ten(scale - precise));
            const ln10 = try lnMantissa(10 * try ten(precise), precise, control);
            const r = @divTrunc(x_fixed - @as(Big, k) * ln10, 10000);
            const e_r = try expSmall(r, w, control);
            // value = e_r * 10^k with w decimals: drop w - rscale - k digits.
            const drop: i64 = w_signed - @as(i64, @intCast(rscale)) - k;
            return make(try roundDown(e_r, @intCast(drop)), rscale);
        }

        /// numeric_exp.
        pub fn exp(value: *const Numeric, control: Control) Error!Numeric {
            if (value.special != .finite) return if (value.special == .ninf) .{} else value.*;
            var val = toDouble(value) * 0.434294481903252;
            val = @max(@min(val, 2000), -2000);
            var rscale: i64 = 16 - @as(i64, @intFromFloat(@trunc(val)));
            rscale = clampScale(@max(rscale, value.dscale));
            if (rscale > numeric.max_scale) return error.NumericCapacity;
            return expAt(signed(value), value.dscale, @intCast(rscale), control);
        }

        fn integral(value: *const Numeric) bool {
            return value.special == .finite and (value.dscale == 0 or value.coef() % @as(u256, @intCast(numeric.pow10[value.dscale])) == 0);
        }

        /// numeric_power (power_var / power_var_int).
        pub fn power(base: *const Numeric, exponent_value: *const Numeric, control: Control) Error!Numeric {
            const one = N.fromInt(1);
            if (base.special != .finite or exponent_value.special != .finite) {
                if (base.special == .nan) return if (exponent_value.special == .finite and exponent_value.isZero()) one else numeric.nan();
                if (exponent_value.special == .nan) return if (base.special == .finite and numeric.compareValues(base, &one) == 0) one else numeric.nan();
                const s1 = signOf(base);
                const s2 = signOf(exponent_value);
                if (s1 == 0 and s2 < 0) return error.InvalidArgumentForPowerFunction;
                if (s1 < 0 and !integral(exponent_value) and exponent_value.special == .finite) return error.InvalidArgumentForPowerFunction;
                if (base.special == .finite and numeric.compareValues(base, &one) == 0) return one;
                if (s2 == 0) return one;
                if (s1 == 0 and s2 > 0) return .{};
                if (exponent_value.special != .finite) {
                    var greater = true;
                    if (base.special == .finite) {
                        const minus_one = N.fromInt(-1);
                        if (numeric.compareValues(base, &minus_one) == 0) return one;
                        const magnitude = N.absolute(base);
                        greater = numeric.compareValues(&magnitude, &one) > 0;
                    }
                    return if (greater == (s2 > 0)) .{ .special = .pinf } else .{};
                }
                if (base.special == .pinf) return if (s2 > 0) .{ .special = .pinf } else .{};
                // -Infinity ^ finite non-zero exponent.
                if (s2 < 0) return .{};
                const odd = integral(exponent_value) and oddIntegral(exponent_value);
                return .{ .special = if (odd) .ninf else .pinf };
            }
            if (base.isZero() and exponent_value.negative and !exponent_value.isZero()) return error.InvalidArgumentForPowerFunction;
            if (base.negative and !base.isZero() and !integral(exponent_value)) return error.InvalidArgumentForPowerFunction;
            if (integral(exponent_value)) {
                const whole = N.toInt(exponent_value, -2147483648, 2147483647) catch null;
                if (whole) |p| return powerInteger(base, p, exponent_value.dscale, control);
            }
            if (base.isZero()) return make(0, 16);
            // Non-integer exponent: exp(y ln|x|) with PostgreSQL's scales.
            const ln_weight = try lnWeight(base);
            const first_scale: usize = @intCast(@max(8 - @as(i64, ln_weight), 0));
            const ln_low = try make(try lnAt(base, first_scale, control), first_scale);
            const product_low = try roundTo(try N.mul(&ln_low, exponent_value), first_scale);
            var val = toDouble(&product_low);
            if (@abs(val) > 2000 * 3.01) {
                if (val > 0) return error.NumericValueOutOfRange;
                return make(0, numeric.max_scale);
            }
            val *= 0.434294481903252;
            var rscale: i64 = 16 - @as(i64, @intFromFloat(@trunc(val)));
            rscale = clampScale(@max(@max(rscale, base.dscale), exponent_value.dscale));
            if (rscale > numeric.max_scale) return error.NumericCapacity;
            const sig_digits: i64 = @max(rscale + @as(i64, @intFromFloat(@trunc(val))), 0);
            const local_signed: i64 = @max(sig_digits - ln_weight + 8, 0);
            const local_scale: usize = @intCast(local_signed);
            if (local_scale > max_working) return error.NumericCapacity;
            const ln_base = try make(try lnAt(base, local_scale, control), local_scale);
            const product = try roundTo(try N.mul(&ln_base, exponent_value), local_scale);
            return expAt(signed(&product), product.dscale, @intCast(rscale), control);
        }

        fn oddIntegral(value: *const Numeric) bool {
            const whole = value.coef() / @as(u256, @intCast(numeric.pow10[value.dscale]));
            return whole % 2 == 1;
        }

        fn roundTo(value: Numeric, scale: usize) Error!Numeric {
            return N.round(&value, @intCast(scale));
        }

        /// power_var_int: result scale from the approximate decimal weight.
        fn powerInteger(base: *const Numeric, p: i64, exponent_scale: u16, control: Control) Error!Numeric {
            var f: f64 = 0;
            if (!base.isZero()) {
                const magnitude = N.absolute(base);
                const groups = N.toBase10000(&magnitude);
                var leading: f64 = @floatFromInt(groups.digits[0]);
                var decimal: i64 = @as(i64, groups.weight) * 4;
                var index: usize = 1;
                while (index < groups.ndigits and index * 4 < 16) : (index += 1) {
                    leading = leading * 10000 + @as(f64, @floatFromInt(groups.digits[index]));
                    decimal -= 4;
                }
                f = @as(f64, @floatFromInt(p)) * (@log10(leading) + @as(f64, @floatFromInt(decimal)));
            }
            if (f > 4 * 32768) return error.NumericValueOutOfRange;
            if (f + 1 < -1000) return make(0, numeric.max_scale) catch error.NumericCapacity;
            var rscale: i64 = 16 - @as(i64, @intFromFloat(@trunc(f)));
            rscale = clampScale(@max(@max(rscale, base.dscale), exponent_scale));
            if (rscale > numeric.max_scale) return error.NumericCapacity;
            const scale: usize = @intCast(rscale);
            if (p == 0) return make(try ten(scale), scale);
            if (base.isZero()) {
                if (p < 0) return error.DivisionByZero;
                return make(0, scale);
            }
            // Exact when the product fits; otherwise exp(p ln|x|).
            const raw: Big = @intCast(base.coef());
            const count: usize = @intCast(if (p < 0) -p else p);
            const coefficient_digits = numeric.digitCount(base.coef());
            const negative = base.negative and count % 2 == 1;
            if (coefficient_digits * count <= 140 and @as(usize, base.dscale) * count <= 280) {
                var product: Big = 1;
                for (0..count) |_| {
                    try tick(control);
                    product *= raw;
                }
                const product_scale: usize = @as(usize, base.dscale) * count;
                if (p > 0) {
                    const value = if (scale >= product_scale) product * try ten(scale - product_scale) else try roundDown(product, product_scale - scale);
                    return make(if (negative) -value else value, scale);
                }
                // 1 / x^|p| at `scale`, rounded: 10^(scale + product_scale) / product.
                const shift = scale + product_scale + 1;
                if (shift >= pow10_big.len or digitCount(product) + shift > 300) return error.NumericCapacity;
                const value = try roundDown(@divTrunc(try ten(shift), product), 1);
                return make(if (negative) -value else value, scale);
            }
            const magnitude = N.absolute(base);
            // ln|x| error is amplified by |p| (at most 10 digits).
            const w = scale + guard + 10 + @as(usize, @intCast(@max(@as(i64, @intFromFloat(@abs(f))), 0)));
            if (w > max_working) return error.NumericCapacity;
            const logarithm = try lnFixed(&magnitude, w, control);
            const result = try expAt(logarithm * p, w, scale, control);
            return if (negative) N.negate(result) else result;
        }

        /// numeric_div_trunc: the integer quotient toward zero (scale 0).
        pub fn divTrunc(a: *const Numeric, b: *const Numeric) Error!Numeric {
            if (a.special == .nan or b.special == .nan) return numeric.nan();
            if (b.special == .finite and b.isZero()) return error.DivisionByZero;
            if (a.special != .finite) {
                if (b.special != .finite) return numeric.nan();
                const negative = (a.special == .ninf) != b.negative;
                return .{ .special = if (negative) .ninf else .pinf };
            }
            if (b.special != .finite) return .{};
            const scale = @max(a.dscale, b.dscale);
            const left = try fixed(a, scale);
            const right = try fixed(b, scale);
            return make(@divTrunc(left, right), 0);
        }

        fn gcdBig(a_in: Big, b_in: Big, control: Control) Error!Big {
            var a = if (a_in < 0) -a_in else a_in;
            var b = if (b_in < 0) -b_in else b_in;
            while (b != 0) {
                try tick(control);
                const t = @rem(a, b);
                a = b;
                b = t;
            }
            return a;
        }

        /// numeric gcd/lcm at the larger display scale; specials are NaN.
        pub fn gcdLcm(a: *const Numeric, b: *const Numeric, lcm: bool, control: Control) Error!Numeric {
            if (a.special != .finite or b.special != .finite) return numeric.nan();
            const scale: usize = @max(a.dscale, b.dscale);
            const left = try fixed(a, scale);
            const right = try fixed(b, scale);
            const divisor = try gcdBig(left, right, control);
            if (!lcm) return make(divisor, scale);
            if (left == 0 or right == 0) return make(0, scale);
            const magnitude = if (left < 0) -left else left;
            const other = if (right < 0) -right else right;
            return make(@divTrunc(magnitude, divisor) * other, scale);
        }

        /// min_scale: the fewest decimals that represent the value exactly.
        pub fn minScale(value: *const Numeric) ?i64 {
            if (value.special != .finite) return null;
            var raw = value.coef();
            var scale: i64 = value.dscale;
            while (scale > 0 and raw % 10 == 0) : (scale -= 1) raw /= 10;
            return if (raw == 0) 0 else scale;
        }

        pub fn trimScale(value: *const Numeric) Numeric {
            if (value.special != .finite) return value.*;
            var out = value.*;
            var raw = value.coef();
            var scale: u16 = value.dscale;
            while (scale > 0 and raw % 10 == 0) : (scale -= 1) raw /= 10;
            if (raw == 0) scale = 0;
            out.dscale = scale;
            out.setCoef(raw);
            return out;
        }
    };
}

/// Correctly rounded double precision exp, ln, log10 and pow (B11).
///
/// Library implementations differ in their last bit; PostgreSQL calls the
/// platform's libm, whose exp/log/pow are correctly rounded for practically
/// all inputs. These evaluate the exact binary input in 40-digit fixed point
/// and round once to the nearest double through the shortest-text parser, so
/// a result differs from the exact value's rounding only when that value is
/// within about 10^-35 relative of a rounding boundary. Overflow and
/// underflow are 22003 (float_text.parse), as check_float8_val reports.
pub const Doubles = struct {
    const w: usize = 40;

    const Parts = struct { mantissa: u64, exponent: i32 };

    /// x = mantissa * 2^exponent for finite x > 0.
    fn decompose(x: f64) Parts {
        const bits: u64 = @bitCast(x);
        const biased: i32 = @intCast((bits >> 52) & 0x7ff);
        const fraction = bits & 0xfffffffffffff;
        if (biased == 0) return .{ .mantissa = fraction, .exponent = -1074 };
        return .{ .mantissa = fraction | (@as(u64, 1) << 52), .exponent = biased - 1075 };
    }

    /// round(x * 10^w) for finite |x| < 2^20.
    fn fixedOf(x: f64) Big {
        const parts = decompose(@abs(x));
        var value: Big = @as(Big, parts.mantissa) * pow10_big[w];
        if (parts.exponent >= 0) {
            value <<= @intCast(parts.exponent);
        } else {
            if (-parts.exponent >= 1000) return 0;
            const shift: u10 = @intCast(-parts.exponent);
            value = (value + (@as(Big, 1) << (shift - 1))) >> shift;
        }
        return if (x < 0) -value else value;
    }

    /// The double nearest to `value` * 10^(exponent - w).
    fn nearest(value: Big, exponent: i64) Error!f64 {
        if (value == 0) return 0;
        var buffer: [96]u8 = undefined;
        var digits: [320]u8 = undefined;
        var magnitude = if (value < 0) -value else value;
        var count: usize = 0;
        while (magnitude != 0) : (count += 1) {
            digits[count] = @intCast('0' + @as(u8, @intCast(@rem(magnitude, 10))));
            magnitude = @divTrunc(magnitude, 10);
        }
        // Keep 45 significant digits; the rest only affect far-below ties.
        const keep = @min(count, 45);
        var at: usize = 0;
        if (value < 0) {
            buffer[0] = '-';
            at = 1;
        }
        for (0..keep) |index| {
            buffer[at] = digits[count - 1 - index];
            at += 1;
        }
        const scaled: i64 = exponent - @as(i64, w) + @as(i64, @intCast(count - keep));
        buffer[at] = 'e';
        at += 1;
        if (scaled < 0) {
            buffer[at] = '-';
            at += 1;
        }
        var power: u64 = @abs(scaled);
        var reversed: [20]u8 = undefined;
        var length: usize = 0;
        while (true) : (length += 1) {
            reversed[length] = @intCast('0' + power % 10);
            power /= 10;
            if (power == 0) break;
        }
        for (0..length + 1) |index| {
            buffer[at] = reversed[length - index];
            at += 1;
        }
        return float_text.parse(f64, buffer[0..at]);
    }

    fn lnTen(precision: usize) Error!Big {
        return Math(76).lnMantissa(10 * try ten(precision), precision, null);
    }

    /// e^(z / 10^w) for a fixed-point exponent with |z| <= 760 * 10^w.
    fn expFixed(z: Big) Error!f64 {
        const whole: f64 = @floatFromInt(@as(i64, @intCast(@divTrunc(z, pow10_big[w]))));
        const k: i64 = @intFromFloat(@round(whole / 2.302585092994046));
        const precise = w + 4;
        const ln10 = try lnTen(precise);
        const r = @divTrunc(z * 10000 - @as(Big, k) * ln10, 10000);
        const mantissa = try Math(76).expSmall(r, w, null);
        return nearest(mantissa, k);
    }

    pub fn exp(x: f64) Error!f64 {
        if (x > 710) return error.NumericValueOutOfRange;
        if (x < -746) return error.NumericValueOutOfRange;
        return expFixed(fixedOf(x));
    }

    /// ln(x) * 10^w for finite x > 0: ln(mantissa) + exponent ln 2.
    fn lnFixed(x: f64) Error!Big {
        const parts = decompose(x);
        const value: Numeric = .{ .limbs = .{ parts.mantissa, 0, 0, 0 } };
        const M = Math(76);
        var result = try M.lnFixed(&value, w, null);
        if (parts.exponent != 0) result += @as(Big, parts.exponent) * try M.lnMantissa(2 * pow10_big[w], w, null);
        return result;
    }

    pub fn ln(x: f64) Error!f64 {
        return nearest(try lnFixed(x), 0);
    }

    pub fn log10(x: f64) Error!f64 {
        const numerator = try lnFixed(x);
        return nearest(@divTrunc(numerator * pow10_big[w], try lnTen(w)), 0);
    }

    /// |x|^y for finite x != 0 and finite y; `negative` flips the sign.
    pub fn pow(x: f64, y: f64, negative: bool) Error!f64 {
        const magnitude = @abs(x);
        if (magnitude == 1 or y == 0) return if (negative) -1.0 else 1.0;
        const approx = y * @log(magnitude);
        if (approx > 710) return error.NumericValueOutOfRange;
        if (approx < -746) return error.NumericValueOutOfRange;
        const logarithm = try lnFixed(magnitude);
        const parts = decompose(@abs(y));
        var z: Big = logarithm * @as(Big, parts.mantissa);
        if (parts.exponent >= 0) {
            z <<= @intCast(parts.exponent);
        } else if (-parts.exponent >= 1000) {
            z = 0;
        } else {
            const shift: u10 = @intCast(-parts.exponent);
            z >>= shift;
        }
        if (y < 0) z = -z;
        const result = try expFixed(z);
        return if (negative) -result else result;
    }
};
