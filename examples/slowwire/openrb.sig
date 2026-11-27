//! Full Sig OpenRB-150 firmware; application begins at 0x2000. Boot disarmed, no automatic gait or calibration.
const z = @import("zpm_slowwire");
const hw = z.samd21.board;
const p = z.dynamixel2;
const xl = z.xl330;
const wire = z.link;
extern var _data_start: u8;
extern var _data_end: u8;
extern var _data_load: u8;
extern var _bss_start: u8;
extern var _bss_end: u8;
const Handler = *const fn () callconv(.c) void;
const Vectors = extern struct { sp: u32, reset: *const fn () callconv(.naked) noreturn, handlers: [14]Handler };
export const vectors: Vectors align(256) linksection(".vectors") = .{ .sp = 0x20008000, .reset = _reset, .handlers = @splat(fault) };
export fn _reset() callconv(.naked) noreturn {
    asm volatile ("cpsid i\n bl startup\n b .");
}
export fn fault() callconv(.c) void {
    hw.power(false);
    while (true) hw.cycles();
}
pub fn panic(_: []const u8, _: ?usize) noreturn {
    fault();
    unreachable;
}
export fn startup() noreturn {
    hw.quiesce();
    const dest: [*]u8 = @ptrCast(&_data_start);
    const source: [*]const u8 = @ptrCast(&_data_load);
    var i: usize = 0;
    while (i < @intFromPtr(&_data_end) - @intFromPtr(&_data_start)) : (i += 1) dest[i] = source[i];
    const bss: [*]u8 = @ptrCast(&_bss_start);
    i = 0;
    while (i < @intFromPtr(&_bss_end) - @intFromPtr(&_bss_start)) : (i += 1) bss[i] = 0;
    hw.init();
    usb.init();
    uart = z.samd21.uart.Uart.init(pollUsb);
    service = .{ .bus = bus(), .clock = .{ .context = &clock_context, .now = clockNow, .delay = delay, .power = setPower }, .powered = false };
    loop();
}
var usb: z.samd21.usb.Usb = .{};
var uart: z.samd21.uart.Uart = undefined;
var service: z.service.Service = undefined;
var clock_context: u8 = 0;
var receiver: wire.Receiver = .{};
var response: wire.Encoded = .{};
var response_pending: bool = false;
var last_request: wire.Frame = .{};
var have_sequence = false;
var epoch: u32 = 0;
var dtr = false;
fn pollUsb() void {
    usb.poll();
}
fn bus() xl.Bus {
    return uart.bus();
}
fn clockNow(_: *anyopaque) u32 {
    return hw.millis();
}
fn delay(_: *anyopaque, ms: u32) void {
    const begin = hw.millis();
    while (hw.millis() -% begin < ms) usb.poll();
}
fn shutDown(latch: bool) void {
    service.stop(latch);
}
fn same(a: *const wire.Frame, b: *const wire.Frame) bool {
    if (a.op != b.op or a.len != b.len) return false;
    for (a.payload[0..a.len], b.payload[0..b.len]) |x, y| if (x != y) return false;
    return true;
}
fn handle(f: *const wire.Frame) void {
    // STOP remains available even if the sequence is stale.
    if (f.op == .stop) shutDown(false);
    if (have_sequence) {
        const distance = f.seq -% last_request.seq;
        if (distance == 0 and same(f, &last_request)) {
            response_pending = true;
            return;
        }
        if (distance == 0 or distance >= 32768) return;
    }
    var r: wire.Frame = .{ .seq = f.seq, .op = @fromBackingInt(@intCast(@backingInt(f.op) | 0x80)), .len = 1 };
    r.payload[0] = 0;
    service.execute(f, &r) catch |err| {
        r.payload[0] = switch (err) {
            error.Range => 2,
            error.Busy => 3,
            error.NotArmed, error.Uncalibrated, error.Unconfigured => 4,
            error.Timeout => 5,
            error.Stale, error.Fault => 6,
            error.Model => 7,
            else => 1,
        };
        r.len = 1;
        shutDown(true);
    };
    wire.encode(&r, &response) catch unreachable;
    response_pending = true;
    last_request = f.*;
    have_sequence = true;
}
fn loop() noreturn {
    while (true) {
        usb.poll();
        if (usb.epoch != epoch or usb.control.dtr != dtr) {
            epoch = usb.epoch;
            dtr = usb.control.dtr;
            shutDown(false);
            have_sequence = false;
            receiver.reset();
            response_pending = false;
            service.controller.has_host = false;
        }
        if (usb.rx_overflow) {
            usb.rx_overflow = false;
            receiver.reset();
            shutDown(true);
        }
        if (!response_pending) {
            while (usb.receive()) |byte| {
                var f: wire.Frame = .{};
                if (receiver.feed(byte, &f)) {
                    if (usb.control.dtr) handle(&f);
                    break;
                }
            }
        }
        if (response_pending and usb.send(response.slice())) response_pending = false;
        const now = hw.millis();
        service.tick();
        hw.led(service.controller.state == .armed or service.controller.state == .running or (now / 500) % 2 == 0);
    }
}

fn setPower(_: *anyopaque, on: bool) void {
    hw.power(on);
}
