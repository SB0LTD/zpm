//! @zpm/ps5 link — PlayStation modules loaded into one address space and
//! bound to each other: what the console's own linker does inside a
//! process, done here for the program as it is (no file is rewritten).
//!
//!   load   a file is given addresses, its segments are copied there, and
//!          what it exports is entered in one table keyed by NID;
//!   link   every module loaded since the last link has its relocations
//!          applied: its own addresses, and each import bound to whoever
//!          provides it;
//!   after  the segments get the protections the file asks for (the
//!          relocated read-only part included), and the caller runs the
//!          modules' start functions (`startOrder` says in what order: a
//!          module after the modules it needs) and jumps to the executable.
//!
//! An import is `NID#library#module`. It is looked up by its NID and its
//! library's name: first among the loaded modules' exports (a game's own
//! copy of a library wins), then in the host's own libraries (`builtin`:
//! system libraries written natively), then it is the host's to say what a
//! symbol nobody has is bound to (`missing`: a stub that reports the call),
//! or the link fails. A weak import nobody has is 0. Binding is eager: all
//! of it happens in `link`, none on a first call.
//!
//! Thread storage is the x86-64 kind (variant II): every module with
//! thread-local data gets an index and a place below the thread pointer;
//! `staticTls` says how much a thread's block needs and `initTls` fills
//! one.
//!
//! The linker runs in the address space it loads into: the host says where
//! (`reserve`) and it writes there directly. Nothing is allocated: the
//! module table, the library names and the export table are the caller's
//! storage, and running out of any is an error.

const std = @import("std");
const elf = @import("elf.sig");
const nid = @import("nid.sig");

pub const Error = elf.Error || error{
    /// No addresses for the module (the host's `reserve` refused).
    NoSpace,
    /// The module, library or export table is full.
    TableFull,
    /// A relocation outside the module, of a kind unknown here, or naming
    /// a symbol the file does not have.
    BadRelocation,
    /// An import nobody provides, and the host had no stand-in for it.
    Unresolved,
    /// The host could not change a segment's protection.
    Protect,
};

/// An import nobody provides, as the host is asked about it.
pub const Missing = struct {
    /// The library and module its name says ("" for a symbol that is not
    /// named Sony's way: a plain name, hashed to `nid`).
    library: []const u8,
    module: []const u8,
    nid: nid.Nid,
    /// What it is: a stand-in for a function is code to call, one for an
    /// object is memory to read and write. They cannot be the same thing.
    kind: Kind,
    /// An object's size, when the symbol says (else 0).
    size: u64,

    pub const Kind = enum { function, object, other };
};

/// What the linker asks of where it runs.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// `size` bytes of zeroed, writable memory at a multiple of the page
    /// (at `want` when not 0: a fixed-address executable); null to refuse.
    reserve: *const fn (ctx: ?*anyopaque, want: u64, size: u64) ?u64,
    /// Gives a reservation back (a module that then could not be loaded).
    release: *const fn (ctx: ?*anyopaque, addr: u64, size: u64) void = noRelease,
    /// The final protection of whole pages of a module.
    protect: *const fn (ctx: ?*anyopaque, addr: u64, size: u64, read: bool, write: bool, exec: bool) bool,
    /// A symbol of one of the host's own libraries, or null.
    builtin: *const fn (ctx: ?*anyopaque, library: []const u8, n: nid.Nid) ?u64 = noBuiltin,
    /// What to bind an import nobody has to, or null to fail the link.
    missing: *const fn (ctx: ?*anyopaque, what: Missing) ?u64 = noStandIn,

    fn noRelease(_: ?*anyopaque, _: u64, _: u64) void {}
    fn noBuiltin(_: ?*anyopaque, _: []const u8, _: nid.Nid) ?u64 {
        return null;
    }
    pub fn noStandIn(_: ?*anyopaque, _: Missing) ?u64 {
        return null;
    }
};

pub const NAME_MAX = 47;

/// A module's or library's name, kept by value (the file it came from goes).
pub const Name = struct {
    bytes: [NAME_MAX]u8 = undefined,
    len: u8 = 0,

    pub fn of(s: []const u8) Name {
        var n = Name{};
        n.len = @intCast(@min(s.len, NAME_MAX));
        @memcpy(n.bytes[0..n.len], s[0..n.len]);
        return n;
    }
    pub fn slice(n: *const Name) []const u8 {
        return n.bytes[0..n.len];
    }
};

/// A loaded module.
pub const Module = struct {
    /// Its own name (the file says; else the file's), and the file's.
    name: Name = .{},
    file: Name = .{},
    kind: elf.Kind = .module,
    /// Where address 0 of the file is in memory.
    base: u64 = 0,
    /// The memory it occupies.
    start: u64 = 0,
    size: u64 = 0,
    /// Addresses in memory (0: none).
    entry: u64 = 0,
    init: u64 = 0,
    fini: u64 = 0,
    proc_param: u64 = 0,
    /// (how much of it the file vouches for)
    proc_param_size: u64 = 0,
    module_param: u64 = 0,
    eh_frame_hdr: u64 = 0,
    eh_frame_hdr_size: u64 = 0,
    /// Thread storage: its index (0: the module has none), its initial
    /// bytes, and where its block is: `tls_offset` bytes below the thread
    /// pointer.
    tls_index: u16 = 0,
    tls_image: u64 = 0,
    tls_filesz: u64 = 0,
    tls_memsz: u64 = 0,
    tls_offset: u64 = 0,
    /// The loaded modules it names as needed, by index: one bit each (set
    /// by `link`; modules past the 64th are not recorded).
    needs: u64 = 0,
    /// The file, until the module is linked (the caller keeps its bytes
    /// until then).
    image: elf.Image = undefined,
    linked: bool = false,
    /// `startOrder` has handed it out: its start function is the caller's
    /// to run, once.
    started: bool = false,
    /// It could not be linked (`abandon`): nothing is bound to it any
    /// more, and it is as if it had never been loaded, but for the
    /// addresses it keeps.
    abandoned: bool = false,
};

/// One exported symbol.
pub const Export = struct {
    nid: nid.Nid = 0,
    addr: u64 = 0,
    /// Index of its library's name, plus one (0: an empty slot).
    library: u16 = 0,
    module: u16 = 0,
    /// A thread-local symbol: `addr` is its offset in the module's block.
    tls: bool = false,
};

pub const Storage = struct {
    modules: []Module,
    libraries: []Name,
    /// A power of two; the table is full at three quarters.
    exports: []Export,
};

