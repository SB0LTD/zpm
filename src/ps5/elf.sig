//! @zpm/ps5 elf — a PlayStation executable or module read as a file: what a
//! loader needs to know before it maps anything.
//!
//! A decrypted PS5 `eboot.bin` or `.prx` is an ELF for x86-64 with FreeBSD's
//! OS ABI byte, one of Sony's file types, and Sony's own way of naming what
//! it imports and exports (nid.sig). Two generations write the same facts
//! differently, and `Image.parse` reads both:
//!
//!   - the PS5 keeps its dynamic tables (strings, symbols, relocations) in
//!     ordinary load segments, under the standard tags (DT_STRTAB, DT_SYMTAB,
//!     DT_RELA, DT_JMPREL), their values addresses in the module;
//!   - the PS4 keeps them in a file-only segment (PT_SCE_DYNLIBDATA), under
//!     its own tags (DT_SCE_STRTAB ...), their values offsets into it.
//!
//! The modules and libraries a file names (its own, the ones it needs, the
//! ones its symbols come from) are dynamic tags too, one per name, with an
//! id that the symbol names refer to: `NID#library id#module id`.
//!
//! Everything here is a view of the file's bytes: nothing is copied, every
//! offset is checked against the file before it is used, and a file that
//! lies about itself is an error, never a read outside the buffer. (A dump
//! rebuilt from an encrypted original can carry stale offsets in segments
//! a loader does not need: those are not read.)
//!
//! Sources: the ELF and System V ABI documents; for Sony's types and tags,
//! open loaders and tools read as documentation (shadPS4, Kyty, RPCSX,
//! sce-elf, the OpenOrbis toolchain's notes, AnyPS5's docs), cross-checked
//! against each other. Allocation-free: views and plain values.

const std = @import("std");
const nid = @import("nid.sig");

pub const Error = error{
    /// Not a 64-bit little-endian x86-64 ELF.
    NotElf,
    /// An ELF, but not one of Sony's file types for the PS4 or PS5.
    NotSce,
    /// A header or a table runs past the end of the file.
    Truncated,
    /// Load segments that wrap, overlap or are too many; a size below the
    /// bytes it holds.
    BadSegment,
    /// The dynamic section contradicts itself, or names a table that is
    /// not where it says.
    BadDynamic,
    /// PS4's and PS5's spellings of the same fact in one file.
    MixedDialect,
};

// ── The ELF structures (64-bit, little-endian) ──────────────────────────────

pub const Phdr = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    @"align": u64,
};

pub const Dyn = extern struct { tag: u64, val: u64 };

pub const Sym = extern struct {
    name: u32,
    info: u8,
    other: u8,
    shndx: u16,
    value: u64,
    size: u64,

    pub fn bind(s: Sym) u4 {
        return @truncate(s.info >> 4);
    }
    pub fn kind(s: Sym) u4 {
        return @truncate(s.info);
    }
    /// Default or protected visibility: a hidden or internal definition
    /// never answers another module's import.
    pub fn visible(s: Sym) bool {
        return s.other & 3 == 0 or s.other & 3 == 3;
    }
    pub fn defined(s: Sym) bool {
        return s.shndx != SHN_UNDEF;
    }
};

pub const Rela = extern struct {
    offset: u64,
    info: u64,
    addend: i64,

    pub fn sym(r: Rela) u32 {
        return @truncate(r.info >> 32);
    }
    pub fn kind(r: Rela) u32 {
        return @truncate(r.info);
    }
};

comptime {
    std.debug.assert(@sizeOf(Phdr) == 56 and @sizeOf(Dyn) == 16 and @sizeOf(Sym) == 24 and @sizeOf(Rela) == 24);
}

pub const SHN_UNDEF = 0;
pub const STB_LOCAL = 0;
pub const STB_GLOBAL = 1;
pub const STB_WEAK = 2;
pub const STT_OBJECT = 1;
pub const STT_FUNC = 2;
pub const STT_TLS = 6;

/// x86-64 relocations a PlayStation file uses.
pub const R = struct {
    pub const NONE = 0;
    pub const @"64" = 1;
    pub const GLOB_DAT = 6;
    pub const JUMP_SLOT = 7;
    pub const RELATIVE = 8;
    pub const DTPMOD64 = 16;
    pub const DTPOFF64 = 17;
    pub const TPOFF64 = 18;
};

pub const PT = struct {
    pub const LOAD = 1;
    pub const DYNAMIC = 2;
    pub const TLS = 7;
    pub const GNU_EH_FRAME = 0x6474_e550;
    pub const GNU_RELRO = 0x6474_e552;
    pub const SCE_DYNLIBDATA = 0x6100_0000;
    pub const SCE_PROCPARAM = 0x6100_0001;
    pub const SCE_MODULE_PARAM = 0x6100_0002;
    pub const SCE_RELRO = 0x6100_0010;
    pub const SCE_COMMENT = 0x6fff_ff00;
    pub const SCE_LIBVERSION = 0x6fff_ff01;
};

