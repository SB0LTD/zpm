//! DOS's memory: the chain of memory control blocks over conventional
//! memory. Each block is a paragraph of header ('M', or 'Z' for the last;
//! the owner's PSP, 0 when free, 8 for DOS; the size in paragraphs; the
//! owner's name from offset 8) followed by its paragraphs. Allocation is
//! first, best or last fit (58h); adjacent free blocks merge as DOS merges
//! them, when it next walks the chain.

const std = @import("std");
const Memory = @import("mem.sig").Memory;
const State = @import("dos_state.sig").State;

pub const Err = error{ Corrupt, NoMemory, BadBlock };

pub const OWNER_FREE: u16 = 0;
pub const OWNER_DOS: u16 = 8;

pub fn kind(mem: *const Memory, mcb: u16) u8 {
    return mem.rdB(mcb, 0);
}
pub fn owner(mem: *const Memory, mcb: u16) u16 {
    return mem.rdW(mcb, 1);
}
pub fn size(mem: *const Memory, mcb: u16) u16 {
    return mem.rdW(mcb, 3);
}
fn valid(mem: *const Memory, mcb: u16) bool {
    const k = kind(mem, mcb);
    return k == 'M' or k == 'Z';
}

pub fn write(mem: *Memory, mcb: u16, k: u8, own: u16, paras: u16) void {
    mem.wrB(mcb, 0, k);
    mem.wrW(mcb, 1, own);
    mem.wrW(mcb, 3, paras);
    mem.wrB(mcb, 5, 0);
    mem.wrB(mcb, 6, 0);
    mem.wrB(mcb, 7, 0);
}

pub fn setOwner(mem: *Memory, data: u16, own: u16) void {
    mem.wrW(data - 1, 1, own);
}

/// The block's name (DOS 4+: the program's, or "SC"/"SD" for DOS's own).
pub fn setName(mem: *Memory, data: u16, name: []const u8) void {
    var i: u16 = 0;
    while (i < 8) : (i += 1) mem.wrB(data - 1, 8 + i, if (i < name.len) name[i] else 0);
}

/// One free block over [first, end) (`first` is its header's segment).
pub fn initChain(st: *State, mem: *Memory, first: u16, end: u16) void {
    st.first_mcb = first;
    st.mem_end = end;
    write(mem, first, 'Z', OWNER_FREE, end - first - 1);
    setName(mem, first + 1, "");
}

fn next(mem: *const Memory, mcb: u16) u16 {
    return mcb +% size(mem, mcb) +% 1;
}

/// Free neighbours become one block; the chain is checked on the way.
fn merge(st: *State, mem: *Memory) Err!void {
    var m = st.first_mcb;
    var guard: u32 = 0;
    while (true) : (guard += 1) {
        if (guard > 0x10000 or !valid(mem, m)) return error.Corrupt;
        if (kind(mem, m) == 'Z') return;
        const n = next(mem, m);
        if (n >= st.mem_end or !valid(mem, n)) return error.Corrupt;
        if (owner(mem, m) == OWNER_FREE and owner(mem, n) == OWNER_FREE) {
            write(mem, m, kind(mem, n), OWNER_FREE, size(mem, m) + size(mem, n) + 1);
            continue;
        }
        m = n;
    }
}

/// The largest free block's size.
pub fn largest(st: *State, mem: *Memory) u16 {
    merge(st, mem) catch return 0;
    var best: u16 = 0;
    var m = st.first_mcb;
    while (true) {
        if (owner(mem, m) == OWNER_FREE) best = @max(best, size(mem, m));
        if (kind(mem, m) == 'Z') return best;
        m = next(mem, m);
    }
}

