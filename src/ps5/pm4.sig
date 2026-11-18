//! @zpm/ps5 pm4 — the PS5 GPU's command packets as data: what a game's
//! graphics library writes into a command buffer, and what the driver reads
//! back out of it.
//!
//! The PS5's GPU is AMD's, and takes AMD's PM4 packets: a 32-bit header
//! (type, length, opcode, flags), then that many words of payload. A game
//! never writes these itself: it calls the graphics library (libSceAgc),
//! which writes them, and hands the buffer to the driver (libSceAgcDriver),
//! which the console's kernel runs on the GPU. Here both ends are in the
//! process, so the few packets that are not AMD's own (a flip, a wait for a
//! display buffer, a marker) are this library pair's private matter: a NOP
//! with a sub-type in its header's low byte.
//!
//! Registers are written in three banks, each addressed from its own base:
//! the shaders' ("SH"), the context's ("CX": targets, viewports, blending,
//! depth) and the user configuration's ("UC": primitive type, index type).
//!
//! This file is the format only: headers, opcodes, the banks, a reader that
//! walks a buffer packet by packet with every length checked, and a writer
//! for the libraries here and their tests. No Sony code: AMD's packet
//! format is public (the Linux kernel's and Mesa's headers), and the PS5's
//! use of it is as open projects document it. Allocation-free.

const std = @import("std");

// ── Headers ─────────────────────────────────────────────────────────────────

/// A packet's opcode (bits 15..8 of a type-3 header).
pub const OP = struct {
    pub const NOP: u8 = 0x10;
    pub const SET_BASE: u8 = 0x11;
    pub const CLEAR_STATE: u8 = 0x12;
    pub const INDEX_BUFFER_SIZE: u8 = 0x13;
    pub const DISPATCH_DIRECT: u8 = 0x15;
    pub const DISPATCH_INDIRECT: u8 = 0x16;
    pub const ATOMIC_GDS: u8 = 0x1D;
    pub const ATOMIC_MEM: u8 = 0x1E;
    pub const SET_PREDICATION: u8 = 0x20;
    pub const COND_EXEC: u8 = 0x22;
    pub const DRAW_INDIRECT: u8 = 0x24;
    pub const DRAW_INDEX_INDIRECT: u8 = 0x25;
    pub const INDEX_BASE: u8 = 0x26;
    pub const DRAW_INDEX_2: u8 = 0x27;
    pub const CONTEXT_CONTROL: u8 = 0x28;
    pub const INDEX_TYPE: u8 = 0x2A;
    pub const DRAW_INDIRECT_MULTI: u8 = 0x2C;
    pub const DRAW_INDEX_AUTO: u8 = 0x2D;
    pub const NUM_INSTANCES: u8 = 0x2F;
    pub const DRAW_INDEX_OFFSET_2: u8 = 0x35;
    pub const WRITE_DATA: u8 = 0x37;
    pub const DRAW_INDEX_INDIRECT_MULTI: u8 = 0x38;
    pub const MEM_SEMAPHORE: u8 = 0x39;
    pub const DRAW_INDEX_MULTI_INST: u8 = 0x3A;
    pub const WAIT_REG_MEM: u8 = 0x3C;
    pub const INDIRECT_BUFFER: u8 = 0x3F;
    pub const COPY_DATA: u8 = 0x40;
    pub const PFP_SYNC_ME: u8 = 0x42;
    pub const COND_WRITE: u8 = 0x45;
    pub const EVENT_WRITE: u8 = 0x46;
    /// (the older end-of-pipe packet: never written here, only patched)
    pub const EVENT_WRITE_EOP: u8 = 0x47;
    pub const RELEASE_MEM: u8 = 0x49;
    pub const DMA_DATA: u8 = 0x50;
    pub const CONTEXT_REG_RMW: u8 = 0x51;
    pub const ACQUIRE_MEM: u8 = 0x58;
    pub const REWIND: u8 = 0x59;
    pub const SET_SH_REG_INDIRECT: u8 = 0x63;
    pub const SET_UCONFIG_REG_INDIRECT: u8 = 0x64;
    pub const SET_CONFIG_REG: u8 = 0x68;
    pub const SET_CONTEXT_REG: u8 = 0x69;
    pub const SET_SH_REG: u8 = 0x76;
    pub const SET_UCONFIG_REG: u8 = 0x79;
    pub const SET_UCONFIG_REG_INDEX: u8 = 0x7A;
    pub const WRITE_CONST_RAM: u8 = 0x81;
    pub const DUMP_CONST_RAM: u8 = 0x83;
    pub const INDEX_ATTRIBUTES_INDIRECT: u8 = 0x91;
    pub const WAIT_REG_MEM_64: u8 = 0x93;
    pub const SET_CONTEXT_REG_INDIRECT: u8 = 0x9F;
};

