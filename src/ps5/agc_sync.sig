//! @zpm/ps5 agc_sync — libSceAgc's flow control (jumps, branches,
//! conditions, predication), memory and sync packets, the display's
//! packets, markers and workloads (agc.sig has the library's table).
//! Allocation-free.

const std = @import("std");
const pm4 = @import("pm4.sig");

const OP = pm4.OP;
const SUB = pm4.SUB;
const header = pm4.header;

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

// ── Flow ────────────────────────────────────────────────────────────────────

/// A call into another buffer (`mode` 1: a jump, never back). Bit 21 is
/// set by the draw queue's form and bit 23 by the compute queue's; the
/// driver reads neither, and what they mean is not known.
pub fn sceAgcDcbJump(buf: Buf, mode: u8, cache: u8, target: u64, words: u32) callconv(.c) Out {
    return put(buf, &.{ header(OP.INDIRECT_BUFFER, 4, 0), lo32(target) & ~@as(u32, 3), hi32(target), 0x0F20_0000 | ((w32(cache) & 3) << 28) | ((w32(mode) & 1) << 20) | (words & 0xF_FFFF) });
}
pub fn sceAgcAcbJump(buf: Buf, cache: u8, target: u64, words: u32) callconv(.c) Out {
    return put(buf, &.{ header(OP.INDIRECT_BUFFER, 4, 0), lo32(target) & ~@as(u32, 3), hi32(target), 0x0F90_0000 | ((w32(cache) & 3) << 28) | (words & 0xF_FFFF) });
}

/// A call into one of two buffers by a 64-bit value in memory, masked and
/// compared. (The driver here does not carry this form out.)
pub fn sceAgcCbBranch(buf: Buf, mode: u8, function: u8, compare_at: u64, mask: u64, reference: u64, cache1: u8, then_at: u64, then_words: u32, cache2: u8, else_at: u64, else_words: u32) callconv(.c) Out {
    if (mode > 3 or function > 7 or cache1 > 3 or cache2 > 3 or then_words > 0xF_FFFF or else_words > 0xF_FFFF) return null;
    if (function != 0 and (compare_at == 0 or compare_at & 7 != 0)) return null;
    if (!branchTarget(then_at, then_words) or !branchTarget(else_at, else_words)) return null;
    return put(buf, &.{
        header(OP.INDIRECT_BUFFER, 14, 0), w32(mode) | (w32(function) << 8),
        lo32(compare_at),                  hi32(compare_at),
        lo32(mask),                        hi32(mask),
        lo32(reference),                   hi32(reference),
        lo32(then_at),                     hi32(then_at),
        then_words | (w32(cache1) << 28),  lo32(else_at),
        hi32(else_at),                     else_words | (w32(cache2) << 28),
    });
}

/// A branch's target: none at all, or an aligned one.
pub fn branchTarget(at: u64, words: u32) bool {
    if (at == 0 and words == 0) return true;
    return at != 0 and at & 3 == 0;
}

/// When a word in memory compares as asked with a reference, a word is
/// written somewhere. (The driver here does not carry this out.)
pub fn sceAgcCbCondWrite(buf: Buf, function: u32, space: u32, write_at: u64, data: u32, poll_at: u64, reference: u32, mask: u32) callconv(.c) Out {
    if (write_at >> 48 != 0 or poll_at >> 48 != 0) return null;
    return put(buf, &.{ header(OP.COND_WRITE, 9, 0), 0x10 | (function & 7) | ((space & 3) << 8), lo32(poll_at), hi32(poll_at), reference, mask, lo32(write_at), hi32(write_at), data });
}

/// The next `words` words are skipped when the word at `at` is 0.
fn condExec(buf: Buf, at: u64, words: u32) Out {
    if (at == 0 or at & 3 != 0 or words > 0x3FFF) return null;
    return put(buf, &.{ header(OP.COND_EXEC, 5, 0), lo32(at) & ~@as(u32, 3), hi32(at), 0, words });
}
pub fn sceAgcDcbCondExec(buf: Buf, at: u64, words: u32) callconv(.c) Out {
    return condExec(buf, at, words);
}
pub fn sceAgcAcbCondExec(buf: Buf, at: u64, words: u32) callconv(.c) Out {
    return condExec(buf, at, words);
}

/// The queue stops here until the packet's word has its top bit set (the
/// game sets it, later, with sceAgcRewindPatchSetRewindState).
fn rewind(buf: Buf, state: u32) Out {
    return put(buf, &.{ header(OP.REWIND, 2, 0), (state & 1) << 31 });
}
pub fn sceAgcDcbRewind(buf: Buf, state: u32) callconv(.c) Out {
    return rewind(buf, state);
}
pub fn sceAgcAcbRewind(buf: Buf, state: u32) callconv(.c) Out {
    return rewind(buf, state);
}

/// Whether the packets marked for it run, by a value at `at` (`op`: 0
/// off, 3 a 64-bit value, 4 a 32-bit one, as the driver reads it). The
/// count is not written.
pub fn sceAgcDcbSetPredication(buf: Buf, condition: u8, op: u8, wait: u8, at: u64, words: u32) callconv(.c) Out {
    _ = words;
    return put(buf, &.{ header(OP.SET_PREDICATION, 4, 0), ((w32(condition) & 1) << 8) | ((w32(wait) & 1) << 12) | ((w32(op) & 7) << 16), lo32(at) & ~@as(u32, 0xF), hi32(at) });
}

pub fn sceAgcDcbStallCommandBufferParser(buf: Buf) callconv(.c) Out {
    return put(buf, &.{ header(OP.PFP_SYNC_ME, 2, 0), 0 });
}

/// The context registers to the GPU's cleared state. `op` is checked and
/// not written (so the open implementation; not known why).
pub fn sceAgcDcbResetQueue(buf: Buf, op: u32, state: u32) callconv(.c) Out {
    if (op > 0xFFF or state > 0xF) return null;
    return put(buf, &.{ header(OP.CLEAR_STATE, 2, 0), state });
}
pub fn sceAgcDcbClearState(buf: Buf, command: u32) callconv(.c) Out {
    return put(buf, &.{ header(OP.CLEAR_STATE, 2, 0), command & 0xF });
}
/// A compute queue's state back to its start: this pair's own packet, and
/// `value` is not written.
pub fn sceAgcAcbResetQueue(buf: Buf, op: u32, value: u32) callconv(.c) Out {
    _ = value;
    return put(buf, &.{ pm4.nop(SUB.DISPATCH_RESET, 2), op });
}

/// The context registers reset (0), saved (1), restored (2), or saved and
/// reset (3): a run of NOPs, the first of them this pair's own, of the
/// sizes an open emulator gives (a console's are not known).
const context_ops = [4][]const u8{ &.{5}, &.{ 5, 8, 9, 3, 2 }, &.{ 3, 5, 8, 9, 2 }, &.{ 5, 8, 9, 3, 2, 5 } };

fn contextWords(op: u32) u32 {
    if (op >= context_ops.len) return 0;
    var n: u32 = 0;
    for (context_ops[op]) |s| n += s;
    return n;
}

pub fn sceAgcDcbContextStateOp(buf: Buf, op: u32) callconv(.c) Out {
    const n = contextWords(op);
    if (n == 0) return null;
    const out = reserve(buf, n) orelse return null;
    var at: usize = 0;
    for (context_ops[op]) |s| {
        fillNop(out[at..][0..s]);
        at += s;
    }
    out[0] = pm4.nop(SUB.CONTEXT_STATE, context_ops[op][0]);
    out[1] = op;
    return out.ptr;
}
pub fn sceAgcDcbContextStateOpGetSize(op: u32) callconv(.c) u32 {
    return contextWords(op) * 4;
}

