//! Processes: the PSP (int 20h at 0, the memory top, the far call at 5,
//! the int 22h-24h addresses, the parent, the 20-handle job file table,
//! the environment, the int 21h far call at 50h, the FCBs, the command
//! tail at 80h), the environment block (the strings, then 0001h and the
//! program's full path), loading (mz.sig) into the memory DOS gives it,
//! exec (4Bh: 00h load and run, 01h load, 03h overlay, 05h), and the
//! end of a process (00h, 4Ch, int 20h, 31h's TSR) back to its parent.
//!
//! Exec and exit switch processes without help from the machine: both run
//! inside int 21h's ROM stub, whose IRET pops IP, CS and FLAGS at SS:SP.
//! Exec points SS:SP at a frame it writes on the child's stack (the
//! child's CS:IP, interrupts on), so the IRET starts the child with its
//! own SS:SP; exit restores the parent's registers as they were at its
//! exec call, SS:SP at the frame its INT 21h pushed, with CS:IP there set
//! to the child's int 22h address, so the IRET returns to the parent.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");
const Host = host_mod.Host;
const S = @import("dos_state.sig");
const State = S.State;
const path = @import("dos_path.sig");
const mcb = @import("dos_mem.sig");
const file = @import("dos_file.sig");
const fcb_mod = @import("dos_fcb.sig");
const con = @import("dos_con.sig");
const mz = @import("mz.sig");
const E = file.E;

/// The environment a program started from Galaxy gets (then 0001h and
/// its path).
pub const DEFAULT_ENV = "COMSPEC=C:\\COMMAND.COM\x00PATH=C:\\\x00PROMPT=$P$G\x00BLASTER=A220 I5 D1 H5 T6\x00";
const ENV_MAX: u32 = 0x8000;

/// A PSP at `psp`:0, the block's end at `top`.
pub fn makePsp(mem: *Memory, psp: u16, top: u16, parent: u16, env: u16) void {
    const at = Memory.lin(psp, 0);
    var i: u32 = 0;
    while (i < 0x100) : (i += 1) mem.wr8(at + i, 0);
    mem.wr16(at + 0x00, 0x20CD);
    mem.wr16(at + 0x02, top);
    // The CP/M call (to the wrapped address DOS puts there).
    mem.wr8(at + 0x05, 0x9A);
    mem.wr16(at + 0x06, 0xFEF0);
    mem.wr16(at + 0x08, 0xF01D);
    mem.wr32(at + 0x0A, mem.rd32(0x22 * 4));
    mem.wr32(at + 0x0E, mem.rd32(0x23 * 4));
    mem.wr32(at + 0x12, mem.rd32(0x24 * 4));
    mem.wr16(at + 0x16, parent);
    i = 0;
    while (i < S.JFT_SIZE) : (i += 1) mem.wr8(at + 0x18 + i, 0xFF);
    mem.wr16(at + 0x2C, env);
    mem.wr16(at + 0x32, S.JFT_SIZE);
    mem.wr16(at + 0x34, 0x0018);
    mem.wr16(at + 0x36, psp);
    mem.wr32(at + 0x38, 0xFFFF_FFFF);
    mem.wr16(at + 0x40, 0x0005);
    mem.copyIn(at + 0x50, &.{ 0xCD, 0x21, 0xCB });
    // Two blank FCBs, an empty tail.
    i = 0;
    while (i < 11) : (i += 1) {
        mem.wr8(at + 0x5D + i, ' ');
        mem.wr8(at + 0x6D + i, ' ');
    }
    mem.wr8(at + 0x81, 0x0D);
}

/// The environment's strings' length, the closing empty string included.
fn envLen(mem: *const Memory, seg: u16) u32 {
    const at = Memory.lin(seg, 0);
    if (mem.rd8(at) == 0) return 1;
    var i: u32 = 1;
    while (i < ENV_MAX) : (i += 1) {
        if (mem.rd8(at + i) == 0 and mem.rd8(at + i - 1) == 0) return i + 1;
    }
    return 0;
}

