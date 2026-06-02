// Log formatting engine — timestamp + part serialization
// Layer 1: Platform

const w32 = @import("win32");
const fmtI64 = @import("core").fmt.fmtI64;

// ── Timestamp ───────────────────────────────────────────────

var start_tick: u64 = 0;
var tick_freq: u64 = 0;

pub fn writeTimestamp(out: []u8) usize {
    if (out.len < 10) return 0;
    const ms = getUptimeMs();
    const total_sec: u64 = ms / 1000;
    const h: u64 = total_sec / 3600;
    const m: u64 = (total_sec % 3600) / 60;
    const s: u64 = total_sec % 60;
    out[0] = @intCast('0' + (h / 10) % 10);
    out[1] = @intCast('0' + h % 10);
    out[2] = ':';
    out[3] = @intCast('0' + m / 10);
    out[4] = @intCast('0' + m % 10);
    out[5] = ':';
    out[6] = @intCast('0' + s / 10);
    out[7] = @intCast('0' + s % 10);
    out[8] = ' ';
    return 9;
}

fn getUptimeMs() u64 {
    if (tick_freq == 0) {
        var freq: w32.LARGE_INTEGER = .{};
        _ = w32.QueryPerformanceFrequency(&freq);
        tick_freq = @intCast(freq.QuadPart);
        var now: w32.LARGE_INTEGER = .{};
        _ = w32.QueryPerformanceCounter(&now);
        start_tick = @intCast(now.QuadPart);
        return 0;
    }
    var now: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceCounter(&now);
    const elapsed: u64 = @intCast(now.QuadPart);
    return ((elapsed - start_tick) * 1000) / tick_freq;
}

// ── Part serialization ──────────────────────────────────────

/// Write a single part into the buffer. Comptime-dispatched by type.
pub inline fn writePart(buf: *[512]u8, pos: usize, part: anytype) usize {
    const P = @TypeOf(part);
    var p = pos;
    if (P == []const u8) {
        const n = @min(part.len, buf.len - p);
        @memcpy(buf[p .. p + n], part[0..n]);
        p += n;
    } else if (P == i64) {
        p += fmtI64(buf[p..], part);
    } else if (P == usize or P == u32 or P == u64 or P == i32) {
        p += fmtI64(buf[p..], @as(i64, @intCast(part)));
    } else if (comptime isStringPtr(P)) {
        const slice: []const u8 = part;
        const n = @min(slice.len, buf.len - p);
        @memcpy(buf[p .. p + n], slice[0..n]);
        p += n;
    } else {
        @compileError("log: unsupported part type in tuple — use []const u8 or integer");
    }
    return p;
}

pub fn isTuple(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
}

pub fn isStringPtr(comptime T: type) bool {
    if (@typeInfo(T) != .pointer) return false;
    const child = @typeInfo(T).pointer.child;
    if (@typeInfo(child) != .array) return false;
    return @typeInfo(child).array.child == u8;
}
