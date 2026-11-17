//! @zpm/ps5 sys — the PS5 kernel's system calls as a program makes them:
//! FreeBSD's amd64 convention (the number in rax, arguments in rdi, rsi,
//! rdx, r10, r8, r9, an error as the carry flag with a positive errno in
//! rax). What code that runs under that kernel ABI is built on: the
//! libkernel here, the runtime, a kernel's own test of its personality.
//!
//! `call` folds the carry flag into the value, so a caller tests one
//! register: a result, or the errno negated (FreeBSD's numbers: abi.sig
//! names them). x86-64 only: the convention is that CPU's.

pub inline fn call(nr: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    return asm volatile (
        \\ syscall
        \\ jnc 1f
        \\ neg %%rax
        \\ 1:
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
          [a3] "{r10}" (a3),
          [a4] "{r8}" (a4),
          [a5] "{r9}" (a5),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

/// The same call as the instruction leaves it: rax, and whether the carry
/// flag was set (to test the convention itself).
pub const Raw = struct { rax: u64, carry: bool };

pub inline fn raw(nr: u64, a0: u64, a1: u64, a2: u64) Raw {
    var cf: u64 = 0;
    const rax = asm volatile (
        \\ syscall
        \\ setc %%cl
        \\ movzbl %%cl, %%ecx
        : [ret] "={rax}" (-> u64),
          [cf] "={rcx}" (cf),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
        : .{ .r11 = true, .memory = true });
    return .{ .rax = rax, .carry = cf != 0 };
}

/// A call made through the indirect one (number 0), all six arguments: the
/// real number goes first, the arguments move up a register, and the sixth
/// is on the stack above a return address's slot, where FreeBSD's kernel
/// reads it. (The stack pointer moves past the red zone first, and comes
/// back with `lea`, which leaves the carry flag as the call set it.)
pub inline fn indirect(nr: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    return asm volatile (
        \\ sub $144, %%rsp
        \\ mov %[a5], 8(%%rsp)
        \\ syscall
        \\ lea 144(%%rsp), %%rsp
        \\ jnc 1f
        \\ neg %%rax
        \\ 1:
        : [ret] "={rax}" (-> i64),
        : [zero] "{rax}" (@as(u64, 0)),
          [nr] "{rdi}" (nr),
          [a0] "{rsi}" (a0),
          [a1] "{rdx}" (a1),
          [a2] "{r10}" (a2),
          [a3] "{r8}" (a3),
          [a4] "{r9}" (a4),
          [a5] "{rbx}" (a5),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

/// The word FS points at (a thread's control block starts with it).
pub inline fn fs0() u64 {
    return asm volatile ("movq %%fs:0, %[r]"
        : [r] "=r" (-> u64),
    );
}

/// The third word FS points at: where a thread's control block keeps the
/// pointer to its own state (FreeBSD's layout). Only once FS is set.
pub inline fn fs16() u64 {
    return asm volatile ("movq %%fs:16, %[r]"
        : [r] "=r" (-> u64),
    );
}

/// The CPU's time stamp counter.
pub inline fn rdtsc() u64 {
    var hi: u32 = undefined;
    const lo = asm volatile ("rdtsc"
        : [lo] "={eax}" (-> u32),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}
