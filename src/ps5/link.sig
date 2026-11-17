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
//!          modules' start functions and jumps to the executable.
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

/// What the linker asks of where it runs.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// `size` bytes of zeroed, writable memory at a multiple of the page
    /// (at `want` when not 0: a fixed-address executable); null to refuse.
    reserve: *const fn (ctx: ?*anyopaque, want: u64, size: u64) ?u64,
    /// The final protection of whole pages of a module.
    protect: *const fn (ctx: ?*anyopaque, addr: u64, size: u64, read: bool, write: bool, exec: bool) bool,
    /// A symbol of one of the host's own libraries, or null.
    builtin: *const fn (ctx: ?*anyopaque, library: []const u8, n: nid.Nid) ?u64 = noBuiltin,
    /// What to bind an import nobody has to, or null to fail the link.
    missing: *const fn (ctx: ?*anyopaque, library: []const u8, module: []const u8, n: nid.Nid) ?u64 = noStandIn,

    fn noBuiltin(_: ?*anyopaque, _: []const u8, _: nid.Nid) ?u64 {
        return null;
    }
    fn noStandIn(_: ?*anyopaque, _: []const u8, _: []const u8, _: nid.Nid) ?u64 {
        return null;
    }
};

pub const NAME_MAX = 47;

const Name = struct {
    bytes: [NAME_MAX]u8 = undefined,
    len: u8 = 0,

    fn of(s: []const u8) Name {
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
    name: Name = .{},
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
    /// The file, until the module is linked (the caller keeps its bytes
    /// until then).
    image: elf.Image = undefined,
    linked: bool = false,
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
    /// How much was bound where (for a log line).
    stats: Stats = .{},

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
        const start = l.host.reserve(l.host.ctx, if (fixed) im.lo else 0, im.span()) orelse return error.NoSpace;
        if (start % elf.PAGE != 0 or (fixed and start != im.lo)) return error.NoSpace;
        const base = start -% im.lo;
        for (im.segments()) |s| {
            const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(base +% s.vaddr)));
            @memcpy(dst[0..@intCast(s.filesz)], bytes[@intCast(s.offset)..][0..@intCast(s.filesz)]);
        }
        const index = l.module_count;
        const m = &l.modules[index];
        m.* = .{
            .name = Name.of(im.moduleName() orelse name),
            .kind = im.kind,
            .base = base,
            .start = start,
            .size = im.span(),
            .entry = if (im.entry != 0) base +% im.entry else 0,
            .init = if (im.init != 0) base +% im.init else 0,
            .fini = if (im.fini != 0) base +% im.fini else 0,
            .proc_param = if (im.proc_param) |r| base +% r.vaddr else 0,
            .module_param = if (im.module_param) |r| base +% r.vaddr else 0,
            .eh_frame_hdr = if (im.eh_frame_hdr) |r| base +% r.vaddr else 0,
            .eh_frame_hdr_size = if (im.eh_frame_hdr) |r| r.size else 0,
            .image = im,
        };
        if (im.tls) |t| {
            // (FreeBSD's layout: each block ends where the one before
            // began, aligned; the offset is from the thread pointer down)
            l.tls_size = std.mem.alignForward(u64, l.tls_size + t.memsz, t.alignment);
            l.tls_align = @max(l.tls_align, t.alignment);
            m.tls_index = l.nextTlsIndex();
            m.tls_image = base +% t.vaddr;
            m.tls_filesz = t.filesz;
            m.tls_memsz = t.memsz;
            m.tls_offset = l.tls_size;
        }
        l.module_count += 1;
        errdefer l.module_count -= 1;
        try l.enterExports(index);
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
    fn exported(im: *const elf.Image, s: elf.Sym) ?elf.Image.Linked {
        if (!s.defined() or s.bind() == elf.STB_LOCAL or !s.visible()) return null;
        // (a definition outside the module is not one)
        if (s.kind() != elf.STT_TLS and !im.covered(s.value, 0)) return null;
        return im.linked(s);
    }

    fn enterExports(l: *Linker, index: u16) Error!void {
        const m = &l.modules[index];
        const im = &m.image;
        // Room for all of them first (and their libraries' names): a
        // module's exports go in whole or not at all.
        var libs = im.names(.export_library);
        while (libs.next()) |n| _ = try l.library(n.name);
        var count: usize = 0;
        for (im.symtab) |s| {
            if (exported(im, s) != null) count += 1;
        }
        if ((l.export_count + count) * 4 > l.exports.len * 3) return error.TableFull;
        for (im.symtab) |s| {
            const info = exported(im, s) orelse continue;
            const is_tls = s.kind() == elf.STT_TLS;
            const lib = l.knownLibrary(info.library);
            const mask = l.exports.len - 1;
            var at: usize = @as(usize, @truncate(info.nid)) & mask;
            var taken = false;
            while (l.exports[at].library != 0) : (at = (at + 1) & mask) {
                // (the first module to export a name keeps it)
                if (l.exports[at].nid == info.nid and l.exports[at].library == lib) {
                    taken = true;
                    break;
                }
            }
            if (taken) continue;
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

    /// A loaded module's export, by its library's name and NID.
    pub fn lookup(l: *const Linker, lib_name: []const u8, n: nid.Nid) ?Export {
        const lib = l.knownLibrary(lib_name);
        if (lib == 0) return null;
        const mask = l.exports.len - 1;
        var at: usize = @as(usize, @truncate(n)) & mask;
        while (l.exports[at].library != 0) : (at = (at + 1) & mask) {
            if (l.exports[at].nid == n and l.exports[at].library == lib) return l.exports[at];
        }
        return null;
    }

    /// Binds every module loaded since the last link, then gives each its
    /// final protections.
    pub fn link(l: *Linker) Error!void {
        for (l.modules[0..l.module_count], 0..) |*m, i| {
            if (m.linked) continue;
            try l.relocate(@intCast(i), m.image.rela);
            try l.relocate(@intCast(i), m.image.jmprel);
        }
        for (l.modules[0..l.module_count]) |*m| {
            if (m.linked) continue;
            try l.protect(m);
            m.linked = true;
            m.image.bytes = &.{}; // (the file may go now)
        }
    }

    const Target = struct { value: u64, module: u16, tls: bool };

    fn relocate(l: *Linker, index: u16, relas: []align(1) const elf.Rela) Error!void {
        const m = &l.modules[index];
        const im = &m.image;
        for (relas) |r| {
            if (!im.covered(r.offset, 8)) return error.BadRelocation;
            const where: *align(1) u64 = @ptrFromInt(@as(usize, @intCast(m.base +% r.offset)));
            const addend: u64 = @bitCast(r.addend);
            switch (r.kind()) {
                elf.R.NONE => {},
                elf.R.RELATIVE => where.* = m.base +% addend,
                elf.R.@"64" => where.* = (try l.resolve(index, r.sym())).value +% addend,
                elf.R.GLOB_DAT, elf.R.JUMP_SLOT => where.* = (try l.resolve(index, r.sym())).value,
                elf.R.DTPMOD64 => where.* = if (r.sym() == 0) m.tls_index else l.modules[(try l.resolve(index, r.sym())).module].tls_index,
                elf.R.DTPOFF64 => where.* = (if (r.sym() == 0) 0 else (try l.resolveTls(index, r.sym())).value) +% addend,
                elf.R.TPOFF64 => {
                    // (below the thread pointer: the symbol's place in its
                    // module's block, less where that block starts)
                    const t: Target = if (r.sym() == 0) .{ .value = 0, .module = index, .tls = true } else try l.resolveTls(index, r.sym());
                    where.* = t.value +% addend -% l.modules[t.module].tls_offset;
                },
                else => return error.BadRelocation,
            }
            l.stats.relocations += 1;
        }
    }

    fn resolveTls(l: *Linker, index: u16, sym_index: u32) Error!Target {
        const t = try l.resolve(index, sym_index);
        if (!t.tls) return error.BadRelocation;
        return t;
    }

    /// What a symbol of module `index` stands for: its own definition, or
    /// whoever provides the import.
    fn resolve(l: *Linker, index: u16, sym_index: u32) Error!Target {
        const m = &l.modules[index];
        const im = &m.image;
        if (sym_index >= im.symtab.len) return error.BadRelocation;
        const s = im.symtab[sym_index];
        const is_tls = s.kind() == elf.STT_TLS;
        if (s.defined()) return .{ .value = if (is_tls) s.value else m.base +% s.value, .module = index, .tls = is_tls };
        const weak = s.bind() == elf.STB_WEAK;
        const info = im.linked(s) orelse {
            if (!weak) return error.Unresolved;
            l.stats.weak_absent += 1;
            return .{ .value = 0, .module = index, .tls = false };
        };
        if (l.lookup(info.library, info.nid)) |e| {
            l.stats.from_modules += 1;
            return .{ .value = e.addr, .module = e.module, .tls = e.tls };
        }
        if (l.host.builtin(l.host.ctx, info.library, info.nid)) |addr| {
            l.stats.from_host += 1;
            return .{ .value = addr, .module = index, .tls = false };
        }
        if (weak) {
            l.stats.weak_absent += 1;
            return .{ .value = 0, .module = index, .tls = false };
        }
        const addr = l.host.missing(l.host.ctx, info.library, info.module, info.nid) orelse return error.Unresolved;
        l.stats.stand_ins += 1;
        return .{ .value = addr, .module = index, .tls = false };
    }

    /// Each segment as its file asks, and the relocated read-only part
    /// read-only (whole pages of it: what shares a page with writable data
    /// stays writable).
    fn protect(l: *Linker, m: *const Module) Error!void {
        const im = &m.image;
        for (im.segments()) |s| {
            const lo = std.mem.alignBackward(u64, s.vaddr, elf.PAGE);
            const hi = std.mem.alignForward(u64, s.end(), elf.PAGE);
            if (!l.host.protect(l.host.ctx, m.base +% lo, hi - lo, s.read or s.exec, s.write, s.exec)) return error.Protect;
        }
        if (im.relro) |r| {
            const lo = std.mem.alignForward(u64, r.vaddr, elf.PAGE);
            const hi = std.mem.alignBackward(u64, r.vaddr + r.size, elf.PAGE);
            if (hi > lo and !l.host.protect(l.host.ctx, m.base +% lo, hi - lo, true, false, false)) return error.Protect;
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
        for (l.loaded()) |m| {
            if (m.tls_index == 0) continue;
            const block: [*]u8 = @ptrFromInt(@as(usize, @intCast(tp - m.tls_offset)));
            const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(m.tls_image)));
            @memcpy(block[0..@intCast(m.tls_filesz)], src[0..@intCast(m.tls_filesz)]);
            @memset(block[@intCast(m.tls_filesz)..@intCast(m.tls_memsz)], 0);
        }
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
    executable: u32 = 0,
    missing_asked: u32 = 0,

    const USLEEP: u64 = 0x1111_0000;
    const STAND_IN: u64 = 0x2222_0000;

    fn host(t: *TestHost) Host {
        return .{ .ctx = t, .reserve = reserve, .protect = protect, .builtin = builtin, .missing = missing };
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
        if (read and !write and !exec) t.read_only += 1;
        if (exec) t.executable += 1;
        return true;
    }
    fn builtin(_: ?*anyopaque, lib: []const u8, n: nid.Nid) ?u64 {
        if (std.mem.eql(u8, lib, "libkernel") and n == nid.of("sceKernelUsleep")) return USLEEP;
        return null;
    }
    fn missing(ctx: ?*anyopaque, _: []const u8, _: []const u8, _: nid.Nid) ?u64 {
        const t: *TestHost = @ptrCast(@alignCast(ctx.?));
        t.missing_asked += 1;
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
    const file = b.finish();

    var th = TestHost{};
    var modules: [1]Module = undefined;
    var libraries: [4]Name = undefined;
    var exports: [4]Export = undefined; // (full at three of four)
    var l = Linker.init(th.host(), .{ .modules = &modules, .libraries = &libraries, .exports = &exports });
    try std.testing.expectError(error.TableFull, l.load("libTest.prx", file));
    try std.testing.expectEqual(@as(usize, 0), l.loaded().len);
    // (and none of its exports went in)
    try std.testing.expectEqual(@as(u32, 0), l.export_count);
    try std.testing.expect(l.lookup("libTest", nid.of("a")) == null);
}
