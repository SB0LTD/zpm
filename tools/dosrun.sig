//! dosrun: a DOS program on zpm's PC (src/dos), headless, as fast as the
//! host runs it: for testing the PC on real programs without Galaxy.
//!
//!   sig build-exe -target x86_64-linux-none -OReleaseFast --dep dos \
//!     -Mroot=tools/dosrun.sig -Mdos=src/dos/dos.sig --name dosrun
//!   dosrun PROGRAM.EXE [ARGS...] [--secs N] [--shot OUT.ppm] [--every S]
//!          [--key T=CODE[,CODE...]]... [--ips N] [--trace] [--wav OUT.wav]
//!
//! --secs N: emulated seconds to run (default 10); --shot: the picture at
//! the end as a PPM (--every S: also OUT-<t>.ppm every S seconds); --key
//! T=CODE: set-1 scan codes (hex) pushed at T emulated seconds, e.g.
//! --key 3=1c,9c (Enter pressed and released at 3 s). The log says why a
//! program stopped, and how fast the PC ran. --wav: the sound (48 kHz
//! stereo, 16-bit) into a WAV file, and its loudness in the log.

const std = @import("std");
const linux = std.os.linux;
const dos = @import("dos");

var machine: dos.Machine = undefined;
var host: dos.host_linux.LinuxHost = .{ .prefix = "[dos] " };
/// The largest picture: VESA's 1600x1200.
const MAX_W = 1600;
const MAX_H = 1200;
var screen: [MAX_W * MAX_H]u32 = undefined;
var ppm: [MAX_W * MAX_H * 3 + 32]u8 = undefined;

