#!/usr/bin/env bash
# What do the remaining failures actually need?
for t in rv32mi-p-zicntr rv32mi-p-instret_overflow rv32ui-p-ma_data; do
  echo "===== $t ====="
  python3 scripts/compare_trace.py \
      --rtl "/build/regress/$t.rtl" --spike "/build/regress/$t.spike" \
      --start-pc 0x80000000 2>&1 | head -4
done
echo
echo "===== instret_overflow: what CSRs does it touch? ====="
riscv64-unknown-elf-objdump -d verif/prog/riscv-tests/isa/rv32mi-p-instret_overflow \
  | grep -oE "csr[rw][wsci]*\s+[a-z0-9_]+" | sort -u
echo
echo "===== zicntr: what CSRs does it touch? ====="
riscv64-unknown-elf-objdump -d verif/prog/riscv-tests/isa/rv32mi-p-zicntr \
  | grep -oE "csr[rw][wsci]*\s+[a-z0-9_]+" | sort -u
