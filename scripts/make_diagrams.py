#!/usr/bin/env python3
"""Generate the README's architecture diagrams and result charts.

Every figure in docs/img/ is produced here, so the style stays consistent and
a figure can be regenerated when the design changes:

    python scripts/make_diagrams.py

Block diagrams are written as plain SVG. Charts use matplotlib with the
numbers recorded in results/experiments.md and results/raw/*.json.
"""
from __future__ import annotations

from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "docs" / "img"

FONT = "Segoe UI, Helvetica Neue, Arial, sans-serif"
MONO = "Consolas, Menlo, DejaVu Sans Mono, monospace"

INK, MUTED, LINE = "#0f172a", "#475569", "#94a3b8"
STAGE = {  # (fill, stroke)
    "IF":  ("#e0f2fe", "#0284c7"),
    "ID":  ("#ede9fe", "#7c3aed"),
    "EX":  ("#fef3c7", "#d97706"),
    "MEM": ("#dcfce7", "#16a34a"),
    "WB":  ("#ffe4e6", "#e11d48"),
}
CACHE = ("#ccfbf1", "#0d9488")
CSR = ("#f3e8ff", "#9333ea")
HAZ = ("#fee2e2", "#dc2626")
NEUTRAL = ("#f8fafc", "#64748b")
REG = "#334155"
FWD, CTRL, EARLY, FLUSH = "#ea580c", "#dc2626", "#0d9488", "#9333ea"
ARROW_COLORS = [INK, MUTED, FWD, CTRL, EARLY, FLUSH, "#0284c7", "#16a34a", "#e11d48",
                "#ca8a04", "#4f46e5", "#c2410c", "#1d72b8"]


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Svg:
    def __init__(self, w: int, h: int, title: str):
        self.w, self.h, self.title = w, h, title
        self.parts: list[str] = []

    # ---- primitives -------------------------------------------------------
    def rect(self, x, y, w, h, fill, stroke, rx=8, sw=1.6, dash=None, opacity=1):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.parts.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" '
            f'fill-opacity="{opacity}" stroke="{stroke}" stroke-width="{sw}"{d}/>')

    def text(self, x, y, s, size=13, anchor="middle", weight="normal", fill=INK,
             mono=False, italic=False, rotate=None):
        fam = MONO if mono else FONT
        st = ' font-style="italic"' if italic else ""
        tr = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        lines = s.split("\n")
        if len(lines) == 1:
            self.parts.append(
                f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" '
                f'text-anchor="{anchor}" font-weight="{weight}" fill="{fill}"{st}{tr}>{esc(s)}</text>')
            return
        lh = size * 1.28
        y0 = y - lh * (len(lines) - 1) / 2
        spans = "".join(
            f'<tspan x="{x}" y="{y0 + i * lh:.1f}">{esc(t)}</tspan>' for i, t in enumerate(lines))
        self.parts.append(
            f'<text font-family="{fam}" font-size="{size}" text-anchor="{anchor}" '
            f'font-weight="{weight}" fill="{fill}"{st}{tr}>{spans}</text>')

    def box(self, x, y, w, h, colors, title, sub=None, size=14, subsize=11.5, rx=8,
            dash=None, mono_sub=False):
        fill, stroke = colors
        self.rect(x, y, w, h, fill, stroke, rx=rx, dash=dash)
        if sub:
            self.text(x + w / 2, y + 20, title, size=size, weight="600")
            self.text(x + w / 2, y + 20 + (h - 20) / 2 + 2, sub, size=subsize, fill=MUTED,
                      mono=mono_sub)
        else:
            self.text(x + w / 2, y + h / 2 + size * 0.35, title, size=size, weight="600")

    def arrow(self, pts, color=INK, width=1.7, dash=None, head=True, both=False):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        cid = ARROW_COLORS.index(color)
        mk = f' marker-end="url(#ah{cid})"' if head else ""
        if both:
            mk += f' marker-start="url(#as{cid})"'
        p = " ".join(f"{x},{y}" for x, y in pts)
        self.parts.append(
            f'<polyline points="{p}" fill="none" stroke="{color}" stroke-width="{width}" '
            f'stroke-linejoin="round"{d}{mk}/>')

    def label(self, x, y, s, color=MUTED, size=11, anchor="middle", mono=True, bg=True,
              weight="normal"):
        if bg:
            w = len(max(s.split("\n"), key=len)) * size * (0.62 if mono else 0.56) + 8
            n = len(s.split("\n"))
            h = size * 1.28 * n + 4
            self.parts.append(
                f'<rect x="{x - w / 2 if anchor == "middle" else (x - 4 if anchor == "start" else x - w + 4)}" '
                f'y="{y - h / 2 - size * 0.32}" width="{w}" height="{h}" rx="3" fill="#ffffff" '
                f'fill-opacity="0.92"/>')
        self.text(x, y, s, size=size, anchor=anchor, fill=color, mono=mono, weight=weight)

    def mux(self, x, y, w, h, colors=NEUTRAL, s="MUX", size=10):
        fill, stroke = colors
        k = h * 0.2
        self.parts.append(
            f'<polygon points="{x},{y} {x + w},{y + k} {x + w},{y + h - k} {x},{y + h}" '
            f'fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        self.text(x + w / 2, y + h / 2 + 3.5, s, size=size, weight="600", rotate=-90)

    def pipereg(self, x, y, h, name):
        self.rect(x, y, 24, h, REG, REG, rx=4)
        self.text(x + 12, y + h / 2, name, size=12, weight="600", fill="#ffffff", rotate=-90)

    def raw(self, s):
        self.parts.append(s)

    # ---- output -----------------------------------------------------------
    def save(self, name):
        defs = []
        for i, c in enumerate(ARROW_COLORS):
            defs.append(
                f'<marker id="ah{i}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
                f'markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>')
            defs.append(
                f'<marker id="as{i}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
                f'markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>')
        body = "\n".join(self.parts)
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" '
            f'width="{self.w}" height="{self.h}" role="img" aria-label="{esc(self.title)}">\n'
            f'<title>{esc(self.title)}</title>\n<defs>{"".join(defs)}</defs>\n'
            f'<rect width="{self.w}" height="{self.h}" rx="14" fill="#ffffff"/>\n{body}\n</svg>\n')
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / name).write_text(svg, encoding="utf-8", newline="\n")
        print(f"wrote docs/img/{name}")


# ===========================================================================
# 1. System overview
# ===========================================================================
def system():
    s = Svg(1320, 660, "rv32_soc system overview")
    s.text(40, 42, "rv32_soc — the cached system", size=20, anchor="start", weight="700")
    s.text(40, 64, "Everything inside the dashed boundary is synthesised; main memory and the "
           "trace checker belong to the testbench.", size=12.5, anchor="start", fill=MUTED)

    s.rect(30, 84, 990, 550, "#ffffff", LINE, rx=14, dash="7 5", sw=1.4)
    s.text(1005, 108, "rv32_soc", size=13, anchor="end", weight="600", fill=MUTED, mono=True)

    # core
    s.rect(60, 118, 930, 176, "#f8fafc", "#334155", rx=12, sw=1.8)
    s.text(78, 144, "core_rv32i_p5 — five-stage in-order pipeline", size=15, anchor="start",
           weight="700")
    stages = [("IF", "fetch unit\n4-entry prefetch"), ("ID", "decode + regfile\nhazard detect"),
              ("EX", "ALU + forwarding\nbranch resolve"), ("MEM", "D$ access, CSRs\ntrap point"),
              ("WB", "writeback\nRVFI retire")]
    x = 84
    for i, (nm, sub) in enumerate(stages):
        s.box(x, 162, 158, 112, STAGE[nm], nm, sub, size=17, subsize=11.5)
        if i < 4:
            s.arrow([(x + 158, 218), (x + 178, 218)], INK)
        x += 180

    # RVFI out
    s.box(1060, 130, 236, 120, NEUTRAL, "Trace checker",
          "RVFI trace vs Spike\ncommit log, one\ninstruction at a time", subsize=11.5)
    s.arrow([(888, 162), (888, 104), (1040, 104), (1040, 190), (1058, 190)], MUTED, dash="5 4")
    s.label(964, 104, "rvfi_* (every retirement)", size=10.5)

    # caches
    s.box(84, 370, 300, 124, CACHE, "icache  ·  L1 instruction cache",
          "4 KiB · 2-way · 128 sets · 16 B lines\n1-cycle hit, one request per cycle\n"
          "blocking refill, FENCE.I = invalidate all", subsize=11.5)
    s.box(626, 370, 330, 124, CACHE, "dcache  ·  L1 data cache",
          "4 KiB · 2-way · write-back + write-allocate\n1-cycle hit (address sent one cycle early)\n"
          "dirty victim write-back · FENCE.I flush walk", subsize=11.5)

    # core <-> icache
    s.arrow([(130, 274), (130, 368)], "#0284c7")
    s.label(130, 336, "req / addr", size=10.5)
    s.arrow([(220, 368), (220, 274)], "#0284c7")
    s.label(220, 316, "gnt · rvalid\nrdata", size=10.5)
    # core <-> dcache
    s.arrow([(640, 274), (640, 368)], "#16a34a")
    s.label(640, 346, "req/addr/we\nbe/wdata", size=10.5)
    s.arrow([(770, 274), (770, 368)], EARLY, dash="5 4")
    s.label(770, 330, "pre_addr\n(1 cycle early)", size=10.5, color=EARLY)
    s.arrow([(900, 368), (900, 274)], "#16a34a")
    s.label(900, 320, "ready · rdata", size=10.5)

    # FENCE.I chain
    s.arrow([(692, 274), (692, 368)], FLUSH, dash="5 4")
    s.label(692, 300, "flush_req", size=10.5, color=FLUSH)
    s.arrow([(624, 470), (388, 470)], FLUSH, dash="5 4")
    s.label(505, 470, "D$ done → inv_req", size=10.5, color=FLUSH)
    s.arrow([(350, 368), (350, 310), (613, 310), (613, 276)], FLUSH, dash="5 4")
    s.label(480, 310, "inv_done → flush_done (MEM)", size=10.5, color=FLUSH)

    # arbiter
    s.box(360, 534, 330, 76, NEUTRAL, "mem_arbiter",
          "data side wins ties · grant held for a whole line", subsize=11.5)
    s.arrow([(234, 494), (234, 572), (358, 572)], INK)
    s.arrow([(790, 494), (790, 572), (692, 572)], INK)
    s.label(234, 530, "line port", size=10.5)
    s.label(790, 530, "line port", size=10.5)

    # main memory
    s.box(1060, 470, 236, 140, NEUTRAL, "main_mem (simulation)",
          "LATENCY wait states\n16-byte lines, word array\nloaded from the program hex",
          subsize=11.5)
    s.arrow([(690, 596), (1058, 596)], INK, both=True)
    s.label(860, 596, "req·we·addr[31:4]·wdata[127:0] ⇄ ready·rdata[127:0]", size=10)

    # legend
    lx, ly = 1060, 290
    s.text(lx, ly, "Legend", size=12, anchor="start", weight="700")
    items = [("#0284c7", None, "instruction path"), ("#16a34a", None, "data path"),
             (EARLY, "5 4", "early data address"), (FLUSH, "5 4", "FENCE.I handshake"),
             (MUTED, "5 4", "retirement trace")]
    for i, (c, d, t) in enumerate(items):
        yy = ly + 22 + i * 24
        s.arrow([(lx, yy), (lx + 34, yy)], c, dash=d)
        s.text(lx + 44, yy + 4, t, size=11.5, anchor="start", fill=MUTED)
    s.save("system.svg")


