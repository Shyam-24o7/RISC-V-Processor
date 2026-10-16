# RV32I Processor

A five-stage pipelined RISC-V RV32I processor in SystemVerilog, verified
instruction-by-instruction against the reference ISA simulator (Spike) and
synthesised for a Xilinx Zynq UltraScale+ FPGA. A single-cycle core is kept
alongside it as the baseline.

| | |
|---|---|
| **ISA** | RV32I + Zicsr + machine-mode traps |
| **Cores** | `rv32_soc` (pipeline + split L1 caches), `core_rv32i_p5` (pipeline), `core_rv32i` (single-cycle) |
| **Target** | AMD/Xilinx XCK26 (Kria K26 SOM / KV260), synthesis only |
| **Compliance** | 54/58 applicable riscv-tests |
| **Co-simulation** | Matches Spike instruction-for-instruction |

---

## Quick start

Everything runs inside a pinned container, driven by `make` from WSL2:

```bash
make env-check              # host prerequisites (docker, python, vivado reachable)
make docker-build           # build the pinned toolchain image (~20 min, once)
make tools-check            # prove every tool runs AND has not drifted

make tb TB=tb_alu           # one module testbench
make cosim PROG=hello       # compile C -> run on RTL and Spike -> diff traces
make cosim PROG=hello CORE_TB=tb_soc   # cached system vs Spike
make lint
make regress                # the official riscv-tests compliance suite
make synth CORE=core_rv32i  # Vivado: Fmax + utilisation
make results                # regenerate results/comparison.md
```

---

## 1. What a single-cycle core means

Every instruction completes **between two clock edges**. Fetch, decode, register read,
execute, memory access and writeback all happen inside one clock period.

The consequence is a trade: IPC is exactly **1.000** — nothing ever stalls, because there
is nothing to stall on — but the clock period must be long enough to contain that entire
chain of logic. A pipelined design breaks the chain into stages, giving a much shorter
clock at the cost of hazards that must then be managed.

RV32I has no multiply or divide, so there is no multi-cycle functional unit anywhere in
this design. That is what makes IPC exactly 1.000 rather than merely close to it.

---

## 2. Datapath

```
                     ┌───────────────────────────────────────────────┐
                     │                    (next PC feedback)         │
   ┌──────┐          │                                               │
   │mtvec │──┐       │        ┌────────┐                             │
   └──────┘  │       └───────>│   PC   │                             │
   ┌──────┐  │  ┌────┐        │  (reg) │                             │
   │ mepc │──┼─>│MUX │───────>└───┬────┘                             │
   └──────┘  │  └────┘            │ instr_addr_o                     │
             │    ▲               ▼                                  │
  pc+4 / branch / jump     ┌──────────────┐                          │
             └─────────────│ INSTRUCTION  │                          │
                           │    MEMORY    │                          │
                           └──────┬───────┘                          │
                                  │ instr_rdata_i                    │
                                  ▼                                  │
                           ┌──────────────┐                          │
                           │   DECODER    │  insn -> decoded_t       │
                           └──┬────────┬──┘                          │
                    rs1, rs2  │        │  imm, alu_op, control flags │
                              ▼        │                             │
                       ┌────────────┐  │                             │
                       │  REGFILE   │  │                             │
                       │   32 x 32  │  │                             │
                       │  2R / 1W   │  │                             │
                       └──┬──────┬──┘  │                             │
                   rs1_d  │      │ rs2_d                             │
                          ▼      ▼     │                             │
                      ┌─────┐  ┌─────┐ │                             │
                 PC ─>│MUX A│  │MUX B│<┘ imm                         │
                      └──┬──┘  └──┬──┘                               │
                         ▼        ▼                                  │
                      ┌──────────────┐                               │
                      │     ALU      │                               │
                      └──────┬───────┘                               │
                             │ alu_result                            │
          ┌──────────────────┼───────────────────┐                   │
          ▼                  ▼                   ▼                   │
   ┌─────────────┐    ┌─────────────┐    ┌──────────────┐            │
   │  DATA MEM   │    │  CSR FILE   │    │ branch cond  │            │
   │ addr/we/be  │    │  + TRAPS    │    │ jump target  │────────────┘
   └──────┬──────┘    └──────┬──────┘    └──────────────┘
          │ load_data        │ csr_rdata
          └────────┬─────────┘
                   ▼
            ┌─────────────┐
            │  WRITEBACK  │───> regfile write port (rd)
            │     MUX     │
            └─────────────┘
```

