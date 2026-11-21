//! Hyper-V's synthetic network adapter: the Ethernet port of a generation 2
//! machine, on one of the host's virtual switches. Two protocols ride its
//! VMBus channel:
//!
//! - NVSP sets the channel up: a protocol version, the NDIS version, and a
//!   receive buffer, a large piece of the guest's memory the host writes
//!   incoming frames into, section by section.
//! - RNDIS (Microsoft's "remote NDIS", as USB network adapters speak it)
//!   is what travels: control messages (initialize, query the address, set
//!   the packet filter) and data messages, each an Ethernet frame behind a
//!   44-byte header.
//!
//! A frame out: its RNDIS message in the guest's memory, named to the host
//! by its pages in an NVSP "send RNDIS packet"; the host answers with a
//! completion, which frees the slot. A frame in: a "transfer page" packet
//! naming ranges of the receive buffer, one RNDIS message each; once the
//! guest has read them it sends a completion, which gives the sections
//! back to the host.
//!
//! Zero allocation, freestanding; over an open VMBus channel (vmbus.sig).
//! Polled: `receive` is called by the network core, and also reaps the
//! completions that free transmit slots. The message layouts are the ones
//! Linux's netvsc and rndis_filter document (documentation only).

const vmbus = @import("vmbus.sig");
const put16 = vmbus.put16;
const put32 = vmbus.put32;
const get16 = vmbus.get16;
const get32 = vmbus.get32;

// ── NVSP ─────────────────────────────────────────────────────────────────────

const NVSP_INIT: u32 = 1;
const NVSP_SEND_NDIS_VERSION: u32 = 100;
const NVSP_SEND_RECEIVE_BUFFER: u32 = 101;
const NVSP_SEND_RNDIS_PACKET: u32 = 107;
const NVSP_SEND_RNDIS_PACKET_COMPLETE: u32 = 108;
const NVSP_SEND_NDIS_CONFIG: u32 = 125;
const NVSP_SUCCESS: u32 = 1;
/// Every NVSP message is sent at this size, whatever it carries.
const NVSP_BYTES = 40;
/// The id the receive buffer is given, which transfer-page packets repeat.
const RECEIVE_BUFFER_ID: u16 = 0xCAFE;
/// NVSP versions, newest first: 5 (Windows 8.1 and later), 4, 2 and 1.
const NVSP_VERSIONS = [_]u32{ 0x0005_0000, 0x0004_0000, 0x0003_0002, 0x0000_0002 };

const CHANNEL_DATA: u32 = 0;
const CHANNEL_CONTROL: u32 = 1;

// ── RNDIS ────────────────────────────────────────────────────────────────────

const RNDIS_PACKET: u32 = 1;
const RNDIS_INITIALIZE: u32 = 2;
const RNDIS_QUERY: u32 = 4;
const RNDIS_SET: u32 = 5;
const RNDIS_INDICATE_STATUS: u32 = 7;
const RNDIS_DONE: u32 = 0x8000_0000;
const OID_PERMANENT_ADDRESS: u32 = 0x0101_0101;
const OID_PACKET_FILTER: u32 = 0x0001_010E;
/// Frames to this address, to every group address, and broadcasts.
const FILTER: u32 = 0x1 | 0x4 | 0x8;
const STATUS_MEDIA_CONNECT: u32 = 0x4001_000B;
const STATUS_MEDIA_DISCONNECT: u32 = 0x4001_000C;
/// A data message's header: the type and length, then nine words of which
/// the first two are where the frame starts (from the third word) and its
/// length.
const RNDIS_DATA_HEADER = 44;

// ── Sizes ────────────────────────────────────────────────────────────────────

pub const SEND_PAGES = 16;
pub const RECEIVE_PAGES = 16;
/// The receive buffer the host fills (2 MiB).
pub const RECEIVE_BUFFER_PAGES = 512;
/// Frames on their way out at once, each in a 2 KiB slot; one more slot
/// carries control messages.
pub const TX_SLOTS = 32;
pub const SLOT_BYTES = 2048;
pub const TX_PAGES = (TX_SLOTS + 1) * SLOT_BYTES / vmbus.PAGE + 1;
pub const MAX_FRAME = SLOT_BYTES - RNDIS_DATA_HEADER;

