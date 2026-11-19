//! The PC: a 386 with 16 MiB, the chipset's devices, a VGA, a Sound
//! Blaster 16 with its OPL3, and a BIOS and DOS written in Sig. One
//! `Machine` holds all of it (about 16.5 MiB: the host puts it in static
//! memory); nothing allocates.
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

pub const Memory = mem_mod.Memory;
pub const Cpu = cpu_mod.Cpu;
pub const Host = host_mod.Host;
pub const Size = vga_mod.Size;

/// The ROM's segment, and where the service stubs start in it.
pub const ROM_SEG: u16 = 0xF000;
const STUBS: u16 = 0x1000;
/// The XMS driver's entry point (F000:XMS_ENTRY: `FE 39 00 CB`).
pub const XMS_ENTRY: u16 = 0x0F00;
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

    pub fn init(m: *Machine, host: Host, c_root: []const u8) void {
        m.mem.clear();
        m.host = host;
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
    }

    /// The vector table and the ROM: each vector's stub, the hardware
    /// handlers, the XMS entry, the BIOS's date and model bytes.
    fn writeRom(m: *Machine) void {
        const rom = mem_mod.Memory.lin(ROM_SEG, 0);
        var v: u32 = 0;
        while (v < 256) : (v += 1) {
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

    pub inline fn rd8(m: *Machine, a0: u32) u8 {
        const a = m.mem.wrap(a0);
        if (a < 0xA0000 or a >= mem_mod.MEG) return m.mem.ram[a];
        return m.rdHigh(a);
    }
    fn rdHigh(m: *Machine, a: u32) u8 {
        if (a < 0xC0000) return m.vga.read(a - 0xA0000);
        if (a >= 0xE0000 and a < 0xF0000) {
            if (m.xms.emsWindow(a - 0xE0000)) |r| return m.mem.ram[r];
            return 0xFF;
        }
        return m.mem.ram[a];
    }
    pub inline fn wr8(m: *Machine, a0: u32, v: u8) void {
        const a = m.mem.wrap(a0);
        if (a < 0xA0000 or a >= mem_mod.MEG) {
            m.mem.ram[a] = v;
            return;
        }
        m.wrHigh(a, v);
    }
    fn wrHigh(m: *Machine, a: u32, v: u8) void {
        if (a < 0xC0000) return m.vga.write(a - 0xA0000, v);
        if (a >= 0xE0000 and a < 0xF0000) {
            if (m.xms.emsWindow(a - 0xE0000)) |r| m.mem.ram[r] = v;
            return;
        }
        // (the ROMs: read only; 0xC8000-0xDFFFF: nothing there)
    }
    pub inline fn rd16(m: *Machine, a: u32) u16 {
        const w = m.mem.wrap(a);
        if (w < 0x9FFFF) return std.mem.readInt(u16, m.mem.ram[w..][0..2], .little);
        return @as(u16, m.rd8(a)) | (@as(u16, m.rd8(a +% 1)) << 8);
    }
    pub inline fn wr16(m: *Machine, a: u32, v: u16) void {
        const w = m.mem.wrap(a);
        if (w < 0x9FFFF) return std.mem.writeInt(u16, m.mem.ram[w..][0..2], v, .little);
        m.wr8(a, @truncate(v));
        m.wr8(a +% 1, @truncate(v >> 8));
    }
    pub inline fn rd32(m: *Machine, a: u32) u32 {
        const w = m.mem.wrap(a);
        if (w < 0x9FFFD) return std.mem.readInt(u32, m.mem.ram[w..][0..4], .little);
        return @as(u32, m.rd16(a)) | (@as(u32, m.rd16(a +% 2)) << 16);
    }
    pub inline fn wr32(m: *Machine, a: u32, v: u32) void {
        const w = m.mem.wrap(a);
        if (w < 0x9FFFD) return std.mem.writeInt(u32, m.mem.ram[w..][0..4], v, .little);
        m.wr16(a, @truncate(v));
        m.wr16(a +% 2, @truncate(v >> 16));
    }

    // ── Ports ────────────────────────────────────────────────────────────

    pub fn in8(m: *Machine, port: u16) u8 {
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
        const r = &c.regs;
        var done = true;
        switch (id) {
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
            0x15 => bios.int15(&m.bios, r, &m.mem, &m.mem.a20),
            0x16 => done = bios.int16(&m.bios, r, &m.mem),
            0x1A => bios.int1a(&m.bios, r, &m.mem, m.host),
            0x20 => {
                r.setAh(0x00);
                done = dos21.int21(&m.dos, r, &m.mem, m.host);
            },
            0x21 => done = dos21.int21(&m.dos, r, &m.mem, m.host),
            0x2F => dos21.int2f(&m.dos, r, &m.mem),
            0x33 => mouse_mod.int33(&m.mouse, r, &m.mem),
            0x67 => xms_mod.int67(&m.xms, r, &m.mem),
            0x100 => {
                xms_mod.xms(&m.xms, r, &m.mem);
                return true; // (a far call: its flags are the CPU's own)
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
            const slice: u32 = @min(left, 250);
            left -= slice;
            m.devices(slice);
            var budget: u32 = @intCast(@as(u64, m.ips) * slice / 1_000_000);
            while (budget > 0) {
                const before = m.cpu.executed;
                const why = m.cpu.run(m, budget);
                const ran: u32 = @intCast(@min(m.cpu.executed - before, budget));
                budget -= ran;
                if (m.dos.exited) return .exited;
                switch (why) {
                    .budget => break,
                    .irq => {
                        if (m.pic.acknowledge()) |vec| m.cpu.interrupt(m, vec);
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

    /// The picture (vga.render's contract).
    pub fn frame(m: *Machine, out: []u32, stride: u32, max: Size) Size {
        return m.vga.render(out, stride, max);
    }
    /// The sound since the last call: interleaved stereo i16 at `rate`
    /// (the host asks for as many frames as its device took).
    pub fn audio(m: *Machine, out: []i16, rate: u32) void {
        @memset(out, 0);
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
