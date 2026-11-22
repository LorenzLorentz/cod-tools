#!/usr/bin/env python3
"""把 VCD 波形渲染成 PNG（效果类似 Vivado 波形窗口的静态截图）。

xsim（scripts/vivado/sim.tcl）和 Verilator（+VCD）写出的 VCD 都能读。

用法:
  render_wave.py wave.vcd --list                              # 列出 VCD 里的信号
  render_wave.py wave.vcd -o wave.png                         # 画所有信号（最多 --max-signals 个）
  render_wave.py wave.vcd -o wave.png --signals sim/wave_signals.txt
  render_wave.py wave.vcd -o wave.png -s dut.video_hsync -s 'dut.video_*' --start 0 --end 25us
  render_wave.py wave.vcd -o wave.png --signals sim/wave_signals.txt --cursor 17.1us

信号匹配规则：按层次名“后缀”匹配（dut.leds 能匹配 tb_vga_frame.dut.leds 和
TOP.tb_vga_frame.dut.leds），支持 * ? 通配。信号清单文件格式见 sim/wave_signals.txt。
时间参数不写单位时按 ns 处理。依赖 matplotlib。
"""

from __future__ import annotations

import argparse
import fnmatch
import math
import re
import sys
from dataclasses import dataclass, field

UNITS = {"s": 1.0, "ms": 1e-3, "us": 1e-6, "ns": 1e-9, "ps": 1e-12, "fs": 1e-15}

THEMES = {
    # 接近 Vivado 波形窗口的配色
    "dark": dict(bg="#000000", fg="#d0d0d0", grid="#262626", wave="#00e060", bus="#00e060",
                 x="#ff3030", z="#f0c000", divider="#7fb2ff", cursor="#ffd000", off="#303030"),
    "light": dict(bg="#ffffff", fg="#202020", grid="#e4e4e4", wave="#0a7d32", bus="#0a5fa8",
                  x="#d01010", z="#b08800", divider="#3050a0", cursor="#d08000", off="#e0e0e0"),
}


@dataclass
class Var:
    name: str      # 完整层次名，例如 tb_vga_frame.dut.leds
    code: str      # VCD 标识符
    width: int
    rng: str = ""  # 例如 [15:0]
    changes: list = field(default_factory=list)  # [(tick, value_str)]


@dataclass
class Row:
    kind: str                 # "signal" | "divider"
    label: str
    var: Var | None = None
    radix: str = "hex"


# ---------------------------------------------------------------- VCD 解析

def parse_time(text):
    """'25us' / '1.5 ms' / '1000'（默认 ns）-> 秒。"""
    m = re.fullmatch(r"\s*([0-9.eE+-]+)\s*([a-z]*)\s*", text)
    if not m:
        raise ValueError(f"bad time: {text!r}")
    unit = m.group(2) or "ns"
    if unit not in UNITS:
        raise ValueError(f"bad time unit in {text!r}")
    return float(m.group(1)) * UNITS[unit]


def read_header(f):
    """读到 $enddefinitions 为止，返回 (timescale 秒, [Var])。"""
    tokens = []
    for line in f:
        tokens.extend(line.split())
        if "$enddefinitions" in tokens:
            break
    timescale, variables, scope = 1e-12, [], []
    it = iter(tokens)
    for tok in it:
        if tok == "$timescale":
            spec = "".join(iter(lambda: next(it), "$end"))
            timescale = parse_time(spec)
        elif tok == "$scope":
            _kind, name = next(it), next(it)
            scope.append(name)
            next(it)  # $end
        elif tok == "$upscope":
            scope.pop()
            next(it)
        elif tok == "$var":
            _kind, width, code = next(it), int(next(it)), next(it)
            ref = list(iter(lambda: next(it), "$end"))
            rng = ref[1] if len(ref) > 1 else ""
            m = re.fullmatch(r"(.*?)(\[[0-9:]+\])", ref[0])
            if m:  # 形如 leds[15:0] 连在一起
                ref[0], rng = m.group(1), m.group(2)
            variables.append(Var(".".join(scope + [ref[0]]), code, width, rng))
        elif tok.startswith("$") and tok not in ("$end", "$enddefinitions"):
            for t in it:  # 跳过 $date / $version / $comment ...
                if t == "$end":
                    break
    return timescale, variables


def extend(bits, width):
    """VCD 允许省略向量左侧的位，按规则补齐。"""
    if len(bits) >= width:
        return bits[-width:]
    pad = bits[0] if bits[0] in "xz" else "0"
    return pad * (width - len(bits)) + bits


