//! Hyper-V's synthetic SCSI controller: every disk of a generation 2
//! machine. SCSI commands travel as 64-byte packets over a VMBus channel;
//! a command's data stays in the guest's memory, named to the host by its
//! pages, and the host reads or fills it directly.
//!
//! The handshake is four exchanges (begin, a protocol version, the
//! channel's properties, end); after it each command is one packet out and
//! one completion back, carrying the SCSI status, the bytes moved and,
//! after a CHECK CONDITION, the sense data.
//!
//! Zero allocation, freestanding; over an open VMBus channel (vmbus.sig).
//! The packet layout is the one Linux's storvsc documents (documentation
//! only).

const vmbus = @import("vmbus.sig");
const put16 = vmbus.put16;
const put32 = vmbus.put32;
const get32 = vmbus.get32;

const OP_COMPLETE_IO: u32 = 1;
const OP_EXECUTE_SRB: u32 = 3;
const OP_BEGIN_INITIALIZATION: u32 = 7;
const OP_END_INITIALIZATION: u32 = 8;
const OP_QUERY_PROTOCOL_VERSION: u32 = 9;
const OP_QUERY_PROPERTIES: u32 = 10;
const FLAG_REQUEST_COMPLETION: u32 = 1;

/// A packet: the operation, flags and status, then 52 bytes whose meaning
/// the operation gives (a SCSI request, the properties, a version).
pub const PACKET_BYTES = 64;
/// A SCSI request's length field: the request with Windows 8's extension.
const REQUEST_BYTES: u16 = 52;
const SENSE_BYTES = 20;

/// Protocol versions (major << 8 | minor), newest first: Windows 10's,
/// 8.1's and 8's all use the 64-byte packet.
const VERSIONS = [_]u16{ 0x0602, 0x0600, 0x0501 };

const SRB_STATUS_SUCCESS: u8 = 1;
const SRB_STATUS_AUTOSENSE_VALID: u8 = 0x80;
const SRB_FLAGS_DISABLE_SYNCH_TRANSFER: u32 = 0x08;
const SRB_FLAGS_DATA_IN: u32 = 0x40;
const SRB_FLAGS_DATA_OUT: u32 = 0x80;
const SCSI_CHECK_CONDITION: u8 = 2;

/// Ring sizes: a command's packet names up to 66 pages (a 256 KiB transfer).
pub const SEND_PAGES = 5;
pub const RECEIVE_PAGES = 5;

pub const Error = error{
    /// The channel's ring has no room (the host is not reading it).
    RingFull,
    /// No completion came back in time.
    NoAnswer,
    /// The host refused a step of the handshake.
    Refused,
    /// The host speaks none of this driver's protocol versions.
    NoVersion,
};

/// How a SCSI command ended.
pub const Outcome = struct {
    /// The command succeeded (the SCSI status is GOOD).
    ok: bool,
    /// It ended in CHECK CONDITION: `sense` says why.
    check: bool,
    /// Bytes of data the host moved.
    moved: u32,
};

