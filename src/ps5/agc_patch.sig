//! @zpm/ps5 agc_patch — libSceAgc's calls that change a packet already
//! written, read a packet's size and payload, and the calls that are not
//! packets (agc.sig has the library's table). Allocation-free.

const std = @import("std");
const pm4 = @import("pm4.sig");

const OP = pm4.OP;
const SUB = pm4.SUB;
const header = pm4.header;

const sync = @import("agc_sync.sig");
const branchTarget = sync.branchTarget;
const core = @import("agc_buffer.sig");
const ERROR = core.ERROR;
const CommandBuffer = core.CommandBuffer;
const ShaderRegister = core.ShaderRegister;
const MemoryRange = core.MemoryRange;
const Buf = core.Buf;
const Out = core.Out;
const lo32 = core.lo32;
const hi32 = core.hi32;
const w32 = core.w32;
const reserve = core.reserve;
const put = core.put;
const fillNop = core.fillNop;
const PAIRS = core.PAIRS;
const TAG = core.TAG;
const TAG_HEADER = core.TAG_HEADER;

// ── Patches: a packet already written, changed ──────────────────────────────
//
// Each checks that the packet is the kind it changes by its whole header
// (so a packet whose predicate bit was set since is refused, as in the
// open implementation), and returns 0 or ERROR.

const Cmd = ?[*]u32;

fn packetIs(cmd: Cmd, want: u32) ?[*]u32 {
    const c = cmd orelse return null;
    return if (c[0] == want) c else null;
}

/// The three indirect register packets' patches, one set per opcode.
fn RegIndirectPatch(comptime op: u8) type {
    return struct {
        fn packet(cmd: Cmd) ?[*]u32 {
            const c = packetIs(cmd, header(op, 5, 0)) orelse return null;
            return if (c[3] == PAIRS and c[4] <= 0x3FFF) c else null;
        }
        pub fn setAddress(cmd: Cmd, regs: u64) callconv(.c) i32 {
            const c = packet(cmd) orelse return ERROR.INVALID;
            if (regs == 0 or regs & 3 != 0) return ERROR.INVALID;
            c[1] = lo32(regs);
            c[2] = hi32(regs);
            return 0;
        }
        pub fn setCount(cmd: Cmd, n: u32) callconv(.c) i32 {
            const c = packet(cmd) orelse return ERROR.INVALID;
            if (n > 0x3FFF) return ERROR.INVALID;
            c[4] = n;
            return 0;
        }
        pub fn add(cmd: Cmd, n: u32) callconv(.c) i32 {
            const c = packet(cmd) orelse return ERROR.INVALID;
            const sum = @as(u64, c[4]) + n;
            if (sum > 0x3FFF) return ERROR.INVALID;
            c[4] = @intCast(sum);
            return 0;
        }
    };
}
pub const CxIndirect = RegIndirectPatch(OP.SET_CONTEXT_REG_INDIRECT);
pub const ShIndirect = RegIndirectPatch(OP.SET_SH_REG_INDIRECT);
pub const UcIndirect = RegIndirectPatch(OP.SET_UCONFIG_REG_INDIRECT);

/// A target's address and size into an INDIRECT_BUFFER's words.
fn setTarget(c: [*]u32, at: usize, to: u64, words: u32) void {
    c[at] = lo32(to);
    c[at + 1] = hi32(to);
    c[at + 2] = (c[at + 2] & ~@as(u32, 0xF_FFFF)) | (words & 0xF_FFFF);
}

pub fn sceAgcJumpPatchSetTarget(cmd: Cmd, to: u64, words: u32) callconv(.c) i32 {
    const c = packetIs(cmd, header(OP.INDIRECT_BUFFER, 4, 0)) orelse return ERROR.INVALID;
    if (to == 0 or to & 3 != 0) return ERROR.INVALID;
    setTarget(c, 1, to, words);
    return 0;
}

fn branch(cmd: Cmd) ?[*]u32 {
    return packetIs(cmd, header(OP.INDIRECT_BUFFER, 14, 0));
}
pub fn sceAgcBranchPatchSetCompareAddress(cmd: Cmd, at: u64) callconv(.c) i32 {
    const c = branch(cmd) orelse return ERROR.INVALID;
    if (at == 0 or at & 7 != 0) return ERROR.INVALID;
    c[2] = lo32(at);
    c[3] = hi32(at);
    return 0;
}
pub fn sceAgcBranchPatchSetThenTarget(cmd: Cmd, to: u64, words: u32) callconv(.c) i32 {
    const c = branch(cmd) orelse return ERROR.INVALID;
    if (!branchTarget(to, words) or words > 0xF_FFFF) return ERROR.INVALID;
    setTarget(c, 8, to, words);
    return 0;
}
pub fn sceAgcBranchPatchSetElseTarget(cmd: Cmd, to: u64, words: u32) callconv(.c) i32 {
    const c = branch(cmd) orelse return ERROR.INVALID;
    if (!branchTarget(to, words) or words > 0xF_FFFF) return ERROR.INVALID;
    setTarget(c, 11, to, words);
    return 0;
}