def read_changes(f, wanted):
    """读取值变化，只保存 wanted（code -> [Var]）里的信号。返回 (最后时刻, dumpoff 时刻或 None)。"""
    tick, dumpoff_at, skipping, pending = 0, None, False, None
    for line in f:
        for tok in line.split():
            if pending is not None:  # 向量 / 实数值后面的 code（code 本身也可能以 # 开头）
                vs = None if skipping else wanted.get(tok)
                for v in vs or ():
                    v.changes.append((tick, pending if pending[0] == "r" else extend(pending, v.width)))
                pending = None
                continue
            c = tok[0]
            if c == "#":
                tick = int(tok[1:])
            elif c == "$":
                if tok == "$dumpoff":
                    skipping = True
                    if dumpoff_at is None:
                        dumpoff_at = tick
                elif tok == "$dumpon":
                    skipping = False
                    dumpoff_at = None
            elif c in "bB":
                pending = tok[1:].lower()
            elif c in "rR":
                pending = "r" + tok[1:]
            elif not skipping and c in "01xXzZ":
                for v in wanted.get(tok[1:], ()):
                    v.changes.append((tick, c.lower()))
    return tick, dumpoff_at


# ---------------------------------------------------------------- 信号选择

def match(pattern, variables):
    """后缀匹配 + 通配。无通配时同名多个取层次最浅的一个。"""
    hits = [v for v in variables
            if fnmatch.fnmatchcase(v.name, pattern) or fnmatch.fnmatchcase(v.name, "*." + pattern)]
    if not any(ch in pattern for ch in "*?[") and len(hits) > 1:
        hits = [min(hits, key=lambda v: v.name.count("."))]
    seen, out = set(), []
    for v in hits:
        if v.name not in seen:
            seen.add(v.name)
            out.append(v)
    return out


def short_label(var, pattern):
    depth = pattern.count(".") + 1
    return ".".join(var.name.split(".")[-depth:]) + (var.rng if var.width > 1 else "")


def build_rows(variables, specs, max_signals):
    rows = []
    if not specs:
        for v in variables[:max_signals]:
            rows.append(Row("signal", v.name + (v.rng if v.width > 1 else ""), v))
        if len(variables) > max_signals:
            print(f"render_wave: only first {max_signals} of {len(variables)} signals drawn "
                  f"(use --signals / -s to choose)", file=sys.stderr)
        return rows
    for spec in specs:
        spec = spec.strip()
        if not spec or spec.startswith("#"):
            continue
        if spec.startswith("--"):
            rows.append(Row("divider", spec[2:].strip()))
            continue
        parts = spec.split()
        pattern, radix, label = parts[0], "hex", None
        for p in parts[1:]:
            if p.startswith("radix="):
                radix = p.split("=", 1)[1]
            else:
                label = p
        hits = match(pattern, variables)
        if not hits:
            print(f"render_wave: WARNING no signal matches {pattern!r}", file=sys.stderr)
        for v in hits:
            rows.append(Row("signal", label if (label and len(hits) == 1) else short_label(v, pattern), v, radix))
    return rows


# ---------------------------------------------------------------- 取值与格式化

def value_at(changes, tick):
    """changes 按时间排序，返回 tick 时刻（含）的值；之前无值返回 'x'。"""
    lo, hi = 0, len(changes)
    while lo < hi:
        mid = (lo + hi) // 2
        if changes[mid][0] <= tick:
            lo = mid + 1
        else:
            hi = mid
    return changes[lo - 1][1] if lo else "x"


def segments(changes, t0, t1):
    """把变化列表切成 [t0, t1] 内的 (start, end, value) 段；同一时刻多次赋值取最后一次。"""
    segs, cur, start = [], value_at(changes, t0), t0
    for tick, val in changes:
        if tick <= t0:
            continue
        if tick >= t1:
            break
        if val != cur:
            if tick > start:
                segs.append((start, tick, cur))
                start = tick
            cur = val
    segs.append((start, t1, cur))
    return segs


