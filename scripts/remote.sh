#!/usr/bin/env bash
# 本地 → 服务器：同步代码、在服务器的 Vivado 容器里执行、把结果拉回本地。
#
#   tools/scripts/remote.sh check               检查服务器环境（docker 权限、镜像、磁盘）
#   tools/scripts/remote.sh image               在服务器上 build vivado-flow 镜像（每台服务器一次）
#   tools/scripts/remote.sh sim                 xsim 仿真 + 渲染，结果拉回 $SIM_OUT（默认 build/sim/）
#   tools/scripts/remote.sh bit                 生成 bitstream，结果拉回 $BIT_OUT（默认 build/bit/）
#   tools/scripts/remote.sh wave-gui            （可选，需先 sim）Vivado GUI 打开 $SIM_OUT 里的 WDB 并截图 → $SIM_OUT/vivado_gui.png
#   tools/scripts/remote.sh shell [sim|bit]     进入服务器上的容器（交互式 bash）
#   tools/scripts/remote.sh run <sim|bit> CMD…  在容器里执行任意命令
#
# 配置：复制 flow.env.example 为课程仓库根目录的 flow.env 修改，或者直接用环境变量覆盖（环境变量优先）。
# SIM_OUT / BIT_OUT 是结果目录（仓库内 build/ 下的相对路径），不同实验、不同版本可以放到不同目录，互不覆盖。
# 本脚本在 tools/ 里，但所有相对路径（rsync ./、build/、.xpr）都以课程仓库根 $REPO_ROOT 为准；
# 直接手动运行时用 REPO_ROOT=$PWD 指定，Makefile 会自动设置。
# 兼容 macOS 自带的 bash 3.2。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOOLS_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=${REPO_ROOT:-$PWD}
cd "$REPO_ROOT"
if [ -f "$REPO_ROOT/flow.env" ]; then . "$REPO_ROOT/flow.env"; fi

