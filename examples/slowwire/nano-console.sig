//! Interactive host bridge: Galaxy projection -> SW v1 -> ATmega328P.
const z = @import("zpm_slowwire");
const context = @import("context_projection");
const io = z.windows;
const p = z.dynamixel2;
const wire = z.link;
var sequence: u16 = 0;
var receiver: wire.Receiver = .{};
fn request(port: io.Handle, op: wire.Op, data: []const u8) !wire.Frame {
    sequence +%= 1;
    var frame: wire.Frame = .{ .seq = sequence, .op = op, .len = data.len };
    @memcpy(frame.payload[0..data.len], data);
    var encoded: wire.Encoded = .{};
    try wire.encode(&frame, &encoded);
    try io.write(port, encoded.slice());
    const start = io.now();
    while (io.now() -% start < 1500) {
        var bytes: [64]u8 = undefined;
        const count = try io.read(port, &bytes);
        for (bytes[0..count]) |byte| {
            var reply: wire.Frame = .{};
            if (receiver.feed(byte, &reply) and reply.seq == sequence and @backingInt(reply.op) == (@backingInt(op) | 0x80)) return reply;
        }
        io.sleep(1);
    }
    return error.Timeout;
}
fn expectOk(frame: wire.Frame) !void {
    if (frame.len == 0 or frame.payload[0] != 0) return error.Device;
}
fn readState(port: io.Handle) !wire.Frame {
    const state = try request(port, .telemetry, "");
    try expectOk(state);
    if (state.len != 16 or p.get16(state.payload[10..12]) == 0 or p.get16(state.payload[10..12]) > 1023) return error.Telemetry;
    return state;
}
fn project(port: io.Handle, state: *const wire.Frame, led: bool) !void {
    const revision: u64 = p.get32(state.payload[1..5]);
    const now: u64 = io.now();
    const refs = [_]context.Stamp{
        .{ .reference = .{ .source = 1, .revision = 1 }, .origin = .policy },
        .{ .reference = .{ .source = 2, .revision = revision }, .origin = .observation },
        .{ .reference = .{ .source = 3, .revision = 1 }, .origin = .owner },
        .{ .reference = .{ .source = 4, .revision = 1 }, .origin = .hypothesis },
    };
    const items = [_]context.Candidate{
        .{ .id = 1, .reference = refs[0].reference, .origin = .policy, .required = true, .full = "Nano exposes LED and internal ADC, zero actuator axes", .relevance = 65535 },
        .{ .id = 2, .reference = refs[1].reference, .origin = .observation, .required = true, .expires = now + 250, .full = "Fresh CRC-checked device telemetry", .relevance = 65535 },
        .{ .id = 3, .reference = refs[2].reference, .origin = .owner, .required = true, .deps = .{ refs[0].reference, refs[1].reference, .{}, .{} }, .dep_count = 2, .full = if (led) "LED=1" else "LED=0", .relevance = 65535 },
        .{ .id = 4, .reference = refs[3].reference, .origin = .hypothesis, .full = "Arm motors", .relevance = 65535 },
    };
    var decisions: [4]context.Decision = undefined;
    var order: [4]usize = undefined;
    _ = try context.compile(&items, &refs, .{ .now = now }, .{ .bytes = 256, .units = 256 }, .{}, &decisions, &order);
    if (decisions[2].form != .full or decisions[3].form != .omitted) return error.Projection;
    try expectOk(try request(port, .board_io, &.{@intFromBool(led)}));
    const verified = try readState(port);
    if (verified.payload[9] != @intFromBool(led)) return error.StateMismatch;
}
fn showState(port: io.Handle) !void {
    const state = try readState(port);
    io.print("LED=");
    io.number(state.payload[9]);
    io.print(" revision=");
    io.number(p.get32(state.payload[1..5]));
    io.print(" uptime_ms=");
    io.number(p.get32(state.payload[5..9]));
    io.print(" ADC_bandgap_raw=");
    io.number(p.get16(state.payload[10..12]));
    io.print(" bad_crc=");
    io.number(p.get32(state.payload[12..16]));
    io.print(" (ADC is not actuator feedback)\n");
}
pub fn main() !void {
    const args = try io.Args.load();
    if (args.count != 2) {
        io.print("Usage: slowwire-nano-console.exe COM9\n");
        return error.Args;
    }
    const mode = try io.consoleStart();
    defer io.consoleRestore(mode);
    const port = try io.serialBaud(args.get(1), 57600);
    defer io.close(port);
    io.sleep(2200); // CH340 DTR resets the Nano into its old bootloader.
    const identify = try request(port, .identify, "");
    try expectOk(identify);
    if (identify.len != 9 or identify.payload[2] != 0x1e or identify.payload[3] != 0x95 or identify.payload[4] != 0x0f or identify.payload[7] != 0) return error.WrongBoard;
    const initial = try readState(port);
    if (initial.payload[9] != 0) {
        try expectOk(try request(port, .stop, ""));
        return error.UnsafeStartup;
    }
    var active = true;
    defer if (active) {
        _ = request(port, .stop, "") catch {};
    };
    try expectOk(try request(port, .heartbeat, ""));
    io.print("Connected to ATmega328P SlowWire v1 at 57600 baud; motors unsupported.\nCommands: help, id, status, on, off, stop, quit\n> ");
    var line: [32]u8 = undefined;
    var length: usize = 0;
    var lastHeartbeat = io.now();
    while (true) {
        if (io.now() -% lastHeartbeat >= 200) {
            try expectOk(try request(port, .heartbeat, ""));
            lastHeartbeat = io.now();
        }
        if (try io.key()) |key| {
            if (key == 3) {
                try expectOk(try request(port, .stop, ""));
                active = false;
                break;
            }
            if (key == 13) {
                io.print("\n");
                const command = line[0..length];
                if (io.equal(command, "quit")) {
                    try expectOk(try request(port, .stop, ""));
                    active = false;
                    break;
                }
                if (io.equal(command, "help")) io.print("help, id, status, on, off, stop, quit\n") else if (io.equal(command, "id")) {
                    io.print("ATmega328P signature=1E950F axes=0\n");
                } else if (io.equal(command, "status")) try showState(port) else if (io.equal(command, "on")) {
                    const state = try readState(port);
                    try project(port, &state, true);
                    io.print("LED on (Galaxy context projection approved; lease 500ms)\n");
                } else if (io.equal(command, "off") or io.equal(command, "stop")) {
                    if (io.equal(command, "stop")) try expectOk(try request(port, .stop, "")) else {
                        const state = try readState(port);
                        try project(port, &state, false);
                    }
                    io.print("LED off\n");
                } else io.print("Unknown command. Type help.\n");
                length = 0;
                io.print("> ");
            } else if (key == 8) {
                if (length > 0) {
                    length -= 1;
                    io.print("\x08 \x08");
                }
            } else if (key >= 32 and length < line.len) {
                line[length] = key;
                length += 1;
                io.print(&.{key});
            }
        }
        io.sleep(2);
    }
}
