//! Memory above 1 MiB, the two ways DOS programs ask for it:
//! XMS 3.0 (HIMEM's driver: the entry point int 2Fh/4310h gives, its
//! functions 00h-12h and the 32-bit 88h, 89h, 8Eh, 8Fh: version, the HMA,
//! A20, extended memory blocks, moves, locks; no UMBs) and EMS 4.0
//! (EMM386's int 67h, the "EMMXXXX0" device: status, the page frame at
//! E000h, pages, handles and their names, mapping 40h-54h, 57h-5Ah as
//! games use them; 55h/56h, 5Bh and 5Dh refused, no VCPI).
//!
//! Both carve their memory out of one pool above the HMA, in 16 KiB
//! units: an extended memory block is a run of units from the bottom, an
//! EMS handle's pages are single units from the top (as EMM386 takes its
//! pages from XMS), so each side sees what the other left. The EMS page
//! frame is mapped through `emsWindow`, which the machine's bus asks for
//! 0xE0000-0xEFFFF.
//!
//! Written from the XMS 3.0 and LIM EMS 4.0 specifications; no driver's
//! code.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const mem_mod = @import("mem.sig");
const Memory = mem_mod.Memory;
const bus_mod = @import("dos_bus.sig");

/// The EMS page frame's segment, its four 16 KiB physical pages.
pub const FRAME: u16 = 0xE000;
pub const FRAME_PAGES = 4;
/// The pool's unit (an EMS page).
pub const UNIT: u32 = 16 * 1024;
pub const MAX_UNITS = mem_mod.RAM / UNIT;
pub const MAX_XMS = 64;
pub const MAX_EMS = 64;
/// Where the device header puts int 67h's entry (dev_seg:INT67_STUB).
pub const INT67_STUB: u16 = 0x0014;

const FREE: u8 = 0;
const EMS_OWNER: u8 = 0x80;

const Emb = struct {
    used: bool = false,
    first: u16 = 0,
    count: u16 = 0,
    kb: u32 = 0,
    locks: u8 = 0,
};

const Map = struct {
    handle: u8 = 0xFF,
    page: u16 = 0,
};

const EmsHandle = struct {
    used: bool = false,
    pages: u16 = 0,
    name: [8]u8 = [_]u8{0} ** 8,
    saved: bool = false,
    save: [FRAME_PAGES]Map = [_]Map{.{}} ** FRAME_PAGES,
};

pub const State = struct {
    /// The pool: `units` units from `base`.
    base: u32 = 0,
    units: u16 = 0,
    /// Each unit's owner: FREE, an XMS handle (1..MAX_XMS), or EMS_OWNER
    /// | an EMS handle; for EMS, the logical page it is.
    owner: [MAX_UNITS]u8 = [_]u8{FREE} ** MAX_UNITS,
    lpage: [MAX_UNITS]u16 = [_]u16{0} ** MAX_UNITS,
    emb: [MAX_XMS]Emb = [_]Emb{.{}} ** MAX_XMS,
    hma_used: bool = false,
    a20_global: bool = false,
    a20_local: u16 = 0,
    ems: [MAX_EMS]EmsHandle = [_]EmsHandle{.{}} ** MAX_EMS,
    map: [FRAME_PAGES]Map = [_]Map{.{}} ** FRAME_PAGES,
    /// The mapped pages' RAM addresses (0: nothing mapped).
    window: [FRAME_PAGES]u32 = [_]u32{0} ** FRAME_PAGES,
    dev_seg: u16 = 0,

    pub fn reset(self: *State) void {
        self.* = .{};
    }
    /// Where 0xE0000 + `off` (off < 0x10000) lives in RAM, or null if
    /// that 16 KiB window maps no page.
    pub inline fn emsWindow(self: *const State, off: u32) ?u32 {
        const w = self.window[(off >> 14) & 3];
        if (w == 0) return null;
        return w + (off & 0x3FFF);
    }

    fn unitAddr(self: *const State, u: u32) u32 {
        return self.base + u * UNIT;
    }
    fn freeUnits(self: *const State) u32 {
        var n: u32 = 0;
        for (self.owner[0..self.units]) |o| {
            if (o == FREE) n += 1;
        }
        return n;
    }
    /// The longest run of free units: its first unit and length.
    fn largestRun(self: *const State) struct { first: u32, len: u32 } {
        var best_first: u32 = 0;
        var best: u32 = 0;
        var run: u32 = 0;
        var i: u32 = 0;
        while (i < self.units) : (i += 1) {
            if (self.owner[i] == FREE) {
                run += 1;
                if (run > best) {
                    best = run;
                    best_first = i + 1 - run;
                }
            } else run = 0;
        }
        return .{ .first = best_first, .len = best };
    }
    /// The first run of `n` free units from the bottom.
    fn findRun(self: *const State, n: u32) ?u32 {
        if (n == 0) return 0;
        var run: u32 = 0;
        var i: u32 = 0;
        while (i < self.units) : (i += 1) {
            if (self.owner[i] == FREE) {
                run += 1;
                if (run == n) return i + 1 - n;
            } else run = 0;
        }
        return null;
    }
    /// The unit holding EMS handle `h`'s logical page `p`.
    fn emsUnit(self: *const State, h: u8, p: u16) ?u32 {
        const o = EMS_OWNER | h;
        var i: u32 = 0;
        while (i < self.units) : (i += 1) {
            if (self.owner[i] == o and self.lpage[i] == p) return i;
        }
        return null;
    }
};

