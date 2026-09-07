#!/usr/bin/env bash
T=rv32mi-p-scall
echo "===== $T : first divergence ====="
python3 scripts/compare_trace.py --rtl /build/regress/$T.rtl --spike /build/regress/$T.spike \
    --start-pc 0x80000000 2>&1 | head -12
echo
echo "===== spike log around the trap ====="
grep -nE "exception|0x8000000[048c]" /build/regress/$T.spike | head -12
echo
echo "===== RTL trace lines 70-80 ====="
sed -n '70,80p' /build/regress/$T.rtl
