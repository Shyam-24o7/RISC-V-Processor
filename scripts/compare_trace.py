#!/usr/bin/env python3
"""Compare an RTL RVFI trace against Spike's commit log.

We deliberately use only Spike's stable command-line interface
(`spike -l --log-commits`). Spike's C++ internals are documented upstream as a
non-public API subject to breaking change, so a DPI lockstep bridge would bind
us to an unstable interface.

Spike commit-log line:
    core   0: 3 0x00001000 (0x00000297) x 5 0x00001000
              ^priv ^pc      ^insn        ^rd ^value

RTL trace line (emitted by verif/tb/tb_core_sc.sv):
    <order> <pc> <insn> <rd> <rd_value>      -- all hex, no 0x prefix

Exit codes:
    0  traces agree
    1  divergence (including a truncated trace on either side)
    2  a trace file could not be parsed
"""
from __future__ import annotations

import argparse
import re
import sys
from typing import NamedTuple


class Retire(NamedTuple):
    pc: int
    insn: int
    rd: int
    rd_value: int


class TraceParseError(Exception):
    """A line looked like a trace record but could not be decoded.

    Raised rather than skipped: a corrupted line that is silently dropped
    shifts every subsequent index, so the divergence report would blame the
    wrong instruction. Failing loudly is the only honest option.
    """


# "core N: <priv> 0xPC (0xINSN)" optionally followed by " x RD 0xVALUE".
_SPIKE_RE = re.compile(
    r"^core\s+\d+:\s+\d+\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)"
    r"(?:\s+x\s*(\d+)\s+0x([0-9a-fA-F]+))?"
)


def parse_spike(lines) -> list[Retire]:
    out = []
    for line in lines:
        m = _SPIKE_RE.match(line.strip())
        if not m:
            continue  # banner, symbol dumps, warnings
        pc, insn, rd, val = m.groups()
        out.append(
            Retire(
                pc=int(pc, 16),
                insn=int(insn, 16),
                rd=int(rd) if rd is not None else 0,
                rd_value=int(val, 16) if val is not None else 0,
            )
        )
    return out


def parse_rtl(lines) -> list[Retire]:
    out = []
    for lineno, line in enumerate(lines, start=1):
        parts = line.split()
        if len(parts) != 5:
            continue
        _order, pc, insn, rd, val = parts
        try:
            out.append(
                Retire(
                    pc=int(pc, 16),
                    insn=int(insn, 16),
                    rd=int(rd, 16),
                    rd_value=int(val, 16),
                )
            )
        except ValueError as exc:
            raise TraceParseError(
                f"RTL trace line {lineno} has 5 fields but is not valid hex: "
                f"{line.strip()!r} ({exc})"
            ) from exc
    return out


def first_divergence(rtl: list[Retire], spike: list[Retire]):
    """Return (index, rtl_entry, spike_entry) or None if the traces agree.

    A missing entry on either side is reported as a divergence with None in
    that position, so a truncated RTL run (hang, early $finish) is not silently
    treated as a pass.
    """
    for i in range(max(len(rtl), len(spike))):
        r = rtl[i] if i < len(rtl) else None
        s = spike[i] if i < len(spike) else None
        if r != s:
            return (i, r, s)
    return None


def _fmt(r: Retire | None) -> str:
    if r is None:
        return "<end of trace>"
    return (
        f"pc=0x{r.pc:08x} insn=0x{r.insn:08x} "
        f"x{r.rd:<2d}=0x{r.rd_value:08x}"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", required=True)
    ap.add_argument("--spike", required=True)
    ap.add_argument("--start-pc", default=None,
                    help="hex PC at which to begin comparing. Leading records "
                         "before the FIRST occurrence of this PC are dropped "
                         "from both traces. Needed because Spike executes a "
                         "5-instruction boot ROM at 0x1000 that the RTL, which "
                         "resets straight to the entry point, never runs.")
    ap.add_argument("--stop-pc", default=None,
                    help="hex PC at which to stop comparing (exclusive). Both "
                         "traces are cut at the first occurrence, so they end "
                         "at the same instruction. Used for the post-completion "
                         "spin loop, which the RTL never enters but Spike runs "
                         "until HTIF polls. Truncation detection still applies "
                         "to everything before this point.")
    ap.add_argument("--max-insn", type=int, default=0,
                    help="compare only the first N retirements (0 = all). "
                         "Both traces must still REACH N; a shorter trace is "
                         "reported as truncated, never silently accepted.")
    args = ap.parse_args()

    try:
        with open(args.rtl) as f:
            rtl = parse_rtl(f)
        with open(args.spike) as f:
            spike = parse_spike(f)
    except TraceParseError as exc:
        print(f"TRACE PARSE ERROR: {exc}")
        return 2

    if args.start_pc is not None:
        want = int(args.start_pc, 16)
        for name, tr in (("RTL", rtl), ("Spike", spike)):
            if not any(r.pc == want for r in tr):
                print(f"START PC NOT FOUND: 0x{want:08x} never appears in the "
                      f"{name} trace ({len(tr)} instructions). The program may "
                      f"not have reached its entry point.")
                return 1
        rtl = rtl[next(i for i, r in enumerate(rtl) if r.pc == want):]
        spike = spike[next(i for i, r in enumerate(spike) if r.pc == want):]

    if args.stop_pc is not None:
        stop = int(args.stop_pc, 16)
        def cut(tr):
            for i, r in enumerate(tr):
                if r.pc == stop:
                    return tr[:i]
            return tr          # never reached it: compare the whole trace
        rtl, spike = cut(rtl), cut(spike)

    # --max-insn bounds how much is COMPARED, never whether truncation is
    # DETECTED. Slicing both lists first would make a short RTL trace -- a hung
    # or early-exiting core, precisely what this tool exists to catch -- look
    # like a clean match. So require both traces to reach N before bounding.
    if args.max_insn:
        for name, tr in (("RTL", rtl), ("Spike", spike)):
            if len(tr) < args.max_insn:
                print(f"TRUNCATED: {name} trace has {len(tr)} instructions, "
                      f"fewer than the requested --max-insn {args.max_insn}")
                return 1
        rtl = rtl[: args.max_insn]
        spike = spike[: args.max_insn]

    d = first_divergence(rtl, spike)
    if d is None:
        print(f"MATCH: {len(rtl)} instructions agree")
        return 0

    i, r, s = d
    print(f"DIVERGENCE at instruction #{i}")
    print(f"  RTL   {_fmt(r)}")
    print(f"  Spike {_fmt(s)}")
    print("\nPreceding 5 instructions (RTL):")
    for j in range(max(0, i - 5), i):
        print(f"  #{j:<6d} {_fmt(rtl[j])}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