/// Sets up both over RAM from `from` (the first byte above the HMA) to
/// `to`, and puts the EMS device header ("EMMXXXX0" at +0Ah) at `dev_seg`:0
/// with int 67h's entry in it: int 67h's vector is pointed there, so a
/// program that checks the vector's segment for the name finds it.
pub fn boot(st: *State, mem: *Memory, from: u32, to: u32, dev_seg: u16) void {
    st.base = from;
    st.units = @intCast(@min((to -| from) / UNIT, MAX_UNITS));
    st.dev_seg = dev_seg;
    // EMS handle 0 is the system's (no pages).
    st.ems[0].used = true;
    const d = Memory.lin(dev_seg, 0);
    mem.wr32(d + 0x00, 0xFFFF_FFFF); // next device: none
    mem.wr16(d + 0x04, 0xC000); // a character device with IOCTL
    mem.wr16(d + 0x06, 0x0012); // strategy and interrupt: RETF
    mem.wr16(d + 0x08, 0x0012);
    mem.copyIn(d + 0x0A, "EMMXXXX0");
    mem.wr8(d + 0x12, 0xCB);
    // int 67h's entry: STI; FE 38 67 (the service); IRET.
    mem.copyIn(d + INT67_STUB, &.{ 0xFB, 0xFE, 0x38, 0x67, 0xCF });
    mem.wrW(0, 0x67 * 4, INT67_STUB);
    mem.wrW(0, 0x67 * 4 + 2, dev_seg);
}

// ── XMS ──────────────────────────────────────────────────────────────────

fn xmsOk(r: *Regs) void {
    r.setAx(1);
    r.setBl(0);
}
fn xmsFail(r: *Regs, code: u8) void {
    r.setAx(0);
    r.setBl(code);
}

fn embOf(st: *State, handle: u16) ?*Emb {
    if (handle == 0 or handle > MAX_XMS) return null;
    const e = &st.emb[handle - 1];
    return if (e.used) e else null;
}

fn freeHandles(st: *const State) u16 {
    var n: u16 = 0;
    for (st.emb) |e| {
        if (!e.used) n += 1;
    }
    return n;
}

fn setA20(mem: *Memory, on: bool) void {
    mem.a20 = on;
}

/// The XMS driver's far entry point (called with AH = function).
pub fn xms(st: *State, r: *Regs, mem: *Memory) void {
    xmsBus(st, r, mem, bus_mod.MemBus{ .mem = mem });
}