pub const Linker = struct {
    host: Host,
    modules: []Module,
    module_count: u16 = 0,
    libraries: []Name,
    library_count: u16 = 0,
    exports: []Export,
    export_count: u32 = 0,
    /// The bytes below the thread pointer the modules' thread storage takes.
    tls_size: u64 = 0,
    tls_align: u64 = 16,
    /// The most it may take: threads already running have that much and no
    /// more, so a module whose storage would not fit is not loaded.
    tls_limit: u64 = std.math.maxInt(u64),
    /// The module the last `link` failed on (NO_MODULE: none): the caller
    /// may `abandon` it and link the rest again.
    failed: u16 = NO_MODULE,
    /// How much was bound where (for a log line).
    stats: Stats = .{},

    pub const NO_MODULE: u16 = std.math.maxInt(u16);

    pub const Stats = struct {
        relocations: u64 = 0,
        from_modules: u32 = 0,
        from_host: u32 = 0,
        stand_ins: u32 = 0,
        weak_absent: u32 = 0,
    };

    pub fn init(host: Host, storage: Storage) Linker {
        std.debug.assert(std.math.isPowerOfTwo(storage.exports.len));
        @memset(storage.exports, .{});
        return .{ .host = host, .modules = storage.modules, .libraries = storage.libraries, .exports = storage.exports };
    }

    pub fn loaded(l: *const Linker) []const Module {
        return l.modules[0..l.module_count];
    }

    /// The loaded module called `name`, if any.
    pub fn find(l: *const Linker, name: []const u8) ?*const Module {
        for (l.loaded()) |*m| {
            if (std.mem.eql(u8, m.name.slice(), name[0..@min(name.len, NAME_MAX)])) return m;
        }
        return null;
    }

    /// Gives a file addresses, copies its segments there and enters its
    /// exports. `bytes` must stay until `link` returns. Its index.
    pub fn load(l: *Linker, name: []const u8, bytes: []const u8) Error!u16 {
        if (l.module_count == l.modules.len) return error.TableFull;
        const im = try elf.Image.parse(bytes);
        const fixed = im.kind == .exec;
        // Where its thread storage goes, before anything is taken: below
        // the thread pointer, under the modules' before it, at an address
        // that agrees with the one the file gives it (a static linker
        // counts on the block's address being its own, modulo its
        // alignment, when it computes offsets from the thread pointer).
        var tls_offset: u64 = 0;
        if (im.tls) |t| {
            const end = std.math.add(u64, l.tls_size, t.memsz) catch return error.BadSegment;
            tls_offset = std.math.add(u64, end, (0 -% t.vaddr -% end) & (t.alignment - 1)) catch return error.BadSegment;
            if (tls_offset > l.tls_limit) return error.NoSpace;
        }
        const start = l.host.reserve(l.host.ctx, if (fixed) im.lo else 0, im.span()) orelse return error.NoSpace;
        if (start % elf.PAGE != 0 or (fixed and start != im.lo)) {
            l.host.release(l.host.ctx, start, im.span());
            return error.NoSpace;
        }
        const base = start -% im.lo;
        for (im.segments()) |s| {
            const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(base +% s.vaddr)));
            @memcpy(dst[0..@intCast(s.filesz)], bytes[@intCast(s.offset)..][0..@intCast(s.filesz)]);
        }
        const index = l.module_count;
        const m = &l.modules[index];
        m.* = .{
            .name = Name.of(im.moduleName() orelse name),
            .file = Name.of(name),
            .kind = im.kind,
            .base = base,
            .start = start,
            .size = im.span(),
            .entry = if (im.entry != 0) base +% im.entry else 0,
            .init = if (im.init != 0) base +% im.init else 0,
            .fini = if (im.fini != 0) base +% im.fini else 0,
            .proc_param = if (im.proc_param) |r| base +% r.vaddr else 0,
            .proc_param_size = if (im.proc_param) |r| r.size else 0,
            .module_param = if (im.module_param) |r| base +% r.vaddr else 0,
            .eh_frame_hdr = if (im.eh_frame_hdr) |r| base +% r.vaddr else 0,
            .eh_frame_hdr_size = if (im.eh_frame_hdr) |r| r.size else 0,
            .image = im,
        };
        if (im.tls) |t| {
            m.tls_index = l.nextTlsIndex();
            m.tls_image = base +% t.vaddr;
            m.tls_filesz = t.filesz;
            m.tls_memsz = t.memsz;
            m.tls_offset = tls_offset;
        }
        // (a module whose exports do not fit is not loaded at all: nothing
        // of it stays, its addresses and its thread storage's place go
        // back. It is counted only once they are in: a thread being made
        // meanwhile reads the table up to the count, and must not find a
        // module whose memory is about to go.)
        l.enterExports(index) catch |e| {
            l.host.release(l.host.ctx, start, im.span());
            return e;
        };
        l.module_count += 1;
        if (im.tls) |t| {
            l.tls_size = tls_offset;
            l.tls_align = @max(l.tls_align, t.alignment);
        }
        return index;
    }

    fn nextTlsIndex(l: *const Linker) u16 {
        var n: u16 = 1;
        for (l.loaded()) |m| {
            if (m.tls_index != 0) n += 1;
        }
        return n;
    }

    fn library(l: *Linker, name: []const u8) Error!u16 {
        const want = name[0..@min(name.len, NAME_MAX)];
        for (l.libraries[0..l.library_count], 0..) |*n, i| {
            if (std.mem.eql(u8, n.slice(), want)) return @intCast(i + 1);
        }
        if (l.library_count == l.libraries.len) return error.TableFull;
        l.libraries[l.library_count] = Name.of(want);
        l.library_count += 1;
        return l.library_count;
    }

    fn knownLibrary(l: *const Linker, name: []const u8) u16 {
        const want = name[0..@min(name.len, NAME_MAX)];
        for (l.libraries[0..l.library_count], 0..) |*n, i| {
            if (std.mem.eql(u8, n.slice(), want)) return @intCast(i + 1);
        }
        return 0;
    }

    /// Whether a symbol of `im` is one other modules may import.
    fn exported(im: *const elf.Image, names: *const elf.Names, s: elf.Sym) ?elf.Image.Linked {
        if (!s.defined() or s.bind() == elf.STB_LOCAL or !s.visible()) return null;
        // (a definition outside the module is not one)
        if (s.kind() != elf.STT_TLS and !im.covered(s.value, 0)) return null;
        return names.linked(im, s);
    }

    fn enterExports(l: *Linker, index: u16) Error!void {
        const m = &l.modules[index];
        const im = &m.image;
        const names = try elf.Names.init(im);
        // Room for all of them first (and their libraries' names): a
        // module's exports go in whole or not at all.
        const libraries_before = l.library_count;
        errdefer l.library_count = libraries_before;
        for (names.exports[0..names.export_count]) |n| _ = try l.library(n.name);
        var count: usize = 0;
        for (im.symtab) |s| {
            if (exported(im, &names, s) != null) count += 1;
        }
        if ((l.export_count + count) * 4 > l.exports.len * 3) return error.TableFull;
        for (im.symtab) |s| {
            const info = exported(im, &names, s) orelse continue;
            const is_tls = s.kind() == elf.STT_TLS;
            const lib = l.knownLibrary(info.library);
            const mask = l.exports.len - 1;
            var at: usize = @as(usize, @truncate(info.nid)) & mask;
            // Every export is entered, after any earlier one of the same
            // name: a lookup finds the first module's (the first to export
            // a name keeps it), and a module can still be asked for its
            // own, or take the first one's place should that one be
            // abandoned.
            while (l.exports[at].library != 0) at = (at + 1) & mask;
            l.exports[at] = .{
                .nid = info.nid,
                .addr = if (is_tls) s.value else m.base +% s.value,
                .library = lib,
                .module = index,
                .tls = is_tls,
            };
            l.export_count += 1;
        }
    }

    /// What module `index` exports under a NID, whatever its library (a
    /// program asking one module for a symbol by name).
    pub fn lookupIn(l: *const Linker, index: u16, n: nid.Nid) ?Export {
        if (index >= l.module_count or l.modules[index].abandoned) return null;
        const mask = l.exports.len - 1;
        var at: usize = @as(usize, @truncate(n)) & mask;
        while (l.exports[at].library != 0) : (at = (at + 1) & mask) {
            if (l.exports[at].nid == n and l.exports[at].module == index) return l.exports[at];
        }
        return null;
    }

    /// A loaded module's export, by its library's name and NID.
    pub fn lookup(l: *const Linker, lib_name: []const u8, n: nid.Nid) ?Export {
        const lib = l.knownLibrary(lib_name);
        if (lib == 0) return null;
        const mask = l.exports.len - 1;
        var at: usize = @as(usize, @truncate(n)) & mask;
        while (l.exports[at].library != 0) : (at = (at + 1) & mask) {
            const e = l.exports[at];
            // (an abandoned module provides nothing)
            if (e.nid == n and e.library == lib and !l.modules[e.module].abandoned) return e;
        }
        return null;
    }

    /// Binds every module loaded since the last link, then gives each its
    /// final protections.
    pub fn link(l: *Linker) Error!void {
        l.failed = NO_MODULE;
        for (l.modules[0..l.module_count], 0..) |*m, i| {
            if (m.linked) continue;
            // (a relocation applied twice writes the same word twice: a
            // link that failed further on may be run again)
            errdefer l.failed = @intCast(i);
            const names = try elf.Names.init(&m.image);
            try l.relocate(@intCast(i), &names, m.image.rela);
            try l.relocate(@intCast(i), &names, m.image.jmprel);
            // Which loaded modules it says it needs (for the order they
            // are started in). A name nobody loaded is not an error here:
            // its imports were bound, or stood in for, one by one.
            var needed = m.image.names(.needed_module);
            while (needed.next()) |n| {
                const other = l.indexOf(n.name) orelse continue;
                if (other < 64 and other != i and !l.modules[other].abandoned) m.needs |= @as(u64, 1) << @intCast(other);
            }
        }
        for (l.modules[0..l.module_count], 0..) |*m, i| {
            if (m.linked) continue;
            errdefer l.failed = @intCast(i);
            try l.protect(m);
            m.linked = true;
            // The file may go now: nothing of the module points into it.
            m.image.bytes = &.{};
            m.image.dynamic = &.{};
            m.image.strtab = &.{};
            m.image.symtab = &.{};
            m.image.rela = &.{};
            m.image.jmprel = &.{};
        }
    }

    /// A module that could not be linked (or, linked, could not be made
    /// usable) is given up: it keeps its addresses, but from here on it
    /// exports nothing, is never linked again nor started, and later
    /// links go on without it. Modules not yet linked that were bound to
    /// it are bound again by the next `link`, to whoever else provides
    /// the name or to the host's stand-in.
    pub fn abandon(l: *Linker, index: u16) void {
        if (index >= l.module_count) return;
        const m = &l.modules[index];
        m.abandoned = true;
        m.linked = true;
        m.started = true;
        m.image.bytes = &.{};
        m.image.dynamic = &.{};
        m.image.strtab = &.{};
        m.image.symtab = &.{};
        m.image.rela = &.{};
        m.image.jmprel = &.{};
    }

    fn indexOf(l: *const Linker, name: []const u8) ?usize {
        for (l.loaded(), 0..) |*m, i| {
            if (std.mem.eql(u8, m.name.slice(), name[0..@min(name.len, NAME_MAX)])) return i;
        }
        return null;
    }

    /// The linked modules whose start functions have not been handed out
    /// yet, in the order to run them: a module after every module it
    /// needs (modules that need each other: in the order they were
    /// loaded). Executables are not among them: a program starts itself.
    /// Fills `out` and returns the part filled; call again for the rest
    /// when `out` was too small.
    pub fn startOrder(l: *Linker, out: []u16) []u16 {
        var n: usize = 0;
        var visiting: u64 = 0;
        for (0..l.module_count) |i| l.visit(@intCast(i), &visiting, out, &n);
        return out[0..n];
    }

    fn visit(l: *Linker, index: u16, visiting: *u64, out: []u16, n: *usize) void {
        const m = &l.modules[index];
        if (!m.linked or m.started or m.kind.isExecutable()) return;
        const bit: u64 = if (index < 64) @as(u64, 1) << @intCast(index) else 0;
        if (visiting.* & bit != 0) return; // (it needs itself, by a way round)
        visiting.* |= bit;
        var needs = m.needs;
        while (needs != 0) {
            const other: u16 = @intCast(@ctz(needs));
            needs &= needs - 1;
            if (other < l.module_count) l.visit(other, visiting, out, n);
        }
        visiting.* &= ~bit;
        if (m.started or n.* == out.len) return;
        m.started = true;
        out[n.*] = index;
        n.* += 1;
    }

    const Target = struct { value: u64, module: u16, tls: bool };

    fn relocate(l: *Linker, index: u16, names: *const elf.Names, relas: []align(1) const elf.Rela) Error!void {
        const m = &l.modules[index];
        const im = &m.image;
        for (relas) |r| {
            // (a relocation that does nothing may name any place)
            if (r.kind() == elf.R.NONE) continue;
            if (!im.covered(r.offset, 8)) return error.BadRelocation;
            const where: *align(1) u64 = @ptrFromInt(@as(usize, @intCast(m.base +% r.offset)));
            const addend: u64 = @bitCast(r.addend);
            switch (r.kind()) {
                elf.R.RELATIVE => where.* = m.base +% addend,
                elf.R.@"64" => where.* = (try l.resolve(index, names, r.sym())).value +% addend,
                elf.R.GLOB_DAT, elf.R.JUMP_SLOT => where.* = (try l.resolve(index, names, r.sym())).value,
                elf.R.DTPMOD64 => where.* = if (r.sym() == 0) m.tls_index else l.modules[(try l.resolve(index, names, r.sym())).module].tls_index,
                elf.R.DTPOFF64 => where.* = (if (r.sym() == 0) 0 else (try l.resolveTls(index, names, r.sym())).value) +% addend,
                elf.R.TPOFF64 => {
                    // (below the thread pointer: the symbol's place in its
                    // module's block, less where that block starts)
                    const t: Target = if (r.sym() == 0) .{ .value = 0, .module = index, .tls = true } else try l.resolveTls(index, names, r.sym());
                    where.* = t.value +% addend -% l.modules[t.module].tls_offset;
                },
                else => return error.BadRelocation,
            }
            l.stats.relocations += 1;
        }
    }

    fn resolveTls(l: *Linker, index: u16, names: *const elf.Names, sym_index: u32) Error!Target {
        const t = try l.resolve(index, names, sym_index);
        if (!t.tls) return error.BadRelocation;
        return t;
    }

    /// What a symbol of module `index` stands for: its own definition, or
    /// whoever provides the import.
    fn resolve(l: *Linker, index: u16, names: *const elf.Names, sym_index: u32) Error!Target {
        const m = &l.modules[index];
        const im = &m.image;
        if (sym_index >= im.symtab.len) return error.BadRelocation;
        const s = im.symtab[sym_index];
        const is_tls = s.kind() == elf.STT_TLS;
        // Its own: a definition, or a local symbol whatever it says of
        // itself (the null symbol among them: the module's own address 0),
        // as FreeBSD's linker takes them.
        if (s.defined() or s.bind() == elf.STB_LOCAL) {
            return .{ .value = if (is_tls) s.value else m.base +% s.value, .module = index, .tls = is_tls };
        }
        const weak = s.bind() == elf.STB_WEAK;
        // An import by NID and library. A symbol not named Sony's way (a
        // plain name, a NID alone) is asked for by its NID in any library.
        var lib_name: []const u8 = "";
        var mod_name: []const u8 = "";
        var n: nid.Nid = 0;
        if (names.linked(im, s)) |info| {
            lib_name = info.library;
            mod_name = info.module;
            n = info.nid;
            if (l.lookup(lib_name, n)) |e| {
                l.stats.from_modules += 1;
                return .{ .value = e.addr, .module = e.module, .tls = e.tls };
            }
        } else {
            const name = im.symbolName(s) orelse "";
            if (name.len == 0) {
                if (!weak) return error.Unresolved;
                l.stats.weak_absent += 1;
                return .{ .value = 0, .module = index, .tls = false };
            }
            n = nid.parse(name) orelse nid.of(name);
        }
        if (l.host.builtin(l.host.ctx, lib_name, n)) |addr| {
            l.stats.from_host += 1;
            return .{ .value = addr, .module = index, .tls = false };
        }
        if (weak) {
            l.stats.weak_absent += 1;
            return .{ .value = 0, .module = index, .tls = false };
        }
        const addr = l.host.missing(l.host.ctx, .{
            .library = lib_name,
            .module = mod_name,
            .nid = n,
            .kind = switch (s.kind()) {
                elf.STT_FUNC => .function,
                elf.STT_OBJECT => .object,
                else => .other,
            },
            .size = s.size,
        }) orelse return error.Unresolved;
        l.stats.stand_ins += 1;
        return .{ .value = addr, .module = index, .tls = false };
    }

    /// Each segment as its file asks, and the relocated read-only part
    /// read-only. Protection is by whole pages, and no two segments share
    /// one (the reader refuses a file where they do), so that part's first
    /// and last pages are its own when it starts or ends with its segment,
    /// as linkers lay it out; an end in the middle of a segment keeps its
    /// page writable, for the data that shares it.
    fn protect(l: *Linker, m: *const Module) Error!void {
        const im = &m.image;
        for (im.segments()) |s| {
            const lo = std.mem.alignBackward(u64, s.vaddr, elf.PAGE);
            const hi = std.mem.alignForward(u64, s.end(), elf.PAGE);
            if (!l.host.protect(l.host.ctx, m.base +% lo, hi - lo, s.read or s.exec, s.write, s.exec)) return error.Protect;
        }
        if (im.relro) |r| {
            const end = r.vaddr + r.size;
            for (im.segments()) |s| {
                if (r.vaddr < s.vaddr or end > s.end()) continue;
                const lo = if (r.vaddr == s.vaddr) std.mem.alignBackward(u64, r.vaddr, elf.PAGE) else std.mem.alignForward(u64, r.vaddr, elf.PAGE);
                const hi = if (end == s.end()) std.mem.alignForward(u64, end, elf.PAGE) else std.mem.alignBackward(u64, end, elf.PAGE);
                if (hi > lo and !l.host.protect(l.host.ctx, m.base +% lo, hi - lo, true, false, false)) return error.Protect;
                break;
            }
        }
    }

    // ── Thread storage ──────────────────────────────────────────────────────

    pub const StaticTls = struct { size: u64, alignment: u64 };

    /// What a thread needs below its thread pointer for every module
    /// loaded so far.
    pub fn staticTls(l: *const Linker) StaticTls {
        return .{ .size = std.mem.alignForward(u64, l.tls_size, l.tls_align), .alignment = l.tls_align };
    }

    /// Fills a thread's storage: `tp` is its thread pointer, with
    /// `staticTls().size` bytes of memory below it. Each module's initial
    /// bytes, then zeroes.
    pub fn initTls(l: *const Linker, tp: u64) void {
        for (l.loaded()) |*m| initTlsOf(m, tp);
    }

    /// One module's part of a thread's storage (a module loaded while
    /// threads run: its block is filled in each of them).
    pub fn initTlsOf(m: *const Module, tp: u64) void {
        if (m.tls_index == 0) return;
        const block: [*]u8 = @ptrFromInt(@as(usize, @intCast(tp - m.tls_offset)));
        const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(m.tls_image)));
        @memcpy(block[0..@intCast(m.tls_filesz)], src[0..@intCast(m.tls_filesz)]);
        @memset(block[@intCast(m.tls_filesz)..@intCast(m.tls_memsz)], 0);
    }

    /// The module with this thread storage index.
    pub fn tlsModule(l: *const Linker, index: u64) ?*const Module {
        for (l.loaded()) |*m| {
            if (m.tls_index != 0 and m.tls_index == index) return m;
        }
        return null;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const fixture = @import("fixture.sig");

/// A host for tests: addresses from a page-aligned array, protections
/// noted, two libraries of its own.
const TestHost = struct {
    memory: [8 * fixture.SIZE]u8 align(elf.PAGE) = undefined,
    used: usize = 0,
    protects: u32 = 0,
    read_only: u32 = 0,
    /// The last range made read-only (address, size).
    read_only_range: [2]u64 = .{ 0, 0 },
    executable: u32 = 0,
    missing_asked: u32 = 0,
    objects_missing: u32 = 0,
    released: u32 = 0,
    /// Whether an import nobody has gets no stand-in (the link then fails).
    refuse_missing: bool = false,

    const USLEEP: u64 = 0x1111_0000;
    const STAND_IN: u64 = 0x2222_0000;
    const OBJECT_STAND_IN: u64 = 0x3333_0000;

    fn host(t: *TestHost) Host {
        return .{ .ctx = t, .reserve = reserve, .release = release, .protect = protect, .builtin = builtin, .missing = missing };
    }
    fn release(ctx: ?*anyopaque, _: u64, _: u64) void {
        const t: *TestHost = @ptrCast(@alignCast(ctx.?));
        t.released += 1;
    }
    fn reserve(ctx: ?*anyopaque, want: u64, size: u64) ?u64 {
        const t: *TestHost = @ptrCast(@alignCast(ctx.?));
        if (want != 0 or size > t.memory.len - t.used) return null;
        const at = @intFromPtr(&t.memory) + t.used;
        @memset(t.memory[t.used..][0..@intCast(size)], 0);
        t.used += @intCast(size);
        return at;
    }
    fn protect(ctx: ?*anyopaque, addr: u64, size: u64, read: bool, write: bool, exec: bool) bool {
        const t: *TestHost = @ptrCast(@alignCast(ctx.?));
        if (addr % elf.PAGE != 0 or size % elf.PAGE != 0) return false;
        t.protects += 1;
        if (read and !write and !exec) {
            t.read_only += 1;
            t.read_only_range = .{ addr, size };
        }
        if (exec) t.executable += 1;
        return true;
    }
    fn builtin(_: ?*anyopaque, lib: []const u8, n: nid.Nid) ?u64 {
        if (std.mem.eql(u8, lib, "libkernel") and n == nid.of("sceKernelUsleep")) return USLEEP;
        return null;
    }
    fn missing(ctx: ?*anyopaque, what: Missing) ?u64 {
        const t: *TestHost = @ptrCast(@alignCast(ctx.?));
        t.missing_asked += 1;
        if (t.refuse_missing) return null;
        if (what.kind == .object) {
            t.objects_missing += 1;
            return OBJECT_STAND_IN;
        }
        return STAND_IN;
    }
};

fn word(addr: u64) u64 {
    return @as(*align(1) const u64, @ptrFromInt(@as(usize, @intCast(addr)))).*;
}

test "an executable and a module: loaded, bound to each other and to the host" {
    // A module that exports a function and a thread-local variable.
    var lib_buf: [fixture.SIZE]u8 = undefined;
    var lb = fixture.Builder.init(&lib_buf, .module);
    lb.selfModule("libTest", 0);
    const lt = lb.exportLibrary("libTest", 1);
    _ = lb.exportSymbol(nid.of("testFunction"), lt, 0, fixture.TEXT + 0x20, elf.STT_FUNC);
    _ = lb.exportSymbol(nid.of("testVariable"), lt, 0, fixture.DATA + 0x40, elf.STT_OBJECT);
    const tv = lb.exportSymbol(nid.of("testThreadLocal"), lt, 0, 8, elf.STT_TLS);
    lb.data = &([_]u8{0} ** 0x100 ++ [_]u8{ 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8 });
    lb.tls(fixture.DATA + 0x100, 8, 24, 16);
    lb.tlsModule(fixture.DATA + 0x10);
    lb.tlsOffset(fixture.DATA + 0x18, tv, 0);
    lb.init_at = fixture.TEXT + 0x40;
    const lib_file = lb.finish();

    // An executable that imports from the module, from the host, and a
    // symbol nobody has (strongly, and weakly).
    var exe_buf: [fixture.SIZE]u8 = undefined;
    var eb = fixture.Builder.init(&exe_buf, .dynexec);
    eb.selfModule("eboot", 0);
    const m_test = eb.neededModule("libTest", 1);
    const m_kernel = eb.neededModule("libkernel", 2);
    const l_test = eb.importLibrary("libTest", 1);
    const l_kernel = eb.importLibrary("libkernel", 2);
    const f = eb.importSymbol(nid.of("testFunction"), l_test, m_test, elf.STT_FUNC);
    const v = eb.importSymbol(nid.of("testVariable"), l_test, m_test, elf.STT_OBJECT);
    const tl = eb.importSymbol(nid.of("testThreadLocal"), l_test, m_test, elf.STT_TLS);
    const usleep = eb.importSymbol(nid.of("sceKernelUsleep"), l_kernel, m_kernel, elf.STT_FUNC);
    const nobody = eb.importSymbol(nid.of("sceKernelNobodyHasThis"), l_kernel, m_kernel, elf.STT_FUNC);
    const maybe = eb.weakImport(nid.of("sceKernelMaybe"), l_kernel, m_kernel, elf.STT_FUNC);
    eb.relative(fixture.DATA + 0x00, fixture.TEXT + 0x10);
    eb.jumpSlot(fixture.DATA + 0x08, f);
    eb.globDat(fixture.DATA + 0x10, v);
    eb.absolute(fixture.DATA + 0x18, v, 4);
    eb.jumpSlot(fixture.DATA + 0x20, usleep);
    eb.jumpSlot(fixture.DATA + 0x28, nobody);
    eb.globDat(fixture.DATA + 0x30, maybe);
    eb.threadPointerOffset(fixture.DATA + 0x38, tl, 0);
    eb.entry = fixture.TEXT;
    const exe_file = eb.finish();

    var th = TestHost{};
    var modules: [4]Module = undefined;
    var libraries: [8]Name = undefined;
    var exports: [64]Export = undefined;
    var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    const exe = try l.load("eboot.bin", exe_file);
    const lib = try l.load("libTest.prx", lib_file);
    try l.link();

    const e = l.loaded()[exe];
    const t = l.loaded()[lib];
    try std.testing.expectEqualStrings("eboot", e.name.slice());
    try std.testing.expectEqualStrings("libTest", l.find("libTest").?.name.slice());
    try std.testing.expect(e.base % elf.PAGE == 0 and t.base % elf.PAGE == 0 and e.base != t.base);
    try std.testing.expectEqual(e.base + fixture.TEXT, e.entry);
    try std.testing.expectEqual(t.base + fixture.TEXT + 0x40, t.init);
    try std.testing.expect(e.proc_param == e.base + fixture.PARAM and t.module_param == t.base + fixture.PARAM);

    // The executable's words.
    const d = e.base + fixture.DATA;
    try std.testing.expectEqual(e.base + fixture.TEXT + 0x10, word(d + 0x00)); // its own address
    try std.testing.expectEqual(t.base + fixture.TEXT + 0x20, word(d + 0x08)); // the module's function
    try std.testing.expectEqual(t.base + fixture.DATA + 0x40, word(d + 0x10)); // its variable
    try std.testing.expectEqual(t.base + fixture.DATA + 0x44, word(d + 0x18)); // and 4 into it
    try std.testing.expectEqual(TestHost.USLEEP, word(d + 0x20)); // the host's own
    try std.testing.expectEqual(TestHost.STAND_IN, word(d + 0x28)); // nobody's: the stand-in
    try std.testing.expectEqual(@as(u64, 0), word(d + 0x30)); // weak and absent
    try std.testing.expectEqual(@as(u32, 1), th.missing_asked);

    // Thread storage: the module is the only one with any, so its block
    // is the 24 bytes (to 16: 32) below the thread pointer.
    try std.testing.expectEqual(@as(u16, 1), t.tls_index);
    try std.testing.expectEqual(@as(u16, 0), e.tls_index);
    try std.testing.expectEqual(@as(u64, 32), l.staticTls().size);
    try std.testing.expectEqual(@as(u64, 1), word(t.base + fixture.DATA + 0x10)); // its index
    try std.testing.expectEqual(@as(u64, 8), word(t.base + fixture.DATA + 0x18)); // the variable's place in its block
    const tp_offset: i64 = @bitCast(word(d + 0x38));
    try std.testing.expectEqual(@as(i64, 8 - 32), tp_offset); // and from the thread pointer
    var thread: [64]u8 align(16) = [_]u8{0x55} ** 64;
    const tp = @intFromPtr(&thread) + 48;
    l.initTls(tp);
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8 }, thread[16..24]);
    try std.testing.expect(std.mem.allEqual(u8, thread[24..40], 0)); // zeroes up to memsz
    try std.testing.expect(std.mem.allEqual(u8, thread[40..48], 0x55)); // (alignment's slack: not the module's)
    try std.testing.expectEqualStrings("libTest", l.tlsModule(1).?.name.slice());

    // Protections: code executable, and every call on whole pages.
    try std.testing.expect(th.protects >= 4 and th.executable == 2);
    try std.testing.expectEqual(@as(u32, 2), l.stats.from_host + l.stats.stand_ins);
    try std.testing.expectEqual(@as(u32, 1), l.stats.weak_absent);
    try std.testing.expect(l.lookup("libTest", nid.of("testFunction")) != null);
    try std.testing.expect(l.lookup("libTest", nid.of("sceKernelUsleep")) == null);
    try std.testing.expect(l.lookup("libOther", nid.of("testFunction")) == null);
}

