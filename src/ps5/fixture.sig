//! @zpm/ps5 fixture — small PS5 executables and modules made in memory, for
//! the tests of the reader and the linker (and, with code in them, for a
//! kernel's own test of a whole load). The opposite of the reader: names,
//! symbols and relocations go in, a file in the PS5's dialect comes out.
//!
//! The layout is fixed, and a file's offsets equal its addresses:
//!
//!   0x0000  ELF and program headers
//!   TEXT    code (read, execute): up to TEXT_SIZE bytes
//!   TABLES  strings, symbols, hash, relocations, the dynamic section
//!   DATA    data (read, write): DATA_SIZE bytes, the first `data.len` from
//!           the file; the process or module parameter is at its end
//!
//! Allocation-free: fixed tables, the file written into the caller's buffer.

const std = @import("std");
const elf = @import("elf.sig");
const nid = @import("nid.sig");

pub const TEXT: u64 = 0x1000;
pub const TEXT_SIZE: u64 = 0x1000;
pub const TABLES: u64 = 0x2000;
pub const DATA: u64 = 0x8000;
pub const DATA_SIZE: u64 = 0x4000;
/// Where the process or module parameter is.
pub const PARAM: u64 = DATA + DATA_SIZE - 0x80;
/// A buffer this size holds any file the builder makes.
pub const SIZE = DATA + DATA_SIZE;

const MAX_SYMS = 48;
const MAX_RELAS = 64;
const MAX_DYN = 48;

