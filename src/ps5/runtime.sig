//! @zpm/ps5 runtime — what stands between a kernel that speaks the PS5's
//! ABI and a game: the program the kernel starts for a PS5 executable. It
//! does what the console's libkernel does before a game's first
//! instruction, in the game's own process:
//!
//!   1. maps the executable's file, and the modules the game brought with
//!      it (`sce_module/*.prx` beside it), and gives them to the linker
//!      (link.sig), which copies them in and binds their imports: to each
//!      other, to this runtime's libkernel (libkernel.sig), or, for a
//!      symbol nobody has yet, to a stand-in that says which one when the
//!      game calls it;
//!   2. makes the first thread's control block and thread storage and
//!      points FS at it;
//!   3. switches to a stack of the game's, runs each module's start
//!      function (a module after the modules it needs), and jumps to the
//!      executable's entry, with the argument block and the clean-up
//!      function its start code expects.
//!
//! While the game runs it loads the modules the game asks for by path
//! (`sceKernelLoadStartModule`) the same way.
//!
//! From there the game runs as itself: its code is the CPU's own, its
//! system calls are the kernel's, and what it imports is ordinary code in
//! the same address space. Nothing is translated or rewritten on disk.
//!
//! `start` is the whole of it: a host's `_start` hands it FreeBSD's
//! argument block (argv[1] is the executable).
//!
//! Not here yet: every library but libkernel, and the console's own system
//! modules (a game names them; nothing loads them).
//!
//! x86-64 only. Allocation-free: the linker's tables and the stand-ins are
//! static; memory for the game comes from the kernel by mmap.

const std = @import("std");
const sys = @import("sys.sig");
const abi = @import("abi.sig");
const nid = @import("nid.sig");
const elf = @import("elf.sig");
const link = @import("link.sig");
const libkernel = @import("libkernel.sig");
const pthread = @import("pthread.sig");
const videoout = @import("videoout.sig");
const agcdriver = @import("agcdriver.sig");

const S = abi.Sys;
const RW = abi.PROT.READ | abi.PROT.WRITE;
const NO_FD: u64 = ~@as(u64, 0);

// ── Saying things ───────────────────────────────────────────────────────────

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [384]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "[ps5] " ++ fmt ++ "\n", args) catch "[ps5] (a message too long to print)\n";
    _ = sys.call(S.write, 2, @intFromPtr(text.ptr), text.len, 0, 0, 0);
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    say(fmt, args);
    _ = sys.call(S.exit, code, 0, 0, 0, 0, 0);
    while (true) {}
}

// ── Stand-ins for what nobody provides ──────────────────────────────────────

