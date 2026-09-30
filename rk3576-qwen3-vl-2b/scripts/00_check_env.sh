#!/usr/bin/env bash
# ============================================================================
#  00  转换前环境自检（不改任何东西，只报告）
#  用法: bash scripts/00_check_env.sh
# ============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

banner "00 环境自检  Qwen3-VL-2B -> ${TARGET_PLATFORM}"

# --- 1. 主机 ---------------------------------------------------------------
c_info "主机: $(uname -s)/$(uname -m)   内核: $(uname -r)"
require_linux

# x86_64 / aarch64 的能力差异说明
HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" == "aarch64" || "${HOST_ARCH}" == "arm64" ]]; then
    c_info "aarch64 宿主机：02 下载 / 03 视觉导出 / 04 校准集 / 05 编译 demo 都能原生跑，"
    c_info "  但 01 装 rkllm 环境和 04 的 build 阶段需要 x86_64（rkllm-toolkit 只有 x86_64 wheel）。"
    c_info "  推荐用 docker/local_build.sh 自动做 arm64+x86_64 混合构建，或走 GitHub Actions。"
fi

# --- 2. 上下文长度合法性（RKLLM 1.3.1 硬上限） ------------------------------
if (( MAX_CONTEXT > 16384 )); then
    c_err "MAX_CONTEXT=${MAX_CONTEXT} 超过 RKLLM 1.3.1 的官方上限 16384。"
    c_err "官方文档原文（doc/Rockchip_RKLLM_SDK_CN_1.3.1.pdf, build() 接口说明）："
    c_err "  “context: 上下文长度的上限值，最大支持到 16384 且必须按 32 对齐”"
    c_err "英文版：The maximum context length, supported up to 16,384 and must be aligned to 32."
    die "请把 config.env 里的 MAX_CONTEXT 改成 <= 16384 且为 32 的倍数"
fi
if (( MAX_CONTEXT % 32 != 0 )); then
    die "MAX_CONTEXT=${MAX_CONTEXT} 不是 32 的倍数（官方要求按 32 对齐）"
fi
c_ok "MAX_CONTEXT=${MAX_CONTEXT}（<=16384 且 32 对齐）"

# --- 3. RK3576 量化 / 核心数合法性 -----------------------------------------
case "${QUANTIZED_DTYPE}" in
    w4a16|w4a16_g32|w4a16_g64|w4a16_g128|w8a8) ;;
    *) die "RK3576 不支持量化类型 '${QUANTIZED_DTYPE}'。可选: w4a16 w4a16_g32 w4a16_g64 w4a16_g128 w8a8（w8a8_g128/g256/g512 是 RK3588 专属）" ;;
esac
c_ok "QUANTIZED_DTYPE=${QUANTIZED_DTYPE}"
if (( NUM_NPU_CORE < 1 || NUM_NPU_CORE > 2 )); then
    die "RK3576 的 NPU 核心数只能是 1 或 2，当前 NUM_NPU_CORE=${NUM_NPU_CORE}（3 是 RK3588 的值）"
fi
c_ok "NUM_NPU_CORE=${NUM_NPU_CORE}"

# --- 4. 内存 / 磁盘 --------------------------------------------------------
ram_gb="$(check_ram_gb)"
if (( ram_gb > 0 )); then
    c_info "内存: ${ram_gb} GB"
    if (( ram_gb < 32 )); then
        c_warn "建议 >= 32GB。export_vision.py 以 float32 加载整个 2B 模型，峰值内存约 10-14GB；"
        c_warn "RKLLM 侧 load_huggingface 同样吃内存。内存不足会 OOM Killed，请加大 swap 或换机器。"
    else
        c_ok "内存充足"
    fi
else
    c_warn "无法读取内存信息（/proc/meminfo 不可用）；请自行确认 >= 32GB"
fi
free_h="$(df -h "${HOME}" | awk 'NR==2{print $4}')"
c_info "HOME 可用磁盘: ${free_h}（建议 >= 60GB：模型 4.3GB + ONNX/RKNN 若干 GB + torch 等依赖）"

# --- 5. 基础命令 ----------------------------------------------------------
for c in git python3 pip3; do
    if command -v "$c" >/dev/null 2>&1; then c_ok "$c -> $(command -v "$c")"; else c_warn "缺少 $c"; fi
done
command -v adb >/dev/null 2>&1 && c_ok "adb -> $(command -v adb)" \
    || c_warn "未找到 adb（只影响 06_push_to_board.sh 推送到板子；可用 scp/U盘替代）"

