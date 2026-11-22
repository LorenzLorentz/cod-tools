#!/usr/bin/env python3
"""不开 Vivado GUI 维护 thinpad_top.xpr 的源文件清单和综合顶层（仅标准库）。

在 VS Code 等编辑器里新建的 .sv/.v 不会自动出现在 Vivado 工程里。工程里没有的文件，
Vivado 综合 / 仿真和课程 GitLab CI 都看不到，报的错是“module not found”或者悄悄换了顶层。

  xpr.py check [--top lab2_top]   列出 sources_1/new 下没加进工程的文件；给了 --top 时同时检查综合顶层
  xpr.py add                      把这些文件加进 sources_1（等价于 GUI 里 Add Sources）
  xpr.py top lab2_top             设置综合顶层（等价于 GUI 里 Set as Top）

只做文本插入 / 替换，不重排 XML，git diff 里只有新增的几行。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# 按当前目录找工程（Makefile 在仓库根目录调用）。不能用 __file__：课程仓库里 scripts/ 是指向
# vivado-flow-demo 的软链接，resolve() 之后就跑到 demo 仓库去了
ROOT = Path.cwd()
XPR = ROOT / "thinpad_top.xpr"
SRCDIR = ROOT / "thinpad_top.srcs"
NEW = SRCDIR / "sources_1" / "new"

FILE_BLOCK = """      <File Path="$PSRCDIR/{rel}">
        <FileInfo>
          <Attr Name="UsedIn" Val="synthesis"/>
          <Attr Name="UsedIn" Val="implementation"/>
          <Attr Name="UsedIn" Val="simulation"/>
        </FileInfo>
      </File>
"""


def sources_fileset(text: str) -> re.Match:
    m = re.search(r'(<FileSet Name="sources_1".*?)(      <Config>.*?</FileSet>)', text, re.S)
    if not m:
        sys.exit("xpr: 找不到 sources_1 fileset")
    return m


def missing_files(text: str) -> list[str]:
    listed = set(re.findall(r'<File Path="\$PSRCDIR/([^"]+)"', sources_fileset(text).group(1)))
    on_disk = sorted(p.relative_to(SRCDIR).as_posix() for ext in ("*.sv", "*.v") for p in NEW.rglob(ext))
    return [f for f in on_disk if f not in listed]


def current_top(text: str) -> str:
    m = re.search(r'<Option Name="TopModule" Val="([^"]*)"/>', sources_fileset(text).group(2))
    return m.group(1) if m else ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--top")
    sub.add_parser("add")
    t = sub.add_parser("top")
    t.add_argument("name")
    args = ap.parse_args()

    if not XPR.is_file():
        sys.exit(f"xpr: 当前目录下没有 {XPR.name}，请在仓库根目录运行")
    text = XPR.read_text(encoding="utf-8")
    missing = missing_files(text)

    if args.cmd == "check":
        ok = True
        for f in missing:
            print(f"xpr: {f} 没有加进 thinpad_top.xpr（Vivado / CI 看不到它），运行 make xpr-add")
            ok = False
        top = current_top(text)
        if args.top and top != args.top:
            print(f"xpr: 工程的综合顶层是 {top}，不是 {args.top}（GitLab CI 会编译 {top}），运行 make xpr-top")
            ok = False
        if ok:
            print(f"xpr: OK（综合顶层 {top}）")
        return 0 if ok else 1

    if args.cmd == "add":
        if not missing:
            print("xpr: 没有需要添加的文件")
            return 0
        m = sources_fileset(text)
        blocks = "".join(FILE_BLOCK.format(rel=f) for f in missing)
        text = text[: m.start(2)] + blocks + text[m.start(2):]
        for f in missing:
            print(f"xpr: + {f}")

    if args.cmd == "top":
        m = sources_fileset(text)
        cfg = m.group(2)
        new_cfg, n = re.subn(r'(<Option Name="TopModule" Val=")[^"]*("/>)', rf"\g<1>{args.name}\g<2>", cfg, count=1)
        if n == 0:
            sys.exit("xpr: sources_1 里没有 TopModule 选项")
        text = text[: m.start(2)] + new_cfg + text[m.end(2):]
        print(f"xpr: 综合顶层 {current_top(XPR.read_text(encoding='utf-8'))} -> {args.name}")

    XPR.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
