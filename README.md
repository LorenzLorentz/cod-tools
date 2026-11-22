# cod-tools

课程（thinpad / cod26）的**可复用**工具与官方测例本地集成。具体工程的 RTL、`.xpr`、
约束、IP、示例 design 不在这里——它们在各自的课程仓库里。

## 内容

```
docker/Dockerfile          Vivado 2024.2 + gcc + matplotlib + imagemagick 镜像
scripts/                   remote.sh（本地↔服务器）、xpr.py、render_*.py、vivado/、server/
sim/verilator/             Verilator 用的通用模型：pll_example.sv、sram_model.sv、tb_wrap.sv
test/                      官方测例 runner + SoC 级 testbench（tb_official_soc / tb_monitor_soc）
flow.env.example           服务器配置模板
docs/                      flow 文档（05-porting.md 为本仓库的接入说明）
```

不包含：`thinpad_top.xpr`、`thinpad_top.srcs/`、约束、IP、示例 RTL、示例 testbench、
`build/`。这些属于课程仓库或 `vivado-flow-demo` 示例。

## 接入课程仓库（推荐：submodule）

```bash
# 课程仓库根目录
git submodule add ../cod-tools tools      # 或 git@...:group/cod-tools.git
git submodule update --init
cp tools/flow.env.example flow.env        # 再按需修改
```

`tools/` 必须在课程仓库里面：`remote.sh` 同步的是课程仓库根（`REPO_ROOT`），服务器上的
Vivado 工程和 `.xpr` 也来自课程仓库。

`remote.sh` 不再用 `dirname $0/..` 猜仓库根；它读 `REPO_ROOT`（不设时用当前目录），
由课程的 Makefile 传入：

```make
TOOLS     := tools
REPO_ROOT := $(CURDIR)
...
official:
	REPO_ROOT=$(CURDIR) $(PYTHON) $(TOOLS)/test/run_official.py
bit:
	REPO_ROOT=$(CURDIR) $(TOOLS)/scripts/remote.sh bit
```

课程 Makefile 里的 Verilator 模型也直接引用 tools：

```make
RTL_V      := $(RTL) $(TOOLS)/sim/verilator/pll_example.sv
SIM_MODELS := ... $(TOOLS)/sim/verilator/sram_model.sv ...
```

## 官方测例

`tools/test/run_official.py` 会把课程 `../testcases/basic/{1,2,3}.py` **只读**拷到
课程仓库的 `build/official/`，生成镜像/期望结果，再在完整 SoC 上直接跑用户程序。
官方脚本本身不做任何修改；kernel 按脚本头部的 URL 下载。详见 `test/README.md`。

## 分工

- **通用**：`docker/`、`scripts/`、`sim/verilator/{pll_example,sram_model,tb_wrap}.sv`、
  `test/` 的官方 runner 与 SoC 级 testbench、`flow.env.example`。
- **每个课程仓库自己**：`Makefile`、RTL 列表、`sim/lab5` 里依赖 CPU 内部层次
  （`cpu_top`、`u_reg_file`）的随机参考模型/testbench、`sim/verilator/lint.vlt` 的豁免。
