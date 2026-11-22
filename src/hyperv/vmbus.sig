//! VMBus: how a guest of Microsoft's hypervisor (Hyper-V on Windows 10/11
//! and Windows Server, Azure) reaches its devices. A generation 2 Hyper-V
//! machine has no PCI bus at all: its keyboard, mouse, disks, network
//! adapters and video are "synthetic" devices offered over VMBus.
//!
//! Zero allocation, freestanding. The guest's side of the hypervisor (its
//! hypercalls, its message page, its memory) comes through `Host`, so the
//! same code runs in a kernel and against the fake hypervisor in this
//! file's tests.
//!
//! The pieces:
//!
//! 1. Control messages. The guest posts them with the HvPostMessage
//!    hypercall; the hypervisor answers into one 256-byte slot of the
//!    guest's message page (SINT 2), one message at a time: the guest
//!    clears the slot, and says "end of message" when more are waiting.
//! 2. The handshake: INITIATE_CONTACT with a protocol version, then
//!    REQUEST_OFFERS; the hypervisor sends one OFFER_CHANNEL per device and
//!    ALL_OFFERS_DELIVERED.
//! 3. A channel: two ring buffers in the guest's memory, guest to host and
//!    host to guest. The guest names the pages (a GPADL: GPADL_HEADER and,
//!    past 26 pages, GPADL_BODY messages), then OPEN_CHANNEL.
//! 4. Packets in a ring: a 16-byte descriptor, the payload padded to 8
//!    bytes, and 8 bytes naming the write index before it. The guest tells
//!    the host of new packets with the HvSignalEvent hypercall; this driver
//!    polls its own rings (their interrupt mask stays set), so it needs no
//!    interrupt.
//!
//! From Microsoft's Hypervisor Top Level Functional Specification (the
//! hypercalls, the message page) and the layout of the VMBus messages and
//! rings as Linux's drivers/hv documents them (documentation only).

// ══════════════════════════════════════════════════════════════════════════════
// The hypervisor's interface (TLFS)
// ══════════════════════════════════════════════════════════════════════════════

pub const hv = struct {
    /// CPUID: the hypervisor's vendor leaf ("Microsoft Hv" in ebx, ecx, edx)
    /// and its interface leaf ("Hv#1" in eax).
    pub const CPUID_VENDOR: u32 = 0x4000_0000;
    pub const CPUID_INTERFACE: u32 = 0x4000_0001;
    pub const INTERFACE_HV1: u32 = 0x3123_7648;

    pub const MSR_GUEST_OS_ID: u32 = 0x4000_0000;
    pub const MSR_HYPERCALL: u32 = 0x4000_0001;
    pub const MSR_VP_INDEX: u32 = 0x4000_0002;
    pub const MSR_SCONTROL: u32 = 0x4000_0080;
    pub const MSR_SIEFP: u32 = 0x4000_0082;
    pub const MSR_SIMP: u32 = 0x4000_0083;
    pub const MSR_EOM: u32 = 0x4000_0084;
    pub const MSR_SINT0: u32 = 0x4000_0090;

    /// A synthetic interrupt source: its vector, and the bits that keep it
    /// from interrupting (polled: messages still arrive in their slot).
    pub const SINT_MASKED: u64 = 1 << 16;
    pub const SINT_AUTO_EOI: u64 = 1 << 17;
    pub const SINT_POLLING: u64 = 1 << 18;

    pub const CALL_POST_MESSAGE: u64 = 0x005C;
    pub const CALL_SIGNAL_EVENT: u64 = 0x005D;
    pub const CALL_FAST: u64 = 1 << 16;

    pub const STATUS_SUCCESS: u16 = 0;
    pub const STATUS_INSUFFICIENT_MEMORY: u16 = 0x0B;
    pub const STATUS_INSUFFICIENT_BUFFERS: u16 = 0x13;

    /// VMBus's place in the message page, and its message type.
    pub const VMBUS_SINT = 2;
    pub const MESSAGE_SLOT_BYTES = 256;
    pub const MESSAGE_PAYLOAD_MAX = 240;
    pub const MESSAGE_VMBUS: u32 = 1;
    /// The connection control messages are posted to (protocols before 5.0).
    pub const VMBUS_MESSAGE_CONNECTION: u32 = 1;
};

/// A device class or instance id, in the byte order the hypervisor sends.
pub const Guid = [16]u8;

/// A GUID's bytes from its text ("f912ad6d-2b17-48ea-bd65-f927a61c7684"):
/// the first three groups are little-endian, the rest as written.
pub fn guid(text: *const [36]u8) Guid {
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '-' or n == 32) continue;
        hex[n] = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => 0,
        };
        n += 1;
    }
    var raw: [16]u8 = undefined;
    for (0..16) |i| raw[i] = hex[i * 2] * 16 + hex[i * 2 + 1];
    return .{ raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15] };
}

pub const device = struct {
    pub const keyboard = guid("f912ad6d-2b17-48ea-bd65-f927a61c7684");
    pub const mouse = guid("cfa8b69e-5b4a-4cc0-b98b-8ba1a1f3f95a");
    pub const scsi = guid("ba6163d9-04a1-4d29-b605-72e2ffb1dc7f");
    pub const network = guid("f8615163-df3e-46c5-913f-f2d2f965ed0e");
    pub const video = guid("da0a7802-e377-4aac-8e77-0558eb1073f8");
    pub const heartbeat = guid("57164f39-9115-4e78-ab55-382f3bd5422d");
    pub const shutdown = guid("0e0b6031-5213-4934-818b-38d90ced39db");
    pub const time_sync = guid("9527e630-d0ae-497b-adce-e80ab0175caf");

    /// A name for the log.
    pub fn name(id: Guid) []const u8 {
        const known = [_]struct { id: Guid, name: []const u8 }{
            .{ .id = keyboard, .name = "keyboard" },
            .{ .id = mouse, .name = "mouse" },
            .{ .id = scsi, .name = "SCSI controller" },
            .{ .id = network, .name = "network adapter" },
            .{ .id = video, .name = "video" },
            .{ .id = heartbeat, .name = "heartbeat" },
            .{ .id = shutdown, .name = "shutdown" },
            .{ .id = time_sync, .name = "time sync" },
        };
        for (known) |k| if (same(k.id, id)) return k.name;
        return "other";
    }
};