pub const Builder = struct {
    buf: []u8,
    kind: elf.Kind,
    /// Addresses in the module (0: none).
    entry: u64 = 0,
    init_at: u64 = 0,
    code: []const u8 = &.{},
    data: []const u8 = &.{},
    strings: [2048]u8 = undefined,
    strings_len: u32 = 1,
    syms: [MAX_SYMS]elf.Sym = undefined,
    sym_count: u32 = 1,
    relas: [MAX_RELAS]elf.Rela = undefined,
    rela_count: u32 = 0,
    plts: [MAX_RELAS]elf.Rela = undefined,
    plt_count: u32 = 0,
    names: [MAX_DYN]elf.Dyn = undefined,
    name_count: u32 = 0,
    tls_seg: ?elf.Tls = null,
    /// A part to be read-only once relocated (address, size), if any.
    relro: ?elf.Range = null,
    /// Whether the file says its symbol table's size (Sony's tag). Without
    /// it a reader counts the symbols from the hash table.
    symtab_size_tag: bool = true,

    pub fn init(buf: []u8, kind: elf.Kind) Builder {
        std.debug.assert(buf.len >= SIZE);
        var b = Builder{ .buf = buf, .kind = kind };
        b.strings[0] = 0;
        b.syms[0] = std.mem.zeroes(elf.Sym);
        return b;
    }

    fn string(b: *Builder, s: []const u8) u32 {
        const at = b.strings_len;
        @memcpy(b.strings[at..][0..s.len], s);
        b.strings[at + s.len] = 0;
        b.strings_len += @intCast(s.len + 1);
        return at;
    }

    fn name(b: *Builder, tag: u64, text: []const u8, id: u16, version: u16) void {
        b.names[b.name_count] = .{ .tag = tag, .val = @as(u64, id) << 48 | @as(u64, version) << 32 | b.string(text) };
        b.name_count += 1;
    }

    fn attr(b: *Builder, tag: u64, id: u16, flags: u32) void {
        b.names[b.name_count] = .{ .tag = tag, .val = @as(u64, id) << 48 | flags };
        b.name_count += 1;
    }

    /// The file's own module name.
    pub fn selfModule(b: *Builder, text: []const u8, id: u16) void {
        b.name(elf.DT.SCE_MODULE_INFO_1, text, id, 0x0101);
    }

    pub fn neededModule(b: *Builder, text: []const u8, id: u16) u16 {
        b.name(elf.DT.SCE_NEEDED_MODULE_1, text, id, 0x0101);
        return id;
    }

    pub fn importLibrary(b: *Builder, text: []const u8, id: u16) u16 {
        b.name(elf.DT.SCE_IMPORT_LIB_1, text, id, 1);
        b.attr(elf.DT.SCE_IMPORT_LIB_ATTR, id, 9);
        return id;
    }

    pub fn exportLibrary(b: *Builder, text: []const u8, id: u16) u16 {
        b.name(elf.DT.SCE_EXPORT_LIB_1, text, id, 1);
        b.attr(elf.DT.SCE_EXPORT_LIB_ATTR, id, 1);
        return id;
    }

    fn symbol(b: *Builder, n: nid.Nid, library: u16, module: u16, value: u64, shndx: u16, bind: u8, kind: u8) u32 {
        var text: [nid.TEXT_LEN + 10]u8 = undefined;
        @memcpy(text[0..nid.TEXT_LEN], &nid.text(n));
        var len: usize = nid.TEXT_LEN;
        var digits: [4]u8 = undefined;
        for ([_]u16{ library, module }) |id| {
            text[len] = '#';
            const d = nid.indexText(id, &digits);
            @memcpy(text[len + 1 ..][0..d.len], d);
            len += 1 + d.len;
        }
        const i = b.sym_count;
        b.syms[i] = .{ .name = b.string(text[0..len]), .info = bind << 4 | kind, .other = 0, .shndx = shndx, .value = value, .size = 0 };
        b.sym_count += 1;
        return i;
    }

    /// A symbol another module is to provide; its index.
    pub fn importSymbol(b: *Builder, n: nid.Nid, library: u16, module: u16, kind: u8) u32 {
        return b.symbol(n, library, module, 0, elf.SHN_UNDEF, elf.STB_GLOBAL, kind);
    }

    /// The same, but nothing providing it is no error (it then reads as 0).
    pub fn weakImport(b: *Builder, n: nid.Nid, library: u16, module: u16, kind: u8) u32 {
        return b.symbol(n, library, module, 0, elf.SHN_UNDEF, elf.STB_WEAK, kind);
    }

    /// A symbol this file provides, at `value` in the module; its index.
    pub fn exportSymbol(b: *Builder, n: nid.Nid, library: u16, module: u16, value: u64, kind: u8) u32 {
        return b.symbol(n, library, module, value, 1, elf.STB_GLOBAL, kind);
    }

    fn rela(b: *Builder, at: u64, sym: u32, kind: u32, addend: i64) void {
        b.relas[b.rela_count] = .{ .offset = at, .info = @as(u64, sym) << 32 | kind, .addend = addend };
        b.rela_count += 1;
    }

    /// The word at `at` is to hold where `target` (an address in the
    /// module) is loaded.
    pub fn relative(b: *Builder, at: u64, target: u64) void {
        b.rela(at, 0, elf.R.RELATIVE, @intCast(target));
    }

    /// The word at `at`: the symbol's address plus `addend`.
    pub fn absolute(b: *Builder, at: u64, sym: u32, addend: i64) void {
        b.rela(at, sym, elf.R.@"64", addend);
    }

    pub fn globDat(b: *Builder, at: u64, sym: u32) void {
        b.rela(at, sym, elf.R.GLOB_DAT, 0);
    }

    /// Thread storage: the module's index, an offset in its block, and an
    /// offset from the thread pointer.
    pub fn tlsModule(b: *Builder, at: u64) void {
        b.rela(at, 0, elf.R.DTPMOD64, 0);
    }
    pub fn tlsOffset(b: *Builder, at: u64, sym: u32, addend: i64) void {
        b.rela(at, sym, elf.R.DTPOFF64, addend);
    }
    pub fn threadPointerOffset(b: *Builder, at: u64, sym: u32, addend: i64) void {
        b.rela(at, sym, elf.R.TPOFF64, addend);
    }

    /// An imported function's slot (the PLT's relocations).
    pub fn jumpSlot(b: *Builder, at: u64, sym: u32) void {
        b.plts[b.plt_count] = .{ .offset = at, .info = @as(u64, sym) << 32 | elf.R.JUMP_SLOT, .addend = 0 };
        b.plt_count += 1;
    }

    /// The thread storage's initial bytes are `filesz` bytes at `vaddr`
    /// (in the data), then zeroes up to `memsz`.
    pub fn tls(b: *Builder, vaddr: u64, filesz: u64, memsz: u64, alignment: u64) void {
        b.tls_seg = .{ .vaddr = vaddr, .filesz = filesz, .memsz = memsz, .alignment = alignment };
    }

    /// Writes the file; the bytes used of the buffer.
    pub fn finish(b: *Builder) []const u8 {
        std.debug.assert(b.code.len <= TEXT_SIZE and b.data.len <= DATA_SIZE - 0x80);
        const out = b.buf[0..SIZE];
        @memset(out, 0);
        @memcpy(out[TEXT..][0..b.code.len], b.code);
        @memcpy(out[DATA..][0..b.data.len], b.data);

        // The tables, one after another, 8-aligned.
        var at: u64 = TABLES;
        const strtab = at;
        @memcpy(out[at..][0..b.strings_len], b.strings[0..b.strings_len]);
        at = std.mem.alignForward(u64, at + b.strings_len, 8);
        const symtab = at;
        const sym_bytes = std.mem.sliceAsBytes(b.syms[0..b.sym_count]);
        @memcpy(out[at..][0..sym_bytes.len], sym_bytes);
        at += sym_bytes.len;
        // A System V hash table with one bucket: every symbol on one chain.
        const hash = at;
        w32(out, at, 1);
        w32(out, at + 4, b.sym_count);
        w32(out, at + 8, b.sym_count - 1);
        for (1..b.sym_count) |i| w32(out, at + 12 + 4 * i, @intCast(i - 1));
        at = std.mem.alignForward(u64, at + 12 + 4 * @as(u64, b.sym_count), 8);
        const rela_at = at;
        const rela_bytes = std.mem.sliceAsBytes(b.relas[0..b.rela_count]);
        @memcpy(out[at..][0..rela_bytes.len], rela_bytes);
        at += rela_bytes.len;
        const jmprel = at;
        const plt_bytes = std.mem.sliceAsBytes(b.plts[0..b.plt_count]);
        @memcpy(out[at..][0..plt_bytes.len], plt_bytes);
        at += plt_bytes.len;

        const dynamic = at;
        var d = DynWriter{ .out = out, .at = at };
        for (b.names[0..b.name_count]) |n| d.put(n.tag, n.val);
        d.put(elf.DT.HASH, hash);
        d.put(elf.DT.STRTAB, strtab);
        d.put(elf.DT.STRSZ, b.strings_len);
        d.put(elf.DT.SYMTAB, symtab);
        d.put(elf.DT.SYMENT, @sizeOf(elf.Sym));
        if (b.symtab_size_tag) d.put(elf.DT.SCE_SYMTABSZ, sym_bytes.len);
        if (b.rela_count != 0) {
            d.put(elf.DT.RELA, rela_at);
            d.put(elf.DT.RELASZ, rela_bytes.len);
            d.put(elf.DT.RELAENT, @sizeOf(elf.Rela));
        }
        if (b.plt_count != 0) {
            d.put(elf.DT.JMPREL, jmprel);
            d.put(elf.DT.PLTRELSZ, plt_bytes.len);
            d.put(elf.DT.PLTREL, elf.DT.RELA);
            d.put(elf.DT.PLTGOT, DATA);
        }
        if (b.init_at != 0) d.put(elf.DT.INIT, b.init_at);
        d.put(elf.DT.FLAGS, 8); // DF_BIND_NOW
        d.put(elf.DT.NULL, 0);
        const dynamic_size = d.at - dynamic;
        std.debug.assert(d.at <= DATA);

        // The parameter: its size, then Sony's magic at 8.
        const exe = b.kind.isExecutable();
        std.mem.writeInt(u64, out[PARAM..][0..8], 0x40, .little);
        std.mem.writeInt(u32, out[PARAM + 8 ..][0..4], if (exe) 0x4942_524f else 0x3c13_f4bf, .little);

        // The headers.
        @memcpy(out[0..4], "\x7fELF");
        out[4] = 2; // 64-bit
        out[5] = 1; // little-endian
        out[6] = 1;
        out[7] = 9; // FreeBSD
        out[8] = 2; // the PS5's ABI version
        std.mem.writeInt(u16, out[16..18], @intFromEnum(b.kind), .little);
        std.mem.writeInt(u16, out[18..20], 62, .little);
        std.mem.writeInt(u32, out[20..24], 1, .little);
        std.mem.writeInt(u64, out[24..32], b.entry, .little);
        std.mem.writeInt(u64, out[32..40], 64, .little); // e_phoff
        std.mem.writeInt(u16, out[52..54], 64, .little);
        std.mem.writeInt(u16, out[54..56], @sizeOf(elf.Phdr), .little);
        var ph = PhdrWriter{ .out = out };
        ph.put(elf.PT.LOAD, 5, 0, d.at, d.at, elf.PAGE);
        ph.put(elf.PT.LOAD, 6, DATA, DATA_SIZE, DATA_SIZE, elf.PAGE);
        ph.put(elf.PT.DYNAMIC, 4, dynamic, dynamic_size, dynamic_size, 8);
        ph.put(if (exe) elf.PT.SCE_PROCPARAM else elf.PT.SCE_MODULE_PARAM, 4, PARAM, 0x40, 0x40, 8);
        if (b.tls_seg) |t| ph.put(elf.PT.TLS, 4, t.vaddr, t.filesz, t.memsz, t.alignment);
        if (b.relro) |r| ph.put(elf.PT.GNU_RELRO, 4, r.vaddr, r.size, r.size, 1);
        std.mem.writeInt(u16, out[56..58], ph.count, .little);
        return out;
    }
};

