# 官方测例本地集成

在课程仓库根目录运行 `python3 tools/test/run_official.py`（或 `make official`）。它会：

1. 把课程 `../testcases/basic/{1,2,3}.py` **只读**拷到课程仓库的 `build/official/`（官方脚本不做任何修改）；
2. 从脚本自带的 `Model/SPEC` 生成内存镜像和期望结果（`build/official/*.hex|txt`）；
3. 用 `tools/test/tb_official_soc.sv` 在完整 `thinpad_top`（CPU + 总线 + 两片 SRAM + UART）上
   直接跑每个测例的用户程序；
4. 对照脚本给出的结果表、串口输出、寄存器值，报告每项 PASS/FAIL。

课程仓库根由 `REPO_ROOT` 指定（`make official` 会设为 `$(CURDIR)`）；直接运行时默认
`tools/` 的上一级。官方测例目录可用 `TESTCASES=/path/to/testcases/basic` 覆盖。

覆盖范围：

| 测例 | 覆盖 |
| --- | --- |
| 基础（1.py） | G/R/D2：程序执行、7 个寄存器、0x80400100 的 448 个结果字 |
| A01-A20 | 全部 20 项（指令、冒险、控制冒险、随机序列） |
| B04/B06/B09-B17 | 只含 run/tab 步骤、可以绕过监控程序直接跑的 11 项 |
| 监控程序冒烟 | 真实 kernel 的 boot message / W / D / G / D |

不覆盖：需要监控程序复位、A/T/R 命令、串口收发交互的 B01-B03/B05/B07/B08/B18-B20，
以及基础测例的启动信息/W/A/D 回读部分。

testbench 按监控程序 G 命令的初始状态启动程序：`sp=fp=0x807F0000`、`ra=0x80000298`、
`s10=entry`、其余寄存器 0；用一串 JAL（不写寄存器）跳到 entry，用返回桩检测程序返回。
每个程序还会和官方 `run` 步骤的毫秒超时比较（10 MHz，1 ms = 10000 周期）。
