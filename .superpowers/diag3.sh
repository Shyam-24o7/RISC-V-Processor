#!/usr/bin/env bash
echo "=== instruction sequence around the minstret read ==="
riscv64-unknown-elf-objdump -d verif/prog/riscv-tests/isa/rv32mi-p-instret_overflow \
  | sed -n '/800001c8:/,/800001e4:/p'
echo
echo "=== spike log there ==="
grep -nE "0x800001(c8|cc|d0|d4|d8|dc)" /build/regress/rv32mi-p-instret_overflow.spike | head -14
