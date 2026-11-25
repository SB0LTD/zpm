//! @zpm/nvidia push — pushbuffers for an NVIDIA channel: the methods a
//! compute batch sends (BLACKWELL_COMPUTE_B, clcec0.h, on subchannel 1 as
//! tinygrad binds it), the host's semaphore release (clc96f.h), and the
//! GPFIFO entries and doorbell token that hand a pushbuffer to the GPU.
//!
//! A pushbuffer is dwords: a method header (cla06f.h's NV_FIFO_DMA_*: the
//! method's address over 4, its subchannel, a count and how the data
//! advances), then its data. The host's methods (below 0x100) work on any
//! subchannel. These are Galaxy's encodings (src/kernel/nv_chan.sig), which
//! the Legion 5's RTX 5070 Laptop GPU ran (M4, M5, `keep`); the tests keep
//! Galaxy's expected words, so the bits stay identical.
//!
//! `Push` writes into the caller's dwords and remembers an overflow rather
//! than writing past them: `check` says whether the batch is whole.
//!
//! A Turing GPU's compute class is TURING_COMPUTE_A (clc5c0.h): the same
//! methods at the same addresses for what a batch sends, but for two. A
//! QMD is scheduled with SEND_SIGNALING_PCAS_B (its INVALIDATE and
//! SCHEDULE bits: NVK does so for every class up to Turing's) where
//! Blackwell has SEND_SIGNALING_PCAS2_B, and the engine's report is
//! SET_REPORT_SEMAPHORE_A..D. `Push.sm` picks (`batchPushFor`). Not run on
//! a card yet.
//!
//! Allocation-free: the caller owns the dwords.

const std = @import("std");
const qmd = @import("qmd.sig");

pub const Error = error{
    /// The pushbuffer's dwords ran out.
    BufferTooSmall,
};

// ── Classes and methods ─────────────────────────────────────────────────────

pub const BLACKWELL_CHANNEL_GPFIFO_B: u32 = 0xca6f;
pub const BLACKWELL_COMPUTE_B: u32 = 0xcec0;
pub const TURING_COMPUTE_A: u32 = 0xc5c0;

/// The shader model a pushbuffer's compute methods are for.
pub const Sm = @import("chips.sig").Sm;

/// The compute class of shader model `sm`'s GPUs.
pub fn computeClass(sm: Sm) u32 {
    return if (sm == .sm_75) TURING_COMPUTE_A else BLACKWELL_COMPUTE_B;
}

/// TURING_COMPUTE_A's own (clc5c0.h): the schedule (INVALIDATE bit 0,
/// SCHEDULE bit 1) and the report (the address's upper 8 bits, its lower
/// word, the payload, then the operation: RELEASE 0 in 1:0, the structure
/// in bit 28: four words 0, one word 1).
pub const SEND_SIGNALING_PCAS_B: u32 = 0x02bc;
pub const PCAS_B_INVALIDATE_SCHEDULE: u32 = 0x3;
pub const SET_REPORT_SEMAPHORE_A: u32 = 0x1b00;
pub const SET_REPORT_SEMAPHORE_D: u32 = 0x1b0c;
pub const REPORT_D_ONE_WORD: u32 = 1 << 28;

/// The subchannel compute is bound to (tinygrad's; the host's methods,
/// below 0x100, work on any).
pub const SUBCH_COMPUTE: u32 = 1;

/// The host's methods (clc96f.h).
pub const SET_OBJECT: u32 = 0x0000;
pub const SEM_ADDR_LO: u32 = 0x005c;
pub const SEM_ADDR_HI: u32 = 0x0060;
pub const SEM_PAYLOAD_LO: u32 = 0x0064;
pub const SEM_PAYLOAD_HI: u32 = 0x0068;
pub const SEM_EXECUTE: u32 = 0x006c;
/// SEM_EXECUTE: OPERATION (2:0) RELEASE, RELEASE_WFI (20), PAYLOAD_SIZE
/// (24) 32-bit.
pub const SEM_OPERATION_ACQUIRE: u32 = 0;
pub const SEM_OPERATION_RELEASE: u32 = 1;
pub const SEM_RELEASE_WFI: u32 = 1 << 20;
pub const SEM_PAYLOAD_64BIT: u32 = 1 << 24;

