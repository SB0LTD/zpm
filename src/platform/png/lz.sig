// LZ77 hash-chain matching with sliding window
// Layer 1: Platform (internal to png/ module)
//
// Implements LZ77 compression with lazy match evaluation and a 32KB
// sliding window that persists across calls for cross-block matching.
// Uses a monotonically increasing global position counter so hash
// chain entries remain valid across calls.

const HASH_BITS = 15;
const HASH_SIZE = 1 << HASH_BITS;
const HASH_MASK = HASH_SIZE - 1;
const MAX_MATCH = 258;
const MIN_MATCH = 3;
pub const MAX_DIST = 32768;
const MAX_CHAIN = 512;
const GOOD_LENGTH = 128;
const NICE_LENGTH = 258;

pub const LzToken = struct {
    lit_or_len: u16,
    dist: u16,
};

/// LZ77 state — file-scope static to avoid stack overflow.
/// Only one screenshot can be in progress at a time, so this is safe.
///
/// Supports cross-block compression via a 32KB sliding window. Call
/// `compress()` repeatedly without `reset()` — the window retains
/// context from previous blocks so LZ77 can find matches across
/// block boundaries, dramatically improving compression ratio.
pub const LzState = struct {
    head: [HASH_SIZE]u32,
    prev: [MAX_DIST]u32,
    /// Sliding window — last MAX_DIST bytes from previous compress() calls.
    window: [MAX_DIST]u8,
    window_len: u32,
    /// Global byte offset — monotonically increasing across compress() calls.
    global_offset: u32,

    const instance = struct {
        var data: LzState = .{
            .head = [_]u32{0} ** HASH_SIZE,
            .prev = [_]u32{0} ** MAX_DIST,
            .window = [_]u8{0} ** MAX_DIST,
            .window_len = 0,
            .global_offset = 0,
        };
    };

    pub fn getStatic() *LzState {
        return &instance.data;
    }

    pub fn reset(self: *LzState) void {
        @memset(&self.head, 0);
        @memset(&self.prev, 0);
        self.window_len = 0;
        self.global_offset = 0;
    }

    /// Compress `input`, emitting tokens only for `input` bytes.
    /// Uses the sliding window from previous calls for cross-block
    /// LZ77 matching. After compression, updates the window with
    /// the tail of `input`.
    pub fn compress(self: *LzState, input: []const u8, tokens: []LzToken) usize {
        const wlen: usize = self.window_len;
        const base: u32 = self.global_offset;
        const total = wlen + input.len;
        const emit_start = wlen;

        var token_count: usize = 0;
        var i: usize = 0;

        var prev_match_len: usize = 0;
        var prev_match_dist: usize = 0;
        var prev_literal: u8 = 0;
        var have_prev: bool = false;

        while (i < total) {
            var best_len: usize = 0;
            var best_dist: usize = 0;

            if (i + 2 < total) {
                const b0 = self.readByte(input, i);
                const b1 = self.readByte(input, i + 1);
                const b2 = self.readByte(input, i + 2);
                const h = ((@as(u32, b0) << 10) ^ (@as(u32, b1) << 5) ^ @as(u32, b2)) & HASH_MASK;
                const gpos: u32 = base +% @as(u32, @intCast(i));

                self.prev[gpos & (MAX_DIST - 1)] = self.head[h];
                self.head[h] = gpos;

                if (i >= emit_start) {
                    var chain_gpos = self.prev[gpos & (MAX_DIST - 1)];
                    var chain_len: usize = 0;
                    const max_chain: usize = if (have_prev and prev_match_len >= GOOD_LENGTH) MAX_CHAIN / 4 else MAX_CHAIN;

                    while (chain_len < max_chain) : (chain_len += 1) {
                        const dist = gpos -% chain_gpos;
                        if (dist == 0 or dist > MAX_DIST) break;
                        if (chain_gpos -% base >= total) break;
                        const local: usize = chain_gpos -% base;
                        if (local >= total) break;

                        const match_limit = @min(MAX_MATCH, @min(total - i, total - local));
                        var ml: usize = 0;
                        while (ml < match_limit and
                            self.readByte(input, local + ml) == self.readByte(input, i + ml)) : (ml += 1)
                        {}

                        if (ml >= MIN_MATCH and ml > best_len) {
                            best_len = ml;
                            best_dist = dist;
                            if (ml >= NICE_LENGTH) break;
                        }

                        chain_gpos = self.prev[chain_gpos & (MAX_DIST - 1)];
                    }
                }
            }

            if (i < emit_start) {
                i += 1;
                continue;
            }

            if (have_prev) {
                if (best_len > prev_match_len + 1) {
                    if (token_count < tokens.len) {
                        tokens[token_count] = .{ .lit_or_len = prev_literal, .dist = 0 };
                        token_count += 1;
                    }
                    prev_match_len = best_len;
                    prev_match_dist = best_dist;
                    prev_literal = self.readByte(input, i);
                    i += 1;
                    continue;
                } else {
                    if (token_count < tokens.len) {
                        tokens[token_count] = .{
                            .lit_or_len = @intCast(prev_match_len),
                            .dist = @intCast(prev_match_dist),
                        };
                        token_count += 1;
                    }
                    const skip = prev_match_len - 1;
                    var s: usize = 0;
                    while (s < skip and i + s < total and i + s + 2 < total) : (s += 1) {
                        const si = i + s;
                        const sb0 = self.readByte(input, si);
                        const sb1 = self.readByte(input, si + 1);
                        const sb2 = self.readByte(input, si + 2);
                        const sh = ((@as(u32, sb0) << 10) ^ (@as(u32, sb1) << 5) ^ @as(u32, sb2)) & HASH_MASK;
                        const sp: u32 = base +% @as(u32, @intCast(si));
                        self.prev[sp & (MAX_DIST - 1)] = self.head[sh];
                        self.head[sh] = sp;
                    }
                    i += skip;
                    have_prev = false;
                    continue;
                }
            }

            if (best_len >= MIN_MATCH) {
                prev_match_len = best_len;
                prev_match_dist = best_dist;
                prev_literal = self.readByte(input, i);
                have_prev = true;
                i += 1;
            } else {
                if (token_count < tokens.len) {
                    tokens[token_count] = .{ .lit_or_len = self.readByte(input, i), .dist = 0 };
                    token_count += 1;
                }
                i += 1;
            }
        }

        if (have_prev) {
            if (prev_match_len >= MIN_MATCH) {
                if (token_count < tokens.len) {
                    tokens[token_count] = .{
                        .lit_or_len = @intCast(prev_match_len),
                        .dist = @intCast(prev_match_dist),
                    };
                    token_count += 1;
                }
            } else {
                if (token_count < tokens.len) {
                    tokens[token_count] = .{ .lit_or_len = prev_literal, .dist = 0 };
                    token_count += 1;
                }
            }
        }

        // Update sliding window with tail of input, advance global offset
        if (input.len >= MAX_DIST) {
            @memcpy(&self.window, input[input.len - MAX_DIST ..][0..MAX_DIST]);
            self.window_len = MAX_DIST;
        } else if (wlen + input.len <= MAX_DIST) {
            @memcpy(self.window[wlen .. wlen + input.len], input);
            self.window_len = @intCast(wlen + input.len);
        } else {
            const new_total = wlen + input.len;
            const keep = MAX_DIST;
            const discard = new_total - keep;
            if (discard < wlen) {
                const remaining = wlen - discard;
                var j: usize = 0;
                while (j < remaining) : (j += 1) {
                    self.window[j] = self.window[discard + j];
                }
                @memcpy(self.window[remaining..MAX_DIST], input);
            } else {
                const input_skip = discard - wlen;
                @memcpy(self.window[0..MAX_DIST], input[input_skip..][0..MAX_DIST]);
            }
            self.window_len = MAX_DIST;
        }
        self.global_offset = base +% @as(u32, @intCast(total)) -% self.window_len;

        return token_count;
    }

    /// Read a byte from the conceptual [window ++ input] buffer at local index.
    inline fn readByte(self: *const LzState, input: []const u8, local: usize) u8 {
        const wlen: usize = self.window_len;
        if (local < wlen) return self.window[local];
        return input[local - wlen];
    }
};
