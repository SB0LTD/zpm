//! @zpm/ps5 — PlayStation 5 programs as programs, in pure Sig: what a kernel
//! and a libkernel need to run a decrypted PS5 executable natively on an
//! x86-64 machine, with no emulator, no relinking step and no translation
//! of the program's code.
//!
//!   nid — the hashed names Sony's linker knows symbols by, and comptime
//!         export tables keyed by them;
//!   abi — the kernel's system call ABI (FreeBSD 11's amd64 convention,
//!         numbers, errno, flags and structures), with the conversions to
//!         the Linux-shaped services a host kernel already has;
//!   elf — an executable or module read as a file (the PS5's dialect and
//!         the PS4's): segments, tables, the modules and libraries named;
//!   link — modules loaded into one address space and bound to each other
//!         and to the host's own libraries by NID, with thread storage;
//!   fixture — small PS5 files made in memory, for tests;
//!   sys — the system calls as a program makes them (x86-64);
//!   libkernel — the PS5's kernel library in Sig: files, memory, time, the
//!         process (a first set);
//!   runtime — the program a kernel starts for a PS5 executable: it loads
//!         and links the game in its own process and jumps to it.
//!
//! No Sony code, keys or firmware: the formats are documented in public
//! (FreeBSD's sources, open loaders), and the input is a program its owner
//! dumped and decrypted themselves. Open projects that load such programs
//! (shadPS4, Kyty, RPCSX, AnyPS5) were read as documentation only.
//!
//! Allocation-free throughout: fixed tables and caller-provided storage.

pub const nid = @import("nid.sig");
pub const abi = @import("abi.sig");
pub const elf = @import("elf.sig");
pub const link = @import("link.sig");
pub const fixture = @import("fixture.sig");
// (x86-64 only: they are that CPU's instructions. Nothing above needs them.)
pub const sys = @import("sys.sig");
pub const libkernel = @import("libkernel.sig");
pub const runtime = @import("runtime.sig");

test {
    _ = nid;
    _ = abi;
    _ = elf;
    _ = link;
    _ = fixture;
    if (@import("builtin").cpu.arch == .x86_64) {
        _ = libkernel;
        _ = runtime;
    }
}
