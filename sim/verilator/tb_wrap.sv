`timescale 1ns / 1ps

// 仅供 Verilator 使用：把课程的 labN_tb 原样包一层，负责写 VCD。
// 课程 testbench 里没有 $dumpfile，又不想改它，所以在外面套一个顶层。
// LAB_TB 由 Makefile 传入（+define+LAB_TB=lab2_tb），VCD 路径用 +VCD_FILE=... 指定。
// 层次名是 tb_wrap.tb.dut.xxx，render_wave.py 按后缀匹配，信号清单写 dut.xxx 即可（与 xsim 共用）。
module tb_wrap;
  `LAB_TB tb ();

  initial begin
    string vcd_file;
    if (!$value$plusargs("VCD_FILE=%s", vcd_file)) vcd_file = "wave.vcd";
    $dumpfile(vcd_file);
    $dumpvars(0, tb_wrap);
  end
endmodule