**Reading the diagram:** the PC drives instruction memory; the fetched word is decoded
into a control bundle; the register file supplies operands; two muxes select whether the
ALU sees the PC (for `AUIPC`) and the immediate (for I-type) or the raw registers; the ALU
result then fans out to memory, the CSR file and the branch unit; and a final mux picks
what gets written back. The next-PC decision feeds back to the top.

### 2.1 Module responsibilities

| Module | Lines | Responsibility |
|---|---|---|
| `rtl/common/rv32_pkg.sv` | 134 | Every ISA encoding: opcodes, funct3/funct7, CSR addresses, exception causes. The single source of truth. |
| `rtl/common/alu.sv` | 39 | 11 combinational operations |
| `rtl/common/regfile.sv` | 38 | 32×32 registers, two read ports, one write port |
| `rtl/common/decoder.sv` | 135 | Instruction word → control bundle + sign-extended immediate |
| `rtl/common/csr_file.sv` | 169 | Machine-mode CSRs, trap entry/exit, performance counters |
| `rtl/mem/magic_mem.sv` | 59 | Zero-latency memory model (simulation only) |
| `rtl/mem/latency_mem.sv` | — | Memory with configurable wait states and a ready handshake; optional pipelined instruction port |
| `rtl/core/fetch_unit.sv` | — | Decoupled fetch: runs the fetch address ahead, buffers arriving instructions |
| `rtl/core/core_rv32i_p5.sv` | — | Five-stage pipelined core |
| `rtl/core/core_rv32i.sv` | 265 | Top-level datapath tying it all together |

### 2.2 Details that are easy to get wrong

These are the places where a plausible-looking implementation is subtly incorrect:

**Shift amounts are masked to 5 bits.** RV32 shifts use `rs2[4:0]`, so `x << 33` is a
shift by 1, not zero. Passing the full 32-bit operand to `<<` silently gives the wrong
answer.

**`SRA` needs a signed operand.** `>>>` performs an arithmetic shift *only* on a signed
value; on an unsigned one it behaves exactly like `>>`, quietly losing sign extension.

**`x0` is enforced on all three ports.** It is not a register that holds zero — it cannot
hold anything else. RISC-V depends on this: `ret` is `jalr x0, 0(ra)`, which computes a
link address purely to discard it.

**Immediates are shredded across the encoding.** The register fields sit at fixed
positions in every format (`rs1`=[19:15], `rs2`=[24:20], `rd`=[11:7]) so the register file
can start reading before decode finishes. The price is that B-type and J-type immediates
are reassembled from scattered bits, with an implicit zero LSB since branch targets are
2-byte aligned.

**Byte and halfword loads sign-extend from their own lane.** `LB` from address 3 takes
bits [31:24] and extends from bit 7 *of that byte*, not bit 31 of the word.

**`csr_we` must be pure write *intent*.** Gating it with `trap_taken` closes a
combinational loop:

```
trap_taken -> csr_we -> csr_illegal -> illegal_insn -> trap_taken
```

The suppression happens inside `csr_file` instead, whose sequential block gives trap entry
priority over the write branch.

---

## 3. Traps

```
   instruction
        │
        ▼
   ┌─────────────────────────────────────────┐
   │ priority encoder (illegal first)        │
   │   illegal instruction   -> mcause 2     │
   │   ecall                 -> mcause 11    │
   │   ebreak                -> mcause 3     │
   │   load  misaligned      -> mcause 4     │
   │   store misaligned      -> mcause 6     │
   │   fetch misaligned      -> mcause 0     │
   └──────────────┬──────────────────────────┘
                  │ trap_taken
                  ▼
   ┌─────────────────────────────────────────┐
   │ mepc   <- faulting PC                   │
   │ mcause <- cause code                    │
   │ mtval  <- faulting address / instruction│
   │ mstatus.MPIE <- mstatus.MIE             │
   │ mstatus.MIE  <- 0                       │
   │ PC     <- mtvec                         │
   └─────────────────────────────────────────┘
                  │
              handler runs
                  │  mret
                  ▼
   ┌─────────────────────────────────────────┐
   │ mstatus.MIE  <- mstatus.MPIE            │
   │ mstatus.MPIE <- 1                       │
   │ PC           <- mepc                    │
   └─────────────────────────────────────────┘
```

