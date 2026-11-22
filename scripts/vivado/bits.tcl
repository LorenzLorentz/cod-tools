# 工程模式生成 bitstream：流程与课程 CI（.ci-scripts/bits.tcl）一致，结束后导出比特流和报告。
#
# 用法（容器内、仓库根目录）：
#   vivado -mode batch -nojournal -source scripts/vivado/bits.tcl -tclargs <out_dir>
#
# 环境变量：
#   PROJECT   工程文件，默认 thinpad_top.xpr
#   TOP       综合顶层（例如 lab2_top），默认用工程里 sources_1 设置的 top
#   JOBS      launch_runs 的并行数，默认 4

proc env_or {name default} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $default
}

set out_dir [file normalize [lindex $argv 0]]
file mkdir $out_dir
set jobs [env_or JOBS 4]

open_project [env_or PROJECT thinpad_top.xpr]
set top [env_or TOP ""]
if {$top ne ""} {
  set_property top $top [get_filesets sources_1]
}
update_compile_order -fileset sources_1
# 顶层名写错、或者顶层用到的文件没加进工程时，Vivado 会悄悄换一个顶层，这里直接报错
if {$top ne "" && [get_property top [get_filesets sources_1]] ne $top} {
  puts "ERROR: TOP=$top 不在 sources_1 里（Vivado 自动换成了 [get_property top [get_filesets sources_1]]）"
  exit 1
}

# 有 IP 核时先把 IP 的综合 run 跑掉（和课程 CI 相同）
if {[llength [get_ips]] != 0} {
  upgrade_ip [get_ips]
  foreach ip [get_ips] {
    create_ip_run [get_ips $ip]
  }
  set ip_runs [get_runs -filter {SRCSET != sources_1 && IS_SYNTHESIS && NEEDS_REFRESH}]
  if {[llength $ip_runs] != 0} {
    launch_runs -quiet -jobs $jobs {*}$ip_runs
    foreach r $ip_runs {
      wait_on_run $r
    }
  }
}

set t0 [clock seconds]
reset_run synth_1
launch_runs -jobs $jobs impl_1 -to_step write_bitstream
wait_on_run impl_1

set impl [get_runs impl_1]
if {[get_property PROGRESS $impl] ne "100%" || [string match "*ERROR*" [get_property STATUS $impl]]} {
  puts "BIT: impl_1 failed: [get_property STATUS $impl]"
  puts "BIT: see [get_property DIRECTORY $impl]/runme.log and [get_property DIRECTORY [get_runs synth_1]]/runme.log"
  exit 1
}

open_run impl_1
report_timing_summary -file $out_dir/timing_summary.rpt
report_utilization -file $out_dir/utilization.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]

set top [get_property top [get_filesets sources_1]]
set bit [get_property DIRECTORY $impl]/$top.bit
file copy -force $bit $out_dir/
foreach r {synth_1 impl_1} {
  file copy -force [get_property DIRECTORY [get_runs $r]]/runme.log $out_dir/$r.runme.log
}
puts "BIT: $out_dir/$top.bit  WNS=$wns ns  build [expr {[clock seconds] - $t0}] s"