const DynWriter = struct {
    out: []u8,
    at: u64,

    fn put(d: *DynWriter, tag: u64, val: u64) void {
        std.mem.writeInt(u64, d.out[d.at..][0..8], tag, .little);
        std.mem.writeInt(u64, d.out[d.at + 8 ..][0..8], val, .little);
        d.at += 16;
    }
};

const PhdrWriter = struct {
    out: []u8,
    count: u16 = 0,

    fn put(p: *PhdrWriter, kind: u32, flags: u32, vaddr: u64, filesz: u64, memsz: u64, alignment: u64) void {
        const h = elf.Phdr{ .type = kind, .flags = flags, .offset = vaddr, .vaddr = vaddr, .paddr = vaddr, .filesz = filesz, .memsz = memsz, .@"align" = alignment };
        @memcpy(p.out[64 + @as(usize, p.count) * @sizeOf(elf.Phdr) ..][0..@sizeOf(elf.Phdr)], std.mem.asBytes(&h));
        p.count += 1;
    }
};

fn w32(out: []u8, at: u64, v: u32) void {
    std.mem.writeInt(u32, out[at..][0..4], v, .little);
}

/// A whole small program in the PS5's format, with real code: it prints
/// `message` and exits, the way a game would.
///
///   write(1, message, len)      libkernel
///   sceVideoOutOpen()           libSceVideoOut (a library a loader's host
///                               may well not have: what happens then is
///                               the host's to show)
///   _exit(0)                    libkernel
///
/// Its three imports are bound through jump slots, and the message is
/// reached through a pointer the loader has to relocate, so running it
/// exercises a loader end to end. Should `_exit` return (it does not, on a
/// console), the program returns to whoever called its entry.
///
/// The code, at TEXT (rdi: the argument block, not used):
///   00  48 83 EC 08        sub  rsp, 8            ; the stack as a caller's
///   04  BF 01 00 00 00     mov  edi, 1
///   09  48 8B 35 ..        mov  rsi, [rip + ptr]  ; -> the message
///   10  BA ..              mov  edx, len
///   15  FF 15 ..           call [rip + write]
///   1B  FF 15 ..           call [rip + sceVideoOutOpen]
///   21  31 FF              xor  edi, edi
///   23  FF 15 ..           call [rip + _exit]
///   29  48 83 C4 08        add  rsp, 8
///   2D  C3                 ret
pub fn hello(buf: []u8, message: []const u8) []const u8 {
    const SLOT_WRITE = DATA + 0x00;
    const SLOT_EXIT = DATA + 0x08;
    const SLOT_VIDEO = DATA + 0x10;
    const POINTER = DATA + 0x18;
    const MESSAGE = DATA + 0x40;
    std.debug.assert(message.len <= 512);

    var b = Builder.init(buf, .dynexec);
    b.selfModule("eboot", 0);
    const kernel_module = b.neededModule("libkernel", 1);
    const kernel = b.importLibrary("libkernel", 1);
    const video_module = b.neededModule("libSceVideoOut", 2);
    const video = b.importLibrary("libSceVideoOut", 2);
    b.jumpSlot(SLOT_WRITE, b.importSymbol(nid.of("write"), kernel, kernel_module, elf.STT_FUNC));
    b.jumpSlot(SLOT_EXIT, b.importSymbol(nid.of("_exit"), kernel, kernel_module, elf.STT_FUNC));
    b.jumpSlot(SLOT_VIDEO, b.importSymbol(nid.of("sceVideoOutOpen"), video, video_module, elf.STT_FUNC));
    b.relative(POINTER, MESSAGE);

    var code = [_]u8{
        0x48, 0x83, 0xec, 0x08,
        0xbf, 0x01, 0x00, 0x00, 0x00,
        0x48, 0x8b, 0x35, 0, 0, 0, 0,
        0xba, 0, 0, 0, 0,
        0xff, 0x15, 0, 0, 0, 0,
        0xff, 0x15, 0, 0, 0, 0,
        0x31, 0xff,
        0xff, 0x15, 0, 0, 0, 0,
        0x48, 0x83, 0xc4, 0x08,
        0xc3,
    };
    // Each operand is relative to the address after its instruction.
    w32(&code, 0x0c, @intCast(POINTER - (TEXT + 0x10)));
    w32(&code, 0x11, @intCast(message.len));
    w32(&code, 0x17, @intCast(SLOT_WRITE - (TEXT + 0x1b)));
    w32(&code, 0x1d, @intCast(SLOT_VIDEO - (TEXT + 0x21)));
    w32(&code, 0x25, @intCast(SLOT_EXIT - (TEXT + 0x29)));

    var data = [_]u8{0} ** (0x40 + 512);
    @memcpy(data[0x40..][0..message.len], message);
    b.code = &code;
    b.data = data[0 .. 0x40 + message.len];
    b.entry = TEXT;
    return b.finish();
}