pub fn same(a: Guid, b: Guid) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// Control messages
// ══════════════════════════════════════════════════════════════════════════════

pub const msg = struct {
    pub const OFFER_CHANNEL: u32 = 1;
    pub const RESCIND_OFFER: u32 = 2;
    pub const REQUEST_OFFERS: u32 = 3;
    pub const ALL_OFFERS_DELIVERED: u32 = 4;
    pub const OPEN_CHANNEL: u32 = 5;
    pub const OPEN_CHANNEL_RESULT: u32 = 6;
    pub const CLOSE_CHANNEL: u32 = 7;
    pub const GPADL_HEADER: u32 = 8;
    pub const GPADL_BODY: u32 = 9;
    pub const GPADL_CREATED: u32 = 10;
    pub const GPADL_TEARDOWN: u32 = 11;
    pub const GPADL_TORNDOWN: u32 = 12;
    pub const INITIATE_CONTACT: u32 = 14;
    pub const VERSION_RESPONSE: u32 = 15;

    /// Page numbers that fit beside a GPADL_HEADER and in a GPADL_BODY.
    pub const HEADER_PFNS = 26;
    pub const BODY_PFNS = 28;
};

/// Protocol versions, newest first, that this driver speaks: all of them
/// post control messages to connection 1 and name a channel's connection in
/// its offer.
pub const VERSIONS = [_]u32{ 0x0004_0000, 0x0003_0000, 0x0002_0004 };

pub fn put16(b: []u8, at: usize, v: u16) void {
    b[at] = @truncate(v);
    b[at + 1] = @truncate(v >> 8);
}

pub fn put32(b: []u8, at: usize, v: u32) void {
    put16(b, at, @truncate(v));
    put16(b, at + 2, @truncate(v >> 16));
}

pub fn put64(b: []u8, at: usize, v: u64) void {
    put32(b, at, @truncate(v));
    put32(b, at + 4, @truncate(v >> 32));
}

pub fn get16(b: []const u8, at: usize) u16 {
    return @as(u16, b[at]) | @as(u16, b[at + 1]) << 8;
}

pub fn get32(b: []const u8, at: usize) u32 {
    return @as(u32, get16(b, at)) | @as(u32, get16(b, at + 2)) << 16;
}

pub fn get64(b: []const u8, at: usize) u64 {
    return @as(u64, get32(b, at)) | @as(u64, get32(b, at + 4)) << 32;
}

