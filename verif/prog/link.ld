OUTPUT_ARCH(riscv)
ENTRY(_start)

/* Base 0x80000000 matches Spike's default DRAM base and riscv-tests' own
   layout, so no -m argument is needed and test binaries drop straight in.
   The memory models decode only the low address bits, so 0x80000000 aliases to
   word 0, identically on every port. */
SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text*)     }
  .rodata    : { *(.rodata*) *(.srodata*) }
  .data      : { *(.data*) *(.sdata*) }
  .bss       : { *(.bss*) *(.sbss*) *(COMMON) }

  /* Fixed address so the testbench can watch for the completion store without
     parsing the ELF symbol table. Must match tohost_addr in the core testbenches. */
  . = 0x80010000;
  .tohost : { tohost = .; . += 8; fromhost = .; . += 8; }

  . = ALIGN(16);
  . += 4096;
  _stack_top = .;
}
