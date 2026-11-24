//! Experimental cgroup-scoped Linux shortcut for a single 127.0.0.1 TCP service.
//! Attach before opening the listener or client sockets. Close after both
//! endpoints have stopped. Remote peers and unmatched sockets use normal TCP.
const std = @import("std");
const linux = std.os.linux;
const bpf = linux.BPF;
const Insn = bpf.Insn;

pub const Direction = enum { replies, duplex };

// Prefixes of the Linux uapi bpf_sock_ops and sk_msg_md contexts.
const Endpoints = extern struct {
    family: u32,
    remote_ip4: u32,
    local_ip4: u32,
    remote_ip6: [4]u32,
    local_ip6: [4]u32,
    remote_port: u32,
    local_port: u32,
};

const SockOps = extern struct {
    op: u32,
    args: [4]u32,
    endpoints: Endpoints,
};

const Message = extern struct {
    data: u64,
    data_end: u64,
    endpoints: Endpoints,
};

const loopback: i32 = @bitCast(std.mem.nativeToBig(u32, 0x7f000001));
const active_established = 4;
const passive_established = 5;
const sk_pass = 1;
const ingress = 1;
// All eligible flows have one fixed service endpoint and a distinct peer
// port. Use one bank per side and the full u16 port space in each bank.
const server_bank = 1 << 16;
const map_entries = 2 * server_bank;
const reply_verdict_bytes = 1 << 16;

fn field(comptime Context: type, comptime name: []const u8) i16 {
    return @offsetOf(Context, "endpoints") + @offsetOf(Endpoints, name);
}

fn skip(comptime at: i16, comptime destination: i16) i16 {
    return destination - at - 1;
}

fn registration(map: linux.fd_t, service: u16, netns: u64) [31]Insn {
    const done = 29;
    return .{
        Insn.ldx(.word, .r0, .r1, @offsetOf(SockOps, "op")),
        Insn.jeq(.r0, active_established, skip(1, 3)),
        Insn.jne(.r0, passive_established, skip(2, done)),
        Insn.ldx(.word, .r0, .r1, field(SockOps, "remote_ip4")),
        Insn.jne(.r0, loopback, skip(4, done)),
        Insn.ldx(.word, .r0, .r1, field(SockOps, "local_ip4")),
        Insn.jne(.r0, loopback, skip(6, done)),
        Insn.mov(.r6, .r1),
        Insn.call(.get_netns_cookie),
        Insn.ld_dw1(.r2, netns),
        Insn.ld_dw2(netns),
        Insn.jne(.r0, .r2, skip(11, done)),
        Insn.mov(.r1, .r6),
        Insn.ldx(.word, .r2, .r1, field(SockOps, "local_port")),
        Insn.ldx(.word, .r3, .r1, field(SockOps, "remote_port")),
        Insn.be(.word, .r3),
        Insn.jeq(.r2, @as(i32, service), skip(16, 19)),
        Insn.jne(.r3, @as(i32, service), skip(17, done)),
        Insn.ja(skip(18, 22)),
        Insn.jeq(.r3, @as(i32, service), skip(19, done)),
        Insn.mov(.r2, .r3),
        Insn.add(.r2, server_bank),
        Insn.stx(.word, .r10, -4, .r2),
        Insn.ld_map_fd1(.r2, map),
        Insn.ld_map_fd2(map),
        Insn.mov(.r3, .r10),
        Insn.add(.r3, -4),
        Insn.mov(.r4, 1), // BPF_NOEXIST
        Insn.call(.sock_map_update),
        Insn.mov(.r0, 1),
        Insn.exit(),
    };
}

