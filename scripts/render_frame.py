#!/usr/bin/env python3
"""把 vga_capture 写出的帧文件（RGB332 十六进制文本）转成 PNG。只依赖标准库。

用法:
  render_frame.py frame.hex -o frame.png
  render_frame.py a.hex --diff b.hex     # 逐像素比较两帧（例如 Verilator vs xsim），不同则退出码 1
"""

import argparse
import struct
import sys
import zlib

X_COLOR = (255, 0, 255)  # X/Z 像素画成品红，一眼能看出来


def read_frame(path):
    with open(path) as f:
        header = f.readline().split()
        if header[:2] != ["#", "vga_capture"]:
            sys.exit(f"{path}: not a vga_capture file")
        w, h = map(int, header[2].split("x"))
        rows = [line.strip() for line in f if line.strip()]
    if len(rows) != h:
        print(f"{path}: WARNING expected {h} rows, got {len(rows)}", file=sys.stderr)
    return w, h, rows


def to_rgb(row, w):
    out, bad = bytearray(), 0
    for i in range(w):
        pair = row[2 * i:2 * i + 2]
        try:
            v = int(pair, 16)
        except ValueError:  # 'xx' / 'zz' / 行太短
            out += bytes(X_COLOR)
            bad += 1
            continue
        r, g, b = v >> 5, (v >> 2) & 7, v & 3
        out += bytes((r * 255 // 7, g * 255 // 7, b * 255 // 3))
    return bytes(out), bad


def write_png(path, w, h, rgb_rows):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + r for r in rgb_rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frame")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--diff", metavar="OTHER", help="与另一帧逐像素比较")
    args = ap.parse_args()

    w, h, rows = read_frame(args.frame)

    if args.diff:
        w2, h2, rows2 = read_frame(args.diff)
        if (w, h) != (w2, h2):
            sys.exit(f"size differs: {w}x{h} vs {w2}x{h2}")
        diff = [(y, x) for y in range(h) for x in range(w)
                if rows[y][2 * x:2 * x + 2] != rows2[y][2 * x:2 * x + 2]]
        if diff:
            y, x = diff[0]
            print(f"DIFF: {len(diff)} of {w * h} pixels differ, first at (x={x}, y={y})")
            sys.exit(1)
        print(f"SAME: {args.frame} == {args.diff} ({w}x{h})")
        if not args.output:
            return

    rgb_rows, bad = [], 0
    for y in range(h):
        row = rows[y] if y < len(rows) else ""
        rgb, b = to_rgb(row, w)
        rgb_rows.append(rgb)
        bad += b
    out = args.output or args.frame.rsplit(".", 1)[0] + ".png"
    write_png(out, w, h, rgb_rows)
    print(f"render_frame: wrote {out} ({w}x{h})" + (f", {bad} X/Z pixels" if bad else ""))
    if bad:
        sys.exit(2)


if __name__ == "__main__":
    main()