/// BLACKWELL_COMPUTE_B's (clcec0.h).
pub const REPORT_SEMAPHORE_PAYLOAD_LOWER: u32 = 0x0158;
pub const REPORT_SEMAPHORE_EXECUTE: u32 = 0x0168;
pub const INVALIDATE_SHADER_CACHES: u32 = 0x021c;
pub const SET_SHADER_SHARED_MEMORY_WINDOW_A: u32 = 0x02a0;
pub const SET_SHADER_SHARED_MEMORY_WINDOW_B: u32 = 0x02a4;
pub const SEND_PCAS_A: u32 = 0x02b4;
pub const SEND_SIGNALING_PCAS2_B: u32 = 0x02c0;
pub const SET_SHADER_LOCAL_MEMORY_NON_THROTTLED_A: u32 = 0x02e4;
pub const SET_SHADER_LOCAL_MEMORY_NON_THROTTLED_B: u32 = 0x02e8;
pub const SET_SHADER_LOCAL_MEMORY_NON_THROTTLED_C: u32 = 0x02ec;
pub const SET_SHADER_LOCAL_MEMORY_A: u32 = 0x0790;
pub const SET_SHADER_LOCAL_MEMORY_B: u32 = 0x0794;
pub const SET_SHADER_LOCAL_MEMORY_WINDOW_A: u32 = 0x07b0;
pub const SET_SHADER_LOCAL_MEMORY_WINDOW_B: u32 = 0x07b4;

/// INVALIDATE_SHADER_CACHES: instructions (bit 0), data (4), constants (12).
pub const INVALIDATE_ALL: u32 = (1 << 0) | (1 << 4) | (1 << 12);
/// Data and constants only: what a barrier between two dispatches of one
/// batch needs (the first's stores seen by the second's loads). The code
/// does not change within a batch, so the SMs keep their instructions:
/// with them thrown away at every barrier, each dependent dispatch fetched
/// its kernel cold (a 3000-instruction kernel ~100 us from system memory
/// behind /dev/dxg, and again for every layer).
pub const INVALIDATE_DATA: u32 = (1 << 4) | (1 << 12);
/// SEND_SIGNALING_PCAS2_B's PCAS_ACTION.
pub const PCAS_SCHEDULE: u32 = 2;
pub const PCAS_PREFETCH: u32 = 8;
pub const PCAS_PREFETCH_SCHEDULE: u32 = 9;
/// REPORT_SEMAPHORE_EXECUTE: OPERATION (1:0) RELEASE, STRUCTURE_SIZE (4:3)
/// FOUR_WORDS (the payload, then the GPU's 64-bit timestamp at +8) or
/// ONE_WORD.
pub const REPORT_RELEASE: u32 = 0;
pub const REPORT_FOUR_WORDS: u32 = 0 << 3;
pub const REPORT_ONE_WORD: u32 = 1 << 3;

/// SET_SHADER_LOCAL_MEMORY_NON_THROTTLED_C: MAX_SM_COUNT (tinygrad's).
pub const LOCAL_MAX_SM_COUNT: u32 = 0xff;

/// The GPU's timestamps (a report's, the global timer's) count ns.
pub const TIMESTAMP_HZ: u64 = 1_000_000_000;

// ── Method headers (cla06f.h) ───────────────────────────────────────────────

pub const SecOp = enum(u3) {
    grp0 = 0,
    inc = 1,
    grp2 = 2,
    non_inc = 3,
    immd = 4,
    one_inc = 5,
    end_segment = 7,
};

/// A pushbuffer method header: incrementing, `count` dwords from
/// `method` on `subch`.
pub fn header(subch: u32, method: u32, count: u32) u32 {
    return (1 << 29) | (count << 16) | (subch << 13) | (method >> 2);
}

/// Every dword to the same method.
pub fn headerNonInc(subch: u32, method: u32, count: u32) u32 {
    return (3 << 29) | (count << 16) | (subch << 13) | (method >> 2);
}

