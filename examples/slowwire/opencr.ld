ENTRY(_reset)
MEMORY { FLASH (rx) : ORIGIN = 0x08040000, LENGTH = 512K
         RAM (rwx) : ORIGIN = 0x200114EC, LENGTH = 0x3EB14 }
SECTIONS {
 .vectors : { KEEP(*(.vectors)) } > FLASH
 .text : { *(.text*) *(.rodata*) } > FLASH
 .data : { . = ALIGN(32); _data_start = .; *(.ramfunc*) *(.data*) . = ALIGN(32); _data_end = .; } > RAM AT> FLASH
 _data_load = LOADADDR(.data);
 .bss (NOLOAD) : { . = ALIGN(32); _bss_start = .; *(.bss*) *(COMMON) . = ALIGN(32); _bss_end = .; } > RAM
 /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment*) }
}
ASSERT(_bss_end < 0x2004c000, "Keep at least 16 KiB stack reserve")
ASSERT(LOADADDR(.data) + SIZEOF(.data) <= 0x080c0000, "Reserve sector 7 for explicit scratch storage")
