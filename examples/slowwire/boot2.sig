//! Standalone RP2040 boot stage; generic flash serial READ 03h, no SDK.
export fn _boot2() callconv(.naked) noreturn {
    asm volatile (
        \\ldr r3, =0x18000000
        \\movs r1, #0
        \\str r1, [r3, #8]
        \\movs r1, #4
        \\str r1, [r3, #20]
        \\ldr r1, =0x001f0300
        \\str r1, [r3]
        \\ldr r1, =0x03000218
        \\ldr r0, =0x180000f4
        \\str r1, [r0]
        \\movs r1, #0
        \\str r1, [r3, #4]
        \\movs r1, #1
        \\str r1, [r3, #8]
        \\ldr r0, =0x10000100
        \\ldr r1, =0xe000ed08
        \\str r0, [r1]
        \\ldr r1, [r0]
        \\msr msp, r1
        \\ldr r1, [r0, #4]
        \\bx r1
        \\.ltorg
    );
}
