//! Bare-metal AArch64 test runner for QEMU's `virt` board, so freestanding
//! core modules can run their own `test` blocks on emulated AArch64 from an
//! x86 host (no AArch64 machine, Linux or user-mode QEMU needed).
//!
//! QEMU loads the ELF at its link address (RAM starts at 0x40000000) and
//! enters `_start` at EL1. The runner enables FP/SIMD, maps the first 1 GiB
//! as device memory (the PL011 UART) and the second as cacheable RAM (NEON
//! code makes unaligned accesses, which fault while the MMU is off), runs
//! every test, prints to the UART and exits QEMU through semihosting with 0
//! when all passed, 1 on a failure and 3 on a panic or CPU exception.
//!
//! Build and run: tools/aarch64_qemu/run.ps1.
const std = @import("std");
const builtin = @import("builtin");

// Level-1 blocks: 0-1 GiB device (MAIR attr 0), 1-2 GiB normal write-back
// (attr 1), inner shareable, access flag set. TCR: T0SZ 25 (walks start at
// level 1), write-back walks, 4 KiB granule, TTBR1 walks off, 40-bit physical
// addresses. SCTLR: MMU, data and instruction caches on, alignment checks off.
comptime {
    asm (
        \\.section .text._start, "ax"
        \\.global _start
        \\_start:
        \\  adrp x0, runner_stack_top
        \\  add x0, x0, :lo12:runner_stack_top
        \\  mov sp, x0
        \\  adrp x0, runner_vectors
        \\  add x0, x0, :lo12:runner_vectors
        \\  msr vbar_el1, x0
        \\  mrs x0, cpacr_el1
        \\  orr x0, x0, #(3 << 20)
        \\  msr cpacr_el1, x0
        \\  isb
        \\  adrp x1, runner_level1
        \\  mov x2, #0x401
        \\  str x2, [x1]
        \\  mov x2, #0x705
        \\  movk x2, #0x4000, lsl #16
        \\  str x2, [x1, #8]
        \\  mov x2, #0xff00
        \\  msr mair_el1, x2
        \\  mov x2, #0x3519
        \\  movk x2, #0x80, lsl #16
        \\  movk x2, #0x2, lsl #32
        \\  msr tcr_el1, x2
        \\  msr ttbr0_el1, x1
        \\  dsb sy
        \\  tlbi vmalle1
        \\  dsb sy
        \\  isb
        \\  mrs x0, sctlr_el1
        \\  mov x2, #0x1005
        \\  orr x0, x0, x2
        \\  bic x0, x0, #2
        \\  msr sctlr_el1, x0
        \\  isb
        \\  bl runnerMain
        \\1:
        \\  b 1b
        \\
        \\.section .text.runner_vectors, "ax"
        \\.balign 2048
        \\runner_vectors:
        \\.irp kind, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        \\  mov x0, #\kind
        \\  mrs x1, esr_el1
        \\  mrs x2, elr_el1
        \\  mrs x3, far_el1
        \\  bl runnerException
        \\.balign 128
        \\.endr
        \\
        \\.section .bss.runner_stack, "aw", @nobits
        \\.balign 4096
        \\runner_level1:
        \\  .space 4096
        \\runner_stack_bottom:
        \\  .space 0x400000
        \\runner_stack_top:
    );
}

const uart: *volatile u32 = @ptrFromInt(0x0900_0000);

fn write(text: []const u8) void {
    for (text) |byte| {
        if (byte == '\n') uart.* = '\r';
        uart.* = byte;
    }
}

fn writeNumber(value: u64, comptime base: u8) void {
    var digits: [20]u8 = undefined;
    var index = digits.len;
    var rest = value;
    while (true) {
        index -= 1;
        digits[index] = "0123456789abcdef"[rest % base];
        rest /= base;
        if (rest == 0) break;
    }
    write(digits[index..]);
}

/// Semihosting SYS_EXIT (ADP_Stopped_ApplicationExit): QEMU exits with `code`.
fn exit(code: u64) noreturn {
    const block = [2]u64{ 0x20026, code };
    asm volatile ("hlt #0xf000"
        :
        : [operation] "{w0}" (@as(u32, 0x18)),
          [parameters] "{x1}" (&block),
        : .{ .memory = true });
    while (true) {}
}

export fn runnerException(kind: u64, syndrome: u64, link: u64, fault: u64) callconv(.c) noreturn {
    write("\nCPU exception, vector ");
    writeNumber(kind, 10);
    write(" esr 0x");
    writeNumber(syndrome, 16);
    write(" elr 0x");
    writeNumber(link, 16);
    write(" far 0x");
    writeNumber(fault, 16);
    write("\n");
    exit(3);
}

fn onPanic(message: []const u8, _: ?usize) noreturn {
    write("\npanic: ");
    write(message);
    write("\n");
    exit(3);
}

pub const panic = std.debug.FullPanic(onPanic);

// No OS behind std.debug: its prints (std.testing failure messages) go
// nowhere instead of pulling in the threaded Io implementation.
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
pub const std_options_debug_io: std.Io = std.Io.failing;

export fn runnerMain() callconv(.c) noreturn {
    var passed: u64 = 0;
    var skipped: u64 = 0;
    var failed: u64 = 0;
    write("aarch64 tests (" ++ builtin.cpu.model.name ++ ")\n");
    for (builtin.test_functions) |test_fn| {
        write(test_fn.name);
        write(" ... ");
        if (test_fn.func()) |_| {
            passed += 1;
            write("ok\n");
        } else |err| if (err == error.SkipZigTest) {
            skipped += 1;
            write("skipped\n");
        } else {
            failed += 1;
            write("FAIL ");
            write(@errorName(err));
            write("\n");
        }
    }
    write("passed ");
    writeNumber(passed, 10);
    write(", failed ");
    writeNumber(failed, 10);
    write(", skipped ");
    writeNumber(skipped, 10);
    write("\n");
    exit(if (failed == 0) 0 else 1);
}