/// A block with the environment's strings (copied from `src`'s, or the
/// defaults when `src` is 0), 0001h and `prog`, owned by `owner`.
fn makeEnv(st: *State, mem: *Memory, src: u16, prog: []const u8, owner: u16) error{ Environment, Memory }!u16 {
    const n: u32 = if (src == 0) DEFAULT_ENV.len + 1 else envLen(mem, src);
    if (n == 0) return error.Environment;
    const total = n + 2 + @as(u32, @intCast(prog.len)) + 1;
    const paras: u16 = @intCast((total + 15) / 16);
    const seg = mcb.alloc(st, mem, paras, owner) catch return error.Memory;
    const at = Memory.lin(seg, 0);
    if (src == 0) {
        mem.copyIn(at, DEFAULT_ENV);
        mem.wr8(at + @as(u32, DEFAULT_ENV.len), 0);
    } else {
        const from = Memory.lin(src, 0);
        var i: u32 = 0;
        while (i < n) : (i += 1) mem.wr8(at + i, mem.rd8(from + i));
    }
    mem.wr16(at + n, 1);
    mem.copyIn(at + n + 2, prog);
    mem.wr8(at + n + 2 + @as(u32, @intCast(prog.len)), 0);
    return seg;
}

pub const Tail = union(enum) {
    /// At a linear address: a count byte, the characters, CR.
    at: u32,
    bytes: []const u8,
};

/// FFFF:FFFF, a parameter block's "no FCB".
const NO_FCB: u32 = Memory.lin(0xFFFF, 0xFFFF);

pub const Fcbs = union(enum) {
    /// Copied from these two addresses (16 bytes each).
    at: [2]u32,
    /// Parsed from the tail, as COMMAND.COM makes them.
    parse,
};

pub const Loaded = struct {
    psp: u16 = 0,
    cs: u16 = 0,
    ip: u16 = 0,
    ss: u16 = 0,
    sp: u16 = 0,
    ax: u16 = 0,
};

pub const LoadResult = union(enum) {
    ok: Loaded,
    err: u16,
};

