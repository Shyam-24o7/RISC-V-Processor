import subprocess, sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from compare_trace import (
    parse_spike,
    parse_rtl,
    first_divergence,
    Retire,
    TraceParseError,
)

SCRIPT = Path(__file__).parent / "compare_trace.py"


def _run(tmp_path, rtl_lines, spike_lines, *extra):
    """Invoke the CLI exactly as the Makefile does; return (rc, stdout)."""
    rtl_f = tmp_path / "t.rtl"
    spk_f = tmp_path / "t.spike"
    rtl_f.write_text("".join(l + "\n" for l in rtl_lines))
    spk_f.write_text("".join(l + "\n" for l in spike_lines))
    p = subprocess.run(
        [sys.executable, str(SCRIPT), "--rtl", str(rtl_f), "--spike", str(spk_f), *extra],
        capture_output=True, text=True,
    )
    return p.returncode, p.stdout


def test_parse_spike_with_writeback():
    line = "core   0: 3 0x00001000 (0x00000297) x 5 0x00001000"
    (r,) = parse_spike([line])
    assert r == Retire(pc=0x1000, insn=0x00000297, rd=5, rd_value=0x1000)


def test_parse_spike_without_writeback():
    # A store writes no register, so rd must normalize to 0. Real Spike appends
    # " mem 0xADDR 0xVALUE" for loads/stores; _SPIKE_RE uses re.match (prefix
    # semantics) so the trailing text is correctly ignored. Using the real
    # format here rather than a bare line keeps the fixture honest.
    line = "core   0: 3 0x00001004 (0x00512023) mem 0x00002000 0x0000002a"
    (r,) = parse_spike([line])
    assert r == Retire(pc=0x1004, insn=0x00512023, rd=0, rd_value=0)


def test_parse_spike_load_with_writeback_and_mem_suffix():
    # A load writes a register AND touches memory; both must parse, with the
    # register capture unaffected by the trailing mem text.
    line = "core   0: 3 0x00001008 (0x00002503) x10 0x0000002a mem 0x00002000"
    (r,) = parse_spike([line])
    assert r == Retire(pc=0x1008, insn=0x00002503, rd=10, rd_value=0x2A)


def test_parse_spike_skips_non_commit_lines():
    lines = ["warning: tohost not found", "core   0: >>>>  _start"]
    assert parse_spike(lines) == []


def test_parse_rtl():
    (r,) = parse_rtl(["0 00001000 00000297 05 00001000"])
    assert r == Retire(pc=0x1000, insn=0x00000297, rd=5, rd_value=0x1000)


def test_identical_traces_have_no_divergence():
    t = [Retire(0x1000, 0x297, 5, 0x1000)]
    assert first_divergence(t, t) is None


def test_divergence_reports_index_and_fields():
    a = [Retire(0x1000, 0x297, 5, 0x1000), Retire(0x1004, 0x13, 1, 4)]
    b = [Retire(0x1000, 0x297, 5, 0x1000), Retire(0x1004, 0x13, 1, 99)]
    d = first_divergence(a, b)
    assert d is not None
    idx, rtl, spike = d
    assert idx == 1
    assert rtl.rd_value == 4 and spike.rd_value == 99


def test_truncated_rtl_trace_is_a_divergence():
    a = [Retire(0x1000, 0x297, 5, 0x1000)]
    b = a + [Retire(0x1004, 0x13, 1, 4)]
    d = first_divergence(a, b)
    assert d is not None and d[0] == 1


def test_malformed_rtl_line_raises_clean_error():
    # 5 fields, so it looks like a record, but the PC is not hex. Skipping it
    # would shift every later index and blame the wrong instruction, so it must
    # raise rather than be dropped.
    with pytest.raises(TraceParseError) as exc:
        parse_rtl(["0 ZZZZZZZZ 00000297 05 00001000"])
    assert "line 1" in str(exc.value)


# ---- CLI contract: exit codes are what the Makefile and CI depend on ----

MATCH_RTL = ["0 00001000 00000297 05 00001000"]
MATCH_SPIKE = ["core   0: 3 0x00001000 (0x00000297) x 5 0x00001000"]


def test_cli_exit_0_on_match(tmp_path):
    rc, out = _run(tmp_path, MATCH_RTL, MATCH_SPIKE)
    assert rc == 0 and "MATCH" in out


def test_cli_exit_1_on_divergence(tmp_path):
    rc, out = _run(tmp_path, ["0 00001000 00000297 05 DEADBEEF"], MATCH_SPIKE)
    assert rc == 1 and "DIVERGENCE at instruction #0" in out


def test_cli_exit_2_on_unparseable_trace(tmp_path):
    rc, out = _run(tmp_path, ["0 ZZZZZZZZ 00000297 05 00001000"], MATCH_SPIKE)
    assert rc == 2 and "TRACE PARSE ERROR" in out


def test_cli_empty_rtl_against_nonempty_spike_fails(tmp_path):
    rc, out = _run(tmp_path, [], MATCH_SPIKE)
    assert rc == 1 and "DIVERGENCE at instruction #0" in out


# ---- --max-insn must bound comparison WITHOUT masking truncation ----

THREE_RTL = [f"{i} 0000100{i} 00000013 00 00000000" for i in range(3)]
THREE_SPIKE = [
    f"core   0: 3 0x0000100{i} (0x00000013)" for i in range(3)
]


def test_max_insn_compares_prefix_when_both_long_enough(tmp_path):
    rc, out = _run(tmp_path, THREE_RTL, THREE_SPIKE, "--max-insn", "2")
    assert rc == 0 and "MATCH: 2 instructions agree" in out


def test_max_insn_does_not_mask_a_short_rtl_trace(tmp_path):
    # The regression this guards: slicing both traces to N first would report
    # MATCH for a hung core whose trace stopped early.
    rc, out = _run(tmp_path, THREE_RTL[:1], THREE_SPIKE, "--max-insn", "3")
    assert rc == 1
    assert "TRUNCATED" in out and "RTL trace has 1 instructions" in out


def test_max_insn_does_not_mask_a_short_spike_trace(tmp_path):
    rc, out = _run(tmp_path, THREE_RTL, THREE_SPIKE[:1], "--max-insn", "3")
    assert rc == 1 and "TRUNCATED" in out and "Spike" in out
