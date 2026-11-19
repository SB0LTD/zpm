//! The PC: a 386 with 16 MiB, the chipset's devices, a VGA with VESA's
//! SVGA modes (4 MiB of its own), a Sound Blaster 16 with its OPL3, and a
//! BIOS and DOS written in Sig. One `Machine` holds all of it (about
//! 21 MiB: the host puts it in static memory); nothing allocates.
//!
//!   init(host, c_root)   boots: the vector table, the ROM's service traps,
//!                        the BIOS data area, video, DOS, XMS and EMS
//!   start(path, tail)    loads the first program (C:\... in c_root)
//!   run(us)              emulated time goes on by `us` microseconds
//!   frame / audio        the picture and the sound, pulled by the host
//!   key / mouseMove / mouseButtons   input, pushed by the host
//!
//! The BIOS and DOS services are Sig: each vector points into the ROM at
//! F000:1000 + 8 * vector, at `STI; FE 38 vv; IRET` (the trap runs the
//! service; its carry and zero flags go into the flags IRET restores).
//! The timer's and keyboard's handlers are real code there around their
//! traps (int 08h calls int 1Ch and sends the EOI, as the BIOS does), so
//! a program that hooks a vector and chains to the old one gets them.

const std = @import("std");
const regs = @import("regs.sig");
const mem_mod = @import("mem.sig");
const cpu_mod = @import("cpu.sig");
const host_mod = @import("host.sig");
const Pic = @import("pic.sig").Pic;
const pit_mod = @import("pit.sig");
const Keyboard = @import("kbd.sig").Keyboard;
const Dma = @import("dma.sig").Dma;
const sb_mod = @import("sb.sig");
const Opl = @import("opl.sig").Opl;
const vga_mod = @import("vga.sig");
const video_bios = @import("video_bios.sig");
const bios = @import("bios.sig");
const dos21 = @import("dos21.sig");
const xms_mod = @import("xms.sig");
const mouse_mod = @import("mouse.sig");
const vesa = @import("vesa.sig");
const vesa_bios = @import("vesa_bios.sig");
const jit = @import("jit.sig");

pub const Memory = mem_mod.Memory;
pub const Cpu = cpu_mod.Cpu;
pub const Host = host_mod.Host;
pub const Size = vga_mod.Size;

/// The ROM's segment, and where the service stubs start in it.
pub const ROM_SEG: u16 = 0xF000;
const STUBS: u16 = 0x1000;
/// The XMS driver's entry point (F000:XMS_ENTRY: `FE 39 00 CB`).
pub const XMS_ENTRY: u16 = 0x0F00;
/// Where the mouse's user handler returns to (F000:MOUSE_RET: `FE 39 01`).
pub const MOUSE_RET: u16 = 0x0F10;
/// Where the EMS device header lives (its name, "EMMXXXX0", at +10).
const EMS_DEV_SEG: u16 = 0xF080;

pub const Status = enum {
    /// Ran the time asked for.
    ran,
    /// The program ended (DOS's exit code in `dos.exit_code`).
    exited,
    /// The CPU met something it cannot run (`cpu.fault_op`, `cpu.fault_at`).
    fault,
};