pub const DT = struct {
    pub const NULL = 0;
    pub const NEEDED = 1;
    pub const PLTRELSZ = 2;
    pub const PLTGOT = 3;
    pub const HASH = 4;
    pub const STRTAB = 5;
    pub const SYMTAB = 6;
    pub const RELA = 7;
    pub const RELASZ = 8;
    pub const RELAENT = 9;
    pub const STRSZ = 10;
    pub const SYMENT = 11;
    pub const INIT = 12;
    pub const FINI = 13;
    pub const SONAME = 14;
    pub const PLTREL = 20;
    pub const JMPREL = 23;
    pub const INIT_ARRAY = 25;
    pub const FINI_ARRAY = 26;
    pub const INIT_ARRAYSZ = 27;
    pub const FINI_ARRAYSZ = 28;
    pub const FLAGS = 30;
    pub const PREINIT_ARRAY = 32;
    pub const PREINIT_ARRAYSZ = 33;
    // Sony's. The PS4's names for itself and what it needs:
    pub const SCE_MODULE_INFO = 0x6100_000d;
    pub const SCE_NEEDED_MODULE = 0x6100_000f;
    pub const SCE_MODULE_ATTR = 0x6100_0011;
    pub const SCE_EXPORT_LIB = 0x6100_0013;
    pub const SCE_IMPORT_LIB = 0x6100_0015;
    pub const SCE_EXPORT_LIB_ATTR = 0x6100_0017;
    pub const SCE_IMPORT_LIB_ATTR = 0x6100_0019;
    // The PS4's tables (offsets into PT_SCE_DYNLIBDATA):
    pub const SCE_HASH = 0x6100_0025;
    pub const SCE_PLTGOT = 0x6100_0027;
    pub const SCE_JMPREL = 0x6100_0029;
    pub const SCE_PLTREL = 0x6100_002b;
    pub const SCE_PLTRELSZ = 0x6100_002d;
    pub const SCE_RELA = 0x6100_002f;
    pub const SCE_RELASZ = 0x6100_0031;
    pub const SCE_RELAENT = 0x6100_0033;
    pub const SCE_STRTAB = 0x6100_0035;
    pub const SCE_STRSZ = 0x6100_0037;
    pub const SCE_SYMTAB = 0x6100_0039;
    pub const SCE_SYMENT = 0x6100_003b;
    pub const SCE_HASHSZ = 0x6100_003d;
    /// The symbol table's size in bytes: kept on the PS5 beside the
    /// standard tables, which have no tag for it.
    pub const SCE_SYMTABSZ = 0x6100_003f;
    // The PS5's names for itself and what it needs (the same packing):
    pub const SCE_MODULE_INFO_1 = 0x6100_0043;
    pub const SCE_NEEDED_MODULE_1 = 0x6100_0045;
    pub const SCE_EXPORT_LIB_1 = 0x6100_0047;
    pub const SCE_IMPORT_LIB_1 = 0x6100_0049;
};

// ── What a file is ──────────────────────────────────────────────────────────

/// Which console's linker wrote the file.
pub const Dialect = enum { ps4, ps5 };

/// Sony's file types (e_type).
pub const Kind = enum(u16) {
    /// A fixed-address executable.
    exec = 0xfe00,
    /// A relocatable executable (an eboot.bin: it loads wherever it is put).
    dynexec = 0xfe10,
    /// A module (.prx, .sprx).
    module = 0xfe18,

    pub fn isExecutable(k: Kind) bool {
        return k != .module;
    }
};

/// One piece of the file that a loader maps.
pub const Segment = struct {
    vaddr: u64,
    memsz: u64,
    /// The first `filesz` bytes come from the file at `offset`; the rest
    /// are zero.
    filesz: u64,
    offset: u64,
    read: bool,
    write: bool,
    exec: bool,

    pub fn end(s: Segment) u64 {
        return s.vaddr + s.memsz;
    }
};

pub const Range = struct { vaddr: u64, size: u64 };

pub const Tls = struct {
    /// Where the initial bytes are in the module (inside a load segment).
    vaddr: u64,
    /// Initialised bytes, then zeroes up to `memsz`.
    filesz: u64,
    memsz: u64,
    alignment: u64,
};

/// A module or a library a file names: itself, one it needs, one its
/// symbols belong to. `id` is what a symbol's name says (`NID#lib#module`).
pub const Named = struct {
    id: u16,
    /// Major and minor in one word, as the file packs them.
    version: u16,
    name: []const u8,
};

pub const MAX_SEGMENTS = 8;

/// The PS5's (and PS4's) page: segments are aligned to it.
pub const PAGE: u64 = 0x4000;

/// The most thread storage one module may ask for. (Real titles' are tens
/// of kilobytes; a file that says more than this is not believed, so that
/// no sum of them can overflow and no thread's storage is absurd.)
pub const TLS_MAX: u64 = 256 << 20;

