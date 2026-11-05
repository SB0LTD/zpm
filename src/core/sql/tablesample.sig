//! TABLESAMPLE row selection (Layer 0, conformance lane B11).
//!
//! BERNOULLI and SYSTEM follow PostgreSQL 18's tsm_bernoulli / tsm_system:
//! the REPEATABLE seed is hashfloat8(seed), the cutoff is
//! rint(2^32 * percent / 100), and a tuple (BERNOULLI: block, offset, seed)
//! or a block (SYSTEM: block, seed) is kept when PostgreSQL's hash_bytes of
//! those 32-bit words is below the cutoff. 0 keeps nothing and 100 keeps
//! everything, exactly as PostgreSQL. The engine has no heap pages: row slot
//! s is modeled as block s / page_rows, line offset s % page_rows + 1, which
//! matches a never-updated PostgreSQL table that fits one page. Other
//! layouts are deterministic for a REPEATABLE seed but are not PostgreSQL's
//! physical layout, so partial samples are not expected to match a native
//! server row for row.

/// Row slots per modeled heap block.
pub const page_rows: u32 = 64;

fn rot(x: u32, k: u5) u32 {
    return (x << k) | (x >> @intCast(@as(u6, 32) - k));
}

const State = struct {
    a: u32,
    b: u32,
    c: u32,

    fn mix(self: *State) void {
        self.a -%= self.c;
        self.a ^= rot(self.c, 4);
        self.c +%= self.b;
        self.b -%= self.a;
        self.b ^= rot(self.a, 6);
        self.a +%= self.c;
        self.c -%= self.b;
        self.c ^= rot(self.b, 8);
        self.b +%= self.a;
        self.a -%= self.c;
        self.a ^= rot(self.c, 16);
        self.c +%= self.b;
        self.b -%= self.a;
        self.b ^= rot(self.a, 19);
        self.a +%= self.c;
        self.c -%= self.b;
        self.c ^= rot(self.b, 4);
        self.b +%= self.a;
    }

    fn final(self: *State) void {
        self.c ^= self.b;
        self.c -%= rot(self.b, 14);
        self.a ^= self.c;
        self.a -%= rot(self.c, 11);
        self.b ^= self.a;
        self.b -%= rot(self.a, 25);
        self.c ^= self.b;
        self.c -%= rot(self.b, 16);
        self.a ^= self.c;
        self.a -%= rot(self.c, 4);
        self.b ^= self.a;
        self.b -%= rot(self.a, 14);
        self.c ^= self.b;
        self.c -%= rot(self.b, 24);
    }
};

/// PostgreSQL hash_bytes over three aligned little-endian 32-bit words.
pub fn hash3(a: u32, b: u32, c: u32) u32 {
    const initial = 0x9e3779b9 +% @as(u32, 12) +% 3923095;
    var state: State = .{ .a = initial +% a, .b = initial +% b, .c = initial +% c };
    state.mix();
    state.final();
    return state.c;
}

/// PostgreSQL hash_bytes over two aligned little-endian 32-bit words.
pub fn hash2(a: u32, b: u32) u32 {
    const initial = 0x9e3779b9 +% @as(u32, 8) +% 3923095;
    var state: State = .{ .a = initial +% a, .b = initial +% b, .c = initial };
    state.final();
    return state.c;
}

/// PostgreSQL hashfloat8: zero (either sign) hashes to 0, every NaN to the
/// standard NaN's hash, otherwise hash_bytes of the 8 value bytes.
pub fn hashFloat8(value: f64) u32 {
    if (value == 0) return 0;
    const key: f64 = if (value != value) @bitCast(@as(u64, 0x7ff8000000000000)) else value;
    const bits: u64 = @bitCast(key);
    return hash2(@truncate(bits), @truncate(bits >> 32));
}

/// Keep-below threshold for a percentage in [0, 100]: rint (half to even)
/// of 2^32 * percent / 100, as PostgreSQL computes it.
pub fn cutoff(percent: f32) u64 {
    const scaled = 4294967296.0 * @as(f64, percent) / 100.0;
    const floor = @floor(scaled);
    const fraction = scaled - floor;
    var rounded = floor;
    if (fraction > 0.5 or (fraction == 0.5 and @mod(floor, 2.0) != 0)) rounded += 1;
    return @intFromFloat(rounded);
}

/// Whether row slot `slot` is in the sample.
pub fn keep(method: u8, slot: usize, seed: u32, threshold: u64) bool {
    const block: u32 = @truncate(slot / page_rows);
    if (method == 2) return hash2(block, seed) < threshold;
    const offset: u32 = @truncate(slot % page_rows + 1);
    return hash3(block, offset, seed) < threshold;
}
