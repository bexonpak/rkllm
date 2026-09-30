#!/usr/bin/env bash
# ============================================================================
#  04  LLM 部分: Qwen3-VL-2B  ->  .rkllm
#
#  分两个阶段，可用 --phase 单独执行（本地 Docker 混合方案需要拆开跑）：
#     calib : 4.1 生成量化校准集 input_embeds (data/llm_inputs.json + data/llm_inputs/*)
#     build : 4.2 rkllm.build(max_context=${MAX_CONTEXT}) + export_rkllm
#     all   : 两个都做（默认）
#
#  产物: ${OUTPUT_DIR}/qwen3-vl-2b-instruct_${QUANTIZED_DTYPE}_${TARGET_PLATFORM}.rkllm
#
#  用法:
#    bash scripts/04_export_llm.sh                    # 全流程
#    bash scripts/04_export_llm.sh --phase calib      # 只生成校准集
#    bash scripts/04_export_llm.sh --phase build      # 只做 RKLLM 构建（需已有校准集）
# ============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

PHASE="all"
while (( $# > 0 )); do
    case "$1" in
        --phase) PHASE="${2:-}"; shift 2 ;;
        --phase=*) PHASE="${1#*=}"; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) die "未知参数: $1（可用: --phase all|calib|build）" ;;
    esac
done
case "${PHASE}" in
    all|calib|build) ;;
    *) die "--phase 只能是 all / calib / build，当前为 '${PHASE}'" ;;
esac

banner "04 导出 LLM 部分 RKLLM (phase=${PHASE}, ${QUANTIZED_DTYPE}, max_context=${MAX_CONTEXT}, ${TARGET_PLATFORM})"
require_linux

[[ -f "${MODEL_DIR}/config.json" ]] || die "模型不存在: ${MODEL_DIR}，先跑 02_download_model.sh"
(( MAX_CONTEXT <= 16384 )) || die "MAX_CONTEXT=${MAX_CONTEXT} 超过 RKLLM 上限 16384，无法转换"
(( MAX_CONTEXT % 32 == 0 )) || die "MAX_CONTEXT 必须按 32 对齐"

ensure_dir "${OUTPUT_DIR}"

MODEL_TAG="$(basename "${MODEL_DIR}" | tr 'A-Z' 'a-z')"
SAVEPATH="${OUTPUT_DIR}/${MODEL_TAG}_${QUANTIZED_DTYPE}_${TARGET_PLATFORM}.rkllm"
CALIB_JSON="data/llm_inputs.json"

cd "${MM_DIR}"

