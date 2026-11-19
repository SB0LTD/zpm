//! DOS's handles over the host's files: the system file table (`st.sft`:
//! the host's handle, the access mode, references from every PSP's job
//! file table), the JFT in each PSP (20 entries, or the table 67h made),
//! and the handle functions: create, open, close, read, write, seek,
//! delete, attributes, IOCTL, dup, rename, date and time, temporary and
//! new files, the extended open; the directory functions (mkdir, rmdir,
//! chdir, getcwd). Files are the host's; CON, NUL, AUX, PRN, CLOCK$ and
//! EMMXXXX0 are devices whatever folder or extension names them.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");
const Host = host_mod.Host;
const S = @import("dos_state.sig");
const State = S.State;
const Sft = S.Sft;
const path = @import("dos_path.sig");
const con = @import("dos_con.sig");
const bus_mod = @import("dos_bus.sig");

/// DOS's errors, as their codes.
pub const E = struct {
    pub const function: u16 = 0x01;
    pub const not_found: u16 = 0x02;
    pub const path_not_found: u16 = 0x03;
    pub const too_many: u16 = 0x04;
    pub const denied: u16 = 0x05;
    pub const handle: u16 = 0x06;
    pub const mcb: u16 = 0x07;
    pub const memory: u16 = 0x08;
    pub const block: u16 = 0x09;
    pub const environment: u16 = 0x0A;
    pub const format: u16 = 0x0B;
    pub const access: u16 = 0x0C;
    pub const data: u16 = 0x0D;
    pub const drive: u16 = 0x0F;
    pub const current_dir: u16 = 0x10;
    pub const no_more: u16 = 0x12;
    pub const exists: u16 = 0x50;
};

// ── The tables ───────────────────────────────────────────────────────────

pub fn jftLin(mem: *const Memory, psp: u16) u32 {
    return S.farLin(mem, Memory.lin(psp, 0x34));
}
pub fn jftSize(mem: *const Memory, psp: u16) u16 {
    return mem.rdW(psp, 0x32);
}

/// The SFT entry a handle of the current PSP stands for.
pub fn sftOf(st: *const State, mem: *const Memory, handle: u16) ?u8 {
    if (handle >= jftSize(mem, st.psp)) return null;
    const i = mem.rd8(jftLin(mem, st.psp) + handle);
    if (i >= S.MAX_HANDLES or st.sft[i].kind == .free) return null;
    return i;
}

/// The first standard entries (AUX, CON, PRN): always there.
pub const SYSTEM = 3;

pub fn newSft(st: *State) ?u8 {
    var i: u8 = SYSTEM;
    while (i < S.MAX_HANDLES) : (i += 1) {
        if (st.sft[i].kind == .free) {
            st.sft[i] = .{};
            return i;
        }
    }
    return null;
}

pub fn retain(st: *State, i: u8) void {
    if (i >= SYSTEM) st.sft[i].refs +|= 1;
}

/// One reference fewer; the last closes the host's file.
pub fn release(st: *State, host: Host, i: u8) void {
    if (i < SYSTEM or i >= S.MAX_HANDLES) return;
    const s = &st.sft[i];
    if (s.kind == .free) return;
    s.refs -|= 1;
    if (s.refs > 0) return;
    if (s.kind == .file and s.fd >= 0) host.close(s.fd);
    s.* = .{};
}

/// A free handle of the current PSP for SFT entry `i`; null: none (the
/// caller releases `i`).
pub fn bind(st: *State, mem: *Memory, i: u8) ?u16 {
    const n = jftSize(mem, st.psp);
    const at = jftLin(mem, st.psp);
    var h: u16 = 0;
    while (h < n) : (h += 1) {
        if (mem.rd8(at + h) == 0xFF) {
            mem.wr8(at + h, i);
            return h;
        }
    }
    return null;
}

/// Closes every handle of PSP `psp` (a process ending).
pub fn closeAll(st: *State, mem: *Memory, host: Host, psp: u16) void {
    const n = jftSize(mem, psp);
    const at = jftLin(mem, psp);
    var h: u16 = 0;
    while (h < n) : (h += 1) {
        const i = mem.rd8(at + h);
        if (i != 0xFF) {
            release(st, host, i);
            mem.wr8(at + h, 0xFF);
        }
    }
}