const MAX_RANGES = 16;

pub const Error = error{
    RingFull,
    /// The host did not answer a step of the handshake.
    NoAnswer,
    /// The host refused a step (its status is logged by the caller).
    Refused,
    NoVersion,
};

pub fn Network(comptime Host: type) type {
    return struct {
        const Self = @This();

        ch: vmbus.Channel(Host),
        /// RECEIVE_BUFFER_PAGES pages the host was told of (a GPADL), and
        /// TX_PAGES pages for outgoing messages: the caller's memory, at
        /// addresses that are also guest physical addresses.
        receive_buffer: u64,
        tx_buffer: u64,

        mac: [6]u8 = [_]u8{0} ** 6,
        nvsp_version: u32 = 0,
        /// The host's word on the cable (connected until it says otherwise).
        link_up: bool = true,
        /// Frames the host could not be handed because every slot was busy.
        tx_busy_drops: u64 = 0,

        tx_id: [TX_SLOTS]u64 = [_]u64{0} ** TX_SLOTS,
        request_id: u32 = 1,
        /// The last NVSP completion and the last RNDIS control answer.
        nvsp_reply: [NVSP_BYTES]u8 = [_]u8{0} ** NVSP_BYTES,
        nvsp_reply_id: u64 = 0,
        reply: [128]u8 = [_]u8{0} ** 128,
        reply_len: usize = 0,

        /// The transfer-page packet being read: its ranges of the receive
        /// buffer, and how far through them the guest is.
        rx_id: u64 = 0,
        rx_count: u32 = 0,
        rx_index: u32 = 0,
        rx_ranges: [MAX_RANGES][2]u32 = undefined,
        /// A completion the channel had no room for yet.
        owed: ?u64 = null,

        const Step = union(enum) { empty, other, frame: usize };

        // ── The handshake ────────────────────────────────────────────────

        /// One NVSP message out and its completion back (in nvsp_reply).
        fn nvsp(self: *Self, m: *const [NVSP_BYTES]u8) Error!void {
            const id = self.ch.send(m, true) orelse return error.RingFull;
            self.nvsp_reply_id = 0;
            var waited: u32 = 0;
            while (waited < 2_000_000) {
                switch (self.step(null)) {
                    .empty => {
                        self.ch.host.delayUs(50);
                        waited += 50;
                    },
                    else => {},
                }
                if (self.nvsp_reply_id == id) return;
            }
            return error.NoAnswer;
        }

        /// One RNDIS control message (already in the control slot, `len`
        /// bytes, its request id at word 2) out, and its answer back (in
        /// reply): the status word of the answer must be 0.
        fn control(self: *Self, len: u32) Error!void {
            const slot = self.tx_buffer + TX_SLOTS * SLOT_BYTES;
            const want = get32(@as([*]const u8, @ptrFromInt(slot))[0..12], 8);
            var m = [_]u8{0} ** NVSP_BYTES;
            put32(&m, 0, NVSP_SEND_RNDIS_PACKET);
            put32(&m, 4, CHANNEL_CONTROL);
            put32(&m, 8, 0xFFFF_FFFF); // (not in a send buffer: in the pages named)
            self.reply_len = 0;
            _ = self.ch.sendWithData(&m, slot, len) orelse return error.RingFull;
            var waited: u32 = 0;
            while (waited < 2_000_000) {
                switch (self.step(null)) {
                    .empty => {
                        self.ch.host.delayUs(50);
                        waited += 50;
                    },
                    else => {},
                }
                if (self.reply_len >= 16 and get32(&self.reply, 8) == want) {
                    if (get32(&self.reply, 12) != 0) return error.Refused;
                    return;
                }
            }
            return error.NoAnswer;
        }

        fn controlSlot(self: *Self) []u8 {
            const p: [*]u8 = @ptrFromInt(self.tx_buffer + TX_SLOTS * SLOT_BYTES);
            @memset(p[0..64], 0);
            return p[0..SLOT_BYTES];
        }

        fn nextRequest(self: *Self) u32 {
            self.request_id += 1;
            return self.request_id;
        }

        /// The adapter from an open channel to carrying frames: NVSP's
        /// version, the NDIS version, the receive buffer (already named to
        /// the host as GPADL `receive_gpadl`), then RNDIS: initialize, the
        /// address, the packet filter.
        pub fn start(self: *Self, receive_gpadl: u32) Error!void {
            for (NVSP_VERSIONS) |v| {
                var m = [_]u8{0} ** NVSP_BYTES;
                put32(&m, 0, NVSP_INIT);
                put32(&m, 4, v);
                put32(&m, 8, v);
                try self.nvsp(&m);
                if (get32(&self.nvsp_reply, 12) == NVSP_SUCCESS) {
                    self.nvsp_version = v;
                    break;
                }
            } else return error.NoVersion;

            var m = [_]u8{0} ** NVSP_BYTES;
            if (self.nvsp_version >= 0x0003_0002) {
                // (the largest frame, with its Ethernet header; no extras)
                put32(&m, 0, NVSP_SEND_NDIS_CONFIG);
                put32(&m, 4, 1514);
                _ = self.ch.send(&m, false) orelse return error.RingFull;
            }
            // NDIS 6.1 to an older host, 6.30 from NVSP 5 on.
            @memset(&m, 0);
            put32(&m, 0, NVSP_SEND_NDIS_VERSION);
            put32(&m, 4, 6);
            put32(&m, 8, if (self.nvsp_version > 0x0004_0000) 30 else 1);
            _ = self.ch.send(&m, false) orelse return error.RingFull;

            @memset(&m, 0);
            put32(&m, 0, NVSP_SEND_RECEIVE_BUFFER);
            put32(&m, 4, receive_gpadl);
            put16(&m, 8, RECEIVE_BUFFER_ID);
            try self.nvsp(&m);
            if (get32(&self.nvsp_reply, 4) != NVSP_SUCCESS) return error.Refused;

            var c = self.controlSlot();
            put32(c, 0, RNDIS_INITIALIZE);
            put32(c, 4, 24);
            put32(c, 8, self.nextRequest());
            put32(c, 12, 1); // (RNDIS 1.0)
            put32(c, 20, 0x4000); // (the largest message this side takes)
            try self.control(24);

            c = self.controlSlot();
            put32(c, 0, RNDIS_QUERY);
            put32(c, 4, 28);
            put32(c, 8, self.nextRequest());
            put32(c, 12, OID_PERMANENT_ADDRESS);
            put32(c, 20, 20); // (where the answer's buffer would start)
            try self.control(28);
            // (the answer: its length and its place, from the request id's word)
            const at: usize = 8 + @as(usize, get32(&self.reply, 20));
            if (get32(&self.reply, 16) < 6 or at + 6 > self.reply_len) return error.Refused;
            @memcpy(&self.mac, self.reply[at..][0..6]);

            c = self.controlSlot();
            put32(c, 0, RNDIS_SET);
            put32(c, 4, 32);
            put32(c, 8, self.nextRequest());
            put32(c, 12, OID_PACKET_FILTER);
            put32(c, 16, 4);
            put32(c, 20, 20);
            put32(c, 28, FILTER);
            try self.control(32);
        }

        // ── Frames ───────────────────────────────────────────────────────

        /// One Ethernet frame to the switch. False when it is too long, or
        /// every slot is still with the host (the caller's next `receive`
        /// reaps completions).
        pub fn send(self: *Self, frame: []const u8) bool {
            if (frame.len == 0 or frame.len > MAX_FRAME) return false;
            const slot = for (self.tx_id, 0..) |id, i| {
                if (id == 0) break i;
            } else {
                self.tx_busy_drops += 1;
                return false;
            };
            const at = self.tx_buffer + slot * SLOT_BYTES;
            const p: [*]u8 = @ptrFromInt(at);
            @memset(p[0..RNDIS_DATA_HEADER], 0);
            put32(p[0..RNDIS_DATA_HEADER], 0, RNDIS_PACKET);
            put32(p[0..RNDIS_DATA_HEADER], 4, @intCast(RNDIS_DATA_HEADER + frame.len));
            put32(p[0..RNDIS_DATA_HEADER], 8, RNDIS_DATA_HEADER - 8);
            put32(p[0..RNDIS_DATA_HEADER], 12, @intCast(frame.len));
            @memcpy(p[RNDIS_DATA_HEADER..][0..frame.len], frame);
            var m = [_]u8{0} ** NVSP_BYTES;
            put32(&m, 0, NVSP_SEND_RNDIS_PACKET);
            put32(&m, 4, CHANNEL_DATA);
            put32(&m, 8, 0xFFFF_FFFF);
            const id = self.ch.sendWithData(&m, at, @intCast(RNDIS_DATA_HEADER + frame.len)) orelse return false;
            self.tx_id[slot] = id;
            return true;
        }

        /// The next received frame into `out` (cut to its length), or null
        /// when the host has sent none.
        pub fn receive(self: *Self, out: []u8) ?usize {
            var budget: u32 = 64;
            while (budget > 0) : (budget -= 1) {
                switch (self.step(out)) {
                    .empty => return null,
                    .other => {},
                    .frame => |n| return n,
                }
            }
            return null;
        }

        /// One thing from the host: a completion, a control answer, a
        /// status, or a frame (copied to `out`; dropped when there is none).
        fn step(self: *Self, out: ?[]u8) Step {
            if (self.owed) |id| {
                if (!self.acknowledge(id)) return .empty;
                self.owed = null;
            }
            if (self.rx_index < self.rx_count) return self.range(out);
            var buf: [512]u8 = undefined;
            const p = self.ch.receive(&buf) orelse return .empty;
            switch (p.kind) {
                vmbus.pkt.COMPLETION => {
                    if (p.body.len >= 4 and get32(p.body, 0) == NVSP_SEND_RNDIS_PACKET_COMPLETE) {
                        // (a frame, or a control message, the host has taken)
                        for (&self.tx_id) |*id| {
                            if (id.* == p.id) id.* = 0;
                        }
                    } else {
                        @memset(&self.nvsp_reply, 0);
                        const n = @min(p.body.len, NVSP_BYTES);
                        @memcpy(self.nvsp_reply[0..n], p.body[0..n]);
                        self.nvsp_reply_id = p.id;
                    }
                },
                vmbus.pkt.DATA_USING_XFER_PAGES => {
                    if (p.whole.len < 24 or get16(p.whole, 16) != RECEIVE_BUFFER_ID) return .other;
                    const count: u32 = @min(get32(p.whole, 20), MAX_RANGES);
                    var n: u32 = 0;
                    while (n < count and 24 + 8 * @as(usize, n) + 8 <= p.whole.len) : (n += 1) {
                        self.rx_ranges[n] = .{ get32(p.whole, 24 + 8 * @as(usize, n)), get32(p.whole, 28 + 8 * @as(usize, n)) };
                    }
                    self.rx_id = p.id;
                    self.rx_count = n;
                    self.rx_index = 0;
                    if (n == 0) self.finish();
                },
                else => {},
            }
            return .other;
        }

        /// The next range of the packet being read: an RNDIS message in the
        /// receive buffer.
        fn range(self: *Self, out: ?[]u8) Step {
            const len = self.rx_ranges[self.rx_index][0];
            const off = self.rx_ranges[self.rx_index][1];
            self.rx_index += 1;
            defer if (self.rx_index == self.rx_count) self.finish();
            if (len < 16 or @as(u64, off) + len > RECEIVE_BUFFER_PAGES * vmbus.PAGE) return .other;
            const m: []const u8 = @as([*]const u8, @ptrFromInt(self.receive_buffer + off))[0..len];
            switch (get32(m, 0)) {
                RNDIS_PACKET => {
                    const at: u64 = 8 + @as(u64, get32(m, 8));
                    const n: u64 = get32(m, 12);
                    if (n == 0 or at + n > len) return .other;
                    const to = out orelse return .other;
                    const take: usize = @intCast(@min(n, to.len));
                    @memcpy(to[0..take], m[@intCast(at)..][0..take]);
                    return .{ .frame = take };
                },
                RNDIS_INDICATE_STATUS => {
                    const status = get32(m, 8);
                    if (status == STATUS_MEDIA_CONNECT) self.link_up = true;
                    if (status == STATUS_MEDIA_DISCONNECT) self.link_up = false;
                },
                else => |t| if (t & RNDIS_DONE != 0) {
                    self.reply_len = @min(m.len, self.reply.len);
                    @memcpy(self.reply[0..self.reply_len], m[0..self.reply_len]);
                },
            }
            return .other;
        }

        /// The packet's ranges are read: its sections go back to the host.
        fn finish(self: *Self) void {
            self.rx_count = 0;
            self.rx_index = 0;
            if (!self.acknowledge(self.rx_id)) self.owed = self.rx_id;
        }

        fn acknowledge(self: *Self, id: u64) bool {
            var m = [_]u8{0} ** NVSP_BYTES;
            put32(&m, 0, NVSP_SEND_RNDIS_PACKET_COMPLETE);
            put32(&m, 4, NVSP_SUCCESS);
            return self.ch.complete(id, &m);
        }
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests: a virtual switch port at the far end of the channel
// ══════════════════════════════════════════════════════════════════════════════

const TestHost = vmbus.testing.Host;
const fromHost = vmbus.testing.fromHost;

const FakePort = struct {
    ch: *vmbus.Channel(TestHost),
    receive_buffer: [*]u8,
    mac: [6]u8 = .{ 0x00, 0x15, 0x5D, 0x01, 0x02, 0x03 },
    newest: u32 = 0x0005_0000,
    /// Where the next message goes in the receive buffer.
    next_section: u32 = 0,
    next_id: u64 = 100,

    ndis_minor: u32 = 0,
    mtu: u32 = 0,
    gpadl: u32 = 0,
    buffer_id: u16 = 0,
    filter: u32 = 0,
    initialized: bool = false,
    hold_completions: bool = false,
    echo: bool = false,
    frames: u32 = 0,
    last: [128]u8 = undefined,
    last_len: usize = 0,
    acknowledged: [8]u64 = [_]u64{0} ** 8,
    acks: usize = 0,

    /// An RNDIS message to the guest: into the receive buffer, then named
    /// in a transfer-page packet.
    fn deliver(self: *FakePort, channel_type: u32, messages: []const []const u8) u64 {
        var head: [24 + 8 * 4 + 16]u8 = undefined;
        @memset(&head, 0);
        const n = messages.len;
        const offset = 24 + 8 * n;
        put16(&head, 0, vmbus.pkt.DATA_USING_XFER_PAGES);
        put16(&head, 2, @intCast(offset / 8));
        put16(&head, 4, @intCast((offset + 16) / 8));
        put16(&head, 6, vmbus.pkt.FLAG_COMPLETION_REQUESTED);
        const id = self.next_id;
        self.next_id += 1;
        vmbus.put64(&head, 8, id);
        put16(&head, 16, RECEIVE_BUFFER_ID);
        put32(&head, 20, @intCast(n));
        for (messages, 0..) |m, i| {
            @memcpy(self.receive_buffer[self.next_section..][0..m.len], m);
            put32(&head, 24 + 8 * i, @intCast(m.len));
            put32(&head, 28 + 8 * i, self.next_section);
            self.next_section += 2048;
        }
        put32(&head, offset, NVSP_SEND_RNDIS_PACKET);
        put32(&head, offset + 4, channel_type);
        _ = self.ch.in.write(&.{head[0 .. offset + 16]});
        return id;
    }

    /// A frame from the network.
    fn frameIn(self: *FakePort, frame: []const u8) u64 {
        var m: [RNDIS_DATA_HEADER + 100]u8 = undefined;
        @memset(&m, 0);
        put32(&m, 0, RNDIS_PACKET);
        put32(&m, 4, @intCast(RNDIS_DATA_HEADER + frame.len));
        put32(&m, 8, RNDIS_DATA_HEADER - 8);
        put32(&m, 12, @intCast(frame.len));
        @memcpy(m[RNDIS_DATA_HEADER..][0..frame.len], frame);
        return self.deliver(CHANNEL_DATA, &.{m[0 .. RNDIS_DATA_HEADER + frame.len]});
    }

    fn rndisControl(self: *FakePort, m: []const u8) void {
        var r = [_]u8{0} ** 48;
        put32(&r, 0, get32(m, 0) | RNDIS_DONE);
        put32(&r, 8, get32(m, 8)); // (the request's id)
        switch (get32(m, 0)) {
            RNDIS_INITIALIZE => {
                self.initialized = true;
                put32(&r, 4, 52);
                _ = self.deliver(CHANNEL_CONTROL, &.{r[0..48]});
            },
            RNDIS_QUERY => {
                if (get32(m, 12) != OID_PERMANENT_ADDRESS) put32(&r, 12, 0xC000_00BB);
                put32(&r, 4, 30);
                put32(&r, 16, 6);
                put32(&r, 20, 16);
                @memcpy(r[24..30], &self.mac);
                _ = self.deliver(CHANNEL_CONTROL, &.{r[0..30]});
            },
            RNDIS_SET => {
                if (get32(m, 12) == OID_PACKET_FILTER) self.filter = get32(m, 8 + get32(m, 20));
                put32(&r, 4, 16);
                _ = self.deliver(CHANNEL_CONTROL, &.{r[0..16]});
            },
            else => {},
        }
    }

    fn answer(ctx: *anyopaque) void {
        const self: *FakePort = @ptrCast(@alignCast(ctx));
        var buf: [256]u8 = undefined;
        while (self.ch.out.read(&buf)) |len| {
            const whole = buf[0..@min(len, buf.len)];
            const body = whole[@as(usize, get16(whole, 2)) * 8 ..];
            const id = vmbus.get64(whole, 8);
            var r = [_]u8{0} ** NVSP_BYTES;
            switch (get16(whole, 0)) {
                vmbus.pkt.COMPLETION => {
                    if (get32(body, 0) == NVSP_SEND_RNDIS_PACKET_COMPLETE and get32(body, 4) == NVSP_SUCCESS and self.acks < 8) {
                        self.acknowledged[self.acks] = id;
                        self.acks += 1;
                    }
                },
                vmbus.pkt.DATA_INBAND => switch (get32(body, 0)) {
                    NVSP_INIT => {
                        put32(&r, 0, 2);
                        put32(&r, 4, get32(body, 4));
                        put32(&r, 12, if (get32(body, 4) <= self.newest) NVSP_SUCCESS else 2);
                        _ = fromHost(self.ch.in, vmbus.pkt.COMPLETION, id, &r);
                    },
                    NVSP_SEND_NDIS_CONFIG => self.mtu = get32(body, 4),
                    NVSP_SEND_NDIS_VERSION => self.ndis_minor = get32(body, 8),
                    NVSP_SEND_RECEIVE_BUFFER => {
                        self.gpadl = get32(body, 4);
                        self.buffer_id = get16(body, 8);
                        put32(&r, 0, 102);
                        put32(&r, 4, NVSP_SUCCESS);
                        put32(&r, 8, 1);
                        _ = fromHost(self.ch.in, vmbus.pkt.COMPLETION, id, &r);
                    },
                    else => {},
                },
                vmbus.pkt.DATA_USING_GPA_DIRECT => {
                    // The RNDIS message, where its page range says it is.
                    const m: [*]const u8 = @ptrFromInt(vmbus.get64(whole, 32) * vmbus.PAGE + get32(whole, 28));
                    const size = get32(whole, 24);
                    if (get32(body, 4) == CHANNEL_CONTROL) {
                        self.rndisControl(m[0..size]);
                    } else {
                        const at: usize = 8 + get32(m[0..16], 8);
                        self.last_len = get32(m[0..16], 12);
                        @memcpy(self.last[0..self.last_len], m[at..][0..self.last_len]);
                        self.frames += 1;
                        if (self.echo) _ = self.frameIn(self.last[0..self.last_len]);
                    }
                    if (!self.hold_completions) {
                        put32(&r, 0, NVSP_SEND_RNDIS_PACKET_COMPLETE);
                        put32(&r, 4, NVSP_SUCCESS);
                        _ = fromHost(self.ch.in, vmbus.pkt.COMPLETION, id, &r);
                    }
                },
                else => {},
            }
        }
    }
};

const Bench = struct {
    var host: TestHost = .{};
    var rings: [(SEND_PAGES + RECEIVE_PAGES) * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var receive_buffer: [64 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var tx_buffer: [TX_PAGES * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var nic: Network(TestHost) = undefined;
    var port: FakePort = undefined;

    fn fresh() *FakePort {
        host = .{};
        nic = .{
            .ch = vmbus.testing.channel(TestHost, &host, &rings, SEND_PAGES),
            .receive_buffer = @intFromPtr(&receive_buffer),
            .tx_buffer = @intFromPtr(&tx_buffer),
        };
        port = .{ .ch = &nic.ch, .receive_buffer = &receive_buffer };
        host.answer = FakePort.answer;
        host.ctx = &port;
        return &port;
    }
};

fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

test "network: the handshake" {
    const p = Bench.fresh();
    try Bench.nic.start(0xE1E12);
    try expect(Bench.nic.nvsp_version == 0x0005_0000);
    try expect(p.mtu == 1514 and p.ndis_minor == 30);
    try expect(p.gpadl == 0xE1E12 and p.buffer_id == RECEIVE_BUFFER_ID);
    try expect(p.initialized and p.filter == FILTER);
    try expect(Bench.nic.mac[0] == 0x00 and Bench.nic.mac[1] == 0x15 and Bench.nic.mac[5] == 0x03);
    // Each control answer's transfer-page packet was completed: its
    // section is the host's again.
    try expect(p.acks == 3 and p.acknowledged[0] == 100 and p.acknowledged[2] == 102);
    // Nothing left in a transmit slot.
    for (Bench.nic.tx_id) |id| try expect(id == 0);
}

test "network: an older host" {
    const p = Bench.fresh();
    p.newest = 0x0000_0002;
    try Bench.nic.start(1);
    try expect(Bench.nic.nvsp_version == 2);
    try expect(p.mtu == 0 and p.ndis_minor == 1); // (no NDIS configuration before version 2)
    const q = Bench.fresh();
    q.newest = 1;
    try expect(if (Bench.nic.start(1)) |_| false else |e| e == error.NoVersion);
}

test "network: frames out and in" {
    const p = Bench.fresh();
    try Bench.nic.start(1);
    var frame: [60]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @intCast(i + 1);
    try expect(Bench.nic.send(&frame));
    try expect(p.frames == 1 and p.last_len == 60 and p.last[0] == 1 and p.last[59] == 60);
    // The slot is busy until the host's completion is read.
    try expect(Bench.nic.tx_id[0] != 0);
    var out: [1600]u8 = undefined;
    try expect(Bench.nic.receive(&out) == null);
    try expect(Bench.nic.tx_id[0] == 0);

    // Two frames in one packet from the host, then a third.
    var a = [_]u8{0xA1} ** 64;
    a[63] = 0x1A;
    const b = [_]u8{0xB2} ** 80;
    var ma: [RNDIS_DATA_HEADER + 64]u8 = undefined;
    var mb: [RNDIS_DATA_HEADER + 80]u8 = undefined;
    for ([_]struct { m: []u8, f: []const u8 }{ .{ .m = &ma, .f = &a }, .{ .m = &mb, .f = &b } }) |x| {
        @memset(x.m[0..RNDIS_DATA_HEADER], 0);
        put32(x.m, 0, RNDIS_PACKET);
        put32(x.m, 4, @intCast(x.m.len));
        put32(x.m, 8, RNDIS_DATA_HEADER - 8);
        put32(x.m, 12, @intCast(x.f.len));
        @memcpy(x.m[RNDIS_DATA_HEADER..], x.f);
    }
    const acks_before = p.acks;
    const id = p.deliver(CHANNEL_DATA, &.{ &ma, &mb });
    const third = p.frameIn(frame[0..42]);
    try expect(Bench.nic.receive(&out).? == 64 and out[0] == 0xA1 and out[63] == 0x1A);
    try expect(p.acks == acks_before); // (not given back while a range is unread)
    try expect(Bench.nic.receive(&out).? == 80 and out[79] == 0xB2);
    // (the completion is sent with the last range; the far end sees it at
    // the next signal)
    try expect(Bench.nic.receive(&out).? == 42 and out[41] == 42);
    try expect(Bench.nic.receive(&out) == null);
    FakePort.answer(p);
    try expect(p.acks == acks_before + 2 and p.acknowledged[acks_before] == id and p.acknowledged[acks_before + 1] == third);
    // A short buffer gets the frame's start.
    _ = p.frameIn(&b);
    var small: [10]u8 = undefined;
    try expect(Bench.nic.receive(&small).? == 10 and small[9] == 0xB2);
}

test "network: every slot busy, then reaped" {
    const p = Bench.fresh();
    try Bench.nic.start(1);
    p.hold_completions = true;
    const frame = [_]u8{0x5A} ** 100;
    var n: usize = 0;
    while (Bench.nic.send(&frame)) n += 1;
    try expect(n == TX_SLOTS and Bench.nic.tx_busy_drops == 1);
    // The host completes them all; one look at the channel frees the slots.
    var id: u64 = 0;
    for (Bench.nic.tx_id) |t| {
        var r = [_]u8{0} ** NVSP_BYTES;
        put32(&r, 0, NVSP_SEND_RNDIS_PACKET_COMPLETE);
        put32(&r, 4, NVSP_SUCCESS);
        try expect(fromHost(Bench.nic.ch.in, vmbus.pkt.COMPLETION, t, &r));
        id = t;
    }
    var out: [64]u8 = undefined;
    try expect(Bench.nic.receive(&out) == null);
    for (Bench.nic.tx_id) |t| try expect(t == 0);
    try expect(Bench.nic.send(&frame));
    // Too long, or empty: refused.
    try expect(!Bench.nic.send(Bench.tx_buffer[0 .. MAX_FRAME + 1]));
    try expect(!Bench.nic.send(frame[0..0]));
}

test "network: the cable, and what is not a frame" {
    const p = Bench.fresh();
    try Bench.nic.start(1);
    try expect(Bench.nic.link_up);
    var status = [_]u8{0} ** 20;
    put32(&status, 0, RNDIS_INDICATE_STATUS);
    put32(&status, 4, 20);
    put32(&status, 8, STATUS_MEDIA_DISCONNECT);
    _ = p.deliver(CHANNEL_CONTROL, &.{&status});
    var out: [64]u8 = undefined;
    try expect(Bench.nic.receive(&out) == null and !Bench.nic.link_up);
    put32(&status, 8, STATUS_MEDIA_CONNECT);
    _ = p.deliver(CHANNEL_CONTROL, &.{&status});
    try expect(Bench.nic.receive(&out) == null and Bench.nic.link_up);
    // A data message whose frame would run past its range: passed over.
    var bad = [_]u8{0} ** (RNDIS_DATA_HEADER + 8);
    put32(&bad, 0, RNDIS_PACKET);
    put32(&bad, 8, RNDIS_DATA_HEADER - 8);
    put32(&bad, 12, 4000);
    _ = p.deliver(CHANNEL_DATA, &.{&bad});
    try expect(Bench.nic.receive(&out) == null);
    // A packet for another buffer's id: passed over.
    var head = [_]u8{0} ** 48;
    put16(&head, 0, vmbus.pkt.DATA_USING_XFER_PAGES);
    put16(&head, 2, 4);
    put16(&head, 4, 6);
    put16(&head, 16, 0xBEEF);
    put32(&head, 20, 1);
    put32(&head, 24, 100);
    try expect(Bench.nic.ch.in.write(&.{&head}));
    try expect(Bench.nic.receive(&out) == null);
}