/// A block of `paras` paragraphs for `own`: its first data segment.
pub fn alloc(st: *State, mem: *Memory, paras: u16, own: u16) Err!u16 {
    try merge(st, mem);
    var pick: ?u16 = null;
    var m = st.first_mcb;
    while (true) {
        const sz = size(mem, m);
        if (owner(mem, m) == OWNER_FREE and sz >= paras) {
            switch (st.strategy & 0x03) {
                0 => if (pick == null) {
                    pick = m;
                },
                1 => if (pick == null or sz < size(mem, pick.?)) {
                    pick = m;
                },
                else => pick = m,
            }
        }
        if (kind(mem, m) == 'Z') break;
        m = next(mem, m);
    }
    const b = pick orelse return error.NoMemory;
    const sz = size(mem, b);
    const k = kind(mem, b);
    if (sz == paras) {
        write(mem, b, k, own, paras);
        return b + 1;
    }
    if (st.strategy & 0x03 >= 2) {
        // Last fit: the top of the block; the free part stays below.
        const free_sz = sz - paras - 1;
        write(mem, b, 'M', OWNER_FREE, free_sz);
        const top = b + 1 + free_sz;
        write(mem, top, k, own, paras);
        setName(mem, top + 1, "");
        return top + 1;
    }
    write(mem, b, 'M', own, paras);
    const rest = b + 1 + paras;
    write(mem, rest, k, OWNER_FREE, sz - paras - 1);
    setName(mem, rest + 1, "");
    setName(mem, b + 1, "");
    return b + 1;
}

/// Frees the block at `data` (its header at data - 1).
pub fn free(st: *State, mem: *Memory, data: u16) Err!void {
    _ = st;
    if (data == 0 or !valid(mem, data - 1)) return error.BadBlock;
    mem.wrW(data - 1, 1, OWNER_FREE);
}

/// Resizes the block at `data` to `paras`; on NoMemory `max` is the most
/// it could have.
pub fn resize(st: *State, mem: *Memory, data: u16, paras: u16, max: *u16) Err!void {
    if (data == 0 or !valid(mem, data - 1)) return error.BadBlock;
    try merge(st, mem);
    const m = data - 1;
    const sz = size(mem, m);
    const k = kind(mem, m);
    const own = owner(mem, m);
    if (paras <= sz) {
        if (paras < sz) {
            write(mem, m, 'M', own, paras);
            const rest = m + 1 + paras;
            write(mem, rest, k, OWNER_FREE, sz - paras - 1);
            setName(mem, rest + 1, "");
            try merge(st, mem);
        }
        return;
    }
    var avail: u32 = sz;
    var nk = k;
    if (k == 'M') {
        const n = next(mem, m);
        if (owner(mem, n) == OWNER_FREE) {
            avail += @as(u32, size(mem, n)) + 1;
            nk = kind(mem, n);
        }
    }
    if (avail < paras) {
        max.* = @intCast(avail);
        return error.NoMemory;
    }
    if (avail == paras) {
        write(mem, m, nk, own, paras);
        return;
    }
    write(mem, m, 'M', own, paras);
    const rest = m + 1 + paras;
    write(mem, rest, nk, OWNER_FREE, @intCast(avail - paras - 1));
    setName(mem, rest + 1, "");
}

/// Frees every block `own` holds (a process ending).
pub fn freeOwned(st: *State, mem: *Memory, own: u16) void {
    var m = st.first_mcb;
    var guard: u32 = 0;
    while (valid(mem, m) and guard < 0x10000) : (guard += 1) {
        if (owner(mem, m) == own) mem.wrW(m, 1, OWNER_FREE);
        if (kind(mem, m) == 'Z') break;
        m = next(mem, m);
    }
    merge(st, mem) catch {};
}

/// The block holding `seg`, its header's segment (for 49h on a PSP).
pub fn blockOf(st: *const State, mem: *const Memory, seg: u16) ?u16 {
    var m = st.first_mcb;
    var guard: u32 = 0;
    while (valid(mem, m) and guard < 0x10000) : (guard += 1) {
        const n = next(mem, m);
        if (seg > m and seg < n) return m;
        if (kind(mem, m) == 'Z') break;
        m = n;
    }
    return null;
}
