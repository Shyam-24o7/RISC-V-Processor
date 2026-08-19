OUTPUT_ARCH(riscv)
ENTRY(_start)

/* Base 0x80000000 matches Spike's default DRAM base and riscv-tests' own
   layout, so no -m argument is needed and test binaries drop straight in.
   magic_mem decodes only the low address bits, so 0x80000000 aliases to word
   0 of the array - the same aliasing applies to both the instruction and data
   ports, so it is consistent. */
SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text*)     }
  .rodata    : { *(.rodata*) *(.srodata*) }
  .data      : { *(.data*) *(.sdata*) }
  .bss       : { *(.bss*) *(.sbss*) *(COMMON) }

  /* Fixed address so the testbench can watch for the completion store without
     parsing the ELF symbol table. Must match TOHOST_ADDR in tb_core_sc.sv. */
  . = 0x80010000;
  .tohost : { tohost = .; . += 8; fromhost = .; . += 8; }

  . = ALIGN(16);
  . += 4096;
  _stack_top = .;
}
