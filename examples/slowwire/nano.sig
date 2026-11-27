//! Native Sig Nano I/O bring-up. No actuator driver is advertised or enabled.
const z = @import("zpm_slowwire");
const hw = z.nano;
const wire = z.link;
const p = z.dynamixel2;
comptime {
    asm (
        \\.section .vectors,"ax",@progbits
        \\.global _reset
        \\_reset:
        \\  jmp nano_reset
        \\  .rept 25
        \\  jmp nano_reset
        \\  .endr
        \\.text
        \\nano_reset:
        \\  cli
        \\  clr r1
        \\  out 0x3f, r1
        \\  ldi r16, 8
        \\  out 0x3e, r16
        \\  ldi r16, 255
        \\  out 0x3d, r16
        \\  wdr
        \\  out 0x34, r1
        \\  ldi r16, 24
        \\  sts 0x60, r16
        \\  sts 0x60, r1
        \\  ldi r26, lo8(__data_start)
        \\  ldi r27, hi8(__data_start)
        \\  ldi r30, lo8(__data_load_start)
        \\  ldi r31, hi8(__data_load_start)
        \\  ldi r24, lo8(__data_end)
        \\  ldi r25, hi8(__data_end)
        \\1: cp r26, r24
        \\  cpc r27, r25
        \\  breq 2f
        \\  lpm r0, Z+
        \\  st X+, r0
        \\  rjmp 1b
        \\2: ldi r26, lo8(__bss_start)
        \\  ldi r27, hi8(__bss_start)
        \\  ldi r24, lo8(__bss_end)
        \\  ldi r25, hi8(__bss_end)
        \\3: cp r26, r24
        \\  cpc r27, r25
        \\  breq 4f
        \\  st X+, r1
        \\  rjmp 3b
        \\4: call nano_main
        \\  rjmp nano_reset
        \\.global memcpy
        \\memcpy:
        \\  movw r26, r24
        \\  movw r30, r22
        \\5: cp r20, r1
        \\  cpc r21, r1
        \\  breq 6f
        \\  ld r0, Z+
        \\  st X+, r0
        \\  subi r20, 1
        \\  sbci r21, 0
        \\  rjmp 5b
        \\6: ret
    );
}
pub fn panic(_: []const u8, _: ?usize) noreturn {
    hw.led(false);
    while (true) {}
}
var receiver: wire.Receiver = .{};
var request: wire.Frame = .{};
var response: wire.Frame = .{};
var encoded: wire.Encoded = .{};
var clock: u32 = 0;
var revision: u32 = 1;
var lease: u32 = 0;
var lit = false;
fn pollTime() void {
    if (hw.tick()) clock +%= 1;
    if (lit and clock -% lease >= 500) {
        lit = false;
        hw.led(false);
        revision +%= 1;
    }
}
fn reply() void {
    wire.encode(&response, &encoded) catch return;
    for (encoded.slice()) |byte| {
        while (!hw.ready()) pollTime();
        hw.send(byte);
    }
}
fn process() void {
    response.seq = request.seq;
    response.op = @fromBackingInt(@as(u8, @backingInt(request.op)) | 0x80);
    response.len = 1;
    response.payload[0] = 0;
    switch (request.op) {
        .hello, .identify, .board => {
            if (request.len != 0) {
                response.payload[0] = 1;
                return reply();
            }
            response.len = 9;
            // status, ABI, processor signature, capabilities LE16 (LED + internal ADC + capacitive electrode), axes.
            response.payload[0..9].* = .{ 0, 1, 0x1e, 0x95, 0x0f, 7, 0, 0, 0 };
        },
        .heartbeat => {
            if (request.len != 0) response.payload[0] = 1 else lease = clock;
        },
        .stop => {
            lit = false;
            hw.led(false);
            revision +%= 1;
        },
        .board_io => {
            if (request.len != 1 or request.payload[0] > 1) response.payload[0] = 1 else {
                lit = request.payload[0] == 1;
                hw.led(lit);
                lease = clock;
                revision +%= 1;
            }
        },
        .capacitive_read => {
            // Sensor electrode is on A0; D2 excites it through an external high-value resistor.
            if (request.len != 1 or request.payload[0] != 0) {
                response.payload[0] = 1;
            } else {
                const sample = hw.capacitiveRead();
                response.len = 6;
                response.payload[1] = 0; // sensor electrode A0
                response.payload[2] = 1; // charge-count algorithm version
                response.payload[3] = @intFromBool(sample.discharged) | (@as(u8, @intFromBool(sample.charged)) << 1);
                p.put16(response.payload[4..6], sample.ticks);
            }
        },
        .telemetry => {
            if (request.len != 0) {
                response.payload[0] = 1;
                return reply();
            }
            hw.adcStart();
            while (!hw.adcReady()) pollTime();
            response.len = 16;
            p.put32(response.payload[1..5], revision);
            p.put32(response.payload[5..9], clock);
            response.payload[9] = @intFromBool(lit);
            p.put16(response.payload[10..12], hw.adcRead());
            p.put32(response.payload[12..16], receiver.bad);
        },
        else => response.payload[0] = 2, // Unsupported, including arm/jog/run.
    }
    reply();
}
export fn nano_main() noreturn {
    hw.init();
    while (true) {
        pollTime();
        if (hw.receive()) |byte| {
            if (receiver.feed(byte, &request)) process();
        }
    }
}