/// A game with a module of its own, as two files: `game` is the
/// executable, `gameModule` the module it brings (a loader finds it in
/// `sce_module` beside the executable). Together they exercise what a real
/// game's start does: the module's start function runs first, the
/// executable calls into the module, and the module reads a thread-local
/// variable.
///
/// The executable prints `message`, calls the module's `gameAnswer` and
/// exits with what it returned: GAME_ANSWER when the module's start
/// function ran (it stores GAME_STARTED) and its thread storage holds its
/// initial value (GAME_TLS).
///
/// The code, at TEXT (rdi: the argument block, not used):
///   00  48 83 EC 08        sub  rsp, 8
///   04  BF 01 00 00 00     mov  edi, 1
///   09  48 8B 35 ..        mov  rsi, [rip + ptr]  ; -> the message
///   10  BA ..              mov  edx, len
///   15  FF 15 ..           call [rip + write]
///   1B  FF 15 ..           call [rip + gameAnswer]
///   21  89 C7              mov  edi, eax
///   23  FF 15 ..           call [rip + _exit]
///   29  48 83 C4 08        add  rsp, 8
///   2D  C3                 ret
pub fn game(buf: []u8, message: []const u8) []const u8 {
    const SLOT_WRITE = DATA + 0x00;
    const SLOT_EXIT = DATA + 0x08;
    const SLOT_ANSWER = DATA + 0x10;
    const POINTER = DATA + 0x18;
    const MESSAGE = DATA + 0x40;
    std.debug.assert(message.len <= 512);

    var b = Builder.init(buf, .dynexec);
    b.selfModule("eboot", 0);
    const kernel_module = b.neededModule("libkernel", 1);
    const kernel = b.importLibrary("libkernel", 1);
    const game_module = b.neededModule(GAME_MODULE, 2);
    const game_library = b.importLibrary(GAME_MODULE, 2);
    b.jumpSlot(SLOT_WRITE, b.importSymbol(nid.of("write"), kernel, kernel_module, elf.STT_FUNC));
    b.jumpSlot(SLOT_EXIT, b.importSymbol(nid.of("_exit"), kernel, kernel_module, elf.STT_FUNC));
    b.jumpSlot(SLOT_ANSWER, b.importSymbol(nid.of(GAME_SYMBOL), game_library, game_module, elf.STT_FUNC));
    b.relative(POINTER, MESSAGE);

    var code = [_]u8{
        0x48, 0x83, 0xec, 0x08,
        0xbf, 0x01, 0x00, 0x00, 0x00,
        0x48, 0x8b, 0x35, 0, 0, 0, 0,
        0xba, 0, 0, 0, 0,
        0xff, 0x15, 0, 0, 0, 0,
        0xff, 0x15, 0, 0, 0, 0,
        0x89, 0xc7,
        0xff, 0x15, 0, 0, 0, 0,
        0x48, 0x83, 0xc4, 0x08,
        0xc3,
    };
    w32(&code, 0x0c, @intCast(POINTER - (TEXT + 0x10)));
    w32(&code, 0x11, @intCast(message.len));
    w32(&code, 0x17, @intCast(SLOT_WRITE - (TEXT + 0x1b)));
    w32(&code, 0x1d, @intCast(SLOT_ANSWER - (TEXT + 0x21)));
    w32(&code, 0x25, @intCast(SLOT_EXIT - (TEXT + 0x29)));

    var data = [_]u8{0} ** (0x40 + 512);
    @memcpy(data[0x40..][0..message.len], message);
    b.code = &code;
    b.data = data[0 .. 0x40 + message.len];
    b.entry = TEXT;
    return b.finish();
}

