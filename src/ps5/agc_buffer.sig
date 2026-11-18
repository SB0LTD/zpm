//! @zpm/ps5 agc_buffer — libSceAgc's command buffer: its structure, the
//! room in it, and the writers every other part uses; NOPs and register
//! packets (agc.sig has the library's table). Allocation-free.

const std = @import("std");
const pm4 = @import("pm4.sig");
const pthread = @import("pthread.sig");

const OP = pm4.OP;
const header = pm4.header;

// ── Numbers and structures ──────────────────────────────────────────────────

pub const ERROR = struct {
    pub const ALIGNMENT: i32 = @bitCast(@as(u32, 0x8A6C_0002));
    pub const OUT_OF_RANGE: i32 = @bitCast(@as(u32, 0x8A6C_000B));
    /// A patch call given a packet of another kind.
    pub const WRONG_PACKET: i32 = @bitCast(@as(u32, 0x8A6C_000C));
    pub const SEMAPHORE_REGISTERED: i32 = @bitCast(@as(u32, 0x8A6C_0048));
    pub const NO_SEMAPHORE: i32 = @bitCast(@as(u32, 0x8A6C_0049));
    /// A bad argument to a call that returns a code. What a console answers
    /// is not known (the open implementation throws): the code for a value
    /// out of range.
    pub const INVALID: i32 = OUT_OF_RANGE;
};

/// Called when a buffer has no room: `words` is what the call needs (and
/// the words kept free at the top). True: there is room now.
pub const Grow = *const fn (buffer: *CommandBuffer, words: u32, user: ?*anyopaque) callconv(.c) bool;

/// A command buffer as a game holds it. Packets go up from `cursor_up`,
/// to `cursor_down` (or `top`, when that is 0), less `reserved` words.
/// The four are addresses (a game's: checked before they are used).
pub const CommandBuffer = extern struct {
    bottom: usize = 0,
    top: usize = 0,
    cursor_up: usize = 0,
    /// (0 is taken as `top`: what a console does then is not known)
    cursor_down: usize = 0,
    grow: ?Grow = null,
    user: ?*anyopaque = null,
    reserved: u32 = 0,

    /// A buffer over words the caller owns, empty.
    pub fn over(words: []u32) CommandBuffer {
        const b = @intFromPtr(words.ptr);
        return .{ .bottom = b, .top = b + 4 * words.len, .cursor_up = b, .cursor_down = b + 4 * words.len };
    }

    /// What has been written so far (nothing, when the buffer is not one).
    pub fn written(cb: *const CommandBuffer) []u32 {
        _ = room(cb) orelse return &.{};
        const b: [*]u32 = @ptrFromInt(cb.bottom);
        return b[0 .. (cb.cursor_up - cb.bottom) / 4];
    }
};

/// One register and its value, as a game lists them.
pub const ShaderRegister = extern struct { offset: u32, value: u32 };

/// A piece of memory: where, and how many bytes.
pub const MemoryRange = extern struct { base: ?*anyopaque, size: u64 };

pub const Buf = ?*CommandBuffer;
pub const Out = ?[*]u32;

pub fn lo32(x: u64) u32 {
    return @truncate(x);
}
pub fn hi32(x: u64) u32 {
    return @truncate(x >> 32);
}
pub fn w32(x: anytype) u32 {
    return @as(u32, x);
}

// ── Room in a buffer ────────────────────────────────────────────────────────

/// Free words, or null when the buffer's pointers are not a buffer's
/// (unaligned, out of order, missing).
pub fn room(cb: *const CommandBuffer) ?usize {
    const bottom = cb.bottom;
    const top = cb.top;
    const up = cb.cursor_up;
    const limit = if (cb.cursor_down != 0) cb.cursor_down else top;
    if (bottom == 0 or (bottom | top | up | limit) & 3 != 0) return null;
    if (bottom > up or up > limit or limit > top) return null;
    return ((limit - up) / 4) -| cb.reserved;
}

/// The cursor as a pointer (a buffer `room` has checked).
pub fn cursor(cb: *const CommandBuffer) [*]u32 {
    return @ptrFromInt(cb.cursor_up);
}