/// A child's JFT from its parent's: the inheritable handles, referenced
/// once more.
pub fn inherit(st: *State, mem: *Memory, parent: u16, child: u16) void {
    const pn = jftSize(mem, parent);
    const pa = jftLin(mem, parent);
    const ca = jftLin(mem, child);
    var h: u16 = 0;
    while (h < S.JFT_SIZE) : (h += 1) {
        var i: u8 = 0xFF;
        if (h < pn) i = mem.rd8(pa + h);
        if (i != 0xFF and (i >= S.MAX_HANDLES or st.sft[i].kind == .free or st.sft[i].no_inherit)) i = 0xFF;
        if (i != 0xFF) retain(st, i);
        mem.wr8(ca + h, i);
    }
}

/// The JFT of a PSP made at boot: stdin, stdout, stderr on CON, stdaux on
/// AUX, stdprn on PRN.
pub fn standardJft(mem: *Memory, psp: u16) void {
    const at = jftLin(mem, psp);
    const std_handles = [_]u8{ 1, 1, 1, 0, 2 };
    var h: u16 = 0;
    while (h < S.JFT_SIZE) : (h += 1) mem.wr8(at + h, if (h < std_handles.len) std_handles[h] else 0xFF);
}

pub fn initSystem(st: *State) void {
    st.sft[0] = .{ .kind = .aux, .refs = 255, .access = 2 };
    st.sft[1] = .{ .kind = .con, .refs = 255, .access = 2 };
    st.sft[2] = .{ .kind = .prn, .refs = 255, .access = 1 };
}

/// IOCTL 00h's device information word.
pub fn deviceInfo(s: *const Sft) u16 {
    return switch (s.kind) {
        .con => 0x80D3 | @as(u16, if (s.raw) 0x20 else 0),
        .nul => 0x8084,
        .aux => 0x80C0,
        .prn => 0xA0C0,
        .clock => 0xC088,
        .emm => 0xC080,
        .file => S.DRIVE_C | @as(u16, if (s.written) 0 else 0x40),
        .free => 0,
    };
}

// ── Opening ──────────────────────────────────────────────────────────────

pub const How = struct {
    access: u2 = 0,
    create: bool = false,
    truncate: bool = false,
    /// Fail if it exists (5Bh, 5Ah, 6Ch's "fail" action).
    new: bool = false,
    /// Fail if it does not (3Dh).
    must_exist: bool = true,
    no_inherit: bool = false,
    attr: u8 = 0x20,
};

fn str(mem: *const Memory, at: u32, buf: []u8) []u8 {
    return mem.cstr(at, buf);
}

/// An SFT entry, or a DOS error code.
pub const Opened = union(enum) {
    ok: u8,
    err: u16,
};

/// Opens or creates a program's path. `existed`: whether the file was
/// there before.
pub fn openPath(st: *State, host: Host, p: []const u8, how: How, existed: ?*bool) Opened {
    const r = openInner(st, host, p, how, existed) catch |e| return .{ .err = errCode(e) };
    return .{ .ok = r };
}

const OpenErr = error{ NotFound, PathNotFound, TooMany, Denied, Exists, Host2, Host3, Host4, Host5, Host6, General };

fn errCode(e: OpenErr) u16 {
    return switch (e) {
        error.NotFound, error.Host2 => E.not_found,
        error.PathNotFound, error.Host3 => E.path_not_found,
        error.TooMany, error.Host4 => E.too_many,
        error.Denied, error.Host5 => E.denied,
        error.Host6 => E.handle,
        error.Exists => E.exists,
        error.General => 0x1F,
    };
}

fn pathErr(e: path.Err) OpenErr {
    return if (path.code(e) == 2) error.NotFound else error.PathNotFound;
}

fn hostOpenErr(fd: i32) OpenErr {
    return switch (S.hostErr(fd)) {
        2 => error.Host2,
        3 => error.Host3,
        4 => error.Host4,
        5 => error.Host5,
        6 => error.Host6,
        0x50 => error.Exists,
        else => error.General,
    };
}