/// An opcode's name, for a log line. "?" for one this file does not know.
pub fn opName(op: u8) []const u8 {
    inline for (@typeInfo(OP).@"struct".decl_names) |name| {
        if (@field(OP, name) == op) return name;
    }
    return "?";
}

/// The header's low byte.
pub const FLAG = struct {
    /// The packet runs only while the queue's predicate holds.
    pub const PREDICATE: u8 = 1;
    /// It is about compute shaders (which base a SET_BASE sets, and so on).
    pub const COMPUTE: u8 = 2;
    /// On a register write: accepted, and nothing here depends on it.
    pub const RESET_FILTER_CAM: u8 = 4;
};

/// A NOP's sub-type (its header's bits 7..2): the packets that are this
/// library pair's own.
pub const SUB = struct {
    pub const PLAIN: u8 = 0;
    /// [handle, buffer, 0]: wait until that display buffer may be drawn to.
    pub const WAIT_SAFE: u8 = 0x06;
    /// [op]: a compute queue's state back to its start.
    pub const DISPATCH_RESET: u8 = 0x09;
    /// Text, ended with a 0 and padded: a name for what follows.
    pub const PUSH_MARKER: u8 = 0x0B;
    pub const POP_MARKER: u8 = 0x0C;
    /// [handle, buffer, mode, arg low, arg high]: show that display buffer.
    pub const FLIP: u8 = 0x17;
    /// [op, 0...]: the context registers reset (0), saved (1), restored
    /// (2), or saved and reset (3).
    pub const CONTEXT_STATE: u8 = 0x1A;
};

/// A packet's most words, its header among them.
pub const MAX_WORDS = 0x4001;

/// A one-word packet that does nothing (what a library pads with).
pub const FILLER: u32 = 0xFFFF_1000;

/// A type-3 header: `words` is the whole packet's length, its header
/// among them (2 at least).
pub fn header(op: u8, words: u32, flags: u8) u32 {
    std.debug.assert(words >= 2 and words <= MAX_WORDS);
    // (a NOP of the most words would read as the one-word filler)
    std.debug.assert(op != OP.NOP or words < MAX_WORDS);
    return 0xC000_0000 | (words - 2) << 16 | @as(u32, op) << 8 | flags;
}

/// A NOP of a sub-type.
pub fn nop(sub: u8, words: u32) u32 {
    return header(OP.NOP, words, sub << 2);
}

pub fn opOf(h: u32) u8 {
    return @truncate(h >> 8);
}

pub fn flagsOf(h: u32) u8 {
    return @truncate(h);
}

/// Whether a word is a one-word filler: a type-2 header, or the NOP with
/// no payload.
pub fn isFiller(h: u32) bool {
    return h >> 30 == 2 or h & 0x3FFF_FF00 == 0x3FFF_1000 and h >> 30 == 3;
}

/// How many words the packet a header starts takes. Null: not a header
/// this GPU's packets have (types 0 and 1).
pub fn lengthOf(h: u32) ?u32 {
    if (isFiller(h)) return 1;
    if (h >> 30 != 3) return null;
    return (h >> 16 & 0x3FFF) + 2;
}

// ── Registers ───────────────────────────────────────────────────────────────

/// A bank of registers: where it starts among all the GPU's registers (a
/// register's number; four times it is its byte address) and how many it
/// has.
pub const Bank = enum {
    sh,
    cx,
    uc,

    pub fn base(b: Bank) u32 {
        return switch (b) {
            .sh => 0x2C00,
            .cx => 0xA000,
            .uc => 0xC000,
        };
    }

    pub fn size(b: Bank) u32 {
        return switch (b) {
            .sh, .cx => 0x400,
            .uc => 0x4000,
        };
    }

    /// The bank a register's absolute number is in, and its place there.
    pub fn of(absolute: u32) ?struct { bank: Bank, offset: u32 } {
        inline for (.{ Bank.sh, Bank.cx, Bank.uc }) |b| {
            if (absolute >= b.base() and absolute - b.base() < b.size()) return .{ .bank = b, .offset = absolute - b.base() };
        }
        return null;
    }
};