/// `n` words at the cursor, the cursor moved past them; null (and nothing
/// moved) when there is no room, even after asking for more.
pub fn reserve(buf: Buf, n: usize) ?[]u32 {
    const cb = buf orelse return null;
    if (n == 0 or n > pm4.MAX_WORDS * 4) return null;
    var free = room(cb) orelse return null;
    if (free < n) {
        const more = cb.grow orelse return null;
        if (!more(cb, @as(u32, @intCast(n)) +| cb.reserved, cb.user)) return null;
        free = room(cb) orelse return null;
        if (free < n) return null;
    }
    const at = cursor(cb);
    cb.cursor_up += 4 * n;
    return at[0..n];
}

// A builder that copies from memory the game points at has two things to
// mind, for that memory may be in the command buffer itself (a game may
// stage data just past the cursor):
//   - the packet's own words may lie over the data: the copy is made as a
//     move, and before the header is written;
//   - when the buffer has no room and the game's callback brings another,
//     the data may go with the old one: it is put aside first.

/// Where data is kept while a buffer is changed for a bigger one (one
/// packet's worth; one builder at a time).
const aside = struct {
    var lock: pthread.Lock = .{};
    var bytes: [pm4.MAX_WORDS * 4]u8 align(8) = undefined;
};

fn overlaps(a: usize, a_len: usize, b: usize, b_len: usize) bool {
    return a < b +| b_len and b < a +| a_len;
}

/// Room for a packet that copies the game's memory, and where to copy
/// from now. `release` it after the copy.
pub const Space = struct {
    out: []u32,
    from: [*]const u8,
    held: bool,

    pub fn release(s: Space) void {
        if (s.held) aside.lock.unlock();
    }
};

/// `n` words at the cursor for a packet that copies `bytes` of the game's
/// memory at `from`. `reordered`: the packet does not hold the data as it
/// lies (a list turned into packets), so it cannot be copied over itself.
/// Null, and nothing moved: no room, or data in the way that is too much
/// to put aside.
pub fn reserveFor(buf: Buf, n: usize, from: [*]const u8, bytes: usize, reordered: bool) ?Space {
    const cb = buf orelse return null;
    const free = room(cb) orelse return null;
    const at = @intFromPtr(from);
    const in_buffer = overlaps(at, bytes, cb.bottom, cb.top - cb.bottom);
    const under_packet = overlaps(at, bytes, cb.cursor_up, 4 * n);
    if (!((free < n and in_buffer) or (reordered and under_packet))) {
        const out = reserve(cb, n) orelse return null;
        return .{ .out = out, .from = from, .held = false };
    }
    if (bytes > aside.bytes.len) return null;
    aside.lock.lock();
    @memcpy(aside.bytes[0..bytes], from[0..bytes]);
    const out = reserve(cb, n) orelse {
        aside.lock.unlock();
        return null;
    };
    return .{ .out = out, .from = &aside.bytes, .held = true };
}

/// Bytes to a place that may overlap where they are.
pub fn move(to: [*]u8, from: [*]const u8, n: usize) void {
    if (@intFromPtr(to) <= @intFromPtr(from)) {
        std.mem.copyForwards(u8, to[0..n], from[0..n]);
    } else {
        std.mem.copyBackwards(u8, to[0..n], from[0..n]);
    }
}

/// Words as they are, at the cursor.
pub fn put(buf: Buf, words: []const u32) Out {
    const out = reserve(buf, words.len) orelse return null;
    @memcpy(out, words);
    return out.ptr;
}

/// A NOP over all of `out` (one word: the filler).
pub fn fillNop(out: []u32) void {
    var o = out;
    // (as many NOPs as it takes: one may be a word short of the most a
    // packet has, for a NOP of the most words would have the filler's
    // header)
    while (o.len != 0) {
        // (exactly the most words: the filler goes first)
        const n: usize = if (o.len == pm4.MAX_WORDS) 1 else @min(o.len, pm4.MAX_WORDS - 1);
        if (n == 1) {
            o[0] = pm4.FILLER;
        } else {
            o[0] = header(OP.NOP, @intCast(n), 0);
            @memset(o[1..n], 0);
        }
        o = o[n..];
    }
}

// ── NOPs ────────────────────────────────────────────────────────────────────

