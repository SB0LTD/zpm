//! The file control block functions programs of the era still use (open,
//! close, create, delete, rename, sequential and random reads and writes,
//! block reads and writes, the size, the random record), over the same
//! SFT as the handles (an open FCB keeps its entry's number in its
//! reserved bytes), and 29h's filename parser, which also makes a new
//! program's two FCBs from its command tail. FCBs name files in the
//! current directory of drive C.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");
const Host = host_mod.Host;
const S = @import("dos_state.sig");
const State = S.State;
const path = @import("dos_path.sig");
const file = @import("dos_file.sig");
const find = @import("dos_find.sig");

// ── 29h ──────────────────────────────────────────────────────────────────

fn isSep(c: u8) bool {
    return switch (c) {
        ':', '.', ';', ',', '=', '+' => true,
        else => false,
    };
}
fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}
fn isTerm(c: u8) bool {
    if (c < 0x21) return true;
    return switch (c) {
        '.', '"', '/', '\\', '[', ']', ':', '|', '<', '>', '+', '=', ';', ',' => true,
        else => false,
    };
}

pub const Parsed = struct {
    /// 00h no wildcards, 01h wildcards, FFh an invalid drive.
    al: u8,
    /// Bytes of the string the name took.
    len: u32,
};

/// Parses a file name at `src` into the FCB at `fcb` (29h's flags: bit 0
/// skip a leading separator, 1 keep the drive, 2 the name, 3 the
/// extension when the string gives none).
pub fn parse(mem: *Memory, src: u32, fcb: u32, flags: u8) Parsed {
    var i: u32 = 0;
    const at = struct {
        fn f(m: *const Memory, s: u32, k: u32) u8 {
            return m.rd8(s + k);
        }
    }.f;
    while (isBlank(at(mem, src, i))) i += 1;
    if (flags & 1 != 0 and isSep(at(mem, src, i))) {
        i += 1;
        while (isBlank(at(mem, src, i))) i += 1;
    }
    var bad_drive = false;
    const c0 = path.upper(at(mem, src, i));
    if (c0 >= 'A' and c0 <= 'Z' and at(mem, src, i + 1) == ':') {
        const d = c0 - 'A' + 1;
        mem.wr8(fcb, d);
        bad_drive = d != S.DRIVE_C + 1;
        i += 2;
    } else if (flags & 2 == 0) mem.wr8(fcb, 0);
    var wild = false;
    // The name.
    const name_there = !isTerm(at(mem, src, i)) or at(mem, src, i) == '*' or at(mem, src, i) == '?';
    if (name_there or flags & 4 == 0) {
        var k: u32 = 0;
        while (k < 8) : (k += 1) mem.wr8(fcb + 1 + k, ' ');
    }
    var n: u32 = 0;
    while (true) {
        const c = at(mem, src, i);
        if (c == '*') {
            while (n < 8) : (n += 1) mem.wr8(fcb + 1 + n, '?');
            wild = true;
            i += 1;
            continue;
        }
        if (c != '?' and isTerm(c)) break;
        if (c == '?') wild = true;
        if (n < 8) {
            mem.wr8(fcb + 1 + n, path.upper(c));
            n += 1;
        }
        i += 1;
    }
    // The extension.
    if (at(mem, src, i) == '.') {
        i += 1;
        var k: u32 = 0;
        while (k < 3) : (k += 1) mem.wr8(fcb + 9 + k, ' ');
        var e: u32 = 0;
        while (true) {
            const c = at(mem, src, i);
            if (c == '*') {
                while (e < 3) : (e += 1) mem.wr8(fcb + 9 + e, '?');
                wild = true;
                i += 1;
                continue;
            }
            if (c != '?' and isTerm(c)) break;
            if (c == '?') wild = true;
            if (e < 3) {
                mem.wr8(fcb + 9 + e, path.upper(c));
                e += 1;
            }
            i += 1;
        }
    } else if (flags & 8 == 0) {
        var k: u32 = 0;
        while (k < 3) : (k += 1) mem.wr8(fcb + 9 + k, ' ');
    }
    return .{ .al = if (bad_drive) 0xFF else if (wild) 1 else 0, .len = i };
}

