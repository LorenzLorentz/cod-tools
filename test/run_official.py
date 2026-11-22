#!/usr/bin/env python3
"""官方测例的本地集成入口。

把课程 testcases/basic 的 1.py / 2.py / 3.py 拷到课程仓库的 build/official/（不修改原文件），
从脚本自带的 Model 生成内存镜像和期望结果，再用 Verilator 的 tb_official_soc 直接跑每个
测例的用户程序（不经过监控程序）：

  * 基础测例（1.py）：G/R/D2 三步对应的程序执行、寄存器结果、数据内存结果；
  * A01-A20：全部 20 项；
  * B04/B06/B09-B17：脚本里只含 run/tab 步骤、可以直接跑的 11 项。

需要监控程序命令的测例（B01-B03/B05/B07/B08/B18-B20）不在本地直跑范围内。

用法（在课程仓库根目录）：python3 tools/test/run_official.py [--only A10,B13,basic]

课程仓库根由 REPO_ROOT 指定（Makefile 会设成 $(CURDIR)）；不设时默认 tools/ 的上一级。
官方测例目录由 TESTCASES 覆盖，默认是课程仓库的 ../testcases/basic。
"""
import argparse
import importlib.util
import os
import re
import shutil
import struct
import subprocess
import sys
import types
import urllib.request
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("REPO_ROOT", TOOLS.parent)).resolve()
WORK = ROOT / "build" / "official"
SRC = Path(os.environ.get("TESTCASES", ROOT.parent / "testcases" / "basic")).resolve()
SIM = ROOT / "build" / "verilator" / "tb_official_soc" / "sim"
MON_SIM = ROOT / "build" / "verilator" / "tb_monitor_soc" / "sim"
KERNEL_URL = "https://lab.cs.tsinghua.edu.cn/thinpad/static/r/cod26/kernel-5736926b5353.bin"