/// The bank a register-writing opcode writes. Null: not such an opcode.
pub fn bankOf(op: u8) ?Bank {
    return switch (op) {
        OP.SET_SH_REG, OP.SET_SH_REG_INDIRECT => .sh,
        OP.SET_CONTEXT_REG, OP.SET_CONTEXT_REG_INDIRECT, OP.CONTEXT_REG_RMW => .cx,
        OP.SET_UCONFIG_REG, OP.SET_UCONFIG_REG_INDEX, OP.SET_UCONFIG_REG_INDIRECT => .uc,
        else => null,
    };
}

/// The user-configuration register a library tags packets through (a
/// write to it changes nothing: it says what the packets after it are).
pub const UC_TAG: u32 = 0x342;

// ── Reading ─────────────────────────────────────────────────────────────────

/// One packet: its header and the words after it.
pub const Packet = struct {
    /// Where its header is in the buffer, in words.
    at: usize,
    head: u32,
    body: []const u32,

    pub fn op(p: Packet) u8 {
        return opOf(p.head);
    }
    pub fn flags(p: Packet) u8 {
        return flagsOf(p.head);
    }
    /// A NOP's sub-type.
    pub fn sub(p: Packet) u8 {
        return flagsOf(p.head) >> 2;
    }
    pub fn predicated(p: Packet) bool {
        return p.head & FLAG.PREDICATE != 0 and p.op() != OP.NOP;
    }
    pub fn compute(p: Packet) bool {
        return p.head & FLAG.COMPUTE != 0 and p.op() != OP.NOP;
    }
    /// Its length in words, header and all.
    pub fn words(p: Packet) usize {
        return p.body.len + 1;
    }
    /// Two of its words as a 64-bit value, low word first (an address).
    pub fn pair(p: Packet, low: usize) u64 {
        return @as(u64, p.body[low + 1]) << 32 | p.body[low];
    }
};

pub const Error = error{
    /// A word where a header should be that is none of this GPU's.
    NotAPacket,
    /// A header that says its packet goes on past the buffer's end.
    CutShort,
};

/// Walks a command buffer packet by packet. Fillers are stepped over.
pub const Reader = struct {
    words: []const u32,
    at: usize = 0,

    pub fn next(r: *Reader) Error!?Packet {
        while (r.at < r.words.len) {
            const h = r.words[r.at];
            const n = lengthOf(h) orelse return error.NotAPacket;
            if (n == 1) {
                r.at += 1;
                continue;
            }
            if (n > r.words.len - r.at) return error.CutShort;
            const p = Packet{ .at = r.at, .head = h, .body = r.words[r.at + 1 ..][0 .. n - 1] };
            r.at += n;
            return p;
        }
        return null;
    }
};

// ── Writing ─────────────────────────────────────────────────────────────────