test "an import nobody has fails the link when the host has no stand-in" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .dynexec);
    b.selfModule("eboot", 0);
    const m = b.neededModule("libkernel", 1);
    const lk = b.importLibrary("libkernel", 1);
    b.jumpSlot(fixture.DATA, b.importSymbol(nid.of("sceKernelNobodyHasThis"), lk, m, elf.STT_FUNC));
    const file = b.finish();

    var th = TestHost{};
    var h = th.host();
    h.missing = Host.noStandIn;
    var modules: [2]Module = undefined;
    var libraries: [4]Name = undefined;
    var exports: [16]Export = undefined;
    var l = Linker.init(h, .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    _ = try l.load("eboot.bin", file);
    try std.testing.expectError(error.Unresolved, l.link());
}

test "a relocation outside the module is refused" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .dynexec);
    b.selfModule("eboot", 0);
    b.relative(fixture.DATA + fixture.DATA_SIZE - 4, fixture.TEXT); // (its last 4 bytes are outside)
    const file = b.finish();

    var th = TestHost{};
    var modules: [2]Module = undefined;
    var libraries: [4]Name = undefined;
    var exports: [16]Export = undefined;
    var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    _ = try l.load("eboot.bin", file);
    try std.testing.expectError(error.BadRelocation, l.link());
}