pub const Image = struct {
    bytes: []const u8,
    dialect: Dialect,
    kind: Kind,
    /// Where the program starts, in the module (0: none).
    entry: u64,
    segments_buf: [MAX_SEGMENTS]Segment,
    segment_count: u8,
    /// The addresses the segments span, from 0 for a relocatable file,
    /// whole pages: what a loader reserves.
    lo: u64,
    hi: u64,
    /// Made read-only once relocated.
    relro: ?Range,
    tls: ?Tls,
    /// The process parameter (an executable) or module parameter.
    proc_param: ?Range,
    module_param: ?Range,
    eh_frame_hdr: ?Range,
    /// The dynamic section, up to its end marker.
    dynamic: []align(1) const Dyn,
    strtab: []const u8,
    symtab: []align(1) const Sym,
    /// Relocations, then the ones for imported functions (the PLT's).
    rela: []align(1) const Rela,
    jmprel: []align(1) const Rela,
    /// Addresses in the module (0: none).
    init: u64,
    fini: u64,
    pltgot: u64,
    init_array: Range,
    fini_array: Range,
    preinit_array: Range,

    pub fn segments(im: *const Image) []const Segment {
        return im.segments_buf[0..im.segment_count];
    }

    /// The size of the addresses to reserve.
    pub fn span(im: *const Image) u64 {
        return im.hi - im.lo;
    }

    /// Reads a file's headers and dynamic section. `bytes` must outlive the
    /// image (it is a view of them).
    pub fn parse(bytes: []const u8) Error!Image {
        if (bytes.len < 64) return error.NotElf;
        if (!std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1) return error.NotElf;
        if (rd(u16, bytes, 18) != 62) return error.NotElf; // EM_X86_64
        if (bytes[7] != 9) return error.NotSce; // ELFOSABI_FREEBSD
        const kind: Kind = switch (rd(u16, bytes, 16)) {
            0xfe00 => .exec,
            // (0xFE04: the older name for an executable that is relocated)
            0xfe04, 0xfe10 => .dynexec,
            0xfe18 => .module,
            else => return error.NotSce,
        };
        const phoff = rd(u64, bytes, 32);
        const phentsize = rd(u16, bytes, 54);
        const phnum: usize = rd(u16, bytes, 56);
        if (phentsize != @sizeOf(Phdr)) return error.NotElf;
        if (phoff > bytes.len or phnum * @sizeOf(Phdr) > bytes.len - phoff) return error.Truncated;
        const phdrs = std.mem.bytesAsSlice(Phdr, bytes[@intCast(phoff)..][0 .. phnum * @sizeOf(Phdr)]);

        var im = Image{
            .bytes = bytes,
            .dialect = .ps5,
            .kind = kind,
            .entry = rd(u64, bytes, 24),
            .segments_buf = undefined,
            .segment_count = 0,
            .lo = std.math.maxInt(u64),
            .hi = 0,
            .relro = null,
            .tls = null,
            .proc_param = null,
            .module_param = null,
            .eh_frame_hdr = null,
            .dynamic = &.{},
            .strtab = &.{},
            .symtab = &.{},
            .rela = &.{},
            .jmprel = &.{},
            .init = 0,
            .fini = 0,
            .pltgot = 0,
            .init_array = .{ .vaddr = 0, .size = 0 },
            .fini_array = .{ .vaddr = 0, .size = 0 },
            .preinit_array = .{ .vaddr = 0, .size = 0 },
        };

        // What is mapped first: the others are placed against it, whatever
        // order the headers come in. The load segments; then, on the PS4, a
        // read-only-after-relocation part that is a segment of its own (its
        // GOT lives there). Inside a load segment it is only a range.
        for (phdrs) |ph| {
            if (ph.type == PT.LOAD) try im.addSegment(ph);
        }
        for (phdrs) |ph| {
            if (ph.type != PT.SCE_RELRO or ph.memsz == 0) continue;
            if (ph.vaddr +% ph.memsz < ph.vaddr) return error.BadSegment;
            if (!im.covered(ph.vaddr, ph.memsz)) try im.addSegment(ph);
        }
        var dyn_ph: ?Phdr = null;
        var dynlib: ?Phdr = null;
        for (phdrs) |ph| switch (ph.type) {
            PT.SCE_RELRO, PT.GNU_RELRO => {
                if (ph.memsz == 0) continue;
                if (ph.vaddr +% ph.memsz < ph.vaddr or !im.covered(ph.vaddr, ph.memsz)) return error.BadSegment;
                im.relro = .{ .vaddr = ph.vaddr, .size = ph.memsz };
            },
            // (one of each: a second would silently replace the first)
            PT.DYNAMIC => {
                if (dyn_ph != null) return error.BadSegment;
                dyn_ph = ph;
            },
            PT.SCE_DYNLIBDATA => dynlib = ph,
            PT.TLS => {
                if (im.tls != null or ph.filesz > ph.memsz or ph.memsz > TLS_MAX) return error.BadSegment;
                if (ph.memsz != 0) {
                    if (!im.covered(ph.vaddr, ph.filesz)) return error.BadSegment;
                    const a = if (ph.@"align" == 0) 1 else ph.@"align";
                    if (!std.math.isPowerOfTwo(a) or a > PAGE) return error.BadSegment;
                    im.tls = .{ .vaddr = ph.vaddr, .filesz = ph.filesz, .memsz = ph.memsz, .alignment = a };
                }
            },
            PT.SCE_PROCPARAM => im.proc_param = try im.inside(ph),
            PT.SCE_MODULE_PARAM => im.module_param = try im.inside(ph),
            PT.GNU_EH_FRAME => im.eh_frame_hdr = try im.inside(ph),
            else => {},
        };
        if (im.segment_count == 0) return error.BadSegment;
        std.mem.sort(Segment, im.segments_buf[0..im.segment_count], {}, struct {
            fn lt(_: void, a: Segment, b: Segment) bool {
                return a.vaddr < b.vaddr;
            }
        }.lt);
        var prev_end: u64 = 0;
        for (im.segments(), 0..) |s, i| {
            if (i != 0 and s.vaddr < prev_end) return error.BadSegment;
            prev_end = std.mem.alignForward(u64, s.end(), PAGE);
        }
        im.lo = std.mem.alignBackward(u64, im.segments()[0].vaddr, PAGE);
        im.hi = prev_end;
        if (im.entry != 0 and !im.covered(im.entry, 1)) return error.BadSegment;

        if (dyn_ph) |ph| try im.readDynamic(ph, dynlib);
        return im;
    }

    fn addSegment(im: *Image, ph: Phdr) Error!void {
        if (ph.memsz == 0) return;
        if (ph.filesz > ph.memsz) return error.BadSegment;
        if (ph.vaddr +% ph.memsz < ph.vaddr or ph.vaddr + ph.memsz > (1 << 47)) return error.BadSegment;
        if (ph.offset > im.bytes.len or ph.filesz > im.bytes.len - ph.offset) return error.Truncated;
        if (im.segment_count == MAX_SEGMENTS) return error.BadSegment;
        // (a segment with no flags at all, as some PS5 files have: memory
        // to read and write, as open loaders treat it; a page nothing can
        // touch is no use to a program)
        const bare = ph.flags & 7 == 0;
        im.segments_buf[im.segment_count] = .{
            .vaddr = ph.vaddr,
            .memsz = ph.memsz,
            .filesz = ph.filesz,
            .offset = ph.offset,
            .exec = ph.flags & 1 != 0,
            .write = bare or ph.flags & 2 != 0,
            .read = bare or ph.flags & 4 != 0,
        };
        im.segment_count += 1;
    }

    /// The whole of [vaddr, vaddr + size) lies in one segment.
    pub fn covered(im: *const Image, vaddr: u64, size: u64) bool {
        for (im.segments()) |s| {
            if (vaddr >= s.vaddr and size <= s.memsz and vaddr - s.vaddr <= s.memsz - size) return true;
        }
        return false;
    }

    fn inside(im: *const Image, ph: Phdr) Error!?Range {
        if (ph.memsz == 0) return null;
        if (!im.covered(ph.vaddr, ph.memsz)) return error.BadSegment;
        return .{ .vaddr = ph.vaddr, .size = ph.memsz };
    }

    /// The file's bytes for [vaddr, vaddr + size) of the module, when a
    /// segment holds all of them in the file.
    pub fn fileBytes(im: *const Image, vaddr: u64, size: u64) ?[]const u8 {
        for (im.segments()) |s| {
            if (vaddr < s.vaddr) continue;
            const at = vaddr - s.vaddr;
            if (size > s.filesz or at > s.filesz - size) continue;
            return im.bytes[@intCast(s.offset + at)..][0..@intCast(size)];
        }
        return null;
    }

    fn readDynamic(im: *Image, ph: Phdr, dynlib: ?Phdr) Error!void {
        if (ph.offset > im.bytes.len or ph.filesz > im.bytes.len - ph.offset) return error.Truncated;
        const all = std.mem.bytesAsSlice(Dyn, im.bytes[@intCast(ph.offset)..][0..@intCast(ph.filesz - ph.filesz % @sizeOf(Dyn))]);
        var n: usize = 0;
        while (n < all.len and all[n].tag != DT.NULL) n += 1;
        im.dynamic = all[0..n];

        // Each table under one console's tag or the other's, never both.
        var std_tags = false;
        var sce_tags = false;
        var old_names = false;
        var new_names = false;
        var t: Tables = .{};
        for (im.dynamic) |d| switch (d.tag) {
            DT.STRTAB, DT.SYMTAB, DT.RELA, DT.JMPREL, DT.HASH => {
                std_tags = true;
                t.set(d.tag, d.val);
            },
            DT.SCE_STRTAB, DT.SCE_SYMTAB, DT.SCE_RELA, DT.SCE_JMPREL, DT.SCE_HASH => {
                sce_tags = true;
                t.set(d.tag - DT.SCE_HASH + 0x1000, d.val);
            },
            DT.STRSZ, DT.SCE_STRSZ => t.strsz = d.val,
            DT.RELASZ, DT.SCE_RELASZ => t.relasz = d.val,
            DT.PLTRELSZ, DT.SCE_PLTRELSZ => t.pltrelsz = d.val,
            DT.SCE_SYMTABSZ => t.symtabsz = d.val,
            DT.RELAENT, DT.SCE_RELAENT => if (d.val != @sizeOf(Rela)) return error.BadDynamic,
            DT.SYMENT, DT.SCE_SYMENT => if (d.val != @sizeOf(Sym)) return error.BadDynamic,
            DT.PLTREL, DT.SCE_PLTREL => if (d.val != DT.RELA) return error.BadDynamic,
            DT.PLTGOT, DT.SCE_PLTGOT => im.pltgot = d.val,
            DT.INIT => im.init = d.val,
            DT.FINI => im.fini = d.val,
            DT.INIT_ARRAY => im.init_array.vaddr = d.val,
            DT.INIT_ARRAYSZ => im.init_array.size = d.val,
            DT.FINI_ARRAY => im.fini_array.vaddr = d.val,
            DT.FINI_ARRAYSZ => im.fini_array.size = d.val,
            DT.PREINIT_ARRAY => im.preinit_array.vaddr = d.val,
            DT.PREINIT_ARRAYSZ => im.preinit_array.size = d.val,
            DT.SCE_MODULE_INFO, DT.SCE_NEEDED_MODULE, DT.SCE_EXPORT_LIB, DT.SCE_IMPORT_LIB => old_names = true,
            DT.SCE_MODULE_INFO_1, DT.SCE_NEEDED_MODULE_1, DT.SCE_EXPORT_LIB_1, DT.SCE_IMPORT_LIB_1 => new_names = true,
            else => {},
        };
        if ((std_tags and sce_tags) or (old_names and new_names)) return error.MixedDialect;
        if ((sce_tags and new_names) or (std_tags and old_names)) return error.MixedDialect;
        im.dialect = if (sce_tags or old_names) .ps4 else .ps5;
        for ([_]u64{ im.init, im.fini }) |a| {
            if (a != 0 and !im.covered(a, 1)) return error.BadDynamic;
        }
        for ([_]Range{ im.init_array, im.fini_array, im.preinit_array }) |r| {
            if (r.size != 0 and (r.size % 8 != 0 or !im.covered(r.vaddr, r.size))) return error.BadDynamic;
        }

        im.strtab = try im.table(t.strtab, t.strsz, dynlib);
        if (im.strtab.len != 0 and im.strtab[im.strtab.len - 1] != 0) return error.BadDynamic;
        // The symbol table's size: Sony's tag, or as many symbols as the
        // hash table has chain entries.
        var symsz = t.symtabsz;
        if (symsz == null and t.symtab != null) {
            const head = try im.table(t.hash, 8, dynlib);
            if (head.len == 8) symsz = @as(u64, rd(u32, head, 4)) * @sizeOf(Sym);
        }
        const syms = try im.table(t.symtab, symsz, dynlib);
        if (syms.len % @sizeOf(Sym) != 0) return error.BadDynamic;
        im.symtab = std.mem.bytesAsSlice(Sym, syms);
        const rela = try im.table(t.rela, t.relasz, dynlib);
        const plt = try im.table(t.jmprel, t.pltrelsz, dynlib);
        if (rela.len % @sizeOf(Rela) != 0 or plt.len % @sizeOf(Rela) != 0) return error.BadDynamic;
        im.rela = std.mem.bytesAsSlice(Rela, rela);
        im.jmprel = std.mem.bytesAsSlice(Rela, plt);
    }

    const Tables = struct {
        strtab: ?u64 = null,
        symtab: ?u64 = null,
        rela: ?u64 = null,
        jmprel: ?u64 = null,
        hash: ?u64 = null,
        strsz: ?u64 = null,
        relasz: ?u64 = null,
        pltrelsz: ?u64 = null,
        symtabsz: ?u64 = null,

        fn set(t: *Tables, tag: u64, val: u64) void {
            switch (tag) {
                DT.STRTAB, DT.SCE_STRTAB - DT.SCE_HASH + 0x1000 => t.strtab = val,
                DT.SYMTAB, DT.SCE_SYMTAB - DT.SCE_HASH + 0x1000 => t.symtab = val,
                DT.RELA, DT.SCE_RELA - DT.SCE_HASH + 0x1000 => t.rela = val,
                DT.JMPREL, DT.SCE_JMPREL - DT.SCE_HASH + 0x1000 => t.jmprel = val,
                DT.HASH, 0x1000 => t.hash = val,
                else => unreachable,
            }
        }
    };

    /// A table's bytes in the file. The PS5's is at an address in the
    /// module; the PS4's at an offset into its file-only segment. A table
    /// with no address or no size is empty; one that is not wholly where it
    /// says is an error.
    fn table(im: *const Image, at: ?u64, size: ?u64, dynlib: ?Phdr) Error![]const u8 {
        const a = at orelse return &.{};
        const n = size orelse return &.{};
        if (n == 0) return &.{};
        if (im.dialect == .ps5) return im.fileBytes(a, n) orelse error.BadDynamic;
        const seg = dynlib orelse return error.BadDynamic;
        if (seg.offset > im.bytes.len or seg.filesz > im.bytes.len - seg.offset) return error.Truncated;
        if (n > seg.filesz or a > seg.filesz - n) return error.BadDynamic;
        return im.bytes[@intCast(seg.offset + a)..][0..@intCast(n)];
    }

    // ── Names ───────────────────────────────────────────────────────────────

    /// The string at `off` in the string table.
    pub fn string(im: *const Image, off: u64) ?[]const u8 {
        if (off >= im.strtab.len) return null;
        const rest = im.strtab[@intCast(off)..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
        return rest[0..end];
    }

    pub fn symbolName(im: *const Image, s: Sym) ?[]const u8 {
        return im.string(s.name);
    }

    pub const NameKind = enum { module, needed_module, export_library, import_library };

    /// The modules or libraries of one kind the file names, in its order.
    pub fn names(im: *const Image, kind: NameKind) NameIterator {
        const old: u64 = switch (kind) {
            .module => DT.SCE_MODULE_INFO,
            .needed_module => DT.SCE_NEEDED_MODULE,
            .export_library => DT.SCE_EXPORT_LIB,
            .import_library => DT.SCE_IMPORT_LIB,
        };
        const new: u64 = switch (kind) {
            .module => DT.SCE_MODULE_INFO_1,
            .needed_module => DT.SCE_NEEDED_MODULE_1,
            .export_library => DT.SCE_EXPORT_LIB_1,
            .import_library => DT.SCE_IMPORT_LIB_1,
        };
        return .{ .im = im, .tag = if (im.dialect == .ps4) old else new };
    }

    pub const NameIterator = struct {
        im: *const Image,
        tag: u64,
        i: usize = 0,

        /// (an entry whose name is not in the string table is skipped)
        pub fn next(it: *NameIterator) ?Named {
            while (it.i < it.im.dynamic.len) {
                const d = it.im.dynamic[it.i];
                it.i += 1;
                if (d.tag != it.tag) continue;
                const name = it.im.string(d.val & 0xffff_ffff) orelse continue;
                return .{ .id = @truncate(d.val >> 48), .version = @truncate(d.val >> 32), .name = name };
            }
            return null;
        }
    };

    /// The module or library of a kind with this id (ids are keys the
    /// symbol names use, not positions).
    pub fn named(im: *const Image, kind: NameKind, id: u32) ?Named {
        var it = im.names(kind);
        while (it.next()) |n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// The module's own name (an executable may have none).
    pub fn moduleName(im: *const Image) ?[]const u8 {
        var it = im.names(.module);
        return if (it.next()) |n| n.name else null;
    }

    /// What an imported or exported symbol's name says: its NID, and the
    /// library and module the ids in it name. Null for a symbol that is
    /// not named Sony's way (a local, a section symbol).
    pub const Linked = struct {
        nid: nid.Nid,
        library: []const u8,
        module: []const u8,
    };

    pub fn linked(im: *const Image, s: Sym) ?Linked {
        const name = im.symbolName(s) orelse return null;
        const parts = nid.Symbol.parse(name) orelse return null;
        // An import's library is one the file imports; a definition's, one
        // it exports. The module is the file itself or one it needs.
        const lib = im.named(if (s.defined()) .export_library else .import_library, parts.library) orelse return null;
        const mod = im.named(.needed_module, parts.module) orelse im.named(.module, parts.module) orelse return null;
        return .{ .nid = parts.nid, .library = lib.name, .module = mod.name };
    }
};

/// The modules and libraries an image names, read from its dynamic
/// section once. A linker asks for one by id for every symbol it binds;
/// `Image.linked` walks the whole section each time, and a section can be
/// made very long.
pub const Names = struct {
    pub const MAX_LIBRARIES = 256;
    pub const MAX_MODULES = 128;

    imports: [MAX_LIBRARIES]Named = undefined,
    import_count: u16 = 0,
    exports: [MAX_LIBRARIES]Named = undefined,
    export_count: u16 = 0,
    /// The file's own module and the ones it needs.
    modules: [MAX_MODULES]Named = undefined,
    module_count: u16 = 0,

    /// BadDynamic for a file that names more than any real one does.
    pub fn init(im: *const Image) Error!Names {
        var t = Names{};
        const ps4 = im.dialect == .ps4;
        const tag_module: u64 = if (ps4) DT.SCE_MODULE_INFO else DT.SCE_MODULE_INFO_1;
        const tag_needed: u64 = if (ps4) DT.SCE_NEEDED_MODULE else DT.SCE_NEEDED_MODULE_1;
        const tag_export: u64 = if (ps4) DT.SCE_EXPORT_LIB else DT.SCE_EXPORT_LIB_1;
        const tag_import: u64 = if (ps4) DT.SCE_IMPORT_LIB else DT.SCE_IMPORT_LIB_1;
        for (im.dynamic) |d| {
            const is_module = d.tag == tag_module or d.tag == tag_needed;
            if (!is_module and d.tag != tag_export and d.tag != tag_import) continue;
            // (an entry whose name is not in the string table is skipped)
            const name = im.string(d.val & 0xffff_ffff) orelse continue;
            const n = Named{ .id = @truncate(d.val >> 48), .version = @truncate(d.val >> 32), .name = name };
            if (is_module) {
                if (t.module_count == MAX_MODULES) return error.BadDynamic;
                t.modules[t.module_count] = n;
                t.module_count += 1;
            } else if (d.tag == tag_import) {
                if (t.import_count == MAX_LIBRARIES) return error.BadDynamic;
                t.imports[t.import_count] = n;
                t.import_count += 1;
            } else {
                if (t.export_count == MAX_LIBRARIES) return error.BadDynamic;
                t.exports[t.export_count] = n;
                t.export_count += 1;
            }
        }
        return t;
    }

    fn find(list: []const Named, id: u32) ?Named {
        for (list) |n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// As `Image.linked`, from the table.
    pub fn linked(t: *const Names, im: *const Image, s: Sym) ?Image.Linked {
        const name = im.symbolName(s) orelse return null;
        const parts = nid.Symbol.parse(name) orelse return null;
        const libs = if (s.defined()) t.exports[0..t.export_count] else t.imports[0..t.import_count];
        const lib = find(libs, parts.library) orelse return null;
        const mod = find(t.modules[0..t.module_count], parts.module) orelse return null;
        return .{ .nid = parts.nid, .library = lib.name, .module = mod.name };
    }
};

fn rd(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const fixture = @import("fixture.sig");

test "a PS5 executable: segments, tables, names" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .dynexec);
    b.selfModule("eboot", 0);
    const kernel_mod = b.neededModule("libkernel", 1);
    const kernel_lib = b.importLibrary("libkernel", 1);
    const usleep = b.importSymbol(nid.of("sceKernelUsleep"), kernel_lib, kernel_mod, STT_FUNC);
    b.relative(fixture.DATA + 0, fixture.TEXT + 0x10);
    b.jumpSlot(fixture.DATA + 8, usleep);
    b.entry = fixture.TEXT;
    const file = b.finish();

    const im = try Image.parse(file);
    try std.testing.expectEqual(Dialect.ps5, im.dialect);
    try std.testing.expectEqual(Kind.dynexec, im.kind);
    try std.testing.expectEqual(@as(u64, fixture.TEXT), im.entry);
    try std.testing.expectEqual(@as(usize, 2), im.segments().len);
    try std.testing.expect(im.segments()[0].exec and !im.segments()[0].write);
    try std.testing.expect(im.segments()[1].write and !im.segments()[1].exec);
    try std.testing.expectEqual(@as(u64, 0), im.lo);
    try std.testing.expectEqual(@as(u64, 0), im.hi % PAGE);
    try std.testing.expect(im.hi >= fixture.DATA + fixture.DATA_SIZE);
    try std.testing.expect(im.proc_param != null);

    try std.testing.expectEqualStrings("eboot", im.moduleName().?);
    try std.testing.expectEqualStrings("libkernel", im.named(.needed_module, 1).?.name);
    try std.testing.expectEqualStrings("libkernel", im.named(.import_library, 1).?.name);
    try std.testing.expectEqual(@as(?Named, null), im.named(.import_library, 7));

    try std.testing.expectEqual(@as(usize, 2), im.symtab.len); // the null symbol, then usleep
    const s = im.symtab[usleep];
    try std.testing.expect(!s.defined() and s.bind() == STB_GLOBAL and s.kind() == STT_FUNC);
    const l = im.linked(s).?;
    try std.testing.expectEqual(nid.of("sceKernelUsleep"), l.nid);
    try std.testing.expectEqualStrings("libkernel", l.library);
    try std.testing.expectEqualStrings("libkernel", l.module);

    try std.testing.expectEqual(@as(usize, 1), im.rela.len);
    try std.testing.expectEqual(@as(u32, R.RELATIVE), im.rela[0].kind());
    try std.testing.expectEqual(@as(i64, fixture.TEXT + 0x10), im.rela[0].addend);
    try std.testing.expectEqual(@as(usize, 1), im.jmprel.len);
    try std.testing.expectEqual(@as(u32, R.JUMP_SLOT), im.jmprel[0].kind());
    try std.testing.expectEqual(usleep, im.jmprel[0].sym());
}

test "a module: its exports and its thread storage" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .module);
    b.selfModule("libTest", 0);
    const lib = b.exportLibrary("libTest", 1);
    const f = b.exportSymbol(nid.of("testFunction"), lib, 0, fixture.TEXT + 0x20, STT_FUNC);
    b.tls(fixture.DATA + 0x100, 8, 24, 16);
    b.init_at = fixture.TEXT + 0x40;
    const file = b.finish();

    const im = try Image.parse(file);
    try std.testing.expectEqual(Kind.module, im.kind);
    try std.testing.expect(!im.kind.isExecutable());
    try std.testing.expect(im.module_param != null and im.proc_param == null);
    try std.testing.expectEqual(@as(u64, fixture.TEXT + 0x40), im.init);
    const t = im.tls.?;
    try std.testing.expectEqual(@as(u64, 8), t.filesz);
    try std.testing.expectEqual(@as(u64, 24), t.memsz);
    try std.testing.expectEqual(@as(u64, 16), t.alignment);
    const s = im.symtab[f];
    try std.testing.expect(s.defined() and s.visible());
    try std.testing.expectEqual(@as(u64, fixture.TEXT + 0x20), s.value);
    const l = im.linked(s).?;
    try std.testing.expectEqualStrings("libTest", l.library);
    try std.testing.expectEqualStrings("libTest", l.module);
}

