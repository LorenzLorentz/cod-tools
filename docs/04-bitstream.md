# 4. 服务器编译 bitstream

```bash
make bit                 # → build/bit/thinpad_top.bit
JOBS=8 make bit          # launch_runs 并行数（默认 4）
TOP=lab2_top make bit    # 临时换综合顶层（默认用工程里设置的 top）
BIT_OUT=build/bit-v2 make bit   # 换一个结果目录（build/ 下），不覆盖上一次的 bitstream
```

## 4.1 流程

`scripts/remote.sh bit` 把代码同步到 `~/vivado-flow/<repo>/bit/`，然后在容器里执行
[`scripts/server/bit.sh`](../scripts/server/bit.sh)，也就是 `vivado -mode batch -source` [`scripts/vivado/bits.tcl`](../scripts/vivado/bits.tcl)。

`bits.tcl` 和课程 CI 的 `.ci-scripts/bits.tcl` 步骤相同：

1. `open_project thinpad_top.xpr`，`update_compile_order`
2. 有 IP 核时：`upgrade_ip` → `create_ip_run` → 先跑 IP 的 out-of-context 综合（例如 `pll_example_synth_1`）
3. `reset_run synth_1` → `launch_runs impl_1 -to_step write_bitstream` → `wait_on_run impl_1`

在 CI 的基础上加了几步：

- **检查结果**：`impl_1` 没跑到 100%，或者状态里有 ERROR，就打印 runme.log 的位置并返回退出码 1。`make bit` 会失败，日志照样拉回来。
- **导出报告**：`report_timing_summary`、`report_utilization`，并打印最差建立时间裕量 WNS。
- **收集产物**：`.bit`、两个 run 的 `runme.log` 拷到 `build/bit/`，再算一个 sha256。

```
build/bit/
├── thinpad_top.bit        比特流
├── timing_summary.rpt     时序（先看 WNS/WHS 是否 ≥ 0）
├── utilization.rpt        资源占用
├── synth_1.runme.log      综合日志
├── impl_1.runme.log       实现 + bitgen 日志
└── vivado.log             外层 batch 日志
```

## 4.2 实测

样例工程在 cluster39 上：

```
BIT: /workspace/build/bit/thinpad_top.bit  WNS=15.942 ns  build 185 s
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)  ...
     15.942        0.000                      0                  275        0.172  ...
```

- `make bit` 全程约 3 min 40 s。其中 Vivado 185 s，其余是同步和容器启动。
- 0 error、0 critical warning。
- 资源：198 LUT、157 个寄存器。
- `.bit` 文件头：design `thinpad_top`、part `7a100tfgg676`、Vivado 2024.2.2，和工程的 `xc7a100tfgg676-2L` 一致。
- 课程原版模板（未修改）用同一个镜像编译，耗时 4 min 03 s，同样成功。

> utilization 里 `MMCME2_ADV` 是 0：模板里 PLL 的输出 `clk_10M` 没有驱动任何逻辑（`Your Code` 那段是空的），
> 所以 Vivado 把 PLL 整个优化掉了。这是模板本身的行为。等你在 `clk_10M` 时钟域里写了逻辑，MMCM 就会保留。

## 4.3 看结果

1. **先看时序**：`timing_summary.rpt` 里 `WNS`、`WHS` 都 ≥ 0，才说明满足约束。负数表示上板可能出错，
   要么改逻辑，要么降频（例如改用 PLL 的 10 MHz 输出）。
2. **再看 critical warning**：`grep "CRITICAL WARNING" build/bit/*.runme.log`。常见的是约束文件里的引脚在设计里不存在。
3. **上板**：按课程要求把 `build/bit/thinpad_top.bit` 上传到实验平台，或者在接了板子的电脑上用 Vivado Hardware Manager 烧写。

## 4.4 增量与并行

- 每次都 `reset_run synth_1`，所以是完整重新编译，和 CI 一致，避免“本地能过、CI 不过”。
- IP 的综合 run 只在 `NEEDS_REFRESH` 时才重跑，第二次以后会快一些。
- `bit` 和 `sim` 在服务器上是两个独立的工作副本，`make sim` 和 `make bit` 可以同时在两个终端里跑。
- 线程数：`VIVADO_MAX_THREADS`（默认 8）控制单个 Vivado 进程，`JOBS`（默认 4）控制 `launch_runs` 的并行 run 数。
  cluster39 是共享服务器，请不要一直开到最大。