/// One per import nobody has: a few bytes of code that load its number and
/// jump to `ps5_runtime_missing`, which says the import's name (once) and
/// returns 0 to the game. A game that only passes through such a call
/// carries on; the log says what it wanted.
pub const Stubs = struct {
    /// Bytes of one stand-in; the first slot of each page holds the
    /// address they all jump through.
    pub const SIZE = 16;
    /// Stand-ins in a page. A page is written, then made code for good
    /// (`seal`), and stand-ins made after that start a new one, so no
    /// page a thread may be running in is ever writable again. A page
    /// may so be left part empty: a module loaded while the game runs
    /// that wants one thing nobody has takes a page for it.
    pub const PER_PAGE: u32 = @intCast(abi.PAGE / SIZE - 1);
    /// The most stand-ins there may be (each has a record here), and the
    /// most pages they may be in (each costs a word here until it is
    /// used). A stand-in's number is its record's, not its place in the
    /// pages, so a page left part empty uses up no records.
    pub const MAX = 16384;
    pub const PAGES = 2048;

    const Info = struct {
        nid: nid.Nid = 0,
        library: link.Name = .{},
        /// Where its code is.
        addr: u64 = 0,
        said: bool = false,
    };

    var pages: [PAGES]u64 = [_]u64{0} ** PAGES;
    /// Stand-ins made.
    var count: u32 = 0;
    /// Places used or passed over in the pages, and the pages that are
    /// code already.
    var places: u32 = 0;
    var sealed_pages: u32 = 0;
    var info: [MAX]Info = [_]Info{.{}} ** MAX;

    /// Where place `n` is: its page, and its bytes from the page's start.
    pub fn where(n: u32) struct { page: u32, offset: u64 } {
        return .{ .page = n / PER_PAGE, .offset = SIZE * (@as(u64, n % PER_PAGE) + 1) };
    }

    /// The first place of the first page not begun at place `n`.
    pub fn nextPage(n: u32) u32 {
        return (n + PER_PAGE - 1) / PER_PAGE * PER_PAGE;
    }

    /// The machine code of stand-in `index`, at `at`, jumping through the
    /// address stored at `through`:
    ///   mov eax, index        B8 imm32
    ///   jmp [rip + disp]      FF 25 disp32
    pub fn encode(out: *[SIZE]u8, index: u32, at: u64, through: u64) void {
        @memset(out, 0xcc);
        out[0] = 0xb8;
        std.mem.writeInt(u32, out[1..5], index, .little);
        out[5] = 0xff;
        out[6] = 0x25;
        const disp: i64 = @as(i64, @bitCast(through)) - @as(i64, @bitCast(at + 11));
        std.mem.writeInt(i32, out[7..11], @intCast(disp), .little);
    }

    fn make(library: []const u8, n: nid.Nid) ?u64 {
        // (the same import of several modules: one stand-in)
        for (info[0..count]) |*i| {
            if (i.nid == n and std.mem.eql(u8, i.library.slice(), library[0..@min(library.len, link.NAME_MAX)])) return i.addr;
        }
        const w = where(places);
        if (count == MAX or w.page >= PAGES) return null;
        const page = &pages[w.page];
        if (page.* == 0) {
            const r = sys.call(S.mmap, 0, abi.PAGE, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
            if (r < 0) return null;
            page.* = @intCast(r);
            @as(*u64, @ptrFromInt(@as(usize, @intCast(page.*)))).* = @intFromPtr(&ps5_runtime_missing);
        }
        const at = page.* + w.offset;
        const index = count;
        encode(@ptrFromInt(@as(usize, @intCast(at))), index, at, page.*);
        info[index] = .{ .nid = n, .library = link.Name.of(library), .addr = at };
        // (its record first, then the count that makes it findable: the
        // routine a stand-in jumps to reads both with no lock)
        @atomicStore(u32, &count, index + 1, .release);
        places += 1;
        return at;
    }

    /// The stand-ins made since the last time become code (no longer
    /// writable), and the next one made starts a page of its own. False
    /// when the kernel would not allow it: they could then not be called.
    fn seal() bool {
        const end = nextPage(places) / PER_PAGE;
        var page = sealed_pages;
        while (page < end) : (page += 1) {
            if (sys.call(S.mprotect, pages[page], abi.PAGE, abi.PROT.READ | abi.PROT.EXEC, 0, 0, 0) != 0) return false;
        }
        sealed_pages = end;
        places = end * PER_PAGE;
        return true;
    }
};

/// Memory for an imported object nothing provides. A stand-in for a
/// function is code; a program reads and writes an object, so its stand-in
/// is zeroed memory of its own, and the log says so when it is bound
/// (nothing calls it, so nothing could say so later).
const Objects = struct {
    const BYTES: u64 = 1 << 20;
    /// One object's most; a bigger one fails the link.
    const ONE_MAX: u64 = 64 << 10;
    /// Lines the log gets before only the count goes on.
    const SAID_MAX = 16;

    /// The ones made (as many as are remembered: a name asked for again,
    /// by another module or by a link run a second time, gets the same
    /// memory and no second line in the log).
    const Made = struct { nid: nid.Nid, library: u64, addr: u64 };

    var base: u64 = 0;
    var used: u64 = 0;
    var count: u32 = 0;
    var made: [2048]Made = undefined;

    fn make(what: link.Missing) ?u64 {
        if (what.size > ONE_MAX) return null;
        const library = nameHash(what.library);
        for (made[0..@min(count, made.len)]) |m| {
            if (m.nid == what.nid and m.library == library) return m.addr;
        }
        if (base == 0) {
            const r = sys.call(S.mmap, 0, BYTES, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
            if (r < 0) return null;
            base = @intCast(r);
        }
        const size = std.mem.alignForward(u64, @max(what.size, 8), 16);
        if (size > BYTES - used) return null;
        const at = base + used;
        used += size;
        if (count < made.len) made[count] = .{ .nid = what.nid, .library = library, .addr = at };
        count += 1;
        if (count <= SAID_MAX) say("not provided: the object {s}:{s} ({d} bytes): it reads as zeroes", .{ what.library, nid.text(what.nid), what.size });
        return at;
    }
};

/// A name or a path as one number (FNV-1a), for telling two apart.
pub fn nameHash(text: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (text) |c| h = (h ^ c) *% 0x0000_0100_0000_01b3;
    return h;
}

extern fn ps5_runtime_missing() callconv(.c) void;

comptime {
    // A stand-in arrives here with its number in eax, as a function that
    // was called: the stack is as after a call.
    asm (
        \\ .text
        \\ .p2align 4
        \\ .global ps5_runtime_missing
        \\ ps5_runtime_missing:
        \\   sub $8, %rsp
        \\   mov %eax, %edi
        \\   call ps5RuntimeMissing
        \\   add $8, %rsp
        \\   xor %eax, %eax
        \\   ret
    );
}

export fn ps5RuntimeMissing(index: u32) callconv(.c) void {
    if (index >= @atomicLoad(u32, &Stubs.count, .acquire)) return;
    const i = &Stubs.info[index];
    if (@atomicRmw(bool, &i.said, .Xchg, true, .monotonic)) return;
    say("not implemented: {s}:{s} was called (it answers 0)", .{ i.library.slice(), nid.text(i.nid) });
}

// ── The linker's host ───────────────────────────────────────────────────────

const MODULES = 64;

var modules: [MODULES]link.Module = undefined;
var libraries: [512]link.Name = undefined;
var exports: [1 << 16]link.Export = undefined;
var linker: link.Linker = undefined;

/// The linker's tables are one thread's at a time (a game's threads may
/// each ask for a module).
var linker_lock: pthread.Lock = .{};

fn reserve(_: ?*anyopaque, want: u64, size: u64) ?u64 {
    const fixed: u64 = if (want != 0) abi.MAP.FIXED | abi.MAP.NO_OVERWRITE else 0;
    const r = sys.call(S.mmap, want, size, RW, abi.MAP.ANON | abi.MAP.PRIVATE | fixed, NO_FD, 0);
    return if (r < 0) null else @intCast(r);
}

fn protect(_: ?*anyopaque, addr: u64, size: u64, read: bool, write: bool, exec: bool) bool {
    var prot: u64 = 0;
    if (read) prot |= abi.PROT.READ;
    if (write) prot |= abi.PROT.WRITE;
    if (exec) prot |= abi.PROT.EXEC;
    return sys.call(S.mprotect, addr, size, prot, 0, 0, 0) == 0;
}

fn builtin(_: ?*anyopaque, library: []const u8, n: nid.Nid) ?u64 {
    if (libkernel.find(library, n)) |addr| return addr;
    if (videoout.find(library, n)) |addr| return addr;
    if (agcdriver.find(library, n)) |addr| return addr;
    for (providers[0..provider_count]) |f| {
        if (f(library, n)) |addr| return addr;
    }
    return null;
}

/// A library the runtime's host brings besides the ones here (the GPU
/// path, which needs the host's own graphics code): a library's name and
/// a NID in, the function's address out, or null.
pub const Provider = *const fn (library: []const u8, n: nid.Nid) ?u64;

var providers: [8]Provider = undefined;
var provider_count: usize = 0;

/// Adds a library provider. Call before `start` or `standalone`.
pub fn provide(f: Provider) void {
    if (provider_count == providers.len) return;
    providers[provider_count] = f;
    provider_count += 1;
}

fn release(_: ?*anyopaque, addr: u64, size: u64) void {
    _ = sys.call(S.munmap, addr, size, 0, 0, 0, 0);
}

fn missing(_: ?*anyopaque, what: link.Missing) ?u64 {
    return switch (what.kind) {
        .function, .other => Stubs.make(what.library, what.nid),
        .object => Objects.make(what),
    };
}

/// Where each module's thread storage is below a thread pointer, by its
/// thread storage index (`__tls_get_addr` is called often: one load, no
/// search).
var tls_offsets: [MODULES + 1]u64 = [_]u64{0} ** (MODULES + 1);

fn noteTls() void {
    for (linker.loaded()) |*m| {
        if (m.tls_index != 0 and m.tls_index < tls_offsets.len) @atomicStore(u64, &tls_offsets[m.tls_index], m.tls_offset, .release);
    }
}

fn tlsAddress(module: u64, offset: u64) callconv(.c) usize {
    if (module == 0 or module >= tls_offsets.len) return 0;
    const below = @atomicLoad(u64, &tls_offsets[@intCast(module)], .acquire);
    if (below == 0) return 0;
    return @intCast(sys.fs0() -% below +% offset);
}

/// Room below every thread pointer for the thread storage of modules
/// loaded after the threads were made.
const TLS_SPARE: u64 = 1 << 20;

fn fillTls(tp: u64) void {
    linker.initTls(tp);
}

// ── Files ───────────────────────────────────────────────────────────────────

/// A whole file, mapped to read. Null when it cannot be opened or mapped.
fn mapFile(path: [*:0]const u8) ?[]const u8 {
    const fd = sys.call(S.open, @intFromPtr(path), 0, 0, 0, 0, 0);
    if (fd < 0) return null;
    defer _ = sys.call(S.close, @intCast(fd), 0, 0, 0, 0, 0);
    var st: abi.Stat = undefined;
    if (sys.call(S.fstat, @intCast(fd), @intFromPtr(&st), 0, 0, 0, 0) != 0 or st.size <= 0) return null;
    const size: u64 = @intCast(st.size);
    const r = sys.call(S.mmap, 0, size, abi.PROT.READ, abi.MAP.PRIVATE, @intCast(fd), 0);
    if (r < 0) return null;
    return @as([*]const u8, @ptrFromInt(@as(usize, @intCast(r))))[0..@intCast(size)];
}

// ── The first thread ────────────────────────────────────────────────────────

var main_thread: libkernel.Thread = .{};

/// The first thread's storage and control block: every module's block
/// below the thread pointer (and room for modules to come), the control
/// block at it. From here on the thread library makes every other
/// thread's the same way. Null when there is no memory for it.
fn firstThread(stack_addr: u64, stack_size: u64) ?u64 {
    const st = linker.staticTls();
    if (st.alignment > abi.PAGE) return null;
    const capacity = std.mem.alignForward(u64, st.size + TLS_SPARE, abi.PAGE);
    linker.tls_limit = capacity;
    pthread.tls_capacity = capacity;
    pthread.tls_init = fillTls;
    const r = sys.call(S.mmap, 0, capacity + abi.PAGE, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
    if (r < 0) return null;
    const tp: u64 = @as(u64, @intCast(r)) + capacity;
    linker.initTls(tp);
    noteTls();
    pthread.adoptFirst(&main_thread, tp, stack_addr, stack_size);
    const tcb: *libkernel.Tcb = @ptrFromInt(@as(usize, @intCast(tp)));
    tcb.* = .{ .self = tp, .thread = @intFromPtr(&main_thread) };
    var base = tp;
    if (sys.call(S.sysarch, abi.ARCH.SET_FSBASE, @intFromPtr(&base), 0, 0, 0, 0) != 0) return null;
    pthread.threads_ready = true;
    return tp;
}

// ── Modules ─────────────────────────────────────────────────────────────────

/// A file as the console stores it, signed and encrypted (a "SELF"): not
/// something this can load. Its first four bytes say so.
pub fn isEncrypted(file: []const u8) bool {
    return file.len >= 4 and std.mem.eql(u8, file[0..4], "\x4f\x15\x3d\x1d");
}

pub fn isModuleName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".prx") or std.mem.endsWith(u8, name, ".sprx");
}

/// The files `load` copied from: they go once the link is done.
var pending: [MODULES][]const u8 = undefined;
var pending_count: usize = 0;

fn unmapPending() void {
    for (pending[0..pending_count]) |f| _ = sys.call(S.munmap, @intFromPtr(f.ptr), f.len, 0, 0, 0, 0);
    pending_count = 0;
}

/// What each loaded module's start function has come to, by the module's
/// index: `start_done` is 1 once it has returned (nobody else may be
/// handed the module before), `start_by` the thread running it (which may
/// itself ask for the module again and must not wait for itself).
var start_done: [MODULES]u32 = [_]u32{0} ** MODULES;
var start_by: [MODULES]i64 = [_]i64{0} ** MODULES;
/// The path each module was loaded from, as one number: two files of one
/// name in two folders are two modules.
var path_hash: [MODULES]u64 = [_]u64{0} ** MODULES;

/// Loads one file (not linked yet). Its index, or a negated errno with
/// the reason said: no such file, or not something that can be loaded.
fn loadFile(path: [*:0]const u8, name: []const u8) i64 {
    if (pending_count == pending.len) {
        say("{s}: not loaded: too many modules at once", .{name});
        return -@as(i64, abi.E.NOMEM);
    }
    const file = mapFile(path) orelse {
        say("{s}: cannot be read", .{name});
        return -@as(i64, abi.E.NOENT);
    };
    if (isEncrypted(file)) {
        say("{s}: still encrypted, as the console stores it: it has to be decrypted first", .{name});
        _ = sys.call(S.munmap, @intFromPtr(file.ptr), file.len, 0, 0, 0, 0);
        return -@as(i64, abi.E.NOEXEC);
    }
    const index = linker.load(name, file) catch |e| {
        say("{s}: not loaded: {s}", .{ name, @errorName(e) });
        _ = sys.call(S.munmap, @intFromPtr(file.ptr), file.len, 0, 0, 0, 0);
        return -@as(i64, abi.E.NOEXEC);
    };
    pending[pending_count] = file;
    pending_count += 1;
    path_hash[index] = nameHash(std.mem.span(path));
    @atomicStore(u32, &start_done[index], 0, .release);
    return index;
}

/// Puts `name` in its place among `names[0..count]`, kept in order.
pub fn insertSorted(names: []link.Name, count: usize, name: []const u8) void {
    var i = count;
    while (i > 0 and std.mem.lessThan(u8, name, names[i - 1].slice())) : (i -= 1) names[i] = names[i - 1];
    names[i] = link.Name.of(name);
}

/// The modules a game brought: every `.prx` in `sce_module` beside its
/// executable, in name order (so that which of two modules exporting one
/// name wins does not depend on how the folder happens to list them).
fn loadBundled() u32 {
    var dir_buf: [1024]u8 = undefined;
    const dir = joinPath(&dir_buf, libkernel.app0, "/sce_module", "") orelse return 0;
    const fd = sys.call(S.open, @intFromPtr(dir.ptr), abi.O.DIRECTORY, 0, 0, 0, 0);
    if (fd < 0) return 0; // (a game without any)
    var names: [MODULES - 2]link.Name = undefined;
    var count: usize = 0;
    var skipped: u32 = 0;
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const got = sys.call(S.getdents, @intCast(fd), @intFromPtr(&buf), buf.len, 0, 0, 0);
        if (got <= 0) break;
        var off: usize = 0;
        const end: usize = @intCast(got);
        while (off + 8 <= end) {
            const reclen = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            const namlen = buf[off + 7];
            if (reclen < 8 or off + reclen > end or 8 + @as(usize, namlen) > reclen) break;
            const name = buf[off + 8 ..][0..namlen];
            off += reclen;
            if (!isModuleName(name)) continue;
            if (name.len > link.NAME_MAX or count == names.len) {
                skipped += 1;
                continue;
            }
            insertSorted(&names, count, name);
            count += 1;
        }
    }
    _ = sys.call(S.close, @intCast(fd), 0, 0, 0, 0, 0);
    if (skipped != 0) say("sce_module: {d} modules left out (more than {d}, or a name too long)", .{ skipped, names.len });
    var loaded: u32 = 0;
    for (names[0..count]) |*n| {
        var path_buf: [1024]u8 = undefined;
        const path = joinPath(&path_buf, dir, "/", n.slice()) orelse continue;
        if (loadFile(path.ptr, n.slice()) >= 0) loaded += 1;
    }
    return loaded;
}