# tools 必须位于 REPO_ROOT 里面（课程仓库的 tools/ 子模块），服务器脚本才会被一起同步过去。
case "$TOOLS_DIR/" in
  "$REPO_ROOT"/*) TOOLS_REL=${TOOLS_DIR#"$REPO_ROOT"/} ;;
  *) TOOLS_REL="" ;;
esac

REMOTE_HOST=${REMOTE_HOST:-cluster39}
REMOTE_DIR=${REMOTE_DIR:-vivado-flow/$(basename "$REPO_ROOT")}
IMAGE=${IMAGE:-vivado-flow:2024.2}
BASE_IMAGE=${BASE_IMAGE:-vivado:2024.2}
VIVADO_MAX_THREADS=${VIVADO_MAX_THREADS:-8}
JOBS=${JOBS:-4}
SIM_OUT=${SIM_OUT:-build/sim}
BIT_OUT=${BIT_OUT:-build/bit}
# 这些环境变量会原样传进容器（没设置的不传）；OUT 由 run_task 设置
PASS_ENV="OUT MODE TOP WAVE_TITLE SIM_TOP SIM_TIME VCD_SCOPES VCD_TIME PLUSARGS GENERICS WAVE_SIGNALS WAVE_ARGS WAVE_CURSOR_US WAVE_START_US WAVE_END_US JOBS VIVADO_MAX_THREADS"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }
q() { printf '%q' "$1"; }

# 每个任务在服务器上有独立的工作副本（~/$REMOTE_DIR/sim、~/$REMOTE_DIR/bit），
# 可以同时跑仿真和编译，也各自保留 Vivado 的增量状态（IP 缓存等）
workdir() { echo "$REMOTE_DIR/$1"; }

sync_up() {
  local dir
  dir=$(workdir "$1")
  log "sync  ./ -> $REMOTE_HOST:~/$dir/"
  ssh "$REMOTE_HOST" "mkdir -p $(q "$dir")"
  rsync -az --delete --copy-unsafe-links --exclude-from="$TOOLS_DIR/scripts/rsync-exclude.txt" ./ "$REMOTE_HOST:$dir/"
}

fetch() {  # fetch <task> <subdir>
  local dir
  dir=$(workdir "$1")
  log "fetch $REMOTE_HOST:~/$dir/$2/ -> ./$2/"
  mkdir -p "$2"
  rsync -az --delete "$REMOTE_HOST:$dir/$2/" "$2/"
}

in_docker() {  # in_docker <task> <cmd…>
  local task=$1
  shift
  local dir name envs="" tty="" v
  dir=$(workdir "$task")
  name="vflow-$task-$(date +%s)-$$"
  for v in $PASS_ENV; do
    if [ -n "${!v:-}" ]; then envs="$envs -e $(q "$v=${!v}")"; fi
  done
  if [ -t 0 ] && [ -t 1 ]; then tty="-it"; fi
  # Ctrl-C 时顺手把服务器上的容器停掉，避免 Vivado 在后台继续占资源
  trap 'ssh "$REMOTE_HOST" docker rm -f "$name" >/dev/null 2>&1; exit 130' INT TERM
  log "run   [$REMOTE_HOST:$IMAGE] $*"
  ssh ${tty:+-t} "$REMOTE_HOST" "cd $(q "$dir") && docker run --rm $tty --name $name \
    -e REUID=\$(id -u) -e REGID=\$(id -g) $envs \
    -v \"\$PWD\":/workspace -w /workspace $(q "$IMAGE") $(printf '%q ' "$@")"
  local rc=$?
  trap - INT TERM
  return $rc
}

check_out() {  # 服务器脚本会 rm -rf 结果目录，只允许 build/ 下的相对路径
  case "$1" in
    build/?* ) case "$1" in *..*) ;; *) return 0 ;; esac ;;
  esac
  echo "remote.sh: 结果目录必须是 build/ 下的相对路径（不能含 ..）：$1" >&2
  exit 2
}

run_task() {  # run_task <task> <script> <result dir>
  local rc=0
  check_out "$3"
  if [ -z "$TOOLS_REL" ]; then
    echo "remote.sh: tools 目录 $TOOLS_DIR 不在课程仓库 $REPO_ROOT 里面；请把 tools/ 作为课程仓库的子模块" >&2
    exit 2
  fi
  sync_up "$1"
  OUT=$3 in_docker "$1" bash "$TOOLS_REL/$2" || rc=$?
  fetch "$1" "$3"  # 失败时也把日志拉回来
  if [ $rc -ne 0 ]; then log "FAILED ($rc), logs in ./$3/"; fi
  return $rc
}

cmd=${1:-help}
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  check)
    ssh "$REMOTE_HOST" "echo \"host   \$(hostname)  user \$(id -un)  groups \$(id -Gn)\"
      docker version --format 'docker {{.Server.Version}}' || { echo 'cannot talk to docker (need docker group)'; exit 1; }
      for i in $(q "$BASE_IMAGE") $(q "$IMAGE"); do
        if docker image inspect \"\$i\" >/dev/null 2>&1; then echo \"image  ok       \$i\"; else echo \"image  MISSING  \$i\"; fi
      done
      echo \"disk   \$(df -h \$(docker info --format '{{.DockerRootDir}}') | tail -1)\""
    ;;
  image)
    log "docker build $IMAGE (FROM $BASE_IMAGE) on $REMOTE_HOST"
    ssh "$REMOTE_HOST" "mkdir -p $(q "$REMOTE_DIR/docker")"
    rsync -az --delete "$TOOLS_DIR/docker/" "$REMOTE_HOST:$REMOTE_DIR/docker/"
    ssh "$REMOTE_HOST" "docker build -t $(q "$IMAGE") --build-arg BASE=$(q "$BASE_IMAGE") \
      ${APT_MIRROR:+--build-arg APT_MIRROR=$(q "$APT_MIRROR")} $(q "$REMOTE_DIR/docker")"
    ;;
  sim) run_task sim "scripts/server/sim.sh" "$SIM_OUT" ;;
  bit) run_task bit "scripts/server/bit.sh" "$BIT_OUT" ;;
  wave-gui) run_task sim "scripts/server/wave_gui.sh" "$SIM_OUT" ;;
  shell)
    task=${1:-sim}
    sync_up "$task"
    in_docker "$task" bash
    ;;
  run)
    task=${1:?usage: remote.sh run <sim|bit> CMD…}
    shift
    sync_up "$task"
    in_docker "$task" "$@"
    ;;
  sync) sync_up "${1:-sim}" ;;
  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
