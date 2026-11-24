//! The guest's side of Hyper-V's virtual PCI bus (PCI pass-through, the
//! "vPCI" VMBus device): enough to reach the config space of the one
//! function behind it. A machine given a partition of the host's GPU has
//! one, a function of vendor 0x1414 (Microsoft's virtual render device)
//! whose config space carries dxgkrnl's interface version and the host's
//! capabilities (gpu.sig's pciHandshake).
//!
//! The protocol is Linux's pci-hyperv.c's, restated (documentation only):
//! the version agreed (QUERY_PROTOCOL_VERSION, newest first), the bus's
//! functions asked for (QUERY_BUS_RELATIONS; the host answers with a
//! BUS_RELATIONS packet of its own), each function's resource needs, the
//! bus put in D0 with the address of the guest's config window (8 KiB of
//! MMIO: a page that selects the function, a page that is its config
//! space), the resources assigned (none here: no BAR is used). A config
//! access writes the function's slot to the window's first page, then reads
//! or writes the second page at the register's offset; the host traps both.
//!
//! Zero allocation, freestanding; the channel is vmbus.sig's.

const std = @import("std");
const vmbus = @import("vmbus.sig");

pub const KIND = vmbus.guid("44c4f61d-4444-4400-9d52-802e27ede19f");
/// Each ring: 16 KiB of data and its header page, as Linux's.
pub const RING_PAGES: u32 = 5;
/// The config window: the slot page, then the config page.
pub const WINDOW_BYTES: u64 = 0x2000;
pub const CONFIG_PAGE: u64 = 0x1000;

pub const VERSIONS = [_]u32{ 0x0001_0004, 0x0001_0003, 0x0001_0002, 0x0001_0001 };
const STATUS_REVISION_MISMATCH: i32 = @bitCast(@as(u32, 0xC000_0059));

pub const MESSAGE_BASE: u32 = 0x4249_0000;
pub const msg = struct {
    pub const BUS_RELATIONS: u32 = MESSAGE_BASE + 0x00;
    pub const QUERY_BUS_RELATIONS: u32 = MESSAGE_BASE + 0x01;
    pub const QUERY_RESOURCE_REQUIREMENTS: u32 = MESSAGE_BASE + 0x05;
    pub const BUS_D0ENTRY: u32 = MESSAGE_BASE + 0x07;
    pub const RESOURCES_ASSIGNED: u32 = MESSAGE_BASE + 0x10;
    pub const QUERY_PROTOCOL_VERSION: u32 = MESSAGE_BASE + 0x13;
    pub const RESOURCES_ASSIGNED2: u32 = MESSAGE_BASE + 0x16;
    pub const BUS_RELATIONS2: u32 = MESSAGE_BASE + 0x19;
};

/// A function on the bus, as BUS_RELATIONS describes it (20 bytes; 28 in
/// BUS_RELATIONS2, flags and a NUMA node after).
pub const Function = struct {
    vendor: u16 = 0,
    device: u16 = 0,
    revision: u8 = 0,
    class: u8 = 0,
    subclass: u8 = 0,
    subsystem: u32 = 0,
    /// win_slot: device number in bits 0-4, function in bits 5-7.
    slot: u32 = 0,
    serial: u32 = 0,
};

pub const Error = error{
    /// The host did not answer in time (or the ring was full).
    NoAnswer,
    /// No protocol version this guest speaks was accepted.
    NoVersion,
    /// The host refused a step (its NTSTATUS in `status`).
    Refused,
    /// The bus has no function.
    NoFunction,
};

pub const Step = enum { version, relations, requirements, d0, resources };