/// The same, with `bus` for moves that touch the adapter area (the
/// machine; video memory and the EMS page frame are there).
pub fn xmsBus(st: *State, r: *Regs, mem: *Memory, bus: anytype) void {
    switch (r.ah()) {
        0x00 => {
            r.setAx(0x0300);
            r.setBx(0x0350);
            r.setDx(1); // the HMA exists
        },
        0x01 => {
            if (st.hma_used) return xmsFail(r, 0x91);
            st.hma_used = true;
            xmsOk(r);
        },
        0x02 => {
            if (!st.hma_used) return xmsFail(r, 0x93);
            st.hma_used = false;
            xmsOk(r);
        },
        0x03 => {
            st.a20_global = true;
            setA20(mem, true);
            xmsOk(r);
        },
        0x04 => {
            st.a20_global = false;
            if (st.a20_local > 0) return xmsFail(r, 0x94);
            setA20(mem, false);
            xmsOk(r);
        },
        0x05 => {
            st.a20_local +|= 1;
            setA20(mem, true);
            xmsOk(r);
        },
        0x06 => {
            if (st.a20_local > 0) st.a20_local -= 1;
            if (st.a20_local > 0 or st.a20_global) return xmsFail(r, 0x94);
            setA20(mem, false);
            xmsOk(r);
        },
        0x07 => {
            r.setAx(if (mem.a20) 1 else 0);
            r.setBl(0);
        },
        0x08 => {
            const big = st.largestRun().len * 16;
            const total = st.freeUnits() * 16;
            r.setAx(@intCast(@min(big, 0xFFFF)));
            r.setDx(@intCast(@min(total, 0xFFFF)));
            r.setBl(if (total == 0) 0xA0 else 0);
        },
        0x88 => {
            r.r[regs.EAX] = st.largestRun().len * 16;
            r.r[regs.EDX] = st.freeUnits() * 16;
            r.r[regs.ECX] = st.base + @as(u32, st.units) * UNIT - 1;
            r.setBl(if (r.r[regs.EDX] == 0) 0xA0 else 0);
        },
        0x09, 0x89 => {
            const kb: u32 = if (r.ah() == 0x09) r.dx() else r.r[regs.EDX];
            const h = allocEmb(st, kb) catch |e| return xmsFail(r, switch (e) {
                error.NoHandle => 0xA1,
                error.NoMemory => 0xA0,
            });
            r.setAx(1);
            r.setDx(h);
            r.setBl(0);
        },
        0x0A => {
            const e = embOf(st, r.dx()) orelse return xmsFail(r, 0xA2);
            if (e.locks > 0) return xmsFail(r, 0xAB);
            releaseUnits(st, e.first, e.count);
            e.* = .{};
            xmsOk(r);
        },
        0x0B => moveEmb(st, r, mem, bus),
        0x0C => {
            const e = embOf(st, r.dx()) orelse return xmsFail(r, 0xA2);
            if (e.locks == 0xFF) return xmsFail(r, 0xAC);
            e.locks += 1;
            const a = st.unitAddr(e.first);
            r.setAx(1);
            r.setDx(@intCast(a >> 16));
            r.setBx(@truncate(a));
        },
        0x0D => {
            const e = embOf(st, r.dx()) orelse return xmsFail(r, 0xA2);
            if (e.locks == 0) return xmsFail(r, 0xAA);
            e.locks -= 1;
            xmsOk(r);
        },
        0x0E, 0x8E => {
            const e = embOf(st, r.dx()) orelse return xmsFail(r, 0xA2);
            r.setAx(1);
            r.setBh(e.locks);
            if (r.ah() == 0x0E) {
                r.setBl(@intCast(@min(freeHandles(st), 0xFF)));
                r.setDx(@intCast(@min(e.kb, 0xFFFF)));
            } else {
                r.setCx(freeHandles(st));
                r.r[regs.EDX] = e.kb;
            }
        },
        0x0F, 0x8F => {
            const kb: u32 = if (r.ah() == 0x0F) r.bx() else r.r[regs.EBX];
            const e = embOf(st, r.dx()) orelse return xmsFail(r, 0xA2);
            if (!resizeEmb(st, mem, e, kb)) return xmsFail(r, if (e.locks > 0) 0xAB else 0xA0);
            xmsOk(r);
        },
        // No upper memory blocks.
        0x10 => {
            xmsFail(r, 0xB1);
            r.setDx(0);
        },
        0x11, 0x12 => xmsFail(r, 0xB2),
        else => xmsFail(r, 0x80),
    }
}

fn claim(st: *State, first: u32, n: u32, owner: u8) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) st.owner[first + i] = owner;
}
fn releaseUnits(st: *State, first: u32, n: u32) void {
    claim(st, first, n, FREE);
}

fn unitsFor(kb: u32) u32 {
    return (kb + 15) / 16;
}

fn allocEmb(st: *State, kb: u32) error{ NoHandle, NoMemory }!u16 {
    var slot: ?usize = null;
    for (&st.emb, 0..) |*e, i| if (!e.used) {
        slot = i;
        break;
    };
    const i = slot orelse return error.NoHandle;
    const n = unitsFor(kb);
    const first = st.findRun(n) orelse return error.NoMemory;
    claim(st, first, n, @intCast(i + 1));
    st.emb[i] = .{ .used = true, .first = @intCast(first), .count = @intCast(n), .kb = kb };
    return @intCast(i + 1);
}

