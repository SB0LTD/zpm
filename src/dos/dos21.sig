//! DOS itself, written in Sig (a DOS 5.0 as programs see it): int 20h,
//! 21h (console I/O through the BIOS, files and handles with SFT-like
//! state over the host's files, FCB functions programs of the era still
//! use, find first/next with the DTA, directories, drives (C: is a folder
//! of the host's; A:, B:, D: and E: hold nothing), memory blocks (the MCB
//! chain, allocate/free/resize, UMB link off), the PSP and the
//! environment, exec (load and run, load only, overlay), exit codes and
//! TSRs, date and time, IOCTL (device info, removable, remote, the EMM's
//! control data), the country info, the InDOS flag and the list of
//! lists), 2Fh (XMS's 4300h/4310h, 1600h "no Windows", 1680h, DPMI's
//! 1687h "none"). MZ and COM programs (mz.sig). The parts:
//!
//!   dos_state.sig  the state; DOS's data in conventional memory
//!   dos_mem.sig    the MCB chain
//!   dos_path.sig   DOS paths to the host's real names, 8.3 aliases
//!   dos_file.sig   the SFT, handles, IOCTL, folders
//!   dos_find.sig   find first/next
//!   dos_fcb.sig    FCBs, 29h
//!   dos_proc.sig   PSPs, the environment, exec, exit
//!   dos_con.sig    the console
//!
//! Written from Microsoft's MS-DOS programmer's reference and Ralf
//! Brown's Interrupt List; no DOS's code.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");
const Host = host_mod.Host;
const bios = @import("bios.sig");
const S = @import("dos_state.sig");
const mcb = @import("dos_mem.sig");
const path = @import("dos_path.sig");
const file = @import("dos_file.sig");
const find = @import("dos_find.sig");
const fcb = @import("dos_fcb.sig");
const proc = @import("dos_proc.sig");
const con = @import("dos_con.sig");
const E = file.E;

pub const MAX_HANDLES = S.MAX_HANDLES;
pub const State = S.State;

/// The XMS driver's entry, F000:XMS_ENTRY (machine.sig's).
pub const XMS_SEG: u16 = 0xF000;
pub const XMS_ENTRY: u16 = 0x0F00;

/// DOS at boot: the MCB chain over conventional memory from `first_seg`
/// to `top_seg` (its last paragraph), DOS's data block, the shell's PSP
/// and environment, the standard handles (CON), drive C: at the host's
/// `c_root` folder; the BIOS's tick count from the host's clock.
pub fn boot(st: *State, mem: *Memory, host: Host, c_root: []const u8, first_seg: u16, top_seg: u16) void {
    var root = c_root;
    while (root.len > 1 and root[root.len - 1] == '/') root = root[0 .. root.len - 1];
    const n = @min(root.len, S.PATH_MAX);
    @memcpy(st.root[0..n], root[0..n]);
    st.root_len = @intCast(n);
    st.cwd_len = 0;
    file.initSystem(st);
    bios.setClock(mem, host.now());

    mcb.initChain(st, mem, first_seg, top_seg + 1);
    st.dseg = mcb.alloc(st, mem, S.D_PARAS, mcb.OWNER_DOS) catch unreachable;
    mcb.setName(mem, st.dseg, "SD");
    writeData(st, mem);

    // The shell: a PSP that is its own parent, its environment after it.
    const shell = mcb.alloc(st, mem, 0x10, 0xFFFF) catch unreachable;
    const env_paras: u16 = (proc.DEFAULT_ENV.len + 1 + 15) / 16;
    const env = mcb.alloc(st, mem, env_paras, shell) catch unreachable;
    mem.copyIn(Memory.lin(env, 0), proc.DEFAULT_ENV);
    mem.wr8(Memory.lin(env, proc.DEFAULT_ENV.len), 0);
    mcb.setOwner(mem, shell, shell);
    mcb.setName(mem, shell, "COMMAND");
    proc.makePsp(mem, shell, shell + 0x10, shell, env);
    file.standardJft(mem, shell);
    st.shell = shell;
    st.psp = shell;
    st.dta_seg = shell;
    st.dta_off = 0x80;
}

