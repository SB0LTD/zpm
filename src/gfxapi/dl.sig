//! @zpm/gfxapi dl — functions and data of the program the driver is loaded
//! into, found by name: libwayland-client's for EGL's Wayland platform.
//! The app has loaded it already, since it hands EGL a wl_display.
//!
//! The driver has no C library of its own and no DT_NEEDED, so it takes
//! the host's `dlsym` as a weak symbol, which the dynamic linker binds
//! from the program's C library (musl, or glibc 2.34 and later). Where
//! there is none (glibc before 2.34 keeps it in libdl, which a program
//! need not load), it reads the loaded objects' dynamic symbol tables
//! (GNU or SysV hash) through the weak `dl_iterate_phdr`. Neither
//! reference stops the library from loading: without them, lookups find
//! nothing and EGL says it has no display.

const std = @import("std");
const builtin = @import("builtin");

const DlsymFn = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;

// (a weak symbol's address goes through a function: named directly, the
// compiler would take it as never null)
fn hostDlsym() ?DlsymFn {
    if (builtin.is_test or builtin.os.tag != .linux) return null;
    return @extern(DlsymFn, .{ .name = "dlsym", .linkage = .weak });
}

const Phdr = extern struct { type: u32, flags: u32, offset: u64, vaddr: u64, paddr: u64, filesz: u64, memsz: u64, @"align": u64 };
const Dyn = extern struct { tag: i64, val: u64 };
const Sym = extern struct { name: u32, info: u8, other: u8, shndx: u16, value: u64, size: u64 };
const PhdrInfo = extern struct { addr: usize, name: ?[*:0]const u8, phdr: [*]const Phdr, phnum: u16 };
const EachFn = *const fn (*const PhdrInfo, usize, ?*anyopaque) callconv(.c) c_int;
const IterateFn = *const fn (EachFn, ?*anyopaque) callconv(.c) c_int;

fn hostIterate() ?IterateFn {
    if (builtin.is_test or builtin.os.tag != .linux) return null;
    return @extern(IterateFn, .{ .name = "dl_iterate_phdr", .linkage = .weak });
}

const PT_DYNAMIC = 2;
const DT_NULL = 0;
const DT_HASH = 4;
const DT_STRTAB = 5;
const DT_SYMTAB = 6;
const DT_GNU_HASH = 0x6ffffef5;
const DT_VERSYM = 0x6ffffff0;

/// The program's first definition of `name` (dlsym(RTLD_DEFAULT, name)),
/// or null.
pub fn lookup(name: [*:0]const u8) ?*anyopaque {
    if (hostDlsym()) |f| {
        if (f(null, name)) |symbol| return symbol;
    }
    const iter = hostIterate() orelse return null;
    var s = Search{ .name = std.mem.span(name) };
    _ = iter(&each, &s);
    return s.found;
}

/// `name` as a pointer of type T (a function's, or data's).
pub fn sym(comptime T: type, name: [*:0]const u8) ?T {
    return @ptrCast(@alignCast(lookup(name) orelse return null));
}

const Search = struct { name: []const u8, found: ?*anyopaque = null };

fn each(info: *const PhdrInfo, size: usize, data: ?*anyopaque) callconv(.c) c_int {
    _ = size;
    const s: *Search = @ptrCast(@alignCast(data.?));
    if (findIn(info.addr, info.phdr[0..info.phnum], s.name)) |p| {
        s.found = p;
        return 1;
    }
    return 0;
}

fn gnuHash(name: []const u8) u32 {
    var h: u32 = 5381;
    for (name) |c| h = h *% 33 +% c;
    return h;
}

fn sysvHash(name: []const u8) u32 {
    var h: u32 = 0;
    for (name) |c| {
        h = (h << 4) +% c;
        const g = h & 0xf000_0000;
        if (g != 0) h ^= g >> 24;
        h &= ~g;
    }
    return h;
}

