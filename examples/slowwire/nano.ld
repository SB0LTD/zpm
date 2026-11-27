ENTRY(_reset)
MEMORY {
  flash (rx) : ORIGIN = 0, LENGTH = 30K
  ram (rw!x) : ORIGIN = 0x800100, LENGTH = 2K
}
SECTIONS {
  .text : { KEEP(*(.vectors)) *(.text*) } > flash
  .data : { __data_start = .; *(.data*) *(.rodata*) __data_end = .; } > ram AT> flash
  __data_load_start = LOADADDR(.data);
  .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(COMMON) __bss_end = .; } > ram
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
ASSERT(SIZEOF(.data) + SIZEOF(.bss) <= 1024, "Reserve at least 1 KiB SRAM for stack")
