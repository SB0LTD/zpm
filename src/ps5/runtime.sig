//! @zpm/ps5 runtime — what stands between a kernel that speaks the PS5's
//! ABI and a game: the program the kernel starts for a PS5 executable. It
//! does what the console's libkernel does before a game's first
//! instruction, in the game's own process:
//!
//!   1. maps the executable's file and gives it to the linker (link.sig),
//!      which copies it in and binds its imports: to this runtime's
//!      libkernel (libkernel.sig), or, for a symbol nobody has yet, to a
//!      stand-in that says which one when the game calls it;
//!   2. makes the first thread's control block and thread storage and
//!      points FS at it;
//!   3. switches to a stack of the game's and jumps to its entry, with the
//!      argument block and the clean-up function its start code expects.
//!
//! From there the game runs as itself: its code is the CPU's own, its
//! system calls are the kernel's, and what it imports is ordinary code in
//! the same address space. Nothing is translated or rewritten on disk.
//!
//! `start` is the whole of it: a host's `_start` hands it FreeBSD's
//! argument block (argv[1] is the executable).
//!
//! Not here yet: the modules a game bundles (`sce_module/*.prx`), threads
//! of the game's own, and every library but libkernel.
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
    pub const MAX = 4096;
    /// Bytes of one stand-in; the first slot of the page holds the address
    /// they all jump through.
    pub const SIZE = 16;

    const Info = struct {
        nid: nid.Nid = 0,
        library: link.Name = .{},
        said: bool = false,
    };

    var page: u64 = 0;
    var count: u32 = 0;
    var info: [MAX]Info = undefined;

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
        if (page == 0) {
            const bytes = std.mem.alignForward(u64, (MAX + 1) * SIZE, abi.PAGE);
            const r = sys.call(S.mmap, 0, bytes, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
            if (r < 0) return null;
            page = @intCast(r);
            @as(*u64, @ptrFromInt(@as(usize, @intCast(page)))).* = @intFromPtr(&ps5_runtime_missing);
        }
        // (the same import of several modules: one stand-in)
        for (info[0..count], 0..) |*i, k| {
            if (i.nid == n and std.mem.eql(u8, i.library.slice(), library[0..@min(library.len, link.NAME_MAX)])) return address(@intCast(k));
        }
        if (count == MAX) return null;
        const index = count;
        info[index] = .{ .nid = n, .library = link.Name.of(library) };
        count += 1;
        const at = address(index);
        encode(@ptrFromInt(@as(usize, @intCast(at))), index, at, page);
        return at;
    }

    fn address(index: u32) u64 {
        return page + SIZE * (@as(u64, index) + 1);
    }

    /// The stand-ins become code (no longer writable). False when the
    /// kernel would not allow it: they could then not be called at all.
    fn seal() bool {
        if (page == 0) return true;
        const bytes = std.mem.alignForward(u64, (MAX + 1) * SIZE, abi.PAGE);
        return sys.call(S.mprotect, page, bytes, abi.PROT.READ | abi.PROT.EXEC, 0, 0, 0) == 0;
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

    var base: u64 = 0;
    var used: u64 = 0;
    var count: u32 = 0;

    fn make(what: link.Missing) ?u64 {
        if (what.size > ONE_MAX) return null;
        if (base == 0) {
            const r = sys.call(S.mmap, 0, BYTES, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
            if (r < 0) return null;
            base = @intCast(r);
        }
        const size = std.mem.alignForward(u64, @max(what.size, 8), 16);
        if (size > BYTES - used) return null;
        const at = base + used;
        used += size;
        count += 1;
        if (count <= SAID_MAX) say("not provided: the object {s}:{s} ({d} bytes): it reads as zeroes", .{ what.library, nid.text(what.nid), what.size });
        return at;
    }
};

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
    if (index >= Stubs.count) return;
    const i = &Stubs.info[index];
    if (@atomicRmw(bool, &i.said, .Xchg, true, .monotonic)) return;
    say("not implemented: {s}:{s} was called (it answers 0)", .{ i.library.slice(), nid.text(i.nid) });
}

// ── The linker's host ───────────────────────────────────────────────────────

var modules: [64]link.Module = undefined;
var libraries: [256]link.Name = undefined;
var exports: [1 << 14]link.Export = undefined;
var linker: link.Linker = undefined;

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
    return libkernel.find(library, n);
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

