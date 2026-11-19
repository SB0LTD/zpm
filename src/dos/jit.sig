//! The translator: guest x86 code (real mode, 16- and 32-bit protected
//! mode, paging) turned block by block into the host's own code (x86-64:
//! jit_x64.sig; AArch64: jit_a64.sig), so programs run several times as
//! fast as cpu.sig's interpreter runs them, with the same results.
//!
//! A block is a run of guest instructions from one entry point, all on
//! one 4 KiB page, up to a branch (jit_dec.sig decodes them as the
//! interpreter does). Every instruction a template exists for runs as
//! native code on the guest's registers in `Cpu.regs`; every other one is
//! a call into the interpreter for exactly that instruction (`stepJit`),
//! so every program runs. Arithmetic flags are computed only where a
//! later instruction (in the block or at the start of the blocks it goes
//! to) reads them before they are written again.
//!
//! The cache: blocks keyed by the host address of their first byte (the
//! RAM's: a physical page, whatever maps it), their EIP and the mode they
//! were made for (PE, code and stack size, CPL, flat segments, the A20
//! gate, the FPU's availability). Fixed tables, no allocation: when the
//! code memory or the table is full, everything is dropped and made anew.
//! A block's exit to another block on its page jumps there directly once
//! both exist (chaining); other exits look the target up in a direct-
//! mapped table, then the dispatcher.
//!
//! Code that changes: a RAM page with blocks is marked in the machine's
//! `jit_pages`; the TLB gives no direct write pointer for it, and the
//! machine's RAM writes look at the mark, so every write to it reaches
//! `written`, which drops the blocks whose bytes it touches (the block
//! running ends after the instruction). The BIOS's and DOS's services
//! write memory past the CPU: after them the blocks are checked against
//! their bytes (`afterService`).
//!
//! What stays exact: faults restart their instruction with EIP and ESP as
//! it began (templates do their memory accesses before they change a
//! register), interrupts are taken at the instruction boundaries the
//! interpreter takes them at (whatever can raise one ends its block),
//! `executed` counts every instruction, the trace flag
//! and the interrupt shadow single-step in the interpreter; a block runs
//! only if all of it fits in the budget left (else its instructions are
//! interpreted one at a time), so a run stops where the interpreter's
//! would. Lockstep
//! (`check`): every block's results compared with a second, interpreted
//! PC's (machine.sig's twin, jit_check.sig).

const std = @import("std");
const builtin = @import("builtin");
const cpu_mod = @import("cpu.sig");
const pm = @import("cpu_pm.sig");
const regs_mod = @import("regs.sig");
const host_mod = @import("host.sig");
const mem_mod = @import("mem.sig");
pub const dec = @import("jit_dec.sig");

const Cpu = cpu_mod.Cpu;
const Exit = cpu_mod.Exit;

/// The host's code generator, if there is one for it.
pub const be = switch (builtin.cpu.arch) {
    .x86_64 => @import("jit_x64.sig"),
    // (AArch64: jit_a64.sig, once it has the templates)
    .aarch64 => void,
    else => void,
};
pub const have_backend = be != void;

pub const PAGES: usize = mem_mod.RAM >> 12;
pub const CODE_SIZE: usize = 32 << 20;
pub const MAX_BLOCKS: u32 = 1 << 16;
const HASH_N: u32 = 1 << 16;
pub const FAST_N: u32 = 1 << 14;
/// The most instructions in a block.
pub const MAX_INS: u32 = 64;
/// The most code bytes one block may take.
pub const MAX_CODE: usize = 64 * 1024;

const PE = cpu_mod.CR0_PE;
const TF = regs_mod.TF;
const IF = regs_mod.IF;
const CS = regs_mod.CS;

/// The mode bits a block is made for (`mode`).
pub const M_PE: u32 = 1 << 0;
pub const M_CODE32: u32 = 1 << 1;
pub const M_STACK32: u32 = 1 << 2;
pub const M_USER: u32 = 1 << 3; // CPL 3
pub const M_CPL_SHIFT = 4; // (2 bits)
pub const M_FLAT_SHIFT = 6; // (6 bits: seg_flat)
pub const M_FPU: u32 = 1 << 12; // CR0.EM and TS clear: x87 runs directly
pub const M_A20: u32 = 1 << 13;
pub const M_CSFLAT: u32 = 1 << 14; // CS limit 4 GiB (chains may cross pages... no: may skip the limit check)
pub const M_CHECK: u32 = 1 << 15; // made for lockstep (no chaining)
pub const M_PAGING: u32 = 1 << 16; // CR0.PG: linear pages may move

/// An exit's code (the value generated code returns): the kind, the
/// instructions of the block not run (`adj`), the exit's chain slot.
pub const X_NEXT: u64 = 1;
pub const X_BUDGET: u64 = 2;
pub const X_RET: u64 = 3;
pub inline fn exitCode(kind: u64, adj: u32, edge: u32) u64 {
    return kind | (@as(u64, adj) << 8) | (@as(u64, edge) << 32);
}