test "files that are not what they say are refused, not read past" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .dynexec);
    b.selfModule("eboot", 0);
    const m = b.neededModule("libkernel", 1);
    const l = b.importLibrary("libkernel", 1);
    const s = b.importSymbol(nid.of("exit"), l, m, STT_FUNC);
    b.jumpSlot(fixture.DATA, s);
    const file = b.finish();
    _ = try Image.parse(file);

    var copy: [fixture.SIZE]u8 = undefined;
    const bad = copy[0..file.len];

    @memcpy(bad, file);
    bad[1] = 'X';
    try std.testing.expectError(error.NotElf, Image.parse(bad));

    @memcpy(bad, file);
    bad[7] = 0; // (System V's OS ABI: a Linux program)
    try std.testing.expectError(error.NotSce, Image.parse(bad));

    @memcpy(bad, file);
    std.mem.writeInt(u16, bad[16..18], 3, .little); // ET_DYN
    try std.testing.expectError(error.NotSce, Image.parse(bad));

    // The file cut off at every length. What this looks for is a read past
    // the bytes given (the test would stop there): either answer is fine.
    var n: usize = 0;
    while (n < file.len) : (n += 1) {
        _ = Image.parse(file[0..n]) catch continue;
    }

    // A table that claims more than the file has.
    @memcpy(bad, file);
    const dyn_off = fixture.dynamicOffset(file);
    var i: usize = dyn_off;
    while (std.mem.readInt(u64, bad[i..][0..8], .little) != DT.NULL) : (i += 16) {
        if (std.mem.readInt(u64, bad[i..][0..8], .little) == DT.STRSZ) std.mem.writeInt(u64, bad[i + 8 ..][0..8], 1 << 40, .little);
    }
    try std.testing.expectError(error.BadDynamic, Image.parse(bad));

    // Both consoles' spellings at once.
    @memcpy(bad, file);
    i = dyn_off;
    while (std.mem.readInt(u64, bad[i..][0..8], .little) != DT.NULL) : (i += 16) {
        if (std.mem.readInt(u64, bad[i..][0..8], .little) == DT.SCE_IMPORT_LIB_1) std.mem.writeInt(u64, bad[i..][0..8], DT.SCE_IMPORT_LIB, .little);
    }
    try std.testing.expectError(error.MixedDialect, Image.parse(bad));
}

