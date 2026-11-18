//! @zpm/ps5 agc_draw — libSceAgc's draws, their index and instance state,
//! and dispatches (agc.sig has the library's table). Allocation-free.

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

// ── Draws ───────────────────────────────────────────────────────────────────
//
// A draw's 64-bit `modifier` (its top 31 bits must be 0): bit 0, 2, 3 ask
// for the first vertex, the first instance, the draw's number to be put in
// a shader's user register (which one: bits 9, 19, 24 on, five bits each,
// from the stage's first; the stage is bits 31..29); bit 4 user vertex
// registers; bit 8 fuse draws; bit 32 "the default" (no fusing).

/// What a draw packet's last word says when no register is asked for.
const NO_REGISTER: u32 = 0x280;

/// A draw's initiator word: fusing (unless "the default"), and whether
/// the indices are made up (no index buffer).
fn initiator(modifier: u64, indexed: bool) u32 {
    const fuse: u32 = if (modifier & (1 << 32) != 0) 0 else lo32(modifier >> 3) & 0x20;
    return fuse | @as(u32, if (indexed) 0 else 2);
}

/// The user register a modifier names for a value, or NO_REGISTER.
fn userRegister(modifier: u64, enable: u64, shift: u6) u32 {
    if (modifier & enable == 0) return NO_REGISTER;
    const stage = lo32(modifier) >> 29;
    const first: u32 = if (stage == 3 or stage == 5) 0x10C else 0x8C;
    return first + (lo32(modifier >> shift) & 0x1F);
}
fn vertexRegister(modifier: u64) u32 {
    return userRegister(modifier, 1, 9);
}
fn instanceRegister(modifier: u64) u32 {
    return userRegister(modifier, 4, 19);
}
fn drawRegister(modifier: u64) u32 {
    return userRegister(modifier, 8, 24);
}

fn badModifier(modifier: u64) bool {
    return modifier >> 33 != 0;
}

pub fn sceAgcDcbDrawIndex(buf: Buf, count: u32, indices: u64, modifier: u64) callconv(.c) Out {
    if (indices == 0 or badModifier(modifier)) return null;
    return put(buf, &.{ header(OP.DRAW_INDEX_2, 6, 0), count, lo32(indices), hi32(indices), count, initiator(modifier, true) });
}

pub fn sceAgcDcbDrawIndexAuto(buf: Buf, count: u32, modifier: u64) callconv(.c) Out {
    if (badModifier(modifier)) return null;
    return put(buf, &.{ header(OP.DRAW_INDEX_AUTO, 3, 0), count, initiator(modifier, false) });
}

/// Indices from the index buffer (sceAgcDcbSetIndexBuffer), from the
/// `first`th.
pub fn sceAgcDcbDrawIndexOffset(buf: Buf, first: u32, count: u32, modifier: u64) callconv(.c) Out {
    if (badModifier(modifier)) return null;
    return put(buf, &.{ header(OP.DRAW_INDEX_OFFSET_2, 5, 0), @max(count, 1), first, count, initiator(modifier, true) });
}

/// A draw whose counts are in memory, `offset` bytes past the base
/// sceAgcDcbSetBaseIndirectArgs set.
fn drawIndirect(buf: Buf, op: u8, offset: u32, modifier: u64, indexed: bool) Out {
    if (offset & 3 != 0 or badModifier(modifier)) return null;
    return put(buf, &.{ header(op, 5, 0), offset, vertexRegister(modifier), instanceRegister(modifier), initiator(modifier, indexed) });
}
pub fn sceAgcDcbDrawIndexIndirect(buf: Buf, offset: u32, modifier: u64) callconv(.c) Out {
    return drawIndirect(buf, OP.DRAW_INDEX_INDIRECT, offset, modifier, true);
}
pub fn sceAgcDcbDrawIndirect(buf: Buf, offset: u32, modifier: u64) callconv(.c) Out {
    return drawIndirect(buf, OP.DRAW_INDIRECT, offset, modifier, false);
}