def load_py(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_basic(path: Path):
    """1.py 直接 from TestcaseBase import *，没有 fallback；用假模块把常量读出来。"""
    class Dummy:
        def __call__(self, f):
            return f

        def __getattr__(self, k):
            return Dummy()

        def __lshift__(self, o):
            return self

    fake = types.ModuleType("TestcaseBase")
    fake.TestcaseBase = type("TestcaseBase", (object,), {})
    fake.Serial = Dummy()
    fake.Timer = Dummy()
    fake.started = lambda f: f
    fake.abort = lambda f: f
    old = sys.modules.get("TestcaseBase")
    sys.modules["TestcaseBase"] = fake
    try:
        ns = {"__name__": "official_basic"}
        exec(compile(path.read_text(), str(path), "exec"), ns)
    finally:
        if old is None:
            del sys.modules["TestcaseBase"]
        else:
            sys.modules["TestcaseBase"] = old
    return ns


def direct_items(model):
    """只含 run/tab 的测例，按 (item id, program index) 返回。"""
    out = []
    for ident, _title, steps in model.items:
        if all(s[0] in ("run", "tab") for s in steps):
            for st in steps:
                if st[0] == "run":
                    out.append((ident, st[1]))
                    break
    return out


def write_image(path: Path, host):
    with path.open("w") as f:
        for addr, data in host:
            assert len(data) % 4 == 0, (hex(addr), len(data))
            for i in range(0, len(data), 4):
                f.write("%08x %08x\n" % (addr + i, struct.unpack_from("<I", data, i)[0]))


def write_prog(path: Path, items, model, nreg_map=None, tmo_map=None):
    """每项：entry res n tabs nout nreg tmo + n 个期望字 + nout 个串口字节 + nreg 个 (reg, value)。"""
    with path.open("w") as f:
        for ident, pi in items:
            p = model.progs[pi]
            nreg = 0 if nreg_map is None else len(nreg_map.get(ident, ()))
            tmo = 0 if tmo_map is None else tmo_map.get(ident, 0)
            f.write("%08x %08x %d %d %d %d %d\n" % (p["entry"], p["res"], p["n"], p["tabs"], len(p["out"]), nreg, tmo))
            f.write(" ".join("%08x" % x for x in p["exp"]) + "\n")
            f.write(" ".join("%02x" % x for x in p["out"]) + "\n")
            for (r, v) in (nreg_map or {}).get(ident, ()):
                f.write("%d %08x\n" % (r, v))


def run_set(name, images: Path, progs: Path, items):
    res = subprocess.run([str(SIM), "+IMAGES=" + str(images), "+PROGS=" + str(progs)],
                         capture_output=True, text=True)
    out = res.stdout + res.stderr
    got = {}
    for line in out.splitlines():
        m = re.match(r"PROG (\d+) entry=[0-9a-f]+ (PASS|FAIL)", line)
        if m:
            got[int(m.group(1))] = (m.group(2) == "PASS", line)
    ok = True
    print("== %s ==" % name)
    for i, (ident, _pi) in enumerate(items):
        passed, line = got.get(i, (False, "PROG %d missing" % i))
        print("  %-7s %s" % (ident, "PASS" if passed else "FAIL"))
        if not passed:
            print("          " + line)
            ok = False
    return ok, out


def ensure_kernel():
    """下载/转换基础监控程序 kernel，给 tb_monitor_soc 用。失败时返回 None（跳过）。"""
    bin_path = WORK / "kernel.bin"
    hex_path = WORK / "kernel.hex"
    try:
        if not bin_path.is_file():
            print("downloading kernel ...")
            urllib.request.urlretrieve(KERNEL_URL, bin_path)
        if not hex_path.is_file():
            data = bin_path.read_bytes()
            if len(data) % 4:
                raise ValueError("kernel size %d is not a multiple of 4" % len(data))
            with hex_path.open("w") as f:
                for i in range(0, len(data), 4):
                    f.write("%08x %08x\n" % (0x80000000 + i, struct.unpack_from("<I", data, i)[0]))
        return hex_path
    except Exception as e:  # 没网/下载失败时只跳过监控程序冒烟测试
        print("WARNING: kernel unavailable, skip monitor smoke test: %s" % e)
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="逗号分隔的测例 ID（A10,B13,basic）；默认全部")
    args = ap.parse_args()
    only = set(x.strip() for x in args.only.split(",")) if args.only else None

    WORK.mkdir(parents=True, exist_ok=True)
    if SRC.is_dir():
        for name in ("1.py", "2.py", "3.py"):
            shutil.copyfile(SRC / name, WORK / name)
    else:
        missing = [n for n in ("1.py", "2.py", "3.py") if not (WORK / n).is_file()]
        if missing:
            sys.exit("找不到官方测例：%s 不存在，build/official/ 里也没有 %s" % (SRC, ", ".join(missing)))

    # ---- A ----
    mod_a = load_py(WORK / "2.py", "official_A")
    model_a = mod_a.Model(mod_a.SPEC, b"")
    items_a = direct_items(model_a)
    if only:
        items_a = [(i, p) for (i, p) in items_a if i in only]
    write_image(WORK / "a_images.hex", model_a.host)
    write_prog(WORK / "a_progs.txt", items_a, model_a,
               tmo_map={i: model_a.progs[p].get("tmo", 0) for i, p in items_a})

    # ---- B ----
    mod_b = load_py(WORK / "3.py", "official_B")
    model_b = mod_b.Model(mod_b.SPEC, b"")
    items_b = direct_items(model_b)
    if only:
        items_b = [(i, p) for (i, p) in items_b if i in only]
    write_image(WORK / "b_images.hex", model_b.host)
    write_prog(WORK / "b_progs.txt", items_b, model_b,
               tmo_map={i: model_b.progs[p].get("tmo", 0) for i, p in items_b})

    # ---- 基础测例（1.py）----
    ns = load_basic(WORK / "1.py")
    up, rv, mv = ns["USER_PROGRAM"], ns["REG_VERIFICATION"], ns["MEM_VERIFICATION"]
    basic_items = [("BASIC", 0)]
    if only and "basic" not in only and "BASIC" not in only:
        basic_items = []
    with (WORK / "c_images.hex").open("w") as f:
        for i in range(0, len(up), 4):
            f.write("%08x %08x\n" % (0x80100000 + i, struct.unpack_from("<I", up, i)[0]))
    words = struct.unpack("<%dI" % (len(mv) // 4), mv)
    with (WORK / "c_progs.txt").open("w") as f:
        f.write("%08x %08x %d 1 0 %d %d\n" % (0x80100000, 0x80400100, len(words), len(rv), 5000))
        f.write(" ".join("%08x" % x for x in words) + "\n")
        f.write("\n")
        for (r, v) in rv:
            f.write("%d %08x\n" % (r, v))

    print("building Verilator testbenches ...")
    subprocess.run(["make", "build/verilator/tb_official_soc/sim", "build/verilator/tb_monitor_soc/sim"],
                   cwd=ROOT, check=True)

    ok = True
    if items_a:
        r, out = run_set("A (20 items)", WORK / "a_images.hex", WORK / "a_progs.txt", items_a)
        ok &= r
    if items_b:
        r, out = run_set("B (direct-run items)", WORK / "b_images.hex", WORK / "b_progs.txt", items_b)
        ok &= r
    if basic_items:
        r, out = run_set("BASIC (60-point testcase: G/R/D2)", WORK / "c_images.hex",
                         WORK / "c_progs.txt", basic_items)
        ok &= r

    # ---- 监控程序冒烟测试（boot / W / D / G / D）----
    kernel = ensure_kernel()
    if kernel is not None:
        print("== MONITOR (kernel boot / W / D / G / D) ==")
        res = subprocess.run([str(MON_SIM), "+IMAGE=" + str(kernel)], capture_output=True, text=True)
        mon = "tb_monitor_soc: PASS" in (res.stdout + res.stderr)
        print("  MONITOR %s" % ("PASS" if mon else "FAIL"))
        if not mon:
            print((res.stdout + res.stderr)[-3000:])
        ok &= mon

    print("\nOFFICIAL: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