fn condExecPacket(cmd: Cmd) ?[*]u32 {
    return packetIs(cmd, header(OP.COND_EXEC, 5, 0));
}
/// The word the condition is read from (its low two bits are the packet's
/// own and stay).
pub fn sceAgcCondExecPatchSetCommandAddress(cmd: Cmd, at: u64) callconv(.c) i32 {
    const c = condExecPacket(cmd) orelse return ERROR.INVALID;
    c[1] = (c[1] & 3) | (lo32(at) & ~@as(u32, 3));
    c[2] = hi32(at);
    return 0;
}
/// How many words are skipped: up to `end`, from the packet's end.
pub fn sceAgcCondExecPatchSetEnd(cmd: Cmd, end: u64) callconv(.c) i32 {
    const c = condExecPacket(cmd) orelse return ERROR.INVALID;
    const after = @intFromPtr(c) + 5 * 4;
    if (end == 0 or end & 3 != 0 or end < after or (end - after) / 4 > 0x3FFF) return ERROR.INVALID;
    c[4] = (c[4] & ~@as(u32, 0x3FFF)) | @as(u32, @intCast((end - after) / 4));
    return 0;
}

/// Lets a queue stopped at a REWIND go on (1), or not yet (0).
pub fn sceAgcRewindPatchSetRewindState(cmd: Cmd, state: u8) callconv(.c) i32 {
    const c = packetIs(cmd, header(OP.REWIND, 2, 0)) orelse return ERROR.INVALID;
    if (state > 1) return ERROR.INVALID;
    @atomicStore(u32, &c[1], w32(state) << 31, .release);
    return 0;
}

fn dmaPacket(cmd: Cmd) ?[*]u32 {
    return packetIs(cmd, header(OP.DMA_DATA, 7, 0));
}
pub fn sceAgcDmaDataPatchSetDstAddressOrOffset(cmd: Cmd, at: u64) callconv(.c) i32 {
    const c = dmaPacket(cmd) orelse return ERROR.INVALID;
    c[4] = lo32(at);
    c[5] = hi32(at);
    return 0;
}
pub fn sceAgcDmaDataPatchSetSrcAddressOrOffsetOrImmediate(cmd: Cmd, at: u64) callconv(.c) i32 {
    const c = dmaPacket(cmd) orelse return ERROR.INVALID;
    c[2] = lo32(at);
    c[3] = hi32(at);
    return 0;
}

/// A tagged wait as sceAgc*WaitRegMem writes it (`cmd` at its first tag):
/// the words, and whether it waits on 64 bits.
const Wait = struct { c: [*]u32, wide: bool };

fn waitPacket(cmd: Cmd) ?Wait {
    const c = cmd orelse return null;
    const q = c[0] & 0xFF;
    if (q != 0 and q != pm4.FLAG.RESET_FILTER_CAM) return null;
    if (c[0] != header(OP.SET_UCONFIG_REG, 4, 0) | q or c[1] != pm4.UC_TAG) return null;
    const wide = switch (c[2] & 0xFFFF_0000) {
        TAG.WAIT_32 => false,
        TAG.WAIT_64 => true,
        else => return null,
    };
    if (c[4] != if (wide) header(OP.WAIT_REG_MEM_64, 9, 0) else header(OP.WAIT_REG_MEM, 7, 0)) return null;
    const e: usize = if (wide) 13 else 11;
    if (c[e] != header(OP.SET_UCONFIG_REG, 3, 0) | q or c[e + 1] != pm4.UC_TAG or c[e + 2] != TAG.WAIT_END) return null;
    return .{ .c = c, .wide = wide };
}

pub fn sceAgcWaitRegMemPatchAddress(cmd: Cmd, at: u64) callconv(.c) i32 {
    const wt = waitPacket(cmd) orelse return ERROR.INVALID;
    const keep: u32 = if (wt.wide) 7 else 3;
    if (at >> 48 != 0 or lo32(at) & keep != 0) return ERROR.INVALID;
    const c = wt.c;
    c[2] = (c[2] & 0xFFFF_0000) | (hi32(at) & 0xFFFF);
    c[3] = lo32(at);
    c[6] = (lo32(at) & ~keep) | (c[6] & keep);
    c[7] = (c[7] & ~@as(u32, 0x3_FFFF)) | (hi32(at) & 0x3_FFFF);
    return 0;
}
pub fn sceAgcWaitRegMemPatchReference(cmd: Cmd, reference: u32) callconv(.c) i32 {
    const wt = waitPacket(cmd) orelse return ERROR.INVALID;
    wt.c[8] = reference;
    return 0;
}
pub fn sceAgcWaitRegMemPatchMask(cmd: Cmd, mask: u32) callconv(.c) i32 {
    const wt = waitPacket(cmd) orelse return ERROR.INVALID;
    wt.c[if (wt.wide) 10 else 9] = mask;
    return 0;
}
pub fn sceAgcWaitRegMemPatchCompareFunction(cmd: Cmd, function: u8) callconv(.c) i32 {
    const wt = waitPacket(cmd) orelse return ERROR.INVALID;
    if (function > 6) return ERROR.INVALID;
    wt.c[5] = (wt.c[5] & ~@as(u32, 7)) | function;
    return 0;
}