test "tables that are full say so" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .module);
    b.selfModule("libTest", 0);
    const lt = b.exportLibrary("libTest", 1);
    _ = b.exportSymbol(nid.of("a"), lt, 0, fixture.TEXT, elf.STT_FUNC);
    _ = b.exportSymbol(nid.of("b"), lt, 0, fixture.TEXT, elf.STT_FUNC);
    _ = b.exportSymbol(nid.of("c"), lt, 0, fixture.TEXT, elf.STT_FUNC);
    _ = b.exportSymbol(nid.of("d"), lt, 0, fixture.TEXT, elf.STT_FUNC);
    b.tls(fixture.DATA + 0x100, 8, 24, 16);
    const file = b.finish();

    var th = TestHost{};
    var modules: [1]Module = undefined;
    var libraries: [4]Name = undefined;
    var exports: [4]Export = undefined; // (full at three of four)
    var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    try std.testing.expectError(error.TableFull, l.load("libTest.prx", file));
    try std.testing.expectEqual(@as(usize, 0), l.loaded().len);
    // (and nothing of it stays: no export, no library name, no place in a
    // thread's storage, and its addresses went back to the host)
    try std.testing.expectEqual(@as(u32, 0), l.export_count);
    try std.testing.expectEqual(@as(u16, 0), l.library_count);
    try std.testing.expect(l.lookup("libTest", nid.of("a")) == null);
    try std.testing.expectEqual(@as(u64, 0), l.staticTls().size);
    try std.testing.expectEqual(@as(u32, 1), th.released);
}

