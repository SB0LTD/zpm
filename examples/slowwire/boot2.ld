ENTRY(_boot2)
SECTIONS { . = 0x20041f00; .text : { *(.text*) *(.rodata*) } /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment*) } }
ASSERT(SIZEOF(.text) <= 252, "RP2040 boot stage exceeds 252 bytes")
