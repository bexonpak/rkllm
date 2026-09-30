#!/usr/bin/env bash
# ============================================================================
#  local_build.sh —— 在本机 Docker 里跑完整转换（macOS / Linux 通用）
#
#  核心思路：**能用原生就用原生，只有绕不过去的才用 Rosetta。**
#
#    rknn-toolkit2 有 aarch64 wheel  -> 视觉导出 / 校准集 / demo 编译 全走 arm64 原生
#    rkllm-toolkit 只有 x86_64 wheel -> 只有 RKLLM 构建那一步走 amd64（Rosetta）
#
#  所以在 Apple Silicon 上，Rosetta 只承担整条链路里的一步，慢也只慢那一步。
#
#  与 GitHub Actions 路线相比：
#    + 完全本地，不依赖任何远端仓库
#    - 需要先装 Docker Desktop（管理员权限），占 40-60GB 磁盘
#    - Rosetta 翻译有性能损失；CI 跑在真 x86_64 上通常更快
#
#  用法:
#    bash docker/smoke_test.sh          # ★ 先跑这个，验证 Rosetta 能不能加载工具链
#    bash docker/local_build.sh
#    ONLY=vision bash docker/local_build.sh     # 只做视觉部分
#    VISION_ON=amd64 bash docker/local_build.sh # 视觉也走 amd64（arm64 wheel 万一不好用时）
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
KIT_DIR="$(cd "${HERE}/.." && pwd -P)"
KIT_NAME="$(basename "${KIT_DIR}")"
# shellcheck source=../config.env
source "${KIT_DIR}/config.env"

# --- 可调参数 --------------------------------------------------------------
ARM_PLATFORM="${ARM_PLATFORM:-linux/arm64}"
X86_PLATFORM="${X86_PLATFORM:-linux/amd64}"
VISION_ON="${VISION_ON:-arm64}"          # arm64 | amd64
IMAGE_PREFIX="${IMAGE_PREFIX:-rk3576-qwen3vl}"
WORKSPACE="${WORKSPACE:-${HOME}/rkllm-workspace}"
TREE="${TREE:-${WORKSPACE}/rknn-llm-tree}"
UPSTREAM_REF="${UPSTREAM_REF:-release-v1.3.1}"
ONLY="${ONLY:-all}"                      # all | vision | llm | demo
MEMORY_LIMIT="${MEMORY_LIMIT:-}"         # 可选，例如 16g（不要超过 Docker Desktop 的 VM 上限）

case "${VISION_ON}" in arm64|amd64) ;; *) echo "VISION_ON 只能是 arm64 或 amd64" >&2; exit 1 ;; esac
case "${ONLY}" in all|vision|llm|demo) ;; *) echo "ONLY 只能是 all|vision|llm|demo" >&2; exit 1 ;; esac