test "the part to be read-only once relocated: whole pages of it, when they are its own" {
    var buf: [fixture.SIZE]u8 = undefined;
    // All of the data segment: every page of it.
    {
        var b = fixture.Builder.init(&buf, .dynexec);
        b.selfModule("eboot", 0);
        b.relative(fixture.DATA, fixture.TEXT);
        b.relro = .{ .vaddr = fixture.DATA, .size = fixture.DATA_SIZE };
        var th = TestHost{};
        var modules: [1]Module = undefined;
        var libraries: [2]Name = undefined;
        var exports: [8]Export = undefined;
        var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
        const exe = try l.load("eboot.bin", b.finish());
        try l.link();
        const base = l.loaded()[exe].base;
        try std.testing.expectEqual(@as(u32, 1), th.read_only);
        try std.testing.expectEqual([2]u64{ base + fixture.DATA, fixture.DATA_SIZE }, th.read_only_range);
        // (and the relocation was written before it closed)
        try std.testing.expectEqual(base + fixture.TEXT, word(base + fixture.DATA));
    }
    // Its first quarter page only: the page has writable data too, and
    // stays as it is.
    {
        var b = fixture.Builder.init(&buf, .dynexec);
        b.selfModule("eboot", 0);
        b.relro = .{ .vaddr = fixture.DATA, .size = 0x1000 };
        var th = TestHost{};
        var modules: [1]Module = undefined;
        var libraries: [2]Name = undefined;
        var exports: [8]Export = undefined;
        var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
        _ = try l.load("eboot.bin", b.finish());
        try l.link();
        try std.testing.expectEqual(@as(u32, 0), th.read_only);
    }
}