/// One method and its data (13 bits) in the header itself.
pub fn headerImmd(subch: u32, method: u32, data: u32) u32 {
    return (4 << 29) | ((data & 0x1fff) << 16) | (subch << 13) | (method >> 2);
}

/// A header's fields.
pub const Header = struct {
    op: u3,
    subch: u3,
    /// The method's byte address.
    method: u32,
    /// Dwords that follow (for an immediate: its data).
    count: u32,
};

pub fn parseHeader(h: u32) Header {
    return .{
        .op = @intCast(h >> 29),
        .subch = @intCast((h >> 13) & 7),
        .method = (h & 0xfff) << 2,
        .count = (h >> 16) & 0x1fff,
    };
}

/// A host semaphore release of 32-bit `payload` to `va`, once what came
/// before is done (RELEASE_WFI): 6 dwords into `out`.
pub fn hostRelease(out: []u32, va: u64, payload: u32) Error!usize {
    if (out.len < 6) return error.BufferTooSmall;
    out[0] = header(0, SEM_ADDR_LO, 5); // SEM_ADDR_LO .. SEM_EXECUTE
    out[1] = @truncate(va & 0xffff_fffc);
    out[2] = @truncate((va >> 32) & 0x1ff_ffff);
    out[3] = payload;
    out[4] = 0;
    out[5] = SEM_OPERATION_RELEASE | SEM_RELEASE_WFI;
    return 6;
}

// ── GPFIFO ──────────────────────────────────────────────────────────────────

/// A GPFIFO entry: `dwords` of pushbuffer at `va`, main level, fetched
/// unconditionally (clc96f.h's GP_ENTRY).
pub fn gpEntry(va: u64, dwords: u32) u64 {
    return (va & 0xff_ffff_fffc) | (@as(u64, dwords) << 42);
}

pub const GpEntry = struct { va: u64, dwords: u32 };

pub fn parseGpEntry(e: u64) GpEntry {
    return .{ .va = e & 0xff_ffff_fffc, .dwords = @intCast((e >> 42) & 0x1f_ffff) };
}

/// The doorbell's work-submit token (nouveau's gb202_chan_doorbell_handle).
pub fn token(runlist: u32, chid: u32) u32 {
    return (1 << 30) | (runlist << 16) | chid;
}

// ── A pushbuffer ────────────────────────────────────────────────────────────

/// Local memory for the SMs (SET_SHADER_LOCAL_MEMORY*): where, and how
/// much each TPC gets (qmd.localSize).
pub const Local = struct { va: u64, per_tpc: u64 };

/// The VA windows the SMs take as their local and shared memory.
pub const Windows = struct {
    local: u64 = qmd.LOCAL_WINDOW,
    shared: u64 = qmd.SHARED_WINDOW,
};