test "thread storage a file cannot mean is refused" {
    var buf: [fixture.SIZE]u8 = undefined;
    // More than any program's (and enough to overflow a sum of them).
    for ([_]u64{ TLS_MAX + 1, 1 << 40, std.math.maxInt(u64), std.math.maxInt(u64) - 63 }) |memsz| {
        var b = fixture.Builder.init(&buf, .module);
        b.selfModule("libTest", 0);
        b.tls(fixture.DATA + 0x100, 0, memsz, 16);
        try std.testing.expectError(error.BadSegment, Image.parse(b.finish()));
    }
    // An alignment that is no power of two, and one past a page.
    for ([_]u64{ 24, PAGE * 2 }) |alignment| {
        var b = fixture.Builder.init(&buf, .module);
        b.selfModule("libTest", 0);
        b.tls(fixture.DATA + 0x100, 8, 16, alignment);
        try std.testing.expectError(error.BadSegment, Image.parse(b.finish()));
    }
    // The most it may be is taken.
    var b = fixture.Builder.init(&buf, .module);
    b.selfModule("libTest", 0);
    b.tls(fixture.DATA + 0x100, 8, TLS_MAX, 16);
    try std.testing.expectEqual(TLS_MAX, (try Image.parse(b.finish())).tls.?.memsz);
}