/// Several draws' records in memory, `stride` bytes apart; how many: the
/// count itself, or (`from_memory` 1) the most, with the count read from
/// `count_at`. An odd `from_memory` other than 1 is refused (what a console
/// does with it is not known).
fn drawMulti(buf: Buf, op: u8, tag: u32, offset: u32, from_memory: u32, count: u32, count_at: u64, stride: u32, modifier: u64, indexed: bool) Out {
    if (badModifier(modifier)) return null;
    if (from_memory & 1 != 0 and from_memory != 1) return null;
    if (from_memory == 1 and (count_at == 0 or count_at & 3 != 0)) return null;
    const m = lo32(modifier);
    const control = drawRegister(modifier) | ((m & 0x10) << 23) | ((from_memory & 1) << 30) | ((m & 8) << 28);
    return put(buf, &.{
        TAG_HEADER,           pm4.UC_TAG,          tag,
        header(op, 10, 0),    offset,              vertexRegister(modifier),
        instanceRegister(modifier), control,       count,
        lo32(count_at),       hi32(count_at),      stride,
        initiator(modifier, indexed), TAG_HEADER,  pm4.UC_TAG,
        TAG.DRAW_END,
    });
}
pub fn sceAgcDcbDrawIndexIndirectMulti(buf: Buf, offset: u32, from_memory: u32, count: u32, count_at: u64, stride: u32, modifier: u64) callconv(.c) Out {
    return drawMulti(buf, OP.DRAW_INDEX_INDIRECT_MULTI, TAG.DRAW_INDEX_MULTI, offset, from_memory, count, count_at, stride, modifier, true);
}
pub fn sceAgcDcbDrawIndirectMulti(buf: Buf, offset: u32, from_memory: u32, count: u32, count_at: u64, stride: u32, modifier: u64) callconv(.c) Out {
    return drawMulti(buf, OP.DRAW_INDIRECT_MULTI, TAG.DRAW_MULTI, offset, from_memory, count, count_at, stride, modifier, false);
}

/// Instances of indexed objects. Which argument is which is not known for
/// sure (the words' places were measured on a console, the names were
/// not); the driver here does not carry the packet out.
pub fn sceAgcDcbDrawIndexMultiInstanced(buf: Buf, count: u32, indices: u64, objects: u64, instances: u32, modifier: u64) callconv(.c) Out {
    if (badModifier(modifier)) return null;
    return put(buf, &.{
        TAG_HEADER,       pm4.UC_TAG,  TAG.DRAW_MULTI_INSTANCED,
        header(OP.DRAW_INDEX_MULTI_INST, 9, 0), count, lo32(indices),
        hi32(indices),    @max(instances, 1), lo32(objects),
        hi32(objects),    instances,   0x80 | initiator(modifier, true),
        TAG_HEADER,       pm4.UC_TAG,  TAG.DRAW_END,
    });
}

// ── Index and instance state ────────────────────────────────────────────────

/// The user configuration register the index size is in (written with the
/// "index" form of the packet: index 2 in the top bits).
const INDEX_TYPE_SELECT: u32 = 0x2000_0243;

/// `size`: 0, 1 or 2 (16-, 32-, 8-bit as the driver reads it; the sheet
/// does not say). Bit 10 of the value is always set; what it means is not
/// known.
fn indexSize(buf: Buf, size: u8, cache: u8, per_instance: u8) Out {
    if (size > 2 or cache > 3 or per_instance > 1) return null;
    return put(buf, &.{ header(OP.SET_UCONFIG_REG_INDEX, 3, 0), INDEX_TYPE_SELECT, 0x400 | w32(size) | (w32(cache) << 6) | (w32(per_instance) << 14) });
}
pub fn sceAgcDcbSetIndexSize(buf: Buf, size: u8, cache: u8) callconv(.c) Out {
    return indexSize(buf, size, cache, 0);
}

/// 0: no index buffer.
pub fn sceAgcDcbSetIndexBuffer(buf: Buf, indices: u64) callconv(.c) Out {
    if (indices & 1 != 0) return null;
    return put(buf, &.{ header(OP.INDEX_BASE, 3, 0), lo32(indices), hi32(indices) });
}
pub fn sceAgcDcbSetIndexCount(buf: Buf, count: u32) callconv(.c) Out {
    return put(buf, &.{ header(OP.INDEX_BUFFER_SIZE, 2, 0), count });
}
pub fn sceAgcDcbSetNumInstances(buf: Buf, count: u32) callconv(.c) Out {
    return put(buf, &.{ header(OP.NUM_INSTANCES, 2, 0), count });
}

/// The index buffer from a table of 16-byte records (address, count,
/// size), the `index`th. (A console masks the index; the open
/// implementation refuses one above 16 bits, as here.)
pub fn sceAgcDcbSetIndexIndirectArgs(buf: Buf, table: u64, index: u32) callconv(.c) Out {
    if (table & 15 != 0 or index > 0xFFFF) return null;
    return put(buf, &.{ header(OP.INDEX_ATTRIBUTES_INDIRECT, 4, 0), lo32(table), hi32(table), index });
}

/// Where indirect draws' (or, `kind` 1, dispatches') records are. The
/// kind goes into the header's flags as it is, all 32 bits of it.
pub fn sceAgcDcbSetBaseIndirectArgs(buf: Buf, kind: u32, base: u64) callconv(.c) Out {
    if (base & 1 != 0) return null;
    return put(buf, &.{ header(OP.SET_BASE, 4, 0) | (kind << 1), 1, lo32(base) & ~@as(u32, 6), hi32(base) });
}