/// What generated code sees (its base register points here).
pub const Ctx = extern struct {
    cpu: usize = 0,
    ram: usize = 0,
    bus: usize = 0,
    /// `executed` = end - r14 - adj, r14 the budget register.
    end: u64 = 0,
    r14: i64 = 0,
    /// The Exit a helper returned (X_RET).
    ret: u32 = 0,
    /// A block was dropped while a helper ran (the running one may be).
    inval: u32 = 0,
    /// The direct-mapped lookup table generated code probes.
    fast: usize = 0,
    /// The machine's page marks (jit_pages), the lockstep write log.
    pages: usize = 0,
    wlog: usize = 0,
    /// The helpers generated code calls (backend's table).
    helpers: [24]usize = [_]usize{0} ** 24,
    /// The lockstep write log: host address and size of each store.
    wlog_n: u32 = 0,
    wlog_pad: u32 = 0,
    scratch: [8]u64 = [_]u64{0} ** 8,
};

pub const FastEnt = extern struct {
    host: u64 = 0,
    key: u64 = 0,
    code: u64 = 0,
    /// The block's last byte's EIP (CS's limit must reach it).
    last: u64 = 0,
};

pub const Block = struct {
    /// The host address of its first guest byte (0: dead or free).
    host: usize = 0,
    eip: u32 = 0,
    mode: u32 = 0,
    /// Guest bytes [lo, hi) of its page it depends on (its own code, and
    /// the starts of the blocks it looked ahead into).
    lo: u16 = 0,
    hi: u16 = 0,
    /// Its own code's length; its last byte's EIP (CS's limit).
    len: u16 = 0,
    n: u16 = 0,
    last_eip: u32 = 0,
    /// Entry: offset in the code memory.
    code: u32 = 0,
    page: u32 = 0,
    sum: u64 = 0,
    next_pg: u32 = 0,
    next_hash: u32 = 0,
    /// Chain slots: where the patchable jump is (its rel32's offset), the
    /// EIP it goes to, the block it is chained to (+1).
    slot_at: [2]u32 = .{ 0, 0 },
    slot_eip: [2]u32 = .{ 0, 0 },
    slot_to: [2]u32 = .{ 0, 0 },
    /// Incoming chains: the first edge (src*2+slot, +1); each edge's next.
    in_head: u32 = 0,
    in_next: [2]u32 = .{ 0, 0 },
    /// Bytes [dyn_lo, dyn_hi) of its page the code does not depend on
    /// (instructions that are written while they run: the interpreter
    /// reads them anew each time).
    dyn_lo: [2]u16 = .{ 0, 0 },
    dyn_hi: [2]u16 = .{ 0, 0 },

    fn dynamic(k: *const Block, lo: u32, hi: u32) bool {
        inline for (0..2) |i| {
            if (k.dyn_hi[i] > k.dyn_lo[i] and lo >= k.dyn_lo[i] and hi <= k.dyn_hi[i]) return true;
        }
        return false;
    }
};

/// Code that writes itself while it runs (a routine patching an operand
/// of its own loop): the bytes written on a page while a block used them.
/// A block made again over them leaves their instructions to the
/// interpreter, so the writes no longer drop it. A few pages' worth.
const VOL_N = 64;
var vol_slot: [PAGES]u8 = undefined;
var vol_bits: [VOL_N][512]u8 = undefined;
var vol_used: u32 = 0;

fn volMark(p: u32, lo: u32, hi: u32) void {
    var s = vol_slot[p];
    if (s == 0) {
        if (vol_used >= VOL_N) return;
        vol_used += 1;
        s = @intCast(vol_used);
        vol_slot[p] = s;
        @memset(&vol_bits[s - 1], 0);
    }
    var i = lo;
    while (i < hi) : (i += 1) vol_bits[s - 1][i >> 3] |= @as(u8, 1) << @intCast(i & 7);
}

pub fn volatileAt(p: u32, lo: u32, hi: u32) bool {
    const s = vol_slot[p];
    if (s == 0) return false;
    var i = lo;
    while (i < hi) : (i += 1) {
        if (vol_bits[s - 1][i >> 3] & (@as(u8, 1) << @intCast(i & 7)) != 0) return true;
    }
    return false;
}

pub var blocks: [MAX_BLOCKS]Block = undefined;
var hash_head: [HASH_N]u32 = undefined;
pub var fast: [FAST_N]FastEnt align(64) = undefined;
var pg_head: [PAGES]u32 = undefined;
var pg_mask: [PAGES]u64 = undefined;

/// Lockstep: what a stretch of code did, for jit_check.sig.
pub const CheckInfo = struct {
    /// Instructions run.
    n: u64,
    /// Where it started.
    eip: u32,
    cs: u16,
    /// Flags the code left stale (dead: written again before any read).
    dead: u32 = 0,
    /// A block (else a single interpreted step).
    block: bool,
    /// `poll` as the stretch began (the twin starts with the same).
    poll: bool = false,
    /// The stores it made (host addresses, sizes).
    wlog: []const WLog,
};

pub const WLog = extern struct { at: u64, n: u64 };
pub var wlog: [256]WLog = undefined;

pub const Stats = struct {
    blocks: u64 = 0,
    flushes: u64 = 0,
    invalidated: u64 = 0,
    verified: u64 = 0,
    entered: u64 = 0,
    interp: u64 = 0,
    chained: u64 = 0,
    helper_calls: u64 = 0,
    /// Drops by cause: a write to their bytes, a check after a service.
    drop_written: u64 = 0,
    drop_verify: u64 = 0,
    /// Exits to the dispatcher: through a chain slot, other.
    exit_slot: u64 = 0,
    exit_other: u64 = 0,
    exit_budget: u64 = 0,
};

