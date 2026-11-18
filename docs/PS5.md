# PlayStation 5 programs in pure Sig

`src/ps5/` is what a kernel and a libkernel need to run a decrypted PS5 executable natively on an x86-64 computer: no emulator, no relinking step, no translation of the program's code. A PS5 is an x86-64 machine, so the code runs as it is. What has to be supplied is what the code talks to: a kernel that answers its system calls, and libraries bound by Sony's hashed names.

What is here: the names, the kernel's ABI, a loader that reads PS5 files and binds them, a first libkernel with threads, their locks and event queues, the display library, the GPU's command packets with a first driver for them, the graphics library that writes those packets, and the runtime that puts them together. A small program in the PS5's format loads, prints and exits; one with a module of its own starts that module and calls into it; one shows frames it drew itself in a window, paced by the screen. All of that runs in tests here and on Galaxy's kernel. Not here: a renderer (draw commands are written, read and counted, and nothing draws them yet), shaders, sound, the controller, and the console's other system modules. No real game runs.

Galaxy's kernel uses `abi.sig` for its PS5 personality (`src/kernel/galaxy_ps5.sig` there), and its PS5 runtime binary is `runtime.sig` with a `_start`.

Everything is allocation-free: plain values, comptime tables, caller-provided buffers.

## The files

| File | What it is |
|---|---|
| `nid.sig` | NIDs: the 64-bit hashed names Sony's linker knows symbols by. Hash a name, write and parse the eleven-character text, take an imported symbol's name apart (`NID#library#module`), and build a sorted export table at comptime from plain names. |
| `abi.sig` | The PS5 kernel's system call ABI as data: the convention, every call's number and name, FreeBSD's errno values, open and mmap flags, clock ids, the structures (`struct stat`, directory entries, `thr_param`, `_umtx_time`), and the conversions to the values a Linux-shaped kernel service takes. |
| `elf.sig` | A PS5 (or PS4) executable or module read as a file: segments, thread storage, the dynamic tables, and the modules and libraries it names. A view of the file's bytes with every offset checked. |
| `link.sig` | The linker: modules given addresses, copied in, their exports entered in one table keyed by NID, their relocations applied and imports bound, thread storage laid out. |
| `fixture.sig` | Small PS5 files made in memory, for the tests. `hello()` is a whole program with real code: it prints through an imported `write`, calls a library a host may not have, and exits. `game()` and `gameModule()` are an executable and the module it brings: the module has a start function and a thread-local variable, and the executable exits with what the module's function returns. |
| `sys.sig` | The system calls as a program makes them: the number in `rax`, the carry flag folded into a negative errno. x86-64 only. |
| `libkernel.sig` | The PS5's kernel library in Sig, a first set: files, sleeps, clocks, memory, the process, the stack protector's canary, `__tls_get_addr`, and modules loaded by path (`sceKernelLoadStartModule`, `sceKernelDlsym`). With `pthread.sig` and `equeue.sig`, 214 names. |
| `pthread.sig` | libkernel's threads and what they wait on: threads and their attributes, mutexes, condition variables, read-write locks, thread-specific keys, once. Each under its POSIX name and Sony's. |
| `equeue.sig` | libkernel's event queues: what a game waits on to hear of a flip, a GPU interrupt, a timer, or a word from another of its threads. Kept in the process. |
| `videoout.sig` | The display library (libSceVideoOut): buffers, flips paced by a clock thread that stands in for the screen's refresh, flip and vblank events, the PS4's and the PS5's calls. Where frames go is the host's (`display`). |
| `pm4.sig` | The PS5 GPU's command packets as data (AMD's PM4): headers, opcodes, the three register banks, a reader that checks every length, a writer. |
| `agc.sig`, `agc_*.sig` | The graphics library (libSceAgc): 203 names. A game's calls for registers, draws, flow, memory and sync, flips and markers each write their packet into the game's command buffer; the patch calls and size queries go with them. `agc_shader.sig` is a shader object as a game holds it: the call that makes one usable, the list of those made, and the calls that link a vertex-side shader to a pixel shader. Not its register-default tables. |
| `agcdriver.sig` | The graphics driver library (libSceAgcDriver), a first part: a game's submitted command buffers are carried out in order by a worker thread. Registers, labels, interrupts, waits, skips, calls and flips happen; draws are handed to a renderer that is not here yet. |
| `runtime.sig` | The program a kernel starts for a PS5 executable. It loads and links the game and the modules it brought in its own process, binds imports to libkernel or to a stand-in that names what is missing, makes the first thread's storage, runs the modules' start functions and jumps to the game. |
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
  3. `Host.missing`, which is told the library, module, NID, whether it is a function or an object, and its size, and may return a stand-in (a stub that reports the call, or zeroed storage for an object). If it returns nothing, the link fails.