A trapping instruction writes **no** architectural state: `rd_we` and `data_we_o` are both
gated by `trap_taken`, so a misaligned store never reaches memory.

`mstatus.MPP` reads as 3 (machine mode). On an M-mode-only core the privilege level before
any trap is always machine mode; leaving it zero makes `mstatus` read `0x0080` where a
conforming model reads `0x1880`.

---

## 4. The containerised environment

Five tools, three of which are Linux-native, one Windows-native, all driven from one
`make`:

```
  Windows 11 host
  │
  ├─ Vivado 2022.2 (native Windows)  ── synthesis, Fmax, utilisation
  │       ▲
  │       │ invoked from WSL over interop:
  │       │   /mnt/d/Vivado/2022.2/bin/vivado.bat -mode batch ...
  │
  ├─ WSL2 : Ubuntu 24.04             ── `make` runs here
  │       │
  │       │  docker run -v <repo>:/work -v ~/build/riscv:/build
  │       ▼
  │  ┌──────────────────────────────────────────────┐
  │  │  rv32-toolchain:1   (digest-pinned base)     │
  │  │                                              │
  │  │   verilator 5.026     built from source      │
  │  │   riscv64-unknown-elf-gcc 13.2.0             │
  │  │   spike 1.1.0         --enable-commitlog     │
  │  │   yosys / sby / boolector  (oss-cad-suite)   │
  │  └──────────────────────────────────────────────┘
  │
  └─ repo lives on D:\ , build artefacts on ext4
```

### Why it is built this way

**Source on Windows, builds on ext4.** WSL2 reaching into `/mnt/d` goes through a 9p
filesystem bridge that is roughly 10–20× slower for many-small-file operations. Verilating
a core emits thousands of C++ files — precisely the pathological case. Sources are a few
hundred text files read once, so that crossing is free; the build output is not.

**Everything pinned, including the base image by digest.** `ubuntu:24.04` is a moving tag.
A rebuild months from now could silently serve a different compiler, and a different
compiler produces different instruction counts — which would invalidate any performance
comparison across designs built at different times.

**`tools-check` verifies more than "the binary exists".** It asserts the RISC-V GCC version
has not drifted from the one the results were measured with, and that Spike genuinely
*emits commit lines*. That second check exists because commit logging is opt-in at Spike's
configure time, and a build without it still passes `spike --help` — the failure is
completely silent until a trace comparison mysteriously sees an empty reference.

**Vivado stays outside the container.** The one thing that does *not* live in the
container is Vivado, because it is a native Windows install; WSL interop lets a single
`make synth` drive it anyway, and `scripts/synth.tcl` uses only relative paths so the
space in the repo path never reaches a Make prerequisite (GNU Make cannot escape it).

---

## 5. Verification

Four independent layers, weakest to strongest:

```
   verif/prog/hello.c
        │
        │  riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32
        ▼
    hello.elf ────────────┬────────────────────┬──────────────┐
        │                 │                    │              │
        │ objcopy -O bin  │ spike --priv=m     │ nm           │
        ▼                 │  -l --log-commits  │              │
    hello.bin             ▼                    ▼              │
        │            hello.spike          tohost address      │
        │ od -tx4    (golden trace)       write_tohost        │
        ▼                 │                    │              │
    hello.hex             │                    │              │
        │                 │                    │              │
        ▼                 │                    │              │
 ┌──────────────────┐     │                    │              │
 │    Verilator     │     │                    │              │
 │  tb_core_rv32i   │     │                    │              │
 │    + core RTL    │     │                    │              │
 └────────┬─────────┘     │                    │              │
          │ RVFI trace    │                    │              │
          ▼               ▼                    ▼              │
      hello.rtl ────> compare_trace.py <───────┘              │
                            │                                 │
                  MATCH  /  DIVERGENCE at instruction #N ◄─────┘
                            with both sides printed
```

