`timescale 1ns / 1ps

// 仅供 Verilator 使用的 pll_example 行为模型。
// Vivado（综合 / xsim）用的是 IP 核生成的 MMCM，不会读这个文件。
// 端口和频率与 thinpad_top.srcs/sources_1/ip/pll_example/pll_example.xci 保持一致：
//   clk_in1 = 50MHz, clk_out1 = 10MHz, clk_out2 = 20MHz
module pll_example (
    input  wire clk_in1,
    output reg  clk_out1,
    output reg  clk_out2,
    input  wire reset,
    output reg  locked
);

  initial begin
    clk_out1 = 1'b0;
    clk_out2 = 1'b0;
    locked   = 1'b0;
  end

  always #50 clk_out1 = ~clk_out1;
  always #25 clk_out2 = ~clk_out2;

  // 复位释放后等 64 个输入时钟再报 locked，粗略模拟真实 MMCM 的锁定延迟
  logic [6:0] lock_cnt = '0;
  always @(posedge clk_in1) begin
    if (reset) begin
      lock_cnt <= '0;
      locked   <= 1'b0;
    end else if (!lock_cnt[6]) begin
      lock_cnt <= lock_cnt + 7'd1;
    end else begin
      locked <= 1'b1;
    end
  end

endmodule