const ModuleStart = *const fn (args: usize, argp: ?*const anyopaque, param: ?*anyopaque) callconv(.c) c_int;

/// Takes the modules linked and not started yet as this thread's to
/// start, a module after the modules it needs. Under the linker's lock,
/// in the same hold as the link that made them ready: whoever loads a
/// module is the one to start it.
fn claimStarts(order: *[MODULES]u16) []const u16 {
    const todo = linker.startOrder(order);
    const self = pthread.thread().tid;
    for (todo) |index| @atomicStore(i64, &start_by[index], self, .release);
    return todo;
}

/// Runs the start functions claimed. `wanted` gets the arguments a
/// program gave and its answer comes back; the rest get none. Not under
/// the linker's lock: a start function may itself load a module.
fn runStarts(todo: []const u16, wanted: ?u16, args: usize, argp: ?*const anyopaque) c_int {
    var answer: c_int = 0;
    for (todo) |index| {
        const m = &linker.loaded()[index];
        if (m.init != 0) {
            const f: ModuleStart = @ptrFromInt(@as(usize, @intCast(m.init)));
            const is_wanted = wanted != null and wanted.? == index;
            const r = if (is_wanted) f(args, argp, null) else f(0, null, null);
            if (is_wanted) answer = r;
        }
        // (whoever asked for it meanwhile may have it now)
        @atomicStore(u32, &start_done[index], 1, .release);
        pthread.wakeAll(&start_done[index]);
    }
    return answer;
}