pub fn Storage(comptime Host: type) type {
    return struct {
        const Self = @This();

        ch: vmbus.Channel(Host),
        version: u16 = 0,
        /// The most bytes of data one command may carry, as the host says.
        max_transfer: u32 = 0,
        /// The sense data of the last command that ended in CHECK CONDITION.
        sense: [SENSE_BYTES]u8 = [_]u8{0} ** SENSE_BYTES,
        sense_valid: bool = false,
        /// The last exchange, in microseconds waited: until the host had
        /// taken the request out of the ring, and until its answer came.
        taken_us: u64 = 0,
        answered_us: u64 = 0,

        /// One packet out (with `len` bytes at `address` for the host to
        /// read or fill, when not 0) and its completion back into `m`.
        fn exchange(self: *Self, m: *[PACKET_BYTES]u8, address: u64, len: u32, wait_ms: u32) Error!void {
            const sent = if (len != 0) self.ch.sendWithData(m, address, len) else self.ch.send(m, true);
            const id = sent orelse return error.RingFull;
            var buf: [256]u8 = undefined;
            var waited: u64 = 0;
            self.taken_us = 0;
            var taken = false;
            while (waited < @as(u64, wait_ms) * 1000) {
                if (!taken and self.ch.out.used() == 0) {
                    taken = true;
                    self.taken_us = waited;
                }
                const p = self.ch.receive(&buf) orelse {
                    self.ch.host.delayUs(10);
                    waited += 10;
                    continue;
                };
                // (anything else from the host, a bus rescan's notice, is
                // not this command's answer)
                if (p.kind != vmbus.pkt.COMPLETION or p.id != id) continue;
                if (!taken) self.taken_us = waited;
                self.answered_us = waited;
                @memset(m, 0);
                const n = @min(p.body.len, PACKET_BYTES);
                @memcpy(m[0..n], p.body[0..n]);
                return;
            }
            return error.NoAnswer;
        }

        fn step(self: *Self, operation: u32, version: u16) Error![PACKET_BYTES]u8 {
            var m = [_]u8{0} ** PACKET_BYTES;
            put32(&m, 0, operation);
            put32(&m, 4, FLAG_REQUEST_COMPLETION);
            put16(&m, 12, version);
            try self.exchange(&m, 0, 0, 5000);
            return m;
        }

        /// The handshake. After it the controller takes SCSI commands.
        pub fn start(self: *Self) Error!void {
            const begun = try self.step(OP_BEGIN_INITIALIZATION, 0);
            if (get32(&begun, 8) != 0) return error.Refused;
            for (VERSIONS) |v| {
                const r = try self.step(OP_QUERY_PROTOCOL_VERSION, v);
                if (get32(&r, 8) == 0) {
                    self.version = v;
                    break;
                }
            } else return error.NoVersion;
            const props = try self.step(OP_QUERY_PROPERTIES, 0);
            if (get32(&props, 8) != 0) return error.Refused;
            self.max_transfer = get32(&props, 24);
            const ended = try self.step(OP_END_INITIALIZATION, 0);
            if (get32(&ended, 8) != 0) return error.Refused;
        }

        /// One SCSI command to the disk at `lun` (its location on the
        /// controller), with `len` bytes of data at `address` in the
        /// guest's memory: from the disk when `in`, to it otherwise.
        pub fn command(self: *Self, lun: u8, cdb: []const u8, address: u64, len: u32, in: bool) Error!Outcome {
            var m = [_]u8{0} ** PACKET_BYTES;
            put32(&m, 0, OP_EXECUTE_SRB);
            put32(&m, 4, FLAG_REQUEST_COMPLETION);
            put16(&m, 12, REQUEST_BYTES);
            m[19] = lun; // (port, path and target are 0)
            m[20] = @intCast(@min(cdb.len, 16));
            m[21] = SENSE_BYTES;
            m[22] = if (len == 0) 2 else @intFromBool(in); // 0: to the disk, 1: from it, 2: none
            put32(&m, 24, len);
            @memcpy(m[28..][0..m[20]], cdb[0..m[20]]);
            put32(&m, 52, SRB_FLAGS_DISABLE_SYNCH_TRANSFER | (if (len == 0) @as(u32, 0) else if (in) SRB_FLAGS_DATA_IN else SRB_FLAGS_DATA_OUT));
            put32(&m, 56, 60); // (seconds the host may take)
            try self.exchange(&m, address, len, 30_000);
            const srb = m[14];
            const scsi = m[15];
            self.sense_valid = srb & SRB_STATUS_AUTOSENSE_VALID != 0;
            if (self.sense_valid) @memcpy(&self.sense, m[28..][0..SENSE_BYTES]);
            return .{
                .ok = get32(&m, 0) == OP_COMPLETE_IO and srb & 0x3F == SRB_STATUS_SUCCESS and scsi == 0,
                .check = scsi == SCSI_CHECK_CONDITION,
                .moved = get32(&m, 24),
            };
        }
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests: a controller with one small disk at the far end of the channel
// ══════════════════════════════════════════════════════════════════════════════

const TestHost = vmbus.testing.Host;

const FakeDisk = struct {
    ch: *vmbus.Channel(TestHost),
    sectors: [64][512]u8 = undefined,
    newest: u16 = 0x0602,
    max_transfer: u32 = 0x40000,
    silent: bool = false,
    commands: u32 = 0,
    last_lun: u8 = 0xFF,
    began: bool = false,
    ended: bool = false,

    fn answer(ctx: *anyopaque) void {
        const self: *FakeDisk = @ptrCast(@alignCast(ctx));
        var buf: [1024]u8 = undefined;
        while (self.ch.out.read(&buf)) |len| {
            if (self.silent) continue;
            const whole = buf[0..@min(len, buf.len)];
            const body = whole[@as(usize, vmbus.get16(whole, 2)) * 8 ..];
            var r = [_]u8{0} ** PACKET_BYTES;
            @memcpy(&r, body[0..PACKET_BYTES]);
            const op = get32(body, 0);
            put32(&r, 0, OP_COMPLETE_IO);
            put32(&r, 8, 0);
            switch (op) {
                OP_BEGIN_INITIALIZATION => self.began = true,
                OP_END_INITIALIZATION => self.ended = true,
                OP_QUERY_PROTOCOL_VERSION => if (vmbus.get16(body, 12) > self.newest) put32(&r, 8, 0xC000_0001),
                OP_QUERY_PROPERTIES => put32(&r, 24, self.max_transfer),
                OP_EXECUTE_SRB => self.scsi(whole, body, &r),
                else => put32(&r, 8, 0xC000_0001),
            }
            _ = vmbus.testing.fromHost(self.ch.in, vmbus.pkt.COMPLETION, vmbus.get64(whole, 8), &r);
        }
    }

    /// The data's place in the guest's memory, from a packet's page range.
    fn data(whole: []const u8) [*]u8 {
        return @ptrFromInt(vmbus.get64(whole, 32) * vmbus.PAGE + get32(whole, 28));
    }

    fn scsi(self: *FakeDisk, whole: []const u8, body: []const u8, r: *[PACKET_BYTES]u8) void {
        self.commands += 1;
        self.last_lun = body[19];
        const cdb = body[28..44];
        const direct = vmbus.get16(whole, 0) == vmbus.pkt.DATA_USING_GPA_DIRECT;
        r[14] = SRB_STATUS_SUCCESS;
        r[15] = 0;
        switch (cdb[0]) {
            0x00 => put32(r, 24, 0), // TEST UNIT READY
            0x25 => { // READ CAPACITY (10): the last block, the block size
                const d = data(whole);
                @memset(d[0..8], 0);
                d[3] = 63;
                d[6] = 2;
                put32(r, 24, 8);
            },
            0x28, 0x2A => { // READ (10), WRITE (10)
                const lba = @as(u32, cdb[2]) << 24 | @as(u32, cdb[3]) << 16 | @as(u32, cdb[4]) << 8 | cdb[5];
                const blocks = @as(u32, cdb[7]) << 8 | cdb[8];
                if (!direct or lba + blocks > 64) {
                    r[14] = 0x04 | SRB_STATUS_AUTOSENSE_VALID; // (error, with sense)
                    r[15] = SCSI_CHECK_CONDITION;
                    @memset(r[28..48], 0);
                    r[28] = 0x70;
                    r[30] = 5; // ILLEGAL REQUEST
                    r[40] = 0x21; // (LBA out of range)
                    put32(r, 24, 0);
                    return;
                }
                const d = data(whole);
                for (0..blocks) |i| {
                    if (cdb[0] == 0x28) @memcpy(d[i * 512 ..][0..512], &self.sectors[lba + i]) else @memcpy(&self.sectors[lba + i], d[i * 512 ..][0..512]);
                }
                put32(r, 24, blocks * 512);
            },
            else => { // (a command this disk does not have)
                r[14] = 0x04 | SRB_STATUS_AUTOSENSE_VALID;
                r[15] = SCSI_CHECK_CONDITION;
                @memset(r[28..48], 0);
                r[28] = 0x70;
                r[30] = 5;
                r[40] = 0x20;
                put32(r, 24, 0);
            },
        }
    }
};

const Bench = struct {
    var host: TestHost = .{};
    var mem: [10 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var ctl: Storage(TestHost) = undefined;
    var disk: FakeDisk = undefined;
    var bounce: [16 * 512]u8 align(vmbus.PAGE) = undefined;

    fn fresh() *FakeDisk {
        host = .{};
        ctl = .{ .ch = vmbus.testing.channel(TestHost, &host, &mem, SEND_PAGES) };
        disk = .{ .ch = &ctl.ch };
        for (&disk.sectors, 0..) |*s, i| @memset(s, @intCast(i));
        host.answer = FakeDisk.answer;
        host.ctx = &disk;
        return &disk;
    }
};

fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

test "storage: the handshake" {
    const d = Bench.fresh();
    try Bench.ctl.start();
    try expect(d.began and d.ended);
    try expect(Bench.ctl.version == 0x0602 and Bench.ctl.max_transfer == 0x40000);
    // An older host: Windows 8's version is settled on.
    const old = Bench.fresh();
    old.newest = 0x0501;
    try Bench.ctl.start();
    try expect(Bench.ctl.version == 0x0501);
    // One older still: none.
    const ancient = Bench.fresh();
    ancient.newest = 0x0402;
    try expect(if (Bench.ctl.start()) |_| false else |e| e == error.NoVersion);
}

test "storage: read, write and read back" {
    const d = Bench.fresh();
    try Bench.ctl.start();
    const at = @intFromPtr(&Bench.bounce);
    // READ CAPACITY (10): 64 blocks of 512 bytes.
    var cap = [_]u8{0} ** 10;
    cap[0] = 0x25;
    var o = try Bench.ctl.command(0, &cap, at, 8, true);
    try expect(o.ok and o.moved == 8 and Bench.bounce[3] == 63 and Bench.bounce[6] == 2);
    // Four sectors from sector 5.
    var read = [_]u8{0} ** 10;
    read[0] = 0x28;
    read[5] = 5;
    read[8] = 4;
    o = try Bench.ctl.command(3, &read, at, 4 * 512, true);
    try expect(o.ok and o.moved == 2048 and d.last_lun == 3);
    try expect(Bench.bounce[0] == 5 and Bench.bounce[511] == 5 and Bench.bounce[512] == 6 and Bench.bounce[2047] == 8);
    // Two sectors written to sector 40, and read back.
    @memset(Bench.bounce[0..1024], 0xC3);
    var write = [_]u8{0} ** 10;
    write[0] = 0x2A;
    write[5] = 40;
    write[8] = 2;
    o = try Bench.ctl.command(0, &write, at, 1024, false);
    try expect(o.ok and d.sectors[40][0] == 0xC3 and d.sectors[41][511] == 0xC3 and d.sectors[42][0] == 42);
    @memset(&Bench.bounce, 0);
    read[5] = 41;
    read[8] = 1;
    o = try Bench.ctl.command(0, &read, at, 512, true);
    try expect(o.ok and Bench.bounce[0] == 0xC3 and Bench.bounce[511] == 0xC3);
    // A command with no data.
    const ready = [_]u8{0} ** 6;
    o = try Bench.ctl.command(0, &ready, 0, 0, false);
    try expect(o.ok and o.moved == 0 and !Bench.ctl.sense_valid);
}

test "storage: a refused command leaves its sense" {
    _ = Bench.fresh();
    try Bench.ctl.start();
    // SYNCHRONIZE CACHE, which this disk does not have.
    var sync = [_]u8{0} ** 10;
    sync[0] = 0x35;
    var o = try Bench.ctl.command(0, &sync, 0, 0, false);
    try expect(!o.ok and o.check and Bench.ctl.sense_valid);
    try expect(Bench.ctl.sense[2] & 0xF == 5 and Bench.ctl.sense[12] == 0x20);
    // A read past the disk's end.
    var read = [_]u8{0} ** 10;
    read[0] = 0x28;
    read[5] = 63;
    read[8] = 2;
    o = try Bench.ctl.command(0, &read, @intFromPtr(&Bench.bounce), 1024, true);
    try expect(!o.ok and o.check and Bench.ctl.sense[12] == 0x21);
    // The next good command clears it.
    read[8] = 1;
    o = try Bench.ctl.command(0, &read, @intFromPtr(&Bench.bounce), 512, true);
    try expect(o.ok and !Bench.ctl.sense_valid);
}

test "storage: a host that does not answer" {
    const d = Bench.fresh();
    try Bench.ctl.start();
    d.silent = true;
    const ready = [_]u8{0} ** 6;
    try expect(if (Bench.ctl.command(0, &ready, 0, 0, false)) |_| false else |e| e == error.NoAnswer);
    try expect(Bench.host.waited_us >= 30_000_000);
}
