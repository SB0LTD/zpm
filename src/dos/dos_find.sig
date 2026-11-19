//! Find first/next (4Eh/4Fh, and the FCB forms 11h/12h): a search is a
//! host folder, an 11-byte pattern and the attributes asked for, kept in
//! a slot DOS owns; the program's DTA holds the slot's number, its
//! generation and the position, so a program may keep several searches
//! (saving and restoring DTAs) until 32 newer ones have reused its slot.
//! Names are the folders' DOS names (8.3, or the aliases dos_path.sig
//! makes for long host names); subfolders show "." and "..".

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");
const Host = host_mod.Host;
const S = @import("dos_state.sig");
const State = S.State;
const path = @import("dos_path.sig");

const MAGIC: u8 = 'G';
pub const LABEL = "GALAXY     ";

pub const Found = struct {
    fcb: [11]u8 = [_]u8{' '} ** 11,
    attr: u8 = 0,
    time: u16 = 0,
    date: u16 = 0,
    size: u32 = 0,
};

pub const Started = union(enum) {
    ok: u8,
    err: u16,
};

/// A new search in the canonical folder `dir`.
pub fn start(st: *State, host: Host, dir: []const u8, pattern: [11]u8, attr: u8) Started {
    var hp: path.HostPath = .{};
    path.resolveDir(st, host, dir, &hp) catch return .{ .err = 3 };
    const slot = st.search_next % S.MAX_SEARCH;
    st.search_next = (st.search_next + 1) % S.MAX_SEARCH;
    st.search_gen +%= 1;
    if (st.search_gen == 0) st.search_gen = 1;
    if (st.cache_slot == slot) dropCache(st, host);
    const s = &st.searches[slot];
    s.* = .{ .gen = st.search_gen, .attr = attr, .pattern = pattern, .root = dir.len == 0 };
    @memcpy(s.dir[0..hp.len], hp.str());
    s.dir_len = hp.len;
    return .{ .ok = slot };
}

fn dropCache(st: *State, host: Host) void {
    if (st.cache_dir >= 0) host.dirClose(st.cache_dir);
    st.cache_dir = -1;
    st.cache_slot = -1;
}

fn entryAttr(s: *const host_mod.Stat) u8 {
    var a: u8 = if (s.dir) 0x10 else 0x20;
    if (s.readonly) a |= 0x01;
    return a;
}

/// Whether an entry with attributes `a` is one a search for `want` sees:
/// hidden, system and folders only when asked for.
fn wanted(a: u8, want: u8) bool {
    return (a & 0x16) & ~want == 0;
}

/// The next match of search `slot` from position `index` (moved past it).
pub fn next(st: *State, host: Host, slot: u8, index: *u16) ?Found {
    const s = &st.searches[slot];
    // A volume label search (attribute 08h alone): the label, in the root.
    if (s.attr == 0x08) {
        if (index.* > 0 or !s.root) return null;
        index.* = 1;
        var lab: [11]u8 = undefined;
        @memcpy(&lab, LABEL);
        if (!path.matches(s.pattern, lab)) return null;
        return .{ .fcb = lab, .attr = 0x08 };
    }
    const synth: u16 = if (s.root) 0 else 2;
    while (index.* < synth) {
        const i = index.*;
        index.* += 1;
        if (s.attr & 0x10 == 0) continue;
        var f = [_]u8{' '} ** 11;
        f[0] = '.';
        if (i == 1) f[1] = '.';
        if (!path.matches(s.pattern, f)) continue;
        var info: host_mod.Stat = .{};
        _ = host.stat(s.hostDir(), &info);
        const dt = S.dosDateTime(info.mtime);
        return .{ .fcb = f, .attr = 0x10, .time = dt.time, .date = dt.date };
    }
    var raw: u32 = index.* - synth;
    if (!(st.cache_slot == slot and st.cache_raw == raw and st.cache_dir >= 0)) {
        dropCache(st, host);
        const d = host.dirOpen(s.hostDir());
        if (d < 0) return null;
        st.cache_dir = d;
        st.cache_slot = slot;
        var e: host_mod.DirEntry = .{};
        var k: u32 = 0;
        while (k < raw) : (k += 1) {
            if (!host.dirNext(d, &e)) {
                dropCache(st, host);
                return null;
            }
        }
    }
    var e: host_mod.DirEntry = .{};
    while (host.dirNext(st.cache_dir, &e)) {
        const k = raw;
        raw += 1;
        const name = e.str();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const f = path.dosNameOf(host, s.hostDir(), name, k);
        if (!path.matches(s.pattern, f)) continue;
        var hp: path.HostPath = .{};
        _ = hp.push(s.hostDir());
        if (!hp.push(name)) continue;
        var info: host_mod.Stat = .{ .dir = e.dir };
        _ = host.stat(hp.str(), &info);
        const a = entryAttr(&info);
        if (!wanted(a, s.attr)) continue;
        const dt = S.dosDateTime(info.mtime);
        st.cache_raw = raw;
        index.* = @intCast(raw + synth);
        return .{ .fcb = f, .attr = a, .time = dt.time, .date = dt.date, .size = @intCast(@min(info.size, 0xFFFF_FFFF)) };
    }
    dropCache(st, host);
    index.* = @intCast(raw + synth);
    return null;
}

fn dta(st: *const State) u32 {
    return Memory.lin(st.dta_seg, st.dta_off);
}