pub const Jit = struct {
    on: bool = false,
    /// Lockstep with the machine's twin after every block.
    check: bool = false,
    cm: host_mod.CodeMem = undefined,
    used: usize = 0,
    nblocks: u32 = 1,
    ctx: Ctx = .{},
    pages: *[PAGES]u8 = undefined,
    ram: [*]u8 = undefined,
    cpu: *Cpu = undefined,
    /// Nested unlocks of the code memory (a flipping host).
    unlocked: u32 = 0,
    /// The written range since the last lock (AArch64's cache upkeep).
    dirty_lo: usize = std.math.maxInt(usize),
    dirty_hi: usize = 0,
    /// The backend's own fixed code (entry, exits) is at 0..stub_end.
    stub_end: usize = 0,
    stats: Stats = .{},
    /// Dead flags at the last block exit (lockstep).
    last_dead: u32 = 0,
    /// The block being run by generated code (+1), for lockstep.
    cur: u32 = 0,
    /// A bus for the dispatcher's twin checks: the raw one.
    trace: bool = false,

    // ── The code memory ────────────────────────────────────────────────

    pub fn unlock(j: *Jit) void {
        if (j.unlocked == 0) {
            if (j.cm.unlock) |f| f(j.cm.ctx);
        }
        j.unlocked += 1;
    }

    pub fn lock(j: *Jit) void {
        j.unlocked -= 1;
        if (j.unlocked != 0) return;
        if (j.dirty_hi > j.dirty_lo) {
            if (have_backend) be.syncCode(j.cm.rx + j.dirty_lo, j.dirty_hi - j.dirty_lo);
            j.dirty_lo = std.math.maxInt(usize);
            j.dirty_hi = 0;
        }
        if (j.cm.lock) |f| f(j.cm.ctx);
    }

    pub fn dirty(j: *Jit, off: usize, n: usize) void {
        j.dirty_lo = @min(j.dirty_lo, off);
        j.dirty_hi = @max(j.dirty_hi, off + n);
    }

    pub inline fn rxAddr(j: *const Jit, off: usize) usize {
        return @intFromPtr(j.cm.rx) + off;
    }

    // ── The tables ─────────────────────────────────────────────────────

    /// Everything dropped: no blocks, no code but the backend's own.
    pub fn flush(j: *Jit) void {
        j.stats.flushes += 1;
        j.nblocks = 1;
        j.used = j.stub_end;
        @memset(&hash_head, 0);
        @memset(std.mem.sliceAsBytes(&fast), 0);
        @memset(&pg_head, 0);
        @memset(&pg_mask, 0);
        @memset(&vol_slot, 0);
        vol_used = 0;
        @memset(j.pages, 0);
        j.ctx.inval = 1;
    }

    inline fn hashOf(host: usize, eip: u32, mode: u32) u32 {
        const x = @as(u64, host) *% 0x9E37_79B9_7F4A_7C15 ^ (@as(u64, eip) *% 0xC2B2_AE3D_27D4_EB4F) ^ mode;
        return @truncate(x >> 40);
    }

    pub inline fn fastIdx(host: usize, eip: u32) u32 {
        return @truncate((host ^ (@as(usize, eip) << 7)) & (FAST_N - 1));
    }

    pub fn find(j: *Jit, host: usize, eip: u32, mode: u32) ?u32 {
        _ = j;
        var b = hash_head[hashOf(host, eip, mode) & (HASH_N - 1)];
        while (b != 0) : (b = blocks[b].next_hash) {
            const k = &blocks[b];
            if (k.host == host and k.eip == eip and k.mode == mode) return b;
        }
        return null;
    }

    /// A new block's slot (null: the table is full).
    pub fn newBlock(j: *Jit) ?u32 {
        if (j.nblocks >= MAX_BLOCKS) return null;
        const b = j.nblocks;
        j.nblocks += 1;
        blocks[b] = .{};
        return b;
    }

    /// Makes block b findable and its page watched.
    pub fn publish(j: *Jit, b: u32) void {
        const k = &blocks[b];
        const h = hashOf(k.host, k.eip, k.mode) & (HASH_N - 1);
        k.next_hash = hash_head[h];
        hash_head[h] = b;
        const p = k.page;
        k.next_pg = pg_head[p];
        pg_head[p] = b;
        pg_mask[p] |= rangeMask(k.lo, k.hi);
        if (j.pages[p] == 0) {
            j.pages[p] = 1;
            // (no direct writes to it from the TLB any more)
            j.cpu.tlb.dropWrite(@intFromPtr(j.ram) + p * 4096);
        }
        j.stats.blocks += 1;
    }

    fn rangeMask(lo: u16, hi: u16) u64 {
        if (hi <= lo) return 0;
        const a: u6 = @intCast(lo >> 6);
        const z: u6 = @intCast((hi - 1) >> 6);
        const top: u64 = if (z == 63) ~@as(u64, 0) else (@as(u64, 1) << (z + 1)) - 1;
        return top & ~((@as(u64, 1) << a) - 1);
    }

    /// Block b dropped: unfindable, its chains undone, its entry made an
    /// exit to the dispatcher (generated code may still be running in it).
    pub fn invalidate(j: *Jit, b: u32) void {
        const k = &blocks[b];
        if (k.host == 0) return;
        j.stats.invalidated += 1;
        j.ctx.inval = 1;
        // The hash chain.
        const h = hashOf(k.host, k.eip, k.mode) & (HASH_N - 1);
        var pp: *u32 = &hash_head[h];
        while (pp.* != 0) : (pp = &blocks[pp.*].next_hash) {
            if (pp.* == b) {
                pp.* = k.next_hash;
                break;
            }
        }
        const fi = fastIdx(k.host, k.eip);
        if (fast[fi].code == j.rxAddr(k.code)) fast[fi] = .{};
        // The page's list and mask.
        const p = k.page;
        var q: *u32 = &pg_head[p];
        while (q.* != 0) : (q = &blocks[q.*].next_pg) {
            if (q.* == b) {
                q.* = k.next_pg;
                break;
            }
        }
        var mask: u64 = 0;
        var o = pg_head[p];
        while (o != 0) : (o = blocks[o].next_pg) mask |= rangeMask(blocks[o].lo, blocks[o].hi);
        pg_mask[p] = mask;
        if (pg_head[p] == 0) j.pages[p] = 0;
        j.unlock();
        // Chains into it, undone; its own chains, out of their targets' lists.
        var e = k.in_head;
        while (e != 0) {
            const src = (e - 1) >> 1;
            const slot: u1 = @truncate(e - 1);
            const nx = blocks[src].in_next[slot];
            blocks[src].slot_to[slot] = 0;
            blocks[src].in_next[slot] = 0;
            if (have_backend) be.unchain(j, src, slot);
            e = nx;
        }
        k.in_head = 0;
        inline for (0..2) |s| {
            if (k.slot_to[s] != 0) j.unlinkEdge(b, s);
        }
        if (have_backend) be.killEntry(j, b);
        j.lock();
        k.host = 0;
    }

    /// Edge b.slot out of its target's incoming list.
    fn unlinkEdge(j: *Jit, b: u32, comptime s: u1) void {
        _ = j;
        const k = &blocks[b];
        const t = k.slot_to[s] - 1;
        const me: u32 = b * 2 + s + 1;
        var pp: *u32 = &blocks[t].in_head;
        while (pp.* != 0) {
            if (pp.* == me) {
                pp.* = k.in_next[s];
                break;
            }
            const e = pp.* - 1;
            pp = &blocks[e >> 1].in_next[@as(u1, @truncate(e))];
        }
        k.slot_to[s] = 0;
        k.in_next[s] = 0;
    }

    /// Chains block b's slot s to block t (both alive, t on b's page).
    pub fn chain(j: *Jit, b: u32, s: u1, t: u32) void {
        const k = &blocks[b];
        if (k.slot_to[s] != 0) {
            if (s == 0) j.unlinkEdge(b, 0) else j.unlinkEdge(b, 1);
        }
        k.slot_to[s] = t + 1;
        k.in_next[s] = blocks[t].in_head;
        blocks[t].in_head = b * 2 + s + 1;
        j.unlock();
        if (have_backend) be.chainTo(j, b, s, t);
        j.lock();
        j.stats.chained += 1;
    }

    /// The machine wrote `n` bytes at RAM address `a` on a marked page.
    pub fn written(j: *Jit, a: u32, n: u32) void {
        var p: u32 = a >> 12;
        const last: u32 = (a + n - 1) >> 12;
        while (p <= last) : (p += 1) {
            if (j.pages[p] == 0) continue;
            const lo: u32 = if (p == a >> 12) a & 0xFFF else 0;
            const hi: u32 = if (p == last) ((a + n - 1) & 0xFFF) + 1 else 4096;
            if (pg_mask[p] & rangeMask(@intCast(lo), @intCast(hi)) == 0) continue;
            var b = pg_head[p];
            while (b != 0) {
                const nx = blocks[b].next_pg;
                if (blocks[b].lo < hi and blocks[b].hi > lo and !blocks[b].dynamic(lo, hi)) {
                    volMark(p, lo, hi);
                    j.stats.drop_written += 1;
                    j.invalidate(b);
                }
                b = nx;
            }
        }
    }

    /// After a BIOS or DOS service (id: its trap's number, ax: AX as it
    /// was called): those that only change registers, the stack, the
    /// BIOS's data or the vector table (the timer's and keyboard's
    /// interrupts, the keyboard, clock and mouse, DOS's time, handles
    /// and console) cost a look at page 0; any other may have written
    /// anywhere (a file read, a block move, an EXEC), and every block's
    /// bytes are checked.
    pub fn afterService(j: *Jit, id: u16, ax: u16) void {
        if (!j.on) return;
        const ah: u8 = @truncate(ax >> 8);
        const al: u8 = @truncate(ax);
        const safe = switch (id) {
            0x08, 0x09, 0x0A...0x0F, 0x70...0x77, 0x11, 0x12, 0x16, 0x1A, 0x1C, 0x2F, 0x101 => true,
            0x10 => !(ah == 0x1B or ah == 0x1C or ah == 0x4F or (ah == 0x10 and (al == 0x09 or al == 0x17))),
            0x15 => ah != 0x87,
            0x21 => switch (ah) {
                0x01, 0x02, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0E, 0x19, 0x25, 0x2A, 0x2C, 0x2D, 0x30, 0x33, 0x35, 0x3D, 0x3E, 0x40, 0x41, 0x42, 0x43, 0x45, 0x46, 0x57, 0x58, 0x62 => true,
                else => false,
            },
            0x33 => ax != 0x16,
            0x100 => ah != 0x0B,
            0x67 => ah != 0x57,
            else => false,
        };
        if (safe) j.verifyPage(0) else j.verifyAll();
    }

    pub fn verifyPage(j: *Jit, p: u32) void {
        var b = pg_head[p];
        while (b != 0) {
            const nx = blocks[b].next_pg;
            j.verify(b);
            b = nx;
        }
    }

    pub fn verifyAll(j: *Jit) void {
        var b: u32 = 1;
        while (b < j.nblocks) : (b += 1) {
            if (blocks[b].host != 0) j.verify(b);
        }
    }

    fn verify(j: *Jit, b: u32) void {
        const k = &blocks[b];
        j.stats.verified += 1;
        if (sumOf(j.ram, k) != k.sum) {
            j.stats.drop_verify += 1;
            j.invalidate(b);
        }
    }

    pub fn sumOf(ram: [*]u8, k: *const Block) u64 {
        const page: [*]const u8 = ram + @as(usize, k.page) * 4096;
        var h: u64 = 0xCBF2_9CE4_8422_2325;
        var i: usize = k.lo;
        while (i < k.hi) {
            if (k.dyn_hi[0] > k.dyn_lo[0] and i == k.dyn_lo[0]) {
                i = k.dyn_hi[0];
                continue;
            }
            if (k.dyn_hi[1] > k.dyn_lo[1] and i == k.dyn_lo[1]) {
                i = k.dyn_hi[1];
                continue;
            }
            h = (h ^ page[i]) *% 0x100_0000_01B3;
            i += 1;
        }
        return h;
    }
};