# ===========================================================================
# 2. Pipeline datapath
# ===========================================================================
def pipeline():
    s = Svg(1600, 980, "Five-stage pipeline datapath")
    s.text(30, 40, "core_rv32i_p5 — datapath, forwarding and control", size=20, anchor="start",
           weight="700")
    s.text(30, 62, "Pipeline registers are the dark bars. The fetch unit's buffer head is the "
           "IF/ID interface, so there is no separate IF/ID register.", size=12.5, anchor="start",
           fill=MUTED)

    for nm, x, w in [("IF", 30, 240), ("ID", 282, 272), ("EX", 600, 306), ("MEM", 950, 322),
                     ("WB", 1312, 258)]:
        f, st = STAGE[nm]
        s.rect(x, 84, w, 34, f, st, rx=8)
        s.text(x + w / 2, 107, nm, size=15, weight="700", fill=st)

    # ---- writeback bus along the top (drawn first, under everything) ----
    s.arrow([(1304, 266), (1336, 266), (1336, 134), (385, 134), (385, 156)], "#e11d48", width=2.2)
    s.label(1000, 134, "writeback   rd ← wb_data", size=10.5, color="#e11d48")
    s.arrow([(520, 134), (520, 176)], FWD, width=1.7, dash="3 3")
    s.label(560, 148, "WB → ID", size=10, color=FWD)

    # ---- register bars ----
    s.rect(262, 150, 12, 570, "#ffffff", "#0284c7", rx=3, dash="4 3", sw=1.2)
    s.text(268, 640, "buffer head = IF/ID", size=10.5, fill="#0284c7", rotate=-90)
    s.pipereg(562, 150, 570, "ID / EX")
    s.pipereg(918, 150, 570, "EX / MEM")
    s.pipereg(1280, 150, 570, "MEM / WB")

    # ---------------- IF ----------------
    s.rect(36, 150, 212, 300, STAGE["IF"][0], STAGE["IF"][1], rx=10)
    s.text(142, 172, "fetch_unit", size=14, weight="700")
    w = ("#ffffff", "#0284c7")
    s.box(50, 186, 184, 46, w, "fetch_pc", "+4 on each issue", size=12.5, subsize=10.5)
    s.box(50, 242, 184, 46, w, "in-flight PC queue", "4 entries, oldest first", size=12.5,
          subsize=10.5)
    s.box(50, 298, 184, 58, w, "instruction buffer", "4 × {pc, insn}\nhead feeds decode",
          size=12.5, subsize=10.5)
    s.box(50, 366, 184, 70, w, "discard_q", "responses still owed to\nan abandoned path",
          size=12.5, subsize=10.5)
    s.box(50, 520, 184, 86, CACHE, "L1 I-cache", "1-cycle hit · may withhold\ngnt during a refill",
          subsize=10.5)
    s.arrow([(100, 450), (100, 518)], "#0284c7")
    s.arrow([(184, 518), (184, 450)], "#0284c7")
    s.label(100, 484, "req·addr", size=10)
    s.label(184, 484, "gnt·rvalid·rdata", size=10)
    s.arrow([(248, 327), (280, 327), (280, 356), (298, 356)], INK)
    s.label(282, 314, "insn", size=10)
    s.box(50, 640, 184, 70, ("#eaf3fb", "#1d72b8"), "branch predictor",
          "BTB (64) + bimodal BHT (256)\nlooked up at fetch_pc", size=12.5, subsize=10.5)
    s.arrow([(242, 640), (242, 452)], "#1d72b8", dash="5 4")
    s.label(220, 622, "predicted next PC", size=9.5, color="#1d72b8")

    # ---------------- ID ----------------
    s.box(300, 158, 170, 120, STAGE["ID"], "register file",
          "32 × 32-bit · 2R / 1W\nasync read, sync write\nx0 reads as 0", subsize=10.5)
    s.box(300, 320, 170, 72, STAGE["ID"], "decoder", "insn → decoded_t\nimm · alu_op · flags",
          subsize=10.5)
    s.arrow([(385, 320), (385, 280)], INK)
    s.label(424, 300, "rs1/rs2 addr", size=9.5)
    s.mux(506, 178, 26, 92, STAGE["ID"], "BYPASS", size=8.5)
    s.arrow([(470, 200), (504, 200)], INK)
    s.arrow([(470, 248), (504, 248)], INK)
    s.arrow([(532, 224), (560, 224)], INK)
    s.arrow([(470, 356), (560, 356)], INK)
    s.label(515, 342, "decoded_t", size=10)
    s.box(300, 430, 236, 92, HAZ, "hazard detection",
          "producer in EX is a load or CSR read,\nconsumer in ID needs its rd\n→ stall_ld_use: one bubble",
          subsize=10.5)
    s.arrow([(536, 476), (560, 476)], CTRL, dash="5 4")

    # ---------------- EX ----------------
    s.mux(612, 180, 28, 72, STAGE["EX"], "FWD", size=9.5)
    s.mux(612, 276, 28, 72, STAGE["EX"], "FWD", size=9.5)
    s.arrow([(586, 200), (610, 200)], INK)
    s.arrow([(586, 296), (610, 296)], INK)
    s.mux(672, 186, 24, 60, STAGE["EX"], "A", size=10)
    s.mux(672, 282, 24, 60, STAGE["EX"], "B", size=10)
    s.label(684, 174, "pc | rs1", size=9.5)
    s.label(684, 354, "imm | rs2", size=9.5)
    s.raw('<polygon points="720,180 800,210 800,310 720,340 720,282 736,260 720,238" '
          f'fill="{STAGE["EX"][0]}" stroke="{STAGE["EX"][1]}" stroke-width="1.7"/>')
    s.text(764, 266, "ALU", size=15, weight="700")
    s.arrow([(640, 216), (670, 216)], INK)
    s.arrow([(640, 312), (670, 312)], INK)
    s.arrow([(696, 216), (718, 216)], INK)
    s.arrow([(696, 312), (718, 312)], INK)
    s.arrow([(800, 272), (916, 272)], INK)
    s.label(866, 260, "result", size=10)
    s.box(700, 368, 150, 40, STAGE["EX"], "link = pc + 4", None, size=12)
    s.arrow([(850, 388), (884, 388), (884, 272)], INK, head=False)
    # operand distribution lanes (rs1 at x=660, rs2 at x=652)
    s.arrow([(660, 216), (660, 566), (698, 566)], INK)
    s.arrow([(660, 478), (698, 478)], INK)
    s.arrow([(652, 312), (652, 596), (698, 596)], INK)
    s.arrow([(652, 432), (916, 432)], INK)
    for x, y in [(660, 216), (652, 312), (660, 478), (652, 432)]:
        s.raw(f'<circle cx="{x}" cy="{y}" r="3.2" fill="{INK}"/>')
    s.label(800, 422, "store data (rs2)", size=10)
    s.box(700, 456, 180, 44, STAGE["EX"], "address adder", "rs1 + imm", size=12.5, subsize=10.5)
    s.arrow([(880, 478), (916, 478)], INK)
    s.box(700, 548, 190, 66, STAGE["EX"], "branch unit",
          "outcome + target, checked\nagainst the prediction", subsize=10.5)
    s.arrow([(890, 576), (916, 576)], INK)
    s.label(902, 556, "pc_next · mispredict", size=9.5)
    # early data address: skips the EX/MEM register on purpose
    s.arrow([(790, 500), (790, 514), (958, 514)], EARLY, dash="5 4", width=2)
    s.label(842, 528, "pre_addr (skips EX/MEM)", size=9.5, color=EARLY)

    # ---------------- MEM ----------------
    s.box(960, 158, 172, 90, CSR, "CSR file",
          "machine-mode CSRs + counters\nread / written here,\nin program order", subsize=10.5)
    s.mux(1186, 196, 30, 140, STAGE["MEM"], "WB SELECT", size=9.5)
    s.arrow([(942, 272), (1184, 272)], INK)
    s.label(1060, 272, "alu / link result", size=10)
    s.arrow([(1132, 214), (1184, 214)], INK)
    s.label(1158, 204, "csr", size=9.5)
    s.box(960, 420, 172, 100, CACHE, "L1 D-cache port",
          "addr · we · be · wdata →\n← ready · rdata\nstall_mem until ready", subsize=10.5)
    s.arrow([(942, 440), (958, 440)], INK)
    s.arrow([(942, 478), (958, 478)], INK)
    s.box(1152, 420, 112, 100, STAGE["MEM"], "load extract", "byte / half\nsign / zero",
          size=12, subsize=10.5)
    s.arrow([(1132, 470), (1150, 470)], INK)
    s.arrow([(1201, 420), (1201, 338)], INK)
    s.label(1230, 380, "load", size=9.5)
    s.arrow([(1216, 266), (1278, 266)], INK)
    s.box(960, 560, 172, 100, CSR, "redirect · train",
          "trap / mret / FENCE.I / mispredict\n→ mtvec / mepc / pc+4 / real PC\n"
          "trains the branch predictor", size=12.5, subsize=10.5)
    s.arrow([(942, 610), (958, 610)], INK)

    # ---------------- WB ----------------
    s.box(1336, 420, 214, 120, STAGE["WB"], "RVFI retirement port",
          "valid · order · insn · trap\nrd_addr · rd_wdata\npc_rdata · pc_wdata\n→ compared with Spike",
          size=13, subsize=10.5)
    s.arrow([(1304, 480), (1334, 480)], INK)

    # ---------------- forwarding lanes ----------------
    s.arrow([(930, 720), (930, 760), (598, 760), (598, 222), (610, 222)], FWD, width=2)
    s.arrow([(598, 318), (610, 318)], FWD, width=2)
    s.arrow([(1292, 720), (1292, 784), (592, 784), (592, 238), (610, 238)], FWD, width=2,
            dash="7 4")
    s.arrow([(592, 334), (610, 334)], FWD, width=2, dash="7 4")
    s.label(760, 760, "EX/MEM → EX   (ALU and link results)", size=10.5, color=FWD)
    s.label(1110, 784, "MEM/WB → EX   (every result, including loads and CSR reads)", size=10.5,
            color=FWD)

    # ---------------- redirect lane ----------------
    s.arrow([(1046, 660), (1046, 840), (256, 840), (256, 432), (250, 432)], CTRL, width=2)
    s.label(560, 840, "redirect_pc from MEM   priority: trap › mret › FENCE.I › branch "
            "misprediction", size=10.5, color=CTRL)

    # ---------------- legend / notes ----------------
    lx, ly = 30, 884
    items = [(INK, None, "data"), (FWD, None, "forwarding"), ("#e11d48", None, "writeback"),
             (CTRL, None, "redirect"), (CTRL, "5 4", "stall"), (EARLY, "5 4",
                                                                  "early D$ address")]
    for i, (c, d, t) in enumerate(items):
        xx = lx + i * 165
        s.arrow([(xx, ly), (xx + 34, ly)], c, dash=d)
        s.text(xx + 42, ly + 4, t, size=11.5, anchor="start", fill=MUTED)
    s.text(30, 920, "stall_mem (D$ not ready, or FENCE.I waiting): fetch stops popping, ID/EX "
           "holds and re-latches its forwarded operands, EX/MEM holds, MEM/WB receives a bubble.",
           size=11.5, anchor="start", fill=MUTED)
    s.text(30, 942, "flush (trap, mret, FENCE.I done, branch misprediction): younger instructions "
           "become bubbles; the fetch unit drops its buffer and discards responses still owed.",
           size=11.5, anchor="start", fill=MUTED)
    s.save("pipeline.svg")