fn far(mem: *Memory, at: u32, seg: u16, off: u16) void {
    mem.wr16(at, off);
    mem.wr16(at + 2, seg);
}

fn device(mem: *Memory, at: u32, next_seg: u16, next_off: u16, attr: u16, retf: u16, name: []const u8) void {
    far(mem, at, next_seg, next_off);
    mem.wr16(at + 4, attr);
    mem.wr16(at + 6, retf);
    mem.wr16(at + 8, retf);
    var i: u32 = 0;
    while (i < 8) : (i += 1) mem.wr8(at + 10 + i, if (i < name.len) name[i] else ' ');
}

/// Code page 437's lower-case letters above 7Fh and their capitals.
const upper437 = [_][2]u8{
    .{ 0x81, 0x9A }, .{ 0x82, 0x90 }, .{ 0x83, 'A' }, .{ 0x84, 0x8E }, .{ 0x85, 'A' },
    .{ 0x86, 0x8F }, .{ 0x87, 0x80 }, .{ 0x88, 'E' }, .{ 0x89, 'E' }, .{ 0x8A, 'E' },
    .{ 0x8B, 'I' },  .{ 0x8C, 'I' },  .{ 0x8D, 'I' }, .{ 0x91, 0x92 }, .{ 0x93, 'O' },
    .{ 0x94, 0x99 }, .{ 0x95, 'O' },  .{ 0x96, 'U' }, .{ 0x97, 'U' },  .{ 0x98, 'Y' },
    .{ 0xA0, 'A' },  .{ 0xA1, 'I' },  .{ 0xA2, 'O' }, .{ 0xA3, 'U' },  .{ 0xA4, 0xA5 },
};

fn upperTable(mem: *Memory, at: u32) void {
    mem.wr16(at, 128);
    var c: u32 = 0;
    while (c < 128) : (c += 1) mem.wr8(at + 2 + c, @intCast(0x80 + c));
    for (upper437) |p| mem.wr8(at + 2 + p[0] - 0x80, p[1]);
}