/// The module's name, the name it exports its function under, and what
/// that function returns when everything a loader owes it was done.
pub const GAME_MODULE = "libGame";
pub const GAME_SYMBOL = "gameAnswer";
pub const GAME_TLS: u32 = 7;
pub const GAME_STARTED: u32 = 5;
pub const GAME_ANSWER: u32 = GAME_TLS + GAME_STARTED;
/// Where the module's two functions are in it, and the word its start
/// function stores GAME_STARTED in.
pub const GAME_START_AT: u64 = TEXT;
pub const GAME_ANSWER_AT: u64 = TEXT + 0x30;
pub const GAME_STARTED_AT: u64 = DATA + 0x18;
/// The word a loader fills with the module's thread storage's place
/// (an offset from the thread pointer).
pub const GAME_TPOFF_AT: u64 = DATA + 0x10;

/// The module of `game`. Its start function (what the file's DT_INIT
/// names) prints `message` through its own import of `write`, stores
/// GAME_STARTED, and returns the first argument it was given (so a
/// loader's caller can tell its arguments arrived); `gameAnswer` adds the
/// stored number to the module's thread-local variable.
///
/// The start function, at TEXT (rdi: its first argument):
///   00  53                       push rbx                    ; (and the stack as a caller's)
///   01  89 FB                    mov  ebx, edi
///   03  BF 01 00 00 00           mov  edi, 1
///   08  48 8B 35 ..              mov  rsi, [rip + ptr]       ; -> the message
///   0F  BA ..                    mov  edx, len
///   14  FF 15 ..                 call [rip + write]
///   1A  C7 05 .. 05 00 00 00     mov  dword [rip + started], 5
///   24  89 D8                    mov  eax, ebx
///   26  5B                       pop  rbx
///   27  C3                       ret
/// gameAnswer, at TEXT + 0x30:
///   30  48 8B 05 ..              mov  rax, [rip + tpoff]     ; the variable, from the thread pointer
///   37  64 8B 00                 mov  eax, fs:[rax]
///   3A  03 05 ..                 add  eax, [rip + started]
///   40  C3                       ret
pub fn gameModule(buf: []u8, message: []const u8) []const u8 {
    return gameModuleNamed(buf, GAME_MODULE, message);
}