// ── Memory ──────────────────────────────────────────────────────────────────

/// Words of the packet to memory or a register. The draw queue's `dst`
/// is 5 bits (its low bit goes to bit 30), the compute queue's 4.
/// `increment` is bit 16 as given: the driver here takes it as "all to one
/// address" (what 1 means on a console is not known).
fn writeData(buf: Buf, dst: u8, cache: u8, at: u64, data: ?*const anyopaque, n: u32, increment: u8, confirm: u8, compute: bool) Out {
    if (n == 0 or n > 0x3FFD) return null;
    const from: [*]align(1) const u32 = @ptrCast(data orelse return null);
    if (dst > @as(u8, if (compute) 0xF else 0x1F) or cache > 3 or increment > 1 or confirm > 1) return null;
    if (!compute and at & 3 != 0) return null;
    if (dst == 0 and confirm != 0) return null;
    const where: u32 = if (compute) w32(dst) << 8 else ((w32(dst) & 1) << 30) | ((w32(dst) & 0x1E) << 7);
    // (The open implementation copies the data before the buffer may grow,
    // in case it is in the buffer; here it is copied after.)
    const out = reserve(buf, n + 4) orelse return null;
    out[0] = header(OP.WRITE_DATA, n + 4, 0);
    out[1] = where | (w32(increment) << 16) | (w32(confirm) << 20) | (w32(cache) << 25);
    out[2] = lo32(at);
    out[3] = hi32(at);
    for (out[4..], from[0..n]) |*o, x| o.* = x;
    return out.ptr;
}
pub fn sceAgcDcbWriteData(buf: Buf, dst: u8, cache: u8, at: u64, data: ?*const anyopaque, n: u32, increment: u8, confirm: u8) callconv(.c) Out {
    return writeData(buf, dst, cache, at, data, n, increment, confirm, false);
}
pub fn sceAgcAcbWriteData(buf: Buf, dst: u8, cache: u8, at: u64, data: ?*const anyopaque, n: u32, increment: u8, confirm: u8) callconv(.c) Out {
    return writeData(buf, dst, cache, at, data, n, increment, confirm, true);
}
pub fn sceAgcDcbWriteDataGetSize(n: u32) callconv(.c) u32 {
    return n *% 4 +% 16;
}

/// A value (32 or 64 bits) from memory, a register, the packet itself
/// (selector 5) or a clock, to memory or a register. The draw queue's
/// selectors are shifted up one, their low bit the engine.
fn copyData(buf: Buf, dst: u8, dst_cache: u8, dst_at: u64, src: u8, src_cache: u8, src_value: u64, item: u8, confirm: u8, compute: bool) Out {
    if (item > 1 or confirm > 1) return null;
    const src_sel: u32 = if (compute) w32(src) & 0xF else (w32(src) >> 1) & 0xF;
    const dst_sel: u32 = if (compute) w32(dst) & 0xF else (w32(dst) >> 1) & 0xF;
    const engine: u32 = if (compute) 0 else w32(src) & 1;
    if (src_sel == 5 and item == 0 and src_value >> 32 != 0) return null;
    const control = src_sel | (dst_sel << 8) | ((w32(src_cache) & 3) << 13) | (w32(item) << 16) | (w32(confirm) << 20) | ((w32(dst_cache) & 3) << 25) | (engine << 30);
    return put(buf, &.{ header(OP.COPY_DATA, 6, 0), control, lo32(src_value), hi32(src_value), lo32(dst_at), hi32(dst_at) });
}
pub fn sceAgcDcbCopyData(buf: Buf, dst: u8, dst_cache: u8, dst_at: u64, src: u8, src_cache: u8, src_value: u64, item: u8, confirm: u8) callconv(.c) Out {
    return copyData(buf, dst, dst_cache, dst_at, src, src_cache, src_value, item, confirm, false);
}
pub fn sceAgcAcbCopyData(buf: Buf, dst: u8, dst_cache: u8, dst_at: u64, src: u8, src_cache: u8, src_value: u64, item: u8, confirm: u8) callconv(.c) Out {
    return copyData(buf, dst, dst_cache, dst_at, src, src_cache, src_value, item, confirm, true);
}

/// Bytes copied, or a place filled with a word (source 2), by the DMA
/// engine. Three source values name one of three registers instead of an
/// address (0x14, 0x24, and 0x64 on the draw queue or 0x25 on the compute
/// queue): their user-configuration byte addresses go in the packet.
fn dmaData(buf: Buf, engine: u8, dst: u8, dst_cache: u8, dst_at: u64, src: u8, src_cache: u8, src_at: u64, bytes: u32, wait: u8, confirm: u8, block: u8, compute: bool) Out {
    if (bytes > 0x3FF_FFFF or wait > 1 or confirm > 1 or block > 1) return null;
    const d = w32(dst) & 0xF;
    const slot: ?u64 = switch (src) {
        0x14 => 0,
        0x24 => 1,
        0x64 => if (compute) null else 2,
        0x25 => if (compute) 2 else null,
        else => null,
    };
    // (the special values' low four bits are the selector, as for others)
    const s = w32(src) & 0xF;
    const from: u64 = if (slot) |k| @as(u64, if (engine & 1 == 1) 0x30148 else 0x30174) + k * 8 else src_at;
    const control = (w32(engine) & 1) | ((w32(src_cache) & 3) << 13) | ((d & 3) << 20) | ((w32(dst_cache) & 3) << 25) | ((s & 3) << 29) | (w32(block) << 31);
    const command = bytes | ((s & 4) << 24) | ((d & 4) << 25) | ((s & 8) << 25) | ((d & 8) << 26) | (w32(wait) << 30) | (w32(confirm) << 31);
    return put(buf, &.{ header(OP.DMA_DATA, 7, 0), control, lo32(from), hi32(from), lo32(dst_at), hi32(dst_at), command });
}
pub fn sceAgcDcbDmaData(buf: Buf, engine: u8, dst: u8, dst_cache: u8, dst_at: u64, src: u8, src_cache: u8, src_at: u64, bytes: u32, wait: u8, confirm: u8, block: u8) callconv(.c) Out {
    return dmaData(buf, engine, dst, dst_cache, dst_at, src, src_cache, src_at, bytes, wait, confirm, block, false);
}
pub fn sceAgcAcbDmaData(buf: Buf, dst: u8, dst_cache: u8, dst_at: u64, src: u8, src_cache: u8, src_at: u64, bytes: u32, wait: u8, confirm: u8) callconv(.c) Out {
    return dmaData(buf, 0, dst, dst_cache, dst_at, src, src_cache, src_at, bytes, wait, confirm, 0, true);
}