fn releaseMem(cmd: Cmd) ?[*]u32 {
    return packetIs(cmd, header(OP.RELEASE_MEM, 8, 0));
}

/// Where an end-of-pipe action writes: a RELEASE_MEM's address, or an
/// EVENT_WRITE_EOP's (6 words; never written by this library).
pub fn sceAgcQueueEndOfPipeActionPatchAddress(cmd: Cmd, label: u64) callconv(.c) i32 {
    const c = cmd orelse return ERROR.INVALID;
    const eop = c[0] == header(OP.EVENT_WRITE_EOP, 6, 0);
    if (!eop and c[0] != header(OP.RELEASE_MEM, 8, 0)) return ERROR.INVALID;
    const select = (if (eop) c[3] else c[2]) >> 29;
    const alignment: u64 = if (select == 2 or select == 3) 8 else 4;
    if (label == 0 or label % alignment != 0) return ERROR.INVALID;
    if (eop) {
        if (label >> 48 != 0) return ERROR.INVALID;
        c[2] = lo32(label);
        c[3] = (c[3] & 0xFFFF_0000) | (hi32(label) & 0xFFFF);
    } else {
        c[3] = lo32(label);
        c[4] = hi32(label);
    }
    return 0;
}
pub fn sceAgcQueueEndOfPipeActionPatchData(cmd: Cmd, data: u64) callconv(.c) i32 {
    const c = releaseMem(cmd) orelse return ERROR.INVALID;
    const irq = c[2] >> 24 & 7;
    const select = c[2] >> 29;
    if (irq == 4 and (data != 0 or c[3] != 0 or c[4] != 0)) return ERROR.INVALID;
    if (select == 5) return if (data == 0) 0 else ERROR.INVALID;
    if (select == 1 and data >> 32 != 0) return ERROR.INVALID;
    c[5] = lo32(data);
    c[6] = hi32(data);
    return 0;
}
pub fn sceAgcQueueEndOfPipeActionPatchGcrCntl(cmd: Cmd, gcr: u16) callconv(.c) i32 {
    const c = releaseMem(cmd) orelse return ERROR.INVALID;
    if (gcr > 0xFFF) return ERROR.INVALID;
    var g: u32 = gcr;
    if (g & 0x300 == 0x100) g |= 0x200;
    c[1] = (c[1] & ~@as(u32, 0xFF_F000)) | (g << 12);
    return 0;
}
pub fn sceAgcQueueEndOfPipeActionPatchType(cmd: Cmd, action: u8) callconv(.c) i32 {
    const c = releaseMem(cmd) orelse return ERROR.INVALID;
    if (action > 0x3F) return ERROR.INVALID;
    const index: u32 = if (action >= 0x2F) 6 else 5;
    c[1] = (c[1] & ~@as(u32, 0xF3F)) | action | (index << 8);
    return 0;
}

/// Which engine an ACQUIRE_MEM is for (only its opcode is checked).
pub fn sceAgcAcquireMemSetEngine(packet: Cmd, engine: u8) callconv(.c) i32 {
    const c = packet orelse return ERROR.INVALID;
    if (pm4.opOf(c[0]) != OP.ACQUIRE_MEM) return ERROR.WRONG_PACKET;
    c[1] = (c[1] & 0x7FFF_FFFF) | ((w32(engine) & 1) << 31);
    return 0;
}

/// Whether one packet runs only while the queue's predicate holds.
pub fn sceAgcSetPacketPredication(packet: Cmd, on: u32) callconv(.c) i32 {
    const c = packet orelse return ERROR.INVALID;
    if (c[0] >> 30 != 3 or on > 1) return ERROR.INVALID;
    c[0] = (c[0] & ~@as(u32, 1)) | on;
    return 0;
}