**Layer 1 — per-module directed testbenches.** One per module, self-checking, `$fatal` on
mismatch. Fast, and they localise a failure to a single module.

**Layer 2 — Spike co-simulation.** The core exposes an **RVFI** (RISC-V Formal Interface)
retirement port. The testbench dumps one line per retired instruction; `compare_trace.py`
parses Spike's commit log into the same form and reports the *first* divergence with both
sides shown. This is the difference between *"CoreMark failed"* and *"instruction #48211,
`lw x7,0(x9)`: RTL rd=0x4, Spike rd=0x10"*.

**Layer 3 — riscv-tests.** The official compliance suite, dual-gated: the suite's own
`tohost` result code *and* full trace agreement with Spike. The first tells you which
sub-test failed; the second tells you which instruction diverged.

**Layer 4 — synthesis.** Not correctness, but it keeps the RTL honest: anything that
cannot be built is caught immediately rather than at the end.

### Two subtleties the harness has to get right

**Spike omits trapping instructions from its commit log** — it prints a disassembly line
and an `exception` line, but no commit record. The RTL trace dump therefore skips trapping
instructions too. This does *not* weaken trap checking: if the core trapped where Spike did
not, our trace would be missing a record Spike has, and vice versa. Either way it diverges.

**A truncated trace is a divergence, never a pass.** If the core hangs, its trace is short.
Silently accepting that because "everything so far matched" would make the whole harness
untrustworthy, so `first_divergence` compares to `max(len(rtl), len(spike))` and reports
the missing side explicitly.

### Compliance status

**54 of 58** applicable tests pass (`rv32ui` + `rv32mi`). `rv32um` is not applicable — this
core has no M extension. The four remaining failures are documented scope boundaries, not
defects:

| Test | Why |
|---|---|
| `rv32ui-p-ma_data` | Requires *hardware* misaligned access. The spec permits trapping instead, which is what this core does. |
| `rv32mi-p-breakpoint` | Needs a debug trigger module (`tselect`/`tdata*`) |
| `rv32mi-p-pmpaddr` | Tests PMP enforcement; this core implements zero PMP regions |
| `rv32mi-p-mcsr` | Passes its own result gate. Differs only on `marchid`, an implementation-defined identity register — ours reads 0, Spike reports its own value. |

The runner separates documented gaps from unexpected failures, so only a real regression
fails the build — and it reports if a known gap *starts* passing, so the list cannot rot.

---

## 5.1 Memory latency

The cycle-count measurements behind the fetch unit (and the branch-prediction
experiment that was reverted) are in `results/experiments.md`.

## 5.2 Memory hierarchy

    core_rv32i_p5 --instr--> icache --+
                                      +--> mem_arbiter --line port--> main memory
    core_rv32i_p5 --data---> dcache --+

- **L1 caches:** 4 KiB each, 2-way set-associative, 16-byte lines, LRU.
  Arrays are synchronous-read block RAM (`sram_1r1w`); valid, dirty and LRU
  bits are flip-flops so reset and FENCE.I can clear them at once.
- **Instruction cache:** one-cycle hits, one request per cycle, so the fetch
  buffer stays full. A miss withholds the grant until the line arrives.
- **Data cache:** write-back, write-allocate. A hit completes in MEM because
  the core sends the next access's address one cycle early. A miss writes back
  a dirty victim, refills, and replays through the hit path. A store followed
  by an access to the same set re-reads rather than relying on block-RAM
  collision behaviour.
- **FENCE.I:** the data cache writes back every dirty line, then the
  instruction cache invalidates, then fetch restarts at the next instruction.
- **Arbiter:** one line port shared by both caches; the data side wins ties.
  An L2 would attach downstream of it.
- **Main memory:** simulation model with a configurable number of wait states,
  outside the synthesised boundary.

Measured results are in section 6 and `results/experiments.md`.

## 6. Results