/// Caches written back or dropped for a range of memory, in 256-byte
/// blocks rounded outward. `cb_db` bit 14 or 26: all of memory. (What a
/// console writes for the whole range and for a range past the end of the
/// address space is the open implementation's guess.)
fn acquireMem(buf: Buf, engine: u8, cb_db: u32, gcr: u32, base: u64, bytes: u64, poll: u32) Out {
    const most: u64 = (1 << 40) - 1;
    var page: u64 = undefined;
    var blocks: u64 = undefined;
    if (cb_db & 0x0400_4000 != 0) {
        page = 1;
        blocks = most - 1;
    } else {
        page = base >> 8;
        if (bytes > (most << 8) - (base & 0xFF)) {
            blocks = if (page < most) most - page else 0;
        } else {
            blocks = (bytes + (base & 0xFF) + 0xFF) >> 8;
        }
    }
    const c = gcr & 0x7_FFFF;
    return put(buf, &.{
        header(OP.ACQUIRE_MEM, 8, 0), ((w32(engine) & 1) << 31) | (cb_db & 0x0600_7FC0),
        lo32(blocks),                 hi32(blocks) & 0xFF,
        lo32(page),                   hi32(page) & 0xFF_FFFF,
        @min(poll >> 4, 0xFFFF),      c | ((c & 0x4000) << 1),
    });
}
pub fn sceAgcDcbAcquireMem(buf: Buf, engine: u8, cb_db: u32, gcr: u32, base: u64, bytes: u64, poll: u32) callconv(.c) Out {
    return acquireMem(buf, engine, cb_db, gcr, base, bytes, poll);
}
pub fn sceAgcAcbAcquireMem(buf: Buf, gcr: u32, base: u64, bytes: u64, poll: u32) callconv(.c) Out {
    return acquireMem(buf, 0, 0, gcr, base, bytes, poll);
}

/// RELEASE_MEM: when the work before it is done (an end-of-pipe action,
/// below 0x2F; end of shader from 0x2F on), a value to memory and/or an
/// interrupt. Data selector 1: 32 bits, 2: 64 bits, 3: the GPU's clock, 5:
/// GDS (`gds_offset`, `gds_size`). Interrupt 4: an interrupt and nothing
/// written.
pub fn sceAgcCbReleaseMem(buf: Buf, action: u8, gcr: u16, dst: u8, cache: u8, label: u64, select: u8, data: u64, gds_offset: u16, gds_size: u16, irq: u8, context: u32) callconv(.c) Out {
    if (action > 0x3F or gcr > 0xFFF or dst > 1 or cache > 3 or irq > 4 or context > 0x7FF_FFFF) return null;
    if (select > 5 or select == 4) return null;
    var value = data;
    if (select == 5) {
        if (data != 0) return null;
        value = @as(u64, gds_offset) | @as(u64, gds_size) << 16;
    } else if (gds_offset != 0 or gds_size > 1) return null;
    if (select == 1 and data >> 32 != 0) return null;
    if (irq == 4 and (label != 0 or data != 0)) return null;
    if (label != 0 and select != 0 and label & @as(u64, if (select == 2 or select == 3) 7 else 3) != 0) return null;
    return put(buf, &.{
        header(OP.RELEASE_MEM, 8, 0), action1(action, gcr) | (w32(cache) << 25),
        (w32(dst) << 16) | (w32(irq) << 24) | (w32(select) << 29),
        lo32(label),                  hi32(label),
        lo32(value),                  hi32(value),
        context,
    });
}

/// A RELEASE_MEM's first word, but for its cache policy: the action, its
/// event index, the cache control (bit 9 joins bit 8 when bit 8 is alone).
fn action1(action: u8, gcr: u16) u32 {
    var g: u32 = gcr;
    if (g & 0x300 == 0x100) g |= 0x200;
    const index: u32 = if (action >= 0x2F) 6 else 5;
    return w32(action) | (index << 8) | (g << 12);
}

/// The queue waits until a value in memory, masked, compares as asked with
/// a reference (function: 0 always, 1 <, 2 <=, 3 ==, 4 !=, 5 >=, 6 >), 32
/// or (size 1) 64 bits; bracketed by tags that say what is waited on.
fn waitRegMem(buf: Buf, size: u8, function: u8, op: u8, cache: u8, at: u64, reference: u64, mask: u64, poll: u32, q: u8) Out {
    if (function > 6 or poll >> 4 > 0xFFFF or at >> 48 != 0) return null;
    const p = poll >> 4;
    const tag_at = hi32(at) & 0xFFFF;
    const control0 = 0x10 | w32(function) | ((w32(cache) & 3) << 25);
    switch (size) {
        0 => {
            if (op > 0xF or at & 3 != 0) return null;
            const control = control0 | ((w32(op) & 3) << 8) | ((w32(op) & 0xC) << 4);
            return put(buf, &.{
                header(OP.SET_UCONFIG_REG, 4, q), pm4.UC_TAG,  TAG.WAIT_32 | tag_at, lo32(at),
                header(OP.WAIT_REG_MEM, 7, 0),    control,     lo32(at),             hi32(at),
                lo32(reference),                  lo32(mask),  p,                    header(OP.SET_UCONFIG_REG, 3, q),
                pm4.UC_TAG,                       TAG.WAIT_END,
            });
        },
        1 => {
            if (op > 7) return null;
            const control = control0 | ((w32(op) & 1) << 8) | ((w32(op) & 6) << 5);
            return put(buf, &.{
                header(OP.SET_UCONFIG_REG, 4, q), pm4.UC_TAG,       TAG.WAIT_64 | tag_at,  lo32(at),
                header(OP.WAIT_REG_MEM_64, 9, 0), control,          lo32(at) & ~@as(u32, 7), hi32(at),
                lo32(reference),                  hi32(reference),  lo32(mask),            hi32(mask),
                p,                                header(OP.SET_UCONFIG_REG, 3, q), pm4.UC_TAG, TAG.WAIT_END,
            });
        },
        else => return null,
    }
}
pub fn sceAgcDcbWaitRegMem(buf: Buf, size: u8, function: u8, op: u8, cache: u8, at: u64, reference: u64, mask: u64, poll: u32) callconv(.c) Out {
    return waitRegMem(buf, size, function, op, cache, at, reference, mask, poll, pm4.FLAG.RESET_FILTER_CAM);
}
pub fn sceAgcAcbWaitRegMem(buf: Buf, size: u8, function: u8, cache: u8, at: u64, reference: u64, mask: u64, poll: u32) callconv(.c) Out {
    return waitRegMem(buf, size, function, 0, cache, at, reference, mask, poll, 0);
}
pub fn sceAgcWaitOnAddressGetSize(size: u8) callconv(.c) u32 {
    return switch (size) {
        0 => 56,
        1 => 64,
        else => 0,
    };
}

/// An event for the pipeline. Types 0x38 and 0x39 (a dump of counters)
/// carry an address; the event index for those is 1, for the partial
/// flushes (7, 15, 16 on the draw queue; 7 on the compute queue) 4.
pub fn sceAgcDcbEventWrite(buf: Buf, kind: u8, at: u64) callconv(.c) Out {
    if (kind > 0x3F) return null;
    if (kind == 0x38 or kind == 0x39) {
        if (at == 0 or at & 7 != 0) return null;
        return put(buf, &.{ header(OP.EVENT_WRITE, 4, 0), 0x100 | w32(kind), lo32(at), hi32(at) });
    }
    const index: u32 = if (kind == 7 or kind == 15 or kind == 16) 0x400 else 0;
    return put(buf, &.{ header(OP.EVENT_WRITE, 2, 0), index | kind });
}
pub fn sceAgcAcbEventWrite(buf: Buf, kind: u8, at: u64) callconv(.c) Out {
    if (kind > 0x3F) return null;
    if ((kind == 0x38 or kind == 0x39) and at != 0) return null;
    const index: u32 = if (kind == 7) 0x400 else 0;
    return put(buf, &.{ header(OP.EVENT_WRITE, 2, 0), index | kind });
}
pub fn sceAgcDcbEventWriteGetSize(kind: u8) callconv(.c) u32 {
    return if (kind == 0x38 or kind == 0x39) 16 else 8;
}
/// (no writer of an occlusion query is exported here; only the sizes)
pub fn sceAgcDcbBeginOcclusionQueryGetSize(kind: u32) callconv(.c) u32 {
    return switch (kind) {
        0 => 0x10,
        1 => 0x120,
        else => 0,
    };
}