test "without Sony's size tag the symbols are counted from the hash table" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .module);
    b.selfModule("libTest", 0);
    const lib = b.exportLibrary("libTest", 1);
    _ = b.exportSymbol(nid.of("one"), lib, 0, fixture.TEXT, STT_FUNC);
    _ = b.exportSymbol(nid.of("two"), lib, 0, fixture.TEXT + 8, STT_FUNC);
    b.symtab_size_tag = false;
    const im = try Image.parse(b.finish());
    try std.testing.expectEqual(@as(usize, 3), im.symtab.len); // the null symbol and the two
    try std.testing.expectEqual(nid.of("two"), im.linked(im.symtab[2]).?.nid);
}

test "the names table answers as the file does, and a file with too many is refused" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .dynexec);
    b.selfModule("eboot", 0);
    const m = b.neededModule("libkernel", 1);
    const l = b.importLibrary("libkernel", 1);
    const s = b.importSymbol(nid.of("write"), l, m, STT_FUNC);
    const im = try Image.parse(b.finish());
    const names = try Names.init(&im);
    try std.testing.expectEqual(@as(u16, 1), names.import_count);
    try std.testing.expectEqual(@as(u16, 2), names.module_count); // itself and the one it needs
    const a = names.linked(&im, im.symtab[s]).?;
    const c = im.linked(im.symtab[s]).?;
    try std.testing.expectEqual(c.nid, a.nid);
    try std.testing.expectEqualStrings(c.library, a.library);
    try std.testing.expectEqualStrings(c.module, a.module);
}

test "an executable called relocatable by its older type is one" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .dynexec);
    b.selfModule("eboot", 0);
    const file = b.finish();
    var copy: [fixture.SIZE]u8 = undefined;
    @memcpy(copy[0..file.len], file);
    std.mem.writeInt(u16, copy[16..18], 0xfe04, .little);
    try std.testing.expectEqual(Kind.dynexec, (try Image.parse(copy[0..file.len])).kind);
}