/// `sceKernelLoadStartModule`: a module by its path, loaded, linked and
/// started while the game runs. Its handle (the same one when it is
/// loaded already), or a negated errno.
fn moduleLoad(path: [*:0]const u8, args: usize, argp: ?*const anyopaque, result: ?*c_int) i64 {
    var buf: [1024]u8 = undefined;
    var joined: [1024]u8 = undefined;
    var given: [*:0]const u8 = path;
    // (a bare name is one of the game's own modules)
    if (std.mem.indexOfScalar(u8, std.mem.span(path), '/') == null) {
        given = (joinPath(&joined, "/app0/sce_module/", std.mem.span(path), "") orelse return -@as(i64, abi.E.NAMETOOLONG)).ptr;
    }
    const host = libkernel.hostPath(given, &buf) orelse return -@as(i64, abi.E.NAMETOOLONG);
    const name = basename(std.mem.span(host));

    const hash = nameHash(std.mem.span(host));

    linker_lock.lock();
    // Loaded already (and not given up): the same module. Its start
    // function may still be running on the thread that loaded it: this
    // caller gets the module once it has returned.
    for (linker.loaded(), 0..) |*m, i| {
        if (m.abandoned or path_hash[i] != hash or !std.mem.eql(u8, m.file.slice(), name[0..@min(name.len, link.NAME_MAX)])) continue;
        const starting = m.started;
        linker_lock.unlock();
        const self = pthread.thread().tid;
        while (starting and @atomicLoad(u32, &start_done[i], .acquire) == 0 and @atomicLoad(i64, &start_by[i], .acquire) != self) {
            pthread.waitWhile(&start_done[i], 0);
        }
        if (result) |r| r.* = 0;
        return @intCast(i);
    }
    const loaded = loadFile(host, name);
    if (loaded < 0) {
        linker_lock.unlock();
        return loaded;
    }
    const index: u16 = @intCast(loaded);
    var ok = true;
    linker.link() catch |e| {
        say("{s}: not linked: {s}", .{ name, @errorName(e) });
        ok = false;
    };
    // (whatever happened, the stand-ins made on the way must become code:
    // other modules may be bound to them)
    if (!Stubs.seal()) ok = false;
    unmapPending();
    if (!ok) {
        // (given up: it exports nothing, is no module to ask for again,
        // and is never started)
        linker.abandon(index);
        linker_lock.unlock();
        return -@as(i64, abi.E.NOEXEC);
    }
    // Its thread storage, in every thread there is.
    noteTls();
    const m = &linker.loaded()[index];
    if (m.tls_index != 0) {
        late = m;
        pthread.forEachThread(fillLate);
    }
    // Its start function is this thread's to run, taken before the lock
    // goes: another thread loading another module does not take it.
    var order: [MODULES]u16 = undefined;
    const todo = claimStarts(&order);
    linker_lock.unlock();

    const answer = runStarts(todo, index, args, argp);
    if (result) |r| r.* = answer;
    return index;
}

