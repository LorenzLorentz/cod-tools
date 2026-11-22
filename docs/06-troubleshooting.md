# 6. 常见问题

### `make check` 显示 `vivado-flow:2024.2 MISSING`

这台服务器还没构建扩展镜像，先 `make image`（约 1 分钟）。如果连 `vivado:2024.2` 也缺，先按
[第 1 章 1.3 节](01-server-image.md#13-在其他服务器上-load-镜像) load 基础镜像。

### `[XSIM 43-3388] /usr/bin/gcc not found`

用的是基础镜像 `vivado:2024.2`，它不能做 xsim 仿真。换成 `vivado-flow:2024.2`（`IMAGE` 变量，默认就是它）。

### `Module <pll_example> not found`

IP 核没有生成仿真模型。`sim.tcl` 会自动 `generate_target simulation`。如果你手写 Tcl，记得加上这一步。

### 仿真跑不完 / 一直卡住

testbench 没有 `$finish`，课程自带的 tb 都是这样。设 `SIM_TIME=100us` 这类上限。
样例的 `tb_vga_frame` 有 20 ms 看门狗。

### 画面全是品红，或者看门狗超时

像素是 X：多半是寄存器没有初值（xsim 默认 X，Verilator 默认 0）。给计数器加 `initial` 初值或复位逻辑。
`render_frame.py` 遇到 X 像素时以退出码 2 结束。

### `SIM_TOP=… 不在 sim_1 里`

顶层名写错，或者这个 testbench 文件没加进工程的 `sim_1` fileset。在 GUI 里 Add Sources 加进去，
或者直接编辑 `.xpr`，照着现有的 `<File Path=…>` 条目添加。

### `VCD_SCOPES 没有匹配到任何信号`

`VCD_SCOPES` 写的是相对顶层的路径（默认 `* dut/*`），或者以 `/` 开头的绝对路径。
可以先 `make shell` 进容器手动 `launch_simulation`，再用 `get_scopes` / `get_objects` 查一下名字。

### 波形图里某些信号没画出来

看 `render_wave: WARNING no signal matches …`：

- 用 `python3 scripts/render_wave.py build/sim/wave.vcd --list` 列出 VCD 里实际有哪些信号。
- 更深层的信号要先加进 `VCD_SCOPES`，才会出现在 VCD 里。

### Ctrl-C 之后服务器上还在跑吗

`remote.sh` 会捕获 Ctrl-C，然后 `docker rm -f` 掉这次的容器（容器名形如 `vflow-sim-<时间>-<pid>`）。
不放心的话，在服务器上 `docker ps` 看一下。

### 服务器上生成的文件是 root 所有，删不掉

`docker run` 时没传 `-e REUID=$(id -u) -e REGID=$(id -g)`，`remote.sh` 默认会传。已经是 root 所有的文件，
可以在容器里以 root 删掉：`docker run --rm -v $PWD:/w vivado:2024.2 rm -rf /w/<目录>`。

### 想要全新环境重来

删掉服务器上的 `~/vivado-flow/<repo>/sim`（或 `bit`）。下次 `make sim` / `make bit` 会重新同步并重新生成所有东西。

### macOS 上 `make` 的注意点

macOS 自带 GNU Make 3.81，不认 `.SHELLFLAGS`。Makefile 里用到管道的规则都显式写了 `set -o pipefail`，
测试失败时 make 一定会返回非零。`remote.sh` 兼容 macOS 自带的 bash 3.2。

### 不在校园网

`make image` 默认用清华 apt 源，校外可以用 `APT_MIRROR=archive.ubuntu.com make image`。
SSH 连接走 `~/.ssh/config`（例如 cluster39 经过 cluster0 跳板），和这套脚本无关。
