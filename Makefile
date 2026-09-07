# All paths in this file MUST be relative. The repo lives at "D:\RISC-V Processor"
# whose path contains a space, and GNU Make cannot escape spaces in prerequisites.
# Always invoke make from the repo root.

BUILD ?= $(HOME)/build/riscv
SHELL := /usr/bin/env bash

.PHONY: env-check dirs clean

dirs:
	@mkdir -p $(BUILD)

env-check: dirs
	@BUILD=$(BUILD) bash scripts/env_check.sh

clean:
	rm -rf $(BUILD)

IMAGE   := rv32-toolchain:1
# Bind-mount the repo read-write and the ext4 build dir separately, so Verilator's
# thousands of generated C++ files never touch the 9p bridge.
IN_DOCKER := docker run --rm -v "$(CURDIR)":/work -v "$(BUILD)":/build -w /work $(IMAGE)

.PHONY: docker-build tools-check

docker-build:
	docker build -t $(IMAGE) docker/

# riscv64-unknown-elf-gcc comes from apt (gcc-riscv64-unknown-elf), which floats with
# the Ubuntu archive even though the base image itself is digest-pinned. A different
# GCC compiles the test binaries differently - different instruction counts, different
# IPC - which would silently invalidate the cross-phase comparison table this project
# exists to produce. EXPECTED_GCC is the version this image was validated with.
EXPECTED_GCC := 13.2.0

tools-check:
	@$(IN_DOCKER) bash -c '\
	  set -euo pipefail; \
	  echo "  verilator: $$(verilator --version)"; \
	  echo "  gcc:       $$(riscv64-unknown-elf-gcc --version | head -1)"; \
	  echo "  spike:     $$(spike --help 2>&1 | head -1)"; \
	  echo "  yosys:     $$(yosys -V)"; \
	  echo "  sby:       $$(sby --version)"; \
	  echo "  rv32 multilib:"; \
	  riscv64-unknown-elf-gcc -print-multi-lib | grep -q rv32 && echo "    OK rv32 supported" || \
	    { echo "    FAIL no rv32 multilib"; exit 1; }; \
	  GCC_VER=$$(riscv64-unknown-elf-gcc -dumpversion); \
	  if [ "$$GCC_VER" != "$(EXPECTED_GCC)" ]; then \
	    echo "  FAIL riscv gcc drifted: image has $$GCC_VER, this image was validated with $(EXPECTED_GCC)."; \
	    echo "        A different compiler yields different instruction counts/IPC, which"; \
	    echo "        would silently invalidate cross-phase comparisons. Rebuild pinned to"; \
	    echo "        $(EXPECTED_GCC), or update EXPECTED_GCC in the Makefile deliberately."; \
	    exit 1; \
	  fi; \
	  echo "  OK riscv gcc version matches validated $(EXPECTED_GCC)"; \
	  SPIKE_PROBE=$$(spike --isa=rv32i_zicsr --priv=m -l --log-commits /dev/null 2>&1 || true); \
	  if echo "$$SPIKE_PROBE" | grep -qi "commit logging support has not been properly enabled"; then \
	    echo "  FAIL spike was built WITHOUT --enable-commitlog."; \
	    echo "        Commit logging is opt-in at configure time. Without it spike emits no"; \
	    echo "        commit lines at all, so compare_trace.py sees an empty Spike trace and"; \
	    echo "        reports a truncation divergence - a broken toolchain misdiagnosed as a"; \
	    echo "        CPU bug. Rebuild: ../configure --prefix=/usr/local --enable-commitlog"; \
	    exit 1; \
	  fi; \
	  echo "  OK spike commit logging enabled"'

VFLAGS := --binary --timing -Wall -Wno-fatal -Irtl/common -Irtl/mem -Irtl/core

