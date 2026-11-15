//! gpud: the RTX forwarded to a virtual machine (WSL): a vhost-user device
//! backend (zpm's vhost) whose requests (dxg.fwd) run on the GPU through
//! /dev/dxg (dxg.fwd_server). No libc, no NVIDIA library.
//!
//!   sig build-exe -target x86_64-linux -OReleaseSafe
//!     --dep dxg --dep vhost -Mroot=tools/gpud.sig
//!     --dep nvidia -Mdxg=src/dxg/dxg.sig -Mvhost=src/vhost/vhost.sig
//!     -Mnvidia=src/nvidia/nvidia.sig --name gpud
//!   ./gpud /run/user/$UID/galaxy-gpu.sock &
//!   qemu-system-x86_64 ... -m 4G
//!     -object memory-backend-memfd,id=mem,size=4G,share=on
//!     -machine q35,memory-backend=mem
//!     -chardev socket,id=gpu0,path=/run/user/$UID/galaxy-gpu.sock
//!     -device vhost-user-device-pci,chardev=gpu0,virtio-id=21,num_vqs=1
//!
//! It serves one virtual machine at a time; when it goes away, everything
//! it had is given back and the next one is waited for.

const std = @import("std");
const linux = std.os.linux;
const dxg = @import("dxg");
const vhost = @import("vhost");
const fwd = dxg.fwd;

fn logLine(line: []const u8) void {
    _ = linux.write(2, "gpud: ".ptr, 6);
    _ = linux.write(2, line.ptr, line.len);
    _ = linux.write(2, "\n", 1);
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var b: [256]u8 = undefined;
    logLine(std.fmt.bufPrint(&b, fmt, args) catch return);
}

var g: dxg.Gpu = .{};
var server: dxg.fwd_server.Server = undefined;
var backend: vhost.Backend = .{};

fn guestBytes(_: *anyopaque, gpa: u64, len: u64) ?[]u8 {
    return backend.guestBytes(gpa, len);
}

fn request(_: *anyopaque, _: u32, readable: []const []const u8, writable: []const []u8) u32 {
    if (readable.len < 1 or readable[0].len < @sizeOf(fwd.Request) or writable.len < 1 or writable[0].len < @sizeOf(fwd.Response)) return 0;
    const r = std.mem.bytesToValue(fwd.Request, readable[0][0..@sizeOf(fwd.Request)]);
    const a = server.handle(r);
    @memcpy(writable[0][0..@sizeOf(fwd.Response)], std.mem.asBytes(&a));
    return @sizeOf(fwd.Response);
}

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        logLine("usage: gpud SOCKET");
        linux.exit(2);
    }
    g.open(.{ .name = "galaxy-gpud" }) catch |e| {
        out("no GPU: {s} (call {x}, status {d})", .{ @errorName(e), dxg.kmt.last_nr, dxg.kmt.last_status });
        linux.exit(1);
    };
    out("GPU {x}:{x} through /dev/dxg", .{ g.ids.vendor, g.ids.device });
    const rings_len = fwd.MAX_CHANNELS * dxg.gpu.RING_BYTES;
    const m: isize = @bitCast(linux.mmap(null, rings_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0));
    if (m < 0) linux.exit(1);
    const rings: [*]align(4096) u8 = @ptrFromInt(@as(usize, @intCast(m)));
    var dummy: u8 = 0;
    server.init(&g, .{ .ctx = &dummy, .bytes = guestBytes }, rings[0..rings_len]);
    server.log = logLine;
    backend.log = logLine;
    // (a frame's passes come in bursts: no doorbell each, 2 ms of polling)
    backend.poll_us = 2000;
    backend.listen(std.mem.span(argv[1]), 1) catch {
        out("cannot listen on {s}", .{std.mem.span(argv[1])});
        linux.exit(1);
    };
    out("waiting for a virtual machine on {s}", .{std.mem.span(argv[1])});
    while (true) {
        backend.serve(.{ .ctx = &dummy, .request = request }) catch |e| out("the connection ended: {s}", .{@errorName(e)});
        out("served {d} requests, {d} submissions; giving everything back", .{ server.served, server.submits });
        server.reset();
    }
}