/// A NOP of `words` words, header and all (1 to 0x4001).
pub fn nopOf(buf: Buf, words: u32) Out {
    if (words == 0 or words > pm4.MAX_WORDS) return null;
    const out = reserve(buf, words) orelse return null;
    fillNop(out);
    return out.ptr;
}

// (The sheet gives sceAgcSetNop a command buffer, as sceAgcCbNop; it is
// with the patch calls in the open implementation, so it may take a packet
// pointer on a console. Not known.)
pub fn sceAgcSetNop(buf: Buf, words: u32) callconv(.c) Out {
    return nopOf(buf, words);
}
pub fn sceAgcCbNop(buf: Buf, words: u32) callconv(.c) Out {
    return nopOf(buf, words);
}
pub fn sceAgcCbNopGetSize(words: u32) callconv(.c) u32 {
    return words *% 4;
}

// ── Registers ───────────────────────────────────────────────────────────────
//
// A register is named by its number within its bank (pm4.Bank), never by
// its absolute number. The config bank's packet (0x68) is written as asked;
// the driver here does not carry it out.

/// `n` registers in a row from `first`, the values from `values` (any byte
/// address). Null `values`: the packet's words are reserved, the values
/// left for the game to write.
fn direct(buf: Buf, op: u8, first: u32, values: ?[*]align(1) const u32, n: u32) Out {
    if (first > 0xFFFF or n == 0 or n > 0x3FFF or first + n > 0x10000) return null;
    const v = values orelse {
        const out = reserve(buf, n + 2) orelse return null;
        out[0] = header(op, n + 2, 0);
        out[1] = first;
        return out.ptr;
    };
    const s = reserveFor(buf, n + 2, @ptrCast(v), 4 * @as(usize, n), false) orelse return null;
    move(@ptrCast(s.out[2..].ptr), s.from, 4 * @as(usize, n));
    s.release();
    s.out[0] = header(op, n + 2, 0);
    s.out[1] = first;
    return s.out.ptr;
}

fn one(buf: Buf, op: u8, reg: ShaderRegister) Out {
    const v = [1]u32{reg.value};
    return direct(buf, op, reg.offset, &v, 1);
}

pub fn sceAgcDcbSetCxRegisterDirect(buf: Buf, reg: ShaderRegister) callconv(.c) Out {
    return one(buf, OP.SET_CONTEXT_REG, reg);
}
pub fn sceAgcDcbSetShRegisterDirect(buf: Buf, reg: ShaderRegister) callconv(.c) Out {
    return one(buf, OP.SET_SH_REG, reg);
}
pub fn sceAgcDcbSetUcRegisterDirect(buf: Buf, reg: ShaderRegister) callconv(.c) Out {
    return one(buf, OP.SET_UCONFIG_REG, reg);
}
pub fn sceAgcDcbSetCfRegisterDirect(buf: Buf, reg: ShaderRegister) callconv(.c) Out {
    return one(buf, OP.SET_CONFIG_REG, reg);
}
pub fn sceAgcDcbSetCfRegisterRangeDirect(buf: Buf, first: u32, values: ?[*]align(1) const u32, n: u32) callconv(.c) Out {
    return direct(buf, OP.SET_CONFIG_REG, first, values, n);
}
pub fn sceAgcCbSetShRegisterRangeDirect(buf: Buf, first: u32, values: ?[*]align(1) const u32, n: u32) callconv(.c) Out {
    return direct(buf, OP.SET_SH_REG, first, values, n);
}
pub fn sceAgcCbSetUcRegisterRangeDirect(buf: Buf, first: u32, values: ?[*]align(1) const u32, n: u32) callconv(.c) Out {
    return direct(buf, OP.SET_UCONFIG_REG, first, values, n);
}

/// How many registers from `i` on are in a row (one packet's worth).
fn runOf(regs: [*]align(1) const ShaderRegister, i: usize, n: usize) usize {
    var len: usize = 1;
    while (i + len < n and len < 0x3FFF and @as(u64, regs[i + len].offset) == @as(u64, regs[i].offset) + len) len += 1;
    return len;
}