/// The host's MMIO the config window is in: `mmio32(addr)` a pointer to
/// a u32 there (mapped uncached by the caller).
pub fn Pci(comptime Host: type) type {
    return struct {
        const Self = @This();
        pub const Channel = vmbus.Channel(Host);

        ch: Channel,
        version: u32 = 0,
        /// The config window's address (WINDOW_BYTES of the machine's MMIO,
        /// mapped uncached).
        window: u64 = 0,
        function: Function = .{},
        functions: u32 = 0,
        bars: [6]u32 = @splat(0),
        status: i32 = 0,
        failed: ?Step = null,
        rx: [2048]u8 align(8) = undefined,

        const TIMEOUT_US: u32 = 5_000_000;

        /// A message the host completes; the completion's NTSTATUS (its
        /// body, first word; `out` the rest of it when given).
        fn call(self: *Self, bytes: []const u8, out: ?[]u8) Error!i32 {
            const id = self.ch.send(bytes, true) orelse return error.NoAnswer;
            var waited: u32 = 0;
            while (waited < TIMEOUT_US) {
                while (self.ch.receive(&self.rx)) |p| {
                    if (p.kind == vmbus.pkt.COMPLETION and p.id == id) {
                        if (p.body.len < 4) return error.NoAnswer;
                        if (out) |o| {
                            const n = @min(o.len, p.body.len - 4);
                            @memcpy(o[0..n], p.body[4..][0..n]);
                        }
                        return std.mem.readInt(i32, p.body[0..4], .little);
                    }
                    self.inband(p);
                }
                self.ch.host.delayUs(20);
                waited += 20;
            }
            return error.NoAnswer;
        }

        /// The host's own packet: its bus relations kept (the first
        /// function), anything else not waited for here.
        fn inband(self: *Self, p: vmbus.Packet) void {
            if (p.kind != vmbus.pkt.DATA_INBAND or p.body.len < 8) return;
            const t = std.mem.readInt(u32, p.body[0..4], .little);
            if (t != msg.BUS_RELATIONS and t != msg.BUS_RELATIONS2) return;
            const n = std.mem.readInt(u32, p.body[4..8], .little);
            const size: usize = if (t == msg.BUS_RELATIONS2) 28 else 20;
            self.functions = n;
            if (n == 0 or p.body.len < 8 + size) return;
            const f = p.body[8..];
            self.function = .{
                .vendor = std.mem.readInt(u16, f[0..2], .little),
                .device = std.mem.readInt(u16, f[2..4], .little),
                .revision = f[4],
                .subclass = f[6],
                .class = f[7],
                .subsystem = std.mem.readInt(u32, f[8..12], .little),
                .slot = std.mem.readInt(u32, f[12..16], .little),
                .serial = std.mem.readInt(u32, f[16..20], .little),
            };
            self.functions = n;
        }

        fn step(self: *Self, s: Step, status: i32) Error!void {
            self.status = status;
            if (status < 0) {
                self.failed = s;
                return error.Refused;
            }
        }

        /// The bus brought up with its config window at `window`
        /// (WINDOW_BYTES of MMIO, page-aligned, mapped uncached).
        pub fn start(self: *Self, window: u64) Error!void {
            self.window = window;
            self.failed = .version;
            var buf: [256]u8 align(8) = @splat(0);
            for (VERSIONS) |v| {
                std.mem.writeInt(u32, buf[0..4], msg.QUERY_PROTOCOL_VERSION, .little);
                std.mem.writeInt(u32, buf[4..8], v, .little);
                const st = try self.call(buf[0..8], null);
                if (st >= 0) {
                    self.version = v;
                    break;
                }
                self.status = st;
                if (st != STATUS_REVISION_MISMATCH) return error.Refused;
            } else return error.NoVersion;

            // the functions: the host answers with a packet of its own
            self.failed = .relations;
            std.mem.writeInt(u32, buf[0..4], msg.QUERY_BUS_RELATIONS, .little);
            _ = self.ch.send(buf[0..4], false) orelse return error.NoAnswer;
            var waited: u32 = 0;
            while (self.functions == 0 and waited < TIMEOUT_US) {
                while (self.ch.receive(&self.rx)) |p| self.inband(p);
                if (self.functions != 0) break;
                self.ch.host.delayUs(50);
                waited += 50;
            }
            if (self.functions == 0) return error.NoFunction;

            @memset(&buf, 0);
            std.mem.writeInt(u32, buf[0..4], msg.QUERY_RESOURCE_REQUIREMENTS, .little);
            std.mem.writeInt(u32, buf[4..8], self.function.slot, .little);
            var bars: [24]u8 = @splat(0);
            try self.step(.requirements, try self.call(buf[0..8], &bars));
            for (&self.bars, 0..) |*b, i| b.* = std.mem.readInt(u32, bars[4 * i ..][0..4], .little);

            @memset(&buf, 0);
            std.mem.writeInt(u32, buf[0..4], msg.BUS_D0ENTRY, .little);
            std.mem.writeInt(u64, buf[8..16], window, .little);
            try self.step(.d0, try self.call(buf[0..16], null));

            // (no resources: the window's MMIO is all this guest uses)
            @memset(&buf, 0);
            const v2 = self.version >= 0x0001_0002;
            std.mem.writeInt(u32, buf[0..4], if (v2) msg.RESOURCES_ASSIGNED2 else msg.RESOURCES_ASSIGNED, .little);
            std.mem.writeInt(u32, buf[4..8], self.function.slot, .little);
            try self.step(.resources, try self.call(buf[0..if (v2) 202 else 148], null));
            self.failed = null;
        }

        fn at(self: *const Self, offset: u64) *volatile u32 {
            return @ptrFromInt(self.window + offset);
        }

        /// The function's config register at `offset` (4-byte aligned,
        /// below 4 KiB).
        pub fn read32(self: *Self, offset: u16) u32 {
            self.at(0).* = self.function.slot;
            fence();
            const v = self.at(CONFIG_PAGE + offset).*;
            fence();
            return v;
        }

        pub fn write32(self: *Self, offset: u16, value: u32) void {
            self.at(0).* = self.function.slot;
            fence();
            self.at(CONFIG_PAGE + offset).* = value;
            fence();
        }
    };
}

