# 5. 接入课程仓库（cod-tools 子模块）

`cod-tools` 只放**可复用**的 flow 工具和官方测例集成；`.xpr`、`srcs/`、约束、IP、
示例 RTL/testbench、`build/` 都不在这里。

## 5.1 作为子模块加入课程仓库

```bash
# 在课程仓库根目录
git submodule add ../cod-tools tools     # 或 git@...:group/cod-tools.git
git submodule update --init
cp tools/flow.env.example flow.env       # 再按需修改 REMOTE_HOST 等
```

`tools/` 必须在课程仓库里面：`remote.sh` 同步的是课程仓库根，服务器上的 Vivado 工程
和 `.xpr` 也来自课程仓库。

CI 拉子模块：`.gitlab-ci.yml` 里已经有

```yaml
variables:
  GIT_SUBMODULE_STRATEGY: recursive
```

如果 `cod-tools` 是私有仓库，CI runner 需要有读权限。

## 5.2 脚本的 cwd：REPO_ROOT

`tools/scripts/remote.sh` 和 `tools/scripts/server/*.sh` 不再用 `dirname $0/..` 猜仓库根：

- 本地 `remote.sh` 读 `REPO_ROOT`（不设时用当前目录），所有 `rsync ./`、`build/`、
  `.xpr` 都以它为准；
- 容器内 `server/*.sh` 用 `${REPO_ROOT:-/workspace}`，默认是 Docker 挂载点 `/workspace`。

由课程仓库的 Makefile 传入即可：

```make
TOOLS     := tools
REPO_ROOT := $(CURDIR)
```

## 5.3 课程仓库 Makefile 的参考写法

```make
TOOLS       := tools
REPO_ROOT   := $(CURDIR)
SRC         := thinpad_top.srcs/sources_1/new
SIMSRC      := thinpad_top.srcs/sim_1/new
VSIM        := sim/verilator                 # 本仓库的 lint.vlt（豁免是每个仓库自己的）
TOOLS_SIM   := $(TOOLS)/sim/verilator        # 通用 Verilator 模型

RTL         := ...
RTL_V       := $(RTL) $(TOOLS_SIM)/pll_example.sv
SIM_MODELS  := ... $(TOOLS_SIM)/sram_model.sv ...

lint:
	verilator ... $(VSIM)/lint.vlt $(RTL_V)

official:
	REPO_ROOT=$(CURDIR) $(PYTHON) $(TOOLS)/test/run_official.py

sim:
	REPO_ROOT=$(CURDIR) $(TOOLS)/scripts/remote.sh sim

bit:
	REPO_ROOT=$(CURDIR) $(TOOLS)/scripts/remote.sh bit

check:
	REPO_ROOT=$(CURDIR) $(TOOLS)/scripts/remote.sh check
```

`tools/test/tb_official_soc.sv` 和 `tb_monitor_soc.sv` 用 `$< $(RTL_V) $(SIM_MODELS)`
编译即可（它们是 SoC 级 testbench，不引用仓库里的 `.svh`）。

## 5.4 哪些留在课程仓库

- `thinpad_top.xpr`、`thinpad_top.srcs/`、约束、IP。
- `Makefile`（或至少 RTL 列表和顶层名）。
- `sim/lab5` 里依赖 CPU 内部层次（`cpu_top`、`u_reg_file`）的随机参考模型和 testbench。
- `sim/verilator/lint.vlt`：课程模板/第三方文件的 lint 豁免是每个仓库自己的。
- `flow.env`（本机服务器配置）。

## 5.5 官方测例

`tools/test/run_official.py`：

1. 从课程仓库的 `../testcases/basic/{1,2,3}.py` **只读**拷贝到 `build/official/`
   （官方脚本不做任何修改）；
2. 用脚本自带的 `Model/SPEC` 生成镜像和期望结果；
3. 在完整 `thinpad_top` 上直接跑用户程序（SoC 级，含两片 SRAM 和 UART）；
4. 对照结果表、串口输出、寄存器值。

官方测例目录可用 `TESTCASES=/path/to/testcases/basic` 覆盖；kernel 按脚本头部的
`oj.resources.kernel_bin` 下载到 `build/official/`。覆盖范围和限制见 `test/README.md`。