# ===========================================================================
# 2b. Conventional pipelined datapath (Patterson & Hennessy notation)
# ===========================================================================
BLUE = "#1d72b8"
BLUE_FILL = "#eaf3fb"


def conventional():
    """Datapath and control drawn in the textbook convention: black datapath,
    blue control, 'Mux' pills, trapezoid adders and ALU, tall pipeline
    registers carrying their WB / M / EX control fields."""
    s = Svg(1600, 940, "Pipelined datapath and control in textbook notation")
    s.text(30, 38, "core_rv32i_p5 — pipelined datapath and control", size=20, anchor="start",
           weight="700")
    s.text(30, 60, "Textbook notation (Patterson & Hennessy): black = datapath, blue = control. "
           "Branches are predicted in IF, checked in EX, redirected and trained from MEM.", size=12.5, anchor="start",
           fill=MUTED)

    def pill(x, y, h, label="M\nu\nx", w=24):
        s.rect(x, y, w, h, "#ffffff", INK, rx=w / 2, sw=1.5)
        s.text(x + w / 2, y + h / 2 + 1, label, size=9.5, weight="600")

    def adder(x, y, w=46, h=70, label="Add"):
        s.raw(f'<polygon points="{x},{y} {x + w},{y + h * 0.28} {x + w},{y + h * 0.72} '
              f'{x},{y + h} {x},{y + h * 0.62} {x + w * 0.22},{y + h / 2} {x},{y + h * 0.38}" '
              f'fill="#ffffff" stroke="{INK}" stroke-width="1.5"/>')
        s.text(x + w * 0.6, y + h / 2 + 4, label, size=10, weight="600")

    def unit(x, y, w, h, label, rx=None, size=11):
        s.rect(x, y, w, h, BLUE_FILL, BLUE, rx=(rx if rx is not None else h / 2), sw=1.6)
        s.text(x + w / 2, y + h / 2 + 4, label, size=size, weight="600", fill=BLUE)

    def blk(x, y, w, h, label, size=11.5):
        s.rect(x, y, w, h, "#ffffff", INK, rx=4, sw=1.5)
        s.text(x + w / 2, y + h / 2 + 4, label, size=size, weight="600")

    def preg(x, name, fields):
        top, bot = 190, 800
        s.rect(x, top, 30, bot - top, "#f1f5f9", INK, rx=3, sw=1.6)
        s.text(x + 15, top - 8, name, size=11.5, weight="700")
        for i, f in enumerate(fields):
            s.rect(x + 2, top + 4 + i * 24, 26, 20, BLUE_FILL, BLUE, rx=2, sw=1.2)
            s.text(x + 15, top + 18 + i * 24, f, size=9.5, weight="700", fill=BLUE)

    def L(pts, c=INK, w=1.5, dash=None, head=True):
        s.arrow(pts, c, width=w, dash=dash, head=head)

    def dot(x, y, c=INK):
        s.raw(f'<circle cx="{x}" cy="{y}" r="3" fill="{c}"/>')

    # stage names
    for nm, x0, x1 in [("IF", 20, 330), ("ID", 360, 640), ("EX", 670, 1040),
                       ("MEM", 1070, 1300), ("WB", 1330, 1590)]:
        s.text((x0 + x1) / 2, 92, nm, size=14, weight="700", fill=STAGE[nm][1])

    # pipeline registers
    preg(330, "IF/ID", [])
    preg(640, "ID/EX", ["WB", "M", "EX"])
    preg(1040, "EX/MEM", ["WB", "M"])
    preg(1300, "MEM/WB", ["WB"])
    s.text(345, 815, "fetch buffer", size=9.5, fill=MUTED)

    # ================= IF =================
    pill(36, 420, 110)
    blk(84, 450, 40, 50, "PC", 12)
    L([(60, 475), (82, 475)])
    blk(150, 420, 140, 110, "Instruction\nmemory\n(L1 I-cache)", 11)
    L([(124, 475), (148, 475)])
    L([(290, 475), (328, 475)])
    s.label(305, 465, "insn", size=9.5)
    adder(170, 250)
    L([(132, 475), (132, 300), (168, 300)])
    dot(132, 475)
    s.text(150, 268, "4", size=11, weight="700")
    L([(156, 272), (168, 272)])
    # pc+4 back to PC mux
    L([(216, 285), (236, 285), (236, 232), (22, 232), (22, 440), (34, 440)])
    s.label(120, 232, "pc + 4", size=9.5)
    # branch predictor
    unit(150, 330, 140, 64, "BTB (64)\n+ bimodal BHT (256)", rx=8, size=10.5)
    L([(132, 362), (148, 362)])
    L([(150, 380), (14, 380), (14, 470), (34, 470)])
    s.label(80, 380, "predicted target", size=9.5)
    L([(290, 345), (306, 345), (306, 160), (48, 160), (48, 418)], BLUE, dash="5 3")
    s.label(176, 160, "predict taken", size=9.5, color=BLUE)
    # PC and prediction also travel down the pipe
    L([(140, 500), (140, 560), (328, 560)])
    dot(140, 475)
    s.label(240, 560, "pc, pred_next", size=9.5)

    # ================= ID =================
    unit(388, 126, 170, 46, "Hazard\ndetection unit", rx=10, size=10.5)
    unit(440, 205, 120, 66, "Control", size=12)
    pill(596, 205, 64, label="M\nu\nx", w=22)
    s.text(588, 214, "0", size=10, weight="700")
    L([(560, 238), (594, 238)], BLUE)
    L([(618, 237), (642, 237)], BLUE)
    s.rect(410, 380, 160, 180, "#ffffff", INK, rx=4, sw=1.5)
    s.text(490, 400, "Registers", size=12.5, weight="700")
    for yy, t in [(430, "Read reg 1"), (470, "Read reg 2"), (510, "Write reg"),
                  (545, "Write data")]:
        s.text(416, yy, t, size=9.5, anchor="start", fill=MUTED)
    for yy, t in [(430, "Read data 1"), (500, "Read data 2")]:
        s.text(564, yy, t, size=9.5, anchor="end", fill=MUTED)
    s.raw(f'<ellipse cx="490" cy="640" rx="46" ry="28" fill="#ffffff" stroke="{INK}" '
          f'stroke-width="1.5"/>')
    s.text(490, 644, "Imm Gen", size=11, weight="600")
    # instruction fields out of IF/ID
    L([(360, 475), (380, 475), (380, 238), (438, 238)], INK)
    s.label(392, 300, "opcode", size=9)
    L([(380, 426), (408, 426)])
    L([(380, 466), (408, 466)])
    L([(380, 466), (380, 640), (442, 640)])
    dot(380, 426); dot(380, 466); dot(380, 475)
    s.label(395, 452, "rs1  rs2", size=9)
    L([(380, 640), (380, 700), (638, 700)])
    s.label(520, 700, "rd", size=9.5)
    L([(570, 430), (638, 430)])
    L([(570, 500), (638, 500)])
    L([(536, 640), (638, 640)])
    s.label(600, 628, "imm", size=9.5)
    L([(360, 560), (638, 560)])
    # hazard detection
    L([(473, 172), (473, 186), (607, 186), (607, 203)], BLUE, dash="5 3")
    L([(388, 149), (318, 149), (318, 212), (328, 212)], BLUE, dash="5 3")
    s.label(352, 141, "stall", size=9, color=BLUE)
    L([(640, 300), (628, 300), (628, 160), (560, 160)], BLUE, dash="5 3")
    s.label(596, 300, "MemRead · rd", size=9, color=BLUE)

    # ================= EX =================
    pill(696, 395, 70)
    pill(696, 480, 70)
    L([(670, 430), (694, 430)])
    L([(670, 500), (694, 500)])
    pill(770, 488, 70)
    L([(720, 515), (768, 515)])
    L([(670, 640), (750, 640), (750, 540), (768, 540)])
    # ALU
    s.raw(f'<polygon points="826,388 900,420 900,520 826,552 826,494 842,470 826,446" '
          f'fill="#ffffff" stroke="{INK}" stroke-width="1.6"/>')
    s.text(872, 474, "ALU", size=13, weight="700")
    L([(720, 430), (824, 430)])
    L([(794, 523), (824, 523)])
    L([(900, 470), (1038, 470)])
    s.label(990, 460, "ALU result", size=9.5)
    # store data
    L([(708, 550), (708, 590), (1038, 590)])
    dot(708, 560)
    s.label(990, 580, "store data", size=9.5)
    # rd through
    L([(670, 700), (1038, 700)])
    # branch: target adder + compare + misprediction check
    adder(760, 260)
    L([(670, 560), (680, 560), (680, 312), (758, 312)])
    L([(750, 640), (750, 286), (758, 286)])
    dot(750, 640)
    blk(880, 330, 104, 42, "Branch\ncompare", 10.5)
    L([(724, 420), (724, 351), (878, 351)])
    dot(724, 430)
    unit(880, 230, 150, 64, "mispredict?\nnext PC ≠ pred_next", rx=8, size=10.5)
    L([(806, 295), (870, 295), (870, 262), (878, 262)])
    L([(932, 330), (932, 296)], BLUE, dash="5 3")
    L([(686, 560), (686, 214), (960, 214), (960, 228)], INK)
    dot(686, 560)
    s.label(800, 214, "pc + 4, pred_next", size=9)
    # ALU control from EX field
    L([(670, 250), (862, 250), (862, 402)], BLUE, dash="5 3")
    s.label(760, 250, "ALUOp", size=9, color=BLUE)
    # forwarding unit
    unit(740, 744, 180, 46, "Forwarding unit", rx=10)
    L([(740, 767), (708, 767), (708, 552)], BLUE, dash="5 3")
    L([(800, 744), (800, 474), (708, 474), (708, 467)], BLUE, dash="5 3")
    # forwarding data paths
    L([(1064, 470), (1064, 830), (684, 830), (684, 452), (694, 452)])
    s.label(870, 830, "EX/MEM → EX forward", size=9.5)
    L([(684, 520), (694, 520)])

    # ================= MEM =================
    s.rect(1090, 420, 150, 140, "#ffffff", INK, rx=4, sw=1.5)
    s.text(1165, 444, "Data memory", size=11.5, weight="700")
    s.text(1165, 506, "(L1 D-cache)", size=10.5, fill=MUTED)
    s.text(1096, 474, "Address", size=9.5, anchor="start", fill=MUTED)
    s.text(1096, 534, "Write data", size=9.5, anchor="start", fill=MUTED)
    s.text(1234, 474, "Read data", size=9.5, anchor="end", fill=MUTED)
    L([(1070, 470), (1088, 470)])
    L([(1070, 590), (1080, 590), (1080, 530), (1088, 530)])
    L([(1240, 470), (1298, 470)])
    L([(1064, 470), (1064, 380), (1298, 380)])
    dot(1064, 470)
    s.label(1110, 380, "ALU result / link", size=9.5)
    unit(1100, 610, 130, 60, "CSRs +\ntrap unit", rx=8, size=10.5)
    L([(1070, 640), (1098, 640)])
    L([(1230, 640), (1298, 640)])
    L([(1070, 700), (1298, 700)])
    L([(1070, 216), (1165, 216), (1165, 418)], BLUE, dash="5 3")
    s.label(1120, 205, "MemRead / MemWrite", size=9, color=BLUE)

    # ================= WB =================
    pill(1360, 400, 260)
    L([(1330, 470), (1358, 470)])
    L([(1330, 380), (1340, 380), (1340, 420), (1358, 420)])
    L([(1330, 640), (1358, 640)])
    L([(1330, 194), (1372, 194), (1372, 398)], BLUE, dash="5 3")
    s.label(1430, 194, "MemtoReg / RegWrite", size=9, color=BLUE)
    # writeback loop
    L([(1384, 530), (1420, 530), (1420, 870), (396, 870), (396, 545), (408, 545)], "#e11d48",
      w=2)
    s.label(900, 870, "write data", size=9.5, color="#e11d48")
    L([(1330, 700), (1440, 700), (1440, 886), (388, 886), (388, 510), (408, 510)])
    s.label(900, 886, "write register (rd)", size=9.5)
    # MEM/WB -> EX forward
    L([(1420, 850), (676, 850), (676, 535), (694, 535)], INK, dash="6 3")
    L([(676, 462), (694, 462)], INK, dash="6 3")
    s.label(1090, 850, "MEM/WB → EX forward", size=9.5)
    dot(1420, 850)

    # ================= redirect =================
    L([(1030, 262), (1038, 262)], BLUE, dash="5 3")
    L([(1072, 262), (1082, 262), (1082, 104), (10, 104), (10, 505), (34, 505)], BLUE,
      w=1.8)
    L([(1230, 625), (1260, 625), (1260, 104), (1082, 104)], BLUE, w=1.8, head=False)
    s.label(700, 104, "redirect from MEM: misprediction found in EX, or trap / mret / "
            "FENCE.I  ·  flushes younger instructions", size=9.5, color=BLUE)
    # predictor training, also from MEM
    L([(1092, 300), (1092, 116), (270, 116), (270, 328)], BLUE, dash="5 3")
    s.label(700, 116, "train BTB / BHT from MEM: pc, taken, target", size=9.5, color=BLUE)

    # legend
    s.text(1460, 280, "Notation", size=11.5, weight="700", anchor="start")
    L([(1460, 300), (1494, 300)])
    s.text(1500, 304, "datapath", size=10.5, anchor="start", fill=MUTED)
    L([(1460, 322), (1494, 322)], BLUE, dash="5 3")
    s.text(1500, 326, "control", size=10.5, anchor="start", fill=MUTED)
    L([(1460, 344), (1494, 344)], "#e11d48", w=2)
    s.text(1500, 348, "writeback", size=10.5, anchor="start", fill=MUTED)
    s.text(30, 920, "Simplified like the textbook figure: the fetch unit's 4-entry buffer is "
           "drawn as IF/ID, and the WB→ID register bypass, the early D-cache address and "
           "the separate address adder are omitted (see pipeline.svg for those).",
           size=10.5, anchor="start", fill=MUTED)
    s.save("pipeline_datapath.svg")