pub const Push = struct {
    buf: []u32,
    len: usize = 0,
    overflow: bool = false,
    /// The shader model whose compute class the batch is for.
    sm: Sm = .sm_120,

    pub fn words(p: *const Push) []const u32 {
        return p.buf[0..p.len];
    }

    pub fn check(p: *const Push) Error!void {
        if (p.overflow) return error.BufferTooSmall;
    }

    fn room(p: *Push, n: usize) bool {
        if (p.overflow or p.len + n > p.buf.len) {
            p.overflow = true;
            return false;
        }
        return true;
    }

    /// `data` to `method` and the methods after it, on `subch`.
    pub fn method(p: *Push, subch: u32, m: u32, data: []const u32) void {
        if (!p.room(1 + data.len)) return;
        p.buf[p.len] = header(subch, m, @intCast(data.len));
        @memcpy(p.buf[p.len + 1 ..][0..data.len], data);
        p.len += 1 + data.len;
    }

    /// One method whose data (13 bits at most) rides in the header: a
    /// single dword.
    pub fn immediate(p: *Push, subch: u32, m: u32, data: u32) void {
        if (data > 0x1fff) return p.method(subch, m, &.{data});
        if (!p.room(1)) return;
        p.buf[p.len] = headerImmd(subch, m, data);
        p.len += 1;
    }

    /// A 64-bit address to an _A/_B method pair (the upper word first).
    fn address(p: *Push, subch: u32, m: u32, va: u64) void {
        p.method(subch, m, &.{ @truncate(va >> 32), @truncate(va) });
    }

    pub fn setObject(p: *Push, subch: u32, class: u32) void {
        p.method(subch, SET_OBJECT, &.{class});
    }

    /// Compute bound to its subchannel, and its windows.
    pub fn computeSetup(p: *Push, w: Windows) void {
        p.setObject(SUBCH_COMPUTE, computeClass(p.sm));
        p.address(SUBCH_COMPUTE, SET_SHADER_LOCAL_MEMORY_WINDOW_A, w.local);
        p.address(SUBCH_COMPUTE, SET_SHADER_SHARED_MEMORY_WINDOW_A, w.shared);
    }

    /// The SMs' local memory: its base, and each TPC's share.
    pub fn localMemory(p: *Push, l: Local) void {
        p.address(SUBCH_COMPUTE, SET_SHADER_LOCAL_MEMORY_A, l.va);
        p.method(SUBCH_COMPUTE, SET_SHADER_LOCAL_MEMORY_NON_THROTTLED_A, &.{ @truncate(l.per_tpc >> 32), @truncate(l.per_tpc), LOCAL_MAX_SM_COUNT });
    }

    /// The shader caches (instructions, data, constants) invalidated: after
    /// the CPU wrote code or constants the SMs may hold.
    pub fn invalidateShaderCaches(p: *Push) void {
        p.method(SUBCH_COMPUTE, INVALIDATE_SHADER_CACHES, &.{INVALIDATE_ALL});
    }

    /// The data and constant caches invalidated, the instructions kept: a
    /// barrier's, between dispatches of one batch (after a WAIT_FOR_IDLE).
    pub fn invalidateDataCaches(p: *Push) void {
        p.method(SUBCH_COMPUTE, INVALIDATE_SHADER_CACHES, &.{INVALIDATE_DATA});
    }

    /// The QMD at `qmd_va` (256-aligned) prefetched and scheduled.
    pub fn launch(p: *Push, qmd_va: u64) void {
        p.method(SUBCH_COMPUTE, SEND_PCAS_A, &.{@truncate(qmd_va >> 8)});
        if (p.sm == .sm_75) return p.method(SUBCH_COMPUTE, SEND_SIGNALING_PCAS_B, &.{PCAS_B_INVALIDATE_SCHEDULE});
        p.method(SUBCH_COMPUTE, SEND_SIGNALING_PCAS2_B, &.{PCAS_PREFETCH_SCHEDULE});
    }

    /// The host's semaphore release of `payload` at `va`, after everything
    /// before it (hostRelease's words).
    pub fn release(p: *Push, va: u64, payload: u32) void {
        if (!p.room(6)) return;
        p.len += hostRelease(p.buf[p.len..], va, payload) catch unreachable; // (room checked)
    }

    /// The compute engine's report: `payload` at `va` and the GPU's
    /// timestamp (ns) at va + 8, once the launches before it are done (16
    /// bytes, 16-aligned).
    pub fn reportTimestamp(p: *Push, va: u64, payload: u32) void {
        if (p.sm == .sm_75) return p.method(SUBCH_COMPUTE, SET_REPORT_SEMAPHORE_A, &.{ @truncate((va >> 32) & 0xff), @truncate(va), payload, REPORT_RELEASE });
        p.method(SUBCH_COMPUTE, REPORT_SEMAPHORE_PAYLOAD_LOWER, &.{ payload, 0, @truncate(va), @truncate(va >> 32), REPORT_RELEASE | REPORT_FOUR_WORDS });
    }
};

/// A batch's pushbuffer (tinygrad's compute setup and launches): compute
/// on subchannel 1, its windows, its local memory when there is, the
/// shader caches invalidated, each QMD in `qmds` prefetched and
/// scheduled, then a host semaphore release of `payload` at `sem_va` once
/// all of that is done. Its length (Galaxy's runBatch's words).
pub fn batchPush(out: []u32, qmds: []const u64, local: ?Local, sem_va: u64, payload: u32) Error!usize {
    return batchPushFor(.sm_120, out, qmds, local, sem_va, payload);
}