/// A list of registers (any byte address, any order): a packet for each
/// run of them in a row. None: nothing written, the cursor returned.
fn listed(buf: Buf, op: u8, regs: ?[*]align(1) const ShaderRegister, n: u32) Out {
    const cb = buf orelse return null;
    if (n == 0) return if (room(cb) != null) cursor(cb) else null;
    const given = regs orelse return null;
    var r = given;
    var total: usize = 0;
    var i: usize = 0;
    while (i < n) {
        const run = runOf(r, i, n);
        if (r[i].offset > 0xFFFF or r[i].offset + run > 0x10000) return null;
        total += run + 2;
        i += run;
    }
    // (a list in the buffer, where its own packets would be written over
    // it, is read from a copy)
    const s = reserveFor(cb, total, @ptrCast(given), 8 * @as(usize, n), true) orelse return null;
    defer s.release();
    r = @ptrCast(s.from);
    const out = s.out;
    var at: usize = 0;
    i = 0;
    while (i < n) {
        const run = runOf(r, i, n);
        // (a list the game changes meanwhile cannot take this past the
        // words reserved: what is left is filled with NOPs)
        if (run + 2 > out.len - at) break;
        out[at] = header(op, @intCast(run + 2), 0);
        out[at + 1] = r[i].offset;
        for (0..run) |k| out[at + 2 + k] = r[i + k].value;
        at += run + 2;
        i += run;
    }
    fillNop(out[at..]);
    return out.ptr;
}

pub fn sceAgcCbSetShRegistersDirect(buf: Buf, regs: ?[*]align(1) const ShaderRegister, n: u32) callconv(.c) Out {
    return listed(buf, OP.SET_SH_REG, regs, n);
}
pub fn sceAgcCbSetUcRegistersDirect(buf: Buf, regs: ?[*]align(1) const ShaderRegister, n: u32) callconv(.c) Out {
    return listed(buf, OP.SET_UCONFIG_REG, regs, n);
}

/// A packet that has the GPU read the registers from the game's list of
/// pairs (the list is not copied). A null list goes only with none: a
/// packet to patch later.
fn indirect(buf: Buf, op: u8, regs: u64, n: u32) Out {
    if (n > 0x3FFF or regs & 3 != 0 or (regs == 0 and n != 0)) return null;
    return put(buf, &.{ header(op, 5, 0), lo32(regs), hi32(regs), PAIRS, n });
}

/// The third word of an indirect register packet: the list holds pairs.
pub const PAIRS: u32 = 0x8000_0000;

pub fn sceAgcDcbSetCxRegistersIndirect(buf: Buf, regs: u64, n: u32) callconv(.c) Out {
    return indirect(buf, OP.SET_CONTEXT_REG_INDIRECT, regs, n);
}
pub fn sceAgcDcbSetShRegistersIndirect(buf: Buf, regs: u64, n: u32) callconv(.c) Out {
    return indirect(buf, OP.SET_SH_REG_INDIRECT, regs, n);
}
pub fn sceAgcDcbSetUcRegistersIndirect(buf: Buf, regs: u64, n: u32) callconv(.c) Out {
    return indirect(buf, OP.SET_UCONFIG_REG_INDIRECT, regs, n);
}

pub fn sceAgcCbSetRegisterRangeDirectGetSize(n: u32) callconv(.c) u32 {
    return (n +% 2) *% 4;
}
/// (an upper bound: registers in a row share a packet)
pub fn sceAgcCbSetRegistersDirectGetSize(n: u32) callconv(.c) u32 {
    return if (n > 0x1555_5555) 0 else n * 12;
}

// ── Tags ────────────────────────────────────────────────────────────────────

/// The tag packet the multi-draws are bracketed by (to the user
/// configuration register pm4.UC_TAG, from a draw queue).
pub const TAG_HEADER: u32 = 0xC001_7904;
pub const TAG = struct {
    pub const DRAW_INDEX_MULTI: u32 = 0xC600_0005;
    pub const DRAW_MULTI_INSTANCED: u32 = 0xC600_0006;
    pub const DRAW_MULTI: u32 = 0xC600_0008;
    pub const DRAW_END: u32 = 0xC600_0000;
    /// The wait brackets: what is waited on, its address's bits 47..32 in
    /// the low half.
    pub const WAIT_32: u32 = 0xC801_0000;
    pub const WAIT_64: u32 = 0xC802_0000;
    pub const WAIT_END: u32 = 0xC800_0000;
};