fn resizeEmb(st: *State, mem: *Memory, e: *Emb, kb: u32) bool {
    const n = unitsFor(kb);
    const owner: u8 = @intCast((@intFromPtr(e) - @intFromPtr(&st.emb[0])) / @sizeOf(Emb) + 1);
    if (n <= e.count) {
        releaseUnits(st, e.first + n, e.count - n);
        e.count = @intCast(n);
        e.kb = kb;
        return true;
    }
    // Grow in place when the units after it are free.
    var room = true;
    var i: u32 = e.first + e.count;
    while (i < e.first + n) : (i += 1) {
        if (i >= st.units or st.owner[i] != FREE) {
            room = false;
            break;
        }
    }
    if (room) {
        claim(st, e.first + e.count, n - e.count, owner);
        e.count = @intCast(n);
        e.kb = kb;
        return true;
    }
    if (e.locks > 0) return false;
    // Move it: find a run with its own units counted free.
    releaseUnits(st, e.first, e.count);
    const first = st.findRun(n) orelse {
        claim(st, e.first, e.count, owner);
        return false;
    };
    const from = st.unitAddr(e.first);
    const to = st.unitAddr(first);
    const len = @as(u32, e.count) * UNIT;
    if (to <= from) std.mem.copyForwards(u8, mem.ram[to..][0..len], mem.ram[from..][0..len]) else std.mem.copyBackwards(u8, mem.ram[to..][0..len], mem.ram[from..][0..len]);
    claim(st, first, n, owner);
    e.first = @intCast(first);
    e.count = @intCast(n);
    e.kb = kb;
    return true;
}

/// 0Bh: the move structure at DS:SI (length, source handle and offset,
/// destination handle and offset; handle 0: the offset is seg:off).
fn moveEmb(st: *State, r: *Regs, mem: *Memory, bus: anytype) void {
    const p = r.base[regs.DS] +% r.si();
    const len = mem.rd32(p);
    const sh = mem.rd16(p + 4);
    const so = mem.rd32(p + 6);
    const dh = mem.rd16(p + 10);
    const do_ = mem.rd32(p + 12);
    if (len & 1 != 0) return xmsFail(r, 0xA7);
    const src = xmsAddr(st, sh, so, len) catch |e| return xmsFail(r, switch (e) {
        error.Handle => 0xA3,
        error.Offset => 0xA4,
        error.Length => 0xA7,
    });
    const dst = xmsAddr(st, dh, do_, len) catch |e| return xmsFail(r, switch (e) {
        error.Handle => 0xA5,
        error.Offset => 0xA6,
        error.Length => 0xA7,
    });
    const was = mem.a20;
    mem.a20 = true;
    const ok = bus_mod.copy(bus, mem, dst, src, len);
    mem.a20 = was;
    if (!ok) return xmsFail(r, 0xA7);
    xmsOk(r);
}

fn xmsAddr(st: *State, handle: u16, off: u32, len: u32) error{ Handle, Offset, Length }!u32 {
    if (handle == 0) {
        const a = (off >> 16) * 16 + (off & 0xFFFF);
        if (a +| len > mem_mod.HMA_END + 16) return error.Length;
        return a;
    }
    const e = embOf(st, handle) orelse return error.Handle;
    const size = e.kb * 1024;
    if (off > size) return error.Offset;
    if (off +| len > size) return error.Length;
    return st.unitAddr(e.first) + off;
}

// ── EMS ──────────────────────────────────────────────────────────────────

/// int 67h.
pub fn int67(st: *State, r: *Regs, mem: *Memory) void {
    int67Bus(st, r, mem, bus_mod.MemBus{ .mem = mem });
}

fn emsHandle(st: *State, dx: u16) ?u8 {
    if (dx >= MAX_EMS or !st.ems[dx].used) return null;
    return @intCast(dx);
}

fn status(r: *Regs, code: u8) void {
    r.setAh(code);
}