/// 29h: DS:SI the string, ES:DI the FCB, AL the flags; SI past the name.
pub fn parseName(r: *Regs, mem: *Memory) void {
    const p = parse(mem, r.base[regs.DS] +% r.si(), r.base[regs.ES] +% r.di(), r.al());
    r.setSi(r.si() +% @as(u16, @truncate(p.len)));
    r.setAl(p.al);
}

// ── FCB files ────────────────────────────────────────────────────────────

const MAGIC0: u8 = 'G';
const MAGIC1: u8 = 'X';

fn dosName(f: [11]u8, buf: *[13]u8) []u8 {
    return path.fromFcb(f, buf);
}

fn sftOfFcb(st: *const State, mem: *const Memory, fcb: u32) ?u8 {
    if (mem.rd8(fcb + 0x19) != MAGIC0 or mem.rd8(fcb + 0x1A) != MAGIC1) return null;
    const i = mem.rd8(fcb + 0x18);
    if (i >= S.MAX_HANDLES or st.sft[i].kind != .file) return null;
    return i;
}

fn recSize(mem: *Memory, fcb: u32) u32 {
    var rs: u32 = mem.rd16(fcb + 0x0E);
    if (rs == 0) {
        rs = 128;
        mem.wr16(fcb + 0x0E, 128);
    }
    return rs;
}

/// 0Fh open, 16h create.
pub fn open(st: *State, r: *Regs, mem: *Memory, host: Host, make: bool) void {
    const parts = find.fcbParts(mem, r.base[regs.DS] +% r.dx());
    const fcb = parts.fcb;
    if (!find.fcbDriveOk(mem, fcb)) return r.setAl(0xFF);
    const f = find.fcbName(mem, fcb);
    if (path.hasWild(f)) return r.setAl(0xFF);
    var nb: [13]u8 = undefined;
    const name = dosName(f, &nb);
    const how: file.How = if (make) .{ .access = 2, .create = true, .truncate = true, .must_exist = false } else .{ .access = 2 };
    const i = switch (file.openPath(st, host, name, how, null)) {
        .ok => |x| x,
        .err => |e| blk: {
            // (a read-only file opens for reading)
            if (make or e != file.E.denied) return r.setAl(0xFF);
            break :blk switch (file.openPath(st, host, name, .{ .access = 0 }, null)) {
                .ok => |x| x,
                .err => return r.setAl(0xFF),
            };
        },
    };
    const s = &st.sft[i];
    if (mem.rd8(fcb) == 0) mem.wr8(fcb, S.DRIVE_C + 1);
    mem.wr16(fcb + 0x0C, 0);
    mem.wr16(fcb + 0x0E, 128);
    var size: u32 = 0;
    var dt = S.dosDateTime(0);
    if (s.kind == .file) {
        var info: host_mod.Stat = .{};
        if (host.stat(s.hostPath(), &info)) {
            size = @intCast(@min(info.size, 0xFFFF_FFFF));
            dt = S.dosDateTime(info.mtime);
        }
    }
    mem.wr32(fcb + 0x10, size);
    mem.wr16(fcb + 0x14, dt.date);
    mem.wr16(fcb + 0x16, dt.time);
    mem.wr8(fcb + 0x18, i);
    mem.wr8(fcb + 0x19, MAGIC0);
    mem.wr8(fcb + 0x1A, MAGIC1);
    mem.wr8(fcb + 0x20, 0);
    r.setAl(0);
}

/// 10h: close.
pub fn close(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const fcb = find.fcbParts(mem, r.base[regs.DS] +% r.dx()).fcb;
    const i = sftOfFcb(st, mem, fcb) orelse return r.setAl(0xFF);
    file.release(st, host, i);
    mem.wr8(fcb + 0x19, 0);
    r.setAl(0);
}

const Rw = struct { al: u8, done: u32 };