/// DOS's data block: the InDOS flag, the list of lists, the devices, the
/// drive's DPB and CDS, the country tables, the SFT's header.
fn writeData(st: *State, mem: *Memory) void {
    const seg = st.dseg;
    const base = Memory.lin(seg, 0);
    var i: u32 = 0;
    while (i < @as(u32, S.D_PARAS) * 16) : (i += 1) mem.wr8(base + i, 0);
    mem.wr8(base + S.D_RETF, 0xCB);
    mem.wr8(base + S.D_MEDIA, 0xF8);

    // The list of lists (DOS 5's layout).
    const lol = base + S.D_LOL;
    mem.wr16(lol - 2, st.first_mcb);
    far(mem, lol + 0x00, seg, S.D_DPB);
    far(mem, lol + 0x04, seg, S.D_SFT);
    far(mem, lol + 0x08, seg, S.D_CLOCK);
    far(mem, lol + 0x0C, seg, S.D_CON);
    mem.wr16(lol + 0x10, 512);
    far(mem, lol + 0x12, 0xFFFF, 0xFFFF);
    far(mem, lol + 0x16, seg, S.D_CDS);
    far(mem, lol + 0x1A, 0xFFFF, 0xFFFF);
    mem.wr8(lol + 0x20, 3);
    mem.wr8(lol + 0x21, S.LASTDRIVE);
    mem.wr16(lol + 0x3F, 20);
    mem.wr8(lol + 0x43, S.DRIVE_C + 1);
    mem.wr8(lol + 0x44, 1);
    mem.wr16(lol + 0x45, 15 * 1024);

    // The device chain: NUL, CON, CLOCK$, and the EMM when int 67h's
    // vector's segment holds its header.
    const emm_seg = mem.rdW(0, 0x67 * 4 + 2);
    var emm_name: [8]u8 = undefined;
    mem.copyOut(Memory.lin(emm_seg, 0x0A), &emm_name);
    const have_emm = std.mem.eql(u8, &emm_name, "EMMXXXX0");
    device(mem, base + S.D_NUL, seg, S.D_CON, 0x8004, S.D_RETF, "NUL");
    device(mem, base + S.D_CON, seg, S.D_CLOCK, 0x8013, S.D_RETF, "CON");
    device(mem, base + S.D_CLOCK, if (have_emm) emm_seg else 0xFFFF, if (have_emm) 0 else 0xFFFF, 0x8008, S.D_RETF, "CLOCK$");

    // Drive C:'s DPB: 512-byte sectors, 64 to a cluster (as a 2 GB FAT16
    // volume would be; the host's free space is not asked).
    const dpb = base + S.D_DPB;
    mem.wr8(dpb + 0x00, S.DRIVE_C);
    mem.wr8(dpb + 0x01, S.DRIVE_C);
    mem.wr16(dpb + 0x02, 512);
    mem.wr8(dpb + 0x04, 63);
    mem.wr8(dpb + 0x05, 6);
    mem.wr16(dpb + 0x06, 1);
    mem.wr8(dpb + 0x08, 2);
    mem.wr16(dpb + 0x09, 512);
    mem.wr16(dpb + 0x0B, 545);
    mem.wr16(dpb + 0x0D, 65001);
    mem.wr16(dpb + 0x0F, 256);
    mem.wr16(dpb + 0x11, 513);
    far(mem, dpb + 0x13, seg, S.D_NUL);
    mem.wr8(dpb + 0x17, 0xF8);
    far(mem, dpb + 0x19, 0xFFFF, 0xFFFF);
    mem.wr16(dpb + 0x1F, 32000);

    // The CDS: A: to E:, only C: a physical drive.
    var d: u32 = 0;
    while (d < S.LASTDRIVE) : (d += 1) {
        const at = base + S.D_CDS + d * S.CDS_SIZE;
        mem.wr8(at, @intCast('A' + d));
        mem.copyIn(at + 1, ":\\");
        mem.wr16(at + 0x43, if (d == S.DRIVE_C) 0x4000 else 0);
        if (d == S.DRIVE_C) far(mem, at + 0x45, seg, S.D_DPB);
        far(mem, at + 0x4B, 0xFFFF, 0xFFFF);
        mem.wr16(at + 0x4F, 2);
    }
    file.writeCds(st, mem);

    // Country tables (65h): upper case, file names' upper case, the file
    // name terminators, the collating order; DBCS: none.
    upperTable(mem, base + S.D_UPPER);
    upperTable(mem, base + S.D_FUPPER);
    const illegal = ".\"/\\[]:|<>+=;,";
    const ft = base + S.D_FTERM;
    mem.wr16(ft, 8 + illegal.len);
    mem.copyIn(ft + 2, &.{ 0x01, 0x00, 0xFF, 0x00, 0x00, 0x20, 0x02, illegal.len });
    mem.copyIn(ft + 10, illegal);
    const co = base + S.D_COLLATE;
    mem.wr16(co, 256);
    var c: u32 = 0;
    while (c < 256) : (c += 1) mem.wr8(co + 2 + c, path.upper(@intCast(c)));
    for (upper437) |p| mem.wr8(co + 2 + p[0], p[1]);

    // The SFT's header (its entries are DOS's own, in Sig).
    far(mem, base + S.D_SFT, 0xFFFF, 0xFFFF);
    mem.wr16(base + S.D_SFT + 4, S.SFT_FILES);
}