/// An atomic operation on memory. (The two queues' forms take their
/// arguments in different orders, as a console's were measured; the
/// driver here does not carry it out.) Every field is masked, none
/// refused.
fn atomicMem(buf: Buf, engine: u8, op: u8, command: u8, cache: u8, at: u64, src: u64, compare: u64, loop: u16) Out {
    return put(buf, &.{
        header(OP.ATOMIC_MEM, 9, 0), (w32(op) & 0x7F) | ((w32(command) & 0xF) << 8) | ((w32(cache) & 3) << 25) | ((w32(engine) & 3) << 30),
        lo32(at),                    hi32(at),
        lo32(src),                   hi32(src),
        lo32(compare),               hi32(compare),
        w32(loop) & 0x1FFF,
    });
}
pub fn sceAgcDcbAtomicMem(buf: Buf, engine: u8, op: u8, command: u8, cache: u8, at: u64, src: u64, compare: u64, loop: u16) callconv(.c) Out {
    return atomicMem(buf, engine, op, command, cache, at, src, compare, loop);
}
pub fn sceAgcAcbAtomicMem(buf: Buf, op: u8, command: u8, at: u64, cache: u8, src: u64, compare: u64, loop: u16) callconv(.c) Out {
    return atomicMem(buf, 0, op, command, cache, at, src, compare, loop);
}

/// An atomic operation on the GDS. The layout comes from one open project
/// and was never checked against a console; the driver here does not carry
/// it out. (These, the unversioned exports, clear bit 7 of `control`; the
/// "_0900" exports that keep it are not in the public name list.)
fn atomicGds(buf: Buf, engine: u32, control: u32, mode: u32, op: u32, src: u32, offset: u16, index: u16, mask: u32, data: u32, compare: u64, extra: u64) Out {
    const c = control & ~@as(u32, 0x80);
    const bit17: u32 = if (c & 0x20 == 0 and mode == 1) 1 << 17 else 0;
    return put(buf, &.{
        header(OP.ATOMIC_GDS, 11, 0),
        (c & 0xFF) | ((c & 0x200) << 7) | ((c & 0x20) << 13) | ((c & 0x40) << 14) | bit17 | ((engine & 3) << 30),
        ((op & 1) << 8) | (src & 0x3F),
        offset,
        index,
        mask & 0x00FF_00FF,
        data,
        lo32(compare),
        hi32(compare),
        lo32(extra),
        hi32(extra),
    });
}
pub fn sceAgcDcbAtomicGds(buf: Buf, engine: u32, control: u32, mode: u32, op: u32, src: u32, offset: u16, index: u16, mask: u32, data: u32, compare: u64, extra: u64) callconv(.c) Out {
    return atomicGds(buf, engine, control, mode, op, src, offset, index, mask, data, compare, extra);
}
pub fn sceAgcAcbAtomicGds(buf: Buf, control: u32, mode: u32, op: u32, src: u32, offset: u16, index: u16, mask: u32, data: u32, compare: u64, extra: u64) callconv(.c) Out {
    return atomicGds(buf, 0, control, mode, op, src, offset, index, mask, data, compare, extra);
}

/// A semaphore in memory signalled (6) or waited on (7). (The driver here
/// does not carry it out.)
fn memSemaphore(buf: Buf, at: u64, mailbox: u8, signal: u8, op: u8) Out {
    if ((op != 6 and op != 7) or mailbox > 1 or signal > 1 or at == 0 or at & 7 != 0) return null;
    return put(buf, &.{ header(OP.MEM_SEMAPHORE, 4, 0), lo32(at), hi32(at), (w32(op) << 29) | (w32(signal) << 20) | (w32(mailbox) << 16) });
}
pub fn sceAgcDcbMemSemaphore(buf: Buf, at: u64, mailbox: u8, signal: u8, op: u8) callconv(.c) Out {
    return memSemaphore(buf, at, mailbox, signal, op);
}
pub fn sceAgcAcbMemSemaphore(buf: Buf, at: u64, mailbox: u8, signal: u8, op: u8) callconv(.c) Out {
    return memSemaphore(buf, at, mailbox, signal, op);
}
/// (the last three arguments are not read: the open implementation writes
/// one fixed word for them)
pub fn sceAgcCbMemSemaphore(buf: Buf, at: u64, op: u32, modifier: u32, value: u32) callconv(.c) Out {
    _ = op;
    _ = modifier;
    _ = value;
    return put(buf, &.{ header(OP.MEM_SEMAPHORE, 4, 0), lo32(at) & ~@as(u32, 0xF), hi32(at), 0x8010_0000 });
}

/// Stand-ins: NOPs of the real packets' sizes, with their words (the real
/// opcodes, PRIME_UTCL2 and GET_LOD_STATS, are not written: nothing here
/// would carry them out).
fn primeUtcl2(buf: Buf, at: u64, bytes: u32) Out {
    return put(buf, &.{ header(OP.NOP, 5, 0), 0, lo32(at), hi32(at), bytes });
}
pub fn sceAgcDcbPrimeUtcl2(buf: Buf, at: u64, bytes: u32) callconv(.c) Out {
    return primeUtcl2(buf, at, bytes);
}
pub fn sceAgcAcbPrimeUtcl2(buf: Buf, at: u64, bytes: u32) callconv(.c) Out {
    return primeUtcl2(buf, at, bytes);
}
pub fn sceAgcDcbGetLodStats(buf: Buf, cache: u8, out_at: u64, bytes: u32, resets: u32, force: u8, report: u8, interval: u32) callconv(.c) Out {
    if (cache > 3 or resets > 0xFF or interval > 0xFF or force > 1 or report > 1 or out_at & 63 != 0) return null;
    return put(buf, &.{ header(OP.NOP, 5, 0), bytes, lo32(out_at), hi32(out_at), (w32(cache) << 28) | (w32(report) << 19) | (w32(force) << 18) | (resets << 10) | (interval << 2) });
}

// ── Display ─────────────────────────────────────────────────────────────────
//
// The flip and the wait for a display buffer are this library pair's own
// packets: the words are pm4.Writer's, which the driver reads back.

/// Show display buffer `index` of output `handle` (videoout.sig) once the
/// work before it is done.
fn setFlip(buf: Buf, handle: u32, index: i32, mode: u32, arg: i64) Out {
    const out = reserve(buf, 6) orelse return null;
    var w = pm4.Writer{ .words = out };
    _ = w.flip(handle, index, mode, arg);
    return out.ptr;
}
pub fn sceAgcDcbSetFlip(buf: Buf, handle: u32, index: i32, mode: u32, arg: i64) callconv(.c) Out {
    return setFlip(buf, handle, index, mode, arg);
}
pub fn sceAgcAcbSetFlip(buf: Buf, handle: u32, index: i32, mode: u32, arg: i64) callconv(.c) Out {
    return setFlip(buf, handle, index, mode, arg);
}

/// The queue waits until no flip of display buffer `index` is waiting to
/// be shown (the same packet as the driver's
/// sceAgcDriverWaitUntilSafeForRendering).
fn waitSafe(buf: Buf, handle: u32, index: u32) Out {
    const out = reserve(buf, 4) orelse return null;
    var w = pm4.Writer{ .words = out };
    _ = w.putNop(SUB.WAIT_SAFE, &.{ handle, index, 0 });
    return out.ptr;
}
pub fn sceAgcDcbWaitUntilSafeForRendering(buf: Buf, handle: u32, index: u32) callconv(.c) Out {
    return waitSafe(buf, handle, index);
}
pub fn sceAgcAcbWaitUntilSafeForRendering(buf: Buf, handle: u32, index: u32) callconv(.c) Out {
    return waitSafe(buf, handle, index);
}