/// Loads a program (`p`: the DOS path as given) as a child of the current
/// PSP: its environment, its memory, its PSP with the tail and FCBs.
pub fn load(st: *State, mem: *Memory, host: Host, p: []const u8, env_src: u16, tail: Tail, fcbs: Fcbs) LoadResult {
    var cb: [S.DOS_PATH]u8 = undefined;
    var hp: path.HostPath = .{};
    const canon = path.map(st, host, p, &cb, &hp) catch |e| return .{ .err = path.code(e) };
    if (!hp.exists or hp.dir or path.device(canon) != null) return .{ .err = E.not_found };
    var info: host_mod.Stat = .{};
    if (!host.stat(hp.str(), &info)) return .{ .err = E.not_found };
    const fd = host.open(hp.str(), .{ .read = true });
    if (fd < 0) return .{ .err = S.hostErr(fd) };
    defer host.close(fd);
    const img = mz.inspect(host, fd, info.size) catch return .{ .err = E.format };

    // "C:\" + the canonical path: the environment's last string.
    var full: [S.DOS_PATH + 3]u8 = undefined;
    @memcpy(full[0..3], "C:\\");
    @memcpy(full[3..][0..canon.len], canon);
    const prog = full[0 .. 3 + canon.len];

    const env = makeEnv(st, mem, env_src, prog, 0xFFFF) catch |e| return .{ .err = switch (e) {
        error.Environment => E.environment,
        error.Memory => E.memory,
    } };
    // The program's block: the largest free one, cut to what it asks for.
    const big: u32 = mcb.largest(st, mem);
    const need: u32 = 0x10 + (if (img.exe) img.paras + img.min_extra else (img.size + 0x100 + 15) / 16 + 0x10);
    if (big < need) {
        mcb.free(st, mem, env) catch {};
        return .{ .err = E.memory };
    }
    var want: u32 = big;
    if (img.exe and !img.high()) want = @min(big, 0x10 + img.paras + img.max_extra);
    want = @max(want, need);
    const psp = mcb.alloc(st, mem, @intCast(want), 0xFFFF) catch {
        mcb.free(st, mem, env) catch {};
        return .{ .err = E.memory };
    };
    const top: u16 = psp +% @as(u16, @intCast(want));
    mcb.setOwner(mem, psp, psp);
    mcb.setOwner(mem, env, psp);
    const name = path.split(canon).name;
    const base = if (std.mem.indexOfScalar(u8, name, '.')) |i| name[0..i] else name;
    mcb.setName(mem, psp, base);

    var out: Loaded = .{ .psp = psp };
    if (img.exe) {
        const seg: u16 = if (img.high()) top -% @as(u16, @intCast(img.paras)) else psp + 0x10;
        mz.load(host, fd, mem, &img, seg, seg) catch {
            mcb.freeOwned(st, mem, psp);
            return .{ .err = E.format };
        };
        out.cs = seg +% img.cs;
        out.ip = img.ip;
        out.ss = seg +% img.ss;
        out.sp = img.sp;
    } else {
        mz.load(host, fd, mem, &img, psp + 0x10, 0) catch {
            mcb.freeOwned(st, mem, psp);
            return .{ .err = E.format };
        };
        out.cs = psp;
        out.ip = 0x100;
        out.ss = psp;
        // The stack at the segment's top (or the block's), a 0 word on it
        // so a RET goes to int 20h at PSP:0.
        out.sp = if (want >= 0x1000) 0xFFFE else @intCast(want * 16 - 2);
        mem.wrW(psp, out.sp, 0);
    }

    makePsp(mem, psp, top, st.psp, env);
    file.inherit(st, mem, st.psp, psp);
    const pa = Memory.lin(psp, 0);
    switch (tail) {
        .at => |src| {
            const n = @min(mem.rd8(src), 126);
            mem.wr8(pa + 0x80, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) mem.wr8(pa + 0x81 + i, mem.rd8(src + 1 + i));
            mem.wr8(pa + 0x81 + n, 0x0D);
        },
        .bytes => |b| {
            const n: u32 = @intCast(@min(b.len, 126));
            mem.wr8(pa + 0x80, @intCast(n));
            mem.copyIn(pa + 0x81, b[0..n]);
            mem.wr8(pa + 0x81 + n, 0x0D);
        },
    }
    switch (fcbs) {
        .at => |a| {
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                if (a[0] != NO_FCB) mem.wr8(pa + 0x5C + i, mem.rd8(a[0] + i));
                if (a[1] != NO_FCB) mem.wr8(pa + 0x6C + i, mem.rd8(a[1] + i));
            }
        },
        .parse => {
            const p1 = fcb_mod.parse(mem, pa + 0x81, pa + 0x5C, 0x01);
            _ = fcb_mod.parse(mem, pa + 0x81 + p1.len, pa + 0x6C, 0x01);
        },
    }
    const d1 = mem.rd8(pa + 0x5C);
    const d2 = mem.rd8(pa + 0x6C);
    const ok1: u16 = if (d1 == 0 or d1 == S.DRIVE_C + 1) 0 else 0xFF;
    const ok2: u16 = if (d2 == 0 or d2 == S.DRIVE_C + 1) 0 else 0xFF;
    out.ax = ok2 << 8 | ok1;
    return .{ .ok = out };
}