/// The same module under another name (several of them loaded side by
/// side: each has its own start function, variable and export).
pub fn gameModuleNamed(buf: []u8, name: []const u8, message: []const u8) []const u8 {
    const SLOT_WRITE = DATA + 0x00;
    const POINTER = DATA + 0x08;
    const MESSAGE = DATA + 0x40;
    const TLS_IMAGE = DATA + 0x400;
    std.debug.assert(message.len <= 512);

    var b = Builder.init(buf, .module);
    b.selfModule(name, 0);
    const kernel_module = b.neededModule("libkernel", 1);
    const kernel = b.importLibrary("libkernel", 2);
    const own = b.exportLibrary(name, 1);
    b.jumpSlot(SLOT_WRITE, b.importSymbol(nid.of("write"), kernel, kernel_module, elf.STT_FUNC));
    _ = b.exportSymbol(nid.of(GAME_SYMBOL), own, 0, GAME_ANSWER_AT, elf.STT_FUNC);
    b.relative(POINTER, MESSAGE);
    b.threadPointerOffset(GAME_TPOFF_AT, 0, 0);
    b.tls(TLS_IMAGE, 4, 8, 8);
    b.init_at = GAME_START_AT;

    var code = [_]u8{
        0x53,
        0x89, 0xfb,
        0xbf, 0x01, 0x00, 0x00, 0x00,
        0x48, 0x8b, 0x35, 0, 0, 0, 0,
        0xba, 0, 0, 0, 0,
        0xff, 0x15, 0, 0, 0, 0,
        0xc7, 0x05, 0, 0, 0, 0, 0, 0, 0, 0,
        0x89, 0xd8,
        0x5b,
        0xc3,
        0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc,
        0x48, 0x8b, 0x05, 0, 0, 0, 0,
        0x64, 0x8b, 0x00,
        0x03, 0x05, 0, 0, 0, 0,
        0xc3,
    };
    comptime std.debug.assert(code.len == 0x41);
    w32(&code, 0x0b, @intCast(POINTER - (TEXT + 0x0f)));
    w32(&code, 0x10, @intCast(message.len));
    w32(&code, 0x16, @intCast(SLOT_WRITE - (TEXT + 0x1a)));
    w32(&code, 0x1c, @intCast(GAME_STARTED_AT - (TEXT + 0x24)));
    w32(&code, 0x20, GAME_STARTED);
    w32(&code, 0x33, @intCast(GAME_TPOFF_AT - (TEXT + 0x37)));
    w32(&code, 0x3c, @intCast(GAME_STARTED_AT - (TEXT + 0x40)));

    var data = [_]u8{0} ** 0x408;
    @memcpy(data[0x40..][0..message.len], message);
    std.mem.writeInt(u32, data[0x400..0x404], GAME_TLS, .little);
    b.code = &code;
    b.data = &data;
    return b.finish();
}

/// Where a built file's dynamic section is (for tests that damage it).
pub fn dynamicOffset(file: []const u8) usize {
    const phnum = std.mem.readInt(u16, file[56..58], .little);
    for (0..phnum) |i| {
        const ph = file[64 + i * @sizeOf(elf.Phdr) ..];
        if (std.mem.readInt(u32, ph[0..4], .little) == elf.PT.DYNAMIC) return @intCast(std.mem.readInt(u64, ph[8..16], .little));
    }
    unreachable;
}
