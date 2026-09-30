# ============================================================================
#  本地 Docker 构建镜像（macOS / Linux 通用）
#
#  同一份 Dockerfile 支持两种平台，用 --platform 选择：
#     linux/arm64  —— 原生。用于视觉导出 / 校准集 / demo 编译（最快）
#     linux/amd64  —— Apple Silicon 上由 Rosetta 翻译。
#                     rkllm-toolkit 只有 x86_64 wheel，只有这条路能跑。
#
#  注意：镜像里**不装 conda 环境**。conda 和两个环境都装到挂载进来的
#  工作区（CONDA_HOME），这样：
#    1) 镜像构建只要 2-3 分钟，改依赖不用重建镜像
#    2) arm64 / amd64 两套环境各自持久化，互不污染
#    3) 重跑时不用重新下 torch
#
#  构建（由 docker/local_build.sh 自动完成，手动构建示例）：
#     docker build --platform linux/arm64 -t rk3576-qwen3vl:arm64 docker/
#     docker build --platform linux/amd64 -t rk3576-qwen3vl:amd64 docker/
# ============================================================================
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV BUILD_CUDA_EXT=0

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget curl bzip2 xz-utils \
        git git-lfs \
        build-essential cmake pkg-config file \
        libgl1 libglib2.0-0 libsm6 libxext6 libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && git lfs install --system \
    && echo "架构: $(uname -m)"

WORKDIR /work/rknn-llm
CMD ["/bin/bash"]