# ===========================================================================
# 2c. Pipelined processor in the style of Harris & Harris, Fig. 7.61
# ===========================================================================
def harris():
    """The pipeline drawn the way textbooks draw a pipelined processor
    (Harris & Harris, DDCA RISC-V, Figure 7.61): thin clocked pipeline
    registers, stage-suffixed signal names (F, D, E, M, W), the register file
    with its A1/A2/A3/WD3 ports, instruction bit fields on the wires, the
    control unit on top with its signals travelling through the registers,
    and the hazard unit along the bottom."""
    W, H = 1330, 1060
    s = Svg(W, H, "Pipelined processor with branch prediction and full hazard handling")
    K = INK
    B = "#1d72b8"          # control, as in the book

    def wire(pts, c=K, w=1.4):
        p_ = " ".join(f"{x},{y}" for x, y in pts)
        s.raw(f'<polyline points="{p_}" fill="none" stroke="{c}" stroke-width="{w}" '
              f'stroke-linejoin="miter"/>')

    def dot(x, y, c=K):
        s.raw(f'<circle cx="{x}" cy="{y}" r="2.6" fill="{c}"/>')

    def t(x, y, txt, c=K, size=10, anchor="start", weight="normal"):
        s.text(x, y, txt, size=size, anchor=anchor, fill=c, weight=weight)

    def block(x, y, w, h, title):
        s.rect(x, y, w, h, "#ffffff", K, rx=2, sw=1.4)
        s.text(x + w / 2, y + h / 2 + 4, title, size=10.5, weight="700")

    def mux(x, y, h, labels, w=20):
        s.rect(x, y, w, h, "#ffffff", K, rx=w / 2, sw=1.3)
        n = len(labels)
        for i, lb in enumerate(labels):
            s.text(x + w / 2, y + (i + 0.5) * h / n + 3, lb, size=8)

    def adder(x, y, w=40, h=64):
        s.raw(f'<polygon points="{x},{y} {x + w},{y + h * 0.3} {x + w},{y + h * 0.7} '
              f'{x},{y + h} {x},{y + h * 0.62} {x + w * 0.25},{y + h / 2} {x},{y + h * 0.38}" '
              f'fill="#ffffff" stroke="{K}" stroke-width="1.4"/>')
        s.text(x + w * 0.62, y + h / 2 + 5, "+", size=14, weight="700")

    REG_TOP, REG_BOT = 150, 820

    def preg(x, en=None, clr=None, name=None):
        s.rect(x, REG_TOP, 16, REG_BOT - REG_TOP, "#ffffff", K, rx=1, sw=1.5)
        s.raw(f'<polygon points="{x + 3},{REG_TOP} {x + 13},{REG_TOP} {x + 8},{REG_TOP + 9}" '
              f'fill="none" stroke="{K}" stroke-width="1.2"/>')
        t(x + 8, REG_TOP - 6, "CLK", size=9, anchor="middle")
        yy = REG_BOT - 34
        if en:
            t(x + 8, yy, "EN", size=8, anchor="middle")
            yy += 14
        if clr:
            t(x + 8, yy, "CLR", size=8, anchor="middle")
        if name:
            t(x + 8, REG_BOT + 14, name, size=9.5, anchor="middle", weight="700", c=MUTED)

    # ---- title and stage names ----
    s.text(30, 36, "Pipelined RV32I processor with branch prediction and full hazard handling",
           size=19, anchor="start", weight="700")
    s.text(30, 58, "Drawn in the convention of Harris & Harris, Digital Design and Computer "
           "Architecture: RISC-V Edition, Figure 7.61. Black = datapath, blue = control. "
           "Signal suffix = stage (F D E M W).", size=12, anchor="start", fill=MUTED)
    for nm, x0, x1 in [("Fetch", 20, 296), ("Decode", 296, 584), ("Execute", 584, 872),
                       ("Memory", 872, 1130), ("Writeback", 1130, 1300)]:
        s.text((x0 + x1) / 2, 88, nm, size=13, weight="700",
               fill=STAGE[{"Fetch": "IF", "Decode": "ID", "Execute": "EX", "Memory": "MEM",
                           "Writeback": "WB"}[nm]][1])

    # ---- pipeline registers ----
    preg(280, en=True, clr=True, name="IF/ID")
    preg(568, clr=True, name="ID/EX")
    preg(856, clr=True, name="EX/MEM")
    preg(1114, name="MEM/WB")

    # ================= FETCH =================
    mux(26, 368, 96, ["00", "01", "10"])                       # PC source
    s.rect(70, 380, 16, 72, "#ffffff", K, rx=1, sw=1.5)          # PC register
    s.raw(f'<polygon points="73,380 83,380 78,389" fill="none" stroke="{K}" stroke-width="1.2"/>')
    t(78, 374, "CLK", size=9, anchor="middle")
    t(78, 446, "EN", size=8, anchor="middle")
    wire([(46, 416), (70, 416)]); t(48, 410, "PCF'", size=9)
    block(116, 370, 112, 96, "")
    s.text(172, 430, "Instruction", size=10.5, weight="700")
    s.text(172, 444, "Memory", size=10.5, weight="700")
    t(122, 400, "A", size=10); t(222, 400, "RD", size=10, anchor="end")
    t(172, 456, "(L1 I-cache)", size=8.5, anchor="middle", c=MUTED)
    wire([(86, 396), (116, 396)]); t(90, 390, "PCF", size=9.5)
    wire([(228, 396), (280, 396)]); t(244, 390, "InstrF", size=9)
    # +4 adder
    dot(100, 396)
    wire([(100, 396), (100, 548), (150, 548)])
    adder(150, 532)
    t(132, 590, "4", size=11, weight="700")
    wire([(140, 586), (150, 586)])
    wire([(190, 564), (264, 564), (264, 600), (280, 600)]); t(196, 558, "PCPlus4F", size=9)
    dot(264, 564)
    wire([(264, 564), (264, 520), (12, 520), (12, 380), (26, 380)])
    # PCF to IF/ID
    wire([(100, 548), (100, 640)])
    dot(100, 548)
    wire([(100, 640), (280, 640)]); t(206, 634, "PCF", size=9)
    # branch predictor
    block(116, 680, 128, 80, "")
    s.text(180, 708, "Branch Predictor", size=10.5, weight="700")
    s.text(180, 724, "BTB (64) + BHT (256)", size=9, fill=MUTED)
    t(122, 744, "A", size=10)
    dot(100, 640)
    wire([(100, 640), (100, 744), (116, 744)])
    t(238, 744, "Target", size=9, anchor="end")
    wire([(244, 744), (262, 744), (262, 790), (8, 790), (8, 416), (26, 416)])
    t(150, 784, "PredTargetF", size=9)
    t(238, 700, "Taken", size=9, anchor="end", c=B)
    wire([(244, 696), (252, 696), (252, 352), (40, 352), (40, 368)], B)
    t(160, 346, "PredTakenF", size=9, c=B)
    # predicted next PC travels with the instruction
    wire([(270, 664), (280, 664)]); t(200, 676, "PredNextF", size=9)
    s.raw(f'<line x1="246" y1="664" x2="270" y2="664" stroke="{K}" stroke-width="1.4"/>')
    t(212, 660, "", size=1)

    # ================= DECODE =================
    wire([(296, 396), (320, 396)]); t(298, 390, "InstrD", size=9.5)
    wire([(320, 210), (320, 720)])                              # instruction trunk
    # control unit
    block(372, 170, 104, 132, "")
    s.text(424, 186, "Control", size=10.5, weight="700", fill=B)
    s.text(424, 200, "Unit", size=10.5, weight="700", fill=B)
    s.rect(372, 170, 104, 132, "none", B, rx=2, sw=1.4)
    for yy, f, nm in [(226, "6:0", "op"), (250, "14:12", "funct3"), (274, "30", "funct7\u2085")]:
        dot(320, yy)
        wire([(320, yy), (372, yy)])
        t(324, yy - 4, f, size=8)
        t(378, yy + 4, nm, size=9.5)
    ctrl = ["RegWriteD", "ResultSrcD", "MemWriteD", "JumpD", "BranchD", "ALUControlD",
            "ALUSrcD"]
    for i, nm in enumerate(ctrl):
        yy = 178 + i * 16
        wire([(476, yy), (568, yy)], B)
        t(482, yy - 3, nm, size=8.5, c=B)
    # ImmSrc to Extend
    t(482, 294, "ImmSrcD", size=8.5, c=B)
    wire([(476, 298), (540, 298), (540, 668)], B)
    # register file
    block(372, 330, 128, 132, "")
    s.text(450, 436, "Register", size=10.5, weight="700")
    s.text(450, 450, "File", size=10.5, weight="700")
    for yy, port, f in [(350, "A1", "19:15"), (380, "A2", "24:20")]:
        dot(320, yy)
        wire([(320, yy), (372, yy)])
        t(324, yy - 4, f, size=8)
        t(378, yy + 4, port, size=9.5)
    t(378, 414, "A3", size=9.5)
    t(378, 444, "WD3", size=9.5)
    t(436, 344, "WE3", size=9)
    t(494, 354, "RD1", size=9.5, anchor="end")
    t(494, 394, "RD2", size=9.5, anchor="end")
    wire([(500, 350), (568, 350)])
    wire([(500, 390), (568, 390)])
    # register sources for the hazard unit
    for yy, f, nm in [(560, "19:15", "Rs1D"), (580, "24:20", "Rs2D"), (600, "11:7", "RdD")]:
        dot(320, yy)
        wire([(320, yy), (568, yy)])
        t(324, yy - 4, f, size=8)
        t(500, yy - 4, nm, size=9)
    # extend
    s.raw(f'<polygon points="372,700 500,686 500,724 372,724" fill="#ffffff" stroke="{K}" '
          f'stroke-width="1.4"/>')
    s.text(440, 714, "Extend", size=10.5, weight="700")
    dot(320, 712)
    wire([(320, 712), (372, 712)])
    t(324, 708, "31:7", size=8)
    wire([(500, 706), (568, 706)]); t(506, 700, "ImmExtD", size=9)
    # PC, PC+4, predicted next
    wire([(296, 640), (568, 640)]); t(500, 634, "PCD", size=9)
    wire([(296, 600), (306, 600), (306, 760), (568, 760)]); t(500, 754, "PCPlus4D", size=9)
    wire([(296, 664), (310, 664), (310, 780), (568, 780)]); t(500, 774, "PredNextD", size=9)

    # ================= EXECUTE =================
    for i, nm in enumerate(ctrl):
        yy = 178 + i * 16
        en = nm[:-1] + "E"
        wire([(584, yy), (600, yy)], B)
        t(588, yy - 3, en, size=8.5, c=B)
    # control continuing to MEM
    for yy in (178, 194, 210):
        wire([(600, yy), (856, yy)], B)
    # forwarding muxes
    wire([(584, 350), (610, 350)]); t(585, 344, "RD1E", size=8)
    wire([(584, 390), (600, 390), (600, 432), (610, 432)]); t(585, 384, "RD2E", size=8)
    mux(610, 330, 70, ["00", "01", "10"])
    mux(610, 412, 70, ["00", "01", "10"])
    wire([(630, 365), (690, 365)]); t(640, 359, "SrcAE", size=9)
    wire([(630, 447), (650, 447)])
    dot(650, 447)
    wire([(650, 447), (668, 447)])
    t(632, 462, "WriteDataE", size=8.5)
    mux(668, 436, 46, ["0", "1"])
    wire([(584, 706), (656, 706), (656, 470), (668, 470)])
    t(588, 700, "ImmExtE", size=9)
    wire([(688, 459), (700, 459), (700, 420), (712, 420)]); t(690, 476, "SrcBE", size=9)
    # ALU
    s.raw(f'<polygon points="712,330 768,354 768,438 712,462 712,410 726,396 712,382" '
          f'fill="#ffffff" stroke="{K}" stroke-width="1.6"/>')
    s.text(748, 400, "ALU", size=12, weight="700")
    wire([(690, 365), (700, 365), (700, 350), (712, 350)])
    wire([(768, 396), (856, 396)]); t(782, 390, "ALUResultE", size=9)
    # ALU control & ALUSrc
    wire([(600, 274), (740, 274), (740, 340)], B)
    wire([(600, 290), (678, 290), (678, 436)], B)
    # write data on to MEM
    wire([(650, 447), (650, 490), (856, 490)]); t(782, 484, "WriteDataE", size=9)
    # branch target adder
    wire([(584, 640), (632, 640), (632, 580), (752, 580)]); t(588, 634, "PCE", size=9)
    dot(632, 640)
    wire([(656, 706), (656, 620), (752, 620)])
    dot(656, 706)
    adder(752, 566, w=40, h=68)
    wire([(792, 600), (806, 600)]); t(758, 562, "PCTargetE", size=8.5)
    # next PC select and misprediction check
    wire([(584, 760), (700, 760), (700, 650), (806, 650)]); t(588, 754, "PCPlus4E", size=9)
    mux(806, 586, 80, ["1", "0"])
    t(808, 580, "TakenE", size=8.5, c=B)
    wire([(826, 626), (838, 626)])
    dot(838, 626)
    wire([(838, 626), (856, 626)]); t(830, 620, "", size=1)
    # branch decision (blue control logic)
    s.rect(700, 500, 96, 40, "#ffffff", B, rx=4, sw=1.3)
    s.text(748, 516, "Branch", size=9.5, weight="700", fill=B)
    s.text(748, 530, "resolve", size=9.5, weight="700", fill=B)
    wire([(768, 430), (780, 430), (780, 500)], B)                  # flags from ALU
    wire([(600, 226), (612, 226), (612, 520), (700, 520)], B)      # JumpE
    wire([(600, 242), (620, 242), (620, 510), (700, 510)], B)      # BranchE
    wire([(796, 520), (816, 520), (816, 586)], B)                  # TakenE
    # mismatch: PCNextE != PredNextE
    s.raw(f'<circle cx="838" cy="700" r="13" fill="#ffffff" stroke="{B}" stroke-width="1.4"/>')
    s.text(838, 705, "\u2260", size=14, weight="700", fill=B)
    wire([(838, 626), (838, 687)])
    wire([(584, 780), (838, 780), (838, 713)])
    t(588, 774, "PredNextE", size=9)
    wire([(851, 700), (856, 700)], B)
    t(760, 716, "MispredictE", size=8.5, c=B)
    # register numbers on to MEM / hazard
    wire([(584, 560), (596, 560)]); t(588, 554, "", size=1)
    wire([(584, 600), (856, 600)]); t(588, 594, "RdE", size=9)

    # ================= MEMORY =================
    for yy, nm in [(178, "RegWriteM"), (194, "ResultSrcM"), (210, "MemWriteM")]:
        t(876, yy - 3, nm, size=8.5, c=B)
    wire([(872, 178), (1114, 178)], B)
    wire([(872, 194), (1114, 194)], B)
    wire([(872, 210), (960, 210), (960, 340)], B)
    block(920, 340, 120, 110, "")
    s.text(980, 420, "Data Memory", size=10.5, weight="700")
    s.text(980, 434, "(L1 D-cache)", size=8.5, fill=MUTED)
    t(926, 390, "A", size=10); t(926, 430, "WD", size=10); t(1034, 390, "RD", size=10,
                                                              anchor="end")
    t(966, 356, "WE", size=9)
    wire([(872, 396), (920, 396)]); t(874, 390, "ALUResultM", size=9)
    dot(896, 396)
    wire([(896, 396), (896, 360), (1114, 360)])
    wire([(872, 490), (906, 490), (906, 430), (920, 430)]); t(874, 506, "WriteDataM", size=9)
    wire([(1040, 396), (1114, 396)]); t(1050, 390, "ReadDataM", size=9)
    # CSR / trap unit
    block(920, 520, 120, 60, "")
    s.text(980, 545, "CSRs + trap", size=10.5, weight="700")
    s.text(980, 560, "precise exceptions", size=8.5, fill=MUTED)
    wire([(896, 396), (896, 550), (920, 550)])
    wire([(1040, 550), (1114, 550)]); t(1046, 544, "CSRDataM", size=9)
    # rd, PC+4, next PC, misprediction
    wire([(872, 600), (1114, 600)]); t(874, 594, "RdM", size=9)
    wire([(872, 760), (1114, 760)]); t(874, 754, "PCPlus4M", size=9)
    s.raw(f'<line x1="584" y1="760" x2="856" y2="760" stroke="{K}" stroke-width="1.4"/>')
    wire([(872, 626), (888, 626), (888, 120), (4, 120), (4, 452), (26, 452)])
    t(898, 640, "PCNextM", size=9)
    s.label(470, 120, "PCNextM — the correct next PC", size=9.5, color=K, mono=False)
    wire([(872, 700), (880, 700), (880, 108), (54, 108), (54, 368)], B)
    s.label(470, 108, "RedirectM — misprediction, trap, mret or FENCE.I", size=9.5, color=B,
            mono=False)
    t(884, 716, "MispredictM", size=8.5, c=B)
    # predictor update

    # ================= WRITEBACK =================
    t(1134, 175, "RegWriteW", size=8.5, c=B)
    t(1134, 191, "ResultSrcW", size=8.5, c=B)
    wire([(1130, 194), (1196, 194), (1196, 350)], B)
    mux(1186, 350, 104, ["00", "01", "10", "11"])
    wire([(1130, 360), (1160, 360), (1160, 363), (1186, 363)]); t(1132, 354, "ALUResultW", size=8.5)
    wire([(1130, 396), (1186, 389)]); t(1132, 390, "ReadDataW", size=8.5)
    wire([(1130, 760), (1170, 760), (1170, 415), (1186, 415)]); t(1132, 754, "PCPlus4W", size=8.5)
    wire([(1130, 550), (1160, 550), (1160, 441), (1186, 441)]); t(1132, 544, "CSRDataW", size=8.5)
    wire([(1206, 402), (1236, 402)])
    t(1212, 396, "ResultW", size=9.5, weight="700")
    dot(1236, 402)
    wire([(1236, 402), (1236, 846), (340, 846), (340, 444), (372, 444)])
    wire([(1130, 600), (1150, 600), (1150, 862), (356, 862), (356, 414), (372, 414)])
    t(1152, 616, "RdW", size=9)
    wire([(1130, 178), (1250, 178), (1250, 140), (436, 140), (436, 330)], B)
    s.label(760, 140, "RegWriteW → WE3", size=9.5, color=B, mono=False)
    # forwarding into the EX muxes
    dot(896, 396)
    wire([(896, 396), (896, 830), (604, 830), (604, 400), (610, 400)])
    dot(604, 400)
    wire([(604, 400), (604, 470), (610, 470)])
    t(700, 826, "ALUResultM  (forward, 10)", size=9)
    dot(1236, 846)
    dot(598, 846)
    wire([(598, 846), (598, 381), (610, 381)])
    wire([(598, 451), (610, 451)])
    t(700, 842, "ResultW  (forward, 01)", size=9)

    # ================= HAZARD UNIT =================
    s.rect(60, 920, 1240, 44, "#ffffff", B, rx=6, sw=1.6)
    s.text(680, 948, "Hazard Unit", size=12, weight="700", fill=B)
    for x, ty, nm, side in [(78, 452, "StallF", 1), (284, 820, "StallD", -1),
                            (292, 820, "FlushD", 1), (576, 820, "FlushE", 1),
                            (864, 820, "FlushM", 1)]:
        wire([(x, 920), (x, ty)], B)
        s.text(x + 4 * side, 884 if nm == "FlushE" else 900, nm, size=8.5, fill=B,
               anchor="start" if side > 0 else "end")
    for x, ty, nm in [(620, 400, "ForwardAE"), (628, 482, "ForwardBE")]:
        wire([(x, 920), (x, ty)], B)
    s.text(612, 900, "ForwardAE", size=8.5, fill=B, anchor="end")
    s.text(632, 900, "ForwardBE", size=8.5, fill=B, anchor="start")
    ins = [(330, "Rs1D", 560), (338, "Rs2D", 580), (720, "RdE", 600), (980, "RdM", 600),
           (1150, "RdW", 862)]
    for x, nm, yy in ins:
        dot(x, yy) if x not in (1150,) else None
    for x in (400, 412, 724, 990):
        pass
    wire([(330, 560), (330, 920)])
    wire([(344, 580), (344, 920)])
    dot(344, 580)
    wire([(724, 600), (724, 920)])
    dot(724, 600)
    wire([(984, 600), (984, 920)])
    dot(984, 600)
    wire([(1150, 862), (1150, 920)])
    wire([(886, 700), (886, 920)], B)
    s.text(334, 912, "Rs1D Rs2D", size=8, fill=MUTED, anchor="start")
    s.text(728, 912, "RdE", size=8, fill=MUTED, anchor="start")
    s.text(988, 912, "RdM", size=8, fill=MUTED, anchor="start")
    s.text(1154, 912, "RdW", size=8, fill=MUTED, anchor="start")

    # ---- notes ----
    s.text(30, 994, "Additions to the textbook processor: a branch predictor in Fetch (BTB + "
           "2-bit bimodal counters) picks PCF'; every instruction carries PredNext; Execute "
           "compares the real next PC with it;", size=11, anchor="start", fill=MUTED)
    s.text(30, 1012, "a misprediction, trap, mret or FENCE.I redirects from Memory, flushing "
           "D, E and M. CSRs are read in Memory, so ResultW has a fourth source. Load-use and "
           "CSR-use stalls come from the Hazard Unit.", size=11, anchor="start", fill=MUTED)
    s.text(30, 1030, "Simplified for clarity: the 4-entry fetch buffer is drawn as the IF/ID "
           "register, and the data cache's early address, the WB→ID bypass, the address adder "
           "and predictor training are not shown (see pipeline.svg).", size=11,
           anchor="start", fill=MUTED)
    s.save("pipeline_datapath.svg")


