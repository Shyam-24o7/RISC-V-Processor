#!/usr/bin/env python3
"""Build and run the riscv-tests ISA suite against a core, one test per ELF.

Two independent gates per test, both must pass:

  1. tohost value. riscv-tests writes 1 on success, or (failing_test << 1) | 1
     on failure. This is the suite's own designed criterion and tells us WHICH
     sub-test failed.
  2. Trace agreement with Spike, compared from _start up to write_tohost.
     Gate 1 alone only says "test 7 failed"; gate 2 says which instruction
     diverged and how.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple


class TestResult(NamedTuple):
    name: str
    passed: bool
    detail: str


SUITES = ("rv32ui", "rv32um", "rv32mi")
ENTRY_PC = "0x80000000"

# Tests this core is not expected to pass, each with the reason established by
# reading the actual divergence rather than assumed. These still RUN and still
# report; they are separated in the summary so a real regression is not lost in
# the noise. Anything failing that is NOT listed here is a genuine regression.
KNOWN_GAPS = {
    "rv32ui-p-ma_data":
        "core traps on misaligned load/store; the spec permits trapping, this "
        "test requires hardware support",
    "rv32mi-p-breakpoint":
        "no debug trigger module: tselect (0x7a0) and tdata* are unimplemented",
    "rv32mi-p-zicntr":
        "unprivileged counters cycle/time/instret (0xc00-0xc02) unimplemented",
    "rv32mi-p-pmpaddr":
        "zero PMP entries implemented, so enforcement cannot be tested",
    "rv32mi-p-mcsr":
        "passes its own tohost gate; trace differs only on marchid, an "
        "implementation-defined identity register (ours 0, Spike 5)",
    "rv32mi-p-instret_overflow":
        "mcountinhibit is implemented but this still fails at sub-test 3; root "
        "cause NOT yet established - do not treat this entry as understood",
}


def discover(isa_dir: Path) -> list[Path]:
    """Built p-mode ELFs only. The .dump files are disassembly, not programs,
    and the -v variants need an MMU this core does not implement."""
    out = []
    for suite in SUITES:
        for p in sorted(isa_dir.glob(f"{suite}-p-*")):
            if p.suffix == ".dump" or not p.is_file():
                continue
            out.append(p)
    return out


def _sym(elf: Path, name: str) -> str | None:
    r = subprocess.run(["riscv64-unknown-elf-nm", str(elf)],
                       capture_output=True, text=True)
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == name:
            return "0x" + parts[0]
    return None


def run_one(elf: Path, build: Path, sim: Path, compare: Path) -> TestResult:
    name = elf.name
    hexf = build / f"{name}.hex"
    rtlf = build / f"{name}.rtl"
    spkf = build / f"{name}.spike"

    tohost = _sym(elf, "tohost")
    stop_pc = _sym(elf, "write_tohost")
    if tohost is None:
        return TestResult(name, False, "no tohost symbol in ELF")

    # Flat image from the lowest address, zero-filling gaps, then one 32-bit
    # little-endian word per line for $readmemh.
    binf = build / f"{name}.bin"
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary",
                    str(elf), str(binf)], check=True)
    od = subprocess.run(["od", "-An", "-tx4", "-v", str(binf)],
                        capture_output=True, text=True, check=True)
    hexf.write_text("\n".join(w for w in od.stdout.split()) + "\n")

    # Delete first, then require a fresh log. If spike fails, the previous run's
    # log is left in place and the comparison silently uses a stale reference -
    # which can report a false MATCH. That is exactly what an unsupported
    # --pmpregions flag did here: spike rejected it, wrote nothing, and every
    # trace comparison afterwards ran against hours-old logs.
    spkf.unlink(missing_ok=True)
    sp = subprocess.run(["spike", "--isa=rv32im_zicsr", "--priv=m", "-l", "--log-commits",
                         f"--log={spkf}", str(elf)],
                        capture_output=True, text=True)
    if not spkf.exists() or spkf.stat().st_size == 0:
        err = (sp.stderr.strip().splitlines() or ["(no stderr)"])[0]
        return TestResult(name, False, f"spike wrote no commit log: {err}")

    sim_proc = subprocess.run(
        [str(sim), f"+hex={hexf}", f"+trace={rtlf}",
         f"+tohost={tohost[2:]}", "+max_cycles=500000"],
        capture_output=True, text=True,
    )
    m = re.search(r"PROGRAM DONE tohost=0x([0-9a-fA-F]+)", sim_proc.stdout)
    if not m:
        tail = sim_proc.stdout.strip().splitlines()
        return TestResult(name, False,
                          "did not reach tohost: " + (tail[-1] if tail else "no output"))

    code = int(m.group(1), 16)
    if code != 1:
        # riscv-tests encodes the failing sub-test number in the upper bits.
        return TestResult(name, False, f"tohost=0x{code:x} (sub-test {code >> 1} failed)")

    cmp_cmd = ["python3", str(compare), "--rtl", str(rtlf), "--spike", str(spkf),
               "--start-pc", ENTRY_PC]
    if stop_pc:
        cmp_cmd += ["--stop-pc", stop_pc]
    cmp_proc = subprocess.run(cmp_cmd, capture_output=True, text=True)
    if cmp_proc.returncode != 0:
        first = cmp_proc.stdout.strip().splitlines()
        return TestResult(name, False, first[0] if first else "trace mismatch")

    return TestResult(name, True, "")


def summarize(results: list[TestResult]) -> tuple[str, int]:
    passed = [r for r in results if r.passed]
    failed = [r for r in results if not r.passed]
    known = [r for r in failed if r.name in KNOWN_GAPS]
    unexpected = [r for r in failed if r.name not in KNOWN_GAPS]

    lines = [f"\n{len(passed)}/{len(results)} tests passed"]
    if known:
        lines.append(f"\n{len(known)} known gaps (documented, not regressions):")
        for r in known:
            lines.append(f"  {r.name:<26s} {KNOWN_GAPS[r.name]}")
    if unexpected:
        lines.append(f"\n{len(unexpected)} UNEXPECTED failures:")
        for r in unexpected:
            lines.append(f"  {r.name:<26s} {r.detail}")
    # Only unexpected failures fail the build. A known gap that starts passing
    # is reported too, so the list cannot silently rot.
    fixed = [n for n in KNOWN_GAPS if n in {r.name for r in passed}]
    if fixed:
        lines.append("\nKnown gaps that now PASS - remove them from KNOWN_GAPS:")
        for n in fixed:
            lines.append(f"  {n}")
    return "\n".join(lines), (1 if unexpected else 0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tests-dir", default="verif/prog/riscv-tests")
    ap.add_argument("--build", default="/build/regress")
    ap.add_argument("--sim", required=True)
    ap.add_argument("--compare", default="scripts/compare_trace.py")
    ap.add_argument("--filter", default="", help="only run tests containing this substring")
    args = ap.parse_args()

    build = Path(args.build)
    build.mkdir(parents=True, exist_ok=True)

    elfs = discover(Path(args.tests_dir) / "isa")
    if args.filter:
        elfs = [e for e in elfs if args.filter in e.name]
    if not elfs:
        print("No tests found - run `make fetch-tests` and build the suite first.")
        return 1

    results = []
    for e in elfs:
        r = run_one(e, build, Path(args.sim), Path(args.compare))
        results.append(r)
        print(f"  {'PASS' if r.passed else 'FAIL'}  {e.name}"
              + (f"   {r.detail}" if not r.passed else ""))

    text, code = summarize(results)
    print(text)
    return code


if __name__ == "__main__":
    sys.exit(main())