var fence_word: u32 = 0;
fn fence() void {
    _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst);
}

comptime {
    // (the layouts' sizes, as Linux's packed structs: version request 8,
    // child message 8, D0 entry 16, resources assigned 148 / 202)
    if (MESSAGE_BASE + 0x19 != 0x4249_0019) @compileError("pci: message numbers");
}

// ── Tests: the bus brought up against a host the test plays ─────────────────

const testing = std.testing;

const Play = struct {
    p: *Pci(vmbus.testing.Host),
    seen: [8]u32 = @splat(0),
    n: usize = 0,
    d0_window: u64 = 0,
    assigned_bytes: usize = 0,
    /// The first version answered with a revision mismatch.
    refuse_first: bool = true,

    fn answer(ctx: *anyopaque) void {
        const s: *Play = @ptrCast(@alignCast(ctx));
        var buf: [512]u8 align(8) = undefined;
        const n = s.p.ch.out.read(&buf) orelse return;
        const id = std.mem.readInt(u64, buf[8..16], .little);
        const body = buf[16..n];
        const t = std.mem.readInt(u32, body[0..4], .little);
        if (s.n < s.seen.len) s.seen[s.n] = t;
        s.n += 1;
        var r: [64]u8 align(8) = @splat(0);
        var len: usize = 4;
        switch (t) {
            msg.QUERY_PROTOCOL_VERSION => if (s.refuse_first) {
                s.refuse_first = false;
                std.mem.writeInt(i32, r[0..4], STATUS_REVISION_MISMATCH, .little);
            },
            msg.QUERY_BUS_RELATIONS => {
                // no completion: the host's own packet, one function
                var rel: [8 + 28]u8 = @splat(0);
                std.mem.writeInt(u32, rel[0..4], msg.BUS_RELATIONS2, .little);
                std.mem.writeInt(u32, rel[4..8], 1, .little);
                std.mem.writeInt(u16, rel[8..10], 0x1414, .little);
                std.mem.writeInt(u16, rel[10..12], 0x008e, .little);
                std.mem.writeInt(u32, rel[20..24], 0x0000_0001, .little);
                _ = vmbus.testing.fromHost(s.p.ch.in, vmbus.pkt.DATA_INBAND, 0, &rel);
                return;
            },
            msg.QUERY_RESOURCE_REQUIREMENTS => len = 4 + 24,
            msg.BUS_D0ENTRY => s.d0_window = std.mem.readInt(u64, body[8..16], .little),
            msg.RESOURCES_ASSIGNED2, msg.RESOURCES_ASSIGNED => s.assigned_bytes = body.len,
            else => {},
        }
        _ = vmbus.testing.fromHost(s.p.ch.in, vmbus.pkt.COMPLETION, id, r[0..len]);
    }
};

test "vPCI: the bus brought up (version, functions, needs, D0, resources), then a config access" {
    var host = vmbus.testing.Host{};
    var mem: [4 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    @memset(&mem, 0);
    var window: [WINDOW_BYTES]u8 align(4096) = @splat(0);
    var p = Pci(vmbus.testing.Host){ .ch = vmbus.testing.channel(vmbus.testing.Host, &host, &mem, 2) };
    var play = Play{ .p = &p };
    host.answer = Play.answer;
    host.ctx = &play;
    try p.start(@intFromPtr(&window));
    try testing.expectEqual(@as(u32, 0x0001_0003), p.version);
    try testing.expectEqual(@as(u16, 0x1414), p.function.vendor);
    try testing.expectEqual(@as(u16, 0x008e), p.function.device);
    try testing.expectEqual(@as(u32, 1), p.function.slot);
    try testing.expectEqual(@intFromPtr(&window), play.d0_window);
    // (202 bytes, padded to 8 by the ring)
    try testing.expectEqual(@as(usize, 208), play.assigned_bytes);
    try testing.expectEqual(msg.RESOURCES_ASSIGNED2, play.seen[5]);
    // a config read: the slot written to the first page, the register read
    // from the second
    std.mem.writeInt(u32, window[CONFIG_PAGE + 208 ..][0..4], 40, .little);
    try testing.expectEqual(@as(u32, 40), p.read32(208));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, window[0..4], .little));
    p.write32(212, 1);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, window[CONFIG_PAGE + 212 ..][0..4], .little));
}