fn verdict(map: linux.fd_t, service: u16, direction: Direction) [20]Insn {
    const done = 18;
    return .{
        // Only registered sockets reach this program. Their endpoint
        // addresses, service port and network namespace are already fixed.
        Insn.ldx(.word, .r2, .r1, field(Message, "local_port")),
        if (direction == .replies) Insn.jne(.r2, @as(i32, service), skip(1, done)) else
            Insn.jeq(.r2, @as(i32, service), skip(1, 4)),
        if (direction == .replies) Insn.ja(0) else Insn.add(.r2, server_bank),
        if (direction == .replies) Insn.ja(0) else Insn.ja(skip(3, 6)),
        Insn.ldx(.word, .r2, .r1, field(Message, "remote_port")),
        Insn.be(.word, .r2),
        Insn.mov(.r3, .r2),
        Insn.ld_map_fd1(.r2, map),
        Insn.ld_map_fd2(map),
        Insn.mov(.r4, ingress),
        Insn.mov(.r6, .r1),
        Insn.call(.msg_redirect_map),
        // Requests resolve their peer for every send. Only successful
        // server replies retain a bounded verdict.
        Insn.jne(.r0, sk_pass, skip(12, done)),
        Insn.ldx(.word, .r2, .r6, field(Message, "local_port")),
        Insn.jne(.r2, @as(i32, service), skip(14, done)),
        Insn.mov(.r1, .r6),
        Insn.mov(.r2, reply_verdict_bytes),
        Insn.call(.msg_apply_bytes),
        // The helper sets the redirect only if the matching peer exists.
        Insn.mov(.r0, sk_pass),
        Insn.exit(),
    };
}

fn checked(result: usize) !linux.fd_t {
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .ACCES, .PERM => error.PermissionDenied,
        .INVAL, .OPNOTSUPP, .NOSYS => error.SocketMapUnavailable,
        .NOMEM => error.SystemResources,
        else => error.SocketMapFailed,
    };
}

fn attachType(map: linux.fd_t, program: linux.fd_t, command: bpf.Cmd) !void {
    var attr: bpf.Attr = .{ .prog_attach = .{
        .target_fd = map,
        .attach_bpf_fd = program,
        .attach_type = @intFromEnum(bpf.AttachType.sk_msg_verdict),
        .attach_flags = 0,
        .replace_bpf_fd = 0,
    } };
    _ = try checked(linux.bpf(command, &attr, @sizeOf(bpf.ProgAttachAttr)));
}

fn netnsCookie() !u64 {
    const socket = try checked(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(socket);
    var cookie: u64 = 0;
    var length: linux.socklen_t = @sizeOf(u64);
    const so_netns_cookie = 71; // Linux UAPI SO_NETNS_COOKIE
    _ = try checked(linux.getsockopt(socket, linux.SOL.SOCKET, so_netns_cookie, @ptrCast(&cookie), &length));
    if (length != @sizeOf(u64) or cookie == 0) return error.SocketMapUnavailable;
    return cookie;
}

pub const Shortcut = struct {
    sockets: linux.fd_t,
    message: linux.fd_t,
    cgroup_link: linux.fd_t,

    /// Both endpoints must open their sockets in the supplied dedicated
    /// cgroup-v2 directory. The kernel owns a fixed two-bank port map.
    /// All userspace instructions and log storage are fixed-size or caller-owned.
    pub fn init(cgroup: linux.fd_t, service: u16, direction: Direction, log: *bpf.Log) !Shortcut {
        if (service == 0) return error.InvalidSocketMap;
        const netns = try netnsCookie();
        const sockets = try bpf.map_create(.sockmap, 4, 4, map_entries);
        errdefer _ = linux.close(sockets);
        const message = try bpf.prog_load(.sk_msg, &verdict(sockets, service, direction), log, "GPL", 0, 0);
        errdefer _ = linux.close(message);
        try attachType(sockets, message, .prog_attach);
        errdefer attachType(sockets, message, .prog_detach) catch {};
        const ops = try bpf.prog_load(.sock_ops, &registration(sockets, service, netns), log, "GPL", 0, 0);
        defer _ = linux.close(ops);
        var link: bpf.Attr = .{ .link_create = .{
            .prog_fd = ops,
            .target_fd = cgroup,
            .attach_type = @intFromEnum(bpf.AttachType.cgroup_sock_ops),
            .flags = 0,
        } };
        const cgroup_link = try checked(linux.bpf(.link_create, &link, @sizeOf(bpf.LinkCreateAttr)));
        return .{ .sockets = sockets, .message = message, .cgroup_link = cgroup_link };
    }

    pub fn deinit(self: Shortcut) !void {
        _ = linux.close(self.cgroup_link);
        defer _ = linux.close(self.sockets);
        defer _ = linux.close(self.message);
        try attachType(self.sockets, self.message, .prog_detach);
    }
};
