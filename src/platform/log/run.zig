// Log public API — emit functions
// Layer 1: Platform
//
// Usage:
//   const log = @import("../platform/log.zig");
//   log.info("connected to exchange");
//   log.info(.{ "candles parsed: ", @as(i64, count) });

const sinks = @import("sinks.zig");
const fmt = @import("fmt.zig");

pub const Level = sinks.Level;

pub fn isDebug() bool {
    return sinks.isDebug();
}

pub fn init(level_str: []const u8) void {
    sinks.init(level_str);
    info("logging initialized");
}

pub fn err(msg: anytype) void {
    emit(.err, msg);
}
pub fn warn(msg: anytype) void {
    emit(.warn, msg);
}
pub fn info(msg: anytype) void {
    emit(.info, msg);
}
pub fn debug(msg: anytype) void {
    emit(.debug, msg);
}
pub fn trace(msg: anytype) void {
    emit(.trace, msg);
}

fn emit(level: Level, msg: anytype) void {
    sinks.ensureInit();
    if (@intFromEnum(level) > @intFromEnum(sinks.current_level)) return;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    pos += fmt.writeTimestamp(buf[pos..]);
    const lbl = level.label();
    @memcpy(buf[pos .. pos + lbl.len], lbl);
    pos += lbl.len;

    const T = @TypeOf(msg);
    if (T == []const u8) {
        const n = @min(msg.len, buf.len - pos);
        @memcpy(buf[pos .. pos + n], msg[0..n]);
        pos += n;
    } else if (comptime fmt.isTuple(T)) {
        inline for (msg) |part| {
            pos = fmt.writePart(&buf, pos, part);
        }
    } else if (comptime fmt.isStringPtr(T)) {
        const slice: []const u8 = msg;
        const n = @min(slice.len, buf.len - pos);
        @memcpy(buf[pos .. pos + n], slice[0..n]);
        pos += n;
    } else {
        @compileError("log: unsupported message type — use []const u8 or .{ parts... }");
    }

    sinks.dispatch(level, buf[0..pos]);
}