c_info() { printf '\033[1;34m[INFO ]\033[0m %s\n' "$*"; }
c_ok()   { printf '\033[1;32m[ OK  ]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

# --- 前置 ------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "没装 docker。macOS 请装 Docker Desktop（Apple Silicon 版）并启动"
docker info >/dev/null 2>&1 || die "docker 守护进程没起来（Docker Desktop 启动了吗？）"

# --- 源码树（上游 + 本套件）------------------------------------------------
c_info "准备源码树（浅克隆上游 + 放入本套件）..."
TREE="$(bash "${KIT_DIR}/ci/prepare_tree.sh" "$(dirname "${KIT_DIR}")" "${TREE}" "${UPSTREAM_REF}")"
[[ -f "${TREE}/${KIT_NAME}/config.env" ]] || die "源码树里没有 ${KIT_NAME}/config.env: ${TREE}"
mkdir -p "${WORKSPACE}"
c_ok "源码树: ${TREE}"
c_info "工作区: ${WORKSPACE}（模型/conda 环境/产物都在这里，重跑不会重下）"

ARM_CONDA="/work/ws/conda-arm64"
X86_CONDA="/work/ws/conda-amd64"
VISION_PLATFORM="${ARM_PLATFORM}"
VISION_CONDA="${ARM_CONDA}"
VISION_TAG="arm64"
if [[ "${VISION_ON}" == "amd64" ]]; then
    VISION_PLATFORM="${X86_PLATFORM}"
    VISION_CONDA="${X86_CONDA}"
    VISION_TAG="amd64"
fi

# --- 镜像 ------------------------------------------------------------------
build_image() {   # <platform> <tag>
    local platform="$1" tag="$2"
    c_info "构建镜像 ${IMAGE_PREFIX}:${tag} (${platform}) ..."
    docker build --platform "${platform}" -t "${IMAGE_PREFIX}:${tag}" "${HERE}" >/dev/null \
        || die "镜像构建失败（${platform}）"
    c_ok "镜像就绪: ${IMAGE_PREFIX}:${tag}"
}

# --- 容器执行 --------------------------------------------------------------
docker_run() {    # <platform> <tag> <conda_home> <命令字符串>
    local platform="$1" tag="$2" conda_home="$3" cmd="$4"
    local extra=()
    [[ -n "${MEMORY_LIMIT}" ]] && extra+=(-m "${MEMORY_LIMIT}")
    docker run --rm \
        --platform "${platform}" \
        -v "${TREE}":/work/rknn-llm \
        -v "${WORKSPACE}":/work/ws \
        -v "${WORKSPACE}/pip-cache-${tag}":/root/.cache/pip \
        -w /work/rknn-llm \
        -e WORKSPACE=/work/ws \
        -e CONDA_HOME="${conda_home}" \
        -e TARGET_PLATFORM -e QUANTIZED_DTYPE -e QUANTIZED_ALGORITHM \
        -e MAX_CONTEXT -e NUM_NPU_CORE -e OPTIMIZATION_LEVEL -e DEVICE \
        -e IMG_HEIGHT -e IMG_WIDTH -e HF_ENDPOINT \
        ${extra[@]+"${extra[@]}"} \
        "${IMAGE_PREFIX}:${tag}" \
        bash -c "${cmd}"
}

step() {   # <标题> <platform> <tag> <conda_home> <命令>
    local title="$1"; shift
    echo
    echo "=============================================================="
    echo "  ${title}"
    echo "=============================================================="
    local t0 t1
    t0="$(date +%s)"
    docker_run "$@"
    t1="$(date +%s)"
    c_ok "${title} 完成，用时 $(( (t1 - t0) / 60 )) 分 $(( (t1 - t0) % 60 )) 秒"
}

# --- 计划 ------------------------------------------------------------------
echo
echo "=============================================================="
echo " 本地 Docker 构建计划"
echo "   视觉/校准集/demo : ${VISION_ON} 原生"
echo "   RKLLM 构建       : amd64 (Rosetta) —— rkllm-toolkit 只有 x86_64 wheel"
echo "   量化             : ${QUANTIZED_DTYPE} / max_context=${MAX_CONTEXT} / npu_core=${NUM_NPU_CORE}"
echo "   ONLY             : ${ONLY}"
echo "=============================================================="

# --- 构建镜像 --------------------------------------------------------------
if [[ "${ONLY}" == "all" || "${ONLY}" == "vision" || "${ONLY}" == "demo" ]]; then
    build_image "${VISION_PLATFORM}" "${VISION_TAG}"
fi
# 板端 demo 必须原生 aarch64 编译（amd64 容器编出来的是 x86_64，板子跑不了），
# 所以 VISION_ON=amd64 时还要额外准备一个 arm64 镜像
if [[ "${ONLY}" == "all" || "${ONLY}" == "demo" ]] && [[ "${VISION_TAG}" != "arm64" ]]; then
    build_image "${ARM_PLATFORM}" "arm64"
fi
if [[ "${ONLY}" == "all" || "${ONLY}" == "llm" ]]; then
    build_image "${X86_PLATFORM}" "amd64"
fi

SCRIPTS="/work/rknn-llm/${KIT_NAME}/scripts"
CI="/work/rknn-llm/${KIT_NAME}/ci"

# --- 视觉部分（默认 arm64 原生）--------------------------------------------
if [[ "${ONLY}" == "all" || "${ONLY}" == "vision" ]]; then
    step "装 miniforge3 (${VISION_ON})"      "${VISION_PLATFORM}" "${VISION_TAG}" "${VISION_CONDA}" \
        "bash ${CI}/install_miniforge.sh"
    step "装 rknn-toolkit2 环境 (${VISION_ON})" "${VISION_PLATFORM}" "${VISION_TAG}" "${VISION_CONDA}" \
        "bash ${SCRIPTS}/01_env_setup.sh --only rknn"
    step "下载模型"                          "${VISION_PLATFORM}" "${VISION_TAG}" "${VISION_CONDA}" \
        "bash ${SCRIPTS}/02_download_model.sh"
    step "视觉编码器 HF->ONNX->RKNN"          "${VISION_PLATFORM}" "${VISION_TAG}" "${VISION_CONDA}" \
        "bash ${SCRIPTS}/03_export_vision.sh"
    step "生成量化校准集 (--phase calib)"      "${VISION_PLATFORM}" "${VISION_TAG}" "${VISION_CONDA}" \
        "bash ${SCRIPTS}/04_export_llm.sh --phase calib"
fi

# --- RKLLM 部分（只能 amd64 / Rosetta）-------------------------------------
if [[ "${ONLY}" == "llm" ]]; then
    CALIB_HOST="${TREE}/examples/multimodal_model_demo/data/llm_inputs.json"
    [[ -f "${CALIB_HOST}" ]] || die "ONLY=llm 但还没有量化校准集：
    ${CALIB_HOST}
    请先跑  ONLY=vision bash docker/local_build.sh  （或直接不带 ONLY 跑 all）"
fi
if [[ "${ONLY}" == "all" || "${ONLY}" == "llm" ]]; then
    step "装 miniforge3 (amd64/Rosetta)"     "${X86_PLATFORM}" "amd64" "${X86_CONDA}" \
        "bash ${CI}/install_miniforge.sh"
    step "装 rkllm-toolkit 环境 (amd64)"      "${X86_PLATFORM}" "amd64" "${X86_CONDA}" \
        "bash ${SCRIPTS}/01_env_setup.sh --only rkllm"
    step "构建导出 RKLLM (--phase build)"     "${X86_PLATFORM}" "amd64" "${X86_CONDA}" \
        "bash ${SCRIPTS}/04_export_llm.sh --phase build"
fi

# --- 板端 demo（原生 aarch64，无需交叉工具链）------------------------------
if [[ "${ONLY}" == "all" || "${ONLY}" == "demo" ]]; then
    step "编译板端 demo (原生 aarch64)"        "${ARM_PLATFORM}" "arm64" "${ARM_CONDA}" \
        "bash ${SCRIPTS}/05_build_demo.sh"
fi

# --- 汇总 ------------------------------------------------------------------
OUT_DIR="${TREE}/${KIT_NAME}/output"
echo
echo "=============================================================="
c_ok "全部完成"
echo "=============================================================="
if [[ -d "${OUT_DIR}" ]]; then
    ls -lh "${OUT_DIR}" | sed 's/^/    /'
else
    c_warn "没有找到产物目录 ${OUT_DIR}"
fi
cat <<EOF

产物在: ${OUT_DIR}
板端部署:
    adb push ${OUT_DIR}/demo_Linux_aarch64 /data/
    adb push ${OUT_DIR}/*.rknn ${OUT_DIR}/*.rkllm /data/demo_Linux_aarch64/
    # 板子上:
    cd /data/demo_Linux_aarch64 && sh run_demo.sh

说明:
  * 模型和 conda 环境都缓存在 ${WORKSPACE}，重跑不会重新下载
  * 想重做视觉部分:   ONLY=vision bash docker/local_build.sh
  * 想重做 RKLLM:     ONLY=llm    bash docker/local_build.sh
  * arm64 的 rknn-toolkit2 万一不能转换，改用:
      VISION_ON=amd64 bash docker/local_build.sh
EOF