# ===========================================================================
# 3. Fetch unit
# ===========================================================================
def fetch_unit():
    s = Svg(1180, 520, "Decoupled fetch unit")
    s.text(30, 40, "fetch_unit — decoupled instruction fetch", size=20, anchor="start",
           weight="700")
    s.text(30, 62, "Requests run ahead of decode; responses are paired with the oldest in-flight "
           "PC and parked until decode takes them.", size=12.5, anchor="start", fill=MUTED)

    blue = STAGE["IF"]
    s.box(40, 110, 200, 66, blue, "fetch_pc", "advances by 4 on each issue\nloads redirect_pc",
          subsize=10.5)
    s.box(40, 214, 200, 100, HAZ, "issue logic",
          "can_issue = in-flight + buffered\n< DEPTH and no redirect\nissue = can_issue && gnt",
          subsize=10.5)
    s.arrow([(140, 176), (140, 212)], INK)

    # PC queue
    s.rect(300, 110, 300, 128, blue[0], blue[1], rx=10)
    s.text(450, 132, "in-flight PC queue", size=14, weight="600")
    for i in range(4):
        s.rect(318 + i * 68, 150, 58, 40, "#ffffff", blue[1], rx=5)
        s.text(347 + i * 68, 175, f"pc[{i}]", size=11, mono=True)
    s.text(450, 222, "index 0 = oldest request · pushed on issue", size=10.5, fill=MUTED)
    s.arrow([(240, 143), (298, 143)], INK)
    s.label(268, 132, "push", size=10)

    # discard
    s.box(300, 270, 300, 76, HAZ, "discard_q",
          "responses still owed to a path the core left;\nthrown away as they arrive",
          subsize=10.5)

    # instruction buffer
    s.rect(660, 250, 300, 196, blue[0], blue[1], rx=10)
    s.text(810, 272, "instruction buffer", size=14, weight="600")
    for i in range(4):
        s.rect(680, 286 + i * 36, 260, 30, "#ffffff", blue[1], rx=5)
        s.text(810, 306 + i * 36, f"{{ pc, insn }}[{i}]" + ("  ← head" if i == 0 else ""),
               size=11, mono=True)

    # memory
    s.box(980, 96, 176, 118, CACHE, "I-cache / memory",
          "accepts on gnt\nanswers in order\none response per\naccepted request", subsize=10.5)
    s.arrow([(200, 110), (200, 92), (960, 92), (960, 130), (978, 130)], "#0284c7")
    s.label(620, 92, "instr_req · instr_addr = fetch_pc", size=10.5)
    s.arrow([(1068, 96), (1068, 76), (22, 76), (22, 262), (38, 262)], "#0284c7")
    s.label(620, 76, "instr_gnt", size=10.5)
    s.arrow([(1068, 214), (1068, 236), (810, 236), (810, 248)], "#0284c7")
    s.label(940, 236, "instr_ready · instr_rdata", size=10.5)
    s.arrow([(450, 238), (450, 252), (640, 252), (640, 300), (678, 300)], INK)
    s.label(560, 252, "pair with pc[0]", size=10)

    # decode
    s.box(980, 330, 176, 104, STAGE["ID"], "decode (ID)",
          "insn_valid · pc · insn\ninsn_ready = pop", subsize=10.5)
    s.arrow([(940, 301), (962, 301), (962, 372), (978, 372)], INK)

    # redirect
    s.arrow([(40, 482), (140, 482), (140, 316)], CTRL, width=2)
    s.text(40, 472, "redirect_i · redirect_pc_i", size=11.5, anchor="start", fill=CTRL,
           mono=True)
    s.text(300, 480, "on redirect: fetch_pc ← target, buffer and queue cleared,\n"
           "discard_q ← discard_q + requests still in flight", size=11.5, anchor="start",
           fill=MUTED)
    s.save("fetch_unit.svg")


