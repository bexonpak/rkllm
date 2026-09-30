#!/usr/bin/env bash
# ============================================================================
#  01  创建 conda 环境并安装工具链（只需执行一次）
#
#   环境 A  ${RKLLM_ENV} : rkllm-toolkit + transformers==5.8.0 + torch  -> 出 .rkllm
#   环境 B  ${RKNN_ENV}  : rknn-toolkit2 + transformers==4.57.0        -> 出 .onnx / .rknn
#
#  为什么必须两个环境：Qwen3-VL 的视觉导出官方要求 transformers==4.57.0，
#  而 rkllm-toolkit 的 requirements 锁 transformers==5.8.0，两者不能共存。
#
#  用法:
#    bash scripts/01_env_setup.sh                 # 两个环境都装（本机开发推荐）
#    bash scripts/01_env_setup.sh --only rknn     # 只装视觉环境（CI 的 vision job）
#    bash scripts/01_env_setup.sh --only rkllm    # 只装语言环境
# ============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

ONLY="both"
while (( $# > 0 )); do
    case "$1" in
        --only) ONLY="${2:-}"; shift 2 ;;
        --only=*) ONLY="${1#*=}"; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) die "未知参数: $1（可用: --only both|rknn|rkllm）" ;;
    esac
done
case "${ONLY}" in
    both)  WANT_RKLLM=1; WANT_RKNN=1 ;;
    rkllm) WANT_RKLLM=1; WANT_RKNN=0 ;;
    rknn)  WANT_RKLLM=0; WANT_RKNN=1 ;;
    *) die "--only 只能是 both / rknn / rkllm，当前为 '${ONLY}'" ;;
esac

banner "01 安装工具链环境 (--only ${ONLY})"
require_linux

# ---------------------------------------------------------------------------
# 0. conda 是否就绪
# ---------------------------------------------------------------------------
if ! _find_conda_sh >/dev/null 2>&1; then
    c_err "未找到 conda。请先安装 miniforge3（推荐，体积小、无 Anaconda 商业条款）："
    cat <<'EOF'

  # 官方源（海外最快）
  wget -c https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
  # 国内可换镜像：
  # wget -c https://mirrors.bfsu.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh
  bash Miniforge3-Linux-x86_64.sh        # 一路回车 + yes，最后 Proceed with initialization? 输入 yes
  source ~/miniforge3/bin/activate

  装好后重新运行本脚本。若装在别处，设置 CONDA_HOME=/your/miniforge3
EOF
    exit 1
fi
conda_init
c_ok "conda: ${CONDA_HOME}"

# ---------------------------------------------------------------------------
# 1. 系统依赖（rknn-toolkit2 / onnxruntime / opencv 需要）
# ---------------------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
    c_info "安装系统依赖 (libgl1 libglib2.0-0 libsm6 libxext6 libgomp1 git-lfs)"
    if sudo -n true 2>/dev/null || [[ "$(id -u)" == "0" ]]; then
        SUDO=""; [[ "$(id -u)" != "0" ]] && SUDO="sudo"
        ${SUDO} apt-get update -y >/dev/null 2>&1 || c_warn "apt-get update 失败，继续"
        ${SUDO} apt-get install -y libgl1 libglib2.0-0 libsm6 libxext6 libgomp1 git-lfs >/dev/null 2>&1 \
            || c_warn "apt 依赖安装失败，若后面 import cv2 / onnxruntime 报错请手动安装"
    else
        c_warn "sudo 需要密码，跳过系统依赖安装。如遇 libGL.so.1 报错请手动执行："
        c_warn "  sudo apt-get install -y libgl1 libglib2.0-0 libsm6 libxext6 libgomp1 git-lfs"
    fi
else
    c_warn "非 apt 系统，请自行保证 libGL/libgomp/opencv 依赖"
fi

create_env() {
    local name="$1" pyver="$2"
    if conda env list | awk '{print $1}' | grep -qx "${name}"; then
        c_info "conda 环境已存在，跳过创建: ${name}"
    else
        c_info "创建 conda 环境 ${name} (python=${pyver})"
        conda create -y -n "${name}" "python=${pyver}" || die "创建环境 ${name} 失败"
    fi
}

# 避免 auto_gptq 尝试编译 CUDA 扩展（官方 README 也要求这样设）
export BUILD_CUDA_EXT=0

