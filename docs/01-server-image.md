# 1. 服务器与 Vivado 镜像

## 1.1 cluster39 上现有的东西（2026-09-24 核对）

| 项目 | 状态 |
| --- | --- |
| 系统 | Ubuntu 20.04，256 核，503 GB 内存 |
| Docker | 28.0.4，数据目录 `/villa/docker`（`/villa` 剩余约 7 TB）；用户 `wpj24-srt` 在 `docker` 组，不需要 sudo |
| 基础镜像 | `vivado:2024.2`（同一个镜像还有 tag `vivado:2024.2.2-noble`），ID `dcf286ca84e7`，154 GB |
| 镜像内容 | Ubuntu 24.04 + **Vivado v2024.2.2**（`/opt/Xilinx/Vivado/2024.2`，含 Artix-7 等器件库），入口 `tini → vivado-entrypoint` |
| 落盘的镜像文件 | `/villa/wpj24-srt/vivado-export/vivado-2024.2.2-ubuntu-noble-linux-amd64.tar.gz.local`（115,563,375,202 字节 ≈ 108 GiB）+ 同名 `.sha256` |
| 另一份未压缩副本 | `/villa/wpj24-srt/vivado-export/docker-export-snapshot/`（OCI 目录格式，root 所有，154 GB） |
| 本仓库新增 | `vivado-flow:2024.2` = 基础镜像 + gcc + matplotlib + imagemagick（多一层约 580 MB，见 1.4） |

### 镜像的入口脚本做了什么

`vivado-entrypoint` 会 `source settings64.sh`、`ulimit -s unlimited`，并支持两个环境变量：

- `REUID` / `REGID`：以 root 启动后切换成这个 uid/gid 运行命令。**一定要传**（`-e REUID=$(id -u) -e REGID=$(id -g)`），
  否则容器里生成的文件（工程目录、`.bit`）都是 root 所有，宿主机上删不掉。
- `VIVADO_MAX_THREADS`：Vivado 单进程线程数，默认 32（Vivado 上限就是 32）。本仓库默认用 8，免得挤占共享服务器。

最简单的手动用法：

```bash
docker run --rm -it -e REUID=$(id -u) -e REGID=$(id -g) \
  -v "$PWD":/workspace -w /workspace vivado:2024.2 vivado -version
```

## 1.2 验证结果

| 检查 | 方法 | 结果 |
| --- | --- | --- |
| Vivado 能运行 | 容器内 `vivado -version` | `vivado v2024.2.2 (64-bit)`，6.8 s 启动 |
| 能编译 bitstream | 用课程原版模板跑 CI 同款 `bits.tcl` | 4 min 03 s 生成 `thinpad_top.bit`，0 error / 0 critical warning |
| 镜像文件完整 | `sha256sum` | 与 `.sha256` 记录一致：`7ab2d34fbdad6ab070c2ebc214e9bed649d6e22e738c207e5e8b8cb8144db0ce` |
| 压缩包结构完整 | `pigz -dc … \| tar -tv` | 能完整解压；是标准 `docker save` 格式：`manifest.json` + `index.json` + 6 个 layer，config digest 就是 `dcf286ca84e7` |
| 能 `docker load` | `pigz -dc … \| docker load` | `Loaded image: vivado:2024.2.2-noble`，退出码 0，耗时 14 min |
| xsim 行为仿真 | 本仓库 `make sim` | **基础镜像不行**：xelab 报 `[XSIM 43-3388] /usr/bin/gcc not found`。加了 gcc 的 `vivado-flow` 镜像可以 |

校验日志留在 cluster39 的 `~/vivado-export/verify/`。

> **xsim 为什么要 gcc**：xelab 会把设计编译成本地代码再链接成仿真程序。Vivado 自带 gcc 9.3，
> 但仍要求系统里有 `/usr/bin/gcc` 和 libc 开发文件。基础镜像只装了 GUI / 综合需要的运行库，
> 所以综合、实现、bitgen 都正常，只有仿真在 elaborate 这一步失败。

## 1.3 在其他服务器上 load 镜像

前提：目标服务器能跑 docker（在 `docker` 组里）、x86_64，Docker 数据目录下至少有 **160 GB** 空闲
（`docker info --format '{{.DockerRootDir}}'` 查看位置，再 `df -h` 这个目录）。