/// `count` records from record `rec` to or from the DTA.
fn records(st: *State, mem: *Memory, host: Host, fcb: u32, i: u8, rec: u32, count0: u32, writing: bool) Rw {
    const rs = recSize(mem, fcb);
    var count = count0;
    var al: u8 = 0;
    // The DTA's segment must hold them.
    const room = (0x10000 - @as(u32, st.dta_off)) / rs;
    if (count > room) {
        count = room;
        al = 2;
    }
    if (count == 0) return .{ .al = if (al == 2) 2 else 0, .done = 0 };
    const s = &st.sft[i];
    const pos: u64 = @as(u64, rec) * rs;
    if (host.seek(s.fd, @intCast(pos), .set) < 0) return .{ .al = 1, .done = 0 };
    const at = Memory.lin(st.dta_seg, st.dta_off);
    const bytes = count * rs;
    if (writing) {
        s.written = true;
        const got = host.write(s.fd, mem.bytes(at, bytes));
        const n: u32 = if (got < 0) 0 else @intCast(got);
        const end: u32 = @intCast(@min(pos + n, 0xFFFF_FFFF));
        if (end > mem.rd32(fcb + 0x10)) mem.wr32(fcb + 0x10, end);
        return .{ .al = if (n < bytes) 1 else al, .done = n / rs };
    }
    const got = host.read(s.fd, mem.bytes(at, bytes));
    const n: u32 = if (got < 0) 0 else @intCast(got);
    const full = n / rs;
    const part = n % rs;
    if (part > 0) {
        // The last record, partly there: the rest zeroes.
        var k: u32 = n;
        while (k < (full + 1) * rs) : (k += 1) mem.wr8(at + k, 0);
        return .{ .al = 3, .done = full + 1 };
    }
    if (full < count) return .{ .al = 1, .done = full };
    return .{ .al = al, .done = full };
}

fn curRecord(mem: *const Memory, fcb: u32) u32 {
    return @as(u32, mem.rd16(fcb + 0x0C)) * 128 + mem.rd8(fcb + 0x20);
}
fn setCurRecord(mem: *Memory, fcb: u32, rec: u32) void {
    mem.wr16(fcb + 0x0C, @truncate(rec / 128));
    mem.wr8(fcb + 0x20, @intCast(rec % 128));
}
fn randomRecord(mem: *Memory, fcb: u32) u32 {
    const rr = mem.rd32(fcb + 0x21);
    return if (recSize(mem, fcb) >= 64) rr & 0x00FF_FFFF else rr;
}
fn setRandom(mem: *Memory, fcb: u32, rec: u32) void {
    if (recSize(mem, fcb) >= 64) {
        mem.wr16(fcb + 0x21, @truncate(rec));
        mem.wr8(fcb + 0x23, @truncate(rec >> 16));
    } else mem.wr32(fcb + 0x21, rec);
}

/// 14h/15h: the next record, sequentially.
pub fn sequential(st: *State, r: *Regs, mem: *Memory, host: Host, writing: bool) void {
    const fcb = find.fcbParts(mem, r.base[regs.DS] +% r.dx()).fcb;
    const i = sftOfFcb(st, mem, fcb) orelse return r.setAl(1);
    const rec = curRecord(mem, fcb);
    const res = records(st, mem, host, fcb, i, rec, 1, writing);
    if (res.done > 0) setCurRecord(mem, fcb, rec + 1);
    r.setAl(res.al);
}

/// 21h/22h: the random record (the current record set to it).
pub fn random(st: *State, r: *Regs, mem: *Memory, host: Host, writing: bool) void {
    const fcb = find.fcbParts(mem, r.base[regs.DS] +% r.dx()).fcb;
    const i = sftOfFcb(st, mem, fcb) orelse return r.setAl(1);
    const rec = randomRecord(mem, fcb);
    setCurRecord(mem, fcb, rec);
    r.setAl(records(st, mem, host, fcb, i, rec, 1, writing).al);
}

/// 27h/28h: CX records from the random record (both moved past them);
/// 28h with CX 0 sets the file's size there.
pub fn block(st: *State, r: *Regs, mem: *Memory, host: Host, writing: bool) void {
    const fcb = find.fcbParts(mem, r.base[regs.DS] +% r.dx()).fcb;
    const i = sftOfFcb(st, mem, fcb) orelse return r.setAl(1);
    const rec = randomRecord(mem, fcb);
    if (writing and r.cx() == 0) {
        const size = rec * recSize(mem, fcb);
        _ = host.truncate(st.sft[i].fd, size);
        mem.wr32(fcb + 0x10, size);
        return r.setAl(0);
    }
    const res = records(st, mem, host, fcb, i, rec, r.cx(), writing);
    setRandom(mem, fcb, rec + res.done);
    setCurRecord(mem, fcb, rec + res.done);
    r.setCx(@intCast(res.done));
    r.setAl(res.al);
}