/// Writes packets into words the caller owns. A packet that does not fit
/// is not begun: `full` is set and nothing is written.
pub const Writer = struct {
    words: []u32,
    len: usize = 0,
    full: bool = false,

    /// A packet of an opcode: its header and payload. Where it starts, in
    /// words, or null when there was no room.
    pub fn put(w: *Writer, op: u8, flags: u8, payload: []const u32) ?usize {
        return w.raw(header(op, @intCast(payload.len + 1), flags), payload);
    }

    /// A NOP of a sub-type.
    pub fn putNop(w: *Writer, sub: u8, payload: []const u32) ?usize {
        return w.raw(nop(sub, @intCast(payload.len + 1)), payload);
    }

    fn raw(w: *Writer, head: u32, payload: []const u32) ?usize {
        std.debug.assert(payload.len >= 1);
        if (payload.len + 1 > w.words.len - w.len) {
            w.full = true;
            return null;
        }
        const at = w.len;
        w.words[at] = head;
        @memcpy(w.words[at + 1 ..][0..payload.len], payload);
        w.len += payload.len + 1;
        return at;
    }

    /// One register (or several in a row) of a bank.
    pub fn setRegisters(w: *Writer, bank: Bank, offset: u32, values: []const u32) ?usize {
        std.debug.assert(values.len >= 1 and values.len < MAX_WORDS - 2);
        if (values.len + 2 > w.words.len - w.len) {
            w.full = true;
            return null;
        }
        const op: u8 = switch (bank) {
            .sh => OP.SET_SH_REG,
            .cx => OP.SET_CONTEXT_REG,
            .uc => OP.SET_UCONFIG_REG,
        };
        const at = w.len;
        w.words[at] = header(op, @intCast(values.len + 2), 0);
        w.words[at + 1] = offset;
        @memcpy(w.words[at + 2 ..][0..values.len], values);
        w.len += values.len + 2;
        return at;
    }

    /// The flip packet: show display buffer `buffer` of output `handle`.
    pub fn flip(w: *Writer, handle: u32, buffer: i32, mode: u32, arg: i64) ?usize {
        const a: u64 = @bitCast(arg);
        return w.putNop(SUB.FLIP, &.{ handle, @bitCast(buffer), mode, @truncate(a), @truncate(a >> 32) });
    }

    pub fn written(w: *const Writer) []const u32 {
        return w.words[0..w.len];
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "headers: a type-3 packet's length, opcode and flags; fillers; what is not a packet" {
    // (the headers open projects quote for these packets)
    try std.testing.expectEqual(@as(u32, 0xC000_1000), header(OP.NOP, 2, 0));
    try std.testing.expectEqual(@as(u32, 0xC002_1000), header(OP.NOP, 4, 0));
    try std.testing.expectEqual(@as(u32, 0xC001_7904), header(OP.SET_UCONFIG_REG, 3, FLAG.RESET_FILTER_CAM));
    try std.testing.expectEqual(@as(u32, 0xC004_105C), nop(SUB.FLIP, 6));
    try std.testing.expectEqual(@as(u32, 0xC002_1018), nop(SUB.WAIT_SAFE, 4));
    try std.testing.expectEqual(@as(u32, 0xC000_1030), nop(SUB.POP_MARKER, 2));
    try std.testing.expectEqual(@as(u32, 0xC002_1102), header(OP.SET_BASE, 4, FLAG.COMPUTE));

    try std.testing.expectEqual(@as(?u32, 6), lengthOf(0xC004_105C));
    try std.testing.expectEqual(@as(?u32, MAX_WORDS), lengthOf(header(OP.WRITE_DATA, MAX_WORDS, 0)));
    // (a NOP may be one word shorter: the longest NOP's header is the
    // one-word filler's)
    try std.testing.expectEqual(@as(?u32, MAX_WORDS - 1), lengthOf(header(OP.NOP, MAX_WORDS - 1, 0)));
    try std.testing.expectEqual(@as(u8, OP.SET_UCONFIG_REG), opOf(0xC001_7904));
    try std.testing.expectEqual(@as(u8, 4), flagsOf(0xC001_7904));

    // One word that does nothing: the NOP without a payload (whatever its
    // low byte), and a type-2 header.
    try std.testing.expect(isFiller(FILLER));
    try std.testing.expect(isFiller(0xFFFF_10FF));
    try std.testing.expect(isFiller(0x8000_0000));
    try std.testing.expect(!isFiller(0xC000_1000));
    try std.testing.expectEqual(@as(?u32, 1), lengthOf(FILLER));
    // Types 0 and 1 are not this GPU's.
    try std.testing.expectEqual(@as(?u32, null), lengthOf(0x0001_2345));
    try std.testing.expectEqual(@as(?u32, null), lengthOf(0x4000_0000));

    try std.testing.expectEqualStrings("RELEASE_MEM", opName(OP.RELEASE_MEM));
    try std.testing.expectEqualStrings("?", opName(0xEE));
}

test "the register banks" {
    try std.testing.expectEqual(Bank.cx, bankOf(OP.SET_CONTEXT_REG).?);
    try std.testing.expectEqual(Bank.sh, bankOf(OP.SET_SH_REG_INDIRECT).?);
    try std.testing.expectEqual(Bank.uc, bankOf(OP.SET_UCONFIG_REG_INDEX).?);
    try std.testing.expectEqual(@as(?Bank, null), bankOf(OP.NOP));
    // A register by its absolute number (as a copy or a write names it).
    const tag = Bank.of(0xC343).?;
    try std.testing.expectEqual(Bank.uc, tag.bank);
    try std.testing.expectEqual(@as(u32, 0x343), tag.offset);
    try std.testing.expectEqual(Bank.sh, Bank.of(0x2C00).?.bank);
    try std.testing.expectEqual(@as(u32, 0x3FF), Bank.of(0xA3FF).?.offset);
    try std.testing.expect(Bank.of(0x2BFF) == null);
    try std.testing.expect(Bank.of(0x3000) == null);
    try std.testing.expect(Bank.of(0xA400) == null);
    try std.testing.expect(Bank.of(0x10000) == null);
}

test "a buffer written and read back: packets in order, fillers stepped over" {
    var words: [64]u32 = undefined;
    var w = Writer{ .words = &words };
    try std.testing.expectEqual(@as(?usize, 0), w.setRegisters(.cx, 0x80, &.{ 1, 2, 3 }));
    words[w.len] = FILLER;
    w.len += 1;
    words[w.len] = 0x8000_0000;
    w.len += 1;
    try std.testing.expectEqual(@as(?usize, 7), w.put(OP.DRAW_INDEX_AUTO, FLAG.PREDICATE, &.{ 3, 2 }));
    try std.testing.expectEqual(@as(?usize, 10), w.flip(1, -1, 1, -2));

    var r = Reader{ .words = w.written() };
    const set = (try r.next()).?;
    try std.testing.expectEqual(@as(u8, OP.SET_CONTEXT_REG), set.op());
    try std.testing.expectEqualSlices(u32, &.{ 0x80, 1, 2, 3 }, set.body);
    try std.testing.expectEqual(@as(usize, 5), set.words());
    const draw = (try r.next()).?;
    try std.testing.expectEqual(@as(usize, 7), draw.at);
    try std.testing.expect(draw.predicated());
    try std.testing.expect(!draw.compute());
    const f = (try r.next()).?;
    try std.testing.expectEqual(@as(u8, OP.NOP), f.op());
    try std.testing.expectEqual(SUB.FLIP, f.sub());
    // (a NOP's low byte is its sub-type, not the flags other packets have)
    try std.testing.expect(!f.predicated());
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), f.body[1]);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -2))), f.pair(3));
    try std.testing.expectEqual(@as(?Packet, null), try r.next());
}