// ── Tests ───────────────────────────────────────────────────────────────────
//
// With no kernel under them: the buffers are the test's own memory, and
// the words written are compared with the ones open projects' tests give.

const testing = std.testing;

fn expectWords(cb: *const CommandBuffer, want: []const u32) !void {
    try testing.expectEqualSlices(u32, want, cb.written());
}

test "a command buffer: room, the reserve at its top, a callback for more, nothing written when full" {
    try testing.expectEqual(@as(usize, 0x38), @sizeOf(CommandBuffer));
    try testing.expectEqual(@as(usize, 0x20), @offsetOf(CommandBuffer, "grow"));
    try testing.expectEqual(@as(usize, 0x30), @offsetOf(CommandBuffer, "reserved"));

    var mem: [6]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    cb.reserved = 1;
    try testing.expectEqual(@as(Out, &mem), sceAgcCbNop(&cb, 3));
    // Three words left, one of them kept: a three-word NOP does not fit.
    try testing.expectEqual(@as(Out, null), sceAgcCbNop(&cb, 3));
    try testing.expectEqual(@as(usize, 3), cb.written().len);
    try testing.expectEqual(@as(Out, mem[3..].ptr), sceAgcCbNop(&cb, 1));
    // A null cursor_down: the limit is the top.
    cb.cursor_down = 0;
    cb.reserved = 0;
    try testing.expect(sceAgcCbNop(&cb, 2) != null);
    try testing.expectEqual(@as(Out, null), sceAgcCbNop(&cb, 1));
    // No buffer, or pointers that are not a buffer's.
    try testing.expectEqual(@as(Out, null), sceAgcCbNop(null, 1));
    var bad = CommandBuffer.over(&mem);
    bad.cursor_up = @intFromPtr(&mem) + 2;
    try testing.expectEqual(@as(Out, null), sceAgcCbNop(&bad, 1));
    bad = CommandBuffer.over(&mem);
    bad.cursor_down = @intFromPtr(&mem[1]);
    bad.cursor_up = @intFromPtr(&mem[2]);
    try testing.expectEqual(@as(Out, null), sceAgcCbNop(&bad, 1));

    // A buffer that grows: the callback moves it to more memory.
    const More = struct {
        var big: [16]u32 = undefined;
        var asked: u32 = 0;
        fn grow(b: *CommandBuffer, words: u32, user: ?*anyopaque) callconv(.c) bool {
            asked = words;
            if (user == null) return false;
            b.* = CommandBuffer.over(&big);
            b.grow = grow;
            b.user = user;
            return true;
        }
    };
    var small: [2]u32 = undefined;
    var g = CommandBuffer.over(&small);
    g.grow = More.grow;
    g.user = &small;
    try testing.expectEqual(@as(Out, &More.big), sceAgcCbNop(&g, 4));
    try testing.expectEqual(@as(u32, 4), More.asked);
    // A callback that says no: nothing written.
    var h = CommandBuffer.over(&small);
    h.grow = More.grow;
    try testing.expectEqual(@as(Out, null), sceAgcCbNop(&h, 3));
    try testing.expectEqual(@as(usize, 0), h.written().len);
}

test "NOPs: one word, two, three, the longest" {
    var mem: [pm4.MAX_WORDS + 8]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcSetNop(&cb, 1);
    _ = sceAgcSetNop(&cb, 2);
    _ = sceAgcCbNop(&cb, 3);
    try expectWords(&cb, &.{ 0xFFFF_1000, 0xC000_1000, 0, 0xC001_1000, 0, 0 });
    try testing.expectEqual(@as(Out, null), sceAgcSetNop(&cb, 0));
    try testing.expectEqual(@as(Out, null), sceAgcSetNop(&cb, pm4.MAX_WORDS + 1));
    // The longest reads back as a filler and a NOP: one packet's room.
    cb = CommandBuffer.over(&mem);
    _ = sceAgcSetNop(&cb, pm4.MAX_WORDS);
    try testing.expectEqual(@as(usize, pm4.MAX_WORDS), cb.written().len);
    var r = pm4.Reader{ .words = cb.written() };
    const p = (try r.next()).?;
    try testing.expectEqual(@as(usize, 1), p.at);
    try testing.expectEqual(@as(?pm4.Packet, null), try r.next());
    try testing.expectEqual(@as(u32, 12), sceAgcCbNopGetSize(3));
}