/// The module `fillLate` fills (set under the linker's lock).
var late: *const link.Module = undefined;

fn fillLate(tp: u64) void {
    link.Linker.initTlsOf(late, tp);
}

/// `sceKernelDlsym`: what a module exports under a plain name.
fn moduleSymbol(handle: c_int, name: [*:0]const u8) u64 {
    if (handle < 0) return 0;
    linker_lock.lock();
    defer linker_lock.unlock();
    if (handle >= linker.loaded().len) return 0;
    const e = linker.lookupIn(@intCast(handle), nid.of(std.mem.span(name))) orelse return 0;
    return if (e.tls) 0 else e.addr;
}

// ── Starting the game ───────────────────────────────────────────────────────

/// The game's first thread's stack when its file does not say (the
/// console's default), and the least and most one is given.
const STACK_BYTES: u64 = 2 << 20;
const STACK_MIN: u64 = 64 << 10;
const STACK_MAX: u64 = 1 << 30;
const MAX_ARGS = 62;
/// The most the arguments' text may take of the stack.
const ARG_BYTES_MAX: usize = 32 << 10;

/// What a game's start code registers to run at exit. The runtime has
/// nothing to undo.
fn cleanup() callconv(.c) void {}

/// The stack size a program asks for its first thread: its process
/// parameter's seventh word points at it (a 32-bit number). The file is
/// not trusted: the parameter must be long enough to have the word, and
/// the pointer must lead into the program's own memory.
fn stackBytes(exe: *const link.Module) u64 {
    const FIELD = 0x30;
    if (exe.proc_param == 0 or exe.proc_param_size < FIELD + 8) return STACK_BYTES;
    const param: [*]align(1) const u64 = @ptrFromInt(@as(usize, @intCast(exe.proc_param)));
    if (param[0] < FIELD + 8) return STACK_BYTES; // (its own word for its size)
    const at = param[FIELD / 8];
    if (at < exe.start or at > exe.start + exe.size - 4) return STACK_BYTES;
    const asked: u64 = @as(*align(1) const u32, @ptrFromInt(@as(usize, @intCast(at)))).*;
    if (asked == 0) return STACK_BYTES;
    return std.mem.alignForward(u64, std.math.clamp(asked, STACK_MIN, STACK_MAX), abi.PAGE);
}

