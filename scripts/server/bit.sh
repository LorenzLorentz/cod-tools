#!/usr/bin/env bash
# 【容器内执行】综合 + 实现 + 生成 bitstream，比特流和报告放到 build/bit/。
# 一般由 tools/scripts/remote.sh bit 调用。环境变量：OUT（默认 build/bit）、JOBS（默认 4）。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${REPO_ROOT:-/workspace}"

OUT=${OUT:-build/bit}
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> [bitstream] vivado -mode batch -source $SCRIPT_DIR/../vivado/bits.tcl  (JOBS=${JOBS:-4})"
vivado -mode batch -nojournal -log "$OUT/vivado.log" -source "$SCRIPT_DIR/../vivado/bits.tcl" -tclargs "$OUT" \
  | grep -E --line-buffered '^(BIT:|ERROR|CRITICAL WARNING)|Launched |impl_1 finished|Bitgen Completed' || true
ls "$OUT"/*.bit > /dev/null 2>&1 || { echo "!! 没有生成 .bit，详见 $OUT/vivado.log 和 $OUT/*.runme.log" >&2; exit 1; }
grep -A2 -m1 'WNS(ns)' "$OUT/timing_summary.rpt" || true
( cd "$OUT" && sha256sum ./*.bit )