/// The registers a new program starts with (as DOS 5 leaves them).
fn entryRegs(r: *Regs, l: *const Loaded) void {
    r.setAx(l.ax);
    r.setBx(0);
    r.setCx(0x00FF);
    r.setDx(l.psp);
    r.setSi(l.ip);
    r.setDi(l.sp);
    r.set16(regs.EBP, 0x091C);
    r.setSeg(regs.DS, l.psp);
    r.setSeg(regs.ES, l.psp);
}

/// Loads the first program, a child of the shell, and points the CPU at
/// it (`tail`: its command line after the name).
pub fn start(st: *State, r: *Regs, mem: *Memory, host: Host, p: []const u8, tail: []const u8) ?u16 {
    st.psp = st.shell;
    var tb: [127]u8 = undefined;
    var n: usize = 0;
    if (tail.len > 0 and tail[0] != ' ' and tail[0] != '\t') {
        tb[0] = ' ';
        n = 1;
    }
    const k = @min(tail.len, tb.len - n);
    @memcpy(tb[n..][0..k], tail[0..k]);
    n += k;
    const env_src = mem.rdW(st.shell, 0x2C);
    const l = switch (load(st, mem, host, p, env_src, .{ .bytes = tb[0..n] }, .parse)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    // Its end is the shell's: PSP:0Ah points at the shell's int 20h.
    mem.wrW(l.psp, 0x0A, 0x0000);
    mem.wrW(l.psp, 0x0C, st.shell);
    entryRegs(r, &l);
    r.setSeg(regs.CS, l.cs);
    r.eip = l.ip;
    r.setSeg(regs.SS, l.ss);
    r.set16(regs.ESP, l.sp);
    r.flags = regs.FIXED | regs.IF;
    st.psp = l.psp;
    st.dta_seg = l.psp;
    st.dta_off = 0x80;
    return null;
}

/// 4Bh: exec.
pub fn exec(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    var pb: [S.DOS_PATH]u8 = undefined;
    const p = mem.cstr(r.base[regs.DS] +% r.dx(), &pb);
    const blk = r.base[regs.ES] +% r.bx();
    switch (r.al()) {
        0x00, 0x01 => {
            if (r.al() == 0 and st.depth >= S.MAX_DEPTH) return st.fail(r, E.memory);
            const env = mem.rd16(blk);
            const tail = S.farLin(mem, blk + 2);
            const f1 = S.farLin(mem, blk + 6);
            const f2 = S.farLin(mem, blk + 10);
            const l = switch (load(st, mem, host, p, if (env == 0) mem.rdW(st.psp, 0x2C) else env, .{ .at = tail }, .{ .at = .{ f1, f2 } })) {
                .ok => |x| x,
                .err => |e| return st.fail(r, e),
            };
            // The parent's stack at its call, and where it returns to.
            const frame = r.base[regs.SS] +% r.sp();
            mem.wrW(st.psp, 0x2E, r.sp());
            mem.wrW(st.psp, 0x30, r.seg[regs.SS]);
            mem.wrW(l.psp, 0x0A, mem.rd16(frame));
            mem.wrW(l.psp, 0x0C, mem.rd16(frame + 2));
            if (r.al() == 0x01) {
                // Load only: SS:SP (the first AX on that stack) and CS:IP
                // for the caller, who now runs as the child's parent.
                const sp = l.sp -% 2;
                mem.wrW(l.ss, sp, l.ax);
                mem.wr16(blk + 0x0E, sp);
                mem.wr16(blk + 0x10, l.ss);
                mem.wr16(blk + 0x12, l.ip);
                mem.wr16(blk + 0x14, l.cs);
                st.psp = l.psp;
                st.dta_seg = l.psp;
                st.dta_off = 0x80;
                return r.ok();
            }
            st.frames[st.depth] = .{ .regs = r.*, .psp = st.psp, .child = l.psp, .dta_seg = st.dta_seg, .dta_off = st.dta_off };
            st.depth += 1;
            entryRegs(r, &l);
            // The IRET frame on the child's stack.
            const sp = l.sp -% 6;
            mem.wrW(l.ss, sp, l.ip);
            mem.wrW(l.ss, sp +% 2, l.cs);
            mem.wrW(l.ss, sp +% 4, @truncate(regs.FIXED | regs.IF));
            r.setSeg(regs.SS, l.ss);
            r.set16(regs.ESP, sp);
            st.psp = l.psp;
            st.dta_seg = l.psp;
            st.dta_off = 0x80;
            r.ok();
        },
        0x03 => {
            var cb: [S.DOS_PATH]u8 = undefined;
            var hp: path.HostPath = .{};
            _ = path.map(st, host, p, &cb, &hp) catch |e| return st.fail(r, path.code(e));
            var info: host_mod.Stat = .{};
            if (!hp.exists or hp.dir or !host.stat(hp.str(), &info)) return st.fail(r, E.not_found);
            const fd = host.open(hp.str(), .{ .read = true });
            if (fd < 0) return st.fail(r, S.hostErr(fd));
            defer host.close(fd);
            var img = mz.inspect(host, fd, info.size) catch |e| switch (e) {
                // (an overlay may be larger than a COM file may)
                error.Format => mz.Image{ .size = @intCast(@min(info.size, 0xA0000)), .paras = 0 },
                error.Read => return st.fail(r, E.format),
            };
            if (!img.exe) img.file_off = 0;
            mz.load(host, fd, mem, &img, mem.rd16(blk), mem.rd16(blk + 2)) catch return st.fail(r, E.format);
            r.ok();
        },
        // Set the execution state (DOS 5): nothing to keep.
        0x05 => r.ok(),
        else => st.fail(r, E.function),
    }
}

/// The current process ends with `code` (`kind`: 0 normal, 3 TSR keeping
/// `keep` paragraphs). The first program's end is the machine's.
pub fn terminate(st: *State, r: *Regs, mem: *Memory, host: Host, code: u8, kind: u8, keep: u16) void {
    const child = st.psp;
    const parent = mem.rdW(child, 0x16);
    st.return_code = (@as(u16, kind) << 8) | code;
    if (child == st.shell or parent == child or parent == st.shell or parent == 0) {
        con.flushLog(st, host);
        st.exited = true;
        st.exit_code = code;
        return;
    }
    // int 22h-24h as the child's PSP keeps them.
    var v: u32 = 0;
    while (v < 3) : (v += 1) mem.wr32((0x22 + v) * 4, mem.rd32(Memory.lin(child, 0) + 0x0A + v * 4));
    if (kind == 3) {
        var max: u16 = 0;
        mcb.resize(st, mem, child, @max(keep, 6), &max) catch {};
    } else {
        file.closeAll(st, mem, host, child);
        mcb.freeOwned(st, mem, child);
    }
    const ret_ip = mem.rdW(child, 0x0A);
    const ret_cs = mem.rdW(child, 0x0C);
    st.psp = parent;
    if (st.depth > 0 and st.frames[st.depth - 1].child == child) {
        st.depth -= 1;
        const f = st.frames[st.depth];
        const eip = r.eip;
        const cs = r.seg[regs.CS];
        const flags = r.flags;
        r.* = f.regs;
        r.eip = eip;
        r.setSeg(regs.CS, cs);
        r.flags = flags;
        st.dta_seg = f.dta_seg;
        st.dta_off = f.dta_off;
    } else {
        // (a child of exec 01h: the parent's stack at its last call)
        r.set16(regs.ESP, mem.rdW(parent, 0x2E));
        r.setSeg(regs.SS, mem.rdW(parent, 0x30));
        r.setSeg(regs.DS, parent);
        r.setSeg(regs.ES, parent);
        st.dta_seg = parent;
        st.dta_off = 0x80;
    }
    const frame = r.base[regs.SS] +% r.sp();
    mem.wr16(frame, ret_ip);
    mem.wr16(frame + 2, ret_cs);
    r.ok();
}
