// A real child process: emit argv as one hex record per argument, then fail.
// Its exact output and exit status are checked by test_cli_forwarding.py.
const std = @import("std");
const process = @import("sig_process");
var decoded: [98_304]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = process.Argv_Iterator.init(init.args.vector, &decoded);
    _ = args.next() catch return 90;
    while (args.next() catch return 91) |arg| {
        for (arg) |byte| std.debug.print("{x:0>2}", .{byte});
        std.debug.print("\n", .{});
    }
    return 37;
}
