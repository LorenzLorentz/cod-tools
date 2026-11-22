# 在 Vivado 基础镜像上加一层很薄的“仿真 + 渲染”工具：
#   - gcc / libc6-dev：xsim 的 xelab 会把设计编译成本地代码，要求系统里有 /usr/bin/gcc，
#     基础镜像里没有，缺了它行为仿真在 elaborate 阶段直接报错 [XSIM 43-3388]
#   - matplotlib：在服务器上把 VCD 波形画成 PNG
#   - imagemagick：make wave-gui 用它给 Xvfb 里的 Vivado 波形窗口截图
# 基础镜像（vivado:2024.2，约 154GB）不改动；这一层只有几百 MB，在每台服务器上本地 build 即可。
#
#   docker build -t vivado-flow:2024.2 --build-arg BASE=vivado:2024.2 docker/
ARG BASE=vivado:2024.2
FROM ${BASE}

# 默认走清华镜像；在校外可以 --build-arg APT_MIRROR=archive.ubuntu.com
ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
RUN sed -i -E "s#http://(archive|security)\.ubuntu\.com#http://${APT_MIRROR}#g" /etc/apt/sources.list.d/ubuntu.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends gcc g++ libc6-dev \
      python3-matplotlib python3-numpy fonts-dejavu-core imagemagick \
 && rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="vivado-flow" \
      org.opencontainers.image.description="Vivado 2024.2 + gcc/matplotlib/imagemagick for headless xsim and rendering"