/// int 67h, with `bus` for 57h's moves (the machine).
pub fn int67Bus(st: *State, r: *Regs, mem: *Memory, bus: anytype) void {
    switch (r.ah()) {
        0x40 => status(r, 0),
        0x41 => {
            r.setBx(FRAME);
            status(r, 0);
        },
        0x42 => {
            r.setBx(@intCast(st.freeUnits()));
            r.setDx(st.units);
            status(r, 0);
        },
        0x43 => {
            if (r.bx() == 0) return status(r, 0x89);
            allocPages(st, r);
        },
        0x44 => {
            const h = emsHandle(st, r.dx()) orelse return status(r, 0x83);
            status(r, mapPage(st, h, r.al(), r.bx()));
        },
        0x45 => {
            const h = emsHandle(st, r.dx()) orelse return status(r, 0x83);
            if (st.ems[h].saved) return status(r, 0x86);
            resizePages(st, h, 0) catch {};
            if (h != 0) st.ems[h] = .{};
            status(r, 0);
        },
        0x46 => {
            r.setAl(0x40);
            status(r, 0);
        },
        0x47 => {
            const h = emsHandle(st, r.dx()) orelse return status(r, 0x83);
            if (st.ems[h].saved) return status(r, 0x8D);
            st.ems[h].saved = true;
            st.ems[h].save = st.map;
            status(r, 0);
        },
        0x48 => {
            const h = emsHandle(st, r.dx()) orelse return status(r, 0x83);
            if (!st.ems[h].saved) return status(r, 0x8E);
            st.ems[h].saved = false;
            restoreMap(st, st.ems[h].save);
            status(r, 0);
        },
        0x4B => {
            var n: u16 = 0;
            for (st.ems) |e| {
                if (e.used) n += 1;
            }
            r.setBx(n);
            status(r, 0);
        },
        0x4C => {
            const h = emsHandle(st, r.dx()) orelse return status(r, 0x83);
            r.setBx(st.ems[h].pages);
            status(r, 0);
        },
        0x4D => {
            var at = r.base[regs.ES] +% r.di();
            var n: u16 = 0;
            for (st.ems, 0..) |e, h| if (e.used) {
                mem.wr16(at, @intCast(h));
                mem.wr16(at + 2, e.pages);
                at += 4;
                n += 1;
            };
            r.setBx(n);
            status(r, 0);
        },
        0x4E => pageMap(st, r, mem),
        0x4F => partialMap(st, r, mem),
        0x50 => mapMultiple(st, r, mem),
        0x51 => {
            const h = emsHandle(st, r.dx()) orelse return status(r, 0x83);
            resizePages(st, h, r.bx()) catch |e| return status(r, switch (e) {
                error.TooMany => 0x87,
                error.NoMemory => 0x88,
            });
            r.setBx(st.ems[h].pages);
            status(r, 0);
        },
        0x52 => switch (r.al()) {
            0x00 => {
                _ = emsHandle(st, r.dx()) orelse return status(r, 0x83);
                r.setAl(0); // volatile
                status(r, 0);
            },
            0x01 => {
                _ = emsHandle(st, r.dx()) orelse return status(r, 0x83);
                status(r, if (r.bl() == 0) 0 else if (r.bl() == 1) 0x91 else 0x90);
            },
            0x02 => {
                r.setAl(0); // only volatile handles
                status(r, 0);
            },
            else => status(r, 0x8F),
        },
        0x53 => {
            const h = emsHandle(st, r.dx()) orelse return status(r, 0x83);
            switch (r.al()) {
                0x00 => {
                    mem.copyIn(r.base[regs.ES] +% r.di(), &st.ems[h].name);
                    status(r, 0);
                },
                0x01 => {
                    var name: [8]u8 = undefined;
                    mem.copyOut(r.base[regs.DS] +% r.si(), &name);
                    if (!std.mem.allEqual(u8, &name, 0)) {
                        for (st.ems, 0..) |e, i| {
                            if (e.used and i != h and std.mem.eql(u8, &e.name, &name)) return status(r, 0xA1);
                        }
                    }
                    st.ems[h].name = name;
                    status(r, 0);
                },
                else => status(r, 0x8F),
            }
        },
        0x54 => switch (r.al()) {
            0x00 => {
                var at = r.base[regs.ES] +% r.di();
                var n: u8 = 0;
                for (st.ems, 0..) |e, h| if (e.used) {
                    mem.wr16(at, @intCast(h));
                    mem.copyIn(at + 2, &e.name);
                    at += 10;
                    n += 1;
                };
                r.setAl(n);
                status(r, 0);
            },
            0x01 => {
                var name: [8]u8 = undefined;
                mem.copyOut(r.base[regs.DS] +% r.si(), &name);
                if (std.mem.allEqual(u8, &name, 0)) return status(r, 0xA1);
                for (st.ems, 0..) |e, h| {
                    if (e.used and std.mem.eql(u8, &e.name, &name)) {
                        r.setDx(@intCast(h));
                        return status(r, 0);
                    }
                }
                status(r, 0xA0);
            },
            0x02 => {
                r.setBx(MAX_EMS);
                status(r, 0);
            },
            else => status(r, 0x8F),
        },
        0x57 => moveRegion(st, r, mem, bus),
        0x58 => switch (r.al()) {
            0x00 => {
                const at = r.base[regs.ES] +% r.di();
                var p: u16 = 0;
                while (p < FRAME_PAGES) : (p += 1) {
                    mem.wr16(at + p * 4, FRAME + p * 0x400);
                    mem.wr16(at + p * 4 + 2, p);
                }
                r.setCx(FRAME_PAGES);
                status(r, 0);
            },
            0x01 => {
                r.setCx(FRAME_PAGES);
                status(r, 0);
            },
            else => status(r, 0x8F),
        },
        0x59 => switch (r.al()) {
            0x00 => {
                const at = r.base[regs.ES] +% r.di();
                mem.wr16(at, 0x0400); // a raw page: 1024 paragraphs
                mem.wr16(at + 2, 0); // no alternate register sets
                mem.wr16(at + 4, FRAME_PAGES * 4); // a context's size
                mem.wr16(at + 6, 0); // no DMA register sets
                mem.wr16(at + 8, 0);
                status(r, 0);
            },
            0x01 => {
                r.setBx(@intCast(st.freeUnits()));
                r.setDx(st.units);
                status(r, 0);
            },
            else => status(r, 0x8F),
        },
        0x5A => {
            if (r.al() > 1) return status(r, 0x8F);
            allocPages(st, r);
        },
        // Prepare for a warm boot: nothing to keep.
        0x5C => status(r, 0),
        // Alternate map register sets and the OS functions: refused (the
        // operating system denies them), as EMM386 does for programs.
        0x5B, 0x5D => status(r, 0xA4),
        // 55h/56h (map and jump/call), VCPI (DEh) and the rest: no.
        else => status(r, 0x84),
    }
}

