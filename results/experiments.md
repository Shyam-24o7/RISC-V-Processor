# Experiments

Measurements behind design decisions. Benchmark: `hello.c` (297 retired
instructions), every configuration matched against Spike.

**Caveat for every Fmax figure below:** until the 2026-10 repair, both cores
contained a combinational loop (CSR write enable -> legality -> trap -> stall
-> CSR write enable). Vivado breaks such a loop arbitrarily for timing
analysis, so these Fmax numbers are not reliable. Cycle counts are unaffected.

## 1. Memory latency without a fetch buffer

`LATENCY` = wait states on both ports (an access takes LATENCY+1 cycles).

| Wait states | Single-cycle | Pipeline |
|---|---|---|
| 0 | 297 | 422 |
| 1 | 594 | 765 |
| 2 | 891 | 1147 |
| 4 | 1485 | 1911 |

The pipeline stays about 29% slower at every non-zero latency. An
instruction-fetch stall froze the whole pipeline, so fetch latency was paid
once per instruction, as on the single-cycle core.

## 2. Decoupled fetch unit (4-entry prefetch buffer, pipelined fetch port)

| Wait states | Single-cycle | Pipeline + fetch unit | Ratio |
|---|---|---|---|
| 0 | 297 | 484 | 0.61x |
| 1 | 594 | 506 | 1.17x |
| 2 | 891 | 590 | 1.51x |
| 4 | 1485 | 805 | 1.84x |

Both parts are required: a buffer cannot fill from a memory serving one
request at a time. At zero latency the registered response adds one cycle
before decode (+62 cycles).

## 3. Branch prediction in ID (reverted)

| Variant | Cycles | IPC | Fmax (MHz)* |
|---|---|---|---|
| Branches resolve in EX | 422 | 0.701 | 251.3 |
| Predict in ID, target from decoder | 391 | 0.757 | 194.7 |
| Predict in ID, target from raw bits | 391 | 0.757 | 193.5 |

\* loop-affected. The extra redirect-mux input sat on the EX critical path.
Reverted; a BTB in IF is the alternative that adds no depth to that path.

## 4. Exception classification moved from EX to MEM

Fmax 260.2 -> 266.2 MHz* on a loop-affected design; not meaningful until
re-measured. The change itself is kept: it removes logic from EX.