/// The same for shader model `sm`'s compute class.
pub fn batchPushFor(sm: Sm, out: []u32, qmds: []const u64, local: ?Local, sem_va: u64, payload: u32) Error!usize {
    var p = Push{ .buf = out, .sm = sm };
    p.computeSetup(.{});
    if (local) |l| p.localMemory(l);
    p.invalidateShaderCaches();
    for (qmds) |va| p.launch(va);
    p.release(sem_va, payload);
    try p.check();
    return p.len;
}

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "method headers, the semaphore release, GPFIFO entries, the token (Galaxy's nv_chan test)" {
    try testing.expectEqual(@as(u32, 0x2005_0017), header(0, 0x5c, 5));
    try testing.expectEqual(@as(u32, 0x2001_2000), header(1, 0, 1)); // SET_OBJECT on subchannel 1
    var pb: [6]u32 = undefined;
    try testing.expectEqual(@as(usize, 6), try hostRelease(&pb, 0x20_0002_0000, 7));
    try testing.expectEqual([6]u32{ 0x2005_0017, 0x0002_0000, 0x20, 7, 0, 0x0010_0001 }, pb);
    try testing.expectEqual(@as(u64, 0x20_0001_0000 | (6 << 42)), gpEntry(0x20_0001_0000, 6));
    try testing.expectEqual(@as(u64, 0x12_3456_7000), gpEntry(0xff12_3456_7003, 0) & 0xff_ffff_ffff);
    try testing.expectEqual(@as(u32, 0x4003_0002), token(3, 2));
    try testing.expectError(error.BufferTooSmall, hostRelease(pb[0..5], 0, 0));
}

test "headers parse back; GPFIFO entries too" {
    const h = parseHeader(header(1, SEND_PCAS_A, 1));
    try testing.expectEqual(Header{ .op = 1, .subch = 1, .method = SEND_PCAS_A, .count = 1 }, h);
    const n = parseHeader(headerNonInc(2, 0x1b4, 300));
    try testing.expectEqual(@as(u3, 3), n.op);
    try testing.expectEqual(@as(u32, 300), n.count);
    const i = parseHeader(headerImmd(1, INVALIDATE_SHADER_CACHES, INVALIDATE_ALL));
    try testing.expectEqual(@as(u3, 4), i.op);
    try testing.expectEqual(INVALIDATE_ALL, i.count);
    try testing.expectEqual(GpEntry{ .va = 0x20_0001_0000, .dwords = 20 }, parseGpEntry(gpEntry(0x20_0001_0000, 20)));
}

test "a batch's pushbuffer (Galaxy's nv_chan test)" {
    var pb: [0x400]u32 = undefined;
    // (M4's: no local memory, one QMD)
    try testing.expectEqual(@as(usize, 20), try batchPush(&pb, &.{0x20_0003_0000}, null, 0x20_0002_0000, 2));
    try testing.expectEqual(@as(u32, 0x2001_2000), pb[0]); // SET_OBJECT, subchannel 1
    try testing.expectEqual(BLACKWELL_COMPUTE_B, pb[1]);
    try testing.expectEqual(@as(u32, 0x2002_21ec), pb[2]); // the local window (0x7b0), 2 words
    try testing.expectEqual([2]u32{ 0x7293, 0 }, pb[3..5].*);
    try testing.expectEqual(@as(u32, 0x2002_20a8), pb[5]); // the shared window (0x2a0)
    try testing.expectEqual([2]u32{ 0x7294, 0 }, pb[6..8].*);
    try testing.expectEqual(@as(u32, 0x2001_2087), pb[8]); // INVALIDATE_SHADER_CACHES (0x21c)
    try testing.expectEqual(@as(u32, 0x1011), pb[9]);
    try testing.expectEqual([2]u32{ 0x2001_20ad, 0x2000_0300 }, pb[10..12].*); // SEND_PCAS_A: the QMD >> 8
    try testing.expectEqual([2]u32{ 0x2001_20b0, 9 }, pb[12..14].*); // PCAS2_B: prefetch, schedule
    try testing.expectEqual(@as(u32, 0x2005_0017), pb[14]); // the host's release follows
    // (local memory, two QMDs)
    const l = Local{ .va = 0x10_1234_0000, .per_tpc = 0x1e_0000 };
    try testing.expectEqual(@as(usize, 31), try batchPush(&pb, &.{ 0x20_0003_0000, 0x20_0003_0800 }, l, 0x20_0002_0000, 3));
    try testing.expectEqual([3]u32{ 0x2002_21e4, 0x10, 0x1234_0000 }, pb[8..11].*); // SET_SHADER_LOCAL_MEMORY_A (0x790)
    try testing.expectEqual([4]u32{ 0x2003_20b9, 0, 0x1e_0000, 0xff }, pb[11..15].*); // _NON_THROTTLED_A (0x2e4)
    try testing.expectEqual([2]u32{ 0x2001_20ad, 0x2000_0308 }, pb[21..23].*); // the second QMD
    // (too few dwords: an error, nothing written past them)
    var small: [19]u32 = undefined;
    try testing.expectError(error.BufferTooSmall, batchPush(&small, &.{0x20_0003_0000}, null, 0x20_0002_0000, 2));
}