# ===========================================================================
# 4. Cache organisation
# ===========================================================================
def cache():
    s = Svg(1260, 640, "Two-way set-associative L1 cache lookup")
    s.text(30, 40, "L1 cache organisation — 4 KiB, 2-way, 128 sets, 16-byte lines",
           size=20, anchor="start", weight="700")
    s.text(30, 62, "Both caches share this geometry. A lookup reads both ways of one set; the "
           "data cache reads them a cycle early, at the address the core announces.",
           size=12.5, anchor="start", fill=MUTED)

    # address split
    segs = [("tag", "31 … 11  (21 bits)", 470, "#fde68a"), ("index", "10 … 4  (7)", 210,
                                                            "#c7d2fe"),
            ("word", "3 … 2", 110, "#bbf7d0"), ("byte", "1 … 0", 90, "#e5e7eb")]
    x = 150
    pos = {}
    for nm, bits, w, c in segs:
        s.rect(x, 84, w, 52, c, INK, rx=4)
        s.text(x + w / 2, 106, nm, size=14, weight="700")
        s.text(x + w / 2, 126, bits, size=11, fill=MUTED, mono=True)
        pos[nm] = x + w / 2
        x += w
    s.text(140, 116, "address", size=13, anchor="end", weight="600")

    def way(x0, n):
        s.text(x0 + 205, 178, f"way {n}", size=14, weight="700")
        # valid/dirty column
        s.rect(x0, 190, 56, 220, "#f1f5f9", MUTED, rx=6)
        s.text(x0 + 28, 206, "V  D", size=11, weight="600", mono=True)
        s.rect(x0 + 72, 190, 120, 220, "#fef9c3", "#ca8a04", rx=6)
        s.text(x0 + 132, 206, "tag RAM", size=11.5, weight="600")
        s.rect(x0 + 208, 190, 200, 220, CACHE[0], CACHE[1], rx=6)
        s.text(x0 + 308, 206, "data RAM", size=11.5, weight="600")
        for r in range(8):
            y = 216 + r * 23
            sel = r == 4
            fill = "#fde68a" if sel else "#ffffff"
            s.rect(x0 + 8, y, 40, 18, fill, LINE, rx=2, sw=1)
            s.rect(x0 + 80, y, 104, 18, fill, LINE, rx=2, sw=1)
            for k in range(4):
                s.rect(x0 + 216 + k * 46, y, 42, 18, fill, LINE, rx=2, sw=1)
        s.text(x0 + 132, 428, "128 × 21", size=10.5, fill=MUTED, mono=True)
        s.text(x0 + 308, 428, "128 × 128 (4 words)", size=10.5, fill=MUTED, mono=True)
        s.text(x0 + 28, 428, "flip-flops", size=10.5, fill=MUTED, mono=True)
        # comparator
        cx, cy = x0 + 132, 480
        s.raw(f'<circle cx="{cx}" cy="{cy}" r="17" fill="#ffffff" stroke="{INK}" '
              f'stroke-width="1.6"/>')
        s.text(cx, cy + 6, "=", size=18, weight="700")
        s.arrow([(x0 + 132, 410), (x0 + 132, 461)], INK)
        s.box(x0 + 60, 524, 144, 40, ("#ffffff", INK), f"hit{n} = V · match", size=12)
        s.arrow([(cx, 497), (cx, 522)], INK)
        s.arrow([(x0 + 28, 410), (x0 + 28, 544), (x0 + 58, 544)], MUTED)
        return x0 + 308

    d0 = way(60, 0)
    d1 = way(540, 1)
    # index line
    s.arrow([(pos["index"], 136), (pos["index"], 160), (30, 160), (30, 309), (66, 309)], "#4f46e5",
            dash="5 4")
    s.arrow([(pos["index"] - 20, 160), (520, 160), (520, 309), (546, 309)], "#4f46e5",
            dash="5 4", head=True)
    s.label(250, 160, "index selects one row in every array", size=10.5, color="#4f46e5")
    # tag bus
    s.arrow([(pos["tag"], 136), (pos["tag"], 150), (974, 150), (974, 456)], "#ca8a04",
            head=False, dash="2 3")
    s.arrow([(974, 456), (192, 456), (192, 462)], "#ca8a04")
    s.arrow([(672, 456), (672, 462)], "#ca8a04")
    s.label(974, 360, "address tag", size=10.5, color="#ca8a04")

    # way mux + word select
    s.mux(1100, 470, 34, 90, NEUTRAL, "WAY", size=10)
    s.arrow([(d0, 410), (d0, 444), (1080, 444), (1080, 492), (1098, 492)], INK)
    s.arrow([(d1, 410), (d1, 436), (1088, 436), (1088, 536), (1098, 536)], INK)
    s.arrow([(264, 544), (280, 544), (280, 600), (1117, 600), (1117, 562)], MUTED)
    s.arrow([(744, 544), (760, 544), (760, 600)], MUTED, head=False)
    s.label(560, 600, "hit0 / hit1 select the way;  hit = hit0 or hit1", size=10.5)
    s.mux(1160, 480, 30, 70, NEUTRAL, "WORD", size=9)
    s.arrow([(1134, 515), (1158, 515)], INK)
    s.arrow([(pos["word"], 136), (pos["word"], 146), (1175, 146), (1175, 478)], "#16a34a",
            dash="5 4")
    s.arrow([(1190, 515), (1240, 515)], INK)
    s.text(1222, 504, "rdata", size=11, mono=True, fill=INK)
    s.text(1050, 168, "", size=1)

    # LRU
    s.box(1000, 196, 190, 110, CSR, "LRU bit per set",
          "victim = an empty way,\nelse the least recently\nused; updated on every\nhit and refill",
          subsize=10.5)
    s.save("cache.svg")