fn allocPages(st: *State, r: *Regs) void {
    const want = r.bx();
    if (want > st.units) return status(r, 0x87);
    if (want > st.freeUnits()) return status(r, 0x88);
    var h: u8 = 1;
    while (h < MAX_EMS and st.ems[h].used) h += 1;
    if (h == MAX_EMS) return status(r, 0x85);
    st.ems[h] = .{ .used = true };
    resizePages(st, h, want) catch unreachable;
    r.setDx(h);
    status(r, 0);
}

/// A handle's pages grow (units from the top of the pool) or shrink.
fn resizePages(st: *State, h: u8, n: u16) error{ TooMany, NoMemory }!void {
    const e = &st.ems[h];
    if (n > st.units) return error.TooMany;
    const o = EMS_OWNER | h;
    if (n < e.pages) {
        var i: u32 = 0;
        while (i < st.units) : (i += 1) {
            if (st.owner[i] == o and st.lpage[i] >= n) st.owner[i] = FREE;
        }
        for (&st.map, 0..) |*m, p| if (m.handle == h and m.page >= n) {
            m.* = .{};
            st.window[p] = 0;
        };
        e.pages = n;
        return;
    }
    if (n - e.pages > st.freeUnits()) return error.NoMemory;
    var next = e.pages;
    var i: u32 = st.units;
    while (i > 0 and next < n) {
        i -= 1;
        if (st.owner[i] == FREE) {
            st.owner[i] = o;
            st.lpage[i] = next;
            next += 1;
        }
    }
    e.pages = n;
}

/// Maps logical page `page` of handle `h` at physical page `phys`
/// (page FFFFh: unmaps it); the status.
fn mapPage(st: *State, h: u8, phys: u8, page: u16) u8 {
    if (phys >= FRAME_PAGES) return 0x8B;
    if (page == 0xFFFF) {
        st.map[phys] = .{};
        st.window[phys] = 0;
        return 0;
    }
    if (page >= st.ems[h].pages) return 0x8A;
    const u = st.emsUnit(h, page) orelse return 0x80;
    st.map[phys] = .{ .handle = h, .page = page };
    st.window[phys] = st.unitAddr(u);
    return 0;
}