test "a module's own symbols, a missing object, and relocations that say nothing" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .dynexec);
    b.selfModule("eboot", 0);
    const m = b.neededModule("libkernel", 1);
    const k = b.importLibrary("libkernel", 1);
    const object = b.importSymbol(nid.of("environ"), k, m, elf.STT_OBJECT);
    const function = b.importSymbol(nid.of("sceKernelNobodyHasThis"), k, m, elf.STT_FUNC);
    // The null symbol is the module's own address 0: with an addend, a
    // place in the module.
    b.absolute(fixture.DATA + 0x00, 0, 0x1234);
    b.globDat(fixture.DATA + 0x08, object);
    b.jumpSlot(fixture.DATA + 0x10, function);
    // (a relocation of no kind may name any place, even none of the file's)
    b.absolute(0xffff_ffff_0000, 0, 0);
    b.relas[b.rela_count - 1].info = elf.R.NONE;
    const file = b.finish();

    var th = TestHost{};
    var modules: [1]Module = undefined;
    var libraries: [2]Name = undefined;
    var exports: [8]Export = undefined;
    var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    const exe = try l.load("eboot.bin", file);
    try l.link();
    const base = l.loaded()[exe].base;
    try std.testing.expectEqual(base + 0x1234, word(base + fixture.DATA + 0x00));
    // An object's stand-in is not a function's: the host is told which.
    try std.testing.expectEqual(TestHost.OBJECT_STAND_IN, word(base + fixture.DATA + 0x08));
    try std.testing.expectEqual(TestHost.STAND_IN, word(base + fixture.DATA + 0x10));
    try std.testing.expectEqual(@as(u32, 1), th.objects_missing);
    try std.testing.expectEqual(@as(u32, 2), th.missing_asked);
}

test "a relocation that names a symbol the file does not have is refused" {
    var buf: [fixture.SIZE]u8 = undefined;
    var b = fixture.Builder.init(&buf, .dynexec);
    b.selfModule("eboot", 0);
    b.globDat(fixture.DATA, 999);
    var th = TestHost{};
    var modules: [1]Module = undefined;
    var libraries: [2]Name = undefined;
    var exports: [8]Export = undefined;
    var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    _ = try l.load("eboot.bin", b.finish());
    try std.testing.expectError(error.BadRelocation, l.link());
}