/// The same for every packet from `start` up to `end` (not included);
/// fillers are stepped over. A range that is not whole packets is refused
/// and nothing changed.
pub fn sceAgcSetRangePredication(start: Cmd, end: ?[*]const u32, on: u32) callconv(.c) i32 {
    const s = start orelse return ERROR.INVALID;
    const e = @intFromPtr(end orelse return ERROR.INVALID);
    if (on > 1 or e < @intFromPtr(s) or (e - @intFromPtr(s)) % 4 != 0) return ERROR.INVALID;
    const words = s[0 .. (e - @intFromPtr(s)) / 4];
    for (0..2) |pass| {
        var i: usize = 0;
        while (i < words.len) {
            const h = words[i];
            if (pm4.isFiller(h)) {
                i += 1;
                continue;
            }
            if (h >> 30 != 3) return ERROR.INVALID;
            const n = pm4.lengthOf(h).?;
            if (n > words.len - i) return ERROR.INVALID;
            if (pass == 1) words[i] = (h & ~@as(u32, 1)) | on;
            i += n;
        }
    }
    return 0;
}

// ── Reading packets ─────────────────────────────────────────────────────────

/// A packet's words, from its header (0: not a type-3 header).
pub fn sceAgcGetPacketSize(packet: ?[*]const u32) callconv(.c) u32 {
    const c = packet orelse return 0;
    if (c[0] >> 30 != 3) return 0;
    return pm4.lengthOf(c[0]).?;
}

/// Where a packet's payload starts: past a data packet's control word
/// (`kind` not 0), or past the header (none for a one-word NOP).
fn payload(c: [*]u32, kind: i32) ?[*]u32 {
    if (kind != 0) return c + 2;
    return if (c[0] >> 16 & 0x3FFF == 0x3FFF) null else c + 1;
}
pub fn sceAgcGetDataPacketPayloadAddress(out: ?*align(1) ?[*]u32, cmd: Cmd, kind: i32) callconv(.c) i32 {
    const o = out orelse return ERROR.INVALID;
    const c = cmd orelse return ERROR.INVALID;
    o.* = payload(c, kind);
    return 0;
}
pub fn sceAgcGetDataPacketPayloadRange(out: ?*MemoryRange, cmd: Cmd, kind: i32) callconv(.c) i32 {
    const o = out orelse return ERROR.INVALID;
    const c = cmd orelse return ERROR.INVALID;
    const bytes: u64 = c[0] >> 14 & 0xFFFC;
    const at = payload(c, kind);
    o.* = .{ .base = @ptrCast(at), .size = if (at == null) 0 else if (kind != 0) bytes else bytes + 4 };
    return 0;
}

// ── What is not a packet ────────────────────────────────────────────────────

/// Ready for a version of the register defaults: nothing to prepare here
/// (they are not in this file). The arguments are not read: the open
/// implementation takes a version, a console is said to take a pointer
/// first.
pub fn sceAgcInit() callconv(.c) i32 {
    return 0;
}

