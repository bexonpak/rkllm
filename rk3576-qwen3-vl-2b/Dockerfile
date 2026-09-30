# ============================================================================
#  Qwen3-VL-2B -> RK3576 转换环境（Ubuntu 22.04 x86_64 + miniforge）
#
#  rkllm-toolkit 只发布 linux_x86_64 的 wheel，macOS/arm64 主机无法转换，
#  所以这里给一个可复现的 x86_64 构建容器。
#
#  构建（在 rknn-llm 仓库根目录执行，镜像约 20-25GB）：
#      docker build -f rk3576-qwen3-vl-2b/Dockerfile -t rk3576-qwen3vl .
#
#  运行（模型/产物都放挂载出来的 workspace，避免留在容器里）：
#      docker run --rm -it \
#          -v "$PWD/rk3576-qwen3-vl-2b/output:/work/rknn-llm/rk3576-qwen3-vl-2b/output" \
#          -v "$HOME/rkllm-workspace:/work/rkllm-workspace" \
#          rk3576-qwen3vl bash
#      # 容器内：
#      cd /work/rknn-llm
#      bash rk3576-qwen3-vl-2b/scripts/run_all.sh --skip-env
#
#  在 Apple Silicon 上构建需要模拟 amd64（很慢，仅供参考）：
#      docker build --platform linux/amd64 -f rk3576-qwen3-vl-2b/Dockerfile -t rk3576-qwen3vl .
#
#  内存：docker run 建议至少 --memory=32g，否则 ONNX 导出阶段会被 OOM Kill。
# ============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV BUILD_CUDA_EXT=0

# --- 系统依赖：交叉编译 + rknn-toolkit2/onnxruntime/opencv 运行库 -------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget curl ca-certificates bzip2 \
        git git-lfs build-essential cmake pkg-config \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
        libgl1 libglib2.0-0 libsm6 libxext6 libgomp1 \
        android-tools-adb file \
    && rm -rf /var/lib/apt/lists/* \
    && git lfs install --system

# --- miniforge（用国内镜像，官方 conda-forge 亦可） --------------------------
RUN wget -q -O /tmp/miniforge.sh \
        https://mirrors.bfsu.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh \
    && bash /tmp/miniforge.sh -b -p /opt/conda \
    && rm -f /tmp/miniforge.sh \
    && /opt/conda/bin/conda clean -afy

ENV CONDA_HOME=/opt/conda
ENV PATH=/opt/conda/bin:$PATH
ENV CONDA_AUTO_ACTIVATE_BASE=false

# --- 仓库 + 工具链环境预装 --------------------------------------------------
WORKDIR /work/rknn-llm
COPY . /work/rknn-llm/

# 预装两个 conda 环境（transformers 5.8.0 与 4.57.0 必须分开）
RUN bash /work/rknn-llm/rk3576-qwen3-vl-2b/scripts/01_env_setup.sh \
    && /opt/conda/bin/conda clean -afy

# 模型默认落在 /work/rkllm-workspace（建议挂载出来）
ENV WORKSPACE=/work/rkllm-workspace
RUN mkdir -p ${WORKSPACE}

CMD ["/bin/bash"]