# ===========================================================================
# 4.1 量化校准集
# ===========================================================================
phase_calib() {
    banner "4.1  make_input_embeds_for_quantize.py  (生成量化校准集)"
    c_info "校准集来源: data/datasets.json + data/datasets/（20 条图文样本，MMBench 抽取）"
    c_warn "该脚本按 image_path 字段的相对路径读图，所以必须在 ${MM_DIR} 下运行（脚本已 cd 过来）"

    # 清掉上一次的产物，避免残留样本混进校准集
    rm -rf data/llm_inputs data/llm_inputs.json

    # 只挑「确实存在」的 conda 环境来试。
    # 单机全量环境里两个都有；Docker 混合方案里原生 arm64 容器只有 rknn 环境，
    # 如果这里不先过滤，activate_env 会因为环境不存在直接 die，回退逻辑就走不到。
    local candidates=()
    local e
    for e in "${RKLLM_ENV}" "${RKNN_ENV}"; do
        if env_exists "${e}"; then candidates+=("${e}"); else c_info "环境 ${e} 不存在，跳过"; fi
    done
    (( ${#candidates[@]} > 0 )) || die "两个 conda 环境都不存在，请先跑 scripts/01_env_setup.sh"

    local ok=0 env_name
    for env_name in "${candidates[@]}"; do
        c_info "在 conda 环境 '${env_name}' 中生成 input_embeds ..."
        if (
            activate_env "${env_name}"
            cd "${MM_DIR}"
            python data/make_input_embeds_for_quantize.py \
                --path "${MODEL_DIR}" \
                --model_type qwen3vl
        ); then
            ok=1
            break
        fi
        c_warn "环境 '${env_name}' 生成失败（常见原因：该环境的 transformers 与 Qwen3-VL 不匹配）"
        rm -rf data/llm_inputs data/llm_inputs.json
    done
    (( ok == 1 )) || die "input_embeds 生成失败，请单独执行排查：
    conda activate <环境>
    cd ${MM_DIR}
    python data/make_input_embeds_for_quantize.py --path ${MODEL_DIR} --model_type qwen3vl"

    [[ -f data/llm_inputs.json ]] || die "没有生成 data/llm_inputs.json"
    local n
    n="$(find data/llm_inputs -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    (( n > 0 )) || die "data/llm_inputs/ 是空的"
    c_ok "校准集: data/llm_inputs.json，样本 ${n} 个 ($(human_size data/llm_inputs))"

    # 此时可能已 conda deactivate 回 base，优先用 conda 自带的 python3
    local PY3="python3"
    if [[ -n "${CONDA_HOME:-}" && -x "${CONDA_HOME}/bin/python3" ]]; then
        PY3="${CONDA_HOME}/bin/python3"
    fi

    "${PY3}" - <<'PY'
import json, os
info = json.load(open("data/llm_inputs.json"))
missing, toks = [], []
for it in info:
    p = os.path.join("data", it["sample"])
    if not os.path.isfile(p):
        missing.append(p)
    toks.append(it.get("token_nums", 0))
if missing:
    raise SystemExit("以下样本文件不存在（dataset 相对路径约定被打破）: %s" % missing[:3])
print("  样本数 %d, 每条 token 数 min/max = %d/%d"
      % (len(info), min(toks), max(toks)))
if max(toks) > 16384:
    print("  [WARN] 有样本 token 数超过 16384")
PY
    c_ok "校准集自检通过"
}

# ===========================================================================
# 4.2 构建 RKLLM
# ===========================================================================
phase_build() {
    banner "4.2  rkllm.build + export_rkllm  (max_context=${MAX_CONTEXT})"

    # rkllm-toolkit 只有 linux_x86_64 wheel，构建阶段必须是 x86_64
    require_linux_x86_64
    [[ -f "${CALIB_JSON}" ]] || die "找不到量化校准集 ${MM_DIR}/${CALIB_JSON}
    请先用 --phase calib 生成（或在完整环境里直接跑不带 --phase 的 04 脚本）"
    env_exists "${RKLLM_ENV}" || die "conda 环境 '${RKLLM_ENV}' 不存在（rkllm-toolkit 装在这里）"

    c_warn "注意 w4a16 官方建议配 grq 算法（精度更好），但 grq 需要 CUDA GPU；"
    c_warn "当前 QUANTIZED_ALGORITHM=${QUANTIZED_ALGORITHM}, DEVICE=${DEVICE}"

    activate_env "${RKLLM_ENV}"
    cd "${MM_DIR}"

    python "${KIT_DIR}/scripts/export_rkllm_qwen3vl.py" \
        --path "${MODEL_DIR}" \
        --target-platform "${TARGET_PLATFORM}" \
        --num_npu_core "${NUM_NPU_CORE}" \
        --quantized_dtype "${QUANTIZED_DTYPE}" \
        --quantized_algorithm "${QUANTIZED_ALGORITHM}" \
        --optimization_level "${OPTIMIZATION_LEVEL}" \
        --device "${DEVICE}" \
        --max_context "${MAX_CONTEXT}" \
        --dataset "${CALIB_JSON}" \
        --savepath "${SAVEPATH}" \
        || die "RKLLM 导出失败"

    conda deactivate || true

    [[ -f "${SAVEPATH}" ]] || die "没有生成 ${SAVEPATH}"
    {
        echo "artifact     : $(basename "${SAVEPATH}")"
        echo "bytes        : $(stat -c%s "${SAVEPATH}")"
        echo "sha256       : $(sha256_of "${SAVEPATH}")"
        echo "target       : ${TARGET_PLATFORM}"
        echo "dtype        : ${QUANTIZED_DTYPE} (${QUANTIZED_ALGORITHM})"
        echo "num_npu_core : ${NUM_NPU_CORE}"
        echo "max_context  : ${MAX_CONTEXT}"
    } > "${SAVEPATH}.info"

    c_ok "RKLLM: ${SAVEPATH} ($(human_size "${SAVEPATH}"))"
}

# 注意：这里用 if 而不是 `[[ ... ]] && phase_calib`。
# 顶层 `test && func` 在 set -e 下其实是安全的（失败的是被豁免的 test），
# 但语义不够直白，而且写成函数最后一行时会真的把 1 传染给调用方，统一用 if。
if [[ "${PHASE}" == "all" || "${PHASE}" == "calib" ]]; then phase_calib; fi
if [[ "${PHASE}" == "all" || "${PHASE}" == "build" ]]; then phase_build; fi

echo
case "${PHASE}" in
    calib) c_info "下一步:  bash scripts/04_export_llm.sh --phase build" ;;
    build) c_info "下一步:  bash scripts/05_build_demo.sh" ;;
    *)     c_info "下一步:  bash scripts/05_build_demo.sh" ;;
esac