压缩包里的 tag 是 `vivado:2024.2.2-noble`。load 完以后再打一个 `vivado:2024.2` 的 tag，脚本默认用这个名字。

### 方式 A：边传边 load（推荐，目标机不用多留 108 GB 放压缩包）

在**目标服务器**上执行，前提是它能 `ssh cluster39`：

```bash
F=/villa/wpj24-srt/vivado-export/vivado-2024.2.2-ubuntu-noble-linux-amd64.tar.gz.local
ssh cluster39 cat "$F" \
  | tee >(sha256sum > vivado.sha256.got) \
  | pigz -dc | docker load
docker tag vivado:2024.2.2-noble vivado:2024.2
cat vivado.sha256.got     # 应为 7ab2d34fbdad6ab070c2ebc214e9bed649d6e22e738c207e5e8b8cb8144db0ce
```

没有 `pigz` 就换成 `gzip -dc`（单线程，慢一些）。

### 方式 B：先拷文件再 load

```bash
rsync -P cluster39:/villa/wpj24-srt/vivado-export/vivado-2024.2.2-ubuntu-noble-linux-amd64.tar.gz.local /some/big/disk/
cd /some/big/disk
sha256sum vivado-2024.2.2-ubuntu-noble-linux-amd64.tar.gz.local   # 与上面的值比较
pigz -dc vivado-2024.2.2-ubuntu-noble-linux-amd64.tar.gz.local | docker load
docker tag vivado:2024.2.2-noble vivado:2024.2
```

`docker load -i xxx.tar.gz` 也能直接读 gzip，但它是单线程解压。在 cluster39 上 `pigz -dc | docker load` 用了 14 分钟。

> `.sha256` 文件里写的是 cluster39 上的绝对路径，换了目录后 `sha256sum -c` 会找不到文件，所以上面直接比较哈希值。

### 方式 C：放到共享存储

cluster39 挂载了 NAS `/DATA/DATANAS1`（NFS，剩余约 13 TB，可写）。如果其他节点也挂了同一个 NAS，可以把压缩包拷一份过去，
各节点直接 `pigz -dc /DATA/DATANAS1/…/vivado-…tar.gz.local | docker load`。放上去之前请先确认共享盘的使用规定。

### load 之后：构建 vivado-flow 镜像并验证

在本地仓库里把 `REMOTE_HOST` 指向新服务器：

```bash
REMOTE_HOST=cluster40 make check    # 应显示 image ok vivado:2024.2，vivado-flow 为 MISSING
REMOTE_HOST=cluster40 make image    # 约 1 分钟（走清华 apt 源）
REMOTE_HOST=cluster40 make sim bit  # 端到端验证
```

也可以直接写进 `flow.env`：`REMOTE_HOST=${REMOTE_HOST:-cluster40}`。

## 1.4 vivado-flow 镜像

[`docker/Dockerfile`](../docker/Dockerfile) 在基础镜像上只加一层：

| 包 | 用途 |
| --- | --- |
| `gcc g++ libc6-dev` | xsim 的 elaborate 必需（见 1.2） |
| `python3-matplotlib python3-numpy fonts-dejavu-core` | `render_wave.py` 在服务器上把 VCD 画成 PNG |
| `imagemagick` | `make wave-gui` 给 Xvfb 里的 Vivado 窗口截图 |

- 基础镜像不做任何修改。`ENTRYPOINT`、`ENV`、`REUID`/`REGID` 机制都继承下来。
- 这一层只有约 580 MB，每台服务器上本地 `make image` 就行，不用再导出一个 155 GB 的压缩包。
- 校外网络可以用 `APT_MIRROR=archive.ubuntu.com make image` 换 apt 源。

## 1.5 服务器上的目录

`scripts/remote.sh` 在服务器 `$HOME` 下使用：

```
~/vivado-flow/<仓库名>/
├── sim/      make sim / wave-gui 的工作副本（保留 thinpad_top.sim、IP 生成物等增量状态）
├── bit/      make bit 的工作副本（保留 thinpad_top.runs）
└── docker/   make image 的构建上下文
```

`sim` 和 `bit` 分成两个副本，所以两者可以同时跑，不会抢同一个 Vivado 工程。想要全新环境时，删掉对应目录就行。