pub const Machine = struct {
    mem: Memory = .{},
    cpu: Cpu = .{},
    pic: Pic = .{},
    pit: pit_mod.Pit = .{},
    kbd: Keyboard = .{},
    dma: Dma = .{},
    sb: sb_mod.SoundBlaster = .{},
    opl: Opl = .{},
    vga: vga_mod.Vga = .{},
    bios: bios.State = .{},
    dos: dos21.State = .{},
    xms: xms_mod.State = .{},
    mouse: mouse_mod.State = .{},
    host: Host = undefined,

    /// The CPU's speed: instructions per emulated second (a 486DX2-66
    /// runs about 25 million of a game's).
    ips: u32 = 25_000_000,
    /// Emulated time, in microseconds and PIT clocks' remainder.
    time_us: u64 = 0,
    pit_rem: u64 = 0,
    cmos_index: u8 = 0,
    /// The last fault's reason, for the host's log.
    fault_why: []const u8 = "",
    /// An invalid opcode reached the ROM's int 6 (no handler of the
    /// program's): `run` returns .fault.
    stopped: bool = false,
    /// Every BIOS and DOS service called (but the timer's and keyboard's)
    /// in the host's log, with its registers and caller.
    trace: bool = false,
    /// Port accesses in the current CPU run (each costs a microsecond).
    io_count: u32 = 0,
    /// The program's state while the mouse's user handler runs.
    mouse_saved: ?struct { regs: regs.Regs, halted: bool } = null,
    /// The translator's (jit.sig) marks: nonzero for a RAM page that holds
    /// translated code (its writes are seen: `codeWrite`).
    jit_pages: [jit.PAGES]u8 = [_]u8{0} ** jit.PAGES,
    /// Lockstep checking (dosrun --jit-check): a second PC, interpreted,
    /// that runs every block the translator ran and must end up the same.
    twin: ?*Machine = null,

    /// (Every field is set here: a host may keep its Machine `undefined`
    /// in .bss, so 16 MiB of RAM costs nothing in its file.)
    pub fn init(m: *Machine, host: Host, c_root: []const u8) void {
        m.mem.clear();
        m.host = host;
        m.ips = 25_000_000;
        m.cmos_index = 0;
        m.fault_why = "";
        m.stopped = false;
        m.io_count = 0;
        m.mouse_saved = null;
        m.trace = false;
        @memset(&m.jit_pages, 0);
        m.twin = null;
        m.cpu.jit = null;
        m.cpu.reset();
        m.pic.reset();
        m.pit.reset();
        m.kbd.reset();
        m.dma.reset();
        m.sb.reset();
        m.opl.reset();
        m.vga.reset();
        m.bios.reset();
        m.dos.reset();
        m.xms.reset();
        m.mouse.reset();
        m.time_us = 0;
        m.pit_rem = 0;
        m.writeRom();
        // 640 KiB conventional, 15 MiB extended (the HMA's 64 KiB, then
        // XMS and EMS from 0x110000).
        bios.boot(&m.bios, &m.mem, 640, @intCast((mem_mod.RAM - mem_mod.MEG) / 1024));
        video_bios.boot(&m.vga, &m.mem);
        xms_mod.boot(&m.xms, &m.mem, 0x110000, mem_mod.RAM, EMS_DEV_SEG);
        // DOS's own data below 0x0700; programs from 0x0700 to 0x9FFF.
        dos21.boot(&m.dos, &m.mem, host, c_root, 0x0070, 0x9FFF);
        // (DOS's console output goes through int 10h's teletype, which
        // writes the VGA's own memory)
        m.dos.tty_direct = false;
    }

    /// DOS's console output since the last call, through int 10h/0Eh on
    /// the BIOS's active page.
    fn conFlush(m: *Machine) void {
        var buf: [256]u8 = undefined;
        while (true) {
            const n = dos21.conDrain(&m.dos, &buf);
            if (n == 0) return;
            for (buf[0..n]) |ch| {
                var t = regs.Regs{};
                t.setAh(0x0E);
                t.setAl(ch);
                t.setBh(m.mem.rdB(0x40, 0x62));
                t.setBl(0x07);
                video_bios.int10(&t, &m.mem, &m.vga);
            }
            if (n < buf.len) return;
        }
    }

    /// A mouse event the program's handler waits for: a far call to it
    /// with the driver's registers (it returns through F000:MOUSE_RET).
    fn mouseCall(m: *Machine) void {
        if (m.mouse_saved != null) return;
        // (a real-mode handler: while a DOS extender's protected mode
        // runs, the call waits for its next switch back to real mode)
        if (m.cpu.cr0 & 1 != 0) return;
        const call = m.mouse.userCall() orelse return;
        m.mouse_saved = .{ .regs = m.cpu.regs, .halted = m.cpu.halted };
        const r = &m.cpu.regs;
        m.mouse.handlerRegs(r, call.mask);
        var sp = r.sp();
        const ss = r.base[regs.SS];
        sp -%= 2;
        m.wr16(ss +% sp, ROM_SEG);
        sp -%= 2;
        m.wr16(ss +% sp, MOUSE_RET);
        r.set16(regs.ESP, sp);
        r.flags &= ~regs.IF;
        r.eip = call.off;
        r.setSeg(regs.CS, call.seg);
        m.cpu.halted = false;
    }

    /// The vector table and the ROM: each vector's stub, the hardware
    /// handlers, the XMS entry, the BIOS's date and model bytes.
    fn writeRom(m: *Machine) void {
        const rom = mem_mod.Memory.lin(ROM_SEG, 0);
        var v: u32 = 0;
        while (v < 256) : (v += 1) {
            // A real PC's vectors nobody owns are 0000:0000, and programs
            // count on it: DOS/4GW looks for a vector equal to int BDh's
            // (an unused one) and loops until it finds one. The BIOS's
            // and DOS's own (00-2F), the mouse's (33), the RTC alarm's
            // (4A), EMS's (67) and the IRQs get the ROM's stubs.
            const owned = v <= 0x2F or v == 0x33 or v == 0x4A or v == 0x67 or (v >= 0x70 and v <= 0x77);
            if (!owned) {
                m.mem.wrW(0, @intCast(v * 4), 0);
                m.mem.wrW(0, @intCast(v * 4 + 2), 0);
                continue;
            }
            const off: u16 = @intCast(STUBS + v * 8);
            const at = rom + off;
            switch (v) {
                // IRQ 0: tick, int 1Ch, EOI.
                0x08 => m.mem.copyIn(at, &.{ 0xFE, 0x38, 0x08, 0xCD, 0x1C, 0xE9, 0x00, 0x00 }),
                // IRQ 1: the scan code into the BIOS buffer, EOI.
                0x09 => m.mem.copyIn(at, &.{ 0xFE, 0x38, 0x09, 0xE9, 0x00, 0x00, 0x00, 0x00 }),
                // The other IRQs: EOI and return (their stubs jump to it).
                0x0A...0x0F, 0x70...0x77 => m.mem.copyIn(at, &.{ 0xFE, 0x38, @intCast(v), 0xCF, 0, 0, 0, 0 }),
                // int 1Ch and the unused ones: return.
                else => m.mem.copyIn(at, &.{ 0xFB, 0xFE, 0x38, @intCast(v), 0xCF, 0, 0, 0 }),
            }
            m.mem.wrW(0, @intCast(v * 4), off);
            m.mem.wrW(0, @intCast(v * 4 + 2), ROM_SEG);
        }
        // int 08h's and 09h's tails: after the trap (and int 1Ch), EOI to
        // the master and IRET: push ax; mov al,20h; out 20h,al; pop ax; iret
        const eoi = [_]u8{ 0x50, 0xB0, 0x20, 0xE6, 0x20, 0x58, 0xCF };
        const tail8 = rom + STUBS + 0x100 * 8;
        m.mem.copyIn(tail8, &eoi);
        m.patchJump(rom + STUBS + 0x08 * 8 + 5, tail8);
        m.patchJump(rom + STUBS + 0x09 * 8 + 3, tail8);
        // The XMS driver's far entry: FE 39 00; RETF.
        m.mem.copyIn(rom + XMS_ENTRY, &.{ 0xFE, 0x39, 0x00, 0xCB });
        // Where the mouse's user handler returns: FE 39 01.
        m.mem.copyIn(rom + MOUSE_RET, &.{ 0xFE, 0x39, 0x01 });
        // The BIOS's date and the machine's model (an AT).
        m.mem.copyIn(rom + 0xFFF5, "11/19/26");
        m.mem.wrB(ROM_SEG, 0xFFFE, 0xFC);
        // Reset vector: a far jump nowhere useful (a program that jumps to
        // F000:FFF0 to reboot ends instead: int 20h).
        m.mem.copyIn(rom + 0xFFF0, &.{ 0xCD, 0x20 });
    }

    /// A near JMP (E9 rel16) at `at` to `to`, both in the ROM's segment.
    fn patchJump(m: *Machine, at: u32, to: u32) void {
        const rel: i32 = @as(i32, @intCast(to)) - @as(i32, @intCast(at + 3));
        m.mem.wr8(at, 0xE9);
        m.mem.wr16(at + 1, @bitCast(@as(i16, @intCast(rel))));
    }

    /// Loads the first program: C:\NAME.EXE (or .COM) with its command
    /// tail; false (and a log line) if DOS cannot.
    pub fn start(m: *Machine, path: []const u8, tail: []const u8) bool {
        if (dos21.start(&m.dos, &m.cpu.regs, &m.mem, m.host, path, tail)) |err| {
            m.host.say("dos: cannot start {s}: error {d}", .{ path, err });
            return false;
        }
        return true;
    }

    // ── The bus (what the CPU reads and writes) ────────────────────────

    /// A linear address on the bus: the A20 gate off masks address line
    /// 20 (FFFF:0010 is 0:0); nothing past the RAM's end aliases into it.
    ///
    /// The map: RAM below 0xA0000 and from 1 MiB to 16 MiB; the VGA at
    /// 0xA0000-0xBFFFF (while a VESA mode is set, 0xA0000-0xAFFFF is the
    /// SVGA's window A instead); the ROMs and EMS's page frame up to 1 MiB;
    /// the SVGA's linear frame buffer at vesa.LFB_BASE (4 MiB); nothing
    /// else (0xFF).
    inline fn phys(m: *const Machine, a: u32) u32 {
        return if (m.mem.a20) a else a & ~mem_mod.MEG;
    }

    /// Where an `n`-byte access at bus address `w` lands in the SVGA's
    /// memory, if all of it does (the frame buffer, or window A in a
    /// VESA mode): the 16- and 32-bit paths' straight route there.
    inline fn svgaAt(m: *const Machine, w: u32, comptime n: u32) ?u32 {
        const lo = w -% vesa.LFB_BASE;
        if (lo <= vesa.VRAM - n) return lo;
        const wo = w -% 0xA0000;
        if (wo <= vesa.WIN_SIZE - n and m.vga.svga.active) {
            const o = m.vga.svga.bank_off + wo;
            if (o <= vesa.VRAM - n) return o;
        }
        return null;
    }

    /// The host's own bytes behind the 4 KiB page at bus address `a`
    /// (page aligned), for the CPU's fast paths (its TLB keeps them): RAM
    /// and the frame buffer, to read and write; the ROMs' area, to read;
    /// null where a device has to see the access. Good until `mapKey`
    /// changes (the A20 gate moves RAM around).
    pub fn page(m: *Machine, a0: u32, write: bool) ?[*]u8 {
        const a = m.phys(a0);
        if (a < 0xA0000 or (a >= mem_mod.MEG and a < mem_mod.RAM)) {
            // (a page with translated code: its writes go the slow way)
            if (write and m.jit_pages[a >> 12] != 0) return null;
            return m.mem.ram[a..].ptr;
        }
        const lo = a -% vesa.LFB_BASE;
        if (lo < vesa.VRAM) return m.vga.svga.mem[lo..].ptr;
        if (!write and ((a >= 0xC0000 and a < 0xE0000) or (a >= 0xF0000 and a < mem_mod.MEG))) return m.mem.ram[a..].ptr;
        return null;
    }

    pub inline fn mapKey(m: *const Machine) u32 {
        return @intFromBool(m.mem.a20);
    }

    // ── The translator's hooks ───────────────────────────────────────────

    /// The RAM the translator may translate code from (and its marks).
    pub fn jitRam(m: *Machine) []u8 {
        return &m.mem.ram;
    }
    pub fn jitPages(m: *Machine) *[jit.PAGES]u8 {
        return &m.jit_pages;
    }
    /// A write of `n` bytes at RAM address `a` on a page with code.
    fn codeWrite(m: *Machine, a: u32, n: u32) void {
        if (m.cpu.jit) |j| j.written(a, n);
    }
    /// The translator on (the host's code memory), or false.
    pub fn jitEnable(m: *Machine) bool {
        return jit.attach(&m.cpu, m.host, &m.jit_pages, &m.mem.ram);
    }
    /// After each stretch of translated (or single-stepped) code in
    /// lockstep: the twin runs the same, and the two must agree.
    pub fn jitCheck(m: *Machine, info: *const jit.CheckInfo) bool {
        const t = m.twin orelse return true;
        return @import("jit_check.sig").check(m, t, info);
    }

    pub inline fn rd8(m: *Machine, a0: u32) u8 {
        const a = m.phys(a0);
        if (a < 0xA0000 or (a >= mem_mod.MEG and a < mem_mod.RAM)) return m.mem.ram[a];
        return m.rdHigh(a);
    }
    fn rdHigh(m: *Machine, a: u32) u8 {
        if (a >= mem_mod.RAM) {
            const lo = a -% vesa.LFB_BASE;
            if (lo < vesa.VRAM) return m.vga.svga.mem[lo];
            // (no memory there: the bus floats high)
            return 0xFF;
        }
        if (a < 0xC0000) {
            if (a < 0xB0000 and m.vga.svga.active) return m.vga.svga.winRead(a - 0xA0000);
            return m.vga.read(a - 0xA0000);
        }
        if (a >= 0xE0000 and a < 0xF0000) {
            if (m.xms.emsWindow(a - 0xE0000)) |r| return m.mem.ram[r];
            return 0xFF;
        }
        return m.mem.ram[a];
    }
    pub inline fn wr8(m: *Machine, a0: u32, v: u8) void {
        const a = m.phys(a0);
        if (a < 0xA0000 or (a >= mem_mod.MEG and a < mem_mod.RAM)) {
            m.mem.ram[a] = v;
            if (m.jit_pages[a >> 12] != 0) m.codeWrite(a, 1);
            return;
        }
        m.wrHigh(a, v);
    }
    fn wrHigh(m: *Machine, a: u32, v: u8) void {
        if (a >= mem_mod.RAM) {
            const lo = a -% vesa.LFB_BASE;
            if (lo < vesa.VRAM) m.vga.svga.mem[lo] = v;
            return;
        }
        if (a < 0xC0000) {
            if (a < 0xB0000 and m.vga.svga.active) return m.vga.svga.winWrite(a - 0xA0000, v);
            return m.vga.write(a - 0xA0000, v);
        }
        if (a >= 0xE0000 and a < 0xF0000) {
            if (m.xms.emsWindow(a - 0xE0000)) |r| {
                m.mem.ram[r] = v;
                if (m.jit_pages[r >> 12] != 0) m.codeWrite(r, 1);
            }
            return;
        }
        // (the ROMs: read only; 0xC8000-0xDFFFF: nothing there)
    }
    // (words and dwords straight from RAM in conventional and extended
    // memory: a protected-mode game's code and data live above 1 MiB; and
    // straight from the SVGA's memory, where a game draws its frames)
    pub inline fn rd16(m: *Machine, a: u32) u16 {
        const w = m.phys(a);
        if (w < 0x9FFFF or (w >= mem_mod.MEG and w < mem_mod.RAM - 1)) return std.mem.readInt(u16, m.mem.ram[w..][0..2], .little);
        return m.rd16Slow(a, w);
    }
    fn rd16Slow(m: *Machine, a: u32, w: u32) u16 {
        if (m.svgaAt(w, 2)) |o| return std.mem.readInt(u16, m.vga.svga.mem[o..][0..2], .little);
        return @as(u16, m.rd8(a)) | (@as(u16, m.rd8(a +% 1)) << 8);
    }
    pub inline fn wr16(m: *Machine, a: u32, v: u16) void {
        const w = m.phys(a);
        if (w < 0x9FFFF or (w >= mem_mod.MEG and w < mem_mod.RAM - 1)) {
            std.mem.writeInt(u16, m.mem.ram[w..][0..2], v, .little);
            if (m.jit_pages[w >> 12] | m.jit_pages[(w + 1) >> 12] != 0) m.codeWrite(w, 2);
            return;
        }
        m.wr16Slow(a, w, v);
    }
    fn wr16Slow(m: *Machine, a: u32, w: u32, v: u16) void {
        if (m.svgaAt(w, 2)) |o| return std.mem.writeInt(u16, m.vga.svga.mem[o..][0..2], v, .little);
        m.wr8(a, @truncate(v));
        m.wr8(a +% 1, @truncate(v >> 8));
    }
    pub inline fn rd32(m: *Machine, a: u32) u32 {
        const w = m.phys(a);
        if (w < 0x9FFFD or (w >= mem_mod.MEG and w < mem_mod.RAM - 3)) return std.mem.readInt(u32, m.mem.ram[w..][0..4], .little);
        return m.rd32Slow(a, w);
    }
    fn rd32Slow(m: *Machine, a: u32, w: u32) u32 {
        if (m.svgaAt(w, 4)) |o| return std.mem.readInt(u32, m.vga.svga.mem[o..][0..4], .little);
        return @as(u32, m.rd16(a)) | (@as(u32, m.rd16(a +% 2)) << 16);
    }
    pub inline fn wr32(m: *Machine, a: u32, v: u32) void {
        const w = m.phys(a);
        if (w < 0x9FFFD or (w >= mem_mod.MEG and w < mem_mod.RAM - 3)) {
            std.mem.writeInt(u32, m.mem.ram[w..][0..4], v, .little);
            if (m.jit_pages[w >> 12] | m.jit_pages[(w + 3) >> 12] != 0) m.codeWrite(w, 4);
            return;
        }
        m.wr32Slow(a, w, v);
    }
    fn wr32Slow(m: *Machine, a: u32, w: u32, v: u32) void {
        if (m.svgaAt(w, 4)) |o| return std.mem.writeInt(u32, m.vga.svga.mem[o..][0..4], v, .little);
        m.wr16(a, @truncate(v));
        m.wr16(a +% 2, @truncate(v >> 16));
    }

    // ── Ports ────────────────────────────────────────────────────────────

    pub fn in8(m: *Machine, port: u16) u8 {
        m.io_count +%= 1;
        return switch (port) {
            0x00...0x0F, 0x80...0x8F, 0xC0...0xDF => m.dma.in8(port),
            0x20, 0x21, 0xA0, 0xA1 => m.pic.in8(port),
            0x40...0x43 => m.pit.in8(port),
            0x61 => m.pit.in61(),
            0x60, 0x64 => m.kbd.in8(port),
            0x70 => m.cmos_index,
            0x71 => m.cmosRead(),
            0x92 => if (m.mem.a20) 0x02 else 0x00,
            0x201 => 0xFF, // (no joystick)
            0x220...0x223 => m.opl.in8(@intCast(port & 3)),
            0x228, 0x229 => m.opl.in8(@intCast(port & 1)),
            0x224...0x227, 0x22A...0x22F => m.sb.in8(port),
            0x388...0x38B => m.opl.in8(@intCast(port & 3)),
            0x3B0...0x3DF => m.vga.in8(port),
            else => 0xFF,
        };
    }
    pub fn out8(m: *Machine, port: u16, v: u8) void {
        m.io_count +%= 1;
        switch (port) {
            0x00...0x0F, 0x80...0x8F, 0xC0...0xDF => m.dma.out8(port, v),
            0x20, 0x21, 0xA0, 0xA1 => m.pic.out8(port, v),
            0x40...0x43 => m.pit.out8(port, v),
            0x61 => m.pit.out61(v),
            0x60, 0x64 => if (m.kbd.out8(port, v)) |a20| {
                m.mem.a20 = a20;
            },
            0x70 => m.cmos_index = v & 0x7F,
            0x92 => m.mem.a20 = v & 0x02 != 0,
            0x220...0x223 => m.opl.out8(@intCast(port & 3), v),
            0x228, 0x229 => m.opl.out8(@intCast(port & 1), v),
            0x224...0x227, 0x22A...0x22F => m.sb.out8(port, v),
            0x388...0x38B => m.opl.out8(@intCast(port & 3), v),
            0x3B0...0x3DF => m.vga.out8(port, v),
            else => {},
        }
    }
    pub fn in16(m: *Machine, port: u16) u16 {
        return @as(u16, m.in8(port)) | (@as(u16, m.in8(port +% 1)) << 8);
    }
    pub fn out16(m: *Machine, port: u16, v: u16) void {
        m.out8(port, @truncate(v));
        m.out8(port +% 1, @truncate(v >> 8));
    }
    pub fn in32(m: *Machine, port: u16) u32 {
        return @as(u32, m.in16(port)) | (@as(u32, m.in16(port +% 2)) << 16);
    }
    pub fn out32(m: *Machine, port: u16, v: u32) void {
        m.out16(port, @truncate(v));
        m.out16(port +% 2, @truncate(v >> 16));
    }

    /// The RTC's registers (time and date in BCD from the host's clock,
    /// status A-D, the CMOS's memory sizes).
    fn cmosRead(m: *Machine) u8 {
        const t = m.host.now();
        const bcd = struct {
            fn f(x: u32) u8 {
                return @intCast(((x / 10) % 10) << 4 | (x % 10));
            }
        }.f;
        const ext_kb: u32 = @min((mem_mod.RAM - mem_mod.MEG) / 1024, 0xFFFF);
        return switch (m.cmos_index) {
            0x00 => bcd(t.second),
            0x02 => bcd(t.minute),
            0x04 => bcd(t.hour),
            0x06 => bcd(t.weekday + 1),
            0x07 => bcd(t.day),
            0x08 => bcd(t.month),
            0x09 => bcd(t.year % 100),
            0x0A => 0x26, // (no update in progress)
            0x0B => 0x02, // 24-hour, BCD
            0x0C => 0x00,
            0x0D => 0x80, // the battery is fine
            0x15 => 0x80, // 640 KiB base memory
            0x16 => 0x02,
            0x17, 0x30 => @truncate(ext_kb),
            0x18, 0x31 => @truncate(ext_kb >> 8),
            0x32 => bcd(t.year / 100),
            else => 0,
        };
    }

    /// An interrupt waits for the CPU.
    pub fn irq(m: *Machine) bool {
        return m.pic.pending();
    }

    // ── Services ─────────────────────────────────────────────────────────

    /// A trap in the ROM: the service it names. False: the service waits
    /// (the trap runs again once time has gone on).
    pub fn hle(m: *Machine, c: *Cpu, id: u16) bool {
        const ax = c.regs.ax();
        const done = m.hleRun(c, id);
        // (a service writes memory past the CPU's view of it: translated
        // code it may have overwritten is checked)
        if (c.jit) |j| j.afterService(id, ax);
        return done;
    }

    fn hleRun(m: *Machine, c: *Cpu, id: u16) bool {
        const r = &c.regs;
        var done = true;
        if (m.trace and id != 0x08 and id != 0x09 and !(id >= 0x0A and id <= 0x0F) and !(id >= 0x70 and id <= 0x77)) {
            m.host.say("svc {x:0>3} ax={x:0>4} bx={x:0>4} cx={x:0>4} dx={x:0>4} ds={x:0>4} es={x:0>4} from {x:0>4}:{x:0>4}", .{
                id, r.ax(), r.bx(), r.cx(), r.dx(), r.seg[regs.DS], r.seg[regs.ES], m.rd16(r.base[regs.SS] +% @as(u32, r.sp() +% 2)), m.rd16(r.base[regs.SS] +% @as(u32, r.sp())),
            });
        }
        switch (id) {
            // A divide error or an invalid opcode the program has no
            // handler for: DOS ends a program on the first ("Divide
            // overflow"); the second stops the PC with where and what.
            0x00 => {
                m.host.say("dos: divide overflow at {x:0>4}:{x:0>4}: the program ends", .{ r.seg[regs.CS], @as(u16, @truncate(r.eip)) });
                m.dos.exited = true;
                m.dos.exit_code = 0xFF;
                return false;
            },
            0x06 => {
                m.stopped = true;
                return false;
            },
            0x08 => bios.timerTick(&m.bios, &m.mem),
            0x09 => bios.keyIrq(&m.bios, &m.mem, m.kbd.in8(0x60)),
            // The slave's IRQs: EOI to both; the master's: EOI.
            0x0A...0x0F => m.pic.out8(0x20, 0x20),
            0x70...0x77 => {
                m.pic.out8(0xA0, 0x20);
                m.pic.out8(0x20, 0x20);
            },
            0x10 => video_bios.int10(r, &m.mem, &m.vga),
            0x11 => bios.int11(r, &m.mem),
            0x12 => bios.int12(r, &m.mem),
            0x13 => bios.int13(r, &m.mem),
            0x15 => done = bios.int15Wait(&m.bios, r, &m.mem, &m.mem.a20, m),
            0x16 => done = bios.int16(&m.bios, r, &m.mem),
            0x1A => bios.int1a(&m.bios, r, &m.mem, m.host),
            0x20 => {
                r.setAh(0x00);
                done = dos21.int21Bus(&m.dos, r, &m.mem, m.host, m);
            },
            0x21 => {
                done = dos21.int21Bus(&m.dos, r, &m.mem, m.host, m);
                m.conFlush();
            },
            // (the critical error handler: fail the call)
            0x24 => dos21.int24(r),
            // int 27h: stay resident, DX bytes of the PSP at CS kept.
            0x27 => {
                r.setDx(@intCast((@as(u32, r.dx()) + 15) / 16));
                r.setAx(0x3100);
                done = dos21.int21Bus(&m.dos, r, &m.mem, m.host, m);
            },
            0x2F => dos21.int2f(&m.dos, r, &m.mem),
            0x33 => mouse_mod.int33(&m.mouse, r, &m.mem),
            0x67 => xms_mod.int67Bus(&m.xms, r, &m.mem, m),
            0x100 => {
                xms_mod.xmsBus(&m.xms, r, &m.mem, m);
                return true; // (a far call: its flags are the CPU's own)
            },
            // VESA's far window function (C000:WIN_FUNC, then RETF).
            0x100 + @as(u16, vesa_bios.WIN_TRAP) => {
                vesa_bios.winFunc(r, &m.vga);
                return true;
            },
            // The mouse's user handler returned (RETF to F000:MOUSE_RET):
            // the program goes on as it was.
            0x101 => {
                if (m.mouse_saved) |sv| {
                    c.regs = sv.regs;
                    c.halted = sv.halted;
                    m.mouse_saved = null;
                }
                return true;
            },
            else => {},
        }
        // An interrupt service's results in CF and ZF go back through the
        // FLAGS image IRET pops (SS:SP+4).
        if (done and id < 0x100) {
            const at = r.base[regs.SS] +% @as(u32, (r.sp() +% 4));
            var f = m.rd16(at);
            f = (f & ~@as(u16, @truncate(regs.CF | regs.ZF))) | @as(u16, @truncate(r.flags & (regs.CF | regs.ZF)));
            m.wr16(at, f);
        }
        return done;
    }

    // ── Time ─────────────────────────────────────────────────────────────

    /// Emulated time goes on by `us` microseconds: the CPU in slices of a
    /// quarter millisecond, the devices after each.
    pub fn run(m: *Machine, us: u32) Status {
        var left = us;
        while (left > 0) {
            // A slice ends at the timer's next edge (a game's 1 kHz or
            // faster timer gets every tick), else after 250 us.
            const until_us: u32 = @intCast((@as(u64, m.pit.untilIrq()) * 1_000_000 + pit_mod.HZ - 1) / pit_mod.HZ);
            const slice: u32 = @max(1, @min(left, 250, until_us));
            left -= slice;
            m.devices(slice);
            m.mouseCall();
            if (m.twin) |t| {
                t.devices(slice);
                t.mouseCall();
            }
            var budget: u32 = @intCast(@as(u64, m.ips) * slice / 1_000_000);
            while (budget > 0) {
                const before = m.cpu.executed;
                m.io_count = 0;
                const why = m.cpu.run(m, budget);
                // (an ISA port access takes about a microsecond: what the
                // CPU did meanwhile is that much less)
                const io_cost: u64 = @as(u64, m.io_count) * (m.ips / 1_000_000);
                const ran: u32 = @intCast(@min(m.cpu.executed - before + io_cost, budget));
                budget -= ran;
                if (m.dos.exited) return .exited;
                if (m.stopped) {
                    m.host.say("dos: an invalid opcode ({x}) at {x:0>5}, and the program has no handler for it", .{ m.cpu.fault_op, m.cpu.fault_at });
                    return .fault;
                }
                switch (why) {
                    .budget => break,
                    .irq => {
                        // (no vector after all: the rest of the slice idles
                        // rather than spinning on .irq)
                        const ack = m.pic.acknowledge();
                        if (m.twin) |t| {
                            if (t.pic.acknowledge()) |tv| t.cpu.interrupt(t, tv);
                        }
                        if (ack) |vec| m.cpu.interrupt(m, vec) else break;
                    },
                    // Idle until the next slice's interrupts.
                    .halt, .wait => break,
                    .fault => {
                        m.host.say("dos: the CPU stopped at {x:0>5} (opcode {x})", .{ m.cpu.fault_at, m.cpu.fault_op });
                        return .fault;
                    },
                }
            }
            if (m.dos.exited) return .exited;
        }
        return .ran;
    }

    fn devices(m: *Machine, us: u32) void {
        m.time_us += us;
        const clocks_x = @as(u64, us) * pit_mod.HZ + m.pit_rem;
        const clocks: u32 = @intCast(clocks_x / 1_000_000);
        m.pit_rem = clocks_x % 1_000_000;
        if (m.pit.advance(clocks) > 0) m.pic.raise(0);
        if (m.kbd.wantIrq()) m.pic.raise(1);
        if (m.sb.advance(&m.dma, &m.mem, us)) m.pic.raise(sb_mod.IRQ);
        m.opl.advance(us);
        m.vga.advance(us);
    }

    // ── The host's side ──────────────────────────────────────────────────

    /// The picture (vga.render's contract): the VGA's, or a VESA mode's
    /// at its own size (up to vesa.MAX_W x MAX_H, 1600x1200).
    pub fn frame(m: *Machine, out: []u32, stride: u32, max: Size) Size {
        const sz = m.vga.render(out, stride, max);
        // (the mouse driver's cursor, when shown: over the picture, never
        // in video memory)
        mouse_mod.overlay(&m.mouse, &m.mem, m.vga.svga.active, out, stride, sz.w, sz.h);
        return sz;
    }
    /// The sound since the last call: interleaved stereo i16 at `rate`
    /// (the host asks for as many frames as its device took).
    pub fn audio(m: *Machine, out: []i16, rate: u32) void {
        @memset(out, 0);
        m.opl.gain = m.sb.fmGain();
        m.sb.mix(out, rate);
        m.opl.mix(out, rate);
        m.pit.speaker(out, rate);
    }
    /// A key (set-1 scan code; bit 7 released; 0xE0 before extended ones).
    pub fn key(m: *Machine, code: u8) void {
        m.kbd.push(code);
    }
    pub fn mouseMove(m: *Machine, dx: i32, dy: i32) void {
        m.mouse.move(dx, dy);
    }
    pub fn mouseButtons(m: *Machine, b: u3) void {
        m.mouse.buttons(b);
    }
};