/// `name` among one loaded object's dynamic symbols: global or weak,
/// defined, a function or data, the default version.
fn findIn(base: usize, phdrs: []const Phdr, name: []const u8) ?*anyopaque {
    var dyn_at: usize = 0;
    for (phdrs) |ph| {
        if (ph.type == PT_DYNAMIC) dyn_at = base +% ph.vaddr;
    }
    if (dyn_at == 0) return null;
    var symtab: usize = 0;
    var strtab: usize = 0;
    var gnu: usize = 0;
    var sysv: usize = 0;
    var versym: usize = 0;
    const dyn: [*]const Dyn = @ptrFromInt(dyn_at);
    var i: usize = 0;
    while (dyn[i].tag != DT_NULL and i < 512) : (i += 1) {
        // (glibc keeps these relocated; musl, offsets from the base)
        var v: usize = dyn[i].val;
        if (v < base) v +%= base;
        switch (dyn[i].tag) {
            DT_SYMTAB => symtab = v,
            DT_STRTAB => strtab = v,
            DT_GNU_HASH => gnu = v,
            DT_HASH => sysv = v,
            DT_VERSYM => versym = v,
            else => {},
        }
    }
    if (symtab == 0 or strtab == 0) return null;
    const t = Table{ .base = base, .syms = @ptrFromInt(symtab), .strs = @ptrFromInt(strtab), .vers = if (versym != 0) @ptrFromInt(versym) else null };
    if (gnu != 0) {
        const h: [*]const u32 = @ptrFromInt(gnu);
        const nbuckets = h[0];
        const symoffset = h[1];
        if (nbuckets == 0) return null;
        const buckets: [*]const u32 = @ptrFromInt(gnu + 16 + @as(usize, h[2]) * @sizeOf(usize));
        const chain = buckets + nbuckets;
        const hv = gnuHash(name);
        var idx = buckets[hv % nbuckets];
        if (idx < symoffset) return null;
        while (true) : (idx += 1) {
            const h2 = chain[idx - symoffset];
            if ((h2 | 1) == (hv | 1)) {
                if (t.match(idx, name)) |p| return p;
            }
            if (h2 & 1 != 0) return null;
        }
    }
    if (sysv != 0) {
        const h: [*]const u32 = @ptrFromInt(sysv);
        const nbucket = h[0];
        if (nbucket == 0) return null;
        const bucket = h + 2;
        const chain = bucket + nbucket;
        var idx = bucket[sysvHash(name) % nbucket];
        var n: usize = 0;
        while (idx != 0 and n < 1 << 20) : (n += 1) {
            if (t.match(idx, name)) |p| return p;
            idx = chain[idx];
        }
    }
    return null;
}

const Table = struct {
    base: usize,
    syms: [*]const Sym,
    strs: [*]const u8,
    vers: ?[*]const u16,

    fn match(t: Table, idx: usize, want: []const u8) ?*anyopaque {
        const s = t.syms[idx];
        if (s.shndx == 0 or s.value == 0) return null;
        const bind = s.info >> 4;
        const kind = s.info & 15;
        if (bind != 1 and bind != 2) return null; // global, weak
        if (kind > 2) return null; // notype, object, function (no IFUNC)
        if (t.vers) |v| {
            if (v[idx] & 0x8000 != 0 or v[idx] == 0) return null; // hidden, or local
        }
        const nm = std.mem.span(@as([*:0]const u8, @ptrCast(t.strs + s.name)));
        if (!std.mem.eql(u8, nm, want)) return null;
        return @ptrFromInt(t.base +% s.value);
    }
};

test "dl: the hash functions are the ELF ones" {
    try std.testing.expectEqual(@as(u32, 0x0000_1505), gnuHash(""));
    try std.testing.expectEqual(@as(u32, 0x156b_2bb8), gnuHash("printf"));
    try std.testing.expectEqual(@as(u32, 0x077905a6), sysvHash("printf"));
    // (a test is a static program: nothing to find)
    try std.testing.expect(lookup("wl_display_flush") == null);
}