test "two modules with thread storage: each its own place below the thread pointer" {
    var exe_buf: [fixture.SIZE]u8 = undefined;
    var eb = fixture.Builder.init(&exe_buf, .dynexec);
    eb.selfModule("eboot", 0);
    eb.data = &([_]u8{0} ** 0x100 ++ [_]u8{ 1, 2, 3, 4 });
    eb.tls(fixture.DATA + 0x100, 4, 16, 16);
    // (no symbol: 4 bytes into this module's own block, from the thread pointer)
    eb.threadPointerOffset(fixture.DATA + 0x00, 0, 4);
    eb.tlsModule(fixture.DATA + 0x08);
    var lib_buf: [fixture.SIZE]u8 = undefined;
    var lb = fixture.Builder.init(&lib_buf, .module);
    lb.selfModule("libTest", 0);
    lb.data = &([_]u8{0} ** 0x108 ++ [_]u8{ 9, 9 });
    // (its first bytes are 8 past a multiple of its 32: so is its block)
    lb.tls(fixture.DATA + 0x108, 2, 40, 32);
    lb.tlsModule(fixture.DATA + 0x08);

    var th = TestHost{};
    var modules: [2]Module = undefined;
    var libraries: [2]Name = undefined;
    var exports: [8]Export = undefined;
    var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    const exe = try l.load("eboot.bin", eb.finish());
    const lib = try l.load("libTest.prx", lb.finish());
    try l.link();
    const e = l.loaded()[exe];
    const t = l.loaded()[lib];
    // The executable is first: its 16 bytes end at the thread pointer.
    try std.testing.expectEqual(@as(u64, 16), e.tls_offset);
    try std.testing.expectEqual(@as(u16, 1), e.tls_index);
    // The module's 40 bytes go under them, and down to where its block's
    // address is 8 past a multiple of 32, as its file's is: 16 + 40 = 56,
    // then 56 past a multiple of 32 is 24 short of 8 past one.
    try std.testing.expectEqual(@as(u16, 2), t.tls_index);
    try std.testing.expectEqual(@as(u64, 56), t.tls_offset);
    try std.testing.expectEqual(@as(u64, 8), (0 -% t.tls_offset) % 32);
    try std.testing.expectEqual(@as(u64, 64), l.staticTls().size);
    try std.testing.expectEqual(@as(u64, 32), l.staticTls().alignment);
    try std.testing.expectEqual(@as(i64, 4 - 16), @as(i64, @bitCast(word(e.base + fixture.DATA + 0x00))));
    try std.testing.expectEqual(@as(u64, 1), word(e.base + fixture.DATA + 0x08));
    try std.testing.expectEqual(@as(u64, 2), word(t.base + fixture.DATA + 0x08));

    var thread: [128]u8 align(32) = [_]u8{0x55} ** 128;
    const tp = @intFromPtr(&thread) + 96;
    l.initTls(tp);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, thread[80..84]); // the executable's, at tp - 16
    try std.testing.expect(std.mem.allEqual(u8, thread[84..96], 0));
    try std.testing.expectEqualSlices(u8, &.{ 9, 9 }, thread[40..42]); // the module's, at tp - 56
    try std.testing.expect(std.mem.allEqual(u8, thread[42..80], 0));
    try std.testing.expect(std.mem.allEqual(u8, thread[0..40], 0x55)); // (below them: nobody's)
}

// A whole program run for real: the hello fixture's code is the CPU's own,
// so on an x86-64 Linux host the test can load it into executable memory,
// bind its imports to functions here, and call its entry.
const Ran = struct {
    var text: [64]u8 = undefined;
    var text_len: usize = 0;
    var fd: c_int = -1;
    var exit_code: c_int = -1;
    var stand_in_calls: u32 = 0;

    fn write(to: c_int, bytes: [*]const u8, n: usize) callconv(.c) isize {
        fd = to;
        text_len = @min(n, text.len);
        @memcpy(text[0..text_len], bytes[0..text_len]);
        return @intCast(n);
    }
    fn exit(code: c_int) callconv(.c) void {
        exit_code = code;
    }
    fn standIn() callconv(.c) u64 {
        stand_in_calls += 1;
        return 0;
    }

    fn reserve(_: ?*anyopaque, want: u64, size: u64) ?u64 {
        if (want != 0) return null;
        const os = std.os.linux;
        // (Linux's pages are 4 KiB: a page more, and the first address in
        // it that is a multiple of the PS5's 16 KiB)
        const r = os.mmap(null, @intCast(size + elf.PAGE), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        return if (os.errno(r) != .SUCCESS) null else std.mem.alignForward(u64, r, elf.PAGE);
    }
    fn protect(_: ?*anyopaque, addr: u64, size: u64, read: bool, wr: bool, exec: bool) bool {
        const os = std.os.linux;
        const r = os.mprotect(@ptrFromInt(@as(usize, @intCast(addr))), @intCast(size), .{ .READ = read, .WRITE = wr, .EXEC = exec });
        return os.errno(r) == .SUCCESS;
    }
    fn builtin(_: ?*anyopaque, lib: []const u8, n: nid.Nid) ?u64 {
        if (!std.mem.eql(u8, lib, "libkernel")) return null;
        if (n == nid.of("write")) return @intFromPtr(&write);
        if (n == nid.of("_exit")) return @intFromPtr(&exit);
        return null;
    }
    fn missing(_: ?*anyopaque, _: Missing) ?u64 {
        return @intFromPtr(&standIn);
    }
};

test "a game and the module it brought: bound to each other, the module's start first" {
    const native = @import("builtin");
    if (native.cpu.arch != .x86_64 or native.os.tag != .linux) return error.SkipZigTest;
    Ran.text_len = 0;
    var exe_buf: [fixture.SIZE]u8 = undefined;
    var mod_buf: [fixture.SIZE]u8 = undefined;
    var modules: [4]Module = undefined;
    var names: [8]Name = undefined;
    var table: [64]Export = undefined;
    var l = Linker.init(.{ .reserve = Ran.reserve, .protect = Ran.protect, .builtin = Ran.builtin, .missing = Ran.missing }, .{ .modules = &modules, .libraries = &names, .exports = &table });
    const exe = try l.load("eboot.bin", fixture.game(&exe_buf, "the game\n"));
    const mod = try l.load("libGame.prx", fixture.gameModule(&mod_buf, "its module\n"));
    try l.link();
    try std.testing.expectEqualStrings("libGame", l.loaded()[mod].name.slice());
    try std.testing.expectEqualStrings("libGame.prx", l.loaded()[mod].file.slice());
    // The executable says it needs the module, and found it.
    try std.testing.expectEqual(@as(u64, 1) << @intCast(mod), l.loaded()[exe].needs);
    try std.testing.expectEqual(@as(u32, 1), l.stats.from_modules);
    try std.testing.expectEqual(@as(u32, 0), l.stats.stand_ins);
    const m = l.loaded()[mod];
    // Its call into the module goes to the module's function.
    try std.testing.expectEqual(m.base + fixture.GAME_ANSWER_AT, word(l.loaded()[exe].base + fixture.DATA + 0x10));
    // The module's variable is found from the thread pointer.
    try std.testing.expectEqual(0 -% m.tls_offset, word(m.base + fixture.GAME_TPOFF_AT));
    try std.testing.expectEqual(m.base + fixture.GAME_ANSWER_AT, l.lookupIn(mod, nid.of(fixture.GAME_SYMBOL)).?.addr);
    try std.testing.expect(l.lookupIn(exe, nid.of(fixture.GAME_SYMBOL)) == null);

    // What is to be started: the module, not the program; and once.
    var order: [4]u16 = undefined;
    const todo = l.startOrder(&order);
    try std.testing.expectEqualSlices(u16, &.{mod}, todo);
    try std.testing.expectEqual(@as(usize, 0), l.startOrder(&order).len);
    // Its start function, run: it prints through its own import and
    // leaves its mark where its other function reads it.
    const start: *const fn (usize, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int = @ptrFromInt(@as(usize, @intCast(m.init)));
    try std.testing.expectEqual(@as(c_int, 0), start(0, null, null));
    try std.testing.expectEqualStrings("its module\n", Ran.text[0..Ran.text_len]);
    // (it answers with the argument it was given)
    try std.testing.expectEqual(@as(c_int, 7), start(7, null, null));
    try std.testing.expectEqual(fixture.GAME_STARTED, @as(*const u32, @ptrFromInt(@as(usize, @intCast(m.base + fixture.GAME_STARTED_AT)))).*);
}

test "modules are started after the modules they need" {
    var t = TestHost{};
    var bufs: [3][fixture.SIZE]u8 = undefined;
    var modules: [4]Module = undefined;
    var names: [8]Name = undefined;
    var table: [64]Export = undefined;
    var l = Linker.init(t.host(), .{ .modules = &modules, .libraries = &names, .exports = &table });
    // Loaded in the order a, b, c; a needs c, c needs b, and b needs a
    // back (a ring a real set of modules can have).
    const needs = [3][]const u8{ "libC", "libA", "libB" };
    const own = [3][]const u8{ "libA", "libB", "libC" };
    for (0..3) |i| {
        var b = fixture.Builder.init(&bufs[i], .module);
        b.selfModule(own[i], 0);
        _ = b.neededModule(needs[i], 1);
        b.init_at = fixture.TEXT;
        _ = try l.load(own[i], b.finish());
    }
    try l.link();
    var order: [4]u16 = undefined;
    // a wants c first, c wants b first, b wants a, which is already being
    // placed: so b, then c, then a.
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 0 }, l.startOrder(&order));
    try std.testing.expectEqual(@as(usize, 0), l.startOrder(&order).len);
}