pub var the: Jit = .{};



/// The JIT for this bus type: a machine with RAM pages to watch.
pub fn supports(comptime B: type) bool {
    if (!have_backend) return false;
    const T = switch (@typeInfo(B)) {
        .pointer => |info| info.child,
        else => B,
    };
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "jitPages") and @hasDecl(T, "page");
}

/// The translator for `c` on the host's code memory (false if the host
/// has none, or this host has no code generator).
pub fn attach(c: *Cpu, host: host_mod.Host, pages: *[PAGES]u8, ram: *[mem_mod.RAM]u8) bool {
    if (!have_backend) return false;
    const j = &the;
    const cm = if (j.on and j.cm.len >= CODE_SIZE) j.cm else (host.codeMem(CODE_SIZE) orelse return false);
    j.* = .{};
    j.cm = cm;
    j.pages = pages;
    j.ram = ram;
    j.cpu = c;
    j.ctx = .{};
    j.ctx.cpu = @intFromPtr(c);
    j.ctx.ram = @intFromPtr(ram);
    j.ctx.fast = @intFromPtr(&fast);
    j.ctx.pages = @intFromPtr(pages);
    j.ctx.wlog = @intFromPtr(&wlog);
    j.unlock();
    j.stub_end = be.emitStubs(j);
    j.lock();
    j.on = true;
    j.flush();
    j.stats = .{};
    c.jit = j;
    return true;
}

