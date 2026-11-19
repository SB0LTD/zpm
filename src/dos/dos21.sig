//! DOS itself, written in Sig (a DOS 5.0 as programs see it): int 20h,
//! 21h (console I/O through the BIOS, files and handles with SFT-like
//! state over the host's files, FCB functions programs of the era still
//! use, find first/next with the DTA, directories, drives (C: is the
//! program's folder on the host; Z: holds nothing), memory blocks (the
//! MCB chain, allocate/free/resize, UMB link off), the PSP and the
//! environment, exec (load and run, load overlay, load only), exit codes,
//! date and time, IOCTL (device info, removable, remote), the country
//! info, the InDOS flag and the list of lists), 25h/26h refused, 27h, 28h,
//! 2Fh (XMS's 4300h/4310h, DPMI's 1687h "none", 1600h "no Windows"),
//! 33h (the mouse: mouse.sig). MZ and COM programs (mz.sig).
//! STUB: the API; the services come next.

const std = @import("std");
const Regs = @import("regs.sig").Regs;
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");

pub const MAX_HANDLES = 64;

pub const State = struct {
    /// The program asked to end (int 20h, 21h/00h, 21h/4Ch with no parent).
    exited: bool = false,
    exit_code: u8 = 0,
    pub fn reset(self: *State) void {
        self.* = .{};
    }
};

/// DOS at boot: the MCB chain over conventional memory from `first_seg`
/// to `top_seg`, the list of lists, the standard handles (CON), drive C:
/// at the host's `c_root` folder.
pub fn boot(st: *State, mem: *Memory, host: host_mod.Host, c_root: []const u8, first_seg: u16, top_seg: u16) void {
    _ = st;
    _ = mem;
    _ = host;
    _ = c_root;
    _ = first_seg;
    _ = top_seg;
}

/// Loads `path` (a DOS path: "C:\\ALADDIN.EXE") with its command tail as
/// the first program, its PSP and environment made; returns the CS:IP and
/// SS:SP to start at, or the DOS error.
pub fn start(st: *State, r: *Regs, mem: *Memory, host: host_mod.Host, path: []const u8, tail: []const u8) ?u16 {
    _ = st;
    _ = r;
    _ = mem;
    _ = host;
    _ = path;
    _ = tail;
    return 2;
}

/// int 21h: false when the call must wait for a key (01h, 07h, 08h, 0Ah,
/// 3Fh on CON): the machine runs it again after the next interrupt.
pub fn int21(st: *State, r: *Regs, mem: *Memory, host: host_mod.Host) bool {
    _ = st;
    _ = mem;
    host.say("dos: int 21h ah={x:0>2} not implemented", .{r.ah()});
    r.fail(1);
    return true;
}

/// int 2Fh (the multiplex interrupt).
pub fn int2f(st: *State, r: *Regs, mem: *Memory) void {
    _ = st;
    _ = r;
    _ = mem;
}