// ── Markers ─────────────────────────────────────────────────────────────────
//
// A name for the packets that follow (for a capture tool): the text in a
// NOP of this pair's own, ended with a 0 and padded. The colour is not
// written. A console is said to write these differently (a tag and a
// WRITE_DATA, with the colour); not known for sure.

/// The longest text: one more byte and the packet would be the longest a
/// NOP can be, whose header reads as a one-word filler. (The open
/// implementation takes 0xFFFF bytes; this refuses the last four.)
const MARKER_MOST = 0xFFFB;

fn marker(buf: Buf, text: ?[*]const u8, len: usize, and_pop: bool) Out {
    if (len > MARKER_MOST or (text == null and len != 0)) return null;
    const p = (len + 4) / 4;
    const out = reserve(buf, 1 + p + @as(usize, if (and_pop) 2 else 0)) orelse return null;
    out[0] = pm4.nop(SUB.PUSH_MARKER, @intCast(1 + p));
    @memset(out[1..][0..p], 0);
    if (len != 0) @memcpy(std.mem.sliceAsBytes(out[1..][0..p])[0..len], text.?[0..len]);
    if (and_pop) {
        out[1 + p] = pm4.nop(SUB.POP_MARKER, 2);
        out[2 + p] = 0;
    }
    return out.ptr;
}

/// A text's length, or null when it is longer than a marker may be.
fn textLength(text: ?[*:0]const u8) ?usize {
    const t = text orelse return 0;
    var n: usize = 0;
    while (t[n] != 0) {
        n += 1;
        if (n > MARKER_MOST) return null;
    }
    return n;
}

fn pushMarker(buf: Buf, text: ?[*:0]const u8, and_pop: bool) Out {
    const n = textLength(text) orelse return null;
    return marker(buf, text, n, and_pop);
}

pub fn sceAgcDcbPushMarker(buf: Buf, text: ?[*:0]const u8, color: u32) callconv(.c) Out {
    _ = color;
    return pushMarker(buf, text, false);
}
pub fn sceAgcDcbPushMarkerSpan(buf: Buf, text: ?[*]const u8, len: u32, color: u32) callconv(.c) Out {
    _ = color;
    return marker(buf, text, len, false);
}
pub fn sceAgcDcbSetMarker(buf: Buf, text: ?[*:0]const u8, color: u32) callconv(.c) Out {
    _ = color;
    return pushMarker(buf, text, true);
}
pub fn sceAgcDcbSetMarkerSpan(buf: Buf, text: ?[*]const u8, len: u32, color: u32) callconv(.c) Out {
    _ = color;
    return marker(buf, text, len, true);
}
pub fn sceAgcDcbPopMarker(buf: Buf) callconv(.c) Out {
    return put(buf, &.{ pm4.nop(SUB.POP_MARKER, 2), 0 });
}

// ── Workloads ───────────────────────────────────────────────────────────────
//
// Which workloads of a stream are under way (a profiler's matter). Written
// as plain NOPs of the sizes a console's packets are believed to have; the
// words a console writes (a tag, a WRITE_DATA, an atomic) are not. The
// open implementation also asks its driver whether the stream was
// registered; the driver here keeps no such list, so every stream is
// taken.

