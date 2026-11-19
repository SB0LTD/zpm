//! DOS's state, shared by dos21.sig and the dos_*.sig parts: the open
//! files (an SFT of the host's files and the character devices), the
//! searches find first/next left in programs' DTAs, the exec stack, the
//! console's line, the current directory and PSP, and the layout of DOS's
//! own data in conventional memory (the list of lists, the device chain,
//! the tables programs are given pointers to).

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");

pub const MAX_HANDLES = 64;
pub const MAX_SEARCH = 32;
pub const MAX_DEPTH = 8;
/// A host path's longest form (c_root and the real names under it).
pub const PATH_MAX = 260;
/// A canonical DOS path ("DIR\SUB\FILE.EXT", no drive, no leading '\').
pub const DOS_PATH = 128;
/// The current directory's longest form (DOS's 64 less "C:\").
pub const CWD_MAX = 64;
/// The handles a PSP's own table holds.
pub const JFT_SIZE = 20;
/// The one drive (C:, 1-based 3); the logical drives programs may name.
pub const DRIVE_C = 2;
pub const LASTDRIVE = 5;

/// DOS's data in conventional memory, offsets in its segment.
pub const D_CRIT_ERR: u16 = 0x0000;
pub const D_INDOS: u16 = 0x0001;
pub const D_RETF: u16 = 0x0002;
pub const D_MEDIA: u16 = 0x0003;
pub const D_DBCS: u16 = 0x0004;
pub const D_LOL: u16 = 0x0030;
pub const D_NUL: u16 = D_LOL + 0x22;
pub const D_CON: u16 = 0x00A0;
pub const D_CLOCK: u16 = 0x00B4;
pub const D_DPB: u16 = 0x00C8;
pub const D_CDS: u16 = 0x00F0;
pub const CDS_SIZE: u16 = 0x58;
pub const D_UPPER: u16 = 0x02B0;
pub const D_FUPPER: u16 = 0x0340;
pub const D_FTERM: u16 = 0x03D0;
pub const D_COLLATE: u16 = 0x0400;
pub const D_SFT: u16 = 0x0510;
pub const SFT_FILES: u16 = 20;
pub const SFT_ENTRY: u16 = 0x3B;
/// The data block's size in paragraphs.
pub const D_PARAS: u16 = 0xA0;

pub const Kind = enum(u8) { free, con, nul, aux, prn, clock, emm, file };