// ── Dispatch ────────────────────────────────────────────────────────────────

/// The dispatch initiator: bits 0 and 6 always; the caller's from 0xA038
/// (0xA079 for the indirect forms, which refuse others).
const DISPATCH_ON: u32 = 0x41;

pub fn sceAgcCbDispatch(buf: Buf, x: u32, y: u32, z: u32, modifier: u32) callconv(.c) Out {
    return put(buf, &.{ header(OP.DISPATCH_DIRECT, 5, 0), x, y, z, (modifier & 0xA038) | DISPATCH_ON });
}

/// The group counts in memory, `offset` bytes past the dispatch base.
pub fn sceAgcDcbDispatchIndirect(buf: Buf, offset: u32, flags: u32) callconv(.c) Out {
    if (flags & ~@as(u32, 0xA079) != 0) return null;
    return put(buf, &.{ header(OP.DISPATCH_INDIRECT, 3, 0), offset, flags | DISPATCH_ON });
}

pub fn sceAgcAcbDispatchIndirect(buf: Buf, args: u64, modifier: u32) callconv(.c) Out {
    if (args == 0 or args & 3 != 0 or modifier & ~@as(u32, 0xA079) != 0) return null;
    return put(buf, &.{ header(OP.DISPATCH_INDIRECT, 4, 0), lo32(args), hi32(args), modifier | DISPATCH_ON });
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// The words open projects' tests give for these calls.

const testing = std.testing;

fn expectWords(cb: *const CommandBuffer, want: []const u32) !void {
    try testing.expectEqualSlices(u32, want, cb.written());
}

test "draws: the words of each, the registers a modifier names, what is refused" {
    var mem: [64]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbDrawIndexAuto(&cb, 17, 0);
    _ = sceAgcDcbDrawIndexIndirect(&cb, 0x40, 0);
    _ = sceAgcDcbDrawIndirect(&cb, 0x40, 0);
    _ = sceAgcDcbDrawIndexOffset(&cb, 12, 36, 0);
    _ = sceAgcDcbDrawIndex(&cb, 6, 0x1122_3344_5566, 0);
    try expectWords(&cb, &.{
        0xC001_2D00, 17,          2,
        0xC003_2500, 0x40,        0x280,  0x280, 0,
        0xC003_2400, 0x40,        0x280,  0x280, 2,
        0xC003_3500, 36,          12,     36,    0,
        0xC004_2700, 6,           0x3344_5566, 0x1122, 6, 0,
    });
    // Fusing: modifier bit 8, unless bit 32 says "the default".
    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbDrawIndirect(&cb, 0, 0x100);
    _ = sceAgcDcbDrawIndirect(&cb, 0, 0x1_0000_0100);
    try testing.expectEqual(@as(u32, 0x22), mem[4]);
    try testing.expectEqual(@as(u32, 0x2), mem[9]);
    // The first vertex and instance into user registers: slots 3 and 5 of
    // the vertex stage (0x8C on), and of stage 3 (0x10C on).
    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbDrawIndexIndirect(&cb, 0, 1 | 4 | 3 << 9 | 5 << 19);
    _ = sceAgcDcbDrawIndexIndirect(&cb, 0, 1 | 3 << 29);
    try testing.expectEqualSlices(u32, &.{ 0x8F, 0x91 }, mem[2..4]);
    try testing.expectEqualSlices(u32, &.{ 0x10C, 0x280 }, mem[7..9]);
    // A modifier past 33 bits, an index address of 0, an offset not in
    // words: nothing.
    try testing.expectEqual(@as(Out, null), sceAgcDcbDrawIndexAuto(&cb, 3, 1 << 33));
    try testing.expectEqual(@as(Out, null), sceAgcDcbDrawIndex(&cb, 3, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbDrawIndirect(&cb, 2, 0));
    try testing.expectEqual(@as(usize, 10), cb.written().len);
    // An offset draw of nothing still says one index at most.
    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbDrawIndexOffset(&cb, 0, 0, 0);
    try testing.expectEqual(@as(u32, 1), mem[1]);
}

test "draws of several records, bracketed by tags" {
    var mem: [64]u32 = undefined;
    var count: u32 align(4) = 0;
    const ca = @intFromPtr(&count);
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbDrawIndexIndirectMulti(&cb, 0x80, 1, 8, ca, 20, 0);
    try expectWords(&cb, &.{ 0xC001_7904, 0x342, 0xC600_0005, 0xC008_3800, 0x80, 0x280, 0x280, 0x4000_0280, 8, lo32(ca), hi32(ca), 0x14, 0, 0xC001_7904, 0x342, 0xC600_0000 });
    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbDrawIndirectMulti(&cb, 0x40, 0, 5, 0, 16, 0);
    try expectWords(&cb, &.{ 0xC001_7904, 0x342, 0xC600_0008, 0xC008_2C00, 0x40, 0x280, 0x280, 0x280, 5, 0, 0, 0x10, 2, 0xC001_7904, 0x342, 0xC600_0000 });
    cb = CommandBuffer.over(&mem);
    const ia: u64 = 0x1234_5678_9AB0;
    const oa: u64 = 0x0FED_CBA9_8760;
    _ = sceAgcDcbDrawIndexMultiInstanced(&cb, 100, ia, oa, 3, 0);
    try expectWords(&cb, &.{ 0xC001_7904, 0x342, 0xC600_0006, 0xC007_3A00, 100, lo32(ia), hi32(ia), 3, lo32(oa), hi32(oa), 3, 0x80, 0xC001_7904, 0x342, 0xC600_0000 });
    // The count read from memory needs an address; an odd selector other
    // than 1 is refused. The draw-index register and user registers go
    // into the control word.
    try testing.expectEqual(@as(Out, null), sceAgcDcbDrawIndirectMulti(&cb, 0, 1, 5, 0, 16, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbDrawIndirectMulti(&cb, 0, 3, 5, ca, 16, 0));
    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbDrawIndirectMulti(&cb, 0, 2, 5, 0, 16, 8 | 0x10 | 7 << 24);
    try testing.expectEqual(@as(u32, 0x8000_0000 | 0x0800_0000 | 0x93), mem[7]);
    try testing.expectEqual(@as(usize, 16), cb.written().len);

    // Read back: the draw packet between its tags.
    var r = pm4.Reader{ .words = cb.written() };
    try testing.expectEqual(@as(u8, OP.SET_UCONFIG_REG), (try r.next()).?.op());
    try testing.expectEqual(@as(u8, OP.DRAW_INDIRECT_MULTI), (try r.next()).?.op());
    try testing.expectEqual(@as(u8, OP.SET_UCONFIG_REG), (try r.next()).?.op());
    try testing.expectEqual(@as(?pm4.Packet, null), try r.next());
}

test "index and instance state" {
    var mem: [64]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbSetIndexSize(&cb, 1, 2);
    _ = indexSize(&cb, 2, 3, 1);
    _ = sceAgcDcbSetNumInstances(&cb, 3);
    _ = sceAgcDcbSetIndexCount(&cb, 9);
    _ = sceAgcDcbSetIndexBuffer(&cb, 0x1234_5678_9AB2);
    _ = sceAgcDcbSetIndexIndirectArgs(&cb, 0x1111_1111_2222_2220, 0x4444);
    try expectWords(&cb, &.{
        0xC001_7A00, 0x2000_0243, 0x481,
        0xC001_7A00, 0x2000_0243, 0x44C2,
        0xC000_2F00, 3,
        0xC000_1300, 9,
        0xC001_2600, 0x5678_9AB2, 0x1234,
        0xC002_9100, 0x2222_2220, 0x1111_1111, 0x4444,
    });
    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbSetBaseIndirectArgs(&cb, 0x1111_1111, 0x2222_2222);
    _ = sceAgcDcbSetBaseIndirectArgs(&cb, 0x2222_2222, 0x3333_3333_4444_4444);
    try expectWords(&cb, &.{ 0xE222_3322, 1, 0x2222_2220, 0, 0xC446_5544, 1, 0x4444_4440, 0x3333_3333 });
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetIndexSize(&cb, 3, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetIndexSize(&cb, 0, 4));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetIndexBuffer(&cb, 1));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetIndexIndirectArgs(&cb, 8, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetIndexIndirectArgs(&cb, 0, 0x10000));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetBaseIndirectArgs(&cb, 0, 3));
    try testing.expectEqual(@as(usize, 8), cb.written().len);
}

test "dispatches" {
    var mem: [32]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcCbDispatch(&cb, 7, 3, 1, 0x8000);
    _ = sceAgcCbDispatch(&cb, 1, 1, 1, 0xFFFF_FFFF);
    _ = sceAgcDcbDispatchIndirect(&cb, 0x40, 8);
    _ = sceAgcAcbDispatchIndirect(&cb, 0x1234_5678_9ABC, 0x2000);
    try expectWords(&cb, &.{
        0xC003_1500, 7,           3,      1, 0x8041,
        0xC003_1500, 1,           1,      1, 0xA079,
        0xC001_1600, 0x40,        0x49,
        0xC002_1600, 0x5678_9ABC, 0x1234, 0x2041,
    });
    try testing.expectEqual(@as(Out, null), sceAgcDcbDispatchIndirect(&cb, 0, 0x4));
    try testing.expectEqual(@as(Out, null), sceAgcAcbDispatchIndirect(&cb, 0, 0));
    try testing.expectEqual(@as(Out, null), sceAgcAcbDispatchIndirect(&cb, 2, 0));
}