/// 23h: the file's size in records, in the random record.
pub fn fileSize(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const fcb = find.fcbParts(mem, r.base[regs.DS] +% r.dx()).fcb;
    if (!find.fcbDriveOk(mem, fcb)) return r.setAl(0xFF);
    var nb: [13]u8 = undefined;
    const name = dosName(find.fcbName(mem, fcb), &nb);
    var cb: [S.DOS_PATH]u8 = undefined;
    var hp: path.HostPath = .{};
    _ = path.map(st, host, name, &cb, &hp) catch return r.setAl(0xFF);
    var info: host_mod.Stat = .{};
    if (!hp.exists or hp.dir or !host.stat(hp.str(), &info)) return r.setAl(0xFF);
    const rs = recSize(mem, fcb);
    const sz: u32 = @intCast(@min(info.size, 0xFFFF_FFFF));
    setRandom(mem, fcb, (sz + rs - 1) / rs);
    r.setAl(0);
}

/// 24h: the random record from the current block and record.
pub fn setRandomRecord(r: *Regs, mem: *Memory) void {
    const fcb = find.fcbParts(mem, r.base[regs.DS] +% r.dx()).fcb;
    setRandom(mem, fcb, curRecord(mem, fcb));
}

/// 13h: deletes the files the FCB's pattern matches.
pub fn delete(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const fcb = find.fcbParts(mem, r.base[regs.DS] +% r.dx()).fcb;
    if (!find.fcbDriveOk(mem, fcb)) return r.setAl(0xFF);
    const slot = switch (find.start(st, host, st.cwdPath(), find.fcbName(mem, fcb), 0)) {
        .ok => |x| x,
        .err => return r.setAl(0xFF),
    };
    var any = false;
    // (names are gathered first: deleting while listing would move them)
    var names: [32][11]u8 = undefined;
    var n: usize = 0;
    var index: u16 = 0;
    while (n < names.len) {
        const f = find.next(st, host, slot, &index) orelse break;
        names[n] = f.fcb;
        n += 1;
    }
    for (names[0..n]) |f| {
        var nb: [13]u8 = undefined;
        var cb: [S.DOS_PATH]u8 = undefined;
        var hp: path.HostPath = .{};
        _ = path.map(st, host, dosName(f, &nb), &cb, &hp) catch continue;
        if (hp.exists and !hp.dir and host.unlink(hp.str()) >= 0) any = true;
    }
    r.setAl(if (any) 0 else 0xFF);
}

/// 17h: renames the files matching the FCB's name to its second name (at
/// +11h; a '?' there keeps the old name's character).
pub fn rename(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const fcb = find.fcbParts(mem, r.base[regs.DS] +% r.dx()).fcb;
    if (!find.fcbDriveOk(mem, fcb)) return r.setAl(0xFF);
    var to: [11]u8 = undefined;
    for (&to, 0..) |*c, k| c.* = path.upper(mem.rd8(fcb + 0x11 + @as(u32, @intCast(k))));
    const slot = switch (find.start(st, host, st.cwdPath(), find.fcbName(mem, fcb), 0)) {
        .ok => |x| x,
        .err => return r.setAl(0xFF),
    };
    var names: [32][11]u8 = undefined;
    var n: usize = 0;
    var index: u16 = 0;
    while (n < names.len) {
        const f = find.next(st, host, slot, &index) orelse break;
        names[n] = f.fcb;
        n += 1;
    }
    var any = false;
    for (names[0..n]) |old| {
        var new: [11]u8 = to;
        for (&new, 0..) |*c, k| if (c.* == '?') {
            c.* = old[k];
        };
        var b1: [13]u8 = undefined;
        var b2: [13]u8 = undefined;
        var c1: [S.DOS_PATH]u8 = undefined;
        var c2: [S.DOS_PATH]u8 = undefined;
        var h1: path.HostPath = .{};
        var h2: path.HostPath = .{};
        _ = path.map(st, host, dosName(old, &b1), &c1, &h1) catch continue;
        _ = path.map(st, host, dosName(new, &b2), &c2, &h2) catch continue;
        if (!h1.exists or h2.exists) continue;
        if (host.rename(h1.str(), h2.str()) >= 0) any = true;
    }
    r.setAl(if (any) 0 else 0xFF);
}
