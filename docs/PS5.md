# PlayStation 5 programs in pure Sig

`src/ps5/` is what a kernel and a libkernel need to run a decrypted PS5 executable natively on an x86-64 computer: no emulator, no relinking step, no translation of the program's code. A PS5 is an x86-64 machine, so the code runs as it is. What has to be supplied is what the code talks to: a kernel that answers its system calls, and libraries bound by Sony's hashed names.

This is the groundwork: the names, the kernel's ABI, and a loader that reads PS5 files and binds them. Not here yet: the libraries a game imports (libkernel first) and anything about graphics. Galaxy's kernel uses `abi.sig` for its PS5 personality (`src/kernel/galaxy_ps5.sig` there). Nothing uses the loader yet; it has been run only on files its own tests make, never on a real game.

Everything is allocation-free: plain values, comptime tables, caller-provided buffers.

## The files

| File | What it is |
|---|---|
| `nid.sig` | NIDs: the 64-bit hashed names Sony's linker knows symbols by. Hash a name, write and parse the eleven-character text, take an imported symbol's name apart (`NID#library#module`), and build a sorted export table at comptime from plain names. |
| `abi.sig` | The PS5 kernel's system call ABI as data: the convention, every call's number and name, FreeBSD's errno values, open and mmap flags, clock ids, the structures (`struct stat`, directory entries, `thr_param`, `_umtx_time`), and the conversions to the values a Linux-shaped kernel service takes. |
| `elf.sig` | A PS5 (or PS4) executable or module read as a file: segments, thread storage, the dynamic tables, and the modules and libraries it names. A view of the file's bytes with every offset checked. |
| `link.sig` | The linker: modules given addresses, copied in, their exports entered in one table keyed by NID, their relocations applied and imports bound, thread storage laid out. |
| `fixture.sig` | Small PS5 files made in memory, for the tests. |
| `ps5.sig` | The module root. |

## NIDs

A PS5 program does not import `sceKernelUsleep`. It imports `1jfXLRVzisc#A#B`: the NID, then which of the file's libraries and modules the symbol comes from.

- **The hash:** SHA-1 over the name followed by a fixed 16-byte salt. The first eight bytes of the digest, read little-endian, are the NID.
- **The text:** those 64 bits, most significant first, in base64 with `+` and `-` as the last two digits. Eleven characters, no padding.
- **The indexes** after each `#` are numbers in the same digits, most significant first (`A` is 0, `B` is 1, `BA` is 64).

`nid.of("name")` also runs at comptime, so a library written in Sig lists its exports by name and ships a table of 64-bit keys:

```zig
const exports = nid.Table(*const anyopaque, &.{
    .{ "sceKernelUsleep", &usleep },
    .{ "sceKernelGetpid", &getpid },
});
const f = exports.find(wanted_nid); // a binary search over the keys
```

Two names that hash to the same NID are a compile error.

## The system call ABI

The PS5's kernel descends from FreeBSD 11, and a program's side of it is FreeBSD's amd64 convention:

- `syscall`, with the number in `rax` and arguments in `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`;
- the result in `rax`;
- an error is the **carry flag** set and a positive errno in `rax` (Linux returns a negative number, and numbers its errors differently above 34);
- calls 0 and 198 are indirect: the real number is the first argument.

`abi.sig` has:

- **`Sys`**: every call by name, FreeBSD's up to 531, Sony's from 532 to 676, and the PS5's additions up to 722. `sysName(nr)` gives the name back, so a kernel can say which call a program wanted.
- **`E`** and `errnoFromLinux`: FreeBSD's errno values, and each Linux errno as FreeBSD's. `resultFromLinux` turns a Linux-style result into `rax` and the carry flag.
- **Flags:** `openFlagsToLinux` (for Linux's x86-64 or generic bits), `mmapToLinux` (FreeBSD's flags, Sony's `MAP_NO_OVERWRITE` and `MAP_VOID`, the alignment field, the GPU protection bits), `clockToLinux`.
- **Structures** in FreeBSD 11's amd64 layout: `Stat` (120 bytes), directory entries (`writeDirent`), `ThrParam` (104 bytes, with Sony's name pointer), `UmtxTime`, and the `_umtx_op`, `sysarch` and `__sysctl` constants.
- **`PAGE`**: 16 KiB, the granule the PS5's kernel maps a program's memory in.

## Reading a file

A decrypted `eboot.bin` or `.prx` is an x86-64 ELF with FreeBSD's OS ABI byte and one of Sony's file types. `elf.Image.parse(bytes)` reads either console's dialect:

| | PS5 | PS4 |
|---|---|---|
| Dynamic tables (strings, symbols, relocations) | in ordinary load segments, under the standard tags; values are addresses in the module | in a file-only segment (`PT_SCE_DYNLIBDATA`), under `DT_SCE_*` tags; values are offsets into it |
| Module and library names | `DT_SCE_*_1` tags (0x61000043 to 0x61000049) | the older tags (0x6100000D to 0x61000015) |

A file that mixes the two is refused. A header or table that points outside the file is an error, never a read outside the buffer; the tests feed it every truncation of a file.

`Image.linked(symbol)` turns a symbol's `NID#library#module` name into the NID and the two names the ids stand for.

## Loading and linking

```zig
var linker = link.Linker.init(host, .{ .modules = &modules, .libraries = &names, .exports = &table });
_ = try linker.load("eboot.bin", eboot_bytes);
_ = try linker.load("libc.prx", libc_bytes);
try linker.link();
```

- **`load`** asks the host for addresses, copies the segments there and enters the module's exports.
- **`link`** applies the relocations of every module loaded since the last link, then sets each segment's final protection.
- **An import** is looked up by NID and library name, in this order:
  1. the loaded modules' exports (a game's own copy of a library wins);
  2. the host's own libraries (`Host.builtin`: system libraries written natively);
  3. `Host.missing`, which may return a stand-in (a stub that reports the call). If it returns nothing, the link fails.
- **A weak import** nobody has is 0.
- **Binding is eager**: all of it happens in `link`, none on a first call.
- **Thread storage** is x86-64's (variant II). Each module with thread-local data gets an index and a place below the thread pointer; `staticTls()` says how much a thread needs and `initTls(tp)` fills one thread's.

The host supplies four functions: `reserve` (zeroed writable memory at a multiple of 16 KiB), `protect`, `builtin` and `missing`. The linker writes into the address space it runs in.

## Sources

- FreeBSD 11.0's sources (BSD licence): the convention, the base numbers, the structures.
- The file format: the ELF and System V ABI documents. Sony's types and tags come from open loaders and tools, cross-checked against each other (shadPS4, Kyty, RPCSX, sce-elf, the OpenOrbis toolchain's notes, AnyPS5's docs).
- Sony's call numbers: two independent open reimplementations of the kernel (RPCSX and fpPS4) list the same numbers from 99 to 676. The PS5's additions (677 to 722) come from RPCSX alone.
- The NID algorithm and salt are public and carried by every open tool for these files. The test vectors are names whose NIDs are widely published.

Open projects were read as documentation only. There is no Sony code, key or firmware here, and nothing decrypts anything: the input is a program its owner dumped and decrypted themselves.

## Testing

```bash
sig build test-ps5
```

The tests hash published names to their NIDs, check the structures' sizes and offsets against FreeBSD 11's, and check each conversion. For the loader they build an executable and a module in memory, load and link them, and check every bound word and the thread storage. Galaxy's twin test (`galaxy/bench/test-ps5.sh` there) runs a program that makes the system calls for real.

What the tests cannot show: that a real game's files load. The reader and linker follow what open loaders document, and no retail file has been through them.