fn tlsAddress(module: u64, offset: u64) callconv(.c) usize {
    const m = linker.tlsModule(module) orelse return 0;
    return @intCast(sys.fs0() -% m.tls_offset +% offset);
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
/// below the thread pointer, the control block at it. Null when there is
/// no memory for it.
fn firstThread() ?u64 {
    const st = linker.staticTls();
    const below = std.mem.alignForward(u64, st.size, @max(st.alignment, 16));
    const bytes = std.mem.alignForward(u64, below + @sizeOf(libkernel.Tcb), abi.PAGE);
    const r = sys.call(S.mmap, 0, bytes, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
    if (r < 0) return null;
    const tp: u64 = @as(u64, @intCast(r)) + below;
    linker.initTls(tp);
    var tid: i64 = 0;
    _ = sys.call(S.thr_self, @intFromPtr(&tid), 0, 0, 0, 0, 0);
    main_thread.tid = tid;
    const tcb: *libkernel.Tcb = @ptrFromInt(@as(usize, @intCast(tp)));
    tcb.* = .{ .self = tp, .thread = @intFromPtr(&main_thread) };
    var base = tp;
    if (sys.call(S.sysarch, abi.ARCH.SET_FSBASE, @intFromPtr(&base), 0, 0, 0, 0) != 0) return null;
    libkernel.threads_ready = true;
    return tp;
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

fn basename(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

fn dirname(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    return if (i == 0) "/" else path[0..i];
}

/// The runtime's whole life: `ap` is FreeBSD's argument block (argc, then
/// argv), argv[1] the PS5 executable, the rest the game's own arguments.
pub fn start(ap: [*]const u64) noreturn {
    const argc = ap[0];
    if (argc < 2) die(64, "usage: {s} EBOOT [ARGS...]", .{if (argc > 0) std.mem.span(@as([*:0]const u8, @ptrFromInt(ap[1]))) else "galaxy-ps5"});
    const path: [*:0]const u8 = @ptrFromInt(ap[2]);
    const path_text = std.mem.span(path);
    const name = basename(path_text);

    libkernel.init();
    libkernel.app0 = dirname(path_text);
    libkernel.tls_address = tlsAddress;
    // (the name is the end of the path's own text, so it ends with its 0)
    libkernel.progname = @ptrCast(name.ptr);

    const file = mapFile(path) orelse die(127, "{s}: cannot be read", .{path_text});
    linker = link.Linker.init(.{ .reserve = reserve, .release = release, .protect = protect, .builtin = builtin, .missing = missing }, .{
        .modules = &modules,
        .libraries = &libraries,
        .exports = &exports,
    });
    const index = linker.load(name, file) catch |e| die(126, "{s}: not loaded: {s}", .{ name, @errorName(e) });
    linker.link() catch |e| die(126, "{s}: not linked: {s}", .{ name, @errorName(e) });
    if (!Stubs.seal()) die(126, "{s}: the stand-ins for what nothing provides could not be made code", .{name});
    _ = sys.call(S.munmap, @intFromPtr(file.ptr), file.len, 0, 0, 0, 0);

    const exe = &linker.loaded()[index];
    if (!exe.kind.isExecutable() or exe.entry == 0) die(126, "{s}: a module, not a program (nothing to start)", .{name});
    const st = linker.stats;
    say("{s}: loaded at 0x{x}, {d} relocations; imports: {d} from libkernel, {d} from modules, {d} that nothing provides yet", .{
        name, exe.base, st.relocations, st.from_host, st.from_modules, st.stand_ins,
    });
    if (Objects.count > Objects.SAID_MAX) say("{s}: {d} objects in all that nothing provides (they read as zeroes)", .{ name, Objects.count });

    _ = firstThread() orelse die(126, "{s}: no memory for its first thread", .{name});

    // Its stack: the size its file asks for, with a page below that
    // nothing may touch, so that running off its end is a fault and not a
    // quiet write into whatever was mapped next.
    const bytes = stackBytes(exe);
    const stack = sys.call(S.mmap, 0, bytes + abi.PAGE, RW, abi.MAP.STACK, NO_FD, 0);
    if (stack < 0) die(126, "{s}: no memory for its stack", .{name});
    const bottom: u64 = @intCast(stack);
    if (sys.call(S.mprotect, bottom, abi.PAGE, 0, 0, 0, 0) != 0) die(126, "{s}: its stack's guard could not be set", .{name});
    // The game's arguments: its own path, then what followed it.
    const block = pushArguments(bottom + abi.PAGE + bytes, ap, @intCast(@min(argc - 1, MAX_ARGS)));
    enter(exe.entry, block, @intFromPtr(&cleanup), block);
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

test "a path's folder and name" {
    try std.testing.expectEqualStrings("eboot.bin", basename("/games/hello/eboot.bin"));
    try std.testing.expectEqualStrings("/games/hello", dirname("/games/hello/eboot.bin"));
    try std.testing.expectEqualStrings("/", dirname("/eboot.bin"));
    try std.testing.expectEqualStrings(".", dirname("eboot.bin"));
}