/// Six 16-byte slots a game keeps for its shaders (the open
/// implementation keeps them in its driver; the driver here has none).
const statics = struct {
    var table: [6][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** 6;
};
pub fn sceAgcSetStaticBuffer(index: u32, from: ?*const [16]u8) callconv(.c) i32 {
    const f = from orelse return ERROR.OUT_OF_RANGE;
    if (index >= statics.table.len) return ERROR.OUT_OF_RANGE;
    statics.table[index] = f.*;
    return 0;
}
pub fn sceAgcGetStaticBuffer(index: u32, to: ?*[16]u8) callconv(.c) i32 {
    const t = to orelse return ERROR.OUT_OF_RANGE;
    if (index >= statics.table.len) return ERROR.OUT_OF_RANGE;
    t.* = statics.table[index];
    return 0;
}

/// The memory a game gives for semaphore labels (32 bytes each), once.
const semaphores = struct {
    var claimed: bool = false;
    var size: u64 = 0;
    var base: usize = 0;
};
pub fn sceAgcSetAmmSemaphoreMemory(memory: ?*anyopaque, bytes: u64) callconv(.c) i32 {
    if (@atomicLoad(bool, &semaphores.claimed, .acquire)) return ERROR.SEMAPHORE_REGISTERED;
    // (null: the sheet does not say; refused)
    const m = @intFromPtr(memory orelse return ERROR.OUT_OF_RANGE);
    if (m % 0x4000 != 0 or bytes % 0x4000 != 0) return ERROR.ALIGNMENT;
    if (@cmpxchgStrong(bool, &semaphores.claimed, false, true, .acq_rel, .acquire) != null) return ERROR.SEMAPHORE_REGISTERED;
    @memset(@as([*]u8, @ptrFromInt(m))[0..@intCast(bytes)], 0);
    semaphores.size = bytes;
    @atomicStore(usize, &semaphores.base, m, .release);
    return 0;
}
pub fn sceAgcGetSemaphoreLabel(index: u32, label: ?*align(1) u64) callconv(.c) i32 {
    const base = @atomicLoad(usize, &semaphores.base, .acquire);
    if (base == 0) return ERROR.NO_SEMAPHORE;
    const l = label orelse return ERROR.OUT_OF_RANGE;
    if (index >= semaphores.size / 32) return ERROR.OUT_OF_RANGE;
    l.* = base + 32 * @as(u64, index);
    return 0;
}

/// Accepted and nothing done: no debugger, no suspend here.
pub fn sceAgcDebugRaiseException() callconv(.c) i32 {
    return 0;
}
pub fn sceAgcSuspendPoint() callconv(.c) i32 {
    return 0;
}
/// Mode 0 only (what another mode does on a console is not known; the
/// open implementation stops there).
pub fn sceAgcSetSubmitMode(mode: u32) callconv(.c) i32 {
    return if (mode == 0) 0 else ERROR.INVALID;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const draw = @import("agc_draw.sig");

test "patches: indirect registers, jumps, branches, cond exec, rewind, DMA" {
    var mem: [128]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    const regs = [_]ShaderRegister{ .{ .offset = 1, .value = 2 }, .{ .offset = 3, .value = 4 } };
    const a = @intFromPtr(&regs);
    const ind = core.sceAgcDcbSetCxRegistersIndirect(&cb, 0, 0).?;
    try testing.expectEqual(@as(i32, 0), CxIndirect.setAddress(ind, a));
    try testing.expectEqual(@as(i32, 0), CxIndirect.setCount(ind, 1));
    try testing.expectEqual(@as(i32, 0), CxIndirect.add(ind, 1));
    try testing.expectEqualSlices(u32, &.{ 0xC003_9F00, lo32(a), hi32(a), 0x8000_0000, 2 }, ind[0..5]);
    try testing.expectEqual(ERROR.INVALID, CxIndirect.add(ind, 0x3FFE));
    try testing.expectEqual(ERROR.INVALID, CxIndirect.setAddress(ind, 0));
    try testing.expectEqual(ERROR.INVALID, CxIndirect.setAddress(ind, a + 2));
    // The wrong bank's patch, and no packet.
    try testing.expectEqual(ERROR.INVALID, ShIndirect.setCount(ind, 1));
    try testing.expectEqual(ERROR.INVALID, UcIndirect.setCount(null, 1));
    try testing.expectEqual(@as(u32, 2), ind[4]);

    const jump = sync.sceAgcDcbJump(&cb, 0, 3, 0x1000, 8).?;
    try testing.expectEqual(@as(i32, 0), sceAgcJumpPatchSetTarget(jump, 0x12_3456_7890, 0x40));
    try testing.expectEqualSlices(u32, &.{ 0xC002_3F00, 0x3456_7890, 0x12, 0x3F20_0040 }, jump[0..4]);
    try testing.expectEqual(ERROR.INVALID, sceAgcJumpPatchSetTarget(jump, 0x1002, 1));
    try testing.expectEqual(ERROR.INVALID, sceAgcJumpPatchSetTarget(jump, 0, 1));

    const br = sync.sceAgcCbBranch(&cb, 0, 0, 0, 0, 0, 1, 0, 0, 2, 0, 0).?;
    try testing.expectEqual(@as(i32, 0), sceAgcBranchPatchSetCompareAddress(br, 0x1_0000_0008));
    try testing.expectEqual(@as(i32, 0), sceAgcBranchPatchSetThenTarget(br, 0x2000, 0x11));
    try testing.expectEqual(@as(i32, 0), sceAgcBranchPatchSetElseTarget(br, 0x3_0000_3000, 0x22));
    try testing.expectEqualSlices(u32, &.{ 0x8, 0x1, 0, 0, 0, 0, 0x2000, 0, 0x1000_0011, 0x3000, 3, 0x2000_0022 }, br[2..14]);
    try testing.expectEqual(ERROR.INVALID, sceAgcBranchPatchSetCompareAddress(br, 0x1004));
    try testing.expectEqual(ERROR.INVALID, sceAgcBranchPatchSetThenTarget(br, 0x2001, 1));
    // (a jump is not a branch)
    try testing.expectEqual(ERROR.INVALID, sceAgcBranchPatchSetElseTarget(jump, 0x2000, 1));

    const ce = sync.sceAgcDcbCondExec(&cb, 0x1000, 0).?;
    try testing.expectEqual(@as(i32, 0), sceAgcCondExecPatchSetCommandAddress(ce, 0x5_0000_2004));
    try testing.expectEqual(@as(i32, 0), sceAgcCondExecPatchSetEnd(ce, @intFromPtr(ce + 5 + 3)));
    try testing.expectEqualSlices(u32, &.{ 0x2004, 5, 0, 3 }, ce[1..5]);
    try testing.expectEqual(ERROR.INVALID, sceAgcCondExecPatchSetEnd(ce, @intFromPtr(ce + 4)));
    try testing.expectEqual(ERROR.INVALID, sceAgcCondExecPatchSetEnd(ce, @intFromPtr(ce + 5) + 2));
    try testing.expectEqual(ERROR.INVALID, sceAgcCondExecPatchSetEnd(ce, @intFromPtr(ce + 5) + 4 * 0x4000));

    const rw = sync.sceAgcDcbRewind(&cb, 0).?;
    try testing.expectEqual(@as(i32, 0), sceAgcRewindPatchSetRewindState(rw, 1));
    try testing.expectEqual(@as(u32, 0x8000_0000), rw[1]);
    try testing.expectEqual(ERROR.INVALID, sceAgcRewindPatchSetRewindState(rw, 2));

    const dma = sync.sceAgcAcbDmaData(&cb, 0, 0, 0, 0, 0, 0, 4, 0, 0).?;
    try testing.expectEqual(@as(i32, 0), sceAgcDmaDataPatchSetDstAddressOrOffset(dma, 0x7_0000_0010));
    try testing.expectEqual(@as(i32, 0), sceAgcDmaDataPatchSetSrcAddressOrOffsetOrImmediate(dma, 0x8_0000_0020));
    try testing.expectEqualSlices(u32, &.{ 0x20, 8, 0x10, 7 }, dma[2..6]);

    // A packet whose predicate bit was set since is refused (its header is
    // not the one written).
    try testing.expectEqual(@as(i32, 0), sceAgcSetPacketPredication(rw, 1));
    try testing.expectEqual(ERROR.INVALID, sceAgcRewindPatchSetRewindState(rw, 0));
}

test "patches: a tagged wait, its address, reference, mask, compare function" {
    var mem: [64]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    const w32w = sync.sceAgcDcbWaitRegMem(&cb, 0, 3, 0, 0, 0, 1, 0xFF, 0x40).?;
    const w64w = sync.sceAgcAcbWaitRegMem(&cb, 1, 3, 0, 0x5, 1, 0xFF, 0x40).?;
    try testing.expectEqual(@as(i32, 0), sceAgcWaitRegMemPatchAddress(w32w, 0x1234_5678_9AB4));
    try testing.expectEqual(@as(i32, 0), sceAgcWaitRegMemPatchReference(w32w, 7));
    try testing.expectEqual(@as(i32, 0), sceAgcWaitRegMemPatchMask(w32w, 0xF0));
    try testing.expectEqual(@as(i32, 0), sceAgcWaitRegMemPatchCompareFunction(w32w, 5));
    try testing.expectEqualSlices(u32, &.{ 0xC002_7904, 0x342, 0xC801_1234, 0x5678_9AB4, 0xC005_3C00, 0x15, 0x5678_9AB4, 0x1234, 7, 0xF0, 4 }, w32w[0..11]);
    // A 64-bit wait: its address 8-aligned; its mask's low half.
    try testing.expectEqual(@as(i32, 0), sceAgcWaitRegMemPatchAddress(w64w, 0x10_2000_0008));
    try testing.expectEqual(@as(i32, 0), sceAgcWaitRegMemPatchMask(w64w, 0xAB));
    try testing.expectEqualSlices(u32, &.{ 0xC802_0010, 0x2000_0008, 0xC007_9300, 0x13, 0x2000_0008, 0x10, 1, 0, 0xAB }, w64w[2..11]);
    try testing.expectEqual(ERROR.INVALID, sceAgcWaitRegMemPatchAddress(w64w, 0x1004));
    try testing.expectEqual(ERROR.INVALID, sceAgcWaitRegMemPatchAddress(w32w, 0x1002));
    try testing.expectEqual(ERROR.INVALID, sceAgcWaitRegMemPatchAddress(w32w, 1 << 48));
    try testing.expectEqual(ERROR.INVALID, sceAgcWaitRegMemPatchCompareFunction(w32w, 7));
    // Not at a wait's first tag.
    try testing.expectEqual(ERROR.INVALID, sceAgcWaitRegMemPatchReference(w32w + 4, 1));
    // A wait whose end tag was overwritten.
    w32w[13] = 0;
    try testing.expectEqual(ERROR.INVALID, sceAgcWaitRegMemPatchReference(w32w, 1));
}

test "patches: the end-of-pipe action, acquire mem's engine, predication" {
    var mem: [64]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    const rm = sync.sceAgcCbReleaseMem(&cb, 0x28, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0).?;
    try testing.expectEqual(@as(i32, 0), sceAgcQueueEndOfPipeActionPatchAddress(rm, 0x7_0000_1008));
    try testing.expectEqual(@as(i32, 0), sceAgcQueueEndOfPipeActionPatchData(rm, 0x1111_2222_3333_4444));
    try testing.expectEqual(@as(i32, 0), sceAgcQueueEndOfPipeActionPatchGcrCntl(rm, 0x100));
    try testing.expectEqual(@as(i32, 0), sceAgcQueueEndOfPipeActionPatchType(rm, 0x30));
    try testing.expectEqualSlices(u32, &.{ 0xC006_4900, 0x30 | 0x600 | 0x30_0000, 0x4000_0000, 0x1008, 7, 0x3333_4444, 0x1111_2222, 0 }, rm[0..8]);
    try testing.expectEqual(ERROR.INVALID, sceAgcQueueEndOfPipeActionPatchAddress(rm, 0x1004));
    try testing.expectEqual(ERROR.INVALID, sceAgcQueueEndOfPipeActionPatchAddress(rm, 0));
    try testing.expectEqual(ERROR.INVALID, sceAgcQueueEndOfPipeActionPatchGcrCntl(rm, 0x1000));
    try testing.expectEqual(ERROR.INVALID, sceAgcQueueEndOfPipeActionPatchType(rm, 0x40));
    // A 32-bit selector takes 32 bits; the GDS selector no data at all.
    const r32 = sync.sceAgcCbReleaseMem(&cb, 0x28, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0).?;
    try testing.expectEqual(ERROR.INVALID, sceAgcQueueEndOfPipeActionPatchData(r32, 1 << 32));
    try testing.expectEqual(@as(i32, 0), sceAgcQueueEndOfPipeActionPatchAddress(r32, 0x1004));
    const gds = sync.sceAgcCbReleaseMem(&cb, 0x28, 0, 0, 0, 0, 5, 0, 1, 2, 0, 0).?;
    try testing.expectEqual(@as(i32, 0), sceAgcQueueEndOfPipeActionPatchData(gds, 0));
    try testing.expectEqual(ERROR.INVALID, sceAgcQueueEndOfPipeActionPatchData(gds, 1));
    try testing.expectEqual(@as(u32, 0x2_0001), gds[5]);
    // The older end-of-pipe packet: the address only, 48 bits, the rest of
    // its fourth word kept.
    var eop = [_]u32{ header(OP.EVENT_WRITE_EOP, 6, 0), 0x28, 0, 0x4002_0000, 0, 0 };
    try testing.expectEqual(@as(i32, 0), sceAgcQueueEndOfPipeActionPatchAddress(&eop, 0x1234_5678_9AB8));
    try testing.expectEqualSlices(u32, &.{ 0x5678_9AB8, 0x4002_1234 }, eop[2..4]);
    try testing.expectEqual(ERROR.INVALID, sceAgcQueueEndOfPipeActionPatchAddress(&eop, 0x1004));
    try testing.expectEqual(ERROR.INVALID, sceAgcQueueEndOfPipeActionPatchData(&eop, 0));

    const am = sync.sceAgcAcbAcquireMem(&cb, 0, 0, 0, 0).?;
    try testing.expectEqual(@as(i32, 0), sceAgcAcquireMemSetEngine(am, 1));
    try testing.expectEqual(@as(u32, 0x8000_0000), am[1]);
    try testing.expectEqual(ERROR.WRONG_PACKET, sceAgcAcquireMemSetEngine(rm, 1));

    // Predication: one packet, then a run with fillers in it.
    cb = CommandBuffer.over(&mem);
    const first = draw.sceAgcDcbDrawIndexAuto(&cb, 3, 0).?;
    _ = core.sceAgcCbNop(&cb, 1);
    _ = draw.sceAgcDcbSetNumInstances(&cb, 2);
    _ = draw.sceAgcDcbDrawIndexAuto(&cb, 3, 0);
    const end = cb.written().ptr + cb.written().len;
    try testing.expectEqual(@as(i32, 0), sceAgcSetRangePredication(first, end, 1));
    try testing.expectEqualSlices(u32, &.{ 0xC001_2D01, 3, 2, 0xFFFF_1000, 0xC000_2F01, 2, 0xC001_2D01, 3, 2 }, cb.written());
    try testing.expectEqual(@as(i32, 0), sceAgcSetPacketPredication(first, 0));
    try testing.expectEqual(@as(u32, 0xC001_2D00), first[0]);
    // A range that ends inside a packet: refused, nothing changed.
    try testing.expectEqual(ERROR.INVALID, sceAgcSetRangePredication(first, end - 1, 0));
    try testing.expectEqual(@as(u32, 0xC000_2F01), mem[4]);
    // What is not a type-3 header.
    mem[0] = 0x1234;
    try testing.expectEqual(ERROR.INVALID, sceAgcSetRangePredication(first, end, 0));
    try testing.expectEqual(ERROR.INVALID, sceAgcSetPacketPredication(first, 0));
    try testing.expectEqual(ERROR.INVALID, sceAgcSetPacketPredication(first + 4, 2));
    try testing.expectEqual(@as(i32, 0), sceAgcSetRangePredication(first, first, 1));
}

test "reading packets: sizes and payloads" {
    var p = [_]u32{ 0xC004_7600, 1, 2, 3, 4, 5 };
    try testing.expectEqual(@as(u32, 6), sceAgcGetPacketSize(&p));
    try testing.expectEqual(@as(u32, 0x4000), sceAgcGetPacketSize(&[_]u32{0xFFFE_1000}));
    try testing.expectEqual(@as(u32, 0x4001), sceAgcGetPacketSize(&[_]u32{0xFFFF_7600}));
    try testing.expectEqual(@as(u32, 1), sceAgcGetPacketSize(&[_]u32{0xFFFF_1000}));
    // (a type-2 filler is not a packet this call sizes)
    try testing.expectEqual(@as(u32, 0), sceAgcGetPacketSize(&[_]u32{0x8000_0000}));
    try testing.expectEqual(@as(u32, 0), sceAgcGetPacketSize(null));

    var at: ?[*]u32 = null;
    try testing.expectEqual(@as(i32, 0), sceAgcGetDataPacketPayloadAddress(&at, &p, 1));
    try testing.expectEqual(@as(?[*]u32, p[2..].ptr), at);
    try testing.expectEqual(@as(i32, 0), sceAgcGetDataPacketPayloadAddress(&at, &p, 0));
    try testing.expectEqual(@as(?[*]u32, p[1..].ptr), at);
    var range: MemoryRange = undefined;
    try testing.expectEqual(@as(i32, 0), sceAgcGetDataPacketPayloadRange(&range, &p, 1));
    try testing.expectEqual(@as(u64, 16), range.size);
    try testing.expectEqual(@intFromPtr(&p[2]), @intFromPtr(range.base));
    try testing.expectEqual(@as(i32, 0), sceAgcGetDataPacketPayloadRange(&range, &p, 0));
    try testing.expectEqual(@as(u64, 20), range.size);
    var filler = [_]u32{0xFFFF_1000};
    try testing.expectEqual(@as(i32, 0), sceAgcGetDataPacketPayloadRange(&range, &filler, 0));
    try testing.expectEqual(@as(u64, 0), range.size);
    try testing.expect(range.base == null);
    try testing.expectEqual(ERROR.INVALID, sceAgcGetDataPacketPayloadRange(null, &p, 0));
}

const SemaphoreArea = struct {
    var bytes: [0x8000]u8 align(0x4000) = undefined;
};

test "static buffers, the semaphore area, the calls with nothing to do" {
    try testing.expectEqual(@as(i32, 0), sceAgcInit());
    const in = [_]u8{0xAB} ** 16;
    var out = [_]u8{0} ** 16;
    try testing.expectEqual(@as(i32, 0), sceAgcSetStaticBuffer(5, &in));
    try testing.expectEqual(@as(i32, 0), sceAgcGetStaticBuffer(5, &out));
    try testing.expectEqualSlices(u8, &in, &out);
    try testing.expectEqual(ERROR.OUT_OF_RANGE, sceAgcSetStaticBuffer(6, &in));
    try testing.expectEqual(ERROR.OUT_OF_RANGE, sceAgcGetStaticBuffer(0, null));

    var label: u64 = 0;
    try testing.expectEqual(ERROR.NO_SEMAPHORE, sceAgcGetSemaphoreLabel(0, &label));
    @memset(&SemaphoreArea.bytes, 0xEE);
    try testing.expectEqual(ERROR.ALIGNMENT, sceAgcSetAmmSemaphoreMemory(&SemaphoreArea.bytes[0x10], 0x4000));
    try testing.expectEqual(ERROR.ALIGNMENT, sceAgcSetAmmSemaphoreMemory(&SemaphoreArea.bytes, 0x100));
    try testing.expectEqual(@as(i32, 0), sceAgcSetAmmSemaphoreMemory(&SemaphoreArea.bytes, 0x8000));
    try testing.expectEqual(@as(u8, 0), SemaphoreArea.bytes[0x7FFF]);
    try testing.expectEqual(ERROR.SEMAPHORE_REGISTERED, sceAgcSetAmmSemaphoreMemory(&SemaphoreArea.bytes, 0x8000));
    try testing.expectEqual(@as(i32, 0), sceAgcGetSemaphoreLabel(3, &label));
    try testing.expectEqual(@intFromPtr(&SemaphoreArea.bytes) + 96, label);
    try testing.expectEqual(ERROR.OUT_OF_RANGE, sceAgcGetSemaphoreLabel(0x8000 / 32, &label));

    try testing.expectEqual(@as(i32, 0), sceAgcSetSubmitMode(0));
    try testing.expectEqual(ERROR.INVALID, sceAgcSetSubmitMode(1));
    try testing.expectEqual(@as(i32, 0), sceAgcSuspendPoint());
    try testing.expectEqual(@as(i32, 0), sceAgcDebugRaiseException());
}
