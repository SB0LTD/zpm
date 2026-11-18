//! Linux runtime coverage for fixed socket completion ownership.
const std = @import("std");
const builtin = @import("builtin");
const tcp = @import("tcp_server");
const linux = std.os.linux;
const completion = @import("tcp_completion");
const Queue = completion.Queue(2);
var assertions: usize = 0;
var raw: [4]linux.io_uring_cqe = undefined;
var events: [4]completion.Completion = undefined;
var sent: [64 * 1024]u8 = undefined;
var received: [64 * 1024]u8 = undefined;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("TCP completion assertion {d} failed\n", .{assertions});
        return error.ContractFailed;
    }
}

fn pair(nonblocking: bool) ![2]linux.fd_t {
    var sockets: [2]linux.fd_t = undefined;
    const flags = linux.SOCK.STREAM | linux.SOCK.CLOEXEC | (if (nonblocking) linux.SOCK.NONBLOCK else 0);
    if (linux.errno(linux.socketpair(linux.AF.UNIX, flags, 0, &sockets)) != .SUCCESS)
        return error.SocketPair;
    return sockets;
}

fn next(q: *Queue) !completion.Completion {
    try check(try q.complete(raw[0..1], events[0..1], true) == 1);
    return events[0];
}

fn loopback(q: *Queue) !void {
    const listener = try tcp.listen(.{127,0,0,1}, 0);
    defer tcp.close(listener);
    const raw_peer = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    try check(linux.errno(raw_peer) == .SUCCESS);
    const peer: linux.fd_t = @intCast(raw_peer);
    defer tcp.close(peer);
    const port = try tcp.localPort(listener);
    const host_port = if (builtin.cpu.arch.endian() == .little) @byteSwap(port) else port;
    const address: linux.sockaddr.in = .{ .port=host_port, .addr=@bitCast([4]u8{127,0,0,1}) };
    try check(linux.errno(linux.connect(peer, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) == .SUCCESS);
    var ready: [0]bool = .{};
    try check(try tcp.wait(listener, &.{}, &ready, &ready, 1000));
    const server = (try tcp.accept(listener)) orelse return error.ExpectedConnection;
    defer tcp.close(server);
    var buf: [8]u8 = undefined;
    try q.receive(0, server, &buf);
    _ = try q.submit();
    try check((try tcp.send(peer,"native")) == 6);
    const received_request = try next(q);
    try check(received_request.outcome == .bytes and received_request.outcome.bytes == 6 and std.mem.eql(u8,buf[0..6],"native"));
    try q.send(0, server, "completed");
    _ = try q.submit();
    const sent_reply = try next(q);
    try check(sent_reply.outcome == .bytes and sent_reply.outcome.bytes == 9);
    var reply: [9]u8 = undefined;
    var at: usize = 0;
    while (at < reply.len) {
        const got = linux.read(peer, reply[at..].ptr, reply.len-at);
        try check(linux.errno(got) == .SUCCESS and got != 0);
        at += got;
    }
    try check(std.mem.eql(u8,&reply,"completed"));
}

pub fn main() !void {
    var q = try Queue.init();
    try loopback(&q);
    const sockets = try pair(true);
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);
    const send_budget: c_int = 4096;
    try check(linux.errno(linux.setsockopt(sockets[0], linux.SOL.SOCKET, linux.SO.SNDBUF, @ptrCast(&send_budget), @sizeOf(c_int))) == .SUCCESS);

    for (&sent, 0..) |*byte, i| byte.* = @truncate(i);
    var offset: usize = 0;
    var partial = false;
    while (offset < sent.len) {
        try q.send(0, sockets[0], sent[offset..]);
        try check(!q.reusable(0) and q.reusable(1));
        if (q.deinit()) |_| return error.PrematureClose else |err| try check(err == error.PendingSocketOperations);
        if (q.send(0, sockets[0], sent[0..1])) |_| return error.ReusedSlot else |err| try check(err == error.SocketSlotBusy);
        _ = try q.submit();
        const event = try next(&q);
        try check(event.operation == .send and event.slot == 0 and event.outcome == .bytes);
        const n = event.outcome.bytes;
        partial = partial or n < sent.len - offset;
        const end = offset + n;
        while (offset < end) {
            const got = linux.read(sockets[1], received[offset..end].ptr, end - offset);
            try check(linux.errno(got) == .SUCCESS and got != 0);
            offset += got;
        }
        try check(q.reusable(0));
    }
    try check(partial and std.mem.eql(u8, &sent, &received));

    var recv_buf: [32]u8 = undefined;
    try q.receive(1, sockets[1], &recv_buf);
    _ = try q.submit();
    try check(linux.write(sockets[0], "ok", 2) == 2);
    const bytes = try next(&q);
    try check(bytes.slot == 1 and bytes.operation == .receive and bytes.outcome == .bytes and
        bytes.outcome.bytes == 2 and std.mem.eql(u8, recv_buf[0..2], "ok"));

    const cancel_pair = try pair(false);
    defer _ = linux.close(cancel_pair[0]);
    defer _ = linux.close(cancel_pair[1]);
    try q.receive(1, cancel_pair[1], &recv_buf);
    _ = try q.submit();
    try check(try q.complete(&raw, &events, false) == 0);
    try check(try q.cancel(1));
    try check(!try q.cancel(1) and !q.reusable(1));
    _ = try q.submit();
    var canceled = false;
    var acknowledged = false;
    var count: usize = 0;
    while (count < 2) {
        const ready = try q.complete(&raw, &events, true);
        count += ready;
        for (events[0..ready]) |event| {
            try check(event.slot == 1);
            if (event.operation == .receive and event.outcome == .canceled) canceled = true;
            if (event.operation == .cancel and event.outcome == .cancel_accepted) acknowledged = true;
        }
    }
    try check(canceled and acknowledged and q.reusable(1));
    try q.send(1, cancel_pair[0], "race");
    _ = try q.submit();
    try check(try q.cancel(1));
    _ = try q.submit();
    const first = try next(&q);
    try check(!q.reusable(1));
    const second = try next(&q);
    try check(first.operation != second.operation and q.reusable(1));
    const cancel_result = if (first.operation == .cancel) first.outcome else second.outcome;
    const send_result = if (first.operation == .send) first.outcome else second.outcome;
    try check((cancel_result == .cancel_raced and send_result == .bytes) or
        (cancel_result == .cancel_accepted and send_result == .canceled));

    try check(linux.errno(linux.shutdown(sockets[0], linux.SHUT.WR)) == .SUCCESS);
    try q.receive(1, sockets[1], &recv_buf);
    _ = try q.submit();
    const eof = try next(&q);
    try check(eof.slot == 1 and eof.operation == .receive and eof.outcome == .eof);
    try q.send(0, sockets[0], "closed");
    _ = try q.submit();
    const failed = try next(&q);
    try check(failed.slot == 0 and failed.operation == .send and failed.outcome == .failed and failed.outcome.failed == .PIPE);
    try q.deinit();
    std.debug.print("PASS Linux TCP completions: {d} assertions\n", .{assertions});
}
