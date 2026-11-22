#!/usr/bin/env bash
# 【容器内执行】在 Xvfb 虚拟显示器里启动 Vivado GUI，打开 build/sim 下的 WDB，
# 给波形窗口截图 → build/sim/vivado_gui.png（同时留下 build/sim/wave.wcfg）。
# 需要先跑过 tools/scripts/server/sim.sh。由本地 tools/scripts/remote.sh wave-gui 调用。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${REPO_ROOT:-/workspace}"

OUT=${OUT:-build/sim}
WDB=$(ls "$OUT"/*_behav.wdb 2>/dev/null | head -1)
[ -n "$WDB" ] || { echo "!! $OUT 里没有 .wdb，先跑 make sim" >&2; exit 1; }
WAVE_SIGNALS=${WAVE_SIGNALS:-sim/wave_signals.txt}
[ -f "$WAVE_SIGNALS" ] || { echo "!! 找不到信号清单 $WAVE_SIGNALS" >&2; exit 1; }
WAVE_CURSOR_US=${WAVE_CURSOR_US:-17.12}  # 游标位置（us）
WAVE_START_US=${WAVE_START_US:-0}       # 从多少 us 开始显示
WAVE_END_US=${WAVE_END_US:-25}          # 显示到多少 us（近似，见 wave_gui.tcl 的说明）

# 屏幕尺寸固定：wave_gui.tcl 里的缩放系数 ZOOM_FIX 是按 1920x1080 标定的
SCREEN_W=1920
SCREEN_H=1080

rm -f "$OUT/.wave_gui_ready" "$OUT/vivado_gui.png"
Xvfb :77 -screen 0 ${SCREEN_W}x${SCREEN_H}x24 -nolisten tcp > /dev/null 2>&1 &
XVFB=$!
export DISPLAY=:77
sleep 2

echo "==> [wave-gui] vivado -mode gui (Xvfb) 打开 $WDB"
vivado -mode gui -nojournal -log "$OUT/wave_gui.log" -source "$SCRIPT_DIR/../vivado/wave_gui.tcl" \
  -tclargs "$WDB" "$OUT" "$WAVE_SIGNALS" "$WAVE_CURSOR_US" "$WAVE_END_US" "$WAVE_START_US" > /dev/null 2>&1 &
VIV=$!
cleanup() { kill "$VIV" 2> /dev/null || true; sleep 2; kill -9 "$VIV" 2> /dev/null || true; kill "$XVFB" 2> /dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 90); do
  [ -f "$OUT/.wave_gui_ready" ] && break
  kill -0 "$VIV" 2> /dev/null || { echo "!! Vivado GUI 提前退出，见 $OUT/wave_gui.log" >&2; exit 1; }
  sleep 2
done
[ -f "$OUT/.wave_gui_ready" ] || { echo "!! 等待 Vivado GUI 超时，见 $OUT/wave_gui.log" >&2; exit 1; }
sleep 3

# Vivado 不管屏幕多大都开成 1500x950，波形窗口只放得下约 20 行，信号多了会被窗口底部的横线从中间截断。
# Xvfb 里没有窗口管理器，用 Xlib 直接把主窗口拉满屏幕，Java 会重新布局
WIN=$(xwininfo -root -tree | awk '/"Vivado 20/ {print $1; exit}')
if [ -n "$WIN" ]; then
  python3 "$SCRIPT_DIR/xctl.py" resize "$WIN" "$SCREEN_W" "$SCREEN_H"
fi
sleep 8  # 等重新布局、波形窗口画完

import -window "${WIN:-root}" "$OUT/vivado_gui.png"
rm -f "$OUT/.wave_gui_ready"
echo "wave-gui: wrote $OUT/vivado_gui.png and $OUT/wave.wcfg"