/// Loads `path` (a DOS path: "C:\\ALADDIN.EXE") with its command tail as
/// the first program, its PSP and environment made, and sets the CPU's
/// CS:IP, SS:SP, DS, ES to start it; null, or the DOS error.
pub fn start(st: *State, r: *Regs, mem: *Memory, host: Host, p: []const u8, tail: []const u8) ?u16 {
    return proc.start(st, r, mem, host, p, tail);
}

/// The bytes console output wrote since the last call (for a machine that
/// sets `st.tty_direct = false` and hands them to int 10h's teletype).
pub fn conDrain(st: *State, buf: []u8) usize {
    return con.drain(st, buf);
}

fn lin(r: *const Regs, s: u3, off: u16) u32 {
    return r.base[s] +% off;
}

/// int 21h: false when the call must wait for a key (01h, 07h, 08h, 0Ah,
/// 0Ch with those, 3Fh on CON): the machine runs it again after the next
/// interrupt. (Reads and writes that touch video memory need int21Bus.)
pub fn int21(st: *State, r: *Regs, mem: *Memory, host: Host) bool {
    return int21Bus(st, r, mem, host, @import("dos_bus.sig").MemBus{ .mem = mem });
}

/// int 21h with `bus` (the machine) for 3Fh/40h buffers in the adapter
/// area: a game that reads a picture straight into A000:0 gets it there.
pub fn int21Bus(st: *State, r: *Regs, mem: *Memory, host: Host, bus: anytype) bool {
    switch (r.ah()) {
        // The ends of a process. The first program's end returns false: the
        // CPU stops on the trap and the machine sees `exited`.
        0x00 => {
            proc.terminate(st, r, mem, host, 0, 0, 0);
            return !st.exited;
        },
        0x01 => {
            const c = con.getChar(st, mem) orelse return false;
            con.out(st, mem, host, c);
            r.setAl(c);
        },
        0x02 => {
            con.out(st, mem, host, r.dl());
            r.setAl(r.dl());
        },
        0x03 => r.setAl(0),
        0x04, 0x05 => {},
        0x06 => {
            if (r.dl() == 0xFF) {
                if (con.getChar(st, mem)) |c| {
                    r.setAl(c);
                    r.setFlag(regs.ZF, false);
                } else {
                    r.setAl(0);
                    r.setFlag(regs.ZF, true);
                }
            } else {
                con.out(st, mem, host, r.dl());
                r.setAl(r.dl());
            }
        },
        0x07, 0x08 => r.setAl(con.getChar(st, mem) orelse return false),
        0x09 => {
            const at = lin(r, regs.DS, r.dx());
            var i: u32 = 0;
            while (i < 0x10000) : (i += 1) {
                const c = mem.rd8(at + i);
                if (c == '$') break;
                con.out(st, mem, host, c);
            }
            r.setAl('$');
        },
        0x0A => {
            const at = lin(r, regs.DS, r.dx());
            const max = mem.rd8(at);
            if (max == 0) return true;
            if (!con.lineInput(st, mem, host, max - 1)) return false;
            mem.wr8(at + 1, st.line_len);
            mem.copyIn(at + 2, st.line[0..st.line_len]);
            mem.wr8(at + 2 + @as(u32, st.line_len), 0x0D);
        },
        0x0B => r.setAl(if (con.ready(st, mem)) 0xFF else 0x00),
        0x0C => {
            if (!st.flushing) {
                con.flushInput(st, mem);
                st.flushing = true;
            }
            const sub = r.al();
            switch (sub) {
                0x01, 0x06, 0x07, 0x08, 0x0A => {
                    r.setAh(sub);
                    const done = int21Bus(st, r, mem, host, bus);
                    if (!done) {
                        r.setAh(0x0C);
                        r.setAl(sub);
                        return false;
                    }
                },
                else => {},
            }
            st.flushing = false;
        },
        0x0D => r.ok(),
        0x0E => r.setAl(S.LASTDRIVE),
        0x0F => fcb.open(st, r, mem, host, false),
        0x10 => fcb.close(st, r, mem, host),
        0x11 => find.fcbFind(st, r, mem, host, true),
        0x12 => find.fcbFind(st, r, mem, host, false),
        0x13 => fcb.delete(st, r, mem, host),
        0x14 => fcb.sequential(st, r, mem, host, false),
        0x15 => fcb.sequential(st, r, mem, host, true),
        0x16 => fcb.open(st, r, mem, host, true),
        0x17 => fcb.rename(st, r, mem, host),
        0x18, 0x1D, 0x1E, 0x20 => r.setAl(0),
        0x19 => r.setAl(S.DRIVE_C),
        0x1A => {
            st.dta_seg = r.seg[regs.DS];
            st.dta_off = r.dx();
        },
        0x1B, 0x1C => {
            if (r.ah() == 0x1C and r.dl() != 0 and r.dl() != S.DRIVE_C + 1) {
                r.setAl(0xFF);
                return true;
            }
            r.setAl(64);
            r.setCx(512);
            r.setDx(65000);
            r.setSeg(regs.DS, st.dseg);
            r.setBx(S.D_MEDIA);
        },
        0x1F, 0x32 => {
            if (r.ah() == 0x32 and r.dl() != 0 and r.dl() != S.DRIVE_C + 1) {
                r.setAl(0xFF);
                return true;
            }
            r.setSeg(regs.DS, st.dseg);
            r.setBx(S.D_DPB);
            r.setAl(0);
        },
        0x21 => fcb.random(st, r, mem, host, false),
        0x22 => fcb.random(st, r, mem, host, true),
        0x23 => fcb.fileSize(st, r, mem, host),
        0x24 => fcb.setRandomRecord(r, mem),
        0x25 => {
            const v = @as(u32, r.al()) * 4;
            mem.wr16(v, r.dx());
            mem.wr16(v + 2, r.seg[regs.DS]);
        },
        0x26 => {
            const to = Memory.lin(r.dx(), 0);
            const from = Memory.lin(st.psp, 0);
            var i: u32 = 0;
            while (i < 0x100) : (i += 1) mem.wr8(to + i, mem.rd8(from + i));
            mem.wr32(to + 0x0A, mem.rd32(0x22 * 4));
            mem.wr32(to + 0x0E, mem.rd32(0x23 * 4));
            mem.wr32(to + 0x12, mem.rd32(0x24 * 4));
        },
        0x27 => fcb.block(st, r, mem, host, false),
        0x28 => fcb.block(st, r, mem, host, true),
        0x29 => fcb.parseName(r, mem),
        0x2A => {
            const t = host.now();
            r.setCx(t.year);
            r.setDh(t.month);
            r.setDl(t.day);
            r.setAl(t.weekday);
        },
        0x2C => {
            const t = host.now();
            r.setCh(t.hour);
            r.setCl(t.minute);
            r.setDh(t.second);
            r.setDl(t.hundredths);
        },
        // Setting the date or time: taken (the host's clock stays).
        0x2B, 0x2D => r.setAl(0),
        0x2E => st.verify = r.al() != 0,
        0x2F => {
            r.setSeg(regs.ES, st.dta_seg);
            r.setBx(st.dta_off);
        },
        0x30 => {
            const al = r.al();
            r.setAx(0x0005);
            r.setBh(if (al == 1) 0x00 else 0xFF);
            r.setBl(0);
            r.setCx(0);
        },
        0x31 => {
            proc.terminate(st, r, mem, host, r.al(), 3, r.dx());
            return !st.exited;
        },
        0x33 => switch (r.al()) {
            0x00 => r.setDl(@intFromBool(st.break_on)),
            0x01 => st.break_on = r.dl() != 0,
            0x02 => {
                const was = st.break_on;
                st.break_on = r.dl() != 0;
                r.setDl(@intFromBool(was));
            },
            0x05 => r.setDl(S.DRIVE_C + 1),
            0x06 => {
                r.setBx(0x0005);
                r.setDx(0);
            },
            else => r.setAl(0xFF),
        },
        0x34 => {
            r.setSeg(regs.ES, st.dseg);
            r.setBx(S.D_INDOS);
        },
        0x35 => {
            const v = @as(u32, r.al()) * 4;
            r.setBx(mem.rd16(v));
            r.setSeg(regs.ES, mem.rd16(v + 2));
        },
        0x36 => {
            const d = r.dl();
            if (d != 0 and d != S.DRIVE_C + 1) {
                r.setAx(0xFFFF);
                return true;
            }
            r.setAx(64);
            r.setBx(32000);
            r.setCx(512);
            r.setDx(65000);
        },
        0x37 => switch (r.al()) {
            0x00 => {
                r.setDl('/');
                r.setAl(0);
            },
            0x01 => r.setAl(0),
            0x02, 0x03 => r.setDl(0xFF),
            else => r.setAl(0xFF),
        },
        0x38 => country(st, r, mem),
        0x39 => file.mkdir(st, r, mem, host, true),
        0x3A => file.mkdir(st, r, mem, host, false),
        0x3B => file.chdir(st, r, mem, host),
        0x3C => file.create(st, r, mem, host),
        0x3D => file.open(st, r, mem, host),
        0x3E => file.close(st, r, mem, host),
        0x3F => return file.read(st, r, mem, host, bus),
        0x40 => file.write(st, r, mem, host, bus),
        0x41 => file.unlink(st, r, mem, host),
        0x42 => file.seek(st, r, mem, host),
        0x43 => file.attributes(st, r, mem, host),
        0x44 => file.ioctl(st, r, mem, host),
        0x45 => file.dup(st, r, mem),
        0x46 => file.dup2(st, r, mem, host),
        0x47 => file.getcwd(st, r, mem),
        0x48 => {
            const seg = mcb.alloc(st, mem, r.bx(), st.psp) catch |e| {
                if (e == error.NoMemory) r.setBx(mcb.largest(st, mem));
                st.fail(r, if (e == error.NoMemory) E.memory else E.mcb);
                return true;
            };
            r.setAx(seg);
            r.ok();
        },
        0x49 => {
            mcb.free(st, mem, r.seg[regs.ES]) catch {
                st.fail(r, E.block);
                return true;
            };
            r.ok();
        },
        0x4A => {
            var max: u16 = 0;
            mcb.resize(st, mem, r.seg[regs.ES], r.bx(), &max) catch |e| {
                if (e == error.NoMemory) r.setBx(max);
                st.fail(r, switch (e) {
                    error.NoMemory => E.memory,
                    error.BadBlock => E.block,
                    error.Corrupt => E.mcb,
                });
                return true;
            };
            r.ok();
        },
        0x4B => proc.exec(st, r, mem, host),
        0x4C => {
            proc.terminate(st, r, mem, host, r.al(), 0, 0);
            return !st.exited;
        },
        0x4D => {
            r.setAx(st.return_code);
            st.return_code = 0;
            r.ok();
        },
        0x4E => find.findFirst(st, r, mem, host),
        0x4F => find.findNext(st, r, mem, host),
        0x50 => st.psp = r.bx(),
        0x51, 0x62 => r.setBx(st.psp),
        0x52 => {
            r.setSeg(regs.ES, st.dseg);
            r.setBx(S.D_LOL);
        },
        0x54 => r.setAl(@intFromBool(st.verify)),
        0x55 => {
            const child = r.dx();
            proc.makePsp(mem, child, r.si(), st.psp, mem.rdW(st.psp, 0x2C));
            file.inherit(st, mem, st.psp, child);
            st.psp = child;
        },
        0x56 => file.rename(st, r, mem, host),
        0x57 => file.dateTime(st, r, mem, host),
        0x58 => switch (r.al()) {
            0x00 => {
                r.setAx(st.strategy);
                r.ok();
            },
            0x01 => {
                st.strategy = @truncate(r.bx());
                r.ok();
            },
            0x02 => {
                r.setAl(0);
                r.ok();
            },
            0x03 => if (r.bx() == 0) r.ok() else st.fail(r, E.function),
            else => st.fail(r, E.function),
        },
        0x59 => {
            r.setAx(st.last_error);
            r.setBh(st.last_class);
            r.setBl(st.last_action);
            r.setCh(st.last_locus);
        },
        0x5A => file.createTemp(st, r, mem, host),
        0x5B => file.createNew(st, r, mem, host),
        // Record locks: there is no one to share with.
        0x5C => r.ok(),
        0x5D => if (r.al() == 0x0A) r.ok() else st.fail(r, E.function),
        // No network.
        0x5E, 0x5F => st.fail(r, E.function),
        0x60 => truename(st, r, mem, host),
        0x63 => {
            r.setSeg(regs.DS, st.dseg);
            r.setSi(S.D_DBCS + 2);
            r.setAl(0);
        },
        0x65 => extCountry(st, r, mem),
        0x66 => switch (r.al()) {
            0x01 => {
                r.setBx(437);
                r.setDx(437);
                r.ok();
            },
            0x02 => r.ok(),
            else => st.fail(r, E.function),
        },
        0x67 => file.handleCount(st, r, mem),
        0x68, 0x6A => r.ok(),
        0x69 => switch (r.al()) {
            0x00 => {
                const at = lin(r, regs.DS, r.dx());
                mem.wr16(at, 0);
                mem.wr32(at + 2, 0x1994_1111);
                mem.copyIn(at + 6, find.LABEL);
                mem.copyIn(at + 17, "FAT16   ");
                r.ok();
            },
            0x01 => r.ok(),
            else => st.fail(r, E.function),
        },
        0x6C => file.extOpen(st, r, mem, host),
        // Long file names (Windows 95's 71h): not here.
        0x71 => st.fail(r, 0x7100),
        else => {
            if (!st.told[r.ah()]) {
                st.told[r.ah()] = true;
                host.say("dos: int 21h ah={x:0>2} al={x:0>2} not implemented", .{ r.ah(), r.al() });
            }
            st.fail(r, E.function);
        },
    }
    return true;
}

