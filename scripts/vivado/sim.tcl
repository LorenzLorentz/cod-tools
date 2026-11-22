# 工程模式行为仿真：读取工程的 sim_1 fileset，用 xsim 跑仿真，
# 同时导出 VCD（给 scripts/render_wave.py 画图）和 WDB（Vivado 波形数据库，可以在 GUI 里打开）。
#
# 用法（容器内、仓库根目录）：
#   vivado -mode batch -nojournal -source scripts/vivado/sim.tcl -tclargs <out_dir>
#
# 环境变量（都可以不设）：
#   PROJECT     工程文件，默认 thinpad_top.xpr
#   SIM_TOP     仿真顶层，默认用工程里 sim_1 设置的 top
#   SIM_TIME    总仿真时长，默认 all（跑到 $finish）
#   VCD_SCOPES  写进 VCD 的对象，空格分隔的 xsim 路径通配（相对顶层，或以 / 开头的绝对路径），默认 "* dut/*"
#   VCD_TIME    只把开头这么长写进 VCD，默认 30us；0 表示整段都写
#   PLUSARGS    传给仿真的 plusargs，空格分隔、不带 +，例如 "MODE=3 FRAME_FILE=/workspace/build/sim/frame.hex"
#   GENERICS    覆盖仿真顶层的 parameter，例如 'BASE_RAM_INIT_FILE="/workspace/kernel.bin"'

proc env_or {name default} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $default
}

set out_dir [file normalize [lindex $argv 0]]
file mkdir $out_dir

open_project [env_or PROJECT thinpad_top.xpr]
set fs [get_filesets sim_1]
set top [env_or SIM_TOP [get_property top $fs]]
set_property top $top $fs
set_property top_lib xil_defaultlib $fs
update_compile_order -fileset sim_1
# 工程是自动层次模式：顶层名写错时 Vivado 只报 CRITICAL WARNING 并悄悄换一个顶层，这里直接报错
if {[get_property top $fs] ne $top} {
  puts "ERROR: SIM_TOP=$top 不在 sim_1 里（Vivado 自动换成了 [get_property top $fs]）"
  exit 1
}

# 新 clone 的工程里 IP 核（pll_example）还没有生成仿真模型，GUI 会自动补，batch 模式要手动生成
if {[llength [get_ips]] != 0} {
  upgrade_ip [get_ips]
  generate_target simulation [get_ips]
  export_ip_user_files -of_objects [get_ips] -no_script -sync -force -quiet
}

# 以下 set_property 会被 Vivado 存回（服务器工作副本里的）.xpr，所以每次都无条件设置，避免沿用上一次的值。
# 覆盖仿真顶层的 parameter（例如课程 tb.sv 里的 BASE_RAM_INIT_FILE），对应 GUI 里 Simulation Settings 的 Generics
set_property generic [env_or GENERICS ""] $fs

set opts {}
foreach p [env_or PLUSARGS ""] { lappend opts -testplusarg $p }
set_property -name {xsim.simulate.xsim.more_options} -value [join $opts " "] -objects $fs
# runtime 设成 0，launch_simulation 只编译 + 细化，之后由本脚本控制 run
set_property -name {xsim.simulate.runtime} -value {0ns} -objects $fs
set_property -name {xsim.simulate.log_all_signals} -value {false} -objects $fs

puts "SIM: top=$top plusargs=[env_or PLUSARGS {}]"
launch_simulation -simset sim_1 -mode behavioral

# 顶层 scope 的真实名字：带 GENERICS 时 xsim 会把它叫成 /\tb(BASE_RAM_INIT_FILE="...") ，不能直接拼 /$top
foreach s [get_scopes /*] {
  if {[get_property NAME $s] ne "glbl"} { current_scope $s; break }
}

# 选出要记录的信号（只要线网/寄存器/端口，不要参数、常量、string 等；SV 的 logic 在 xsim 里是 reg）。
# 默认是顶层和 dut 两层，相对当前 scope 写；VCD_SCOPES 里可以写绝对路径
set scopes [env_or VCD_SCOPES "* dut/*"]
set objs {}
foreach pattern $scopes {
  foreach o [get_objects -quiet $pattern] {
    if {[get_property TYPE $o] in {signal internal_signal reg port in_port out_port inout_port}} {
      lappend objs $o
    }
  }
}
puts "SIM: logging [llength $objs] objects from '$scopes' (scope [current_scope])"
if {[llength $objs] == 0} {
  puts "ERROR: VCD_SCOPES 没有匹配到任何信号: $scopes"
  exit 1
}

# WDB：波形数据库，会写在 <工程>.sim/sim_1/behav/xsim/<top>_behav.wdb
log_wave $objs

# VCD：只记开头一段，避免一整帧的时钟翻转把文件撑到几百 MB
open_vcd $out_dir/wave.vcd
log_vcd $objs
set vcd_time [env_or VCD_TIME 30us]
set vcd_open 1
if {$vcd_time ne "0"} {
  run $vcd_time
  close_vcd
  set vcd_open 0
}

set t0 [clock milliseconds]
set sim_time [env_or SIM_TIME all]
if {$sim_time eq "all"} { run -all } else { run $sim_time }
if {$vcd_open} { close_vcd }
puts "SIM: stopped at [current_time], wall [expr {([clock milliseconds] - $t0) / 1000.0}] s"

set sim_dir [get_property DIRECTORY [current_project]]/[current_project].sim/sim_1/behav/xsim
close_sim
foreach f [list $sim_dir/${top}_behav.wdb $sim_dir/simulate.log $sim_dir/elaborate.log $sim_dir/compile.log] {
  if {[file exists $f]} { file copy -force $f $out_dir/ }
}
puts "SIM: outputs in $out_dir"