# ---------------------------------------------------------------------------
# 2. 环境 A：rkllm-toolkit
# ---------------------------------------------------------------------------
setup_rkllm_env() {
    # rkllm-toolkit 只有 linux_x86_64 wheel，这一步必须是 x86_64
    require_linux_x86_64
    c_info "==== 配置 ${RKLLM_ENV} (RKLLM) ===="
    create_env "${RKLLM_ENV}" "${RKLLM_PY_VER}"
    activate_env "${RKLLM_ENV}"

    local wheels wheel req req_filtered
    shopt -s nullglob
    wheels=("${RKLLM_TOOLKIT_PKGS}"/rkllm_toolkit-*-cp${RKLLM_PY_TAG}-cp${RKLLM_PY_TAG}-linux_x86_64.whl)
    shopt -u nullglob
    (( ${#wheels[@]} > 0 )) || die "找不到 rkllm_toolkit 的 cp${RKLLM_PY_TAG} wheel（目录 ${RKLLM_TOOLKIT_PKGS}）"
    wheel="${wheels[0]}"
    pip install --upgrade pip -i "${PIP_INDEX}" >/dev/null

    # ★ 顺序很关键：必须先装 CPU 版 torch，再装 rkllm-toolkit wheel。
    #   rkllm-toolkit 的元数据钉了 torch==2.6.0，如果先装 wheel，
    #   pip 会立刻去拉 766MB 的「默认 PyPI torch」（带 CUDA），
    #   还会连带拉 2.5GB 左右的 nvidia-* 依赖 —— 实测在海外 runner 上
    #   走国内镜像时这一步就卡死了（766MB @ 170kB/s ≈ 76 分钟）。
    #   先装好 torch==2.6.0+cpu 之后，PEP 440 规定 "==2.6.0" 匹配本地版本
    #   2.6.0+cpu，pip 会认为依赖已满足，这 3GB+ 的下载就全省了。
    c_info "先装 CPU 版 torch==${RKLLM_TORCH} / torchvision（省掉 CUDA 版 766MB + nvidia-* 约 2.5GB）"
    pip install "torch==${RKLLM_TORCH}" "torchvision==0.21.0" --index-url "${TORCH_CPU_INDEX}" \
        || { c_warn "CPU 版 torch 安装失败，回退到 ${PIP_INDEX}（会拉 CUDA 版，体积大很多）"; pip install "torch==${RKLLM_TORCH}" "torchvision==0.21.0" -i "${PIP_INDEX}"; }

    c_info "安装 rkllm-toolkit wheel: $(basename "${wheel}")"
    pip install "${wheel}" -i "${PIP_INDEX}" || die "安装 rkllm-toolkit wheel 失败"

    c_info "安装 huggingface_hub CLI（下载模型用）"
    pip install "huggingface_hub[cli]" -i "${PIP_INDEX}" >/dev/null || c_warn "huggingface_hub 安装失败"

    c_info "安装 rkllm-toolkit 的 requirements.txt（自动跳过装不上的 auto_gptq）"
    req="${RKLLM_TOOLKIT_PKGS}/requirements.txt"
    if [[ -f "${req}" ]]; then
        if ! pip install -r "${req}" -i "${PIP_INDEX}"; then
            c_warn "整份 requirements.txt 安装失败，通常是 auto_gptq（需要 CUDA 编译）。"
            c_warn "auto_gptq 只有转换 GPTQ 模型时才用到，Qwen3-VL 用不到，这里过滤掉重试。"
            req_filtered="$(mktemp)"
            grep -v -i '^[[:space:]]*auto_gptq' "${req}" > "${req_filtered}"
            pip install -r "${req_filtered}" -i "${PIP_INDEX}" \
                || die "requirements 安装失败，请查看上面的报错（常见原因：网络/镜像、缺少编译工具 build-essential）"
            rm -f "${req_filtered}"
        fi
    else
        c_warn "找不到 ${req}，跳过"
    fi

    python - <<'PY' || die "rkllm-toolkit 导入失败"
from rkllm.api import RKLLM
import transformers, torch
print("  rkllm-toolkit : OK")
print("  transformers  :", transformers.__version__)
print("  torch         :", torch.__version__)
PY
    conda deactivate || true
    c_ok "${RKLLM_ENV} 就绪"
}

# ---------------------------------------------------------------------------
# 3. 环境 B：rknn-toolkit2（视觉导出）
# ---------------------------------------------------------------------------
setup_rknn_env() {
    c_info "==== 配置 ${RKNN_ENV} (RKNN) ===="
    create_env "${RKNN_ENV}" "${RKNN_PY_VER}"
    activate_env "${RKNN_ENV}"

    pip install --upgrade pip -i "${PIP_INDEX}" >/dev/null

    # ★★ torch 必须锁在 2.4.x，torchvision 必须配套锁 0.19.0 ★★
    #   这不是随手挑的版本，踩过两次坑：
    #     1) rknn-toolkit2 2.3.2 的元数据是 "torch<=2.4.0,>=1.10.1"，
    #        装 2.6.0 会在装 rknn-toolkit2 时被悄悄降级成 2.4.0；
    #     2) 随后未固定版本的 torchvision 又会把 torch 顶到 2.14.0。
    #   而 torch.onnx.export 在 2.4 里是 dynamo=False（TorchScript 旧导出器），
    #   在 2.14 里默认 dynamo=True —— Qwen3-VL vision 的 forward 里有
    #   grid_t*grid_h*grid_w 这种数据相关形状，dynamo 会直接失败：
    #     GuardOnDataDependentSymNode: Could not extract specialized integer...
    #   所以：torch/torchvision 成对固定，且这一行之后不允许再出现
    #   不固定版本的 torch/torchvision。
    c_info "安装 CPU 版 torch==${RKNN_TORCH} + torchvision==${RKNN_TORCHVISION}（配套版本，缺一不可）"
    pip install "torch==${RKNN_TORCH}" "torchvision==${RKNN_TORCHVISION}" --index-url "${TORCH_CPU_INDEX}" \
        || { c_warn "CPU 版 torch/torchvision 安装失败，回退到 ${PIP_INDEX}";
             pip install "torch==${RKNN_TORCH}" "torchvision==${RKNN_TORCHVISION}" -i "${PIP_INDEX}"; }

    c_info "安装 ${RKNN_TOOLKIT2_SPEC}"
    pip install "${RKNN_TOOLKIT2_SPEC}" -i "${PIP_INDEX}" || die "rknn-toolkit2 安装失败"

    c_info "安装 Qwen3-VL 视觉导出所需版本：transformers==${RKNN_TRANSFORMERS} onnx==${RKNN_ONNX}"
    pip install "transformers==${RKNN_TRANSFORMERS}" "onnx==${RKNN_ONNX}" -i "${PIP_INDEX}" \
        || die "transformers/onnx 安装失败"

    # ★ onnxscript 也是硬依赖：torch.onnx.export 会无条件 import
    #   torch.onnx._internal.exporter，那里第一行就是 import onnxscript。
    #   缺了它会在「模型已加载完、前向也算完」之后才报 ModuleNotFoundError。
    #   注意这里**故意不写 torchvision**（会顶掉上面固定的版本）。
    c_info "安装辅助依赖 + onnxscript（onnxscript 是 torch.onnx.export 的硬依赖）"
    pip install "timm" "pillow" "tqdm" "accelerate" "datasets" \
                "huggingface_hub[cli]" "onnxscript" -i "${PIP_INDEX}" \
        || c_warn "部分辅助依赖安装失败，导出时若报错请按提示补装"

    # ★ 装完强制校验版本。将来若有依赖把 torch 顶掉，这里立刻失败并说明原因，
    #   而不是等到 ONNX 导出时报一堆看不懂的 dynamo / symbolic shape 错误。
    python - <<'PY' || die "rknn 环境自检未通过（见上面的 FATAL 说明）"
import sys
import torch
print("  torch         :", torch.__version__)
print("  torchvision   :", __import__("torchvision").__version__)
import transformers, onnx
from rknn.api import RKNN
print("  rknn-toolkit2 : OK")
print("  transformers  :", transformers.__version__)
print("  onnx          :", onnx.__version__)
if not torch.__version__.startswith("2.4."):
    print()
    print("  [FATAL] 期望 torch 2.4.x，实际 %s。" % torch.__version__)
    print("  rknn-toolkit2 要求 torch<=2.4.0；而且 torch.onnx.export 只有在")
    print("  2.4 里才默认 dynamo=False（TorchScript 旧导出器）。更新版本会走")
    print("  dynamo 新导出器，Qwen3-VL vision 会报 GuardOnDataDependentSymNode。")
    print("  多半是某个依赖（常见：未固定版本的 torchvision）把 torch 顶上去了。")
    sys.exit(1)
PY
    conda deactivate || true
    c_ok "${RKNN_ENV} 就绪"
}

# 用 if 而不是 `(( WANT_RKLLM == 1 )) && setup_rkllm_env`：
# 后者在条件为假时会让「整条语句」的返回值为 1，读起来像失败；用 if 语义明确。
if (( WANT_RKLLM == 1 )); then setup_rkllm_env; fi
if (( WANT_RKNN  == 1 )); then setup_rknn_env;  fi

banner "01 完成 (--only ${ONLY})"
cat <<EOF
环境 A (${RKLLM_ENV}) : 出 .rkllm    $( ((WANT_RKLLM==1)) && echo '[已安装]' || echo '[本次跳过]' )
环境 B (${RKNN_ENV})  : 出 .onnx/.rknn $( ((WANT_RKNN==1)) && echo '[已安装]' || echo '[本次跳过]' )

下一步:  bash scripts/02_download_model.sh
EOF