/// The game's arguments at the top of its stack, as a kernel leaves them
/// for a new program: the text, then (lower) the block its entry gets in
/// rdi: argc, the argv pointers, a null, and a null for an environment of
/// nothing. Returns the block's address, a multiple of 16.
fn pushArguments(top: u64, ap: [*]const u64, count: usize) u64 {
    var at = top;
    var pointers: [MAX_ARGS]u64 = undefined;
    var n: usize = 0;
    var text: usize = 0;
    while (n < count) : (n += 1) {
        const arg = std.mem.span(@as([*:0]const u8, @ptrFromInt(ap[2 + n])));
        if (text + arg.len + 1 > ARG_BYTES_MAX) break; // (the rest are left out)
        text += arg.len + 1;
        at -= arg.len + 1;
        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(at)));
        @memcpy(dst[0..arg.len], arg);
        dst[arg.len] = 0;
        pointers[n] = at;
    }
    at &= ~@as(u64, 15);
    // argc, argv[0..n], null, the environment's null, and two words of
    // nothing after it (where FreeBSD's vector of extras would end).
    const words = 1 + n + 1 + 1 + 2;
    at = (at - words * 8) & ~@as(u64, 15);
    const block: [*]u64 = @ptrFromInt(@as(usize, @intCast(at)));
    block[0] = n;
    for (0..n) |i| block[1 + i] = pointers[i];
    @memset(block[1 + n .. words], 0);
    return at;
}

/// Three pieces of a path one after another in `buf`, ending with a 0.
/// Null when they do not fit.
pub fn joinPath(buf: []u8, a: []const u8, b: []const u8, c: []const u8) ?[:0]const u8 {
    const len = a.len + b.len + c.len;
    if (len + 1 > buf.len) return null;
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    @memcpy(buf[a.len + b.len ..][0..c.len], c);
    buf[len] = 0;
    return buf[0..len :0];
}