fn restoreMap(st: *State, m: [FRAME_PAGES]Map) void {
    for (m, 0..) |e, p| {
        if (e.handle != 0xFF and e.handle < MAX_EMS and st.ems[e.handle].used and e.page < st.ems[e.handle].pages) {
            _ = mapPage(st, e.handle, @intCast(p), e.page);
        } else {
            st.map[p] = .{};
            st.window[p] = 0;
        }
    }
}

const CONTEXT = FRAME_PAGES * 4;

fn writeMap(st: *const State, mem: *Memory, at: u32) void {
    for (st.map, 0..) |m, p| {
        mem.wr16(at + @as(u32, @intCast(p)) * 4, m.handle);
        mem.wr16(at + @as(u32, @intCast(p)) * 4 + 2, m.page);
    }
}
fn readMap(mem: *const Memory, at: u32) [FRAME_PAGES]Map {
    var m: [FRAME_PAGES]Map = undefined;
    for (&m, 0..) |*e, p| {
        const h = mem.rd16(at + @as(u32, @intCast(p)) * 4);
        e.* = .{ .handle = if (h > 0xFF) 0xFF else @intCast(h), .page = mem.rd16(at + @as(u32, @intCast(p)) * 4 + 2) };
    }
    return m;
}

/// 4Eh: the whole page map (00 get to ES:DI, 01 set from DS:SI, 02 both,
/// 03 its size).
fn pageMap(st: *State, r: *Regs, mem: *Memory) void {
    switch (r.al()) {
        0x00 => writeMap(st, mem, r.base[regs.ES] +% r.di()),
        0x01 => restoreMap(st, readMap(mem, r.base[regs.DS] +% r.si())),
        0x02 => {
            writeMap(st, mem, r.base[regs.ES] +% r.di());
            restoreMap(st, readMap(mem, r.base[regs.DS] +% r.si()));
        },
        0x03 => r.setAl(CONTEXT),
        else => return status(r, 0x8F),
    }
    status(r, 0);
}

/// 4Fh: part of the map. 00: DS:SI lists the segments (a count word, then
/// the segments), ES:DI gets count, then segment, handle, page for each;
/// 01: that saved form back from DS:SI; 02: BX segments' size.
fn partialMap(st: *State, r: *Regs, mem: *Memory) void {
    switch (r.al()) {
        0x00 => {
            const src = r.base[regs.DS] +% r.si();
            const dst = r.base[regs.ES] +% r.di();
            const n = mem.rd16(src);
            if (n > FRAME_PAGES) return status(r, 0x8B);
            mem.wr16(dst, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const seg = mem.rd16(src + 2 + i * 2);
                const p = physOfSeg(seg) orelse return status(r, 0x8B);
                mem.wr16(dst + 2 + i * 6, seg);
                mem.wr16(dst + 4 + i * 6, st.map[p].handle);
                mem.wr16(dst + 6 + i * 6, st.map[p].page);
            }
        },
        0x01 => {
            const src = r.base[regs.DS] +% r.si();
            const n = mem.rd16(src);
            if (n > FRAME_PAGES) return status(r, 0x8B);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const p = physOfSeg(mem.rd16(src + 2 + i * 6)) orelse return status(r, 0x8B);
                const h = mem.rd16(src + 4 + i * 6);
                const page = mem.rd16(src + 6 + i * 6);
                if (h < MAX_EMS and st.ems[h].used and page < st.ems[h].pages) {
                    _ = mapPage(st, @intCast(h), p, page);
                } else {
                    st.map[p] = .{};
                    st.window[p] = 0;
                }
            }
        },
        0x02 => {
            if (r.bx() > FRAME_PAGES) return status(r, 0x8B);
            r.setAl(@intCast(2 + r.bx() * 6));
        },
        else => return status(r, 0x8F),
    }
    status(r, 0);
}

fn physOfSeg(seg: u16) ?u8 {
    if (seg < FRAME or (seg - FRAME) % 0x400 != 0) return null;
    const p = (seg - FRAME) / 0x400;
    return if (p < FRAME_PAGES) @intCast(p) else null;
}