fn out(comptime f: []const u8, args: anytype) void {
    var b: [400]u8 = undefined;
    const s = std.fmt.bufPrint(&b, f ++ "\n", args) catch return;
    _ = linux.write(2, s.ptr, s.len);
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Key = struct { at_us: u64, codes: [16]u8, n: u8, done: bool = false };

fn shot(path: []const u8) void {
    const sz = machine.frame(&screen, MAX_W, .{ .w = MAX_W, .h = MAX_H });
    if (sz.w == 0 or sz.h == 0) {
        out("dosrun: no picture to save ({s})", .{path});
        return;
    }
    const head = std.fmt.bufPrint(&ppm, "P6\n{d} {d}\n255\n", .{ sz.w, sz.h }) catch return;
    var n = head.len;
    var y: usize = 0;
    while (y < sz.h) : (y += 1) {
        for (screen[y * MAX_W ..][0..sz.w]) |px| {
            ppm[n] = @truncate(px >> 16);
            ppm[n + 1] = @truncate(px >> 8);
            ppm[n + 2] = @truncate(px);
            n += 3;
        }
    }
    var pb: [512]u8 = undefined;
    if (path.len >= pb.len) return;
    @memcpy(pb[0..path.len], path);
    pb[path.len] = 0;
    const r = linux.openat(linux.AT.FDCWD, @ptrCast(&pb), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (@as(isize, @bitCast(r)) < 0) return;
    _ = linux.write(@intCast(r), &ppm, n);
    _ = linux.close(@intCast(r));
    out("dosrun: {s} ({d}x{d})", .{ path, sz.w, sz.h });
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var prog: ?[]const u8 = null;
    var pargs: [16][]const u8 = undefined;
    var np: usize = 0;
    var secs: u64 = 10;
    var every: u64 = 0;
    var shot_path: ?[]const u8 = null;
    var keys: [64]Key = undefined;
    var nk: usize = 0;
    var ips: u32 = 25_000_000;
    var trace = false;
    var wav_path: ?[]const u8 = null;

    var it = init.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--secs")) {
            secs = std.fmt.parseInt(u64, it.next() orelse "10", 10) catch 10;
        } else if (std.mem.eql(u8, a, "--every")) {
            every = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        } else if (std.mem.eql(u8, a, "--shot")) {
            shot_path = it.next();
        } else if (std.mem.eql(u8, a, "--wav")) {
            wav_path = it.next();
        } else if (std.mem.eql(u8, a, "--trace")) {
            trace = true;
        } else if (std.mem.eql(u8, a, "--ips")) {
            ips = std.fmt.parseInt(u32, it.next() orelse "25000000", 10) catch ips;
        } else if (std.mem.eql(u8, a, "--key")) {
            const spec = it.next() orelse break;
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse continue;
            if (nk >= keys.len) continue;
            const t = std.fmt.parseFloat(f64, spec[0..eq]) catch continue;
            var k = Key{ .at_us = @intFromFloat(t * 1e6), .codes = undefined, .n = 0 };
            var cs = std.mem.splitScalar(u8, spec[eq + 1 ..], ',');
            while (cs.next()) |c| {
                if (k.n >= k.codes.len) break;
                k.codes[k.n] = std.fmt.parseInt(u8, c, 16) catch continue;
                k.n += 1;
            }
            keys[nk] = k;
            nk += 1;
        } else if (prog == null) {
            prog = a;
        } else if (np < pargs.len) {
            pargs[np] = a;
            np += 1;
        }
    }
    const path = prog orelse {
        out("usage: dosrun PROGRAM.EXE [ARGS...] [--secs N] [--shot OUT.ppm] [--every S] [--key T=CODE,...] [--ips N]", .{});
        return 2;
    };
    var db: [512]u8 = undefined;
    var pb: [140]u8 = undefined;
    const p = dos.host_linux.splitProgram(path, &db, &pb) orelse return 2;
    var tail: [127]u8 = undefined;
    var tl: usize = 0;
    for (pargs[0..np]) |a| {
        if (tl + 1 + a.len > tail.len) break;
        tail[tl] = ' ';
        @memcpy(tail[tl + 1 ..][0..a.len], a);
        tl += 1 + a.len;
    }

    machine.init(host.host(), p.dir);
    machine.ips = ips;
    machine.trace = trace;
    if (!machine.start(p.dos_path, tail[0..tl])) return 1;
    out("dosrun: {s}, C: = {s}, {d} s at {d} M instructions/s", .{ p.dos_path, p.dir, secs, ips / 1_000_000 });
    {
        const r = &machine.cpu.regs;
        out("dosrun: starts at {x:0>4}:{x:0>4}, stack {x:0>4}:{x:0>4}, PSP {x:0>4}{s}", .{ r.seg[dos.regs.CS], @as(u16, @truncate(r.eip)), r.seg[dos.regs.SS], r.sp(), r.seg[dos.regs.DS], if (machine.dos.exited) " (already ended?)" else "" });
        var code: [16]u8 = undefined;
        for (&code, 0..) |*c, i| c.* = machine.rd8(r.base[dos.regs.CS] +% r.eip +% @as(u32, @intCast(i)));
        out("dosrun: its first bytes {x}", .{code});
        // DOSRUN_DUMP: the first 64 KiB from CS:0 into /tmp/dosrun-cs.bin
        {
            var dump: [65536]u8 = undefined;
            for (&dump, 0..) |*c, i| c.* = machine.rd8(r.base[dos.regs.CS] +% @as(u32, @intCast(i)));
            const fd = linux.openat(linux.AT.FDCWD, "/tmp/dosrun-cs.bin", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
            if (@as(isize, @bitCast(fd)) >= 0) {
                _ = linux.write(@intCast(fd), &dump, dump.len);
                _ = linux.close(@intCast(fd));
            }
        }
    }

    const t0 = nowNs();
    const step_us: u32 = 10_000;
    var t_us: u64 = 0;
    var next_shot: u64 = if (every > 0) every * 1_000_000 else std.math.maxInt(u64);
    var audio: [960]i16 = undefined;
    var wav_fd: i32 = -1;
    var wav_bytes: u32 = 0;
    var peak: u16 = 0;
    var sum_sq: f64 = 0;
    var samples: u64 = 0;
    if (wav_path) |wp| {
        var wb: [512]u8 = undefined;
        if (wp.len < wb.len) {
            @memcpy(wb[0..wp.len], wp);
            wb[wp.len] = 0;
            const fd = linux.openat(linux.AT.FDCWD, @ptrCast(&wb), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
            if (@as(isize, @bitCast(fd)) >= 0) {
                wav_fd = @intCast(fd);
                var hdr: [44]u8 = [_]u8{0} ** 44;
                _ = linux.write(wav_fd, &hdr, hdr.len); // (filled in at the end)
            }
        }
    }
    var status: dos.Status = .ran;
    while (t_us < secs * 1_000_000) : (t_us += step_us) {
        for (keys[0..nk]) |*k| if (!k.done and t_us >= k.at_us) {
            for (k.codes[0..k.n]) |c| machine.key(c);
            k.done = true;
        };
        status = machine.run(step_us);
        // (the sound is pulled as a host would, and dropped)
        machine.audio(&audio, 48000);
        for (audio) |v| {
            const a: u16 = @abs(v);
            if (a > peak) peak = a;
            const f: f64 = @floatFromInt(v);
            sum_sq += f * f;
        }
        samples += audio.len;
        if (wav_fd >= 0) {
            _ = linux.write(wav_fd, @ptrCast(&audio), audio.len * 2);
            wav_bytes += audio.len * 2;
        }
        if (status != .ran) break;
        if (t_us >= next_shot) {
            if (shot_path) |sp| {
                var nb: [512]u8 = undefined;
                const base = if (std.mem.endsWith(u8, sp, ".ppm")) sp[0 .. sp.len - 4] else sp;
                const name = std.fmt.bufPrint(&nb, "{s}-{d}.ppm", .{ base, t_us / 1_000_000 }) catch sp;
                shot(name);
            }
            next_shot += every * 1_000_000;
        }
    }
    const wall = @as(f64, @floatFromInt(nowNs() - t0)) / 1e9;
    const emu = @as(f64, @floatFromInt(t_us)) / 1e6;
    out("dosrun: {s} after {d:.2} emulated s in {d:.2} s ({d:.1}x real time), {d} M instructions", .{
        @tagName(status), emu, wall, emu / @max(wall, 1e-6), machine.cpu.executed / 1_000_000,
    });
    if (status == .exited) out("dosrun: exit code {d}", .{machine.dos.exit_code});
    if (samples > 0) out("dosrun: sound peak {d}, rms {d:.0}", .{ peak, @sqrt(sum_sq / @as(f64, @floatFromInt(samples))) });
    if (wav_fd >= 0) {
        var hdr: [44]u8 = undefined;
        @memcpy(hdr[0..4], "RIFF");
        std.mem.writeInt(u32, hdr[4..8], 36 + wav_bytes, .little);
        @memcpy(hdr[8..16], "WAVEfmt ");
        std.mem.writeInt(u32, hdr[16..20], 16, .little);
        std.mem.writeInt(u16, hdr[20..22], 1, .little);
        std.mem.writeInt(u16, hdr[22..24], 2, .little);
        std.mem.writeInt(u32, hdr[24..28], 48000, .little);
        std.mem.writeInt(u32, hdr[28..32], 48000 * 4, .little);
        std.mem.writeInt(u16, hdr[32..34], 4, .little);
        std.mem.writeInt(u16, hdr[34..36], 16, .little);
        @memcpy(hdr[36..40], "data");
        std.mem.writeInt(u32, hdr[40..44], wav_bytes, .little);
        _ = linux.lseek(wav_fd, 0, linux.SEEK.SET);
        _ = linux.write(wav_fd, &hdr, hdr.len);
        _ = linux.close(wav_fd);
    }
    {
        const r = &machine.cpu.regs;
        var code: [16]u8 = undefined;
        for (&code, 0..) |*c, i| c.* = machine.rd8(r.base[dos.regs.CS] +% r.eip +% @as(u32, @intCast(i)));
        // (with paging on, CS:EIP is a linear address the bytes are not at)
        if (machine.cpu.cr0 & 0x8000_0000 != 0) @memset(&code, 0);
        out("dosrun: ends at {x:0>4}:{x:0>8} (CR0 {x}), eax {x} ecx {x} edx {x} ebx {x} esp {x}, bytes {x}", .{ r.seg[dos.regs.CS], r.eip, machine.cpu.cr0, r.r[0], r.r[1], r.r[2], r.r[3], r.r[4], code });
    }
    if (shot_path) |sp| shot(sp);
    return if (status == .fault) 1 else 0;
}
