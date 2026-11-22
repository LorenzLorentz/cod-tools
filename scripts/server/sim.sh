#!/usr/bin/env bash
# 【容器内执行】xsim 行为仿真 → 导出 VCD / 帧文件 / WDB → 渲染成 PNG。
# 一般由 tools/scripts/remote.sh sim 调用，也可以在服务器上手动跑：
#   docker run --rm -e REUID=$(id -u) -e REGID=$(id -g) -v $PWD:/workspace -w /workspace \
#     vivado-flow:2024.2 bash tools/scripts/server/sim.sh
#
# 环境变量：MODE（图案，默认 0）、OUT（输出目录，默认 build/sim）、WAVE_SIGNALS、WAVE_ARGS、WAVE_TITLE，
# 以及 tools/scripts/vivado/sim.tcl 支持的 SIM_TOP / SIM_TIME / VCD_SCOPES / VCD_TIME / PLUSARGS。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${REPO_ROOT:-/workspace}"

OUT=${OUT:-build/sim}
MODE=${MODE:-0}
WAVE_SIGNALS=${WAVE_SIGNALS:-sim/wave_signals.txt}
[ -f "$WAVE_SIGNALS" ] || { echo "!! 找不到信号清单 $WAVE_SIGNALS" >&2; exit 1; }
WAVE_ARGS=${WAVE_ARGS:---end 25us --cursor 17.12us}

rm -rf "$OUT"
mkdir -p "$OUT"
export PLUSARGS="MODE=$MODE FRAME_FILE=$PWD/$OUT/frame.hex ${PLUSARGS:-}"

echo "==> [xsim] vivado -mode batch -source $SCRIPT_DIR/../vivado/sim.tcl  (MODE=$MODE)"
vivado -mode batch -nojournal -log "$OUT/vivado.log" -source "$SCRIPT_DIR/../vivado/sim.tcl" -tclargs "$OUT" \
  | grep -E --line-buffered '^(SIM:|ERROR|CRITICAL WARNING|Fatal|vga_capture:|tb_vga_frame:|\$finish)' || true
if grep -q '^ERROR' "$OUT/vivado.log"; then
  echo "!! xsim 失败，详见 $OUT/vivado.log 和 $OUT/elaborate.log" >&2
  exit 1
fi
if grep -q '^Fatal' "$OUT/vivado.log"; then  # testbench 里的 $fatal（断言失败、超时）
  echo "!! testbench 报告失败：$(grep -m1 '^Fatal' "$OUT/vivado.log")" >&2
  exit 1
fi

echo "==> [render] $OUT/*.png"
if [ -s "$OUT/frame.hex" ]; then
  python3 "$SCRIPT_DIR/../render_frame.py" "$OUT/frame.hex" -o "$OUT/frame.png"
fi
# shellcheck disable=SC2086
python3 "$SCRIPT_DIR/../render_wave.py" "$OUT/wave.vcd" -o "$OUT/wave.png" --signals "$WAVE_SIGNALS" $WAVE_ARGS \
  --title "${WAVE_TITLE:-xsim: $(basename "$OUT")/wave.vcd  (MODE=$MODE)}"
