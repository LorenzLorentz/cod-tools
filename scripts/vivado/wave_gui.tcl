# 在 Vivado GUI（Xvfb 虚拟显示器里）打开仿真生成的 WDB 波形数据库，按信号清单加波形，
# 保存 wave.wcfg，并写一个标记文件通知外面的 scripts/server/wave_gui.sh 截图。
#
# 用法：vivado -mode gui -source scripts/vivado/wave_gui.tcl -tclargs <wdb> <out_dir> <signals.txt> <cursor_us> <end_us> [start_us]
# 信号清单与 render_wave.py 共用（sim/wave_signals.txt）：
#   "dut.hdata radix=dec" → add_wave -radix unsigned dut/hdata（相对顶层 scope）
#   "-- 标题"             → add_wave_divider
# 缩放：Vivado 没有缩放波形的 Tcl 命令，只能改 wcfg 里的 <ZoomEndTime>。Vivado 打开 wcfg 时按一个约 94 px
# 宽的面板换算“每像素多少时间”，之后面板变宽就显示更长的时间，所以显示出来的范围 ≈ 面板宽度 / 94 × wcfg 里写的。
# wave_gui.sh 会把主窗口拉到 1920x1080（波形面板约 885 px），实测系数 9.42（1500x950 默认窗口时是 4.94）。
# 它是经验值：换分辨率 / 布局后要重新标定，需要精确时间窗口时以 render_wave.py 画的 wave.png 为准。
set ZOOM_FIX 9.42

lassign $argv wdb out_dir signals cursor_us end_us start_us
if {$start_us eq ""} { set start_us 0 }
file mkdir $out_dir
open_wave_database $wdb

# 顶层 scope（带 generic 覆盖时名字形如 \tb(BASE_RAM_INIT_FILE="...") ），之后的信号路径都相对它写
foreach s [get_scopes /*] {
  if {[get_property NAME $s] ne "glbl"} { current_scope $s; break }
}

create_wave_config wave
set fd [open $signals]
foreach line [split [read $fd] "\n"] {
  set line [string trim $line]
  if {$line eq "" || [string index $line 0] eq "#"} continue
  if {[string range $line 0 1] eq "--"} {
    add_wave_divider [string trim [string range $line 2 end]]
    continue
  }
  set path [string map {. /} [lindex $line 0]]
  set radix hex
  foreach opt [lrange $line 1 end] {
    if {[string match radix=* $opt]} { set radix [string range $opt 6 end] }
  }
  # render_wave.py 的 dec/sdec 对应 Vivado 的 unsigned/dec
  set radix [string map {sdec dec dec unsigned} $radix]
  if {[catch {add_wave -radix $radix $path} err]} { puts "WAVE_GUI: skip $path ($err)" }
}
close $fd

set wcfg $out_dir/wave.wcfg
save_wave_config $wcfg
close_wave_config [current_wave_config]
set fd [open $wcfg]; set x [read $fd]; close $fd
# 系数作用在显示的长度上：ZoomEndTime = 起点 + 长度 / ZOOM_FIX
regsub {<ZoomStartTime time="[^"]*">} $x "<ZoomStartTime time=\"$start_us us\">" x
regsub {<ZoomEndTime time="[^"]*">} $x "<ZoomEndTime time=\"[expr {$start_us + ($end_us - $start_us) / $ZOOM_FIX}] us\">" x
regsub {<Cursor1Time time="[^"]*">} $x "<Cursor1Time time=\"$cursor_us us\">" x
set fd [open $wcfg w]; puts -nonewline $fd $x; close $fd
open_wave_config $wcfg

set fd [open $out_dir/.wave_gui_ready w]; close $fd