fn openInner(st: *State, host: Host, p: []const u8, how: How, existed: ?*bool) OpenErr!u8 {
    var cbuf: [S.DOS_PATH]u8 = undefined;
    const canon = path.canonical(st, p, &cbuf) catch |e| return pathErr(e);
    if (path.device(canon)) |k| {
        const i = newSft(st) orelse return error.TooMany;
        st.sft[i] = .{ .kind = k, .refs = 1, .access = how.access, .no_inherit = how.no_inherit };
        if (existed) |x| x.* = true;
        return i;
    }
    if (path.toFcb(path.split(canon).name)) |f| {
        if (path.hasWild(f)) return error.NotFound;
    } else if (canon.len == 0) return error.Denied;
    var hp: path.HostPath = .{};
    path.resolve(st, host, canon, &hp) catch |e| return pathErr(e);
    if (existed) |x| x.* = hp.exists;
    if (hp.exists) {
        if (hp.dir) return error.Denied;
        if (how.new) return error.Exists;
        var s: host_mod.Stat = .{};
        if (host.stat(hp.str(), &s) and s.readonly and (how.access != 0 or how.truncate)) return error.Denied;
    } else if (!how.create) return error.NotFound;
    const fd = host.open(hp.str(), .{
        .read = true,
        .write = how.access != 0 or how.create or how.truncate,
        .create = how.create and !hp.exists,
        .truncate = how.truncate,
    });
    if (fd < 0) return hostOpenErr(fd);
    const i = newSft(st) orelse {
        host.close(fd);
        return error.TooMany;
    };
    const sft = &st.sft[i];
    sft.* = .{ .kind = .file, .refs = 1, .fd = fd, .access = how.access, .no_inherit = how.no_inherit, .attr = how.attr };
    @memcpy(sft.path[0..hp.len], hp.str());
    sft.path_len = hp.len;
    return i;
}

/// The SFT entry under a new handle, or the error (the entry let go).
fn handOut(st: *State, r: *Regs, mem: *Memory, host: Host, i: u8) void {
    const h = bind(st, mem, i) orelse {
        release(st, host, i);
        return st.fail(r, E.too_many);
    };
    r.setAx(h);
    r.ok();
}

fn pathArg(r: *const Regs, mem: *const Memory, seg: u3, off: u16, buf: []u8) []u8 {
    return str(mem, r.base[seg] +% off, buf);
}

/// 3Ch: create (CX: attributes).
pub fn create(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    var b: [S.DOS_PATH]u8 = undefined;
    const p = pathArg(r, mem, regs.DS, r.dx(), &b);
    const i = switch (openPath(st, host, p, .{ .access = 2, .create = true, .truncate = true, .must_exist = false, .attr = @truncate(r.cx()) }, null)) {
        .ok => |x| x,
        .err => |e| return st.fail(r, e),
    };
    handOut(st, r, mem, host, i);
}

/// 3Dh: open (AL: access, sharing, inheritance).
pub fn open(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const mode = r.al();
    if (mode & 0x07 > 2) return st.fail(r, E.access);
    var b: [S.DOS_PATH]u8 = undefined;
    const p = pathArg(r, mem, regs.DS, r.dx(), &b);
    const i = switch (openPath(st, host, p, .{ .access = @intCast(mode & 3), .no_inherit = mode & 0x80 != 0 }, null)) {
        .ok => |x| x,
        .err => |e| return st.fail(r, e),
    };
    handOut(st, r, mem, host, i);
}

/// 5Bh: create a file that must not exist.
pub fn createNew(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    var b: [S.DOS_PATH]u8 = undefined;
    const p = pathArg(r, mem, regs.DS, r.dx(), &b);
    const i = switch (openPath(st, host, p, .{ .access = 2, .create = true, .new = true, .must_exist = false, .attr = @truncate(r.cx()) }, null)) {
        .ok => |x| x,
        .err => |e| return st.fail(r, e),
    };
    handOut(st, r, mem, host, i);
}