fn basename(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

fn dirname(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    return if (i == 0) "/" else path[0..i];
}

/// libkernel and the linker made ready, with nothing loaded yet. `folder`
/// is what the game knows as /app0.
fn prepare(folder: []const u8) void {
    libkernel.init();
    libkernel.app0 = folder;
    libkernel.tls_address = tlsAddress;
    libkernel.module_load = moduleLoad;
    libkernel.module_symbol = moduleSymbol;
    linker = link.Linker.init(.{ .reserve = reserve, .release = release, .protect = protect, .builtin = builtin, .missing = missing }, .{
        .modules = &modules,
        .libraries = &libraries,
        .exports = &exports,
    });
}

/// For a program that is its own game: one built with these libraries (a
/// test of them) and started by the kernel as any PS5 program. libkernel
/// is made ready and the thread it runs on becomes the first thread, on
/// the stack it already has. `folder` is what it knows as /app0. False
/// when there is no memory for the thread's storage.
pub fn standalone(folder: []const u8) bool {
    prepare(folder);
    return firstThread(0, 0) != null;
}

/// The runtime's whole life: `ap` is FreeBSD's argument block (argc, then
/// argv), argv[1] the PS5 executable, the rest the game's own arguments.
pub fn start(ap: [*]const u64) noreturn {
    const argc = ap[0];
    if (argc < 2) die(64, "usage: {s} EBOOT [ARGS...]", .{if (argc > 0) std.mem.span(@as([*:0]const u8, @ptrFromInt(ap[1]))) else "galaxy-ps5"});
    const path: [*:0]const u8 = @ptrFromInt(ap[2]);
    const path_text = std.mem.span(path);
    const name = basename(path_text);

    prepare(dirname(path_text));
    // (the name is the end of the path's own text, so it ends with its 0)
    libkernel.progname = @ptrCast(name.ptr);

    // The executable first (its exports win), then the modules it brought.
    const first = loadFile(path, name);
    if (first < 0) die(126, "{s}: nothing to run", .{name});
    const index: u16 = @intCast(first);
    var bundled = loadBundled();
    // One of its modules that cannot be linked is left out (said, and
    // what the game wanted of it is then missing where it is called);
    // the executable itself that cannot be is the end.
    while (true) {
        // (a link run again counts again)
        linker.stats = .{};
        linker.link() catch |e| {
            const bad = linker.failed;
            // (a protection that could not be set comes after modules were
            // bound to each other for good: there is no going on from it)
            if (bad == link.Linker.NO_MODULE or bad == index or e == error.Protect) die(126, "{s}: not linked: {s}", .{ name, @errorName(e) });
            say("{s}: not linked: {s}: the game goes on without it", .{ linker.loaded()[bad].file.slice(), @errorName(e) });
            linker.abandon(bad);
            bundled -|= 1;
            continue;
        };
        break;
    }
    if (!Stubs.seal()) die(126, "{s}: the stand-ins for what nothing provides could not be made code", .{name});
    unmapPending();

    const exe = &linker.loaded()[index];
    if (!exe.kind.isExecutable() or exe.entry == 0) die(126, "{s}: a module, not a program (nothing to start)", .{name});
    const st = linker.stats;
    say("{s}: loaded at 0x{x}, {d} relocations; imports: {d} from libkernel, {d} from modules, {d} that nothing provides yet", .{
        name, exe.base, st.relocations, st.from_host, st.from_modules, st.stand_ins,
    });
    if (bundled != 0) say("{s}: {d} of its own modules loaded with it", .{ name, bundled });
    if (Objects.count > Objects.SAID_MAX) say("{s}: {d} objects in all that nothing provides (they read as zeroes)", .{ name, Objects.count });

    // Its stack: the size its file asks for, with a page below that
    // nothing may touch, so that running off its end is a fault and not a
    // quiet write into whatever was mapped next.
    const bytes = stackBytes(exe);
    const stack = sys.call(S.mmap, 0, bytes + abi.PAGE, RW, abi.MAP.STACK, NO_FD, 0);
    if (stack < 0) die(126, "{s}: no memory for its stack", .{name});
    const bottom: u64 = @intCast(stack);
    if (sys.call(S.mprotect, bottom, abi.PAGE, 0, 0, 0, 0) != 0) die(126, "{s}: its stack's guard could not be set", .{name});

    _ = firstThread(bottom + abi.PAGE, bytes) orelse die(126, "{s}: no memory for its first thread", .{name});

    // The game's arguments: its own path, then what followed it.
    game_entry = exe.entry;
    const block = pushArguments(bottom + abi.PAGE + bytes, ap, @intCast(@min(argc - 1, MAX_ARGS)));
    enter(@intFromPtr(&gameMain), block, 0, block);
}

var game_entry: u64 = 0;

/// The game's first thread, on its own stack: its modules' start
/// functions, then the executable's entry (which gets the stack as the
/// runtime first made it: nothing of this function stays on it).
fn gameMain(block: u64) callconv(.c) noreturn {
    var order: [MODULES]u16 = undefined;
    linker_lock.lock();
    const todo = claimStarts(&order);
    linker_lock.unlock();
    _ = runStarts(todo, null, 0, null);
    enter(game_entry, block, @intFromPtr(&cleanup), block);
}

/// Onto the game's stack and into its entry: rdi the argument block, rsi
/// the clean-up function, no frame behind it, the stack as after a call.
fn enter(entry: u64, args: u64, cleanup_fn: u64, stack_top: u64) noreturn {
    asm volatile (
        \\ mov %[top], %%rsp
        \\ xor %%ebp, %%ebp
        \\ pushq $0
        \\ jmp *%[entry]
        :
        : [top] "{rcx}" (stack_top & ~@as(u64, 15)),
          [entry] "{rax}" (entry),
          [args] "{rdi}" (args),
          [clean] "{rsi}" (cleanup_fn),
        : .{ .memory = true });
    unreachable;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "a stand-in's code: its number, then a jump through the page's first word" {
    var code: [Stubs.SIZE]u8 = undefined;
    // The third stand-in of a page at 0x10000 (the first slot is the word).
    const page: u64 = 0x10000;
    const at = page + 3 * Stubs.SIZE;
    Stubs.encode(&code, 2, at, page);
    try std.testing.expectEqualSlices(u8, &.{ 0xb8, 2, 0, 0, 0, 0xff, 0x25 }, code[0..7]);
    // rip after the jump is at + 11: the word is 0x30 + 11 bytes behind it.
    try std.testing.expectEqual(@as(i32, -(0x30 + 11)), std.mem.readInt(i32, code[7..11], .little));
    try std.testing.expectEqual(@as(u8, 0xcc), code[11]);
}

test "a path joined from its pieces, when it fits" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("/games/a/sce_module", joinPath(&buf, "/games/a", "/sce_module", "").?);
    try std.testing.expectEqualStrings("/g/sce_module/libc.prx", joinPath(&buf, "/g/sce_module", "/", "libc.prx").?);
    try std.testing.expectEqual(@as(u8, 0), buf[22]);
    // (one byte short of room for its end)
    try std.testing.expect(joinPath(&buf, "/games/abcdef/sce_module", "", "") == null);
    try std.testing.expect(joinPath(&buf, "/games/abcde/sce_module", "", "") != null);
}

test "which files are modules, and which are still encrypted" {
    try std.testing.expect(isModuleName("libc.prx"));
    try std.testing.expect(isModuleName("libSceFios2.sprx"));
    try std.testing.expect(!isModuleName("readme.txt"));
    try std.testing.expect(!isModuleName("prx"));
    try std.testing.expect(isEncrypted("\x4f\x15\x3d\x1d\x00\x01"));
    try std.testing.expect(!isEncrypted("\x7fELF"));
    try std.testing.expect(!isEncrypted("\x4f\x15"));
}

test "module names kept in order as they are found" {
    var names: [4]link.Name = undefined;
    insertSorted(&names, 0, "libc.prx");
    insertSorted(&names, 1, "libSceFios2.prx");
    insertSorted(&names, 2, "libz.prx");
    insertSorted(&names, 3, "liba.prx");
    try std.testing.expectEqualStrings("libSceFios2.prx", names[0].slice());
    try std.testing.expectEqualStrings("liba.prx", names[1].slice());
    try std.testing.expectEqualStrings("libc.prx", names[2].slice());
    try std.testing.expectEqualStrings("libz.prx", names[3].slice());
}

test "a stand-in's place in the pages, and the page a later one starts" {
    try std.testing.expectEqual(@as(u32, 1023), Stubs.PER_PAGE);
    // The first place is after the page's word; the last one ends the page.
    try std.testing.expectEqual(@as(u32, 0), Stubs.where(0).page);
    try std.testing.expectEqual(@as(u64, Stubs.SIZE), Stubs.where(0).offset);
    try std.testing.expectEqual(@as(u32, 0), Stubs.where(1022).page);
    try std.testing.expectEqual(@as(u64, abi.PAGE), Stubs.where(1022).offset + Stubs.SIZE);
    try std.testing.expectEqual(@as(u32, 1), Stubs.where(1023).page);
    try std.testing.expectEqual(@as(u64, Stubs.SIZE), Stubs.where(1023).offset);
    // What `seal` moves on to: the page after the one begun; a page just
    // filled, or none begun, is not skipped.
    try std.testing.expectEqual(@as(u32, 0), Stubs.nextPage(0));
    try std.testing.expectEqual(@as(u32, 1023), Stubs.nextPage(1));
    try std.testing.expectEqual(@as(u32, 1023), Stubs.nextPage(1023));
    try std.testing.expectEqual(@as(u32, 2046), Stubs.nextPage(1024));
    // A stand-in's number is not its place: there are records for more
    // stand-ins than one module's worth, and pages for many loads.
    try std.testing.expect(Stubs.PAGES > 1000 and Stubs.MAX >= 16384);
}

test "two paths with one name are told apart" {
    try std.testing.expect(nameHash("/app0/a/p.prx") != nameHash("/app0/b/p.prx"));
    try std.testing.expectEqual(nameHash("/app0/a/p.prx"), nameHash("/app0/a/p.prx"));
    try std.testing.expect(nameHash("") != nameHash("a"));
}

test "a path's folder and name" {
    try std.testing.expectEqualStrings("eboot.bin", basename("/games/hello/eboot.bin"));
    try std.testing.expectEqualStrings("/games/hello", dirname("/games/hello/eboot.bin"));
    try std.testing.expectEqualStrings("/", dirname("/eboot.bin"));
    try std.testing.expectEqualStrings(".", dirname("eboot.bin"));
}