# --- 6. conda ------------------------------------------------------------
if sh="$(_find_conda_sh 2>/dev/null)"; then
    c_ok "conda -> ${sh}"
    conda_init
    for e in "${RKLLM_ENV}" "${RKNN_ENV}"; do
        if conda env list | awk '{print $1}' | grep -qx "$e"; then
            c_ok "conda 环境存在: $e"
        else
            c_warn "conda 环境不存在: $e  -> 运行 bash scripts/01_env_setup.sh"
        fi
    done
else
    c_warn "未找到 conda（miniforge/miniconda/anaconda）。01_env_setup.sh 会提示安装方式"
fi

# --- 7. 仓库结构 ----------------------------------------------------------
[[ -d "${MM_DIR}" ]] && c_ok "multimodal demo: ${MM_DIR}" || die "找不到 ${MM_DIR}，REPO_ROOT 是否正确？"
for f in \
    "export/export_vision.py" \
    "export/export_vision_rknn.py" \
    "data/make_input_embeds_for_quantize.py" \
    "data/datasets.json" \
    "deploy/build-linux.sh" ; do
    [[ -f "${MM_DIR}/${f}" ]] && c_ok "  ${f}" || die "缺少 ${MM_DIR}/${f}"
done
n_imgs="$(find "${MM_DIR}/data/datasets" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
if (( n_imgs >= MIN_QUANT_SAMPLES )); then
    c_ok "量化校准图: ${n_imgs} 张"
else
    c_warn "量化校准图仅 ${n_imgs} 张（期望 >= ${MIN_QUANT_SAMPLES}），w4a16 量化精度可能下降"
fi

# --- 8. 工具链 wheel ------------------------------------------------------
shopt -s nullglob
wheels=("${RKLLM_TOOLKIT_PKGS}"/rkllm_toolkit-*-cp${RKLLM_PY_TAG}-cp${RKLLM_PY_TAG}-linux_x86_64.whl)
shopt -u nullglob
if (( ${#wheels[@]} > 0 )); then
    c_ok "rkllm-toolkit wheel: $(basename "${wheels[0]}")"
else
    c_warn "在 ${RKLLM_TOOLKIT_PKGS} 下没找到 cp${RKLLM_PY_TAG} 的 rkllm_toolkit linux_x86_64 wheel"
fi
[[ -f "${RKLLM_RT_DIR}/Linux/librkllm_api/aarch64/librkllmrt.so" ]] \
    && c_ok "librkllmrt.so (aarch64) 存在" || c_warn "缺少 aarch64 的 librkllmrt.so"

# --- 9. 模型 --------------------------------------------------------------
if [[ -d "${MODEL_DIR}" && -f "${MODEL_DIR}/config.json" ]]; then
    c_ok "本地模型: ${MODEL_DIR} ($(human_size "${MODEL_DIR}"))"
    for f in config.json preprocessor_config.json tokenizer.json; do
        [[ -f "${MODEL_DIR}/${f}" ]] && c_ok "  ${f}" || c_warn "  缺少 ${f}"
    done
    if compgen -G "${MODEL_DIR}/*.safetensors" >/dev/null; then
        c_ok "  权重: $(ls -1 "${MODEL_DIR}"/*.safetensors | wc -l | tr -d ' ') 个 safetensors"
    else
        c_warn "  没有 .safetensors 权重，请运行 02_download_model.sh"
    fi
else
    c_warn "本地还没有模型: ${MODEL_DIR}  -> 运行 bash scripts/02_download_model.sh"
fi

banner "自检结束"
cat <<EOF
当前配置（来自 config.env）：
  目标平台       : ${TARGET_PLATFORM}
  量化类型       : ${QUANTIZED_DTYPE}  (算法 ${QUANTIZED_ALGORITHM})
  上下文长度     : ${MAX_CONTEXT}
  NPU 核心数     : ${NUM_NPU_CORE}
  视觉输入       : ${IMG_HEIGHT}x${IMG_WIDTH}, batch=${IMG_BATCH}
  模型目录       : ${MODEL_DIR}
  产物目录       : ${OUTPUT_DIR}

下一步：
  bash scripts/01_env_setup.sh       # 建两个 conda 环境（只做一次）
  bash scripts/02_download_model.sh  # 拉 Qwen3-VL-2B-Instruct
  bash scripts/run_all.sh            # 或者一步到位跑完整条链路
EOF
