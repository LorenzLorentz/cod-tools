# 2. 本地编写与 Verilator 测试

本地的目标是**快**：改完代码 10 秒内知道有没有写错，确认没问题了再去服务器跑 Vivado。

## 2.1 环境

```bash
brew install verilator     # 需要 5.x（用到 --timing / --binary），本仓库在 5.048 上验证
pip install matplotlib     # 只有画波形图需要；帧图片 render_frame.py 只用标准库
```

Linux 上直接用发行版的包，或者从源码装 Verilator 5。

## 2.2 三类检查

```bash
make lint    # 静态检查整个顶层（和课程 CI 的 linter 参数一致）
make unit    # 单元测试：自检式 testbench，失败时 make 返回非零
make frame   # 整板仿真一帧 VGA，出 wave.png / frame.png
make test    # = lint + unit + frame
```

输出都放在 `build/verilator/`：

```
build/verilator/
├── tb_vga_timing/sim     单元测试可执行文件（源文件变了才重新编译）
├── tb_vga_pattern/sim
├── tb_vga_frame/sim
└── out/
    ├── wave.vcd  wave.png     开头 30us 的波形
    └── frame.hex frame.png    完整的一帧 800x600
```

### lint

```
verilator --lint-only --timing --timescale 1ns/1ps -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSED \
  --top-module thinpad_top sim/verilator/lint.vlt <RTL…> sim/verilator/pll_example.sv
```

- 参数取自课程 CI 的 `.ci-scripts/run-linter.py`，本地看到的警告和 CI 上一样。
- 课程模板本身带一批已知、无害的警告：`async.v` 的位宽警告、没用到的板载外设端口没驱动、FPGA 寄存器初值写法。
  这些都集中豁免在 [`sim/verilator/lint.vlt`](../sim/verilator/lint.vlt) 里，所以 `make lint` 在样例上是干净的，
  **自己新写的代码一出警告就能看到**。不要往 `lint.vlt` 里加自己代码的豁免，应该改代码。
- `--timescale 1ns/1ps`：`thinpad_top.sv` 没写 `` `timescale ``，其他文件写了，不给默认值 Verilator 会报 TIMESCALEMOD。

### 单元测试

[`sim/verilator/tb_vga_timing.sv`](../sim/verilator/tb_vga_timing.sv) 跑 2.2 帧，逐周期检查：

- 行周期 1040、hsync 宽 120，每行 de 为 800 个像素
- 帧周期 1040×666，vsync 宽 6 行，每帧 600 个有效行
- 输出里没有 X/Z

[`sim/verilator/tb_vga_pattern.sv`](../sim/verilator/tb_vga_pattern.sv) 在 4 种模式下抽查 32 个坐标的颜色。

写法约定：失败时打印 `FAIL …`，最后 `$fatal`（退出码非零），全过打印 `PASS …` 再 `$finish`。
新增测试只需要在 Makefile 里加两行：

```make
UNIT_TESTS          := tb_vga_timing tb_vga_pattern tb_my_alu
tb_my_alu_SRCS      := $(VSIM)/tb_my_alu.sv $(SRC)/my_alu.sv
```

### 整帧仿真

[`thinpad_top.srcs/sim_1/new/tb_vga_frame.sv`](../thinpad_top.srcs/sim_1/new/tb_vga_frame.sv) 是**和 xsim 共用的同一个 testbench**。
它例化整个 `thinpad_top`，挂一个“虚拟显示器”[`vga_capture`](../thinpad_top.srcs/sim_1/new/vga_capture.sv)，
抓满一帧就写文件并 `$finish`。

Verilator 不认 `$dumpoff`，所以 `make frame` 跑两次，每次不到 1 秒：

```bash
sim +MODE=0 +FRAME_FILE=/dev/null +VCD +VCD_FILE=out/wave.vcd +STOP_US=30   # 只要波形
sim +MODE=0 +FRAME_FILE=out/frame.hex                                         # 只要画面
```

testbench 支持的 plusargs：

| plusarg | 作用 |
| --- | --- |
| `+MODE=<n>` | `dip_sw` 初值，`dip_sw[1:0]` 选图案 |
| `+FRAME_FILE=<path>` | 帧文件输出路径 |
| `+VCD`、`+VCD_FILE=<path>` | 用 `$dumpvars` 写 VCD（xsim 那边由 Tcl 写 VCD，不用这个） |
| `+STOP_US=<n>` | n 微秒后结束仿真 |

## 2.3 Vivado IP 在 Verilator 里怎么办

`thinpad_top` 例化了 Vivado 的 PLL IP `pll_example`（clk_wiz）。Verilator 没有这个 IP 的模型，所以
[`sim/verilator/pll_example.sv`](../sim/verilator/pll_example.sv) 写了一个**端口一致的行为模型**：输出 10 MHz / 20 MHz，
复位释放 64 个周期后拉高 `locked`。

- 这个文件**只给 Verilator 用**，不在 Vivado 工程里。综合和 xsim 用的都是 IP 核生成的真实 MMCM 模型。
- 所以两边的时钟细节会不一样。对比 [xsim 波形](images/wave_xsim.png) 和 [Verilator 波形](images/wave_verilator.png)：
  xsim 里复位期间 `clk_10M` 停振，约 1.7 µs 才 locked；Verilator 模型里时钟一直在跑。
  **跨时钟域、复位时序这类问题要以 xsim 为准。**
- 以后用到其他 IP（例如 BRAM），可以同样写行为模型放在 `sim/verilator/`，并加进 `RTL_VERILATOR`。

## 2.4 Verilator 和 xsim 的差异（本仓库踩过的坑）

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| Verilator 正常，xsim 20 ms 后看门狗报 `timeout, no complete frame captured`（实测） | 课程模板 `vga.v` 的 `hdata/vdata` 没有初值；Verilator 默认初始化为 0，xsim 里是 X，`X+1` 还是 X，`de` 一直是 X，一行也抓不到 | `vga.v` 里加了 `initial hdata = 0; vdata = 0;`（FPGA 上综合成寄存器 INIT 值，行为和上电一致） |
| 第一行少一个像素 | 在时钟**下降沿**采样会错过第一个上升沿之前的 (0,0) | `vga_capture` 和时序测试都在**上升沿**采样：DUT 用非阻塞赋值，上升沿读到的是本周期的值 |
| `$dumpoff` 在 Verilator 里没效果，VCD 有 90 MB | Verilator 运行时不支持 `$dumpoff` | 加了 `+STOP_US`，波形和画面分两次跑 |
| `checker` 做函数名报语法错 | `checker` 是 SystemVerilog 关键字 | 改名 |
| `.vlt` 文件第二行莫名报语法错 | 以 `// verilator lint…` 开头的注释会被当成指令 | 注释别用 `verilator` 开头 |

两边最后抓到的帧**逐像素一致**（`make compare`）。所以 Verilator 适合日常快速迭代，xsim 用来做最终确认。