test "a timestamp report" {
    var pb: [8]u32 = undefined;
    var p = Push{ .buf = &pb };
    p.reportTimestamp(0x20_0002_0100, 5);
    try p.check();
    try testing.expectEqual(@as(u32, 0x2005_2056), pb[0]); // 0x158, 5 words
    try testing.expectEqualSlices(u32, &.{ 5, 0, 0x0002_0100, 0x20, 0 }, pb[1..6]);
}

test "a Turing batch: TURING_COMPUTE_A bound, each QMD scheduled with SEND_SIGNALING_PCAS_B" {
    var pb: [64]u32 = undefined;
    const n = try batchPushFor(.sm_75, &pb, &.{0x20_0003_0000}, null, 0x20_0002_0000, 5);
    try testing.expectEqual(header(SUBCH_COMPUTE, SET_OBJECT, 1), pb[0]);
    try testing.expectEqual(TURING_COMPUTE_A, pb[1]);
    // (the windows and the invalidate as on Blackwell: the same methods)
    try testing.expectEqual(header(SUBCH_COMPUTE, SET_SHADER_LOCAL_MEMORY_WINDOW_A, 2), pb[2]);
    try testing.expectEqual(header(SUBCH_COMPUTE, INVALIDATE_SHADER_CACHES, 1), pb[8]);
    try testing.expectEqual(header(SUBCH_COMPUTE, SEND_PCAS_A, 1), pb[10]);
    try testing.expectEqual(@as(u32, 0x2000_0300), pb[11]);
    try testing.expectEqual(header(SUBCH_COMPUTE, SEND_SIGNALING_PCAS_B, 1), pb[12]);
    try testing.expectEqual(@as(u32, 3), pb[13]);
    try testing.expectEqual(header(0, SEM_ADDR_LO, 5), pb[14]);
    try testing.expectEqual(@as(usize, 20), n);
    // the same batch for Blackwell differs in the class and the schedule alone
    var pb2: [64]u32 = undefined;
    const n2 = try batchPush(&pb2, &.{0x20_0003_0000}, null, 0x20_0002_0000, 5);
    try testing.expectEqual(n, n2);
    for (pb[0..n], pb2[0..n], 0..) |a, b, i| {
        if (i == 1 or i == 12 or i == 13) try testing.expect(a != b) else try testing.expectEqual(b, a);
    }
    // the report: four words, the address's upper byte first
    var p = Push{ .buf = &pb, .sm = .sm_75 };
    p.reportTimestamp(0x20_0002_0010, 1);
    try testing.expectEqual(header(SUBCH_COMPUTE, SET_REPORT_SEMAPHORE_A, 4), pb[0]);
    try testing.expectEqual([4]u32{ 0x20, 0x0002_0010, 1, 0 }, pb[1..5].*);
    try testing.expectEqual(TURING_COMPUTE_A, computeClass(.sm_75));
    try testing.expectEqual(BLACKWELL_COMPUTE_B, computeClass(.sm_120));
}