test "a module whose thread storage would not fit the threads there are is not loaded" {
    var t = TestHost{};
    var buf: [fixture.SIZE]u8 = undefined;
    var modules: [2]Module = undefined;
    var names: [4]Name = undefined;
    var table: [16]Export = undefined;
    var l = Linker.init(t.host(), .{ .modules = &modules, .libraries = &names, .exports = &table });
    l.tls_limit = 32;
    var b = fixture.Builder.init(&buf, .module);
    b.selfModule("libBig", 0);
    b.tls(fixture.DATA + 0x100, 0, 64, 8);
    try std.testing.expectError(error.NoSpace, l.load("libBig.prx", b.finish()));
    try std.testing.expectEqual(@as(usize, 0), l.loaded().len);
    // (nothing was reserved for it)
    try std.testing.expectEqual(@as(u32, 0), t.released);
    l.tls_limit = 64;
    _ = try l.load("libBig.prx", b.finish());
}

test "a module whose link failed is left out of every later one" {
    var t = TestHost{};
    t.refuse_missing = true;
    var bufs: [2][fixture.SIZE]u8 = undefined;
    var modules: [2]Module = undefined;
    var names: [4]Name = undefined;
    var table: [16]Export = undefined;
    var l = Linker.init(t.host(), .{ .modules = &modules, .libraries = &names, .exports = &table });
    // It exports a function, and wants one nobody has.
    var bad = fixture.Builder.init(&bufs[0], .module);
    bad.selfModule("libBad", 0);
    const own = bad.exportLibrary("libBad", 1);
    _ = bad.exportSymbol(nid.of("badThing"), own, 0, fixture.TEXT + 0x10, elf.STT_FUNC);
    const nm = bad.neededModule("libNone", 1);
    const nl = bad.importLibrary("libNone", 2);
    bad.jumpSlot(fixture.DATA, bad.importSymbol(nid.of("nothingHasThis"), nl, nm, elf.STT_FUNC));
    bad.init_at = fixture.TEXT;
    const index = try l.load("libBad.prx", bad.finish());
    try std.testing.expect(l.lookup("libBad", nid.of("badThing")) != null);
    try std.testing.expectError(error.Unresolved, l.link());
    try std.testing.expectEqual(index, l.failed);
    l.abandon(index);
    // Abandoned, it provides nothing: not by its library, not when asked itself.
    try std.testing.expect(l.lookup("libBad", nid.of("badThing")) == null);
    try std.testing.expect(l.lookupIn(index, nid.of("badThing")) == null);
    // A good one after it, which imports what the bad one exported: it
    // links, to a stand-in and not into the abandoned module; and only
    // the good one is started.
    t.refuse_missing = false;
    var good = fixture.Builder.init(&bufs[1], .module);
    good.selfModule("libGood", 0);
    const bm = good.neededModule("libBad", 1);
    const bl = good.importLibrary("libBad", 1);
    good.jumpSlot(fixture.DATA, good.importSymbol(nid.of("badThing"), bl, bm, elf.STT_FUNC));
    good.init_at = fixture.TEXT;
    const second = try l.load("libGood.prx", good.finish());
    try l.link();
    try std.testing.expectEqual(Linker.NO_MODULE, l.failed);
    try std.testing.expectEqual(TestHost.STAND_IN, word(l.loaded()[second].base + fixture.DATA));
    try std.testing.expectEqual(@as(u64, 0), l.loaded()[second].needs);
    var order: [2]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{second}, l.startOrder(&order));
}

test "two modules export one name: the first one's is found, and each can be asked for its own" {
    var t = TestHost{};
    var bufs: [3][fixture.SIZE]u8 = undefined;
    var modules: [3]Module = undefined;
    var names: [4]Name = undefined;
    var table: [16]Export = undefined;
    var l = Linker.init(t.host(), .{ .modules = &modules, .libraries = &names, .exports = &table });
    var index: [2]u16 = undefined;
    for (0..2) |i| {
        var b = fixture.Builder.init(&bufs[i], .module);
        b.selfModule(if (i == 0) "libFirst" else "libSecond", 0);
        const lib = b.exportLibrary("libShared", 1);
        _ = b.exportSymbol(nid.of("sharedName"), lib, 0, fixture.TEXT + 0x10 * (@as(u64, i) + 1), elf.STT_FUNC);
        index[i] = try l.load(if (i == 0) "first.prx" else "second.prx", b.finish());
    }
    try l.link();
    const first = l.loaded()[index[0]];
    const second = l.loaded()[index[1]];
    try std.testing.expectEqual(first.base + fixture.TEXT + 0x10, l.lookup("libShared", nid.of("sharedName")).?.addr);
    try std.testing.expectEqual(first.base + fixture.TEXT + 0x10, l.lookupIn(index[0], nid.of("sharedName")).?.addr);
    try std.testing.expectEqual(second.base + fixture.TEXT + 0x20, l.lookupIn(index[1], nid.of("sharedName")).?.addr);
    // With the first given up, the second one's is what there is.
    l.abandon(index[0]);
    try std.testing.expectEqual(second.base + fixture.TEXT + 0x20, l.lookup("libShared", nid.of("sharedName")).?.addr);
}

test "the hello program, loaded and run: it prints through its imports and exits" {
    const native = @import("builtin");
    if (native.cpu.arch != .x86_64 or native.os.tag != .linux) return error.SkipZigTest;

    var buf: [fixture.SIZE]u8 = undefined;
    const file = fixture.hello(&buf, "hello from a PS5 program\n");
    var modules: [2]Module = undefined;
    var libraries: [4]Name = undefined;
    var exports: [16]Export = undefined;
    var l = Linker.init(.{ .reserve = Ran.reserve, .protect = Ran.protect, .builtin = Ran.builtin, .missing = Ran.missing }, .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    const exe = try l.load("eboot.bin", file);
    try l.link();
    try std.testing.expectEqual(@as(u32, 2), l.stats.from_host);
    try std.testing.expectEqual(@as(u32, 1), l.stats.stand_ins);

    const entry: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrFromInt(@as(usize, @intCast(l.loaded()[exe].entry)));
    entry(null, null);
    try std.testing.expectEqual(@as(c_int, 1), Ran.fd);
    try std.testing.expectEqualStrings("hello from a PS5 program\n", Ran.text[0..Ran.text_len]);
    try std.testing.expectEqual(@as(u32, 1), Ran.stand_in_calls);
    try std.testing.expectEqual(@as(c_int, 0), Ran.exit_code);
}
