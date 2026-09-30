#!/usr/bin/env bash
# ============================================================================
#  02  下载 Qwen3-VL-2B-Instruct
#  产物: ${MODEL_DIR}/  (config.json / model.safetensors ~4.26GB / tokenizer 等)
# ============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

banner "02 下载模型 ${MODEL_ID}"
require_linux

ensure_dir "$(dirname "${MODEL_DIR}")"

# --- 已经下好了就跳过 -------------------------------------------------------
if [[ -f "${MODEL_DIR}/config.json" ]] && compgen -G "${MODEL_DIR}/*.safetensors" >/dev/null; then
    sz="$(du -sb "${MODEL_DIR}" 2>/dev/null | awk '{print $1}')"
    if (( sz > 4000000000 )); then
        c_ok "模型已存在且看起来完整: ${MODEL_DIR} ($(human_size "${MODEL_DIR}"))"
        c_info "如需强制重新下载: rm -rf '${MODEL_DIR}' 后重跑"
        exit 0
    fi
    c_warn "模型目录存在但体积偏小 (${sz} bytes)，重新下载"
fi

# --- 挑一个可用的 conda 环境 ------------------------------------------------
# 注意：不能写死 RKLLM_ENV。CI 的 vision job 用 `01 --only rknn` 只装了 rknn 环境，
# 写死的话 activate_env 会直接 die，整个 job 挂在下载这一步。
DL_ENV=""
for _e in "${RKLLM_ENV}" "${RKNN_ENV}"; do
    if env_exists "${_e}"; then DL_ENV="${_e}"; break; fi
done
[[ -n "${DL_ENV}" ]] || die "两个 conda 环境都不存在，请先运行 bash scripts/01_env_setup.sh"
c_info "使用 conda 环境 '${DL_ENV}' 下载模型"
activate_env "${DL_ENV}"

export HF_HUB_ENABLE_HF_TRANSFER=0
if [[ -n "${HF_ENDPOINT}" ]]; then
    export HF_ENDPOINT
    c_info "使用镜像 HF_ENDPOINT=${HF_ENDPOINT}"
else
    c_info "使用官方 huggingface.co（国内慢的话设 HF_ENDPOINT=https://hf-mirror.com 重跑）"
fi

# 忽略这些格式（只要 safetensors）。注意：**不要**用 CLI 的 --exclude：
#   huggingface_hub 1.33.0 的 --exclude 只吃一个值，多给的会被当成位置参数
#   （"要下载的文件名"），结果 "Fetching 0 files" 还返回成功 —— run #3 就是这么挂的。
#   Python API 的 ignore_patterns 是真正的列表，跨版本稳定。
IGNORE_PATTERNS="*.pth *.bin *.msgpack *.h5 *.ot"

download_via_api() {
    c_info "用 huggingface_hub.snapshot_download 下载 -> ${MODEL_DIR}"
    HF_MODEL_ID="${MODEL_ID}" HF_LOCAL_DIR="${MODEL_DIR}" HF_IGNORE="${IGNORE_PATTERNS}" \
    python - <<'PY'
import os
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id=os.environ["HF_MODEL_ID"],
    local_dir=os.environ["HF_LOCAL_DIR"],
    ignore_patterns=os.environ["HF_IGNORE"].split(),
)
print("[download] snapshot_download 完成")
PY
}

download_via_cli() {
    # 兜底：不带 --exclude。Qwen3-VL-2B 仓库本身只有 safetensors，没有 .bin/.pth
    local cli="$1"
    c_info "用 ${cli} download 下载（不带 --exclude）"
    if [[ "${cli}" == "hf" ]]; then
        hf download "${MODEL_ID}" --local-dir "${MODEL_DIR}"
    else
        huggingface-cli download "${MODEL_ID}" --local-dir "${MODEL_DIR}"
    fi
}

download_via_git() {
    c_warn "回退到 git lfs"
    need_cmd git "安装 git"
    git lfs version >/dev/null 2>&1 || die "git-lfs 未安装：sudo apt-get install -y git-lfs"
    local url="https://huggingface.co/${MODEL_ID}"
    [[ -n "${HF_ENDPOINT}" ]] && url="${HF_ENDPOINT}/${MODEL_ID}"
    rm -rf "${MODEL_DIR}"
    GIT_LFS_SKIP_SMUDGE=1 git clone "${url}" "${MODEL_DIR}" || die "git clone 失败"
    ( cd "${MODEL_DIR}" && git lfs pull ) || die "git lfs pull 失败"
}

DL_OK=0
if download_via_api; then
    DL_OK=1
else
    c_warn "snapshot_download 失败，尝试 CLI 兜底方案"
    if command -v hf >/dev/null 2>&1; then
        download_via_cli hf && DL_OK=1
    elif command -v huggingface-cli >/dev/null 2>&1; then
        download_via_cli huggingface-cli && DL_OK=1
    fi
    if (( DL_OK == 0 )); then
        download_via_git && DL_OK=1
    fi
fi
(( DL_OK == 1 )) || die "模型下载失败（三种方式都试过了）"

# --- 校验 ------------------------------------------------------------------
banner "下载结果校验"
[[ -f "${MODEL_DIR}/config.json" ]]            || die "缺少 config.json"
[[ -f "${MODEL_DIR}/preprocessor_config.json" ]] || c_warn "缺少 preprocessor_config.json（视觉预处理用，建议补全）"
[[ -f "${MODEL_DIR}/tokenizer.json" ]]         || die "缺少 tokenizer.json"
compgen -G "${MODEL_DIR}/*.safetensors" >/dev/null || die "缺少 .safetensors 权重"

WEIGHT_BYTES=$(du -cb "${MODEL_DIR}"/*.safetensors 2>/dev/null | tail -1 | awk '{print $1}')
c_info "权重体积: $(( WEIGHT_BYTES / 1000000 )) MB"
if (( WEIGHT_BYTES < 4000000000 )); then
    die "权重只有 $(( WEIGHT_BYTES / 1000000 )) MB，预期约 4255 MB。可能 git-lfs 没拉全，请检查"
fi

# arch 快速确认
python - <<PY || die "config.json 不是 Qwen3-VL 文本结构，请确认 MODEL_ID"
import json
c = json.load(open("${MODEL_DIR}/config.json"))
assert c.get("architectures") == ["Qwen3VLForConditionalGeneration"], c.get("architectures")
t = c["text_config"]
print("  architectures     :", c["architectures"])
print("  layers/heads/kv   :", t["num_hidden_layers"], "/", t["num_attention_heads"], "/", t["num_key_value_heads"])
print("  hidden/head_dim   :", t["hidden_size"], "/", t["head_dim"])
print("  max_position_emb  :", t["max_position_embeddings"], "(RKLLM 侧上限 16384)")
PY

conda deactivate
c_ok "模型就绪: ${MODEL_DIR} ($(human_size "${MODEL_DIR}"))"
echo
c_info "下一步:  bash scripts/03_export_vision.sh"