- **A symbol the module defines itself**, or a local one, is the module's own address and is never looked up.
- **A symbol with a plain name** (no `NID#library#module`) is looked up by the NID its name hashes to.
- **A weak import** nobody has is 0.
- **Binding is eager**: all of it happens in `link`, none on a first call.
- **Thread storage** is x86-64's (variant II). Each module with thread-local data gets an index and a place below the thread pointer, at an address that agrees with the segment's own alignment; `staticTls()` says how much a thread needs and `initTls(tp)` fills one thread's.
- **The part a file marks read-only after relocation** (`PT_GNU_RELRO`, `PT_SCE_RELRO`) is made so once the relocations are in.
- **A load that fails** gives its addresses back (`Host.release`) and leaves the tables as they were.

The host supplies five functions: `reserve` (zeroed writable memory at a multiple of 16 KiB), `release`, `protect`, `builtin` and `missing`. The linker writes into the address space it runs in.

## The runtime and libkernel

`runtime.start(ap)` is a PS5 process's whole start. A host gives it FreeBSD's argument block; `argv[1]` is the executable.

1. It maps the executable and every `.prx` in `sce_module` beside it (in name order), and runs the linker with libkernel as `builtin`. A file still encrypted as the console stores it is named and left out. A module that cannot be linked is named and left out; the executable that cannot be is the end.
2. For a function nothing provides, `missing` writes a **stand-in**: 16 bytes of code that load the import's number and jump to one routine, which prints `not implemented: library:NID was called` once and returns 0. A game that only passes through such a call carries on, and the log lists what it wanted. For an object nothing provides it hands out zeroed storage of the object's size (code there would be read as data), and names it in the log.
3. It maps the first thread's storage, with FreeBSD's control block at the thread pointer (`fs:0` is its own address), and sets FS. Every thread's storage has 1 MiB to spare, so a module loaded later finds its place in threads already running.
4. It maps the game's stack: the size the executable's process parameters ask for (2 MiB if they do not say), with a page below it that faults. The arguments are copied onto it as FreeBSD lays them out (`argc`, `argv`, an empty environment).
5. On that stack it runs each module's start function (the file's `DT_INIT`, called with no arguments), a module after the modules it says it needs, then jumps to the entry with `rdi` the argument block and `rsi` a clean-up function.

libkernel's functions are ordinary Sig functions with the C calling convention, listed in one comptime table keyed by NID. POSIX names answer -1 and `errno`; `sceKernel` names answer `0x80020000 + errno`. Both `libkernel` and `libScePosix` resolve to the same table. A game's `/app0` is the folder its executable is in.

These files make system calls, so they run only under a kernel that speaks the PS5's ABI. Their tests here cover what does not: the export table, error encoding, path mapping, a stand-in's bytes, the layouts, and a lock's word when nobody else wants it. Galaxy's twin test runs the rest for real.

## Threads and locks

`pthread.sig` is FreeBSD's thread library as a PS5 program sees it, on three things a kernel gives: `thr_new`, `thr_exit`, and `_umtx_op`'s plain wait and wake.