def fmt(bits, radix):
    if len(bits) == 1:
        return bits.upper() if bits in "xz" else bits
    if set(bits) <= {"0", "1"}:
        n = int(bits, 2)
        if radix == "dec":
            return str(n)
        if radix == "sdec":
            return str(n - (1 << len(bits)) if bits[0] == "1" else n)
        if radix == "bin":
            return bits
        if radix == "ascii":  # 字符串向量（testbench 里的反汇编等），去掉前面补的 0
            raw = n.to_bytes((len(bits) + 7) // 8, "big").lstrip(b"\0")
            return "".join(chr(c) if 32 <= c < 127 else "." for c in raw)
        return format(n, "0%dx" % ((len(bits) + 3) // 4))
    if set(bits) == {"z"}:
        return "Z"
    if set(bits) == {"x"}:
        return "X"
    out = []  # 混合 X/Z：逐个十六进制位显示
    pad = (-len(bits)) % 4
    b = "0" * pad + bits
    for i in range(0, len(b), 4):
        nib = b[i:i + 4]
        out.append(format(int(nib, 2), "x") if set(nib) <= {"0", "1"} else ("Z" if set(nib) == {"z"} else "X"))
    return "".join(out)


def pick_unit(span_s):
    for name in ("s", "ms", "us", "ns", "ps"):
        if span_s >= UNITS[name] * 2:
            return name
    return "fs"


# ---------------------------------------------------------------- 绘图

def render(rows, t0, t1, data_end, timescale, out, width_in, theme, cursor, title):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import LineCollection, PolyCollection
    from matplotlib.patches import Rectangle

    th = THEMES[theme]
    unit = pick_unit((t1 - t0) * timescale)
    k = timescale / UNITS[unit]           # tick -> 显示单位
    x0, x1 = t0 * k, t1 * k

    n = len(rows)
    row_h, top_in, bot_in = 0.32, 0.55, 0.45
    label_chars = max([len(r.label) for r in rows] + [8])
    value_chars = 0
    if cursor is not None:
        value_chars = max([len(fmt(value_at(r.var.changes, cursor), r.radix)) for r in rows
                           if r.kind == "signal"] + [5])
    left_in = 0.25 + 0.075 * (label_chars + value_chars + (2 if value_chars else 0))
    height_in = top_in + bot_in + row_h * n
    fig = plt.figure(figsize=(width_in, height_in), dpi=150, facecolor=th["bg"])
    ax = fig.add_axes([left_in / width_in, bot_in / height_in,
                       1 - (left_in + 0.25) / width_in, (row_h * n) / height_in])
    ax.set_facecolor(th["bg"])
    ax.set_xlim(x0, x1)
    ax.set_ylim(0, n)
    ax.set_yticks([])
    for s in ax.spines.values():
        s.set_color(th["grid"])
    ax.tick_params(axis="x", colors=th["fg"], labelsize=8, top=True, labeltop=True)
    ax.grid(axis="x", color=th["grid"], linewidth=0.6)
    ax.set_axisbelow(True)
    ax.set_xlabel(unit, color=th["fg"], fontsize=8, labelpad=2)

    px_per_unit = ax.get_position().width * width_in * 150 / (x1 - x0)
    char_px = 8 * 150 / 72 * 0.62  # 8pt 等宽字符宽度
    lw = 1.0

    if data_end is not None and data_end < t1:  # dump 结束之后没有数据，灰色标出
        ax.add_patch(Rectangle((data_end * k, 0), x1 - data_end * k, n, color=th["off"], zorder=0))

    for i, row in enumerate(rows):
        y = n - 1 - i
        lo, hi, mid = y + 0.18, y + 0.82, y + 0.5
        ax.text(-(0.1 + 0.075 * value_chars) / (ax.get_position().width * width_in) if value_chars else -0.004,
                mid, row.label, transform=ax.get_yaxis_transform(), ha="right", va="center",
                color=th["divider"] if row.kind == "divider" else th["fg"], fontsize=8,
                family="monospace", fontstyle="italic" if row.kind == "divider" else "normal")
        if row.kind == "divider":
            ax.axhline(y + 0.02, color=th["grid"], linewidth=0.6)
            continue
        var = row.var
        if cursor is not None:
            ax.text(-0.004, mid, fmt(value_at(var.changes, cursor), row.radix),
                    transform=ax.get_yaxis_transform(), ha="right", va="center",
                    color=th["cursor"], fontsize=8, family="monospace")
        end = min(t1, data_end) if data_end is not None else t1
        if end <= t0:
            continue
        segs = segments(var.changes, t0, end)
        dense = len(segs) > 0.5 * px_per_unit * (end - t0) * k  # 平均每段不到 2 个像素
        if var.width == 1:
            lines, xs, zs = [], [], []
            path = []
            for a, b, v in segs:
                if v in "01":
                    yy = hi if v == "1" else lo
                    path += [(a * k, yy), (b * k, yy)]
                else:
                    if path:
                        lines.append(path)
                        path = []
                    (xs if v == "x" else zs).append((a * k, b * k))
            if path:
                lines.append(path)
            ax.add_collection(LineCollection(lines, colors=th["wave"], linewidths=lw * (0.6 if dense else 1)))
            for a, b in xs:
                ax.add_patch(Rectangle((a, lo), b - a, hi - lo, color=th["x"], alpha=0.55, linewidth=0))
            for a, b in zs:
                ax.plot([a, b], [mid, mid], color=th["z"], linewidth=lw)
        else:
            polys, colors, labels = [], [], []
            d_units = 3 / px_per_unit  # 斜边 3 像素
            for a, b, v in segs:
                xa, xb = a * k, b * k
                d = min(d_units, (xb - xa) / 2)
                polys.append([(xa, mid), (xa + d, hi), (xb - d, hi), (xb, mid), (xb - d, lo), (xa + d, lo)])
                bad = any(ch in v for ch in "xz")
                colors.append(th["x"] if "x" in v else (th["z"] if bad else th["bus"]))
                text = fmt(v, row.radix)
                if (xb - xa) * px_per_unit > len(text) * char_px + 6:
                    labels.append(((xa + xb) / 2, text, colors[-1] if bad else th["fg"]))
            ax.add_collection(PolyCollection(polys, facecolors="none", edgecolors=colors,
                                             linewidths=lw * (0.6 if dense else 1)))
            for xm, text, color in labels:
                ax.text(xm, mid, text, ha="center", va="center", color=color, fontsize=7.5,
                        family="monospace", clip_on=True)

    if cursor is not None:
        ax.axvline(cursor * k, color=th["cursor"], linewidth=0.9)
        ax.text(cursor * k, n, f" {cursor * k:g} {unit}", color=th["cursor"], fontsize=7.5,
                va="bottom", ha="left", clip_on=False)
    fig.suptitle(title, color=th["fg"], fontsize=9, x=0.01, ha="left", y=1 - 0.08 / height_in)
    fig.savefig(out, facecolor=th["bg"])
    print(f"render_wave: wrote {out} ({len(rows)} rows, {x0:g}..{x1:g} {unit})")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vcd")
    ap.add_argument("-o", "--output", default="wave.png")
    ap.add_argument("-s", "--signal", action="append", default=[], help="信号匹配模式，可重复")
    ap.add_argument("--signals", help="信号清单文件（每行一个模式，见 sim/wave_signals.txt）")
    ap.add_argument("--start", default=None, help="起始时间，例如 0 / 2us（默认 VCD 开头）")
    ap.add_argument("--end", default=None, help="结束时间（默认 VCD 结尾或 $dumpoff 处）")
    ap.add_argument("--cursor", default=None, help="在该时刻画游标并在左侧显示信号值")
    ap.add_argument("--width", type=float, default=16, help="图片宽度（英寸，150dpi）")
    ap.add_argument("--theme", choices=THEMES, default="dark")
    ap.add_argument("--max-signals", type=int, default=40)
    ap.add_argument("--title", default=None)
    ap.add_argument("--list", action="store_true", help="只列出信号")
    args = ap.parse_args()

    with open(args.vcd) as f:
        timescale, variables = read_header(f)
        if args.list:
            for v in variables:
                print(f"{v.name}{v.rng}  (width {v.width})")
            return
        specs = list(args.signal)
        if args.signals:
            with open(args.signals, encoding="utf-8") as sf:
                specs += sf.read().splitlines()
        rows = build_rows(variables, specs, args.max_signals)
        if not any(r.kind == "signal" for r in rows):
            sys.exit("render_wave: no signals selected")
        wanted = {}
        for r in rows:
            if r.var is not None:
                lst = wanted.setdefault(r.var.code, [])
                if all(v is not r.var for v in lst):
                    lst.append(r.var)
        last_tick, dumpoff_at = read_changes(f, wanted)

    to_tick = lambda s: int(round(parse_time(s) / timescale))
    t0 = to_tick(args.start) if args.start else 0
    data_end = dumpoff_at if dumpoff_at is not None else last_tick
    t1 = to_tick(args.end) if args.end else data_end
    if t1 <= t0:
        sys.exit(f"render_wave: empty time window ({t0}..{t1} ticks)")
    cursor = to_tick(args.cursor) if args.cursor else None
    title = args.title or f"{args.vcd}"
    render(rows, t0, t1, data_end if data_end < t1 else None, timescale, args.output,
           args.width, args.theme, cursor, title)


if __name__ == "__main__":
    main()
