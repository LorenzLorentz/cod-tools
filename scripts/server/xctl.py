#!/usr/bin/env python3
"""【容器内执行】不装 xdotool，用 ctypes 调 Xlib 调整窗口大小（Xvfb 里没有窗口管理器，直接改就生效）。

  xctl.py resize <窗口 id> <宽> <高>     窗口 id 取自 xwininfo，例如 0x200020
"""
import ctypes
import sys

if len(sys.argv) != 5 or sys.argv[1] != "resize":
    sys.exit(__doc__)
x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
dpy = ctypes.c_void_p(x11.XOpenDisplay(None))
if not dpy.value:
    sys.exit("xctl: 打不开 $DISPLAY")
win = ctypes.c_ulong(int(sys.argv[2], 0))
x11.XMoveResizeWindow(dpy, win, 0, 0, int(sys.argv[3]), int(sys.argv[4]))
x11.XFlush(dpy)
x11.XCloseDisplay(dpy)