- **A lock lives in user memory.** One nobody else holds is taken and given back with a compare-and-swap and no system call (about 15 ns for the pair in Galaxy's twin). A thread enters the kernel only to sleep, or to wake one that does.
- **A handle is a pointer the library fills in**, as on the console: 0 is a static initialiser, and the object is made on first use. Objects come from a pool of 64-byte slots mapped 64 KiB at a time; a slot given back is used again.
- **Two faces for each call:** `pthread_*` answers 0 or an errno, `scePthread*` answers 0 or `0x80020000 + errno`.
- **Mutexes:** FreeBSD's four types, checked for their owner as FreeBSD's are (the default is the error-checking one). An adaptive one is watched for a moment before its waiter sleeps.
- **A thread** is one mapping: a guard page, its stack, its thread storage, its control block and state. A joined thread's goes back when the kernel says the thread is gone; a detached one's when later threads are made.
- **A handle of a thread is looked up, never read through**: one that names a thread long gone answers ESRCH, as FreeBSD's does.
- **Not here:** cancelling a thread (its state and type are kept; nothing cancels), signals to a thread, priority inheritance and ceilings (the attributes are kept and read back), process-shared objects, semaphores, Sony's event flags.
- **A library's own threads** (the display's clock, the GPU's worker) are not counted among the program's: the process ends when the program's last thread does.

A kernel whose wake wakes every waiter (Galaxy's does) makes a contended lock cost more than it should; the code is correct either way.

## Modules loaded while the game runs

`sceKernelLoadStartModule(path, args, argp, ...)` maps the file, loads and links it, fills its thread storage in every thread there is, and calls its start function with the arguments. The handle is the module's index (the same one when the file is loaded already). A bare name is looked for in the game's `sce_module`. `sceKernelDlsym(handle, name, &address)` finds what a module exports under a plain name.

Stand-ins made after the first ones became code go in a page of their own, so no page a thread may be running in is ever writable again.


## Event queues

On the console an event queue is the kernel's kqueue. Here it is kept in the process (`equeue.sig`), because everything that posts to one is in the process too: the display, the GPU's queue, the game's own threads, timers.

- **A queue** is one mapping with room for about a thousand events. A game's handle is its address, looked up among the queues there are before anything is read through it. A deleted queue's memory goes back when the last thread inside it has left; a thread waiting on it comes back with `EBADF`.
- **A post** is a few instructions under a lock, and enters the kernel only when a thread is asleep on the queue. A wait that finds an event ready does not enter it at all (71 ns for a post and a read in Galaxy's twin).
- **User events** are FreeBSD's: one added plain stays ready for every reader until it is deleted, one added "edge" is read once per post.
- **Timers:** a repeating one counts the times it ran out since it was read; a one-time one is gone once read. No thread runs them: the wait itself looks at the clock.
- **Other libraries post** through `add`, `post` and `remove` (the display's flips and vblanks, the GPU's interrupts).
- **Not here:** events on files and sockets, which need the kernel's own queue.

## The display

`videoout.sig` is libSceVideoOut. A game opens the display, registers buffers (the PS4's way with 32-bit format codes, or the PS5's with 64-bit ones and groups it names), submits flips, and waits on an event queue for each.

- **A clock thread stands in for the screen's refresh** (59.94 Hz). At each tick it counts a vblank and takes the oldest waiting flip, at the rate the game set. So a game that waits for its flips runs at the screen's rate: 60 frames took 0.994 to 0.999 s in the twin.
- **Where a frame goes** is the host's: `display` (open, a place to write the frame, show, close). With none, flips and their events still happen.
- **Where a frame comes from:** the buffer's own memory when the game's code drew it (rows of pixels, each of the six formats converted to 8 bits a colour), or `source` when the GPU path did.
- **A buffer's memory is read only while its flip is shown.** `sceVideoOutUnregisterBuffers` and `sceVideoOutClose` wait for a flip in progress to finish, so that when they return the memory is the game's to unmap. Flips of those buffers still waiting become flips of no picture: they happen, with their events, and show nothing.
- **The flip status** is written as the game's console lays it out: 128 bytes for a PS5 game, 64 for one that registered its buffers the PS4's way.
- **Events** carry 12 bits of time, a count of how often they happened since they were read (stopping at 15), and 48 bits of their own: a flip's argument, a vblank's number.
- **Not here:** stereo, the cursor, HDR output (10-bit and float buffers are shown as 8-bit), the other outputs, flips triggered by the GPU's end of pipe. The event's identity in the queue is this library's own choice (a game asks `sceVideoOutGetEventId`); what a console puts there is not established. Giving back the group of buffers that is on the screen succeeds here; one open project answers "busy" for it.

## The GPU's commands

A game does not write GPU commands itself. It calls the graphics library (libSceAgc), which writes AMD PM4 packets into a buffer the game owns, and hands the buffer to the driver (libSceAgcDriver). Both are console system modules, so both are this module's to provide. `pm4.sig` is the format; `agc.sig` is the library, as far as writing packets goes; `agcdriver.sig` is a first part of the driver.

- **The library writes into the game's own buffer** (`CommandBuffer`: a bottom, a top, a cursor that climbs), asks the game's callback for room when it runs out, and writes nothing when there is none. Data a call points at inside that same buffer is read before the packet is written over it. Each call's packet is the one the driver reads: the tests build buffers with the library's functions, found by NID, and run them through the driver.
- **Missing from the library:** the tables of register defaults a game asks for at start (`sceAgcGetRegisterDefaults` and its kin), and joining two halves of a shader (`sceAgcFuseShaderHalves`).

### Shaders

A game's shader is two things it loaded itself: a header with tables after it (`agc.shader.Shader`: registers to set, what the shader reads and writes, where its resources are), and the machine code, which is AMD's (LLVM's `gfx1013`; `src/amdgpu/gfx10.sig` decodes it).

- **`sceAgcCreateShader`** turns the header's pointers, which in a file are offsets from their own fields, into addresses; writes the code's address into the header's own register list (the pair of program registers a game later puts in a command buffer); and lists the shader under that address. A renderer finds a draw's shaders by what the program registers hold (`agc.shader.byCode`).
  - Everything that can refuse comes before the first write: a refused header is left as it was.
  - A shader made again with its code somewhere else keeps its tables, has its program registers moved by as much as the code moved, and is found at the new address only.
  - The list holds 12,288 shaders. Past that a shader is still created, and not found.
- **`sceAgcCreatePrimState`, `sceAgcUpdatePrimState`:** the registers that say which stages run and what they hand the rasteriser, from the shaders' own special registers and the kind of primitive.
- **`sceAgcCreateInterpolantMapping`, `sceAgcUpdateInterpolantMapping`, `sceAgcLinkShaders`:** the thirty-two registers that say which output of the vertex side each input of the pixel shader reads, matched by semantic; an input nothing writes reads its default.
- **`sceAgcGetGsOversubscription`** answers the most room for any budget but 0. A console works the amount out; nothing here reads the two registers.
- The header stays the game's memory and is read whenever its shader is looked up, as the GPU reads the register lists in it.
- What these calls write was checked against an open implementation bit by bit (33 million combinations for the pixel-input registers, by the independent reviewer).

## Drawing (`src/ps5gfx/`, begun)

The driver hands each draw to a renderer. That renderer is to be `src/ps5gfx/`, a module above `ps5` and zpm's 3D engine (`gfxapi`): the same engine on a PC's GPU, a phone's, or the CPU. So far it has three parts:

- **`state.sig`** reads a draw's registers as values a renderer can use: each colour target (address, size, the layout of a pixel, its tiling), the depth target and test, blending, the viewport and every scissor (with the window's offset), the rasteriser's mode, where the vertex-side and pixel shaders are and the words a game gave them, where each pixel-shader input comes from, and the registers a pixel shader's built-in values arrive in. It guesses nothing: a state it cannot make sense of is null, or kept as its raw code for the renderer to refuse and name. Every register number and field in it was checked by an independent reviewer against AMD's public headers for this GPU family.
- **`draw.sig`** puts those values in the engine's terms. The engine's window counts rows from the bottom, so a viewport and a scissor are turned over (the picture is the same either way up, and so is which way round a triangle goes); blend factors become the engine's linear forms; a write mask becomes the bits of a pixel a draw leaves alone. Where the engine has nothing to match (rectangles and quads, the two-colour blend factors) the answer is null.
- **`target.sig`** keeps the pictures a game draws into as the engine's images, found by the address a game names a target by: made black on first use, made anew when a game changes what is at an address, the one unused longest given up when there are thirty-two. The display asks for a frame by the same address and gets it as it takes one (rows from the top, 0xAARRGGBB). The game's own bytes at that address are not written: a game that reads its target's memory on the CPU finds nothing drawn there.

Not yet: the shaders' machine code recompiled, and anything drawn. `sig build test-ps5gfx` runs its tests.

- **A submit call returns at once.** A worker thread stands in for the GPU's command processor and reads the buffer packet by packet, straight from the game's memory, as the GPU would.
- **Registers** are kept in three banks (shader, context, user configuration) with the values a queue starts with; the context registers can be cleared, put aside and brought back.
- **Draws** (plain, indexed, from an offset, indirect, several indirect records in one packet) are handed to `renderer` with the state before them. With no renderer they are counted and said once.
- **Labels and interrupts:** what the GPU writes to memory in passing (`RELEASE_MEM`, `WRITE_DATA`, `COPY_DATA`, `DMA_DATA`) is written in the buffer's order, after the renderer has finished what came before. An interrupt reaches the game through an event queue (`sceAgcDriverAddEqEvent`), with the number the game gave it.
- **Flow:** the queue stands still at `WAIT_REG_MEM` until memory compares as asked, skips what `COND_EXEC` says, calls into other buffers (`INDIRECT_BUFFER`, sixteen deep), waits at `REWIND` for the game to finish the buffer, and honours a predicate read from memory. `COND_WRITE` writes its word when memory compares as asked.
- **A flip in a command buffer** is one of two packets that are this library pair's own (a NOP with a sub-type): it goes to the display after what was drawn before it. It counts as pending from the moment its buffer is submitted, and a flip the game's own code asks for (`sceVideoOutSubmitFlip`) goes behind the buffers already waiting.
- **A buffer that calls or follows itself without end** is left after 2^26 words of packets, as a GPU would hang on it; the queue goes on to the next submission.
- **A packet this does not carry out** is named once in the log and stepped over; a word that is no packet ends its buffer.
- **Not here:** compute queues, `DRAW_INDEX_MULTI_INST`, the fourteen-word conditional branch, stream-out, the GDS and constant RAM, occlusion predicates, semaphores, flips at the end of pipe.

## Sources

- FreeBSD 11.0's sources (BSD licence): the convention, the base numbers, the structures.
- The file format: the ELF and System V ABI documents. Sony's types and tags come from open loaders and tools, cross-checked against each other (shadPS4, Kyty, RPCSX, sce-elf, the OpenOrbis toolchain's notes, AnyPS5's docs).
- Sony's call numbers: two independent open reimplementations of the kernel (RPCSX and fpPS4) list the same numbers from 99 to 676. The PS5's additions (677 to 722) come from RPCSX alone.
- The NID algorithm and salt are public and carried by every open tool for these files. The test vectors are names whose NIDs are widely published.

- The display library's calls, numbers and structures: shadPS4 and AnyPS5, which agree except where the text above says so. The GPU's packets: AMD's PM4 as the Linux kernel's and Mesa's headers give it, and the PS5's use of it as AnyPS5's driver documents it.

Open projects were read as documentation only. There is no Sony code, key or firmware here, and nothing decrypts anything: the input is a program its owner dumped and decrypted themselves.

## Testing

```bash
sig build test-ps5
```

The tests hash published names to their NIDs, check the structures' sizes and offsets against FreeBSD 11's, and check each conversion. For the loader they build an executable and a module in memory, load and link them, and check every bound word and the thread storage. On an x86-64 Linux host one test goes further: it loads the hello program into executable memory, binds its imports to functions in the test, and calls its entry, so a file in the PS5's format really runs. Galaxy's twin test (`galaxy/bench/test-ps5.sh` there) runs a program that makes the system calls for real.

The event queues, the display and the driver are tested here with no kernel under them: a queue in the test's own memory, the display's clock turned by hand, the test as the GPU's worker. What needs threads that sleep and a real clock (a wait woken by a post, flips at the screen's rate, the queue standing still at a wait) is in Galaxy's twin test.

What the tests cannot show: that a real game's files load. The reader and linker follow what open loaders document, and no retail file has been through them.