/// 38h's 34 bytes (the United States').
fn countryInfo(st: *const State, mem: *Memory, at: u32) void {
    var i: u32 = 0;
    while (i < 34) : (i += 1) mem.wr8(at + i, 0);
    mem.wr16(at + 0x00, 0);
    mem.copyIn(at + 0x02, "$");
    mem.copyIn(at + 0x07, ",");
    mem.copyIn(at + 0x09, ".");
    mem.copyIn(at + 0x0B, "-");
    mem.copyIn(at + 0x0D, ":");
    mem.wr8(at + 0x0F, 0);
    mem.wr8(at + 0x10, 2);
    mem.wr8(at + 0x11, 0);
    far(mem, at + 0x12, st.dseg, S.D_RETF);
    mem.copyIn(at + 0x16, ",");
}

fn country(st: *State, r: *Regs, mem: *Memory) void {
    if (r.dx() == 0xFFFF) return r.ok();
    countryInfo(st, mem, lin(r, regs.DS, r.dx()));
    r.setBx(1);
    r.setAx(1);
    r.ok();
}

/// 65h: the extended country information and the case functions.
fn extCountry(st: *State, r: *Regs, mem: *Memory) void {
    const at = lin(r, regs.ES, r.di());
    switch (r.al()) {
        0x01 => {
            mem.wr8(at, 1);
            mem.wr16(at + 1, 38);
            mem.wr16(at + 3, 1);
            mem.wr16(at + 5, 437);
            countryInfo(st, mem, at + 7);
            r.setCx(41);
        },
        0x02, 0x04, 0x05, 0x06, 0x07 => {
            const off: u16 = switch (r.al()) {
                0x02 => S.D_UPPER,
                0x04 => S.D_FUPPER,
                0x05 => S.D_FTERM,
                0x06 => S.D_COLLATE,
                else => S.D_DBCS,
            };
            mem.wr8(at, r.al());
            far(mem, at + 1, st.dseg, off);
            r.setCx(5);
        },
        0x20 => r.setDl(upcase(mem, st, r.dl())),
        0x21, 0x22 => {
            const s = lin(r, regs.DS, r.dx());
            var i: u32 = 0;
            while (if (r.al() == 0x21) i < r.cx() else mem.rd8(s + i) != 0) : (i += 1) mem.wr8(s + i, upcase(mem, st, mem.rd8(s + i)));
        },
        0x23 => {
            const c = upcase(mem, st, r.dl());
            r.setAx(if (c == 'Y') 1 else if (c == 'N') 0 else 2);
        },
        else => return st.fail(r, E.function),
    }
    r.ok();
}