test "a buffer that ends inside a packet, or holds what is not one, is refused" {
    const cut = [_]u32{ header(OP.SET_SH_REG, 4, 0), 0x10, 1 };
    var r = Reader{ .words = &cut };
    try std.testing.expectError(error.CutShort, r.next());
    const not = [_]u32{ 0xC000_1000, 0, 0x0001_0000, 0 };
    r = Reader{ .words = &not };
    _ = try r.next();
    try std.testing.expectError(error.NotAPacket, r.next());
    // Every way a buffer can be cut: an error or the packets before, never
    // a read past the end.
    var words: [32]u32 = undefined;
    var w = Writer{ .words = &words };
    _ = w.setRegisters(.uc, 0x242, &.{4});
    _ = w.put(OP.RELEASE_MEM, 0, &.{ 0x2F, 0x2000_0000, 0x1000, 0, 7, 0, 0 });
    _ = w.flip(1, 0, 1, 0);
    for (0..w.len + 1) |n| {
        var rr = Reader{ .words = words[0..n] };
        while (rr.next() catch null) |_| {}
        try std.testing.expect(rr.at <= n);
    }
}

test "a writer with no room writes nothing and says so" {
    var words: [4]u32 = undefined;
    var w = Writer{ .words = &words };
    try std.testing.expectEqual(@as(?usize, null), w.flip(1, 0, 1, 0));
    try std.testing.expect(w.full);
    try std.testing.expectEqual(@as(usize, 0), w.len);
    w.full = false;
    try std.testing.expectEqual(@as(?usize, 0), w.setRegisters(.sh, 0x8C, &.{ 5, 6 }));
    try std.testing.expectEqual(@as(?usize, null), w.setRegisters(.sh, 0x8C, &.{5}));
    try std.testing.expect(w.full);
}