/// An open file: what DOS's SFT entry holds, over the host's handle.
pub const Sft = struct {
    kind: Kind = .free,
    refs: u8 = 0,
    fd: i32 = -1,
    /// 0 read, 1 write, 2 both.
    access: u2 = 0,
    no_inherit: bool = false,
    written: bool = false,
    /// CON's raw mode (IOCTL 01h, bit 5).
    raw: bool = false,
    /// 57h/01h's date and time (the host keeps its own).
    dt_set: bool = false,
    time: u16 = 0,
    date: u16 = 0,
    attr: u8 = 0x20,
    path_len: u16 = 0,
    path: [PATH_MAX]u8 = undefined,
    pub fn hostPath(self: *const Sft) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// A find first/next search: the folder and what it looks for. The DTA
/// holds its number, generation and position.
pub const Search = struct {
    gen: u16 = 0,
    attr: u8 = 0,
    pattern: [11]u8 = [_]u8{' '} ** 11,
    root: bool = true,
    dir_len: u16 = 0,
    dir: [PATH_MAX]u8 = undefined,
    pub fn hostDir(self: *const Search) []const u8 {
        return self.dir[0..self.dir_len];
    }
};

/// A parent waiting for its child (exec 4B00h): its registers at the
/// call, its PSP and DTA.
pub const Frame = struct {
    regs: Regs = .{},
    psp: u16 = 0,
    child: u16 = 0,
    dta_seg: u16 = 0,
    dta_off: u16 = 0,
};

pub const State = struct {
    /// The program asked to end (int 20h, 21h/00h, 21h/4Ch with no parent).
    exited: bool = false,
    exit_code: u8 = 0,

    // Drive C: is the host folder `root`.
    root_len: u16 = 0,
    root: [PATH_MAX]u8 = undefined,
    cwd_len: u16 = 0,
    cwd: [CWD_MAX]u8 = undefined,

    sft: [MAX_HANDLES]Sft = [_]Sft{.{}} ** MAX_HANDLES,

    // Memory: the MCB chain from `first_mcb`, conventional memory's end.
    first_mcb: u16 = 0,
    mem_end: u16 = 0xA000,
    strategy: u8 = 0,
    /// DOS's data segment.
    dseg: u16 = 0,

    // Processes.
    psp: u16 = 0,
    shell: u16 = 0,
    dta_seg: u16 = 0,
    dta_off: u16 = 0x80,
    frames: [MAX_DEPTH]Frame = [_]Frame{.{}} ** MAX_DEPTH,
    depth: u8 = 0,
    return_code: u16 = 0,

    // Errors (59h), switches.
    last_error: u16 = 0,
    last_class: u8 = 0,
    last_action: u8 = 0,
    last_locus: u8 = 0,
    break_on: bool = false,
    verify: bool = false,

    // Searches, and the host folder kept open for the latest one.
    searches: [MAX_SEARCH]Search = [_]Search{.{}} ** MAX_SEARCH,
    search_next: u8 = 0,
    search_gen: u16 = 0,
    cache_slot: i16 = -1,
    cache_dir: i32 = -1,
    cache_raw: u32 = 0,
    /// The FCB find's search (11h/12h): one at a time.
    fcb_slot: u8 = 0xFF,
    fcb_gen: u16 = 0,
    fcb_index: u16 = 0,
    fcb_ext: bool = false,

    // The console.
    line_active: bool = false,
    line_len: u8 = 0,
    line: [128]u8 = undefined,
    cin_len: u8 = 0,
    cin_pos: u8 = 0,
    cin: [130]u8 = undefined,
    pending_scan: ?u8 = null,
    flushing: bool = false,
    /// Console output straight into text-mode video memory (B800:0, the
    /// BIOS cursor at 0x450); false: only the ring below (for a machine
    /// that hands it to int 10h's teletype).
    tty_direct: bool = true,
    out_ring: [256]u8 = undefined,
    out_head: u8 = 0,
    out_len: u16 = 0,
    log_len: u8 = 0,
    log_line: [120]u8 = undefined,

    temp_count: u16 = 0,
    /// int 21h functions already reported as missing (one log line each).
    told: [256]bool = [_]bool{false} ** 256,

    pub fn reset(self: *State) void {
        self.* = .{};
    }
    pub fn rootPath(self: *const State) []const u8 {
        return self.root[0..self.root_len];
    }
    pub fn cwdPath(self: *const State) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    /// The error a call failed with, for 59h, and the carry and AX.
    pub fn fail(self: *State, r: *Regs, code: u16) void {
        self.last_error = code;
        self.last_class = switch (code) {
            2, 3, 0x12 => 8, // not found
            4, 8 => 1, // out of resource
            5 => 3, // authorisation
            0x50 => 12, // already exists
            else => 7, // application error
        };
        self.last_action = if (code == 4 or code == 8) 4 else 3;
        self.last_locus = switch (code) {
            2, 3, 5, 0x12, 0x50 => 2, // block device
            8 => 5, // memory
            else => 1,
        };
        r.fail(code);
    }
};

/// A DOS error from a host's negative result.
pub fn hostErr(ret: anytype) u16 {
    const v: i64 = -@as(i64, ret);
    return switch (v) {
        2, 3, 4, 5, 6, 0x50 => @intCast(v),
        else => 0x1F,
    };
}

/// seg:off of a far pointer stored as a dword (offset low).
pub fn farLin(mem: *const Memory, at: u32) u32 {
    return Memory.lin(mem.rd16(at + 2), mem.rd16(at));
}

/// DOS's date and time from the host's seconds since 1970 (as given: the
/// host's clock has no time zone to offer here).
pub fn dosDateTime(secs: i64) struct { date: u16, time: u16 } {
    if (secs < 315_532_800) return .{ .date = (0 << 9) | (1 << 5) | 1, .time = 0 }; // before 1980
    const days: i64 = @divFloor(secs, 86400);
    const rem: i64 = secs - days * 86400;
    // Days to a civil date (the proleptic Gregorian calendar).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    const yy: u16 = @intCast(@min(@max(y - 1980, 0), 127));
    const h: u16 = @intCast(@divFloor(rem, 3600));
    const mi: u16 = @intCast(@divFloor(@mod(rem, 3600), 60));
    const s: u16 = @intCast(@mod(rem, 60));
    return .{
        .date = (yy << 9) | (@as(u16, @intCast(m)) << 5) | @as(u16, @intCast(d)),
        .time = (h << 11) | (mi << 5) | (s / 2),
    };
}
