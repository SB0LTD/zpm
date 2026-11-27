//! Interactive Windows commissioning client. Own USB framing, no Python/SDK.
const z = @import("zpm_slowwire");
const io = z.windows;
const p = z.dynamixel2;
const wire = z.link;
var direct: ?*z.service.Service = null;
var clock_context: u8 = 0;
fn clockNow(_: *anyopaque) u32 {
    return io.now();
}
fn clockDelay(_: *anyopaque, ms: u32) void {
    io.sleep(ms);
}
var sequence: u16 = 0;
var receiver: wire.Receiver = .{};
fn request(port: io.Handle, op: wire.Op, data: []const u8) !wire.Frame {
    sequence +%= 1;
    var f: wire.Frame = .{ .seq = sequence, .op = op, .len = data.len };
    @memcpy(f.payload[0..data.len], data);
    var encoded: wire.Encoded = .{};
    try wire.encode(&f, &encoded);
    if (direct) |service| {
        var reply: wire.Frame = .{ .seq = sequence, .op = @fromBackingInt(@intCast(@backingInt(op) | 0x80)), .len = 1 };
        reply.payload[0] = 0;
        service.execute(&f, &reply) catch |err| {
            service.stop(true);
            return err;
        };
        return reply;
    }
    try io.write(port, encoded.slice());
    const start = io.now();
    const timeout: u32 = if (op == .board_io) 5000 else 1500;
    var bytes: [64]u8 = undefined;
    while (io.now() -% start < timeout) {
        const n = try io.read(port, &bytes);
        for (bytes[0..n]) |b| {
            var result: wire.Frame = .{};
            if (receiver.feed(b, &result) and result.seq == sequence and @backingInt(result.op) == (@backingInt(op) | 0x80)) {
                if (result.len < 1) return error.Length;
                if (result.payload[0] != 0) {
                    io.print("device error=");
                    io.number(result.payload[0]);
                    io.print("\n");
                    return error.Device;
                }
                return result;
            }
        }
        io.sleep(1);
    }
    return error.Timeout;
}
fn report(f: *const wire.Frame) !void {
    if (f.len != 17) return error.Length;
    io.print("axis=");
    io.number(f.payload[1] + 1);
    io.print(" pos=");
    io.number(@as(i32, @bitCast(p.get32(f.payload[8..12]))));
    io.print(" mA=");
    io.number(@as(i16, @bitCast(p.get16(f.payload[2..4]))));
    io.print(" velocity=");
    io.number(@as(i32, @bitCast(p.get32(f.payload[4..8]))));
    io.print(" mV=");
    io.number(p.get16(f.payload[12..14]));
    io.print(" C=");
    io.number(f.payload[14]);
    io.print(" fault=");
    io.number(f.payload[15]);
    io.print(" state=");
    io.number(f.payload[16]);
    io.print("\n");
}
fn parseNumber(text: []const u8) !u16 {
    if (text.len == 0) return error.Number;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.Number;
        value = value * 10 + c - '0';
        if (value > 65535) return error.Number;
    }
    return @intCast(value);
}
fn command(port: io.Handle, line: []const u8, watch: *bool) !bool {
    var tokens: [49][]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    while (start < line.len) {
        while (start < line.len and line[start] == ' ') start += 1;
        if (start == line.len) break;
        var end = start;
        while (end < line.len and line[end] != ' ') end += 1;
        if (count >= tokens.len) return error.Args;
        tokens[count] = line[start..end];
        count += 1;
        start = end;
    }
    if (count == 0) return true;
    const name = tokens[0];
    var values: [48]u16 = @splat(0);
    for (1..count) |i| values[i - 1] = try parseNumber(tokens[i]);
    if (io.equal(name, "board") and count == 1) {
        const result = try request(port, .board, &.{});
        if (result.len != 12) return error.Length;
        io.print("board=");
        io.number(result.payload[1]);
        io.print(" revision=");
        io.number(result.payload[2]);
        io.print(" IMU=");
        io.number(result.payload[3]);
        io.print(" CPU_Hz=");
        io.number(p.get32(result.payload[4..8]));
        io.print("\n");
        return true;
    }
    var bench: [48]u8 = undefined;
    var bench_len: usize = 0;
    if (io.equal(name, "io") and count >= 2) {
        bench_len = count - 1;
        for (values[0..bench_len], 0..) |v, i| {
            if (v > 255) return error.Args;
            bench[i] = @intCast(v);
        }
    } else if ((io.equal(name, "buttons") or io.equal(name, "imu") or io.equal(name, "battery") or io.equal(name, "rtc") or io.equal(name, "can-read")) and count == 1) {
        bench[0] = if (io.equal(name, "buttons")) 1 else if (io.equal(name, "imu")) 6 else if (io.equal(name, "battery")) 15 else if (io.equal(name, "rtc")) 13 else 11;
        bench_len = 1;
    } else if (io.equal(name, "adc") and count == 2 and values[0] < 85) {
        bench[0..2].* = .{ 3, @intCast(values[0]) };
        bench_len = 2;
    } else if (io.equal(name, "led") and count == 3 and values[0] >= 2 and values[0] <= 4 and values[1] <= 1) {
        bench[0..3].* = .{ 2, @intCast(values[0] - 1), @intCast(values[1]) };
        bench_len = 3;
    } else if (io.equal(name, "gpio") and count == 4 and values[0] < 85 and values[1] <= 2 and values[2] <= 1) {
        bench[0..4].* = .{ 5, @intCast(values[0]), @intCast(values[1]), @intCast(values[2]) };
        bench_len = 4;
    } else if (io.equal(name, "pwm") and count == 4 and values[0] >= 1 and values[0] <= 6) {
        bench[0] = 4;
        bench[1] = @intCast(values[0] - 1);
        p.put16(bench[2..4], values[1]);
        p.put16(bench[4..6], values[2]);
        bench_len = 6;
    } else if (io.equal(name, "tone") and count == 3) {
        bench[0] = 16;
        p.put16(bench[1..3], values[0]);
        p.put16(bench[3..5], values[1]);
        bench_len = 5;
    } else if (io.equal(name, "can-start") and count == 3 and values[0] <= 3 and values[1] <= 1) {
        bench[0..3].* = .{ 9, @intCast(values[0]), @intCast(values[1]) };
        bench_len = 3;
    } else if ((io.equal(name, "i2c") or io.equal(name, "i2cw")) and count == 5 and values[0] <= 1 and values[1] <= 127 and values[2] <= 255 and values[3] <= 255) {
        const writing = io.equal(name, "i2cw");
        if (!writing and values[3] > 32) return error.Args;
        bench[0..7].* = .{ 7, @intCast(values[0]), @intCast(values[1]), if (writing) 2 else 1, if (writing) 0 else @intCast(values[3]), @intCast(values[2]), if (writing) @intCast(values[3]) else 0 };
        bench_len = if (writing) 7 else 6;
    } else if (io.equal(name, "spi") and count >= 3 and count <= 34 and values[0] <= 1) {
        bench[0] = 8;
        bench[1] = @intCast(values[0]);
        bench_len = count;
        for (values[1 .. count - 1], 0..) |v, i| {
            if (v > 255) return error.Args;
            bench[2 + i] = @intCast(v);
        }
    }
    if (bench_len != 0) {
        const result = try request(port, .board_io, bench[0..bench_len]);
        io.print("reply bytes:");
        for (result.payload[1..result.len]) |v| {
            io.print(" ");
            io.number(v);
        }
        io.print("\n");
        return true;
    }
    if (io.equal(name, "quit") and count == 1) {
        _ = try request(port, .stop, &.{});
        return false;
    }
    if (io.equal(name, "watch") and count == 2 and values[0] <= 1) {
        watch.* = values[0] == 1;
        return true;
    }
    if (io.equal(name, "hello") and count == 1) {
        _ = try request(port, .hello, &.{});
        io.print("SlowWire protocol v1 connected\n");
        return true;
    }
    if (io.equal(name, "stop") and count == 1) {
        _ = try request(port, .stop, &.{});
        return true;
    }
    if (io.equal(name, "arm") and count == 1) {
        _ = try request(port, .arm, &.{});
        return true;
    }
    if (io.equal(name, "run") and count == 2 and values[0] >= 1 and values[0] <= 2) {
        _ = try request(port, .run, &.{@intCast(values[0])});
        return true;
    }
    if (io.equal(name, "provision") and count == 2 and values[0] >= 1 and values[0] <= 3) {
        _ = try request(port, .provision, &.{@intCast(values[0])});
        return true;
    }
    if (count < 2 or values[0] < 1 or values[0] > 3) return error.Args;
    const axis: u8 = @intCast(values[0] - 1);
    if (io.equal(name, "ping") and count == 2) {
        const result = try request(port, .identify, &.{axis});
        io.print("firmware=");
        io.number(result.payload[1]);
        io.print("\n");
        return true;
    }
    if (io.equal(name, "read") and count == 2) {
        const result = try request(port, .telemetry, &.{axis});
        try report(&result);
        return true;
    }
    if ((io.equal(name, "config") or io.equal(name, "jog")) and count == 3) {
        var data: [3]u8 = undefined;
        data[0] = axis;
        p.put16(data[1..3], values[1]);
        _ = try request(port, if (io.equal(name, "config")) .configure else .jog, &data);
        return true;
    }
    if (io.equal(name, "cal") and count == 6) {
        var data: [9]u8 = undefined;
        data[0] = axis;
        for (1..5) |i| p.put16(data[1 + (i - 1) * 2 ..][0..2], values[i]);
        _ = try request(port, .calibrate, &data);
        return true;
    }
    return error.Args;
}
pub fn main() !void {
    const args = try io.Args.load();
    if (args.count != 2 and args.count != 3) {
        io.print("usage: slowwire-host [--openrb|--opencr|--u2d2] COM7 | --self-test\n");
        return error.Args;
    }
    if (io.equal(args.get(1), "--self-test")) {
        var frame: wire.Frame = .{ .seq = 42, .op = .telemetry, .len = 1 };
        frame.payload[0] = 2;
        var encoded: wire.Encoded = .{};
        try wire.encode(&frame, &encoded);
        var got: wire.Frame = .{};
        for (encoded.slice()) |b| _ = receiver.feed(b, &got);
        if (got.seq != 42 or got.payload[0] != 2) return error.SelfTest;
        io.print("host frame self-test PASS\n");
        return;
    }
    const console_mode = try io.consoleStart();
    defer io.consoleRestore(console_mode);
    const direct_mode = args.count == 3 and io.equal(args.get(1), "--u2d2");
    if (args.count == 3 and !direct_mode and !io.equal(args.get(1), "--openrb") and !io.equal(args.get(1), "--opencr")) return error.Args;
    const port_name = args.get(if (args.count == 3) @as(usize, 2) else 1);
    var adapter: z.u2d2.U2d2 = undefined;
    var service: z.service.Service = undefined;
    const port = if (direct_mode) blk: {
        adapter = try z.u2d2.U2d2.open(port_name);
        service = .{ .bus = adapter.bus(), .clock = .{ .context = &clock_context, .now = clockNow, .delay = clockDelay } };
        direct = &service;
        service.stop(false);
        break :blk adapter.handle;
    } else try io.serial(port_name);
    defer io.close(port);
    defer {
        _ = request(port, .stop, &.{}) catch {};
    }
    // CDC open/reset settle. A fresh session never arms or starts motion.
    io.sleep(300);
    _ = try request(port, .hello, &.{});
    _ = try request(port, .heartbeat, &.{});
    io.print("Connected, disarmed. Commands: hello; provision ID (one servo only); ping AXIS; config AXIS mA; read AXIS; cal AXIS low high released engaged; arm; jog AXIS ticks; run 1|2; stop; watch 0|1; quit\nOpenCR bench: board; buttons; led 2|3|4 0|1; adc PIN; gpio PIN MODE VALUE; pwm CHANNEL HZ DUTY; imu; battery; i2c|i2cw CHANNEL ADDRESS REG COUNT|VALUE; spi CHANNEL BYTES; can-start RATE LOOP; can-read; tone HZ MS; rtc; io BYTES\n> ");
    var line: [256]u8 = undefined;
    var len: usize = 0;
    var heartbeat = io.now();
    var sample = io.now();
    var axis: u8 = 0;
    var watch = false;
    while (true) {
        if (direct) |active_service| active_service.tick();
        const now = io.now();
        if (now -% heartbeat >= 100) {
            _ = try request(port, .heartbeat, &.{});
            heartbeat = io.now();
        }
        if (watch and now -% sample >= 150) {
            const f = request(port, .telemetry, &.{axis}) catch {
                watch = false;
                continue;
            };
            try report(&f);
            axis = (axis + 1) % 3;
            sample = io.now();
        }
        if (try io.key()) |key| {
            if (key == 3) {
                _ = try request(port, .stop, &.{});
                break;
            }
            if (key == 13) {
                io.print("\n");
                const keep = command(port, line[0..len], &watch) catch |err| blk: {
                    io.print("command failed: ");
                    io.print(@errorName(err));
                    io.print("\n");
                    break :blk true;
                };
                len = 0;
                if (!keep) break;
                io.print("> ");
            } else if (key == 8) {
                if (len > 0) {
                    len -= 1;
                    io.print("\x08 \x08");
                }
            } else if (key >= 32 and len < line.len) {
                line[len] = key;
                len += 1;
                io.print(&.{key});
            }
        }
        io.sleep(2);
    }
}