# ===========================================================================
# 5. Hazard timing
# ===========================================================================
def hazards():
    s = Svg(1300, 830, "Pipeline hazard timing")
    s.text(30, 40, "How the pipeline handles hazards", size=20, anchor="start", weight="700")
    s.text(30, 62, "Each row is one instruction, each column one clock cycle. Simplified: the "
           "fetch unit's buffering is not shown.", size=12.5, anchor="start", fill=MUTED)
    cw, rh, x0 = 74, 34, 330

    def panel(y, title, note, rows):
        s.text(30, y, title, size=15, anchor="start", weight="700")
        s.text(30, y + 20, note, size=11.5, anchor="start", fill=MUTED)
        for c in range(9):
            s.text(x0 + c * cw + cw / 2, y + 48, f"C{c + 1}", size=11, fill=MUTED, mono=True)
        cells = {}
        for r, (name, stages) in enumerate(rows):
            yy = y + 58 + r * rh
            s.text(x0 - 12, yy + rh / 2 + 4, name, size=12, anchor="end", mono=True)
            for c, st in stages:
                if st in STAGE:
                    f, k = STAGE[st]
                    s.rect(x0 + c * cw + 3, yy + 3, cw - 6, rh - 6, f, k, rx=5, sw=1.3)
                    s.text(x0 + c * cw + cw / 2, yy + rh / 2 + 4, st, size=12, weight="600",
                           fill=k)
                elif st == "bubble":
                    s.rect(x0 + c * cw + 3, yy + 3, cw - 6, rh - 6, "#f1f5f9", LINE, rx=5,
                           sw=1.2, dash="4 3")
                    s.text(x0 + c * cw + cw / 2, yy + rh / 2 + 4, "bubble", size=10.5,
                           fill=MUTED, italic=True)
                elif st.startswith("x"):
                    s.rect(x0 + c * cw + 3, yy + 3, cw - 6, rh - 6, "#ffffff", CTRL, rx=5,
                           sw=1.2, dash="3 3")
                    s.text(x0 + c * cw + cw / 2, yy + rh / 2 + 4, st[1:], size=11, fill=CTRL,
                           italic=True)
                cells[(r, c)] = (x0 + c * cw + cw / 2, yy + rh / 2)
        return cells

    c = panel(100, "1 · Data dependence on an ALU result — forwarded, no stall",
              "The result exists at the end of EX, so the next instruction takes it straight "
              "from the EX/MEM register.",
              [("add  x1, x2, x3", [(0, "IF"), (1, "ID"), (2, "EX"), (3, "MEM"), (4, "WB")]),
               ("sub  x4, x1, x5", [(1, "IF"), (2, "ID"), (3, "EX"), (4, "MEM"), (5, "WB")])])
    a, b = c[(0, 2)], c[(1, 3)]
    s.arrow([(a[0] + 22, a[1] + 15), (b[0] - 22, b[1] - 15)], FWD, width=2.6)
    s.label(830, 209, "← result forwarded EX/MEM → EX", size=11, color=FWD, anchor="start")

    c = panel(300, "2 · Load followed by its consumer — one bubble",
              "A loaded value exists only at the end of MEM. The consumer waits one cycle in ID, "
              "then takes the value from MEM/WB.",
              [("lw   x1, 0(x2)", [(0, "IF"), (1, "ID"), (2, "EX"), (3, "MEM"), (4, "WB")]),
               ("add  x3, x1, x4", [(1, "IF"), (2, "ID"), (3, "ID"), (4, "EX"), (5, "MEM"),
                                    (6, "WB")]),
               ("(EX slot)", [(3, "bubble")])])
    a, b = c[(0, 3)], c[(1, 4)]
    s.arrow([(a[0] + 22, a[1] + 15), (b[0] - 22, b[1] - 15)], FWD, width=2.6)
    s.label(904, 409, "← loaded value forwarded MEM/WB → EX", size=11, color=FWD,
            anchor="start")
    s.text(904, 430, "CSR reads behave the same way", size=10.5, fill=MUTED, anchor="start")

    c = panel(530, "3 · Mispredicted branch — checked in EX, redirected from MEM",
              "A correctly predicted branch costs nothing. A misprediction is found in EX, the "
              "redirect fires from MEM, and the three instructions behind it are squashed.",
              [("beq  x1, x2, L", [(0, "IF"), (1, "ID"), (2, "EX"), (3, "MEM"), (4, "WB")]),
               ("wrong path 1", [(1, "IF"), (2, "ID"), (3, "xflushed")]),
               ("wrong path 2", [(2, "IF"), (3, "xflushed")]),
               ("wrong path 3", [(3, "xflushed")]),
               ("L: real next PC", [(4, "IF"), (5, "ID"), (6, "EX"), (7, "MEM"), (8, "WB")])])
    a = c[(0, 3)]
    gx = x0 + 4 * cw
    s.arrow([(a[0] + 36, a[1]), (gx, a[1]), (gx, c[(4, 4)][1])], CTRL, width=2.2)
    s.label(gx - 4, 800, "redirect from MEM to the real next PC", size=11, color=CTRL,
            anchor="end")
    s.save("hazards.svg")


