//! Compile-only API coverage object. Has no entry point and is never flashed/executed.
const board = @import("opencr");
fn poll() void {
    board.board.idle();
}
export fn opencr_compile_coverage() callconv(.c) void {
    // Force analysis/codegen of peripheral APIs outside the default USB device fixture.
    var usb_host = board.usb_host.Host.init(poll) catch return;
    var descriptor: [18]u8 = undefined;
    usb_host.enumerate(&descriptor) catch return;
    var rx: [8]u8 = undefined;
    _ = usb_host.packetTransfer(.{ .address = 1, .number = 1, .input = true, .max_packet = 8, .kind = .interrupt }, 0, &.{}, &rx, 25) catch return;
    board.flash.erase(poll) catch return;
    board.flash.program(0, &.{ 1, 2, 3, 4 }, poll) catch return;
    board.rtc.writeBackup(0, 1) catch return;
    board.io.edge(.{ .port = 6, .bit = 6 }, true, true);
    _ = board.io.takeEdge(.{ .port = 6, .bit = 6 });
    var uart = board.uart.Uart.init(.bt2, 115200, poll) catch return;
    uart.flush();
    var can = board.can.Can.init(500_000, true, poll) catch return;
    _ = can.errorState();
}
pub fn panic(_: []const u8, _: ?usize) noreturn {
    while (true) poll();
}