test "registers: one, a range, a list in runs, the indirect forms" {
    var mem: [64]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbSetCxRegisterDirect(&cb, .{ .offset = 0x80, .value = 1 });
    _ = sceAgcDcbSetShRegisterDirect(&cb, .{ .offset = 0x8C, .value = 2 });
    _ = sceAgcDcbSetUcRegisterDirect(&cb, .{ .offset = 0x242, .value = 3 });
    _ = sceAgcDcbSetCfRegisterDirect(&cb, .{ .offset = 0x10, .value = 4 });
    try expectWords(&cb, &.{ 0xC001_6900, 0x80, 1, 0xC001_7600, 0x8C, 2, 0xC001_7900, 0x242, 3, 0xC001_6800, 0x10, 4 });

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbSetCfRegisterRangeDirect(&cb, 0x100, &[_]u32{ 1, 2, 3 }, 3);
    try expectWords(&cb, &.{ 0xC003_6800, 0x100, 1, 2, 3 });
    // A null list reserves the values' words and leaves them.
    mem[7] = 0x5555;
    const at = sceAgcCbSetUcRegisterRangeDirect(&cb, 0x10, null, 2).?;
    try testing.expectEqual(@as(u32, 0xC002_7900), at[0]);
    try testing.expectEqual(@as(u32, 0x5555), mem[7]);
    // Out of the bank's numbering, none, too many: nothing.
    try testing.expectEqual(@as(Out, null), sceAgcCbSetShRegisterRangeDirect(&cb, 0x10000, &[_]u32{1}, 1));
    try testing.expectEqual(@as(Out, null), sceAgcCbSetShRegisterRangeDirect(&cb, 0xFFFF, &[_]u32{ 1, 2 }, 2));
    try testing.expectEqual(@as(Out, null), sceAgcCbSetShRegisterRangeDirect(&cb, 0, &[_]u32{1}, 0));

    // A list: a packet for each run in a row; any byte address.
    cb = CommandBuffer.over(&mem);
    var raw: [3 * 8 + 1]u8 align(4) = undefined;
    const regs = [_]ShaderRegister{ .{ .offset = 0x10, .value = 7 }, .{ .offset = 0x11, .value = 8 }, .{ .offset = 0x20, .value = 9 } };
    @memcpy(raw[1..], std.mem.sliceAsBytes(&regs));
    const odd: [*]align(1) const ShaderRegister = @ptrCast(&raw[1]);
    _ = sceAgcCbSetShRegistersDirect(&cb, odd, 3);
    try expectWords(&cb, &.{ 0xC002_7600, 0x10, 7, 8, 0xC001_7600, 0x20, 9 });
    // None: the cursor, nothing written.
    try testing.expectEqual(@as(Out, @ptrFromInt(cb.cursor_up)), sceAgcCbSetUcRegistersDirect(&cb, null, 0));
    try testing.expectEqual(@as(Out, null), sceAgcCbSetUcRegistersDirect(&cb, null, 1));

    cb = CommandBuffer.over(&mem);
    _ = sceAgcDcbSetCxRegistersIndirect(&cb, 0, 0);
    _ = sceAgcDcbSetShRegistersIndirect(&cb, 0, 0);
    _ = sceAgcDcbSetUcRegistersIndirect(&cb, @intFromPtr(&regs), 3);
    try expectWords(&cb, &.{
        0xC003_9F00, 0,                         0,                               0x8000_0000, 0,
        0xC003_6300, 0,                         0,                               0x8000_0000, 0,
        0xC003_6400, lo32(@intFromPtr(&regs)), hi32(@intFromPtr(&regs)), 0x8000_0000, 3,
    });
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetCxRegistersIndirect(&cb, 0, 1));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetCxRegistersIndirect(&cb, 2, 0));
    try testing.expectEqual(@as(Out, null), sceAgcDcbSetCxRegistersIndirect(&cb, 4, 0x4000));
    try testing.expectEqual(@as(u32, 20), sceAgcCbSetRegisterRangeDirectGetSize(3));
    try testing.expectEqual(@as(u32, 36), sceAgcCbSetRegistersDirectGetSize(3));
    try testing.expectEqual(@as(u32, 0), sceAgcCbSetRegistersDirectGetSize(0x1555_5556));
}

