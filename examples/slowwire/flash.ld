ENTRY(_reset)
MEMORY { FLASH (rx) : ORIGIN = 0x10000100, LENGTH = 2M - 256
         RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 256K }
SECTIONS {
 .vectors : { KEEP(*(.vectors)) } > FLASH
 .text : { *(.text*) *(.rodata*) } > FLASH
 .data : { . = ALIGN(4); _data_start = .; *(.data*) . = ALIGN(4); _data_end = .; } > RAM AT> FLASH
 _data_load = LOADADDR(.data);
 .bss (NOLOAD) : { . = ALIGN(4); _bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
 /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment*) }
}
ASSERT(_bss_end < 0x2003c000, "Keep at least 16 KiB stack reserve")
