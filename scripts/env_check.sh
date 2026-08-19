#!/usr/bin/env bash
# Verifies the host environment is ready. Run via `make env-check`.
set -euo pipefail

fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    printf '  OK    %s\n' "$1"
  else
    printf '  FAIL  %s\n' "$1"
    fail=1
  fi
}

echo "Environment check:"
check "running under WSL"        'grep -qi microsoft /proc/version'
check "docker reachable"         'docker info'
check "python3 >= 3.10"          'python3 -c "import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)"'
check "make present"             'command -v make'
check "build dir writable"       "mkdir -p ${BUILD:-$HOME/build/riscv} && test -w ${BUILD:-$HOME/build/riscv}"
check "vivado reachable"         'test -f /mnt/d/Vivado/2022.2/bin/vivado.bat'

# The repo path contains a space; confirm we are invoked from the repo root so
# that every Makefile path can stay relative.
check "cwd is repo root"         'test -f Makefile && test -d rtl'

exit $fail
