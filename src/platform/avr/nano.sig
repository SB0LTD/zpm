//! ATmega328P Nano, 16 MHz. USB-UART is the host link, never the motor bus.
fn reg(address: usize) *volatile u8 {
    return @ptrFromInt(address);
}
pub fn init() void {
    // Outputs other than the onboard LED remain inputs without pull-ups.
    reg(0x24).* = 0x20;
    reg(0x25).* = 0;
    reg(0x27).* = 0;
    reg(0x28).* = 0;
    reg(0x2a).* = 0;
    reg(0x2b).* = 0;
    reg(0xc0).* = 2;
    reg(0xc4).* = 34;
    reg(0xc5).* = 0; // 57143 baud, -0.79% from 57600.
    reg(0xc2).* = 6;
    reg(0xc1).* = 0x18; // 8N1, RX/TX, no interrupts.
    reg(0x44).* = 2;
    reg(0x45).* = 3;
    reg(0x46).* = 0;
    reg(0x47).* = 249;
    reg(0x35).* = 7;
    reg(0x6e).* = 0; // Timer0 CTC, 1 ms, polling.
    reg(0x7c).* = 0x4e;
    reg(0x7a).* = 0x87; // AVcc reference, internal bandgap, /128.
}
pub fn led(on: bool) void {
    reg(0x25).* = if (on) 0x20 else 0;
}
pub fn tick() bool {
    if (reg(0x35).* & 2 == 0) return false;
    reg(0x35).* = 2;
    return true;
}
pub fn receive() ?u8 {
    const status = reg(0xc0).*;
    if (status & 0x80 == 0) return null;
    const value = reg(0xc6).*;
    if (status & 0x1c != 0) return null; // Frame, overrun and parity errors.
    return value;
}
pub fn ready() bool {
    return reg(0xc0).* & 0x20 != 0;
}
pub fn send(byte: u8) void {
    reg(0xc6).* = byte;
}
pub fn adcStart() void {
    reg(0x7c).* = 0x4e; // AVcc reference, internal bandgap channel.
    reg(0x7a).* |= 0x40;
}
pub fn adcReady() bool {
    return reg(0x7a).* & 0x40 == 0;
}
pub fn adcRead() u16 {
    const low = reg(0x78).*;
    return @as(u16, low) | (@as(u16, reg(0x79).*) << 8);
}
pub const CapacitiveSample = struct { ticks: u16 = 0, discharged: bool = true, charged: bool = true };
/// Four charge-time readings on A0, driven through the external high-value resistor from D2.
/// The result is a relative loop-count signal, not calibrated capacitance. Flags distinguish
/// a node held high from a node that never charges, so wiring faults are visible to the host.
pub fn capacitiveRead() CapacitiveSample {
    var total: u32 = 0;
    var result: CapacitiveSample = .{};
    for (0..4) |_| {
        reg(0x27).* &= 0xfe; // A0 input.
        reg(0x28).* &= 0xfe; // No A0 pull-up.
        reg(0x2b).* &= 0xfb;
        reg(0x2a).* |= 0x04; // D2 drives the excitation only after being set low.
        var discharge: u16 = 0;
        while (discharge < 8192 and reg(0x26).* & 0x01 != 0) : (discharge += 1) {}
        if (reg(0x26).* & 0x01 != 0) {
            result.discharged = false;
            continue;
        }
        reg(0x2b).* |= 0x04;
        var ticks: u16 = 0;
        while (ticks < 4095 and reg(0x26).* & 0x01 == 0) : (ticks += 1) {}
        if (reg(0x26).* & 0x01 == 0) result.charged = false;
        total += ticks;
        reg(0x2b).* &= 0xfb;
    }
    result.ticks = @intCast(total / 4);
    return result;
}
