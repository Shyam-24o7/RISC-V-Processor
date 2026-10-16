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

Note: these cycle counts were measured with the earlier `tb_core_p5_lat`
completion trigger; the corrected testbench gives 507/592/809 at 1, 2 and 4
wait states (see section 6).

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

## 5. First loop-free synthesis (2026-10)

| Core | Fmax (MHz) | LUT | FF |
|---|---|---|---|
| core_rv32i | 216.7 | 2123 | 1438 |
| core_rv32i_p5 | 259.0 | 2718 | 2446 |

Both reports show zero combinational loops. Previous loop-affected figures were
215.5 MHz / 2094 LUT / 1438 FF (single-cycle) and 266.2 MHz / 2661 LUT / 2431 FF
(pipeline).

## 6. L1 caches (2026-10)

Split 4 KiB 2-way L1 caches, 16-byte lines, write-back data cache, in front of
main memory with 10 wait states.

| Program | Uncached pipeline (cycles) | Cached (cycles) | Speedup | I$ hit rate | D$ hit rate |
|---|---|---|---|---|---|
| hello.c | 1439 | 880 | 1.64x | 92.9% (395/425) | 82.6% (19/23) |
| cachestress.c | 167919 | 126479 | 1.33x | 99.9% (42199/42237) | 36.5% (2580/7073) |

Cycles come from the testbench's `PROGRAM DONE` line (`tb_core_p5_lat` uncached,
`tb_soc` cached), both counting up to the handshake of the final `tohost` store.
Hit rate = hits / (hits + misses) from the `CACHE` line. Every run matches
Spike.

`cachestress.c` is built to defeat the data cache: three arrays that map onto
the same sets, then a working set twice the cache size. Its 36.5% D$ hit rate
is a property of that access pattern: three arrays contend for two ways, and
the 8 KiB stream touches one word per line. The I$ hit rate is 99.9%. The
split of the speedup between the two caches was not measured. Cycles of the cached system across
main-memory latency (wait states):

| Wait states | hello.c uncached | hello.c cached | cachestress.c uncached | cachestress.c cached |
|---|---|---|---|---|
| 1 | 507 | 575 | 51423 | 67270 |
| 4 | 809 | 676 | - | 86999 |
| 10 | 1439 | 880 | 167919 | 126479 |
| 20 | - | 1220 | - | 192279 |

At 1 wait state the cached system is slower on both programs, and faster at 4
or more wait states for hello.c and at 10 or more for cachestress.c (4 was not
run for the uncached cachestress). The cause was not measured; a likely
explanation is the cost of refilling a whole 16-byte line on each miss. Cached
hit and miss counts vary by at most 2 across latencies (cachestress.c: 42199 to
42201 I$ hits, 4493 D$ misses at every latency).

Measurement note: `tb_core_p5_lat` previously took the `tohost` store as
complete when the request appeared. With wait states the request is visible for
several cycles before it completes, and above 8 wait states the fixed
8-cycle drain ended the run before the last instruction retired. The testbench
now waits for the store's handshake, as `tb_soc` does. Uncached hello.c cycle
counts at 1, 2 and 4 wait states moved by +1, +2 and +4 (506/590/805 in
section 2 became 507/592/809); the section 2 table is left as recorded.

Synthesis of the cached system (`rv32_soc`, main memory excluded):
Fmax 214.4 MHz, 5740 LUT, 3654 FF, 10 BRAM, 0 combinational loops.
The pipeline alone reaches 259.0 MHz, so adding the caches costs clock rate. The
worst path in `timing.rpt` runs from a data-cache tag RAM to the enable of a
data-cache data RAM. These are post-synthesis estimates.