/// 5Ah: a new file with a unique name in the folder DS:DX names (the name
/// appended there).
pub fn createTemp(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const at = r.base[regs.DS] +% r.dx();
    var b: [S.DOS_PATH]u8 = undefined;
    const dir = str(mem, at, b[0 .. S.DOS_PATH - 14]);
    var tries: u32 = 0;
    while (tries < 64) : (tries += 1) {
        st.temp_count +%= 1;
        var name: [16]u8 = undefined;
        const sep: []const u8 = if (dir.len == 0 or dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/' or dir[dir.len - 1] == ':') "" else "\\";
        const n = std.fmt.bufPrint(&name, "{s}GX{X:0>6}", .{ sep, st.temp_count }) catch unreachable;
        var full: [S.DOS_PATH]u8 = undefined;
        @memcpy(full[0..dir.len], dir);
        @memcpy(full[dir.len..][0..n.len], n);
        const i = switch (openPath(st, host, full[0 .. dir.len + n.len], .{ .access = 2, .create = true, .new = true, .must_exist = false }, null)) {
            .ok => |x| x,
            .err => |e| {
                if (e == E.exists) continue;
                return st.fail(r, e);
            },
        };
        mem.copyIn(at + @as(u32, @intCast(dir.len)), n);
        mem.wr8(at + @as(u32, @intCast(dir.len + n.len)), 0);
        return handOut(st, r, mem, host, i);
    }
    st.fail(r, E.denied);
}

/// 6Ch: the extended open (BX mode, CX attributes, DX action, DS:SI name);
/// CX the action taken (1 opened, 2 created, 3 replaced).
pub fn extOpen(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const mode = r.bx();
    const action = r.dx();
    if (mode & 0x07 > 2) return st.fail(r, E.access);
    var b: [S.DOS_PATH]u8 = undefined;
    const p = pathArg(r, mem, regs.DS, r.si(), &b);
    const if_exists = action & 0x0F;
    const if_missing = (action >> 4) & 0x0F;
    if (if_exists > 2 or if_missing > 1 or (if_exists == 0 and if_missing == 0)) return st.fail(r, E.function);
    var existed = false;
    const how: How = .{
        .access = @intCast(mode & 3),
        .no_inherit = mode & 0x80 != 0,
        .create = if_missing == 1,
        .truncate = if_exists == 2,
        .new = if_exists == 0,
        .must_exist = if_missing == 0,
        .attr = @truncate(r.cx()),
    };
    const i = switch (openPath(st, host, p, how, &existed)) {
        .ok => |x| x,
        .err => |e| return st.fail(r, e),
    };
    handOut(st, r, mem, host, i);
    if (!r.flag(regs.CF)) r.setCx(if (!existed) 2 else if (if_exists == 2) 3 else 1);
}

/// 3Eh: close.
pub fn close(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const h = r.bx();
    const i = sftOf(st, mem, h) orelse return st.fail(r, E.handle);
    release(st, host, i);
    mem.wr8(jftLin(mem, st.psp) + h, 0xFF);
    r.ok();
}

/// A file's bytes into memory the bus routes (video memory, the EMS
/// page frame): through a bounce buffer; the count read, or the error.
fn readVia(host: Host, fd: i32, bus: anytype, at: u32, want: u32) i32 {
    var buf: [2048]u8 = undefined;
    var done: u32 = 0;
    while (done < want) {
        const n = @min(want - done, buf.len);
        const got = host.read(fd, buf[0..n]);
        if (got < 0) return got;
        const g: u32 = @intCast(got);
        for (buf[0..g], 0..) |b, i| bus.wr8(at + done + @as(u32, @intCast(i)), b);
        done += g;
        if (g < n) break;
    }
    return @intCast(done);
}
fn writeVia(host: Host, fd: i32, bus: anytype, at: u32, n: u32) i32 {
    var buf: [2048]u8 = undefined;
    var done: u32 = 0;
    while (done < n) {
        const k = @min(n - done, buf.len);
        for (buf[0..k], 0..) |*b, i| b.* = bus.rd8(at + done + @as(u32, @intCast(i)));
        const put = host.write(fd, buf[0..k]);
        if (put < 0) return put;
        const p: u32 = @intCast(put);
        done += p;
        if (p < k) break;
    }
    return @intCast(done);
}

/// 3Fh: read; false while CON waits for its line. `bus`: the machine
/// (reads into video memory reach the VGA), or bus_mod.MemBus.
pub fn read(st: *State, r: *Regs, mem: *Memory, host: Host, bus: anytype) bool {
    const i = sftOf(st, mem, r.bx()) orelse {
        st.fail(r, E.handle);
        return true;
    };
    const s = &st.sft[i];
    const at = r.base[regs.DS] +% r.dx();
    const want: u32 = r.cx();
    if (s.access == 1) {
        st.fail(r, E.denied);
        return true;
    }
    switch (s.kind) {
        .file => {
            const got = if (bus_mod.touchesAdapter(at, want)) readVia(host, s.fd, bus, at, want) else host.read(s.fd, mem.bytes(at, want));
            if (got < 0) {
                st.fail(r, S.hostErr(got));
                return true;
            }
            r.setAx(@intCast(got));
        },
        .con => {
            if (s.raw) {
                var n: u32 = 0;
                while (n < want) : (n += 1) {
                    const c = con.getChar(st, mem) orelse break;
                    mem.wr8(at + n, c);
                }
                if (n == 0 and want > 0) return false;
                r.setAx(@intCast(n));
            } else {
                if (st.cin_pos >= st.cin_len) {
                    if (!con.lineInput(st, mem, host, 126)) return false;
                    @memcpy(st.cin[0..st.line_len], st.line[0..st.line_len]);
                    st.cin[st.line_len] = '\r';
                    st.cin[st.line_len + 1] = '\n';
                    st.cin_len = st.line_len + 2;
                    st.cin_pos = 0;
                    con.out(st, mem, host, '\n');
                }
                const n = @min(want, st.cin_len - st.cin_pos);
                mem.copyIn(at, st.cin[st.cin_pos..][0..n]);
                st.cin_pos += @intCast(n);
                r.setAx(@intCast(n));
            }
        },
        // NUL, the ports, the clock, the EMM: nothing to read.
        else => r.setAx(0),
    }
    r.ok();
    return true;
}

/// 40h: write (CX = 0 on a file: its size becomes the position).
pub fn write(st: *State, r: *Regs, mem: *Memory, host: Host, bus: anytype) void {
    const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
    const s = &st.sft[i];
    const at = r.base[regs.DS] +% r.dx();
    const n: u32 = r.cx();
    if (s.access == 0 and s.kind == .file) return st.fail(r, E.denied);
    switch (s.kind) {
        .file => {
            s.written = true;
            if (n == 0) {
                const pos = host.seek(s.fd, 0, .cur);
                if (pos < 0 or !host.truncate(s.fd, @intCast(pos))) return st.fail(r, E.denied);
                r.setAx(0);
            } else {
                const got = if (bus_mod.touchesAdapter(at, n)) writeVia(host, s.fd, bus, at, n) else host.write(s.fd, mem.bytes(at, n));
                if (got < 0) return st.fail(r, S.hostErr(got));
                r.setAx(@intCast(got));
            }
        },
        .con => {
            var k: u32 = 0;
            while (k < n) : (k += 1) con.out(st, mem, host, mem.rd8(at + k));
            r.setAx(@intCast(n));
        },
        else => r.setAx(@intCast(n)),
    }
    r.ok();
}

/// 41h: delete.
pub fn unlink(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    var b: [S.DOS_PATH]u8 = undefined;
    const p = pathArg(r, mem, regs.DS, r.dx(), &b);
    var cb: [S.DOS_PATH]u8 = undefined;
    var hp: path.HostPath = .{};
    _ = path.map(st, host, p, &cb, &hp) catch |e| return st.fail(r, path.code(e));
    if (!hp.exists) return st.fail(r, E.not_found);
    if (hp.dir) return st.fail(r, E.denied);
    var s: host_mod.Stat = .{};
    if (host.stat(hp.str(), &s) and s.readonly) return st.fail(r, E.denied);
    const rc = host.unlink(hp.str());
    if (rc < 0) return st.fail(r, S.hostErr(rc));
    r.ok();
}

/// 42h: seek (AL from the start, the position, the end; CX:DX signed);
/// DX:AX the new position.
pub fn seek(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
    if (r.al() > 2) return st.fail(r, E.function);
    const s = &st.sft[i];
    if (s.kind != .file) {
        r.setAx(0);
        r.setDx(0);
        return r.ok();
    }
    const raw: u32 = (@as(u32, r.cx()) << 16) | r.dx();
    const off: i64 = @as(i32, @bitCast(raw));
    const whence: host_mod.Whence = @enumFromInt(r.al());
    const pos = host.seek(s.fd, off, whence);
    if (pos < 0) return st.fail(r, 0x19);
    const p: u32 = @truncate(@as(u64, @intCast(pos)));
    r.setAx(@truncate(p));
    r.setDx(@intCast(p >> 16));
    r.ok();
}

/// The attribute byte of a host path.
fn attrOf(host: Host, hp: []const u8) ?u8 {
    var s: host_mod.Stat = .{};
    if (!host.stat(hp, &s)) return null;
    var a: u8 = if (s.dir) 0x10 else 0x20;
    if (s.readonly) a |= 0x01;
    return a;
}

/// 43h: get (00h) or set (01h) a file's attributes.
pub fn attributes(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    if (r.al() > 1) return st.fail(r, E.function);
    var b: [S.DOS_PATH]u8 = undefined;
    const p = pathArg(r, mem, regs.DS, r.dx(), &b);
    var cb: [S.DOS_PATH]u8 = undefined;
    var hp: path.HostPath = .{};
    const canon = path.map(st, host, p, &cb, &hp) catch |e| return st.fail(r, path.code(e));
    if (path.device(canon) != null) {
        if (r.al() == 0) r.setCx(0x40);
        return r.ok();
    }
    if (!hp.exists) return st.fail(r, E.not_found);
    if (r.al() == 0) {
        r.setCx(attrOf(host, hp.str()) orelse return st.fail(r, E.not_found));
        r.setAx(r.cx());
    }
    // (setting: taken; the host keeps its own permissions)
    r.ok();
}

/// 45h: a second handle for the same file.
pub fn dup(st: *State, r: *Regs, mem: *Memory) void {
    const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
    const h = bind(st, mem, i) orelse return st.fail(r, E.too_many);
    retain(st, i);
    r.setAx(h);
    r.ok();
}

/// 46h: handle CX becomes BX's (CX closed first if open).
pub fn dup2(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
    const to = r.cx();
    if (to >= jftSize(mem, st.psp)) return st.fail(r, E.handle);
    if (to == r.bx()) return r.ok();
    if (sftOf(st, mem, to)) |old| release(st, host, old);
    mem.wr8(jftLin(mem, st.psp) + to, i);
    retain(st, i);
    r.ok();
}

/// 56h: rename or move (DS:DX old, ES:DI new; one drive).
pub fn rename(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    var b1: [S.DOS_PATH]u8 = undefined;
    var b2: [S.DOS_PATH]u8 = undefined;
    const p1 = pathArg(r, mem, regs.DS, r.dx(), &b1);
    const p2 = pathArg(r, mem, regs.ES, r.di(), &b2);
    var c1: [S.DOS_PATH]u8 = undefined;
    var c2: [S.DOS_PATH]u8 = undefined;
    var h1: path.HostPath = .{};
    var h2: path.HostPath = .{};
    _ = path.map(st, host, p1, &c1, &h1) catch |e| return st.fail(r, path.code(e));
    if (!h1.exists) return st.fail(r, E.not_found);
    _ = path.map(st, host, p2, &c2, &h2) catch |e| return st.fail(r, path.code(e));
    if (h2.exists) return st.fail(r, E.denied);
    const rc = host.rename(h1.str(), h2.str());
    if (rc < 0) return st.fail(r, S.hostErr(rc));
    r.ok();
}

/// 57h: a handle's date and time (00h get: CX time, DX date; 01h set).
pub fn dateTime(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
    const s = &st.sft[i];
    switch (r.al()) {
        0x00 => {
            if (s.dt_set or s.kind != .file) {
                r.setCx(s.time);
                r.setDx(s.date);
            } else {
                var info: host_mod.Stat = .{};
                const dt = if (host.stat(s.hostPath(), &info)) S.dosDateTime(info.mtime) else S.dosDateTime(0);
                r.setCx(dt.time);
                r.setDx(dt.date);
            }
            r.ok();
        },
        0x01 => {
            s.dt_set = true;
            s.time = r.cx();
            s.date = r.dx();
            r.ok();
        },
        else => st.fail(r, E.function),
    }
}

/// 44h: IOCTL.
pub fn ioctl(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    switch (r.al()) {
        0x00 => {
            const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
            r.setDx(deviceInfo(&st.sft[i]));
            r.setAx(r.dx());
            r.ok();
        },
        0x01 => {
            const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
            const s = &st.sft[i];
            if (s.kind == .file) return st.fail(r, E.function);
            if (s.kind == .con) s.raw = r.dl() & 0x20 != 0;
            r.ok();
        },
        // Read control data: the EMM's (EMM386's subfunctions 0 and 2).
        0x02 => {
            const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
            if (st.sft[i].kind != .emm) return st.fail(r, E.function);
            const at = r.base[regs.DS] +% r.dx();
            switch (mem.rd8(at)) {
                0x00 => {
                    if (r.cx() < 6) return st.fail(r, E.data);
                    mem.wr16(at, 0x0025);
                    mem.wr32(at + 2, 0);
                    r.setAx(6);
                },
                0x02 => {
                    if (r.cx() < 2) return st.fail(r, E.data);
                    mem.wr8(at, 4);
                    mem.wr8(at + 1, 0);
                    r.setAx(2);
                },
                else => return st.fail(r, E.function),
            }
            r.ok();
        },
        0x03 => st.fail(r, E.function),
        0x06 => {
            const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
            const s = &st.sft[i];
            r.setAl(switch (s.kind) {
                .con => if (con.ready(st, mem)) 0xFF else 0x00,
                .file => blk: {
                    const pos = host.seek(s.fd, 0, .cur);
                    const end = host.seek(s.fd, 0, .end);
                    _ = host.seek(s.fd, pos, .set);
                    break :blk if (pos < end) 0xFF else 0x00;
                },
                .nul => 0x00,
                else => 0xFF,
            });
            r.ok();
        },
        0x07 => {
            _ = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
            r.setAl(0xFF);
            r.ok();
        },
        // Removable (08h): drive C is fixed; remote (09h, 0Ah): local.
        0x08 => {
            const d = r.bl();
            if (d != 0 and d != S.DRIVE_C + 1) return st.fail(r, E.drive);
            r.setAx(1);
            r.ok();
        },
        0x09 => {
            const d = r.bl();
            if (d != 0 and d != S.DRIVE_C + 1) return st.fail(r, E.drive);
            r.setDx(0x0040);
            r.ok();
        },
        0x0A => {
            const i = sftOf(st, mem, r.bx()) orelse return st.fail(r, E.handle);
            r.setDx(if (st.sft[i].kind == .file) 0 else 0x80);
            r.ok();
        },
        // Sharing retries: taken.
        0x0B => r.ok(),
        // The logical drive map: one letter per drive.
        0x0E, 0x0F => {
            const d = r.bl();
            if (d != 0 and d != S.DRIVE_C + 1) return st.fail(r, E.drive);
            r.setAl(0);
            r.ok();
        },
        else => st.fail(r, E.function),
    }
}

/// 67h: the handle count (a larger table in a block of the PSP's own).
pub fn handleCount(st: *State, r: *Regs, mem: *Memory) void {
    const want = r.bx();
    const have = jftSize(mem, st.psp);
    if (want <= S.JFT_SIZE) {
        // (shrinking below the open handles is refused as DOS refuses it)
        if (want < have) {
            var h: u16 = want;
            const at = jftLin(mem, st.psp);
            while (h < have) : (h += 1) if (mem.rd8(at + h) != 0xFF) return st.fail(r, E.too_many);
        }
        if (have > S.JFT_SIZE) {
            const old = jftLin(mem, st.psp);
            var h: u16 = 0;
            while (h < S.JFT_SIZE) : (h += 1) mem.wrB(st.psp, 0x18 + h, mem.rd8(old + h));
            mem.wrW(st.psp, 0x34, 0x18);
            mem.wrW(st.psp, 0x36, st.psp);
        }
        mem.wrW(st.psp, 0x32, @max(want, S.JFT_SIZE));
        return r.ok();
    }
    if (want <= have) return r.ok();
    const paras: u16 = @intCast((@as(u32, want) + 15) / 16);
    const seg = @import("dos_mem.sig").alloc(st, mem, paras, st.psp) catch return st.fail(r, E.memory);
    const old = jftLin(mem, st.psp);
    const new = Memory.lin(seg, 0);
    var h: u16 = 0;
    while (h < want) : (h += 1) mem.wr8(new + h, if (h < have) mem.rd8(old + h) else 0xFF);
    mem.wrW(st.psp, 0x32, want);
    mem.wrW(st.psp, 0x34, 0);
    mem.wrW(st.psp, 0x36, seg);
    r.ok();
}

// ── Folders ──────────────────────────────────────────────────────────────

/// 39h mkdir, 3Ah rmdir.
pub fn mkdir(st: *State, r: *Regs, mem: *Memory, host: Host, make: bool) void {
    var b: [S.DOS_PATH]u8 = undefined;
    const p = pathArg(r, mem, regs.DS, r.dx(), &b);
    var cb: [S.DOS_PATH]u8 = undefined;
    var hp: path.HostPath = .{};
    const canon = path.map(st, host, p, &cb, &hp) catch |e| return st.fail(r, path.code(e));
    if (canon.len == 0) return st.fail(r, E.denied);
    if (make) {
        if (hp.exists) return st.fail(r, E.denied);
        if (canon.len > S.CWD_MAX) return st.fail(r, E.path_not_found);
        const rc = host.mkdir(hp.str());
        if (rc < 0) return st.fail(r, if (rc == -80) E.denied else S.hostErr(rc));
    } else {
        if (!hp.exists or !hp.dir) return st.fail(r, E.path_not_found);
        if (std.mem.eql(u8, canon, st.cwdPath())) return st.fail(r, E.current_dir);
        const rc = host.rmdir(hp.str());
        if (rc < 0) return st.fail(r, E.denied);
    }
    r.ok();
}

/// 3Bh: the current directory.
pub fn chdir(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    var b: [S.DOS_PATH]u8 = undefined;
    const p = pathArg(r, mem, regs.DS, r.dx(), &b);
    var cb: [S.DOS_PATH]u8 = undefined;
    const canon = path.canonical(st, p, &cb) catch return st.fail(r, E.path_not_found);
    var hp: path.HostPath = .{};
    path.resolveDir(st, host, canon, &hp) catch return st.fail(r, E.path_not_found);
    if (canon.len > S.CWD_MAX) return st.fail(r, E.path_not_found);
    @memcpy(st.cwd[0..canon.len], canon);
    st.cwd_len = @intCast(canon.len);
    writeCds(st, mem);
    r.ok();
}

/// The CDS's entry for C: ("C:\" and the current directory).
pub fn writeCds(st: *const State, mem: *Memory) void {
    const at = Memory.lin(st.dseg, S.D_CDS + S.CDS_SIZE * S.DRIVE_C);
    var i: u32 = 0;
    while (i < 67) : (i += 1) mem.wr8(at + i, 0);
    mem.copyIn(at, "C:\\");
    mem.copyIn(at + 3, st.cwdPath());
}

/// 47h: the current directory of drive DL (0 the current) at DS:SI.
pub fn getcwd(st: *State, r: *Regs, mem: *Memory) void {
    const d = r.dl();
    if (d != 0 and d != S.DRIVE_C + 1) return st.fail(r, E.drive);
    const at = r.base[regs.DS] +% r.si();
    mem.copyIn(at, st.cwdPath());
    mem.wr8(at + st.cwd_len, 0);
    r.setAx(0x0100);
    r.ok();
}