fn putFound(mem: *Memory, at: u32, f: *const Found) void {
    mem.wr8(at + 0x15, f.attr);
    mem.wr16(at + 0x16, f.time);
    mem.wr16(at + 0x18, f.date);
    mem.wr32(at + 0x1A, f.size);
    var nb: [13]u8 = undefined;
    const name = if (f.fcb[0] == '.') (if (f.fcb[1] == '.') ".." else ".") else path.fromFcb(f.fcb, &nb);
    var i: u32 = 0;
    while (i < 13) : (i += 1) mem.wr8(at + 0x1E + i, if (i < name.len) name[i] else 0);
}

/// 4Eh: find first (CX attributes, DS:DX the path with wildcards).
pub fn findFirst(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    var pb: [S.DOS_PATH]u8 = undefined;
    const p = mem.cstr(r.base[regs.DS] +% r.dx(), &pb);
    var cb: [S.DOS_PATH]u8 = undefined;
    const canon = path.canonical(st, p, &cb) catch |e| return st.fail(r, path.code(e));
    const parts = path.split(canon);
    const pattern = if (parts.name.len == 0) [_]u8{'?'} ** 11 else path.toFcb(parts.name) orelse return st.fail(r, 2);
    const attr: u8 = @truncate(r.cx());
    const slot = switch (start(st, host, parts.dir, pattern, attr)) {
        .ok => |x| x,
        .err => |e| return st.fail(r, e),
    };
    const at = dta(st);
    mem.wr8(at, S.DRIVE_C + 1);
    mem.copyIn(at + 1, &pattern);
    mem.wr8(at + 0x0C, attr);
    mem.wr16(at + 0x0D, 0);
    mem.wr8(at + 0x0F, slot);
    mem.wr8(at + 0x10, MAGIC);
    mem.wr16(at + 0x11, st.searches[slot].gen);
    mem.wr16(at + 0x13, 0);
    var index: u16 = 0;
    const f = next(st, host, slot, &index) orelse return st.fail(r, 2);
    mem.wr16(at + 0x0D, index);
    putFound(mem, at, &f);
    r.setAx(0);
    r.ok();
}

/// 4Fh: find next (the search in the DTA).
pub fn findNext(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const at = dta(st);
    const slot = mem.rd8(at + 0x0F);
    if (mem.rd8(at + 0x10) != MAGIC or slot >= S.MAX_SEARCH or mem.rd16(at + 0x11) != st.searches[slot].gen)
        return st.fail(r, 0x12);
    var index = mem.rd16(at + 0x0D);
    const f = next(st, host, slot, &index) orelse {
        mem.wr16(at + 0x0D, index);
        return st.fail(r, 0x12);
    };
    mem.wr16(at + 0x0D, index);
    putFound(mem, at, &f);
    r.setAx(0);
    r.ok();
}

/// An FCB at `at` (extended or not): where its normal part is, the
/// attribute an extended one gives.
pub fn fcbParts(mem: *const Memory, at: u32) struct { fcb: u32, ext: bool, attr: u8 } {
    if (mem.rd8(at) == 0xFF) return .{ .fcb = at + 7, .ext = true, .attr = mem.rd8(at + 6) };
    return .{ .fcb = at, .ext = false, .attr = 0 };
}

/// An FCB's name field, upper-cased.
pub fn fcbName(mem: *const Memory, fcb: u32) [11]u8 {
    var f: [11]u8 = undefined;
    for (&f, 0..) |*c, i| c.* = path.upper(mem.rd8(fcb + 1 + @as(u32, @intCast(i))));
    return f;
}

/// Whether an FCB's drive byte names drive C (0: the current one).
pub fn fcbDriveOk(mem: *const Memory, fcb: u32) bool {
    const d = mem.rd8(fcb);
    return d == 0 or d == S.DRIVE_C + 1;
}

/// 11h/12h: the FCB find; the entry goes to the DTA as an FCB with the
/// directory entry (extended if the search's FCB was). AL 00h or FFh.
pub fn fcbFind(st: *State, r: *Regs, mem: *Memory, host: Host, first: bool) void {
    if (first) {
        const parts = fcbParts(mem, r.base[regs.DS] +% r.dx());
        if (!fcbDriveOk(mem, parts.fcb)) return r.setAl(0xFF);
        const slot = switch (start(st, host, st.cwdPath(), fcbName(mem, parts.fcb), parts.attr)) {
            .ok => |x| x,
            .err => return r.setAl(0xFF),
        };
        st.fcb_slot = slot;
        st.fcb_gen = st.searches[slot].gen;
        st.fcb_index = 0;
        st.fcb_ext = parts.ext;
    }
    if (st.fcb_slot >= S.MAX_SEARCH or st.searches[st.fcb_slot].gen != st.fcb_gen) return r.setAl(0xFF);
    const f = next(st, host, st.fcb_slot, &st.fcb_index) orelse return r.setAl(0xFF);
    var at = dta(st);
    if (st.fcb_ext) {
        mem.wr8(at, 0xFF);
        var i: u32 = 1;
        while (i < 6) : (i += 1) mem.wr8(at + i, 0);
        mem.wr8(at + 6, st.searches[st.fcb_slot].attr);
        at += 7;
    }
    mem.wr8(at, S.DRIVE_C + 1);
    mem.copyIn(at + 1, &f.fcb);
    mem.wr8(at + 12, f.attr);
    var i: u32 = 13;
    while (i < 23) : (i += 1) mem.wr8(at + i, 0);
    mem.wr16(at + 23, f.time);
    mem.wr16(at + 25, f.date);
    mem.wr16(at + 27, 0);
    mem.wr32(at + 29, f.size);
    r.setAl(0);
}