/// A second buffer a full one is changed for, as a game's callback may do
/// it: the old one's words are wiped first, as memory given back is.
const Swap = struct {
    var first: [4]u32 = undefined;
    var second: [32]u32 = undefined;
    var calls: u32 = 0;

    fn grow(cb: *CommandBuffer, words: u32, user: ?*anyopaque) callconv(.c) bool {
        _ = words;
        _ = user;
        calls += 1;
        @memset(&first, 0xDEAD_DEAD);
        cb.* = CommandBuffer.over(&second);
        cb.grow = grow;
        return true;
    }
};

test "data a game points at inside its own buffer is copied before anything is written over it" {
    // Values staged at the cursor: the packet's first two words land on
    // them, and the values must still be what the packet carries.
    var words: [16]u32 = undefined;
    var cb = CommandBuffer.over(&words);
    words[0..3].* = .{ 11, 22, 33 };
    try testing.expect(sceAgcCbSetShRegisterRangeDirect(&cb, 0x40, @ptrCast(&words), 3) != null);
    try expectWords(&cb, &.{ header(OP.SET_SH_REG, 5, 0), 0x40, 11, 22, 33 });

    // A list staged at the cursor: three pairs, the last two in a row. Its
    // packets take more words than the list does, so they would run over
    // pairs not read yet: read from a copy.
    cb = CommandBuffer.over(&words);
    words[0..6].* = .{ 0x10, 1, 0x20, 2, 0x21, 3 };
    try testing.expect(sceAgcCbSetShRegistersDirect(&cb, @ptrCast(&words), 3) != null);
    try expectWords(&cb, &.{ header(OP.SET_SH_REG, 3, 0), 0x10, 1, header(OP.SET_SH_REG, 4, 0), 0x20, 2, 3 });

    // No room, and the game's callback brings another buffer and gives
    // the old one back, with the values in it: they were put aside.
    Swap.calls = 0;
    Swap.first[0..3].* = .{ 44, 55, 66 };
    cb = CommandBuffer.over(&Swap.first);
    cb.grow = Swap.grow;
    try testing.expect(sceAgcCbSetShRegisterRangeDirect(&cb, 0x50, @ptrCast(&Swap.first), 3) != null);
    try testing.expectEqual(@as(u32, 1), Swap.calls);
    try expectWords(&cb, &.{ header(OP.SET_SH_REG, 5, 0), 0x50, 44, 55, 66 });
    // (data elsewhere needs no putting aside: the same call, the values in
    // the test's own memory)
    Swap.calls = 0;
    const apart = [_]u32{ 7, 8, 9 };
    cb = CommandBuffer.over(&Swap.first);
    cb.grow = Swap.grow;
    try testing.expect(sceAgcCbSetShRegisterRangeDirect(&cb, 0x50, &apart, 3) != null);
    try testing.expectEqual(@as(u32, 1), Swap.calls);
    try expectWords(&cb, &.{ header(OP.SET_SH_REG, 5, 0), 0x50, 7, 8, 9 });
}

test "a stretch of any length is filled with NOPs a reader can walk" {
    const Long = struct {
        var words: [2 * pm4.MAX_WORDS + 3]u32 = undefined;
    };
    for ([_]usize{ 1, 2, pm4.MAX_WORDS - 1, pm4.MAX_WORDS, pm4.MAX_WORDS + 1, 2 * pm4.MAX_WORDS - 1, 2 * pm4.MAX_WORDS + 3 }) |n| {
        @memset(&Long.words, 0x1234_5678);
        fillNop(Long.words[0..n]);
        var r = pm4.Reader{ .words = Long.words[0..n] };
        var covered: usize = 0;
        while (try r.next()) |p| {
            try testing.expectEqual(@as(u8, OP.NOP), p.op());
            covered += p.words();
        }
        // (the reader ends exactly at the end: every word is a NOP's or a
        // filler, none left over and none past it)
        try testing.expectEqual(n, r.at);
        try testing.expect(covered <= n);
    }
}