/// A device the hypervisor offers.
pub const Offer = struct {
    kind: Guid = [_]u8{0} ** 16,
    instance: Guid = [_]u8{0} ** 16,
    /// The channel's id in every later control message.
    relid: u32 = 0,
    /// What HvSignalEvent names to wake the host for this channel.
    connection: u32 = 0,
    /// Not 0: a sub-channel of a device that asked for more than one.
    sub_index: u16 = 0,
    /// The MMIO the device wants of the machine's (MiB): dxgkrnl's global
    /// channel asks this much for its IO space.
    mmio_megabytes: u16 = 0,

    /// From an OFFER_CHANNEL message (196 bytes), or null when it is short.
    pub fn parse(m: []const u8) ?Offer {
        if (m.len < 196) return null;
        return .{
            .kind = m[8..24].*,
            .instance = m[24..40].*,
            .mmio_megabytes = get16(m, 58),
            .sub_index = get16(m, 180),
            .relid = get32(m, 184),
            .connection = get32(m, 192),
        };
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Ring buffers
// ══════════════════════════════════════════════════════════════════════════════

pub const PAGE = 4096;

/// Packet types and flags.
pub const pkt = struct {
    pub const DATA_INBAND: u16 = 6;
    pub const DATA_USING_XFER_PAGES: u16 = 7;
    pub const DATA_USING_GPA_DIRECT: u16 = 9;
    pub const COMPLETION: u16 = 11;
    pub const FLAG_COMPLETION_REQUESTED: u16 = 1;
    pub const DESCRIPTOR_BYTES = 16;
};

/// One direction of a channel: a header page (the two indices, the
/// reader's interrupt mask, what the writer waits for) and `size` bytes of
/// data after it, used as a ring.
pub const Ring = struct {
    base: u64 = 0,
    size: u32 = 0,

    const WRITE_INDEX = 0;
    const READ_INDEX = 4;
    const INTERRUPT_MASK = 8;
    const PENDING_SEND = 12;
    const FEATURE_BITS = 64;

    fn word(self: Ring, at: usize) *volatile u32 {
        return @ptrFromInt(self.base + at);
    }

    fn data(self: Ring) [*]u8 {
        return @ptrFromInt(self.base + PAGE);
    }

    /// A ring over `pages` pages at `base`, empty. `reader_polls`: this
    /// side reads it and does not want to be interrupted for it.
    pub fn init(base: u64, pages: u32, reader_polls: bool) Ring {
        const r: Ring = .{ .base = base, .size = (pages - 1) * PAGE };
        @memset(@as([*]u8, @ptrFromInt(base))[0..PAGE], 0);
        r.word(FEATURE_BITS).* = 1; // (the reader honours "pending send size")
        if (reader_polls) r.word(INTERRUPT_MASK).* = 1;
        return r;
    }

    pub fn used(self: Ring) u32 {
        const w = self.word(WRITE_INDEX).*;
        const r = self.word(READ_INDEX).*;
        return if (w >= r) w - r else self.size - r + w;
    }

    /// Whether the writer is waiting for room (the reader then signals it
    /// after reading).
    pub fn writerWaits(self: Ring) bool {
        return self.word(PENDING_SEND).* != 0;
    }

    fn copyIn(self: Ring, at: u32, bytes: []const u8) u32 {
        const d = self.data();
        const first: usize = @min(bytes.len, self.size - at);
        @memcpy(d[at..][0..first], bytes[0..first]);
        @memcpy(d[0 .. bytes.len - first], bytes[first..]);
        return @intCast((at + bytes.len) % self.size);
    }

    fn copyOut(self: Ring, at: u32, out: []u8) void {
        const d = self.data();
        const first: usize = @min(out.len, self.size - at);
        @memcpy(out[0..first], d[at..][0..first]);
        @memcpy(out[first..], d[0 .. out.len - first]);
    }

    /// One packet: its parts one after another (together a multiple of 8
    /// bytes), then the 8 bytes that name the write index before it. False
    /// when the ring has no room; nothing is written then.
    pub fn write(self: Ring, parts: []const []const u8) bool {
        var total: u32 = 8;
        for (parts) |p| total += @intCast(p.len);
        const w = self.word(WRITE_INDEX).*;
        // (one byte always stays free: equal indices mean an empty ring)
        if (self.size - self.used() <= total) return false;
        var at = w;
        for (parts) |p| at = self.copyIn(at, p);
        var trailer: [8]u8 = undefined;
        put64(&trailer, 0, @as(u64, w) << 32);
        at = self.copyIn(at, &trailer);
        @atomicStore(u32, @as(*u32, @ptrFromInt(self.base + WRITE_INDEX)), at, .seq_cst);
        return true;
    }

    /// The next packet (descriptor and payload) into `out`, cut to its
    /// length; its whole length, or null when the ring is empty. A packet
    /// longer than `out` is consumed all the same.
    pub fn read(self: Ring, out: []u8) ?usize {
        const avail = self.used();
        if (avail < pkt.DESCRIPTOR_BYTES + 8) return null;
        const r = self.word(READ_INDEX).*;
        var desc: [pkt.DESCRIPTOR_BYTES]u8 = undefined;
        self.copyOut(r, &desc);
        const len: u32 = @as(u32, get16(&desc, 4)) * 8;
        // (a length the ring cannot hold: the other side is not making
        // sense; the ring is emptied rather than read as packets)
        if (len < pkt.DESCRIPTOR_BYTES or len + 8 > avail) {
            self.word(READ_INDEX).* = self.word(WRITE_INDEX).*;
            return null;
        }
        const n: usize = @min(len, out.len);
        self.copyOut(r, out[0..n]);
        @atomicStore(u32, @as(*u32, @ptrFromInt(self.base + READ_INDEX)), (r + len + 8) % self.size, .seq_cst);
        return len;
    }
};

/// A packet as read from a ring.
pub const Packet = struct {
    kind: u16,
    flags: u16,
    /// The sender's id for it: a completion carries the request's.
    id: u64,
    /// Everything after the descriptor's header words, from the packet's
    /// data offset: the device's message.
    body: []const u8,
    /// The whole packet (transfer-page and GPA packets keep their ranges
    /// between the descriptor and the body).
    whole: []const u8,
};

// ══════════════════════════════════════════════════════════════════════════════
// The bus
// ══════════════════════════════════════════════════════════════════════════════

pub const Error = error{
    /// HvPostMessage kept failing.
    PostFailed,
    /// The hypervisor did not answer a control message in time.
    NoAnswer,
    /// No protocol version this driver speaks was accepted.
    NoVersion,
    /// The hypervisor refused a GPADL or the channel's open.
    Refused,
    /// The host gave no memory for a channel's rings.
    NoMemory,
    /// More pages than one GPADL names (MAX_GPADL_PAGES).
    TooManyPages,
};

/// The most pages one GPADL names: its range's length in the header is 16
/// bits of bytes (8, then 8 a page), so just under 32 MiB (Linux keeps its
/// own buffers at 31 MiB for this).
pub const MAX_GPADL_PAGES: u32 = (0xffff - 8) / 8;

pub const MAX_OFFERS = 24;

/// The bus over a host's `Host`, which gives it:
///   post(connection: u32, message_type: u32, payload: []const u8) u16:
///     the HvPostMessage hypercall, its status;
///   signal(connection: u32) void: the HvSignalEvent hypercall;
///   messageSlot() *[256]u8: VMBus's slot in this processor's message page;
///   endOfMessage() void: the end-of-message register written (more wait);
///   vpIndex() u32: this processor's index, where messages are to arrive;
///   pages(count: usize) ?u64: that many zeroed, contiguous pages, whose
///     address is also their guest physical address;
///   delayUs(us: u32) void, note(text: []const u8, value: u64) void.
pub fn Bus(comptime Host: type) type {
    return struct {
        const Self = @This();

        host: *Host,
        version: u32 = 0,
        offers: [MAX_OFFERS]Offer = [_]Offer{.{}} ** MAX_OFFERS,
        offer_count: usize = 0,
        next_gpadl: u32 = 0xE1E10,
        /// The last control message taken from the slot.
        inbox: [hv.MESSAGE_PAYLOAD_MAX]u8 = undefined,

        pub fn init(host: *Host) Self {
            return .{ .host = host };
        }

        /// A control message posted; busy answers are tried again for 100 ms.
        fn post(self: *Self, payload: []const u8) Error!void {
            var tries: u32 = 0;
            while (tries < 100) : (tries += 1) {
                const status = self.host.post(hv.VMBUS_MESSAGE_CONNECTION, hv.MESSAGE_VMBUS, payload);
                if (status == hv.STATUS_SUCCESS) return;
                if (status != hv.STATUS_INSUFFICIENT_BUFFERS and status != hv.STATUS_INSUFFICIENT_MEMORY) {
                    self.host.note("HvPostMessage failed, status", status);
                    return error.PostFailed;
                }
                self.host.delayUs(1000);
            }
            return error.PostFailed;
        }

        /// The message in the slot, if any, taken out: copied to the inbox,
        /// the slot freed, and the hypervisor told when more are waiting.
        pub fn take(self: *Self) ?[]const u8 {
            const slot = self.host.messageSlot();
            const kind: *volatile u32 = @ptrCast(@alignCast(slot));
            const t = kind.*;
            if (t == 0) return null;
            const size: usize = @min(slot[4], hv.MESSAGE_PAYLOAD_MAX);
            const more = slot[5] & 1 != 0;
            @memcpy(self.inbox[0..size], slot[16..][0..size]);
            kind.* = 0;
            if (more) self.host.endOfMessage();
            // (another kind of message: a timer's, an intercept's; not ours)
            if (t != hv.MESSAGE_VMBUS or size < 8) return self.inbox[0..0];
            return self.inbox[0..size];
        }

        /// The next control message of type `want`, for up to `ms`.
        /// Offers that arrive meanwhile are kept.
        fn wait(self: *Self, want: u32, ms: u32) Error![]const u8 {
            var waited: u32 = 0;
            while (waited < ms * 10) {
                const m = self.take() orelse {
                    self.host.delayUs(100);
                    waited += 1;
                    continue;
                };
                if (m.len < 8) continue;
                const t = get32(m, 0);
                if (t == want) return m;
                if (t == msg.OFFER_CHANNEL) self.keep(m);
            }
            return error.NoAnswer;
        }

        fn keep(self: *Self, m: []const u8) void {
            const o = Offer.parse(m) orelse return;
            if (self.offer_count == MAX_OFFERS) return;
            self.offers[self.offer_count] = o;
            self.offer_count += 1;
        }

        /// The handshake: a protocol version agreed, then every device the
        /// hypervisor offers this machine. `monitor_pages`: two zeroed pages
        /// the hypervisor may watch (this driver signals by hypercall and
        /// leaves them alone).
        pub fn connect(self: *Self) Error!void {
            const monitors = self.host.pages(2) orelse return error.NoMemory;
            for (VERSIONS) |v| {
                var m = [_]u8{0} ** 40;
                put32(&m, 0, msg.INITIATE_CONTACT);
                put32(&m, 8, v);
                put32(&m, 12, self.host.vpIndex());
                put64(&m, 24, monitors);
                put64(&m, 32, monitors + PAGE);
                try self.post(&m);
                const r = try self.wait(msg.VERSION_RESPONSE, 2000);
                if (r.len > 8 and r[8] != 0) {
                    self.version = v;
                    break;
                }
            } else return error.NoVersion;
            var m = [_]u8{0} ** 8;
            put32(&m, 0, msg.REQUEST_OFFERS);
            try self.post(&m);
            _ = try self.wait(msg.ALL_OFFERS_DELIVERED, 5000);
        }

        /// The first offered device of class `kind` (not a sub-channel).
        pub fn find(self: *const Self, kind: Guid) ?Offer {
            for (self.offers[0..self.offer_count]) |o| {
                if (o.sub_index == 0 and same(o.kind, kind)) return o;
            }
            return null;
        }

        /// The pages [base, base + count pages) named to the hypervisor as
        /// a GPADL for channel `relid`; its handle.
        pub fn gpadl(self: *Self, relid: u32, base: u64, count: u32) Error!u32 {
            if (count == 0 or count > MAX_GPADL_PAGES) return error.TooManyPages;
            const handle = self.next_gpadl;
            self.next_gpadl += 1;
            var m: [hv.MESSAGE_PAYLOAD_MAX]u8 = undefined;
            @memset(&m, 0);
            put32(&m, 0, msg.GPADL_HEADER);
            put32(&m, 8, relid);
            put32(&m, 12, handle);
            put16(&m, 16, @intCast(8 + 8 * @as(usize, count))); // (the range, in bytes)
            put16(&m, 18, 1); // (one range)
            put32(&m, 20, count * PAGE);
            put32(&m, 24, 0);
            var done: u32 = 0;
            const first: u32 = @min(count, msg.HEADER_PFNS);
            while (done < first) : (done += 1) put64(&m, 28 + 8 * @as(usize, done), base / PAGE + done);
            try self.post(m[0 .. 28 + 8 * @as(usize, first)]);
            var number: u32 = 1;
            while (done < count) : (number += 1) {
                @memset(&m, 0);
                put32(&m, 0, msg.GPADL_BODY);
                put32(&m, 8, number);
                put32(&m, 12, handle);
                const n: u32 = @min(count - done, msg.BODY_PFNS);
                for (0..n) |i| put64(&m, 16 + 8 * i, base / PAGE + done + @as(u32, @intCast(i)));
                done += n;
                try self.post(m[0 .. 16 + 8 * @as(usize, n)]);
            }
            while (true) {
                const r = try self.wait(msg.GPADL_CREATED, 5000);
                if (r.len < 20 or get32(r, 12) != handle) continue;
                if (get32(r, 16) != 0) {
                    self.host.note("the hypervisor refused a GPADL, status", get32(r, 16));
                    return error.Refused;
                }
                return handle;
            }
        }

        /// GPADL `handle` of channel `relid` given back: the host lets go
        /// of its pages (GPADL_TORNDOWN says so).
        pub fn gpadlTeardown(self: *Self, relid: u32, handle: u32) Error!void {
            var m = [_]u8{0} ** 16;
            put32(&m, 0, msg.GPADL_TEARDOWN);
            put32(&m, 8, relid);
            put32(&m, 12, handle);
            try self.post(&m);
            while (true) {
                const r = try self.wait(msg.GPADL_TORNDOWN, 5000);
                if (r.len >= 12 and get32(r, 8) == handle) return;
            }
        }

        /// The offer's channel opened over rings of `send_pages` and
        /// `receive_pages` pages (each a header page and its data).
        pub fn open(self: *Self, offer: Offer, send_pages: u32, receive_pages: u32) Error!Channel(Host) {
            const base = self.host.pages(send_pages + receive_pages) orelse return error.NoMemory;
            const out = Ring.init(base, send_pages, false);
            const in = Ring.init(base + @as(u64, send_pages) * PAGE, receive_pages, true);
            const handle = try self.gpadl(offer.relid, base, send_pages + receive_pages);
            var m = [_]u8{0} ** 148;
            put32(&m, 0, msg.OPEN_CHANNEL);
            put32(&m, 8, offer.relid);
            put32(&m, 12, offer.relid); // (the open's id, echoed in its result)
            put32(&m, 16, handle);
            put32(&m, 20, self.host.vpIndex());
            put32(&m, 24, send_pages); // (where the host's ring starts, in pages)
            try self.post(&m);
            while (true) {
                const r = try self.wait(msg.OPEN_CHANNEL_RESULT, 5000);
                if (r.len < 20 or get32(r, 8) != offer.relid) continue;
                if (get32(r, 16) != 0) {
                    self.host.note("the hypervisor refused a channel's open, status", get32(r, 16));
                    return error.Refused;
                }
                return .{ .host = self.host, .offer = offer, .out = out, .in = in };
            }
        }
    };
}

/// An open channel: packets to the host and from it.
pub fn Channel(comptime Host: type) type {
    return struct {
        const Self = @This();

        host: *Host,
        offer: Offer,
        out: Ring,
        in: Ring,
        next_id: u64 = 1,

        fn descriptor(kind: u16, offset: usize, len: usize, flags: u16, id: u64) [pkt.DESCRIPTOR_BYTES]u8 {
            var d: [pkt.DESCRIPTOR_BYTES]u8 = undefined;
            put16(&d, 0, kind);
            put16(&d, 2, @intCast(offset / 8));
            put16(&d, 4, @intCast(len / 8));
            put16(&d, 6, flags);
            put64(&d, 8, id);
            return d;
        }

        fn padded(n: usize) usize {
            return (n + 7) & ~@as(usize, 7);
        }

        const ZEROS = [_]u8{0} ** 8;

        /// A message in the packet itself. Its id (a completion names it),
        /// or null when the ring is full.
        pub fn send(self: *Self, body: []const u8, want_completion: bool) ?u64 {
            const id = self.next_id;
            const len = pkt.DESCRIPTOR_BYTES + padded(body.len);
            const d = descriptor(pkt.DATA_INBAND, pkt.DESCRIPTOR_BYTES, len, if (want_completion) pkt.FLAG_COMPLETION_REQUESTED else 0, id);
            if (!self.out.write(&.{ &d, body, ZEROS[0 .. padded(body.len) - body.len] })) return null;
            self.next_id += 1;
            self.host.signal(self.offer.connection);
            return id;
        }

        /// A completion for the host's packet `id` (which asked for one).
        pub fn complete(self: *Self, id: u64, body: []const u8) bool {
            const len = pkt.DESCRIPTOR_BYTES + padded(body.len);
            const d = descriptor(pkt.COMPLETION, pkt.DESCRIPTOR_BYTES, len, 0, id);
            if (!self.out.write(&.{ &d, body, ZEROS[0 .. padded(body.len) - body.len] })) return false;
            self.host.signal(self.offer.connection);
            return true;
        }

        /// The most pages one sendWithData names.
        pub const MAX_DATA_PAGES = 66;

        /// A message with `bytes` of the guest's memory at `address` for
        /// the host to read or fill directly (a disk transfer, a frame to
        /// send). Its id, or null when the ring is full.
        pub fn sendWithData(self: *Self, body: []const u8, address: u64, bytes: u32) ?u64 {
            const first = address / PAGE;
            const last = (address + bytes - 1) / PAGE;
            const pages: usize = @intCast(last - first + 1);
            if (bytes == 0 or pages > MAX_DATA_PAGES) return null;
            // descriptor, a reserved word, the range count, then one range:
            // its length, its offset in the first page, its page numbers
            var head: [32 + 8 * MAX_DATA_PAGES]u8 = undefined;
            const head_len = 32 + 8 * pages;
            const id = self.next_id;
            const d = descriptor(pkt.DATA_USING_GPA_DIRECT, head_len, head_len + padded(body.len), pkt.FLAG_COMPLETION_REQUESTED, id);
            @memcpy(head[0..pkt.DESCRIPTOR_BYTES], &d);
            put32(&head, 16, 0);
            put32(&head, 20, 1);
            put32(&head, 24, bytes);
            put32(&head, 28, @intCast(address % PAGE));
            for (0..pages) |i| put64(&head, 32 + 8 * i, first + i);
            if (!self.out.write(&.{ head[0..head_len], body, ZEROS[0 .. padded(body.len) - body.len] })) return null;
            self.next_id += 1;
            self.host.signal(self.offer.connection);
            return id;
        }

        /// The next packet from the host into `buf`, or null when there is
        /// none. The host is told when it was waiting for room.
        pub fn receive(self: *Self, buf: []u8) ?Packet {
            const len = self.in.read(buf) orelse return null;
            if (self.in.writerWaits()) self.host.signal(self.offer.connection);
            const n = @min(len, buf.len);
            const offset: usize = @as(usize, get16(buf, 2)) * 8;
            const body_at = @min(@max(offset, pkt.DESCRIPTOR_BYTES), n);
            return .{ .kind = get16(buf, 0), .flags = get16(buf, 6), .id = get64(buf, 8), .body = buf[body_at..n], .whole = buf[0..n] };
        }
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// For the devices' tests: a channel whose far end the test plays
// ══════════════════════════════════════════════════════════════════════════════

pub const testing = struct {
    /// A host that counts signals and, when a device's test gives it one,
    /// lets the far end answer at each signal (as the hypervisor would,
    /// before the guest's next look at its ring).
    pub const Host = struct {
        signals: u32 = 0,
        waited_us: u64 = 0,
        answer: ?*const fn (ctx: *anyopaque) void = null,
        ctx: *anyopaque = undefined,

        pub fn signal(self: *Host, _: u32) void {
            self.signals += 1;
            if (self.answer) |f| f(self.ctx);
        }

        pub fn delayUs(self: *Host, us: u32) void {
            self.waited_us += us;
        }
    };

    /// A channel over rings in `mem`, as Bus.open would leave it.
    pub fn channel(comptime H: type, host: *H, mem: []align(PAGE) u8, send_pages: u32) Channel(H) {
        const base = @intFromPtr(mem.ptr);
        const total: u32 = @intCast(mem.len / PAGE);
        return .{
            .host = host,
            .offer = .{ .relid = 1, .connection = 0x2001 },
            .out = Ring.init(base, send_pages, false),
            .in = Ring.init(base + @as(u64, send_pages) * PAGE, total - send_pages, true),
        };
    }

    /// A packet from the host into a channel's incoming ring.
    pub fn fromHost(ring: Ring, kind: u16, id: u64, body: []const u8) bool {
        var d: [pkt.DESCRIPTOR_BYTES]u8 = undefined;
        const padded = (body.len + 7) & ~@as(usize, 7);
        put16(&d, 0, kind);
        put16(&d, 2, 2);
        put16(&d, 4, @intCast((pkt.DESCRIPTOR_BYTES + padded) / 8));
        put16(&d, 6, 0);
        put64(&d, 8, id);
        const zeros = [_]u8{0} ** 8;
        return ring.write(&.{ &d, body, zeros[0 .. padded - body.len] });
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// A fake hypervisor (tests only): the control messages and both rings' far ends
// ══════════════════════════════════════════════════════════════════════════════

const Fake = struct {
    slot: [hv.MESSAGE_SLOT_BYTES]u8 align(8) = [_]u8{0} ** hv.MESSAGE_SLOT_BYTES,
    /// Messages waiting for the slot.
    queue: [16][hv.MESSAGE_PAYLOAD_MAX]u8 = undefined,
    queue_len: [16]usize = [_]usize{0} ** 16,
    head: usize = 0,
    tail: usize = 0,
    arena: [96 * PAGE]u8 align(PAGE) = undefined,
    arena_used: usize = 0,

    /// The newest version this hypervisor accepts.
    newest: u32 = 0x0004_0000,
    devices: []const Guid = &.{ device.keyboard, device.scsi },
    busy_posts: u32 = 0,
    refuse_open: bool = false,

    // What it saw.
    contacts: u32 = 0,
    eoms: u32 = 0,
    signals: u32 = 0,
    last_signal: u32 = 0,
    gpadl_pfns: [80]u64 = undefined,
    gpadl_count: usize = 0,
    gpadl_expected: usize = 0,
    gpadl_handle: u32 = 0,
    gpadl_relid: u32 = 0,
    torn_down: u32 = 0,
    out_ring: Ring = .{},
    in_ring: Ring = .{},
    notes: u32 = 0,

    fn enqueue(self: *Fake, payload: []const u8) void {
        @memcpy(self.queue[self.tail % 16][0..payload.len], payload);
        self.queue_len[self.tail % 16] = payload.len;
        self.tail += 1;
        self.deliver();
    }

    /// The next queued message into the slot, when the slot is free.
    fn deliver(self: *Fake) void {
        if (self.head == self.tail) return;
        if (get32(&self.slot, 0) != 0) {
            self.slot[5] |= 1; // (more waiting behind the one in the slot)
            return;
        }
        const n = self.queue_len[self.head % 16];
        @memcpy(self.slot[16..][0..n], self.queue[self.head % 16][0..n]);
        self.slot[4] = @intCast(n);
        self.head += 1;
        self.slot[5] = if (self.head != self.tail) 1 else 0; // (more waiting)
        put32(&self.slot, 0, hv.MESSAGE_VMBUS);
    }

    fn offer(self: *Fake, kind: Guid, relid: u32) void {
        var m = [_]u8{0} ** 196;
        put32(&m, 0, msg.OFFER_CHANNEL);
        @memcpy(m[8..24], &kind);
        m[24] = @intCast(relid);
        put32(&m, 184, relid);
        put32(&m, 192, 0x2000 + relid);
        self.enqueue(&m);
    }

    fn gpadlDone(self: *Fake) void {
        var r = [_]u8{0} ** 20;
        put32(&r, 0, msg.GPADL_CREATED);
        put32(&r, 8, self.gpadl_relid);
        put32(&r, 12, self.gpadl_handle);
        self.enqueue(&r);
    }

    // ── Host ──

    pub fn post(self: *Fake, connection: u32, message_type: u32, payload: []const u8) u16 {
        if (connection != hv.VMBUS_MESSAGE_CONNECTION or message_type != hv.MESSAGE_VMBUS) return 0x11; // (invalid connection)
        if (payload.len > hv.MESSAGE_PAYLOAD_MAX) return 0x05;
        if (self.busy_posts != 0) {
            self.busy_posts -= 1;
            return hv.STATUS_INSUFFICIENT_BUFFERS;
        }
        switch (get32(payload, 0)) {
            msg.INITIATE_CONTACT => {
                self.contacts += 1;
                var r = [_]u8{0} ** 12;
                put32(&r, 0, msg.VERSION_RESPONSE);
                r[8] = @intFromBool(get32(payload, 8) <= self.newest);
                self.enqueue(&r);
            },
            msg.REQUEST_OFFERS => {
                for (self.devices, 0..) |d, i| self.offer(d, @intCast(i + 1));
                var r = [_]u8{0} ** 8;
                put32(&r, 0, msg.ALL_OFFERS_DELIVERED);
                self.enqueue(&r);
            },
            msg.GPADL_HEADER => {
                self.gpadl_relid = get32(payload, 8);
                self.gpadl_handle = get32(payload, 12);
                self.gpadl_expected = (get16(payload, 16) - 8) / 8;
                self.gpadl_count = 0;
                var at: usize = 28;
                while (at + 8 <= payload.len) : (at += 8) {
                    self.gpadl_pfns[self.gpadl_count] = get64(payload, at);
                    self.gpadl_count += 1;
                }
                if (self.gpadl_count == self.gpadl_expected) self.gpadlDone();
            },
            msg.GPADL_BODY => {
                var at: usize = 16;
                while (at + 8 <= payload.len) : (at += 8) {
                    self.gpadl_pfns[self.gpadl_count] = get64(payload, at);
                    self.gpadl_count += 1;
                }
                if (self.gpadl_count == self.gpadl_expected) self.gpadlDone();
            },
            msg.GPADL_TEARDOWN => {
                self.torn_down = get32(payload, 12);
                var r = [_]u8{0} ** 12;
                put32(&r, 0, msg.GPADL_TORNDOWN);
                put32(&r, 8, get32(payload, 12));
                self.enqueue(&r);
            },
            msg.OPEN_CHANNEL => {
                // The far ends of the rings, from the GPADL and the offset.
                const send_pages = get32(payload, 24);
                const base = self.gpadl_pfns[0] * PAGE;
                self.out_ring = .{ .base = base, .size = (send_pages - 1) * PAGE };
                self.in_ring = .{ .base = base + @as(u64, send_pages) * PAGE, .size = @intCast((self.gpadl_count - send_pages - 1) * PAGE) };
                var r = [_]u8{0} ** 20;
                put32(&r, 0, msg.OPEN_CHANNEL_RESULT);
                put32(&r, 8, get32(payload, 8));
                put32(&r, 12, get32(payload, 12));
                put32(&r, 16, if (self.refuse_open) 0xC000_0001 else 0);
                self.enqueue(&r);
            },
            else => {},
        }
        return hv.STATUS_SUCCESS;
    }

    pub fn signal(self: *Fake, connection: u32) void {
        self.signals += 1;
        self.last_signal = connection;
    }

    pub fn messageSlot(self: *Fake) *[hv.MESSAGE_SLOT_BYTES]u8 {
        return &self.slot;
    }

    pub fn endOfMessage(self: *Fake) void {
        self.eoms += 1;
        self.deliver();
    }

    pub fn vpIndex(_: *Fake) u32 {
        return 0;
    }

    pub fn pages(self: *Fake, count: usize) ?u64 {
        if (self.arena_used + count * PAGE > self.arena.len) return null;
        const at = self.arena_used;
        self.arena_used += count * PAGE;
        @memset(self.arena[at..][0 .. count * PAGE], 0);
        return @intFromPtr(&self.arena[at]);
    }

    pub fn delayUs(_: *Fake, _: u32) void {}

    pub fn note(self: *Fake, _: []const u8, _: u64) void {
        self.notes += 1;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

const Bench = struct {
    var fake: Fake = .{};

    fn fresh() *Fake {
        fake = .{};
        return &fake;
    }
};

fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

test "vmbus: a GUID's bytes" {
    const k = device.keyboard;
    try expect(k[0] == 0x6d and k[1] == 0xad and k[2] == 0x12 and k[3] == 0xf9);
    try expect(k[4] == 0x17 and k[5] == 0x2b and k[6] == 0xea and k[7] == 0x48);
    try expect(k[8] == 0xbd and k[15] == 0x84);
    try expect(same(device.scsi, guid("BA6163D9-04A1-4D29-B605-72E2FFB1DC7F")));
    try expect(!same(device.scsi, device.network));
    try expect(device.name(device.mouse).len == 5);
}

test "vmbus: a ring carries packets around its end" {
    var mem: [3 * PAGE]u8 align(PAGE) = undefined;
    const ring = Ring.init(@intFromPtr(&mem), 3, true);
    try expect(ring.size == 2 * PAGE and ring.used() == 0);
    try expect(get32(&mem, 8) == 1 and get32(&mem, 64) == 1); // (masked; feature bit)
    var buf: [1024]u8 = undefined;
    try expect(ring.read(&buf) == null);
    // 40 packets of 16 + 600 + 8 bytes through an 8 KiB ring: the indices
    // wrap, and every byte comes back.
    var body: [600]u8 = undefined;
    var k: u32 = 0;
    while (k < 40) : (k += 1) {
        for (&body, 0..) |*b, i| b.* = @truncate(i + k);
        var d: [16]u8 = undefined;
        put16(&d, 0, pkt.DATA_INBAND);
        put16(&d, 2, 2);
        put16(&d, 4, (16 + 600) / 8);
        put16(&d, 6, 0);
        put64(&d, 8, k);
        try expect(ring.write(&.{ &d, &body }));
        const n = ring.read(&buf) orelse return error.TestUnexpectedResult;
        try expect(n == 616 and get64(&buf, 8) == k);
        try expect(buf[16] == @as(u8, @truncate(k)) and buf[615] == @as(u8, @truncate(599 + k)));
    }
    try expect(ring.used() == 0);
    try expect(get32(&mem, 0) == (40 * 624) % (2 * PAGE));
}

test "vmbus: a full ring refuses a packet whole" {
    var mem: [2 * PAGE]u8 align(PAGE) = undefined;
    const ring = Ring.init(@intFromPtr(&mem), 2, false);
    var d: [16]u8 = undefined;
    put16(&d, 0, pkt.DATA_INBAND);
    put16(&d, 2, 2);
    put16(&d, 4, (16 + 1000) / 8);
    put16(&d, 6, 0);
    put64(&d, 8, 7);
    const body = [_]u8{0xAA} ** 1000;
    var n: u32 = 0;
    while (ring.write(&.{ &d, &body })) n += 1;
    try expect(n == 3); // (3 x 1024 of 4096: a fourth would leave no free byte)
    try expect(ring.used() == 3 * 1024);
    var buf: [1100]u8 = undefined;
    try expect(ring.read(&buf).? == 1016);
    try expect(ring.write(&.{ &d, &body }));
    // A packet longer than the reader's buffer is cut, and consumed.
    var small: [64]u8 = undefined;
    try expect(ring.read(&small).? == 1016 and small[63] == 0xAA);
    try expect(ring.used() == 2 * 1024);
}

test "vmbus: a ring that makes no sense is emptied, not followed" {
    var mem: [2 * PAGE]u8 align(PAGE) = undefined;
    const ring = Ring.init(@intFromPtr(&mem), 2, true);
    // 64 bytes "written" whose descriptor claims 8 KiB.
    put16(mem[PAGE..], 4, 1024);
    put32(&mem, 0, 64);
    var buf: [256]u8 = undefined;
    try expect(ring.read(&buf) == null);
    try expect(ring.used() == 0);
}

test "vmbus: the handshake, and the offers" {
    const f = Bench.fresh();
    var bus = Bus(Fake).init(f);
    try bus.connect();
    try expect(bus.version == 0x0004_0000 and f.contacts == 1);
    try expect(bus.offer_count == 2);
    const k = bus.find(device.keyboard) orelse return error.TestUnexpectedResult;
    try expect(k.relid == 1 and k.connection == 0x2001);
    try expect(bus.find(device.scsi).?.relid == 2);
    try expect(bus.find(device.network) == null);
    // Three messages waited in the queue behind the first: each taken one
    // said "more are waiting", and the hypervisor was told.
    try expect(f.eoms >= 2);
}

test "vmbus: an older hypervisor, and a busy one" {
    const f = Bench.fresh();
    f.newest = 0x0002_0004;
    f.busy_posts = 3;
    var bus = Bus(Fake).init(f);
    try bus.connect();
    try expect(bus.version == 0x0002_0004 and f.contacts == 3);
    // One that speaks none of them.
    const g = Bench.fresh();
    g.newest = 0x0001_0000;
    var old = Bus(Fake).init(g);
    try expect(if (old.connect()) |_| false else |e| e == error.NoVersion);
}

test "vmbus: a channel's rings named in one message, and opened" {
    const f = Bench.fresh();
    var bus = Bus(Fake).init(f);
    try bus.connect();
    var ch = try bus.open(bus.find(device.keyboard).?, 2, 3);
    try expect(f.gpadl_count == 5 and f.gpadl_relid == 1);
    try expect(f.gpadl_pfns[1] == f.gpadl_pfns[0] + 1 and f.gpadl_pfns[4] == f.gpadl_pfns[0] + 4);
    try expect(ch.out.base == f.gpadl_pfns[0] * PAGE and ch.out.size == PAGE);
    try expect(ch.in.base == ch.out.base + 2 * PAGE and ch.in.size == 2 * PAGE);
    try expect(f.out_ring.base == ch.out.base and f.in_ring.size == ch.in.size);

    // To the host: a message in the packet, a completion wanted.
    const id = ch.send("hello host", true) orelse return error.TestUnexpectedResult;
    try expect(f.signals == 1 and f.last_signal == 0x2001);
    var buf: [256]u8 = undefined;
    const n = f.out_ring.read(&buf) orelse return error.TestUnexpectedResult;
    try expect(n == 16 + 16); // (10 bytes padded to 16)
    try expect(get16(&buf, 0) == pkt.DATA_INBAND and get16(&buf, 2) == 2 and get16(&buf, 6) == 1);
    try expect(get64(&buf, 8) == id and buf[16] == 'h' and buf[25] == 't' and buf[26] == 0);

    // From the host: its completion, then a message of its own.
    var d: [16]u8 = undefined;
    put16(&d, 0, pkt.COMPLETION);
    put16(&d, 2, 2);
    put16(&d, 4, 3);
    put16(&d, 6, 0);
    put64(&d, 8, id);
    try expect(f.in_ring.write(&.{ &d, "done...." }));
    const p = ch.receive(&buf) orelse return error.TestUnexpectedResult;
    try expect(p.kind == pkt.COMPLETION and p.id == id and p.body.len == 8 and p.body[0] == 'd');
    try expect(ch.receive(&buf) == null);
    // The host waiting for room is signalled once the guest has read.
    put32(@as([*]u8, @ptrFromInt(ch.in.base))[0..PAGE], 12, 512);
    try expect(f.in_ring.write(&.{ &d, "again..." }));
    const before = f.signals;
    try expect(ch.receive(&buf) != null);
    try expect(f.signals == before + 1);
}

test "vmbus: more pages than one message holds" {
    const f = Bench.fresh();
    var bus = Bus(Fake).init(f);
    try bus.connect();
    const ch = try bus.open(bus.find(device.scsi).?, 30, 40);
    try expect(f.gpadl_count == 70 and f.gpadl_expected == 70);
    for (f.gpadl_pfns[0..70], 0..) |pfn, i| try expect(pfn == f.gpadl_pfns[0] + i);
    try expect(ch.in.base == ch.out.base + 30 * PAGE and ch.in.size == 39 * PAGE);
}

test "vmbus: a GPADL given back; one too big refused" {
    const f = Bench.fresh();
    var bus = Bus(Fake).init(f);
    try bus.connect();
    const h = try bus.gpadl(3, 0x10_0000, 16);
    try bus.gpadlTeardown(3, h);
    try expect(f.torn_down == h);
    try expect(if (bus.gpadl(3, 0x10_0000, MAX_GPADL_PAGES + 1)) |_| false else |e| e == error.TooManyPages);
}

test "vmbus: memory for the host to read or fill" {
    const f = Bench.fresh();
    var bus = Bus(Fake).init(f);
    try bus.connect();
    var ch = try bus.open(bus.find(device.scsi).?, 5, 5);
    // 9000 bytes starting 100 bytes into a page: three pages.
    const address: u64 = 0x1234_5000 + 100;
    const id = ch.sendWithData("request", address, 9000) orelse return error.TestUnexpectedResult;
    var buf: [256]u8 = undefined;
    const n = f.out_ring.read(&buf) orelse return error.TestUnexpectedResult;
    try expect(get16(&buf, 0) == pkt.DATA_USING_GPA_DIRECT and get16(&buf, 6) == 1 and get64(&buf, 8) == id);
    try expect(get16(&buf, 2) == (32 + 24) / 8 and n == 32 + 24 + 8);
    try expect(get32(&buf, 20) == 1 and get32(&buf, 24) == 9000 and get32(&buf, 28) == 100);
    try expect(get64(&buf, 32) == 0x12345 and get64(&buf, 48) == 0x12347);
    try expect(buf[56] == 'r' and buf[62] == 't' and buf[63] == 0);
    // Nothing to move, or too much for one packet: refused.
    try expect(ch.sendWithData("x", address, 0) == null);
    try expect(ch.sendWithData("x", 0x1000, 67 * PAGE) == null);
}

test "vmbus: a refused open, and a silent hypervisor" {
    const f = Bench.fresh();
    f.refuse_open = true;
    var bus = Bus(Fake).init(f);
    try bus.connect();
    try expect(if (bus.open(bus.find(device.keyboard).?, 2, 2)) |_| false else |e| e == error.Refused);
    try expect(f.notes == 1);
    // No hypervisor behind the hypercalls at all.
    const g = Bench.fresh();
    g.devices = &.{};
    var silent = Bus(Fake).init(g);
    g.newest = 0;
    try expect(if (silent.connect()) |_| false else |e| e == error.NoVersion);
}