/// Off again (the interpreter runs everything).
pub fn detach(c: *Cpu) void {
    if (c.jit) |j| j.on = false;
    c.jit = null;
}

// ── The dispatcher ─────────────────────────────────────────────────────

/// Cpu.run's with the translator: the same contract.
pub fn run(c: *Cpu, bus: anytype, budget: u32) Exit {
    c.poll = true;
    if (c.dead) return .fault;
    if (c.halted) {
        if (c.regs.flags & IF != 0 and bus.irq()) return .irq;
        return .halt;
    }
    const end = c.executed + budget;
    while (true) {
        const why = if (c.cr0 & PE != 0)
            Mode(@TypeOf(bus), true).loop(c, bus, end)
        else
            Mode(@TypeOf(bus), false).loop(c, bus, end);
        if (why) |w| return w;
    }
}

/// Block-local flag liveness: after[i], the arithmetic flags read after
/// instruction i before they are written again; returns what is live at
/// the block's end (all of them). In lockstep (`check`) anything that can
/// fault or leave through the interpreter counts as reading them all, so
/// the flags are exact wherever the twin may look.
pub fn liveness(ins: []const dec.Ins, after: []u32, check: bool) u32 {
    const live_out: u32 = dec.ARITH;
    var live = live_out;
    var i = ins.len;
    while (i > 0) {
        i -= 1;
        after[i] = live;
        const x = &ins[i];
        var rd: u32 = x.fr;
        if (check) {
            switch (x.kind) {
                .helper, .x87, .push, .pop, .call, .ret, .leave, .call_ind, .jmp_ind => rd = dec.ARITH,
                else => if (x.mem) {
                    rd = dec.ARITH;
                },
            }
        }
        live = (live & ~@as(u32, x.fw)) | rd;
    }
    return live_out;
}

