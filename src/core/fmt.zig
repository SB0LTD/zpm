// Pure formatting utilities — integer/float to ASCII, OHLCV record encoding
// Layer 0: Core — no I/O, no platform imports
//
// Reusable across any module that needs to format numbers into buffers
// or serialize/deserialize OHLCV records as raw bytes.

const OHLCV = @import("types.zig").OHLCV;

/// Format a usize as decimal ASCII into `out`. Returns number of bytes written.
pub fn fmtInt(out: []u8, val: usize) usize {
    if (val == 0) {
        if (out.len > 0) out[0] = '0';
        return 1;
    }
    var v = val;
    var tmp: [20]u8 = undefined;
    var tl: usize = 0;
    while (v > 0) : (v /= 10) {
        tmp[tl] = @intCast(v % 10 + '0');
        tl += 1;
    }
    var pos: usize = 0;
    var ri = tl;
    while (ri > 0) : (ri -= 1) {
        if (pos >= out.len) break;
        out[pos] = tmp[ri - 1];
        pos += 1;
    }
    return pos;
}

/// Format an i64 as decimal ASCII into `out`. Returns number of bytes written.
/// Handles negative values.
pub fn fmtI64(out: []u8, val: i64) usize {
    if (val == 0) {
        if (out.len > 0) out[0] = '0';
        return 1;
    }
    var pos: usize = 0;
    var v: u64 = undefined;
    if (val < 0) {
        if (pos < out.len) {
            out[pos] = '-';
            pos += 1;
        }
        v = @intCast(-val);
    } else {
        v = @intCast(val);
    }
    var tmp: [20]u8 = undefined;
    var tl: usize = 0;
    while (v > 0) : (v /= 10) {
        tmp[tl] = @intCast(v % 10 + '0');
        tl += 1;
    }
    var ri = tl;
    while (ri > 0) : (ri -= 1) {
        if (pos >= out.len) break;
        out[pos] = tmp[ri - 1];
        pos += 1;
    }
    return pos;
}

/// Size of one packed OHLCV record on disk: i64 + 5×f64 = 48 bytes
pub const RECORD_SIZE: usize = 48;

/// Encode one OHLCV into 48 raw bytes (native endian).
pub fn encodeRecord(out: *[RECORD_SIZE]u8, c: *const OHLCV) void {
    const ts: [8]u8 = @bitCast(c.timestamp);
    const o: [8]u8 = @bitCast(c.open);
    const h: [8]u8 = @bitCast(c.high);
    const l: [8]u8 = @bitCast(c.low);
    const cl: [8]u8 = @bitCast(c.close);
    const vl: [8]u8 = @bitCast(c.volume);
    @memcpy(out[0..8], &ts);
    @memcpy(out[8..16], &o);
    @memcpy(out[16..24], &h);
    @memcpy(out[24..32], &l);
    @memcpy(out[32..40], &cl);
    @memcpy(out[40..48], &vl);
}

/// Decode 48 raw bytes into an OHLCV (native endian).
pub fn decodeRecord(raw: *const [RECORD_SIZE]u8) OHLCV {
    return .{
        .timestamp = @bitCast(raw[0..8].*),
        .open = @bitCast(raw[8..16].*),
        .high = @bitCast(raw[16..24].*),
        .low = @bitCast(raw[24..32].*),
        .close = @bitCast(raw[32..40].*),
        .volume = @bitCast(raw[40..48].*),
    };
}