fn upcase(mem: *const Memory, st: *const State, c: u8) u8 {
    if (c < 0x80) return path.upper(c);
    return mem.rdB(st.dseg, S.D_UPPER + 2 + @as(u16, c - 0x80));
}

/// 60h: a path's canonical form ("C:\DIR\FILE.EXT"; a device "C:/CON").
fn truename(st: *State, r: *Regs, mem: *Memory, host: Host) void {
    _ = host;
    var pb: [S.DOS_PATH]u8 = undefined;
    const p = mem.cstr(lin(r, regs.DS, r.si()), &pb);
    var cb: [S.DOS_PATH]u8 = undefined;
    const canon = path.canonical(st, p, &cb) catch |e| return st.fail(r, path.code(e));
    const at = lin(r, regs.ES, r.di());
    if (path.device(canon) != null) {
        mem.copyIn(at, "C:/");
        const name = path.split(canon).name;
        const base = if (std.mem.indexOfScalar(u8, name, '.')) |i| name[0..i] else name;
        mem.copyIn(at + 3, base);
        mem.wr8(at + 3 + @as(u32, @intCast(base.len)), 0);
    } else {
        mem.copyIn(at, "C:\\");
        mem.copyIn(at + 3, canon);
        mem.wr8(at + 3 + @as(u32, @intCast(canon.len)), 0);
    }
    r.ok();
}