/// The mode's block key for the CPU as it is.
pub fn modeKey(c: *const Cpu, comptime P: bool, a20: bool, check: bool) u32 {
    var m: u32 = 0;
    if (a20) m |= M_A20;
    if (c.cr0 & (cpu_mod.CR0_TS | 4) == 0) m |= M_FPU;
    if (check) m |= M_CHECK;
    if (!P) return m;
    m |= M_PE;
    if (c.paging) m |= M_PAGING;
    if (c.code32) m |= M_CODE32;
    if (c.stack32) m |= M_STACK32;
    if (c.cpl == 3) m |= M_USER;
    m |= @as(u32, c.cpl) << M_CPL_SHIFT;
    m |= @as(u32, c.seg_flat & 0x3F) << M_FLAT_SHIFT;
    if (c.fetch_hi == 0xFFFF_FFFF) m |= M_CSFLAT;
    return m;
}

/// What a helper compares before and after the instruction it ran: if
/// any of it changed, the block ends there.
pub const Sig = struct {
    cr0: u32,
    cs: u32,
    fetch_hi: u32,
    gen: u32,
    key: u32,
    cpl: u2,
    code32: bool,
    stack32: bool,
    flat: u8,

    pub fn of(c: *const Cpu) Sig {
        return .{ .cr0 = c.cr0, .cs = c.regs.base[CS], .fetch_hi = c.fetch_hi, .gen = c.tlb.gen, .key = c.tlb.key, .cpl = c.cpl, .code32 = c.code32, .stack32 = c.stack32, .flat = c.seg_flat };
    }
    pub fn eql(a: Sig, b: Sig) bool {
        return a.cr0 == b.cr0 and a.cs == b.cs and a.fetch_hi == b.fetch_hi and a.gen == b.gen and a.key == b.key and
            a.cpl == b.cpl and a.code32 == b.code32 and a.stack32 == b.stack32 and a.flat == b.flat;
    }
};