| Core | IPC | Fmax (MHz) | LUT / FF / BRAM / DSP |
|---|---|---|---|
| RV32I single-cycle | 1.000 | 216.7 | 2123 / 1438 / 0 / 0 |
| RV32I 5-stage pipeline | 0.612 | 259.0 | 2718 / 2446 / 0 / 0 |
| RV32I pipeline + L1 I$/D$ (4 KiB each) | - | 214.4 | 5740 / 3654 / 10 / 0 |

The `rv32_soc` row has no ideal-memory IPC: its IPC depends on main-memory latency, so
it is reported in the table below. Its Fmax excludes main memory.

With 10 main-memory wait states, cycles to completion (all runs match Spike):

| Program | Uncached pipeline | Cached | Speedup | I$ hit rate | D$ hit rate |
|---|---|---|---|---|---|
| hello.c | 1439 | 880 | 1.64x | 92.9% | 82.6% |
| cachestress.c | 167919 | 126479 | 1.33x | 99.9% | 36.5% |

`cachestress.c` is written to thrash the data cache, so its low D$ hit rate reflects the
access pattern. At 1 wait state the cached system is slower on both programs (hello.c 575
vs 507 cycles; cachestress.c 67270 vs 51423); see `results/experiments.md`, section 6.

Both IPC figures above are for **ideal memory**, the one case where the pipeline's prefetch
buffer is pure overhead. Under any real memory latency the ranking flips (section 5.1),
so do not read IPC × Fmax from this table as the pipeline's real-world throughput.

**On reading these numbers.** IPC alone is misleading: a single-cycle datapath buys its
perfect IPC with a slow clock. MIPS is only comparable *within* one ISA, because it counts
instructions rather than work — an RV32I core scores far higher MIPS than an RV32IM core on
the same C source purely because it executes many more instructions to compute the same
answer.

The synthesised Fmax is also **optimistic for a single-cycle design specifically**:
`magic_mem` is excluded from synthesis as a simulation construct, so instruction fetch and
data access time sit outside every measured path — which a real single-cycle core cannot do.

---

## 7. Repository layout

```
rtl/
  common/     rv32_pkg.sv  alu.sv  regfile.sv  decoder.sv  csr_file.sv
  core/       core_rv32i.sv  core_rv32i_p5.sv  fetch_unit.sv
  mem/        sram_1r1w.sv  icache.sv  dcache.sv  mem_arbiter.sv
              main_mem.sv  latency_mem.sv  magic_mem.sv   (last three: simulation only)
  soc/        rv32_soc.sv
verif/
  tb/         one self-checking testbench per module, plus the trace-dumping top
  prog/       crt0.S, linker script, C benchmark, smoke program
scripts/
  compare_trace.py    RVFI vs Spike commit-log diff  (+ its own unit tests)
  run_regress.py      riscv-tests runner, dual-gated
  synth.tcl           Vivado batch synthesis
  collect_results.py  regenerates results/comparison.md
  env_check.sh        host prerequisites
docker/       Dockerfile with every tool version pinned
results/      comparison.md and the raw measurements behind it
```

---

## 8. Roadmap

The verification harness is deliberately microarchitecture-independent: it consumes an
RVFI retirement port, so a different core implementing the same interface is validated by
the same flow with no changes. Planned next:

- **Branch target buffer** in the fetch stage.
- **L2 cache** between the arbiter and main memory.
- **Non-blocking data cache** (miss status holding registers).
- **M extension**, then **custom instructions** in the reserved custom opcode
  space (`0x0B`, `0x2B`, `0x5B`, `0x7B`).

---

## References

- [RISC-V ratified specifications](https://docs.riscv.org/)
- [RVFI — RISC-V Formal Interface](https://yosyshq.readthedocs.io/projects/riscv-formal/en/latest/rvfi.html)
- [riscv-tests](https://github.com/riscv-software-src/riscv-tests)
- [Spike, the RISC-V ISA simulator](https://github.com/riscv-software-src/riscv-isa-sim)
- [CV32E40P custom instruction set extensions](https://cv32e40p.readthedocs.io/en/latest/instruction_set_extensions.html)