# rv32_pkg.sv MUST come first: every module imports it, and a package has to be
# analysed before its first use. A plain alphabetical glob puts it last (after
# alu, csr_file, decoder, mul_div, regfile) and the build fails on an
# undefined type. wildcard keeps this relative-path-only, as required.
RTL_SRCS := rtl/common/rv32_pkg.sv \
            $(filter-out rtl/common/rv32_pkg.sv, \
              $(wildcard rtl/common/*.sv) $(wildcard rtl/mem/*.sv) \
              $(wildcard rtl/core/*.sv))

.PHONY: tb
# Usage: make tb TB=tb_alu
tb:
	@$(IN_DOCKER) bash -c 'verilator $(VFLAGS) --top-module $(TB) \
	   --Mdir /build/$(TB) -o $(TB) \
	   $(RTL_SRCS) verif/tb/$(TB).sv \
	   && /build/$(TB)/$(TB)'

# Which core-level testbench cosim and regress drive. The RVFI harness is
# microarchitecture-independent, so switching cores needs nothing else.
CORE_TB ?= tb_core_rv32i

RVGCC := riscv64-unknown-elf-gcc
RVOBJ := riscv64-unknown-elf-objcopy
ARCH  := -march=rv32i -mabi=ilp32 -mcmodel=medany
ENTRY_PC := 0x80000000

.PHONY: cosim
# Usage: make cosim PROG=hello
# Builds an ELF, runs Spike and the RTL on it, and diffs the two traces.
cosim:
	@$(IN_DOCKER) bash -c 'set -euo pipefail; \
	  mkdir -p /build/prog; \
	  $(RVGCC) $(ARCH) -nostdlib -nostartfiles -O2 -Wall -g \
	    -T verif/prog/link.ld verif/prog/crt0.S verif/prog/$(PROG).c \
	    -o /build/prog/$(PROG).elf -lgcc; \
	  $(RVOBJ) -O binary /build/prog/$(PROG).elf /build/prog/$(PROG).bin; \
	  od -An -tx4 -v /build/prog/$(PROG).bin | tr -s " " "\n" | grep -v "^$$" \
	    > /build/prog/$(PROG).hex; \
	  rm -f /build/prog/$(PROG).spike; \
	  spike --isa=rv32i_zicsr --priv=m -l --log-commits \
	    --log=/build/prog/$(PROG).spike /build/prog/$(PROG).elf >/dev/null 2>&1; \
	  test -s /build/prog/$(PROG).spike || \
	    { echo "FATAL: spike wrote no commit log - refusing to compare against a stale one"; exit 1; }; \
	  verilator $(VFLAGS) --top-module $(CORE_TB) --Mdir /build/$(CORE_TB) \
	    -o $(CORE_TB) $(RTL_SRCS) verif/tb/$(CORE_TB).sv 2>&1 | grep -E "^%Error" || true; \
	  /build/$(CORE_TB)/$(CORE_TB) +hex=/build/prog/$(PROG).hex \
	    +trace=/build/prog/$(PROG).rtl +max_cycles=200000; \
	  STOP=$$(riscv64-unknown-elf-nm /build/prog/$(PROG).elf \
	          | awk "/ _finish_loop\$$/ {print \$$1}"); \
	  python3 scripts/compare_trace.py --rtl /build/prog/$(PROG).rtl \
	    --spike /build/prog/$(PROG).spike --start-pc $(ENTRY_PC) --stop-pc 0x$$STOP'

.PHONY: test-scripts
test-scripts:
	@$(IN_DOCKER) bash -c 'pip install --quiet --break-system-packages pytest && \
	  python3 -m pytest scripts/test_compare_trace.py -q'

.PHONY: fetch-tests
fetch-tests:
	@test -d verif/prog/riscv-tests || \
	  git clone --recursive --depth 1 \
	    https://github.com/riscv-software-src/riscv-tests verif/prog/riscv-tests

.PHONY: regress
# Usage: make regress            (all rv32ui/um/mi p-mode tests)
#        make regress FILTER=add (subset)
regress:
	@$(IN_DOCKER) bash -c 'set -euo pipefail; \
	  verilator $(VFLAGS) --top-module $(CORE_TB) --Mdir /build/$(CORE_TB) \
	    -o $(CORE_TB) $(RTL_SRCS) verif/tb/$(CORE_TB).sv 2>&1 | grep -E "^%Error" || true; \
	  python3 scripts/run_regress.py --sim /build/$(CORE_TB)/$(CORE_TB) \
	    --filter "$(FILTER)"'

# Vivado is a native Windows install, so this target runs OUTSIDE the container,
# reached from WSL through interop. Paths stay relative; the space in the repo
# path is fine here because Tcl and the shell both quote correctly - it is only
# GNU Make's target/prerequisite parsing that cannot cope with it.
VIVADO := /mnt/d/Vivado/2022.2/bin/vivado.bat

.PHONY: synth results
# Usage: make synth CORE=core_sc
synth:
	@mkdir -p results/raw
	$(VIVADO) -mode batch -source scripts/synth.tcl -tclargs $(CORE) -nojournal -nolog
	@cp build_vivado/$(CORE)/summary.json results/raw/$(CORE)_synth.json
	@echo "recorded results/raw/$(CORE)_synth.json"

results:
	@python3 scripts/collect_results.py

.PHONY: fetch-formal formal
fetch-formal:
	@test -d verif/formal/riscv-formal || \
	  git clone --depth 1 https://github.com/YosysHQ/riscv-formal verif/formal/riscv-formal

# Usage: make formal CORE=core_sc
formal: fetch-formal
	@$(IN_DOCKER) bash -c 'sby -f -d /build/formal_$(CORE) verif/formal/$(CORE).sby'