pub fn Mode(comptime B: type, comptime P: bool) type {
    return struct {
        const Bus = if (P) cpu_mod.PmBus(B) else B;

        inline fn modeBus(c: *Cpu, bus: B) Bus {
            return if (P) Bus{ .b = bus, .c = c } else bus;
        }

        fn mapKey(bus: B) u32 {
            return bus.mapKey();
        }

        /// The host address of the code at linear `lin`, if it is in RAM
        /// the TLB has (protected mode) or the bus maps (real mode).
        inline fn codeHost(j: *Jit, c: *Cpu, bus: B, lin: u32) ?usize {
            var h: usize = 0;
            if (P) {
                const i = (lin >> 12) & (pm.TLB_N - 1);
                const u = @intFromBool(c.cpl == 3);
                if (c.tlb.rtag[u][i] != (lin & 0xFFFF_F000) | 1) return null;
                h = c.tlb.hoff[i] +% lin;
            } else {
                const p = bus.page(lin & 0xFFFF_F000, false) orelse return null;
                h = @intFromPtr(p) + (lin & 0xFFF);
            }
            const r = @intFromPtr(j.ram);
            if (h < r or h >= r + mem_mod.RAM) return null;
            return h;
        }

        pub fn loop(c: *Cpu, bus: B, end: u64) ?Exit {
            const j = c.jit.?;
            if (P) {
                pm.syncAll(c);
                pm.checkKey(c, bus);
            }
            j.ctx.bus = @intFromPtr(bus);
            j.ctx.end = end;
            be.setHelpers(j, B, P);
            while (c.executed < end) {
                if (c.poll) {
                    if ((c.cr0 & PE != 0) != P) return null;
                    if (P) pm.checkKey(c, bus);
                    if (c.shadow) {
                        c.shadow = false;
                        if (single(j, c, bus, end, false, true)) |w| return w;
                        continue;
                    }
                    const f = c.regs.flags;
                    if (f & IF != 0 and bus.irq()) return .irq;
                    if (f & TF != 0) {
                        if (single(j, c, bus, end, true, true)) |w| return w;
                        continue;
                    }
                    c.poll = false;
                }
                const eip = c.regs.eip;
                const lin = c.regs.base[CS] +% eip;
                const b = lookup(j, c, bus, eip, lin) orelse {
                    if (single(j, c, bus, end, false, false)) |w| return w;
                    continue;
                };
                if (enter(j, c, bus, b, end)) |w| return w;
            }
            return .budget;
        }

        /// One instruction through the interpreter (the shadow, the trace
        /// trap, code with no block).
        fn single(j: *Jit, c: *Cpu, bus: B, end: u64, trace: bool, poll0: bool) ?Exit {
            j.stats.interp += 1;
            const e0 = c.executed;
            const eip0 = c.regs.eip;
            const cs0 = c.regs.seg[CS];
            const res = c.stepJit(modeBus(c, bus), end, true, trace);
            if (j.check) {
                const info = CheckInfo{ .n = c.executed - e0, .eip = eip0, .cs = cs0, .block = false, .poll = poll0, .wlog = &.{} };
                if (!bus.jitCheck(&info)) return checkFailed(c);
            }
            return res;
        }

        fn checkFailed(c: *Cpu) Exit {
            c.fault_op = 0x7D00_0000;
            c.fault_at = c.regs.base[CS] +% c.regs.eip;
            c.dead = true;
            return .fault;
        }

        /// The block for CS:EIP now, made if need be (null: interpret).
        fn lookup(j: *Jit, c: *Cpu, bus: B, eip: u32, lin: u32) ?u32 {
            if (!P and eip > 0xFFFF) return null;
            const host = codeHost(j, c, bus, lin) orelse return null;
            const mode = modeKey(c, P, mapKey(bus) != 0, j.check);
            const b = blk: {
                if (j.find(host, eip, mode)) |b| {
                    if (P and blocks[b].last_eip > c.fetch_hi) return null;
                    break :blk b;
                }
                break :blk translate(j, c, host, lin, eip, mode) orelse return null;
            };
            // (generated code's own lookup: blocks it may enter unchecked)
            fast[Jit.fastIdx(host, eip)] = .{ .host = host, .key = (@as(u64, eip) << 32) | mode, .code = j.rxAddr(blocks[b].code), .last = if (P) blocks[b].last_eip else 0 };
            return b;
        }

        fn translate(j: *Jit, c: *Cpu, host: usize, lin: u32, eip: u32, mode: u32) ?u32 {
            var ins: [MAX_INS]dec.Ins = undefined;
            var dyn: [2][2]u16 = .{ .{ 0, 0 }, .{ 0, 0 } };
            const n = decodeBlock(j, c, host, lin, eip, &ins, &dyn);
            if (n == 0) return null;
            if (j.used + MAX_CODE > j.cm.len or j.nblocks >= MAX_BLOCKS) j.flush();
            const b = j.newBlock() orelse return null;
            const k = &blocks[b];
            k.host = host;
            k.eip = eip;
            k.mode = mode;
            k.page = @intCast((host - @intFromPtr(j.ram)) >> 12);
            var len: u32 = 0;
            for (ins[0..n]) |x| len += x.len;
            k.len = @intCast(len);
            k.n = @intCast(n);
            k.last_eip = eip +% len -% 1;
            k.lo = @intCast(host & 0xFFF);
            k.hi = @intCast((host & 0xFFF) + len);
            inline for (0..2) |i| {
                k.dyn_lo[i] = dyn[i][0];
                k.dyn_hi[i] = dyn[i][1];
            }
            j.unlock();
            const ok = be.emitBlock(j, b, ins[0..n], mode, B, P);
            j.lock();
            if (!ok) {
                // (no room after all: start again with an empty cache)
                j.nblocks -= 1;
                j.flush();
                return null;
            }
            k.sum = Jit.sumOf(j.ram, k);
            j.publish(b);
            return b;
        }

        /// The block's instructions from `host` (EIP `eip`): to a branch,
        /// the page's end, CS's limit or the 64 KiB wrap, MAX_INS.
        fn decodeBlock(j: *Jit, c: *Cpu, host: usize, lin: u32, eip: u32, out: *[MAX_INS]dec.Ins, dyn: *[2][2]u16) u32 {
            _ = lin;
            const page: u32 = @intCast((host - @intFromPtr(j.ram)) >> 12);
            var ndyn: u32 = 0;
            const d32 = P and c.code32;
            const wrap: u32 = if (d32) 0xFFFF_FFFF else 0xFFFF;
            var n: u32 = 0;
            var off: u32 = @intCast(host & 0xFFF);
            var ip = eip;
            while (n < MAX_INS) {
                var avail: u64 = 4096 - off;
                if (!d32) avail = @min(avail, 0x10000 - @as(u64, ip & 0xFFFF));
                if (P) {
                    const lim: u64 = @min(@as(u64, c.fetch_hi), @as(u64, c.ip_wrap));
                    if (ip > lim) break;
                    avail = @min(avail, lim - ip + 1);
                }
                if (avail == 0) break;
                const p: [*]const u8 = @ptrFromInt(host - (host & 0xFFF) + off);
                var x = dec.decode(p, @intCast(avail), d32, ip, wrap) orelse break;
                // (16-bit code: an instruction that would wrap IP is left
                // to the interpreter)
                if (!d32 and @as(u64, ip) + x.len > 0x10000) break;
                if (volatileAt(page, off, off + x.len)) {
                    // (written while it runs: the interpreter's, read anew)
                    if (ndyn == 2) break;
                    dyn[ndyn] = .{ @intCast(off), @intCast(off + x.len) };
                    ndyn += 1;
                    x.kind = .helper;
                    x.fr = dec.ARITH;
                    x.fw = dec.ARITH;
                }
                out[n] = x;
                n += 1;
                off += x.len;
                ip = (ip +% x.len) & wrap;
                if (x.term) break;
            }
            return n;
        }

        fn enter(j: *Jit, c: *Cpu, bus: B, b: u32, end: u64) ?Exit {
            j.stats.entered += 1;
            const e0 = c.executed;
            const eip0 = c.regs.eip;
            const cs0 = c.regs.seg[CS];
            j.ctx.r14 = @intCast(end - c.executed);
            j.ctx.inval = 0;
            j.ctx.wlog_n = 0;
            j.cur = b + 1;
            const code = be.run(j, j.rxAddr(blocks[b].code));
            const kind = code & 0xFF;
            const adj: u32 = @truncate((code >> 8) & 0xFF_FFFF);
            c.executed = @intCast(@as(i64, @intCast(end)) - j.ctx.r14 - @as(i64, adj));
            if (j.check) {
                const info = CheckInfo{ .n = c.executed - e0, .eip = eip0, .cs = cs0, .block = true, .dead = j.last_dead, .wlog = wlog[0..@min(j.ctx.wlog_n, wlog.len)] };
                if (!bus.jitCheck(&info)) return checkFailed(c);
            }
            if (kind == X_RET) return @enumFromInt(j.ctx.ret);
            // (the block is longer than the budget left: the rest of it
            // one instruction at a time, so `executed` stays exact)
            if (kind == X_BUDGET and c.executed < end) return single(j, c, bus, end, false, false);
            if (kind == X_BUDGET) j.stats.exit_budget += 1 else if (code >> 32 != 0) j.stats.exit_slot += 1 else j.stats.exit_other += 1;
            if (kind == X_NEXT) {
                const edge: u32 = @truncate(code >> 32);
                if (edge != 0) chainExit(j, c, bus, edge - 1);
            }
            return null;
        }

        /// A chainable exit was taken: chain it to the block at its
        /// target if there is one (made now if need be) on its page.
        fn chainExit(j: *Jit, c: *Cpu, bus: B, edge: u32) void {
            const src = edge >> 1;
            const s: u1 = @truncate(edge);
            const k = &blocks[src];
            if (k.host == 0 or k.slot_to[s] != 0) return;
            if (j.ctx.inval != 0) return;
            const eip = c.regs.eip;
            if (eip != k.slot_eip[s]) return;
            if (c.poll) return;
            const lin = c.regs.base[CS] +% eip;
            const t = lookup(j, c, bus, eip, lin) orelse return;
            // (the source may have been dropped by a flush in lookup)
            if (k.host == 0 or blocks[t].host == 0) return;
            if (blocks[t].mode != k.mode) return;
            // (another page: only where linear pages cannot move)
            if (blocks[t].page != k.page and k.mode & M_PAGING != 0) return;
            j.chain(src, s, t);
        }

        // ── Helpers (called by generated code) ──────────────────────────

        /// Instruction k of the running block through the interpreter:
        /// `ip` its EIP and the next's (high half), `adj` the block's
        /// instructions after it. 0: go on; else the exit's code.
        pub fn hStep(ctx: *Ctx, ip: u64, adj: u64) callconv(.c) u64 {
            const c: *Cpu = @ptrFromInt(ctx.cpu);
            const bus: B = @ptrFromInt(ctx.bus);
            const a: u32 = @truncate(adj);
            const eip: u32 = @truncate(ip);
            const next: u32 = @truncate(ip >> 32);
            c.regs.eip = eip;
            c.executed = @intCast(@as(i64, @intCast(ctx.end)) - ctx.r14 - @as(i64, a));
            const s0 = Sig.of(c);
            ctx.inval = 0;
            const res = c.stepJit(modeBus(c, bus), ctx.end, false, false);
            ctx.r14 = @as(i64, @intCast(ctx.end)) - @as(i64, @intCast(c.executed)) - @as(i64, a);
            if (res) |e| {
                ctx.ret = @intFromEnum(e);
                return exitCode(X_RET, a, 0);
            }
            if (c.regs.eip != next or c.poll or ctx.inval != 0 or !Sig.of(c).eql(s0)) return exitCode(X_NEXT, a, 0);
            return 0;
        }

        /// An x87 instruction: the FPU's own code at linear `lin` (info:
        /// opcode, ModRM, o32, adj; ip: its EIP and the next's).
        pub fn hX87(ctx: *Ctx, lin: u64, info: u64, ip: u64) callconv(.c) u64 {
            const c: *Cpu = @ptrFromInt(ctx.cpu);
            const bus: B = @ptrFromInt(ctx.bus);
            const op: u8 = @truncate(info);
            const modrm: u8 = @truncate(info >> 8);
            const o32 = (info >> 16) & 1 != 0;
            const a: u32 = @truncate((info >> 24) & 0xFF);
            const eip: u32 = @truncate(ip);
            c.executed = @intCast(@as(i64, @intCast(ctx.end)) - ctx.r14 - @as(i64, a));
            ctx.inval = 0;
            if (!c.fpu.esc(modeBus(c, bus), &c.regs, op, modrm, @truncate(lin), o32, c.regs.base[CS] +% eip)) {
                // (not an instruction after all: the interpreter's #UD)
                return hStep(ctx, ip, a);
            }
            if (P and c.sticky) {
                c.sticky = false;
                c.regs.eip = eip;
                c.poll = true;
                c.keep = false;
                if (pm.exception(c, bus)) |e| {
                    ctx.ret = @intFromEnum(e);
                    return exitCode(X_RET, a, 0);
                }
                return exitCode(X_NEXT, a, 0);
            }
            if (ctx.inval != 0) {
                c.regs.eip = @truncate(ip >> 32);
                return exitCode(X_NEXT, a, 0);
            }
            return 0;
        }
    };
}