/// 50h: CX mappings at DS:SI (logical page, then the physical page (AL 00)
/// or its segment (AL 01)).
fn mapMultiple(st: *State, r: *Regs, mem: *Memory) void {
    if (r.al() > 1) return status(r, 0x8F);
    const h = emsHandle(st, r.dx()) orelse return status(r, 0x83);
    const at = r.base[regs.DS] +% r.si();
    var i: u32 = 0;
    while (i < r.cx()) : (i += 1) {
        const page = mem.rd16(at + i * 4);
        const where = mem.rd16(at + i * 4 + 2);
        const phys: u8 = if (r.al() == 0)
            (if (where < 0x100) @intCast(where) else 0xFF)
        else
            physOfSeg(where) orelse 0xFF;
        const s = mapPage(st, h, phys, page);
        if (s != 0) return status(r, s);
    }
    status(r, 0);
}

/// A 57h region's end: conventional memory or a handle's pages.
const Region = struct {
    ems: bool,
    handle: u8 = 0,
    /// Conventional: the linear start; EMS: the byte offset into the
    /// handle's pages.
    at: u32,
};

fn region(st: *State, mem: *const Memory, p: u32, len: u32) error{ Handle, Page, Offset, Type, Wrap }!Region {
    const kind = mem.rd8(p);
    const handle = mem.rd16(p + 1);
    const off = mem.rd16(p + 3);
    const seg = mem.rd16(p + 5);
    switch (kind) {
        0 => {
            const a = Memory.lin(seg, off);
            if (a + len > mem_mod.MEG) return error.Wrap;
            return .{ .ems = false, .at = a };
        },
        1 => {
            const h = emsHandle(st, handle) orelse return error.Handle;
            if (off >= UNIT) return error.Offset;
            if (seg >= st.ems[h].pages) return error.Page;
            const at = @as(u32, seg) * UNIT + off;
            if (at + len > @as(u32, st.ems[h].pages) * UNIT) return error.Page;
            return .{ .ems = true, .handle = h, .at = at };
        },
        else => return error.Type,
    }
}

/// Where `pos` bytes into a region are, and how many bytes follow there
/// contiguously.
fn regionAt(st: *const State, g: Region, pos: u32) struct { a: u32, run: u32 } {
    if (!g.ems) return .{ .a = g.at + pos, .run = 0xFFFF_FFFF };
    const x = g.at + pos;
    const u = st.emsUnit(g.handle, @intCast(x / UNIT)).?;
    return .{ .a = st.unitAddr(u) + x % UNIT, .run = UNIT - x % UNIT };
}

/// 57h: move (AL 00) or exchange (AL 01) a region (the structure at DS:SI).
fn moveRegion(st: *State, r: *Regs, mem: *Memory, bus: anytype) void {
    if (r.al() > 1) return status(r, 0x8F);
    const p = r.base[regs.DS] +% r.si();
    const len = mem.rd32(p);
    if (len > mem_mod.MEG) return status(r, 0x96);
    const errCode = struct {
        fn f(e: anyerror) u8 {
            return switch (e) {
                error.Handle => 0x83,
                error.Page => 0x93,
                error.Offset => 0x95,
                error.Type => 0x98,
                else => 0xA2,
            };
        }
    }.f;
    const src = region(st, mem, p + 4, len) catch |e| return status(r, errCode(e));
    const dst = region(st, mem, p + 11, len) catch |e| return status(r, errCode(e));
    var overlap = false;
    if (src.ems == dst.ems and (!src.ems or src.handle == dst.handle)) {
        overlap = src.at < dst.at + len and dst.at < src.at + len;
        if (overlap and r.al() == 1) return status(r, 0x97);
    }
    const was = mem.a20;
    mem.a20 = true;
    defer mem.a20 = was;
    // An overlapping move within one handle goes backwards when the
    // destination is above the source; whole-region moves otherwise go
    // in pieces, each contiguous at both ends.
    if (overlap and dst.at > src.at and src.ems) {
        var i: u32 = len;
        while (i > 0) {
            i -= 1;
            const s = regionAt(st, src, i);
            const d = regionAt(st, dst, i);
            bus.wr8(d.a, bus.rd8(s.a));
        }
        return status(r, 0x92);
    }
    var pos: u32 = 0;
    while (pos < len) {
        const s = regionAt(st, src, pos);
        const d = regionAt(st, dst, pos);
        const n = @min(len - pos, s.run, d.run);
        const ok = if (r.al() == 0) bus_mod.copy(bus, mem, d.a, s.a, n) else bus_mod.exchange(bus, mem, d.a, s.a, n);
        if (!ok) return status(r, 0x80);
        pos += n;
    }
    status(r, if (overlap) 0x92 else 0);
}

test {
    _ = @import("xms_test.sig");
}