pub fn sceAgcDcbSetWorkloadsActive(buf: Buf, stream: u32, ids: ?[*]const u32, count: u32) callconv(.c) Out {
    const list = ids orelse return null;
    if (count == 0 or count > 63) return null;
    var mask: u64 = 0;
    for (list[0..count]) |id| {
        if (id > 63) return null;
        const bit = @as(u64, 1) << @intCast(id);
        if (mask & bit != 0) return null;
        mask |= bit;
    }
    const out = reserve(buf, 18) orelse return null;
    fillNop(out);
    out[1] = stream;
    out[2] = lo32(mask);
    out[3] = hi32(mask);
    return out.ptr;
}
pub fn sceAgcDcbSetWorkloadComplete(buf: Buf, stream: u32, id: u32) callconv(.c) Out {
    if (id > 63) return null;
    const left = ~(@as(u64, 1) << @intCast(id));
    const out = reserve(buf, 12) orelse return null;
    fillNop(out);
    out[1] = stream;
    out[2] = id;
    out[3] = lo32(left);
    out[4] = hi32(left);
    return out.ptr;
}
pub fn sceAgcDcbSetWorkloadStreamInactive(buf: Buf, stream: u32) callconv(.c) Out {
    const out = reserve(buf, 9) orelse return null;
    fillNop(out);
    out[1] = stream;
    return out.ptr;
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// The words open projects' tests give for these calls, and every buffer
// read back packet by packet.

const testing = std.testing;

fn expectWords(cb: *const CommandBuffer, want: []const u32) !void {
    try testing.expectEqualSlices(u32, want, cb.written());
}

fn nopOp(sub: u8) u16 {
    return 0x100 + @as(u16, sub);
}

/// The opcodes of a buffer's packets, read back (NOPs by sub-type, as
/// 0x100 + sub).
fn expectOps(cb: *const CommandBuffer, want: []const u16) !void {
    var r = pm4.Reader{ .words = cb.written() };
    var got: [64]u16 = undefined;
    var n: usize = 0;
    while (try r.next()) |p| : (n += 1) got[n] = if (p.op() == OP.NOP) 0x100 + @as(u16, p.sub()) else p.op();
    try testing.expectEqualSlices(u16, want, got[0..n]);
}

test "flow: jumps, a branch, a conditional write, cond exec, rewind, predication" {
    var mem: [128]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbJump(&cb, 1, 2, 0x1234_5678_9AB0, 0x40);
    _ = sceAgcDcbJump(&cb, 0, 0, 0x1003, 0xFFFFF);
    _ = sceAgcAcbJump(&cb, 1, 0x1000, 0x10);
    try expectWords(&cb, &.{
        0xC002_3F00, 0x5678_9AB0, 0x1234, 0x2F30_0040,
        0xC002_3F00, 0x1000,      0,      0x0F2F_FFFF,
        0xC002_3F00, 0x1000,      0,      0x1F90_0010,
    });

    cb = CommandBuffer.over(&mem);
    _ = sceAgcCbBranch(&cb, 2, 3, 0x1234_5678_9AB8, 0x1122_3344_5566_7788, 0x99AA_BBCC_DDEE_FF00, 1, 0x22_3344_5564, 0x123, 2, 0x66_7788_9900, 0x456);
    try expectWords(&cb, &.{ 0xC00C_3F00, 0x302, 0x5678_9AB8, 0x1234, 0x5566_7788, 0x1122_3344, 0xDDEE_FF00, 0x99AA_BBCC, 0x3344_5564, 0x22, 0x1000_0123, 0x7788_9900, 0x66, 0x2000_0456 });
    // A compare address that is not 8-aligned; a target with words and no
    // address; a mode out of range.
    try testing.expectEqual(@as(Out, null), sceAgcCbBranch(&cb, 0, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcCbBranch(&cb, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcCbBranch(&cb, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcCbCondWrite(&cb, 3, 1, 0x1234_5678_9ABC, 0xDEAD_BEEF, 0xFEDC_BA98_7654, 0x1122_3344, 0xFF00_FF00);
    try expectWords(&cb, &.{ 0xC007_4500, 0x113, 0xBA98_7654, 0xFEDC, 0x1122_3344, 0xFF00_FF00, 0x5678_9ABC, 0x1234, 0xDEAD_BEEF });
    try testing.expectEqual(@as(Out, null), sceAgcCbCondWrite(&cb, 0, 0, 1 << 48, 0, 0, 0, 0));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbCondExec(&cb, 0x7_1234_5670, 3);
    _ = sceAgcDcbRewind(&cb, 1);
    _ = sceAgcAcbRewind(&cb, 0);
    _ = sceAgcDcbSetPredication(&cb, 0x11, 0x22, 0x33, 0x4444_4444, 99);
    _ = sceAgcDcbStallCommandBufferParser(&cb);
    _ = sceAgcDcbResetQueue(&cb, 0, 3);
    _ = sceAgcDcbClearState(&cb, 0x13);
    _ = sceAgcAcbResetQueue(&cb, 5, 9);
    try expectWords(&cb, &.{
        0xC003_2200, 0x1234_5670, 7,           0, 3,
        0xC000_5900, 0x8000_0000, 0xC000_5900, 0,
        0xC002_2000, 0x0002_1100, 0x4444_4440, 0,
        0xC000_4200, 0,           0xC000_1200, 3,
        0xC000_1200, 3,           0xC000_1024, 5,
    });
    try expectOps(&cb, &.{ OP.COND_EXEC, OP.REWIND, OP.REWIND, OP.SET_PREDICATION, OP.PFP_SYNC_ME, OP.CLEAR_STATE, OP.CLEAR_STATE, nopOp(SUB.DISPATCH_RESET) });
    try testing.expectEqual(@as(Out, null), sceAgcDcbCondExec(&cb, 0, 3));
    try testing.expectEqual(@as(Out, null), sceAgcAcbCondExec(&cb, 2, 3));
    try testing.expectEqual(@as(Out, null), sceAgcDcbCondExec(&cb, 4, 0x4000));
    try testing.expectEqual(@as(Out, null), sceAgcDcbResetQueue(&cb, 0x1000, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbResetQueue(&cb, 0, 0x10));
}

test "context-state operations: a run of NOPs, the first one saying which" {
    var mem: [64]u32 = undefined;
    for ([_]u32{ 0, 1, 2, 3 }, [_]u32{ 20, 108, 108, 128 }, [_]u32{ 0xC003_1068, 0xC003_1068, 0xC001_1068, 0xC003_1068 }) |op, bytes, head| {
        var cb = CommandBuffer.over(&mem);
        try testing.expectEqual(@as(Out, &mem), sceAgcDcbContextStateOp(&cb, op));
        try testing.expectEqual(bytes, sceAgcDcbContextStateOpGetSize(op));
        try testing.expectEqual(@as(usize, bytes / 4), cb.written().len);
        try testing.expectEqual(head, mem[0]);
        try testing.expectEqual(op, mem[1]);
        var r = pm4.Reader{ .words = cb.written() };
        var first = true;
        while (try r.next()) |p| : (first = false) {
            try testing.expectEqual(@as(u8, OP.NOP), p.op());
            try testing.expectEqual(if (first) SUB.CONTEXT_STATE else SUB.PLAIN, p.sub());
            for (p.body[(if (first) @as(usize, 1) else 0)..]) |x| try testing.expectEqual(@as(u32, 0), x);
        }
    }
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbContextStateOp(&cb, 1);
    try expectOps(&cb, &.{ nopOp(SUB.CONTEXT_STATE), 0x100, 0x100, 0x100, 0x100 });
    try testing.expectEqual(@as(Out, null), sceAgcDcbContextStateOp(&cb, 4));
    try testing.expectEqual(@as(u32, 0), sceAgcDcbContextStateOpGetSize(4));
    // No room for all of it: none of it.
    var small: [26]u32 = undefined;
    cb = CommandBuffer.over(&small);
    try testing.expectEqual(@as(Out, null), sceAgcDcbContextStateOp(&cb, 1));
    try testing.expectEqual(@as(usize, 0), cb.written().len);
}

test "memory: write data, copy data, DMA data, acquire mem" {
    var mem: [128]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    const data = [_]u32{ 1, 2, 3 };
    _ = sceAgcDcbWriteData(&cb, 2, 0, 0x2000, &data, 3, 1, 0);
    _ = sceAgcAcbWriteData(&cb, 5, 2, 0x2001, &data, 1, 0, 1);
    try expectWords(&cb, &.{ 0xC005_3700, 0x0001_0100, 0x2000, 0, 1, 2, 3, 0xC003_3700, 0x0410_0500, 0x2001, 0, 1 });
    try testing.expectEqual(@as(u32, 28), sceAgcDcbWriteDataGetSize(3));
    // Refused: no data, none, too many, a register with a confirm, an
    // unaligned address on the draw queue, a destination too large.
    try testing.expectEqual(@as(Out, null), sceAgcDcbWriteData(&cb, 2, 0, 0x2000, null, 1, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWriteData(&cb, 2, 0, 0x2000, &data, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWriteData(&cb, 2, 0, 0x2000, &data, 0x3FFE, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWriteData(&cb, 0, 0, 0x2000, &data, 1, 0, 1));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWriteData(&cb, 2, 0, 0x2002, &data, 1, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcAcbWriteData(&cb, 0x10, 0, 0x2000, &data, 1, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWriteData(&cb, 0x20, 0, 0x2000, &data, 1, 0, 0));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbCopyData(&cb, 4, 1, 0x11_2233_4450, 0xB, 2, 0x1234_5678, 0, 1);
    _ = sceAgcAcbCopyData(&cb, 1, 0, 0x1000, 5, 0, 0x1234, 0, 0);
    _ = sceAgcDcbCopyData(&cb, 2, 1, 0x1234_5678_9AB0, 5, 2, 0xDEAD_BEEF_0000_0010, 1, 1);
    try expectWords(&cb, &.{
        0xC004_4000, 0x4210_4205, 0x1234_5678, 0,           0x2233_4450, 0x11,
        0xC004_4000, 0x105,       0x1234,      0,           0x1000,      0,
        0xC004_4000, 0x4211_4102, 0x10,        0xDEAD_BEEF, 0x5678_9AB0, 0x1234,
    });
    // An immediate of more than 32 bits for a 32-bit copy.
    try testing.expectEqual(@as(Out, null), sceAgcAcbCopyData(&cb, 1, 0, 0x1000, 5, 0, 1 << 32, 0, 0));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbDmaData(&cb, 1, 5, 2, 0x7788_99AA_BBCC, 10, 1, 0x1122_3344_5566, 0x1234, 1, 1, 1);
    _ = sceAgcAcbDmaData(&cb, 5, 2, 0x10, 10, 1, 0x20, 0x1234, 1, 1);
    // The three register sources: their addresses, by engine.
    _ = sceAgcDcbDmaData(&cb, 1, 0, 0, 0x10, 0x24, 0, 0x9999, 4, 0, 0, 0);
    _ = sceAgcAcbDmaData(&cb, 0, 0, 0x10, 0x25, 0, 0x9999, 4, 0, 0);
    try expectWords(&cb, &.{
        0xC005_5000, 0xC410_2001, 0x3344_5566, 0x1122, 0x99AA_BBCC, 0x7788, 0xD800_1234,
        0xC005_5000, 0x4410_2000, 0x20,        0,      0x10,        0,      0xD800_1234,
        0xC005_5000, 0x0000_0001, 0x30150,     0,      0x10,        0,      0x0400_0004,
        0xC005_5000, 0x2000_0000, 0x30184,     0,      0x10,        0,      0x0400_0004,
    });
    try testing.expectEqual(@as(Out, null), sceAgcAcbDmaData(&cb, 0, 0, 0, 0, 0, 0, 0x400_0000, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcAcbDmaData(&cb, 0, 0, 0, 0, 0, 0, 1, 2, 0));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbAcquireMem(&cb, 0, 0, 0x1234, 0x12_3456_7890, 0x1000, 400);
    _ = sceAgcDcbAcquireMem(&cb, 3, 0x0200_0200, 0xFFF8_4000, 0xABCD_EF01_2345_6700, 0x100, 0);
    _ = sceAgcDcbAcquireMem(&cb, 1, 0x4000, 0x4380, 0x10_0000, 0x1000, 0xA0);
    _ = sceAgcAcbAcquireMem(&cb, 0x1234, 0x12_3456_7890, 0x1000, 400);
    try expectWords(&cb, &.{
        0xC006_5800, 0,           0x11,        0,    0x1234_5678, 0,        25, 0x1234,
        0xC006_5800, 0x8200_0200, 1,           0,    0x0123_4567, 0xABCDEF, 0,  0xC000,
        0xC006_5800, 0x8000_4000, 0xFFFF_FFFE, 0xFF, 1,           0,        10, 0xC380,
        0xC006_5800, 0,           0x11,        0,    0x1234_5678, 0,        25, 0x1234,
    });
    try expectOps(&cb, &.{ OP.ACQUIRE_MEM, OP.ACQUIRE_MEM, OP.ACQUIRE_MEM, OP.ACQUIRE_MEM });
}

test "the end-of-pipe action, waits on memory, events" {
    var mem: [128]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    const label: u64 = 0x7FFF_1234_5678;
    _ = sceAgcCbReleaseMem(&cb, 0x28, 0x0A5, 1, 2, label, 2, 0x1111_2222_3333_4444, 0, 0, 0, 0);
    // End of shader (from 0x2F); bit 9 of the cache control joins bit 8;
    // the GDS selector's value from its offset and size; an interrupt.
    _ = sceAgcCbReleaseMem(&cb, 0x2F, 0x100, 0, 0, 0, 5, 0, 0x10, 0x20, 2, 0x123);
    try expectWords(&cb, &.{
        0xC006_4900, 0x28 | 0x500 | 0xA5000 | 0x0400_0000, 0x4001_0000, 0x1234_5678, 0x7FFF, 0x3333_4444, 0x1111_2222, 0,
        0xC006_4900, 0x2F | 0x600 | 0x30_0000,             0xA200_0000, 0,           0,      0x20_0010,   0,           0x123,
    });
    // Refused: a selector of 4, data for the GDS, 64 bits for a 32-bit
    // value, an "interrupt only" with an address, an unaligned label.
    try testing.expectEqual(@as(Out, null), sceAgcCbReleaseMem(&cb, 0x28, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcCbReleaseMem(&cb, 0x28, 0, 0, 0, 0, 5, 1, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcCbReleaseMem(&cb, 0x28, 0, 0, 0, 0, 1, 1 << 32, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcCbReleaseMem(&cb, 0x28, 0, 0, 0, 8, 0, 0, 0, 0, 4, 0));
    try testing.expectEqual(@as(Out, null), sceAgcCbReleaseMem(&cb, 0x28, 0, 0, 0, 0x1004, 2, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcCbReleaseMem(&cb, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbWaitRegMem(&cb, 0, 3, 0, 0, label, 1, 0xFFFF_FFFF, 0x40);
    _ = sceAgcDcbWaitRegMem(&cb, 1, 3, 0, 0, label, 1, 0xFFFF_FFFF_FFFF_FFFF, 0x40);
    try expectWords(&cb, &.{
        0xC002_7904, 0x342, 0xC801_7FFF, 0x1234_5678, 0xC005_3C00, 0x13, 0x1234_5678, 0x7FFF, 1, 0xFFFF_FFFF, 4, 0xC001_7904, 0x342, 0xC800_0000,
        0xC002_7904, 0x342, 0xC802_7FFF, 0x1234_5678, 0xC007_9300, 0x13, 0x1234_5678, 0x7FFF, 1, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, 4, 0xC001_7904, 0x342, 0xC800_0000,
    });
    try expectOps(&cb, &.{ OP.SET_UCONFIG_REG, OP.WAIT_REG_MEM, OP.SET_UCONFIG_REG, OP.SET_UCONFIG_REG, OP.WAIT_REG_MEM_64, OP.SET_UCONFIG_REG });
    cb = CommandBuffer.over(&mem);
    _ = sceAgcAcbWaitRegMem(&cb, 1, 2, 3, 4, 5, 0, 0);
    try expectWords(&cb, &.{ 0xC002_7900, 0x342, 0xC802_0000, 4, 0xC007_9300, 0x0600_0012, 0, 0, 5, 0, 0, 0, 0, 0xC001_7900, 0x342, 0xC800_0000 });
    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbWaitRegMem(&cb, 1, 2, 3, 4, 5, 0, 1, 0xF_FFF0);
    try testing.expectEqual(@as(u32, 0x152), mem[5]);
    try testing.expectEqual(@as(u32, 0xFFFF), mem[12]);
    try testing.expectEqual(@as(Out, null), sceAgcDcbWaitRegMem(&cb, 2, 0, 0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWaitRegMem(&cb, 0, 7, 0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWaitRegMem(&cb, 0, 0, 0, 0, 2, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWaitRegMem(&cb, 0, 0, 0, 0, 1 << 48, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbWaitRegMem(&cb, 0, 0, 0, 0, 0, 0, 0, 0x10_0000));
    try testing.expectEqual(@as(u32, 56), sceAgcWaitOnAddressGetSize(0));
    try testing.expectEqual(@as(u32, 64), sceAgcWaitOnAddressGetSize(1));
    try testing.expectEqual(@as(u32, 0), sceAgcWaitOnAddressGetSize(2));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbEventWrite(&cb, 0x38, 0x1000);
    _ = sceAgcDcbEventWrite(&cb, 7, 0);
    _ = sceAgcDcbEventWrite(&cb, 0x16, 0x1234);
    _ = sceAgcDcbEventWrite(&cb, 16, 0);
    _ = sceAgcAcbEventWrite(&cb, 16, 0);
    _ = sceAgcAcbEventWrite(&cb, 7, 0);
    try expectWords(&cb, &.{ 0xC002_4600, 0x138, 0x1000, 0, 0xC000_4600, 0x407, 0xC000_4600, 0x16, 0xC000_4600, 0x410, 0xC000_4600, 0x10, 0xC000_4600, 0x407 });
    try testing.expectEqual(@as(Out, null), sceAgcDcbEventWrite(&cb, 0x39, 0));
    try testing.expectEqual(@as(Out, null), sceAgcAcbEventWrite(&cb, 0x39, 0x1000));
    try testing.expectEqual(@as(Out, null), sceAgcDcbEventWrite(&cb, 0x40, 0));
    try testing.expectEqual(@as(u32, 16), sceAgcDcbEventWriteGetSize(0x39));
    try testing.expectEqual(@as(u32, 8), sceAgcDcbEventWriteGetSize(7));
}

test "atomics, semaphores, the stand-ins" {
    var mem: [128]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcAcbAtomicMem(&cb, 0x2F, 5, 0x1234_5678_9AB4, 2, 0x1122_3344_5566_7788, 0x99AA_BBCC_DDEE_FF00, 0x1ABC);
    _ = sceAgcDcbAtomicMem(&cb, 3, 0xFF, 0xFF, 0xFF, 0x10, 0, 0, 0xFFFF);
    try expectWords(&cb, &.{
        0xC007_1E00, 0x0400_052F, 0x5678_9AB4, 0x1234, 0x5566_7788, 0x1122_3344, 0xDDEE_FF00, 0x99AA_BBCC, 0x1ABC,
        0xC007_1E00, 0xC600_0F7F, 0x10,        0,      0,           0,           0,           0,           0x1FFF,
    });

    cb = CommandBuffer.over(&mem);
    _ = sceAgcAcbAtomicGds(&cb, 0xFFFF_FFFF, 1, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xABCD, 0xFEDC, 0x1234_5678, 0x8765_4321, 0xFEDC_BA98_7654_3210, 0x0123_4567_89AB_CDEF);
    _ = sceAgcDcbAtomicGds(&cb, 2, 0x2E1, 1, 0, 0, 0, 0, 0, 0, 0, 0);
    // (the unversioned calls clear bit 7 of the control word: 0xFF -> 0x7F)
    try expectWords(&cb, &.{
        0xC009_1D00, 0x0015_007F, 0x13F, 0xABCD, 0xFEDC, 0x0034_0078, 0x8765_4321, 0x7654_3210, 0xFEDC_BA98, 0x89AB_CDEF, 0x0123_4567,
        0xC009_1D00, 0x8015_0061, 0,     0,      0,      0,           0,           0,           0,           0,           0,
    });
    // Bit 17: mode 1 without control bit 5.
    cb = CommandBuffer.over(&mem);
    _ = sceAgcAcbAtomicGds(&cb, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 1 << 17), mem[1]);

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbMemSemaphore(&cb, 0x10_2F22_1D98, 0, 1, 6);
    _ = sceAgcAcbMemSemaphore(&cb, 0x10_2F22_1D98, 1, 0, 7);
    _ = sceAgcCbMemSemaphore(&cb, 0x10_2F22_1D98, 1, 2, 3);
    try expectWords(&cb, &.{
        0xC002_3900, 0x2F22_1D98, 0x10, 0xC010_0000,
        0xC002_3900, 0x2F22_1D98, 0x10, 0xE001_0000,
        0xC002_3900, 0x2F22_1D90, 0x10, 0x8010_0000,
    });
    try testing.expectEqual(@as(Out, null), sceAgcDcbMemSemaphore(&cb, 0x1000, 0, 0, 5));
    try testing.expectEqual(@as(Out, null), sceAgcDcbMemSemaphore(&cb, 0x1004, 0, 0, 6));
    try testing.expectEqual(@as(Out, null), sceAgcDcbMemSemaphore(&cb, 0, 0, 0, 6));
    try testing.expectEqual(@as(Out, null), sceAgcDcbMemSemaphore(&cb, 0x1000, 2, 0, 6));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbPrimeUtcl2(&cb, 0x1122_3344_0000, 0x34_5000);
    _ = sceAgcDcbGetLodStats(&cb, 3, 0x1000, 0x40, 0xFF, 1, 0, 0xFF);
    try expectWords(&cb, &.{ 0xC003_1000, 0, 0x3344_0000, 0x1122, 0x34_5000, 0xC003_1000, 0x40, 0x1000, 0, 0x3007_FFFC });
    try expectOps(&cb, &.{ 0x100, 0x100 });
    try testing.expectEqual(@as(Out, null), sceAgcDcbGetLodStats(&cb, 4, 0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbGetLodStats(&cb, 0, 0x1020, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbGetLodStats(&cb, 0, 0, 0, 0x100, 0, 0, 0));
}

test "the flip, the rendering wait, markers, workloads" {
    var mem: [128]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbSetFlip(&cb, 0xFEDC_BA98, -2, 0x1234_5678, -0x1234_5678_9ABC_DEF);
    _ = sceAgcAcbWaitUntilSafeForRendering(&cb, 7, 2);
    try expectWords(&cb, &.{ 0xC004_105C, 0xFEDC_BA98, 0xFFFF_FFFE, 0x1234_5678, 0x7654_3211, 0xFEDC_BA98, 0xC002_1018, 7, 2, 0 });
    // What pm4.Writer writes, word for word.
    var mine: [6]u32 = undefined;
    var w = pm4.Writer{ .words = &mine };
    _ = w.flip(0xFEDC_BA98, -2, 0x1234_5678, -0x1234_5678_9ABC_DEF);
    try testing.expectEqualSlices(u32, &mine, mem[0..6]);

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbPushMarker(&cb, "frame", 0xFF00_00FF);
    _ = sceAgcDcbPopMarker(&cb);
    _ = sceAgcDcbPushMarker(&cb, null, 0);
    _ = sceAgcDcbSetMarkerSpan(&cb, "abcdXYZ", 4, 0);
    try expectWords(&cb, &.{ 0xC001_102C, 0x6D61_7266, 0x65, 0xC000_1030, 0, 0xC000_102C, 0, 0xC001_102C, 0x6463_6261, 0, 0xC000_1030, 0 });
    try expectOps(&cb, &.{ nopOp(SUB.PUSH_MARKER), nopOp(SUB.POP_MARKER), nopOp(SUB.PUSH_MARKER), nopOp(SUB.PUSH_MARKER), nopOp(SUB.POP_MARKER) });
    try testing.expectEqual(@as(Out, null), sceAgcDcbPushMarkerSpan(&cb, null, 1, 0));
    // The longest text, and one byte more.
    var long: [MARKER_MOST + 2]u8 = undefined;
    @memset(&long, 'a');
    var big: [0x4010]u32 = undefined;
    cb = CommandBuffer.over(&big);
    try testing.expect(sceAgcDcbPushMarkerSpan(&cb, &long, MARKER_MOST, 0) != null);
    try testing.expectEqual(@as(usize, 0x4000), cb.written().len);
    try testing.expectEqual(@as(Out, null), sceAgcDcbPushMarkerSpan(&cb, &long, MARKER_MOST + 1, 0));
    long[MARKER_MOST + 1] = 0;
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetMarker(&cb, @ptrCast(&long), 0));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbSetWorkloadsActive(&cb, 1, &[_]u32{ 3, 4 }, 2);
    _ = sceAgcDcbSetWorkloadComplete(&cb, 1, 33);
    _ = sceAgcDcbSetWorkloadStreamInactive(&cb, 1);
    try testing.expectEqual(@as(usize, 18 + 12 + 9), cb.written().len);
    try testing.expectEqualSlices(u32, &.{ 0xC010_1000, 1, 0x18, 0 }, mem[0..4]);
    try testing.expectEqualSlices(u32, &.{ 0xC00A_1000, 1, 33, 0xFFFF_FFFF, 0xFFFF_FFFD }, mem[18..23]);
    try testing.expectEqualSlices(u32, &.{ 0xC007_1000, 1 }, mem[30..32]);
    for (mem[4..18]) |x| try testing.expectEqual(@as(u32, 0), x);
    try expectOps(&cb, &.{ 0x100, 0x100, 0x100 });
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetWorkloadsActive(&cb, 1, &[_]u32{ 3, 3 }, 2));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetWorkloadsActive(&cb, 1, &[_]u32{64}, 1));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetWorkloadsActive(&cb, 1, null, 1));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetWorkloadsActive(&cb, 1, &[_]u32{1}, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetWorkloadComplete(&cb, 1, 64));
}