/// int 2Fh (the multiplex interrupt).
pub fn int2f(st: *State, r: *Regs, mem: *Memory) void {
    _ = st;
    _ = mem;
    switch (r.ax()) {
        // XMS: installed, its entry point.
        0x4300 => r.setAl(0x80),
        0x4310 => {
            r.setSeg(regs.ES, XMS_SEG);
            r.setBx(XMS_ENTRY);
        },
        // No Windows (AL 00h); the time slice release answered (AL 00h).
        0x1600, 0x1680 => r.setAl(0),
        // DPMI (1687h): AX left non-zero = none.
        // DOS not in the HMA: no free HMA to give (4A01h, 4A02h).
        0x4A01, 0x4A02 => {
            r.setBx(0);
            r.setSeg(regs.ES, 0xFFFF);
            r.setDi(0xFFFF);
        },
        else => {},
    }
}

/// int 24h (the critical error handler a program has not replaced): fail
/// the call (AL 03h). The machine calls it for the vector's ROM stub.
pub fn int24(r: *Regs) void {
    r.setAl(0x03);
}

test {
    _ = @import("dos_test.sig");
    // Every declaration of DOS's parts analysed, used by a test or not.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(S);
    std.testing.refAllDecls(mcb);
    std.testing.refAllDecls(path);
    std.testing.refAllDecls(file);
    std.testing.refAllDecls(find);
    std.testing.refAllDecls(fcb);
    std.testing.refAllDecls(proc);
    std.testing.refAllDecls(con);
    std.testing.refAllDecls(@import("mz.sig"));
}
