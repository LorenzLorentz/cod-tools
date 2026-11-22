`timescale 1ns / 1ps

// 仅供 Verilator 使用：代替课程的 thinpad_top.srcs/sim_1/new/sram_model.v（异步 SRAM，16 位，LB_n / UB_n 字节使能）。
// 课程模型靠 always #1 轮询和 $time 差值判断时序，在 Verilator 里读数据要到下一个时钟沿之后才出现
// （xsim 里是地址给出后约 10ns），会让正确的 SRAM 控制器读错，所以本地换成这个行为模型；服务器上的 xsim 仍用课程模型。
// 端口和内部数组名（mem_array0 = DataIO[7:0]，mem_array1 = DataIO[15:8]）与课程模型相同，testbench 可以直接读写。
//   读：CE_n=0、OE_n=0、WE_n=1 时按字节使能输出，没有延迟
//   写：CE_n、WE_n 同时为低的期间是写脉冲，脉冲结束时按脉冲结束前一刻的地址、数据、字节使能写入
//       （和数据手册一样，地址、数据要保持到脉冲结束）
module sram_model (
    input  wire [19:0] Address,
    inout  wire [15:0] DataIO,
    input  wire        OE_n,
    input  wire        CE_n,
    input  wire        WE_n,
    input  wire        LB_n,
    input  wire        UB_n
);

  reg [7:0] mem_array0[1048575:0];
  reg [15:8] mem_array1[1048575:0];

  wire rd = !CE_n && !OE_n && WE_n;
  assign DataIO[7:0]  = (rd && !LB_n) ? mem_array0[Address] : 8'bz;
  assign DataIO[15:8] = (rd && !UB_n) ? mem_array1[Address] : 8'bz;

  wire wr = !CE_n && !WE_n;
  reg [19:0] wr_addr;
  reg [15:0] wr_data;
  reg wr_lb, wr_ub;

  // 脉冲期间一直跟着总线走；wr 是组合信号，结束的那个时刻这里已经看到 wr=0，不会记下变化后的值
  always @(*)
    if (wr) begin
      wr_addr = Address;
      wr_data = DataIO;
      wr_lb   = !LB_n;
      wr_ub   = !UB_n;
    end

  always @(negedge wr) begin
    if (wr_lb) mem_array0[wr_addr] = wr_data[7:0];
    if (wr_ub) mem_array1[wr_addr] = wr_data[15:8];
  end

endmodule