# ===========================================================================
# 6. Verification ecosystem
# ===========================================================================
def verification():
    s = Svg(1380, 820, "Verification and build ecosystem")
    s.text(30, 40, "Verification ecosystem — how every claim in this repository is checked",
           size=20, anchor="start", weight="700")
    s.text(30, 62, "One make target per check, all inside a pinned container; Vivado runs "
           "natively on Windows for synthesis.", size=12.5, anchor="start", fill=MUTED)

    # host
    s.rect(24, 84, 1332, 712, "#f8fafc", LINE, rx=14)
    s.text(44, 110, "Windows 11 host  →  WSL2 Ubuntu 24.04  →  make (relative paths, repo "
           "root)", size=13, anchor="start", weight="600", fill=MUTED)

    # container
    s.rect(44, 126, 980, 650, "#ffffff", "#2563eb", rx=12, sw=2)
    s.text(64, 152, "Docker image rv32-toolchain:1  (base image pinned by digest)", size=14,
           anchor="start", weight="700", fill="#2563eb")
    tools = [("riscv64-unknown-elf-gcc", "13.2.0 (asserted)"), ("Verilator", "5.026, from source"),
             ("Spike", "1.1.0, --enable-commitlog"), ("oss-cad-suite", "2024-09-01"),
             ("Python 3", "+ pytest")]
    for i, (t, v) in enumerate(tools):
        s.box(64 + i * 190, 166, 176, 50, ("#eff6ff", "#2563eb"), t, v, size=12, subsize=10.5)

    # program flow
    s.box(64, 252, 190, 70, NEUTRAL, "programs", "hello.c · cachestress.c\nsmoke.S · crt0.S",
          subsize=10.5)
    s.box(64, 352, 190, 70, NEUTRAL, "riscv-tests", "rv32ui + rv32mi\np-mode ELFs (58)",
          subsize=10.5)
    s.box(300, 252, 170, 70, ("#eff6ff", "#2563eb"), "gcc + link.ld", "-march=rv32i\nbase 0x8000_0000",
          subsize=10.5)
    s.arrow([(254, 287), (298, 287)], INK)
    s.box(520, 252, 150, 70, NEUTRAL, "ELF", "+ objcopy\n→ word hex", subsize=10.5)
    s.arrow([(470, 287), (518, 287)], INK)
    s.arrow([(254, 387), (595, 387), (595, 324)], INK)

    s.box(720, 236, 280, 92, STAGE["MEM"], "Verilator simulation",
          "testbench + RTL (tb_core_rv32i / tb_core_p5 /\ntb_soc / *_lat with LATENCY)\n"
          "→ RVFI trace: order pc insn rd value", subsize=10.5)
    s.box(720, 352, 280, 70, CSR, "Spike reference ISS",
          "--isa=rv32i_zicsr --priv=m\n-l --log-commits", subsize=10.5)
    s.arrow([(670, 280), (718, 280)], INK)
    s.arrow([(670, 304), (690, 304), (690, 387), (718, 387)], INK)

    s.box(720, 452, 280, 96, HAZ, "compare_trace.py",
          "instruction-by-instruction diff\nfrom _start to a stop label\n"
          "exit 0 match · 1 diverge · 2 unparsable", subsize=10.5)
    s.arrow([(1000, 282), (1012, 282), (1012, 500), (1002, 500)], INK)
    s.arrow([(860, 422), (860, 450)], INK)
    s.box(720, 580, 280, 80, ("#fff7ed", FWD), "run_regress.py",
          "gate 1: tohost == 1 (suite's own check)\ngate 2: trace matches Spike", subsize=10.5)
    s.arrow([(860, 548), (860, 578)], INK)
    s.text(860, 690, "result: 54 / 58 pass, the 4 failures are\ndocumented known gaps",
           size=11.5, fill=MUTED)

    # unit tests & lint
    s.box(64, 470, 410, 110, ("#eff6ff", "#2563eb"), "16 self-checking unit testbenches",
          "ALU · regfile · decoder · CSR file · fetch unit · branch predictor · RAM\n"
          "main memory · arbiter · I-cache · D-cache (directed + thousands of\n"
          "random accesses against a reference model) · smoke programs", subsize=10.5)
    s.box(64, 610, 410, 74, HAZ, "make lint  —  the gate in front of everything",
          "verilator --lint-only -Wall on every top; any warning fails.\n"
          "Compile errors stop the run; builds start from a clean directory.", subsize=10.5)
    s.box(64, 700, 410, 60, ("#eff6ff", "#2563eb"), "make test-scripts",
          "16 pytest cases for the trace comparator itself", subsize=10.5)
    s.box(500, 470, 190, 290, NEUTRAL, "assertions", "fetch-unit occupancy\n\n"
          "D$ pre_addr contract\n(lookup must match\nthe set read last edge)\n\n"
          "fire as hard errors\nin every simulation", subsize=10.5)

    # vivado
    s.rect(1044, 126, 296, 650, "#ffffff", "#c2410c", rx=12, sw=2)
    s.text(1192, 152, "Vivado 2022.2 (native Windows)", size=14, weight="700", fill="#c2410c")
    s.box(1064, 172, 256, 70, ("#fff7ed", "#c2410c"), "synth.tcl", "XCK26 · synth_design\n"
          "+ opt_design", subsize=10.5)
    s.box(1064, 270, 256, 70, HAZ, "loop gate", "fails if timing report shows\nany combinational loop",
          subsize=10.5)
    s.box(1064, 368, 256, 70, HAZ, "block-RAM gate", "rv32_soc must infer\nblock RAM for its caches",
          subsize=10.5)
    s.box(1064, 466, 256, 70, ("#fff7ed", "#c2410c"), "summary.json",
          "Fmax = 1 / (target − WNS)\nLUT · FF · BRAM · DSP · loops", subsize=10.5)
    s.box(1064, 564, 256, 70, NEUTRAL, "collect_results.py", "→ results/comparison.md",
          subsize=10.5)
    for y in (242, 340, 438, 536):
        s.arrow([(1192, y), (1192, y + 26)], INK)
    s.text(1192, 680, "make synth CORE=<top> TARGET=<ns>", size=11, mono=True, fill=MUTED)
    s.save("verification.svg")


# ===========================================================================
# 7. Charts
# ===========================================================================
def charts():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({"font.family": "sans-serif", "font.size": 11, "svg.fonttype": "none",
                         "axes.spines.top": False, "axes.spines.right": False})

    # cycles vs wait states, hello.c (results/experiments.md sections 2 and 6)
    fig, ax = plt.subplots(figsize=(8.6, 4.6), dpi=100)
    sc = ([0, 1, 2, 4, 10], [297, 595, 893, 1489, 3277])
    p5 = ([0, 1, 4, 10], [381, 404, 637, 1201])
    soc = ([1, 4, 10, 20], [471, 575, 785, 1135])
    ax.plot(*sc, "o-", color="#64748b", lw=2.2, label="single-cycle core")
    ax.plot(*p5, "s-", color="#d97706", lw=2.2, label="pipeline + branch prediction, no cache")
    ax.plot(*soc, "D-", color="#0d9488", lw=2.6, label="pipeline + prediction + L1 caches (rv32_soc)")
    for x, y in zip(*soc):
        ax.annotate(f"{y}", (x, y), textcoords="offset points", xytext=(0, -16), ha="center",
                    color="#0d9488", fontsize=10)
    ax.set_xticks([0, 1, 2, 4, 10, 20])
    ax.set_xlabel("main-memory latency (wait states per access)")
    ax.set_ylabel("cycles to run hello.c")
    ax.set_title("Cycles vs memory latency (hello.c, ~297 instructions)", loc="left",
                 fontweight="bold")
    ax.grid(axis="y", color="#e2e8f0")
    ax.legend(frameon=False, loc="upper left")
    fig.tight_layout()
    fig.savefig(OUT / "chart_latency.svg", facecolor="white")
    plt.close(fig)
    print("wrote docs/img/chart_latency.svg")

    # FPGA resources (results/raw/*_synth.json)
    names = ["single-cycle", "pipeline + prediction", "+ L1 caches"]
    lut = [2123, 4110, 6788]
    ff = [1438, 3401, 4604]
    fmax = [216.7, 264.4, 213.5]
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(9.6, 4.0), dpi=100,
                                 gridspec_kw={"width_ratios": [1.5, 1]})
    xs = range(3)
    a1.bar([x - 0.19 for x in xs], lut, 0.38, color="#7c3aed", label="LUTs")
    a1.bar([x + 0.19 for x in xs], ff, 0.38, color="#c4b5fd", label="flip-flops")
    for x, v in zip(xs, lut):
        a1.text(x - 0.19, v + 80, f"{v}", ha="center", fontsize=9.5)
    for x, v in zip(xs, ff):
        a1.text(x + 0.19, v + 80, f"{v}", ha="center", fontsize=9.5)
    a1.set_xticks(list(xs), names)
    a1.set_title("Area on XCK26 (+ 10 block RAMs for caches)", loc="left", fontweight="bold",
                 fontsize=11.5)
    a1.legend(frameon=False)
    a1.grid(axis="y", color="#e2e8f0")
    a2.bar(list(xs), fmax, 0.55, color=["#64748b", "#d97706", "#0d9488"])
    for x, v in zip(xs, fmax):
        a2.text(x, v + 4, f"{v}", ha="center", fontsize=10)
    a2.set_xticks(list(xs), ["single", "pipeline", "+caches"])
    a2.set_ylim(0, 300)
    a2.set_title("Fmax (MHz, post-synthesis)", loc="left", fontweight="bold", fontsize=11.5)
    a2.grid(axis="y", color="#e2e8f0")
    fig.tight_layout()
    fig.savefig(OUT / "chart_fpga.svg", facecolor="white")
    plt.close(fig)
    print("wrote docs/img/chart_fpga.svg")


if __name__ == "__main__":
    system()
    pipeline()
    harris()
    fetch_unit()
    cache()
    hazards()
    verification()
    charts()
