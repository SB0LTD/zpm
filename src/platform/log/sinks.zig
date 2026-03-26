// Log sinks — ring buffer + file output, init, level management
// Layer 1: Platform

const w32 = @import("win32");
const ring_log = @import("core").ui.ring_log;

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "ERR  ",
            .warn => "WARN ",
            .info => "INFO ",
            .debug => "DBG  ",
            .trace => "TRC  ",
        };
    }
};

const SinkFn = *const fn (level: u8, line: []const u8) void;
const MAX_SINKS = 4;

var sinks: [MAX_SINKS]?SinkFn = [_]?SinkFn{null} ** MAX_SINKS;
var sink_count: usize = 0;
pub var current_level: Level = .info;
pub var initialized: bool = false;

pub fn addSink(f: SinkFn) void {
    if (sink_count < MAX_SINKS) {
        sinks[sink_count] = f;
        sink_count += 1;
    }
}

pub fn dispatch(level: Level, line: []const u8) void {
    const lvl = @intFromEnum(level);
    for (sinks[0..sink_count]) |maybe_sink| {
        if (maybe_sink) |sink| sink(lvl, line);
    }
}

fn sinkRing(level: u8, line: []const u8) void {
    ring_log.push(level, line);
}

const LOG_FILE = w32.L("sb0trade.log");

fn sinkFile(_: u8, line: []const u8) void {
    const handle = w32.CreateFileW(
        LOG_FILE,
        w32.GENERIC_WRITE,
        w32.FILE_SHARE_READ | w32.FILE_SHARE_WRITE,
        null,
        w32.OPEN_ALWAYS,
        w32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == w32.INVALID_HANDLE_VALUE) return;
    _ = w32.SetFilePointer(handle, 0, null, w32.FILE_END);
    var file_buf: [514]u8 = undefined;
    const n = @min(line.len, 512);
    @memcpy(file_buf[0..n], line[0..n]);
    file_buf[n] = '\r';
    file_buf[n + 1] = '\n';
    _ = w32.WriteFile(handle, &file_buf, @intCast(n + 2), null, null);
    _ = w32.CloseHandle(handle);
}

pub fn isDebug() bool {
    return @intFromEnum(current_level) >= @intFromEnum(Level.debug);
}

pub fn init(level_str: []const u8) void {
    if (level_str.len > 0) {
        current_level = parseLevel(level_str);
    } else {
        current_level = levelFromCmdLine();
    }

    sink_count = 0;
    addSink(&sinkRing);
    addSink(&sinkFile);

    const handle = w32.CreateFileW(
        LOG_FILE,
        w32.GENERIC_WRITE,
        w32.FILE_SHARE_READ,
        null,
        w32.CREATE_ALWAYS,
        w32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle != w32.INVALID_HANDLE_VALUE) {
        _ = w32.CloseHandle(handle);
    }

    initialized = true;
}

pub fn ensureInit() void {
    if (!initialized) {
        current_level = levelFromCmdLine();
        addSink(&sinkRing);
        addSink(&sinkFile);
        initialized = true;
    }
}

fn parseLevel(s: []const u8) Level {
    if (s.len >= 3) {
        if (s[0] == 'e' and s[1] == 'r' and s[2] == 'r') return .err;
        if (s[0] == 'w' and s[1] == 'a' and s[2] == 'r') return .warn;
        if (s[0] == 'i' and s[1] == 'n' and s[2] == 'f') return .info;
        if (s[0] == 'd' and s[1] == 'e' and s[2] == 'b') return .debug;
        if (s[0] == 't' and s[1] == 'r' and s[2] == 'a') return .trace;
    }
    return .info;
}

pub fn levelFromCmdLine() Level {
    const cmdline = w32.GetCommandLineW();
    var i: usize = 0;
    while (cmdline[i] != 0) : (i += 1) {
        if (cmdline[i] == '-' and cmdline[i + 1] == '-') {
            if (cmdline[i + 2] == 't' and cmdline[i + 3] == 'r' and
                cmdline[i + 4] == 'a' and cmdline[i + 5] == 'c' and
                cmdline[i + 6] == 'e') return .trace;
            if (cmdline[i + 2] == 'd' and cmdline[i + 3] == 'e' and
                cmdline[i + 4] == 'b' and cmdline[i + 5] == 'u' and
                cmdline[i + 6] == 'g') return .debug;
        }
    }
    return .info;
}
